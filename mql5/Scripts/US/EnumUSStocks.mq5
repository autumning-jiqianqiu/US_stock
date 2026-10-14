//+------------------------------------------------------------------+
//|                                                EnumUSStocks.mq5  |
//|  列出经纪商全部品种并导出 CSV(含美股筛选标记)                      |
//|  运行后输出: MQL5/Files/USSymbols.csv                              |
//+------------------------------------------------------------------+
#property script_show_inputs
#property version "1.00"
#property description "导出经纪商全部品种名到 CSV,便于核对美股 CFD 的真实命名"

input bool InpOnlyUSLike = false;   // 只导出看起来像美股的品种(名字含 .US)

//+------------------------------------------------------------------+
//| 把可能含逗号/换行的字段清洗掉,避免 CSV 列错位                     |
//+------------------------------------------------------------------+
string Clean(const string s)
{
   string out = s;
   StringReplace(out, ",", ";");
   StringReplace(out, "\r", " ");
   StringReplace(out, "\n", " ");
   return out;
}

//+------------------------------------------------------------------+
void OnStart()
{
   int total = SymbolsTotal(false);
   if(total <= 0)
   {
      Print("品种列表为空,请确认终端已连接经纪商。error=", GetLastError());
      return;
   }

   int handle = FileOpen("USSymbols.csv", FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(handle == INVALID_HANDLE)
   {
      Print("无法创建 CSV,error=", GetLastError());
      return;
   }

   FileWrite(handle, "Index", "Symbol", "Description", "Path",
             "CurrencyBase", "CurrencyProfit", "Digits", "IsUSLike");

   int usCount = 0;
   int written = 0;
   for(int i = 0; i < total; i++)
   {
      string name = SymbolName(i, false);
      if(name == "")
         continue;

      string upper = name;
      StringToUpper(upper);
      bool usLike = (StringFind(upper, ".US") >= 0);
      if(usLike)
         usCount++;
      if(InpOnlyUSLike && !usLike)
         continue;

      string desc     = SymbolInfoString(name, SYMBOL_DESCRIPTION);
      string path     = SymbolInfoString(name, SYMBOL_PATH);
      string curBase  = SymbolInfoString(name, SYMBOL_CURRENCY_BASE);
      string curProf  = SymbolInfoString(name, SYMBOL_CURRENCY_PROFIT);
      int    digits   = (int)SymbolInfoInteger(name, SYMBOL_DIGITS);

      FileWrite(handle,
                IntegerToString(i),
                Clean(name),
                Clean(desc),
                Clean(path),
                Clean(curBase),
                Clean(curProf),
                IntegerToString(digits),
                usLike ? "Y" : "N");
      written++;
   }

   FileClose(handle);
   PrintFormat("品种总数=%d, 名称含 .US 的=%d, 已写出=%d -> MQL5/Files/USSymbols.csv",
               total, usCount, written);
}
//+------------------------------------------------------------------+
