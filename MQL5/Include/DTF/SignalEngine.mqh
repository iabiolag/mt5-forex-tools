//+------------------------------------------------------------------+
//|                                                 SignalEngine.mqh |
//|          Daily Trend-Following System - trend ensemble (-1..+1)   |
//+------------------------------------------------------------------+
//| TRADING LOGIC
//| ------------
//| One trend measure at one lookback is close to a coin-flip on any
//| given pair: it is either too fast (chopped up inside ranges) or
//| too slow (gives back the move). So we measure trend at three
//| lookbacks - short (20), medium (60) and long (120 daily bars) -
//| and average them. The ensemble only reaches a large magnitude
//| when the pair trends on several horizons at once, which is the
//| condition a daily trend-follower wants. When the horizons
//| disagree the average collapses toward zero and we stand aside.
//|
//| Each lookback produces a score in [-1,+1] from up to two views:
//|
//|  1) EMA distance: clamp((close - EMA(L)) / (k * ATR * sqrt(L/A)))
//|     "How far above or below its own mean is price, measured in
//|     units of daily noise?" Dividing by ATR makes the number
//|     comparable across pairs (JPY crosses and EURCHF live on very
//|     different scales). The sqrt(L/A) term is random-walk scaling:
//|     over L bars price wanders roughly sqrt(L) further than over A
//|     bars, so without it the 120-bar component would sit pinned at
//|     +1 or -1 and stop carrying information. With it, a single k
//|     works for all three lookbacks.
//|
//|  2) Channel position: 2*(close - LL(L))/(HH(L) - LL(L)) - 1
//|     "Where inside its own L-bar range does price sit?" +1 at a new
//|     L-bar high, -1 at a new low, 0 mid-range. This is the classic
//|     breakout view: it reacts to range expansion, where the EMA
//|     view reacts to sustained displacement.
//|
//| The two fail in different places (EMA lags at turns, channel
//| whipsaws at range edges), which is the whole point of averaging
//| them. The mode is an input so a backtest can prove whether both
//| are actually pulling their weight.
//+------------------------------------------------------------------+
#ifndef DTF_SIGNALENGINE_MQH
#define DTF_SIGNALENGINE_MQH

#include <DTF/Common.mqh>

//+------------------------------------------------------------------+
//| CSignalEngine                                                    |
//| One instance per symbol. Init() once, then Calculate() for a run  |
//| of recent bars (an indicator asks for thousands, an EA for two).  |
//| All output arrays are plain (non-series) with index 0 = the       |
//| CURRENT bar, index 1 = the previous bar, and so on.               |
//+------------------------------------------------------------------+
class CSignalEngine
  {
private:
   string               m_symbol;
   ENUM_TIMEFRAMES      m_tf;
   int                  m_period[3];       // fast / mid / slow lookbacks
   ENUM_DTF_SIGNAL_MODE m_mode;
   int                  m_atr_period;      // ATR used to normalise EMA distance
   double               m_atr_norm;        // k: how many ATRs count as a full +-1
   int                  m_h_ema[3];
   int                  m_h_atr;
   bool                 m_ready;

   bool                 Component(const int slot,const int count,const int need,
                                  const double &close[],const double &high[],
                                  const double &low[],const double &atr[],
                                  double &out[]);

public:
                        CSignalEngine(void);
                       ~CSignalEngine(void);

   bool                 Init(const string symbol,const ENUM_TIMEFRAMES tf,
                             const int p_fast,const int p_mid,const int p_slow,
                             const ENUM_DTF_SIGNAL_MODE mode,
                             const int atr_period,const double atr_norm);
   void                 Release(void);
   bool                 IsReady(void) const { return(m_ready); }
   int                  MinBars(void) const;

   //--- fills sig[] and the three component arrays; returns bars written
   int                  Calculate(const int count,double &sig[],
                                  double &c_fast[],double &c_mid[],double &c_slow[]);
   //--- convenience for the EA: one bar at 'shift' (1 = last closed bar)
   bool                 Latest(const int shift,double &sig,
                               double &c_fast,double &c_mid,double &c_slow);
  };

//+------------------------------------------------------------------+
CSignalEngine::CSignalEngine(void) : m_symbol(""),
                                     m_tf(PERIOD_D1),
                                     m_mode(DTF_SIGNAL_BOTH),
                                     m_atr_period(20),
                                     m_atr_norm(2.0),
                                     m_h_atr(INVALID_HANDLE),
                                     m_ready(false)
  {
   for(int i=0;i<3;i++)
     {
      m_period[i]=0;
      m_h_ema[i]=INVALID_HANDLE;
     }
  }
//+------------------------------------------------------------------+
CSignalEngine::~CSignalEngine(void)
  {
   Release();
  }
//+------------------------------------------------------------------+
void CSignalEngine::Release(void)
  {
   for(int i=0;i<3;i++)
      if(m_h_ema[i]!=INVALID_HANDLE)
        {
         IndicatorRelease(m_h_ema[i]);
         m_h_ema[i]=INVALID_HANDLE;
        }
   if(m_h_atr!=INVALID_HANDLE)
     {
      IndicatorRelease(m_h_atr);
      m_h_atr=INVALID_HANDLE;
     }
   m_ready=false;
  }
//+------------------------------------------------------------------+
bool CSignalEngine::Init(const string symbol,const ENUM_TIMEFRAMES tf,
                         const int p_fast,const int p_mid,const int p_slow,
                         const ENUM_DTF_SIGNAL_MODE mode,
                         const int atr_period,const double atr_norm)
  {
   Release();

   if(p_fast<2 || p_mid<2 || p_slow<2 || atr_period<2)
     {
      Print("DTF/SignalEngine: lookbacks and ATR period must be >= 2");
      return(false);
     }
   if(atr_norm<=0.0)
     {
      Print("DTF/SignalEngine: ATR normaliser must be > 0");
      return(false);
     }

   m_symbol     = symbol;
   m_tf         = tf;
   m_period[0]  = p_fast;
   m_period[1]  = p_mid;
   m_period[2]  = p_slow;
   m_mode       = mode;
   m_atr_period = atr_period;
   m_atr_norm   = atr_norm;

   for(int i=0;i<3;i++)
     {
      m_h_ema[i]=iMA(m_symbol,m_tf,m_period[i],0,MODE_EMA,PRICE_CLOSE);
      if(m_h_ema[i]==INVALID_HANDLE)
        {
         PrintFormat("DTF/SignalEngine: iMA(%d) failed on %s",m_period[i],m_symbol);
         Release();
         return(false);
        }
     }

   m_h_atr=iATR(m_symbol,m_tf,m_atr_period);
   if(m_h_atr==INVALID_HANDLE)
     {
      PrintFormat("DTF/SignalEngine: iATR(%d) failed on %s",m_atr_period,m_symbol);
      Release();
      return(false);
     }

   m_ready=true;
   return(true);
  }
//+------------------------------------------------------------------+
//| Bars of history needed before the first valid value.             |
//+------------------------------------------------------------------+
int CSignalEngine::MinBars(void) const
  {
   int maxp=MathMax(m_period[0],MathMax(m_period[1],m_period[2]));
   return(maxp+m_atr_period+2);
  }
//+------------------------------------------------------------------+
//| Score for one lookback slot over the most recent 'count' bars.   |
//+------------------------------------------------------------------+
bool CSignalEngine::Component(const int slot,const int count,const int need,
                              const double &close[],const double &high[],
                              const double &low[],const double &atr[],
                              double &out[])
  {
   double ema[];
   ArraySetAsSeries(ema,true);
   if(CopyBuffer(m_h_ema[slot],0,0,need,ema)<need)
      return(false);

   if(ArrayResize(out,count)!=count)
      return(false);
   ArraySetAsSeries(out,false);

   const int    L     = m_period[slot];
   const double scale = MathSqrt((double)L/(double)m_atr_period);

   for(int i=0;i<count;i++)
     {
      double sum=0.0;
      int    parts=0;

      //--- view 1: volatility-normalised distance from the EMA
      if(m_mode==DTF_SIGNAL_EMA || m_mode==DTF_SIGNAL_BOTH)
        {
         double denom=m_atr_norm*atr[i]*scale;
         if(denom>0.0)
           {
            sum+=DTF_Clamp((close[i]-ema[i])/denom,-1.0,1.0);
            parts++;
           }
        }

      //--- view 2: position inside the L-bar Donchian channel.
      //--- high[] / low[] are series arrays, so scanning L elements
      //--- from index i walks backwards over bars i .. i+L-1.
      if(m_mode==DTF_SIGNAL_CHANNEL || m_mode==DTF_SIGNAL_BOTH)
        {
         int hi=ArrayMaximum(high,i,L);
         int lo=ArrayMinimum(low,i,L);
         if(hi>=0 && lo>=0)
           {
            double hh=high[hi];
            double ll=low[lo];
            if(hh>ll)
              {
               sum+=DTF_Clamp(2.0*(close[i]-ll)/(hh-ll)-1.0,-1.0,1.0);
               parts++;
              }
           }
        }

      out[i]=(parts>0 ? sum/(double)parts : 0.0);
     }

   return(true);
  }
//+------------------------------------------------------------------+
//| Ensemble signal for the most recent 'count' bars.                |
//| Returns bars written, or 0 on failure. History still downloading  |
//| is the usual cause of 0 - the caller should simply retry later.   |
//+------------------------------------------------------------------+
int CSignalEngine::Calculate(const int count,double &sig[],
                             double &c_fast[],double &c_mid[],double &c_slow[])
  {
   if(!m_ready || count<=0)
      return(0);

   int maxp=MathMax(m_period[0],MathMax(m_period[1],m_period[2]));
   int need=count+maxp+m_atr_period+1;   // room for the slowest lookback

   double close[],high[],low[],atr[];
   ArraySetAsSeries(close,true);
   ArraySetAsSeries(high,true);
   ArraySetAsSeries(low,true);
   ArraySetAsSeries(atr,true);

   if(CopyClose(m_symbol,m_tf,0,need,close)<need) return(0);
   if(CopyHigh(m_symbol,m_tf,0,need,high)<need)   return(0);
   if(CopyLow(m_symbol,m_tf,0,need,low)<need)     return(0);
   if(CopyBuffer(m_h_atr,0,0,need,atr)<need)      return(0);

   if(!Component(0,count,need,close,high,low,atr,c_fast)) return(0);
   if(!Component(1,count,need,close,high,low,atr,c_mid))  return(0);
   if(!Component(2,count,need,close,high,low,atr,c_slow)) return(0);

   if(ArrayResize(sig,count)!=count)
      return(0);
   ArraySetAsSeries(sig,false);

   //--- A plain unweighted average: no component is privileged, which
   //--- keeps the ensemble free of fitted weights we would then have
   //--- to defend out-of-sample.
   for(int i=0;i<count;i++)
      sig[i]=(c_fast[i]+c_mid[i]+c_slow[i])/3.0;

   return(count);
  }
//+------------------------------------------------------------------+
//| Single-bar read. shift 1 = last closed bar (what the EA trades).  |
//+------------------------------------------------------------------+
bool CSignalEngine::Latest(const int shift,double &sig,
                           double &c_fast,double &c_mid,double &c_slow)
  {
   sig=0.0; c_fast=0.0; c_mid=0.0; c_slow=0.0;
   if(shift<0)
      return(false);

   double s[],a[],b[],c[];
   int n=Calculate(shift+1,s,a,b,c);
   if(n<=shift)
      return(false);

   sig    = s[shift];
   c_fast = a[shift];
   c_mid  = b[shift];
   c_slow = c[shift];
   return(true);
  }

#endif // DTF_SIGNALENGINE_MQH
//+------------------------------------------------------------------+
