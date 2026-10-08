"""tools/selfplay_night.py -- summary of an unattended live self-play session.

usage: python tools/selfplay_night.py <runs_line_offset> <autoplay_line_offset> [save_dir]

Reads bes_runs.jsonl (from the given line on) and bes_autoplay.log (from the given line on) in the LOVE save folder
(default %APPDATA%/Balatro) and reports: runs started / finished, death-ante histogram, wins, how each run ended
(boss, ante, blind ratio), the board at death, what was bought / sold / skipped, and from the self-player log the
action counts, think-time gaps (lag), failures and stalls.
"""
import json, os, re, sys, collections, datetime

off_runs = int(sys.argv[1]) if len(sys.argv) > 1 else 0
off_ap = int(sys.argv[2]) if len(sys.argv) > 2 else 0
save = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.environ.get("APPDATA", ""), "Balatro")

recs = []
with open(os.path.join(save, "bes_runs.jsonl"), encoding="utf-8", errors="replace") as f:
    for i, line in enumerate(f):
        if i < off_runs:
            continue
        try:
            recs.append(json.loads(line))
        except Exception:
            pass

runs = collections.OrderedDict()
for r in recs:
    s = str(r.get("seed"))
    run = runs.setdefault(s, {"seed": s, "board": collections.Counter(), "buys": [], "sells": [], "max_ante": 1,
                              "end": None, "blinds": 0, "vouchers": []})
    k = r.get("kind")
    run["max_ante"] = max(run["max_ante"], int(r.get("ante") or 1))
    if k == "joker_gain":
        run["board"][r.get("key")] += 1; run["buys"].append((r.get("ante"), r.get("key"), r.get("via")))
    elif k == "joker_loss":
        run["board"][r.get("key")] -= 1; run["sells"].append((r.get("ante"), r.get("key"), r.get("via")))
    elif k == "voucher_gain":
        run["vouchers"].append(r.get("key"))
    elif k == "blind_result":
        run["blinds"] += 1
    elif k in ("death", "win"):
        run["end"] = r

finished = [r for r in runs.values() if r["end"]]
wins = [r for r in finished if r["end"].get("kind") == "win"]
deaths = [r for r in finished if r["end"].get("kind") == "death"]
print(f"LIVE SELF-PLAY: {len(runs)} runs seen, {len(finished)} finished ({len(wins)} won, {len(deaths)} lost)")
hist = collections.Counter(int(r["end"].get("ante") or 0) for r in deaths)
print("death ante histogram:", " ".join(f"a{a}:{hist[a]}" for a in sorted(hist)), f"| wins: {len(wins)}")
if finished:
    reach = lambda a: sum(1 for r in finished if r["end"].get("kind") == "win" or int(r["end"].get("ante") or 0) >= a)
    print(f"reach ante 4: {reach(4)}/{len(finished)}  ante 6: {reach(6)}/{len(finished)}  ante 8: {reach(8)}/{len(finished)}")
print("\nhow each finished run ended:")
for r in finished:
    e = r["end"]
    board = [k for k, n in r["board"].items() if n > 0]
    print(f"  {r['seed']}: {e.get('kind')} a{e.get('ante')} {e.get('blind_type') or ''} {e.get('boss_key') or ''}"
          f" ratio={e.get('ratio')} ${e.get('dollars')} board={','.join(board)}")
bought = collections.Counter(k for r in runs.values() for _, k, via in r["buys"])
sold = collections.Counter(k for r in runs.values() for _, k, via in r["sells"])
print("\nmost acquired jokers:", ", ".join(f"{k} {n}" for k, n in bought.most_common(12)))
print("most lost/sold jokers:", ", ".join(f"{k} {n}" for k, n in sold.most_common(8)))
vch = collections.Counter(v for r in runs.values() for v in r["vouchers"])
print("vouchers:", ", ".join(f"{k} {n}" for k, n in vch.most_common()))

# self-player log: actions, gaps (lag), failures
acts = collections.Counter(); fails = []; gaps = []; restarts = 0
last_t = None
tre = re.compile(r"^(\d\d):(\d\d):(\d\d) (.*)$")
with open(os.path.join(save, "bes_autoplay.log"), encoding="utf-8", errors="replace") as f:
    for i, line in enumerate(f):
        if i < off_ap:
            continue
        m = tre.match(line.rstrip("\n"))
        if not m:
            continue
        h, mi, se, msg = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4)
        t = h * 3600 + mi * 60 + se
        if last_t is not None:
            d = (t - last_t) % 86400
            gaps.append((d, line.strip()[:110]))
        last_t = t
        w = msg.split()[0] if msg.split() else ""
        if w in ("PLAY", "DISCARD", "buy", "sell", "reroll", "open", "pick", "skip", "use", "select"):
            acts[w] += 1
        if "auto-restart after" in msg:
            restarts += 1
        if re.search(r"FAIL|ERROR|error|stuck|timeout|MAX_WAIT", msg):
            fails.append(line.strip()[:140])
print(f"\nself-player actions: {dict(acts)}; auto-restarts: {restarts}")
gaps.sort(reverse=True)
print("longest gaps between self-player log lines (think time / stalls):")
for d, l in gaps[:8]:
    print(f"  {d:5d}s  before: {l}")
print(f"failures/warnings logged: {len(fails)}")
for l in fails[:15]:
    print("  " + l)
