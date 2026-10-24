-- tools/owner_continue_trace.lua -- continue the sim from the OWNER's recorded BLIND-START positions (Small / Big / Boss
-- of any ante, not only ante starts like tools/owner_continue.lua), with the owner's REAL boss for that ante, and keep
-- the FULL record trace (shop advice, buys, sells, deaths) so the engine's failures from strong human boards can be read.
--
--   usage (from the repo root):
--     luajit tools/owner_continue_trace.lua <fixtures.jsonl> <points_file> <s0> <n_seeds> <out.jsonl>
--   points_file lines: "<seed> <ante> <Small|Big|Boss> <boss_key|none>"  (boss_key from that ante's Boss fixture)
--   every emitted record carries r.start = "<seed>:<ante><S|B|X>" and r.cseed = the world seed; one
--   {kind="cont_end", won, death_ante} per continuation. World seeds are s*1000+7, so two runs with the same s pair.
--
-- ABLATIONS (env): CONT_MONEY=<n> sets the bankroll; CONT_DECK=std gives a fresh 52-card deck (plain / stdmods /
-- sizemods: finer splits, see shape_deck; CONT_DECK_DUMP=1 prints the deck and runs nothing); CONT_JOKERS=<file>
-- swaps the owner's jokers for an engine board (one line of joker keys per board, chosen by seed); CONT_LEVELS=reset;
-- CONT_PROBE=<Probe config> (default invest1 = the live skip policy). Any engine BES_* switch passes through the env.
--
-- 2026-10-23 (capture runs SEMXURN5 / X778PBYT / UEZMTED9 / 9MY8IRY3): found the full-board reroll inflation (claims
-- +100..+1388% of a boss hand per roll, buys nothing), the never-expiring economy commitment, and SAVE-to-$50 at
-- "risk 88-94%" -- see NEXT_SESSION 2026-10-23.
--   points_file lines: "<seed> <ante> <Small|Big|Boss> <boss_key>"
package.path = "./?.lua;./?/init.lua;" .. package.path
pcall(function() require("jit").opt.start("maxtrace=4000", "maxmcode=16384") end)
local Json = require("util.json"); local RF = require("core.replay_fixture")
local World = require("sim.world"); local Driver = require("sim.driver"); local Content = require("sim.content")
local Probe = require("sim.probe")

local fixtures_path, points_path = arg[1], arg[2]
local S0, N, out_path = tonumber(arg[3]) or 1, tonumber(arg[4]) or 20, arg[5]
local probe_name = os.getenv("CONT_PROBE") or "invest1"

local want = {}
for line in io.lines(points_path) do
  local sd, a, bt, bk = line:match("^(%S+)%s+(%d+)%s+(%S+)%s+(%S+)")
  if sd then want[sd .. ":" .. a .. ":" .. bt] = { seed = sd, ante = tonumber(a), bt = bt, boss = bk } end
end
local fx = {}
for line in io.lines(fixtures_path) do
  if line:find('"decision":"blind"', 1, true) then
    local f = Json.decode(line)
    if f and f.gs and f.gs.blind then
      local k = f.seed .. ":" .. f.ante .. ":" .. tostring(f.gs.blind.blind_type)
      local b = f.gs.blind
      if want[k] and not fx[k] and (b.chips_scored or 0) == 0 and b.hands_left == b.base_hands
         and b.discards_left == b.base_discards then fx[k] = f end
    end
  end
end

local function deep(v) if type(v) ~= "table" then return v end local o = {} for k, x in pairs(v) do o[k] = deep(x) end return o end
local SHOP_V = { v_overstock_norm = true, v_overstock_plus = true, v_clearance_sale = true, v_liquidation = true,
  v_reroll_surplus = true, v_reroll_glut = true, v_telescope = true, v_hone = true, v_glow_up = true,
  v_tarot_merchant = true, v_planet_merchant = true, v_seed_money = true, v_money_tree = true }
-- Finer deck ablations (CONT_DECK=, 2026-10-24) splitting the owner deck's edge into modifiers / composition / size:
--   plain    = the owner's cards with every enhancement, seal and edition removed (ranks, suits, size kept);
--   stdmods  = a fresh 52 with the owner's modifiers moved onto the same rank+suit (else same rank, else any free card);
--   sizemods = stdmods trimmed (unmodified cards) or padded (copies of unmodified cards) to the owner's deck size.
-- base - plain = modifiers; base - sizemods = which ranks / suits; sizemods - stdmods = size alone.
local function has_mod(c) return c.enhancement or c.seal or c.edition end
local function shape_deck(mode, owner, s)
  if mode == "plain" then
    local d = deep(owner)
    for _, c in ipairs(d) do c.enhancement, c.seal, c.edition = nil, nil, nil end
    return d
  end
  local d = World.standard_deck()
  local used = {}
  local function take(pred) for i, c in ipairs(d) do if not used[i] and pred(c) then used[i] = true return c end end end
  local mods = {}
  for _, c in ipairs(owner) do if has_mod(c) then mods[#mods + 1] = c end end
  table.sort(mods, function(a, b) return (a.id or 0) < (b.id or 0) end)
  for _, o in ipairs(mods) do
    local t = take(function(c) return c.rank_id == o.rank_id and c.suit == o.suit end)
      or take(function(c) return c.rank_id == o.rank_id end) or take(function() return true end)
    if t then t.enhancement, t.seal, t.edition = o.enhancement, o.seal, o.edition end
  end
  if mode == "sizemods" then
    local x = (s * 7919 + 17) % 2147483647
    local function rnd(n) x = (x * 48271) % 2147483647 return x % n + 1 end
    local free = {}
    for i, c in ipairs(d) do if not has_mod(c) then free[#free + 1] = i end end
    local want = #owner
    if want < #d then
      local drop = {}
      for _ = 1, math.min(#d - want, #free) do local k = rnd(#free) drop[free[k]] = true table.remove(free, k) end
      local kept = {}
      for i, c in ipairs(d) do if not drop[i] then kept[#kept + 1] = c end end
      d = kept
    else
      local id = 1000
      while #d < want do
        local c = deep(d[free[rnd(#free)]]); id = id + 1; c.id = id; d[#d + 1] = c
      end
    end
  end
  return d
end

local BI = { Small = 1, Big = 2, Boss = 3 }
local TAGC = { Small = "S", Big = "B", Boss = "X" }

local out = assert(io.open(out_path, "a"))
local keys = {}
for k in pairs(want) do keys[#keys + 1] = k end
table.sort(keys)
for _, k in ipairs(keys) do
  local w, fix = want[k], fx[k]
  if not fix then io.stderr:write("no fixture " .. k .. "\n") else
    local start = w.seed .. ":" .. w.ante .. TAGC[w.bt]
    for s = S0, S0 + N - 1 do
      local gs = RF.rehydrate(fix)
      local seed = s * 1000 + 7
      local o = { content = Content, silent = true }
      for kk, v in pairs(Probe.opts(probe_name) or {}) do o[kk] = v end
      local run = World.new_run(seed, o)
      run.deck = deep(gs.deck); run.jokers = deep(gs.jokers); run.consumables = deep(gs.consumables or {})
      run.hand_levels = deep(gs.run.hand_levels or {})
      run.economy.dollars = gs.economy.dollars or 0
      run.hand_size = gs.run.hand_size or 8
      run.base_hands = gs.blind.base_hands or 4; run.base_discards = gs.blind.base_discards or 3
      run.joker_slots = gs.run.joker_slots or 5; run.consumable_slots = gs.run.consumable_slots or 2
      run.build_plan = deep(gs.run.build_plan)
      for kk, v in pairs(gs.run.vouchers_owned or {}) do
        local key = (type(kk) == "string" and v == true) and kk or v
        if type(key) == "string" then
          if SHOP_V[key] then Content._apply_voucher(run, key) else run.vouchers_owned[#run.vouchers_owned + 1] = key end
        end
      end
      -- ABLATIONS (env): CONT_MONEY=<n> sets the bankroll; CONT_DECK=std gives a fresh 52-card deck;
      -- CONT_JOKERS=<boards file> swaps the owner's jokers for an engine a4 board (line chosen by seed);
      -- CONT_LEVELS=reset clears the hand levels.
      if os.getenv("CONT_MONEY") then run.economy.dollars = tonumber(os.getenv("CONT_MONEY")) end
      local dm = os.getenv("CONT_DECK")
      if dm == "std" then run.deck = World.standard_deck()
      elseif dm == "plain" or dm == "stdmods" or dm == "sizemods" then run.deck = shape_deck(dm, run.deck, s) end
      if os.getenv("CONT_LEVELS") == "reset" then run.hand_levels = {} end
      if os.getenv("CONT_JOKERS") then
        local bl = {}
        for ln in io.lines(os.getenv("CONT_JOKERS")) do bl[#bl + 1] = ln end
        local GS = require("model.game_state"); local JD = require("engine.joker_data")
        local ln = bl[(s * 7919) % #bl + 1]
        run.jokers = {}
        for key in ln:gmatch("%S+") do
          local d = JD.resolve(key)
          run.jokers[#run.jokers + 1] = GS.joker{ key = key, name = d.name or key, cost = d.cost or 4,
            sell_value = math.max(1, math.floor((d.cost or 4) / 2)), rarity = d.rarity, ability = { extra = {} } }
        end
      end
      if os.getenv("CONT_DECK_DUMP") then   -- print the (ablated) deck's make-up and skip the run
        local m, r = {}, {}
        for _, c in ipairs(run.deck) do
          for _, f in pairs({ c.enhancement or false, c.seal or false, c.edition or false }) do
            if f then m[f] = (m[f] or 0) + 1 end
          end
          r[c.rank_id] = (r[c.rank_id] or 0) + 1
        end
        local o = {}
        for kk, v in pairs(m) do o[#o + 1] = kk .. "=" .. v end
        table.sort(o)
        local ro = {}
        for rr = 2, 14 do ro[#ro + 1] = r[rr] or 0 end
        print(start, s, "n=" .. #run.deck, table.concat(o, " "), "ranks2-A " .. table.concat(ro, ","))
        goto continue
      end
      local A = w.ante
      run.ante = A
      local bi = BI[w.bt]
      run.round = (A - 1) * 3 + (bi - 1)
      local opts = { run = run, content = Content }
      if w.boss and w.boss:match("^bl_") and w.boss ~= "bl_small" and w.boss ~= "bl_big" then
        run._pending_boss = w.boss
      end
      if bi > 1 then
        World.checkpoint(run, "ante", A)
        run._ante_blinds = World.ante_blinds(run)
        run._blind_idx = bi - 1
        opts.resume = true
      end
      local ok, res = pcall(Driver.run, seed, opts)
      if not ok then io.stderr:write("err " .. start .. " " .. tostring(res) .. "\n") else
        for _, r in ipairs(res.records or {}) do
          r.start = start; r.cseed = seed
          out:write(Json.encode(r) .. "\n")
        end
        out:write(Json.encode({ kind = "cont_end", start = start, cseed = seed, won = res.won and true or false,
          death_ante = res.death_ante }) .. "\n")
        out:flush()
      end
      ::continue::
    end
  end
end
out:close()
