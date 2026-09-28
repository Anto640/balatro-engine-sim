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
                   STABLE_HOLD = 0.6, pending_id = nil, pending_since = 0,
                   MAX_WAIT = 3.0, wait_sig = nil, wait_since = 0, PROVISIONAL_MAX = 20.0 }

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
  -- pairs (not ipairs) so a nil entry doesn't truncate the list
  for _, r in pairs({ G.HUD, G.blind_select, G.shop }) do roots[#roots + 1] = r end
  if type(G.STAGE_OBJECTS) == "table" then for _, r in pairs(G.STAGE_OBJECTS) do if type(r) == "table" then roots[#roots + 1] = r end end end
  pcall(function() for _, r in ipairs(roots) do walk(r, 0) end end)
  local list = {}; for k in pairs(found) do list[#list + 1] = k end; table.sort(list)
  flog("BUTTONS+FUNCS (visited " .. count .. ", " .. #roots .. " roots): [" .. table.concat(list, ", ") .. "]")
  flog("--- END UI DUMP ---")
end

-- AUTO-RESTART (F6, owner 2026-09-27): when a run ENDS (game over, or the win screen), start a new run by itself so
-- the self-player can play many runs unattended. It uses the game's OWN hold-R restart path (Controller key-hold
-- 'r': same deck and stake, a fresh seed unless the run was seeded), after RESTART_DELAY so the run's death/win is
-- recorded first. Off by default; every step is pcall'd and logged, so a failure can only stop the restart, never
-- crash the game.
Autoplay.auto_restart = false
Autoplay.RESTART_DELAY = 4.0
Autoplay.restarts = 0
function Autoplay.toggle_restart()
  Autoplay.auto_restart = not Autoplay.auto_restart
  flog("==== AUTO-RESTART " .. (Autoplay.auto_restart and "ON" or "OFF") .. " ====")
  return Autoplay.auto_restart
end
local function run_ended(G)
  if G.STATES and G.STATE == G.STATES.GAME_OVER then return "game over" end
  if G.GAME and G.GAME.won and G.OVERLAY_MENU then return "win" end
  return nil
end
local function restart_run(G)
  return pcall(function()
    if G.save_settings then G:save_settings() end
    G.SETTINGS.current_setup = "New Run"
    G.GAME.viewed_back = nil
    G.run_setup_seed = G.GAME.seeded
    G.challenge_tab = G.GAME and G.GAME.challenge and G.GAME.challenge_tab or nil
    G.forced_seed, G.setup_seed = nil, nil
    if G.GAME.seeded then G.forced_seed = G.GAME.pseudorandom.seed end
    G.forced_stake = G.GAME.stake
    if G.STAGE == G.STAGES.RUN then G.FUNCS.start_setup_run() end
    G.forced_stake = nil
    G.challenge_tab = nil
    G.forced_seed = nil
  end)
end
-- returns true when it handled (or is waiting on) an ended run this tick
local function maybe_restart(G)
  local why = run_ended(G)
  if not why then Autoplay._ended_since = nil; return false end
  if not Autoplay.auto_restart then return true end
  Autoplay._ended_since = Autoplay._ended_since or now()
  if now() - Autoplay._ended_since < Autoplay.RESTART_DELAY then return true end
  local ok, err = restart_run(G)
  Autoplay._ended_since = nil
  if ok then
    Autoplay.restarts = Autoplay.restarts + 1
    flog("auto-restart after " .. why .. " (#" .. Autoplay.restarts .. ")")
    Autoplay.last_sig, Autoplay.pending_id, Autoplay.wait_sig = nil, nil, nil
    Autoplay.locked_until = now() + 3.0
  else
    flog("auto-restart FAILED: " .. tostring(err) .. " -- turning auto-restart off")
    Autoplay.auto_restart = false
  end
  return true
end

-- ONE-SHOT AUTOSTART (for restarting the game remotely, e.g. to load a fix while the owner is away): if the file
-- `bes_autostart` exists in the save folder at launch, it is deleted, self-play + auto-restart turn ON, and from the
-- main menu the saved run is CONTINUED (or a new run starts if there is none). Without the file nothing changes.
Autoplay.AUTOSTART_FILE = "bes_autostart"
Autoplay.AUTOSTART_DELAY = 5.0
function Autoplay.check_autostart()
  local ok, info = pcall(function() return love.filesystem.getInfo(Autoplay.AUTOSTART_FILE) end)
  if not (ok and info) then return false end
  pcall(love.filesystem.remove, Autoplay.AUTOSTART_FILE)
  Autoplay.enabled, Autoplay.auto_restart, Autoplay._autostart = true, true, true
  flog("==== AUTOSTART: self-play + auto-restart ON; will continue the saved run from the menu ====")
  return true
end
-- returns true while it is handling the menu -> run step
local function maybe_autostart(G)
  if not Autoplay._autostart then return false end
  if not (G.STATES and G.STATE == G.STATES.MENU and G.MAIN_MENU_UI) then
    if G.STAGE == (G.STAGES and G.STAGES.RUN) then Autoplay._autostart = nil end   -- already in a run
    return false
  end
  Autoplay._menu_since = Autoplay._menu_since or now()
  if now() - Autoplay._menu_since < Autoplay.AUTOSTART_DELAY then return true end
  Autoplay._autostart, Autoplay._menu_since = nil, nil
  local ok, err = pcall(function()
    if not G.SAVED_GAME then
      local raw = get_compressed(G.SETTINGS.profile .. "/" .. "save.jkr")
      if raw ~= nil then G.SAVED_GAME = STR_UNPACK(raw) end
    end
    if G.SAVED_GAME ~= nil and not (G.SAVED_GAME.GAME and G.SAVED_GAME.GAME.won) then
      flog("autostart: continuing the saved run")
      G.FUNCS.start_run(nil, { savetext = G.SAVED_GAME })
    else
      flog("autostart: no saved run -- starting a new run")
      G.SETTINGS.current_setup = "New Run"
      G.FUNCS.start_run(nil, { stake = G.PROFILES[G.SETTINGS.profile].MEMORY.stake or 1 })
    end
  end)
  if not ok then flog("autostart FAILED: " .. tostring(err)) end
  Autoplay.locked_until = now() + 4.0
  return true
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
    -- key fallback. If the target named an exact card (id) that wasn't found, only fall back when the key
    -- is UNAMBIGUOUS: plain playing cards all share "c_base", so "first c_base" is a guess at a random card.
    local first, n = nil, 0
    for _, area in ipairs(areas) do
      if area and area.cards then
        for _, c in ipairs(area.cards) do if ckey(c) == target.key then n = n + 1; first = first or c end end
      end
    end
    if target.id == nil or n == 1 then return first end
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
  -- the in-blind Play/Discard buttons live under G.STAGE_OBJECTS (confirmed by the UI dump), not in
  -- G.I.UIBOX / HUD — include them so find_button reaches them.
  if type(G.STAGE_OBJECTS) == "table" then
    for _, r in pairs(G.STAGE_OBJECTS) do if type(r) == "table" then roots[#roots + 1] = r end end
  end
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
-- The stable ID wins when both sides have one: many cards share a center KEY (every plain playing card is
-- "c_base", every Bonus card "m_bonus"), so a key match can point at the wrong card (owner 2026-09-23: the
-- overlay said take the 3 of Spades from a Standard pack, the self-player took a Jack). Key is the fallback
-- for things with no id (shop boosters/vouchers).
local function ref_matches(cfg_ref, ref)
  if ref == nil then return true end
  if cfg_ref == nil then return false end
  if cfg_ref == ref then return true end
  local rid = cid(cfg_ref)
  if ref.id ~= nil and rid ~= nil then return rid == ref.id end
  if ref.key and ckey(cfg_ref) == ref.key then return true end
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
  -- a card the game keeps selected (Cerulean Bell's forced card) survives unhighlight_all; adding it AGAIN puts it
  -- in `highlighted` twice, so the 5-card limit rejects a real pick and the selection never matches (live 4125ZXCZ)
  local already = {}
  for _, c in ipairs(G.hand.highlighted or {}) do already[c] = true end
  for _, card in ipairs(G.hand.cards or {}) do
    if want[cid(card)] then
      if not already[card] then pcall(function() G.hand:add_to_highlighted(card) end) end
      n = n + 1
    end
  end
  return n
end
-- Are EXACTLY the wanted cards currently highlighted? (used to phase highlight -> click across frames)
local function wanted_ids(cards_pod)
  local s = {}; for _, p in ipairs(cards_pod or {}) do if p.id ~= nil then s[p.id] = true end end; return s
end
local function highlighted_matches(G, cards_pod)
  local want = wanted_ids(cards_pod)
  local have = {}
  if G.hand and G.hand.highlighted then for _, c in ipairs(G.hand.highlighted) do have[cid(c)] = true end end
  for k in pairs(want) do if not have[k] then return false end end
  for k in pairs(have) do if not want[k] then return false end end
  return next(want) ~= nil   -- must be non-empty and exactly equal
end
-- Are all the wanted cards highlighted (extras allowed)?
local function highlighted_contains(G, cards_pod)
  local want = wanted_ids(cards_pod)
  local have = {}
  if G.hand and G.hand.highlighted then for _, c in ipairs(G.hand.highlighted) do have[cid(c)] = true end end
  for k in pairs(want) do if not have[k] then return false end end
  return next(want) ~= nil
end
-- Reorder the live joker row to the engine's recommended order (best.reorder.joker_order). Jokers score
-- left->right, so order can be a big swing (a +mult LEFT of an xmult vs wasted RIGHT of it). There is no
-- reorder BUTTON in Balatro (it's drag-only), so we reorder G.jokers.cards directly (by id) and re-align.
-- Guarded: aborts unless every recommended joker maps to a live joker, and no-ops if already in order.
local function reorder_jokers(G, joker_order)
  if not (G.jokers and G.jokers.cards) or not joker_order or #joker_order < 2 then return false end
  local live = G.jokers.cards
  local byid = {}
  for _, c in ipairs(live) do byid[cid(c)] = c end
  local new = {}
  for _, pod in ipairs(joker_order) do local c = pod.id ~= nil and byid[pod.id]; if c then new[#new + 1] = c end end
  if #new ~= #live then return false end                 -- couldn't map all -> don't touch the row
  local same = true
  for i = 1, #live do if live[i] ~= new[i] then same = false; break end end
  if same then return false end
  for i = 1, #new do live[i] = new[i] end                -- reorder the scoring array
  pcall(function() if G.jokers.set_ranks then G.jokers:set_ranks() end end)
  pcall(function() if G.jokers.align_cards then G.jokers:align_cards() end end)
  return true
end

-- Reorder the PLAYED cards within the live hand to the engine's recommended order (best.reorder.card_order).
-- Balatro scores a play in SCREEN order: play_cards_from_highlighted sorts G.hand.highlighted by T.x, and
-- the hand's align_cards assigns T.x from the array index BEFORE its own T.x sort -- so rewriting
-- G.hand.cards then aligning sticks (same mechanism as reorder_jokers). Only the played cards move: they
-- are permuted among the hand slots they already occupy, every other card keeps its position (what a
-- human dragging them would do). Returns true only if the live order was actually changed.
local function reorder_cards(G, card_order)
  if not (G.hand and G.hand.cards) or not card_order or #card_order < 2 then return false end
  local live = G.hand.cards
  local want = {}
  for _, pod in ipairs(card_order) do if pod.id ~= nil then want[#want + 1] = pod.id end end
  if #want ~= #card_order then return false end
  local in_play = {}
  for _, id in ipairs(want) do in_play[id] = true end
  local slots, byid = {}, {}
  for i, c in ipairs(live) do
    local id = cid(c)
    if id ~= nil and in_play[id] then slots[#slots + 1] = i; byid[id] = c end
  end
  if #slots ~= #want then return false end               -- couldn't map every played card -> don't touch
  local same = true
  for k, i in ipairs(slots) do if cid(live[i]) ~= want[k] then same = false; break end end
  if same then return false end
  for k, i in ipairs(slots) do live[i] = byid[want[k]] end
  pcall(function() if G.hand.set_ranks then G.hand:set_ranks() end end)
  pcall(function() if G.hand.align_cards then G.hand:align_cards() end end)
  return true
end

-- Is the target inner pack card currently selected/highlighted in G.pack_cards?
local function pack_selected(G, target)
  if not (G.pack_cards and G.pack_cards.highlighted) then return false end
  for _, c in ipairs(G.pack_cards.highlighted) do
    if target.id ~= nil and cid(c) ~= nil then
      if cid(c) == target.id then return true end                  -- exact card (see ref_matches)
    elseif target.key and ckey(c) == target.key then return true end
  end
  return false
end

-- SHOP LOAD GATE (owner crash 2026-09-23: "game.lua:3294: attempt to index field 'shop' (a nil value)").
-- Entering the shop, Game:update_shop queues an event that waits for the shop panel to slide in
-- (|G.shop.T.y - G.shop.VT.y| < 3) and THEN stocks it. When the engine's first shop answer was SAVE, we
-- clicked "leave" ~1s in -- before that event ran -- which removed G.shop, and the pending event then
-- crashed on it. Earlier shops always bought something first, which accidentally gave it time to load.
-- So don't act in the shop until it has slid in AND been stocked, plus a short settle; latched per visit
-- (G.GAME.round) so buying the shop empty can't re-block it, with a time fallback so it can never stall.
Autoplay.SHOP_SETTLE = 0.5
Autoplay.SHOP_MAX_WAIT = 4.0
local function shop_ready(G)
  local visit = G.GAME and G.GAME.round
  if Autoplay._shop_ready_visit == visit then return true end
  if Autoplay._shop_seen_visit ~= visit then Autoplay._shop_seen_visit = visit; Autoplay._shop_seen_at = now() end
  local waited = now() - (Autoplay._shop_seen_at or now())
  local sh = G.shop
  local slid = sh and sh.T and sh.VT and math.abs((sh.T.y or 0) - (sh.VT.y or 0)) < 3
  local stocked = (G.shop_jokers and G.shop_jokers.cards and #G.shop_jokers.cards > 0)
    or (G.shop_booster and G.shop_booster.cards and #G.shop_booster.cards > 0)
  if (slid and stocked) or (sh and waited > Autoplay.SHOP_MAX_WAIT) then
    Autoplay._shop_ready_visit = visit
    Autoplay.locked_until = now() + Autoplay.SHOP_SETTLE   -- let the load event finish its remaining work
  end
  return false
end
Autoplay._shop_ready = shop_ready   -- exposed for tests

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
-- Is the game MID-ANIMATION -- the previous action still resolving, so the live state is a half-way frame, not a
-- decision? (owner 2026-09-28: after a discard the panel advised on the half-redrawn hand; after the last pack pick
-- it said "take this tarot" / "skip" for the ~0.5 s the pack took to close.) Read from the game source (Lovely dump):
--   * DRAW_TO_HAND / HAND_PLAYED / NEW_ROUND / PLAY_TAROT: a discard/play/deal/tarot is resolving
--     (SELECTING_HAND is only set once the draw events have finished);
--   * any CONTROLLER lock: use / selling_card / shop_reroll / skip_blind / toggle_shop ... are held while
--     their action animates;
--   * a pack screen whose panel is closing: G.FUNCS.use_card slides G.booster_pack off-screen (alignment.offset.py
--     set) while a pick resolves, and end_consumeable removes it before the leftover pack cards are cleared.
function Autoplay.in_transition(G)
  if not (G and G.STATES) then return false end
  local S, st = G.STATES, G.STATE
  if st ~= nil and (st == S.DRAW_TO_HAND or st == S.HAND_PLAYED or st == S.NEW_ROUND or st == S.PLAY_TAROT) then
    return true
  end
  if input_locked(G) then return true end
  local pack_state = st ~= nil and (st == S.TAROT_PACK or st == S.PLANET_PACK or st == S.SPECTRAL_PACK
    or st == S.STANDARD_PACK or st == S.BUFFOON_PACK or st == S.SMODS_BOOSTER_OPENED)
  if pack_state and G.pack_cards and G.pack_cards.cards and #G.pack_cards.cards > 0 then
    local bp = G.booster_pack
    local off = bp and bp.alignment and bp.alignment.offset
    if not bp or (off and off.py ~= nil) then return true end
  end
  return false
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
  -- SELL_JOKER in a hand: Verdant Leaf (ante 8) debuffs every card until a joker is sold
  if ch == "hand" then return t == "PLAY" or t == "DISCARD" or t == "USE_CONSUMABLE" or t == "SELL_JOKER" end
  if ch == "shop" then return t == "SAVE" or t == "REROLL" or t == "USE_CONSUMABLE" or (t and (t:find("^BUY") or t:find("^SELL"))) end
  -- SELL_JOKER is allowed in a pack: a joker pick into a FULL board needs room made first, and you
  -- CAN sell jokers while a booster is open (the make-room sell the engine now recommends as its own step).
  -- USE_CONSUMABLE in a pack: use a held planet to free a consumable slot for a card-making tarot pick
  if ch == "pack" then return t == "PICK" or t == "SKIP" or t == "SKIP_PACK" or t == "USE_CONSUMABLE" or (t and t:find("^SELL")) end
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
  -- include consumable + joker COUNTS so an in-place action that consumes one (use a held planet, sell a
  -- joker) changes the signature and the NEXT decision on the same hand/shop isn't blocked.
  local nc = (G.consumeables and G.consumeables.cards and #G.consumeables.cards) or 0
  local nj = (G.jokers and G.jokers.cards and #G.jokers.cards) or 0
  if ch == "hand" then
    local cr = (G.GAME and G.GAME.current_round) or {}
    return "hand:" .. ids_of_area(G.hand) .. "|h" .. tostring(cr.hands_left or 0) .. "|d" .. tostring(cr.discards_left or 0) .. "|c" .. nc .. "|j" .. nj
  elseif ch == "shop" then
    return "shop:" .. tostring((G.GAME and G.GAME.dollars) or 0) .. "|" .. ids_of_area(G.shop_jokers) .. "|" .. ids_of_area(G.shop_booster) .. "|c" .. nc .. "|j" .. nj
  elseif ch == "pack" then
    -- include the joker count so a MAKE-ROOM sell (board full -> sell a joker to take a pack joker)
    -- changes the signature and the follow-up PICK isn't blocked by last_sig on the unchanged pack cards.
    return "pack:" .. keys_of_area(G.pack_cards) .. "|j" .. nj
  elseif ch == "cash_out" then
    return "cash:" .. tostring((G.GAME and G.GAME.round) or 0)
  elseif ch == "blind_select" then
    return "blind:" .. tostring((G.GAME and G.GAME.round) or 0) .. tostring((G.GAME and G.GAME.blind_on_deck) or "")
  end
  return tostring(ch)
end

-- ---- executors (return true if an action was ISSUED) ------------------------
-- NOTE: cards are already highlighted by the tick's phase-1 (a frame earlier), so Balatro's
-- can_play/can_discard have registered the selection — these just click the button.
local function do_hand(G, best, logger)
  if best.type == "SELL_JOKER" then   -- Verdant Leaf: sell a joker to lift the card debuff
    local card = find_card({ G.jokers }, best.target)
    if not card then log(logger, "SELL(hand): joker not found"); return false end
    log(logger, "sell " .. tostring(ckey(card)) .. " (in blind)")
    return click(G, "sell_card", logger, best.target)
  end
  if best.type == "USE_CONSUMABLE" then
    log(logger, "USE " .. tostring(best.target and (best.target.key or best.target.name)))
    return click(G, "use_card", logger, best.target)
  end
  log(logger, best.type .. " " .. tostring(best.cards and #best.cards) .. " cards (" .. tostring(best.hand_type or "") .. ")")
  if best.reason then flog("  play-reason: " .. tostring(best.reason):gsub("%s+", " "):sub(1, 220)) end
  local fn = best.type == "PLAY" and "play_cards_from_highlighted" or "discard_cards_from_highlighted"
  return click(G, fn, logger)
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
    -- jokers/consumables/vouchers use the buy_from_shop button; booster PACKS use the use_card button
    -- (confirmed: btn:use_card=p_buffoon_normal_2 / p_celestial_normal_2), which buys AND opens the pack.
    if find_button(G, "buy_from_shop", best.target) then
      log(logger, "buy " .. tostring(ckey(card) or (best.target and best.target.name)))
      return click(G, "buy_from_shop", logger, best.target)
    end
    log(logger, "open pack " .. tostring(ckey(card) or (best.target and best.target.name)))
    return click(G, "use_card", logger, best.target)
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
  if maybe_restart(G) then return end
  if now() < Autoplay.locked_until then return end
  if maybe_autostart(G) then return end
  if Autoplay.in_transition(G) then return end   -- controller locks, a deal/play resolving, a pack closing
  local ch = channel(G)
  if not ch then return end
  if ch == "shop" and not shop_ready(G) then return end   -- wait for the shop to finish loading
  local s = sig(G, ch)
  if s == Autoplay.last_sig then return end
  -- how long we've been on THIS state without acting (drives the deadlock-breaker below)
  if s ~= Autoplay.wait_sig then Autoplay.wait_sig = s; Autoplay.wait_since = now() end

  -- Dump each screen type ONCE per session so booster/pack/cash-out mechanisms are captured automatically.
  Autoplay._dumped = Autoplay._dumped or {}
  if not Autoplay._dumped[ch] then Autoplay._dumped[ch] = true; pcall(Autoplay.dump_ui, G) end

  if ch == "cash_out" then
    Autoplay.locked_until = now() + 1.0
    -- do NOT set last_sig on failure — retrying until the cash-out button is clickable is what makes it
    -- work (it succeeded before this guard was added).
    if click(G, "cash_out", logger) then Autoplay.last_sig = s end
    return
  end

  local best = last and last.ranked and last.ranked.best
  if not best then return end
  if not type_ok(ch, best.type) then return end
  local isfresh = fresh(G, last.gs, ch)
  -- NON-TARGETED actions (leave shop / reroll / continue / skip a blind or pack) don't act on a
  -- specific card, so exact dollar/item parity between the decision snapshot and live G is irrelevant --
  -- being in the right STATE is enough. Requiring strict freshness here was a DEADLOCK: a persistent
  -- shop freshness false-negative (a no-joker shop where the $/item-count parity never re-synced) left
  -- SAVE blocked forever, and the deadlock-breaker below was unreachable behind the freshness `return`.
  local nontargeted = best.type == "SAVE" or best.type == "REROLL" or best.type == "CONTINUE"
    or best.type == "SKIP" or best.type == "SKIP_PACK"
  -- EXCEPT leaving/rerolling a SHOP: that decision is only right for the stock it was made on, and the first
  -- evaluation of a shop sees it EMPTY (the game stocks it a moment later) -- executing that "Bank $X" left shops
  -- the engine would have bought from (live LBUI8IK1). The deadlock above came from the same root: a stock that
  -- arrived without changing the overlay's signature never re-evaluated (core/signature now covers every offer).
  -- The MAX_WAIT breaker still rescues a genuine freshness false-negative.
  if nontargeted and not (ch == "shop" and (best.type == "SAVE" or best.type == "REROLL")) then isfresh = true end
  -- DEADLOCK-BREAKER, promoted ABOVE the freshness gate so it can rescue ANY freshness false-negative
  -- (targeted included): after MAX_WAIT stuck on the SAME state, proceed even if not fresh (a targeted
  -- action still resolves by stable id/key at execution, or logs "not found" -- never a wrong-card).
  local forced = (now() - (Autoplay.wait_since or now())) > Autoplay.MAX_WAIT
  -- diagnostic (once per state): what the engine wants + whether the decision matches the live state,
  -- so a stall is explainable from the log rather than guessed.
  if s ~= Autoplay._diag_sig then
    Autoplay._diag_sig = s
    flog("[tick] " .. ch .. " best=" .. tostring(best.type)
      .. " tgt=" .. tostring(best.target and (best.target.key or best.target.name))
      .. " fresh=" .. tostring(isfresh) .. (forced and " FORCED" or ""))
  end
  if not isfresh and not forced then return end
  -- NEVER execute a PROVISIONAL (priors-only) pack pick: wait for the measured refine. Not bypassed by `forced` --
  -- that clock can already be running from an earlier action on the same screen (live 978TLFTS: a failed skip
  -- click, then the cheap pass's flat-prior Hex was forced through and destroyed four jokers). Own safety valve:
  -- if no measured result arrives within PROVISIONAL_MAX of this pick appearing, act (a failed job can't stall).
  if last.provisional then
    if Autoplay._prov_sig ~= s then Autoplay._prov_sig = s; Autoplay._prov_since = now() end
    if (now() - (Autoplay._prov_since or now())) < Autoplay.PROVISIONAL_MAX then return end
  end

  -- DECISION-STABILITY GATE: the engine's Monte-Carlo refine can CHANGE the recommendation a couple of
  -- seconds after the cheap pass, so acting instantly risks executing a decision it's about to revise.
  -- Require the (state + action) to hold UNCHANGED for STABLE_HOLD before committing.
  -- DEADLOCK-BREAKER: if the top action flickers so the gate never settles, don't wait forever — after
  -- MAX_WAIT on the SAME state, act on the current best anyway (this was the "stuck on SAVE" stall).
  -- `forced` is computed above (promoted over the freshness gate) so both gates share the one clock.
  local act_id = s .. "|" .. tostring(best.type) .. "|"
    .. tostring(best.target and (best.target.key or best.target.name) or (best.cards and #best.cards) or "")
  if not forced then
    if act_id ~= Autoplay.pending_id then
      Autoplay.pending_id = act_id; Autoplay.pending_since = now(); return   -- new/changed -> start the timer
    end
    if now() - (Autoplay.pending_since or 0) < Autoplay.STABLE_HOLD then return end   -- not stable yet
  end

  -- PHASE 0 — JOKER REORDER. The engine attaches the optimal joker order to a PLAY (best.reorder); apply
  -- it BEFORE selecting/playing so the hand scores what the engine intends (order is a real score swing).
  if ch == "hand" and best.type == "PLAY" and best.reorder and best.reorder.joker_changed then
    if reorder_jokers(G, best.reorder.joker_order) then
      log(logger, "reorder jokers (+" .. tostring(math.floor((best.reorder.gain or 0))) .. " score)")
      Autoplay.locked_until = now() + 0.4
      return                                  -- re-enter next pass to select + play in the new order
    end
  end
  -- PHASE 0b — CARD REORDER. Played cards score left->right in hand position (Hanging Chad retriggers the
  -- FIRST card, Photograph the first face, Glass ×2 wants the additive cards before it), and the chooser
  -- picked this play at its best card order (R7) -- playing it as dealt forfeits that score (the owner's
  -- Greedy+Chad Two Pair: 340 dealt vs 748 reordered). Apply it before select+play. Capped per state so a
  -- reorder that somehow doesn't stick can never spin the loop -- it then plays in the live order.
  if ch == "hand" and best.type == "PLAY" and best.reorder and best.reorder.card_changed then
    if Autoplay._card_reorder_sig ~= s then Autoplay._card_reorder_sig = s; Autoplay._card_reorder_n = 0 end
    if Autoplay._card_reorder_n < 2 and reorder_cards(G, best.reorder.card_order) then
      Autoplay._card_reorder_n = Autoplay._card_reorder_n + 1
      local o = best.reorder
      log(logger, "reorder cards"
        .. (o.objective == "money" and (" (+$" .. tostring(o.money_gain or 0) .. ")")
            or (" (+" .. tostring(math.floor(o.gain or 0)) .. " score)")))
      Autoplay.locked_until = now() + 0.4
      return                                  -- re-enter next pass to select + play in the new order
    end
  end

  -- PHASE 1 — SELECT THEN ACT ON SEPARATE FRAMES. Clicking Play/Discard/Use in the SAME frame the cards
  -- are highlighted fails, because Balatro's can_play/can_discard haven't registered the selection yet
  -- (that was the "highlights but won't play until F11 twice" bug). If a card action's target cards are
  -- not yet EXACTLY highlighted, highlight them, brief lockout, and return — the click happens next pass.
  local target_cards
  if ch == "hand" and (best.type == "PLAY" or best.type == "DISCARD") then target_cards = best.cards
  elseif (best.type == "USE_CONSUMABLE" or best.type == "PICK") and best.cards and #best.cards > 0 then target_cards = best.cards end
  -- A card the GAME holds selected (Cerulean Bell's forced card) can't be unhighlighted, so an exact match may be
  -- impossible; the engine now includes it, but if a selection still never matches, don't re-select forever
  -- (live 4125ZXCZ looped ~4 hours at the ante-8 Bell): after MAX_WAIT accept a selection that CONTAINS every wanted card.
  local sel_ok = target_cards and (highlighted_matches(G, target_cards)
    or (forced and highlighted_contains(G, target_cards)))
  if target_cards and not sel_ok then
    local n = highlight(G, target_cards)
    log(logger, "select " .. n .. " card" .. (n == 1 and "" or "s") .. " (" .. tostring(best.hand_type or best.type) .. ")")
    Autoplay.locked_until = now() + 0.4    -- let the selection register before we click next pass
    return                                  -- do NOT set last_sig: re-enter next tick to click
  end

  -- PACK PICK is also two-phase, but the inner card lives in G.pack_cards and has NO use_card button
  -- until it is SELECTED: phase 1 clicks the inner card to select it (its use_card button then appears),
  -- phase 2 clicks that button. (Confirmed: an open Buffoon pack showed no use_card for the inner joker.)
  if ch == "pack" and best.type == "PICK" then
    local target = best.target or best
    local card = find_card({ G.pack_cards }, target)
    if not card then log(logger, "pack pick not found (" .. tostring(target.key or target.name) .. ")"); Autoplay.last_sig = s; return end
    if not pack_selected(G, target) then
      log(logger, "select pack card " .. tostring(ckey(card) or target.key))
      pcall(function() card:click() end)                     -- select the inner card
      Autoplay.locked_until = now() + 0.7                     -- let the use_card button appear
      return                                                  -- confirm next pass
    end
    -- a card-tarot from the pack (Magician, Strength, ...) enhances SELECTED hand cards — its use button
    -- won't appear until the target cards are highlighted. Select them first (from best.target_cards).
    local tgt = best.target_cards
    if tgt and #tgt > 0 and not highlighted_matches(G, tgt) then
      local n = highlight(G, tgt)
      log(logger, "target " .. n .. " hand card(s) for " .. tostring(target.key))
      Autoplay.locked_until = now() + 0.5
      return
    end
    log(logger, "confirm pack pick " .. tostring(ckey(card) or target.key))
    Autoplay.locked_until = now() + 1.0
    if click(G, "use_card", logger, target) then Autoplay.last_sig = s; Autoplay.pending_id = nil
    elseif (now() - (Autoplay.wait_since or now())) > 6.0 then
      -- genuinely stuck on this pick after several seconds of retries -> skip the pack so the run
      -- continues (e.g. a card-tarot whose targets we couldn't provide).
      log(logger, "pick unusable after retries -> skip pack"); click(G, "skip_booster", logger); Autoplay.last_sig = s
    end
    -- else: the use button just isn't ready yet (appears a moment after selecting) -> retry next pass
    return
  end

  -- SELL (owned joker/consumable) is two-phase: there is NO persistent sell button — you SELECT the
  -- owned card (click it, its sell_card button then appears), then click sell. Also fires in the PACK
  -- channel for a MAKE-ROOM sell (board full, engine wants a joker from the pack): you can sell jokers
  -- while a booster is open. If the make-room sell can't actuate (a blind-select tag pack where the
  -- joker row isn't sellable), fall back to skipping the pack so the run never stalls.
  if (ch == "shop" or ch == "pack") and best.type and best.type:find("^SELL") then
    local card = find_card({ G.jokers, G.consumeables }, best.target)
    if not card then
      -- already sold (slot now free) or not found: in a pack, re-enter so the pick surfaces; in the
      -- shop just mark done. Don't spin.
      log(logger, "SELL: owned card not found (" .. tostring(best.target and best.target.key) .. ")")
      Autoplay.last_sig = s; return
    end
    if not card.highlighted then
      log(logger, "select to sell " .. tostring(ckey(card))
        .. (best.make_room_for and ("  | make room for " .. tostring(best.make_room_for)) or "")
        .. (best.reason and ("  | ENGINE REASON: " .. tostring(best.reason):sub(1, 160)) or ""))
      pcall(function() card:click() end)
      if not Autoplay._dumped_sell then Autoplay._dumped_sell = true; flog("(post-sell-select dump)"); pcall(Autoplay.dump_ui, G) end
      Autoplay.locked_until = now() + 0.4
      return
    end
    log(logger, "confirm sell " .. tostring(ckey(card)))
    Autoplay.locked_until = now() + 1.5
    if click(G, "sell_card", logger, best.target) then Autoplay.last_sig = s; Autoplay.pending_id = nil
    elseif ch == "pack" and (now() - (Autoplay.wait_since or now())) > 6.0 then
      -- can't make room in this pack context after retries -> skip so the run continues.
      log(logger, "make-room sell unusable in pack after retries -> skip pack")
      click(G, "skip_booster", logger); Autoplay.last_sig = s
    end
    return
  end

  -- USE_CONSUMABLE (held planet/tarot/spectral): SELECT the consumable in the consumables area (its
  -- use_card button then appears), then use it — two-phase. `use_keys` lists the consumable(s) to use in
  -- order; each is consumed in turn (the sig includes the consumable count, so the next one/the play is
  -- not blocked). A card-tarot ALSO needs its TARGET hand cards highlighted first (tarot targeting).
  if best.type == "USE_CONSUMABLE" then
    -- (a) tarot targeting: if the engine named target hand cards, highlight them before using the tarot.
    local tgt = best.target_cards or best.cards
    if tgt and #tgt > 0 and not highlighted_matches(G, tgt) then
      local n = highlight(G, tgt)
      log(logger, "target " .. n .. " card(s) for " .. tostring(best.target and best.target.name))
      Autoplay.locked_until = now() + 0.4
      return
    end
    -- (b) select then use the next held consumable named by use_keys (fallback: target.key/name).
    local keys = best.use_keys
    if not keys or #keys == 0 then keys = { best.target and (best.target.key or best.target.name) } end
    local card, kk
    for _, k in ipairs(keys) do
      local c = k and find_card({ G.consumeables }, { key = k })
      if not c and k and G.consumeables and G.consumeables.cards then   -- fallback: match by display name
        for _, cc in ipairs(G.consumeables.cards) do if cc.ability and cc.ability.name == k then c = cc; break end end
      end
      if c then card, kk = c, k; break end
    end
    if not card then Autoplay.last_sig = s; return end       -- all used / none found -> done
    if not card.highlighted then
      log(logger, "select consumable " .. tostring(ckey(card) or kk))
      pcall(function() card:click() end)
      Autoplay.locked_until = now() + 0.4
      return                                                  -- confirm next pass (no last_sig)
    end
    log(logger, "use consumable " .. tostring(ckey(card) or kk))
    Autoplay.locked_until = now() + 1.2
    click(G, "use_card", logger, { key = ckey(card), id = cid(card) })
    -- if it worked the consumable is gone -> sig changes -> we re-enter (next consumable / the play);
    -- if it failed the sig is unchanged -> last_sig stops it (no loop).
    Autoplay.last_sig = s; Autoplay.pending_id = nil
    return
  end

  -- log the engine's reason for a BUY so a churn (buy-then-sell) is diagnosable from the log.
  if ch == "shop" and best.type and best.type:find("^BUY") and best.reason then
    flog("  ENGINE REASON: " .. tostring(best.reason):sub(1, 160))
  end

  Autoplay.locked_until = now() + 1.5
  local issued = false
  if ch == "hand" then issued = do_hand(G, best, logger)
  elseif ch == "shop" then issued = do_shop(G, best, logger)
  elseif ch == "pack" then issued = do_pack(G, best, logger)
  elseif ch == "blind_select" then issued = do_blind_select(G, best, logger) end
  -- Burn last_sig only when the action ISSUED, or after MAX_WAIT stuck on the SAME state. A button
  -- sometimes appears a BEAT after the state settles -- e.g. a booster's `skip_booster` renders only
  -- after the pack open-animation finishes -- so the first attempt legitimately fails. Marking the
  -- decision done on that first failure set last_sig, and the state-gate at the top of tick() then
  -- blocked EVERY retry, stalling the run until an F11 reset (owner 2026-09-22: stuck skipping a
  -- standard pack). Now a transient miss is retried (every locked_until ~1.5s) until it renders, while
  -- the MAX_WAIT deadlock-breaker still stops a genuinely-missing button from retrying forever.
  if issued or (now() - (Autoplay.wait_since or now())) > Autoplay.MAX_WAIT then
    Autoplay.last_sig = s
    Autoplay.pending_id = nil
  end
end

return Autoplay
