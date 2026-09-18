-- engine/build_plan.lua
-- The build-PLANNING layer the greedy per-joker valuation lacks.
--
-- THE PROBLEM (see CLAUDE.md "THE WALL"): the shop advisor values a joker by its marginal
-- score on the CURRENT board. That myopia can't assemble a MULTIPLICATIVE core (xmult x
-- scaling x leveled hands) that WINS: an xmult is weak on a small early board (multiplies
-- little), so it measures low and is skipped; valuing it high regardless makes the engine
-- buy it too early, leaving the CURRENT board too weak to survive -> it dies (proven by two
-- backfired attempts). The board fills with additive flat/econ commons and never compounds.
--
-- THE RESOLUTION: value a joker toward the board you're BUILDING, but only INVEST in the
-- future core when immediate survival is assured. The pacing model gives two independent
-- signals: `urgent` (can't clear the current/next boss -> must buy immediate power NOW) and
-- `on_pace` (projects past ante 8). The key window the greedy model conflates away is
-- NOT-URGENT-BUT-BEHIND: you can clear the near-term (easy) blinds even with a weak-now core
-- piece, AND you need to out-scale the ante race, so you should INVEST in the compounding
-- axis your build is missing -- accepting it's weak this blind because it pays off later.
-- When urgent, this layer stands down (no planning bonus; buy what scores NOW).
--
-- It also charges DILUTION: a 3rd flat-mult or a 3rd econ joker adds a redundant additive
-- term to a slot that a multiplier/scaler would compound -- so redundant commons are damped,
-- freeing slots for the core. PURE; consumes the POD gs + the pacing assessment.

local JokerData = require("engine.joker_data")

local BP = {}

-- Bonus/penalty magnitudes, in the SAME units as shop_advisor's synergy_bonus (added inside
-- `w_score * (sgain*5 + syn + fit)`), so a full-strength fit is comparable to a mid joker's
-- scoring gain -- enough to re-rank the buy, never enough to override survival (the invest
-- gate + econ floor still bind). Tunable; measured against sim_out/det_baseline.
BP.XMULT_FILL   = 2.2   -- an xmult to multiply a board that already has an additive base
BP.SCALING_FILL = 1.2   -- a scaler (the growth axis) while the core is thin
BP.LEVEL_FILL   = 0.0   -- (leveling comes from planets/tags, not shop jokers; reserved)
BP.FLAT_GLUT    = 1.4   -- redundant flat-mult joker (>= FLAT_CAP already) dilutes a slot
BP.ECON_GLUT    = 1.4   -- redundant econ joker (>= ECON_CAP already); money isn't the win-con
BP.FLAT_CAP     = 2
BP.ECON_CAP     = 2
BP.BASE_MIN     = 2     -- additive scorers the board needs before an xmult is worth prioritising
BP.XMULT_CAP    = 2     -- diminishing returns past this many xmult

-- Phase 5 committed-archetype planner. A commitment is a small POD stored on
-- `gs.run.build_plan`; the world/live adapter owns persistence, while this module
-- owns the pure transition. Signals are deliberately factual and sparse: a
-- hand-conditional xmult is a sufficient anchor; a scaler needs a matching
-- scorer; concentrated levels can also anchor; economy needs a scoring converter
-- plus economy support. Once chosen, the plan is sticky through the early dip.
-- E-10a: 3.0 left 106/160 runs UNCOMMITTED, starving the whole committed-archetype layer
-- (fit/retention/planet concentration + the V2c leveling push) of surface. 2.5 admits the
-- next band of real-but-thinner anchors (hand_modifier + a level / a flat), with the
-- maybe_upgrade guardrail already in place for weak commits that lock in early.
BP.COMMIT_THRESHOLD = 2.5
BP.ECON_COMMIT_THRESHOLD = 4.0

-- EARNED DIRECTION -- credit the hands the run ACTUALLY PLAYS (2026-08-14).
--
-- The planner was blind to the single most informative fact about a run. Measured on the
-- n=480 baseline (tools/commit_dist.lua, commit_gap.lua, played_hands.lua):
--   * 63% of runs NEVER commit -- the whole planner is inert in two runs out of three;
--   * of those, 75% peak at a signal of 0 or 1, i.e. at most ONE joker carrying a
--     `handtype:` tag while holding ~4.5 jokers, so the board is mostly illegible;
--   * the gate sits in an EMPTY GAP -- nothing scores between 2.0 and the 2.5 threshold,
--     while 22% of never-committers peak at exactly 2.0 (two matching hand-commons);
--   * and when it does commit it points at the hand the run actually plays only 34% of the
--     time -- 42.6% of commitments are to a hand taking under 20% of plays, 16.7% under 10%.
-- Board-matched and conditioned on reaching the same ante, committing is worth +0.28 (a3) /
-- +0.40 (a4) progress, and committing to the hand actually played a further +0.39. Those are
-- observational, but they size the prize; the defects above are not observational.
--
-- WHY THIS IS NOT `oracle_plan` (which measured a dead-even 41/40 and must not be re-run by
-- accident): that probe committed 95% of runs at ante 1 to Straight/Two Pair, from an
-- 8-sample estimate on the IDENTICAL starting deck -- it described the deck everyone starts
-- with, not the run. Play history is the deck AND the jokers AND the engine's own scoring
-- choices, measured over real hands.
--
-- WHY IT CANNOT COMMIT TO NOISE: the credit is capped BELOW COMMIT_THRESHOLD, so play share
-- alone never commits anything. It can only carry a hand over the line that ALREADY has a
-- real joker anchor -- which is exactly "a direction it has EARNED" rather than a tie-break
-- (the failure mode that sank the DeckPlan.target work, see WINRATE_V3_PLAN.md 5t).
-- Sized from the measured share distribution: the modal hand takes 0.2-0.5 of plays in 95%
-- of runs, so FLOOR/FULL bracket the real range instead of saturating or never firing.
BP.PLAY_CREDIT     = 1.5   -- max credit; deliberately < COMMIT_THRESHOLD
BP.PLAY_FLOOR      = 0.20  -- below this share a hand is incidental, not a direction
BP.PLAY_FULL       = 0.50  -- at/above this share the run is clearly landing this hand
BP.PLAY_MIN_SAMPLE = 8     -- ~one ante of hands; don't read a direction off three plays

-- ...AND A PLAY-DERIVED COMMITMENT WHEN THERE IS NO JOKER ANCHOR AT ALL.
--
-- The credit above only helps a board the planner can already partly read, which measured at
-- just 8.5% of runs (tools/commit_counterfactual.lua) -- because a credit capped below the
-- threshold cannot rescue a board with NO anchor, and that is most boards. The planner can
-- read 12.7% of a real board (0.57 of 4.53 jokers, tools/board_legibility.lua), and the
-- untagged remainder is not mis-tagged: Cavendish, Hanging Chad and Blue Joker genuinely do
-- not point at a poker hand. **The winners' boards are hand-AGNOSTIC** -- Hanging Chad appears
-- in 7 of 7 human wins, Photograph in 5, Sock and Buskin in 3, and not one carries a handtype
-- tag. So "which hand do my jokers point at" is simply the wrong question for most runs.
--
-- But those same winners concentrated LEVELING hard (hand levels 7-40 vs the engine's 4.5),
-- and leveling is the one channel where engine and winner agree EXACTLY (WINRATE_V3_PLAN 5s:
-- 0 discordant pairs). Levelling the hand you demonstrably land is not a speculative build
-- commitment, it is arithmetic, and it needs no joker anchor.
--
-- Hence a SPLIT commitment. A play-derived plan drives the LEVELING channel (planet_credit)
-- like any other, but is NEUTRAL in BP.fit -- play history says which hand to level, and
-- nothing whatever about which jokers to buy. That also keeps it clear of the one thing the
-- divergence mine told us not to disturb: relative joker pricing is directionally right.
--
-- It is PROVISIONAL: re-derived every shop until either a real tag-anchored commitment
-- reaches the threshold (which locks it) or the commit window closes (which freezes it). So
-- an early weak-hand reading self-corrects as the deck develops, and the plan that survives
-- into the ante 4-8 leveling push is the one the run has actually been landing -- which is
-- also the human's measured shape (economy and base first, power second, crossing at a4).
BP.PLAY_COMMIT_SHARE  = 0.30  -- measured: the modal hand takes >=0.30 of plays in ~64% of runs
BP.PLAY_COMMIT_MARGIN = 0.10  -- ...and clearly beats the runner-up in ~48%. Both, so a
                              -- near-tie between two hands commits to NEITHER.
BP.COMMIT_MAX_ANTE = 4
BP.COMMIT_JOKER_FILL = 1.2
BP.COMMIT_MISMATCH = 0.6
BP.COMMIT_LEVEL_CREDIT = 0.12
BP.COMMIT_LEVEL_TARGET = 8

-- Phase 5 V2c "finishing move" -- convert BANK into LEVELS once the run reaches the
-- winners' state. Evidence (n=160, sim_out/p5_w4.jsonl): ALL 6 runs that reached ante 8
-- shared (a) a cheap x3 core by ante 1-2, (b) interest-capped economy (~$25) by ante 3-4,
-- and decisively (c) ONE hand hard-leveled to 8-12 via Celestial packs + Orbital tags
-- (the winners bought 7-13 Celestial packs). The two runs that died AT ante 8 had the
-- core AND the economy but hand levels <= 2; the engine's median hand-lv at ante 6 is
-- only 3. LEVELING CONCENTRATION is the missing win-converter. So when the sharp gate
-- (COMMITTED hand + BANKED >= PUSH_MIN_DOLLARS + ante >= PUSH_MIN_ANTE) holds, the
-- committed hand's planet_credit -- the ONE shared hook every leveling delivery channel
-- already consumes (loose shop planets, the Celestial pack pool, pack picks, the Fool
-- copy, the held-planet keep value, best_planet's hand choice; Orbital is extended in
-- engine/tags) -- is raised LEVEL_PUSH x on a LONGER taper, so every channel co-moves
-- (the proven rule) and the engine spends its capped bank on levels. Pure arithmetic:
-- no rng, no cache, increase-only (the gate can only RAISE the credit, never lower it,
-- and gate-closed behaviour is byte-identical to V1).
BP.LEVEL_PUSH        = 2.0  -- x on the committed hand's leveling credit when the gate holds;
                            -- the credit dominates a planet's measured vfrac (hundredths) by
                            -- mid-game, so this ~doubles the committed hand's planet value
BP.PUSH_MIN_DOLLARS  = 20   -- "banked": at/near the $25 interest cap (Mechanics.RESERVE)
BP.PUSH_MIN_ANTE     = 4    -- the winners' finishing window (core + economy already stand)
BP.PUSH_LEVEL_TARGET = 12   -- push toward the winners' hand-lv 8-12, past the V1 target

-- The sharp, cheap gate: a COMMITTED hand, bank at/near the interest cap, ante >= 4.
function BP.level_push_active(gs)
  local c = BP.commitment(gs)
  if not c or c.kind ~= "hand" then return false end
  if ((gs.meta and gs.meta.ante) or 1) < BP.PUSH_MIN_ANTE then return false end
  return ((gs.economy and gs.economy.dollars) or 0) >= BP.PUSH_MIN_DOLLARS
end

-- One-shot UPGRADE guardrails (see maybe_upgrade). A WEAK commitment (a level-only hand or
-- an economy commitment with no live joker backing) can be locked in early from planet/skip
-- luck; if a genuinely stronger, multi-joker-anchored HAND core later emerges, staying put
-- would DILUTE that real core and strand leveling on the weak hand. So a weak commitment may
-- be replaced ONCE. The guards make it conservative (anti-thrash): the new hand needs a REAL
-- multi-joker anchor, must clearly beat the incumbent's CURRENT signal (which still credits
-- any sunk levels), and only while it still has time to pay off.
BP.UPGRADE_MAX_ANTE    = 6    -- no late pivots that can't mature
BP.UPGRADE_MIN_ANCHORS = 2    -- an upgrade abandons a plan -> demand a real multi-joker anchor
BP.UPGRADE_MARGIN      = 2.0  -- new anchored signal must beat the incumbent's live signal by this

local HAND_TAG = {
  pair = "Pair", twopair = "Two Pair", trips = "Three of a Kind",
  straight = "Straight", flush = "Flush", fullhouse = "Full House",
  four = "Four of a Kind", highcard = "High Card",
}
-- All TWELVE poker hands. The four strongest used to be missing, which made the planner
-- structurally blind to them: `commitment_signals` credits sunk hand levels only through
-- HAND_NAME, so a run that had leveled Five of a Kind scored ZERO toward committing to it.
-- That is exactly the build the one human WIN used (data/bes_runs.jsonl seed IRXRZRWV
-- leveled Five of a Kind nine times, antes 3-8). Listing them cannot make the engine commit
-- SPECULATIVELY: a secret hand scores only via sunk levels, and levels only come from a
-- planet that (per sim/content.lua) unlocks after you have actually PLAYED the hand. So the
-- commitment stays feasibility-gated by construction. -- see WINRATE_V3_PLAN.md 5m
local HAND_ORDER = { "Flush Five", "Flush House", "Five of a Kind", "Straight Flush",
  "Full House", "Four of a Kind", "Three of a Kind",
  "Two Pair", "Pair", "Flush", "Straight", "High Card" }
local HAND_NAME = {}
for _, hand in ipairs(HAND_ORDER) do HAND_NAME[hand] = true end

local function hand_tags(key)
  local out = {}
  for _, tag in ipairs(JokerData.resolve(key).tags or {}) do
    local raw = tag:match("^handtype:(.+)$")
    if raw and HAND_TAG[raw] then out[#out + 1] = HAND_TAG[raw] end
  end
  return out
end

-- Does a joker's trigger hand fire on the committed scoring hand? Mirrors the
-- contains semantics used by hand_eval (e.g. Full House contains pair + trips).
function BP.hand_matches(committed, trigger)
  if not committed or not trigger then return false end
  if committed == trigger then return true end
  local contains = {
    ["Two Pair"] = { Pair = true },
    ["Three of a Kind"] = { Pair = true },
    ["Full House"] = { Pair = true, ["Two Pair"] = true, ["Three of a Kind"] = true },
    ["Four of a Kind"] = { Pair = true, ["Two Pair"] = true, ["Three of a Kind"] = true },
    -- the strong hands CONTAIN the weak ones, so a Pair/Trips-triggered joker still fires
    -- for a run committed to a secret hand. Without these, committing to Five of a Kind
    -- made every anchor joker read as "doesn't fire" and the commitment starved itself.
    ["Straight Flush"] = { Straight = true, Flush = true },
    ["Five of a Kind"] = { Pair = true, ["Two Pair"] = true, ["Three of a Kind"] = true,
                           ["Four of a Kind"] = true },
    ["Flush House"] = { Pair = true, ["Two Pair"] = true, ["Three of a Kind"] = true,
                        ["Full House"] = true, Flush = true },
    ["Flush Five"] = { Pair = true, ["Two Pair"] = true, ["Three of a Kind"] = true,
                       ["Four of a Kind"] = true, ["Five of a Kind"] = true, Flush = true },
  }
  return contains[committed] and contains[committed][trigger] or false
end

local function commitment_signals(gs)
  local score, anchors = {}, {}
  local econ = 0
  for _, j in ipairs(gs.jokers or {}) do
    local e = JokerData.resolve(j.key)
    local w = JokerData.is_xmult(j.key) and 3
      or (JokerData.is_scaling(j.key) and 2)
      or (e.cat == "hand_modifier" and 1.5) or 1
    for _, hand in ipairs(hand_tags(j.key)) do
      score[hand] = (score[hand] or 0) + w
      anchors[hand] = anchors[hand] or {}
      anchors[hand][#anchors[hand] + 1] = j.key
    end
    if j.key == "j_bull" or j.key == "j_bootstraps" then econ = econ + 3
    elseif e.cat == "economy" then econ = econ + 1 end
  end
  for hand, lv in pairs(gs.run and gs.run.hand_levels or {}) do
    local n = math.min(4, math.max(0, (lv.level or 1) - 1))
    if n > 0 and HAND_NAME[hand] then
      score[hand] = (score[hand] or 0) + n
    end
  end
  -- Duo + Trio (or their flat/scaling counterparts) jointly point to Full House,
  -- the standard-hand analogue of the analyzed human Flush-House stack.
  if (score.Pair or 0) > 0 and (score["Three of a Kind"] or 0) > 0 then
    score["Full House"] = math.max(score["Full House"] or 0,
      math.min(score.Pair, score["Three of a Kind"]) + 2)
    anchors["Full House"] = {}
    for _, h in ipairs({ "Pair", "Three of a Kind" }) do
      for _, key in ipairs(anchors[h] or {}) do anchors["Full House"][#anchors["Full House"] + 1] = key end
    end
  end
  -- EARNED DIRECTION: the hands this run actually LANDS (BP.PLAY_* above). Everything
  -- upstream of here is a statement of intent -- what the jokers point at, what has been
  -- leveled. This is the one term that is feedback from reality, and it is nearly free:
  -- the world already tracks `hand_type_plays` for Supernova.
  local plays = gs.run and gs.run.hand_type_plays
  if plays then
    local total = 0
    for _, n in pairs(plays) do total = total + (n or 0) end
    if total >= BP.PLAY_MIN_SAMPLE then
      local span = BP.PLAY_FULL - BP.PLAY_FLOOR
      for hand, n in pairs(plays) do
        if HAND_NAME[hand] then
          local share = (n or 0) / total
          local frac = span > 0 and (share - BP.PLAY_FLOOR) / span or 0
          if frac > 0 then
            score[hand] = (score[hand] or 0) + BP.PLAY_CREDIT * math.min(1, frac)
          end
        end
      end
    end
  end
  return score, anchors, econ
end

-- The hand this run demonstrably LANDS, or nil when it is not landing one clearly enough.
-- Deterministic: hands are visited in HAND_ORDER, never in `pairs` order, so a tie can never
-- depend on table layout (a flickering commitment would re-rank the live overlay every tick).
-- See the BP.PLAY_COMMIT_* block for why this is allowed to commit with no joker anchor.
function BP.play_direction(gs)
  local plays = gs.run and gs.run.hand_type_plays
  if not plays then return nil end
  local total = 0
  for _, n in pairs(plays) do total = total + (n or 0) end
  if total < BP.PLAY_MIN_SAMPLE then return nil end
  local best, best_s, second_s = nil, 0, 0
  for _, hand in ipairs(HAND_ORDER) do
    local s = (plays[hand] or 0) / total
    if s > best_s then best, second_s, best_s = hand, best_s, s
    elseif s > second_s then second_s = s end
  end
  if not best then return nil end
  if best_s < BP.PLAY_COMMIT_SHARE then return nil end
  if best_s - second_s < BP.PLAY_COMMIT_MARGIN then return nil end
  return best, best_s, best_s - second_s
end

-- Instrumentation hook. `commitment_signals` is the gate on the whole planner, and 67% of
-- runs never pass it (tools/commit_dist.lua) -- so being able to ask "what WAS the signal in
-- the runs that never committed?" from outside is the difference between tuning the threshold
-- blind and knowing what it is rejecting. Pure, read-only, no behaviour of its own.
function BP.signals(gs) return commitment_signals(gs) end

-- One-shot upgrade of a WEAK commitment (see the UPGRADE_* guardrails above). "Weak" is judged
-- LIVE: an economy commitment, or a hand commitment whose committed hand currently has NO joker
-- anchor (level-only, or its anchor was later sold). Such a commitment may be replaced ONCE by a
-- hand with >= UPGRADE_MIN_ANCHORS jokers whose signal beats the incumbent's CURRENT signal (which
-- still credits sunk levels) by UPGRADE_MARGIN. Fires at most once (the `upgraded` flag) and only
-- toward a strictly better-anchored, higher-signal, different core -- so it can't thrash.
local function maybe_upgrade(gs, current, ante)
  if current.upgraded then return current end
  if ante > BP.UPGRADE_MAX_ANTE then return current end
  local scores, anchors = commitment_signals(gs)
  local inc_anchors = (current.kind == "hand" and anchors[current.hand] and #anchors[current.hand]) or 0
  local weak = (current.kind == "economy") or (current.kind == "hand" and inc_anchors == 0)
  if not weak then return current end
  local incumbent = (current.kind == "hand" and scores[current.hand]) or 0
  local best_hand, best_score
  for _, hand in ipairs(HAND_ORDER) do
    local na = anchors[hand] and #anchors[hand] or 0
    local s = scores[hand] or 0
    if na >= BP.UPGRADE_MIN_ANCHORS and (not best_score or s > best_score) then
      best_hand, best_score = hand, s
    end
  end
  if best_hand and best_hand ~= (current.kind == "hand" and current.hand)
     and best_score >= BP.COMMIT_THRESHOLD
     and best_score >= incumbent + BP.UPGRADE_MARGIN then
    return { kind = "hand", hand = best_hand, committed_ante = current.committed_ante,
      strength = best_score, anchors = anchors[best_hand] or {},
      upgraded = true, upgraded_ante = ante,
      upgraded_from = (current.kind == "hand" and current.hand) or "economy" }
  end
  return current
end

function BP.advance(gs, current)
  local ante = (gs.meta and gs.meta.ante) or 1
  -- A PROVISIONAL (play-derived) plan does not block re-derivation -- that is what makes it
  -- self-correcting. An anchored plan is sticky and only ever moves via maybe_upgrade.
  local provisional = current and current.via == "played"
  if current and current.kind and not provisional then return maybe_upgrade(gs, current, ante) end
  if ante > BP.COMMIT_MAX_ANTE then return current end   -- window closed: freeze whatever stands
  local scores, anchors, econ = commitment_signals(gs)
  local best_hand, best_score
  for _, hand in ipairs(HAND_ORDER) do
    local s = scores[hand] or 0
    if not best_score or s > best_score then best_hand, best_score = hand, s end
  end
  if econ >= BP.ECON_COMMIT_THRESHOLD and econ > (best_score or 0) then
    return { kind = "economy", committed_ante = ante, strength = econ }
  end
  if best_hand and best_score >= BP.COMMIT_THRESHOLD then
    return { kind = "hand", hand = best_hand, committed_ante = ante,
      strength = best_score, anchors = anchors[best_hand] or {} }
  end
  -- No anchor reached the bar. Fall back to the direction the run has EARNED by playing it.
  -- Provisional and leveling-only (see BP.PLAY_COMMIT_*), so this cannot lock a run into a
  -- weak archetype: it re-derives until an anchored plan supersedes it.
  local ph = BP.play_direction(gs)
  if ph then
    return { kind = "hand", hand = ph, committed_ante = ante, strength = 0,
      anchors = {}, via = "played" }
  end
  return current
end

function BP.commitment(gs)
  return gs.run and gs.run.build_plan or nil
end

-- The commitment as every channel EXCEPT leveling should see it. A play-derived plan
-- (BP.PLAY_COMMIT_*) knows one thing -- which hand this run lands -- and that is exactly
-- what planet_credit needs and the limit of what it is entitled to say. Anywhere else it
-- reads as "uncommitted":
--   * BP.fit    -- play history says nothing about which jokers to BUY, and the winners'
--                  boards are hand-agnostic (Hanging Chad 7/7, no handtype tag).
--   * keep_bias -- CORE_KEEP is a strategic override on the SELL side; a thin play reading
--                  should not promote a matching common to untouchable core.
--   * DeckPlan  -- and this one is load-bearing: DP.target on a Flush commitment thins
--                  toward the "dominant" suit, which on a near-flat deck is an arbitrary
--                  tie-break. Removing that gate measured -0.054 and destroyed a win
--                  (WINRATE_V3_PLAN 5t). Feeding it MORE commitments would amplify a
--                  refuted path, so it does not get to see this one.
-- Keeping the blast radius to a single mechanism is also what makes the result readable:
-- a broad re-weight lands inside the noise floor (CLAUDE.md, THE #1 TUNING RULE).
function BP.anchored_commitment(gs)
  local c = BP.commitment(gs)
  if c and c.via == "played" then return nil end
  return c
end

function BP.planet_credit(gs, hand)
  local c = BP.commitment(gs)
  if not c or c.kind ~= "hand" or c.hand ~= hand then return 0 end
  local lv = gs.run and gs.run.hand_levels and gs.run.hand_levels[hand]
  local n = math.max(0, (lv and lv.level or 1) - 1)
  local credit = 0
  if n < BP.COMMIT_LEVEL_TARGET then
    credit = BP.COMMIT_LEVEL_CREDIT * (BP.COMMIT_LEVEL_TARGET - n) / BP.COMMIT_LEVEL_TARGET
  end
  -- finishing move (see LEVEL_PUSH above): gate open -> a LEVEL_PUSH-sized credit on the
  -- LONGER taper (to the winners' 8-12), max()'d with the V1 credit so it is strictly
  -- increase-only at every level (and (T2-n)/T2 >= (T1-n)/T1 for T2 > T1 regardless).
  if n < BP.PUSH_LEVEL_TARGET and BP.level_push_active(gs) then
    local push = BP.LEVEL_PUSH * BP.COMMIT_LEVEL_CREDIT
      * (BP.PUSH_LEVEL_TARGET - n) / BP.PUSH_LEVEL_TARGET
    if push > credit then credit = push end
  end
  return credit
end

-- Sell-side core protection. On a still-weak board an xmult/scaler measures LOW (nothing to
-- multiply yet), so "sell the weakest" dumps it while econ/flat filler is hoarded -- sim:
-- 43% of bought xmult were SOLD (keep 57%) vs econ 83% kept, so the board never accumulates a
-- core. keep_bias is added to a joker's contribution ONLY when choosing which to sell, biasing
-- the choice toward the disposable additive filler, not the compounding core.
-- Keep-protection is TIERED: the compounding core (xmult/scaling) is protected hardest, but
-- FLAT SCORERS (flat_mult / flat_chips) are protected too -- they contribute real chips/mult,
-- and dumping them CRASHES scoring (sim trace: sold Stuntman +250 chips + Blue Joker, then
-- scored 8k vs 24k the blind before and died to a beatable blind). Only econ/utility filler
-- (keep_bias 0) is freely sold. So "sell the weakest" dumps money jokers, not your scorers.
BP.CORE_KEEP   = 2.5
BP.SCORER_KEEP = 1.2
-- RETRIGGERS ARE CORE (2026-08-13, from the live divergence mine). A retrigger multiplies
-- what the REST of the board already does -- the same compounding role as an xmult, which is
-- the whole reason is_core exists -- but it carries no handtype tag, so BP.fit gives it neither
-- commitment credit nor penalty while a suit-matching flat common gets +COMMIT_JOKER_FILL.
-- With keep_bias 0 it was also unprotected in the swap, and the two combined: the live log has
-- the engine advising "Sell Dusk (+$2) -- frees a slot for Scary Face / Smiley Face / Lusty
-- Joker" SIXTEEN times in one run, trading a tier-6 retrigger for tier-3 flat commons, while
-- Dusk sat on that run's WINNING final board. The valuation layer already knows instantaneous
-- measurement under-reads this class -- jp_from_measure and joker_pick_frac both floor a
-- retrigger at 0.9 x prior instead of 0.6 -- so keep_bias was simply inconsistent with it.
-- Evidence beyond the one run: Hanging Chad appears in 7 of 7 human wins, Sock and Buskin in 3.
function BP.is_retrigger(key) return JokerData.has_tag(key, "retrigger") end
function BP.is_core(key)
  return JokerData.is_xmult(key) or JokerData.is_scaling(key) or BP.is_retrigger(key)
end
local function is_flat_scorer(key)
  local c = JokerData.resolve(key).cat
  return c == "flat_mult" or c == "flat_chips"
end
function BP.keep_bias(key, gs)
  local c = gs and BP.anchored_commitment(gs)
  if c and c.kind == "hand" then
    for _, hand in ipairs(hand_tags(key)) do
      if BP.hand_matches(c.hand, hand) then return BP.CORE_KEEP end
    end
  elseif c and c.kind == "economy" then
    if key == "j_bull" or key == "j_bootstraps" or JokerData.resolve(key).cat == "economy" then
      return BP.CORE_KEEP
    end
  end
  if BP.is_core(key) then return BP.CORE_KEEP end
  if is_flat_scorer(key) then return BP.SCORER_KEEP end
  return 0
end

-- Leveling axis (B1). A hand LEVEL raises the additive BASE that the board's xmult jokers
-- multiply, so with a core it is worth ~board_multiplier x its raw hand-gain -- the third leg
-- of the compounding tripod (xmult x scaling x LEVELED hands). Sim: 29/80 death boards had a
-- core (>=2 xmult/scale) but median hand-lv = 0, i.e. the retained xmult were multiplying a
-- level-1 base. The amplifier makes the engine ACQUIRE leveling (planets/Celestial/Orbital)
-- once it has a core to multiply it through. It is 1.0 with no xmult (NO early over-buy on a
-- bare board -- same discipline as the base-gate), and rises as the core forms.
BP.XMULT_EST     = 1.9    -- rough average xMult factor contributed per owned xmult joker
BP.LEVEL_AMP_CAP = 5.0    -- bound the amplifier (an estimate, not a measurement)
function BP.level_amplifier(gs)
  local n = 0
  for _, j in ipairs(gs.jokers or {}) do if JokerData.is_xmult(j.key) then n = n + 1 end end
  if n == 0 then return 1.0 end
  return math.min(BP.LEVEL_AMP_CAP, BP.XMULT_EST ^ n)
end

-- Leveling-NEED nudge (P3-1, re-litigated Round-22). ADDITIVE credit (boss-hand-fraction
-- units, added to a Planet/Celestial's scoring value) fired ONLY when a compounding CORE
-- already exists (>=1 xmult over a scoring base) but the base it multiplies is UNDER-LEVELED.
-- Rationale the per-decision EV misses: a level-1 base x xmult is SUB-THRESHOLD; leveling it
-- to clear the boss requirement is a NONLINEAR survival gain, not the linear score the raw
-- planet EV captures. Shaped like the only lever that has ever worked (additive priority when
-- the board LACKS a needed piece -- here the piece is levels on the base), tapering to 0 as
-- levels approach the target so it can't run away. 0 with no core (no early over-buy, same
-- discipline as level_amplifier). Round 22 lost this against the BROKEN world (frozen scalers,
-- lost pack picks, x1 planet scale) where the leveled base never compounded; Phase 1-2 fixed
-- all three, so its payoff is now real -- this batch re-measures it.
BP.LEVEL_NEED_CREDIT = 0.12   -- frac-of-a-boss-hand nudge at zero levels (a modest priority)
BP.LEVEL_NEED_TARGET = 4      -- levels above 1 at/after which the base is "leveled enough"
function BP.level_need(gs)
  local plan = BP.analyze(gs)
  if plan.n_xmult < 1 or plan.base < BP.BASE_MIN then return 0 end   -- no core to multiply -> no nudge
  local lv = 0
  for _, h in pairs(gs.run and gs.run.hand_levels or {}) do lv = lv + math.max(0, (h.level or 1) - 1) end
  if lv >= BP.LEVEL_NEED_TARGET then return 0 end
  return BP.LEVEL_NEED_CREDIT * (BP.LEVEL_NEED_TARGET - lv) / BP.LEVEL_NEED_TARGET
end

local function cat(key) return (JokerData.resolve(key).cat) or "?" end
local function is_flat(key) local c = cat(key); return c == "flat_mult" or c == "flat_chips" end
local function is_econ(key)
  local e = JokerData.resolve(key)
  return (e.cat == "economy") or (e.cat == "utility" and (e.econ or 0) > 0)
end

-- (A board-READINESS gate lived here 2026-08-14: full leveling credit only once the board had
-- BASE_MIN scorers, tapering to 0.35 on an empty board, ante-bounded at 4. It did exactly what it
-- was designed to do -- ante-2 deaths 21 -> 16, ante-2 board 2.48 -> 2.77 -- and still measured
-- NULL on the outcome metric at both operating points (+0.116 p 0.286 sign 39/43 at baseline;
-- -0.165 p 0.284 sign 35/34 at rich10). Removed under the standing rule that a magnitude change
-- needs positive evidence. The mechanism worked and did not convert; that is the finding.
-- Full write-up and the income-conditioned variant worth trying: WINRATE_V3_PLAN.md 17.)

-- Analyse the board's COMPOUNDING structure: how many of each axis, and the additive "base"
-- an xmult would multiply (flat scorers + scaling jokers count as base; econ/utility don't).
function BP.analyze(gs)
  local n_xmult, n_scaling, n_flat, n_econ = 0, 0, 0, 0
  for _, j in ipairs(gs.jokers or {}) do
    if JokerData.is_xmult(j.key) then n_xmult = n_xmult + 1
    elseif JokerData.is_scaling(j.key) then n_scaling = n_scaling + 1
    elseif is_flat(j.key) then n_flat = n_flat + 1
    elseif is_econ(j.key) then n_econ = n_econ + 1 end
  end
  local base = n_flat + n_scaling   -- additive score for an xmult to multiply
  return { n_xmult = n_xmult, n_scaling = n_scaling, n_flat = n_flat, n_econ = n_econ,
           base = base,
           commitment = BP.commitment(gs),
           -- what the compounding core is MISSING
           needs_xmult   = (n_xmult < BP.XMULT_CAP) and (base >= BP.BASE_MIN),
           needs_scaling = (n_scaling < 3),
           needs_base    = (base < BP.BASE_MIN) }
end

-- Planning fit for a candidate shop joker `sj`, given the board `plan` (BP.analyze) and
-- whether we're in the INVEST window. Returns (fit, note). `invest` MUST be false when the
-- run is at immediate risk (urgent) -- then this returns 0 and the engine buys what scores
-- now. The dilution penalties apply regardless (a redundant common is a bad buy either way).
function BP.fit(gs, sj, plan, invest)
  local key = sj.key
  local fit, note = 0, nil

  -- DILUTION (always on): a redundant flat-mult / econ joker occupies a slot a compounding
  -- piece would use, and adds only a small additive term. Damp it so the board stays dense.
  if is_flat(key) and plan.n_flat >= BP.FLAT_CAP then
    fit = fit - BP.FLAT_GLUT; note = "redundant flat mult — dilutes the board"
  elseif is_econ(key) and plan.n_econ >= BP.ECON_CAP then
    fit = fit - BP.ECON_GLUT; note = "already have economy — money isn't the win condition"
  end

  -- INVESTMENT (only when survival now is OK but we're behind the ante race): build the
  -- compounding axis the core is missing. Weak THIS blind, pays off later -- and it's safe
  -- because `invest` is gated on not-urgent (we can still clear the near-term blinds).
  if invest then
    if JokerData.is_xmult(key) and plan.needs_xmult then
      fit = fit + BP.XMULT_FILL
      note = "xmult to multiply your scoring base (invest: safe now, compounds later)"
    elseif JokerData.is_scaling(key) and plan.needs_scaling then
      fit = fit + BP.SCALING_FILL
      note = note or "scaler grows all run (invest: safe now, compounds later)"
    end
  end

  -- COMMITMENT: co-move acquisitions with the sticky plan. Matching conditional
  -- scorers receive the same-sized credit as a scaler fill; off-plan conditional
  -- pieces are mildly diluted. This stays inactive on a hopeless board (the same
  -- viability gate as other future investment), so immediate survival still wins.
  local commit = plan.commitment
  if commit and commit.via == "played" then commit = nil end   -- see BP.anchored_commitment
  if commit and plan.commit_active then
    if commit.kind == "hand" then
      local tags = hand_tags(key)
      local matched = false
      for _, hand in ipairs(tags) do if BP.hand_matches(commit.hand, hand) then matched = true; break end end
      if matched then
        fit = fit + BP.COMMIT_JOKER_FILL
        note = "fits committed " .. commit.hand .. " build"
      elseif #tags > 0 then
        fit = fit - BP.COMMIT_MISMATCH
        note = note or "off-plan hand payoff"
      end
    elseif commit.kind == "economy" then
      local e = JokerData.resolve(key)
      if key == "j_bull" or key == "j_bootstraps" then
        fit = fit + BP.COMMIT_JOKER_FILL
        note = "converts the committed bankroll into score"
      elseif e.cat == "economy" then
        fit = fit + BP.COMMIT_JOKER_FILL * 0.5
        note = note or "supports the committed economy build"
      end
    end
  end

  return fit, note
end

-- ============================================================================================
-- WS-3 conversion-pressure lever (2026-09-18): BUILT, MEASURED, REVERTED. Recorded so it is not
-- re-tried. The idea was to charge the permanent-slot opportunity cost of buying a non-multiplier
-- into a maturing, multiplier-poor board (BP.conversion_cost, gated on base-exists + slot-pressure +
-- pace), to shift the board from the measured 26.8% multiplier (engine deaths) toward the human's
-- 86.5%. Paired n=160: winrate 8.1% -> 6.2%, sign 3/11 (p 0.06), tail reach-8 -4, FOUR winning runs
-- killed; board composition UNCHANGED (still 26.8% mult); agreement byte-identical. Mechanism (now
-- triangulated with the refuted ecap3 §28 and buy-bar §31g): refusing filler does NOT create
-- multipliers -- when the shop offers none, banking/rerolling lands on OTHER filler or a weaker board
-- that dies. The constraint is multiplier SUPPLY (packs/tags/rerolls/later shops), not the engine's
-- willingness to buy multipliers (it buys them #1 when present). The restraint family is closed;
-- the frontier is multiplier ACQUISITION/supply + the economy that funds it. See WINRATE_V4_PLAN §P1.
-- ============================================================================================

-- The INVEST window from a pacing assessment: invest when we're behind the ante race (not
-- on pace), so we need to out-scale it, but NOT when the run is already hopeless (a very low
-- ante-8 projection margin -> the core won't have time to pay off; buy whatever scores now).
-- We deliberately do NOT gate on `urgent` (can't-clear-next-BOSS): a weak board is almost
-- always urgent early, so that gate never opens (the bootstrap trap). Instead the xmult
-- investment is gated by `needs_xmult` requiring a scoring BASE already on the board -- i.e.
-- the board isn't bare and can clear the easy near-term blinds while the core piece grows.
BP.HOPELESS_MARGIN = 0.15  -- below this projected ante-8 margin, don't invest (survive now)
function BP.invest_window(pace)
  return pace ~= nil and (not pace.on_pace) and ((pace.margin or 0) >= BP.HOPELESS_MARGIN)
end

return BP
