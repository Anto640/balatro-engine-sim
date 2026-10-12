-- engine/eval_function.lua
-- Position evaluation: cheap scalars describing "how good is this run", now
-- driven by the joker_data catalogue so EVERY joker contributes a sensible
-- amount (not just a hardcoded xmult list). Used for run-strength readout and
-- as the basis for shop valuation. PURE.
--
-- Weights are heuristic; tests pin ORDERING and BOUNDS, not magic numbers.

local Cards = require("util.cards")
local JokerData = require("engine.joker_data")
local Downside = require("engine.joker_downside")
local Generators = require("engine.generators")
local JokerValue = require("engine.joker_value")
local Mechanics = require("engine.mechanics")
local VU = require("engine.value_units")
local ConsumableValue = require("engine.consumable_value")
local JokerEffects = require("engine.joker_effects")

local Eval = {}

-- future_value weights joker_power by this; pinned here so the measured path can
-- put a boss-hand fraction on the SAME scale as the tier path (no downstream
-- retune). 1 fraction is worth VU.FV_PER_FRAC FV points, and FV = weight*jp, so:
local FV_JOKER_WEIGHT = 1.5
Eval.FV_JOKER_WEIGHT = FV_JOKER_WEIGHT   -- frac -> FV for callers pricing a hypothetical joker
local JP_PER_FRAC = VU.FV_PER_FRAC / FV_JOKER_WEIGHT   -- == 0.5/0.3 (tier*0.5 jp vs tier*0.3 frac)

-- Total situational downside (future-value units) across owned jokers. Subtracted
-- from future_value / run_strength so a net-harmful joker contributes negatively.
function Eval.downside_total(gs)
  local p = 0
  for idx, j in ipairs(gs.jokers or {}) do p = p + Downside.penalty(gs, j, idx) end
  return p
end

-- Downside penalty for a single joker (passthrough; idx optional). Used by the
-- shop advisor so a harmful joker is skipped WHEN the situation makes it bad.
function Eval.joker_downside(gs, j, idx) return Downside.penalty(gs, j, idx) end

-- saturating map [0,inf) -> [0,1)
local function sat(x, scale)
  if x <= 0 then return 0 end
  return x / (x + scale)
end

-- ---- scaling projection -----------------------------------------------------
-- A scaling joker (Ride the Bus, Hologram, Vampire, Constellation, Green Joker)
-- is bought for what it becomes, not what it is today: its mult/xmult accrues on
-- every blind for the rest of the run, so an x-mult scaler bought early is worth
-- ~10x by ante 8. Valuing it at its static tier (or its fresh live counter)
-- under-rates the exact pieces that win runs. We correct that with a projection:
--
--   projected_value = current + per_blind_growth x blinds_remaining
--
-- expressed as a multiplier (>= 1) so the SAME factor lifts both unit systems
-- (tier units in joker_power, fraction-of-boss-hand in the shop's scoring_gain):
-- per_blind_growth is a fraction of `current`, so projected = current * mult.

local SCALE_HORIZON_ANTE = 8   -- the ante-8 race (see engine/pacing)
local PROJ_CAP = 3.0           -- bound the projection; heuristic, not unbounded

-- Blinds left until the ante-8 race is decided (~3 blinds/ante: small/big/boss).
-- This is a scaling joker's remaining growth runway.
function Eval.blinds_remaining(gs)
  local ante = math.floor((gs.meta and gs.meta.ante) or 1)
  return math.max(0, (SCALE_HORIZON_ANTE - ante) * 3)
end

-- Realized-growth gate. A scaler that only accrues on a SPECIFIC played hand
-- (Runner on Straights, Square on 4-card hands) barely grows when the deck rarely
-- makes that hand -- so projecting it at full growth over-values it (the exact
-- complaint that this fixes). Discount the growth by how often the trigger actually
-- fires, measured from greedy hand frequencies. Returns 1 (no gate) for jokers that
-- accrue every blind, or when frequencies aren't available (no deck / cheap path),
-- so existing behaviour and the no-deck tests are unchanged.
local SCALE_GATE_TARGET = 0.30  -- trigger freq at/above which growth is fully realised
local SCALE_GATE_FLOOR  = 0.20  -- never zero the growth entirely: rare triggers still
                                -- accrue, and play can be shaped toward the fuel hand
-- Ride the Bus grows +1 mult per hand with NO SCORED FACE and RESETS the instant a face is scored. So
-- (a) even alone it does not grow every hand (a scored face turns up often), and (b) it ANTI-SYNERGIZES
-- with any joker that pays for SCORING faces -- you deliberately play faces to feed those, resetting it
-- every hand (owner 2026-09-01: bought Ride the Bus onto a Sock & Buskin board; it never scaled). Damp
-- its projected growth by that reset. Pareidolia is terminal -- every card counts as a face, so it resets
-- every hand and never grows. Keyed by the RESETTING joker so the list is easy to extend.
local RIDE_BUS_ANTISYN = {
  j_pareidolia = 0.0, j_sock_and_buskin = 0.15, j_photograph = 0.15,
  j_smiley = 0.15, j_scary_face = 0.15, j_midas_mask = 0.15,
}
local function ride_the_bus_factor(gs)
  local f = 0.5  -- base: a scored face resets it often enough that undamped full growth over-values it
  for _, j in ipairs(gs.jokers or {}) do
    local a = RIDE_BUS_ANTISYN[j.key]
    if a and a < f then f = a end
  end
  return f
end

-- ===== MEASURED scaler valuation (owner 2026-09-01: tiers should be a LEGACY FALLBACK; measure scalers,
-- drop the tier floor). A RESETTING scaler's counter zeroes on a miss, so it sits at a LOW geometric
-- EQUILIBRIUM rather than growing -- so we value it as (measured score per unit of counter) x (equilibrium
-- counter), fully deck-aware, and skip the static tier floor entirely (see jp_from_measure). ==============

-- P a SCORED hand is face-FREE, so Ride the Bus survives and grows. ~0 when you own a face-scoring joker
-- (you deliberately play faces to feed it) or Pareidolia (every card is a face) -- the anti-synergy falls
-- straight out of the probability, no special case.
local function face_free_prob(gs)
  for _, j in ipairs(gs.jokers or {}) do
    local a = RIDE_BUS_ANTISYN[j.key]
    if a ~= nil then return (j.key == "j_pareidolia") and 0 or 0.05 end
  end
  local faces, n = 0, 0
  for _, c in ipairs(gs.deck or {}) do
    if not Cards.is_stone(c) then n = n + 1; if Cards.is_face(c) then faces = faces + 1 end end
  end
  if n == 0 then return 0.25 end
  return (1 - faces / n) ^ 5   -- 5 scored cards, none a face
end

-- Score value of ONE unit of a scaler's counter (measured deck-aware by injecting a reference counter).
-- A joker that reads RUN STATE instead of its own ability (Supernova reads gs.run.hand_type_plays, so
-- injecting ability.mult does nothing) is measured through a generic +mult scaler proxy -- a unit of mult
-- is worth the same whichever joker adds it.
local MULT_PROXY = "j_ride_the_bus"   -- reads ability.mult straight (measures the per-mult value cleanly)
local function scaler_spu(gs, key, opts)
  local e = JokerData.resolve(key) or {}
  local mkey = e.head_start and MULT_PROXY or key
  local cat = (JokerData.resolve(mkey) or {}).cat
  local ref = 10
  local ability = (cat == "scaling_chips") and { extra = { chips = ref } } or { mult = ref }
  local m = JokerValue.score_delta(gs, { key = mkey, ability = ability },
    { samples = (opts and opts.samples) or 6, rng = opts and opts.rng, cache = opts and opts.cache })
  return (m or 0) / ref
end

-- Analytic raw score marginal (per hand) of a RESETTING scaler at its geometric equilibrium, or nil if the
-- joker is not a modelled resetting scaler (falls through to the normal measured/tier path).
local function scaler_marginal(gs, key, opts)
  local e = JokerData.resolve(key)
  if not (e and e.inc and e.reset_on == "face") then return nil end
  local p = face_free_prob(gs)
  if p <= 0 then return 0 end
  local avg_counter = e.inc * p / (1 - p)              -- geometric equilibrium of a reset-on-miss counter
  return avg_counter * scaler_spu(gs, key, opts)
end
local function scale_trigger_factor(gs, key, freq)
  if key == "j_ride_the_bus" then return ride_the_bus_factor(gs) end
  local hands = JokerData.scale_trigger_hands(key)
  if not hands or not freq then return 1 end
  local realized = 0
  for _, h in ipairs(hands) do realized = realized + (freq[h] or 0) end
  local f = realized / SCALE_GATE_TARGET
  if f < SCALE_GATE_FLOOR then return SCALE_GATE_FLOOR end
  return (f > 1) and 1 or f
end

-- Projection multiplier (>= 1) applied to a scaling joker's current value to
-- account for accumulation over the blinds remaining. 1 (no change) for
-- non-scaling jokers and for late game (no runway left). Bounded by PROJ_CAP so
-- an ante-1 scaler is strongly preferred but can't dominate without limit. `freq`
-- is the deck's measured hand-make frequencies; pass it to gate condition-locked
-- scalers (Runner/Square) by how often their trigger hand actually appears.
function Eval.scaling_projection(gs, key, freq)
  local rate = JokerData.scaling_growth(key)
  if rate <= 0 then return 1 end
  local m = 1 + rate * Eval.blinds_remaining(gs) * scale_trigger_factor(gs, key, freq)
  return (m > PROJ_CAP) and PROJ_CAP or m
end

-- ---- component scores -------------------------------------------------------

-- Edition contribution in joker_power units. On the MEASURED path foil/holo/poly
-- scoring is already in the sampled delta, so only the extra slot (negative) is
-- added; the PRIOR/tier path adds all editions (mirrors the original inline list).
local function edition_jp(edition, include_scoring)
  if edition == "negative" then return 1.0 end       -- a whole extra joker slot
  if not include_scoring then return 0 end
  if edition == "polychrome" then return 1.5
  elseif edition == "holo" or edition == "foil" then return 0.8 end
  return 0
end

-- Deck hand-make frequencies, memoised on the shared measurement cache so the
-- per-joker scaling gate samples them ONCE per evaluation, not per joker. Needs the
-- seeded measurement rng; returns nil when we can't/shouldn't sample (cheap path).
local function hand_freq(gs, opts)
  if not opts or not opts.rng then return nil end
  local cache = opts.cache
  if cache and cache._hand_freq ~= nil then return cache._hand_freq or nil end
  local f = ConsumableValue.hand_frequencies(gs, { samples = opts.samples or 8, rng = opts.rng })
  if cache then cache._hand_freq = f or false end
  return f
end

-- Scoring hands the run has left for a scaler to accrue over. ~2.5 scoring hands per blind (blinds
-- mostly clear in 1-2, plus some farm/setup hands), across blinds_remaining. Principled, not tuned to
-- any one joker.
local ACC_HANDS_PER_BLIND = 2.5
-- AUDIT 2026-10-10 (BES_SCALER_TIME=1): TIME-CONSISTENT scaler ramp. A scaler's counter is valued as its AVERAGE
-- over the remaining run against TODAY's per-hand need (the /2 of a linear ramp) -- but the counter accrues LATE,
-- when the need is ~2x larger per ante, while a flat joker is priced at its share NOW. Replayed live buys
-- (tools/joker_realized.lua): flat jokers keep ~0.43 of their share per ante, xmult ~0.67; Runner was priced at 2.26
-- of a boss hand and realized ~0.11 one and two antes later. So each ante's counter is weighted by the same decay a
-- flat (additive) or xmult share shows: ramp = sum_k ((k+.5)/K) d^k / sum_k d^k instead of 0.5.
-- shipped 2026-10-10 with BES_SCALER_TIME (audit_scalerfix +0.166 / sf_7 +0.068; pooled n=320 +0.117, wins 96 -> 106); =0 disables
Eval.SCALER_TIME = not (os.getenv and os.getenv("BES_SCALER_TIME") == "0")
Eval.SCALER_DECAY_ADD = 0.43
Eval.SCALER_DECAY_X   = 0.67
function Eval.time_ramp(gs, kind)
  if not Eval.SCALER_TIME then return 0.5 end
  local ante = math.floor((gs.meta and gs.meta.ante) or 1)
  local K = math.max(1, 8 - ante + 1)
  local d = (kind == "xmult") and Eval.SCALER_DECAY_X or Eval.SCALER_DECAY_ADD
  local num, den, w = 0, 0, 1
  for k = 0, K - 1 do num = num + ((k + 0.5) / K) * w; den = den + w; w = w * d end
  return num / den
end
-- Measured value of an ACCUMULATING joker-counter scaler: (score per unit of counter, MEASURED deck-aware)
-- x (average counter over the run). The counter ramps ~linearly to inc*rate*N, so its average is half of
-- that. A hand-type scaler's trigger rate is the shaped scale_trigger_factor (floored, since play shapes
-- toward it); an every_hand scaler triggers every scoring hand. NO tier floor. nil if not a modelled
-- joker-counter accumulator (reset_on scalers and Hiker are handled elsewhere).
local function accumulating_scaler_marginal(gs, key, opts)
  local e = JokerData.resolve(key)
  if not (e and e.inc) or e.reset_on then return nil end
  local rate = e.scale_rate or 1                             -- committed-build trigger rate (domain data)
  local hands = JokerData.scale_trigger_hands(key)
  if hands then
    -- deck-gate: you can't scale a hand the deck can't make. Full committed rate once the deck makes the
    -- trigger hand >= ~5% greedily; damp toward half as it gets rarer (the spu is already deck-aware).
    local freq = hand_freq(gs, opts)
    if freq then
      local gf = 0
      for _, h in ipairs(hands) do gf = gf + (freq[h] or 0) end
      rate = rate * math.max(0.5, math.min(1, gf / 0.05))
    end
  end
  local n = Eval.blinds_remaining(gs) * ACC_HANDS_PER_BLIND
  local kind = (e.cat == "xmult_scaling") and "xmult" or "add"
  local future = e.inc * rate * n * Eval.time_ramp(gs, kind)
  -- head start: Supernova's counter is the run's cumulative plays of your (most-played, most repeatable)
  -- hand type -- so buying it late already reads high, and it never ramps from 0.
  local head = 0
  if e.head_start == "hand_type_plays" then
    for _, c in pairs((gs.run and gs.run.hand_type_plays) or {}) do if c > head then head = c end end
  end
  return (head + future) * scaler_spu(gs, key, opts)
end

-- Measured value of a DECK-BUFF scaler (Hiker): it adds `deck_buff` chips to each scored card, permanently.
-- Unlike the joker-counter accumulators there is no counter to inject -- the growth lives on the CARDS -- so
-- value it as (chips it projects to add to a hand's score, averaged over the run) x (score per unit per-card
-- chip, MEASURED deck-aware via JV.deck_buff_delta). Hiker adds deck_buff to the ~s scored cards each hand;
-- those chips only pay when a buffed card is RE-scored, so the effective per-hand chips grow ~linearly to
-- deck_buff*buff_rate*n and average half that. buff_rate folds in the re-score concentration (a committed
-- build re-scores its core cards, so its +5s compound; a scattered deck spreads them thin). The deck_buff_delta
-- spu already carries the s scored cards and the board mult, so s cancels out of the product. nil if not a
-- modelled deck-buff joker or no deck to sample. Same forward-average model as the buy case for an owned one
-- (its already-accrued perma_chips are baked into the current board, so this is the go-forward marginal).
local DECK_BUFF_REF = 25
local function deck_buff_scaler_marginal(gs, key, opts)
  local e = JokerData.resolve(key)
  if not (e and e.deck_buff) then return nil end
  local spu = JokerValue.deck_buff_delta(gs, DECK_BUFF_REF,
    { samples = (opts and opts.samples) or 6, rng = opts and opts.rng, cache = opts and opts.cache })
  if not spu then return nil end
  local rate = e.buff_rate or 0.4
  local n = Eval.blinds_remaining(gs) * ACC_HANDS_PER_BLIND
  return e.deck_buff * rate * n * Eval.time_ramp(gs, "add") * spu
end

-- ===== EVENT-FED scaler valuation (the measured-scaler system, generalized). A large family of scalers
-- grows its counter on a specific EVENT -- using a consumable (Constellation/Planet, Fortune Teller/Tarot),
-- DISCARDING (Castle/Hit-the-Road/Yorick), scoring a rank (Wee), scoring/destroying an enhanced card
-- (Vampire/Glass/Lucky Cat), adding a card (Hologram), a shop/blind ACTION (Campfire/sell, Throwback/skip,
-- Flash/reroll, Red Card/pack-skip, Madness/blind-select) -- rather than on the played HAND TYPE the
-- accumulating scalers key on. A flat tier x generic-projection valued a FRESH one identically in every
-- context (it valued a fresh Constellation at 4.32-of-a-boss-hand on a bare deck AND a committed build).
-- The measured model instead projects the counter's accrual by (a) how often the fuel EVENT fires -- deck-
-- aware or resource-aware per fuel -- and (b) the deck-aware per-unit score (spu), and drops the tier floor.
-- value = feed_inc * projected_events / 2 * spu   (the /2 is the linear-ramp average, as for the
-- accumulating scalers). RESETTING fuels (Hit-the-Road/round, Campfire/ante, Obelisk/on-type) don't accrue
-- over the whole run -- they sit at a per-period equilibrium, so the horizon is the PERIOD not the run.
-- Rates are OWNER-CALIBRATABLE (like scale_rate). Owner directive: measure scalers, drop the tier floor. ==

local function owns_joker(gs, key)
  for _, j in ipairs(gs.jokers or {}) do if j.key == key then return true end end
  return false
end

-- Is the run committed to LEVELING (so it will keep buying/using planets)? Any hand pushed above its base
-- level is the cleanest deck-only signal (no build_plan dependency -- eval is below it in the stack).
local function is_leveling(gs)
  local hl = gs.run and gs.run.hand_levels
  if not hl then return false end
  for _, lv in pairs(hl) do if type(lv) == "table" and (lv.level or 1) > 1 then return true end end
  return false
end

-- Rich enough that buying consumables/rerolls is unconstrained (comfortably above the interest-maxing hold).
local function is_rich(gs)
  local e = gs.economy or {}
  local hold = ((e.interest_cap or 5) * 5)   -- $ held to max interest (5 per $5, capped)
  return (e.dollars or 0) >= hold + 10
end

-- The scaler's counter UNIT, from its catalogue cat: chips (scaling_chips), flat mult (scaling_mult), or
-- x_mult (xmult_scaling). Drives where the reference counter is injected for the spu measurement.
local function scaler_kind(e)
  if e.cat == "scaling_chips" then return "chips"
  elseif e.cat == "xmult_scaling" then return "xmult" end
  return "mult"
end

-- Fraction of the (non-stone) deck that is a given rank_id, and count of a given enhancement. Deck-aware
-- inputs for the rank/suit/enhancement-gated fuels (Wee's 2s, Hit-the-Road's Jacks, Vampire/Glass' enh).
local function deck_rank_frac(gs, rank_id)
  local n, hit = 0, 0
  for _, c in ipairs(gs.deck or {}) do
    if not Cards.is_stone(c) then n = n + 1; if Cards.rank_id(c) == rank_id then hit = hit + 1 end end
  end
  return (n > 0) and (hit / n) or 0
end
local function deck_enh_count(gs, enh)
  local k = 0
  for _, c in ipairs(gs.deck or {}) do
    if c.enhancement and (not enh or c.enhancement == enh) then k = k + 1 end
  end
  return k
end
local function deck_enh_frac(gs, enh)
  local n = #(gs.deck or {})
  return (n > 0) and (deck_enh_count(gs, enh) / n) or 0
end

-- Cards scored per hand (~a 5-card hand, minus the odd non-scorer) and discards spent per scoring hand
-- (a ~3-discard budget over ~2.5 scoring hands, not all used) -- the base multipliers the rank/suit gates
-- scale. Owner-calibratable.
local SCORED_PER_HAND   = 4.5
local DISCARDS_PER_HAND = 1.0
local TAROT_MAKERS = { j_cartomancer = true, j_vagabond = true, j_hallucination = true }

-- Events of a scaler's fuel per SCORING HAND (deck/resource-aware), OWNER-CALIBRATABLE per fuel.
-- Discards a round allows, relative to the standard 3: the discard-fed scalers' fuel scales with it (an extra discard
-- a round -- Wasteful -- feeds Castle / Yorick / Hit the Road more; Burglar's none feeds nothing). 2026-10-06.
function Eval.discard_budget_scale(gs)
  local b = gs and gs.blind
  local d = b and (b.base_discards or ((b.discards_left or 3) + (b.discards_used or 0))) or 3
  return math.max(0, d) / 3
end

-- shipped 2026-10-10 together with Eval.SCALER_TIME (see there); BES_EVENT_RATES=0 disables
Eval.MEASURED_EVENT_RATES = not (os.getenv and os.getenv("BES_EVENT_RATES") == "0")
local function event_rate(gs, e)
  local fuel = e.feed_fuel
  -- AUDIT 2026-10-10 (BES_EVENT_RATES=1): the planet / tarot / sell rates were guesses (0.03-0.15 per scoring hand);
  -- the sim REALIZES 0.37 planets and 0.41 tarots per scoring hand (fsh, all antes; 0.26-0.55 / 0.10-0.61 by ante)
  -- and 0.15 joker sales. Measured values, with the owned-generator boosts kept on top.
  if Eval.MEASURED_EVENT_RATES and (fuel == "planet" or fuel == "tarot" or fuel == "sell") then
    if fuel == "planet" then return owns_joker(gs, "j_astronomer") and 0.55 or 0.37 end
    if fuel == "tarot" then
      for k in pairs(TAROT_MAKERS) do if owns_joker(gs, k) then return 0.55 end end
      return 0.41
    end
    return 0.15
  end
  if fuel == "planet" then
    if owns_joker(gs, "j_astronomer") then return 0.30 end          -- free Celestials -> heavy throughput
    if is_leveling(gs) or owns_joker(gs, "j_satellite") then return 0.15 end
    if is_rich(gs) then return 0.06 end
    return 0.03
  elseif fuel == "tarot" then
    for k in pairs(TAROT_MAKERS) do if owns_joker(gs, k) then return 0.14 end end
    if is_rich(gs) then return 0.05 end
    return 0.03
  elseif fuel == "discard_any" then
    return DISCARDS_PER_HAND * Eval.discard_budget_scale(gs)
  elseif fuel == "discard_suit" then
    return DISCARDS_PER_HAND * Eval.discard_budget_scale(gs) * 0.25 -- a random suit each round ~ 1/4 of discards
  elseif fuel == "discard_rank" then
    return DISCARDS_PER_HAND * Eval.discard_budget_scale(gs) * deck_rank_frac(gs, e.feed_rank)
  elseif fuel == "scored_rank" then
    return SCORED_PER_HAND * deck_rank_frac(gs, e.feed_rank)
  elseif fuel == "lucky_trigger" then
    return SCORED_PER_HAND * deck_enh_frac(gs, "m_lucky") * 0.20    -- lucky card scored, ~1/5 mult trigger
  elseif fuel == "card_add" then
    -- MEASURED (2026-10-04, live NSWJJKK8 flag 1: Hologram lost a Buffoon pick to Splash): sim runs that OWN the
    -- card-add scaler (only Hologram uses this fuel) add 1.35 cards an ante (n=334 ante-steps over 29 arms; net of
    -- destroys, so a floor) = 0.18 per scoring hand at 7.5 hands an ante -- it buys Standard packs for it. 0.06 was a
    -- guess below even the UNconditional rate (0.072).
    return 0.18
  elseif fuel == "reroll" then
    return is_rich(gs) and 0.30 or 0.12                             -- money-gated
  elseif fuel == "skip" then
    return 0.03
  elseif fuel == "pack_skip" then
    return 0.04
  elseif fuel == "sell" then
    return 0.05
  elseif fuel == "blind_select" then
    return 2 / (ACC_HANDS_PER_BLIND * 3)                            -- 2 selectable blinds per ante
  elseif fuel == "off_type" then
    return 0.55                                                     -- fraction of hands that aren't your most-played
  elseif fuel == "face_destroy" then
    return 0.02                                                     -- face-destruction events are rare
  end
  return 0
end

-- Score per 1.0 unit of a scaler's counter (per-chip, per-mult, or per-1.0-x_mult), measured deck-aware by
-- injecting a reference counter. A per-1.0-x_mult unit is measured at x_mult=2 (i.e. +1.0x) and divided.
local function unit_spu(gs, key, kind, opts)
  local ability, denom
  if kind == "xmult" then ability, denom = { x_mult = 2 }, 1.0
  elseif kind == "chips" then ability, denom = { extra = { chips = 100 } }, 100
  else ability, denom = { mult = 10 }, 10 end
  local m = JokerValue.score_delta(gs, { key = key, ability = ability },
    { samples = (opts and opts.samples) or 6, rng = opts and opts.rng, cache = opts and opts.cache })
  return (m or 0) / denom
end

-- Total counter the scaler accrues over its effective horizon (RUN, or a resetting PERIOD). Deck-CONSUME
-- fuels (Vampire eats enhancements, Glass shatters Glass cards) are bounded by the deck count, once each,
-- rather than a per-hand rate.
local function total_counter_gain(gs, e)
  local fuel = e.feed_fuel
  if fuel == "enh_scored" then return e.feed_inc * deck_enh_count(gs) end        -- Vampire: each enh eaten once
  if fuel == "glass_break" then return e.feed_inc * deck_enh_count(gs, "m_glass") end  -- Glass: each shatters once
  if fuel == "ceremonial" then return e.feed_inc * 2.5 end   -- one-shot: 2 x a typical right-neighbour sell value
  -- rate-based fuels: events over the horizon (run, or one resetting period)
  local horizon = Eval.blinds_remaining(gs) * ACC_HANDS_PER_BLIND
  if e.feed_reset == "round" then horizon = ACC_HANDS_PER_BLIND
  elseif e.feed_reset == "ante" then horizon = ACC_HANDS_PER_BLIND * 3
  elseif e.feed_reset == "on_type" then horizon = ACC_HANDS_PER_BLIND end   -- Obelisk resets ~each time you play best
  if horizon <= 0 then return 0 end
  return e.feed_inc * event_rate(gs, e) * horizon
end

-- Forward (go-forward) accrual value of an event-fed scaler in RAW score units: the counter ramps
-- ~linearly to total_counter_gain over its horizon, so its average ADDED per-hand contribution is half
-- that times the per-unit score. `feed_damp` (Madness: it destroys a joker each blind-select) discounts
-- the net. nil if not a modelled event-fed scaler.
local function event_fed_forward(gs, key, opts)
  local e = JokerData.resolve(key)
  if not (e and e.feed_fuel) then return nil end
  local total = total_counter_gain(gs, e)
  if total <= 0 then return 0 end
  local spu = unit_spu(gs, key, scaler_kind(e), opts)
  local ramp = e.feed_once and 1 or 0.5   -- a one-shot gain is at full from hand 1 (no linear ramp)
  -- run-horizon accruals only (resetting fuels sit at an in-period equilibrium; deck-content fuels are bounded)
  if not e.feed_once and not e.feed_reset and e.feed_fuel ~= "enh_scored" and e.feed_fuel ~= "glass_break" then
    ramp = Eval.time_ramp(gs, scaler_kind(e) == "xmult" and "xmult" or "add")
  end
  return total * ramp * spu * (e.feed_damp or 1)
end

-- What MORE RESOURCES (a hand, a discard, a card of hand size: gs2 vs gs) earn through the board and the deck beyond
-- the score of the extra play itself, as a boss-hand fraction (owner 2026-10-06: "wasteful or paint brush etc. can
-- help make more money/tarots/scaling"):
--   * discard-fed scalers accrue faster (Castle / Yorick / Hit the Road: event_rate scales with the discard budget);
--   * money jokers whose income depends on resources earn more (Mail-In Rebate sees more cards, Delayed
--     Gratification pays \$2 per unused discard, To Do List has more hands to make its hand) -- at the \$/round stream
--     rate (VU.round_income_frac);
--   * the deck's money and generator cards pay more often (Gold held at round end, Purple seals discarded, Blue seals
--     held: CV.card_round_rates reads hand size and the discard budget).
-- Each card type is valued once and multiplied (same enhancement / seal / face / low rank -> same value), with the SAME
-- seeded draws on both sides so the difference is the resource, not sampling noise.
function Eval.resource_side_frac(gs, gs2, opts)
  local need = Mechanics.boss_per_hand_need(gs)
  if not need or need <= 0 then return 0 end
  local total = 0
  for _, j in ipairs(gs.jokers or {}) do
    local e = JokerData.resolve(j.key)
    if e and e.feed_fuel and string.sub(e.feed_fuel, 1, 7) == "discard" then
      local d = total_counter_gain(gs2, e) - total_counter_gain(gs, e)
      if d ~= 0 then
        local ramp = e.feed_once and 1 or 0.5
        total = total + d * ramp * unit_spu(gs, j.key, scaler_kind(e), opts) * (e.feed_damp or 1) / need
      end
    end
    local m = (Eval.econ_value(gs2, j.key, true) or 0) - (Eval.econ_value(gs, j.key, true) or 0)
    if m ~= 0 then total = total + VU.round_income_frac(gs, m) end
  end
  local groups, order = {}, {}
  for _, c in ipairs(gs.deck or {}) do
    if c.enhancement == "m_gold" or c.enhancement == "m_lucky" or c.seal then
      local rk = Cards.rank_id(c) or 0
      local k = table.concat({ c.enhancement or "-", c.seal or "-", Cards.is_face(c) and "f" or "-",
        (rk >= 2 and rk <= 5) and "l" or "-" }, "|")
      if not groups[k] then groups[k] = { card = c, n = 0 }; order[#order + 1] = k end
      groups[k].n = groups[k].n + 1
    end
  end
  table.sort(order)
  for i, k in ipairs(order) do
    local g = groups[k]
    local function r() local x = 7919 * i; return function() x = (x * 16807) % 2147483647; return (x - 1) / 2147483646 end end
    local d = ConsumableValue.card_econ_value(gs2, g.card, r()) - ConsumableValue.card_econ_value(gs, g.card, r())
    total = total + g.n * d
  end
  return total
end

-- Mean best-play score of the CURRENT board (the base a conditional xmult multiplies),
-- memoised like hand_freq. jp_from_measure always receives the full current gs (owned AND
-- shop paths), so this is the same board across a whole evaluation -> sample it once.
local function board_base(gs, opts)
  if not opts or not opts.rng then return nil end
  local cache = opts.cache
  if cache and cache._avg_score ~= nil then return cache._avg_score or nil end
  local s = JokerValue.avg_score(gs, { samples = opts.samples or 8, rng = opts.rng })
  if cache then cache._avg_score = s or false end
  return s
end

-- DECK-MODIFIER jokers whose value is ECON, not scoring (Midas golds played faces; Certificate adds a
-- sealed card/round). Their money flows through Eval.econ_value (jp_to_fv's econ term), so jp_from_measure
-- returns ~0 SCORING jp for them -- dropping the tier floor, which otherwise DOUBLE-COUNTS with the econ.
local DECK_MOD_ECON = { j_midas_mask = true, j_certificate = true }

-- MONEY-ONLY jokers: no scoring hook (joker_effects VALUE_ONLY) and a money channel (catalogue econ > 0,
-- or Chaos's free reroll). Their worth is the money -- priced ONCE via Eval.joker_money. They used to ALSO
-- get a tier-prior SCORING value (tier x 0.5 jp sell-side, tier x 0.3 frac buy-side) for score they never
-- produce: Delayed Gratification / Mail-In Rebate each read 1.5 jp of phantom score + $4, Chaos 3.0 jp from
-- its tier alone, while the board's biggest real scorer (Smiley, MEASURED 0.75 of a boss hand) read 2.28 and
-- was sold first (owner 2026-09-23, seed DGTW4TTP). The buy side said "Reserved Parking adds ~90% of a boss
-- hand". Generators / utility jokers with no money channel are NOT money-only and keep their prior.
function Eval.is_money_only(key)
  if not JokerEffects.is_value_only(key) then return false end
  if key == "j_chaos" or key == "j_astronomer" or key == "j_gift" then return true end
  return (JokerData.resolve(key).econ or 0) > 0
end

-- Chaos the Clown: one free reroll per shop. Priced as the reroll money it saves, at the rate the engine
-- actually takes a free reroll -- the share of shops whose reroll has positive GROSS value (reroll_value +
-- reroll_cost), measured over 3458 sim shop screens (sim_out/hc_ab_after.jsonl, 2026-09-23): ante 1 0.45,
-- 2 0.58, 3 0.86, 4 0.89, 5 0.91, 6 0.97, 7+ 1.00. Replaces the hand-set tier 6.
Eval.CHAOS_REROLL_USE = { 0.45, 0.58, 0.86, 0.89, 0.91, 0.97, 1.0, 1.0 }
Eval.BASE_REROLL_COST = 5
function Eval.reroll_saving(gs, key)
  if key ~= "j_chaos" then return 0 end
  local a = math.max(1, math.min(8, (gs and gs.meta and gs.meta.ante) or 1))
  return Eval.BASE_REROLL_COST * Eval.CHAOS_REROLL_USE[a]
end

-- P(clear the boss) as a function of the board's per-hand SCORE RATIO = mean best single-hand score over
-- random deals / the boss per-hand need (Mechanics.boss_per_hand_need). FITTED, not chosen: a binomial
-- logistic in ln(ratio) over 307 real shop boards (32 states x current board + every leave-one-out,
-- tools/rollout_calibration.lua, 2026-09-23), where the outcome is the FULL engine actually playing the
-- boss round (World.play_blind). Calibration by bin: ratio~0.5 actual 0.45 / fit 0.49 (n=113), ~1.0
-- 0.82 / 0.79 (n=69), ~1.5 0.95 / 0.89 (n=37). Used to make SELLING survival-aware (shop_advisor).
Eval.CLEAR_FIT_A, Eval.CLEAR_FIT_B = 1.326, 1.966
function Eval.clear_prob(ratio)
  if not ratio or ratio <= 0 then return 0 end
  return 1 / (1 + math.exp(-(Eval.CLEAR_FIT_A + Eval.CLEAR_FIT_B * math.log(ratio))))
end

-- $/round a joker is worth as MONEY: its passive income (deck-aware econ_value) + reroll savings.
-- MONEY jokers whose $ is a SAVING or a sell-value accrual, MEASURED from the sim's own behaviour (sim_out/y1.jsonl,
-- 160 runs, 2311 rounds, 2026-09-25):
--   Astronomer: every planet and Celestial pack is free. The engine opens 0.215 Celestial packs per round (~$5 each)
--     and buys ~0.034 loose planets per round (half of its 0.068 consumable buys, $3) -> ~$1.18/round saved; a LOWER
--     bound (free packs would be opened more), and the planet share is an estimate.
--   Gift Card: +$1 sell value per joker per round, realised only when a joker is sold: 0.106 sales per round x 4.45
--     rounds held on average -> ~$0.47/round.
Eval.ASTRONOMER_SAVING = 0.215 * 5 + 0.034 * 3
Eval.GIFT_REALISED = 0.106 * 4.45
local SAVING = { j_astronomer = function() return Eval.ASTRONOMER_SAVING end,
                 j_gift = function() return Eval.GIFT_REALISED end }
function Eval.joker_money(gs, key, measured_income)
  local sv = SAVING[key]
  return Eval.econ_value(gs, key, measured_income) + Eval.reroll_saving(gs, key) + (sv and sv() or 0)
end

-- DECK-GROWTH deck-modifiers (Marble adds Stone cards; DNA duplicates your best card). Both reduce to
-- "value of adding a card to the deck", which ConsumableValue.card_add_value MEASURES deck-aware (score
-- delta + dilution + any deck-size joker feed). Returns a measured jp, or nil (no deck / cheap path /
-- not a modelled deck-grower) to fall through to the tier floor.
local STONE_CARD = { enhancement = "m_stone", id = -911 }
local DNA_COPIES = 2   -- useful permanent copies DNA makes over a run (conservative; each further copy bloats)
-- The deck card most worth duplicating with DNA: prefer editions/enhancements/seals, else the highest rank.
-- Returns a COPY (distinct id) so the measurement adds a duplicate rather than re-counting one identity.
local function dna_best_card(gs)
  local deck = gs.deck
  if not deck or #deck == 0 then return nil end
  local best, bestq
  for _, c in ipairs(deck) do
    local q = 0
    if c.edition == "polychrome" then q = q + 5
    elseif c.edition == "holo" or c.edition == "foil" then q = q + 3 end
    if c.enhancement == "m_glass" then q = q + 4
    elseif c.enhancement == "m_steel" then q = q + 3
    elseif c.enhancement == "m_mult" then q = q + 2
    elseif c.enhancement then q = q + 1 end
    if c.seal then q = q + 1 end
    q = q + (Cards.chips(c) or 0) / 100   -- tie-break toward high chips
    if not bestq or q > bestq then bestq = q; best = c end
  end
  if not best then return nil end
  local copy = {}
  for k, v in pairs(best) do copy[k] = v end
  copy.id = -912
  return copy
end
-- A REDUCED tier floor for the deck-growth modifiers: their card_add_value is measured at the CURRENT
-- board's mult, so it under-states the value the added cards accrue as the board grows LATER (Marble's
-- stones are chip fuel; DNA's copies compound) and the option value of future synergies/copy-targets a
-- single snapshot can't see. Floor at a small fraction of the prior (not the full 0.5) so a vanilla deck
-- reads "modest, situational" rather than exactly 0, while the measured value dominates when it's higher
-- (Hologram-fed Marble, an enhanced-card DNA copy).
local DECK_MOD_FLOOR = 0.12
local function deck_modifier_jp(gs, key, opts)
  if not (opts and opts.rng) then return nil end
  local deck = gs.deck
  if not deck or #deck < JokerValue.MIN_DECK then return nil end
  local need = Mechanics.boss_per_hand_need(gs)
  local cav_opts = { samples = (opts.samples or 6), rng = opts.rng, need = need }
  local floor = (JokerData.resolve(key).tier or 3) * DECK_MOD_FLOOR
  if key == "j_marble" then
    -- Marble adds ~1 Stone per blind selected, so the deck's stone count ramps to blinds_remaining and the
    -- average per-hand benefit over the run is ~ (blinds_remaining/2) x the value of one added stone.
    local cav = ConsumableValue.card_add_value(gs, STONE_CARD, cav_opts)
    if not cav then return nil end
    return math.max(floor, math.max(0, cav) * (Eval.blinds_remaining(gs) / 2) * JP_PER_FRAC)
  elseif key == "j_dna" then
    local best = dna_best_card(gs)
    if not best then return nil end
    local cav = ConsumableValue.card_add_value(gs, best, cav_opts)
    if not cav then return nil end
    return math.max(floor, math.max(0, cav) * DNA_COPIES * JP_PER_FRAC)
  end
  return nil
end

-- Hand-conditional xmults (The Duo/Trio/Family/Order/Tribe): { trigger, xmult }. The trigger
-- keys mirror joker_effects.lua's ctx.contains checks; the xmult magnitudes are the same
-- constants those on_hand closures return. Blueprint/Brainstorm copies are handled separately.
local COND_XMULT = {
  j_duo    = { trigger = "pair",     x = 2 },
  j_trio   = { trigger = "three",    x = 3 },
  j_family = { trigger = "four",     x = 4 },
  j_order  = { trigger = "straight", x = 3 },
  j_tribe  = { trigger = "flush",    x = 2 },
}
-- Which best-play hand types CONTAIN each trigger (mirrors HandEval.analyze's `contains`):
-- a Three of a Kind contains a pair, a Full House contains trips, etc. Keyed by the hand_type
-- names hand_frequencies returns.
local CONTAINS_TRIGGER = {
  pair     = { ["Pair"] = 1, ["Two Pair"] = 1, ["Three of a Kind"] = 1, ["Full House"] = 1,
               ["Four of a Kind"] = 1, ["Five of a Kind"] = 1, ["Flush House"] = 1, ["Flush Five"] = 1 },
  three    = { ["Three of a Kind"] = 1, ["Full House"] = 1, ["Four of a Kind"] = 1,
               ["Five of a Kind"] = 1, ["Flush House"] = 1, ["Flush Five"] = 1 },
  four     = { ["Four of a Kind"] = 1, ["Five of a Kind"] = 1, ["Flush Five"] = 1 },
  straight = { ["Straight"] = 1, ["Straight Flush"] = 1 },
  flush    = { ["Flush"] = 1, ["Straight Flush"] = 1, ["Flush House"] = 1, ["Flush Five"] = 1 },
}

-- Analytic marginal SCORE (same raw-score units as a measured score_delta) of a hand-conditional
-- xmult, used to replace the 6-sample MC measurement that reads ~0 when the trigger hand is rare
-- in-sample (the root cause of the engine skipping Trio/Tribe/Duo/... on a full board). Value it
-- by how often you actually PLAY a hand containing its trigger x how much the xmult adds to that
-- score. `owned` chooses the marginal semantics: ADDING sj to a board (base = avg WITHOUT it)
-- adds (X-1)*base on trigger hands; SELLING an owned one (base = avg WITH it) gives up
-- (1-1/X)*base -- same absolute marginal, expressed against the base each call site sees.
-- P(trigger) is measured WITHOUT the joker so it is CONSERVATIVE (owning it would raise it).
-- Returns nil for non-conditional-xmult jokers (fast) and when frequencies aren't samplable.
-- XMULT FORWARD VALUE (2026-09-25). A multiplier's worth is proportional to the base it multiplies, and a still-weak
-- board's base is not what it will multiply for most of the run: boards grow IN STEP with the blinds. MEASURED on every
-- recorded live shop state (bes_fixtures.jsonl, JokerValue.avg_score, 16 samples): the board's per-hand score / the
-- boss per-hand need averages 0.82 at ante 1 and 1.79 / 1.82 / 1.36 / 1.52 / 1.65 at antes 2-6 (antes 7-8 read ~8 but
-- only WINNING boards reach them -- selection-biased, excluded). So an xmult on a board below that typical ratio is
-- valued as if its base were at it -- capped at XMULT_FWD_CAP -- and a board already at/above it is unchanged. This is
-- what the tier floor was standing in for: without it the engine stopped buying Photograph (28 -> 13), The Order
-- (9 -> 1), Duo, Tribe (sim g2 vs g1) -- the winners' keystones, measured low only because the board was weak NOW.
Eval.BOARD_RATIO_TYPICAL = 1.63
Eval.XMULT_FWD_CAP = 3
local function board_ratio(gs, opts)
  local base = board_base(gs, opts)
  local need = Mechanics.boss_per_hand_need(gs)
  if not base or base <= 0 or not need or need <= 0 then return nil end
  return base / need
end
-- ❌ OFF BY DEFAULT (sim x1 vs g1, paired n=160: -0.188, p 0.06, sign 31/52, wins 33 -> 26, reach-8 42 -> 34).
-- Scaling ONLY the multipliers up to 3x distorted the ranking against everything left unscaled: Acrobat (last-hand
-- x3) bought 11 -> 18, Blueprint (a copier, unscaled) 14 -> 8. The typical-board-ratio measurement stands; applying
-- it to one class alone does not. Opt-in for experiments: BES_XMULT_FWD=1.
Eval.XMULT_FWD = os.getenv and os.getenv("BES_XMULT_FWD") == "1"
function Eval.xmult_forward_scale(gs, key, opts)
  if not Eval.XMULT_FWD then return 1 end
  if not JokerData.is_xmult(key) or JokerData.is_scaling(key) or not Eval.floor_free(key) then return 1 end
  local r = board_ratio(gs, opts)
  if not r then return 1 end
  return math.max(1, math.min(Eval.XMULT_FWD_CAP, Eval.BOARD_RATIO_TYPICAL / math.max(r, 1e-6)))
end

local function conditional_xmult_marginal(gs, key, opts, owned)
  local cx = COND_XMULT[key]
  if not cx then return nil end
  local freq = hand_freq(gs, opts)
  if not freq then return nil end
  local contains = CONTAINS_TRIGGER[cx.trigger]
  local p = 0
  for ht, f in pairs(freq) do if contains[ht] then p = p + f end end
  if p <= 0 then return 0 end
  local base = board_base(gs, opts)
  if not base or base <= 0 then return nil end
  local factor = owned and (1 - 1 / cx.x) or (cx.x - 1)
  return p * factor * base * Eval.xmult_forward_scale(gs, key, opts)
end

-- The measured SCORING value (fraction of a boss hand) of a joker the measured-scaler / deck-modifier
-- system models, or nil if it isn't one (so the caller keeps its own valuation). This is the BRIDGE that
-- carries Tasks 1-2 (Ride the Bus at equilibrium, the accumulating scalers, Hiker, Marble/DNA) into the
-- SHOP buy decision -- `shop_advisor.scoring_gain` has its OWN tier-prior x projection valuation that
-- otherwise ignores all of the above (it valued Ride the Bus at 3.78 vs the measured 0.04). The scalers
-- already project internally (accrued counter / equilibrium), so the caller must NOT re-apply a projection.
-- Econ-channel deck-mods (Midas/Certificate) return 0 here -- their value is MONEY, added via Eval.econ_value.
-- ==== UTILITY JOKERS, MEASURED (R12b, 2026-09-24) ============================================================
-- These jokers have no scoring hook (VALUE_ONLY) and used to be priced by their flat tier prior (tier x 0.5 jp)
-- -- which is WHY the measured jokers need a tier floor at all: without it the unmodelled priors out-ranked
-- every measured joker (sim r12: bought Drunkard 23x, wins 28 -> 15). Modelling them on the engine's own
-- units removes that asymmetry for the two commonest families. Both return a boss-hand FRACTION (the unit
-- of every other joker's value), deck- and board-aware.
--
-- LEVELING (Burnt, Space): a level every round / a 1-in-4 level per hand accrues like an event-fed scaler --
-- the added per-hand score ramps ~linearly over the remaining blinds, so its average is half the total,
-- times the per-hand worth of one level (frequency x CV.level_gain in board context, plus the build's
-- planet credit -- the SAME quantity CV.best_planet ranks planets by).
-- MEASURED (tools/burnt_aim.lua, 80 sim seeds with Burnt kept all run, 1265 Burnt rounds, 2026-09-24):
--   BURNT_QUALITY = mean worth(the hand the first discard actually levels) / worth(levelling the BEST hand)
--                   = 0.560, flat across antes (0.50-0.64) -- 20% of first discards are the aimed clear-in-hand
--                   discard, the rest are digs that level their chaff;
--   BURNT_FIRE    = share of Burnt rounds with ANY discard = 0.831 (16.9% end without one).
Eval.BURNT_QUALITY = 0.560
Eval.BURNT_FIRE    = 0.831
local function level_worth(gs, hand, freq, bctx)
  local f = freq[hand] or 0
  if f <= 0 or not Mechanics.HAND_PLANET[hand] then return 0 end
  local BuildPlan = require("engine.build_plan")
  return f * ConsumableValue.level_gain(gs, hand, 1, bctx)
    + BuildPlan.planet_credit(gs, hand) * Mechanics.boss_per_hand_need(gs)
end
Eval._level_worth = level_worth   -- for tools/burnt_aim.lua (the measurement of BURNT_AIM)
local function leveling_fraction(gs, key, opts)
  local need = Mechanics.boss_per_hand_need(gs)
  if not need or need <= 0 then return nil end
  local freq, bctx = ConsumableValue.hand_frequencies(gs, { samples = 8, rng = opts.rng })
  if not freq then return nil end
  local R = Eval.blinds_remaining(gs)
  if R <= 0 then return 0 end
  if key == "j_burnt" then
    local base_d = ((gs.blind or {}).base_discards) or 3
    if base_d <= 0 or owns_joker(gs, "j_burglar") then return 0 end     -- no discard -> no level
    local best = 0
    for hand in pairs(freq) do best = math.max(best, level_worth(gs, hand, freq, bctx)) end
    local per_level = Eval.BURNT_FIRE * Eval.BURNT_QUALITY * best
    return 0.5 * R * per_level / need                                   -- 1 level/round, linear ramp
  elseif key == "j_space" then
    local p = owns_joker(gs, "j_oops") and 0.5 or 0.25                  -- 1 in 4 (Oops doubles it)
    local H = R * ACC_HANDS_PER_BLIND
    local s = 0
    for hand, f in pairs(freq) do
      -- levels of `hand` gained over the horizon = p * f * H; the average in place is half that
      if f > 0 then s = s + 0.5 * p * f * H * level_worth(gs, hand, freq, bctx) end
    end
    return s / need
  end
  return nil
end

-- RESOURCE jokers (hands / discards / hand size), priced from a FULL-ENGINE measurement (tools/resource_value.lua,
-- 2026-09-24): 88 recorded shop boards played the NEXT ante's boss with the real decision engine under +1 discard /
-- +1 hand size / +1 hand on paired round seeds. The relative gain in output (fraction of the target reached)
-- depends almost entirely on how strong the board already is, which the per-hand score ratio against the next
-- ante's boss (r_next) predicts cleanly -- so the gain is a lookup, costs nothing at shop time, and needs no
-- rollout. A joker that lifts the blind's output by x% is worth what a joker adding x% to every hand is worth:
-- frac = r0 x gain, r0 the board's per-hand ratio against THIS ante's need (the unit of every joker value).
--
-- History: the first version priced these with the cheap greedy rollout. Against the full engine it OVER-valued
-- hand size (+15.2% vs +9.3%) and hands (+11.2% vs +5.8%) and UNDER-valued discards (+3.0% vs +4.6%; it wastes
-- them) -- which is why discards were left on the tier prior. This table replaces it for all six jokers.
--
-- gain per ONE unit, isotonic (monotone non-increasing), linearly interpolated in r_next between band centres:
Eval.RESOURCE_R  = { 0.10,  0.275, 0.425, 0.60,  0.85,  1.25,  2.00 }
Eval.GAIN_DISC   = { 0.094, 0.090, 0.090, 0.023, 0.016, 0.005, 0.001 }
Eval.GAIN_HSIZE  = { 0.302, 0.178, 0.134, 0.029, 0.021, 0.008, 0.000 }
Eval.GAIN_HAND   = { 0.123, 0.114, 0.114, 0.024, 0.024, 0.005, 0.001 }
local function interp(xs, ys, x)
  if x <= xs[1] then return ys[1] end
  for k = 2, #xs do
    if x <= xs[k] then
      local t = (x - xs[k - 1]) / (xs[k] - xs[k - 1])
      return ys[k - 1] + t * (ys[k] - ys[k - 1])
    end
  end
  return ys[#ys]
end
function Eval.resource_gain(kind, r_next)
  local ys = (kind == "discard" and Eval.GAIN_DISC) or (kind == "hand_size" and Eval.GAIN_HSIZE) or Eval.GAIN_HAND
  return interp(Eval.RESOURCE_R, ys, r_next)
end
-- per-unit deltas (World.blind_resources' rules). Multi-unit effects (Merry Andy +3 discards, Turtle Bean +5 hand
-- size, Burglar +3 hands) are EXTRAPOLATED linearly from the measured +1 -- an upper bound, since returns diminish.
local RESOURCE = {
  j_drunkard    = { d = 1 },
  j_juggler     = { hs = 1 },
  j_merry_andy  = { d = 3, hs = -1 },
  j_troubadour  = { hs = 2, h = -1 },
  j_turtle_bean = { hs = 5, decays = true },                 -- +5, -1 per round
  j_burglar     = { h = 3, lose_discards = true },           -- +3 hands, ALL discards lost
}
local function resource_fraction(gs, key, opts, owned, idx)
  local spec = RESOURCE[key]
  if not spec or not opts.rng then return nil end
  local ckey = "_resource|" .. key .. "|" .. tostring(owned and idx or "add")
  if opts.cache and opts.cache[ckey] ~= nil then return opts.cache[ckey] end
  local need = Mechanics.boss_per_hand_need(gs)
  if not need or need <= 0 then return nil end
  -- the board WITHOUT this joker, same deck
  local rest = {}
  for i, j in ipairs(gs.jokers or {}) do if not (owned and i == idx) then rest[#rest + 1] = j end end
  local base = {}
  for k, v in pairs(gs) do base[k] = v end
  base.jokers = rest
  local score = JokerValue.avg_score(base, { samples = 8, rng = opts.rng })
  if not score or score <= 0 then return nil end
  local r0 = score / need
  local ante = math.floor((gs.meta and gs.meta.ante) or 1)
  local nb = { meta = { ante = math.min(8, ante + 1) }, blind = gs.blind, run = gs.run }
  local need_next = Mechanics.boss_per_hand_need(nb)
  local r_next = (need_next and need_next > 0) and (score / need_next) or r0
  local gd, gz, gh = Eval.resource_gain("discard", r_next), Eval.resource_gain("hand_size", r_next),
    Eval.resource_gain("hand", r_next)
  local hs_units = spec.hs or 0
  if spec.decays then
    local ab = owned and idx and gs.jokers[idx] and gs.jokers[idx].ability
    local cur = (type(ab) == "table" and tonumber(ab.turtle)) or 5
    -- Turtle Bean's +N shrinks by 1 per round and is gone after N rounds: average bonus over the horizon
    local R = math.max(1, Eval.blinds_remaining(gs))
    local sum = 0
    for k = 0, math.min(cur, R) - 1 do sum = sum + (cur - k) end
    hs_units = sum / R
  end
  local d_units = spec.d or 0
  if spec.lose_discards then d_units = -(((gs.blind or {}).base_discards) or 3) end
  local gain = d_units * gd + hs_units * gz + (spec.h or 0) * gh
  local frac = r0 * gain
  if opts.cache then opts.cache[ckey] = frac end
  return frac
end

-- CONSUMABLE GENERATORS (2026-09-25): priced by what they MAKE, the same shape as Burnt Joker -- items per
-- round x the remaining rounds x 0.5 (a card made later has less runway left to pay back) x the mean value of a
-- RANDOM card of that type (Packs.mean_random: the pack pools' own measured per-card values), times whether the
-- output has a consumable slot to land in (a full tray is transient -- the engine uses cards -- so it is damped,
-- not zeroed; see CLAUDE.md "Created things need a SLOT"). Rates per round, deck- and board-aware:
--   Cartomancer  1 Tarot per blind selected
--   8 Ball       1 in 4 per scored 8        -> hands x 8s scored per hand x 1/4
--   Superposition Tarot on a Straight with an Ace -> hands x P(Straight/Straight Flush) x 2/10 rank windows
--   Seance       Spectral on a Straight Flush -> hands x P(Straight Flush)
--   Hallucination 1 in 2 per booster opened -> packs per round x 1/2 (MEASURED: 2315 packs / 2218 rounds in the
--                sim, ~1.0 per round)
--   Vagabond     Tarot per hand played at <= $4 -> hands x Generators.fire_rate (the existing $ proxy)
--   Sixth Sense  Spectral when the round's first discard is a lone 8 -- the play engine now makes that discard
--                when the clear is in hand and a spare 8 is held -> share of rounds with the clear in hand at the
--                first decision (MEASURED 0.167 = 20.1% aimed first discards x 83.1% of rounds with any discard,
--                tools/burnt_aim.lua) x P(a spare 8 among ~3 spare cards)
--   Perkeo       a Negative copy of a random HELD consumable at each shop end -> 1 per round while holding one:
--                the mean value of the cards held now, else a random Tarot x PERKEO_HOLD (share of shop ends with
--                a card held -- an ESTIMATE, not measured: the engine mostly uses cards at once)
-- Oops! All 6s doubles every "1 in N". Riff-Raff (makes 2 Commons) is priced separately below: its output is JOKERS.
Eval.PACKS_PER_ROUND = 1.0
Eval.CLEAR_IN_HAND_SHARE = 0.167
Eval.PERKEO_HOLD = 0.3
local GENERATOR = {
  j_cartomancer   = { kind = "Tarot" },
  j_8_ball        = { kind = "Tarot" },
  j_superposition = { kind = "Tarot" },
  j_seance        = { kind = "Spectral" },
  j_hallucination = { kind = "Tarot" },
  j_vagabond      = { kind = "Tarot" },
  j_sixth_sense   = { kind = "Spectral" },
  j_perkeo        = { kind = "Tarot" },
}
local function generator_rate(gs, key, freq)
  local oops = owns_joker(gs, "j_oops") and 2 or 1
  local H = ACC_HANDS_PER_BLIND
  if key == "j_cartomancer" then return 1 end
  if key == "j_8_ball" then return math.min(1, H * SCORED_PER_HAND * deck_rank_frac(gs, 8) * 0.25 * oops) end
  if key == "j_superposition" then
    local p = ((freq and freq["Straight"]) or 0) + ((freq and freq["Straight Flush"]) or 0)
    return H * p * 0.2
  end
  if key == "j_seance" then return H * ((freq and freq["Straight Flush"]) or 0) end
  if key == "j_hallucination" then return Eval.PACKS_PER_ROUND * math.min(1, 0.5 * oops) end
  if key == "j_vagabond" then return H * Generators.fire_rate(gs, key) end
  if key == "j_sixth_sense" then
    local spare = math.max(1, ((gs.run and gs.run.hand_size) or 8) - 5)
    return Eval.CLEAR_IN_HAND_SHARE * (1 - (1 - deck_rank_frac(gs, 8)) ^ spare)
  end
  if key == "j_perkeo" then return 1 end
  return 0
end
local function generator_fraction(gs, key, opts, owned)
  local spec = GENERATOR[key]
  if not spec then return nil end
  local R = Eval.blinds_remaining(gs)
  if R <= 0 then return 0 end
  local Packs = require("engine.packs")
  local freq = ConsumableValue.hand_frequencies(gs, { samples = 8, rng = opts.rng })
  local rate = generator_rate(gs, key, freq)
  if rate <= 0 then return 0 end
  local ckey = "_mean_random|" .. spec.kind
  local mean = opts.cache and opts.cache[ckey]
  if mean == nil then
    mean = Packs.mean_random(gs, spec.kind, { rng = opts.rng, tarot_samples = 3 })
    if opts.cache then opts.cache[ckey] = mean end
  end
  local fit = (Generators.output_room_free(gs, key, owned) > 0) and 1 or 0.6
  if key == "j_perkeo" then
    -- the copy is of a card you HOLD (and is Negative: no slot needed)
    local held, n = 0, 0
    for _, c in ipairs(gs.consumables or {}) do
      local v, g = ConsumableValue.card_value(gs, c.set or "Tarot", c.key, nil, Mechanics.boss_per_hand_need(gs), opts.rng, 3)
      held = held + math.max(0, (v or 0) + VU.income_frac(gs, g or 0)); n = n + 1
    end
    mean = (n > 0) and (held / n) or (mean * Eval.PERKEO_HOLD)
    fit = 1
  end
  return 0.5 * rate * R * mean * fit
end

-- BOSS DISABLERS (Chicot: every boss; Luchador: sell to disable the current one). A disabled boss is a plain x2 blind
-- (blind.lua Blind:disable: The Wall's chips /2, Violet Vessel /3, every other effect removed). MEASURED with the full
-- engine (tools/boss_cost.lua, 30 recorded boards x 8 paired rounds per boss, next ante): the relative OUTPUT gain
-- (fraction of target reached) from disabling each boss. The Wheel / Fish / House / Mark read 0 because the engine sees
-- face-down cards (known limitation); Pillar / Serpent / Ox read 0 too. frac = r0 x gain, the resource-table convention
-- (also measured at the boss). Chicot averages the known upcoming boss with the eligible pool of every later ante;
-- Luchador is one use on the upcoming boss, spread over the bosses left.
Eval.BOSS_DISABLE_GAIN = {
  bl_wall = .586, bl_mouth = .576, bl_water = .454, bl_plant = .744, bl_needle = .389, bl_flint = .484,
  bl_goad = .148, bl_eye = .178, bl_window = .083, bl_manacle = .121, bl_club = .141, bl_head = .062,
  bl_arm = .028, bl_psychic = .007, bl_tooth = 0, bl_wheel = 0, bl_fish = 0, bl_ox = 0, bl_pillar = 0,
  bl_serpent = 0, bl_house = 0, bl_mark = 0, bl_hook = .003 }
Eval.BOSS_MIN_ANTE = {   -- mirrors sim/world World.BOSS_MIN_ANTE (engine must not require sim/)
  bl_hook = 1, bl_club = 1, bl_psychic = 1, bl_goad = 1, bl_window = 1, bl_head = 1, bl_pillar = 1, bl_manacle = 1,
  bl_house = 2, bl_wall = 2, bl_wheel = 2, bl_arm = 2, bl_fish = 2, bl_water = 2, bl_mouth = 2, bl_mark = 2,
  bl_needle = 2, bl_flint = 2, bl_eye = 3, bl_tooth = 3, bl_plant = 4, bl_serpent = 5, bl_ox = 6 }
local function pool_gain(ante)
  local s, n = 0, 0
  for k, a in pairs(Eval.BOSS_MIN_ANTE) do if a <= ante then s = s + (Eval.BOSS_DISABLE_GAIN[k] or 0); n = n + 1 end end
  return (n > 0) and (s / n) or 0
end
local function boss_disable_fraction(gs, key, opts)
  local need = Mechanics.boss_per_hand_need(gs)
  if not need or need <= 0 then return nil end
  local base = board_base(gs, opts)
  if not base or base <= 0 then return nil end
  local r0 = base / need
  local ante = math.floor((gs.meta and gs.meta.ante) or 1)
  local known = gs.run and gs.run.boss_key
  local g_now = (known and Eval.BOSS_DISABLE_GAIN[known]) or pool_gain(ante)
  local gains = { g_now }
  for a = ante + 1, 8 do gains[#gains + 1] = pool_gain(a) end
  if key == "j_luchador" then return r0 * g_now / #gains end
  local s = 0
  for _, g in ipairs(gains) do s = s + g end
  return r0 * s / #gains
end

-- nil when `key` is not a modelled utility joker (the caller keeps its own valuation)
function Eval.utility_fraction(gs, key, opts, owned, idx)
  opts = opts or {}
  if not opts.rng then return nil end
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < JokerValue.MIN_DECK then return nil end
  if key == "j_burnt" or key == "j_space" then return leveling_fraction(gs, key, opts) end
  if RESOURCE[key] then return resource_fraction(gs, key, opts, owned, idx) end
  if GENERATOR[key] then return generator_fraction(gs, key, opts, owned) end
  if key == "j_chicot" or key == "j_luchador" then return boss_disable_fraction(gs, key, opts) end
  if key == "j_oops" then
    -- Oops! All 6s doubles every listed probability. MEASURED as: (a) the board's mean score with vs without it on
    -- the SAME sampled hands (HandEval applies it to Lucky cards), plus (b) the lift in every owned odds-driven
    -- joker the utility models price (8 Ball, Space, Hallucination, Sixth Sense, ...), minus (c) Gros Michel's
    -- doubled extinction (1/6 -> 1/3 a round). Money odds (Lucky $, Business Card) are not in score (not counted).
    local need = Mechanics.boss_per_hand_need(gs)
    if not need or need <= 0 then return nil end
    local with = {}
    for k, v in pairs(gs) do with[k] = v end
    local js = {}
    for i, oj in ipairs(gs.jokers or {}) do if not (owned and i == idx) then js[#js + 1] = oj end end
    local base = {}
    for k, v in pairs(gs) do base[k] = v end
    base.jokers = js
    local wj = {}
    for i, oj in ipairs(js) do wj[i] = oj end
    wj[#wj + 1] = { key = "j_oops", ability = { extra = {} } }
    with.jokers = wj
    local seed = math.floor(opts.rng() * 2147483646) + 1
    local function lcg(x) return function() x = (x * 1103515245 + 12345) % 2147483648; return x / 2147483648 end end
    local s1 = JokerValue.avg_score(with, { samples = 16, rng = lcg(seed) })
    local s0 = JokerValue.avg_score(base, { samples = 16, rng = lcg(seed) })
    local frac = ((s1 or 0) - (s0 or 0)) / need
    for _, oj in ipairs(js) do
      if Eval.UTILITY_MODELLED[oj.key] and oj.key ~= "j_oops" then
        local a = Eval.utility_fraction(with, oj.key, { rng = lcg(seed + 1), cache = nil }, false)
        local b = Eval.utility_fraction(base, oj.key, { rng = lcg(seed + 1), cache = nil }, false)
        if a and b then frac = frac + (a - b) end
      end
      if oj.key == "j_gros_michel" then
        -- extinction 1/6 -> 1/3 a round halves its expected remaining life: lose half its measured worth
        local rest = {}
        for _, x in ipairs(js) do if x ~= oj then rest[#rest + 1] = x end end
        local g0 = {}
        for k, v in pairs(base) do g0[k] = v end
        g0.jokers = rest
        local gm = JokerValue.score_delta(g0, oj, { samples = 8, rng = lcg(seed + 2) })
        if gm then frac = frac - 0.5 * gm / need end
      end
    end
    return frac
  end
  if key == "j_riff_raff" then
    -- 2 random Commons at blind select, into FREE joker slots (Generators.output_fit: a made room counts 0.1).
    -- A filled board stops it producing, so it is priced as the fill it can deliver now, not per round.
    local Packs = require("engine.packs")
    local common = Packs.expected_joker_of_rarity(gs, "Common", { rng = opts.rng, samples = 3, measure_count = 6 })
    if not common then return nil end
    return 2 * Generators.output_fit(gs, key, owned) * common
  end
  return nil
end
Eval.UTILITY_MODELLED = { j_burnt = true, j_space = true }
for k in pairs(RESOURCE) do Eval.UTILITY_MODELLED[k] = true end
for k in pairs(GENERATOR) do Eval.UTILITY_MODELLED[k] = true end
Eval.UTILITY_MODELLED.j_riff_raff = true
Eval.UTILITY_MODELLED.j_oops = true
Eval.UTILITY_MODELLED.j_chicot = true
Eval.UTILITY_MODELLED.j_luchador = true

function Eval.modeled_scoring_fraction(gs, key, opts)
  local e = JokerData.resolve(key)
  local need = Mechanics.boss_per_hand_need(gs)
  if not need or need <= 0 then return nil end
  if e.reset_on then
    local sm = scaler_marginal(gs, key, opts); return sm and (sm / need) or nil
  elseif e.inc then
    local sm = accumulating_scaler_marginal(gs, key, opts); return sm and (sm / need) or nil
  elseif e.deck_buff then
    local sm = deck_buff_scaler_marginal(gs, key, opts); return sm and (sm / need) or nil
  elseif e.feed_fuel then
    -- EVENT-fed (Constellation, Castle, Vampire, Campfire, ...): a fresh one measures 0, so value it by its
    -- deck/resource-aware projected accrual (no tier floor). It projects internally -> caller must not re-project.
    local fwd = event_fed_forward(gs, key, opts); return fwd and (fwd / need) or nil
  elseif DECK_MOD_ECON[key] then
    return 0
  elseif key == "j_invisible" then
    -- Invisible's shop value is the copy it will make from the CURRENT board (not owned yet -> self_idx nil).
    return Eval.invisible_copy_jp(gs, nil, opts) / JP_PER_FRAC
  elseif key == "j_ring_master" then
    return Eval.showman_jp(gs, opts) / JP_PER_FRAC
  elseif Eval.UTILITY_MODELLED[key] then
    local uf = Eval.utility_fraction(gs, key, opts, false)
    if uf then return uf end
  end
  local dmj = deck_modifier_jp(gs, key, opts)
  return dmj and (dmj / JP_PER_FRAC) or nil
end

-- joker_power units from a measured marginal `m` (raw score the joker adds), or
-- the tier prior when `m` is nil (no deck / no scoring model). Measured value is
-- normalised to a boss-hand fraction and scaled onto the joker_power scale, then
-- floored by a fraction of the tier prior so a held/retrigger joker the greedy
-- sampler suppresses (Mime, Baron, Steel) is never valued at ~0. Scaling jokers
-- are projected forward either way -- condition-locked scalers gated by how often
-- their trigger hand appears (only those sample frequencies). Returns (jp, measured?).
-- MEASURED, NOT FLOORED (R12, 2026-09-24, live seed Y1U5TZWJ). The tier floor (0.6 x prior, 0.9 for
-- retrigger/Steel) was a guard against a measurement that could not SEE held-card and retrigger effects:
-- the shop scored nothing as held (fixed 7874b55), so Mime/Baron/Steel read 0 on every deck. With that
-- fixed the measurement is right -- Mime reads 0.00 on a deck with no held effects and 1.65 / 4.6 / 21
-- boss-hand fractions with 3 / 6 / 10 Steel cards -- and the floor only INFLATED jokers doing nothing:
-- a Mime with nothing to retrigger was priced at 1.62 (the board's highest), bought at ante 1, and kept
-- all run while measured offers could never beat the floored board. So a joker whose effect HandEval
-- models is valued at its measurement; a low reading is re-measured with more samples (noise, not a
-- floor, is the answer to an under-sampled conditional). The floor stays ONLY where the per-hand shop
-- measurement is structurally blind: scalers (value is future accrual; owned-core sell protection) and
-- Dusk (fires on the last hand only, which the shop sample never plays).
Eval.REFINE_SAMPLES = 24
-- the forward/projection measurements (projected deck, levels, per-card jokers) run at half the refine samples and
-- use the top of the per-card mix only: they are averaged with the present value, and at 24 samples x 11 per-card
-- jokers they were 80% of an 8-10 s shop decision (profiled on the Y1U5TZWJ late shops).
Eval.FWD_SAMPLES = 12
Eval.PERCARD_TOP = 6
function Eval.floor_free(key)
  local e = JokerData.resolve(key)
  if JokerData.is_scaling(key) or e.inc or e.feed_fuel or e.reset_on or e.deck_buff then return false end
  if key == "j_dusk" then return false end
  return true
end
-- ⚠ SIM VERDICT (r12, paired n=160 vs risk_after): dropping the floor for EVERY modelled joker cost wins
-- 28 -> 15 (sign 64/84). The floor also sets the SCALE of measured jokers against the tier-PRIOR ones
-- (Drunkard/Credit Card/Burnt keep their full prior): without it the engine bought Drunkard 23x and cut
-- Hanging Chad 27 -> 17, and sold held-card scorers (Shoot the Moon 12x) that measure low on a thin board.
-- So the floor stays for any joker that FIRES; it is dropped only for a joker measured to do NOTHING on
-- this deck (a Mime with no held effect to retrigger, a suit joker whose suit is absent): m == 0 on every
-- paired sample, after the refine re-measure -- the Y1U5TZWJ case, and nothing broader.
Eval.NO_TIER_FLOOR = os.getenv and os.getenv("BES_NO_TIER_FLOOR") == "1"   -- A/B switch: floor-free for all modelled jokers
-- A hand-conditional xmult (Duo/Trio/Family/Order/Tribe) whose trigger hand this RUN has already played is not
-- inert, whatever the samples read (2026-10-01, live DZHHCFQ1 a6: The Family played two Four of a Kinds -- 133733
-- and 72816, the second a clear only with its x4 -- then measured 0 on 6 undug deals, lost its floor as "inert"
-- and was sold as "contributes almost nothing"; the run died at the next Big blind at 95%. The buy side had priced
-- it at its floor, ~144% of a boss hand, a few minutes earlier: the same joker flipped on sampling noise.)
function Eval.trigger_played(gs, key)
  local cx = COND_XMULT[key]
  local plays = cx and gs and gs.run and gs.run.hand_type_plays
  if not plays then return false end
  for ht in pairs(CONTAINS_TRIGGER[cx.trigger]) do
    if (plays[ht] or 0) > 0 then return true end
  end
  return false
end
-- `gs` (optional): with it, a conditional xmult whose trigger was played this run is never inert.
function Eval.is_inert(key, m, gs)
  if gs and Eval.trigger_played(gs, key) then return false end
  if Eval.NO_TIER_FLOOR then return Eval.floor_free(key) and m ~= nil end
  return Eval.floor_free(key) and m ~= nil and m <= 1e-9
end
function Eval.tier_floor_frac(key)
  local f = (JokerData.has_tag(key, "retrigger") or JokerData.has_tag(key, "enh:steel")) and 0.9 or 0.6
  return f * (JokerData.resolve(key).tier or 3) * 0.3
end
-- m: a score_delta already taken on ctx_gs at opts.samples. Returns m, re-measured at REFINE_SAMPLES
-- when it reads below the old floor for a floor-free joker (only then: the cost lands on the jokers
-- whose low reading now decides their value).
function Eval.refine_measure(ctx_gs, j, m, opts)
  opts = opts or {}
  if not m or not Eval.floor_free(j.key) or (opts.samples or 6) >= Eval.REFINE_SAMPLES then return m end
  if m / Mechanics.boss_per_hand_need(ctx_gs) >= Eval.tier_floor_frac(j.key) then return m end
  local m2 = JokerValue.score_delta(ctx_gs, j, { samples = Eval.REFINE_SAMPLES, rng = opts.rng, cache = opts.cache })
  return m2 or m
end

Eval.conditional_xmult_marginal = conditional_xmult_marginal

-- A plain flat scorer: its whole value is the +Mult/+Chips it scores now (no scaling, no money, no downside).
function Eval.is_plain_flat(key)
  local d = JokerData.resolve(key)
  return (d.cat == "flat_mult" or d.cat == "flat_chips") and not JokerData.is_scaling(key)
    and not JokerData.is_unmodelled(key) and (d.econ or 0) == 0 and not Downside.has_downside(key)
end

local function jp_from_measure(gs, key, edition, m, opts, owned)
  local e = JokerData.resolve(key)
  -- DECK-BUFF scaler (Hiker): no joker counter, no scoring model, so m is always nil -- value it MEASURED
  -- via its deck-buff spu (before the tier fallback) and skip the tier floor, like the other scalers.
  if e.deck_buff then
    local sm = deck_buff_scaler_marginal(gs, key, opts)
    if sm then
      return (sm / Mechanics.boss_per_hand_need(gs)) * JP_PER_FRAC + edition_jp(edition, false), true
    end
  end
  -- DECK-MODIFIER jokers (Task 2): value them off their real channel, not the tier floor.
  -- Econ-channel (Midas/Certificate): scoring jp ~0 -- their money is added via Eval.econ_value.
  if DECK_MOD_ECON[key] then
    return edition_jp(edition, false), true
  end
  -- money-only joker: no phantom scoring value (its money is added once, in jp_to_fv)
  if Eval.is_money_only(key) then
    return edition_jp(edition, true), true
  end
  -- Deck-growth (Marble/DNA): MEASURED via card_add_value; nil on the cheap/no-deck path -> tier floor.
  local dmj = deck_modifier_jp(gs, key, opts)
  if dmj then
    return dmj + edition_jp(edition, false), true
  end
  if Eval.UTILITY_MODELLED[key] and not m then
    local uf = Eval.utility_fraction(gs, key, opts, owned, opts and opts._idx)
    if uf then return uf * JP_PER_FRAC + edition_jp(edition, false), true end
  end
  local freq = JokerData.scale_trigger_hands(key) and hand_freq(gs, opts) or nil
  local proj = Eval.scaling_projection(gs, key, freq)
  if not m then
    -- A GENERATOR reaches this branch because it has no scoring model of its own, and the tier
    -- prior it falls back to silently ASSUMES its output lands. Scale it by how much actually can
    -- (Generators.output_fit, the same convention pack_open_advisor's gen_fit already uses).
    -- Without this, a Riff-Raff on a full board -- structurally incapable of ever spawning -- kept
    -- the full prior of tier 6 x 0.5 = 3.000, which outranked the board's ONLY unconditional Mult
    -- at 1.800 and made that Mult the cheapest thing to sell. ADVICE_REVIEW R8, where exactly that
    -- happened and cost the run at the ante-4 boss. Identity (x1) for every non-generator.
    local fit = Generators.output_fit(gs, key, owned) * Generators.fire_rate(gs, key)
    return (e.tier or 3) * 0.5 * proj * fit + edition_jp(edition, true), false
  end
  -- RESETTING scaler (Ride the Bus): a fresh one measures 0, so the tier FLOOR used to decide its value
  -- (tier 7 -> priced above Runner). Instead value it MEASURED at its low geometric equilibrium and skip
  -- the tier floor entirely. No proj: a reset-on-miss counter is steady at equilibrium, not accumulating.
  -- (First piece of the measured-scaler system; accumulating scalers still use the proj+floor path below.)
  if e.reset_on then
    local sm = scaler_marginal(gs, key, opts)
    if sm then
      return (sm / Mechanics.boss_per_hand_need(gs)) * JP_PER_FRAC + edition_jp(edition, false), true
    end
  end
  -- ACCUMULATING joker-counter scaler (Runner/Square/Supernova/Green): value it MEASURED at its projected
  -- accrual, not the tier floor.
  if e.inc then
    local sm = accumulating_scaler_marginal(gs, key, opts)
    if sm then
      return (sm / Mechanics.boss_per_hand_need(gs)) * JP_PER_FRAC + edition_jp(edition, false), true
    end
  end
  -- EVENT-FED scaler (Constellation, Castle, Vampire, Campfire, ...), BUY side only: value = deck/resource-
  -- aware forward accrual + the fresh joker's measured ~0. No tier floor -- this is what stops over-buying a
  -- scaler that can never be fed (the R5 non-planet Constellation trap). The OWNED/sell side (owned=true)
  -- deliberately does NOT take this path: an owned scaling core measures LOW on a still-weak board (nothing
  -- to multiply YET), and dropping its tier floor here made it the most-disposable joker -- the engine
  -- dumped its own committed Constellation (corpus seed Z9PBGTL2). Sell-side core protection is a SEPARATE,
  -- endorsed concern (BP.CORE_KEEP / the tier floor as a FLOOR), so an owned one falls through to the
  -- measured+floor path below and keeps its protection.
  if e.feed_fuel and not owned then
    local fwd = event_fed_forward(gs, key, opts)
    if fwd then
      local frac = (m + fwd) / Mechanics.boss_per_hand_need(gs)
      return frac * JP_PER_FRAC + edition_jp(edition, false), true
    end
  end
  -- Analytic floor for hand-conditional xmults: the noisy 6-sample delta reads ~0 when the
  -- trigger hand is rare in-sample, so the engine skips a core that multiplies every trigger
  -- hand it plays. Take the HIGHER of measured and P(trigger)*(X-1)*base (an xmult never
  -- reduces score, so max, not blend, is safe and only lifts values the noise suppressed).
  local an = conditional_xmult_marginal(gs, key, opts, owned)
  if an and an > m then m = an end
  local frac = m / Mechanics.boss_per_hand_need(gs)
  -- the floor protects jokers whose value a sampled delta under-reads (held / conditional / growing ones). A PLAIN
  -- flat scorer is measured completely, so when the caller is choosing WHICH owned joker to give up in a trade
  -- (opts.plain_unfloored) its measured score stands (2026-10-05, owner on live UAPB3XY9 flag 4b: Walkie Talkie,
  -- measured ~450 a hand, was floored to 1.80 FV and kept while Gros Michel, ~1900 a hand, was sold).
  local unfloored = owned and opts and opts.plain_unfloored and Eval.is_plain_flat(key)
  if not unfloored and not Eval.is_inert(key, m, gs) then frac = math.max(frac, Eval.tier_floor_frac(key)) end
  -- measured path: foil/holo/poly already in the delta, add only the slot
  return frac * JP_PER_FRAC * proj + edition_jp(edition, false), true
end

local function can_measure(gs, opts)
  if opts.measure == false then return false end
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  return deck and #deck >= JokerValue.MIN_DECK
end

-- RETRIGGER FORWARD VALUE (2026-09-25). A retrigger (Hanging Chad, Sock and Buskin, Hack, Seltzer, Mime) is worth
-- what the cards it retriggers carry -- and decks GAIN enhanced / sealed / edition cards as the run goes, which the
-- present-deck measurement cannot see (the same blind spot that keeps the tier floor on scalers). MEASURED growth,
-- from every recorded live deck (bes_fixtures.jsonl shop states, per ante): enhanced 0 / 0.6 / 2.4 / 3.4 / 7.9 /
-- 10.3 / 11.4 / 14.4 cards at antes 1-8, seals 0 -> 4.7, editions 0 -> 2.7; mix (ante >= 4) Gold .385, Lucky .262,
-- Mult .106, Bonus .081, Wild .054, Stone .048, Glass .034, Steel .029; seals Purple .383, Gold .296, Blue .174,
-- Red .148; editions foil .562, holo .391, polychrome .047. A retrigger is valued on the deck PROJECTED to the
-- midpoint of the remaining run (its average over the horizon, like a scaler's ramp) -- the current deck plus the
-- typical gain between now and then, applied to plain cards in the measured mix, deterministically.
Eval.PERCARD_GROWTH = { 0, 0.45, 0.91, 1.0, 1.1, 1.4, 1.7, 1.6 }   -- per-card jokers on the board, antes 1-8 (live)
Eval.PERCARD_MIX = { { "j_photograph", .202 }, { "j_scary_face", .182 }, { "j_business", .162 }, { "j_scholar", .141 },
  { "j_smiley", .101 }, { "j_even_steven", .071 }, { "j_greedy_joker", .071 }, { "j_fibonacci", .030 },
  { "j_lusty_joker", .020 }, { "j_odd_todd", .010 }, { "j_wrathful_joker", .010 } }
Eval.PERCARD = {}
for _, e in ipairs(Eval.PERCARD_MIX) do Eval.PERCARD[e[1]] = true end
for _, k in ipairs({ "j_gluttonous_joker", "j_gluttenous_joker", "j_arrowhead", "j_onyx_agate", "j_rough_gem",
  "j_bloodstone", "j_ancient", "j_idol", "j_walkie_talkie", "j_triboulet" }) do Eval.PERCARD[k] = true end
Eval.DECK_GROWTH = { -- per ante: { enhanced, sealed, edition }
  { 0, 0, 0 }, { 0.6, 0, 0 }, { 2.4, 0.2, 0 }, { 3.4, 0.7, 0.35 },
  { 7.9, 1.9, 0.9 }, { 10.3, 2.6, 1.3 }, { 11.4, 3.6, 2.4 }, { 14.4, 4.7, 2.7 } }
Eval.ENH_MIX  = { { "m_gold", .385 }, { "m_lucky", .262 }, { "m_mult", .106 }, { "m_bonus", .081 },
                  { "m_wild", .054 }, { "m_stone", .048 }, { "m_glass", .034 }, { "m_steel", .029 } }
Eval.SEAL_MIX = { { "Purple", .383 }, { "Gold", .296 }, { "Blue", .174 }, { "Red", .148 } }
Eval.ED_MIX   = { { "foil", .562 }, { "holo", .391 }, { "polychrome", .047 } }
local function growth_at(a)
  local lo = math.max(1, math.min(8, math.floor(a)))
  local hi = math.min(8, lo + 1)
  local t = a - lo
  local g1, g2 = Eval.DECK_GROWTH[lo], Eval.DECK_GROWTH[hi]
  return g1[1] + t * (g2[1] - g1[1]), g1[2] + t * (g2[2] - g1[2]), g1[3] + t * (g2[3] - g1[3])
end
-- n items spread over a mix by largest remainder (deterministic, no RNG)
local function spread(mix, n)
  local out, rems, used = {}, {}, 0
  for i, e in ipairs(mix) do
    local x = e[2] * n
    out[i] = math.floor(x); used = used + out[i]; rems[#rems + 1] = { i = i, r = x - out[i] }
  end
  table.sort(rems, function(a, b) if a.r ~= b.r then return a.r > b.r end return a.i < b.i end)
  for k = 1, math.min(#rems, math.max(0, n - used)) do out[rems[k].i] = out[rems[k].i] + 1 end
  local list = {}
  for i, e in ipairs(mix) do for _ = 1, out[i] do list[#list + 1] = e[1] end end
  return list
end
function Eval.projected_deck(gs, target_ante)
  local ante = (gs.meta and gs.meta.ante) or 1
  local e0, s0, d0 = growth_at(ante)
  local e1, s1, d1 = growth_at(target_ante)
  local ne, ns, nd = math.floor(e1 - e0 + 0.5), math.floor(s1 - s0 + 0.5), math.floor(d1 - d0 + 0.5)
  local deck = {}
  for i, c in ipairs(gs.deck or {}) do local x = {}; for k, v in pairs(c) do x[k] = v end; deck[i] = x end
  if ne + ns + nd <= 0 then return deck end
  -- plain cards, in a fixed order (by id) spread evenly across the deck
  local plain = {}
  for _, c in ipairs(deck) do if not c.enhancement then plain[#plain + 1] = c end end
  table.sort(plain, function(a, b) return (a.id or 0) < (b.id or 0) end)
  local function pick(k, n) return plain[math.floor((k - 1) * #plain / math.max(1, n)) + 1] end
  for k, enh in ipairs(spread(Eval.ENH_MIX, ne)) do local c = pick(k, ne); if c then c.enhancement = enh end end
  local unsealed = {}
  for _, c in ipairs(deck) do if not c.seal then unsealed[#unsealed + 1] = c end end
  for k, sl in ipairs(spread(Eval.SEAL_MIX, ns)) do
    local c = unsealed[math.floor((k - 1) * #unsealed / math.max(1, ns)) + 1]; if c then c.seal = sl end
  end
  local plain_ed = {}
  for _, c in ipairs(deck) do if not c.edition then plain_ed[#plain_ed + 1] = c end end
  for k, ed in ipairs(spread(Eval.ED_MIX, nd)) do
    local c = plain_ed[#plain_ed - math.floor((k - 1) * #plain_ed / math.max(1, nd))]; if c then c.edition = ed end
  end
  return deck
end
-- m (measured on ctx_gs) -> the retrigger's value at the midpoint of the remaining run. Identity for anything else.
-- FORWARD VALUE FOR EVERY JOKER (2026-09-25, experiment, BES_FWD_ALL=1). Boards fill to ~5 jokers by ante 3 (live:
-- 0 / 2.1 / 4.3 / 4.7 / 4.8 / 5.1 / 5.1 / 5.3), so after that a board grows through its DECK (projected_deck) and
-- its HAND LEVELS -- MEASURED on all live shop states, extra levels total 0 / .17 / 1.26 / 3.0 / 6.7 / 10.5 / 16.7 /
-- 18.3 at antes 1-8, about half on the most-played hand. Every joker is valued as the average of its share of the
-- boss per-hand need NOW and at the run's midpoint, the latter measured on the SAME board with the projected deck and
-- levels against the midpoint need. Same unit at both ends, same treatment for every joker -- unlike the rejected
-- xmult-only scaling (x1), which inflated one class against the rest.
-- ON by default since 2026-09-25: z1 vs y1 +0.108 (sign 77/59, reach-7 +11), replicated out of sample (BES_SEED_OFF=7:
-- +0.098, sign 68/64, wins 26 -> 32, reach-7 +7); pooled ~+0.10 over 320 pairs, never negative. BES_FWD_ALL=0 disables.
Eval.FWD_ALL = not (os.getenv and os.getenv("BES_FWD_ALL") == "0")
Eval.LEVEL_GROWTH = { 0, 0.17, 1.26, 3.0, 6.7, 10.5, 16.7, 18.3 }
Eval.TOP_HAND_LEVEL_SHARE = 0.5
local function interp_ante(tbl, a)
  local lo = math.max(1, math.min(8, math.floor(a)))
  local hi = math.min(8, lo + 1)
  return tbl[lo] + (a - lo) * (tbl[hi] - tbl[lo])
end
function Eval.projected_levels(gs, target_ante, freq)
  local ante = (gs.meta and gs.meta.ante) or 1
  local add = math.max(0, interp_ante(Eval.LEVEL_GROWTH, target_ante) - interp_ante(Eval.LEVEL_GROWTH, ante))
  local lv = {}
  for k, v in pairs((gs.run and gs.run.hand_levels) or {}) do lv[k] = v end
  if add <= 0 or not freq then return lv end
  local top, topf, total = nil, -1, 0
  local names = {}
  for h, f in pairs(freq) do if Mechanics.HAND_PLANET[h] and f > 0 then names[#names + 1] = h; total = total + f end end
  table.sort(names)
  for _, h in ipairs(names) do if freq[h] > topf then top, topf = h, freq[h] end end
  if not top then return lv end
  local rest = total - topf
  for _, h in ipairs(names) do
    local k = (h == top) and (add * Eval.TOP_HAND_LEVEL_SHARE + ((rest <= 0) and add * (1 - Eval.TOP_HAND_LEVEL_SHARE) or 0))
      or ((rest > 0) and add * (1 - Eval.TOP_HAND_LEVEL_SHARE) * freq[h] / rest or 0)
    if k > 0 then
      local inc = Mechanics.HAND_PLANET[h]
      local cur = lv[h] or { level = 1, chips = inc.base_chips or 0, mult = inc.base_mult or 0 }
      lv[h] = { level = (cur.level or 1) + k, chips = (cur.chips or 0) + inc.dchips * k, mult = (cur.mult or 0) + inc.dmult * k }
    end
  end
  return lv
end
local function mid_need(gs, mid)
  local hands = (gs.blind and gs.blind.base_hands) or (gs.run and gs.run.base_hands) or 4
  if not hands or hands <= 0 then hands = 4 end
  local lo = math.max(1, math.min(8, math.floor(mid)))
  local hi = math.min(8, lo + 1)
  local a, b = Mechanics.blind_requirement(lo, "Boss"), Mechanics.blind_requirement(hi, "Boss")
  return math.max(1, (a + (mid - lo) * (b - a)) / hands)
end

-- LIMITED-LIFE jokers get NO forward projection: they will not be on the board for the deck/board the projection
-- values (sim r1 vs g1: Seltzer -- 10 hands of retriggers, then gone -- was bought 12 -> 18 once projected to the
-- run's midpoint deck).
Eval.LIMITED_LIFE = { j_selzer = true, j_ramen = true, j_ice_cream = true, j_popcorn = true, j_gros_michel = true,
                      j_turtle_bean = true }
function Eval.forward_measure(ctx_gs, j, m, opts)
  opts = opts or {}
  m = Eval.refine_measure(ctx_gs, j, m, opts)
  if Eval.LIMITED_LIFE[j.key] then return m end
  if Eval.FWD_ALL and m and Eval.floor_free(j.key) and not JokerData.has_tag(j.key, "retrigger")
     and can_measure(ctx_gs, opts) then
    local ante = (ctx_gs.meta and ctx_gs.meta.ante) or 1
    local mid = ante + (8 - ante) / 2
    if mid > ante then
      local cache = opts.cache
      local ckey = "_fwd_ctx|" .. tostring(ctx_gs.deck) .. "|" .. tostring(ctx_gs.jokers) .. "|" .. mid
      local fctx = cache and cache[ckey]
      if not fctx then
        local dkey = "_proj_deck|" .. tostring(ctx_gs.deck) .. "|" .. mid
        local pdeck = cache and cache[dkey]
        if not pdeck then pdeck = Eval.projected_deck(ctx_gs, mid); if cache then cache[dkey] = pdeck end end
        -- hand frequencies + the projected levels depend on the deck, not on which joker is being valued: one per
        -- decision (was recomputed for every leave-one-out board -- the bulk of an 8.7 s shop decision)
        local lkey = "_fwd_levels|" .. tostring(ctx_gs.deck) .. "|" .. mid
        local plevels = cache and cache[lkey]
        if not plevels then
          local freq = ConsumableValue.hand_frequencies(ctx_gs, { samples = 8, rng = opts.rng })
          plevels = Eval.projected_levels(ctx_gs, mid, freq)
          if cache then cache[lkey] = plevels end
        end
        fctx = {}
        for k, v in pairs(ctx_gs) do fctx[k] = v end
        fctx.deck = pdeck
        local run = {}
        for k, v in pairs(ctx_gs.run or {}) do run[k] = v end
        run.hand_levels = plevels
        fctx.run = run
        if cache then cache[ckey] = fctx end
      end
      local mf = JokerValue.score_delta(fctx, j, { samples = Eval.FWD_SAMPLES, rng = opts.rng, cache = cache })
      -- ANCHORED to a plain Joker (+4 Mult) measured in the same two contexts: the projection keeps the CURRENT
      -- jokers while real boards also upgrade them, so raw mid-run shares deflate EVERY joker against money/packs
      -- (Half Joker 5.07 -> 2.77 FV on a replayed ante-2 board). Only the RELATIVE growth is used: a joker whose
      -- share holds up better than +Mult's (a multiplier) gains, one that dilutes faster (+Chips) loses, and the
      -- joker-vs-money scale is unchanged.
      local rkey = "_fwd_ref|" .. tostring(ctx_gs.deck) .. "|" .. mid   -- one reference per decision (board-insensitive enough)
      local ref = cache and cache[rkey]
      if ref == nil then
        local pj = { key = "j_joker", ability = { extra = {} } }
        local r0 = JokerValue.score_delta(ctx_gs, pj, { samples = Eval.FWD_SAMPLES, rng = opts.rng, cache = cache })
        local r1 = JokerValue.score_delta(fctx, pj, { samples = Eval.FWD_SAMPLES, rng = opts.rng, cache = cache })
        ref = (r0 and r1 and r0 > 0) and (r1 / r0) or false
        if cache then cache[rkey] = ref end
      end
      if mf and ref and m > 0 then
        local rel = (mf / m) / ref                      -- this joker's growth relative to +Mult's
        m = m * (0.5 + 0.5 * math.max(0, math.min(3, rel)))
      end
    end
    return m
  end
  if m and m > 0 and JokerData.is_xmult(j.key) then
    -- scale by the board the xmult will multiply (ctx_gs = the board it joins / the rest of the board)
    local ro = { rng = opts.rng, samples = opts.samples, cache = nil }
    m = m * Eval.xmult_forward_scale(ctx_gs, j.key, ro)
  end
  if not m or not JokerData.has_tag(j.key, "retrigger") or not Eval.floor_free(j.key) then return m end
  if not can_measure(ctx_gs, opts) then return m end
  local ante = (ctx_gs.meta and ctx_gs.meta.ante) or 1
  local mid = ante + (8 - ante) / 2
  if mid <= ante then return m end
  local cache = opts.cache
  local dkey = "_proj_deck|" .. tostring(ctx_gs.deck) .. "|" .. mid
  local pdeck = cache and cache[dkey]
  if not pdeck then pdeck = Eval.projected_deck(ctx_gs, mid); if cache then cache[dkey] = pdeck end end
  local pgs = {}
  for k, v in pairs(ctx_gs) do pgs[k] = v end
  pgs.deck = pdeck
  local m2 = JokerValue.score_delta(pgs, j, { samples = Eval.FWD_SAMPLES, rng = opts.rng, cache = cache }) or m
  -- PROJECTED BOARD (owner 2026-09-25: "retriggers can be very good together with jokers that use them -- taking
  -- Hanging Chad with the possibility in the future to get Photograph or Business Card or Scholar"). A retrigger
  -- fires every PER-CARD joker again, and boards GAIN per-card jokers: MEASURED on all live shop states, the count
  -- on the board is 0 / 0.45 / 0.91 / 1.0 / 1.1 / 1.4 / 1.7 / 1.6 at antes 1-8, and which ones (PERCARD_MIX) is
  -- Photograph .202, Scary Face .182, Business Card .162, Scholar .141, Smiley .101, Even Steven .071, Greedy .071,
  -- Fibonacci .030, Lusty .020, Odd Todd .010, Wrathful .010. So the retrigger is also measured with each likely
  -- per-card joker added (weighted by that mix) and credited for the expected number the board will have gained
  -- by the run's midpoint. Business Card's payout is MONEY, which score_delta does not see -- it adds 0 here.
  local have = 0
  for _, oj in ipairs(pgs.jokers or {}) do if Eval.PERCARD[oj.key] then have = have + 1 end end
  local lo = math.max(1, math.min(8, math.floor(mid)))
  local t = mid - lo
  local want = Eval.PERCARD_GROWTH[lo] + t * (Eval.PERCARD_GROWTH[math.min(8, lo + 1)] - Eval.PERCARD_GROWTH[lo])
  local n_add = math.min(2, math.max(0, want - have))
  if n_add > 0 then
    local sum, wsum = 0, 0
    for ei, e in ipairs(Eval.PERCARD_MIX) do
      if ei > Eval.PERCARD_TOP then break end   -- the top 6 of the mix carry ~87% of its weight
      local mk = m2
      if e[1] ~= "j_business" then
        local g2 = {}
        for k, v in pairs(pgs) do g2[k] = v end
        local js = {}
        for i, oj in ipairs(pgs.jokers or {}) do js[i] = oj end
        js[#js + 1] = { key = e[1], ability = { extra = {} } }
        g2.jokers = js
        mk = JokerValue.score_delta(g2, j, { samples = Eval.FWD_SAMPLES, rng = opts.rng, cache = cache }) or m2
      end
      sum = sum + e[2] * mk; wsum = wsum + e[2]
    end
    m2 = m2 + n_add * (sum / wsum - m2)
  end
  return math.max(m, m2)   -- a projected deck/board only ADDS retrigger targets; noise must not cut the present
end

-- Does owned joker idx change the score AT ALL on this deck? (R12 -- the input to BP.keep_bias.) A
-- retrigger with nothing to retrigger / an xmult whose condition the deck never meets reads exactly 0 on
-- every paired sample; one that works on a weak board reads small but POSITIVE. nil when the measurement
-- is structurally blind (scalers, Dusk -- Eval.floor_free) or unavailable (no deck / value-only joker),
-- so the caller keeps the category bias. Uses the recommend-scoped cache, so it is ~free after joker_jp.
function Eval.joker_fires(gs, idx, opts)
  opts = opts or {}
  local j = (gs.jokers or {})[idx]
  if not j or not Eval.floor_free(j.key) or not can_measure(gs, opts) then return nil end
  local rest = {}
  for k, jj in ipairs(gs.jokers) do if k ~= idx then rest[#rest + 1] = jj end end
  local without = {}
  for k, v in pairs(gs) do without[k] = v end
  without.jokers = rest
  local m = JokerValue.score_delta(without, j, { samples = opts.samples or 6, rng = opts.rng, cache = opts.cache })
  if m == nil then return nil end
  m = Eval.refine_measure(without, j, m, opts)   -- a rare trigger must not read as "does nothing"
  return m > 1e-9 or Eval.trigger_played(gs, j.key)
end


local INVISIBLE_DELAY_DAMP = 0.75   -- 3-round wait before you can sell-to-copy (dead weight meanwhile)
-- Invisible Joker: after 3 rounds, SELL it to DUPLICATE a random OTHER owned joker (the copy inherits the
-- joker's CURRENT state -- scaling counters included -- and lands in Invisible's own freed slot, so no extra
-- slot is needed). Its value is therefore the value of the joker it will copy. The pick is RANDOM, but you
-- shed weak jokers first to bias it toward your best, so blend the board mean with the best (lean best).
-- Because each candidate is valued via joker_jp (measured, deck-aware), copying a SCALED joker is priced at
-- its scaled worth automatically -- the owner's question. ~0 with no board worth copying; strong when the
-- build already has strong jokers. `self_idx` excludes the owned Invisible itself (nil on the shop-BUY path,
-- where the whole current board is the copy pool). Damped for the 3-round delay it sits idle.
function Eval.invisible_copy_jp(gs, self_idx, opts)
  local jokers = gs.jokers or {}
  local vals = {}
  for i, j in ipairs(jokers) do
    if i ~= self_idx and j.key ~= "j_invisible" and not JokerData.is_unmodelled(j.key) then
      local v = Eval.joker_jp(gs, i, opts)
      if v and v > 0 then vals[#vals + 1] = v end
    end
  end
  if #vals == 0 then return 0 end
  table.sort(vals, function(a, b) return a > b end)
  local best, sum = vals[1], 0
  for _, v in ipairs(vals) do sum = sum + v end
  return (0.4 * (sum / #vals) + 0.6 * best) * INVISIBLE_DELAY_DAMP
end

-- Showman (game key j_ring_master): lets DUPLICATE jokers/cards/planets/tarots appear in shops+packs. Value
-- = the flat utility of "duplicates can show up" (base prior) PLUS how worth-duplicating the current board
-- is -- but heavily damped vs Invisible, because Showman only lets a duplicate APPEAR; you still have to
-- find AND buy it yourself. Owner: ~2 base, higher when the build already has strong jokers worth doubling.
local SHOWMAN_BEST_FRAC = 0.25
function Eval.showman_jp(gs, opts)
  local base = (JokerData.resolve("j_ring_master").tier or 2) * 0.5
  local best = 0
  for i, j in ipairs(gs.jokers or {}) do
    if j.key ~= "j_ring_master" and not JokerData.is_unmodelled(j.key) then
      local v = Eval.joker_jp(gs, i, opts)
      if v and v > best then best = v end
    end
  end
  return base + SHOWMAN_BEST_FRAC * best
end

-- joker_power units for ONE owned joker, measured against the deck where possible:
-- its marginal score added back to the rest of the board (paired sampling). Falls
-- back to the tier prior with no deck. Returns (jp, measured?).
function Eval.joker_jp(gs, idx, opts)
  opts = opts or {}
  local j = (gs.jokers or {})[idx]
  if not j then return 0, false end
  -- Invisible Joker has no scoring model -- its worth is the joker it will DUPLICATE (see invisible_copy_jp),
  -- not its tier prior. Value it off the current board, not the flat floor.
  if j.key == "j_invisible" then return Eval.invisible_copy_jp(gs, idx, opts), true end
  if j.key == "j_ring_master" then return Eval.showman_jp(gs, opts), true end
  local m
  if can_measure(gs, opts) then
    local rest = {}
    for k, jj in ipairs(gs.jokers) do if k ~= idx then rest[#rest + 1] = jj end end
    local without = {}
    for k, v in pairs(gs) do without[k] = v end
    without.jokers = rest
    m = JokerValue.score_delta(without, j,
      { samples = opts.samples or 6, rng = opts.rng, cache = opts.cache })
    m = Eval.forward_measure(without, j, m, opts)
    if m == nil then
      -- j has no scoring model of its own (e.g. value-only Oops! All 6s), so its
      -- worth normally falls back to the tier prior. But REMOVING it can still
      -- change the board score via CROSS-joker synergy -- the signature case being
      -- a freed slot raising Joker Stencil's xmult (+1 per empty slot). If removing
      -- it measurably RAISES the board score, keeping it is a net DRAG, so return
      -- that negative marginal directly (NOT via jp_from_measure, whose prior floor
      -- would erase it). A near-zero/positive delta means "unmodelled, value
      -- unknown" -> keep the conservative tier prior below.
      local bd = JokerValue.remove_delta(gs, idx, { samples = opts.samples or 6, rng = opts.rng })
      if bd and bd < -1e-9 then
        return (bd / Mechanics.boss_per_hand_need(gs)) * JP_PER_FRAC, true
      end
    end
  end
  if Eval.UTILITY_MODELLED[j.key] then
    local o = {}; for k, v in pairs(opts) do o[k] = v end; o._idx = idx
    opts = o
  end
  return jp_from_measure(gs, j.key, j.edition, m, opts, true)   -- owned: sell-side marginal
end

-- Measured board joker_power = sum of per-joker measured jp. Returns nil when
-- there's no deck to sample against, so joker_power falls back to the tier sum.
function Eval.measured_joker_power(gs, opts)
  local jokers = gs.jokers or {}
  if #jokers == 0 then return 0 end
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < JokerValue.MIN_DECK then return nil end
  local s = 0
  for i = 1, #jokers do s = s + (Eval.joker_jp(gs, i, opts)) end
  return s
end

-- Joker power: MEASURED against the deck when one is present (deck-aware, the
-- KEY PRINCIPLE), else each joker contributes by its data tier + editions. Pass
-- opts.measure=false to force the cheap tier path. opts: {rng, cache, samples}.
function Eval.joker_power(gs, opts)
  opts = opts or {}
  if opts.measure ~= false then
    local mp = Eval.measured_joker_power(gs, opts)
    if mp ~= nil then return mp end
  end
  local s = 0
  for _, j in ipairs(gs.jokers or {}) do
    local e = JokerData.resolve(j.key)
    -- scaling jokers are projected forward (worth far more late); flat jokers
    -- have projection 1.0, so this is a no-op for them.
    s = s + (e.tier or 3) * 0.5 * Eval.scaling_projection(gs, j.key)
    s = s + edition_jp(j.edition, true)
  end
  return s
end

-- MONEY WEIGHT BY ANTE (2026-10-03). A joker's income was priced at a flat 0.8 FV per \$/round at every ante. But an
-- income only pays for the rounds LEFT, and a late dollar buys less (VU.dollar_frac falls along the requirement curve),
-- while a scorer's FV is needed in full at every remaining blind. So the money term is scaled by rounds left x dollar
-- rate, relative to the ante the 0.8 was calibrated around (VU.REF_ANTE), and never raised (early money unchanged):
-- ante <=3 1.00, 4 0.73, 5 0.52, 6 0.35, 7 0.22, 8 0.10. Arm pt (wins 35 -> 17) showed the flat rate letting \$/round
-- outweigh real scoring late.
-- ⚠ OPT-IN (sim verdict 2026-10-03, arm mw vs bn2, n=160): progress +0.070 (p 0.40), sign 39/37, reach-8 60 -> 62,
-- wins 43 -> 38 -- no positive evidence for a magnitude change, so the flat rate stays the default. BES_MONEY_ANTE=1.
Eval.MONEY_LAST_ANTE = 8
-- FV points per \$/round of joker income. 0.8 FV = 0.32 boss-hand fraction = 1.6 shop utility, while the shop BUYS that
-- same income at VU.ROUND_INCOME_UTIL = 1.0 utility (2026-10-06 unit audit) -- so a money joker was worth 1.6x more to keep
-- than to buy, and in a trade its income outweighed a scorer at that rate (memory: paired trades went 35 -> 17 wins on
-- this scale). Priced at the buy rate (0.5 FV) since 2026-10-07: arms u4 vs u1 +0.206 (p 0.008), fresh seeds +0.033,
-- pooled n=320 +0.119 (p 0.075), wins 88 -> 90, reach-8 118 -> 127. BES_ECON_FV=0 restores the old 0.8.
Eval.ECON_FV = (os.getenv and os.getenv("BES_ECON_FV") == "0") and 0.8
  or (VU.ROUND_INCOME_UTIL / VU.FRAC_UTIL * VU.FV_PER_FRAC)
function Eval.money_weight(gs)
  if not (_G.BES_MONEY_ANTE or (os.getenv and os.getenv("BES_MONEY_ANTE") == "1")) then return 1 end
  local ante = math.floor((gs and gs.meta and gs.meta.ante) or 1)
  if ante <= VU.REF_ANTE then return 1 end
  local left = math.max(1, Eval.MONEY_LAST_ANTE + 1 - ante)
  local ref_left = Eval.MONEY_LAST_ANTE + 1 - VU.REF_ANTE
  local rate = VU.dollar_frac(gs) / VU.dollar_frac({ meta = { ante = VU.REF_ANTE } })
  return math.min(1, (left / ref_left) * rate)
end

-- FV points from a joker's jp + its passive econ - its situational downside. `j`
-- is the real joker (so stickers/ability inform the downside); idx is its board
-- position or nil for a not-yet-placed shop joker.
local function jp_to_fv(gs, j, jp, idx, measured)
  -- Eval.econ_value, NOT the raw catalogue number. This line read the flat prior, which meant
  -- the deck-aware econ model (Rough Gem by diamond density, Business Card and Reserved
  -- Parking by face density, Cloud 9 by nines) had NEVER reached the buy or sell decision --
  -- it only ever informed spending headroom and run_strength. So a Rough Gem was priced
  -- identically on a 4-diamond deck and a 20-diamond one. It also routes the Oops! All 6s
  -- probability multiplier through, so a money joker is worth more once Oops is on the board.
  local econ = Eval.joker_money(gs, j.key)
  -- a MEASURED resource joker already has its hands/discards/hand-size trade-off inside jp (Eval.utility_fraction);
  -- don't charge the flat resource downside a second time (the anti-synergies it can't see are still charged)
  local dopts = (measured and Eval.UTILITY_MODELLED[j.key]) and { resource_measured = true } or nil
  return FV_JOKER_WEIGHT * jp + Eval.ECON_FV * econ * Eval.money_weight(gs) - Downside.penalty(gs, j, idx, dopts)
end

-- FV-point marginal of OWNING joker idx (what selling it gives up). Measuring this
-- (vs the old tier delta) is what stops the advisor selling the joker actually
-- carrying your deck. Cross-joker downside terms (e.g. removing a strong joker
-- easing a Madness threat) are a second-order effect this per-joker marginal
-- omits. Returns (fv, measured?). opts: {rng, cache, samples, measure}.
function Eval.joker_marginal_fv(gs, idx, opts)
  local j = (gs.jokers or {})[idx]
  if not j then return 0, false end
  local jp, measured = Eval.joker_jp(gs, idx, opts)
  return jp_to_fv(gs, j, jp, idx, measured), measured
end

-- CAMPFIRE SALE (2026-10-01). Campfire gains x0.25 Mult per card sold and RESETS when a boss is beaten. The sell
-- path priced each sale at a flat 1.5 x the RUN-long scaling projection -- as if the gain were permanent -- which
-- out-valued any joker on the board, so the engine sold scorers one after another (live 4CKRM5N5 a5, at ~90% risk:
-- sold a Zany it had just bought, then Card Sharp, then Wily, and died to the Small blind by 149 chips with 3
-- jokers). Measured instead: +0.25 on a Campfire at X raises the board's score by 0.25/X of what one more x1.0
-- adds (unit_spu), and only for the blinds left before the next boss (k of the R blinds the sold joker's loss
-- lasts). 0 when the board can't be measured.
Eval.CAMPFIRE_BLINDS_LEFT = { Small = 3, Big = 2, Boss = 1 }
function Eval.campfire_sale_fv(gs, opts)
  local cf
  for _, j in ipairs(gs.jokers or {}) do if j.key == "j_campfire" then cf = j; break end end
  if not cf or not opts or not can_measure(gs, opts) then return 0 end
  local ab = type(cf.ability) == "table" and cf.ability or {}
  local x = math.max(1, tonumber(ab.x_mult) or tonumber(ab.Xmult) or 1)
  local need = Mechanics.boss_per_hand_need(gs)
  if not need or need <= 0 then return 0 end
  local raw = 0.25 * unit_spu(gs, "j_campfire", "xmult", opts) / x
  local k = Eval.CAMPFIRE_BLINDS_LEFT[(gs.blind or {}).blind_type or ""] or 2
  local r = math.max(k, Eval.blinds_remaining(gs))
  return VU.frac_to_fv(raw / need) * (k / r)
end

-- FV-point marginal of ADDING shop joker `sj` to the current board: one measured
-- score_delta (NOT a full board re-measure), so valuing a buy/upgrade is O(1) in
-- the board size. Falls back to the tier prior with no deck. opts as above.
-- The board after SELLING owned joker `i`: a shallow copy of gs whose joker list drops it.
function Eval.without_joker(gs, i)
  local g = {}
  for k, v in pairs(gs) do g[k] = v end
  local rest = {}
  for k, j in ipairs(gs.jokers or {}) do if k ~= i then rest[#rest + 1] = j end end
  g.jokers = rest
  return g
end

-- A full-board TRADE (sell owned joker `i`, take `sj`) is self-defeating when most of sj's measured gain comes from
-- the joker being sold: Mime retriggering Raised Fist, a copier copying it, Baron's Kings-in-hand partner... The
-- trade used to price sj on the board that still holds joker i. Live Z9ZPREGI a5 (2026-10-02) sold Raised Fist to
-- take Mime: Mime added ~4045 a hand with Raised Fist and ~118 without it, the board measured -19% after the
-- trade. Its FV could not show it -- both boards read Mime at its tier floor -- so this compares the MEASURED gain
-- on both boards: true when the gain without joker i is under half the gain with it. nil when unmeasurable.
Eval.TRADE_DEPENDENCE = 0.5
-- Its own stream, the SAME for both boards (paired hands), seeded from the pair: drawing from the caller's rng
-- would reshuffle every later Monte-Carlo sample of the decision (noise, and a cascade in a sim batch).
local function trade_rng(i, key)
  local s = 7919 * i + 104729
  for c in tostring(key):gmatch(".") do s = (s * 31 + c:byte()) % 2147483647 end
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end
function Eval.trade_leans_on(gs, i, sj, opts)
  if not (opts and opts.rng) or not can_measure(gs, opts) then return nil end
  local n = opts.samples or 6
  local with = JokerValue.score_delta(gs, sj, { samples = n, rng = trade_rng(i, sj.key) })
  if not with or with <= 0 then return nil end
  local without = JokerValue.score_delta(Eval.without_joker(gs, i), sj, { samples = n, rng = trade_rng(i, sj.key) })
  if not without then return nil end
  return without < Eval.TRADE_DEPENDENCE * with
end

function Eval.add_joker_marginal_fv(gs, sj, opts)
  opts = opts or {}
  local m
  if can_measure(gs, opts) then
    m = JokerValue.score_delta(gs, sj,
      { samples = opts.samples or 6, rng = opts.rng, cache = opts.cache })
    m = Eval.forward_measure(gs, sj, m, opts)
  end
  local jp, measured = jp_from_measure(gs, sj.key, sj.edition, m, opts, false)   -- shop: add-side marginal
  return jp_to_fv(gs, sj, jp, nil, measured)
end

-- Scoring value (boss-hand FRACTION) of PICKING a candidate joker `sj` from a pack, on the SAME
-- basis the shop uses: max(measured marginal, analytic conditional-xmult marginal, tier-prior
-- floor) / need. The pack-pick path used raw score_delta/need with NO floor, so a conditional
-- xmult (Trio/Tribe/...) whose 6-sample delta rarely hits its trigger hand read ~0 on a weak
-- board and a flat common out-ranked it -- a direct mechanism for "never assembles a core" on a
-- FREE, heavily-used channel. Mirrors jp_from_measure but in fraction units and WITHOUT the
-- edition term (the caller adds editions). Returns (frac, measured?); with no samplable deck /
-- rng it returns the prior floor (the cheap first-pass keeps its own prior). `need` should be
-- Mechanics.boss_per_hand_need(gs) (what the pack advisor already divides by).
function Eval.joker_pick_frac(gs, sj, need, opts)
  opts = opts or {}
  local key = sj.key
  local e = JokerData.resolve(key)
  local floor = Eval.tier_floor_frac(key)
  if not can_measure(gs, opts) then return floor, false end
  if Eval.UTILITY_MODELLED[key] then                        -- measured utility joker (Burnt, Drunkard, ...)
    local uf = Eval.utility_fraction(gs, key, opts, false)
    if uf then return uf, true end
  end
  -- MODELLED SCALERS / DECK-MODIFIERS (2026-10-04, live NSWJJKK8 flag 1, owner-confirmed: Splash taken over Hologram):
  -- the shop prices these through Eval.modeled_scoring_fraction (their projected growth), but a pack pick measured
  -- the joker's score TODAY -- 0 for a Hologram with nothing added yet -- and fell to the tier floor, so every
  -- scaling joker in a Buffoon pack was valued as if it never grew. Same basis as the shop buy (scoring_gain).
  local modeled = Eval.modeled_scoring_fraction(gs, key, opts)
  if modeled then return modeled, true end
  local m = JokerValue.score_delta(gs, sj, { samples = opts.samples or 6, rng = opts.rng, cache = opts.cache })
  if not m then return floor, false end
  m = Eval.forward_measure(gs, sj, m, opts)
  local an = conditional_xmult_marginal(gs, key, opts, false)   -- add-side (X-1)*base, like a buy
  if an and an > m then m = an end
  local frac = m / (need or Mechanics.boss_per_hand_need(gs))
  if Eval.is_inert(key, m, gs) then return frac, true end
  return math.max(frac, floor), true
end

-- Deck composition counts (excluding stone cards): total, diamonds, faces, nines.
local function deck_counts(gs)
  local n, dia, face, nines = 0, 0, 0, 0
  for _, c in ipairs(gs.deck or {}) do
    if not Cards.is_stone(c) then
      n = n + 1
      if c.suit == "Diamonds" then dia = dia + 1 end
      if Cards.is_face(c) then face = face + 1 end
      if Cards.rank_id(c) == 9 then nines = nines + 1 end
    end
  end
  return n, dia, face, nines
end

local function clampf(x, lo, hi) return math.max(lo, math.min(hi, x)) end

-- Conditional econ jokers: their $/round depends on YOUR deck, not a flat number.
-- Each scales its prior by how the deck's relevant share compares to the balanced
-- 52-card baseline the prior assumed -- so a Diamonds deck earns more from Rough
-- Gem, a no-Diamonds deck earns ~nothing, and a balanced deck reproduces the prior
-- (keeping existing behaviour). Scale is bounded so an extreme deck can't run away.
-- MEASURED discard/play money (2026-10-03, live NUJ9ENYU flags 1-2, owner: Mail-In Rebate is "pretty easy at least
-- 10 dollars", To Do List "on pairs could've farmed money"). Both sat on the catalogue's flat \$4/round, tying
-- Rebate with Delayed Gratification and losing To Do List to a foil Ice Cream.
local function rank_suit_counts(cards)
  local ranks, suits, n = {}, {}, 0
  for _, c in ipairs(cards or {}) do
    if not Cards.is_stone(c) then
      local r = Cards.rank_id(c)
      if r and r > 0 then ranks[r] = (ranks[r] or 0) + 1; n = n + 1 end
      if c.suit then suits[c.suit] = (suits[c.suit] or 0) + 1 end
    end
  end
  return ranks, suits, n
end
-- Mail-In Rebate: \$5 per discarded card of the round's rank. The game draws that rank from a deck card, so the
-- expected copies of it are sum(n_r^2)/N; a round's discards cycle about hand_size + discards x 4 cards (a discard
-- takes up to 5) of the N-card deck, and the engine dumps every match it sees (Heuristics money_discard).
local function mail_income(gs)
  local ranks, _, n = rank_suit_counts(gs.deck)
  if n == 0 then return nil end
  local sq = 0
  for _, c in pairs(ranks) do sq = sq + c * c end
  local copies = sq / n
  local hs = (gs.run and gs.run.hand_size) or 8
  local d = (gs.blind and (gs.blind.base_discards or gs.blind.discards_left)) or 3
  local seen = math.min(1, (hs + 4 * math.max(0, d)) / n)
  return 5 * copies * seen
end
-- To Do List: \$4 per play of the round's listed hand (one of 8, drawn each round). Expected plays of a hand = the
-- share of dealt hands that contain it x the hands a round can spend on it (half the round's hands: the clear
-- needs the rest), averaged over the list. Availability is measured on deals from the deck.
local TODO_HANDS = { "Pair", "Two Pair", "Three of a Kind", "Straight", "Flush", "Full House", "Four of a Kind",
  "Straight Flush" }
local function deal_contains(cards)
  local ranks, suits = rank_suit_counts(cards)
  local pairs_, three, four = 0, false, false
  for _, c in pairs(ranks) do
    if c >= 2 then pairs_ = pairs_ + 1 end
    if c >= 3 then three = true end
    if c >= 4 then four = true end
  end
  local flush = false
  for _, c in pairs(suits) do if c >= 5 then flush = true end end
  local straight = false
  for lo = 1, 10 do
    local ok = true
    for r = lo, lo + 4 do
      local rr = (r == 1) and 14 or r
      if not ranks[rr] then ok = false; break end
    end
    if ok then straight = true; break end
  end
  return { ["Pair"] = pairs_ >= 1, ["Two Pair"] = pairs_ >= 2, ["Three of a Kind"] = three,
    ["Straight"] = straight, ["Flush"] = flush, ["Full House"] = three and pairs_ >= 2,
    ["Four of a Kind"] = four, ["Straight Flush"] = false }
end
local function todo_income(gs)
  local deck = gs.deck
  if not deck or #deck < 8 then return nil end
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)
  local s = (#deck * 7919 + 104729) % 2147483647
  local rng = function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
  local SAMPLES = 12
  local avail = 0
  for _ = 1, SAMPLES do
    local has = deal_contains(JokerValue._sample_hand(gs, deck, hs, rng))
    for _, h in ipairs(TODO_HANDS) do if has[h] then avail = avail + 1 end end
  end
  local hands = (gs.blind and gs.blind.base_hands) or 4
  return 4 * (avail / (SAMPLES * #TODO_HANDS)) * (hands / 2)
end
-- Delayed Gratification: \$2 per discard, only in a round where NO discard is used. The share of rounds that need
-- none = the share of sampled deals whose best play clears this ante's Big blind over the round's hands. Owning
-- Mail-In Rebate (which wants every discard) makes it 0 -- owner 2026-10-03: they work against each other.
local function delayed_grat_income(gs)
  for _, j in ipairs(gs.jokers or {}) do if j.key == "j_mail" then return 0 end end
  local deck = gs.deck
  if not deck or #deck < 8 then return nil end
  local HandEval = require("engine.hand_eval")
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)
  local hands = (gs.blind and gs.blind.base_hands) or 4
  local d = (gs.blind and (gs.blind.base_discards or gs.blind.discards_left)) or 3
  local need = Mechanics.blind_requirement(math.floor((gs.meta and gs.meta.ante) or 1), "Big")
  local s = (#deck * 104729 + 7919) % 2147483647
  local rng = function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
  local SAMPLES, ok = 8, 0
  for _ = 1, SAMPLES do
    local ev = HandEval.best_play(gs, JokerValue._sample_hand(gs, deck, hs, rng))
    if ev and ev.score * hands >= need then ok = ok + 1 end
  end
  return 2 * d * ok / SAMPLES
end
Eval._mail_income, Eval._todo_income, Eval._dg_income = mail_income, todo_income, delayed_grat_income

local CONDITIONAL_ECON = {
  -- MEASURED-INCOME jokers: the measurement is used only where the caller asks for it (a buy into a FREE slot,
  -- see Eval.econ_value). Everywhere a joker is weighed AGAINST another (swaps, trades, sells) they keep the prior:
  -- the joker FV's money term is a flat 0.8 per \$/round at every ante, and with Mail-In at \$9 that sold real
  -- scorers for it from ante 3 on (bundle arm bn, 2026-10-03: Rebate bought 16x vs 3, replacing Wily, Jolly,
  -- Swashbuckler, Abstract...). Lift this once the money->FV rate is ante-aware.
  j_mail = function(gs, base, measured) return measured and mail_income(gs) or base end,
  j_todo_list = function(gs, base, measured) return measured and todo_income(gs) or base end,
  j_delayed_grat = function(gs, base, measured) return measured and delayed_grat_income(gs) or base end,
  -- Faceless Joker: \$5 per discard of 3+ face cards. MEASURED, not the catalogue's \$3 (2026-10-04, live NSWJJKK8 flags 3/8,
  -- owner-confirmed: Faceless sat unsold beside Ramen while full-board picks were skipped). What the engine actually
  -- earns with it, over whole runs that start owning it (sim probe `faceless`, 44 seeds, 199 blinds): \$1.93 a blind;
  -- with Ramen on the board \$0 (its discards are blocked, DiscardFuel.bleeds_scaler; pooled arms \$0.19); with Green
  -- Joker ~\$0.2 (pooled \$0.35, probe \$0). The farm needs a one-hand clear in hand, so it pays mostly early.
  j_faceless = function(gs, base)
    for _, j in ipairs(gs.jokers or {}) do
      if j.key == "j_ramen" then return 0.2 end
      if j.key == "j_green_joker" then return 0.2 end
    end
    return 1.9
  end,
  -- Rough Gem: $1 per Diamond scored. Baseline 13/52 = 25% diamonds.
  j_rough_gem = function(gs, base)
    local n, dia = deck_counts(gs)
    if n == 0 then return base end
    return base * clampf((dia / n) / 0.25, 0, 3)
  end,
  -- Business Card: face cards have a chance at $2. Baseline 12/52 faces.
  j_business = function(gs, base)
    local n, _, face = deck_counts(gs)
    if n == 0 then return base end
    return base * clampf((face / n) / (12 / 52), 0, 3)
  end,
  -- Cloud 9: $1 per 9 in the FULL deck each round. Baseline 4 nines (one/suit).
  j_cloud_9 = function(gs, base)
    local n, _, _, nines = deck_counts(gs)
    if n == 0 then return base end
    return base * clampf(nines / 4, 0, 3)
  end,
  -- Reserved Parking: $1 per FACE card held in hand, at a listed probability. It was priced
  -- at a flat $3 regardless of how many faces the deck actually has -- the same gap
  -- Business Card already had fixed above it. Same baseline (12/52 faces).
  j_reserved_parking = function(gs, base)
    local n, _, face = deck_counts(gs)
    if n == 0 then return base end
    return base * clampf((face / n) / (12 / 52), 0, 3)
  end,
  -- Midas Mask (Task 2): golds PLAYED faces; a Gold card pays $3 when later HELD at round end. So the
  -- money scales with how many faces the deck has to convert. Same face baseline (12/52); a no-face deck
  -- correctly earns ~0 (the tier floor valued it flat regardless), a face-heavy deck earns more.
  j_midas_mask = function(gs, base)
    local n, _, face = deck_counts(gs)
    if n == 0 then return base end
    return base * clampf((face / n) / (12 / 52), 0, 3)
  end,
}

-- PROBABILITY-SCALING ECONOMY (2026-08-13). Eval.econ_power is a plain SUM of static
-- per-joker dollar figures, so it is structurally unable to represent a MULTIPLICATIVE money
-- engine -- and both of the human's money-carried wins were exactly that: run 8 was "oops all
-- 6s synergising into reserved parking farming then business card", run 6 was a gold-seal card
-- retriggered by Hanging Chad copied by Brainstorm.
--
-- Oops! All 6s DOUBLES every listed probability, so it doubles the payout RATE of every
-- probability-gated money joker. In the catalogue it carries econ = 0 and cat = "utility", so
-- it contributed nothing and multiplied nothing: the engine could not see the combo at all,
-- and duly owns Oops in 2% of runs and Oops-plus-another-probability-joker in 0%.
--
-- Applied only to the money-POSITIVE probability jokers. Oops also doubles harmful odds
-- (Gros Michel's extinction roll), which is a downside this term must not silently credit.
local PROB_ECON = {
  j_reserved_parking = true, j_business = true, j_bloodstone = true,
  j_lucky_cat = true, j_space = true, j_8_ball = true,
}
local function probability_factor(gs, key)
  if not PROB_ECON[key] then return 1 end
  for _, j in ipairs(gs.jokers or {}) do
    if j.key == "j_oops" then return 2 end
  end
  return 1
end

-- $/round a single joker generates, deck-aware for the conditional ones (Rough
-- Gem / Business Card / Cloud 9); the flat prior for everything else.
-- `measured_income` (optional): use the MEASURED income of Mail-In Rebate / To Do List / Delayed Gratification
-- (only a buy into a free slot passes it; see CONDITIONAL_ECON).
function Eval.econ_value(gs, key, measured_income)
  local base = JokerData.resolve(key).econ or 0
  local fn = CONDITIONAL_ECON[key]
  if fn and base ~= 0 then base = fn(gs, base, measured_income) end
  return base * probability_factor(gs, key)
end

-- Passive economy generated by jokers ($/round), deck-aware (see econ_value).
function Eval.econ_power(gs)
  local s = 0
  for _, j in ipairs(gs.jokers or {}) do s = s + Eval.econ_value(gs, j.key) end
  return s
end

-- Economy: dollars plus a small credit for being at/over the interest cap.
function Eval.economy_power(gs)
  local e = gs.economy or {}
  local d = math.max(0, e.dollars or 0)
  local cap = e.interest_cap or 5
  local interest = math.min(d, cap * 5) / 5
  return d + interest
end

-- Hand-level investment: total levels above 1 across all hands.
function Eval.handlevel_power(gs)
  local total = 0
  for _, h in pairs(gs.run and gs.run.hand_levels or {}) do
    total = total + math.max(0, (h.level or 1) - 1)
  end
  return total
end

-- Deck quality: share of cards with an enhancement/edition/seal + high cards.
function Eval.deck_quality(gs)
  local deck = gs.deck or {}
  if #deck == 0 then return 0 end
  local special, high = 0, 0
  for _, c in ipairs(deck) do
    if c.enhancement or c.edition or c.seal then special = special + 1 end
    if Cards.rank_id(c) >= 12 then high = high + 1 end
  end
  return 0.7 * (special / #deck) + 0.3 * (high / #deck)
end

-- ---- composites -------------------------------------------------------------

-- Run strength in [0,1): weighted, saturated blend of the components. opts is
-- forwarded to joker_power (measured when a deck is present); pass measure=false
-- to force the cheap tier path.
function Eval.run_strength(gs, opts)
  -- downside is in future-value units (~1.5x joker_power units); convert back
  local jp = sat(math.max(0, Eval.joker_power(gs, opts) - Eval.downside_total(gs) / 1.5), 8)
  local ec = sat(Eval.economy_power(gs) + Eval.econ_power(gs) * 5, 30)
  local hl = sat(Eval.handlevel_power(gs), 6)
  local dq = Eval.deck_quality(gs)
  local s = 0.45 * jp + 0.20 * ec + 0.20 * hl + 0.15 * dq
  if s < 0 then s = 0 elseif s > 1 then s = 1 end
  return s
end

-- Expected scaling potential (>=0 normally, but a net-harmful joker can pull a
-- contribution negative): scaling upside minus situational joker downsides. opts
-- is forwarded to joker_power (measured when a deck is present).
function Eval.future_value(gs, opts)
  return FV_JOKER_WEIGHT * Eval.joker_power(gs, opts)
       + 0.1 * Eval.economy_power(gs)
       + 0.5 * Eval.handlevel_power(gs)
       + Eval.ECON_FV * Eval.econ_power(gs) * Eval.money_weight(gs)
       - Eval.downside_total(gs)
end

-- Back-compat: some callers ask "is this an xmult joker?".
function Eval.is_xmult(key) return JokerData.is_xmult(key) end

-- Extra value (fraction of a boss hand) a joker gets from its EDITION.
-- foil/holo/poly are scoring effects already captured when a joker is MEASURED,
-- so pass include_scoring=false in the measured path to avoid double-counting and
-- true in the prior/fallback path. Negative (+1 joker slot) is never captured by
-- scoring, so it's always added.
-- NOTE (acceptable approximation): on the PRIOR path these are flat fractions, but
-- polychrome (x1.5) and holo (+10 mult) are multiplicative/additive on the joker's
-- own contribution, so their true worth scales with that joker's strength. This only
-- bites the no-deck/unmodelled prior path; the measured path already reflects the
-- real magnitude. Left flat by design -- refine only if it proves mis-ranking.
function Eval.edition_score_bonus(edition, include_scoring)
  if edition == "negative" then return 0.5 end       -- a whole extra joker slot (fallback; see negative_slot_fv)
  if not include_scoring then return 0 end
  if edition == "polychrome" then return 0.40        -- x1.5 mult
  elseif edition == "holo" then return 0.25          -- +10 mult
  elseif edition == "foil" then return 0.15 end      -- +50 chips
  return 0
end

-- GRAND_AUDIT P1 (2026-08-25). A NEGATIVE-edition joker is SLOT-FREE: it brings its own
-- +1 PERMANENT joker slot (sim/content.lua note_negative_gain; the real rule). So its worth
-- is the joker's own measured value PLUS the value of that slot -- and the slot is the SAME
-- game effect the Antimatter voucher grants, which engine/vouchers.lua prices at ~8-12.
-- The flat 0.5/1.0 above under-priced it ~16x, so whenever the joker itself measured weak the
-- engine passed a joker that would have handed it a free permanent slot -- exactly the
-- capacity the ceiling probe measured as a large lever (+0.732 baseline / +1.265 rich10 for
-- +2 slots; §5a A3, GRAND_AUDIT §B/P1). This prices the slot board-awarely: ~a future joker,
-- tapered by the RUNWAY left to fill it and discounted when slots are not yet binding. Kept
-- deliberately BELOW Antimatter's base (it rides on a joker that already carries its own value,
-- and negatives are rare so the blast radius is tiny -- correctness over aggression).
Eval.NEG_SLOT_FV    = 6.0    -- a +1 permanent slot ~ a future joker (Antimatter base is 8.0)
Eval.NEG_SLOT_FLOOR = 0.5    -- late-game / no-runway residual (matches the old flat credit)
-- MEASURED SLOT (2026-10-12, owner review; BES_NEG_SLOT=0 restores the flat model below). The flat model priced the slot
-- at 6 boss hands x antes-left -- 4-12x what the engine prices the same +1 slot as Antimatter (one measured shop joker),
-- tapered by time left (a slot is static capacity: what it holds decides the deciding blinds, not how many blinds it
-- exists for; docs/TIME_LEFT_AUDIT_2026-10-12.md), and it credited a slot a Negative joker never leaves free:
--   mode "kept" (default): a Negative joker vs the same joker without the edition -- it leaves ONE more slot free than
--     its normal twin would: worth a future joker. On a FULL board there is no free slot left either way (its edge there
--     -- no sale needed to fit it -- is already in the shop's buy-vs-sell-to-buy paths), so 0.
--   mode "freed" (Ectoplasm): a joker you HOLD becomes negative -> a genuinely free slot appears: a future joker.
-- The current fill does NOT scale it (owner 2026-10-12: "you will basically always have the slots full at some point
-- soon" -- engine boards average 5+ jokers by ante 4 in won and lost runs alike), so a slot = one future joker.
Eval.NEG_SLOT_MEASURED = not (os.getenv and os.getenv("BES_NEG_SLOT") == "0")
function Eval.negative_slot_fv(gs, opts)
  if Eval.NEG_SLOT_MEASURED then
    opts = opts or {}
    local slots = (gs and gs.run and gs.run.joker_slots) or 5
    local jfree = math.max(0, slots - #((gs and gs.jokers) or {}))
    if opts.mode ~= "freed" and jfree <= 0 then return 0 end
    local rng = opts.rng
    if not rng then
      local s = (math.floor((gs and gs.meta and gs.meta.ante) or 1) * 7919 + jfree * 104729 + #((gs and gs.deck) or {})) % 2147483646 + 1
      rng = function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
    end
    local Packs = require("engine.packs")
    local ok, e = pcall(Packs.expected_shop_joker, gs, 2, { rng = rng, samples = 3, measure_count = 4 })
    return (ok and e and e > 0) and e or 0
  end
  local ante = math.floor((gs and gs.meta and gs.meta.ante) or 1)
  local runway = 8 - ante
  if runway < 1 then return Eval.NEG_SLOT_FLOOR end        -- ante 8: no time to collect on the slot
  local rf = math.min(1.0, runway / 6)                     -- more antes left -> more value from the capacity
  local slots = (gs and gs.run and gs.run.joker_slots) or 5
  local njok  = #((gs and gs.jokers) or {})
  local jfree = math.max(0, slots - njok)
  -- full board -> the extra slot is immediately binding; free slots -> option value only
  local bf = (jfree == 0) and 1.0 or math.max(0.4, 1.0 - 0.2 * jfree)
  return math.max(Eval.NEG_SLOT_FLOOR, Eval.NEG_SLOT_FV * rf * bf)
end

return Eval
