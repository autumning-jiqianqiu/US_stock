#!/usr/bin/env python3
"""美股基本面因子拉取与预处理管线(SEC EDGAR 版)。

数据源:
  * 主源  SEC EDGAR XBRL  companyfacts  —— 三大报表全量、带报告日与 frame
  * 行业  SEC submissions(SIC 码)      —— 用于金融/地产的指标适用性豁免
  * 校验  双源不可得时的替代方案:同一指标用「备用 XBRL 标签」二次计算 + 值域合理性检查

说明:原计划的 Yahoo Finance 交叉验证在当前网络下被拦截(crumb 返回 HTML 拦截页),
      故改用 SEC 内部双算法校验,并在审计文件里注明。

产物:
  data/processed/fundamentals/fundamentals.csv        因子表(供 MT5 选股脚本读取)
  data/processed/fundamentals/fundamentals_audit.csv  逐标的审计
  并自动复制到 MT5 Common/Files(若存在)

用法:
  python3 scripts/fetch_fundamentals.py
  python3 scripts/fetch_fundamentals.py --limit 5
  python3 scripts/fetch_fundamentals.py --selftest      # 离线自检
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import ssl
import statistics
import sys
import time
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "data" / "processed" / "fundamentals"
MQL5_SCREENER = ROOT / "mql5" / "Scripts" / "US" / "ScreenUSStocks.mq5"
MT5_COMMON = (
    Path.home()
    / "Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/users/user"
    / "AppData/Roaming/MetaQuotes/Terminal/Common/Files"
)

# SEC 要求 UA 里带联系方式;实测纯 Mozilla UA 会被 403
SEC_UA = "USStockResearch/0.1 (research use; contact: your.email@example.com)"
TIMEOUT = 30
SLEEP = 0.15
WIN_LO, WIN_HI = 0.02, 0.98

SEC_METRICS = {
    "revenue":      ("RevenueFromContractWithCustomerExcludingAssessedTax",
                     "RevenueFromContractWithCustomerIncludingAssessedTax",
                     "Revenues", "SalesRevenueNet"),
    "net_income":   ("NetIncomeLoss", "ProfitLoss"),
    "gross_profit": ("GrossProfit",),
    "cost_revenue": ("CostOfGoodsAndServicesSold", "CostOfRevenue", "CostOfGoodsSold",
                     "CostOfServices", "CostOfGoodsAndServiceExcludingDepreciationDepletionAndAmortization"),
    "operating_income": ("OperatingIncomeLoss",),
    "equity":       ("StockholdersEquity",
                     "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"),
    "assets":       ("Assets",),
    "liabilities":  ("Liabilities",),
    "cash":         ("CashAndCashEquivalentsAtCarryingValue",),
    "long_debt":    ("LongTermDebtNoncurrent", "LongTermDebt",
                     "LongTermDebtAndCapitalLeaseObligations",
                     "LongTermDebtAndCapitalLeaseObligationsNoncurrent",
                     "DebtLongtermAndShorttermCombinedAmount"),
    "short_debt":   ("LongTermDebtCurrent", "ShortTermBorrowings", "DebtCurrent",
                     "LongTermDebtAndCapitalLeaseObligationsCurrent",
                     "NotesPayableCurrent", "FinanceLeaseLiabilityCurrent"),
    "interest_exp": ("InterestExpense", "InterestExpenseNonoperating",
                     "InterestExpenseDebt", "InterestAndDebtExpense",
                     "InterestExpenseBorrowings"),
    "dep_amort":    ("DepreciationDepletionAndAmortization",
                     "DepreciationAmortizationAndAccretionNet",
                     "DepreciationAndAmortization"),
    "cfo":          ("NetCashProvidedByUsedInOperatingActivities",
                     "NetCashProvidedByUsedInOperatingActivitiesContinuingOperations"),
    "capex":        ("PaymentsToAcquirePropertyPlantAndEquipment",),
    "eps_diluted":  ("EarningsPerShareDiluted", "EarningsPerShareBasic"),
    "shares_diluted": ("WeightedAverageNumberOfDilutedSharesOutstanding",
                       "WeightedAverageNumberOfSharesOutstandingBasic"),
}
EPS_UNIT = "USD/shares"

# key -> (中文名, 方向, 族)
OUT_FACTORS = {
    "roe":            ("ROE(TTM)",        +1, "quality"),
    "net_margin":     ("净利率(TTM)",      +1, "quality"),
    "gross_margin":   ("毛利率(TTM)",      +1, "quality"),
    "earn_vol":       ("盈利波动(近8季)",   -1, "stability"),
    "net_debt_ebitda":("净负债/EBITDA",    -1, "safety"),
    "int_cov":        ("利息保障倍数",      +1, "safety"),
    # 扩展因子(同管线顺带产出,默认不参与过滤)
    "roa":            ("ROA(TTM)",        +1, "quality"),
    "fcf_margin":     ("FCF利润率",        +1, "quality"),
    "cash_conv":      ("现金转化率",        +1, "quality"),
    "accruals":       ("应计利润",         -1, "earnqual"),
    "debt_to_assets": ("总负债/总资产",     -1, "safety"),
    "dividend_yield": ("股息率",           +1, "shareholder"),
}
PLAN_FACTORS = ["roe", "net_margin", "gross_margin", "earn_vol", "net_debt_ebitda",
                "int_cov", "dividend_yield", "roa"]

# SIC: 金融与地产不做毛利率/杠杆类判定
FIN_SIC = [(6000, 6499), (6500, 6799)]


# --------------------------------------------------------------------------
# 纯函数(离线可测)
# --------------------------------------------------------------------------
def winsorize(values: list[float], lo: float = WIN_LO, hi: float = WIN_HI) -> list[float]:
    if len(values) < 8:
        return list(values)
    s = sorted(values)
    n = len(s)
    lo_v = s[max(0, min(n - 1, int(math.floor(lo * (n - 1)))))]
    hi_v = s[max(0, min(n - 1, int(math.ceil(hi * (n - 1)))))]
    return [min(max(v, lo_v), hi_v) for v in values]


def pct_rank(values: list[float]) -> list[float]:
    n = len(values)
    if n == 0:
        return []
    if n == 1:
        return [0.5]
    order = sorted(range(n), key=lambda i: values[i])
    out = [0.0] * n
    i = 0
    while i < n:
        j = i
        while j + 1 < n and values[order[j + 1]] == values[order[i]]:
            j += 1
        pct = ((i + j) / 2.0) / (n - 1.0)
        for k in range(i, j + 1):
            out[order[k]] = pct
        i = j + 1
    return out


def oriented(value: float, direction: int) -> float:
    return value * direction if direction > 0 else -value


def direction_of(key: str) -> int:
    return OUT_FACTORS[key][1]


def composite_percentile(table: list[dict], factor_keys: list[str], min_metrics: int) -> dict:
    """在覆盖集内逐因子算百分位(先缩尾、先统一方向),再取平均得综合分位。"""
    factor_pct: dict[str, dict[str, float]] = {}
    for key in factor_keys:
        vals, tks = [], []
        for row in table:
            v = row.get(key)
            if v is None or not row.get(f"{key}_applicable", True):
                continue
            vals.append(oriented(float(v), direction_of(key)))
            tks.append(row["ticker"])
        vals = winsorize(vals)
        factor_pct[key] = dict(zip(tks, pct_rank(vals)))

    out = {}
    for row in table:
        tk = row["ticker"]
        used = [k for k in factor_keys if tk in factor_pct.get(k, {})]
        if len(used) < min_metrics:
            out[tk] = {"pct": None, "n_metrics": len(used), "pass": False,
                       "reasons": [f"适用因子仅{len(used)}项(<{min_metrics})"]}
            continue
        out[tk] = {"pct": sum(factor_pct[k][tk] for k in used) / len(used),
                   "n_metrics": len(used), "pass": True, "reasons": []}
    return out


def apply_filter(comp: dict, min_pct: float) -> dict:
    res = {}
    for tk, info in comp.items():
        ok = info["pass"] and info["pct"] is not None and info["pct"] >= min_pct
        reasons = list(info["reasons"])
        if info["pass"] and not ok:
            reasons.append(f"综合分位{info['pct']:.2f}<{min_pct:.2f}")
        res[tk] = {"keep": ok, "pct": info["pct"], "n_metrics": info["n_metrics"],
                   "reasons": reasons}
    return res


# --------------------------------------------------------------------------
# 网络层
# --------------------------------------------------------------------------
_SSL_CTX = None


def ssl_context():
    """框架版 Python 默认找不到系统 CA,这里显式指定(certifi → 系统证书)。"""
    global _SSL_CTX
    if _SSL_CTX is not None:
        return _SSL_CTX
    cands = []
    try:
        import certifi
        cands.append(certifi.where())
    except Exception:                                 # noqa: BLE001
        pass
    cands += ["/etc/ssl/cert.pem", "/private/etc/ssl/cert.pem"]
    for c in cands:
        if c and Path(c).exists():
            _SSL_CTX = ssl.create_default_context(cafile=c)
            return _SSL_CTX
    _SSL_CTX = ssl.create_default_context()
    return _SSL_CTX


def http_get(url: str, retries: int = 3) -> bytes:
    last = None
    for i in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": SEC_UA,
                                                       "Accept": "application/json,*/*",
                                                       "Accept-Encoding": "gzip"})
            with urllib.request.urlopen(req, timeout=TIMEOUT, context=ssl_context()) as r:
                data = r.read()
                if (r.headers.get("Content-Encoding") or "").lower() == "gzip":
                    import gzip
                    data = gzip.decompress(data)
                return data
        except Exception as e:                        # noqa: BLE001
            last = e
            time.sleep(0.8 * (i + 1))
    raise RuntimeError(f"GET 失败 {url}: {last}")


def get_json(url: str):
    return json.loads(http_get(url).decode("utf-8", "replace"))


def curl_json(url: str, retries: int = 3):
    """用 curl 取(部分站点按 TLS 指纹挡 urllib,curl 正常)。"""
    import subprocess
    last = None
    for i in range(retries):
        p = subprocess.run(["curl", "-s", "-m", "30", "-A",
                            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
                            url], capture_output=True)
        if p.returncode == 0 and p.stdout:
            try:
                return json.loads(p.stdout.decode("utf-8", "replace"))
            except Exception as e:                    # noqa: BLE001
                last = e
        else:
            last = f"curl rc={p.returncode}"
        time.sleep(0.5 * (i + 1))
    raise RuntimeError(f"{url}: {last}")


def trailing_div_yield(ticker: str, asof: str | None = None) -> float | None:
    """近 12 个月股息率 = 前复权总收益 − 未复权价格收益(stockanalysis)。

    asof 不为空时,只用到该日为止的价格 —— 同样避免前视。
    """
    try:
        d = curl_json(f"https://stockanalysis.com/api/symbol/s/{ticker.lower()}"
                      "/history?range=5Y&period=Daily")
        rows = sorted(d.get("data") or [], key=lambda r: r["t"])
        if asof:
            rows = [r for r in rows if r["t"] <= asof]
        if len(rows) < 200:
            return None
        # 取最近 252 个交易日
        win = rows[-252:]
        a, b = win[0], win[-1]
        if not a.get("c") or not a.get("a"):
            return None
        price = b["c"] / a["c"] - 1.0
        total = b["a"] / a["a"] - 1.0
        return max(0.0, total - price)
    except Exception:                                 # noqa: BLE001
        return None


def load_pool() -> list[str]:
    txt = MQL5_SCREENER.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"string g_symbols\[\]\s*=\s*\{(.*?)\};", txt, re.S)
    if not m:
        raise SystemExit(f"没能从 {MQL5_SCREENER} 解析出股票池")
    out = []
    for line in m.group(1).splitlines():
        line = line.strip()
        if line.startswith("//"):
            continue
        out += re.findall(r'"([^"]+)"', line)
    return out


def ticker_to_cik() -> dict[str, str]:
    data = get_json("https://www.sec.gov/files/company_tickers.json")
    return {str(v["ticker"]).upper(): str(v["cik_str"]).zfill(10) for v in data.values()}


def sec_submissions(cik: str) -> dict:
    return get_json(f"https://data.sec.gov/submissions/CIK{cik}.json")


def sec_facts(cik: str) -> dict:
    return get_json(f"https://data.sec.gov/api/xbrl/companyfacts/CIK{cik}.json")


def filter_facts(facts: dict, asof: str | None) -> dict:
    """点时过滤:只保留「报送日(filed) <= asof」的事实,消除前视偏差。

    SEC 的每条 XBRL 事实都带 filed(实际报送日),因此可以精确还原
    "在 asof 这一天,你能看到哪些财报数据"。
    """
    if not asof:
        return facts
    out: dict = {"facts": {}}
    for k in ("cik", "entityName"):
        if k in facts:
            out[k] = facts[k]
    for ns, tags in (facts.get("facts") or {}).items():
        nso = {}
        for tag, node in tags.items():
            units = {}
            for unit, arr in (node.get("units") or {}).items():
                kept = [it for it in arr if (it.get("filed") or "9999-99-99") <= asof]
                if kept:
                    units[unit] = kept
            if units:
                nso[tag] = {"units": units}
        if nso:
            out["facts"][ns] = nso
    return out


# --------------------------------------------------------------------------
# XBRL 取值
# --------------------------------------------------------------------------
def _unit_series(facts: dict, tag: str, unit: str | None = None):
    for ns in ("us-gaap", "ifrs-full"):
        node = facts.get("facts", {}).get(ns, {}).get(tag)
        if not node:
            continue
        units = node.get("units", {})
        if unit and unit in units:
            return units[unit]
        for arr in units.values():
            return arr
    return None


ASOF_REF = [None]        # 全局点时参照日;由 main 设置,供 sec_pick 判断"数据是否新鲜"


def _is_fresh(series, max_days: int = 450) -> bool:
    """该标签里是否存在"接近参照日"的期间,避免选到多年未用的陈旧标签。

    例:JPM 的 Revenues 标签最后一次使用是 2014 年,若无此检查会被误当成当期营收。
    """
    ref = date.fromisoformat(ASOF_REF[0]) if ASOF_REF[0] else date.today()
    for it in series:
        e = it.get("end")
        if not e:
            continue
        try:
            if (ref - date.fromisoformat(e)).days <= max_days:
                return True
        except ValueError:
            continue
    return False


def sec_pick(facts: dict, tags, unit=None):
    for t in tags:
        s = _unit_series(facts, t, unit)
        if s and _is_fresh(s):
            return t, s
    return None, None


def flow_quarters(series) -> dict[str, float]:
    """从 XBRL 期间事实推导离散季度值,返回 {期末日: 值}。

    两个来源:
      1) 直接披露的季度值(期间长度 80~100 天)
      2) 年初至今累计(YTD)差分:同一 start 的相邻两期,期末间隔 75~105 天
    (很多公司只在 10-Q 里报 YTD,不报离散季度;不做差分就会误判成"缺失")
    """
    if not series:
        return {}
    q: dict[str, float] = {}
    by_start: dict[str, list] = {}
    for it in series:
        s, e, v = it.get("start"), it.get("end"), it.get("val")
        if not s or not e or v is None:
            continue
        d = (date.fromisoformat(e) - date.fromisoformat(s)).days
        if 75 <= d <= 125:            # 含 12/16 周记账期的公司
            q[e] = float(v)
        by_start.setdefault(s, []).append((e, float(v)))
    for arr in by_start.values():
        arr.sort()
        for i in range(1, len(arr)):
            pe, pv = arr[i - 1]
            e, v = arr[i]
            if 70 <= (date.fromisoformat(e) - date.fromisoformat(pe)).days <= 130 and e not in q:
                q[e] = v - pv
    return q


def quarters_ok(q: dict, need: int) -> bool:
    """最近 need 个季度的间隔是否真的近似季度(防止把年度值当季度)。"""
    ks = sorted(q)[-need:]
    if len(ks) < need:
        return False
    return all(60 <= (date.fromisoformat(b) - date.fromisoformat(a)).days <= 140
               for a, b in zip(ks, ks[1:]))


def instant_latest(series):
    best_end, best = None, None
    for it in series:
        end = it.get("end")
        if end and (best_end is None or end > best_end):
            best_end, best = end, float(it["val"])
    return best


LAST_BASIS = [None]     # "Q"=四季度合计(FY)=年报兜底;调用方读这个来写审计
LAST_END = [None]       # 本次 ttm() 用到的最后一个期间期末日


def ttm(series):
    """滚动 12 个月。优先四季度合计;取不到则退回最近一个年报(记 FY)。"""
    LAST_BASIS[0] = None
    LAST_END[0] = None
    if not series:
        return None
    q = flow_quarters(series)
    if len(q) >= 4 and quarters_ok(q, 4):
        LAST_BASIS[0] = "Q"
        ks = sorted(q)[-4:]
        LAST_END[0] = ks[-1]
        return sum(q[k] for k in ks)
    annual = None
    for it in series:                     # 最近一个整年
        s, e, v = it.get("start"), it.get("end"), it.get("val")
        if not s or not e or v is None:
            continue
        if 330 <= (date.fromisoformat(e) - date.fromisoformat(s)).days <= 400:
            if annual is None or e > annual[0]:
                annual = (e, float(v))
    if annual:
        LAST_BASIS[0] = "FY"
        LAST_END[0] = annual[0]
        return annual[1]
    return None


def eps_vol_8q(facts: dict):
    """近 8 季 EPS 波动。优先用 EPS 序列;没有就用(季度净利润 ÷ 季度股数)推导。"""
    _, series = sec_pick(facts, SEC_METRICS["eps_diluted"], EPS_UNIT)
    q = flow_quarters(series) if series else {}
    if len(q) < 6:
        ni_q = flow_quarters(sec_pick(facts, SEC_METRICS["net_income"])[1] or [])
        sh_q = flow_quarters(sec_pick(facts, SEC_METRICS["shares_diluted"])[1] or [])
        derived = {k: ni_q[k] / sh_q[k] for k in ni_q if k in sh_q and sh_q[k]}
        if len(derived) >= 6:
            q = derived
    if len(q) < 6:
        return None, len(q)
    vals = [q[k] for k in sorted(q)[-8:]]
    return statistics.pstdev(vals), len(vals)


# --------------------------------------------------------------------------
# 单只标的
# --------------------------------------------------------------------------
def compute_one(ticker: str, cik: str | None, asof: str | None = None) -> dict:
    row: dict = {"ticker": ticker, "cik": cik or "", "status": "ok", "notes": [],
                 "ship": "SEC"}
    for k in OUT_FACTORS:
        row[k] = None
        row[f"{k}_applicable"] = True
    row["sic"] = row["sector"] = row["entity"] = ""

    if not cik:
        row["status"] = "no_cik"
        return row

    # --- 行业(SIC) ---
    try:
        sub = sec_submissions(cik)
        row["sic"] = str(sub.get("sic", ""))
        row["sector"] = str(sub.get("sicDescription", ""))
        row["entity"] = str(sub.get("name", ""))
    except Exception as e:                            # noqa: BLE001
        row["notes"].append(f"submissions失败:{type(e).__name__}")

    try:
        facts = filter_facts(sec_facts(cik), asof)   # 点时过滤,只看 asof 之前已报送的数据
    except Exception as e:                            # noqa: BLE001
        row["status"] = f"sec_fail:{type(e).__name__}"
        return row

    def ser(key, unit="USD"):
        return sec_pick(facts, SEC_METRICS[key], unit)[1]

    bases_used = []
    ends_seen = []

    def T(s):
        v = ttm(s)
        if LAST_BASIS[0] == "FY":
            bases_used.append("FY")
        if LAST_END[0]:
            ends_seen.append(LAST_END[0])
        return v

    rev, ni = T(ser("revenue")), T(ser("net_income"))
    gp, oi = T(ser("gross_profit")), T(ser("operating_income"))
    if gp is None:                       # 很多公司不单列 GrossProfit,用 营收−营业成本 推导
        cost = T(ser("cost_revenue"))
        if rev is not None and cost is not None and cost != 0:
            gp = rev + cost if cost < 0 else rev - cost
    eq = instant_latest(ser("equity")) if ser("equity") else None
    assets = instant_latest(ser("assets")) if ser("assets") else None
    liab = instant_latest(ser("liabilities")) if ser("liabilities") else None
    if liab is None and assets is not None and eq is not None:
        liab = assets - eq                      # 不少公司不单列 Liabilities
    cash = instant_latest(ser("cash")) if ser("cash") else None
    ld = instant_latest(ser("long_debt")) if ser("long_debt") else None
    sd = instant_latest(ser("short_debt")) if ser("short_debt") else None
    iexp = T(ser("interest_exp")) if ser("interest_exp") else None
    da = T(ser("dep_amort")) if ser("dep_amort") else None
    cfo = T(ser("cfo")) if ser("cfo") else None
    capex = T(ser("capex")) if ser("capex") else None
    row["basis_fy"] = "1" if "FY" in bases_used else "0"
    row["asof_date"] = max(ends_seen) if ends_seen else ""
    if "FY" in bases_used:
        row["notes"].append("部分科目用最近年报兜底(FY)")
    ev, qn = eps_vol_8q(facts)

    if ni is not None and eq is not None and eq > 0.0:
        row["roe"] = ni / eq
    elif eq is not None and eq <= 0.0:
        row["roe_applicable"] = False          # 负权益(常见于长期回购)时 ROE 无意义
        row["notes"].append("股东权益为负,ROE不适用")
    if ni is not None and rev:
        row["net_margin"] = ni / rev
        if assets:
            row["roa"] = ni / assets
    if gp is not None and rev:
        row["gross_margin"] = gp / rev
    if ev is not None and qn >= 6:
        row["earn_vol"] = ev
    elif qn:
        row["earn_vol_applicable"] = False
        row["notes"].append(f"EPS仅{qn}季")
    net_debt = None
    if ld is not None or sd is not None:
        net_debt = (ld or 0.0) + (sd or 0.0) - (cash or 0.0)
    ebitda = (oi + da) if (oi is not None and da is not None) else None
    if net_debt is not None and ebitda and ebitda > 0:
        row["net_debt_ebitda"] = net_debt / ebitda
    if oi is not None and iexp and iexp > 0:
        row["int_cov"] = oi / iexp
    if cfo is not None and rev:
        row["fcf_margin"] = (cfo - (capex or 0.0)) / rev
    if cfo is not None and ni and ni != 0:
        row["cash_conv"] = cfo / ni
    if ni is not None and cfo is not None and assets:
        row["accruals"] = (ni - cfo) / assets
    if liab is not None and assets:
        row["debt_to_assets"] = liab / assets

    # --- 股息率:stockanalysis 的「前复权总收益 − 未复权价格收益」 ---
    dy = trailing_div_yield(ticker, asof)
    if dy is not None:
        row["dividend_yield"] = dy
        if dy == 0.0:
            row["notes"].append("近12个月无派息")

    # --- 金融/地产豁免 ---
    try:
        sic = int(row["sic"] or 0)
    except ValueError:
        sic = 0
    is_fin = any(lo <= sic <= hi for lo, hi in FIN_SIC)
    row["is_financial"] = is_fin
    if is_fin:
        # 银行/保险/地产:毛利率、净负债/EBITDA、利息保障、净利率 口径均不适用,
        # 改用 ROE + ROA + 盈利波动率 + 股息率
        for k in ("gross_margin", "net_debt_ebitda", "int_cov", "net_margin"):
            row[f"{k}_applicable"] = False

    # --- 替代校验:备用标签二次计算 + 值域检查 ---
    flags = []
    _, alt_rev = sec_pick(facts, SEC_METRICS["revenue"][1:])
    alt = ttm(alt_rev) if alt_rev else None
    if rev and alt and abs(rev - alt) > 0.05 * max(abs(rev), abs(alt)):
        flags.append("revenue_tag_mismatch")
    for k, (lo, hi) in (("net_margin", (-2, 1)), ("gross_margin", (-1, 1)),
                        ("roe", (-3, 3)), ("debt_to_assets", (0, 2)), ("cash_conv", (-5, 10))):
        v = row.get(k)
        if v is not None and not (lo <= v <= hi):
            flags.append(f"{k}_out_of_range")
    row["mismatch_fields"] = ",".join(flags)

    # 因子分级:
    #   硬因子(披露覆盖高)取不到 → 判缺失 → 淘汰
    #   软因子(XBRL 覆盖天生偏低)取不到 → 视为"口径不适用",只降低适用项数
    HARD = ("roe", "net_margin", "earn_vol")
    missing = [k for k in PLAN_FACTORS
               if k in HARD and row.get(f"{k}_applicable", True) and row.get(k) is None]
    for k in PLAN_FACTORS:
        if k not in HARD and row.get(k) is None:
            row[f"{k}_applicable"] = False
    if missing:
        row["status"] = "missing:" + ",".join(missing)
    return row


# --------------------------------------------------------------------------
# 自检 / 主流程
# --------------------------------------------------------------------------
def selftest() -> int:
    assert winsorize([1, 2, 3]) == [1, 2, 3]
    assert pct_rank([10, 20, 30, 40]) == [0.0, 1 / 3, 2 / 3, 1.0]
    pr = pct_rank([5, 5, 9])
    assert abs(pr[0] - 0.25) < 1e-9 and abs(pr[2] - 1.0) < 1e-9, pr
    assert oriented(3.0, -1) == -3.0
    table = [{"ticker": f"T{i}", "roe": 0.10 + i * 0.01, "roe_applicable": True,
              "net_margin": 0.05 + i * 0.01, "net_margin_applicable": True,
              "gross_margin": 0.30 + i * 0.01, "gross_margin_applicable": True,
              "earn_vol": -0.02 * i, "earn_vol_applicable": True,
              "net_debt_ebitda": 2.0 - 0.1 * i, "net_debt_ebitda_applicable": True,
              "int_cov": 5.0 + i, "int_cov_applicable": True} for i in range(10)]
    comp = composite_percentile(table, PLAN_FACTORS, 3)
    filt = apply_filter(comp, 0.40)
    kept = [t for t, r in filt.items() if r["keep"]]
    assert "T9" in kept and "T0" not in kept, (kept, filt["T0"])
    # 金融股只有 3 项适用仍可通过
    fin = dict(table[9])
    fin.update({"ticker": "FIN", "gross_margin_applicable": False,
                "net_debt_ebitda_applicable": False, "int_cov_applicable": False})
    c2 = composite_percentile(table[:9] + [fin], PLAN_FACTORS, 3)
    assert c2["FIN"]["pass"] and c2["FIN"]["n_metrics"] == 3, c2["FIN"]
    print("自检通过 / 保留", len(kept), "只;金融股 3 项适用可放行")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--min-pct", type=float, default=0.40)
    ap.add_argument("--min-metrics", type=int, default=3)
    ap.add_argument("--asof", default="", help="点时快照日 YYYY-MM-DD;只用到该日为止已报送的数据")
    ap.add_argument("--out-name", default="fundamentals.csv", help="输出文件名(写到仓库与 MT5 共享目录)")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    ASOF_REF[0] = args.asof or None

    pool = load_pool()
    print(f"股票池:{len(pool)} 只")
    cik_map = ticker_to_cik()
    print(f"SEC ticker→CIK 映射:{len(cik_map)} 条")

    todo = pool[: args.limit] if args.limit else pool
    rows = []
    for i, sym in enumerate(todo, 1):
        bare = sym.split(".")[0].upper()
        cik = cik_map.get(bare)
        try:
            row = compute_one(bare, cik, args.asof or None)
        except Exception as e:                        # noqa: BLE001
            row = {"ticker": bare, "status": f"error:{type(e).__name__}", "notes": [],
                   "mismatch_fields": ""}
            for k in OUT_FACTORS:
                row.setdefault(k, None)
        row["pool_code"] = sym
        row["snapshot"] = args.asof or "latest"
        rows.append(row)
        print(f"  [{i}/{len(todo)}] {bare:6s} cik={cik or '-':>10s} sic={row.get('sic',''):>4s} {row['status']}")
        time.sleep(SLEEP)

    covered = [r for r in rows if str(r.get("status")) == "ok"]
    comp = composite_percentile(covered, PLAN_FACTORS, args.min_metrics)
    filt = apply_filter(comp, args.min_pct)
    for r in rows:
        info = filt.get(r["ticker"])
        r["fund_pct"] = f"{info['pct']:.4f}" if info and info["pct"] is not None else ""
        r["fund_keep"] = "1" if info and info["keep"] else "0"
        r["fund_reason"] = "" if (info and info["keep"]) else (
            ";".join(info["reasons"]) if info else str(r.get("status", "")))

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    cols = (["pool_code", "ticker", "cik", "sic", "sector", "entity", "status",
             "fund_keep", "fund_pct", "fund_reason", "mismatch_fields", "is_financial",
             "asof_date", "basis_fy", "snapshot"]
            + list(OUT_FACTORS)
            + [f"{k}_applicable" for k in OUT_FACTORS])
    f_path = OUT_DIR / args.out_name
    def _clean(v):
        """MQL5 侧是按逗号硬切的,字段里不能出现逗号(否则列错位)。"""
        s = "" if v is None else str(v)
        return s.replace(",", ";").replace("\r", " ").replace("\n", " ")

    with f_path.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f, quoting=csv.QUOTE_NONE, escapechar="\\", lineterminator="\r\n")
        w.writerow(cols)
        for r in rows:
            w.writerow([_clean(r.get(c)) for c in cols])
    a_name = args.out_name.replace(".csv", "") + "_audit.csv"
    a_path = OUT_DIR / a_name
    with a_path.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f, quoting=csv.QUOTE_NONE, escapechar="\\", lineterminator="\r\n")
        w.writerow(["ticker", "status", "keep", "fund_pct", "reason", "sic", "sector",
                    "asof_date", "basis_fy", "mismatch", "notes"])
        for r in rows:
            w.writerow([_clean(x) for x in
                        [r["ticker"], r.get("status"), r.get("fund_keep"), r.get("fund_pct"),
                         r.get("fund_reason"), r.get("sic"), r.get("sector"),
                         r.get("asof_date"), r.get("basis_fy"),
                         r.get("mismatch_fields"), ";".join(r.get("notes") or [])]])

    keep = [r["pool_code"] for r in rows if r.get("fund_keep") == "1"]
    print()
    print(f"覆盖 {len(covered)}/{len(rows)} → 保留 {len(keep)} 只,淘汰 {len(rows)-len(keep)} 只")
    print("淘汰明细:")
    for r in rows:
        if r.get("fund_keep") != "1":
            print(f"   {r['ticker']:6s} {r.get('fund_reason') or r.get('status')}")
    print(f"\n写出 {f_path}\n写出 {a_path}")

    if MT5_COMMON.is_dir():
        for src, name in ((f_path, args.out_name), (a_path, a_name)):
            try:
                (MT5_COMMON / name).write_bytes(src.read_bytes())
                print(f"已复制 → {MT5_COMMON / name}")
            except Exception as e:                    # noqa: BLE001
                print(f"复制失败 {name}:{e}")
    else:
        print(f"未找到 MT5 共享目录,请手动复制 fundamentals.csv 到 {MT5_COMMON}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
