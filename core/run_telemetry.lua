-- core/run_telemetry.lua
-- Phase 0 of SELFPLAY_PLAN.md: instrument REAL runs so we can confirm (with
-- numbers) the hypothesis that the engine dies around ante 3 because it falls
-- BEHIND ON PACE, not because it misplays winnable blinds.
--
-- This is a PURE state machine over light "frames" (one per BES.tick snapshot).
-- It owns no game objects: the caller (main.lua) derives a frame from the POD
-- GameState via Telemetry.frame_of(gs) and feeds it in. The module detects run
-- boundaries (start / new ante / death / win) and emits flat records the caller
-- persists as JSONL. Heavy metrics (pace, run-strength) are computed lazily by an
-- injected `enrich(ctx)` callback, invoked ONLY at boundaries (a few times a run),
-- so per-tick cost stays ~zero. No G, no love -> fully headless-testable.
--
-- Record kinds (one JSON object per line):
--   run_start { kind, seed, t, ante, dollars }
--   ante      { kind, seed, t, ante, dollars, njokers, jokers[], hand_level_sum,
--               consumables, metrics? }            -- emitted when a new ante begins
--   death     { kind, seed, t, ante, blind_type, boss, target, scored, ratio,
--               dollars, njokers, jokers[], hand_level_sum, metrics? }
--   win       { kind, seed, t, ante, dollars, njokers, jokers[] }  -- cleared ante 8

local Json = require("util.json")
local Cards = require("util.cards")

local Telemetry = {}
Telemetry.__index = Telemetry

-- compact per-hand card list {id,label} so a PLAY/DISCARD can be reconstructed by diffing the hand
-- across frames (cards present before but gone after = the ones played/discarded). 2026-08-26.
local function hand_cards(gs)
  local out = {}
  for _, c in ipairs(gs.hand or {}) do
    out[#out + 1] = { id = c.id, label = Cards.label(c) }
  end
  return out
end

-- States that mean "the run is over, you lost". Extract.state_name yields these
-- from G.STATES; kept as a set so it's easy to extend if a version differs.
Telemetry.GAME_OVER_STATES = { GAME_OVER = true }

-- ---- frame derivation (pure: POD GameState -> light frame) -------------------

local function joker_keys(gs)
  local out = {}
  for _, j in ipairs(gs.jokers or {}) do out[#out + 1] = j.key or "?" end
  return out
end

local function hand_level_sum(gs)
  local s = 0
  for _, h in pairs((gs.run and gs.run.hand_levels) or {}) do
    s = s + math.max(0, (h.level or 1) - 1)
  end
  return s
end

-- name -> level, LEVELED hands only (the base-1 entries are noise in a log line). Mirrors
-- the sim driver's `hand_level_map` so live and sim ante records read the same.
local function hand_level_map(gs)
  local m, any = {}, false
  for name, h in pairs((gs.run and gs.run.hand_levels) or {}) do
    local lvl = h.level or 1
    if lvl > 1 then m[name] = lvl; any = true end
  end
  return any and m or nil
end

-- A frame is everything the state machine needs from one snapshot, and nothing
-- that holds a live object. `ctx` (the gs itself) is forwarded to enrich only.
-- NOTE on the three fields added 2026-08-14: `hand_type_plays` and `build_plan` are stored by
-- REFERENCE, and `self.prev` keeps a frame across ticks. That is safe here only because both are
-- plain PODs -- state_extraction rebuilds `hand_type_plays` on every read, and `build_plan` is a
-- small commitment table -- never a LOVE/Steamodded object. Keep it that way: the invariant above
-- is what stops telemetry from pinning game objects alive.
function Telemetry.frame_of(gs)
  local meta = gs.meta or {}
  local b = gs.blind or {}
  local econ = gs.economy or {}
  return {
    seed = meta.seed_hash or "",
    ante = math.floor(meta.ante or 1),
    round = math.floor(meta.round or 1),
    state = meta.state or "",
    blind_type = b.blind_type,
    boss = b.boss or false,
    target = b.target_chips or 0,
    scored = b.chips_scored or 0,
    dollars = econ.dollars or 0,
    hands_left = b.hands_left or 0,
    discards_left = b.discards_left or 0,
    -- the blind's STARTING allowance, so blind_result can report how many hands/discards
    -- were actually spent (clearing on hand 1 vs digging for four look identical without it)
    base_hands = b.base_hands,
    base_discards = b.base_discards,
    njokers = #(gs.jokers or {}),
    joker_keys = joker_keys(gs),
    hand_level_sum = hand_level_sum(gs),
    consumables = #(gs.consumables or {}),
    has_hand = #(gs.hand or {}) > 0,
    hand = hand_cards(gs),   -- cards currently in hand (for per-hand PLAY/DISCARD reconstruction)
    -- WHICH HANDS THIS RUN ACTUALLY LANDS, and what it has leveled. The 2026-08-12 human
    -- dataset cannot answer "does the winner level the hand they play?" -- the half of the
    -- play-derived commitment that concerns the human is unverifiable without these, and it
    -- is the central claim behind BP.play_direction. Both are already extracted; they were
    -- simply never carried into a record.
    hand_type_plays = (gs.run or {}).hand_type_plays,
    hand_levels = hand_level_map(gs),
    build_plan = (gs.run or {}).build_plan,
  }
end

-- ---- construction -----------------------------------------------------------

-- opts:
--   emit(record)  REQUIRED -- persist one flat record (caller appends JSONL)
--   enrich(ctx)   optional -- return a flat metrics table for boundary records
--   clock()       optional -- monotonic seconds for the `t` stamp (default 0)
function Telemetry.new(opts)
  opts = opts or {}
  return setmetatable({
    emit = opts.emit or function() end,
    enrich = opts.enrich,
    clock = opts.clock or function() return 0 end,
    run = nil,        -- current run summary { seed, max_ante, ended }
    prev = nil,       -- previous frame
    last_play = nil,  -- last frame that was an active blind (for death context)
  }, Telemetry)
end

-- ---- internals --------------------------------------------------------------

function Telemetry:_now() return self.clock() end

function Telemetry:_metrics(ctx)
  if not (self.enrich and ctx) then return nil end
  local ok, m = pcall(self.enrich, ctx)
  if ok and type(m) == "table" then return m end
  return nil
end

function Telemetry:_board_fields(frame)
  return {
    dollars = frame.dollars,
    njokers = frame.njokers,
    jokers = Json.array(frame.joker_keys),
    hand_level_sum = frame.hand_level_sum,
    consumables = frame.consumables,
    hand_type_plays = frame.hand_type_plays,
    hand_levels = frame.hand_levels,
    build_plan = frame.build_plan,
  }
end

-- If the previous run never recorded an end (no GAME_OVER seen, no win) but a new
-- run is now starting, the old run must have ended somehow -- record an INFERRED
-- death at its last active blind. This makes the death-ante histogram robust to the
-- `-- VERIFY` game-over STATE NAME being wrong (the primary risk in death detection):
-- even if "GAME_OVER" never matches, every finished run still lands in the histogram,
-- flagged inferred=true so the analyzer can tell measured from inferred deaths.
function Telemetry:_finalize_unended(reason)
  local run = self.run
  if not run or run.ended or run.won then return end
  run.ended = true
  local d = self.last_play
  if not d then return end           -- never saw an active blind -> nothing to place
  self.emit({
    kind = "death", inferred = true, reason = reason, seed = run.seed, t = self:_now(),
    ante = d.ante, blind_type = d.blind_type, boss = d.boss or false,
    target = d.target, scored = d.scored,
    ratio = (d.target and d.target > 0) and (d.scored / d.target) or nil,
    dollars = d.dollars, njokers = d.njokers,
    jokers = Json.array(d.joker_keys or {}),
    hand_level_sum = d.hand_level_sum, consumables = d.consumables,
  })
end

function Telemetry:_start_run(frame)
  self:_finalize_unended("seed_change")   -- close out any run that didn't record an end
  self.run = { seed = frame.seed, max_ante = frame.ante, ended = false,
               partial = frame.ante > 1 }
  self.last_play = nil
  self.emit({ kind = "run_start", seed = frame.seed, t = self:_now(),
              ante = frame.ante, dollars = frame.dollars,
              partial = self.run.partial or nil })
end

-- ---- public: feed one snapshot ----------------------------------------------

-- observe(frame, ctx): `frame` from Telemetry.frame_of(gs); `ctx` is the gs,
-- forwarded only to enrich at boundaries. Returns the record emitted this call
-- (or nil) -- handy for tests/logging.
function Telemetry:observe(frame, ctx)
  if not frame or not frame.seed or frame.seed == "" then return nil end
  local emitted = nil

  -- new run? (seed changed, or first ever frame)
  if not self.run or self.run.seed ~= frame.seed then
    self:_start_run(frame)
    self.prev = frame
    if frame.has_hand then self.last_play = frame end
    return nil
  end

  -- remember the last active-blind frame so a later GAME_OVER can report WHERE
  -- the run died (the death-state snapshot has the blind fields cleared).
  if frame.has_hand and frame.target and frame.target > 0 then
    self.last_play = frame
  end

  -- PER-HAND PLAY / DISCARD (2026-08-26, for advice-review of the in-blind dig). Reconstruct each
  -- hand by diffing the hand across frames: cards in prev.hand but gone from frame.hand are the ones
  -- that LEFT (played or discarded). A hands_left drop => PLAY (and which hand_type incremented); a
  -- discards_left drop => DISCARD. Emits one `play` record so the play-vs-discard sequence is visible
  -- (the counts alone hid whether it dug or played weak hands).
  if self.prev and self.prev.has_hand and frame.has_hand
     and self.prev.ante == frame.ante and self.prev.blind_type == frame.blind_type then
    local dhands = (self.prev.hands_left or 0) - (frame.hands_left or 0)
    local ddisc  = (self.prev.discards_left or 0) - (frame.discards_left or 0)
    if dhands > 0 or ddisc > 0 then
      local now = {}
      for _, c in ipairs(frame.hand or {}) do if c.id ~= nil then now[c.id] = true end end
      local left = {}
      for _, c in ipairs(self.prev.hand or {}) do
        if c.id == nil or not now[c.id] then left[#left + 1] = c.label end
      end
      local action = (dhands > 0) and "PLAY" or "DISCARD"
      local hand_type = nil
      if action == "PLAY" then
        local pp, cp = self.prev.hand_type_plays or {}, frame.hand_type_plays or {}
        for name, n in pairs(cp) do if n > (pp[name] or 0) then hand_type = name; break end end
      end
      self.emit({
        kind = "play", seed = frame.seed, t = self:_now(), ante = frame.ante,
        blind_type = frame.blind_type, action = action, hand_type = hand_type,
        cards = Json.array(left),
        score_delta = (frame.scored or 0) - (self.prev.scored or 0),
        scored = frame.scored, target = frame.target,
        hands_left = frame.hands_left, discards_left = frame.discards_left,
      })
    end
  end

  -- BLIND RESULT (2026-08-12). The live log had no in-blind data at all, so a player who
  -- clears a blind on hand 1 and one who deliberately spends four hands DIGGING -- discarding
  -- a winning hand to hunt lucky cards or tarot targets, farming money instead of just
  -- clearing -- produced identical telemetry. That is a different OBJECTIVE from the one the
  -- engine optimises (clear the blind), and it was invisible. Emitted on the has_hand ->
  -- no-hand transition, using the last active-blind frame.
  do
    local was = self.last_play
    if was and self.prev and self.prev.has_hand and not frame.has_hand
       and not self.GAME_OVER_STATES[frame.state] then
      local used_hands = (was.base_hands and was.hands_left)
        and (was.base_hands - was.hands_left) or nil
      local used_discards = (was.base_discards and was.discards_left)
        and (was.base_discards - was.discards_left) or nil
      self.emit({
        kind = "blind_result", seed = frame.seed, t = self:_now(),
        ante = was.ante, blind_type = was.blind_type, boss = was.boss or false,
        target = was.target, scored = was.scored,
        ratio = (was.target and was.target > 0) and (was.scored / was.target) or nil,
        hands_left = was.hands_left, discards_left = was.discards_left,
        hands_used = used_hands, discards_used = used_discards,
        dollars = frame.dollars, njokers = frame.njokers,
      })
      self.last_play = nil
    end
  end

  -- death: entered a game-over state, once per run
  if self.GAME_OVER_STATES[frame.state] and not self.run.ended then
    self.run.ended = true
    local d = self.last_play or self.prev or frame
    local ratio = (d.target and d.target > 0) and (d.scored / d.target) or nil
    local rec = {
      kind = "death", seed = frame.seed, t = self:_now(),
      ante = d.ante, blind_type = d.blind_type, boss = d.boss or false,
      target = d.target, scored = d.scored, ratio = ratio,
      dollars = frame.dollars, njokers = frame.njokers,
      jokers = Json.array(frame.joker_keys),
      hand_level_sum = frame.hand_level_sum, consumables = frame.consumables,
      metrics = self:_metrics(ctx),
    }
    self.emit(rec)
    emitted = rec
    self.prev = frame
    return emitted
  end

  -- ante advanced: a new ante began => we just cleared the previous ante's boss
  if frame.ante > (self.prev and self.prev.ante or frame.ante) then
    self.run.max_ante = math.max(self.run.max_ante, frame.ante)
    -- win: clearing ante 8's boss rolls us into ante 9 (endless). Log once.
    if frame.ante >= 9 and not self.run.won then
      self.run.won = true
      self.emit({ kind = "win", seed = frame.seed, t = self:_now(),
                  ante = frame.ante, dollars = frame.dollars,
                  njokers = frame.njokers,
                  jokers = Json.array(frame.joker_keys) })
    end
    local rec = { kind = "ante", seed = frame.seed, t = self:_now(), ante = frame.ante,
                  metrics = self:_metrics(ctx) }
    local bf = self:_board_fields(frame)
    for k, v in pairs(bf) do rec[k] = v end
    self.emit(rec)
    emitted = rec
  end

  self.prev = frame
  return emitted
end

-- convenience: derive a frame from gs and observe it
function Telemetry:observe_gs(gs)
  if not gs then return nil end
  return self:observe(Telemetry.frame_of(gs), gs)
end

-- ---- action trace -----------------------------------------------------------
-- The boundary records above say WHERE a run ended; the trace says HOW it got
-- there: which jokers/consumables were gained or lost, what the shop OFFERED and
-- the engine ADVISED (so "skipped" = offered-but-never-gained), packs opened, and
-- hand level-ups. Reconstructed purely by diffing successive scenes -- the mod is
-- an advisor, so we infer the player's (engine-following) actions from state
-- changes rather than hooking inputs. Fed a `scene` (see main.BES.scene_of):
--   { seed, ante, state, dollars, jokers[], consumables[], hand_levels{hand=lvl},
--     shop? { reroll_cost, offer_jokers[{key,cost}], offer_packs[] },
--     pack?  { items[{set,key}] }, advice? { type, target, reason } }

local function countmap(list)
  local m = {}
  for _, k in ipairs(list or {}) do m[k] = (m[k] or 0) + 1 end
  return m
end

local function diff_counts(old, new)  -- -> gains{key=n}, losses{key=n}
  local gains, losses, seen = {}, {}, {}
  for k in pairs(old) do seen[k] = true end
  for k in pairs(new) do seen[k] = true end
  for k in pairs(seen) do
    local d = (new[k] or 0) - (old[k] or 0)
    if d > 0 then gains[k] = d elseif d < 0 then losses[k] = -d end
  end
  return gains, losses
end

local function copy_map(m)
  local o = {}
  for k, v in pairs(m or {}) do o[k] = v end
  return o
end

local function shop_signature(shop)
  local parts = { "r" .. tostring(shop.reroll_cost) }
  for _, j in ipairs(shop.offer_jokers or {}) do parts[#parts + 1] = (j.key or "?") .. "@" .. tostring(j.cost) end
  for _, p in ipairs(shop.offer_packs or {}) do parts[#parts + 1] = "p:" .. tostring(p) end
  table.sort(parts)
  return table.concat(parts, "|")
end

local function pack_signature(pack)
  local parts = {}
  for _, it in ipairs(pack.items or {}) do parts[#parts + 1] = tostring(it.set) .. ":" .. tostring(it.key) end
  table.sort(parts)
  return table.concat(parts, "|")
end

function Telemetry:trace(scene)
  if not scene or not scene.seed or scene.seed == "" then return end
  if not self.run or self.run.seed ~= scene.seed then return end  -- only within a started run
  -- a gain is "via pack" while a pack is open AND on the very next tick after it closes (the last
  -- pick's gain lands as the pack disappears) -- self.was_pack carries that one-tick grace.
  local via = (scene.pack or self.was_pack) and "pack" or (scene.shop and "shop") or "other"
  local now = self:_now()

  -- On the first trace of a run we seed the diff baseline to the CURRENT board so
  -- the opening jokers aren't logged as a pile of "gains" -- but we still log the
  -- shop/pack offerings below (the first shop a run sees matters).
  local first = (not self.board or self.board.seed ~= scene.seed)
  if first then
    self.board = { seed = scene.seed, jokers = countmap(scene.jokers),
      consumables = countmap(scene.consumables), levels = copy_map(scene.hand_levels),
      vouchers = countmap(scene.vouchers), dollars = scene.dollars }
    self.shop_sig, self.pack_sig, self.blind_sig, self.pack_items = nil, nil, nil, nil
  end
  local b = self.board
  local acquired = false  -- did the player GAIN a joker/consumable/voucher this tick? (reroll gate)

  if not first then
    -- joker gains / losses (money delta on the same tick attributes a buy/sell)
    local jg, jl = diff_counts(b.jokers, countmap(scene.jokers))
    for k, n in pairs(jg) do for _ = 1, n do
      acquired = true
      self.emit({ kind = "joker_gain", seed = scene.seed, t = now, ante = scene.ante,
        key = k, via = via, dollars_before = b.dollars, dollars_after = scene.dollars })
    end end
    for k, n in pairs(jl) do for _ = 1, n do
      local sold = scene.shop and scene.dollars > b.dollars
      self.emit({ kind = "joker_loss", seed = scene.seed, t = now, ante = scene.ante,
        key = k, via = sold and "sell" or via,
        dollars_before = b.dollars, dollars_after = scene.dollars })
    end end

    -- consumable gains / used (a loss outside the shop = used; in shop w/ +$ = sold)
    local cg, cl = diff_counts(b.consumables, countmap(scene.consumables))
    for k, n in pairs(cg) do for _ = 1, n do
      acquired = true
      self.emit({ kind = "consumable_gain", seed = scene.seed, t = now, ante = scene.ante, key = k, via = via })
    end end
    for k, n in pairs(cl) do for _ = 1, n do
      local sold = scene.shop and scene.dollars > b.dollars
      self.emit({ kind = sold and "consumable_sell" or "consumable_use",
        seed = scene.seed, t = now, ante = scene.ante, key = k,
        -- which cards a targeting tarot/spectral hit: the selection on the tick BEFORE the use
        -- (using it clears the highlight). Only meaningful for a use, not a sale.
        targets = (not sold and self.prev_selected and #self.prev_selected > 0)
          and self.prev_selected or nil })
    end end

    -- hand level-ups (planet used / blue seal / etc.). via lets a Celestial-pack planet be told
    -- apart from a loose one, which the pack-pick agreement needs.
    for hand, lv in pairs(scene.hand_levels or {}) do
      local old = b.levels[hand] or 0
      if lv > old then
        self.emit({ kind = "level_up", seed = scene.seed, t = now, ante = scene.ante,
          hand = hand, from = old, to = lv, via = via })
      end
    end

    -- VOUCHER purchases (used_vouchers is a set; a new key = bought this round). Previously
    -- untracked entirely, so a Seed Money / Director's Cut buy was invisible to the analysis.
    local vg = diff_counts(b.vouchers, countmap(scene.vouchers))
    for k, n in pairs(vg) do for _ = 1, n do
      acquired = true
      self.emit({ kind = "voucher_gain", seed = scene.seed, t = now, ante = scene.ante,
        key = k, dollars_before = b.dollars, dollars_after = scene.dollars })
    end end
  end

  -- BLIND SELECT, once per distinct (ante, blind) pairing. Emitted when the player is on the
  -- blind-select screen, so PLAY-vs-SKIP is recoverable: a Small blind_select followed by a
  -- Big blind_select at the same ante means the Small was skipped. Without it a skipped blind
  -- leaves no trace at all and the ante simply advances.
  if scene.blind_select then
    local bs = scene.blind_select
    local sig = tostring(scene.ante) .. "|" .. tostring(bs.blind_type)
    if sig ~= self.blind_sig then
      self.blind_sig = sig
      self.emit({ kind = "blind_select", seed = scene.seed, t = now, ante = scene.ante,
        blind_type = bs.blind_type, skip_tag = bs.skip_tag, target_chips = bs.target_chips,
        dollars = scene.dollars, njokers = #(scene.jokers or {}),
        ranked = scene.ranked and Json.array(scene.ranked) or nil,
        advice = scene.advice })
    end
  else self.blind_sig = nil end

  -- shop offer + engine advice, once per distinct offering (a reroll changes the sig)
  if scene.shop then
    local sig = shop_signature(scene.shop)
    if sig ~= self.shop_sig then
      -- REROLL: the offers changed while still in the shop, cash dropped, nothing was bought and no
      -- pack is opening. (A buy also changes the sig -- one offer leaves -- but sets `acquired`; a
      -- pack buy sets scene.pack.) Previously a reroll was invisible except as a fresh shop record.
      if self.shop_sig ~= nil and not acquired and not scene.pack and scene.dollars < b.dollars then
        self.emit({ kind = "reroll", seed = scene.seed, t = now, ante = scene.ante,
          cost = b.dollars - scene.dollars, dollars_after = scene.dollars })
      end
      self.shop_sig = sig
      self.emit({ kind = "shop", seed = scene.seed, t = now, ante = scene.ante,
        dollars = scene.dollars, reroll_cost = scene.shop.reroll_cost,
        offer_jokers = Json.array(scene.shop.offer_jokers or {}),
        offer_packs = Json.array(scene.shop.offer_packs or {}),
        ranked = scene.ranked and Json.array(scene.ranked) or nil,
        advice = scene.advice })
    end
  else self.shop_sig = nil end

  -- pack contents + engine advice, once per distinct pack. Also emit an explicit PACK_PICK when an
  -- item leaves the pack (picking one shrinks the item list -> the sig changes). This makes the
  -- human's pick directly recoverable instead of only by diffing consecutive fixtures (which missed
  -- single-pick and last-pick cases). A fresh pack (items ADDED) resets rather than logging picks.
  if scene.pack then
    local ikeys = {}
    for _, it in ipairs(scene.pack.items or {}) do ikeys[#ikeys + 1] = it.key or it.set or "?" end
    local cur = countmap(ikeys)
    local sig = pack_signature(scene.pack)
    if sig ~= self.pack_sig then
      if self.pack_items then
        local added, picked = diff_counts(self.pack_items, cur)
        if not next(added) then   -- no new items => same pack, the missing ones were PICKED
          for k, n in pairs(picked) do for _ = 1, n do
            self.emit({ kind = "pack_pick", seed = scene.seed, t = now, ante = scene.ante, key = k })
          end end
        end
      end
      self.pack_sig = sig
      self.pack_items = cur
      self.emit({ kind = "pack", seed = scene.seed, t = now, ante = scene.ante,
        items = Json.array(scene.pack.items or {}),
        ranked = scene.ranked and Json.array(scene.ranked) or nil,
        advice = scene.advice })
    end
  else self.pack_sig = nil; self.pack_items = nil end

  -- advance the diff baseline
  self.was_pack = scene.pack ~= nil     -- one-tick grace so a closing pick's gain is via=pack
  self.prev_selected = scene.selected   -- last tick's selection -> targets for next tick's use
  self.board = { seed = scene.seed, jokers = countmap(scene.jokers),
    consumables = countmap(scene.consumables), levels = copy_map(scene.hand_levels),
    vouchers = countmap(scene.vouchers), dollars = scene.dollars }
end

return Telemetry
