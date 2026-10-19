-- tests/test_state_xmult.lua
-- Round-state xmults (2026-10-19): Card Sharp, Acrobat, Loyalty Card, Ancient Joker and The Idol fire on something a
-- single fresh deal never shows, so their sampled delta was 0, they were judged inert and priced like a joker that does
-- nothing. Each now has an expected per-hand value on the board (Eval.conditional_xmult_marginal), and a shop buy of
-- one is valued above a do-nothing joker.
local GS = require("model.game_state")
local Eval = require("engine.eval_function")
local SA = require("engine.shop_advisor")

return function(t)
  local deck, id = {}, 0
  for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
    for _, r in ipairs({ "2", "3", "4", "5", "6", "7", "8", "9", "10", "Jack", "Queen", "King", "Ace" }) do
      id = id + 1; deck[#deck + 1] = GS.card{ id = id, rank = r, suit = s }
    end
  end
  local function lcg(seed) local s = seed; return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
  local function state(ante, offer)
    return GS.new{ deck = deck, jokers = { GS.joker{ key = "j_joker", id = 101 }, GS.joker{ key = "j_jolly", id = 102 } },
      economy = { dollars = 20, interest_cap = 5 }, meta = { ante = ante, round = ante * 3, state = "SHOP", seed_hash = "SX" },
      run = { hand_levels = {}, hand_size = 8, joker_slots = 5 }, blind = { base_hands = 4, base_discards = 3 },
      shop = { jokers = offer and { offer } or {}, boosters = {}, vouchers = {}, consumables = {}, reroll_cost = 5, joker_slots = 5 } }
  end
  for _, k in ipairs({ "j_card_sharp", "j_loyalty_card", "j_ancient", "j_idol" }) do
    local m = Eval.conditional_xmult_marginal(state(3), k, { rng = lcg(7), samples = 8, cache = {} }, false)
    t.ok(m and m > 0, k .. " has a positive expected marginal on a plain board")
  end
  -- Acrobat only fires on the final hand: a board that needs every hand at the boss gets value, a board far ahead none
  local weak = Eval.conditional_xmult_marginal(state(6), "j_acrobat", { rng = lcg(7), samples = 8, cache = {} }, false)
  local strong = Eval.conditional_xmult_marginal(state(1), "j_acrobat", { rng = lcg(7), samples = 8, cache = {} }, false)
  t.ok(weak and weak > 0, "Acrobat is worth something to a board that needs its last hand")
  t.eq(strong, 0, "Acrobat is worth nothing to a board that clears long before its last hand")
  -- owned semantics: the sell-side marginal (1 - 1/X) is smaller than the buy-side (X - 1) on the same board
  local buy = Eval.conditional_xmult_marginal(state(3), "j_card_sharp", { rng = lcg(9), samples = 8, cache = {} }, false)
  local own = Eval.conditional_xmult_marginal(state(3), "j_card_sharp", { rng = lcg(9), samples = 8, cache = {} }, true)
  t.ok(own < buy, "owned Card Sharp marginal uses the (1 - 1/X) form")
  -- shop: buying Card Sharp is valued above buying a joker that does nothing on this board (Mime, no held effects)
  local function buy_value(key)
    local r = SA.recommend(state(3, GS.joker{ key = key, cost = 6, id = 201 }), {})
    for _, a in ipairs({ r.best, (table.unpack or unpack)(r.alternatives or {}) }) do
      if a.type == "BUY_JOKER" and a.target and a.target.key == key then return a.value end
    end
    return -math.huge
  end
  t.ok(buy_value("j_card_sharp") > buy_value("j_mime"), "Card Sharp's buy beats a do-nothing joker's")
end
