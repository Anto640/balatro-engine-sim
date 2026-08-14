-- tools/pacing_screen.lua
-- FIRING-RATE SCREEN for the growth_factor correction (WINRATE_V3_PLAN 19).
--
-- THE QUESTION a screen must answer before an arm is spent: how often does the change alter the
-- DECISION, not just the number? `growth_factor` feeds ONE consumer -- P.pace's on_pace/urgent
-- verdict -- so the firing rate is the rate at which dropping flat-xmult growth credit FLIPS that
-- verdict. Below the frequency ceiling (CLAUDE.md) a 45-minute arm cannot distinguish a small
-- effect from a change that barely executes, and this project has lost arms to exactly that.
--
-- Every quantity needed is already in the per-ante telemetry, so this costs nothing to run:
--   metrics.capacity                              cap
--   features.xmult - features.xmult_scaling       the FLAT xmult count (sim/driver.lua:98-99)
--
-- `growth` itself is NOT recorded -- but it is exactly recoverable, because P.pace stores
--     pace_margin = cap * g^(8-ante) / max(1, req8)
-- so  g = (pace_margin * req8 / cap) ^ (1/(8-ante)).  Exact, not an approximation.
--
-- The corrected factor is g' = clamp(g - 0.30*flat, 1, 3), and on_pace is then recomputed by
-- replaying P.pace's FULL loop -- the first future ante whose Boss requirement the projection
-- misses -- not just the ante-8 test. Requirements grow ~2x/ante and g is usually below that, so
-- ante 8 is normally the binding constraint, but "normally" is not "always" and the whole point
-- of a screen is to not hand-wave the thing being screened.
--
--   usage: lua tools/pacing_screen.lua <batch.jsonl> [more.jsonl ...]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")
local Mechanics = require("engine.mechanics")

local REQ8 = Mechanics.blind_requirement(8, "Boss")

local function num(s, k)
  local v = s:match('"' .. k .. '":([%-%d%.e%+]+)')
  return tonumber(v)
end

for _, f in ipairs({ ... }) do
  local n, fired, held_flat, sum_dg, band_fired = 0, 0, 0, 0, 0
  local by = {}
  local fh = io.open(f)
  if not fh then
    print("missing " .. f)
  else
    for line in fh:lines() do
      if line:match('"kind":"ante"') then
        local m = line:match('"metrics":(.*)$') or line
        local cap    = num(m, "capacity")
        local margin = num(m, "pace_margin")
        local ante   = num(line, "ante")
        local xm     = num(m, "xmult")
        local xs     = num(m, "xmult_scaling")
        local k      = ante and math.max(0, 8 - ante) or 0
        if cap and margin and ante and xm and xs and cap > 0 and k > 0 and margin > 0 then
          local g = (margin * math.max(1, REQ8) / cap) ^ (1 / k)
          local flat = math.max(0, xm - xs)
          local g2 = math.max(1.0, math.min(3.0, g - 0.30 * flat))
          -- replay P.pace's loop: on_pace iff EVERY future ante's Boss requirement is met
          local function on_pace(gr)
            for a = ante, 8 do
              if cap * gr ^ (a - ante) < Mechanics.blind_requirement(a, "Boss") then return false end
            end
            return true
          end
          local on1, on2 = on_pace(g), on_pace(g2)
          -- ⚠ on_pace ALONE understates this badly. `pace.margin` drives four more threshold
          -- bands, and a growth change is raised to the power (8-ante) before it reaches them:
          --   shop_advisor:390-394  weights      urgent / behind / margin>=1.5 / else
          --   shop_advisor:426-430  pack_need    urgent / behind / >=1.8 / >=1.3 / else
          --   shop_advisor:468-469  proj_damp    urgent / behind / else
          --   build_plan:597-599    invest+commit  margin >= HOPELESS_MARGIN (0.15)
          -- The behavioural firing rate is the rate at which ANY of those band assignments moves.
          local function band(gr)
            local fail
            for a = ante, 8 do
              if cap * gr ^ (a - ante) < Mechanics.blind_requirement(a, "Boss") then fail = a; break end
            end
            local mg = cap * gr ^ k / math.max(1, REQ8)
            local urgent = (fail ~= nil) and (fail <= ante + 1)
            local m = (mg >= 1.8 and 4) or (mg >= 1.5 and 3) or (mg >= 1.3 and 2)
                   or (mg >= 0.15 and 1) or 0
            return (urgent and "U" or (fail and "B" or "P")) .. m
          end
          local b1, b2 = band(g), band(g2)
          if b1 ~= b2 then band_fired = band_fired + 1 end
          n = n + 1
          if flat > 0 then held_flat = held_flat + 1 end
          sum_dg = sum_dg + (g - g2)
          local b = by[ante]
          if not b then b = { n = 0, flip = 0, dg = 0, flat = 0, bf = 0 }; by[ante] = b end
          b.n = b.n + 1; b.dg = b.dg + (g - g2); b.flat = b.flat + flat
          if b1 ~= b2 then b.bf = b.bf + 1 end
          if on1 ~= on2 then fired = fired + 1; b.flip = b.flip + 1 end
        end
      end
    end
    fh:close()
    print(("%s   %d ante-states"):format(f:gsub(".*/", ""), n))
    if n > 0 then
      print(("  holds a FLAT xmult : %.1f%%     mean growth over-credit : %.3f per ante")
        :format(100 * held_flat / n, sum_dg / n))
      print(("  ON_PACE verdict flips     : %d  (%.1f%% of ante-states)")
        :format(fired, 100 * fired / n))
      print(("  ADVISOR BAND flips (real) : %d  (%.1f%% of ante-states)")
        :format(band_fired, 100 * band_fired / n))
      io.write("  by ante: ")
      for a = 1, 8 do
        local b = by[a]
        if b and b.n >= 10 then
          io.write(("a%d band%.0f%% pace%.0f%% dg%.2f (n%d)   ")
            :format(a, 100 * b.bf / b.n, 100 * b.flip / b.n, b.dg / b.n, b.n))
        end
      end
      print("")
    end
  end
end
