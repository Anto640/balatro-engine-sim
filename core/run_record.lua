-- core/run_record.lua
-- The field builders shared by the two writers of run records: core/run_telemetry (live, bes_runs.jsonl) and
-- sim/driver (the simulator's arms). The analysis tools read both, so a field must mean the same in each;
-- building it in one place is what keeps it so. Pure: plain tables in, plain tables out.

local RunRecord = {}

-- The owned jokers' keys, in board order.
function RunRecord.joker_keys(jokers)
  local out = {}
  for _, j in ipairs(jokers or {}) do out[#out + 1] = j.key or "?" end
  return out
end

-- Total levels gained across all hand types (a level-1 hand counts 0).
function RunRecord.hand_level_sum(hand_levels)
  local s = 0
  for _, h in pairs(hand_levels or {}) do s = s + math.max(0, (h.level or 1) - 1) end
  return s
end

-- name -> level, LEVELED hands only (the base-1 entries are noise in a log line); nil when no hand is leveled.
function RunRecord.hand_level_map(hand_levels)
  local m, any = {}, false
  for name, h in pairs(hand_levels or {}) do
    local lvl = h.level or 1
    if lvl > 1 then m[name] = lvl; any = true end
  end
  return any and m or nil
end

return RunRecord
