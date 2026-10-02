-- tests/test_scheduler.lua
-- The live scheduler (main.lua): the main recommendation is TIME-SLICED (owner 2026-10-02: animations froze
-- while it computed). Loads main.lua headlessly (its in-game wiring is gated on G/SMODS) with a fake clock and
-- drives BES.begin_eval / BES.pump_job with a zero budget, so every slice boundary hands the frame back.

local DE = require("engine.decision_engine")
local GS = require("model.game_state")
local card = GS.card

return function(t)
  local saved = { love = _G.love, samples = _G.BES_SAMPLES }
  local T = 100
  _G.love = { timer = { getTime = function() return T end } }
  local Log = require("util.log")
  local saved_level = Log.level
  local HandEval = require("engine.hand_eval")
  local Overlay = require("ui.overlay")

  local ok, err = pcall(function()
    local BES = dofile(package.searchpath("main", package.path))
    Log.level = "off"
    _G.BES_SAMPLES = 6                      -- keep the play-state refinement (survival sim) quick

    local RANKS = { "Ace", "King", "Queen", "Jack", "10", "9", "7", "4", "2" }
    local SUITS = { "Spades", "Hearts", "Clubs", "Diamonds" }
    local function state(offset)
      local hand = {}
      for i = 1, 8 do
        hand[i] = card{ id = i + offset, rank = RANKS[((i + offset) % #RANKS) + 1], suit = SUITS[(i % 4) + 1] }
      end
      return GS.new{ hand = hand, run = { hand_levels = {}, hand_size = 8 },
        blind = { target_chips = 600, chips_scored = 0, hands_left = 4, discards_left = 3, played_hand_types = {} } }
    end
    local function ids(a)
      local o = {}
      for _, c in ipairs((a and a.cards) or {}) do o[#o + 1] = c.id end
      return (a and a.type or "nil") .. ":" .. table.concat(o, ",")
    end

    -- 1. the main answer is spread over many frames, and equals the synchronous decide
    local want = ids(DE.decide(state(0), { sim = nil }).best)
    BES.last = nil
    BES.begin_eval(state(0), nil)
    t.ok(BES.thinking ~= nil and Overlay.state.thinking, "thinking starts with the evaluation")
    local pumps, first, prog_ok, last_prog = 0, nil, true, 0
    while BES.job and pumps < 200000 do
      BES.pump_job(0)
      pumps = pumps + 1
      BES.think_progress()
      local p = Overlay.state.progress or 0
      if BES.thinking then
        if p < last_prog - 1e-9 or p > 0.97 + 1e-9 then prog_ok = false end
        last_prog = p
      end
      if not first and not BES.thinking then first = { pumps = pumps, best = ids(BES.last and BES.last.ranked.best) } end
    end
    t.ok(first ~= nil, "thinking ends")
    t.ok(first and first.pumps > 10, "main recommendation spread over many frames (" .. tostring(first and first.pumps) .. ")")
    t.eq(first and first.best, want, "sliced main answer == synchronous decide")
    t.ok(prog_ok, "progress bar only rises and stays below full while thinking")
    t.ok(not Overlay.state.thinking, "panel leaves thinking once the answer lands")
    t.ok(BES.EXPECT.blind ~= 2700, "the expected-work estimate learns from a finished decision")

    -- 2. a newer state replaces an in-flight job: the stale answer is never published
    BES.last = nil
    local a, b = state(0), state(20)
    BES.begin_eval(a, nil)
    for _ = 1, 5 do BES.pump_job(0) end
    BES.begin_eval(b, nil)
    local leaked = false
    local n = 0
    while BES.job and n < 200000 do
      BES.pump_job(0); n = n + 1
      if BES.last and BES.last.gs == a then leaked = true end
    end
    t.ok(not leaked, "the replaced job never publishes")
    t.ok(BES.last and BES.last.gs == b, "the newer state's advice is what lands")

    -- 2b. F5 flag: the last decisions are remembered, one entry per decision STATE, capped
    local Json = require("util.json")
    local RF = require("core.replay_fixture")
    BES.recent = {}
    local s1 = state(0)
    BES.remember({ gs = s1, ranked = { best = { type = "DISCARD", cards = { s1.hand[1] }, reason = "cheap" } } })
    BES.remember({ gs = s1, ranked = { best = { type = "PLAY", cards = { s1.hand[2] }, reason = "refined" } } })
    t.eq(#BES.recent, 1, "the refined answer for the same state replaces the first")
    t.eq(BES.recent[1].reason, "refined", "... and is the one kept")
    for k = 1, 14 do BES.remember({ gs = state(k), ranked = { best = { type = "PLAY", cards = {} } } }) end
    t.eq(#BES.recent, BES_FLAG_KEEP, "history capped at BES_FLAG_KEEP")
    local recs = BES.flag_records("test-flag")
    t.eq(#recs, BES_FLAG_KEEP, "a flag saves the whole history (the misplay may predate the key press)")
    t.eq(recs[1].steps_before, BES_FLAG_KEEP - 1, "oldest first")
    t.eq(recs[#recs].steps_before, 0, "steps_before 0 = on screen at the press")
    t.eq(recs[#recs].decision, "blind", "decision kind recorded for replay")
    local okj, line = pcall(Json.encode, recs[#recs])
    t.ok(okj, "flag record encodes to JSON")
    local back = Json.decode(line)
    local okr, res = pcall(DE.decide, RF.rehydrate(back), {})
    t.ok(okr and res and res.best, "a flagged state replays under the engine")
    t.eq(back.flag_id, "test-flag", "flag id round-trips")
    local nsaved = BES.flag()
    t.eq(nsaved, BES_FLAG_KEEP, "F5 reports how many decisions it saved")
    t.eq(Overlay.active_notice(T), "Flagged (" .. BES_FLAG_KEEP .. ")", "F5 confirms on the panel")
    t.eq(Overlay.active_notice(T + 10), nil, "... briefly")
    -- a state that cannot be serialised must not lose the press (live NUJ9ENYU: presses vanished silently)
    local broken = { meta = {}, jokers = 5 }   -- serialising its jokers fails (ipairs on a number)
    BES.remember({ gs = broken, ranked = { best = { type = "PLAY", cards = {} } } })
    local recs2 = BES.flag_records("test-flag-2")
    t.eq(#recs2, BES_FLAG_KEEP, "every remembered decision still gets a record")
    t.ok(recs2[#recs2].error ~= nil, "the unreadable one is kept as a minimal record with its error")
    t.eq(recs2[#recs2].steps_before, 0, "... in its place in the history")
    t.eq(BES.flag(), BES_FLAG_KEEP, "F5 still saves the whole press")

    -- 3. safety valve: a thinking flag with no job must not stall the self-player
    BES.thinking = { kind = "blind", t0 = T, units0 = BES.work_units }
    BES.job = nil
    T = T + 3
    BES.think_progress()
    t.ok(BES.thinking == nil, "stale thinking flag cleared without a job")

    -- 4. slice budget: idle (no game -> nothing animating) gets the larger slice
    -- frame-aware budget: what is left of the target frame after the game's own work
    BES.game_cost = nil
    t.eq(BES.slice_budget(), BES_BUDGET_BUSY, "no frame measured yet -> the default slice")
    BES.note_frame(0.010, 0.002)                       -- the game itself took 8 ms
    t.near(BES.game_cost, 0.008, "game cost = frame work minus our slice", 1e-12)
    BES.think_mode = "balanced"
    t.near(BES.slice_budget(), 1 / 60 - 0.008 - BES_FRAME_SAFETY, "balanced: the rest of a 60 fps frame", 1e-12)
    BES.note_frame(0.004, 0)
    t.ok(BES.game_cost > 0.0075, "a lighter frame lowers the estimate only slowly (decaying max)")
    BES.note_frame(0.030, 0)
    t.near(BES.game_cost, 0.030, "a heavier frame raises it at once", 1e-12)
    t.eq(BES.slice_budget(), BES_BUDGET_MIN, "a slow PC still gets a minimum slice")
    BES.game_cost = 0.005; BES.refresh_rate = 144; BES.think_mode = "smooth"
    t.eq(BES.slice_budget(), BES_BUDGET_MIN, "smooth: a 144 Hz frame leaves only the minimum")
    BES.think_mode = "fast"
    t.eq(BES.slice_budget(), BES_BUDGET_IDLE, "fast: the old fixed slice")
    BES.think_mode = "balanced"; BES.game_cost = nil; BES.refresh_rate = nil
    local AP = require("ui.autoplay")
    local was = AP.enabled
    AP.enabled = true
    t.eq(BES.slice_budget(), BES_BUDGET_AUTO, "self-play gets the largest slice (nobody watching frames)")
    AP.enabled = was
  end)
  t.ok(ok, "scheduler suite ran without error: " .. tostring(err))

  HandEval.set_yield(nil)              -- main.lua installs its GC-step hook at load; leave the engine pure
  Log.level = saved_level
  _G.love, _G.BES_SAMPLES = saved.love, saved.samples
  Overlay.set_thinking(false, 0); Overlay.set(nil)
end
