"""Weekly report card: are you improving? Built from your MT5 account history.

Run with MT5 open and logged in:
    python weekly_report.py                  # every week in your history
    python weekly_report.py --weeks 4        # only the last 4 weeks
    python weekly_report.py --max-trades 3 --max-loss 3 --max-losses 3 --risk 1
                                             # the rules it grades you against (same defaults
                                             # as daily_range.py)
    python weekly_report.py --pairs EURUSD GBPUSD --max-lot 0.05 --max-open 3 --floor 800
                                             # your trading plan's rules (pair list, lot cap,
                                             # open-trade cap, hard balance floor)

Read-only: nothing here places, modifies or closes trades.
"""
import argparse, csv, datetime as dt, os, statistics as st, sys
import MetaTrader5 as mt5
import daily_range as dr

HERE = os.path.dirname(os.path.abspath(__file__))
REASON = {mt5.DEAL_REASON_SL: "SL hit", mt5.DEAL_REASON_TP: "TP hit", mt5.DEAL_REASON_SO: "Stop-out"}


def server_date(ts):
    return dt.datetime.utcfromtimestamp(ts).date()


def week_start(d):
    return d - dt.timedelta(days=d.weekday())


def load_trades(args):
    """One record per closed position, plus the rule checks as they stood when it was opened."""
    deals = mt5.history_deals_get(dt.datetime(2000, 1, 1), dt.datetime.now() + dt.timedelta(days=2)) or []
    deals = sorted(deals, key=lambda d: (d.time_msc, d.ticket))
    entries, exits = {}, {}
    for d in deals:
        if d.entry == mt5.DEAL_ENTRY_IN and d.symbol:
            entries[d.position_id] = d
        elif d.entry in (mt5.DEAL_ENTRY_OUT, mt5.DEAL_ENTRY_OUT_BY) and d.symbol:
            exits.setdefault(d.position_id, []).append(d)

    rates_cache = {}

    def trend_at(sym, day):
        """Trend score from the candles that had CLOSED before the entry day - what you could see."""
        if sym not in rates_cache:
            rates_cache[sym] = dr.load_rates(sym)
        rates = rates_cache[sym]
        if rates is None:
            return None
        closed = [r for r in rates if server_date(int(r["time"])) < day]
        return dr.trend_score(closed)  # (score, [20, 60, 120-day components])

    # Walk every deal in time order, tracking balance and each day's running rule state.
    balance = 0.0
    day_state = {}  # date -> dict(opened, realised, start_balance, streak)
    trades = {}
    open_pos = {}     # position_id -> symbol, for positions still open at this point in history
    last_close = {}   # symbol -> date its last position closed
    pairs = {p.upper() for p in args.pairs}
    for d in deals:
        day = server_date(d.time)
        s = day_state.setdefault(day, {"opened": 0, "realised": 0.0, "start": balance, "streak": 0})
        if d.type == mt5.DEAL_TYPE_BALANCE or not d.symbol:
            balance += d.profit  # deposit / withdrawal
            s["start"] += d.profit
            continue
        pl = d.profit + d.commission + d.swap + d.fee
        if d.entry == mt5.DEAL_ENTRY_IN:
            balance += pl  # opening commission/fee, if the account charges any
            s["opened"] += 1
            sym = d.symbol.removesuffix("m")
            broke = []
            if s["opened"] > args.max_trades:
                broke.append(f"trade #{s['opened']} of the day")
            if s["start"] > 0 and s["realised"] / s["start"] * 100 <= -args.max_loss:
                broke.append("day already down past the loss limit")
            if s["streak"] >= args.max_losses:
                broke.append(f"after {s['streak']} losses in a row")
            if pairs and sym.upper() not in pairs:
                broke.append("pair not on my list")
            if args.max_lot and d.volume > args.max_lot + 1e-9:
                broke.append(f"lot {d.volume:g} above {args.max_lot:g}")
            if sym in open_pos.values():
                broke.append("already had a trade open on this pair")
            if args.max_open and len(open_pos) >= args.max_open:
                broke.append(f"already {len(open_pos)} trades open")
            if last_close.get(sym) == day:
                broke.append("re-entry: same pair closed earlier today")
            if args.floor and balance <= args.floor:
                broke.append(f"balance at/below the ${args.floor:g} floor")
            open_pos[d.position_id] = sym
            pip, pv = dr.pip_info(d.symbol)
            orders = mt5.history_orders_get(ticket=d.order) or []
            sl = orders[0].sl if orders else 0.0
            risk = abs(d.price - sl) / pip * pv * d.volume if sl and pip else None
            buy = d.type == mt5.DEAL_TYPE_BUY
            score, comps = trend_at(d.symbol, day) or (None, None)
            if score is None:
                with_trend = "?"
            elif abs(score) < args.trend:
                with_trend = "sideways"
            else:
                with_trend = "with" if (score > 0) == buy else "against"
            if with_trend == "with" and comps and not all((c > 0) == buy for c in comps):
                broke.append("trend not clean (20/60/120 not all + or all -)")  # plan step 4a
            if with_trend == "against":
                broke.append("against the D1 trend")
            elif with_trend == "sideways":
                broke.append("pair was sideways (no trend)")
            if not sl:
                broke.append("no SL on the order ticket")
            trades[d.position_id] = {
                "symbol": sym, "side": "BUY" if buy else "SELL", "lot": d.volume,
                "opened": dt.datetime.utcfromtimestamp(d.time), "entry_day": day,
                "risk": risk, "risk_pct": risk / balance * 100 if risk and balance > 0 else None,
                "had_sl": bool(sl), "sl_on_order": bool(sl), "trend_score": score, "with_trend": with_trend,
                "broke": broke, "net": comm_open(d),
                "_price": d.price, "_pip": pip, "_pv": pv, "_bal": balance,
            }
        else:
            balance += pl
            s["realised"] += pl
            s["streak"] = s["streak"] + 1 if pl < 0 else 0
            sym = open_pos.pop(d.position_id, None)
            if sym:
                last_close[sym] = day
            t = trades.get(d.position_id)
            if t is not None:
                t["net"] += pl
                t["closed"] = dt.datetime.utcfromtimestamp(d.time)
                t["exit"] = REASON.get(d.reason, "Closed by you")
                t["balance_after"] = balance
                # An SL added after opening isn't on the order ticket, but MT5 writes the SL
                # price on the closing deal when it is hit: "[sl 1.24201]".
                if d.reason == mt5.DEAL_REASON_SL:
                    t["had_sl"] = True
                    if t["risk"] is None and d.comment.startswith("[sl ") and t["_pip"]:
                        try:
                            sl_px = float(d.comment[4:].rstrip("]").strip())
                            t["risk"] = abs(t["_price"] - sl_px) / t["_pip"] * t["_pv"] * t["lot"]
                            t["risk_pct"] = t["risk"] / t["_bal"] * 100 if t["_bal"] > 0 else None
                        except ValueError:
                            pass
    closed = [t for t in trades.values() if "closed" in t]
    return sorted(closed, key=lambda t: t["closed"]), balance


def comm_open(d):
    """Costs charged on the opening deal (commission/fee) belong to the trade's result."""
    return d.commission + d.fee + d.profit + d.swap


def stats(ts):
    n = len(ts)
    wins = [t["net"] for t in ts if t["net"] > 0]
    losses = [t["net"] for t in ts if t["net"] <= 0]
    gw, gl = sum(wins), -sum(losses)
    return {
        "n": n, "wins": len(wins),
        "win_rate": len(wins) / n * 100 if n else 0,
        "net": sum(t["net"] for t in ts),
        "avg_win": st.mean(wins) if wins else 0.0,
        "avg_loss": -st.mean(losses) if losses else 0.0,
        "payoff": (st.mean(wins) / -st.mean(losses)) if wins and losses and st.mean(losses) < 0 else None,
        "pf": gw / gl if gl > 0 else None,
        "expect": sum(t["net"] for t in ts) / n if n else 0,
        "worst": min((t["net"] for t in ts), default=0.0),
        "broke": sum(1 for t in ts if t["broke"]),
        "no_sl": sum(1 for t in ts if not t["had_sl"]),
        "late_sl": sum(1 for t in ts if not t["sl_on_order"]),
        "with": sum(1 for t in ts if t["with_trend"] == "with"),
        "against": sum(1 for t in ts if t["with_trend"] == "against"),
        "side": sum(1 for t in ts if t["with_trend"] == "sideways"),
        "avg_risk_pct": st.mean([t["risk_pct"] for t in ts if t["risk_pct"]]) if any(t["risk_pct"] for t in ts) else None,
        "max_day": max((sum(1 for u in ts if u["entry_day"] == t["entry_day"]) for t in ts), default=0),
        "hold_h": st.median([(t["closed"] - t["opened"]).total_seconds() / 3600 for t in ts]) if ts else 0,
    }


def money(v):
    return f"{'+' if v >= 0 else '-'}${abs(v):.2f}"


def opt(v, fmt):
    return "-" if v is None else format(v, fmt)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--weeks", type=int, default=0, help="Only show the last N weeks (default: all)")
    ap.add_argument("--max-trades", type=int, default=3)
    ap.add_argument("--max-loss", type=float, default=3.0)
    ap.add_argument("--max-losses", type=int, default=3)
    ap.add_argument("--risk", type=float, default=1.0, help="Planned risk per trade, %% (default 1)")
    ap.add_argument("--trend", type=float, default=0.5)
    ap.add_argument("--pairs", nargs="*", default=[], help="Allowed pairs (default: any)")
    ap.add_argument("--max-lot", type=float, default=0, help="Biggest allowed lot (default: no cap)")
    ap.add_argument("--max-open", type=int, default=0, help="Max trades open at once (default: no cap)")
    ap.add_argument("--floor", type=float, default=0, help="Stop trading at/below this balance (default: none)")
    args = ap.parse_args()

    if not mt5.initialize():
        sys.exit(f"Could not connect to MT5 - is the terminal open and logged in? {mt5.last_error()}")
    acc = mt5.account_info()
    trades, _ = load_trades(args)
    mt5.shutdown()
    if not trades:
        sys.exit("No closed trades in this account's history yet.")

    weeks = {}
    for t in trades:
        weeks.setdefault(week_start(t["closed"].date()), []).append(t)
    keys = sorted(weeks)[-args.weeks:] if args.weeks else sorted(weeks)

    line = "=" * 118
    print(f"\nWEEKLY REPORT CARD - {acc.server if acc else ''} #{acc.login if acc else ''} - "
          f"{dt.datetime.now():%Y-%m-%d %H:%M}   (weeks run Mon-Sun, broker time; $ include costs)")
    print(line)
    print("RESULTS")
    print(line)
    print(f"{'Week of':12}{'Trades':>7}{'Wins':>6}{'Win%':>6}{'Net':>10}{'Net%':>7}{'Avg win':>9}"
          f"{'Avg loss':>10}{'Win/loss':>10}{'Profit':>8}{'Per trade':>11}{'Worst':>9}")
    print(f"{'':12}{'':>7}{'':>6}{'':>6}{'':>10}{'':>7}{'':>9}{'':>10}{'ratio':>10}{'factor':>8}{'(avg)':>11}{'trade':>9}")
    rows = []
    for k in keys:
        s = stats(weeks[k])
        start_bal = weeks[k][0]["balance_after"] - weeks[k][0]["net"]
        s["net_pct"] = s["net"] / start_bal * 100 if start_bal > 0 else 0
        rows.append((k, s))
        print(f"{k:%d %b %Y}".ljust(12) + f"{s['n']:>7}{s['wins']:>6}{s['win_rate']:>5.0f}%{money(s['net']):>10}"
              f"{s['net_pct']:>+6.1f}%{money(s['avg_win']):>9}{money(-s['avg_loss']):>10}"
              f"{opt(s['payoff'], '.2f'):>10}{opt(s['pf'], '.2f'):>8}{money(s['expect']):>11}{money(s['worst']):>9}")
    alls = stats(trades)
    print(f"{'ALL':12}{alls['n']:>7}{alls['wins']:>6}{alls['win_rate']:>5.0f}%{money(alls['net']):>10}{'':>7}"
          f"{money(alls['avg_win']):>9}{money(-alls['avg_loss']):>10}{opt(alls['payoff'], '.2f'):>10}"
          f"{opt(alls['pf'], '.2f'):>8}{money(alls['expect']):>11}{money(alls['worst']):>9}")

    extra = []
    if args.pairs:
        extra.append("pairs " + " ".join(args.pairs))
    if args.max_lot:
        extra.append(f"max lot {args.max_lot:g}")
    if args.max_open:
        extra.append(f"max {args.max_open} open")
    if args.floor:
        extra.append(f"floor ${args.floor:g}")
    print(f"\n{line}\nDISCIPLINE  (graded against: max {args.max_trades} trades/day, stop at -{args.max_loss:g}%/day, "
          f"stop after {args.max_losses} losses in a row, {args.risk:g}% risk"
          + (";\n             " + ", ".join(extra) if extra else "") + f")\n{line}")
    print(f"{'Week of':12}{'Rule':>7}{'SL not':>10}{'SL not':>8}{'Most trades':>13}{'Avg risk':>10}{'With':>7}"
          f"{'Against':>9}{'Side-':>7}{'Median':>9}")
    print(f"{'':12}{'breaks':>7}{'on order':>10}{'seen':>8}{'in one day':>13}{'per trade':>10}{'trend':>7}"
          f"{'trend':>9}{'ways':>7}{'hold':>9}")
    for k, s in rows:
        print(f"{k:%d %b %Y}".ljust(12) + f"{s['broke']:>7}{s['late_sl']:>10}{s['no_sl']:>8}{s['max_day']:>13}"
              f"{(opt(s['avg_risk_pct'], '.1f') + '%') if s['avg_risk_pct'] else '-':>10}"
              f"{s['with']:>7}{s['against']:>9}{s['side']:>7}{s['hold_h']:>8.0f}h")
    print("Rule breaks = trades that broke at least one rule when opened (too many trades that day, after a stop")
    print("              rule, off-list pair, lot too big, pair already open, same-day re-entry, against/no trend,")
    print("              trend not clean (20/60/120 not all the same sign),")
    print("              no SL on the ticket, below the floor). Checked on closed trades only. See the table below.")
    print("SL not on order = SL wasn't set on the order ticket (added after opening, or never). Setting it ON")
    print("              the order means you're never in a trade without one, not even for a minute.")
    print("SL not seen = closed by hand and the SL wasn't on the order, so the report can't tell if one existed.")
    print("Avg risk    = what the SL would have cost, as % of the account (only trades where the SL is known).")
    print("With/Against trend = direction of the trade vs the D1 trend score on the candles closed before entry.")

    # Which rules were broken, per week
    def kind(msg):
        if msg.startswith("trade #"):
            return "too many trades that day"
        if msg.startswith("after "):
            return "after a losing streak"
        if msg.startswith("lot "):
            return "lot too big"
        if msg.startswith("already ") and msg.endswith("trades open"):
            return "too many trades open"
        if msg.startswith("balance "):
            return "below the balance floor"
        return msg

    kinds = {kind(m) for t in trades for m in t["broke"]}
    if kinds:
        shown = [k for k, _ in rows[-4:]]
        count = lambda ts, kd: sum(1 for t in ts if any(kind(m) == kd for m in t["broke"]))
        print(f"\n{line}\nRULE BREAKS BY RULE  (number of trades; one trade can break several rules)\n{line}")
        print(f"{'Rule':44}" + "".join(f"{k:%d %b}".rjust(10) for k in shown) + f"{'ALL':>8}")
        for kd in sorted(kinds, key=lambda x: -count(trades, x)):
            print(f"{kd:44}" + "".join(f"{count(weeks[k], kd):>10}" for k in shown) + f"{count(trades, kd):>8}")
        clean = [sum(1 for t in weeks[k] if not t["broke"]) for k in shown]
        print(f"{'CLEAN trades (no rule broken)':44}" + "".join(f"{c:>10}" for c in clean)
              + f"{sum(1 for t in trades if not t['broke']):>8}")

    # This week vs last week
    if len(rows) >= 2:
        (k0, a), (k1, b) = rows[-2], rows[-1]
        print(f"\n{line}\nTHIS WEEK ({k1:%d %b}) vs LAST WEEK ({k0:%d %b})\n{line}")

        def cmp(label, x, y, better_high=True, fmt="{:.2f}"):
            if x is None or y is None:
                return
            if abs(y - x) < 1e-9:
                verdict = "same"
            else:
                verdict = "BETTER" if (y > x) == better_high else "worse"
            print(f"  {label:38}{fmt.format(x):>10} -> {fmt.format(y):<10} {verdict}")
        cmp("Net result ($)", a["net"], b["net"])
        cmp("Win rate (%)", a["win_rate"], b["win_rate"], fmt="{:.0f}")
        cmp("Win/loss ratio (avg win / avg loss)", a["payoff"], b["payoff"])
        cmp("Profit factor (won $ / lost $)", a["pf"], b["pf"])
        cmp("Average result per trade ($)", a["expect"], b["expect"])
        cmp("Trades per week", a["n"], b["n"], better_high=False, fmt="{:.0f}")
        cmp("Rule breaks", a["broke"], b["broke"], better_high=False, fmt="{:.0f}")
        cmp("Trades against the trend", a["against"], b["against"], better_high=False, fmt="{:.0f}")

    # All-time breakdowns
    def table(title, groups):
        print(f"\n{line}\n{title}\n{line}")
        print(f"{'':16}{'Trades':>7}{'Win%':>6}{'Net':>10}{'Per trade':>11}")
        for name, ts in sorted(groups.items(), key=lambda kv: stats(kv[1])["net"]):
            if not ts:
                print(f"{name:16}{'none yet':>7}")
                continue
            s = stats(ts)
            print(f"{name:16}{s['n']:>7}{s['win_rate']:>5.0f}%{money(s['net']):>10}{money(s['expect']):>11}")

    by = lambda key: {v: [t for t in trades if t[key] == v] for v in {t[key] for t in trades}}
    table("ALL TIME - WITH vs AGAINST THE D1 TREND", by("with_trend"))
    table("ALL TIME - HOW TRADES ENDED", by("exit"))
    table("ALL TIME - BY PAIR (worst first)", by("symbol"))
    broke = [t for t in trades if t["broke"]]
    table("ALL TIME - DID BREAKING YOUR RULES COST YOU?",
          {"Rule broken": broke, "Rules followed": [t for t in trades if not t["broke"]]})

    # Plain-English summary
    print(f"\n{line}\nSUMMARY\n{line}")
    n = alls["n"]
    if n < 30:
        print(f"  * {n} closed trades so far. Under ~30 trades, results are mostly luck - judge the HABITS below,")
        print(f"    not the money, until you have more.")
    if rows:
        k, s = rows[-1]
        if s["broke"] == 0:
            print(f"  * Week of {k:%d %b}: no rule breaks. That is the habit that matters most right now.")
        else:
            print(f"  * Week of {k:%d %b}: {s['broke']} of {s['n']} trade(s) broke at least one rule - "
                  f"see RULE BREAKS BY RULE.")
        if s["payoff"] and s["payoff"] >= 1:
            print(f"  * Your average win is {s['payoff']:.1f}x your average loss this week - winners bigger than losers.")
        elif s["payoff"]:
            print(f"  * Your average win is only {s['payoff']:.1f}x your average loss - losers are bigger than winners.")
        if s["against"]:
            print(f"  * {s['against']} trade(s) this week went against the D1 trend.")
        if s["late_sl"]:
            print(f"  * {s['late_sl']} of {s['n']} trade(s) this week were opened with no SL on the order - it was added")
            print(f"    after (or never). Put the SL in the order ticket so no trade is ever open without one.")
    if broke:
        followed = [t for t in trades if not t["broke"]]
        sb, sf = stats(broke), stats(followed)
        print(f"  * All time: trades opened after breaking a rule made {money(sb['net'])} ({money(sb['expect'])} each); "
              + (f"trades within your rules made {money(sf['net'])} ({money(sf['expect'])} each)." if followed else
                 "no trade has followed every rule yet - your first clean trade is the goal."))
    need = 100 / (1 + alls["payoff"]) if alls["payoff"] else None
    if need:
        print(f"  * With your all-time win/loss ratio of {alls['payoff']:.2f}, you need to win more than {need:.0f}% "
              f"of trades to make money. You win {alls['win_rate']:.0f}%.")

    out = os.path.join(HERE, "weekly_report_trades.csv")
    try:
        with open(out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["opened", "closed", "pair", "side", "lot", "net", "exit", "had_sl", "risk_$", "risk_%",
                        "trend_score", "with_trend", "rule_broken"])
            for t in trades:
                w.writerow([f"{t['opened']:%Y-%m-%d %H:%M}", f"{t['closed']:%Y-%m-%d %H:%M}", t["symbol"], t["side"],
                            t["lot"], round(t["net"], 2), t["exit"], t["had_sl"],
                            opt(t["risk"], ".2f"), opt(t["risk_pct"], ".2f"), opt(t["trend_score"], ".2f"),
                            t["with_trend"], "; ".join(t["broke"])])
        print(f"\nEvery trade with its grading saved to {out}")
    except PermissionError:
        print(f"\nCould not save {out} - it is open in Excel. Close it and run again.")


if __name__ == "__main__":
    main()
