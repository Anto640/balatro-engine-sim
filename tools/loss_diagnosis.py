# tools/loss_diagnosis.py — POSITION-LEVEL failure taxonomy of the engine's OWN losing sim runs,
# plus the supply-vs-competence test (were multipliers OFFERED+AFFORDABLE but passed, or never seen?).
#
# Answers the question the micro-fix loop cannot: are the engine's losses a FEW recurring gestalt
# mistakes (fixable at the policy level, no learned value needed) or DISTRIBUTED / supply-bound
# (needs the compute path)?  See WINRATE_V4_PLAN "LOSS DIAGNOSIS".
#
#   usage: python tools/loss_diagnosis.py <runs.jsonl> <jokercls.json>
import json, collections, sys

simfile = sys.argv[1] if len(sys.argv) > 1 else "sim_out/v4_base.jsonl"
clsfile = sys.argv[2]
CLS = json.load(open(clsfile))
def cls(k): return CLS.get(k, "other")
def is_mult(k): return cls(k) == "mult"

runs = collections.defaultdict(lambda: {"antes": [], "shops": [], "gains": [], "losses": [], "death": None, "win": None})
for l in open(simfile, encoding="utf-8"):
    l = l.strip()
    if not l: continue
    try: r = json.loads(l)
    except: continue
    s = r.get("seed"); k = r.get("kind")
    if not s: continue
    R = runs[s]
    if   k == "ante": R["antes"].append(r)
    elif k == "shop": R["shops"].append(r)
    elif k == "joker_gain": R["gains"].append(r)
    elif k == "joker_loss": R["losses"].append(r)
    elif k == "death": R["death"] = r
    elif k == "win":   R["win"] = r

def counts(jokers):
    c = collections.Counter(cls(k) for k in jokers)
    return c["mult"], c["econ"], c["flat"], c["scaling"], c["flat"] + c["scaling"]

classes = collections.Counter()
rows = []
for s, R in runs.items():
    if R["win"] or not R["death"]: continue
    d = R["death"]; jok = d.get("jokers", [])
    nmult, necon, nflat, nscal, base = counts(jok)
    hlv = d.get("hand_level_sum", 0); ante = d.get("ante", 0)
    target = d.get("target", 1) or 1; ratio = d.get("scored", 0) / target
    max_nmult = nmult
    for a in R["antes"]:
        max_nmult = max(max_nmult, counts(a.get("jokers", []))[0])
    mult_off = mult_off_aff = mult_off_reserve = mult_off_pos = 0
    for sh in R["shops"]:
        doll = sh.get("dollars", 0)
        for oj in sh.get("offer_jokers", []):
            if is_mult(oj.get("key", "")):
                cost = oj.get("cost", 99) or 99
                val = oj.get("value", 0) or 0
                mult_off += 1
                if cost <= doll: mult_off_aff += 1
                if cost <= doll - 5: mult_off_reserve += 1          # buyable leaving a $5 reserve
                if cost <= doll - 5 and val > 0: mult_off_pos += 1  # ...AND the engine rated it positive
    mult_gained = sum(1 for g in R["gains"] if is_mult(g.get("key", "")))
    mult_sold   = sum(1 for x in R["losses"] if is_mult(x.get("key", "")) and x.get("via") == "sell")
    # primary failure class (priority order; competence-level)
    if ratio >= 0.85:                              cl = "VARIANCE"          # had ~enough, fell short (not a build error)
    elif max_nmult <= 1:                           cl = "NO_CORE"          # never assembled 2+ multipliers
    elif necon >= 2 and nmult <= 2:                cl = "ECON_CLOG"        # money-makers clog scoring slots
    elif nmult >= 2 and base <= 1:                 cl = "BASELESS"         # multipliers, nothing to multiply
    elif nmult >= 2 and base >= 2 and hlv < 2 * max(0, ante - 2): cl = "UNDERLEVEL"
    elif ante <= 3:                                cl = "STARVED_EARLY"    # died early, thin everything
    else:                                          cl = "COHERENT_LOSS"    # had core+base+levels, still lost
    classes[cl] += 1
    rows.append(dict(seed=s, cl=cl, ante=ante, dollars=d.get("dollars", 0), nmult=nmult,
                     max_nmult=max_nmult, necon=necon, base=base, hlv=hlv, ratio=round(ratio, 2),
                     mult_off=mult_off, mult_off_aff=mult_off_aff, mult_off_reserve=mult_off_reserve,
                     mult_off_pos=mult_off_pos, mult_gained=mult_gained, mult_sold=mult_sold))

# WIN-run contrast: what did the 13 winning runs' multiplier supply/acquisition look like?
win_rows = []
for s, R in runs.items():
    if not R["win"]: continue
    mo = mg = 0
    for sh in R["shops"]:
        for oj in sh.get("offer_jokers", []):
            if is_mult(oj.get("key", "")): mo += 1
    mg = sum(1 for g in R["gains"] if is_mult(g.get("key", "")))
    win_rows.append((mo, mg))

nloss = len(rows)
print(f"=== LOSS-DIAGNOSIS: {nloss} losing runs in {simfile} ===\n")
print("FAILURE CLASS DISTRIBUTION (primary, competence-level):")
for cl, n in classes.most_common():
    print(f"  {n:4d}  {100*n/nloss:5.1f}%  {cl}")

def agg(pred, label):
    sub = [r for r in rows if pred(r)]
    if not sub: return
    n = len(sub)
    def mean(f): return sum(r[f] for r in sub) / n
    print(f"\n{label}  (n={n})")
    print(f"  died: ante {mean('ante'):.1f}, ${mean('dollars'):.0f}")
    print(f"  multipliers OFFERED in shops (total slots)     : mean {mean('mult_off'):.1f}")
    print(f"  ...AFFORDABLE (cost<=$)                          : mean {mean('mult_off_aff'):.1f}")
    print(f"  ...buyable leaving a $5 RESERVE                  : mean {mean('mult_off_reserve'):.1f}")
    print(f"  ...AND the engine RATED IT POSITIVE but passed  : mean {mean('mult_off_pos'):.1f}  <-- competence")
    print(f"  multipliers ACQUIRED (joker_gain)               : mean {mean('mult_gained'):.1f}")
    print(f"  multipliers SOLD (churned)                      : mean {mean('mult_sold'):.1f}")
    print(f"  max multipliers held simultaneously             : mean {mean('max_nmult'):.2f}")

print("\n" + "=" * 60)
print("SUPPLY vs COMPETENCE TEST")
print("=" * 60)
agg(lambda r: True, "ALL losing runs")
agg(lambda r: r["cl"] == "NO_CORE", "NO_CORE losses (never assembled a core)")
agg(lambda r: r["cl"] in ("ECON_CLOG", "BASELESS", "UNDERLEVEL", "COHERENT_LOSS"), "HAD-A-CORE losses")

if win_rows:
    n = len(win_rows)
    print(f"\nWIN runs (contrast, n={n}):  multipliers OFFERED mean {sum(m for m,_ in win_rows)/n:.1f}"
          f" | ACQUIRED mean {sum(g for _,g in win_rows)/n:.1f}")

print("\nREADING:")
print("  If NO_CORE runs were OFFERED (and could AFFORD) multipliers they didn't take -> COMPETENCE")
print("  (fixable policy). If ~0 affordable multipliers were ever offered -> SUPPLY (needs compute/luck).")
print("  High 'multipliers SOLD' -> the engine churned its own core (a third, distinct failure).")
