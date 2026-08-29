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

local Autoplay = { enabled = false, locked_until = 0, last_sig = nil }

local function now() return (love and love.timer and love.timer.getTime()) or 0 end
local function flog(msg)
  pcall(function()
    if love and love.filesystem then love.filesystem.append("bes_autoplay.log", os.date("%H:%M:%S ") .. msg .. "\n") end
  end)
end
local function log(logger, msg) if logger then logger("[autoplay] " .. msg) end flog(msg) end
Autoplay.flog = flog

function Autoplay.toggle()
  Autoplay.enabled = not Autoplay.enabled
  Autoplay.locked_until = now() + 1.0
  Autoplay.last_sig = nil
  flog("==== AUTO-PLAY " .. (Autoplay.enabled and "ON" or "OFF") .. " ====")
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
-- Recursively find a live UI node whose config.button == `name` (and, if `ref` given, whose
-- config.ref_table == ref — the specific card's button). Returns the node (which HAS .UIBox + .config).
local function find_button(G, name, ref)
  local found
  local seen = {}
  local function walk(node, depth)
    if found or type(node) ~= "table" or depth > 80 or seen[node] then return end
    seen[node] = true
    local cfg = node.config
    if type(cfg) == "table" and cfg.button == name then
      if (ref == nil) or (cfg.ref_table == ref) then found = node; return end
    end
    local kids = node.nodes
    if type(kids) == "table" then for _, ch in ipairs(kids) do walk(ch, depth + 1) end end
    if node.UIRoot then walk(node.UIRoot, depth + 1) end
  end
  pcall(function()
    local roots = {}
    if G.I and G.I.UIBOX then for _, ub in pairs(G.I.UIBOX) do roots[#roots + 1] = ub end end
    roots[#roots + 1] = G.OVERLAY_MENU; roots[#roots + 1] = G.HUD
    roots[#roots + 1] = G.blind_select; roots[#roots + 1] = G.shop; roots[#roots + 1] = G.buttons
    for _, r in ipairs(roots) do walk(r, 0); if found then break end end
  end)
  return found
end

-- Collect the distinct config.button names present in the live UI tree — so a "not found" logs the REAL
-- names available and we learn the correct one in a single run.
local function list_buttons(G)
  local names, seen = {}, {}
  local function walk(node, depth)
    if type(node) ~= "table" or depth > 80 or seen[node] then return end
    seen[node] = true
    local cfg = node.config
    if type(cfg) == "table" and cfg.button then names[tostring(cfg.button)] = true end
    if type(node.nodes) == "table" then for _, ch in ipairs(node.nodes) do walk(ch, depth + 1) end end
    if node.UIRoot then walk(node.UIRoot, depth + 1) end
  end
  pcall(function()
    local roots = {}
    if G.I and G.I.UIBOX then for _, ub in pairs(G.I.UIBOX) do roots[#roots + 1] = ub end end
    roots[#roots + 1] = G.OVERLAY_MENU; roots[#roots + 1] = G.HUD
    roots[#roots + 1] = G.blind_select; roots[#roots + 1] = G.shop; roots[#roots + 1] = G.buttons
    for _, r in ipairs(roots) do walk(r, 0) end
  end)
  local out = {}
  for k in pairs(names) do out[#out + 1] = k end
  table.sort(out); return table.concat(out, ", ")
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
    log(logger, "button not found: " .. name .. (ref and " (for target card)" or "")
      .. "  | available buttons: [" .. list_buttons(G) .. "]")
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
    log(logger, "USE " .. tostring(ckey(card))); return click(G, "use_card", logger, card)
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
    log(logger, "sell " .. tostring(ckey(card))); return click(G, "sell_card", logger, card)
  elseif t == "USE_CONSUMABLE" then
    local card = find_card({ G.consumeables }, best.target)
    if not card then log(logger, "USE(shop): not found"); return false end
    log(logger, "use " .. tostring(ckey(card))); return click(G, "use_card", logger, card)
  elseif t and t:find("^BUY") then
    local card = find_card({ G.shop_jokers, G.shop_booster, G.shop_vouchers }, best.target)
    if not card then log(logger, t .. ": shop item not found (" .. tostring(best.target and (best.target.key or best.target.name)) .. ")"); return false end
    log(logger, "buy " .. tostring(ckey(card) or (best.target and best.target.name)))
    return click(G, "buy_from_shop", logger, card)
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
  log(logger, "pack pick " .. tostring(ckey(card) or target.key)); return click(G, "use_card", logger, card)
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

  Autoplay.locked_until = now() + 1.5
  local issued = false
  if ch == "hand" then issued = do_hand(G, best, logger)
  elseif ch == "shop" then issued = do_shop(G, best, logger)
  elseif ch == "pack" then issued = do_pack(G, best, logger)
  elseif ch == "blind_select" then issued = do_blind_select(G, best, logger) end
  if issued then Autoplay.last_sig = s end
end

return Autoplay
