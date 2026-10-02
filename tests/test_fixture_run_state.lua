-- tests/test_fixture_run_state.lua
-- bes_fixtures.jsonl must record the run state the live evaluation uses (2026-10-02). The fixture used to be written
-- BEFORE BES.evaluate attached the carried build commitment and the Mouth lock, so 0 of 892 live states carried
-- them and a replay of a commitment-dependent decision disagreed with live (Z9ZPREGI: live sold Raised Fist because
-- Sly was core to a Full House plan; the replay, with no plan, sold Sly). Loads main.lua headlessly like
-- test_scheduler and captures what BES.emit_fixture writes.

local GS   = require("model.game_state")
local Json = require("util.json")
local RF   = require("core.replay_fixture")

return function(t)
  local saved_love = _G.love
  local written = {}
  _G.love = { timer = { getTime = function() return 1 end },
              filesystem = { append = function(_, s) written[#written + 1] = s end } }
  local Log = require("util.log")
  local saved_level = Log.level
  local ok, err = pcall(function()
    local BES = dofile(package.searchpath("main", package.path))
    Log.level = "off"
    local plan = { kind = "hand", hand = "Full House", committed_ante = 3, strength = 5,
                   anchors = { "j_sly" }, upgraded = true }   -- upgraded: BP.advance keeps it as is
    BES._build_seed, BES._build_plan = "SEEDX", plan

    -- a shop state: the fixture carries the plan the evaluation will use
    local shop = GS.new{
      jokers = { GS.joker{ key = "j_sly" } }, economy = { dollars = 10, interest_cap = 5 },
      meta = { ante = 5, round = 13, state = "SHOP", seed_hash = "SEEDX" },
      run = { hand_levels = {}, hand_size = 8 },
      shop = { jokers = {}, boosters = {}, vouchers = {}, reroll_cost = 5, joker_slots = 5 },
    }
    BES.emit_fixture(shop)
    t.eq(#written, 1, "one fixture written for the shop state")
    local fx = Json.decode(written[1])
    local bp = fx.gs and fx.gs.run and fx.gs.run.build_plan
    t.ok(bp ~= nil, "the shop fixture records the build commitment")
    t.eq(bp and bp.hand, "Full House", "with the committed hand")
    t.eq(RF.rehydrate(fx).run.build_plan.hand, "Full House", "and replay sees it")
    t.eq(BES._build_plan, plan, "writing the fixture does not move the live plan")

    -- a Mouth blind after the first hand: the fixture carries the lock
    local blind = GS.new{
      hand = { GS.card{ id = 1, rank = "Ace", suit = "Spades" } },
      meta = { ante = 2, round = 6, state = "SELECTING_HAND", seed_hash = "SEEDX" },
      run = { hand_levels = {}, hand_size = 8 },
      blind = { blind_type = "Boss", boss = true, boss_effect_key = "bl_mouth", hands_left = 3,
                hands_played_round = 1, last_hand_played = "Pair", played_hand_types = { Pair = true } },
    }
    BES.emit_fixture(blind)
    t.eq(#written, 2, "one fixture written for the blind state")
    local bfx = Json.decode(written[2])
    t.eq(bfx.gs.blind.first_hand_type, "Pair", "the blind fixture records the Mouth lock")
    t.eq(RF.rehydrate(bfx).blind.first_hand_type, "Pair", "and replay sees it")
  end)
  Log.level = saved_level
  _G.love = saved_love
  if not ok then t.ok(false, "fixture run-state test crashed: " .. tostring(err)) end
end
