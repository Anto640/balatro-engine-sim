# MCTS_PLAN.md — scoping: line-finding search over the shop stream (re-scoped 2026-08-26)

> **⚠ READ FIRST — the 2026-07-14 conclusion at the bottom of this file ("supply-constrained ceiling;
> no decision policy can help; MCTS is dead") is OVERTURNED by evidence collected afterward.** It is
> preserved below as the audit trail, not as the current verdict. The reconciliation is the whole point
> of this re-scope (see §1). Current authoritative status: `GRAND_AUDIT.md`.

## 1. Why the old "supply ceiling" verdict is overturned — and why search is back on the table

The 2026-07-14 plan built INC-1 (a myopic slot-reservation heuristic), watched it backfire (−0.136,
p 0.031, tail collapsed), and leapt to a sweeping conclusion: *the 2.5% ceiling is supply-constrained,
the engine already plays optimally given the offers, no decision policy can help.* **Four later facts
falsify that leap:**

1. **The human wins 87.5% on IDENTICAL game inputs** (red deck / white stake; `data/bes_runs_live_…`,
   7/8). If the ceiling were the *supply* of offers, the human — drawing from the same generator — could
   not win either. They do. ⇒ the offers permit wins; the gap is finding and committing the line.
2. **`rich10` wins 24%** (same supply, +$10/round). Supply held fixed, winrate 10×'d. ⇒ not supply-bound.
3. **The governing frame** (user, 2026-08-11): *"there is almost always a winning line; the engine finds
   none."* The `rich` probe (+$100/round, ~20× interest headroom) won only 72.5%, not ~100% ⇒ the bottle-
   neck is **line-FINDING**, a search problem, not resources or supply.
4. **This session's closure (GRAND_AUDIT P1–P5):** every per-decision, present-state, economy, product-
   board, and learned-*objective* lever is now closed/bounded on a cheap screen. The **residual is
   DYNAMIC / target-directed** (save-for-interest / deck-shape / future-multiplier — localized by the
   agreement screen) — precisely the object a forward search prices and a greedy valuation cannot.

5. **⭐ THE OFFER STREAM IS ENDOGENOUS TO THE POLICY — so "no decision policy can manufacture the missing
   offers" is not merely wrong, it is BACKWARDS: manufacturing offers is most of what the winning policy
   DOES.** The 2026-07-14 doc treated the stream as an exogenous draw ("xmults offered ~12% of shops"), but
   the policy CONTROLS the stream: **rerolls** mint fresh offers (gated by money — so poverty→thin-stream is
   itself a policy failure), **pack-opening** is the largest offer channel and the engine opens **1.36 packs/
   ante vs the human's 6.10** (§5z — a 4.5× gap that is pure policy), **skip-tags** manufacture free jokers/
   packs, **vouchers** reshape shop rarity/slots, and **deck-shaping** tarots change what you draw. The
   "scarce keystones / faithful supply" the old doc measured was the supply the ENGINE'S OWN under-opening,
   under-rerolling, cash-starved policy produced — not the supply a good policy generates. The ceiling was
   measured on a self-starved stream.

**What INC-1 actually falsified:** a *one-step reservation gamble* — decline an available survival-now
filler because a keystone *might* arrive. That is a bad **policy**, and its failure is real and kept (§7).
It is **not** evidence that *search* is futile: a proper search evaluates whether reserving actually
**leads to a win** across sampled continuations, and buys the filler whenever the line doesn't pay or
survival needs it — the exact bind INC-1 got wrong by guessing instead of searching. And §5 makes the
deeper point: the search's job is not only to pick among the offers in front of it, but to choose the
actions (open packs, reroll, take skip-tags, bank for interest) that GENERATE a richer offer stream.

**The one measurement that settles supply-vs-policy was never taken:** do winning lines EXIST in lost
runs' actual offer streams? That is Phase 0, and it is the gate for everything below.

## 2. The reframe: search over the SHOP STREAM (the one object never closed)

§24 closed *archetype planning* (a perfect deck-frequency target handed to the engine measured null at
both operating points) but explicitly did **not** close **search over the shop STREAM** — "a different
object." §31c–e closed *economy* depth-3 search (buying dominates additive capacity). Neither searched
the **offer sequence** with a proper value backup. That is the un-tried object, and the win condition is
a **PRODUCT** (copiers × xmult × retriggers × leveled base) that an additive marginal provably cannot
represent but a path value can.

Two assets this session hands the search that the 2026-07-14 plan only hypothesized:
- **A validated cheap leaf value.** `tools/winprob_headroom.py`: `capacity` (board scoring power vs boss
  requirement) gives test-AUC ~0.70–0.81 at every ante — ≈ the sufficient statistic for P(win). So the
  search can evaluate a leaf **analytically, with no in-blind rollouts** (the hard-constraint the old plan
  flagged as infeasible is resolved: capacity IS the value function).
- **A chaos-immune screen.** The hardened per-decision **agreement objective** (`tools/replay_fixtures.lua`
  → `tools/agreement.py`, 14-win corpus): score a search policy by whether its picks move toward the
  winners' on the SAME states — immune to the §5z seed chaos (85% of seeds flip outcome under tiny
  perturbations, sd ~1.9, MDE ~0.42), so a policy can be judged before spending a sim arm.

## 3. Phase 0 — THE GATE (cheap; build and verdict this BEFORE any search) 🔑

**Retrospective shop-stream oracle.** For each LOST sim run, ask: does a **reachable winning line exist**
— a sequence of buys/skips/rerolls/pack-opens/levels, subject to the real money + slot + interest
constraints, that clears ante 8? **Critically (per §1.5), the offer stream is ENDOGENOUS, so the oracle
must be run at TWO levels and the gap between them is the headroom:**

- **(a) Observed-stream oracle (LOWER bound):** perfect foresight over exactly the offers the engine's
  policy actually surfaced (the shops/packs it saw). Cheap; reuses `BP.analyze`/`Eval` capacity vs the
  `Mechanics` boss target at each blind (no MC). This is what the 2026-07-14 doc implicitly assumed was
  the whole game.
- **(b) Policy-reachable oracle (THE REAL bound):** also allow the offers a good policy would have
  GENERATED — affordable **rerolls** (re-sample `sim/content` at the real reroll cost/interest tradeoff),
  the **packs the engine DECLINED to open** (their real contents), and available **skip-tags**. This
  counts the stream a manufacture-your-offers policy actually plays into. `sim/content` already has the
  generators; the run trace needs the declined-pack contents + reroll affordability logged (see Data).
- **Verdict:** fraction of LOST runs winnable under (a) vs (b). **(b) − (a) is the endogenous-offer
  headroom — the wins a good policy could manufacture that the engine's thin observed stream hides.** If
  (b) ≫ (a) ≈ 2.5%, the July 14 "supply ceiling" was an artifact of measuring (a) only, and the
  offer-generation policy (packs/rerolls/tags) is the lever — which also re-aims the search in §5.
- **Verdict (headline):** fraction of LOST runs whose stream admits a win, under (b).
  - ≫ 2.5% (e.g. the human-implied ~85%) → **the ceiling is POLICY, not supply — MCTS has real headroom.
    Proceed to Phase 1.** (This directly overturns the 2026-07-14 verdict on the sim's own runs.)
  - ≈ 2.5% → the 2026-07-14 supply-ceiling was right after all → **stop; MCTS is dead, honestly.**
- **Data readiness (VERIFIED 2026-08-26):** the `shop` trace record (`sim/content.lua` `emit_shop`) already
  logs the FULL observed offer set per shop — `offer_jokers`/`offer_packs`/`offer_consumables`/`offer_vouchers`
  each with `{key, cost, value}`, plus `reroll_cost`/`reroll_value`/`dollars`/`ante`; opened packs log full
  `items`. ⇒ **Phase 0a (observed-stream oracle) is buildable NOW as a pure analysis over the arm JSONL on
  disk — no logging changes.** ⚠ Phase 0b (policy-reachable) needs a re-sim harness: DECLINED packs never roll
  their contents into the trace (packs roll only on open), and reroll continuations must be re-sampled from
  `sim/content` — so (b) requires driving the sim forward under an oracle policy, not replaying the trace.
- **Effort:** 0a ~half a day (JSONL walk + capacity-vs-requirement foresight over observed offers); 0b ~1–2 d
  (re-sim). This is the highest-value cheapest thing in the whole plan; 0a alone gives a conservative LOWER
  bound that may already settle supply-vs-policy. Do not build search before it passes.

### ✅ Phase 0a RESULT (2026-08-26, `tools/stream_oracle.lua`) — THE GATE PASSES; supply ceiling REFUTED

Observed-stream keystone-availability oracle (LOWER bound; pure JSONL analysis, no re-sim). Across **623 LOST
baseline runs**: **70% were OFFERED ≥2 affordable multiplier keystones** (xmult/copier/retrigger) and **69%
also had a leveling source offered** — yet the run acquired on average only **1.46 of the 2.75 affordable
multipliers offered** (39% of the ≥2-offered runs took <2). The stricter "≥4 offered" (near a full 86%-mult
winning board) still holds for ~28% of losses. **Rich10 cross-check (242 losses): 92%** offered ≥2 affordable
keystones — the availability rises 70%→92% with money/rerolls, **directly demonstrating the §1.5 endogenous-
offer point** (more resources ⇒ more affordable offers surfaced).

**⇒ The 2026-07-14 "supply ceiling / keystones genuinely scarce / no policy can manufacture the offers"
conclusion is REFUTED on the sim's own runs:** the winning PIECES were in the observed stream in 70–92% of
losses, and the engine passed them up. The 2.5% ceiling is a POLICY (assembly) gap, not a supply gap.

⚠ **Honest scope of the claim:** this proves the *pieces* were available and individually affordable — it is
NECESSARY, not yet SUFFICIENT for a full winning LINE (surviving every blind *while* spending on the keystones
— the survival-vs-assemble bind INC-1 showed is real). So Phase 0a shifts the burden decisively (supply is not
the wall) but the survivable-line question is exactly what the **search** (evaluating full lines with the
capacity value + survival check) must answer — which is the whole point of Phases 1–2. Phase 0b (re-sim with
declined-pack contents + rerolls) is the fuller confirmation; 0a alone already green-lights the build.

## 4. Phase 1 — the forward model + value (only if Phase 0 clears)

- **Environment = the sim as a generative model.** `sim/world` (in-blind referee) + `sim/content` (shop/
  pack generator, rarity-weighted, VERIFY-tagged) become the MCTS transition + **chance nodes** (shop
  draws, deck draws, blind variance). Determinism is per-seed, so counterfactual futures are sampled by
  advancing a PRIVATE seeded rng (never the run rng — the stream-neutrality guardrail).
- **Leaf value V(board, ante) = capacity vs projected boss requirement** (validated §2), reusing
  `BP.analyze` (n_xmult/base) × `Eval.scaling_projection` × `run.hand_levels` × `Mechanics` target. No
  rollouts. Optionally 1–2 greedy-engine rollout steps for near-horizon sharpening.
- **Determinization for chaos:** sample N≈3–5 future streams, average the value (the §5z answer — never
  read a single line as the truth; that is what makes greedy brittle).
- **Calibration check:** V's win-discrimination on held-out arms should match `winprob_headroom` (~0.8
  AUC). If V under-performs capacity-alone, fix V before searching.

## 5. Phase 2 — search over STRATEGIC decisions (not in-blind play)

- **Scope: shop (buy/reroll/save/pack), pack-pick, blind-select (skip/play).** NOT in-blind play — it is
  already near-optimal (in-blind regret 0.0076; the losses are BUILD, not play). Searching play would burn
  budget on a solved problem.
- **Algorithm: start SIMPLE, escalate only if it pays.** Depth-≤2 expectimax / beam over chance nodes with
  the capacity leaf and the greedy engine as default policy — the 2026-07-14 depth-2 design, but with the
  reservation heuristic REMOVED and replaced by a full-line value. Branching K≈3 (top candidates + save +
  reroll), depth ≤2 antes, N≈3 scenarios ⇒ ~27 cheap evals/decision (feasible). Move to UCT/MCTS only if
  expectimax clears the screen and depth is the binding limit.
- **Why this is not INC-1:** INC-1 reserved a slot on a one-step supply *guess*; the search only prefers a
  reserve/compounding buy when the sampled continuations show the line actually **reaches ante 8**, and it
  takes the survival filler whenever they don't — so it cannot make INC-1's survival-vs-reserve error
  (that bind is now inside the value, not a hand-set threshold).
- **Screen order (discipline):** (1) **agreement objective FIRST** — does the search move `eng_buy_human_
  save` toward `agree_save` and lift pack/level agreement, on the winners' states? cheap, chaos-immune,
  no sim arm. (2) Only if it clears, a **paired sim arm n≥160** with the **tail-weighted verdict** (reach-
  7/reach-8 + McNemar, added this session) + **OOS (`BES_SEED_OFF=7`)**, at BOTH operating points.
- **Kill:** agreement unmoved → the search isn't finding the human's lines → wrong value or wrong object,
  fix or stop before any sim arm.

## 6. Phase 3 — learned rollout value (only if Phase 2 clears)

Replace the capacity heuristic leaf with a **learned value** trained on sim outcomes — the ONE use the
`winprob_headroom` bound left open (it bounded the learned model as a *standalone objective*, not as a
*rollout value inside search*). This is where the dynamic/target-directed signal capacity misses can be
learned. Needs a positives-rich training set (rich-arm outcomes; 2.5% baseline starves it).

## 7. Hard constraints, risks, and the lessons that must be carried in

- **Compute is the dominant risk.** The sim is ~95 s/run single-core; naive per-candidate rollouts are
  ~100× a batch (the old plan's correct warning). The capacity leaf value is the enabler that makes it
  feasible — do not regress to rollout-per-candidate. Parallelism (`sim_par.sh`) + a private MC cache.
- **§5z chaos** is the measurement wall: determinize (sample+average) and screen on the agreement objective
  before trusting any sim-arm mean; expect sd ~1.9 on outcome batches.
- **Purity:** the search must use a PRIVATE seeded rng + private cache and must NOT perturb the run rng
  (stream-neutral), or live recommendations will flicker. Same rule as `shop_advisor`/`pack_open_advisor`.
- **Carry the INC-1 lesson:** never trade survival-now for a speculative future on a *guess*; only on a
  value that has actually searched the continuations. The reserve-vs-survive bind is real; put it inside
  V, not a threshold.
- **Carry the null-planner lessons:** oracle_plan (§24) searched a fixed TARGET; the multi-step planner
  (§31c–e) searched ECONOMY depth-3; both null. Shop-STREAM search with capacity backup is the object
  neither tried — but if Phase 0 says lost streams are ~2.5% winnable, all of this is moot and the honest
  answer reverts to the 2026-07-14 conclusion.
- **The advice-vs-autonomy split (GRAND_AUDIT G1):** even a search that is compute-infeasible LIVE could
  run offline to generate better OVERLAY advice for the human (who executes it lag-free) — a fallback value
  path if live search is too slow.

## 8. Sequencing & effort

| Phase | Deliverable | Effort | Gate to next |
|---|---|---|---|
| **0** | shop-stream oracle → % of lost runs winnable | ~1–2 d | ≫2.5% winnable |
| **1** | sim-as-environment + capacity leaf V, calibrated | ~2–3 d | V AUC ≈ 0.8 |
| **2** | depth-2 expectimax over shop stream | ~3–5 d | agreement moves → sim arm passes |
| **3** | learned rollout value | ~1 wk+ | Phase 2 shipped |

**Do Phase 0 first and alone.** It is the cheapest, highest-information step in the project and it
directly re-tests the claim this whole file used to end on. Everything after is conditional on it.

---
## HISTORICAL (2026-07-14) — the original plan + the INC-1 result it ended on

> Preserved verbatim as the audit trail. Its INC-1 *result* stands (the reservation heuristic backfired,
> −0.136); its sweeping *conclusion* (supply ceiling, MCTS dead) is overturned by §1 above.

**Why:** the winrate is stuck at 4/160 (2.5%). Four independent mining passes proved the incremental
lever space is EXHAUSTED and the frontier is a genuine **build-assembly wall**: wins cross an exponential
threshold (TWO stacked xmult keystones, or keystone + deep-leveling); near-wins hold ONE keystone padded
with additive filler that inflates early pace but can't compound. The shop supply is faithful, so
keystones are scarce. The greedy per-joker valuation can't *commit to and assemble* a compounding stack.

**Hard constraint:** full `survive_after` rollouts per shop-candidate are computationally INFEASIBLE
(~100× a batch). The lookahead MUST use a CHEAP analytic value function + bounded branching/depth.

**Architecture (target):** (1) cheap capacity value `V(board, ante)`; (2) supply model
`P_offer(piece_kind, n_shops)` by sampling `sim/content`; (3) depth-limited forward search, K≈3, depth≤2,
scenarios≈3 → ~27 cheap evals/decision.

**Increment order:** INC-1 supply-aware slot/cash reservation; INC-2 capacity-projection value function;
INC-3 depth-2 forward search.

**INC-1 RESULT (2026-07-14) — ❌ BACKFIRED; reservation heuristic falsified.** Reserve the last slot when a
keystone core is held + not-urgent + filler candidate + p(compounding offered)≥0.5. Behavioral probe fired
3/94 states. **n=160: progress −0.136 (t −2.15, p 0.031 SIGNIFICANT NEGATIVE), wins 4→2, reach-6+ 31→21
(tail collapsed −10).** Declining an available filler to hold a slot for a keystone that usually doesn't
arrive leaves the board weaker NOW; the run dies sooner. The greedy "fill the slot with available filler"
is the SURVIVAL-CORRECT response to the offers in front of you. REVERTED.
*(Its further conclusion — "supply ceiling, no policy can help, MCTS dead" — is the over-generalization §1
overturns: a one-step reserve GAMBLE failing ≠ search failing, and the human's 87.5% on identical inputs
proves the offers permit wins. The direct test, Phase 0, was never run.)*
