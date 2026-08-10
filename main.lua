-- main.lua  (Steamodded entry point: referenced by your_mod.json "main_file")
--
-- Milestone 2: read live state -> rank actions -> show a recommendation in the
-- HUD. The engine re-runs only when the relevant state changes (signature gate),
-- keeping us off the per-frame hot path.
--
-- Keys:  F7  dump owned joker ability tables (debug)
--        F8  force a re-evaluation + log    |   F9  toggle the overlay

-- ---------------------------------------------------------------------------
-- Bootstrap: make require() resolve our sibling modules in-game.
-- Steamodded does NOT add the mod folder to package.path, so a bare
-- require("util.log") fails at load time. We register a searcher that maps our
-- namespaces (util/model/core/engine/ui) to files via SMODS.load_file.
-- The headless test runner (tests/runner.lua) sets package.path instead, so it
-- never executes this block.
-- ---------------------------------------------------------------------------
if SMODS and SMODS.load_file then
  -- Resolve any of OUR modules by top-level namespace, so adding a new file
  -- never needs a manual allow-list update (that omission silently breaks the
  -- whole engine in-game while headless tests, which use package.path, pass).
  -- We run LAST (appended), only claim our namespaces, and verify the file is
  -- actually ours by loading it -- if it isn't, we return nil and let other
  -- mods' requires proceed untouched.
  local NS = { util = true, model = true, core = true, engine = true, ui = true }
  local function bes_searcher(name)
    local top = name:match("^([%w_]+)%.")
    if not (top and NS[top]) then return nil end
    local path = name:gsub("%.", "/") .. ".lua"
    local ok, chunk = pcall(SMODS.load_file, path)
    if not ok or type(chunk) ~= "function" then return nil end -- not one of ours
    return chunk                                               -- Lua calls it to build the module
  end
  local searchers = package.searchers or package.loaders -- 5.2+ / LuaJIT(5.1)
  if searchers then table.insert(searchers, bes_searcher) end
end

local Log = require("util.log")

local function try_require(name)
  local ok, mod = pcall(require, name)
  if not ok then Log.error("require failed:", name, mod); return nil end
  return mod
end

local Extract  = try_require("core.state_extraction")
local JokerEffects = try_require("engine.joker_effects")
local HandEval = try_require("engine.hand_eval")   -- for the background yield hook
local Cards    = try_require("util.cards")          -- for the F7 hand/decision dump
local Sig      = try_require("core.signature")
local Decision = try_require("engine.decision_engine")
local Simulation = try_require("engine.simulation")
local ShopAdvisor = try_require("engine.shop_advisor")
local SkipAdvisor = try_require("engine.skip_advisor")
local PackOpenAdvisor = try_require("engine.pack_open_advisor")
local Overlay  = try_require("ui.overlay")
local HUDInject = try_require("ui.hud_inject")
-- Phase 0 self-play instrumentation (SELFPLAY_PLAN.md): record real runs to JSONL
-- so we can confirm the "behind on pace by ante 2-3" hypothesis with numbers.
local Telemetry = try_require("core.run_telemetry")
local Pacing    = try_require("engine.pacing")
local Eval      = try_require("engine.eval_function")
local Json      = try_require("util.json")

-- Monte-Carlo sample count per evaluation. Higher = smoother probabilities but
-- more cost; the signature gate means this only runs when state changes.
BES_SAMPLES = 80

local BES = {}
BES.tracker = Sig and Sig.tracker() or nil
BES.last = nil

-- Run the decision engine on the current state and push it to the overlay.
-- with_sim=true also runs the (expensive) Monte-Carlo probability engine; the
-- live tick passes false so card-selection stays responsive, F8 passes true.
-- Surface any owned/shop joker whose live key isn't covered by our model: it
-- would score ZERO silently (e.g. a base-game key typo our catalogue doesn't
-- match), which is the exact failure that makes the engine undervalue your board.
-- Logged once per unique key so a mismatch is reportable instead of invisible.
function BES.warn_uncovered(gs)
  if not (JokerEffects and JokerEffects.is_covered) then return end
  BES.warned = BES.warned or {}
  local function scan(list, where)
    for _, j in ipairs(list or {}) do
      local k = j.key
      if k and not JokerEffects.is_covered(k) and not BES.warned[k] then
        BES.warned[k] = true
        Log.warn("uncovered joker key (scores ZERO) in " .. where .. ": " .. tostring(k)
          .. " — report it so the effect can be modelled")
      end
    end
  end
  scan(gs.jokers, "board")
  if gs.shop then scan(gs.shop.jokers, "shop") end
end

function BES.evaluate(with_sim, gs)
  if not (Extract and Decision) then return end
  gs = gs or Extract.snapshot()   -- caller may pass an already-built snapshot (C4)
  if not gs then
    if Overlay then Overlay.set({ best = nil, reason = "No game state." }) end
    return
  end
  pcall(BES.warn_uncovered, gs)

  -- An open booster pack: recommend which revealed items to take, and in what
  -- order (chained effects), or to skip the pack (deck bloat). The cheap pass
  -- (with_sim=false, the live tick) ranks by priors instantly -- NO play
  -- simulation -- and the background job (BES.tick) refines it with the measured
  -- ranking. with_sim=true (F8) does the measured pass synchronously.
  if gs.pack and PackOpenAdvisor then
    local ok, po = pcall(PackOpenAdvisor.recommend, gs, { cheap = not with_sim })
    if ok and po and po.reason then
      BES.apply_pack(gs, po)
      return
    end
  end

  -- At blind select, recommend whether to skip for the tag or play.
  if gs.meta and gs.meta.in_blind_select and SkipAdvisor then
    local ok, sk = pcall(SkipAdvisor.recommend, gs)
    if ok and sk then
      local action = {
        type = sk.recommend == "SKIP" and "SKIP" or "CONTINUE",
        target = sk.recommend == "SKIP" and { name = sk.tag } or nil,
        reason = sk.reason, confidence = 0.7,
        expected_value = (sk.tag_value - sk.play_value) / math.max(1, sk.play_value),
      }
      BES.last = { gs = gs, ranked = { best = action }, skip = true }
      if Overlay then Overlay.set({ best = action }) end
      Log.info("SKIP: " .. (sk.reason or ""))
      return
    end
  end

  -- In the shop, recommend an economy action instead of a hand.
  if gs.shop and ShopAdvisor then
    local ok, ranked = pcall(ShopAdvisor.recommend, gs, {})
    if ok then
      if ranked.warn then
        Log.error("shop advisor (partial):", ranked.warn)
        -- show a trimmed warning on the (wrapping) panel so it's reportable
        if ranked.best then
          ranked.best.reason = (ranked.best.reason or "") .. "  [partial: " .. tostring(ranked.warn):sub(1, 90) .. "]"
        end
      end
      BES.last = { gs = gs, ranked = ranked, shop = true }
      if Overlay then Overlay.set(ranked) end
      if HUDInject then HUDInject.refresh() end
      Log.info(ShopAdvisor.summary(ranked))
      return ranked
    else
      Log.error("shop advisor failed:", ranked)
      -- surface the failure instead of falling through to a stale blind action
      if Overlay then Overlay.set({ best = nil, reason = "Shop eval error: " .. tostring(ranked) }) end
      return
    end
  end

  -- No cards in hand (cash-out / transition screens): clear the panel rather
  -- than leave the previous blind's play showing -- that "stale" look is what
  -- reads as the advisor being an action behind.
  if #gs.hand == 0 then
    if Overlay then Overlay.set({ best = nil, reason = "Waiting for the next hand…" }) end
    return
  end

  -- run the probabilistic engine only on demand (F8); it is the expensive part
  local sim = nil
  if with_sim and Simulation then
    local ok, res = pcall(Simulation.simulate, gs, { samples = BES_SAMPLES })
    if ok then sim = res else Log.error("simulate failed:", res) end
  end

  local ok, ranked = pcall(Decision.decide, gs, { sim = sim })
  if not ok then
    Log.error("decide failed:", ranked)
    if Overlay then Overlay.set({ best = nil, reason = "Eval error: " .. tostring(ranked) }) end
    return
  end
  BES.last = { gs = gs, ranked = ranked, sim = sim }
  if Overlay then Overlay.set(ranked) end
  if HUDInject then HUDInject.refresh() end
  Log.info(Decision.summary(ranked))
  return ranked
end

-- ---- live scheduler: cheap-first, then a time-sliced background sim ----------
-- The Monte-Carlo simulation costs ~hundreds of ms and used to run synchronously
-- the instant a hand changed -- and because the signature includes the hand, it
-- re-ran for EVERY card of the deal animation, stacking multi-second freezes.
-- Now: the cheap heuristic decision (~ms) runs immediately on any state change so
-- the panel is always responsive, and the expensive sim runs in a coroutine that
-- is pumped a few ms per frame. A new state change cancels an in-flight sim, so
-- the deal churn never completes a wasted rollout -- only the SETTLED hand's sim
-- finishes, then patches calibrated win/draw probabilities onto the panel.

BES_SIM_BUDGET = 0.003   -- max seconds of background work per frame
BES.job = nil            -- in-flight background job: { thread, gs, sig, finish }

-- Build + push the overlay action for a pack recommendation (shared by the cheap
-- instant pass and the measured background refine).
function BES.apply_pack(gs, po)
  local pick = po.best
  local action = {
    type = po.skip and "SKIP" or "PICK",
    target = pick and { name = pick.name or pick.key } or nil,
    reason = po.reason, confidence = 0.75,
  }
  BES.last = { gs = gs, ranked = { best = action }, pack = true }
  if Overlay then Overlay.set({ best = action }) end
  Log.info("PACK: " .. (po.reason or ""))
end

-- Deterministic per-state seed so the background sim doesn't flicker between runs.
local function sim_seed(gs)
  local b = gs.blind or {}
  local s = (#(gs.hand or {}) * 2654435761) + ((b.chips_scored or 0) * 40503)
    + ((b.hands_left or 0) * 1299709) + ((b.discards_left or 0) * 7919)
    + (#(gs.jokers or {}) * 131071)
  s = math.floor(math.abs(s)) % 2147483647
  return (s <= 0) and 1 or s
end
local function bes_lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end

-- Is this a state where the expensive blind-survival sim is meaningful? (an
-- active hand to play -- NOT a pack/shop/blind-select/transition screen).
local function is_play_state(gs)
  return gs and gs.hand and #gs.hand > 0
    and not gs.pack and not gs.shop
    and not (gs.meta and gs.meta.in_blind_select)
end

-- Start (or restart) a background job for `gs`, tagged with its signature `sig`.
-- `body` is the heavy function to run inside the coroutine; `finish(result)`
-- consumes its return value to patch the overlay. Replacing BES.job cancels any
-- stale in-flight job (its thread is simply dropped).
function BES.start_job(gs, sig, body, finish)
  BES.job = { gs = gs, sig = sig, finish = finish, thread = coroutine.create(body) }
end

-- Arm the right background refinement for the current state: the survival sim for
-- a play state, the measured pack valuation for an open pack, nothing otherwise.
function BES.arm_job(gs, sig)
  if is_play_state(gs) and Simulation then
    local rng = bes_lcg(sim_seed(gs))
    BES.start_job(gs, sig,
      function() return Simulation.simulate(gs, { samples = BES_SAMPLES, rng = rng, yield = coroutine.yield }) end,
      function(sim)
        local ok, ranked = pcall(Decision.decide, gs, { sim = sim })
        if ok and ranked then
          BES.last = { gs = gs, ranked = ranked, sim = sim }
          if Overlay then Overlay.set(ranked) end
          if HUDInject then HUDInject.refresh() end
          Log.info(Decision.summary(ranked))
        else
          Log.error("decide(+sim) failed:", ranked)
        end
      end)
  elseif gs.pack and PackOpenAdvisor then
    -- measured pack ranking (best_play sampling) -> time-sliced via the hand_eval
    -- yield hook the pump sets around each resume; refines the instant cheap pass.
    BES.start_job(gs, sig,
      function() return PackOpenAdvisor.recommend(gs) end,
      function(po) if po and po.reason then BES.apply_pack(gs, po) end end)
  else
    BES.job = nil
  end
end

-- Advance the in-flight job for up to `budget` seconds; when it finishes, run its
-- finisher (only if it's still the live state -- else the result is stale). The
-- hand_eval yield hook is active ONLY across each resume, so synchronous engine
-- calls elsewhere this frame never see it.
function BES.pump_job(budget)
  local job = BES.job
  if not job then return end
  local now = (love and love.timer and love.timer.getTime()) or 0
  local deadline = now + (budget or BES_SIM_BUDGET)
  repeat
    if HandEval then HandEval.set_yield(coroutine.yield) end
    local ok, res = coroutine.resume(job.thread)
    if HandEval then HandEval.set_yield(nil) end
    if not ok then
      Log.error("background job failed:", res); BES.job = nil; return
    end
    if coroutine.status(job.thread) == "dead" then
      BES.job = nil
      if BES.tracker and BES.tracker.current() ~= job.sig then return end -- moved on
      pcall(job.finish, res)
      return
    end
    now = (love and love.timer and love.timer.getTime()) or deadline
  until now >= deadline
end

-- ---- Phase 0 run telemetry --------------------------------------------------
-- One JSONL file in the LÖVE save dir, appended across sessions. The recorder is a
-- pure state machine (core/run_telemetry); here we give it the live sinks: a clock,
-- an append-emit, and an `enrich` that measures pace/run-strength at run boundaries
-- ONLY (a few times per run), so the per-tick cost stays negligible.
BES_RUNLOG = "bes_runs.jsonl"

function BES.telemetry_instance()
  if BES.telemetry ~= nil then return BES.telemetry end          -- created (or false) already
  if not (Telemetry and Json) then BES.telemetry = false; return false end
  BES.telemetry = Telemetry.new{
    clock = function() return (love and love.timer and love.timer.getTime()) or 0 end,
    emit = function(rec)
      if love and love.filesystem then
        pcall(love.filesystem.append, BES_RUNLOG, Json.encode(rec) .. "\n")
      end
      Log.info(string.format("run-telemetry %s: ante=%s $%s jokers=%s",
        tostring(rec.kind), tostring(rec.ante), tostring(rec.dollars), tostring(rec.njokers)))
    end,
    -- measured pace/run-strength: the diagnostic that tells us if we're on track for
    -- ante 8. Runs only at ante boundaries + death. All in pcall -- telemetry must
    -- NEVER take the game down.
    enrich = function(gs)
      local m = {}
      if Pacing then
        local ok, p = pcall(Pacing.pace, gs, { samples = 6 })
        if ok and p then
          m.pace_margin = p.margin; m.on_pace = p.on_pace
          m.capacity = p.capacity; m.growth = p.growth; m.fail_ante = p.fail_ante
        end
      end
      if Eval then
        local ok, rs = pcall(Eval.run_strength, gs, { measure = false })
        if ok then m.run_strength = rs end
      end
      return m
    end,
  }
  local dir = (love and love.filesystem and love.filesystem.getSaveDirectory
    and love.filesystem.getSaveDirectory()) or "save dir"
  Log.info("run telemetry -> " .. tostring(dir) .. "/" .. BES_RUNLOG)
  return BES.telemetry
end

-- Build the "scene" the action tracer diffs: current board + (if open) shop/pack
-- offerings + the engine's latest recommendation. Lets the trace reconstruct what
-- the engine bought/skipped/sold/used without hooking inputs.
function BES.scene_of(gs)
  local meta = gs.meta or {}
  local levels = {}
  for h, v in pairs((gs.run and gs.run.hand_levels) or {}) do levels[h] = v.level or 1 end
  local jk, ck = {}, {}
  for _, j in ipairs(gs.jokers or {}) do jk[#jk + 1] = j.key or "?" end
  for _, c in ipairs(gs.consumables or {}) do ck[#ck + 1] = c.key or "?" end
  local scene = {
    seed = meta.seed_hash or "", ante = math.floor(meta.ante or 1), state = meta.state,
    dollars = (gs.economy and gs.economy.dollars) or 0,
    jokers = jk, consumables = ck, hand_levels = levels,
  }
  if gs.shop then
    local oj = {}
    for _, j in ipairs(gs.shop.jokers or {}) do oj[#oj + 1] = { key = j.key or "?", cost = j.cost } end
    local op = {}
    for _, p in ipairs(gs.shop.boosters or {}) do op[#op + 1] = p.name or p.key or "?" end
    scene.shop = { reroll_cost = gs.shop.reroll_cost, offer_jokers = oj, offer_packs = op }
  end
  if gs.pack then
    local items = {}
    for _, it in ipairs(gs.pack.items or {}) do items[#items + 1] = { set = it.set, key = it.key } end
    scene.pack = { items = items }
  end
  local last = BES.last
  if last and last.ranked and last.ranked.best then
    local a = last.ranked.best
    scene.advice = { type = a.type, target = (a.target and a.target.name) or a.hand_type, reason = a.reason }
  end
  return scene
end

function BES.observe(gs)
  local tel = BES.telemetry_instance()
  if not tel then return end
  pcall(function() tel:observe_gs(gs) end)
  pcall(function() tel:trace(BES.scene_of(gs)) end)
end

-- Gate: only re-evaluate when something relevant changed. Runs the CHEAP engine
-- pass synchronously (instant panel), then arms a background job to refine it.
function BES.tick()
  if not (Extract and BES.tracker) then return end
  local gs = Extract.snapshot()
  if not gs then return end
  -- telemetry observes EVERY tick (before the change-gate) so it never misses an
  -- ante advance or a GAME_OVER; the recorder itself only acts at boundaries.
  BES.observe(gs)
  if not BES.tracker.changed(gs) then return end
  -- cheap, measurement-free pass for EVERY state -> panel updates immediately (C4:
  -- the only snapshot this cycle; evaluate reuses it rather than snapshotting again)
  BES.evaluate(false, gs)
  BES.arm_job(gs, BES.tracker.current())
end

-- ---- debug: dump owned joker ability tables (Phase 0) -----------------------
-- The scaling-joker reader (engine.joker_effects `scaled`) pulls a joker's live
-- counter from `ability` using guessed, version-dependent field names. If those
-- names are wrong, every scaling joker (Obelisk/Hologram/Ride the Bus/...) reads
-- as a no-op and the engine severely undervalues your board. This dumps the real
-- `ability` table of each owned joker so we can confirm the correct field names.
-- Bounded serializer (depth/key caps + cycle guard) so a stray object reference
-- in an ability can't blow up or loop.
local function bes_serialize(v, depth, maxdepth, maxkeys, seen, indent)
  local t = type(v)
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "string" then return string.format("%q", v) end
  if t ~= "table" then return "<" .. t .. ">" end
  if seen[v] then return "<cycle>" end
  if depth >= maxdepth then return "<table…>" end
  seen[v] = true
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local pad = string.rep("  ", indent + 1)
  local parts, shown = {}, 0
  for _, k in ipairs(keys) do
    if shown >= maxkeys then parts[#parts + 1] = pad .. "… (" .. (#keys - shown) .. " more)"; break end
    parts[#parts + 1] = pad .. tostring(k) .. " = "
      .. bes_serialize(v[k], depth + 1, maxdepth, maxkeys, seen, indent + 1)
    shown = shown + 1
  end
  seen[v] = nil
  if #parts == 0 then return "{}" end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep("  ", indent) .. "}"
end

function BES.dump_jokers()
  local G = _G.G
  if not (G and G.jokers and G.jokers.cards) then Log.info("joker dump: no jokers on board"); return end
  local lines = { "--- BES joker ability dump (" .. #G.jokers.cards .. " jokers) ---" }
  for i, c in ipairs(G.jokers.cards) do
    local center = c.config and c.config.center
    local key = (center and center.key) or "?"
    local ed = c.edition and c.edition.type
    -- coverage: does our model recognise this live key, and does it SCORE?
    local cov = "?"
    if JokerEffects and JokerEffects.is_covered then
      if JokerEffects.is_registered(key) then cov = "scored"
      elseif JokerEffects.is_covered(key) then cov = "value-only"
      else cov = "!! UNCOVERED (scores ZERO)" end
    end
    lines[#lines + 1] = string.format("[%d] key=%s name=%s edition=%s  -> %s", i, key,
      tostring(c.ability and c.ability.name), tostring(ed), cov)
    lines[#lines + 1] = "    ability = " .. bes_serialize(c.ability, 0, 3, 60, {}, 1)
  end

  -- current hand + what the engine recommends for it. This makes a play-decision
  -- complaint ("it didn't play the obvious Ace pair") diagnosable from the F7 file:
  -- it shows the best play of EACH hand type with its score, so you can see whether
  -- the engine valued the Ace play correctly and what it actually chose.
  if Extract and Decision and Cards then
    local ok, gs = pcall(Extract.snapshot)
    if ok and gs and gs.hand and #gs.hand > 0 then
      local function labels(cs)
        local o = {}; for _, c in ipairs(cs or {}) do o[#o + 1] = Cards.label(c) end
        return table.concat(o, " ")
      end
      lines[#lines + 1] = ""
      lines[#lines + 1] = "--- current hand + decision ---"
      lines[#lines + 1] = "hand: " .. labels(gs.hand)
      local b = gs.blind or {}
      lines[#lines + 1] = string.format("blind: target=%s scored=%s remaining=%s hands_left=%s discards_left=%s",
        tostring(b.target_chips), tostring(b.chips_scored),
        tostring(math.max(0, (b.target_chips or 0) - (b.chips_scored or 0))),
        tostring(b.hands_left), tostring(b.discards_left))
      if HandEval and HandEval.top_plays then
        lines[#lines + 1] = "best play per hand-type (score, cards):"
        local okp, plays = pcall(HandEval.top_plays, gs, gs.hand, 8)
        if okp and plays then
          for _, p in ipairs(plays) do
            lines[#lines + 1] = string.format("    %-16s %9d  [%s]", p.hand_type, p.score, labels(p.cards))
          end
        end
      end
      local okd, ranked = pcall(Decision.decide, gs, {})
      if okd and ranked and ranked.best then
        local a = ranked.best
        lines[#lines + 1] = string.format("RECOMMENDATION: %s %s [%s]",
          a.type, a.hand_type or "", labels(a.cards))
        lines[#lines + 1] = "  reason: " .. tostring(a.reason)
      end
    end
  end

  local out = table.concat(lines, "\n")
  Log.info("\n" .. out)
  -- also write to the LÖVE save dir so it's easy to copy out of game
  local wrote = false
  if love and love.filesystem then
    wrote = pcall(love.filesystem.write, "bes_joker_dump.txt", out)
    if wrote then
      local dir = (love.filesystem.getSaveDirectory and love.filesystem.getSaveDirectory()) or "save dir"
      Log.info("joker dump written to " .. tostring(dir) .. "/bes_joker_dump.txt")
    end
  end
  -- on-screen confirmation (F7 is otherwise silent). Held for a few seconds via
  -- BES.notice_until, which the periodic tick respects before overwriting it.
  if Overlay then
    Overlay.set({ best = nil, reason = string.format(
      "Joker dump: %d joker%s %s bes_joker_dump.txt (save folder).",
      #G.jokers.cards, #G.jokers.cards == 1 and "" or "s",
      wrote and "written to" or "logged (file write failed) —") })
  end
  if love and love.timer then BES.notice_until = love.timer.getTime() + 6 end
end

-- ---- in-game wiring ---------------------------------------------------------
if _G.G and _G.SMODS then
  if HUDInject then HUDInject.install() end

  -- debug + toggle keys (chain to any previously-registered handler)
  if love then
    local prev = love.keypressed
    function love.keypressed(key, ...)
      if key == "f7" then Log.info("--- joker ability dump ---"); pcall(BES.dump_jokers) end
      if key == "f8" then Log.info("--- manual evaluation (with sim) ---"); BES.evaluate(true) end
      if key == "f9" and HUDInject then HUDInject.toggle() end
      if prev then return prev(key, ...) end
    end

    -- Periodic re-evaluation via a love.update timer (replaces an E_MANAGER
    -- re-scheduling loop that could accumulate events and leak over time).
    local prev_update = love.update
    local acc = 0
    love.update = function(dt, ...)
      if prev_update then prev_update(dt, ...) end
      -- advance any in-flight background job a few ms EVERY frame (cheap when idle)
      -- so the expensive Monte-Carlo / pack measurement never blocks rendering.
      pcall(BES.pump_job, BES_SIM_BUDGET)
      acc = acc + (dt or 0)
      if acc >= 0.25 then
        acc = 0
        -- hold a transient notice (e.g. the F7 dump confirmation) on screen
        -- before the periodic re-eval overwrites the panel.
        local held = BES.notice_until and love.timer and love.timer.getTime() < BES.notice_until
        if not held then pcall(BES.tick) end
      end
    end
  end

  BES.telemetry_instance()  -- create the run log up front so its path is logged on load
  Log.info("Balatro Engine Sim loaded. F7 = dump jokers, F8 = evaluate, F9 = toggle overlay."
    .. "  Run telemetry -> " .. BES_RUNLOG .. " (analyze with tools/analyze_runs.lua).")
end

return BES
