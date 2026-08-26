#!/usr/bin/env python3
# tools/winprob_headroom.py -- P5 Phase-B BOUND (2026-08-26): does a LEARNED win-probability model on
# the state features already logged per ante beat the single best feature (proxy for hand-tuned pacing)?
# RESULT: NO material, reliable headroom. `capacity` alone gives test-AUC ~0.70-0.81 at every ante on
# both baseline (17 wins/640) and rich (78 wins/320) arms; a 23-feature logistic adds +0.09/-0.07/+0.03/
# -0.08 (~0 avg, overfits the rare positive class). capacity ~= the sufficient statistic, and it is what
# pace_margin already uses => a learned classifier as a DENSER OBJECTIVE is bounded weak. (A learned
# ROLLOUT VALUE inside a planner/search is a different, larger use this does NOT bound.)
#   usage: python tools/winprob_headroom.py [arm1.jsonl arm2.jsonl ...]   (defaults to the baseline arms)
# Zero new sim runs -- reuses arm JSONL on disk. Reports test AUC: best single feature vs multi-logistic.
import json, sys, math, random

random.seed(7)
import sys as _s
FILES = _s.argv[1:] if len(_s.argv)>1 else ['sim_out/p3_ctrl_base.jsonl','sim_out/p2a_treat_base.jsonl','sim_out/p2a_ctrl_b7.jsonl','sim_out/p2a_treat_b7.jsonl']
FEATS = ['dollars','njokers','hand_lv_sum','hand_lv_max','hands_leveled','xmult','xmult_scaling',
         'copier','scaling','econ_total','econ_jokers','editioned','enhanced','negative','sealed',
         'tier_sum','tier_max','hand_size','hands','discards','slots_free','consumables','capacity']

def load_runs(path):
    runs = {}
    for l in open(path, encoding='utf-8'):
        l = l.strip()
        if not l: continue
        try: r = json.loads(l)
        except: continue
        s = str(r.get('seed'))
        if r.get('kind') == 'run_start': runs.setdefault(s, {'antes': {}, 'won': None})
        elif r.get('kind') == 'ante':
            f = dict(r.get('metrics', {}).get('features', {}))
            f['capacity'] = r.get('metrics', {}).get('capacity', 0)
            runs.setdefault(s, {'antes': {}, 'won': None})['antes'][int(r.get('ante', 0))] = f
        elif r.get('kind') == 'win': runs.setdefault(s, {'antes': {}, 'won': None})['won'] = 1
        elif r.get('kind') == 'death': runs.setdefault(s, {'antes': {}, 'won': None})['won'] = 0
    return runs

def auc(scores, labels):   # Mann-Whitney U / (n_pos*n_neg); handles ties (0.5)
    pairs = sorted(zip(scores, labels))
    pos = sum(labels); neg = len(labels) - pos
    if pos == 0 or neg == 0: return 0.5
    # rank-sum with tie handling
    ranks = [0.0]*len(pairs); i = 0
    while i < len(pairs):
        j = i
        while j+1 < len(pairs) and pairs[j+1][0] == pairs[i][0]: j += 1
        r = (i+j)/2.0 + 1
        for k in range(i, j+1): ranks[k] = r
        i = j+1
    rsum_pos = sum(rk for rk,(_,lab) in zip(ranks, pairs) if lab == 1)
    u = rsum_pos - pos*(pos+1)/2.0
    return u/(pos*neg)

def standardize(rows, feats):
    mean = {}; sd = {}
    for f in feats:
        xs = [r[f] for r in rows]
        m = sum(xs)/len(xs); v = sum((x-m)**2 for x in xs)/max(1,len(xs)-1)
        mean[f] = m; sd[f] = math.sqrt(v) or 1.0
    return mean, sd

def logreg_fit(rows, y, feats, mean, sd, l2=1.0, iters=400, lr=0.3):
    w = {f: 0.0 for f in feats}; b = 0.0
    n = len(rows)
    for _ in range(iters):
        gw = {f: 0.0 for f in feats}; gb = 0.0
        for r, yi in zip(rows, y):
            z = b + sum(w[f]*(r[f]-mean[f])/sd[f] for f in feats)
            p = 1/(1+math.exp(-max(-30,min(30,z))))
            e = p - yi
            for f in feats: gw[f] += e*(r[f]-mean[f])/sd[f]
            gb += e
        for f in feats: w[f] -= lr*(gw[f]/n + l2*w[f]/n)
        b -= lr*gb/n
    return w, b

def logreg_score(r, w, b, mean, sd, feats):
    return b + sum(w[f]*(r[f]-mean[f])/sd[f] for f in feats)

def run_at_ante(runs, K):
    rows, y = [], []
    for s, d in runs.items():
        if d['won'] is None: continue
        if K in d['antes']:
            rows.append(d['antes'][K]); y.append(d['won'])
    return rows, y

def main():
    runs = {}
    for f in FILES:
        try:
            r = load_runs(f)
            for s,d in r.items():
                # namespace seeds by file so seed collisions across arms don't merge
                runs[f+'::'+s] = d
        except FileNotFoundError:
            print('missing', f)
    print('loaded %d runs (%d won)' % (len(runs), sum(1 for d in runs.values() if d['won']==1)))
    for K in (3,4,5,6):
        rows, y = run_at_ante(runs, K)
        if len(rows) < 40 or sum(y) < 5 or (len(y)-sum(y)) < 5:
            print('ante %d: too few (n=%d, wins=%d)' % (K, len(rows), sum(y))); continue
        feats = [f for f in FEATS if any(r.get(f,0)!=rows[0].get(f,0) for r in rows)] or FEATS
        # train/test split
        idx = list(range(len(rows))); random.shuffle(idx)
        cut = int(0.7*len(idx)); tr = set(idx[:cut])
        Rtr=[rows[i] for i in idx[:cut]]; Ytr=[y[i] for i in idx[:cut]]
        Rte=[rows[i] for i in idx[cut:]]; Yte=[y[i] for i in idx[cut:]]
        if sum(Yte)<3 or (len(Yte)-sum(Yte))<3:
            print('ante %d: test split too thin'%K); continue
        mean,sd = standardize(Rtr, feats)
        # best single feature by TEST auc (proxy for hand-tuned single signal)
        best_f, best_a = None, 0.0
        for f in feats:
            a = auc([r[f] for r in Rte], Yte); a = max(a, 1-a)
            if a > best_a: best_a, best_f = a, f
        # multi-feature logistic, TEST auc
        w,b = logreg_fit(Rtr, Ytr, feats, mean, sd)
        te_scores = [logreg_score(r,w,b,mean,sd,feats) for r in Rte]
        ml_a = auc(te_scores, Yte)
        base = sum(y)/len(y)
        print('ante %d  n=%d (train %d/test %d, win-rate %.0f%%)' % (K,len(rows),len(Rtr),len(Rte),100*base))
        print('   best single feature: %-12s test-AUC %.3f' % (best_f, best_a))
        print('   multi-feature logreg (%d feats): test-AUC %.3f   (headroom over best single: %+.3f)'
              % (len(feats), ml_a, ml_a-best_a))

if __name__ == '__main__':
    main()
