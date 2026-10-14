//+------------------------------------------------------------------+
//|                                          ReliabilityRanking.mq5  |
//|         美股价格稳定性排序 + 一类/二类标的自动分类                     |
//|         一类：通过全部过滤；二类：未通过全部过滤但参与排序          |
//|         输出可直接粘贴到EA槽位的字符串                            |
//+------------------------------------------------------------------+
#property copyright "YourName"
#property version   "1.31"
#property description "对美股按价格稳定性排序，自动划分一类/二类标的"
#property script_show_inputs

//+------------------------------------------------------------------+
//| 输入参数                                                          |
//+------------------------------------------------------------------+
input ENUM_TIMEFRAMES InpTimeframe     = PERIOD_M30;
input datetime        InpStartDate     = D'2025.01.01';
input datetime        InpEndDate       = D'2025.12.31';
input string          InpIndexSymbol   = "US500";
input int             InpFallbackBars  = 3000;   // 指定区间没数据时,回退取最近N根K线
input int             InpMinBars       = 30;     // 少于这么多根K线就算数据不足
input double          InpRiskFreeRate  = 0.0;
input int             InpADFLagOrder   = 1;
input int             InpLogTopN       = 20;
input int             InpHalfLifeCap   = 800;
input double          InpRecoveryRatio = 0.8;

//--- 滚动窗口参数
input int             InpRollingMDDWindowDays = 20;
input double          InpRollingMDDThreshold  = 0.20;

//--- 数量控制
input int             InpTotalCount    = 100;

//--- EA槽位字段
input string          InpSlotStartTime = "10:00";
input bool            InpSlotAllowBuy  = true;
input bool            InpSlotAllowSell = false;
input bool            InpSlotProfitBuy = true;
input bool            InpSlotProfitSell= true;
input double          InpSlotLots      = 1.0;

//--- 维度权重
input double InpW_MeanReversion = 0.25;
input double InpW_Drawdown      = 0.15;
input double InpW_VolAdditivity = 0.10;
input double InpW_VolumePrice   = 0.05;
input double InpW_ReturnEff     = 0.10;
input double InpW_Systematic    = 0.05;
input double InpW_RollingMDD    = 0.30;

//--- 维度内权重
input double InpW_ADF      = 0.60;
input double InpW_HalfLife = 0.40;
input double InpW_Hurst    = 0.00;
input double InpW_MaxDD    = 0.40;
input double InpW_Recovery = 0.40;
input double InpW_CurrentDD= 0.20;
input double InpW_Ratio    = 0.40;
input double InpW_MaxStreak= 0.40;
input double InpW_AvgStreak= 0.20;
input double InpW_VolConv  = 1.00;
input double InpW_Sortino  = 0.50;
input double InpW_Calmar   = 0.50;

//--- 基本面硬过滤
input group "=== 基本面硬过滤 ==="
input bool   InpUseFundamental = true;                 // 启用基本面硬过滤
input string InpFundFile       = "fundamentals.csv";   // 共享目录(Common/Files)里的因子表
input double InpFundMinPct     = 0.40;                 // 综合分位下限，低于此淘汰

//+------------------------------------------------------------------+
//| 基本面：读入的列与缓存                                            |
//+------------------------------------------------------------------+
#define FUND_COLS 7
string g_fundCol[FUND_COLS] =
  {"roe", "net_margin", "gross_margin", "earn_vol", "net_debt_ebitda", "int_cov",
   "dividend_yield"};
double g_fundRaw[POOL_SIZE][FUND_COLS];
double g_fundPct[POOL_SIZE];
bool   g_fundHas[POOL_SIZE];
int    g_fundKept = 0, g_fundDropped = 0, g_fundNoData = 0;

//+------------------------------------------------------------------+
//| 股票池                                                            |
//+------------------------------------------------------------------+
//  股票池（TMGM 模拟账户命名：纯代码、无后缀；已逐个核对存在）
//  注：DJT 在本经纪商的描述字段是 "Dow Jones Transportation Averag"（道指运输指数），
//      与“特朗普媒体(Nasdaq: DJT)”撞名，含义待确认，故默认注释掉；
//      若确认它就是你要的那只股票，取消下面最后一行注释并把它加回数组、POOL_SIZE 改回 100。
//  股票池（Pepperstone 基准版：81 个，已剔除该经纪商没有的 19 个）
//  这里只写基础代码；真实合约由 ResolveUSSymbol() 在 .US / .US-24 / 纯代码
//  之间自动挑选“区间内确实有K线”的那一个。
//  被剔除（Pepperstone 无此品种）：HYG GLD VNQ BK VBK VGT ZTO YY BHP VALE
//                                BILI TCOM MOMO EDU PDD EA TWLO SQ DJT
string g_symbols[] = {
    "KO", "MCD", "V", "TTWO", "EW",
    "TJX", "MA", "DE", "GD", "EEM",
    "PEP", "SCHW", "LOW", "MSFT", "XOM",
    "NEE", "MMM", "JNJ", "ZM", "BKNG",
    "F", "IBM", "ROST", "RTX", "IWM",
    "JPM", "DG", "BLK", "LMT", "HD",
    "PNC", "ULTA", "U", "GOOGL", "GOOG",
    "DVN", "GE", "EMR", "NXPI", "WFC",
    "FCX", "DIS", "WMT", "XLE", "MPWR",
    "MPC", "KLAC", "PFE", "USB", "SNOW",
    "ISRG", "NEM", "NET", "META", "ON",
    "LYFT", "NKE", "MCHP", "WSM", "QCOM",
    "RIVN", "MS", "GM", "UAL", "GS",
    "LRCX", "ROKU", "DELL", "HAL", "FSLR",
    "SHOP", "TSM", "TMO", "NVDA", "BBY",
    "WBD", "LLY", "SWKS", "INTC", "MU",
    "MRK"
};

#define POOL_SIZE 81

//+------------------------------------------------------------------+
//| 品种名解析：兼容“纯代码”(TMGM) 与 “代码.US”(Pepperstone) 两种命名  |
//| 顺序：精确匹配 -> 代码.US -> 代码.US-24 -> 任何以“代码.”开头的    |
//+------------------------------------------------------------------+
string ResolveUSSymbol(const string poolName, ENUM_TIMEFRAMES tf,
                       datetime from, datetime to, int minBars)
{
   string base = poolName;
   int dot = StringFind(base, ".");
   if(dot > 0)
      base = StringSubstr(base, 0, dot);
   StringToUpper(base);

   string cands[3];
   cands[0] = base + ".US";      // Pepperstone 标准合约
   cands[1] = base + ".US-24";   // Pepperstone 24小时合约
   cands[2] = base;               // 纯代码（TMGM 等）

   int total = SymbolsTotal(false);
   string firstExisting = "";
   double probe[];
   for(int c = 0; c < 3; c++)
   {
      string actual = "";
      for(int i = 0; i < total; i++)
      {
         string cand = SymbolName(i, false);
         string up = cand;
         StringToUpper(up);
         if(up == cands[c]) { actual = cand; break; }
      }
      if(actual == "")
         continue;
      if(firstExisting == "")
         firstExisting = actual;
      if(CopyClose(actual, tf, from, to, probe) >= minBars)
         return actual;   // 这个候选在区间内有数据，就用它
   }
   return firstExisting;
}

//+------------------------------------------------------------------+
//| 基准指数解析：不同经纪商对 S&P500 命名不同,逐个尝试              |
//+------------------------------------------------------------------+
string ResolveIndexSymbol(const string wanted)
{
   string candidates[] =
   {
      wanted, "US500", "SP500m", "SPX500", "SP500", "US500m",
      "ND100m", "NAS100", "USTEC", "US30", "DJI"
   };
   int total = SymbolsTotal(false);
   for(int c = 0; c < ArraySize(candidates); c++)
   {
      if(candidates[c] == "")
         continue;
      string w = candidates[c];
      StringToUpper(w);
      for(int i = 0; i < total; i++)
      {
         string up = SymbolName(i, false);
         StringToUpper(up);
         if(up == w)
            return SymbolName(i, false);
      }
   }
   return wanted;
}

//+------------------------------------------------------------------+
//| 读取基本面因子表(Common/Files/fundamentals.csv)                  |
//| 列:pool_code/ticker + 6 个因子 + fund_pct(已由 Python 端缩尾与算分位) |
//+------------------------------------------------------------------+
bool LoadFundamentals()
{
   for(int i = 0; i < POOL_SIZE; i++)
   {
      g_fundHas[i] = false;
      g_fundPct[i] = 0.0;
      for(int j = 0; j < FUND_COLS; j++)
         g_fundRaw[i][j] = 0.0;
   }

   int h = FileOpen(InpFundFile, FILE_READ|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
   {
      PrintFormat("!! 打不开基本面文件 %s (error=%d)", InpFundFile, GetLastError());
      PrintFormat("   请把 fundamentals.csv 复制到 MT5 的 Common\\Files 目录");
      return false;
   }

   string header = FileReadString(h);
   string cols[];
   int nc = StringSplit(header, ',', cols);
   int iTicker = -1, iPct = -1;
   int iCol[FUND_COLS];
   ArrayInitialize(iCol, -1);
   for(int c = 0; c < nc; c++)
   {
      string nm = cols[c];
      StringTrimLeft(nm); StringTrimRight(nm);
      if(nm == "ticker" || nm == "pool_code") iTicker = c;
      else if(nm == "fund_pct")               iPct = c;
      for(int j = 0; j < FUND_COLS; j++)
         if(nm == g_fundCol[j]) iCol[j] = c;
   }
   if(iTicker < 0 || iPct < 0)
   {
      FileClose(h);
      Print("!! 基本面文件缺少 ticker / fund_pct 列，改用不上过滤");
      return false;
   }

   int rows = 0, matched = 0;
   while(!FileIsEnding(h))
   {
      string line = FileReadString(h);
      if(line == "") continue;
      rows++;
      string f[];
      int nf = StringSplit(line, ',', f);
      if(nf <= iPct || nf <= iTicker) continue;

      string tk = f[iTicker];
      StringTrimLeft(tk); StringTrimRight(tk); StringToUpper(tk);
      int dot = StringFind(tk, ".");
      if(dot > 0) tk = StringSubstr(tk, 0, dot);

      for(int i = 0; i < POOL_SIZE; i++)
      {
         string bare = g_symbols[i];
         int d2 = StringFind(bare, ".");
         if(d2 > 0) bare = StringSubstr(bare, 0, d2);
         StringToUpper(bare);
         if(bare != tk) continue;

         g_fundHas[i] = true;
         g_fundPct[i] = StringToDouble(f[iPct]);
         for(int j = 0; j < FUND_COLS; j++)
            if(iCol[j] >= 0 && iCol[j] < nf)
               g_fundRaw[i][j] = StringToDouble(f[iCol[j]]);
         matched++;
         break;
      }
   }
   FileClose(h);
   PrintFormat("基本面文件读取完成:数据行 %d,匹配到池内 %d 只", rows, matched);
   return (matched > 0);
}

//+------------------------------------------------------------------+
//| 全局存储                                                          |
//+------------------------------------------------------------------+
double g_adfTStat[POOL_SIZE];
double g_halfLife[POOL_SIZE];
double g_hurst[POOL_SIZE];
double g_maxDD[POOL_SIZE];
double g_recoveryDays[POOL_SIZE];
double g_currentDD[POOL_SIZE];
double g_downUpRatio[POOL_SIZE];
double g_maxConsecDown[POOL_SIZE];
double g_avgConsecDown[POOL_SIZE];
double g_sortino[POOL_SIZE];
double g_calmar[POOL_SIZE];
double g_beta[POOL_SIZE];
double g_volConv[POOL_SIZE];
double g_rollingMDD[POOL_SIZE];

bool   g_valid[POOL_SIZE];
bool   g_passRecovery[POOL_SIZE];
bool   g_passRolling[POOL_SIZE];
bool   g_isClassA[POOL_SIZE];

double g_score[POOL_SIZE];
int    g_rank[POOL_SIZE];
int    g_qualifiedCount = 0;

double g_adfScore[POOL_SIZE];
double g_hlScore[POOL_SIZE];
double g_hurstScore[POOL_SIZE];
double g_mddScore[POOL_SIZE];
double g_recScore[POOL_SIZE];
double g_curScore[POOL_SIZE];
double g_ratioScore[POOL_SIZE];
double g_streakScore[POOL_SIZE];
double g_avgStreakScore[POOL_SIZE];
double g_volConvScore[POOL_SIZE];
double g_sortinoScore[POOL_SIZE];
double g_calmarScore[POOL_SIZE];
double g_betaScore[POOL_SIZE];
double g_rollingMDDScore[POOL_SIZE];

int g_barsPerYear = 252;

//--- 结构体
struct DrawdownResult
{
   double   maxDD;
   int      recoveryDays;
   bool     recovered;
   double   currentDD;
   int      maxDDStartIdx;
   int      maxDDBottomIdx;
   int      maxDDEndIdx;
   double   recoveryTarget;
};

struct DownStreakResult
{
   int    maxConsecDown;
   double avgConsecDown;
   double downDayRatio;
   int    downStreakCount;
};

struct ADFResult
{
   double gamma;
   double tStat;
   double halfLife;
   bool   stationary;
};

struct HurstResult
{
   double hurst;
   double rSquared;
   bool   valid;
};

//+------------------------------------------------------------------+
int CalcBarsPerYear(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return 252 * 1440;
      case PERIOD_M5:  return 252 * 288;
      case PERIOD_M15: return 252 * 96;
      case PERIOD_M30: return 252 * 48;
      case PERIOD_H1:  return 252 * 24;
      case PERIOD_H4:  return 252 * 6;
      case PERIOD_D1:  return 252;
      case PERIOD_W1:  return 52;
      case PERIOD_MN1: return 12;
      default:         return 252;
   }
}

//+------------------------------------------------------------------+
int DaysToBars(int days, ENUM_TIMEFRAMES tf)
{
   int barsPerDay = 13;
   switch(tf)
   {
      case PERIOD_M1:  barsPerDay = 390; break;
      case PERIOD_M5:  barsPerDay = 78;  break;
      case PERIOD_M15: barsPerDay = 26;  break;
      case PERIOD_M30: barsPerDay = 13;  break;
      case PERIOD_H1:  barsPerDay = 7;   break;
      case PERIOD_H4:  barsPerDay = 2;   break;
      case PERIOD_D1:  barsPerDay = 1;   break;
      default:         barsPerDay = 13;  break;
   }
   return days * barsPerDay;
}

//+------------------------------------------------------------------+
//| 工具：标准差                                                      |
//+------------------------------------------------------------------+
double StdDev(const double &arr[], int start, int n)
{
   if(n < 2) return 0.0;
   double sum = 0.0;
   for(int i = 0; i < n; i++) sum += arr[start+i];
   double mean = sum / n;
   double sumSq = 0.0;
   for(int i = 0; i < n; i++)
   {
      double d = arr[start+i] - mean;
      sumSq += d * d;
   }
   return MathSqrt(sumSq / n);
}

//+------------------------------------------------------------------+
//| 工具：二分查找时间戳                                              |
//+------------------------------------------------------------------+
int FindTimeIndex(const datetime &times[], int n, datetime target)
{
   int lo = 0, hi = n - 1;
   while(lo <= hi)
   {
      int mid = (lo + hi) / 2;
      if(times[mid] == target) return mid;
      if(times[mid] < target)  lo = mid + 1;
      else                     hi = mid - 1;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| 一元线性回归                                                      |
//+------------------------------------------------------------------+
bool LinearRegression(const double &x[], const double &y[], int n,
                      double &alpha, double &beta, double &seBeta, double &tStat)
{
   if(n < 3) return false;
   double sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumX2 = 0.0;
   for(int i = 0; i < n; i++)
   {
      sumX += x[i]; sumY += y[i]; sumXY += x[i]*y[i]; sumX2 += x[i]*x[i];
   }
   double meanX = sumX / n, meanY = sumY / n;
   double sxx = sumX2 - n*meanX*meanX;
   if(MathAbs(sxx) < 1e-12) return false;
   double sxy = sumXY - n*meanX*meanY;
   beta = sxy / sxx;
   alpha = meanY - beta * meanX;
   double rss = 0.0;
   for(int i = 0; i < n; i++)
   {
      double yHat = alpha + beta * x[i];
      double e = y[i] - yHat;
      rss += e * e;
   }
   double dof = n - 2.0;
   if(dof <= 0.0) return false;
   double sigma2 = rss / dof;
   seBeta = MathSqrt(sigma2 / sxx);
   tStat = (seBeta > 1e-12) ? beta / seBeta : 0.0;
   return true;
}

//+------------------------------------------------------------------+
//| 多元线性回归                                                      |
//+------------------------------------------------------------------+
bool MultiLinearRegression(const double &X[], const double &y[], int n, int k,
                           double &beta[], double &seBeta[], double &tStat[])
{
   if(n <= k) return false;
   ArrayResize(beta, k); ArrayResize(seBeta, k); ArrayResize(tStat, k);
   double XtX[]; ArrayResize(XtX, k*k); ArrayInitialize(XtX, 0.0);
   double Xty[]; ArrayResize(Xty, k);   ArrayInitialize(Xty, 0.0);
   for(int i = 0; i < k; i++)
   {
      for(int j = 0; j < k; j++)
      {
         double sum = 0.0;
         for(int t = 0; t < n; t++) sum += X[t*k+i] * X[t*k+j];
         XtX[i*k+j] = sum;
      }
      double sumY = 0.0;
      for(int t = 0; t < n; t++) sumY += X[t*k+i] * y[t];
      Xty[i] = sumY;
   }
   double A[]; ArrayResize(A, k*(k+1)); ArrayInitialize(A, 0.0);
   for(int i = 0; i < k; i++)
   {
      for(int j = 0; j < k; j++) A[i*(k+1)+j] = XtX[i*k+j];
      A[i*(k+1)+k] = Xty[i];
   }
   for(int col = 0; col < k; col++)
   {
      int pivot = col;
      double maxAbs = MathAbs(A[col*(k+1)+col]);
      for(int r = col+1; r < k; r++)
      {
         double v = MathAbs(A[r*(k+1)+col]);
         if(v > maxAbs) { maxAbs = v; pivot = r; }
      }
      if(maxAbs < 1e-12) return false;
      if(pivot != col)
      {
         for(int c = 0; c <= k; c++)
         {
            double tmp = A[col*(k+1)+c];
            A[col*(k+1)+c] = A[pivot*(k+1)+c];
            A[pivot*(k+1)+c] = tmp;
         }
      }
      double diag = A[col*(k+1)+col];
      for(int c = col; c <= k; c++) A[col*(k+1)+c] /= diag;
      for(int r = 0; r < k; r++)
      {
         if(r == col) continue;
         double factor = A[r*(k+1)+col];
         for(int c = col; c <= k; c++)
            A[r*(k+1)+c] -= factor * A[col*(k+1)+c];
      }
   }
   for(int i = 0; i < k; i++) beta[i] = A[i*(k+1)+k];
   double rss = 0.0;
   for(int t = 0; t < n; t++)
   {
      double yHat = 0.0;
      for(int i = 0; i < k; i++) yHat += X[t*k+i] * beta[i];
      double e = y[t] - yHat;
      rss += e * e;
   }
   double dof = n - k;
   if(dof <= 0.0) return false;
   double sigma2 = rss / dof;
   double Inv[]; ArrayResize(Inv, k*k);
   for(int i = 0; i < k*k; i++) Inv[i] = XtX[i];
   double I[]; ArrayResize(I, k*k); ArrayInitialize(I, 0.0);
   for(int i = 0; i < k; i++) I[i*k+i] = 1.0;
   for(int col = 0; col < k; col++)
   {
      int pivot = col;
      double maxAbs = MathAbs(Inv[col*k+col]);
      for(int r = col+1; r < k; r++)
      {
         double v = MathAbs(Inv[r*k+col]);
         if(v > maxAbs) { maxAbs = v; pivot = r; }
      }
      if(maxAbs < 1e-12) return false;
      if(pivot != col)
      {
         for(int c = 0; c < k; c++)
         {
            double tmp = Inv[col*k+c]; Inv[col*k+c] = Inv[pivot*k+c]; Inv[pivot*k+c] = tmp;
            tmp = I[col*k+c]; I[col*k+c] = I[pivot*k+c]; I[pivot*k+c] = tmp;
         }
      }
      double diag = Inv[col*k+col];
      for(int c = 0; c < k; c++) { Inv[col*k+c] /= diag; I[col*k+c] /= diag; }
      for(int r = 0; r < k; r++)
      {
         if(r == col) continue;
         double factor = Inv[r*k+col];
         for(int c = 0; c < k; c++)
         {
            Inv[r*k+c] -= factor * Inv[col*k+c];
            I[r*k+c]   -= factor * I[col*k+c];
         }
      }
   }
   for(int i = 0; i < k; i++)
   {
      seBeta[i] = MathSqrt(sigma2 * I[i*k+i]);
      tStat[i] = (seBeta[i] > 1e-12) ? beta[i] / seBeta[i] : 0.0;
   }
   return true;
}

//+------------------------------------------------------------------+
//| 对数收益率                                                        |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| 滚动窗口最大回撤                                                  |
//+------------------------------------------------------------------+
double CalcRollingMDD(const double &prices[], int n, int windowBars)
{
   if(n < windowBars || windowBars < 2) return 0.0;
   double worstMDD = 0.0;
   for(int start = 0; start <= n - windowBars; start++)
   {
      double peak = prices[start];
      double maxDD = 0.0;
      for(int i = start + 1; i < start + windowBars; i++)
      {
         if(prices[i] > peak) peak = prices[i];
         else
         {
            double dd = 1.0 - prices[i] / peak;
            if(dd > maxDD) maxDD = dd;
         }
      }
      if(maxDD > worstMDD) worstMDD = maxDD;
   }
   return worstMDD;
}

//+------------------------------------------------------------------+
//| 波动率收敛比                                                      |
//+------------------------------------------------------------------+
double CalcVolConvergence(const double &returns[], int n)
{
   if(n < 30) return 1.0;
   double stdAll = StdDev(returns, 0, n);
   if(stdAll < 1e-12) return 1.0;
   int recentCount = n / 3;
   if(recentCount < 10) recentCount = 10;
   return StdDev(returns, n - recentCount, recentCount) / stdAll;
}

//+------------------------------------------------------------------+
//| 半衰期                                                            |
//+------------------------------------------------------------------+
bool CalcHalfLife(const double &prices[], int n, double &halfLife, double &lambda, bool &valid)
{
   valid = false; halfLife = 0.0; lambda = 0.0;
   if(n < 30) return false;
   int m = n - 1;
   double dP[], pLag[];
   ArrayResize(dP, m); ArrayResize(pLag, m);
   for(int i = 0; i < m; i++)
   {
      dP[i] = prices[i+1] - prices[i];
      pLag[i] = prices[i];
   }
   double alpha, beta, seBeta, tStat;
   if(!LinearRegression(pLag, dP, m, alpha, beta, seBeta, tStat)) return false;
   lambda = beta;
   if(lambda >= 0.0) return true;
   halfLife = -MathLog(2.0) / lambda;
   valid = true;
   return true;
}

//+------------------------------------------------------------------+
//| ADF 检验                                                          |
//+------------------------------------------------------------------+
bool CalcADF(const double &prices[], int n, int lagOrder, ADFResult &result)
{
   result.gamma = 0.0; result.tStat = 0.0; result.halfLife = 0.0; result.stationary = false;
   if(n < 30) return false;
   if(lagOrder < 0) lagOrder = 0;
   if(lagOrder > 5) lagOrder = 5;
   int m = n - 1 - lagOrder;
   if(m < 20) return false;
   int k = 2 + lagOrder;
   double X[]; ArrayResize(X, m*k); ArrayInitialize(X, 0.0);
   double y[]; ArrayResize(y, m);
   for(int row = 0; row < m; row++)
   {
      int t = row + lagOrder + 1;
      double dP_t = prices[t] - prices[t-1];
      X[row*k+0] = 1.0;
      X[row*k+1] = prices[t-1];
      for(int i = 1; i <= lagOrder; i++)
         X[row*k+1+i] = prices[t-i] - prices[t-i-1];
      y[row] = dP_t;
   }
   double beta[], seBeta[], tStat[];
   if(!MultiLinearRegression(X, y, m, k, beta, seBeta, tStat)) return false;
   result.gamma = beta[1];
   result.tStat = tStat[1];
   result.stationary = (result.tStat < -2.86);
   if(result.gamma < 0.0) result.halfLife = -MathLog(2.0) / result.gamma;
   else result.halfLife = 9999.0;
   return true;
}

//+------------------------------------------------------------------+
//| R/S 分析                                                          |
//+------------------------------------------------------------------+
bool CalcRS(const double &series[], int start, int len, double &rs)
{
   rs = 0.0;
   if(len < 2) return false;
   double sum = 0.0;
   for(int i = 0; i < len; i++) sum += series[start+i];
   double mean = sum / len;
   double cumDev[]; ArrayResize(cumDev, len);
   double running = 0.0;
   for(int i = 0; i < len; i++) { running += series[start+i] - mean; cumDev[i] = running; }
   double maxY = cumDev[0], minY = cumDev[0];
   for(int i = 1; i < len; i++)
   {
      if(cumDev[i] > maxY) maxY = cumDev[i];
      if(cumDev[i] < minY) minY = cumDev[i];
   }
   double R = maxY - minY;
   double sumSq = 0.0;
   for(int i = 0; i < len; i++)
   {
      double d = series[start+i] - mean;
      sumSq += d * d;
   }
   double S = MathSqrt(sumSq / len);
   if(S < 1e-12) return false;
   rs = R / S;
   return true;
}

//+------------------------------------------------------------------+
//| Hurst 指数                                                        |
//+------------------------------------------------------------------+
bool CalcHurst(const double &returns[], int n, HurstResult &result)
{
   result.hurst = 0.5; result.rSquared = 0.0; result.valid = false;
   if(n < 64) return false;
   int sizes[] = {8, 16, 32, 64};
   int numSizes = ArraySize(sizes);
   double logN[], logRS[];
   ArrayResize(logN, numSizes); ArrayResize(logRS, numSizes);
   int validSizes = 0;
   for(int s = 0; s < numSizes; s++)
   {
      int len = sizes[s];
      if(len > n / 2) continue;
      int numBlocks = n / len;
      if(numBlocks < 2) continue;
      double sumRS = 0.0; int cntRS = 0;
      for(int b = 0; b < numBlocks; b++)
      {
         double rs;
         if(CalcRS(returns, b*len, len, rs)) { sumRS += rs; cntRS++; }
      }
      if(cntRS < 2) continue;
      double avgRS = sumRS / cntRS;
      if(avgRS < 1e-12) continue;
      logN[validSizes] = MathLog((double)len);
      logRS[validSizes] = MathLog(avgRS);
      validSizes++;
   }
   if(validSizes < 3) return false;
   double alpha, beta, seBeta, tStat;
   if(!LinearRegression(logN, logRS, validSizes, alpha, beta, seBeta, tStat)) return false;
   result.hurst = beta;
   double meanY = 0.0;
   for(int i = 0; i < validSizes; i++) meanY += logRS[i];
   meanY /= validSizes;
   double sst = 0.0, sse = 0.0;
   for(int i = 0; i < validSizes; i++)
   {
      double yHat = alpha + beta * logN[i];
      sst += (logRS[i]-meanY)*(logRS[i]-meanY);
      sse += (logRS[i]-yHat)*(logRS[i]-yHat);
   }
   result.rSquared = (sst > 1e-12) ? (1.0 - sse / sst) : 0.0;
   result.valid = true;
   return true;
}

//+------------------------------------------------------------------+
//| 回撤分析                                                          |
//+------------------------------------------------------------------+
bool CalcDrawdown(const double &prices[], int n, DrawdownResult &result)
{
   result.maxDD = 0.0; result.recoveryDays = 0; result.recovered = false;
   result.currentDD = 0.0; result.maxDDStartIdx = 0; result.maxDDBottomIdx = 0;
   result.maxDDEndIdx = 0; result.recoveryTarget = 0.0;
   if(n < 2) return false;
   double peak = prices[0]; int peakIdx = 0;
   double maxDD = 0.0; int ddStartIdx = 0, ddBottomIdx = 0;
   for(int i = 1; i < n; i++)
   {
      if(prices[i] > peak) { peak = prices[i]; peakIdx = i; }
      else
      {
         double dd = 1.0 - prices[i] / peak;
         if(dd > maxDD) { maxDD = dd; ddStartIdx = peakIdx; ddBottomIdx = i; }
      }
   }
   result.maxDD = maxDD;
   result.maxDDStartIdx = ddStartIdx;
   result.maxDDBottomIdx = ddBottomIdx;
   double peakBeforeDD = prices[ddStartIdx];
   double bottomPrice = prices[ddBottomIdx];
   double recoveryTarget = bottomPrice + (peakBeforeDD - bottomPrice) * InpRecoveryRatio;
   result.recoveryTarget = recoveryTarget;
   int recoveryIdx = -1;
   for(int i = ddBottomIdx+1; i < n; i++)
      if(prices[i] >= recoveryTarget) { recoveryIdx = i; break; }
   if(recoveryIdx >= 0)
   {
      result.recovered = true;
      result.recoveryDays = recoveryIdx - ddBottomIdx;
      result.maxDDEndIdx = recoveryIdx;
   }
   else
   {
      result.recovered = false;
      result.recoveryDays = n - 1 - ddBottomIdx;
      result.maxDDEndIdx = n - 1;
   }
   double peakAll = prices[0];
   for(int i = 1; i < n; i++) if(prices[i] > peakAll) peakAll = prices[i];
   result.currentDD = 1.0 - prices[n-1] / peakAll;
   return true;
}

//+------------------------------------------------------------------+
//| 下行/上行波动比                                                   |
//+------------------------------------------------------------------+
bool CalcDownUpRatio(const double &returns[], int n, double &downUpRatio, double &downVol, double &upVol)
{
   downUpRatio = 1.0; downVol = 0.0; upVol = 0.0;
   if(n < 10) return false;
   double sumDown = 0.0, sumUp = 0.0;
   int cntDown = 0, cntUp = 0;
   for(int i = 0; i < n; i++)
   {
      if(returns[i] < 0.0) { sumDown += returns[i]*returns[i]; cntDown++; }
      else if(returns[i] > 0.0) { sumUp += returns[i]*returns[i]; cntUp++; }
   }
   if(cntDown < 2 || cntUp < 2) return false;
   downVol = MathSqrt(sumDown / cntDown);
   upVol = MathSqrt(sumUp / cntUp);
   if(upVol < 1e-12) return false;
   downUpRatio = downVol / upVol;
   return true;
}

//+------------------------------------------------------------------+
//| 连续下跌统计                                                      |
//+------------------------------------------------------------------+
bool CalcDownStreak(const double &returns[], int n, DownStreakResult &result)
{
   result.maxConsecDown = 0; result.avgConsecDown = 0.0;
   result.downDayRatio = 0.0; result.downStreakCount = 0;
   if(n < 10) return false;
   int totalDown = 0, curStreak = 0, sumStreak = 0, maxStreak = 0;
   for(int i = 0; i < n; i++)
   {
      if(returns[i] < 0.0) { totalDown++; curStreak++; }
      else if(curStreak > 0)
      {
         result.downStreakCount++;
         sumStreak += curStreak;
         if(curStreak > maxStreak) maxStreak = curStreak;
         curStreak = 0;
      }
   }
   if(curStreak > 0)
   {
      result.downStreakCount++;
      sumStreak += curStreak;
      if(curStreak > maxStreak) maxStreak = curStreak;
   }
   result.maxConsecDown = maxStreak;
   result.downDayRatio = (double)totalDown / n;
   result.avgConsecDown = (result.downStreakCount > 0) ? (double)sumStreak / result.downStreakCount : 0.0;
   return true;
}

//+------------------------------------------------------------------+
//| 索提诺                                                            |
//+------------------------------------------------------------------+
bool CalcSortino(const double &returns[], int n, double riskFreeRate,
                 double &sortino, double &annualReturn, double &downVolAnnual)
{
   sortino = 0.0; annualReturn = 0.0; downVolAnnual = 0.0;
   if(n < 20) return false;
   double sumRet = 0.0;
   for(int i = 0; i < n; i++) sumRet += returns[i];
   double meanRet = sumRet / n;
   annualReturn = meanRet * g_barsPerYear;
   double sumDownSq = 0.0;
   int cntDown = 0;
   for(int i = 0; i < n; i++)
      if(returns[i] < 0.0) { sumDownSq += returns[i]*returns[i]; cntDown++; }
   if(cntDown < 2) return false;
   double downVol = MathSqrt(sumDownSq / cntDown);
   downVolAnnual = downVol * MathSqrt((double)g_barsPerYear);
   if(downVolAnnual < 1e-12) return false;
   sortino = (annualReturn - riskFreeRate) / downVolAnnual;
   return true;
}

//+------------------------------------------------------------------+
//| 卡马尔                                                            |
//+------------------------------------------------------------------+
bool CalcCalmar(double annualReturn, double maxDD, double &calmar)
{
   calmar = 0.0;
   if(maxDD < 1e-6) return false;
   calmar = annualReturn / maxDD;
   return true;
}

//+------------------------------------------------------------------+
//| 贝塔                                                              |
//+------------------------------------------------------------------+
bool CalcBeta(const double &stockReturns[], const double &indexReturns[], int n, double &beta)
{
   beta = 0.0;
   if(n < 20) return false;
   double sumS = 0.0, sumI = 0.0;
   for(int i = 0; i < n; i++) { sumS += stockReturns[i]; sumI += indexReturns[i]; }
   double meanS = sumS / n, meanI = sumI / n;
   double cov = 0.0, varI = 0.0;
   for(int i = 0; i < n; i++)
   {
      double ds = stockReturns[i] - meanS;
      double di = indexReturns[i] - meanI;
      cov += ds * di;
      varI += di * di;
   }
   if(varI < 1e-12) return false;
   beta = cov / varI;
   return true;
}

//+------------------------------------------------------------------+
//| Z-score 标准化                                                    |
//+------------------------------------------------------------------+
void ZScoreNormalize(const double &arr[], int n, double &out[])
{
   ArrayResize(out, n);
   ArrayInitialize(out, 0.0);
   if(n < 2) return;
   double sum = 0.0;
   for(int i = 0; i < n; i++) sum += arr[i];
   double mean = sum / n;
   double sumSq = 0.0;
   for(int i = 0; i < n; i++)
   {
      double d = arr[i] - mean;
      sumSq += d * d;
   }
   double std = MathSqrt(sumSq / n);
   if(std < 1e-12) return;
   for(int i = 0; i < n; i++) out[i] = (arr[i] - mean) / std;
}

//+------------------------------------------------------------------+
//| 标准化 + 方向统一                                                 |
//+------------------------------------------------------------------+
void NormalizeIndicators()
{
   double adfArr[], hlArr[], hurstArr[], mddArr[], recArr[], curArr[];
   double ratioArr[], maxStrArr[], avgStrArr[], volConvArr[];
   double sortinoArr[], calmarArr[], betaArr[], rollingArr[];

   ArrayResize(adfArr, g_qualifiedCount);
   ArrayResize(hlArr, g_qualifiedCount);
   ArrayResize(hurstArr, g_qualifiedCount);
   ArrayResize(mddArr, g_qualifiedCount);
   ArrayResize(recArr, g_qualifiedCount);
   ArrayResize(curArr, g_qualifiedCount);
   ArrayResize(ratioArr, g_qualifiedCount);
   ArrayResize(maxStrArr, g_qualifiedCount);
   ArrayResize(avgStrArr, g_qualifiedCount);
   ArrayResize(volConvArr, g_qualifiedCount);
   ArrayResize(sortinoArr, g_qualifiedCount);
   ArrayResize(calmarArr, g_qualifiedCount);
   ArrayResize(betaArr, g_qualifiedCount);
   ArrayResize(rollingArr, g_qualifiedCount);

   int idx = 0;
   for(int i = 0; i < POOL_SIZE; i++)
   {
      if(!g_valid[i]) continue;
      adfArr[idx]     = -g_adfTStat[i];
      hlArr[idx]      = -g_halfLife[i];
      hurstArr[idx]   = -g_hurst[i];
      mddArr[idx]     = -g_maxDD[i];
      recArr[idx]     = -(double)g_recoveryDays[i];
      curArr[idx]     = -g_currentDD[i];
      ratioArr[idx]   = -MathAbs(g_downUpRatio[i] - 1.0);
      maxStrArr[idx]  = -(double)g_maxConsecDown[i];
      avgStrArr[idx]  = -g_avgConsecDown[i];
      volConvArr[idx] = -g_volConv[i];
      sortinoArr[idx] = g_sortino[i];
      calmarArr[idx]  = g_calmar[i];
      betaArr[idx]    = -MathAbs(g_beta[i] - 1.0);
      rollingArr[idx] = -g_rollingMDD[i];
      idx++;
   }

   double norm[];

   ZScoreNormalize(adfArr, g_qualifiedCount, norm);
   idx = 0;
   for(int i = 0; i < POOL_SIZE; i++) { if(!g_valid[i]) continue; g_adfScore[i] = norm[idx]; idx++; }

   ZScoreNormalize(hlArr, g_qualifiedCount, norm);
   idx = 0;
   for(int i = 0; i < POOL_SIZE; i++) { if(!g_valid[i]) continue; g_hlScore[i] = norm[idx]; idx++; }

   ZScoreNormalize(hurstArr, g_qualifiedCount, norm);
   idx = 0;
   for(int i = 0; i < POOL_SIZE; i++) { if(!g_valid[i]) continue; g_hurstScore[i] = norm[idx]; idx++; }

   ZScoreNormalize(mddArr, g_qualifiedCount, norm);
   idx = 0;
   for(int i = 0; i < POOL_SIZE; i++) { if(!g_valid[i]) continue; g_mddScore[i] = norm[idx]; idx++; }

   ZScoreNormalize(recArr, g_qualifiedCount, norm);
   idx = 0;
   for(int i = 0; i < POOL_SIZE; i++) { if(!g_valid[i]) continue; g_recScore[i] = norm[idx]; idx++; }

   ZScoreNormalize(curArr, g_qualifiedCount, norm);
   idx = 0;
   for(int i = 0; i < POOL_SIZE; i++) { if(!g_valid[i]) continue; g_curScore[i] = norm[idx]; idx++; }

   ZScoreNormalize(ratioArr, g_qualifiedCount, norm);
   idx = 0;
   for(int i = 0; i < POOL_SIZE; i++) { if(!g_valid[i]) continue; g_ratioScore[i] = norm[idx]; idx++; }

   ZScoreNormalize(maxStrArr, g_qualifiedCount, norm);
   idx = 0;
   for(int i = 0; i < POOL_SIZE; i++) { if(!g_valid[i]) continue; g_streakScore[i] = norm[idx]; idx++; }

   ZScoreNormalize(avgStrArr, g_qualifiedCount, norm);
   idx = 0;
   for(int i = 0; i < POOL_SIZE; i++) { if(!g_valid[i]) continue; g_avgStreakScore[i] = norm[idx]; idx++; }

   ZScoreNormalize(volConvArr, g_qualifiedCount, norm);
   idx = 0;
   for(int i = 0; i < POOL_SIZE; i++) { if(!g_valid[i]) continue; g_volConvScore[i] = norm[idx]; idx++; }

   ZScoreNormalize(sortinoArr, g_qualifiedCount, norm);
   idx = 0;
   for(int i = 0; i < POOL_SIZE; i++) { if(!g_valid[i]) continue; g_sortinoScore[i] = norm[idx]; idx++; }

   ZScoreNormalize(calmarArr, g_qualifiedCount, norm);
   idx = 0;
   for(int i = 0; i < POOL_SIZE; i++) { if(!g_valid[i]) continue; g_calmarScore[i] = norm[idx]; idx++; }

   ZScoreNormalize(betaArr, g_qualifiedCount, norm);
   idx = 0;
   for(int i = 0; i < POOL_SIZE; i++) { if(!g_valid[i]) continue; g_betaScore[i] = norm[idx]; idx++; }

   ZScoreNormalize(rollingArr, g_qualifiedCount, norm);
   idx = 0;
   for(int i = 0; i < POOL_SIZE; i++) { if(!g_valid[i]) continue; g_rollingMDDScore[i] = norm[idx]; idx++; }
}

//+------------------------------------------------------------------+
//| 综合评分                                                          |
//+------------------------------------------------------------------+
void CalcCompositeScore()
{
   double sumMR = InpW_ADF + InpW_HalfLife + InpW_Hurst;
   double sumDD = InpW_MaxDD + InpW_Recovery + InpW_CurrentDD;
   double sumVA = InpW_Ratio + InpW_MaxStreak + InpW_AvgStreak;
   double sumVP = InpW_VolConv;
   double sumRE = InpW_Sortino + InpW_Calmar;

   double wADF     = (sumMR > 0) ? InpW_ADF / sumMR : 0.0;
   double wHL      = (sumMR > 0) ? InpW_HalfLife / sumMR : 0.0;
   double wHurst   = (sumMR > 0) ? InpW_Hurst / sumMR : 0.0;
   double wMaxDD   = (sumDD > 0) ? InpW_MaxDD / sumDD : 0.0;
   double wRec     = (sumDD > 0) ? InpW_Recovery / sumDD : 0.0;
   double wCurDD   = (sumDD > 0) ? InpW_CurrentDD / sumDD : 0.0;
   double wRatio   = (sumVA > 0) ? InpW_Ratio / sumVA : 0.0;
   double wMaxStr  = (sumVA > 0) ? InpW_MaxStreak / sumVA : 0.0;
   double wAvgStr  = (sumVA > 0) ? InpW_AvgStreak / sumVA : 0.0;
   double wVolConv = (sumVP > 0) ? InpW_VolConv / sumVP : 0.0;
   double wSortino = (sumRE > 0) ? InpW_Sortino / sumRE : 0.0;
   double wCalmar  = (sumRE > 0) ? InpW_Calmar / sumRE : 0.0;

   double sumDim = InpW_MeanReversion + InpW_Drawdown + InpW_VolAdditivity
                 + InpW_VolumePrice + InpW_ReturnEff + InpW_Systematic + InpW_RollingMDD;
   if(sumDim < 1e-12) sumDim = 1.0;

   double wMR = InpW_MeanReversion / sumDim;
   double wDD = InpW_Drawdown / sumDim;
   double wVA = InpW_VolAdditivity / sumDim;
   double wVP = InpW_VolumePrice / sumDim;
   double wRE = InpW_ReturnEff / sumDim;
   double wSY = InpW_Systematic / sumDim;
   double wRM = InpW_RollingMDD / sumDim;

   for(int i = 0; i < POOL_SIZE; i++)
   {
      if(!g_valid[i]) { g_score[i] = -9999.0; continue; }

      double scoreMR = wADF * g_adfScore[i] + wHL * g_hlScore[i] + wHurst * g_hurstScore[i];
      double scoreDD = wMaxDD * g_mddScore[i] + wRec * g_recScore[i] + wCurDD * g_curScore[i];
      double scoreVA = wRatio * g_ratioScore[i] + wMaxStr * g_streakScore[i] + wAvgStr * g_avgStreakScore[i];
      double scoreVP = wVolConv * g_volConvScore[i];
      double scoreRE = wSortino * g_sortinoScore[i] + wCalmar * g_calmarScore[i];
      double scoreSY = g_betaScore[i];
      double scoreRM = g_rollingMDDScore[i];

      g_score[i] = wMR * scoreMR + wDD * scoreDD + wVA * scoreVA + wVP * scoreVP
                 + wRE * scoreRE + wSY * scoreSY + wRM * scoreRM;
   }
}

//+------------------------------------------------------------------+
//| 排序（按评分降序）                                                 |
//+------------------------------------------------------------------+
void SortByScore(int &rankArr[], int count)
{
   for(int i = 0; i < count - 1; i++)
      for(int j = 0; j < count - 1 - i; j++)
         if(g_score[rankArr[j]] < g_score[rankArr[j+1]])
         {
            int tmp = rankArr[j];
            rankArr[j] = rankArr[j+1];
            rankArr[j+1] = tmp;
         }
}

//+------------------------------------------------------------------+
//| 生成槽位字符串                                                     |
//+------------------------------------------------------------------+
string BuildSlotString(const string sym, const string cls)
{
   string s = sym + "," + InpSlotStartTime + ",";
   s += InpSlotAllowBuy  ? "true" : "false";  s += ",";
   s += InpSlotAllowSell ? "true" : "false";  s += ",";
   s += InpSlotProfitBuy ? "true" : "false";  s += ",";
   s += InpSlotProfitSell? "true" : "false";  s += ",";
   s += DoubleToString(InpSlotLots, 2);       s += ",";
   s += cls;
   return s;
}

//+------------------------------------------------------------------+
//| 输出 CSV                                                          |
//+------------------------------------------------------------------+
void WriteCSV(int &classARank[], int classACount, int &classBRank[], int classBCount)
{
   // 用逗号分隔,SlotString 手动加引号包住(它本身含逗号),这样 Excel/Numbers 能正确分列
   int handle = FileOpen("reliability_ranking.csv", FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(handle == INVALID_HANDLE) { Print("CSV 打开失败"); return; }

   FileWrite(handle, "Rank", "Class", "Code", "Score",
             "ADF_t", "HalfLife", "Hurst",
             "MaxDD", "RecoveryBars", "CurrentDD",
             "DownUpRatio", "MaxConsecDown", "AvgConsecDown",
             "VolConv", "RollingMDD",
             "Sortino", "Calmar", "Beta",
             "FundPct", "ROE", "NetMargin", "GrossMargin", "EarnVol", "NetDebtEBITDA", "IntCov",
             "DividendYield",
             "SlotString");

   int rank = 0;

   for(int r = 0; r < classACount; r++)
   {
      int i = classARank[r];
      rank++;
      FileWrite(handle,
                IntegerToString(rank),
                "A",
                g_symbols[i],
                DoubleToString(g_score[i], 4),
                DoubleToString(g_adfTStat[i], 4),
                DoubleToString(g_halfLife[i], 2),
                DoubleToString(g_hurst[i], 4),
                DoubleToString(g_maxDD[i], 4),
                IntegerToString((int)g_recoveryDays[i]),
                DoubleToString(g_currentDD[i], 4),
                DoubleToString(g_downUpRatio[i], 4),
                IntegerToString((int)g_maxConsecDown[i]),
                DoubleToString(g_avgConsecDown[i], 2),
                DoubleToString(g_volConv[i], 4),
                DoubleToString(g_rollingMDD[i], 4),
                DoubleToString(g_sortino[i], 4),
                DoubleToString(g_calmar[i], 4),
                DoubleToString(g_beta[i], 4),
                DoubleToString(g_fundPct[i], 4),
                DoubleToString(g_fundRaw[i][0], 4),
                DoubleToString(g_fundRaw[i][1], 4),
                DoubleToString(g_fundRaw[i][2], 4),
                DoubleToString(g_fundRaw[i][3], 4),
                DoubleToString(g_fundRaw[i][4], 4),
                DoubleToString(g_fundRaw[i][5], 4),
                DoubleToString(g_fundRaw[i][6], 4),
                "\"" + BuildSlotString(g_symbols[i], "A") + "\"");
   }

   for(int r = 0; r < classBCount; r++)
   {
      int i = classBRank[r];
      rank++;
      FileWrite(handle,
                IntegerToString(rank),
                "B",
                g_symbols[i],
                DoubleToString(g_score[i], 4),
                DoubleToString(g_adfTStat[i], 4),
                DoubleToString(g_halfLife[i], 2),
                DoubleToString(g_hurst[i], 4),
                DoubleToString(g_maxDD[i], 4),
                IntegerToString((int)g_recoveryDays[i]),
                DoubleToString(g_currentDD[i], 4),
                DoubleToString(g_downUpRatio[i], 4),
                IntegerToString((int)g_maxConsecDown[i]),
                DoubleToString(g_avgConsecDown[i], 2),
                DoubleToString(g_volConv[i], 4),
                DoubleToString(g_rollingMDD[i], 4),
                DoubleToString(g_sortino[i], 4),
                DoubleToString(g_calmar[i], 4),
                DoubleToString(g_beta[i], 4),
                DoubleToString(g_fundPct[i], 4),
                DoubleToString(g_fundRaw[i][0], 4),
                DoubleToString(g_fundRaw[i][1], 4),
                DoubleToString(g_fundRaw[i][2], 4),
                DoubleToString(g_fundRaw[i][3], 4),
                DoubleToString(g_fundRaw[i][4], 4),
                DoubleToString(g_fundRaw[i][5], 4),
                DoubleToString(g_fundRaw[i][6], 4),
                "\"" + BuildSlotString(g_symbols[i], "B") + "\"");
   }

   FileClose(handle);
}

//+------------------------------------------------------------------+
//| 输出日志                                                          |
//+------------------------------------------------------------------+
void PrintSummary(int &classARank[], int classACount, int &classBRank[], int classBCount)
{
   Print("========== 可靠性排序完成 ==========");
   PrintFormat("时间框架: %s | 起止: %s ~ %s",
               EnumToString(InpTimeframe),
               TimeToString(InpStartDate, TIME_DATE),
               TimeToString(InpEndDate, TIME_DATE));
   PrintFormat("原始股票池: %d | 有效数据: %d", POOL_SIZE, g_qualifiedCount);
   PrintFormat("一类标的（通过全部过滤）: %d 只", classACount);
   PrintFormat("二类标的（未通过全部过滤，按评分截取）: %d 只", classBCount);
   PrintFormat("总标的数量上限: %d", InpTotalCount);
   PrintFormat("滚动回撤窗口: %d交易日 (%d根K线) | 阈值: %.0f%%",
               InpRollingMDDWindowDays, DaysToBars(InpRollingMDDWindowDays, InpTimeframe),
               InpRollingMDDThreshold * 100.0);
   Print("------------------------------------");

   PrintFormat("【一类标的 - 共%d只】", classACount);
   for(int r = 0; r < classACount; r++)
   {
      int i = classARank[r];
      PrintFormat("  A%02d | %-12s | Score: %7.4f | RollMDD: %5.2f%% | MaxDD: %5.2f%% | HL: %6.1f | ADF: %6.2f",
                  r+1, g_symbols[i], g_score[i],
                  g_rollingMDD[i]*100.0, g_maxDD[i]*100.0,
                  g_halfLife[i], g_adfTStat[i]);
   }

   Print("------------------------------------");
   PrintFormat("【二类标的 - 共%d只】", classBCount);
   int showB = (classBCount < InpLogTopN) ? classBCount : InpLogTopN;
   for(int r = 0; r < showB; r++)
   {
      int i = classBRank[r];
      PrintFormat("  B%02d | %-12s | Score: %7.4f | RollMDD: %5.2f%% | MaxDD: %5.2f%% | HL: %6.1f | ADF: %6.2f",
                  r+1, g_symbols[i], g_score[i],
                  g_rollingMDD[i]*100.0, g_maxDD[i]*100.0,
                  g_halfLife[i], g_adfTStat[i]);
   }
   if(classBCount > showB)
      PrintFormat("  ...（仅显示前%d名，完整结果见CSV）", showB);

   Print("------------------------------------");
   Print("完整结果（含SlotString可粘贴字符串）已写入 MQL5/Files/reliability_ranking.csv");
   Print("====================================");
}

//+------------------------------------------------------------------+
//| 主流程                                                            |
//+------------------------------------------------------------------+
void RunScreening()
{
   g_barsPerYear = CalcBarsPerYear(InpTimeframe);
   int rollingWindowBars = DaysToBars(InpRollingMDDWindowDays, InpTimeframe);

   for(int i = 0; i < POOL_SIZE; i++)
   {
      g_valid[i] = false;
      g_passRecovery[i] = false;
      g_passRolling[i] = false;
      g_isClassA[i] = false;
      g_adfTStat[i] = 0.0;
      g_halfLife[i] = 9999.0;
      g_hurst[i] = 0.5;
      g_maxDD[i] = 1.0;
      g_recoveryDays[i] = 9999;
      g_currentDD[i] = 1.0;
      g_downUpRatio[i] = 999.0;
      g_maxConsecDown[i] = 9999;
      g_avgConsecDown[i] = 999.0;
      g_sortino[i] = -999.0;
      g_calmar[i] = -999.0;
      g_beta[i] = 1.0;
      g_volConv[i] = 1.0;
      g_rollingMDD[i] = 1.0;
      g_score[i] = -9999.0;
   }
   g_qualifiedCount = 0;

   double    indexCloses[];
   datetime  indexTimes[];
   int       nIndex = 0;

   string indexSym = ResolveIndexSymbol(InpIndexSymbol);
   int nClose = CopyClose(indexSym, InpTimeframe, InpStartDate, InpEndDate, indexCloses);
   int nTime  = CopyTime(indexSym, InpTimeframe, InpStartDate, InpEndDate, indexTimes);

   if(nClose < InpMinBars || nTime != nClose)
   {
      nClose = CopyClose(indexSym, InpTimeframe, 0, InpFallbackBars, indexCloses);
      nTime  = CopyTime(indexSym, InpTimeframe, 0, InpFallbackBars, indexTimes);
   }

   if(nClose >= InpMinBars && nTime == nClose)
   {
      ArraySetAsSeries(indexCloses, false);
      ArraySetAsSeries(indexTimes, false);
      nIndex = nClose;
   }

   PrintFormat("基准品种=[%s] nIndex=%d | 滚动窗口=%d根K线",
               indexSym, nIndex, rollingWindowBars);

   //---- 基本面硬过滤：先把因子表读进来 ----
   bool fundReady = false;
   if(InpUseFundamental)
   {
      fundReady = LoadFundamentals();
      if(!fundReady)
         Print("!! 基本面过滤未生效(文件缺失或格式不对)，本轮按纯价格逻辑运行");
   }

   uint tStart = GetTickCount();
   for(int i = 0; i < POOL_SIZE; i++)
   {
      string sym = ResolveUSSymbol(g_symbols[i], InpTimeframe, InpStartDate, InpEndDate, InpMinBars);
      if(sym == "" || !SymbolSelect(sym, true))
      {
         PrintFormat("[%d/%d] %s 未提供，跳过", i + 1, POOL_SIZE, g_symbols[i]);
         continue;
      }
      g_symbols[i] = sym;   // 后续输出统一用真实品种名

      //---- 基本面硬过滤 ----
      if(InpUseFundamental && fundReady)
      {
         if(!g_fundHas[i])
         {
            g_fundNoData++;
            PrintFormat("[%d/%d] %s 无基本面数据，淘汰", i + 1, POOL_SIZE, sym);
            continue;
         }
         if(g_fundPct[i] < InpFundMinPct)
         {
            g_fundDropped++;
            PrintFormat("[%d/%d] %s 基本面综合分位 %.3f < %.2f，淘汰",
                        i + 1, POOL_SIZE, sym, g_fundPct[i], InpFundMinPct);
            continue;
         }
         g_fundKept++;
      }

      PrintFormat("[%d/%d] %s ...", i + 1, POOL_SIZE, sym);

      double   closes[];
      datetime stockTimes[];
      int copiedClose = CopyClose(sym, InpTimeframe, InpStartDate, InpEndDate, closes);
      int copiedTime  = CopyTime(sym, InpTimeframe, InpStartDate, InpEndDate, stockTimes);

      if(copiedClose < InpMinBars || copiedTime != copiedClose)
      {
         copiedClose = CopyClose(sym, InpTimeframe, 0, InpFallbackBars, closes);
         copiedTime  = CopyTime(sym, InpTimeframe, 0, InpFallbackBars, stockTimes);
         if(copiedClose >= InpMinBars && copiedTime == copiedClose)
            PrintFormat("    %s 指定区间无数据，已回退取最近 %d 根K线", sym, copiedClose);
      }

      if(copiedClose < InpMinBars || copiedTime != copiedClose)
      {
         PrintFormat("    %s 数据不足（K线=%d）跳过", sym,
                     copiedClose < copiedTime ? copiedClose : copiedTime);
         continue;
      }

      ArraySetAsSeries(closes, false);
      ArraySetAsSeries(stockTimes, false);
      int copied = copiedClose;

      double returns[];
      if(!CalcLogReturns(closes, copied, returns)) continue;
      int retCount = ArraySize(returns);

      g_rollingMDD[i] = CalcRollingMDD(closes, copied, rollingWindowBars);
      g_passRolling[i] = (g_rollingMDD[i] <= InpRollingMDDThreshold);

      double halfLife, lambda;
      bool hlValid;
      CalcHalfLife(closes, copied, halfLife, lambda, hlValid);
      g_halfLife[i] = hlValid ? halfLife : 9999.0;
      if(g_halfLife[i] > (double)InpHalfLifeCap) g_halfLife[i] = 9999.0;

      ADFResult adfResult;
      if(CalcADF(closes, copied, InpADFLagOrder, adfResult))
      {
         g_adfTStat[i] = adfResult.tStat;
         if(g_halfLife[i] > 9000.0 && adfResult.halfLife < 9000.0 && adfResult.halfLife <= (double)InpHalfLifeCap)
            g_halfLife[i] = adfResult.halfLife;
      }

      HurstResult hurstResult;
      if(CalcHurst(returns, retCount, hurstResult) && hurstResult.rSquared > 0.7)
         g_hurst[i] = hurstResult.hurst;
      else
         g_hurst[i] = 0.5;
      if(g_hurst[i] < 0.0 || g_hurst[i] > 1.0) g_hurst[i] = 0.5;

      DrawdownResult ddResult;
      if(!CalcDrawdown(closes, copied, ddResult))
      {
         PrintFormat("%s 回撤计算失败", sym);
         continue;
      }
      g_maxDD[i] = ddResult.maxDD;
      g_recoveryDays[i] = ddResult.recoveryDays;
      g_currentDD[i] = ddResult.currentDD;
      g_passRecovery[i] = ddResult.recovered;

      double downUpRatio, downVol, upVol;
      if(CalcDownUpRatio(returns, retCount, downUpRatio, downVol, upVol))
         g_downUpRatio[i] = downUpRatio;

      DownStreakResult dsResult;
      if(CalcDownStreak(returns, retCount, dsResult))
      {
         g_maxConsecDown[i] = dsResult.maxConsecDown;
         g_avgConsecDown[i] = dsResult.avgConsecDown;
      }

      g_volConv[i] = CalcVolConvergence(returns, retCount);

      double sortino, annualReturn, downVolAnnual;
      if(CalcSortino(returns, retCount, InpRiskFreeRate, sortino, annualReturn, downVolAnnual))
         g_sortino[i] = sortino;

      double calmar;
      if(CalcCalmar(annualReturn, g_maxDD[i], calmar))
         g_calmar[i] = calmar;

      if(nIndex >= 20)
      {
         double sRet[], iRet[];
         ArrayResize(sRet, copied);
         ArrayResize(iRet, copied);
         int matched = 0;
         for(int j = 1; j < copied; j++)
         {
            int idx     = FindTimeIndex(indexTimes, nIndex, stockTimes[j]);
            int idxPrev = FindTimeIndex(indexTimes, nIndex, stockTimes[j-1]);
            if(idx < 0 || idxPrev < 0) continue;
            if(idx == idxPrev) continue;
            if(indexCloses[idxPrev] <= 0.0) continue;
            sRet[matched] = MathLog(closes[j] / closes[j-1]);
            iRet[matched] = MathLog(indexCloses[idx] / indexCloses[idxPrev]);
            matched++;
         }
         if(matched >= 20)
         {
            double beta = 0.0;
            if(CalcBeta(sRet, iRet, matched, beta))
               g_beta[i] = beta;
         }
      }

      g_isClassA[i] = (g_passRecovery[i] && g_passRolling[i]);

      g_valid[i] = true;
      g_qualifiedCount++;
   }

   PrintFormat("扫描完成，用时 %.1f 秒", (GetTickCount() - tStart) / 1000.0);
   if(InpUseFundamental && fundReady)
      PrintFormat("基本面过滤: 分位达标 %d 只 | 分位不足淘汰 %d 只 | 无基本面数据淘汰 %d 只 | 阈值 %.2f",
                  g_fundKept, g_fundDropped, g_fundNoData, InpFundMinPct);
   PrintFormat("有效数据: %d 只", g_qualifiedCount);
   if(g_qualifiedCount < 2)
   {
      Print("有效数据不足 2 只，未生成 CSV。");
      Print("排查方向：");
      Print("  1) 终端是否已连上服务器（日志里应有 authorized on ...；状态栏不显示 No connection）");
      Print("  2) 数据区间内是否真有K线（可把区间改到本年度，脚本也会自动回退取最近K线）");
      Print("  3) 品种名是否匹配（纯代码 vs 代码.US）");
      PrintFormat("  当前基准=%s | 区间=%s ~ %s | 回退K线数=%d",
                  indexSym, TimeToString(InpStartDate, TIME_DATE),
                  TimeToString(InpEndDate, TIME_DATE), InpFallbackBars);
      return;
   }

   NormalizeIndicators();
   CalcCompositeScore();

   int classARank[]; int classBRank[];
   ArrayResize(classARank, g_qualifiedCount);
   ArrayResize(classBRank, g_qualifiedCount);
   int classACount = 0, classBCount = 0;

   for(int i = 0; i < POOL_SIZE; i++)
   {
      if(!g_valid[i]) continue;
      if(g_isClassA[i]) classARank[classACount++] = i;
      else              classBRank[classBCount++] = i;
   }

   SortByScore(classARank, classACount);
   SortByScore(classBRank, classBCount);

   int classBLimit = InpTotalCount - classACount;
   if(classBLimit < 0) classBLimit = 0;
   if(classBCount > classBLimit) classBCount = classBLimit;

   PrintFormat("最终保留：一类%d只 + 二类%d只 = %d只",
               classACount, classBCount, classACount + classBCount);

   WriteCSV(classARank, classACount, classBRank, classBCount);
   PrintSummary(classARank, classACount, classBRank, classBCount);
}

//+------------------------------------------------------------------+
void OnStart()
{
   RunScreening();
}
//+------------------------------------------------------------------+
