-- tests/test_purple_slot.lua
-- A discard with a Purple-seal card makes a Tarot only with a free consumable slot; with a full tray, use a held card
-- that has no side effect (a Planet / Hermit / Temperance) first (2026-10-03, live NUJ9ENYU a6, owner flag 8).
local GS = require("model.game_state")
local DE = require("engine.decision_engine")

return function(t)
  local p = GS.card{ id = 1, rank = "8", suit = "Clubs", seal = "Purple" }
  local q = GS.card{ id = 2, rank = "4", suit = "Clubs" }
  local function gs(cons) return GS.new{ hand = { p, q }, consumables = cons, run = { consumable_slots = 2 } } end
  local discard = { type = "DISCARD", cards = { p, q } }
  local planet = { set = "Planet", key = "c_jupiter", name = "Jupiter" }
  local sun = { set = "Tarot", key = "c_sun", name = "The Sun" }
  local judge = { set = "Tarot", key = "c_judgement", name = "Judgement" }
  local a = DE.free_slot_for_purple(gs({ judge, planet }), discard)
  t.ok(a and a.type == "USE_CONSUMABLE" and a.use_keys[1] == "c_jupiter", "full tray + Purple discard -> use the Planet first")
  t.eq(DE.free_slot_for_purple(gs({ judge, sun }), discard), nil, "never spends a deck-changing tarot (The Sun) for the slot")
  t.eq(DE.free_slot_for_purple(gs({ planet }), discard), nil, "a free slot already -> just discard")
  t.eq(DE.free_slot_for_purple(gs({ judge, planet }), { type = "DISCARD", cards = { q } }), nil, "no Purple seal -> nothing to free")
end
