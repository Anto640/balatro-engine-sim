-- ui/hud_panel.lua
-- The recommendation panel, built INTO Balatro's own left HUD (owner 2026-10-01: "built into the
-- balatro ui, not an overlay"). It is a native UIBox row with the same shape as the game's "Round
-- score" row -- a two-line label on the left, a dark inset box on the right -- so it uses the game's
-- font, DYN_UI colours (which follow the boss blind), emboss shading and CRT shader.
--
-- How it gets there without the old failure modes (invisible DynaText, crashing on a G.HUD rebuild):
--   * create_UIBox_HUD is WRAPPED: our row replaces the empty 0.3 spacer at the top of the bar in the
--     definition table, BEFORE the game builds G.HUD. G.HUD itself is never rebuilt.
--   * Live updates use the game's own dynamic-section pattern (G.FUNCS.HUD_blind_debuff /
--     change_window_cycle_UI): the row's `func` swaps its one child and recalculates the HUD box,
--     only when the advice actually changes. Plain UIT.T text, no DynaText.
--   * Details (reason, reorder, confidence basis, self-play / auto-restart status) live in a
--     card-style hover popup, so the bar itself stays one row tall.
--   * The bar was already nearly full (~12.1 of 12.9 visible units). If the panel makes it overflow
--     the screen, Panel.fit shortens the Run Info / Options buttons (never below MIN_BTN_H).
-- Every hook is pcall-guarded: a panel error is logged once and the game keeps running.
--
-- Runtime-only for install(); the definition builders are headless-testable with a stub G.

local Overlay = require("ui.overlay")
local Log = require("util.log")

local Panel = {}
Panel.installed = false
Panel.autoplay = nil          -- the ui/autoplay module (set by main.lua): .enabled / .auto_restart
Panel.fast = nil              -- the ui/fast_mode module (set by main.lua): .engaged()

local PANEL_ID   = "bes_panel"
local OPTIONS_ID = "bes_options_button"
local MIN_BTN_H  = 1.2        -- the Run Info / Options buttons are 1.75 tall in the base game
local TIP_W      = 6.0        -- tooltip text width (game units)
local TIP_SCALE  = 0.32

-- ---- text helpers -------------------------------------------------------------------------------

-- Width of `s` in game units at text scale `scale`, with the game's own font metrics
-- (engine/ui.lua calculate_xywh: getWidth * squish * scale * FONTSCALE / TILESIZE).
function Panel.text_w(s, scale)
  local f = G and G.LANG and G.LANG.font
  if f and f.FONT and f.FONT.getWidth then
    return f.FONT:getWidth(s) * (f.squish or 1) * scale * (f.FONTSCALE or 0.1) / ((G and G.TILESIZE) or 20)
  end
  return #s * scale * 0.42      -- headless fallback, roughly the pixel font's advance
end

-- Greedy word wrap to `maxw` game units. Returns a list of lines (never empty for non-empty text).
function Panel.wrap(text, scale, maxw)
  local out = {}
  for para in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    local cur = ""
    for word in para:gmatch("%S+") do
      local cand = (cur == "") and word or (cur .. " " .. word)
      if cur ~= "" and Panel.text_w(cand, scale) > maxw then
        out[#out + 1] = cur; cur = word
      else
        cur = cand
      end
    end
    if cur ~= "" then out[#out + 1] = cur end
  end
  return out
end

local function clip(s, n)
  if s and #s > n then return s:sub(1, n - 1) .. "…" end
  return s
end

-- ---- node builders --------------------------------------------------------------------------------

-- The pixel font is ASCII-first: spell typographic dashes / ellipses plainly so no glyph goes missing.
function Panel.plain(s)
  return (tostring(s):gsub("\226\128\148", "-"):gsub("\226\128\147", "-"):gsub("\226\128\166", "..."))
end

local function text(t, scale, colour)
  return { n = G.UIT.T, config = { text = Panel.plain(t), scale = scale, colour = colour or G.C.UI.TEXT_LIGHT, shadow = true } }
end

-- a small game-style tag: rounded, embossed, white text on a colour (like the HUD's money/chips boxes)
local function tag(t, colour, scale)
  return { n = G.UIT.C, config = { align = "cm", r = 0.1, colour = colour, padding = 0.04, emboss = 0.05 }, nodes = {
    text(t, scale or 0.28, G.C.WHITE),
  } }
end

local function conf_colour(p)
  if p >= 70 then return G.C.GREEN elseif p >= 40 then return G.C.FILTER end
  return G.C.RED
end

local function auto_on()
  local ap = Panel.autoplay
  return ap and ap.enabled and true or false
end

function Panel.now() return (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0 end
local function thinking() return Overlay.show_thinking(Panel.now()) end

-- the "Thinking" label colour: one table, re-tinted in place every frame (a soft orange pulse) -- the
-- text node draws whatever this table holds, so the pulse needs no rebuild / recalculate
Panel.pulse = nil
local function pulse_colour()
  if not Panel.pulse then
    local f = G.C.FILTER
    Panel.pulse = { f[1], f[2], f[3], f[4] or 1 }
  end
  return Panel.pulse
end
function Panel.tick_pulse(t)
  local p, f, w = pulse_colour(), G.C.FILTER, G.C.WHITE
  local k = 0.25 + 0.25 * math.sin(t * 5)          -- 0..0.5 toward white
  for i = 1, 3 do p[i] = f[i] + (w[i] - f[i]) * k end
end

-- the thinking row: the game's own progress bar (UIT progress_bar, drawn live from Overlay.state.progress)
local function progress_bar()
  return { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = {
    { n = G.UIT.C, config = { align = "cm", minw = 3.0, minh = 0.14, r = 0.05, colour = G.C.BLACK,
        progress_bar = { max = 1, ref_table = Overlay.state, ref_value = "progress",
          empty_col = G.C.BLACK, filled_col = G.C.FILTER } }, nodes = {} },
  } }
end

-- The tags under the headline: confidence, win chance, and the money involved.
function Panel.tags()
  local st, out = Overlay.state, {}
  local function add(node)
    if #out > 0 then out[#out + 1] = { n = G.UIT.B, config = { w = 0.08, h = 0.1 } } end
    out[#out + 1] = node
  end
  if st.conf_pct then add(tag(string.format("Conf %d%%", st.conf_pct), conf_colour(st.conf_pct))) end
  if st.win_pct then add(tag(string.format("Win %d%%", st.win_pct), G.C.BLUE)) end
  if st.cost then add(tag(string.format("$%d", st.cost), G.C.MONEY))
  elseif st.banked then add(tag(string.format("+$%d", st.banked), G.C.MONEY)) end
  return out
end

-- "Engine", plus a red "!" while an engine error is recent (details in the hover popup).
function Panel.label_row()
  local nodes = { text("Engine", 0.42) }
  if #Overlay.recent_errors(Panel.now()) > 0 then
    nodes[#nodes + 1] = { n = G.UIT.B, config = { w = 0.06, h = 0.1 } }
    nodes[#nodes + 1] = tag("!", G.C.RED, 0.32)
  end
  return nodes
end

-- The panel's single child (rebuilt whenever the advice changes).
function Panel.content()
  if not Overlay.visible then
    return { n = G.UIT.B, config = { w = 0.1, h = 0.3 } }   -- hidden: same height as the spacer it replaced
  end
  local st = Overlay.state
  local auto = auto_on()
  local think = thinking()
  local has_move = st.headline and st.headline ~= "" and st.headline ~= "-"
  -- no move yet: show the status line ("Waiting for the next hand…") greyed in the headline slot.
  -- Thinking: the previous move stays, greyed, so the panel doesn't jump; the bar replaces the tags.
  local head = has_move and st.headline or clip(st.reason ~= "" and st.reason or "No recommendation.", 44)
  if think and not has_move then head = "Working it out..." end
  local tags = think and {} or Panel.tags()
  local note = Overlay.active_notice(Panel.now())
  if note then   -- a confirmation (F5 flag) leads the tag row
    if #tags > 0 then table.insert(tags, 1, { n = G.UIT.B, config = { w = 0.08, h = 0.1 } }) end
    table.insert(tags, 1, tag(note, G.C.GREEN))
  end
  local body = {
    { n = G.UIT.R, config = { align = "cm", maxw = 3.2 }, nodes = {
      text(head, has_move and 0.36 or 0.3, (has_move and not think) and G.C.WHITE or G.C.UI.TEXT_INACTIVE),
    } },
  }
  if think and not note then
    body[#body + 1] = progress_bar()
  elseif #tags > 0 then
    body[#body + 1] = { n = G.UIT.R, config = { align = "cm", maxw = 3.2, padding = 0.03 }, nodes = tags }
  end
  local mode, mode_col = "Advice", G.C.UI.TEXT_LIGHT
  if think then mode, mode_col = "Thinking", pulse_colour()
  elseif auto then mode, mode_col = "Auto", G.C.GREEN end
  return { n = G.UIT.C, config = { align = "cm", padding = 0.1 }, nodes = {
    { n = G.UIT.C, config = { align = "cm", minw = 1.3 }, nodes = {
      { n = G.UIT.R, config = { align = "cm", maxw = 1.3 }, nodes = Panel.label_row() },
      { n = G.UIT.R, config = { align = "cm", maxw = 1.3 }, nodes = { text(mode, 0.42, mode_col) } },
    } },
    { n = G.UIT.C, config = { align = "cm", minw = 3.3, minh = 0.7, r = 0.1, padding = 0.05,
        colour = G.C.DYN_UI.BOSS_DARK }, nodes = body },
  } }
end

-- The row inserted into the HUD definition (its `func` keeps it live).
function Panel.row()
  return { n = G.UIT.R, config = { align = "cm", r = 0.1, colour = G.C.DYN_UI.BOSS_MAIN, emboss = 0.05,
      id = PANEL_ID, func = PANEL_ID, collideable = true }, nodes = { Panel.content() } }
end

-- Card-style hover popup (grey frame, dark title, white description, status badges).
function Panel.tooltip()
  local st = Overlay.state
  local dark = G.C.UI.TEXT_DARK
  local lines = {}
  local function para(t, colour)
    if not t or t == "" then return end
    for _, l in ipairs(Panel.wrap(Panel.plain(t), TIP_SCALE, TIP_W)) do
      lines[#lines + 1] = { n = G.UIT.R, config = { align = "cl", padding = 0.01 }, nodes = {
        { n = G.UIT.T, config = { text = l, scale = TIP_SCALE, colour = colour or dark } },
      } }
    end
  end
  if thinking() then
    para("Working out the best move for what's on screen now - wait for it before acting. "
      .. "The move below is the previous one.", G.C.FILTER)
  end
  para(st.reason)
  para(st.reorder, G.C.FILTER)
  local stats = {}
  for _, s in ipairs({ st.conf, st.ev, st.winp }) do if s and s ~= "" then stats[#stats + 1] = s end end
  if #stats > 0 then para(table.concat(stats, "   "), G.C.BLUE) end
  if Panel.fast and Panel.fast.engaged and Panel.fast.engaged() then
    para("Fast mode: animations are skipped while self-play runs.", G.C.GREEN)
  end
  local errs = Overlay.recent_errors(Panel.now())
  if #errs > 0 then
    para("Engine errors (full text in the Lovely log):", G.C.RED)
    for i = #errs, 1, -1 do para(errs[i].clock .. " " .. clip(errs[i].msg, 140), G.C.RED) end
  end
  if #lines == 0 then para("No recommendation yet.") end

  local function badge(label, on)
    return { n = G.UIT.C, config = { align = "cm", r = 0.1, padding = 0.06, minw = 2.2, emboss = 0.05,
        colour = on and G.C.GREEN or G.C.UI.BACKGROUND_INACTIVE }, nodes = {
      text(label .. (on and ": ON" or ": OFF"), 0.3, on and G.C.WHITE or G.C.UI.TEXT_LIGHT),
    } }
  end
  local ap = Panel.autoplay
  local title = (st.move and st.move ~= "-" and st.move) or "Engine advice"
  return { n = G.UIT.ROOT, config = { align = "cm", colour = G.C.CLEAR }, nodes = {
    { n = G.UIT.R, config = { align = "cm", colour = lighten(G.C.JOKER_GREY, 0.5), r = 0.1, padding = 0.05, emboss = 0.05 }, nodes = {
      { n = G.UIT.R, config = { align = "cm", colour = darken(G.C.BLACK, 0.1), r = 0.1, padding = 0.07 }, nodes = {
        { n = G.UIT.R, config = { align = "cm", padding = 0.05, maxw = TIP_W }, nodes = { text(title, 0.4, G.C.WHITE) } },
        { n = G.UIT.R, config = { align = "cm", colour = G.C.UI.BACKGROUND_WHITE, r = 0.1, padding = 0.08,
            minw = 2, emboss = 0.05 }, nodes = {
          { n = G.UIT.C, config = { align = "cl" }, nodes = lines },
        } },
        { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = {
          badge("Self-play", ap and ap.enabled),
          { n = G.UIT.B, config = { w = 0.1, h = 0.1 } },
          badge("Auto-restart", ap and ap.auto_restart),
        } },
        { n = G.UIT.R, config = { align = "cm" }, nodes = {
          text("F11 self-play   F6 auto-restart   F5 flag a misplay   F9 hide", 0.26, G.C.UI.TEXT_INACTIVE),
        } },
      } },
    } },
  } }
end

-- ---- HUD definition surgery ---------------------------------------------------------------------

-- Depth-first: the node whose `nodes` list contains a child matching pred, plus that child's index.
local function find_parent(node, pred)
  for i, c in ipairs(node.nodes or {}) do
    if pred(c) then return node, i end
    local p, j = find_parent(c, pred)
    if p then return p, j end
  end
end

local function walk(node, fn)
  fn(node)
  for _, c in ipairs(node.nodes or {}) do walk(c, fn) end
end

-- Insert our row at the top of the left bar (in place of its empty spacer) and tag the
-- Options button so Panel.fit can find it. Mutates and returns `def`.
function Panel.inject(def)
  local parent, i = find_parent(def, function(c) return c.config and c.config.id == "row_blind" end)
  if not parent then error("row_blind not found in the HUD definition") end
  local prev = parent.nodes[i - 1]
  local is_spacer = prev and prev.n == G.UIT.R and prev.config and prev.config.minh
    and not prev.config.id and (not prev.nodes or #prev.nodes == 0)
  if is_spacer then parent.nodes[i - 1] = Panel.row()
  else table.insert(parent.nodes, i, Panel.row()) end
  walk(def, function(n)
    if n.config and n.config.button == "options" and not n.config.id then n.config.id = OPTIONS_ID end
  end)
  return def
end

-- ---- live behaviour -----------------------------------------------------------------------------

-- Content-based, so the periodic re-set of IDENTICAL advice never recalculates the HUD.
local SIG_FIELDS = { "headline", "move", "reason", "reorder", "conf", "ev", "winp", "cost", "banked", "conf_pct", "win_pct" }
local function signature()
  local ap, st = Panel.autoplay, Overlay.state
  local parts = { tostring(Overlay.visible), tostring(ap and ap.enabled), tostring(ap and ap.auto_restart),
    tostring(thinking()), tostring(#Overlay.recent_errors(Panel.now())), tostring(#Overlay.errors > 0 and Overlay.errors[#Overlay.errors].t),
    tostring(Overlay.active_notice(Panel.now())) }
  for _, k in ipairs(SIG_FIELDS) do parts[#parts + 1] = tostring(st[k]) end
  return table.concat(parts, "\31")
end

-- If the bar is taller than the visible screen, shorten the Run Info / Options buttons.
function Panel.fit(e)
  local hud = e.UIBox
  local last = hud and hud:get_UIE_by_ID("row_round")
  if not (last and G.ROOM and G.ROOM.T) then return end
  local h = (last.T.y + last.T.h) - e.T.y
  local avail = G.ROOM.T.h + 2 * (G.ROOM_PADDING_H or 0.7) - 0.1
  local over = h - avail
  if over <= 0.005 then return end
  local changed = false
  for _, id in ipairs({ "run_info_button", OPTIONS_ID }) do
    local b = hud:get_UIE_by_ID(id)
    if b and b.config.minh then
      local nh = math.max(MIN_BTN_H, b.config.minh - over / 2)
      if nh < b.config.minh - 0.001 then b.config.minh = nh; changed = true end
    end
  end
  if changed then
    hud:recalculate()
    Log.info(string.format("HUD panel: bar %.2f > %.2f visible units; shortened Run Info / Options", h, avail))
  end
end

local function rebuild(e)
  local vis = Overlay.visible
  e.config.colour = vis and G.C.DYN_UI.BOSS_MAIN or G.C.CLEAR
  e.config.emboss = vis and 0.05 or nil
  e.states.collide.can = vis
  if e.children[1] then e.children[1]:remove(); e.children[1] = nil end
  e.UIBox:add_child(Panel.content(), e)      -- add_child recalculates the HUD box
  if e.children.h_popup then                 -- refresh an open tooltip
    e.children.h_popup:remove(); e.children.h_popup = nil
    if vis and e.states.hover.is then e:hover() end
  end
  Panel.fit(e)
end

-- Instance hover: build a fresh popup each time (UIBox consumes its definition table).
local function hover(self)
  local ok, def = pcall(Panel.tooltip)
  if ok and def then
    self.config.h_popup = def
    self.config.h_popup_config = { align = "cr", offset = { x = 0.15, y = 0 }, parent = self }
  else
    self.config.h_popup = nil
    if not ok then Log.error("HUD panel tooltip failed:", def) end
  end
  Node.hover(self)
  local pop = self.children.h_popup
  if pop and pop.alignment and pop.T then   -- top-align with the panel instead of centring on it
    pop.alignment.offset.y = math.max(0, (pop.T.h - self.T.h) / 2)
  end
end

local function on_frame(e)
  if not e.bes_hooked then e.hover = hover; e.bes_hooked = true end
  if Overlay.state.thinking then Panel.tick_pulse(Panel.now()) end
  local sig = signature()
  if sig ~= e.config.bes_sig then
    e.config.bes_sig = sig
    rebuild(e)
  end
end

local err_logged = false
function Panel.install()
  if Panel.installed then return end
  if not (_G.G and G.FUNCS and type(_G.create_UIBox_HUD) == "function") then
    Log.warn("create_UIBox_HUD unavailable; HUD panel disabled.")
    return
  end
  G.FUNCS[PANEL_ID] = function(e)
    local ok, err = pcall(on_frame, e)
    if not ok and not err_logged then err_logged = true; Log.error("HUD panel update failed:", err) end
  end
  local orig = _G.create_UIBox_HUD
  _G.create_UIBox_HUD = function(...)
    local def = orig(...)
    local ok, err = pcall(Panel.inject, def)
    if not ok then Log.error("HUD panel inject failed (game HUD left unchanged):", err) end
    return def
  end
  Panel.installed = true
  Log.info("HUD panel installed (native left-bar row; shows from the next run start / continue).")
end

-- No-op: the panel's func watches Overlay.state.version itself.
function Panel.refresh() end

function Panel.toggle()
  Overlay.visible = not Overlay.visible
  Log.info("Overlay " .. (Overlay.visible and "shown" or "hidden"))
end

return Panel
