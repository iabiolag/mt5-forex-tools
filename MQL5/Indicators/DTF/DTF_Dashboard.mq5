//+------------------------------------------------------------------+
//|                                                 DTF_Dashboard.mq5 |
//|      Daily Trend-Following System - phase 1 chart indicator        |
//+------------------------------------------------------------------+
//| WHAT THIS IS FOR
//| ----------------
//| This is the eyes of the system, not the hands. It runs the exact
//| same modules the EA will run (SignalEngine, VolatilityRegime,
//| RiskManager) and shows, for the last closed daily bar:
//|
//|   * the trend-ensemble signal, -1..+1, plus its three components
//|   * the ATR percentile and the volatility regime
//|   * the Bollinger-width percentile and the compression flag
//|   * the stop distance an ATR multiple implies
//|   * the lot size that stop implies for a given risk %
//|
//| Because it shares the modules, anything that looks wrong here is
//| wrong in the EA too - which is the point of building it first.
//|
//| Read it on the DAILY timeframe. The subwindow histogram is the
//| ensemble signal; the dotted lines are the three lookbacks, so you
//| can see whether the horizons agree or are fighting each other.
//+------------------------------------------------------------------+
#property copyright "DTF"
#property version   "1.00"
#property description "Daily trend ensemble, volatility regime and suggested stop/lot size."
#property indicator_separate_window
#property indicator_buffers 6
#property indicator_plots   5

#property indicator_minimum -1.05
#property indicator_maximum  1.05

#property indicator_label1  "Signal"
#property indicator_type1   DRAW_COLOR_HISTOGRAM
#property indicator_color1  clrDimGray,clrLimeGreen,clrTomato
#property indicator_width1  3

#property indicator_label2  "Fast"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDodgerBlue
#property indicator_style2  STYLE_DOT

#property indicator_label3  "Mid"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrGoldenrod
#property indicator_style3  STYLE_DOT

#property indicator_label4  "Slow"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrMediumPurple
#property indicator_style4  STYLE_DOT

#property indicator_label5  "ATR pct/100"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrSilver
#property indicator_style5  STYLE_DASH

#include <DTF/Common.mqh>
#include <DTF/SignalEngine.mqh>
#include <DTF/VolatilityRegime.mqh>
#include <DTF/RiskManager.mqh>

//--- Signal engine ------------------------------------------------
input group           "=== Trend ensemble ==="
input int                  InpFastPeriod     = 20;             // Fast lookback (bars)
input int                  InpMidPeriod      = 60;             // Medium lookback (bars)
input int                  InpSlowPeriod     = 120;            // Slow lookback (bars)
input ENUM_DTF_SIGNAL_MODE InpSignalMode     = DTF_SIGNAL_BOTH;// How each lookback measures trend
input double               InpEmaAtrNorm     = 2.0;            // ATRs from EMA that count as full +-1
input double               InpSignalThreshold= 0.5;            // |signal| needed to call a trade

//--- Volatility regime --------------------------------------------
input group           "=== Volatility regime ==="
input int                  InpAtrPeriod      = 20;             // ATR period
input int                  InpBbPeriod       = 20;             // Bollinger period
input double               InpBbDeviation    = 2.0;            // Bollinger deviations
input int                  InpPercentileBars = 250;            // Percentile lookback (bars)
input double               InpCompressionPct = 20.0;           // BB width pct below this = compression
input double               InpExpansionPct   = 80.0;           // BB width pct above this = expansion
input double               InpExtremeVolPct  = 90.0;           // ATR pct above this = extreme regime
input double               InpExtremeVolScale= 0.5;            // Risk multiplier in extreme regime

//--- Risk / sizing ------------------------------------------------
input group           "=== Risk and stops ==="
input double               InpRiskPercent    = 0.75;           // Risk per trade (% of equity)
input double               InpAtrStopMult     = 3.0;           // Initial stop = N x ATR
input double               InpMaxMarginPct   = 30.0;           // Max free margin one trade may use (%)
input bool                 InpCheckMargin    = true;           // Run the margin check
input double               InpEquityOverride = 0.0;            // Plan with this equity (0 = live equity)

//--- Display ------------------------------------------------------
input group           "=== Display ==="
input bool                 InpUseClosedBar   = true;           // Read the last CLOSED bar (recommended)
input bool                 InpShowComponents = true;           // Plot the three component lines
input bool                 InpShowAtrPct     = false;          // Plot ATR percentile (scaled /100)
input bool                 InpShowPanel      = true;           // Draw the text panel on the chart
input ENUM_BASE_CORNER     InpPanelCorner    = CORNER_LEFT_UPPER; // Panel corner
input int                  InpPanelX         = 12;             // Panel X offset (px)
input int                  InpPanelY         = 22;             // Panel Y offset (px)
input int                  InpPanelFontSize  = 9;              // Panel font size
input color                InpPanelTextColor = clrGainsboro;   // Panel text colour

//--- buffers ------------------------------------------------------
double BufSignal[];
double BufSignalColor[];
double BufFast[];
double BufMid[];
double BufSlow[];
double BufAtrPct[];

//--- modules ------------------------------------------------------
CSignalEngine      g_signal;
CVolatilityRegime  g_vol;
CRiskManager       g_risk;

int                g_min_bars = 0;
const string       PANEL_PREFIX = "DTF_DASH_";

//--- colour indices for the histogram
#define CLR_NEUTRAL 0
#define CLR_LONG    1
#define CLR_SHORT   2

//--- forward declarations (panel helpers are defined below OnCalculate)
string PanelPad(const string s,const int width);
void   PanelLine(const int idx,const string text,const color clr);
void   UpdatePanel(const int shift,
                   const double &sig[],const double &cf[],
                   const double &cm[],const double &cs[],
                   const double &atr[],const double &atr_pct[],
                   const double &bbw[],const double &bb_pct[]);

//+------------------------------------------------------------------+
int OnInit()
  {
   //--- buffers, all series-indexed so index 0 is the current bar and
   //--- the module output arrays can be copied across one-to-one.
   SetIndexBuffer(0,BufSignal,INDICATOR_DATA);
   SetIndexBuffer(1,BufSignalColor,INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2,BufFast,INDICATOR_DATA);
   SetIndexBuffer(3,BufMid,INDICATOR_DATA);
   SetIndexBuffer(4,BufSlow,INDICATOR_DATA);
   SetIndexBuffer(5,BufAtrPct,INDICATOR_DATA);

   ArraySetAsSeries(BufSignal,true);
   ArraySetAsSeries(BufSignalColor,true);
   ArraySetAsSeries(BufFast,true);
   ArraySetAsSeries(BufMid,true);
   ArraySetAsSeries(BufSlow,true);
   ArraySetAsSeries(BufAtrPct,true);

   for(int p=0;p<5;p++)
      PlotIndexSetDouble(p,PLOT_EMPTY_VALUE,EMPTY_VALUE);

   if(!InpShowComponents)
     {
      PlotIndexSetInteger(1,PLOT_DRAW_TYPE,DRAW_NONE);
      PlotIndexSetInteger(2,PLOT_DRAW_TYPE,DRAW_NONE);
      PlotIndexSetInteger(3,PLOT_DRAW_TYPE,DRAW_NONE);
     }
   if(!InpShowAtrPct)
      PlotIndexSetInteger(4,PLOT_DRAW_TYPE,DRAW_NONE);

   //--- entry threshold drawn as levels, so "is this bar tradeable?"
   //--- is answerable at a glance.
   IndicatorSetInteger(INDICATOR_LEVELS,3);
   IndicatorSetDouble(INDICATOR_LEVELVALUE,0, InpSignalThreshold);
   IndicatorSetDouble(INDICATOR_LEVELVALUE,1, 0.0);
   IndicatorSetDouble(INDICATOR_LEVELVALUE,2,-InpSignalThreshold);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR,0,clrLimeGreen);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR,1,clrDimGray);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR,2,clrTomato);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE,0,STYLE_DOT);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE,1,STYLE_DOT);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE,2,STYLE_DOT);
   IndicatorSetInteger(INDICATOR_DIGITS,2);
   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("DTF %d/%d/%d",InpFastPeriod,InpMidPeriod,InpSlowPeriod));

   //--- validate the few inputs that could silently produce nonsense
   if(InpSignalThreshold<=0.0 || InpSignalThreshold>=1.0)
     {
      Print("DTF_Dashboard: signal threshold must be strictly between 0 and 1");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpAtrStopMult<=0.0)
     {
      Print("DTF_Dashboard: ATR stop multiple must be > 0");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpCompressionPct<0.0 || InpCompressionPct>=InpExpansionPct || InpExpansionPct>100.0)
     {
      Print("DTF_Dashboard: need 0 <= compression pct < expansion pct <= 100");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(!g_signal.Init(_Symbol,(ENUM_TIMEFRAMES)_Period,
                     InpFastPeriod,InpMidPeriod,InpSlowPeriod,
                     InpSignalMode,InpAtrPeriod,InpEmaAtrNorm))
      return(INIT_FAILED);

   if(!g_vol.Init(_Symbol,(ENUM_TIMEFRAMES)_Period,
                  InpAtrPeriod,InpBbPeriod,InpBbDeviation,InpPercentileBars,
                  InpCompressionPct,InpExpansionPct,
                  InpExtremeVolPct,InpExtremeVolScale))
      return(INIT_FAILED);

   if(!g_risk.Init(InpRiskPercent,InpMaxMarginPct,InpCheckMargin))
      return(INIT_PARAMETERS_INCORRECT);

   g_min_bars=MathMax(g_signal.MinBars(),g_vol.MinBars());

   for(int p=0;p<5;p++)
      PlotIndexSetInteger(p,PLOT_DRAW_BEGIN,g_min_bars);

   if(_Period!=PERIOD_D1)
      PrintFormat("DTF_Dashboard: running on %s - this system is designed for D1.",
                  EnumToString((ENUM_TIMEFRAMES)_Period));

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_signal.Release();
   g_vol.Release();
   ObjectsDeleteAll(0,PANEL_PREFIX,0,OBJ_LABEL);
   ChartRedraw();
  }
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total<g_min_bars+2)
     {
      static bool warned=false;
      if(!warned)
        {
         PrintFormat("DTF_Dashboard: need %d bars of history, chart has %d. "
                     "Scroll back or increase Max bars in chart.",g_min_bars+2,rates_total);
         warned=true;
        }
      return(0);
     }

   const int calculable=rates_total-g_min_bars;

   int to_calc;
   if(prev_calculated<=0)
      to_calc=calculable;
   else
     {
      //--- +1 so the previously-current bar is rewritten now that it closed
      to_calc=rates_total-prev_calculated+1;
      //--- never fewer than 2: the panel reads the last CLOSED bar
      //--- (shift 1), so a 1-bar refresh would leave it frozen all day
      if(to_calc<2)          to_calc=2;
      if(to_calc>calculable) to_calc=calculable;
     }

   double sig[],cf[],cm[],cs[];
   if(g_signal.Calculate(to_calc,sig,cf,cm,cs)<to_calc)
      return(prev_calculated);   // history not ready yet, try again next tick

   double atr[],atr_pct[],bbw[],bb_pct[];
   if(g_vol.Calculate(to_calc,atr,atr_pct,bbw,bb_pct)<to_calc)
      return(prev_calculated);

   //--- On a full recalculation, blank the warm-up tail explicitly so
   //--- stale values from a previous timeframe can never be drawn.
   if(prev_calculated<=0)
      for(int i=to_calc;i<rates_total;i++)
        {
         BufSignal[i]     = EMPTY_VALUE;
         BufSignalColor[i]= CLR_NEUTRAL;
         BufFast[i]       = EMPTY_VALUE;
         BufMid[i]        = EMPTY_VALUE;
         BufSlow[i]       = EMPTY_VALUE;
         BufAtrPct[i]     = EMPTY_VALUE;
        }

   for(int i=0;i<to_calc;i++)
     {
      BufSignal[i] = sig[i];
      BufFast[i]   = cf[i];
      BufMid[i]    = cm[i];
      BufSlow[i]   = cs[i];
      BufAtrPct[i] = (atr_pct[i]>=0.0 ? atr_pct[i]/100.0 : EMPTY_VALUE);

      if(sig[i]>=InpSignalThreshold)       BufSignalColor[i]=CLR_LONG;
      else if(sig[i]<=-InpSignalThreshold) BufSignalColor[i]=CLR_SHORT;
      else                                 BufSignalColor[i]=CLR_NEUTRAL;
     }

   if(InpShowPanel)
     {
      int shift=(InpUseClosedBar ? 1 : 0);
      if(shift<to_calc)
         UpdatePanel(shift,sig,cf,cm,cs,atr,atr_pct,bbw,bb_pct);
     }

   return(rates_total);
  }
//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
//| Pad a label so the monospace panel lines up.                     |
//+------------------------------------------------------------------+
string PanelPad(const string s,const int width)
  {
   string out=s;
   for(int i=StringLen(s);i<width;i++)
      out+=" ";
   return(out);
  }
//+------------------------------------------------------------------+
void PanelLine(const int idx,const string text,const color clr)
  {
   string name=PANEL_PREFIX+IntegerToString(idx);
   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0))
         return;
      ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,InpPanelFontSize);
      ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
      //--- Font size is in points and the terminal scales it by screen
      //--- DPI, but X/Y offsets are raw pixels and do not scale. On a
      //--- 125%/150% display that mismatch makes the lines overlap, so
      //--- scale the line step by DPI to match the rendered text.
      int dpi=(int)TerminalInfoInteger(TERMINAL_SCREEN_DPI);
      if(dpi<=0) dpi=96;
      int step=(InpPanelFontSize+7)*dpi/96;
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,InpPanelX);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,InpPanelY+idx*step);
      //--- anchor follows the chosen corner so right-hand corners do
      //--- not push the text off the chart
      if(InpPanelCorner==CORNER_RIGHT_UPPER)
         ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_RIGHT_UPPER);
      else if(InpPanelCorner==CORNER_RIGHT_LOWER)
         ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_RIGHT_LOWER);
      else if(InpPanelCorner==CORNER_LEFT_LOWER)
         ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
      else
         ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
     }
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
  }
//+------------------------------------------------------------------+
//| Rebuild the text panel from the values of one bar.                |
//+------------------------------------------------------------------+
void UpdatePanel(const int shift,
                 const double &sig[],const double &cf[],
                 const double &cm[],const double &cs[],
                 const double &atr[],const double &atr_pct[],
                 const double &bbw[],const double &bb_pct[])
  {
   SDtfVolState vs;
   g_vol.Classify(atr[shift],atr_pct[shift],bbw[shift],bb_pct[shift],vs);

   const double signal=sig[shift];
   string direction="FLAT";
   color  dir_color=clrSilver;
   if(signal>=InpSignalThreshold)       { direction="LONG";  dir_color=clrLimeGreen; }
   else if(signal<=-InpSignalThreshold) { direction="SHORT"; dir_color=clrTomato;    }

   //--- Stop first, size second: the stop is what defines the risk.
   const double stop_dist=g_risk.StopDistance(atr[shift],InpAtrStopMult);
   const double equity=(InpEquityOverride>0.0 ? InpEquityOverride
                                              : AccountInfoDouble(ACCOUNT_EQUITY));

   SDtfSizing sz;
   g_risk.CalcLots(_Symbol,stop_dist,equity,vs.size_scale,sz);

   //--- Read the bar directly rather than relying on the indexing
   //--- direction of the arrays OnCalculate hands us.
   double   c[];
   datetime t[];
   ArraySetAsSeries(c,true);
   ArraySetAsSeries(t,true);
   if(CopyClose(_Symbol,(ENUM_TIMEFRAMES)_Period,0,shift+1,c)<shift+1) return;
   if(CopyTime(_Symbol,(ENUM_TIMEFRAMES)_Period,0,shift+1,t)<shift+1)  return;
   const double   bar_close=c[shift];
   const datetime bar_time =t[shift];

   const string acct=AccountInfoString(ACCOUNT_CURRENCY);
   const int    dg  =(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   int n=0;
   PanelLine(n++,StringFormat("DTF Dashboard  %s  %s  [%s]",
                              _Symbol,EnumToString((ENUM_TIMEFRAMES)_Period),
                              (InpUseClosedBar ? "closed bar" : "forming bar")),
             clrWhite);

   PanelLine(n++,PanelPad("Signal",14)+StringFormat(": %+.2f  %s   (threshold %.2f)",
                          signal,direction,InpSignalThreshold),
             dir_color);

   PanelLine(n++,PanelPad("  components",14)+StringFormat(": %d %+.2f   %d %+.2f   %d %+.2f",
                          InpFastPeriod,cf[shift],InpMidPeriod,cm[shift],
                          InpSlowPeriod,cs[shift]),
             InpPanelTextColor);

   PanelLine(n++,PanelPad(StringFormat("ATR(%d)",InpAtrPeriod),14)+
                 StringFormat(": %s  (%.1f pips)   pct %s",
                          DoubleToString(atr[shift],dg),
                          DTF_PriceToPips(_Symbol,atr[shift]),
                          (atr_pct[shift]>=0.0 ? DoubleToString(atr_pct[shift],0) : "n/a")),
             InpPanelTextColor);

   string bb_note="";
   color  bb_color=InpPanelTextColor;
   if(vs.compression) { bb_note="   <<< COMPRESSION"; bb_color=clrAqua;      }
   if(vs.expansion)   { bb_note="   >>> EXPANSION";   bb_color=clrSandyBrown;}
   PanelLine(n++,PanelPad("BB width pct",14)+
                 StringFormat(": %s%s",
                          (bb_pct[shift]>=0.0 ? DoubleToString(bb_pct[shift],0) : "n/a"),
                          bb_note),
             bb_color);

   PanelLine(n++,PanelPad("Vol regime",14)+
                 StringFormat(": %s   (risk x%.2f)",
                          DTF_RegimeToString(vs.regime),vs.size_scale),
             (vs.regime==DTF_REGIME_EXTREME ? clrOrange : InpPanelTextColor));

   PanelLine(n++,PanelPad(StringFormat("Stop %.1fxATR",InpAtrStopMult),14)+
                 StringFormat(": %.1f pips   long SL %s / short SL %s",
                          sz.stop_pips,
                          DoubleToString(bar_close-stop_dist,dg),
                          DoubleToString(bar_close+stop_dist,dg)),
             InpPanelTextColor);

   PanelLine(n++,PanelPad("Risk",14)+
                 StringFormat(": %.2f%% of %.2f %s = %.2f %s",
                          sz.risk_pct_used,equity,acct,
                          equity*sz.risk_pct_used/100.0,acct),
             InpPanelTextColor);

   if(sz.valid)
      PanelLine(n++,PanelPad("Lots",14)+
                    StringFormat(": %.2f   (actual risk %.2f %s%s)",
                             sz.lots,sz.risk_money,acct,
                             (sz.margin>=0.0 ? StringFormat(", margin %.2f",sz.margin) : "")),
                clrLimeGreen);
   else
     {
      PanelLine(n++,PanelPad("Lots",14)+": NO TRADE - "+sz.note,clrTomato);
      //--- Spell out WHY on its own lines. "below min lot" on a small
      //--- account is not a glitch to work around, it is the system
      //--- saying this pair costs more than the risk budget allows.
      if(sz.min_lot_risk>0.0)
        {
         PanelLine(n++,PanelPad("  min lot risks",14)+
                       StringFormat(": %.2f %s = %.2f%% of equity",
                                sz.min_lot_risk,acct,
                                (equity>0.0 ? sz.min_lot_risk/equity*100.0 : 0.0)),
                   clrTomato);
         PanelLine(n++,PanelPad("  needs equity",14)+
                       StringFormat(": %.0f %s to trade at %.2f%%",
                                sz.equity_needed,acct,sz.risk_pct_used),
                   clrTomato);
        }
     }

   if(StringLen(sz.note)>0 && sz.valid)
      PanelLine(n++,PanelPad("  note",14)+": "+sz.note,clrSandyBrown);

   PanelLine(n++,PanelPad("Bar",14)+": "+TimeToString(bar_time,TIME_DATE),clrSlateGray);

   //--- clear any leftover lines from a longer previous render
   for(int i=n;i<16;i++)
     {
      string name=PANEL_PREFIX+IntegerToString(i);
      if(ObjectFind(0,name)>=0)
         ObjectDelete(0,name);
     }

   ChartRedraw();
  }
//+------------------------------------------------------------------+
