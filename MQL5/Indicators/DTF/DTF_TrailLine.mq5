//+------------------------------------------------------------------+
//|                                                 DTF_TrailLine.mq5 |
//|        Trailing-stop line for YOUR open trade, on the H4 chart     |
//+------------------------------------------------------------------+
//| WHAT THIS IS FOR
//| ----------------
//| You trade by hand. This draws where your stop loss should be on
//| every H4 candle of an open trade, and tells you when to move it.
//| It never touches the trade - you move the SL yourself.
//|
//|  * Start: the stop sits 2 x the typical H4 candle from the entry
//|    (typical = median high-low of the 120 H4 candles closed before
//|    the trade opened - the same SL the daily tool suggests).
//|  * Trail: after every closed H4 candle the stop is pulled up to
//|    the best price since entry minus that same distance (down to
//|    the lowest price plus the distance for a sell). It only ever
//|    moves in the trade's favour.
//|  * Exit warning: the D1 trend score crossing zero against the
//|    trade. The tested rule closes the trade the next morning.
//|
//| WHY THIS RULE
//| -------------
//| confirm_research.py --only h4exits, 29 pairs, H4, plan-style trades
//| (clean D1 trend, 08:00 entry, SL 2 x typical H4 candle). Chosen on
//| 2021-2023, checked on 2024-2026:
//|    take profit at 2R (the plan before) : -0.045R / -0.102R a trade
//|    this trail (2 x typical H4 candle)  : -0.024R / -0.073R a trade
//| The trail loses less than a fixed take profit in both periods. It
//| does NOT make the entries profitable - nothing tested did. It is a
//| better way to manage a trade, not a reason to open one.
//|
//| Values only change when an H4 candle closes, so the line never
//| repaints. Read-only: no orders are placed, modified or closed.
//+------------------------------------------------------------------+
#property copyright "DTF"
#property version   "1.00"
#property description "Trailing stop line for your open trade on this symbol (H4). Read-only."
#property indicator_chart_window
#property indicator_buffers 1
#property indicator_plots   1

#property indicator_label1  "Trail stop"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrOrange
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

#include <DTF/Common.mqh>
#include <DTF/SignalEngine.mqh>

//--- Trail ----------------------------------------------------------
input group           "=== Trailing stop ==="
input double               InpTrailMult      = 2.0;            // Stop distance = N x typical H4 candle
input int                  InpUnitBars       = 120;            // Typical candle = median of this many H4 candles

//--- Trend exit -----------------------------------------------------
input group           "=== D1 trend exit warning ==="
input bool                 InpUseFlipWarning = true;           // Warn when the D1 trend turns against the trade
input double               InpFlipLevel      = 0.0;            // Warn when the score crosses this level
input int                  InpFastPeriod     = 20;             // Fast lookback (D1 bars)
input int                  InpMidPeriod      = 60;             // Medium lookback (D1 bars)
input int                  InpSlowPeriod     = 120;            // Slow lookback (D1 bars)
input double               InpEmaAtrNorm     = 2.0;            // ATRs from EMA that count as full +-1

//--- Alerts and display ---------------------------------------------
input group           "=== Alerts and display ==="
input bool                 InpAlert          = true;           // Pop-up alert when the SL should move
input bool                 InpAlertPush      = false;          // Also send to the MT5 phone app
input ENUM_BASE_CORNER     InpPanelCorner    = CORNER_LEFT_UPPER; // Panel corner
input int                  InpPanelX         = 12;             // Panel X offset (px)
input int                  InpPanelY         = 22;             // Panel Y offset (px)
input int                  InpPanelFontSize  = 9;              // Panel font size

double BufTrail[];

CSignalEngine g_signal;
bool          g_have_signal = false;
const string  PANEL_PREFIX  = "DTF_TRAIL_";

//--- what the last calculation found, for alerts and the panel
ulong    g_ticket      = 0;
datetime g_alert_bar   = 0;     // H4 candle we last alerted on
datetime g_flip_bar    = 0;     // D1 candle we last warned about

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpTrailMult<=0.0 || InpUnitBars<20)
     {
      Print("DTF_TrailLine: trail multiple must be > 0 and typical-candle bars >= 20");
      return(INIT_PARAMETERS_INCORRECT);
     }
   SetIndexBuffer(0,BufTrail,INDICATOR_DATA);
   PlotIndexSetDouble(0,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   IndicatorSetString(INDICATOR_SHORTNAME,"DTF Trail");
   IndicatorSetInteger(INDICATOR_DIGITS,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));

   if(InpUseFlipWarning)
      g_have_signal=g_signal.Init(_Symbol,PERIOD_D1,InpFastPeriod,InpMidPeriod,InpSlowPeriod,
                                  DTF_SIGNAL_BOTH,20,InpEmaAtrNorm);

   if(_Period!=PERIOD_H4)
      PrintFormat("DTF_TrailLine: tested and built for H4 - this chart is %s, the line is not drawn.",
                  EnumToString((ENUM_TIMEFRAMES)_Period));
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_signal.Release();
   ObjectsDeleteAll(0,PANEL_PREFIX,0,OBJ_LABEL);
   ChartRedraw();
  }
//+------------------------------------------------------------------+
//| The newest open position on this chart's symbol (any magic: the   |
//| trades this is for are opened by hand). False if there is none.   |
//+------------------------------------------------------------------+
bool FindPosition(ulong &ticket,int &dir,double &open_px,datetime &open_t,
                  double &sl,double &lots)
  {
   ticket=0;
   datetime newest=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      datetime t=(datetime)PositionGetInteger(POSITION_TIME);
      if(t<newest)
         continue;
      newest =t;
      ticket =tk;
      dir    =(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1);
      open_px=PositionGetDouble(POSITION_PRICE_OPEN);
      open_t =t;
      sl     =PositionGetDouble(POSITION_SL);
      lots   =PositionGetDouble(POSITION_VOLUME);
     }
   return(ticket!=0);
  }
//+------------------------------------------------------------------+
//| Median high-low of the H4 candles [from, to) - the typical candle.|
//+------------------------------------------------------------------+
double MedianRange(const double &high[],const double &low[],const int from,const int to)
  {
   int n=to-from;
   if(from<0 || n<=0)
      return(0.0);
   double r[];
   ArrayResize(r,n);
   for(int i=0;i<n;i++)
      r[i]=high[from+i]-low[from+i];
   ArraySort(r);
   return(n%2==1 ? r[n/2] : (r[n/2-1]+r[n/2])/2.0);
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
   //--- plain (non-series) arrays: index 0 = oldest, rates_total-1 = forming
   ArrayInitialize(BufTrail,EMPTY_VALUE);
   const int    last=rates_total-1;
   const double pip =DTF_PipSize(_Symbol);
   const int    dg  =(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   //--- D1 trend score of the last CLOSED daily candle
   double sig=0.0,cf=0.0,cm=0.0,cs=0.0;
   bool   have_sig=(g_have_signal && g_signal.Latest(1,sig,cf,cm,cs));

   ulong ticket; int dir=0; double open_px=0.0,sl=0.0,lots=0.0; datetime open_t=0;
   if(!FindPosition(ticket,dir,open_px,open_t,sl,lots))
     {
      g_ticket=0;
      double unit=(rates_total>InpUnitBars+1 ? MedianRange(high,low,last-InpUnitBars,last) : 0.0);
      string l1="No open trade on "+_Symbol+".";
      string l2=(_Period==PERIOD_H4 && unit>0.0 && pip>0.0
                 ? StringFormat("A new trade's SL: %.1f x typical H4 candle = %.0f pips.",InpTrailMult,InpTrailMult*unit/pip)
                 : "Open an H4 chart to see the suggested SL.");
      string l3=(have_sig ? StringFormat("D1 trend score %+.2f",sig) : "");
      ShowPanel(l1,clrSilver,l2,clrGainsboro,l3,clrGainsboro,"",clrNONE,"",clrNONE);
      return(rates_total);
     }
   if(ticket!=g_ticket)
     {
      g_ticket=ticket;
      g_alert_bar=0;
      g_flip_bar=0;
     }

   if(_Period!=PERIOD_H4 || pip<=0.0)
     {
      ShowPanel("DTF Trail: switch this chart to H4.",clrOrange,"",clrNONE,"",clrNONE,"",clrNONE,"",clrNONE);
      return(rates_total);
     }

   //--- the H4 candle the trade was opened in
   int e=last;
   while(e>0 && time[e]>open_t)
      e--;
   if(e<InpUnitBars)
     {
      ShowPanel("DTF Trail: not enough H4 history before the entry.",clrOrange,
                "Scroll the chart back to load more candles.",clrGainsboro,"",clrNONE,"",clrNONE,"",clrNONE);
      return(rates_total);
     }

   //--- distance fixed at entry: the typical candle BEFORE the trade
   const double dist=InpTrailMult*MedianRange(high,low,e-InpUnitBars,e);
   double stop=open_px-dir*dist;      // starting stop
   double ext =open_px;               // best price since entry

   //--- The stop in force during candle k uses candles e..k-1 only, so
   //--- the forming candle never moves the line - no repainting.
   for(int k=e;k<=last;k++)
     {
      BufTrail[k]=stop;
      if(k==last)
         break;
      //--- the entry candle's high/low may come from BEFORE the fill, so
      //--- it only counts when the trade opened at that candle's open
      if(k>e || open_t==time[e])
         ext=(dir>0 ? MathMax(ext,high[k]) : MathMin(ext,low[k]));
      double lvl=ext-dir*dist;
      stop=(dir>0 ? MathMax(stop,lvl) : MathMin(stop,lvl));
     }
   const double trail=BufTrail[last];

   //--- what the trade looks like against the line
   const double bid  =SymbolInfoDouble(_Symbol,SYMBOL_BID);
   const double ask  =SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   const double price=(dir>0 ? bid : ask);       // the side a stop triggers on
   const double half =0.5*pip;

   string l1=StringFormat("%s %.2f %s @ %s   trail stop %s  (%+.0f pips from entry)",
                          (dir>0 ? "BUY" : "SELL"),lots,_Symbol,DoubleToString(open_px,dg),
                          DoubleToString(trail,dg),dir*(trail-open_px)/pip);
   string l2,l3,l4="",l5="";
   color  c2,c3,c4=clrGainsboro,c5=clrGainsboro;

   bool through=(dir>0 ? price<=trail : price>=trail);
   bool behind =(sl<=0.0 || (dir>0 ? sl<trail-half : sl>trail+half));
   if(through)
     {
      l2="Price is through the trail stop - the plan exits here. Close the trade.";
      c2=clrTomato;
     }
   else if(sl<=0.0)
     {
      l2="NO STOP LOSS on this trade! Set SL to "+DoubleToString(trail,dg)+" now.";
      c2=clrTomato;
     }
   else if(behind)
     {
      l2=StringFormat("Move your SL from %s to %s  (%.0f pips closer)",
                      DoubleToString(sl,dg),DoubleToString(trail,dg),MathAbs(trail-sl)/pip);
      c2=clrYellow;
     }
   else
     {
      l2="Your SL ("+DoubleToString(sl,dg)+") is at or ahead of the trail - nothing to do.";
      c2=clrLimeGreen;
     }
   l3=StringFormat("Price is %.0f pips from the trail stop. It can only move %s, at H4 candle closes.",
                   MathAbs(price-trail)/pip,(dir>0 ? "UP" : "DOWN"));
   c3=clrGainsboro;

   bool flip=false;
   if(have_sig)
     {
      flip=(dir>0 ? sig<=InpFlipLevel : sig>=-InpFlipLevel);
      l4=StringFormat("D1 trend score %+.2f%s",sig,
                      (flip ? "  - TURNED AGAINST your trade: the plan closes it next morning." : "  - still with your trade."));
      c4=(flip ? clrTomato : clrGainsboro);
     }
   l5=StringFormat("Stop distance %.0f pips = %.1f x typical H4 candle before entry. Read-only: you move the SL.",
                   dist/pip,InpTrailMult);
   c5=clrSlateGray;
   ShowPanel(l1,clrWhite,l2,c2,l3,c3,l4,c4,l5,c5);

   //--- alerts: once per H4 candle for the SL, once per D1 candle for the trend
   if(InpAlert && prev_calculated>0)
     {
      if((behind || through) && time[last]!=g_alert_bar && last>e)
        {
         g_alert_bar=time[last];
         Notify(_Symbol+" "+(dir>0 ? "BUY" : "SELL")+": "+l2);
        }
      datetime d1[];
      if(flip && CopyTime(_Symbol,PERIOD_D1,1,1,d1)==1 && d1[0]!=g_flip_bar)
        {
         g_flip_bar=d1[0];
         Notify(_Symbol+": D1 trend turned against your "+(dir>0 ? "BUY" : "SELL")+
                StringFormat(" (score %+.2f) - plan: close it next morning.",sig));
        }
     }
   return(rates_total);
  }
//+------------------------------------------------------------------+
void Notify(const string msg)
  {
   Alert(msg);
   if(InpAlertPush)
      SendNotification(msg);
  }
//+------------------------------------------------------------------+
//| Five-line text panel. Empty text removes the line.                |
//+------------------------------------------------------------------+
void PanelLine(const int idx,const string text,const color clr)
  {
   string name=PANEL_PREFIX+IntegerToString(idx);
   if(text=="")
     {
      ObjectDelete(0,name);
      return;
     }
   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0))
         return;
      ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,InpPanelFontSize);
      ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
      //--- line step scaled by DPI, as in DTF_Dashboard
      int dpi=(int)TerminalInfoInteger(TERMINAL_SCREEN_DPI);
      if(dpi<=0) dpi=96;
      int step=(InpPanelFontSize+7)*dpi/96;
      bool lower=(InpPanelCorner==CORNER_LEFT_LOWER || InpPanelCorner==CORNER_RIGHT_LOWER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,InpPanelX);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,InpPanelY+(lower ? 4-idx : idx)*step);
      if(InpPanelCorner==CORNER_RIGHT_UPPER)      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_RIGHT_UPPER);
      else if(InpPanelCorner==CORNER_RIGHT_LOWER) ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_RIGHT_LOWER);
      else if(InpPanelCorner==CORNER_LEFT_LOWER)  ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
      else                                        ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
     }
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
  }
//+------------------------------------------------------------------+
void ShowPanel(const string t1,const color c1,const string t2,const color c2,
               const string t3,const color c3,const string t4,const color c4,
               const string t5,const color c5)
  {
   PanelLine(0,t1,c1);
   PanelLine(1,t2,c2);
   PanelLine(2,t3,c3);
   PanelLine(3,t4,c4);
   PanelLine(4,t5,c5);
   ChartRedraw();
  }
//+------------------------------------------------------------------+
