//+------------------------------------------------------------------+
//|                                              MeanReversionEA.mq5 |
//|  均值回归回测 EA —— 配套「美股可靠性选股」结果                     |
//|                                                                  |
//|  逻辑：                                                            |
//|    1) 对每只标的算 z = (收盘 − SMA) / StdDev（用已收盘的 K 线）    |
//|    2) z ≤ 入场阈值 → 市价买入（只做多）                            |
//|    3) 出场：z ≥ 出场阈值 / 回到均值止盈 / 持仓超时 / ATR 止损      |
//|    4) 仓位按“单笔风险 % 净值”反推手数，并受保证金上限约束          |
//|                                                                  |
//|  用法：把本 EA 挂到策略测试器里跑。InpSymbols 留空 = 只测图表品种； |
//|        填逗号分隔的代码列表 = 组合回测（MT5 会自动加载其它品种历史） |
//+------------------------------------------------------------------+
#property copyright "FX Strategy Lab"
#property version   "1.00"
#property description "z-score 均值回归回测（只做多），可直接在 MT5 策略测试器运行"

#include <Trade\Trade.mqh>

//--- 标的
input group "=== 标的 ==="
input string          InpSymbols      = "";          // 逗号分隔；留空=只用当前图表品种
input ENUM_TIMEFRAMES InpTF           = PERIOD_M30;  // 信号周期

//--- 信号
input group "=== 信号 ==="
input int             InpZWindow      = 96;          // 均值/标准差窗口(根)
input double          InpEntryZ       = -1.5;        // 入场:z ≤ 该值
input double          InpExitZ        = 0.0;         // 出场:z ≥ 该值
input bool            InpTPatMean     = true;        // 止盈挂在均值上
input int             InpMaxHoldBars  = 60;          // 最长持仓(根)；0=不限
input int             InpMinGapBars   = 2;           // 两次入场最小间隔(根)

//--- 风控
input group "=== 风控 ==="
input double          InpRiskPct      = 1.0;         // 每笔风险(%净值)
input int             InpATRPeriod    = 14;          // ATR 周期
input double          InpStopATR      = 3.0;         // 止损 = N × ATR
input double          InpLotsFixed    = 0.0;         // >0 → 固定手数(忽略风险%)
input int             InpMaxSpreadPts = 0;           // 点差上限(点)；0=不限

//--- 其他
input group "=== 其他 ==="
input long            InpMagic        = 20261005;    // Magic
input bool            InpVerbose      = true;        // 打印日志

//--- 全局
CTrade   g_trade;
string   g_sym[];          // 标的
int      g_hMA[];          // 均线句柄
int      g_hSD[];          // 标准差句柄
int      g_hATR[];         // ATR 句柄
datetime g_lastBar[];      // 上一处理过的 K 线时间
datetime g_lastEntry[];    // 上次入场时间

//+------------------------------------------------------------------+
//| 解析标的列表                                                      |
//+------------------------------------------------------------------+
int ParseSymbols(const string list, string &out[])
{
   ArrayResize(out, 0);
   string s = list;
   StringTrimLeft(s);
   StringTrimRight(s);
   if(s == "")
   {
      ArrayResize(out, 1);
      out[0] = _Symbol;
      return 1;
   }

   string parts[];
   int n = StringSplit(s, ',', parts);
   for(int i = 0; i < n; i++)
   {
      string t = parts[i];
      StringTrimLeft(t);
      StringTrimRight(t);
      if(t == "")
         continue;
      int m = ArraySize(out);
      ArrayResize(out, m + 1);
      out[m] = t;
   }
   if(ArraySize(out) == 0)
   {
      ArrayResize(out, 1);
      out[0] = _Symbol;
   }
   return ArraySize(out);
}

//+------------------------------------------------------------------+
//| 手数规范化                                                        |
//+------------------------------------------------------------------+
double NormalizeLots(const string sym, double lots)
{
   double minL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;

   int digits = 0;
   double s = step;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 1e-9)
   {
      s *= 10.0;
      digits++;
   }

   lots = MathFloor(lots / step) * step;
   if(lots < minL)
      lots = minL;
   if(lots > maxL)
      lots = maxL;
   return NormalizeDouble(lots, digits);
}

//+------------------------------------------------------------------+
//| 按“单笔风险 %”计算手数                                            |
//+------------------------------------------------------------------+
double CalcLots(const string sym, double entry, double sl)
{
   if(InpLotsFixed > 0.0)
      return NormalizeLots(sym, InpLotsFixed);

   double stopDist = MathAbs(entry - sl);
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(stopDist <= 0.0 || tickSize <= 0.0 || tickVal <= 0.0)
      return NormalizeLots(sym, SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN));

   double lossPerLot = stopDist / tickSize * tickVal;   // 每 1 手打止损亏多少钱
   if(lossPerLot <= 0.0)
      return NormalizeLots(sym, SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN));

   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100.0;
   double lots = riskMoney / lossPerLot;

   // 保证金上限：最多用掉 90% 可用保证金
   double margin = 0.0;
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(lots > 0.0 && freeMargin > 0.0 &&
      OrderCalcMargin(ORDER_TYPE_BUY, sym, lots, entry, margin) &&
      margin > 0.0 && margin > freeMargin * 0.9)
      lots = lots * (freeMargin * 0.9 / margin);

   return NormalizeLots(sym, lots);
}

//+------------------------------------------------------------------+
//| 找该标的的持仓(返回 ticket,0=没有)                              |
//+------------------------------------------------------------------+
ulong FindPosition(const string sym)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == sym &&
         (long)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return ticket;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| 取最新一根已收盘 K 线的指标                                       |
//+------------------------------------------------------------------+
bool ReadSignals(const int idx, double &ma, double &sd, double &atr, double &closep)
{
   double b[1];
   if(CopyBuffer(g_hMA[idx],  0, 1, 1, b) <= 0) return false;
   ma = b[0];
   if(CopyBuffer(g_hSD[idx],  0, 1, 1, b) <= 0) return false;
   sd = b[0];
   if(CopyBuffer(g_hATR[idx], 0, 1, 1, b) <= 0) return false;
   atr = b[0];
   closep = iClose(g_sym[idx], InpTF, 1);
   return (closep > 0.0);
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(!MQLInfoInteger(MQL_TESTER) && InpVerbose)
      Print("提示：建议在策略测试器里运行本 EA 做回测。");

   int n = ParseSymbols(InpSymbols, g_sym);
   ArrayResize(g_hMA, n);
   ArrayResize(g_hSD, n);
   ArrayResize(g_hATR, n);
   ArrayResize(g_lastBar, n);
   ArrayResize(g_lastEntry, n);

   int ok = 0;
   for(int i = 0; i < n; i++)
   {
      string sym = g_sym[i];
      if(!SymbolSelect(sym, true))
      {
         PrintFormat("标的不存在，跳过：%s", sym);
         g_hMA[i] = INVALID_HANDLE; g_hSD[i] = INVALID_HANDLE; g_hATR[i] = INVALID_HANDLE;
         continue;
      }
      g_hMA[i]  = iMA(sym, InpTF, InpZWindow, 0, MODE_SMA, PRICE_CLOSE);
      g_hSD[i]  = iStdDev(sym, InpTF, InpZWindow, 0, MODE_SMA, PRICE_CLOSE);
      g_hATR[i] = iATR(sym, InpTF, InpATRPeriod);
      g_lastBar[i] = 0;
      g_lastEntry[i] = 0;
      if(g_hMA[i] == INVALID_HANDLE || g_hSD[i] == INVALID_HANDLE || g_hATR[i] == INVALID_HANDLE)
      {
         PrintFormat("指标创建失败：%s", sym);
         continue;
      }
      ok++;
   }

   if(ok == 0)
   {
      Print("没有可用标的。");
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   PrintFormat("MeanReversionEA 就绪：标的 %d 个，周期 %s，z 窗口 %d，入场 %.2f，出场 %.2f，止损 %.1f×ATR，风险 %.2f%%",
               ok, EnumToString(InpTF), InpZWindow, InpEntryZ, InpExitZ, InpStopATR, InpRiskPct);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < ArraySize(g_hMA); i++)
   {
      if(g_hMA[i]  != INVALID_HANDLE) IndicatorRelease(g_hMA[i]);
      if(g_hSD[i]  != INVALID_HANDLE) IndicatorRelease(g_hSD[i]);
      if(g_hATR[i] != INVALID_HANDLE) IndicatorRelease(g_hATR[i]);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   for(int i = 0; i < ArraySize(g_sym); i++)
   {
      if(g_hMA[i] == INVALID_HANDLE)
         continue;

      string sym = g_sym[i];

      // 只在新 K 线处理一次
      datetime t0 = iTime(sym, InpTF, 0);
      if(t0 == 0 || t0 == g_lastBar[i])
         continue;
      g_lastBar[i] = t0;

      if(Bars(sym, InpTF) < InpZWindow + 5)
         continue;

      double ma, sd, atr, closep;
      if(!ReadSignals(i, ma, sd, atr, closep))
         continue;

      double z = (sd > 0.0) ? (closep - ma) / sd : 0.0;

      //---- 1) 已有持仓：判断出场
      ulong ticket = FindPosition(sym);
      if(ticket > 0)
      {
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         int barsHeld = (int)((t0 - openTime) / PeriodSeconds(InpTF));

         if(z >= InpExitZ)
         {
            if(g_trade.PositionClose(ticket))
               if(InpVerbose) PrintFormat("%s 出场(z=%.2f)", sym, z);
         }
         else if(InpMaxHoldBars > 0 && barsHeld >= InpMaxHoldBars)
         {
            if(g_trade.PositionClose(ticket))
               if(InpVerbose) PrintFormat("%s 出场(超时 %d 根)", sym, barsHeld);
         }
         continue;
      }

      //---- 2) 空仓：判断入场
      if(z > InpEntryZ)
         continue;

      if(InpMinGapBars > 0 && g_lastEntry[i] > 0)
      {
         int gap = (int)((t0 - g_lastEntry[i]) / PeriodSeconds(InpTF));
         if(gap < InpMinGapBars)
            continue;
      }

      double ask  = SymbolInfoDouble(sym, SYMBOL_ASK);
      double bid  = SymbolInfoDouble(sym, SYMBOL_BID);
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(ask <= 0.0 || point <= 0.0)
         continue;

      if(InpMaxSpreadPts > 0 && (ask - bid) / point > InpMaxSpreadPts)
         continue;

      int stops = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
      double minDist = stops * point;

      double sl = ask - InpStopATR * atr;
      if(ask - sl < minDist)
         sl = ask - minDist;
      sl = NormalizeDouble(sl, digits);
      if(sl >= ask)
         continue;

      double tp = 0.0;
      if(InpTPatMean && ma > ask + minDist)
         tp = NormalizeDouble(ma, digits);

      double lots = CalcLots(sym, ask, sl);
      if(lots <= 0.0)
         continue;

      if(g_trade.Buy(lots, sym, 0.0, sl, tp, "MR"))
      {
         g_lastEntry[i] = t0;
         if(InpVerbose)
            PrintFormat("%s 入场 z=%.2f 手数=%.2f SL=%s TP=%s",
                        sym, z, lots, DoubleToString(sl, digits), DoubleToString(tp, digits));
      }
      else if(InpVerbose)
      {
         PrintFormat("%s 入场失败 ret=%d (%s)", sym, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
//| 自定义优化准则：收益 / 相对回撤 × 盈亏比                          |
//+------------------------------------------------------------------+
double OnTester()
{
   double profit = TesterStatistics(STAT_PROFIT);
   double dd     = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   if(dd <= 0.0)
      return profit;
   return (profit / dd) * (pf > 0.0 ? pf : 1.0);
}
//+------------------------------------------------------------------+
