"""Profit & loss by day, week and month - every closed trade, from your MT5 account history.

Run with MT5 open and logged in:
    python pnl_report.py                     # this week's trades + daily / weekly / monthly tables
    python pnl_report.py --last-week         # show last week's trades in detail instead
    python pnl_report.py --week-of 2026-09-21  # the week containing this date
    python pnl_report.py --days 60           # how many days in the daily table (default 31)

A trade counts on the day it was CLOSED (broker time). Weeks run Monday-Sunday, months are
calendar months. $ amounts are net: profit + commission + swap + fees. Deposits and
withdrawals are not counted as profit. Open trades are shown separately (not yet won or lost).
Read-only: nothing here places, modifies or closes trades.
"""
import argparse, csv, datetime as dt, os, sys
import MetaTrader5 as mt5
import daily_range as dr

HERE = os.path.dirname(os.path.abspath(__file__))
REASON = {mt5.DEAL_REASON_SL: "SL hit", mt5.DEAL_REASON_TP: "TP hit", mt5.DEAL_REASON_SO: "Stop-out"}
utc = dt.datetime.utcfromtimestamp  # MT5 stamps deals in broker time as if it were UTC


def load_trades():
    """One record per closed position: entry/exit, pips, net $, and account balance around it."""
    deals = mt5.history_deals_get(dt.datetime(2000, 1, 1), dt.datetime.now() + dt.timedelta(days=2)) or []
    deals = sorted(deals, key=lambda d: (d.time_msc, d.ticket))
    pos, balance = {}, 0.0
    for d in deals:
        if d.type == mt5.DEAL_TYPE_BALANCE or not d.symbol:
            balance += d.profit  # deposit / withdrawal
            continue
        pl = d.profit + d.commission + d.swap + d.fee
        balance += pl
        if d.entry == mt5.DEAL_ENTRY_IN:
            p = pos.setdefault(d.position_id, {"net": 0.0, "exit_vol": 0.0, "exit_px_vol": 0.0})
            p.update(symbol=d.symbol, side="BUY" if d.type == mt5.DEAL_TYPE_BUY else "SELL",
                     lot=d.volume, opened=utc(d.time), entry=d.price, bal_before=balance - pl)
            p["net"] += pl
        elif d.entry in (mt5.DEAL_ENTRY_OUT, mt5.DEAL_ENTRY_OUT_BY):
            p = pos.setdefault(d.position_id, {"net": 0.0, "exit_vol": 0.0, "exit_px_vol": 0.0})
            p["net"] += pl
            p["exit_vol"] += d.volume
            p["exit_px_vol"] += d.price * d.volume
            p["closed"] = utc(d.time)
            p["how"] = REASON.get(d.reason, "Closed by you")
            p["bal_after"] = balance

    pip_cache, trades = {}, []
    for p in pos.values():
        if "closed" not in p or "entry" not in p:
            continue  # still open, or opened before the history starts
        sym = p["symbol"]
        if sym not in pip_cache:
            pip_cache[sym] = dr.pip_info(sym)[0]
        pip = pip_cache[sym]
        exit_px = p["exit_px_vol"] / p["exit_vol"] if p["exit_vol"] else p["entry"]
        move = exit_px - p["entry"] if p["side"] == "BUY" else p["entry"] - exit_px
        p.update(symbol=sym.removesuffix("m"), exit=exit_px, pips=move / pip if pip else None)
        trades.append(p)
    return sorted(trades, key=lambda t: t["closed"]), balance


def money(v):
    return f"{'+' if v >= 0 else '-'}${abs(v):.2f}"


def pips(v):
    return "-" if v is None else f"{v:+.1f}"


def summarise(ts):
    won = [t for t in ts if t["net"] > 0]
    start = ts[0]["bal_after"] - ts[0]["net"]
    known = [t["pips"] for t in ts if t["pips"] is not None]
    return {"n": len(ts), "won": len(won), "lost": len(ts) - len(won),
            "win": len(won) / len(ts) * 100, "net": sum(t["net"] for t in ts),
            "pips": sum(known) if known else None, "start": start, "end": ts[-1]["bal_after"],
            "best": max(t["net"] for t in ts), "worst": min(t["net"] for t in ts)}


HEAD = (f"{'Trades':>7}{'Won':>5}{'Lost':>5}{'Win%':>6}{'Pips':>9}{'Net $':>10}{'Net %':>8}"
        f"{'Best':>9}{'Worst':>9}{'Balance':>11}")


def row(label, s, width):
    pct = s["net"] / s["start"] * 100 if s["start"] > 0 else 0
    return (f"{label:<{width}}{s['n']:>7}{s['won']:>5}{s['lost']:>5}{s['win']:>5.0f}%{pips(s['pips']):>9}"
            f"{money(s['net']):>10}{pct:>+7.1f}%{money(s['best']):>9}{money(s['worst']):>9}{s['end']:>11.2f}")


def period_table(title, trades, key, label, width, last=None):
    groups = {}
    for t in trades:
        groups.setdefault(key(t["closed"].date()), []).append(t)
    keys = sorted(groups)[-last:] if last else sorted(groups)
    line = "=" * (width + 79)
    print(f"\n{line}\n{title}\n{line}")
    print(f"{'':<{width}}{HEAD}")
    for k in keys:
        s = summarise(groups[k])
        flag = "  <- green" if s["net"] > 0 else "  <- red" if s["net"] < 0 else ""
        print(row(label(k), s, width) + flag)
    green = sum(1 for k in keys if sum(t["net"] for t in groups[k]) > 0)
    print(f"{len(keys)} period(s) shown: {green} green, {len(keys) - green} red/flat. "
          f"Balance = account balance after the last trade closed in that period.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--last-week", action="store_true", help="Detail last week instead of this week")
    ap.add_argument("--week-of", help="Detail the week containing this date (YYYY-MM-DD)")
    ap.add_argument("--days", type=int, default=31, help="Days in the daily table (default 31, 0 = all)")
    args = ap.parse_args()

    if not mt5.initialize():
        sys.exit(f"Could not connect to MT5 - is the terminal open and logged in? {mt5.last_error()}")
    acc = mt5.account_info()
    trades, _ = load_trades()
    today = dr.server_today()
    open_pos = mt5.positions_get() or []
    mt5.shutdown()
    if not trades:
        sys.exit("No closed trades in this account's history yet.")

    monday = lambda d: d - dt.timedelta(days=d.weekday())
    if args.week_of:
        wk = monday(dt.date.fromisoformat(args.week_of))
    else:
        wk = monday(today) - dt.timedelta(days=7 if args.last_week else 0)
    wk_end = wk + dt.timedelta(days=6)

    print(f"\nPROFIT & LOSS - {acc.server if acc else ''} #{acc.login if acc else ''} - "
          f"{dt.datetime.now():%Y-%m-%d %H:%M}   (broker time; $ include commission/swap)")

    # Week in detail: every trade, grouped by day
    line = "=" * 108
    print(f"\n{line}\nWEEK {wk:%a %d %b} - {wk_end:%a %d %b %Y}: EVERY CLOSED TRADE\n{line}")
    week = [t for t in trades if wk <= t["closed"].date() <= wk_end]
    if not week:
        print("  No trades closed this week.")
    print(f"  {'Opened':13}{'Closed':13}{'Pair':9}{'Side':5}{'Lot':>6}{'Entry':>11}{'Exit':>11}"
          f"{'Pips':>8}{'Net $':>10}  How it closed")
    for day in (wk + dt.timedelta(days=i) for i in range(7)):
        ts = [t for t in week if t["closed"].date() == day]
        if not ts:
            continue
        print(f"  -- {day:%A %d %b} " + "-" * 40)
        for t in ts:
            print(f"  {t['opened']:%d %b %H:%M} {t['closed']:%d %b %H:%M} {t['symbol']:9}{t['side']:5}"
                  f"{t['lot']:>6.2f}{round(t['entry'], 5):>11g}{round(t['exit'], 5):>11g}{pips(t['pips']):>8}"
                  f"{money(t['net']):>10}  {t['how']}")
        s = summarise(ts)
        print(f"  {'Day total':>68}{pips(s['pips']):>8}{money(s['net']):>10}  "
              f"({s['won']} won, {s['lost']} lost)")
    if week:
        s = summarise(week)
        pct = s["net"] / s["start"] * 100 if s["start"] > 0 else 0
        print(f"  {'':-<106}")
        print(f"  {'WEEK TOTAL':>68}{pips(s['pips']):>8}{money(s['net']):>10}  "
              f"({s['n']} trades: {s['won']} won, {s['lost']} lost, {s['win']:.0f}% win rate)")
        print(f"  Balance {s['start']:.2f} -> {s['end']:.2f}  ({pct:+.1f}% this week)")
    if open_pos and wk <= today <= wk_end:
        floating = sum(p.profit + p.swap for p in open_pos)
        print(f"  Still open: {len(open_pos)} trade(s), floating {money(floating)} - not counted until closed.")

    period_table(f"DAILY (last {args.days} trading days)" if args.days else "DAILY", trades,
                 lambda d: d, lambda k: f"{k:%a %d %b %Y}", 16, args.days or None)
    period_table("WEEKLY (Monday - Sunday)", trades, monday, lambda k: f"Wk of {k:%d %b %Y}", 18)
    period_table("MONTHLY", trades, lambda d: d.replace(day=1), lambda k: f"{k:%B %Y}", 16)

    out = os.path.join(HERE, "pnl_trades.csv")
    try:
        with open(out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["opened", "closed", "close_day", "week_of", "month", "pair", "side", "lot",
                        "entry", "exit", "pips", "net_$", "how_closed", "balance_after"])
            for t in trades:
                d = t["closed"].date()
                w.writerow([f"{t['opened']:%Y-%m-%d %H:%M}", f"{t['closed']:%Y-%m-%d %H:%M}", d, monday(d),
                            f"{d:%Y-%m}", t["symbol"], t["side"], t["lot"], t["entry"], round(t["exit"], 6),
                            pips(t["pips"]), round(t["net"], 2), t["how"], round(t["bal_after"], 2)])
        print(f"\nEvery trade saved to {out} (open in Excel to filter by day / week / month).")
    except PermissionError:
        print(f"\nCould not save {out} - it is open in Excel. Close it and run again.")


if __name__ == "__main__":
    main()
