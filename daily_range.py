"""Daily SL/TP helper: how many pips each pair moves per day, from your MT5 terminal.

Run with MT5 open and logged in:
    python daily_range.py                   # default list + every pair you've traded
    python daily_range.py EURUSD XAUUSD     # just these symbols
    python daily_range.py --sl 0.6 --tp 1.2 # change the SL/TP multipliers
    python daily_range.py --sl-tf H4 --sl 2 --tp 4
                                            # SL/TP from the typical H4 candle instead of the day
    python daily_range.py --risk 0.5        # size lots to risk 0.5% of balance (default 1%)
    python daily_range.py --max-trades 2 --max-loss 2 --max-losses 2 --max-open-risk 3
                                            # daily stop rules (defaults 3 / 3% / 3 / 3%)

After the table it checks your open trades (loss if every SL is hit, trades with no SL,
trades that are really one bet on the same currency) and today's stop-trading limits.

Suggested SL/TP = multiplier x "typical day now" (median high-low range of the last
20 closed daily candles), or with --sl-tf H4 multiplier x the typical H4 candle (median of
the last 120 closed H4 candles = ~20 trading days), so the levels adapt to current volatility.
Read-only: nothing here places, modifies or closes trades.
"""
import argparse, csv, datetime as dt, math, os, statistics as st, sys, time
import MetaTrader5 as mt5

# All 28 pairs of the 8 major currencies (EUR GBP AUD NZD USD CAD CHF JPY), plus gold and
# GBPSGD (traded before). Any other pair you have traded is added automatically.
DEFAULT_SYMBOLS = [
    "XAUUSD",
    "EURUSD", "GBPUSD", "USDJPY", "USDCHF", "AUDUSD", "USDCAD", "NZDUSD",
    "EURGBP", "EURJPY", "EURCHF", "EURAUD", "EURCAD", "EURNZD",
    "GBPJPY", "GBPCHF", "GBPAUD", "GBPCAD", "GBPNZD",
    "AUDJPY", "AUDCHF", "AUDCAD", "AUDNZD",
    "NZDJPY", "NZDCHF", "NZDCAD",
    "CADJPY", "CADCHF", "CHFJPY",
    "GBPSGD",
]
# Pip size by symbol prefix where the digits rule doesn't apply.
# Gold: 1 pip = $0.10 (so a $20 day = 200 pips). Silver: 1 pip = $0.01.
PIP_OVERRIDE = {"XAU": 0.1, "XAG": 0.01}
RECENT_DAYS = 20
SL_TIMEFRAMES = {"D1": None, "H4": (mt5.TIMEFRAME_H4, 120)}  # D1 uses typical day now
HERE = os.path.dirname(os.path.abspath(__file__))


def resolve(name):
    """Map EURUSD -> the broker's name (some brokers add a suffix, e.g. EURUSDm)."""
    name = name.upper().removesuffix("M")
    for cand in (name, name + "m"):
        if mt5.symbol_info(cand) is not None:
            return cand
    return None


def pip_size(sym, info):
    for prefix, pip in PIP_OVERRIDE.items():
        if sym.upper().startswith(prefix):
            return pip
    return info.point * 10 if info.digits in (3, 5) else info.point


def traded_symbols():
    deals = mt5.history_deals_get(dt.datetime(2015, 1, 1), dt.datetime.now() + dt.timedelta(days=2)) or []
    return {d.symbol for d in deals if d.symbol and d.entry == 0}


def server_now():
    """Now on the broker's clock, as a timestamp (candles are stamped in server time).

    Server offset is read from a fresh tick: a live tick sits within a few minutes of a
    whole-hour offset from real time. Crypto trades at weekends, so try it first.
    """
    for name in ("BTCUSD", "ETHUSD", "EURUSD", "XAUUSD"):
        s = resolve(name)
        tick = mt5.symbol_info_tick(s) if s else None
        if not tick:
            continue
        diff = tick.time - time.time()
        hours = round(diff / 3600)
        if abs(diff - hours * 3600) < 600 and abs(hours) <= 14:
            return time.time() + hours * 3600
    return time.time()


def server_today():
    """Today's date on the broker's clock."""
    return dt.datetime.utcfromtimestamp(server_now()).date()


TF_SECONDS = {mt5.TIMEFRAME_D1: 86400, mt5.TIMEFRAME_H4: 14400, mt5.TIMEFRAME_H1: 3600}


def closed_rates(sym, tf, n):
    """The last n CLOSED candles. The newest candle is dropped only if it is still forming -
    at weekends the newest candle (Friday's) is already closed and must be kept."""
    r = mt5.copy_rates_from_pos(sym, tf, 0, n + 1)
    if r is None or len(r) == 0:
        return r
    if int(r[-1]["time"]) + TF_SECONDS[tf] > server_now():
        r = r[:-1]
    return r[-n:]


def load_rates(sym, count=1000):
    """D1 candles, newest last. MT5 downloads history in the background the first time a
    symbol is asked for, so an early call can return too few bars - retry until the count
    stops growing (a young symbol may simply have less history than asked for)."""
    rates, last_len = None, -1
    for _ in range(10):
        rates = mt5.copy_rates_from_pos(sym, mt5.TIMEFRAME_D1, 0, count)
        n = 0 if rates is None else len(rates)
        if n >= count or (n >= 300 and n == last_len):
            break
        last_len = n
        time.sleep(1)
    return rates


def trend_score(rates, periods=(20, 60, 120), atr_period=20, k=2.0):
    """Same maths as MQL5/Include/DTF/SignalEngine.mqh (mode Both), on closed D1 candles.

    For each lookback L: average of
      EMA view     clamp((close - EMA(L)) / (k * ATR * sqrt(L / atr_period)))
      channel view 2 * (close - lowest low L) / (highest high L - lowest low L) - 1
    then the three lookbacks are averaged. -1 = strong downtrend, +1 = strong uptrend.
    Raw candles (incl. Sunday stubs) are used on purpose - that is what the chart indicator sees.
    """
    close = [float(r["close"]) for r in rates]
    high = [float(r["high"]) for r in rates]
    low = [float(r["low"]) for r in rates]
    n = len(close)
    if n < max(periods) + atr_period + 2:
        return None, None
    # MT5 iATR = simple average of true range over atr_period
    tr = [max(high[i], close[i - 1]) - min(low[i], close[i - 1]) for i in range(n - atr_period, n)]
    atr = sum(tr) / atr_period
    clamp = lambda x: max(-1.0, min(1.0, x))
    comps = []
    for L in periods:
        a = 2.0 / (L + 1)
        ema = close[0]
        for c in close[1:]:
            ema += a * (c - ema)
        parts = []
        denom = k * atr * math.sqrt(L / atr_period)
        if denom > 0:
            parts.append(clamp((close[-1] - ema) / denom))
        hh, ll = max(high[-L:]), min(low[-L:])
        if hh > ll:
            parts.append(clamp(2 * (close[-1] - ll) / (hh - ll) - 1))
        comps.append(sum(parts) / len(parts) if parts else 0.0)
    return sum(comps) / 3, comps


def atr(sym, tf, period=14):
    """MT5's built-in ATR(14): simple average of the true range of the last 14 CLOSED candles
    (true range = high-low, stretched to include any gap from the previous close).
    Raw candles incl. Sunday stubs, exactly what the indicator on the chart sees.
    On the chart, read the ATR value of the last closed candle (Data Window, Ctrl+D)."""
    r = closed_rates(sym, tf, period + 1)
    if r is None or len(r) < period + 1:
        return None
    return sum(max(r[i]["high"], r[i - 1]["close"]) - min(r[i]["low"], r[i - 1]["close"])
               for i in range(1, period + 1)) / period


def analyse(sym, today, sl_mult, tp_mult, sl_tf="D1"):
    mt5.symbol_select(sym, True)
    info = mt5.symbol_info(sym)
    rates = load_rates(sym)
    if info is None or rates is None or len(rates) < 30:
        print(f"  {sym}: no daily data ({mt5.last_error()})")
        return None
    pip = pip_size(sym, info)
    # The newest candle is still forming only if it is dated today (server time).
    # At weekends / holidays the newest candle is already closed. A Sunday-evening
    # stub candle is only a few hours old, so it is not reported as "today" either.
    today_so_far = room_up = room_down = None
    if dt.datetime.utcfromtimestamp(int(rates[-1]["time"])).date() == today:
        cur = rates[-1]
        rates = rates[:-1]
        tick = mt5.symbol_info_tick(sym)
        if today.weekday() < 5 and tick and tick.bid > 0:
            today_so_far = (cur["high"] - cur["low"]) / pip
            # If today ends up a typical-sized day, the high can reach low + typical and
            # the low can reach high - typical. Room = how far price is from those.
            today_hl = (cur["high"], cur["low"], tick.bid)
    bars = []  # (date, range_pips) for closed Mon-Fri candles (drops Sunday-evening stubs)
    for r in rates:
        t = dt.datetime.utcfromtimestamp(int(r["time"])).date()
        if t.weekday() < 5:
            bars.append((t, (r["high"] - r["low"]) / pip))

    def ranges(days):
        return [x[1] for x in bars if x[0] >= today - dt.timedelta(days=days)]

    r12, r6 = ranges(365), ranges(182)
    if len(r12) < 200:
        print(f"  WARNING {sym}: only {len(r12)} daily candles in the last 12 months (expected ~260)."
              f" Scroll its D1 chart back in MT5 to download history, then run again.")
    if len(r6) < 20:
        return None
    score, comps = trend_score(rates)  # rates = closed candles only (forming one dropped above)
    recent = [x[1] for x in bars[-RECENT_DAYS:]]
    r6s = sorted(r6)
    typical_now = st.median(recent)
    if today_so_far is not None:
        high, low, price = today_hl
        room_up = max(0.0, (low + typical_now * pip - price) / pip)
        room_down = max(0.0, (price - (high - typical_now * pip)) / pip)
    sl_unit = typical_now
    if SL_TIMEFRAMES[sl_tf]:
        tf, n = SL_TIMEFRAMES[sl_tf]
        bars_tf = closed_rates(sym, tf, n)
        if bars_tf is None or len(bars_tf) < n // 2:
            print(f"  {sym}: not enough {sl_tf} candles for the SL ({mt5.last_error()})")
            return None
        sl_unit = st.median((b["high"] - b["low"]) / pip for b in bars_tf)
    pip_value = tick_value(info) * pip / info.trade_tick_size if info.trade_tick_size else 0
    # Normal spread = median spread of the H1 candles of the last ~20 days. The spread right now
    # is much wider at weekends and around the daily rollover, so warnings use the normal one.
    h1 = closed_rates(sym, mt5.TIMEFRAME_H1, 480)
    spread_normal = st.median(int(b["spread"]) for b in h1) * info.point / pip if h1 is not None and len(h1) else None
    atr_d1, atr_h4 = atr(sym, mt5.TIMEFRAME_D1), atr(sym, mt5.TIMEFRAME_H4)
    atr_h4_20d = atr(sym, mt5.TIMEFRAME_H4, 120)  # same ATR over ~20 days = "normal" H4 ATR
    return {
        "symbol": sym,
        "score": score,
        "comps": comps,
        "avg_12m": st.mean(r12),
        "avg_6m": st.mean(r6),
        "typical_6m": st.median(r6),
        "quiet_6m": r6s[int(0.25 * (len(r6s) - 1))],
        "busy_6m": r6s[int(0.75 * (len(r6s) - 1))],
        "typical_now": typical_now,
        "yesterday": bars[-1][1],
        "today": today_so_far,
        "room_up": room_up,
        "room_down": room_down,
        "vol_vs_6m": typical_now / st.median(r6) * 100,
        "atr_d1": atr_d1 / pip if atr_d1 is not None else None,  # MT5 ATR(14) on D1, in pips
        "atr_h4": atr_h4 / pip if atr_h4 is not None else None,  # MT5 ATR(14) on H4, in pips
        "atr_h4_20d": atr_h4_20d / pip if atr_h4_20d is not None else None,
        "spread": info.spread * info.point / pip,  # right now
        "spread_normal": spread_normal,
        "sl_unit": sl_unit,
        "SL": sl_mult * sl_unit,
        "TP": tp_mult * sl_unit,
        # account-currency value of 1 pip on 1.00 lot (0 = MT5 hasn't priced it yet)
        "pip_value": pip_value,
        "vol_min": info.volume_min, "vol_step": info.volume_step,
    }


def size_lot(r, risk_money):
    """Largest lot whose SL loss stays within risk_money. Rounds down, never up."""
    loss_per_lot = r["SL"] * r["pip_value"]
    if loss_per_lot <= 0:
        return None, None, False  # pip value unknown - show '-' rather than guess
    step = r["vol_step"]
    lot = math.floor(risk_money / loss_per_lot / step + 1e-9) * step
    too_small = lot < r["vol_min"]
    if too_small:
        lot = r["vol_min"]
    return lot, lot * loss_per_lot, too_small


def pip_info(sym):
    """(pip size, account-currency value of 1 pip on 1.00 lot) for any symbol."""
    info = mt5.symbol_info(sym)
    if info is None:
        return None, 0
    pip = pip_size(sym, info)
    return pip, (tick_value(info) * pip / info.trade_tick_size if info.trade_tick_size else 0)


def tick_value(info):
    """Money per tick on 1 lot, the losing side (what a stop loss costs; >= the profit side)."""
    return max(info.trade_tick_value, info.trade_tick_value_loss or 0)


def currencies(sym):
    """EURGBPm -> ('EUR', 'GBP'); None for things that aren't currency/metal pairs."""
    core = sym.upper().removesuffix("M")
    if len(core) == 6 and core.isalpha():
        return core[:3], core[3:]
    return None


def open_trades_check(rows, account, max_open_risk):
    """Feature 1: what every open trade can lose, SL/TP sanity, and shared-currency risk."""
    typical = {r["symbol"]: r["typical_now"] for r in rows}
    sugg_sl = {r["symbol"]: r["SL"] for r in rows}
    trend = {r["symbol"]: r["trend"] for r in rows}
    positions = mt5.positions_get() or []
    print("\n" + "=" * 100)
    print("OPEN TRADES CHECK")
    print("=" * 100)
    if not positions:
        print("No open trades.")
        return []
    print(f"{'Pair':8}{'Side':>5}{'Lot':>6}{'SL':>6}{'TP':>6}{'If SL hit':>11}{'Now':>9}   Notes  (SL/TP in pips)")
    warnings, total_risk, exposure = [], 0.0, {}
    for p in positions:
        pip, pv = pip_info(p.symbol)
        buy = p.type == mt5.POSITION_TYPE_BUY
        side = "BUY" if buy else "SELL"
        name = p.symbol.removesuffix("m")
        notes = []
        sl_pips = tp_pips = None
        if p.sl:
            sl_pips = (p.price_open - p.sl) / pip if buy else (p.sl - p.price_open) / pip
            sl_money = -sl_pips * pv * p.volume  # negative = a loss
            risk = max(0.0, -sl_money)
            total_risk += risk
            sl_txt = f"-${-sl_money:.2f}" if sl_money < 0 else f"+${sl_money:.2f}"
            if sl_money >= 0:
                notes.append("SL is in profit - this trade can no longer lose")
        else:
            risk = None
            sl_txt = "NO SL!"
            warnings.append(f"{name} {side} has NO stop loss - the loss is unlimited. Set an SL now.")
        if p.tp:
            tp_pips = (p.tp - p.price_open) / pip if buy else (p.price_open - p.tp) / pip
        t = trend.get(p.symbol)
        if (t == "UP" and not buy) or (t == "DOWN" and buy):
            notes.append(f"AGAINST the D1 trend ({t})")
            warnings.append(f"{name} {side} is against the daily trend ({t}) - is that on purpose?")
        elif t == "SIDE":
            notes.append("no clear D1 trend")
        typ = typical.get(p.symbol)
        if typ:
            sug = sugg_sl[p.symbol]
            if sl_pips is not None and 0 < sl_pips < 0.5 * sug:
                notes.append(f"SL tight: under half the suggested SL ({sug:.0f})")
            elif sl_pips is not None and sl_pips > 1.5 * sug:
                notes.append(f"SL wide: over 1.5x the suggested SL ({sug:.0f})")
            if tp_pips is not None and tp_pips > 0:
                days = tp_pips / typ
                if days >= 2:
                    notes.append(f"TP is ~{days:.1f} typical days away")
        now_money = p.profit + p.swap
        print(f"{name:8}{side:>5}{p.volume:>6.2f}"
              f"{(f'{sl_pips:.0f}' if sl_pips is not None else '-'):>6}"
              f"{(f'{tp_pips:.0f}' if tp_pips is not None else '-'):>6}"
              f"{sl_txt:>11}{('+' if now_money >= 0 else '-') + f'${abs(now_money):.2f}':>9}   {'; '.join(notes)}")
        # exposure: a BUY of EURGBP is long EUR and short GBP
        ccy = currencies(p.symbol)
        if ccy:
            base, quote = ccy
            for c, direction in ((base, "long" if buy else "short"), (quote, "short" if buy else "long")):
                exposure.setdefault((c, direction), []).append((f"{name} {side}", risk or 0.0, risk is None))

    pct = total_risk / account * 100 if account else 0
    status = "OK" if pct <= max_open_risk else "TOO HIGH"
    print(f"\nIf EVERY stop loss is hit: -${total_risk:.2f} = {pct:.1f}% of your account "
          f"(your limit {max_open_risk:g}%)  -> {status}")
    if pct > max_open_risk:
        warnings.append(f"Total open risk {pct:.1f}% is over your {max_open_risk:g}% limit - "
                        f"don't open more trades; consider closing or tightening one.")

    shared = {k: v for k, v in exposure.items() if len(v) >= 2}
    if shared:
        print("\nTrades that win or lose TOGETHER (same currency, same direction):")
        for (c, direction), trades in sorted(shared.items()):
            falls = "falls" if direction == "long" else "rises"
            risk = sum(t[1] for t in trades)
            extra = " + a trade with NO SL" if any(t[2] for t in trades) else ""
            print(f"  {direction.upper()} {c} in {len(trades)} trades ({', '.join(t[0] for t in trades)}): "
                  f"if {c} {falls}, they can all lose together - combined -${risk:.2f}{extra}")
        warnings.append("Some open trades are really one bet on the same currency - count them as one bigger trade.")
    else:
        print("\nNo two open trades depend on the same currency in the same direction.")
    return warnings


def daily_limits_check(today, account_now, balance, max_trades, max_loss_pct, max_losses_row,
                       max_week_loss=0, max_month_loss=0, floor=0):
    """Feature 2: stop-for-the-day rules, counted on the broker's day. Optional (0 = off):
    stop for the week / the month at a % loss, and a hard balance floor."""
    frm = dt.datetime.combine(today - dt.timedelta(days=3), dt.time())
    deals = mt5.history_deals_get(frm, dt.datetime.now() + dt.timedelta(days=2)) or []
    todays = sorted((d for d in deals if dt.datetime.utcfromtimestamp(d.time).date() == today and d.symbol),
                    key=lambda d: d.time)
    opened = sum(1 for d in todays if d.entry == mt5.DEAL_ENTRY_IN)
    closes = [d.profit + d.commission + d.swap + d.fee for d in todays
              if d.entry in (mt5.DEAL_ENTRY_OUT, mt5.DEAL_ENTRY_INOUT, mt5.DEAL_ENTRY_OUT_BY)]
    realised = sum(closes)
    floating = account_now - balance
    start = balance - realised  # balance when the day started
    day_pct = (realised + floating) / start * 100 if start > 0 else 0
    streak = 0
    for pl in reversed(closes):
        if pl >= 0:
            break
        streak += 1

    print("\n" + "=" * 100)
    print(f"TODAY'S LIMITS   (broker day {today:%a %d %b}; limits set with --max-trades / --max-loss / --max-losses)")
    print("=" * 100)
    stops = []
    ok = lambda bad: "[STOP]" if bad else "[ OK ]"
    bad = opened >= max_trades
    print(f"{ok(bad)}  New trades opened today : {opened} of max {max_trades}")
    if bad:
        stops.append(f"you've opened {opened} trades today (max {max_trades})")
    bad = day_pct <= -max_loss_pct
    print(f"{ok(bad)}  Today's result          : {'+' if realised + floating >= 0 else '-'}"
          f"${abs(realised + floating):.2f} ({day_pct:+.1f}%, incl. open trades) - limit -{max_loss_pct:g}%")
    if bad:
        stops.append(f"today is down {day_pct:.1f}% (limit -{max_loss_pct:g}%)")
    bad = streak >= max_losses_row
    print(f"{ok(bad)}  Losing trades in a row  : {streak} of max {max_losses_row}")
    if bad:
        stops.append(f"{streak} losing trades in a row")

    def period_pct(start_day):
        """Result since start_day (closed + open trades) as % of the balance at its start.
        Deposits/withdrawals in between are not counted as profit or loss."""
        frm = dt.datetime.combine(start_day - dt.timedelta(days=2), dt.time())
        ds = [d for d in mt5.history_deals_get(frm, dt.datetime.now() + dt.timedelta(days=2)) or []
              if dt.datetime.utcfromtimestamp(d.time).date() >= start_day]
        net = lambda d: d.profit + d.commission + d.swap + d.fee
        trading = sum(net(d) for d in ds if d.symbol)
        start_bal = balance - sum(net(d) for d in ds)
        pnl = trading + floating
        return pnl, (pnl / start_bal * 100 if start_bal > 0 else 0)

    for start_day, name, limit in ((today - dt.timedelta(days=today.weekday()), "This week", max_week_loss),
                                   (today.replace(day=1), "This month", max_month_loss)):
        if not limit:
            continue
        pnl, pct = period_pct(start_day)
        bad = pct <= -limit
        print(f"{ok(bad)}  {name + ' (since ' + f'{start_day:%a %d %b}' + ')':24}: {'+' if pnl >= 0 else '-'}${abs(pnl):.2f}"
              f" ({pct:+.1f}%, incl. open trades) - limit -{limit:g}%")
        if bad:
            stops.append(f"{name.lower()} is down {pct:.1f}% (limit -{limit:g}%)"
                         + (" - no new trades until Monday" if name == "This week" else
                            " - stop live trading and go back to testing (plan step 9)"))
    if floor:
        bad = balance <= floor
        print(f"{ok(bad)}  Balance vs hard floor   : ${balance:.2f} (floor ${floor:g})")
        if bad:
            stops.append(f"balance ${balance:.2f} is at/below your ${floor:g} floor - stop live trading (plan step 1)")
    return stops


def build_rows(syms, today, args, risk_money):
    """analyse() every symbol, then add trend label, '+ + +' signs, used-of-day and lot size.
    Sorted strongest trend (up or down) first - those are the pairs a trend trader looks at."""
    rows = [r for r in (analyse(s, today, args.sl, args.tp, args.sl_tf) for s in syms) if r]
    for r in rows:
        s = r["score"]
        r["trend"] = "-" if s is None else "UP" if s >= args.trend else "DOWN" if s <= -args.trend else "SIDE"
        r["tf"] = " ".join("+" if c > 0 else "-" for c in r["comps"]) if r["comps"] else None
        r["used"] = r["today"] / r["typical_now"] * 100 if r["today"] is not None else None
        r["lot"], r["risk_usd"], r["too_small"] = size_lot(r, risk_money)
    rows.sort(key=lambda r: -abs(r["score"] or 0))
    return rows


def make_parser():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("symbols", nargs="*")
    ap.add_argument("--sl", type=float, default=0.7, help="SL as a multiple of the typical day (default 0.7)")
    ap.add_argument("--tp", type=float, default=1.0, help="TP as a multiple of the typical day (default 1.0)")
    ap.add_argument("--sl-tf", choices=list(SL_TIMEFRAMES), default="D1",
                    help="Base SL/TP on the typical D1 day (default) or the typical H4 candle")
    ap.add_argument("--risk", type=float, default=1.0, help="Risk per trade, %% of balance (default 1)")
    ap.add_argument("--max-open-risk", type=float, default=3.0,
                    help="Max %% of account all open trades may lose together (default 3)")
    ap.add_argument("--max-trades", type=int, default=3, help="Max new trades per day (default 3)")
    ap.add_argument("--max-loss", type=float, default=3.0, help="Stop for the day at this %% loss (default 3)")
    ap.add_argument("--max-losses", type=int, default=3, help="Stop after this many losses in a row today (default 3)")
    ap.add_argument("--max-week-loss", type=float, default=0, help="Stop for the week at this %% loss (default off)")
    ap.add_argument("--max-month-loss", type=float, default=0, help="Stop for the month at this %% loss (default off)")
    ap.add_argument("--floor", type=float, default=0, help="Stop live trading at/below this balance (default off)")
    ap.add_argument("--trend", type=float, default=0.5,
                    help="Trend score needed to call UP/DOWN, same as the DTF indicator threshold (default 0.5)")
    return ap


def main():
    args = make_parser().parse_args()

    if not mt5.initialize():
        sys.exit(f"Could not connect to MT5 - is the terminal open and logged in? {mt5.last_error()}")
    acc = mt5.account_info()
    now = dt.datetime.now()

    wanted = args.symbols or DEFAULT_SYMBOLS
    syms = []
    for name in wanted:
        s = resolve(name)
        if s is None:
            print(f"  {name}: not found at this broker")
        elif s not in syms:
            syms.append(s)
    if not args.symbols:
        syms += sorted(traded_symbols() - set(syms))

    today = server_today()
    # Size off the smaller of balance and equity: open losing trades reduce what you really have.
    balance = min(acc.balance, acc.equity) if acc else 0
    risk_money = balance * args.risk / 100
    rows = build_rows(syms, today, args, risk_money)
    if not rows:
        sys.exit("No daily data for any symbol - check MT5 is connected (bottom-right corner) and try again.")

    print(f"\nDAILY CANDLE MOVEMENT (D1, high to low) in pips - {acc.server if acc else ''} - {now:%Y-%m-%d %H:%M}")
    print("Each number = how far ONE daily candle moves from its high to its low.")
    print("ALL NUMBERS ARE IN PIPS, except those marked % or $ (and Lot size).\n")
    if all(r["today"] is None for r in rows):
        print("Market is closed today (weekend/holiday) - 'Today so far' is blank; everything else is up to date.\n")
    # (key, width, header line 1, header line 2)
    cols = [("symbol", 8, "", "Pair"),
            ("trend", 5, "D1", "trend"), ("score", 7, "Trend", "score"), ("tf", 11, "Each", "20/60/120"),
            ("sep", 3, "", " |"),
            ("today", 7, "Today", "so far"), ("used", 7, "Used", "of day"),
            ("room_up", 6, "Room", "up"), ("room_down", 6, "Room", "down"),
            ("yesterday", 10, "Yesterday", "candle"),
            ("typical_now", 9, "Typical", "day now"), ("vol_vs_6m", 7, "Vol", "vs 6m"),
            *([("sl_unit", 7, "Typ.", "H4 cdl")] if args.sl_tf == "H4" else []),
            ("SL", 6, "Sugg.", "SL"), ("TP", 6, "Sugg.", "TP"),
            ("lot", 6, "Lot", "size"), ("risk_usd", 9, "Loss if", "SL hit"),
            ("sep", 3, "", " |"),
            ("avg_12m", 8, "Avg day", "12m"), ("avg_6m", 8, "Avg day", "6m"),
            ("typical_6m", 8, "Typical", "day 6m"), ("quiet_6m", 7, "Quiet", "day 6m"),
            ("busy_6m", 7, "Busy", "day 6m"), ("spread_normal", 7, "Normal", "spread"),
            ("spread", 7, "Spread", "now")]
    for i in (2, 3):
        print("".join(c[i].ljust(c[1]) if c[0] == "symbol" else c[i].rjust(c[1]) for c in cols))
    for r in rows:
        line = ""
        for k, w, *_ in cols:
            if k == "symbol":
                line += f"{r[k].rstrip('m'):<{w}}"
            elif k == "sep":
                line += "  |"
            elif r[k] is None:
                line += "-".rjust(w)
            elif k in ("trend", "tf"):
                line += f"{r[k]:>{w}}"
            elif k == "score":
                line += f"{r[k]:+.2f}".rjust(w)
            elif k in ("used", "vol_vs_6m"):
                line += f"{r[k]:>{w - 1}.0f}%"
            elif k == "lot":
                line += f"{r[k]:.2f}".rjust(w)
            elif k in ("spread", "spread_normal"):
                line += f"{r[k]:.1f}".rjust(w)
            elif k == "risk_usd":
                line += (f"${r[k]:.2f}" + ("!" if r["too_small"] else " ")).rjust(w)
            else:
                line += f"{r[k]:.0f}".rjust(w)
        flag = "  <- hot" if r["vol_vs_6m"] >= 120 else "  <- quiet" if r["vol_vs_6m"] <= 80 else ""
        room = {"UP": r["room_up"], "DOWN": r["room_down"]}.get(r["trend"])
        if room is not None and room < 0.25 * r["typical_now"]:
            flag += f"  <- {r['trend']} trend, but little room {r['trend'].lower()} left today"
        if (r["spread_normal"] or r["spread"]) >= 0.15 * r["typical_now"]:
            flag += "  <- spread eats >15% of a day"
        if r["too_small"] and r["risk_usd"] is not None:
            flag += (f"  <- SKIP: even {r['vol_min']} lot loses ${r['risk_usd']:.2f}"
                     f" ({r['risk_usd'] / balance * 100:.1f}%) at this SL")
        print(line + flag)
    print(f"\nD1 trend      = UP / DOWN when the trend score is at least +{args.trend} / -{args.trend}; SIDE = no clear")
    print(f"                trend (a trend trader stands aside). Pairs are sorted strongest trend first.")
    print(f"Trend score   = -1 (strong down) .. +1 (strong up), from the last CLOSED daily candle - same")
    print(f"                maths and settings as your DTF_Dashboard indicator (20/60/120, ATR 20, k 2.0).")
    print(f"Each 20/60/120 = direction over the last 20, 60 and 120 days. '+ + +' or '- - -' = all agree")
    print(f"                (cleanest trend); mixed signs = the timeframes disagree.")
    print(f"Today so far  = pips today's daily candle has moved (high to low) up to now - it is still forming.")
    print(f"Used of day   = today so far as % of a typical day. Near/over 100% = most of today's move is done.")
    print(f"Room up/down  = pips price can still travel today UP (for a buy) or DOWN (for a sell) if today")
    print(f"                turns out a typical-sized day. 0 = a typical day's move is already done that way.")
    print(f"                Not a ceiling: about 1 day in 4 is bigger than 'Busy day'.")
    print(f"Typical day now = the middle value of the last {RECENT_DAYS} daily candles.")
    if args.sl_tf == "H4":
        print(f"Typ. H4 cdl   = the middle value of the last ~20 days of H4 candles. SL/TP are based on this:")
        print(f"                SL = {args.sl} x typical H4 candle, TP = {args.tp} x typical H4 candle.")
    else:
        print(f"                SL/TP are based on this: SL = {args.sl} x typical day, TP = {args.tp} x typical day.")
    print(f"Vol vs 6m     = typical day now vs typical day over 6 months (100% = normal).")
    print(f"Lot size      = lot that loses about {args.risk}% of your account (${risk_money:.2f} of ${balance:.2f}) if the")
    print(f"                suggested SL is hit. Rounded DOWN, so the real loss is at or under that.")
    print(f"                '!' / SKIP = even the smallest lot ({rows[0]['vol_min']}) loses MORE than {args.risk}% here.")
    print(f"                      Skip the pair - do NOT take it with a smaller SL than suggested.")
    print(f"                Change the risk with e.g. --risk 0.5 (half a percent).")
    print(f"Right of the | = the same daily-candle measure averaged over 12 / 6 months, for reference.")
    print(f"Normal spread = the usual spread (middle value over ~20 days). 'Spread now' is far wider at")
    print(f"                weekends and around the daily rollover - wait for it to come back to normal.")
    print("\nAll the plain numbers in the table are PIPS, not points.")
    print("  If MT5 or an EA asks for POINTS instead: currency pairs 1 pip = 10 points")
    print("  (SL 30 pips = 300 points); gold on this broker 1 pip = 100 points (675 pips = 67500 points).")
    print("  Normal pairs: 1 pip = 0.0001 in price.  JPY pairs: 1 pip = 0.01.  Gold: 1 pip = $0.10.")
    print("  Example: EURUSD buy at 1.10000 with a 30 pips SL -> SL price 1.09700.")
    print("  Example: XAUUSD buy at 4000.00 with a 675 pips SL -> SL price 3932.50 ($67.50 away).")

    warnings = open_trades_check(rows, balance, args.max_open_risk)
    stops = daily_limits_check(today, acc.equity, acc.balance, args.max_trades, args.max_loss, args.max_losses,
                               args.max_week_loss, args.max_month_loss, args.floor)
    mt5.shutdown()
    print()
    for w in warnings:
        print(f"  ! {w}")
    if stops:
        print("\n  >>> STOP TRADING FOR TODAY: " + "; ".join(stops) + ".")
        print("  >>> Manage the trades you have open, but open nothing new until tomorrow.")
    else:
        print("\n  >>> OK to trade today - within all your limits. Use the lot size from the table.")

    out = os.path.join(HERE, "daily_range.csv")
    try:
        with open(out, "w", newline="") as f:
            keys = [k for k in rows[0] if k != "comps"]
            w = csv.DictWriter(f, fieldnames=["date"] + keys)
            w.writeheader()
            for r in rows:
                w.writerow({"date": now.date(),
                            **{k: round(r[k], 2) if isinstance(r[k], float) else r[k] for k in keys}})
        print(f"Saved {out}")
    except PermissionError:
        print(f"Could not save {out} - it is open in Excel. Close it and run again to refresh the file.")


if __name__ == "__main__":
    main()
