#!/usr/bin/env python3
# tools/lookahead_score.py -- HEADROOM of the 1-step lookahead (WINRATE_V3_PLAN §31).
# Joins the greedy engine pick AND the lookahead pick (tools/lookahead_headroom.lua) to the human's
# actual shop action, and asks: does the lookahead move the engine TOWARD the winner?
#   - eng_buy_human_save : greedy over-buys a marginal joker the winner banked. Headroom = the
#       lookahead flips it to SAVE (agrees with the human).
#   - false_flip         : human actually BOUGHT, greedy agreed, but the lookahead wrongly flips to
#       SAVE. This is the COST of the lookahead -- it must not exceed the headroom it captures.
# Usage: python tools/lookahead_score.py <fx_pool.jsonl> <runs.jsonl> <la_pool.jsonl>
import sys, json, collections, bisect

def load(p):
    out = []
    for line in open(p, encoding='utf-8'):
        line = line.strip()
        if line:
            try: out.append(json.loads(line))
            except: pass
    return out

def main():
    FX, RN, LA = sys.argv[1], sys.argv[2], sys.argv[3]
    fixs, runs, la = load(FX), load(RN), load(LA)
    la_by = {(str(p['seed']), p['idx']): p for p in la}

    buys = collections.defaultdict(list); rerolls = collections.defaultdict(list)
    for r in runs:
        s, t = str(r['seed']), r.get('t')
        if t is None: continue
        if r.get('kind') in ('joker_gain', 'consumable_gain', 'voucher_gain'): buys[s].append((t, r.get('key')))
        elif r.get('kind') == 'reroll': rerolls[s].append(t)
    for d in (buys, rerolls):
        for s in d: d[s].sort(key=lambda x: x[0] if isinstance(x, tuple) else x)

    fixt = collections.defaultdict(list)
    for r in fixs:
        if r.get('kind') == 'state' and r.get('t') is not None: fixt[str(r['seed'])].append(r['t'])
    for s in fixt: fixt[s].sort()
    def next_t(s, t):
        a = fixt[s]; i = bisect.bisect_right(a, t); return a[i] if i < len(a) else 1e18
    def first_in(seq, t, hi):
        for x in seq:
            xt = x[0] if isinstance(x, tuple) else x
            if t < xt <= hi: return x
        return None

    C = collections.Counter()
    for r in fixs:
        if r.get('kind') != 'state' or r.get('decision') != 'shop': continue
        s = str(r['seed'])
        p = la_by.get((s, r['idx']))
        if not p: continue
        eng, look = p.get('engine'), p.get('lookahead')
        if not eng: continue
        hi = next_t(s, r['t'])
        buy = first_in(buys[s], r['t'], hi); rr = first_in(rerolls[s], r['t'], hi)
        human = 'BUY' if buy else ('REROLL' if rr else 'SAVE')
        greedy_buy = (eng.get('type') == 'BUY_JOKER')
        look_flip = bool(look and look.get('flip'))
        C['shop'] += 1
        if greedy_buy: C['greedy_buy_joker'] += 1
        # focus: greedy buys a joker
        if greedy_buy:
            if human == 'SAVE':
                C['eng_buy_human_save'] += 1
                if look_flip: C['HEADROOM_flip_to_save'] += 1          # lookahead now agrees w/ human
            elif human == 'BUY':
                C['eng_buy_human_buy'] += 1
                if look_flip: C['FALSE_flip_away_from_buy'] += 1        # lookahead wrongly banked
            elif human == 'REROLL':
                C['eng_buy_human_reroll'] += 1
                if look_flip: C['flip_on_reroll'] += 1

    print('=' * 60)
    print('LOOKAHEAD HEADROOM on greedy joker-buys (7-win pool)')
    print('=' * 60)
    print(f"  shop decisions            {C['shop']}")
    print(f"  greedy BUY_JOKER          {C['greedy_buy_joker']}")
    print(f"  eng_buy_human_SAVE        {C['eng_buy_human_save']}   (the over-buy target)")
    print(f"    -> lookahead FLIPS to SAVE  {C['HEADROOM_flip_to_save']}   << HEADROOM (agrees w/ winner)")
    print(f"  eng_buy_human_BUY         {C['eng_buy_human_buy']}   (greedy already agreed)")
    print(f"    -> lookahead FALSE-flips    {C['FALSE_flip_away_from_buy']}   << COST (banks a real buy)")
    print(f"  eng_buy_human_REROLL      {C['eng_buy_human_reroll']}  (flips {C['flip_on_reroll']})")
    hr = C['HEADROOM_flip_to_save']; cost = C['FALSE_flip_away_from_buy']
    obs = C['eng_buy_human_save'] or 1
    print('-' * 60)
    print(f"  headroom capture: {hr}/{C['eng_buy_human_save']} over-buys flipped ({100*hr/obs:.0f}%)")
    print(f"  net agreement change on joker-buys: +{hr} - {cost} = {hr - cost}")
    print(f"  precision of flips: {hr}/{hr+cost} good ({100*hr/max(1,hr+cost):.0f}%)" )

if __name__ == '__main__':
    main()
