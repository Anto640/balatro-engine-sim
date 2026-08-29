-- tools/decision_review.lua
-- ENGINE DECISION REVIEW (2026-08-29): replay the CURRENT engine over one captured run and render
-- a human-readable sheet of every SHOP/PACK decision — the engine's recommendation + reasoning +
-- the ranked alternatives, beside what the human actually did — for the owner to COMMENT on.
-- This is the "follow the engine and comment" workflow: a dense, causal advice-quality signal that
-- works on ANY fixture-logged run (win OR loss), not just wins. Blind decisions are skipped by
-- default (expensive MC + less about conversion); pass `blind` to include them.
--
--   usage: luajit tools/decision_review.lua <seed> [fixtures.jsonl] [runs.jsonl] [blind]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json = require("util.json")
local RF   = require("core.replay_fixture")
local SA   = require("engine.shop_advisor")
local PO   = require("engine.pack_open_advisor")

local SEED = arg[1] or error("usage: decision_review.lua <seed> [fixtures] [runs] [blind]")
local FX   = arg[2] or "data/agreement_corpus/fixtures.jsonl"
local RN   = arg[3] or "data/agreement_corpus/runs.jsonl"
local WITH_BLIND = arg[4] == "blind"

local function load(p)
  local out, fh = {}, io.open(p); if not fh then error("cannot open " .. p) end
  for line in fh:lines() do if line:match("%S") then local ok, r = pcall(Json.decode, line); if ok then out[#out + 1] = r end end end
  fh:close(); return out
end
local fixs, runs = load(FX), load(RN)

-- human timeline for this seed: buys / rerolls / pack picks / plays, time-ordered
local ev = {}
for _, r in ipairs(runs) do
  if tostring(r.seed) == SEED and r.t then
    if r.kind == "joker_gain" or r.kind == "consumable_gain" or r.kind == "voucher_gain" then
      ev[#ev + 1] = { t = r.t, what = "BUY " .. (r.key or "?") .. (r.via and (" (" .. r.via .. ")") or "") }
    elseif r.kind == "reroll" then ev[#ev + 1] = { t = r.t, what = "REROLL" }
    elseif r.kind == "pack_pick" then ev[#ev + 1] = { t = r.t, what = "PICK " .. (r.key or "?") }
    elseif r.kind == "joker_loss" then ev[#ev + 1] = { t = r.t, what = "SELL/LOSE " .. (r.key or "?") }
    end
  end
end
table.sort(ev, function(a, b) return a.t < b.t end)
local outcome
for _, r in ipairs(runs) do if tostring(r.seed) == SEED and (r.kind == "win" or r.kind == "death") then outcome = r.kind end end

-- fixtures for this seed, time-ordered
local mine = {}
for _, r in ipairs(fixs) do if r.kind == "state" and tostring(r.seed) == SEED then mine[#mine + 1] = r end end
table.sort(mine, function(a, b) return (a.t or 0) < (b.t or 0) end)

local function human_between(t, hi)
  local out = {}
  for _, e in ipairs(ev) do if t and e.t > t and (not hi or e.t <= hi) then out[#out + 1] = e.what end end
  return out
end
local function jkeys(gs)
  local t = {}; for _, j in ipairs(gs.jokers or {}) do t[#t + 1] = (j.key or "?"):gsub("^j_", "") end
  return table.concat(t, ", ")
end
local function lcg(seed) local x = math.floor(seed) % 2147483647; if x <= 0 then x = x + 2147483646 end
  return function() x = (x * 16807) % 2147483647; return (x - 1) / 2147483646 end end
local function money(gs) return (gs.economy and gs.economy.dollars) or 0 end

print(("# Engine decision review — seed %s (%s)"):format(SEED, outcome or "?"))
print("")
print("Each row: the engine's recommendation (value, reasoning) vs what you did. Comment on any the")
print("engine got wrong — that's the signal. `>>` marks a disagreement (engine's pick ≠ your action).")
print("")

for i, fx in ipairs(mine) do
  local dec = fx.decision
  if dec == "blind" and not WITH_BLIND then goto continue end
  local gs = RF.rehydrate(fx)
  local rng = lcg((tonumber(fx.idx) or i) * 2654435761)
  local hi = mine[i + 1] and mine[i + 1].t or nil
  local human = human_between(fx.t, hi)
  local htxt = (#human > 0) and table.concat(human, "; ") or "SAVE / (nothing)"

  if dec == "shop" then
    local ok, rec = pcall(SA.recommend, gs, { reserve = 0, rng = rng })
    if ok and rec and rec.best then
      local b = rec.best
      local tgt = (type(b.target) == "table" and (b.target.name or b.target.key)) or b.target or ""
      local alts = {}
      for _, a in ipairs(rec.alternatives or {}) do
        if #alts < 2 then
          local at = (type(a.target) == "table" and (a.target.name or a.target.key)) or a.target or ""
          alts[#alts + 1] = ("%s %s (%.1f)"):format(a.type, at, a.value or 0)
        end
      end
      local eng = ("%s %s (val %.1f)"):format(b.type, tostring(tgt), b.value or 0)
      local flag = htxt:find(tostring(tgt) or "\0", 1, true) and "  " or ">>"
      print(("### [%s] SHOP · ante %s · $%d · board: {%s}"):format(flag, tostring(fx.ante), money(gs), jkeys(gs)))
      print(("- **Engine:** %s"):format(eng))
      if b.reason then print(("  - _%s_"):format((b.reason:gsub("%s+", " ")))) end
      if #alts > 0 then print(("  - alts: %s"):format(table.concat(alts, " | "))) end
      print(("- **You:** %s"):format(htxt))
      print("")
    end
  elseif dec == "pack" then
    local ok, rec = pcall(PO.recommend, gs, { rng = rng })
    if ok and rec then
      local pick = rec.skip and "SKIP" or (rec.best and ((rec.best.name or rec.best.key or "?") .. (rec.best.v and (" (%.1f)"):format(rec.best.v) or "")) or "?")
      print(("### [pack] PACK · ante %s · board: {%s}"):format(tostring(fx.ante), jkeys(gs)))
      print(("- **Engine picks:** %s"):format(pick))
      if rec.best and rec.best.reason then print(("  - _%s_"):format((tostring(rec.best.reason):gsub("%s+", " ")))) end
      print(("- **You:** %s"):format(htxt))
      print("")
    end
  end
  ::continue::
end
