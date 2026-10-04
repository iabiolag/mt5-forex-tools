//+------------------------------------------------------------------+
//|                                                       Common.mqh |
//|              Daily Trend-Following System - shared primitives    |
//+------------------------------------------------------------------+
//| Small, dependency-free helpers shared by every DTF module.       |
//| Nothing in here knows about orders, charts or indicators, so it   |
//| can be included from an indicator, an EA or a script alike.      |
//+------------------------------------------------------------------+
#ifndef DTF_COMMON_MQH
#define DTF_COMMON_MQH

#define DTF_VERSION "0.1 (phase 1)"

//+------------------------------------------------------------------+
//| How each lookback of the trend ensemble measures trend.          |
//|  EMA     : distance of price from its EMA, scaled by volatility  |
//|  CHANNEL : position inside the Donchian range (breakout bias)    |
//|  BOTH    : average of the two (default - they fail differently)  |
//+------------------------------------------------------------------+
enum ENUM_DTF_SIGNAL_MODE
  {
   DTF_SIGNAL_EMA     = 0,  // EMA distance only
   DTF_SIGNAL_CHANNEL = 1,  // Channel position only
   DTF_SIGNAL_BOTH    = 2   // Both, averaged
  };

//+------------------------------------------------------------------+
//| Volatility regime buckets, derived from the ATR percentile.      |
//| Used to scale risk down when the market is unusually wild - a    |
//| fixed % risk in a 95th-percentile ATR is a much bigger bet in    |
//| practice than the same % in a quiet market.                      |
//+------------------------------------------------------------------+
enum ENUM_DTF_REGIME
  {
   DTF_REGIME_LOW     = 0,  // quiet
   DTF_REGIME_NORMAL  = 1,  // ordinary
   DTF_REGIME_HIGH    = 2,  // busy
   DTF_REGIME_EXTREME = 3   // scale entries down / stand aside
  };

//+------------------------------------------------------------------+
//| Why a position was closed. Recorded on every journal row, because |
//| "which exit is paying for itself?" is the question that decides   |
//| whether the trailing stop and the time stop survive to phase 5.   |
//+------------------------------------------------------------------+
enum ENUM_DTF_EXIT_REASON
  {
   DTF_EXIT_NONE     = 0,  // still open
   DTF_EXIT_STOP     = 1,  // initial stop hit
   DTF_EXIT_TRAIL    = 2,  // chandelier trailing stop hit
   DTF_EXIT_SIGNAL   = 3,  // trend ensemble reversed
   DTF_EXIT_TIME     = 4,  // time stop: no progress after N bars
   DTF_EXIT_MANUAL   = 5,  // closed outside the EA
   DTF_EXIT_OTHER    = 6   // anything else the broker did
  };

string DTF_ExitReasonToString(const ENUM_DTF_EXIT_REASON r)
  {
   switch(r)
     {
      case DTF_EXIT_NONE:   return("OPEN");
      case DTF_EXIT_STOP:   return("STOP");
      case DTF_EXIT_TRAIL:  return("TRAIL");
      case DTF_EXIT_SIGNAL: return("SIGNAL");
      case DTF_EXIT_TIME:   return("TIME");
      case DTF_EXIT_MANUAL: return("MANUAL");
     }
   return("OTHER");
  }

//+------------------------------------------------------------------+
//| Clamp v into [lo,hi].                                            |
//+------------------------------------------------------------------+
double DTF_Clamp(const double v,const double lo,const double hi)
  {
   if(v<lo) return(lo);
   if(v>hi) return(hi);
   return(v);
  }

//+------------------------------------------------------------------+
//| Percentile rank of 'value' inside data[first .. first+window-1].  |
//| Returns 0..100, or -1.0 when the window is not fully available.   |
//|                                                                   |
//| Callers pass a SERIES-ordered array (index 0 = newest bar) and    |
//| 'first' = the bar AFTER the one being ranked, so the current bar  |
//| is never ranked against itself or against the future.             |
//+------------------------------------------------------------------+
double DTF_PercentRank(const double &data[],const int first,const int window,const double value)
  {
   if(window<=0 || first<0) return(-1.0);
   if(first+window>ArraySize(data)) return(-1.0);

   int less=0,valid=0;
   for(int i=first;i<first+window;i++)
     {
      double d=data[i];
      if(d==EMPTY_VALUE || !MathIsValidNumber(d)) continue;
      valid++;
      if(d<value) less++;
     }
   if(valid<=0) return(-1.0);
   return(100.0*(double)less/(double)valid);
  }

//+------------------------------------------------------------------+
//| Bucket an ATR percentile into a regime.                          |
//+------------------------------------------------------------------+
ENUM_DTF_REGIME DTF_RegimeFromPercentile(const double atr_pct,const double extreme_pct)
  {
   if(atr_pct<0.0)          return(DTF_REGIME_NORMAL);   // not enough history yet
   if(atr_pct>=extreme_pct) return(DTF_REGIME_EXTREME);
   if(atr_pct>=70.0)        return(DTF_REGIME_HIGH);
   if(atr_pct<=30.0)        return(DTF_REGIME_LOW);
   return(DTF_REGIME_NORMAL);
  }

string DTF_RegimeToString(const ENUM_DTF_REGIME r)
  {
   switch(r)
     {
      case DTF_REGIME_LOW:     return("LOW");
      case DTF_REGIME_NORMAL:  return("NORMAL");
      case DTF_REGIME_HIGH:    return("HIGH");
      case DTF_REGIME_EXTREME: return("EXTREME");
     }
   return("?");
  }

//+------------------------------------------------------------------+
//| One pip in price terms. 5- and 3-digit quotes price in tenths of |
//| a pip, so a pip is 10 points there and 1 point everywhere else.  |
//| Metals are the exception: gold quotes 3 digits but a gold pip is  |
//| $0.10, silver's $0.01 - the same convention as the Python tools   |
//| (daily_range.py PIP_OVERRIDE), so both show the same pip counts.  |
//+------------------------------------------------------------------+
double DTF_PipSize(const string symbol)
  {
   string s=symbol;
   StringToUpper(s);
   if(StringFind(s,"XAU")==0) return(0.1);
   if(StringFind(s,"XAG")==0) return(0.01);

   int    digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   double point =SymbolInfoDouble(symbol,SYMBOL_POINT);
   if(point<=0.0) return(0.0);
   if(digits==3 || digits==5) return(point*10.0);
   return(point);
  }

//+------------------------------------------------------------------+
//| Convert a price distance into pips (0 if the symbol is unknown). |
//+------------------------------------------------------------------+
double DTF_PriceToPips(const string symbol,const double price_distance)
  {
   double pip=DTF_PipSize(symbol);
   if(pip<=0.0) return(0.0);
   return(price_distance/pip);
  }

//+------------------------------------------------------------------+
//| Apply the broker's prefix/suffix to a plain pair name and make    |
//| sure the symbol is in Market Watch. Empty string = unavailable.   |
//| (Used from phase 3 onward for the multi-symbol basket; defined    |
//|  here so the naming rule lives in exactly one place.)             |
//+------------------------------------------------------------------+
string DTF_ResolveSymbol(const string base,const string prefix,const string suffix)
  {
   string name=prefix+base+suffix;
   if(!SymbolSelect(name,true)) return("");
   return(name);
  }

#endif // DTF_COMMON_MQH
//+------------------------------------------------------------------+
