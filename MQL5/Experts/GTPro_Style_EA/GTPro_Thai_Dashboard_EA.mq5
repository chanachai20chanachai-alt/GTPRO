//+------------------------------------------------------------------+
//| GTPro_Thai_Dashboard_EA.mq5                                               |
//| Independent GTpro-inspired research EA for MetaTrader 5          |
//| Does NOT contain or claim to reproduce the proprietary formula.  |
//| V1: EMA trend + BOS/FVG retest + SSL/BSL sweep/internal CHoCH     |
//| No grid, martingale, recovery, or external dependencies.         |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"
#property description "GTpro-inspired SMC research EA. Test on demo before any live trading."

#include <Trade/Trade.mqh>
CTrade trade;

enum ENUM_GT_STRATEGY { MODE_TREND=0, MODE_REVERSAL=1, MODE_HYBRID=2 };
enum ENUM_GT_EXECUTION { GT_SIGNAL_ONLY=0, GT_AUTO_TRADE=1 };
enum ENUM_GT_SL { GT_SL_SWING_ATR=0, GT_SL_FIXED_POINTS=1 };
enum ENUM_GT_TP { GT_TP_RR=0, GT_TP_FIXED_POINTS=1 };
enum ENUM_GT_TRAIL { GT_TRAIL_OFF=0, GT_TRAIL_POINTS=1, GT_TRAIL_ATR=2 };

input group "01 | โหมดการทำงาน"
input ENUM_GT_EXECUTION InpExecutionMode = GT_SIGNAL_ONLY; // แจ้งสัญญาณ / ออโต้เทรด
input ENUM_GT_STRATEGY InpStrategy = MODE_HYBRID; // เทรนด์ / กลับตัว / ผสม
input ENUM_TIMEFRAMES InpEntryTF = PERIOD_M5; // กราฟเข้าไม้
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_M15; // กราฟดูเทรนด์
input long InpMagic = 26102302; // Magic Number
input int InpDeviationPoints = 30; // สลิปเพจ สูงสุด (จุด)
input int InpMaxSpreadPoints = 40; // สเปรด สูงสุด (จุด)

input group "02 | EMA / BOS / โครงสร้าง"
input int InpFastEMA = 100; // EMA เร็ว
input int InpSlowEMA = 200; // EMA ช้า
input int InpADXPeriod = 14; // ADX
input double InpMinTrendADX = 18.0; // ADX ขั้นต่ำ
input int InpPivotLeft = 3; // Swing ด้านซ้าย
input int InpPivotRight = 3; // Swing ด้านขวา
input int InpStructureLookback = 75; // แท่งย้อนหลัง
input int InpBreakBufferPoints = 20; // ทะลุ BOS กี่จุด

input group "03 | รอย่อเข้า FVG"
input int InpFVGSearchBars = 10; // ค้นหา FVG
input double InpFVGMinATR = 0.15; // FVG ขั้นต่ำเทียบ ATR
input int InpMaxRetestBars = 12; // จำนวนแท่งรอ Retest

input group "04 | Sweep / CHoCH"
input int InpSweepBufferPoints = 20; // ระยะกวาดสภาพคล่อง
input int InpInternalBreakBars = 5; // แท่งยืนยัน CHoCH
input int InpMaxCHoCHWaitBars = 8; // ระยะรอ CHoCH
input bool InpRequireReversalHTF = false; // ให้เทรนด์ใหญ่ยืนยัน
input bool InpRequireZoneForReversal = false; // บังคับใช้โซน Supply/Demand

input group "05 | โซน Demand / Supply"
input bool InpShowZones = true; // วาดโซนบนกราฟ
input int InpZoneBaseLookback = 7; // ค้นหาแท่งฐาน
input double InpZoneDisplacementATR = 0.60; // แรงแท่ง BOS x ATR
input int InpZoneMaxAgeBars = 100; // อายุโซนสูงสุด
input int InpZoneExtendBars = 80; // ความยาวโซนด้านขวา

input group "06 | ตั้งค่า SL"
input ENUM_GT_SL InpSLMode = GT_SL_SWING_ATR; // Swing/ATR หรือ SL คงที่
input int InpFixedSLPoints = 1500; // SL คงที่ (จุด)
input int InpATRPeriod = 14; // ATR
input double InpStopBufferATR = 0.20; // เผื่อ SL จาก Swing x ATR
input double InpMinStopATR = 1.00; // SL ขั้นต่ำ x ATR
input double InpMaxStopATR = 4.00; // SL สูงสุด x ATR

input group "07 | ตั้งค่า TP"
input ENUM_GT_TP InpTPMode = GT_TP_RR; // RR หรือ TP คงที่
input int InpFixedTPPoints = 3000; // TP คงที่ (จุด)
input double InpRiskReward = 1.80; // อัตราส่วนกำไรต่อความเสี่ยง

input group "08 | Lot และการป้องกันพอร์ต"
input bool InpUseFixedLot = false; // ใช้ Lot คงที่
input double InpFixedLot = 0.01; // ล็อตคงที่
input double InpRiskPercent = 0.50; // % เสี่ยงต่อไม้
input double InpMaxLot = 1.00; // Lot สูงสุด
input double InpMaxDailyEquityLoss = 2.00; // ขาดทุน Equity รายวัน %
input double InpMaxPeakEquityDD = 10.0; // DD สูงสุด %
input int InpCooldownBars = 3; // พักกี่แท่ง

input group "09 | กันหน้าทุน (BE)"
input bool InpUseBreakeven = true; // เปิดระบบ BE
input int InpBEStartPoints = 500; // เริ่ม BE เมื่อกำไรกี่จุด
input int InpBEPlusPoints = 50; // ล็อกกำไร BE กี่จุด

input group "10 | เทรลลิ่ง (Trailing)"
input ENUM_GT_TRAIL InpTrailMode = GT_TRAIL_OFF; // ปิด / คงที่ / ATR
input int InpTrailStartPoints = 1000; // เริ่มเทรลเมื่อกำไรกี่จุด
input int InpTrailDistancePoints = 400; // SL ห่างราคากี่จุด
input int InpTrailStepPoints = 100; // ขยับทีละกี่จุด
input double InpTrailATR = 1.20; // เทรลระยะ x ATR

input group "11 | แดชบอร์ดและสัญญาณ"
input bool InpShowDashboard = true; // แสดงแผงภาษาไทย
input bool InpDrawTradeLevels = true; // เส้นจุดเข้า SL TP
input bool InpPopupAlert = false; // Alert เมื่อพบสัญญาณ
input bool InpPushNotification = false; // Push ไปมือถือ

struct FVGState
  {
   bool     active;
   int      direction;
   double   low;
   double   high;
   int      age;
  };
struct SweepState
  {
   bool     active;
   int      direction;
   double   extreme;
   double   trigger;
   int      age;
  };

FVGState   g_fvg;
SweepState g_sweep;
int        g_fastHandle=INVALID_HANDLE;
int        g_slowHandle=INVALID_HANDLE;
int        g_adxHandle=INVALID_HANDLE;
int        g_atrHandle=INVALID_HANDLE;
datetime   g_lastBar=0;
int        g_cooldown=0;
datetime   g_day=0;
double     g_dayStartEquity=0.0;
double     g_peakEquity=0.0;
bool       g_dailyBlocked=false;
bool       g_equityBlocked=false;
string     g_status="Initializing";

bool IndicatorValue(const int handle,const int shift,double &value)
  {
   double buffer[1];
   if(CopyBuffer(handle,0,shift,1,buffer)!=1)
      return false;
   value=buffer[0];
   return (MathIsValidNumber(value) && value!=EMPTY_VALUE);
  }

void UpdateEquityGuards()
  {
   MqlDateTime now;
   TimeToStruct(TimeCurrent(),now);
   now.hour=0;
   now.min=0;
   now.sec=0;
   datetime startOfDay=StructToTime(now);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_day!=startOfDay)
     {
      g_day=startOfDay;
      g_dayStartEquity=equity;
      g_dailyBlocked=false;
     }
   if(equity>g_peakEquity)
      g_peakEquity=equity;
   if(InpMaxDailyEquityLoss>0.0 && g_dayStartEquity>0.0 &&
      equity<=g_dayStartEquity*(1.0-InpMaxDailyEquityLoss/100.0))
      g_dailyBlocked=true;
   if(InpMaxPeakEquityDD>0.0 && g_peakEquity>0.0 &&
      equity<=g_peakEquity*(1.0-InpMaxPeakEquityDD/100.0))
      g_equityBlocked=true;
  }

bool AnyPositionOnSymbol()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionSelectByTicket(ticket) &&
         PositionGetString(POSITION_SYMBOL)==_Symbol)
         return true; // prevent conflict with other EAs/manual trades
     }
   return false;
  }

bool AllowedToOpen()
  {
   if(!InpEnableAutoTrading) { g_status="SIGNAL ONLY (auto trading disabled)"; return false; }
   if(g_dailyBlocked || g_equityBlocked) { g_status="EQUITY LOCK"; return false; }
   if(g_cooldown>0) { g_status="Cooldown"; return false; }
   if(AnyPositionOnSymbol()) { g_status="Existing position on symbol"; return false; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED)) { g_status="Trading permissions disabled"; return false; }
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=0 || tick.bid<=0)
      return false;
   if(InpMaxSpreadPoints>0 && (tick.ask-tick.bid)/_Point>InpMaxSpreadPoints)
     { g_status="Spread too high"; return false; }
   return true;
  }

// A confirmed pivot has both older (left) and newer (right) CLOSED bars.
bool FindPivots(const MqlRates &r[],const int n,const int first,
                double &swingHigh,double &swingLow)
  {
   swingHigh=0.0;
   swingLow=0.0;
   bool foundHigh=false,foundLow=false;
   int begin=MathMax(first,InpPivotRight+1);
   int last=MathMin(n-InpPivotLeft-1,InpStructureLookback);
   for(int i=begin;i<=last;i++)
     {
      bool isHigh=true,isLow=true;
      for(int k=1;k<=InpPivotLeft;k++)
        {
         if(r[i+k].high>=r[i].high) isHigh=false;
         if(r[i+k].low<=r[i].low) isLow=false;
        }
      for(int k=1;k<=InpPivotRight;k++)
        {
         if(r[i-k].high>=r[i].high) isHigh=false;
         if(r[i-k].low<=r[i].low) isLow=false;
        }
      if(isHigh && !foundHigh) { swingHigh=r[i].high; foundHigh=true; }
      if(isLow  && !foundLow)  { swingLow=r[i].low;   foundLow=true; }
      if(foundHigh && foundLow) return true;
     }
   return false;
  }

bool FindFVG(const MqlRates &r[],const int n,const int direction,
             const double atr,double &zoneLow,double &zoneHigh)
  {
   int last=MathMin(n-3,InpFVGSearchBars);
   for(int i=2;i<=last;i++)
     {
      if(direction==1 && r[i].low-r[i+2].high>=atr*InpFVGMinATR &&
         r[i+1].close>r[i+1].open)
        {
         zoneLow=r[i+2].high;
         zoneHigh=r[i].low;
         return true;
        }
      if(direction==-1 && r[i+2].low-r[i].high>=atr*InpFVGMinATR &&
         r[i+1].close<r[i+1].open)
        {
         zoneLow=r[i].high;
         zoneHigh=r[i+2].low;
         return true;
        }
     }
   return false;
  }

int GetTrendDirection(double &adxValue)
  {
   double fast,slow;
   if(!IndicatorValue(g_fastHandle,1,fast) ||
      !IndicatorValue(g_slowHandle,1,slow) ||
      !IndicatorValue(g_adxHandle,1,adxValue))
      return 0;
   if(adxValue<InpMinTrendADX) return 0;
   double closeHTF=iClose(_Symbol,InpTrendTF,1);
   if(closeHTF<=0.0) return 0;
   if(fast>slow && closeHTF>fast) return 1;
   if(fast<slow && closeHTF<fast) return -1;
   return 0;
  }

// Returns 1 for BUY, -1 for SELL, 0 for no trade.
int ProcessTrend(const MqlRates &r[],const int n,const int trend,
                 const double atr,double &slAnchor)
  {
   if(g_fvg.active)
     {
      g_fvg.age++;
      if(g_fvg.age>InpMaxRetestBars ||
         (g_fvg.direction==1 && r[1].close<g_fvg.low) ||
         (g_fvg.direction==-1 && r[1].close>g_fvg.high))
        {
         g_fvg.active=false;
        }
      else if(g_fvg.age>=1 && g_fvg.direction==trend &&
              r[1].low<=g_fvg.high && r[1].high>=g_fvg.low)
        {
         if(trend==1 && r[1].close>g_fvg.high && r[1].close>r[1].open)
           {
            slAnchor=g_fvg.low;
            g_fvg.active=false;
            return 1;
           }
         if(trend==-1 && r[1].close<g_fvg.low && r[1].close<r[1].open)
           {
            slAnchor=g_fvg.high;
            g_fvg.active=false;
            return -1;
           }
        }
     }
   if(g_fvg.active || trend==0) return 0;

   double high,low;
   if(!FindPivots(r,n,InpPivotRight+1,high,low)) return 0;
   double threshold=InpBreakBufferPoints*_Point;
   bool bullBOS=(trend==1 && r[1].close>high+threshold &&
                 r[2].close<=high+threshold);
   bool bearBOS=(trend==-1 && r[1].close<low-threshold &&
                 r[2].close>=low-threshold);
   if(!bullBOS && !bearBOS) return 0;

   double zl,zh;
   int direction=(bullBOS?1:-1);
   if(FindFVG(r,n,direction,atr,zl,zh))
     {
      g_fvg.active=true;
      g_fvg.direction=direction;
      g_fvg.low=zl;
      g_fvg.high=zh;
      g_fvg.age=0;
      PrintFormat("GTProStyle BOS %s: FVG %.3f - %.3f",
                  (direction==1?"BUY":"SELL"),zl,zh);
     }
   return 0;
  }

// Sweep a PREVIOUSLY confirmed pivot, then wait for a close beyond the
// internal high/low that existed BEFORE the sweep (CHoCH proxy).
int ProcessReversal(const MqlRates &r[],const int n,const int trend,
                    double &slAnchor)
  {
   if(g_sweep.active)
     {
      g_sweep.age++;
      if(g_sweep.age>InpMaxCHoCHWaitBars)
         g_sweep.active=false;
      else
        {
         if(g_sweep.direction==1)
           {
            g_sweep.extreme=MathMin(g_sweep.extreme,r[1].low);
            if(r[1].close>g_sweep.trigger &&
               r[1].close>r[1].open &&
               (!InpRequireReversalHTF || trend==1))
              {
               slAnchor=g_sweep.extreme;
               g_sweep.active=false;
               return 1;
              }
           }
         else
           {
            g_sweep.extreme=MathMax(g_sweep.extreme,r[1].high);
            if(r[1].close<g_sweep.trigger &&
               r[1].close<r[1].open &&
               (!InpRequireReversalHTF || trend==-1))
              {
               slAnchor=g_sweep.extreme;
               g_sweep.active=false;
               return -1;
              }
           }
        }
     }
   if(g_sweep.active || n<InpInternalBreakBars+InpPivotRight+8)
      return 0;

   double high,low;
   // Start farther back: the pivot must already have been confirmable
   // at the time of the sweep bar.
   if(!FindPivots(r,n,InpPivotRight+2,high,low)) return 0;
   double buffer=InpSweepBufferPoints*_Point;
   int direction=0;
   if(r[1].low<low-buffer && r[1].close>low)
      direction=1;           // Sell-side liquidity sweep
   else if(r[1].high>high+buffer && r[1].close<high)
      direction=-1;          // Buy-side liquidity sweep
   if(direction==0) return 0;

   double trigger=(direction==1 ? -DBL_MAX : DBL_MAX);
   for(int j=2;j<2+InpInternalBreakBars;j++)
     {
      if(direction==1) trigger=MathMax(trigger,r[j].high);
      else             trigger=MathMin(trigger,r[j].low);
     }
   g_sweep.active=true;
   g_sweep.direction=direction;
   g_sweep.extreme=(direction==1?r[1].low:r[1].high);
   g_sweep.trigger=trigger;
   g_sweep.age=0;
   PrintFormat("GTProStyle %s liquidity sweep. CHoCH trigger %.3f",
               (direction==1?"SSL":"BSL"),trigger);
   return 0;
  }

double NormalizeVolumeDown(const double target)
  {
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0.0 || minLot<=0.0) return 0.0;
   double cap=MathMin(maxLot,InpMaxLot);
   if(cap<minLot || target<minLot) return 0.0;
   double capped=MathMin(target,cap);
   double lots=MathFloor((capped-minLot)/step+1e-8)*step+minLot;
   return NormalizeDouble(MathMax(minLot,MathMin(lots,cap)),8);
  }

double GetTradeVolume(const ENUM_ORDER_TYPE orderType,
                      const double entry,const double stop)
  {
   if(InpUseFixedLot) return NormalizeVolumeDown(InpFixedLot);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double referenceLot=MathMax(minLot,MathMin(1.0,maxLot));
   double estimatedLoss=0.0;
   if(!OrderCalcProfit(orderType,_Symbol,referenceLot,entry,stop,estimatedLoss) ||
      estimatedLoss>=0.0)
      return 0.0;
   double riskMoney=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercent/100.0;
   if(riskMoney<=0.0) return 0.0;
   // Never round up to broker minimum if doing so exceeds risk budget.
   return NormalizeVolumeDown(riskMoney/(-estimatedLoss/referenceLot));
  }

void DrawTradeArrow(const int direction,const datetime stamp,
                    const double price)
  {
   string name="GTP_"+IntegerToString((long)stamp)+"_"+
               IntegerToString(direction);
   if(ObjectFind(0,name)>=0) return;
   if(ObjectCreate(0,name,(direction==1?OBJ_ARROW_UP:OBJ_ARROW_DOWN),
                   0,stamp,price))
     {
      ObjectSetInteger(0,name,OBJPROP_COLOR,(direction==1?clrLime:clrTomato));
      ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
     }
  }

void SubmitSignal(const int direction,const double anchor,
                  const double atr,const string origin,const datetime signalTime)
  {
   g_status=origin+" signal "+(direction==1?"BUY":"SELL");
   Print("GTProStyle ",g_status);
   DrawTradeArrow(direction,signalTime,anchor);
   if(!AllowedToOpen()) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;
   double entry=(direction==1?tick.ask:tick.bid);
   double buffer=atr*InpStopBufferATR;
   double rawStop=(direction==1?anchor-buffer:anchor+buffer);
   double distance=(direction==1?entry-rawStop:rawStop-entry);
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minimum=MathMax(atr*InpMinStopATR,(stops+2)*_Point);
   distance=MathMax(distance,minimum);
   if(distance<=0 || distance>atr*InpMaxStopATR)
     { g_status="Stop outside ATR limits"; return; }

   double stop=NormalizeDouble(entry-direction*distance,_Digits);
   double target=NormalizeDouble(entry+direction*distance*InpRiskReward,_Digits);
   ENUM_ORDER_TYPE orderType=(direction==1?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
   double volume=GetTradeVolume(orderType,entry,stop);
   if(volume<=0.0) { g_status="Lot below broker minimum or invalid risk"; return; }

   double margin=0.0;
   if(!OrderCalcMargin(orderType,_Symbol,volume,entry,margin) ||
      margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)*0.80)
     { g_status="Not enough available margin"; return; }

   bool requested=(direction==1?
                   trade.Buy(volume,_Symbol,0.0,stop,target,origin):
                   trade.Sell(volume,_Symbol,0.0,stop,target,origin));
   uint retcode=trade.ResultRetcode();
   if(!requested || (retcode!=TRADE_RETCODE_DONE &&
                     retcode!=TRADE_RETCODE_DONE_PARTIAL &&
                     retcode!=TRADE_RETCODE_PLACED))
     {
      PrintFormat("GTProStyle order REJECTED retcode=%u %s",
                  retcode,trade.ResultRetcodeDescription());
      g_status="Order rejected";
      return;
     }
   g_cooldown=InpCooldownBars;
   PrintFormat("GTProStyle %s %.3f lots SL %.3f TP %.3f",
               origin,volume,stop,target);
   g_status="TRADED: "+origin;
  }

void ManageOurPositions()
  {
   if(!InpUseBreakeven && !InpUseTrailing) return;
   double atr=0.0;
   if(!IndicatorValue(g_atrHandle,1,atr) || atr<=0.0) return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   int freeze=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double minDistance=(MathMax(stops,freeze)+2)*_Point;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      long type=PositionGetInteger(POSITION_TYPE);
      int direction=(type==POSITION_TYPE_BUY?1:-1);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double oldSL=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      if(tp<=0.0 || InpRiskReward<=0) continue;
      double initialR=MathAbs(tp-entry)/InpRiskReward;
      double market=(direction==1?tick.bid:tick.ask);
      double move=(market-entry)*direction;
      double proposedSL=oldSL;

      if(InpUseBreakeven && move>=initialR*InpBreakevenAtR)
        {
         double be=entry+direction*InpBreakevenPlusPoints*_Point;
         if(direction==1 && (oldSL==0 || be>proposedSL)) proposedSL=be;
         if(direction==-1 && (oldSL==0 || be<proposedSL)) proposedSL=be;
        }
      if(InpUseTrailing && move>=initialR*InpTrailAfterR)
        {
         double trailed=market-direction*atr*InpTrailATR;
         if(direction==1 && (oldSL==0 || trailed>proposedSL)) proposedSL=trailed;
         if(direction==-1 && (oldSL==0 || trailed<proposedSL)) proposedSL=trailed;
        }
      bool improves=(direction==1?proposedSL>oldSL+_Point:
                       oldSL==0 || proposedSL<oldSL-_Point);
      bool validDistance=(direction==1?
                          market-proposedSL>minDistance:
                          proposedSL-market>minDistance);
      if(improves && validDistance && proposedSL>0)
        {
         double rounded=NormalizeDouble(proposedSL,_Digits);
         if(!trade.PositionModify(ticket,rounded,tp) ||
            trade.ResultRetcode()!=TRADE_RETCODE_DONE)
            PrintFormat("GTProStyle stop modify failed %I64u: %s",
                        ticket,trade.ResultRetcodeDescription());
        }
     }
  }

void ProcessClosedBar()
  {
   int barsNeeded=MathMax(InpStructureLookback+InpPivotLeft+InpPivotRight+10,
                          InpInternalBreakBars+InpPivotRight+12);
   MqlRates r[];
   ArraySetAsSeries(r,true);
   int received=CopyRates(_Symbol,InpEntryTF,0,barsNeeded,r);
   if(received<InpPivotLeft+InpPivotRight+InpInternalBreakBars+12)
     { g_status="Waiting for M5 history"; return; }
   double atr=0.0,adx=0.0;
   if(!IndicatorValue(g_atrHandle,1,atr) || atr<=0.0)
     { g_status="Waiting for ATR"; return; }
   int trend=GetTrendDirection(adx);
   if(g_cooldown>0) g_cooldown--;

   double trendAnchor=0.0,reversalAnchor=0.0;
   int trendSignal=0,reversalSignal=0;
   if(InpStrategy==MODE_TREND || InpStrategy==MODE_HYBRID)
      trendSignal=ProcessTrend(r,received,trend,atr,trendAnchor);
   if(InpStrategy==MODE_REVERSAL || InpStrategy==MODE_HYBRID)
      reversalSignal=ProcessReversal(r,received,trend,reversalAnchor);

   if(trendSignal!=0)
      SubmitSignal(trendSignal,trendAnchor,atr,"BOS_FVG",r[1].time);
   else if(reversalSignal!=0)
      SubmitSignal(reversalSignal,reversalAnchor,atr,"SWEEP_CHOCH",r[1].time);
   else
      g_status="Watching | M15 trend="+IntegerToString(trend)+
               " ADX="+DoubleToString(adx,1);
  }

int OnInit()
  {
   if(InpPivotLeft<1 || InpPivotRight<1 || InpStructureLookback<20 ||
      InpInternalBreakBars<2 || InpFastEMA<2 || InpSlowEMA<=InpFastEMA ||
      InpATRPeriod<2 || InpRiskReward<=0 || InpRiskPercent<=0 ||
      InpMaxLot<=0 || InpMinStopATR<=0 ||
      InpMaxStopATR<InpMinStopATR)
     {
      Print("GTProStyle: invalid inputs");
      return INIT_PARAMETERS_INCORRECT;
     }
   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_fastHandle=iMA(_Symbol,InpTrendTF,InpFastEMA,0,MODE_EMA,PRICE_CLOSE);
   g_slowHandle=iMA(_Symbol,InpTrendTF,InpSlowEMA,0,MODE_EMA,PRICE_CLOSE);
   g_adxHandle=iADX(_Symbol,InpTrendTF,InpADXPeriod);
   g_atrHandle=iATR(_Symbol,InpEntryTF,InpATRPeriod);
   if(g_fastHandle==INVALID_HANDLE || g_slowHandle==INVALID_HANDLE ||
      g_adxHandle==INVALID_HANDLE || g_atrHandle==INVALID_HANDLE)
     {
      Print("GTProStyle indicator handle initialization failed");
      return INIT_FAILED;
     }
   g_fvg.active=false;
   g_sweep.active=false;
   g_lastBar=iTime(_Symbol,InpEntryTF,0);
   g_day=0;
   g_peakEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   UpdateEquityGuards();
   g_status="Initialized";
   Print("GTProStyle V1 initialized on ",_Symbol,". AutoTrade=",
         (InpEnableAutoTrading?"ON":"OFF"));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   Comment("");
   if(g_fastHandle!=INVALID_HANDLE) IndicatorRelease(g_fastHandle);
   if(g_slowHandle!=INVALID_HANDLE) IndicatorRelease(g_slowHandle);
   if(g_adxHandle!=INVALID_HANDLE) IndicatorRelease(g_adxHandle);
   if(g_atrHandle!=INVALID_HANDLE) IndicatorRelease(g_atrHandle);
  }

void OnTick()
  {
   UpdateEquityGuards();
   ManageOurPositions();
   datetime bar=iTime(_Symbol,InpEntryTF,0);
   if(bar!=0 && bar!=g_lastBar)
     {
      g_lastBar=bar;
      ProcessClosedBar();
     }
   Comment("GTPro Style EA v1 | ",_Symbol,
           "\nMode: ",EnumToString(InpStrategy),
           "\nAuto Trading: ",(InpEnableAutoTrading?"ON":"OFF"),
           "\nDaily lock: ",(g_dailyBlocked?"YES":"NO"),
           " | Peak DD lock: ",(g_equityBlocked?"YES":"NO"),
           "\n",g_status);
  }
//+------------------------------------------------------------------+
