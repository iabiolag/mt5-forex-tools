"""Research harness: which entry confirmations and exits actually have an edge on D1?

    python confirm_research.py --refresh      # pull D1 history from MT5 into research_cache/ (once)
    python confirm_research.py                # run every experiment, in-sample vs out-of-sample
    python confirm_research.py --only exits   # just one experiment group

Same trend score as SignalEngine.mqh. Each idea is simulated bar by bar on daily candles:
decide on the close of candle i, enter at the open of candle i+1, stop/trail checked on each
later candle's high/low (a gap through the stop fills at the open), one position per pair.
Costs: 1.5x the pair's median daily-bar spread, charged once per trade.

Results are in R (1R = the initial stop distance). In-sample = before 2023, out-of-sample =
2023 onward. Pick rules on in-sample ONLY; out-of-sample is the check, not a tuning knob.
Read-only: nothing here places, modifies or closes trades.
"""
import argparse, csv, datetime as dt, math, os, random, statistics as st, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "research_cache")
SPLIT = dt.date(2023, 1, 1)  # broker D1 history mostly starts 2018-07
MAJORS = ["EURUSD", "GBPUSD", "USDJPY", "USDCHF", "USDCAD", "AUDUSD", "NZDUSD",
          "EURGBP", "EURJPY", "EURCHF", "EURCAD", "EURAUD", "EURNZD",
          "GBPJPY", "GBPCHF", "GBPCAD", "GBPAUD", "GBPNZD",
          "AUDJPY", "AUDCHF", "AUDCAD", "AUDNZD", "NZDJPY", "NZDCHF", "NZDCAD",
          "CADJPY", "CADCHF", "CHFJPY", "XAUUSD"]


# ----------------------------------------------------------------------------- data
def refresh():
    import MetaTrader5 as mt5
    import daily_range as dr
    if not mt5.initialize():
        sys.exit(f"MT5 initialize failed: {mt5.last_error()}")
    os.makedirs(CACHE, exist_ok=True)
    today = dr.server_today()
    for pair in MAJORS:
        sym = dr.resolve(pair)
        if sym is None:
            print(f"  {pair}: not on this account"); continue
        mt5.symbol_select(sym, True)
        r = None
        for _ in range(5):
            r = mt5.copy_rates_from_pos(sym, mt5.TIMEFRAME_D1, 0, 6000)
            if r is not None and len(r) > 500:
                break
        if r is None or len(r) < 500:
            print(f"  {pair}: not enough history"); continue
        point = mt5.symbol_info(sym).point
        with open(os.path.join(CACHE, pair + ".csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["date", "open", "high", "low", "close", "spread"])
            for b in r:
                d = dt.datetime.utcfromtimestamp(int(b["time"])).date()
                if d >= today:
                    continue  # unfinished candle
                w.writerow([d.isoformat(), b["open"], b["high"], b["low"], b["close"],
                            int(b["spread"]) * point])
        print(f"  {pair}: {len(r)} candles from {dt.datetime.utcfromtimestamp(int(r[0]['time'])).date()}")
    mt5.shutdown()


def load(pair):
    rows = list(csv.DictReader(open(os.path.join(CACHE, pair + ".csv"))))
    # drop broker Sunday stubs: they distort ATR and are not real trading days
    rows = [r for r in rows if dt.date.fromisoformat(r["date"]).weekday() != 6]
    D = {"date": [dt.date.fromisoformat(r["date"]) for r in rows]}
    for k in ("open", "high", "low", "close", "spread"):
        D[k] = [float(r[k]) for r in rows]
    sp = sorted(x for x in D["spread"] if x > 0)
    D["cost"] = 1.5 * (sp[len(sp) // 2] if sp else 0.0)
    features(D)
    return D


# ----------------------------------------------------------------------------- indicators
def sma(x, n):
    out, s = [None] * len(x), 0.0
    for i, v in enumerate(x):
        s += v
        if i >= n:
            s -= x[i - n]
        if i >= n - 1:
            out[i] = s / n
    return out


def ema(x, n):
    a, out, e = 2.0 / (n + 1), [], x[0]
    for v in x:
        e += a * (v - e); out.append(e)
    return out


def rolling_max(x, n):
    return [max(x[max(0, i - n + 1):i + 1]) for i in range(len(x))]


def rolling_min(x, n):
    return [min(x[max(0, i - n + 1):i + 1]) for i in range(len(x))]


def features(D, periods=(20, 60, 120), atr_n=20, k=2.0):
    o, h, l, c = D["open"], D["high"], D["low"], D["close"]
    n = len(c)
    tr = [h[0] - l[0]] + [max(h[i], c[i - 1]) - min(l[i], c[i - 1]) for i in range(1, n)]
    D["atr"] = sma(tr, atr_n)
    clamp = lambda v: max(-1.0, min(1.0, v))
    comps = []
    for L in periods:
        e, hh, ll = ema(c, L), rolling_max(h, L), rolling_min(l, L)
        sc = math.sqrt(L / atr_n)
        comp = [None] * n
        for i in range(n):
            if D["atr"][i] is None or i < L:
                continue
            parts = [clamp((c[i] - e[i]) / (k * D["atr"][i] * sc))]
            if hh[i] > ll[i]:
                parts.append(clamp(2 * (c[i] - ll[i]) / (hh[i] - ll[i]) - 1))
            comp[i] = sum(parts) / len(parts)
        comps.append(comp)
    D["comps"] = comps
    D["sig"] = [None if any(cp[i] is None for cp in comps) else sum(cp[i] for cp in comps) / 3
                for i in range(n)]
    # Kaufman efficiency ratio: net move / path length. 1 = straight line, 0 = pure chop.
    for L in (20, 60):
        er = [None] * n
        for i in range(L, n):
            path = sum(abs(c[j] - c[j - 1]) for j in range(i - L + 1, i + 1))
            er[i] = abs(c[i] - c[i - L]) / path if path > 0 else 0.0
        D[f"er{L}"] = er
    # Wilder ADX(14)
    N = 14
    pdm = [0.0] + [max(h[i] - h[i - 1], 0) if h[i] - h[i - 1] > l[i - 1] - l[i] else 0.0 for i in range(1, n)]
    mdm = [0.0] + [max(l[i - 1] - l[i], 0) if l[i - 1] - l[i] > h[i] - h[i - 1] else 0.0 for i in range(1, n)]
    adx, s_tr, s_p, s_m, a = [None] * n, 0.0, 0.0, 0.0, None
    for i in range(1, n):
        if i <= N:
            s_tr += tr[i]; s_p += pdm[i]; s_m += mdm[i]
            continue
        s_tr += tr[i] - s_tr / N; s_p += pdm[i] - s_p / N; s_m += mdm[i] - s_m / N
        pdi, mdi = 100 * s_p / s_tr, 100 * s_m / s_tr
        dx = 100 * abs(pdi - mdi) / (pdi + mdi) if pdi + mdi > 0 else 0.0
        a = dx if a is None else a + (dx - a) / N
        adx[i] = a
    D["adx"] = adx
    # ATR percentile vs own last 250 bars (volatility regime)
    ap = [None] * n
    for i in range(270, n):
        w = D["atr"][i - 249:i + 1]
        ap[i] = 100.0 * sum(1 for v in w if v <= D["atr"][i]) / len(w)
    D["atr_pct"] = ap
    D["hh20"], D["ll20"] = rolling_max(h, 20), rolling_min(l, 20)
    D["hh10"], D["ll10"] = rolling_max(h, 10), rolling_min(l, 10)
    D["hh55"], D["ll55"] = rolling_max(h, 55), rolling_min(l, 55)
    D["hh5"], D["ll5"] = rolling_max(h, 5), rolling_min(l, 5)
    D["sma5"], D["sma20"] = sma(c, 5), sma(c, 20)
    sd = [None] * n
    for i in range(19, n):
        m = D["sma20"][i]
        sd[i] = math.sqrt(sum((c[k] - m) ** 2 for k in range(i - 19, i + 1)) / 20)
    D["sd20"] = sd
    # RSI(2), Wilder smoothing
    r, ag, al = [None] * n, 0.0, 0.0
    for i in range(1, n):
        ch = c[i] - c[i - 1]
        g, ls = max(ch, 0.0), max(-ch, 0.0)
        if i <= 2:
            ag += g / 2; al += ls / 2
            if i < 2: continue
        else:
            ag += (g - ag) / 2; al += (ls - al) / 2
        r[i] = 100.0 if al == 0 else 100 - 100 / (1 + ag / al)
    D["rsi2"] = r


# ----------------------------------------------------------------------------- simulator
def simulate(D, entry, exit_cfg, start=150):
    """entry(D, i) -> +1/-1/0 decided on the close of candle i.
    exit_cfg keys: stop (ATR mult), trail (ATR mult or None), trail_start (R),
    flip (signal level or None), donchian (N or None), time (bars or None),
    tp (R or None), be (R at which stop goes to breakeven, or None)."""
    o, h, l, c, sig, atr = D["open"], D["high"], D["low"], D["close"], D["sig"], D["atr"]
    n, trades, i = len(c), [], start
    while i < n - 1:
        d = entry(D, i) if sig[i] is not None and atr[i] else 0
        if not d:
            i += 1; continue
        e_i = i + 1
        entry_px = o[e_i]
        risk = exit_cfg["stop"] * atr[i]
        stop = entry_px - d * risk
        ext = entry_px  # best price since entry
        mfe = 0.0
        exit_px, reason, j = None, None, e_i
        while j < n:
            # 1) stop (gap through -> fill at open)
            if d > 0 and l[j] <= stop:
                exit_px, reason = (min(o[j], stop) if j > e_i else min(o[j], stop)), "stop"
            elif d < 0 and h[j] >= stop:
                exit_px, reason = max(o[j], stop), "stop"
            # 2) take profit
            if exit_px is None and exit_cfg.get("tp"):
                tp = entry_px + d * exit_cfg["tp"] * risk
                if (d > 0 and h[j] >= tp) or (d < 0 and l[j] <= tp):
                    exit_px, reason = (max(o[j], tp) if d > 0 else min(o[j], tp)), "tp"
            if exit_px is not None:
                break
            # end-of-candle updates, acted on at the next open
            ext = max(ext, h[j]) if d > 0 else min(ext, l[j])
            mfe = max(mfe, d * (ext - entry_px) / risk)
            close_next = None
            if exit_cfg.get("flip") is not None and sig[j] is not None:
                if (d > 0 and sig[j] <= exit_cfg["flip"]) or (d < 0 and sig[j] >= -exit_cfg["flip"]):
                    close_next = "flip"
            if exit_cfg.get("donchian"):
                N = exit_cfg["donchian"]
                lvl = D[f"ll{N}"][j - 1] if d > 0 else D[f"hh{N}"][j - 1]
                if (d > 0 and c[j] < lvl) or (d < 0 and c[j] > lvl):
                    close_next = close_next or "donchian"
            if exit_cfg.get("time") and j - e_i + 1 >= exit_cfg["time"] and mfe < 1.0:
                close_next = close_next or "time"
            if exit_cfg.get("exit_fn") and exit_cfg["exit_fn"](D, j, d, entry_px, risk, mfe):
                close_next = close_next or "custom"
            if close_next:
                if j + 1 < n:
                    exit_px, reason, j = o[j + 1], close_next, j + 1
                break
            if exit_cfg.get("be") and mfe >= exit_cfg["be"]:
                stop = max(stop, entry_px) if d > 0 else min(stop, entry_px)
            if exit_cfg.get("trail") and mfe >= exit_cfg.get("trail_start", 0.0):
                t = ext - d * exit_cfg["trail"] * atr[j]
                stop = max(stop, t) if d > 0 else min(stop, t)
            j += 1
        if exit_px is None:
            break  # still open at the end of data
        R = (d * (exit_px - entry_px) - D["cost"]) / risk
        trades.append((D["date"][e_i], R, reason, j - e_i, d, D["date"][min(j, n - 1)]))
        i = j  # flat again; can re-enter from the exit candle's close
    return trades


# ----------------------------------------------------------------------------- reporting
def stats(rs):
    if not rs:
        return dict(n=0, exp=0.0, tot=0.0, win=0.0, pf=0.0)
    gw, gl = sum(r for r in rs if r > 0), -sum(r for r in rs if r <= 0)
    return dict(n=len(rs), exp=st.mean(rs), tot=sum(rs), win=100 * sum(r > 0 for r in rs) / len(rs),
                pf=gw / gl if gl > 0 else float("inf"))


def run(name, data, entry, exit_cfg, out):
    ins, oos, per_pair_is, per_pair_oos, years = [], [], [], [], {}
    for pair, D in data.items():
        t = simulate(D, entry, exit_cfg)
        a = [r for d, r, *_ in t if d < SPLIT]
        b = [r for d, r, *_ in t if d >= SPLIT]
        ins += a; oos += b
        if a: per_pair_is.append(sum(a))
        if b: per_pair_oos.append(sum(b))
        for d, r, *_ in t:
            years.setdefault(d.year, []).append(r)
    s1, s2 = stats(ins), stats(oos)
    pos_is = sum(x > 0 for x in per_pair_is)
    pos_oos = sum(x > 0 for x in per_pair_oos)
    print(f"{name:42s} | IS n={s1['n']:5d} exp={s1['exp']:+.3f} pf={s1['pf']:.2f} pairs+={pos_is:2d}/{len(per_pair_is):2d}"
          f" | OOS n={s2['n']:5d} exp={s2['exp']:+.3f} pf={s2['pf']:.2f} pairs+={pos_oos:2d}/{len(per_pair_oos):2d}")
    out.append(dict(name=name, is_n=s1["n"], is_exp=round(s1["exp"], 4), is_pf=round(s1["pf"], 3),
                    oos_n=s2["n"], oos_exp=round(s2["exp"], 4), oos_pf=round(s2["pf"], 3),
                    is_pairs_pos=pos_is, oos_pairs_pos=pos_oos,
                    years=" ".join(f"{y}:{sum(v):+.0f}" for y, v in sorted(years.items()))))
    return s1, s2


# ----------------------------------------------------------------------------- experiments
def trend_entry(thr=0.5, er=None, adx=None, agree=False, fresh=None, max_atr_pct=None,
                breakout=None, pullback=False):
    """Base: |trend score| >= thr gives the direction. Every other argument is one
    confirmation filter that must ALSO pass on the same closed candle."""
    def f(D, i):
        s = D["sig"][i]
        if abs(s) < thr:
            return 0
        d = 1 if s > 0 else -1
        if agree and not all(cp[i] is not None and cp[i] * d > 0 for cp in D["comps"]):
            return 0
        if er is not None and (D["er20"][i] is None or D["er20"][i] < er):
            return 0
        if adx is not None and (D["adx"][i] is None or D["adx"][i] < adx):
            return 0
        if fresh is not None:  # score crossed the threshold within the last `fresh` candles
            w = [D["sig"][k] for k in range(i - fresh, i)]
            if any(v is None for v in w) or all(v * d >= thr for v in w):
                return 0
        if max_atr_pct is not None and (D["atr_pct"][i] is None or D["atr_pct"][i] > max_atr_pct):
            return 0
        if breakout:  # close beyond the previous N-candle high/low
            lvl = D[f"hh{breakout}"][i - 1] if d > 0 else D[f"ll{breakout}"][i - 1]
            if (d > 0 and D["close"][i] <= lvl) or (d < 0 and D["close"][i] >= lvl):
                return 0
        if pullback:  # 2 of last 5 candles closed against, then a trigger candle beyond prior high/low
            c, o = D["close"], D["open"]
            against = sum(1 for k in range(i - 4, i + 1) if (c[k] - o[k]) * d < 0)
            trig = c[i] > D["high"][i - 1] if d > 0 else c[i] < D["low"][i - 1]
            if against < 2 or not trig:
                return 0
        return d
    return f


def random_entry(seed):
    rnd = random.Random(seed)
    return lambda D, i: rnd.choice((1, -1)) if rnd.random() < 0.1 else 0


def donchian_entry(N=55):
    def f(D, i):
        if D["close"][i] > D[f"hh{N}"][i - 1]: return 1
        if D["close"][i] < D[f"ll{N}"][i - 1]: return -1
        return 0
    return f


def fade_entry(thr=0.7):
    """Opposite of the trend score: sell strength, buy weakness."""
    return lambda D, i: (-1 if D["sig"][i] >= thr else 1 if D["sig"][i] <= -thr else 0)


def dip_in_trend(rsi=10, slow_only=True):
    """Long-term trend up (120-candle component > 0) + short-term washout (RSI2 < rsi):
    buy the dip. Mirror for downtrends."""
    def f(D, i):
        t, r = D["comps"][2][i], D["rsi2"][i]
        if t is None or r is None:
            return 0
        if t > 0 and r < rsi: return 1
        if t < 0 and r > 100 - rsi: return -1
        return 0
    return f


def band_fade(k=2.0):
    """Close outside the 20-candle Bollinger band: fade it."""
    def f(D, i):
        m, sd = D["sma20"][i], D["sd20"][i]
        if m is None or not sd: return 0
        if D["close"][i] > m + k * sd: return -1
        if D["close"][i] < m - k * sd: return 1
        return 0
    return f


def back_to_mean(ma):
    """Exit on the close that gets back to the moving average."""
    return lambda D, j, d, e, risk, mfe: (D["close"][j] - D[ma][j]) * d >= 0


EA = dict(stop=3.0, trail=3.0, trail_start=1.0, flip=0.0)


def experiments(data, only, out):
    if only in (None, "benchmark"):
        print("\n--- benchmarks: random direction / classic breakout, EA exits ---")
        for s in (1, 2, 3):
            run(f"random entry seed {s}", data, random_entry(s), EA, out)
        run("Donchian 55 breakout", data, donchian_entry(55), EA, out)
    if only in (None, "entries"):
        print("\n--- confirmation filters on top of the trend score, EA exits ---")
        run("EA as is (score>=0.5)", data, trend_entry(0.5), EA, out)
        for thr in (0.6, 0.7, 0.8):
            run(f"score >= {thr}", data, trend_entry(thr), EA, out)
        run("+ all 3 lookbacks agree", data, trend_entry(0.5, agree=True), EA, out)
        for er in (0.2, 0.3, 0.4):
            run(f"+ efficiency ratio20 >= {er}", data, trend_entry(0.5, er=er), EA, out)
        for a in (20, 25, 30):
            run(f"+ ADX14 >= {a}", data, trend_entry(0.5, adx=a), EA, out)
        for fr in (3, 10):
            run(f"+ fresh cross (last {fr} candles)", data, trend_entry(0.5, fresh=fr), EA, out)
        run("+ ATR pct <= 90 (not extreme vol)", data, trend_entry(0.5, max_atr_pct=90), EA, out)
        run("+ 20-candle breakout", data, trend_entry(0.5, breakout=20), EA, out)
        run("+ pullback & trigger (manual plan)", data, trend_entry(0.5, pullback=True), EA, out)
    if only in (None, "exits"):
        print("\n--- exits, entry = score >= 0.5 ---")
        e = trend_entry(0.5)
        run("EA exits (stop3 trail3@1R flip0)", data, e, EA, out)
        run("no flip exit", data, e, dict(EA, flip=None), out)
        run("flip at -0.25 (later)", data, e, dict(EA, flip=-0.25), out)
        run("flip at +0.25 (earlier)", data, e, dict(EA, flip=0.25), out)
        for t in (2.0, 4.0, 5.0):
            run(f"trail {t} ATR @1R", data, e, dict(EA, trail=t), out)
        run("trail 3 ATR from entry", data, e, dict(EA, trail_start=0.0), out)
        run("no trail (stop + flip only)", data, e, dict(EA, trail=None), out)
        for s in (2.0, 4.0):
            run(f"initial stop {s} ATR", data, e, dict(EA, stop=s), out)
        run("Donchian 20 exit instead of trail", data, e, dict(stop=3.0, flip=0.0, donchian=20), out)
        run("Donchian 10 exit instead of trail", data, e, dict(stop=3.0, flip=0.0, donchian=10), out)
        run("breakeven at +1R", data, e, dict(EA, be=1.0), out)
        run("time stop 20 candles (<1R)", data, e, dict(EA, time=20), out)
        for tp in (2.0, 3.0):
            run(f"take profit {tp}R", data, e, dict(EA, tp=tp), out)


def reversion(data, out):
    print("\n--- mean reversion (the opposite idea), declared before running ---")
    R5 = dict(stop=3.0, exit_fn=back_to_mean("sma5"), time=10)
    R20 = dict(stop=3.0, exit_fn=back_to_mean("sma20"), time=20)
    run("fade score>=0.7, EA exits w/o flip", data, fade_entry(0.7), dict(EA, flip=None), out)
    run("fade score>=0.7, exit at SMA20", data, fade_entry(0.7), R20, out)
    run("dip in trend RSI2<10, exit at SMA5", data, dip_in_trend(10), R5, out)
    run("dip in trend RSI2<5, exit at SMA5", data, dip_in_trend(5), R5, out)
    run("Bollinger 2SD fade, exit at SMA20", data, band_fade(2.0), R20, out)
    run("Bollinger 2.5SD fade, exit at SMA20", data, band_fade(2.5), R20, out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--refresh", action="store_true", help="re-download D1 history from MT5 first")
    ap.add_argument("--only", choices=["benchmark", "entries", "exits", "reversion"])
    ap.add_argument("--pairs", nargs="*", default=MAJORS)
    args = ap.parse_args()
    if args.refresh or not os.path.isdir(CACHE):
        refresh()
    data = {}
    for p in args.pairs:
        if os.path.exists(os.path.join(CACHE, p + ".csv")):
            data[p] = load(p)
    first = min(D["date"][150] for D in data.values())
    print(f"{len(data)} pairs, trading from {first}; in-sample < {SPLIT}, out-of-sample >= {SPLIT}")
    out = []
    experiments(data, args.only, out)
    if args.only in (None, "reversion"):
        reversion(data, out)
    with open(os.path.join(HERE, "confirm_research_results.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(out[0]))
        w.writeheader(); w.writerows(out)


if __name__ == "__main__":
    main()
