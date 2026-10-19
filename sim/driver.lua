-- sim/driver.lua
-- PHASE 1: the full-run loop. Strings the world (referee) together with the engine
-- (policy): play each blind, award income, run the shop, advance the ante, until death
-- or an ante-8 boss clear. Emits the SAME record shapes as the live telemetry
-- (core/run_telemetry), so tools/analyze_runs.lua works on sim output unchanged --
-- which is how we calibrate the sim against real runs (SELFPLAY_PLAN.md §6).
--
-- The SHOP/content generator is INJECTED (opts.content). With the default no-op stub the
-- loop is fully exercised (a run plays its blinds, economy accrues, antes advance) but no
-- jokers are bought -- so a stub run dies early. Real fidelity lives in sim/content.lua
-- (the rarity/odds work), which plugs in here without touching the loop.

-- JIT CACHE SIZE (2026-10-18 speed audit): LuaJIT's default trace limits (maxtrace 1000, maxmcode 512 KB) are too small
-- for the engine -- the compiler log showed ~400 full flushes of the compiled code in one run, each followed by
-- recompiling everything. Larger limits halve sim run time (2007: 19.5s -> 11.0s, 3007: 37.5s -> 18.6s CPU) and do not
-- change results (golden seeds byte-identical). Sim only: every sim entry point loads this module.
if jit and jit.opt and jit.opt.start then pcall(jit.opt.start, "maxtrace=4000", "maxmcode=16384") end

local World       = require("sim.world")
local Pacing      = require("engine.pacing")
local Eval        = require("engine.eval_function")
local Json        = require("util.json")
local SkipAdvisor = require("engine.skip_advisor")
local GS          = require("model.game_state")
local ShopAdvisor = require("engine.shop_advisor")
local Decision    = require("engine.decision_engine")
local ConsumableV = require("engine.consumable_value")
local JokerData   = require("engine.joker_data")   -- B1 feature vector

local Driver = {}

-- ---- MCTS Phase 1: fork a run for a counterfactual rollout ------------------
-- The `run` object is ALL plain data EXCEPT `run.rng` (a World.lcg closure with hidden state), so
-- a fork = deep-copy the data + a FRESH lcg. The fresh stream samples an INDEPENDENT plausible
-- future (different shop draws / shuffles) -- exactly what chance-node determinization needs; we do
-- NOT (and cannot) reproduce the original's hidden rng state. Functions are skipped in the copy
-- (rng is the only one, and it's set explicitly). Deterministic per (seed, priv_seed) so a rollout
-- is reproducible. See docs/archive/MCTS_PLAN.md §4.
local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, val in pairs(v) do
    if type(val) ~= "function" then out[k] = deep_copy(val) end
  end
  return out
end
Driver._deep_copy = deep_copy
function Driver.fork(run, priv_seed)
  local f = deep_copy(run)
  -- default private seed derived from the run position, so distinct fork points differ
  local base = math.floor((tonumber(run.seed) or 1))
  f.rng = World.lcg(priv_seed or ((base * 1000003 + (run.round or 0) * 101 + (run.ante or 1)) % 2147483647 + 1))
  return f
end

-- ---- engine identity (P6) ---------------------------------------------------
-- Stamp each run_start with the tuning constants + git SHA in effect, so an old
-- sim_out/*.jsonl stays interpretable after the engine is retuned (you can tell
-- WHICH engine produced a batch). Memoised; deterministic (no wall-clock/RNG).
local ENGINE_META
local function engine_meta()
  if ENGINE_META then return ENGINE_META end
  -- best-effort git SHA. No stderr redirect: it's non-portable across io.popen's shell
  -- (cmd.exe on Windows chokes on `2>/dev/null`); on a non-repo git just prints to stderr
  -- and stdout stays empty -> sha nil. pcall guards a missing git binary.
  local sha
  local ok, fh = pcall(io.popen, "git rev-parse --short HEAD")
  if ok and fh then
    sha = (fh:read("*l") or ""):gsub("%s+", "")
    fh:close()
    if not sha:match("^%x+$") then sha = nil end   -- reject error text / empty
  end
  ENGINE_META = {
    git_sha = sha,
    sa = { econ_floor = ShopAdvisor.ECON_FLOOR, econ_floor_rate = ShopAdvisor.ECON_FLOOR_RATE,
           upgrade_margin = ShopAdvisor.UPGRADE_MARGIN, reroll_min_improvement = ShopAdvisor.REROLL_MIN_IMPROVEMENT,
           reroll_appetite_rich = ShopAdvisor.REROLL_APPETITE_RICH, w_fv = ShopAdvisor.W_FV,
           joker_score_weight = ShopAdvisor.JOKER_SCORE_WEIGHT, interest_horizon = ShopAdvisor.INTEREST_HORIZON,
           cost_weight = ShopAdvisor.COST_WEIGHT },
    de = { level_use_credit = Decision.LEVEL_USE_CREDIT },
    cv = { wraith_joker = ConsumableV.WRAITH_JOKER, wraith_per_dollar = ConsumableV.WRAITH_PER_DOLLAR,
           level_persist_a1 = ConsumableV.level_scale({ meta = { ante = 1 } }) },
  }
  return ENGINE_META
end

-- A no-op shop: validates the loop without buying anything. Replace via opts.content.
local STUB_CONTENT = { shop_phase = function() end }

-- pace / run-strength snapshot for an `ante` boundary record (mirrors main.lua enrich).
local function metrics(run)
  local gs = {
    jokers = run.jokers, deck = run.deck, economy = run.economy,
    meta = { ante = run.ante }, run = { hand_levels = run.hand_levels, base_hands = run.base_hands },
    blind = { base_hands = run.base_hands },
  }
  local m = {}
  local ok, p = pcall(Pacing.pace, gs, { samples = 4, rng = run.rng })
  if ok and p then m.pace_margin = p.margin; m.on_pace = p.on_pace; m.capacity = p.capacity end
  local ok2, rs = pcall(Eval.run_strength, gs, { measure = false })
  if ok2 then m.run_strength = rs end
  m.features = Driver.features(run)   -- B1: the learned-win-model feature vector
  return m
end

-- B1 (WINRATE_V3_PLAN Phase B): the per-ante FEATURE VECTOR for fitting a win-probability
-- model on self-play data. Pure counting over the run state -- no rng, no measurement, no
-- engine call -- so it cannot perturb the seeded stream (an additive measurement that is
-- NOT stream-neutral is a documented way to churn a batch; see WINRATE_AUDIT §7).
--
-- These replace `engine/pacing.lua`'s six invented growth coefficients with something that
-- can be FITTED. Labels come from the run outcome: dense `reach(ante+1)` per boundary plus
-- the sparse `win`, which is what makes 4-positives-per-160 trainable at all.
Driver._metrics = metrics   -- the leaf value of a look-ahead rollout (sim/lookahead.lua)
function Driver.features(run)
  local f = {
    ante = run.ante, round = run.round, dollars = run.economy.dollars,
    njokers = #(run.jokers or {}), joker_slots = run.joker_slots,
    consumables = #(run.consumables or {}), consumable_slots = run.consumable_slots,
    vouchers = #(run.vouchers_owned or {}),
    hand_size = run.hand_size, hands = run.base_hands, discards = run.base_discards,
    xmult = 0, xmult_scaling = 0, scaling = 0, copier = 0, econ_jokers = 0,
    econ_total = 0, negative = 0, tier_sum = 0, tier_max = 0,
  }
  f.slots_free = math.max(0, (run.joker_slots or 5) - f.njokers)
  for _, j in ipairs(run.jokers or {}) do
    local d = JokerData.resolve(j.key) or {}
    local cat = d.cat or ""
    if JokerData.is_xmult(j.key) then f.xmult = f.xmult + 1 end
    if cat == "xmult_scaling" then f.xmult_scaling = f.xmult_scaling + 1 end
    if JokerData.is_scaling(j.key) then f.scaling = f.scaling + 1 end
    if j.key == "j_blueprint" or j.key == "j_brainstorm" then f.copier = f.copier + 1 end
    local e = d.econ or 0
    if e > 0 then f.econ_jokers = f.econ_jokers + 1; f.econ_total = f.econ_total + e end
    if j.edition == "negative" then f.negative = f.negative + 1 end
    local t = d.tier or 0
    f.tier_sum = f.tier_sum + t
    if t > f.tier_max then f.tier_max = t end
  end
  -- leveling: the win-CONVERTER in every run this project has seen reach ante 8
  local lv_max, lv_sum, n_lv = 0, 0, 0
  for _, h in pairs(run.hand_levels or {}) do
    local over = math.max(0, (h.level or 1) - 1)
    lv_sum = lv_sum + over
    if over > 0 then n_lv = n_lv + 1 end
    if over > lv_max then lv_max = over end
  end
  f.hand_lv_max, f.hand_lv_sum, f.hands_leveled = lv_max, lv_sum, n_lv
  -- deck shaping
  local enh, seal, edn = 0, 0, 0
  for _, c in ipairs(run.deck or {}) do
    if c.enhancement then enh = enh + 1 end
    if c.seal then seal = seal + 1 end
    if c.edition then edn = edn + 1 end
  end
  f.deck_size, f.enhanced, f.sealed, f.editioned = #(run.deck or {}), enh, seal, edn
  return f
end

local function joker_keys(run)
  local out = {}
  for _, j in ipairs(run.jokers or {}) do out[#out + 1] = j.key or "?" end
  return out
end

local function hand_level_sum(run)
  local s = 0
  for _, h in pairs(run.hand_levels or {}) do s = s + math.max(0, (h.level or 1) - 1) end
  return s
end

-- per-joker detail (P5): key + edition + stickers. A negative-edition joker is
-- slot-free (it doesn't consume a board slot), flagged so the analyzer can reason
-- about effective board size.
local function joker_details(run)
  local out = {}
  for _, j in ipairs(run.jokers or {}) do
    local ab = type(j.ability) == "table" and j.ability or nil
    local ex = ab and type(ab.extra) == "table" and ab.extra or nil
    out[#out + 1] = { key = j.key, edition = j.edition,
      slot_free = (j.edition == "negative") or nil,
      eternal = (ab and ab.eternal) or (ex and ex.eternal) or nil,
      perishable = (ab and ab.perishable) or nil,
      rental = (ab and ab.rental) or nil }
  end
  return Json.array(out)
end

-- hand levels as a per-hand-type map (P5): { ["Pair"] = 3, ... }, only hands above
-- base level (keeps the record small). hand_level_sum is kept for backward compat.
local function hand_level_map(run)
  local m = {}
  for name, h in pairs(run.hand_levels or {}) do
    local lvl = h.level or 1
    if lvl > 1 then m[name] = lvl end
  end
  return m
end

local function board(run)
  return { dollars = run.economy.dollars, njokers = #(run.jokers or {}),
           jokers = Json.array(joker_keys(run)), hand_level_sum = hand_level_sum(run),
           consumables = #(run.consumables or {}),
           -- enriched snapshot (P5)
           jokers_detail = joker_details(run),
           hand_levels = hand_level_map(run),
           vouchers = Json.array((function() local v = {}; for _, k in ipairs(run.vouchers_owned or {}) do v[#v + 1] = k end; return v end)()),
           build_plan = run.build_plan,
           hands = run.base_hands, discards = run.base_discards, hand_size = run.hand_size,
           consumable_slots = run.consumable_slots, joker_slots = run.joker_slots }
end

-- run(seed, opts) -> { records[], won, death_ante, seed }
-- opts.content : a content module with shop_phase(run) (default: no-op stub)
-- opts.max_ante : stop after this ante (default 8 = the win condition)
function Driver.run(seed, opts)
  opts = opts or {}
  local content = opts.content or STUB_CONTENT
  local max_ante = opts.max_ante or 8
  -- MCTS Phase 2: opts.run lets a caller supply a PRE-BUILT run (a Driver.fork) so the same loop
  -- resumes a counterfactual rollout from mid-run; opts.silent makes emit a no-op (rollouts want no
  -- telemetry). Both default off -> a normal Driver.run(seed) is byte-identical (nil-guarded branches).
  local run = opts.run or World.new_run(seed, opts)
  local recs = {}
  local function emit(r) if opts.silent then return end; r.seed = tostring(seed); recs[#recs + 1] = r end

  if not opts.run then
    emit({ kind = "run_start", ante = 1, dollars = run.economy.dollars, engine = engine_meta() })
  end

  -- W4: the ante counter is MUTABLE -- Hieroglyph's -1 ante (content sets run._ante_back)
  -- is consumed at the boundary below by replaying the ante, so the loop is a while.
  local ante = (opts.run and run.ante) or 1
  -- LOOK-AHEAD resume (sim/lookahead.lua, 2026-10-18): a forked run continues from the blind AFTER the shop it was
  -- forked in, with the ante's blinds (and boss) already rolled -- not by replaying the ante from its Small blind.
  local resume = opts.resume and opts.run and run._ante_blinds and true or false
  while ante <= max_ante do
    run.ante = ante
    local blinds, first_bi
    if resume then
      blinds, first_bi, resume = run._ante_blinds, (run._blind_idx or 0) + 1, false
    else
      first_bi = 1
      -- Phase A probe: free hand levels per ante (sim/probe.lua). Applied BEFORE the ante's
      -- snapshot so the feature vector reflects them. Inert on every normal run.
      if run.probe and run.probe.free_levels and content.grant_free_levels then
        content.grant_free_levels(run, run.probe.free_levels)
      end
      if ante > 1 then
        local r = { kind = "ante", ante = ante, metrics = metrics(run) }
        local b = board(run); for k, v in pairs(b) do r[k] = v end
        emit(r)
      end

      World.checkpoint(run, "ante", ante)        -- common random numbers (World.stream): the boss roll
      blinds = World.ante_blinds(run)
    end
    for bi, blind in ipairs(blinds) do
      if bi < first_bi then goto next_blind end
      run.round = run.round + 1
      -- SKIP decision (Small/Big only): offer a tag, ask the engine, and if it skips,
      -- take the tag's effect and move to the next blind (no play, no income, NO shop).
      if blind.type ~= "Boss" and content.gen_tag then
        World.checkpoint(run, "tag", ante, run.round)       -- the tag, its Orbital hand, a skipped tag's pack
        blind.skip_tag = content.gen_tag(run.rng, run.ante)   -- E-11: 9 tags are ante-gated (min_ante 2)
        -- the Orbital tag names its hand when offered; the engine sees it (live: G.GAME.orbital_choices)
        run._orbital_hand = (blind.skip_tag == "tag_orbital" and content.orbital_hand) and content.orbital_hand(run, run.rng) or nil
        local sgs = GS.new{
          deck = run.deck, jokers = run.jokers, economy = run.economy,
          meta = { ante = run.ante }, run = { hand_levels = run.hand_levels,
            base_hands = run.base_hands, build_plan = run.build_plan },
          blind = { blind_type = blind.type, base_hands = run.base_hands, skip_tag = blind.skip_tag,
                    skip_tag_hand = run._orbital_hand },
        }
        local ok, sk = pcall(SkipAdvisor.recommend, sgs)
        -- P2: record the skip decision on BOTH branches (a DECLINED skip matters as
        -- much as a taken one). Telemetry only -- does not change the SKIP/PLAY choice.
        if ok and sk then
          emit({ kind = "skip", ante = ante, blind_type = blind.type, tag = blind.skip_tag,
                 recommend = sk.recommend, tag_value = sk.tag_value, play_value = sk.play_value,
                 reason = sk.reason })
        end
        -- SKIP LESION (Probe.CONFIGS.noskip / noskip_early). The engine skips 2.16 blinds
        -- per run, 27-30% of offers at antes 2-4; the expert human plays 3.0/3.0/3.0 through
        -- ante 3 and only skips from ante 6 to speedrun an already-won run ("skipping is
        -- typically the wrong option" -- user, 2026-08-13). Each skip forfeits the blind
        -- reward, the interest on it, AND a shop visit, on the one axis probing found binding.
        local no_skip = run.probe and run.probe.no_skip_until
          and (run.ante <= run.probe.no_skip_until)
        if no_skip then sk = nil end
        -- `invest1` (owner 2026-10-12: "only takes like investment tag ante 1 and that's it"): every other skip refused
        if ok and sk and run.probe and run.probe.skip_only
           and not (run.probe.skip_only[blind.skip_tag] and run.ante <= (run.probe.skip_only_until or 99)) then sk = nil end
        if ok and sk and sk.recommend == "SKIP" then
          if content.apply_tag then content.apply_tag(run, blind.skip_tag, run.rng) end
          World.skip_tick(run)   -- A1: Throwback +0.25x per skipped blind
          run._blinds_skipped = (run._blinds_skipped or 0) + 1   -- A5: Speed Tag counter (after payout)
          goto next_blind
        end
      end

      World.checkpoint(run, "blind", ante, run.round)     -- the deal and every in-blind roll
      local result = World.play_blind(run, blind)
      -- Mr Bones: prevents death if you scored >= 25% of the requirement, then is
      -- destroyed. -- VERIFY (works on any blind). Models a real death-prevention joker.
      if not result.cleared and result.target > 0 and result.scored >= 0.25 * result.target then
        for i, j in ipairs(run.jokers) do
          if j.key == "j_mr_bones" then
            table.remove(run.jokers, i)
            -- E-11: a negative-edition Mr Bones takes its slot-free +1 joker_slot with it
            if j.edition == "negative" then run.joker_slots = math.max(1, (run.joker_slots or 5) - 1) end
            result.cleared = true; break
          end
        end
      end
      -- P1: per-hand play log for this blind (lets the analyzer split a variance death
      -- -- capacity >= target but scored < target -- from a build death). Emitted for
      -- EVERY blind, cleared or not; `cleared` reflects the final outcome (incl. Mr Bones).
      do
        local plays = {}
        for _, p in ipairs(result.plays or {}) do
          plays[#plays + 1] = { kind = p.kind, hand_type = p.hand_type, score = p.score,
            selected = Json.array(p.selected or {}),
            hands_left_after = p.hands_left_after, discards_left_after = p.discards_left_after,
            avail = p.avail, draw_left = p.draw_left }
        end
        emit({ kind = "blind_result", ante = ante, blind_type = result.blind_type, boss_key = result.boss_key,
               cleared = result.cleared, scored = result.scored, target = result.target,
               hands_used = result.hands_used, hands_left = result.hands_left,
               discards_left = result.discards_left, plays = Json.array(plays),
               money_gap = result.money_gap })   -- telemetry only (tools/money_gap.lua)
      end
      -- P4: consumable USE records (key, target cards, realized effect) applied in-blind.
      for _, u in ipairs(result.consumable_uses or {}) do
        emit({ kind = "consumable_use", ante = ante, key = u.key, set = u.set, hand = u.hand,
               levels = u.levels, money_delta = u.money_delta,
               shape = u.shape and u.shape.shape or nil,
               shape_suit = u.shape and u.shape.suit or nil,
               shape_n = u.shape and u.shape.n or nil,
               target = u.target and Json.array(u.target) or nil })
      end
      if not result.cleared then
        local b = board(run)
        emit({ kind = "death", gen_made = run._gen_made, gen_used = run._gen_used, ante = ante, blind_type = blind.type, boss = (blind.type == "Boss"),
               boss_key = blind.boss_key, target = result.target, scored = result.scored,
               ratio = (result.target > 0) and (result.scored / result.target) or nil,
               dollars = b.dollars, njokers = b.njokers, jokers = b.jokers,
               hand_level_sum = b.hand_level_sum, consumables = b.consumables,
               metrics = metrics(run) })
        run.dead = true
        return { records = recs, won = false, death_ante = ante, seed = seed }
      end
      -- A5: run-history counters for the Handy/Garbage tags ($1 per hand played / unused discard).
      run._hands_played = (run._hands_played or 0) + (result.hands_used or 0)
      run._unused_discards = (run._unused_discards or 0) + math.max(0, result.discards_left or 0)
      World.award_income(run, result)
      -- A1: end-of-round joker tick (Popcorn decay; Gros Michel/Cavendish self-destruct).
      -- A cleared blind = one "round". Emit a joker_loss for anything that self-destructed
      -- so the trace/board stays consistent (not counted as a "sell").
      for _, j in ipairs(World.round_end_tick(run)) do
        emit({ kind = "joker_loss", ante = ante, key = j.key, via = "destroy" })
      end
      -- a defeated boss resets Campfire (x1) and pays out tag-deferred money (Investment $25),
      -- THEN the shop opens
      if blind.type == "Boss" then World.boss_clear_tick(run) end
      if blind.type == "Boss" and content.on_boss_cleared then content.on_boss_cleared(run) end
      -- the next ante's boss is rolled now, as in the game, so the post-boss shop knows it
      if blind.type == "Boss" and World.preroll_next_boss then World.preroll_next_boss(run) end
      -- SHOP: generate offerings + let the engine spend (injected; no-op stub by default).
      -- emit forwards the action trace (shop offers/advice, buys, sells, packs) into the
      -- run's records, so analyze_runs surfaces what it bought AND what it SKIPPED.
      run._next_blind = (blind.type == "Small" and "Big") or (blind.type == "Big" and "Boss") or "Small"
      run._ante_blinds, run._blind_idx = blinds, bi       -- where a look-ahead fork resumes (no rng)
      World.checkpoint(run, "shop", ante, run.round)      -- the shop's first offers
      content.shop_phase(run, { rng = run.rng, emit = emit })
      ::next_blind::
    end
    -- ante cleared (boss beaten). W4: a pending Hieroglyph -1 ante REPLAYS this ante
    -- (fresh blinds/boss/shops at the same requirements = the extra ante of runway),
    -- and is consumed before the win check so an ante-8 purchase can't win for free.
    if (run._ante_back or 0) > 0 then
      run._ante_back = run._ante_back - 1
      run._voucher_ante = nil   -- the replayed ante restocks the voucher slot like any new ante
    else
      if ante >= 8 then
        run.won = true
        emit({ kind = "win", gen_made = run._gen_made, gen_used = run._gen_used, ante = ante, dollars = run.economy.dollars,
               njokers = #(run.jokers or {}), jokers = Json.array(joker_keys(run)) })
        return { records = recs, won = true, death_ante = nil, seed = seed }
      end
      ante = ante + 1
    end
  end
  return { records = recs, won = run.won or false, death_ante = nil, seed = seed }
end

-- MCTS Phase 2: roll a FORKED run forward under the greedy policy to a horizon, silently, and
-- return the leaf value. Reuses Driver.run's exact loop (opts.run + opts.silent), so a rollout is
-- byte-faithful to a real run. value = 1 on a win, 0 on a death, else pace_margin at the reached
-- horizon (the leaf V validated in Phase 1: weak early / strong late, so roll to ~ante 5+ before
-- trusting it). `opts.content` MUST be the real content module (the greedy shop policy); with the
-- default stub the rollout dies early (no shop). See docs/archive/MCTS_PLAN.md §5.
function Driver.rollout(fork, opts)
  opts = opts or {}
  local horizon = opts.horizon or opts.max_ante or 8
  local res = Driver.run(fork.seed, { run = fork, content = opts.content, max_ante = horizon, silent = true })
  local value
  if res.won then value = 1.0
  elseif res.death_ante then value = 0.0
  else value = (metrics(fork).pace_margin or 0) end   -- survived to horizon: leaf = pace_margin
  return { won = res.won, death_ante = res.death_ante,
           survived = (res.death_ante == nil), value = value, final_ante = fork.ante }
end

-- Run a batch of seeds, append all records to a JSONL file (sim output that
-- tools/analyze_runs.lua reads exactly like live telemetry). Returns a small summary.
function Driver.batch(seeds, opts, out_path)
  opts = opts or {}
  local fh = out_path and assert(io.open(out_path, "w")) or nil
  local wins, deaths = 0, {}
  for _, seed in ipairs(seeds) do
    local res = Driver.run(seed, opts)
    if res.won then wins = wins + 1 elseif res.death_ante then deaths[res.death_ante] = (deaths[res.death_ante] or 0) + 1 end
    if fh then for _, r in ipairs(res.records) do fh:write(Json.encode(r) .. "\n") end end
  end
  if fh then fh:close() end
  return { n = #seeds, wins = wins, deaths_by_ante = deaths, out = out_path }
end

return Driver
