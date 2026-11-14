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

-- name -> level, LEVELED hands only (the base-1 entries are noise in a log line).
-- With no leveled hand: nil, or an empty map when `keep_empty` (the simulator's records have always carried the
-- empty map and the live ones have always omitted the field; both are kept as they are).
function RunRecord.hand_level_map(hand_levels, keep_empty)
  local m, any = {}, false
  for name, h in pairs(hand_levels or {}) do
    local lvl = h.level or 1
    if lvl > 1 then m[name] = lvl; any = true end
  end
  if any or keep_empty then return m end
  return nil
end

return RunRecord
