# tools/arm_promising.py -- usage: python tools/arm_promising.py <baseline.jsonl> <arm.jsonl>; exit 0 when the arm is promising (paired progress > 0 and wins not lower), i.e. worth a fresh-seed replication arm
import json, sys
def load(p):
    d = {}
    for l in open(p):
        if '"kind":"death"' in l or '"kind":"win"' in l:
            r = json.loads(l); d[str(r['seed'])] = (9.0 if r['kind'] == 'win' else float(r['ante']), r['kind'] == 'win')
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
seeds = [s for s in a if s in b]
dp = sum(b[s][0] - a[s][0] for s in seeds) / max(1, len(seeds))
wa, wb = sum(a[s][1] for s in seeds), sum(b[s][1] for s in seeds)
print("paired death-ante delta %.3f, wins %d -> %d" % (dp, wa, wb))
sys.exit(0 if (dp > 0 and wb >= wa) else 1)
