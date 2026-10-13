#!/usr/bin/env python3
# tools/decision_audit_placebo.py -- read a decision audit AGAINST ITS PLACEBO (2026-10-13). A flip re-rolls everything
# after the decision, so flip - baseline mixes "the other choice" with "different luck"; the placebo (same seed, same
# decision index, decision KEPT, later randomness re-rolled) measures the luck part. Effect = flip - placebo, per seed.
#   usage: python tools/decision_audit_placebo.py <flip_audit.jsonl> <placebo_audit.jsonl>
import sys, json, math, statistics as st, collections
BI = {'Small': 0, 'Big': 1, 'Boss': 2}
def out(r):
    if r['kind'] == 'win': return 8.0, 1
    fr = min(1, r['scored'] / r['target']) if r.get('target') else 0
    return (r['ante'] - 1) + (BI.get(r.get('blind_type'), 0) + fr) / 3, 0
def load(p):
    F, R = {}, {}
    for l in open(p):
        r = json.loads(l)
        key = ':'.join(r['job'].split(':')[:2]) if 'job' in r else None
        if r.get('kind') == 'forced': F[key] = r
        elif r.get('kind') in ('death', 'win'): R[key] = out(r)
    return F, R
Ff, Rf = load(sys.argv[1]); Fp, Rp = load(sys.argv[2])
rows = []
for k, f in Ff.items():
    if not f.get('forced') or k not in Rf or k not in Rp: continue
    rows.append(dict(type=f['best']['type'], ante=f['ante'], d=Rf[k][0] - Rp[k][0], dw=Rf[k][1] - Rp[k][1]))
def S(name, rs):
    if len(rs) < 2: return
    d = [r['d'] for r in rs]; m = st.mean(d); se = st.stdev(d) / math.sqrt(len(d))
    print('  %-34s n %3d  flip - placebo %+.3f (se %.3f, t %+.2f)  better/worse %d/%d  wins %+d' % (name, len(d), m, se, m / se if se else 0,
          sum(x > 1e-9 for x in d), sum(x < -1e-9 for x in d), sum(r['dw'] for r in rs)))
print('decisions with both a flip and a placebo:', len(rows))
S('all', rows)
for t, lab in (('DISCARD', 'engine dug -> its best play'), ('PLAY', 'engine played -> its best dig')):
    S(lab, [r for r in rows if r['type'] == t])
    for lo, hi in ((1, 1), (2, 4), (5, 8)):
        S('   ... at ante %d-%d' % (lo, hi), [r for r in rows if r['type'] == t and lo <= r['ante'] <= hi])
