# NEXT_SESSION.md — fresh-session handoff

## ⭐⭐⭐⭐ START HERE (2026-09-28)
**LIVE INSTALL = `42a867f`**: best-trade swap SHIPPED (pooled 320 seeds 86 -> 100 wins, 26.9% -> 31.3%); `main` synced to
the branch tip; `BES_DIG_HANDS` stays OFF. Tests 1278 unit + 605 sim. Sim baselines: `sim_out/{sw17,sw17_7}.jsonl` (= live).
The owner is running unattended F11 + F6 runs on this build. **Next session, in order:**
1. **Review those runs** (the R17 method): outcomes + average length; `bes_autoplay.log` for live-only failures
   ("pick unusable", "button not found" other than cash_out, FORCED, stalls); live vs sim (win rate, death ante,
   death BLIND -- is the Big-blind gap still there?); does it now SWAP jokers live (look for "frees a slot for ... a
   clear upgrade")? Replay any misplay from `bes_fixtures.jsonl` before theorising.
2. **Big-blind / weaker live boards** (R17b): live Small clears x1.22 vs sim x1.43 -- find where live boards lose
   strength (purchases, skips, money into each ante), with more runs.
3. **Ante-1 jokerless deaths** (R17b): price the jokerless board's survival risk in the first shop (not a flat bump).
4. Dig-aware joker valuation per-joker / MC dig (R17b); the remaining no-flat items; shop speed.
Ops: `%TMP%/bes/arm.sh <name> <worktree> <workers> [n] [seed_off] [ENV=VAL]` (resumable; memory reaps come from
Chrome/Steam/Discord, not the ~14 MB workers); owner authorises self-restart after reaps.


## ⭐⭐⭐ 2026-09-27 (later) — R17b: MORE UNATTENDED RUNS + "THE BOARD NEVER CHANGES" ROOT CAUSES
Runs: KGJ9UMQH a5 Boss, 7Y3LRJJG **a1 Small (297/300)**, HMNFE4W2 a5 Boss, 2YD6L372 a8 Big (.79). 0 wins.
- The overlay flip ("sell Swashbuckler for Green Joker" -> skip; pack picks changing at the last second) was the
  provisional pass being DISPLAYED (the self-player correctly waited) -> `2aa00f9` shows "Evaluating pack..." until decided.
- ⭐ TWO ROOT CAUSES of "never changes jokers / keeps redundant flat mults / rerolled past Trio" (owner: keep in mind):
  1. **Joker value is measured on ONE 8-card deal with no discards.** Live 2YD6L372 (Pair build + Duo): swapping
     Lusty for Trio = -25% on single deals, **+40% (heuristic dig) / +44% (MC dig)** when each board digs with its own
     jokers; Swashbuckler->Trio +49% / +85%. Conditional multipliers are worth what you dig toward.
     `c8503f4` BES_DIG_HANDS=1 (default OFF): content-seeded deals shared across a decision, each board digs with
     its own jokers (Heuristics.best_discard), cached. Late shops 1.7s -> 3.1s.
  2. **The full-board swap only weighed selling the ONE weakest joker** (there a protected Sock and Buskin). `c8503f4`
     best-trade swap: every offer vs selling EACH owned joker (same protections); runs before a reroll that would
     replace its target. Replay: "Sell Swashbuckler (+$2) -- frees a slot for The Trio".
  Also: Sock and Buskin measured LOWEST raw (2208 pts vs flats 2648-5512) -- mult is additive and Duo doubles it, while
  S&B only helps scored faces; on DUG hands S&B/Trio gain (Pair builds dig for face pairs).
- **RESULTS (n=160 paired, 2026-09-28):**
  | arm | vs | progress | sign | wins | reach-8 | verdict |
  |---|---|---|---|---|---|---|
  | `sw17` c8503f4 (best-trade swap) | base17 | **+0.140 (p 0.076)** | 31/20, **109 tied** | 44 -> **54** | 54 -> 58 | promising -> OOS |
  | `sw17_7` (OOS, BES_SEED_OFF=7) | base17_7 | +0.045 (p 0.51) | 25/26, 109 tied | 42 -> **46** | 59 -> 57 | **SHIPPED** -- pooled 320: wins 86 -> 100 (26.9% -> 31.3%), positive on both pools |
  | `dig17` (+ BES_DIG_HANDS=1) | sw17 | -0.310 (p 0.18) | 66/73 | 54 -> 48 | 58 -> 58 | NOT shipped (flag stays OFF). The single-deal measure is still wrong in principle (Trio -25% vs +40% dug), but pricing every joker on heuristic-dug hands did not convert -- likely over-credits conditional jokers the play engine then fails to dig for; revisit with the MC dig or per-joker, not wholesale |
- Pack picks already use the best-trade bar (`weakest_owned_joker` = min over owned of c*(1+slope*c)+max(margin,kb)),
  so the shop was the only path with the fixed-weakest flaw.
- **Big-blind deaths (live vs sim, antes 4+):** live plays MORE blinds (Small 91% vs 79%, Big 82% vs 76%) and its
  boards clear the Small by LESS (median x1.22 vs x1.43; 58% vs 39% of Small clears under x1.3) -- live boards run
  ~15% weaker entering an ante, and the 1.5x Big is where that shows. Per-hand scoring is faithful (1.05), so the
  gap is upstream (purchases/skips). Sample: 34 live ante-states / 12 runs -- collect more before acting.
- **Ante-1 deaths (sim ~3%):** the engine enters the ante-1 Big with NO jokers in 58% of runs (90/155); 3% of those
  die (0/65 with a joker). Cause: the first shop at ~$10 opens a Celestial/Spectral pack (valued 7-11) over an
  affordable joker (e.g. Crafty 3.05). Worth ~0.5 wins/160; the right fix prices the jokerless board's survival
  risk (pace risk read ~1% where the real death rate is 3%) -- not a flat first-scorer bump.
- 7Y3LRJJG ante-1 death: each step defensible (dug 4 discards for a one-hand clear, then 297/300); but the sim dies at
  ante 1 in ~4% of runs -- investigate (competent play never loses ante 1).

## ⭐⭐⭐ 2026-09-27 — R17: FIRST UNATTENDED RUNS (auto-restart F6) — LIVE INSTALL `b76d453`
5 complete unattended runs (13:58-15:30) + 1 partial: K1MG6F66 a6 Big (.77), JDBPAMG6 a4 Boss (.87), RE4MB8K5 **a8 Big (.94)**,
TDD21SIX a5 Big (.92), S79XPZDS a7 Boss (.72). **0 wins; mean run length 17.3 min.** Auto-restart fired 5/5 times.
Found + FIXED (`b76d453`, live-only -- 3 pack picks LOST in 5 runs): Cryptid had no selected card (T.SPECTRAL_TARGET gains
c_cryptid); a Fool with a full tray and a Fool whose last-used card was a Fool (game can_use) -> card-making tarots need a
free slot: "Use <held planet> first" step (USE_CONSUMABLE allowed in the pack channel) else valued 0; fixtures now record
last_tarot_planet (it was dropped, so every replay saw "nothing to copy").
**Live vs sim (9 recent live runs vs 320 sim runs of the ~same engine, at2+at2_7):**
- scoring is FAITHFUL: 224 live hands re-scored from the recorded state -> actual/predicted = 1.05 (misses are Lucky/
  Bloodstone randomness + boss debuffs the quick re-score omits).
- death ante: live mean 5.8 vs sim 6.1; reach ante 6+: live 5/9 vs sim 58% -- similar. 0 wins in 9 at 28% = p 0.06.
- ⭐ **DEATHS ON THE BIG BLIND: live 6/9 vs sim 20% (ante 4+ deaths, n=182) -- p 0.003. REAL, UNEXPLAINED.** Every live
  Big-blind death came after a barely-cleared Small (ratio 1.06-1.25). Next: (1) compare Big-blind SKIP rates (sim skips
  22% of ante-4+ Big blinds; live blind_select records mix shop advice -- log the skip decision cleanly first), (2) compare
  board power entering each ante live vs sim, (3) the 20 FORCED shop actions (a shop decision took >3 s).

## ⭐⭐⭐ 2026-09-26 (evening) — R16 LIVE REVIEW (seed BQ63E388, died ante 6 by ~200 chips, $40-65 most of the run)
| owner observation | verdict | fix |
|---|---|---|
| picked one tarot then switched to Strength; Black Hole shown then Mercury taken | (a) Justice was SELECTED on the empty-hand state (Arcana/Spectral packs deal the hand a beat after opening) -- a self-player hole; (b) Black Hole -> Mercury was the overlay moving from the provisional to the measured pick | `08fde99` pre-deal tarot/spectral pack decisions are provisional (LIVE); (b) see next row |
| Mercury over Black Hole | REAL: the committed-Pair planet_credit went to Mercury only; Black Hole levels Pair too | `3cb4fe9` Packs.black_hole_value adds every hand's credit (BH .574 vs Mercury .435) |
| never bought vouchers; skipped Overstock while rerolling ~20x at $40-65 | REAL: Overstock was hard 0 ("not modelled"); Reroll Surplus used a flat 0.23 rerolls/shop (measured by bankroll: <$15 .02, 15-24 .06, 25-39 .23, 40+ .88) | `3cb4fe9` Overstock = the reroll's measured gross per-card value x shop views left x 0.5; Reroll Surplus bankroll-aware |
| bought planets but held them (blocks the same planet from the shop) | REAL (game rule: a held card isn't re-offered; Showman lifts it) | `3cb4fe9` shop proposes USE for held planets (not with Observatory/Perkeo); `f359a04` sim now enforces the no-duplicate rule |
| Emperor not bought (2nd time) | it is back on the flat 0.25 prior (audit batch reverted): -1.60 at $27 | pending the audit retry. The sim does NOT log Emperor-created tarots, so their realised value can't be measured yet -- add that logging first |
| Neptune bought / Mercury-heavy with Ancient Joker; Investment skip at $27; Gros Michel / Bloodstone / Death skipped; purple-seal cards kept; board unchanged 5 antes | judgement calls / the build-assembly wall; Neptune/Mercury partly the old frequency model (live was on dig-aware freq) | none this round |
**R16 RESULTS (n=160 paired vs `b16` = f359a04):**
| arm | what | progress | sign | wins | reach-8 | verdict |
|---|---|---|---|---|---|---|
| `r16` 3cb4fe9 | all four | -0.327 | 47/64 | 37->35 | 51->47 | INVALID: the sim could not execute a shop planet-use, and a refused action ENDS the shop visit (fixed `8cfbc52`) |
| `r16b` 8cfbc52 | all four, sim fixed | -0.172 (p 0.30) | 48/67 | 37->37 | 51->46 | split |
| `r16c` | vouchers + BH only | -0.163 (p 0.063) | 12/24, 124 tied | 37->32 | 51->44 | voucher part REVERTED (`718c7ba`): Overstock at 8-21 FV bought at antes 1-2 |
| r16b vs r16c | planet-use alone | -0.010 (p 0.95) | 47/63 | 32->37 | 44->46 | kept |
| `r16d` 718c7ba | planet-use + BH credit | -0.050 (p 0.75) | 49/62 | 37->36 | 51->50 | SHIPPED (correctness; neutral) |
**OVERNIGHT 2026-09-27 (vs r16d; OOS = BES_SEED_OFF=7):**
| arm | what | in-sample | OOS | verdict |
|---|---|---|---|---|
| `at2m` (40 runs) | measure Emperor/HP output use | Emperor outputs used 17/22 = 0.77, HP 24/24 = 1.00 | -- | -> CV.GEN_USE_RATE |
| `at2` | no-flat audit batch 1 retried (+ use rates) | +0.009, wins 36->**47**, reach-8 +6 (McNemar 33/22, p 0.18) | -0.058, wins 49->**43**, reach-8 -5 | did NOT replicate; pooled ~null (+5 wins/320). SHIPPED as correctness (owner no-flat rule), not as a gain |
| `ov2` | Overstock gated to money above the interest cap | -0.038, 142 tied, wins 36->35 | -- | neutral (fires only when rich); SHIPPED (was a hard 0) |
+ `d399bbc` Gold seal / Lucky money counts retriggers (Chad etc.) -- rare, on mechanism.
**LIVE INSTALL = `d399bbc`** (2026-09-27, verified 0 diffs). Baselines on disk: `sim_out/{r16d,r16d7,at2,at2_7,ov2}.jsonl`
(the live engine ~= at2+ov2+retriggers: use at2/at2_7 as its reference until a fresh arm is run). Overnight: `at2` (audit batch retry with the
MEASURED use rate of Emperor/HP outputs -- sim now logs gen_made/gen_used) and `ov2` (Overstock gated to money above the
interest cap), both vs r16d. Runner: `%TMP%/bes/arm.sh` (resumable; restart after memory reaps).

## ⭐⭐⭐ 2026-09-26 (later) — R15 LIVE REVIEW (seed 978TLFTS, died ante 5) — LIVE INSTALL `3cc50c6`
| owner observation | verdict | fix |
|---|---|---|
| Hex used on a FULL board, destroyed 4 jokers (incl. the Hanging Chad just bought) | REAL -- a SELF-PLAYER bug, not valuation: the measured pass said SKIP (Hex -4.2); the skip click failed (button not rendered), the re-evaluation surfaced the INSTANT priors-only pass ("Take Hex", flat 0.6) and the stuck-state deadlock-breaker forced it through | `9df76ae`: the instant pack pass is marked provisional; Autoplay never executes it (own 20 s valve, not bypassed by `forced`); the cheap pass prices Hex/Ankh by their real formula. Regression test verified to FAIL without the gate |
| Riff-Raff: never sold weak jokers to make room | REAL: on a full board the dead spawner was itself the weakest joker, so the flat-constant farm rule never fired | `3cc50c6`: farm sale = weakest NON-spawner, credited with the measured Common a freed slot lands + cash (flat 0.5/0.3 retired) |
| Foil 2 / Foil Ace over Gold-seal cards (Hanging Chad) | close calls on that board: Foil 2 .082 vs Gold-seal 7 .073; Foil Ace .226 (Scholar pays Aces) vs Gold-seal Mult 4 .105; Chad was bought AFTER both packs | none. Open: the Gold-seal $ in card_econ_value ignores a Chad retrigger (the in-blind money model is retrigger-aware; the card valuation is not) -- fold into the no-flat audit retry |
| died ante 5, meh jokers, no xmult | the known build-assembly wall | none |

## ⭐⭐⭐ 2026-09-26 — R14 LIVE REVIEW (seed 5XX3FFG3, died ante 5 on a flat-mult board) — read with START HERE below

Owner report -> what the replay loop found (`bes_fixtures.jsonl`, 236 states; `bes_autoplay.log` 00:21-00:45):
| owner observation | verdict | fix |
|---|---|---|
| Emperor offered with surplus $, not bought | REAL: valued +1.95, but a reroll (+3.34) ranked higher and REPLACED it; same for Strength (+1.15) | `e2aef5a` buy-before-reroll (shop_advisor, mirrors pack-first) |
| Skipped a Standard pack with a Purple-seal Stone Queen | REAL: Purple seal was a FLAT +0.10; card-add values were NOISE (foil King -0.41 on a Photograph board) | `e2aef5a` seals priced like generator jokers (live-measured cards drawn/blind); `card_add_value` PAIRED (same hand +/- the card x P(drawn)) -> Stone/Purple +0.477 taken, foil King +0.029 |
| Strength ignored (3->4 for Hack/Walkie/Even Steven; J->Q for Shoot the Moon) | REAL: Strength/Death were FLAT priors (0.15/0.12), and Strength was aimed at the most build-relevant card (a 10 -> J LOSES Walkie) | `e2aef5a` `T.strength_targets` (gain in joker triggers from the rank-up), used by value/advice/sim; rank tarots measured -> 0.758, taken over High Priestess |
| Discarded Queens with Shoot the Moon | PLAUSIBLE: discard candidates were joker-blind (keep-scoring-cards pitched every held card) | `7d0ca6a` board-aware discard candidates (MC still decides; no weight) |
| Bought ~3 planets from the shop early (Pluto/Mercury/Venus) | REAL, and SYSTEMIC -- see item 1 below | NOT fixed yet |
| First blind: played a 260/300 Straight with 4 discards (a hand = $1) | marginal: 2nd hand is a certain clear; a dig clears in one hand only ~half the time -> ~$0.5 EV. Dig objective rewrites measured neutral twice (09-19) | none |
| Took Green Joker | it was FREE (Top-up tag) and sold soon after -- fine | none |
| Shop recorder | fixtures/telemetry never recorded shop TAROTS/PLANETS, so consumable buys could not be replayed | `e2aef5a` (replay_fixture, main, run_telemetry) |

**Sim arms (n=160, vs `sim_out/f1.jsonl` = live 0ed0a6d):** `s1` = `e2aef5a` (shop/seal/Strength/paired), `s2` = `7d0ca6a`
(s1 + discard candidates). Owner rule: sim OUTCOMES decide; replicate OOS if kept on a mean.
**R14 RESULTS (n=160 paired):**
| arm | vs | progress | sign | wins | reach-7 / reach-8 | verdict |
|---|---|---|---|---|---|---|
| `s1` e2aef5a | f1 (live) | +0.226 (p 0.17) | 74/56 | 36 -> **42** | 61->67 / 47->48 | KEPT (correctness, positive) |
| `s2` 7d0ca6a | s1 | +0.139 (p 0.27) | 47/40, 73 tied | 42 -> **43** | 67->75 / 48->52 | KEPT |
| `fid` b984dc9 | s2 | -0.130 (p 0.33) | 51/54 | 43 -> 39 | 75->67 / 52->48 | FIDELITY (sim shop had 0 discards; live 4) -- kept; the honest baseline from here |
| `hf` f22edfc | fid | +0.046 (p 0.81) | 69/79, 12 tied | 39 -> 38 | 67->70 / 48->50 | KEPT (correctness; null). Levels moved High Card .13->.05, Pair .18->.11, Straight .13->.21, Flush .10->.16 |
fid exposed a guessed constant: Banner buys 0 -> 28 once the sim shop saw discards, because the "discards held at play"
was assumed = the full budget unless the board digs. MEASURED (4061 sim plays): 36.4% of plays at 0 discards, else 75%
of budget held, flat across builds -> `e74d263` prices Banner/Mystic Summit at that mixture in JokerValue.score_delta.
| `au` e74d263 | hf | -0.194 (p 0.29) | 66/73 | 38 -> 33 | 70->59 / 50->44 | NOT deployed -- split into `at` (b816068, audit batch 1 alone) and `bm` (hf + Banner/Mystic alone) to find the cost. Emperor use 18->73 (2 x mean random tarot, which carries Hermit's $) displaced Strength 78->51 / Hierophant 84->57; Mystic Summit buys 0->14 |
| `at` b816068 | hf | -0.118 (p 0.51) | 64/73 | 38 -> 35 | 70->65 / 50->45 | REVERTED (04f2457) |
| `bm` a329292 | hf | -0.139 (p 0.15) | 31/43, 86 tied | 38 -> 37 | 70->65 / 50->47 | REVERTED (a727f25) |
All three (au/at/bm) lean negative and shed the tail, so neither part ships. The GOAL stands (owner: no flat scores);
the measured versions need a second look before a retry: (1) Emperor use 18->73 -- its 2 random tarots are valued at
the pool MEAN, but the play engine holds/wastes many card tarots (CARD_USE_MIN_FRAC gate), so the REALISED value is
lower: measure realised tarot value per random tarot in the sim before pricing a generator by the mean; (2) Mystic
Summit bought 0->14 at the measured 36%-at-0-discards mixture -- that share comes from boards WITHOUT Mystic; check
whether the Mystic timing policy (dig to 0) costs more than it earns. Code is in the reverted commits (git show).
**LIVE INSTALL = `f22edfc`** (s2 + dig-aware frequencies; the fid commit is sim-only). Verified 0 diffs. Branch engine
== f22edfc.
**✅ CONFIRMED (same corrected sim = fid on both sides; old live `0ed0a6d`+fid vs live `f22edfc`):**
| pool | old live | live f22edfc | progress | sign | reach-8 |
|---|---|---|---|---|---|
| in-sample (s*1000+3) | 32/160 (20.0%) | **38/160 (23.8%)** | +0.230 (p 0.28) | 77/72 | 45 -> 50 |
| **OOS (s*1000+7)** | 28/160 (17.5%) | **49/160 (30.6%)** | **+0.477 (p 0.022)** | 86/62 | **35 -> 56 (McNemar p 0.009)** |
Pooled 320 seeds: **60 -> 87 wins (18.8% -> 27.2%)**. Files: sim_out/{f1fid,hf,f1fid7,hf7}.jsonl (the new baselines).
Mechanisms fire (s1 vs f1): Strength used 22->70, Death 11->80, purple-seal picks 23->70, 82 buy-before-reroll.
(was live `7d0ca6a` earlier on 2026-09-26.) Sim win rate 43/160 = **26.9%** (in-sample).
Queued arms (worktrees `../bes_wt_*`): `fid` b984dc9 (sim shop sees the discard budget -- fidelity, kept regardless),
`hf` f22edfc (dig-aware hand frequencies, vs fid), `au` b816068 (no-flat audit batch 1, vs hf). Then an OOS
replication (BES_SEED_OFF=7) of the final stack vs f1 before calling the gain real.

**Next, in priority:**
1. **Planet frequency is FIRST-DRAW, not PLAYED.** `CV.hand_frequencies` = best play of ONE 8-card draw, no discards.
   Measured (f1, antes 1-2, 1260 plays): the engine PLAYS Straight .181 / Flush .178 / Full House .171 / Pair .115 /
   High Card .049, but first-draw says Straight .093 / Flush .061 / FH .065 / Pair .318 / High Card .062. So Pair/High
   Card planets are over-priced ~2-3x and Straight/Flush/FH under-priced ~2-3x -- every planet, Celestial pick,
   Black Hole and the commitment read it. (Pluto flipped buy/skip on 2 of 8 seeds from the 1/8 quantisation alone.)
   Fix = a dig-aware frequency (measure the engine's played distribution per deck), NOT a hand-type fudge table.
2. **The no-flat-scores audit (owner rule 2026-09-26, memory `no-flat-scores`).** Remaining flats: `CV.TAROT_BASE`
   (and card_value still falls back to it when a measured tarot is <= 0), `CV.SPECTRAL_BASE` fallbacks, Gold card /
   Gold seal / Lucky $ in `CV.card_econ_value` (one round's worth, not x rounds left like the seals now), planet 0.3
   fallback, `T.THIN_CREDIT`, `T.CARD_PERM_CREDIT`, Packs `QUALITY_FRAC`/`CARD_W`, `PERKEO_HOLD`.
3. The rest of START HERE's list (Business Card $ in the retrigger projection, Burnt aim in digs, last 3 tier priors).

## ⭐⭐⭐ START HERE (2026-09-25 end of session) — STATE, WIN-RATE HISTORY, AND THE NEXT FEW SESSIONS

**Live install = `0ed0a6d`** (restart Balatro after any deploy -- no hot reload). Tests: `lua tests/runner.lua` (1264 pass).
Everything below the "R13" and "R12/R11" blocks is the detailed audit trail.

### Sim win-rate checkpoints (autonomous engine, red deck / white stake, same 160-seed pool unless noted)
One seed = 0.6 pp; paired differences under ~3 pp are noise. Earlier eras are NOT strictly comparable (the sim world
itself changed -- e.g. 2026-08-28 faithful jokers HALVED the rate 5% -> 2.5%).
| date | build / arm | win rate |
|---|---|---|
| 2026-08-12 | first human-vs-engine dataset (engine 12/960) | 1.3% (human 7/8 = 87.5%) |
| 2026-08-25 | `slotfix_base` baseline (rich10 probe: 23.8%) | 2.5% |
| 2026-09-02 | `wire_base160` | 5.6% |
| 2026-09-18 | WINRATE V4 fresh baseline `v4_base` | 8.1% |
| 2026-09-23 | R11 start `hc_ab_before` | 6.2% |
| 2026-09-23 | held-card fix -> money-only -> vouchers (`vo_ab_after`) | 9.4% -> 10.6% -> 12.5% |
| 2026-09-23 | calibrated pace risk `risk_after` (OOS pool: 18.1%) | 17.5% |
| 2026-09-24 | R12 inert jokers / core protection `r12c` | 15.0% |
| 2026-09-25 | resource table `v1` -> generators `g1` -> retrigger projection `y1` | 16.2% -> 20.6% -> 20.0% |
| 2026-09-25 | forward valuation, fast `f1` (OOS pool, slow version: 20.0%) | 22.5% |
| 2026-09-26 | sim FIDELITY fix (shop sees discards) re-baselines f1 -> `f1fid` | 20.0% (OOS 17.5%) |
| 2026-09-26 | **R14 `f22edfc` (LIVE): buy-before-reroll, seals, Strength, paired cards, discards, dig-aware freq** | **23.8% (OOS 30.6%)** |

### What the next few sessions should do (in rough priority)
1. **Live F11 run on `0ed0a6d` and review it** (the replay loop in CLAUDE.md). A lot shipped at once: watch the Burnt
   first-discard and Sixth Sense lone-8 discards (spare cards only, never the clearing hand), Hanging Chad valued
   higher (forward/per-card projection), no Oops/Luchador/Mime buys with nothing to use them on, shop speed (~4-6 s
   on heavy late shops -- was 8.7-10.6 s before the speed-up).
2. **Money in the retrigger projection**: Business Card (and Rough Gem) pay MONEY per scored card, which score_delta
   cannot see -- so Hanging Chad x Business Card is still undervalued (owner's example). Price retriggered per-card $.
3. **Burnt aiming during digs**: 80% of first discards are digs (no clear in hand) that level their chaff (quality
   0.56). Steer the dig's discard set toward a hand worth levelling when the dig value is ~equal.
4. **Last three tier priors**: Mr Bones (one-shot death save -- 98% of deaths qualify; the open question is what a
   saved blind is worth), Diet Cola (free Double Tag on sale), Credit Card (-$20 loan). Low frequency.
5. **Refinements with an estimate inside them** (measure, don't guess): Perkeo `PERKEO_HOLD` 0.3; Merry Andy / Turtle
   Bean multi-unit resource gains extrapolated linearly from +1; Chicot uses the board-AVERAGED boss cost (scale it by
   board strength like the resource table); flip bosses (Wheel/Fish/House/Mark) read 0 because the engine sees
   face-down cards (known limitation, owner: do not fix).
6. **The tier floor stays.** Every removal test lost wins (latest z2 vs z1: -0.256, p 0.049). The remaining gap is
   early CONDITIONAL multipliers (Photograph / The Order / The Tribe) whose worth is the board they will multiply --
   the board-as-a-SET problem. Only retry with a genuinely new model (not a constant, not one class scaled alone:
   x1 proved that distorts the ranking).
7. **Ops**: run A/B arms from a git worktree at <= 6 workers while the owner is using the PC (Claude Code reaps
   background shells on low memory; the PC itself crashed once); 11 workers when idle. The luajit workers survive a
   reap and `tools/sim_par.sh`'s wrapper may too -- VERIFY unique finished seeds before deleting anything; resume an
   interrupted batch with `tools/run_seeds.lua` (deterministic, verified identical). Tools added: `burnt_aim.lua`,
   `resource_value.lua`, `boss_cost.lua`, `run_seeds.lua`.

## ⭐⭐⭐ 2026-09-25 — R13: MEASURE THE UNMODELLED JOKERS (so the tier floor can go) — read FIRST

Goal (owner): every joker priced by measurement, then drop the tier floor. The floor exists because unmodelled
jokers keep a flat tier prior; removing it with them unmodelled cost wins (r12 28->15, u2 24->18).
**Measured / shipped this block (install = `b89a643`, v1):**
1. Burnt: always spends the first discard when the clear is in hand (spare cards only); valued with MEASURED
   BURNT_QUALITY 0.560 / BURNT_FIRE 0.831 (`tools/burnt_aim.lua`, 1265 sim rounds).
2. Resource jokers from a FULL-ENGINE table (`tools/resource_value.lua`, 88 recorded boards, next-ante boss):
   +1 discard +4.6%, +1 hand size +9.3%, +1 hand +5.8% output, by board strength (`Eval.resource_gain`). The greedy
   rollout was off 1.7x (hand size/hands high, discards low). Drunkard/Merry Andy/Juggler/Troubadour/Turtle/
   Burglar priced by lookup. v1 vs u: +0.048, 94 tied, wins 24->26, reach-7 +5 -- SHIPPED.
   v2 (same + floor removed): -0.075 (p 0.60), sign 61/65, wins 24->19 -- much better than u2 (-0.221) but still
   leans negative; Hanging Chad bought 27 -> 18 (retrigger future value, next item).
**Committed, sim arms queued (not deployed):**
3. `b4056af` generators by what they make (items/round x rounds x 0.5 x mean random card); Sixth Sense play
   (discard a spare lone 8 first when the clear is in hand); Riff-Raff (2 x output_fit x E[Common]); Perkeo
   (PERKEO_HOLD 0.3 is an ESTIMATE). Arms g1 (floor) / g2 (no floor).
4. `d16d9d3` retriggers valued on the deck projected to the run midpoint (measured live growth: enhanced 0 ->
   14.4 by ante 8, mix Gold .385 Lucky .262 ...). Hanging Chad a1 0.32 -> 1.04; Mime stays 0. Arms r1 / r2.
**2026-09-25 day results (all paired n=160; install = `0ed0a6d`):**
- g1 generators vs v1: +0.137, wins 26->33 -- SHIPPED. y1 retrigger projection (deck + per-card jokers a board typically
  gains, owner idea) vs g1: -0.044, 124 tied, Hanging Chad 29->37 -- SHIPPED (neutral). r1 found a Seltzer bug
  (limited-life jokers now excluded from projections).
- x1 xmult-only forward scaling: -0.188, sign 31/52 -- REJECTED (off, BES_XMULT_FWD=1). Acrobat 11->18, Blueprint 14->8.
- z1 FORWARD VALUE FOR EVERY JOKER (projected deck + hand levels at the run midpoint, growth anchored to a plain
  +4 Mult Joker so the joker-vs-money scale holds): vs y1 +0.108 (sign 77/59, reach-7 +11); OUT-OF-SAMPLE
  (BES_SEED_OFF=7) +0.098 (wins 26->32, reach-7 +7) -- SHIPPED ON (BES_FWD_ALL=0 disables). Then sped up (12 samples,
  top-6 per-card mix, per-decision caches: heavy shops 10.6 s -> 5.6 s); the fast version f1 vs y1: +0.009, wins 32 -> 36,
  reach-8 40 -> 47 (vs the slow z1: -0.100 n.s., wins +4) -- KEPT, live.
- w1 Astronomer/Gift (measured $), Oops (measured), Chicot/Luchador (full-engine boss-cost table, tools/boss_cost.lua):
  vs y1 141 tied, -0.042 -- SHIPPED. Oops 9->0, Luchador 3->0 buys (no longer bought with nothing to double/disable).
- FLOOR REMOVAL re-tested at every step (g2, r2, y2, z2): never neutral; z2 vs z1 -0.256 (p 0.049). Keep the floor.
  Still on the tier prior: Mr Bones, Diet Cola, Credit Card (one-shots, hard to price honestly).
- Boss-cost table: Wall/Mouth/Water/Plant/Needle/Flint cost most; Wheel/Fish/House/Mark read 0 (engine sees face-down).

Compare g1/r1 vs `sim_out/v1.jsonl` and g2/r2 vs `sim_out/v2.jsonl` (all in the main tree's sim_out once copied).
⚠ Ops: Claude Code reaps background shells on low memory; orphan luajit workers keep running and their shard
files survive -- merge by hand, verify unique seeds BEFORE deleting anything (a merge-then-rm lost v1 once).

## ⭐⭐⭐ 2026-09-24 — R12: INERT JOKERS, MEASURED CORE PROTECTION, BURNT JOKER (read FIRST, then R11 below)

Live seed **Y1U5TZWJ** (owner): bought Mime at ante 1 with nothing to retrigger, kept it all run, skipped Lucky
Cat / Half Joker for it, rerolled $91 -> $29 at antes 5-6 buying nothing, never used Burnt Joker, died a6.
Replayed from `bes_fixtures.jsonl` (scratch scripts `y1_*.lua`). Root causes:
- **Tier floor on an inert joker.** Mime measured 0.00 (no held-effect card) but was floored at 0.9 x tier 6 x
  0.3 = 1.62 boss hands -- the board's highest. Every owned joker sat on its floor, so measured offers never won.
- **Category "core" protection.** keep_bias / the pack-swap EXCLUSION protected Mime as a retrigger regardless of
  whether it did anything; in packs even flat scorers were unswappable (only Splash was eligible).
- **Burnt Joker** was never used by the play engine (the sim already modelled it).
- The a6 death itself was NOT a play bug: out of discards, playing 4s to keep bonus Aces had 21% clear vs 1%.

**Shipped + deployed (`685ed72`, `835f18e`; sim r12c vs risk_after n=160: +0.056, sign 74/68, wins 28->24
McNemar 19/23 p 0.64, reach-8 33->32 -- neutral):**
1. `Eval.is_inert`: no tier floor ONLY when a modelled joker's refined (24-sample) measurement is exactly 0.
2. `BP.keep_bias(key, gs, fires)` + `Eval.joker_fires`: category protection only for a joker that fires on this
   deck; `BP.is_keeper` keeps the old predicate for Ectoplasm's contingent slot. Funder tier floor skips inert.
3. Pack full-board swap: ranks EVERY pack joker against the shop's upgrade bar (keep c(1+0.5c) + max(1.2, kb)),
   survival-checked (`SA.sell_survival`); the swap's joker becomes the pick. Fixtures now carry pack jokers.
4. Burnt Joker: with the clear in hand, the round's FIRST discard (live `current_round.discards_used`, sim flag)
   levels the most valuable hand, priced like a planet -- from SPARE cards only, never the winning hand (owner
   rule). Skipped with Delayed Gratification / Green Joker / Ramen.
5. Shop scoring_gain takes the analytic conditional-xmult estimate; refine measure cached (shop 4.8s -> 3.0s).

**Refuted (sim):** floor removal for EVERY modelled joker (r12: wins 28->15, sign 64/84) -- the floor sets the
scale vs tier-PRIOR jokers (bought Drunkard 23x, Hanging Chad 27->17, sold Shoot the Moon 12x). Full-board reroll
swap bar (r12b: -0.071, wins 21) -- rerolls also surface packs/consumables e_best never prices; now opt-in
`BES_SWAP_BAR=1`. Arms: `sim_out/{r12,r12b,r12c}.jsonl`.

**R12b (`8ee9991`, deployed): utility jokers MEASURED.** Burnt/Space as leveling (event-fed-scaler ramp x the
per-hand worth of a level, as CV.best_planet ranks planets; `Eval.BURNT_AIM` 0.5 is an UNMEASURED estimate);
Juggler/Troubadour/Turtle Bean/Burglar(+3 hands) by `Sim.blind_output_frac` (expected fraction of the NEXT
ante's boss, policy chasing it, common random numbers). Downside skips the double-counted resource terms.
Sim u vs r12c: -0.008 (p 0.92), 99/160 tied, wins 24=24, reach-8 32->35 -- neutral, shipped.
Discards NOT measurable yet (greedy rollout wastes them; dig policy 7-10 s/state and noisy) -> Drunkard / Merry
Andy keep the prior. u2 (+ floor removed, `BES_NO_TIER_FLOOR=1`): -0.221, wins 24->18, Drunkard bought 20x,
Hanging Chad 27->18 -- the floor must stay until DISCARD value is measurable (the next lever) and the generators
(8 Ball, Cartomancer, Seance, ...) are modelled.

**Open:** unmodelled jokers (Drunkard, Burnt, Credit Card) are priced by full tier prior -- the real reason a
floor is needed at all; modelling them (Burnt = a planet/round) would let the floor go. Watch live: Mime-like
buys, pack swaps, Burnt discards.

## ⭐⭐⭐ 2026-09-22/24 — R11: SELL/BUY VALUATION OVERHAUL + LIVE FIXES (read this block FIRST)

Driven by the owner's live F11 runs (seeds DGTW4TTP, NGMNBGP9). Everything below is committed, pushed, and
DEPLOYED to the install. **Owner rule adopted this session (memory `corpus-is-not-ground-truth`): the 7-win
agreement corpus is the owner's own playstyle — a secondary signal / bug-finder, NOT a veto. Sim OUTCOMES
(wins, reach-8) decide; report stats honestly and replicate out-of-sample (`BES_SEED_OFF=7`).**

**Shipped (measured; paired n=160 unless noted; baselines chain hc→mo→sv→vo→pace_base→risk_after):**
1. **Self-player executes the card reorder** (`ea897de`, confirmed live). Mod does NOT hot-reload — restart the game.
2. **Held-card context bug** (`7874b55`): HandEval read held cards from `gs.hand` (EMPTY in the shop) → Blackboard's
   x3 fired on every sampled hand, Raised Fist/Shoot the Moon/Baron/Steel measured 0. Fixed at `HandEval.hand_ctx`.
   Sim +0.200 (p 0.02), wins 10→15. Root cause of the Smiley→Blackboard sale.
3. **Card Sharp never fired in the survival rollout** (`58f0c06`).
4. **Money-only jokers had phantom scoring value** (`721fcc1`): econ jokers got tier-prior score + their money;
   Chaos valued by tier only. Now score 0, money via `Eval.joker_money` (Chaos = $5 × measured free-reroll rate).
   Sim +0.343, SIGN 79/41 (p 0.0007) — strongest result.
5. **Survival-first selling** (`ca6e873`): `Eval.clear_prob` (logistic P(clear) vs per-hand score ratio, FITTED to
   the full engine on 307 calibration boards) + `SA.sell_survival`; a sale dropping P(clear) > 5 points is pushed
   behind safe ones; swaps judged on the board AFTER. Sim +0.163, SIGN 47/23 (p 0.006).
6. **Vouchers: no set values** (`9733089`): each valued by its effect (game rules + measured engine rates) or 0 if
   unusable/unmodelled (Magic Trick, Observatory, Director's Cut, Hieroglyph, Overstock, ...). Blank = P(Antimatter
   offered) × P(affordable above the interest reserve) × Antimatter. Sim neutral, agreement better.
7. **Calibrated pace risk** (`c2cdf2e`, owner decision): the "On pace (projects past ante 8)" verdict was badly
   over-confident (ante 4: 48% still died within 2 antes; the "comfortably ahead" band was the WORST, 72%).
   `Pacing.risk` = fitted P(die within 2 antes); the shop saves only when risk < 25%, buys power when ≥ 50%.
   Sim wins 20→28; fresh seeds 23→27; pooled 314 pairs 36 vs 24 wins-only (p~0.16) — consistent modest lean.
8. **Live interest-cap unit bug, fixed globally** (`927f45d`): live G.GAME.interest_cap is in DOLLARS; now
   converted at `state_extraction` so live == sim. Injecting the bug INTO the sim (`BES_LIVE_CAP_BUG=1`) cost
   wins 28→19 (p~0.14). The corpus had vetoed this twice; the sim overruled it.
9. **Live-only bugs:** shop-load crash (`1d339e9`, left the shop before its load event ran → game.lua:3294);
   wrong-card Standard-pack pick (`a123f2c`, all plain cards share key `c_base`); Orbital tag valued as your BEST
   hand instead of the hand on the tag (`a123f2c`).

**Refuted / not shipped:** uniform dig bias +0.05 (sim SIGN 38/61 worse, p 0.03 — stays off). Greedy survival
rollout is badly pessimistic and a smart-dig rollout fixes accuracy but NOT ranking (calibration tool below).

**New tools:** `tools/rollout_calibration.{lua,sh}` (rank cheap measures vs the full engine; `run`/`rescore`/
`remeasure`/`report`); `agreement.py` `AGREE_DUMP_PACK` / `AGREE_DUMP_SHOP`; sim shop records log `pace_margin/
pace_growth/pace_capacity/pace_on`; `BES_LIVE_CAP_BUG` switch; `BES_VALUE_DEBUG` reroll decomposition.

**⚠ Ops:** running the agreement corpus + an 11-worker sim TOGETHER reaps on low memory (worse while the owner
plays). Run arms SEQUENTIALLY at ≤9 workers. Unit tests: `lua tests/runner.lua` (1244 pass); LuaJIT aborts
`test_shop` (`table.unpack`) — use plain `lua`.

**OPEN / next:**
- Watch the owner's next F11 run on the full set: it should spend surplus on packs/rerolls (not hoard), keep
  scorers (sell econ jokers first), take exact Standard-pack cards, no Orbital skips for unplayed hands.
- The Blackboard BUY is still priced by the tier FLOOR (`max(measured, 0.6·tier·0.3)`) — the floor's rationale was
  largely the held-card bug; replace with more samples for condition-dependent jokers (owner prefers measuring).
- Dig-aware per-hand measure ranks sells slightly better (5/0 on large gaps) at ~15× cost — optional.
- Chariot/Steel-deck long-run value (winners pick it; engine values one card's immediate effect).

## ⭐⭐ 2026-09-20 — R9 LIVE-REVIEW FIXES + the REPLAY-AUDIT plan (read the `r9-live-review-2026-09-20` memory)

Owner played a full live run (F11), it DIED to The Mouth, and owner flagged several decisions. All traced via
the R8 replay loop (capture → `RF.rehydrate` → re-run the engine) and fixed as CORRECTNESS (not winrate
tuning). Branch `winrate-v4-bundle`; all shipped to the install (`%APPDATA%/Balatro/Mods/balatroenginesim`,
backup `bes_install_backup_20260920` OUTSIDE Mods/) and pushed.

**Shipped this session (each tested + deployed):**
1. **Mouth death (run-killer)** — off-type plays score 0 under `single_hand_type`, so the engine now DIGS for
   the locked type instead of burning hands on 0-scorers; the tarot follow-up can't corrupt the lock. Locked
   by a regression test (`tests/test_decision.lua`). ⚠ The sim referee auto-corrects illegal plays, so this
   class is INVISIBLE to the sim suite — it needs live capture + replay.
2. **Build-aware card targeting (`engine/tarot.lua` `T.card_relevance_fn`)** — Empress/Hierophant/Strength/
   Death + spectral seals/editions target what the build REWARDS, read by PROBING each owned joker's scoring
   hooks (complete + self-maintaining: catches Wee/Hack/Fibonacci/Baron/faces/odd, not just suits). Tag-based
   was rejected as incomplete.
3. **Banner/Mystic valuation** — scored at the discards you'll HOLD at play (`SA.expected_discards_left`), not
   the fresh-blind max (Banner was 4× over-valued).
4. **Sim held-gold $3 fidelity** (`sim/world.lua`) + **Celestial finishing-window poverty exemption**
   (`shop_advisor`, agreement-neutral).
5. **SKIP decisions are now CAPTURED** (`main.lua`/`replay_fixture`/`replay_fixtures`) — previously the one
   decision class never logged. NOT a behaviour change (skip-RATE = the REFUTED `noskip` lever, −0.166).

**⭐ THE RECOMMENDED NEXT STEP — a REPLAY-BASED PROVABLE-ERROR audit (not an agreement bake-off).** Owner's
valid critique: "differs from my play" bottlenecks on the owner's judgment (the corpus IS their play). So the
audit's PRIMARY signal is PROVABLE errors — wrong on their own terms, judgment-free: a played hand that scores
0, an illegal play, a joker valued at an impossible state, an enhancement on a non-scoring card, a generator
with no output room. Method: replay every captured fixture (`data/agreement_corpus/` OR the live save-folder
`bes_fixtures.jsonl`) under the current engine and FLAG these. Agreement-divergence from the 7 winning human
runs is a SECONDARY lead-generator only. Verified provable-correctness fixes ship + get a regression test;
judgment/refuted items are LEFT (that's not the loop, it's discipline).

**Verification is decoupled from the owner:** they PLAY (any runs, any seed), the mod captures every decision,
the assistant REPLAYS. Owner does not need to know the optimum or replay a specific seed. The winrate CEILING
(~8% autonomous) is compute-bound and per-decision fixes won't move it — this work is ADVICE CORRECTNESS,
which is tractable and the live overlay's actual job. `run tests/runner.lua` (1210 pass) + `runner_sim.lua`
(604 pass, 1 pre-existing `test_world` failure) before committing.

## ⭐⭐ 2026-09-19 — WINRATE_V4 investigation + the IN-BLIND PLAY / MONEY-FARMING finding (read `WINRATE_V4_PLAN.md`)

**Fresh baselines (current HEAD, `branch winrate-v4-bundle`):** autonomous **8.1%** baseline / **28.7%** rich10
(the old docs' 2.5% is STALE — recent scaler/spectral/R7 work tripled it). `run_str` caps ~0.62 at ante 8 in
BOTH → money buys levels, not board power.

**What this session established (all in `WINRATE_V4_PLAN.md`):**
1. **Build/economy/supply levers are exhausted** — WS-3 product-value (reverted, killed winners), the whole
   economy family already tried (reroll-to-dig, banking, ecap3, pack-poverty), loss diagnosis = SUPPLY×SURVIVAL
   (engine takes offered multipliers fine; it just dies early → low exposure), and the learned-value path is a
   NO-GO on attainable data (`tools/data_scaling_probe.py`: plateaus below the free `capacity` baseline).
2. **In-blind SCORING-play is near-optimal** — `HandEval` faithful (7/7 canonical), chooser 94% max, ante-1 dig
   at a clairvoyant ceiling (78% vs 75%), and target-aware dig rewrites measured NEUTRAL (reverted). First
   blind clears 99.5%. The live self-player uses the full engine (`BES_SAMPLES=80`), not a degraded path.
3. **⭐ THE OPEN FRONTIER (owner, 2026-09-19): JOINT MONEY-FARMING + SCORING in-blind.** Pure "clear the blind"
   is solved, but milking ECONOMY *while* clearing (Gold cards/seals, Lucky, editions, econ jokers held/played
   to MAX $ subject to still clearing; $1/unused-hand compounds into the next shop) is NOT measured or
   optimized. Deterministic, non-compute-bound. Probe `engine/discard_fuel.lua`, `hold_fuel.lua`,
   `HandEval.play_econ`, and the MILK/DIG paths in `decision_engine`. Owner: assume autoplay actuation is fine.
4. **Target: near-100% is legitimate** (expert humans hit >98% gold-stake hardest decks); even 0.5% ante-1
   failures are a real defect. New diagnostics kept: `tools/first_blind_fast.lua`, `first_blind_optimal.lua`,
   `play_regret.lua`, `loss_diagnosis.py`, `data_scaling_probe.py`.

---

# NEXT_SESSION.md — earlier handoff (2026-09-04)

## ⭐ TASK 3 SWEEP — bring EVERY scaler onto the measured system (owner directive, 2026-09-04)

> **Owner reframed the goal: ALL jokers should follow the measured system, not revert to tier constants.**
> The scaler-coverage audit answers "how many still do": of **151 catalogued jokers, 120 non-scalers are
> already MEASURED** (deck-aware `score_delta`, or `econ_value` for money jokers — tier is only a low floor);
> **12 scalers were on the measured system; 19 still fell through** to `tier-prior × generic-projection`. A
> fresh scaler contributes ~0 (a fresh xmult is ×1), so `score_delta` reads 0 and the value collapses to the
> tier constant — the same class of error that had Ride the Bus at 3.78 vs measured 0.04.

**✅ BATCH 1 SHIPPED (`88ed981` + fix `1b2e6a1`) — the consumable-fed class + a class-A freebie (19 → 16):**
- **Constellation (+0.1x/Planet) & Fortune Teller (+1 mult/Tarot)** — the R5 "skipped a Constellation while
  rich" item. Valued by the event-fed model (below), **RESOURCE-AWARE**: planet/tarot uses per scoring-hand
  scale with generation capacity (Astronomer 0.30, tarot-makers 0.14), leveling / Satellite (0.15), money
  (0.06), else base 0.03. Constellation went from a context-blind flat **4.32-of-a-boss-hand EVERYWHERE** →
  ~nil in a non-planet build (the over-buy TRAP fixed) rising to **1.86** in a leveled Astronomer build (tracks
  how leveled you are).
- **Spare Trousers (class A)** — just needed `inc=2, scale_rate=0.50`; trigger hands were already gated.

**⭐ THE CORPUS CAUGHT A REGRESSION — the reusable lesson.** The agreement corpus (161 Constellation states)
was NEUTRAL overall (±0.2pp), but its **picks-diff** showed dropping the tier floor made an owned scaling core
measure LOW on a still-weak board → the engine wanted to **SELL its own committed Constellation** (seed
Z9PBGTL2, jp 0.113, below Egg). **Fix: gate the measured value to the BUY side only (`owned=false`).** The
owned/sell path keeps the measured+tier-floor route — sell-side core protection (`BP.CORE_KEEP` / the tier
floor as a FLOOR) is a SEPARATE, endorsed concern from not-over-BUYING. owned jp 0.113 → 7.200; buy-side
unchanged. **"Drop the tier floor" is a BUY-side directive; check the SELL ranking + corpus picks-diff, not
just the headline metrics, when you change a scaler.** The remaining −2 buy_agree was diagnosed to 3 winning
planet-build states where the decline is DEFENSIBLE (full-board swap / short runway / early speculation), not
undervaluation — the old flat 4.32 "agreed" by over-valuing everything.

**✅ BATCH 2 SHIPPED (`1993ca7`) — the remaining 14 scalers; 31/31 now measured, 0 fall-throughs.** The
consumable-fed model was generalized into a unified **EVENT-FED** model (`Eval.event_fed_forward`): `value =
feed_inc × projected_events / 2 × deck-aware-spu`, no tier floor, BUY-side only. Catalogue `feed_fuel/feed_inc`
drives it; the counter unit (chips/mult/x_mult) is derived from `cat`. Fuels by class:
- **C. Discard-fed:** Castle (+3ch/suit-discard), Hit-the-Road (+0.5x/Jack, resets/round), Yorick (+1x/23 discards)
- **scored-rank:** Wee (+8ch/scored 2)
- **D. Deck-content (bounded by deck count, deck-aware):** Vampire (+0.1x/enh eaten), Glass (+0.75x/shatter —
  **0 with no Glass cards, 0.50 with eight**), Lucky Cat (+0.25x/trigger)
- **E. Deck-size:** Hologram (+0.25x/card added)
- **F. Action-fed:** Campfire (+0.25x/sell, resets/ante), Throwback (+0.25x/skip), Flash (+2mult/reroll —
  **money-gated: 0.19 poor → 0.47 rich**), Red Card (+3mult/pack-skip)
- **G. Reset/rare/destroying:** Obelisk (+0.2x off-type, resets), Madness (+0.5x/select, DESTROYS a joker →
  `feed_damp 0.3`), Canio (+1x/face destroyed), Ceremonial (one-shot +2×right-sell, `feed_once` + damp)

`event_rate` holds the per-fuel rates (OWNER-CALIBRATABLE like `scale_rate`); resetting fuels use the PERIOD as
the horizon; deck-content fuels are bounded by deck count. **`SCALER FALL-THROUGHS: 0`** (audit:
`tools/scratchpad audit_scalers`). 1182 tests.
**Corpus (batch-1 → all-scalers): NET POSITIVE — `agree_save` +0.8pp (316→324)**, everything else neutral
(±0.1pp), guards unchanged. Dropping the inflated tier values made the engine **over-buy and over-churn
scalers LESS**: the changed decisions are the engine no longer selling working jokers to fund inflated scalers
(Smiley Face, 8 Ball, Gros Michel, Raised Fist — all "SELL → SAVE" now) and no longer speculatively buying
inflated Castle/Campfire/Hologram. **No early-core dumps** (the buy-side-only gate held); the only oddities are
ante-8 already-won states where measurement noise reshuffles equivalent win-lines.

**➡ THE SCALER SWEEP IS COMPLETE. Where the frontier goes next** (all optional, none is a fall-through fix):
- **Owner-calibrate the `event_rate` rates + `feed_damp`s** if any live-run value looks off — these are the
  Runner/Square-style domain constants, set to reasonable defaults, not yet owner-tuned.
- **The remaining tier-prior dependence is NOT scalers:** the 3 joker-making generators (Riff-Raff/Vagabond/
  Cartomancer, valued tier × `output_fit`) and a few utility jokers. Different modeling axis (output/utility),
  not the scaler system.
- **Deck-content BUY-timing:** Glass/Vampire/Lucky read 0 until the cards are in the deck — correct per-state,
  but a human buys them as a COMMITMENT to add those cards (the same foresight gap as early Constellation). A
  future "planned deck-content" signal could credit that; deferred (it's the build-commitment wall again).

## ⭐⭐ R6–R8 LIVE-RUN REVIEW (2026-09-04) — 3 fixes shipped, and the FIRST death traced end to end

> **Read `ADVICE_REVIEW.md` R6/R7/R8 for the full detail.** The headline is methodological: R8 is the first
> time this project has traced a live death from **board state → valuation → the specific line of code**,
> by finding the run in `bes_runs.jsonl` and **replaying the exact shop state from `bes_fixtures.jsonl`**.
> That loop — owner reports a misplay, find the seed, replay the fixture, watch the engine reproduce it —
> is now the sharpest diagnostic this project has, and it is repeatable. **Use it before theorising.**

**✅ SHIPPED THIS SESSION:**
- **Ectoplasm priced properly** (`175b5c4`) — it fell through to a flat `SPECTRAL_BASE` prior of **0.7** (3rd
  highest spectral) with its permanent −1 hand size charged at **zero**, while the structurally identical
  Ouija branch directly above it did charge one. Now: no-eligible-joker guard; the +1 slot priced by the
  existing board/runway-aware `Eval.negative_slot_fv`; and the credit scaled by how much of the board
  `BP.keep_bias` calls a keeper — because the slot rides on a RANDOM joker and leaves when you sell it, while
  the hand size never comes back. Ante 3, stock deck: **0 jokers −0.130 · 3 junk commons −0.466 · 2 commons +
  1 core +0.634 · 3 cores +2.808 · 3 cores at ante 8 +0.498 · 5 cores full board ante 2 +5.366** (all were a
  flat 0.700). New `CV.hand_size_cost` MEASURES the −1 hand size off the real deck by paired sampling, and
  **Ouija now uses it too**, so both cards inflicting that downside are charged the same way.
- **A generator with nowhere to put its output is not "live"** (`b21aa57`) — the two defects behind the R8
  death, below.

**⭐ R8, THE DEATH (seed 6EDJFT2Y, ante 4).** Board full → bought **Riff-Raff into the last joker slot** (it
spawned **zero** jokers for the rest of the run) → later needed a slot for a To Do List and **sold Greedy
Joker, the board's only unconditional Mult** → died at the ante-4 boss on **21.5% of the requirement holding
$52** (the same $52 as the canonical X3L32ZEA loss). Three of the five jokers on the death board score
nothing. Replaying the recorded state reproduced the misplay exactly, and **two composing defects are now
fixed**:
- 🔧 **`funder_is_live` protected a generator that could not generate.** The `card_generation` clause (added
  2026-09-01 for **Vagabond**) shields a joker whose "value is in its OUTPUT" — but with no room there IS no
  output. The fix is deliberately **asymmetric**: consumable-makers keep their UNCONDITIONAL protection (a
  consumable slot frees up as you use it, so a full tray is transient and gating it would re-open the very
  churn the 09-01 fix closed — that path is byte-identical), while the joker-maker is gated on a free joker
  slot. Riff-Raff is the only `card_generation` joker without the `"consumable"` tag, so **exactly one key**
  changes behaviour, in exactly the state where it provably produces nothing.
- 🔧 **The tier prior assumed the output lands.** Fix 2 alone does NOT change the outcome — Riff-Raff's
  marginal was **3.000** (a pure tier prior, 6 × 0.5) against Greedy's **1.800**, so unprotecting it still
  left the Mult as the cheapest sale. Both prior paths — sell-side `Eval.jp_from_measure` and the
  **independent** buy-side prior in `shop_advisor.scoring_gain` — are now scaled by `Generators.output_fit`.
  **No new constant:** it reuses `pack_open_advisor`'s existing `gen_fit` convention and its `room_credit`
  reading (Judgement is 0.1 there because "a RANDOM joker rarely beats what you sacrifice"; Riff-Raff makes
  2 random **Commons**, strictly weaker, so it takes the same 0.1).
  Result: marginal **3.000 → 0.300**, advice **SELL Greedy → SELL Riff-Raff**; buy value was **7.5233 on
  every board size**, now 7.02 / 7.02 / 2.43 / **−2.16** as the slots after purchase go 3 / 2 / 1 / 0.

**⏳ OPEN, ranked:**
1. **✅ DONE (`f46b5cc`, 2026-09-05) — THE PLAY CHOOSER IS NOW CARD-ORDER-AWARE.** `best_play` compared
   subsets in dealt order and could take a play that fails to clear while a REORDERED subset clears (owner's
   Greedy + Hanging Chad hand — Two Pair 340 dealt / 924 lead-Diamond-Ace, verified). `HandEval.best_play_target`
   now, when `HandEval.card_order_sensitive` (Hanging Chad / Photograph / Glass or poly cards), collects the
   top-K subsets by dealt score and re-judges each at its best CARD order (bounded cards-only permute), then
   returns the sel already in best order (so the sim, which scores sel in order, plays optimally). The human
   REORDER tip is preserved: `decision_engine` feeds `Ordering.optimize` the HAND-order sequence so it still
   recovers hand→best. Order-INSENSITIVE boards are byte-identical (0.98 ms/call; sensitive ~6.4 ms, gated).
   `best_play` (the 80× discard-sampling path) is left dealt-order for perf. **Corpus (cf_spec2→cf_play):
   BLIND class-agree +1.0pp (431→439)** — the engine's in-blind play choices now match the winning human MORE
   often; everything else neutral, guards intact. The changed plays are higher-value ordered picks.
2. **✅ DONE (`0538fa1`) — Business Card feeds the in-blind money model.** `j_business` (VALUE_ONLY) never
   reached `ev.money`, so the tier-2 "both clear → maximise MONEY" play tie-break read $0 for a farming board.
   `score_with` now adds $1 expected per played FACE card per Business Card (per trigger — a Hanging Chad
   retrigger re-rolls it; Oops! → $2; Pareidolia counts all cards). Feeds `ev.money` → `play_econ` → the
   tie-break and `econ_power`. **Corpus (cf_play→cf_all, with Vagabond): NEUTRAL** — BLIND −0.3pp (2 tier-2
   plays where the money tie-break now prefers the higher-$ clearing play), all SHOP/PACK metrics 0.0.
3. **✅ DONE (`ea897de`, 2026-09-22) — the self-player now EXECUTES the card reorder** (PHASE 0b in `ui/autoplay.lua`: permutes the played cards within their own hand slots to `best.reorder.card_order`, re-aligns; the game scores in T.x order, and align_cards sets T.x from the array index, so it sticks. Headless-tested vs a mock G with the real align/play-sort rules (`tests/test_autoplay.lua`); deployed. ✅ CONFIRMED LIVE by the owner on seed DGTW4TTP after a game restart — the first attempt looked broken only because the game had been running since before the deploy; the mod does NOT hot-reload.) Original note: ~~The self-player never reorders CARDS~~ — `ui/autoplay.lua` has a joker-reorder phase; `card_order`
   appears **zero times**. Now that the chooser (item 1) returns the best card order and the overlay tip
   recovers hand→best, the live autoplayer must EXECUTE that card reorder to realize the fix (the sim already
   does, since it scores the sel in order). ⚠ Live-only (`ui/autoplay.lua` needs `G`/love) — cannot be
   validated headlessly; needs an in-game run.
4a. **✅ 2026-09-23 — the Smiley→Blackboard sale (DGTW4TTP) was a HELD-CARD CONTEXT BUG, fixed `7874b55` + deployed.** HandEval read held cards from gs.hand (EMPTY in the shop), so Blackboard's ×3 fired on every sampled hand and Raised Fist/Shoot the Moon/Baron/Chariot-Steel measured 0. Also fixed: Card Sharp never fired in the rollout (`58f0c06`). New tool `tools/rollout_calibration.{lua,sh}` ranks cheap measures vs the full engine (307 boards): the shop's per-hand mean ranks sells best (88–95%); the fast rollout is pessimistic; a dig-aware per-hand measure adds +2–5pp at ~15× cost. OPEN: Blackboard's BUY is still priced by the tier floor (1.08 vs measured 0.42) — revisit the floor as a measured change. **Sim A/B of the held fix (paired n=160, baseline, 58f0c06→7874b55): progress +0.200 (t 2.28, p 0.022), wins 10→15, death-ante 35 later/23 earlier, reach-8 16→19; sign test 44/38 n.s. ⇒ suggestive positive, no harm.** Arms: sim_out/hc_ab_{before,after}.jsonl.
4b. **✅ 2026-09-23 — MONEY-ONLY jokers no longer get phantom scoring value (`721fcc1`, deployed).** Econ jokers (VALUE_ONLY + catalogue econ>0) were valued twice: tier-prior score + their money; Chaos only by its hand-set tier. Now score 0, worth = `Eval.joker_money` (econ + Chaos reroll saving = $5 × measured free-reroll use rate by ante). **Paired sim n=160 vs hc_ab_after: progress +0.343 (t 2.62, p 0.009), SIGN 79/41 (p 0.0007), reach-7 27→43, reach-8 19→27, wins 15→17; agreement agree_save +23.** Not yet OOS-replicated (BES_SEED_OFF). ⚠ It does NOT flip the DGTW4TTP sale on its own: Smiley (2.28) is still below a $4/round joker (3.20) — the sell side's money↔score exchange is LINEAR and blind to the survival cliff (removing Smiley: ~1165 → ~430/hand vs need ~1000). That is item 4 below, now precisely located.
4c. **✅ 2026-09-23 — SURVIVAL-FIRST SELLING (`ca6e873`, deployed).** `Eval.clear_prob` (logistic P(clear) vs per-hand score ratio, FITTED to the full engine on 307 calibration boards) + `SA.sell_survival` (board ratio + each joker's leave-one-out loss, 16 paired hands, once per shop): a sale dropping P(clear) > SURVIVAL_EPS 0.05 is penalised ∝ the drop (SELL_JOKER pick, pure-sale value, SELL_TO_BUY funders); swaps judged on the board AFTER. DGTW4TTP: Smiley −0.14 / Chad −0.13 unsafe, econ 0 → nomination now Delayed Gratification. **Paired sim n=160 vs mo_ab_after: +0.163 (t 2.67, p 0.008), SIGN 47/23 (p 0.006), death-ante 24 later/13 earlier, reach-7 43→49; wins 17→14 (6 vs 3 discordant, p 0.51 n.s.); agreement neutral.** This closes item 4 below in practice (board-as-set collapse via a measured survival gate, not a guard).
4d. **2026-09-23 live run NGMNBGP9 (died ante-6 boss holding $63):** FIXED + deployed `1d339e9` shop-load crash (leave clicked before the shop's load event ran); `a123f2c` wrong-card Standard-pack pick (all plain cards key `c_base`, no id passed) + Orbital tag valued as your BEST hand (it levels the hand in G.GAME.orbital_choices). Replaying the run's 50 shops: survival-first selling changed ONE decision (blocked selling Misprint for Rocket at a6, behind pace) — it did NOT freeze the board. ⭐ OPEN, the real cause of the idle board: the engine held $51–88 from ante 4 (interest capped at $5) and mostly SAVEd — ZERO rerolls in ante 4 at $51–64; a6 reroll valued +0.15 while 'at risk — need a better joker'. Money above the cap is idle. This is the conversion wall: investigate reroll/search valuation when rich (anti-hoard decay exists, R5).
4e. **✅ 2026-09-23 — VOUCHERS: no set values (`9733089`, deployed).** Every voucher valued by its effect (game rules + measured engine rates: 0.70 Celestial packs/ante, 0.23 rerolls/shop) or 0 when unusable/unmodelled (Magic Trick, Observatory, Director's Cut, Hieroglyph, Overstock, ...). Blank = P(Antimatter offered) × P(affordable above the interest reserve) × Antimatter. Sim n=160 vs sv_ab_after: +0.127 n.s. (sign 61/56), wins 14→20; agreement: eng_buy_human_save 267→231, agree_save +25. Global interest-cap fix RE-TESTED + REJECTED (winners save ~75% of shops even at $60+; see memory). Baseline for the next A/B: sim_out/vo_ab_after.jsonl, agreement vo_after.
4f. **2026-09-23 — PACE VERDICT IS OVER-CONFIDENT (measured); calibrated fix RE-APPLIED + DEPLOYED `c2cdf2e` by OWNER DECISION (see below).** With pace logged per shop (`85982eb`, sim_out/pace_base.jsonl): 'On pace (projects past ante 8)' at ante 4 → 48% die within 2 antes; the 'comfortably ahead' band (margin 1.5–1.8) is the WORST (72%). Only margin ≥3 (ante 4) gets risk <50%. Fitted P(die within 2 antes) = per-ante intercept {-2.776,-0.529,0.792,1.281,1.634,1.073} + −1.164·ln(margin). Wiring it into the shop (d975013, reverted): sim +0.083 n.s. (tail reach-8 24→33, wins 20→28, n.s.) but agreement worse (agree_save 391→332, reroll-where-human-saved +43). Likely: the curve is fitted to ENGINE outcomes and mis-reads a skilled player's board. OWNER (2026-09-23): keep it — the corpus is the owner's judgement/playstyle, not ground truth; sim tail (+8 wins, McNemar 17/9 p~0.17) wins. TODO: OOS-replicate (BES_SEED_OFF). Earlier idea: calibrate to what the winners' boards actually survived, or apply the risk only to the self-player — or OOS-replicate the tail gain (BES_SEED_OFF).
4g. **✅ 2026-09-23 — corpus-rejected changes RE-TESTED on sim outcomes (owner: the corpus is their playstyle, the sim decides).** (1) **Live interest-cap bug** — sim arm with the bug injected (`BES_LIVE_CAP_BUG=1`, `a7c51e2`) vs today's engine: wins 28→19 (19 vs 10 discordant, p~0.14), progress −0.208 (p~0.06), reach-8 33→28 ⇒ the bug costs wins. **FIXED LIVE at extraction (`927f45d`, deployed)**: `state_extraction` converts G.GAME.interest_cap $→interest units, so live == sim everywhere. (2) **Uniform dig bias +0.05** — sign test 38 better / 61 worse (p~0.03), wins 28→24 ⇒ stays OFF (sim + corpus agree). (3) **Fresh-seed (BES_SEED_OFF=7) replication of the calibrated pace risk** (q_oos_base 154 runs + q_oos_risk, paired 154): same direction, smaller — wins 23→27 (19 vs 15 discordant, p~0.61), reach-8 32→34, progress +0.034 n.s. Pooled with the original pool (314 pairs): wins-only 36 vs 24, p~0.15. ⇒ consistent modest positive lean, no harm; KEPT (winner's-curse shrink as expected).
4. **⚠ Nothing notices a sale leaves the board with no unconditional Mult** (R8 defect 3, STILL open — the
   hard one). Greedy is `flat_mult` → `SCORER_KEEP`; plain scorers are deliberately unprotected. **Assessed
   2026-09-05 and deliberately NOT quick-fixed:** the leave-one-out marginal `joker_marginal_fv` is ACCURATE
   (Greedy really was weak on a few-Diamonds deck); the gap is WORST-CASE-hand board collapse — the boss hand
   didn't trigger the board's conditional/retrigger mult, so scoring collapsed. This is genuinely §31f's
   board-as-a-SET problem (Mult is a FACTOR; its marginal ≠ the product's collapse) and needs set-scoring
   (score the board as copiers×xmult×triggers, detect the last mult FACTOR), not a magnitude tweak or a
   guard bolted onto the averaged marginal. Left for the research fork.

**✅ GENERATORS (`c491742`, 2026-09-05) — Vagabond value is now econ-aware.** It makes a Tarot only at <= $4,
but the flat tier prior valued it 3.75 at every dollar level; `Generators.fire_rate` damps it by expected
firing rate (3.75 at $2 → 0.38 at $25). Cartomancer (unconditional) and Riff-Raff (output-fit gated, R8) are
unchanged. The generators are no longer context-blind constants.
5. **✅ TIER 1 DONE (`0c6ae12`, 2026-09-04) — the spectral wiring.** **Black Hole** now uses the measured
   `Packs.black_hole_value` in BOTH the buy valuation (`card_value`) and the use decision (`DE.GEN_USE`) —
   one deck-aware price, not three (0.9 → 0.388 stock ante 3). **The four SEAL spectrals** are now
   distinguished via `CV.seal_spectral_value` (Gold/Blue/Purple by `card_econ_value`; Red as a bounded
   retrigger estimate `CV.RED_SEAL_FRAC`, because a greedy measurement seals a plain card and reads ~0) —
   flat 0.2 → Gold .063 / Red .016 / Blue .026 / Purple .100. **Sigil** via `CV.sigil_value` (measure the
   flush conversion toward the dominant suit, damp for the random suit) — flat 0.3 → 0.020 rising to 0.055 as
   the deck leans flush. **Corpus (pre-spectral → wired): NET POSITIVE — PACK agree_same +0.5pp (84→86),
   PACK diff −0.5pp, everything else neutral, guards unchanged.** The changed picks are the engine choosing
   spectrals by measured value instead of flat priors (Sigil→Grim/Talisman where Sigil measures low with no
   flush lean; Incantation→Deja Vu on a board where the red retrigger is worth more) + spectral pack EVs
   recomputed. No regressions. **✅ TIER 2 DONE (`009c368`, 2026-09-05) — ALL 18 spectrals now measured, 0 flat priors.**
   **Soul** (a random Legendary) via `Packs.expected_joker_of_rarity("Legendary")`, slot-aware (full board
   ×0.7) — 1.2 → 1.98 free / 1.39 full, now the top spectral above Black Hole; its `DE.GEN_USE` uses the same
   measured value. **Cryptid** (2 copies of a card) via `card_add_value ×2` FLOORED like DNA/Marble
   (`CV.CRYPTID_FLOOR` — deck-copy value is dilution-dominated in a snapshot; the floor is the compounding it
   can't measure) — 0.4 → 0.2. **Aura** (a random edition) via an analytic `AURA_FRAC × base/need` estimate
   (a greedy measurement editions a card the sampler rarely scores and reads ~0, same intent-blindness as the
   Red seal) — 0.35 → deck-aware 0.01–0.10. **Familiar/Grim/Incantation** (destroy 1, add N enhanced) via
   `N × card_add_value` — 0.25 flat → scales with N (Incantation 0.37 > Familiar 0.29 > Grim 0.19). The pack
   pool inherits all of it (spectral_pool calls card_value). **Corpus (Tier1→Tier2): NEUTRAL** — PACK agree
   ±0.3pp (1 state), all SHOP metrics 0.0, guards unchanged. Changed picks = choosing spectrals by measured
   value (Incantation, the strongest add-group, now often wins) + spectral pack EVs rising because Soul is
   valued; no aggregate buy/save shift. ⚠ Watch: Soul at ~1.98 lifts spectral-pack EVs noticeably — if a live
   run shows over-buying Spectral packs, damp `CV.soul_value` or the pool's best-of-N.
   **➡ THE SPECTRAL LAYER IS FULLY MEASURED (18/18). No spectral reverts to a constant.**

**🛑 A PROCESS LESSON THAT PAID FOR ITSELF TWICE THIS SESSION** — CLAUDE.md's *"verify by MEASURING, not by
reading the diff"*. On Ectoplasm, the first draft's comment asserted the hand-size cost was **convex** in hand
size; the probe refuted it (0.33 at hand size 8, **0.09** at 5 — a smaller hand makes weaker hands, so the
marginal card contributes less), which also means stacking Ectoplasms are under-charged (recorded in-code).
And the first `stick` formula credited each joker `keep_bias / CORE_KEEP`, paying a flat common **48%** and
leaving three junk commons at **+0.97 — ABOVE the 0.7 being replaced**: as first written, the fix would have
made the reported misplay MORE likely. **Both were caught only by running the numbers.**

⚠ **Test-suite note:** `tests/test_shop.lua` uses `table.unpack` (~line 1048), which is nil under **LuaJIT**
— the suite aborts there if run with `luajit`. It is fine under `lua tests/runner.lua`, which is how the
headless suite is meant to run. Pre-existing, unrelated to this session's changes, but it will bite anyone
running that one suite standalone under luajit.

---

## ⭐ R5 LIVE-RUN REVIEW (2026-09-03) — 3 fixes shipped, the rest triaged
Owner watched a run and reported ~10 issues. Outcomes:

**✅ SHIPPED:**
- **Purple seal discarded into full consumable slots** (`567c165`) — `discard_value.keep_value` now treats a
  purple seal as pitchable (+3, for its Tarot) ONLY when a consumable slot is free; with full slots it's kept
  like any sealed card (+15) so it isn't thrown for a Tarot that overflows. Corpus-neutral (no in-blind regression).
- **Money hoarding** (`567c165`) — `FREE_SPEND_DISCOUNT` now DECAYS as the idle above-cap pile grows
  (0.4→0.12 over $25 of surplus), so a large hoard converts to build while the near-cap interest buffer is
  protected. **Corpus-neutral; baseline sim neutral/slight-neg (change barely fires — the poor sim engine
  dies at ~$22); RICH10 POSITIVE on every metric (wins 13v11, reach-8 15v13, sign 15/9, progress +0.065, only
  16 tied vs 34).** The operating-point signature (B3/level_gain) — neutral at baseline, converts at the rich
  end the live overlay serves. ⚠ rich10-in-sample isn't a *proven* lever (B3-lesson), but mechanism-sound +
  owner-reported + no baseline harm = defensible ship.
- **Skip advisor missed the board's money jokers** (`6a7892b`) — added `Eval.econ_power` to the skip's
  play-value, so a farming board (Business Card/Bloodstone/…) correctly prefers to PLAY not skip (owner:
  skipped a Meteor pack forgoing Business-Card farming). Correctness (the play earns that money).

**🔎 DIAGNOSED, not a bug / deferred:**
- **Overlay "Jupiter/Earth" & "holo-8S/blue-seal" mismatches** — the live tick renders the CHEAP tier pass
  (`main.lua:116`, `cheap = not with_sim`) then the background job refines to the MEASURED pick. The owner
  read the transient cheap pick before it refined. Engine's actual pick is CORRECT — a display-latency
  artifact. Fix is UX (mark provisional / prefer the cached measured pick); not done.
- **Played 3 Kings incl. a DEBUFFED one, no dig with 3 discards** — the engine already scores a debuffed card
  as 0 (`is_debuffed`), so it KNEW; playing to clear efficiently vs digging is the known build-commitment/dig
  wall (a uniform dig bias was REFUTED by the corpus). Not a clean bug.

**⛔ DEFERRED (harder — need modeling/measurement):**
- **Skipped a Constellation (xmult_scaling) while rich** — an xmult scaler is under-valued at purchase
  (fresh xmult ~1) and the engine doesn't connect "I'm rich → I'll use many planets → it scales fast."
  Needs RESOURCE-AWARE scaler valuation.
- **Kept an unscaled Castle while chip-flush** — Castle (discard-fed chip scaler) isn't in the measured-scaler
  system, so it's tier×proj-valued (over-valued when unfed), and a chip-scaler's value should drop when MULT
  (not chips) is the bottleneck. Add discard-fed scalers to the measured system + a chips-vs-mult-bottleneck
  read.
- **Build incoherence (held a Diamonds +mult without building Diamonds)** — the known CONVERSION wall (commit
  to a suit + convert cards). The #1 unsolved winrate problem.
- **Reluctant to use tarots (slows scaling)** — proactive consumable-use pacing; related to the conversion wall.

## ✅ FOUR UTILITY-JOKER MODELS shipped (2026-09-02) — beyond-tier follow-ups from the tier review
Owner directed these off their flat tier priors, systematically:
- **Invisible Joker** — was a flat prior (not modeled as a copier). Now valued by the joker it will
  DUPLICATE: `Eval.invisible_copy_jp` blends the board mean with the best (0.4/0.6, you shed weak jokers to
  bias the random pick), × 0.75 for the 3-round delay. **~0 with no board worth copying; scales with your
  best joker.** Scaling-inheritance falls out for free — the copy is priced via `joker_jp` at the board
  joker's CURRENT (scaled) value. Wired into `joker_jp` (owned) + `modeled_scoring_fraction` (shop). The
  shop correctly won't buy it on an empty board and buys it beside a strong joker.
- **Burglar** — discard anti-synergy in `joker_downside`. Burglar removes ALL discards, so DISCARD-FED
  jokers (`DISCARD_FED`: Faceless/Mail/Hit-the-Road/Trading/Yorick/Burnt/Castle) and purple-seal cards go
  dead beside it — penalized two-directionally (Burglar costs more with them owned; they cost more with
  Burglar owned). **Green Joker deliberately EXCLUDED** (no discards only helps it).
- **Diet Cola** — usage gate in `joker_downside`: its Double Tag only pays on a future SKIP, and skips are
  front-loaded, so it decays with ante (~0 penalty antes 1–2 → ~its whole prior by ante 8). The
  "don't sell a strong joker to fit it" concern is already handled by the anti-churn SELL_TO_BUY guard.
- **Showman** — ⚠ was NOT missing: it's catalogued under its real game key **`j_ring_master`** (the silent-
  key gotcha — `j_showman` would never match a live joker; a duplicate I added was caught by the coverage
  guard and removed). Retuned to the owner's tier **2** and given a build-dependent model (`Eval.showman_jp`
  = base + 0.25 × best board joker) — worth more when you have a strong joker worth duplicating.

1141 tests pass; all deployed. ⭐ LESSON reinforced: a new catalogue key MUST match the live center key —
the coverage guard (`no silent-zero jokers`) catches mismatches. **NEXT idea:** DNA-style copy models could
extend to any "duplicate" joker; and Green Joker + Burglar is a positive SYNERGY not yet credited (only the
anti-synergy is modeled).

## ✅✅ THE MEASURED VALUATION NOW REACHES THE SHOP (2026-09-02, `dfba522`) — the real completion
Chasing the follow-up (the engine buying weak scalers) uncovered the load-bearing bug: **`shop_advisor.
scoring_gain` has its OWN joker valuation (tier-prior × scaling-projection) that NEVER consulted the
measured-scaler system.** So all of Tasks 1–2 reached `add_joker_marginal_fv` but **NOT the primary shop
BUY decision** — the live overlay valued Ride the Bus at ~3.78 of a boss hand (≈10 in shop units) and
recommended buying it, and that is exactly why the Task-1/2 A/Bs read neutral (the values weren't reaching
the shop). **Fix:** `Eval.modeled_scoring_fraction` bridges the measured value into `scoring_gain` (no
re-projection — the scalers project internally; pace still damps); the shop econ term now uses the
deck-aware `Eval.econ_value`. Now Cavendish (xmult) 11.99 > basic Joker 4.00 > **Ride the Bus 1.68** (was
~10), and a full board REROLLs rather than churning to buy a weak scaler.

**SIM A/B — DECISIVE n=160 (HEAD `dfba522` vs baseline `591b462` = measured values NOT reaching the shop):
NEUTRAL, confirmed KEEP.** Progress 4.144 vs 4.092 (the FIX slightly higher, Δ +0.052, p 0.53 n.s.); sign
test leans to the fix (better on 30, worse on 21, 109 tied, n.s.); tail slightly favors baseline (wins 7 vs
9, reach-8 12 vs 15 — within noise, MDE ≈ 0.23). ⚠ The n=40 first pass read scary-negative (wins 1 vs 4)
but was cascade noise on 2 known coin-flip seeds (the baseline "won" by buying the WEAKEST jokers — Ride the
Bus + green_joker — that luck into good downstream shops); n=160 dissolved it. The fix is correct for ADVICE
QUALITY (the overlay no longer tells a human to buy a near-useless scaler at 3.78-of-a-boss-hand) and
sim-neutral. Arms: `sim_out/wire_head160.jsonl` · `wire_base160.jsonl` (n=40: `wire_head.jsonl`/`wire_base.jsonl`).
⚠ Perf: `scoring_gain` now measures modeled scalers/deck-mods per shop offer (Marble/DNA run `card_add_value`
= avg_score ×2); the sim arm ran ~15% slower. Fine for now; note it if the shop-eval hot path ever matters.

## ✅ TASK 2 COMPLETE: deck-modifier jokers modeled off tier + SIM-validated (2026-09-02)
The four `deck_modifier` jokers (Midas/Certificate/Marble/DNA) had no scoring model → a flat, deck-blind
tier floor. Now each is valued off its real channel (`ad9eb45`):
- **Midas Mask & Certificate** pay in MONEY → routed through `Eval.econ_value` (jp_to_fv's econ term) with
  scoring jp ~0 (`DECK_MOD_ECON`), NOT the tier floor (which double-counts). **Midas is FACE-DECK-AWARE**
  (`CONDITIONAL_ECON`, 12/52 baseline like Business Card): no-face deck ~0, face-heavy up to 3×. Certificate's
  seal is random → flat modest prior. (Midas econ 2.0, Certificate 1.5.)
- **Marble (adds Stones) & DNA (duplicates your best card)** reduce to "value of adding a card to the deck",
  MEASURED by `ConsumableValue.card_add_value` (score delta + dilution + deck-size joker feed). Floored at a
  REDUCED prior fraction (`DECK_MOD_FLOOR=0.12`, not 0.5) because a single-card marginal at the CURRENT board
  under-states the late compounding + strategic/consistency value a snapshot can't see; the measured value
  dominates upward when a premium copy target / deck-size synergy is present.
- Balanced-deck fv: **Midas 1.60** (highest, owner prior; → ~4.8 face-heavy) > **DNA 1.44** > **Certificate
  1.20** > **Marble 0.54**. Config: `eval_function.deck_modifier_jp` / `DECK_MOD_ECON`; `joker_data` econ
  priors. 6 regression tests.

**SIM A/B (paired n=40, HEAD `ad9eb45` vs baseline `3c13617` = deck-mods at tier floor):** modeled LEADS —
progress **4.470 vs 4.250** (Δ +0.220, p 0.085), wins **4 vs 3**, reach-8 **5 vs 3**, **sign 4/0 (every
seed that moved improved, none regressed), 36/40 tied**, no crashes. ⚠ The behavioral change is TINY (Midas
buys 0→1, others ~flat) so the +0.220 is **cascade-carried, not a proven winrate lever** — same epistemic
status as the scalers (frequency ceiling: these fire ~10% of runs). It meets the correctness keep-criterion
(leans positive, no regression). Value = **advice correctness**. Arms: `sim_out/dm_head.jsonl` · `dm_base.jsonl`.
⚠ Deck-mod valuation adds `card_add_value` cost (Marble/DNA measure avg_score ×2/offer) — the HEAD arm ran ~15%
slower; acceptable but note it if the shop-eval hot path ever matters.

**➡ NEXT: the driver slot-fill follow-up** (task #22) — the engine still BUYS weak scalers (Ride the Bus 0.04)
in the shop despite advice de-prioritizing them; a `sim/driver.lua` execution path fills slots with cheap
positive-value jokers. Then Task 3 (owner-parallel tier review). See the completion blocks below.

## ✅ TASK 1 COMPLETE: the measured-scaler system is finished + SIM-validated (2026-09-02)
**Task 1 = "finish the measured-scaler system"** (owner directive: *tiers are a LEGACY FALLBACK — measure
the scalers, drop the tier floor*) is DONE. Hiker (the last unmodelled scaler) is now measured, and the whole
system was SIM-A/B'd against the pre-scaler tier-floor baseline. **Result: SAFE (neutral-to-slightly-positive,
no regression) — KEEP.** Details below; the open work is now **Task 2** (deck-modifier effects) + a follow-up.

**Hiker — DONE (`13f6917`).** A DECK-BUFFER (+5 chips/scored card, permanent) with NO joker counter to inject.
Valued MEASURED via a new **deck-buff spu** (`JV.deck_buff_delta` — paired per-hand score delta from a uniform
per-card chip buff, deck-aware): `value = deck_buff·buff_rate·N/2·spu` (`eval_function.deck_buff_scaler_marginal`,
config `D.j_hiker.deck_buff=5 / buff_rate=0.4` in joker_data). `buff_rate` = re-score CONCENTRATION (derivation
exact: it's the Σrᵢ²/s concentration, /2 the linear-ramp average — no double-count). On a standard deck ante 3
Hiker measures **0.848** (was tier-floored ~10.5) — just below a basic Joker, just above Runner.

**SIM A/B — DONE (paired n=40, HEAD 13f6917 vs baseline 7911554 = pre-scaler tier floor).** Measured scalers
lead: progress **4.250 vs 4.171** (Δ +0.079, p 0.43 n.s.), wins **3 vs 2**, reach-8 **3 vs 2**, sign **6/5, 29
tied**, NO crashes. The 29/40 ties + near-identical scaler BUY counts (RtB 4/4, runner 2/2, hiker 3/3) confirm
the FREQUENCY CEILING: scaler valuation rarely flips a decision → it can't (and needn't) move an n=40 winrate
verdict. Its value is **advice CORRECTNESS for the human overlay**, and the change meets the keep criterion for
a correctness fix (ship unless significantly negative — it leans positive). The sim can't adjudicate the FINE
calibration (Runner 2.49 vs Supernova 1.02 etc. are invisible at this n); that stays owner domain knowledge.
Arms on disk: `sim_out/scaler_head.jsonl` (measured) · `sim_out/scaler_base.jsonl` (tier floor).

**⭐ FOLLOW-UP found during the A/B (separate lever, NOT the scaler valuation).** The engine still *buys* the
near-useless Ride the Bus (measured 0.04) ~4×/40-run in the SHOP — but its ADVICE de-prioritizes it (only **2
buy-advices for RtB in the whole 40-run arm**; the ticks recommend Ramen/Blueprint/reroll/save). The buys come
from a DRIVER slot-fill / low-positive-value execution path (identical in BOTH arms, so not caused by the
scaler change). Worth a pass: the driver executes cheap positive-value buys to fill a slot even when the
headline advice says otherwise — the "over-buy weak jokers early" pattern the owner has flagged. See
`sim/driver.lua` buy loop vs the single top-line advice.

---

## (historical) The "proceed" plan that produced the above — Task 1 progress log

**DONE + committed this session:**
- **Resetting scaler** (Ride the Bus) — `97227b6`. Valued at its geometric EQUILIBRIUM (measured per-unit ×
  `inc*p/(1-p)`, p = P a scored hand is face-free). 7.875 → 0.04. Anti-synergy (Sock&Buskin/Pareidolia)
  falls out of p. Also `46eb53f` (a projection damp, now largely superseded by the equilibrium path).
- **Accumulating joker-counter scalers** (Runner/Square/Supernova/Green) — the checkpoint just committed.
  Value = measured-per-unit (counter injection) × projected avg counter, NO tier floor. Per-joker `inc` +
  `scale_rate` in `joker_data.lua` (after the catalogue). **Owner-calibrated ranking: Runner(2.49) >
  Supernova(1.02) > Square(0.74) > Green(0.64).** Runner inc fixed 8→**15** (owner data catch). Supernova
  reads `gs.run.hand_type_plays` (not a counter) → measured via a generic mult proxy + existing-plays head
  start (`e.head_start`). Key fns in `eval_function.lua`: `scaler_marginal` (resetting), `accumulating_
  scaler_marginal`, `scaler_spu` (counter injection; mult-proxy for run-state jokers), `face_free_prob`.

**✅ DONE (both items — see the completion block at the top):**
1. **HIKER** — measured deck-buff valuation shipped (`13f6917`). 10.5 → 0.848.
2. **SIM A/B** — paired n=40 vs the pre-scaler tier-floor baseline: SAFE (neutral-to-positive, no regression).

**⚠ TWO LESSONS baked into the above:** (a) *don't anchor to Runner* — it's just a joker the engine happened
to pick; measure all scalers correctly and let values fall out. (b) *PULL REAL GAME VALUES, don't guess* —
two data errors this session (Runner inc 8→15; earlier Hologram ×0.1→×0.25) were both in NEW code.

## Task 2 (after Task 1): MODEL the deck-modifier effects
Midas Mask (gold econ), DNA (deck→four-of-a-kind), Certificate (seals), Marble (stone) are `deck_modifier`
jokers valued off TIER (effects not scored). Midas likely highest value. Medium-hard.

## ✅ Task 3 COMPLETE (2026-09-02, `07b7ba4`): owner tier review of the genuine-utility jokers
Applied the owner's 0–10 judgments to the utility jokers' tier prior (their whole valuation — they don't
score): Chaos 3→6, Turtle Bean 3→5, Oops! 5→6, Invisible 6→7, Burnt 6→7, Juggler 3→4, Drunkard 3→4, Credit
Card 1→2, Mr. Bones 6→5, Troubadour 5→4, Chicot 8→6. Held: Space 5, Burglar 5, Luchador 3, Diet Cola 3,
Merry Andy 4, Matador 3. Shipped on correctness (fire rarely, no A/B).

**⭐ BEYOND-TIER follow-ups the owner raised (tier can't capture these — future synergy/modeling work):**
- **Invisible Joker** is NOT modeled as a copier at all (flat tier prior, unlike Blueprint/Brainstorm). Owner
  asked: when it duplicates a SCALING joker, does the copy inherit the current scaled state? The engine
  doesn't model its copy value yet — worth a DNA-style "value = copy your best joker" model (and verify the
  scaling-inheritance game mechanic).
- **Burglar** anti-synergy with DISCARD jokers (Mail-In Rebate, purple seals) — it removes all discards. A
  downside-modeling opportunity (`joker_downside`).
- **Oops! All 6s** — synergy with probability jokers is already modeled (`PROB_ECON` ×2); note the small
  anti-synergy with Glass cards (doubles the shatter odds).
- **Diet Cola** value is conditional (needs spare money + a free slot + a planned skip to buy-sell for the
  Double Tag) — a usage-context gate, not a flat prior.
- **Showman** is NOT in the catalogue at all — needs adding if the owner wants it valued.
- **Matador** stays UNMODELLED/acquisition-gated (no boss-trigger model); un-gating needs a boss-econ model.

## Earlier this session (2026-09-01) — SHIPPED live-run fixes (all deployed, corpus-checked)
- **The Mouth** (`316f29b` populate `played_hand_types` live + `7911554` first play must be a REPEATABLE
  hand type — the cheap overlay pass is survive_after-blind and the self-player acts on it).
- **MILK** deferring a trivial clear on illusory held-gold (`71dedb3`) + Midas gold-exclusion in HoldFuel.
- **Reroll escalation damp** (`96b56b1`) — MEASURED WIN: eng_reroll_human_save 120→109 (was the money-bleed
  behind the "sold Fibonacci" death; the churn was the symptom, the reroll spree the cause).
- **Anti-churn generalised** (`0597c14` SA.stb_funder_allowed — plain scorers were churned) + card-generation
  (Vagabond) churn protection (`d268ff6`).
- **Mystic Summit play-timing** (`84dd375` defer_uplift — dig to 0 discards). **Ride the Bus face
  anti-synergy** (`46eb53f`). **level_need planet freq-gate** (`15e35af`).
- Full owner-observation log: `ADVICE_REVIEW.md` R4. Method: reconstruct the misplay from telemetry
  (`bes_fixtures.jsonl` **state** records carry the full `gs`), fix, regression-test, corpus/sim A/B.

---

## ⭐ IN-BLIND PLAY + HOLOGRAM + JOKER AUDIT (2026-08-31) — from more live self-player runs
**Joker-model audit (owner flagged a 0.1-vs-0.25 error).** It was a typo in NEW credit code, NOT the
model: `sim/joker_tick.lua` had Hologram correct at ×0.25. Swept all scoring constants (joker_effects)
and growth increments (joker_tick) vs the real game — ALL correct. Models are trustworthy.

**Hologram never scaled** (`2cee18b`) — `card_add_value` measured a card's deck contribution via
avg_score, which reads a scaler's CURRENT counter, so the deck-size scalers' gain was invisible and
Standard cards stayed ~0.05. Added `CV.add_card_feed`: Hologram +×0.25/card (board-scaled, capped),
Blue Joker +2 chips/card; Erosion (fed by REMOVING) excluded.

**In-blind play fixes** (owner: plays best hand even when it can't clear; spends build cards):
- **Dig-play out of discards** (`7168a99`) — with no discards + no clear, play CHAFF to cycle (keep
  build cards), arbitrated by survive_after E[frac]. Safe/narrow.
- **Retention tie-break** (`1374909`, `hand_eval`) — among EQUAL-score plays, keep the more valuable
  cards (don't spend a face as a useless kicker). Gated tier<2 (pre-clear only; a spent card returns
  after a clear). Fixed "played a face it needed as a 2-pair kicker with chaff available."
- **Faceless econ credit** (`1a2e3f1`) — the measured discard now includes the discard_econ money its
  pitched cards earn, so a hand-improving discard that also dumps 3 faces isn't under-valued.

**⭐ HUMAN-VALIDATED FINDING (mined the 7 winning runs, `data/agreement_corpus/runs.jsonl`):** the
winning in-blind style is **dig hard, play one big hand** — humans DISCARD **57%** of decisions
(~2.9/blind, often clear in 1 play); the engine discards **41%** on those same states. A uniform +0.05
dig bias was **REFUTED** (`b5f2165`): discard rate moved only 41→42% and blind class-agreement FELL
430→424 (it dug where the human PLAYED). ⇒ the engine under-digs SITUATIONALLY (commit-to-a-line
judgment = the build-commitment wall), not uniformly. **Econ ground truth:** winners build to ~$40 by
ante 3-4 and HOLD **$34-40** through the endgame (never single digits mid/late). The engine dropping to
single digits is the gap. **FIXED + MEASURED (`e170265`): an ante-aware econ floor** (`SA.econ_floor`)
ramps $10->$25 (interest cap) over antes 1-4, preserving the buffer while leaving surplus-above-cap free.
Agreement A/B (shop): agree_save 278->298 (+20), eng_buy_human_save 281->276, eng_reroll_human_save
136->120 -- ~21 over-spend buys/rerolls flipped to SAVE, ~20 matching the human (flips the RIGHT
decisions, unlike the refuted dig bias). Holding PAST the cap (the human's $34-40) is option-value
banking -- the remaining unsolved econ lever.

## ⭐ THREE LIVE-RUN OBSERVATIONS — now FIXED (2026-08-30)
1. **Banner** (`e693975`) — `DV.measured` scored the redraw on the original gs, crediting the discard as
   free; for discards_left jokers (Banner +30 chips/remaining discard) that over-valued discarding, so
   the engine discarded away Banner's chips. Now scores the redraw with `discards_left-1`. No-op for any
   deck without Banner/Mystic Summit (the only readers).
2. **Red Card** (`63d41f1`) — `scaling_mult` that grows +3 Mult per BOOSTER SKIP; the engine couldn't
   express feeding it. `pack_open_advisor` now skips a WEAK pack to feed Red Card (board-amplified,
   bounded ≤0.15 frac so a real pick always wins; gated on owning Red Card).
3. **Over-skipping** (`6249773`) — `blind_select_value` priced only on-select generators, ignoring the
   in-blind value only PLAYING realizes (scalers grow, Faceless/Mail/Trading farm). Now credited, so a
   scaler/farm board skips less. NOTE: the early strong-tag skips seen (Rare/Negative/Buffoon/Orbital)
   are mostly JUSTIFIED; if over-skipping persists in a fresh run, the lever is a MEASURED
   `SK.SKIP_MARGIN` adjustment (skip fires 100% of blind-selects — the one high-firing class worth a sim A/B).

Shipped this session AFTER the block below: the "stuck on SAVE" freshness-deadlock fix (`44826dc`),
atomic one-action-per-recommendation (Jupiter+Saturn + pack make-room, `318d146`), pack "never take a
joker into a full board" demote-or-skip (`e48e6d2`), the **interest-cap unit fix scoped to value-buys**
(`4007b36` — see the `interest-cap-unit-fix-scoped` memory: do NOT revert as conversion_baseline's
"reverted" one), and **don't-acquire-unmodelled-joker (Matador)** (`c70447c`, `JokerData.UNMODELLED`).

## ⭐ CURRENT STATE (2026-08-30) — the IN-GAME SELF-PLAYER + the autonomous review loop

**A working in-game self-player was built** (`ui/autoplay.lua`, toggle **F11**, default OFF). It
translates the engine's live recommendation into REAL Balatro inputs — it plays whole runs unattended
(blind select/skip · play/discard with joker **reorder** · cash-out · shop buy/sell/reroll/leave ·
buy+open packs · pick from packs incl. **card-tarot targeting** · use held consumables · use card-tarots
with target selection). It completed a full run (ante-4 death). **Point of it:** a real-game,
unlimited-sample bug-finder for the OVERLAY's advice — no sim-fidelity doubt, no tiny-corpus limit. Actuation
notes (learned the hard way): invoke the REAL UI button node (found via `config.button`), never a fabricated
event (crashes on `e.UIBox`); Play/Discard live under `G.STAGE_OBJECTS`; boosters buy via `use_card`; SELECT
and CLICK must be on SEPARATE frames (`can_play`/`can_use` lag a frame); a deadlock-breaker acts after 3s if
the decision flickers. Logs to `bes_autoplay.log` in the save folder (the in-game logger only print()s).

**The autonomous review loop (owner directive): CLAUDE does the analysis, not the owner.** The owner
generates in-game runs (I can't drive Balatro), OR — for DECISION quality — I run the **headless sim myself**
(same engine, same decisions; only outcomes are modelled) and analyse the traces. First loop run
(`sim_out/churn0.jsonl`, n=48) DEBUNKED the joker-churn hypothesis: churn is real (2.4 bought-then-sold/run,
driven by SELL_JOKER upgrades) but its harm is a **run-length CONFOUND** — raw corr(churn,reach)=+0.61 but
corr(#shops,reach)=+0.934 and de-confounded corr(churn-per-shop,reach)=**+0.074 (flat)**. So the n=1
`XAXGTK5S` impression ("churn killed it") did NOT survive scale — **no churn fix**; it died with the right
pieces one blind too late (the conversion wall). The loop caught a spurious fix before shipping it.

**Engine fixes shipped this session** (deployed, 1100 tests pass): Judgement/generator make-room now
output-quality-aware (don't take a RANDOM joker into a full board); Riff-Raff slot-farming (sell a
disposable common to reopen a spawner slot — mechanism-justified, outcome-unproven); `best_targets` covers
ALL card-targeting tarots + spectrals (Strength/Death/Hanged-Man/seals/Aura); the pack-poverty damp
(bank toward the interest cap before gambling on a pack — SAFE + advice-positive). Reverted: the
`interest_cap` unit fix (correct but regressed agreement — winners over-bank; see `conversion_baseline.txt`).

**Advice-quality A/B harness** (`tools/agreement_run.sh`): replay the frozen 7-win corpus under the current
engine → per-decision agreement diff. **Conversion investigation** (`CONVERSION_PLAN.md` +
`conversion_baseline.txt`): the gap is ECONOMY/SPEND discipline, not valuation (C' refuted: engine ranks the
human's multiplier #1 91% of the time) — the frontier is assembly TIMING (core lands ante 4 not ante 2-3).

---

# (previous handoff) 2026-08-28 — the advice-quality + sim-fidelity session

> **THE OBJECTIVE PIVOTED to ADVICE QUALITY this session** (the pivot the old §"if the objective ever
> shifts" section below anticipated). The mod advises a *human who wins ~87.5%*; autonomous winrate is
> ceilinged (below) but advice quality is a different, non-compute-bound objective. Read this top block
> for the current state; `ADVICE_REVIEW.md` (the human's run observations + fixes) and
> `JOKER_FIDELITY_AUDIT.md` (the sim-fidelity work) hold the detail. `GRAND_AUDIT.md` + `MCTS_PLAN.md`
> remain the authoritative record of the *winrate-ceiling* investigation (unchanged, still true).

## CURRENT STATE (2026-08-28) — the advice-quality + sim-fidelity session

Three big threads, all shipped/deployed (live install CURRENT, verified byte-identical; 1100 engine +
604 sim tests pass, the 1 sim fail is a pre-existing unrelated overflow test):

1. **Advice-review fixes** (`ADVICE_REVIEW.md`) — the owner played runs with the overlay live and
   catalogued every decision. Shipped: the **anti-churn SELL_TO_BUY live-funder gate** (was dumping
   Cloud 9 / Astronomer / polychrome Ice Cream for junk — the run-killer), the **active money-dig**,
   **held-consumable use** (Hermit), **pack-first sequencing**, **free-planet picks**, **debuff-first
   discard**, and UX (Play-blind at a boss, pack-pick target text, cost/size in the big line).

2. **⭐ JOKER SIM-FIDELITY (`JOKER_FIDELITY_AUDIT.md`) — the sim was FLATTERING the engine.** The sim
   paid many jokers a flat `econ` $/round they never actually earn (Faceless flat $3 vs its real
   $5-per-3-face-discard, etc.). Audited all 150 jokers; **25 of 26 gaps now faithfully modelled** (only
   Matador deferred — needs a boss-trigger event bus). **Result, measured: the faithful world HALVED the
   sim winrate (5.0% → 2.5%)** — proving the old number was inflated. The sim now measures the same
   reality the overlay faces, which makes future overlay work trustworthy instead of fake.

3. **⭐ IN-BLIND ECON SYSTEM (two channels, `engine/discard_fuel.lua` + `engine/hold_fuel.lua`).**
   *Discard channel*: farm/feed every applicable joker by discarding — Faceless (faces), Mail-In (rank),
   Trading (single), Hit the Road/Castle/Yorick (scaler-feed) — with a **harm guard** (hard-refuse to
   bleed Ramen's xmult; soft-penalise Green Joker). *Hold channel*: farm Reserved Parking / gold by
   playing a MINIMAL hand and HOLDING econ cards (held money is now credited inside the survival rollout
   so MILK fires the multi-hand farm). Plus an **aggressive farm** (break the winner to farm when
   `survive_after` confirms a spare hand re-clears — hardened to a 99% gate / 3-hand min / 2× samples
   after an early version measured −2 wins; the fix returned it to neutral).

**The measured verdict on the econ work: SAFE + CORRECT + sim-NEUTRAL** (full system vs active-dig
baseline: 8.3% = 8.3%, wins 4 = 4, only 9/48 seeds touched). It is real value on the *overlay* (the human
converts money into builds) but the sim's greedy engine still doesn't convert — **the winrate wall is
CONVERSION, not econ generation.** That is the unobstructed frontier: turn farmed money into a directed
supermodular build (copiers × xmult × the hand being built toward).

**➡ THE CONVERSION FRONTIER NOW HAS A PLAN: `CONVERSION_PLAN.md`.** The load-bearing reframe: every
prior conversion verdict (oracle_plan §24, additive family §31, target/completion model §32c, product
board-scorer P4) was rendered on the **ceilinged autonomous-winrate instrument** — NONE on the
**advice-quality / agreement instrument** (`replay_fixtures.lua` + `agreement.py`). So the target/product
family is *closed on winrate and OPEN on agreement*. The plan attacks it agreement-first (winrate becomes
a safety rail, not the target): Phase A = baseline the agreement report (no code); B = resurrect
`completion_credit` and judge it on agreement not winrate; C = a forward marginal on the committed target
board (fixes the root cause — `sgain` is a present-board marginal, `shop_advisor.lua:516`,678); D = the
pack-pick conversion channel (41% agreement, the biggest gap). Start at Phase A.

## The autonomous-winrate ceiling (UNCHANGED — the audit trail)

The engine is mature and correct; **autonomous** winrate (baseline ~2.5%) is a *policy/assembly* gap
(not supply — Phase 0a) that is **not closable with the current apparatus**: the value function is the
wall, and that wall is compute/data-bound beyond a few nights of local compute. Consolidated at the
ceiling. Details below + in `GRAND_AUDIT.md` / `MCTS_PLAN.md`.

## The load-bearing findings (all in GRAND_AUDIT + MCTS_PLAN, with tools)

- **The 2.5% ceiling is POLICY, not supply.** `tools/stream_oracle.lua`: 70% (baseline) / 92% (rich) of
  LOST runs were *offered* ≥2 affordable multiplier keystones and passed them up. The old "supply
  ceiling / no policy can manufacture offers" verdict is overturned (offers are endogenous —
  rerolls/packs/tags/vouchers manufacture them).
- **Every present-state lever is closed/bounded on a cheap screen:** P1 slots (correctness keeper), P3
  scaler-demotion (null, reverted), P2a interest-horizon (correctness keeper, winrate-null OOS), P4
  product board-scorer (bounded weak), plus the whole §31 additive/economy family.
- **The search machinery works but the value function is the wall.** `Driver.fork`/`Driver.rollout`
  built + byte-identical determinism proven; `sim/search.lua` makes sensible picks — but the rollout
  evaluator is infeasible (~42s/decision, in-blind `best_play` cost). The cheap analytic value (=
  `pace_margin`/`capacity`) is what the greedy engine already uses, and **no learned value beats it
  out-of-sample** — confirmed FOUR ways: P5 CV (`winprob_headroom.py`), NNUE piece-level OOS
  (`richeval_probe.py` — in-sample +0.13 was winner's-curse), and interactions + TD OOS
  (`offline_value.py`). Capacity is a MC score projection that already integrates the board's
  multiplicative structure; it is the achievable cheap-value ceiling on this data.
- **⇒ A feasible search can't beat greedy (same cheap value); a better value is infeasible (rollout) or
  non-generalizing (learned, data wall).** The winrate gap is real but not closable this way.

## What WOULD break it (all beyond a few nights of local compute — declined by the operator)

1. **Brute-force ~1,300–3,000+ training wins** for an NNUE-style piece-level value → ~3–8 nights at
   rich10 (~17.5s/run wall on 6 cores), *uncertain payoff* (the generalizable features are saturated;
   piece-level may need 10k+ wins).
2. **GPU self-play (AlphaZero-lite)** — the only option that breaks the data wall (bootstraps its own
   training data), but CPU-bottlenecked by sim speed (~20 days for ~100k games) and a multi-week build.
3. **(Enabler) sim speedup** — a faster in-blind play would unlock both, but risks the sim fidelity that
   makes its value signal valid.

## Durable assets from this session (the lasting value)

- Apparatus: hardened per-decision **agreement objective** (`agreement.py` guards + `replay_fixtures`
  pipeline, validated on the 14-win save-folder corpus); **tail-weighted verdict** (reach-7/8 + McNemar
  in `analyze_runs.lua compare`); the **search scaffold** (`Driver.fork`/`rollout`, `sim/search.lua`).
- Diagnostics (each precisely bounds one part of the problem): `stream_oracle.lua`, `leaf_value_auc.py`,
  `winprob_headroom.py`, `richeval_probe.py`, `offline_value.py`, `supermodular_headroom.lua`.
- Live install is CURRENT (P1 + P2a deployed 2026-08-26; backup at
  `%APPDATA%/Balatro/bes_install_backup_20260826`).

## If the objective ever shifts from AUTONOMOUS winrate to ADVICE quality

The mod advises a *human* (who wins 87.5%). That is a **different, measurable objective** (the agreement
objective vs the winners' picks) and is NOT compute-bound. Overlay-advice improvements that align with
winners are shippable on that objective even when they are winrate-null autonomously (e.g. P2a). This is
the natural pivot if winrate is treated as ceilinged. See `GRAND_AUDIT.md` §G1.

## Audit trail

The detailed section-by-section history is archived (moved 2026-08-26): `docs/archive/WINRATE_V3_PLAN.md`
(§-citations in GRAND_AUDIT resolve here), `docs/archive/WINRATE_AUDIT.md`, `docs/archive/WINRATE_AUDIT_v2.md`.
