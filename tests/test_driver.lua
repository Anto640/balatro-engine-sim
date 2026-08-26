-- tests/test_driver.lua
-- Phase 1: the full-run driver loop emits telemetry-shaped records and is
-- deterministic. Capped at ante 1 (3 blinds) to keep the suite fast; the stub
-- content means no shop, so this validates the LOOP + record emission, not winrate.

local Driver = require("sim.driver")
local Json   = require("util.json")

return function(t)
  -- a run produces a run_start record and terminates with a well-formed result
  do
    local res = Driver.run(7, { max_ante = 1 })
    t.ok(type(res) == "table" and type(res.records) == "table", "run returns records")
    t.eq(res.records[1].kind, "run_start", "first record is run_start")
    t.ok(type(res.won) == "boolean", "result has a boolean won flag")
    -- every record round-trips through the telemetry JSON (so analyze_runs can read it)
    for _, r in ipairs(res.records) do
      local back = Json.decode(Json.encode(r))
      t.ok(back and back.kind == r.kind, "record JSON round-trips: " .. tostring(r.kind))
    end
  end

  -- determinism: same seed -> identical trajectory (records + outcome)
  do
    local a = Driver.run(42, { max_ante = 1 })
    local b = Driver.run(42, { max_ante = 1 })
    t.eq(#a.records, #b.records, "same seed -> same number of records")
    t.eq(tostring(a.won), tostring(b.won), "same seed -> same outcome")
    t.eq(tostring(a.death_ante), tostring(b.death_ante), "same seed -> same death ante")
  end

  -- W4: a pending Hieroglyph -1 ante (run._ante_back, set by apply_voucher) REPLAYS the
  -- ante -- one extra ante of blinds/shops -- instead of advancing or winning for free.
  do
    local applied = false
    local stub = { shop_phase = function(run)
      if not applied then applied = true; run._ante_back = (run._ante_back or 0) + 1 end
    end }
    local res = Driver.run(2, { max_ante = 1, content = stub })
    -- Assert the MECHANISM: after the ante-1 boss is cleared once, the pending -1
    -- ante REPLAYS ante 1 (more ante-1 blinds follow the cleared boss) instead of
    -- advancing or winning for free. (The old assertion -- the engine also CLEARS
    -- the replayed ante -- was outcome-brittle: any in-blind policy change cascades
    -- the seeded RNG and could flip whether this seed wins the extra blinds.)
    local first_boss_idx
    for i, r in ipairs(res.records) do
      if r.kind == "blind_result" and r.blind_type == "Boss" and r.cleared then
        first_boss_idx = i; break
      end
    end
    t.ok(first_boss_idx ~= nil, "Hieroglyph -1 ante: the ante-1 boss is cleared once")
    local replayed = 0
    for i = (first_boss_idx or 0) + 1, #res.records do
      local r = res.records[i]
      if (r.kind == "blind_result" or r.kind == "skip") and r.ante == 1 then replayed = replayed + 1 end
    end
    t.ok(replayed > 0, "Hieroglyph -1 ante: the ante is REPLAYED (ante-1 blinds continue past the boss)")
    t.ok(not res.won, "a replayed ante is not a win")
  end

  -- a death record (if the stub run dies) carries the blind context + ratio
  do
    local res = Driver.run(3, { max_ante = 3 })
    local death
    for _, r in ipairs(res.records) do if r.kind == "death" then death = r end end
    if death then
      t.ok(death.ante and death.ante >= 1, "death record has an ante")
      t.ok(death.ratio == nil or (death.ratio >= 0), "death ratio is well-formed")
    else
      t.ok(res.won ~= nil, "no death -> run completed the capped antes")
    end
  end

  -- MCTS Phase 1: Driver.fork deep-copies the run data + gives a fresh independent rng
  do
    local World = require("sim.world")
    local run = World.new_run(12345)
    run.ante = 3; run.round = 5; run.economy.dollars = 20
    run.jokers = { { key = "j_cavendish" }, { key = "j_hanging_chad" } }
    local fork = Driver.fork(run)
    -- independence: mutating the fork must not touch the original
    fork.economy.dollars = 999
    fork.jokers[#fork.jokers + 1] = { key = "j_baron" }
    fork.deck[1].rank = "__X__"
    t.eq(run.economy.dollars, 20, "fork is independent: original dollars unchanged")
    t.eq(#run.jokers, 2, "fork is independent: original jokers unchanged")
    t.ok(run.deck[1].rank ~= "__X__", "fork is independent: original deck unchanged")
    -- faithful copy + fresh valid rng
    t.eq(fork.ante, 3, "fork copies ante")
    t.eq(#fork.deck, #run.deck, "fork copies the full deck")
    t.ok(type(fork.rng) == "function", "fork has a fresh rng function")
    local r = fork.rng(); t.ok(r >= 0 and r < 1, "fork rng yields [0,1)")
    -- reproducible with an explicit private seed (deterministic rollouts)
    local f1, f2 = Driver.fork(run, 777), Driver.fork(run, 777)
    t.ok(math.abs(f1.rng() - f2.rng()) < 1e-12, "same priv_seed reproduces the rng stream")
  end

  -- MCTS Phase 2: Driver.rollout reuses the real loop (opts.run + silent) and returns a leaf value.
  -- A silent rollout from a FRESH run must reproduce Driver.run's outcome for the same seed (the
  -- opts.run/silent branches must not change behaviour). Stub content -> fast, ante-1 cap.
  do
    local World = require("sim.world")
    for _, seed in ipairs({ 7, 13, 21 }) do
      local ref  = Driver.run(seed, { max_ante = 1 })
      local ro   = Driver.rollout(World.new_run(seed), { horizon = 1 })
      t.eq(tostring(ro.won), tostring(ref.won), "rollout won matches Driver.run (seed " .. seed .. ")")
      t.eq(tostring(ro.death_ante), tostring(ref.death_ante), "rollout death_ante matches (seed " .. seed .. ")")
      t.ok(type(ro.value) == "number", "rollout returns a numeric leaf value")
      t.ok(type(ro.survived) == "boolean", "rollout reports survived")
    end
  end
end
