#!/usr/bin/env python3
"""离线重算基本面快照的 fund_keep(不改动任何因子值,不需要联网)。

用途:只想换一个"保留阈值"(min_pct)时,不必重新抓 SEC 数据。
原理与 fetch_fundamentals.py 完全一致:
    n_applicable = 有值且 *_applicable 为 True 的因子个数
    pass         = n_applicable >= --min-metrics
    keep         = pass and fund_pct >= --min-pct
其中 fund_pct 是"覆盖集内的综合分位",与阈值无关,因此重算与原管线等价。

用法:
    python3 scripts/us_stocks/rethreshold_snapshot.py \
        data/processed/fundamentals/fundamentals_2024-12-31.csv \
        --min-pct 0.30 --out-name fundamentals_2024-12-31_p30.csv

输出:写回 data/processed/fundamentals/,并自动复制一份到 MT5 的 Common/Files。
"""

from __future__ import annotations

import argparse
import csv
import shutil
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT_DIR = REPO / "data" / "processed" / "fundamentals"
COMMON = Path.home() / (
    "Library/Application Support/net.metaquotes.wine.metatrader5"
    "/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common/Files"
)

# 与 fetch_fundamentals.py 的 OUT_FACTORS 对齐
FACTORS = [
    "roe", "net_margin", "gross_margin", "earn_vol", "net_debt_ebitda", "int_cov",
    "roa", "fcf_margin", "cash_conv", "accruals", "debt_to_assets", "dividend_yield",
]


def n_applicable(row: dict) -> int:
    n = 0
    for k in FACTORS:
        v = (row.get(k) or "").strip()
        applicable = (row.get(f"{k}_applicable", "True") or "True").strip()
        if v and applicable == "True":
            n += 1
    return n


def clean(v) -> str:
    s = "" if v is None else str(v)
    return s.replace(",", ";").replace("\r", " ").replace("\n", " ")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("src", help="已有快照 CSV 路径")
    ap.add_argument("--min-pct", type=float, default=0.30, help="新的综合分位阈值")
    ap.add_argument("--min-metrics", type=int, default=3, help="最少适用因子数")
    ap.add_argument("--out-name", default="", help="输出文件名(默认在原文件名后加 _pXX)")
    ap.add_argument("--no-copy", action="store_true", help="不复制到 MT5 共享目录")
    args = ap.parse_args()

    src = Path(args.src)
    rows = list(csv.DictReader(src.open(encoding="utf-8-sig")))
    if not rows:
        raise SystemExit("源文件没有数据行")

    kept, dropped = [], []
    for r in rows:
        n = n_applicable(r)
        pct_raw = (r.get("fund_pct") or "").strip()
        pct = float(pct_raw) if pct_raw else None
        if n < args.min_metrics:
            keep, reason = False, f"适用因子仅{n}项(<{args.min_metrics})"
        elif pct is None:
            keep, reason = False, "无综合分位"
        elif pct < args.min_pct:
            keep, reason = False, f"综合分位{pct:.2f}<{args.min_pct:.2f}"
        else:
            keep, reason = True, ""
        r["fund_keep"] = "1" if keep else "0"
        r["fund_reason"] = reason
        (kept if keep else dropped).append(r)

    tag = f"_p{int(round(args.min_pct * 100)):02d}"
    out_name = args.out_name or (src.stem + tag + ".csv")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUT_DIR / out_name
    with out_path.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()), quoting=csv.QUOTE_NONE,
                           escapechar="\\", lineterminator="\r\n")
        w.writeheader()
        for r in rows:
            w.writerow({k: clean(v) for k, v in r.items()})

    if not args.no_copy and COMMON.exists():
        shutil.copy2(out_path, COMMON / out_name)
        print(f"已复制到 MT5 共享目录: {COMMON / out_name}")

    orig = sum(1 for r in rows if (r.get("fund_keep") or "").strip() == "1")
    print(f"源: {src.name}")
    print(f"新阈值 min_pct={args.min_pct} min_metrics={args.min_metrics}")
    print(f"输出: {out_path}(保留 {len(kept)} 只,淘汰 {len(dropped)} 只)")
    added = sorted(r["ticker"] for r in kept)
    print("保留池:", " ".join(added))


if __name__ == "__main__":
    main()
