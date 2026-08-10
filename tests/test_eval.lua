-- tests/test_eval.lua
-- Analytic conditional-xmult valuation (the skip-the-cores fix): a hand-conditional xmult
-- (Duo/Trio/Family/Order/Tribe) whose 6-sample measured delta reads ~0 is valued instead by
-- P(trigger hand) x (X-1) x board base, so it rises with how much the DECK makes its trigger.

local Eval = require("engine.eval_function")
local GS = require("model.game_state")

-- deterministic LCG (matches the engine's per-state seeding style)
local function lcg(seed)
  local s = seed % 2147483647; if s == 0 then s = 1 end
  return function() s = (s * 48271) % 2147483647; return s / 2147483647 end
end

local function card(rank, id, suit, i)
  return { rank = rank, rank_id = id, suit = suit, id = i }
end

-- a normal spread deck (4 suits x 13 ranks): trigger hands are relatively rare
local function deck_spread()
  local d, suits = {}, { "Hearts", "Diamonds", "Clubs", "Spades" }
  local ranks = { {"2",2},{"3",3},{"4",4},{"5",5},{"6",6},{"7",7},{"8",8},
                  {"9",9},{"10",10},{"J",11},{"Q",12},{"K",13},{"A",14} }
  for _, s in ipairs(suits) do for _, r in ipairs(ranks) do d[#d+1] = card(r[1], r[2], s, #d+1) end end
  return d
end

-- a deck flooded with three ranks (16 of them) so Three of a Kind is a common best play
local function deck_trips_heavy()
  local d, suits = {}, { "Hearts", "Diamonds", "Clubs", "Spades" }
  for _ = 1, 4 do for _, r in ipairs({ {"7",7},{"8",8},{"9",9} }) do
    for _, s in ipairs(suits) do d[#d+1] = card(r[1], r[2], s, #d+1) end
  end end
  local extra = deck_spread()
  for i = 1, 16 do d[#d+1] = extra[i] end
  return d
end

local function trio_add_fv(deckfn, seed)
  local gs = GS.new{ deck = deckfn(), jokers = {}, meta = { ante = 2 }, run = { hand_size = 8 } }
  return (Eval.add_joker_marginal_fv(gs, { key = "j_trio" },
    { rng = lcg(seed), cache = {}, samples = 24 }))
end

return function(t)
  local spread = trio_add_fv(deck_spread, 4242)
  local heavy  = trio_add_fv(deck_trips_heavy, 4242)

  -- the mechanism: The Trio is worth strictly MORE on a deck that actually makes trips
  t.ok(heavy > spread + 1e-6, "a conditional xmult is valued higher on a trigger-rich deck")
  -- and it clears the flat tier-prior floor there (the noisy measurement would leave it AT the floor)
  t.ok(heavy > spread + 1.0, "the trips-rich deck lifts The Trio well above its spread-deck floor")

  -- determinism: same seed -> byte-identical value (live panel must not flicker)
  t.eq(trio_add_fv(deck_trips_heavy, 4242), heavy, "conditional-xmult valuation is per-state deterministic")

  -- no-deck / cheap path is unaffected (the analytic needs a samplable deck; falls back to prior)
  local bare = GS.new{ jokers = {}, meta = { ante = 2 } }
  local ok = pcall(Eval.add_joker_marginal_fv, bare, { key = "j_trio" }, {})
  t.ok(ok, "no-deck valuation still works (analytic no-ops without a samplable deck)")

  -- ---- Buffoon pack-pick core valuation (Eval.joker_pick_frac): a conditional xmult picked
  -- from a pack is valued for the core it is, not the ~0 its noisy delta reads on a weak board ----
  do
    local Mech = require("engine.mechanics")
    -- board WITH a scoring base so an xmult has something to multiply
    local gs = GS.new{ deck = deck_trips_heavy(), jokers = { { key = "j_jolly" }, { key = "j_scholar" } },
      meta = { ante = 2 }, run = { hand_size = 8, hand_levels = {} } }
    local need = Mech.boss_per_hand_need(gs)
    local function pick(k) return (Eval.joker_pick_frac(gs, { key = k }, need, { rng = lcg(77), samples = 24 })) end
    local trio, flat = pick("j_trio"), pick("j_greedy_joker")
    t.ok(trio > flat + 1e-6, "a conditional xmult out-values a flat common in the pack pick (was inverted)")
    -- prior floor protects an unmeasurable core even with no samplable deck
    local floor = (Eval.joker_pick_frac(GS.new{ jokers = {}, meta = { ante = 2 } }, { key = "j_trio" }, 1000, {}))
    t.ok(floor > 0, "no-deck pack pick falls back to a positive prior floor (never ~0)")
    t.eq((Eval.joker_pick_frac(gs, { key = "j_trio" }, need, { rng = lcg(77), samples = 24 })), trio,
      "pack-pick valuation is per-state deterministic")
  end

  -- ---- W3: world-side joker REORDER for scoring (sim fidelity) ----
  do
    local World = require("sim.world")
    local HandEval = require("engine.hand_eval")
    local function card2(r, i, su, x) return { rank = r, rank_id = i, suit = su, id = x } end
    local hand = { card2("8", 8, "Hearts", 1), card2("8", 8, "Spades", 2), card2("8", 8, "Clubs", 3),
                   card2("K", 13, "Diamonds", 4), card2("2", 2, "Hearts", 5) }
    local function sc(jokers) return (HandEval.score(GS.new{ jokers = jokers, hand = hand, run = { hand_levels = {} } }, hand) or {}).score or 0 end
    -- BAD acquisition order: xmult first (additive after it unmultiplied), Blueprint last (copies nothing)
    local acq = { { key = "j_cavendish", ability = { x_mult = 3 } }, { key = "j_scholar" }, { key = "j_jolly" }, { key = "j_blueprint" } }
    local s_acq = sc(acq)
    local run = { jokers = {} }; for i, j in ipairs(acq) do run.jokers[i] = j end
    World.optimize_joker_order(run)
    t.ok(sc(run.jokers) > s_acq, "W3: the reordered board scores strictly higher (additive-before-xmult + Blueprint copies the xmult)")
    -- additive jokers come before the xmult; the copier is not stranded in the last slot
    t.ok(run.jokers[#run.jokers].key == "j_cavendish", "W3: the xmult is placed last (multiplies the accumulated additive)")
    -- idempotent + safe on tiny boards
    local before = {}; for i, j in ipairs(run.jokers) do before[i] = j.key end
    World.optimize_joker_order(run)
    local after = {}; for i, j in ipairs(run.jokers) do after[i] = j.key end
    t.eq(table.concat(after, ","), table.concat(before, ","), "W3: reorder is idempotent")
    local tiny = { jokers = { { key = "j_joker" } } }; World.optimize_joker_order(tiny)
    t.eq(#tiny.jokers, 1, "W3: no-op on a single-joker board")
  end
end
