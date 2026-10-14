//+------------------------------------------------------------------+
//|                                     CrossSectionalRankEA.mq5     |
//|  截面排序 + 滚动调仓回测 EA —— 配套「美股选股系统」                |
//|                                                                  |
//|  v2.10 (2026-10-12):                                             |
//|    · 新增市场闸门:基准指数日线趋势(收盘 vs N 日均线),可选叠加     |
//|      池内宽度;风险开启时按系数降仓或空仓(解决下跌段暴露)。        |
//|    · 基本面快照支持扩池版(_p30,池 63~67 只)。                    |
//|                                                                  |
//|  v2 (2026-10-09):                                                |
//|    · 稳定性评分排序已移除(实证为负贡献),旧版与旧参数集见          |
//|      archive/2026-10-09_评分维度/。                               |
//|    · 排序改为两档: 0 = 纯动量, 1 = 动量 + 质量(fund_pct)混合。    |
//|    · 少于 TopN 只通过"一类"时,可从二类按分数补足。                 |
//|    · 基准模式:全池有效标等权,用于"什么都不选"的对照。              |
//|                                                                  |
//|  逻辑(全部只用"仅过去"的数据,无未来函数):                       |
//|    每个调仓日重算 20 日滚动回撤 / 回撤回升状态 → 一类/二类;        |
//|    动量分位 pct_mom(候选集内) → S=(1-w)·pct_mom + w·fund_pct;     |
//|    取前 N 名 → 等权 → 持有到下一个调仓日再平衡。只做多。           |
//+------------------------------------------------------------------+
#property copyright "FX Strategy Lab"
#property version   "2.10"
#property description "截面排序 + 市场闸门 + 定期调仓的组合回测（只做多）"

#include <Trade\Trade.mqh>

//=========================== 输入 ===========================
input group "=== 标的与基准 ==="
input string          InpSymbols       = "KO,MCD,V,TTWO,EW,TJX,MA,DE,GD,EEM,PEP,SCHW,LOW,MSFT,XOM,NEE,MMM,JNJ,ZM,BKNG,F,IBM,ROST,RTX,IWM,JPM,DG,BLK,LMT,HD,PNC,ULTA,U,GOOGL,GOOG,DVN,GE,EMR,NXPI,WFC,FCX,DIS,WMT,XLE,MPWR,MPC,KLAC,PFE,USB,SNOW,ISRG,NEM,NET,META,ON,LYFT,NKE,MCHP,WSM,QCOM,RIVN,MS,GM,UAL,GS,LRCX,ROKU,DELL,HAL,FSLR,SHOP,TSM,TMO,NVDA,BBY,WBD,LLY,SWKS,INTC,MU,MRK"; // 全池 81 只(基础代码)
input string          InpBenchmark     = "US500";     // 基准(算Beta)
input ENUM_TIMEFRAMES InpTF            = PERIOD_M30;  // 数据周期
input bool            InpPrefer24H     = false;       // 优先用24小时合约(.US-24)
input bool            InpUseFundFilter = true;        // 用 fundamentals.csv 的 fund_keep 过滤标的
input string          InpFundFile      = "fundamentals.csv"; // 基本面快照文件名(Common/Files)
input bool            InpPoolFromFile  = true;        // 股票池直接取自快照(fund_keep=1);关掉才用 InpSymbols
input bool            InpUseDividend   = true;        // 内部累计股息并在结束时报告
// v2(2026-10-09):稳定性评分排序已移除,旧版见 archive/2026-10-09_评分维度/
input int             InpRankMode      = 1;           // 0=纯动量,1=动量+质量混合(默认)
input int             InpRankRetBars   = 1500;        // 动量回看K线数
input double          InpQualityWeight = 0.5;         // 混合排序中的质量分权重 w(0~1);w=0 等价于纯动量
input bool            InpBenchmarkMode = false;       // 基准模式:全池有效标等权持有(不做一类过滤/TopN)
input double          InpMarginMult    = 0.5;         // 单仓保证金预算 = 净值×权重×该系数(防超配)
input double          InpContractSize  = 0.0;         // 每手股数(0=用品种规格。实测 Pepperstone 美股 CFD 就是 1 股/手)

input group "=== 调仓 ==="
input int             InpRebalanceDays = 21;          // 调仓间隔(日历天)
input int             InpTopN          = 8;           // 持有评分最高的 N 只
input int             InpWeightMode    = 0;           // 0=等权,1=按分数加权
input double          InpMaxWeightPct  = 25.0;        // 单标的权重上限(%)
input bool            InpScaleWeightsToFull = false;  // 权重裁剪后是否回补到满仓(默认否=不足部分留现金)
input double          InpAdjustTolPct  = 30.0;        // 目标手数偏离超此%才调整
input int             InpRebalHourFrom = 18;          // 调仓窗口(服务器时间)起;GMT+2/+3 都在美盘内
input int             InpRebalHourTo   = 22;          // 调仓窗口止;留 0/23 表示不限

input group "=== 评分窗口 ==="
input int             InpLookbackBars  = 1500;        // 评分回看K线数
input int             InpMinBars       = 300;         // 少于此数不参与
input int             InpRollingDays   = 20;          // 滚动回撤窗口(交易日)
input double          InpRollingThresh = 0.20;        // 滚动回撤阈值(硬过滤)
input bool            InpOnlyClassA    = true;        // 只买"一类"标的
input bool            InpFillFromClassB= true;        // 一类不足 TopN 时,从二类按分数补足(默认是)
input double          InpRecoveryRatio = 0.80;        // 回升比例(与选股脚本一致)
input double          InpRiskFree      = 0.0;         // 无风险利率(年化)
input int             InpHalfLifeCap   = 800;         // 半衰期上限

input group "=== 市场闸门(下跌段保护) ==="
input bool            InpRegimeGate     = false;      // 开启市场闸门(下跌时降仓/空仓)
input int             InpGateSMA        = 200;        // 趋势判定:基准指数日线均线周期
input double          InpGateScale      = 0.0;        // 风险开启时的仓位系数(0=空仓,0.5=半仓)
input double          InpGateBreadthMin = 0.0;        // 池内宽度下限(0=不启用);低于此值也判为风险
input int             InpGateBreadthSMA = 200;        // 宽度判定用的日线均线周期

input group "=== 其他 ==="
input long            InpMagic         = 20261006;
input bool            InpVerbose       = true;

//=========================== 全局 ===========================
CTrade g_trade;

struct DrawdownResult
{
   double maxDD;
   int    recoveryBars;
   bool   recovered;
   double currentDD;
};

string   g_pool[];        // 输入的原始代码
string   g_sym[];         // 解析后的真实品种名
int      g_n           = 0;
string   g_benchSym    = "";
int      g_barsPerYear = 0;
int      g_barsPerDay  = 13;

bool     g_valid[];
double   g_rollingMDD[];
bool     g_isClassA[];

//--- v2 排序分(稳定性评分维度已移除) ---
double   g_rankScore[];   // 本期排序分:S_i = (1-w)*pct_mom,i + w*fund_pct,i
double   g_momPct[];      // 动量在有效集内的排名分位(0~1)
double   g_fundQual[];    // 每只标的的质量分(快照 fund_pct)
bool     g_qualNA[];      // 质量分缺失(已用中位数兜底,诊断里标 qp=NA)

datetime g_lastRebalance = 0;
datetime g_lastTry = 0;              // 上次尝试调仓的时间(重试节流)
int      g_diag = INVALID_HANDLE;   // 诊断 CSV 句柄

//--- 市场闸门状态 ---
int      g_gateOnCount   = 0;       // 风险开启(=趋势向上,满仓)的调仓次数
int      g_gateOffCount  = 0;       // 风险关闭(=降仓/空仓)的调仓次数
int      g_gateNoData    = 0;       // 日线数据不足、未拦截的次数
string   g_gateWhy       = "";

//--- 基本面表 + 股息累计 ---
bool     g_fundKeep[];               // 每只标的是否通过基本面过滤
double   g_fundDY[];                 // 每只标的的股息率
datetime g_divAccFrom[];             // 上次累计股息的日期
double   g_divCash = 0.0;            // 累计股息现金
int      g_rebalanceCount = 0;       // 调仓次数
string   g_fTicker[];                // 快照里的 ticker
bool     g_fKeep[];                  // 快照里的 fund_keep
double   g_fDY[];                    // 快照里的 dividend_yield
double   g_fQual[];                  // 快照里的 fund_pct
int      g_fRows = 0;                // 快照行数

//+------------------------------------------------------------------+
//| 诊断输出：测试器日志不保存 EA 的 Print，所以写到公共文件夹         |
//| 目标：.../MetaQuotes/Terminal/Common/Files/cs_diag.csv            |
//+------------------------------------------------------------------+
void DiagRow(const string t, const string sym, const string valid, const string isA,
             const double rollMDD, const double score, const double weight,
             const double ask, const double lots, const string extra = "")
{
   if(g_diag == INVALID_HANDLE)
   {
      string names[3];
      names[0] = "cs_diag.csv";
      names[1] = "cs_diag2.csv";
      names[2] = "cs_diag3.csv";
      for(int k = 0; k < 3 && g_diag == INVALID_HANDLE; k++)
         g_diag = FileOpen(names[k], FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
      if(g_diag == INVALID_HANDLE) return;
      FileWrite(g_diag, "Time", "Symbol", "Valid", "ClassA", "RollMDD", "Score",
                "Weight", "Ask", "TargetLots", "Extra");
   }
   FileWrite(g_diag, t, sym, valid, isA,
             DoubleToString(rollMDD, 4), DoubleToString(score, 4),
             DoubleToString(weight, 4), DoubleToString(ask, 5),
             DoubleToString(lots, 2), extra);
   FileFlush(g_diag);   // 立即落盘，避免测试中断导致内容丢失
}

//+------------------------------------------------------------------+
//| 读取基本面表(Common/Files/fundamentals.csv)                       |
//| 取 fund_keep(是否通过过滤) 与 dividend_yield(股息率)              |
//+------------------------------------------------------------------+
void LoadFundFile()
{
   ArrayResize(g_fTicker, 0); ArrayResize(g_fKeep, 0); ArrayResize(g_fDY, 0);
   ArrayResize(g_fQual, 0);
   g_fRows = 0;
   int h = FileOpen(InpFundFile, FILE_READ|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
   {
      PrintFormat("!! 打不开 %s (err=%d)", InpFundFile, GetLastError());
      return;
   }
   string header = FileReadString(h);
   string cols[]; int nc = StringSplit(header, ',', cols);
   int iTk = -1, iKeep = -1, iDY = -1, iQual = -1;
   for(int c = 0; c < nc; c++)
   {
      string nm = cols[c]; StringTrimLeft(nm); StringTrimRight(nm);
      if(nm == "ticker")                 iTk = c;
      else if(nm == "fund_keep")         iKeep = c;
      else if(nm == "dividend_yield")    iDY = c;
      else if(nm == "fund_pct")          iQual = c;
   }
   if(iTk < 0 || iKeep < 0) { FileClose(h); Print("!! 快照缺少 ticker/fund_keep 列"); return; }

   while(!FileIsEnding(h))
   {
      string line = FileReadString(h);
      if(line == "") continue;
      string f[]; int nf = StringSplit(line, ',', f);
      if(nf <= iKeep || nf <= iTk) continue;
      string tk = f[iTk]; StringTrimLeft(tk); StringTrimRight(tk); StringToUpper(tk);
      int d = StringFind(tk, ".");
      if(d > 0) tk = StringSubstr(tk, 0, d);
      if(tk == "") continue;
      int m = ArraySize(g_fTicker);
      ArrayResize(g_fTicker, m+1);
      ArrayResize(g_fKeep,   m+1);
      ArrayResize(g_fDY,     m+1);
      ArrayResize(g_fQual,   m+1);
      g_fTicker[m] = tk;
      g_fKeep[m]   = (f[iKeep] == "1");
      g_fDY[m]     = (iDY >= 0 && iDY < nf) ? StringToDouble(f[iDY]) : 0.0;
      g_fQual[m]   = (iQual >= 0 && iQual < nf) ? StringToDouble(f[iQual]) : 0.0;
   }
   FileClose(h);
   g_fRows = ArraySize(g_fTicker);
   int k = 0;
   for(int i = 0; i < g_fRows; i++) if(g_fKeep[i]) k++;
   PrintFormat("基本面快照 %s:%d 行,fund_keep=1 的 %d 只", InpFundFile, g_fRows, k);
}

void MapFundToSymbols()
{
   ArrayResize(g_fundKeep, g_n);  ArrayInitialize(g_fundKeep, false);
   ArrayResize(g_fundDY,   g_n);  ArrayInitialize(g_fundDY, 0.0);
   ArrayResize(g_fundQual, g_n);  ArrayInitialize(g_fundQual, -1.0);
   ArrayResize(g_divAccFrom, g_n);
   for(int i = 0; i < g_n; i++)
   {
      g_divAccFrom[i] = 0;
      string bare = g_sym[i];
      int d = StringFind(bare, ".");
      if(d > 0) bare = StringSubstr(bare, 0, d);
      StringToUpper(bare);
      for(int j = 0; j < g_fRows; j++)
      {
         if(g_fTicker[j] != bare) continue;
         g_fundKeep[i] = g_fKeep[j];
         g_fundDY[i]   = g_fDY[j];
         g_fundQual[i] = g_fQual[j];
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| 股息累计:按 持仓市值 × 年化股息率 ÷ 365 × 持有天数                |
//| 注意:MT5 测试器不会给 CFD 补股息调整,这里只是内部记账并单独报告   |
//+------------------------------------------------------------------+
void AccrueDividends()
{
   if(!InpUseDividend) return;
   if(ArraySize(g_fundDY) != g_n || ArraySize(g_divAccFrom) != g_n) return;
   datetime now = TimeCurrent();
   for(int i = 0; i < g_n; i++)
   {
      ulong tk = FindPosition(g_sym[i]);
      if(tk == 0) { g_divAccFrom[i] = 0; continue; }
      if(g_fundDY[i] <= 0.0) continue;
      datetime from = (g_divAccFrom[i] > 0) ? g_divAccFrom[i]
                                            : (datetime)PositionGetInteger(POSITION_TIME);
      int days = (int)((now - from) / 86400);
      if(days <= 0) continue;
      double vol = PositionGetDouble(POSITION_VOLUME);
      double px  = PositionGetDouble(POSITION_PRICE_OPEN);
      double cs  = SymbolInfoDouble(g_sym[i], SYMBOL_TRADE_CONTRACT_SIZE);
      if(cs <= 0.0) cs = 1.0;
      g_divCash += vol * cs * px * g_fundDY[i] / 365.0 * days;
      g_divAccFrom[i] = now;
   }
}

//+------------------------------------------------------------------+
//| 结束后写一份运行报告(股息与设置)                                   |
//+------------------------------------------------------------------+
void WriteRunReport()
{
   int h = FileOpen("cs_run_report.csv", FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
   if(h == INVALID_HANDLE) return;
   FileWrite(h, "Item", "Value");
   FileWrite(h, "Symbols", IntegerToString(g_n));
   FileWrite(h, "RankMode", IntegerToString(InpRankMode) + (InpRankMode == 1 ? " (hybrid: momentum+quality)" : " (momentum)"));
   FileWrite(h, "UseFundFilter", InpUseFundFilter ? "1" : "0");
   FileWrite(h, "UseDividend", InpUseDividend ? "1" : "0");
   FileWrite(h, "Rebalances", IntegerToString(g_rebalanceCount));
   FileWrite(h, "DividendCash", DoubleToString(g_divCash, 2));
   FileWrite(h, "ProfitCalcCurrency", AccountInfoString(ACCOUNT_CURRENCY));
   FileWrite(h, "ContractSizeOverride", DoubleToString(InpContractSize, 2));
   FileWrite(h, "MaxWeightPct", DoubleToString(InpMaxWeightPct, 1));
   FileWrite(h, "ScaleWeightsToFull", InpScaleWeightsToFull ? "1" : "0");
   FileWrite(h, "Benchmark", InpBenchmarkMode ? "1" : "0");
   FileWrite(h, "QualityWeight", DoubleToString(InpQualityWeight, 2));
   FileWrite(h, "FillFromClassB", InpFillFromClassB ? "1" : "0");
   FileWrite(h, "RankRetBars", IntegerToString(InpRankRetBars));
   FileWrite(h, "RegimeGate", InpRegimeGate ? "1" : "0");
   FileWrite(h, "GateSMA", IntegerToString(InpGateSMA));
   FileWrite(h, "GateScale", DoubleToString(InpGateScale, 2));
   FileWrite(h, "GateBreadthMin", DoubleToString(InpGateBreadthMin, 2));
   FileWrite(h, "GateOnRebalances", IntegerToString(g_gateOnCount));
   FileWrite(h, "GateOffRebalances", IntegerToString(g_gateOffCount));
   FileWrite(h, "GateNoData", IntegerToString(g_gateNoData));
   FileClose(h);
   PrintFormat("运行报告:标的 %d | %s | 调仓 %d 次 | 累计股息现金 %.2f",
               g_n, (InpBenchmarkMode ? "基准模式" : (InpRankMode == 1 ? "动量+质量" : "纯动量")),
               g_rebalanceCount, g_divCash);
}

//=========================== 工具 ===========================
int CalcBarsPerDay(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return 390;
      case PERIOD_M5:  return 78;
      case PERIOD_M15: return 26;
      case PERIOD_M30: return 13;    // 美股 6.5 小时
      case PERIOD_H1:  return 7;
      case PERIOD_H4:  return 2;
      case PERIOD_D1:  return 1;
      default:         return 13;
   }
}

double StdDev(const double &arr[], int start, int n)
{
   if(n < 2) return 0.0;
   double sum = 0.0;
   for(int i = 0; i < n; i++) sum += arr[start+i];
   double mean = sum / n;
   double ss = 0.0;
   for(int i = 0; i < n; i++) { double d = arr[start+i] - mean; ss += d*d; }
   return MathSqrt(ss / n);
}

bool LinearRegression(const double &x[], const double &y[], int n,
                      double &alpha, double &beta, double &seBeta, double &tStat)
{
   if(n < 3) return false;
   double sx=0, sy=0, sxy=0, sxx=0;
   for(int i = 0; i < n; i++) { sx+=x[i]; sy+=y[i]; sxy+=x[i]*y[i]; sxx+=x[i]*x[i]; }
   double mx = sx/n, my = sy/n;
   double sxxc = sxx - n*mx*mx;
   if(MathAbs(sxxc) < 1e-12) return false;
   beta  = (sxy - n*mx*my) / sxxc;
   alpha = my - beta*mx;
   double rss = 0.0;
   for(int i = 0; i < n; i++) { double e = y[i] - (alpha + beta*x[i]); rss += e*e; }
   double dof = n - 2.0;
   if(dof <= 0.0) return false;
   seBeta = MathSqrt((rss/dof) / sxxc);
   tStat  = (seBeta > 1e-12) ? beta/seBeta : 0.0;
   return true;
}

bool CalcLogReturns(const double &prices[], int n, double &returns[])
{
   if(n < 2) return false;
   int m = n - 1;
   ArrayResize(returns, m);
   for(int i = 0; i < m; i++)
   {
      if(prices[i] <= 0.0 || prices[i+1] <= 0.0) return false;
      returns[i] = MathLog(prices[i+1] / prices[i]);
   }
   return true;
}

double CalcRollingMDD(const double &prices[], int n, int windowBars)
{
   if(n < windowBars || windowBars < 2) return 0.0;
   double worst = 0.0;
   for(int start = 0; start <= n - windowBars; start++)
   {
      double peak = prices[start], maxDD = 0.0;
      for(int i = start+1; i < start+windowBars; i++)
      {
         if(prices[i] > peak) peak = prices[i];
         else { double dd = 1.0 - prices[i]/peak; if(dd > maxDD) maxDD = dd; }
      }
      if(maxDD > worst) worst = maxDD;
   }
   return worst;
}

double CalcVolConvergence(const double &returns[], int n)
{
   if(n < 30) return 1.0;
   double all = StdDev(returns, 0, n);
   if(all < 1e-12) return 1.0;
   int rc = n/3; if(rc < 10) rc = 10;
   return StdDev(returns, n-rc, rc) / all;
}

bool CalcHalfLife(const double &prices[], int n, double &halfLife, double &tStat, bool &valid)
{
   valid = false; halfLife = 0.0; tStat = 0.0;
   if(n < 30) return false;
   int m = n - 1;
   double dP[];
   double pLag[];
   ArrayResize(dP, m); ArrayResize(pLag, m);
   for(int i = 0; i < m; i++) { dP[i] = prices[i+1]-prices[i]; pLag[i] = prices[i]; }
   double a, b, se, t;
   if(!LinearRegression(pLag, dP, m, a, b, se, t)) return false;
   tStat = t;
   double lambda = b;
   if(lambda < 0.0) { halfLife = -MathLog(2.0)/lambda; valid = true; }
   return true;
}

bool CalcDrawdown(const double &prices[], int n, DrawdownResult &res)
{
   res.maxDD = 0.0; res.recoveryBars = 0; res.recovered = false; res.currentDD = 0.0;
   if(n < 2) return false;
   double peak = prices[0]; int peakIdx = 0;
   double maxDD = 0.0; int ddStart = 0, ddBottom = 0;
   for(int i = 1; i < n; i++)
   {
      if(prices[i] > peak) { peak = prices[i]; peakIdx = i; }
      else { double dd = 1.0 - prices[i]/peak; if(dd > maxDD) { maxDD = dd; ddStart = peakIdx; ddBottom = i; } }
   }
   res.maxDD = maxDD;
   double peakBefore = prices[ddStart], bottom = prices[ddBottom];
   double target = bottom + (peakBefore - bottom) * InpRecoveryRatio;
   int recIdx = -1;
   for(int i = ddBottom+1; i < n; i++) if(prices[i] >= target) { recIdx = i; break; }
   if(recIdx >= 0) { res.recovered = true; res.recoveryBars = recIdx - ddBottom; }
   else            { res.recovered = false; res.recoveryBars = n - 1 - ddBottom; }
   double peakAll = prices[0];
   for(int i = 1; i < n; i++) if(prices[i] > peakAll) peakAll = prices[i];
   res.currentDD = 1.0 - prices[n-1]/peakAll;
   return true;
}

bool CalcSortino(const double &returns[], int n, double rf,
                 double &sortino, double &annualReturn, double &downVolAnnual)
{
   sortino = 0.0; annualReturn = 0.0; downVolAnnual = 0.0;
   if(n < 20) return false;
   double sum = 0.0;
   for(int i = 0; i < n; i++) sum += returns[i];
   annualReturn = (sum/n) * g_barsPerYear;
   double ss = 0.0; int cnt = 0;
   for(int i = 0; i < n; i++) if(returns[i] < 0.0) { ss += returns[i]*returns[i]; cnt++; }
   if(cnt < 2) return false;
   downVolAnnual = MathSqrt(ss/cnt) * MathSqrt((double)g_barsPerYear);
   if(downVolAnnual < 1e-12) return false;
   sortino = (annualReturn - rf) / downVolAnnual;
   return true;
}

bool CalcCalmar(double annualReturn, double maxDD, double &calmar)
{
   calmar = 0.0;
   if(maxDD < 1e-6) return false;
   calmar = annualReturn / maxDD;
   return true;
}

bool CalcBeta(const double &sRet[], const double &iRet[], int n, double &beta)
{
   beta = 0.0;
   if(n < 20) return false;
   double ms=0, mi=0;
   for(int i = 0; i < n; i++) { ms += sRet[i]; mi += iRet[i]; }
   ms /= n; mi /= n;
   double cov=0, var=0;
   for(int i = 0; i < n; i++) { cov += (sRet[i]-ms)*(iRet[i]-mi); var += (iRet[i]-mi)*(iRet[i]-mi); }
   if(var < 1e-12) return false;
   beta = cov/var;
   return true;
}

//===== 品种/基准名解析 =====
// 只按「名字是否存在」解析，不看历史数据是否就绪
// （测试器 OnInit 阶段数据往往还没同步，用数据判断会误判、丢标的）
string ResolveSymbol(const string want)
{
   string base = want;
   int dot = StringFind(base, ".");
   if(dot > 0) base = StringSubstr(base, 0, dot);
   StringToUpper(base);

   string cands[3];
   if(InpPrefer24H)
   {
      cands[0] = base + ".US-24";   // 24小时合约，任何时段都能成交
      cands[1] = want;
      cands[2] = base + ".US";
   }
   else
   {
      cands[0] = want;              // 先原样
      cands[1] = base + ".US";
      cands[2] = base + ".US-24";
   }

   int total = SymbolsTotal(false);
   for(int c = 0; c < 3; c++)
   {
      if(cands[c] == "") continue;
      string w = cands[c];
      StringToUpper(w);
      for(int i = 0; i < total; i++)
      {
         string cand = SymbolName(i, false);
         string up = cand; StringToUpper(up);
         if(up == w)
            return cand;
      }
   }
   // 纯代码兜底（TMGM 等）
   for(int i = 0; i < total; i++)
   {
      string cand = SymbolName(i, false);
      if(cand == base) return cand;
   }
   return want;   // 名字没匹配到也不丢标的，后面按数据可用性再判
}

string ResolveBenchmark(const string want)
{
   string cands[] = { want, "US500", "SP500m", "SPX500", "SP500", "ND100m", "NAS100" };
   int total = SymbolsTotal(false);
   for(int c = 0; c < ArraySize(cands); c++)
   {
      if(cands[c] == "") continue;
      string w = cands[c]; StringToUpper(w);
      for(int i = 0; i < total; i++)
      {
         string up = SymbolName(i, false); StringToUpper(up);
         if(up == w) return SymbolName(i, false);
      }
   }
   return want;
}

//===== 截面排名分位 =====
// pct_i = 1 - (rank_i - 1)/(cnt - 1):最好=1,最差=0;并列取平均秩;cnt=1 时取 1。
// values[] 只对 mask=true 的标的有意义。
void RankPercentile(const double &values[], const bool &mask[], int n, double &dst[])
{
   ArrayResize(dst, n); ArrayInitialize(dst, 0.0);
   int idx[]; ArrayResize(idx, 0);
   for(int i = 0; i < n; i++)
      if(mask[i]) { int m = ArraySize(idx); ArrayResize(idx, m+1); idx[m] = i; }
   int cnt = ArraySize(idx);
   if(cnt <= 0) return;
   if(cnt == 1) { dst[idx[0]] = 1.0; return; }

   // 按值降序排(值越大越好)
   for(int a = 0; a < cnt-1; a++)
      for(int b = 0; b < cnt-1-a; b++)
         if(values[idx[b]] < values[idx[b+1]]) { int t=idx[b]; idx[b]=idx[b+1]; idx[b+1]=t; }

   // 并列取平均秩,再折算成 0~1 分位
   int a = 0;
   while(a < cnt)
   {
      int b = a;
      while(b+1 < cnt && MathAbs(values[idx[b+1]] - values[idx[a]]) < 1e-12) b++;
      double avgRank = ((double)(a+1) + (double)(b+1)) / 2.0;   // 1..cnt
      double pct = 1.0 - (avgRank - 1.0) / ((double)cnt - 1.0);
      if(pct < 0.0) pct = 0.0;
      if(pct > 1.0) pct = 1.0;
      for(int k = a; k <= b; k++) dst[idx[k]] = pct;
      a = b + 1;
   }
}

//=========================== 初始化 ===========================
int ParseSymbols(const string list, string &out[])
{
   ArrayResize(out, 0);
   string s = list; StringTrimLeft(s); StringTrimRight(s);
   if(s == "") { ArrayResize(out,1); out[0] = _Symbol; return 1; }
   string parts[];
   int n = StringSplit(s, ',', parts);
   for(int i = 0; i < n; i++)
   {
      string t = parts[i]; StringTrimLeft(t); StringTrimRight(t);
      if(t == "") continue;
      int m = ArraySize(out); ArrayResize(out, m+1); out[m] = t;
   }
   if(ArraySize(out) == 0) { ArrayResize(out,1); out[0] = _Symbol; }
   return ArraySize(out);
}

int OnInit()
{
   //---- 测试器自检:利润计算必须是"按资金/存款货币",不能是"按点数" ----
   // 按点数模式(=测试器设置里的"点数/Pips")会让每笔盈亏相对名义金额放大 100 倍,
   // 结果必然是几天内爆仓,而脚本本身没有问题。
   string acctCur = AccountInfoString(ACCOUNT_CURRENCY);
   PrintFormat("测试器账户: 币种='%s' 余额=%.2f 杠杆=%d",
               acctCur, AccountInfoDouble(ACCOUNT_BALANCE),
               (int)AccountInfoInteger(ACCOUNT_LEVERAGE));
   if(StringLen(acctCur) == 0)
      Print("!!!! 警告:测试器当前按【点数】计算利润(账户币种为空)。"
            "请到 测试器 -> 设置 -> 存款/利润计算,把 '点数' 改回 'USD'(按资金),"
            "否则盈亏会被放大 100 倍,账户几天内必被强平。");

   g_barsPerDay  = CalcBarsPerDay(InpTF);
   g_barsPerYear = g_barsPerDay * 252;

   //---- 先读基本面快照:它同时提供"股票池"和过滤/股息数据 ----
   LoadFundFile();

   //---- 股票池:默认直接取自快照里 fund_keep=1 的标的 ----
   //(不把 81 个代码塞进输入框 —— MT5 的字符串输入有长度上限,会被截断)
   if(InpPoolFromFile && g_fRows > 0)
   {
      ArrayResize(g_pool, 0);
      for(int i = 0; i < g_fRows; i++)
         if(g_fKeep[i])
         {
            int m = ArraySize(g_pool);
            ArrayResize(g_pool, m+1);
            g_pool[m] = g_fTicker[i];
         }
      PrintFormat("股票池取自快照 %s:%d 只", InpFundFile, ArraySize(g_pool));
   }
   else
   {
      ParseSymbols(InpSymbols, g_pool);
   }

   int n0 = ArraySize(g_pool);
   ArrayResize(g_sym, n0);
   int n = 0;
   for(int i = 0; i < n0; i++)
   {
      string sym = ResolveSymbol(g_pool[i]);
      bool sel = (sym != "") && SymbolSelect(sym, true);
      DiagRow("resolve", g_pool[i] + "->" + sym, sel ? "1" : "0", "-",
              0.0, 0.0, 0.0, (sym != "" ? SymbolInfoDouble(sym, SYMBOL_ASK) : 0.0), 0.0);
      // 不再因为 SymbolSelect 失败而丢标的：有些环境这里会返回 false，但数据仍可读
      if(sym == "")
      {
         PrintFormat("解析失败，跳过：%s", g_pool[i]);
         continue;
      }
      g_sym[n] = sym;
      n++;
   }
   ArrayResize(g_sym, n);
   g_n = n;
   if(g_n == 0) { Print("没有可用标的。"); return INIT_FAILED; }

   //---- 把快照里的 keep/股息率映射到已解析的标的,再做过滤 ----
   MapFundToSymbols();
   if(InpUseFundFilter)
   {
      int m = 0;
      for(int i = 0; i < g_n; i++)
         if(g_fundKeep[i])
         {
            g_sym[m] = g_sym[i]; g_fundDY[m] = g_fundDY[i]; g_fundQual[m] = g_fundQual[i]; m++;
         }
      PrintFormat("基本面过滤: %d 只 -> %d 只", g_n, m);
      ArrayResize(g_sym, m);
      ArrayResize(g_fundDY, m);
      ArrayResize(g_fundQual, m);
      ArrayResize(g_fundKeep, m);
      g_n = m;
      if(g_n == 0) { Print("基本面过滤后没有可用标的。"); return INIT_FAILED; }
   }
   ArrayResize(g_divAccFrom, g_n);

   ArrayResize(g_valid, g_n);      ArrayInitialize(g_valid, false);
   ArrayResize(g_rankScore, g_n);  ArrayInitialize(g_rankScore, 0.0);
   ArrayResize(g_momPct, g_n);     ArrayInitialize(g_momPct, 0.0);
   ArrayResize(g_qualNA, g_n);     ArrayInitialize(g_qualNA, true);
   ArrayResize(g_rollingMDD, g_n); ArrayInitialize(g_rollingMDD, 1.0);
   ArrayResize(g_isClassA, g_n);   ArrayInitialize(g_isClassA, false);

   g_benchSym = ResolveBenchmark(InpBenchmark);
   SymbolSelect(g_benchSym, true);

   // ==== 预热：强制让终端/测试器加载这些品种的数据 ====
   // 只用于激活品种，不判断返回值（OnInit 阶段数据往往还没同步，
   // 但这次调用会让测试器把这些品种纳入数据加载范围）
   double warm[];
   datetime warmT[];
   for(int i = 0; i < g_n; i++)
   {
      CopyClose(g_sym[i], InpTF, 0, 2, warm);
      CopyTime(g_sym[i], InpTF, 0, 2, warmT);
   }
   CopyClose(g_benchSym, InpTF, 0, 2, warm);
   CopyTime(g_benchSym, InpTF, 0, 2, warmT);

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   PrintFormat("CrossSectionalRankEA v2 就绪：标的 %d 只 | 周期 %s | 回看 %d 根 | 调仓 %d 天 | TopN %d | 权重模式 %d | 一类过滤 %s | 基准 %s",
               g_n, EnumToString(InpTF), InpLookbackBars, InpRebalanceDays, InpTopN,
               InpWeightMode, InpOnlyClassA ? "是" : "否", g_benchSym);
   PrintFormat("排序: %s | 质量权重 w=%.2f | 二类补足=%s | 基准模式=%s",
               (InpRankMode == 1 ? "动量+质量混合" : "纯动量"), InpQualityWeight,
               InpFillFromClassB ? "是" : "否", InpBenchmarkMode ? "是" : "否");
   PrintFormat("市场闸门: %s | 均线 %d 日 | 风险系数 %.2f | 宽度下限 %.2f",
               InpRegimeGate ? "开启" : "关闭", InpGateSMA, InpGateScale, InpGateBreadthMin);
   for(int i = 0; i < g_n; i++)
      PrintFormat("  [%d] %s  (原始 %s)", i+1, g_sym[i], g_pool[i]);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   AccrueDividends();          // 收尾:把最后一段持有期的股息补记
   WriteRunReport();
   if(g_diag != INVALID_HANDLE)
   {
      FileClose(g_diag);
      g_diag = INVALID_HANDLE;
   }
}

//=========================== 打分 ===========================
// 在 .US 与 .US-24 之间切换（同一只股票的两套合约）
string AltSymbol(const string sym)
{
   int p = StringFind(sym, ".US-24");
   if(p > 0) return StringSubstr(sym, 0, p + 3);   // X.US-24 -> X.US
   p = StringFind(sym, ".US");
   if(p > 0) return sym + "-24";
   return "";
}

bool ComputeStats(const int i, double &tStat, double &halfLife, bool &hlValid,
                  DrawdownResult &dd, double &rollMDD, double &volConv,
                  double &sortino, double &calmar, double &beta)
{
   string sym = g_sym[i];
   double   closes[];
   datetime times[];
   int n = 0, nt = 0;
   bool ok = false;
   string tries[2];
   tries[0] = sym;
   tries[1] = AltSymbol(sym);      // .US <-> .US-24 互为备选
   for(int t = 0; t < 2; t++)
   {
      if(tries[t] == "") continue;
      n  = CopyClose(tries[t], InpTF, 0, InpLookbackBars, closes);
      nt = CopyTime(tries[t], InpTF, 0, InpLookbackBars, times);
      if(n >= InpMinBars && nt == n)
      {
         sym = tries[t];
         g_sym[i] = sym;           // 记住这个合约有数据
         ok = true;
         break;
      }
   }
   if(!ok) return false;
   ArraySetAsSeries(closes, false);
   ArraySetAsSeries(times, false);

   double ret[];
   if(!CalcLogReturns(closes, n, ret)) return false;
   int rn = ArraySize(ret);

   int rollBars = InpRollingDays * g_barsPerDay;
   rollMDD  = CalcRollingMDD(closes, n, rollBars);
   volConv  = CalcVolConvergence(ret, rn);

   double lambda = 0.0;
   hlValid = false;
   if(!CalcHalfLife(closes, n, halfLife, tStat, hlValid)) { tStat = 0.0; halfLife = 9999.0; }
   if(!hlValid || halfLife > (double)InpHalfLifeCap) halfLife = 9999.0;

   if(!CalcDrawdown(closes, n, dd)) return false;

   double annual = 0.0, dv = 0.0;
   if(!CalcSortino(ret, rn, InpRiskFree, sortino, annual, dv)) sortino = -999.0;
   if(!CalcCalmar(annual, dd.maxDD, calmar)) calmar = -999.0;

   // Beta(与基准对齐时间戳)
   beta = 1.0;
   double   idxCloses[];
   datetime idxTimes[];
   int ni  = CopyClose(g_benchSym, InpTF, 0, InpLookbackBars, idxCloses);
   int nit = CopyTime(g_benchSym, InpTF, 0, InpLookbackBars, idxTimes);
   if(ni >= InpMinBars && nit == ni)
   {
      ArraySetAsSeries(idxCloses, false);
      ArraySetAsSeries(idxTimes, false);
      double sr[];
      double ir[];
      ArrayResize(sr, n); ArrayResize(ir, n);
      int matched = 0;
      int k = 0;         // 指向 idxTimes 的游标
      int prevK = -1;    // 上一根股票K线在 idxTimes 里的位置
      for(int j = 1; j < n; j++)
      {
         while(k < ni && idxTimes[k] < times[j]) k++;
         int curK = (k < ni && idxTimes[k] == times[j]) ? k : -1;
         if(curK >= 0 && prevK >= 0 && curK != prevK && idxCloses[prevK] > 0.0)
         {
            sr[matched] = MathLog(closes[j]/closes[j-1]);
            ir[matched] = MathLog(idxCloses[curK]/idxCloses[prevK]);
            matched++;
         }
         prevK = curK;
      }
      if(matched >= 20) CalcBeta(sr, ir, matched, beta);
   }
   return true;
}

// v2:只更新统计量与"一类/二类"判定;排序分在 RebalanceComputeScores() 里算。
void UpdateStats()
{
   int n = g_n;

   for(int i = 0; i < n; i++)
   {
      double t, hl, vc, so, ca, be; bool hlOk;
      DrawdownResult dd; double rm;
      g_valid[i] = ComputeStats(i, t, hl, hlOk, dd, rm, vc, so, ca, be) ? true : false;
      if(!g_valid[i])
      {
         t=-999; hl=9999; rm=1.0; vc=1.0; so=-999; ca=-999; be=1.0;
         dd.maxDD=1.0; dd.recoveryBars=9999; dd.currentDD=1.0; dd.recovered=false;
      }
      g_rollingMDD[i]=rm;
      g_isClassA[i] = (dd.recovered && rm <= InpRollingThresh);
   }
}

//===== 排序分 =====
// RankMode=0: S_i = pct_mom,i                                  (纯动量)
// RankMode=1: S_i = (1-w)*pct_mom,i + w*fund_pct,i             (动量+质量混合)
// 分位在"全部有效标的"内计算,保证一类与二类之间可比。
void RebalanceComputeScores()
{
   int n = g_n;
   double momRet[];
   ArrayResize(momRet, n); ArrayInitialize(momRet, -999.0);

   for(int i = 0; i < n; i++)
   {
      if(!g_valid[i]) continue;
      double c1[], c0[];
      int n1 = CopyClose(g_sym[i], InpTF, 1, 1, c1);
      int n0 = CopyClose(g_sym[i], InpTF, InpRankRetBars, 1, c0);
      if(n1 > 0 && n0 > 0 && c0[0] > 0.0)
         momRet[i] = c1[0] / c0[0] - 1.0;
   }
   RankPercentile(momRet, g_valid, n, g_momPct);

   // 质量分兜底:取不到(理论上不会,池子来自 fund_keep=1)就用候选集中位数,并置 qpNA 标记
   double medQ = MedianQual();
   for(int i = 0; i < n; i++)
   {
      if(!g_valid[i]) { g_rankScore[i] = -9999.0; continue; }
      double q = g_fundQual[i];
      g_qualNA[i] = !(q >= 0.0 && q <= 1.0);         // 缺失或脏数据 → 兜底并标记
      if(g_qualNA[i]) q = medQ;
      g_fundQual[i] = q;
      double w = (InpRankMode == 1) ? InpQualityWeight : 0.0;
      if(w < 0.0) w = 0.0;
      if(w > 1.0) w = 1.0;
      g_rankScore[i] = (1.0 - w) * g_momPct[i] + w * q;
   }
}

// 质量分中位数(有效标的);没有可用值时退回 0.5
double MedianQual()
{
   double v[]; ArrayResize(v, 0);
   for(int i = 0; i < g_n; i++)
      if(g_valid[i] && g_fundQual[i] >= 0.0 && g_fundQual[i] <= 1.0)
      { int m = ArraySize(v); ArrayResize(v, m+1); v[m] = g_fundQual[i]; }
   int m = ArraySize(v);
   if(m <= 0) return 0.5;
   ArraySort(v);
   return (m % 2 == 1) ? v[m/2] : 0.5*(v[m/2-1] + v[m/2]);
}

//=========================== 交易 ===========================
// 按 g_rankScore 降序排一个"下标数组"(就地冒泡,池子只有几十只,够用)
void SortByScore(int &idx[])
{
   int cnt = ArraySize(idx);
   for(int a = 0; a < cnt-1; a++)
      for(int b = 0; b < cnt-1-a; b++)
         if(g_rankScore[idx[b]] < g_rankScore[idx[b+1]])
         { int t = idx[b]; idx[b] = idx[b+1]; idx[b+1] = t; }
}

double NormalizeLots(const string sym, double lots)
{
   double minL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;
   int digits = 0; double s = step;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 1e-9) { s *= 10.0; digits++; }
   lots = MathFloor(lots/step)*step;
   if(lots < minL) lots = minL;
   if(lots > maxL) lots = maxL;
   return NormalizeDouble(lots, digits);
}

ulong FindPosition(const string sym)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym && (long)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return tk;
   }
   return 0;
}

double TargetLots(const string sym, double weight)
{
   if(weight <= 0.0) return 0.0;
   double price = SymbolInfoDouble(sym, SYMBOL_ASK);
   if(price <= 0.0) price = iClose(sym, InpTF, 1);   // 测试器里其它品种可能暂时无报价，用最近收盘价兜底
   if(price <= 0.0) price = iClose(sym, InpTF, 0);
   if(price <= 0.0) return 0.0;

   // 合约大小(1 手 = 多少股):
   //   InpContractSize > 0 时以它为准(手动覆盖);
   //   否则依次取 品种规格 → 每跳价值/每跳大小 反推 → 退回 1 股。
   // 实测(2025 全年回测的成交明细):Pepperstone 美股 CFD 规格 = 1 股/手,
   // 与 OrderCalcMargin 一致,不存在 1:100 的差异。
   double valuePerLot = 0.0;
   double cs = (InpContractSize > 0.0) ? InpContractSize
                                       : SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
   if(cs > 0.0)
      valuePerLot = cs * price;
   if(valuePerLot <= 0.0)
   {
      double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      if(tv > 0.0 && ts > 0.0)
         valuePerLot = price * (tv / ts);       // 等价于 合约大小 × 价格
   }
   if(valuePerLot <= 0.0)
      valuePerLot = price;                        // 最后兜底:按 1 股
   if(valuePerLot <= 0.0) return 0.0;

   double targetValue = AccountInfoDouble(ACCOUNT_EQUITY) * weight;
   double lots = targetValue / valuePerLot;

   // 逐仓保证金上限:OrderCalcMargin 内部用的是真实合约规格,
   // 即使上面的合约大小取错,这一步也能把敞口压回安全范围。
   double m1 = 0.0;
   if(lots > 0.0 && OrderCalcMargin(ORDER_TYPE_BUY, sym, 1.0, price, m1) && m1 > 0.0)
   {
      double marginBudget = AccountInfoDouble(ACCOUNT_EQUITY) * weight * InpMarginMult;
      double maxLots = marginBudget / m1;
      if(lots > maxLots) lots = maxLots;
   }
   // 再加一道全局闸:任何情况下不超过可用保证金的 90%
   double margin = 0.0, freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(lots > 0.0 && freeMargin > 0.0 &&
      OrderCalcMargin(ORDER_TYPE_BUY, sym, lots, price, margin) &&
      margin > 0.0 && margin > freeMargin*0.9)
      lots = lots * (freeMargin*0.9/margin);

   return NormalizeLots(sym, lots);
}

void CloseSym(const string sym, const string why)
{
   ulong tk = FindPosition(sym);
   if(tk == 0) return;
   if(g_trade.PositionClose(tk) && InpVerbose)
     PrintFormat("平仓 %s (%s)", sym, why);
}

//=========================== 市场闸门 ===========================
// 上升段满仓、下跌段降仓/空仓,用来解决"策略在下跌市里亏得比基准多得多"的结构问题。
// 判定只用"仅过去"的日线数据,无未来函数。

// 基准指数趋势:最近一根已收日线 vs 前 N 根日线均线
bool BenchTrendUp(double &detail)
{
   detail = 0.0;
   if(InpGateSMA < 2) return true;
   double c[];
   int need = InpGateSMA + 2;
   int n = CopyClose(g_benchSym, PERIOD_D1, 1, need, c);
   if(n < InpGateSMA)
   {
      g_gateNoData++;
      return true;                       // 数据不足时不拦截(宁可保持可交易)
   }
   double sum = 0.0;
   for(int i = 0; i < InpGateSMA; i++) sum += c[i];     // 非序列数组:0=最旧, n-1=最近
   double sma  = sum / InpGateSMA;
   double last = c[n-1];
   if(sma <= 0.0) return true;
   detail = last / sma - 1.0;
   return (last > sma);
}

// 池内宽度:有效标的中"日线收盘在自身均线上方"的比例
double PoolBreadth()
{
   if(InpGateBreadthSMA < 2) return 1.0;
   int cnt = 0, up = 0;
   for(int i = 0; i < g_n; i++)
   {
      if(!g_valid[i]) continue;
      double c[];
      int n = CopyClose(g_sym[i], PERIOD_D1, 1, InpGateBreadthSMA + 2, c);
      if(n < InpGateBreadthSMA) continue;
      double sum = 0.0;
      for(int k = n - InpGateBreadthSMA; k < n; k++) sum += c[k];
      double sma = sum / InpGateBreadthSMA;
      if(sma > 0.0 && c[n-1] > sma) up++;
      cnt++;
   }
   return (cnt > 0) ? (double)up / (double)cnt : 1.0;
}

// 返回本期仓位系数:1 = 满仓;否则按 InpGateScale 降仓
double GateScaleNow()
{
   if(!InpRegimeGate || InpBenchmarkMode) return 1.0;   // 基准组不做闸门,保持"什么都不做"
   double dev = 0.0;
   bool up = BenchTrendUp(dev);
   if(up)
      g_gateWhy = StringFormat("指数在均线上方(+%.1f%%)", dev * 100.0);
   else
      g_gateWhy = StringFormat("指数跌破均线(%.1f%%)", dev * 100.0);

   if(up && InpGateBreadthMin > 0.0)
   {
      double br = PoolBreadth();
      if(br < InpGateBreadthMin)
      {
         up = false;
         g_gateWhy = StringFormat("池内宽度 %.0f%% < %.0f%%", br * 100.0, InpGateBreadthMin * 100.0);
      }
   }
   if(up) { g_gateOnCount++;  return 1.0; }
   g_gateOffCount++;
   return InpGateScale;
}

bool Rebalance()          // 返回 false = 有下单失败(通常是休市)，需要稍后重试
{
   bool allOk = true;
   g_rebalanceCount++;
   AccrueDividends();     // 先给现有持仓累计这一段持有期的股息
   UpdateStats();               // 统计量 + 一类/二类判定
   RebalanceComputeScores();    // 动量分位(可选叠加质量分)→ g_rankScore

   //---- 候选集合:一类优先,可选从二类补足;基准模式=全池等权 ----
   int tierA[]; ArrayResize(tierA, 0);      // 一类(有效)
   int tierB[]; ArrayResize(tierB, 0);      // 二类(有效但未过一类)
   int allV[];  ArrayResize(allV, 0);       // 全部有效
   for(int i = 0; i < g_n; i++)
   {
      if(!g_valid[i]) continue;
      int m = ArraySize(allV); ArrayResize(allV, m+1); allV[m] = i;
      if(g_isClassA[i]) { m = ArraySize(tierA); ArrayResize(tierA, m+1); tierA[m] = i; }
      else              { m = ArraySize(tierB); ArrayResize(tierB, m+1); tierB[m] = i; }
   }
   SortByScore(tierA);   // 按 g_rankScore 降序
   SortByScore(tierB);
   SortByScore(allV);

   int cand[]; ArrayResize(cand, 0);
   if(InpBenchmarkMode)
   {
      // 基准:全池有效标等权(不做一类过滤,不取 TopN)
      for(int k = 0; k < ArraySize(allV); k++)
      { int m = ArraySize(cand); ArrayResize(cand, m+1); cand[m] = allV[k]; }
   }
   else if(!InpOnlyClassA)
   {
      // 关掉一类过滤:全池按分数取前 N
      for(int k = 0; k < ArraySize(allV) && ArraySize(cand) < InpTopN; k++)
      { int m = ArraySize(cand); ArrayResize(cand, m+1); cand[m] = allV[k]; }
   }
   else
   {
      int need = InpTopN;
      for(int k = 0; k < ArraySize(tierA) && ArraySize(cand) < need; k++)
      { int m = ArraySize(cand); ArrayResize(cand, m+1); cand[m] = tierA[k]; }
      if(InpFillFromClassB)
         for(int k = 0; k < ArraySize(tierB) && ArraySize(cand) < need; k++)
         { int m = ArraySize(cand); ArrayResize(cand, m+1); cand[m] = tierB[k]; }
   }

   int cnt   = ArraySize(cand);
   // 基准模式下权重分母=候选数(全池)；策略模式分母固定为 TopN(不足则留现金)
   int slots = InpBenchmarkMode ? MathMax(cnt, 1) : MathMax(InpTopN, 1);
   int pick  = cnt;
   double weight[];
   ArrayResize(weight, g_n); ArrayInitialize(weight, 0.0);
   if(pick > 0)
   {
      if(InpWeightMode == 1)
      {
         double lo = g_rankScore[cand[pick-1]];
         double sum = 0.0;
         for(int k = 0; k < pick; k++) { double w = g_rankScore[cand[k]] - lo + 1.0; weight[cand[k]] = w; sum += w; }
         if(sum <= 0.0) sum = 1.0;
         for(int k = 0; k < pick; k++) weight[cand[k]] /= sum;
      }
      else
      {
         // 分母固定用 slots:合格标的不足 N 只时剩余权重留现金,
         // 避免"当期只有 2 只合格 → 各 50% 满仓"的隐性集中。
         double base = 1.0 / (double)slots;
         for(int k = 0; k < pick; k++) weight[cand[k]] = base;
      }
   }

   //---- 市场闸门:风险开启时按系数降仓(0 = 全部转现金) ----
   double gateScale = GateScaleNow();
   if(gateScale < 1.0)
      for(int i = 0; i < g_n; i++) weight[i] *= gateScale;
   if(InpVerbose)
      PrintFormat("市场闸门: 仓位系数 %.2f (%s)", gateScale, g_gateWhy);

   // 单标的上限:超过上限的部分默认不再回补(留现金),只有显式打开
   // InpScaleWeightsToFull 才摊回已选标的。旧版"先截顶再归一化"会让
   // 上限形同虚设:2 只标的各 50% 截到 25% 再归一化又变回 50%。
   double cap = InpMaxWeightPct/100.0, wsum = 0.0;
   for(int i = 0; i < g_n; i++) { if(weight[i] > cap) weight[i] = cap; wsum += weight[i]; }
   if(InpScaleWeightsToFull && wsum > 0.0)
      for(int i = 0; i < g_n; i++) weight[i] /= wsum;

   // 把这一期每个标的的状态写进诊断文件（测试器日志看不到 Print）
   string ts = TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES);
   DiagRow(ts, "GATE", "-", "-", 0.0, gateScale, 0.0, 0.0, 0.0, g_gateWhy);
   for(int i = 0; i < g_n; i++)
   {
      double ask = SymbolInfoDouble(g_sym[i], SYMBOL_ASK);
      double lots = (weight[i] > 0.0) ? TargetLots(g_sym[i], weight[i]) : 0.0;
      double csD  = SymbolInfoDouble(g_sym[i], SYMBOL_TRADE_CONTRACT_SIZE);
      double m1D  = 0.0;
      double pxD = (ask > 0.0) ? ask : iClose(g_sym[i], InpTF, 1);
      if(!OrderCalcMargin(ORDER_TYPE_BUY, g_sym[i], 1.0, pxD, m1D))
         m1D = -1.0;                     // 取不到就记 -1,便于在诊断里识别
      DiagRow(ts, g_sym[i], g_valid[i]?"1":"0", g_isClassA[i]?"1":"0",
              g_rollingMDD[i], g_rankScore[i], weight[i], ask, lots,
              "cs=" + DoubleToString(csD, 2) + ";m1=" + DoubleToString(m1D, 2)
              + ";tv=" + DoubleToString(SymbolInfoDouble(g_sym[i], SYMBOL_TRADE_TICK_VALUE), 4)
              + ";ts=" + DoubleToString(SymbolInfoDouble(g_sym[i], SYMBOL_TRADE_TICK_SIZE), 6)
              + ";mom=" + DoubleToString(g_momPct[i], 4)
              + ";qp=" + (g_qualNA[i] ? "NA" : DoubleToString(g_fundQual[i], 4)));
      if(InpVerbose)
         PrintFormat("  %-10s 有效=%s 一类=%s 滚动回撤=%.1f%% 分数=%.3f 权重=%.1f%% 价格=%.4f 手数=%.2f",
                     g_sym[i], g_valid[i]?"是":"否", g_isClassA[i]?"是":"否",
                     g_rollingMDD[i]*100.0, g_rankScore[i], weight[i]*100.0, ask, lots);
   }

   // 先平掉不在目标里的
   for(int i = 0; i < g_n; i++)
      if(weight[i] <= 0.0)
         CloseSym(g_sym[i], "调出");

   // 再建/调目标仓
   for(int i = 0; i < g_n; i++)
   {
      if(weight[i] <= 0.0) continue;
      string sym = g_sym[i];
      double want = TargetLots(sym, weight[i]);
      if(want <= 0.0) continue;

      ulong tk = FindPosition(sym);
      double have = 0.0;
      if(tk > 0) have = PositionGetDouble(POSITION_VOLUME);
      if(have > 0.0)
      {
         double dev = MathAbs(have - want) / have * 100.0;
         if(dev <= InpAdjustTolPct) continue;      // 偏离不大就不动,省成本
         CloseSym(sym, "再平衡");
      }
      if(g_trade.Buy(want, sym, 0.0, 0.0, 0.0, "CS"))
      {
         if(InpVerbose)
            PrintFormat("买入 %s 手数 %.2f (目标权重 %.1f%%)", sym, want, weight[i]*100.0);
      }
      else
      {
         int rc = (int)g_trade.ResultRetcode();
         DiagRow(ts, "BUYFAIL(" + IntegerToString(rc) + "):" + sym,
                 "0", "-", 0.0, 0.0, 0.0, 0.0, want);
         if(rc == 10018)      // 市场已收盘 → 不是配置问题，等下一个 tick 重试
            allOk = false;
      }
   }
   return allOk;
}

//=========================== 主循环 ===========================
void OnTick()
{
   datetime now = TimeCurrent();
   bool due = (g_lastRebalance == 0) ||
              (now - g_lastRebalance >= (long)InpRebalanceDays * 86400);
   if(!due)
      return;

   // 失败重试节流：最多每 15 分钟试一次
   if(g_lastTry > 0 && now - g_lastTry < 900)
      return;

   // 只在美国现货开盘时段调仓：否则 .US 合约会以"市场已收盘"(10018)被拒单
   if(InpRebalHourFrom > 0 || InpRebalHourTo < 23)
   {
      MqlDateTime dt;
      TimeToStruct(now, dt);
      if(dt.hour < InpRebalHourFrom || dt.hour > InpRebalHourTo)
         return;                 // 只调仓到窗口内第一个 tick
   }

   g_lastTry = now;
   if(Rebalance())
      g_lastRebalance = now;      // 只有成功才推进调仓周期；失败则稍后重试
}

//=========================== 优化准则 ===========================
double OnTester()
{
   double profit = TesterStatistics(STAT_PROFIT);
   double dd     = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   if(dd <= 0.0) return profit;
   return (profit/dd) * (pf > 0.0 ? pf : 1.0);
}
//+------------------------------------------------------------------+
