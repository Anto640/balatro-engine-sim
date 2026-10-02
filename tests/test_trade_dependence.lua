-- tests/test_trade_dependence.lua
-- A full-board trade (sell X, take Y) is no trade when Y's measured gain comes from X (2026-10-02, live Z9ZPREGI a5:
-- Raised Fist sold to take a Mime whose whole gain was retriggering Raised Fist; the board measured -19%).
local GS   = require("model.game_state")
local Eval = require("engine.eval_function")

return function(t)
  local deck = {}
  local ranks = { "2", "3", "4", "5", "6", "7", "8", "9", "10", "Jack", "Queen", "King", "Ace" }
  local suits = { "Spades", "Hearts", "Clubs", "Diamonds" }
  local id = 0
  for _, s in ipairs(suits) do for _, r in ipairs(ranks) do id = id + 1; deck[#deck + 1] = GS.card{ id = id, rank = r, suit = s } end end
  local gs = GS.new{
    deck = deck,
    jokers = { GS.joker{ key = "j_joker" }, GS.joker{ key = "j_raised_fist" } },
    meta = { ante = 3 }, run = { hand_levels = {}, hand_size = 8, joker_slots = 2 },
  }
  local s = 99
  local opts = { rng = function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end, samples = 12 }
  local mime = GS.joker{ key = "j_mime" }
  t.eq(Eval.trade_leans_on(gs, 2, mime, opts), true, "Mime leans on the Raised Fist sold for it")
  t.eq(Eval.trade_leans_on(gs, 1, mime, opts), false, "Mime does not lean on a plain Joker")
  t.eq(#gs.jokers, 2, "the check does not change the board")
  t.eq(Eval.trade_leans_on(gs, 2, mime, { samples = 12 }), nil, "no rng (cheap pass): no verdict")
end
