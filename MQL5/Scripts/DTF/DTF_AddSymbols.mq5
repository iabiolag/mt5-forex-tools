//+------------------------------------------------------------------+
//|                                                DTF_AddSymbols.mq5 |
//|   Daily Trend-Following System - put the basket in Market Watch   |
//+------------------------------------------------------------------+
//| WHY THIS EXISTS
//| ---------------
//| The Strategy Tester's Symbol dropdown only offers symbols that are
//| currently shown in Market Watch. A pair that exists on the server
//| but is hidden simply cannot be selected, and the tester quietly
//| keeps whatever symbol was there before - so every run goes to the
//| wrong pair without any error.
//|
//| Drag this script onto any chart ONCE. It shows every pair in the
//| basket and reports how far back each one's daily history goes, so
//| you know which are testable before spending time on a run.
//+------------------------------------------------------------------+
#property copyright "DTF"
#property version   "1.00"
#property script_show_inputs
#property description "Adds the DTF basket to Market Watch and reports history depth."

input string InpSuffix   = "m";    // Broker symbol suffix (e.g. "m" for EURUSDm)
input string InpPrefix   = "";     // Broker symbol prefix (usually empty)
input int    InpWarmupBars = 272;  // Bars the EA needs before it can trade

//--- The non-USD basket, plus the majors for comparison. Editing this
//--- list is the only change needed to test a different basket.
string BasketCross[] =
  {
   "EURJPY","AUDJPY","GBPJPY","EURGBP","EURCHF",
   "AUDNZD","AUDCAD","AUDCHF","GBPCHF","CADJPY","NZDCAD"
  };
string BasketMajor[] =
  {
   "EURUSD","GBPUSD","USDJPY","AUDUSD","USDCAD","USDCHF","NZDUSD"
  };

//+------------------------------------------------------------------+
//| Ask for the series and wait briefly for the server to deliver it. |
//| A freshly shown symbol has no history cached yet, so the first    |
//| read almost always returns nothing.                                |
//+------------------------------------------------------------------+
datetime FirstDailyBar(const string sym,int &bars_out)
  {
   bars_out=0;
   long value=0;
   datetime first=0;

   for(int attempt=0;attempt<40;attempt++)
     {
      MqlRates r[];
      CopyRates(sym,PERIOD_D1,0,10,r);      // nudges the download

      if(SeriesInfoInteger(sym,PERIOD_D1,SERIES_FIRSTDATE,value) && value>0)
        {
         first=(datetime)value;
         bars_out=Bars(sym,PERIOD_D1);
         if(bars_out>0)
            return(first);
        }
      Sleep(250);
     }
   return(first);
  }
//+------------------------------------------------------------------+
void Report(const string &list[],const string heading)
  {
   PrintFormat("--- %s ---",heading);

   for(int i=0;i<ArraySize(list);i++)
     {
      string name=InpPrefix+list[i]+InpSuffix;

      if(!SymbolSelect(name,true))
        {
         //--- maybe this broker has no suffix on this one
         string bare=list[i];
         if(SymbolSelect(bare,true))
            name=bare;
         else
           {
            PrintFormat("  %-12s NOT AVAILABLE on this server",name);
            continue;
           }
        }

      int bars=0;
      datetime first=FirstDailyBar(name,bars);

      if(first<=0 || bars<=0)
        {
         PrintFormat("  %-12s shown, history still downloading - rerun this script",name);
         continue;
        }

      int tradeable=bars-InpWarmupBars;
      PrintFormat("  %-12s shown | D1 from %s | %d bars | ~%d tradeable after warm-up%s",
                  name,TimeToString(first,TIME_DATE),bars,
                  (tradeable>0 ? tradeable : 0),
                  (tradeable<250 ? "   <-- TOO SHALLOW" : ""));
     }
  }
//+------------------------------------------------------------------+
void OnStart()
  {
   Print("=== DTF: adding basket to Market Watch ===");
   Print("Suffix in use: \"",InpSuffix,"\"   (change the input if your broker differs)");

   Report(BasketCross,"Non-USD crosses");
   Report(BasketMajor,"Majors (for reference)");

   Print("=== done. The Strategy Tester Symbol dropdown will now list these. ===");
   Print("If a pair says NOT AVAILABLE, your server does not carry it under that name.");
  }
//+------------------------------------------------------------------+
