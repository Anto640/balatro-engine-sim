#!/usr/bin/env python3
# tools/decision_audit_dplan.py -- jobs for the DISCARD-CHOICE audit (alts 'dswap' / 'dplacebo', sim/world.lua): one
# discard decision per seed of a baseline arm, sampled uniformly over the discards the run made (estimated from each
# blind's spare discards: base 4 on the Red Deck -- a k past the real count makes both jobs miss, and they are dropped).
#   usage: python tools/decision_audit_dplan.py <baseline.jsonl> <jobs.txt> [base_discards=4] [salt=0]
import sys, json, random, collections
src, out = sys.argv[1], sys.argv[2]
base = int(sys.argv[3]) if len(sys.argv) > 3 else 4
salt = int(sys.argv[4]) if len(sys.argv) > 4 else 0
used = collections.Counter()
for l in open(src):
    try: r = json.loads(l)
    except Exception: continue
    if r.get('kind') == 'blind_result': used[str(r.get('seed'))] += max(0, base - (r.get('discards_left') or 0))
jobs = []
for s in sorted(used, key=int):
    if used[s] < 1: continue
    k = random.Random(int(s) * 7919 + salt).randint(1, used[s])
    jobs += ['%s %d dswap' % (s, k), '%s %d dplacebo' % (s, k)]
open(out, 'w').write('\n'.join(jobs) + '\n')
print(len(jobs), 'jobs from', len(used), 'seeds')
