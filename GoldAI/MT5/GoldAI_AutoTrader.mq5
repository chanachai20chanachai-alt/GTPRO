//+------------------------------------------------------------------+
//| GoldAI_AutoTrader.mq5                                             |
//| Prototype V1.1 - closed-candle execution and fail-closed guard    |
//| DO NOT RUN LIVE WITHOUT COMPILATION, REPLAY AND DEMO VALIDATION   |
//+------------------------------------------------------------------+
#property strict
#property version "1.10"
#include <Trade/Trade.mqh>

input string InpBridgeURL             = "http://127.0.0.1:8765/analyze";
input string InpBridgeToken           = "";       // Same as BRIDGE_TOKEN in Python; do not commit .set files
input bool   InpEnableAutoTrade       = false;    // DEMO FIRST; OFF by default
input bool   InpRequireVerifiedNews   = true;     // Fail closed when MT5 calendar unavailable
input long   InpMagic                 = 26251025;
input double InpFixedLot              = 0.10;
input double InpTPPlanPercent         = 110.0;
input double InpSLPlanPercent         = 100.0;
input int    InpMaxTradesPerDay       = 14;        // Maximum, never a required minimum
input int    InpMaxReentriesAfterTP   = 2;         // Total max 3 executions per plan
input int    InpCooldownMinutes       = 15;
input double InpRearmGoldDistance     = 0.60;      // USD move away from zone before re-entry
input double InpMaxEntryDriftGold     = 1.00;      // Reject overly stale AI reference
input double InpMaxSpreadGold         = 0.50;      // Ask - Bid, dollars per ounce
input double InpMinRewardRisk         = 1.50;
input double InpRiskPerTradeMaxPct    = 0.50;
input double InpDailyLossLimitPct     = 2.00;
input double InpMaxEquityDrawdownPct  = 10.00;
input double InpDailyGoalPoints       = 3000.0;   // Informational, not a minimum target
input double InpDailyHardStopPoints   = 6000.0;   // Stop new entries on goal, if reached
input bool   InpResetRiskLock         = false;    // Manual unlock: apply once then set false
input int    InpSlipPoints            = 30;       // Broker native points, not user gold points
input bool   InpAllowPullback         = true;
input bool   InpAllowBreakoutRetest   = true;

CTrade trade;
struct AIPlan
{
   string id;
   string decision;
   string strategy;
   string reason;
   double low, high, reference, sl, tp;
   datetime expiry;
   bool valid;
};
AIPlan g_plan;
datetime g_m5bar=0;
datetime g_h1bar=0;
datetime g_lastExit=0;
datetime g_lastEntryBar=0;
bool g_allowEntry=true;
bool g_rearmed=true;
int g_planEntries=0;
bool g_riskLock=false;
double g_peakEquity=0;
string g_prefix="";
string g_status="WAIT_AI";

string K(const string suffix) { return g_prefix+suffix; }
double PlanHash(const string s)
{
   // Deterministic 31-bit rolling hash to persist plan state on terminal restart.
   long h=5381;
   for(int i=0;i<StringLen(s);i++) h=((h*33)+(long)StringGetCharacter(s,i))%2147483647;
   return (double)h;
}
void SavePlanState()
{
   GlobalVariableSet(K("plan_hash"),PlanHash(g_plan.id));
   GlobalVariableSet(K("entries"),(double)g_planEntries);
   GlobalVariableSet(K("allow"),g_allowEntry?1.0:0.0);
   GlobalVariableSet(K("rearmed"),g_rearmed?1.0:0.0);
   GlobalVariableSet(K("last_entry"),(double)g_lastEntryBar);
   GlobalVariableSet(K("last_exit"),(double)g_lastExit);
}
void UpdatePlanState(const string id)
{
   if(GlobalVariableCheck(K("plan_hash")) && GlobalVariableGet(K("plan_hash"))==PlanHash(id))
   {
      g_planEntries=(int)GlobalVariableGet(K("entries"));
      g_allowEntry=GlobalVariableGet(K("allow"))>0.5;
      g_rearmed=GlobalVariableGet(K("rearmed"))>0.5;
      g_lastEntryBar=(datetime)(long)GlobalVariableGet(K("last_entry"));
      g_lastExit=(datetime)(long)GlobalVariableGet(K("last_exit"));
   }
   else
   {
      g_planEntries=0; g_allowEntry=true; g_rearmed=true;
      g_lastEntryBar=0; g_lastExit=0;
      SavePlanState();
   }
}

datetime ThaiMidnightServer()
{
   // Broker server may switch DST; resolve using current server/UTC offset.
   datetime utc=TimeGMT(), thai=utc+7*3600;
   MqlDateTime s; TimeToStruct(thai,s);
   s.hour=0; s.min=0; s.sec=0;
   datetime startUtc=StructToTime(s)-7*3600;
   return startUtc+(TimeTradeServer()-TimeGMT());
}
bool IsOurDeal(const ulong ticket)
{
   return HistoryDealGetString(ticket,DEAL_SYMBOL)==_Symbol &&
          HistoryDealGetInteger(ticket,DEAL_MAGIC)==InpMagic;
}
int DailyEntries()
{
   if(!HistorySelect(ThaiMidnightServer(),TimeTradeServer())) return InpMaxTradesPerDay;
   int n=0;
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(IsOurDeal(ticket) && HistoryDealGetInteger(ticket,DEAL_ENTRY)==DEAL_ENTRY_IN)
         n++;
   }
   return n;
}
double DailyNetMoney()
{
   if(!HistorySelect(ThaiMidnightServer(),TimeTradeServer())) return -1e10;
   double net=0;
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(!IsOurDeal(ticket)) continue;
      net+=HistoryDealGetDouble(ticket,DEAL_PROFIT);
      net+=HistoryDealGetDouble(ticket,DEAL_SWAP);
      net+=HistoryDealGetDouble(ticket,DEAL_COMMISSION);
      net+=HistoryDealGetDouble(ticket,DEAL_FEE);
   }
   return net;
}
double DailyNormalizedPoints()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return 0;
   double perPoint=0;
   // A user gold point is a $0.01 price move; this normalizes net P/L by 0.10 lot.
   if(!OrderCalcProfit(ORDER_TYPE_BUY,_Symbol,InpFixedLot,tick.bid,tick.bid+0.01,perPoint) ||
      perPoint<=0) return 0;
   return DailyNetMoney()/perPoint;
}
bool HasAnyPositionOnSymbol()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket!=0 && PositionGetString(POSITION_SYMBOL)==_Symbol) return true;
   }
   return false;
}
bool IsNewsClear(bool &verified,string &reason)
{
   verified=false; reason="NEWS_UNAVAILABLE";
   if(!InpRequireVerifiedNews) { reason="NEWS_FILTER_DISABLED"; return true; }
   MqlCalendarValue values[];
   ResetLastError();
   datetime now=TimeTradeServer();
   int n=CalendarValueHistory(values,now-30*60,now+30*60,"","USD");
   if(n<0) return false;
   verified=true;
   for(int i=0;i<n;i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id,event))
      {
         verified=false; reason="NEWS_EVENT_LOOKUP_FAILED"; return false;
      }
      if(event.importance==CALENDAR_IMPORTANCE_HIGH)
      {
         reason="HIGH_USD_NEWS_WINDOW";
         return false;
      }
   }
   reason="NEWS_CLEAR";
   return true;
}
string CandleJson(const MqlRates &r)
{
   return "{\"t\":"+IntegerToString((long)r.time)+
          ",\"o\":"+DoubleToString(r.open,_Digits)+
          ",\"h\":"+DoubleToString(r.high,_Digits)+
          ",\"l\":"+DoubleToString(r.low,_Digits)+
          ",\"c\":"+DoubleToString(r.close,_Digits)+"}";
}
bool AddRates(string &json,const ENUM_TIMEFRAMES tf,const string key,const int count)
{
   MqlRates r[];
   int n=CopyRates(_Symbol,tf,1,count,r); // shift 1 = last CLOSED candle
   if(n!=count) return false;
   json+=",\""+key+"\":[";
   for(int i=0;i<n;i++)
   {
      if(i>0) json+=",";
      json+=CandleJson(r[i]);
   }
   json+="]";
   return true;
}
bool RequestPlan(const bool newsVerified)
{
   if(StringLen(InpBridgeToken)<12) { g_status="NO_TRADE: BRIDGE TOKEN MISSING"; return false; }
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;
   string payload="{\"symbol\":\""+_Symbol+"\",\"news_verified\":"+
        (newsVerified?"true":"false")+
        ",\"bid\":"+DoubleToString(tick.bid,_Digits)+
        ",\"ask\":"+DoubleToString(tick.ask,_Digits)+
        ",\"timestamp_utc\":"+IntegerToString((long)TimeGMT());
   if(!AddRates(payload,PERIOD_H1,"h1",80) ||
      !AddRates(payload,PERIOD_M15,"m15",100) ||
      !AddRates(payload,PERIOD_M5,"m5",100))
   {
      g_status="NO_TRADE: INSUFFICIENT CLOSED HISTORY"; return false;
   }
   payload+="}";
   char request[], response[];
   string headers="Content-Type: application/json\r\nX-Bridge-Token: "+InpBridgeToken+"\r\n";
   string responseHeaders;
   StringToCharArray(payload,request,0,StringLen(payload),CP_UTF8);
   ResetLastError();
   int code=WebRequest("POST",InpBridgeURL,headers,20000,request,response,responseHeaders);
   if(code!=200)
   {
      g_status="NO_TRADE: API ERROR "+IntegerToString(code);
      g_plan.valid=false;
      return false;
   }
   string wire=CharArrayToString(response,0,ArraySize(response),CP_UTF8);
   string f[];
   int len=StringSplit(wire,'|',f);
   if(len<11 || f[0]!="PLAN")
   {
      g_status=(len>0 && f[0]=="NO_TRADE") ? "NO_TRADE: AI DECLINED" : "NO_TRADE: INVALID AI RESPONSE";
      g_plan.valid=false;
      return false;
   }
   AIPlan p;
   p.valid=false;
   p.id=f[1]; p.decision=f[2]; p.strategy=f[3];
   p.low=StringToDouble(f[4]); p.high=StringToDouble(f[5]);
   p.reference=StringToDouble(f[6]); p.sl=StringToDouble(f[7]); p.tp=StringToDouble(f[8]);
   p.expiry=(datetime)(long)StringToInteger(f[9]); p.reason=f[10];
   bool side=(p.decision=="BUY" || p.decision=="SELL");
   bool strategy=(p.strategy=="PULLBACK" && InpAllowPullback) ||
                 (p.strategy=="BREAKOUT_RETEST" && InpAllowBreakoutRetest);
   if(!side || !strategy || p.low>p.high || p.reference<p.low ||
      p.reference>p.high || p.expiry<=TimeGMT() ||
      (p.decision=="BUY" && !(p.sl<p.low && p.tp>p.high)) ||
      (p.decision=="SELL" && !(p.sl>p.high && p.tp<p.low)))
   { g_status="NO_TRADE: PLAN VALIDATION FAILED"; g_plan.valid=false; return false; }
   p.valid=true; g_plan=p;
   UpdatePlanState(g_plan.id);
   g_status="WAIT_M5: "+p.decision+" "+p.strategy;
   Print("GoldAI plan=",p.id," ",p.decision," ",p.strategy," reason=",p.reason);
   return true;
}
bool H1TrendMatches()
{
   int handle=iMA(_Symbol,PERIOD_H1,50,0,MODE_EMA,PRICE_CLOSE);
   if(handle==INVALID_HANDLE) return false;
   double ema[];
   int copied=CopyBuffer(handle,0,1,4,ema);
   IndicatorRelease(handle);
   if(copied!=4) return false;
   double lastClose=iClose(_Symbol,PERIOD_H1,1);
   if(lastClose<=0) return false;
   if(g_plan.decision=="BUY") return lastClose>ema[3] && ema[3]>ema[0];
   if(g_plan.decision=="SELL") return lastClose<ema[3] && ema[3]<ema[0];
   return false;
}
bool BreakoutWasConfirmed()
{
   MqlRates r[];
   if(CopyRates(_Symbol,PERIOD_M15,1,14,r)!=14) return false;
   // Check one recent CLOSED M15 candle closed beyond the prior 6-bar swing.
   for(int i=9;i<14;i++)
   {
      double hi=r[i-1].high,lo=r[i-1].low;
      for(int j=i-6;j<i;j++)
      {
         if(r[j].high>hi) hi=r[j].high;
         if(r[j].low<lo) lo=r[j].low;
      }
      if(g_plan.decision=="BUY" && r[i].close>hi) return true;
      if(g_plan.decision=="SELL" && r[i].close<lo) return true;
   }
   return false;
}
bool M5Signal()
{
   MqlRates r[];
   if(CopyRates(_Symbol,PERIOD_M5,1,3,r)!=3) return false;
   MqlRates last=r[2], prev=r[1];
   // A previous or current closed candle must have touched the plan zone.
   bool touched=(last.low<=g_plan.high && last.high>=g_plan.low) ||
                (prev.low<=g_plan.high && prev.high>=g_plan.low);
   if(!touched) return false;
   if(g_plan.decision=="BUY")
   {
      bool bullish=last.close>last.open && last.close>prev.high;
      return bullish && last.close>g_plan.low;
   }
   bool bearish=last.close<last.open && last.close<prev.low;
   return bearish && last.close<g_plan.high;
}
bool RiskPermits(const double price,const double sl,const double tp,const ENUM_ORDER_TYPE side)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) {g_status="NO_TRADE: QUOTE ERROR";return false;}
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double vstep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(InpFixedLot<vmin || InpFixedLot>vmax || vstep<=0 ||
      MathAbs((InpFixedLot/vstep)-MathRound(InpFixedLot/vstep))>0.00001)
   {g_status="NO_TRADE: INVALID FIXED LOT";return false;}
   if(tick.ask-tick.bid>InpMaxSpreadGold) {g_status="NO_TRADE: SPREAD";return false;}
   if(DailyEntries()>=InpMaxTradesPerDay) {g_status="NO_TRADE: DAILY TRADE LIMIT";return false;}
   double net=DailyNetMoney();
   if(net< -1e9) {g_status="NO_TRADE: HISTORY UNAVAILABLE";return false;}
   double basis=AccountInfoDouble(ACCOUNT_BALANCE)-net;
   if(basis<=0) return false;
   if(net<=-basis*InpDailyLossLimitPct/100.0)
   {g_status="NO_TRADE: DAILY LOSS LOCK";return false;}
   if(InpDailyHardStopPoints>0 && DailyNormalizedPoints()>=InpDailyHardStopPoints)
   {g_status="NO_TRADE: DAILY POINT GOAL REACHED";return false;}
   if(HasAnyPositionOnSymbol()) {g_status="NO_TRADE: EXISTING SYMBOL POSITION";return false;}
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity>g_peakEquity) {g_peakEquity=equity;GlobalVariableSet(K("peak"),equity);}
   if(g_peakEquity>0 && (g_peakEquity-equity)/g_peakEquity*100.0>=InpMaxEquityDrawdownPct)
   {
      g_riskLock=true;GlobalVariableSet(K("locked"),1);
      g_status="NO_TRADE: EQUITY DD LOCK";return false;
   }
   if(g_riskLock) {g_status="NO_TRADE: RISK LOCK";return false;}
   double risk=0;
   if(!OrderCalcProfit(side,_Symbol,InpFixedLot,price,sl,risk) || risk>=0)
   {g_status="NO_TRADE: INVALID SL OR CONTRACT";return false;}
   if(-risk > equity*InpRiskPerTradeMaxPct/100.0)
   {g_status="NO_TRADE: FIXED LOT OVER RISK CAP";return false;}
   double reward=0;
   if(!OrderCalcProfit(side,_Symbol,InpFixedLot,price,tp,reward) || reward<=0)
   {g_status="NO_TRADE: INVALID TP";return false;}
   // Conservative room for spread, commissions, and slippage: use at least 0.10 USD per oz.
   double costEstimate=0.10;
   double moneyCost=0;
   OrderCalcProfit(ORDER_TYPE_BUY,_Symbol,InpFixedLot,price,price+costEstimate,moneyCost);
   if(moneyCost<0) moneyCost=0;
   if((reward-moneyCost)/(-risk+moneyCost)<InpMinRewardRisk)
   {g_status="NO_TRADE: LOW RR";return false;}
   double requiredMargin=0;
   if(!OrderCalcMargin(side,_Symbol,InpFixedLot,price,requiredMargin) ||
      requiredMargin > AccountInfoDouble(ACCOUNT_MARGIN_FREE)*0.80)
   {g_status="NO_TRADE: INSUFFICIENT MARGIN";return false;}
   long stopPts=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minStop=(double)stopPts*_Point;
   if(side==ORDER_TYPE_BUY &&
      (sl>=tick.bid-minStop || tp<=tick.bid+minStop)) return false;
   if(side==ORDER_TYPE_SELL &&
      (sl<=tick.ask+minStop || tp>=tick.ask-minStop)) return false;
   return true;
}
void TryEntry()
{
   if(!g_plan.valid || TimeGMT()>=g_plan.expiry) {g_status="NO_TRADE: PLAN EXPIRED";return;}
   if(!g_allowEntry || g_planEntries>InpMaxReentriesAfterTP)
   {g_status="NO_TRADE: PLAN ENTRY LIMIT";return;}
   if(g_lastExit>0 && TimeCurrent()-g_lastExit<InpCooldownMinutes*60)
   {g_status="WAIT: COOLDOWN";return;}
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;
   // Require price to leave the zone after TP before the next attempt.
   if(!g_rearmed)
   {
      double close=iClose(_Symbol,PERIOD_M5,1);
      if(close<g_plan.low-InpRearmGoldDistance || close>g_plan.high+InpRearmGoldDistance)
      {g_rearmed=true;SavePlanState();}
      else {g_status="WAIT: REARM OUTSIDE ZONE";return;}
   }
   bool verified=false;string newsReason;
   if(!IsNewsClear(verified,newsReason))
   {g_status="NO_TRADE: "+newsReason;return;}
   if(!H1TrendMatches()) {g_status="WAIT: H1 DISAGREES";return;}
   if(g_plan.strategy=="BREAKOUT_RETEST" && !BreakoutWasConfirmed())
   {g_status="WAIT: M15 BREAKOUT NOT CONFIRMED";return;}
   if(!M5Signal()) {g_status="WAIT: M5 CONFIRMATION";return;}
   if(!InpEnableAutoTrade) {g_status="SIGNAL ONLY: "+g_plan.decision+" M5 CONFIRMED";return;}
   double price=(g_plan.decision=="BUY")?tick.ask:tick.bid;
   if(MathAbs(price-g_plan.reference)>InpMaxEntryDriftGold)
   {g_status="NO_TRADE: ENTRY DRIFT";return;}
   if(price<g_plan.low-0.15 || price>g_plan.high+0.15)
   {g_status="WAIT: OUTSIDE ENTRY ZONE";return;}
   ENUM_ORDER_TYPE type=(g_plan.decision=="BUY")?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   // At 100%, SL remains the AI structure-derived absolute price.
   double sl=g_plan.reference+(g_plan.sl-g_plan.reference)*InpSLPlanPercent/100.0;
   // TP % scales AI planned distance from actual market entry.
   double tp=price+(g_plan.tp-g_plan.reference)*InpTPPlanPercent/100.0;
   sl=NormalizeDouble(sl,_Digits); tp=NormalizeDouble(tp,_Digits);
   if(!RiskPermits(price,sl,tp,type)) return;
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlipPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   string comment="GoldAI:"+g_plan.id;
   if(StringLen(comment)>31) comment=StringSubstr(comment,0,31);
   bool sent=false;
   if(type==ORDER_TYPE_BUY) sent=trade.Buy(InpFixedLot,_Symbol,0,sl,tp,comment);
   else sent=trade.Sell(InpFixedLot,_Symbol,0,sl,tp,comment);
   uint ret=trade.ResultRetcode();
   if(sent && (ret==TRADE_RETCODE_DONE || ret==TRADE_RETCODE_DONE_PARTIAL))
   {
      g_planEntries++;
      g_allowEntry=false; // Must close at broker TP before possible re-entry
      g_rearmed=false;
      g_lastEntryBar=iTime(_Symbol,PERIOD_M5,1);
      SavePlanState();
      g_status="TRADE OPEN: "+g_plan.decision;
      Print("Opened ",g_plan.decision," plan ",g_plan.id," execution ",g_planEntries);
   }
   else
   {
      g_status="NO_TRADE: ORDER REJECTED "+IntegerToString((int)ret);
      Print("GoldAI order failed: ",trade.ResultRetcodeDescription());
   }
}
void OnTradeTransaction(const MqlTradeTransaction& tx,
                        const MqlTradeRequest& rq,
                        const MqlTradeResult& rs)
{
   if(tx.type!=TRADE_TRANSACTION_DEAL_ADD || tx.deal==0) return;
   if(!HistoryDealSelect(tx.deal)) return;
   if(HistoryDealGetString(tx.deal,DEAL_SYMBOL)!=_Symbol ||
      HistoryDealGetInteger(tx.deal,DEAL_MAGIC)!=InpMagic) return;
   if(HistoryDealGetInteger(tx.deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT) return;
   long reason=HistoryDealGetInteger(tx.deal,DEAL_REASON);
   g_lastExit=TimeCurrent();
   bool brokerTP=(reason==DEAL_REASON_TP);
   g_allowEntry=(brokerTP && g_plan.valid &&
                 g_planEntries<=InpMaxReentriesAfterTP && TimeGMT()<g_plan.expiry);
   g_rearmed=false;
   SavePlanState();
   Print("GoldAI exit: TP=",brokerTP," reentryAllowed=",g_allowEntry);
}
void OnTimer()
{
   datetime h1=iTime(_Symbol,PERIOD_H1,0);
   if(h1>0 && h1!=g_h1bar)
   {
      g_h1bar=h1;
      bool verified=false;string reason;
      if(IsNewsClear(verified,reason))
      {
         // Never recycle an expired/invalid plan if API is offline.
         g_plan.valid=false;
         RequestPlan(verified);
      }
      else {g_plan.valid=false;g_status="NO_TRADE: "+reason;}
   }
   datetime m5=iTime(_Symbol,PERIOD_M5,0);
   if(m5>0 && m5!=g_m5bar)
   {
      g_m5bar=m5;
      TryEntry();
   }
   Comment("Gold AI Auto Trader v1.1 | ",_Symbol,
           "\nStatus: ",g_status,
           "\nAI Plan: ",g_plan.id," | ",g_plan.decision," | ",g_plan.strategy,
           "\nEntry zone: ",DoubleToString(g_plan.low,_Digits)," - ",DoubleToString(g_plan.high,_Digits),
           "\nAI SL / TP: ",DoubleToString(g_plan.sl,_Digits)," / ",DoubleToString(g_plan.tp,_Digits),
           "\nTrades today: ",DailyEntries()," / ",InpMaxTradesPerDay,
           "\nEntries on plan: ",g_planEntries," / ",1+InpMaxReentriesAfterTP,
           "\nDaily net gold points (approx): ",DoubleToString(DailyNormalizedPoints(),0),
           "\nGold-point goals: ",DoubleToString(InpDailyGoalPoints,0)," - ",DoubleToString(InpDailyHardStopPoints,0),
           "\nAUTO: ",(InpEnableAutoTrade?"ON":"OFF")," | Risk lock: ",(g_riskLock?"YES":"NO"));
}
int OnInit()
{
   if(StringFind(_Symbol,"XAUUSD")!=0 || InpFixedLot<=0 ||
      InpTPPlanPercent<=0 || InpSLPlanPercent<100 ||
      InpMaxTradesPerDay<1 || InpMaxReentriesAfterTP<0 ||
      InpMinRewardRisk<1 || InpMagic<1)
      return INIT_PARAMETERS_INCORRECT;
   if(MQLInfoInteger(MQL_TESTER))
   {
      Print("GoldAI HTTP mode unavailable in Strategy Tester: use replay fixture build.");
      return INIT_FAILED;
   }
   g_plan.valid=false;
   g_prefix="GAI."+IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))+"."+
             IntegerToString(InpMagic)+"."+_Symbol+"."; // Scoped to symbol
   if(InpResetRiskLock) GlobalVariableSet(K("locked"),0);
   g_riskLock=GlobalVariableCheck(K("locked")) && GlobalVariableGet(K("locked"))>0.5;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEquity=(GlobalVariableCheck(K("peak"))?GlobalVariableGet(K("peak")):equity);
   if(g_peakEquity<equity) g_peakEquity=equity;
   GlobalVariableSet(K("peak"),g_peakEquity);
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   EventSetTimer(3);
   Print("GoldAI started. Auto trading ",(InpEnableAutoTrade?"ON":"OFF"),
         ". Configure WebRequest allowed URL and BridgeToken. TEST DEMO FIRST.");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}
void OnTick() {} // OnTimer handles closed candles; broker-side SL/TP remains active
