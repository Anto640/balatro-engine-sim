#!/usr/bin/env python3
# tools/decision_audit_placebo.py -- read a decision audit AGAINST ITS PLACEBO (2026-10-13). A flip re-rolls everything
# after the decision, so flip - baseline mixes "the other choice" with "different luck"; the placebo (same seed, same
# decision index, decision KEPT, later randomness re-rolled) measures the luck part. Effect = flip - placebo, per seed.
#   usage: python tools/decision_audit_placebo.py <flip_audit.jsonl> <placebo_audit.jsonl>
#          python tools/decision_audit_placebo.py <audit.jsonl>   (one file holding both: alts containing 'placebo' = placebo)
import sys, json, math, statistics as st, collections
BI = {'Small': 0, 'Big': 1, 'Boss': 2}
def out(r):
    if r['kind'] == 'win': return 8.0, 1
    fr = min(1, r['scored'] / r['target']) if r.get('target') else 0
    return (r['ante'] - 1) + (BI.get(r.get('blind_type'), 0) + fr) / 3, 0
def load(p, want=None):
    F, R = {}, {}
    for l in open(p):
        r = json.loads(l)
        if 'job' not in r: continue
        parts = r['job'].split(':')
        if want is not None and (('placebo' in parts[2]) != want): continue
        key = ':'.join(parts[:2])
        if r.get('kind') == 'forced': F[key] = r
        elif r.get('kind') in ('death', 'win'): R[key] = out(r)
    return F, R
if len(sys.argv) > 2: (Ff, Rf), (Fp, Rp) = load(sys.argv[1]), load(sys.argv[2])
else: (Ff, Rf), (Fp, Rp) = load(sys.argv[1], False), load(sys.argv[1], True)
rows = []
for k, f in Ff.items():
    if not f.get('forced') or k not in Rf or k not in Rp: continue
    rows.append(dict(type=f['best']['type'], ante=f['ante'], d=Rf[k][0] - Rp[k][0], dw=Rf[k][1] - Rp[k][1],
                     dswap=f.get('dswap'), nb=len(f['best'].get('cards') or []), nf=len(f['forced'].get('cards') or [])))
def S(name, rs):
    if len(rs) < 2: return
    d = [r['d'] for r in rs]; m = st.mean(d); se = st.stdev(d) / math.sqrt(len(d))
    print('  %-34s n %3d  flip - placebo %+.3f (se %.3f, t %+.2f)  better/worse %d/%d  wins %+d' % (name, len(d), m, se, m / se if se else 0,
          sum(x > 1e-9 for x in d), sum(x < -1e-9 for x in d), sum(r['dw'] for r in rs)))
print('decisions with both a flip and a placebo:', len(rows))
S('all', rows)
if rows and rows[0].get('dswap'):   # DISCARD-CHOICE audit: the engine's discard set -> its runner-up set
    for lo, hi in ((1, 1), (2, 4), (5, 8)):
        S('ante %d-%d' % (lo, hi), [r for r in rows if lo <= r['ante'] <= hi])
    S('runner-up discards MORE cards', [r for r in rows if r['nf'] > r['nb']])
    S('runner-up discards same count', [r for r in rows if r['nf'] == r['nb']])
    S('runner-up discards FEWER cards', [r for r in rows if r['nf'] < r['nb']])
    for n in range(1, 6): S('engine discarded %d card(s)' % n, [r for r in rows if r['nb'] == n])
    sys.exit(0)
for t, lab in (('DISCARD', 'engine dug -> its best play'), ('PLAY', 'engine played -> its best dig')):
    S(lab, [r for r in rows if r['type'] == t])
    for lo, hi in ((1, 1), (2, 4), (5, 8)):
        S('   ... at ante %d-%d' % (lo, hi), [r for r in rows if r['type'] == t and lo <= r['ante'] <= hi])
