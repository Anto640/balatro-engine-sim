-- tests/test_simulation.lua
-- Tests for probability (exact), simulation (seeded MC: bounds + monotonicity +
-- exact outs), and the eval function (bounds + ordering). Pure / headless.

local Prob = require("engine.probability")
local Sim = require("engine.simulation")
local Eval = require("engine.eval_function")
local GS = require("model.game_state")
local card, joker = GS.card, GS.joker

-- Deterministic Park-Miller RNG so MC results are reproducible across runs.
local function lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()
    s = (s * 16807) % 2147483647
    return (s - 1) / 2147483646
  end
end

return function(t)
  -- ---- probability: exact closed form ----
  t.near(Prob.comb(5, 2), 10, "C(5,2)=10")
  t.near(Prob.comb(52, 5), 2598960, "C(52,5)")
  t.near(Prob.at_least_one(9, 47, 1), 9 / 47, "flush draw, 1 draw = 9/47")
  -- exact: 1 - C(38,5)/C(47,5) = 1 - 501942/1533939
  t.near(Prob.at_least_one(9, 47, 5), 1 - 501942 / 1533939, "flush draw, 5 draws", 1e-9)
  t.near(Prob.pmf(0, 9, 47, 1), 38 / 47, "P(0 outs in 1 draw)")
  t.near(Prob.expected(9, 47, 5), 5 * 9 / 47, "expected outs in 5 draws")
  -- pmf is a valid distribution
  do
    local s = 0
    for k = 0, 5 do s = s + Prob.pmf(k, 9, 47, 5) end
    t.near(s, 1.0, "pmf sums to 1", 1e-9)
  end
  -- monotone in draws
  t.ok(Prob.at_least_one(9, 47, 3) > Prob.at_least_one(9, 47, 1), "more draws -> higher prob")

  -- ---- simulation: survival bounds + monotonicity ----
  local function pair_state(target)
    return GS.new{
      hand = {
        card{ id = 1, rank = "King", suit = "Spades" },
        card{ id = 2, rank = "King", suit = "Hearts" },
        card{ id = 3, rank = "7", suit = "Clubs" },
        card{ id = 4, rank = "3", suit = "Diamonds" },
        card{ id = 5, rank = "2", suit = "Spades" },
      },
      remaining = {
        card{ id = 6, rank = "9", suit = "Hearts" },
        card{ id = 7, rank = "4", suit = "Clubs" },
      },
      blind = { target_chips = target, chips_scored = 0, hands_left = 2, discards_left = 1 },
      run = { hand_levels = {}, hand_size = 5 },
    }
  end

  local easy = Sim.survive_current(pair_state(30), 50, lcg(1))
  local hard = Sim.survive_current(pair_state(1e9), 50, lcg(1))
  t.eq(easy, 1.0, "trivial target -> always survive")
  t.eq(hard, 0.0, "impossible target -> never survive")
  t.ok(easy >= 0 and easy <= 1, "survival in [0,1]")

  -- ---- survive_after (F1/F2): forced-first-action survival value ----
  do
    local gs = pair_state(400)
    local play = { gs.hand[1], gs.hand[2] }        -- play the pair of Kings
    local disc = { gs.hand[3], gs.hand[4], gs.hand[5] }  -- pitch the low junk
    local vp = Sim.survive_after(gs, { kind = "PLAY", sel = play }, 40, lcg(7))
    local vd = Sim.survive_after(gs, { kind = "DISCARD", cards = disc }, 40, lcg(7))
    t.ok(vp.frac >= 0 and vp.frac <= 1, "survive_after PLAY frac in [0,1]")
    t.ok(vd.clear >= 0 and vd.clear <= 1, "survive_after DISCARD clear in [0,1]")
    -- CRN determinism: same seed -> identical result (a precondition of paired arbitration)
    local vp2 = Sim.survive_after(gs, { kind = "PLAY", sel = play }, 40, lcg(7))
    t.eq(vp.frac, vp2.frac, "survive_after is deterministic for a fixed seed")
    -- a trivial target is always cleared regardless of the first move
    local triv = Sim.survive_after(pair_state(1), { kind = "PLAY", sel = play }, 20, lcg(1))
    t.eq(triv.clear, 1.0, "trivial target -> survive_after clear = 1")
  end

  -- ---- simulation: exact outs for a flush draw ----
  do
    local gs = GS.new{
      hand = {
        card{ id = 1, rank = "2", suit = "Hearts" },
        card{ id = 2, rank = "5", suit = "Hearts" },
        card{ id = 3, rank = "9", suit = "Hearts" },
        card{ id = 4, rank = "King", suit = "Hearts" },
        card{ id = 5, rank = "3", suit = "Spades" },
      },
      remaining = {
        card{ id = 6, rank = "7", suit = "Hearts" },   -- out
        card{ id = 7, rank = "Jack", suit = "Hearts" },-- out
        card{ id = 8, rank = "4", suit = "Spades" },
        card{ id = 9, rank = "8", suit = "Clubs" },
        card{ id = 10, rank = "Queen", suit = "Spades" },
      },
      run = { hand_levels = {}, hand_size = 8 },
    }
    local o = Sim.outs(gs)
    t.eq(o.target, "flush", "outs target = flush")
    t.eq(o.count, 2, "2 heart outs in remaining")
    t.eq(o.population, 5, "population = 5 unseen")
    t.eq(o.draws, 1, "discarding 1 card => 1 draw")
    t.near(o.prob, 1 - 3 / 5, "P(complete) = 1 - C(3,1)/C(5,1) = 0.4")
  end

  -- ---- discard-aware rollout: a discard that completes a draw raises survival ----
  do
    local function flush_chase(discards)
      return GS.new{
        hand = {
          card{ id = 1, rank = "2", suit = "Hearts" },
          card{ id = 2, rank = "5", suit = "Hearts" },
          card{ id = 3, rank = "9", suit = "Hearts" },
          card{ id = 4, rank = "King", suit = "Hearts" }, -- 4 to a heart flush
          card{ id = 5, rank = "3", suit = "Spades" },    -- the off-suit to pitch
        },
        remaining = {
          card{ id = 6, rank = "4", suit = "Hearts" },    -- outs
          card{ id = 7, rank = "7", suit = "Hearts" },
          card{ id = 8, rank = "10", suit = "Hearts" },
          card{ id = 9, rank = "8", suit = "Spades" },
          card{ id = 10, rank = "Queen", suit = "Spades" },
        },
        -- only a flush clears 200 here; one hand, so a discard is the only path
        blind = { target_chips = 200, chips_scored = 0, hands_left = 1, discards_left = discards },
        run = { hand_levels = {}, hand_size = 5 },
      }
    end
    local with_d = Sim.survive_current(flush_chase(1), 200, lcg(7))
    local no_d   = Sim.survive_current(flush_chase(0), 200, lcg(7))
    t.eq(no_d, 0.0, "no discard: cannot complete the flush -> never clears")
    t.ok(with_d > no_d, "a discard that can complete the flush raises survival")
    t.ok(with_d > 0.2, "discard-aware survival is materially positive")
  end

  -- ---- simulate(): full result well-formed ----
  do
    local gs = GS.new{
      hand = {
        card{ id = 1, rank = "King", suit = "Spades" },
        card{ id = 2, rank = "King", suit = "Hearts" },
        card{ id = 3, rank = "7", suit = "Clubs" },
      },
      deck = (function()
        local d, i = {}, 0
        for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
          for r = 2, 14 do i = i + 1; d[i] = card{ id = 100 + i, rank_id = r, suit = s } end
        end
        return d
      end)(),
      remaining = { card{ id = 9, rank = "9", suit = "Hearts" } },
      blind = { target_chips = 300, chips_scored = 0, hands_left = 3, base_hands = 4,
                name = "Small Blind", boss = false },
      run = { hand_levels = {}, hand_size = 8 },
    }
    local r = Sim.simulate(gs, { samples = 20, rng = lcg(42) })
    t.ok(r.win_probability >= 0 and r.win_probability <= 1, "win_probability in [0,1]")
    t.ok(r.ante_survival >= 0 and r.ante_survival <= 1, "ante_survival in [0,1]")
    t.ok(r.ante_survival <= r.win_probability + 1e-9, "ante survival <= blind survival")
    t.ok(r.run_strength >= 0 and r.run_strength <= 1, "run_strength in [0,1]")
    t.eq(r.samples, 20, "samples echoed")
  end

  -- ---- eval function: bounds + ordering ----
  local empty = GS.new{}
  local one_joker = GS.new{ jokers = { joker{ key = "j_joker" } } }
  local baron = GS.new{ jokers = { joker{ key = "j_baron" } } }
  local rich = GS.new{ economy = { dollars = 60, interest_cap = 5 } }

  t.ok(Eval.run_strength(empty) >= 0 and Eval.run_strength(empty) <= 1, "run_strength bounded")
  t.ok(Eval.run_strength(one_joker) > Eval.run_strength(empty), "a joker beats none")
  t.ok(Eval.run_strength(baron) > Eval.run_strength(one_joker), "xmult joker beats plain joker")
  t.ok(Eval.run_strength(rich) > Eval.run_strength(empty), "money raises run strength")
  t.ok(Eval.future_value(one_joker) > Eval.future_value(empty), "future value monotone in jokers")

  -- ---- scaling projection: scalers are valued for what they BECOME ----
  do
    local function gsa(ante, jk) return GS.new{ meta = { ante = ante }, jokers = jk or {} } end
    -- growth runway shrinks as the ante-8 race progresses, hits 0 at ante 8
    t.ok(Eval.blinds_remaining(gsa(1)) > Eval.blinds_remaining(gsa(5)), "growth runway shrinks with ante")
    t.eq(Eval.blinds_remaining(gsa(8)), 0, "no runway left at the ante-8 race")
    -- projection is 1.0 for a flat joker, >1 for a scaler with runway, 1.0 late
    t.near(Eval.scaling_projection(gsa(1), "j_baron"), 1, "flat xmult joker is not projected")
    t.ok(Eval.scaling_projection(gsa(1), "j_hologram") > 1, "an x-mult scaler is projected up early")
    t.near(Eval.scaling_projection(gsa(8), "j_hologram"), 1, "no projection once the runway is gone")
    -- x-mult scalers grow steeper than chip scalers (compared below the cap)
    t.ok(Eval.scaling_projection(gsa(7), "j_hologram") > Eval.scaling_projection(gsa(7), "j_runner"),
      "x-mult scalers project steeper than chip scalers")
    -- bounded -- an ante-1 scaler is strongly preferred but never unbounded
    t.ok(Eval.scaling_projection(gsa(1), "j_hologram") <= 3.0 + 1e-9, "projection is bounded")
    -- self-harming scaler (Madness destroys your jokers) is explicitly NOT projected
    t.near(Eval.scaling_projection(gsa(1), "j_madness"), 1, "self-harming scaler is not projected")
    -- the payoff: a scaler is worth more bought early (more runway) than late
    local holo_early = Eval.future_value(gsa(1, { joker{ key = "j_hologram" } }))
    local holo_late  = Eval.future_value(gsa(8, { joker{ key = "j_hologram" } }))
    t.ok(holo_early > holo_late, "a scaler is worth more bought early than late")

    -- ---- realized-growth gate: condition-locked scalers (Runner/Square) ----
    -- A Runner only grows when you PLAY a straight, so its projection is discounted
    -- by how often the deck actually makes one. Passing measured hand frequencies
    -- gates it; omitting them keeps the old, ungated behaviour.
    local straighty   = { Straight = 0.5 }
    local no_straight = { Flush = 0.7, Pair = 0.3 }
    local run_makes = Eval.scaling_projection(gsa(2), "j_runner", straighty)
    local run_none  = Eval.scaling_projection(gsa(2), "j_runner", no_straight)
    local run_ungated = Eval.scaling_projection(gsa(2), "j_runner")
    t.ok(run_makes > run_none, "Runner projects higher when the deck actually makes straights")
    t.ok(run_none > 1, "a no-straight Runner still keeps SOME projection (gate floors, never zeroes)")
    t.ok(run_none < run_ungated, "no straights -> Runner is projected LESS than the ungated assumption")
    t.near(run_makes, run_ungated, "frequent straights -> Runner projects ~as much as the ungated assumption")
    -- Square scales on 4-card hands (Two Pair / Four of a Kind under greedy play).
    t.ok(Eval.scaling_projection(gsa(2), "j_square", { ["Two Pair"] = 0.4 })
       > Eval.scaling_projection(gsa(2), "j_square", { Flush = 0.6 }),
      "Square projects higher in a deck that plays 4-card hands")
    -- an UNCONDITIONAL scaler ignores hand frequencies (no trigger-hands map)
    t.eq(Eval.scaling_projection(gsa(2), "j_hologram", no_straight),
         Eval.scaling_projection(gsa(2), "j_hologram"),
      "an unconditional scaler (Hologram) is unaffected by hand frequencies")
  end

  -- deck quality bounded and rewards specials
  local plain_deck = GS.new{ deck = { card{ rank = "2", suit = "Spades" }, card{ rank = "3", suit = "Clubs" } } }
  local good_deck = GS.new{ deck = {
    card{ rank = "Ace", suit = "Spades", enhancement = "m_steel" },
    card{ rank = "King", suit = "Hearts", edition = "polychrome" },
  } }
  local pq = Eval.deck_quality(plain_deck)
  local gq = Eval.deck_quality(good_deck)
  t.ok(pq >= 0 and pq <= 1, "deck_quality bounded (plain)")
  t.ok(gq >= 0 and gq <= 1, "deck_quality bounded (good)")
  t.ok(gq > pq, "enhanced deck scores higher")

  -- ---- joker downsides: situational, can flip a contribution negative ----
  do
    local function fv(jokers, hs)
      return Eval.future_value(GS.new{ jokers = jokers,
        run = { hand_levels = {}, hand_size = hs or 8 },
        blind = { base_hands = 4, base_discards = 3 } })
    end
    local function contrib_last(jokers, hs)
      local without = {}
      for i = 1, #jokers - 1 do without[i] = jokers[i] end
      return fv(jokers, hs) - fv(without, hs)
    end
    -- Madness destroys a random joker: harmless on a lone board, harmful when it
    -- threatens strong jokers -> the contribution must be able to go NEGATIVE.
    local lone  = contrib_last({ joker{ key = "j_madness" } })
    local risky = contrib_last({ joker{ key = "j_baron" }, joker{ key = "j_baron" }, joker{ key = "j_madness" } })
    t.ok(lone > 0, "Madness contributes positively on a lone board (still worth taking)")
    t.ok(risky < 0, "Madness contributes NEGATIVELY when it threatens strong jokers")
    t.ok(risky < lone, "the downside is situational -- worse with more to lose")
    -- Stuntman's -2 hand size bites harder when card-starved, yet stays positive
    -- when the situation suits it (so it is never auto-skipped).
    local plenty  = contrib_last({ joker{ key = "j_stuntman" } }, 8)
    local starved = contrib_last({ joker{ key = "j_stuntman" } }, 5)
    t.ok(plenty > starved, "hand-size downside scales with scarcity")
    t.ok(plenty > 0, "a downside joker is still net-positive when the situation suits it")
  end

  -- ---- interaction-aware downsides (Vampire, joker destruction, stickers) ----
  do
    local function fv(jokers, deck)
      return Eval.future_value(GS.new{ jokers = jokers, deck = deck or {},
        run = { hand_levels = {}, hand_size = 8 }, blind = { base_hands = 4, base_discards = 3 } })
    end
    local function clast(jokers, deck)
      local w = {}
      for i = 1, #jokers - 1 do w[i] = jokers[i] end
      return fv(jokers, deck) - fv(w, deck)
    end

    -- Vampire eats enhancements: cheap on a board that doesn't rely on them,
    -- costlier beside an enhancement-dependent joker (Steel Joker) -- but still
    -- worth taking when nothing depends on what it eats.
    local steel_deck = {}
    for i = 1, 8 do steel_deck[i] = card{ id = i, rank_id = 10 + (i % 5), suit = "Spades", enhancement = "m_steel" } end
    local vamp_alone = clast({ joker{ key = "j_vampire" } }, steel_deck)
    local vamp_dep   = clast({ joker{ key = "j_steel_joker" }, joker{ key = "j_vampire" } }, steel_deck)
    t.ok(vamp_alone > vamp_dep, "Vampire costs more beside enhancement-dependent jokers")
    t.ok(vamp_alone > 0, "Vampire is still worth taking when nothing depends on the enhancements")

    -- Madness can't destroy an Eternal joker, so it threatens nothing there.
    local madness_vs_normal  = clast({ joker{ key = "j_baron" }, joker{ key = "j_madness" } })
    local madness_vs_eternal = clast({ joker{ key = "j_baron", ability = { eternal = true } }, joker{ key = "j_madness" } })
    t.ok(madness_vs_eternal > madness_vs_normal, "Madness threatens a normal joker but not an Eternal one")

    -- A Perishable sticker lowers any joker's contribution.
    local plain  = clast({ joker{ key = "j_baron" } })
    local perish = clast({ joker{ key = "j_baron", ability = { perishable = true } } })
    t.ok(plain > perish, "a Perishable sticker lowers a joker's contribution")

    -- In-game, ability.extra is a NUMBER for many jokers (not a table). The
    -- downside/eval code must type-check before indexing it, or it crashes.
    local numeric = GS.new{ jokers = {
      joker{ key = "j_madness", ability = 5 },               -- ability itself a number
      joker{ key = "j_vampire", ability = { extra = 7 } },   -- extra a number
    } }
    local ok = pcall(Eval.future_value, numeric)
    t.ok(ok, "eval tolerates ability / ability.extra being a number, not a table")
  end

  -- ---- boss effects: module + survival impact ----
  do
    local BE = require("engine.boss_effect")
    t.eq(BE.of("bl_wall").mult, 4, "The Wall is a 4x requirement")
    t.eq(BE.of("nope_unknown").mult, 2, "unknown boss -> generic 2x")
    t.ok(not BE.legal_play(BE.of("bl_psychic"), { 1, 2, 3, 4 }, "Pair", {}), "Psychic forbids <5-card plays")
    t.ok(BE.legal_play(BE.of("bl_psychic"), { 1, 2, 3, 4, 5 }, "Flush", {}), "Psychic allows 5-card plays")
    local nh = BE.resources(BE.of("bl_needle"), 4, 3, 8)
    t.eq(nh, 1, "The Needle -> only 1 hand")
    local _, wd = BE.resources(BE.of("bl_water"), 4, 3, 8)
    t.eq(wd, 0, "The Water -> 0 discards")

    -- The Flint lowers fresh-blind survival (base halved); seeded for stability.
    local deck, id = {}, 0
    for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do id = id + 1; deck[id] = card{ id = id, rank_id = r, suit = s } end
    end
    local gs = GS.new{ deck = deck, run = { hand_levels = {}, hand_size = 8 } }
    local sv0 = Sim.survive_fresh(gs, 800, 4, 3, 80, lcg(2), nil)
    local svf = Sim.survive_fresh(gs, 800, 4, 3, 80, lcg(2), BE.of("bl_flint"))
    t.ok(svf < sv0, "The Flint lowers fresh-blind survival vs no boss")
  end

  -- ---- whole-run pacing (ante race) ----
  do
    local Pacing = require("engine.pacing")
    -- a scaling/xmult engine with money grows faster than a flat joker
    t.ok(Pacing.growth_factor(GS.new{ jokers = { joker{ key = "j_cavendish" }, joker{ key = "j_baron" } },
        economy = { dollars = 30, interest_cap = 5 } })
       > Pacing.growth_factor(GS.new{ jokers = { joker{ key = "j_joker" } } }),
      "xmult + money grows the engine faster than a flat joker")

    -- A FLAT XMULT IS A STEP, NOT A RATE (see engine/pacing growth_factor). cap = base * X, so a
    -- growth step gives cap'/cap = (base+d)/base with X cancelling -- and `cap` already MEASURES
    -- the board's X. Only an xmult whose X itself grows is a rate.
    local g_flat = Pacing.growth_factor(GS.new{ jokers = { joker{ key = "j_cavendish" } } })
    local g_bare = Pacing.growth_factor(GS.new{ jokers = { joker{ key = "j_joker" } } })
    local g_xsc  = Pacing.growth_factor(GS.new{ jokers = { joker{ key = "j_hologram" } } })
    local g_sc   = Pacing.growth_factor(GS.new{ jokers = { joker{ key = "j_runner" } } })
    t.eq(g_flat, g_bare, "an owned FLAT xmult adds no growth RATE (it is already in the measured cap)")
    t.ok(g_xsc > g_sc, "an xmult that SCALES out-credits a plain scaler")
    t.ok(g_xsc - g_bare > 2 * (g_sc - g_bare),
      "a scaling xmult out-credits a plain scaler by >2x (0.45 vs 0.15)")

    local deck, id = {}, 0
    for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do id = id + 1; deck[id] = card{ id = id, rank_id = r, suit = s } end
    end
    local function pgs(jokers, levels)
      return GS.new{ jokers = jokers, deck = deck, economy = { dollars = 10, interest_cap = 5 },
        meta = { ante = 1, round = 1, state = "x", seed_hash = "" },
        run = { hand_levels = levels or {}, hand_size = 8 }, blind = { base_hands = 4 } }
    end
    local weak = Pacing.pace(pgs({ joker{ key = "j_joker" } }), { rng = lcg(3), samples = 8 })
    local strong = Pacing.pace(pgs({ joker{ key = "j_cavendish" }, joker{ key = "j_baron" } }), { rng = lcg(3), samples = 8 })
    t.ok(weak and strong, "pace is measurable on a deck")
    t.ok(strong.margin > weak.margin, "a stronger engine is closer to on-pace")
    -- a heavily-leveled engine projects on pace through ante 8
    local big = Pacing.pace(pgs({ joker{ key = "j_cavendish" } }, { ["Pair"] = { level = 25, chips = 400, mult = 60 } }),
      { rng = lcg(3), samples = 8 })
    t.ok(big.on_pace, "a strong, leveled engine projects on pace through ante 8")
    t.ok(not weak.on_pace, "a flat 1-joker board is behind pace")
  end

  -- ---- Phase 1: joker value (and sell ranking) is MEASURED, not tier ----
  -- The headline bug: with tier-only valuation the advisor ranks the joker
  -- actually carrying your deck as the weakest, because two suit jokers share a
  -- tier. Measured against a Hearts-heavy deck, Lusty (Hearts +mult) must out-rank
  -- Wrathful (Spades +mult) -- so Wrathful, not Lusty, is the one to sell.
  do
    local deck = {}
    for r = 2, 14 do deck[#deck + 1] = card{ id = r, rank_id = r, suit = "Hearts" } end
    for r = 2, 14 do deck[#deck + 1] = card{ id = 100 + r, rank_id = r, suit = "Hearts" } end
    deck[#deck + 1] = card{ id = 200, rank_id = 14, suit = "Spades" }
    deck[#deck + 1] = card{ id = 201, rank_id = 13, suit = "Spades" }
    local gs = GS.new{
      jokers = { joker{ key = "j_lusty_joker" }, joker{ key = "j_wrathful_joker" } },
      deck = deck, run = { hand_levels = {}, hand_size = 8 },
      meta = { ante = 1, round = 1, state = "x", seed_hash = "" },
    }
    local mopts = { rng = lcg(5), cache = {}, samples = 16 }
    local lusty   = Eval.joker_marginal_fv(gs, 1, mopts)
    local wrathful = Eval.joker_marginal_fv(gs, 2, mopts)
    t.ok(lusty > wrathful, "measured: Lusty out-contributes Wrathful on a Hearts deck (so Wrathful sells)")

    -- The same board with NO deck cannot be measured -> both fall back to the tier
    -- prior, which (same tier) does NOT distinguish them. This is exactly what made
    -- the old tier-only sell ranking blind to which joker fits your deck.
    local nodeck = GS.new{ jokers = gs.jokers }
    local lp = select(2, Eval.joker_marginal_fv(nodeck, 1))
    t.ok(lp == false, "no deck -> falls back to the tier prior (unmeasured)")

    -- joker_power is deck-aware now: a Hearts board on a Hearts deck out-powers the
    -- SAME board measured against a Spades deck.
    local spade_deck = {}
    for r = 2, 14 do spade_deck[#spade_deck + 1] = card{ id = r, rank_id = r, suit = "Spades" } end
    for r = 2, 14 do spade_deck[#spade_deck + 1] = card{ id = 100 + r, rank_id = r, suit = "Spades" } end
    local gs_h = GS.new{ jokers = { joker{ key = "j_lusty_joker" } }, deck = deck,
      run = { hand_levels = {}, hand_size = 8 } }
    local gs_s = GS.new{ jokers = { joker{ key = "j_lusty_joker" } }, deck = spade_deck,
      run = { hand_levels = {}, hand_size = 8 } }
    t.ok(Eval.joker_power(gs_h, { rng = lcg(5), cache = {}, samples = 16 })
       > Eval.joker_power(gs_s, { rng = lcg(5), cache = {}, samples = 16 }),
      "joker_power is deck-aware: Lusty powers a Hearts deck more than a Spades deck")
  end

  -- ---- Phase 5: conditional joker econ is DECK-AWARE, not a flat number ----
  do
    local function suit_deck(suit, n)
      local d = {}
      for i = 1, n do d[i] = card{ id = i, rank_id = 2 + (i % 9), suit = suit } end
      return d
    end
    local dia = GS.new{ deck = suit_deck("Diamonds", 20) }   -- all diamonds
    local nod = GS.new{ deck = suit_deck("Spades", 20) }     -- no diamonds

    -- Rough Gem ($1 per Diamond scored) earns more on a Diamonds deck, ~nothing
    -- without diamonds -- not the flat prior.
    t.ok(Eval.econ_value(dia, "j_rough_gem") > Eval.econ_value(nod, "j_rough_gem"),
      "Rough Gem earns more on a Diamonds-heavy deck (deck-aware econ)")
    t.eq(Eval.econ_value(nod, "j_rough_gem"), 0, "Rough Gem earns nothing with no Diamonds")

    -- Golden Joker (+$ flat at round end) is unconditional: deck doesn't change it.
    t.eq(Eval.econ_value(dia, "j_golden"), Eval.econ_value(nod, "j_golden"),
      "Golden Joker econ is deck-independent (unconditional)")

    -- MULTIPLICATIVE ECONOMY (2026-08-13). econ_power is a SUM of static per-joker figures,
    -- so it could not represent a money ENGINE -- and both of the human's money-carried wins
    -- were exactly that ("oops all 6s synergising into reserved parking farming"). Oops! All
    -- 6s doubles every listed probability, so it doubles a probability-gated money joker.
    do
      local faces = {}
      for i = 1, 20 do faces[i] = card{ id = i, rank_id = 12, suit = "Spades" } end  -- all Queens
      local plain = GS.new{ deck = faces, jokers = { { key = "j_reserved_parking" } } }
      local oops  = GS.new{ deck = faces, jokers = { { key = "j_reserved_parking" }, { key = "j_oops" } } }
      t.ok(Eval.econ_value(oops, "j_reserved_parking") > Eval.econ_value(plain, "j_reserved_parking"),
        "Oops! All 6s doubles a probability-gated money joker's income")
      t.eq(Eval.econ_value(oops, "j_golden"), Eval.econ_value(plain, "j_golden"),
        "...but NOT a flat, non-probability econ joker (Golden Joker is unaffected)")
      -- Reserved Parking is face-density-aware, like Business Card
      local nofaces = {}
      for i = 1, 20 do nofaces[i] = card{ id = i, rank_id = 5, suit = "Spades" } end
      local lowdeck = GS.new{ deck = nofaces, jokers = { { key = "j_reserved_parking" } } }
      t.ok(Eval.econ_value(plain, "j_reserved_parking") > Eval.econ_value(lowdeck, "j_reserved_parking"),
        "Reserved Parking earns more on a face-heavy deck (deck-aware, was a flat prior)")
      -- and the deck-aware value must reach the BUY/SELL path, which read the raw catalogue
      -- number: a Rough Gem was priced identically on a 4-diamond deck and a 20-diamond one.
      local fv_dia = Eval.joker_marginal_fv(
        GS.new{ deck = suit_deck("Diamonds", 20), jokers = { { key = "j_rough_gem" } } }, 1,
        { measure = false })
      local fv_nod = Eval.joker_marginal_fv(
        GS.new{ deck = suit_deck("Spades", 20), jokers = { { key = "j_rough_gem" } } }, 1,
        { measure = false })
      t.ok(fv_dia > fv_nod, "deck-aware econ reaches the FV valuation (buy/sell), not just headroom")
    end

    -- Cloud 9 ($1 per 9 in the deck) scales with the count of 9s.
    local many9, no9 = {}, {}
    for i = 1, 8 do many9[i] = card{ id = i, rank_id = 9, suit = "Spades" } end
    for i = 9, 20 do many9[i] = card{ id = i, rank_id = 5, suit = "Spades" } end
    for i = 1, 20 do no9[i] = card{ id = i, rank_id = 5, suit = "Spades" } end
    t.ok(Eval.econ_value(GS.new{ deck = many9 }, "j_cloud_9") > Eval.econ_value(GS.new{ deck = no9 }, "j_cloud_9"),
      "Cloud 9 earns more with more 9s in the deck")
    t.eq(Eval.econ_value(GS.new{ deck = no9 }, "j_cloud_9"), 0, "Cloud 9 earns nothing with no 9s")

    -- with NO deck the conditional jokers fall back to their flat prior (preserves
    -- existing deckless behaviour / tests).
    t.eq(Eval.econ_value(GS.new{}, "j_rough_gem"), 4, "no deck -> Rough Gem uses its flat econ prior")
  end

  -- ---- time-slicing: opts.yield must NOT change the result -------------------
  -- The live overlay runs Sim.simulate inside a coroutine, pumping it a few ms
  -- per frame via opts.yield = coroutine.yield. Because yield touches neither the
  -- RNG nor the win counts, the sliced result must equal the synchronous one.
  do
    local function rich_state()
      return GS.new{
        hand = {
          card{ id = 1, rank = "King", suit = "Spades" },
          card{ id = 2, rank = "King", suit = "Hearts" },
          card{ id = 3, rank = "Queen", suit = "Clubs" },
          card{ id = 4, rank = "7", suit = "Diamonds" },
          card{ id = 5, rank = "3", suit = "Spades" },
        },
        deck = {
          card{ id = 6, rank = "9", suit = "Hearts" },
          card{ id = 7, rank = "King", suit = "Clubs" },
          card{ id = 8, rank = "4", suit = "Clubs" },
          card{ id = 9, rank = "Queen", suit = "Hearts" },
          card{ id = 10, rank = "2", suit = "Spades" },
          card{ id = 11, rank = "10", suit = "Diamonds" },
        },
        blind = { target_chips = 300, chips_scored = 0, boss = true,
                  hands_left = 3, discards_left = 2, base_hands = 3, base_discards = 2,
                  blind_type = "Small" },
        run = { hand_levels = {}, hand_size = 5 },
        meta = { ante = 2 },
      }
    end

    local sync = Sim.simulate(rich_state(), { samples = 40, rng = lcg(99) })

    -- drive the same simulation through a coroutine, yielding mid-run
    local sliced, all_ok = nil, true
    local yields = 0
    local co = coroutine.create(function()
      return Sim.simulate(rich_state(), { samples = 40, rng = lcg(99),
        yield = function() yields = yields + 1; coroutine.yield() end })
    end)
    while true do
      local ok, res = coroutine.resume(co)
      if not ok then all_ok = false; break end
      if coroutine.status(co) == "dead" then sliced = res; break end
    end

    t.ok(all_ok, "sim coroutine resumed without error")
    t.ok(yields > 0, "yield callback was actually invoked (time-sliced)")
    t.eq(sliced.win_probability, sync.win_probability, "sliced win_prob == sync win_prob")
    t.eq(sliced.ante_survival, sync.ante_survival, "sliced ante_survival == sync ante_survival")
  end
end
