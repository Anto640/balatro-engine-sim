-- tools/burnt_aim.lua -- MEASURE Eval.BURNT_AIM (R12b's one unmeasured constant).
-- Runs the full sim with Burnt Joker on the starting board and, at every round's FIRST discard while Burnt is
-- owned (the discard Burnt levels), records the poker hand the discard forms and the per-hand worth of a level
-- of it (Eval._level_worth -- the same quantity the valuation prices) beside the worth of levelling the BEST
-- hand. The mean of worth(levelled) / worth(best) is the realised quality of a Burnt level, which is what
-- BURNT_AIM x best + (1 - BURNT_AIM) x chaff approximates. Also counts Burnt-owned blinds with NO discard
-- (fire rate). Read-only observer via World._capture: the runs are ordinary engine runs.
--
--   usage: luajit tools/burnt_aim.lua <n_seeds> [shard nshards]   -> sim_out/burnt_aim[__p<shard>].jsonl
--   summary: luajit tools/burnt_aim.lua report
local here = arg and arg[0] and arg[0]:gsub("[^/]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")
local Json = require("util.json")

if arg[1] == "report" then
  local n, q, aimed, fire_blinds, no_disc, by_ante = 0, 0, 0, 0, 0, {}
  local files = { "sim_out/burnt_aim.jsonl" }
  for k = 0, 63 do files[#files + 1] = "sim_out/burnt_aim__p" .. k .. ".jsonl" end   -- no `ls` on Windows luajit
  for _, f in ipairs(files) do
    local fh = io.open(f)
    if fh then fh:close() end
    for l in (fh and io.lines(f) or function() return nil end) do
      local r = Json.decode(l)
      if r.kind == "level" and r.best > 0 then
        local x = math.min(1, math.max(0, r.worth / r.best))
        n = n + 1; q = q + x; if r.aimed then aimed = aimed + 1 end
        local a = by_ante[r.ante] or { n = 0, q = 0 }; a.n = a.n + 1; a.q = a.q + x; by_ante[r.ante] = a
      elseif r.kind == "blind" then
        fire_blinds = fire_blinds + 1; if not r.discarded then no_disc = no_disc + 1 end
      end
    end
  end
  print(("first discards with Burnt: %d   mean worth(levelled)/worth(best) = %.3f   engine-aimed share %.3f")
    :format(n, n > 0 and q / n or 0, n > 0 and aimed / n or 0))
  print(("Burnt-owned blinds: %d   with NO discard at all: %d (%.1f%%)"):format(fire_blinds, no_disc,
    fire_blinds > 0 and 100 * no_disc / fire_blinds or 0))
  for a = 1, 8 do local t = by_ante[a]; if t then print(("  ante %d  n %4d  quality %.3f"):format(a, t.n, t.q / t.n)) end end
  return
end

local World   = require("sim.world")
local Driver  = require("sim.driver")
local Content = require("sim.content")
local Eval    = require("engine.eval_function")
local CV      = require("engine.consumable_value")
local HandEval = require("engine.hand_eval")

local n = tonumber(arg[1]) or 40
local shard, nshards = tonumber(arg[2]), tonumber(arg[3])
local out = "sim_out/burnt_aim" .. (shard and ("__p" .. shard) or "") .. ".jsonl"
local fh = assert(io.open(out, "w"))
local function lcg(s) return function() s = (s * 1103515245 + 12345) % 2147483648; return s / 2147483648 end end
local function owns_burnt(gs) for _, j in ipairs(gs.jokers or {}) do if j.key == "j_burnt" then return true end end end

local seed_now, blinds = nil, {}
World._capture = function(gs, ranked)
  if not owns_burnt(gs) then return end
  local b = gs.blind or {}
  local bkey = tostring(gs.meta and gs.meta.ante) .. "|" .. tostring(gs.meta and gs.meta.round) .. "|" .. tostring(b.blind_type)
  if not blinds[bkey] then blinds[bkey] = { ante = gs.meta and gs.meta.ante, discarded = false } end
  local a = ranked and ranked.best
  if not (a and a.type == "DISCARD" and (b.discards_used or 0) == 0 and (b.discards_left or 0) > 0) then return end
  blinds[bkey].discarded = true
  local ht = (HandEval.analyze(a.cards, {}))
  local freq, bctx = CV.hand_frequencies(gs, { samples = 8, rng = lcg(17) })
  if not freq or not ht then return end
  local best, best_h = 0, nil
  for h in pairs(freq) do local w = Eval._level_worth(gs, h, freq, bctx); if w > best then best, best_h = w, h end end
  fh:write(Json.encode({ kind = "level", seed = seed_now, ante = gs.meta and gs.meta.ante, hand = ht, best_hand = best_h,
    worth = Eval._level_worth(gs, ht, freq, bctx), best = best, aimed = a.burnt and true or false }) .. "\n")
end

for s = 1, n do
  if (not nshards) or ((s - 1) % nshards) == shard then
    local seed = s * 1000 + 3
    seed_now = seed; blinds = {}
    local run = World.new_run(seed, {})
    run.jokers[1] = { key = "j_burnt", name = "Burnt Joker", sell_value = 4, cost = 8, ability = { extra = {}, eternal = true } }   -- eternal: kept all run, so every round samples
    local res = Driver.run(seed, { content = Content, max_ante = 8, run = run, silent = true })
    for _, v in pairs(blinds) do fh:write(Json.encode({ kind = "blind", seed = seed, ante = v.ante, discarded = v.discarded }) .. "\n") end
    fh:flush()
    io.write(("[%s] seed %d -> %s\n"):format(tostring(shard), seed, res.won and "won" or ("died ante " .. tostring(res.death_ante))))
  end
end
fh:close()
