# 美股选股脚本 —— Pepperstone 基准版

回到 **Pepperstone-Demo**,品种池为 **81 个美股/ETF**。

## 品种池

原池 100 个里,Pepperstone 没有提供这 19 个,已剔除:

```
HYG GLD VNQ BK VBK VGT ZTO YY BHP VALE
BILI TCOM MOMO EDU PDD EA TWLO SQ DJT
```

剩下的 81 个只写 **基础代码**(`KO`、`MCD`…),真实合约由解析函数挑选:

```
候选顺序：代码.US  →  代码.US-24  →  代码(纯代码)
挑选规则：谁在 [起始日, 结束日] 区间内真的有 ≥InpMinBars 根K线,就用谁
```

这样能同时兼容 Pepperstone(`.US` / `.US-24`)和以后换经纪商的纯代码命名,
也能避开"某个后缀合约没有那段历史"的坑。

## 主要参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `InpTimeframe` | M30 | 选股周期(与图表周期无关) |
| `InpStartDate` / `InpEndDate` | 2025.01.01 ~ 2025.12.31 | 样本区间 |
| `InpIndexSymbol` | US500 | 基准;会自动在 `US500/SP500m/SPX500…` 里找存在的 |
| `InpFallbackBars` | 3000 | 区间取不到数据时,回退取最近 N 根K线 |
| `InpMinBars` | 30 | 少于这么多根算数据不足 |
| `InpTotalCount` | 100 | 一类的全部保留,二类补足到总数上限 |

## 相对原脚本的改动

1. 品种池 → Pepperstone 81 个基础代码;`POOL_SIZE` = 81
2. 新增 `ResolveUSSymbol()`:按"区间内真有K线"挑合约
3. 新增 `ResolveIndexSymbol()`:基准自动解析
4. 区间无数据时自动回退取最近 K 线
5. 每只打印进度 `[i/81] 代码 ...`,结束打印 `扫描完成,用时 X 秒`
6. 有效数据 < 2 时打印排查方向,不再只报"有效数据不足2只"

指标、打分、分类逻辑 **一行未改**。

## 运行

1. 双击仓库根目录 `install_us_stocks.command`
2. MetaEditor 里打开 `MQL5/Scripts/US/ScreenUSStocks.mq5`,按 `Fn+F7` 编译
3. 确认终端已连上 **Pepperstone-Demo**
4. 把 `ScreenUSStocks` 拖到任意图表运行
5. 结果:`MQL5/Files/reliability_ranking.csv`

首轮约 10 来分钟(81 只标的 × ADF/Hurst/滚动回撤 + 补历史数据),
之后有缓存会明显变快。日志里出现 `script ScreenUSStocks ... removed` 才算结束。

## 看进度

工具箱 → **专家/Experts** 标签会逐只打印。若最后是
`有效数据不足 2 只`,按打印出来的排查方向检查连接与区间即可。
