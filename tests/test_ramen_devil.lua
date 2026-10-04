-- tests/test_ramen_devil.lua
-- 2026-10-04 live UAPB3XY9 (owner-confirmed):
--  * the normal dig prices the Ramen it burns (x0.01 per discarded card, destroyed at x1) -- it scored the redraw as if
--    Ramen were untouched and four digs destroyed it mid-blind;
--  * a held Devil is USED: a Gold card scores nothing but pays $3 when held at round end, so the score-only use test
--    read it as worthless and it sat in the tray for three antes.
local GS = require("model.game_state")
local DV = require("engine.discard_value")
local T = require("engine.tarot")

return function(t)
  local deck, id = {}, 0
  for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
    for _, r in ipairs({ "2", "3", "4", "5", "6", "7", "8", "9", "10", "Jack", "Queen", "King", "Ace" }) do
      id = id + 1; deck[#deck + 1] = GS.card{ id = id, rank = r, suit = s }
    end
  end
  local hand = {}
  for i = 1, 8 do hand[i] = deck[i * 6] end
  local function state(x)
    return GS.new{ deck = deck, hand = hand, jokers = { GS.joker{ key = "j_ramen", id = 90, ability = { x_mult = x } } },
      economy = { dollars = 10, interest_cap = 5 }, meta = { ante = 3, round = 7, state = "SELECTING_HAND" },
      run = { hand_levels = {}, hand_size = 8 }, blind = { target_chips = 2000, chips_scored = 0, hands_left = 4, discards_left = 3 } }
  end
  local function lcg(seed) local s = seed; return function() s = (s * 16807) % 2147483647; return s / 2147483647 end end
  local discard = { hand[1], hand[2], hand[3], hand[4], hand[5] }
  local saved = DV.RAMEN_DECAY
  DV.RAMEN_DECAY = 0
  local free = DV.measured(state(1.8), discard, { rng = lcg(7), samples = 20 })
  DV.RAMEN_DECAY = saved
  local priced = DV.measured(state(1.8), discard, { rng = lcg(7), samples = 20 })
  t.ok(priced < free, "a dig with Ramen owned is charged for the xmult it burns")
  local gone = DV.measured(state(1.03), discard, { rng = lcg(7), samples = 20 })
  t.ok(gone ~= nil, "a dig that would destroy Ramen is still scored (without Ramen)")

  -- The Devil: used for its money, on a card outside the play
  local gs = GS.new{ deck = deck, hand = hand, jokers = {}, consumables = { { key = "c_devil", name = "The Devil", set = "Tarot" } },
    economy = { dollars = 10, interest_cap = 5 }, meta = { ante = 3, round = 7, state = "SELECTING_HAND" },
    run = { hand_levels = {}, hand_size = 8 }, blind = { target_chips = 300, chips_scored = 0, hands_left = 4, discards_left = 3 } }
  t.ok(T.money_enh_dollars(gs, "c_devil") > 0, "The Devil's Gold card is worth money over the run")
  t.eq(T.money_enh_dollars(gs, "c_magician"), 0, "... a scoring enhancement is not")
  local HandEval = require("engine.hand_eval")
  local base = HandEval.best_play(gs, hand)
  local use = T.best_use(gs, base, 300, 12)
  t.ok(use and use.target and use.target.key == "c_devil", "a held Devil is used")
  t.ok(use and use.reason:find("held at round end") ~= nil, "... for its money")

  -- discount vouchers: total measured dollars saved over the rest of the run (owner: "didn't buy clearance sale")
  local V = require("engine.vouchers")
  local function at(a) return V.savings_dollars({ meta = { ante = a }, economy = { dollars = 20 } }, "v_clearance_sale") end
  t.ok(at(1) > at(4) and at(4) > at(6) and at(6) > at(8), "Clearance Sale saves less the later it is bought")
  t.ok(at(4) > 10 and at(6) > 10, "... and more than its $10 price through ante 6")
  t.ok(at(8) < 10, "... but not at ante 8")
  t.eq(V.savings_dollars({ meta = { ante = 3 } }, "v_telescope"), nil, "only discount vouchers are priced by savings")
end
