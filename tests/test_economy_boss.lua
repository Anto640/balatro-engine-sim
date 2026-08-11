-- tests/test_economy_boss.lua
-- Phase 1 world fidelity (WINRATE_AUDIT A7/A8/A9): boss money/level penalties, in-blind
-- scoring money, and generation-odds corrections. Pure/headless.

local World   = require("sim.world")
local Content = require("sim.content")

return function(t)
  -- ---- W-ECON: the two DYNAMIC economy jokers (2026-08-11) -----------------
  -- Both were flattened into a static `econ` $/round prior, which removes the economy
  -- snowball. To the Moon is bankroll-PROPORTIONAL; Rocket GROWS per boss defeated.
  do
    local W = require("sim.world")
    local blind = { blind_type = "Small", hands_left = 0 }

    -- To the Moon pays more as the bankroll grows (a flat prior cannot do this)
    local function ttm_at(dollars)
      local r = W.new_run(1)
      r.jokers = { { key = "j_to_the_moon" } }
      r.economy.dollars = dollars
      return W._bonus_interest(r)
    end
    t.eq(ttm_at(0), 0, "To the Moon pays nothing on an empty bankroll")
    t.ok(ttm_at(25) > ttm_at(10), "To the Moon scales WITH the bankroll")
    t.ok(ttm_at(10) > 0, "...and pays below the base cap, where the snowball starts")
    -- capped like base interest, so it cannot run away
    t.eq(ttm_at(1000), ttm_at(100), "To the Moon respects the interest cap")
    -- a raised cap (Seed Money / Money Tree) unlocks more of it
    do
      local r = W.new_run(1)
      r.jokers = { { key = "j_to_the_moon" } }
      r.economy.dollars = 200
      local base = W._bonus_interest(r)
      r.economy.interest_cap = 20
      t.ok(W._bonus_interest(r) > base, "raising the interest cap unlocks more To the Moon")
    end

    -- Rocket grows with bosses defeated
    local r2 = W.new_run(1)
    r2.jokers = { { key = "j_rocket" } }
    local early = W._rocket_income(r2)
    r2._bosses_defeated = 4
    local late = W._rocket_income(r2)
    t.ok(late > early, "Rocket grows per boss defeated")
    t.eq(late - early, 4 * W.ROCKET_PER_BOSS, "...by exactly ROCKET_PER_BOSS each")
    t.eq(W.boss_clear_tick(W.new_run(1)) == nil and 1 or 1, 1, "boss_clear_tick runs")
    do
      local r3 = W.new_run(1)
      W.boss_clear_tick(r3); W.boss_clear_tick(r3)
      t.eq(r3._bosses_defeated, 2, "boss_clear_tick counts defeated bosses")
    end

    -- and neither is DOUBLE-counted through the flat econ sum
    local r4 = W.new_run(1)
    r4.jokers = { { key = "j_to_the_moon" }, { key = "j_rocket" } }
    t.eq(W._joker_econ_income(r4), 0, "the dynamic pair is excluded from the flat econ sum")
    -- a normal econ joker still pays flat
    local r5 = W.new_run(1)
    r5.jokers = { { key = "j_golden" } }
    t.ok(W._joker_econ_income(r5) > 0, "an ordinary econ joker still pays its flat prior")

    -- income actually includes them
    local r6 = W.new_run(1)
    r6.economy.dollars = 25
    local plain = W.award_income(r6, blind)
    local r7 = W.new_run(1)
    r7.economy.dollars = 25
    r7.jokers = { { key = "j_to_the_moon" } }
    t.ok(W.award_income(r7, blind) > plain, "To the Moon raises actual round income")
  end

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
