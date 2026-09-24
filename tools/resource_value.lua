-- tools/resource_value.lua -- what is ONE more discard / hand size / hand worth, measured by the FULL ENGINE?
--
-- R12b priced hand-size / hands jokers (Juggler, Troubadour, Turtle Bean, Burglar's +3 hands) with the cheap
-- greedy rollout (Eval.utility_fraction -> Sim.blind_output_frac), but DISCARDS could not be priced that way:
-- the greedy rollout wastes them (a 4th discard read -3%..+15% by seed and LOWERED output against a far
-- target), and the dig-aware policy was 7-10 s per state and still noisy. So Drunkard / Merry Andy stayed on
-- their tier prior -- the last big reason the tier floor cannot be removed (sim u2: Drunkard bought 20x).
--
-- This tool measures it offline instead, once, with the real decision engine digging every hand: recorded
-- shop boards play the NEXT ante's boss (so a board that clears this ante still separates) under four
-- resource conditions on PAIRED round seeds -- as recorded, +1 discard, +1 hand size, +1 hand -- and records
-- the mean fraction of the target reached (capped at 1) and the clear rate. The relative output gain of each
-- condition (out_cond / out_base - 1) is the quantity Eval.utility_fraction converts to a per-hand fraction
-- (frac = r0 x gain), so the report gives it by base-discard count and board strength, ready to fit. The
-- +hand-size / +hand columns double as a CHECK of the greedy rollout already shipped for those jokers.
--
--   run   : luajit tools/resource_value.lua run <fixtures.jsonl> <out.jsonl> [n_states] [rounds] [shard] [nshards]
--   report: luajit tools/resource_value.lua report <out.jsonl>
local here = arg and arg[0] and arg[0]:gsub("[^/]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json      = require("util.json")
local RF        = require("core.replay_fixture")
local Mechanics = require("engine.mechanics")
local World     = require("sim.world")
local JokerValue = require("engine.joker_value")
local Sim       = require("engine.simulation")

local function lcg(seed)
  local s = math.floor(seed) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end
local function deep(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = deep(x) end
  return o
end

local CONDS = {
  { name = "base",  dh = 0, dd = 0, dz = 0 },
  { name = "disc",  dh = 0, dd = 1, dz = 0 },
  { name = "hsize", dh = 0, dd = 0, dz = 1 },
  { name = "hand",  dh = 1, dd = 0, dz = 0 },
}

local mode = arg[1]
if mode == "report" then
  local path = arg[2]
  local rows = {}
  local files = { path }
  for k = 0, 63 do files[#files + 1] = path .. ".p" .. k end   -- no `ls` on Windows luajit
  for _, f in ipairs(files) do
    local fh = io.open(f)
    if fh then
      for l in fh:lines() do local ok, r = pcall(Json.decode, l); if ok and r and r.out then rows[#rows + 1] = r end end
      fh:close()
    end
  end
  -- per state: relative gain of each condition over base; grouped by base discards and board strength
  local by = {}
  local function add(key, cond, g, gg)
    by[key] = by[key] or { n = 0 }
    local t = by[key]
    t[cond] = (t[cond] or 0) + g
    t[cond .. "_greedy"] = (t[cond .. "_greedy"] or 0) + (gg or 0)
    if cond == "disc" then t.n = t.n + 1 end
  end
  local all = { n = 0 }
  for _, r in ipairs(rows) do
    local b = r.out.base
    if b and b > 0.02 then
      local band = (r.r0 < 0.5 and "r0<0.5") or (r.r0 < 1 and "r0 0.5-1") or (r.r0 < 2 and "r0 1-2") or "r0>=2"
      for _, c in ipairs({ "disc", "hsize", "hand" }) do
        local g = r.out[c] / b - 1
        local gg = (r.greedy and r.greedy.base and r.greedy.base > 0) and (r.greedy[c] / r.greedy.base - 1) or nil
        add("d=" .. r.d0 .. "  " .. band, c, g, gg)
        add("ALL", c, g, gg)
      end
    end
  end
  local keys = {}
  for k in pairs(by) do keys[#keys + 1] = k end
  table.sort(keys)
  print("relative OUTPUT gain vs base (full engine | greedy rollout), next-ante boss target")
  print(("%-22s %4s  %-17s %-17s %-17s"):format("group", "n", "+1 discard", "+1 hand size", "+1 hand"))
  for _, k in ipairs(keys) do
    local t = by[k]
    local function cell(c) return ("%+.3f | %+.3f"):format(t[c] / t.n, t[c .. "_greedy"] / t.n) end
    print(("%-22s %4d  %-17s %-17s %-17s"):format(k, t.n, cell("disc"), cell("hsize"), cell("hand")))
  end
  return
end

assert(mode == "run", "usage: resource_value.lua run|report ...")
local fixtures, out_path = arg[2], arg[3]
local n_states = tonumber(arg[4]) or 60
local rounds   = tonumber(arg[5]) or 16
local shard, nshards = tonumber(arg[6]), tonumber(arg[7])

-- distinct (seed, ante, joker set) shop states with a real board and deck, even stride (deterministic)
local by_key, keys = {}, {}
for line in io.lines(fixtures) do
  if line:find('"decision"%s*:%s*"shop"') then
    local ok, fix = pcall(Json.decode, line)
    if ok and fix and fix.gs and #(fix.gs.jokers or {}) >= 1 and #(fix.gs.deck or {}) >= 30 then
      local js = {}
      for _, j in ipairs(fix.gs.jokers) do js[#js + 1] = j.key end
      table.sort(js)
      local key = tostring(fix.seed) .. "|" .. tostring(fix.ante) .. "|" .. table.concat(js, ",")
      if not by_key[key] then by_key[key] = fix; keys[#keys + 1] = key end
    end
  end
end
table.sort(keys)
local states = {}
local n = math.min(n_states, #keys)
for i = 1, n do local k = keys[math.floor((i - 1) * #keys / n) + 1]; states[#states + 1] = { key = k, fix = by_key[k] } end

local done = {}
local sp = out_path .. (shard and (".p" .. shard) or "")
do local fh = io.open(sp); if fh then for l in fh:lines() do local ok, r = pcall(Json.decode, l); if ok and r then done[r.key] = true end end; fh:close() end end
local fh = assert(io.open(sp, "a"))

for si, st in ipairs(states) do
  if ((not nshards) or ((si - 1) % nshards) == shard) and not done[st.key] then
    local fix = st.fix
    local ante = math.min(8, (fix.ante or 1) + 1)
    local target = Mechanics.blind_requirement(ante, "Boss")
    local b, r = fix.gs.blind or {}, fix.gs.run or {}
    local h0 = (b.base_hands and b.base_hands > 0) and b.base_hands or 4
    local d0 = (b.base_discards and b.base_discards >= 0) and b.base_discards or 3
    local z0 = r.hand_size or 8
    local gs = RF.rehydrate(deep(fix)); gs.consumables = {}; gs.meta.ante = ante; gs.hand, gs.remaining = {}, {}
    local r0 = (JokerValue.avg_score(gs, { samples = 16, rng = lcg(7) }) or 0) / Mechanics.boss_per_hand_need(gs)
    local out, clr, greedy = {}, {}, {}
    local seed0 = 0
    for c = 1, #st.key do seed0 = (seed0 * 31 + st.key:byte(c)) % 2147483647 end
    for _, cd in ipairs(CONDS) do
      local sum, wins = 0, 0
      for k = 1, rounds do
        local run = World.new_run(seed0 * 7 + k, { deck = deep(fix.gs.deck), dollars = (fix.gs.economy or {}).dollars or 0,
          base_hands = h0 + cd.dh, base_discards = d0 + cd.dd, hand_size = z0 + cd.dz })
        run.ante = ante
        run.jokers = deep(fix.gs.jokers)
        run.hand_levels = deep(r.hand_levels or {})
        run.vouchers_owned = deep(r.vouchers_owned or {})
        run.consumables = {}
        local res = World.play_blind(run, { type = "Boss", name = "Boss", target = target })
        sum = sum + math.min(1, (res.scored or 0) / target)
        if res.cleared then wins = wins + 1 end
      end
      out[cd.name], clr[cd.name] = sum / rounds, wins / rounds
      -- the shipped greedy measure, same condition, for comparison
      local g = {}; for kk, v in pairs(gs) do g[kk] = v end
      g.run = {}; for kk, v in pairs(gs.run or {}) do g.run[kk] = v end
      g.run.hand_size = z0 + cd.dz
      greedy[cd.name] = Sim.blind_output_frac(g, h0 + cd.dh, d0 + cd.dd, 24, lcg(seed0 + 3), nil, nil, target)
    end
    fh:write(Json.encode({ key = st.key, ante = fix.ante, d0 = d0, h0 = h0, z0 = z0, r0 = r0,
      out = out, clear = clr, greedy = greedy }) .. "\n")
    fh:flush()
    io.write(("[%s] %d/%d %s  base %.3f disc %.3f hsize %.3f hand %.3f\n"):format(tostring(shard), si, #states,
      st.key:sub(1, 40), out.base, out.disc, out.hsize, out.hand))
  end
end
fh:close()
