-- tests/test_paired_trade.lua
-- Full-board trades between plain scorers are measured as a PAIR on shared hands (2026-10-03, live NUJ9ENYU a6:
-- Swashbuckler 2351 a hand vs the offered Abstract Joker 3966 both read the 1.80 tier floor, so no trade cleared).
-- The trade's buy is then honoured once the sale is made (gs.run.pending_swap).
local GS = require("model.game_state")
local SA = require("engine.shop_advisor")

return function(t)
  local deck, id = {}, 0
  for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
    for _, r in ipairs({ "2", "3", "4", "5", "6", "7", "8", "9", "10", "Jack", "Queen", "King", "Ace" }) do
      id = id + 1; deck[#deck + 1] = GS.card{ id = id, rank = r, suit = s }
    end
  end
  local function board()
    return { GS.joker{ key = "j_swashbuckler", sell_value = 1, id = 101 }, GS.joker{ key = "j_joker", sell_value = 1, id = 102 },
             GS.joker{ key = "j_jolly", sell_value = 1, id = 103 }, GS.joker{ key = "j_zany", sell_value = 2, id = 104 },
             GS.joker{ key = "j_half", sell_value = 2, id = 105 } }
  end
  local abstract = GS.joker{ key = "j_abstract", cost = 4, id = 201 }
  local function state(jokers, pending)
    return GS.new{ deck = deck, jokers = jokers, economy = { dollars = 30, interest_cap = 5 },
      meta = { ante = 6, round = 16, state = "SHOP", seed_hash = "T1" },
      run = { hand_levels = {}, hand_size = 8, joker_slots = 5, pending_swap = pending },
      blind = { base_hands = 4, base_discards = 3 },
      shop = { jokers = { abstract }, boosters = {}, vouchers = {}, consumables = {}, reroll_cost = 5, joker_slots = 5 } }
  end
  t.ok(SA.trade_out_plain("j_swashbuckler") and SA.trade_in_plain("j_abstract"), "flat scorers are paired-trade eligible")
  t.ok(not SA.trade_out_plain("j_ride_the_bus"), "a scaler keeps its own protection")
  local r = SA.recommend(state(board()), {})
  local sell
  for _, a in ipairs(r.alternatives or {}) do
    if a.type == "SELL_JOKER" and a.pending_swap then sell = a end
  end
  if r.best.type == "SELL_JOKER" and r.best.pending_swap then sell = r.best end
  t.ok(sell ~= nil, "a paired trade for Abstract Joker is offered")
  t.eq(sell and sell.pending_swap.key, "j_abstract", "... buying Abstract Joker")
  if sell then
    -- after the sale the buy is due: it must beat banking
    local rest = {}
    for _, j in ipairs(board()) do if j.id ~= sell.target.id then rest[#rest + 1] = j end end
    local r2 = SA.recommend(state(rest, sell.pending_swap), {})
    t.eq(r2.best.type, "BUY_JOKER", "the trade's buy is taken once the slot is free")
    t.eq(r2.best.target and r2.best.target.key, "j_abstract", "... the joker it was made for")
  end
end
