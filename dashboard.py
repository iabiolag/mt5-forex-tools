"""Browser dashboard for the Daily Pips SL-TP tool: the same numbers, easier to read.

Run with MT5 open and logged in, then it opens http://127.0.0.1:8765 in your browser:
    python dashboard.py                              # daily_range.py's default settings
    python dashboard.py --port 8800                  # another port
    python dashboard.py --pairs EURUSD GBPUSD        # only these pairs are "my plan pairs"
    dashboard.bat                                    # your settings from settings.bat

Page 1: every pair (simple cards or the full table) with a search box.
Page 2: one pair on its own - plan checklist, chart, SL/TP prices, your history on it.
Only listens on this computer (127.0.0.1). Close the black window to stop it.
Read-only: nothing here places, modifies or closes trades.
"""
import contextlib, datetime as dt, io, json, os, sys, threading, time, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
import MetaTrader5 as mt5
import daily_range as dr
import pnl_report

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE_SECONDS = 60
CHART_DAYS = 90
utc = dt.datetime.utcfromtimestamp


def parse_args():
    ap = dr.make_parser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--pairs", nargs="*", default=[], help="Pairs your plan allows (default: any pair)")
    ap.add_argument("--max-lot", type=float, default=0, help="Biggest lot your plan allows (default 0 = no cap)")
    ap.add_argument("--max-open", type=int, default=3, help="Max trades open at once (default 3)")
    ap.add_argument("--no-browser", action="store_true", help="Don't open the browser")
    return ap.parse_args()


def clean(sym):
    return sym.removesuffix("m")


def quiet(fn, *a):
    """Run one of daily_range's printing checks and keep only its return value + text."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        out = fn(*a)
    return out, buf.getvalue().strip()


class Data:
    def __init__(self, args):
        self.args = args
        self.plan = {p.upper() for p in args.pairs}
        self.overview_cache = None
        self.overview_time = 0
        self.trades_cache = None

    def connect(self):
        if mt5.terminal_info() is None and not mt5.initialize():
            raise RuntimeError(f"Could not connect to MT5 - is the terminal open and logged in? {mt5.last_error()}")

    def account(self):
        acc = mt5.account_info()
        balance = min(acc.balance, acc.equity) if acc else 0
        return acc, balance, balance * self.args.risk / 100

    def row_json(self, r):
        out = {k: v for k, v in r.items() if k != "comps"}
        out["symbol"] = clean(r["symbol"])
        out["broker_symbol"] = r["symbol"]
        out["on_plan"] = bool(self.plan) and out["symbol"] in self.plan
        out["comps"] = r["comps"]
        out["plan_lot"], out["plan_loss"] = self.plan_lot(r)
        return out

    def plan_lot(self, r):
        """The lot your plan allows - the 1% lot capped at --max-lot, never below the broker
        minimum - and what it loses if the SL is hit."""
        if r["lot"] is None:
            return None, None
        cap = self.args.max_lot or r["lot"]  # 0 = no cap
        lot = max(r["vol_min"], min(r["lot"], cap))
        return lot, lot * r["SL"] * r["pip_value"]

    def overview(self, force=False):
        if not force and self.overview_cache and time.time() - self.overview_time < CACHE_SECONDS:
            return self.overview_cache
        self.connect()
        a = self.args
        acc, balance, risk_money = self.account()
        syms = []
        for name in list(dr.DEFAULT_SYMBOLS) + sorted(self.plan):
            s = dr.resolve(name)
            if s and s not in syms:
                syms.append(s)
        syms += sorted(dr.traded_symbols() - set(syms))
        today = dr.server_today()
        rows = dr.build_rows(syms, today, a, risk_money)
        if not rows:
            raise RuntimeError("No daily data for any symbol - check MT5 is connected (bottom-right corner).")
        warnings, open_text = quiet(dr.open_trades_check, rows, balance, a.max_open_risk)
        stops, limits_text = quiet(dr.daily_limits_check, today, acc.equity, acc.balance,
                                   a.max_trades, a.max_loss, a.max_losses,
                                   a.max_week_loss, a.max_month_loss, a.floor)
        positions = mt5.positions_get() or []
        self.rows = {r["symbol"]: r for r in rows}
        self.today = today
        self.stops = stops
        self.overview_cache = {
            "generated": dt.datetime.now().strftime("%a %d %b %Y, %H:%M"),
            "server": acc.server if acc else "",
            "today": today.isoformat(),
            "market_open": any(r["today"] is not None for r in rows),
            "account": {"balance": acc.balance, "equity": acc.equity, "sizing": balance,
                        "risk_money": risk_money, "currency": acc.currency},
            "settings": {"sl": a.sl, "tp": a.tp, "sl_tf": a.sl_tf, "risk": a.risk, "trend": a.trend,
                         "max_trades": a.max_trades, "max_loss": a.max_loss, "max_losses": a.max_losses,
                         "max_open_risk": a.max_open_risk, "max_open": a.max_open, "max_lot": a.max_lot,
                         "max_week_loss": a.max_week_loss, "max_month_loss": a.max_month_loss, "floor": a.floor,
                         "plan_pairs": sorted(self.plan)},
            "rows": [self.row_json(r) for r in rows],
            "warnings": warnings, "stops": stops,
            "open_text": open_text, "limits_text": limits_text,
            "open_count": len(positions),
        }
        self.overview_time = time.time()
        self.trades_cache = None
        return self.overview_cache

    def trades(self):
        if self.trades_cache is None:
            self.trades_cache = pnl_report.load_trades()[0]
        return self.trades_cache

    def pair(self, name):
        ov = self.overview()
        sym = dr.resolve(name)
        if sym is None:
            return {"error": f"'{name.upper()}' is not a symbol at this broker. Try e.g. EURUSD or GBP."}
        r = self.rows.get(sym)
        if r is None:  # not in the overview list - analyse it now
            _, _, risk_money = self.account()
            built = dr.build_rows([sym], self.today, self.args, risk_money)
            if not built:
                return {"error": f"MT5 has no daily candles for {clean(sym)} yet. Open its D1 chart in MT5 and try again."}
            r = built[0]
            self.rows[sym] = r
        info = mt5.symbol_info(sym)
        tick = mt5.symbol_info_tick(sym)
        pip = dr.pip_size(sym, info)

        # Closed Mon-Fri daily candles (drops the forming one and Sunday-evening stubs).
        rates = dr.load_rates(sym)
        candles, forming = [], None
        for x in rates:
            d = utc(int(x["time"])).date()
            if d.weekday() >= 5:
                continue
            c = {"date": d.isoformat(), "open": float(x["open"]), "high": float(x["high"]),
                 "low": float(x["low"]), "close": float(x["close"])}
            if d == self.today:
                forming = c
            else:
                candles.append(c)
        # 20-day average line (EMA 20 over all candles, same family as the trend score)
        ema, a = None, 2 / 21
        for c in candles:
            ema = c["close"] if ema is None else ema + a * (c["close"] - ema)
            c["ema20"] = ema

        trend = r["trend"]
        last5 = candles[-5:]
        # pullback = candles that closed against the trend (red in an uptrend, green in a downtrend)
        sign = {"UP": 1, "DOWN": -1}.get(trend, 0)
        against = sum(1 for c in last5 if sign and (c["close"] - c["open"]) * sign < 0)
        y, before = candles[-1], candles[-2]
        if trend == "UP":
            trigger = y["close"] > y["open"] and y["close"] > before["high"]
        elif trend == "DOWN":
            trigger = y["close"] < y["open"] and y["close"] < before["low"]
        else:
            trigger = False
        positions = mt5.positions_get() or []
        mine = [p for p in positions if p.symbol == sym]
        # Plan step 8: no re-entry on a pair that was closed earlier today (broker day)
        frm = dt.datetime.combine(self.today - dt.timedelta(days=2), dt.time())
        closed_today = any(d.symbol == sym and utc(d.time).date() == self.today
                           and d.entry in (mt5.DEAL_ENTRY_OUT, mt5.DEAL_ENTRY_OUT_BY)
                           for d in mt5.history_deals_get(frm, dt.datetime.now() + dt.timedelta(days=2)) or [])
        clean_trend = (trend == "UP" and r["tf"] == "+ + +") or (trend == "DOWN" and r["tf"] == "- - -")
        on_plan = not self.plan or clean(sym) in self.plan
        side = "BUY" if trend == "UP" else "SELL" if trend == "DOWN" else None
        checks = [
            {"key": "plan", "ok": on_plan, "title": "It is one of my plan pairs",
             "why": ("No pair list set (--pairs), so any pair is allowed." if not self.plan else
                     f"{clean(sym)} is on your list.") if on_plan else
                    f"{clean(sym)} is NOT one of your plan pairs ({', '.join(sorted(self.plan))})."},
            {"key": "trend", "ok": clean_trend, "title": "Clear trend (all three lookbacks agree)",
             "why": f"Trend is {trend} and 20/60/120 days all point the same way ({r['tf']})." if clean_trend else
                    f"Trend is {trend} with signs {r['tf']} - you need UP with + + + or DOWN with - - -."},
            {"key": "pullback", "ok": side is not None and against >= 2, "title": "Pullback: 2+ of the last 5 candles went the other way",
             "why": (f"{against} of the last 5 daily candles closed {'red (down)' if side == 'BUY' else 'green (up)'} - "
                     f"{'enough' if against >= 2 else 'need at least 2'}.") if side else "No trend, so there is no pullback to look for."},
            {"key": "trigger", "ok": trigger, "title": "Trigger: yesterday's candle closed back in the trend direction",
             "why": ((f"Yesterday ({y['date']}) was green and closed above the high before it." if trigger else
                      f"Yesterday ({y['date']}) did not close green ABOVE the previous candle's high.") if side == "BUY" else
                     (f"Yesterday ({y['date']}) was red and closed below the low before it." if trigger else
                      f"Yesterday ({y['date']}) did not close red BELOW the previous candle's low.") if side == "SELL" else
                     "No trend, so there is no trigger.")},
            {"key": "room", "ok": not mine and not closed_today and not self.stops and len(positions) < self.args.max_open,
             "title": "Room for a new trade",
             "why": ("You already have a trade open on this pair." if mine else
                     "You closed a trade on this pair earlier today - no re-entry until tomorrow." if closed_today else
                     "The daily tool says STOP for today: " + "; ".join(self.stops) + "." if self.stops else
                     f"You already have {len(positions)} trades open (max {self.args.max_open})."
                     if len(positions) >= self.args.max_open else
                     f"No trade open on it, {len(positions)} of {self.args.max_open} trades open, today's limits OK.")},
            {"key": "size", "ok": not r["too_small"], "title": "The smallest lot fits my 1% risk",
             "why": (f"Even {r['vol_min']} lot would lose ${r['risk_usd']:.2f} at the suggested SL - SKIP this pair."
                     if r["too_small"] and r["risk_usd"] is not None else
                     "{:.2f} lot (your plan's size) loses about ${:.2f} if the SL is hit.".format(*self.plan_lot(r))
                     if r["lot"] else "MT5 hasn't priced this pair yet.")},
        ]
        if tick and tick.bid > 0:
            d = info.digits
            levels = {
                "BUY": {"entry": round(tick.ask, d), "sl": round(tick.ask - r["SL"] * pip, d),
                        "tp": round(tick.ask + r["TP"] * pip, d)},
                "SELL": {"entry": round(tick.bid, d), "sl": round(tick.bid + r["SL"] * pip, d),
                         "tp": round(tick.bid - r["TP"] * pip, d)},
            }
        else:
            levels = None
        hist = [t for t in self.trades() if t["symbol"] == clean(sym)]
        return {
            "row": self.row_json(r), "side": side, "checks": checks,
            "ready": all(c["ok"] for c in checks),
            "candles": candles[-CHART_DAYS:], "forming": forming, "pullback_window": [c["date"] for c in last5],
            "digits": info.digits, "pip": pip, "bid": tick.bid if tick else None, "ask": tick.ask if tick else None,
            "levels": levels, "points_per_pip": round(pip / info.point),
            "positions": [{
                "side": "BUY" if p.type == mt5.POSITION_TYPE_BUY else "SELL", "lot": p.volume,
                "open": p.price_open, "sl": p.sl or None, "tp": p.tp or None,
                "sl_pips": (abs(p.price_open - p.sl) / pip) if p.sl else None,
                "tp_pips": (abs(p.tp - p.price_open) / pip) if p.tp else None,
                "profit": p.profit + p.swap, "opened": utc(p.time).strftime("%a %d %b %H:%M"),
            } for p in mine],
            "history": [{
                "side": t["side"], "lot": t["lot"], "opened": t["opened"].strftime("%d %b %Y"),
                "closed": t["closed"].strftime("%d %b %Y"), "pips": t["pips"], "net": t["net"], "how": t["how"],
            } for t in reversed(hist)],
            "settings": ov["settings"], "account": ov["account"], "market_open": ov["market_open"],
            "generated": ov["generated"],
        }


class Handler(BaseHTTPRequestHandler):
    data = None
    lock = threading.Lock()  # the MT5 package is not thread-safe: one MT5 job at a time
    hosts = set()

    def log_message(self, *a):
        pass

    def send(self, code, body, ctype):
        b = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        # Only answer pages opened as 127.0.0.1/localhost (blocks other websites peeking via DNS tricks)
        if self.headers.get("Host", "") not in self.hosts:
            return self.send(403, "Forbidden", "text/plain")
        u = urlparse(self.path)
        q = parse_qs(u.query)
        try:
            if u.path in ("/", "/index.html"):
                with open(os.path.join(HERE, "dashboard.html"), encoding="utf-8") as f:
                    return self.send(200, f.read(), "text/html; charset=utf-8")
            if u.path not in ("/api/overview", "/api/pair"):
                return self.send(404, "Not found", "text/plain")
            with self.lock:
                if u.path == "/api/overview":
                    out = self.data.overview(force="refresh" in q)
                else:
                    out = self.data.pair(q.get("s", [""])[0].strip())
            self.send(200, json.dumps(out, default=float), "application/json")
        except Exception as e:  # show the problem on the page instead of a blank screen
            self.send(500, json.dumps({"error": str(e)}), "application/json")


def main():
    args = parse_args()
    Handler.data = Data(args)
    try:
        Handler.data.connect()
    except RuntimeError as e:
        sys.exit(str(e))
    Handler.hosts = {f"127.0.0.1:{args.port}", f"localhost:{args.port}"}
    ThreadingHTTPServer.allow_reuse_address = False  # on Windows reuse would let 2 servers share a port
    ThreadingHTTPServer.daemon_threads = True
    try:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError:
        url = f"http://127.0.0.1:{args.port}/"
        print(f"The dashboard is already running - opening {url}")
        webbrowser.open(url)
        return
    url = f"http://127.0.0.1:{args.port}/"
    print(f"Dashboard running at {url}")
    print("Keep this window open while you use it. Close it (or press Ctrl+C) to stop.")
    if not args.no_browser:
        threading.Timer(0.5, webbrowser.open, (url,)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
