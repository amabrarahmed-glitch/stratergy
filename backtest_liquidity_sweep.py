#!/usr/bin/env python3
"""
Python port of LiquiditySweepEA.mq5 for offline smoke-testing.

Same mechanics as the EA: liquidity zones from clustered swing highs/lows,
sweep = wick through zone + close back inside on a volume spike, entry on
CHoCH (close beyond last opposite swing), SL beyond sweep wick, TP at next
zone, 50% partial at 1R + breakeven, then ATR trailing stop.

Data: OHLCV csv (time,open,high,low,close,volume). Distance parameters are
ATR-scaled so the same logic runs on any timeframe's bars.

NOT a substitute for the MT5 real-tick Strategy Tester run - intrabar
fill ordering is approximated conservatively (SL checked before TP when
both are inside one bar's range).
"""
import csv, math, sys
from dataclasses import dataclass, field

# ---------------- parameters (ATR-scaled analogues of the EA inputs) ----
SWING_BARS      = 5
ZONE_LOOKBACK   = 150
EQ_TOL_ATR      = 0.30    # equal high/low cluster tolerance, x ATR
ZONE_H_ATR      = 0.40    # zone height, x ATR
VOL_SPIKE_MULT  = 1.5
VOL_AVG_PERIOD  = 20
CHOCH_WINDOW    = 12
CHOCH_SWING     = 3
RISK_PCT        = 0.5
SL_BUF_ATR      = 0.25
PARTIAL_AT_R    = 1.0
PARTIAL_PCT     = 50.0
TRAIL_ATR_MULT  = 2.0
MIN_RR          = 1.5
ATR_PERIOD      = 14
DEPOSIT         = 10_000.0

@dataclass
class Zone:
    level: float; is_high: bool; touches: int; swept: bool = False

@dataclass
class Trade:
    dir: int; entry: float; sl: float; tp: float; risk_d: float
    size: float                      # $ P/L per $1 of price move
    open_i: int
    partial_done: bool = False
    realized: float = 0.0

def load(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            rows.append(dict(t=r["time"], o=float(r["open"]), h=float(r["high"]),
                             l=float(r["low"]), c=float(r["close"]), v=float(r["volume"])))
    return rows

def atr(rows, i, n=ATR_PERIOD):
    if i < n + 1: return None
    s = 0.0
    for k in range(i - n + 1, i + 1):
        s += max(rows[k]["h"] - rows[k]["l"],
                 abs(rows[k]["h"] - rows[k-1]["c"]),
                 abs(rows[k]["l"] - rows[k-1]["c"]))
    return s / n

def is_swing_high(rows, i, side):
    if i - side < 0 or i + side >= len(rows): return False
    return all(rows[i]["h"] >= rows[i+j]["h"] and rows[i]["h"] >= rows[i-j]["h"]
               and (rows[i]["h"] > rows[i+j]["h"] or rows[i]["h"] > rows[i-j]["h"])
               for j in range(1, side + 1))

def is_swing_low(rows, i, side):
    if i - side < 0 or i + side >= len(rows): return False
    return all(rows[i]["l"] <= rows[i+j]["l"] and rows[i]["l"] <= rows[i-j]["l"]
               and (rows[i]["l"] < rows[i+j]["l"] or rows[i]["l"] < rows[i-j]["l"])
               for j in range(1, side + 1))

def build_zones(rows, i, a):
    highs, lows = [], []
    lo = max(SWING_BARS, i - ZONE_LOOKBACK)
    for k in range(lo, i - SWING_BARS):
        if is_swing_high(rows, k, SWING_BARS): highs.append(rows[k]["h"])
        if is_swing_low(rows, k, SWING_BARS):  lows.append(rows[k]["l"])
    zones = []
    tol = EQ_TOL_ATR * a
    for levels, is_high in ((highs, True), (lows, False)):
        used = [False] * len(levels)
        for x in range(len(levels)):
            if used[x]: continue
            cluster = [levels[x]]; used[x] = True
            for y in range(x + 1, len(levels)):
                if not used[y] and abs(levels[y] - levels[x]) <= tol:
                    cluster.append(levels[y]); used[y] = True
            zones.append(Zone(sum(cluster) / len(cluster), is_high, len(cluster)))
    return zones

def next_zone_target(zones, buy, entry):
    best = None
    for z in zones:
        if z.swept: continue
        if buy and z.is_high and z.level > entry and (best is None or z.level < best):
            best = z.level
        if not buy and not z.is_high and z.level < entry and (best is None or z.level > best):
            best = z.level
    return best

def run(path):
    rows = load(path)
    balance = DEPOSIT
    peak = balance; max_dd = 0.0
    wins = losses = 0; gross_w = gross_l = 0.0
    trades_closed = 0
    zones = []
    sweep = None          # (bullish, extreme, bar_index)
    pos = None
    equity_curve = []

    for i in range(ATR_PERIOD + SWING_BARS + 2, len(rows)):
        bar = rows[i]; a = atr(rows, i - 1)
        if a is None: continue

        # ---- manage open position on this bar (conservative: SL first) --
        if pos:
            d = pos.dir
            hit_sl = (bar["l"] <= pos.sl) if d > 0 else (bar["h"] >= pos.sl)
            hit_tp = (bar["h"] >= pos.tp) if d > 0 else (bar["l"] <= pos.tp)
            # partial at 1R + move SL to BE (checked on favourable excursion)
            fav = (bar["h"] - pos.entry) if d > 0 else (pos.entry - bar["l"])
            if not pos.partial_done and fav >= PARTIAL_AT_R * pos.risk_d:
                part = pos.size * PARTIAL_PCT / 100.0
                pos.realized += part * PARTIAL_AT_R * pos.risk_d
                pos.size -= part
                pos.sl = pos.entry
                pos.partial_done = True
                hit_sl = (bar["l"] <= pos.sl) if d > 0 else (bar["h"] >= pos.sl)
            if hit_sl:
                pnl = pos.realized + pos.size * (pos.sl - pos.entry) * d
            elif hit_tp:
                pnl = pos.realized + pos.size * (pos.tp - pos.entry) * d
            else:
                pnl = None
                # ATR trail after BE
                if pos.partial_done:
                    trail = TRAIL_ATR_MULT * a
                    new_sl = bar["c"] - trail * d
                    if (new_sl - pos.sl) * d > 0: pos.sl = new_sl
            if pnl is not None:
                balance += pnl; trades_closed += 1
                if pnl >= 0: wins += 1; gross_w += pnl
                else: losses += 1; gross_l -= pnl
                pos = None

        peak = max(peak, balance)
        max_dd = max(max_dd, (peak - balance) / peak * 100)
        equity_curve.append(balance)

        # ---- rebuild zones every 5 bars (EA: every zone-TF bar) ---------
        if i % 5 == 0 or not zones:
            swept_lv = {(round(z.level, 2)) for z in zones if z.swept}
            zones = build_zones(rows, i, a)
            for z in zones:
                if round(z.level, 2) in swept_lv: z.swept = True

        if pos: continue

        # ---- CHoCH check if a sweep is armed ----------------------------
        if sweep:
            bullish, extreme, s_i = sweep
            if i - s_i > CHOCH_WINDOW: sweep = None
            elif (bullish and bar["l"] < extreme) or (not bullish and bar["h"] > extreme):
                sweep = None                     # real breakout, stand aside
            else:
                lvl = None
                for k in range(i - CHOCH_SWING - 1, max(s_i - 20, SWING_BARS), -1):
                    if bullish and is_swing_high(rows, k, CHOCH_SWING): lvl = rows[k]["h"]; break
                    if not bullish and is_swing_low(rows, k, CHOCH_SWING): lvl = rows[k]["l"]; break
                if lvl and ((bullish and bar["c"] > lvl) or (not bullish and bar["c"] < lvl)):
                    d = 1 if bullish else -1
                    entry = bar["c"]
                    sl = extreme - d * SL_BUF_ATR * a
                    tp = next_zone_target(zones, bullish, entry)
                    risk_d = abs(entry - sl)
                    if tp and risk_d > 0 and abs(tp - entry) / risk_d >= MIN_RR:
                        size = balance * RISK_PCT / 100.0 / risk_d
                        pos = Trade(d, entry, sl, tp, risk_d, size, i)
                    sweep = None
            if pos or sweep: continue

        # ---- sweep detection on this closed bar -------------------------
        v_avg = sum(r["v"] for r in rows[i - VOL_AVG_PERIOD:i]) / VOL_AVG_PERIOD
        if bar["v"] < VOL_SPIKE_MULT * v_avg: continue
        half = ZONE_H_ATR * a / 2
        for z in zones:
            if z.swept: continue
            top, bot = z.level + half, z.level - half
            if z.is_high and bar["h"] > top and bar["c"] < top:
                z.swept = True; sweep = (False, bar["h"], i); break
            if not z.is_high and bar["l"] < bot and bar["c"] > bot:
                z.swept = True; sweep = (True, bar["l"], i); break

    pf = (gross_w / gross_l) if gross_l > 0 else float("inf")
    print(f"Bars: {len(rows)}   period: {rows[0]['t']} -> {rows[-1]['t']}")
    print(f"Closed trades : {trades_closed}  (wins {wins} / losses {losses}, "
          f"win rate {100*wins/max(trades_closed,1):.1f}%)")
    print(f"Net profit    : {balance - DEPOSIT:+,.2f}  ({(balance/DEPOSIT-1)*100:+.1f}%)")
    print(f"Profit factor : {pf:.2f}")
    print(f"Max balance DD: {max_dd:.2f}%")
    print(f"Final balance : {balance:,.2f}")

if __name__ == "__main__":
    run(sys.argv[1] if len(sys.argv) > 1 else
        "/workspace/ea-lab/mt5_strategies/XAUUSD_1d_2yr_sample.csv")
