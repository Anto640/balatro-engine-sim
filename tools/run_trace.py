#!/usr/bin/env python3
# tools/run_trace.py -- reconstruct a full LIVE run decision-by-decision by JOINING the two live logs:
#   bes_runs.jsonl     (shop/pack/blind_select decisions + engine ADVICE + ranked VALUES + skip_tag)
#   bes_fixtures.jsonl (the full STATE at each decision, incl. the in-blind HAND)
# So an advice-review session can see, per decision: the hand/shop/board + what the engine recommended
# and how it valued the options. Fields to know: shop-kind records with advice.type PLAY/DISCARD are
# IN-BLIND decisions (offer_jokers empty); with BUY_*/SAVE they're SHOP decisions. Values live in `ranked`,
# tags in `skip_tag`.  usage: python tools/run_trace.py <SEED> [runs.jsonl fixtures.jsonl]
import json, os, sys
SAVE = os.path.join(os.environ.get("APPDATA", ""), "Balatro")  # LOVE save folder
SEED = sys.argv[1] if len(sys.argv) > 1 else None
RN = sys.argv[2] if len(sys.argv) > 2 else os.path.join(SAVE, "bes_runs.jsonl")
FX = sys.argv[3] if len(sys.argv) > 3 else os.path.join(SAVE, "bes_fixtures.jsonl")
def load(P):
    return [r for r in (json.loads(l) for l in open(P, encoding='utf-8') if l.strip())
            if SEED is None or str(r.get('seed')) == SEED]
def card(c):
    if not isinstance(c, dict): return str(c)
    e = c.get('enhancement'); ed = c.get('edition')
    return f"{c.get('rank')}{(c.get('suit') or '?')[:1]}" + (f"[{e[:4]}]" if e else "") + (f"({ed[:4]})" if ed else "")
def clean(s): return (s or '').encode('ascii', 'replace').decode()
def val(v): return round(v, 2) if isinstance(v, (int, float)) else v

def main():
    if SEED is None:
        print("usage: python tools/run_trace.py <SEED>"); return
    rn = sorted(load(RN), key=lambda r: r.get('t', 0))
    fx = sorted(load(FX), key=lambda r: r.get('t', 0))
    hands = [(r['t'], [card(c) for c in (r.get('gs', {}) or {}).get('hand', [])]) for r in fx
             if r.get('kind') == 'state' and (r.get('gs', {}) or {}).get('hand')]
    def hand_before(t):
        best = None
        for ht, h in hands:
            if ht <= t + 0.01 and (best is None or ht > best[0]): best = (ht, h)
        return best[1] if best else None
    for r in rn:
        k = r.get('kind'); a = r.get('ante')
        if k == 'blind_select':
            print(f"a{a} BLIND_SELECT ${r.get('dollars')} njok={r.get('njokers')} skip_tag={r.get('skip_tag')}")
        elif k == 'shop':
            adv = r.get('advice') or {}; rk = r.get('ranked') or []; oj = r.get('offer_jokers') or []
            opts = ", ".join(f"{o.get('type')} {o.get('target') or ''}={val(o.get('value'))}" for o in rk[:6])
            if adv.get('type') in ('PLAY', 'DISCARD') and not oj:
                h = hand_before(r.get('t', 0))
                print(f"a{a}  IN-BLIND hand={h}")
                print(f"        -> {adv.get('type')} {adv.get('target') or ''} :: {clean(adv.get('reason'))[:80]}")
            else:
                offers = ", ".join(f"{j.get('key')}(${j.get('cost')})" for j in oj if isinstance(j, dict))
                print(f"a{a} SHOP ${r.get('dollars')} -> {adv.get('type')} {adv.get('target') or ''} | offers:[{offers}] | ranked:[{opts}]")
        elif k == 'pack':
            adv = r.get('advice') or {}
            items = [c.get('key') if isinstance(c, dict) else c for c in (r.get('items') or [])]
            print(f"a{a} PACK {items} -> {adv.get('type')} {adv.get('target') or ''}")
        elif k in ('joker_gain', 'joker_loss'):
            print(f"    {'+' if k=='joker_gain' else '-'}joker {r.get('key')} via {r.get('via')}")
        elif k == 'blind_result':
            print(f"a{a} [{r.get('blind_type')}] cleared: {r.get('scored')}/{r.get('target')} in {r.get('hands_used')}h {r.get('discards_used')}d")
        elif k == 'death':
            print(f"a{a} DEATH {r.get('blind_type')} {r.get('scored')}/{r.get('target')} ({100*(r.get('ratio') or 0):.0f}%)")

if __name__ == '__main__': main()
