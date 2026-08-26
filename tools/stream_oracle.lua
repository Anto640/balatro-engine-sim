-- tools/stream_oracle.lua -- MCTS_PLAN Phase 0a: the observed-stream keystone-availability oracle.
--
-- THE QUESTION (the gate for the whole MCTS build): do winning LINES exist in LOST runs' OBSERVED offer
-- streams, or is the 2.5% ceiling genuinely supply-limited (the 2026-07-14 MCTS_PLAN claim)? The winning
-- archetype (supermodular_headroom, 2026-08): boards are ~86% MULTIPLIER (xmult/copier/retrigger), needing
-- >=2 stacked multiplier keystones + leveling. So the cheapest operationalization of "a winning line
-- existed" is: were >=2 AFFORDABLE multiplier keystones actually OFFERED across this lost run's shops/packs?
--
-- This is the OBSERVED-stream LOWER bound (Phase 0a): it counts only offers the engine's own (thin) policy
-- surfaced, and CANNOT see the contents of packs the engine declined to open (packs roll contents only on
-- open) -- so it UNDER-counts the policy-reachable supply (Phase 0b, a re-sim, adds those). A lower bound
-- that already shows keystones were available in >>2.5% of lost runs refutes the supply ceiling on the sim's
-- own runs. Pure analysis over arm JSONL -- no sim runs, no engine calls.
--
--   usage: luajit tools/stream_oracle.lua sim_out/<arm>.jsonl [more.jsonl ...]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")
local Json = require("util.json")
local JD   = require("engine.joker_data")

-- role: multiplier (copier|xmult|retrigger) vs additive -- same split as supermodular_headroom.lua
local function role(key)
  if JD.has_tag(key, "copy") then return "copier" end
  local e = JD.get(key)
  if (e and e.cat == "retrigger") or JD.has_tag(key, "retrigger") then return "retrigger" end
  if JD.is_xmult(key) then return "xmult" end
  return "additive"
end
local function is_mult(key) return role(key) ~= "additive" end
local function is_planet(rec) -- a leveling source (Planet consumable or Celestial-pack card)
  local s = (rec.set or ""):lower(); local k = tostring(rec.key or rec.name or ""):lower()
  return s == "planet" or k:match("^c_") and (k:match("mercury") or k:match("venus") or k:match("earth")
    or k:match("mars") or k:match("jupiter") or k:match("saturn") or k:match("uranus") or k:match("neptune")
    or k:match("pluto") or k:match("planet_x") or k:match("ceres") or k:match("eris")) ~= nil
end

local files = {}
for i = 1, #arg do files[#files + 1] = arg[i] end
if #files == 0 then io.stderr:write("usage: luajit tools/stream_oracle.lua <arm.jsonl> [...]\n"); os.exit(1) end

-- group records by run
local runs, order = {}, {}
for _, path in ipairs(files) do
  local fh = io.open(path, "r"); if not fh then io.stderr:write("cannot open "..path.."\n"); os.exit(1) end
  for line in fh:lines() do
    if line:match("%S") then
      local ok, r = pcall(Json.decode, line)
      if ok and type(r) == "table" and r.seed then
        local key = path .. "::" .. tostring(r.seed)
        local run = runs[key]
        if not run then run = { recs = {}, outcome = nil, death_ante = 0 }; runs[key] = run; order[#order+1] = run end
        run.recs[#run.recs+1] = r
        if r.kind == "win" then run.outcome = "win"; run.death_ante = 9
        elseif r.kind == "death" then run.outcome = "death"; run.death_ante = r.ante or run.death_ante end
      end
    end
  end
  fh:close()
end

-- per-run: count AFFORDABLE distinct multiplier keystones offered, leveling sources offered, and what was taken
local function analyze(run)
  local mult_offered, mult_aff = {}, {}   -- distinct keys offered / offered-and-affordable-at-that-shop
  local lvl_offered = 0
  local mult_taken = {}
  for _, r in ipairs(run.recs) do
    if r.kind == "shop" then
      local d = r.dollars or 0
      for _, j in ipairs(r.offer_jokers or {}) do
        if j.key and is_mult(j.key) then
          mult_offered[j.key] = true
          if (j.cost or 999) <= d then mult_aff[j.key] = true end
        end
      end
      for _, c in ipairs(r.offer_consumables or {}) do if is_planet(c) and (c.cost or 999) <= d then lvl_offered = lvl_offered + 1 end end
    elseif r.kind == "pack" then
      for _, it in ipairs(r.items or {}) do
        local k = (type(it)=="table") and (it.key or it.joker and it.joker.key) or it
        if k and JD.get(k) and is_mult(k) then mult_offered[k] = mult_offered[k] end  -- packs: contents seen only if opened
        if type(it)=="table" and is_planet(it) then lvl_offered = lvl_offered + 1 end
      end
    elseif r.kind == "joker_gain" and r.key and is_mult(r.key) then
      mult_taken[r.key] = true
    end
  end
  local function count(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end
  return count(mult_offered), count(mult_aff), lvl_offered, count(mult_taken)
end

local nwin, nloss = 0, 0
local buckets = {}  -- for lost runs: histogram of affordable-multipliers-offered
local loss_ge2, loss_ge2_lvl, loss_taken_lt2 = 0, 0, 0
local sum_offered, sum_aff, sum_taken = 0, 0, 0
for _, run in ipairs(order) do
  if run.outcome == "win" then nwin = nwin + 1
  elseif run.outcome == "death" then
    nloss = nloss + 1
    local off, aff, lvl, taken = analyze(run)
    buckets[aff] = (buckets[aff] or 0) + 1
    sum_offered = sum_offered + off; sum_aff = sum_aff + aff; sum_taken = sum_taken + taken
    if aff >= 2 then loss_ge2 = loss_ge2 + 1; if lvl >= 1 then loss_ge2_lvl = loss_ge2_lvl + 1 end
      if taken < 2 then loss_taken_lt2 = loss_taken_lt2 + 1 end end
  end
end

local function pct(a,b) return b>0 and string.format("%.0f%%", 100*a/b) or "-" end
print(string.rep("=", 68))
print("MCTS Phase 0a -- OBSERVED-STREAM keystone-availability oracle (LOWER bound)")
print(string.rep("=", 68))
print(string.format("files: %s", table.concat(files, ", ")))
print(string.format("runs: %d win / %d loss", nwin, nloss))
print("")
print("LOST runs -- affordable MULTIPLIER keystones (xmult/copier/retrigger) OFFERED across the stream:")
for k = 0, 8 do if buckets[k] then print(string.format("   %d offered: %4d runs (%s of losses)", k, buckets[k], pct(buckets[k], nloss))) end end
print("")
print(string.format("LOST runs OFFERED >= 2 affordable multiplier keystones : %d / %d  (%s)", loss_ge2, nloss, pct(loss_ge2, nloss)))
print(string.format("   ...AND >= 1 leveling source offered                 : %d / %d  (%s)", loss_ge2_lvl, nloss, pct(loss_ge2_lvl, nloss)))
print(string.format("   ...of those >=2-offered, run TOOK < 2 (passed up)   : %d / %d  (%s)", loss_taken_lt2, loss_ge2, pct(loss_taken_lt2, loss_ge2)))
print(string.format("avg per lost run: multipliers offered %.2f / affordable %.2f / taken %.2f", sum_offered/math.max(1,nloss), sum_aff/math.max(1,nloss), sum_taken/math.max(1,nloss)))
print("")
print("READING: if >>2.5% of LOST runs were OFFERED >=2 affordable multiplier keystones (+leveling) and")
print("PASSED THEM UP, the winning PIECES were in the observed stream -> the 2.5% ceiling is POLICY, not")
print("supply, on the sim's own runs (and Phase 0b's policy-reachable stream only ADDS more). If ~2.5%, the")
print("2026-07-14 supply-ceiling stands for the OBSERVED stream (then 0b tests whether reroll/pack policy lifts it).")
