-- tests/test_hud_panel.lua
-- The native HUD panel's definition builders run headless against a stub G (the real UIBox layout
-- needs the game). Checks the HUD surgery lands where intended and every builder survives every
-- state shape -- an error in-game would only be logged, leaving the panel blank.

return function(t)
  local saved = { G = _G.G, lighten = _G.lighten, darken = _G.darken }
  local function col(n) return { n, n, n, 1 } end
  _G.G = {
    UIT = { T = 1, B = 2, C = 3, R = 4, O = 5, ROOT = 7 },
    C = { WHITE = col(1), BLACK = col(0), CLEAR = col(0), GREEN = col(0.2), RED = col(0.3), BLUE = col(0.4),
      FILTER = col(0.5), MONEY = col(0.6), JOKER_GREY = col(0.7),
      UI = { TEXT_LIGHT = col(1), TEXT_DARK = col(0.1), TEXT_INACTIVE = col(0.5),
        BACKGROUND_WHITE = col(1), BACKGROUND_INACTIVE = col(0.4) },
      DYN_UI = { MAIN = col(0.8), BOSS_MAIN = col(0.2), BOSS_DARK = col(0.1) } },
  }
  _G.lighten = function(c) return c end
  _G.darken = function(c) return c end

  local ok, err = pcall(function()
    package.loaded["ui.hud_panel"] = nil
    local Overlay = require("ui.overlay")
    local Panel = require("ui.hud_panel")
    local UIT = G.UIT

    -- a definition shaped like create_UIBox_HUD's: MAIN row > BOSS_DARK row > spacer, row_blind, ...
    local function hud_def()
      return { n = UIT.ROOT, config = {}, nodes = {
        { n = UIT.R, config = { colour = G.C.DYN_UI.MAIN }, nodes = {
          { n = UIT.R, config = { minh = 30 }, nodes = {
            { n = UIT.R, config = { align = "cm", minh = 0.3 }, nodes = {} },
            { n = UIT.R, config = { id = "row_blind", minh = 3.75 }, nodes = {} },
            { n = UIT.R, config = { id = "row_dollars_chips" }, nodes = {} },
            { n = UIT.R, config = { id = "row_round" }, nodes = {
              { n = UIT.C, config = {}, nodes = {
                { n = UIT.R, config = { id = "run_info_button", minh = 1.75, button = "run_info" }, nodes = {} },
                { n = UIT.R, config = { minh = 1.75, button = "options" }, nodes = {} },
              } },
            } },
          } },
        } },
      } }
    end

    local def = Panel.inject(hud_def())
    local bar = def.nodes[1].nodes[1].nodes
    t.eq(#bar, 4, "panel REPLACES the empty top spacer (bar keeps its row count)")
    t.eq(bar[1].config.id, "bes_panel", "panel is the first row of the left bar")
    t.eq(bar[1].config.func, "bes_panel", "panel row carries its live-update func")
    t.eq(bar[2].config.id, "row_blind", "blind row follows the panel")
    t.eq(bar[4].nodes[1].nodes[2].config.id, "bes_options_button", "Options button tagged for fitting")

    -- no spacer (another mod reshaped the bar): insert before row_blind instead of overwriting
    local d2 = hud_def()
    table.remove(d2.nodes[1].nodes[1].nodes, 1)
    Panel.inject(d2)
    t.eq(d2.nodes[1].nodes[1].nodes[1].config.id, "bes_panel", "inserted above row_blind when no spacer")
    t.eq(d2.nodes[1].nodes[1].nodes[2].config.id, "row_blind", "row_blind kept")
    t.ok(not pcall(Panel.inject, { n = UIT.ROOT, nodes = {} }), "inject errors (guarded by caller) without row_blind")

    -- content: before any advice, the status shows greyed in the headline slot, no tags
    Overlay.set(nil)
    local c = Panel.content()
    local body = c.nodes[2].nodes
    t.eq(#body, 1, "no tags without a recommendation")
    t.eq(body[1].nodes[1].config.colour, G.C.UI.TEXT_INACTIVE, "status line greyed")

    -- a buy: headline without the cost, confidence + money tags
    Overlay.set({ best = { type = "BUY_JOKER", target = { name = "Blueprint" }, cost = 10,
      confidence = 0.82, expected_value = 0.12, reason = "Copies your best joker — big gain." } })
    t.eq(Overlay.state.headline, "Buy Blueprint", "headline carries no cost")
    t.eq(Overlay.state.move, "Buy Blueprint — $10", "full move still has the cost")
    c = Panel.content()
    body = c.nodes[2].nodes
    t.eq(#body, 2, "tag row present")
    local tags = {}
    for _, n in ipairs(body[2].nodes) do if n.n == UIT.C then tags[#tags + 1] = n.nodes[1].config.text end end
    t.eq(table.concat(tags, ","), "Conf 82%,$10", "tags: confidence then cost")
    t.eq(body[2].nodes[1].config.colour, G.C.GREEN, "high confidence is green")

    -- self-play status: label + tooltip badges
    Panel.autoplay = { enabled = true, auto_restart = false }
    c = Panel.content()
    t.eq(c.nodes[1].nodes[2].nodes[1].config.text, "Auto", "label shows Auto while self-playing")
    local tip = Panel.tooltip()
    local found = {}
    local function walk(n)
      if n.config and n.config.text then found[#found + 1] = n.config.text end
      for _, k in ipairs(n.nodes or {}) do walk(k) end
    end
    walk(tip)
    local all = table.concat(found, "\n")
    t.ok(all:find("Self%-play: ON"), "tooltip shows self-play ON")
    t.ok(all:find("Auto%-restart: OFF"), "tooltip shows auto-restart OFF")
    t.ok(all:find("Copies your best joker %- big gain%."), "tooltip carries the reason (dash made plain)")
    t.ok(not all:find("\226\128\148"), "no em dash reaches the pixel font")

    -- hidden (F9): a spacer-sized blank
    Overlay.visible = false
    t.eq(Panel.content().n, UIT.B, "hidden panel collapses to a spacer")
    Overlay.visible = true
    Panel.autoplay = nil

    -- wrap: every line fits, no words lost
    local long = string.rep("word ", 60)
    local lines = Panel.wrap(long, 0.32, 6.0)
    t.ok(#lines > 1, "long reason wraps")
    local words = 0
    for _, l in ipairs(lines) do
      t.ok(Panel.text_w(l, 0.32) <= 6.0 or not l:find(" "), "wrapped line fits: " .. l)
      for _ in l:gmatch("%S+") do words = words + 1 end
    end
    t.eq(words, 60, "wrap keeps every word")
    Overlay.set(nil)
  end)
  t.ok(ok, "hud_panel suite ran without error: " .. tostring(err))

  _G.G, _G.lighten, _G.darken = saved.G, saved.lighten, saved.darken
  package.loaded["ui.hud_panel"] = nil
end
