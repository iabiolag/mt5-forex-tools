# Phase 2 — Strategy Tester checklist

The EA is `Experts\DTF\DTF_EA.ex5`. One pair, daily bars, one position at a time.

The point of this phase is **not** to find a profitable setting. It is to confirm the
machinery is honest: that stops are where they should be, that R-multiples mean what they
say, and that the journal matches the tester's own report. Optimisation is phase 5, and
tuning for profit now is exactly the mistake the spec's anti-overfitting rules forbid.

---

## 1. Tester settings

| Setting | Value | Why |
|---|---|---|
| Expert | `DTF\DTF_EA` | |
| Symbol | `EURUSDm` for run 1 | Tightest spread, cleanest history |
| Period | **D1** | The EA refuses anything else |
| Modelling | **Every tick based on real ticks** | The trailing stop and the initial stop are intrabar events. "Open prices only" will model them wrong and flatter the results. |
| Deposit | **10000 USD** | A small account (a few hundred USD) often cannot size a single position at the minimum lot with D1 stops, so it produces zero trades and proves nothing. |
| Leverage | whatever your account uses | Affects the margin check only |
| Optimisation | **Disabled** | |
| Forward | **No** | We split by hand below |

**Spread:** do **not** use "Current". Set a fixed, slightly pessimistic spread so runs are
reproducible and you are not silently backtesting a 0.1-pip spread that never existed in
2011. Suggested floors: EURUSD 10 points, GBPUSD 15, JPY crosses 15, AUDNZD/EURCHF 25.
(Those are 5-digit points, so 10 points = 1.0 pip.)

**Swap and commission** must be on — carry is a real cost on daily holds, and the journal
records it in its own column so phase 4 can judge it.

---

## 2. Date ranges — in-sample vs out-of-sample

Per the spec's anti-overfitting rules, **design on the first window and do not look at the
second until the design is frozen.**

| Window | Range | Use |
|---|---|---|
| In-sample | **2010.01.01 → 2019.12.31** | Every decision, every inspection, every change |
| Out-of-sample | **2020.01.01 → today** | Run **once**, at the end, to confirm — not to iterate |

The OOS window includes the March 2020 volatility spike, which is a genuinely useful stress
test of the EXTREME-regime cutback.

Add ~1 year of lead-in: the EA needs **272 D1 bars** of warm-up before it can trade, so a
run starting 2010.01.01 makes its first decision around 2011.01. Either accept that or start
the run at 2009.01.01 and ignore the first year.

---

## 3. Data quality first

Before trusting any result: **Symbols → EURUSDm → Bars/Ticks**, and confirm real tick data
actually exists back to your start date. Broker history depth varies by symbol and account.
If real ticks only go back to, say, 2017, then say so — a "2010–2019" run on generated ticks
is not the test we think it is, and I would rather shorten the window than pretend.

Run the tester's own **history quality** figure and note it. Below ~90% is worth mentioning.

---

## 4. What to check on run 1 (EURUSDm, in-sample)

Correctness before performance. Open the **Results** tab and the journal CSV side by side.

1. **Trade count is plausible.** A daily trend system on one pair should make roughly
   5–20 trades a year. Hundreds means the new-bar gate is broken; two means the threshold is
   too high or warm-up ate the window.
2. **Every trade has a stop.** No position should ever appear without an SL.
3. **Losses cluster near −1R.** In the journal, `r_multiple` for `exit_reason = STOP` should
   sit close to −1.0 (slightly worse with spread/slippage). If stop losses are coming in at
   −1.8R, sizing and stop placement disagree and that is a bug, not a market.
4. **`net_profit / init_risk_money` equals `r_multiple`.** Recompute a few rows by hand.
5. **The journal's net sum matches the tester's net profit.** If they differ, the journal is
   missing trades or double-counting.
6. **Exit reasons are all represented** — you should see `STOP`, `TRAIL` and `SIGNAL` rows.
   If `TRAIL` never appears, the trailing stop is not engaging. If `STOP` never appears, the
   trail is too tight and is pre-empting the initial stop.
7. **`bars_held` is sane** — a trend follower should hold winners for weeks, not days.
   Check that winners have larger `bars_held` than losers. If not, the exits are backwards.
8. **`mfe_r` on losers.** Tells you whether losers never worked (`mfe_r` near 0) or worked
   and gave it all back (`mfe_r` > 1.5). The second pattern is an argument for a
   breakeven rule — which we would then have to test, not assume.

---

## 5. Then the expectancy numbers

Only after the above passes. From the **Results** tab, record:

- Total net profit, profit factor, expected payoff
- Maximal drawdown (both absolute and %)
- Total trades, win rate
- Sharpe (tester's own figure)

And from the journal: mean R of winners, mean R of losers, expectancy in R.

**Expectancy in R is the number that matters.** A trend system with a 35% win rate and
+0.25R expectancy is working exactly as designed. Win rate on its own is noise.

---

## 6. Repeat across pairs

Same settings, same window, one run each:

`EURUSDm`, `GBPUSDm`, `USDJPYm`, `AUDUSDm`, `USDCADm`, `AUDNZDm`, `EURJPYm`

A component survives only if it works across **most pairs**, not the best one. Expect some
pairs to lose money — that is normal for trend following and is what the phase 3 portfolio is
for. What would worry me is *every* pair losing, or one pair carrying the entire result.

---

## 7. Only then, out-of-sample

Freeze the settings. Run 2020→today on the same pairs. Compare expectancy in R, not profit.
A drop of a third is normal. A sign flip means the in-sample result was fitted.

---

## What to send back

1. Compile confirmation (or the MetaEditor errors).
2. Whether real tick history reaches 2010, and the history-quality %.
3. Run 1 (EURUSDm in-sample): the Results-tab summary, plus the first ~20 journal rows.
4. Any of checks 1–8 in section 4 that **failed** — those are bugs and I want them before
   any performance discussion.
5. `DTF_skips_*.csv` — the skip reasons and their counts. If it is 90% "below min lot", the
   deposit is still too small. If it is full of something unexpected, a filter is misfiring.

Both CSVs land in **Common Files** (`File → Open Data Folder` → up to `Terminal\Common\Files`,
or `C:\Users\<you>\AppData\Roaming\MetaQuotes\Terminal\Common\Files`).

---

## Known limitations in phase 2

Stated plainly so they are not mistaken for bugs:

- **One position at a time, one pair.** No pyramiding, no portfolio. Phase 3.
- **No news filter, no circuit breakers, no currency caps.** Phase 4.
- **ATR and the percentiles include broker Sunday stub bars**, which slightly distorts
  volatility on brokers that emit them. The EA refuses to *decide* on a Sunday bar
  (`InpSkipSundayBar`), but the indicators underneath still see it. Fixing that properly
  means a custom bar series; not worth it unless the journal shows it mattering.
- **`init_risk_money` is computed at fill**, so a partial fill or large slippage changes 1R
  for that trade. Correct, but it means R is not exactly the target 0.75% on every row.
- **Rows with `reconstructed = 1`** had their state rebuilt after a restart; their
  `r_multiple` is approximate. In a backtest this should never appear — if it does, that is
  a bug worth reporting.
