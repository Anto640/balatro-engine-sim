-- tests/test_replay_harness.lua
-- E-9 state-replay harness smoke test (WINRATE_AUDIT_v2.md §16 E-9).
-- Captures a few decision states from one CHEAP driver run (max_ante=1, stub shop --
-- no content, so it's fast), then replays them with tiny oracle samples, asserting:
--   * the World._capture hook is read-only (hook-on run is byte-identical to hook-off);
--   * fixtures are well-formed and JSONL round-trip via util/json;
--   * replay rows are well-formed (E[frac] in [0,1], regret >= 0) and deterministic.

local World  = require("sim.world")
local Driver = require("sim.driver")
local Json   = require("util.json")
local Lib    = require("tools.replay_lib")

return function(t)
  -- hook inertness: same seed, hook off vs hook on -> byte-identical telemetry
  local baseline = Driver.run(11, { max_ante = 1 })
  local cap = {}
  World._capture = function(gs, ranked) cap[#cap + 1] = Lib.fixture_of(gs, ranked, #cap + 1) end
  local hooked = Driver.run(11, { max_ante = 1 })
  World._capture = nil
  t.eq(#hooked.records, #baseline.records, "capture hook does not change the record count")
  local ea, eb = {}, {}
  for _, r in ipairs(baseline.records) do ea[#ea + 1] = Json.encode(r) end
  for _, r in ipairs(hooked.records) do eb[#eb + 1] = Json.encode(r) end
  t.eq(table.concat(eb, "\n"), table.concat(ea, "\n"), "hook-on run is byte-identical to hook-off")
  t.ok(#cap >= 3, "captured at least a few decision states (got " .. #cap .. ")")

  -- fixture shape + JSONL round-trip
  local fix = Json.decode(Json.encode(cap[1]))
  t.eq(fix.kind, "state", "fixture kind is 'state'")
  t.eq(tonumber(fix.seed), 11, "fixture carries the run seed")
  t.ok(fix.ante == 1, "fixture carries the ante")
  t.ok(#fix.gs.hand > 0, "fixture has a drawn hand")
  t.ok(fix.gs.blind.target_chips > 0, "fixture has a blind target")
  t.ok((fix.gs.blind.hands_left or 0) >= 1, "fixture has hands left")
  t.ok(#fix.gs.deck >= 52 - 8, "fixture carries the deck")
  t.ok(type(fix.gs.run.hand_size) == "number", "fixture carries run.hand_size")

  -- replay a few fixtures with tiny samples -> well-formed rows
  local n = math.min(3, #cap)
  local rows = {}
  for i = 1, n do
    local fx = Json.decode(Json.encode(cap[i]))
    local row, err = Lib.score_state(fx, 6)
    t.ok(row ~= nil, "replay produced a row for fixture " .. i .. " (" .. tostring(err) .. ")")
    if row then
      rows[#rows + 1] = row
      t.ok(row.chosen == "PLAY" or row.chosen == "DISCARD" or row.chosen == "USE_CONSUMABLE",
        "row chosen is an action type (fixture " .. i .. ")")
      t.ok(row.frac_chosen >= 0 and row.frac_chosen <= 1, "E[frac] chosen in [0,1] (fixture " .. i .. ")")
      t.ok(row.frac_other == nil or (row.frac_other >= 0 and row.frac_other <= 1),
        "E[frac] other in [0,1] when present (fixture " .. i .. ")")
      t.ok(row.regret >= 0, "regret is non-negative (fixture " .. i .. ")")
      t.ok(row.blind ~= nil and row.seed ~= nil, "row carries seed + blind (fixture " .. i .. ")")
    end
  end

  -- replay determinism: same fixture + samples -> identical numbers
  local r1 = Lib.score_state(Json.decode(Json.encode(cap[1])), 6)
  local r2 = Lib.score_state(Json.decode(Json.encode(cap[1])), 6)
  t.eq(r1.frac_chosen, r2.frac_chosen, "replay is deterministic (frac_chosen)")
  t.eq(tostring(r1.frac_other), tostring(r2.frac_other), "replay is deterministic (frac_other)")
  t.eq(r1.chosen, r2.chosen, "replay is deterministic (chosen action)")

  -- summary shape
  local s = Lib.summarize(rows)
  t.eq(s.n, #rows, "summary counts all rows")
  t.ok(s.mean_chosen >= 0 and s.mean_chosen <= 1, "summary mean E[frac] in [0,1]")
  t.ok(s.mean_regret >= 0, "summary mean regret is non-negative")
  t.ok(s.match_pct >= 0 and s.match_pct <= 100, "summary match%% in [0,100]")
end
