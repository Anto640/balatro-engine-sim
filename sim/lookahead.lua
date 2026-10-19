-- sim/lookahead.lua -- SHALLOW LOOK-AHEAD at shop decisions (2026-10-18, owner: "treat it like a chess engine where
-- every random event is the opponent's move ... and calculate which response is best").
--
-- At a shop decision in the early antes, the engine's own top choices are compared by PLAYING THEM FORWARD: each
-- candidate is applied to a copy of the run, the rest of that shop is finished by the normal engine, then the rest of
-- the ante and the next ante are played by the normal engine, several times over freshly sampled futures (the rollout
-- streams are SALTED: a fork never sees the real run's coming shops / deals / bosses). The candidate whose futures go
-- best is taken. This is expectimax over chance with the engine itself as the policy inside the rollouts -- a
-- one-ply search -- not a re-valuation: it never reads the engine's prices.
--
--   value of one rollout = died ? 0.5 * (fraction of the horizon's blinds cleared)
--                                : 1 + 0.12 * clamp(log2(margin at the horizon), -4, 4)
-- (dying is what matters; among survivors, the board's measured pace over the requirement breaks the tie.)
--
-- Sim-only (the live overlay never runs it). Enabled by a probe config (`lookahead`); inert otherwise.

local Driver = require("sim.driver")
local World  = require("sim.world")

local LA = {}
LA.UNTIL_ANTE = 3     -- search the shops of antes 1..3 (the early board decides runs: MCTS_PLAN Phase 1)
LA.SAMPLES    = 4     -- sampled futures per candidate (same salts across candidates: common random numbers)
LA.HORIZON    = tonumber(os.getenv and os.getenv("BES_LA_HORIZON") or "") or 1   -- antes beyond the current one to play
-- leaf among SURVIVING futures: "pace" = the pace model's projected margin at ante 8 (hand-set growth constants);
-- "cap" = the board's MEASURED capacity over the next boss's requirement at the horizon -- no projection, so every
-- candidate is judged at the same point by what its board actually scores (owner: the projection is arbitrary)
LA.LEAF       = (os.getenv and os.getenv("BES_LA_LEAF")) or "pace"
LA.MARGIN     = 0.02  -- an alternative must beat the engine's own choice by this much (noise guard)
LA.SALT       = 900001

-- deep copy with a memo (shared references stay shared: a candidate's target is the copied shop item / joker),
-- functions dropped (run.rng is rebuilt below)
local function copy(v, memo)
  if type(v) ~= "table" then return v end
  if memo[v] then return memo[v] end
  local o = {}
  memo[v] = o
  for k, x in pairs(v) do
    if type(x) ~= "function" then o[copy(k, memo)] = copy(x, memo) end
  end
  return o
end

local SPEND = { BUY_JOKER = true, BUY_PACK = true, BUY_VOUCHER = true, BUY_CONSUMABLE = true, REROLL = true,
                SELL_TO_BUY = true, SELL_JOKER = true }
local function same(a, b)
  return a.type == b.type and a.target == b.target
end

-- the engine's best, its best alternative of a different action, and leaving the shop
function LA.candidates(ranked)
  local best = ranked.best
  local cs = { best }
  for _, a in ipairs(ranked.alternatives or {}) do
    if SPEND[a.type] and not same(a, best) and type(a.value) == "number" then cs[#cs + 1] = a; break end
  end
  if best.type ~= "SAVE" then cs[#cs + 1] = { type = "SAVE", value = 0, reason = "look-ahead: leave the shop" } end
  return cs
end

-- TRANSPOSITIONS (2026-10-18): in 28% of la_7's decisions two candidates ended the shop in the SAME position (buy the
-- pack then the joker, or the joker then the pack). Every future re-seeds its random streams from the salt at the next
-- checkpoint, so an identical post-shop position has an identical future: it is played out once per future and its
-- value reused. Exact -- values are unchanged, only repeated work is skipped.
local function serialize(v, out, seen)
  local t = type(v)
  if t == "table" then
    if seen[v] then out[#out + 1] = "@"; return end
    seen[v] = true
    -- keys are ordered by their own CONTENT (some run tables are sets keyed by card / joker tables)
    local entries = {}
    for k, x in pairs(v) do
      if type(x) ~= "function" then
        local ks
        if type(k) == "table" then local o = {}; serialize(k, o, seen); ks = "t" .. table.concat(o)
        else ks = type(k):sub(1, 1) .. tostring(k) end
        entries[#entries + 1] = { ks, x }
      end
    end
    table.sort(entries, function(a, b) return a[1] < b[1] end)
    out[#out + 1] = "{"
    for _, e in ipairs(entries) do
      out[#out + 1] = e[1]; out[#out + 1] = "="
      serialize(e[2], out, seen); out[#out + 1] = ";"
    end
    out[#out + 1] = "}"
    seen[v] = nil
  elseif t == "number" then out[#out + 1] = string.format("%.17g", v)
  else out[#out + 1] = tostring(v) end
end
local function position_key(f)
  local out = {}
  serialize(f, out, {})
  return table.concat(out)
end

-- one sampled future of taking `cand` now, in two stages: finish the shop (returns the forked run), then play it out
local function prepare(run, shop, crn_n, cand, s)
  local Content = require("sim.content")
  local st = copy({ run = run, shop = shop, cand = cand, crn = crn_n }, {})
  local f, fshop = st.run, st.shop
  f._salt = (run._salt or 0) + LA.SALT + s * 7919 + (run.round or 0) * 104729
  f.rng = World.lcg(World.stream_seed(f, "lookahead", run.ante or 1, run.round or 0, s))
  f._emit, f._la_rollout = nil, true
  if f.probe then f.probe.lookahead = nil end
  if st.cand.type == "SAVE" then
    -- leave: nothing more is bought in this shop (an emptied shop -> the engine saves; exit effects still run)
    fshop.jokers, fshop.boosters, fshop.vouchers, fshop.consumables = {}, {}, {}, {}
    fshop.reroll_cost, f.reroll_cost = 1e9, 1e9
  else
    Content._apply_action(f, fshop, st.cand, f.rng)   -- then the engine finishes the shop as usual
  end
  Content._shop_loop(f, fshop, f.rng, st.crn)
  return f
end

local function play_out(run, f)
  local Content = require("sim.content")
  local start_round = f.round or 0
  local horizon = math.min(8, (run.ante or 1) + LA.HORIZON)
  local res = Driver.run(f.seed, { run = f, content = Content, max_ante = horizon, silent = true, resume = true })
  local total = 0
  for a = run.ante or 1, horizon do total = total + 3 end
  total = total - (run._blind_idx or 0)
  if res.won then return 2 end
  if res.death_ante then
    local cleared = math.max(0, (f.round or 0) - start_round - 1)
    return 0.5 * math.min(1, cleared / math.max(1, total))
  end
  local m = Driver._metrics(f)
  local pm
  if LA.LEAF == "cap" then
    local req = require("engine.mechanics").blind_requirement(math.min(8, horizon + 1), "Boss")
    pm = ((m and m.capacity) or 0) / math.max(1, req)
  else
    pm = (m and m.pace_margin) or 1
  end
  -- survivors: 1 + 0.12 x log2(margin), clamped at +-4 -> [0.52, 1.48], always above any death (<= 0.5). It was
  -- 0.25 x clamp(+-2): early boards far ahead of the requirement all hit the 1.5 ceiling (9% of la_7's decisions had
  -- EVERY option there, 31% at least one), so the search could not rank them.
  local l = math.log(math.max(1e-6, pm)) / math.log(2)
  if l > 4 then l = 4 elseif l < -4 then l = -4 end
  return 1 + 0.12 * l
end

-- Evaluate the candidates; returns a ranked table to replace the engine's (or nil to keep it) and a trace record.
function LA.choose(run, shop, crn_n, ranked)
  local cs = LA.candidates(ranked)
  if #cs < 2 then return nil end
  local vals, per, errs, dups = {}, {}, 0, 0
  for i = 1, #cs do vals[i] = 0; per[i] = {} end
  for s = 1, LA.SAMPLES do
    local seen = {}   -- post-shop position -> value, for this future
    for i, c in ipairs(cs) do
      local okp, f = pcall(prepare, run, shop, crn_n, c, s)
      local v
      if not okp then errs = errs + 1; v = 0
      else
        local okk, key = pcall(position_key, f)
        if not okk then key = {} end   -- unkeyable: a fresh key, never matches (no reuse)
        if seen[key] ~= nil then v = seen[key]; dups = dups + 1
        else
          local ok, pv = pcall(play_out, run, f)
          if not ok then errs = errs + 1; pv = 0 end
          v = pv; seen[key] = pv
        end
      end
      per[i][s] = v
      vals[i] = vals[i] + v
    end
  end
  for i = 1, #cs do vals[i] = vals[i] / LA.SAMPLES end
  -- switch away from the engine's choice only on a PAIRED gain (same salts) that clears the margin AND one standard
  -- error of the per-future differences: with few futures, noise would otherwise flip near-ties
  local bi, bgain = 1, 0
  for i = 2, #cs do
    local d, sum, sq = {}, 0, 0
    for s = 1, LA.SAMPLES do d[s] = per[i][s] - per[1][s]; sum = sum + d[s] end
    local mean = sum / LA.SAMPLES
    for s = 1, LA.SAMPLES do sq = sq + (d[s] - mean) ^ 2 end
    local se = math.sqrt(sq / math.max(1, LA.SAMPLES - 1) / LA.SAMPLES)
    if mean > LA.MARGIN and mean > se and mean > bgain then bi, bgain = i, mean end
  end
  local rec = { kind = "lookahead", ante = run.ante, round = run.round, chosen = bi, errors = errs, dups = dups, cands = {} }
  for i, c in ipairs(cs) do
    rec.cands[i] = { type = c.type, target = c.target and (c.target.key or c.target.name) or nil, value = vals[i] }
  end
  if bi == 1 then return nil, rec end
  local pick = cs[bi]
  pick.reason = string.format("look-ahead: %.3f vs the engine's choice %.3f", vals[bi], vals[1])
  return { best = pick, alternatives = ranked.alternatives, pace = ranked.pace }, rec
end

return LA
