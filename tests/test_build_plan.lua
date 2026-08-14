-- tests/test_build_plan.lua
-- The build-PLANNING layer: value jokers toward the compounding core (xmult multiplies a
-- scoring base), invest only when behind-but-viable, and damp additive dilution. Pure.

local BP = require("engine.build_plan")
local GS = require("model.game_state")

return function(t)
  local function board(keys)
    local jk = {}; for _, k in ipairs(keys) do jk[#jk + 1] = { key = k } end
    return GS.new{ jokers = jk }
  end

  -- ---- analyze: classifies the board's compounding structure ----
  do
    local a = BP.analyze(board({ "j_even_steven", "j_jolly", "j_todo_list" }))
    t.eq(a.n_flat, 2, "two flat-mult jokers counted as flat")
    t.eq(a.n_econ, 1, "one economy joker counted as econ")
    t.eq(a.base, 2, "base = additive scorers (flat + scaling), not econ")
    t.ok(a.needs_xmult, "a board with a scoring base but no xmult NEEDS an xmult")
    local bare = BP.analyze(board({ "j_joker" }))
    t.ok(not bare.needs_xmult, "a bare board (base < 2) does NOT prioritise xmult (no base to multiply)")
  end

  -- ---- level_need (P3-1): additive leveling nudge, gated on core + low levels ----
  do
    -- core present (1 xmult over base 2) but NO levels -> a positive nudge
    local core = board({ "j_cavendish", "j_even_steven", "j_jolly" })
    local n0 = BP.level_need(core)
    t.ok(n0 > 0, "core board with 0 levels gets a positive leveling nudge")
    -- bare board (no xmult core) -> no nudge (no early over-buy)
    t.eq(BP.level_need(board({ "j_even_steven", "j_jolly" })), 0, "no xmult core -> no leveling nudge")
    -- xmult but no base to multiply -> no nudge
    t.eq(BP.level_need(board({ "j_cavendish" })), 0, "xmult with base<2 -> no leveling nudge")
    -- core present but already leveled past the target -> nudge tapers to 0
    core.run.hand_levels = { ["Two Pair"] = { level = 1 + BP.LEVEL_NEED_TARGET } }
    t.eq(BP.level_need(core), 0, "core board leveled past target -> nudge gone")
    -- monotone: fewer levels -> larger nudge
    core.run.hand_levels = { ["Two Pair"] = { level = 2 } }  -- 1 level above base
    local n1 = BP.level_need(core)
    t.ok(n0 > n1 and n1 > 0, "nudge shrinks as levels rise")
  end

  -- ---- fit: invest window credits the missing compounding axis ----
  do
    local gs = board({ "j_even_steven", "j_jolly" })   -- base = 2, no xmult
    local plan = BP.analyze(gs)
    -- INVEST window: an xmult (multiplies the base) is credited; on a BARE board it is not.
    local fit_x = (BP.fit(gs, { key = "j_cavendish" }, plan, true))
    t.ok(fit_x > 0, "invest: an xmult that multiplies the base gets a positive planning fit")
    local bare = board({ "j_joker" })
    local fit_bare = (BP.fit(bare, { key = "j_cavendish" }, BP.analyze(bare), true))
    t.eq(fit_bare, 0, "invest but NO base: xmult gets no fit (this is the anti-backfire gate)")
    -- when NOT investing (on pace / hopeless), the xmult bonus stands down
    local fit_noinvest = (BP.fit(gs, { key = "j_cavendish" }, plan, false))
    t.eq(fit_noinvest, 0, "not investing: no xmult planning bonus (buy what scores now)")
  end

  -- ---- fit: dilution penalty (applies regardless of invest) ----
  do
    local gs = board({ "j_even_steven", "j_jolly" })   -- 2 flat already (>= FLAT_CAP)
    local plan = BP.analyze(gs)
    local fit_flat = (BP.fit(gs, { key = "j_greedy_joker" }, plan, false))
    t.ok(fit_flat < 0, "a redundant flat-mult joker is damped (dilutes a slot)")
    local econgs = board({ "j_todo_list", "j_faceless" })  -- 2 econ already
    local fit_econ = (BP.fit(econgs, { key = "j_delayed_grat" }, BP.analyze(econgs), false))
    t.ok(fit_econ < 0, "a redundant econ joker is damped (money isn't the win condition)")
  end

  -- ---- sell-side core protection: don't dump a low-measuring xmult/scaler ----
  do
    t.ok(BP.is_core("j_cavendish"), "an xmult is a core piece")
    t.ok(BP.is_core("j_ride_the_bus"), "a scaler is a core piece")
    t.ok(not BP.is_core("j_joker"), "a flat-mult joker is not a core piece")
    t.ok(not BP.is_core("j_todo_list"), "an econ joker is not a core piece")
    t.ok(BP.keep_bias("j_cavendish") > BP.keep_bias("j_joker"), "core protected MORE than a flat scorer")
    t.ok(BP.keep_bias("j_joker") > 0, "a flat scorer is protected too (it contributes chips/mult)")
    t.eq(BP.keep_bias("j_todo_list"), 0, "econ/utility filler gets no keep-bias (sold first)")
  end

  -- ---- retriggers are core (live divergence mine, 2026-08-13) ----
  -- A retrigger multiplies what the rest of the board does, but carries no handtype tag, so
  -- BP.fit gave it no commitment credit while a suit-matching flat common got +COMMIT_JOKER_FILL.
  -- Unprotected, that swapped a tier-6 retrigger out for tier-3 commons: the live log advised
  -- "Sell Dusk -- frees a slot for Scary Face" 16 times in a run Dusk finished on the board.
  do
    for _, k in ipairs({ "j_dusk", "j_hanging_chad", "j_sock_and_buskin", "j_mime",
                         "j_hack", "j_selzer" }) do
      t.ok(BP.is_retrigger(k), k .. " is recognised as a retrigger")
      t.eq(BP.keep_bias(k), BP.CORE_KEEP, k .. " is protected like a core piece")
    end
    t.ok(BP.keep_bias("j_dusk") > BP.keep_bias("j_scary_face"),
      "a retrigger is protected MORE than the flat common the engine wanted to swap it for")
  end

  -- ---- leveling axis (B1): leveling compounds through the board's xmult ----
  do
    t.eq(BP.level_amplifier(GS.new{ jokers = { { key = "j_joker" } } }), 1.0,
      "no xmult -> leveling amplifier is 1.0 (no early over-buy of planets on a bare board)")
    local one = BP.level_amplifier(GS.new{ jokers = { { key = "j_cavendish" } } })
    local two = BP.level_amplifier(GS.new{ jokers = { { key = "j_cavendish" }, { key = "j_baron" } } })
    t.ok(one > 1.0, "one xmult -> leveling worth more (the level multiplies through it)")
    t.ok(two > one, "more xmult -> leveling worth even more (compounds through the core)")
    t.ok(BP.level_amplifier(GS.new{ jokers = {
      { key = "j_cavendish" }, { key = "j_baron" }, { key = "j_stencil" }, { key = "j_loyalty_card" } } })
      <= BP.LEVEL_AMP_CAP + 1e-9, "the amplifier is bounded (it's an estimate, not a measurement)")
  end

  -- ---- invest window: behind-but-viable, not hopeless, not on pace ----
  do
    t.ok(BP.invest_window({ on_pace = false, margin = 0.5 }), "behind + viable -> invest")
    t.ok(not BP.invest_window({ on_pace = true, margin = 2.0 }), "on pace -> don't force-invest")
    t.ok(not BP.invest_window({ on_pace = false, margin = 0.05 }), "hopeless (tiny margin) -> survive now, don't invest")
    t.ok(not BP.invest_window(nil), "no pacing assessment -> no invest window")
  end

  -- ---- Phase 5: sticky committed-archetype planner ----
  do
    local duo = board({ "j_duo" })
    duo.meta.ante = 2
    local cp = BP.advance(duo, nil)
    t.eq(cp.kind, "hand", "a conditional xmult is a sufficient commitment anchor")
    t.eq(cp.hand, "Pair", "Duo commits to the Pair family")

    local stack = board({ "j_duo", "j_trio" })
    stack.meta.ante = 2
    t.eq(BP.advance(stack, nil).hand, "Full House", "Duo + Trio commit to their shared Full House payoff")

    local two_pair = board({ "j_trousers", "j_mad" })
    two_pair.meta.ante = 3
    t.eq(BP.advance(two_pair, nil).hand, "Two Pair", "matching scaler + scorer can anchor commitment")

    local econ = board({ "j_bull", "j_to_the_moon" })
    econ.meta.ante = 3
    t.eq(BP.advance(econ, nil).kind, "economy", "bankroll converter + economy support commits economy")

    local empty = board({})
    empty.meta.ante = 4
    t.eq(BP.advance(empty, cp), cp, "an existing commitment persists through loss/dip of its anchors")

    -- E-10a (threshold 3.0 -> 2.5): a real-but-thinner anchor commits now. Four Fingers
    -- (hand_modifier, 1.5 on Flush) + a level-2 Flush (+1) = 2.5 -- below the old bar,
    -- at the new one. 106/160 runs were uncommitted, starving the planner layer.
    local thin = board({ "j_four_fingers" })
    thin.meta.ante = 2
    thin.run = { hand_levels = { Flush = { level = 2 } } }
    local tc = BP.advance(thin, nil)
    t.ok(tc ~= nil and tc.kind == "hand" and tc.hand == "Flush",
      "E-10a: hand_modifier + one level (2.5) commits at the widened threshold")
    -- and a bare 2.0 anchor still does NOT commit (a lone scaler stays out)
    local lone = board({ "j_trousers" })
    lone.meta.ante = 2
    t.ok(BP.advance(lone, nil) == nil, "a lone scaler (2.0) still does not commit")

    -- ---- the four hands the planner used to be BLIND to (2026-08-11) ----
    -- The one human WIN committed to Five of a Kind and leveled it nine times; under the
    -- old HAND_ORDER those levels scored ZERO and the planner could never commit to it.
    do
      -- sunk levels in a secret hand now register as a commitment signal
      local secret = board({ "j_duo" })
      secret.meta.ante = 3
      secret.run = { hand_levels = { ["Five of a Kind"] = { level = 5 } } }
      local sc = BP.advance(secret, nil)
      t.ok(sc ~= nil and sc.hand == "Five of a Kind",
        "four sunk levels in Five of a Kind now anchor a commitment to it")

      -- ...but ONLY via sunk levels: a bare board never commits to a secret hand
      -- speculatively (there are no handtype: tags pointing at one)
      local bare = board({ "j_duo", "j_trio" })
      bare.meta.ante = 3
      bare.run = { hand_levels = {} }
      local bc = BP.advance(bare, nil)
      t.ok(bc == nil or bc.hand ~= "Five of a Kind",
        "no levels -> the planner never commits to a secret hand speculatively")

      -- Straight Flush is likewise reachable now
      local sf = board({ "j_four_fingers" })
      sf.meta.ante = 2
      sf.run = { hand_levels = { ["Straight Flush"] = { level = 4 } } }
      t.eq(BP.advance(sf, nil).hand, "Straight Flush", "Straight Flush can anchor a commitment")
    end

    -- CONTAINS semantics: a run committed to a strong hand still fires its weak-hand jokers
    do
      t.ok(BP.hand_matches("Five of a Kind", "Pair"), "Five of a Kind contains Pair")
      t.ok(BP.hand_matches("Five of a Kind", "Four of a Kind"), "Five of a Kind contains Four of a Kind")
      t.ok(BP.hand_matches("Flush House", "Flush"), "Flush House contains Flush")
      t.ok(BP.hand_matches("Flush House", "Full House"), "Flush House contains Full House")
      t.ok(BP.hand_matches("Flush Five", "Five of a Kind"), "Flush Five contains Five of a Kind")
      t.ok(BP.hand_matches("Straight Flush", "Straight"), "Straight Flush contains Straight")
      t.ok(BP.hand_matches("Straight Flush", "Flush"), "Straight Flush contains Flush")
      -- and the relation stays one-way (a Pair hand does not fire Five-of-a-Kind jokers)
      t.ok(not BP.hand_matches("Pair", "Five of a Kind"), "containment is one-way")
      t.ok(not BP.hand_matches("Five of a Kind", "Flush"), "Five of a Kind does NOT contain Flush")
    end

    local committed = board({ "j_duo", "j_jolly" })
    committed.run.build_plan = cp
    local plan = BP.analyze(committed); plan.commit_active = true
    local on = BP.fit(committed, { key = "j_jolly" }, plan, false)
    local off = BP.fit(committed, { key = "j_droll" }, plan, false)
    t.ok(on > off, "committed plan credits matching jokers over off-plan hand payoffs")
    t.ok(BP.keep_bias("j_jolly", committed) > BP.keep_bias("j_jolly"),
      "matching committed scorer is protected through its early dip")

    committed.run.hand_levels = {}
    t.ok(BP.planet_credit(committed, "Pair") > 0, "committed hand gets concentrated leveling credit")
    t.eq(BP.planet_credit(committed, "Flush"), 0, "off-plan planet gets no commitment credit")
    committed.run.hand_levels.Pair = { level = 1 + BP.COMMIT_LEVEL_TARGET }
    t.eq(BP.planet_credit(committed, "Pair"), 0, "leveling credit tapers away at its target")
  end

  -- ---- Phase 5 refinement: one-shot upgrade of a WEAK (anchor-less) commitment ----
  do
    -- a level-only Straight (locked in early from planet luck; 3 sunk levels, no straight joker)
    local function weak_straight() return { kind = "hand", hand = "Straight", committed_ante = 1, strength = 3, anchors = {} } end

    -- a real multi-joker Full House core later emerges (Duo + Trio, 2 anchors, FH signal 5)
    local emerged = board({ "j_duo", "j_trio" }); emerged.meta.ante = 3
    emerged.run.hand_levels = { Straight = { level = 4 } }   -- 3 levels sunk into the weak hand
    local up = BP.advance(emerged, weak_straight())
    t.eq(up.hand, "Full House", "a level-only commitment upgrades to the emerged multi-joker core")
    t.ok(up.upgraded, "the upgrade is flagged (one-shot)")
    t.eq(up.upgraded_from, "Straight", "the upgrade records the abandoned hand")

    -- a WELL-leveled weak hand is not abandoned for a only-marginally-stronger core (sunk cost)
    local rich = board({ "j_duo", "j_trio" }); rich.meta.ante = 3
    rich.run.hand_levels = { Straight = { level = 6 } }       -- 5 levels -> incumbent signal high
    t.eq(BP.advance(rich, weak_straight()).hand, "Straight",
      "a well-leveled weak hand is kept when the new core only marginally beats it")

    -- a single joker anchor is NOT a real core -> no upgrade
    local one = board({ "j_duo" }); one.meta.ante = 3
    t.eq(BP.advance(one, weak_straight()).hand, "Straight",
      "a single joker anchor cannot trigger an upgrade (needs a multi-joker core)")

    -- upgrades fire at most once
    local again = board({ "j_duo", "j_trio" }); again.meta.ante = 3
    local done = weak_straight(); done.upgraded = true
    t.eq(BP.advance(again, done), done, "an already-upgraded commitment cannot upgrade again")

    -- a LIVE-anchored commitment never upgrades away (its hand has a real joker backing it)
    local live = board({ "j_duo", "j_trio" }); live.meta.ante = 3
    t.eq(BP.advance(live, { kind = "hand", hand = "Pair", committed_ante = 1, anchors = { "j_duo" } }).hand,
      "Pair", "a live-anchored commitment is never upgraded away")

    -- no late pivots that can't mature
    local late = board({ "j_duo", "j_trio" }); late.meta.ante = BP.UPGRADE_MAX_ANTE + 1
    late.run.hand_levels = { Straight = { level = 4 } }
    t.eq(BP.advance(late, weak_straight()).hand, "Straight", "no upgrade past UPGRADE_MAX_ANTE")

    -- a weak economy commitment can upgrade to an emerged hand core
    local econ_up = board({ "j_duo", "j_trio" }); econ_up.meta.ante = 3
    local eu = BP.advance(econ_up, { kind = "economy", committed_ante = 2, strength = 4 })
    t.eq(eu.hand, "Full House", "a weak economy commitment upgrades to an emerged multi-joker core")
    t.eq(eu.upgraded_from, "economy", "the economy->hand upgrade is recorded")
  end

  -- ---- Phase 5 V2c: the "finishing move" leveling push (committed + banked + ante>=4) ----
  -- Evidence (n=160 p5_w4): all 6 ante-8 runs had ONE hand hard-leveled to 8-12 via
  -- Celestial/Orbital; the 2 that died AT ante 8 had core + economy but hand-lv <= 2.
  do
    local plan = { kind = "hand", hand = "Pair", committed_ante = 2, strength = 4 }
    local function state(ante, cash, p, levels)
      local gs = board({ "j_duo", "j_jolly" })
      gs.meta.ante = ante
      gs.economy.dollars = cash
      gs.run.build_plan = p
      gs.run.hand_levels = levels or {}
      return gs
    end

    -- gate CLOSED -> V1 behaviour byte-identical (nothing decreases, nothing increases)
    t.eq(BP.planet_credit(state(3, 25, plan), "Pair"), BP.COMMIT_LEVEL_CREDIT,
      "gate closed (ante < PUSH_MIN_ANTE): the V1 credit is unchanged")
    t.eq(BP.planet_credit(state(5, BP.PUSH_MIN_DOLLARS - 1, plan), "Pair"), BP.COMMIT_LEVEL_CREDIT,
      "gate closed (below the bank threshold): the V1 credit is unchanged")
    t.eq(BP.planet_credit(state(5, 25, nil), "Pair"), 0,
      "uncommitted: no credit at all, however rich/late")
    t.ok(not BP.level_push_active(state(5, 25, { kind = "economy", committed_ante = 2 })),
      "an economy commitment never opens the leveling-push gate")
    t.ok(not BP.level_push_active(state(3, 25, plan)), "early ante keeps the gate shut")
    t.ok(not BP.level_push_active(state(5, 10, plan)), "a thin bank keeps the gate shut")

    -- gate OPEN -> the committed hand's credit is LEVEL_PUSH x; a non-committed hand stays 0
    local open = state(BP.PUSH_MIN_ANTE, BP.PUSH_MIN_DOLLARS, plan)
    t.ok(BP.level_push_active(open), "committed + banked + ante>=4 opens the gate")
    t.eq(BP.planet_credit(open, "Pair"), BP.LEVEL_PUSH * BP.COMMIT_LEVEL_CREDIT,
      "gate open: the committed hand's leveling credit is LEVEL_PUSH x the V1 credit")
    t.eq(BP.planet_credit(open, "Flush"), 0,
      "gate open: a NON-committed hand still gets no credit")

    -- the push keeps paying PAST the V1 taper target (the winners finished at hand-lv 8-12)
    local past = { Pair = { level = 1 + BP.COMMIT_LEVEL_TARGET } }
    t.eq(BP.planet_credit(state(5, 10, plan, past), "Pair"), 0,
      "gate closed: the credit still tapers out at the V1 target")
    t.ok(BP.planet_credit(state(5, 25, plan, past), "Pair") > 0,
      "gate open: the push persists past the V1 target (finish the hand to 8-12)")
    t.eq(BP.planet_credit(state(5, 25, plan, { Pair = { level = 1 + BP.PUSH_LEVEL_TARGET } }), "Pair"), 0,
      "the push tapers out at PUSH_LEVEL_TARGET (no runaway)")

    -- increase-only at EVERY level: gate open >= gate closed (the additive-boost shape)
    local monotone = true
    for n = 0, BP.PUSH_LEVEL_TARGET do
      local levels = { Pair = { level = 1 + n } }
      local closed = BP.planet_credit(state(5, 10, plan, levels), "Pair")
      local opened = BP.planet_credit(state(5, 25, plan, levels), "Pair")
      if opened < closed then monotone = false end
    end
    t.ok(monotone, "the gate can only RAISE the credit, at every level (increase-only)")

    -- deterministic: pure arithmetic, no rng, no cache -> identical on re-evaluation
    t.eq(BP.planet_credit(open, "Pair"), BP.planet_credit(open, "Pair"),
      "planet_credit is deterministic (same state -> same value)")
  end

  -- ---- EARNED DIRECTION: credit the hands the run actually PLAYS ----
  -- The planner was blind to its own play history: 63% of runs never committed, and 42.6%
  -- of the commitments that did happen pointed at a hand taking under 20% of plays. The
  -- guard that matters is that this can never commit a run on play share ALONE.
  do
    local function played(keys, plays, levels)
      local gs = board(keys)
      gs.run.hand_type_plays = plays
      gs.run.hand_levels = levels or {}
      return gs
    end

    -- The credit is capped below the threshold, so play share can never manufacture an
    -- ANCHORED commitment -- the kind that steers joker buying and deck shaping. A run that
    -- plays one hand exclusively still gets only the leveling-only play-derived plan below.
    t.ok(BP.PLAY_CREDIT < BP.COMMIT_THRESHOLD,
      "the play credit is capped BELOW the commit threshold by construction")
    local pure = played({ "j_joker" }, { ["Two Pair"] = 20 })
    t.eq(BP.advance(pure, nil).via, "played",
      "play share alone yields a play-derived plan, never an anchored one")
    t.eq(BP.anchored_commitment({ run = { build_plan = BP.advance(pure, nil) } }), nil,
      "...which reads as uncommitted in every non-leveling channel")

    -- the target band: TWO matching hand-commons score exactly 2.0 against a 2.5 gate --
    -- nothing in the measured distribution falls between them -- so a run that also LANDS
    -- that hand should now cross. Without the play history it must not.
    local pair_jokers = { "j_jolly", "j_sly" }          -- both handtype:pair, 1.0 each
    local blind_run = played(pair_jokers, nil)
    t.eq(BP.advance(blind_run, nil), nil, "two matching commons alone stay under the gate")
    local landing = played(pair_jokers, { Pair = 10, Flush = 2, ["High Card"] = 3 })
    local plan = BP.advance(landing, nil)
    t.ok(plan and plan.kind == "hand" and plan.hand == "Pair",
      "two matching commons PLUS actually landing the hand commits to it")

    -- below the sample floor the credit is silent (don't read a direction off three hands)
    local tiny = played(pair_jokers, { Pair = 3 })
    t.eq(BP.advance(tiny, nil), nil, "under PLAY_MIN_SAMPLE the play credit does not fire")

    -- incidental hands earn nothing: at/below PLAY_FLOOR the credit is exactly zero
    local s_lo = BP.signals(played({ "j_joker" }, { Pair = 2, Flush = 8 }))
    t.eq(s_lo.Pair or 0, 0, "a hand at/below PLAY_FLOOR share earns no credit")

    -- monotone in share, and saturating at PLAY_FULL (no runaway from a lucky streak)
    local prev = -1
    local monotone = true
    for k = 0, 10 do
      local s = BP.signals(played({ "j_joker" }, { Pair = k, ["High Card"] = 10 - k }))
      local v = s.Pair or 0
      if v < prev then monotone = false end
      prev = v
    end
    t.ok(monotone, "the play credit is monotone in play share")
    local sat = BP.signals(played({ "j_joker" }, { Pair = 100 }))
    t.eq(sat.Pair, BP.PLAY_CREDIT, "the credit saturates at PLAY_CREDIT")

    -- deterministic: no rng, no iteration-order dependence in the VALUE
    local a = BP.signals(played(pair_jokers, { Pair = 10, Flush = 4 }))
    local b = BP.signals(played(pair_jokers, { Pair = 10, Flush = 4 }))
    t.eq(a.Pair, b.Pair, "the play credit is deterministic")
  end

  -- ---- PLAY-DERIVED COMMITMENT: provisional, and LEVELING-ONLY ----
  -- The credit above cannot rescue a board with no anchor at all, and that is most boards --
  -- the planner can read 12.7% of a real board, and the winners' boards are hand-agnostic
  -- (Hanging Chad appears in 7 of 7 human wins and carries no handtype tag). So a run that
  -- clearly LANDS one hand may commit to it with no anchor -- but only for the leveling
  -- channel, and only provisionally.
  do
    local function played(keys, plays)
      local gs = board(keys)
      gs.run.hand_type_plays = plays
      return gs
    end

    -- commits with NO joker anchor whatever, on play history alone
    local gs = played({ "j_joker" }, { Flush = 8, Pair = 4, ["High Card"] = 3 })
    local plan = BP.advance(gs, nil)
    t.ok(plan and plan.hand == "Flush" and plan.via == "played",
      "a run that clearly lands one hand commits to it with no anchor")

    -- ...but only when it is CLEAR: a near-tie commits to neither
    local tie = played({ "j_joker" }, { Flush = 8, Pair = 7 })
    t.eq(BP.advance(tie, nil), nil, "a near-tie between two hands commits to neither")
    local thin = played({ "j_joker" }, { Flush = 4, Pair = 3, Straight = 3, ["High Card"] = 5 })
    t.eq(BP.advance(thin, nil), nil, "a hand under PLAY_COMMIT_SHARE does not commit")
    t.eq(BP.advance(played({ "j_joker" }, { Flush = 5 }), nil), nil,
      "under PLAY_MIN_SAMPLE there is no play-derived commitment either")

    -- LEVELING-ONLY: it drives planet_credit but is invisible to every other channel
    gs.run.build_plan = plan
    t.ok(BP.planet_credit(gs, "Flush") > 0, "a play-derived plan DOES drive the leveling credit")
    t.eq(BP.anchored_commitment(gs), nil, "...and reads as uncommitted everywhere else")
    t.eq(BP.keep_bias("j_droll", gs), BP.keep_bias("j_droll", board({ "j_joker" })),
      "keep_bias is unchanged by a play-derived plan (no new sell-side override)")
    local bare = board({ "j_joker" })
    t.eq(BP.fit(gs, { key = "j_droll" }, BP.analyze(gs), true),
         BP.fit(bare, { key = "j_droll" }, BP.analyze(bare), true),
      "BP.fit is unchanged by a play-derived plan")

    -- PROVISIONAL: re-derives as the run develops, instead of locking in an early reading
    local moved = played({ "j_joker" }, { Flush = 8, ["Two Pair"] = 20 })
    local plan2 = BP.advance(moved, plan)
    t.ok(plan2 and plan2.hand == "Two Pair",
      "a provisional plan follows the run when the hand it actually lands changes")

    -- ...and a real joker anchor supersedes it, after which the plan is sticky
    local anchored = played({ "j_tribe", "j_droll" }, { ["Two Pair"] = 20, Flush = 8 })
    local plan3 = BP.advance(anchored, plan)
    t.ok(plan3 and plan3.hand == "Flush" and plan3.via == nil,
      "a real joker anchor supersedes the provisional plan")
    local later = played({ "j_tribe", "j_droll" }, { ["Two Pair"] = 99 })
    t.eq(BP.advance(later, plan3).hand, "Flush", "...and the anchored plan is then sticky")

    -- the commit window still closes: past COMMIT_MAX_ANTE nothing new is committed
    local late = played({ "j_joker" }, { Flush = 20 })
    late.meta.ante = BP.COMMIT_MAX_ANTE + 1
    t.eq(BP.advance(late, nil), nil, "the commit window still closes on the play-derived path")
  end
end
