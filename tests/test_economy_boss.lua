-- tests/test_economy_boss.lua
-- Phase 1 world fidelity (WINRATE_AUDIT A7/A8/A9): boss money/level penalties, in-blind
-- scoring money, and generation-odds corrections. Pure/headless.

local World   = require("sim.world")
local Content = require("sim.content")

return function(t)
  local function run() return World.new_run(1) end

  -- ---- A8: in-blind scoring money (gold seals / Lucky / Rough Gem) is banked ----
  do
    local r = run(); r.economy.dollars = 5
    World._post_play_econ(r, { money = 6, hand_type = "Pair" }, { {}, {} }, nil)
    t.eq(r.economy.dollars, 11, "A8: ev.money (gold seals etc.) is credited to the bankroll")
  end
  do  -- no money -> no change
    local r = run(); r.economy.dollars = 8
    World._post_play_econ(r, { money = 0, hand_type = "Pair" }, { {} }, nil)
    t.eq(r.economy.dollars, 8, "A8: a hand with no scoring money leaves the bankroll unchanged")
  end

  -- ---- A7 The Tooth: -$1 per card played (floored at $0) ----
  do
    local r = run(); r.economy.dollars = 10
    World._post_play_econ(r, { money = 0, hand_type = "Flush" }, { {}, {}, {}, {}, {} }, { money_per_card = 1 })
    t.eq(r.economy.dollars, 5, "A7 Tooth: -$1 per card (5 cards -> -$5)")
  end
  do  -- floored at $0
    local r = run(); r.economy.dollars = 2
    World._post_play_econ(r, { money = 0, hand_type = "Flush" }, { {}, {}, {}, {}, {} }, { money_per_card = 1 })
    t.eq(r.economy.dollars, 0, "A7 Tooth: money floors at $0 (no debt modelled)")
  end
  do  -- play-money and Tooth net together
    local r = run(); r.economy.dollars = 4
    World._post_play_econ(r, { money = 3, hand_type = "Pair" }, { {}, {} }, { money_per_card = 1 })
    t.eq(r.economy.dollars, 5, "A7/A8 net: +$3 scoring money, then -$2 Tooth (4 + 3 - 2)")
  end

  -- ---- A7 The Arm: the played hand's level drops by 1 (floored at base) ----
  do
    local r = run()
    -- Flush leveled to 3 via two planets
    local inc = require("engine.mechanics").HAND_PLANET["Flush"]
    r.hand_levels["Flush"] = { level = 3, chips = inc.base_chips + inc.dchips * 2, mult = inc.base_mult + inc.dmult * 2 }
    World._post_play_econ(r, { money = 0, hand_type = "Flush" }, { {} }, { level_down = 1 })
    t.eq(r.hand_levels["Flush"].level, 2, "A7 Arm: played hand drops one level (3 -> 2)")
    t.eq(r.hand_levels["Flush"].chips, inc.base_chips + inc.dchips, "A7 Arm: chips track the lowered level")
  end
  do  -- can't go below level 1
    local r = run()
    r.hand_levels["Pair"] = { level = 1, chips = 10, mult = 2 }
    World._arm_level_down(r, "Pair", 1)
    t.eq(r.hand_levels["Pair"].level, 1, "A7 Arm: level floors at 1 (no negative levels)")
  end

  -- ---- A9: per-edition price adders + mega weight ----
  do
    t.eq(Content.EDITION_COST.foil, 2, "A9: foil adds +$2 (was flat +$1)")
    t.eq(Content.EDITION_COST.holo, 3, "A9: holo adds +$3")
    t.eq(Content.EDITION_COST.polychrome, 5, "A9: polychrome adds +$5")
    t.eq(Content.PACK_SIZE_W.mega, 0.5, "A9: mega packs down-weighted to 0.5 (was 1)")
  end

  -- ---- A9: pack card ids are unique across packs (no `1000+i` collisions) ----
  do
    local r = run()
    local seen, collisions = {}, 0
    for _ = 1, 4 do
      local opened = Content.open_pack({ key = "p_standard_mega" }, r, World.lcg(7))
      for _, it in ipairs(opened.items) do
        if it.card then
          if seen[it.card.id] then collisions = collisions + 1 end
          seen[it.card.id] = true
        end
      end
    end
    t.eq(collisions, 0, "A9: no duplicate card ids across four opened Standard packs")
  end
end
