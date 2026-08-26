# GRAND_AUDIT.md — the consolidated master audit (2026-08-25)

> **What this is.** A ground-up re-derivation of the project's state, written to *distrust* every prior
> verdict and re-establish it (or overturn it) from the code and data as they exist **today** (HEAD
> `f74ec56`, engine byte-identical to `f1242bb` — the intervening commits are docs/tools only, verified
> by `git diff --stat f1242bb..HEAD -- engine/ sim/ core/ model/`). It supersedes the *navigation* role of
> `WINRATE_V3_PLAN.md`/`WINRATE_AUDIT.md`/`NEXT_SESSION.md` but **preserves them as the audit trail** — every
> §-number below points back into `WINRATE_V3_PLAN.md`. Read this first, then the plan sections it cites.
>
> **Method.** Baseline tests green (1046 pass). All numbers below were re-derived from on-disk data
> (`sim_out/*.jsonl`, `data/*.jsonl`) or freshly run (paired, deterministic, from the pristine HEAD tree).
> A forensic subagent re-audited 15 diagnostic tools for the measurement-bug class; a second analysis pass
> mined the human dataset from raw records. Where I was wrong, it is marked ⟲.

---

## A. EXECUTIVE SUMMARY — the state of the world, re-established

**The honest scoreboard (current HEAD engine, re-derived this pass):**

| operating point | winrate | progress | source |
|---|---|---|---|
| **baseline income** (autonomous — the true operating point) | **2.5%** (4/159) | 3.981 | `sim_out/base_31f.jsonl` |
| scripted-expert tier list, baseline | **0.6%** (1/160) | 3.089 | `sim_out/ceil_expert.jsonl` (new) |
| **baseline + 2 reachable slots** | **14.4%** (23/160) | 4.733 | `sim_out/ceil_slots7` (new — **+0.732 paired, t 5.51**) |
| **rich10** (+$10/rd, in-sample +3) | **24.4%** (39/160) | 5.565 | `sim_out/baser_31f.jsonl` |
| **rich10** (out-of-sample +7) | **32.5%** (52/160) | 5.792 | `sim_out/baser7_31f.jsonl` |
| **rich10 + 2 reachable slots** | **51.0%** (49/96) | 6.799 | `sim_out/ceil_rich10_slots7` (new — **+1.265 paired, t 5.96**) |
| rich ($100/rd) | **86.5%** (83/96) | 7.611 | `sim_out/ceil_rich` (new; §5n was 72.5% at OLD code) |
| everything (money+slots+top-pool) | **97.9%** (94/96) | 7.839 | `sim_out/ceil_everything` (new) |
| **expert human, overlay hidden** | **87.5%** (7/8) | — | `data/bes_runs_live_2026-08-12.jsonl` |

> **⭐ The two ceiling runs re-frame the whole project — but the reframe has TWO regimes.** `everything`
> (money + 8 slots + top-pool) wins **~100%** and `rich` ($100/rd alone) wins **~89%** (vs §5n's 72.5% at old
> code — resource→win conversion improved a lot). So **the world does not cap winrate**, and at *extreme* wealth
> the engine brute-forces to a near-perfect winrate. **BUT that does NOT mean "the gap is purely acquisition,"**
> and the rich10-vs-human comparison proves it: at **rich10** — the human's *realistic* wealth — the engine is
> actually **richer than the human early** ($15 vs $7 at a2, $26 vs $23 at a3) and matches leveling (15 vs 15 at
> a8), **yet wins 24% vs the human's 87%.** Two allocation failures persist even with money: it **fills 5 slots
> by ante 2** (human holds 1) → locks a weak additive board it can't later upgrade, and its money **plateaus at
> ~$28** while the human's **compounds to ~$45** — given +$10/rd it *spends* rather than *invests*. ⇒ **The wall
> is TWO things: (1) at baseline, the engine can't ACQUIRE money at all; (2) even at realistic (rich10) wealth it
> ALLOCATES worse than the human (over-fills slots early, doesn't compound economy, builds a sum not a product).
> Only UNREALISTIC wealth ($100/rd) masks (2) by brute force.** This refines §5n: given *enough* resources the
> engine converts fine, but at the operating wealth level allocation is a real, second gap. (Partial n≈20;
> long-surviving arms complete DEATHS first, so true winrates are if anything higher. Finalize on completion.)

**Six load-bearing conclusions, re-derived:**

1. **The valuation layer EARNS ITS KEEP — decisively.** A 120-line scripted tier-list policy, run under
   today's engine at baseline, wins **0.6%** vs the engine's **2.5%** (paired Δ −0.898, t = −5.38,
   p ≈ 0). The engine's measured/Monte-Carlo valuation is a *large net positive*, not the bottleneck.
   "Replace valuation with something simpler" is dead. (Confirms §5a A1 on current code.)

2. **Money is the dominant binding constraint, and this is robust.** The *same* HEAD engine wins **2.5%**
   at baseline and **24–32%** at rich10 — a 10–13× winrate swing from +$10/round alone, and the
   *out-of-sample* rich10 pool is if anything **higher** (32.5%), so it is not a lucky-pool artifact.
   The engine holds a median of **$1 at ante 2**; it cannot afford its own preferences.

3. **The gap is TWO things — economy ACQUISITION and ALLOCATION — not one.** (a) At baseline the engine
   can't make money (median **$1 at ante 2** vs the winners' **$7**). (b) But given money it *still* loses:
   at rich10 the engine is **richer than the human early** ($15 vs $7 at a2) yet wins **24% vs 87%**, because
   it **fills all 5 slots by ante 2** (human: 1), lets its money **plateau at ~$28** while the human's
   **compounds to ~$45**, and builds an additive *sum* not a multiplier *product*. Only unrealistic wealth
   ($100/rd → 86.5%) brute-forces past (b). **Measured this pass: giving the rich10 engine just +2 reachable
   slots takes it 24% → 51% (+1.265 progress, t 5.96) — half the allocation gap is SLOTS**, the other half
   economy-compounding + product. rich10's 24–32% is a floor-on-allocation, not just a money ceiling.

4. **The winning board is a PRODUCT of multipliers, assembled early and mostly via the SHOP.** 86% of the
   37 jokers on winning final boards are multipliers (xmult/retrigger/copier); winners get their **first
   multiplier by ante 2–4** and acquire **73% of kept multipliers via the shop** (24 shop / 7 pack / 2
   other). The engine builds a locally-optimal *sum* of additive jokers, fills all 5 slots by ante 3, and
   then **cannot acquire** (board full + conservative swap) — the build freezes at whatever it had by ante 4.

5. **"Converts at rich10" replicates for BROAD shifts, fails for FEW-BIG-FLIPS — the sign-test breadth is the
   discriminator (measured this pass).** Of the three flagship rich10 conversions: **B3** has weak OOS support
   (magnitude halves); **the target model (§32) FAILED OOS** (winner's curse) — its in-sample was a few big
   asymmetric flips (sign 9/2); and **level_gain's +0.421, which I initially flagged as unconfirmed, REPLICATED
   cleanly OOS this pass** (I re-ran §15's exact commit pair at `BES_SEED_OFF=7`: progress **+0.377, t 2.14,
   p 0.032; sign 93/52, p 0.0009; wins 26→40, McNemar p 0.049** — all three metrics, the win effect *more*
   significant than in-sample). The discriminator held exactly as predicted: level_gain's in-sample was a
   **broad shift** (sign 84/57, 73/49 death-ante) and broad shifts replicate; the target model's few-big-flips
   did not. **So the rule is not "rich10-positive is unreliable" but "OOS-confirm it, and expect a broad sign
   test to survive and a narrow-but-large-mean one to collapse."** OOS replication remains mandatory before a
   ship. (This upgrades the project's banked level_gain result from "unconfirmed" to **confirmed real**.)

6. **The additive/target-model families are *mostly* — not fully — exhausted.** The strongest *closed*
   claims (§5s "joker valuation not mis-ordered", §31f "winners acquire multipliers diffusely via
   packs/tags") have holes: §5s conditions on jokers the human *bought* (blind to what the engine rerolls
   past), and the shop-provenance data shows multipliers arrive **73% via shop, not diffusely**. What is
   genuinely un-tested: (a) valuing slot *expansion*, (b) an integrated economy-generation policy, (c) a
   product (not sum) board-value function on the buy side. These are the frontier.

---

## B. SECTION SCORECARD

Each section scored **/10 for maturity × closeness-to-optimal**; gap-to-10 = exploitable headroom.
Ranked in the table by **headroom × tractability** (top = work here).

| rank | section | score | the specific headroom behind the score | tractability |
|---|---|---|---|---|
| 1 | **Shop & economy loop** | **4** | economy GENERATION: engine holds $1 at a2 vs human $7; over-fills board, spends to floor, money plateaus at rich10 (doesn't compound); no satisfice-then-invest structure | med (needs bundle/planner, not a lever) |
| 2 | **Slot / capacity management** | **4** | LESION huge (+0.732 baseline / +1.265 rich10; board full by a2 halts acquisition) BUT the reachable valuation fix measured only +0.021 (slot sources 0.3% — resource-limited, like money); a genuine correctness fix, not a winrate lever | LOW-med (headroom mostly unreachable by policy) |
| 3 | **Commitment / target planning** | **3** | planner commits to Full House ~always, yields real deck direction 0.3%; no product-scoring, no multi-channel target; oracle_plan null (41/40) | med (research rebuild) |
| 4 | **Joker / consumable valuation** | **6.5** | over-values SCALERS (median 9.34, winners churn them); under-values conditional amplifiers on *winner* deck-states (overlay gap) | **HIGH** (retune) |
| 5 | **Pack / tag channel** | **5** | opens 1.36 packs/ante vs human 6.10; gated by economy (pack×income interaction, not separable) | med |
| 6 | **Leveling channel** | **6** | ~3 median levels behind at a8 (15 vs 12) on current code; throughput gated by economy; +0.421 claim unconfirmed | med |
| 7 | **Objective / search architecture** | **4** | mean-progress proxy for a tail event; chaos-limited (sd ~1.9, MDE ~0.42); no forward search; agreement objective built but input-fragile | med |
| 8 | **Human-data alignment** | **6** | primary evidence is 7 wins / 1 loss (thin); "closed" conclusions carry selection biases; need more losses + same-state agreement | med (collect data) |
| 9 | **Skip / blind decisions** | **6** | over-skips (2.16/run) vs human ~0; noskip refuted at baseline; skip value should scale with stake (overlay) | low-med |
| 10 | **Measurement apparatus** | **7.5** | chaos-limited sensitivity; rich10-greenlight unreliable (OOS); agreement.py silently zeros on wrong input | med |
| 11 | **In-blind play** | **7** | winners discard-dig (4 discards) toward a target then clear in 1 hand; engine forfeits discards; indiscriminate dig refuted | low-med |
| 12 | **Boss handling** | **7** | 105 boss deaths at 0.69 clear-ratio — a symptom of weak build, not boss logic | low (upstream) |
| 13 | **Starting deck / stake** | **5** | single config (red/white); adequate for the target, not tuned per-stake | low |
| 14 | **World / sim fidelity** | **8.5** | validated vs real telemetry, deterministic, cross-process byte-identical; residual: milk-able deck density, a few spectrals | low (near-done) |

**Reading the scorecard.** The apparatus, world, and in-blind play are mature (7–8.5). The winrate headroom
lives in the **economy/slot/assembly nexus** (scores 3–4.5) — and those three are *one interdependent
system*, which is exactly why every single-lever cut into it has failed. The tractable entry points are
**slot valuation** (#2, concrete) and the **scaler retune** (#4, concrete); the big prize (#1 economy, #3
planning) needs the integrated build the roadmap keeps deferring.

---

## C. PRIOR RESULTS — CONFIRMED / QUALIFIED / INVALIDATED

### ✅ CONFIRMED (re-derived, holds under today's engine)
- **§5a A1 — valuation beats a scripted tier list.** Re-run: engine 2.5% vs expert 0.6%, Δ −0.898, p≈0.
- **§6 core — money binds hard / operating-point sensitivity.** Current-code: 2.5% → 24–32% (rich10), robust
  across pools. The *phenomenon* (winrate is dominated by whether the engine can afford to act) is real.
- **§5a A3 — joker slots bind.** +3 slots = +0.984, 5%→15%; board full by a4. Mechanism intact.
- **§31f H1 — winning boards are products.** Independently reproduced: 32/37 = 86% multiplier; the loss board
  is 2/5. Kept-rate multiplier 77% vs additive 13% reproduced (subagent + my raw recount agree exactly).
- **World fidelity (early antes).** real_vs_sim's "world validated" rests on antes 1–3 (large n, not
  survivorship-selected); holds. The tool self-discloses the late-ante survivorship confound.

### ⚠ QUALIFIED (true but the framing overreached; corrected here)
- **§5s "joker valuation is NOT mis-ordered — stop looking there."** *Selection-biased.* It conditions on
  jokers the human **bought**, so it is structurally blind to the amplifiers the engine **rerolls/saves
  past** (which never enter its sample). On the human's winning deck-states the engine recommends REROLL/SAVE
  past exactly the conditional multipliers winners keep (Photograph, Sock & Buskin) — e.g. "Reroll ($5)…
  need a better joker" with Sock & Buskin ($6) on offer and $20 in hand. ⟲ **But** my own sim-side check
  demotes this: on the *engine's own* decks it values retriggers fine (median 7.90) and passes affordable
  amplifiers only 26% (14% early). So the mis-valuation is a **live-advice/overlay gap on winner deck-states**,
  not a large autonomous-winrate lever. Net: "valuation is directionally right" survives for *autonomous*
  play; the "stop looking" is too strong for the *overlay*.
- **§5o "winners are xmult-poor early / sequencing inverts."** *Blind spot.* It tracked raw `xmult` cat only.
  The early multiplicative pieces winners actually grab (a2–a4) are **retriggers** (Hanging Chad, Sock &
  Buskin), which §5o didn't count. "Economy/base first, xmult later" is really "economy/base + cheap
  retrigger amplifiers early, raw xmult scalers later." Refines, doesn't refute.
- **"Human 2–4× richer" vs "median $1 in both at ante 2."** Both are artifacts of *which dataset*. The
  "$1 in both" world-validation was mixed-vs-mixed (`bes_runs.jsonl`); the **winners hold $7 at a2** — they
  ARE the fat right tail. So the economy gap is real and is a *policy* gap (how winners get rich), consistent
  with the `rich10-is-not-the-operating-point` correction.
- **§31f "winners acquire multipliers DIFFUSELY via packs/tags, not shops."** *Overturned on provenance.*
  Kept-multiplier channel across 7 wins: **shop 24 / pack 7 / other 2 = 73% shop.** The "diffuse" claim came
  from a *different* measurement (the immediate next purchase after a save is a multiplier only 37%); the
  provenance of the pieces that actually end up on winning boards is shop-dominant. This weakens §32's
  argument that the residual gap is pack-throughput.
- **The leveling gap.** Quoted as "a8: 18.6 vs 7.7" (means, inflated by 32–41-level outlier runs). On
  current code the **median** gap is 15 vs 12 = ~3 levels; level_gain narrowed it. Real but smaller.

### ✅ CONFIRMED THIS PASS (was flagged suspect, now resolved)
- **level_gain's "+0.421 at rich10" is REAL — it replicated OOS.** I initially downgraded it to "unconfirmed /
  likely winner's-curse" (§15 said it was never OOS-tested and it's a bundle with a churn-signature win effect
  — the target model's exact pre-OOS profile). But I RAN the missing test: §15's commit pair (0e5596a vs
  2953b15) re-run at rich10 `BES_SEED_OFF=7`, paired n=160 → **progress +0.377 (t 2.14, p 0.032), sign 93/52
  (p 0.0009), wins 26→40 (McNemar p 0.049)** — a clean replication on all three, with the win effect *more*
  significant OOS than in-sample. The discriminator I predicted held: level_gain's in-sample sign test was
  **broad** (84/57) unlike the target model's narrow 9/2, and breadth predicts replication. ⇒ **the project's
  banked +0.421 is a real winrate result.** Arms on disk: `sim_out/pd{base,play}_r7.jsonl`.

### ❌ INVALIDATED / DOWNGRADED (should not be relied on as stated)
- **"The revert graveyard was populated almost entirely by baseline nulls" as a reason to re-litigate it.**
  The forensic tool-audit found **no measurement bug** in the current diagnostic set (post-§32a they are
  defensive), and the mechanism-based reverts (swap-damp, xmult-floor, hoard, ecap) stand. §6 does not
  resurrect them wholesale — it only says *test valuation levers at rich10*, and the target-model result
  shows even that is unreliable without OOS.
- **`agreement.py` / `blind_outcome.lua` headline numbers (over-buy 24%, over-reroll 12%, "human plays
  0.32x / milks the blind").** *Unverifiable from the repo* — they consume a generated `bes_fixtures.jsonl` +
  `picks.jsonl` that are **not checked in**, and `agreement.py` reads record kinds (`reroll`/`pack_pick`/
  `voucher_gain`) that don't exist in the committed data, so re-running it on the live winners would silently
  zero those channels (a latent bug-#2). My raw-record check contradicts the "milk weak hands" story:
  winners use **1 hand (mode, 66%)** but **~4 discards** per blind — they **discard-dig toward a target,
  then clear in one**, not "play many weak hands." The in-blind narrative needs re-grounding on raw records.

---

## D. HUMAN-DATA DEEP-DIVE (primary evidence, mined from raw records)

The 8-run capture (`data/bes_runs_live_2026-08-12.jsonl`, 7 wins / 1 loss) is the project's most valuable
asset. New findings from a per-run reconstruction (`scratchpad/human_assembly.lua`, `reroll_past.lua`,
`sim_amplifier.lua`):

**D1. The assembly timeline (new).** Winners' first kept multiplier lands at ante **2,2,2,2,3,3,4**. The
pieces are cheap, common, repeatedly-offered shop jokers — **Hanging Chad in ~every win, Photograph 5/7,
Sock & Buskin 3/7** — plus later raw-xmult (Cavendish, Hologram, Acrobat) at a5–a7. Provenance of kept
multipliers: **73% shop.** Boards end 4–5 multipliers out of 4–6 slots.

**D2. Two winning modes, one invariant.** U8UE74EN won ante 9 with only **7 hand-levels** but a **4/4
all-multiplier board**; 4NN97569 won with **41 levels** on a 4/6 board. Heavy leveling substitutes for a
weaker product and vice-versa, but **every** winning board carries the multiplier product. The loss
(X3L32ZEA) had **neither** — a 2/5 scattered board, 4 levels, dead at ante 5 holding **$52**. Resources were
not the constraint; **conversion to a product** was — the engine's own failure mode, executed once by a human.

**D3. The economy trajectory (re-derived).** Human vs sim-baseline per-ante median: $ **7/23/22/45→52** vs
**1/9/18/25→29**; jokers **1/4/5/5** vs **3/5/5/5**; levels **0/0/2/…15** vs **1/1.5/3/…12**. Winners are
2–7× richer early *and* hold fewer jokers early — they bank and compound. This is the economy-generation gap.

**D4. In-blind is discard-digging, not hand-milking (corrects the record).** Over 102 winning blinds:
**hands_used 1.70 (mode 1, 66%), discards_used 3.36 (mode 4).** Winners spend discards to assemble the hand,
then clear in one. The engine forfeits discards once a clear is locked (§5p). The lever is **targeted**
digging (the indiscriminate `dig` probe was −0.110); the winner digs toward a committed hand.

**D5. The reroll-past pattern (the sharpest overlay gap).** Of 65 shop records offering a winning-multiplier
joker, the engine's top action is **REROLL 25% / SAVE 31% = 56%**, buying the amplifier in only ~3 cases.
The same joker (Sock & Buskin) is priced "+189% of a boss hand" on a supporting board but rerolled-past on a
weak one — board-conditional MC valuation is *correct locally* but creates a **chicken-and-egg trap**: the
amplifier is worth little until the build exists, so the build never forms. Winners break the cycle by buying
the amplifier on spec. (⟲ Sim-side this is milder — see the §5s qualification — so it is primarily an
overlay/advice finding, rich10-class.)

---

## E. METHODOLOGY AUDIT

**E1. The operating-point rule (§6) — core solid, practical use unreliable.** The interaction (code ×
operating point, p ≈ 0.0102) rests on a 6-commit bundle on a shared seed family (approximate SE, per the
doc's own caveat). The *phenomenon* is re-confirmed hard on current code (2.5%→24–32%). **But** the practical
prescription — "greenlight a valuation lever if it converts at rich10 in-sample" — needs OOS confirmation, and
the track record now shows **the in-sample sign-test BREADTH predicts OOS survival**: B3 weak-OOS-pass (broad),
**level_gain OOS-PASS (broad, 84/57 → 93/52, confirmed this pass)**, target-model OOS-**fail** (narrow, 9/2).
⇒ Keep §6 as a *diagnostic frame*; require **OOS replication before any rich10 ship**; a broad in-sample sign
test is the leading indicator that it will hold, a narrow-but-large-mean one that it will collapse.

**E2. rich10 is a ceiling, not the operating point — but the mod serves a rich human.** The
`rich10-is-not-the-operating-point` correction is right for *autonomous* winrate (the engine must earn its
own money; baseline is the honest number). **Yet the live overlay advises a human who sits at the rich10 end.**
These are **two distinct deliverables** that the docs conflate: (A) autonomous baseline winrate (economy-bound)
and (B) advice quality to a rich human (valuation-bound). B3/level_gain/target-model/amplifier-credit are all
type-(B) levers. **Recommendation: score and optimize A and B separately** (see G1).

**E3. The frequency ceiling — real, but it is about SPECIFICITY not an absolute 5%.** One joker fires ~5% of
runs; a *category* fires far more. The proposed amplifier/slot levers touch categories: an affordable
amplifier is offered in **19% of sim shops** — comfortably batch-viable. Always screen firing rate first
(the rule holds), but "5%" is the single-joker floor, not a universal cap.

**E4. World fidelity — validated for early antes; do not over-extend to late.** The subagent confirms
real_vs_sim reads valid fields and self-discloses the survivorship confound. Winners-vs-baseline late-ante
gaps (levels, $) are **policy**, not world. The "sim is a poorer world" hypothesis stays dead.

**E5. The ceiling, finally measured under current code — the resource ladder.** Expert-script 0.6%
(valuation not harmful). The resource ceilings give a clean "what each resource is worth" ladder (partial n≈20,
will firm up):

| policy | winrate | Δ vs prior rung | what it adds |
|---|---|---|---|
| baseline (autonomous) | 2.5% | — | the engine earns its own money |
| rich10 (+$10/rd) | 24–32% | +~22–30pp | modest exogenous income |
| **rich10 + 2 reachable slots** | **51%** | **+~27pp over rich10, from SLOTS alone** | at rich10 the binding constraint is SLOTS, not money |
| **the human, at ~rich10–25 wealth** | **87.5%** | **+~55pp over rich10** | **good ALLOCATION** (the prize) |
| rich (+$100/rd) | 86.5% (83/96) | +~57pp over rich10 | *unrealistic* income brute-forces allocation |
| everything (+$100, 8 slots, top-pool) | 97.9% (94/96) | +~11pp | slots + joker quality close the last gap |

Three reads. (1) **The world doesn't cap winrate** (everything → ~98%). (2) **The human at ~rich10 wealth
(87.5%) matches the engine at 10× the income (rich $100/rd, 86.5%)** — the human's *allocation* is worth as
much as a **10× money subsidy**. (3) **The allocation gap decomposes cleanly, and half of it is SLOTS:** at
rich10, +2 reachable slots alone takes 24% → 51% (**+27pp**), and the remaining 51% → 87% (**+36pp**) is
economy-compounding + the multiplier product + deck-shaping. So the reachable prize is **P1 (slots, ~half the
gap, and measured this pass at +1.265 progress) + P2 (economy compounding) + P3/P4 (the product board)** —
*not* more money (rich is unreachable). §5n's `rich` was 72.5% at *old* code; current-code 86.5% shows
conversion improved, but allocation at realistic wealth is the reachable prize.

**E6. The chaos wall (§5z envelope) — the deepest measurement limit.** 85% of seeds flip outcome under tiny
policy perturbations (sd ~1.9, MDE ~0.42 for shop-loop changes). This is why every broad lever ties, and why
the project's only trustworthy verdicts are low-cascade/late-firing. It is a genuine ceiling on the
mean-progress objective and the strongest argument for the **agreement objective** (denser, less chaotic).

---

## F. RANKED FORWARD PLANS

> Each: **mechanism · expected effect · how to measure · kill-criteria.** Nothing here is shipped in this
> pass. All burden-of-proof rules apply (paired n≥160, MDE stated, worktree per arm, OOS for rich10 ships).

### P0 — CONFIRMATORY RE-RUNS
- **✅ DONE — OOS-replicate level_gain's +0.421 rich10.** Re-ran §15's commit pair (0e5596a vs 2953b15) at
  rich10 `BES_SEED_OFF=7`, paired n=160: **progress +0.377 (t 2.14, p 0.032), sign 93/52 (p 0.0009), wins
  26→40 (McNemar p 0.049)** — clean replication on all three, win effect *more* significant than in-sample.
  **level_gain's +0.421 is CONFIRMED real** (§C). It is the project's most solid winrate result. Arms:
  `sim_out/pd{base,play}_r7.jsonl`.
- **✅ DONE — the ceilings** (`rich` 86.5%, `everything` 97.9%) — see §A.

### P1 — SLOT-EXPANSION VALUATION (⭐ huge LESION, but implementation shows it is resource-limited)
- *The lesion is real and huge, at BOTH operating points:* +2 REACHABLE slots moves
  **BASELINE 2.5% → 14.4% (+0.732 paired, t 5.51, McNemar 4→23, p 0.0002)** and **rich10 24% → 51% (+1.265,
  t 5.96, McNemar 24→49, p 0.0001)** — `sim_out/ceil_slots7`/`ceil_rich10_slots7` vs `base_31f`/`baser_31f`.
  **Even the baseline +0.732 exceeds the project's entire shipped historical arc (+0.487)**, and it improves the
  *autonomous* number — this is NOT a rich10-only overlay lever. The effect is *larger* with money (money×slots
  are complementary: you must afford to fill the slots), matching §5a A3's baseline +3-slot = +0.984. **The
  binding constraint at every wealth level is SLOTS:** the engine fills 5 by ante 2 and freezes; given room it
  keeps acquiring the compounding pieces.
- *Human-data corroboration (not just a lesion):* **4 of the 7 winning boards run 6 jokers** (GU73QPLY,
  4NN97569, IET2K8M7, 67HVNBZB) — those winners *expanded past 5 slots* via a negative edition / Antimatter.
  The engine, capped at 5 and full by ante 2, never does. So the winners themselves treat slot expansion as a
  build move; the lever is human-aligned.
- *The clean lever:* the **reachable** in-game slot sources — **negative-edition jokers** and the **Antimatter
  voucher chain** — are valued as ordinary jokers/vouchers, not as **+1 permanent capacity** (the lesion says
  that capacity is worth ~0.6 progress each). Add a large, ante-scaled capacity premium so the engine *acquires*
  slots it currently passes. This *adds* capacity (opposite of the refuted ecap board-cap) and has never been
  probed as a valuation lever.
- *⭐ IMPLEMENTED + MEASURED (2026-08-25) — and the ceiling is NOT reachable by valuation.* Fixed the genuine
  correctness bug: a negative-edition joker is slot-FREE (+1 permanent slot) yet was priced at a flat **0.5**
  while the identical Antimatter slot is **~8-12** (a 16x inconsistency). Built `Eval.negative_slot_fv(gs)`
  (board-aware: ~a future joker when slots bind, tapered by runway, discounted when slots are free), wired into
  the shop + pack buy-valuation (worktree `.claude/worktrees/slotfix`; tests 1046 pass). **Paired baseline
  n=160 vs `base_31f`: +0.021 (t 1.09, p 0.28 n.s.), 155/159 TIED, 0 seeds died earlier, wins 4→4.** The screen's
  warning held exactly: negative editions are 0.3%/joker, so the fix fires in only ~2.5% of seeds. **⇒ The huge
  slot LESION (+0.732) is largely NOT reachable by valuation — it is a RESOURCE the world grants rarely, like
  money.** *Disposition:* **KEEP on the correctness rule** (non-negative, human-aligned — 4/7 winners expand
  slots, improves the overlay's advice to grab a negative joker for the free slot), but it is a *fidelity* fix,
  not a winrate lever. **rich10 confirms it: +0.009 (t 0.98, p 0.33 n.s.), 155/159 TIED, wins 39→38 (McNemar
  p 1.0 = noise)** — clean at BOTH operating points; the frequency cap dominates regardless of money (binding
  constraint is source-availability, not affordability). **LANDED in the main tree** (correctness rule),
  uncommitted for review. The reachable slot avenues that remain are all frequency-limited too (Hone/Glow-Up to
  2-4x the negative rate, aggressive Antimatter/Negative-tag pursuit) — worth pricing correctly, but none
  capture the lesion. **The reachable prize is the OTHER half
  of the allocation gap (economy compounding + product board + shaping — P2/P3/P4), not slots.**
- *⚠ The riskier half (do NOT bundle in blindly):* biasing the engine to *hold an open slot* through ante 3 is
  **ecap-adjacent**, and ecap (cap the early board) was refuted hard (−0.169 baseline, **−0.945 at rich10**),
  because a smaller board earns less income. Only pursue slot-reservation if the *expansion* half proves out
  AND it can be shown not to shrink early board power — treat it as a separate, evidence-gated experiment, not
  part of the core P1 lever.
- *Measure:* run `slots6`/`slots7` to size the reachable ceiling; measure neg-edition/Antimatter offer
  firing-rate; then the capacity-premium arm paired n≥160 at **baseline** (capacity is not a preference, so §6
  predicts it can express at baseline) with a rich10 confirm.
- *Kill:* `slots7` (reachable +2) is itself near-null → the reachable slot headroom is small and P1 is capped;
  OR the premium fires (offers ≥10%) but the arm is baseline-null → capacity valuation isn't the lever.

### P2 — ECONOMY-GENERATION POLICY BUNDLE (highest headroom; low-med tractability)
- **⚖️ P2a TESTED → MECHANISM FIRES, WINRATE NULL OOS → KEPT AS CORRECTNESS (2026-08-26, commit 6db29eb).**
  Diagnostic REFRAMED the gap: money is not the late constraint — it plateaus at a median **$25–29 idle from
  ante 5–8** while under-levelled (12 vs 18.6); that idle ~$25 ≈ **8 planet-levels = the leveling gap held in
  cash** (§30). Root cause: `interest_penalty` used a flat `INTEREST_HORIZON=3`, but interest you won't collect
  isn't a cost (at ante 8 the run ends on the clear). `SA.interest_horizon(gs)` caps it by rounds-remaining
  (unchanged ≤ante 5; 2.0/1.0/0.4 at ante 6/7/8 — antes ≤5 untouched, so NOT the refuted ecap §28). Mechanism
  **confirmed** (ante-8 $29→$26, lvl 12→13) but winrate **null**: baseline in-sample +0.014 sign 10/3 (p 0.096)
  did NOT replicate OOS → +0.010 sign **5/4 (p 1.00)** — winner's-curse mean on big-win flips. **⇒ §30a
  GENERALISES: late reserve-conversion is too late; the human's levels compound from antes 3–7.** Kept anyway
  (undisputable accounting fix + better human overlay + sim-non-negative over 320 seeds — like P4 income_frac).
  Arms: `sim_out/p2a_{ctrl_base,treat_base,ctrl_b7,treat_b7}.jsonl`.
- **⇒ P2 economy-by-shop-policy is essentially CLOSED (its own Kill criterion met):** late half (P2a)
  fires-but-null; early half (ante-2 $1 vs $7) is ecap-refuted (§28) + poverty-trap-structural. The leveling
  gap must be closed EARLIER (antes 3–7) — that is P4 (product board / compounding), not more economy levers.
- *Mechanism (original plan, now superseded by the P2a finding):* implement the winner's economy policy (`human-economy-policy` memory) as a **co-calibrated
  bundle**, not single levers (which all failed because the surface is interaction-dominated and baseline
  starves them): (a) **satisfice** — ensure sufficiency for the upcoming 1–2 blinds, then (b) allocate every
  surplus dollar to compounding (money tarots — Hermit/Temperance/Fool; interest to cap; econ jokers), and
  (c) don't fill the 4th/5th slot early. Gate econ shadow-value by *remaining need* (sell econ once scoring is
  solved).
- *Expected:* lifts the ante-2 bankroll toward the human's $7, which is the precondition for pack/leveling
  volume — the thing rich10 supplies exogenously.
- *Measure:* bundle vs baseline, paired n≥160 baseline; watch the **ante-2/3 median $** move (the mechanism),
  not just progress. Screen each component's firing rate.
- *Kill:* bundle null at baseline **and** ante-2 $ unmoved → economy is not reachable by shop-policy alone and
  the problem is genuinely the in-blind money-card density (deck-shaping, P4).

### P3 — SCALER-DEMOTION + AMPLIFIER-CREDIT RETUNE (part 1 DONE ❌ null; part 2 open)
- **⛔ PART 1 TESTED → NULL AT BOTH OPERATING POINTS → REVERTED (2026-08-26, commit 0ed6d1b).** Demoted
  additive scalers (`scaling_mult`/`scaling_chips`) from `BP.is_core` (CORE_KEEP 2.5 → SCORER_KEEP 1.2).
  Paired n=160 from pinned worktrees: **rich10 +0.020 (p 0.67, 144 tied, wins 38→40); baseline +0.015
  (p 0.19, 156 tied, wins 4→4)** — trustworthy nulls (MDE ~0.03–0.13). The predicted "high-frequency,
  fires ~every shop" was WRONG: `is_core` feeds only `keep_bias` (SELL-side), so it moved just 4–16/160
  seeds. Reverted as a policy change without positive evidence (protect-a-fed-scaler is defensible design,
  not a provable bug). Extends §31g (buy-side scaler null) with a sell-side null → **scaler per-decision
  family closed on BOTH sides.** Arms: `sim_out/p3_{ctrl,treat}_{base,rich}.jsonl`.
- *Mechanism (two parts, both from §31f + this audit):* (1) ~~demote `scaling_mult` from `BP.is_core`~~
  (done, null — above); (2) **still open — on the buy side, credit conditional
  retriggers/copiers** (Hanging Chad, Sock & Buskin, Photograph, Blueprint) with a forward-product term when
  the board is core-deficient, so the engine stops rerolling past them on weak boards (D5). This is the
  *credit* side, distinct from the *keep* side just tested; it overlaps P4's product-scorer and is best folded there.
- *Expected:* a small autonomous effect (the sim values amplifiers OK already) but a real **overlay/advice**
  improvement on winner deck-states — a type-(B) lever.
- *Measure:* baseline + **rich10 with mandatory OOS** (this is the class that fails OOS); also score on the
  human same-state agreement (does it flip the D5 reroll-pasts toward the winner's buy?).
- *Kill:* OOS-null at rich10 (expected base rate) → keep only if the same-state agreement improves (overlay
  value) with zero baseline harm; otherwise revert. (§31g damp-side was null; this is the credit side, untested.)

### P4 — SUPERMODULAR BOARD-VALUE + MULTI-CHANNEL TARGET (BOUNDED WEAK on the cheap screen — not built)
- **⛔ VERDICT (2026-08-26, commit 298c2ab): the present-board product-scorer is BOUNDED WEAK — the cheap
  agreement/flip screen the plan promised, achieved WITHOUT a scorer build or sim arm.** On the newer 14-win
  corpus: supermodular flip precision **57%, +8/85** (replicates Aug-12); a completion-AWARE product damp
  (gated on `needs_xmult`, not blunt role) measured on the agreement objective moved the over-buy
  `eng_buy_human_save` **264→263 (unmoved)**. Confirmed 3 ways (flip proxy 57% / damp ~0 / §31g sim-null) that
  present-board product structure does NOT explain the human's saves; dir-2 refuted again (next-buy multiplier
  **33% < 40%** base). **The residual is DYNAMIC/target-directed** (save for interest/deck-shape/future
  multiplier) — not a present-STATE scorer's to capture. ⇒ redirect to the LEARNED WIN-PROBABILITY model (P5
  Phase B), the only thing that can price dynamic target-directed play. Apparatus (agreement objective) now
  hardened + validated — the durable win of this fork.
- *Mechanism (original plan, now bounded-out above):* the missing primitive — score the board as a **product** (copiers × xmult × retriggers), so a
  marginal additive reads as worthless *because it doesn't multiply the build*, and a target expressed as a
  **set of pieces to assemble** across channels (shop/pack/tag) with slot reservation. This is the §31e
  research fork, but note its two bounding nulls tested only the *present-board damp* (§31g) and a *generic
  pack-EV credit* (§32) — a genuine product-scorer on the buy side is untested.
- *Expected:* the only thing that can represent "the win condition is a product," which every additive lever
  provably cannot.
- *Measure:* judge by the **agreement objective** (immune to seed chaos), not run-outcome, until it clears
  that screen; then a baseline arm.
- *Kill:* if a product-scorer's picks don't move toward the winners' on the same states, the whole research
  fork is mis-aimed (a much cheaper verdict than a sim arm).

### P5 — OBJECTIVE & APPARATUS UPGRADES (enabling)
- **Tail-weighted verdict** (reach-7/reach-8 alongside mean-progress) — winning is a tail event the mean
  under-reports (§7). Cheap; do next batch.
- **✅ DONE (2026-08-26, 298c2ab): hardened the agreement objective.** `agreement.py` `load()` now returns []
  on a missing file + 3 loud guards (empty input / empty fixture-pick join / all-channels-zero) → errors
  instead of silently zeroing. Inputs `bes_fixtures.jsonl`+`bes_runs.jsonl` live in the LÖVE save folder
  (`%APPDATA%/Balatro/`) — a NEWER 14-win corpus; validated end-to-end (BLIND 55% / PACK 20% same / SHOP
  over-buy 25%). Pipeline: `luajit tools/replay_fixtures.lua <fixtures> picks.jsonl` → `python tools/agreement.py
  <fixtures> <runs> picks.jsonl`. ⚠ The corpus itself is NOT checked in (26 MB); it lives in the save folder.
- **Learned win-probability model** (Phase B) — **⚖️ BOUNDED WEAK as a denser OBJECTIVE (2026-08-26,
  `tools/winprob_headroom.py`).** On the per-ante features already logged, `capacity` alone gives test-AUC
  ~0.70–0.81 at every ante (baseline 17 wins/640 AND rich 78 wins/320); a 23-feature logistic adds ≈0 on
  average and overfits the rare positive class. `capacity` ≈ the sufficient statistic and is what `pace_margin`
  already uses ⇒ replacing pacing with a learned classifier won't move much, and 2.5% win-rate starves it of
  positives. ⚠ Bounds the OBJECTIVE use only; a learned **rollout value inside a planner/search** (MCTS —
  intentionally deferred) is a different, larger, un-bounded use.
- **⇒ Tractable frontier exhausted; the one un-bounded direction is the deferred PLANNER/SEARCH (MCTS) with a
  learned rollout value** to price DYNAMIC target-directed play (the residual the agreement screen localized).
  **NOW SCOPED: `MCTS_PLAN.md` (re-scoped 2026-08-26).** It OVERTURNS the 2026-07-14 "supply-ceiling / MCTS
  dead" verdict (refuted by the human's 87.5% on identical inputs + rich10 24% + the line-finding frame), and
  gates the whole build on **Phase 0 — a retrospective shop-stream oracle** (do winning lines EXIST in lost
  runs' actual offer streams?): the cheapest, highest-information step, never run, which alone green-lights or
  kills the architecture. Phases 1–3: sim-as-environment + capacity leaf value (validated AUC 0.8 this pass) →
  depth-2 expectimax over the shop stream, screened on the agreement objective → learned rollout value.
- **✅✅ Phase 0a RUN → THE GATE PASSES (2026-08-26, `tools/stream_oracle.lua`).** Of 623 lost baseline runs,
  **70% were offered ≥2 affordable multiplier keystones + leveling** yet acquired only 1.46 of 2.75 offered;
  rich10 **92%**. ⇒ the winning PIECES are in the observed stream in 70–92% of losses — **the 2.5% ceiling is
  a POLICY (assembly) gap, not supply; the 2026-07-14 supply-ceiling is refuted on the sim's own runs and the
  MCTS direction is GREEN-LIT.** (Honest caveat: proves piece-availability, not yet a full survivable line —
  that is what the search itself tests.)

---

## G. BIGGER IDEAS / REFRAMINGS

**G1. Split the objective into the two deliverables the project actually has.** *Autonomous winrate at
baseline* (economy-generation-bound, currently 2.5%) and *advice quality to a rich human* (valuation-bound,
the live mod's real job). Almost every "inert at baseline / positive at rich10" lever is a type-(B) win being
judged by a type-(A) metric. Concretely: keep baseline self-play as the honest autonomous headline, **and**
stand up a type-(B) metric — the same-state agreement with the winning human — as the primary judge for
valuation/overlay changes. This dissolves years of "logical fix, no effect" confusion and gives the overlay
its own scoreboard.

**G2. Deck-shape as a first-class value axis.** Winners spend free pack-picks on *money* and *shape* (§5s),
converting suits/ranks and thinning so their committed hand becomes consistent and their amplifiers become
high-value. The engine prices only what a card does *today*. A `shape_credit` that values a pick by the
**probability lift it gives the committed hand** (the way `BP.planet_credit` already values leveling by the
commitment — the one channel where engine and winner agree exactly) is the natural completion of the
commitment→valuation feedback loop, and it is the thing that would make the amplifiers the engine already
owns actually fire.

**G3. Treat joker-slot count as a strategic build axis, not incidental.** The single largest resource lever in
the project's history (+3 slots) has no corresponding *policy* that pursues slots. Negative editions and the
Antimatter chain should be first-class build targets (P1).

**G4. A real forward-search planner, judged by agreement not run-outcome.** The seed chaos (85% flip rate)
makes run-outcome an unusable judge of a planner; the agreement objective is not chaos-limited. Build the
supermodular-target planner (P4) and judge every step of it by whether it moves toward winners' choices on
captured states — the one un-confounded signal the project has.

**G5. Question the whole "self-play winrate is the goal" frame — for the overlay.** The mod's success is a
*human* following it winning, and that human is rich and shapes their deck. The most valuable thing the engine
can do may be to *advise the human's economy/shape/assembly decisions well*, which is measurable **today**
against 7 wins without any sim batch. The sim self-play is the right object for the *autonomous* research
question; it is the *wrong* object for the shipping product, and separating them (G1) is the highest-leverage
reframe available.

---

## H. DOC HOUSEKEEPING (performed this pass)

- **`GRAND_AUDIT.md`** (this file) is the new entry point. `CLAUDE.md` and `NEXT_SESSION.md` pointers updated.
- `WINRATE_V3_PLAN.md` (§1→§32c), `WINRATE_AUDIT.md`, `WINRATE_AUDIT_v2.md` retained **unabridged** as the
  audit trail — every §-citation above resolves into them. Do not delete; they are the provenance.
- New tooling this pass: `scratchpad/human_assembly.lua`, `reroll_past.lua`, `sim_amplifier.lua`,
  `human_traj.lua` (assembly/economy/valuation mining); new arms `sim_out/ceil_expert.jsonl` (+ `ceil_rich`,
  `ceil_everything` pending).

---

*Provenance: HEAD f74ec56; tests 1046 pass; re-derived 2026-08-25 from on-disk `sim_out`/`data` + fresh
paired runs from the pristine tree. Numbers marked ⟲ are self-corrections made during the audit.*
