-- tests/test_decision_state.lua
-- engine/decision_state: the derived fields, the state carried between decisions, and the per-kind contract.
-- sim/state: the simulator's three builders satisfy that contract (a forgotten field fails HERE, not in play).

local GS       = require("model.game_state")
local DS       = require("engine.decision_state")
local SimState = require("sim.state")
local World    = require("sim.world")
local RF       = require("core.replay_fixture")

return function(t)
  -- ---- derive: the boss effect comes from the key, once ----
  do
    local gs = GS.new{ blind = { boss = true, boss_effect_key = "bl_flint", hands_left = 1, discards_left = 0 } }
    DS.derive(gs)
    t.ok(gs.boss_effect ~= nil, "derive: a boss blind gets its scoring effect")
    local first = gs.boss_effect
    DS.derive(gs)
    t.eq(gs.boss_effect, first, "derive: idempotent (an existing effect is kept)")

    local plain = GS.new{ blind = { boss = false, boss_effect_key = "bl_flint", hands_left = 1, discards_left = 0 } }
    t.eq(DS.derive(plain).boss_effect, nil, "derive: not a boss -> no effect")

    local given = {}
    local g2 = GS.new{ blind = { boss = true, boss_effect_key = "bl_flint" } }
    t.eq(DS.derive(g2, given).boss_effect, given, "derive: a caller-supplied effect is used as is")
  end

  -- ---- carry: the Mouth lock ----
  do
    local gs = GS.new{
      meta = { ante = 2, round = 5, state = "SELECTING_HAND", seed_hash = "S" },
      blind = { hands_played_round = 1, last_hand_played = "Pair", played_hand_types = { Pair = true } },
    }
    local c = DS.carry(gs, {})
    t.eq(c.first_hand, "Pair", "carry: one hand played this round -> it is the lock")
    local mem = DS.remember({}, c)
    t.eq(mem.first_hand, "Pair", "remember: stored")

    -- a second hand of another type: the remembered lock stands
    local gs2 = GS.new{
      meta = { ante = 2, round = 5, state = "SELECTING_HAND", seed_hash = "S" },
      blind = { hands_played_round = 2, last_hand_played = "Flush", played_hand_types = { Pair = true, Flush = true } },
    }
    t.eq(DS.carry(gs2, mem).first_hand, "Pair", "carry: the lock survives a later hand")

    -- a new round: the lock lapses
    local gs3 = GS.new{
      meta = { ante = 2, round = 6, state = "SELECTING_HAND", seed_hash = "S" },
      blind = { hands_played_round = 0, played_hand_types = {} },
    }
    t.eq(DS.carry(gs3, mem).first_hand, nil, "carry: a new round has no lock")

    DS.attach(gs2, DS.carry(gs2, mem))
    t.eq(gs2.blind.first_hand_type, "Pair", "attach: the advisors read it on the blind")
  end

  -- ---- carry: the build plan follows the run seed ----
  do
    local plan = { kind = "hand", hand = "Flush", committed_ante = 2, strength = 5, anchors = {}, upgraded = true }
    local blind_gs = GS.new{ meta = { ante = 3, round = 8, state = "SELECTING_HAND", seed_hash = "S" } }
    t.eq(DS.carry(blind_gs, { build_seed = "S", build_plan = plan }).plan, plan, "carry: same run -> the plan")
    t.eq(DS.carry(blind_gs, { build_seed = "OTHER", build_plan = plan }).plan, nil, "carry: another run -> no plan")
  end

  -- ---- carry: a paired trade's buy stays due while the offer is in the shop ----
  do
    local sold = GS.joker{ id = 7, key = "j_joker" }
    local keep = GS.joker{ id = 8, key = "j_sly" }
    local function shop_gs(jokers, offer_key, round)
      return GS.new{
        meta = { ante = 3, round = round or 9, state = "SHOP", seed_hash = "S" }, jokers = jokers,
        run = { hand_levels = {}, hand_size = 8 },
        shop = { jokers = offer_key and { { key = offer_key } } or {}, boosters = {}, vouchers = {}, reroll_cost = 5 },
      }
    end
    local last = { gs = shop_gs({ sold, keep }, "j_blackboard"),
      ranked = { best = { type = "SELL_JOKER", target = sold, pending_swap = { key = "j_blackboard", sold_fv = 1.5 } } } }

    local c = DS.carry(shop_gs({ keep }, "j_blackboard"), { last = last })
    t.ok(c.pending ~= nil and c.pending.key == "j_blackboard", "carry: the sale was made -> the buy is pending")

    local c2 = DS.carry(shop_gs({ sold, keep }, "j_blackboard"), { last = last })
    t.eq(c2.pending, nil, "carry: the joker is still owned -> nothing pending")

    local mem = DS.remember({}, c)
    t.ok(DS.carry(shop_gs({ keep }, "j_blackboard"), mem).pending ~= nil, "carry: still pending on the next tick")
    t.eq(DS.carry(shop_gs({ keep }, nil), mem).pending, nil, "carry: the offer left the shop -> lapsed")
    t.eq(DS.carry(shop_gs({ keep }, "j_blackboard", 10), mem).pending, nil, "carry: a new round -> lapsed")
  end

  -- ---- the contract ----
  do
    local bare = GS.new{}
    local miss = DS.missing(bare, "shop")
    local set = {}
    for _, m in ipairs(miss) do set[m] = true end
    t.ok(set["run.joker_slots"], "missing: a bare state lacks run.joker_slots for a shop decision")
  end

  -- ---- the simulator's builders meet the contract ----
  do
    local run = World.new_run(1)
    local shop = SimState.shop(run, { jokers = {}, boosters = {}, vouchers = {}, reroll_cost = 5 })
    t.eq(table.concat(DS.missing(shop, "shop"), ","), "", "sim shop state: complete")

    local blind = { type = "Boss", name = "The Flint", boss_key = "bl_flint", target = 600, scored = 0,
                    hands_left = 4, discards_left = 3, base_hands = 4, base_discards = 3, hand_size = 8,
                    played_types = {} }
    local bgs = SimState.blind(run, blind, {}, {}, nil)
    t.eq(table.concat(DS.missing(bgs, "blind"), ","), "", "sim blind state: complete")
    t.ok(bgs.boss_effect ~= nil, "sim blind state: the boss effect is derived")

    local sgs = SimState.skip(run, { type = "Small", skip_tag = "tag_investment" })
    t.eq(table.concat(DS.missing(sgs, "skip"), ","), "", "sim skip state: complete")

    -- every declared gap is a real one (an entry that no longer applies must be deleted, not left to rot)
    for kind, gaps in pairs(SimState.GAPS) do
      local gs = (kind == "shop") and shop or sgs
      for path in pairs(gaps) do
        local section, field = path:match("^(%w+)%.([%w_]+)$")
        local v
        if section then v = gs[section] and gs[section][field] else v = gs[path] end
        local empty = (v == nil) or (type(v) == "table" and next(v) == nil)
        t.ok(empty, "sim " .. kind .. " gap '" .. path .. "' is still a gap")
      end
    end
  end

  -- ---- a replayed fixture goes through the same derivation ----
  do
    local gs = RF.rehydrate({ seed = "S", ante = 2, round = 6,
      gs = { blind = { boss = true, boss_effect_key = "bl_flint" }, run = {} } })
    t.ok(gs.boss_effect ~= nil, "replay: the boss effect is derived")
  end
end
