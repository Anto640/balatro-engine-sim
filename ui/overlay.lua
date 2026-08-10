-- ui/overlay.lua
-- Builds the recommendation panel's UI node tree and owns the display state.
-- Uses plain UIT.T text nodes (the most reliable text in Balatro) built fresh
-- from the current state; the HUD is rebuilt on update (see ui/hud_inject.lua),
-- so we don't depend on DynaText live-binding.
-- Runtime-only: needs G.UIT, which exists in-game.

local Cards = require("util.cards")

local Overlay = {}

Overlay.state = {
  title   = "ENGINE SIM",
  move    = "-",
  conf    = "",
  ev      = "",
  winp    = "",
  reorder = "",
  reason  = "Press F8 to evaluate.",
}
Overlay.visible = true

local function cards_str(cards)
  local out = {}
  for _, c in ipairs(cards or {}) do out[#out + 1] = Cards.label(c) end
  return table.concat(out, " ")
end

local function jokers_str(list)
  local out = {}
  for _, j in ipairs(list or {}) do out[#out + 1] = j.name or j.key or "?" end
  return table.concat(out, " > ")
end

local function truncate(s, n)
  if s and #s > n then return s:sub(1, n - 1) .. "…" end
  return s
end

-- Populate display state from a RankedActionList (engine output).
function Overlay.set(ranked)
  local s = Overlay.state
  if not ranked or not ranked.best then
    s.move, s.conf, s.ev, s.winp = "-", "", "", ""
    s.reason = ranked and ranked.reason or "No recommendation."
    return
  end
  local a = ranked.best
  local VERB = {
    PLAY = "Play", DISCARD = "Discard", BUY_JOKER = "Buy", SELL_JOKER = "Sell",
    BUY_VOUCHER = "Buy", BUY_PACK = "Open", REROLL = "Reroll", SAVE = "Save",
    SKIP = "Skip", CONTINUE = "Play blind", PICK = "Take", BUY_CONSUMABLE = "Buy",
    USE_CONSUMABLE = "Use", SELL_TO_BUY = "Sell",
  }
  local verb = VERB[a.type] or a.type
  local what = (a.cards and #a.cards > 0) and cards_str(a.cards)
    or (a.target and (a.target.name or a.target.key)) or ""
  s.move = (what ~= "") and string.format("%s %s", verb, what) or verb
  -- The target ("on which cards") is the actionable part of using a Tarot, so put it
  -- in the BIG move line, not just the small reason text below. e.g. the headline
  -- reads "Use Empress — apply to AS, KS" instead of a bare "Use Empress".
  if a.target_note and a.target_note ~= "" then
    s.move = s.move .. " — " .. a.target_note
  end
  -- Be honest about what "confidence" means: a calibrated probability (from the
  -- simulation) vs a heuristic preference strength. Likewise only call the
  -- number "EV" when it is sim-backed; a heuristic ratio is shown as "Edge".
  local basis = a.confidence_basis or "heuristic_margin"
  local sim_backed = (basis == "win_probability" or basis == "draw_probability")
  local conf_tag = sim_backed and " (sim)" or " (heuristic)"
  s.conf = string.format("Confidence: %d%%%s", math.floor((a.confidence or 0) * 100 + 0.5), conf_tag)
  local ev_label = sim_backed and "EV" or "Edge"
  s.ev   = string.format("%s: %+d%%", ev_label, math.floor((a.expected_value or 0) * 100 + 0.5))
  if a.banked_money and a.banked_money > 0 then
    s.ev = s.ev .. string.format("   Banks $%d", a.banked_money)
  end
  if a.win_probability ~= nil then
    s.winp = string.format("Win: %d%%   Run: %d%%",
      math.floor(a.win_probability * 100 + 0.5),
      math.floor((a.run_strength or 0) * 100 + 0.5))
  else
    s.winp = ""
  end
  -- dedicated, untruncated reorder line (the reason gets truncated below)
  s.reorder = ""
  if a.reorder then -- decision_engine only sets this when a reorder is worth it
    local o, parts = a.reorder, {}
    if o.joker_changed then parts[#parts + 1] = "jokers " .. jokers_str(o.joker_order) end
    if o.card_changed then parts[#parts + 1] = "cards " .. cards_str(o.card_order) end
    local tail
    if o.objective == "money" then tail = string.format(" (+$%g)", o.money_gain)
    elseif o.gain and o.gain > 0 then tail = string.format(" (+%d)", o.gain)
    else tail = " (safer)" end
    s.reorder = "Reorder: " .. table.concat(parts, ", ") .. tail
  end
  s.reason = a.reason or "" -- full text; the HUD word-wraps it so it stays on-screen
end

-- Build the UI subtree from the CURRENT state (static text; rebuilt on update).
function Overlay.node()
  if not _G.G or not _G.G.UIT then return nil end
  local UIT, C = G.UIT, G.C
  local st = Overlay.state

  -- a text row; skips empty lines so the panel stays compact
  local function row(text, scale, colour)
    if text == nil or text == "" then return nil end
    return { n = UIT.R, config = { align = "cl", padding = 0.02 }, nodes = {
      { n = UIT.T, config = {
        text = text, scale = scale or 0.32,
        colour = colour or C.UI.TEXT_LIGHT, shadow = true,
      } },
    } }
  end

  local rows = {}
  local function add(r) if r then rows[#rows + 1] = r end end
  add(row(st.title,  0.40, C.GOLD))
  add(row(st.move,   0.46, C.UI.TEXT_LIGHT))
  add(row(st.conf,    0.32, C.WHITE))
  add(row(st.ev,      0.32, C.GREEN))
  add(row(st.winp,    0.30, C.BLUE))
  add(row(st.reorder, 0.30, C.GOLD))
  add(row(st.reason,  0.28, C.WHITE))

  return { n = UIT.ROOT, config = {
      align = "cm", padding = 0.08, r = 0.1, colour = C.BLACK,
      emboss = 0.08, minw = 3.0,
    }, nodes = {
    { n = UIT.C, config = { align = "cl", padding = 0.04 }, nodes = rows },
  } }
end

return Overlay
