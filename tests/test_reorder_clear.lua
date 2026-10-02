-- tests/test_reorder_clear.lua
-- A clear that exists only in the engine's best card order must carry the reorder (2026-10-02, live NUJ9ENYU a6:
-- a Flush listed 8S-first for Hanging Chad was "guaranteed" at 45198; the money-objective ordering dropped the
-- reorder because it gained no $, the self-player played the cards as dealt and scored 13400 against 30000).
local GS       = require("model.game_state")
local DE       = require("engine.decision_engine")
local HandEval = require("engine.hand_eval")

return function(t)
  local hand = {
    GS.card{ id = 1, rank = "King", suit = "Hearts" },
    GS.card{ id = 2, rank = "King", suit = "Spades", enhancement = "m_glass" },
    GS.card{ id = 3, rank = "2", suit = "Clubs" }, GS.card{ id = 4, rank = "3", suit = "Diamonds" },
    GS.card{ id = 5, rank = "4", suit = "Hearts" }, GS.card{ id = 6, rank = "6", suit = "Spades" },
    GS.card{ id = 7, rank = "7", suit = "Clubs" }, GS.card{ id = 8, rank = "9", suit = "Diamonds" },
  }
  local base = { jokers = { GS.joker{ key = "j_hanging_chad" } }, hand = hand,
    run = { hand_levels = {}, hand_size = 8 }, meta = { ante = 2 } }
  local g0 = GS.new(base)
  local dealt = HandEval.score(g0, { hand[1], hand[2] }).score     -- Chad retriggers the plain King
  local best  = HandEval.score(g0, { hand[2], hand[1] }).score     -- Chad retriggers the Glass King
  t.ok(best > dealt, "the Glass King first scores more with Hanging Chad")
  local target = math.floor((dealt + best) / 2)
  base.blind = { target_chips = target, chips_scored = 0, hands_left = 1, discards_left = 0, played_hand_types = {} }
  local r = DE.decide(GS.new(base), {})
  local b = r and r.best
  t.eq(b and b.type, "PLAY", "plays the pair")
  t.ok(b and b.reorder ~= nil and b.reorder.card_changed, "the reorder that keeps the clear is attached")
  t.eq(b and b.reorder and b.reorder.card_order[1] and b.reorder.card_order[1].id, 2, "Glass King goes first")

  -- the sim plays the listed cards in HAND order unless a reorder moves them
  local World = require("sim.world")
  local o = World.in_hand_order({ hand[2], hand[1] }, hand)
  t.eq(o[1].id, 1, "sim: listed cards fall back to hand order")
end
