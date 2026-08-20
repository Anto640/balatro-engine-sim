-- tools/blind_outcome.lua
-- IN-BLIND OUTCOME SCORER (methodology-shift-2026-08). The agreement analysis found the engine plays
-- DIFFERENT cards from the winning human on 83% of shared plays -- but agreement can't say who is
-- RIGHT (both won). This forward-simulates BOTH plays with the engine's own survival oracle
-- (Sim.survive_after: after the given first play, roll the rest of the blind out and measure the
-- fraction of the target reached + the clear rate), under COMMON RANDOM NUMBERS, and also takes each
-- play's immediate score. The question it answers: when they differ, does the engine OVERKILL (score
-- far past what the blind needs, burning cards the human banks) while the human just clears -- or is
-- the engine's max-score play genuinely SAFER (the human would under-clear)?
--
--   usage: luajit tools/blind_outcome.lua <bes_fixtures.jsonl> <picks.jsonl> [samples]
--   picks.jsonl from tools/replay_fixtures.lua (carries the engine's played card ids per blind).

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")
local Json    = require("util.json")
local RF      = require("core.replay_fixture")
local Sim     = require("engine.simulation")
local HandEval = require("engine.hand_eval")

local function lcg(seed)
  local s = math.floor(seed) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end
local function shash(str)                    -- stable hash of an alphanumeric Balatro seed
  local h = 5381
  for i = 1, #tostring(str) do h = (h * 33 + string.byte(str, i)) % 2147483647 end
  return h
end
local function oracle_seed(seed, idx) return (shash(seed) * 131 + (tonumber(idx) or 0) * 977 + 7) % 2147483646 + 1 end

local function load(path)
  local out, fh = {}, io.open(path)
  if not fh then io.stderr:write("cannot open " .. path .. "\n"); os.exit(1) end
  for line in fh:lines() do
    if line:match("%S") then local ok, r = pcall(Json.decode, line); if ok then out[#out + 1] = r end end
  end
  fh:close(); return out
end

local FX = arg[1] or "bes_fixtures.jsonl"
local PK = arg[2] or "picks.jsonl"
local SAMPLES = tonumber(arg[3]) or 100

local fixs = load(FX)
local picks = {}
for _, p in ipairs(load(PK)) do picks[tostring(p.seed) .. "|" .. tostring(p.idx)] = p end

-- human plays per seed, sorted by t
local plays = {}
for _, r in ipairs(fixs) do
  if r.kind == "play" and r.t then
    local s = tostring(r.seed); plays[s] = plays[s] or {}
    plays[s][#plays[s] + 1] = r
  end
end
for _, arr in pairs(plays) do table.sort(arr, function(a, b) return a.t < b.t end) end
local function play_after(seed, t)
  local arr = plays[tostring(seed)]; if not arr then return nil end
  for _, r in ipairs(arr) do if r.t >= t then return r end end
  return nil
end

local function cards_by_id(hand, ids)
  local byid = {}; for _, c in ipairs(hand or {}) do byid[c.id] = c end
  local out = {}; for _, id in ipairs(ids or {}) do if byid[id] then out[#out + 1] = byid[id] end end
  return out
end
local function score_of(gs, cards)
  if #cards == 0 then return 0 end
  local ok, ev = pcall(HandEval.score, gs, cards)
  return (ok and ev and (ev.score or ((ev.chips or 0) * (ev.mult or 0)))) or 0
end

local n, both_clear, eng_safer, hum_safer = 0, 0, 0, 0
local eng_one, hum_one, sum_nc_e, sum_nc_h = 0, 0, 0, 0   -- "clears in ONE hand" (banks the rest)
local over_e, over_h = {}, {}    -- score/remaining-target distributions (report the MEDIAN)
local overkill_both_clear = {}   -- engine's score/target on decisions where BOTH clear
local ex = {}

for _, r in ipairs(fixs) do
  if r.kind == "state" and r.decision == "blind" then
    local eng = picks[tostring(r.seed) .. "|" .. tostring(r.idx)]
    eng = eng and eng.engine
    if eng and eng.type == "PLAY" and eng.cards then
      local hp = play_after(r.seed, r.t)
      if hp and hp.action == "PLAY" and hp.cards then
        local es, hs = {}, {}
        for _, id in ipairs(eng.cards) do es[id] = true end
        for _, id in ipairs(hp.cards) do hs[id] = true end
        local same = true
        for id in pairs(es) do if not hs[id] then same = false break end end
        if same then for id in pairs(hs) do if not es[id] then same = false break end end end
        if not same then
          local gs = RF.rehydrate(r)
          local ecards = cards_by_id(gs.hand, eng.cards)
          local hcards = cards_by_id(gs.hand, hp.cards)
          if #ecards > 0 and #hcards > 0 then
            local b = gs.blind or {}
            local remaining = math.max(1, (b.target_chips or 0) - (b.chips_scored or 0))
            local escore, hscore = score_of(gs, ecards), score_of(gs, hcards)
            local sd = oracle_seed(r.seed, r.idx)
            local ef = Sim.survive_after(gs, { kind = "PLAY", sel = ecards }, SAMPLES, lcg(sd))
            local hf = Sim.survive_after(gs, { kind = "PLAY", sel = hcards }, SAMPLES, lcg(sd))
            n = n + 1
            over_e[#over_e + 1] = escore / remaining; over_h[#over_h + 1] = hscore / remaining
            sum_nc_e = sum_nc_e + #ecards; sum_nc_h = sum_nc_h + #hcards
            if escore >= remaining then eng_one = eng_one + 1 end   -- engine's ONE play clears -> banks the other hands
            if hscore >= remaining then hum_one = hum_one + 1 end
            local dc = ef.clear - hf.clear
            if ef.clear > 0.95 and hf.clear > 0.95 then
              both_clear = both_clear + 1
              overkill_both_clear[#overkill_both_clear + 1] = escore / remaining
            end
            if dc > 0.1 then eng_safer = eng_safer + 1 end
            if dc < -0.1 then hum_safer = hum_safer + 1 end
            if #ex < 14 then
              ex[#ex + 1] = string.format("  %s a%s: eng %s (%dc, %.1fx target, clear %.0f%%) vs human (%dc, %.1fx, clear %.0f%%)",
                tostring(r.seed):sub(1, 6), tostring(r.ante), eng.hand_type or "?", #ecards, escore / remaining,
                ef.clear * 100, #hcards, hscore / remaining, hf.clear * 100)
            end
          end
        end
      end
    end
  end
end

local function pct(c) return n > 0 and string.format("%d (%.0f%%)", c, 100 * c / n) or "0" end
local function med(t) if #t == 0 then return 0 end; table.sort(t); return t[math.floor(#t / 2) + 1] end
print(string.rep("=", 66))
print(string.format("IN-BLIND OUTCOME — %d divergent PLAY decisions (samples=%d, CRN)", n, SAMPLES))
print(string.rep("=", 66))
if n > 0 then
  print(string.format("BOTH plays clear the blind: %s   -> the engine's extra score is OVERKILL", pct(both_clear)))
  print(string.format("  (on those, engine plays a median %.1fx the needed target)", med(overkill_both_clear)))
  print(string.format("Engine play strictly SAFER (human would under-clear): %s", pct(eng_safer)))
  print(string.format("Human play strictly SAFER than the engine's: %s", pct(hum_safer)))
  print(string.format("First play alone CLEARS (banks the remaining hands):  engine %s   human %s", pct(eng_one), pct(hum_one)))
  print(string.format("Median immediate score / needed target:  engine %.2fx   human %.2fx", med(over_e), med(over_h)))
  print(string.format("Avg cards played:  engine %.2f   human %.2f", sum_nc_e / n, sum_nc_h / n))
  print("\n--- examples ---")
  for _, e in ipairs(ex) do print(e) end
end
