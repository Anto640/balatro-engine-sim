-- tools/decision_audit.lua -- DECISION AUDIT (2026-10-11): which shop choices would have done better?
-- Replays a seed exactly (the sim is deterministic per seed) but replaces the engine's FIRST action at one shop visit
-- by an alternative -- its runner-up ("2"), its third choice ("3"), or leaving the shop ("save") -- or, with alt "flip", the
-- k-th in-blind play-or-discard decision by its best option of the other kind -- and lets the engine
-- play on. Compared with the unforced baseline arm on the same seed (common random numbers keep the world aligned),
-- the outcome difference is that one decision's consequence. Summarise with tools/decision_audit_report.py.
--   usage: luajit tools/decision_audit.lua <out.jsonl> <seed> <visit> <alt> [<seed> <visit> <alt> ...]
-- Writes, per job: the 'forced' record (what the engine chose, what replaced it, the values) and the run's
-- 'death'/'win' record, each tagged with job = "<seed>:<visit>:<alt>".
package.path = "./?.lua;./?/init.lua;" .. package.path
local Json    = require("util.json")
local Driver  = require("sim.driver")
local Content = require("sim.content")
local fh = assert(io.open(arg[1], "a"))
for i = 2, #arg - 2, 3 do
  local seed, visit, alt = tonumber(arg[i]), tonumber(arg[i + 1]), arg[i + 2]
  local job = seed .. ":" .. visit .. ":" .. alt
  if alt == "flip" then _G.BES_FORCE_INBLIND = { k = visit }
  elseif alt == "iplacebo" then _G.BES_FORCE_INBLIND = { k = visit, placebo = true }   -- in-blind placebo
  else _G.BES_FORCE = { visit = visit, alt = alt } end                                -- shop: 2 / 3 / save / placebo
  local res = Driver.run(seed, { content = Content, max_ante = 8 })
  local F = _G.BES_FORCE or _G.BES_FORCE_INBLIND
  local fr = F.record or { kind = "forced", visit = visit, alt = alt, missing = true }
  fr.job, fr.seed = job, seed
  fh:write(Json.encode(fr) .. "\n")
  for _, r in ipairs(res.records) do
    if r.kind == "death" or r.kind == "win" then r.job = job; fh:write(Json.encode(r) .. "\n") end
  end
  fh:flush()
  _G.BES_FORCE, _G.BES_FORCE_INBLIND = nil, nil
end
fh:close()
