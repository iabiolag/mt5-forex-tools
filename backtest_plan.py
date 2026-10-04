"""Backtest of a D1 trend-pullback plan on your broker's own price history.

    python backtest_plan.py                                  # all 28 major pairs, default rules
    python backtest_plan.py --pairs EURUSD GBPUSD            # only these pairs
    python backtest_plan.py --skip-balance 450 --risk 1      # also apply the SKIP rule

Rules tested (same maths as daily_range.py / the dashboard checklist):
  Trend    D1 trend score >= +0.5 with all three lookbacks up ("+ + +") -> buys only,
           <= -0.5 with "- - -" -> sells only (from candles closed before the entry morning).
  Pullback at least 2 of the last 5 daily candles (incl. the trigger) closed against the trend.
  Trigger  the last closed daily candle closed in the trend direction beyond the previous
           candle's high (buy) / low (sell).
  Entry    next trading morning at --entry-hour UTC (default 07:00), paying that hour's spread.
  SL / TP  --sl / --tp x the typical H4 candle (median of the 120 closed H4 candles before entry),
           or x the typical day with --sl-tf D1.
  Exit     SL, TP, D1 trend flips to the opposite side (closed next morning), or --max-days
           trading days (closed the morning after). SL/TP are checked hour by hour; if both are
           touched in the same hour the SL is assumed. A gap through SL/TP fills at the open.
  Limits   one trade per pair, max --max-open open, max --max-new new per day (strongest trend
           first). --skip-balance: skip a signal when even the minimum lot risks more than --risk %.
Not simulated: swap (assumes a swap-free account), commission, the daily/weekly loss stops.
Needs intraday (H1/H4) history - the test starts when your broker's intraday history starts.

Results are in R: 1R = the amount risked on a trade (e.g. 1% of the account).
Read-only: nothing here places, modifies or closes trades.
"""
import argparse, bisect, csv, datetime as dt, math, os, statistics as st, sys, time
import MetaTrader5 as mt5
import daily_range as dr

MAJORS = [p for p in dr.DEFAULT_SYMBOLS if p not in ("XAUUSD", "GBPSGD")]  # the 28 major pairs
HISTORY_BARS = {mt5.TIMEFRAME_D1: 5000, mt5.TIMEFRAME_H4: 25000, mt5.TIMEFRAME_H1: 90000}  # under the 100k chart limit
TREND_BARS = 600  # D1 candles fed to the trend score (EMA 120 has fully settled by then)
HERE = os.path.dirname(os.path.abspath(__file__))
utc = dt.datetime.utcfromtimestamp


def rates(sym, tf):
    """All history MT5 has for this timeframe, up to HISTORY_BARS (retry while it downloads)."""
    r = None
    for _ in range(5):
        r = mt5.copy_rates_from_pos(sym, tf, 0, HISTORY_BARS[tf])
        if r is not None and len(r):
            return r
        time.sleep(1)
    return r


def load_pair(pair, today):
    sym = dr.resolve(pair)
    if sym is None:
        return None
    mt5.symbol_select(sym, True)
    info = mt5.symbol_info(sym)
    d1, h4, h1 = rates(sym, mt5.TIMEFRAME_D1), rates(sym, mt5.TIMEFRAME_H4), rates(sym, mt5.TIMEFRAME_H1)
    if d1 is None or h4 is None or h1 is None or len(h1) < 2000:
        print(f"  {pair}: not enough history ({mt5.last_error()})")
        return None
    d1 = [r for r in d1 if utc(int(r["time"])).date() < today]  # closed daily candles only
    h1_t = [int(t) for t in h1["time"]]
    # Early history is often one bar per day even on H1. Intraday data starts at the first day
    # with at least 18 H1 bars.
    start = None
    for i in range(len(h1_t)):
        if bisect.bisect_left(h1_t, h1_t[i] + 86400) - i >= 18:
            start = utc(h1_t[i]).date()
            break
    pip, pip_value = dr.pip_info(sym)
    return {"pair": pair, "sym": sym, "info": info, "pip": pip, "pip_value": pip_value,
            "d1": d1, "h4": h4, "h4_t": [int(t) for t in h4["time"]], "h1": h1, "h1_t": h1_t,
            "intraday_from": start}


def trend_by_day(d):
    """Trend score as it looked each morning: day -> (score, comps) from candles closed before it."""
    d1, out = d["d1"], {}
    first = d["intraday_from"]
    for i in range(1, len(d1)):
        day = utc(int(d1[i]["time"])).date()
        if day >= first:
            out[day] = dr.trend_score(d1[max(0, i - TREND_BARS):i])
    return out


def signals(d, trend_on, a, mode):
    """Candidate trades for one pair. mode: 'last5' (plan), 'before5' (pullback window = the 5
    candles before the trigger) or 'trend' (every morning with a clean trend - baseline)."""
    d1, h1, h1_t, h4, h4_t = d["d1"], d["h1"], d["h1_t"], d["h4"], d["h4_t"]
    pip, point = d["pip"], d["info"].point
    wk = [r for r in d1 if utc(int(r["time"])).weekday() < 5]  # weekday candles
    begin = max(d["intraday_from"] + dt.timedelta(days=35), a.start)  # room for 120 closed H4 candles
    out = []
    for k in range(25, len(wk) - 1):
        c, prev = wk[k], wk[k - 1]
        day = utc(int(wk[k + 1]["time"])).date()  # entry morning = next trading day
        if day < begin:
            continue
        score, comps = trend_on.get(day, (None, None))
        if score is None:
            continue
        if score >= a.trend and all(x > 0 for x in comps):
            buy = True
        elif score <= -a.trend and all(x < 0 for x in comps):
            buy = False
        else:
            continue
        if mode != "trend":
            window = wk[k - 4:k + 1] if mode == "last5" else wk[k - 5:k]
            if sum(1 for r in window if (r["close"] < r["open"]) == buy) < 2:
                continue
            if buy and not (c["close"] > c["open"] and c["close"] > prev["high"]):
                continue
            if not buy and not (c["close"] < c["open"] and c["close"] < prev["low"]):
                continue
        t = out_trade(d, trend_on, a, buy, day, score, utc(int(c["time"])).date(), wk[k - 19:k + 1])
        if t:
            out.append(t)
    return out


def out_trade(d, trend_on, a, buy, day, score, signal_day, last20):
    h1, h1_t, h4, h4_t, pip, point = d["h1"], d["h1_t"], d["h4"], d["h4_t"], d["pip"], d["info"].point
    entry_ts = int(dt.datetime(day.year, day.month, day.day, a.entry_hour).replace(tzinfo=dt.timezone.utc).timestamp())
    j = bisect.bisect_left(h1_t, entry_ts)
    if j >= len(h1) or utc(h1_t[j]).date() != day:
        return None
    if a.sl_tf == "H4":
        idx = bisect.bisect_right(h4_t, h1_t[j] - 14400)  # H4 candles closed before entry
        if idx < 120:
            return None
        unit = st.median(float(b["high"] - b["low"]) for b in h4[idx - 120:idx])
    else:
        unit = st.median(float(r["high"] - r["low"]) for r in last20)
    sp = lambda bar: (int(bar["spread"]) or 1) * point
    bid = float(h1[j]["open"])
    entry = bid + sp(h1[j]) if buy else bid
    sl_d, tp_d = a.sl * unit, a.tp * unit
    sl = entry - sl_d if buy else entry + sl_d
    tp = entry + tp_d if buy else entry - tp_d

    exit_px = exit_t = reason = None
    days_held, last_day, checked = 0, day, day
    for h in range(j, len(h1)):
        bar, t = h1[h], utc(h1_t[h])
        if t.date() != last_day and t.weekday() < 5:
            last_day = t.date()
            days_held += 1
        o, hi, lo, s = float(bar["open"]), float(bar["high"]), float(bar["low"]), sp(bar)
        # morning check (once a day, first bar at/after the entry hour): trend flip / time stop
        if t.date() > checked and t.hour >= a.entry_hour and t.weekday() < 5:
            checked = t.date()
            sc, _ = trend_on.get(t.date(), (None, None))
            flip = sc is not None and (sc <= -a.trend if buy else sc >= a.trend)
            if flip or days_held > a.max_days:
                exit_px, exit_t, reason = (o if buy else o + s), t, "Trend flipped" if flip else f"{a.max_days} days"
                break
        if buy:  # exits on the bid
            if o <= sl or o >= tp:
                exit_px, exit_t, reason = o, t, "SL hit" if o <= sl else "TP hit"
            elif lo <= sl:
                exit_px, exit_t, reason = sl, t, "SL hit"
            elif hi >= tp:
                exit_px, exit_t, reason = tp, t, "TP hit"
        else:    # exits on the ask
            if o + s >= sl or o + s <= tp:
                exit_px, exit_t, reason = o + s, t, "SL hit" if o + s >= sl else "TP hit"
            elif hi + s >= sl:
                exit_px, exit_t, reason = sl, t, "SL hit"
            elif lo + s <= tp:
                exit_px, exit_t, reason = tp, t, "TP hit"
        if exit_px is not None:
            break
    if exit_px is None:
        last = h1[-1]
        exit_px = float(last["close"]) + (0 if buy else sp(last))
        exit_t, reason = utc(h1_t[-1]), "Still open"
    r_mult = ((exit_px - entry) if buy else (entry - exit_px)) / sl_d
    min_lot_loss = d["info"].volume_min * sl_d / pip * d["pip_value"]
    return {"pair": d["pair"], "side": "BUY" if buy else "SELL", "signal_candle": signal_day,
            "entry_time": utc(h1_t[j]), "entry": entry, "sl": sl, "tp": tp, "sl_pips": sl_d / pip,
            "exit_time": exit_t, "exit": exit_px, "reason": reason, "R": r_mult, "score": score,
            "min_lot_loss": min_lot_loss}


def exposure(t):
    base, quote, buy = t["pair"][:3], t["pair"][3:], t["side"] == "BUY"
    return {(base, buy), (quote, not buy)}


def portfolio(cands, a, skip_rule=True, same_ccy=True, limits=True):
    """Apply the plan's limits in time order (strongest trend first on the same morning).
    Returns taken trades; marks skipped signals with t['skip'] (on copies)."""
    taken, per_day, out = [], {}, []
    risk_money = a.skip_balance * a.risk / 100
    for t in sorted((dict(x) for x in cands), key=lambda t: (t["entry_time"], -abs(t["score"]))):
        now = t["entry_time"]
        open_ = [o for o in taken if o["exit_time"] > now]
        if any(o["pair"] == t["pair"] for o in open_):
            t["skip"] = "pair already open"
        elif skip_rule and a.skip_balance and t["min_lot_loss"] > risk_money:
            t["skip"] = "SKIP: SL too big for the minimum lot"
        elif limits and len(open_) >= a.max_open:
            t["skip"] = f"{a.max_open} trades already open"
        elif limits and per_day.get(now.date(), 0) >= a.max_new:
            t["skip"] = f"{a.max_new} new trades already that day"
        elif not same_ccy and any(exposure(t) & exposure(o) for o in open_):
            t["skip"] = "same currency, same direction already open"
        if "skip" not in t:
            taken.append(t)
            per_day[now.date()] = per_day.get(now.date(), 0) + 1
        out.append(t)
    return taken, out


def summary(ts):
    closed = [t for t in sorted(ts, key=lambda t: t["exit_time"]) if t["reason"] != "Still open"]
    n = len(closed)
    if not n:
        return None
    rs = [t["R"] for t in closed]
    wins = [r for r in rs if r > 0]
    gl = -sum(r for r in rs if r <= 0)
    eq = peak = dd = streak = worst = 0
    bal = 100.0
    for r in rs:
        eq += r
        peak = max(peak, eq)
        dd = max(dd, peak - eq)
        streak = streak + 1 if r <= 0 else 0
        worst = max(worst, streak)
        bal *= 1 + 0.01 * r
    avg = sum(rs) / n
    ci = 1.96 * st.stdev(rs) / math.sqrt(n) if n > 1 else float("inf")
    return {"n": n, "win": len(wins) / n * 100, "total": sum(rs), "avg": avg, "lo": avg - ci, "hi": avg + ci,
            "pf": sum(wins) / gl if gl else None, "dd": dd, "streak": worst, "acct": bal - 100}


HEAD = (f"  {'':44}{'Trades':>7}{'Win%':>6}{'Total':>9}{'Per trade':>10}{'95% range per trade':>22}"
        f"{'PF':>6}{'Max DD':>8}{'Loss run':>9}{'Account':>9}")


def show(title, ts):
    s = summary(ts)
    if not s:
        print(f"  {title:44}{'no closed trades':>20}")
        return s
    pf = f"{s['pf']:.2f}" if s["pf"] else "-"
    rng = f"{s['lo']:+.2f} to {s['hi']:+.2f}R"
    print(f"  {title:44}{s['n']:>7}{s['win']:>5.0f}%{s['total']:>+8.1f}R{s['avg']:>+9.3f}R{rng:>22}"
          f"{pf:>6}{s['dd']:>7.1f}R{s['streak']:>9}{s['acct']:>+8.0f}%")
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pairs", nargs="+", default=MAJORS)
    ap.add_argument("--sl-tf", choices=["H4", "D1"], default="H4")
    ap.add_argument("--sl", type=float, default=2.0)
    ap.add_argument("--tp", type=float, default=4.0)
    ap.add_argument("--trend", type=float, default=0.5)
    ap.add_argument("--max-days", type=int, default=15)
    ap.add_argument("--max-open", type=int, default=3)
    ap.add_argument("--max-new", type=int, default=2, help="Max new trades per day")
    ap.add_argument("--entry-hour", type=int, default=7, help="Entry hour, UTC/server time (default 7)")
    ap.add_argument("--skip-balance", type=float, default=0, help="Apply the SKIP rule for this balance (0 = off)")
    ap.add_argument("--risk", type=float, default=1.0)
    a = ap.parse_args()

    if not mt5.initialize():
        sys.exit(f"Could not connect to MT5 - is the terminal open and logged in? {mt5.last_error()}")
    today = dr.server_today()
    print(f"Backtesting {len(a.pairs)} pairs - SL {a.sl:g} / TP {a.tp:g} x typical {a.sl_tf} candle. "
          f"Loading history (a few minutes the first time)...")
    data = [d for d in (load_pair(p.upper(), today) for p in a.pairs) if d]
    mt5.shutdown()
    if not data:
        sys.exit("No usable history.")
    cands = {"last5": [], "before5": [], "trend": []}
    # Same test window for every pair: from when most pairs' intraday history starts
    starts = sorted(d["intraday_from"] for d in data)
    a.start = starts[len(starts) // 2] + dt.timedelta(days=35)
    for d in data:
        tr = trend_by_day(d)
        for mode in cands:
            cands[mode] += signals(d, tr, a, mode)
        print(f"  {d['pair']}: intraday history from {d['intraday_from']}, "
              f"{sum(1 for t in cands['last5'] if t['pair'] == d['pair'])} signals")
    first = min(t["entry_time"] for t in cands["last5"]).date()
    last = max(t["entry_time"] for t in cands["last5"]).date()

    plan, plan_all = portfolio(cands["last5"], a)
    every = portfolio(cands["last5"], a, skip_rule=False, limits=False)[0]
    line = "=" * 132
    print(f"\n{line}\nRESULTS  {first:%d %b %Y} - {last:%d %b %Y}   (R = amount risked; spreads included, swap not)\n{line}")
    print(HEAD)
    show("YOUR RULES (as the plan says)", plan)
    if a.skip_balance:
        show("  ...without the SKIP rule", portfolio(cands["last5"], a, skip_rule=False)[0])
    show("  ...pullback = 5 candles BEFORE the trigger", portfolio(cands["before5"], a)[0])
    show("  ...skipping same-currency trades", portfolio(cands["last5"], a, same_ccy=False)[0])
    show("Every signal (no limits, 1 per pair at a time)", every)
    show("BASELINE: trend only, no pullback/trigger", portfolio(cands["trend"], a, skip_rule=False, limits=False)[0])

    print(f"\n{line}\nBY YEAR\n{line}\n{HEAD}")
    for y in sorted({t["entry_time"].year for t in every}):
        show(f"{y} - your rules", [t for t in plan if t["entry_time"].year == y])
        show(f"{y} - every signal", [t for t in every if t["entry_time"].year == y])

    mid = first + (last - first) / 2
    print(f"\n{line}\nFIRST HALF vs SECOND HALF (split {mid:%d %b %Y})\n{line}\n{HEAD}")
    show("First half - every signal", [t for t in every if t["entry_time"].date() < mid])
    show("Second half - every signal", [t for t in every if t["entry_time"].date() >= mid])

    print(f"\n{line}\nBY PAIR (every signal, 1 per pair at a time)\n{line}\n{HEAD}")
    by_pair = sorted({t["pair"] for t in every}, key=lambda p: -(summary([t for t in every if t["pair"] == p]) or {"avg": -9})["avg"])
    for p in by_pair:
        show(p, [t for t in every if t["pair"] == p])

    closed = [t for t in plan if t["reason"] != "Still open"]
    print(f"\n{line}\nHOW TRADES ENDED (your rules)\n{line}")
    for reason in sorted({t["reason"] for t in closed}):
        ts = [t for t in closed if t["reason"] == reason]
        print(f"  {reason:16}{len(ts):>5} trades   average {sum(t['R'] for t in ts) / len(ts):+.2f}R")
    skipped = [t for t in plan_all if "skip" in t]
    print(f"  Signals skipped by the limits: {len(skipped)}")
    for why in sorted({t["skip"] for t in skipped}):
        print(f"      {why}: {sum(1 for t in skipped if t['skip'] == why)}")

    print("\nPer trade = average R per trade. 95% range = where the true average probably lies: if it")
    print("includes 0, the test cannot tell the rules apart from no edge. PF = R won / R lost.")
    print("Max DD = worst fall from a peak, in R. Account = result at 1% risk per trade, compounded.")

    out = os.path.join(HERE, "backtest_trades.csv")
    try:
        with open(out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["pair", "side", "signal_candle", "entry_time_utc", "entry", "sl", "tp", "sl_pips",
                        "exit_time_utc", "exit", "reason", "R", "trend_score", "taken_or_skipped"])
            for t in plan_all:
                w.writerow([t["pair"], t["side"], t["signal_candle"], f"{t['entry_time']:%Y-%m-%d %H:%M}",
                            round(t["entry"], 5), round(t["sl"], 5), round(t["tp"], 5), round(t["sl_pips"], 1),
                            f"{t['exit_time']:%Y-%m-%d %H:%M}", round(t["exit"], 5), t["reason"],
                            round(t["R"], 2), round(t["score"], 2), t.get("skip", "TAKEN")])
        print(f"\nEvery signal of your rules saved to {out} - check a few on your D1 charts.")
    except PermissionError:
        print(f"\nCould not save {out} - it is open in Excel. Close it and run again.")


if __name__ == "__main__":
    main()
