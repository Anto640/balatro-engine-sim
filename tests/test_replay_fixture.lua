-- tests/test_replay_fixture.lua
-- The shared replay-fixture serialization (core/replay_fixture): a decision state must survive
-- fixture_of -> JSON -> rehydrate intact enough to re-run the current engine, INCLUDING shop/pack
-- state (which the old in-blind fixture_of dropped). This is the spine of the per-decision
-- agreement objective (methodology-shift-2026-08, Step 2).

local RF   = require("core.replay_fixture")
local GS   = require("model.game_state")
local Json = require("util.json")
local SA   = require("engine.shop_advisor")

return function(t)
  local gs = GS.new{
    jokers = { GS.joker{ key = "j_baron", ability = { x_mult = 1.5 } } },
    consumables = { GS.consumable{ key = "c_temperance", set = "Tarot" } },
    economy = { dollars = 12, interest_cap = 5 },
    meta = { ante = 3, round = 1, state = "SHOP", seed_hash = "1003" },
    shop = {
      jokers = { GS.joker{ key = "j_hologram", cost = 6 } },
      boosters = { { key = "p_celestial_normal", name = "Celestial Pack", cost = 6 } },
      vouchers = {}, reroll_cost = 5, joker_slots = 5,
    },
  }

  -- fixture_of -> JSON -> back: the shop survives (editions/abilities/cost/reroll)
  local fx = RF.fixture_of(gs, { type = "BUY_JOKER", key = "j_hologram" }, 1, "shop")
  t.eq(fx.decision, "shop", "fixture records the decision channel")
  t.eq(fx.chose.key, "j_hologram", "fixture records the chosen action")
  local rt = RF.rehydrate(Json.decode(Json.encode(fx)))
  t.eq(#rt.shop.jokers, 1, "shop offer jokers survive the round-trip")
  t.eq(rt.shop.jokers[1].key, "j_hologram", "shop joker key preserved")
  t.eq(rt.shop.boosters[1].name, "Celestial Pack", "shop booster preserved")
  t.eq(rt.shop.reroll_cost, 5, "reroll cost preserved")
  t.eq(rt.economy.dollars, 12, "economy preserved")
  t.eq(#rt.jokers, 1, "owned jokers preserved")
  t.near(rt.jokers[1].ability.x_mult, 1.5, "owned joker ability (scaling state) preserved", 1e-9)

  -- the CURRENT engine can run on the rehydrated state (the whole point)
  local r = SA.recommend(rt)
  t.ok(r and r.best and r.best.type ~= nil, "current engine replays on a rehydrated shop fixture")

  -- pack round-trip
  local pgs = GS.new{
    economy = { dollars = 8, interest_cap = 5 },
    meta = { ante = 2, round = 1, state = "PACK", seed_hash = "2003" },
    pack = { items = { { set = "Tarot", key = "c_hermit" }, { set = "Planet", key = "c_mars" } },
             picks_left = 1, kind = "arcana" },
  }
  local pfx = RF.rehydrate(Json.decode(Json.encode(RF.fixture_of(pgs, nil, 2, "pack"))))
  t.eq(#pfx.pack.items, 2, "pack items survive the round-trip")
  t.eq(pfx.pack.items[1].key, "c_hermit", "pack item key preserved")
end
