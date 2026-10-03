//+------------------------------------------------------------------+
//|                                              VolatilityRegime.mqh |
//|        Daily Trend-Following System - volatility context per pair |
//+------------------------------------------------------------------+
//| TRADING LOGIC
//| ------------
//| A fixed 0.75% risk is not a fixed bet. When ATR sits at its 95th
//| percentile, the same 3xATR stop is far wider, the position is far
//| smaller, and the pair is far more likely to gap through the stop
//| overnight. And a breakout out of a volatility squeeze behaves
//| nothing like a breakout in the middle of an already-expanded
//| range. So every decision needs volatility *context*, not just a
//| volatility number.
//|
//| Two measures, both ranked against the pair's OWN recent history
//| (default 250 daily bars, about a trading year) so that a "high"
//| reading means high for this pair, not high compared with some
//| absolute threshold that suits EURUSD and ruins GBPJPY:
//|
//|  1) ATR(20) percentile - the size of a typical daily range now
//|     versus the last year. Drives position sizing and the
//|     extreme-volatility cutback.
//|
//|  2) Bollinger band width percentile, where width = (upper-lower)
//|     / middle. Low percentile = COMPRESSION: the pair has coiled,
//|     and moves out of compression are the ones trend-followers most
//|     want to be in. High percentile = EXPANSION: the move is
//|     already underway and late entries pay for it.
//|
//| Percentiles rank the current bar against the bars BEFORE it, never
//| including itself and never including the future, so the value the
//| indicator draws on a historical bar is exactly the value the EA
//| would have seen live on that bar.
//+------------------------------------------------------------------+
#ifndef DTF_VOLATILITYREGIME_MQH
#define DTF_VOLATILITYREGIME_MQH

#include <DTF/Common.mqh>

//+------------------------------------------------------------------+
//| Everything the rest of the system needs to know about volatility  |
//| on one bar.                                                       |
//+------------------------------------------------------------------+
struct SDtfVolState
  {
   double            atr;          // ATR in price terms
   double            atr_pct;      // 0..100 percentile rank, -1 if unknown
   double            bb_width;     // (upper-lower)/middle
   double            bb_pct;       // 0..100 percentile rank, -1 if unknown
   bool              compression;  // bb_pct below the compression threshold
   bool              expansion;    // bb_pct above the expansion threshold
   ENUM_DTF_REGIME   regime;       // bucketed atr_pct
   double            size_scale;   // risk multiplier suggested by the regime
  };

//+------------------------------------------------------------------+
//| CVolatilityRegime                                                |
//| One instance per symbol. Output arrays are plain (non-series),    |
//| index 0 = current bar, matching CSignalEngine.                   |
//+------------------------------------------------------------------+
class CVolatilityRegime
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_atr_period;
   int               m_bb_period;
   double            m_bb_dev;
   int               m_lookback;        // percentile window (default 250)
   double            m_compress_pct;    // below this = compression
   double            m_expand_pct;      // above this = expansion
   double            m_extreme_pct;     // above this = extreme regime
   double            m_extreme_scale;   // risk multiplier in extreme vol
   int               m_h_atr;
   int               m_h_bb;
   bool              m_ready;

public:
                     CVolatilityRegime(void);
                    ~CVolatilityRegime(void);

   bool              Init(const string symbol,const ENUM_TIMEFRAMES tf,
                          const int atr_period,const int bb_period,const double bb_dev,
                          const int lookback,
                          const double compress_pct,const double expand_pct,
                          const double extreme_pct,const double extreme_scale);
   void              Release(void);
   bool              IsReady(void) const { return(m_ready); }
   int               MinBars(void) const;

   //--- fills the four series; returns bars written, 0 on failure
   int               Calculate(const int count,double &atr[],double &atr_pct[],
                               double &bb_width[],double &bb_pct[]);
   //--- one-bar read, packaged with the derived flags
   bool              State(const int shift,SDtfVolState &out);
   //--- build the derived flags from raw values (shared by both paths)
   void              Classify(const double atr_value,const double atr_percentile,
                              const double width,const double width_percentile,
                              SDtfVolState &out) const;
  };

//+------------------------------------------------------------------+
CVolatilityRegime::CVolatilityRegime(void) : m_symbol(""),
                                             m_tf(PERIOD_D1),
                                             m_atr_period(20),
                                             m_bb_period(20),
                                             m_bb_dev(2.0),
                                             m_lookback(250),
                                             m_compress_pct(20.0),
                                             m_expand_pct(80.0),
                                             m_extreme_pct(90.0),
                                             m_extreme_scale(0.5),
                                             m_h_atr(INVALID_HANDLE),
                                             m_h_bb(INVALID_HANDLE),
                                             m_ready(false)
  {
  }
//+------------------------------------------------------------------+
CVolatilityRegime::~CVolatilityRegime(void)
  {
   Release();
  }
//+------------------------------------------------------------------+
void CVolatilityRegime::Release(void)
  {
   if(m_h_atr!=INVALID_HANDLE)
     {
      IndicatorRelease(m_h_atr);
      m_h_atr=INVALID_HANDLE;
     }
   if(m_h_bb!=INVALID_HANDLE)
     {
      IndicatorRelease(m_h_bb);
      m_h_bb=INVALID_HANDLE;
     }
   m_ready=false;
  }
//+------------------------------------------------------------------+
bool CVolatilityRegime::Init(const string symbol,const ENUM_TIMEFRAMES tf,
                             const int atr_period,const int bb_period,const double bb_dev,
                             const int lookback,
                             const double compress_pct,const double expand_pct,
                             const double extreme_pct,const double extreme_scale)
  {
   Release();

   if(atr_period<2 || bb_period<2)
     {
      Print("DTF/VolatilityRegime: ATR and Bollinger periods must be >= 2");
      return(false);
     }
   if(lookback<20)
     {
      Print("DTF/VolatilityRegime: percentile lookback must be >= 20 to mean anything");
      return(false);
     }
   if(bb_dev<=0.0 || extreme_scale<=0.0)
     {
      Print("DTF/VolatilityRegime: deviation and size scale must be > 0");
      return(false);
     }

   m_symbol        = symbol;
   m_tf            = tf;
   m_atr_period    = atr_period;
   m_bb_period     = bb_period;
   m_bb_dev        = bb_dev;
   m_lookback      = lookback;
   m_compress_pct  = compress_pct;
   m_expand_pct    = expand_pct;
   m_extreme_pct   = extreme_pct;
   m_extreme_scale = extreme_scale;

   m_h_atr=iATR(m_symbol,m_tf,m_atr_period);
   if(m_h_atr==INVALID_HANDLE)
     {
      PrintFormat("DTF/VolatilityRegime: iATR(%d) failed on %s",m_atr_period,m_symbol);
      Release();
      return(false);
     }

   m_h_bb=iBands(m_symbol,m_tf,m_bb_period,0,m_bb_dev,PRICE_CLOSE);
   if(m_h_bb==INVALID_HANDLE)
     {
      PrintFormat("DTF/VolatilityRegime: iBands(%d) failed on %s",m_bb_period,m_symbol);
      Release();
      return(false);
     }

   m_ready=true;
   return(true);
  }
//+------------------------------------------------------------------+
int CVolatilityRegime::MinBars(void) const
  {
   return(m_lookback+MathMax(m_atr_period,m_bb_period)+2);
  }
//+------------------------------------------------------------------+
//| Derive flags, regime and size scale from raw readings.            |
//+------------------------------------------------------------------+
void CVolatilityRegime::Classify(const double atr_value,const double atr_percentile,
                                 const double width,const double width_percentile,
                                 SDtfVolState &out) const
  {
   out.atr        = atr_value;
   out.atr_pct    = atr_percentile;
   out.bb_width   = width;
   out.bb_pct     = width_percentile;
   out.compression= (width_percentile>=0.0 && width_percentile<m_compress_pct);
   out.expansion  = (width_percentile>=0.0 && width_percentile>m_expand_pct);
   out.regime     = DTF_RegimeFromPercentile(atr_percentile,m_extreme_pct);
   //--- Extreme volatility gets a smaller bet, not a wider stop: the
   //--- stop is already ATR-based, so the cutback is about not paying
   //--- full size for a wildly uncertain entry.
   out.size_scale = (out.regime==DTF_REGIME_EXTREME ? m_extreme_scale : 1.0);
  }
//+------------------------------------------------------------------+
//| ATR and BB-width with their percentile ranks.                     |
//+------------------------------------------------------------------+
int CVolatilityRegime::Calculate(const int count,double &atr[],double &atr_pct[],
                                 double &bb_width[],double &bb_pct[])
  {
   if(!m_ready || count<=0)
      return(0);

   //--- need 'count' bars plus a full percentile window behind the
   //--- oldest of them, plus indicator warm-up.
   int need=count+m_lookback+MathMax(m_atr_period,m_bb_period)+1;

   double atr_raw[],mid[],up[],dn[];
   ArraySetAsSeries(atr_raw,true);
   ArraySetAsSeries(mid,true);
   ArraySetAsSeries(up,true);
   ArraySetAsSeries(dn,true);

   //--- iBands buffers: 0 = base line, 1 = upper band, 2 = lower band
   if(CopyBuffer(m_h_atr,0,0,need,atr_raw)<need) return(0);
   if(CopyBuffer(m_h_bb,0,0,need,mid)<need)      return(0);
   if(CopyBuffer(m_h_bb,1,0,need,up)<need)       return(0);
   if(CopyBuffer(m_h_bb,2,0,need,dn)<need)       return(0);

   //--- BB width as a full series first, because its percentile needs
   //--- the widths of the preceding bars, not the bands.
   double width[];
   if(ArrayResize(width,need)!=need)
      return(0);
   ArraySetAsSeries(width,true);
   for(int i=0;i<need;i++)
      width[i]=(mid[i]>0.0 ? (up[i]-dn[i])/mid[i] : 0.0);

   if(ArrayResize(atr,count)!=count)      return(0);
   if(ArrayResize(atr_pct,count)!=count)  return(0);
   if(ArrayResize(bb_width,count)!=count) return(0);
   if(ArrayResize(bb_pct,count)!=count)   return(0);
   ArraySetAsSeries(atr,false);
   ArraySetAsSeries(atr_pct,false);
   ArraySetAsSeries(bb_width,false);
   ArraySetAsSeries(bb_pct,false);

   for(int i=0;i<count;i++)
     {
      atr[i]      = atr_raw[i];
      bb_width[i] = width[i];
      //--- rank against bars i+1 .. i+lookback: strictly the past
      atr_pct[i]  = DTF_PercentRank(atr_raw,i+1,m_lookback,atr_raw[i]);
      bb_pct[i]   = DTF_PercentRank(width,i+1,m_lookback,width[i]);
     }

   return(count);
  }
//+------------------------------------------------------------------+
//| One-bar read. shift 1 = last closed bar.                          |
//+------------------------------------------------------------------+
bool CVolatilityRegime::State(const int shift,SDtfVolState &out)
  {
   Classify(0.0,-1.0,0.0,-1.0,out);
   if(shift<0)
      return(false);

   double a[],ap[],w[],wp[];
   int n=Calculate(shift+1,a,ap,w,wp);
   if(n<=shift)
      return(false);

   Classify(a[shift],ap[shift],w[shift],wp[shift],out);
   return(true);
  }

#endif // DTF_VOLATILITYREGIME_MQH
//+------------------------------------------------------------------+
