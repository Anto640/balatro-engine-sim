#!/usr/bin/env python3
# tools/data_scaling_probe.py -- THE go/no-go for path B (learned early-position value).
#
# The NNUE probe (richeval_probe.py) showed a piece-level value beats capacity IN-SAMPLE but FAILS OOS on
# ~80 wins. The open question that decides whether MORE data would fix it: is OOS AUC still RISING with the
# number of training WINS, or has it PLATEAUED? This trains the piece-level model on increasing subsets of
# training wins and evaluates OOS AUC on a DISJOINT seed family at each size.
#   RISING toward/past capacity -> more data generalizes -> path B is worth the compute.
#   FLAT / <= capacity          -> data won't fix it     -> path B (this approach) is dead; pivot to A.
#
#   usage: python tools/data_scaling_probe.py
# Train = base-seed rich10 arms; Test = +7-offset rich10 arm (disjoint seeds). CPU logistic; ~1-2 min.
import json, sys, math, random
from collections import Counter
random.seed(7)

def load(paths):
    runs = {}
    for p in paths:
        for l in open(p, encoding="utf-8"):
            l = l.strip()
            if not l: continue
            try: r = json.loads(l)
            except: continue
            s = p + "::" + str(r.get("seed"))
            if r.get("kind") == "run_start": runs.setdefault(s, {"a": {}, "won": None})
            elif r.get("kind") == "ante":
                m = r.get("metrics", {}); f = dict(m.get("features", {})); f["capacity"] = m.get("capacity", 0)
                f["_jokers"] = list(r.get("jokers") or [])
                runs.setdefault(s, {"a": {}, "won": None})["a"][int(r.get("ante", 0))] = f
            elif r.get("kind") == "win": runs.setdefault(s, {"a": {}, "won": None})["won"] = 1
            elif r.get("kind") == "death": runs.setdefault(s, {"a": {}, "won": None})["won"] = 0
    return runs

def auc(xs, ys):
    pr = sorted(zip(xs, ys)); pos = sum(ys); neg = len(ys) - pos
    if pos == 0 or neg == 0: return 0.5
    rk = [0.0] * len(pr); i = 0
    while i < len(pr):
        j = i
        while j + 1 < len(pr) and pr[j + 1][0] == pr[i][0]: j += 1
        r = (i + j) / 2.0 + 1
        for k in range(i, j + 1): rk[k] = r
        i = j + 1
    rp = sum(x for x, (_, l) in zip(rk, pr) if l == 1)
    return (rp - pos * (pos + 1) / 2.0) / (pos * neg)

def fit(rows, y, feats, l2, iters=250, lr=0.3):
    mean = {f: 0.0 for f in feats}; sd = {f: 1.0 for f in feats}
    for f in feats:
        xs = [r.get(f, 0) for r in rows]; m = sum(xs) / len(xs)
        v = sum((x - m) ** 2 for x in xs) / max(1, len(xs) - 1)
        mean[f] = m; sd[f] = math.sqrt(v) or 1.0
    w = {f: 0.0 for f in feats}; b = 0.0; n = len(rows)
    for _ in range(iters):
        gw = {f: 0.0 for f in feats}; gb = 0.0
        for r, yi in zip(rows, y):
            z = b + sum(w[f] * (r.get(f, 0) - mean[f]) / sd[f] for f in feats)
            p = 1 / (1 + math.exp(-max(-30, min(30, z)))); e = p - yi
            for f in feats: gw[f] += e * (r.get(f, 0) - mean[f]) / sd[f]
            gb += e
        for f in feats: w[f] -= lr * (gw[f] / n + l2 * w[f] / n)
        b -= lr * gb / n
    return w, b, mean, sd

def score(r, w, b, mean, sd, feats):
    return b + sum(w[f] * (r.get(f, 0) - mean[f]) / sd[f] for f in feats)

TRAIN = ["sim_out/v4_rich.jsonl", "sim_out/baser_31f.jsonl"]   # base-seed rich10 arms
TEST  = ["sim_out/baser7_31f.jsonl"]                            # +7 offset -> disjoint seeds

def rows_at(runs, K):
    return [(d["a"][K], d["won"]) for d in runs.values() if d["won"] is not None and K in d["a"]]

def main():
    tr = load(TRAIN); te = load(TEST)
    print("train runs %d (%d won) | test runs %d (%d won)" %
          (len(tr), sum(1 for d in tr.values() if d["won"] == 1),
           len(te), sum(1 for d in te.values() if d["won"] == 1)))
    print("\nOOS AUC (test = disjoint +7 seeds) vs # TRAINING WINS.  reps=6, all losses kept.\n")
    for K in (4, 5):
        tr_all = rows_at(tr, K); te_all = rows_at(te, K)
        tr_wins = [x for x in tr_all if x[1] == 1]; tr_loss = [x for x in tr_all if x[1] == 0]
        nte_pos = sum(1 for _, y in te_all if y == 1)
        if len(tr_wins) < 20 or nte_pos < 5:
            print("ante %d: too few wins (train %d / test %d) -- skipped" % (K, len(tr_wins), nte_pos)); continue
        print("--- ante %d  (train wins avail=%d, loss=%d ; test n=%d, wins=%d) ---" %
              (K, len(tr_wins), len(tr_loss), len(te_all), nte_pos))
        sizes = [k for k in (10, 20, 30, 40, 60, 85) if k <= len(tr_wins)] + [len(tr_wins)]
        sizes = sorted(set(sizes))
        print("  %-10s %-14s %-16s %s" % ("train_wins", "capacity-OOS", "piece-level-OOS", "gain"))
        for k in sizes:
            cap_a, jok_a = [], []
            for _ in range(6):
                wsub = random.sample(tr_wins, k)
                base = [(dict(r), y) for r, y in wsub + tr_loss]
                rows = [r for r, _ in base]; y = [yy for _, yy in base]
                c = Counter(kk for r in rows for kk in r["_jokers"]); MINF = max(3, len(rows) // 40)
                vocab = [kk for kk, n in c.items() if n >= MINF]
                for r in rows:
                    for kk in vocab: r["jk_" + kk] = 1 if kk in r["_jokers"] else 0
                jf = ["jk_" + kk for kk in vocab]
                # piece-level
                w, b, mn, sdv = fit(rows, y, ["capacity"] + jf, l2=8.0)
                terows = [dict(r) for r, _ in te_all]; tey = [yy for _, yy in te_all]
                for r in terows:
                    for kk in vocab: r["jk_" + kk] = 1 if kk in r.get("_jokers", []) else 0
                jok_a.append(auc([score(r, w, b, mn, sdv, ["capacity"] + jf) for r in terows], tey))
                # capacity-only (same subset)
                wc, bc, mc, sc = fit(rows, y, ["capacity"], l2=0.5)
                cap_a.append(auc([score(r, wc, bc, mc, sc, ["capacity"]) for r in terows], tey))
            ca = sum(cap_a) / len(cap_a); ja = sum(jok_a) / len(jok_a)
            print("  %-10d %-14.3f %-16.3f %+.3f" % (k, ca, ja, ja - ca))
        print()

if __name__ == "__main__":
    main()
