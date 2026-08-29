-- ui/autoplay.lua
-- AUTO-PLAY ACTUATOR (2026-08-29) — translate the engine's recommendation into REAL game inputs so the
-- engine plays the ACTUAL Balatro game (real RNG + mechanics, no sim-fidelity gap) — a run to WATCH and
-- ANALYSE, a far better testbed than the headless sim. Reads live `G` and calls `G.FUNCS.*`, so unlike
-- the pure engine it is NOT headless; it lives in ui/ beside hud_inject. Toggle: F11 (default OFF).
--
-- ALL CHANNELS (this pass): blind select · in-blind PLAY/DISCARD/use · shop buy/sell/use/reroll/leave ·
-- pack pick/skip · cash-out navigation. Each action drives the game state machine forward, so with F11
-- on it plays whole runs unattended.
--
-- ROBUSTNESS (the two things that break naive automation):
--  * LAG / staleness — the engine re-evaluates on a 0.25s tick and its MC refine runs in the background.
--    We NEVER act on a decision computed for a previous state: a FRESHNESS gate requires (a) the
--    recommendation TYPE to match the current game STATE, and (b) the live state to match the state the
--    decision was computed on (`BES.last.gs`) — hand ids for a blind, $ + shop-item ids for a shop, pack
--    ids for a pack. After every action a LOCKOUT holds until the animation finishes and the engine
--    re-evaluates, so the next action is always fresh.
--  * CARD POSITIONS — cards re-sort and animate, so we match ONLY by stable id (sort_id/unique_val) or
--    center key, read from LIVE `G` at execution time; positions/indices are never used.
--
-- Every game call is pcall'd with a labelled log, so a wrong FUNC degrades to "did nothing" + a report,
-- never a crash. Defaults OFF; nothing happens until F11.

local Autoplay = { enabled = false, locked_until = 0, last_sig = nil }

local function now() return (love and love.timer and love.timer.getTime()) or 0 end
local function log(logger, msg) if logger then logger("[autoplay] " .. msg) end end

function Autoplay.toggle()
  Autoplay.enabled = not Autoplay.enabled
  Autoplay.locked_until = now() + 1.0
  Autoplay.last_sig = nil
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
-- pack items have NO stable id (state_extraction reads only set/key/name), so packs are matched by
-- CENTER KEY instead.
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
-- find a live card across one or more areas by POD id (preferred) or center key (shop centres have no id)
local function find_card(areas, target)
  if not target then return nil end
  for _, area in ipairs(areas) do
    if area and area.cards then
      for _, c in ipairs(area.cards) do
        if target.id ~= nil and cid(c) == target.id then return c end
      end
    end
  end
  local want = target.key or (type(target) == "table" and target.key)
  if want then
    for _, area in ipairs(areas) do
      if area and area.cards then
        for _, c in ipairs(area.cards) do if ckey(c) == want then return c end end
      end
    end
  end
  return nil
end

-- ---- game-call wrappers (defensive; log the FUNC name so failures are reportable) -----------
local function fe(ref) return { config = { ref_table = ref } } end   -- Balatro FUNCs read e.config.ref_table
local function call(G, name, e, logger)
  local fn = G.FUNCS and G.FUNCS[name]
  if type(fn) ~= "function" then log(logger, "MISSING G.FUNCS." .. name); return false end
  local ok, err = pcall(fn, e or { config = {} })
  if not ok then log(logger, "G.FUNCS." .. name .. " error: " .. tostring(err)) end
  return ok
end

local function highlight(G, cards_pod, logger)
  pcall(function() if G.hand.unhighlight_all then G.hand:unhighlight_all() end end)
  local want, n = {}, 0
  for _, pod in ipairs(cards_pod or {}) do if pod.id ~= nil then want[pod.id] = true end end
  for _, card in ipairs(G.hand.cards or {}) do
    if want[cid(card)] then pcall(function() G.hand:add_to_highlighted(card) end); n = n + 1 end
  end
  return n
end

-- ---- settled / freshness ----------------------------------------------------
local function input_locked(G)
  local locked = false
  pcall(function()
    if G.CONTROLLER and G.CONTROLLER.locks then
      for _, v in pairs(G.CONTROLLER.locks) do if v then locked = true; break end end
    end
  end)
  return locked
end

-- Which decision channel is the game currently in? (pack overrides state — a pack can open over shop.)
local function channel(G)
  if G.pack_cards and G.pack_cards.cards and #G.pack_cards.cards > 0 then return "pack" end
  if not (G.STATE and G.STATES) then return nil end
  if G.STATE == G.STATES.SELECTING_HAND then return "hand" end
  if G.STATE == G.STATES.SHOP then return "shop" end
  if G.STATE == G.STATES.BLIND_SELECT then return "blind_select" end
  if G.STATE == G.STATES.ROUND_EVAL then return "cash_out" end
  return nil
end

-- Does the engine's recommendation TYPE belong to this channel? (stale-decision guard #1)
local function type_ok(ch, t)
  if ch == "hand" then return t == "PLAY" or t == "DISCARD" or t == "USE_CONSUMABLE" end
  if ch == "shop" then return t == "SAVE" or t == "REROLL" or t == "USE_CONSUMABLE"
    or (t and (t:find("^BUY") or t:find("^SELL"))) end
  if ch == "pack" then return t == "PICK" or t == "SKIP" or t == "SKIP_PACK" end
  if ch == "blind_select" then return t == "CONTINUE" or t == "SKIP" or t == "PLAY" end
  return true
end

-- Was the decision computed on the CURRENT live state? (stale-decision guard #2 — lag protection)
local function fresh(G, gs, ch)
  if not gs then return false end
  if ch == "hand" then return ids_of_area(G.hand) == ids_of_pod(gs.hand) end
  if ch == "pack" then return keys_of_area(G.pack_cards) == keys_of_pod((gs.pack or {}).items) end
  if ch == "shop" then
    local live_d = (G.GAME and G.GAME.dollars) or 0
    local pod_d = (gs.economy and gs.economy.dollars) or 0
    local live_n = (G.shop_jokers and G.shop_jokers.cards and #G.shop_jokers.cards or 0)
      + (G.shop_booster and G.shop_booster.cards and #G.shop_booster.cards or 0)
    local pod_n = #((gs.shop or {}).jokers or {}) + #((gs.shop or {}).consumables or {})
      + #((gs.shop or {}).boosters or {})
    return live_d == pod_d and live_n == pod_n
  end
  return true   -- cash_out / blind_select: no fine state to match
end

-- A signature so we act at most once per distinct decision (re-acting only once the state advances).
local function sig(G, ch)
  if ch == "hand" then
    local cr = (G.GAME and G.GAME.current_round) or {}
    return "hand:" .. ids_of_area(G.hand) .. "|h" .. tostring(cr.hands_left or 0) .. "|d" .. tostring(cr.discards_left or 0)
  elseif ch == "shop" then
    return "shop:" .. tostring((G.GAME and G.GAME.dollars) or 0) .. "|" .. ids_of_area(G.shop_jokers) .. "|" .. ids_of_area(G.shop_booster)
  elseif ch == "pack" then
    return "pack:" .. keys_of_area(G.pack_cards) .. "|" .. tostring((G.pack_cards and G.pack_cards.config and G.pack_cards.config.card_limit) or "")
  elseif ch == "cash_out" then
    return "cash:" .. tostring((G.GAME and G.GAME.round) or 0)
  elseif ch == "blind_select" then
    return "blind:" .. tostring((G.GAME and G.GAME.round) or 0) .. tostring((G.GAME and G.GAME.blind_on_deck) or "")
  end
  return tostring(ch)
end

-- ---- per-channel executors --------------------------------------------------
-- Return true if an action was ISSUED (so we lock out); false = nothing to do.
local function do_hand(G, best, logger)
  if best.type == "USE_CONSUMABLE" then
    local card = find_card({ G.consumeables }, best.target)
    if not card then log(logger, "USE: consumable not found"); return false end
    if best.cards and #best.cards > 0 then highlight(G, best.cards, logger) end
    log(logger, "USE " .. tostring(ckey(card)))
    return call(G, "use_card", fe(card), logger)
  end
  local n = highlight(G, best.cards, logger)
  if n == 0 then log(logger, best.type .. ": no live card matched"); return false end
  log(logger, best.type .. " " .. n .. (n == 1 and " card" or " cards") .. " (" .. tostring(best.hand_type or "") .. ")")
  return call(G, best.type == "PLAY" and "play_cards_from_highlighted" or "discard_cards_from_highlighted", nil, logger)
end

local function do_shop(G, best, logger)
  local t = best.type
  if t == "SAVE" then
    log(logger, "shop done -> leave"); return call(G, "toggle_shop", nil, logger)   -- leave shop / next round
  elseif t == "REROLL" then
    log(logger, "reroll shop"); return call(G, "reroll_shop", nil, logger)
  elseif t and t:find("^SELL") then
    local card = find_card({ G.jokers, G.consumeables }, best.target)
    if not card then log(logger, "SELL: card not found"); return false end
    log(logger, "sell " .. tostring(ckey(card))); return call(G, "sell_card", fe(card), logger)
  elseif t == "USE_CONSUMABLE" then
    local card = find_card({ G.consumeables }, best.target)
    if not card then log(logger, "USE(shop): consumable not found"); return false end
    log(logger, "use " .. tostring(ckey(card))); return call(G, "use_card", fe(card), logger)
  elseif t and t:find("^BUY") then
    local card = find_card({ G.shop_jokers, G.shop_booster, G.shop_vouchers }, best.target)
    if not card then log(logger, t .. ": shop item not found (" .. tostring(best.target and (best.target.key or best.target.name)) .. ")"); return false end
    log(logger, "buy " .. tostring(ckey(card) or (best.target and best.target.name)))
    return call(G, "buy_from_shop", fe(card), logger)
  end
  return false
end

local function do_pack(G, best, logger)
  -- pack recommendation (apply_pack): type "PICK" with target {key,name,id} or type "SKIP".
  if best == nil or best.type == "SKIP" or best.type == "SKIP_PACK" then
    log(logger, "skip pack"); return call(G, "skip_booster", nil, logger)
  end
  local target = best.target or best   -- pack best can be the item itself {key,...}
  local card = find_card({ G.pack_cards }, target)
  if not card then log(logger, "pack pick not found (" .. tostring(target.key or target.name) .. ")"); return false end
  -- a card-tarot picked from a pack may target hand cards
  if best.cards and #best.cards > 0 then highlight(G, best.cards, logger) end
  log(logger, "pack pick " .. tostring(ckey(card) or target.key))
  return call(G, "use_card", fe(card), logger)
end

local function do_blind_select(G, best, logger)
  if best and best.type == "SKIP" then
    log(logger, "skip blind"); return call(G, "skip_blind", nil, logger)
  end
  log(logger, "select/play blind"); return call(G, "select_blind", nil, logger)
end

-- ---- main tick --------------------------------------------------------------
-- Called every love.update tick with the latest BES.last. No-op unless enabled + settled + fresh.
function Autoplay.tick(last, logger)
  if not Autoplay.enabled then return end
  local G = _G.G
  if not G then return end
  if now() < Autoplay.locked_until then return end
  if input_locked(G) then return end
  local ch = channel(G)
  if not ch then return end

  local s = sig(G, ch)
  if s == Autoplay.last_sig then return end          -- already acted on this exact decision

  -- cash-out is pure navigation (no engine decision): click through it.
  if ch == "cash_out" then
    Autoplay.locked_until = now() + 1.0
    if call(G, "cash_out", nil, logger) then Autoplay.last_sig = s; log(logger, "cash out") end
    return
  end

  local best = last and last.ranked and last.ranked.best
  if not best then return end
  if not type_ok(ch, best.type) then return end      -- stale-decision guard #1 (type vs state)
  if not fresh(G, last.gs, ch) then return end        -- stale-decision guard #2 (decision vs live state)

  Autoplay.locked_until = now() + 1.5                 -- cover the action's animation + a re-eval
  local issued = false
  if ch == "hand" then issued = do_hand(G, best, logger)
  elseif ch == "shop" then issued = do_shop(G, best, logger)
  elseif ch == "pack" then issued = do_pack(G, best, logger)
  elseif ch == "blind_select" then issued = do_blind_select(G, best, logger) end
  if issued then Autoplay.last_sig = s end            -- only mark done on a successful issue (fails retry)
end

return Autoplay
