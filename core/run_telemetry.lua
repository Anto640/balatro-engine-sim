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

local Telemetry = {}
Telemetry.__index = Telemetry

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

-- A frame is everything the state machine needs from one snapshot, and nothing
-- that holds a live object. `ctx` (the gs itself) is forwarded to enrich only.
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
    njokers = #(gs.jokers or {}),
    joker_keys = joker_keys(gs),
    hand_level_sum = hand_level_sum(gs),
    consumables = #(gs.consumables or {}),
    has_hand = #(gs.hand or {}) > 0,
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
  local via = scene.pack and "pack" or (scene.shop and "shop") or "other"
  local now = self:_now()

  -- On the first trace of a run we seed the diff baseline to the CURRENT board so
  -- the opening jokers aren't logged as a pile of "gains" -- but we still log the
  -- shop/pack offerings below (the first shop a run sees matters).
  local first = (not self.board or self.board.seed ~= scene.seed)
  if first then
    self.board = { seed = scene.seed, jokers = countmap(scene.jokers),
      consumables = countmap(scene.consumables), levels = copy_map(scene.hand_levels),
      dollars = scene.dollars }
    self.shop_sig, self.pack_sig = nil, nil
  end
  local b = self.board

  if not first then
    -- joker gains / losses (money delta on the same tick attributes a buy/sell)
    local jg, jl = diff_counts(b.jokers, countmap(scene.jokers))
    for k, n in pairs(jg) do for _ = 1, n do
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
      self.emit({ kind = "consumable_gain", seed = scene.seed, t = now, ante = scene.ante, key = k, via = via })
    end end
    for k, n in pairs(cl) do for _ = 1, n do
      local sold = scene.shop and scene.dollars > b.dollars
      self.emit({ kind = sold and "consumable_sell" or "consumable_use",
        seed = scene.seed, t = now, ante = scene.ante, key = k })
    end end

    -- hand level-ups (planet used / blue seal / etc.)
    for hand, lv in pairs(scene.hand_levels or {}) do
      local old = b.levels[hand] or 0
      if lv > old then
        self.emit({ kind = "level_up", seed = scene.seed, t = now, ante = scene.ante,
          hand = hand, from = old, to = lv })
      end
    end
  end

  -- shop offer + engine advice, once per distinct offering (a reroll changes the sig)
  if scene.shop then
    local sig = shop_signature(scene.shop)
    if sig ~= self.shop_sig then
      self.shop_sig = sig
      self.emit({ kind = "shop", seed = scene.seed, t = now, ante = scene.ante,
        dollars = scene.dollars, reroll_cost = scene.shop.reroll_cost,
        offer_jokers = Json.array(scene.shop.offer_jokers or {}),
        offer_packs = Json.array(scene.shop.offer_packs or {}),
        advice = scene.advice })
    end
  else self.shop_sig = nil end

  -- pack contents + engine advice, once per distinct pack
  if scene.pack then
    local sig = pack_signature(scene.pack)
    if sig ~= self.pack_sig then
      self.pack_sig = sig
      self.emit({ kind = "pack", seed = scene.seed, t = now, ante = scene.ante,
        items = Json.array(scene.pack.items or {}), advice = scene.advice })
    end
  else self.pack_sig = nil end

  -- advance the diff baseline
  self.board = { seed = scene.seed, jokers = countmap(scene.jokers),
    consumables = countmap(scene.consumables), levels = copy_map(scene.hand_levels),
    dollars = scene.dollars }
end

return Telemetry
