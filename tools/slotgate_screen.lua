-- tools/slotgate_screen.lua
-- SCREEN THE §25c PROPOSAL WITHOUT IMPLEMENTING IT.
--
-- §25b measured that `P.pace` is over-confident by an order of magnitude and STRUCTURALLY so: at
-- ante 4 the engine believes it projects 12.1x the ante-8 requirement while 57 runs die at antes
-- 3-5, and realized capacity growth (4.71 / 2.57 / 1.95 / 1.44 / ...) is nothing like the single
-- geometric rate `growth_factor` projects. The diagnosed cause is that THREE of its five terms are
-- acquisition-driven --
--     1.25   "baseline: ~1 acquisition per ante"
--     money/160   "cash -> more shop buys"
--     econ/40     "passive income -> more buys"
-- -- and §5a measured the board saturating (`slots_free` = 0.00 by ante 5), so on a full board none
-- of them can be realized. The proposal is to gate exactly those terms on remaining slot capacity.
--
-- This models the proposal over states the engine really reached and reports what it would do to the
-- pace verdict. It changes NO engine code: the point is to know the size before spending an arm, and
-- to know it before writing the change rather than after.
--
--   proposed:  g = 1 + f(slots_free) * (0.25 + min(money,40)/160 + min(econ,12)/40)
--                    + 0.30*xgrow + 0.15*scaling + 0.05*min(hand_lv,12)
--   with f = min(1, slots_free): a new joker cannot land on a full board. f(0)=0 is deliberate --
--   swaps are real but their value is priced by SA.UPGRADE_MARGIN, not by a growth RATE, and any
--   f(0)>0 would be a new tuned constant, which is what §25c is trying to avoid.
--
-- ⚠ It recovers `g` from `pace_margin` (exact, see pacing_screen.lua) and rebuilds the proposed `g`
-- from the recorded feature vector, so both numbers are the engine's own.
--
--   usage: lua tools/slotgate_screen.lua <batch.jsonl> [more.jsonl ...]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")
local Mechanics = require("engine.mechanics")

local REQ8 = Mechanics.blind_requirement(8, "Boss")
local function num(s, k) return tonumber(s:match('"' .. k .. '":([%-%d%.e%+]+)')) end

-- the advisor's band assignment (shop_advisor 390-394 / 426-430 / 468-469, build_plan 597-599)
local function band(cap, gr, ante)
  local fail
  for a = ante, 8 do
    if cap * gr ^ (a - ante) < Mechanics.blind_requirement(a, "Boss") then fail = a; break end
  end
  local mg = cap * gr ^ math.max(0, 8 - ante) / math.max(1, REQ8)
  local urgent = (fail ~= nil) and (fail <= ante + 1)
  local m = (mg >= 1.8 and 4) or (mg >= 1.5 and 3) or (mg >= 1.3 and 2) or (mg >= 0.15 and 1) or 0
  return (urgent and "U" or (fail and "B" or "P")) .. m, mg
end

for _, f in ipairs({ ... }) do
  local by, n, flips = {}, 0, 0
  local fh = io.open(f)
  if not fh then print("missing " .. f)
  else
    for line in fh:lines() do
      if line:match('"kind":"ante"') then
        local m       = line:match('"metrics":(.*)$') or line
        local cap     = num(m, "capacity")
        local margin  = num(m, "pace_margin")
        local ante    = num(line, "ante")
        local slots   = num(m, "slots_free")
        local njok    = num(m, "njokers")
        local jslots  = num(m, "joker_slots")
        local money   = num(m, "dollars") or 0
        local econ    = num(m, "econ_total") or 0
        local hand_lv = num(m, "hand_lv_sum") or 0
        local xm, xs  = num(m, "xmult"), num(m, "xmult_scaling")
        local scaling = num(m, "scaling") or 0
        local k = ante and math.max(0, 8 - ante) or 0
        if not slots and njok and jslots then slots = math.max(0, jslots - njok) end
        if cap and margin and ante and slots and xm and xs and cap > 0 and k > 0 and margin > 0 then
          local g_now = (margin * math.max(1, REQ8) / cap) ^ (1 / k)
          local acq = 0.25 + math.min(money, 40) / 160 + math.min(econ, 12) / 40
          local g_new = 1 + math.min(1, slots) * acq
                          + 0.30 * (xs or 0) + 0.15 * scaling
                          + 0.05 * math.min(hand_lv, 12)
          g_new = math.max(1.0, math.min(3.0, g_new))
          local b1, m1 = band(cap, g_now, ante)
          local b2, m2 = band(cap, g_new, ante)
          n = n + 1
          if b1 ~= b2 then flips = flips + 1 end
          local b = by[ante] or { n = 0, g1 = 0, g2 = 0, m1 = 0, m2 = 0, fl = 0, full = 0 }
          b.n = b.n + 1; b.g1 = b.g1 + g_now; b.g2 = b.g2 + g_new
          b.m1 = b.m1 + m1; b.m2 = b.m2 + m2
          if b1 ~= b2 then b.fl = b.fl + 1 end
          if slots < 1 then b.full = b.full + 1 end
          by[ante] = b
        end
      end
    end
    fh:close()
    print(("%s   %d ante-states   BAND FLIPS %d (%.1f%%)")
      :format(f:gsub(".*/", ""), n, flips, n > 0 and 100 * flips / n or 0))
    print(("  %-5s %6s %8s %7s %7s %10s %10s %8s")
      :format("ante", "n", "full bd", "g now", "g new", "margin now", "margin new", "flip%"))
    for a = 1, 8 do
      local b = by[a]
      if b and b.n >= 10 then
        print(("  a%-4d %6d %7.0f%% %7.2f %7.2f %10.1f %10.1f %7.0f%%")
          :format(a, b.n, 100 * b.full / b.n, b.g1 / b.n, b.g2 / b.n,
                  b.m1 / b.n, b.m2 / b.n, 100 * b.fl / b.n))
      end
    end
  end
end
