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

> ⭐ **UPDATE (§6, 2026-08-14): there is a SECOND explanation for that graveyard, and it is not
> non-separability.** The same engine work measures ≈ −0.115 at baseline and **+0.730 (p=0.0018)**
> at +$10/round. The baseline engine holds **$1.3 at ante 2**, so a change to what it *prefers*
> cannot express itself — there is nothing to spend. Those reverts may have failed because the
> measurement point is degenerate, not (only) because their partners didn't move. Re-test the
> graveyard at an operating point where the constants can fire **before** reaching for a joint
> optimizer; that is far cheaper than Phase C and tests a different hypothesis.

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

---

## 5s. THE DIVERGENCE MINE — the engine and the winner disagree about what a PICK IS FOR

`tools/divergence.lua`, run on `data/bes_runs_live_2026-08-12.jsonl` (8 runs, 7 wins). This is
the analysis §5r listed as priority 1. It pairs the engine's own logged valuation of every option
against what the 87.5%-winrate human actually chose, and it lands one strong positive result, one
important NEGATIVE result, and a confirmation.

### Method, and the two things that nearly broke it

* **Values are comparable only WITHIN one ranked list.** An option's `value` is in "fraction of a
  boss hand" units, so it grows with the run — the same joker prices ~3 at ante 1 and ~300 at ante 7.
  A first pass compared values across evaluations and produced a mean gap of −416 against a median of
  1.37. Every comparison here is therefore made *inside* a single ranked list (rank, and value as a
  fraction of that list's best option); raw values are used only for their SIGN.
* **Tick-exact pairing does not work.** `scene.ranked` carries the PREVIOUS evaluation, a shop's
  ranking is often attached to a `pack` record, and a shop re-emits on every signature change. Runs
  are segmented into SHOP SESSIONS (records between two `blind_select` markers) and paired within.
* Excluded: 152 items that arrived via `other` (Judgement, skip tags, Hallucination…) — generated,
  not chosen. Excluded: STANDARD packs, where a playing card logs as `c_base`/`m_lucky` with no rank
  or suit, so it can never match the engine's card-name target (including them scored every such pick
  as a disagreement and biased the rate down, 37% → 41%).
* `c_heirophant` — the base game's own misspelling — is what the live log contains, 34 of 34. The
  engine already aliases both; the tool did not, and dropped real picks into `unknown`. **Third time
  this class of bug has surfaced; check it first in anything that keys on live data.**

### ❌ THE NEGATIVE RESULT: the joker valuation is NOT mis-ordered — stop looking there

7 of 8 runs won, so a joker still on the board at the end is part of a *winning* board. Cross-tabulating
the engine's rank of each joker at purchase against whether it survived:

| engine's rank of it | n | kept to the end |
|---|---|---|
| #1 (engine agreed) | 43 | **47%** |
| #2 | 16 | 31% |
| #3 | 4 | 0% |
| #4 or worse | 6 | 33% |
| (engine valued < 0) | 9 | 22% |

**The engine's rank order predicts which jokers a winning human keeps.** The hypothesis this mine was
built to test — "the engine under-prices the winning line" — is refuted for jokers. Relative joker
pricing is directionally right. **Do not re-tune it.** (Shop-buy agreement is 54%, n=85; the human
buys something the engine prices NEGATIVE 19% of the time, and those are the *least* kept, 22%.)

### ✅ THE POSITIVE RESULT: the pack-pick channel, and it is about FUNCTION not price

Pack picks are invisible to every valuation section above because `PICK` entries carry no `value` —
but the channel is FREE, used **~16× per run**, and fully ordinal. Agreement is the lowest anywhere:

**the human picked what the engine recommended in 53 of 129 picks (41%).**

Each disagreement is a PAIRED observation — same pack, same instant — so pack composition, board and
cash are controlled by construction, and the project's usual sign test applies directly:

| function of the card | human took | engine wanted | eng-only | hum-only | sign p |
|---|---|---|---|---|---|
| **enhance** (Bonus/Mult/Glass/Steel/Gold/Stone on 1–2 cards) | 4 (5%) | 27 (36%) | 25 | 2 | **0.00000** |
| **money** (Hermit, Temperance) | 15 (20%) | 1 (1%) | 1 | 15 | **0.0005** |
| **shape** (thinning + rank/suit convergence) | 22 (29%) | 9 (12%) | 6 | 19 | **0.0146** |
| level (planets, Black Hole) | 17 (22%) | 17 (22%) | **0** | **0** | 1.000 |
| generate | 7 | 10 | 10 | 7 | 0.63 |
| joker (editions/copies) | 4 | 5 | 5 | 4 | 1.00 |

n = 76 disagreements. Top individual cards: the human took Hanged Man ×11, Hermit ×10, Death ×6,
Temperance ×5; the engine wanted Hierophant ×7, Tower ×6, Empress ×5, Justice ×5.

**`level` is a perfect control: 0 discordant pairs.** Whenever either side picked a planet, so did the
other — they only differed on *which*. The disagreement is not about leveling, which is consistent
with the already-established finding that the sim uses MORE planets per run than the human (1.67 vs
1.05). It is about what the *rest* of the picks are for.

### What this says

The engine spends its free picks on **per-card enhancement** — the one class whose value a
per-decision measurement can see cleanly, because a Glass card's contribution is computable *today*
against the current deck. The human spends the same picks on **money** and **deck shape**, whose value
is entirely in what they enable LATER: cash compounds through interest into every future shop, and
thinning/convergence raises the probability of the hand the build is aiming at.

This is the **commitment→valuation feedback** gap (§5r item 3) with a measurement attached, and it
explains two previously unexplained results:

* the surplus dig measured −0.110 because it dug *indiscriminately* (§5q) — the human's shaping picks
  are a *target*, not a search;
* the human is 2–4× richer at every ante (p 0.009 at a2) — this is the **mechanism**: 20% of their
  contested picks are money cards, against the engine's 1%.

It also fits the project's own frequency rule: this is a 100%-of-runs channel (~16 picks/run), and
free-channel pack-pick valuation is where the biggest historical lever came from (+0.054).

### Confirmed, with a number: the Dusk bug

The engine issued **16 SELL_JOKER recommendations for Dusk in a single run**, while Dusk sat on that
run's winning final board. Same shape for Cartomancer (5) and Astronomer (3). `worst_i` picks the
lowest-measuring joker, and a joker that only fires on the final hand of a round measures ~0 mid-blind.
This is §5r item 2, now evidenced rather than reported.

### What to do next

1. **Price the `shape` and `money` functions by the COMMITMENT, not in isolation.** `BP.planet_credit`
   already does exactly this for planets, and planets are the one function where the engine and the
   winner agree exactly. That is the template, and its absence for deck-shaping and cash is the
   measured gap. Co-calibrate with the planner constants; never ship as an isolated magnitude lever.
2. **Conditional-value jokers** (the Dusk fix) — correctness class, ship on mechanism.
3. **Do NOT re-tune relative joker valuation** — the kept test says it is already directionally right.

### 5s-bis. VERDICT on the retrigger fix (paired n=160)

`BP.is_core` now includes retriggers, so `BP.keep_bias` protects them at `CORE_KEEP` in all four
sell/swap sites. Arms: `sim_out/retrig_base.jsonl` (HEAD, in a worktree) vs `sim_out/retrig_keep.jsonl`.

⚠ The obvious baseline `sim_out/dig_base_all.jsonl` was NOT usable: it was generated at 02:30 and the
Fool fix landed at 13:18, so pairing against it would have measured **retrigger + Fool combined** and
attributed all of it to the retrigger change. A fresh baseline arm was built from a worktree at HEAD.

| metric | baseline | candidate | Δ |
|---|---|---|---|
| progress | 3.782 | 3.793 | **+0.012** (t 0.28, p 0.78, n.s.) |
| sign test | — | — | 12 better / 6 worse / **142 TIED** (p 0.24, n.s.) |
| death-ante | 4.088 | 4.106 | +0.019 (7 later, 5 earlier, 148 unchanged) |
| wins | 3 | 4 | not a usable metric — inside its own Poisson error bar |

**MDE at n=160 with sd 0.520 is 0.115** — this batch could only have detected an effect ~10x the one
observed. The number proves nothing in either direction, and **142 of 160 seeds tied** is the frequency
ceiling behaving exactly as the rule predicts: six retrigger jokers, firing only when one is on a board
that is also facing a swap. Do not read the wins 3→4 or the a4→a6 jumps in the top-5 swings; with 18
seeds changed, both tails are cascade noise.

**✅ SHIPPED on mechanism, per the burden-of-proof rule** (correctness ships unless significantly
NEGATIVE; it is not). The justification is not the metric:
* a retrigger multiplies what the rest of the board does — the compounding role `is_core` exists for —
  but carries no handtype tag, so `BP.fit` gave it neither commitment credit nor penalty while a
  suit-matching flat common got `+COMMIT_JOKER_FILL`;
* the valuation layer ALREADY treats the class as under-measured (`jp_from_measure` and
  `joker_pick_frac` both floor a retrigger at 0.9x prior instead of 0.6x) — `keep_bias` was simply
  inconsistent with it;
* the live log has the engine advising **"Sell Dusk — frees a slot for Scary Face"** 16 times in one
  run, while Dusk sat on that run's WINNING final board;
* Hanging Chad appears in **7 of 7** human wins, Sock and Buskin in 3.
The live mod advises a HUMAN, and this was wrong advice the user actually saw.

**Diagnostic note for the next attempt:** the reason strings were decisive and the first hypothesis was
wrong. "Dusk measures ~0 mid-blind so it reads as dead" was FALSE — the retrigger floor already
prevents that. It was the UPGRADE-swap path. Read `advice.reason` before theorising about a mechanism.

---

## 5t. THE SHAPE CREDIT — ❌ REVERTED, and the diagnosis is worth more than the change

§5s located the gap as "committing changes exactly one number". The obvious fix — a
`BP.shape_credit` mirroring `planet_credit` — was built, screened, batched, and **reverted**.
What it uncovered on the way is the real result.

### Arm 1: the credit alone — INERT, and inert in a way a batch cannot diagnose

Paired n=160 vs `sim_out/retrig_keep.jsonl`: **progress −0.001 (t −0.71, p 0.48), 157 of 160
seeds TIED, death-ante unchanged on every seed, sd 0.019.**

That reads like "too subtle to detect". It was not. The screen (`tools/pick_order.lua`) said
**9.9% of packs change their pick**, and 9.9% cannot coexist with 157 tied seeds. Instrumenting
the real driver (now `tools/commit_firing.lua`) settled it:

| link in the chain | rate |
|---|---|
| a commitment is active when a consumable is priced | **25%** |
| ...that commitment is to **Full House** | **100%** |
| ...`DeckPlan.target` turns it into an actual DIRECTION | **0.3%** |
| `shape_credit` therefore fires | 0.3% |

**`DP.target` names ranks only when a rank beats the deck mean by 0.5.** A 52-card deck has four
of every rank against a mean of exactly 4.0, so `4 > 4.5` is never true. You needed a skew to earn
a target and a target to build a skew. Every direction-aware consumer — `card_quality`,
`removal_value`, discard ranking — has been running on a **targetless plan for essentially the
whole run**. (A second, smaller defect was mine: `on_target_frac` scored a full 52-card deck at
0.77 — "nearly done thinning" for the most bloated deck possible — silently blocking 64 more.)

### Arm 2: forcing the direction — NEGATIVE, and reverted on MECHANISM

Removing the skew gate so a committed rank hand always names its ranks unblocked the chain
exactly as intended (direction 0.3% → **23.7%**, matching the commitment rate; `shape_credit`
0.3% → **9.1%**, matching the screen's 9.9%). Paired n=160:

**progress −0.054 (t −1.77, p 0.076), sign 2 better / 8 worse / 150 tied, wins 4 → 3.**

MDE at sd 0.386 is 0.085, so this is formally n.s. — but it is reverted on MECHANISM, not on the
p-value, and the mechanism is the one the original code comment already named:

> *"A fresh 52-card deck ties at four of every rank; arbitrarily declaring Aces there would be
> fake commitment."*

That comment was right. With four of each rank, the tie-break names Aces and Kings, and
`card_quality` then charges **44 of 52 cards −3 as "off-target"** — reordering every discard and
removal decision toward a concentration the run has no jokers or levels supporting. The tails
agree: of 10 changed seeds the three largest movers are **a8→a5 (−3.07), a8→a5 (−3.04), and a
WIN destroyed (a9→a6, −2.16)**.

### What this actually establishes

1. **The commitment layer is nearly inert as a DIRECTION source, and that is now measured.**
   The planner commits, then has nowhere to aim. `planet_credit` works precisely because it needs
   no direction — only the hand's identity.
2. **The engine commits to Full House in 100% of observed valuations** (3 and 6 seed runs both).
   Against eight human runs producing seven distinct winning archetypes, that is its own finding
   and is untouched by this session.
3. **A direction must be EARNED, not declared.** Forcing one from a tie-break is fake commitment
   and measurably destroys runs. A legitimate source would be owned-joker suit/rank tags, real
   accumulated skew, or the hand the player is actually making — not the sort order.
4. **Screen firing rate before batching.** `tools/commit_firing.lua` exists for this. A 45-minute
   arm cannot tell "small effect" from "not executing"; a 2-minute instrumented run can.

### Status

`BP.shape_credit`, `DP.on_target_frac` and the `DP.target` gate change are all **reverted**;
`tools/pick_order.lua` and `tools/commit_firing.lua` are kept. The next lever is **not** pricing
shape — it is giving the commitment a direction it has actually earned, and the Full House
monoculture is probably the thing to look at first.

---

## 5u. WHY LOGICAL FIXES KEEP NOT WORKING — it is a SCALE mismatch, and it is arithmetic

Prompted by the user (2026-08-13): *"it just seems very strange that after so many attempts at
improvements which are logical it is not improving anything. should this be looked at differently?"*

Pooled over n=984 completed sim runs (`dig_base_all` + `of_engine_tuned` + `retrig_keep`):

| quantity | value |
|---|---|
| mean progress | **3.742** |
| sd (per run) | **1.720** |
| a WIN (progress 8.0) sits at | **+2.47 standard deviations** |
| observed winrate | 21 / 984 = **2.1%** |
| **every lever ever shipped, summed** | **+0.487 = 0.28 sd** |

**The project has accumulated 0.28 sd of improvement against a 2.47 sd gap** — about one ninth of
what a coin-flip winrate needs, after the entire tuning history. The modal run dies in ante 4
(28.2% of runs); only 4.1% ever reach progress 7.

That is the answer to the question. The individual fixes are not wrong and are not unlucky —
they are **the wrong SIZE by one to two orders of magnitude**, and no quantity of them sums to
the gap. A typical retained lever is +0.02 (0.012 sd); ~200 of them would be needed.

### The measurement apparatus is calibrated to an irrelevant range

Paired n=160 gives MDE ≈ 0.085–0.27 depending on cascade. Levers produce 0.01–0.07. So:

* a change big enough to matter (+2.0) would be unmistakable and needs no batch;
* a change the batch can certify (+0.1) is ~5% of the way to mattering;
* everything actually produced falls BELOW the detection floor.

Three sessions of 45-minute arms have certified nothing, and cannot. Meanwhile `wins` — the real
objective — has Poisson sd ≈ 3.5 at 12/480, so distinguishing 2% from 4% needs n ≈ 1500+.
**The project optimises a proxy it can measure for an objective it cannot, and the two come apart
exactly in the tail where wins live.**

### What is NOT the explanation (all checked, this session)

* **Not a hidden tail effect the mean metric misses.** Both reverted changes were re-scored on
  reach-5+/6+/7+: shape_dir −2/−3/−3, surplus dig −8/−6/−4. They were genuinely worse, not
  tail-positive. The metric was not hiding value.
* **Not joker mispricing.** The engine's rank order predicts which jokers a winning human keeps
  (§5s: rank #1 → 47% kept, #2 → 31%, #3 → 0%).
* **Not in-blind play** (regret 0.0076), **not resources** (§5n), **not archetype coverage** (§5m),
  **not the world** (§5m).
* **Not the near-miss cohort.** Runs reaching ~ante 7 and dying look like winners at ante 6
  (hand-lv 4.61 vs 5.75, njokers 5.28 vs 5.56, $30 vs $34). At the top of the distribution the
  difference is variance, not a saveable decision — confirming the earlier a3–5 counterfactual.

### What follows

A 2.47 sd shift is not a tuning result; it is a **policy-class** result. The greedy evaluator is
good at what it does — a scripted tier list is −0.987 against it, in-blind play is near-optimal,
and its joker ordering matches a winning human's retention. What is absent is a layer ABOVE it
that chooses an END-STATE and steers toward it. Every fix this project has tried, including both
of this session's, has been "make the greedy valuation slightly less greedy" (credits, floors,
keep-biases). That family is exhausted, and now demonstrably so by arithmetic rather than by
another null result.

**Three candidate directions, in order of how well their size matches the gap:**

1. **Search / lookahead over the shop stream** (the deferred MCTS, or a cheaper beam over "which
   reachable ante-8 board does this run support"). The evaluator becomes the LEAF evaluation of a
   search instead of the decision rule. This is the only class whose plausible effect size is
   measured in whole antes.
2. **Imitation from the human dataset.** `data/bes_runs_live_2026-08-12.jsonl` now contains ~928
   decisions labelled by an 87.5%-winrate policy. That is a supervised target, not a constant to
   hand-tune — a categorically different way of setting the policy.
3. **A P(win) objective** replacing per-decision EV, so the engine takes variance when behind and
   safety when ahead. Note the naive version was already refuted (Δprogress vs Δwins correlates
   +0.58), so this is only worth doing as part of (1).

**And change the verdict protocol:** stop certifying single levers at n=160. Only bundles or
whole-policy swaps are large enough to be measurable, and `luajit tools/commit_firing.lua` should
gate any change before an arm is spent on it.

---

## 5v. THE ORACLE-PLAN PROBE — knowing WHAT TO BUILD is worth nothing (41/40)

§5u ranked search/lookahead as the direction whose size matches the gap. Before building it,
this tests its premise: search is an expensive way to produce a better PLAN, so what is a better
plan worth? The probe series had measured resources (money, slots, levels) but never this.

`BES_PROBE=oracle_plan` (`sim/probe.lua`) replaces the planner's commitment, every shop, with the
hand the deck ACTUALLY makes most often weighted by its leveling gain — knowledge a human gets free
by looking at their deck and the planner never uses (it derives commitments from joker tags and
sunk levels only). Everything downstream then steers toward a real archetype: `planet_credit`,
`BP.fit`, `keep_bias`, `DeckPlan.target`. Verified before spending the arm: the oracle produces
Pair 12 / Straight 6 / Three of a Kind 5 / Two Pair 4, against the baseline's **Full House 100%**.
It samples from a DERIVED rng stream so it cannot consume `run.rng` and change which shops appear —
otherwise it would confound "a better plan" with "a different offer stream".

### Result: paired n=160 vs `retrig_keep`

| metric | baseline | oracle | Δ |
|---|---|---|---|
| progress | 3.793 | 3.722 | −0.071 (t −0.88, p 0.38) |
| **sign test** | — | — | **41 better / 40 worse / 79 tied** |
| reach 6+ | 14 | 10 | −4 |
| wins | 4 | 2 | −2 |
| seeds changed | — | **81 of 160**, mean \|Δ\| **1.05** | sd 1.028 |

**This is not an underpowered null.** The probe is enormous — it changes half the seeds by a whole
ante on average — and the outcome is 41 up, 40 down. That is the project's documented CHURN
signature (high variance, balanced sign, flat mean) in its purest form yet.

### ❌ Handing the engine a perfect archetype target is worth NOTHING

Which retires the direction §5u had ranked first. Search over the shop stream is an expensive
machine for choosing what to build, and choosing what to build has now been measured at zero.
**Do not build the planner/lookahead to fix archetype selection.**

Caveat, stated precisely: this refutes one strong notion of "the right plan" — commit to the hand
your deck makes best. It does not refute a plan that knows the FUTURE OFFER STREAM. But
deck-frequency commitment is exactly what the project's own governing frame described ("a strong
player notices which of several viable lines *this* run offers and COMMITS"), and it is free here.

### Where that leaves the axes — every internal one is now probed

| axis | probe | verdict |
|---|---|---|
| resources | `rich` +$100/rd | **binding** (+3.09, 72.5%) but unreachable endogenously |
| valuation quality | `expert` tier list | −0.987 — the measured valuation EARNS ITS KEEP |
| **what to build** | **`oracle_plan`** | **41/40 — worth nothing** |
| in-blind play | replay harness | near-optimal (regret 0.0076) |
| archetype coverage | §5m | exactly 0.000 |
| world fidelity | §5m, `real_vs_sim` | fair; deck/stake confirmed matching (white stake, red deck, 4 hands, 4 discards) |

Every axis internal to decision quality has now been probed and found NOT binding, while the one
that is binding (resources) is bounded at ~$80/run of reallocatable spend ≈ +0.4 progress — against
a 2.47 sd (+4.26) gap. **The engine is close to the ceiling of its own architecture, and that
ceiling is far below a win.** That is a coherent picture, and an uncomfortable one: it means the
remaining explanations are (a) the winning policy differs in something none of these axes captures,
or (b) the sim is harder than the real game in a way `real_vs_sim` did not catch — noting that
validation compared the sim to MIXED real runs which were themselves not expert play.

**Next, and it should be (b) first because it is cheap and everything else is conditioned on it:**
compare the 8 expert runs' in-blind SCORE-vs-TARGET ratios against sim runs at the same ante and
board size. If the same-sized board clears by 10x in the real game and 1.2x in the sim, the scoring
model under-delivers and every verdict above is measured in the wrong world.

---

## 5w. THE SKIP PROBES — and the pattern across FOUR large interventions

The user's own account (2026-08-13): *"i was skipping to save time cause i know i had a winning
build — skipping is typically the wrong option."* The data agrees. Across the winning runs with
complete `blind_result` telemetry the human plays **3.0 / 3.0 / 3.0** blinds through ante 3 and
only drops off from ante 6 (the speedrun artifact, excluded). The engine skips **2.16 blinds/run**
at a **27–30% skip rate through antes 2–4** — exactly the window the human never skips — always to
chase a tag (*"Investment tag (~$25) beats playing (~$12)"*).

⚠ **Telemetry caveat:** `blind_result` was added DURING the capture. `W9WKT1UE` has **zero** such
records and `GU73QPLY` only 5. Any per-blind human statistic must be restricted to the five runs
with real coverage or it is diluted by missing data (a first pass reported 14.25 blinds/run this way).

### Results (paired n=160 vs `retrig_keep`)

| probe | progress Δ | sign test | wins | sd |
|---|---|---|---|---|
| `noskip` (never skip) | −0.166 (p 0.28) | **68 / 67 / 25** | 4 → 4 | 1.936 |
| `noskip_early` (play all through a4) | −0.107 (p 0.48) | **71 / 61 / 28** | 4 → 5 | 1.935 |

### The mechanism did NOT fire, and why is the finding

| | baseline | noskip |
|---|---|---|
| shops / run | 18.83 | **21.74** ✓ |
| blinds played / run | 9.89 | **11.63** ✓ |
| median $ at ante 5 / 6 | 26.0 / 26.0 | **26.0 / 26.3** ✗ |
| `hand_level_sum` at a6 / a8 | 3.0 / 6.0 | **1.5 / 2.0** ✗✗ |

1. **The engine is interest-CAP-bound, not money-starved.** It sits at $26 from ante 5, so extra
   blind rewards overflow the cap and earn nothing. "Play more blinds → more money" cannot fire.
2. **Skipping was BUYING LEVELS.** Tags (Orbital especially) are a leveling channel; forcing PLAY
   forfeits the tag stream and hand levels roughly halve from ante 5. The skip pays for itself in
   a currency the hypothesis did not account for. A genuine trade, not a null.

### 💀 THE ENGINE DIES HOLDING THE INTEREST CAP

| death ante | n | median $ held |
|---|---|---|
| 4 | 46 | $15 |
| **5** | **27** | **$26** |
| **6** | **17** | **$26** |
| **7** | **7** | **$27** |

**28% of all deaths hold ≥$25.** From ante 5 the engine banks the cap and dies on it. But
`levelbuy` (force it to spend that money on levels) measured **−0.229**, so this is NOT a spending-
policy failure: **$26 does not buy anything that saves the run**, while `rich`'s $100/round wins
72.5%. The available money is below the threshold at which money converts into a build. This is
the human's own loss run in miniature ($52 at ante 5, "couldn't find anything which gave it
direction").

### The pattern across four large probes — this is the real result

| probe | what it changed | sign test | sd |
|---|---|---|---|
| `oracle_plan` | a perfect archetype target | 41 / 40 | 1.03 |
| `noskip` | never skip a blind | 68 / 67 | 1.94 |
| `noskip_early` | play everything to a4 | 71 / 61 | 1.94 |
| `shape_dir` | commitment-priced deck shaping | 2 / 8 | 0.39 |

**Three of four are dead-even coin flips with ENORMOUS per-seed variance.** These are not small
interventions: `noskip` changes 135 of 160 seeds and moves the average one by ~1.9 antes. Large
behavioural changes RE-ROLL the outcome without changing its expectation. Meanwhile the only
intervention that ever moved the mean was `rich` (+3.09) — a resource, not a decision.

**Read together with §5u: decisions are not the binding constraint at this engine's level; income
is, and the income available (~$26 held, ~$80/run flow) is below the conversion threshold.** Any
further single-axis decision probe is predicted to come back ~50/50, and three did in one session.
Stop running them.

---

## 5x. THE ECONOMY MODEL — additive and probability-blind. Fixed; measured INERT (159/160 tied)

Chasing §5w's "income is the binding constraint", the two money engines the human named in their own
run notes were both **multiplicative** — run 6 *"gold seal 3 of clubs paired with hanging chad copied
by brainstorm"*, run 8 *"oops all 6s synergising into reserved parking farming then business card"* —
and `Eval.econ_power` is a **plain SUM** of static `JokerData.econ` values with three exceptions.

Three defects, all real:

1. **`j_oops` had `econ = 0, cat = "utility"`** — it contributed nothing and, worse, *multiplied*
   nothing, though in-game it doubles every listed probability.
2. **`j_reserved_parking` was a flat `econ = 3`** — no deck-awareness, though it pays per FACE card.
3. **`jp_to_fv` read `JokerData.resolve(key).econ` directly**, bypassing `Eval.econ_value` entirely —
   so the deck-aware econ model that already existed (Rough Gem, Business Card, Cloud 9) had **never
   once reached the buy/sell decision**, only the spending-headroom calc. A Rough Gem was priced
   identically on a 4-diamond and a 20-diamond deck.

Fixed: `CONDITIONAL_ECON.j_reserved_parking` scales by face density; a `PROB_ECON` set doubles
probability-gated **money** jokers under Oops (money-positive only — Oops also doubles Gros Michel's
*extinction* roll, which must not be credited); `jp_to_fv` now calls `Eval.econ_value`.

**Result (paired n=160 vs `retrig_keep`): Δ −0.002, p 0.317, sign 0 better / 1 worse, 159 TIED.**

Predicted inert before running (Oops appears in 2.0% of runs, Oops + another probability joker in
**0.0%**), but the measured inertness is stronger than the frequency argument, and the reason is
mechanical: `clampf((face/n)/(12/52), …)` is **exactly 1.0 on an unmodified 52-card deck**. The
deck-aware answer *equals* the flat prior until the deck actually diverges — which is correct, and
is why it can never show up in a sim whose decks stay near-standard. **Shipped on the correctness
rule** (provably wrong code, not significantly negative). Its justification is the live overlay,
which advises a human who built exactly these engines — not winrate.

⚠ Note the 159/160 tie doubles as *proof of non-contamination*: §5y's edits were made while this
batch ran, and a 2× repricing of money would have cascaded every seed, not tied them.

---

## 5y. THE CURRENCY INCOHERENCE — the engine bought dollars at half the price it sold them

> ## ❌ CORRECTION (2026-08-14): THIS IS NOT A NEW FINDING. IT IS **B3**, ALREADY TRIED AND REVERTED.
> `WINRATE_AUDIT.md`, **2026-07-06 — Phase 2 item 6: "B3 unify the $↔fraction rate"** identifies the
> *same* bug (`dollar_frac` 0.03 vs the shop's `0.3/5 = 0.06`), applies the *same* fix
> (`BASE_FRAC 0.03 → 0.06 (= COST_WEIGHT/JOKER_SCORE_WEIGHT)`, clamps doubled), and notes the *same*
> `tags.lua` side effect (tags ~2× over-valued, worsening with ante). It measured **−0.245** at
> paired n=80 and was **REVERTED**. This section was written without finding that entry, and
> presented the bug as newly discovered. It was not.
>
> The measurements agree: B3 −0.245 (n=80), this session −0.125 (n=154). Two consistent negatives.
>
> **And B3 was reverted on a MECHANISM, not a null** — which under this project's own rule is a
> legitimate revert: *"`SK.SHOP_VALUE`, the 1.25 skip margin, keep_bias and the consumable-money
> terms were all calibrated AGAINST the old 0.03 rate; doubling the rate alone mis-calibrates every
> one of them at once."* This session independently rediscovered that same mechanism (see the market
> check below, which flags exactly the `tags.lua` inverse and the `SK.SHOP_VALUE` co-calibration) —
> and then shipped anyway on the correctness rule. **That was the wrong call under the project's own
> standard.**
>
> ⚠ **Lesson, and it is the second of its kind this session:** SEARCH THE AUDIT before claiming a
> finding. The wrong-planet-number correction in §5z came from re-deriving a recorded measurement;
> this one came from *not* reading a recorded one. Both cost real work.
>
> **Status: under re-test, not settled.** §6 shows baseline verdicts on valuation changes are
> uninformative, and BOTH B3 measurements were taken at baseline. An isolation arm
> (`sim_out/rich_nobridge.jsonl`: current HEAD with `BASE_FRAC` alone reverted to 0.03, run at
> `rich10`) is measuring the single-constant effect at an operating point where it can express.
> **If it is negative there, revert the constant** — the B3 mechanism was right and two negatives
> plus a mechanism is decisive. If positive, this is a genuine graveyard resurrection.

**This is not a lever. It is a unit error**, and it is the first thing found that is *about income*
(§5u/§5w's binding constraint) and is a *bug* rather than a weight.

### The finding

The engine mixes three currencies (`engine/value_units.lua` header): boss-hand **fractions**,
**dollars**, and **FV points**. Two independent modules each owned a $→power rate, and they were
never reconciled:

| module | currency it ranks in | price of $1 gained |
|---|---|---|
| `shop_advisor` | "utility" (1 frac = `JOKER_SCORE_WEIGHT` = 5) | `DOLLAR_UTIL` = **0.30** → **0.060 frac** |
| `pack_open_advisor`, `packs`, `consumable_value` | boss-hand **fractions** | `VU.dollar_frac` = **0.0185–0.0399** |

| ante | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| `dollar_frac` | .0399 | .0344 | .0300 | .0261 | .0232 | .0212 | .0195 | .0185 |
| shop rate | .060 | .060 | .060 | .060 | .060 | .060 | .060 | .060 |
| **shop / pack** | **1.5×** | 1.7× | 2.0× | 2.3× | 2.6× | 2.8× | 3.1× | **3.2×** |

### It is provably the SAME card

`CV.card_value(gs, "Tarot", "c_hermit")` returns one tuple — `(vfrac = 0, gain = $g)` — and both
consumers read it:

* `shop_advisor.lua:682` — `value = w_score*5*(vfrac+sbonus) + (gain - cost) * DOLLAR_UTIL` → **0.30·g**
* `pack_open_advisor.lua:127` — `vfrac + VU.dollars_to_frac(gs, gain)` → ×5 into utility = **0.15·g**

A Hermit paying $20 was worth **6.0 utility in the shop and 3.0 inside an Arcana pack**. The engine
bought dollars at half the price it charged itself to spend them — and it did so *only in the pack
channel*. `shop_advisor` never required `value_units` at all, which is how the two drifted.

### Which side is wrong — decided, not guessed

The **pack** side. Its own header says so: BASE_FRAC 0.03 was inherited verbatim from the
pre-refactor "hardcoded DOLLAR_FRAC = 0.03 duplicated in packs.lua and consumable_value.lua". The
centralisation made the rate **ante-aware** but never re-derived its **magnitude**. The shop rate is
load-bearing across buy / sell / reroll / econ-floor / SELL_TO_BUY — all tuned around it, and the
one the §5s kept-test validated as directionally right.

So `BASE_FRAC` is now **derived, not chosen**: `VU.DOLLAR_UTIL / VU.FRAC_UTIL` = 0.3/5 = **0.06**.
Both bridge constants moved *into* `value_units` and `shop_advisor` reads them from there;
`COST_WEIGHT` too (a no-op today — it was already 0.3 — so a future tune cannot desync the price of
a dollar spent from a dollar gained *inside the shop itself*). The clamps keep their original width
relative to the base (0.5× .. 1.67×), so they stay non-binding exactly as before.

Pinned by an invariant test (`tests/test_value_units.lua`): *"$20 of Hermit is worth the same in a
pack as in the shop."* It fails on the old constant (3.0 vs 6.0).

### Why this is the channel that was measured as broken

§5s mined 8 expert human runs and found the pack-pick channel is where engine and winner disagree
most — and the **money** function is the most lopsided single row in it: **human 20% vs engine 1%,
discordant 1/15, p 0.0005.** That is precisely the channel this bug suppresses, and *only* that
channel: money offered in the shop was priced correctly all along.

### A market check (supporting, and it cuts both ways)

`engine/tags.lua` uses the **inverse** (`frac_to_dollars`) to price skip tags, so the fix HALVES the
dollar value of joker/orbital/pack tags. Sanity-checking against what the shop actually charges:

| | measured frac | $ @ old 0.03 | $ @ new 0.06 | actual shop price |
|---|---|---|---|---|
| Common joker | 0.75 | **$25.0** | $12.5 | **$4.30** |
| Uncommon | 1.15 | $38.3 | $19.2 | $6.20 |
| Rare | 1.50 | **$50.0** | $25.0 | **$8.20** |

The old rate valued a free Common skip-tag joker at **six times** what the shop sells the identical
joker for. The new rate is materially closer to the market. It is still above it — partly legitimate
(consumer surplus: you buy because value > price) and partly a *separate* defect worth recording:
`Packs.expected_joker_of_rarity` floors each sample at `0.6 × tier prior`, and from ante 3 that floor
BINDS on every sample, so the value goes flat (0.750 at ante 3 **and** ante 5) while `need` keeps
growing — after `frac_to_dollars` the dollar value then *rises* with ante ($25 → $32). Not fixed
here; noted. This also means the skip channel is co-calibrated with `SK.SHOP_VALUE`, so watch the
skip mix in the verdict.

### Frequency class — the reason this one is worth batching at all

Per the §5-frequency-ceiling rule, only the "every shop of every run" class can move an n=160
verdict. This qualifies: it repriced money inside **every pack EV** (`packs.lua`, so every BUY_PACK
decision in every shop), **every pack pick** (~16/run), **every gold / lucky / gold-seal card**
(`consumable_value`), and **every money tarot**. Contrast the same session's econ-model fix, which is
correctness but sits at Oops 2.0% / broad 27.6% and is predicted inert.

---

### VERDICT on the bridge fix (paired n=154 vs `econ_fix`) — UNRESOLVABLE, kept on the rule

| | |
|---|---|
| progress Δ | **−0.125** (t = −0.84, p 0.40, n.s.) |
| sign test | 56 better / 53 worse / 45 tied (p 0.85) |
| death-ante | 38 later / 38 earlier / 78 unchanged |
| **sd** | **1.859** |
| **MDE at n=154** | **0.42** |

The measurement cannot resolve an effect a third the size of its own detection floor, which is
exactly what CLAUDE.md's power table predicts for a broad re-weight (sd ~1.2 → MDE ~0.27; this
cascaded harder still). **Kept**, per the replacement rule: it is a correctness-class change (the
same card provably priced differently in two modules), it is not significantly negative, and no
mechanism says it is wrong. Reverting a provable unit error on a p=0.40 reading would be
optimising the measurement, not the game.

⚠ Note the signature: **the fifth large intervention in a row that re-rolls without moving the
mean** — oracle_plan 41/40, noskip 68/67, noskip_early 71/61, shape_dir 2/8, bridge 56/53.

### The reachability envelope — and why the churn is NOT hidden upside (`tools/envelope.lua`)

Every A/B batch on the shared 160-seed pool is an independent EXPRESSIBLE POLICY over the SAME
seeds, so the per-seed MAX across them lower-bounds "was a winning line reachable?". Over 7
variants (retrig_keep, retrig_base, shape_credit, shape_dir, pb_noskip, pb_noskip4, econ_fix):

| | progress | wins | reach 6+ | reach 7+ |
|---|---|---|---|---|
| best single arm | 3.793 | 5 (3.1%) | 31 | 14 |
| **envelope (per-seed max)** | **4.483** | **11 (6.9%)** | 50 | 28 |
| floor (per-seed min) | 3.020 | — | — | — |

A 2.2× win "lift" looks like a hidden reachable line — **it is not.** envelope − best = **+0.690**
while best − floor = **+0.773**: near-symmetric dispersion about the mean is the signature of
NOISE, not of reachability (a genuinely reachable line raises the max without lowering the floor
equally). **85% of seeds change outcome under tiny policy perturbations.** The sim is deterministic,
so this is not measurement error — it is chaotic sensitivity to policy through the seeded RNG
cascade. This is the quantitative form of §5w's finding and the reason broad levers cannot be
measured at n=160. Do not read max-over-k as an oracle.

---

## 5z. THE PACK-THROUGHPUT GAP — the largest measured behavioural divergence in the project

Everything below is measured from `sim_out/econ_fix.jsonl` (n=160, current HEAD) against
`data/bes_runs_live_2026-08-12.jsonl` (8 human runs, 7 wins). No new simulation was needed.

### ⚠ FIRST: a recorded number that is WRONG, and it redirected the project

CLAUDE.md and §5m state *"the sim uses MORE planets/run than the human (1.67 vs 1.05)"*, and that
is the premise that produced the **"audit the FACTS layer, it is an expressibility artifact"**
conclusion — which led to the secret-hand / Black Hole / spectral work that measured **exactly
0.000**. Re-measured on the complete dataset, counting `consumable_use` records whose key is in
`CV.PLANET_KEY_HAND` (the live records carry `key`, not `set` — reading `set` returns nil, which is
the likely origin of the error):

| | planets used / run | / ante |
|---|---|---|
| ENGINE (n=160) | **1.77** | 0.43 |
| HUMAN (n=8) | **8.38** | 0.99 |

**4.7× per run, 2.3× per ante — the opposite sign to the recorded figure.** The leveling gap was
policy after all. Treat §5m's "inexpressible-world artifact" framing as unproven.

### The gap itself

| | packs opened / ante |
|---|---|
| ENGINE | **1.36** |
| HUMAN | **6.10** |

And within the human's own 8 runs, pack throughput separates the outcomes **with no overlap**:

| run | 4NN97569 | W9WKT1UE | 6W2JL21K | 67HVNBZB | GU73QPLY | U8UE74EN | IET2K8M7 | **X3L32ZEA** |
|---|---|---|---|---|---|---|---|---|
| packs/ante | 7.33 | 7.44 | 6.89 | 6.44 | 6.22 | 5.89 | 4.33 | **2.80** |
| Celestial packs | 24 | 7 | 14 | 14 | 15 | 13 | 6 | **2** |
| outcome | WIN | WIN | WIN | WIN | WIN | WIN | WIN | **LOSS** |

The loss opened **zero packs at antes 2 AND 3**. It is the run the player described as *"despite
having so much econ i couldnt find anything which boosted my build or gave it direction."* The
engine, at 1.36/ante, sits at **half the human's LOSING run and a fifth of their wins**.

### It is a valuation choice, not poverty

| | count | rate |
|---|---|---|
| shops with a pack offered | 2917 | — |
| ...**affordable** | 2410 | — |
| ...**bought** | 571 | **23.7%** |
| affordable packs DECLINED that the engine itself rated POSITIVE | **1337** | 39.3% of declines |

What it does instead of a positive, affordable pack: BUY_JOKER 38.7%, **REROLL 24.9%**,
BUY_VOUCHER 11.8%, SELL_JOKER 11.6%, BUY_CONSUMABLE 10.3%.

By type — it is worst exactly where the human is heaviest:

| type | affordable | buy rate | mean value | % rated positive |
|---|---|---|---|---|
| Buffoon | 344 | 45.1% | +5.97 | 85% |
| Arcana | 1133 | 22.8% | +1.61 | 69% |
| **Celestial** | 1487 | **6.3%** | **−0.79** | 37% |
| **Standard** | 1290 | **6.8%** | **−1.35** | 34% |

Celestial mean value **by ante**: +1.57, **−2.16, −1.93, −0.84**, −0.22, −0.16, −0.03, +0.65. It is
negative through the whole a2–a6 window and only recovers at a8. Against the hand-level
trajectories:

| ante | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|
| ENGINE hand-lv | 0.4 | 1.3 | 1.8 | 2.5 | 2.8 | 5.2 | 7.7 |
| HUMAN hand-lv | 0.0 | 0.5 | **2.8** | **5.8** | **10.6** | **14.6** | **18.6** |

The human levels LESS at a2–a3 (confirming the recorded crossover) and ramps from a4 — precisely
the window where the engine still prices a Celestial pack negative. (Engine a7/a8 figures are from
15 and 7 survivors, so survivorship inflates them; the true gap is wider.)

### ⭐ THE PAIRED, SAME-STATE CONFIRMATION — the engine says SAVE while a winner buys

Everything above compares AGGREGATES across two different worlds. This does not. The live mod
logged its own recommendation beside the human's action **with the overlay hidden (F9)**, so the
human's choice was independent of the advice. Aligning each pack the human opened to the engine's
recommendation at that moment (non-shop advice states and tag/post-blind packs excluded):

**n = 244 genuine shop decisions in the games of a player who won 7 of 8.**

| the engine's recommendation | n | share |
|---|---|---|
| **AGREED — BUY_PACK** | 33 | **13.5%** |
| **DISAGREED** | 211 | **86.5%** |

| what it wanted instead | n | % of disagreements |
|---|---|---|
| **SAVE** (hold the cash) | 101 | **47.9%** |
| **REROLL** | 63 | **29.9%** |
| BUY_JOKER | 24 | 11.4% |
| BUY_VOUCHER | 14 | 6.6% |
| BUY_CONSUMABLE | 7 | 3.3% |
| SELL_JOKER | 2 | 0.9% |

**On 78% of the decisions where a winner bought a pack, the engine says "save your money" or
"reroll".** Agreement by ante: a1 0%, a2 18%, a3 11%, **a4 4%**, a5 26%, a6 24%, a7 12%, a8 0% —
the minimum is at **ante 4**, precisely where the human's hand-levels cross the engine's and begin
to ramp.

**This closes the loop with §5w's death data.** The engine's single most common alternative to a
pack is SAVE — and **28% of its deaths hold ≥$25**, dying on the interest cap. §5w read that as
*"$26 does not buy anything that saves the run"*. The paired data says the opposite: **$26 buys
five packs, and the player who bought them won 7 of 8.** The `hoard` probes showed forcing MORE
saving is catastrophic (−0.396/−1.194/−1.639); this shows the engine is already running a milder
version of that policy relative to the winner — invisible until the comparison was made on paired
states rather than on aggregates.

⚠ Alignment is approximate (the most recent `shop` record; §5s notes `scene.ranked` can carry the
previous evaluation), and "what the winner did" is a proxy for "what wins", not proof of
per-decision optimality. But 13.5% vs a human at ~100% is far outside any alignment noise.

### The MECHANISM behind the SAVE preference, quantified — and it is ante-1..3 only

`BUY_PACK` is scored `w_score*5*(pv*need + sbonus) - net_cost(cost) - econ_floor_penalty(gs, cost)`.
The floor penalty charges `ECON_FLOOR_RATE` (0.5) per dollar a spend pushes below `ECON_FLOOR`
($10). Recomputing it analytically over all 4470 AFFORDABLE pack offers in the n=160 baseline:

| ante | n | mean logged value | **floor penalty** | value + penalty |
|---|---|---|---|---|
| 1 | 1093 | +1.88 | **2.13** | +4.01 |
| 2 | 940 | −0.81 | **1.61** | +0.81 |
| 3 | 901 | −0.93 | **0.55** | −0.38 |
| 4 | 746 | −0.00 | 0.11 | +0.11 |
| 5–8 | 790 | +0.44…+1.61 | ≈0.02 | — |

Mean penalty **0.99** against a mean residual value of **0.21** — ~5×. **540 affordable packs
(12.1%) are negative SOLELY because of the floor penalty**, and 481 of those 540 are at antes 1–2.

**So the SAVE preference the paired data measured is an EARLY-GAME artifact of the econ floor.**
From ante 4 the penalty is ~0 and packs are positive on average — they simply lose the ranked list
to jokers and rerolls, and Celestial stays negative for its own (type-specific) reasons. Two
different suppressors in two different windows; do not attempt one fix for both.

⚠ The floor exists for a documented reason (it stopped the spend-to-$0 spiral on weak jokers) and
`ECON_FLOOR`/`ECON_FLOOR_RATE` are MAGNITUDE constants — the class this project has repeatedly
shown backfires in isolation. **Do not touch them until the `richpack` probe reports.** If
throughput measures causal, this is the identified mechanism to fix and there would then be BOTH a
causal probe and a mechanism — the strongest position available. If it does not, this is just a
correct description of a policy that happens to be right.

### 💡 THE HYPOTHESIS IS AN INTERACTION — and it is the project's first two-axis probe

The naive reading ("buy more packs") is already REFUTED: `levelbuy` (§5g) bought the declined
Celestial offers, more than doubled levels (2.52 → 5.51/run), and measured **−0.229**, with the
arithmetic ~10 buys × $4.50 ≈ $45 ≈ −0.22 — the levels paid for themselves and no more. But note
what the three known cells actually are:

| cell | packs/ante | result |
|---|---|---|
| baseline | 1.36 | 2.5% win |
| money alone (`rich10`, +$10/rd) | 2.44 | 7.5% win |
| packs alone (`levelbuy`, no extra income) | ↑ Celestial only | **−0.229** |
| **money + packs** | — | **NEVER TESTED** |

The human has **both**. Their dollar trajectory matches the `rich10` arm within ~15% at every ante
(a2: $9.2 vs $10.4 vs engine $1.3; a3: $21.5 vs $24.2 vs $6.6) *while also* buying ~4.7 more packs
per ante — so their true income is roughly **rich10 + the extra pack spend ≈ +$16/round** over
baseline, which the dose–response prices at only ~15% winrate. They win 87.5%. **Money alone cannot
explain the gap; packs alone are refuted; the untested cell is the product.**

`Probe.pack_greed` + configs `packgreed10` / `richpack` test the 2×2, with reserve held at $10 in
BOTH pack cells (the engine's own `SA.ECON_FLOOR`; the levelbuy series showed the reserve is what
did the damage: $0 → −0.229, $10 → −0.002, $20 → −0.084), so the cross varies only money.
Interaction = (richpack − rich10) − (packgreed10 − baseline).

### ⚠ Caveats, stated before the result

* **Bought vs free is unknown.** This dataset cannot distinguish packs the human BOUGHT from free
  MEGA packs granted by skip tags — `blind_select`/`blind_result` were added to telemetry on
  2026-08-13 and this dataset is 08-12, so several runs log zero blinds. If much of the human's
  volume is tag-sourced, "buy more packs" is the wrong prescription even if throughput is causal.
* **`richpack` may be underfunded** at +$10/round against the human's ≈+$16/round, so a null there
  would not fully refute the interaction.
* The win/loss separation is **n=1 on the loss side**. It is a strong correlation, not proof.
* Pack decisions cascade the seeded RNG hard, so expect sd ≈ 1.0–1.9 and MDE ≈ 0.2–0.4 at n=80.
* **The probe holds the PICK policy fixed.** `pack_greed` buys the pack; the engine's own
  `PackOpenAdvisor` still chooses inside it — and §5s measured exactly that policy as the most
  divergent thing in the project (41% agreement; enhance/money/shape all significant). So this
  tests *"more packs, engine's picks"*, not *"more packs, human's picks"*. **A null would NOT
  cleanly refute the throughput hypothesis**, because the extra picks are made by the policy we
  already know is wrong. A POSITIVE result is therefore the strong outcome: it would mean
  throughput pays even through a mis-calibrated picker.
  (The world does not waste them: slots-full consumables are USED immediately (the A6 fix) and
  Standard cards go straight into the deck, so nothing paid for is silently voided.)

---

# 6. ⭐ THE OPERATING-POINT PROBLEM — why "logical fixes measure inert", and it is the measurement

**This may be the most consequential result in the project, because it is about the METHOD every
verdict here has used.**

`rich10` (+$10/round) was re-run on current code to serve as the matched arm for the §5z
interaction test. It was previously run at `e7c3a8c`. Same probe, same 80 seeds, so the pair is a
clean paired A/B of the accumulated ENGINE work, **measured at a different operating point**:

| | old (`e7c3a8c`) | new (`82f808f`) | Δ |
|---|---|---|---|
| progress | 4.608 | **5.338** | **+0.730** |
| wins | 6 / 80 (7.5%) | **12 / 80 (15.0%)** | **2×** |

**t = +3.11, p = 0.0018. Sign test 46 better / 26 worse, p = 0.025.** Two independent tests agree,
and sd 2.096 → MDE 0.66 at n=80, so the effect clears its own detection floor.

Now compare what those SAME changes measured **at baseline income**, each properly paired at
n=160–480:

| change | baseline verdict |
|---|---|
| retrigger core-keep | +0.012 (142/160 TIED, MDE 0.115) |
| economy model | −0.002 (159/160 TIED) |
| currency bridge | −0.125 (p 0.40, MDE 0.42) |
| secret hands / `HAND_ORDER` | **exactly 0.000** |
| **sum** | **≈ −0.115** |

**The same engine work: ≈ −0.115 at baseline, +0.730 (p=0.0018) at +$10/round, doubling the
winrate.**

### The explanation, and it is not subtle

**The baseline engine holds $1.3 at ante 2 and $6.6 at ante 3.** A valuation fix changes which
option the engine *prefers* — but preference is only expressible if you can afford to act on it.
Testing a valuation change at baseline income is testing a car's handling with an empty tank. The
measurement apparatus has been operating at the one point on the resource axis where the quantity
under test is least able to express itself.

This retro-explains the project's central mystery — "after so many attempts at improvements which
are logical it is not improving anything" — without needing the churn/chaos story to carry all of
it. Both are true: §5z's envelope shows the outcome is chaotic in the policy (sd ~1.9), AND the
baseline starves the policy of the means to act.

### What this changes

1. **Judge valuation changes at an operating point where they can fire.** A `rich10` arm costs the
   same as a baseline arm and has ~8× the winrate headroom (15% vs 2.5%), so it discriminates far
   better. Baseline remains the honest headline number; it is a poor *instrument*.
2. **Re-examine the revert set.** The graveyard (C1, B3, F3, F4, F8, swap-damp, cost-discount,
   xmult-floor, the reroll gate, W-ECON…) was populated almost entirely by baseline nulls. Those
   verdicts are now suspect as a class — not necessarily wrong, but *untested where it counts*.
3. It reframes §5w's "decisions are not the binding constraint; income is." Income is not just a
   resource the engine lacks — **it is the precondition for any decision improvement to register at
   all.** That is a supermodularity between the money axis and the policy axis, and it is the same
   shape as §5z's pack/income interaction.

### WHERE the operating-point gain lands — broad, and it is not regression to the mean

An obvious alternative explanation is that the fixes only help LATE, and baseline runs die before
reaching where they matter. Bucketing seeds by where the OLD code died appears to answer this
(+2.948 for old-early-deaths, +0.067 for old-late-deaths) — **but that is a regression-to-the-mean
artifact** and must not be used: conditioning on A's outcome and measuring B−A guarantees that bad-in-A
looks better in B, and severely so when the two arms correlate weakly (which §7 shows they do). The
distribution shift has no such confound:

| at the `rich10` operating point | a1 | a2 | a3 | a4 | a5 | a6 | a7 | a8 | WIN |
|---|---|---|---|---|---|---|---|---|---|
| OLD (`e7c3a8c`) | 7 | 2 | 11 | 12 | 21 | 9 | 6 | 6 | 6 |
| NEW (`82f808f`) | 3 | 0 | 4 | 15 | 20 | 12 | 12 | 2 | **12** |

Fraction reaching ≥a4: **0.75 → 0.91**; ≥a6: 0.34 → 0.47; ≥a7: 0.23 → 0.33. **Deaths in antes 1–3
fall from 20 to 7 (−65%).** The gain is broad and starts EARLY — so "the fixes only matter late" is
refuted, and the money-enables-preference reading survives: given cash, the improved valuations act
from ante 1.

### ✅ CONFIRMED — the identical code pair at both operating points, interaction p = 0.0175

The queued worktree run landed. `e7c3a8c` was run at **baseline income** on the same seed family,
against current-code baseline (`bridge.jsonl`). That replaces the earlier "sum of separate
measurements" argument with a clean single A/B at each operating point:

| operating point | code delta | SE | p | wins | sign test |
|---|---|---|---|---|---|
| **baseline income** | **−0.102** | 0.224 | 0.65 (n.s.) | 1 → 2 / 80 | **32 / 34 — dead even** |
| **+$10/round** | **+0.730** | 0.234 | **0.0018** | 6 → 12 / 80 | 46 / 26 (p 0.025) |

**INTERACTION (code × operating point): +0.832, SE 0.324, t = 2.57, two-sided p = 0.0102.**

The same six commits are worth **nothing** at baseline (if anything slightly negative, sign test
32/34) and **+0.730** when the engine has money. The effect is not the code alone and not
the money alone; it is the product.

⚠ Remaining honest caveats: the two deltas are measured on the same seed family, so treating them
as independent for the interaction SE is approximate. The bundle is six commits, so this says
"accumulated engine work" pays at income, not which commit does. And baseline winrates (1 → 2 of 78)
are too small to carry any weight on their own — the progress metric and the sign test do the work.
(Numbers are the complete n=80 per arm.)


---

## 7. THE PACK×INCOME INTERACTION — suggestive, NOT demonstrated (and the metrics disagree)

`richpack` (+$10/round **and** forced pack throughput) vs `rich10_now` (+$10/round alone). Same 80
seeds, same code, same income — the ONLY difference is `Probe.pack_greed`. The probe fired as
designed: **packs/ante 3.48 → 5.66**, against the human's 6.10.

| metric | rich10_now | richpack | verdict |
|---|---|---|---|
| progress | 5.338 | 5.476 | **+0.137**, t=0.48, **p 0.63 (n.s.)** |
| sign test | — | — | 38 better / 36 worse (p 0.91) — **dead even** |
| **wins** | **12 / 80 (15.0%)** | **19 / 80 (23.8%)** | **+58% relative** |
| McNemar (paired wins) | — | — | discordant **7 vs 14**, exact **p 0.189 (n.s.)** |

**Neither metric is significant, and they disagree in direction of emphasis.** sd 2.550 → MDE 0.80
at n=80, so the progress arm is hopelessly underpowered for a +0.137 effect.

### ⚠ The win sets are nearly DISJOINT — churn, now visible in the outcome that matters

Only **5 seeds won in BOTH arms** (of 12 and 19). Forcing pack throughput *lost* 7 wins and *gained*
14. This is §5z's chaotic-policy-sensitivity finding reappearing in the win count itself: the
intervention largely **re-rolls WHICH seeds win**. A raw "12 → 19" reads as a 58% improvement; the
paired structure shows it is 7 lost + 14 gained at p 0.19.

### 📐 A methodological point worth keeping: progress is a PROXY, wins are the GOAL

The project optimises `progress` because it discriminates better than a censored death-ante. But
here progress says **+0.137 (nothing)** while wins say **+7 net**. A change whose benefit is
concentrated in the TAIL — turning near-wins into wins — is exactly the shape `progress` under-
reports, because it averages the whole distribution. When the two disagree, note it rather than
quoting whichever is more favourable. (Equally: with 5/12 overlap the win gain could simply be
noise. That is the point — at n=80 neither metric can tell.)

### Status: replication running, out of sample

Extending to n=160 should roughly double the discordant pairs (~14 vs ~28), which lands McNemar
near p≈0.04 — borderline. Both arms are being re-run on a **disjoint seed pool** (`BES_SEED_OFF=4`
→ s*1000+4) so the extra 80 are out-of-sample rather than more of the same, and the combined
verdict is n=160 per arm. **Do not act on the pack finding until that lands.**

---

# 8. RE-LITIGATING THE GRAVEYARD — a taxonomy, because §6 does NOT resurrect all of it

Prompted by the user (2026-08-14): *"consider reconsidering older reverted changes which were
reverted due to the rule to revert negative results."* §6 shows baseline verdicts on valuation
changes are uninformative, so that is the right instinct. But sorting the graveyard by **why** each
entry died shows only one class is actually freed.

### Class A — killed by a NULL or an underpowered/incomplete batch ✅ genuine candidates

| lever | measurement | why it is a candidate |
|---|---|---|
| **F8** two-stage discard sampling | **n=106 PARTIAL** (batch interrupted 3× by laptop sleep), Δ −0.054, **p 0.70**, sign 44/58 | a null, not a negative; fires on every discard decision; its mechanism was **inherited by analogy** from C1, not demonstrated for F8 |
| **F4** discard-set generators | "high-variance churn"; depends on F8 | churn signature = the §5z chaos, not evidence of harm |

### Class B — killed by a MECHANISM, and the mechanism is ONE mechanism, confirmed 4× ⚠ needs a COUPLED test, not a re-run

**C1** (adaptive samples, −0.142) · **B3** (the $↔frac rate, −0.245) · **F4/F8** (above) all failed
for the *same* stated reason, and the audit states it explicitly: **"you cannot change the
measurement's noise / the rate / the candidate set without co-retuning the guardrails built around
the old value."** `keep_bias`, the prior floors, `UPGRADE_MARGIN`, `SK.SHOP_VALUE`, the skip margin
and the consumable-money weights are all COMPENSATORS fitted to the old regime.

That is a real mechanism, independently reproduced four times — **it is not a null-revert, and §6
does not automatically clear it.** A change can be genuinely mis-calibrating *and* unmeasurable at
baseline; both are true at once. The open question is whether the mechanism itself was ever
verified at an operating point where it could be seen. **`sim_out/rich_nobridge.jsonl` is that test**
(B3 isolated, at `rich10`), and B3 is the family representative.

### Class C — killed by FREQUENCY ❌ still dead, and §6 is irrelevant to them

E-2, E-2b, SECOND_XMULT_BONUS ("wash, offer-limited"), TAG/Judgement/Soul sell-to-make-room,
committed-hand play-freq, E-14 Mouth, reroll-to-dig. All "near-inert / channel too rare". **The
frequency ceiling applies at every operating point** — a lever that fires in 2% of runs cannot move
a verdict whether the engine is rich or poor. Do not re-test these.

### Class D — already resurrected ✅ no action

**E-5** was reverted 2026-07-12 on the tail gate (sign **57/33, p 0.015** — the strongest sign
result in the project — but wins 4→2, which is two events and statistically meaningless). It was
**already re-applied on 2026-07-13** after replay-screening and is now the project's LARGEST shipped
lever (**+0.146**). `decision_engine.lua:586` carries the note. *This is the precedent for the whole
exercise: the resurrection worked, and it produced the single biggest gain in the project.*

### The rule this suggests

Revert-on-mechanism stays valid. But **"reverted on a null"** and **"reverted on a handful of
wins"** are now both suspect, and E-5 proves the upside is real. The screening order is:
**frequency first** (Class C is unrecoverable), **then mechanism** (Class B needs the coupled
retune the audit already specified), **then re-measure at an operating point where it can fire**.


---

# 9. ✅ B3 IS RESURRECTED — the "co-retune the guardrails" mechanism was itself a BASELINE ARTIFACT

The Class-B family test (§8) landed. `rich_nobridge` is current HEAD with **one constant** reverted
(`BASE_FRAC` 0.06 → 0.03, clamps with it), run at `rich10` against `rich10_now`. A `git log` over
`engine/ model/ core/ util/` between the two arms returns **nothing** — the isolation is exact.

| test | result |
|---|---|
| **progress Δ** | **+0.672**, sd 1.951, SE 0.218, **t = 3.08, p = 0.0021** ✅ |
| wins | **6 → 12** (McNemar discordant 2 vs 8, p 0.109) |
| death-ante | **31 later / 17 earlier**, 32 unchanged |
| sign test | 38 / 28 / 14 tied (p 0.27, n.s.) |

**The same single constant measured −0.245 (n=80, 2026-07) and −0.125 (n=154, this session) at
BASELINE income.** At an operating point where a dollar can actually be spent it is **+0.672,
p=0.0021**.

### What this overturns

1. **B3's July revert was a measurement artifact.** The recorded mechanism — *"`SK.SHOP_VALUE`, the
   skip margin, keep_bias and the consumable-money terms were all calibrated against the old 0.03
   rate, so doubling the rate alone mis-calibrates every one of them"* — is coherent, was
   reproduced four times (C1/B3/F4/F8), and **does not survive contact with the operating point.**
   The co-retune the audit deferred as a prerequisite is not needed for B3.
2. **B3 alone is most of the six-commit bundle** from §6 (+0.518 pooled vs the bundle's +0.730;
   in-sample it was +0.672 vs +0.730). The operating-point effect is not diffuse accumulated work —
   it is substantially *this one constant*.
3. **Class B of the graveyard is now open.** C1 (adaptive samples, −0.142), F4 and F8 all died to
   the same mechanism and all were measured only at baseline. They deserve the identical treatment:
   isolate, run at `rich10`, compare.

### WHY it works — the behavioural diff, and it is what the human data predicts

| per ante (unless noted) | B3 OFF (0.03) | B3 ON (0.06) | change |
|---|---|---|---|
| **SKIPs per run** | **3.11** | **2.34** | **−25%** |
| packs | 3.09 | 3.48 | +13% |
| Celestial packs | 0.60 | 0.69 | +15% |
| planets used | 0.83 | 0.91 | +10% |
| tarots used | 1.95 | 2.07 | +6% |
| jokers gained | 2.16 | 2.19 | +1% |
| $ held at a2 / a3 | 10.4 / 24.6 | 10.6 / 23.7 | — |

The dominant change is the **`tags.lua` INVERSE**: doubling `dollar_frac` halves `frac_to_dollars`,
which halves the dollar value of joker / orbital / pack skip tags — so **the engine skips 25% fewer
blinds**. The audit's own B3 entry identified exactly this as the bug (*"tags ~2× over-valued in the
skip decision, worsening with ante"*); it simply measured the fix at baseline. The user's stated
view of correct play is the same: *"skipping is typically the wrong option."*

The secondary changes — more packs (+13%), more Celestials (+15%), more planets (+10%), jokers flat
— are precisely the direction §5z's human comparison says is right, and they cost no extra money
($ held is unchanged): it is a REALLOCATION, not more spending.

**This also explains the baseline failure.** At baseline the engine holds $1.3 at ante 2, so the
"buy more packs" half cannot fire at all — leaving only the skip change, which the `noskip` probes
(§5w, 68/67 and 71/61) showed is ~neutral there. At `rich10` both halves fire and compound. The
result is not a bare number; it has a mechanism, and the mechanism is the one the audit wrote down
in July.

### ⚠ REPLICATION (disjoint pool `BES_SEED_OFF=4`) — direction HOLDS, magnitude HALVES, wins DO NOT

| | progress Δ | p | wins |
|---|---|---|---|
| in-sample (s·1000+3) | **+0.671** (SE 0.218) | **0.0021** | 6 → 12 (discordant 2 v 8) |
| **out-of-sample (+4)** | **+0.345** (SE 0.232) | 0.136 (n.s.) | **10 → 10** (discordant **6 v 6**) |
| **POOLED n=160** | **+0.518** (SE 0.159) | **t 3.26, p 0.0011** | McNemar 8 v 14, **p 0.286** |

1. **The progress effect is real but SMALLER than first measured.** +0.518 pooled, not +0.672. The
   in-sample figure was inflated by **winner's curse**: B3 was selected for testing partly because
   the bundle containing it looked good *on that same pool*. The out-of-sample +0.345 is the less
   biased single estimate; the pooled +0.518 is the best overall.
2. **The win-doubling does NOT replicate.** The disjoint pool is exactly **6 vs 6** discordant —
   dead null. The in-sample 6→12 was noise, exactly as §7's near-disjoint win sets warned. **Do not
   quote "B3 doubles the winrate."**

**The interaction survives on the conservative estimate:** baseline −0.102 (SE 0.224) vs rich
pooled +0.518 (SE 0.159) → **+0.620, SE 0.274, t = 2.26, p = 0.0238.** So §6's operating-point
claim stands, and B3 is worth roughly the size of the project's **entire historical retained arc
(+0.487)** — but at `rich10`, and with no measurable winrate effect.

### ⚠ Honest limits

* Only the primary metric is significant. The sign test (38/28) and McNemar (2 vs 8) point the same
  way but are n.s. — the mean is carried by large gains on a **subset** of seeds, not by moving most
  of them. Given §5z's chaos (85% of seeds flip under tiny perturbations) that is a real caveat.
* **Out-of-sample replication is running** (`nobridge_s4` vs `rich10_s4`, disjoint pool
  `BES_SEED_OFF=4`). This result is strong but single-pool; do not treat Class B as settled until
  the replication agrees.
* This says nothing about whether B3 helps at BASELINE income, where it still measures ≈ −0.1. The
  engine a real player runs is the baseline one. **If the goal is the live overlay, B3's value is
  still unproven; if the goal is winrate given a functioning economy, it is the biggest single
  lever found.**

---

# 10. HYPOTHESIS (not acted on): the early-interest compounding trap

§9 shows every improvement found so far is **gated on the engine having money**. So the question
that now matters most is where the human's early money comes from, since it is not exogenous for
them. The arithmetic points at **compounding interest**, and it is self-reinforcing in both
directions:

| at ante 2 | $ held | interest earned (=$1 per $5, cap $5) |
|---|---|---|
| ENGINE (baseline) | **$1.3** | **$0 / round** |
| HUMAN | **$9.2** | **$1–2 / round** |
| by ante 3 | $6.6 vs $21.5 | $1 vs $4 / round |

Over the ~6 rounds of antes 1–2 that is ≈**$6** of the ≈$8 gap — and it compounds from there. The
engine's measured antes-1–2 behaviour: ~3.6 joker buys, 1.8 pack buys, 0.7 consumables, 0.2
rerolls, 0.2 vouchers ≈ **$32 spent against ~$30 earned**, landing it at $1.3 with the interest
channel switched off for the rest of the run. `SA.ECON_FLOOR` ($10) exists to prevent exactly this
but is a SOFT penalty folded into the value, and it demonstrably fails to hold the line.

### Check (c) ANSWERED: it is NOT econ jokers — it is EARLY JOKER CHURN

| by ante 2 | jokers gained / run | econ jokers / run | summed econ $ |
|---|---|---|---|
| ENGINE (baseline) | **5.93** | 0.76 (13% of jokers) | $2.59 |
| HUMAN | **4.62** | 0.62 (14% of jokers) | $2.12 |
| *(by ante 3)* | 6.96 vs **8.12** | 0.95 vs 1.25 | $3.28 vs $4.00 |

**The human does not out-earn the engine through economy jokers** — the shares are nearly identical
(13% vs 14%), and by ante 2 the human actually holds slightly LESS econ ($2.12 vs $2.59). So the
$9.2-vs-$1.3 gap at ante 2 is not an income-source difference.

**It is spending.** The engine acquires **1.3 more jokers by ante 2** (5.93 vs 4.62) at ~$5 each
≈ **$6.5**, which is most of the ~$8 gap; the forfeited interest then compounds on top. Note that
joker slots are **5**, so acquiring ~6 by ante 2 means the engine is *churning* — buying and
selling — which the anti-churn work already targets but evidently not this early. By ante 3 the
human has overtaken on joker count (8.12 vs 6.96), so this is a difference in **timing**, not in
how many jokers each ends up with: **the engine front-loads board and the human front-loads cash**,
which is exactly the "economy and base first, power second" sequencing already recorded in CLAUDE.md.

**Refined hypothesis:** the engine converts cash into board during antes 1–2, the only window where
cash still compounds. That is narrower and more testable than "raise the econ floor", and it does
NOT contradict the `hoard` probes (which blocked ALL purchases below $10 from ante 1).

### ⚠ Why this is NOT yet an action

`hoard10` (min_bank $10 until ante 5) measured **−0.396**, `hoard20` −1.194, `hoard25a4` −1.639 —
all strongly negative. That is a direct measurement and it must not be waved away. But note what
that probe actually did: a **HARD refusal** of any purchase dropping below $10, from ante 1 — when
the engine only *has* ~$4–10, so it blocks the first joker outright. That is a different
intervention from "preserve one interest step".

**Before touching this, the honest checks are:** (a) re-measure `hoard` at the `rich10` operating
point (per §6 the baseline hoard verdicts are as suspect as any other), (b) test a *soft, scaled*
floor (e.g. hold $5 = one interest step, scaling with ante) rather than a hard $10 from ante 1, and
(c) confirm the human's early money is actually interest rather than econ jokers — the live data can
answer that and has not been asked. **Do not ship a floor change on this arithmetic alone.**

### ❌ RESULT: `ecap3` −0.169 (n.s.) — and it measured the WRONG THING, which is the finding

`ecap3` (board held to 3 jokers through ante 2), paired n=154 vs the current-code baseline:

| | value |
|---|---|
| progress Δ | **−0.169** (t −1.44, **p 0.151**, n.s.; MDE 0.33) |
| sign test | 58 better / 63 worse / 33 tied (p 0.72) |
| wins | 4 → 5 |

The lesion **fired** — shop buys by ante 2 fell 5.06 → 3.98. But look at what happened to the
cash it was supposed to preserve:

| | shop buys ≤a2 | sells ≤a2 | $ at a2 | $ at a3 | $ at a4 |
|---|---|---|---|---|---|
| baseline | 5.06 | 1.88 | $1.5 | $7.5 | $18.7 |
| **ecap3** | **3.98** | 2.09 | $1.1 | **$3.4** | **$12.9** |

**It made the engine POORER at every ante.** The cause is the probe's own design: it promotes the
best NON-joker alternative (deliberately, so packs could still be bought), and the freed cash flowed
straight into packs / rerolls / vouchers. Sells did not fall either (1.88 → 2.09).

So `ecap3` tested *"spend on non-jokers instead of jokers"*, **not** *"hold the cash"* — and that
trade is neutral-to-negative. The finding that survives is broader and more useful than the
hypothesis was:

> **THE ENGINE SPENDS TO ZERO REGARDLESS OF WHAT YOU BLOCK.** Restricting one purchase channel
> just reroutes the money into the next one. `SA.ECON_FLOOR` is a soft penalty and does not hold a
> line anywhere. Any test of the compounding hypothesis must block the SPEND, not redirect it.

`ecap3bank` (same cap, but forces SAVE so the difference is actually banked) is the corrected test.
It is narrower than `hoard` — which hard-refused ALL purchases below $10 from ante 1 and so blocked
the *first* joker — because it banks only the 4th/5th marginal joker's cost. Given `hoard`
(−0.396/−1.194/−1.639) and `ecap3` (−0.169) both lean negative, the prior is that this is negative
too; if it is, **the early-compounding thread is closed** and the record will say so.

### The churn's actual mechanism: **SELL_TO_BUY**, 81% of it

Breaking the engine's ante-1..2 sell advice down by TYPE (n=209 across 154 runs):

| advice | n | share |
|---|---|---|
| **SELL_TO_BUY** | **170** | **81%** |
| SELL_JOKER | 39 | 19% |

**It is not "sell the weakest for cash" — it is selling a joker to FUND a purchase it cannot
otherwise afford.** That closes the loop on §10's compounding story with a concrete code path:

> poor ($1.3 at ante 2) → cannot afford the thing it wants → SELL_TO_BUY funds it at ~50% of
> purchase price → poorer → the next want is also unaffordable → sell again.

This is self-reinforcing and it fires ~1.1×/run before ante 3. It also explains why `ecap3`
backfired: capping the *board* left SELL_TO_BUY untouched (sells actually rose, 1.88 → 2.09).

⚠ The jokers being sold include **Hanging Chad** — the ONE joker present in all seven human wins
(CLAUDE.md) — alongside Wily/Crafty/Jolly/Zany/Banner/Superposition. This is the same failure class
as the Dusk finding in §5s: a compounding piece traded away early for immediate affordability.

`nochurn2` blocks SELL_TO_BUY and non-junk SELL_JOKER before ante 3. If it measures positive, the
fix is not a new valuation weight — it is a **feasibility gate on SELL_TO_BUY while poor**, which is
a narrow, high-frequency, mechanism-justified change.

### ❌ `ecap3bank` −0.073 (p 0.571) — the early-compounding thread is CLOSED

The corrected lesion (cap the board AND bank the difference) worked exactly as designed:

| | shop buys ≤a2 | sells ≤a2 | $ a2 | $ a3 | $ a4 | $ a5 |
|---|---|---|---|---|---|---|
| baseline | 5.06 | 1.88 | $1.5 | $7.5 | $18.7 | $27.9 |
| **ecap3bank** | **2.94** | **0.66** | $4.0 | **$21.0** | $22.0 | **$27.5** |
| *HUMAN* | *2.75* | *0.12* | *$9.2* | *$21.5* | *$25.5* | *$43.4* |

**It reproduced the human's early economy almost exactly — $21.0 at ante 3 against their $21.5, and
their joker-buy count — and measured NOTHING** (−0.073, t −0.57, p 0.571, sign 60/64, wins 4→5).

**Two conclusions, both firm:**

1. **The human's early money advantage is NOT causal.** Handed the same early bankroll and board,
   the engine does not improve. Combined with `hoard` (−0.396/−1.194/−1.639) and `ecap3` (−0.169),
   **stop trying to make the engine save early.** Thread closed.
2. **Early savings do not persist.** `ecap3bank`'s $13.5 advantage at ante 3 is **gone by ante 5**
   ($27.5 vs baseline $27.9). Another confirmation that the engine spends to zero regardless — a
   one-time surplus is consumed, not compounded.

### Where the human ACTUALLY separates: antes 4–6, and it is a FLOW not a STOCK

| held | a2 | a3 | a4 | **a5** |
|---|---|---|---|---|
| ENGINE | $1.5 / 2.9 jok | $7.5 / 4.6 | $18.7 / 5.0 | **$27.9** / 5.2 |
| HUMAN | **$9.2 / 1.4 jok** | $21.5 / 3.9 | $25.5 / 5.1 | **$43.4** / 5.4 |

The human runs a nearly EMPTY board at ante 2 (1.4 jokers!) and is *behind* on board through a3 —
then converges by a4 and pulls away on cash at a5 at the SAME board size. Both are above the $25
interest cap, so interest does not explain it. What does:

| by ante 5 | jokers gained | econ jokers | summed econ $ |
|---|---|---|---|
| ENGINE | 7.85 | 1.19 | $4.12 |
| HUMAN | **12.12** | **2.00** | **$6.62** |

**The human acquires 1.5× more jokers and 1.6× more ECONOMY — just later.** ~$2.50/round more econ
over ~12 rounds ≈ $30, which covers the $15 cash gap plus the extra buying. So the sequencing is a
compounding *flow*: hold early → acquire more and better from a3 → more econ → more cash → more
acquisition. The engine's is the inverse spiral: spend early → poor → `SELL_TO_BUY` churn → poorer.

**This is why `rich10` works (+1.538) and `ecap3bank` does not:** a continuous income STREAM the
engine's policy converts fine; a one-time early STOCK it simply consumes. Any future economy work
must target the flow (econ acquisition from ante 3 on), not the early stock.

### ✅ `nochurn2` +0.114 (n.s.) — the FIRST early intervention to lean positive, and the only one that improves everything at once

| | sells ≤a2 | shop buys ≤a2 | $ a2 | $ a3 | $ a4 | jokers a3 |
|---|---|---|---|---|---|---|
| baseline | 1.88 | 5.06 | $1.5 | $7.5 | $18.7 | 4.6 |
| **nochurn2** | **0.46** | 4.13 | $2.3 | **$10.6** | **$20.1** | **4.8** |

Verdict: **+0.114** (t 0.93, p 0.350, n.s.; MDE 0.342), sign 57/49/48 tied, death-ante **43 later /
31 earlier**, wins 4→4.

Not significant — but look at the ORDERING of every early-game intervention tried, against how
precisely each is targeted:

| probe | what it restricts | Δ |
|---|---|---|
| `hoard10` | ALL purchases below $10 from ante 1 | **−0.396** |
| `ecap3` | board size; freed cash redirected | −0.169 |
| `ecap3bank` | board size; freed cash banked | −0.073 |
| **`nochurn2`** | **the SELL side only; no purchase, no board change** | **+0.114** |

**Monotone in precision.** And `nochurn2` is the only one that moves all three quantities the right
way *simultaneously* — fewer sells (−75%), MORE money ($7.5→$10.6 at a3) and a SLIGHTLY BIGGER board
(4.6→4.8) — where every other probe traded one against another. That is the signature of removing a
genuine loss rather than reallocating a budget.

**Next: dose–response, not another p-value.** `nochurn3` (block through ante 3) is running. If
Δ(nochurn3) > Δ(nochurn2) > 0 that is far stronger evidence than any single n.s. reading, and it is
the standard this project already trusts (§5w's money dose–response). If the dose does NOT respond,
treat +0.114 as noise and close the thread.

### The shipped fix, if the dose–response confirms: a REPLACEMENT charge on joker-funded SELL_TO_BUY

`shop_advisor.lua:~1084` scores the trade as

```lua
local funded = p.value + SA.DOLLAR_UTIL * f.cash - f.loss
```

crediting the cash raised (`f.cash` ≈ half the purchase price) and charging only the funder's
FORWARD value (`f.loss`). Charging forward value is correct — the purchase price is sunk. But the
formula omits a cost that is NOT sunk: **the slot gets refilled.** The engine's board goes
2.9 → 4.6 → 5.0 jokers across antes 2–4 in every arm measured, so an early joker sale is
*temporary*: the slot is re-bought within a shop or two at ~$5 while the sale raised ~$2.5.

Two independent things make this fire far too often early:
1. **The replacement cost is unpriced** — the model sees +$2.5 of cash, not −$2.5 net.
2. **`f.loss` is noise-suppressed.** On a weak ante-1–2 board a joker's measured marginal reads ~0
   and floors to the tier prior, so the thing being sold looks cheap. That is the same
   measurement-noise family as C1/F4/F8 (§8), and it is *why* the guardrails exist.

**The principled change** (derived, not tuned): when the funder is a JOKER and the board will be
refilled, charge the expected refill against the cash raised —
`SA.DOLLAR_UTIL * (f.cash - refill_p * SA.TYPICAL_JOKER_COST)` — using the constant the engine
ALREADY has for this ($5, "what you expect to pay for a joker once a reroll surfaces one").
Early, `refill_p ≈ 1`, so a ~$2.5 sale nets ≈ −$2.5 and joker-funded SELL_TO_BUY largely stops —
which is exactly the `nochurn2` behaviour. It leaves consumable-funded SELL_TO_BUY untouched
(no slot to refill) and needs no new constant.

⚠ **Do not ship this on `nochurn2`'s +0.114 alone** (p 0.350). Ship only if `nochurn3` shows a
dose–response; and because it is a valuation change, expect §6 to apply — its effect may be far
larger at the `rich10` operating point than at baseline, so measure both.
