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

-- ---------------------------------------------------------------------------
-- OUTPUT ROOM. A generator's entire value IS its output, and the output needs a SLOT --
-- the documented "Created things need a SLOT" rule (CLAUDE.md). Which slot depends on what
-- it makes, and joker_data already encodes that: every `card_generation` joker carries the
-- "consumable" tag EXCEPT j_riff_raff, which is the one that makes JOKERS.
--
-- This is shared so the several places that need it cannot drift apart. It was written after
-- ADVICE_REVIEW R8, where they had: `blind_select_value` below gated Riff-Raff on a free joker
-- slot correctly, while the shop's funder gate and the valuation prior did not -- so a Riff-Raff
-- bought into the last slot produced nothing for a whole run yet stayed both PROTECTED from
-- sale and credited a full tier prior, and the board's only Mult was sold to make room instead.
-- ---------------------------------------------------------------------------

-- Does this generator's output have somewhere to land right now? `owned` = the joker is already
-- on the board (so it is counted in the board size); false = we are pricing BUYING it, in which
-- case it will occupy one of the free slots itself.
function G.output_room_free(gs, key, owned)
  gs = gs or {}
  if JokerData.has_tag(key, "consumable") then
    local slots = (gs.run and gs.run.consumable_slots) or 2
    return slots - #(gs.consumables or {})
  end
  local slots = (gs.run and gs.run.joker_slots) or (gs.shop and gs.shop.joker_slots) or 5
  local free = slots - #(gs.jokers or {})
  if not owned then free = free - 1 end   -- the generator itself takes a slot when bought
  return free
end

function G.has_output_room(gs, key, owned)
  return G.output_room_free(gs, key, owned) > 0
end

-- How much of a generator's output actually LANDS, as a multiplier in [0,1]. This is the SAME
-- convention pack_open_advisor's gen_fit already applies to tarot/spectral generators, reused
-- rather than reinvented: each output dropping into a FREE slot counts full, each that needs room
-- MADE is credited at `room_credit`, and anything beyond that overflows to nothing.
--
-- `room_credit` is output-QUALITY-aware there, and the number below follows the same reading:
-- pack_open_advisor prices The Judgement's room_credit at 0.1 because "a RANDOM joker rarely
-- [beats what you sacrifice]" -- and Riff-Raff's output is 2 random COMMONS, strictly the weakest
-- joker output in the game. Selling a joker you chose to keep in order to make room for a random
-- common is a bad trade, so it takes the same 0.1.
--
-- Only the JOKER-output generator is listed. A consumable-maker's overflow is transient (see the
-- asymmetry argument in shop_advisor's funder_is_live) and its value is already handled by the
-- econ/consumable channels, so it keeps a flat 1 and this function is a no-op for it.
G.OUTPUT = {
  j_riff_raff = { out = "joker", n = 2, room_credit = 0.1 },  -- 2 random Commons on blind select
}
function G.output_fit(gs, key, owned)
  local meta = G.OUTPUT[key]
  if not meta or meta.n <= 0 then return 1 end
  local free = math.max(0, G.output_room_free(gs, key, owned))
  -- room can be MADE by selling a joker; count only jokers other than the generator itself
  local roomable = math.max(0, #((gs and gs.jokers) or {}) - (owned and 1 or 0))
  local landed = math.min(free, meta.n)
  local made = math.min(math.max(0, meta.n - free), roomable)
  return (landed + (meta.room_credit or 0.5) * made) / meta.n
end

-- Expected FIRING rate of a CONDITIONAL generator, as a multiplier in [0,1] applied alongside output_fit.
-- Vagabond makes a Tarot only on a hand played at <= $4 -- so it is near-worthless to a RICH engine and
-- valuable when poor, yet the flat tier prior (tier x 0.5) valued it identically at every dollar level (the
-- same context-blindness the scaler/spectral sweeps removed). Current dollars is the proxy for how often you
-- will actually be at <= $4 when you play. Owner-calibratable; 1 (no change) for unconditional generators.
function G.fire_rate(gs, key)
  if key == "j_vagabond" then
    local d = (gs and gs.economy and gs.economy.dollars) or 0
    if d <= 4 then return 1.0        -- at/under the threshold now -> fires this round
    elseif d <= 10 then return 0.5   -- you dip to <= $4 some rounds
    elseif d <= 20 then return 0.25
    else return 0.10 end             -- rich: almost never at <= $4 when playing
  end
  return 1
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

  -- both slot gates now go through G.has_output_room (exactly equivalent to the inline
  -- `cons < cons_slots` / `joker_slots - njok > 0` they replace), so the shop-side gate added
  -- for R8 and this one can never disagree about whether a generator can produce.
  if owns(gs, "j_cartomancer") and G.has_output_room(gs, "j_cartomancer", true) then add(4, "Cartomancer makes a Tarot") end
  if owns(gs, "j_riff_raff") and G.has_output_room(gs, "j_riff_raff", true) then add(8, "Riff-Raff makes 2 Jokers") end
  if owns(gs, "j_marble") then add(2, "Marble adds a Stone card") end

  -- (2) in-blind value forgone by skipping
  local nsc = 0
  for _, j in ipairs(gs.jokers or {}) do
    if JokerData.is_scaling(j.key) then nsc = nsc + 1 end
    local e = PLAY_FARM_ECON[j.key]
    if e and j.key == "j_faceless" then   -- its MEASURED, board-aware income (Eval.econ_value), not a flat \$4
      local okE, Eval = pcall(require, "engine.eval_function")
      if okE then e = math.floor(Eval.econ_value(gs, j.key) + 0.5) end
      if e <= 0 then e = nil end
    end
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
