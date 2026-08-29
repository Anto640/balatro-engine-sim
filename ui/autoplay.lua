-- ui/autoplay.lua
-- AUTO-PLAY ACTUATOR (2026-08-29) — translate the engine's recommendation into REAL game inputs so the
-- engine plays the ACTUAL Balatro game (real RNG + mechanics, no sim-fidelity gap) — a run to WATCH and
-- ANALYSE, a far better testbed than the headless sim. Reads live `G`, drives the game's own UI buttons.
-- Toggle: F11 (default OFF).
--
-- ⭐ ACTUATION MODEL (learned the hard way): Balatro's action FUNCs are UI BUTTON CALLBACKS — they index
-- the real button element (`e.UIBox`, `e.config.ref_table`). Fabricating `e = {config=...}` CRASHES the
-- game inside a deferred event (uncatchable by our pcall). So we FIND THE REAL BUTTON NODE in the live UI
-- tree (by its `config.button` name, and for card actions by matching `config.ref_table` to the target
-- card) and invoke the callback with that real node. No fabricated events.
--
-- ALL CHANNELS: blind select · in-blind play/discard/use · shop buy/sell/use/reroll/leave · pack
-- pick/skip · cash-out. With F11 on it drives whole runs unattended.
--
-- ROBUSTNESS:
--  * LAG — a FRESHNESS gate (recommendation TYPE matches the current STATE, AND the live state matches
--    the state the decision was computed on: BES.last.gs) + a post-action lockout, so we never act on a
--    stale decision while the MC refine lags.
--  * CARD POSITIONS — matched ONLY by stable id (sort_id/unique_val) or center key, read from live G at
--    execution; positions/indices never used.
-- Everything pcall'd + logged to bes_autoplay.log (the in-game logger only print()s). Defaults OFF.

local Autoplay = { enabled = false, locked_until = 0, last_sig = nil,
                   STABLE_HOLD = 0.6, pending_id = nil, pending_since = 0 }

local function now() return (love and love.timer and love.timer.getTime()) or 0 end
local function flog(msg)
  pcall(function()
    if love and love.filesystem then love.filesystem.append("bes_autoplay.log", os.date("%H:%M:%S ") .. msg .. "\n") end
  end)
end
local function log(logger, msg) if logger then logger("[autoplay] " .. msg) end flog(msg) end
Autoplay.flog = flog

-- One-shot structural dump of the LIVE UI, to bes_autoplay.log — so we can see where Balatro actually
-- keeps its buttons (my first guesses at G.I.UIBOX / .nodes / config.button found nothing). Runs on each
-- F11-ON so it can be triggered at different screens (blind select, shop, pack) to map every button.
function Autoplay.dump_ui(G)
  flog("--- UI DUMP (state=" .. tostring(G.STATE) .. ") ---")
  local gk = {}
  for k, v in pairs(G) do if type(v) == "table" then gk[#gk + 1] = tostring(k) end end
  table.sort(gk); flog("G tables: " .. table.concat(gk, ", "))
  for _, name in ipairs({ "I", "OVERLAY_MENU", "HUD", "blind_select", "shop", "buttons", "STAGE_OBJECTS", "MID" }) do
    local v = G[name]
    if v == nil then flog("G." .. name .. " = nil")
    elseif type(v) == "table" then
      local kk = {}; for k2 in pairs(v) do kk[#kk + 1] = tostring(k2) end; table.sort(kk)
      flog("G." .. name .. " keys: " .. table.concat(kk, ", "):sub(1, 400))
    else flog("G." .. name .. " = " .. type(v)) end
  end
  if type(G.I) == "table" then
    for k, v in pairs(G.I) do if type(v) == "table" then
      local n = 0; for _ in pairs(v) do n = n + 1 end; flog("  G.I." .. tostring(k) .. " (#" .. n .. ")")
    end end
  end
  -- Generic bounded walk over the on-screen UI: collect every config.button / config.func and the
  -- ref_table key it carries. (Roots are APPENDED, skipping nils — a constructor {G.OVERLAY_MENU=nil,..}
  -- truncates at the first nil, which is why this dumped nothing before.)
  local found, seen, count = {}, {}, 0
  local function refkey(cfg)
    local r = cfg.ref_table
    if type(r) ~= "table" then return "" end
    local k = (r.config and r.config.center and r.config.center.key) or r.key or r.sort_id or r.unique_val
    return k and ("=" .. tostring(k)) or "=<ref>"
  end
  local function walk(node, depth)
    if count > 60000 or type(node) ~= "table" or depth > 30 or seen[node] then return end
    seen[node] = true; count = count + 1
    local cfg = node.config
    if type(cfg) == "table" then
      if cfg.button then found["btn:" .. tostring(cfg.button) .. refkey(cfg)] = true end
      if type(cfg.func) == "string" then found["func:" .. cfg.func] = true end
    end
    if node.UIRoot then walk(node.UIRoot, depth + 1) end
    for _, kf in ipairs({ "children", "nodes" }) do
      if type(node[kf]) == "table" then for _, ch in pairs(node[kf]) do walk(ch, depth + 1) end end
    end
  end
  local roots = {}
  if G.I and G.I.UIBOX then for _, ub in pairs(G.I.UIBOX) do roots[#roots + 1] = ub end end
  for _, r in ipairs({ G.HUD, G.blind_select, G.shop, G.STAGE_OBJECTS[1], G.STAGE_OBJECTS[2], G.STAGE_OBJECTS[3] }) do
    roots[#roots + 1] = r
  end
  pcall(function() for _, r in ipairs(roots) do walk(r, 0) end end)
  local list = {}; for k in pairs(found) do list[#list + 1] = k end; table.sort(list)
  flog("BUTTONS+FUNCS (visited " .. count .. ", " .. #roots .. " roots): [" .. table.concat(list, ", ") .. "]")
  flog("--- END UI DUMP ---")
end

function Autoplay.toggle()
  Autoplay.enabled = not Autoplay.enabled
  Autoplay.locked_until = now() + 1.0
  Autoplay.last_sig = nil
  flog("==== AUTO-PLAY " .. (Autoplay.enabled and "ON" or "OFF") .. " ====")
  if Autoplay.enabled then pcall(Autoplay.dump_ui, _G.G) end
  return Autoplay.enabled
end

-- ---- id / matching helpers (position-independent) ---------------------------
local function cid(card) return card and (card.sort_id or card.unique_val) or nil end
local function ckey(card) return card and card.config and card.config.center and card.config.center.key or nil end
local function ids_of_area(area)
  local t = {}
  if area and area.cards then for _, c in ipairs(area.cards) do t[#t + 1] = tostring(cid(c) or "?") end end
  table.sort(t); return table.concat(t, ",")
end
local function ids_of_pod(list)
  local t = {}
  for _, c in ipairs(list or {}) do t[#t + 1] = tostring(c.id or "?") end
  table.sort(t); return table.concat(t, ",")
end
-- pack items carry NO stable id (state_extraction reads only set/key/name) -> match packs by CENTER KEY.
local function keys_of_area(area)
  local t = {}
  if area and area.cards then for _, c in ipairs(area.cards) do t[#t + 1] = tostring(ckey(c) or "?") end end
  table.sort(t); return table.concat(t, ",")
end
local function keys_of_pod(list)
  local t = {}
  for _, c in ipairs(list or {}) do t[#t + 1] = tostring(c.key or "?") end
  table.sort(t); return table.concat(t, ",")
end
-- find a live card across areas by POD id (preferred) or center key (shop/pack centres have no id).
local function find_card(areas, target)
  if not target then return nil end
  for _, area in ipairs(areas) do
    if area and area.cards then
      for _, c in ipairs(area.cards) do if target.id ~= nil and cid(c) == target.id then return c end end
    end
  end
  if target.key then
    for _, area in ipairs(areas) do
      if area and area.cards then for _, c in ipairs(area.cards) do if ckey(c) == target.key then return c end end end
    end
  end
  return nil
end

-- ---- REAL-button invocation (the crash fix) ---------------------------------
-- Traverse the live UI tree. Balatro nodes hold children in `.children` (keyed OR array) and the UIBox
-- root in `.UIRoot`; `.nodes` also appears in some defs. `visit(node)` returns true to stop.
local function ui_roots(G)
  local roots = {}
  pcall(function() if G.I and G.I.UIBOX then for _, ub in pairs(G.I.UIBOX) do roots[#roots + 1] = ub end end end)
  roots[#roots + 1] = G.HUD; roots[#roots + 1] = G.blind_select; roots[#roots + 1] = G.shop
  roots[#roots + 1] = G.OVERLAY_MENU
  return roots
end
local function deep_walk(G, visit)
  local seen = {}
  local function walk(node, depth)
    if type(node) ~= "table" or depth > 60 or seen[node] then return false end
    seen[node] = true
    if visit(node) then return true end
    if node.UIRoot and walk(node.UIRoot, depth + 1) then return true end
    local kids = node.children
    if type(kids) == "table" then for _, ch in pairs(kids) do if walk(ch, depth + 1) then return true end end end
    kids = node.nodes
    if type(kids) == "table" then for _, ch in pairs(kids) do if walk(ch, depth + 1) then return true end end end
    return false
  end
  for _, r in ipairs(ui_roots(G)) do if walk(r, 0) then return true end end
  return false
end

-- Find a live button node whose config.button == `name`. For a card action, `ref` is the target card
-- and we match the button's config.ref_table by KEY/ID (object identity is unreliable across wrappers).
local function ref_matches(cfg_ref, ref)
  if ref == nil then return true end
  if cfg_ref == nil then return false end
  if cfg_ref == ref then return true end
  if ref.key and ckey(cfg_ref) == ref.key then return true end
  if ref.id ~= nil and cid(cfg_ref) == ref.id then return true end
  return false
end
local function find_button(G, name, ref)
  local found
  deep_walk(G, function(node)
    local cfg = node.config
    if type(cfg) == "table" and cfg.button == name and ref_matches(cfg.ref_table, ref) then
      found = node; return true
    end
    return false
  end)
  return found
end

-- Collect the distinct config.button names present in the live UI tree — so a "not found" logs the REAL
-- names available. If `for_name` is given, also list the ref_table KEYS of buttons with that name (to
-- diagnose ref-matching failures — e.g. which cards' buy buttons exist).
local function list_buttons(G, for_name)
  local names, refs = {}, {}
  deep_walk(G, function(node)
    local cfg = node.config
    if type(cfg) == "table" and cfg.button then
      names[tostring(cfg.button)] = true
      if for_name and cfg.button == for_name then
        refs[tostring((cfg.ref_table and ckey(cfg.ref_table)) or (cfg.ref_table and cid(cfg.ref_table)) or "no-ref")] = true
      end
    end
    return false
  end)
  local out = {}; for k in pairs(names) do out[#out + 1] = k end; table.sort(out)
  local rout = {}; for k in pairs(refs) do rout[#rout + 1] = k end; table.sort(rout)
  return table.concat(out, ", "), table.concat(rout, ", ")
end
Autoplay.list_buttons = list_buttons

-- Click a real button by name (optionally for a specific ref card). Strict: if the button isn't found we
-- log + skip (never fabricate an event — that is what crashed). `nil_fallback` allows the highlight-based
-- play/discard FUNCs to be called with nil (they read G.hand.highlighted, not e) when no button is found.
local function click(G, name, logger, ref, nil_fallback)
  local node = find_button(G, name, ref)
  local fn = G.FUNCS and G.FUNCS[name]
  if type(fn) ~= "function" then log(logger, "MISSING G.FUNCS." .. name); return false end
  if not node then
    if nil_fallback then
      local ok, err = pcall(fn, nil)
      if not ok then log(logger, "G.FUNCS." .. name .. "(nil) error: " .. tostring(err)) end
      return ok
    end
    local names, refs = list_buttons(G, name)
    log(logger, "button not found: " .. name
      .. (ref and ("  | wanted ref key=" .. tostring(ref.key) .. " id=" .. tostring(ref.id)
        .. "; " .. name .. " ref-keys present: [" .. refs .. "]") or "")
      .. "  | all buttons: [" .. names .. "]")
    return false
  end
  local ok, err = pcall(fn, node)
  if not ok then log(logger, "G.FUNCS." .. name .. " error: " .. tostring(err)) end
  return ok
end

local function highlight(G, cards_pod)
  pcall(function() if G.hand.unhighlight_all then G.hand:unhighlight_all() end end)
  local want, n = {}, 0
  for _, pod in ipairs(cards_pod or {}) do if pod.id ~= nil then want[pod.id] = true end end
  for _, card in ipairs(G.hand.cards or {}) do
    if want[cid(card)] then pcall(function() G.hand:add_to_highlighted(card) end); n = n + 1 end
  end
  return n
end

-- ---- settled / channel / freshness (lag guards) -----------------------------
local function input_locked(G)
  local locked = false
  pcall(function()
    if G.CONTROLLER and G.CONTROLLER.locks then
      for _, v in pairs(G.CONTROLLER.locks) do if v then locked = true; break end end
    end
  end)
  return locked
end
local function channel(G)
  if G.pack_cards and G.pack_cards.cards and #G.pack_cards.cards > 0 then return "pack" end
  if not (G.STATE and G.STATES) then return nil end
  if G.STATE == G.STATES.SELECTING_HAND then return "hand" end
  if G.STATE == G.STATES.SHOP then return "shop" end
  if G.STATE == G.STATES.BLIND_SELECT then return "blind_select" end
  if G.STATE == G.STATES.ROUND_EVAL then return "cash_out" end
  return nil
end
local function type_ok(ch, t)
  if ch == "hand" then return t == "PLAY" or t == "DISCARD" or t == "USE_CONSUMABLE" end
  if ch == "shop" then return t == "SAVE" or t == "REROLL" or t == "USE_CONSUMABLE" or (t and (t:find("^BUY") or t:find("^SELL"))) end
  if ch == "pack" then return t == "PICK" or t == "SKIP" or t == "SKIP_PACK" end
  if ch == "blind_select" then return t == "CONTINUE" or t == "SKIP" or t == "PLAY" end
  return true
end
local function fresh(G, gs, ch)
  if not gs then return false end
  if ch == "hand" then return ids_of_area(G.hand) == ids_of_pod(gs.hand) end
  if ch == "pack" then return keys_of_area(G.pack_cards) == keys_of_pod((gs.pack or {}).items) end
  if ch == "shop" then
    local live_d = (G.GAME and G.GAME.dollars) or 0
    local pod_d = (gs.economy and gs.economy.dollars) or 0
    local live_n = (G.shop_jokers and G.shop_jokers.cards and #G.shop_jokers.cards or 0)
      + (G.shop_booster and G.shop_booster.cards and #G.shop_booster.cards or 0)
    local pod_n = #((gs.shop or {}).jokers or {}) + #((gs.shop or {}).consumables or {}) + #((gs.shop or {}).boosters or {})
    return live_d == pod_d and live_n == pod_n
  end
  return true
end
local function sig(G, ch)
  if ch == "hand" then
    local cr = (G.GAME and G.GAME.current_round) or {}
    return "hand:" .. ids_of_area(G.hand) .. "|h" .. tostring(cr.hands_left or 0) .. "|d" .. tostring(cr.discards_left or 0)
  elseif ch == "shop" then
    return "shop:" .. tostring((G.GAME and G.GAME.dollars) or 0) .. "|" .. ids_of_area(G.shop_jokers) .. "|" .. ids_of_area(G.shop_booster)
  elseif ch == "pack" then
    return "pack:" .. keys_of_area(G.pack_cards)
  elseif ch == "cash_out" then
    return "cash:" .. tostring((G.GAME and G.GAME.round) or 0)
  elseif ch == "blind_select" then
    return "blind:" .. tostring((G.GAME and G.GAME.round) or 0) .. tostring((G.GAME and G.GAME.blind_on_deck) or "")
  end
  return tostring(ch)
end

-- ---- executors (return true if an action was ISSUED) ------------------------
local function do_hand(G, best, logger)
  if best.type == "USE_CONSUMABLE" then
    local card = find_card({ G.consumeables }, best.target)
    if not card then log(logger, "USE: consumable not found"); return false end
    if best.cards and #best.cards > 0 then highlight(G, best.cards) end
    log(logger, "USE " .. tostring(ckey(card))); return click(G, "use_card", logger, best.target)
  end
  local n = highlight(G, best.cards)
  if n == 0 then log(logger, best.type .. ": no live card matched"); return false end
  log(logger, best.type .. " " .. n .. (n == 1 and " card" or " cards") .. " (" .. tostring(best.hand_type or "") .. ")")
  local fn = best.type == "PLAY" and "play_cards_from_highlighted" or "discard_cards_from_highlighted"
  return click(G, fn, logger)   -- strict: find the real button (no fabricated event -> no crash)
end
local function do_shop(G, best, logger)
  local t = best.type
  if t == "SAVE" then log(logger, "shop done -> leave"); return click(G, "toggle_shop", logger)
  elseif t == "REROLL" then log(logger, "reroll"); return click(G, "reroll_shop", logger)
  elseif t and t:find("^SELL") then
    local card = find_card({ G.jokers, G.consumeables }, best.target)
    if not card then log(logger, "SELL: card not found"); return false end
    log(logger, "sell " .. tostring(ckey(card))); return click(G, "sell_card", logger, best.target)
  elseif t == "USE_CONSUMABLE" then
    local card = find_card({ G.consumeables }, best.target)
    if not card then log(logger, "USE(shop): not found"); return false end
    log(logger, "use " .. tostring(ckey(card))); return click(G, "use_card", logger, best.target)
  elseif t and t:find("^BUY") then
    local card = find_card({ G.shop_jokers, G.shop_booster, G.shop_vouchers }, best.target)
    if not card then log(logger, t .. ": shop item not found (" .. tostring(best.target and (best.target.key or best.target.name)) .. ")"); return false end
    log(logger, "buy " .. tostring(ckey(card) or (best.target and best.target.name)))
    return click(G, "buy_from_shop", logger, best.target)
  end
  return false
end
local function do_pack(G, best, logger)
  if best == nil or best.type == "SKIP" or best.type == "SKIP_PACK" then
    log(logger, "skip pack"); return click(G, "skip_booster", logger)
  end
  local target = best.target or best
  local card = find_card({ G.pack_cards }, target)
  if not card then log(logger, "pack pick not found (" .. tostring(target.key or target.name) .. ")"); return false end
  if best.cards and #best.cards > 0 then highlight(G, best.cards) end
  log(logger, "pack pick " .. tostring(ckey(card) or target.key)); return click(G, "use_card", logger, target)
end
local function do_blind_select(G, best, logger)
  if best and best.type == "SKIP" then log(logger, "skip blind"); return click(G, "skip_blind", logger) end
  log(logger, "select/play blind"); return click(G, "select_blind", logger)
end

-- ---- main tick --------------------------------------------------------------
function Autoplay.tick(last, logger)
  if not Autoplay.enabled then return end
  local G = _G.G
  if not G then return end
  if now() < Autoplay.locked_until then return end
  if input_locked(G) then return end
  local ch = channel(G)
  if not ch then return end
  local s = sig(G, ch)
  if s == Autoplay.last_sig then return end

  if ch == "cash_out" then
    Autoplay.locked_until = now() + 1.0
    if click(G, "cash_out", logger) then Autoplay.last_sig = s end
    return
  end

  local best = last and last.ranked and last.ranked.best
  if not best then return end
  if not type_ok(ch, best.type) then return end
  if not fresh(G, last.gs, ch) then return end

  -- DECISION-STABILITY GATE: the engine's Monte-Carlo refine can CHANGE the recommendation a couple of
  -- seconds after the cheap pass, so acting instantly risks executing a decision it's about to revise.
  -- Require the (state + action) to hold UNCHANGED for STABLE_HOLD before committing. Resets on change.
  local act_id = s .. "|" .. tostring(best.type) .. "|"
    .. tostring(best.target and (best.target.key or best.target.name) or (best.cards and #best.cards) or "")
  if act_id ~= Autoplay.pending_id then
    Autoplay.pending_id = act_id; Autoplay.pending_since = now(); return   -- new/changed -> start the timer
  end
  if now() - (Autoplay.pending_since or 0) < Autoplay.STABLE_HOLD then return end   -- not stable yet

  Autoplay.locked_until = now() + 1.5
  local issued = false
  if ch == "hand" then issued = do_hand(G, best, logger)
  elseif ch == "shop" then issued = do_shop(G, best, logger)
  elseif ch == "pack" then issued = do_pack(G, best, logger)
  elseif ch == "blind_select" then issued = do_blind_select(G, best, logger) end
  -- Mark this decision done whether or not it issued: a repeated FAILED action (e.g. a not-yet-mapped
  -- button) must not spam the log every 1.5s. It re-attempts only once the state genuinely changes
  -- (new sig) — success advances the state, a wrong button name shows once and waits.
  Autoplay.last_sig = s
  Autoplay.pending_id = nil
end

return Autoplay
