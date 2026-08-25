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
local JokerValue = require("engine.joker_value")
local Mechanics = require("engine.mechanics")
local VU = require("engine.value_units")
local ConsumableValue = require("engine.consumable_value")

local Eval = {}

-- future_value weights joker_power by this; pinned here so the measured path can
-- put a boss-hand fraction on the SAME scale as the tier path (no downstream
-- retune). 1 fraction is worth VU.FV_PER_FRAC FV points, and FV = weight*jp, so:
local FV_JOKER_WEIGHT = 1.5
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
local function scale_trigger_factor(gs, key, freq)
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
  return p * factor * base
end

-- joker_power units from a measured marginal `m` (raw score the joker adds), or
-- the tier prior when `m` is nil (no deck / no scoring model). Measured value is
-- normalised to a boss-hand fraction and scaled onto the joker_power scale, then
-- floored by a fraction of the tier prior so a held/retrigger joker the greedy
-- sampler suppresses (Mime, Baron, Steel) is never valued at ~0. Scaling jokers
-- are projected forward either way -- condition-locked scalers gated by how often
-- their trigger hand appears (only those sample frequencies). Returns (jp, measured?).
local function jp_from_measure(gs, key, edition, m, opts, owned)
  local e = JokerData.resolve(key)
  local freq = JokerData.scale_trigger_hands(key) and hand_freq(gs, opts) or nil
  local proj = Eval.scaling_projection(gs, key, freq)
  if not m then
    return (e.tier or 3) * 0.5 * proj + edition_jp(edition, true), false
  end
  -- Analytic floor for hand-conditional xmults: the noisy 6-sample delta reads ~0 when the
  -- trigger hand is rare in-sample, so the engine skips a core that multiplies every trigger
  -- hand it plays. Take the HIGHER of measured and P(trigger)*(X-1)*base (an xmult never
  -- reduces score, so max, not blend, is safe and only lifts values the noise suppressed).
  local an = conditional_xmult_marginal(gs, key, opts, owned)
  if an and an > m then m = an end
  local frac = m / Mechanics.boss_per_hand_need(gs)
  local prior_frac = (e.tier or 3) * 0.3
  local floor_frac = 0.6
  if JokerData.has_tag(key, "retrigger") or JokerData.has_tag(key, "enh:steel") then
    floor_frac = 0.9
  end
  frac = math.max(frac, floor_frac * prior_frac)
  -- measured path: foil/holo/poly already in the delta, add only the slot
  return frac * JP_PER_FRAC * proj + edition_jp(edition, false), true
end

local function can_measure(gs, opts)
  if opts.measure == false then return false end
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  return deck and #deck >= JokerValue.MIN_DECK
end

-- joker_power units for ONE owned joker, measured against the deck where possible:
-- its marginal score added back to the rest of the board (paired sampling). Falls
-- back to the tier prior with no deck. Returns (jp, measured?).
function Eval.joker_jp(gs, idx, opts)
  opts = opts or {}
  local j = (gs.jokers or {})[idx]
  if not j then return 0, false end
  local m
  if can_measure(gs, opts) then
    local rest = {}
    for k, jj in ipairs(gs.jokers) do if k ~= idx then rest[#rest + 1] = jj end end
    local without = {}
    for k, v in pairs(gs) do without[k] = v end
    without.jokers = rest
    m = JokerValue.score_delta(without, j,
      { samples = opts.samples or 6, rng = opts.rng, cache = opts.cache })
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

-- FV points from a joker's jp + its passive econ - its situational downside. `j`
-- is the real joker (so stickers/ability inform the downside); idx is its board
-- position or nil for a not-yet-placed shop joker.
local function jp_to_fv(gs, j, jp, idx)
  -- Eval.econ_value, NOT the raw catalogue number. This line read the flat prior, which meant
  -- the deck-aware econ model (Rough Gem by diamond density, Business Card and Reserved
  -- Parking by face density, Cloud 9 by nines) had NEVER reached the buy or sell decision --
  -- it only ever informed spending headroom and run_strength. So a Rough Gem was priced
  -- identically on a 4-diamond deck and a 20-diamond one. It also routes the Oops! All 6s
  -- probability multiplier through, so a money joker is worth more once Oops is on the board.
  local econ = Eval.econ_value(gs, j.key)
  return FV_JOKER_WEIGHT * jp + 0.8 * econ - Downside.penalty(gs, j, idx)
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
  return jp_to_fv(gs, j, jp, idx), measured
end

-- FV-point marginal of ADDING shop joker `sj` to the current board: one measured
-- score_delta (NOT a full board re-measure), so valuing a buy/upgrade is O(1) in
-- the board size. Falls back to the tier prior with no deck. opts as above.
function Eval.add_joker_marginal_fv(gs, sj, opts)
  opts = opts or {}
  local m
  if can_measure(gs, opts) then
    m = JokerValue.score_delta(gs, sj,
      { samples = opts.samples or 6, rng = opts.rng, cache = opts.cache })
  end
  local jp = jp_from_measure(gs, sj.key, sj.edition, m, opts, false)   -- shop: add-side marginal
  return jp_to_fv(gs, sj, jp, nil)
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
  local prior_frac = (e.tier or 3) * 0.3
  local floor_frac = 0.6
  if JokerData.has_tag(key, "retrigger") or JokerData.has_tag(key, "enh:steel") then floor_frac = 0.9 end
  local floor = floor_frac * prior_frac
  if not can_measure(gs, opts) then return floor, false end
  local m = JokerValue.score_delta(gs, sj, { samples = opts.samples or 6, rng = opts.rng, cache = opts.cache })
  if not m then return floor, false end
  local an = conditional_xmult_marginal(gs, key, opts, false)   -- add-side (X-1)*base, like a buy
  if an and an > m then m = an end
  return math.max(m / (need or Mechanics.boss_per_hand_need(gs)), floor), true
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
local CONDITIONAL_ECON = {
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
function Eval.econ_value(gs, key)
  local base = JokerData.resolve(key).econ or 0
  local fn = CONDITIONAL_ECON[key]
  if fn and base ~= 0 then base = fn(gs, base) end
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
       + 0.8 * Eval.econ_power(gs)
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
function Eval.negative_slot_fv(gs)
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
