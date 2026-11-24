//+------------------------------------------------------------------+
//| QUANT FLIPPER - trend confirmation + controlled stacking EA     |
//| Independent implementation based on visible video behavior.     |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#property description "QUANT FLIPPER: trend confirmation, optional hedge probe, trailing profit and pyramiding."
#include <Trade/Trade.mqh>
CTrade trade;

input bool InpEnableTrading=false;
input ulong InpMagic=25112501;
input ENUM_TIMEFRAMES InpTimeframe=PERIOD_M1;
input double InpFixedLot=0.01;
input bool InpUseRiskLot=false;
input double InpRiskPercent=0.50;
input int InpFastEMA=9;
input int InpSlowEMA=21;
input int InpTrendEMA=50;
input int InpADXPeriod=14;
input double InpMinADX=18.0;
input int InpATRPeriod=14;
input double InpInitialSL_ATR=1.60;
input double InpInitialTP_ATR=2.40;
input double InpTrailStart_ATR=0.80;
input double InpTrailDistance_ATR=0.65;
input double InpTrailStepPoints=30;
input bool InpUseHedgeProbe=true;
input double InpHedgeLotMultiplier=0.50;
input double InpHedgeMaxSpreadPoints=80;
input int InpMaxPositions=6;
input int InpMaxAddsPerTrend=4;
input double InpAddEveryATR=0.75;
input int InpEntryCooldownSeconds=20;
input double InpMaxSpreadPoints=80;
input double InpMaxDailyLossPct=3.0;
input bool InpCloseOppositeOnTrend=true;

int hFast=INVALID_HANDLE,hSlow=INVALID_HANDLE,hTrend=INVALID_HANDLE,hADX=INVALID_HANDLE,hATR=INVALID_HANDLE;
datetime lastBar=0,lastEntryTime=0;
int trendAdds=0,lastTrend=0;
double lastAddPrice=0,dayStartEquity=0;
int dayOfYear=-1;

bool IsHedgingAccount(){return AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;}

bool ReadValue(int handle,int buffer,int shift,double &value){
 double a[]; ArraySetAsSeries(a,true);
 if(handle==INVALID_HANDLE || CopyBuffer(handle,buffer,shift,1,a)!=1) return false;
 value=a[0]; return true;
}

bool ReadTrend(int &direction,double &adx,double &atr,double &fast,double &slow,double &trend){
 double f1,f2,s1,s2,t1;
 if(!ReadValue(hFast,0,1,f1)||!ReadValue(hFast,0,2,f2)||
    !ReadValue(hSlow,0,1,s1)||!ReadValue(hSlow,0,2,s2)||
    !ReadValue(hTrend,0,1,t1)||!ReadValue(hADX,0,1,adx)||!ReadValue(hATR,0,1,atr)) return false;
 fast=f1; slow=s1; trend=t1;
 double c=iClose(_Symbol,InpTimeframe,1);
 bool up=(f1>s1 && s1>t1 && f1>f2 && s1>=s2 && c>f1);
 bool dn=(f1<s1 && s1<t1 && f1<f2 && s1<=s2 && c<f1);
 direction=0;
 if(adx>=InpMinADX){if(up)direction=1;else if(dn)direction=-1;}
 return true;
}

int CountPositions(int side=0){
 int n=0;
 for(int i=PositionsTotal()-1;i>=0;i--){
  ulong ticket=PositionGetTicket(i); if(ticket==0)continue;
  if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
  long type=PositionGetInteger(POSITION_TYPE);
  if(side==0||(side==1&&type==POSITION_TYPE_BUY)||(side==-1&&type==POSITION_TYPE_SELL))n++;
 }
 return n;
}

double NormalizeLot(double lot){
 double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
 lot=MathMax(mn,MathMin(mx,lot)); lot=MathFloor(lot/st)*st; return NormalizeDouble(lot,2);
}

double GetLot(double slDistance){
 if(!InpUseRiskLot||slDistance<=0)return NormalizeLot(InpFixedLot);
 double risk=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercent/100.0;
 double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
 if(tv<=0||ts<=0)return NormalizeLot(InpFixedLot);
 double loss=(slDistance/ts)*tv; if(loss<=0)return NormalizeLot(InpFixedLot);
 return NormalizeLot(risk/loss);
}

bool SpreadOK(double maxp){
 double a=SymbolInfoDouble(_Symbol,SYMBOL_ASK),b=SymbolInfoDouble(_Symbol,SYMBOL_BID);
 return (a-b)/_Point<=maxp;
}

bool DailyLossOK(){
 MqlDateTime tm;TimeToStruct(TimeCurrent(),tm);
 if(tm.day_of_year!=dayOfYear){dayOfYear=tm.day_of_year;dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);}
 if(dayStartEquity<=0)return true;
 return (dayStartEquity-AccountInfoDouble(ACCOUNT_EQUITY))/dayStartEquity*100.0<InpMaxDailyLossPct;
}

void CloseSide(int side){
 for(int i=PositionsTotal()-1;i>=0;i--){
  ulong ticket=PositionGetTicket(i);if(ticket==0)continue;
  if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
  long type=PositionGetInteger(POSITION_TYPE);
  if((side==1&&type==POSITION_TYPE_SELL)||(side==-1&&type==POSITION_TYPE_BUY))trade.PositionClose(ticket);
 }
}

void ManageTrailing(double atr){
 if(atr<=0)return;
 double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
 int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
 for(int i=PositionsTotal()-1;i>=0;i--){
  ulong ticket=PositionGetTicket(i);if(ticket==0)continue;
  if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
  long type=PositionGetInteger(POSITION_TYPE);
  double op=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP);
  double px=(type==POSITION_TYPE_BUY?bid:ask);
  double gain=(type==POSITION_TYPE_BUY?px-op:op-px);
  if(gain<atr*InpTrailStart_ATR)continue;
  double ns=(type==POSITION_TYPE_BUY?px-atr*InpTrailDistance_ATR:px+atr*InpTrailDistance_ATR);
  ns=NormalizeDouble(ns,dg);
  bool better=(type==POSITION_TYPE_BUY?(sl==0||ns>sl+InpTrailStepPoints*_Point):(sl==0||ns<sl-InpTrailStepPoints*_Point));
  if(better)trade.PositionModify(ticket,ns,tp);
 }
}

bool OpenTrade(int dir,double lot,double atr,string note){
 if(atr<=0||!SpreadOK(InpMaxSpreadPoints)||!DailyLossOK())return false;
 double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
 double px=(dir==1?ask:bid);
 int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
 double sl=NormalizeDouble(dir==1?px-atr*InpInitialSL_ATR:px+atr*InpInitialSL_ATR,dg);
 double tp=NormalizeDouble(dir==1?px+atr*InpInitialTP_ATR:px-atr*InpInitialTP_ATR,dg);
 trade.SetExpertMagicNumber(InpMagic);trade.SetDeviationInPoints(20);
 bool ok=(dir==1?trade.Buy(lot,_Symbol,0,sl,tp,note):trade.Sell(lot,_Symbol,0,sl,tp,note));
 if(ok){lastEntryTime=TimeCurrent();lastAddPrice=px;}
 return ok;
}

void HedgeProbe(double atr){
 if(!InpUseHedgeProbe||!IsHedgingAccount()||CountPositions()!=0||!SpreadOK(InpHedgeMaxSpreadPoints))return;
 double lot=NormalizeLot(InpFixedLot*InpHedgeLotMultiplier);
 // Small two-sided probe only while the market direction is not confirmed.
 OpenTrade(1,lot,atr,"QF hedge probe BUY");
 OpenTrade(-1,lot,atr,"QF hedge probe SELL");
}

int OnInit(){
 hFast=iMA(_Symbol,InpTimeframe,InpFastEMA,0,MODE_EMA,PRICE_CLOSE);
 hSlow=iMA(_Symbol,InpTimeframe,InpSlowEMA,0,MODE_EMA,PRICE_CLOSE);
 hTrend=iMA(_Symbol,InpTimeframe,InpTrendEMA,0,MODE_EMA,PRICE_CLOSE);
 hADX=iADX(_Symbol,InpTimeframe,InpADXPeriod);
 hATR=iATR(_Symbol,InpTimeframe,InpATRPeriod);
 if(hFast==INVALID_HANDLE||hSlow==INVALID_HANDLE||hTrend==INVALID_HANDLE||hADX==INVALID_HANDLE||hATR==INVALID_HANDLE)return INIT_FAILED;
 trade.SetExpertMagicNumber(InpMagic);
 MqlDateTime tm;TimeToStruct(TimeCurrent(),tm);dayOfYear=tm.day_of_year;dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
 return INIT_SUCCEEDED;
}

void OnDeinit(const int reason){
 if(hFast!=INVALID_HANDLE)IndicatorRelease(hFast);
 if(hSlow!=INVALID_HANDLE)IndicatorRelease(hSlow);
 if(hTrend!=INVALID_HANDLE)IndicatorRelease(hTrend);
 if(hADX!=INVALID_HANDLE)IndicatorRelease(hADX);
 if(hATR!=INVALID_HANDLE)IndicatorRelease(hATR);
}

void OnTick(){
 double adx,atr,fast,slow,trend;int dir;
 if(!ReadTrend(dir,adx,atr,fast,slow,trend))return;
 ManageTrailing(atr); // checked on every tick
 if(!InpEnableTrading||!DailyLossOK())return;
 datetime bt=iTime(_Symbol,InpTimeframe,0);
 bool newBar=(bt!=lastBar);if(newBar)lastBar=bt;
 if(!newBar||TimeCurrent()-lastEntryTime<InpEntryCooldownSeconds)return;
 int total=CountPositions();
 if(dir==0){if(total==0)HedgeProbe(atr);return;}
 if(InpCloseOppositeOnTrend)CloseSide(dir);
 int aligned=CountPositions(dir);
 if(aligned==0){
  trendAdds=0;lastTrend=dir;
  if(OpenTrade(dir,GetLot(atr*InpInitialSL_ATR),atr,dir==1?"QF confirmed BUY":"QF confirmed SELL"))trendAdds=1;
  return;
 }
 if(lastTrend!=dir){lastTrend=dir;trendAdds=aligned;lastAddPrice=SymbolInfoDouble(_Symbol,dir==1?SYMBOL_ASK:SYMBOL_BID);}
 if(aligned>=InpMaxPositions||trendAdds>=InpMaxAddsPerTrend)return;
 double px=SymbolInfoDouble(_Symbol,dir==1?SYMBOL_ASK:SYMBOL_BID);
 double advance=(dir==1?px-lastAddPrice:lastAddPrice-px);
 if(advance>=atr*InpAddEveryATR){
  if(OpenTrade(dir,GetLot(atr*InpInitialSL_ATR),atr,dir==1?"QF pyramid BUY":"QF pyramid SELL"))trendAdds++;
 }
}
