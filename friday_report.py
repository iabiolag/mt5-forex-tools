"""Friday report: the week's results and rule breaks for your main account and your FTMO
challenge on one browser page. Built to run by itself every Friday night (see README).

    python friday_report.py                    # this week (Mon-Thu: last week), opens the browser
    python friday_report.py --week-of 2026-10-19
    python friday_report.py --no-ftmo          # main account only
    python friday_report.py --no-open          # write the page, don't open it

Rules come from settings.bat and settings_ftmo.bat (or the .example files) - the same values
the launchers use. The page is saved in reports/ (git-ignored).
Read-only: nothing here places, modifies or closes trades.
"""
import argparse, datetime as dt, html, os, re, sys, time, webbrowser
from types import SimpleNamespace
import MetaTrader5 as mt5
import daily_range as dr
import prop_rules
import weekly_report as wr

HERE = os.path.dirname(os.path.abspath(__file__))
esc = html.escape


def read_settings(name):
    """KEY=VALUE from the `set "KEY=VALUE"` lines of name.bat, else name.example.bat."""
    for fn in (f"{name}.bat", f"{name}.example.bat"):
        path = os.path.join(HERE, fn)
        if os.path.exists(path):
            with open(path, encoding="utf-8", errors="replace") as f:
                return dict(re.findall(r'(?im)^\s*set\s+"(\w+)=(.*)"\s*$', f.read()))
    return {}


def account_args(s, prop):
    num = lambda k, d=0: float(s.get(k) or d)
    a = SimpleNamespace(
        terminal=s.get("TERMINAL", ""), pairs=s.get("PAIRS", "").split(), trend=0.5,
        max_trades=int(num("MAX_TRADES", 3)), max_loss=num("MAX_DAY_LOSS", 3), max_losses=int(num("MAX_LOSSES", 3)),
        max_lot=num("MAX_LOT"), max_open=int(num("MAX_OPEN")), floor=num("FLOOR"),
        risk=num("RISK", 1), commission=num("COMMISSION"))
    if prop:
        a.prop_initial, a.prop_daily, a.prop_max = num("PROP_INITIAL"), num("PROP_DAILY", 3), num("PROP_MAX", 10)
        a.prop_target, a.prop_buffer = num("PROP_TARGET", 10), num("PROP_BUFFER", 1)
    return a


def read_account(label, args, prop):
    """Everything the page needs from one terminal, or {'error': ...}."""
    if args.terminal and not os.path.exists(args.terminal):
        return {"label": label, "error": f"terminal not found: {args.terminal}"}
    try:
        dr.connect(args)
    except SystemExit as e:
        return {"label": label, "error": str(e)}
    try:
        acc = mt5.account_info()
        offset = round((dr.server_now() - time.time()) / 3600)
        trades, _ = wr.load_trades(args)
        status = prop_rules.status(args) if prop else None
        positions = [(p.symbol, "BUY" if p.type == mt5.POSITION_TYPE_BUY else "SELL", p.volume, p.profit, bool(p.sl))
                     for p in mt5.positions_get() or []]
    finally:
        mt5.shutdown()
    return {"label": label, "args": args, "server": acc.server, "login": acc.login, "balance": acc.balance,
            "equity": acc.equity, "offset": offset, "trades": trades, "prop": status, "positions": positions}


def report_week(arg):
    """Monday of the week to report: --week-of, else this week from Friday to Sunday, else last week."""
    d = dt.date.fromisoformat(arg) if arg else dt.date.today()
    if not arg and d.weekday() < 4:
        d -= dt.timedelta(days=7)
    return wr.week_start(d)


def money(v):
    return f"{'+' if v >= 0 else '−'}${abs(v):,.2f}"


def cls(v):
    return "pos" if v > 0 else "neg" if v < 0 else ""


def legs(t):
    """Currency exposure of a trade: BUY EURUSD = long EUR, short USD."""
    sym = t["symbol"].upper()
    base, quote = sym[:3], sym[3:6]
    up = 1 if t["side"] == "BUY" else -1
    return {base: up, quote: -up}


def same_bet(ts):
    """Trades that were open at the same time as another trade betting the same way on a currency."""
    hit = set()
    for i, a in enumerate(ts):
        for b in ts[i + 1:]:
            if a["opened"] < b["closed"] and b["opened"] < a["closed"] and a["symbol"] != b["symbol"]:
                la, lb = legs(a), legs(b)
                if any(c in lb and lb[c] == s for c, s in la.items()):
                    hit.update((id(a), id(b)))
    return [t for t in ts if id(t) in hit]


def rollover_hits(ts):
    """Trades stopped out within an hour either side of the broker's midnight (spreads widen 5-10x)."""
    return [t for t in ts if t.get("exit") == "SL hit"
            and (t["closed"].hour == 23 or t["closed"].hour == 0) and t["opened"] < t["closed"] - dt.timedelta(minutes=5)]


def mirrored(a, b):
    """Same pair, same direction, opened on both accounts within an hour (compared in UTC)."""
    out = []
    for x in a["week"]:
        ux = x["opened"] - dt.timedelta(hours=a["offset"])
        for y in b["week"]:
            uy = y["opened"] - dt.timedelta(hours=b["offset"])
            if x["symbol"] == y["symbol"] and x["side"] == y["side"] and abs(ux - uy) <= dt.timedelta(hours=1):
                out.append((x, y))
                break
    return out


def tips(a):
    """Plain-words fix for each rule, using the account's own limits."""
    g = a["args"]
    return {
        "no SL on the order ticket": "Type the SL and TP into the order ticket before you click Buy/Sell.",
        "pair not on my list": f"Only {' '.join(g.pairs) or 'your plan pairs'}. Add a pair on purpose after 30 trades, not trade by trade.",
        "pair was sideways (no trend)": "No trade unless the tool shows + + + (buy) or − − − (sell).",
        "trend not clean (20/60/120 not all + or all -)": "Wait until 20, 60 and 120 all agree.",
        "against the D1 trend": "Buy only in an UP trend, sell only in a DOWN trend.",
        "too many trades that day": f"Max {g.max_trades} new trades a day. When the tool says STOP, close MT5.",
        "too many trades open": f"Max {g.max_open} trades open at once.",
        "re-entry: same pair closed earlier today": "Once a pair is closed, leave it until tomorrow.",
        "already had a trade open on this pair": "One trade per pair.",
        "after a losing streak": f"Stop for the day after {g.max_losses} losses in a row.",
        "day already down past the loss limit": f"Stop for the day at −{g.max_loss:g}%.",
        "lot too big": f"Never more than {g.max_lot:g} lot.",
        "below the balance floor": f"At ${g.floor:,.0f} or less: stop live trading and go back to testing.",
    }


def trade_table(ts):
    rows = []
    for t in ts:
        tags = "".join(f'<span class="tag">{esc(m)}</span>' for m in t["broke"]) or '<span class="tag ok">clean</span>'
        rows.append(f'<tr><td>{t["opened"]:%a %d %H:%M}</td><td>{t["closed"]:%a %d %H:%M}</td><td><b>{esc(t["symbol"])}</b></td>'
                    f'<td>{t["side"]}</td><td class="n">{t["lot"]:g}</td><td class="n {cls(t["net"])}">{money(t["net"])}</td>'
                    f'<td>{esc(t.get("exit", ""))}</td><td>{esc(t["with_trend"])}</td><td>{tags}</td></tr>')
    return ('<div class="scroll"><table><thead><tr><th>Opened</th><th>Closed</th><th>Pair</th><th>Side</th><th class="n">Lot</th>'
            '<th class="n">Net</th><th>How it closed</th><th>D1 trend</th><th>Rules broken</th></tr></thead><tbody>'
            + "".join(rows) + "</tbody></table></div>")


def account_section(a):
    if "error" in a:
        return f'<h2>{esc(a["label"])}</h2><div class="box bad">Could not read this account: {esc(a["error"])}</div>'
    ts, g, tip = a["week"], a["args"], tips(a)
    if not ts:
        return f'<h2>{esc(a["label"])}</h2><p class="small">No trades closed this week.</p>'
    counts = {}
    for t in ts:
        for k in {wr.rule_kind(m) for m in t["broke"]}:
            counts[k] = counts.get(k, 0) + 1
    rows = "".join(f'<tr><td>{esc(k)}</td><td class="n neg">{n} of {len(ts)}</td><td>{esc(tip.get(k, ""))}</td></tr>'
                   for k, n in sorted(counts.items(), key=lambda kv: -kv[1]))
    out = [f'<h2>{esc(a["label"])}: rules broken this week</h2>']
    if rows:
        out.append('<div class="scroll"><table><thead><tr><th>Rule</th><th class="n">Trades</th><th>The fix</th></tr></thead>'
                   f'<tbody>{rows}</tbody></table></div>')
    else:
        out.append('<div class="box ok">Every trade followed every rule this week.</div>')

    per_day = {}
    for t in ts:
        per_day[t["entry_day"]] = per_day.get(t["entry_day"], 0) + 1
    busy = [f"{d:%a} {n}" for d, n in sorted(per_day.items()) if n > g.max_trades]
    notes = []
    if busy:
        notes.append(f"Days over your {g.max_trades}-a-day limit: {', '.join(busy)} trades opened.")
    s = a["stats"]
    if s["payoff"] is not None and s["payoff"] < 1:
        notes.append(f"Average win {money(s['avg_win'])} vs average loss −${s['avg_loss']:,.2f}: losers are bigger than winners. "
                     "Let the TP (2× the SL) work instead of closing small winners.")
    if not g.max_lot and s["avg_risk_pct"] is not None and s["avg_risk_pct"] < g.risk / 2:
        notes.append(f"Average risk per trade was {s['avg_risk_pct']:.2f}% against your planned {g.risk:g}%. "
                     "The SLs were very tight and lots were picked by hand. Use the tool's SL and lot.")
    bet = same_bet(ts)
    if bet:
        notes.append(f"{len(bet)} trades were open at the same time as another bet the same way on the same currency "
                     f"({', '.join(sorted({t['symbol'] for t in bet}))}). Your plan counts those as ONE trade.")
    roll = rollover_hits(ts)
    if roll:
        notes.append(f"{len(roll)} SL hit(s) around the broker's midnight rollover cost {money(sum(t['net'] for t in roll))} "
                     f"({', '.join(t['symbol'] for t in roll)}). Spreads widen 5–10× then, so don't hold tight SLs through it.")
    good = []
    if not counts.get("against the D1 trend"):
        good.append("no trades against the trend")
    if g.max_lot and not counts.get("lot too big"):
        good.append(f"lot never above {g.max_lot:g}")
    if not counts.get("after a losing streak") and not counts.get("day already down past the loss limit"):
        good.append("no trading after a stop rule")
    clean = sum(1 for t in ts if not t["broke"])
    if clean:
        good.append(f"{clean} clean trade(s)")
    if notes:
        out.append('<div class="box warn"><b>Also this week</b><ul>' + "".join(f"<li>{esc(n)}</li>" for n in notes) + "</ul></div>")
    if good:
        out.append(f'<div class="box ok"><b>Done well:</b> {esc(", ".join(good))}.</div>')
    out.append(f'<h3>Every {esc(a["label"])} trade this week</h3>' + trade_table(ts))
    return "\n".join(out)


def prop_section(a):
    p, g = a["prop"], a["args"]
    i = p["initial"]
    days = {}
    for t in a["week"]:
        day = (t["closed"] - dt.timedelta(hours=p["shift"])).date()  # prop day = Prague midnight
        days[day] = days.get(day, 0.0) + t["net"]
    worst_day, worst = min(days.items(), key=lambda kv: kv[1]) if days else (None, 0.0)
    day_cap, max_cap = g.prop_daily / 100 * i, g.prop_max / 100 * i
    used_max = max(0.0, (p["peak"] - p["equity"]) / max_cap * 100)
    need = max(0.0, p["target"] - p["balance"])
    breached = p["equity"] <= p["daily_limit"] or p["equity"] <= p["max_limit"]
    week_net = a["stats"]["net"] if a["week"] else 0.0

    def card(title, ok, status, text, bar=None, neg=False):
        b = f'<div class="bar{" neg" if neg else ""}"><div style="width:{min(100, max(0, bar)):.0f}%"></div></div>' if bar is not None else ""
        return (f'<div class="card"><div class="k">{esc(title)}</div><div class="status {"pos" if ok else "neg"}">{esc(status)}</div>'
                f'<div class="small">{esc(text)}</div>{b}</div>')

    worst_txt = f"Worst day this week: {worst_day:%a} {money(worst)} ({max(0, -worst) / day_cap * 100:.0f}% of the limit)." if worst_day else "No trades closed this week."
    cards = [
        card(f"Maximum Daily Loss ({g.prop_daily:g}% = ${day_cap:,.0f})", worst > -day_cap, "OK" if worst > -day_cap else "CHECK FTMO",
             f"{worst_txt} Room right now: ${p['equity'] - p['daily_limit']:,.2f}.", max(0, -worst) / day_cap * 100),
        card(f"Maximum Loss (floor ${p['max_limit']:,.0f})", p["equity"] > p["max_limit"], "OK" if p["equity"] > p["max_limit"] else "BROKEN",
             f"Equity ${p['equity']:,.2f}, ${p['equity'] - p['max_limit']:,.2f} above the floor. {used_max:.0f}% of the limit used.", used_max, True),
        card(f"Profit Target (${p['target']:,.0f})", p["balance"] >= p["target"], f"{(p['balance'] - i) / i * 100:+.2f}%",
             f"Still needed: ${need:,.2f}.", max(0, (p["balance"] - i) / (p["target"] - i) * 100)),
        card("Best Day rule (≤ 50%)", p["best_share"] <= 50, f"{p['best_share']:.0f}%" if p["best_day"] else "no profitable day yet",
             f"Best day {p['best_day']}: {money(p['best'])} of {money(p['positive_sum'])}." if p["best_day"] else ""),
    ]
    pace = []
    if need > 0:
        if week_net > 0:
            pace.append(f"At this week's pace ({money(week_net)}) the target is about {need / week_net:.0f} weeks away.")
        elif a["week"]:
            pace.append(f"This week moved the account {money(week_net)}, away from the target.")
        r = g.risk / 100 * i
        pace.append(f"At your planned ${r:,.0f} risk with a 2× TP, a winner pays about ${2 * r:,.0f}, so about "
                    f"{need / (2 * r):.0f} more winners than losers reaches the target. Trading more or bigger does not make it faster.")
    head = ('<div class="box bad"><b>An FTMO limit looks broken. Check your FTMO account page.</b></div>' if breached else
            '<div class="box ok"><b>No FTMO rule is broken. The challenge is still alive.</b></div>')
    return (f'<h2>FTMO: are you meeting the rules?</h2>{head}<div class="grid">{"".join(cards)}</div>'
            + "".join(f'<p>{esc(x)}</p>' for x in pace)
            + '<p class="small">The daily-loss check uses closed results, because MT5 history does not record how low equity went '
              'inside a day. Check trading days, inactivity, news and weekend rules on your FTMO dashboard.</p>')


CSS = """
:root{--bg:#f6f7f9;--card:#fff;--text:#1b1f24;--muted:#5b6470;--line:#e2e5ea;--pos:#127a3e;--neg:#c0392b;--warnbg:#fff4e0;--okbg:#e7f6ec;--badbg:#fdecea;--tag:#eef0f4;--accent:#2457c5}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#111418;--card:#1a1e24;--text:#e6e9ee;--muted:#9aa3ae;--line:#2c323b;--pos:#4cc47f;--neg:#ff7b6b;--warnbg:#3a2c12;--okbg:#14301f;--badbg:#3a1a17;--tag:#262c35;--accent:#7aa2ff}}
:root[data-theme="dark"]{--bg:#111418;--card:#1a1e24;--text:#e6e9ee;--muted:#9aa3ae;--line:#2c323b;--pos:#4cc47f;--neg:#ff7b6b;--warnbg:#3a2c12;--okbg:#14301f;--badbg:#3a1a17;--tag:#262c35;--accent:#7aa2ff}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:1100px;margin:0 auto;padding:24px 16px 60px}h1{font-size:26px;margin:0 0 4px}h2{font-size:20px;margin:36px 0 12px}h3{font-size:16px;margin:20px 0 8px}
.sub{color:var(--muted);margin:0 0 20px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px}.k{color:var(--muted);font-size:13px}
.v{font-size:26px;font-weight:700;font-variant-numeric:tabular-nums}.pos{color:var(--pos)}.neg{color:var(--neg)}
.scroll{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:10px}table{border-collapse:collapse;width:100%;font-size:13.5px}
th,td{padding:7px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top;white-space:nowrap}td:last-child{white-space:normal;min-width:240px}
th{color:var(--muted);font-weight:600;font-size:12.5px}.n{text-align:right;font-variant-numeric:tabular-nums}
.tag{display:inline-block;background:var(--tag);border-radius:4px;padding:1px 6px;margin:1px 3px 1px 0;font-size:12px}.tag.ok{background:var(--okbg)}
.box{border-radius:10px;padding:12px 16px;margin:12px 0}.ok{background:var(--okbg)}.bad{background:var(--badbg)}.warn{background:var(--warnbg)}
.status{font-weight:700}ul{padding-left:22px;margin:6px 0}li{margin:4px 0}.bar{height:10px;background:var(--line);border-radius:5px;overflow:hidden;margin:6px 0}
.bar>div{height:100%;background:var(--accent)}.bar.neg>div{background:var(--neg)}.small{font-size:13px;color:var(--muted)}
"""


def page(monday, accounts):
    sunday = monday + dt.timedelta(days=6)
    ok = [a for a in accounts if "error" not in a]
    cards = []
    for a in ok:
        s, ts = a["stats"], a["week"]
        if not ts:
            cards.append(f'<div class="card"><div class="k">{esc(a["label"])} this week</div><div class="v">$0.00</div>'
                         f'<div class="small">no trades closed · balance ${a["balance"]:,.2f}</div></div>')
            continue
        won = sum(t["net"] for t in ts if t["net"] > 0)
        start = a["balance"] - s["net"]
        cards.append(f'<div class="card"><div class="k">{esc(a["label"])} this week</div><div class="v {cls(s["net"])}">{money(s["net"])}</div>'
                     f'<div class="small">{s["net"] / start * 100 if start > 0 else 0:+.1f}% · {s["n"]} trades · {s["wins"]} won, {s["n"] - s["wins"]} lost<br>'
                     f'won ${won:,.2f}, lost ${won - s["net"]:,.2f} · balance ${start:,.2f} → ${a["balance"]:,.2f}</div></div>')
    n = sum(len(a["week"]) for a in ok)
    clean = sum(1 for a in ok for t in a["week"] if not t["broke"])
    if len(ok) > 1:
        tot = sum(a["stats"]["net"] for a in ok if a["week"])
        cards.append(f'<div class="card"><div class="k">All accounts</div><div class="v {cls(tot)}">{money(tot)}</div>'
                     f'<div class="small">{n} trades</div></div>')
    cards.append(f'<div class="card"><div class="k">Trades that followed every rule</div><div class="v {"pos" if n and clean == n else "neg"}">{clean} of {n}</div>'
                 f'<div class="small">{" · ".join(esc(a["label"]) + " " + str(sum(1 for t in a["week"] if not t["broke"])) + " of " + str(len(a["week"])) for a in ok)}</div></div>')

    body = [f'<h1>Weekly Trading Report</h1><p class="sub">Week of {monday:%a %d %b} – {sunday:%a %d %b %Y} · '
            + " · ".join(f'{esc(a["label"])} #{a["login"]}' for a in ok)
            + f' · made {dt.datetime.now():%a %d %b %H:%M} · read-only, nothing was changed on any account</p>',
            f'<div class="grid">{"".join(cards)}</div>']
    for a in ok:
        if a["positions"]:
            items = "".join(f'<li>{esc(sym)} {side} {vol:g} lot, {money(pl)} open{"" if sl else " — NO STOP LOSS"}</li>'
                            for sym, side, vol, pl, sl in a["positions"])
            body.append(f'<div class="box warn"><b>{esc(a["label"])} still has open trades going into the weekend:</b><ul>{items}</ul></div>')
    for a in accounts:
        if "error" in a:
            body.append(account_section(a))
    for a in ok:
        if a["prop"]:
            body.append(prop_section(a))
    if len(ok) > 1:
        pairs = mirrored(ok[0], ok[1])
        if pairs:
            items = "".join(f'<li>{x["symbol"]} {x["side"]}: {esc(ok[0]["label"])} {x["opened"]:%a %H:%M}, {esc(ok[1]["label"])} {y["opened"]:%a %H:%M} (broker times)</li>'
                            for x, y in pairs)
            body.append(f'<h2>Same trade on both accounts</h2><div class="box bad">{len(pairs)} trade(s) were placed the same way on both accounts '
                        f'within an hour. Your FTMO plan says never trade both accounts the same way at the same time.<ul>{items}</ul></div>')
    for a in ok:
        body.append(account_section(a))
    body.append('<p class="small">Made by friday_report.py from your MT5 history (broker times, costs included). '
                'Rules come from settings.bat and settings_ftmo.bat.</p>')
    return (f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
            f'<title>Weekly Trading Report</title><style>{CSS}</style></head><body><main>{"".join(body)}</main></body></html>')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--week-of", help="Report the week containing this date (YYYY-MM-DD)")
    ap.add_argument("--no-ftmo", action="store_true", help="Main account only")
    ap.add_argument("--no-open", action="store_true", help="Don't open the page in the browser")
    args = ap.parse_args()

    monday = report_week(args.week_of)
    accounts = [read_account("Main account", account_args(read_settings("settings"), False), False)]
    if not args.no_ftmo:
        accounts.append(read_account("FTMO", account_args(read_settings("settings_ftmo"), True), True))
    for a in accounts:
        if "error" not in a:
            a["week"] = [t for t in a["trades"] if monday <= t["closed"].date() < monday + dt.timedelta(days=7)]
            a["stats"] = wr.stats(a["week"])
            a["label"] = a["server"].split("-")[0] or a["label"]  # "Exness-MT5Real27" -> "Exness"

    os.makedirs(os.path.join(HERE, "reports"), exist_ok=True)
    out = os.path.join(HERE, "reports", f"week_{monday:%Y-%m-%d}.html")
    with open(out, "w", encoding="utf-8") as f:
        f.write(page(monday, accounts))
    print("Saved", out)
    if not args.no_open:
        webbrowser.open("file:///" + out.replace("\\", "/"))


if __name__ == "__main__":
    main()
