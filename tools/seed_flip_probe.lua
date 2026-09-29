-- tools/seed_flip_probe.lua
-- Which recorded shop / pack decisions change their TOP PICK when only the Monte-Carlo sampling seed changes,
-- which estimator's noise causes it, and how many samples make it stable.
--
--   usage: luajit tools/seed_flip_probe.lua <fixtures.jsonl> <out.jsonl> [opts]
--     --kinds shop,pack   decision kinds to replay (default both)
--     --runs N            only the last N distinct runs in the file (default all)
--     --limit N           stop after N decisions
--     --K N               salted seeds per arm (default 6; each arm = salt 0 + K salts = K+1 realizations)
--     --mults 2,4,8       sample multipliers swept for an estimator that flips on its own
--     --shard i n         process decisions with (ordinal % n) == i-1 (for parallel shards)
--     (resumable: rerun the same command to continue; finished decisions are skipped)
--     --skip a.jsonl,b    also skip decisions finished in these output files (resume across a re-shard)
--     --timing 2,4,8      COST mode instead of the flip arms: per decision, cpu seconds of one advisor call at x1
--                         and with each estimator alone at each multiplier. Record: { t1, tm = { ctx = { m = s } } }
--     --decompose a.jsonl,b.jsonl
--                         DECOMPOSITION mode: for every decision those main-run outputs show flipping on ONE estimator
--                         alone, split that estimator: pack/pool -> which sample dimension stops the flip at x4
--                         (J4 JokerValue samples, M4 jokers drawn, R4 expected_pick trials); joker -> which JokerValue
--                         function's seed alone flips it (score_delta / remove_delta / avg_score / top_score).
--     --selfcheck        also replay each decision with NO wrappers installed and assert it equals salt 0
--   report: lua tools/seed_flip_report.lua <out.jsonl>...
--
-- METHOD. The advisors are replayed exactly as the live mod calls them (SA.recommend(gs, {}), PO.recommend(gs)),
-- so salt 0 IS the live advice on that state. Noise is varied without touching engine code by wrapping the module
-- functions every Monte-Carlo estimate goes through, and tagging each call with the ESTIMATOR (context) it serves:
--   pace   Pacing.pace                       -- capacity read -> risk / urgent band (shop's buy-power vs bank tilt)
--   pack   Packs.value                       -- a booster's EV in the shop (joker pool draw, tarot/spectral values, best-K-of-N)
--   pool   other Packs.* pool EVs            -- reroll EV (expected_shop_joker), rarity tags, random-card generators
--   joker  JokerValue.* outside the above    -- joker buy/sell/swap measurements (score_delta, remove_delta, avg_score)
--   cons   ConsumableValue.* outside above   -- loose tarot / planet / spectral values
-- Nested calls inherit the outer context (a JokerValue call inside Packs.value is pack noise).
-- SALTING rotates each uniform an estimator draws by a salt- and draw-index-dependent offset, mod 1
-- (a Cranley-Patterson rotation): still iid uniform, the SAME number of draws (so no other estimator's stream
-- shifts), and two identically-seeded streams stay identical -- the engine's paired (common-random-number)
-- measurements, e.g. consumable_value.lua:591-592 and eval_function.lua:904-905, keep their pairing.
-- SAMPLE MULTIPLIERS scale per-call sample counts once, at the JokerValue leaf (every scoring MC goes through
-- it), plus the pool's structural counts: measure_count (jokers drawn from a pool, 8) and expected_pick's
-- trials (40). Not scaled: ConsumableValue's own placement draws, and CV.hand_frequencies, which is seeded from
-- the state's content and memoised (frozen: no caller seed reaches it).

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

-- count any use of the GLOBAL rng (a live-flicker bug per CLAUDE.md); installed before the engine loads
local GLOBAL_RNG_CALLS = 0
do
  local mr = math.random
  math.random = function(...) GLOBAL_RNG_CALLS = GLOBAL_RNG_CALLS + 1; return mr(...) end
end

local Json   = require("util.json")
local RF     = require("core.replay_fixture")
local SA     = require("engine.shop_advisor")
local PO     = require("engine.pack_open_advisor")
local JV     = require("engine.joker_value")
local CV     = require("engine.consumable_value")
local Packs  = require("engine.packs")
local Pacing = require("engine.pacing")

-- ---------------------------------------------------------------- args
local infile, outfile = arg[1], arg[2]
if not infile or not outfile then io.stderr:write("usage: seed_flip_probe.lua <fixtures> <out> [opts]\n"); os.exit(2) end
local KINDS, NRUNS, LIMIT, K, MULTS = { shop = true, pack = true }, nil, nil, 6, { 2, 4, 8 }
local SHARD, NSHARDS, SELFCHECK, TIMING, DECOMP = 1, 1, false, nil, nil
local SKIPFILES = {}
do
  local i = 3
  while arg[i] do
    local a = arg[i]
    if a == "--kinds" then KINDS = {}; for k in arg[i + 1]:gmatch("[^,]+") do KINDS[k] = true end; i = i + 1
    elseif a == "--runs" then NRUNS = tonumber(arg[i + 1]); i = i + 1
    elseif a == "--limit" then LIMIT = tonumber(arg[i + 1]); i = i + 1
    elseif a == "--K" then K = tonumber(arg[i + 1]); i = i + 1
    elseif a == "--mults" then MULTS = {}; for m in arg[i + 1]:gmatch("[^,]+") do MULTS[#MULTS + 1] = tonumber(m) end; i = i + 1
    elseif a == "--shard" then SHARD, NSHARDS = tonumber(arg[i + 1]), tonumber(arg[i + 2]); i = i + 2
    elseif a == "--selfcheck" then SELFCHECK = true
    elseif a == "--skip" then for f in arg[i + 1]:gmatch("[^,]+") do SKIPFILES[#SKIPFILES + 1] = f end; i = i + 1
    elseif a == "--decompose" then DECOMP = {}; for f in arg[i + 1]:gmatch("[^,]+") do DECOMP[#DECOMP + 1] = f end; i = i + 1
    elseif a == "--timing" then TIMING = {}; for m in arg[i + 1]:gmatch("[^,]+") do TIMING[#TIMING + 1] = tonumber(m) end; i = i + 1
    else io.stderr:write("unknown arg " .. a .. "\n"); os.exit(2) end
    i = i + 1
  end
end

-- ---------------------------------------------------------------- contexts, salts, multipliers
local CTX = { "pace", "pack", "pool", "joker", "cons" }
local CTXID = { pace = 1, pack = 2, pool = 3, joker = 4, cons = 5 }
local salt, mult = {}, {}
-- the multiplier has three DIMENSIONS; `mult` sets all three, the --decompose arms set one:
--   multJ = per-call JokerValue samples, multM = jokers drawn from a pool (measure_count), multR = expected_pick trials
local multJ, multM, multR = {}, {}, {}
local FN_ONLY           -- --decompose: in the joker context, salt only this JokerValue function
local function reset()
  for _, c in ipairs(CTX) do salt[c] = 0; mult[c] = 1; multJ[c] = nil; multM[c] = nil; multR[c] = nil end
  FN_ONLY = nil
end
local function mJ(c) return multJ[c] or mult[c] end
local function mM(c) return multM[c] or mult[c] end
local function mR(c) return multR[c] or mult[c] end
reset()
local stack = {}
local function cur(default) return stack[#stack] or default end

local function offset(s, cid, t)
  local h = (s * 2654435761 + cid * 97531 + t * 40503) % 2147483647
  h = (h * 16807) % 2147483647; h = (h * 16807) % 2147483647; h = (h * 16807) % 2147483647
  return h / 2147483647
end
local IS_WRAP = setmetatable({}, { __mode = "k" })
local MEMO = setmetatable({}, { __mode = "k" })
local function rot(rng, c)
  if type(rng) ~= "function" or IS_WRAP[rng] or salt[c] == 0 then return rng end
  local m = MEMO[rng]; if not m then m = {}; MEMO[rng] = m end
  local key = c .. ":" .. salt[c]
  local w = m[key]
  if not w then
    local s, cid, t = salt[c], CTXID[c], 0
    w = function()
      t = t + 1
      local r = rng() + offset(s, cid, t)
      if r >= 1 then r = r - 1 end
      return r
    end
    IS_WRAP[w] = true; m[key] = w
  end
  return w
end

local VALLOG   -- when a table: every pace margin / pack / pool EV an evaluation computes, in call order
local function logv(c, fn, v)
  if VALLOG and type(v) == "number" then VALLOG[#VALLOG + 1] = { c, fn, math.floor(v * 1e4 + 0.5) / 1e4 } end
end
local INSTALLED = false
local ORIG = {}
local function with_ctx(c, force, f, ...)
  local cc = force and c or cur(c)
  stack[#stack + 1] = cc
  local res = { pcall(f, ...) }
  stack[#stack] = nil
  if not res[1] then error(res[2], 0) end
  return unpack(res, 2, table.maxn(res))
end

-- JokerValue leaves: rotate the rng, scale samples (once -- only here)
local JV_OPTS = { score_delta = { 3, 8 }, remove_delta = { 3, 8 }, avg_score = { 2, 8 }, top_score = { 2, 20 },
                  deck_buff_delta = { 3, 8 } }
local function install()
  if INSTALLED then return end
  INSTALLED = true
  for fn, spec in pairs(JV_OPTS) do
    local f = JV[fn]; ORIG["JV." .. fn] = f
    local oi, dflt = spec[1], spec[2]
    JV[fn] = function(...)
      local c = cur("joker")
      local args = { ... }
      local o = args[oi] or {}
      local o2 = {}
      for k, v in pairs(o) do o2[k] = v end
      o2.rng = (FN_ONLY and c == "joker" and FN_ONLY ~= fn) and o.rng or rot(o.rng, c)
      if mJ(c) ~= 1 then o2.samples = math.floor((o.samples or dflt) * mJ(c) + 0.5) end
      args[oi] = o2
      return with_ctx(c, false, f, unpack(args, 1, math.max(oi, table.maxn(args))))
    end
  end
  -- ConsumableValue: context + rotate any rng argument (positional function or opts.rng); no sample scaling here
  for fn, f in pairs(CV) do
    if type(f) == "function" then
      ORIG["CV." .. fn] = f
      CV[fn] = function(...)
        local c = cur("cons")
        local args, n = { ... }, select("#", ...)
        for i = 1, n do
          local a = args[i]
          if type(a) == "function" then args[i] = rot(a, c)
          elseif type(a) == "table" and type(a.rng) == "function" then
            local o2 = {}; for k, v in pairs(a) do o2[k] = v end
            o2.rng = rot(a.rng, c); args[i] = o2
          end
        end
        -- card_add_value samples its own hands (12) without going through JokerValue: scale it at this leaf
        if fn == "card_add_value" and mJ(c) ~= 1 then
          local o = args[3] or {}
          local o2 = {}; for k, v in pairs(o) do o2[k] = v end
          o2.samples = math.floor((o.samples or 12) * mJ(c) + 0.5); args[3] = o2; n = math.max(n, 3)
        end
        return with_ctx(c, false, f, unpack(args, 1, n))
      end
    end
  end
  -- Packs: value = the shop pack EV (forced context); the other pool EVs inherit or default to "pool"
  local function packs_wrap(fn, c, force, oi)
    local f = Packs[fn]; ORIG["Packs." .. fn] = f
    Packs[fn] = function(...)
      local cc = force and c or cur(c)
      local args, n = { ... }, select("#", ...)
      local o = args[oi]
      if type(o) == "table" then
        local o2 = {}; for k, v in pairs(o) do o2[k] = v end
        o2.rng = rot(o.rng, cc)
        if mM(cc) ~= 1 then o2.measure_count = math.floor((o.measure_count or 8) * mM(cc) + 0.5) end
        args[oi] = o2
      end
      local depth = #stack
      local r1, r2 = with_ctx(cc, force, f, unpack(args, 1, math.max(n, oi)))
      if depth == 0 or force then logv(cc, fn, r1) end   -- outermost pool call, or any shop pack EV
      return r1, r2
    end
  end
  packs_wrap("value", "pack", true, 3)
  packs_wrap("expected_shop_joker", "pool", false, 3)
  packs_wrap("expected_joker_of_rarity", "pool", false, 3)
  packs_wrap("mean_random", "pool", false, 3)
  packs_wrap("black_hole_value", "pool", false, 2)
  -- expected_pick: same algorithm as engine/packs.lua, trials 40 x mult (asserted identical at mult 1 by --selfcheck)
  ORIG["Packs.expected_pick"] = Packs.expected_pick
  Packs.expected_pick = function(items, n, k, rng)
    local c = cur("pool")
    rng = rot(rng or math.random, c)
    if #items == 0 then return 0 end
    k = math.min(k, n)
    local total = 0
    for _, it in ipairs(items) do total = total + (it.w or 1) end
    if total <= 0 then return 0 end
    local function draw()
      local x = rng() * total
      local acc = 0
      for _, it in ipairs(items) do
        acc = acc + (it.w or 1)
        if x <= acc then return it.v end
      end
      return items[#items].v
    end
    local R = math.floor(40 * mR(c) + 0.5)
    local sum = 0
    for _ = 1, R do
      local drawn = {}
      for _ = 1, n do drawn[#drawn + 1] = draw() end
      table.sort(drawn, function(a, b) return a > b end)
      for i = 1, k do sum = sum + (drawn[i] or 0) end
    end
    return sum / R
  end
  local pace = Pacing.pace; ORIG["Pacing.pace"] = pace
  Pacing.pace = function(...)
    local pc = with_ctx("pace", true, pace, ...)
    if pc then logv("pace", "margin", pc.margin) end
    return pc
  end
end
local function uninstall()
  if not INSTALLED then return end
  INSTALLED = false
  for k, f in pairs(ORIG) do
    local mod, fn = k:match("^(%w+)%.(.+)$")
    local M = (mod == "JV" and JV) or (mod == "CV" and CV) or (mod == "Packs" and Packs) or Pacing
    M[fn] = f
  end
end

-- ---------------------------------------------------------------- one evaluation -> pick id
local function name_of(x) return x and (x.key or x.name) or nil end
local function shop_pick(r)
  local b = r and r.best
  if not b then return "NONE" end
  local t = b.target
  local tn = type(t) == "table" and (t.key or t.name) or (type(t) == "string" and t) or nil
  local id = b.type .. (tn and ("|" .. tn) or "")
  if b.swap_for then id = id .. ">" .. tostring(name_of(b.swap_for)) end
  return id, b.value, r.alternatives and r.alternatives[1] and r.alternatives[1].value,
         r.pace and { risk = r.pace.risk, urgent = r.pace.urgent, margin = r.pace.margin } or nil
end
local function pack_pick(r)
  if not r then return "NONE" end
  if r.skip then return "SKIP" end
  local it = r.best
  if not it then return "NONE" end
  local v1, v2
  for _, x in ipairs(r.ranked or {}) do
    if x.it == it then v1 = x.v elseif x.v and (not v2 or x.v > v2) then v2 = x.v end
  end
  return "PICK|" .. tostring(it.key), v1, v2
end

local function eval(kind, fix)
  local gs = RF.rehydrate(fix)
  math.randomseed(12345)
  if kind == "shop" then return shop_pick(SA.recommend(gs, {})) end
  return pack_pick(PO.recommend(gs))
end

-- one arm: salt 0..K for the given contexts (others at salt 0) with multiplier m on `mctx`
local function arm(kind, fix, ctxs, mctx, m, setup)
  local picks, extra, vals = {}, {}, {}
  for s = 0, K do
    reset()
    for _, c in ipairs(ctxs) do salt[c] = s end
    if mctx then for _, c in ipairs(mctx) do mult[c] = m end end
    if setup then setup() end
    if DECOMP then VALLOG = {} end
    local ok, id, v1, v2, pc = pcall(eval, kind, fix)
    if VALLOG then vals[#vals + 1] = VALLOG; VALLOG = nil end
    picks[#picks + 1] = ok and id or ("ERR:" .. tostring(id):sub(1, 80))
    extra[#extra + 1] = pc and { pc.urgent and 1 or 0, pc.risk and math.floor(pc.risk * 1000 + 0.5) / 1000 or nil } or nil
  end
  reset()
  local first, flip = picks[1], false
  for i = 2, #picks do if picks[i] ~= first then flip = true end end
  local cnt, modal = {}, 0
  for _, p in ipairs(picks) do cnt[p] = (cnt[p] or 0) + 1; if cnt[p] > modal then modal = cnt[p] end end
  return { picks = picks, flip = flip, modal = modal / #picks, pace = (#extra > 0) and extra or nil,
           vals = (#vals > 0) and vals or nil }
end

-- ---------------------------------------------------------------- corpus selection
local keep_run
if NRUNS then
  local order, seen = {}, {}
  local fh = assert(io.open(infile))
  for line in fh:lines() do
    if line:find('"kind":"state"', 1, true) then
      local sd = line:match('"seed":"([^"]+)"')
      if sd and not seen[sd] then seen[sd] = true; order[#order + 1] = sd end
    end
  end
  fh:close()
  keep_run = {}
  for i = math.max(1, #order - NRUNS + 1), #order do keep_run[order[i]] = true end
end

local TARGET   -- ord -> { ctx... } in decompose mode
if DECOMP then
  TARGET = {}
  for _, f in ipairs(DECOMP) do
    for l in io.lines(f) do
      local ok, r = pcall(Json.decode, l)
      if ok and r and r.all and r.all.flip and r.by then
        local cs = {}
        for _, c in ipairs({ "pace", "pack", "pool", "joker", "cons" }) do if r.by[c] and r.by[c].flip then cs[#cs + 1] = c end end
        if #cs > 0 then TARGET[r.ord] = cs end
      end
    end
  end
end

-- resumable: decisions already in <out> (by ordinal) are skipped and new ones appended
local DONE = {}
do
  local f = io.open(outfile)
  if f then
    for l in f:lines() do local o = l:match('"ord":(%d+)'); if o then DONE[tonumber(o)] = true end end
    f:close()
  end
  for _, sf in ipairs(SKIPFILES) do   -- --skip: decisions finished in other output files (e.g. before a re-shard)
    local g = io.open(sf)
    if g then
      for l in g:lines() do local o = l:match('"ord":(%d+)'); if o then DONE[tonumber(o)] = true end end
      g:close()
    end
  end
end
local out = assert(io.open(outfile, "a"))
local fh = assert(io.open(infile))
local ord, done, nflip = 0, 0, 0
local t_start = os.clock()
for line in fh:lines() do
  if LIMIT and done >= LIMIT then break end
  if line:find('"kind":"state"', 1, true) then
    local kind = line:match('"decision":"(%a+)"') or "shop"
    local sd = line:match('"seed":"([^"]+)"')
    if KINDS[kind] and (not keep_run or keep_run[sd]) then
      ord = ord + 1
      if (ord - 1) % NSHARDS == SHARD - 1 and not DONE[ord] and (not TARGET or TARGET[ord]) then
        local ok, fix = pcall(Json.decode, line)
        if ok and fix and fix.gs then
          local t0 = os.clock()
          local g0 = GLOBAL_RNG_CALLS
          local rec = { seed = fix.seed, idx = fix.idx, ante = fix.ante, kind = kind, ord = ord }
          if SELFCHECK then
            uninstall()
            local okp, p = pcall(eval, kind, fix)
            rec.unwrapped = okp and p or "ERR"
          end
          install()
          if TARGET then
            rec.decomp = {}
            for _, c in ipairs(TARGET[ord]) do
              local d = {}
              if c == "pace" or c == "pack" or c == "pool" then
                -- estimator VALUE noise: its outputs across salts at x1 and at x4 (all dimensions)
                local a1 = arm(kind, fix, { c })
                local a4 = arm(kind, fix, { c }, { c }, 4)
                d.vals1, d.vals4 = a1.vals, a4.vals
              end
              if c == "pace" then
                -- (sweep already in the main record)
              elseif c == "joker" then
                for _, fn in ipairs({ "score_delta", "remove_delta", "avg_score", "top_score", "deck_buff_delta" }) do
                  local a = arm(kind, fix, { c }, nil, nil, function() FN_ONLY = fn end)
                  d[fn] = { flip = a.flip, modal = a.modal, picks = a.picks }
                end
              elseif c == "cons" then
                -- re-sweep: the main pass's multiplier missed card_add_value's own samples (fixed above)
                for _, m in ipairs(MULTS) do
                  local a = arm(kind, fix, { c }, { c }, m)
                  d["x" .. m] = { flip = a.flip, modal = a.modal, picks = a.picks }
                end
              else
                for _, dim in ipairs({ "J4", "M4", "R4" }) do
                  local tbl = (dim == "J4" and multJ) or (dim == "M4" and multM) or multR
                  local a = arm(kind, fix, { c }, nil, nil, function() tbl[c] = 4 end)
                  d[dim] = { flip = a.flip, modal = a.modal, picks = a.picks }
                end
              end
              rec.decomp[c] = d
            end
            out:write(Json.encode(rec) .. "\n"); out:flush(); done = done + 1
            io.stderr:write(("[%d] decomp %s#%s\n"):format(done, tostring(fix.seed), tostring(fix.idx)))
            goto continue
          end
          if TIMING then
            local function timed()   -- min of 2 calls trims scheduler jitter (caches are per call, nothing warms)
              local best = math.huge
              for _ = 1, 2 do local a = os.clock(); pcall(eval, kind, fix); best = math.min(best, os.clock() - a) end
              return best
            end
            reset(); rec.t1 = timed(); rec.tm = {}
            for _, c in ipairs(CTX) do
              rec.tm[c] = {}
              for _, m in ipairs(TIMING) do reset(); mult[c] = m; rec.tm[c][tostring(m)] = timed() end
            end
            -- the single-dimension fixes the decomposition points at: pool jokers drawn, pack best-K-of-N trials
            for _, m in ipairs(TIMING) do
              reset(); multM.pool = m; rec.tm.pool["M" .. m] = timed()
              reset(); multR.pack = m; rec.tm.pack["R" .. m] = timed()
            end
            reset()
            out:write(Json.encode(rec) .. "\n"); out:flush(); done = done + 1
            io.stderr:write(("[%d] timing %s#%s %.2fs\n"):format(done, tostring(fix.seed), tostring(fix.idx), rec.t1))
            goto continue
          end
          local okn, p0, v1, v2 = pcall(eval, kind, fix)
          rec.native = okn and p0 or ("ERR:" .. tostring(p0):sub(1, 120))
          rec.v1, rec.v2 = v1, v2
          rec.t_native = os.clock() - t0
          if SELFCHECK and rec.unwrapped ~= rec.native then rec.selfcheck_fail = true end
          if okn then
            local all = arm(kind, fix, CTX)
            rec.all = all
            if all.flip then
              nflip = nflip + 1
              rec.by = {}
              for _, c in ipairs(CTX) do rec.by[c] = arm(kind, fix, { c }) end
              rec.sweep = {}
              for _, c in ipairs(CTX) do
                if rec.by[c].flip then
                  rec.sweep[c] = {}
                  for _, m in ipairs(MULTS) do
                    local a = arm(kind, fix, { c }, { c }, m)
                    rec.sweep[c][tostring(m)] = { flip = a.flip, modal = a.modal, picks = a.picks }
                  end
                end
              end
              -- all estimators salted together, every flipping estimator at the top multiplier
              local mc = {}
              for _, c in ipairs(CTX) do if rec.by[c].flip then mc[#mc + 1] = c end end
              if #mc > 0 then
                local a = arm(kind, fix, CTX, mc, MULTS[#MULTS])
                rec.all_top = { flip = a.flip, modal = a.modal, picks = a.picks, m = MULTS[#MULTS], ctx = mc }
              end
            end
          end
          rec.global_rng = GLOBAL_RNG_CALLS - g0
          rec.t = os.clock() - t0
          out:write(Json.encode(rec) .. "\n"); out:flush()
          done = done + 1
          io.stderr:write(("[%d] %s %s#%s a%s %s  native=%s flip=%s  %.1fs (total %.0fs)\n"):format(
            done, kind, tostring(fix.seed), tostring(fix.idx), tostring(fix.ante), "",
            tostring(rec.native), tostring(rec.all and rec.all.flip), rec.t, os.clock() - t_start))
          ::continue::
        end
      end
    end
  end
end
fh:close(); out:close()
io.stderr:write(("done: %d decisions, %d flipped\n"):format(done, nflip))
