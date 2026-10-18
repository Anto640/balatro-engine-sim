-- tests/test_hand_eval_prune.lua
-- best_play's kicker pruning (HandEval.PRUNE_KICKERS) must return exactly what the full enumeration returns: same
-- score, hand type and cards, on random hands across boards (held-card jokers, Half Joker, copiers, editions,
-- enhancements, and the two kicker-sensitive jokers that switch pruning off). Pure/headless.

local HandEval = require("engine.hand_eval")
local GS = require("model.game_state")
local card, joker = GS.card, GS.joker

return function(t)
  local RANKS = { "2","3","4","5","6","7","8","9","10","Jack","Queen","King","Ace" }
  local SUITS = { "Spades","Hearts","Clubs","Diamonds" }
  local ENH = { nil, nil, nil, "m_bonus", "m_mult", "m_glass", "m_steel", "m_stone", "m_lucky", "m_wild", "m_gold" }
  local seed = 12345
  local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return 1 + (seed % n) end
  local BOARDS = {
    { "j_joker", "j_jolly", "j_sly" },
    { "j_baron", "j_mime", "j_shoot_the_moon" },
    { "j_half", "j_photograph", "j_hanging_chad" },
    { "j_blueprint", "j_baron", "j_duo", "j_tribe" },
    { "j_raised_fist", "j_joker" },            -- kicker-sensitive: pruning off
    { "j_blackboard", "j_greedy_joker" },      -- kicker-sensitive: pruning off
    { "j_four_fingers", "j_shortcut", "j_smeared" },
    { "j_splash", "j_scary_face", "j_smiley" },
    { "j_cavendish", "j_card_sharp", "j_supernova", "j_abstract" },
  }
  local saved = HandEval.PRUNE_KICKERS
  local mismatches, cases = 0, 0
  for b = 1, #BOARDS do
    local jk = {}
    for i, k in ipairs(BOARDS[b]) do jk[i] = joker{ key = k, edition = (rnd(4) == 1) and "polychrome" or nil } end
    for _ = 1, 25 do
      local hand = {}
      for i = 1, 8 do
        hand[i] = card{ id = i, rank = RANKS[rnd(13)], suit = SUITS[rnd(4)], enhancement = ENH[rnd(#ENH)],
                        seal = (rnd(6) == 1) and "Red" or nil }
      end
      local gs = GS.new{ jokers = jk, hand = hand, blind = { hands_left = 3, discards_left = 2 } }
      HandEval.PRUNE_KICKERS = false
      local e0, s0 = HandEval.best_play(gs, hand)
      HandEval.PRUNE_KICKERS = true
      local e1, s1 = HandEval.best_play(gs, hand)
      cases = cases + 1
      local same = e0 and e1 and e0.score == e1.score and e0.hand_type == e1.hand_type and #s0 == #s1
      if same then for i = 1, #s0 do if s0[i] ~= s1[i] then same = false end end end
      if not same then mismatches = mismatches + 1 end
    end
  end
  HandEval.PRUNE_KICKERS = saved
  t.eq(mismatches, 0, string.format("best_play pruned == full enumeration on %d random hands", cases))

  -- the allocation-free kicker check == "every analyze() scoring flag is set", on random sets of 1-5 cards,
  -- including stones, wilds and the Four Fingers / Shortcut / Smeared modifiers
  local MODS = { {}, { four_fingers = true }, { shortcut = true }, { smeared = true }, { four_fingers = true, shortcut = true } }
  local bad, n = 0, 0
  for _, mods in ipairs(MODS) do
    for _ = 1, 400 do
      local k = rnd(5)
      local sel = {}
      for i = 1, k do
        sel[i] = card{ id = i, rank = RANKS[rnd(13)], suit = SUITS[rnd(4)],
                       enhancement = (rnd(10) == 1) and "m_stone" or ((rnd(10) == 1) and "m_wild" or nil) }
      end
      local _, scoring = HandEval.analyze(sel, mods)
      local all = true
      for i = 1, #sel do if not scoring[i] then all = false end end
      n = n + 1
      if HandEval._kicker_free(sel, mods) ~= all then bad = bad + 1 end
    end
  end
  t.eq(bad, 0, string.format("kicker_free == analyze all-scoring on %d random card sets", n))
end
