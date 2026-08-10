-- tests/test_value_units.lua
-- Phase 0 infrastructure: the currency/conversion module (engine/value_units) and
-- the measurement cache on engine/joker_value. Tests pin DIRECTION/BOUNDS and the
-- cache's "compute once" contract, not magic numbers.

local VU = require("engine.value_units")
local JV = require("engine.joker_value")
local GS = require("model.game_state")
local card, joker = GS.card, GS.joker

local function lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()
    s = (s * 16807) % 2147483647
    return (s - 1) / 2147483646
  end
end

-- rng wrapper that counts how many random numbers were drawn
local function counting(rng)
  local n = 0
  return function() n = n + 1; return rng() end, function() return n end
end

local function gs_at_ante(a)
  return GS.new{ meta = { ante = a, round = 1, state = "SHOP", seed_hash = "" } }
end

return function(t)
  -- ---- dollar_frac: ante-aware, monotonic, bounded ----
  local f1 = VU.dollar_frac(gs_at_ante(1))
  local f3 = VU.dollar_frac(gs_at_ante(3))
  local f8 = VU.dollar_frac(gs_at_ante(8))
  t.ok(f1 > f3 and f3 > f8, "dollar_frac decreases with ante (a $ is worth more early)")
  t.near(f3, VU.BASE_FRAC, "dollar_frac at the reference ante equals BASE_FRAC", 1e-9)
  t.ok(f1 <= VU.FRAC_MAX + 1e-9 and f8 >= VU.FRAC_MIN - 1e-9, "dollar_frac stays within bounds")

  -- ---- $ <-> fraction round-trips are inverses ----
  do
    local gs = gs_at_ante(4)
    t.near(VU.frac_to_dollars(gs, VU.dollars_to_frac(gs, 17)), 17, "$ -> frac -> $ round-trips")
    t.near(VU.dollars_to_frac(gs, VU.frac_to_dollars(gs, 0.5)), 0.5, "frac -> $ -> frac round-trips")
  end

  -- ---- fraction <-> FV round-trips + the pinned constant ----
  t.near(VU.fv_to_frac(VU.frac_to_fv(0.3)), 0.3, "frac -> FV -> frac round-trips")
  t.near(VU.frac_to_fv(1.0), VU.FV_PER_FRAC, "1 boss-hand fraction = FV_PER_FRAC points")

  -- ---- composed $ <-> FV matches the two-step path ----
  do
    local gs = gs_at_ante(5)
    t.near(VU.dollars_to_fv(gs, 10), VU.frac_to_fv(VU.dollars_to_frac(gs, 10)),
      "dollars_to_fv == frac_to_fv(dollars_to_frac)")
    t.near(VU.fv_to_dollars(gs, VU.dollars_to_fv(gs, 8)), 8, "$ -> FV -> $ round-trips")
  end

  -- ---- measurement cache: compute once, reuse thereafter ----
  do
    local deck = {}
    for r = 2, 13 do deck[#deck + 1] = card{ id = r, rank_id = r, suit = "Hearts" } end
    for r = 2, 13 do deck[#deck + 1] = card{ id = 100 + r, rank_id = r, suit = "Hearts" } end
    local gs = GS.new{ deck = deck, run = { hand_levels = {}, hand_size = 8 } }

    -- avg_score: first call samples, second (same cache) is a hit -> no new draws
    local rng, count = counting(lcg(11))
    local cache = JV.new_cache()
    local a1 = JV.avg_score(gs, { samples = 8, rng = rng, cache = cache })
    local after_first = count()
    local a2 = JV.avg_score(gs, { samples = 8, rng = rng, cache = cache })
    t.ok(a1 ~= nil, "avg_score is measurable with a deck")
    t.eq(a2, a1, "cached avg_score returns the identical value")
    t.eq(count(), after_first, "cached avg_score draws no new randoms (computed once)")

    -- score_delta: same contract, and a DIFFERENT joker is a cache miss (recomputes)
    local rng2, count2 = counting(lcg(11))
    local cache2 = JV.new_cache()
    local d1 = JV.score_delta(gs, joker{ key = "j_lusty_joker" }, { samples = 8, rng = rng2, cache = cache2 })
    local after_lusty = count2()
    local d1b = JV.score_delta(gs, joker{ key = "j_lusty_joker" }, { samples = 8, rng = rng2, cache = cache2 })
    t.eq(d1b, d1, "cached score_delta returns the identical value")
    t.eq(count2(), after_lusty, "cached score_delta draws no new randoms on a hit")
    JV.score_delta(gs, joker{ key = "j_wrathful_joker" }, { samples = 8, rng = rng2, cache = cache2 })
    t.ok(count2() > after_lusty, "a different joker is a cache miss (recomputes)")
  end
end
