# WINRATE_V4_PLAN.md — the BUNDLE breakout (2026-09-18)

> **One-line thesis.** The engine is at **2.5%**; an expert human under the *same rules* wins **~87.5%**.
> The whole gap is policy, and it is **supermodular** — the fixes multiply, so no single lever shows a
> measurable winrate signal, which is exactly why two years of single-lever tuning bounced and reverted.
> This plan **builds the fix as ONE bundle and measures it on the DENSE agreement corpus**, not on chaotic
> baseline winrate. It supersedes the single-lever method for this objective; it does not touch the
> autonomous-ceiling verdicts in `GRAND_AUDIT.md` (which concern the *learned value function*, a different,
> compute-bound path that stays declined).

---

## 🃏 IN-BLIND PLAY (2026-09-18) — owner: live play is "nowhere near optimal"; sim chooser is not the gap

Owner (reliable — found the true 8.1% winrate) reports the F11 self-player's live in-blind play is **nowhere
near optimal**, contradicting the archived "regret 0.0076 / play is solved" claim. Also: expert human
(DoctorSpectred-tier) hits **>98% GOLD-stake winrate on the hardest decks**, so near-100% is a real target
(the winrate is NOT variance-capped ~87%). Both noted in CLAUDE.md.

**Measured the in-SIM play regret (`tools/play_regret.lua`, 30 seeds, 461 plays):** overall regret **1.2%**;
on must-maximize hands (max play can't clear in one) it picks the **MAX-score play 94%** of the time (mean
regret 1.9%). So **the sim's play CHOOSER is near-optimal by its own scorer** — the old 0.0076 reproduces.

**⇒ The live-play gap is NOT the chooser leaving score on the table in-sim. It is one of:**
1. **`state_extraction` FIDELITY (prime suspect):** the sim builds `gs` correctly (chooser looks fine), but
   live, `state_extraction` (the only file that reads `G`) may feed wrong/missing card or joker data →
   `HandEval` plays on garbage → bad play, invisible to every headless test. This is a **documented recurring
   class** (the Mouth bug: `played_hand_types` unpopulated live killed a run; see `churn-and-live-inert-boss`
   memory). Any gs field the play path READS but `state_extraction` doesn't WRITE (or mis-reads) is dead live.
2. **`HandEval` scorer fidelity vs real Balatro** on complex interactions (retrigger/card-order/held/seals) —
   the winning-board pieces (Hanging Chad, Photograph, Sock & Buskin) are exactly the retrigger/order-sensitive
   ones most prone to mis-modeling; a mis-rank makes the engine pick the wrong "best" play live.
3. Satisficing philosophy (play to barely-clear + keep cards) looking passive — by design, minority of hands.

**This REOPENS the winrate ceiling in a non-compute-bound direction:** if live play is materially sub-optimal
from a fidelity bug, the "supply×survival / dies at ante 3.7" pattern is partly a *play* artifact (bad plays
fail clearable blinds → die early → low exposure), fixable deterministically.

### ✅ RESOLVED (2026-09-19) — scoring-play is near-optimal; the DIG objective is NOT the lever; new frontier = MONEY-FARMING

The "located the dig objective" hypothesis below was BUILT, MEASURED, and REVERTED. Full arc:
- **`HandEval` is a faithful scorer** — 7/7 canonical Balatro level-1 hands scored exactly (`/tmp/hefid.lua`).
  So the sim's scoring is correct; there is no gross fidelity bug in the bare-hand scorer.
- **The play-subset chooser is near-optimal** — 94% max-score on must-maximize hands (`tools/play_regret.lua`).
- **The ante-1 dig is at a clairvoyant ceiling** — engine 78% one-hand vs a future-knowing greedy reference's
  75% (`tools/first_blind_optimal.lua`). The ~22% two-hand clears are largely the base deck's limit (even
  knowing all draws you often can't make 300-in-one), NOT engine error. First blind clears **99.5%** overall.
- **The target-aware dig (clear-probability vs mean-score) measured NEUTRAL** on the isolated first blind
  (79.8%→78.2%, even at 3× samples) AND on full runs (paired n=160: 8.1%→8.8%, sign 80/74 — dead even).
  REVERTED both times. Mean-score prefers timid low-ceiling digs, but switching to clear-probability didn't
  convert — the first blind is too easy to discriminate dig quality, and full runs showed no gain.
- **The live self-player is NOT a degraded path** — it runs the full engine at `BES_SAMPLES=80` (main.lua),
  more samples than the sim. Owner: assume autoplay actuation is fine for now.

**⇒ Pure scoring-play ("which cards clear the blind") is solved — stop re-searching it.** ⭐ **THE OPEN
FRONTIER (owner, 2026-09-19): JOINT MONEY-FARMING + SCORING.** Optimal play milks ECONOMY *while* clearing —
Gold cards/seals, Lucky, editions, and econ jokers (Faceless/Mail/Reserved Parking) held/played to MAXIMIZE
$ subject to still clearing; the $1/unused-hand + farmed $ compounds into the next shop where every dollar
decides survival. None of the tests above measure this joint objective. Probe it in `engine/discard_fuel.lua`,
`engine/hold_fuel.lua`, `HandEval.play_econ`, and the MILK/DIG paths in `engine/decision_engine.lua`. New
diagnostics from this arc (kept): `tools/first_blind_fast.lua`, `first_blind_optimal.lua`, `play_regret.lua`,
`loss_diagnosis.py`, `data_scaling_probe.py`.

### (superseded) LOCATED (2026-09-18) — the DISCARD/DIG objective, not the play chooser

Confirmed on ante-1 small blind (`tools/first_blind.lua`, ranks visible): the play-subset chooser is fine,
but the DISCARD decisions are the suboptimal part (owner corroborated all three: fiddles instead of playing,
pitches wrong cards, clears in 2 when 1 was possible). **Root cause, located in `engine/discard_value.lua`:
`DiscardValue.expected_score` (line 109) values a candidate discard by the EXPECTED MEAN SCORE of the next
best-play after redraw — NOT by the probability of CLEARING the target.** These differ decisively for
clearing: to reach 300 you must maximize `P(best_play ≥ remaining)`, which favors the HIGH-CEILING chase
(pitch a low card, draw toward a HIGH flush/full house), while maximizing mean score can prefer a safe hand
that never reaches 300. This is exactly owner's flush example: the engine keeps the 2♥ because it raises the
flush's mean/probability, ignoring that a 2-flush does not score 300. The dig is **target-blind.**

**THE FIX (target-aware dig):** rank candidate discards by `P(post-redraw best_play ≥ remaining)` (clear
probability / margin), tiebroken by expected score — so the dig chases a hand that actually CLEARS, pitching
low cards even when they match the chased suit/type. Also re-check the discard-vs-play threshold so it does
not "fiddle" when playing-now + a cheap second hand clears. **METHOD (owner's design):** optimize on the
isolated ante-1 small blind (`tools/first_blind_stats.lua` — fixed 300 target, fixed red-deck 4-discard
starting deck, only the draw varies; objective = maximize ONE-HAND clears / minimize hands-to-clear), because
the play/discard logic is SHARED across all blinds, so a fix propagates everywhere. Then CONFIRM on full-run
winrate (don't overfit to the base deck). This is deterministic and non-compute-bound — the real lever.

---

## 🎯 DATA-SCALING PROBE (2026-09-18) — path B go/no-go: NO-GO on attainable data

`tools/data_scaling_probe.py` — the one measurement never done: does the learned piece-level value's
**OOS** AUC keep RISING with more training wins (⇒ more data fixes it ⇒ build B), or PLATEAU below the free
`capacity` baseline (⇒ data won't fix it ⇒ B dead)? Train = base-seed rich10 arms (85 wins); test = disjoint
+7-offset arm (52 wins); linear logistic over {capacity + joker multi-hot}.

| training wins | ante-4 capacity-OOS | ante-4 piece-OOS | ante-5 capacity-OOS | ante-5 piece-OOS |
|---|---|---|---|---|
| 10 | 0.764 | 0.666 | 0.765 | 0.664 |
| 20 | 0.764 | 0.686 | 0.765 | 0.727 |
| 40 | 0.764 | 0.703 | 0.765 | 0.729 |
| 85 | 0.764 | **0.712 (−0.052)** | 0.765 | **0.732 (−0.034)** |

**Verdict: NO-GO.** The piece-level value rises fast to ~20–40 wins then **plateaus BELOW the free capacity
baseline** (ante 5: +0.005 over the 20→85 quadrupling — flat; ante 4: closing but still −0.052 and would need
*hundreds* more wins just to reach parity, with no margin above). So a learned early-position value does **not
beat the heuristic the engine already uses** at any attainable data volume. This is the **5th independent
confirmation** of the P5 bound (after NNUE-OOS, interactions-OOS, TD-OOS, offline-value), and the first as an
explicit scaling curve. Caveat: this is a *linear* model; a nonlinear NNUE + GPU-scale self-play (orders more
data, self-improving) is the only untested residual — but it fights a strong 0.76 baseline, is a multi-week/
GPU build, and the linear+interaction evidence says capacity is near the achievable ceiling.

**⇒ FINAL VERDICT OF THE V4 INVESTIGATION.** Both routes to materially-higher AUTONOMOUS winrate are now
closed on fresh evidence: per-decision/policy levers are exhausted (S1 audit + loss diagnosis: the engine
picks correctly, the gap is supply×survival×economy, all levers reverted), and the learned-value route does
not beat the free baseline on attainable data (this probe). The measured ceiling — **~8% baseline / ~29%
rich10** — is real and confirmed from every angle. Autonomous ~85%+ is **not reachable** with this engine +
attainable data/compute. **The valuable, open, non-compute-bound objective is ADVICE QUALITY** (the mod
advises a human who wins ~87.5%; measured on the agreement ruler). That is where further work should go.

---

## 🔬 LOSS DIAGNOSIS (2026-09-18) — competence vs optimization: it is OPTIMIZATION (supply×survival)

Ran a position-level failure taxonomy over the engine's OWN 147 losing runs (`tools/loss_diagnosis.py`),
plus the supply-vs-competence test (were multipliers OFFERED+AFFORDABLE but passed, or never seen?). This
is the test the "I win with sloppy play, why can't it" question demands — and it is NOT the per-decision
agreement corpus (which is human WINNING states); it judges the engine's own LOSS states.

**Failure taxonomy (147 losses):** NO_CORE 39% (never assembled 2+ multipliers) · VARIANCE 37% (died within
15% of target — mostly one-multiplier-short) · BASELESS 12% (multipliers, no base) · ECON_CLOG 7.5% · rest <5%.

**The decisive supply-vs-competence numbers:**
| | multiplier SUPPLY (shop+pack offers, whole run) | ACQUIRED | positively-rated buyable mults PASSED |
|---|---|---|---|
| WINS (13) | **12.0** | 3.7 | — |
| ALL losses (147) | **4.4** | 1.3 | 0.5 / run |
| NO_CORE losses | **3.1** | 0.5 | **0.2 / run** |

**Verdict: it is NOT a per-decision competence gap.** The engine takes the multipliers it is offered at a
normal rate (~30%) and passes almost none it rates positively (0.2–0.5/run — confirming C'). The losses get
**~4× less multiplier EXPOSURE** (3 vs 12 offers) for one reason: **they die early (mean ante 3.7)**, before
accumulating the shop visits that build a core. Per-shop offer rate is similar (~0.8–1.3); the gap is NUMBER
of shops = SURVIVAL. And early death traces to early poverty (NO_CORE dies at ante 3.7 with only ~$24, unable
to afford the first multiplier without bankrupting — the economy-timing lever, already worked/reverted).

**⇒ The chain is `early economy → early survival → shop EXPOSURE → a multiplier core → survival`, and it is
self-reinforcing.** This is the SAME supply×survival×economy wall, now measured from the loss side and shown
to be structural, NOT a handful of fixable gestalt mistakes. **There is no cheap competence fix hiding here.**

**This is the precise answer to "why not a chess engine":** the engine already *picks* correctly (the search/
eval half a chess engine adds isn't the gap). What it lacks is the human's intuitive **early-game position
sense** — surviving thin early boards and banking to afford the first multiplier, which then compounds into
exposure. That IS a value-function job (a chess eval / human intuition), and it is exactly the piece the
compute path (learned `V(state)`) would supply — and the piece 2 years of hand-crafting could not. The honest
fork stands: **(B) learn that early-position value (needs the data the data-scaling probe would size), or
(A) accept the ceiling and pivot to advice quality.** The diagnosis rules out "cheap policy fix" as a third option.

---

## 🧭 S1 AUDIT (2026-09-18) — the economy/supply frontier is EXHAUSTED, verified against the graveyard

Before building S1 (economy timing) I audited exactly what has been tried (owner directive: do not repeat).
**Result: every supply/economy/restraint lever is already tried — reverted or shipped-modest.** S1 as a
build would repeat prior work. Evidence, current-code-verified:

| lever | status | source |
|---|---|---|
| option-value banking (interest-cap fix + 4 variants) | **REVERTED** — regressed agreement (winners bank PAST the mechanical cap; old appetite was tuned around the bug) | conversion_baseline.txt B' |
| pack-poverty discipline (damp poor-board packs) | **SHIPPED** (`SA.PACK_POVERTY_DAMP`, `^1.6`), modest (eng_buy_human_save 264→258) | 20c146c |
| reroll-to-dig for a core when core-poor | **REVERTED** −0.015, sign 7/17 ("exposure spending is high-variance, −EV") | WINRATE_AUDIT 2026-07-11 |
| buy more packs (levelbuy) | **REVERTED** −0.229 | archive |
| ecap3 early board discipline | **REVERTED HARD** −0.945 @rich10 | §28 |
| conversion-pressure / slot opportunity cost (P1 today) | **REVERTED** — killed winners, composition unchanged | this doc §P1 |
| joker VALUATION forward-marginal (C') | **REFUTED as the gap** — engine ranks the human's multiplier #1 91% of the time | conversion_baseline C' |
| pack-PICK card choice (D') | not a clean lever — within-category, tied to the hard commitment problem | conversion_baseline D' |
| target model / completion credit (§32) | OOS-FAILED (winner's curse on n=7) | §32c |

**The wall, re-confirmed from three sides this session:** the engine already BUYS multipliers first-choice
when present (C', decomposition 21.83); it dies at 27% multiplier because multipliers are rarely PRESENT in
its shops/packs; and **rich10 money does NOT raise `run_str` (0.62 in both)** — so it is not purely "can't
afford". The binding constraint is **multiplier SUPPLY**, and supply is bounded by the greedy policy's
inability to convert money→product plus the RNG. Per-decision levers to force conversion are all closed.

**⇒ THE REMAINING PATHS ARE STRUCTURAL, NOT PER-DECISION** (a genuine strategic fork, not another tweak):
- **(A) Pivot to ADVICE QUALITY** — the mod advises a human who already wins ~87.5%; that objective is
  non-compute-bound and open (the agreement ruler measures it). "Autonomous ~100% to unlock the key" is
  very likely NOT reachable with this architecture; ~8% baseline / ~29% rich10 is the measured ceiling.
- **(B) The COMPUTE path** — a learned value function / GPU self-play (MCTS_PLAN). The only approach with a
  real shot at materially higher AUTONOMOUS winrate; previously declined for compute cost.
- **(C) A BIGGER winning-human corpus** — the n=7 winner's-curse blocker is what killed option-value
  banking and forces every economy constant to fail OOS. More overlay-hidden owner wins would unblock the
  one open economy thread; incremental (maybe 8%→~12–15%), not a path to human parity.

---

## ❌ PHASE 1 RESULT (2026-09-18) — WS-3 conversion-pressure lever BUILT, MEASURED, REVERTED

**What was built.** `BP.conversion_cost`: charge the permanent-slot opportunity cost of buying a
non-multiplier into a maturing, multiplier-poor board (gated on base-exists + slot-pressure, pace-damped),
to push the engine to bank/reroll for a multiplier instead of filling slots with additive/econ commons —
targeting the confirmed defect (death boards 26.8% multiplier vs human 86.5%). Value decomposition first
confirmed filler is bought on `sgain` (current-board score), not the money term, so the lever aimed there.

**Measured (paired n=160, `sim_out/v4_ws3.jsonl` vs `v4_base.jsonl`):**
- winrate **8.1% → 6.2%**; sign test **3 better / 11 worse (p 0.06)**; tail **reach-8 −4**; **4 winning runs killed**.
- **Board composition UNCHANGED** — still 26.8% multiplier / 27.4% econ / 23.4% flat (it did not replace filler).
- **Agreement byte-identical** to HEAD (eng_buy_human_save still 266) — zero decisions flipped on the win corpus.

**Mechanism (now triangulated with the refuted ecap3 §28 and buy-bar §31g — three independent probes, same
wall):** *refusing filler does not create multipliers.* When the shop offers no multiplier, banking/rerolling
lands on **other filler** or a **weaker board that dies**. The engine already buys multipliers #1 when
present (decomposition value 21.83). **The constraint is multiplier SUPPLY (packs / tags / rerolls / later
shops) and the economy that funds it — NOT the engine's willingness to buy them.** The restraint/preference
lever family is closed. Reverted; kept the diagnosis, the `_G.BES_VALUE_DEBUG` instrumentation, and this record.

**⭐ Two things this fast, decisive negative bought us (vs the old grind):**
1. It ruled out an entire family in ONE clean measurement (agreement + composition + paired sim), with a
   named mechanism — not a "bounced slightly, unclear why" revert.
2. It surfaced a ruler limitation: **the agreement corpus is winning-human STATES, so a change that only
   affects the engine's own FAILURE trajectories is invisible there.** For supply-side work, the sim's
   board-composition + winrate is the ruler; agreement gates only decisions on good boards.

**⇒ REDIRECT: the frontier is multiplier SUPPLY**, in priority order by leverage × attainability:
- **(S1) Economy timing to afford more multiplier DRAWS.** rich10 (+$10/rd) → 28.7% proves money→supply→wins.
  The engine is ½ the human's bankroll early ($3/$12 vs $8/$26 at ante 2/3) because it over-buys early
  packs/commons (eng_buy_human_save 266, mostly packs at ante 1–2). Bank early like the human → afford shop
  multipliers + packs when they matter. ⚠ must NOT reduce board size (ecap3) — spend EFFICIENCY, not restraint.
- **(S2) Directed multiplier acquisition from packs** (open Buffoon packs / reroll-for-a-multiplier when
  mult-poor AND funded) — the pack-throughput channel the human back-loads and the engine front-loads.
- **(S3) Slot expansion valuation** (Negative jokers) — GRAND_AUDIT's top un-probed lever, but rare (freq ceiling).

---

## ✅ PHASE 0 RESULTS (2026-09-18, fresh current-HEAD data)

All numbers re-derived on today's engine (the Aug-24 baseline files were stale — 40+ engine commits since).

**The scoreboard moved — recent work already tripled baseline:**
| config | winrate | progress | run_str@a8 | source |
|---|---|---|---|---|
| baseline | **8.1%** (13/160) | 4.287 | 0.60 | `sim_out/v4_base.jsonl` |
| rich10 | **28.7%** (46/160) | 5.999 | 0.62 | `sim_out/v4_rich.jsonl` |

**1. Deaths are BUILD/economy, not play.** Baseline **112 BUILD vs 35 VARIANCE**; boss deaths clear only
**72–75%** of requirement — the board is ~¼ too weak at the fatal boss. (Confirms: fix shop/economy/valuation.)

**2. The over-buy is real, dense, and chaos-free — the RULER.** On **1048** shop decisions (agreement corpus,
`sim_out/agreement/head_v4.report.txt`): engine **buys where the human SAVES 266× (25%)** + **rerolls where
human saves 120× (11%)** = spends on **~36%** of decisions the human banks, while **under-buying only 23×
(2%)** — a **12:1 over-spend asymmetry**, concentrated at **ante 1–2 (49%/53% BUY)**, biggest category
**packs (20.6% of all shop actions)**. This is the dense gradient the project never had: drive
`eng_buy_human_save` down without raising `eng_save_human_buy`.

**3. Economy gap confirmed and EARLY, and money gets spent not compounded.** Engine ≈ half the human's
bankroll at every ante, and **plateaus at ~$27** while the human compounds to ~$45:
| ante | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|
| engine $ | 3 | 12 | 24 | 27 | 27 | 28 | 36 |
| human $ | 8 | 26 | 26 | 45 | 38 | 39 | 52 |
Given +$10/round (rich10) the engine's money **still plateaus at ~$30** — it *spends the surplus* (fills 5
slots by **ante 2** at rich10 vs the human's 2).

**4. ⭐ The TRUE WALL is board POWER (WS-3), and money cannot buy past it.** `run_str` caps at **~0.62 at
ante 8 in BOTH baseline and rich10.** Extra money buys more LEVELS (hlv 13→16.5) but the **same board
strength**. Proof in the death boards: at rich10 the engine dies holding **Golden, Mail, Golden Ticket,
Cloud 9, Delayed Gratification** — five *economy* jokers. **It converts money into more money, not into a
compounding score product.** This is the additive-sum-not-product defect, measured.

**5. Leveling has CAUGHT UP — it is NOT the current gap.** Engine hlv **13 (baseline) / 16.5 (rich10)** at
ante 8 vs human **15**. The old "engine 4.5 vs human 18" is stale (the scaler/spectral work closed it). ⇒
**Do not spend effort on the leveling channel** (`planet_credit`/`LEVEL_PUSH`/`level_need`) — it's solved.

**6. Slot COUNT gap is small** (a2: 3 vs 2). Confirms WS-2 is about slot *content/upgrade*, not holding open.

**⇒ FINALIZED DIRECTION.** One deliverable dominates: **WS-3, a product- and opportunity-cost-aware buy
valuation.** Value a joker by its marginal on the *projected assembled multiplicative board* (so
multipliers/retriggers/copiers rate high and additive/econ commons rate low once a base exists), net of the
true opportunity cost of the cash + slot it consumes. This one change fixes all three symptoms at once: less
spend on additive/econ filler (WS-1 — cash compounds past $27), swaps toward multipliers (WS-2 — board stops
freezing), and breaks the `run_str 0.62` wall (WS-3). WS-1/WS-2 become recalibration downstream, not builds.
Primary ruler = `eng_buy_human_save` on the agreement corpus; confirmation = `run_str@a8` and winrate.

---

## 0. Why the old loop cannot work (the justification for changing method)

Three facts, all from the project's own data, that together make single-lever winrate tuning structurally
blind to the actual solution:

1. **Frequency ceiling.** A fix touching one joker/situation reaches ~5% of runs and comes back
   ~153/160 seeds TIED. It cannot move an n=160 verdict however correct it is. (CLAUDE.md, the frequency table.)
2. **Chaos floor.** Per-seed sd ≈ 1.9; MDE at n=160 ≈ 0.42 progress. Most correct changes are *below the
   noise floor at baseline*. (CLAUDE.md envelope analysis: 85% of seeds flip under tiny perturbations.)
3. **Supermodularity — the killer.** From the ceiling probes on disk:

   | config | winrate | source |
   |---|---|---|
   | baseline | 2.5% | `sim_out/base_31f.jsonl` |
   | + money only (rich10) | 24% | `sim_out/baser_31f.jsonl` |
   | + slots only | 14% | `sim_out/ceil_slots7.jsonl` |
   | money **+** slots | **51%** | `sim_out/ceil_rich10_slots7.jsonl` |
   | everything | **98%** | `sim_out/ceil_everything.jsonl` |

   The levers **multiply**. The winning board is a *product* (xmult × retrigger × copier × leveled hand),
   and so is its fix. **Any single piece of a supermodular fix looks like noise by construction** — so
   "isolate a lever → measure its winrate delta → keep if significant" can *never* find it.

**Consequence — the method changes:**
- **Build the bundle together** (economy + slots + product-value), never lever-by-lever.
- **Primary ruler = agreement with the winning human** (`tools/agreement_run.sh`, 928+ paired decisions,
  deterministic, non-chaotic). "Does the engine now DECIDE like a winner?" is answerable; "did winrate
  move 0.03?" is not.
- **Secondary confirmation = rich10 winrate** (where a valuation change can express, per the §6 rule).
- **Baseline winrate demoted to a regression guard only** ("don't go significantly negative"), never the
  per-lever gate.

---

## 1. Target & definition of done

- **Goal:** push far past 2.5% and measure where it caps. Expected realistic ceiling ≈ human parity
  (~85%) — literal 100% is a cheat-config artifact (`ceil_everything`) and not an in-rules objective.
- **Ship the bundle when ALL hold (paired, deterministic):**
  1. **Agreement up** on the frozen corpus — BLIND + PACK + SHOP each ≥ HEAD, SHOP+PACK (the build
     channels) up by a real margin.
  2. **rich10 winrate up** — paired n≥160, t > 2, and OOS-confirmed at `BES_SEED_OFF=7` (mandatory; the
     level_gain result replicated, the target model did not — breadth of the sign test is the tell).
  3. **Baseline not significantly negative** — paired n≥160, progress Δ not below −0.15.
- **Kill the bundle if:** agreement drops on any channel, or rich10 is null with the sign test even.

---

## 2. The three work-streams (one worktree, built together)

> ### ⭐ PHASE 0 CORRECTION (2026-09-18) — the three WS are ONE root cause, and WS-2 was mis-stated.
> Measured the **winning human** per-ante trajectory from `data/bes_runs_live_2026-08-12.jsonl` (7 wins,
> `ante` records) and audited the current engine code. Two things changed:
>
> **(1) The winners do NOT hold slots open.** Median jokers held: **ante2 = 2, ante3 = 5, and 5 for the
> rest of the run.** They fill to a full board by ante 3 and *keep it full* — the edge is slot *content*
> and *continuous upgrading within 5 slots*, NOT holding slots empty. WS-2 as originally written ("hold a
> slot open") is wrong; the real lever is the **swap/upgrade** policy (keep trading additive commons for
> multipliers inside a full board), which the engine damps via `SA.UPGRADE_MARGIN=1.2` + strength-
> proportional swap protection — it *freezes* the board at ante-4 additive commons instead.
>
> **(2) All the machinery already exists — this is a CALIBRATION/UNIT problem, not missing features.**
> The engine already has: a ramping econ floor to the interest cap (`SA.econ_floor`, horizon decay,
> `FREE_SPEND_DISCOUNT`), slot-dilution penalties (`BP.FLAT_GLUT/ECON_GLUT`), swap hysteresis
> (`SA.UPGRADE_MARGIN`), and a planning layer with an invest gate (`BP.fit`). It wins 2.5% anyway. So the
> defect is that the **buy value of a cheap additive common is measured too high** relative to (holding the
> cash + holding the slot for a future multiplier), because it is a real positive marginal *on the current
> board*. The hand-tuned penalties are patches fighting that mis-measurement.
>
> **⇒ The unified diagnosis:** the engine **over-buys cheap additive commons early**, which simultaneously
> (a) drains early cash (WS-1 symptom — human $8/$26/$26/$45 at ante 2/3/4/5; engine far below), (b) fills
> slots with non-compounding pieces then freezes (WS-2 symptom), and (c) makes the board an additive *sum*
> not a *product* (WS-3). **One root cause, three symptoms — which is exactly why they are supermodular and
> why isolated fixes failed.** The core deliverable is **WS-3: a product- and opportunity-cost-aware buy
> valuation**; WS-1 and WS-2 become consequences + light recalibration, not separate greenfield builds.
> (Winning-human target curve, medians: `$` 8/26/26/45/38/39/52 · `hlv` 0/0/3/5/8/13/15 over antes 2–8.)

### Winning-human target trajectory (acceptance curve, medians over 7 wins)

| ante | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|---|
| dollars | 8 | 26 | 26 | 45 | 38 | 39 | 52 | 57 |
| jokers | 2 | 5 | 5 | 5 | 5 | 5 | 5 | 5 |
| hand-lv sum | 0 | 0 | 3 | 5 | 8 | 13 | 15 | 15 |

The one human LOSS (X3L32ZEA) was **poor early** ($0/$11/$6 at ante 2/3/4) then $54 at ante 5 with hlv 3 —
economy-timing + conversion failure, confirming **early economy (antes 2–4) is the discriminator.**

### WS-1 — Economy ACQUISITION (the #1 binding constraint)
- **Defect (measured):** engine holds **$1 at ante 2** vs the human's **$7**, and its money **plateaus at
  ~$28** while the human's **compounds to ~$45** (GRAND_AUDIT §A). Under identical rules — the human
  *generates* it. Money alone is a 10× winrate swing.
- **The spec already exists:** `human-economy-policy` memory — satisfice current-blind survival, bank to
  the interest cap before spending on power, invest surplus only into the compounding core, econ gated by
  remaining need, interest discipline, stake-aware skips.
- **Where:** `shop_advisor.lua` (`SA.ECON_FLOOR*`, the buy gate), `engine/eval_function.lua`
  (`Eval.econ_value`), `engine/skip_advisor.lua`, `engine/tags.lua` (skip-tag econ).
- **Change:** replace the flat econ floor with a **bankroll target that ramps to the interest cap and
  treats holding/compounding it as high-value early**, so a power buy that drops you below the interest
  breakpoint must clear a higher bar than the interest it forgoes. Value money-generating jokers/skip-tags
  higher in antes 1–3 (still capped by `BP.ECON_CAP=2` so it can't hoard econ).
- **Not the graveyard:** this is *acquisition + interest discipline*, not "buy more econ jokers" (refuted).
  It targets the compounding curve the human has and the engine lacks.

### WS-2 — Slot CONTENT / continuous upgrade (REFRAMED by Phase 0 — was "slot discipline")
- **Defect (measured, corrected):** the winners fill to 5 jokers by ante 3 and stay full; the edge is
  that they keep **swapping additive commons for multipliers within the full board**, while the engine
  **freezes** its board on ante-4 additive commons (board full + `SA.UPGRADE_MARGIN` hysteresis +
  strength-proportional swap protection block the upgrade). NOT "hold a slot open" (winners don't).
- **Where:** `shop_advisor.lua` (`SA.UPGRADE_MARGIN`, swap protection, `funder_is_live`/SELL_TO_BUY gates),
  `build_plan.lua` (`BP.keep_bias`, `BP.fit`), `Eval.negative_slot_fv` (Negative slots already at 6.0).
- **Change:** make the swap gate **product-aware** — trading an additive common for a multiplier/retrigger
  should clear the margin easily even when the multiplier's *current-board* marginal is modest, because on
  the assembled board it compounds (this is WS-3 applied to the sell/swap side). Do NOT lower the margin
  uniformly (that thrashes working boards); raise it only for additive→multiplier trades.
- **⚠ Not `ecap3`/readiness-gate (both REFUTED HARD):** those imposed a *hard cap on board size* and
  starved the engine (board power produces money AND survival jointly, −0.945 at rich10). This is **not a
  cap** — it's "fill slots with the RIGHT (compounding) jokers; hold a slot for a multiplier rather than
  buy a diluting common." It only ever fires when survival is already satisficed, and it is part of the
  bundle (the held slot exists *for* WS-3's core), never measured alone.

### WS-3 — PRODUCT board-value on the buy side (the architectural core)
- **Defect:** the buy value of a joker is its **marginal on the CURRENT board** (`Eval.jp_from_measure`
  and the parallel `shop_advisor.scoring_gain`). That is additive-blind: an xmult on a thin early board
  multiplies little, measures low, gets skipped — so the board never becomes a *product*. `BP.fit` patches
  this with hand-tuned constants (`XMULT_FILL=2.2`, `SCALING_FILL=1.2`, `COMMIT_JOKER_FILL=1.2`), which is
  exactly the guessed-magnitude class that never converts.
- **Change — replace the constants with a MEASURED target-board marginal:**
  1. Model the **projected assembled board** for the committed plan (`BP.commitment`): the target board is
     the current board plus the plan's intended pieces, scored as
     `base_chips × Σ(flat_mult) × Π(xmult) × Π(retrigger) × leveled_hand` (a PRODUCT, using the pieces
     `BP.analyze` already counts).
  2. New `Eval.board_product_marginal(gs, candidate, plan)` = the candidate's marginal on the **target**
     board, not the current one — reusing the existing Monte-Carlo scorer at the projected state.
  3. Blend: `buy_value = V_now + invest_weight(pace) × max(0, V_target − V_now)`, where `invest_weight`
     is 0 when urgent and ramps with `pace.margin` (reuse `BP.invest_window`). Assembly feasibility gate:
     `V_target` only counts pieces that fit in the **remaining** slots (ties WS-2 and WS-3 together).
- **Not the graveyard:** the refuted xmult-floor "valued xmult high regardless" and bought too early
  (bootstrap trap). This is **survival-gated and slot-feasible** — it only rewards the product when the
  board can already clear the near-term blinds, which is the exact condition `BP.fit`'s `invest` gate was
  built for. It is conclusion 6(c) of GRAND_AUDIT ("a product not sum board-value function on the buy
  side"), which is named as genuinely un-built.

---

## 3. Phase 0 — diagnosis (fresh numbers before any code)

Ground the build in current-HEAD data, not old docs. Produces the "before" baseline for every ruler.

1. **Agreement baseline:** `tools/agreement_run.sh head_v4` → lock BLIND/PACK/SHOP % for HEAD.
2. **Winrate baseline (locks the A/B "before"):** confirm `sim_out/base_31f.jsonl` (baseline) and
   `sim_out/baser_31f.jsonl` (rich10) reproduce on current HEAD; if the engine drifted, re-run
   `bash tools/sim_par.sh 160 v4_base` and `BES_PROBE=rich10 bash tools/sim_par.sh 160 v4_rich`.
3. **Economy trajectory gap:** `lua tools/real_vs_sim.lua` — quantify $-per-ante and the $28-plateau vs
   human $45-compound on CURRENT code (WS-1's target numbers).
4. **Slot-fill timing:** measure jokers-held-per-ante for the engine vs the human corpus (extend
   `analyze_runs.lua` action summary if needed) — WS-2's target curve.
5. **Product-gap sanity:** on 5–10 real fixtures, dump `V_now` vs a hand-computed `V_target` for the
   multipliers the engine skipped — confirm the product marginal would have re-ranked them (WS-3 exists).

Phase 0 is cheap (all read existing telemetry) and its numbers are the acceptance targets for Phases 1–2.

---

## 4. Phase 1 — build (in a git worktree, never the live tree)

- One worktree for the whole bundle (`git worktree add ../bes_v4 winrate-v4-bundle`). All three WS land here.
- Keep tests green after each WS: `lua tests/runner.lua` (1209 pass) — correctness first.
- Instrument, don't guess: WS-3's blend and WS-1's bankroll target must be verified by **printing the
  values** on real fixtures (CLAUDE.md process rule #3: verify a threading change by measuring the value,
  not reading the diff).
- Deploy nothing to the install until Phase 2 passes.

## 5. Phase 2 — validate as a BUNDLE (never per-lever)

1. `tools/agreement_run.sh after_v4` → `tools/agreement_run.sh diff head_v4 after_v4`. **Gate 1** = all
   three channels ≥, SHOP+PACK up.
2. rich10 paired: `BES_PROBE=rich10 bash tools/sim_par.sh 160 v4_rich_after` →
   `lua tools/analyze_runs.lua sim_out/v4_rich_after.jsonl compare sim_out/baser_31f.jsonl`. **Gate 2** =
   Δ > 0, t > 2. Then OOS at `BES_SEED_OFF=7`. **Gate 2b** = replicates.
3. baseline paired regression guard: `bash tools/sim_par.sh 160 v4_base_after` compare vs baseline.
   **Gate 3** = Δ ≥ −0.15.
4. If a gate fails, use the replay loop (CLAUDE.md ⭐⭐ diagnostic) to find WHICH ws/decision regressed —
   do NOT revert the bundle blindly; the pieces are supposed to be individually weak.

## 6. Phase 3 — ship / iterate / measure the cap

- All gates pass → deploy the whole tree to `%APPDATA%/Balatro/Mods/balatroenginesim/` (diff the whole
  tree, per CLAUDE.md), commit, and **run the ceiling ladder** (`base`, `rich10`, `rich`) to read where
  the engine now caps — the answer to "85% or 100%".
- Gates split (agreement up, winrate null) → the mechanism is right but under-expressed; tune magnitudes
  *jointly* at rich10 and re-run, or find the next multiplicative partner. Do NOT revert on a baseline null.

---

## 7. Risks & honest caveats

- **Realistic cap ≈ human parity (~85%), not 100%.** Variance alone caps an expert at ~87.5% (7/8). If
  the run past 2.5% stalls at, say, 40–60%, that is already a 20× improvement and the correct place to
  reassess — not a failure.
- **Slot discipline is the highest-risk WS** (adjacent to two hard reverts). It is deliberately the
  weakest lever, gated on survival slack, and only justified inside the bundle. If Phase 2 traces harm to
  it, isolate and soften it first before touching WS-1/WS-3.
- **The product-value could reintroduce the bootstrap trap.** The `invest_weight`/urgency gate is the
  guard; Phase 0 step 5 and Phase 1 instrumentation must confirm it does NOT raise xmult priority on bare
  early boards.
- **This is not the learned-value function.** It stays hand-engineered and cheap. If it caps well below
  human parity, the remaining gap is the compute-bound value function `GRAND_AUDIT` closed — a separate
  decision, not this plan.
