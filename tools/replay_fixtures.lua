-- tools/replay_fixtures.lua
-- OFFLINE replay of captured decision fixtures under the CURRENT engine -- the "run the evaluation
-- while you sleep" half of the per-decision agreement objective (methodology-shift-2026-08, Step 2).
--
-- The live mod's CAPTURE-ONLY mode (main.lua) logs the full STATE of every shop / pack / in-blind
-- decision to bes_fixtures.jsonl WITHOUT running the Monte-Carlo engine (so play is lag-free). This
-- tool does the expensive part unattended: rehydrate each fixture and run the engine that owns that
-- channel (shop_advisor / pack_open_advisor / decision_engine), recording what the engine would do.
-- A later pass joins these picks against what the HUMAN actually did (from bes_runs.jsonl) to score
-- agreement -- the dense, low-chaos signal the whole methodology turn is built on.
--
--   usage: luajit tools/replay_fixtures.lua <fixtures.jsonl> [out.jsonl]
--     out.jsonl (optional): one engine-pick record per decision, for the agreement join.
-- Deterministic: a fixed per-fixture RNG, so replaying the same corpus is byte-identical.

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json = require("util.json")
local RF   = require("core.replay_fixture")
local SA   = require("engine.shop_advisor")
local PO   = require("engine.pack_open_advisor")
local DE   = require("engine.decision_engine")

local function lcg(seed)
  local s = math.floor(seed) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end

local infile  = arg[1] or "bes_fixtures.jsonl"
local outfile = arg[2]
local fh = io.open(infile)
if not fh then io.stderr:write("cannot open " .. infile .. "\n"); os.exit(1) end
local out = outfile and io.open(outfile, "w") or nil

-- one advisor per channel. shop/blind ranked.best is an action { type, value, target?, hand_type? };
-- pack is different -- PO.recommend returns best = the chosen ITEM { key, set, name, v } OR skip=true
-- (a valid "don't take anything" decision, NOT an error). Normalise all three to one pick shape.
local REPLAY = {
  shop  = function(gs, rng) return SA.recommend(gs, { rng = rng }) end,
  pack  = function(gs, rng) return PO.recommend(gs, { rng = rng }) end,
  blind = function(gs, rng) return DE.decide(gs, { rng = rng }) end,
}
local function pick_of(kind, ranked)
  if not ranked then return nil end
  if kind == "pack" then
    if ranked.skip then return { type = "SKIP_PACK" } end
    local it = ranked.best
    if not it then return nil end
    return { type = "PICK", key = it.key, set = it.set,
             target = it.name or it.key, value = it.v }
  end
  local b = ranked.best
  if not b then return nil end
  local cards  -- the card ids the engine would PLAY/DISCARD (blind) -> compare to the human's play
  if b.cards then cards = {}; for _, c in ipairs(b.cards) do cards[#cards + 1] = c.id end end
  return { type = b.type, value = b.value, hand_type = b.hand_type, cards = cards,
           target = b.target and (b.target.name or b.target.key) or nil }
end

local n, bykind, errs, plays = 0, {}, 0, 0
for line in fh:lines() do
  if line:match('"kind":"play"') then
    plays = plays + 1     -- the human's ACTUAL in-blind play (joined to a blind fixture by seed+t)
  elseif line:match('"kind":"state"') then
    local ok, fix = pcall(Json.decode, line)
    if ok and fix and fix.gs then
      local kind = fix.decision or "shop"
      local replay = REPLAY[kind]
      if replay then
        local seed = (tonumber(fix.seed) or 1) * 100003 + (tonumber(fix.idx) or 0) * 31 + 7
        local ok2, ranked = pcall(replay, RF.rehydrate(fix), lcg(seed))
        local pick = ok2 and pick_of(kind, ranked) or nil
        if pick then
          n = n + 1; bykind[kind] = (bykind[kind] or 0) + 1
          local rec = {
            seed = fix.seed, idx = fix.idx, t = fix.t, decision = kind, ante = fix.ante,
            engine = pick,
            advice = fix.chose,   -- the engine's OWN advice at capture (NOT the human's action;
                                  -- present only when the mod was NOT in capture-only mode)
          }
          if out then out:write(Json.encode(rec) .. "\n") end
        else errs = errs + 1 end
      end
    else errs = errs + 1 end
  end
end
fh:close(); if out then out:close() end

print(("replayed %d decisions from %s"):format(n, infile:gsub(".*/", "")))
for _, k in ipairs({ "shop", "pack", "blind" }) do
  if bykind[k] then print(("  %-6s %5d"):format(k, bykind[k])) end
end
if plays > 0 then print(("  %-6s %5d  (human's actual in-blind plays, for the blind-agreement join)"):format("plays", plays)) end
if errs > 0 then print(("  (%d fixtures skipped: decode/replay error)"):format(errs)) end
if outfile then print("  engine picks -> " .. outfile .. " (join vs bes_runs.jsonl for agreement)") end
