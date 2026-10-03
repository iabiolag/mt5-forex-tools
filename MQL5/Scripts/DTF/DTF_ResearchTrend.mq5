//+------------------------------------------------------------------+
//|                                             DTF_ResearchTrend.mq5 |
//|   Daily Trend-Following System - does the signal work where       |
//|   trend actually exists?                                          |
//+------------------------------------------------------------------+
//| The seven non-USD crosses showed no daily trend persistence at all
//| over 2019-2023: a pure momentum baseline was NEGATIVE on five of
//| the seven. A trend system cannot be judged on data with no trend
//| in it, so this exports the same per-bar data for instruments that
//| demonstrably DID trend over the same period.
//|
//| If the signal shows edge here, the design is sound and the crosses
//| were simply the wrong universe. If it is null here too, the signal
//| itself needs rebuilding and no amount of extra history will help.
//|
//| NO INPUT DIALOG BY DESIGN - drag it on, it runs. Everything is
//| compiled in so a mis-set field cannot silently produce the wrong
//| dataset, which has already happened twice.
//+------------------------------------------------------------------+
#property copyright "DTF"
#property version   "1.00"
#property description "Exports signal vs forward returns for trending instruments."

#include <DTF/ResearchExport.mqh>

//--- Gold and BTC trended hard 2019-2023; EURUSD is the USD major with
//--- full local history and carried the 2022 dollar trend.
const string TrendSymbols = "EURUSD,XAUUSD,BTCUSD";
const string OutFile      = "DTF_research_trend.csv";
const string Suffix       = "m";

//+------------------------------------------------------------------+
void OnStart()
  {
   Print("=== DTF research export: trending instruments ===");
   PrintFormat("symbols: %s   suffix: \"%s\"",TrendSymbols,Suffix);

   SDtfResearchCfg cfg;
   DtfResearchDefaults(cfg);          // identical to the EA's defaults

   int rows=DtfExportResearch(TrendSymbols,"",Suffix,OutFile,cfg);

   if(rows==0)
      Print("Nothing exported. If symbols were SKIPPED, open a D1 chart for "
            "each and scroll back to force the history download, then rerun.");
  }
//+------------------------------------------------------------------+
