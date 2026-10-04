-- engine/tags.lua
-- Skip-tag values, in dollar-equivalent terms. Economic tags are valued by the
-- money they actually produce in YOUR situation (Investment = $25, Economy =
-- min($, 40)). The scoring/content tags are now CALCULATED where possible rather
-- than flat: Orbital is valued by the planet hand it would level (deck-aware),
-- and the pack tags (Buffoon/Charm/Meteor/Ethereal) reuse the measured pack
-- valuation for the corresponding MEGA pack -- the same machinery the shop uses --
-- converted from boss-hand fractions to dollars (see engine/value_units). Used by
-- the skip advisor. PURE.

local Mechanics = require("engine.mechanics")
local ConsumableValue = require("engine.consumable_value")
local Packs = require("engine.packs")
local BuildPlan = require("engine.build_plan")
local VU = require("engine.value_units")

local Tags = {}

local function dollars(gs) return (gs.economy and gs.economy.dollars) or 0 end
local function need(gs) return Mechanics.boss_per_hand_need(gs) end
local function has_deck(gs)
  local d = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  return d and #d >= 5
end

-- $ value of leveling your most-leveled-worthwhile hand by 3 (the Orbital tag).
-- Measured: freq(you make it) x the real 3-level score gain, in dollar terms.
local function orbital_dollars(gs, opts)
  if not has_deck(gs) then return nil end
  -- The tag levels a SPECIFIC hand (gs.blind.skip_tag_hand, read live from G.GAME.orbital_choices). Value
  -- THAT hand; fall back to the best planet hand only when it's unknown (the sim doesn't model the choice).
  local bp
  local th = gs.blind and gs.blind.skip_tag_hand
  if th and Mechanics.HAND_PLANET[th] then
    local freq = ConsumableValue.hand_frequencies(gs, opts)
    local f = freq and freq[th] or 0
    if f <= 0 then return 0.01 end            -- a hand this deck (almost) never makes: worth ~nothing
    bp = { hand = th, freq = f }
  else
    -- the hand is not known yet (live: read before the blind-select screen rolled it -- UAPB3XY9 skipped a Small
    -- blind for an Orbital priced as +3 Pair levels, ~$45): it is a RANDOM visible hand, so value the average over
    -- them, not the best one
    local freq = ConsumableValue.hand_frequencies(gs, opts)
    if not freq then return nil end
    local _, bctx0 = ConsumableValue.hand_frequencies(gs, opts)
    local visible = { "High Card", "Pair", "Two Pair", "Three of a Kind", "Straight", "Flush", "Full House",
                      "Four of a Kind", "Straight Flush" }
    local tot = 0
    for _, h in ipairs(visible) do
      local f = freq[h] or 0
      if f > 0 then tot = tot + f * ConsumableValue.level_gain(gs, h, 3, bctx0) end
    end
    local persist0 = ConsumableValue.level_scale(gs)
    local frac0 = persist0 * (tot / #visible) / need(gs)
    -- the leveling push (below) credits +3 levels of the COMMITTED hand: a random hand is that one 1 time in #visible
    if BuildPlan.level_push_active(gs) then
      local bp0 = gs.run and gs.run.build_plan
      if bp0 and bp0.hand then frac0 = frac0 + BuildPlan.planet_credit(gs, bp0.hand) * 3 / #visible end
    end
    return VU.frac_to_dollars(gs, frac0)
  end
  if not bp then return nil end
  -- +3 levels PERSIST for the rest of the run (they raise every future play of that hand),
  -- so project over the remaining runway like the standalone-planet value does -- WITHOUT
  -- this, Orbital was valued at only its one-shot gain and declined 12/14 times, so the
  -- engine (which never levels, hand-lv~0) skipped free leveling that costs no $ and no slot.
  local persist = ConsumableValue.level_scale(gs)
  -- board context, so +3 levels are priced against the board that multiplies them rather
  -- than against the hand's bare base (CV.level_gain: understates by 1.4-19x without it)
  local _, bctx = ConsumableValue.hand_frequencies(gs, opts)
  local frac = persist * (bp.freq * ConsumableValue.level_gain(gs, bp.hand, 3, bctx)) / need(gs)
  -- V2c finishing move (BuildPlan.LEVEL_PUSH): Orbital is a +3-level delivery channel for
  -- the committed hand, but its MAGNITUDE never consumed the commitment's planet_credit
  -- (only its hand CHOICE did, via best_planet) -- so under the leveling push the tag
  -- would lag its sister channels (loose planets / Celestial pool / pack picks all add
  -- the credit per level). When the push gate is open, add the same per-level credit x3
  -- so all delivery channels co-move. Gate closed -> byte-identical to before
  -- (increase-only, exactly like the other channels' gated boost).
  if BuildPlan.level_push_active(gs) then
    frac = frac + BuildPlan.planet_credit(gs, bp.hand) * 3
  end
  return VU.frac_to_dollars(gs, frac)
end

-- $ value of the free MEGA pack a pack-tag grants, via the shop's own measured
-- pack valuation (boss-hand fraction) converted to dollars. Bounded sampling so a
-- joker (Buffoon) pack tag doesn't spike blind-select time.
local function pack_dollars(gs, pack_key, opts)
  if not has_deck(gs) then return nil end
  local o = { rng = opts and opts.rng, cache = opts and opts.cache, samples = 3, measure_count = 4 }
  local frac = Packs.value(gs, { key = pack_key }, o)
  if not frac or frac <= 0 then return nil end
  return VU.frac_to_dollars(gs, frac)
end

-- $ value of n FREE joker(s) of a rarity, MEASURED against the deck (same boss-hand-
-- fraction -> dollars bridge the pack tags use). A flat $ prior made the engine decline
-- a free Rare joker every time (sim: tag_rare PLAY 13 / SKIP 0); this values it like the
-- shop would value the joker, but free.
local function joker_dollars(gs, rarity, n, opts)
  if not has_deck(gs) then return nil end
  -- a free joker needs a SLOT. On a full board the tag joker overflows and is LOST, so
  -- the tag is near-worthless -- never skip a blind for a joker you can't keep. Value
  -- only as many as fit (n capped at free slots).
  local slots = (gs.run and gs.run.joker_slots) or 5
  local free = slots - #(gs.jokers or {})
  if free <= 0 then return 2 end
  local frac = Packs.expected_joker_of_rarity(gs, rarity, opts)
  if not frac or frac <= 0 then return nil end
  return VU.frac_to_dollars(gs, frac) * math.min(n or 1, free)
end

-- A measured tag value, falling back to its flat prior when not measurable.
local function measured(fn, base)
  return function(gs, opts)
    local v = fn(gs, opts)
    return (type(v) == "number" and v > 0) and v or base
  end
end

-- key -> { name, val(gs, opts) -> dollars }
local TAG = {
  tag_investment = { name = "Investment", val = function() return 25 end },        -- +$25 after boss
  tag_economy    = { name = "Economy",    val = function(gs) return math.min(dollars(gs), 40) end },
  tag_coupon     = { name = "Coupon",     val = function() return 8 end },          -- free shop items
  tag_voucher    = { name = "Voucher",    val = function() return 10 end },         -- adds a voucher
  tag_d6         = { name = "D6",         val = function() return 4 end },          -- $0 rerolls
  tag_speed      = { name = "Speed",      val = function() return 5 end },          -- $5/skip this run
  tag_handy      = { name = "Handy",      val = function() return 6 end },          -- $1/hand played
  tag_garbage    = { name = "Garbage",    val = function() return 4 end },          -- $1/unused discard
  -- joker tags: a free joker is valued by the MEASURED joker it grants (deck-aware),
  -- like the pack tags -- not a flat prior that's always declined.
  tag_uncommon   = { name = "Uncommon",   val = measured(function(gs, o) return joker_dollars(gs, "Uncommon", 1, o) end, 8) },
  tag_rare       = { name = "Rare",       val = measured(function(gs, o) return joker_dollars(gs, "Rare", 1, o) end, 14) },
  tag_negative   = { name = "Negative",   val = function() return 16 end },         -- +1 joker slot
  tag_foil       = { name = "Foil",       val = function() return 5 end },
  tag_holo       = { name = "Holographic", val = function() return 7 end },
  tag_polychrome = { name = "Polychrome", val = function() return 9 end },
  tag_double     = { name = "Double",     val = function() return 11 end },         -- copies next tag
  -- pack tags: reuse the measured MEGA-pack valuation (deck-aware), $ fallback prior
  tag_buffoon    = { name = "Buffoon",    val = measured(function(gs, o) return pack_dollars(gs, "p_buffoon_mega", o) end, 9) },
  tag_meteor     = { name = "Meteor",     val = measured(function(gs, o) return pack_dollars(gs, "p_celestial_mega", o) end, 7) },
  tag_charm      = { name = "Charm",      val = measured(function(gs, o) return pack_dollars(gs, "p_arcana_mega", o) end, 7) },
  tag_ethereal   = { name = "Ethereal",   val = measured(function(gs, o) return pack_dollars(gs, "p_spectral_normal", o) end, 8) },
  tag_standard   = { name = "Standard",   val = measured(function(gs, o) return pack_dollars(gs, "p_standard_mega", o) end, 4) },
  -- scoring tag: +3 hand levels, valued by the hand you'd actually level
  tag_orbital    = { name = "Orbital",    val = measured(orbital_dollars, 12) },    -- +3 hand levels
  tag_top_up     = { name = "Top-up",     val = measured(function(gs, o) return joker_dollars(gs, "Common", 2, o) end, 8) },  -- 2 common jokers
  tag_juggle     = { name = "Juggle",     val = function() return 3 end },
  tag_boss       = { name = "Boss",       val = function() return 4 end },          -- reroll boss
}

function Tags.get(key) return key and TAG[key] or nil end

-- Returns value(dollars), name. Unknown tags get a small default. opts (rng/cache/
-- samples) feeds the measured tags; omit it and they use their flat prior.
function Tags.value(gs, key, opts)
  local t = TAG[key]
  if not t then return 4, "Tag" end
  local ok, v = pcall(t.val, gs, opts)
  if not ok or type(v) ~= "number" then v = 4 end
  return v, t.name
end

return Tags
