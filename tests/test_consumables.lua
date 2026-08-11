-- tests/test_consumables.lua
-- Phase 1 world fidelity (WINRATE_AUDIT A2+A3): faithful execution of the consumables the
-- world used to silently discard (money / generators / spectrals), plus the Hierophant
-- misspelling alias and Lovers -> Wild. Pure/headless.

local World    = require("sim.world")
local Tarot    = require("engine.tarot")
local CV       = require("engine.consumable_value")
local Decision = require("engine.decision_engine")

return function(t)
  -- a minimal run the executor accepts; rng is deterministic
  local function new_run(over)
    local r = {
      economy = { dollars = 10, interest_cap = 5 },
      jokers = {}, consumables = {}, hand_levels = {},
      joker_slots = 5, consumable_slots = 2,
      deck = World.standard_deck(), rng = World.lcg(42),
    }
    for k, v in pairs(over or {}) do r[k] = v end
    return r
  end
  local function use(run, key)
    return World._use_consumable(run, { use_names = { key } }, nil, nil, nil, nil)
  end
  local function held(key, set) return { set = set or "Tarot", key = key, name = key } end

  -- ---- A3: Hierophant misspelling alias + Lovers -> Wild ----
  do
    t.ok(Tarot.ENH.c_heirophant ~= nil, "A3: c_heirophant (in-game spelling) aliased in Tarot.ENH")
    t.eq(Tarot.ENH.c_heirophant.enh, "m_bonus", "c_heirophant applies +Chips like c_hierophant")
    t.ok(CV.TAROT_BASE.c_heirophant ~= nil, "A3: c_heirophant has a real prior (not the 0.15 fallback)")
    -- apply_to_hand honours the alias (the world uses this path for enhancement tarots)
    local hand = { { id = 1, rank_id = 14, suit = "Spades" }, { id = 2, rank_id = 13, suit = "Spades" } }
    local nh = Tarot.apply_to_hand(hand, "c_heirophant")
    t.ok(nh and nh[1].enhancement == "m_bonus", "c_heirophant enhances a card via apply_to_hand")
    t.eq(Tarot.ENH.c_lovers.enh, "m_wild", "A2: Lovers enhances into a Wild card")
  end

  -- ---- money tarots (the corrupted-money-model fix) ----
  do
    local run = new_run({ economy = { dollars = 12, interest_cap = 5 } })
    run.consumables = { held("c_hermit") }
    use(run, "c_hermit")
    t.eq(run.economy.dollars, 24, "Hermit doubles money (+min($,20): 12 -> 24)")

    local run2 = new_run({ economy = { dollars = 50, interest_cap = 5 } })
    run2.consumables = { held("c_hermit") }
    use(run2, "c_hermit")
    t.eq(run2.economy.dollars, 70, "Hermit caps the gain at +$20 (50 -> 70)")

    local run3 = new_run({ economy = { dollars = 5, interest_cap = 5 },
      jokers = { { key = "j_joker", sell_value = 3 }, { key = "j_mad", sell_value = 4 } } })
    run3.consumables = { held("c_temperance") }
    use(run3, "c_temperance")
    t.eq(run3.economy.dollars, 12, "Temperance adds total joker sell value (5 + 7 = 12)")
  end

  -- ---- the fifteen spectrals the world used to CONSUME FOR ZERO EFFECT (2026-08-11) ----
  -- Ouija / Sigil / Cryptid are the rank- and suit-CONCENTRATING cards, i.e. the only route
  -- to Five of a Kind / Flush Five / Flush House. Without them the sim could not express the
  -- secret-hand archetype the one human WIN used. See WINRATE_V3_PLAN.md 5m.
  do
    local function hand_of(n)
      local h = {}
      for i = 1, n do h[i] = { id = i, rank_id = 5 + i, suit = ({ "Spades", "Hearts", "Clubs", "Diamonds" })[(i % 4) + 1] } end
      return h
    end
    local function use_on(run, key, hand)
      run.consumables = { held(key, "Spectral") }
      return World._use_consumable(run, { use_names = { key } }, nil, nil, hand, nil)
    end

    -- Ouija: every card in hand becomes ONE rank -> five-of-a-kind becomes reachable
    do
      local run, h = new_run(), hand_of(8)
      local hs = run.hand_size or 8
      use_on(run, "c_ouija", h)
      local rank = h[1].rank_id
      local same = 0
      for _, c in ipairs(h) do if c.rank_id == rank then same = same + 1 end end
      t.eq(same, 8, "Ouija converts every card in hand to a single rank")
      t.ok(same >= 5, "...which is what makes Five of a Kind reachable at all")
      t.eq(run.hand_size, hs - 1, "Ouija costs -1 hand size")
    end

    -- Sigil: one suit (the Flush / Flush House / Flush Five enabler)
    do
      local run, h = new_run(), hand_of(8)
      use_on(run, "c_sigil", h)
      local suit, same = h[1].suit, 0
      for _, c in ipairs(h) do if c.suit == suit then same = same + 1 end end
      t.eq(same, 8, "Sigil converts every card in hand to a single suit")
    end

    -- Cryptid: two copies of a card, added to the DECK with fresh ids
    do
      local run, h = new_run(), hand_of(8)
      local before = #run.deck
      use_on(run, "c_cryptid", h)
      t.eq(#run.deck, before + 2, "Cryptid adds two cards to the deck")
      local ids = {}
      for _, c in ipairs(run.deck) do
        t.ok(not ids[c.id], "every deck card keeps a unique id after Cryptid")
        ids[c.id] = true
      end
    end

    -- Familiar / Grim / Incantation: destroy 1, add N enhanced cards of a rank family
    do
      local cases = { { "c_familiar", 3, 2 }, { "c_grim", 2, 1 }, { "c_incantation", 4, 3 } }
      for _, c in ipairs(cases) do
        local key, add, net = c[1], c[2], c[3]
        local run, h = new_run(), hand_of(8)
        local before = #run.deck
        use_on(run, key, h)
        t.eq(#run.deck, before + net, key .. " destroys 1 card and adds " .. add)
      end
      -- the ADDED cards come from the right rank family and are always enhanced
      local FAMILY = {
        c_grim     = { [14] = true },                                  -- Aces
        c_familiar = { [11] = true, [12] = true, [13] = true },        -- face cards
      }
      for key, ranks in pairs(FAMILY) do
        local run, h = new_run(), hand_of(8)
        local before = #run.deck
        use_on(run, key, h)
        local added = 0
        for i = before, #run.deck do            -- destroy-1 shifts, so scan the tail
          local c = run.deck[i]
          if c and ranks[c.rank_id] and c.enhancement then added = added + 1 end
        end
        t.ok(added >= 2, key .. " adds enhanced cards of the correct rank family (got " .. added .. ")")
      end
    end

    -- seals + Aura: exactly one card upgraded
    do
      for key, seal in pairs({ c_talisman = "Gold", c_deja_vu = "Red", c_trance = "Blue", c_medium = "Purple" }) do
        local run, h = new_run(), hand_of(8)
        use_on(run, key, h)
        local n = 0
        for _, c in ipairs(h) do if c.seal == seal then n = n + 1 end end
        t.eq(n, 1, key .. " adds exactly one " .. seal .. " seal")
      end
      local run, h = new_run(), hand_of(8)
      use_on(run, "c_aura", h)
      local n = 0
      for _, c in ipairs(h) do if c.edition then n = n + 1 end end
      t.eq(n, 1, "Aura adds an edition to exactly one card")
    end

    -- Wraith: a Rare joker, and your bankroll goes to $0
    do
      local run = new_run({ economy = { dollars = 30, interest_cap = 5 } })
      use_on(run, "c_wraith", nil)
      t.eq(run.economy.dollars, 0, "Wraith wipes your money to $0")
      t.eq(#run.jokers, 1, "Wraith creates a joker")
    end

    -- Ectoplasm: negative edition (which carries its own joker slot) and -1 hand size
    do
      local run = new_run({ jokers = { { key = "j_joker", ability = { extra = {} } } } })
      local hs, slots = run.hand_size or 8, run.joker_slots
      use_on(run, "c_ectoplasm", nil)
      t.eq(run.jokers[1].edition, "negative", "Ectoplasm makes a joker Negative")
      t.eq(run.joker_slots, slots + 1, "...and a Negative joker brings its own slot")
      t.eq(run.hand_size, hs - 1, "...at the cost of -1 hand size")
    end

    -- Ankh / Hex DESTROY your other jokers -- the reason consumable_value subtracts them
    do
      local run = new_run({ jokers = {
        { key = "j_joker", ability = { extra = {} } }, { key = "j_mad", ability = { extra = {} } },
        { key = "j_zany", ability = { extra = {} } } } })
      use_on(run, "c_ankh", nil)
      t.eq(#run.jokers, 2, "Ankh leaves one joker plus its copy (the others are destroyed)")
      t.eq(run.jokers[1].key, run.jokers[2].key, "...and the survivor is the one that was copied")

      local run2 = new_run({ jokers = {
        { key = "j_joker", ability = { extra = {} } }, { key = "j_mad", ability = { extra = {} } },
        { key = "j_zany", ability = { extra = {} } } } })
      use_on(run2, "c_hex", nil)
      t.eq(#run2.jokers, 1, "Hex destroys every joker but one")
      t.eq(run2.jokers[1].edition, "polychrome", "...and makes the survivor Polychrome")
    end

    -- the whole point: NONE of these is a silent no-op any more
    do
      local KEYS = { "c_ouija", "c_sigil", "c_cryptid", "c_familiar", "c_grim", "c_incantation",
                     "c_talisman", "c_deja_vu", "c_trance", "c_medium", "c_aura",
                     "c_wraith", "c_ectoplasm", "c_ankh", "c_hex" }
      for _, key in ipairs(KEYS) do
        local run = new_run({ jokers = { { key = "j_joker", ability = { extra = {} } },
                                         { key = "j_mad", ability = { extra = {} } } } })
        local h = hand_of(8)
        local snap = { deck = #run.deck, jokers = #run.jokers, hs = run.hand_size or 8,
                       cash = run.economy.dollars, slots = run.joker_slots }
        use_on(run, key, h)
        local changed = (#run.deck ~= snap.deck) or (#run.jokers ~= snap.jokers)
          or ((run.hand_size or 8) ~= snap.hs) or (run.economy.dollars ~= snap.cash)
          or (run.joker_slots ~= snap.slots)
        if not changed then   -- seal/suit/rank spectrals mutate cards in place
          for _, c in ipairs(h) do
            if c.seal or c.edition or c.rank_id == h[1].rank_id then changed = true end
          end
        end
        t.ok(changed, key .. " has a real effect on the world (no longer consumed for nothing)")
        t.eq(#run.consumables, 0, key .. " is actually consumed")
      end
    end
  end

  -- ---- spectrals: Black Hole (level all hands) + Immolate (+$20, destroy 5) ----
  do
    local run = new_run()
    run.consumables = { held("c_black_hole", "Spectral") }
    use(run, "c_black_hole")
    t.eq(run.hand_levels["Pair"] and run.hand_levels["Pair"].level, 2, "Black Hole levels Pair to 2")
    t.eq(run.hand_levels["Flush"] and run.hand_levels["Flush"].level, 2, "Black Hole levels Flush to 2 (every hand)")
    -- EVERY hand means the three SECRET hands too: both Black Holes in the live telemetry
    -- fired as a burst of exactly 12 level_up records, not 9.
    for _, h in ipairs({ "Five of a Kind", "Flush House", "Flush Five" }) do
      t.eq(run.hand_levels[h] and run.hand_levels[h].level, 2,
        "Black Hole levels the secret hand " .. h .. " too")
    end

    local run2 = new_run({ economy = { dollars = 3, interest_cap = 5 } })
    run2.consumables = { held("c_immolate", "Spectral") }
    local before = #run2.deck
    use(run2, "c_immolate")
    t.eq(run2.economy.dollars, 23, "Immolate pays +$20")
    t.eq(#run2.deck, before - 5, "Immolate destroys 5 deck cards")
  end

  -- ---- generators: Judgement/Soul -> joker, High Priestess/Emperor -> consumables ----
  do
    local run = new_run()
    run.consumables = { held("c_judgement") }
    use(run, "c_judgement")
    t.eq(#run.jokers, 1, "Judgement creates a joker")
    t.eq(#run.consumables, 0, "Judgement is consumed")

    local run2 = new_run()
    run2.consumables = { held("c_soul", "Spectral") }
    use(run2, "c_soul")
    t.eq(#run2.jokers, 1, "The Soul creates a joker (Legendary pool)")

    -- Judgement with a FULL board creates nothing (real rule: needs room)
    local full = new_run({ joker_slots = 1, jokers = { { key = "j_joker" } } })
    full.consumables = { held("c_judgement") }
    use(full, "c_judgement")
    t.eq(#full.jokers, 1, "Judgement on a full board creates no joker")

    local run3 = new_run()
    run3.consumables = { held("c_high_priestess") }
    use(run3, "c_high_priestess")
    t.eq(#run3.consumables, 2, "High Priestess creates 2 Planets (fills both slots)")
    t.ok(CV.PLANET_KEY_HAND[run3.consumables[1].key] ~= nil, "High Priestess creates actual Planets")
  end

  -- ---- Fool recreates the last tarot/planet used ----
  do
    local run = new_run({ economy = { dollars = 0, interest_cap = 5 } })
    -- use a planet first so _last_consumable is set, then a Fool recreates it
    run.consumables = { held("c_saturn", "Planet") }
    use(run, "c_saturn")
    t.eq(run._last_consumable and run._last_consumable.key, "c_saturn", "last-used tracked for Fool")
    run.consumables = { held("c_fool") }
    use(run, "c_fool")
    t.eq(#run.consumables, 1, "Fool recreates one consumable")
    t.eq(run.consumables[1].key, "c_saturn", "Fool recreates the last-used (Saturn)")
  end

  -- ---- A6: pack picks are USED immediately when slots are full (never silently lost) ----
  do
    local Content = require("sim.content")
    -- a planet picked with FULL consumable slots levels its hand (no slot needed)
    local run = new_run({ consumable_slots = 2,
      consumables = { held("c_pluto", "Planet"), held("c_mercury", "Planet") } })  -- slots full
    Content._apply_pack_consumable_now(run, { set = "Planet", key = "c_jupiter", name = "c_jupiter" }, World.lcg(3))
    t.eq(run.hand_levels["Flush"] and run.hand_levels["Flush"].level, 2, "A6: a slot-full Planet pick levels Flush (not lost)")
    t.eq(#run.consumables, 2, "A6: the used Planet pick is not stored (slots unchanged)")

    -- a money tarot picked with full slots pays out immediately
    local run2 = new_run({ economy = { dollars = 8, interest_cap = 5 },
      consumables = { held("c_pluto", "Planet"), held("c_mercury", "Planet") } })
    Content._apply_pack_consumable_now(run2, { set = "Tarot", key = "c_hermit", name = "c_hermit" }, World.lcg(4))
    t.eq(run2.economy.dollars, 16, "A6: a slot-full Hermit pick still doubles money (8 -> 16)")

    -- an enhancement tarot picked with full slots mutates a real deck card (persists)
    local run3 = new_run({ consumables = { held("c_pluto", "Planet"), held("c_mercury", "Planet") } })
    local before = 0
    for _, c in ipairs(run3.deck) do if c.enhancement == "m_bonus" then before = before + 1 end end
    Content._apply_pack_consumable_now(run3, { set = "Tarot", key = "c_hierophant", name = "c_hierophant" }, World.lcg(5))
    local after = 0
    for _, c in ipairs(run3.deck) do if c.enhancement == "m_bonus" then after = after + 1 end end
    t.ok(after > before, "A6: a slot-full Hierophant pick enhances deck cards (deck mutation persists)")
  end

  -- ---- engine PROPOSES using free-value held generators (unclogs slots) ----
  do
    -- Black Hole: proposed whenever held (free leveling, no slot needed)
    local gs = {
      jokers = {}, consumables = { held("c_black_hole", "Spectral") },
      economy = { dollars = 5 }, deck = World.standard_deck(),
      blind = { target_chips = 300, chips_scored = 0, hands_left = 4, discards_left = 4 },
      run = { joker_slots = 5, consumable_slots = 2, hand_levels = {} },
      hand = {},
    }
    for i, r in ipairs({ 14, 13, 12, 11, 10, 9, 8, 7 }) do gs.hand[i] = { id = i, rank_id = r, suit = "Spades" } end
    local ranked = Decision.decide(gs)
    t.ok(ranked and ranked.best and ranked.best.type == "USE_CONSUMABLE",
      "engine proposes USING a held Black Hole (was: clogs a slot forever)")

    -- Judgement with a FULL joker board is NOT proposed (no room -> not free value)
    local gs2 = {
      jokers = { {key="a"},{key="b"},{key="c"},{key="d"},{key="e"} },
      consumables = { held("c_judgement") },
      economy = { dollars = 5 }, deck = World.standard_deck(),
      blind = { target_chips = 300, chips_scored = 0, hands_left = 4, discards_left = 4 },
      run = { joker_slots = 5, consumable_slots = 2, hand_levels = {} }, hand = {},
    }
    for i, r in ipairs({ 14, 13, 12, 11, 10, 9, 8, 7 }) do gs2.hand[i] = { id = i, rank_id = r, suit = "Spades" } end
    local ranked2 = Decision.decide(gs2)
    t.ok(ranked2 and ranked2.best and ranked2.best.type ~= "USE_CONSUMABLE",
      "engine does NOT use Judgement with no free joker slot")
  end
end
