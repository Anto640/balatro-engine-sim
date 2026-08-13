# WINRATE_V3_PLAN.md — the objective is wrong, the oracle is too slow, and the ceiling is unmeasured

> **Status:** proposal (2026-08-10). Successor framing to `WINRATE_AUDIT.md` / `WINRATE_AUDIT_v2.md`.
> Those documents are *correct within their frame*; this one argues the frame itself is the limiter.
> Nothing here contradicts the shipped history — it re-reads that history as evidence.
>
> **Current state being addressed:** `sim_out/p5_w6.jsonl`, **4 wins / 160 (2.5%)**, progress 3.832,
> mean death-ante ~4.0. Target framing: strong human players clear White stake near-routinely and
> Gold stake at very high rates. The gap is ~1.5 orders of magnitude in winrate. That is not a
> tuning gap.

---

## 0. TL;DR

Three structural findings, each checkable against the repo today:

1. **The incremental method is off by ~4.5× — not slow, mis-scaled.** Every lever ever shipped, end
   to end, moved mean progress **+0.487** (3.345 → 3.832) and bought **0 → 4 wins of 160**. A 50%
   winrate needs mean progress ≥ ~6.0, i.e. **+2.17 more — 4.5× the entire shipped history**, and
   that is the *optimistic* linear reading (the requirement curve is exponential in the last antes,
   so the real factor is larger). Meanwhile **the headline metric is unmeasurable**: 4 wins/160 has
   Poisson sd ≈ 2.0 (95% CI ≈ [0, 8]), so **no single lever's "wins 2→4" has ever been statistically
   distinguishable from noise.** See §1 for the Step-0 check that produced these numbers — and for
   the hypothesis it *refuted*.
2. **The controller has 107 hand-set constants and a 50-minute noisy verdict.** With per-seed
   sd ≈ 0.58, a ~3-seed noise floor, and the documented rule *"any isolated re-weight backfires"*
   (i.e. the constants are jointly calibrated), the current method is **coordinate descent in a
   107-dimensional coupled space with one noisy sample per hour**. It cannot converge. The bottleneck
   is the optimization *method*, not the supply of ideas.
3. **Nobody has measured the simulator's ceiling.** Every strategic conclusion of the project —
   "the ante-4 wall is architectural", "the wall is build-assembly variance", "the incremental method
   is exhausted" — is conditioned on a world that, as recently as W6, was silently dropping ~10
   scoring mechanics (the largest lever in project history). No experiment establishes what winrate
   an *arbitrarily good* policy achieves in this sim. That single number re-prioritizes everything.

The plan: **measure the ceiling (A), replace the hand-tuned pacing heuristic with a learned win-
probability model (B), switch the decision objective to ΔP(win) and get a 100×-faster screen (C),
and mine archetype recipes from data instead of authoring a soft commitment bias (D).** Phase E
(risk shaping) is **demoted to speculative** — Step 0 removed its evidence base. A and B1 can start
today and are low-risk.

---

## 1. Finding 1 — the scale gap (Step 0, run 2026-08-10)

### 1.0 The hypothesis I tested, and its refutation

My first draft of this document argued the engine **maximizes the wrong quantity** (expected
marginal score rather than `P(win)`), and predicted that across the shipped/reverted levers,
`Δprogress` and `Δwins` would be **uncorrelated or negatively correlated** — the "mean up, tail
down" signature.

**I ran that check against 17 recorded paired n=160 batch verdicts. It is refuted: r = +0.58.**

| Δprogress | Δwins | | Δprogress | Δwins |
|---|---|---|---|---|
| E-5 honest +0.146 | +1 | | E-11 rebase −0.074 | −3 |
| W6 +0.070 | 0 | | free-channel −0.072 | **+1** |
| W4 +0.066 | +2 | | E-12 −0.038 | −1 |
| packswap2 +0.059 | +1 | | lvlfreq −0.038 | −1 |
| coupled/W3 +0.040 | +2 | | W7 −0.035 | −1 |
| V2c lvlpush +0.020 | 0 | | W5 / E-2 / E-2b / w6-follow ≈ −0.01 | 0, 0, 0, 0 |
| E-13 +0.012 | +1 | | E-5 pre-E-11 ±0.000 | −2 |

Progress and wins **co-move**. The objective-mismatch story, in its strong form, is wrong: the
engine's expected-value valuation is not systematically trading wins for depth. Anything downstream
that rested on that claim is downgraded accordingly (Phase E in particular — see §4.E).

### 1.0b What the data says instead — and it is worse

Two things fall out of the same numbers:

- **The slope is fatal.** 0.487 progress bought 4 wins. Reaching a 50% winrate needs mean progress
  ≥ ~6.0 — **+2.17, or 4.5× everything shipped in the project's entire history**, and the last antes
  are the expensive ones, so the honest factor is higher. At the observed rate of ~+0.05/lever with
  a ~40% ship rate, that is *hundreds* of successful levers. **The incremental method is not
  converging slowly toward a win; it is converging to a plateau around ante 4–5.**
- **The verdict metric is noise.** 4 wins/160 → Poisson sd ≈ 2.0. **Every headline "wins 2→4" /
  "wins 4→2" in the project log is inside its own error bar**, which is why the two direct
  counterexamples in the table above (free-channel −0.072/+1 win; E-5 pre-E-11 ±0.000/−2 wins) exist.
  **Recommendation, effective immediately: demote `wins` from the verdict. Promote a continuous tail
  statistic** — `reach-6+` count (already tracked as a gate, sd ≈ √31 ≈ 5.6 on a base of 31, a far
  better SNR) or, better, **mean projected capacity at ante 8** (continuous, no censoring). Keep
  `wins` as a reported curiosity, not a decision input.

This *strengthens* the case for the plan below while removing a false premise from it: the problem
is not that the engine is aimed at the wrong target, it is that **the method cannot cover the
remaining distance, and cannot even see whether it is moving.** That points at Phases A (is the
distance even there?), B/C (a calibrated objective + a screen fast enough to search 107 coupled
dimensions), and D (the one structural gap a marginal valuation genuinely cannot represent).

### 1.1 What the engine actually optimizes

Trace the value chain: `shop_advisor` ranks actions by `w_score * (scoring_gain*5 + synergy + fit)`
against `w_econ * money`, where `scoring_gain` is a **measured marginal**: Monte-Carlo the deck with
and without the card, take the delta in expected fraction-of-boss-hand. The weights `w_score/w_econ`
come from `SA.weights` (`shop_advisor.lua:358–375`), which switches on a **binary `on_pace` flag**
produced by `engine/pacing.lua`.

That is an **expected-value maximizer with a survival gate**. Nowhere in the codebase is there a
quantity that means "probability this run beats ante 8."

### 1.2 The part of the objection that survives: **supermodularity**, not risk

The requirement curve is `M.ANTE_BASE = {300, 800, 2000, 5000, 11000, 20000, 35000, 50000}`, boss ×2
→ **ante-8 boss = 100,000** versus ante-1 boss = 600: a **167× climb**, ~2.05×/ante, sustained. The
win condition is a *product* of pieces — a conditional ×mult, an additive base for it to multiply, a
copier, a hand leveled 8–12 — and a product has the property that **each factor is worth ≈ nothing
without the others.**

A measured marginal valuation prices exactly one thing: `score(deck + card) − score(deck)`. On a
two-joker board an unfed conditional ×mult measures ≈ 0 — **correctly**. It is worth buying anyway,
because of what it will multiply in three antes. No marginal, however well measured, can express
that: it is not a measurement error, it is a **representational gap**. The audit's own conclusion
("a greedy per-decision valuation can't *commit to and assemble* an archetype across many shops")
is this same fact, and it is the one part of the objective critique that the Step-0 data does not
touch — because `Δprogress`/`Δwins` co-moving says nothing about what the valuation *can represent*.

That is the justification for **Phase D** (completion-distance pricing over mined recipes), and it
is independent of the refuted risk-shaping story.

### 1.3 What Step 0 does and does not license

- **Licensed:** the method-scale argument (§1.0b), the metric change (demote `wins`), Phase A
  (measure the ceiling), Phases B/C (calibrated objective + fast screen), Phase D (supermodularity).
- **Not licensed:** any claim that the engine is too risk-averse, that survival levers cost wins, or
  that "mean up / tail down" is a systematic signature. **Phase E is demoted to speculative** on
  this evidence and must not be prioritized over A–D.

---

## 2. Finding 2 — the tuning loop cannot converge

- **107** distinct `SA.* / BP.* / DE.* / CV.* / …` tunable constants in `engine/*.lua` (counted).
- Verdict cost: **paired n=160 ≈ 50 min**, per-seed sd ≈ 0.58, documented noise floor **~3 seeds**;
  a lever must move ≥5 seeds to be distinguishable.
- Documented rule: *"any isolated measurement/value re-weight that doesn't co-move the constants
  tuned around it backfires."* This is precisely the statement that the objective surface is
  **non-separable** — the coordinates interact.

Coordinate descent on a non-separable 107-dim surface with ~1 noisy sample/hour is not a slow
method; it is a **non-convergent** one. Every "revert" in the graveyard (C1, B3, F3, F4, F8,
swap-damp, coupled, cost-discount, xmult-floor, E-12, leveling-need…) is a coordinate step that
failed because its partners didn't move. The correct response is not more careful single steps —
it is (a) a **cheap surrogate objective** so you can take thousands of samples, and (b) a
**derivative-free joint optimizer** (CMA-ES/SPSA) over the constant vector. Both are Phase C.

---

## 3. Finding 3 — the ceiling is unmeasured (run this first)

Every strategic verdict in the project is of the form *"policy change X produced no winrate gain in
the sim."* None of them can distinguish:

- **(i)** the engine is bad, from
- **(ii)** the sim world cannot express a winning run, from
- **(iii)** the sim world *can*, but only through content the engine has no model for.

The W6 result is decisive proof this ambiguity is live: a pure `sim/*` fidelity fix — **engine
untouched** — was the biggest lever in project history (+0.070) because the world was silently
voiding ~10 scoring mechanics. Two prior sessions had concluded from that same world that the wall
was "architectural."

**Nobody has ever asked: what winrate does a near-optimal policy get in this simulator?** That
number bounds the entire project. If it's 15%, the engine is already at ~1/6 of the achievable and
all remaining work is world fidelity. If it's 85%, the engine is the whole problem and Phases B–E
are correctly aimed.

---

## 4. The plan

### Phase A — the Ceiling Probe *(1 session; cheap; decides the ordering of everything else)*

Three probes, each an upper/lower bracket on "how much of the 97.5% loss is engine vs world."

- **A1 — Scripted-expert policy.** Hardcode 3–4 canonical human archetypes as fixed buy-priority
  lists with a "never sell the core" rule (the three real human wins in `bes_runs.jsonl` give
  Flush-House+leveling / Hologram+copier / economy→Bull+xmult; add Blueprint/Brainstorm+conditional-
  ×mult). No measurement, no MC, no valuation — just "if offered and affordable, buy; else save."
  Run n=160. **This is the key number.** A dumb script that beats a 19k-line measured engine on
  winrate proves the valuation layer is actively harmful to the win-con.
- **A2 — Oracle-forward policy.** At each shop decision, run K=8 full forward rollouts of the
  remainder of the run under the *current* engine for each candidate action; pick argmax(win rate).
  Expensive (hours at n=20) but it is a genuine upper bound on what shop decisions alone can buy,
  and it directly measures the value of lookahead — which is Phase C3's business case.
- **A3 — Resource-lesion controls.** Re-run the engine with (a) $100/round, (b) 8 joker slots,
  (c) both, (d) the shop stocked from the top-tier joker pool only. If winrate stays under ~30% with
  unlimited money and slots, **acquisition is not the bottleneck** — the scoring model or the world
  is — and Phases B–D are aimed at the wrong layer.

**Decision rule:** `A1 ≫ engine` → Phase B/C/D (valuation is the problem). `A1 ≈ engine, both low` →
world fidelity is still binding; go back to the W6-class mining vein with a systematic mechanic-
coverage diff rather than opportunistic agent passes. `A3 stays low` → scoring model audit first.

*Cost:* A1 ≈ half a day of work + one batch. A3 ≈ two hours (config flags + four batches). A2 is the
expensive one and can be deferred until A1/A3 report.

**Bonus probe (2 hours, do it with A):** replay the three real human winning runs' *decision
sequences* through the sim. If the sim kills a run that a human actually won with those exact
decisions, the divergence point localizes a fidelity bug **exactly**, with a ground-truth label.
This is a far sharper fidelity oracle than mining for voids, and the data already exists.

---

### Phase B — a **learned win-probability model** replaces the hand-tuned pacing heuristic

**This is the fresh lever and the highest-leverage single change in the codebase.**

`engine/pacing.lua` is 81 lines. Its core is:

```lua
local g = 1.25 + 0.30*xmult + 0.15*scaling + 0.05*min(hand_lv,12)
        + min(money,40)/160 + min(econ,12)/40      -- clamped to [1.0, 3.0]
```

Six invented coefficients, projected deterministically to ante 8, reduced to a **binary flag**
(`on_pace`) plus a point-estimate `margin`. **Every strategic gate in the engine hangs off this
one function**: `SA.weights`, `pack_need`, `SA.proj_damp`, the build-plan invest gate, the E-13
endgame collapse. It is simultaneously the most consequential and the least evidenced object in the
project.

Replace it with a model **fitted on the simulator's own self-play data**:

- **B1 — feature emission (no risk; do it during Phase A).** The telemetry already emits, per ante:
  `capacity`, `pace_margin`, `on_pace`, `run_strength`, `joker_details` (key/edition/stickers/slot-
  free), `hand_level_map`, dollars, deck. Add: xmult/scaling/econ counts, best-hand-type + its level,
  deck enhancement/seal counts, joker-slot occupancy, consumable holdings, ante, blind index. That is
  ~25 features and roughly 30 lines in `sim/driver.lua:metrics`.
- **B2 — corpus.** 5k–20k runs via `sim_par.sh`. **The `BES_MC_CAP` cheap path is acceptable here**
  — it distorts *verdicts*, but we are fitting a value function over states, not adjudicating an A/B.
  Generate at multiple caps and include the cap as a feature to check for distortion.
- **B3 — fit.** Labels: dense `reach(a+1)` per ante-boundary state, plus the sparse `win` label.
  Fit `P(reach a+1 | s)` by logistic regression, then chain to `P(win | s)` by fitted value
  iteration (one-step bootstrap: `V(s) = P(reach a+1|s) · E[V(s')]`). The dense label solves the
  4-positives-per-160 sparsity problem. Logistic regression is deliberate: ~25 weights, inspectable,
  trivially exportable to a Lua table, and **~25 multiply-adds at inference** — safe for the live
  in-game overlay where an MCTS would not be.
- **B4 — swap.** `P.pace` returns the same shape (`on_pace`, `margin`, `urgent`, `capacity`) but
  derived from calibrated `p_win`: `on_pace := p_win ≥ τ`, `margin := p_win/τ`, `urgent := P(clear
  this boss) < τ_u`. **Interface unchanged → minimum cascade**, which is exactly the property the
  project's proven rule demands. Verify paired n=160 with the tail gate.

**Why this is the right shape under the project's own rule:** it is not a re-weight of one constant
among 107 — it is a **superior-machinery swap at the root of the gate hierarchy**, the same shape as
F1/F2 (the best-signal lever of the effort, which replaced a mean-rule with a measured arbitration).
It also *retires* the coefficient-guessing problem for the 6 pacing constants permanently, and gives
every downstream constant a calibrated signal to be tuned against.

**Diagnostic value even if the swap is neutral:** the fitted coefficients tell you, empirically,
what actually predicts winning in this sim. If `xmult_count` gets 10× the weight the heuristic gave
it, that's a measured indictment of the whole valuation. That readout alone is worth the phase.

---

### Phase C — objective = ΔP(win), and a 100× faster screen

- **C1 — the decision rule.** With `V(s) = P(win | s)` from B, the shop decision becomes
  `argmax_a V(s')`. This is the AlphaZero pattern, and critically it **automatically produces the
  risk profile a human expert has**: when `V` is low, the action that maximizes `V` is the
  high-variance one (a weak-now ×mult, a gamble pack) because safe accumulation has near-zero win
  probability; when `V` is high it plays safe. E-13 ("when ante≥7 and behind, collapse economy
  weight") is a hand-carved special case of exactly this shape; C1 generalizes it to every ante and
  every decision. *(Caveat per §1.0b: E-13's headline "wins 3→4" sits inside the Poisson error bar —
  its `t=2.25, p=0.025` was on **progress**, which is the claim that stands. Do not over-weight it,
  and note that the risk-profile benefit above is now a **hypothesis**, not an evidenced one.)*
- **C2 — the shop replay harness (the decisive process fix).** `tools/replay_states.lua` already
  does screen-then-batch for *in-blind* states. Extend the corpus extractor to **shop states**
  (offers + full gs + subsequent outcome). Then any shop lever is screened in **seconds** against
  thousands of recorded states by ΔV, instead of a 50-minute noisy batch. This turns ~1 verdict/hour
  into ~100/hour and finally makes the 107-constant space searchable.
  - **C2b — joint optimization.** With a cheap surrogate, run CMA-ES (or SPSA) over the whole
    constant vector. This is the escape hatch from Finding 2: the constants are coupled, so
    **optimize them jointly**, which no single-lever experiment can do. Validate the result with one
    honest paired n=160 batch. *(Guard against surrogate overfit: hold out seeds, and require the
    final batch to confirm.)*
- **C3 — revive MCTS as shop-only lookahead.** `MCTS_PLAN.md` was deferred for a good reason: no
  value function to back up. B supplies one. Search 2–3 ply over `{buy, skip, reroll, save}` only.
  **Do not search in-blind** — measured play regret is 0.0076 (near-optimal); the entire loss is in
  the build. Budget-capped so the live overlay stays responsive.

---

### Phase D — archetype **recipes mined from data** (pattern recognition, done properly)

The Phase-5 "committed-archetype planner" is a *sticky soft bias* over hand types — it has no notion
of a concrete stack, its prerequisites, or its completion distance. That is why it retained at
+0.033 and produced 0 wins.

Do it as an explicit, data-derived recipe library:

1. Cluster the joker multisets of every run reaching ante 6+ across a 10k-run corpus (plus the 3
   real human wins). Frequent-itemset mining (FP-growth) over joker keys, weighted by outcome.
2. Extract the recurring stacks with their **conditional win rates** — e.g. `{conditional-×mult,
   Blueprint/Brainstorm, additive base, hand leveled 8+}` → observed P(win).
3. Store each as `{required, substitutes, prerequisites, target hand, target level, money curve}`.
4. Valuation becomes **distance-to-completion of the nearest feasible recipe**, priced by that
   recipe's fitted win rate.

This directly attacks the **supermodularity** problem that no marginal valuation can see: each piece
of a multiplicative stack is worth ≈ 0 alone and the stack is worth the run. A greedy measured
marginal is *structurally incapable* of pricing the first piece; a completion-distance metric prices
it correctly. This is the "it can't commit to and assemble an archetype across many shops" finding
from the audit, given the machinery it was missing.

---

### Phase E — explicit risk shaping *(DEMOTED — speculative; Step 0 removed its evidence base)*

> The premise for this phase was that the engine is systematically too risk-averse. **Step 0 refuted
> the observable signature of that** (§1.0). Keep E as a cheap experiment to run *after* B supplies a
> calibrated `V`, not as a priority. E2 in particular will *look* like a regression on every current
> metric, so it cannot be evaluated at all until the metric change in §1.0b has landed.

Once `V(s)` exists, the two candidate additions are:

- **E1 — the requirement *curve*, not a point projection.** Check `capacity(a) ≥ req(a)` for all
  future `a` using the **distribution** of projected capacity (variance from the MC samples the
  engine already draws), not `cap · g^Δa`. "On pace with no variance" and "behind pace with a fat
  right tail" are opposite situations that the current scalar `margin` reports identically.
- **E2 — the deliberate-gamble rule.** When `P(win) < ~5%` under the current plan, switch from
  argmax-EV to argmax-variance: skip blinds for tags, prioritize packs over safe buys, buy the
  lottery-ticket ×mult. A run that is going to die at ante 5 loses nothing by dying at ante 3
  instead — **that trade is free winrate** and the engine currently never takes it. This alone could
  move the histogram's tail without touching the mean (and will *look* like a regression on
  `progress` — which is why the metric has to change first).

---

## 5. Sequencing, cost, and risk

| Step | Cost | Risk | Unblocks |
|---|---|---|---|
| **0.** ~~Correlate historical Δprogress vs Δwins~~ | ✅ **DONE 2026-08-10** | — | r=+0.58: killed the risk thesis, exposed the 4.5× scale gap and the unmeasurable metric (§1.0) |
| **0b.** Switch verdict metric to `reach-6+` / capacity-at-8 | 1 h in `analyze_runs.lua` | none | Makes every subsequent verdict readable |
| **A1** scripted-expert winrate | ½ day + 1 batch | none (offline) | Engine-vs-world attribution |
| **A3** resource lesions | 2 h + 4 batches | none | Is acquisition the bottleneck? |
| **A-bonus** replay real human wins | 2 h | none | Ground-truth fidelity oracle |
| **B1** feature emission | 30 lines | none | The corpus |
| **B2/B3** corpus + fit | 1 day + ~10 h compute | none (offline) | Calibrated `V` |
| **B4** pacing swap | small diff | **medium** — root gate; needs paired n=160 + tail gate | Everything downstream |
| **C2** shop replay harness | 1–2 days | none (tooling) | 100× faster screening |
| **C1/C2b** ΔV objective + joint tune | days | **high** — the big rewrite | The actual winrate jump |
| **D** recipe mining | days | medium | Supermodular valuation |
| ~~**E** risk shaping~~ | small | — | **Demoted** (§4.E) — run only after B, never before A–D |

**Start today:** Step 0b, A1, A3, A-bonus, and B1 — all zero-risk, all decisive for ordering.
**Do not start** C1/D until A reports; if A3 says acquisition isn't the bottleneck, the whole
valuation stack is the wrong target.

---

## 5a. PHASE A RESULTS (2026-08-11, n=40 paired) — the bottleneck is **MONEY**

> **⚠️ READ THIS FIRST — the section below was written before the `rich` control completed, and
> `rich` overturns its headline.** The full probe table:
>
> | probe | progress | Δ vs engine | winrate | p |
> |---|---|---|---|---|
> | `engine` (baseline) | 4.244 | — | **5.0%** | — |
> | `expert` (static tier list) | 3.257 | −0.987 | 0.0% | 0.0008 |
> | `slots6` (+1 joker slot) | 4.586 | +0.342 | 5.0% | 0.081 n.s. |
> | `slots` (+3 joker slots) | 5.228 | +0.984 | 15.0% | 0.0002 |
> | **`rich`** ($100/round) | **7.334** | **+3.090** | **72.5%** | **~0** |
>
> **Money is worth ~3× what slots are worth** (+3.090 vs +0.984; winrate 72.5% vs 15.0%;
> t=10.39, sign 36/2/2). The engine is **poverty-limited first and slot-limited second.** The
> "the bottleneck is board capacity" headline below is therefore WRONG as stated — capacity is
> a real secondary constraint, not the primary one. §5a-bis's mechanism (the board locks at
> ante 3–4) still stands and is still worth knowing; it just is not the top lever.
>
> **What `rich` does NOT license:** the engine cannot award itself $100/round, so like the slot
> lesion this is a BOUND, not a lever. Its value is diagnostic: with resource scarcity fully
> removed the engine still loses **27.5%** of runs, and *that* residual is pure decision quality
> plus world fidelity, with no resource excuse available.
>
> **How money converts (from the B1 features):** hand levels. `hand_lv_sum` climbs 1.9 → 10.4
> across the run — exactly the "one hand leveled 8–12" archetype the project identified in its
> three real human wins — while `tier_sum` only crawls 25 → 36 because the board stays pinned at
> ~5.3 jokers. **Money and slots are COMPLEMENTS:** cash converts to levels, board quality needs
> slots. That also explains why `rich` is not 100%.
>
> **Tension to resolve (important):** §5a-ter finds that *endogenous* economy investment at ante 3
> (`econ_total`, `vouchers`) correlates NEGATIVELY with survival, while *exogenous* money is
> overwhelmingly positive. The consistent reading is that money is enormously valuable **and the
> engine's ways of acquiring it are bad** — econ jokers cost a slot and pay back too slowly. That
> makes "how should a poor engine acquire money" the sharpest open question this probe raises.

---

### (superseded headline) the bottleneck is board capacity

Two probes have reported. Both are significant at p<0.001, and together they overturn the
framing this document opened with.

| Probe | progress | Δ vs engine | wins/40 | t | p |
|---|---|---|---|---|---|
| `engine` (baseline) | 4.244 | — | 2 (5.0%) | — | — |
| **`expert`** (A1 static tier list) | 3.257 | **−0.987** | 0 (0.0%) | −3.37 | **0.0008** |
| `slots6` (A3, **6** joker slots) | 4.586 | +0.342 | 2 (5.0%) | +1.75 | 0.081 (n.s.) |
| **`slots`** (A3, **8** joker slots) | 5.228 | **+0.984** | **6 (15.0%)** | +3.77 | **0.0002** |

**Dose–response is close to linear at ≈ +0.33 progress per joker slot** (5→6→8 slots:
4.244 → 4.586 → 5.228). Note the scale: **one extra slot is worth ~70% of the entire
shipped history of this project (+0.487)**, and three are worth 2×. The `slots6` result is
n.s. at n=40 (sign 20/13/7) and needs n=160 to call on its own, but it sits exactly on the
line the significant 8-slot result defines.

`rich` ($100/round) and `everything` were **not completed** — with unlimited money nearly every
run survives to ante 8, and no single run finished in 15 minutes on 11 cores. I cut them in favour
of the `slots6` dose–response, which is the more actionable question. **Consequence: "capacity"
and "purchasing power" are not yet fully disentangled** — the slot effect could partly be a money
effect, since a full board also has nothing to spend on. Running `rich` remains the clean control.

### A1 — the measured valuation EARNS ITS KEEP

A static catalogue-tier priority list, with no Monte-Carlo and no deck-aware measurement, is
**decisively worse** than the engine (−0.987 progress, 2 wins → 0). The hypothesis that the
valuation layer is actively harmful to the win condition is **refuted**. Do not pursue
"replace the valuation with something simpler" — and note this also weakens the Phase C1
premise, which assumed the ranking rule is what's wrong.

*Caveat:* this shows *my* script loses, not that no script can win. It is a lower bound on
scripted policies. But it is a bound in the direction that matters.

### A3 — **the binding constraint is JOKER SLOTS**, and the effect is enormous

Three extra joker slots, **with the engine completely unchanged**, produce **+0.984 progress and
tripled the winrate (5% → 15%)**. For scale: that is **twice the total progress gained by every
lever ever shipped in this project's history (+0.487)**, from one resource change.

**The mechanism, straight from the new B1 feature vectors** (means at ante 5, `tools/feature_diff.lua`):

| feature | engine | +3 slots | Δ |
|---|---|---|---|
| **`slots_free`** | **0.00** | 0.21 | +0.21 |
| `njokers` | 5.19 | 7.93 | +2.74 |
| `xmult` | 1.62 | 2.14 | +0.52 |
| `xmult_scaling` | 0.25 | 0.57 | +0.32 |
| `scaling` | 1.25 | 2.14 | +0.89 |
| `tier_sum` | 27.75 | 41.68 | +13.93 |

**`slots_free = 0.00` is the finding.** By ante 5 the baseline board is *always completely full*.
From roughly ante 4 onward the engine cannot ACQUIRE at all — every gain must route through the
swap machinery, which this project has (correctly, from four failed swap-eagering attempts)
tuned to be very conservative. **So acquisition simply halts mid-run, and the build freezes at
whatever it happened to assemble by ante 4.** Given room, the same engine with the same valuation
keeps buying, and what it buys is exactly the compounding axes: xmult, xmult-scaling, scaling.

This re-reads the project's history coherently: "the wall is build-assembly" is right, but the
cause is not that the engine *chooses* badly — A1 shows it chooses well — it is that after ante 4
it can barely choose at all.

### The within-batch win signal (free, from the same feature vectors)

Baseline boards at ante 5, runs that reached ante 7+/won vs runs that died by ante 5:

| feature | winners | losers | diff |
|---|---|---|---|
| `hand_lv_max` | 2.75 | 1.00 | **+1.75** |
| `enhanced` | 5.25 | 2.67 | **+2.58** |
| `econ_total` | 0.75 | 3.17 | **−2.42** |
| `dollars` | 27.17 | 30.11 | −2.94 |

Winners level a hand deeper, shape the deck more, and carry **less** economy and **less** cash.
This is Phase B's training signal already visible by eye, and it disagrees with the engine's
economy weighting — consistent with E-13 having been the one reliable win-producer.

### W-SLOT (2026-08-11) — the voucher-upgrade fix: SHIPPED as fidelity, **winrate-neutral**

Acting on 1(a) below: `Content.UPGRADE_VOUCHERS` added, `gen_voucher` rewritten to offer an
upgrade once its base is owned, upgrade effects implemented in `apply_voucher`, and `v_blank`
re-priced in `engine/vouchers.lua` as an option on Antimatter. **Paired n=40 vs `pa_engine`:
progress −0.064 (t=−0.45, p=0.66, n.s.), sign 5/8/27, wins 2→1.**

**Diagnosis (decisive, and the reason this is a useful negative result):** the upgrade tier
*works* — Nacho Tong (6 offered / 2 bought), Money Tree (2/1), Recyclomancy (2/1) and
Petroglyph (4/0) all reached the shop. But **`v_blank` was bought 0 times, so `v_antimatter`
was offered 0 times.** The slot never got delivered. My option price (~1.7 FV at ante 1) loses
to all ~13 competing vouchers and to SAVE, so the gate never opens.

**Verdict: KEEP as world fidelity, claim nothing about winrate** (the W5 precedent — a correct
referee is worth having even when winrate-neutral). It also fixes a real latent bug: the old
8-retry sampler could fall through and return an **already-owned** voucher. The `v_blank`
re-pricing is **principled but unvalidated — it has never once fired**; treat its constants
(`V.BLANK_OPTION_FRAC` etc.) as unproven.

**Do NOT simply raise the Blank constant until it fires.** That is knob-twiddling on a valuation
constant — the documented failure class — and it would be chasing a channel that is
*structurally rare*: it needs two $10 purchases, and a 1-in-13 offer to land in the runway.

### Why the obvious follow-up was NOT attempted (frequency math)

The engine prices a negative edition's slot at `1.0` jp ≈ 1.5 FV (`eval_function.lua:105`) and
`0.5` frac (`:474`), while pricing the **identical** +1-joker-slot effect at **8.0–12.0 FV** as
Antimatter (`vouchers.lua:128`) — a genuine 5–8× internal inconsistency, and the probe says the
higher number is the better-calibrated one. But negative editions roll at **0.3% per shop joker**
(`Content.EDITION_W`), so only ~12% of runs ever see one. That is precisely the W8 profile
("trigger cards rare, ~1–2% of runs → near-inert"), and this project's refined recipe is explicit:
**a fix wins only when the thing is BOTH strong AND frequent.** Recorded as a real inconsistency,
deliberately not batched.

**The frequent, high-value target is the saturation itself** — `slots_free = 0.00` from ante 5 —
i.e. the full-board acquisition policy. That is the guardrail-tuned swap area with an 0-for-4
history, and the audit is right that it needs a coupled retune rather than an isolated fix. What
the probe adds is the direction: the four failed attempts all made swaps *lateral and eager*;
what the lesion rewards is continued *upward* acquisition on a saturated board.

### 5a-bis. The ACQUISITION PROFILE (`tools/acquisition_profile.lua`) — and a correction

Measuring the halt directly in the n=40 baseline:

| ante | free slots | joker gains | joker losses | saturated shops | SAVE on a full board |
|---|---|---|---|---|---|
| 2 | 2.02 | 94 | 47 | 51 | 21 |
| 3 | 0.45 | 51 | 44 | 130 | 34 |
| 4 | 0.28 | **21** | 18 | 113 | 33 |
| 5 | 0.05 | **6** | 6 | 78 | 13 |
| 6 | 0.00 | 9 | 9 | 45 | 10 |
| 7 | 0.00 | 2 | 2 | 19 | 4 |
| 8 | 0.00 | 0 | 0 | 8 | 2 |

Two things fall out, and the second one **corrects §5a**.

**1. The board LOCKS at ante 3–4, then only churns.** Acquisition collapses 94 → 51 → 21 → 6,
and from ante 4 onward **gains equal losses almost exactly** (21/18, 6/6, 9/9, 2/2, 0/0). The
engine is not accumulating after ante 4; it is swapping in place at equilibrium. **The run is
effectively decided by the board composition it holds at ante 3–4.**

**2. The "blocked keystone" story is FALSE — and this kills the obvious fix.** Of the saturated
shops that ended in SAVE, only **15 across all 40 runs** had a nominally strong (tier ≥ 7) joker
sitting on offer — 16% of them, about **0.4 per run**. Widening the swap gate to admit keystones
therefore targets a *rare* event. This independently explains the project's **0-for-4 swap-eagering
record** and the earlier "swap-admission widening fired 4/160, 0/4" result: those levers were
aimed at something that barely happens.

What the extra slots actually buy is **VOLUME, not unblocked keystones**: at 8 slots the engine's
mid-game acquisition roughly triples (ante 4: 21 → 55, ante 5: 6 → 24, ante 6: 9 → 22), and what
it takes is ordinary mid-tier content (mean best declined tier ≈ 4.3) that accumulates
(`tier_sum` 27.75 → 41.68).

> **CORRECTION to §5a's "new top lever: slot economics".** That framing was too optimistic. The
> +0.984 is **largely not capturable by better decisions** — the engine can only obtain slots from
> rare content (the Antimatter chain, negative editions, `tag_negative`), and the frequency math
> above rules all of them near-inert. The slot lesion is closer to a bound on the **world** than a
> measure of remaining **engine** headroom. It remains the correct diagnosis of *why* the engine
> plateaus; it is not, by itself, a lever.

**What this makes actionable instead — and it is frequent, which is the property that matters:**
since the board locks at ante 3–4 and only churns afterwards, **early acquisition quality
dominates the run**, and late-game decision quality matters far less than the effort spent on it.
That inverts where tuning has been aimed (E-13 and much of Phase 4/5 target the endgame). A
front-loaded-quality hypothesis is testable, fires every run, and has never been stated.

### 5a-ter. What the ante-3 board says about the outcome (REPLICATED across two batches)

Since the board locks at ante 3–4, the natural question is which ante-3 boards go on to survive.
Split on the project's existing tail gate (reached ante 6+ vs died by ante 4), run independently
on two 40-run batches (`pa_engine` and `pa_wslot`) — **only signals that replicate in both**:

| ante-3 feature | batch A | batch B | reading |
|---|---|---|---|
| `econ_total` | **−0.84** | **−0.85** | **less passive economy is better** |
| `econ_jokers` | −0.27 | −0.24 | fewer economy jokers |
| `vouchers` | **−0.39** | **−0.34** | **fewer vouchers bought is better** |
| `tier_max` | −0.83 | −0.64 | a single high-tier joker is *not* what wins |
| `tier_sum` | +2.35 | +1.43 | a broader board of decent jokers is |
| `scaling` | +0.30 | +0.41 | scaling jokers |
| `hand_lv_sum` | +0.28 | +0.49 | deeper leveling |
| `enhanced` | +1.38 | +0.52 | deck shaping |
| `dollars` | +2.85 | +1.27 | **more cash held** |

The coherent story: **winners hold cash and a broad scoring board at ante 3; losers have converted
that cash into economy jokers and vouchers.** Note this is the *early-game* mirror of **E-13** — the
one lever in project history that reliably added wins — which collapsed the economy weight in the
*endgame*. `SA.weights` currently tilts *toward* economy when secure/on-pace.

> ⚠️ **CAUSATION IS NOT ESTABLISHED, and the reverse is very plausible.** A run with a poor shop
> stream has nothing worth buying, so it buys economy by default and also dies — which would produce
> exactly this correlation with no causal role for the econ purchase. **Do not ship an econ re-weight
> on this evidence.** It is a well-specified *hypothesis* whose test is an intervention batch
> (damp `w_econ` for antes 1–3, paired n≥40 first), not more correlation.

That intervention is nonetheless the best-motivated candidate currently on the board: it fires
**every run** (the frequency property that separates this project's wins from its inert changes),
it is replicated, and it has direct precedent in E-13.

### What this changes

1. **New top lever: slot economics.** The scarce resource is the SLOT, and the engine has no
   explicit model of it. Two concrete, already-confirmed follow-ups:

   **(a) WORLD BUG — the +1 joker slot is UNREACHABLE in the sim. Highest-confidence next fix.**
   `sim/content.lua:237 gen_voucher` is commented *"upgrades only when their base is owned"* but
   the code only ever samples `Content.BASE_VOUCHERS` — **upgrade vouchers are never generated at
   all.** So `v_antimatter` (+1 joker slot; the engine already catalogues it at FV 8.0,
   `engine/vouchers.lua:128`) can never be offered, while `v_blank` — whose *entire* real-game
   purpose is to unlock Antimatter — sits in the pool as a permanently dead option. Measured in
   the n=40 baseline: **`v_blank` took 71 voucher offers (~11% of the slot) and led nowhere.**
   The engine correctly declines it (0 bought of 71, valued 0.0), so this is not a live money
   trap — it is *dilution of the voucher channel plus the total unavailability of the single
   most valuable effect this probe identified*. This is precisely the W6/pack-swap shape (a
   FREQUENT world-side void on a channel the engine uses), which is the only class that has ever
   produced wins here — and now it has a **measured ceiling of ≈ +0.34 progress**.

   **(b) VALUATION — negative-edition jokers are slot-free and probably badly underpriced.**
   `engine/eval_function.lua:105` credits a negative edition `1.0` FV (and `:474` credits `0.5`)
   "a whole extra joker slot". Against a measured slot worth ≈ +0.33 progress, that looks far too
   low. **Treat this as a coupled retune, not an isolated re-weight** — it is exactly the class
   the project's proven rule says backfires alone. Do (a) first; it is mechanism-class and safe.

   **(c) `tag_negative`** delivers a slot-free joker and inherits the same underpricing.
2. **Reconsider the swap gate — but as trade-UP, not churn.** The four failed swap-eagering
   attempts all churned the board *laterally*. The lesion shows what is missing is continued
   *upward* acquisition on a saturated board, which is a different policy from swapping more.
3. **Phase C1 is demoted** alongside E: A1 shows the ranking rule is not the defect.
4. **Phase B is unchanged and now better motivated** — the win-signal table above is exactly what
   a fitted model would formalize, and `slots_free`/`njokers` belong in it.

**Caveats.** n=40, so the CIs are wide (slots: 15.0%, 95% CI 3.9–26.1%); confirm at n=160 before
building on it. Eight slots is **not reachable in a real run** — this is a diagnostic bound, not a
strategy. The `rich` ($100/round) and `everything` lesions are still running and will separate
"money" from "slots"; until `rich` reports, "capacity" and "purchasing power" are not fully
disentangled.

---

## 5d. Reroll feasibility gate — TRIED, INERT, REVERTED

The `rich` probe exposed a striking pathology: at $100/round the engine performs **~20 rerolls per
ante while buying ~0.1 jokers per ante** from ante 2 on — hundreds of dollars per ante spent
re-rolling a shop it structurally cannot buy from, because the board is full. In the *normal*
engine the same logic error is present: **99 of 101 rerolls (98%) happen on a full board.**

Cause, confirmed in code: the reroll is priced off `e_best` (the joker a fresh shop would surface),
and its `realizable` factor gates on **money only** — nothing checks that a SLOT exists. This is
the same rule the codebase already applies to generators ("created things need a SLOT",
`pack_open_advisor`'s `gen_fit`).

**Verdict: reverted.** Attenuating the joker term on a full board measured **+0.024 (t=0.12,
p=0.90), sign 8 better / 17 worse / 15 tied, wins 2→1** — no gain with a negative lean, i.e.
churn by this project's standard.

**The instructive part is *why*, and it points at the better fix.** A reroll also refreshes the
loose tarots/planets, which **are** buyable on a full board — but `e_best` prices only jokers. So
full-board rerolls were plausibly earning their keep through *consumables*, and damping them
removed real value. **Next attempt should ADD the consumable-refresh term, not damp the joker
term.** (Note this lands on the leveling channel, which `rich` shows is how money converts.)

---

## 5e. Does the arc GENERALIZE? (the seed-overfitting test — pilot run, full run in flight)

Revising CLAUDE.md's #1 tuning rule surfaced a question nobody has asked: **every verdict in this
project's history was measured on the same seed pool (`s*1000+3`) that changes were selected on.**
Keeping only changes that measure positive on a fixed sample fits that sample. So how much of the
retained arc (3.345 → 3.832, **+0.487**) generalizes?

**Design (difference-in-differences).** Engine-on-held-out vs engine-on-tuned is confounded — the
pools may differ in difficulty. So the **scripted expert** (`sim/probe.lua`), never tuned on either
pool, serves as the difficulty control:

`DiD = (engine_heldout − engine_tuned) − (expert_heldout − expert_tuned)`

**Pilot, n=40/cell** (`tools/overfit_report.lua`):

| cell | mean | sd | SE |
|---|---|---|---|
| engine tuned (+3) | 4.244 | 1.582 | 0.250 |
| engine held-out (+7) | **3.867** | 1.695 | 0.268 |
| expert tuned (+3) | 3.257 | 1.510 | 0.239 |
| expert held-out (+7) | **3.342** | 1.644 | 0.260 |

engine held-out − tuned = **−0.377** · expert (control) = **+0.085** · **DiD = −0.462 (SE 0.509,
t = −0.91)**. Engine wins also fell 2/40 → 0/40 while the expert stayed at 0/40.

The direction is exactly what overfitting looks like — the engine drops off its tuned pool while a
never-tuned policy does not — and the magnitude (−0.462) is comparable to **the entire shipped arc.**

> ⚠️ **But by this document's own standard, that is NOT evidence. MDE at n=40/cell is 1.425 — about
> 3× the arc.** A run this size cannot detect the effect it is looking for, whatever it prints. Filed
> as a *pilot*, not a result.

### ✅ RESULT (n=344 tuned / n=308 held-out): **no overfitting. The concern is NOT supported.**

| cell | mean | sd | n | SE |
|---|---|---|---|---|
| engine tuned (+3) | 3.716 | 1.630 | 344 | 0.088 |
| engine held-out (+7) | 3.665 | 1.763 | 308 | 0.100 |

**engine held-out − tuned = −0.050 (SE 0.133, t = −0.38), 95% CI ≈ [−0.31, +0.21].**

The pilot's −0.377 collapsed to −0.050 — textbook regression to the mean, exactly as its own MDE
warned. **An arc-sized overfitting effect (0.487) is excluded at 95% confidence**, since the CI's
worst case (−0.31) is well inside it. The never-tuned expert control is only needed if the two pools
differ in difficulty; with the engine difference at ~0 it cannot change the conclusion (its n=40
estimate, +0.085, points the other way anyway). **The retained tuning arc generalizes. The method is
sound on this axis** — a real doubt, tested and closed.

### ⚠️ The secondary finding is the one to actually act on

**At n=40 the same engine on the same seed pool measured 3.716 → 4.244 — an error of +0.53, larger
than the entire shipped arc.** The first 40 seeds are simply unrepresentative. This is the power
problem from CLAUDE.md's revised rule, demonstrated on the project's own baseline.

**What this does and does not invalidate:**
- ❌ **Unpaired absolute means at n=40 are near-worthless.** Any "progress = X" quoted from a 40-seed
  batch carries ~±0.5 of error.
- ✅ **The Phase A probe verdicts SURVIVE**, because they were *paired* — same seeds, both arms — with
  SE 0.20–0.30. `slots` +0.984 and `rich` +3.090 stand unchanged. Pairing is doing very heavy lifting
  here, and is the reason the probe results are trustworthy while their absolute means are not.

---

## 5f. Can the engine MANUFACTURE money? (interest headroom, n=344 baseline)

`rich` proved money is the dominant constraint, so the obvious follow-up is: how much more money
could better play actually produce? The largest endogenous source is **interest** ($1 per $5 held,
capped at $5/round — `Mechanics.INTEREST_PER/CAP`). Measured on the n=344 baseline:

| ante | median $ | mean $ | interest earned (of $5 max) | forgone per ante |
|---|---|---|---|---|
| 2 | **$1** | 1.6 | 0.23 | $14.3 |
| 3 | $7 | 8.3 | 1.44 | $10.7 |
| 4 | $18 | 18.0 | 3.15 | $5.5 |
| 5 | $25 | 24.6 | 4.09 | $2.7 |
| 6–8 | ~$27 | ~30 | ~4.4 | ~$1.7 |

**Total forgone interest ≈ $28 per run.** The engine is broke early (median **$1** at ante 2) and
is already at the interest cap from ante 5 on — the economy is close to fully extracted.

**So money is a BOUND, not a lever — the same shape as slots.** Against the ~$2,000/run that `rich`
injects, a perfect-interest policy recovers $28. Even at a generous marginal rate this is far below
the n=344 paired MDE (~0.2–0.28), so **interest discipline is not worth pursuing** and neither, by
the same arithmetic, is any other endogenous source of comparable size.

> ⚠️ The linear conversion (3.090 progress / $2000 ≈ 0.0015/$) is almost certainly wrong at low
> doses — marginal dollars are worth more when poor. That is exactly what the money DOSE–RESPONSE
> (`rich10`/`rich25`/`rich50`, in flight) measures. If +$10/round already buys most of the gain, the
> low-dose slope is much steeper and small recoveries matter more than this table suggests.

### The reframe this forces: **conversion efficiency, not acquisition**

The `rich` shop-action profile shows where the money actually goes, per run per ante:

| action | rich ($100/rd) | baseline |
|---|---|---|
| REROLL | **~20** | 0.6–0.8 |
| BUY_PACK | 2.5–3.5 | 0.3–0.9 |
| BUY_JOKER | **~0.1** | 0.1–0.5 |

At escalating reroll costs ($5, $6, $7 …) **~20 rerolls is ~$290/ante — roughly 90% of the budget —
returning ~0.1 joker purchases.** Meanwhile ~3 packs/ante cost ~$20 and drive the leveling that
actually wins (`hand_lv_sum` 1.9 → 10.4).

Two consequences:
1. **The rich probe's 72.5% is a FLOOR on what money is worth, not a ceiling** — it is achieved while
   wasting most of the money. Efficient conversion would need far less income to reach the same place.
2. **The lever is progress-per-dollar, not dollars.** That is a different and much more tractable
   target than "acquire more money", and it is where the remaining effort should go.

(Note the earlier full-board reroll gate — §5d — attacked exactly this, and was inert *in the poor
regime* because the baseline only rerolls ~2.5×/run. The pathology is real but rich-specific; the
poor engine's conversion problem is elsewhere, most likely in what it buys with its ~$10–20/ante.)

---

## 5g. LEVELING: the engine declines ~13 affordable offers per run

The money dose–response gave a price ($1 ≈ 0.005 progress at low dose). The **leveling**
dose–response prices the channel `rich` says money converts into (n=80/cell, paired vs the n=344
baseline):

| free levels | progress Δ | winrate | p |
|---|---|---|---|
| +1/ante | **+0.879** | 13.8% | 0.0012 |
| +2/ante | **+1.829** | 18.8% | ~0 |
| +3/ante | **+2.332** | 41.2% | ~0 |

### Supply is abundant and the declines are NOT poverty

| | per run | affordable | taken | take rate (affordable) |
|---|---|---|---|---|
| Celestial packs | 10.31 | — | — | 6.4% |
| loose planets | 4.52 | — | — | 10.1% |
| **total leveling** | **14.83** | **12.7** | **1.1** | **8.6%** |

**Only 15% of declined leveling offers were unaffordable.** The other 85% were affordable and
declined — a valuation choice. Take rate on affordable offers *falls* from 16.3% at ante 1 to
~5–8% from ante 3 on, exactly where the board locks (§5a-bis) and levels become the only growth axis.

### The engine's own valuations (from telemetry, n=344)

| offer type | mean value | median | % rated positive |
|---|---|---|---|
| loose Planet | **−0.210** | −0.360 | 35.4% |
| Celestial pack | **−0.736** | −0.436 | 36.5% |
| shop Joker | **+8.462** | +5.004 | 90.0% |

### Mechanism — and why the obvious fix is NOT worth batching

`CV.card_value` prices a planet as `level_persist × f × level_gain / need`. Decomposed at ante 3
(`need` = 1000): one level of Straight is worth **+300 chips-equivalent, 30% of a boss hand** — but
`f` (from `CV.hand_frequencies`) is the probability that hand is **currently your best play**, and
0.125 crushes it to 0.0375.

`f` is the wrong counterfactual: **leveling a hand redirects which hand you play**, so the purchase
changes the very number used to price it — a self-fulfilling underestimate that stops concentration
ever starting. Measured directly (bump the level, re-run `hand_frequencies`):

| hand | f now | f after +1 | f after +4 | vfrac now | vfrac after +1 |
|---|---|---|---|---|---|
| High Card | 0.100 | 0.250 | 0.900 | 0.0081 | 0.0203 |
| Pair | 0.225 | 0.600 | 0.825 | 0.0402 | 0.1072 |
| Two Pair | 0.375 | 0.375 | 0.400 | 0.0975 | 0.0975 |

> **The correction is real but ~2.7× at best, and the gap is ~12×.** Pair's shop value moves from
> ≈ −0.73 to ≈ −0.31 — **still negative, so it would change almost no decisions.** Shipping the
> `f` fix alone is predictably INERT; do not spend a batch on it. Recorded as a genuine
> mis-specification, not a lever.

### Honest caveat on the price

The free-levels probe grants a level **every ante to the best hand** — a concentrated, compounding
*program*. Dividing its total gain by the level count overstates the marginal value of one level
bought in isolation. **So "the engine underprices a level by 12×" is NOT established.** What is
established: a sustained leveling program is worth +0.9 to +2.3 progress, and a greedy per-purchase
valuation structurally cannot see it — the same supermodularity failure as §1.2, now quantified on
the leveling axis. That points at program-level valuation (commitment/concentration), not a constant.

### ❌ RESULT: buying the declined leveling offers does NOT help. Thread closed.

`Probe.level_first` takes the affordable leveling offers the engine declines (n=80/cell, paired):

| variant | progress Δ | sign | wins |
|---|---|---|---|
| `levelbuy` ($0 reserve) | **−0.229** (t=−1.22) | 28/43 | 1→1 |
| `levelbuy10` | −0.002 (t=−0.01) | 27/29 | 1→1 |
| `levelbuy20` | −0.084 (t=−1.04) | 19/20 | 1→0 |

**The levels landed** — this is not a case of the intervention failing to fire:

| batch | levels/run | deepest hand | hands leveled | concentration |
|---|---|---|---|---|
| baseline | 2.52 | 1.39 | 1.63 | 0.55 |
| `levelbuy` (paid) | **5.51** | 2.34 | 3.29 | 0.42 |
| `level1` (free) | 8.88 | 4.51 | 3.73 | 0.51 |

`levelbuy` more than doubled total levels at similar concentration, and still lost. **The
concentration hypothesis is not what separates them either.** The arithmetic that does fit: ~10
extra buys × ~$4.50 ≈ $45 ≈ **−0.22 progress** in money terms, against an observed −0.229 — i.e.
**the purchased levels contributed ≈ zero net**, while free levels are worth ~0.176 each.

**Conclusion: leveling is valuable but NOT PURCHASABLE at a net gain.** The engine's 8.6% take rate
is, if anything, roughly correct. The free-levels probe measures "free stuff is good", not a lever.
Do not re-attempt leveling pushes via purchase; the graveyard entry for E-17 ("money diversion lost
wins") was right and is now explained.

### What this closes, and what it leaves

Every resource axis probed this session is a **BOUND, not a lever**:

| axis | probe result | can the engine get it? |
|---|---|---|
| money | +$25/rd → 30% winrate | **no** — interest headroom is only ~$28/run (§5f) |
| joker slots | +3 → 15% winrate | **no** — only via rare content (§5a) |
| leveling | +2/ante free → 18.8% | **no** — purchasing is net-negative (above) |

And reallocation *within* the ~$80/run the engine already spends is worth at most ~+0.4 by the
money-price, while a 50% winrate needs +2.8. **The engine appears to be near a local optimum for
its architecture and its budget.** That is consistent with every intervention this session measuring
inert or negative, and it is why the remaining candidates are architectural or fidelity-side, not
tuning.

---

## 5i. HOARDING IS HARMFUL — the cash correlation was reverse-causal

The one replicated correlation this project had (§5a-ter: at ante 3, runs reaching ante 6+ hold
MORE cash, +2.85/+1.27 across two independent batches) was flagged there as probably reverse-causal.
`Probe.hoard` tests it causally — refuse any purchase that drops the bankroll below a floor. It fires
in **every shop of every run**, so it clears the frequency ceiling. n=160/cell, paired:

| floor | progress Δ | t | p | sign |
|---|---|---|---|---|
| $10 (to ante 5) | **−0.393** | −2.58 | 0.010 | 66/87 |
| $20 (to ante 5) | **−1.191** | −7.10 | ~0 | 38/115 |
| $25 (to ante 4) | **−1.637** | −9.97 | ~0 | 28/125 |

**Monotonically harmful.** Winners hold cash *because* they are winning (a stronger board clears
blinds with hands to spare → more income), not the other way round. **The engine's spend-to-the-floor
policy is CORRECT** — money in hand is worth less than what it buys. Do not re-derive a hoarding or
econ-weight lever from that correlation; this is the causal answer.

## 5j. Scoring coverage: no void

W6 (the biggest lever in project history) was a scoring-fidelity void, so it is worth checking
whether another exists. Audited the catalogue against `joker_effects`:

**84 scoring-category jokers, 84 covered, 0 uncovered.** (The 66 remaining are economy/utility
jokers with no direct scoring effect.) There is no W6-style scoring void left to find.

## 5k. CONSOLIDATED CONCLUSION (2026-08-11)

**No winrate improvement was achieved this session. The value is diagnostic — and it is substantial,
because it eliminates most of the cheap hypotheses with measurements rather than argument.**

Probes (engine untouched — these are BOUNDS, not levers):

| probe | result | can the engine obtain it? |
|---|---|---|
| static tier list | −0.987 | — (the measured valuation earns its keep) |
| +3 joker slots | +0.984, 15% | no — rare content only |
| +$25/round | +1.941, 30% | no — ~$28/run of headroom exists |
| +2 free levels/ante | +1.829, 18.8% | no — purchasing them is net-negative |

Interventions (all inert or negative):

| intervention | result | why |
|---|---|---|
| voucher upgrade tier | −0.064 n.s. | below the frequency ceiling |
| reroll feasibility gate | +0.024 n.s. | ~2.5 rerolls/run; reverted on mechanism |
| levelbuy (take declined levels) | −0.229 | levels cost ≈ what they return |
| W-ECON (To the Moon/Rocket) | −0.055 n.s. | 5% ownership → 153/160 tied |
| hoard cash | −0.393 → −1.637 | the correlation was reverse-causal |

**What this establishes:** the engine's economic policy is close to optimal for its budget — earning
is ~maxed, hoarding hurts, and reallocating toward leveling hurts. Its joker selection beats a static
tier list. Its scoring coverage is complete. **It is near a local optimum for its architecture, and
every resource axis is a bound it cannot raise.**

**The two hypotheses that survive:**

1. **The sim is harsher than real Balatro.** The engine needs ~$25/round of extra income to look
   human, and holds a median of **$1 at ante 2 / $7 at ante 3**. If real human runs are richer at the
   same point, every conclusion above is conditioned on a too-poor world. **Test: compare the dollar
   trajectory in `bes_runs.jsonl` against the sim.** Cheap, decisive, and the same class as W6. The
   file is not in the repo — the user is providing it.
2. **The architecture cannot build multiplicative stacks** (the §1.2 supermodularity thesis). Greedy
   per-purchase valuation prices the first piece of a product at ~0. This is the audit's
   committed-archetype planner, and it is a large, high-variance bet — but it is now the ONLY
   remaining engine-side hypothesis that clears the frequency ceiling.

**Do not** spend further effort on: individual joker/voucher/tag fidelity (below the frequency
ceiling), economy tuning of any kind (§5f/§5i), leveling purchases (§5g), or reroll policy (§5d).

> **⚠ SUPERSEDED IN PART by §5m.** Hypothesis 1 above is now **REFUTED** by the real telemetry, and
> hypothesis 2 has been given a concrete, located mechanism. Read §5m before acting on this table.

---

## 5m. REAL vs SIM (`data/bes_runs.jsonl`) — the world is fair; the ENGINE IS BLIND

The user supplied the live telemetry (22 runs started, 14 completed: **1 win, 13 deaths**). This is
the test §5k flagged as *"cheap, decisive, DO THIS FIRST"*. Tool: **`tools/real_vs_sim.lua`**
(`lua tools/real_vs_sim.lua data/bes_runs.jsonl sim_out/of_engine_tuned.jsonl`). Sim reference =
the n=344 engine baseline.

### ✅ Hypothesis 1 is REFUTED: the sim is NOT a poorer world

| ante | dollars REAL med (mean) | dollars SIM med (mean) | jokers REAL / SIM | run_str REAL / SIM |
|---|---|---|---|---|
| 2 | **1.0** (7.3) | **1.0** (1.6) | 3.0 / 3.0 | 0.27 / 0.28 |
| 3 | 8.0 (17.4) | 6.7 (8.3) | 5.0 / 5.0 | 0.41 / 0.41 |
| 4 | 25.5 (32.4) | 18.0 (18.0) | 5.0 / 5.0 | 0.47 / 0.46 |
| 5 | 55.5 (52.2) | 25.0 (24.6) | 5.0 / 5.0 | 0.57 / 0.50 |

**The median human bankroll at ante 2 is $1 — identical to the sim's.** §5k's premise ("the engine
holds a median of $1 at ante 2, which surely can't be human") was simply wrong: that *is* human. The
mean gap is a fat right TAIL, not a shifted centre, and from ante 4 it is conditioned on survival
(real n falls to 6, then 3). Board size matches exactly; `run_strength` matches to ±0.01 through
ante 4; the death/progress distributions are comparable (real progress ≈3.5, sim ≈3.55).

**Pack supply is faithful too** — sim vs real share of pack offers: Celestial 31.3/30.1, Standard
29.5/31.5, Arcana 27.3/26.0, Buffoon 7.2/8.2, Spectral 4.7/4.2. All within ~1.5pp, and matching the
wiki's published weights. **The world is validated. Every §5a–§5k bound stands on a fair world.**

### The one real divergence: hand LEVELS — and its cause is not what it looked like

Real survivors carry ~5× the sim's hand levels at ante 5–6 (median 10.5 vs 2.0; 19 vs 4.3). But the
sim is not lazy about leveling — it *uses more planets per run* (1.67 vs 1.05) and **concentrates
just like a human** (1.38 vs 1.64 distinct hands leveled; 80% median concentration). So it is
neither supply, nor take-rate, nor spray.

Splitting the real `level_up` records by burst (a burst of exactly 12 in one second = Black Hole)
found the answer:

| hand | DELIBERATE level-ups | via Black Hole |
|---|---|---|
| Two Pair | 23 | 2 |
| **Five of a Kind** | **15** | 2 |
| Four of a Kind | 8 | 2 |
| **Flush House** | **4** | 2 |

**The three deepest human runs each committed to a SECRET hand.** The winning run (`IRXRZRWV`)
leveled **Five of a Kind nine times, antes 3→8**; `81XB8PIN` six times; `H129ZGT1` took Flush House.
Across **344 sim runs the engine leveled a secret hand zero times.** *(Credit to the user for
pushing back on this — my first reading dismissed these as hands nobody plays. They are strong and
very playable with deck fixing, and the data agreed with the user, not with me.)*

### Why the engine never does it: FOUR expressibility holes, all now closed

This is the same confound that already invalidated one major conclusion in `WINRATE_AUDIT.md` ("a sim
world that couldn't express the winning archetypes"). It was still present, in four places:

| # | hole | evidence | fix |
|---|---|---|---|
| 1 | `Content.PLANETS` **permanently excluded** Planet X / Ceres / Eris | `sim/content.lua:65` "the secret hands aren't reachable until unlocked" | `Content.planet_pool(run)` — a secret planet enters the pool once its hand has been PLAYED (`run.hand_type_plays`) |
| 2 | Black Hole leveled **9 hands, not 12** | both real Black Holes fired as bursts of exactly 12 | `BH_HANDS` completed |
| 3 | **15 of 18 spectrals were silent no-ops** — consumed for zero effect, incl. **Ouija / Sigil / Cryptid**, the only rank- and suit-CONCENTRATING cards in the game | facts-vs-opinion audit: 1.2% of consumable uses (0.058/run) did nothing | all 15 implemented in `use_consumable` |
| 4 | `build_plan.HAND_ORDER` listed **8 of 12 hands** | sunk levels credit only `if HAND_NAME[hand]` → the winning run's 9 Five-of-a-Kind levels would score **ZERO** toward committing | all 12 listed; `hand_matches` containment extended so a committed secret hand still fires its Pair/Trips anchors |

Hole 4 is the sharpest: the engine could not *commit* to the archetype even if it stumbled into it,
because the planner's own signal function could not see the investment. Holes 1+3 meant it could
never stumble into it in the first place. **Deck fixing → duplicate ranks → the hand → the planet →
the commitment: every link in that chain was broken.**

Safety of hole-4's fix: a secret hand scores **only** via sunk levels, and levels come only from a
planet that unlocks after the hand is played. So the planner still cannot commit speculatively —
it is feasibility-gated by construction (test-pinned in `test_build_plan.lua`).

### Honest expectations

Measured firing rates put holes 1–3 **below the frequency ceiling** (~0.06 no-op spectral uses/run;
secret hands in ~9% of human runs). Per the revised #1 tuning rule these are **correctness-class:
ship by mechanism, do not expect a paired batch to move.** They matter regardless — the live mod
advises a human, and this user demonstrably plays these builds.

**✅ MEASURED (`sim_out/spec_fix.jsonl`, paired n=160 vs `of_engine_tuned`) — world fixes 1–3 alone:**

| metric | value |
|---|---|
| paired progress Δ | **−0.019** (sd 0.546, SE 0.043) |
| t / p | −0.44 / **0.66 (n.s.)** |
| sign test | 10 better / 14 worse / **136 TIED** |
| wins | **2** (fixed) vs 1 (baseline) — Poisson noise, do not read into it |

**136 of 160 seeds byte-identical** — the prediction was right to the seed, and it also confirms the
fixes barely perturb the seeded RNG. −0.019 with SE 0.043 is nowhere near "significantly negative",
so the correctness class ships. *This is the rule working as intended: the batch was run to check for
harm, not to justify the change.*

**The chain is verified live, end to end.** Across those 160 runs the sim produced content that was
structurally unreachable before: **Five of a Kind played 3×, Flush House 3×, and `c_planet_x` reached
a shop/pack twice** (played the hand → unlocked the planet → offered it). Previously-dead spectrals
also did real work (Cryptid ×2, Sigil, Familiar, Ectoplasm, Medium). Rate: ~4% of runs touch a secret
hand — real, and exactly as rare as the ceiling analysis said.

**What actually changed in the argument:** hypothesis 1 is dead, and hypothesis 2 (supermodularity /
the committed-archetype planner) is no longer an abstraction. It now has a named mechanism, a worked
example from a real winning run, and its blind spot located at a specific line of code.

### ⚠ The fixes make the archetype POSSIBLE, not LIKELY — and that gap IS hypothesis 2

Measured on the first 50 runs after the fix: **Five of a Kind played once; Cryptid used twice.** The
chain now works end to end, but it fires at ~2% of runs, because nothing in the engine wants it:
`CV.SPECTRAL_BASE` prices Ouija at **0.3** and Cryptid at **0.4** — flat generic priors, with no term
for "this card concentrates ranks, which is the only route to a hand worth 120 chips × the levels I
have already sunk." Every link is valued in isolation, so the product is never assembled.

That is supermodularity stated concretely, and it is the same shape as the xmult-stack problem:

> A human buys Cryptid because they can see three Kings and a plan. The engine buys Cryptid only if
> Cryptid is worth 0.4 on its own — which it never is.

**So the remaining lever is not "value spectrals higher" (a magnitude tweak, refuted class). It is
making the planner's COMMITMENT feed back into card valuation** — once committed to a hand, the cards
that assemble it must be priced by the commitment, not by their standalone prior. `BP.planet_credit`
already does exactly this for planets; the deck-shaping cards have no equivalent. That is the concrete,
located next step.

### ✅ The sharpest confirmation: hole 4 alone is EXACTLY inert (`ship_state` vs `spec_fix`)

Running the full ship state (all four fixes) against the world-only arm isolates the planner fix:

```
progress  A 3.772   B 3.772   Δ +0.0000   sd 0.000   SE 0.0000
SIGN TEST: better 0 / worse 0 / TIED 160        DEATH-ANTE: 160 unchanged
```

**160 of 160 seeds identical, standard deviation exactly zero.** The planner fix changed nothing,
anywhere, because the engine never accumulates enough secret-hand levels to reach a commitment in the
first place (only 5 ante-snapshots in 160 runs show any secret-hand level at all).

This is the thesis in one measurement: **fixing the CAPABILITY changes nothing until something makes
the engine WANT the archetype.** Holes 1–4 removed four hard blocks and moved the needle by 0.000 —
which is the correct outcome and precisely why the next step must be the valuation feedback above,
not more fidelity work. Fidelity was necessary; it was never going to be sufficient.

---

## 5n. THE REFRAME (user, 2026-08-11) — **there is almost always a winning line; the engine finds none**

> *"it's not that there's a special key like secret planets — I could very easily do it without them,
> or do a run without other things or without taking something. Statistically there's basically always
> something else which, if everything is acted upon, allows for wins."*

**This is a better frame than §5m's and it should govern the next session.** The secret-hand result is
an *instance*, not a cause. A strong player does not need Five of a Kind, or any named archetype — they
need to notice which of the several viable lines *this* run is offering and commit to one. Runs are not
won by holding a particular card; they are won by **converting whatever the run offers into a line**.

### The existing data already supports this, and I had it filed under the wrong heading

The `rich` probe gave the engine **+$100/round** — an absurd, unearnable sum, ~20× the interest
headroom — and it won **72.5%**, not ~100% (§4/§5a, `sim_out/dose_rich50.jsonl`). The user asked at the
time *"surely with $100 per round it should be 100% win rate no questions asked?"* and the honest answer
is: **for a player who acts on everything, yes.** The engine, handed effectively unlimited purchasing
power, still fails a quarter of its runs. That is not a resource constraint. **It is a conversion
failure**, and it is the cleanest measurement in this whole document:

| what was removed as a constraint | winrate | reading under the reframe |
|---|---|---|
| money (+$100/round) | 72.5% | unlimited resources ≠ wins — **conversion is the bottleneck** |
| money (+$25/round) | 30% | |
| joker slots (+3) | 15% | |
| leveling (+2/ante) | 18.8% | |
| nothing (baseline) | ~1.3% | |

Every one of those probes handed the engine a resource and measured how much of it the engine could
turn into a win. **None of them reached the ceiling, because none of them changed the policy.** The
ceiling probes were measuring the *greedy policy's conversion rate*, and I had been reading them as
statements about resource scarcity.

### What this changes about the plan

1. **Do NOT chase secret hands.** §5m's fixes are correctness (keep them — the world must be honest,
   and the live overlay advises a human who plays those builds), but "add the missing archetype" is
   the wrong lesson. The next archetype would be just as inert (it measured **exactly** 0.000).
2. **Stop probing resources.** The axis is exhausted: even the absurd dose leaves 27.5% on the table.
3. **The target is LINE-FINDING**: at each decision, is there a reachable end-state that wins from
   here, and does this action advance the best one? That is a planning/search problem, not a valuation
   problem — which is why every *magnitude* lever in the graveyard failed, and why the one structural
   lever (the Phase-5 planner) is the only thing that ever measured positive.
4. **The measurable version of the user's claim** (worth doing first, cheap): for each LOST run, was a
   winning line available? A retrospective oracle over the recorded offer stream would put a number on
   "basically always" — and that number is the true ceiling this engine is failing to reach, replacing
   the resource-probe bounds as the headline diagnostic.

### The highest-value telemetry to collect next

Not more runs in aggregate — **runs where the human WINS, played with the overlay on.** The mod already
logs the engine's `advice` at every shop alongside what was actually taken, so a winning human run is a
labelled record of **divergence points**: every place the human took something the engine priced low,
and it paid. That tests the reframe at the decision level instead of the archetype level, and it is the
one input the simulator cannot generate for itself.

---

## 5o. THE LINE ORACLE — testing §5n's claim (`tools/line_oracle.lua`, n=652)

§5n predicted that most lost runs were offered enough material to win. This measures it, on
the two clean engine baselines (652 runs, 12 wins, 640 deaths). **The claim is PARTLY
supported, and the qualification is the interesting part.**

Method: walk each run's recorded offer stream and, with hindsight, build the best 5-joker board
from offers that were **affordable at the moment they appeared**. Target = the median winning
board (**tier_sum ≥ 34, xmult ≥ 3**). It is an upper bound — buying one offer starves the next,
and it ignores in-blind play.

### The naive number is CONFOUNDED — do not quote it

Only **17.3%** of lost runs were offered a full win-target board. But a run that dies at ante 2
sees a fraction of the shops one that reaches ante 8 does, so *"no material"* and *"died before
the material arrived"* are indistinguishable. **Exposure must be controlled**, comparing only
runs that reached the same cutoff:

| material offered by end of ante N | died shallow (≤N+1) | went deep (≥N+3)/won |
|---|---|---|
| a2 | tier 21.9 · xmult 0.72 | tier 23.6 · xmult 0.84 |
| a3 | tier 27.4 · xmult 1.29 | tier 28.2 · xmult 1.60 |
| a4 | tier 30.2 · xmult 1.99 | tier 31.9 · xmult 2.67 |
| a5 | tier 31.9 · xmult 2.56 | tier 34.2 · xmult 3.79 |

**At the modal death antes (2–4) the doomed runs were offered essentially what the survivors
were offered** — tier within 5%. §5n holds where it matters most.

### The engine is not failing to SPEND

Conversion of offered tier onto the actual board is **identical** between the two groups:

| cutoff | shallow: offered → held (conv.) | deep: offered → held (conv.) |
|---|---|---|
| a3 | 27.4 → 21.3 (**78%**) | 28.2 → 22.7 (**80%**) |
| a4 | 30.2 → 25.2 (**84%**) | 31.9 → 26.9 (**84%**) |
| a5 | 31.9 → 27.3 (**85%**) | 34.2 → 30.3 (**89%**) |

The board is full and the money is spent. **The difference is entirely in WHAT it is spent on.**

### The discriminator is XMULT DENSITY — and the sequencing inverts

| xmult by cutoff | shallow: offered / held / kept | deep: offered / held / kept |
|---|---|---|
| a2 | 0.72 / **0.50** / 70% | 0.84 / **0.38** / 45% |
| a3 | 1.29 / 0.79 / 61% | 1.60 / **1.10** / 68% |
| a4 | 1.99 / 1.14 / 57% | 2.67 / **1.69** / 63% |
| a5 | 2.56 / 1.41 / 55% | 3.79 / **2.17** / 57% |

Two findings, one of them counter-intuitive:

1. **The engine is xmult-light at the point it dies.** At ante 5 the doomed runs hold **1.41**
   xmult; winning boards carry **3**. It converts 85% of offered *tier* while keeping only ~55%
   of affordable *xmult* — it is substituting tier for multiplicativity, filling five slots with
   equally-tiered but multiplicatively-worse jokers. **This is supermodularity, measured.** And
   unlike everything else tested this session it clears the frequency ceiling: affordable xmult
   offers appear in essentially every run.
2. **⚠ At ante 2 the relationship INVERTS.** The runs that go on to die deep-in hold *more* xmult
   at ante 2 (0.50 vs 0.38) and keep a *higher* share (70% vs 45%). The eventual winners are
   xmult-POOR early and xmult-rich by a4–a5. That matches the analyzed human archetype
   "economy → Bull → xmult" exactly: **build base and economy first, stack xmult second.**
   So the naive reading ("buy xmult earlier") is contradicted by the data — the winners buy it
   LATER. The failure is one of SEQUENCING, which is precisely what a greedy per-decision
   valuation cannot represent and a planner can.

### What this licenses, and what it forbids

- **FORBIDDEN: a bare xmult floor/weight bump.** That exact lever (`xmult-floor`) is already in
  the refuted set, and finding 2 explains *why* it failed — front-loading xmult is what the
  LOSING runs do.
- **LICENSED: xmult density as a COMMITMENT-CONDITIONED, ANTE-STAGED target**, co-calibrated with
  the planner constants (the revised #1 rule's "calibrate jointly" clause). The shape the data
  asks for is: economy/base through ante 2, then drive toward 3 xmult by ante 5.
- **Caveat, stated plainly:** deep runs were also *offered* more xmult (2.67 vs 1.99 at a4). Some
  of that is a money → reroll → more-offers feedback loop, so part of the gap is upstream of
  joker choice and is a consequence of surviving, not a cause. The retention and sequencing
  findings do not depend on it; the "offered" gap should not be read as pure luck OR pure skill.

---

## 5b. What has SHIPPED so far (2026-08-11)

Phase A's probe harness and Phase B1's feature emission are implemented and verified.

**New files**
- `sim/probe.lua` — the ceiling-probe harness: the A1 scripted-expert policy (static
  catalogue-tier priority, zero Monte-Carlo, zero deck-aware measurement) and the A3 resource
  lesions, plus named configs (`engine`, `expert`, `rich`, `slots`, `rich_slots`, `toppool`,
  `everything`, `expert_rich`).
- `tools/probe_sweep.sh` — runs a paired batch per config.
- `tests/test_probe.lua` — 36 assertions; registered in `tests/runner.lua`.

**Hooks (all guarded on `run.probe`, which is `nil` on every normal run)**
- `sim/world.lua` — `new_run` stores the probe; `award_income` applies `income_bonus`.
- `sim/content.lua` — `gen_joker` honours `top_pool`; `shop_phase` swaps in the scripted policy.
- `sim/driver.lua` — `Driver.features(run)`, a 28-field vector on every `ante`/`death` record.
- `tools/sim_batch.lua` — reads `BES_PROBE` from the env, so `sim_par.sh` needs no new argument.

**Usage**
```bash
BES_PROBE=expert bash tools/sim_par.sh 40 pa_expert     # one config
bash tools/probe_sweep.sh 40 pa                         # the whole sweep
lua tools/analyze_runs.lua sim_out/pa_engine.jsonl compare sim_out/pa_expert.jsonl
```

**Inertness verified — this is the load-bearing property.** A paired n=12 baseline run before
and after the change produced **byte-identical output across all 835 non-metrics records**, and
death records match field-for-field outside the metrics block. `Driver.features` consumes no RNG
(asserted in the suite), so it cannot perturb the seeded stream. Tests: **856 unit + 369 sim, green.**

---

## 6. Honest caveats

- **"100% winrate" is not the achievable target.** Strong players are not deterministic winners;
  White stake with a full-content game and expert play is high but not 1.0. A realistic ambition for
  this stack is **30–60% in-sim**, with the caveat below.
- **The sim's content coverage is a hard ceiling.** The engine can only win the runs the world can
  express. Phase A measures this directly, which is why it is first.
- **This plan contradicts the project's proven rule in one place** — Phase C1 is a large coupled
  rewrite, exactly the class that has failed repeatedly. That is deliberate and it is why C2 (the
  cheap screen) must land *before* C1: the rule's failures were all *unscreenable* changes verified
  by a 50-minute noisy oracle. The rule is a symptom of the measurement cost, not a law of the game.
- **The live mod must stay fast.** A ~25-weight logistic model is fine in the overlay; shop MCTS
  needs a hard budget. Keep the pure-engine architecture intact — `V` is a pure function of the POD
  `GameState`, so nothing about the `state_extraction → model → engine → ui` discipline changes.

---

## 5p. TWO HUMAN WINS, TWO DIFFERENT LINES — and the first 100%-frequency gap

Live capture, red deck / white stake, overlay hidden (`data/bes_runs_live_2026-08-12.jsonl`).
**Two runs, two wins, two unrelated archetypes** — itself direct support for §5n:

| run | seed | final board | hand-lv at end |
|---|---|---|---|
| 1 | W9WKT1UE | Hanging Chad ×2 · Photograph · Sock and Buskin · Blueprint (**retrigger**) | 15 |
| 2 | GU73QPLY | Cavendish · Driver's License · Lucky Cat · Burnt · Hanging Chad (**xmult stack**) | **32** |

Run 2 also started *poor* — **$2 and ONE joker at ante 2** — and still won. A bad start did not
preclude a line. (Run 1 was the opposite: $27 and two jokers, banked deliberately.) The engine's
sim median is 9 hand-levels at ante 8; these runs finished on **15 and 32**.

### The finding: THE ENGINE LEAVES DISCARDS ON THE TABLE

The new `blind_result` record made in-blind behaviour visible for the first time. The human spends
**every discard even when the clear is already assured**:

| ante | blind | hands used | discards used | clear margin |
|---|---|---|---|---|
| a7 | Small | 2 | **6** | 3.9× |
| a7 | Big | 2 | **6** | 6.5× |
| a7 | Boss | 4 | **6** | 11.9× |

The engine, across **3345 sim blinds**:

| discards left at blind end | blinds | share |
|---|---|---|
| 0 (spent all) | 1138 | 34% |
| 1–3 | 1356 | 41% |
| **4 (spent NONE)** | **821** | **25%** |

**Mean 1.92 discards unused per blind; a quarter of blinds are cleared without discarding at all.**

**Mechanism.** The engine's in-blind objective is *clear the blind safely*. Once the clear is
assured a remaining discard is worth exactly zero to it, so it plays the winning hand immediately.
To the human a discard you will not need is a **free lottery ticket**: more draws mean more Lucky
and Gold card money, better scaler fuel, and more tarot targets. The user described this unprompted
("not instantly playing a winning hand but instead discarding and digging for lucky cards or
something to use my tarots on to make more money").

**Why this one is different from everything else tested this session:**

- **100% frequency** — every blind of every run, ~3345 events per 344 runs. Far above the ceiling
  that killed W-ECON, the voucher fix and the secret-hand work (§5m).
- **Not in the refuted set.** Unlike the xmult-floor family, this lever has never been tried.
- **Human-confirmed mechanism**, not inferred from survivorship.
- `engine/scaling_fuel` already establishes the principle (feed scalers when survival allows); this
  extends it from *feeding a scaler* to *spending a guaranteed-surplus resource*.

**The guardrail it needs:** digging is only free when the clear is genuinely assured. Discarding
into a worse board and failing is the failure mode, so the trigger must be a margin/confidence gate,
not "always dig". That makes it a natural companion to the existing `pace_margin` machinery.

**Next step:** probe it — a policy variant that spends remaining discards once the clear is assured,
measured paired at n≥160. This is the first candidate all session that can actually move a batch.

### Two smaller confirmations from the same session

1. **The reroll/consumable gap is real, and the human named it.** §5d reverted the reroll feasibility
   gate on the *mechanism* that it damped rerolls earning value through CONSUMABLES, which `e_best`
   never prices. Asked why they rerolled, the user said: *"i wasnt looking for something specific
   just things like tarots and planets, maybe also some jokers like blueprint."* That is precisely
   the untracked term, and it independently vindicates reverting on mechanism rather than on the
   n.s. metric. The remaining fix is still the one named at `shop_advisor.lua:118` — add the
   consumable-refresh term to reroll value.
2. **Reroll cost mechanics are modelled correctly** — `content.lua:848` resets to base each shop and
   `REROLL_STEP` adds $1 within it, so the user's "spread rerolls across rounds because the price
   resets" is faithfully represented. `SA.REROLL_DISCOUNT` also already encodes "a fresh shop is free
   next round". No fidelity bug here.

### A real PERFORMANCE bug (live UX, not winrate)

The user noticed shop evaluation felt slower after buying Turtle Bean (+5 hand size). **Confirmed
headlessly** — decision cost is driven by hand size, not board size:

| hand size | ms/decision | vs 8 |
|---|---|---|
| 8 | 1269 | 1.0× |
| 12 | 1916 | 1.5× |
| 13 (Turtle Bean) | 2586 | **2.0×** |

It costs ~1.1s even with **zero jokers**, so the driver is the in-blind play search, not joker
valuation. This matches the `LONG DT` frame-stall spam in the live log. It is a live-usability
problem rather than a winrate one, and any fix must be a pure no-behaviour-change optimisation —
changing decision QUALITY mid-collection would make the human runs mutually incomparable.

### 5p-bis. Run 3 — a THIRD distinct winning archetype, and what the divergence data can/can't yet say

`4NN97569`, won at ante 9 on **Photograph · Hanging Chad · Astronomer · Constellation · Cavendish ·
Family** (6 slots — a negative edition supplied the extra). Final hand levels: **40**, against the
engine's sim median of 9 at ante 8. Three runs, three wins, three unrelated lines:

| run | archetype | final hand-lv |
|---|---|---|
| W9WKT1UE | retrigger (Chad ×2 / Photograph / Sock and Buskin) | 15 |
| GU73QPLY | xmult stack (Cavendish / Driver's License / Lucky Cat) | 32 |
| 4NN97569 | planet engine (Astronomer / Constellation / Cavendish) | **40** |

Run 2 opened on **$2 and one joker**; run 3 on $14 and one joker. Neither start predicted the win.
This is §5n's claim demonstrated rather than argued.

**Two uncovered jokers, both LEVELING engines, both on the highest-leveling boards.** `j_astronomer`
(Planets and Celestial Packs become free) and `j_burnt` (upgrades the first discarded hand each
round) have no `joker_effects` implementation. This does NOT contradict §5j's "84/84 scoring jokers
covered" — both are non-scoring, so they were correctly outside that audit. But the engine therefore
cannot value *making leveling free* or *generating a level per round*, and the two runs that finished
on 32 and 40 levels were built on exactly those. Individually each is ~5% of runs (below the
frequency ceiling, §5m); together they point at the **leveling channel** yet again.

**⚠ The divergence analysis is NOT yet usable — a logging-coverage artifact, not a finding.**
`ranked` capture only began partway through run 2, so a first pass showing "Astronomer, Constellation,
Family, Driver's License, Burnt: never priced" is mostly an artifact of those offers pre-dating the
instrumentation. `j_family`, `j_drivers_license` and `j_constellation` ARE covered and priced by the
engine; their absence means the log missed them, not that the engine is blind. Where coverage does
exist the engine **agrees** with the human on the classic scorers — Hanging Chad **19.89**,
Cavendish **16.79**, Sock and Buskin **13.07**, all recommended.

**Consequence for data collection:** runs 4+ carry full `ranked` + `blind_result` logging from the
first shop, so they are worth materially more per run than runs 1–3. The divergence question — *where
does a winning human take what the engine prices low?* — needs them.

---

## 5q. THE SURPLUS-DIG PROBE — and the metric problem it exposed

Built from §5p. `DE.DIG_SURPLUS` (off by default): once the clear is **guaranteed** and discards
remain, pitch chaff outside the clearing play instead of playing immediately. It fires in every
blind of every run — the only class the frequency ceiling says can move an n=160 verdict.

### Paired n=160, both arms regenerated with current code

| arm | progress | Δ vs base | sign (better/worse/tied) | wins |
|---|---|---|---|---|
| baseline | 3.759 | — | — | 2 |
| dig v1 (naive pitch) | 3.610 | **−0.150** (p 0.065) | 27 / 38 / 95 | 4 |
| dig v2 (chaff-first) | 3.604 | **−0.156** (p 0.067) | 27 / 37 / 96 | **5** |

sd ≈ 1.03–1.08, so the MDE at n=160 is **~0.23**: both results sit inside the noise band. Neither
is evidence of harm; neither is the positive evidence a policy change needs to ship.

**A diagnosis that was half right.** v1 lost money at *every* ante (−0.2 to −1.2), which pointed at
**held value**: a Gold card pays $3 at round end *if held*, Steel/Glass carry xmult while held, and
v1 pitched the first non-clearing cards in hand order, blind to all of it —
`DiscardValue.keep_value` already prices exactly this. v2 pitches chaff-first below
`DE.DIG_MAX_KEEP = 20`. **The money leak duly closed** (a5 −1.2 → −0.8, a6 −1.1 → **+0.3**) — **and
progress did not move at all** (−0.150 → −0.156). So the money leak was real, was fixed, and was
*not* what drove the progress delta. Recorded because it is a clean refutation of my own hypothesis.

### ⚠ The result that matters: PROGRESS DOWN, WINS UP — and the wins are STRICTLY NESTED

| arm | winning seeds |
|---|---|
| baseline | 144003, 14003 |
| dig v1 | 144003, 14003 **+ 125003, 51003** |
| dig v2 | 144003, 14003 **+ 125003, 51003, 127003** |

**The dig never lost a baseline win. It only added.** Paired: 3 discordant seeds, all favouring the
dig, none against — replicated across two independent implementations. Exact two-sided p ≈ 0.25, so
not significant alone; but the direction is unambiguous and the nesting is not what noise usually
looks like. Death-ante shifted 18 later / 26 earlier / 116 unchanged: slightly more runs die sooner,
and three more reach ante 8.

**This is a variance-increasing change, and that exposes a problem with the metric itself.**
`progress` (0–8, win = 8) was adopted because the sim had ~0 wins and a mean was the only usable
signal. But **a mean penalises variance, and winning Balatro is variance-seeking** — you do not win
by dying at ante 5 instead of 4, you win by reaching 8. Every verdict in this document was rendered
by a statistic that is systematically biased against exactly the kind of change most likely to
produce wins. That does not invalidate the earlier results (most were flat on both), but it means:

> **A change that lowers mean progress while raising wins is not obviously bad. It may be exactly
> right, and `progress` cannot see it.**

### ❌ VERDICT AT n=480: REFUTED. The dig is significantly harmful; the win signal was an artifact.

A fresh, out-of-sample 320-seed pool (`BES_SEED_OFF=7`) plus the original 160:

| pool | progress Δ | sign test | wins (base → dig) |
|---|---|---|---|
| n=160 (tuned pool) | −0.156 (p 0.067, n.s.) | 27/37, n.s. | 2 → **5** |
| **n=320 (fresh, out-of-sample)** | −0.086 (p 0.083) | 58/84, **p 0.036** | 10 → **9** |
| **n=480 pooled** | **−0.110, t −2.51, p 0.012** | 85/121, **p 0.015** | 12 → 14 |

**Significantly negative on two independent statistics.** `DE.DIG_SURPLUS` stays OFF.

**Two corrections to what I wrote at n=160, both of which I got wrong:**

1. **The "strictly nested wins" pattern did not replicate.** Out of sample it went 10 → 9, and
   pooled it is 12 → 14 — flat. Three discordant seeds at p≈0.25 was noise, and I leaned on it as
   promising. This is precisely the trap the #1 tuning rule exists to prevent, committed in a
   *different metric* than the one the rule names.
2. **The metric critique was therefore NOT demonstrated.** The general point stands on its own
   logic — a mean does penalise variance, and winning is variance-seeking — but I claimed this
   probe demonstrated it, and it did not. The dig never actually raised wins.

**Mechanism, checked rather than assumed.** The dig has real unmodelled joker interactions:
Delayed Gratification pays $2/discard only if you use NONE (the code charges the normal discard
path for this and my dig action bypassed it), and **Banner** gives +30 chips per REMAINING discard,
which the dig destroys. But measured over the 480 baseline runs these are all *below the frequency
ceiling and partly cancel*: Banner appears in **12 of 480 runs (2.5%)**, Delayed Gratification in
6.1% of snapshots — while **Mystic Summit (10%) is HELPED** by the dig (+15 mult at zero discards).
**So the implementation defects cannot explain −0.110.** The tactic itself is what lost.

### The open tension worth keeping

The human digs constantly and wins 5 of 6. The engine digs indiscriminately and measures −0.110.
The most likely resolution is not that digging is bad but that **the human's digging is PURPOSEFUL** —
they dig when there is a specific target (a tarot to apply, a build to feed, a gold-seal card to
retrigger for $15), whereas the probe dug whenever surplus existed. That is the committed-archetype
thesis once more: a surplus resource is only worth spending *in service of a plan*, and an engine
with no plan cannot spend it well. It also means the sim's inability to model "draw a card worth
applying a tarot to" is a live confound, not a settled question.

### Status: REFUTED as implemented — do not retry indiscriminate digging

`DE.DIG_SURPLUS` stays **off** and the flag is retained only so the experiment is reproducible.
A v3 correcting the Banner / Delayed-Gratification interactions is NOT worth running: those are
2.5% and 6.1% events and are offset by Mystic Summit at 10%, so they cannot move −0.110.

**Caveat kept in view:** the sim may understate what digging is *for*. The user digs for tarot
targets and Lucky-card money; Lucky and Gold are modelled, but "draw a card worth applying a tarot
to" is only partly represented. A null here is evidence about the sim's fidelity as much as about
the tactic.

---

# 5r. PROJECT STATUS — 2026-08-13 (supersedes all earlier status sections)

## The dataset changed everything: 8 expert human runs, 7 wins

`data/bes_runs_live_2026-08-12.jsonl` — red deck / white stake, overlay **hidden** (F9) so the
human played their own game while the engine's advice was logged beside it.

| # | seed | result | final board | hand-lv |
|---|---|---|---|---|
| 1 | W9WKT1UE | WIN a9 | Hanging Chad ×2 · Photograph · Blueprint · Sock and Buskin | 15 |
| 2 | GU73QPLY | WIN a9 | Cavendish · Driver's License · Burnt · Lucky Cat · Hanging Chad | 32 |
| 3 | 4NN97569 | WIN a9 | Photograph · Hanging Chad · Astronomer · Constellation · Cavendish · Family | 40 |
| 4 | U8UE74EN | WIN a9 | Ancient ×2 · Hack · Hanging Chad | 7 |
| 5 | X3L32ZEA | **DEATH a5** | Photograph · Gros Michel · Midas Mask · Rocket · Mime | 3 |
| 6 | IET2K8M7 | WIN a9 | Photograph · Hanging Chad · Cartomancer · Brainstorm · Wily · Throwback | 12 |
| 7 | 6W2JL21K | WIN a9 | Hanging Chad · Photograph · Bloodstone · Dusk · Sock and Buskin | — |
| 8 | 67HVNBZB | WIN a9 | Swashbuckler · Photograph · Hologram · Card Sharp · Sock and Buskin · Acrobat | — |

**7 wins in 8 runs (87.5%) against the engine's 1.25%** (12 wins in 960 sim runs). Seven distinct
winning archetypes. Winning hand-levels range from **7 to 40** — there is no single winning shape,
which is why "add the missing archetype" was always doomed (§5m measured exactly 0.000).

Telemetry now carries **1046 shop / 415 pack / 189 blind_select / 114 blind_result** records and
**928+ entries with the engine's own ranked valuations** beside the human's actual choice.

## What the human does that the engine does not (p-values from `tools/real_vs_sim.lua`)

| ante | dollars human / sim | hand-levels human / sim |
|---|---|---|
| 2 | **7.5 / 1.0** (p 0.009) | **0.0 / 0.5** (p<0.001) |
| 3 | **24.5 / 6.0** (p 0.001) | **0.5 / 1.45** (p 0.005) |
| 5 | **49.5 / 26.0** (p 0.003) | 4.5 / 2.0 (p 0.052) |
| 7 | 39.0 / 27.0 | **13.0 / 4.0** (p 0.001) |
| 8 | 52.0 / 27.8 | **15.0 / 4.5** (p 0.009) |

**The sequencing inverts, significantly, in both directions.** The human is 2–4× richer throughout
*and levels LESS than the engine early* (significantly less at antes 2–3), then crosses over at ante
4 and ends on 3–4× the levels. This is §5o's inferred pattern — economy and base first, power
second — now confirmed by a human at p<0.01 rather than inferred from sim survivors.

⚠ **This does NOT reopen §5m's world-fidelity verdict.** That compared *mixed-outcome* real runs to
*mixed-outcome* sim runs and found the world fair (median $1 at ante 2 in both). This table is
*near-all-wins* against mixed, so it measures **policy, not world**. Winners are richer; the world
is not.

**One joker appears in all seven wins: Hanging Chad** (retrigger). Photograph 5/7, Sock and
Buskin 3/7. Retriggers and conditional xmult, not raw tier.

## The loss is the most informative run

X3L32ZEA reached ante 5 holding **$52 — more than most of the wins had at that point** — on a
scattered board (Photograph/Gros Michel/Midas Mask/Rocket/Mime) with hand-levels stuck at 0 through
ante 4. The player's own account: *"despite having so much econ i couldnt find anything which
boosted my build or gave it direction."*

Resources were not the constraint; **conversion** was. Runs that opened on $2 and $14 with one joker
won. **This is the engine's own failure mode, executed once by a human** — and it is §5n's thesis
demonstrated rather than argued.

## Shipped this session

| fix | class | effect |
|---|---|---|
| Secret planets unlock on play; Black Hole levels 12 hands; 15 no-op spectrals implemented; `build_plan` all 12 hands (§5m) | correctness | −0.019 n.s. (136/160 seeds tied) |
| **OOM soft-lock**: `HandEval.HAND_BUDGET` bounds subset enumeration above hand size 8, + a GC step per evaluation | **bug — game-breaking** | hand-13 cost 2.0× → 1.27×; sim byte-identical at ≤8 |
| **The Fool** valued at its 0.30 prior with nothing to copy (`CV.fool_target`) | correctness | live advice only |
| Live telemetry: `blind_select`, `blind_result`, per-option `ranked` valuations | instrumentation | made the above findings possible |

## Refuted this session (do not retry)

| thread | verdict |
|---|---|
| Secret-hand archetype as a lever | **exactly 0.000** at n=160 (§5m) — capability ≠ intent |
| **Surplus dig** (spend discards once the clear is locked) | **−0.110, p 0.012 at n=480** (§5q). Banner/Delayed-Gratification/Mystic-Summit interactions are all below the frequency ceiling and partly cancel, so they cannot explain it |
| The "dig raises wins" signal | **artifact** — 2→5 at n=160 did not replicate (10→9 out of sample, 12→14 pooled) |

## What to do next — in order

1. **MINE THE DIVERGENCE SET.** The data is finally sufficient and untouched: 928+ records pairing
   the engine's measured value for every option against what a 7-of-8 human actually did. The
   question is *where does a winning human take what the engine prices low, and what happens next?*
   This needs no new runs and no new batches. **Do this first.**
2. **Conditional-value jokers (the Dusk report).** `j_dusk` retriggers only on the final hand, so it
   measures ~0 mid-blind and the engine repeatedly advised SELLING it — while it sat in a winning
   board. `Eval.scaling_projection` already discounts condition-locked scalers by trigger frequency;
   retrigger/conditional jokers get no equivalent. Correctness class, and the same shape as the two
   bugs the human caught.
3. **The commitment→valuation feedback** (§5o/§5q converge here). `BP.planet_credit` prices planets
   *by the commitment* and every leveling channel consumes it; deck-shaping and surplus-spending have
   no equivalent. Three independent threads now point at this: the secret-hand inertness, the
   indiscriminate-dig failure, and the human's purposeful digging. Co-calibrate with the planner
   constants — never as an isolated magnitude lever.

**Do NOT:** collect more human runs (the bottleneck is analysis, not data), probe resources (axis
exhausted, §5n), add archetypes (§5m), retry indiscriminate digging (§5q), or bump xmult weights
(§5o — winners are xmult-POOR early).
