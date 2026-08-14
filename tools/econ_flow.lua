-- tools/econ_flow.lua
-- DOES THE ENGINE UNDER-ACQUIRE ECONOMY FROM ANTE 3 ON? (WINRATE_V3_PLAN 18g Tier 3)
--
-- Every other route to the human's 2-4x income advantage is closed: early STOCK (`ecap3bank`
-- -0.073, `hoard*` all negative), skipping (`noskip` 68/67), rerolls (0 ordering inversions across
-- 1295 shops) and unused-hand banking (18e -- ~$9/run and downstream of board strength). The one the
-- docs named and never tested is the FLOW: *"by ante 5 they have acquired 1.5x more jokers and 1.6x
-- more economy -- just LATER."* This screens it before an arm is spent.
--
-- Both datasets carry per-ante `jokers` arrays, so "economy held at ante k" is directly comparable;
-- `joker_gain` gives acquisition timing. Economy is counted the way the engine itself defines it
-- (`joker_data` cat == "economy", or a utility joker with econ > 0 -- the same test build_plan uses).
--
-- BONUS CROSS-CHECK, free from the same parse: the LIVE records carry `metrics.growth` (the sim's do
-- not), so the human's own boards can be run through 19b's correction to see how much growth credit
-- was flat-xmult double-count on a board that actually won.
--
--   usage: lua tools/econ_flow.lua [sim_batch.jsonl]     (default sim_out/pd_play_r.jsonl)

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local JokerData = require("engine.joker_data")

local HUMAN = here .. "../data/bes_runs_live_2026-08-12.jsonl"
local SIM   = arg[1] or (here .. "../sim_out/pd_play_r.jsonl")

local function is_econ(key)
  local e = JokerData.resolve(key)
  if not e then return false end
  return (e.cat == "economy") or (e.cat == "utility" and (e.econ or 0) > 0)
end

local function jokers_of(line)
  local body = line:match('"jokers":%[(.-)%]')
  local js = {}
  if body then for k in body:gmatch('"(j_[%w_]+)"') do js[#js + 1] = k end end
  return js
end

-- econ jokers HELD at each ante, plus the mean board size, over a file's ante records
local function scan(path, label)
  local by = {}
  local fh = io.open(path)
  if not fh then print("missing " .. path); return end
  for line in fh:lines() do
    if line:match('"kind":"ante"') then
      local a = tonumber(line:match('"ante":(%d+)'))
      if a and a >= 1 and a <= 8 then
        local js = jokers_of(line)
        local ne = 0
        for _, k in ipairs(js) do if is_econ(k) then ne = ne + 1 end end
        local b = by[a]
        if not b then b = { n = 0, econ = 0, njok = 0, dollars = 0 }; by[a] = b end
        b.n = b.n + 1; b.econ = b.econ + ne; b.njok = b.njok + #js
        b.dollars = b.dollars + (tonumber(line:match('"dollars":([%-%d%.]+)')) or 0)
      end
    end
  end
  fh:close()
  print(("\n%s"):format(label))
  print(("  %-5s %6s %9s %9s %9s %9s"):format("ante", "n", "econ jok", "njokers", "econ share", "$"))
  for a = 1, 8 do
    local b = by[a]
    if b and b.n >= 3 then
      print(("  a%-4d %6d %9.2f %9.2f %8.0f%% %9.1f")
        :format(a, b.n, b.econ / b.n, b.njok / b.n,
                100 * (b.njok > 0 and b.econ / b.njok or 0), b.dollars / b.n))
    end
  end
  return by
end

-- acquisition TIMING from joker_gain: what share of econ pickups happen at ante >= 3
local function gains(path, label)
  local early, late, tot_e, tot_l = 0, 0, 0, 0
  local fh = io.open(path)
  if not fh then return end
  for line in fh:lines() do
    if line:match('"kind":"joker_gain"') then
      local a = tonumber(line:match('"ante":(%d+)')) or 1
      local k = line:match('"key":"(j_[%w_]+)"')
      if k then
        if a >= 3 then tot_l = tot_l + 1 else tot_e = tot_e + 1 end
        if is_econ(k) then
          if a >= 3 then late = late + 1 else early = early + 1 end
        end
      end
    end
  end
  fh:close()
  local tot = tot_e + tot_l
  print(("  %-22s econ gains: a1-2 %d of %d (%.0f%%)   a3+ %d of %d (%.0f%%)   all %d/%d = %.0f%%")
    :format(label, early, tot_e, tot_e > 0 and 100 * early / tot_e or 0,
            late, tot_l, tot_l > 0 and 100 * late / tot_l or 0,
            early + late, tot, tot > 0 and 100 * (early + late) / tot or 0))
end

scan(HUMAN, "HUMAN  (data/bes_runs_live_2026-08-12.jsonl -- 7 wins in 8 runs)")
scan(SIM,   "ENGINE (" .. SIM:gsub(".*/", "") .. ")")

print("\nACQUISITION TIMING (joker_gain)")
gains(HUMAN, "human")
gains(SIM, "engine")

-- ---- bonus: 19b against the human's OWN boards ------------------------------------------------
-- The live records carry metrics.growth, so the flat-xmult over-credit is directly readable.
print("\n19b CROSS-CHECK on the human's boards (live records carry metrics.growth; sim's do not)")
do
  local n, over, held = 0, 0, 0
  local fh = io.open(HUMAN)
  if fh then
    for line in fh:lines() do
      if line:match('"kind":"ante"') then
        local g = tonumber(line:match('"growth":([%-%d%.]+)'))
        if g then
          local flat = 0
          for _, k in ipairs(jokers_of(line)) do
            if JokerData.is_xmult(k) and not JokerData.is_scaling(k) then flat = flat + 1 end
          end
          n = n + 1; over = over + 0.30 * flat
          if flat > 0 then held = held + 1 end
        end
      end
    end
    fh:close()
  end
  if n > 0 then
    print(("  %d human ante-states: %.0f%% hold a FLAT xmult, mean growth over-credit %.3f/ante")
      :format(n, 100 * held / n, over / n))
  end
end
