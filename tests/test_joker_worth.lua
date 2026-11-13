-- tests/test_joker_worth.lua
-- engine/joker_worth: the one entry the advisors use to value a joker, plus the trade bars and the tier prior.

local GS         = require("model.game_state")
local JokerWorth = require("engine.joker_worth")
local JokerData  = require("engine.joker_data")
local Eval       = require("engine.eval_function")
local Generators = require("engine.generators")


local function lcg(seed)
  local s = seed
  return function() s = (s * 16807) % 2147483647; return s / 2147483647 end
end

return function(t)
  -- ---- the tier prior: one definition, three units ----
  do
    local tier = JokerData.tier("j_joker")
    t.eq(JokerData.tier_prior("j_joker"), tier * 0.3, "tier prior: a boss-hand fraction (tier x 0.3)")
    t.eq(JokerData.prior_of(JokerData.resolve("j_joker")), tier * 0.3, "prior_of: the same from a catalogue entry")
    t.eq(JokerData.prior_jp_of(JokerData.resolve("j_joker")), tier * 0.5, "prior_jp_of: joker-power points")
    t.eq(JokerData.tier("j_definitely_not_a_joker"), JokerData.resolve("j_definitely_not_a_joker").tier or 3,
         "tier: an unknown key takes the catalogue's fallback")
  end

  -- ---- trade bars ----
  do
    local S, M = JokerWorth.SWAP_KEEP_SLOPE, JokerWorth.UPGRADE_MARGIN
    t.eq(JokerWorth.keep_strength(0), 0, "keep_strength: a dead joker costs nothing to give up")
    t.eq(JokerWorth.keep_strength(2), 2 * (1 + S * 2), "keep_strength: super-linear in the contribution")
    t.eq(JokerWorth.keep_bar(2, 0), 2 * (1 + S * 2) + M, "keep_bar: the upgrade margin when the build has no bias")
    t.eq(JokerWorth.keep_bar(2, M + 3), 2 * (1 + S * 2) + M + 3, "keep_bar: a larger keep bias replaces the margin")
    t.ok(JokerWorth.keep_bar(3, 0) - JokerWorth.keep_bar(1, 0) > 2, "keep_bar: a strong joker is protected more than linearly")
  end

  -- ---- generator fit: one formula for joker and consumable generators ----
  do
    t.eq(Generators.fit({ n = 2 }, 2, 0), 1, "fit: all output lands in free slots")
    t.eq(Generators.fit({ n = 2 }, 0, 0), 0, "fit: no room, none can be made -> nothing lands")
    t.eq(Generators.fit({ n = 2 }, 1, 5), (1 + 0.5 * 1) / 2, "fit: made room is credited at the default discount")
    t.eq(Generators.fit({ n = 2, room_credit = 0.1 }, 0, 5), (0.1 * 2) / 2, "fit: a generator's own room credit")
    t.eq(Generators.fit({ n = 0 }, 0, 0), 1, "fit: nothing to land -> identity")
  end

  -- ---- the pace gate on a scaler's projection ----
  do
    t.eq(JokerWorth.proj_damp(nil), 1, "proj_damp: no pace model -> undamped")
    t.eq(JokerWorth.proj_damp({ on_pace = true }), 1, "proj_damp: on pace -> undamped")
    t.ok(JokerWorth.proj_damp({ urgent = true }) < JokerWorth.proj_damp({ on_pace = false }), "proj_damp: urgent damps hardest")
  end

  -- ---- the one entry: each side answers in its documented unit ----
  do
    local deck = require("sim.world").standard_deck()
    if deck then
      local owned = GS.joker{ id = 1, key = "j_joker", ability = { extra = {} } }
      local gs = GS.new{
        meta = { ante = 2, round = 4, state = "SHOP", seed_hash = "S" }, deck = deck, jokers = { owned },
        economy = { dollars = 20, interest_cap = 5 },
        blind = { base_hands = 4, base_discards = 3, hands_left = 4, discards_left = 3 },
        run = { hand_levels = {}, vouchers_owned = {}, tags = {}, hand_size = 8, consumable_slots = 2, joker_slots = 5 },
        shop = { jokers = {}, boosters = {}, vouchers = {}, reroll_cost = 5 },
      }
      local offer = { key = "j_jolly", ability = { extra = {} } }

      local buy = JokerWorth.of(gs, offer, "buy", { rng = lcg(11) })
      t.ok(type(buy) == "number" and buy > 0, "buy: a scoring joker has a positive gain (boss-hand fraction)")

      local pick, measured = JokerWorth.of(gs, offer, "pick", { rng = lcg(11), samples = 6 })
      t.ok(type(pick) == "number" and pick >= Eval.tier_floor_frac("j_jolly") - 1e-9, "pick: never below the tier floor for a live joker")
      t.eq(measured, true, "pick: says it was measured")

      local add = JokerWorth.of(gs, offer, "add", { rng = lcg(11), samples = 6 })
      t.eq(add, Eval.add_joker_marginal_fv(gs, offer, { rng = lcg(11), samples = 6 }), "add: the measured add-side marginal (FV)")

      local own = JokerWorth.of(gs, 1, "own", { rng = lcg(11), samples = 6 })
      t.eq(own, (Eval.joker_marginal_fv(gs, 1, { rng = lcg(11), samples = 6 })), "own: the owned joker's marginal (FV)")

      -- a money-only joker scores nothing on the buy side
      local money = JokerWorth.of(gs, { key = "j_delayed_grat", ability = { extra = {} } }, "buy", { rng = lcg(11) })
      t.eq(money, Eval.edition_score_bonus(nil, true), "buy: a money-only joker has no scoring gain beyond its edition")
    end
    local ok = pcall(JokerWorth.of, GS.new{}, { key = "j_joker" }, "sideways", {})
    t.eq(ok, false, "of: an unknown side is an error, not a silent zero")
  end
end
