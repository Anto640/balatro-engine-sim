-- ui/overlay.lua
-- Owns the recommendation DISPLAY STATE: Overlay.set() turns the engine's RankedActionList into the
-- strings and numbers the native HUD panel (ui/hud_panel.lua) and the in-world highlights read.
-- Pure: no G, no love -- headless-testable.

local Cards = require("util.cards")

local Overlay = {}

Overlay.state = {
  title    = "ENGINE SIM",
  move     = "-",     -- full one-line move (verb, target, pack size, cost, tarot target)
  headline = "-",     -- the move WITHOUT the cost (the panel shows the cost as its own money tag)
  conf     = "",
  ev       = "",
  winp     = "",
  reorder  = "",
  reason   = "Press F8 to evaluate.",
  -- structured numbers for the panel's tags (nil = not applicable)
  cost = nil, banked = nil, conf_pct = nil, sim_backed = false,
  ev_pct = nil, ev_label = nil, win_pct = nil, run_pct = nil,
  version  = 0,       -- bumped on every change; the panel rebuilds when it moves
  -- the engine is working out the advice for the live state (main.lua BES.think_begin / think_end)
  thinking = false, thinking_since = 0, progress = 0,
}
-- Show "Thinking" only once it has lasted this long, so a quick answer doesn't flash the panel.
Overlay.THINK_SHOW_AFTER = 0.15

-- Engine errors (util/log on_error): the panel shows a red "!" while any is recent, the popup lists them.
Overlay.errors = {}            -- newest last: { t = <seconds>, clock = "HH:MM", msg = "..." }
Overlay.ERRORS_KEEP = 5
Overlay.ERROR_SHOW_FOR = 600   -- seconds an error keeps the indicator lit

function Overlay.add_error(msg, now, clock)
  local e = Overlay.errors
  e[#e + 1] = { t = now or 0, clock = clock or "", msg = tostring(msg) }
  while #e > Overlay.ERRORS_KEEP do table.remove(e, 1) end
end

-- A short confirmation tag on the panel (e.g. "Flagged (12)" after F5), shown for `dur` seconds.
Overlay.notice = nil           -- { text, until_t }
function Overlay.notify(text, now, dur)
  Overlay.notice = { text = tostring(text), until_t = (now or 0) + (dur or 3) }
end
function Overlay.active_notice(now)
  local n = Overlay.notice
  if n and (now or 0) < n.until_t then return n.text end
  return nil
end

-- the errors still worth showing at time `now` (newest last)
function Overlay.recent_errors(now)
  local out = {}
  for _, e in ipairs(Overlay.errors) do
    if (now or 0) - e.t <= Overlay.ERROR_SHOW_FOR then out[#out + 1] = e end
  end
  return out
end
Overlay.action  = nil -- the raw best action (the in-world highlights read its cards / target ids)
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

local function pct(x) return math.floor((x or 0) * 100 + 0.5) end

local VERB = {
  PLAY = "Play", DISCARD = "Discard", BUY_JOKER = "Buy", SELL_JOKER = "Sell",
  BUY_VOUCHER = "Buy", BUY_PACK = "Open", REROLL = "Reroll", SAVE = "Save",
  SKIP = "Skip", CONTINUE = "Play blind", PICK = "Take", BUY_CONSUMABLE = "Buy",
  USE_CONSUMABLE = "Use", SELL_TO_BUY = "Sell",
}
local BUYS = { BUY_PACK = true, BUY_JOKER = true, BUY_CONSUMABLE = true, BUY_VOUCHER = true, SELL_TO_BUY = true }

-- Populate display state from a RankedActionList (engine output).
function Overlay.set(ranked)
  local s = Overlay.state
  s.version = (s.version or 0) + 1
  s.cost, s.banked, s.conf_pct, s.sim_backed = nil, nil, nil, false
  s.ev_pct, s.ev_label, s.win_pct, s.run_pct = nil, nil, nil, nil
  s.reorder = ""
  if not ranked or not ranked.best then
    Overlay.action = nil
    s.move, s.headline, s.conf, s.ev, s.winp = "-", "-", "", "", ""
    s.reason = ranked and ranked.reason or "No recommendation."
    return
  end
  local a = ranked.best
  Overlay.action = a
  local verb = VERB[a.type] or a.type
  local what = (a.cards and #a.cards > 0) and cards_str(a.cards)
    or (a.target and (a.target.name or a.target.key)) or ""
  local head = (what ~= "") and string.format("%s %s", verb, what) or verb
  -- For a pack, its pick-count so Normal/Jumbo (pick 1) vs Mega (pick 2) is unmistakable.
  -- 2026-08-26 advice-review request.
  if a.type == "BUY_PACK" and a.target and a.target.key then
    local ok, P = pcall(require, "engine.packs")
    if ok and P and P.size_label then
      local sz = P.size_label(a.target.key)          -- "Mega" / "Jumbo" / "Normal"
      local pick = (sz == "Mega") and 2 or 1
      head = head .. string.format(" [%s, pick %d]", sz, pick)
    end
  end
  local cost_str = ""
  if a.cost and a.cost > 0 and BUYS[a.type] then
    s.cost = a.cost
    cost_str = string.format(" — $%d", a.cost)
  end
  -- The target ("on which cards") is the actionable part of using a Tarot, so it goes in the
  -- headline, not just the reason: "Use Empress — apply to AS, KS" instead of a bare "Use Empress".
  local note = (a.target_note and a.target_note ~= "") and (" — " .. a.target_note) or ""
  s.headline = head .. note
  s.move = head .. cost_str .. note
  -- Be honest about what "confidence" means: a calibrated probability (from the
  -- simulation) vs a heuristic preference strength. Likewise only call the
  -- number "EV" when it is sim-backed; a heuristic ratio is shown as "Edge".
  local basis = a.confidence_basis or "heuristic_margin"
  local sim_backed = (basis == "win_probability" or basis == "draw_probability")
  s.sim_backed = sim_backed
  s.conf_pct = pct(a.confidence)
  s.conf = string.format("Confidence: %d%%%s", s.conf_pct, sim_backed and " (sim)" or " (heuristic)")
  s.ev_label = sim_backed and "EV" or "Edge"
  s.ev_pct = pct(a.expected_value)
  s.ev = string.format("%s: %+d%%", s.ev_label, s.ev_pct)
  if a.banked_money and a.banked_money > 0 then
    s.banked = a.banked_money
    s.ev = s.ev .. string.format("   Banks $%d", a.banked_money)
  end
  if a.win_probability ~= nil then
    s.win_pct, s.run_pct = pct(a.win_probability), pct(a.run_strength)
    s.winp = string.format("Win: %d%%   Run: %d%%", s.win_pct, s.run_pct)
  else
    s.winp = ""
  end
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
  s.reason = a.reason or ""
end

function Overlay.set_thinking(on, now)
  local s = Overlay.state
  s.thinking = on and true or false
  s.thinking_since = now or 0
  s.progress = 0
end

-- Is the thinking state worth SHOWING at time `now`? (past the anti-flash delay)
function Overlay.show_thinking(now)
  local s = Overlay.state
  return s.thinking and ((now or 0) - (s.thinking_since or 0)) >= Overlay.THINK_SHOW_AFTER
end

-- Replace only the reason line (a transient status such as "Evaluating pack…").
function Overlay.set_reason(text)
  Overlay.state.reason = text or ""
  Overlay.state.version = (Overlay.state.version or 0) + 1
end

return Overlay
