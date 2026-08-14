-- tools/level_scale_screen.lua
-- HOW MUCH DOES THE DERIVED `CV.level_scale` ACTUALLY MOVE, ON BOARDS THAT REALLY OCCURRED?
--
-- WINRATE_V3_PLAN 20 replaces a board-blind ramp, clamp(1 + (8-ante)*0.45, 1, 4), with a sum over
-- the remaining antes of min(1, g^(k-ante) * need(ante)/need(k)). The derivation is sound but the
-- CONSEQUENCE is an empirical question, and a bad one to guess at: the factor multiplies every
-- leveling valuation, so a uniform halving is a different change from a re-SHAPING.
--
-- The per-ante telemetry carries everything `Pacing.growth_factor` reads -- `jokers`, `dollars`,
-- `hand_levels` -- so this replays both formulas over states the engine really reached. No sim.
--
-- ⚠ It reports the RATIO new/old, not a firing rate, because there is no threshold here to cross:
-- the factor is continuous and multiplies a value that competes against every other purchase. A
-- ratio near 1 at the common antes would mean "not worth an arm"; a systematic re-shape would not.
--
--   usage: lua tools/level_scale_screen.lua <batch.jsonl> [more.jsonl ...]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local GS     = require("model.game_state")
local CV     = require("engine.consumable_value")
local Pacing = require("engine.pacing")

local function old_ramp(a) return math.max(1, math.min(4, 1 + (8 - a) * 0.45)) end

-- pull the jokers array out of a record without a JSON parser: "jokers":["j_a","j_b"]
local function jokers_of(line)
  local body = line:match('"jokers":%[(.-)%]')
  local js = {}
  if body then for k in body:gmatch('"(j_[%w_]+)"') do js[#js + 1] = { key = k } end end
  return js
end

-- "hand_levels":{"Two Pair":2,"Flush":3}
local function levels_of(line)
  local body = line:match('"hand_levels":{(.-)}')
  local hl = {}
  if body then for name, lv in body:gmatch('"([^"]+)":(%d+)') do hl[name] = { level = tonumber(lv) } end end
  return hl
end

for _, f in ipairs({ ... }) do
  local by, n = {}, 0
  local fh = io.open(f)
  if not fh then
    print("missing " .. f)
  else
    for line in fh:lines() do
      -- the per-ante record only; a death record's board is the one that failed
      if line:match('"kind":"ante"') then
        local ante = tonumber(line:match('^{"ante":(%d+)') or line:match('"ante":(%d+)'))
        local dollars = tonumber(line:match('"dollars":([%-%d%.]+)')) or 0
        if ante and ante >= 1 and ante <= 8 then
          local gs = GS.new{
            deck = {}, jokers = jokers_of(line), meta = { ante = ante },
            economy = { dollars = dollars, interest_cap = 5 },
            run = { hand_levels = levels_of(line), joker_slots = 5, consumable_slots = 2 },
          }
          local o, nw = old_ramp(ante), CV.level_scale(gs)
          local b = by[ante]
          if not b then b = { n = 0, o = 0, nw = 0, g = 0, up = 0 }; by[ante] = b end
          b.n = b.n + 1; b.o = b.o + o; b.nw = b.nw + nw
          b.g = b.g + Pacing.growth_factor(gs)
          if nw > o then b.up = b.up + 1 end
          n = n + 1
        end
      end
    end
    fh:close()
    print(("%s   %d ante-states"):format(f:gsub(".*/", ""), n))
    print(("  %-5s %6s %7s %7s %7s %8s"):format("ante", "n", "g", "old", "new", "new/old"))
    local so, sn = 0, 0
    for a = 1, 8 do
      local b = by[a]
      if b and b.n >= 5 then
        so = so + b.o; sn = sn + b.nw
        print(("  a%-4d %6d %7.2f %7.2f %7.2f %8.2f   (%.0f%% raised)")
          :format(a, b.n, b.g / b.n, b.o / b.n, b.nw / b.n, (b.nw / b.n) / (b.o / b.n),
                  100 * b.up / b.n))
      end
    end
    if so > 0 then print(("  POOLED new/old = %.2f"):format(sn / so)) end
  end
end
