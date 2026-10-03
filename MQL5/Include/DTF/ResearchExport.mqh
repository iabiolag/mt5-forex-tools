//+------------------------------------------------------------------+
//|                                               ResearchExport.mqh |
//|   Daily Trend-Following System - per-bar signal / forward returns |
//+------------------------------------------------------------------+
//| Shared by the research scripts so the export logic exists once.
//|
//| For EVERY daily bar it records what the signal said and what price
//| did next. No entries, no stops, no exits - the point is to test the
//| signal on its own, on every bar, rather than on the handful of
//| trades a threshold happened to let through.
//|
//| Forward returns are in ATR units so instruments are comparable
//| (gold, BTC and EURJPY live on wildly different scales). The system
//| risks 3xATR, so 3 ATR of favourable move = 1R.
//|
//| The column that matters is fwd_N_dir: the forward move signed by
//| the signal's direction. That is what a trade in the signalled
//| direction would have earned before costs.
//+------------------------------------------------------------------+
#ifndef DTF_RESEARCHEXPORT_MQH
#define DTF_RESEARCHEXPORT_MQH

#include <DTF/Common.mqh>
#include <DTF/SignalEngine.mqh>
#include <DTF/VolatilityRegime.mqh>

#define DTF_HZ_COUNT 6
#define DTF_LB_COUNT 4

//+------------------------------------------------------------------+
//| Signal settings for the export. These MUST mirror the EA, or the  |
//| research says nothing about the system actually being traded.     |
//+------------------------------------------------------------------+
struct SDtfResearchCfg
  {
   int                  fast,mid,slow;
   ENUM_DTF_SIGNAL_MODE mode;
   double               k;
   int                  atr_period,bb_period;
   double               bb_dev;
   int                  pct_bars;
   double               compress_pct,expand_pct,extreme_pct;
  };

//+------------------------------------------------------------------+
void DtfResearchDefaults(SDtfResearchCfg &c)
  {
   c.fast=20; c.mid=60; c.slow=120;
   c.mode=DTF_SIGNAL_BOTH;
   c.k=2.0;
   c.atr_period=20; c.bb_period=20; c.bb_dev=2.0;
   c.pct_bars=250;
   c.compress_pct=20.0; c.expand_pct=80.0; c.extreme_pct=90.0;
  }
//+------------------------------------------------------------------+
int DtfExportOne(const string sym,const int handle,const SDtfResearchCfg &cfg)
  {
   int horizons[DTF_HZ_COUNT];
   horizons[0]=1; horizons[1]=5; horizons[2]=10;
   horizons[3]=20; horizons[4]=40; horizons[5]=60;
   int lookbacks[DTF_LB_COUNT];
   lookbacks[0]=20; lookbacks[1]=60; lookbacks[2]=120; lookbacks[3]=250;

   CSignalEngine     sig;
   CVolatilityRegime vol;

   if(!sig.Init(sym,PERIOD_D1,cfg.fast,cfg.mid,cfg.slow,cfg.mode,cfg.atr_period,cfg.k))
      return(0);
   if(!vol.Init(sym,PERIOD_D1,cfg.atr_period,cfg.bb_period,cfg.bb_dev,cfg.pct_bars,
                cfg.compress_pct,cfg.expand_pct,cfg.extreme_pct,0.5))
     { sig.Release(); return(0); }

   int minbars=MathMax(sig.MinBars(),vol.MinBars());
   int maxhz  =horizons[DTF_HZ_COUNT-1];
   int maxlb  =lookbacks[DTF_LB_COUNT-1];
   int bars   =Bars(sym,PERIOD_D1);
   int count  =bars-minbars-2;

   if(count<50)
     {
      PrintFormat("  %-10s only %d D1 bars (need %d) - SKIPPED, history not downloaded",
                  sym,bars,minbars+52);
      sig.Release(); vol.Release();
      return(0);
     }

   double s[],cf[],cm[],cs[];
   if(sig.Calculate(count,s,cf,cm,cs)<count)
     {
      PrintFormat("  %-10s signal calculate failed",sym);
      sig.Release(); vol.Release();
      return(0);
     }

   double atr[],atrpct[],bbw[],bbpct[];
   if(vol.Calculate(count,atr,atrpct,bbw,bbpct)<count)
     {
      PrintFormat("  %-10s volatility calculate failed",sym);
      sig.Release(); vol.Release();
      return(0);
     }

   double   close[];
   datetime time[];
   ArraySetAsSeries(close,true);
   ArraySetAsSeries(time,true);
   if(CopyClose(sym,PERIOD_D1,0,count,close)<count ||
      CopyTime(sym,PERIOD_D1,0,count,time)<count)
     {
      PrintFormat("  %-10s price copy failed",sym);
      sig.Release(); vol.Release();
      return(0);
     }

   int written=0;

   //--- i is a SHIFT (0 = newest), so a forward return at horizon h
   //--- lives at i-h. Start at maxhz to keep that index valid.
   for(int i=maxhz;i<count-maxlb-1;i++)
     {
      if(atr[i]<=0.0 || atrpct[i]<0.0 || bbpct[i]<0.0)
         continue;                       // still inside percentile warm-up

      MqlDateTime dt;
      TimeToStruct(time[i],dt);
      int dir=(s[i]>0.0 ? 1 : (s[i]<0.0 ? -1 : 0));

      string line=
         sym+","+
         TimeToString(time[i],TIME_DATE)+","+
         IntegerToString(dt.year)+","+
         IntegerToString(dt.day_of_week)+","+
         DoubleToString(s[i],5)+","+
         DoubleToString(cf[i],5)+","+
         DoubleToString(cm[i],5)+","+
         DoubleToString(cs[i],5)+","+
         DoubleToString(atrpct[i],2)+","+
         DoubleToString(bbpct[i],2)+","+
         DTF_RegimeToString(DTF_RegimeFromPercentile(atrpct[i],cfg.extreme_pct))+","+
         (bbpct[i]<cfg.compress_pct ? "1" : "0");

      for(int h=0;h<DTF_HZ_COUNT;h++)
        {
         double raw=(close[i-horizons[h]]-close[i])/atr[i];
         line+=","+DoubleToString(raw,5)+","+DoubleToString(raw*dir,5);
        }
      //--- past return over each lookback, same ATR units
      for(int b=0;b<DTF_LB_COUNT;b++)
         line+=","+DoubleToString((close[i]-close[i+lookbacks[b]])/atr[i],5);

      FileWriteString(handle,line+"\r\n");
      written++;
     }

   sig.Release();
   vol.Release();
   PrintFormat("  %-10s %d bars exported",sym,written);
   return(written);
  }
//+------------------------------------------------------------------+
//| Export a comma-separated list of base symbols to one CSV in the   |
//| Common Files folder. Returns total rows written.                  |
//+------------------------------------------------------------------+
int DtfExportResearch(const string symbols,const string prefix,const string suffix,
                      const string outfile,const SDtfResearchCfg &cfg)
  {
   int horizons[DTF_HZ_COUNT];
   horizons[0]=1; horizons[1]=5; horizons[2]=10;
   horizons[3]=20; horizons[4]=40; horizons[5]=60;
   int lookbacks[DTF_LB_COUNT];
   lookbacks[0]=20; lookbacks[1]=60; lookbacks[2]=120; lookbacks[3]=250;

   int h=FileOpen(outfile,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h==INVALID_HANDLE)
     {
      PrintFormat("cannot create %s in Common Files (error %d)",outfile,GetLastError());
      return(0);
     }

   string header="symbol,date,year,dow,signal,comp_fast,comp_mid,comp_slow,"
                 "atr_pct,bb_pct,regime,compression";
   for(int i=0;i<DTF_HZ_COUNT;i++)
     {
      string n=IntegerToString(horizons[i]);
      header+=",fwd_"+n+",fwd_"+n+"_dir";
     }
   //--- raw PAST returns let the analysis test any lookback x holding
   //--- combination offline, instead of needing a new export per idea.
   for(int i=0;i<DTF_LB_COUNT;i++)
      header+=",past_"+IntegerToString(lookbacks[i]);
   FileWriteString(h,header+"\r\n");

   string parts[];
   int n=StringSplit(symbols,',',parts);
   int total=0;

   for(int i=0;i<n;i++)
     {
      string base=parts[i];
      StringTrimLeft(base);
      StringTrimRight(base);
      if(StringLen(base)==0)
         continue;

      string sym=DTF_ResolveSymbol(base,prefix,suffix);
      if(StringLen(sym)==0)
         sym=DTF_ResolveSymbol(base,"","");
      if(StringLen(sym)==0)
        {
         PrintFormat("  %-10s NOT AVAILABLE on this server",base);
         continue;
        }
      total+=DtfExportOne(sym,h,cfg);
     }

   FileClose(h);
   PrintFormat("=== done: %d rows -> Common Files\\%s ===",total,outfile);
   return(total);
  }

#endif // DTF_RESEARCHEXPORT_MQH
//+------------------------------------------------------------------+
