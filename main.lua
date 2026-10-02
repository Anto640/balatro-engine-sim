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
local BuildPlan = try_require("engine.build_plan")  -- live persistence of the archetype commitment
local Overlay  = try_require("ui.overlay")
local HUDPanel = try_require("ui.hud_panel")
local Highlights = try_require("ui.highlights")  -- in-world tags on the recommended card / item / button
local FastMode = try_require("ui.fast_mode")      -- skip animations while the F11 self-player plays (via Handy)
local Settings = try_require("ui.settings")       -- the Mods-menu settings page
local Dagger   = try_require("engine.dagger")    -- Ceremonial Dagger placement before blind select
local Autoplay = try_require("ui.autoplay")   -- F11: translate the engine's decision into real inputs
-- Phase 0 self-play instrumentation (SELFPLAY_PLAN.md): record real runs to JSONL
-- so we can confirm the "behind on pace by ante 2-3" hypothesis with numbers.
local Telemetry = try_require("core.run_telemetry")
local Pacing    = try_require("engine.pacing")
local Eval      = try_require("engine.eval_function")
local Json      = try_require("util.json")
-- Step 2-B (methodology-shift-2026-08): emit a replay FIXTURE at each shop/pack decision so the
-- human's runs can be replayed under the current engine for the per-decision agreement objective.
local ReplayFixture = try_require("core.replay_fixture")

-- Monte-Carlo sample count per evaluation. Higher = smoother probabilities but
-- more cost; the signature gate means this only runs when state changes.
BES_SAMPLES = 80

-- Heap GROWTH (KB, since the last full collect) above which we force a FULL GC instead
-- of an incremental step. A Hanging-Chad / xmult board makes best_play_target enumerate
-- card ORDERS (R7) and the survival sim (BES_SAMPLES) roll out repeatedly; both allocate,
-- and the overlay re-evaluates on every drawn card. Under LuaJIT the incremental "step" GC
-- may not COMPLETE a cycle while allocation is continuous, so freeable garbage piles up until
-- the (32-bit) allocator ceiling throws "decide failed: not enough memory" and the game dies
-- a few frames later (owner report 2026-09-22: The Goad + Hanging Chad + held Magician).
-- GROWTH-based (not an absolute size) so it is independent of the game's own baseline heap:
-- a cheap board never triggers it (pure step, no stutter); sustained accumulation forces a
-- real collect that reclaims fully (a single decide's garbage is entirely collectable -- this
-- is slow-GC pacing, not a leak) and re-floors. It therefore cannot run away.
BES_GC_GROWTH_KB = 256 * 1024   -- force a full collect after +256 MB of growth

local BES = {}
BES.tracker = Sig and Sig.tracker() or nil
BES.last = nil

-- ROOT-CAUSE FIX for "decide failed: not enough memory" (owner 2026-09-22, The Goad).
-- When the best play does not clear (constant under a suit-debuff boss where scored cards
-- score 0), DE.decide DIGS -- DiscardValue.best measures candidate discards x samples x
-- best_play, and each best_play enumerates every subset (HandEval.each_subset), allocating a
-- short-lived scoring table per subset. That garbage is fully collectable, but LuaJIT's
-- INCREMENTAL collector does not run inside the tight enumeration loop, so on some hands the
-- transient heap ballooned to >1.7 GB in a SINGLE decide and hit the allocator ceiling (a
-- profile showed the per-decide PEAK drop 39 MB -> 1.2 MB when a GC step runs per subset-enum).
-- each_subset already calls a YIELD hook once per invocation (for the sim's time-slicing); set
-- that hook, for the FOREGROUND decide, to an incremental GC step so the transient garbage is
-- reclaimed as it is produced. Pure: it changes no decision, only when memory is freed. The
-- background sim overrides YIELD with coroutine.yield during its own resumes (see pump_job),
-- which restores this stepper afterwards.
BES.gc_yield = function(light) if not light then collectgarbage("step") end end   -- light = mid-enumeration tick
if HandEval and HandEval.set_yield then HandEval.set_yield(BES.gc_yield) end

-- Bound the Lua heap after an evaluation. Step normally (cheap, non-stuttering), but once
-- the heap has grown BES_GC_GROWTH_KB past the last full collect, force a full collect so
-- repeated expensive decides / sims on a Hanging-Chad-class board cannot accumulate to the
-- OOM ceiling. Growth-based so it is independent of the game's baseline heap (see there).
BES._gc_floor = nil
function BES.gc_guard()
  local c = collectgarbage("count")
  BES._gc_floor = BES._gc_floor or c
  if c - BES._gc_floor > BES_GC_GROWTH_KB then
    collectgarbage("collect")
    BES._gc_floor = collectgarbage("count")
  else
    collectgarbage("step")
  end
end

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

-- The run state the live mod carries across snapshots, as it applies to `gs` -- WITHOUT storing it (the fixture
-- writer calls this too, before the evaluation; only BES.evaluate commits the result to BES._*).
--
-- BUILD-COMMITMENT persistence (2026-09-20 field-diff audit, PROVABLE dead-field). BP.commitment
-- reads gs.run.build_plan, which the SIM advances every shop and carries across states
-- (sim/content.lua:923). The LIVE overlay never did -- state_extraction doesn't write it and
-- main.lua never called BP.advance -- so BP.commitment / anchored_commitment were nil and
-- BP.planet_credit was 0 in the ACTUAL mod. Mirror the sim: keep a run-scoped plan, advance
-- it in the shop (where the sim does), and thread it into every gs the advisors read (in-blind
-- planet_credit included). Reset on a new run (the run seed changes).
--
-- THE MOUTH's lock = the FIRST hand type played this blind. played_hand_types (GAME.hands[*].played_this_round)
-- can hold more than one type, and the legality filter took an arbitrary one: live 16JEBAVN (2026-09-30) locked
-- Three of a Kind, then the engine recommended three Pairs predicting +558/+2016/+360 -- each scored 0 and the run
-- died. Record the first type ourselves: when exactly one hand has been played this round and the game has
-- registered it (last_hand_played is among this round's types), that is the lock. Keyed by run + round.
--
-- Fixtures (2026-10-02): bes_fixtures.jsonl used to be written BEFORE the evaluation attached these, so 0 of 892
-- recorded states carried the build plan and every replay of a commitment-dependent decision (sell protection,
-- planet credit, build fit) disagreed with live -- live Z9ZPREGI sold Raised Fist (Sly core to a Full House plan),
-- the replay sold Sly. BES.emit_fixture now records this same state.
function BES.run_state_for(gs)
  local out = {}
  if BuildPlan and gs.run then
    local seed = (gs.meta and gs.meta.seed_hash) or ""
    local plan = (seed == BES._build_seed) and BES._build_plan or nil
    if gs.shop then
      local ok_bp, p = pcall(BuildPlan.advance, gs, plan)   -- pure: returns a new plan, never edits `plan`
      if ok_bp then plan = p end
    end
    out.plan_key, out.plan = seed, plan
  end
  if gs.blind then
    local fkey = tostring(gs.meta and gs.meta.seed_hash) .. ":" .. tostring(gs.meta and gs.meta.round)
    local first = (BES._first_hand_key == fkey) and BES._first_hand or nil
    local b = gs.blind
    if not first and b.hands_played_round == 1 and b.last_hand_played
       and b.played_hand_types and b.played_hand_types[b.last_hand_played] then
      first = b.last_hand_played
    end
    out.first_key, out.first_hand = fkey, first
  end
  return out
end

function BES.evaluate(with_sim, gs)
  if not (Extract and Decision) then return end
  gs = gs or Extract.snapshot()   -- caller may pass an already-built snapshot (C4)
  if not gs then
    if Overlay then Overlay.set({ best = nil, reason = "No game state." }) end
    return
  end
  pcall(BES.warn_uncovered, gs)

  -- carried run state (build commitment, Mouth lock): see BES.run_state_for
  local rs = BES.run_state_for(gs)
  if rs.plan_key then
    BES._build_seed, BES._build_plan = rs.plan_key, rs.plan
    gs.run.build_plan = rs.plan   -- so BP.commitment/planet_credit see it (shop AND blind)
  end
  if rs.first_key then
    BES._first_hand_key, BES._first_hand = rs.first_key, rs.first_hand
    gs.blind.first_hand_type = rs.first_hand
  end

  -- An open booster pack: recommend which revealed items to take, and in what
  -- order (chained effects), or to skip the pack (deck bloat). The cheap pass
  -- (with_sim=false, the live tick) ranks by priors instantly -- NO play
  -- simulation -- and the background job (BES.tick) refines it with the measured
  -- ranking. with_sim=true (F8) does the measured pass synchronously.
  if gs.pack and PackOpenAdvisor then
    local ok, po = pcall(PackOpenAdvisor.recommend, gs, { cheap = not with_sim })
    if ok and po and po.reason then
      BES.apply_pack(gs, po, not with_sim)
      return
    end
  end

  -- At blind select, recommend whether to skip for the tag or play.
  if gs.meta and gs.meta.in_blind_select and SkipAdvisor then
    local ok, sk = pcall(SkipAdvisor.recommend, gs)
    if ok then
      local action
      if sk then
        action = {
          type = sk.recommend == "SKIP" and "SKIP" or "CONTINUE",
          target = sk.recommend == "SKIP" and { name = sk.tag } or nil,
          reason = sk.reason, confidence = 0.7,
          expected_value = (sk.tag_value - sk.play_value) / math.max(1, sk.play_value),
        }
      else
        -- SkipAdvisor returns nil when there is nothing to skip FOR: the boss (unskippable)
        -- or a blind with no offered tag. The only move is to play the blind, so say so
        -- explicitly instead of leaving the panel blank (2026-08-26 advice-review #10).
        local btype = (gs.blind or {}).blind_type
        action = {
          type = "CONTINUE", confidence = 0.7,
          reason = (btype == "Boss")
            and "Play the blind — the boss can't be skipped."
            or "Play the blind — no skip tag worth taking here.",
        }
      end
      -- Ceremonial Dagger: decide what (if anything) sits to its right before the blind starts (engine/dagger.lua)
      if Dagger and action.type ~= "SKIP" then
        local okd, dp = pcall(Dagger.plan, gs)
        if okd then
          action.dagger_checked = true
          if dp then
            action.arrange = dp.order
            action.reason = (action.reason or "") .. "  [" .. dp.reason .. "]"
          end
        end
      end
      BES.last = { gs = gs, ranked = { best = action }, skip = true }
      if Overlay then Overlay.set({ best = action }) end
      Log.info((action.type == "SKIP" and "SKIP: " or "PLAY: ") .. (action.reason or ""))
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
      if Overlay then Overlay.set(ranked, gs) end
      if HUDPanel then HUDPanel.refresh() end
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

  -- DIAGNOSTIC (2026-09-22 OOM hunt): the "not enough memory" crash is not reproducible in ANY
  -- offline engine path (DE.decide / Simulation / tarot on every board incl. all-debuffed hands are
  -- <=2 MB, <=2.5 s), so the failing allocation is likely the WHOLE PROCESS (game + JokerDisplay +
  -- Multiplayer + ... + this mod) hitting a ceiling, with our small decide merely the first alloc to
  -- fail. Record the Lua heap right before each decide so a crash log SHOWS whether the heap was
  -- already huge (ambient exhaustion) or our decide spiked it (an engine bug on a live-only state).
  local heap_before = collectgarbage("count")
  local ok, ranked = pcall(Decision.decide, gs, { sim = sim })
  local heap_after = collectgarbage("count")
  -- A full evaluation churns tens of thousands of short-lived scoring tables (see
  -- HandEval.HAND_BUDGET). Balatro's own GC pacing is tuned for the base game, not for a mod
  -- allocating this hard between frames; BES.gc_guard bounds the heap (see BES_GC_GROWTH_KB).
  BES.gc_guard()
  -- Heap high-water WARN: surface WHO is growing memory. Logs only on a new +128 MB high, so it is
  -- quiet normally but draws the climb toward any ceiling in the run log.
  if heap_after > (BES._heap_hi or 0) + 128 * 1024 then
    BES._heap_hi = heap_after
    Log.warn(string.format("heap high-water: %.0f MB (this decide +%.1f MB)",
      heap_after / 1024, (heap_after - heap_before) / 1024))
  end
  if not ok then
    Log.error(string.format("decide failed: %s  [heap before=%.0f MB after=%.0f MB]",
      tostring(ranked), heap_before / 1024, heap_after / 1024))
    if Overlay then Overlay.set({ best = nil, reason = "Eval error: " .. tostring(ranked) }) end
    return
  end
  BES.last = { gs = gs, ranked = ranked, sim = sim }
  if Overlay then Overlay.set(ranked, gs) end
  if HUDPanel then HUDPanel.refresh() end
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

-- 2026-10-02 (owner: "the animations freeze midway while it's calculating"): the MAIN recommendation is now
-- time-sliced too. It used to run synchronously on every state change -- a shop ~5 s (up to 10 s), a hand up to
-- ~7 s -- holding the frame, so the game's own animations froze mid-way. Now BES.begin_eval runs it in the same
-- coroutine job as the refinement, pumped each frame; the engine's slice boundaries (HandEval YIELD, one per 32
-- scored candidates) keep each slice to a few ms (tools/yield_gaps.lua: p99 3-6 ms). The advice is unchanged --
-- slicing affects only WHEN the work runs -- and the panel shows "Thinking" with a progress bar meanwhile.
BES_BUDGET_BUSY = 0.006  -- engine seconds per frame while the game is animating (keeps animations smooth)
BES_BUDGET_IDLE = 0.020  -- ... while the screen is still (finish sooner; nothing moving to stutter)
BES_BUDGET_AUTO = 0.050  -- ... while the F11 self-player plays: nobody watches the frames, so think faster
BES_SIM_BUDGET = BES_BUDGET_BUSY   -- (legacy name)
BES_TRANSITION_MAX = 6   -- seconds a mid-animation hold may last before the state is treated as settled
BES.job = nil            -- in-flight background job: { thread, gs, sig, finish }
BES.work_units = 0       -- slice-boundary count (progress measure for the thinking bar)
-- expected work units per decision kind, learned as an EMA of finished decisions (seeded from tools/yield_gaps.lua)
BES.EXPECT = { blind = 2700, shop = 9400, pack = 2500, skip = 40 }
BES.thinking = nil       -- { kind, t0, units0 } while the main recommendation for the live state is being worked out

local function clock() return (love and love.timer and love.timer.getTime()) or os.clock() end

function BES.think_begin(kind)
  BES.thinking = { kind = kind, t0 = clock(), units0 = BES.work_units }
  if Overlay and Overlay.set_thinking then Overlay.set_thinking(true, clock()) end
end
-- `learn`: a decision that ran to completion updates the expected-work estimate for its kind
function BES.think_end(learn)
  local th = BES.thinking
  if not th then return end
  local used = BES.work_units - th.units0
  if learn and used > 0 then BES.EXPECT[th.kind] = 0.7 * (BES.EXPECT[th.kind] or used) + 0.3 * used end
  BES.thinking = nil
  if Overlay and Overlay.set_thinking then Overlay.set_thinking(false, clock()) end
end
-- per frame: the progress bar fills toward the learned expectation (capped below full until the answer lands)
function BES.think_progress()
  local th = BES.thinking
  if not th then return end
  -- safety valve: the self-player waits on BES.thinking, so a flag left set with no job must never stall it
  if not BES.job and clock() - th.t0 > 2 then BES.think_end(false); return end
  if not Overlay then return end
  local exp = BES.EXPECT[th.kind] or 1000
  Overlay.state.progress = math.min(0.97, (BES.work_units - th.units0) / math.max(1, exp))
end

-- Is the game animating? (a blocking event queued in the base queue -- dealing, scoring, the shop sliding in --
-- or a mid-action transition). Non-blocking events are background loops and don't count.
function BES.animating()
  local G = _G.G
  if Autoplay and Autoplay.in_transition and Autoplay.in_transition(G) then return true end
  local q = G and G.E_MANAGER and G.E_MANAGER.queues and G.E_MANAGER.queues.base
  if q then for _, ev in ipairs(q) do if ev.blocking ~= false then return true end end end
  return false
end
function BES.slice_budget()
  if Autoplay and Autoplay.enabled then return BES_BUDGET_AUTO end
  return BES.animating() and BES_BUDGET_BUSY or BES_BUDGET_IDLE
end

-- Build + push the overlay action for a pack recommendation (shared by the cheap
-- instant pass and the measured background refine).
-- `provisional` = this is the instant priors-only pass; the measured refine will replace it. The self-player must
-- never EXECUTE a provisional pick (live 978TLFTS: the measured pass said SKIP, a re-evaluation surfaced the cheap
-- pass's flat-prior 'Take Hex', and the self-player used it on a full board -- four jokers destroyed).
-- Arcana / Spectral packs DEAL your hand a moment after they open (the card tarots target it). A pack decision
-- made before that deal is judged on an EMPTY hand -- live BQ63E388: Justice was selected on the empty-hand state,
-- then Strength once the 8 cards arrived. Such a decision is provisional too.
function BES.pack_awaits_hand(gs)
  if gs.hand and #gs.hand > 0 then return false end
  for _, it in ipairs((gs.pack and gs.pack.items) or {}) do
    if it.set == "Tarot" or it.set == "Spectral" then return true end
  end
  return false
end
function BES.apply_pack(gs, po, provisional)
  local pick = po.best
  local action
  if po.use_first and po.use_first.key and not po.skip then
    -- MAKE ROOM IN THE TRAY: a card-making tarot from the pack needs a free consumable slot to be usable, so use
    -- the held planet first (its own step, like the make-room sell), then the pick.
    action = {
      type = "USE_CONSUMABLE",
      target = { name = po.use_first.name, key = po.use_first.key }, use_keys = { po.use_first.key },
      reason = string.format("Use %s first to free a consumable slot for %s, then take it.",
        po.use_first.name, po.use_first.for_name or "the pick"),
      confidence = 0.7,
    }
  elseif po.sell and po.sell.key and not po.skip then
    -- MAKE ROOM IS ITS OWN STEP (owner request 2026-08-30). A joker pick into a FULL board can't be
    -- taken until a joker is sold, so the PRIMARY recommendation is the SELL ("Sell X to make room for
    -- Y") -- its own header line, not a grey note under "Take Y". After the sell the re-evaluation frees
    -- a slot and surfaces the pick. One atomic step per overlay line (both for the human and the
    -- self-player, which can only actuate one action at a time).
    action = {
      type = "SELL_JOKER",
      target = { name = po.sell.name, key = po.sell.key, id = po.sell.id },
      make_room_for = po.sell.for_name,
      reason = string.format("Sell %s to make room for %s, then take it.",
        po.sell.name, po.sell.for_name or (pick and (pick.name or pick.key)) or "the pick"),
      confidence = 0.7,
    }
  else
    action = {
      type = po.skip and "SKIP" or "PICK",
      -- carry the center key (+ id when present) so the auto-play actuator can match the live pack card;
      -- name alone is a display string that won't match a center key (ui/autoplay.lua).
      -- the id must be the CARD's own stable id: every plain playing card shares the center key "c_base"
      -- (and every Bonus card "m_bonus"...), so a key-only match grabbed the FIRST such card in a Standard
      -- pack -- the overlay said "take 3 of Spades", the self-player took a Jack (owner 2026-09-23).
      target = pick and { name = pick.name or pick.key, key = pick.key,
        id = pick.id or (pick.card and pick.card.id) or (pick.joker and pick.joker.id) } or nil,
      target_note = po.target_note,          -- "apply to AS, KS" in the BIG line (#10)
      target_cards = po.target_cards,        -- machine-readable target hand-card ids (auto-play selects them)
      target_order = po.target_order,        -- Death: target_cards must sit left->right in the hand
      reason = po.reason, confidence = 0.75,
    }
  end
  BES.last = { gs = gs, ranked = { best = action }, pack = true,
    provisional = (provisional or BES.pack_awaits_hand(gs)) or nil }
  -- show a pack choice only once it is DECIDED (owner 2026-09-27: the panel said "sell Swashbuckler for Green Joker",
  -- then the measured pass skipped the pack -- the first line was only the instant provisional estimate)
  if Overlay then
    if BES.last.provisional then
      Overlay.set({ best = { type = "Evaluating pack…" },
        reason = "Measuring each pick against your deck — the choice appears when it is decided." })
      Overlay.set_reason("Measuring each pick against your deck — the choice appears when it is decided.")
    else
      Overlay.set({ best = action })
    end
  end
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

-- The background refinement for a state, as (body, finish): the survival sim for a play
-- state, the measured pack valuation for an open pack, nil otherwise.
function BES.refine_for(gs)
  if is_play_state(gs) and Simulation then
    local rng = bes_lcg(sim_seed(gs))
    return function() return Simulation.simulate(gs, { samples = BES_SAMPLES, rng = rng, yield = coroutine.yield }) end,
      function(sim)
        local ok, ranked = pcall(Decision.decide, gs, { sim = sim })
        if ok and ranked then
          BES.last = { gs = gs, ranked = ranked, sim = sim }
          if Overlay then Overlay.set(ranked, gs) end
          if HUDPanel then HUDPanel.refresh() end
          Log.info(Decision.summary(ranked))
        else
          Log.error("decide(+sim) failed:", ranked)
        end
      end
  elseif gs.pack and PackOpenAdvisor then
    -- measured pack ranking (best_play sampling); refines the instant cheap pass
    return function() return PackOpenAdvisor.recommend(gs) end,
      function(po) if po and po.reason then BES.apply_pack(gs, po) end end
  end
end

local function decision_kind(gs)
  if gs.pack then return "pack" end
  if gs.meta and gs.meta.in_blind_select then return "skip" end
  if gs.shop then return "shop" end
  return "blind"
end

-- Work out the advice for the live state as ONE time-sliced job: the main recommendation (published the
-- moment it is ready -- "Thinking" ends there unless it is only a provisional pack estimate), then the
-- refinement. A newer state replaces the job, so a stale answer is never published.
function BES.begin_eval(gs, sig)
  BES.think_begin(decision_kind(gs))
  BES.start_job(gs, sig,
    function()
      BES.evaluate(false, gs)
      if not (BES.last and BES.last.provisional) then BES.think_end(true) end
      local body, finish = BES.refine_for(gs)
      if not body then return nil end
      return { finish = finish, value = body() }
    end,
    function(res)
      if res and res.finish then res.finish(res.value) end
      BES.think_end(true)                  -- a provisional pack ends its thinking with the measured pick
    end)
end

-- The slice hook the pump installs around each resume: counts work (the progress bar), keeps the
-- per-enumeration GC step that bounds the heap (see BES.gc_yield), and hands the frame back once
-- this frame's budget is spent.
local slice_deadline = 0
local function slice_hook(light)
  BES.work_units = BES.work_units + 1
  if not light then collectgarbage("step") end
  if clock() >= slice_deadline then coroutine.yield() end
end

-- Advance the in-flight job for up to `budget` seconds; when it finishes, run its
-- finisher (only if it's still the live state -- else the result is stale). The
-- hand_eval yield hook is active ONLY across each resume, so synchronous engine
-- calls elsewhere this frame never see it.
function BES.pump_job(budget)
  local job = BES.job
  if not job then return end
  slice_deadline = clock() + (budget or BES_BUDGET_BUSY)
  repeat
    if HandEval then HandEval.set_yield(slice_hook) end
    local ok, res = coroutine.resume(job.thread)
    -- restore the foreground GC-stepping hook (NOT nil) so the next foreground decide keeps its
    -- per-subset-enum memory bound (see BES.gc_yield). nil here would leave the heavy foreground
    -- dig unbounded again between background jobs.
    if HandEval then HandEval.set_yield(BES.gc_yield) end
    if not ok then
      Log.error("background job failed:", res); BES.job = nil; BES.think_end(false); return
    end
    if coroutine.status(job.thread) == "dead" then
      BES.job = nil
      -- the background sim (BES_SAMPLES rollouts) is the heaviest allocator; reclaim it
      -- before it stacks with the next decide toward the OOM ceiling (see BES_GC_FULL_KB).
      BES.gc_guard()
      if BES.tracker and BES.tracker.current() ~= job.sig then BES.think_end(false); return end -- moved on
      pcall(job.finish, res)
      return
    end
  until clock() >= slice_deadline
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
        -- measure on the WHOLE deck, as the sim does: gs.deck is only the undrawn pile at a boundary (audit 2026-09-28)
        local pg = gs
        local okf, full = pcall(Extract.full_deck)
        if okf and full and #full > 0 then
          pg = {}; for k, v in pairs(gs) do pg[k] = v end
          pg.deck = full
        end
        local ok, p = pcall(Pacing.pace, pg, { samples = 6 })
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

-- ---- Step 2-B: per-decision REPLAY FIXTURES (methodology-shift-2026-08) ------
-- One fixture per DISTINCT shop/pack decision state, appended to bes_fixtures.jsonl. Dedup by a
-- content signature (owned board + cash + the offers on the table) so the many ticks inside one
-- shop don't each log. The fixture is a full POD (via core.replay_fixture) so the human's runs can
-- later be REPLAYED under the current engine and its top pick compared to what the human did.
-- Fully pcall-guarded by the caller -- must NEVER take the game down.
BES_FIXLOG = "bes_fixtures.jsonl"
BES._fix = { seed = nil, idx = 0, sig = nil }

-- CAPTURE-ONLY mode (data collection). When true, BES.tick still logs telemetry + replay fixtures
-- but SKIPS the Monte-Carlo evaluation -- the expensive per-change work that causes the in-game lag.
-- The overlay shows nothing (nothing is computed), which is exactly right when the point is to record
-- the HUMAN's decisions for OFFLINE replay under the current engine. F10 toggles it in-game.
-- 2026-08-26: switched back to LIVE mode (false) for interactive advice-review sessions -- the overlay
-- computes and shows real-time recommendations again. Flip back to true for lag-free data collection.
BES.capture_only = false

function BES.emit_fixture(gs)
  if not (ReplayFixture and Json and love and love.filesystem) then return end
  -- Which decision channel is this? shop / pack / IN-BLIND play. In-blind = a blind with hands
  -- left and cards in hand (the PLAY/DISCARD decision) -- captured so the offline scorer can
  -- replay the engine's in-blind play too, not just shop/pack.
  local m = gs.meta or {}
  local kind
  if gs.pack then kind = "pack"
  elseif gs.shop then kind = "shop"
  -- SELECTING_HAND only: DRAW_TO_HAND is the transient deal (partial hand) -- not a decision.
  elseif m.state == "SELECTING_HAND" and (gs.blind and (gs.blind.hands_left or 0) > 0)
      and #(gs.hand or {}) > 0 then kind = "blind"
  -- BLIND-SELECT skip decision (SKIP-for-tag vs PLAY). Previously NOT captured, so skip misplays could
  -- not be replayed/verified (owner 2026-09-20 Charm skip). Now recorded like any other decision.
  elseif m.in_blind_select and gs.blind and gs.blind.skip_tag then kind = "skip"
  else return end
  local seed = m.seed_hash or ""
  if BES._fix.seed ~= seed then BES._fix = { seed = seed, idx = 0, sig = nil } end
  -- content signature: what the decision IS, so the many ticks between actions log ONCE. Card
  -- selection is deliberately NOT in the signature (highlighting a card is not a new decision).
  local parts = { kind, tostring((gs.economy or {}).dollars or 0), tostring(#(gs.jokers or {})) }
  for _, j in ipairs(gs.jokers or {}) do parts[#parts + 1] = j.key or "?" end
  if kind == "shop" then
    parts[#parts + 1] = "S" .. tostring(gs.shop.reroll_cost)
    for _, j in ipairs(gs.shop.jokers or {}) do parts[#parts + 1] = j.key or "?" end
    for _, p in ipairs(gs.shop.boosters or {}) do parts[#parts + 1] = p.key or p.name or "?" end
  elseif kind == "pack" then
    for _, it in ipairs(gs.pack.items or {}) do parts[#parts + 1] = (it.key or it.set or "?") end
  elseif kind == "skip" then   -- the offered tag + which blind it is: one decision per blind-select
    parts[#parts + 1] = tostring(gs.blind.skip_tag)
    parts[#parts + 1] = tostring(gs.blind.blind_type or "?")
  else -- blind: the hand you must act on + what you have left to spend on it
    local b = gs.blind
    parts[#parts + 1] = "H" .. tostring(b.hands_left) .. "D" .. tostring(b.discards_left or 0)
    for _, c in ipairs(gs.hand or {}) do parts[#parts + 1] = tostring(c.id or "?") end
  end
  local sig = table.concat(parts, "|")
  if sig == BES._fix.sig then return end     -- same decision state -> already logged
  BES._fix.sig = sig
  BES._fix.idx = BES._fix.idx + 1
  -- capture-only skips evaluation, so there is no fresh advice to record; the offline scorer
  -- computes the engine's pick. In full mode, record the live advice as metadata.
  local last = (not BES.capture_only) and BES.last or nil
  local best = last and last.ranked and last.ranked.best
  local choice = best and { type = best.type,
      target = best.target and (best.target.name or best.target.key),
      hand_type = best.hand_type, key = best.target and best.target.key } or nil
  -- the carried run state the evaluation will attach (this runs before it): without it no fixture recorded the
  -- build plan or the Mouth lock, and replays disagreed with live (BES.run_state_for)
  local rs = BES.run_state_for(gs)
  if rs.plan_key then gs.run.build_plan = rs.plan end
  if rs.first_key then gs.blind.first_hand_type = rs.first_hand end
  local fx = ReplayFixture.fixture_of(gs, choice, BES._fix.idx, kind)
  -- timestamp (same clock as bes_runs.jsonl) so a fixture can be JOINED to the human's ACTUAL
  -- action -- the joker_gain/loss/consumable/blind_result with the smallest t greater than this.
  -- Without it the decision-state and the outcome can't be aligned across the two logs.
  fx.t = (love and love.timer and love.timer.getTime()) or 0
  pcall(love.filesystem.append, BES_FIXLOG, Json.encode(fx) .. "\n")
end

-- ---- F5: FLAG A MISPLAY (owner 2026-10-02) ------------------------------------
-- The key is usually pressed AFTER the wrong move (you notice a step or two later), so the flag saves the last
-- BES_FLAG_KEEP decisions, not just the current one: every published advice is remembered with its full state.
-- F5 appends them to bes_flagged.jsonl in the bes_fixtures format (so the replay tools read them as-is), oldest
-- first, each tagged with flag_id, steps_before (0 = the decision on screen at the press) and its clock time
-- (joins bes_autoplay.log). `lua tools/flagged.lua` lists them and replays each under the current engine.
BES_FLAGLOG = "bes_flagged.jsonl"
BES_FLAG_KEEP = 12
BES.recent = {}            -- ring of { gs, best, move, reason, kind, t, clock, auto }

local function flag_choice(best)
  return best and { type = best.type, target = best.target and (best.target.name or best.target.key),
    hand_type = best.hand_type, key = best.target and best.target.key } or nil
end

-- remember a published advice (one entry per decision STATE: the refined answer replaces the first one)
function BES.remember(last)
  if not (last and last.gs) then return end
  local best = last.ranked and last.ranked.best
  local entry = { gs = last.gs, best = best, kind = decision_kind(last.gs), provisional = last.provisional,
    move = Overlay and Overlay.state.move, reason = best and best.reason,
    cards = best and best.cards, t = clock(), clock = os.date("%H:%M:%S"),
    auto = (Autoplay and Autoplay.enabled) or false }
  local r = BES.recent
  if r[#r] and r[#r].gs == last.gs then r[#r] = entry else r[#r + 1] = entry end
  while #r > BES_FLAG_KEEP do table.remove(r, 1) end
end

-- build the flag records (pure apart from the clock; exposed for tests)
function BES.flag_records(flag_id)
  local out, n = {}, #BES.recent
  for i, e in ipairs(BES.recent) do
    local fx = ReplayFixture.fixture_of(e.gs, flag_choice(e.best), i, e.kind)
    fx.flag_id, fx.steps_before, fx.flag_clock = flag_id, n - i, e.clock
    fx.t, fx.advice_move, fx.advice_reason, fx.provisional, fx.self_play = e.t, e.move, e.reason, e.provisional, e.auto
    local ids = {}
    for _, c in ipairs(e.cards or {}) do ids[#ids + 1] = c.id end
    if #ids > 0 then fx.advice_cards = ids end
    out[#out + 1] = fx
  end
  return out
end

function BES.flag()
  if not (ReplayFixture and Json) then return 0 end
  local flag_id = os.date("%Y-%m-%d %H:%M:%S")
  local recs = BES.flag_records(flag_id)
  local lines = {}
  for _, fx in ipairs(recs) do
    local ok, line = pcall(Json.encode, fx)
    if ok then lines[#lines + 1] = line end
  end
  if #lines > 0 and love and love.filesystem then
    pcall(love.filesystem.append, BES_FLAGLOG, table.concat(lines, "\n") .. "\n")
  end
  Log.info(string.format("FLAGGED %s: saved the last %d decision(s) to %s", flag_id, #lines, BES_FLAGLOG))
  if Overlay and Overlay.notify then
    Overlay.notify(string.format("Flagged (%d)", #lines), clock(), 4)
  end
  return #lines
end

-- ids of the currently SELECTED (highlighted) cards, matching state_extraction's id scheme so a
-- play record's cards line up with the blind fixture's hand cards.
local function bes_highlighted_ids()
  local G = _G.G
  local h = G and G.hand
  if not (h and h.highlighted) then return nil end
  local out = {}
  for _, c in ipairs(h.highlighted) do out[#out + 1] = c.sort_id or c.unique_val end
  return (#out > 0) and out or nil
end

BES._play_prev = nil

-- Capture the human's ACTUAL play/discard the moment it happens. During SELECTING_HAND the player
-- highlights cards; when they commit, hands_left (PLAY) or discards_left (DISCARD) drops. The cards
-- highlighted on the PREVIOUS tick are the ones played/discarded. This catches EVERY play -- crucially
-- the LAST of a blind (which diffing consecutive fixtures misses) and the case where the human plays a
-- DIFFERENT hand than max-score (reorders / underplays for econ or a joker trigger while still
-- clearing). Emits {kind="play"} into bes_fixtures.jsonl, joined offline to the blind fixture by seed+t.
function BES.track_play(gs)
  if not (Json and love and love.filesystem) then return end
  local m, b = gs.meta or {}, gs.blind or {}
  local seed = m.seed_hash or ""
  local hl, dl = b.hands_left, b.discards_left
  local prev = BES._play_prev
  if prev and prev.seed == seed and prev.hi then
    local action
    if hl ~= nil and prev.hl ~= nil and hl < prev.hl then action = "PLAY"
    elseif dl ~= nil and prev.dl ~= nil and dl < prev.dl then action = "DISCARD"
    elseif prev.selecting and m.state ~= "SELECTING_HAND" then
      -- the state moves before the counter animates down: a discard goes straight to DRAW_TO_HAND, a play to
      -- HAND_PLAYED. Reading every state change as a PLAY logged each discard as a play (audit 2026-09-28).
      action = (m.state == "DRAW_TO_HAND") and "DISCARD" or "PLAY"
    end
    if action then
      pcall(love.filesystem.append, BES_FIXLOG, Json.encode({
        kind = "play", seed = tonumber(seed) or seed, ante = m.ante, action = action,
        cards = prev.hi, t = (love.timer and love.timer.getTime()) or 0 }) .. "\n")
    end
  end
  BES._play_prev = { seed = seed, hl = hl, dl = dl, hi = bes_highlighted_ids(),
                     selecting = (m.state == "SELECTING_HAND") }
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
  -- owned vouchers (used_vouchers is a map key->truthy) -> so a purchase shows as a diff below
  local vk = {}
  for k, v in pairs((gs.run and gs.run.vouchers_owned) or {}) do
    if v then vk[#vk + 1] = (type(k) == "string" and k) or (type(v) == "table" and v.key) or tostring(k) end
  end
  -- currently SELECTED cards (for tarot/spectral targets: the telemetry attaches last tick's
  -- selection to a consumable_use so "which cards you enhanced/converted" is recoverable)
  local sel = {}
  do
    local G = _G.G
    local h = G and G.hand
    if h and h.highlighted then
      for _, c in ipairs(h.highlighted) do sel[#sel + 1] = c.sort_id or c.unique_val end
    end
  end
  local scene = {
    seed = meta.seed_hash or "", ante = math.floor(meta.ante or 1), state = meta.state,
    dollars = (gs.economy and gs.economy.dollars) or 0,
    jokers = jk, consumables = ck, hand_levels = levels, vouchers = vk, selected = sel,
  }
  if gs.shop then
    local oj = {}
    for _, j in ipairs(gs.shop.jokers or {}) do oj[#oj + 1] = { key = j.key or "?", cost = j.cost } end
    local op = {}
    for _, p in ipairs(gs.shop.boosters or {}) do op[#op + 1] = p.name or p.key or "?" end
    local oc = {}
    for _, c in ipairs(gs.shop.consumables or {}) do oc[#oc + 1] = { key = c.key or "?", cost = c.cost } end
    scene.shop = { reroll_cost = gs.shop.reroll_cost, offer_jokers = oj, offer_consumables = oc, offer_packs = op }
  end
  if gs.pack then
    local items = {}
    for _, it in ipairs(gs.pack.items or {}) do items[#items + 1] = { set = it.set, key = it.key } end
    scene.pack = { items = items }
  end
  -- BLIND SELECT: what was on offer and (by the NEXT record) what the player did with it.
  -- Without this a skipped blind is invisible in the log -- the ante just advances -- so a
  -- player who skips to save time produces data indistinguishable from one who played and
  -- won. `blind_type` + `skip_tag` make skip-vs-play recoverable after the fact.
  if meta.in_blind_select then
    scene.blind_select = {
      blind_type = gs.blind and gs.blind.blind_type,
      skip_tag = gs.blind and gs.blind.skip_tag,
      target_chips = gs.blind and gs.blind.target_chips,
    }
  end

  local last = BES.last
  if last and last.ranked and last.ranked.best then
    local a = last.ranked.best
    scene.advice = { type = a.type, target = (a.target and a.target.name) or a.hand_type, reason = a.reason }
    -- The engine's MEASURED value for every option it considered, best first. The sim logs
    -- this per offer and it is what makes divergence analysis quantitative ("the human took
    -- what the engine priced at -0.6"); the live log used to throw it away, leaving only the
    -- single chosen action. Capped so a big shop cannot bloat the run log.
    local ranked, n = {}, 0
    local function push(c)
      if not c or n >= 12 then return end
      n = n + 1
      ranked[n] = { type = c.type, target = (c.target and c.target.name) or c.hand_type,
                    value = c.value }
    end
    push(a)
    for _, c in ipairs(last.ranked.alternatives or {}) do push(c) end
    scene.ranked = ranked
  end
  return scene
end

function BES.observe(gs)
  local tel = BES.telemetry_instance()
  if not tel then return end
  pcall(function() tel:observe_gs(gs) end)
  pcall(function() tel:trace(BES.scene_of(gs)) end)
  pcall(function() BES.emit_fixture(gs) end)
  pcall(function() BES.track_play(gs) end)
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
  -- CAPTURE-ONLY (data collection): telemetry + fixtures are logged in observe above; skip the
  -- Monte-Carlo evaluation entirely (the lag). The engine is replayed OFFLINE over the fixtures.
  if BES.capture_only then return end
  -- MID-ANIMATION: the last action is still resolving (a discard/play redrawing the hand, a pack pick / pack
  -- closing, a sell/reroll). Its frames are not decisions -- advising on them showed a plan for a half-drawn hand
  -- and "take this / skip" on a pack that was already closing (owner 2026-09-28). Hold the panel on a wait line,
  -- drop any in-flight job, and forget the signature so the SETTLED state is always evaluated afresh.
  -- Safety valve: a transition longer than BES_TRANSITION_MAX is treated as settled (a stuck flag must not
  -- blank the panel for good).
  local now = (love and love.timer and love.timer.getTime()) or 0
  local busy = Autoplay and Autoplay.in_transition and Autoplay.in_transition(_G.G)
  if busy then
    BES._trans_since = BES._trans_since or now
    busy = (now - BES._trans_since) < BES_TRANSITION_MAX
  else
    BES._trans_since = nil
  end
  if busy then
    if not BES._waiting then
      BES._waiting = true
      BES.job = nil
      BES.think_end(false)
      BES.tracker.reset()
      if Overlay then Overlay.set({ best = nil, reason = "…" }) end
      if HUDPanel then HUDPanel.refresh() end
    end
    return
  end
  BES._waiting = false
  if not BES.tracker.changed(gs) then return end
  -- the advice for the new state, time-sliced (C4: the only snapshot this cycle; evaluate
  -- reuses it rather than snapshotting again)
  BES.begin_eval(gs, BES.tracker.current())
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
  if HUDPanel then HUDPanel.autoplay = Autoplay; HUDPanel.install() end   -- status row: self-play / auto-restart
  if Highlights then Highlights.autoplay = Autoplay end                   -- tags reuse the self-player's lookups
  -- engine errors light a red "!" on the panel (they used to reach only the log)
  if Overlay and Overlay.add_error then
    Log.on_error = function(msg) Overlay.add_error(msg, clock(), os.date("%H:%M")) end
  end
  -- settings page in the Mods menu (SMODS loaded config.lua + the saved values into current_mod.config)
  if Settings then pcall(Settings.install, SMODS.current_mod) end
  if FastMode then
    FastMode.autoplay = Autoplay
    if HUDPanel then HUDPanel.fast = FastMode end                        -- tooltip says when fast mode is on
    pcall(FastMode.ensure)
  end

  -- debug + toggle keys (chain to any previously-registered handler)
  if love then
    local prev = love.keypressed
    function love.keypressed(key, ...)
      if key == "f7" then Log.info("--- joker ability dump ---"); pcall(BES.dump_jokers) end
      if key == "f8" then Log.info("--- manual evaluation (with sim) ---"); BES.evaluate(true) end
      if key == "f9" then   -- the panel setting (also in the Mods menu); applied next frame
        if Settings and Settings.cfg then Settings.toggle_panel() elseif HUDPanel then HUDPanel.toggle() end
      end
      if key == "f5" then pcall(BES.flag) end   -- flag a misplay: saves the last BES_FLAG_KEEP decisions
      if key == "f10" then
        BES.capture_only = not BES.capture_only
        Log.info("BES capture-only " .. (BES.capture_only
          and "ON  (fast: logs decisions, NO evaluation -> no lag)"
          or  "OFF (full evaluation + live recommendations)"))
      end
      if key == "f6" and Autoplay then
        local on = Autoplay.toggle_restart()
        Log.info("BES AUTO-RESTART " .. (on and "ON  (a new run starts by itself when a run ends)" or "OFF"))
      end
      if key == "f11" and Autoplay then
        local on = Autoplay.toggle()
        if FastMode then pcall(FastMode.refresh) end   -- animations skip / return at once
        -- auto-play needs live recommendations, so force full evaluation ON
        if on and BES.capture_only then
          BES.capture_only = false
          Log.info("BES capture-only OFF (auto-play needs live evaluation)")
        end
        Log.info("BES AUTO-PLAY " .. (on
          and "ON  (the engine plays by itself; F6 toggles auto-restart of finished runs)"
          or  "OFF (you control the game)"))
      end
      if prev then return prev(key, ...) end
    end

    -- Periodic re-evaluation via a love.update timer (replaces an E_MANAGER
    -- re-scheduling loop that could accumulate events and leak over time).
    local prev_update = love.update
    local acc = 0
    -- one-shot remote autostart (ui/autoplay.lua check_autostart): a `bes_autostart` file in the save folder turns
    -- self-play + auto-restart on at launch and continues the saved run
    if Autoplay and Autoplay.check_autostart then pcall(Autoplay.check_autostart) end
    love.update = function(dt, ...)
      if prev_update then prev_update(dt, ...) end
      -- advance any in-flight background job a few ms EVERY frame (cheap when idle)
      -- so the expensive Monte-Carlo / pack measurement never blocks rendering.
      if FastMode and not FastMode.installed then pcall(FastMode.ensure) end   -- Handy may load after this mod
      if Settings then pcall(Settings.apply, { overlay = Overlay, highlights = Highlights, fast = FastMode }) end
      pcall(BES.pump_job, BES.job and BES.slice_budget() or BES_BUDGET_BUSY)
      pcall(BES.think_progress)
      if BES.last ~= BES._remembered then BES._remembered = BES.last; pcall(BES.remember, BES.last) end
      -- AUTO-PLAY (F11): if enabled, translate the latest recommendation into real inputs. Gated on
      -- SELECTING_HAND + settled + once-per-hand inside Autoplay.tick, so this is a cheap no-op otherwise.
      -- not while the advice for the live state is still being worked out (BES.last is the previous state's)
      if Autoplay and Autoplay.enabled and not BES.thinking then pcall(Autoplay.tick, BES.last, Log and Log.info) end
      if Highlights then
        local ok, err = pcall(Highlights.update, dt, BES.last)
        if not ok and not BES.highlight_err then BES.highlight_err = true; Log.error("highlights failed:", err) end
      end
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
  Log.info("Balatro Engine Sim loaded. F5 = flag a misplay, F7 = dump jokers, F8 = evaluate, F9 = toggle overlay, "
    .. "F10 = capture-only toggle, F11 = AUTO-PLAY toggle (blind PLAY/DISCARD)."
    .. "  CAPTURE-ONLY is " .. (BES.capture_only and "ON (data-collection: no lag, logs decisions to "
      .. BES_FIXLOG .. "; press F10 for live recommendations)" or "OFF")
    .. "  Run telemetry -> " .. BES_RUNLOG .. " (analyze with tools/analyze_runs.lua).")
end

return BES
