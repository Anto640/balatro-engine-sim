-- tools/boss_cost.lua -- what does each BOSS EFFECT cost a board, measured by the FULL ENGINE?
--
-- Prices Chicot (disables every boss) and Luchador (sell to disable the current boss). In the game a disabled boss
-- is a plain x2 blind (blind.lua Blind:disable: The Wall's chips /2, Violet Vessel /3, every other effect removed),
-- so the value of disabling boss B on a board is the difference between playing B and playing a plain x2 boss.
-- Recorded shop boards (bes_fixtures.jsonl) play the NEXT ante's boss, for every regular boss key and for the
-- disabled (generic x2) boss, on PAIRED round seeds, with the real decision engine. Records the clear rate and the
-- mean fraction of the target reached (capped at 1) per (board, boss).
--
--   run   : luajit tools/boss_cost.lua run <fixtures.jsonl> <out.jsonl> [n_states] [rounds] [shard] [nshards]
--   report: luajit tools/boss_cost.lua report <out.jsonl>
local here = arg and arg[0] and arg[0]:gsub("[^/]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")
local Json  = require("util.json")
local World = require("sim.world")
local Mechanics = require("engine.mechanics")

local function deep(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = deep(x) end
  return o
end

local BOSSES = {}
for k in pairs(World.BOSS_MIN_ANTE) do BOSSES[#BOSSES + 1] = k end
table.sort(BOSSES)

local mode = arg[1]
if mode == "report" then
  local path = arg[2]
  local files = { path }
  for k = 0, 63 do files[#files + 1] = path .. ".p" .. k end
  local agg = {}
  for _, f in ipairs(files) do
    local fh = io.open(f)
    if fh then
      for l in fh:lines() do
        local ok, r = pcall(Json.decode, l)
        if ok and r and r.res and r.res.disabled then
          local d = r.res.disabled
          for b, v in pairs(r.res) do
            if b ~= "disabled" then
              local t = agg[b] or { n = 0, dclear = 0, dfrac = 0 }
              t.n = t.n + 1
              t.dclear = t.dclear + (d.clear - v.clear)
              t.dfrac = t.dfrac + ((v.frac > 0) and (d.frac / v.frac - 1) or 0)
              agg[b] = t
            end
          end
        end
      end
      fh:close()
    end
  end
  local keys = {}
  for k in pairs(agg) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return agg[a].dclear / agg[a].n > agg[b].dclear / agg[b].n end)
  print("boss            n   clear-rate gained by disabling   output gain (fraction of target)")
  for _, k in ipairs(keys) do
    local t = agg[k]
    print(("%-14s %4d   %+.3f                           %+.3f"):format(k, t.n, t.dclear / t.n, t.dfrac / t.n))
  end
  return
end

assert(mode == "run", "usage: boss_cost.lua run|report ...")
local fixtures, out_path = arg[2], arg[3]
local n_states = tonumber(arg[4]) or 30
local rounds   = tonumber(arg[5]) or 8
local shard, nshards = tonumber(arg[6]), tonumber(arg[7])

local by_key, keys = {}, {}
for line in io.lines(fixtures) do
  if line:find('"decision"%s*:%s*"shop"') then
    local ok, fix = pcall(Json.decode, line)
    if ok and fix and fix.gs and #(fix.gs.jokers or {}) >= 1 and #(fix.gs.deck or {}) >= 30 and (fix.ante or 0) >= 1 then
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
    local b, r = fix.gs.blind or {}, fix.gs.run or {}
    local h0 = (b.base_hands and b.base_hands > 0) and b.base_hands or 4
    local d0 = (b.base_discards and b.base_discards >= 0) and b.base_discards or 3
    local z0 = r.hand_size or 8
    local seed0 = 0
    for c = 1, #st.key do seed0 = (seed0 * 31 + st.key:byte(c)) % 2147483647 end
    local res = {}
    local list = { "disabled" }
    for _, bk in ipairs(BOSSES) do list[#list + 1] = bk end
    for _, bk in ipairs(list) do
      local boss_key = (bk ~= "disabled") and bk or nil
      local target = World.blind_target(ante, "Boss", boss_key)
      local sum, wins = 0, 0
      for k = 1, rounds do
        local run = World.new_run(seed0 * 7 + k, { deck = deep(fix.gs.deck), dollars = (fix.gs.economy or {}).dollars or 0,
          base_hands = h0, base_discards = d0, hand_size = z0 })
        run.ante = ante
        run.jokers = deep(fix.gs.jokers)
        run.hand_levels = deep(r.hand_levels or {})
        run.vouchers_owned = deep(r.vouchers_owned or {})
        run.consumables = {}
        local out = World.play_blind(run, { type = "Boss", name = "Boss", target = target, boss_key = boss_key })
        sum = sum + math.min(1, (out.scored or 0) / target)
        if out.cleared then wins = wins + 1 end
      end
      res[bk] = { frac = sum / rounds, clear = wins / rounds }
    end
    fh:write(Json.encode({ key = st.key, ante = fix.ante, res = res }) .. "\n")
    fh:flush()
  end
end
fh:close()
