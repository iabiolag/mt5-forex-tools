"""Backtest of a sample D1 trend-pullback plan on your broker's own price history.

    python backtest_plan.py

Rules tested exactly as written in the plan:
  Trend    D1 trend score >= +0.5 with all three lookbacks up ("+ + +") -> buys only,
           <= -0.5 with "- - -" -> sells only. Same maths as daily_range.py / DTF indicator.
  Pullback at least 2 of the 5 daily candles before the trigger closed against the trend.
  Trigger  the last closed daily candle closed in the trend direction beyond the previous
           candle's high (buy) / low (sell).
  Entry    next trading morning at 07:00 UTC, paying the spread.
  SL / TP  1.5x / 3x typical day (median range of the last 20 daily candles).
  Exit     SL, TP, D1 trend flips to the opposite side (closed next morning), or 15 trading
           days (closed on the 16th morning). SL and TP are checked hour by hour; if both
           are touched in the same hour the SL is assumed (the pessimistic choice).
  Limits   one trade per pair, max 3 open, max 2 new per day, no two open trades on the
           same currency in the same direction.
Weekly/monthly loss stops are not simulated. The small Sunday candle is ignored for the
pullback/trigger checks (the trend score uses raw candles, like the chart indicator).

Results are in R: 1R = the amount risked on a trade (e.g. 1% of the account).
Read-only: nothing here places, modifies or closes trades.
"""
import csv, datetime as dt, os, statistics as st, sys
import MetaTrader5 as mt5
import daily_range as dr

PAIRS = ["EURUSD", "GBPUSD", "USDJPY", "AUDUSD", "EURJPY"]
# Typical retail spreads in normal hours, in pips (a little on the cautious side) - set your broker's.
SPREAD = {"EURUSD": 1.2, "GBPUSD": 1.5, "USDJPY": 1.4, "AUDUSD": 1.2, "EURJPY": 2.0}
WINDOWS = [("Oct 2024 - Sep 2025", dt.date(2024, 10, 1), dt.date(2025, 10, 1)),
           ("Oct 2025 - Sep 2026", dt.date(2025, 10, 1), dt.date(2026, 10, 1))]
SL_MULT, TP_MULT, TREND, MAX_DAYS = 1.5, 3.0, 0.5, 15
MAX_OPEN, MAX_NEW_PER_DAY, ENTRY_HOUR = 3, 2, 7
HERE = os.path.dirname(os.path.abspath(__file__))
date_of = lambda ts: dt.datetime.utcfromtimestamp(int(ts)).date()


def signals_and_paths(pair):
    sym = dr.resolve(pair)
    mt5.symbol_select(sym, True)
    info = mt5.symbol_info(sym)
    pip = dr.pip_size(sym, info)
    spread = SPREAD[pair] * pip
    d1 = dr.load_rates(sym, 1000)
    h1 = mt5.copy_rates_range(sym, mt5.TIMEFRAME_H1, dt.datetime(2024, 6, 1), dt.datetime.now())
    d1_dates = [date_of(r["time"]) for r in d1]

    # trend score as it looked each morning (from candles closed BEFORE that day)
    trend_on = {}
    first = WINDOWS[0][1] - dt.timedelta(days=5)
    for i in range(1, len(d1)):
        day = d1_dates[i]
        if day >= first:
            trend_on[day] = dr.trend_score(d1[:i])  # candles 0..i-1 are closed on day i

    wk = [(i, r) for i, r in enumerate(d1) if d1_dates[i].weekday() < 5]  # weekday candles
    h1_times = [dt.datetime.utcfromtimestamp(int(r["time"])) for r in h1]

    def entry_bar(day):
        for j, t in enumerate(h1_times):
            if t.date() == day and t.hour >= ENTRY_HOUR:
                return j
            if t.date() > day:
                return None
        return None

    trades = []
    for k in range(25, len(wk) - 1):
        i, c = wk[k]
        next_day = date_of(wk[k + 1][1]["time"])
        if next_day < WINDOWS[0][1] or next_day >= WINDOWS[-1][2]:
            continue
        score, comps = trend_on.get(next_day, (None, None))
        if score is None:
            continue
        if score >= TREND and all(x > 0 for x in comps):
            buy = True
        elif score <= -TREND and all(x < 0 for x in comps):
            buy = False
        else:
            continue
        prev = wk[k - 1][1]
        before = [r for _, r in wk[k - 5:k]]
        against = sum(1 for r in before if (r["close"] < r["open"]) == buy)
        if against < 2:
            continue
        if buy and not (c["close"] > c["open"] and c["close"] > prev["high"]):
            continue
        if not buy and not (c["close"] < c["open"] and c["close"] < prev["low"]):
            continue
        typical = st.median((r["high"] - r["low"]) for _, r in wk[k - 19:k + 1])
        j = entry_bar(next_day)
        if j is None:
            continue
        bid = h1[j]["open"]
        entry = bid + spread if buy else bid
        sl_d, tp_d = SL_MULT * typical, TP_MULT * typical
        sl = entry - sl_d if buy else entry + sl_d
        tp = entry + tp_d if buy else entry - tp_d

        # walk forward hour by hour
        exit_px = exit_t = reason = None
        days_held, last_day = 0, next_day
        for h in range(j, len(h1)):
            bar, t = h1[h], h1_times[h]
            if t.date() != last_day and t.weekday() < 5:
                last_day = t.date()
                days_held += 1  # trading days since the entry day
            # morning checks (trend flip / time stop) at the first bar at/after 07:00 of a new day
            if t.date() > next_day and t.hour == ENTRY_HOUR and t.weekday() < 5:
                sc, _ = trend_on.get(t.date(), (None, None))
                flip = sc is not None and (sc <= -TREND if buy else sc >= TREND)
                if flip or days_held > MAX_DAYS:
                    exit_px = bar["open"] if buy else bar["open"] + spread
                    exit_t, reason = t, "Trend flipped" if flip else "15 days"
                    break
            if buy:
                hit_sl, hit_tp = bar["low"] <= sl, bar["high"] >= tp
            else:
                hit_sl, hit_tp = bar["high"] + spread >= sl, bar["low"] + spread <= tp
            if hit_sl:
                exit_px, exit_t, reason = sl, t, "SL hit"
                break
            if hit_tp:
                exit_px, exit_t, reason = tp, t, "TP hit"
                break
        if exit_px is None:
            exit_px = h1[-1]["close"] if buy else h1[-1]["close"] + spread
            exit_t, reason = h1_times[-1], "Still open"
        r_mult = ((exit_px - entry) if buy else (entry - exit_px)) / sl_d
        trades.append({"pair": pair, "side": "BUY" if buy else "SELL", "signal_candle": date_of(c["time"]),
                       "entry_time": h1_times[j], "entry": entry, "sl": sl, "tp": tp,
                       "sl_pips": sl_d / pip, "exit_time": exit_t, "exit": exit_px, "reason": reason,
                       "R": r_mult, "score": score})
    return trades


def one_per_pair(cands):
    """Only the rule 'one trade per pair at a time' - used for the per-pair rows."""
    taken = []
    for t in sorted(cands, key=lambda t: t["entry_time"]):
        if not any(o["pair"] == t["pair"] and o["exit_time"] > t["entry_time"] for o in taken):
            taken.append(t)
    return taken


def portfolio(cands):
    """Apply the plan's portfolio limits in time order. Marks skipped signals with 'skip'."""
    taken, per_day = [], {}
    for t in sorted(cands, key=lambda t: t["entry_time"]):
        now = t["entry_time"]
        open_ = [o for o in taken if o["exit_time"] > now]
        if any(o["pair"] == t["pair"] for o in open_):
            t["skip"] = "pair already open"
        elif len(open_) >= MAX_OPEN:
            t["skip"] = "3 trades already open"
        elif per_day.get(now.date(), 0) >= MAX_NEW_PER_DAY:
            t["skip"] = "2 new trades already today"
        else:
            mine = exposure(t)
            if any(mine & exposure(o) for o in open_):
                t["skip"] = "same currency, same direction already open"
        if "skip" not in t:
            taken.append(t)
            per_day[now.date()] = per_day.get(now.date(), 0) + 1
    return taken


def exposure(t):
    base, quote = t["pair"][:3], t["pair"][3:]
    buy = t["side"] == "BUY"
    return {(base, buy), (quote, not buy)}


def summary(ts):
    closed = [t for t in ts if t["reason"] != "Still open"]
    n = len(closed)
    if not n:
        return None
    rs = [t["R"] for t in closed]
    wins = [r for r in rs if r > 0]
    gl = -sum(r for r in rs if r <= 0)
    eq, peak, dd, streak, worst_streak, bal = 0, 0, 0, 0, 0, 100.0
    for r in rs:
        eq += r
        peak = max(peak, eq)
        dd = max(dd, peak - eq)
        streak = streak + 1 if r <= 0 else 0
        worst_streak = max(worst_streak, streak)
        bal *= 1 + 0.01 * r
    return {"n": n, "win": len(wins) / n * 100, "total": sum(rs), "avg": sum(rs) / n,
            "pf": sum(wins) / gl if gl else None, "dd": dd, "streak": worst_streak, "acct": bal - 100}


def show(title, ts):
    s = summary(ts)
    if not s:
        print(f"  {title:28} no closed trades")
        return s
    pf = f"{s['pf']:.2f}" if s["pf"] else "-"
    print(f"  {title:28}{s['n']:>7}{s['win']:>6.0f}%{s['total']:>+9.1f}R{s['avg']:>+8.2f}R{pf:>7}"
          f"{s['dd']:>8.1f}R{s['streak']:>8}{s['acct']:>+10.1f}%")
    return s


def main():
    if not mt5.initialize():
        sys.exit(f"Could not connect to MT5 - is the terminal open and logged in? {mt5.last_error()}")
    print("Backtesting the sample plan on", ", ".join(PAIRS), "- this takes a minute...")
    cands = []
    for p in PAIRS:
        cands += signals_and_paths(p)
    mt5.shutdown()
    solo = one_per_pair(cands)
    taken = portfolio(cands)

    head = (f"  {'':28}{'Trades':>7}{'Win%':>7}{'Total':>10}{'Per trade':>9}{'PF':>7}{'Max DD':>9}"
            f"{'Loss run':>9}{'Account':>11}")
    line = "=" * 100
    for name, a, b in WINDOWS + [("BOTH YEARS", WINDOWS[0][1], WINDOWS[-1][2])]:
        in_w = lambda ts: [t for t in ts if a <= t["entry_time"].date() < b]
        print(f"\n{line}\n{name}\n{line}")
        print(head)
        show("Plan as written", in_w(taken))
        for p in PAIRS:
            show(f"  {p} on its own", [t for t in in_w(solo) if t["pair"] == p])

    all_t = [t for t in taken if t["reason"] != "Still open"]
    print(f"\n{line}\nHOW TRADES ENDED (plan as written, both years)\n{line}")
    for reason in ("TP hit", "SL hit", "Trend flipped", "15 days"):
        ts = [t for t in all_t if t["reason"] == reason]
        if ts:
            print(f"  {reason:16}{len(ts):>5} trades   average {sum(t['R'] for t in ts) / len(ts):+.2f}R")
    skipped = [t for t in cands if "skip" in t]
    print(f"  Signals skipped by the portfolio limits: {len(skipped)}")
    for why in sorted({t['skip'] for t in skipped}):
        print(f"      {why}: {sum(1 for t in skipped if t['skip'] == why)}")

    print("\nColumns: Win% = trades that made money. Total/Per trade in R (1R = amount risked).")
    print("PF = profit factor (R won / R lost; above 1 = profitable). Max DD = worst fall from a peak.")
    print("Loss run = longest string of losing trades. Account = result at 1% risk per trade.")

    out = os.path.join(HERE, "backtest_trades.csv")
    try:
        with open(out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["pair", "side", "signal_candle", "entry_time_utc", "entry", "sl", "tp", "sl_pips",
                        "exit_time_utc", "exit", "reason", "R", "trend_score", "taken_or_skipped"])
            for t in sorted(cands, key=lambda t: t["entry_time"]):
                w.writerow([t["pair"], t["side"], t["signal_candle"], f"{t['entry_time']:%Y-%m-%d %H:%M}",
                            round(t["entry"], 5), round(t["sl"], 5), round(t["tp"], 5), round(t["sl_pips"], 1),
                            f"{t['exit_time']:%Y-%m-%d %H:%M}", round(t["exit"], 5), t["reason"],
                            round(t["R"], 2), round(t["score"], 2), t.get("skip", "TAKEN")])
        print(f"\nEvery signal saved to {out} - open it and check a few on your D1 charts.")
    except PermissionError:
        print(f"\nCould not save {out} - it is open in Excel. Close it and run again.")


if __name__ == "__main__":
    main()
