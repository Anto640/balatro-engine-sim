"""tools/money_gap_live.py -- the money-gap measurement (tools/money_gap.lua) on LIVE runs.

usage: python tools/money_gap_live.py [save_dir]      (default %APPDATA%/Balatro)

Live telemetry has no draw-pile order, so "money cards within reach of the spare discards" is an EXPECTATION: the deck
at the blind (the latest bes_fixtures.jsonl state of that seed at or before the ante), the money cards not already
counted as held, and the share of the undrawn pile that the spare discards (3.79 cards each, measured) would draw.
Also: spare discards / hands at the end of cleared blinds, the deck's money density, and how often spare discards sat
next to a discard-to-money joker -- side by side with the sim baseline's numbers (docs/PLAN_2026-10-07_money_farming.md).
"""
import json, os, sys, collections

save = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ.get("APPDATA", ""), "Balatro")
CARDS_PER_DISCARD = 3.79
DISCARD_MONEY = {"j_mail": "Mail-In", "j_faceless": "Faceless", "j_trading": "Trading Card",
                 "j_delayed_grat": "Delayed Grat"}


def money_kinds(card):
    k = []
    if card.get("enhancement") == "m_gold": k.append("gold")
    if card.get("seal") == "Gold": k.append("gseal")
    if card.get("enhancement") == "m_lucky": k.append("lucky")
    if card.get("enhancement") == "m_steel": k.append("steel")
    return k


# 1. deck money density per (seed, ante) from the fixtures (full gs at each shop / pack decision)
decks = {}   # (seed, ante) -> counts, deck size, hand size
fx = os.path.join(save, "bes_fixtures.jsonl")
with open(fx, encoding="utf-8", errors="replace") as f:
    for line in f:
        if '"deck"' not in line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        gs = r.get("gs") or r
        meta = gs.get("meta") or {}
        seed = r.get("seed") or meta.get("seed") or (gs.get("run") or {}).get("seed")
        ante = meta.get("ante") or r.get("ante")
        deck = gs.get("deck")
        if not seed or not ante or not isinstance(deck, list) or len(deck) < 20:
            continue
        c = collections.Counter()
        for card in deck:
            if isinstance(card, dict):
                for k in money_kinds(card):
                    c[k] += 1
        hs = (gs.get("run") or {}).get("hand_size") or 8
        decks[(str(seed), int(ante))] = (c, len(deck), hs)

# 2. blinds + the board over time from bes_runs
runs = os.path.join(save, "bes_runs.jsonl")
board = collections.defaultdict(collections.Counter)
tot = collections.Counter()
spare_with = collections.Counter()
by_ante = collections.defaultdict(collections.Counter)
matched = 0
with open(runs, encoding="utf-8", errors="replace") as f:
    for line in f:
        try:
            r = json.loads(line)
        except Exception:
            continue
        k, seed = r.get("kind"), str(r.get("seed"))
        if k == "run_start":
            board[seed] = collections.Counter()
        elif k == "joker_gain" and r.get("key"):
            board[seed][r["key"]] += 1
        elif k == "joker_loss" and r.get("key"):
            board[seed][r["key"]] = max(0, board[seed][r["key"]] - 1)
        elif k == "blind_result":
            cleared = (r.get("scored") or 0) >= (r.get("target") or 1)
            if not cleared:
                continue
            a = int(r.get("ante") or 0)
            sd, sh = r.get("discards_left") or 0, r.get("hands_left") or 0
            for t in (tot, by_ante[a]):
                t["cleared"] += 1; t["spare_d"] += sd; t["spare_h"] += sh
                if sd > 0: t["with_spare_d"] += 1
            if sd > 0:
                for key, name in DISCARD_MONEY.items():
                    if board[seed][key] > 0:
                        spare_with[name] += 1
            d = decks.get((seed, a))
            if d:
                matched += 1
                c, n, hs = d
                used = (r.get("hands_used") or 0) * 4.26 + (r.get("discards_used") or 0) * CARDS_PER_DISCARD
                pile = max(1.0, n - hs - used)
                share = min(1.0, sd * CARDS_PER_DISCARD / pile)
                for kind in ("gold", "gseal", "lucky", "steel"):
                    undrawn = c[kind] * pile / n          # expected number still in the pile
                    for t in (tot, by_ante[a]):
                        t["deck_" + kind] += c[kind]
                        t["reach_" + kind] += undrawn * share
                for t in (tot, by_ante[a]):
                    t["matched"] += 1

print(f"LIVE ({save}): {tot['cleared']} cleared blinds, {matched} matched to a recorded deck")
print("ante  cleared  spare_d spare_h  w/ d   | per matched blind: deck gold gseal lucky steel | reach gold gseal lucky steel")


def row(label, t):
    c, m = max(1, t["cleared"]), max(1, t["matched"])
    print(f"{label:<5} {t['cleared']:7d}  {t['spare_d']/c:6.2f}  {t['spare_h']/c:6.2f}  {100*t['with_spare_d']/c:4.0f}%  |"
          f"  {t['deck_gold']/m:5.2f} {t['deck_gseal']/m:5.2f} {t['deck_lucky']/m:5.2f} {t['deck_steel']/m:5.2f}       |"
          f"  {t['reach_gold']/m:5.3f} {t['reach_gseal']/m:5.3f} {t['reach_lucky']/m:5.3f} {t['reach_steel']/m:5.3f}")


for a in sorted(by_ante):
    row(f"a{a}", by_ante[a])
row("ALL", tot)
m = max(1, tot["matched"])
print(f"\nGold within reach: {tot['reach_gold']/m:.2f} per cleared blind -> up to ${3*tot['reach_gold']/m:.2f}/blind if dug for and held.")
print("Cleared blinds with spare discards while a discard-to-money joker was owned:")
for name, n in sorted(spare_with.items()):
    print(f"  {name:<14} {n:4d} blinds ({100*n/max(1,tot['cleared']):.1f}% of cleared blinds)")
if not spare_with:
    print("  none")
print("\nSIM baseline mf0 (same measures, exact pile order): spare_d 2.62, spare_h 2.67, 82% with spare discards;"
      " deck gold 0.35/blind; reach gold 0.07 gseal 0.026 lucky 0.11 steel 0.05; Mail-In 2.2%, Delayed Grat 1.5%.")
