//+------------------------------------------------------------------+
//|                                                 DTF_RelVolume.mq5 |
//|      Relative (tick) volume - is there enough volume behind a move |
//+------------------------------------------------------------------+
//| WHAT THIS IS FOR
//| ----------------
//| Spot forex has no central exchange, so there is no true volume.
//| MT5's tick volume (how many times price changed in a candle)
//| tracks real traded volume closely, so that is what this uses.
//|
//| Raw volume is misleading in forex: the London / New York hours are
//| ALWAYS busier than Asia. So each candle is compared with the SAME
//| time of day over the last N days:
//|
//|     100% = a normal amount of volume for this hour
//|     150% = half as much again as normal  -> "enough volume"
//|     200% = double normal                 -> strong participation
//|
//| On D1 and higher there is no time of day, so each candle is simply
//| compared with the last N candles.
//|
//| COLOURS
//|   grey        below the "enough" level - weak participation
//|   green / red up / down candle at or above the "enough" level
//|   lime / red  (bright) up / down candle at or above the "strong" level
//|
//| Volume CONFIRMS a move, it does not predict one. Use it as a filter
//| on a setup you already have: e.g. only take the entry when the
//| candle in your trend direction is green (buys) or red (sells).
//| A very big bar AGAINST a long move can also mean exhaustion.
//|
//| The current candle is still forming, so its bar is always low at
//| first. The title shows how it is pacing (rough: volume is not
//| spread evenly inside a candle).
//|
//| Read-only: it only draws. It never places, changes or closes trades.
//+------------------------------------------------------------------+
#property copyright "DTF"
#property version   "1.00"
#property description "Tick volume as % of normal for the same time of day. 100% = normal."
#property indicator_separate_window
#property indicator_buffers 3
#property indicator_plots   1
#property indicator_minimum 0

#property indicator_label1  "Volume % of normal"
#property indicator_type1   DRAW_COLOR_HISTOGRAM
#property indicator_color1  clrDimGray,clrSeaGreen,clrIndianRed,clrLime,clrRed
#property indicator_width1  3

input int    InpLookbackDays = 20;    // Compare with the last N days (same time of day)
input double InpEnough       = 150;   // "Enough volume" level, % of normal
input double InpStrong       = 200;   // "Strong volume" level, % of normal
input bool   InpUseRealVolume = false; // Use real volume if the broker has it (forex: no)
input bool   InpAlert        = false; // Alert when a candle CLOSES at/above "enough"
input bool   InpAlertPush    = false; // Also send the alert to the MT5 phone app
input int    InpMaxBars      = 5000;  // Bars to calculate (more = slower)

double Rel[];   // volume as % of normal
double Clr[];   // colour index
double Avg[];   // normal volume for that bar (same time of day, previous N days)

int    g_slots;        // time-of-day slots per day (1 on D1 and above)
double g_ring[];       // last N closed volumes per slot, flat [slot * N + k]
int    g_cnt[], g_pos[];
double g_sum[];
datetime g_lastAlert = 0;

int OnInit()
{
   if(InpLookbackDays < 2)
   {
      Print("DTF_RelVolume: lookback must be at least 2 days");
      return INIT_PARAMETERS_INCORRECT;
   }
   SetIndexBuffer(0, Rel, INDICATOR_DATA);
   SetIndexBuffer(1, Clr, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, Avg, INDICATOR_CALCULATIONS);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   IndicatorSetInteger(INDICATOR_DIGITS, 0);

   double lv[3]   = {100, 0, 0};
   string txt[3]  = {"normal", "enough", "strong"};
   color  col[3]  = {clrGray, clrGoldenrod, clrOrangeRed};
   lv[1] = InpEnough;
   lv[2] = InpStrong;
   IndicatorSetInteger(INDICATOR_LEVELS, 3);
   for(int i = 0; i < 3; i++)
   {
      IndicatorSetDouble(INDICATOR_LEVELVALUE, i, lv[i]);
      IndicatorSetString(INDICATOR_LEVELTEXT, i, txt[i]);
      IndicatorSetInteger(INDICATOR_LEVELCOLOR, i, col[i]);
      IndicatorSetInteger(INDICATOR_LEVELSTYLE, i, STYLE_DOT);
   }

   int sec = PeriodSeconds();
   g_slots = (sec < 86400) ? 86400 / sec : 1;
   ArrayResize(g_ring, g_slots * InpLookbackDays);
   ArrayResize(g_cnt, g_slots);
   ArrayResize(g_pos, g_slots);
   ArrayResize(g_sum, g_slots);
   IndicatorSetString(INDICATOR_SHORTNAME, "RelVolume");
   return INIT_SUCCEEDED;
}

string TfName()
{
   return StringSubstr(EnumToString((ENUM_TIMEFRAMES)_Period), 7);
}

int SlotOf(datetime t)
{
   if(g_slots == 1)
      return 0;
   int s = (int)((t % 86400) / PeriodSeconds());
   return MathMin(s, g_slots - 1);
}

// -1 down candle, +1 up candle, 0 doji
int Dir(double o, double c)
{
   return c > o ? 1 : (c < o ? -1 : 0);
}

void Paint(int i, double vol, int dir)
{
   if(Avg[i] <= 0 || Avg[i] == EMPTY_VALUE)
   {
      Rel[i] = EMPTY_VALUE;
      Clr[i] = 0;
      return;
   }
   Rel[i] = vol / Avg[i] * 100.0;
   if(Rel[i] < InpEnough || dir == 0)
      Clr[i] = 0;
   else if(Rel[i] < InpStrong)
      Clr[i] = (dir > 0) ? 1 : 2;
   else
      Clr[i] = (dir > 0) ? 3 : 4;
}

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
   if(rates_total < 2)
      return 0;
   int last = rates_total - 1;
   bool newBar = (prev_calculated != rates_total);

   if(newBar)
   {
      // Rebuild everything once per new candle: cheap, and no state to go stale.
      ArrayInitialize(Rel, EMPTY_VALUE);
      ArrayInitialize(Clr, 0);
      ArrayInitialize(Avg, EMPTY_VALUE);
      ArrayInitialize(g_cnt, 0);
      ArrayInitialize(g_pos, 0);
      ArrayInitialize(g_sum, 0);
      int start = MathMax(0, rates_total - InpMaxBars);
      int need  = MathMax(2, InpLookbackDays / 2);   // enough history to call it "normal"
      for(int i = start; i <= last; i++)
      {
         double v = (double)((InpUseRealVolume && volume[i] > 0) ? volume[i] : tick_volume[i]);
         int s = SlotOf(time[i]);
         if(g_cnt[s] >= need)
            Avg[i] = g_sum[s] / g_cnt[s];
         Paint(i, v, Dir(open[i], close[i]));
         if(i == last)
            break;                                    // forming candle is not "history" yet
         int k = s * InpLookbackDays + g_pos[s];
         if(g_cnt[s] == InpLookbackDays)
            g_sum[s] -= g_ring[k];
         else
            g_cnt[s]++;
         g_ring[k] = v;
         g_sum[s] += v;
         g_pos[s] = (g_pos[s] + 1) % InpLookbackDays;
      }

      // Alert on the candle that just closed
      int c = last - 1;
      if(InpAlert && prev_calculated > 0 && time[c] != g_lastAlert &&
         Rel[c] != EMPTY_VALUE && Rel[c] >= InpEnough && Dir(open[c], close[c]) != 0)
      {
         g_lastAlert = time[c];
         string msg = StringFormat("%s %s: %s candle closed with %.0f%% of normal volume",
                                   _Symbol, TfName(), Dir(open[c], close[c]) > 0 ? "UP" : "DOWN", Rel[c]);
         Alert(msg);
         if(InpAlertPush)
            SendNotification(msg);
      }
   }
   else
   {
      double v = (double)((InpUseRealVolume && volume[last] > 0) ? volume[last] : tick_volume[last]);
      Paint(last, v, Dir(open[last], close[last]));
   }

   // Title: last closed candle + how the forming one is pacing
   string title = StringFormat("RelVolume %s (%dd)", TfName(), InpLookbackDays);
   int c = last - 1;
   if(Rel[c] != EMPTY_VALUE)
   {
      int d = Dir(open[c], close[c]);
      title += StringFormat(" | last candle %.0f%% %s", Rel[c], d > 0 ? "UP" : (d < 0 ? "DOWN" : "doji"));
   }
   if(Rel[last] != EMPTY_VALUE)
   {
      double frac = (double)(TimeCurrent() - time[last]) / PeriodSeconds();
      title += StringFormat(" | this candle so far %.0f%%", Rel[last]);
      if(frac > 0.1 && frac < 1.0)
         title += StringFormat(" (on pace for ~%.0f%%)", Rel[last] / frac);
   }
   IndicatorSetString(INDICATOR_SHORTNAME, title);
   return rates_total;
}
//+------------------------------------------------------------------+
