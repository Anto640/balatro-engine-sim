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
  local future = e.inc * rate * n / 2
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
  return e.deck_buff * rate * n / 2 * spu
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

-- The measured SCORING value (fraction of a boss hand) of a joker the measured-scaler / deck-modifier
-- system models, or nil if it isn't one (so the caller keeps its own valuation). This is the BRIDGE that
-- carries Tasks 1-2 (Ride the Bus at equilibrium, the accumulating scalers, Hiker, Marble/DNA) into the
-- SHOP buy decision -- `shop_advisor.scoring_gain` has its OWN tier-prior x projection valuation that
-- otherwise ignores all of the above (it valued Ride the Bus at 3.78 vs the measured 0.04). The scalers
-- already project internally (accrued counter / equilibrium), so the caller must NOT re-apply a projection.
-- Econ-channel deck-mods (Midas/Certificate) return 0 here -- their value is MONEY, added via Eval.econ_value.
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
  elseif DECK_MOD_ECON[key] then
    return 0
  elseif key == "j_invisible" then
    -- Invisible's shop value is the copy it will make from the CURRENT board (not owned yet -> self_idx nil).
    return Eval.invisible_copy_jp(gs, nil, opts) / JP_PER_FRAC
  elseif key == "j_ring_master" then
    return Eval.showman_jp(gs, opts) / JP_PER_FRAC
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
  -- Deck-growth (Marble/DNA): MEASURED via card_add_value; nil on the cheap/no-deck path -> tier floor.
  local dmj = deck_modifier_jp(gs, key, opts)
  if dmj then
    return dmj + edition_jp(edition, false), true
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
    local fit = Generators.output_fit(gs, key, owned)
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
