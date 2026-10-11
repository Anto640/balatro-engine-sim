#!/usr/bin/env python3
# tools/decision_audit_plan.py -- pick the shop decisions to audit from a BASELINE arm (tools/decision_audit.lua).
# One shop visit per seed, uniform over the visits the baseline run actually had (a cleared blind is followed by a
# shop, except the final boss of a win), seeded so the plan is reproducible; two jobs per visit: the engine's
# best-ranked alternative purchase ("2") and leaving the shop instead ("save"; its third choice when it was leaving).
#   usage: python tools/decision_audit_plan.py <baseline.jsonl> <jobs.txt> [visits_per_seed=1] [salt=0]
import sys, json, random, collections
src, out = sys.argv[1], sys.argv[2]
per = int(sys.argv[3]) if len(sys.argv) > 3 else 1
salt = int(sys.argv[4]) if len(sys.argv) > 4 else 0
cleared, won = collections.Counter(), set()
for l in open(src):
    try: r = json.loads(l)
    except Exception: continue
    s = str(r.get('seed'))
    if r.get('kind') == 'blind_result' and r.get('cleared'): cleared[s] += 1
    if r.get('kind') == 'win': won.add(s)
jobs = []
for s in sorted(cleared, key=int):
    n = cleared[s] - (1 if s in won else 0)
    if n < 1: continue
    rng = random.Random(int(s) * 7919 + salt)
    for v in sorted(rng.sample(range(1, n + 1), min(per, n))):
        jobs += ['%s %d 2' % (s, v), '%s %d save' % (s, v)]
open(out, 'w').write('\n'.join(jobs) + '\n')
print(len(jobs), 'jobs from', len(cleared), 'seeds')
