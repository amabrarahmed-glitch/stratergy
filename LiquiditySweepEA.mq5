//+------------------------------------------------------------------+
//|                                            LiquiditySweepEA.mq5 |
//|  Liquidity Sweep / Stop-Hunt Reversal Strategy for XAUUSD        |
//|                                                                  |
//|  Concept:                                                        |
//|   1. Mark liquidity zones on H4/H1: swing highs/lows (equal      |
//|      highs/lows clusters), previous day/week high & low,         |
//|      session highs/lows, round numbers.                          |
//|   2. Wait for price to reach a zone on M15.                      |
//|   3. Confirm a SWEEP: candle wicks through the zone but closes   |
//|      back inside, ideally on a tick-volume spike (trapped        |
//|      breakout traders = the liquidity the whales wanted).        |
//|   4. Entry trigger: lower-timeframe change of character (CHoCH)  |
//|      -- price breaks the most recent M15 swing against the       |
//|      sweep direction.                                            |
//|   5. SL just beyond the sweep wick (+ buffer). TP = next         |
//|      liquidity zone. Partial close at 1R, SL to breakeven,       |
//|      then ATR trailing stop.                                     |
//+------------------------------------------------------------------+
#property copyright  "Liquidity Sweep Strategy"
#property version    "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- Zone building
input ENUM_TIMEFRAMES InpZoneTF          = PERIOD_H1;   // Timeframe for swing liquidity zones
input int             InpSwingBars       = 5;           // Bars each side to confirm a swing point
input int             InpZoneLookback    = 300;         // Bars of history scanned for zones
input double          InpEqualTolPts     = 400;         // Equal high/low cluster tolerance (points)
input double          InpZoneHeightPts   = 500;         // Zone height (points) around the level
input bool            InpUseDailyLevels  = true;        // Include prev day/week high & low
input bool            InpUseRoundNumbers = true;        // Include round numbers as zones
input double          InpRoundStep       = 50.0;        // Round number step in price (e.g. 50 = 3300/3350)

enum ENUM_ENTRY_MODE
  {
   ENTRY_CHOCH  = 0,   // Wait for LTF structure break (CHoCH)
   ENTRY_RETEST = 1    // Limit order at the swept zone (retest)
  };

//--- Sweep detection (M15)
input ENUM_TIMEFRAMES InpEntryTF         = PERIOD_M15;  // Entry timeframe
input ENUM_ENTRY_MODE InpEntryMode       = ENTRY_CHOCH; // Entry trigger after the sweep
input double          InpVolSpikeMult    = 1.5;         // Sweep volume must exceed avg volume x this
input int             InpVolAvgPeriod    = 20;          // Bars for average tick volume
input int             InpChochWindow     = 12;          // Max entry-TF bars to wait for CHoCH after sweep
input int             InpChochSwingBars  = 3;           // Bars each side for entry-TF swing points

//--- Risk & trade management
input double          InpRiskPercent     = 0.5;         // Risk per trade (% of balance)
input double          InpSLBufferPts     = 300;         // SL buffer beyond sweep wick (points)
input double          InpPartialAtR      = 1.0;         // Book partial at this R multiple
input double          InpPartialPct      = 50.0;        // % of position closed at partial
input int             InpTrailATRPeriod  = 14;          // ATR period for trailing stop (entry TF)
input double          InpTrailATRMult    = 2.0;         // Trailing distance = ATR x this
input double          InpMinRR           = 1.5;         // Skip trade if next zone gives worse R:R
input double          InpMaxSpreadPts    = 600;         // Max allowed spread (points)
input int             InpMaxPositions    = 1;           // Max simultaneous positions
input long            InpMagic           = 20260711;    // Magic number

//--- Session filter (server time)
input bool            InpUseSessionFilter = true;       // Trade only London + NY
input int             InpSessionStartHour = 7;          // Session start hour
input int             InpSessionEndHour   = 21;         // Session end hour

//+------------------------------------------------------------------+
struct LiquidityZone
  {
   double            top;
   double            bottom;
   bool              isHigh;      // buy-side liquidity above (highs) or sell-side below (lows)
   int               touches;     // equal highs/lows strength
   datetime          created;
   bool              swept;
  };

struct SweepState
  {
   bool              active;      // sweep confirmed, waiting for CHoCH
   bool              bullish;     // true = swept lows, looking to BUY
   double            sweepExtreme;// wick extreme of the sweep
   double            zoneRef;     // level of the swept zone
   datetime          sweepTime;
   int               barsWaited;
  };

CTrade         trade;
LiquidityZone  g_zones[];
SweepState     g_sweep;
datetime       g_lastEntryBar = 0;
datetime       g_lastZoneBar  = 0;
int            g_atrHandle    = INVALID_HANDLE;
bool           g_isTester     = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(100);
   ZeroMemory(g_sweep);
   g_isTester  = (bool)MQLInfoInteger(MQL_TESTER);
   g_atrHandle = iATR(_Symbol, InpEntryTF, InpTrailATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
      return INIT_FAILED;
   Print("LiquiditySweepEA initialized on ", _Symbol);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   ObjectsDeleteAll(0, "LSZ_");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // manage open positions every tick (partials + trailing)
   ManagePositions();

   // rebuild zones once per zone-TF bar
   datetime zoneBar = iTime(_Symbol, InpZoneTF, 0);
   if(zoneBar != g_lastZoneBar)
     {
      g_lastZoneBar = zoneBar;
      BuildZones();
     }

   // run signal logic once per entry-TF bar close
   datetime entryBar = iTime(_Symbol, InpEntryTF, 0);
   if(entryBar == g_lastEntryBar)
      return;
   g_lastEntryBar = entryBar;

   if(g_sweep.active)
      CheckChochAndEnter();
   else
      DetectSweep();
  }

//+------------------------------------------------------------------+
//| ZONE BUILDING                                                    |
//+------------------------------------------------------------------+
void BuildZones()
  {
   ArrayResize(g_zones, 0);

   //--- swing highs/lows on zone TF, clustered into equal-high/low pools
   double highs[], lows[];
   int bars = MathMin(InpZoneLookback, iBars(_Symbol, InpZoneTF) - InpSwingBars - 1);
   for(int i = InpSwingBars; i < bars; i++)
     {
      if(IsSwingHigh(InpZoneTF, i, InpSwingBars))
         AddLevel(highs, iHigh(_Symbol, InpZoneTF, i));
      if(IsSwingLow(InpZoneTF, i, InpSwingBars))
         AddLevel(lows, iLow(_Symbol, InpZoneTF, i));
     }
   ClusterIntoZones(highs, true);
   ClusterIntoZones(lows, false);


   //--- previous day / week high & low
   if(InpUseDailyLevels)
     {
      AddSimpleZone(iHigh(_Symbol, PERIOD_D1, 1), true,  2);
      AddSimpleZone(iLow(_Symbol,  PERIOD_D1, 1), false, 2);
      AddSimpleZone(iHigh(_Symbol, PERIOD_W1, 1), true,  3);
      AddSimpleZone(iLow(_Symbol,  PERIOD_W1, 1), false, 3);
     }

   //--- round numbers near current price
   if(InpUseRoundNumbers)
     {
      double px = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double base = MathFloor(px / InpRoundStep) * InpRoundStep;
      for(int k = -2; k <= 3; k++)
        {
         double lvl = base + k * InpRoundStep;
         AddSimpleZone(lvl, lvl > px, 1);
        }
     }

   if(!g_isTester)   // chart objects are dead weight in the Strategy Tester
      DrawZones();
  }

bool IsSwingHigh(ENUM_TIMEFRAMES tf, int bar, int side)
  {
   double h = iHigh(_Symbol, tf, bar);
   for(int j = 1; j <= side; j++)
      if(iHigh(_Symbol, tf, bar - j) > h || iHigh(_Symbol, tf, bar + j) > h)
         return false;
   return true;
  }

bool IsSwingLow(ENUM_TIMEFRAMES tf, int bar, int side)
  {
   double l = iLow(_Symbol, tf, bar);
   for(int j = 1; j <= side; j++)
      if(iLow(_Symbol, tf, bar - j) < l || iLow(_Symbol, tf, bar + j) < l)
         return false;
   return true;
  }

void AddLevel(double &arr[], double lvl)
  {
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = lvl;
  }

// cluster nearby levels: equal highs/lows are the strongest liquidity pools
void ClusterIntoZones(double &levels[], bool isHigh)
  {
   int n = ArraySize(levels);
   bool used[];
   ArrayResize(used, n);
   ArrayInitialize(used, false);
   double tol = InpEqualTolPts * _Point;

   for(int i = 0; i < n; i++)
     {
      if(used[i]) continue;
      double sum = levels[i];
      int cnt = 1;
      used[i] = true;
      for(int j = i + 1; j < n; j++)
        {
         if(!used[j] && MathAbs(levels[j] - levels[i]) <= tol)
           {
            sum += levels[j];
            cnt++;
            used[j] = true;
           }
        }
      AddSimpleZone(sum / cnt, isHigh, cnt);
     }
  }

void AddSimpleZone(double level, bool isHigh, int strength)
  {
   if(level <= 0) return;
   double half = InpZoneHeightPts * _Point / 2.0;
   int n = ArraySize(g_zones);
   ArrayResize(g_zones, n + 1);
   g_zones[n].top     = level + half;
   g_zones[n].bottom  = level - half;
   g_zones[n].isHigh  = isHigh;
   g_zones[n].touches = strength;
   g_zones[n].created = TimeCurrent();
   g_zones[n].swept   = false;
  }

//+------------------------------------------------------------------+
//| SWEEP DETECTION (on closed entry-TF bar)                         |
//+------------------------------------------------------------------+
void DetectSweep()
  {
   if(!SessionOK() || !SpreadOK())
      return;

   double o = iOpen(_Symbol,  InpEntryTF, 1);
   double h = iHigh(_Symbol,  InpEntryTF, 1);
   double l = iLow(_Symbol,   InpEntryTF, 1);
   double c = iClose(_Symbol, InpEntryTF, 1);

   //--- tick volume spike check
   long volSum = 0;
   for(int i = 2; i < 2 + InpVolAvgPeriod; i++)
      volSum += iTickVolume(_Symbol, InpEntryTF, i);
   double avgVol = (double)volSum / InpVolAvgPeriod;
   bool volSpike = iTickVolume(_Symbol, InpEntryTF, 1) >= avgVol * InpVolSpikeMult;

   for(int z = 0; z < ArraySize(g_zones); z++)
     {
      if(g_zones[z].swept) continue;

      // SWEEP OF HIGHS (buy-side liquidity taken -> look for SHORT):
      // wick pierces above the zone top, close back below it
      if(g_zones[z].isHigh && h > g_zones[z].top && c < g_zones[z].top && volSpike)
        {
         g_zones[z].swept = true;
         if(InpEntryMode == ENTRY_RETEST)
           {
            PlaceRetestOrder(false, g_zones[z].top, h);
            return;
           }
         g_sweep.active       = true;
         g_sweep.bullish      = false;
         g_sweep.sweepExtreme = h;
         g_sweep.zoneRef      = g_zones[z].top;
         g_sweep.sweepTime    = iTime(_Symbol, InpEntryTF, 1);
         g_sweep.barsWaited   = 0;
         Print("SWEEP of highs @ ", DoubleToString(g_zones[z].top, _Digits),
               " wick ", DoubleToString(h, _Digits), " -> hunting SHORT CHoCH");
         return;
        }

      // SWEEP OF LOWS (sell-side liquidity taken -> look for LONG)
      if(!g_zones[z].isHigh && l < g_zones[z].bottom && c > g_zones[z].bottom && volSpike)
        {
         g_zones[z].swept = true;
         if(InpEntryMode == ENTRY_RETEST)
           {
            PlaceRetestOrder(true, g_zones[z].bottom, l);
            return;
           }
         g_sweep.active       = true;
         g_sweep.bullish      = true;
         g_sweep.sweepExtreme = l;
         g_sweep.zoneRef      = g_zones[z].bottom;
         g_sweep.sweepTime    = iTime(_Symbol, InpEntryTF, 1);
         g_sweep.barsWaited   = 0;
         Print("SWEEP of lows @ ", DoubleToString(g_zones[z].bottom, _Digits),
               " wick ", DoubleToString(l, _Digits), " -> hunting LONG CHoCH");
         return;
        }
     }
  }

//+------------------------------------------------------------------+
//| CHOCH CONFIRMATION + ENTRY                                       |
//+------------------------------------------------------------------+
void CheckChochAndEnter()
  {
   g_sweep.barsWaited++;
   if(g_sweep.barsWaited > InpChochWindow)
     {
      Print("Sweep expired without CHoCH - reset");
      ZeroMemory(g_sweep);
      return;
     }

   // invalidation: price takes out the sweep extreme = real breakout, stand aside
   double c = iClose(_Symbol, InpEntryTF, 1);
   if((g_sweep.bullish && iLow(_Symbol, InpEntryTF, 1) < g_sweep.sweepExtreme) ||
      (!g_sweep.bullish && iHigh(_Symbol, InpEntryTF, 1) > g_sweep.sweepExtreme))
     {
      Print("Sweep extreme violated - real breakout, no trade");
      ZeroMemory(g_sweep);
      return;
     }

   // CHoCH: close beyond the most recent opposite swing formed before/at the sweep
   double swing = FindChochLevel();
   if(swing <= 0) return;

   bool choch = g_sweep.bullish ? (c > swing) : (c < swing);
   if(!choch) return;

   if(!SessionOK() || !SpreadOK() || CountMyPositions() >= InpMaxPositions)
     { ZeroMemory(g_sweep); return; }

   //--- build the trade
   bool  buy   = g_sweep.bullish;
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = buy ? ask : bid;
   double sl = buy ? g_sweep.sweepExtreme - InpSLBufferPts * _Point
                   : g_sweep.sweepExtreme + InpSLBufferPts * _Point;
   double tp = NextZoneTarget(buy, entry);

   double risk   = MathAbs(entry - sl);
   double reward = MathAbs(tp - entry);
   if(risk <= 0 || tp <= 0 || reward / risk < InpMinRR)
     {
      Print("Skipped: R:R ", DoubleToString(reward / MathMax(risk, _Point), 2),
            " below minimum ", InpMinRR);
      ZeroMemory(g_sweep);
      return;
     }

   double lots = LotsForRisk(risk);
   if(lots <= 0) { ZeroMemory(g_sweep); return; }

   bool ok = buy ? trade.Buy(lots, _Symbol, 0, sl, tp, "LSweep long")
                 : trade.Sell(lots, _Symbol, 0, sl, tp, "LSweep short");
   Print(ok ? "ENTRY " : "ENTRY FAILED ", buy ? "LONG " : "SHORT ",
         DoubleToString(lots, 2), " lots  SL=", DoubleToString(sl, _Digits),
         "  TP=", DoubleToString(tp, _Digits),
         "  R:R=", DoubleToString(reward / risk, 2));
   ZeroMemory(g_sweep);
  }

// RETEST mode: limit order at the swept zone edge, expiring after the wait window
void PlaceRetestOrder(bool buy, double zoneEdge, double sweepExtreme)
  {
   if(CountMyPositions() + CountMyPendings() >= InpMaxPositions)
      return;

   double entry = NormalizeDouble(zoneEdge, _Digits);
   double sl = buy ? sweepExtreme - InpSLBufferPts * _Point
                   : sweepExtreme + InpSLBufferPts * _Point;
   double tp = NextZoneTarget(buy, entry);
   double risk   = MathAbs(entry - sl);
   double reward = (tp > 0) ? MathAbs(tp - entry) : 0;
   if(risk <= 0 || tp <= 0 || reward / risk < InpMinRR)
     {
      Print("Retest order skipped: R:R ", DoubleToString(reward / MathMax(risk, _Point), 2),
            " below minimum ", InpMinRR);
      return;
     }
   double lots = LotsForRisk(risk);
   if(lots <= 0) return;

   datetime expiry = TimeCurrent() + InpChochWindow * PeriodSeconds(InpEntryTF);
   bool ok = buy ? trade.BuyLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry, "LSweep retest long")
                 : trade.SellLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry, "LSweep retest short");
   Print(ok ? "RETEST ORDER " : "RETEST ORDER FAILED ", buy ? "BUY LIMIT " : "SELL LIMIT ",
         DoubleToString(lots, 2), " @ ", DoubleToString(entry, _Digits),
         "  SL=", DoubleToString(sl, _Digits), "  TP=", DoubleToString(tp, _Digits),
         "  R:R=", DoubleToString(reward / risk, 2));
  }

int CountMyPendings()
  {
   int cnt = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t != 0 && OrderGetInteger(ORDER_MAGIC) == InpMagic &&
         OrderGetString(ORDER_SYMBOL) == _Symbol)
         cnt++;
     }
   return cnt;
  }

// most recent entry-TF swing against the sweep direction (the CHoCH trigger)
double FindChochLevel()
  {
   int maxScan = InpChochWindow + 20;
   for(int i = InpChochSwingBars + 1; i < maxScan; i++)
     {
      if(g_sweep.bullish && IsSwingHigh(InpEntryTF, i, InpChochSwingBars))
         return iHigh(_Symbol, InpEntryTF, i);
      if(!g_sweep.bullish && IsSwingLow(InpEntryTF, i, InpChochSwingBars))
         return iLow(_Symbol, InpEntryTF, i);
     }
   return 0;
  }

// TP = nearest un-swept liquidity zone in the trade direction
double NextZoneTarget(bool buy, double entry)
  {
   double best = 0;
   for(int z = 0; z < ArraySize(g_zones); z++)
     {
      if(g_zones[z].swept) continue;
      if(buy && g_zones[z].isHigh && g_zones[z].bottom > entry)
         if(best == 0 || g_zones[z].bottom < best)
            best = g_zones[z].bottom;
      if(!buy && !g_zones[z].isHigh && g_zones[z].top < entry)
         if(best == 0 || g_zones[z].top > best)
            best = g_zones[z].top;
     }
   return best;
  }

//+------------------------------------------------------------------+
//| POSITION MANAGEMENT: partial at 1R, BE, ATR trail                |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;

      bool   buy   = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double cur   = buy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double vol   = PositionGetDouble(POSITION_VOLUME);
      double riskD = MathAbs(open - sl);
      if(riskD <= 0) continue;
      double rMult = buy ? (cur - open) / riskD : (open - cur) / riskD;

      // partial booking + SL to breakeven (breakeven state = SL at/beyond open)
      bool beDone = buy ? (sl >= open) : (sl <= open && sl > 0);
      if(!beDone && rMult >= InpPartialAtR)
        {
         double closeVol = NormalizeLots(vol * InpPartialPct / 100.0);
         if(closeVol >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN) && closeVol < vol)
            trade.PositionClosePartial(ticket, closeVol);
         trade.PositionModify(ticket, open, PositionGetDouble(POSITION_TP));
         Print("Partial booked @ ", DoubleToString(rMult, 2), "R, SL -> breakeven");
         continue;
        }

      // ATR trailing after breakeven
      if(beDone)
        {
         double atrBuf[];
         if(CopyBuffer(g_atrHandle, 0, 1, 1, atrBuf) == 1)
           {
            double trail = atrBuf[0] * InpTrailATRMult;
            double newSL = buy ? cur - trail : cur + trail;
            double minStep = 5 * _Point;
            if((buy && newSL > sl + minStep) || (!buy && newSL < sl - minStep))
               trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits),
                                    PositionGetDouble(POSITION_TP));
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| HELPERS                                                          |
//+------------------------------------------------------------------+
double LotsForRisk(double slDistance)
  {
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSize <= 0) return 0;
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double lossPerLot = slDistance / tickSize * tickVal;
   if(lossPerLot <= 0) return 0;
   return NormalizeLots(riskMoney / lossPerLot);
  }

double NormalizeLots(double lots)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   return MathMax(minL, MathMin(maxL, lots));
  }

int CountMyPositions()
  {
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t != 0 && PositionSelectByTicket(t) &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         cnt++;
     }
   return cnt;
  }

bool SessionOK()
  {
   if(!InpUseSessionFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour;
  }

bool SpreadOK()
  {
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPts;
  }

void DrawZones()
  {
   ObjectsDeleteAll(0, "LSZ_");
   datetime t0 = iTime(_Symbol, InpZoneTF, MathMin(InpZoneLookback, iBars(_Symbol, InpZoneTF) - 1));
   datetime t1 = TimeCurrent() + PeriodSeconds(InpZoneTF) * 50;
   for(int z = 0; z < ArraySize(g_zones); z++)
     {
      string name = "LSZ_" + IntegerToString(z);
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t0, g_zones[z].top, t1, g_zones[z].bottom);
      color col = g_zones[z].isHigh ? clrCrimson : clrDodgerBlue;
      ObjectSetInteger(0, name, OBJPROP_COLOR, col);
      ObjectSetInteger(0, name, OBJPROP_FILL, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, g_zones[z].touches >= 2 ? 2 : 1);
     }
  }
//+------------------------------------------------------------------+
