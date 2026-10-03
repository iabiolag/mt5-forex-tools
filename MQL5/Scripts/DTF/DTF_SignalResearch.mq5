//+------------------------------------------------------------------+
//|                                            DTF_SignalResearch.mq5 |
//|      Daily Trend-Following System - does the entry signal work?   |
//+------------------------------------------------------------------+
//| WHY THIS EXISTS
//| ---------------
//| Phase 2 backtests said the system loses money, but they cannot say
//| WHY, because a trade record is the signal, the stop, the trail and
//| the spread all tangled together. Worse, the journal only contains
//| trades we took - every bar the threshold rejected is invisible, so
//| the sample is selected by the very rule under suspicion.
//|
//| This script answers the prior question directly: on EVERY daily
//| bar, what was the signal, and what did price do NEXT? No entries,
//| no stops, no exits - just the signal and the forward return.
//|
//| Forward returns are expressed in ATR units, so pairs are directly
//| comparable and the numbers convert to R (the system risks 3xATR,
//| so 3 ATR of favourable move = 1R).
//|
//| The key column is fwd_N_dir: the forward move SIGNED BY THE
//| SIGNAL'S DIRECTION. If the ensemble has any edge at all, that
//| column must be positive on average and should grow with |signal|.
//| If it is flat or negative, no exit rule can save the system and
//| the signal itself has to be rebuilt.
//|
//| Runs as a script on any chart - no Strategy Tester involved.
//+------------------------------------------------------------------+
#property copyright "DTF"
#property version   "1.00"
#property script_show_inputs
#property description "Exports per-bar signal and forward returns for analysis."

#include <DTF/ResearchExport.mqh>

input string InpSymbols = "EURJPY,AUDJPY,EURGBP,AUDNZD,AUDCAD,AUDCHF,GBPCHF"; // Pairs (no suffix)
input string InpSuffix  = "m";                    // Broker suffix
input string InpPrefix  = "";                     // Broker prefix
input string InpOutFile = "DTF_research.csv";     // Output file (Common Files)

//+------------------------------------------------------------------+
void OnStart()
  {
   Print("=== DTF signal research export ===");

   SDtfResearchCfg cfg;
   DtfResearchDefaults(cfg);        // must mirror the EA

   DtfExportResearch(InpSymbols,InpPrefix,InpSuffix,InpOutFile,cfg);
  }
//+------------------------------------------------------------------+
