#!/usr/bin/env python3
# tools/joker_realized_report.py -- summarise tools/joker_realized.lua output (AUDIT 2026-10-10, task B).
# For every shop-bought joker: predicted = the shop's scoring gain at the buy (fraction of the next boss's
# per-hand need, after projection / forward measure / tier floor); realized = its leave-one-out marginal in the
# same unit at the first shop of each later ante while held. Reports, by category and by joker:
#   * the median realized/predicted ratio at +0 (right after the buy: what the projection/floor ADDS on top of
#     the plain measurement) and at +1 / +2 antes (does the joker grow into its price?)
#   * rank correlation of predicted vs realized(+1) among buys -- does the ranking hold up?
# usage: python tools/joker_realized_report.py <out.jsonl> [min_n]
import sys, json, collections, statistics as st

def spearman(xs, ys):
    def rank(v):
        o = sorted(range(len(v)), key=lambda i: v[i]); r = [0] * len(v)
        for k, i in enumerate(o): r[i] = k
        return r
    if len(xs) < 3: return float('nan')
    rx, ry = rank(xs), rank(ys)
    mx, my = st.mean(rx), st.mean(ry)
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    den = (sum((a - mx) ** 2 for a in rx) * sum((b - my) ** 2 for b in ry)) ** 0.5
    return num / den if den else float('nan')

rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
min_n = int(sys.argv[2]) if len(sys.argv) > 2 else 8
buys = collections.defaultdict(dict)  # (seed,key,buy_ante) -> {dante: row}
for r in rows:
    buys[(r['seed'], r['key'], r['buy_ante'])][r['dante']] = r

def table(group_of, label):
    g = collections.defaultdict(lambda: collections.defaultdict(list))
    for k, d in buys.items():
        r0 = d.get(0)
        if not r0 or r0.get('pred') is None or (r0['pred'] or 0) <= 0: continue
        grp = group_of(r0)
        for da in (0, 1, 2):
            r = d.get(da)
            if r and r.get('real') is not None:
                g[grp][da].append(r['real'] / r0['pred'])
        g[grp]['pred'].append(r0['pred'])
        if d.get(0) and d[0].get('real') is not None: g[grp]['real0'].append(d[0]['real'])
    print('\n%-18s %4s  %8s %8s | realized/predicted median  +0     +1     +2   (n+1, n+2)' % (label, 'n', 'pred', 'real0'))
    for grp in sorted(g, key=lambda x: -len(g[x]['pred'])):
        G = g[grp]
        if len(G['pred']) < min_n: continue
        med = lambda v: ('%6.2f' % st.median(v)) if v else '     -'
        print('%-18s %4d  %8.3f %8.3f |                          %s %s %s   (%d, %d)' % (
            grp, len(G['pred']), st.median(G['pred']), st.median(G['real0']) if G['real0'] else float('nan'),
            med(G[0]), med(G[1]), med(G[2]), len(G[1]), len(G[2])))

print('buys with a predicted value:', sum(1 for d in buys.values() if d.get(0) and (d[0].get('pred') or 0) > 0),
      ' all buys:', len(buys))
table(lambda r: r.get('cat') or '?', 'category')
table(lambda r: 'ante %d' % r['buy_ante'] if r['buy_ante'] < 6 else 'ante 6+', 'buy ante')
table(lambda r: r['key'], 'joker')
# ranking: does predicted rank-order realized(+1)?
xs, ys = [], []
for d in buys.values():
    r0, r1 = d.get(0), d.get(1)
    if r0 and r1 and (r0.get('pred') or 0) > 0 and r1.get('real') is not None:
        xs.append(r0['pred']); ys.append(r1['real'])
print('\nSpearman(predicted, realized +1 ante) over %d buys: %.2f' % (len(xs), spearman(xs, ys)))
