-- tests/test_hud_panel.lua
-- The native HUD panel's definition builders run headless against a stub G (the real UIBox layout
-- needs the game). Checks the HUD surgery lands where intended and every builder survives every
-- state shape -- an error in-game would only be logged, leaving the panel blank.

return function(t)
  local saved = { G = _G.G, lighten = _G.lighten, darken = _G.darken, UIBox = _G.UIBox }
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

    -- predicted score vs the chips still needed (PLAY only)
    t.eq(Overlay.fmt_num(1234567), "1,234,567", "thousands separators")
    t.eq(Overlay.fmt_num(999), "999", "small numbers plain")
    t.eq(Overlay.fmt_num(23456789), "23.5M", "very large numbers shortened")
    local blind_gs = { blind = { target_chips = 3300, chips_scored = 300 } }
    Overlay.set({ best = { type = "PLAY", cards = {}, score = 4200, confidence = 0.8 } }, blind_gs)
    local function tag_texts(c2)
      local o = {}
      for _, n in ipairs((c2.nodes[2].nodes[2] or { nodes = {} }).nodes) do
        if n.n == UIT.C then o[#o + 1] = { n.nodes[1].config.text, n.config.colour } end
      end
      return o
    end
    local tt = tag_texts(Panel.content())
    t.eq(tt[1] and tt[1][1], "~4,200 / 3,000", "score tag: predicted vs still needed")
    t.eq(tt[1] and tt[1][2], G.C.GREEN, "green when the play clears")
    Overlay.set({ best = { type = "PLAY", cards = {}, score = 1800, confidence = 0.8 } }, blind_gs)
    tt = tag_texts(Panel.content())
    t.eq(tt[1] and tt[1][2], G.C.RED, "red when it falls short")
    Overlay.set({ best = { type = "DISCARD", cards = {}, score = 1800, confidence = 0.8 } }, blind_gs)
    tt = tag_texts(Panel.content())
    t.ok(not (tt[1] and tt[1][1]:find("/")), "no score tag for a discard")
    Overlay.set({ best = { type = "BUY_JOKER", target = { name = "Blueprint" }, cost = 10,
      confidence = 0.82, expected_value = 0.12, reason = "Copies your best joker — big gain." } })

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

    -- thinking: pulsing label, a "working it out" line (not the old move greyed), the progress bar instead of the tags
    local saved_love = _G.love
    local now = 50
    _G.love = { timer = { getTime = function() return now end } }
    Panel.autoplay = nil
    Overlay.set_thinking(true, now)
    t.eq(Panel.content().nodes[1].nodes[2].nodes[1].config.text, "Advice", "a quick answer never flashes Thinking")
    now = now + 0.5
    c = Panel.content()
    t.eq(c.nodes[1].nodes[2].nodes[1].config.text, "Thinking", "label reads Thinking once it lasts")
    body = c.nodes[2].nodes
    local htext = {}
    for i = 1, #body - 1 do htext[#htext + 1] = body[i].nodes[1].config.text end
    t.eq(table.concat(htext, " "), "Working out the best move...", "says it is working, not the previous move greyed")
    local bar = body[#body].nodes[1].config.progress_bar
    t.ok(bar and bar.ref_table == Overlay.state and bar.ref_value == "progress", "progress bar bound to the live progress")
    Panel.tick_pulse(1.0)
    t.ok(Panel.pulse and Panel.pulse[1] ~= nil, "pulse colour animates in place")
    found = {}; walk(Panel.tooltip())
    t.ok(table.concat(found, "\n"):find("wait for it before acting"), "tooltip says to wait")
    Overlay.set_thinking(false, now)
    t.eq(Panel.content().nodes[1].nodes[2].nodes[1].config.text, "Advice", "back to Advice when the answer lands")

    -- error indicator: Log.error reaches the panel through util/log's on_error hook
    local Log = require("util.log")
    local lvl, hook = Log.level, Log.on_error
    Log.level = "off"   -- the listener fires even when the line itself is filtered
    Log.on_error = function(msg) Overlay.add_error(msg, now, "12:34") end
    t.eq(#Panel.label_row(), 1, "no error -> plain Engine label")
    Log.error("shop advisor failed:", "boom")
    Log.level, Log.on_error = lvl, hook
    local lr = Panel.label_row()
    t.eq(#lr, 3, "an error adds a red ! beside the label")
    t.eq(lr[3].nodes[1].config.text, "!", "... the ! tag")
    found = {}; walk(Panel.tooltip())
    t.ok(table.concat(found, "\n"):find("12:34 shop advisor failed: boom", 1, true), "popup lists the error with its time")
    now = now + Overlay.ERROR_SHOW_FOR + 1
    t.eq(#Panel.label_row(), 1, "the indicator clears once the error is old")
    Overlay.errors = {}
    _G.love = saved_love

    -- ---- fitting the left bar on screen: gentlest steps first, re-measured after each ----
    local function fit_case(extra)
      local f = { bar = { padding = 0.08 }, buttons = { { minh = 1.75 }, { minh = 1.75 } },
        boxes = { { minh = 1.15 }, { minh = 1 }, { minh = 1 } } }
      local last = { T = { y = 0, h = 0 } }
      local e = { config = { bes_fitcfg = f, align = "cm" }, T = { y = 0, h = 1.0 }, states = { collide = {}, hover = {} } }
      local hud = {}
      function hud.get_UIE_by_ID(_, id) return id == "row_round" and last or nil end
      function hud.recalculate()   -- a bar whose height follows the same configs Panel.fit edits
        local panel = e.config.bes_compact and 0.55 or 1.0
        if e.config.minh then panel = math.max(panel, e.config.minh) end
        local btn = f.buttons[1].minh + f.buttons[2].minh + 0.6
        local col = f.boxes[1].minh + f.boxes[2].minh + f.boxes[3].minh + 0.6
        local rr = math.max(btn, col)
        local bar = panel + extra + 7.05 + rr + 6 * f.bar.padding
        e.T.h = panel
        last.T.y, last.T.h = e.T.y + bar - rr, rr
      end
      function hud.add_child() hud.recalculate() end
      e.UIBox = hud
      e.children = { { remove = function() end } }
      hud.recalculate()
      Panel.fit(e)
      local h = (last.T.y + last.T.h) - e.T.y
      return e, h
    end
    local saved_love2 = _G.love
    _G.love = { graphics = { getHeight = function() return 258 end }, timer = { getTime = function() return 0 end } }
    G.TILESIZE, G.TILESCALE = 20, 1          -- 258 px / 20 = 12.9 units visible (16:9)
    local e0, h0 = fit_case(0)
    t.eq(e0.config.bes_fit or 0, 0, "a bar that fits is left alone")
    local e1, h1 = fit_case(1.0)
    t.ok(e1.config.bes_fit > 2 and e1.config.bes_fit < #Panel.FIT_STEPS, "a taller bar: buttons, spacing, boxes ...")
    t.ok(not e1.config.bes_compact, "... keeping the two-row panel (compact is the last resort)")
    t.ok(h1 <= 12.9 - 0.16 + 1e-9, "... and it now fits (" .. string.format("%.2f", h1) .. ")")
    t.eq(e1.config.align, "cm", "... with no last-resort push")
    local e2 = fit_case(2.0)
    t.eq(e2.config.bes_fit, #Panel.FIT_STEPS, "a very tall bar uses every step")
    t.eq(e2.config.align, "bm", "... then keeps the top on screen (content pinned to the bottom of a taller first row)")
    t.ok(e2.config.bes_push and e2.config.bes_push > 0, "... by exactly the remaining overflow")
    _G.love = saved_love2

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

    -- ---- in-world highlights: the plan (pure) ----
    local H = require("ui.highlights")
    local function labels(plan)
      local o = {}
      for _, w in ipairs(plan) do o[#o + 1] = w.label .. ":" .. (w.kind == "card" and w.areas[1] or w.names[1]) end
      return table.concat(o, ",")
    end
    t.eq(labels(H.plan({ type = "PLAY", cards = { { id = 1 }, { id = 2 } } })), "PLAY:hand,PLAY:hand", "play tags each hand card")
    t.eq(labels(H.plan({ type = "DISCARD", cards = { { id = 3 } } })), "DISCARD:hand", "discard tags the card")
    t.eq(labels(H.plan({ type = "USE_CONSUMABLE", target = { id = 9, key = "c_empress" }, target_cards = { { id = 1 } } })),
      "USE:consumeables,TARGET:hand", "tarot: the card to use and its target")
    t.eq(labels(H.plan({ type = "SELL_TO_BUY", target = { id = 5 }, then_buy = { key = "j_blueprint" } })),
      "SELL:jokers,BUY:shop_jokers", "sell-to-buy tags both ends")
    t.eq(labels(H.plan({ type = "BUY_PACK", target = { key = "p_arcana_normal_1" } })), "OPEN:shop_jokers", "pack -> OPEN")
    t.eq(labels(H.plan({ type = "PICK", target = { key = "c_death", id = 7 }, target_cards = { { id = 1 }, { id = 2 } } })),
      "TAKE:pack_cards,TARGET:hand,TARGET:hand", "pack pick + its targets")
    t.eq(labels(H.plan({ type = "REROLL" })), "BEST:reroll_shop", "reroll -> the reroll button")
    t.eq(labels(H.plan({ type = "SAVE" })), "BEST:toggle_shop", "save -> Next Round")
    t.eq(labels(H.plan({ type = "SKIP" })), "BEST:skip_booster", "skip -> pack skip first, then blind skip")
    t.eq(labels(H.plan({ type = "PLAY", cards = { { id = 1 }, { id = 2 } },
      reorder = { card_changed = true, card_order = { { id = 2 }, { id = 1 } },
                  joker_changed = true, joker_order = { { id = 30, key = "j_a" }, { id = 31, key = "j_b" } } } })),
      "1:hand,2:hand,1:jokers,2:jokers", "reorder: cards and jokers numbered in the order to arrange them")
    local rp = H.plan({ type = "PLAY", cards = { { id = 1 }, { id = 2 } },
      reorder = { card_changed = true, card_order = { { id = 2 }, { id = 1 } } } })
    t.eq(rp[1].target.id, 2, "number 1 goes on the card to play first")
    t.eq(labels(H.plan({ type = "PLAY", cards = { { id = 1 } }, reorder = { card_changed = false, joker_changed = false } })),
      "PLAY:hand", "no order change -> plain PLAY tags")
    t.eq(labels(H.plan({ type = "CONTINUE", arrange = { { id = 30 }, { id = 31 } } })),
      "BEST:select_blind,1:jokers,2:jokers", "Dagger arrangement numbered")
    t.eq(#H.plan({ type = "Evaluating pack…" }), 0, "a placeholder action tags nothing")
    t.eq(#H.plan({ type = "BUY_JOKER" }), 0, "no target -> no tag")
    t.eq(#H.plan(nil), 0, "nil action -> no tag")

    -- ---- highlights runtime: tag lifecycle against stub areas + a fake UIBox ----
    local made = 0
    _G.UIBox = function(args)
      made = made + 1
      return { args = args, states = { collide = {} }, remove = function(self) self.REMOVED = true end }
    end
    local AP = require("ui.autoplay")
    local fake = { _find_card = AP._find_card, _find_button = function() return nil end,
      in_transition = function() return false end, _channel = function() return "shop" end,
      _type_ok = function() return true end, _fresh = function() return true end }
    H.autoplay = fake
    local bp = { sort_id = 41, config = { center = { key = "j_blueprint" } } }
    local sc = { sort_id = 42, config = { center = { key = "j_scholar" } } }
    G.shop_jokers = { cards = { bp, sc } }; bp.area = G.shop_jokers; sc.area = G.shop_jokers
    G.C.ORANGE, G.C.GOLD, G.C.PURPLE = col(0.9), col(0.8), col(0.6)
    local last = { gs = {}, ranked = { best = { type = "BUY_JOKER", target = { id = 41, key = "j_blueprint" } } } }
    H.update(1, last)
    t.ok(H.tags[bp] and H.tags[bp].label == "BUY", "BUY tag on the recommended shop joker")
    t.ok(not H.tags[sc], "no tag on the other shop joker")
    t.eq(H.tags[bp].box.args.config.major, bp, "tag follows its card")
    t.eq(H.tags[bp].box.args.config.align, "bm", "shop tags sit below the card (price is on top)")
    t.ok(H.tags[bp].box.attention_text, "tag draws in the after-cards pass")
    local n0 = made
    H.update(1, last)
    t.eq(made, n0, "an unchanged recommendation keeps its tag (no rebuild flicker)")
    bp.highlighted = true
    H.update(1, last)
    t.ok(not H.tags[bp], "selected shop card: tag yields to the game's Buy button")
    bp.highlighted = nil
    H.update(1, last)
    local box = H.tags[bp].box
    last.ranked.best = { type = "BUY_JOKER", target = { id = 42, key = "j_scholar" } }
    H.update(1, last)
    t.ok(box.REMOVED and not H.tags[bp] and H.tags[sc], "new advice moves the tag")
    sc.REMOVED = true
    H.update(0, last)
    t.ok(not H.tags[sc], "a bought / removed card drops its tag the same frame")
    last.provisional = true
    sc.REMOVED = nil
    H.update(1, last)
    t.ok(next(H.tags) == nil, "a provisional (still evaluating) pick shows no tag")
    last.provisional = nil
    Overlay.visible = false
    H.update(1, last)
    t.ok(next(H.tags) == nil, "F9 hides the tags too")
    Overlay.visible = true
    H.clear(); H.autoplay = nil
  end)
  t.ok(ok, "hud_panel suite ran without error: " .. tostring(err))

  _G.G, _G.lighten, _G.darken, _G.UIBox = saved.G, saved.lighten, saved.darken, saved.UIBox
  package.loaded["ui.hud_panel"] = nil
end
