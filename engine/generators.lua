-- engine/generators.lua
-- Jokers that GENERATE value on actions OUTSIDE the shop -- selecting a blind and
-- playing a hand -- so they should weigh on those decisions:
--   * blind select: owning Cartomancer/Riff-Raff/Marble makes PLAYING a blind
--     worth more than SKIPPING it (you forgo the free tarot/jokers/cards on skip).
--   * playing a hand: a play that triggers Vagabond/Superposition/Seance/Midas
--     also produces a tarot/spectral/gold -- noted and slightly credited so a
--     tie between plays favours the one that generates.
-- PURE. Magnitudes are heuristic; blind-select value is in DOLLARS (to match
-- skip_advisor's $ scale), play value is in SCORE-equivalent chips.

local Cards = require("util.cards")
local JokerData = require("engine.joker_data")

local G = {}

local function owns(gs, key)
  for _, j in ipairs(gs.jokers or {}) do if j.key == key then return true end end
  return false
end

-- Per-PLAY econ farmers: they pay only when you actually PLAY a blind (discard/play triggers), so
-- SKIPPING forgoes their earnings this blind. (Per-ROUND econ like Rocket/Cloud 9 is excluded -- a skip
-- may still pay it, and double-counting it here would wrongly suppress every skip.)
local PLAY_FARM_ECON = { j_faceless = 4, j_mail = 3, j_trading = 3 }

-- Dollar-equivalent value of SELECTING (playing) a blind, from what you forgo by SKIPPING. Two kinds:
-- (1) blind-select generators you own (fire on select), and (2) the in-blind value only PLAYING
-- realizes -- condition-locked scalers grow, per-play econ jokers pay. The skip decision priced only (1)
-- before, so a scaler/farm board over-skipped (owner: "skipping quite a lot"). Bounded so a big board
-- can't make a skip impossible: a genuinely strong tag still clears the skip margin.
function G.blind_select_value(gs)
  local v, notes = 0, {}
  local function add(d, n) v = v + d; notes[#notes + 1] = n end
  local njok = #(gs.jokers or {})
  local joker_slots = (gs.run and gs.run.joker_slots) or (gs.shop and gs.shop.joker_slots) or 5
  local cons = #(gs.consumables or {})
  local cons_slots = (gs.run and gs.run.consumable_slots) or 2

  if owns(gs, "j_cartomancer") and cons < cons_slots then add(4, "Cartomancer makes a Tarot") end
  if owns(gs, "j_riff_raff") and (joker_slots - njok) > 0 then add(8, "Riff-Raff makes 2 Jokers") end
  if owns(gs, "j_marble") then add(2, "Marble adds a Stone card") end

  -- (2) in-blind value forgone by skipping
  local nsc = 0
  for _, j in ipairs(gs.jokers or {}) do
    if JokerData.is_scaling(j.key) then nsc = nsc + 1 end
    local e = PLAY_FARM_ECON[j.key]
    if e then add(e, (j.name or j.key) .. " farms ~$" .. e .. "/blind") end
  end
  if nsc > 0 then add(math.min(6, 2 * nsc), nsc .. " scaler" .. (nsc == 1 and "" or "s") .. " grow by playing") end
  return v, table.concat(notes, ", ")
end

-- Score-equivalent bonus + notes from owned jokers that GENERATE on playing THIS
-- hand. Small relative to a real hand score, so it tie-breaks rather than
-- overrides a clearing play.
function G.play_bonus(gs, played, hand_type)
  local bonus, notes = 0, {}
  local function add(b, n) bonus = bonus + b; notes[#notes + 1] = n end
  local dollars = (gs.economy and gs.economy.dollars) or 0

  if owns(gs, "j_vagabond") and dollars <= 4 then add(30, "Vagabond → Tarot (≤$4)") end
  if owns(gs, "j_superposition") and (hand_type == "Straight" or hand_type == "Straight Flush") then
    local has_ace = false
    for _, c in ipairs(played) do if Cards.rank_id(c) == 14 then has_ace = true break end end
    if has_ace then add(30, "Superposition → Tarot (Ace + straight)") end
  end
  if owns(gs, "j_seance") and hand_type == "Straight Flush" then add(50, "Séance → Spectral") end
  if owns(gs, "j_midas_mask") then
    local faces = 0
    for _, c in ipairs(played) do if Cards.is_face(c) then faces = faces + 1 end end
    if faces > 0 then add(faces * 12, string.format("Midas golds %d face(s)", faces)) end
  end
  return bonus, table.concat(notes, ", ")
end

return G
