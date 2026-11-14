-- tests/test_run_record.lua
-- core/run_record: the field builders the live telemetry and the simulator's records share.

local RunRecord = require("core.run_record")

return function(t)
  local keys = RunRecord.joker_keys({ { key = "j_joker" }, {}, { key = "j_sly" } })
  t.eq(table.concat(keys, ","), "j_joker,?,j_sly", "joker_keys: board order, '?' for a keyless joker")
  t.eq(#RunRecord.joker_keys(nil), 0, "joker_keys: no board -> empty")

  local levels = { Pair = { level = 3 }, Flush = { level = 1 }, ["High Card"] = {}, Straight = { level = 2 } }
  t.eq(RunRecord.hand_level_sum(levels), 3, "hand_level_sum: levels gained above 1")
  t.eq(RunRecord.hand_level_sum(nil), 0, "hand_level_sum: no levels -> 0")

  local m = RunRecord.hand_level_map(levels)
  t.eq(m.Pair, 3, "hand_level_map: a leveled hand")
  t.eq(m.Straight, 2, "hand_level_map: another")
  t.eq(m.Flush, nil, "hand_level_map: base-level hands are left out")

  t.eq(RunRecord.hand_level_map({ Flush = { level = 1 } }), nil, "hand_level_map: nothing leveled -> nil (live records omit it)")
  local e = RunRecord.hand_level_map({ Flush = { level = 1 } }, true)
  t.ok(type(e) == "table" and next(e) == nil, "hand_level_map: keep_empty -> an empty map (the simulator's records)")
end
