# tools/died_rich.py -- usage: python tools/died_rich.py sim_out/<arm>.jsonl [min_dollars=25] [min_ratio=0.9]
# "Died rich": deaths holding >= min_dollars that scored >= min_ratio of the target. For each, the shops of the death
# ante (the last chance to spend): money, what the engine advised, and the affordable offers it valued positively but
# did not take. Answers: did it bank money it could have turned into the missing few percent?
import json, sys, collections
path = sys.argv[1]; MIN_D = float(sys.argv[2]) if len(sys.argv) > 2 else 25; MIN_R = float(sys.argv[3]) if len(sys.argv) > 3 else 0.9
runs = collections.OrderedDict()
for l in open(path):
    r = json.loads(l); runs.setdefault(str(r.get('seed')), []).append(r)
rich = []
for s, rs in runs.items():
    d = rs[-1]
    if d['kind'] == 'death' and (d.get('dollars') or 0) >= MIN_D and (d.get('ratio') or 0) >= MIN_R:
        rich.append((s, rs, d))
deaths = sum(1 for rs in runs.values() if rs[-1]['kind'] == 'death')
print('%s: %d deaths, %d died rich (>= $%d, >= %.0f%% of target)\n' % (path, deaths, len(rich), MIN_D, MIN_R * 100))
adv = collections.Counter(); spare_items = 0; shops_n = 0; saved_with_option = 0
for s, rs, d in rich:
    shops = [r for r in rs if r['kind'] == 'shop' and r.get('ante') == d['ante']]
    print('%-7s died a%s %-5s %s ratio %.2f  $%s  jokers %s' % (s, d['ante'], d.get('blind_type'), d.get('boss_key') or '', d.get('ratio') or 0,
          d.get('dollars'), ' '.join(j[2:] for j in d.get('jokers', []))))
    for r in shops:
        shops_n += 1
        a = (r.get('advice') or {}); adv[a.get('type')] += 1
        cash = r.get('dollars') or 0
        opts = []
        for kind in ('offer_jokers', 'offer_packs', 'offer_consumables'):
            for o in r.get(kind) or []:
                if (o.get('value') or 0) > 0 and (o.get('cost') or 99) <= cash:
                    opts.append('%s $%s v%.2f' % ((o.get('key') or o.get('name') or '?').replace('j_', '').replace('p_', '').replace('c_', ''), o.get('cost'), o.get('value')))
        if a.get('type') in ('SAVE', None) and opts: saved_with_option += 1
        spare_items += len(opts)
        print('    shop $%-3s -> %-15s %-18s | affordable +value: %s' % (cash, a.get('type'), (a.get('target') or '')[:18], '; '.join(opts) or '-'))
print('\ndeath-ante shops: %d; advice %s; SAVE/leave while a +value affordable offer existed: %d' % (shops_n, dict(adv), saved_with_option))
