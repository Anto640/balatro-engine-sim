-- tools/joker_realized.lua -- PREDICTED (at purchase) vs REALIZED (while held) value of shop-bought jokers.
-- AUDIT 2026-10-10 (docs/AUDIT_2026-10-10_next_lever.md, task B). Replays the live decision states in
-- bes_fixtures.jsonl with the CURRENT engine:
--   predicted = the shop advisor's own scoring gain for the joker at the state it was bought (BUY_JOKER dbg.sgain,
--               fraction of the next boss's per-hand need, i.e. after projection / forward measure / tier floor)
--   realized  = its leave-one-out marginal (JokerValue.remove_delta / boss per-hand need) at the first shop of each
--               later ante while it is still owned -- the same single-deal measurement the engine uses, so this
--               isolates what the PROJECTIONS / FLOORS / priors add on top of the measurement, not dig effects.
-- One output line per (buy, later ante); summarise with tools/joker_realized_report.py.
--   usage: luajit tools/joker_realized.lua <bes_fixtures.jsonl> <out.jsonl> [max_runs]
local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

_G.BES_VALUE_DEBUG = true
local Json      = require("util.json")
local RF        = require("core.replay_fixture")
local SA        = require("engine.shop_advisor")
local JV        = require("engine.joker_value")
local Mechanics = require("engine.mechanics")
local JokerData = require("engine.joker_data")

local infile, outfile, max_runs = arg[1], arg[2], tonumber(arg[3] or "")
local out = assert(io.open(outfile, "w"))

local function lcg(seed)
  local s = seed % 2147483647; if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end
local function keyset(gs)
  local t = {}
  for i, j in ipairs(gs.jokers or {}) do if j.key then t[j.key] = i end end
  return t
end

local runs_done = 0
local function process(seed, lines)
  if #lines < 2 then return end
  local st = {}
  for _, l in ipairs(lines) do
    local ok, fix = pcall(Json.decode, l)
    if ok and fix and fix.gs then
      st[#st + 1] = { fix = fix, ante = fix.ante or (fix.gs.meta and fix.gs.meta.ante) or 1, keys = nil }
    end
  end
  table.sort(st, function(a, b) return (a.fix.idx or 0) < (b.fix.idx or 0) end)
  for _, s in ipairs(st) do s.keys = keyset(s.fix.gs) end
  -- first shop state of each ante (realized samples)
  local first_of = {}
  for i, s in ipairs(st) do if not first_of[s.ante] then first_of[s.ante] = i end end
  for t = 1, #st - 1 do
    local a, b = st[t], st[t + 1]
    local offered = {}
    for _, j in ipairs((a.fix.gs.shop and a.fix.gs.shop.jokers) or {}) do if j.key then offered[j.key] = true end end
    for k in pairs(b.keys) do
      if not a.keys[k] and offered[k] then
        -- a shop buy of k between state t and t+1: predicted at t
        local gs = RF.rehydrate(a.fix)
        local ok, res = pcall(SA.recommend, gs, { rng = lcg(7919 + t) })
        local pred, val, typ
        if ok and res then
          local all = { res.best }
          for _, x in ipairs(res.alternatives or {}) do all[#all + 1] = x end
          for _, x in ipairs(all) do
            if x and x.dbg and x.dbg.key == k and x.type == "BUY_JOKER" then pred, val, typ = x.dbg.sgain, x.value, x.type end
          end
        end
        local d = JokerData.resolve(k) or {}
        -- realized: first shop state of this ante (after the buy) and of each later ante while owned
        for ante = a.ante, a.ante + 3 do
          local i = first_of[ante]
          if ante == a.ante then i = t + 1 end
          local s = i and st[i]
          if s and s.keys[k] then
            local g2 = RF.rehydrate(s.fix)
            local idx = keyset(g2)[k]
            local m = idx and JV.remove_delta(g2, idx, { samples = 16, rng = lcg(104729 + i) })
            local need = Mechanics.boss_per_hand_need(g2)
            out:write(Json.encode({ seed = seed, key = k, cat = d.cat, tier = d.tier, buy_ante = a.ante,
              dante = ante - a.ante, pred = pred, value = val, real = m and (m / need) or nil,
              njokers = #(g2.jokers or {}) }) .. "\n")
          end
        end
        out:flush()
      end
    end
  end
  runs_done = runs_done + 1
  io.stderr:write(string.format("run %d %s states %d\n", runs_done, tostring(seed), #st))
end

local cur, lines = nil, {}
for line in io.lines(infile) do
  if line:find('"decision":"shop"', 1, true) and line:find('"kind":"state"', 1, true) then
    local seed = line:match('"seed":"([^"]+)"')
    if seed ~= cur then
      if cur then process(cur, lines) end
      cur, lines = seed, {}
      if max_runs and runs_done >= max_runs then break end
    end
    lines[#lines + 1] = line
  end
end
if cur and not (max_runs and runs_done >= max_runs) then process(cur, lines) end
out:close()
