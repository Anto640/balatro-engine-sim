-- tools/audit_provable.lua
-- REPLAY-BASED PROVABLE-ERROR AUDIT (2026-09-20). Judgment-free: flags engine
-- decisions that are wrong ON THEIR OWN TERMS, not "differs from the owner".
--
-- Fast PLAY-SELECTION level (HandEval.best_play_target, no Monte-Carlo survival),
-- so the whole corpus runs in seconds and prints each finding as it is found.
--   B0  LIVE boss_effect gap -- the play HandEval picks with gs WITHOUT boss_effect
--       (exactly what state_extraction feeds the live engine) scores far less / 0 once
--       the boss suit/face/Flint debuff is applied. A live-only under-scoring bug that a
--       boss_effect-faithful replay hides.
--   B1  the faithful best play scores 0 under the boss (illegal/off-type) w/ a dig available
--   B2  the faithful best play is ILLEGAL under the boss play restriction
--
--   usage: luajit tools/audit_provable.lua <fixtures.jsonl> [maxN]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json     = require("util.json")
local RF       = require("core.replay_fixture")
local HandEval = require("engine.hand_eval")
local BE       = require("engine.boss_effect")

local infile = arg[1] or "bes_fixtures.jsonl"
local maxN   = tonumber(arg[2])
local fh = io.open(infile)
if not fh then io.stderr:write("cannot open " .. infile .. "\n"); os.exit(1) end

local function remaining_of(gs)
  local b = gs.blind or {}
  return math.max(0, (b.target_chips or 0) - (b.chips_scored or 0))
end

local counts = { B0 = 0, B1 = 0, B2 = 0 }
local n, nboss = 0, 0
local shown = 0
local function emit(code, fix, detail)
  counts[code] = counts[code] + 1
  if shown < 60 then
    shown = shown + 1
    local b = fix.gs.blind or {}
    print(string.format("  [%s] seed=%s idx=%s ante=%s boss=%s | %s",
      code, tostring(fix.seed), tostring(fix.idx), tostring(fix.ante),
      tostring(b.boss_effect_key), detail))
  end
end

for line in fh:lines() do
  if maxN and n >= maxN then break end
  if line:match('"kind":"state"') and line:match('"decision":"blind"') then
    local ok, fix = pcall(Json.decode, line)
    if ok and fix and fix.gs then
      n = n + 1
      local b = fix.gs.blind or {}
      local eff = (b.boss and b.boss_effect_key) and BE.of(b.boss_effect_key) or nil
      if eff then
        nboss = nboss + 1
        local gsf = RF.rehydrate(fix)             -- faithful: has boss_effect
        local hand = gsf.hand or {}
        local remaining = remaining_of(gsf)
        -- boss play-legality filter (Mouth/Eye/Psychic) mirrors decision_engine.boss_filter
        local pfilter = nil
        if BE.has_play_restriction(eff) then
          local types = b.played_hand_types or {}
          local first = nil; for t in pairs(types) do first = t; break end
          pfilter = function(sel, ht) return BE.legal_play(eff, sel, ht, { types = types, first = first }) end
        end

        -- (A) LIVE play choice: strip boss_effect, exactly what state_extraction feeds.
        if eff.debuff_suit or eff.debuff_faces or eff.halve_base then
          local gsl = RF.rehydrate(fix); gsl.boss_effect = nil
          local live_ev, live_cards = HandEval.best_play_target(gsl, gsl.hand or {}, remaining, pfilter)
          if live_ev and live_cards and (live_ev.score or 0) > 0 then
            local real = HandEval.score(gsf, live_cards)   -- score THAT play under the real boss
            local real_score = real and real.score or 0
            local claimed = live_ev.score
            local target = remaining
            -- clears mis-determination: engine thinks it beats the blind, real play doesn't.
            local clear_flip = target > 0 and claimed >= target and real_score < target
            if real_score < claimed * 0.6 or clear_flip then
              emit("B0", fix, string.format(
                "LIVE picks %s claiming %d; scores %d under %s (%.0f%% lost)%s; target %d hands %d",
                live_ev.hand_type or "?", math.floor(claimed), math.floor(real_score),
                eff.name or eff.key, 100*(1-real_score/claimed),
                clear_flip and " CLEAR-FLIP" or "", target, b.hands_left or 0))
            end
          end
        end

        -- (B) FAITHFUL best play (boss_effect present) -- B1 zero-score, B2 illegal.
        local fev, fcards = HandEval.best_play_target(gsf, hand, remaining, pfilter)
        if fev and fcards then
          local real = HandEval.score(gsf, fcards)
          local real_score = real and real.score or 0
          local ht = real and real.hand_type or fev.hand_type
          local discards = b.discards_left or 0
          local hands = b.hands_left or 1
          if real_score == 0 and (discards > 0 or hands > 1) then
            emit("B1", fix, string.format("faithful best play %s scores 0 under %s; %d disc %d hands",
              ht or "?", eff.name or eff.key, discards, hands))
          end
          if BE.has_play_restriction(eff) then
            local types = b.played_hand_types or {}
            local first = nil; for t in pairs(types) do first = t; break end
            if not BE.legal_play(eff, fcards, ht, { types = types, first = first }) then
              emit("B2", fix, string.format("faithful best play %s ILLEGAL under %s", ht or "?", eff.name or eff.key))
            end
          end
        end
      end
    end
  end
end
fh:close()

print(string.format("\naudited %d blind fixtures (%d boss) from %s", n, nboss, infile:gsub(".*/", "")))
print(string.format("PROVABLE FINDINGS:  B0=%d  B1=%d  B2=%d", counts.B0, counts.B1, counts.B2))
