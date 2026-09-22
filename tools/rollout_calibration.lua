-- tools/rollout_calibration.lua
-- CALIBRATE the fast survival rollout (Sim.survive_fresh) -- and the shop's per-hand mean-score
-- measure -- against the FULL ENGINE actually playing the round (World.play_blind, the real
-- decision_engine every hand). The question is not "are the absolute numbers right" but "do the
-- cheap measures RANK boards the way the full engine does" -- a shop decision only needs the order.
--
-- Motivating case (2026-09-22, seed DGTW4TTP, ante 3): selling Smiley Face for Blackboard. Full
-- engine, 40 paired seeds: keep Smiley clears The House 40/40, Blackboard 32/40. survive_fresh said
-- the OPPOSITE (42% vs 63%), and the per-hand mean preferred Blackboard too. One case; this tool
-- asks how often, and on which jokers, the cheap measures mis-rank.
--
-- STATES: distinct (seed, ante, joker set) shop fixtures from bes_fixtures.jsonl with >= 2 jokers,
-- picked by an even stride. BOARDS per state: the current board + every leave-one-out (= the SELL
-- ranking the shop must get right). TARGETS per board: this ante's boss (with its effect) and the
-- next ante's boss (generic x2), so strong boards still separate. Consumables are dropped for both
-- players (this measures the BOARD). Full rounds are PAIRED across boards (same round seeds).
--
--   run   : luajit tools/rollout_calibration.lua run <fixtures.jsonl> <out.jsonl> [n_states] [full_rounds] [fast_rounds] [shard] [nshards]
--   report: luajit tools/rollout_calibration.lua report <out.jsonl>
-- RESUMABLE: `run` skips (state, board, target) items already in <out.jsonl> (each shard appends
-- to <out>.p<shard>, and `report` reads <out> plus every <out>.p* next to it). Full rounds cost ~3s
-- each, so shard across cores: see tools/rollout_calibration.sh.

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json      = require("util.json")
local RF        = require("core.replay_fixture")
local Sim       = require("engine.simulation")
local HandEval  = require("engine.hand_eval")
local BossEffect = require("engine.boss_effect")
local Mechanics = require("engine.mechanics")
local World     = require("sim.world")

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
local function str_hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
  return h
end

-- ---- state selection (deterministic) -----------------------------------------
local function load_states(path, n_states)
  local fh = assert(io.open(path), "cannot open " .. path)
  local by_key, keys = {}, {}
  for line in fh:lines() do
    if line:find('"decision"%s*:%s*"shop"') then
      local ok, fix = pcall(Json.decode, line)
      if ok and fix and fix.gs and #(fix.gs.jokers or {}) >= 2 and #(fix.gs.deck or {}) >= 20 then
        local js = {}
        for _, j in ipairs(fix.gs.jokers) do js[#js + 1] = j.key end
        table.sort(js)
        local key = tostring(fix.seed) .. "|" .. tostring(fix.ante) .. "|" .. table.concat(js, ",")
        if not by_key[key] then by_key[key] = fix; keys[#keys + 1] = key end
      end
    end
  end
  fh:close()
  table.sort(keys)
  local out = {}
  local n = math.min(n_states, #keys)
  for i = 1, n do
    local k = keys[math.floor((i - 1) * #keys / n) + 1]
    out[#out + 1] = { key = k, fix = by_key[k] }
  end
  return out, #keys
end

-- boards: current + each leave-one-out
local function boards_of(fix)
  local js = fix.gs.jokers
  local out = { { label = "base", jokers = js, removed = nil } }
  for i, j in ipairs(js) do
    local rest = {}
    for k, x in ipairs(js) do if k ~= i then rest[#rest + 1] = x end end
    out[#out + 1] = { label = "-" .. j.key, jokers = rest, removed = j.key }
  end
  return out
end

local function targets_of(fix)
  local ante = fix.ante or (fix.gs.meta and fix.gs.meta.ante) or 1
  local bk = fix.gs.run and fix.gs.run.boss_key
  local eff = bk and BossEffect.of(bk) or nil
  return {
    { kind = "this_boss", ante = ante, boss_key = bk, eff = eff,
      target = Mechanics.blind_requirement(ante, "Boss", eff and eff.mult or nil) },
    { kind = "next_boss", ante = ante + 1, boss_key = nil, eff = nil,
      target = Mechanics.blind_requirement(ante + 1, "Boss") },
  }
end

local function resources(fix)
  local b, r = fix.gs.blind or {}, fix.gs.run or {}
  local hands = b.base_hands; if not hands or hands <= 0 then hands = 4 end
  local discards = b.base_discards; if not discards or discards < 0 then discards = 3 end
  return hands, discards, r.hand_size or 8
end

-- ---- the three measures ---------------------------------------------------------
local function full_clear(fix, board, tg, rounds, state_seed)
  local hands, discards, hs = resources(fix)
  local wins, ratio = 0, 0
  for k = 1, rounds do
    local run = World.new_run(state_seed * 131 + k,
      { deck = deep(fix.gs.deck), dollars = (fix.gs.economy or {}).dollars or 0,
        base_hands = hands, base_discards = discards, hand_size = hs })
    run.ante = tg.ante
    run.jokers = deep(board.jokers)
    run.hand_levels = deep(fix.gs.run.hand_levels or {})
    run.vouchers_owned = deep(fix.gs.run.vouchers_owned or {})
    run.consumables = {}
    local r = World.play_blind(run, { type = "Boss", name = "Boss", target = tg.target, boss_key = tg.boss_key })
    if r.cleared then wins = wins + 1 end
    ratio = ratio + math.min(3, (r.scored or 0) / tg.target)
  end
  return wins / rounds, ratio / rounds
end

local function gs_for(fix, board, tg)
  local gs = RF.rehydrate(deep(fix))
  gs.jokers = deep(board.jokers)
  gs.consumables = {}
  gs.meta.ante = tg.ante
  gs.hand, gs.remaining = {}, {}
  return gs
end

-- rollout-policy VARIANTS to calibrate (nil = the shipped greedy policy)
local VARIANTS = {
  greedy = nil,
  dig1 = { dig = true, dig_samples = 1 },
  dig2 = { dig = true, dig_samples = 2 },
  dig4 = { dig = true, dig_samples = 4 },
  dig8 = { dig = true, dig_samples = 8 },
}

local function fast_clear(fix, board, tg, rounds, state_seed, pol)
  local hands, discards = resources(fix)
  local gs = gs_for(fix, board, tg)
  return Sim.survive_fresh(gs, tg.target, hands, discards, rounds, lcg(state_seed * 7 + 3), tg.eff, nil, pol)
end

-- the shop's current kind of measure: mean best single-hand score over random deals (paired hands)
local function mean_hand(fix, board, tg, samples, state_seed)
  local gs = gs_for(fix, board, tg)
  if tg.eff then gs.boss_effect = tg.eff end
  local _, _, hs = resources(fix)
  local deck = gs.deck
  local rng = lcg(state_seed * 11 + 5)
  local total = 0
  for _ = 1, samples do
    local d = {}
    for i, c in ipairs(deck) do d[i] = c end
    for i = #d, 2, -1 do local j = math.floor(rng() * i) + 1; d[i], d[j] = d[j], d[i] end
    local hand = {}
    for i = 1, math.min(hs, #d) do hand[i] = d[i] end
    local ev = HandEval.best_play(gs, hand)
    total = total + (ev and ev.score or 0)
  end
  return total / samples / (tg.target / 4)   -- in "fractions of a per-hand need"
end

-- ---- run ------------------------------------------------------------------------
local function read_done(path)
  local done = {}
  local fh = io.open(path)
  if fh then
    for line in fh:lines() do
      local ok, r = pcall(Json.decode, line)
      if ok and r and r.item then done[r.item] = true end
    end
    fh:close()
  end
  return done
end

local function cmd_run()
  local fixtures, out = arg[2], arg[3]
  local n_states = tonumber(arg[4] or 40)
  local full_rounds = tonumber(arg[5] or 16)
  local fast_rounds = tonumber(arg[6] or 200)
  local shard, nshards = tonumber(arg[7] or 0), tonumber(arg[8] or 1)
  local states, n_distinct = load_states(fixtures, n_states)
  local shard_out = out .. ".p" .. shard
  local done = read_done(shard_out)
  io.stderr:write(string.format("[calib] %d states (of %d distinct), shard %d/%d\n", #states, n_distinct, shard, nshards))
  local fh = assert(io.open(shard_out, "a"))
  local idx = 0
  for si, st in ipairs(states) do
    local state_seed = str_hash(st.key)
    for _, board in ipairs(boards_of(st.fix)) do
      for _, tg in ipairs(targets_of(st.fix)) do
        idx = idx + 1
        local item = st.key .. "#" .. board.label .. "#" .. tg.kind
        if (idx - 1) % nshards == shard and not done[item] then
          local t0 = os.clock()
          local fc, fratio = full_clear(st.fix, board, tg, full_rounds, state_seed)
          local t1 = os.clock()
          local fp = fast_clear(st.fix, board, tg, fast_rounds, state_seed)
          local mh = mean_hand(st.fix, board, tg, 100, state_seed)
          local keys = {}
          for _, j in ipairs(board.jokers) do keys[#keys + 1] = j.key end
          fh:write(Json.encode({
            item = item, state = st.key, si = si, seed = tostring(st.fix.seed), ante = st.fix.ante,
            board = board.label, removed = board.removed, jokers = Json.array(keys),
            target_kind = tg.kind, target = tg.target, boss_key = tg.boss_key,
            full = fc, full_ratio = fratio, full_n = full_rounds, fast = fp, fast_n = fast_rounds,
            mean_hand = mh, full_secs = t1 - t0,
          }) .. "\n")
          fh:flush()
          io.stderr:write(string.format("[calib] %s  full %.2f fast %.2f mean %.2f  (%.0fs)\n",
            item:sub(1, 90), fc, fp, mh, t1 - t0))
          collectgarbage()
        end
      end
    end
  end
  fh:close()
end

-- ---- rescore: re-measure the FAST side with a policy variant against existing full rows ----
local load_rows
local function cmd_rescore()
  local fixtures, out, variant = arg[2], arg[3], arg[4]
  local fast_rounds = tonumber(arg[5] or 200)
  local shard, nshards = tonumber(arg[6] or 0), tonumber(arg[7] or 1)
  local pol = VARIANTS[variant]
  assert(pol or variant == "greedy", "unknown variant " .. tostring(variant))
  local states = load_states(fixtures, 1e9)
  local by_key = {}
  for _, st in ipairs(states) do by_key[st.key] = st.fix end
  local path = out .. ".rescore_" .. variant .. ".p" .. shard
  local done = read_done(path)
  local fh = assert(io.open(path, "a"))
  local t0 = os.clock()
  local n = 0
  for ri, r in ipairs(load_rows(out)) do
    local fix = by_key[r.state]
    if fix and not done[r.item] and (ri - 1) % nshards == shard then
      local board, tg
      for _, b in ipairs(boards_of(fix)) do if b.label == r.board then board = b end end
      for _, t in ipairs(targets_of(fix)) do if t.kind == r.target_kind then tg = t end end
      if board and tg then
        local fp = fast_clear(fix, board, tg, fast_rounds, str_hash(r.state), pol)
        fh:write(Json.encode({ item = r.item, fast = fp }) .. "\n"); fh:flush()
        n = n + 1
      end
    end
  end
  fh:close()
  io.stderr:write(string.format("[rescore %s] %d rows in %.0fs\n", variant, n, os.clock() - t0))
end

-- ---- report -----------------------------------------------------------------------
function load_rows(out)
  local rows = {}
  local function add(path)
    local fh = io.open(path)
    if not fh then return end
    for line in fh:lines() do
      local ok, r = pcall(Json.decode, line)
      if ok and r and r.item then rows[r.item] = r end
    end
    fh:close()
  end
  add(out)
  for i = 0, 63 do add(out .. ".p" .. i) end
  local list = {}
  for _, r in pairs(rows) do list[#list + 1] = r end
  table.sort(list, function(a, b) return a.item < b.item end)
  return list
end

local function corr(xs, ys)
  local n = #xs
  if n < 3 then return 0 end
  local mx, my = 0, 0
  for i = 1, n do mx = mx + xs[i]; my = my + ys[i] end
  mx, my = mx / n, my / n
  local sxy, sxx, syy = 0, 0, 0
  for i = 1, n do
    sxy = sxy + (xs[i] - mx) * (ys[i] - my)
    sxx = sxx + (xs[i] - mx) ^ 2; syy = syy + (ys[i] - my) ^ 2
  end
  if sxx == 0 or syy == 0 then return 0 end
  return sxy / math.sqrt(sxx * syy)
end

local function cmd_report()
  local rows = load_rows(arg[2])
  local variant = arg[3]
  if variant then   -- substitute the fast column with a rescored policy variant
    local sub = {}
    for i = 0, 63 do
      local fh = io.open(arg[2] .. ".rescore_" .. variant .. ".p" .. i)
      if fh then
        for line in fh:lines() do local ok, r = pcall(Json.decode, line); if ok and r then sub[r.item] = r.fast end end
        fh:close()
      end
    end
    local kept = {}
    for _, r in ipairs(rows) do if sub[r.item] then r.fast = sub[r.item]; kept[#kept + 1] = r end end
    rows = kept
  end
  -- exclude boards whose resource jokers the fixture ALREADY folds into hand size / discards (the World
  -- re-applies them -> a double count on the full side, not a rollout error)
  local RES = { j_juggler = 1, j_drunkard = 1, j_troubadour = 1, j_merry_andy = 1, j_turtle_bean = 1, j_burglar = 1 }
  local clean = {}
  for _, r in ipairs(rows) do
    local bad = false
    for k in pairs(RES) do if r.state:find(k, 1, true) then bad = true end end
    if not bad then clean[#clean + 1] = r end
  end
  print(string.format("rows: %d (%d after excluding resource-joker states)  fast = %s", #rows, #clean, variant or "greedy"))
  rows = clean
  for _, kind in ipairs({ "this_boss", "next_boss" }) do
    local groups, order = {}, {}
    local xs_full, xs_fast, xs_mean = {}, {}, {}
    local bias = 0
    for _, r in ipairs(rows) do
      if r.target_kind == kind then
        if not groups[r.state] then groups[r.state] = {}; order[#order + 1] = r.state end
        table.insert(groups[r.state], r)
        xs_full[#xs_full + 1] = r.full; xs_fast[#xs_fast + 1] = r.fast; xs_mean[#xs_mean + 1] = r.mean_hand
        bias = bias + (r.fast - r.full)
      end
    end
    local n = #xs_full
    print(string.format("\n=== %s  (%d boards, %d states) ===", kind, n, #order))
    if n > 0 then
      print(string.format("  level: full %.3f  fast %.3f  (fast - full bias %+.3f)",
        (function() local s = 0 for _, v in ipairs(xs_full) do s = s + v end return s / n end)(),
        (function() local s = 0 for _, v in ipairs(xs_fast) do s = s + v end return s / n end)(), bias / n))
      print(string.format("  corr(full, fast) %.3f   corr(full, mean_hand) %.3f", corr(xs_full, xs_fast), corr(xs_full, xs_mean)))
    end
    -- PAIRWISE ranking within a state, on pairs the full engine separates clearly. With paired
    -- rounds, a gap of >= MIN_GAP (e.g. 3+ rounds of 16) is taken as a real difference.
    local MIN_GAP = tonumber(os.getenv("CALIB_MIN_GAP") or 0.1875)
    local pairs_n, fast_ok, mean_ok, fast_tie = 0, 0, 0, 0
    local bad = {}
    local per_removed = {}
    for _, st in ipairs(order) do
      local g = groups[st]
      for i = 1, #g do for j = i + 1, #g do
        local a, b = g[i], g[j]
        local dfull = a.full - b.full
        if math.abs(dfull) >= MIN_GAP then
          pairs_n = pairs_n + 1
          local dfast, dmean = a.fast - b.fast, a.mean_hand - b.mean_hand
          if dfast * dfull > 0 then fast_ok = fast_ok + 1 elseif dfast == 0 then fast_tie = fast_tie + 1 end
          if dmean * dfull > 0 then mean_ok = mean_ok + 1 end
          if dfast * dfull <= 0 then
            bad[#bad + 1] = { st = st, a = a.board, b = b.board, dfull = dfull, dfast = dfast, dmean = dmean }
          end
        end
      end end
      -- per-joker sell error: full vs fast drop from removing that joker
      local base
      for _, r in ipairs(g) do if r.board == "base" then base = r end end
      if base then
        for _, r in ipairs(g) do if r.removed then
          local e = per_removed[r.removed] or { n = 0, full_drop = 0, fast_drop = 0, mean_drop = 0 }
          e.n = e.n + 1
          e.full_drop = e.full_drop + (base.full - r.full)
          e.fast_drop = e.fast_drop + (base.fast - r.fast)
          e.mean_drop = e.mean_drop + (base.mean_hand - r.mean_hand)
          per_removed[r.removed] = e
        end end
      end
    end
    if pairs_n > 0 then
      print(string.format("  RANKING on %d clearly-separated pairs (|full gap| >= %.3f):", pairs_n, MIN_GAP))
      print(string.format("    fast rollout agrees %d/%d (%.0f%%), ties %d   |   per-hand mean agrees %d/%d (%.0f%%)",
        fast_ok, pairs_n, 100 * fast_ok / pairs_n, fast_tie, mean_ok, pairs_n, 100 * mean_ok / pairs_n))
    end
    table.sort(bad, function(x, y) return math.abs(x.dfull) > math.abs(y.dfull) end)
    if #bad > 0 then print("  worst fast-rollout mis-rankings (full gap, fast gap, mean gap):") end
    for i = 1, math.min(12, #bad) do
      local x = bad[i]
      print(string.format("    %+.2f %+.2f %+.2f  %s  vs  %s   [%s]", x.dfull, x.dfast, x.dmean, x.a, x.b, x.st:sub(1, 70)))
    end
    local jl = {}
    for k, e in pairs(per_removed) do jl[#jl + 1] = { k = k, e = e } end
    table.sort(jl, function(x, y)
      return math.abs(x.e.full_drop - x.e.fast_drop) / x.e.n > math.abs(y.e.full_drop - y.e.fast_drop) / y.e.n end)
    if #jl > 0 then print("  per-joker SELL impact (avg clear-rate drop when removed): full | fast | error") end
    for i = 1, math.min(15, #jl) do
      local x = jl[i]
      print(string.format("    %-24s n=%-2d  full %+.2f | fast %+.2f | err %+.2f", x.k, x.e.n,
        x.e.full_drop / x.e.n, x.e.fast_drop / x.e.n, (x.e.fast_drop - x.e.full_drop) / x.e.n))
    end
  end
end

local cmd = arg[1]
if cmd == "run" then cmd_run()
elseif cmd == "rescore" then cmd_rescore()
elseif cmd == "report" then cmd_report()
else
  io.stderr:write("usage: rollout_calibration.lua run <fixtures> <out> [n_states] [full_rounds] [fast_rounds] [shard] [nshards]\n"
    .. "       rollout_calibration.lua report <out>\n")
  os.exit(1)
end
