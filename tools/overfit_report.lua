-- tools/overfit_report.lua
-- Difference-in-differences report for tools/overfit_test.sh: does the engine lose MORE than a
-- never-tuned reference policy when it leaves the seed pool it was selected on?
--
--   usage: lua tools/overfit_report.lua <engine_tuned> <engine_heldout> <expert_tuned> <expert_heldout>
--
-- Reports each cell's mean/sd/SE, both simple differences, the DiD with its SE and t, and --
-- crucially -- the MINIMUM DETECTABLE EFFECT at the n actually run. Per CLAUDE.md's revised #1
-- tuning rule, a null result is only meaningful next to the MDE that produced it.

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")
local Json = require("util.json")

local SHIPPED_ARC = 0.487   -- total progress gained by every lever ever kept (3.345 -> 3.832)

-- per-seed progress, matching tools/analyze_runs.lua's definition (win = 8.0)
local function progress(path)
  local st = {}
  local fh = io.open(path, "r")
  if not fh then return nil end
  for line in fh:lines() do
    local ok, r = pcall(Json.decode, line)
    if ok and type(r) == "table" and r.seed then
      if r.kind == "win" then st[r.seed] = 8.0
      elseif r.kind == "death" then
        local bi = (r.blind_type == "Small" and 0) or (r.blind_type == "Big" and 1) or 2
        local frac = (r.ratio and math.min(1, r.ratio)) or 0
        st[r.seed] = (r.ante - 1) + (bi + frac) / 3
      end
    end
  end
  fh:close()
  local v = {}
  for _, x in pairs(st) do v[#v + 1] = x end
  if #v < 2 then return nil end
  local s = 0
  for _, x in ipairs(v) do s = s + x end
  local m = s / #v
  local q = 0
  for _, x in ipairs(v) do q = q + (x - m) ^ 2 end
  local sd = math.sqrt(q / (#v - 1))
  return { mean = m, sd = sd, n = #v, se = sd / math.sqrt(#v) }
end

local names = { "engine tuned", "engine held-out", "expert tuned", "expert held-out" }
local cells = {}
for i = 1, 4 do
  cells[i] = progress(arg[i])
  if not cells[i] then
    io.stderr:write("missing or empty: " .. tostring(arg[i]) .. "\n")
    os.exit(1)
  end
end

print(string.format("%-18s %8s %8s %6s %8s", "cell", "mean", "sd", "n", "SE"))
for i = 1, 4 do
  local c = cells[i]
  print(string.format("%-18s %8.3f %8.3f %6d %8.3f", names[i], c.mean, c.sd, c.n, c.se))
end

local d_eng = cells[2].mean - cells[1].mean
local d_exp = cells[4].mean - cells[3].mean
local se_eng = math.sqrt(cells[2].se ^ 2 + cells[1].se ^ 2)
local se_did = math.sqrt(cells[1].se ^ 2 + cells[2].se ^ 2 + cells[3].se ^ 2 + cells[4].se ^ 2)
local did = d_eng - d_exp

print()
print(string.format("engine  held-out - tuned = %+.3f   (SE %.3f, t %.2f)", d_eng, se_eng, d_eng / se_eng))
print(string.format("expert  held-out - tuned = %+.3f   <- difficulty control (never tuned)", d_exp))
print(string.format("DIFFERENCE-IN-DIFFERENCES = %+.3f   (SE %.3f, t %.2f)", did, se_did, did / se_did))
print()
local mde = 2.8 * se_did
print(string.format("MDE at this n (80%% power, two-sided 0.05) = %.3f", mde))
print(string.format("the ENTIRE shipped arc, for scale               = %.3f", SHIPPED_ARC))
if mde > SHIPPED_ARC then
  print("  ** UNDERPOWERED: this run cannot detect an arc-sized overfitting effect. **")
  print(string.format("  need ~n=%d per cell to reach MDE < the arc.",
    math.ceil(cells[1].n * (mde / SHIPPED_ARC) ^ 2)))
else
  print("  powered to detect an arc-sized effect.")
  if math.abs(did / se_did) >= 1.96 then
    print(did < 0 and "  VERDICT: significant OVERFITTING -- retained gains do not fully generalize."
                   or "  VERDICT: significant effect in the OPPOSITE direction (engine generalizes better).")
  else
    print("  VERDICT: no significant overfitting at this power.")
  end
end
