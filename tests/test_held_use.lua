-- tests/test_held_use.lua
-- HELD WHEEL OF FORTUNE / FOOL (DE.HELD_USE, 2026-10-09): once in the consumable tray, nothing used them (live death
-- saves held them; the sim only used them straight from a pack). Pins that a held one is used when it can do
-- something, and is not when it cannot.

local DE = require("engine.decision_engine")
local GS = require("model.game_state")
local card, joker = GS.card, GS.joker

return function(t)
  local deck, id = {}, 0
  for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
    for _, r in ipairs({ "2", "3", "4", "5", "6", "7", "8", "9", "10", "Jack", "Queen", "King", "Ace" }) do
      id = id + 1; deck[#deck + 1] = card{ id = id, rank = r, suit = s }
    end
  end
  local hand = { deck[13], deck[26], deck[7], deck[20], deck[3], deck[42], deck[31], deck[9] }   -- an Ace pair + chaff
  local function gs_with(cons, jks, last)
    return GS.new{ hand = hand, deck = deck, jokers = jks, consumables = cons, last_tarot_planet = last,
      meta = { ante = 3 }, run = { hand_levels = {}, hand_size = 8, joker_slots = 5, consumable_slots = 2 },
      blind = { target_chips = 5000, chips_scored = 0, hands_left = 3, discards_left = 0, played_hand_types = {} } }   -- a play decision (a discard outranks a use)
  end
  local function uses(r, key)
    return r.best.type == "USE_CONSUMABLE" and r.best.target and r.best.target.key == key
  end
  local wheel = { key = "c_wheel_of_fortune", set = "Tarot", name = "The Wheel of Fortune" }
  local fool = { key = "c_fool", set = "Tarot", name = "The Fool" }
  local plain = joker{ id = 1, key = "j_joker", name = "Joker" }
  local poly = joker{ id = 2, key = "j_joker", name = "Joker", edition = "polychrome" }

  t.ok(uses(DE.decide(gs_with({ wheel }, { plain })), "c_wheel_of_fortune"),
    "a held Wheel of Fortune is used when a joker has no edition")
  t.ok(not uses(DE.decide(gs_with({ wheel }, { poly })), "c_wheel_of_fortune"),
    "...but not when every joker already has an edition (the game will not allow it)")
  t.ok(uses(DE.decide(gs_with({ fool }, { plain }, { key = "c_jupiter" })), "c_fool"),
    "a held Fool is used to copy the last planet used")
  t.ok(not uses(DE.decide(gs_with({ fool }, { plain }, nil)), "c_fool"), "...not with nothing used yet")
  t.ok(not uses(DE.decide(gs_with({ fool }, { plain }, { key = "c_fool" })), "c_fool"), "...and never to copy a Fool")
end
