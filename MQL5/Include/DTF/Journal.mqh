//+------------------------------------------------------------------+
//|                                                      Journal.mqh |
//|          Daily Trend-Following System - CSV trade/skip journal    |
//+------------------------------------------------------------------+
//| WHY THIS EXISTS
//| ---------------
//| The Strategy Tester report tells you what happened. It does not
//| tell you WHY, and it throws away everything the system knew at the
//| moment it decided. Without that context you cannot answer the only
//| questions that matter for this project:
//|
//|   - is the trailing stop earning its keep, or cutting winners?
//|   - do entries in EXTREME volatility lose money as a group?
//|   - does compression-breakout actually beat mid-range entry?
//|   - what would expectancy be if I removed component X?
//|
//| So every trade is written with the full state at entry (signal
//| strength, ATR percentile, BB percentile, regime) and the exit
//| reason, in R-multiples. Every SKIPPED signal is written too, with
//| the reason - a filter that never fires is dead weight, and a
//| filter that blocks the best trades needs to be found and killed.
//|
//| Two files, both CSV in the Common Files folder so one analyser can
//| read runs from several terminals:
//|   DTF_trades_<suffix>.csv
//|   DTF_skips_<suffix>.csv
//+------------------------------------------------------------------+
#ifndef DTF_JOURNAL_MQH
#define DTF_JOURNAL_MQH

#include <DTF/Common.mqh>

//+------------------------------------------------------------------+
//| One completed trade, as the analyser will read it.                |
//+------------------------------------------------------------------+
struct SDtfTradeRecord
  {
   string            symbol;
   int               direction;        // +1 long, -1 short
   ulong             ticket;
   datetime          entry_time;
   double            entry_price;
   datetime          exit_time;
   double            exit_price;
   double            lots;
   double            init_stop;        // the stop we entered with
   double            init_risk_price;  // entry-to-stop distance
   double            init_risk_money;  // what that distance was worth
   double            gross_profit;
   double            swap;
   double            commission;
   double            net_profit;       // gross + swap + commission
   double            r_multiple;       // net_profit / init_risk_money
   double            mfe_r;            // best unrealised R the trade saw
   int               bars_held;
   double            signal_entry;
   double            signal_exit;
   double            atr_entry;
   double            atr_pct_entry;
   double            bb_pct_entry;
   ENUM_DTF_REGIME   regime_entry;
   bool              compression_entry;
   double            vol_flag;         // tick-volume ratio, phase 4 (-1 = off)
   double            equity_entry;
   ENUM_DTF_EXIT_REASON exit_reason;
   bool              reconstructed;    // state rebuilt after a restart
   string            notes;
  };

//+------------------------------------------------------------------+
//| CJournal                                                          |
//+------------------------------------------------------------------+
class CJournal
  {
private:
   string            m_trade_file;
   string            m_skip_file;
   bool              m_enabled;
   bool              m_common;
   bool              m_echo;           // also Print() each row
   string            m_run_id;         // separates runs inside one file

   int               Flags(void) const;
   bool              Append(const string file,const string header,const string line);
   string            Q(const string s) const;   // CSV-quote a free-text field

public:
                     CJournal(void);
   bool              Init(const string suffix,const bool common,
                          const bool enabled,const bool echo,const bool fresh);
   bool              IsEnabled(void) const { return(m_enabled); }
   string            TradeFile(void) const { return(m_trade_file); }
   string            SkipFile(void)  const { return(m_skip_file);  }

   void              LogTrade(const SDtfTradeRecord &r);
   void              LogSkip(const string symbol,const datetime bar_time,
                             const double signal,const double atr_pct,
                             const double bb_pct,const ENUM_DTF_REGIME regime,
                             const string reason);
  };

//+------------------------------------------------------------------+
CJournal::CJournal(void) : m_trade_file(""),m_skip_file(""),
                           m_enabled(false),m_common(true),m_echo(false),
                           m_run_id("")
  {
  }
//+------------------------------------------------------------------+
int CJournal::Flags(void) const
  {
   int f=FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE;
   if(m_common) f|=FILE_COMMON;
   return(f);
  }
//+------------------------------------------------------------------+
//| Wrap a free-text field so a comma in a reason cannot shift every   |
//| later column by one - the classic way a journal silently rots.     |
//+------------------------------------------------------------------+
string CJournal::Q(const string s) const
  {
   string out=s;
   StringReplace(out,"\"","'");
   return("\""+out+"\"");
  }
//+------------------------------------------------------------------+
bool CJournal::Init(const string suffix,const bool common,
                    const bool enabled,const bool echo,const bool fresh)
  {
   m_enabled = enabled;
   m_common  = common;
   m_echo    = echo;
   //--- Stamps every row so two runs in one file stay separable. The
   //--- journal appends, and without this a second backtest silently
   //--- doubles the first and every statistic drawn from it is wrong.
   m_run_id  = TimeToString(TimeLocal(),TIME_DATE|TIME_MINUTES|TIME_SECONDS);
   StringReplace(m_run_id,".","");
   StringReplace(m_run_id,":","");
   StringReplace(m_run_id," ","-");
   //--- TimeLocal() is SIMULATED time inside the tester, so two runs of
   //--- the same date range would otherwise share a run_id.
   m_run_id+="-"+IntegerToString((int)(GetTickCount()%100000));

   string tag=(StringLen(suffix)>0 ? "_"+suffix : "");
   m_trade_file = "DTF_trades"+tag+".csv";
   m_skip_file  = "DTF_skips"+tag+".csv";

   if(!m_enabled)
      return(true);

   //--- A backtest is a clean-slate experiment, so start from empty
   //--- unless told otherwise. Live trading always appends.
   if(fresh)
     {
      if(FileIsExist(m_trade_file,m_common ? FILE_COMMON : 0))
         FileDelete(m_trade_file,m_common ? FILE_COMMON : 0);
      if(FileIsExist(m_skip_file,m_common ? FILE_COMMON : 0))
         FileDelete(m_skip_file,m_common ? FILE_COMMON : 0);
     }

   //--- Prove we can write NOW rather than discovering at the end of a
   //--- six-hour backtest that every row went nowhere.
   int h=FileOpen(m_trade_file,Flags());
   if(h==INVALID_HANDLE)
     {
      PrintFormat("DTF/Journal: cannot open %s (error %d). Journalling disabled.",
                  m_trade_file,GetLastError());
      m_enabled=false;
      return(false);
     }
   FileClose(h);

   //--- Create the skip file up front too. A run with nothing skipped
   //--- would otherwise leave no file at all, which is indistinguishable
   //--- from a run that never happened.
   int hs=FileOpen(m_skip_file,Flags());
   if(hs!=INVALID_HANDLE)
     {
      if(FileSize(hs)==0)
         FileWriteString(hs,"run_id,symbol,bar_time,signal,atr_pct,bb_pct,regime,reason\r\n");
      FileClose(hs);
     }

   PrintFormat("DTF/Journal: %s and %s in %s",
               m_trade_file,m_skip_file,
               (m_common ? "Common Files" : "terminal Files"));
   return(true);
  }
//+------------------------------------------------------------------+
//| Append one line, writing the header first if the file is new.     |
//+------------------------------------------------------------------+
bool CJournal::Append(const string file,const string header,const string line)
  {
   if(!m_enabled)
      return(false);

   int h=FileOpen(file,Flags());
   if(h==INVALID_HANDLE)
     {
      PrintFormat("DTF/Journal: FileOpen(%s) failed, error %d",file,GetLastError());
      return(false);
     }

   if(FileSize(h)==0)
      FileWriteString(h,header+"\r\n");

   FileSeek(h,0,SEEK_END);
   FileWriteString(h,line+"\r\n");
   FileClose(h);

   if(m_echo)
      Print("DTF/Journal: ",line);
   return(true);
  }
//+------------------------------------------------------------------+
void CJournal::LogTrade(const SDtfTradeRecord &r)
  {
   if(!m_enabled)
      return;

   const string header=
      "run_id,symbol,direction,ticket,entry_time,entry_price,exit_time,exit_price,lots,"
      "init_stop,init_risk_price,init_risk_money,gross_profit,swap,commission,"
      "net_profit,r_multiple,mfe_r,bars_held,signal_entry,signal_exit,atr_entry,"
      "atr_pct_entry,bb_pct_entry,regime_entry,compression_entry,vol_flag,"
      "equity_entry,exit_reason,reconstructed,notes";

   int dg=(int)SymbolInfoInteger(r.symbol,SYMBOL_DIGITS);
   if(dg<=0) dg=5;

   string line=
      m_run_id+","+
      r.symbol+","+
      IntegerToString(r.direction)+","+
      IntegerToString((long)r.ticket)+","+
      TimeToString(r.entry_time,TIME_DATE|TIME_MINUTES)+","+
      DoubleToString(r.entry_price,dg)+","+
      TimeToString(r.exit_time,TIME_DATE|TIME_MINUTES)+","+
      DoubleToString(r.exit_price,dg)+","+
      DoubleToString(r.lots,2)+","+
      DoubleToString(r.init_stop,dg)+","+
      DoubleToString(r.init_risk_price,dg)+","+
      DoubleToString(r.init_risk_money,2)+","+
      DoubleToString(r.gross_profit,2)+","+
      DoubleToString(r.swap,2)+","+
      DoubleToString(r.commission,2)+","+
      DoubleToString(r.net_profit,2)+","+
      DoubleToString(r.r_multiple,4)+","+
      DoubleToString(r.mfe_r,4)+","+
      IntegerToString(r.bars_held)+","+
      DoubleToString(r.signal_entry,4)+","+
      DoubleToString(r.signal_exit,4)+","+
      DoubleToString(r.atr_entry,dg)+","+
      DoubleToString(r.atr_pct_entry,1)+","+
      DoubleToString(r.bb_pct_entry,1)+","+
      DTF_RegimeToString(r.regime_entry)+","+
      (r.compression_entry ? "1" : "0")+","+
      DoubleToString(r.vol_flag,3)+","+
      DoubleToString(r.equity_entry,2)+","+
      DTF_ExitReasonToString(r.exit_reason)+","+
      (r.reconstructed ? "1" : "0")+","+
      Q(r.notes);

   Append(m_trade_file,header,line);
  }
//+------------------------------------------------------------------+
//| A signal we did NOT take, and why. Just as important as the       |
//| trades: this is the record that lets a filter be put on trial.    |
//+------------------------------------------------------------------+
void CJournal::LogSkip(const string symbol,const datetime bar_time,
                       const double signal,const double atr_pct,
                       const double bb_pct,const ENUM_DTF_REGIME regime,
                       const string reason)
  {
   if(!m_enabled)
      return;

   const string header=
      "run_id,symbol,bar_time,signal,atr_pct,bb_pct,regime,reason";

   string line=
      m_run_id+","+
      symbol+","+
      TimeToString(bar_time,TIME_DATE|TIME_MINUTES)+","+
      DoubleToString(signal,4)+","+
      DoubleToString(atr_pct,1)+","+
      DoubleToString(bb_pct,1)+","+
      DTF_RegimeToString(regime)+","+
      Q(reason);

   Append(m_skip_file,header,line);
  }

#endif // DTF_JOURNAL_MQH
//+------------------------------------------------------------------+
