#!/usr/bin/env python3
# tools/decision_audit_report.py -- summarise a decision audit (tools/decision_audit.lua) against its baseline arm.
# For every audited decision: delta = outcome(forced alternative) - outcome(engine's own choice), on the same seed and
# world (progress as in analyze_runs: (ante-1) + (blind + min(1, scored/target))/3, a win = 8). Positive = the
# alternative did better than what the engine chose. Grouped by what the engine chose vs what replaced it, by ante,
# and by the engine's own value gap between the two.
#   usage: python tools/decision_audit_report.py <baseline.jsonl> <audit.jsonl>
import sys, json, collections, statistics as st, math
BI = {'Small': 0, 'Big': 1, 'Boss': 2}
def outcome(r):
    if r['kind'] == 'win': return 8.0, 1
    frac = min(1, r['scored'] / r['target']) if r.get('target') else 0
    return (r.get('ante', 1) - 1) + (BI.get(r.get('blind_type'), 0) + frac) / 3, 0
base = {}
for l in open(sys.argv[1]):
    try: r = json.loads(l)
    except Exception: continue
    if r.get('kind') in ('death', 'win'): base[str(r['seed'])] = outcome(r)
forced, res = {}, {}
for l in open(sys.argv[2]):
    try: r = json.loads(l)
    except Exception: continue
    if r.get('kind') == 'forced': forced[r['job']] = r
    elif r.get('kind') in ('death', 'win'): res[r['job']] = outcome(r)
rows = []
for job, f in forced.items():
    if job not in res or f.get('missing') or not f.get('forced'): continue
    s = job.split(':')[0]
    if s not in base: continue
    (p1, w1), (p0, w0) = res[job], base[s]
    b, a = f['best'], f['forced']
    rows.append(dict(job=job, alt=f.get('alt', 'flip'), ante=f['ante'], best=b['type'], alt_t=a['type'], bt=b.get('target') or b.get('hand_type') or ' '.join(b.get('cards') or []),
                     at=a.get('target') or a.get('hand_type') or ' '.join(a.get('cards') or []), gap=(b.get('value') or 0) - (a.get('value') or 0), dp=p1 - p0, dw=w1 - w0,
                     dollars=f.get('dollars'), nj=f.get('njokers')))
def summ(name, rs):
    if not rs: return
    d = [r['dp'] for r in rs]; m = st.mean(d); se = (st.stdev(d) / math.sqrt(len(d))) if len(d) > 1 else float('nan')
    up = sum(1 for x in d if x > 1e-9); dn = sum(1 for x in d if x < -1e-9)
    wu = sum(1 for r in rs if r['dw'] > 0); wd = sum(1 for r in rs if r['dw'] < 0)
    print('  %-34s n %3d  dprog %+.3f (se %.3f)  alt better/worse/tied %3d/%3d/%3d  wins +%d/-%d'
          % (name, len(rs), m, se, up, dn, len(d) - up - dn, wu, wd))
print('audited decisions:', len(rows), '(positive dprog = the alternative beat the engine\'s choice)')
print('\nALL'); summ('all', rows)
print('\nBY ALTERNATIVE'); [summ(k, [r for r in rows if r['alt'] == k]) for k in ('2', '3', 'save', 'flip')]
print('\nBY ENGINE CHOICE -> REPLACEMENT')
g = collections.defaultdict(list)
for r in rows: g[r['best'] + ' -> ' + r['alt_t']].append(r)
for k in sorted(g, key=lambda k: -len(g[k])): summ(k, g[k])
print('\nBY ANTE')
for a in range(1, 9): summ('ante %d' % a, [r for r in rows if r['ante'] == a])
print('\nBY ENGINE VALUE GAP (best - alternative, engine units)')
for lo, hi in ((-1e9, 2), (2, 5), (5, 10), (10, 25), (25, 1e9)):
    summ('gap %s..%s' % (lo if lo > -1e8 else '-inf', hi if hi < 1e8 else 'inf'), [r for r in rows if lo <= r['gap'] < hi])
print('\nBIGGEST: alternative much better (dprog >= 1)')
for r in sorted(rows, key=lambda r: -r['dp'])[:15]:
    if r['dp'] < 1: break
    print('  %-16s a%d $%-3s j%s  engine %s %s  ->  %s %s  gap %.1f  dprog %+.2f%s' % (r['job'], r['ante'], r['dollars'],
          r['nj'], r['best'], r['bt'] or '', r['alt_t'], r['at'] or '', r['gap'], r['dp'], '  WIN' if r['dw'] > 0 else ''))
