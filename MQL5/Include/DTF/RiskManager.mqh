//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|        Daily Trend-Following System - stop distance -> lot size    |
//+------------------------------------------------------------------+
//| TRADING LOGIC
//| ------------
//| Expectancy comes from capping the loss, not from picking winners.
//| So the stop is decided FIRST, from volatility (ATR multiple), and
//| the position size is whatever makes that stop cost exactly the
//| planned fraction of equity. Size is the dependent variable; risk
//| is the constant. A wide-stop setup gets a small position and a
//| tight-stop setup gets a large one, and both lose the same amount
//| when they are wrong - which is what makes an R-multiple a
//| meaningful unit to measure the system in.
//|
//| Phase 1 uses only the sizing half of this module (the indicator
//| shows the lots it would suggest). Currency-exposure netting and
//| the drawdown circuit breakers land in phases 3 and 4 and will
//| reuse these same functions, so the number on the chart and the
//| number the EA trades can never drift apart.
//+------------------------------------------------------------------+
#ifndef DTF_RISKMANAGER_MQH
#define DTF_RISKMANAGER_MQH

#include <DTF/Common.mqh>

//+------------------------------------------------------------------+
//| Full working of one sizing decision, so the journal and the       |
//| dashboard can explain the number rather than just print it.       |
//+------------------------------------------------------------------+
struct SDtfSizing
  {
   bool     valid;            // false = do not trade this
   double   lots;             // normalised to the broker lot step
   double   risk_money;       // money at risk if the stop is hit
   double   risk_pct_used;    // after the volatility scale
   double   stop_distance;    // price distance, entry to stop
   double   stop_pips;
   double   loss_per_lot;     // money lost per 1.00 lot over that distance
   double   min_lot_risk;     // what the smallest allowed position would risk
   double   equity_needed;    // equity required before min lot fits the risk %
   double   margin;           // margin the position needs, -1 if unavailable
   double   free_margin;      // free margin at the time of the check
   string   note;             // why it was rejected or downsized
  };

//+------------------------------------------------------------------+
//| CRiskManager                                                     |
//| Stateless with respect to the market: every call is given the     |
//| symbol, the stop distance and the equity, so the same instance    |
//| serves every pair in the basket.                                 |
//+------------------------------------------------------------------+
class CRiskManager
  {
private:
   double            m_risk_pct;        // % of equity per trade
   double            m_max_margin_pct;  // cap on free margin one trade may use
   bool              m_check_margin;

   double            NormaliseLots(const string symbol,const double lots) const;

public:
                     CRiskManager(void);

   bool              Init(const double risk_pct,const double max_margin_pct,
                          const bool check_margin);
   void              SetRiskPercent(const double risk_pct) { m_risk_pct=risk_pct; }
   double            RiskPercent(void) const { return(m_risk_pct); }

   //--- ATR multiple -> price distance. One place, so the indicator's
   //--- suggested stop and the EA's actual stop are the same formula.
   double            StopDistance(const double atr,const double atr_multiple) const
                       { return(atr*atr_multiple); }

   //--- The core sizing call. vol_scale comes from CVolatilityRegime
   //--- (1.0 normally, less in extreme volatility).
   bool              CalcLots(const string symbol,const double stop_distance,
                              const double equity,const double vol_scale,
                              SDtfSizing &out) const;
  };

//+------------------------------------------------------------------+
CRiskManager::CRiskManager(void) : m_risk_pct(0.75),
                                   m_max_margin_pct(30.0),
                                   m_check_margin(true)
  {
  }
//+------------------------------------------------------------------+
bool CRiskManager::Init(const double risk_pct,const double max_margin_pct,
                        const bool check_margin)
  {
   if(risk_pct<=0.0 || risk_pct>10.0)
     {
      Print("DTF/RiskManager: risk per trade must be in (0,10] percent");
      return(false);
     }
   if(max_margin_pct<=0.0 || max_margin_pct>100.0)
     {
      Print("DTF/RiskManager: max margin per trade must be in (0,100] percent");
      return(false);
     }

   m_risk_pct       = risk_pct;
   m_max_margin_pct = max_margin_pct;
   m_check_margin   = check_margin;
   return(true);
  }
//+------------------------------------------------------------------+
//| Round DOWN to the broker lot step and clamp to the allowed range. |
//| Always down: rounding up would quietly exceed the planned risk.   |
//+------------------------------------------------------------------+
double CRiskManager::NormaliseLots(const string symbol,const double lots) const
  {
   double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   double vmin=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   if(step<=0.0) step=0.01;

   double v=MathFloor(lots/step)*step;

   //--- kill floating-point dust such as 0.29999999999
   int digits=(int)MathMax(0.0,MathCeil(-MathLog10(step)-0.0000001));
   v=NormalizeDouble(v,digits);

   if(vmax>0.0 && v>vmax) v=vmax;
   if(v<vmin)             v=0.0;   // caller decides what to do with 0
   return(v);
  }
//+------------------------------------------------------------------+
//| Position size for a given stop distance.                         |
//+------------------------------------------------------------------+
bool CRiskManager::CalcLots(const string symbol,const double stop_distance,
                            const double equity,const double vol_scale,
                            SDtfSizing &out) const
  {
   out.valid         = false;
   out.lots          = 0.0;
   out.risk_money    = 0.0;
   out.risk_pct_used = 0.0;
   out.stop_distance = stop_distance;
   out.stop_pips     = DTF_PriceToPips(symbol,stop_distance);
   out.loss_per_lot  = 0.0;
   out.min_lot_risk  = 0.0;
   out.equity_needed = 0.0;
   out.margin        = -1.0;
   out.free_margin   = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   out.note          = "";

   if(stop_distance<=0.0)
     {
      out.note="stop distance is zero (no ATR yet?)";
      return(false);
     }
   if(equity<=0.0)
     {
      out.note="equity is zero";
      return(false);
     }

   double scale=(vol_scale>0.0 ? vol_scale : 1.0);
   out.risk_pct_used = m_risk_pct*scale;
   out.risk_money    = equity*out.risk_pct_used/100.0;

   //--- What does this stop cost per lot? Use the LOSS tick value:
   //--- for most pairs it equals the profit tick value, but it is the
   //--- correct one for the side of the trade that can hurt us, and it
   //--- already carries the account-currency conversion.
   double tick_size  = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tick_value<=0.0)
      tick_value=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
   if(tick_size<=0.0)
      tick_size=SymbolInfoDouble(symbol,SYMBOL_POINT);

   if(tick_size<=0.0 || tick_value<=0.0)
     {
      out.note="broker tick size/value unavailable for "+symbol;
      return(false);
     }

   out.loss_per_lot=(stop_distance/tick_size)*tick_value;
   if(out.loss_per_lot<=0.0)
     {
      out.note="loss per lot computed as zero";
      return(false);
     }

   //--- What the smallest position the broker allows would cost us, and
   //--- therefore how much equity this pair needs before it can be
   //--- traded at the configured risk at all. On a small account this
   //--- is the number that decides whether the system is runnable.
   double vmin=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   out.min_lot_risk=vmin*out.loss_per_lot;
   if(out.risk_pct_used>0.0)
      out.equity_needed=out.min_lot_risk/(out.risk_pct_used/100.0);

   double lots=NormaliseLots(symbol,out.risk_money/out.loss_per_lot);
   if(lots<=0.0)
     {
      //--- Correct behaviour is to SKIP, never to round up to the
      //--- minimum lot: that would silently risk more than planned.
      out.note=StringFormat("below min lot %.2f",vmin);
      return(false);
     }

   //--- Margin sanity check. OrderCalcMargin is a trade function and
   //--- some contexts (indicators in particular) may refuse it; treat
   //--- failure as "unknown", not as a rejection.
   if(m_check_margin)
     {
      double price=SymbolInfoDouble(symbol,SYMBOL_ASK);
      if(price<=0.0)
         price=SymbolInfoDouble(symbol,SYMBOL_BID);

      double margin=0.0;
      ResetLastError();
      if(price>0.0 && OrderCalcMargin(ORDER_TYPE_BUY,symbol,lots,price,margin))
        {
         out.margin=margin;
         double cap=out.free_margin*m_max_margin_pct/100.0;
         if(margin>cap && margin>0.0)
           {
            double shrunk=NormaliseLots(symbol,lots*cap/margin);
            if(shrunk<=0.0)
              {
               out.note=StringFormat("margin %.2f exceeds cap %.2f, cannot downsize",margin,cap);
               out.lots=0.0;
               return(false);
              }
            out.note=StringFormat("downsized %.2f -> %.2f for margin cap",lots,shrunk);
            lots=shrunk;
            if(OrderCalcMargin(ORDER_TYPE_BUY,symbol,lots,price,margin))
               out.margin=margin;
           }
        }
      else
         out.note="margin check unavailable in this context";
     }

   out.lots=lots;
   //--- Report the risk the FINAL lot size actually carries, not the
   //--- ideal it was derived from - lot-step rounding makes them differ.
   out.risk_money=lots*out.loss_per_lot;
   out.valid=true;
   return(true);
  }

#endif // DTF_RISKMANAGER_MQH
//+------------------------------------------------------------------+
