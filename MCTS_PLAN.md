# MCTS_PLAN.md — efficient forward-search shop lookahead (started 2026-07-14)

**Why:** the winrate is stuck at 4/160 (2.5%). Four independent mining passes proved the incremental
lever space is EXHAUSTED and the frontier is a genuine **build-assembly wall** (see WINRATE_AUDIT §7,
2026-07-14 shape-B entry): wins cross an exponential threshold (TWO stacked xmult keystones, or
keystone + deep-leveling); near-wins hold ONE keystone padded with additive filler that inflates early
pace but can't compound. The shop supply is FAITHFUL (rarity Common70/Unc25/Rare5 = real Balatro,
xmults offered ~12%), so keystones are genuinely scarce. The greedy per-joker valuation
(`add_joker_marginal_fv`) can't *commit to and assemble* a compounding stack across shops — and every
value-REWEIGHT planner form has washed (planner V1/V2c, 2nd-xmult, E-16/E-17). The one untried class is
a **superior decision MACHINE** (like F1/F2 boss-aware survival arbitration, the best in-blind lever,
+0.038) applied to the SHOP: a forward search that values a purchase by the build PATH it enables, not
its marginal score now.

**Hard constraint:** full `survive_after` rollouts per shop-candidate are computationally INFEASIBLE
(~60 rollouts × K candidates × many shops × 160 runs ≈ 100× a normal batch). The lookahead MUST use a
CHEAP analytic value function (no in-blind rollouts) + bounded branching/depth.

## Architecture (target)
1. **Cheap capacity value `V(board, ante)`** — analytic projected score capacity: `base_chips × Σ mult
   × Π xmult × leveled-hand`, reusing `BP.analyze` (n_xmult/base) + `Eval.scaling_projection` (scaler
   growth) + `run.hand_levels`. NO rollouts. Compare to `Mechanics` projected boss target at `ante`.
2. **Supply model `P_offer(piece_kind, n_shops)`** — sample the REAL `sim/content` shop generator a few
   times (seeded, private rng) to estimate P(a compounding piece — xmult / matching scaler — appears &
   is affordable in the next `n` shops). This is the genuinely-new SUPPLY-AWARENESS the greedy model
   lacks; it's cheap (content gen is fast, no scoring).
3. **Depth-limited forward search** — from the current shop, for each action (buy top-K candidates /
   save / reroll), transition state, then recurse ≤2 antes sampling `P_offer` continuations; value =
   projected `V` vs target at the horizon (survival proxy). Choose argmax. Branching K≈3, depth≤2,
   scenarios≈3 → ~27 cheap evals/decision (feasible).

## Increment order (each is independently BATCH-TESTABLE vs p5_w6; ship only if sign+progress+tail pass)
- **INC-1 (START HERE) — supply-aware slot/cash RESERVATION.** The narrowest slice of the idea that's
  genuinely new: when the board holds ≥1 compounding keystone and the engine would otherwise fill its
  LAST 1-2 slots (or spend its cash) on additive FILLER, first estimate `P_offer(compounding, next
  ~2 shops)` via the content sampler. If HIGH, RESERVE the slot (decline the filler buy) + hold cash,
  so the board stays open to assemble the 2nd keystone. If LOW, behave as today (filler is fine — no
  2nd piece is coming). This directly attacks the additive-over-buy the shape-B mining identified,
  WITHOUT a value re-weight (it's a conditional reservation driven by a sampled supply estimate).
  Gate to NOT-URGENT (never reserve a slot when survival needs power now) and to a real keystone held
  (base≥2 + n_xmult≥1, or a scaler core) so bare/weak boards are unaffected. Behavioral-probe first
  (does it change buys? does it hold slots?), then n=160.
- **INC-2 — capacity-projection value function** `V(board, ante)` as the PRIMARY buy value (replacing
  marginal-only), so compounding pieces out-rank filler by their PROJECTED terminal capacity. (Overlaps
  BP.fit; risk of the washed re-weight — do only if INC-1 shows the direction lives.)
- **INC-3 — depth-2 forward search** with `P_offer` continuations (the full lookahead).

## Method / guardrails (unchanged)
Paired n≥160 vs `sim_out/p5_w6.jsonl`; verdict = sign test + progress Δ + TAIL GATE (reach-6+ ≥ 31);
green tests + a regression per increment; the search must use a PRIVATE seeded rng + private cache
(stream-neutral) so it doesn't perturb the run RNG. Realistic success = INC-1 implemented & batch-
verdicted (win → ship & continue to INC-2/3; wash → documented, the architectural angle is then also
closed and the winrate ceiling stands). Behavioral-probe (n=32) before every batch.

---
## INC-1 RESULT (2026-07-14) — ❌ BACKFIRED DECISIVELY; the reservation premise is FALSIFIED
Implemented supply-aware slot/cash reservation (pure `Eval.p_compounding_offered` from the rarity prior ×
compounding density; reserve the last slot when a keystone core is held + not-urgent + filler candidate +
p≥0.5). Behavioral probe looked narrow (fired 3/94 shop states, changed 1). **But n=160 vs p5_w6: progress
−0.136 (t=−2.15, p=0.031 SIGNIFICANT NEGATIVE), wins 4→2 (lost 2), reach-6+ 31→21 (TAIL COLLAPSED −10).**
The **reserve-vs-survive bind is real and DOMINANT**: declining an available filler buy to hold a slot for a
keystone that — at the faithful ~12% supply — usually never arrives leaves the board weaker NOW, and the run
dies sooner. **This FALSIFIES the whole reservation premise: the engine's greedy "fill the slot with the
available filler" is NOT a mistake — it is the SURVIVAL-CORRECT response to scarce keystone supply. The near-
wins' additive boards are optimal-given-the-offers, not a decision error.** REVERTED.

**Implication for the MCTS path (important):** INC-1 attacked the exact "additive-filler over-buy" the shape-B
mining named, and delivering the intervention made things WORSE, not better. INC-2 (capacity-projection value
that prefers compounding pieces) and INC-3 (depth-2 forward search) face the SAME supply wall — they would
also tilt buys AWAY from survival-now filler TOWARD compounding pieces that aren't offered, and INC-1 shows
that tilt costs survival. The winrate ceiling (2.5%) is **SUPPLY-CONSTRAINED**: the winning archetype needs 2
stacked keystones, which requires an offer sequence that occurs in ~2.5% of runs, and **no decision policy can
manufacture the missing offers** — reserving/prioritizing for them backfires. The engine already plays
optimally given the offers (in-blind regret 0.0076; INC-1 proves the shop side is survival-tight too).
**CONCLUSION: the architectural lookahead does not overcome the supply ceiling; the 2.5% winrate is the honest
ceiling of engine tuning on this faithful sim. Raising it further would require changing the GAME inputs
(deck/stake/voucher start) or a fundamentally different win-condition, not a better decision policy.**
