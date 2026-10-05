# Daily Trend-Following System for MT5

A systematic, daily-timeframe, trend-following forex system built as switchable modules so
each component can be proven or removed by backtest. The design target is **positive
expectancy**, not win rate: small capped losses, winners allowed to run, hard risk control
across a basket of pairs.

**Status: phase 2 complete — single-pair EA + chart indicator. Backtest only, not validated.**

---

See **[BACKTEST.md](BACKTEST.md)** for the phase 2 Strategy Tester checklist.

## Python tools (daily use)

Read-only helpers that pull data from a running, logged-in MT5 terminal through the
[`MetaTrader5`](https://pypi.org/project/MetaTrader5/) Python package (standard library
otherwise - no pandas). None of them place, modify or close trades. Each has a `.bat`
launcher (Windows) that reads your own rules from `settings.bat`.

| File | What it does |
|---|---|
| `daily_range.py` | Per-pair daily movement in pips, D1 trend score, MT5-style ATR(14), suggested SL/TP, lot size for 1% risk, open-trade risk check and stop-trading rules (day / week / month / balance floor) |
| `dashboard.py` + `dashboard.html` | The same numbers in the browser (`http://127.0.0.1:8765`): cards or full table, search by pair or currency, and a page per pair with the plan checklist, D1 chart, SL/TP prices, ATR cross-check and your history on that pair |
| `weekly_report.py` | Weekly report card: results and rule breaks graded against the trading plan |
| `pnl_report.py` | Profit and loss of every closed trade by day, week and month |
| `backtest_plan.py` | Backtest of the trading plan's entry rules on D1 history |
| `confirm_research.py` | Research harness: entry confirmations and exits on D1 (and `--only h4exits` on H4), in-sample vs out-of-sample |

### Set up for your own account

1. Install Python 3.10+ and the MT5 package: `pip install MetaTrader5`.
2. Open MetaTrader 5 and log in (the tools read from the running terminal).
3. Copy `settings.example.bat` to `settings.bat` and change the values to your plan:
   SL/TP style, risk per trade, daily/weekly/monthly stop rules, balance floor,
   allowed pairs, lot cap and max open trades. `settings.bat` is git-ignored.
4. Double-click `dashboard.bat` (browser) or `daily_range.bat` (terminal). On macOS/Linux
   run the `.py` files directly with the same flags - see `python daily_range.py --help`.

Adapting to another broker:

- **Symbol names** - `resolve()` in `daily_range.py` finds suffixed names such as `EURUSDm`.
  Add other suffixes there if your broker uses e.g. `EURUSD.pro`.
- **Pip sizes** - 5/3-digit pairs use 10 points per pip. Metals are set in `PIP_OVERRIDE`
  (gold 1 pip = 0.10, silver 0.01); change them if you count pips differently.
- **Pair list** - `DEFAULT_SYMBOLS` in `daily_range.py` (all 28 majors, gold and GBPSGD);
  any pair you have traded is added automatically.
- **Spreads in the backtests** - taken from your broker's own candle history (the `spread` field).

The CSV files the tools write (`daily_range.csv`, `pnl_trades.csv`, `weekly_report_trades.csv`,
`backtest_trades.csv`) contain your own account data or results and are git-ignored.

**Two terminals open?** Set `TERMINAL` in `settings.bat` to the `terminal64.exe` the launchers
should read (`--terminal` on the command line); otherwise the MT5 package attaches to whichever
terminal it finds first.

## Prop-firm mode (FTMO 1-Step)

`--prop` (in `daily_range.py` and `dashboard.py`, via `prop_rules.py`) adds the FTMO 1-Step
rules on top of your own:

- **Maximum Daily Loss** - equity must stay above the balance at 00:00 Prague time minus 3% of
  the initial capital. The day is counted in Prague time, not the broker's (FTMO's server is one
  hour ahead, so it resets at 01:00 on the MT5 clock).
- **Maximum Loss** - equity must stay above the highest Prague-midnight balance (or the initial
  capital) minus 10%. **Profit Target** - balance +10% with every trade closed.
- **Best Day** - the best day's closed profit as a share of all profitable days (max 50%), and
  how much more profit is needed when it is over.
- **Lot sizing** - risk is `--risk` % of the *initial* capital, halved within half of the max
  loss, and cut so that if every open SL and the new one are hit, equity is still
  `--prop-buffer` % above both limits. `--commission` (per lot, round trip) is part of the loss.

Launchers: `ftmo.bat` (terminal), `ftmo_dashboard.bat` (browser, port 8766, so it can run
next to the normal dashboard) and `ftmo_pnl.bat`, all reading `settings_ftmo.bat` (copy
`settings_ftmo.example.bat`; git-ignored). Other prop firms with the same rule shapes work
with `--prop-daily / --prop-max / --prop-target`; firms whose daily limit is on equity, or
counted on the broker's day, need changes in `prop_rules.py`.

## Trailing stop line (H4)

`DTF_TrailLine` draws, on an **H4** chart, where the stop loss of your open trade on that
symbol should be, and tells you when to move it. It never touches the trade - you move the SL.

- **Start:** 2 x the typical H4 candle from the entry (median high-low of the 120 H4 candles
  closed before the trade) - the same SL `daily_range.py --sl-tf H4 --sl 2` suggests.
- **Trail:** after every closed H4 candle the stop moves to the best price since entry minus
  that same distance. It only moves in the trade's favour and never repaints.
- **Panel:** "Move your SL from X to Y", "Your SL is ahead of the trail - nothing to do",
  "NO STOP LOSS", or "Price is through the trail - close", plus the D1 trend score with a
  warning when it turns against the trade (the tested rule closes the trade next morning).
- **Alerts:** a pop-up (optionally a push to the MT5 phone app) once per H4 candle when the
  SL should move, and once per day when the D1 trend turns.

Install: copy `MQL5\Indicators\DTF\DTF_TrailLine.mq5` next to `DTF_Dashboard.mq5`, compile
with F7, and drag it onto an H4 chart of the pair you are trading.

The browser dashboard shows the same trail (computed the same way in `dashboard.py`, `h4_trail`):
"move your SL" advice on the overview banner, a Trail stop column and advice box under
*My open trades* on the pair page, and the trail drawn in amber on the pair's daily chart.

Why this rule (`python confirm_research.py --only h4exits`, 29 pairs, plan-style trades,
chosen on 2021-2023 and checked on 2024-2026): versus a fixed 2R take profit it lost less
per trade in both periods (-0.024R vs -0.045R, then -0.073R vs -0.102R). It is a better way to
manage a trade, **not** an edge - none of the entries tested were profitable.

## Deliverables

| File | What it is |
|---|---|
| `MQL5/Include/DTF/Common.mqh` | Enums, clamp, percentile rank, pip size, symbol name resolution |
| `MQL5/Include/DTF/SignalEngine.mqh` | 3-lookback trend ensemble, output -1..+1 |
| `MQL5/Include/DTF/VolatilityRegime.mqh` | ATR percentile, Bollinger-width percentile, compression/expansion, regime |
| `MQL5/Include/DTF/RiskManager.mqh` | Stop distance -> lot size (lot step, min lot, margin cap) |
| `MQL5/Include/DTF/TradeManager.mqh` | Execution, ATR stop, chandelier trail, exit reasons, state persistence |
| `MQL5/Include/DTF/Journal.mqh` | CSV journal of trades and skipped signals |
| `MQL5/Indicators/DTF/DTF_Dashboard.mq5` | The chart indicator (phase 1) |
| `MQL5/Indicators/DTF/DTF_TrailLine.mq5` | Trailing-stop line for your own open trade, H4 (see below) |
| `MQL5/Experts/DTF/DTF_EA.mq5` | The single-pair EA (phase 2) |

The indicator is deliberately thin: all the maths lives in the `.mqh` modules, and the
phase-2 EA will include the **same** modules. If a number looks wrong on the chart, it is
wrong in the EA too — which is exactly why the indicator is built first.

---

## Install

1. In MetaEditor or MetaTrader, open **File -> Open Data Folder**. You land in the
   terminal data folder, which contains an `MQL5` directory.
2. Copy this repo's `MQL5\Include\DTF` folder to `<data folder>\MQL5\Include\DTF`.
3. Copy this repo's `MQL5\Indicators\DTF` folder to `<data folder>\MQL5\Indicators\DTF`.
4. In MetaEditor, open `Indicators\DTF\DTF_Dashboard.mq5` and press **F7** (Compile).
   Expect `0 errors, 0 warnings`. If the include paths fail, step 2 went to the wrong
   place — the includes resolve as `<DTF/Common.mqh>` relative to `MQL5\Include`.
5. Open a **D1** chart, drag `DTF_Dashboard` onto it.

**History requirement:** with default settings the indicator needs about **272 daily bars**
of warm-up (250-bar percentile window + 20-bar ATR) and will not draw before that. Give it
at least 400–500 D1 bars. If the subwindow stays empty, check the Experts log — it prints
exactly how many bars it wanted versus how many the chart has. In
*Tools -> Options -> Charts*, raise **Max bars in chart**, then scroll the chart back once
to force MT5 to download the history.

---

## How to read it

### Subwindow

* **Signal** — the thick histogram, the ensemble value in -1..+1. It is **green** when
  `signal >= threshold`, **red** when `signal <= -threshold`, **grey** when the pair is not
  tradeable. Dotted level lines mark `+threshold`, `0` and `-threshold`.
* **Fast / Mid / Slow** — the three lookback components as dotted lines. Use these to see
  *why* the ensemble is where it is: three lines stacked on one side is a clean multi-horizon
  trend; lines fanned across zero is disagreement, and the ensemble correctly refuses.
* **ATR pct/100** — off by default. The ATR percentile rescaled to 0..1 so it shares the
  subwindow's axis. Turn it on if you want the volatility history in visual form.

### Panel (top-left of the main chart)

```
DTF Dashboard  EURUSD  PERIOD_D1  [closed bar]
Signal        : +0.62  LONG   (threshold 0.50)
  components  : 20 +0.80   60 +0.55   120 +0.51
ATR(20)       : 0.00712  (71.2 pips)   pct 43
BB width pct  : 12   <<< COMPRESSION
Vol regime    : NORMAL   (risk x1.00)
Stop 3.0xATR  : 213.6 pips   long SL 1.06098 / short SL 1.10370
Risk          : 0.75% of 10000.00 USD = 75.00 USD
Lots          : 0.35   (actual risk 74.76 USD, margin 1225.00)
Bar           : 2026.09.24
```

* `[closed bar]` means every number is from the **last closed** daily bar — the same bar the
  EA will make its decision on. Set `InpUseClosedBar = false` to watch today's bar form, but
  do not plan trades off it: it repaints until the day closes.
* `actual risk` is what the **rounded** lot size really risks. It is always slightly under
  the target, because lots round *down* to the broker's lot step. Sizing never rounds up.
* `Lots: NO TRADE` with a reason is a real answer, not an error. The common one is
  *below min lot* — the account is too small for that stop distance at that risk %, and
  taking the minimum lot anyway would risk more than planned.
* `margin check unavailable in this context` is expected on some terminals: `OrderCalcMargin`
  is a trade function and indicators may be refused it. The lot size is still correct; only
  the margin column is unknown. The EA in phase 2 will get a real answer.

---

## Inputs

### Trend ensemble

| Input | Default | Meaning |
|---|---|---|
| `InpFastPeriod` | 20 | Short lookback, in daily bars |
| `InpMidPeriod` | 60 | Medium lookback |
| `InpSlowPeriod` | 120 | Long lookback |
| `InpSignalMode` | Both | `EMA distance only`, `Channel position only`, or `Both averaged` |
| `InpEmaAtrNorm` | 2.0 | How many ATRs of distance from the EMA count as a full +-1 |
| `InpSignalThreshold` | 0.5 | `abs(signal)` required to call a trade |

**How a component is scored.** For each lookback `L`:

* *EMA distance* = `clamp((close - EMA(L)) / (k * ATR * sqrt(L / ATRperiod)), -1, +1)`,
  where `k` is `InpEmaAtrNorm`. Dividing by ATR makes the score comparable across pairs.
  The `sqrt(L/ATRperiod)` term is random-walk scaling — over `L` bars price wanders roughly
  `sqrt(L)` further than over `ATRperiod` bars, so without it the 120-bar component would sit
  pinned at +-1 and stop carrying information. With it, one `k` serves all three lookbacks.
* *Channel position* = `2*(close - LL(L)) / (HH(L) - LL(L)) - 1`. +1 at a new `L`-bar high,
  -1 at a new low, 0 mid-range.
* In `Both` mode the two are averaged, then the three lookbacks are averaged **unweighted**.
  No fitted weights, so there is nothing to defend out-of-sample.

### Volatility regime

| Input | Default | Meaning |
|---|---|---|
| `InpAtrPeriod` | 20 | ATR period, also the stop basis |
| `InpBbPeriod` | 20 | Bollinger period for the width measure |
| `InpBbDeviation` | 2.0 | Bollinger deviations |
| `InpPercentileBars` | 250 | Percentile lookback — roughly one trading year |
| `InpCompressionPct` | 20 | BB-width percentile below this flags COMPRESSION |
| `InpExpansionPct` | 80 | BB-width percentile above this flags EXPANSION |
| `InpExtremeVolPct` | 90 | ATR percentile above this = EXTREME regime |
| `InpExtremeVolScale` | 0.5 | Risk multiplier applied in the EXTREME regime |

Percentiles rank the current bar against the `InpPercentileBars` bars **before** it — never
against itself and never against the future. The value drawn on a historical bar is the value
the EA would have seen live on that bar. Regime buckets: `<=30` LOW, `70..extreme` HIGH,
`>= InpExtremeVolPct` EXTREME, otherwise NORMAL.

### Risk and stops

| Input | Default | Meaning |
|---|---|---|
| `InpRiskPercent` | 0.75 | Risk per trade, % of equity |
| `InpAtrStopMult` | 3.0 | Initial stop distance = N x ATR |
| `InpMaxMarginPct` | 30 | Most of free margin one position may consume |
| `InpCheckMargin` | true | Run the margin check at all |
| `InpEquityOverride` | 0 | Size as if equity were this (0 = use live equity). Useful for planning a different account size without opening a demo. |

### Display

| Input | Default | Meaning |
|---|---|---|
| `InpUseClosedBar` | true | Read the last closed bar. Keep true for decisions. |
| `InpShowComponents` | true | Plot the three component lines |
| `InpShowAtrPct` | false | Plot the ATR percentile, scaled /100 |
| `InpShowPanel` | true | Draw the text panel |
| `InpPanelCorner` / `InpPanelX` / `InpPanelY` / `InpPanelFontSize` / `InpPanelTextColor` | | Panel placement and look |

---

## What to check and send back

Phase 1 has no backtest — an indicator has nothing to measure. What it needs is a
**correctness review**, because every number here becomes an EA decision in phase 2.

Please compile, then attach it to a few D1 charts and report:

1. **Compile result.** Paste the MetaEditor output if it is not `0 errors, 0 warnings`.
2. **One quiet trending pair and one wild one.** Suggested: EURUSD and GBPJPY. Paste the
   panel text for each. Particularly: does the lot size look sane next to what you would
   size by hand, and is `actual risk` within a lot-step of `InpRiskPercent` of equity?
3. **A JPY pair and a non-JPY pair.** The pip conversion and tick-value maths differ. If
   `ATR(x) pips` looks off by 10x anywhere, that is a `DTF_PipSize` bug and I want to know.
4. **Eyeball the signal against known moves.** Scroll to an obvious sustained trend — was
   the histogram green/red through it? Scroll to an obvious range — was it grey? I am not
   asking whether it is *profitable*, only whether it is *describing the chart honestly*.
5. **Compression flag.** Find a visible squeeze and confirm `<<< COMPRESSION` appears around
   it rather than after the breakout has already run.
6. **Does the margin line work** in your terminal, or does it say unavailable? Either is
   fine, I just want to know which.
7. **Does `k = 2.0` produce a sensible spread of signal values** on your pairs, or is the
   ensemble pinned near +-1 most of the time? If it is pinned, the normaliser is too small
   and I will raise the default.

---

## Roadmap

| Phase | Scope |
|---|---|
| 1. Done | Chart indicator: ensemble signal, ATR percentile/regime, compression flag, suggested stop and lot size |
| **2. Done** | Single-pair EA: signal + ATR stop + chandelier trail + risk sizing + CSV journal, with a full Strategy Tester checklist (real ticks, realistic spread, in-sample vs out-of-sample split) |
| 3 | Multi-symbol basket, currency-exposure netting and caps |
| 4 | News filter (live calendar + CSV backtest mode), swap/carry handling, drawdown circuit breakers, optional tick-volume check |
| 5 | Walk-forward plan and the Python journal analyser (expectancy in R, profit factor, max drawdown, per-pair and per-year breakdown, R-multiple distribution, Monte Carlo reshuffle) |

## Anti-overfitting rules this project follows

* Parameters are **not** tuned to maximise backtest profit. Round, robust defaults win ties.
* Out-of-sample data stays reserved: design on 2010–2019, confirm on 2020–present.
* A component is kept only if it improves results across **most pairs and both sample
  periods** — not one lucky pair, not one lucky decade.
