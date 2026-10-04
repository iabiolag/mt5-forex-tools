//+------------------------------------------------------------------+
//|                                                        DTF_EA.mq5 |
//|      Daily Trend-Following System - phase 2, single-pair EA       |
//+------------------------------------------------------------------+
//| WHAT THIS DOES
//| --------------
//| Trades ONE pair on the daily timeframe using the same modules the
//| phase-1 dashboard draws from, so the chart and the EA can never
//| disagree about what the signal is.
//|
//| Once per new daily bar, on the bar that just CLOSED:
//|
//|   1. Manage the open position first (trail, signal exit, time stop).
//|      Protecting an open trade outranks finding a new one.
//|   2. If flat and |signal| >= threshold, size from the ATR stop and
//|      enter. If anything blocks the entry, write down why.
//|
//| Decisions are made only on closed bars. Nothing reads the forming
//| bar, so a backtest and live trading see identical inputs.
//|
//| Phase 2 scope: signal + ATR stop + trail + sizing + journal.
//| Currency exposure caps, the news filter and circuit breakers are
//| phases 3 and 4 and are deliberately absent here.
//+------------------------------------------------------------------+
#property copyright "DTF"
#property version   "1.00"
#property description "Daily trend-following EA, single pair. Phase 2."

#include <DTF/Common.mqh>
#include <DTF/SignalEngine.mqh>
#include <DTF/VolatilityRegime.mqh>
#include <DTF/RiskManager.mqh>
#include <DTF/TradeManager.mqh>
#include <DTF/Journal.mqh>

//--- Trend ensemble -----------------------------------------------
input group           "=== Trend ensemble ==="
input int                  InpFastPeriod      = 20;              // Fast lookback (bars)
input int                  InpMidPeriod       = 60;              // Medium lookback (bars)
input int                  InpSlowPeriod      = 120;             // Slow lookback (bars)
input ENUM_DTF_SIGNAL_MODE InpSignalMode      = DTF_SIGNAL_BOTH; // How each lookback measures trend
input double               InpEmaAtrNorm      = 2.0;             // ATRs from EMA that count as full +-1
input double               InpSignalThreshold = 0.5;             // |signal| needed to enter

//--- Volatility regime --------------------------------------------
input group           "=== Volatility regime ==="
input int                  InpAtrPeriod       = 20;              // ATR period (also the stop basis)
input int                  InpBbPeriod        = 20;              // Bollinger period
input double               InpBbDeviation     = 2.0;             // Bollinger deviations
input int                  InpPercentileBars  = 250;             // Percentile lookback (bars)
input double               InpCompressionPct  = 20.0;            // BB width pct below this = compression
input double               InpExpansionPct    = 80.0;            // BB width pct above this = expansion
input double               InpExtremeVolPct   = 90.0;            // ATR pct above this = extreme regime
input double               InpExtremeVolScale = 0.5;             // Risk multiplier in extreme regime

//--- Risk ---------------------------------------------------------
input group           "=== Risk ==="
input double               InpRiskPercent     = 0.75;            // Risk per trade (% of equity)
input double               InpAtrStopMult     = 3.0;             // Initial stop = N x ATR
input double               InpMaxMarginPct    = 30.0;            // Max free margin one trade may use (%)
input bool                 InpCheckMargin     = true;            // Run the margin check

//--- Exits --------------------------------------------------------
input group           "=== Exits ==="
input bool                 InpUseTrailingStop = true;            // Chandelier trailing stop
input double               InpTrailAtrMult    = 3.0;             // Trail = N x ATR from extreme since entry
input double               InpTrailStartR     = 0.0;             // Start trailing only after +N R (0 = immediately)
input bool                 InpExitOnReversal  = true;            // Exit when the ensemble flips
input double               InpExitSignalLevel = 0.0;             // Exit long below this / short above -this
input bool                 InpUseTimeStop     = false;           // Time stop (off until proven)
input int                  InpTimeStopBars    = 20;              // Exit after N bars if never reached +1R

//--- Execution ----------------------------------------------------
input group           "=== Execution ==="
input ulong                InpMagic           = 770120;          // Magic number (unique per EA instance)
input ulong                InpDeviation       = 20;              // Max slippage (points)
input int                  InpOrderRetries    = 3;               // Retries on requote/price-changed
input bool                 InpSkipSundayBar   = true;            // Ignore broker Sunday stub bars

//--- Journal ------------------------------------------------------
input group           "=== Journal ==="
input bool                 InpJournalEnabled  = true;            // Write the CSV journal
input bool                 InpJournalCommon   = true;            // Use Common Files folder
input bool                 InpJournalEcho     = false;           // Also print every row to the log
input string               InpJournalSuffix   = "";              // Filename suffix (e.g. a run label)
input bool                 InpJournalFresh    = true;            // Start empty on each tester run

//--- modules ------------------------------------------------------
CSignalEngine     g_signal;
CVolatilityRegime g_vol;
CRiskManager      g_risk;
CTradeManager     g_trade;
CJournal          g_journal;

datetime          g_last_bar = 0;
int               g_min_bars = 0;
bool              g_ready    = false;

//--- A decision is LATCHED on the new bar and EXECUTED once the market
//--- is actually open. A new daily bar appears at the broker rollover,
//--- which is precisely when trading is shut, so acting immediately
//--- gets every order rejected with 10018 (market closed).
bool              g_pending      = false;
datetime          g_pending_bar  = 0;
double            g_pending_sig  = 0.0;
SDtfVolState      g_pending_vs;

//--- Last closed bar whose decision was carried out, kept in a terminal
//--- global variable so it survives a restart. Without it, a terminal
//--- opened in the morning (after the rollover) never sees a "new bar"
//--- that day and the open trade goes unmanaged until tomorrow.
string            g_done_gv = "";

//+------------------------------------------------------------------+
int OnInit()
  {
   if(Period()!=PERIOD_D1)
     {
      Print("DTF_EA: this system is daily-only. Attach it to a D1 chart.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpSignalThreshold<=0.0 || InpSignalThreshold>=1.0)
     {
      Print("DTF_EA: signal threshold must be strictly between 0 and 1");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpAtrStopMult<=0.0 || InpTrailAtrMult<=0.0)
     {
      Print("DTF_EA: ATR multiples must be > 0");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(!g_signal.Init(_Symbol,PERIOD_D1,InpFastPeriod,InpMidPeriod,InpSlowPeriod,
                     InpSignalMode,InpAtrPeriod,InpEmaAtrNorm))
      return(INIT_FAILED);

   if(!g_vol.Init(_Symbol,PERIOD_D1,InpAtrPeriod,InpBbPeriod,InpBbDeviation,
                  InpPercentileBars,InpCompressionPct,InpExpansionPct,
                  InpExtremeVolPct,InpExtremeVolScale))
      return(INIT_FAILED);

   if(!g_risk.Init(InpRiskPercent,InpMaxMarginPct,InpCheckMargin))
      return(INIT_PARAMETERS_INCORRECT);

   //--- Default the filename to the symbol so per-pair runs land in
   //--- separate files instead of each one wiping the last.
   string jsuffix=(StringLen(InpJournalSuffix)>0 ? InpJournalSuffix : _Symbol);
   g_journal.Init(jsuffix,InpJournalCommon,InpJournalEnabled,InpJournalEcho,
                  InpJournalFresh && (bool)MQLInfoInteger(MQL_TESTER));

   string state_tag=_Symbol+"_"+IntegerToString((long)InpMagic);
   g_trade.Init(_Symbol,InpMagic,InpDeviation,InpOrderRetries,
                GetPointer(g_journal),state_tag);

   g_min_bars=MathMax(g_signal.MinBars(),g_vol.MinBars());

   //--- Remember the current bar so we do not fire a decision on the
   //--- half-formed bar that happens to be open at attach time.
   datetime t[];
   if(CopyTime(_Symbol,PERIOD_D1,0,1,t)==1)
      g_last_bar=t[0];

   //--- Catch up after a restart: if the last closed bar's decision was
   //--- never carried out, latch it on the first tick. Only when we know
   //--- the EA ran here before (the global exists) or a position needs
   //--- managing - a first attach still waits for the next bar, as before.
   //--- The tester always starts clean, so it keeps the old behaviour.
   g_done_gv="DTF_done_"+_Symbol+"_"+IntegerToString((long)InpMagic);
   if(!MQLInfoInteger(MQL_TESTER))
     {
      datetime closed[];
      if(CopyTime(_Symbol,PERIOD_D1,1,1,closed)==1)
        {
         bool ran_before=GlobalVariableCheck(g_done_gv);
         datetime done=(ran_before ? (datetime)GlobalVariableGet(g_done_gv) : 0);
         if((ran_before || g_trade.HasPosition()) && done<closed[0])
           {
            g_last_bar=0;   // first tick sees a "new bar" and latches it
            PrintFormat("DTF_EA: catching up on the %s decision for %s",
                        TimeToString(closed[0],TIME_DATE),_Symbol);
           }
        }
     }

   g_ready=true;
   PrintFormat("DTF_EA ready on %s. Warm-up needs %d D1 bars. Magic %I64u.",
               _Symbol,g_min_bars,InpMagic);

   //--- Print the settings this run ACTUALLY used. Comparing two
   //--- backtests is worthless if we cannot prove what changed between
   //--- them, and a tester input that silently fails to apply looks
   //--- exactly like a strategy that did not respond to the change.
   PrintFormat("DTF_EA CONFIG | signal %d/%d/%d mode=%d k=%.2f thr=%.2f",
               InpFastPeriod,InpMidPeriod,InpSlowPeriod,
               (int)InpSignalMode,InpEmaAtrNorm,InpSignalThreshold);
   PrintFormat("DTF_EA CONFIG | ATR=%d stop=%.2fxATR trail=%s %.2fxATR from +%.2fR risk=%.2f%%",
               InpAtrPeriod,InpAtrStopMult,
               (InpUseTrailingStop ? "ON" : "OFF"),InpTrailAtrMult,
               InpTrailStartR,InpRiskPercent);
   PrintFormat("DTF_EA CONFIG | exitReversal=%s lvl=%.2f timeStop=%s/%d sundaySkip=%s",
               (InpExitOnReversal ? "ON" : "OFF"),InpExitSignalLevel,
               (InpUseTimeStop ? "ON" : "OFF"),InpTimeStopBars,
               (InpSkipSundayBar ? "ON" : "OFF"));

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_signal.Release();
   g_vol.Release();
  }
//+------------------------------------------------------------------+
//| Is the bar that just closed a broker Sunday stub?                 |
//| Some brokers emit a 1-3 hour Sunday candle. Its range and close   |
//| are not comparable to a real session, so acting on it means       |
//| trading noise. We let it pass and decide on Monday instead.       |
//+------------------------------------------------------------------+
bool IsSundayStub(const datetime bar_time)
  {
   MqlDateTime dt;
   TimeToStruct(bar_time,dt);
   return(dt.day_of_week==0);
  }
//+------------------------------------------------------------------+
//| Can we actually trade this symbol right now?                      |
//| A new D1 bar is born at the rollover, when the session is closed.  |
//| Checking first turns a stream of rejected orders into a short wait.|
//+------------------------------------------------------------------+
bool MarketOpen(const string sym)
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))   return(false);
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))             return(false);
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))     return(false);
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))      return(false);

   if((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(sym,SYMBOL_TRADE_MODE)
      !=SYMBOL_TRADE_MODE_FULL)
      return(false);

   //--- inside one of today's trading sessions?
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   int now_sec=dt.hour*3600+dt.min*60+dt.sec;
   datetime from=0,to=0;
   for(int i=0;i<8;i++)
     {
      if(!SymbolInfoSessionTrade(sym,(ENUM_DAY_OF_WEEK)dt.day_of_week,i,from,to))
         break;
      if(now_sec>=(int)from && now_sec<=(int)to)
         return(true);
     }
   return(false);
  }
//+------------------------------------------------------------------+
//| Work out what this bar wants, and remember it.                    |
//+------------------------------------------------------------------+
void LatchDecision(void)
  {
   if(Bars(_Symbol,PERIOD_D1)<g_min_bars+2)
      return;

   datetime closed_bar_time=0;
   datetime tt[];
   if(CopyTime(_Symbol,PERIOD_D1,1,1,tt)==1)
      closed_bar_time=tt[0];

   double sig=0.0,cf=0.0,cm=0.0,cs=0.0;
   if(!g_signal.Latest(1,sig,cf,cm,cs))
      return;

   SDtfVolState vs;
   if(!g_vol.State(1,vs))
      return;

   //--- Bookkeeping first: a stop hit overnight must be journalled with
   //--- the right reason before we think about a new trade.
   g_trade.DetectClose(sig);

   if(InpSkipSundayBar && IsSundayStub(closed_bar_time))
     {
      g_pending=false;
      return;
     }

   g_pending     = true;
   g_pending_bar = closed_bar_time;
   g_pending_sig = sig;
   g_pending_vs  = vs;
  }
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_ready)
      return;

   //--- Keep the running R high-water mark current between bars; it
   //--- feeds the time stop and the journal's MFE column.
   if(g_trade.HasPosition())
      g_trade.UpdateExcursion(0.0);

   //--- new daily bar? latch the decision (does not trade)
   datetime t[];
   if(CopyTime(_Symbol,PERIOD_D1,0,1,t)==1 && t[0]!=g_last_bar)
     {
      g_last_bar=t[0];
      LatchDecision();
     }

   //--- act as soon as the market reopens
   if(!g_pending || !MarketOpen(_Symbol))
      return;

   g_pending=false;
   if(g_trade.HasPosition())
      ManageOpenPosition(g_pending_sig,g_pending_vs,g_pending_bar);
   else
      ConsiderEntry(g_pending_sig,g_pending_vs,g_pending_bar);
   GlobalVariableSet(g_done_gv,(double)g_pending_bar);
  }
//+------------------------------------------------------------------+
//| Manage an open trade. Order matters: the cheapest exit first.     |
//+------------------------------------------------------------------+
void ManageOpenPosition(const double sig,const SDtfVolState &vs,
                        const datetime bar_time)
  {
   g_trade.OnBarHeld();
   SDtfPosState p=g_trade.State();

   //--- 1. Signal exit. The ensemble that justified the trade no
   //---    longer does. Usually a better price than waiting for the
   //---    trail to be taken out.
   if(InpExitOnReversal)
     {
      bool flip=(p.direction>0 ? sig<=InpExitSignalLevel
                               : sig>=-InpExitSignalLevel);
      if(flip)
        {
         PrintFormat("DTF: signal exit on %s, signal %+.2f",_Symbol,sig);
         g_trade.Close(DTF_EXIT_SIGNAL);
         g_trade.DetectClose(sig);
         return;
        }
     }

   //--- 2. Time stop. Never reached +1R in N bars - the trade is not
   //---    working and the risk budget has better uses.
   if(InpUseTimeStop && p.bars_held>=InpTimeStopBars && p.mfe_r<1.0)
     {
      PrintFormat("DTF: time stop on %s after %d bars, best %.2fR",
                  _Symbol,p.bars_held,p.mfe_r);
      g_trade.Close(DTF_EXIT_TIME);
      g_trade.DetectClose(sig);
      return;
     }

   //--- 3. Trail. Chandelier from the extreme since entry. MoveStop
   //---    silently refuses anything that is not an improvement.
   //---
   //---    Optionally the trail stays DORMANT until the trade has shown
   //---    it is working (MFE >= InpTrailStartR), leaving the initial
   //---    ATR stop in charge before that. The reason: a trail tight
   //---    enough to protect profit is also tight enough to cut a trade
   //---    that has not begun to move, and uniformly tightening it just
   //---    chops the same trend into more pieces, each paying spread
   //---    and carry again. Waiting separates the two jobs - the stop
   //---    caps the loss, the trail protects a gain that exists.
   if(InpUseTrailingStop && vs.atr>0.0 &&
      (InpTrailStartR<=0.0 || p.mfe_r>=InpTrailStartR))
     {
      int bars_since=p.bars_held+1;
      double trail=g_trade.ChandelierStop(p.direction,bars_since,vs.atr,InpTrailAtrMult);
      if(trail>0.0)
         g_trade.MoveStop(trail);
     }
  }
//+------------------------------------------------------------------+
//| Decide whether to open, and record the reason when we do not.     |
//+------------------------------------------------------------------+
void ConsiderEntry(const double sig,const SDtfVolState &vs,const datetime bar_time)
  {
   if(MathAbs(sig)<InpSignalThreshold)
      return;   // not a signal at all; not worth a journal row

   int direction=(sig>0.0 ? 1 : -1);

   if(vs.atr<=0.0)
     {
      g_journal.LogSkip(_Symbol,bar_time,sig,vs.atr_pct,vs.bb_pct,vs.regime,
                        "ATR unavailable");
      return;
     }

   //--- Stop first. Size is whatever makes that stop cost the planned
   //--- fraction of equity - risk is the constant, size is derived.
   double stop_dist=g_risk.StopDistance(vs.atr,InpAtrStopMult);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);

   SDtfSizing sz;
   if(!g_risk.CalcLots(_Symbol,stop_dist,equity,vs.size_scale,sz))
     {
      g_journal.LogSkip(_Symbol,bar_time,sig,vs.atr_pct,vs.bb_pct,vs.regime,
                        "sizing rejected: "+sz.note);
      return;
     }

   double price=(direction>0 ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol,SYMBOL_BID));
   if(price<=0.0)
     {
      g_journal.LogSkip(_Symbol,bar_time,sig,vs.atr_pct,vs.bb_pct,vs.regime,
                        "no price available");
      return;
     }

   double stop_price=g_trade.StopPriceFor(direction,price,stop_dist);

   if(!g_trade.Open(direction,sz.lots,stop_price,sig,vs.atr,vs.atr_pct,vs.bb_pct,
                    vs.regime,vs.compression,equity,bar_time))
      g_journal.LogSkip(_Symbol,bar_time,sig,vs.atr_pct,vs.bb_pct,vs.regime,
                        "order rejected by broker");
  }
//+------------------------------------------------------------------+
