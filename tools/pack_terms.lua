-- tools/pack_terms.lua
-- WHY IS A CELESTIAL PACK WORTH −2.90?
--
-- The pack channel is the project's #1 measured gap (WINRATE_V3_PLAN 5z: engine 1.36 packs/ante
-- vs human 6.10) and Celestial is its worst cell. Reading existing telemetry got as far as the
-- SHAPE of the problem but no further, because the record stores only the final `value`:
--
--   Celestial pack value by ante   : a1 +1.55 | a2 −2.13 | a3 −2.01 | a4 −0.89 | a5 −0.14 | a7 +0.13
--   ...by dollars held (antes 2-4) : $0-3 +1.46 | $4-7 −2.79 | $8-14 −2.90 | $15-24 −2.00 | $25+ −0.66
--
-- Two things stand out and neither can be settled from the aggregate. The value is MOST negative
-- exactly where the pack is affordable, and POSITIVE when the engine is too broke to buy -- which
-- is the signature of `econ_floor_penalty`, whose shape is a band-stop: it is 0 below the floor
-- (no NEW shortfall), peaks at ~2.4 for $5-10, and returns to 0 at $15+. And the engine is not
-- pack-averse in general -- Buffoon is +13.27 at ante 1 and +2.79 at ante 3, Arcana is positive
-- throughout. It is Celestial and Standard specifically.
--
-- So this logs the ACTUAL terms of
--     value = w_score * 5 * (pv * need + sbonus) - net_cost(cost) - econ_floor_penalty(gs, cost)
-- for every pack the engine prices in a real run, instead of inferring them from the total.
-- Guessing which term is wrong from aggregates is precisely what this project keeps getting
-- burned by; this measures it.
--
-- Usage:  luajit tools/pack_terms.lua [n_seeds]        (~95s per seed -- run it on 2-4)

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Driver  = require("sim.driver")
local Content = require("sim.content")
local SA      = require("engine.shop_advisor")
local Packs   = require("engine.packs")

local NSEEDS = tonumber(arg[1]) or 3

-- Wrap the two pure helpers the formula uses. Both are exported on SA, so this observes the
-- real values the advisor computes rather than recomputing them from a reconstructed state.
local rows = {}
local real_need = SA.pack_need
SA.pack_need = function(gs, kind, secure, pace, slots_free)
  local f, why = real_need(gs, kind, secure, pace, slots_free)
  rows[#rows + 1] = { stage = "need", kind = kind, need = f,
                      ante = (gs.meta or {}).ante or 0,
                      dollars = (gs.economy or {}).dollars or 0,
                      urgent = pace and pace.urgent or false,
                      on_pace = pace and pace.on_pace or false,
                      margin = pace and pace.margin or nil }
  return f, why
end

local real_floor = SA.econ_floor_penalty
SA.econ_floor_penalty = function(gs, cost)
  local p = real_floor(gs, cost)
  local last = rows[#rows]
  if last and last.stage == "need" then last.floor_pen = p; last.cost = cost end
  return p
end

for i = 1, NSEEDS do
  local seed = i * 1000 + 3
  Driver.run(seed, { content = Content })
  io.write(("seed %d done (%d priced packs)\n"):format(seed, #rows))
  io.flush()
end

-- ---- report -----------------------------------------------------------------
local by = {}
for _, r in ipairs(rows) do
  if r.cost then                                   -- only rows that reached the floor charge
    local b = by[r.kind]
    if not b then b = { n = 0, need = 0, floor = 0, cost = 0, urgent = 0, ahead = 0 }; by[r.kind] = b end
    b.n = b.n + 1
    b.need = b.need + r.need
    b.floor = b.floor + r.floor_pen
    b.cost = b.cost + r.cost
    if r.urgent then b.urgent = b.urgent + 1 end
    if (r.margin or 0) >= 1.8 then b.ahead = b.ahead + 1 end
  end
end

print("")
print(("PACK TERMS over %d seeds  (SA.ECON_FLOOR=%s rate=%s)")
  :format(NSEEDS, tostring(SA.ECON_FLOOR), tostring(SA.ECON_FLOOR_RATE)))
print(("  %-10s %6s %8s %10s %8s %8s %8s"):format(
  "kind", "n", "avg need", "avg floor", "avg cost", "%urgent", "%ahead"))
local ks = {}
for k in pairs(by) do ks[#ks + 1] = k end
table.sort(ks)
for _, k in ipairs(ks) do
  local b = by[k]
  print(("  %-10s %6d %8.3f %10.3f %8.2f %7.0f%% %7.0f%%"):format(
    k, b.n, b.need / b.n, b.floor / b.n, b.cost / b.n,
    100 * b.urgent / b.n, 100 * b.ahead / b.n))
end

-- the floor charge as a function of the wallet, which is the band-stop hypothesis
print("")
print("econ_floor_penalty by DOLLARS HELD (all pack kinds)")
local w = {}
for _, r in ipairs(rows) do
  if r.cost then
    local d = r.dollars
    local b = d >= 25 and "25+" or (d >= 15 and "15-24" or (d >= 8 and "8-14"
              or (d >= 4 and "4-7" or "0-3")))
    w[b] = w[b] or { n = 0, s = 0, need = 0 }
    w[b].n = w[b].n + 1; w[b].s = w[b].s + r.floor_pen; w[b].need = w[b].need + r.need
  end
end
print(("  %-8s %6s %12s %10s"):format("dollars", "n", "avg penalty", "avg need"))
for _, k in ipairs({ "0-3", "4-7", "8-14", "15-24", "25+" }) do
  local b = w[k]
  if b then print(("  %-8s %6d %12.3f %10.3f"):format(k, b.n, b.s / b.n, b.need / b.n)) end
end
