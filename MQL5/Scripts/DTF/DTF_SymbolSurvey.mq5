//+------------------------------------------------------------------+
//|                                              DTF_SymbolSurvey.mq5 |
//|   What can this broker support a diversified backtest on?         |
//+------------------------------------------------------------------+
//| WHY THIS EXISTS
//| ---------------
//| A 20-day-holding strategy yields ~12 independent observations per
//| market per year. Resolving a realistic +0.10R edge needs roughly
//| 500. One market cannot get there in a lifetime, and seven
//| correlated FX crosses cannot either - BREADTH across uncorrelated
//| asset classes is the only way the arithmetic works. So: which
//| markets does this account offer, with enough history to test?
//|
//| DESIGN NOTE (learned the hard way)
//| SERIES_SERVER_FIRSTDATE needs a server round trip. Asking it for
//| all 356 symbols over an unstable link hung for hours. So this
//| version:
//|   - checks a CURATED candidate list, not every symbol
//|   - prints each result as it goes, so a stall is visible
//|   - opens the CSV with share flags, so it can be read while running
//|   - skips the server call entirely when a symbol already has local
//|     history, since local bars already answer the question
//+------------------------------------------------------------------+
#property copyright "DTF"
#property version   "2.00"
#property description "Surveys candidate markets for history depth and trading costs."

#include <DTF/Common.mqh>

const string OutFile = "DTF_symbol_survey.csv";
const string Suffix  = "m";

//--- Candidates grouped by asset class. Several spellings per market
//--- because index and energy naming differs between brokers; anything
//--- absent is simply reported as NOT FOUND.
const string Candidates =
   // metals
   "XAUUSD,XAGUSD,XPTUSD,XPDUSD,"
   // energy
   "USOIL,UKOIL,XTIUSD,XBRUSD,XNGUSD,"
   // indices
   "US30,US500,USTEC,DE30,DE40,UK100,JP225,HK50,AUS200,FR40,EU50,"
   // crypto
   "BTCUSD,ETHUSD,LTCUSD,XRPUSD,"
   // FX majors
   "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,USDCHF,NZDUSD,"
   // FX crosses already in use
   "EURJPY,AUDJPY,GBPJPY,EURGBP,EURCHF,AUDNZD,AUDCAD,AUDCHF,GBPCHF,CADJPY,NZDCAD";

//+------------------------------------------------------------------+
//| Resolve a base name against this broker's suffix convention.      |
//+------------------------------------------------------------------+
string Resolve(const string base)
  {
   string tries[3];
   tries[0]=base+Suffix;
   tries[1]=base;
   tries[2]=base+"."+Suffix;

   for(int i=0;i<3;i++)
     {
      //--- SymbolInfoInteger on an unknown symbol fails without any
      //--- network access, which is the cheap way to test existence.
      long dummy=0;
      if(SymbolInfoInteger(tries[i],SYMBOL_DIGITS,dummy) && dummy>0)
         return(tries[i]);
     }
   return("");
  }
//+------------------------------------------------------------------+
void OnStart()
  {
   Print("=== DTF symbol survey (curated candidates) ===");

   int h=FileOpen(OutFile,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|
                          FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
     {
      PrintFormat("cannot create %s (error %d)",OutFile,GetLastError());
      return;
     }

   FileWriteString(h,"asset_class,symbol,local_d1_bars,local_first,server_first,"
                     "years_local,digits,spread_points,min_lot,lot_step,"
                     "contract_size,swap_long,swap_short,tradable\r\n");

   string parts[];
   int n=StringSplit(Candidates,',',parts);
   datetime now=TimeCurrent();
   int found=0,usable=0;

   for(int i=0;i<n;i++)
     {
      string base=parts[i];
      StringTrimLeft(base); StringTrimRight(base);
      if(StringLen(base)==0)
         continue;

      string sym=Resolve(base);
      if(StringLen(sym)==0)
        {
         PrintFormat("  %-10s NOT FOUND",base);
         continue;
        }
      found++;

      bool was=(bool)SymbolInfoInteger(sym,SYMBOL_SELECT);
      if(!was)
         SymbolSelect(sym,true);

      int      bars=Bars(sym,PERIOD_D1);
      datetime lf=0,sf=0;
      long     v=0;
      if(SeriesInfoInteger(sym,PERIOD_D1,SERIES_TERMINAL_FIRSTDATE,v))
         lf=(datetime)v;

      //--- Only ask the SERVER when we have little or nothing locally.
      //--- That one call is the slow, network-bound part.
      if(bars<500)
        {
         if(SeriesInfoInteger(sym,PERIOD_D1,SERIES_SERVER_FIRSTDATE,v))
            sf=(datetime)v;
        }

      double years=(lf>0 ? (double)(now-lf)/(365.25*86400.0) : 0.0);
      if(bars>=1500)
         usable++;

      bool tradable=((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(sym,SYMBOL_TRADE_MODE)
                     ==SYMBOL_TRADE_MODE_FULL);

      string cls=SymbolInfoString(sym,SYMBOL_PATH);

      FileWriteString(h,
         "\""+cls+"\","+sym+","+
         IntegerToString(bars)+","+
         (lf>0 ? TimeToString(lf,TIME_DATE) : "none")+","+
         (sf>0 ? TimeToString(sf,TIME_DATE) : "not-queried")+","+
         DoubleToString(years,2)+","+
         IntegerToString((int)SymbolInfoInteger(sym,SYMBOL_DIGITS))+","+
         IntegerToString((int)SymbolInfoInteger(sym,SYMBOL_SPREAD))+","+
         DoubleToString(SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN),2)+","+
         DoubleToString(SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP),2)+","+
         DoubleToString(SymbolInfoDouble(sym,SYMBOL_TRADE_CONTRACT_SIZE),2)+","+
         DoubleToString(SymbolInfoDouble(sym,SYMBOL_SWAP_LONG),4)+","+
         DoubleToString(SymbolInfoDouble(sym,SYMBOL_SWAP_SHORT),4)+","+
         (tradable ? "1" : "0")+"\r\n");

      FileFlush(h);        // so progress is readable while it runs

      PrintFormat("  %-10s %5d D1 bars  from %s  spread %d  minlot %.2f",
                  sym,bars,(lf>0 ? TimeToString(lf,TIME_DATE) : "none"),
                  (int)SymbolInfoInteger(sym,SYMBOL_SPREAD),
                  SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN));

      if(!was)
         SymbolSelect(sym,false);
     }

   FileClose(h);
   PrintFormat("=== done: %d of %d candidates exist, %d have 1500+ local D1 bars ===",
               found,n,usable);
   Print("Symbols with few local bars need their history downloading: open a D1");
   Print("chart for each, scroll back, then rerun this script.");
  }
//+------------------------------------------------------------------+
