#!/usr/bin/env python3
# tools/agreement.py -- PER-DECISION AGREEMENT between the engine and the winning human.
#
# The second half of the per-decision agreement objective (methodology-shift-2026-08, Step 2). It
# joins the engine's replayed pick (from tools/replay_fixtures.lua) to what the human ACTUALLY did,
# per decision, across three channels:
#   BLIND: engine PLAY/DISCARD + cards vs the human's {kind:"play"} record (direct).
#   PACK : engine pick vs {kind:"pack_pick"} (rich telemetry) or a consecutive-fixture item diff.
#   SHOP : engine best (BUY/REROLL/SAVE) vs the human's window action (joker/consumable/voucher
#          gain = BUY, reroll = REROLL, none = SAVE).
#
# Auto-discovers the pool: every seed that has decision fixtures AND a `win` record, minus --exclude.
# "rich" runs (with reroll/pack_pick events) use the direct signals; older runs fall back to diffing.
#
#   usage: python tools/agreement.py <fixtures.jsonl> <runs.jsonl> <picks.jsonl> [--exclude S1,S2]
# where picks.jsonl is the output of:  luajit tools/replay_fixtures.lua <fixtures.jsonl> picks.jsonl
import json, collections, bisect, re, sys

def load(p):
    out = []
    try:
        fh = open(p, encoding='utf-8')
    except OSError:
        return out            # missing/unreadable -> [] so the empty-input GUARD reports it cleanly
    with fh:
        for l in fh:
            l = l.strip()
            if l:
                try: out.append(json.loads(l))
                except: pass
    return out

def norm(x): return re.sub(r'[^a-z0-9]', '', str(x).lower()).replace('joker', '')
def match(a, b):
    na, nb = norm(a), norm(b)
    return bool(na) and bool(nb) and (na == nb or na in nb or nb in na)
def eng_class(e):
    t = e.get('type', '')
    if t == 'SAVE': return ('SAVE', None)
    if t == 'REROLL': return ('REROLL', None)
    if t.startswith('BUY') or t in ('SELL_TO_BUY', 'USE_CONSUMABLE'): return ('BUY', e.get('target') or e.get('key'))
    if t.startswith('SELL'): return ('SELL', e.get('target') or e.get('key'))
    return (t, e.get('target'))
def pct(c, n): return f'{c} ({100*c/n:.0f}%)' if n else '-'

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    FX = args[0] if len(args) > 0 else 'bes_fixtures.jsonl'
    RN = args[1] if len(args) > 1 else 'bes_runs.jsonl'
    PK = args[2] if len(args) > 2 else 'picks.jsonl'
    excl = set()
    for a in sys.argv[1:]:
        if a.startswith('--exclude'): excl |= set(a.split('=', 1)[-1].split(',')) if '=' in a else set()
    if '--exclude' in sys.argv:
        i = sys.argv.index('--exclude')
        if i + 1 < len(sys.argv): excl |= set(sys.argv[i + 1].split(','))

    fixs = load(FX); runs = load(RN); picks_l = load(PK)
    # GUARD (P5): load() swallows every exception, so a missing/corrupt input silently becomes []
    # and the whole report reads a clean-looking N=0 everywhere. Fail LOUD instead. Without this the
    # per-decision objective is untrustworthy (you cannot tell "engine disagrees" from "join broke").
    _paths = {'fixtures': FX, 'runs': RN, 'picks': PK}
    for _nm, _d in (('fixtures', fixs), ('runs', runs), ('picks', picks_l)):
        if not _d:
            sys.exit('AGREEMENT ERROR: %s loaded 0 records (missing/empty/corrupt: %s).\n'
                     '  Regenerate picks with: luajit tools/replay_fixtures.lua <fixtures> picks.jsonl'
                     % (_nm, _paths[_nm]))
    # discover the pool: seeds with fixtures that WON
    fx_seeds = {str(r['seed']) for r in fixs if r.get('kind') == 'state'}
    won = {str(r['seed']) for r in runs if r.get('kind') == 'win'}
    pool = sorted((fx_seeds & won) - excl)
    if not pool:
        print('no pool runs found (need seeds with fixtures AND a win, minus --exclude)'); return
    label = {s: f'run{i+1}' for i, s in enumerate(pool)}
    rich = {str(r['seed']) for r in runs if r.get('kind') in ('reroll', 'pack_pick')}

    picks = {(str(p['seed']), p['idx']): p for p in picks_l if str(p.get('seed')) in pool}
    # GUARD (P5): if NO engine picks join to the winning pool, every channel below silently zeros.
    # This is the exact failure the memory flagged (picks.jsonl stale / regenerated on a different
    # fixtures corpus). Distinguish it from a real disagreement by erroring here.
    if not picks:
        sys.exit('AGREEMENT ERROR: 0 engine picks joined to the %d-seed win pool.\n'
                 '  picks.jsonl seeds/idx do not match these fixtures (stale or wrong corpus).\n'
                 '  Re-run: luajit tools/replay_fixtures.lua %s picks.jsonl' % (len(pool), FX))
    fixs = [r for r in fixs if str(r.get('seed')) in pool]
    runs = [r for r in runs if str(r.get('seed')) in pool]

    buys = collections.defaultdict(list); rerolls = collections.defaultdict(list)
    packpicks = collections.defaultdict(list); plays = collections.defaultdict(list)
    for r in runs:
        s, t = str(r['seed']), r.get('t')
        if t is None: continue
        if r.get('kind') in ('joker_gain', 'consumable_gain', 'voucher_gain'): buys[s].append((t, r.get('key')))
        elif r.get('kind') == 'reroll': rerolls[s].append(t)
        elif r.get('kind') == 'pack_pick': packpicks[s].append((t, r.get('key')))
    for r in fixs:
        if r.get('kind') == 'play' and r.get('t') is not None: plays[str(r['seed'])].append((r['t'], r))
    for d in (buys, rerolls, packpicks, plays):
        for s in d: d[s].sort(key=lambda x: x[0] if isinstance(x, tuple) else x)

    fixt = collections.defaultdict(list)
    for p in picks.values():
        if p.get('t') is not None: fixt[str(p['seed'])].append(p['t'])
    for s in fixt: fixt[s].sort()
    def next_t(s, t):
        a = fixt[s]; i = bisect.bisect_right(a, t); return a[i] if i < len(a) else 1e18
    def first_in(seq, t, hi):
        for x in seq:
            xt = x[0] if isinstance(x, tuple) else x
            if t < xt <= hi: return x
        return None

    BL = collections.Counter(); PKc = collections.Counter(); SH = collections.Counter()
    byrun = collections.defaultdict(lambda: collections.Counter()); ex = collections.defaultdict(list)

    for r in fixs:
        if r.get('kind') != 'state' or r.get('decision') != 'blind': continue
        s = str(r['seed']); eng = picks.get((s, r['idx']), {}).get('engine')
        if not eng: continue
        arr = plays[s]; i = bisect.bisect_left(arr, (r['t'],))
        if i >= len(arr): continue
        hp = arr[i][1]; BL['n'] += 1
        if eng['type'] == hp['action']:
            BL['class_agree'] += 1
            if eng['type'] == 'PLAY':
                ec, hc = set(eng.get('cards') or []), set(hp.get('cards') or [])
                if ec and hc:
                    k = 'play_same' if ec == hc else 'play_diff'
                    BL[k] += 1; byrun[label[s]][k] += 1

    packfx = collections.defaultdict(list)
    for r in fixs:
        if r.get('kind') == 'state' and r.get('decision') == 'pack': packfx[str(r['seed'])].append(r)
    for s in packfx: packfx[s].sort(key=lambda x: x['t'])
    for s, arr in packfx.items():
        for i, r in enumerate(arr):
            eng = picks.get((s, r['idx']), {}).get('engine')
            if not eng: continue
            taken = None
            if s in rich:
                hi = next_t(s, r['t']); pp = first_in(packpicks[s], r['t'] - 0.01, hi + 0.05)
                taken = pp[1] if pp else None
            else:
                nxt = arr[i+1] if i+1 < len(arr) and arr[i+1]['t'] - r['t'] < 8 else None
                if nxt:
                    items = [it.get('key') for it in r['gs'].get('pack', {}).get('items', [])]
                    nit = [it.get('key') for it in nxt['gs'].get('pack', {}).get('items', [])]
                    gone = [k for k in items if k not in nit]; taken = gone[0] if gone else None
            PKc['n'] += 1; ek = eng.get('key') or eng.get('target')
            if eng.get('type') == 'SKIP_PACK': k = 'agree_skip' if taken is None else 'eng_skip_human_took'
            elif taken is None: k = 'undiffable'
            elif match(ek, taken): k = 'agree_same'
            else:
                k = 'diff'
                if len(ex['pack']) < 16: ex['pack'].append((label[s], r.get('ante'), ek, taken))
            PKc[k] += 1

    for r in fixs:
        if r.get('kind') != 'state' or r.get('decision') != 'shop': continue
        s = str(r['seed']); eng = picks.get((s, r['idx']), {}).get('engine')
        if not eng: continue
        hi = next_t(s, r['t']); buy = first_in(buys[s], r['t'], hi); rr = first_in(rerolls[s], r['t'], hi)
        h = ('BUY', buy[1]) if buy else (('REROLL', None) if rr else ('SAVE', None))
        e = eng_class(eng); SH['n'] += 1
        if s not in rich: SH['old_noreroll'] += 1
        if e[0] == h[0]:
            k = ('buy_agree' if match(e[1], h[1]) else 'buy_diff') if e[0] == 'BUY' else 'agree_' + h[0].lower()
        else:
            k = 'eng_%s_human_%s' % (e[0].lower(), h[0].lower())
        SH[k] += 1
        if k in ('eng_buy_human_save', 'buy_diff') and len(ex['shop']) < 16:
            ex['shop'].append((label[s], r.get('ante'), 'eng %s %s / human %s %s' % (e[0], e[1], h[0], h[1])))

    # GUARD (P5): picks joined but every CHANNEL is empty -> the runs file lacks the decision records
    # (joker_gain/reroll/pack_pick/play) needed to compare against (e.g. a capture-only fixtures file
    # was passed as <runs>, or the runs corpus predates rich logging). That is not "0% agreement".
    if (BL['n'] + PKc['n'] + SH['n']) == 0:
        sys.exit('AGREEMENT ERROR: %d picks joined but all channels produced 0 decisions.\n'
                 '  The runs file lacks comparable decision records (joker_gain/reroll/pack_pick/play).\n'
                 '  Check that <runs> is bes_runs.jsonl (not a fixtures file).' % len(picks))
    print('=' * 66); print('PER-DECISION AGREEMENT — %d winning runs' % len(pool)); print('=' * 66)
    for s in pool: print(f'  {label[s]} = {s}{"  [rich telemetry]" if s in rich else ""}')
    n = BL['n']; sp = BL['play_same'] + BL['play_diff']
    print(f'\nBLIND — {n} decisions')
    print(f'  PLAY/DISCARD class agreement: {pct(BL["class_agree"], n)}')
    print(f'  of shared PLAYs — SAME cards: {pct(BL["play_same"], sp)}   DIFFERENT: {pct(BL["play_diff"], sp)}')
    n = PKc['n']; print(f'\nPACK — {n} decisions')
    for k in ('agree_same', 'diff', 'agree_skip', 'eng_skip_human_took', 'undiffable'):
        if PKc[k]: print(f'  {k}: {pct(PKc[k], n)}')
    n = SH['n']; print(f'\nSHOP — {n} decisions  (older runs w/o reroll+voucher: {SH["old_noreroll"]})')
    for k in ('buy_agree', 'buy_diff', 'agree_reroll', 'agree_save', 'eng_buy_human_save',
              'eng_save_human_buy', 'eng_buy_human_reroll', 'eng_reroll_human_buy',
              'eng_reroll_human_save', 'eng_save_human_reroll'):
        if SH[k]: print(f'  {k}: {pct(SH[k], n)}')
    print('\n--- PACK disagreements (engine vs human) ---')
    for e in ex['pack']: print('  ', e)
    print('--- SHOP over-buy / diff examples ---')
    for e in ex['shop']: print('  ', e)

if __name__ == '__main__':
    main()
