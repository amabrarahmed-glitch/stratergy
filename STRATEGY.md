# Liquidity Sweep Strategy (XAUUSD)

## Thesis

All obvious levels — support/resistance, equal highs/lows, session and daily
highs/lows, round numbers — are pools of resting orders (stops + breakout
entries). Large players push price *into* those pools to fill size against
trapped traders, then reverse. The edge is trading the reversal **after** the
trap is confirmed, not the breakout itself.

## Rules

### 1. Liquidity zones (H1, rebuilt every H1 bar)
- Swing highs/lows (5 bars each side), clustered — equal highs/lows within
  tolerance merge into one stronger zone.
- Previous day and previous week high/low.
- Round numbers every $50 near price (gold-specific).
- Zones above price = buy-side liquidity (short setups); below = sell-side
  (long setups). Drawn on chart: red = highs, blue = lows.

### 2. Sweep confirmation (M15, on bar close)
A zone is *swept* when a candle **wicks through it but closes back inside**,
on tick volume ≥ 1.5× the 20-bar average. A candle that closes beyond the
zone is a potential real breakout — no trade.

### 3. Entry trigger — CHoCH
After a sweep, wait up to 12 M15 bars for a close beyond the most recent
opposite M15 swing (change of character). If price instead takes out the
sweep wick, the setup is invalidated (real breakout) and we stand aside.

### 4. Trade construction
- **SL**: just beyond the sweep wick + 30-pip buffer (small by design).
- **TP**: nearest un-swept liquidity zone in the trade direction.
- Skip if R:R < 1.5.
- **Risk**: 0.5% of balance per trade, one position at a time.

### 5. Management
- At **+1R**: close 50%, move SL to breakeven.
- After breakeven: trail SL at 2× ATR(14) on M15.

### Filters
- London + NY only (07:00–21:00 server time).
- Max spread 60 pips (600 points).

## Files
- `LiquiditySweepEA.mq5` — the full Expert Advisor. Copy to
  `MQL5/Experts/`, compile in MetaEditor, attach to an XAUUSD M15 chart.

## Before going live
1. Backtest in the MT5 Strategy Tester (M15, "Every tick based on real ticks",
   ≥ 1 year of data).
2. Tune `InpEqualTolPts`, `InpZoneHeightPts`, `InpSLBufferPts` to your
   broker's XAUUSD point size (this assumes 1 point = 0.01).
3. Forward-test on demo for at least a few weeks.
