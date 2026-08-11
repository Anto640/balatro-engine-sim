-- tests/test_probe.lua
-- The WINRATE_V3_PLAN Phase A CEILING PROBE (sim/probe.lua) + the Phase B1 feature vector.
--
-- THE LOAD-BEARING PROPERTY under test is INERTNESS: with no probe configured, every hook
-- added for Phase A must be unreachable, so the baseline sim stays byte-identical. Every
-- paired A/B verdict this project has ever produced depends on that, so it is asserted
-- directly rather than assumed.

local Probe  = require("sim.probe")
local Driver = require("sim.driver")
local World  = require("sim.world")
local Content = require("sim.content")

return function(t)
  -- ---- inertness: the baseline path must stay untouched -------------------
  do
    t.eq(Probe.opts("engine"), nil, "the `engine` config resolves to NO opts (baseline untouched)")
    t.eq(Probe.opts(nil), nil, "an absent probe name resolves to NO opts")
    t.eq(Probe.policy_for({}), nil, "a run with no probe uses the engine shop advisor")
    t.eq(Probe.policy_for({ probe = { income_bonus = 100 } }), nil,
      "a resource-only probe does NOT swap the policy")
    t.ok(Probe.policy_for({ probe = { policy = "expert" } }) ~= nil,
      "a policy probe returns the scripted expert")

    local run = World.new_run(1)
    t.eq(run.probe, nil, "a normal run carries no probe")
    -- The income bonus must not fire without a probe. Compare two runs in the SAME state:
    -- round income is interest-bearing, so awarding twice to one run is not a control.
    local blind = { blind_type = "Small", hands_left = 0 }
    local plain_run, probe_run = World.new_run(1), World.new_run(1)
    probe_run.probe = { income_bonus = 100 }
    local plain = World.award_income(plain_run, blind)
    local boosted = World.award_income(probe_run, blind)
    t.eq(boosted, plain + 100, "the A3 income lesion adds exactly its bonus")
    t.ok(plain < 100, "...and the un-probed run gets ordinary round income")
  end

  -- ---- A1 static priority: the supermodular knowledge, hardcoded ----------
  do
    t.ok(Probe.rank("j_blueprint") > Probe.rank("j_joker"),
      "a copier outranks a vanilla flat joker")
    t.ok(Probe.rank("j_baron") > Probe.rank("j_sly"),
      "an xmult outranks a flat-chips common")
    t.ok(Probe.is_core("j_blueprint"), "Blueprint is a core piece (never sold)")
    t.ok(not Probe.is_core("j_joker"), "a vanilla Joker is not a core piece")
  end

  -- ---- A1 policy behaviour ------------------------------------------------
  do
    local function run_with(jokers, dollars, ante)
      local r = World.new_run(7)
      r.jokers = jokers or {}
      r.economy.dollars = dollars or 50
      r.ante = ante or 3
      return r
    end

    t.eq(Probe.expert(run_with({}, 50), { jokers = {}, boosters = {}, vouchers = {},
      consumables = {} }).best.type, "SAVE", "an empty shop banks")

    -- a core piece is bought on a board with a free slot
    local shop = { jokers = { { key = "j_baron", cost = 8 } }, boosters = {},
                   vouchers = {}, consumables = {} }
    local a = Probe.expert(run_with({}, 50), shop).best
    t.eq(a.type, "BUY_JOKER", "an affordable core joker is bought")
    t.eq(a.target.key, "j_baron", "...and it is the highest-ranked offer")

    -- the reserve RAMP: a 3-joker board at ante 3 banks $10, so a $45 non-core buy on $50
    -- is refused while the same buy on a 2-joker board (reserve 0) is taken.
    local mid = { key = "j_greedy_joker", cost = 45 }
    local three = { { key = "j_joker" }, { key = "j_sly" }, { key = "j_wily" } }
    t.eq(Probe.expert(run_with(three, 50, 3), { jokers = { mid }, boosters = {},
      vouchers = {}, consumables = {} }).best.type, "SAVE",
      "the reserve ramp refuses a non-core buy that would break the bank")
    t.eq(Probe.expert(run_with({ { key = "j_joker" } }, 50, 3), { jokers = { mid },
      boosters = {}, vouchers = {}, consumables = {} }).best.type, "BUY_JOKER",
      "...but a thin board buys first (reserve 0 until 3 jokers)")

    -- a full board of FILLER evicts its weakest for a core piece; a full board of CORE does not
    local filler = {}
    for i = 1, 5 do filler[i] = { key = "j_joker", sell_value = 2 } end
    local ev = Probe.expert(run_with(filler, 50), shop).best
    t.eq(ev.type, "SELL_JOKER", "a full filler board evicts to make room for a core piece")
    local cores = {}
    for i = 1, 5 do cores[i] = { key = "j_blueprint", sell_value = 5 } end
    t.eq(Probe.expert(run_with(cores, 50), shop).best.type, "SAVE",
      "a full CORE board is never churned")

    -- the policy never rerolls (reroll-to-dig is a documented revert)
    local rr = Probe.expert(run_with({}, 200), { jokers = {}, boosters = {}, vouchers = {},
      consumables = {}, reroll_cost = 5 }).best
    t.ok(rr.type ~= "REROLL", "the scripted expert never pays to reroll")
  end

  -- ---- free-levels probe (the leveling dose-response) ---------------------
  do
    local run = World.new_run(5)
    local before = 0
    for _, h in pairs(run.hand_levels) do before = before + (h.level or 1) end
    Content.grant_free_levels(run, 2)
    local after, hands = 0, 0
    for _, h in pairs(run.hand_levels) do after = after + (h.level or 1); hands = hands + 1 end
    t.eq(hands, 1, "free levels go to exactly ONE hand (the one the deck wants)")
    t.eq(after - before, 2 + 1, "levelling an unlevelled hand by 2 lands it at level 3")
    -- a no-op for 0/nil, so an unconfigured probe cannot perturb anything
    local r2 = World.new_run(5)
    Content.grant_free_levels(r2, 0)
    Content.grant_free_levels(r2, nil)
    t.eq(next(r2.hand_levels), nil, "grant_free_levels(0/nil) changes nothing")
    -- and the driver leaves it alone with no probe
    local r3 = World.new_run(5)
    t.eq(r3.probe, nil, "a normal run has no free-levels probe")
  end

  -- ---- A3 top-tier pool lesion -------------------------------------------
  do
    local JokerData = require("engine.joker_data")
    local run = World.new_run(5)
    run.probe = { top_pool = true }
    local seen, lo = 0, 0
    local rng = run.rng
    for _ = 1, 60 do
      local j = Content.gen_joker(run, rng)
      if j then
        seen = seen + 1
        if ((JokerData.resolve(j.key) or {}).tier or 0) < 7 then lo = lo + 1 end
      end
    end
    t.ok(seen > 0, "the top-pool lesion still generates jokers")
    t.eq(lo, 0, "the top-pool lesion offers NOTHING below tier 7")
  end

  -- ---- B1 feature vector --------------------------------------------------
  do
    local run = World.new_run(11)
    run.ante = 4
    run.economy.dollars = 33
    run.jokers = { { key = "j_baron" }, { key = "j_blueprint" }, { key = "j_joker" } }
    run.hand_levels = { Pair = { level = 5 }, Flush = { level = 2 } }
    run.deck[1].enhancement = "mult"
    run.deck[2].seal = "gold"
    run.deck[3].edition = "foil"

    local f = Driver.features(run)
    t.eq(f.ante, 4, "features carry the ante")
    t.eq(f.dollars, 33, "features carry the bankroll")
    t.eq(f.njokers, 3, "features count the board")
    t.eq(f.slots_free, 2, "features count free slots")
    t.eq(f.copier, 1, "features count copiers (Blueprint/Brainstorm)")
    t.ok(f.xmult >= 1, "features count xmult jokers")
    t.eq(f.hand_lv_max, 4, "features carry the DEEPEST hand level over base")
    t.eq(f.hand_lv_sum, 5, "features carry total levels over base")
    t.eq(f.hands_leveled, 2, "features count how many hands were leveled")
    t.eq(f.deck_size, 52, "features carry deck size")
    t.eq(f.enhanced, 1, "features count enhanced cards")
    t.eq(f.sealed, 1, "features count sealed cards")
    t.eq(f.editioned, 1, "features count editioned cards")

    -- STREAM NEUTRALITY: the feature vector must consume no RNG (an additive measurement
    -- that perturbs the seeded stream silently churns every batch -- WINRATE_AUDIT §7).
    local r2 = World.new_run(11)
    local a = r2.rng()
    local r3 = World.new_run(11)
    Driver.features(r3)
    local b = r3.rng()
    t.eq(b, a, "Driver.features consumes NO rng (stream-neutral)")
  end
end
