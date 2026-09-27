-- ui/hud_inject.lua
-- Renders the recommendation panel by hooking love.draw and drawing directly with
-- love.graphics. This bypasses Balatro's UIBox/DynaText system (which proved unreliable
-- for a live-updating overlay -- invisible text -- and unsafe to rebuild -- G.HUD FRAME
-- crash). Drawing ourselves is guaranteed visible, updates every frame from Overlay.state,
-- and never touches G.HUD's node tree.
--
-- Styled to look NATIVE: it uses Balatro's own pixel font (G.LANG.font.FONT) and colour
-- palette, a rounded dark panel with a gold accent, and sits in the LEFT run-info bar,
-- above the game's own HUD -- which we nudge down (guarded) to make room.
--
-- Runtime-only. install() is a no-op outside the game (no `love`).

local Overlay = require("ui.overlay")
local Log = require("util.log")

local HUD = {}
HUD.installed = false

-- ---- placement / style (tunable; all fractions of the screen so it scales) ----
local PANEL = {
  x_frac   = 0.010,   -- left margin
  y_frac   = 0.012,   -- top margin (panel sits at the very top of the left bar)
  w_frac   = 0.210,   -- width ~ the left run-info column
  min_w    = 210, max_w = 380,
  pad      = 14,
  line_gap = 5,
  title_px = 24,      -- desired on-screen pixel height
  move_px  = 19,
  body_px  = 15,
  radius   = 10,
  shift_hud = true,   -- push Balatro's own left HUD down by our panel height (guarded)
  hud_gap  = 10,
}

-- Balatro palette (r,g,b[,a]). Panel/border tuned to match the game's dark UI panels.
local COL = {
  title  = { 1.00, 0.82, 0.22 },   -- gold
  move   = { 1.00, 1.00, 1.00 },
  conf   = { 0.80, 0.82, 0.90 },
  ev     = { 0.42, 0.92, 0.52 },
  winp   = { 0.52, 0.72, 1.00 },
  reason = { 0.80, 0.80, 0.84 },
  panel  = { 0.11, 0.13, 0.18, 0.93 },
  border = { 0.58, 0.44, 0.16, 0.55 },
  accent = { 1.00, 0.82, 0.22, 0.85 },
}

-- Balatro's pixel font -> native look. Returns (font, baseHeight) or (nil, nil).
local fallback_font
local function pick_font()
  local ok, f = pcall(function() return _G.G and G.LANG and G.LANG.font and G.LANG.font.FONT end)
  if ok and f and f.getHeight then return f, f:getHeight() end
  local ok2, f2 = pcall(function() return _G.G and G.FONTS and G.FONTS[1] and G.FONTS[1].FONT end)
  if ok2 and f2 and f2.getHeight then return f2, f2:getHeight() end
  if not fallback_font and love and love.graphics then
    local ok3, ff = pcall(love.graphics.newFont, 16); if ok3 then fallback_font = ff end
  end
  return fallback_font, fallback_font and fallback_font:getHeight() or nil
end

-- Width-aware word wrap (measures with the real font so the narrow left column fits).
local function wrap_px(text, font, scale, maxw)
  local out = {}
  for para in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    if para ~= "" then
      local cur = ""
      for word in para:gmatch("%S+") do
        local cand = (cur == "") and word or (cur .. " " .. word)
        if cur ~= "" and font:getWidth(cand) * scale > maxw then
          out[#out + 1] = cur; cur = word
        else
          cur = cand
        end
      end
      if cur ~= "" then out[#out + 1] = cur end
    end
  end
  return out
end

-- The actual drawing. May freely error; the caller guarantees the matching pop.
local last_h = 0
local function draw_panel()
  local st = Overlay.state
  local font, base = pick_font()
  if not font then return end

  local W, Hs = love.graphics.getWidth(), love.graphics.getHeight()
  local pad = PANEL.pad
  local boxW = math.max(PANEL.min_w, math.min(PANEL.max_w, W * PANEL.w_frac))
  local x, y = W * PANEL.x_frac, Hs * PANEL.y_frac
  local innerW = boxW - pad * 2

  -- scale the one pixel font to each target height
  local function sc(px) return px / base end
  -- lines: {text, target_px, colour}
  -- live self-play / auto-restart status (owner 2026-09-27), read from the auto-player each frame
  local ap = HUD.autoplay
  local status = ap and string.format("Self-play: %s   Auto-restart: %s  (F11 / F6)",
    ap.enabled and "ON" or "OFF", ap.auto_restart and "ON" or "OFF") or nil
  local spec = {
    { st.title,   PANEL.title_px, COL.title },
    { status,     PANEL.body_px,  (ap and ap.enabled) and COL.ev or COL.reason },
    { st.move,    PANEL.move_px,  COL.move },
    { st.conf,    PANEL.body_px,  COL.conf },
    { st.ev,      PANEL.body_px,  COL.ev },
    { st.winp,    PANEL.body_px,  COL.winp },
    { st.reorder, PANEL.body_px,  COL.title },
    { st.reason,  PANEL.body_px,  COL.reason },
  }
  -- expand to physical rows {text, scale, colour, height}
  local rows = {}
  for _, l in ipairs(spec) do
    if l[1] and l[1] ~= "" then
      local scale = sc(l[2])
      for _, sub in ipairs(wrap_px(l[1], font, scale, innerW)) do
        rows[#rows + 1] = { sub, scale, l[3], base * scale }
      end
    end
  end
  if #rows == 0 then return end

  local boxH = pad * 2
  for _, r in ipairs(rows) do boxH = boxH + r[4] + PANEL.line_gap end
  boxH = boxH - PANEL.line_gap
  last_h = boxH

  love.graphics.origin()  -- raw screen pixels
  -- panel
  love.graphics.setColor(COL.panel)
  love.graphics.rectangle("fill", x, y, boxW, boxH, PANEL.radius, PANEL.radius)
  -- gold accent strip down the left edge + border
  love.graphics.setColor(COL.accent)
  love.graphics.rectangle("fill", x, y, 3, boxH, 2, 2)
  love.graphics.setColor(COL.border)
  love.graphics.setLineWidth(1.5)
  love.graphics.rectangle("line", x, y, boxW, boxH, PANEL.radius, PANEL.radius)

  love.graphics.setFont(font)
  local cy = y + pad
  for _, r in ipairs(rows) do
    local c = r[3]
    love.graphics.setColor(c[1], c[2], c[3], c[4] or 1)
    love.graphics.print(tostring(r[1]), x + pad, cy, 0, r[2], r[2])
    cy = cy + r[4] + PANEL.line_gap
  end
end

-- Push Balatro's own left HUD down so our panel sits ABOVE it (guarded, idempotent).
-- We capture the HUD's original target-y once, then keep its target below our panel.
local hud_base_y
local function shift_hud()
  if not PANEL.shift_hud then return end
  local hud = _G.G and G.HUD
  if not hud or not hud.T then return end
  local Hs = love.graphics.getHeight()
  if not (G.ROOM and G.ROOM.T and G.ROOM.T.h and Hs and Hs > 0) then return end
  if hud_base_y == nil then hud_base_y = hud.T.y end            -- the HUD's natural top
  -- push the HUD DOWN by our panel's height + gap, converting pixels -> Balatro world units
  -- (T is in world units, not pixels). CLAMPED so a bad estimate can never shove the run
  -- info off-screen -- worst case it moves down a modest, still-visible amount.
  local px_to_unit = G.ROOM.T.h / Hs
  local offset = (last_h + PANEL.hud_gap) * px_to_unit
  offset = math.max(0, math.min(offset, G.ROOM.T.h * 0.28))
  local target = (hud_base_y or 0) + offset
  if math.abs((hud.T.y or 0) - target) > 0.001 then hud.T.y = target end
end

function HUD.render()
  if not Overlay.visible or not (love and love.graphics) then return end
  love.graphics.push("all")  -- snapshot transform/colour/font; pop ALWAYS runs
  local ok, err = pcall(draw_panel)
  love.graphics.pop()
  if not ok then Log.error("overlay draw failed:", err) end
  pcall(shift_hud)  -- fully guarded: if the HUD move fails, the panel still renders
end

function HUD.install()
  if HUD.installed then return end
  if not (love and love.draw) then
    Log.warn("love.draw unavailable; overlay disabled.")
    return
  end
  local prev = love.draw
  love.draw = function(...)
    if prev then prev(...) end
    pcall(HUD.render)
  end
  HUD.installed = true
  Log.info("Overlay (love.draw, native left-bar) installed.")
end

-- No-op: the love.draw hook reads Overlay.state live, nothing to rebuild.
function HUD.refresh() end

function HUD.toggle()
  Overlay.visible = not Overlay.visible
  -- when hidden, let the game HUD return to its natural position
  if not Overlay.visible then hud_base_y = nil end
  Log.info("Overlay " .. (Overlay.visible and "shown" or "hidden"))
end

return HUD
