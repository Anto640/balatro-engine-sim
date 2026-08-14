-- tools/death_wallet.lua
-- HOW MUCH MONEY IS THE ENGINE HOLDING WHEN IT DIES?
--
-- A documented pattern with no mechanism until now: *"The engine dies holding the interest cap.
-- From ante 5 the median death holds $26; 28% of all deaths hold >= $25... so $26 simply does not
-- buy anything that saves a run."* WINRATE_V3_PLAN 11a supplies the mechanism -- `SA.free_spend`
-- drops discontinuously to $0 at exactly $25 while `bankroll_plan` TARGETS $25, so the engine
-- parks on the one wallet value where every purchase is maximally expensive.
--
-- That makes this a MECHANISM CHECK for the level_gain correction (12), and one the progress
-- metric cannot see. The correction makes Celestial packs worth buying (36% -> 65% of affordable
-- offers rated positive), i.e. it finally gives banked cash something to convert into. So:
--
--   PRE-REGISTERED PREDICTION -- if the fix works through the channel claimed, the share of
--   deaths holding >= $25 should FALL, and it should fall most from ante 5 on.
--
-- If progress moves but this does not, the gain came from somewhere else and the mechanism story
-- is wrong. If this moves but progress does not, the conversion happened and did not pay -- which
-- is `levelbuy`'s verdict generalising (12c, explanation 3).
--
-- Usage:  lua tools/death_wallet.lua <a.jsonl> [b.jsonl ...]

local function scan(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local n, cap, sum, wins = 0, 0, 0, 0
  local late_n, late_cap, late_sum = 0, 0, 0
  local held = {}
  for line in f:lines() do
    local kind = line:gsub('"build_plan":%b{}', ''):match('"kind":"([^"]*)"')
    if kind == "death" then
      local d = tonumber(line:match('"dollars":(%-?%d+)')) or 0
      local a = tonumber(line:match('"ante":(%d+)')) or 1
      n = n + 1; sum = sum + d
      held[#held + 1] = d
      if d >= 25 then cap = cap + 1 end
      if a >= 5 then
        late_n = late_n + 1; late_sum = late_sum + d
        if d >= 25 then late_cap = late_cap + 1 end
      end
    elseif kind == "win" then
      wins = wins + 1
    end
  end
  f:close()
  table.sort(held)
  local med = #held > 0 and held[math.floor(#held / 2) + 1] or 0
  return { n = n, wins = wins, cap = cap, mean = n > 0 and sum / n or 0, median = med,
           late_n = late_n, late_cap = late_cap,
           late_mean = late_n > 0 and late_sum / late_n or 0 }
end

print(("  %-26s %6s %6s %10s %9s %14s %12s"):format(
  "file", "deaths", "wins", "mean $", "median $", ">=$25 at death", "a5+ >=$25"))
for i = 1, #arg do
  local r = scan(arg[i])
  if r then
    print(("  %-26s %6d %6d %10.1f %9d %8d %4.0f%% %6d %4.0f%%"):format(
      arg[i]:match("[^/\\]+$"):gsub("%.jsonl$", ""), r.n, r.wins, r.mean, r.median,
      r.cap, 100 * r.cap / math.max(1, r.n),
      r.late_cap, 100 * r.late_cap / math.max(1, r.late_n)))
  else
    print(("  %-26s (missing)"):format(arg[i]))
  end
end
