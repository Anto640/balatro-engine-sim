-- tests/test_money_weight.lua
-- 2026-10-03 follow-ups to the F5 review (live NUJ9ENYU):
--  * a joker's income is worth less as fewer rounds remain (Eval.money_weight): unchanged through the calibration
--    ante, then falling with rounds left x the dollar rate;
--  * a MONEY joker may be the incoming side of a paired trade (judged on its measured score; it is never sold as one);
--  * skipping a blind forgoes its cash-out interest, so playing is credited with it.
local GS = require("model.game_state")
local Eval = require("engine.eval_function")
local SA = require("engine.shop_advisor")
local SK = require("engine.skip_advisor")

return function(t)
  local w = function(a) return Eval.money_weight({ meta = { ante = a } }) end
  t.eq(w(1), 1, "early money keeps the calibrated weight")
  t.eq(w(3), 1, "... through the calibration ante")
  t.ok(w(4) < 1 and w(5) < w(4) and w(8) < w(5), "then falls every ante")
  t.ok(w(8) > 0 and w(8) < 0.2, "ante 8 money is worth a small fraction")

  t.ok(SA.trade_in_plain("j_golden"), "a money joker can come in on a measured score trade (Holo Golden Joker)")
  t.ok(not SA.trade_out_plain("j_golden"), "... but is never sold as a plain scorer")
  t.ok(not SA.trade_in_plain("j_rocket"), "a scaling money joker is not a plain trade-in")

  local function skip_state(dollars)
    local deck, id = {}, 0
    for _, s in ipairs({ "Spades", "Hearts" }) do
      for _, r in ipairs({ "2", "5", "9", "King" }) do id = id + 1; deck[#deck + 1] = GS.card{ id = id, rank = r, suit = s } end
    end
    return GS.new{ deck = deck, jokers = {}, economy = { dollars = dollars, interest_cap = 5 },
      meta = { ante = 2, state = "BLIND_SELECT" }, run = { hand_levels = {}, joker_slots = 0 },
      blind = { blind_type = "Big", skip_tag = "tag_economy", base_hands = 4 } }
  end
  local poor, rich = SK.recommend(skip_state(0)), SK.recommend(skip_state(25))
  t.ok(poor and rich, "skip advice is given")
  if poor and rich then
    t.eq(rich.play_value - poor.play_value, 5, "playing is credited the interest the skip forgoes ($25 -> $5)")
    t.ok(rich.reason:find("interest") ~= nil, "... and says so")
  end

  -- a copier on an EMPTY board is worth the joker it will copy (a friend's live runs: rerolled past Blueprint)
  local deck, id = {}, 0
  for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
    for _, r in ipairs({ "2", "3", "4", "5", "6", "7", "8", "9", "10", "Jack", "Queen", "King", "Ace" }) do
      id = id + 1; deck[#deck + 1] = GS.card{ id = id, rank = r, suit = s }
    end
  end
  local gs = GS.new{ deck = deck, jokers = {}, economy = { dollars = 20, interest_cap = 5 },
    meta = { ante = 1, round = 1, state = "SHOP", seed_hash = "BP120" },
    run = { hand_levels = {}, hand_size = 8, joker_slots = 5 }, blind = { base_hands = 4, base_discards = 3 },
    shop = { jokers = { GS.joker{ key = "j_blueprint", cost = 10, id = 201 }, GS.joker{ key = "j_egg", cost = 4, id = 202 } },
             boosters = {}, vouchers = {}, consumables = {}, reroll_cost = 5, joker_slots = 5 } }
  t.ok(SA.copier_future_frac(gs) > 0, "a copier with room for a target has future value")
  local r = SA.recommend(gs, {})
  t.eq(r.best.type, "BUY_JOKER", "an empty board with $20 buys Blueprint (does not reroll past it)")
  t.eq(r.best.target and r.best.target.key, "j_blueprint", "... Blueprint")
end
