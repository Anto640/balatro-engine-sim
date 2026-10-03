-- tests/test_econ_jokers.lua
-- Measured money for Mail-In Rebate and To Do List (2026-10-03, live NUJ9ENYU flags 1-2): both used a flat $4/round.
local GS       = require("model.game_state")
local Eval     = require("engine.eval_function")
local HandEval = require("engine.hand_eval")

return function(t)
  local deck, id = {}, 0
  for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
    for _, r in ipairs({ "2", "3", "4", "5", "6", "7", "8", "9", "10", "Jack", "Queen", "King", "Ace" }) do
      id = id + 1; deck[#deck + 1] = GS.card{ id = id, rank = r, suit = s }
    end
  end
  local gs = GS.new{ deck = deck, run = { hand_levels = {}, hand_size = 8 }, blind = { base_discards = 4, base_hands = 4 } }
  -- 4 copies of the drawn rank x (8 + 4 discards x 4) / 52 seen x $5
  t.near(Eval.econ_value(gs, "j_mail"), 5 * 4 * 24 / 52, "Mail-In Rebate: $5 x expected matches discarded", 1e-6)
  t.ok(Eval.econ_value(gs, "j_mail") > Eval.econ_value(gs, "j_delayed_grat"), "... beats Delayed Gratification")
  local todo = Eval.econ_value(gs, "j_todo_list")
  t.ok(todo > 0 and todo < 4, "To Do List: measured availability of a random listed hand")

  -- playing To Do List's listed hand earns $4 (so the engine can farm it)
  local a, b = GS.card{ id = 1, rank = "9", suit = "Hearts" }, GS.card{ id = 2, rank = "9", suit = "Spades" }
  local function money(listed)
    local g = GS.new{ jokers = { GS.joker{ key = "j_todo_list", ability = { to_do_poker_hand = listed } } },
      hand = { a, b }, run = { hand_levels = {} } }
    return HandEval.score(g, { a, b }).money or 0
  end
  t.eq(money("Pair"), 4, "a Pair pays $4 when Pair is listed")
  t.eq(money("Flush"), 0, "... and nothing when another hand is listed")

  -- the sim no longer pays it once per round on top (it is banked per play)
  local World = require("sim.world")
  local run = { jokers = { { key = "j_todo_list" } }, _todo_hand = "Pair" }
  t.eq(World._conditional_econ(run, { played_types = { Pair = true }, discards_left = 0, discards_start = 0 }), 0,
    "sim: no round-end To Do payout (paid per play)")
end
