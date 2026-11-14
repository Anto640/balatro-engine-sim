-- tests/test_settings.lua
-- The Mods-menu settings page (ui/settings.lua): defaults merge under saved values, the values reach the live
-- modules at once, F9 and the menu stay in step, and the page builds from the game's own widgets.

return function(t)
  local saved = { G = _G.G, toggle = _G.create_toggle, cycle = _G.create_option_cycle }
  local ok, err = pcall(function()
    package.loaded["ui.settings"] = nil
    local S = require("ui.settings")

    -- a saved config with one value changed; missing keys get the defaults
    local mod = { config = { fast_speed = 32 } }
    local cfg = S.init(mod)
    t.eq(cfg.fast_speed, 32, "saved value kept")
    t.eq(cfg.show_panel, true, "missing value -> default")
    t.eq(mod.config, cfg, "bound to the mod's own config table (what Steamodded saves)")

    -- apply: values reach the panel, the tags and fast mode
    local overlay, hl, fast = { visible = true }, {}, { enabled = true, SPEED = 16 }
    local ctx = { overlay = overlay, highlights = hl, fast = fast }
    cfg.show_tags, cfg.fast_selfplay = false, false
    S.apply(ctx)
    t.eq(hl.enabled, false, "tags switched off")
    t.eq(fast.enabled, false, "fast self-play switched off")
    t.eq(fast.SPEED, 32, "self-play speed applied")

    -- F9 flips the same setting the menu shows
    t.eq(S.toggle_panel(), false, "F9 hides the panel setting")
    S.apply(ctx)
    t.eq(overlay.visible, false, "panel hidden")
    overlay.visible = true      -- something else showed it: apply only acts on a CHANGE of the setting
    S.apply(ctx)
    t.eq(overlay.visible, true, "show_panel applied on change only")
    S.toggle_panel(); S.apply(ctx)
    t.eq(overlay.visible, true, "F9 again shows it")

    -- F9 SAVES the setting (Steamodded only saves on leaving the Mods menu, so the panel came back off)
    local smods, saved_mod = _G.SMODS, nil
    _G.SMODS = { save_mod_config = function(m) saved_mod = m; return true end }
    local shown = S.toggle_panel()
    _G.SMODS = smods
    t.eq(saved_mod, mod, "F9 saves the mod's config")
    t.eq(mod.config.show_panel, shown, "and the saved table carries the new value")
    S.toggle_panel(); S.apply(ctx)
    t.eq(overlay.visible, true, "panel back on for the rest of the suite")

    -- the speed cycle callback
    S.on_speed({ to_key = 1, to_val = "x4" })
    t.eq(cfg.fast_speed, 4, "option cycle sets the speed")

    -- the page builds with the game's widgets
    local made = {}
    _G.G = { UIT = { T = 1, B = 2, C = 3, R = 4, ROOT = 7 }, FUNCS = {},
      C = { BLACK = {}, GOLD = {}, UI = { TEXT_INACTIVE = {} } } }
    _G.create_toggle = function(a) made[#made + 1] = "toggle:" .. a.ref_value; return { n = 4, config = {}, nodes = {} } end
    _G.create_option_cycle = function(a)
      made[#made + 1] = "cycle:" .. a.current_option .. ":" .. a.options[a.current_option]
      return { n = 4, config = {}, nodes = {} }
    end
    S.install(mod)
    t.eq(mod.config_tab, S.tab, "config tab registered with Steamodded")
    t.eq(G.FUNCS.bes_cfg_fast_speed, S.on_speed, "speed callback registered")
    local page = mod.config_tab()
    t.ok(page and page.n == 7, "page is a UI root")
    t.eq(table.concat(made, ","), "toggle:show_panel,toggle:show_tags,cycle:2:Balanced,toggle:fast_selfplay,cycle:1:x4",
      "page: panel, tags, while-thinking (default Balanced), fast self-play, speed")
    S.on_think_mode({ to_key = 1 })
    t.eq(cfg.think_mode, "smooth", "while-thinking cycle sets the mode")
    local sched = {}
    S.apply({ scheduler = sched })
    t.eq(sched.think_mode, "smooth", "mode reaches the scheduler")
    t.eq(G.FUNCS.bes_cfg_think_mode, S.on_think_mode, "while-thinking callback registered")

    -- fast mode honours the switch
    package.loaded["ui.fast_mode"] = nil
    local Fast = require("ui.fast_mode")
    Fast.installed, Fast.autoplay = true, { enabled = true }
    local saved_handy = rawget(_G, "Handy")
    _G.Handy = {}
    t.ok(Fast.engaged(), "fast mode engages while self-play runs")
    Fast.enabled = false
    t.ok(not Fast.engaged(), "... not when switched off in the settings")
    _G.Handy = saved_handy
    package.loaded["ui.fast_mode"] = nil
  end)
  t.ok(ok, "settings suite ran without error: " .. tostring(err))
  _G.G, _G.create_toggle, _G.create_option_cycle = saved.G, saved.toggle, saved.cycle
  package.loaded["ui.settings"] = nil
end
