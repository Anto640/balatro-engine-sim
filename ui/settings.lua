-- ui/settings.lua
-- The mod's settings page in Steamodded's Mods menu (owner 2026-10-02), built from the game's own toggle and
-- option-cycle widgets. Steamodded loads `config.lua` (defaults) merged with the saved config/<id>.jkr into
-- SMODS.current_mod.config before main.lua runs, and saves it when the Mods menu is left.
-- S.apply (called every frame by main.lua) pushes the values to the panel, the tags and fast self-play, so a
-- change takes effect at once. F9 flips `show_panel` too, so the key and the menu never disagree.

local S = {}
S.DEFAULTS = { show_panel = true, show_tags = true, fast_selfplay = true, fast_speed = 16, think_mode = "balanced" }
S.SPEEDS = { 4, 8, 16, 32, 64 }
-- "While thinking": how much of each frame the engine may use (main.lua BES.slice_budget)
S.THINK_MODES = { "smooth", "balanced", "fast" }
S.THINK_LABELS = { "Smooth", "Balanced", "Fast" }
S.cfg = nil
S._applied_panel = nil

-- Bind to the mod's config table (filling any missing default); headless callers pass nil.
function S.init(mod)
  local cfg = (mod and type(mod.config) == "table") and mod.config or {}
  for k, v in pairs(S.DEFAULTS) do if cfg[k] == nil then cfg[k] = v end end
  if mod then mod.config = cfg end
  S.cfg = cfg
  S._applied_panel = nil
  return cfg
end

-- Push the settings to the live modules: ctx = { overlay =, highlights =, fast = }.
-- show_panel is applied on CHANGE only, so it never fights a transient state.
function S.apply(ctx)
  local c = S.cfg
  if not c then return end
  if c.show_panel ~= S._applied_panel then
    S._applied_panel = c.show_panel
    if ctx.overlay then ctx.overlay.visible = c.show_panel and true or false end
  end
  if ctx.highlights then ctx.highlights.enabled = c.show_tags and true or false end
  if ctx.fast then
    ctx.fast.enabled = c.fast_selfplay and true or false
    ctx.fast.SPEED = tonumber(c.fast_speed) or S.DEFAULTS.fast_speed
  end
  if ctx.scheduler then ctx.scheduler.think_mode = c.think_mode or S.DEFAULTS.think_mode end
end

-- F9: flip the panel setting (S.apply shows / hides it next frame).
function S.toggle_panel()
  if not S.cfg then return nil end
  S.cfg.show_panel = not S.cfg.show_panel
  return S.cfg.show_panel
end

local function speed_index(v)
  for i, s in ipairs(S.SPEEDS) do if s == v then return i end end
  return 3
end
local function think_index(v)
  for i, s in ipairs(S.THINK_MODES) do if s == v then return i end end
  return 2
end

-- The settings page (Steamodded calls this when the mod's Config tab opens).
function S.tab()
  local cfg = S.cfg or S.init(nil)
  local labels = {}
  for i, v in ipairs(S.SPEEDS) do labels[i] = "x" .. v end
  local function heading(t)
    return { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
      { n = G.UIT.T, config = { text = t, scale = 0.45, colour = G.C.GOLD, shadow = true } },
    } }
  end
  return { n = G.UIT.ROOT, config = { align = "cm", padding = 0.15, colour = G.C.BLACK, r = 0.1, emboss = 0.05, minw = 7 }, nodes = {
    heading("Advice"),
    create_toggle({ label = "Show the advice panel (F9)", ref_table = cfg, ref_value = "show_panel", w = 4.5 }),
    create_toggle({ label = "Tag the recommended cards", ref_table = cfg, ref_value = "show_tags", w = 4.5 }),
    create_option_cycle({ label = "While thinking", options = S.THINK_LABELS,
      current_option = think_index(cfg.think_mode), opt_callback = "bes_cfg_think_mode", scale = 0.8, w = 3,
      info = { "Smooth: full frame rate.  Balanced: 60 fps.  Fast: answers sooner, frames drop." } }),
    heading("Self-play (F11)"),
    create_toggle({ label = "Skip animations while it plays", ref_table = cfg, ref_value = "fast_selfplay", w = 4.5,
      info = { "Uses the Handy mod's animation skip. Your own play is never affected." } }),
    create_option_cycle({ label = "Self-play speed", options = labels, current_option = speed_index(cfg.fast_speed),
      opt_callback = "bes_cfg_fast_speed", scale = 0.8, w = 3 }),
    { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = {
      { n = G.UIT.T, config = { text = "Saved when you leave the Mods menu.", scale = 0.28, colour = G.C.UI.TEXT_INACTIVE } },
    } },
  } }
end

-- option-cycle callback (the game passes { to_key, to_val, ... })
function S.on_speed(args)
  if S.cfg and args then S.cfg.fast_speed = S.SPEEDS[args.to_key] or S.cfg.fast_speed end
end

function S.on_think_mode(args)
  if S.cfg and args then S.cfg.think_mode = S.THINK_MODES[args.to_key] or S.cfg.think_mode end
end

-- Register with Steamodded (in-game only).
function S.install(mod)
  S.init(mod)
  if G and G.FUNCS then
    G.FUNCS.bes_cfg_fast_speed = S.on_speed
    G.FUNCS.bes_cfg_think_mode = S.on_think_mode
  end
  if mod then mod.config_tab = S.tab end
end

return S
