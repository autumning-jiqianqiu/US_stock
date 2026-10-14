#!/usr/bin/env python3
"""CFD 除权行为测试 + 股息率核算。

数据源:stockanalysis.com 的日线接口,同时给出
    c = 收盘(未复权,含除权跳空)
    a = 复权收盘(前复权,抹掉除权影响)
两者之差就是区间内的股息贡献:
    价格收益(price) = c_last / c_first - 1
    总收益(total)   = a_last / a_first - 1
    隐含股息率(DY)  = total - price

再与 MT5 侧 CFD 的实际收益(选股脚本反推的 AnnRet_est_pct)对照:
    * CFD ≈ price  → CFD 报价就是股票价格序列,除权日照样跳空下跌
    * CFD ≈ total  → CFD 已把股息折进报价

产物: data/processed/fundamentals/cfd_dividend_check.csv
用法:
  python3 scripts/check_cfd_dividend.py                       # 用基本面文件里保留的标的
  python3 scripts/check_cfd_dividend.py --only KO,XOM,PEP
  python3 scripts/check_cfd_dividend.py --start 2025-01-01 --end 2025-12-31
"""
from __future__ import annotations

import argparse
import csv
import json
import statistics as st
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "data" / "processed" / "fundamentals" / "cfd_dividend_check.csv"
RANK = ROOT / "reports" / "us_stocks" / "01_选股" / "reliability_ranking.csv"
POOL_FILE = ROOT / "data" / "processed" / "fundamentals" / "fundamentals.csv"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")


def http_json(url: str, retries: int = 3):
    """用 curl 取(实测 urllib 会被部分站点按 TLS 指纹挡掉,curl 正常)。"""
    last = None
    for i in range(retries):
        p = subprocess.run(["curl", "-s", "-m", "30", "-A", UA, url], capture_output=True)
        if p.returncode == 0 and p.stdout:
            try:
                return json.loads(p.stdout.decode("utf-8", "replace"))
            except Exception as e:                    # noqa: BLE001
                last = e
        else:
            last = f"curl rc={p.returncode}"
        time.sleep(0.5 * (i + 1))
    raise RuntimeError(f"{url}: {last}")


def history(ticker: str):
    d = http_json(f"https://stockanalysis.com/api/symbol/s/{ticker.lower()}/history"
                  "?range=5Y&period=Daily")
    rows = d.get("data") or []
    return sorted(rows, key=lambda r: r["t"])      # 接口是倒序的,统一成升序


def window_returns(rows: list[dict], start: str, end: str):
    """返回 (price_ret, total_ret, 起止日, 起止收盘) 或 None。"""
    s = [r for r in rows if r["t"] >= start]
    e = [r for r in rows if r["t"] <= end]
    if not s or not e:
        return None
    a, b = s[0], e[-1]
    if a["t"] >= b["t"] or not a["c"] or not a["a"]:
        return None
    price = b["c"] / a["c"] - 1.0
    total = b["a"] / a["a"] - 1.0
    return price, total, a["t"], b["t"], a["c"], b["c"]


def load_mt5_returns() -> dict:
    out = {}
    if not RANK.exists():
        return out
    for r in csv.DictReader(open(RANK, encoding="utf-8-sig")):
        if r.get("AnnRet_est_pct"):
            out[r["Code"].split(".")[0]] = float(r["AnnRet_est_pct"]) / 100.0
    return out


def load_pool(keep_only: bool) -> list[str]:
    if not POOL_FILE.exists():
        return []
    tks = []
    for r in csv.DictReader(open(POOL_FILE, encoding="utf-8-sig")):
        t = (r.get("ticker") or "").strip().upper()
        if not t:
            continue
        if keep_only and r.get("fund_keep") != "1":
            continue
        tks.append(t)
    return tks


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", default="2025-01-01")
    ap.add_argument("--end", default="2025-12-31")
    ap.add_argument("--only", default="")
    ap.add_argument("--all", action="store_true", help="测全部 81 只(默认只测过滤后保留的)")
    args = ap.parse_args()

    pool = ([t.strip().upper() for t in args.only.split(",")] if args.only
            else load_pool(keep_only=not args.all))
    if not pool:
        print("没有可测标的"); return 1
    mt5 = load_mt5_returns()
    print(f"待测 {len(pool)} 只 | 区间 {args.start} ~ {args.end}")
    print(f"MT5 收益表命中 {sum(1 for t in pool if t in mt5)} 只\n")

    rows = []
    for i, tk in enumerate(pool, 1):
        try:
            w = window_returns(history(tk), args.start, args.end)
            if not w:
                print(f"  [{i}/{len(pool)}] {tk:6s} 无行情"); continue
            price, total, d0, d1, c0, c1 = w
            dy = total - price
            mt5r = mt5.get(tk)
            rows.append({
                "ticker": tk, "date0": d0, "date1": d1, "close0": c0, "close1": c1,
                "price_ret": round(price, 4), "total_ret": round(total, 4),
                "div_yield": round(dy, 4),
                "mt5_cfd_ret": "" if mt5r is None else round(mt5r, 4),
                "gap_price": "" if mt5r is None else round(price - mt5r, 4),
                "gap_total": "" if mt5r is None else round(total - mt5r, 4),
            })
            extra = (f" | MT5 {mt5r*100:6.1f}%  与价格差{(price-mt5r)*100:+5.2f}pp  与总收益差{(total-mt5r)*100:+5.2f}pp"
                     if mt5r is not None else "")
            print(f"  [{i}/{len(pool)}] {tk:6s} 价格{price*100:6.1f}%  总收益{total*100:6.1f}%  股息{dy*100:5.2f}%{extra}")
            time.sleep(0.2)
        except Exception as e:                        # noqa: BLE001
            print(f"  [{i}/{len(pool)}] {tk:6s} 失败 {type(e).__name__}")

    if not rows:
        print("无结果"); return 1
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)

    dy = [r["div_yield"] for r in rows]
    print(f"\n股息率: 中位 {st.median(dy)*100:.2f}%  均值 {sum(dy)/len(dy)*100:.2f}%  "
          f"最高 {max(dy)*100:.2f}%  最低 {min(dy)*100:.2f}%")
    have = [r for r in rows if r["mt5_cfd_ret"] != ""]
    if have:
        gp = [abs(r["gap_price"]) for r in have]
        gt = [abs(r["gap_total"]) for r in have]
        print(f"可比 {len(have)} 只:")
        print(f"  |CFD − 未复权价格收益|  中位 {st.median(gp)*100:.2f}pp  均值 {sum(gp)/len(gp)*100:.2f}pp")
        print(f"  |CFD − 前复权总收益|    中位 {st.median(gt)*100:.2f}pp  均值 {sum(gt)/len(gt)*100:.2f}pp")
        w1 = sum(1 for r in have if abs(r["gap_price"]) < abs(r["gap_total"]))
        print(f"  CFD 更贴近未复权价格的只数: {w1}/{len(have)}")
    print(f"\n写出 {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
