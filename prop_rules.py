"""Prop-firm (FTMO 1-Step style) rule guard for daily_range.py and the dashboard.

FTMO's rules, as they apply to a 1-Step Challenge (all limits are on EQUITY, i.e. including
open trades, and are reset at 00:00 CE(S)T - Prague time - not at the broker's midnight):
    Maximum Daily Loss  equity may never drop below (balance at 00:00 CE(S)T today) - 3% of
                        the initial capital.
    Maximum Loss        equity may never drop below (highest balance at any 00:00 CE(S)T, or the
                        initial capital if higher) - 10% of the initial capital. Only ever rises.
    Profit Target       balance >= initial capital + 10%, with every trade closed.
    Best Day            the best day's closed profit must be <= 50% of the sum of all profitable
                        days (not a breach - you just keep trading until it is true).

check() works out today's limits from the account history, what every open trade would leave
you with if all stop losses were hit, and how much the NEXT trade may risk so that even a full
stop-out keeps you above both limits with a safety buffer. Read-only: nothing here places,
modifies or closes trades.
"""
import datetime as dt, time
import MetaTrader5 as mt5
import daily_range as dr

utc = dt.datetime.utcfromtimestamp


def cest_offset(ts):
    """Hours Prague is ahead of UTC at timestamp ts: +2 in summer time (last Sunday of March
    01:00 UTC to last Sunday of October 01:00 UTC), +1 otherwise."""
    t = utc(ts)

    def last_sunday(month):
        d = dt.datetime(t.year, month, 31 if month in (3, 10) else 30, 1)
        return d - dt.timedelta(days=(d.weekday() + 1) % 7)

    return 2 if last_sunday(3) <= t < last_sunday(10) else 1


def day_shift():
    """Hours the broker's clock runs ahead of CE(S)T (FTMO: +1, its server is on Athens time).
    Deal times are on the broker's clock, so a prop day = broker time minus this, then .date()."""
    server_hours = round((dr.server_now() - time.time()) / 3600)
    return server_hours - cest_offset(time.time())


def prop_day(server_ts, shift):
    return utc(server_ts - shift * 3600).date()


def history(shift):
    """Balance at the end of every prop day, closed trading P/L per prop day, first deposit."""
    deals = sorted(mt5.history_deals_get(dt.datetime(2000, 1, 1), dt.datetime.now() + dt.timedelta(days=2)) or [],
                   key=lambda d: (d.time_msc, d.ticket))
    bal, eod, closed, first_deposit = 0.0, {}, {}, None
    for d in deals:
        net = d.profit + d.commission + d.swap + d.fee
        day = prop_day(d.time, shift)
        bal += net
        eod[day] = bal
        if d.symbol:
            closed[day] = closed.get(day, 0.0) + net
        elif d.type == mt5.DEAL_TYPE_BALANCE and first_deposit is None and net > 0:
            first_deposit = net
    return eod, closed, first_deposit


def stop_loss_money(p, commission):
    """Account money this position adds to the balance if its SL is hit (negative = a loss),
    including swap so far and the closing half of the commission. None if it has no SL."""
    if not p.sl:
        return None
    kind = mt5.ORDER_TYPE_BUY if p.type == mt5.POSITION_TYPE_BUY else mt5.ORDER_TYPE_SELL
    pl = mt5.order_calc_profit(kind, p.symbol, p.volume, p.price_open, p.sl)  # a calculation only
    if pl is None:
        pip, pv = dr.pip_info(p.symbol)
        buy = p.type == mt5.POSITION_TYPE_BUY
        pl = ((p.sl - p.price_open) if buy else (p.price_open - p.sl)) / pip * pv * p.volume
    return pl + p.swap - commission * p.volume / 2


def status(args):
    """Everything about the prop account as a dict (no printing)."""
    acc = mt5.account_info()
    shift = day_shift()
    today = prop_day(dr.server_now(), shift)
    eod, closed, first_deposit = history(shift)
    initial = args.prop_initial or first_deposit or acc.balance
    past = [v for day, v in sorted(eod.items()) if day < today]
    start_balance = past[-1] if past else initial  # day 1 uses the initial capital
    peak = max([initial] + past)
    daily_limit = start_balance - args.prop_daily / 100 * initial
    max_limit = peak - args.prop_max / 100 * initial
    target = initial * (1 + args.prop_target / 100)

    positions = mt5.positions_get() or []
    no_sl = [p for p in positions if not p.sl]
    worst = acc.balance + sum(stop_loss_money(p, args.commission) or 0 for p in positions)

    base = args.risk / 100 * initial
    drawdown_mode = acc.equity - max_limit < args.prop_max / 200 * initial
    if drawdown_mode:
        base /= 2
    buffer = args.prop_buffer / 100 * initial
    room_day = worst - daily_limit - buffer
    room_max = worst - max_limit - buffer
    cap = max(0.0, min(base, room_day, room_max))

    positive = {d: v for d, v in closed.items() if v > 0}
    pos_sum = sum(positive.values())
    best_day, best = max(positive.items(), key=lambda kv: kv[1]) if positive else (None, 0.0)
    return {
        "initial": initial, "today": today, "shift": shift, "balance": acc.balance, "equity": acc.equity,
        "start_balance": start_balance, "peak": peak,
        "daily_limit": daily_limit, "max_limit": max_limit, "target": target,
        "today_pl": acc.equity - start_balance, "today_closed": closed.get(today, 0.0),
        "worst": worst, "no_sl": [p.symbol for p in no_sl],
        "open": len(positions), "buffer": buffer,
        "base_risk": base, "drawdown_mode": drawdown_mode, "room_day": room_day, "room_max": room_max,
        "risk_cap": cap,
        "best_day": best_day.isoformat() if best_day else None, "best": best, "positive_sum": pos_sum,
        "best_share": best / pos_sum * 100 if pos_sum else 0.0,
        "best_more_needed": max(0.0, 2 * best - pos_sum),
        "profit_days": len(positive), "trading_days": len(closed),
    }


def check(args, s=None):
    """Print the prop-firm panel (from status() if given). Returns (stops, status dict)."""
    s = s or status(args)
    i = s["initial"]
    pct = lambda money: money / i * 100
    usd = lambda v: ("-" if v < 0 else "+") + f"${abs(v):,.2f}"
    ok = lambda bad: "[STOP]" if bad else "[ OK ]"
    stops = []
    print("\n" + "=" * 100)
    print(f"PROP FIRM RULES (FTMO style)   initial capital ${i:,.0f}   prop day {s['today']:%a %d %b} "
          f"(resets 00:00 Prague time = {(24 + s['shift']) % 24:02d}:00 on the MT5 clock)")
    print("=" * 100)

    eq = s["equity"]
    bad = eq <= s["daily_limit"]
    print(f"{ok(bad)}  Maximum Daily Loss : equity ${eq:,.2f} must stay above ${s['daily_limit']:,.2f}"
          f"  (${s['start_balance']:,.2f} at day start - {args.prop_daily:g}%)  room ${eq - s['daily_limit']:,.2f}")
    if bad:
        stops.append("FTMO MAXIMUM DAILY LOSS LIMIT IS BROKEN - check the FTMO account page")
    bad = eq <= s["max_limit"]
    print(f"{ok(bad)}  Maximum Loss       : equity ${eq:,.2f} must stay above ${s['max_limit']:,.2f}"
          f"  (best day-start balance ${s['peak']:,.2f} - {args.prop_max:g}%)  room ${eq - s['max_limit']:,.2f}")
    if bad:
        stops.append("FTMO MAXIMUM LOSS LIMIT IS BROKEN - check the FTMO account page")
    print(f"        Today so far       : {usd(s['today_pl'])} ({pct(s['today_pl']):+.2f}%, incl. open trades)")
    print(f"        If every SL is hit : equity would be ${s['worst']:,.2f}"
          f"  -> ${s['worst'] - s['daily_limit']:,.2f} above the daily limit, ${s['worst'] - s['max_limit']:,.2f} above max loss")
    if s["no_sl"]:
        stops.append(f"{len(s['no_sl'])} open trade(s) have NO stop loss - one bad move can break the FTMO limits. "
                     f"Set the SL before anything else")

    gain = s["balance"] - i
    print(f"        Profit Target      : balance ${s['balance']:,.2f} of ${s['target']:,.2f}"
          f"  ({pct(gain):+.2f}% of +{args.prop_target:g}%)  still needed ${max(0, s['target'] - s['balance']):,.2f}")
    if s["best_day"]:
        flag = "OK" if s["best_share"] <= 50 else "TOO BIG"
        print(f"        Best Day rule      : best day {s['best_day']} {usd(s['best'])} = {s['best_share']:.0f}% of "
              f"profitable days' total {usd(s['positive_sum'])} (max 50%) -> {flag}")
        if s["best_more_needed"] > 0:
            print(f"                             profitable days must add ${s['best_more_needed']:,.2f} more before you can pass")
    else:
        print(f"        Best Day rule      : no profitable day yet")
    print(f"        Days with trades closed: {s['trading_days']} ({s['profit_days']} profitable)")

    print(f"\n        Next trade may risk: ${s['risk_cap']:,.2f} ({pct(s['risk_cap']):.2f}%) = the smallest of "
          f"your {args.risk:g}% (${s['base_risk']:,.2f}{', HALVED - near max loss' if s['drawdown_mode'] else ''}),"
          f" room to the daily limit (${max(0, s['room_day']):,.2f}) and to max loss (${max(0, s['room_max']):,.2f}),")
    print(f"        each after keeping a ${s['buffer']:,.0f} ({args.prop_buffer:g}%) safety buffer for slippage, gaps and spread.")
    print(f"        Lot sizes in the table already use this amount.")
    if s["risk_cap"] < s["base_risk"] / 4:
        stops.append(f"not enough room under the FTMO limits for another trade today "
                     f"(only ${s['risk_cap']:,.2f} may be risked)")
    if s["balance"] >= s["target"]:
        if s["open"]:
            print(f"\n  >>> PROFIT TARGET REACHED on balance - close the open trades to lock it in.")
        elif s["best_share"] > 50:
            print(f"\n  >>> PROFIT TARGET REACHED, but the Best Day rule is not met yet - keep trading small"
                  f" (half your normal risk) until it is.")
        else:
            stops.append("PROFIT TARGET REACHED with every objective met - stop trading and check the FTMO account page")
    return stops, s
