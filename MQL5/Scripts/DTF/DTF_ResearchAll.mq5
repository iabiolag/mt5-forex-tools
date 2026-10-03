//+------------------------------------------------------------------+
//|                                               DTF_ResearchAll.mq5 |
//|   Diversified multi-asset export - every market with real depth   |
//+------------------------------------------------------------------+
//| Seven AUD-heavy FX crosses gave an effective breadth of maybe
//| three or four independent markets, which is why every test so far
//| has been underpowered. This exports every instrument on the
//| account that actually has downloadable daily history, across
//| metals, energy and FX, so the analysis finally has breadth.
//|
//| Indices (DE30, US30, US500, JP225) are deliberately absent: their
//| history would not download, so including them would only produce
//| empty rows.
//|
//| NO INPUT DIALOG - drag it on and it runs. Everything is compiled
//| in so a mis-set field cannot silently produce the wrong dataset.
//+------------------------------------------------------------------+
#property copyright "DTF"
#property version   "1.00"
#property description "Exports signal and forward returns for all deep-history markets."

#include <DTF/ResearchExport.mqh>

//--- metals, energy, FX major, FX crosses. Anything without history
//--- is reported as SKIPPED rather than silently producing nothing.
const string AllSymbols =
   "XAUUSD,XAGUSD,USOIL,"
   "EURUSD,"
   "EURJPY,AUDJPY,EURGBP,AUDNZD,AUDCAD,AUDCHF,GBPCHF";

const string OutFile = "DTF_research_all.csv";
const string Suffix  = "m";

//+------------------------------------------------------------------+
void OnStart()
  {
   Print("=== DTF diversified research export ===");
   PrintFormat("symbols: %s",AllSymbols);

   SDtfResearchCfg cfg;
   DtfResearchDefaults(cfg);        // identical to the EA's settings

   int rows=DtfExportResearch(AllSymbols,"",Suffix,OutFile,cfg);

   if(rows==0)
      Print("Nothing exported - check the log above for SKIPPED symbols.");
  }
//+------------------------------------------------------------------+
