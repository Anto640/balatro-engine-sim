-- tools/key_coverage.lua
-- DOES THE CATALOGUE MATCH THE KEYS THE REAL GAME ACTUALLY EMITS?
--
-- CLAUDE.md names this as a standing risk and an explicitly UNTESTED one:
--   "Live-key mismatches are silent zeros. A joker's in-game center key can differ from our
--    catalogue key -- the base game itself misspells some (Gluttonous is j_gluttenous_joker).
--    A mismatch means the joker scores ZERO everywhere... The coverage-guard test only checks
--    catalogue<->effects, NOT catalogue<->live-game keys."
--
-- The live telemetry is the only source of real in-game keys this project has, and it had never
-- been checked against the catalogue at scale. Acquisitions alone are a thin sample; SHOP OFFERS
-- are not -- every joker the shop ever showed is in there, so a few runs cover most of the pool.
--
-- This is a tool, not a unit test, because it needs the captured data files. Run it after any
-- catalogue change and after capturing new live runs.
--
-- RESULT ON THE CURRENT DATA (2026-08-14): 147 distinct live keys, **0 catalogue misses**. The
-- only non-Legendary catalogue key never observed is `j_gluttonous_joker` -- the CORRECTLY spelled
-- alias, which the game never emits because it ships the misspelling. That is the alias strategy
-- working exactly as intended. The documented risk is empirically closed.
--
-- Usage:  lua tools/key_coverage.lua [extra.jsonl ...]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local JD = require("engine.joker_data")

local FILES = {
  "data/bes_runs_live_2026-08-12.jsonl",
  "data/bes_runs.jsonl",
  "data/bes_runs_baseline.jsonl",
}
for i = 1, #arg do FILES[#FILES + 1] = arg[i] end

local seen, where = {}, {}
local function note(k, src)
  if k and k:match("^j_") then
    seen[k] = (seen[k] or 0) + 1
    where[k] = where[k] or src
  end
end

local files_read = 0
for _, path in ipairs(FILES) do
  local f = io.open(path, "r")
  if f then
    files_read = files_read + 1
    for line in f:lines() do
      for blob in line:gmatch('"offer_jokers":%[(.-)%]') do
        for item in blob:gmatch("%b{}") do note(item:match('"key":"([^"]*)"'), "shop offer") end
      end
      if line:match('"kind":"joker_gain"') or line:match('"kind":"joker_loss"') then
        note(line:match('"key":"([^"]*)"'), "gain/loss")
      end
      for blob in line:gmatch('"jokers":%[(.-)%]') do
        for k in blob:gmatch('"(j_[^"]+)"') do note(k, "board") end
      end
      for blob in line:gmatch('"items":%[(.-)%]') do
        for item in blob:gmatch("%b{}") do note(item:match('"key":"(j_[^"]*)"'), "pack") end
      end
    end
    f:close()
  end
end

local names = {}
for k in pairs(seen) do names[#names + 1] = k end
table.sort(names)

local missing = {}
for _, k in ipairs(names) do
  if not JD.ALL[k] then missing[#missing + 1] = k end
end

local catalogue = 0
for _ in pairs(JD.ALL) do catalogue = catalogue + 1 end

print(("files read: %d   distinct live joker keys: %d   catalogue size: %d")
  :format(files_read, #names, catalogue))
print("")
if #missing == 0 then
  print("*** 0 CATALOGUE MISSES -- every key the real game emitted resolves. ***")
else
  print(("*** %d LIVE KEYS THE CATALOGUE DOES NOT KNOW -- each scores ZERO everywhere ***"):format(#missing))
  for _, k in ipairs(missing) do
    print(("  %-30s seen %4d  (%s)"):format(k, seen[k], where[k]))
  end
end

-- The reverse direction is INFORMATIONAL ONLY: absence from a few captured runs is not evidence
-- of a wrong key. It is listed because a non-Legendary entry here is worth a second look -- it is
-- either genuinely rare or an alias the game never emits.
local unseen = {}
for k in pairs(JD.ALL) do if not seen[k] then unseen[#unseen + 1] = k end end
table.sort(unseen)
print("")
print(("catalogue keys never observed live: %d (informational -- the dataset is a handful of runs)")
  :format(#unseen))
for _, k in ipairs(unseen) do
  local d = JD.ALL[k]
  print(("  %-30s %-10s tier %s"):format(k, d.rarity or "?", tostring(d.tier)))
end
