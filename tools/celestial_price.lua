-- tools/celestial_price.lua
-- WHAT IS A CELESTIAL PACK ACTUALLY WORTH TO THE ENGINE, AND WHAT SHOULD IT BE?
--
-- The engine prices Celestial packs at roughly zero content value and buys 6.3% of them, while
-- the human buys 6.10 packs/ante and finishes on 7-41 hand levels against the engine's ~4.
-- `tools/pack_terms.lua` instruments the cost side inside a real run; this isolates the CONTENT
-- side, and it needs no simulation: build a representative board and call the real
-- `Packs.value` / `ConsumableValue` on it.
--
-- The comparison that matters is against the project's own probe-derived exchange rates:
--     $1            ~= 0.005 progress   (money dose-response, WINRATE_V3_PLAN)
--     one FREE level ~= 0.176 progress   (`level1` probe, granted to best_planet's hand)
-- so a level is worth ~$35 by the engine's own measured currency, against a $4-6 pack.
-- If `Packs.value` disagrees with that by a large factor, the leveling channel is mispriced at
-- the source and every downstream buy/skip decision inherits it.
--
-- Boards are taken from a real batch's ante snapshots so the deck/board context is not invented.
--
-- Usage:  lua tools/celestial_price.lua [sim_out/dig_base_all.jsonl] [ante]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local GS      = require("model.game_state")
local Packs   = require("engine.packs")
local CV      = require("engine.consumable_value")
local Cards   = require("util.cards")

local path = arg[1] or "sim_out/dig_base_all.jsonl"
local AT   = tonumber(arg[2]) or 3

-- a standard 52-card deck, in the POD shape the engine expects
local function fresh_deck()
  local d = {}
  for _, s in ipairs({ "S", "H", "D", "C" }) do
    for _, r in ipairs({ "2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K", "A" }) do
      d[#d + 1] = { id = #d + 1, rank = r, suit = s }
    end
  end
  return d
end

-- deterministic rng so repeated runs of this tool agree
local function lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return s / 2147483647 end
end

-- pull real ante-`AT` boards out of the batch
local boards = {}
local f = assert(io.open(path, "r"), "cannot open " .. path)
for line in f:lines() do
  local kind = line:gsub('"build_plan":%b{}', ''):match('"kind":"([^"]*)"')
  if kind == "ante" and tonumber(line:match('"ante":(%d+)')) == AT and #boards < 40 then
    local blob = line:match('"jokers":%[(.-)%]')
    local jk = {}
    if blob then for k in blob:gmatch('"([^"]+)"') do jk[#jk + 1] = { key = k } end end
    local lv = {}
    local lb = line:match('"hand_levels":(%b{})')
    if lb then for n, l in lb:gmatch('"([^"]+)":([%d%.]+)') do lv[n] = { level = tonumber(l) } end end
    if #jk > 0 then boards[#boards + 1] = { jokers = jk, levels = lv } end
  end
end
f:close()

print(("boards sampled from %s at ante %d: %d"):format(path, AT, #boards))
print("")

local PACKS = { "p_celestial_normal", "p_celestial_jumbo", "p_celestial_mega",
                "p_buffoon_normal", "p_arcana_normal", "p_standard_normal" }
local agg = {}
for _, key in ipairs(PACKS) do agg[key] = { n = 0, s = 0, min = 1e9, max = -1e9 } end
local best_gain = { n = 0, s = 0 }

for i, b in ipairs(boards) do
  local gs = GS.new{
    deck = fresh_deck(), jokers = b.jokers,
    economy = { dollars = 20, interest_cap = 5 },
    meta = { ante = AT },
    run = { hand_levels = b.levels, joker_slots = 5, consumable_slots = 2 },
  }
  local rng = lcg(i * 7919 + 13)
  for _, key in ipairs(PACKS) do
    local ok, v = pcall(Packs.value, gs, { key = key, name = key }, { rng = rng, samples = 8 })
    if ok and type(v) == "number" then
      local a = agg[key]
      a.n = a.n + 1; a.s = a.s + v
      if v < a.min then a.min = v end
      if v > a.max then a.max = v end
    end
  end
  -- the single best planet's own valuation, for reference
  local ok, bp = pcall(CV.best_planet, gs, { rng = lcg(i * 104729 + 7), samples = 8 })
  if ok and bp and bp.value then best_gain.n = best_gain.n + 1; best_gain.s = best_gain.s + bp.value end
end

print(("  %-22s %5s %10s %10s %10s"):format("pack", "n", "mean pv", "min", "max"))
for _, key in ipairs(PACKS) do
  local a = agg[key]
  if a.n > 0 then
    print(("  %-22s %5d %10.4f %10.4f %10.4f"):format(key, a.n, a.s / a.n, a.min, a.max))
  end
end
if best_gain.n > 0 then
  print("")
  print(("  best single planet's own value: %.4f  (n=%d)"):format(best_gain.s / best_gain.n, best_gain.n))
end

print("")
print("-- REFERENCE SCALES ------------------------------------------------------")
print("  Packs.value returns 'fraction of a boss hand'; shop_advisor multiplies by")
print("  SA.JOKER_SCORE_WEIGHT (5) and subtracts net_cost + econ_floor_penalty.")
print("  Probe-derived: $1 ~= 0.005 progress; one FREE level ~= 0.176 progress,")
print("  so a level is worth ~$35 of the engine's own currency against a $4-6 pack.")
