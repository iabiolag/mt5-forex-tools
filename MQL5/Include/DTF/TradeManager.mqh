//+------------------------------------------------------------------+
//|                                                 TradeManager.mqh |
//|       Daily Trend-Following System - execution and stop handling  |
//+------------------------------------------------------------------+
//| TRADING LOGIC
//| ------------
//| Entry is the least important decision this system makes. What
//| turns a mediocre entry into positive expectancy is the exit:
//|
//|  1) INITIAL STOP at N x ATR. Decided before the order is sent and
//|     never widened. This is the "capped, pre-planned loss" the whole
//|     approach rests on, and it defines 1R for that trade.
//|
//|  2) CHANDELIER TRAIL at N x ATR from the highest high (longs) or
//|     lowest low (shorts) made SINCE ENTRY. It hangs off the extreme
//|     of the move rather than off price, so a trend can breathe -
//|     ordinary pullbacks do not touch it, but a genuine reversal
//|     does. It only ever moves in the trade's favour. A stop that can
//|     retreat is not a stop.
//|
//|  3) SIGNAL EXIT when the ensemble that got us in flips against us.
//|     Often leaves the trade before the trail does, at a better price.
//|
//|  4) TIME STOP (optional, off by default) for trades that go nowhere.
//|     Dead capital in a trend system is a real cost: it occupies risk
//|     budget and currency exposure that a live trend could use.
//|
//| Each exit is logged by reason so phase 5 can put them on trial
//| individually and delete the ones that do not pay for themselves.
//+------------------------------------------------------------------+
#ifndef DTF_TRADEMANAGER_MQH
#define DTF_TRADEMANAGER_MQH

#include <Trade/Trade.mqh>
#include <DTF/Common.mqh>
#include <DTF/Journal.mqh>

//+------------------------------------------------------------------+
//| Everything about the open position that MT5 will not remember for |
//| us. Persisted to disk so a terminal restart does not destroy the  |
//| R-multiple of a trade that is still running.                      |
//+------------------------------------------------------------------+
struct SDtfPosState
  {
   bool              active;
   ulong             ticket;
   long              position_id;
   int               direction;         // +1 long, -1 short
   double            lots;
   double            entry_price;
   datetime          entry_time;
   datetime          entry_bar;         // bar the decision was made on
   double            init_stop;
   double            init_risk_price;   // entry-to-stop distance = 1R
   double            init_risk_money;
   double            current_stop;
   bool              trailed;           // stop has been moved at least once
   double            mfe_r;             // best unrealised R seen
   int               bars_held;
   //--- context captured at entry, for the journal
   double            signal_entry;
   double            atr_entry;
   double            atr_pct_entry;
   double            bb_pct_entry;
   ENUM_DTF_REGIME   regime_entry;
   bool              compression_entry;
   double            equity_entry;
   bool              reconstructed;
  };

//+------------------------------------------------------------------+
//| CTradeManager                                                    |
//+------------------------------------------------------------------+
class CTradeManager
  {
private:
   CTrade            m_trade;
   CJournal         *m_journal;
   string            m_symbol;
   ulong             m_magic;
   int               m_retries;
   string            m_state_file;
   SDtfPosState      m_pos;
   ENUM_DTF_EXIT_REASON m_pending_reason;   // set when WE initiate a close
   bool              m_opening;           // suppress adoption logic during Open()

   double            MinStopDistance(void) const;
   bool              IsRetryable(const uint retcode) const;
   bool              SendWithRetry(const int direction,const double lots,
                                   const double stop_price);
   void              SaveState(void);
   void              ClearState(void);
   bool              BuildRecord(SDtfTradeRecord &rec);

public:
                     CTradeManager(void);

   bool              Init(const string symbol,const ulong magic,
                          const ulong deviation_points,const int retries,
                          CJournal *journal,const string state_suffix);

   bool              HasPosition(void) const { return(m_pos.active); }
   SDtfPosState      State(void) const { return(m_pos); }

   //--- find a position this EA owns, and rebuild state after a restart
   void              Sync(void);
   bool              LoadState(void);

   //--- 1R in price terms for a proposed entry
   double            StopPriceFor(const int direction,const double price,
                                  const double stop_distance) const;
   //--- chandelier level from the extreme since entry
   double            ChandelierStop(const int direction,const int bars_since_entry,
                                    const double atr,const double multiple) const;

   bool              Open(const int direction,const double lots,const double stop_price,
                          const double signal,const double atr,const double atr_pct,
                          const double bb_pct,const ENUM_DTF_REGIME regime,
                          const bool compression,const double equity,
                          const datetime bar_time);
   bool              MoveStop(const double new_stop);
   bool              Close(const ENUM_DTF_EXIT_REASON reason);

   //--- call every bar while a position is open
   void              UpdateExcursion(const double atr_unused);
   void              OnBarHeld(void) { if(m_pos.active) m_pos.bars_held++; }

   //--- did our position disappear? if so journal it. returns true if closed.
   bool              DetectClose(const double signal_now);
  };

//+------------------------------------------------------------------+
CTradeManager::CTradeManager(void) : m_journal(NULL),m_symbol(""),m_magic(0),
                                     m_retries(3),m_state_file(""),
                                     m_pending_reason(DTF_EXIT_NONE),
                                     m_opening(false)
  {
   ZeroMemory(m_pos);
  }
//+------------------------------------------------------------------+
bool CTradeManager::Init(const string symbol,const ulong magic,
                         const ulong deviation_points,const int retries,
                         CJournal *journal,const string state_suffix)
  {
   m_symbol  = symbol;
   m_magic   = magic;
   m_journal = journal;
   m_retries = (retries<1 ? 1 : retries);
   m_state_file = "DTF_state"+(StringLen(state_suffix)>0 ? "_"+state_suffix : "")+".csv";

   m_trade.SetExpertMagicNumber(m_magic);
   m_trade.SetDeviationInPoints(deviation_points);
   m_trade.SetAsyncMode(false);
   //--- Ask the symbol which filling modes it actually supports rather
   //--- than assuming FOK - a wrong filling mode is the single most
   //--- common reason a working EA returns "Unsupported filling mode".
   m_trade.SetTypeFillingBySymbol(m_symbol);

   ZeroMemory(m_pos);
   LoadState();
   Sync();
   return(true);
  }
//+------------------------------------------------------------------+
//| Broker's minimum distance between price and a stop.               |
//+------------------------------------------------------------------+
double CTradeManager::MinStopDistance(void) const
  {
   long   level=SymbolInfoInteger(m_symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long   freeze=SymbolInfoInteger(m_symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double point=SymbolInfoDouble(m_symbol,SYMBOL_POINT);
   long   worst=(level>freeze ? level : freeze);
   return((double)worst*point);
  }
//+------------------------------------------------------------------+
//| Retcodes worth trying again: transient price/queue problems only.  |
//| Anything else (no money, invalid stops) will fail identically on a |
//| retry and should surface as an error instead of spinning.          |
//+------------------------------------------------------------------+
bool CTradeManager::IsRetryable(const uint retcode) const
  {
   return(retcode==TRADE_RETCODE_REQUOTE       ||
          retcode==TRADE_RETCODE_PRICE_CHANGED ||
          retcode==TRADE_RETCODE_PRICE_OFF     ||
          retcode==TRADE_RETCODE_TIMEOUT       ||
          retcode==TRADE_RETCODE_CONNECTION    ||
          retcode==TRADE_RETCODE_TOO_MANY_REQUESTS);
  }
//+------------------------------------------------------------------+
double CTradeManager::StopPriceFor(const int direction,const double price,
                                   const double stop_distance) const
  {
   int dg=(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS);
   double sl=(direction>0 ? price-stop_distance : price+stop_distance);
   return(NormalizeDouble(sl,dg));
  }
//+------------------------------------------------------------------+
//| Chandelier: N x ATR back from the best price the trade has seen.  |
//| bars_since_entry counts the entry bar itself, so it is never < 1. |
//+------------------------------------------------------------------+
double CTradeManager::ChandelierStop(const int direction,const int bars_since_entry,
                                     const double atr,const double multiple) const
  {
   int n=(bars_since_entry<1 ? 1 : bars_since_entry);
   int dg=(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS);

   double ext[];
   ArraySetAsSeries(ext,true);

   if(direction>0)
     {
      //--- highest high of the bars since entry, including the forming one
      if(CopyHigh(m_symbol,PERIOD_D1,0,n,ext)<n) return(0.0);
      int idx=ArrayMaximum(ext,0,n);
      if(idx<0) return(0.0);
      return(NormalizeDouble(ext[idx]-multiple*atr,dg));
     }

   if(CopyLow(m_symbol,PERIOD_D1,0,n,ext)<n) return(0.0);
   int idx=ArrayMinimum(ext,0,n);
   if(idx<0) return(0.0);
   return(NormalizeDouble(ext[idx]+multiple*atr,dg));
  }
//+------------------------------------------------------------------+
bool CTradeManager::SendWithRetry(const int direction,const double lots,
                                  const double stop_price)
  {
   for(int attempt=1;attempt<=m_retries;attempt++)
     {
      double price=(direction>0 ? SymbolInfoDouble(m_symbol,SYMBOL_ASK)
                                : SymbolInfoDouble(m_symbol,SYMBOL_BID));
      if(price<=0.0)
        {
         Print("DTF/TradeManager: no price for ",m_symbol);
         return(false);
        }

      //--- Respect the broker's stop level. If our ATR stop is closer
      //--- than allowed we push it out, never in: a stop that is too
      //--- tight to place must not become a tighter risk than planned.
      double min_dist=MinStopDistance();
      double sl=stop_price;
      if(min_dist>0.0)
        {
         if(direction>0 && price-sl<min_dist) sl=price-min_dist;
         if(direction<0 && sl-price<min_dist) sl=price+min_dist;
         sl=NormalizeDouble(sl,(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS));
        }

      bool ok=(direction>0 ? m_trade.Buy(lots,m_symbol,price,sl,0.0,"DTF")
                           : m_trade.Sell(lots,m_symbol,price,sl,0.0,"DTF"));
      uint rc=m_trade.ResultRetcode();

      if(ok && (rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_PLACED ||
                rc==TRADE_RETCODE_DONE_PARTIAL))
         return(true);

      PrintFormat("DTF/TradeManager: order attempt %d/%d failed, retcode %u (%s)",
                  attempt,m_retries,rc,m_trade.ResultRetcodeDescription());

      if(!IsRetryable(rc))
         return(false);

      Sleep(200);
     }
   return(false);
  }
//+------------------------------------------------------------------+
bool CTradeManager::Open(const int direction,const double lots,const double stop_price,
                         const double signal,const double atr,const double atr_pct,
                         const double bb_pct,const ENUM_DTF_REGIME regime,
                         const bool compression,const double equity,
                         const datetime bar_time)
  {
   if(m_pos.active)
     {
      Print("DTF/TradeManager: refusing to open, a position is already tracked");
      return(false);
     }
   if(lots<=0.0)
      return(false);

   if(!SendWithRetry(direction,lots,stop_price))
      return(false);

   //--- Read back what the broker ACTUALLY filled rather than what we
   //--- asked for: slippage and partial fills change 1R. The guard stops
   //--- Sync() mistaking our own brand-new fill for an orphan position
   //--- adopted after a restart.
   m_opening=true;
   Sync();
   m_opening=false;
   if(!m_pos.active)
     {
      Print("DTF/TradeManager: order reported success but no position found");
      return(false);
     }

   m_pos.direction         = direction;
   m_pos.entry_bar         = bar_time;
   m_pos.init_stop         = PositionGetDouble(POSITION_SL);
   if(m_pos.init_stop<=0.0) m_pos.init_stop=stop_price;
   m_pos.init_risk_price   = MathAbs(m_pos.entry_price-m_pos.init_stop);
   m_pos.current_stop      = m_pos.init_stop;
   m_pos.trailed           = false;
   m_pos.mfe_r             = 0.0;
   m_pos.bars_held         = 0;
   m_pos.signal_entry      = signal;
   m_pos.atr_entry         = atr;
   m_pos.atr_pct_entry     = atr_pct;
   m_pos.bb_pct_entry      = bb_pct;
   m_pos.regime_entry      = regime;
   m_pos.compression_entry = compression;
   m_pos.equity_entry      = equity;
   m_pos.reconstructed     = false;

   //--- 1R in money, from the fill we actually got
   double tick_size =SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_SIZE);
   double tick_value=SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tick_value<=0.0) tick_value=SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_VALUE);
   if(tick_size<=0.0)  tick_size =SymbolInfoDouble(m_symbol,SYMBOL_POINT);
   m_pos.init_risk_money=(tick_size>0.0
                          ? (m_pos.init_risk_price/tick_size)*tick_value*m_pos.lots
                          : 0.0);

   SaveState();

   PrintFormat("DTF: %s %.2f lots %s @ %s  SL %s  (1R = %.2f %s, signal %+.2f)",
               (direction>0 ? "BUY" : "SELL"),m_pos.lots,m_symbol,
               DoubleToString(m_pos.entry_price,(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS)),
               DoubleToString(m_pos.init_stop,(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS)),
               m_pos.init_risk_money,AccountInfoString(ACCOUNT_CURRENCY),signal);
   return(true);
  }
//+------------------------------------------------------------------+
//| Move the stop. Refuses any move that is not in our favour.        |
//+------------------------------------------------------------------+
bool CTradeManager::MoveStop(const double new_stop)
  {
   if(!m_pos.active || new_stop<=0.0)
      return(false);

   int    dg=(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS);
   double sl=NormalizeDouble(new_stop,dg);
   double point=SymbolInfoDouble(m_symbol,SYMBOL_POINT);

   //--- THE rule: stops ratchet one way only.
   if(m_pos.direction>0 && sl<=m_pos.current_stop+point*0.5) return(false);
   if(m_pos.direction<0 && sl>=m_pos.current_stop-point*0.5) return(false);

   //--- do not ask for something the broker will reject
   double price=(m_pos.direction>0 ? SymbolInfoDouble(m_symbol,SYMBOL_BID)
                                   : SymbolInfoDouble(m_symbol,SYMBOL_ASK));
   double min_dist=MinStopDistance();
   if(min_dist>0.0)
     {
      if(m_pos.direction>0 && price-sl<min_dist) return(false);
      if(m_pos.direction<0 && sl-price<min_dist) return(false);
     }

   if(!m_trade.PositionModify(m_pos.ticket,sl,0.0))
     {
      PrintFormat("DTF/TradeManager: PositionModify failed, retcode %u (%s)",
                  m_trade.ResultRetcode(),m_trade.ResultRetcodeDescription());
      return(false);
     }

   m_pos.current_stop=sl;
   m_pos.trailed=true;
   SaveState();
   PrintFormat("DTF: trail %s stop -> %s",m_symbol,DoubleToString(sl,dg));
   return(true);
  }
//+------------------------------------------------------------------+
bool CTradeManager::Close(const ENUM_DTF_EXIT_REASON reason)
  {
   if(!m_pos.active)
      return(false);

   //--- remember why, so DetectClose does not have to guess
   m_pending_reason=reason;

   for(int attempt=1;attempt<=m_retries;attempt++)
     {
      if(m_trade.PositionClose(m_pos.ticket))
         return(true);

      uint rc=m_trade.ResultRetcode();
      PrintFormat("DTF/TradeManager: close attempt %d/%d failed, retcode %u (%s)",
                  attempt,m_retries,rc,m_trade.ResultRetcodeDescription());
      if(!IsRetryable(rc))
         break;
      Sleep(200);
     }

   m_pending_reason=DTF_EXIT_NONE;
   return(false);
  }
//+------------------------------------------------------------------+
//| Locate a position on our symbol with our magic.                   |
//+------------------------------------------------------------------+
void CTradeManager::Sync(void)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      //--- NEVER touch a trade this EA did not open
      if(PositionGetString(POSITION_SYMBOL)!=m_symbol)      continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=m_magic) continue;

      bool was_active=m_pos.active;

      m_pos.active      = true;
      m_pos.ticket      = ticket;
      m_pos.position_id = PositionGetInteger(POSITION_IDENTIFIER);
      m_pos.lots        = PositionGetDouble(POSITION_VOLUME);
      m_pos.entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
      m_pos.entry_time  = (datetime)PositionGetInteger(POSITION_TIME);
      m_pos.direction   = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1);

      double sl=PositionGetDouble(POSITION_SL);
      if(sl>0.0)
         m_pos.current_stop=sl;

      //--- Found a live position we had no record of: a restart, or the
      //--- state file was lost. Rebuild what we can and MARK it, so the
      //--- journal never presents a guessed 1R as a measured one.
      if(!was_active && !m_opening && m_pos.init_risk_price<=0.0)
        {
         m_pos.init_stop       = (sl>0.0 ? sl : 0.0);
         m_pos.init_risk_price = (sl>0.0 ? MathAbs(m_pos.entry_price-sl) : 0.0);
         m_pos.reconstructed   = true;
         m_pos.entry_bar       = m_pos.entry_time;
         PrintFormat("DTF/TradeManager: adopted existing position %I64u, "
                     "state reconstructed (R-multiple will be approximate)",ticket);
        }
      return;
     }

   //--- nothing found; DetectClose decides whether that is news
   if(m_pos.active)
      m_pos.active=false;
  }
//+------------------------------------------------------------------+
//| Assemble the closed trade from MT5's own deal history.            |
//+------------------------------------------------------------------+
bool CTradeManager::BuildRecord(SDtfTradeRecord &rec)
  {
   long pid=(m_pos.position_id!=0 ? m_pos.position_id : (long)m_pos.ticket);
   if(!HistorySelectByPosition(pid))
     {
      PrintFormat("DTF/TradeManager: no history for position %I64d",pid);
      return(false);
     }

   double gross=0.0,swap=0.0,comm=0.0;
   double exit_price=0.0;
   datetime exit_time=0;
   ENUM_DEAL_REASON close_reason=DEAL_REASON_CLIENT;
   bool found_exit=false;

   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
     {
      ulong d=HistoryDealGetTicket(i);
      if(d==0) continue;

      gross+=HistoryDealGetDouble(d,DEAL_PROFIT);
      swap +=HistoryDealGetDouble(d,DEAL_SWAP);
      comm +=HistoryDealGetDouble(d,DEAL_COMMISSION);

      long entry=HistoryDealGetInteger(d,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
        {
         exit_price  =HistoryDealGetDouble(d,DEAL_PRICE);
         exit_time   =(datetime)HistoryDealGetInteger(d,DEAL_TIME);
         close_reason=(ENUM_DEAL_REASON)HistoryDealGetInteger(d,DEAL_REASON);
         found_exit  =true;
        }
     }
   if(!found_exit)
      return(false);

   //--- Prefer the reason we set ourselves; fall back to what the
   //--- server says. A stop fill is only an "initial stop" loss if we
   //--- never moved it - otherwise the trail is what took us out, and
   //--- those two need separating to judge the trail honestly.
   ENUM_DTF_EXIT_REASON reason=m_pending_reason;
   if(reason==DTF_EXIT_NONE)
     {
      if(close_reason==DEAL_REASON_SL)
         reason=(m_pos.trailed ? DTF_EXIT_TRAIL : DTF_EXIT_STOP);
      else if(close_reason==DEAL_REASON_CLIENT || close_reason==DEAL_REASON_MOBILE ||
              close_reason==DEAL_REASON_WEB)
         reason=DTF_EXIT_MANUAL;
      else
         reason=DTF_EXIT_OTHER;
     }

   rec.symbol            = m_symbol;
   rec.direction         = m_pos.direction;
   rec.ticket            = m_pos.ticket;
   rec.entry_time        = m_pos.entry_time;
   rec.entry_price       = m_pos.entry_price;
   rec.exit_time         = exit_time;
   rec.exit_price        = exit_price;
   rec.lots              = m_pos.lots;
   rec.init_stop         = m_pos.init_stop;
   rec.init_risk_price   = m_pos.init_risk_price;
   rec.init_risk_money   = m_pos.init_risk_money;
   rec.gross_profit      = gross;
   rec.swap              = swap;
   rec.commission        = comm;
   rec.net_profit        = gross+swap+comm;
   //--- R is measured against money actually at risk, including costs,
   //--- because that is what the account felt.
   rec.r_multiple        = (m_pos.init_risk_money>0.0
                            ? rec.net_profit/m_pos.init_risk_money : 0.0);
   rec.mfe_r             = m_pos.mfe_r;
   rec.bars_held         = m_pos.bars_held;
   rec.signal_entry      = m_pos.signal_entry;
   rec.atr_entry         = m_pos.atr_entry;
   rec.atr_pct_entry     = m_pos.atr_pct_entry;
   rec.bb_pct_entry      = m_pos.bb_pct_entry;
   rec.regime_entry      = m_pos.regime_entry;
   rec.compression_entry = m_pos.compression_entry;
   rec.vol_flag          = -1.0;          // phase 4
   rec.equity_entry      = m_pos.equity_entry;
   rec.exit_reason       = reason;
   rec.reconstructed     = m_pos.reconstructed;
   rec.notes             = "";
   return(true);
  }
//+------------------------------------------------------------------+
//| Track the best unrealised R the trade reaches. Needed for the     |
//| time stop, and it is the only way to tell "never worked" from     |
//| "worked then gave it back" when reviewing losers.                 |
//+------------------------------------------------------------------+
void CTradeManager::UpdateExcursion(const double atr_unused)
  {
   if(!m_pos.active || m_pos.init_risk_price<=0.0)
      return;

   double price=(m_pos.direction>0 ? SymbolInfoDouble(m_symbol,SYMBOL_BID)
                                   : SymbolInfoDouble(m_symbol,SYMBOL_ASK));
   if(price<=0.0)
      return;

   double move=(price-m_pos.entry_price)*m_pos.direction;
   double r=move/m_pos.init_risk_price;
   if(r>m_pos.mfe_r)
      m_pos.mfe_r=r;
  }
//+------------------------------------------------------------------+
//| Returns true if the position we were tracking has gone.           |
//+------------------------------------------------------------------+
bool CTradeManager::DetectClose(const double signal_now)
  {
   if(!m_pos.active)
      return(false);

   ulong  tracked=m_pos.ticket;
   double keep_stop=m_pos.current_stop;
   Sync();

   if(m_pos.active && m_pos.ticket==tracked)
     {
      m_pos.current_stop=keep_stop;
      return(false);
     }

   //--- it is gone: write it up
   SDtfTradeRecord rec;
   ZeroMemory(rec);
   if(BuildRecord(rec))
     {
      rec.signal_exit=signal_now;
      if(m_journal!=NULL)
         m_journal.LogTrade(rec);
      PrintFormat("DTF: closed %s %s  R = %+.2f  (%s)",
                  m_symbol,(rec.direction>0 ? "LONG" : "SHORT"),
                  rec.r_multiple,DTF_ExitReasonToString(rec.exit_reason));
     }

   ZeroMemory(m_pos);
   m_pending_reason=DTF_EXIT_NONE;
   ClearState();
   return(true);
  }
//+------------------------------------------------------------------+
//| State persistence. One line; rewritten whenever anything moves.   |
//+------------------------------------------------------------------+
void CTradeManager::SaveState(void)
  {
   int h=FileOpen(m_state_file,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE)
      return;

   string line=
      IntegerToString((long)m_pos.ticket)+","+
      IntegerToString(m_pos.position_id)+","+
      IntegerToString(m_pos.direction)+","+
      DoubleToString(m_pos.lots,2)+","+
      DoubleToString(m_pos.entry_price,8)+","+
      IntegerToString((long)m_pos.entry_time)+","+
      IntegerToString((long)m_pos.entry_bar)+","+
      DoubleToString(m_pos.init_stop,8)+","+
      DoubleToString(m_pos.init_risk_price,8)+","+
      DoubleToString(m_pos.init_risk_money,4)+","+
      DoubleToString(m_pos.current_stop,8)+","+
      (m_pos.trailed ? "1" : "0")+","+
      DoubleToString(m_pos.mfe_r,6)+","+
      IntegerToString(m_pos.bars_held)+","+
      DoubleToString(m_pos.signal_entry,6)+","+
      DoubleToString(m_pos.atr_entry,8)+","+
      DoubleToString(m_pos.atr_pct_entry,2)+","+
      DoubleToString(m_pos.bb_pct_entry,2)+","+
      IntegerToString((int)m_pos.regime_entry)+","+
      (m_pos.compression_entry ? "1" : "0")+","+
      DoubleToString(m_pos.equity_entry,2);

   FileWriteString(h,line);
   FileClose(h);
  }
//+------------------------------------------------------------------+
bool CTradeManager::LoadState(void)
  {
   if(!FileIsExist(m_state_file))
      return(false);

   int h=FileOpen(m_state_file,FILE_READ|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE)
      return(false);

   string line=FileReadString(h);
   FileClose(h);

   string f[];
   if(StringSplit(line,',',f)<21)
      return(false);

   m_pos.ticket            = (ulong)StringToInteger(f[0]);
   m_pos.position_id       = StringToInteger(f[1]);
   m_pos.direction         = (int)StringToInteger(f[2]);
   m_pos.lots              = StringToDouble(f[3]);
   m_pos.entry_price       = StringToDouble(f[4]);
   m_pos.entry_time        = (datetime)StringToInteger(f[5]);
   m_pos.entry_bar         = (datetime)StringToInteger(f[6]);
   m_pos.init_stop         = StringToDouble(f[7]);
   m_pos.init_risk_price   = StringToDouble(f[8]);
   m_pos.init_risk_money   = StringToDouble(f[9]);
   m_pos.current_stop      = StringToDouble(f[10]);
   m_pos.trailed           = (f[11]=="1");
   m_pos.mfe_r             = StringToDouble(f[12]);
   m_pos.bars_held         = (int)StringToInteger(f[13]);
   m_pos.signal_entry      = StringToDouble(f[14]);
   m_pos.atr_entry         = StringToDouble(f[15]);
   m_pos.atr_pct_entry     = StringToDouble(f[16]);
   m_pos.bb_pct_entry      = StringToDouble(f[17]);
   m_pos.regime_entry      = (ENUM_DTF_REGIME)StringToInteger(f[18]);
   m_pos.compression_entry = (f[19]=="1");
   m_pos.equity_entry      = StringToDouble(f[20]);
   return(true);
  }
//+------------------------------------------------------------------+
void CTradeManager::ClearState(void)
  {
   if(FileIsExist(m_state_file))
      FileDelete(m_state_file);
  }

#endif // DTF_TRADEMANAGER_MQH
//+------------------------------------------------------------------+
