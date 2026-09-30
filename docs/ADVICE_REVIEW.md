# docs/ADVICE_REVIEW.md — human observations from live advice-review runs

> **What this is.** A catalogue of EVERY observation the mod owner (a very strong Balatro player, ~7/8
> real winrate) made while following the engine's live overlay through two full runs (2026-08-26). It is a
> **reference, not a spec** — his read, to be weighed and validated (with the "run both sides" gate), not
> followed 100%. Runs: **R1** (Z9PBGTL2, died a3 boss 92%), **R2** (9UZ3Q5Q5, died a3 Big 80%).
> Legend: 🔧 issue · 🎨 overlay UX · ❓ method question · ✅ the engine got it right · [status].

---

## R3 — MALEJYHW (2026-08-27, died ~ante 2, "playing stupid"): the CHURN run

> A third live run, dominated by one failure mode: **catastrophic joker churn via `SELL_TO_BUY`**.
> Telemetry proof — every bad sale was a `SELL_TO_BUY`, and the standalone `SELL_JOKER` value said
> KEEP each time (Cloud 9 at **−12.4**). The user's diagnosis nailed it: *SELL_TO_BUY never reused the
> SELL_JOKER value* — it recomputed a weak funder loss from **scoring alone**, blind to economy,
> leveling, and edition value.

- 🔧 **Sold a polychrome Ice Cream for an 8 Ball; Astronomer for an Arcana pack; Cloud 9 (+$4/round)
  for an Egg.** All `SELL_TO_BUY`. [FIXED: `funder_is_live` — a joker with recurring $/round, a
  consumable+economy leveling engine, or a non-base edition may only fund a clear JOKER upgrade,
  never a non-joker or a lateral. Sim-neutral (surgical); ships on mechanism + the live telemetry.]
- 🔧 **Mega Celestial (pick 2): took one planet, skipped the 2nd** while scoring-starved. [FIXED:
  a planet is used immediately, never bloats the deck — always take a free level.]
  *(User caveat: skipping a lesser planet CAN be right to keep your MAIN planet as the Fool's
  last-used copy target — very rare/situational, so the "take the free level" logic is basically
  entirely correct. Too niche to model.)*
- 🔧 **At the ante-1 boss, discarded the non-debuffed Jack over the debuffed one** (low impact).
  [FIXED: `keep_value` ranks a debuffed card below any live card — pitched first.]
- 🔧 **Hex → polychrome on Ice Cream over Cryptid.** *(User: it had only ONE joker (Ice Cream) so
  Hex was GUARANTEED to hit it — the targeting was never the issue. The real problem was that it
  then SOLD the polychromed joker immediately — pure churn, addressed by the anti-churn fix above.)*
- 🔧 **Rerolled while nearly broke** with good packs present, then spent down to $1 on a Celestial
  pack. [NOT FIXED: reroll is heavily tuned — deferred to a proper A/B rather than a blind edit.]
- 🔧 **In-blind: "pointless discarding around a low straight that wouldn't clear" (a1); at the a2
  boss, dug away from its own Odd Todd line.** [NOT FIXED: the a2 case was moot — the run was already
  lost to the churn (no scoring). The play-spiral is the documented frontier, and the per-hand
  telemetry is currently too lossy (empty `cards`, zero `score_delta`) to diagnose precisely.]

**Sim A/B (n=40, all three fixes vs pre-report baseline): NEUTRAL** — Δ−0.05, p 0.86, death-ante
shift a balanced 8-later/8-earlier. Expected: the sim's decks rarely hold the econ/leveling/edition
jokers where the churn fix pays, so it can't see the live benefit. Ships on correctness + mechanism.

---

## R4 — self-player run (2026-08-31, "same in-blind + shop issues every time"), reached ante 7

> The BEST self-player run so far (reached ante 7) but "carried by Cavendish" + 2 early Runner scales.
> Owner's read, with the run log (bes_autoplay.log, 23:25 session) used to ground-truth. Most notes are
> the SAME recurring classes already in §1 (dig/commit) and §8 (reroll) — this run is fresh evidence, not
> new bugs. Legend as above.
>
> **THE DOMINANT THEME — in-blind: play the first clearing hand instead of DIGGING for the build/scaler
> (§1).** Repeated all run and it caused the death:
> - 🔧 First blind cleared in 3 hands, banked $2 fewer (should be tighter with dig-play). [§1, R1 echo]
> - 🔧 **Big blind: played the spade FLUSH just because it cleared, instead of using its 3 discards to
>   find another STRAIGHT and scale Runner.** [§1 + scaling-fuel: only feeds Runner when out of discards]
> - 🔧 **Boss: had a full STRAIGHT ready, wasted its discards / didn't play it; a3 boss DISCARDED a made
>   straight** — the exact scaler-feeding hand thrown away. Runner scaled only ~3× in 7 antes. [§1]
> - 🔧 **a2 small: played a 9s/10s Two Pair with many discards to spare** instead of digging for face
>   cards (Midas Mask) or a straight (Runner). [§1]
> - 🔧 **a3 small: over-conservative retention** — held gold face cards but played a suboptimal hand; could
>   have played the non-gold Kings or dug for more face cards / a straight. (Made a little $, still wrong.)
> - 🔧 **Endgame: stopped digging with its HANDS too** — played bare pairs / high-cards of the very face
>   cards it needed to ACCUMULATE for the face build. [§1]
> - 🔧 **DNA held all run, never used** — could copy a strong enhanced face card and raise Four-of-a-Kind
>   odds (a hand it had LEVELED but never played/dug for). [new: DNA use never triggered]
>
> **SHOP / ECONOMY:**
> - 🔧 **Orbital tag skipped-for, leveling FOUR OF A KIND on a non-shaped deck** (rarely drawn; never
>   played all run). Plus a Mars planet also leveled Four of a Kind. Leveling value must weight the DECK's
>   frequency of the tag/planet's hand, not credit an unreachable hand. [new — see planned fix]
> - ✅ **Reroll discipline (§8) — FIXED + MEASURED (`96b56b1`).** a6 had $100+ and *barely rerolled*; a
>   later shop **rerolled ~9× to reroll_cost $14** (telemetry: at that shop the engine ranked REROLL 1.05 >
>   SAVE 0.00 and rolled again), bleeding ~$85 to $26 — the money-bleed that forced the joker churn and
>   killed the run. Root: the per-reroll value subtracts the current cost but judges each roll MYOPICALLY,
>   so a spree runs. Fix: damp reroll appetite by base/reroll_cost (~1× at $5, ~0.36× at $14; free rerolls
>   exempt). **Agreement corpus: eng_reroll_human_save 120→109 (−11 over-rerolls), agree_save 300→310, all
>   else byte-identical — a measured win on the target metric.** ⇐ this was the through-line of the whole
>   "sold Fibonacci" investigation: the reroll spree was the CAUSE, the churn the symptom.
> - 🔧 **"Sold its only +mult Fibonacci for a Hiker."** ⚠ INVESTIGATED FROM THE REAL TELEMETRY (owner
>   pushed for exact-state repro, not a synthetic board — the right call). The state fixture shows the
>   board ALSO held **Cavendish (xmult)**, so Fibonacci was never the *sole* mult source, only the sole
>   *additive* one. Reconstructed the exact pre-sale board (real 52-card deck, real levels, $26,
>   {runner, hanging_chad, cavendish, dna, fibonacci}) and replayed: **the current engine SAVEs — it does
>   NOT churn Fibonacci.** No reproducing bug; the live sale was a slightly-different tick I can't recover
>   bit-exactly (no fixture captures a *shop* moment — only blind states carry the `gs`, and Fibonacci
>   lived only between blinds). A "don't sell your only mult for chips" guard was built then REVERTED
>   (misdiagnosis: Cavendish was present). LESSON: reconstruct from telemetry, don't guess a board.
> - 🔧 **Hermit picked FROM A PACK into FULL consumable slots → never used** (the a4 shop-BUY Hermit WAS
>   bought+used correctly — §4 works there; the gap is pack-picked / full-slot Hermit). Also **skipped a
>   Hermit in-shop at $26 with full slots** — should buy+use immediately (instant $), full slots is not a
>   reason to skip an instant-use consumable. [§4 gap]
> - 🔧 **a4: held $20, bought a Mega Celestial** (fine) — the Hermit money point above is the real note.
> - 🔧 **a5: hoarded** past strong Arcana/Planet packs in the first shop (took stuff in the second).
> - 🔧 **Skipped tarots (The Fool, The Magician).** [§6 deck-shaping/tarot valuation, documented frontier]
>
> ✅ **a7 reached — the deepest run yet.** Straights WERE played early (Runner fed ~3×); Hermit bought+used
> at a4; the Gros Michel→Cavendish death-swap found the carry. The wall is the SAME: dig-for-build (§1) +
> reroll discipline (§8) + not leveling toward a REACHABLE hand.
>
> ✅ **NEWEST-RUN in-blind mistakes FOUND + FIXED (2026-09-01, `71dedb3`).** Reconstructed the states and
> replayed: ante-3 round-6 the MILK deferred a **3300 Flush that trivially cleared 2000**, playing High Card
> ×4 to "hold" the flush's own gold hearts for Midas $ — illusory (you forfeit the gold when you play the
> clear). Fixed (gold-exclusion in HoldFuel + milk preserves the clear's scoring cards); round 6 now plays
> the Flush. This IS the "digging with hands / score-opt by discards after the first hand" complaint. The
> ante-2 round-4 "played a Two Pair first instead of digging" was checked and is NOT a bug — it's an
> accumulate play (dig-vs-accumulate = the §1 build-commitment wall; uniform dig bias already refuted).

---

## R6 — owner-followed run (2026-09-04): ECTOPLASM on a sellable joker + the poverty spiral

> Owner's report: *"took Ectoplasm on a joker which is pointless — the joker is so sellable when Ecto causes
> a permanent −1 hand size. It stuck very poor throughout the game which meant it struggled to build, and it
> also meant Bull was doing very little."* Two observations; the code review below found a concrete cause
> for each. **Both are HYPOTHESES until measured** (the R5 standard), but the Ectoplasm one is a plain
> correctness hole rather than a magnitude call.

- 🔧 **Ectoplasm is priced as a flat 0.7 prior with its permanent downside charged at ZERO.**
  `CV.card_value` (`engine/consumable_value.lua:503`) falls through to `CV.SPECTRAL_BASE.c_ectoplasm = 0.7`
  — the **third-highest spectral prior**, behind only The Soul (1.2) and Black Hole (0.9). Three distinct
  errors, and the fix template already sits in the same function:
  * **The cost is not charged at all.** `c_ouija` has an explicit branch two lines up
    (`consumable_value.lua:496-501`) subtracting 0.3 for exactly this — *"PERMANENTLY costs -1 hand size —
    a real ongoing downside. Charge it, so an Ouija isn't reflexively picked over a harmless spectral."*
    Ectoplasm inflicts the **same −1 hand size** and gets **no such branch**. ⚠ `-- VERIFY`: in the real
    game Ectoplasm's penalty *stacks per use in a run* (−1, then −2, …), making it strictly worse than
    Ouija's, while the sim world (`sim/world.lua:461`) models a flat −1 per use.
  * **The benefit is a flat prior when a MEASURED one already exists.** Ectoplasm grants Negative on a
    random joker = **+1 joker slot**, which the engine prices properly via `Eval.negative_slot_fv`
    (`eval_function.lua:842` — board- and runway-aware: `NEG_SLOT_FV` 6.0 tapering to a 0.5 floor,
    discounted when slots aren't binding). Ectoplasm never calls it. Two things the flat prior cannot see:
    with **0 jokers it does literally nothing** yet still costs the hand size (`sim/world.lua:454-461`), and
    at ante 8 the slot is worth the 0.5 floor while the hand-size cost is still full price.
  * **⭐ The owner's actual point — the ASYMMETRY, which even `negative_slot_fv` doesn't capture.** That
    function prices a *permanent* slot. Ectoplasm's slot is yours only while you hold **that specific
    random joker** — sell it and the slot goes with it. **The benefit is contingent and sellable; the cost
    is permanent and unsellable.** So the Negative wants to land on a joker the plan will KEEP
    (`BP.is_core`/`CORE_KEEP`), and the value should discount by the chance the target is later sold.
  * ⚠ The FACTS layer already pays this cost (`sim/world.lua:461` reduces `hand_size`) while the OPINION
    layer prices it at zero — an engine/world mismatch: the sim is *already* charged for a decision the
    engine made blind.
- 🔧 **"Stuck very poor + Bull doing very little" — Bull is credited as INCOME when it produces none.**
  Bull is a *converter* ($ → chips, `joker_effects.lua:178` = `2 × dollars`), not a producer, but
  `commitment_signals` (`build_plan.lua:228`) scores it **econ + 3** — the top weight, tied with Bootstraps
  and **3× any real income joker** (`econ + 1`). `BP.ECON_COMMIT_THRESHOLD` is **4.0**
  (`build_plan.lua:345`), so **Bull plus any one economy joker commits the whole run to the ECONOMY
  archetype** with no actual income on the board. `BP.is_core` then returns `CORE_KEEP` for it
  (`build_plan.lua:446`) and `fit` rewards further economy buys as *"converts the committed bankroll into
  score"* (`build_plan.lua:577-579`) — a bankroll that in this run never arrived. That is a self-reinforcing
  poverty trap matching the reported symptom exactly: commit to economy → never get rich → Bull scores
  nothing → the build never happens. **Proposed direction: a converter must not be able to *establish* an
  economy commitment by itself** — credit Bull/Bootstraps toward the plan in proportion to realised income,
  or require a genuine producer to cross the threshold.
- ❓ **Are the two observations one story?** Plausibly: −1 hand size → weaker hands → fewer/cheaper clears →
  less money → Bull (money-scaled) contributes less → the build stalls. Worth checking the run log for
  whether the Ectoplasm *preceded* the poverty rather than merely accompanying it.

**✅ ECTOPLASM SHIPPED + DEPLOYED (`175b5c4`).** All three corrections, plus `CV.hand_size_cost` — the
permanent −1 hand size is now MEASURED off the real deck (paired sampling at hand size N vs N−1 from the
same shuffle, scaled by `CV.level_scale` for permanence) and **Ouija uses it too**, so the two cards that
inflict this downside are finally charged the same way. Measured at ante 3 on a stock deck, against the flat
**0.700** it read in every one of these rows before:

| board | value | board | value |
|---|---|---|---|
| 0 jokers (lands nowhere) | **−0.130** | 3 cores | **+2.808** |
| 3 disposable commons | **−0.466** | 3 cores, ante 8 (no runway) | **+0.498** |
| 2 commons + 1 core | +0.634 | 5 cores, full board, ante 2 | **+5.366** |

The reported misplay — Ectoplasm onto a board of sellable commons — now reads **negative** and is declined.
Justified on mechanism, not on the metric: per the frequency ceiling one spectral cannot move an n≥160 batch.

⚠ **TWO ERRORS CAUGHT BY MEASURING RATHER THAN BY READING THE DIFF** (the CLAUDE.md rule, earning its keep):
* the first draft's comment asserted the hand-size cost was **convex** in hand size. The probe refuted it —
  0.33 at hand size 8 but 0.09 at 5, because a smaller hand makes weaker hands so the marginal card has less
  to contribute. Correct in this module's absolute units, but it means Ectoplasm's **stacking** penalty is
  *not* self-pricing; repeated uses are under-charged. Recorded in-code as a known limitation.
* the first draft credited each joker `keep_bias / CORE_KEEP`, which pays a flat common **48%** and left a
  board of three junk commons at **+0.97 — above the 0.7 being replaced.** The fix as first written would
  have made the reported misplay MORE likely. Replaced with the codebase's own binary keeper predicate.

**⏳ THE BULL / ECON-COMMITMENT ITEM IS STILL OPEN** — the opposite class: it moves `build_plan` thresholds
that gate every run, so it needs a paired A/B before anything changes.

**➡ ADJACENT FINDING — the spectral valuation layer is mostly priors. 12 of 18 are unmodelled.** After this
fix **6** spectrals have a real branch in `CV.card_value` — Immolate, Hex, Ankh, Wraith, Ouija, Ectoplasm.
The other **12 return a flat `SPECTRAL_BASE` number** regardless of deck, board or ante: Soul, Black Hole,
Aura, Cryptid, Sigil, Familiar, Grim, Incantation, Talisman, Deja Vu, Trance, Medium.

**Tier 1 — the machinery ALREADY EXISTS, this is wiring not modelling:**
* **Black Hole** is fully measured by `Packs.black_hole_value` (deck-aware, all-hands level gain) — but only
  on the pack-pool path. `card_value` still returns the flat 0.9 and `decision_engine`'s held-use table a
  flat 0.5. The same card is priced three different ways depending on where you meet it.
* **The four SEAL spectrals** — Talisman→Gold, Deja Vu→Red, Trance→Blue, Medium→Purple — all read a flat
  **0.2**, so the engine literally cannot tell them apart. Meanwhile `CV.card_econ_value` prices all four
  seals deck-aware, and a passing test asserts Blue > Gold on a built board.
* **Sigil** (all cards → one suit) is a flat 0.3 with no flush-plan awareness, though `CV.suit_tarot_value`
  does exactly this job for suit tarots.

**Tier 2 — needs real modelling:** Soul (a measured Legendary, not a 1.2 prior — `pack_open_advisor` already
knows it needs a slot), and the destroy-and-add group Aura / Cryptid / Familiar / Grim / Incantation, which
want deck-mutation valuation off `DeckPlan.delete_value` + `CV.card_add_value`.

---

## R7 — same run, three more (2026-09-04): card ORDER, Business Card, Riff-Raff

> Follow-ups from the same owner-followed run. All three were reproduced on a probe before being written
> down, and all three are **confirmed**, not suspected.

- ❓→🔧 **"Can it reorder cards for more score/money?" — YES, the capability is real and complete, but the
  PLAY CHOOSER never sees it.** `engine/ordering.lua` permutes both joker order and card order with a SCORE
  objective and a MONEY objective; its own header names *"first-card retriggers (Hanging Chad) want the
  highest-value card first"*, and the money objective exists for exactly *"a Hanging Chad first-card
  retrigger landing on a Gold-seal card"*. It is wired into `decision_engine:479` and surfaced by
  `ui/overlay.lua:98-108` as a dedicated, untruncated gold **"Reorder:"** line. On the owner's exact setup
  (Greedy Joker + Hanging Chad, Two Pair with the Diamond dealt second) it finds the right answer and the
  swing is enormous:

  | played order | score |
  |---|---|
  | as dealt (`10S 10D 4C 4H`) | 340 |
  | **engine's reorder (`10D 10S 4C 4H`)** | **748 (+408, 2.2×)** |

  by which card leads: `10D` → **748**, `10S` → 340, `4C`/`4H` → 280. The Diamond-first read is exact.
  **⭐ THE BUG IS SEQUENCING, NOT CAPABILITY.** `Ordering.optimize` runs on the play that `best_play` has
  ALREADY chosen, and `best_play` compares candidate subsets **in dealt order**. So on that hand it scored
  Two Pair at 340, High Card `10D` at 350, **picked the High Card — and the blind needed 400.** The Two Pair
  correctly ordered scores 748 and clears; the chosen play does not. Worse, the chosen play is a SINGLE
  card, so there is nothing left to permute and the post-hoc reorder recovers **none** of the 398 lost.
  ⇒ the fix is to make the CHOOSER order-aware for order-sensitive boards, not to touch `ordering.lua`.
- 🔧 **The self-player never reorders CARDS.** `ui/autoplay.lua` has a "PHASE 0 — JOKER REORDER" that applies
  `best.reorder.joker_order` by rewriting `G.jokers.cards` (there is no reorder button in Balatro, it is
  drag-only). `card_order` appears **zero times** in the file. So even when the engine emits the right card
  order, an F11 run plays them as dealt. ⚠ Related UX question for the human path: card scoring order is
  the order in your **hand**, so acting on the tip means DRAGGING cards left before playing — the overlay
  line says `cards 10D 10S 4C 4H` without saying that.
- 🔧 **Business Card is invisible to the in-blind money model.** Owner: *"it had Business Card but only
  played a High Card rather than a Two Pair of face cards despite both being able to win."* `j_business` is
  listed in `joker_effects.VALUE_ONLY` — no scoring/effect hook — so its money never reaches `ev.money`.
  Measured on a 4-face-card Two Pair vs a single non-face High Card, both with Business Card on board:

  | play | model money | real EV |
  |---|---|---|
  | Two Pair, 4 face cards | **$0.00** | ~$4 (4 × ½ × $2) |
  | High Card, 1 non-face | **$0.00** | $0 |

  This matters precisely BECAUSE both plays clear: `HandEval.best_play_target` tier 2 says *"the extra score
  is WASTED overkill, so maximise MONEY"* — and the money it maximises reads $0 either way. The only
  per-card in-blind money the model knows is Rough Gem, Gold seals and Lucky. ⚠ Note the asymmetry with the
  already-shipped work: R5 taught the SKIP advisor about Business Card farming and `DE.DIG_FOR_MONEY`
  handles Faceless (the DISCARD channel), but the PLAY channel — which is Business Card's actual trigger —
  was never taught.
- 🔧 **Riff-Raff is bought with no room for what it makes.** Owner: *"it bought Riff-Raff despite not really
  having any space for extra jokers."* Riff-Raff spawns 2 Common Jokers at blind select **only if a slot is
  free**. `Generators.play_bonus` gates this correctly (`generators.lua:41` requires `joker_slots - njok > 0`)
  and `SA.SLOT_FARM_JOKER` even credits selling a common to reopen a slot for it — but both of those are
  about a Riff-Raff you ALREADY OWN. The BUY path only checks that *a* slot exists (`shop_advisor:839`,
  `slots_free > 0`), never that one will REMAIN afterwards. Measured — the buy value is **byte-identical**
  across every board size:

  | board before buying | slots free after | buy value |
  |---|---|---|
  | 1/5 | 3 | 7.5233 |
  | 2/5 | 2 | 7.5233 |
  | 3/5 | 1 | 7.5233 |
  | **4/5** | **0 — spawns nothing, ever** | **7.5233** |

  This is the documented "**Created things need a SLOT**" convention (CLAUDE.md) applied on the pack path
  (`pack_open_advisor` `gen_fit`) and the tarot path (`SA.CREATES_JOKER`, which lists only `c_judgement`) but
  **never to a generator JOKER bought in the shop**.

**Status: RECORDED, NOT FIXED** — deliberately. All three are live-advice correctness items below the
frequency ceiling, but two of them (the order-aware chooser, and any in-blind money term) touch `hand_eval`'s
hot path, which cascades the seeded RNG in every blind of every run — the highest-variance change class this
project has. They want scoping and a paired A/B, not a quick edit. Riff-Raff's slot gate is the surgical one.

---

## ⭐ R8 — THE DEATH, RECONSTRUCTED FROM TELEMETRY (seed 6EDJFT2Y, ante 4): selling the only Mult

> Owner: *"it also sold Greedy despite having no other plus mult other than levels, which lost it the game,
> just for a To Do List — despite having a Riff-Raff which wasn't doing anything and already having econ from
> interest and Business Card."*
>
> **This one is fully evidenced.** The run is in `bes_runs.jsonl` and the exact shop state is in
> `bes_fixtures.jsonl`, so the decision was **replayed through the current engine** rather than guessed at.
> Every number below is measured, not inferred. It is the first live death this project has traced end to end
> from board state → valuation → the specific line of code that produced it.

**The run, from telemetry:**

| t | event | board after |
|---|---|---|
| 90.8 | buy **Greedy Joker** | Hit the Road, Greedy |
| 156–210 | buy Hanging Chad, Ice Cream | + Chad, Ice Cream |
| 365.1 | **Business Card** from a pack | **5/5 — board now FULL** |
| 501.5 | sell Ice Cream *(decaying — defensible)* | 4/5 |
| 507.4 | **buy Riff-Raff ($6) into the last slot** | **5/5 — Riff-Raff can now never spawn** |
| 730.6 | **sell GREEDY** → buy To Do List ($4, holding $42) | Hit the Road, Chad, Business, Riff-Raff, To Do |
| 903.0 | **DEATH**, ante-4 Boss | — |

**The death record:** target **10,000**, scored **2,149** — **21.5%** of the requirement — holding **$52**
with `hand_level_sum` **5**. ⚠ Note the exact echo of the project's canonical loss (CLAUDE.md: *"X3L32ZEA
died at ante 5 holding $52 — more than most of the wins had"*). **Same $52. Conversion, not resources.**
Of the five jokers on the death board, **three score nothing at all** (Business Card, Riff-Raff, To Do List),
and there are **zero `joker_gain` records after t=507** — Riff-Raff, bought for $6, produced **nothing for
the rest of the run**, exactly as R7 predicted.

**⭐ THE REPLAY — the engine re-run on the real state (`$44`, board and shop as recorded):**

| # | joker | cat | **marginal** | `keep_bias` | `funder_is_live` |
|---|---|---|---|---|---|
| 1 | Hit the Road | xmult_scaling | 9.450 | 2.5 | false |
| 2 | **Greedy Joker** | flat_mult | **1.800 — lowest** | 1.2 | **false → SELLABLE** |
| 3 | Hanging Chad | retrigger | 4.050 | 2.5 | false |
| 4 | Business Card | economy | 3.881 | **0.0** | **true → PROTECTED** |
| 5 | **Riff-Raff** | card_generation | **3.000** | **0.0** | **true → PROTECTED** |

The engine's top sell candidate is **`SELL_JOKER Greedy Joker`** — the reported misplay, reproduced exactly
from the recorded state. Three separate defects compose to produce it:

1. 🔧 **Riff-Raff's marginal reads 3.000 on a FULL board** — 67% more than the only Mult source — although
   its output is structurally impossible. This is R7's slot-blindness appearing in the *marginal*, not just
   the buy price, so it is not merely a shop-time mistake: the dead joker keeps a standing credit forever.
2. 🔧 **⭐ `keep_bias` and `funder_is_live` give OPPOSITE verdicts, and the protective one wins.**
   `keep_bias` scores Riff-Raff **0.0** — it knows perfectly well the joker is not worth keeping. But
   `funder_is_live` (`shop_advisor.lua:481`, added 2026-09-01 for **Vagabond**) protects *any*
   `cat == "card_generation"` joker from being a funder, on the rationale that *"it holds its value in its
   OUTPUT"*. **Riff-Raff is not Vagabond**: Vagabond makes CONSUMABLES (consumable slot), Riff-Raff makes
   JOKERS (joker slot). On a full joker board there IS no output, so the rationale is void — yet the
   protection fires, and the two subsystems never consult each other.
   ⇒ **The surgical fix: the `card_generation` clause must require that the generator can actually produce**
   — a free joker slot for a joker-maker — exactly the gate `generators.lua:41` already applies on the
   play path. That single condition removes Riff-Raff from the protected set and restores the correct funder.
3. 🔧 **Nothing notices the sale leaves the board with no unconditional Mult.** Greedy is `flat_mult` →
   `keep_bias` **1.2** (`SCORER_KEEP`), not `CORE_KEEP`, and `funder_is_live` **deliberately** excludes plain
   scorers (its comment: re-protecting them *"broadened the gate to every joker and dented the sim"*). The
   remaining board reads strong by marginals — Hit the Road 9.450 — but Hit the Road is **conditional and
   resets every round** (xMult per Jack *discarded this round*) and Hanging Chad is a **retrigger**, which
   multiplies nothing by itself; it needs something worth retriggering. Sum-of-marginals cannot see that.
   ⇒ this is the project's #1 open research problem in miniature (CLAUDE.md §31f: **score the board as a
   SET — copiers × xmult × triggers as a PRODUCT**). Mult is a FACTOR: dropping the last one does not cost
   its marginal, it collapses the product. **A live death now demonstrates it concretely.**
4. ❓ **Money was never the constraint — the SLOT was.** To Do List cost **$4** against **$42** held, and it
   died on **$52**. Both ante-4 purchases (Riff-Raff $6, To Do List $4) were non-scoring, bought onto a board
   that already had Business Card plus interest at cap. The owner's *"already having econ"* is exactly right,
   and it is the same conversion failure as the canonical loss run.

**⇒ RANKED next actions.** (2) is surgical, mechanically justified, and directly caused this death — ship it
first. (1) follows from R7 and is the same root cause seen from the sell side. (3) is the research problem
and must not be attempted as a magnitude tweak.

### ✅ (1) AND (2) SHIPPED + DEPLOYED (`b21aa57`) — verified against the recorded state

**(2) `funder_is_live` no longer protects a generator that cannot generate.** The gate is deliberately
**asymmetric**, and that asymmetry is the whole fix: a **consumable** slot frees up as you use it, so a full
tray is a TRANSIENT blockage and gating it would re-open the very Vagabond churn the 2026-09-01 clause was
written to close — so consumable-makers keep their **unconditional** protection and that path is
byte-identical to before. A **joker** slot is scarce and sticky, so a full board is STRUCTURAL. Riff-Raff is
the only `card_generation` joker without the `"consumable"` tag, so **exactly one key** changes behaviour.

**(1) The tier prior no longer assumes the output lands.** ⚠ Note (2) alone would NOT have fixed the misplay
— unprotecting Riff-Raff still left it at **3.000** against Greedy's **1.800**, so the Mult was still the
cheapest thing to sell. Both prior paths are now scaled by `Generators.output_fit`: the sell-side one in
`Eval.jp_from_measure` **and the independent buy-side prior in `shop_advisor.scoring_gain`** (a separate
`tier × 0.3`, which is why patching only the first left the buy value flat — caught by measuring, not by
reading the diff). **No new constant**: `output_fit` reuses `pack_open_advisor`'s existing `gen_fit` and its
`room_credit` reading — Judgement is 0.1 there because *"a RANDOM joker rarely [beats what you sacrifice]"*,
and Riff-Raff makes 2 random **Commons**, strictly weaker, so it takes the same 0.1.

**Replayed on the real R8 state** (`bes_fixtures.jsonl`, board 5/5, $44):

| | before | after |
|---|---|---|
| Riff-Raff marginal | 3.000 (protected) | **0.300 (sellable)** |
| Greedy marginal | 1.800 (sellable) | 1.800 — unchanged |
| **engine advice** | **`SELL Greedy Joker`** | **`SELL Riff-raff` — "frees a slot for To Do List"** |

Buy side, previously **7.5233 on every board size**: 3 slots free after buying **7.0233** · 2 free 7.0233 ·
1 free **2.4333** · 0 free **−2.1567** (declined outright). The three places that ask *"can this generator
produce"* — the blind-select gates, the funder gate and the valuation prior — now route through one shared
helper so they cannot drift apart again.

**Still open from R8: defect (3), the missing board-composition guard.** Unchanged and deliberately so — it
is the board-as-a-SET research problem, not a magnitude tweak. Tests 1149 → **1156**; sim **604/1**, the one
failure being the pre-existing `test_world` overflow case verified unchanged on clean HEAD.

---

## 1. In-blind play & digging (the play engine)

- 🔧 **[R1] Didn't discard a dead low card in a marginal draw.** Opening hand held a 4-diamond flush draw
  *including a 2♦*; it kept the 2♦ chasing the flush, but a flush with a 2 rarely one-shots — the 2 should
  be pitched to dig. *(Nuance found: on that exact hand the discard-selection actually keeps the right high
  cards — see §Discard-selection is OK.)*
- 🔧 **[R1] The first blind should be ~always solvable.** Trivially winnable (no jokers, standard deck,
  red-deck extra discard); the engine took 2 hands where 1 should do with correct dig-play. [confirmed: a1
  small took 2 hands]
- 🔧 **[R1] Ante-3 boss: used one partial hand with lots of card resources instead of digging for one
  winning hand.** [play-vs-discard]
- 🔧 **[R1] Discarded a King that could have scored with Smiley Face + more Kings** (threw a synergy face
  card). [confirmed the board degraded from K/QQ/JJ to Ace-high/low pairs]
- 🔧 **[R1] Played lone face cards without selecting others to dig** — should discard chaff and keep
  set-potential cards; caused the death.
- 🔧 **[R2] The "death spiral".** a3-Big: chased straights all game, missed one card, switched to a
  full-house that scored little, then **played 6 weak hands** (a lone Ace, then pairs) without digging;
  even after luckily drawing an ace-low straight it played seemingly random cards, not looking for another
  straight. Died 80%. [confirmed in the per-hand log]
- 🔧 **[R2] Doesn't commit to the line it's clearly on** (straights all game) — abandons it instead of
  digging toward it.
- **NOTE (validated 2026-08-26): the discard *card-selection* is NOT the bug.** Reproducing R1's boss hand,
  the current logic already keeps K+QQ and scores highest; a synergy-weighted variant scored *lower* and
  threw the King. So the real issue is the **PLAY-vs-DISCARD decision** (choosing to play a weak made hand
  instead of discarding to dig), not which cards to throw.

## 2. Money-farming / "milk" spare resources — RECURRING, HIGH VALUE

- 🔧 **[R1] Bought an $8 Arcana pack with good scoring + little need**, dropping under the interest cap and
  gutting a would-be Hermit's payout (so it didn't take Hermit).
- 🔧 **[R2] Cleared blinds immediately with hands/discards to spare instead of farming money.** With
  Faceless (+$ per face card discarded) + Pareidolia (all cards face), every spare discard was free money.
  [confirmed: a1-Boss cleared 1184/600 with **3 hands + 2 discards unused**; a2-Big 1820/1200 with **4 hands
  + 1 discard unused**; happened almost every blind]
- 🔧 **[R2] Once the winning hand was secured it played immediately** rather than spending 2 spare discards
  for ~$10 from Faceless first — "$5 from Faceless outweighs using the hands." Did this **many times**.
- 🔧 **[R2] Discarded only 2 when it could discard 3**, missing money generation — repeatedly.
- 🔧 **[R2] Without Pareidolia it would never have used Faceless at all** — holds the money engine but does
  not leverage it.

## 3. Joker churn (buy-then-sell) & sell-value — CLEAR BUG

- 🔧 **[R2] Buys jokers then immediately says to sell them.** Confirmed pairs: **+Wily→−Wily,
  +Burglar→−Burglar, +Ride the Bus→−Ride the Bus, +Pareidolia→−Pareidolia**. Pure waste (buy price sunk).
- 🔧 **[R1/R2] Took a joker just to sell it, but picked the wrong one.** Took **Ride the Bus** (to sell)
  when **Sixth Sense** was available and **sells for more** — free money left on the table from the pack.
- 🔧 **[R2] Sold a synergy piece for a dead one.** Dumped Pareidolia (its only Faceless enabler) for
  **Satellite**, which produced nothing (it never bought planets).

## 4. Consumable usage (held / timing)

- 🔧 **[R2] Held consumables unused all game.** Only **1** consumable used the entire run; sat on **Hermit**
  and **High Priestess**. [confirmed]
- 🔧 **[R2] Got Hermit but didn't use it immediately** due to inefficient spending; later, with >$20, still
  didn't use it — and opened a tarot pack that **blocked** the useful Hermit.

## 5. Pack ordering & timing

- 🔧 **[R2] Buys shop jokers/vouchers BEFORE opening packs.** e.g. bought Hiker then a Buffoon; said buy a
  voucher before opening a pack. Should **open packs first** — the pack may contain the joker/Hermit that
  makes the buy pointless (Hiker gives no scoring anyway). [FIXED: when a shop buy AND a positive-value
  pack both fit this shop, the shop advisor now leads with the pack (non-lossy reorder — the buy stays an
  affordable alternative). Advice-sequencing; sim impact bounded (both actions still happen), not A/B'd.]
- ❓ **[R2] Opening the bigger/more expensive pack first is questionable** — spending down first lowers a
  later Hermit's payout; sequence money-tarots against current cash.

## 6. Deck-shaping / tarot valuation

- 🔧 **[R1] Took Tower (Stone card, ~nothing) over Strength** (Q→K), which builds toward K-based
  three/four/five-of-a-kind — undervalues deck concentration. [confirmed: Strength was in the pack; engine
  narrated "Face build" yet shaped away from it]
- 🔧 **[R2] Picked Wheel of Fortune** (low edition chance, and the jokers were temporary anyway) over
  destroying a card (e.g. a King) — and generally undervalues deck-shaping (Hanged Man).
- 🔧 **[R2] For Faceless, kept 2 Jacks while going for straights** (which need only one) — redundant with
  Pareidolia (all cards already face). **Reminder: debuffed cards don't count for Faceless.**

## 7. Skip / blind-select

- 🔧 **[R1] Took the Uncommon-Joker skip tag** with strong scoring + money over the interest cap — a weak
  tag, and skipping forfeits interest + blind money + a whole shop ("free reroll"). Skip less in white stake.
- ✅ **[R1] Correctly took the Investment tag** at $0 with no interest/econ.

## 8. Reroll discipline

- 🔧 **[R2] Rerolled with many good options present** (tarot, packs, voucher), leaving too little money to
  buy them while staying liquid.

## 9. Planets

- 🔧 **[R2] Rarely buys planets** in live play — contradicts the sim, which was buying several. Bought
  Satellite ($/planet) while buying zero planets, so it did nothing.

## 10. Overlay UX

- 🎨 **[R1] Pack size/cost was in small grey text, not the main line**; didn't differentiate small vs medium
  (only "Mega"). [FIXED: main line now shows size + pick + cost]
- 🎨 **[R1] The target card ("apply to which card") should be in the main line, not grey.** [partly done for
  owned/shop tarots]
- 🎨 **[R1] "Discard QH" was ambiguous** between a steel and a standard Queen of Hearts. [FIXED:
  "QH (steel)" vs "QH (plain)"]
- 🎨 **[R2] Still no main-line target text for applying Empress *inside a PACK*** — present for owned
  consumables but not pack picks. [FIXED: pack advisor returns `target_note`; big line shows "Take
  Empress — apply to AS, KS"]
- 🎨 **[R2] Should say "Play blind" at a boss with no skip option** (currently shows nothing). [FIXED:
  blind-select falls back to a CONTINUE "Play blind — the boss can't be skipped." action]

## 11. Method / efficiency questions

- ❓ **[R2] Run Monte-Carlo once the hand is fully drawn, not after every individual card** drawn/played/
  discarded — it recomputes nearly the same thing repeatedly (compute + lag). [valid optimisation]
- ❓ **[R1] Can we just A/B both sides for winrate when changing a constant?** Yes — but autonomous winrate
  is a weak, chaotic signal for subtle/advice changes, so validate each fix with the sharpest measure
  (per-blind scoring, agreement vs the human's actual plays, or the "run both sides" hand check).

## 12. Positives (what it got right)

- ✅ **[R1] Investment tag** at $0 (see §7).
- ✅ **[R2] Kept two pairs to chase three-of-a-kind for Wily** in the first big blind.
- ✅ **[R2] Took Pareidolia for Faceless synergy.**

---

### Status (see the session commits / MCTS is unrelated)

**✅ SHIPPED + DEPLOYED (this review pass):**
- **Ankh/Hex valuation** — 0-jokers = 0; else value = duplicating your BEST joker (sell weaker first).
- **Overlay UX** — cost + pack size + pick-count in the big line; steel/plain duplicate disambiguation.
- **Per-hand PLAY/DISCARD telemetry** — logs what was actually played/discarded (enabled §1/§2 diagnosis).
- **§3 churn** (first-pass) — `SA.TIER_FUNDER_FLOOR`: don't dump a decent joker as a free SELL_TO_BUY funder.
- **§2 money-dig** — `DE.DIG_FOR_MONEY`: with Faceless, dig 3+ face cards for the $5 before playing a locked
  clear (debuff-aware — a debuffed face doesn't count). Chains through the discards, keeps the clear.
- **§4 held consumables** — use a maxed income consumable (Hermit ≥$20) now instead of sitting on it.
- **§10 UX** — "Play blind" at an unskippable boss; pack-pick tarot target card in the big line.
- **§5 pack-first** — lead with an affordable pack before a shop buy when both fit (non-lossy reorder).

**⏳ REMAINING = the valuation / in-blind-play FRONTIER (each needs paired A/B, not a quick ship):**
- **§6 deck-shaping / tarot valuation** (Tower-over-Strength, Wheel-over-deathing-a-King) — the documented
  commitment→valuation lever; must be co-calibrated + A/B'd, never an isolated magnitude change.
- **§1 play-spiral / line-commitment** — the in-blind engine abandoning a straight/set line under pressure.
- **§8 reroll discipline** — already heavily tuned; touching it is exactly the risky class.
- **§9 planets rarely bought**, **§7 skip discipline** — leveling/skip levers, operating-point dependent.
- **§11 MC-timing** — the expensive sim is ALREADY debounced to the settled hand (main.lua scheduler); the
  per-card recompute is the CHEAP pass. Needs live profiling before changing, not a blind edit.

**➡ Best next step: a fresh live run** to validate the shipped fixes behaviourally (churn, money-dig,
Hermit-use, pack-first, UX) and surface the next REAL gap — more informative than speculatively tuning the
frontier levers without signal.
