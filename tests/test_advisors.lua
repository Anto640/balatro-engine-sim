-- tests/test_advisors.lua
-- Tests skip advisor, voucher values, pack valuation, and the measured planet /
-- hand-frequency tool. Pure/headless.

local Skip = require("engine.skip_advisor")
local Tags = require("engine.tags")
local Vouchers = require("engine.vouchers")
local CV = require("engine.consumable_value")
local Packs = require("engine.packs")
local PackOpen = require("engine.pack_open_advisor")
local SA = require("engine.shop_advisor")
local Mechanics = require("engine.mechanics")
local GS = require("model.game_state")
local Cards = require("util.cards")
local card, joker = GS.card, GS.joker

local function lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end

return function(t)
  -- ---- tag values (economic) ----
  t.eq(({ Tags.value(GS.new{}, "tag_investment") })[1], 25, "Investment tag worth $25")
  t.eq(({ Tags.value(GS.new{ economy = { dollars = 30 } }, "tag_economy") })[1], 30, "Economy tag = min($,40)")
  t.eq(({ Tags.value(GS.new{ economy = { dollars = 100 } }, "tag_economy") })[1], 40, "Economy tag capped at 40")

  -- ---- Phase 3: scoring/content tags are CALCULATED (deck-aware), not flat ----
  do
    local flush = {}
    for r = 2, 14 do flush[#flush + 1] = card{ id = #flush + 1, rank_id = r, suit = "Hearts" } end
    for r = 2, 14 do flush[#flush + 1] = card{ id = #flush + 1, rank_id = r, suit = "Hearts" } end
    local mixed = {}
    for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do mixed[#mixed + 1] = card{ id = #mixed + 1, rank_id = r, suit = s } end
    end
    local function gsd(deck) return GS.new{ deck = deck, meta = { ante = 2 }, run = { hand_levels = {}, hand_size = 8 } } end
    local opt = function() return { rng = lcg(4), samples = 16 } end

    -- Orbital (+3 hand levels) is valued by the hand you actually make: a deck that
    -- reliably hits Flush gets more than a scattered deck. Flat prior with no deck.
    local orb_flush = ({ Tags.value(gsd(flush), "tag_orbital", opt()) })[1]
    local orb_mixed = ({ Tags.value(gsd(mixed), "tag_orbital", opt()) })[1]
    t.ok(orb_flush > orb_mixed, "Orbital worth more leveling a concentrated flush hand (deck-aware)")
    t.eq(({ Tags.value(GS.new{}, "tag_orbital") })[1], 12, "no deck -> Orbital uses its flat prior")

    -- The Orbital tag levels the hand NAMED on the tag (G.GAME.orbital_choices -> gs.blind.skip_tag_hand),
    -- not your best hand (owner 2026-09-23: skipped ante 2's Big blind for a "~$124" Orbital that levelled a
    -- random hand). A named hand this deck never makes is worth ~nothing; a hand it makes is worth more.
    do
      local function gsh(hand) local g = gsd(mixed); g.blind = { skip_tag_hand = hand }; return g end
      local never = ({ Tags.value(gsh("Flush Five"), "tag_orbital", opt()) })[1]
      local pair  = ({ Tags.value(gsh("Pair"), "tag_orbital", opt()) })[1]
      t.ok(never < 0.1, "Orbital naming a hand the deck never makes (Flush Five) is worth ~$0")
      t.ok(pair > 1, "Orbital naming a hand the deck makes (Pair) keeps real value")
    end

    -- V2c finishing move: with the leveling-push gate OPEN (committed hand + banked +
    -- ante>=4), Orbital co-moves with the other leveling channels (it delivers +3 levels
    -- of the committed hand). Same deck + same seeded rng, only the gate differs.
    do
      local BuildPlan = require("engine.build_plan")
      local function gsc(cash)
        return GS.new{ deck = flush, meta = { ante = 5 }, economy = { dollars = cash },
          run = { hand_levels = {}, hand_size = 8,
            build_plan = { kind = "hand", hand = "Flush", committed_ante = 3, strength = 4 } } }
      end
      local closed = ({ Tags.value(gsc(BuildPlan.PUSH_MIN_DOLLARS - 1), "tag_orbital", opt()) })[1]
      local opened = ({ Tags.value(gsc(BuildPlan.PUSH_MIN_DOLLARS), "tag_orbital", opt()) })[1]
      t.ok(opened > closed, "leveling-push gate open -> the Orbital tag's value rises (co-moved channel)")
      local opened2 = ({ Tags.value(gsc(BuildPlan.PUSH_MIN_DOLLARS), "tag_orbital", opt()) })[1]
      t.eq(opened, opened2, "the pushed Orbital value is deterministic (seeded rng, no shared-stream use)")
    end

    -- Pack tags reuse the measured MEGA-pack valuation; flat prior with no deck.
    t.ok(({ Tags.value(gsd(flush), "tag_meteor", opt()) })[1] > 0, "Meteor tag valued via measured Celestial pack")
    t.eq(({ Tags.value(GS.new{}, "tag_meteor") })[1], 7, "no deck -> Meteor uses its flat prior")
    t.ok(({ Tags.value(gsd(flush), "tag_buffoon", opt()) })[1] > 0, "Buffoon tag valued via measured Buffoon pack")
    t.eq(({ Tags.value(GS.new{}, "tag_buffoon") })[1], 9, "no deck -> Buffoon uses its flat prior")
  end

  -- ---- joker-granting tags valued by the MEASURED joker (rarity-ordered, slot-gated) ----
  -- Sim found the engine declined a free Rare joker EVERY time (flat $9 prior < playing).
  -- Value it like the shop would value the joker (deck-aware), floored by rarity tier so a
  -- conditional Rare isn't ranked below an Uncommon, and gated by free slots (a joker that
  -- can't fit is lost, so don't skip a blind for it).
  do
    local mixed = {}
    for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do mixed[#mixed + 1] = card{ id = #mixed + 1, rank_id = r, suit = s } end
    end
    local opt = function() return { rng = lcg(9), samples = 6 } end
    local function gsj(njok)
      local jk = {}; for i = 1, njok do jk[i] = { key = "j_joker" } end
      return GS.new{ deck = mixed, jokers = jk, meta = { ante = 3 },
        run = { hand_levels = {}, hand_size = 8, joker_slots = 5 } }
    end
    local rare = ({ Tags.value(gsj(1), "tag_rare", opt()) })[1]
    local unc  = ({ Tags.value(gsj(1), "tag_uncommon", opt()) })[1]
    t.ok(rare > 9, "free Rare joker tag valued above its old flat $9 prior (measured)")
    t.ok(rare >= unc, "a free Rare joker is valued at least as high as a free Uncommon")
    local rare_full = ({ Tags.value(gsj(5), "tag_rare", opt()) })[1]
    t.ok(rare_full < rare, "full board: a joker tag is worth far less (the joker would be lost)")
    t.eq(({ Tags.value(GS.new{}, "tag_rare") })[1], 14, "no deck -> Rare tag uses its flat prior")
  end

  -- ---- skip advisor ----
  do
    -- BOARDLESS: even a $25 Investment tag does NOT justify skipping your FIRST shop --
    -- arriving at the boss with a bare deck loses the run (sim-confirmed). Play to build.
    local bare = GS.new{ blind = { blind_type = "Small", base_hands = 4, skip_tag = "tag_investment" } }
    t.eq(Skip.recommend(bare).recommend, "PLAY", "boardless: play the blind, don't skip your first shop")
    -- WITH A BUILT BOARD: the shop matters less, so a strong Investment tag justifies a skip.
    local built = GS.new{
      jokers = { joker{ key = "j_baron" }, joker{ key = "j_baron" }, joker{ key = "j_baron" },
                 joker{ key = "j_baron" }, joker{ key = "j_baron" } },
      run = { joker_slots = 5 },
      blind = { blind_type = "Small", base_hands = 4, skip_tag = "tag_investment" } }
    t.eq(Skip.recommend(built).recommend, "SKIP", "full board: a $25 Investment tag justifies skipping")
  end
  do
    -- weak tag -> PLAY (even with a full board, a Juggle tag isn't worth a skip)
    local gs = GS.new{ blind = { blind_type = "Small", base_hands = 4, skip_tag = "tag_juggle" } }
    t.eq(Skip.recommend(gs).recommend, "PLAY", "play through a weak tag")
  end
  do
    -- boss blind is unskippable
    local gs = GS.new{ blind = { blind_type = "Boss", skip_tag = "tag_investment" } }
    t.ok(Skip.recommend(gs) == nil, "cannot skip the boss")
  end

  -- ---- voucher value ----
  do
    local v1 = ({ Vouchers.value(GS.new{}, "v_antimatter") })[1]
    local v2 = ({ Vouchers.value(GS.new{}, "v_blank") })[1]
    t.ok(v1 > v2, "Antimatter (+joker slot) worth more than Blank")
    local _, econ = Vouchers.value(GS.new{}, "v_money_tree")
    t.ok(econ > 0, "Money Tree has recurring economy value")
  end

  -- ---- W-SLOT: Blank is an OPTION on Antimatter, not a flat zero ----------
  -- 0.0 was CORRECT while the world could never offer Antimatter; once upgrade vouchers
  -- generate (sim/content.lua UPGRADE_VOUCHERS) it is wrong -- Blank is the only key to the
  -- +1 joker slot the Phase A probe measured as the binding constraint.
  do
    local early = ({ Vouchers.value(GS.new{ meta = { ante = 1 } }, "v_blank") })[1]
    local mid   = ({ Vouchers.value(GS.new{ meta = { ante = 4 } }, "v_blank") })[1]
    local late  = ({ Vouchers.value(GS.new{ meta = { ante = 7 } }, "v_blank") })[1]
    t.ok(early > 0, "Blank is worth something EARLY (runway to collect on the option)")
    t.ok(early > mid, "Blank decays as the runway shrinks")
    t.eq(late, 0, "Blank is worth NOTHING with no antes left to be offered Antimatter")
    t.ok(early <= Vouchers.BLANK_CAP + 1e-9, "the Blank option is capped")
    -- it must never out-value the thing it is an option ON
    local anti = ({ Vouchers.value(GS.new{ meta = { ante = 1 } }, "v_antimatter") })[1]
    t.ok(anti > early, "Antimatter always outranks the option on it")
  end

  -- ---- Phase 2: vouchers are SITUATIONAL, not a flat table ----
  do
    -- a focused Hearts deck (concentrated on Flush) vs a full mixed deck (play
    -- spread across many hands). Mid-game ante so measured values don't saturate.
    local flush_deck = {}
    for r = 2, 14 do flush_deck[#flush_deck + 1] = card{ id = #flush_deck + 1, rank_id = r, suit = "Hearts" } end
    for r = 2, 14 do flush_deck[#flush_deck + 1] = card{ id = #flush_deck + 1, rank_id = r, suit = "Hearts" } end
    local mixed_deck = {}
    for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do mixed_deck[#mixed_deck + 1] = card{ id = #mixed_deck + 1, rank_id = r, suit = s } end
    end
    local function gsd(deck)
      return GS.new{ deck = deck, meta = { ante = 4 }, run = { hand_levels = {}, hand_size = 8 } }
    end
    local opt = function(extra)
      local o = { samples = 16, rng = lcg(9) }
      if extra then for k, v in pairs(extra) do o[k] = v end end
      return o
    end

    -- Observatory (planet x1.5) carries a positive, measured bonus on a deck with a
    -- real planet hand -- it is NOT just the flat base prior.
    local obs = ({ Vouchers.value(gsd(flush_deck), "v_observatory", opt()) })[1]
    t.ok(obs > 5.0, "Observatory's value rises above its base on a planet-capable deck (situational)")

    -- Telescope (celestial = most-played planet) is worth more when play is
    -- concentrated on one hand (the flush deck) than spread across a full deck.
    local tel_flush = ({ Vouchers.value(gsd(flush_deck), "v_telescope", opt()) })[1]
    local tel_mixed = ({ Vouchers.value(gsd(mixed_deck), "v_telescope", opt()) })[1]
    t.ok(tel_flush > tel_mixed, "Telescope worth more with concentrated play (situational)")

    -- +1 hand (Grabber) is worth more when survival is at risk than when secure.
    local g_risk = ({ Vouchers.value(gsd(flush_deck), "v_grabber", opt{ at_risk = true }) })[1]
    local g_safe = ({ Vouchers.value(gsd(flush_deck), "v_grabber", opt{ at_risk = false }) })[1]
    t.ok(g_risk > g_safe, "an extra hand is worth more when at risk (stance-aware)")

    -- with NO deck the situational term is silent: just the base prior (so the
    -- deckless callers/tests above still see a stable number).
    t.eq(({ Vouchers.value(GS.new{}, "v_observatory") })[1], 5.0, "no deck -> Observatory falls back to its base prior")
  end

  -- ---- measured planet / hand-frequency (deck-aware) ----
  do
    -- a deck of all one suit and rank-spread makes Flush the common best hand
    local deck = {}
    local suits = { "Hearts" }
    for _, s in ipairs(suits) do
      for r = 2, 14 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = s } end
      for r = 2, 14 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = s } end
    end
    local gs = GS.new{ deck = deck, run = { hand_levels = {}, hand_size = 8 } }
    local freq = CV.hand_frequencies(gs, { samples = 16, rng = lcg(3) })
    t.ok(freq ~= nil, "hand frequencies measurable")
    local total = 0
    for _, f in pairs(freq) do total = total + f end
    t.near(total, 1.0, "hand frequencies sum to ~1", 1e-6)
    local bp = CV.best_planet(gs, { samples = 16, rng = lcg(3) })
    t.ok(bp ~= nil and bp.value > 0, "a best planet to level is identified, with positive value")
  end

  -- ---- Phase 6: planet freq fallback is computed/honest, not a flat 0.4 ----
  do
    local flush = {}
    for r = 2, 14 do flush[#flush + 1] = card{ id = #flush + 1, rank_id = r, suit = "Hearts" } end
    for r = 2, 14 do flush[#flush + 1] = card{ id = #flush + 1, rank_id = r, suit = "Hearts" } end
    local fgs = GS.new{ deck = flush, run = { hand_levels = {}, hand_size = 8 } }

    -- no freq table given, but a deck exists -> frequencies are COMPUTED (a Flush
    -- planet is valuable on a flush deck), not assumed at 0.4.
    local vj = ({ CV.card_value(fgs, "Planet", "c_jupiter", nil, 1, lcg(3)) })[1]
    t.ok(vj > 0, "planet value is computed from the deck when no freq table is provided")

    -- a freq table that OMITS the hand means you never make it -> worth 0, NOT the
    -- 0.4 prior (the bug this fixes: an absent entry was treated as 0.4).
    local v0 = ({ CV.card_value(fgs, "Planet", "c_jupiter", { ["High Card"] = 1.0 }, 1, lcg(3)) })[1]
    t.eq(v0, 0, "provided freq without the hand -> a planet for an unmade hand is worth 0")

    -- only a deckless state falls back to the 0.4 frequency prior.
    t.ok(({ CV.card_value(GS.new{}, "Planet", "c_jupiter", nil, 1) })[1] > 0, "no deck -> 0.4 frequency prior")
  end

  -- ---- pack sizes (see N, pick K) ----
  do
    local kind, n, k = Packs.size_of("p_arcana_mega_1")
    t.eq(kind, "tarot", "arcana -> tarot"); t.eq(n, 5, "arcana mega sees 5"); t.eq(k, 2, "arcana mega picks 2")
    local k2, n2, p2 = Packs.size_of("p_buffoon_normal")
    t.eq(k2, "joker", "buffoon -> joker"); t.eq(n2, 2, "buffoon normal sees 2"); t.eq(p2, 1, "buffoon normal picks 1")
    local k3, n3, p3 = Packs.size_of("p_celestial_jumbo")
    t.eq(n3, 5, "celestial jumbo sees 5"); t.eq(p3, 1, "celestial jumbo picks 1")
  end

  -- ---- expected pick: more cards seen / more picks => more value ----
  do
    local pool = {}
    for i = 1, 10 do pool[i] = { v = i * 0.1, w = 1 } end
    local mega = Packs.expected_pick(pool, 4, 2, lcg(5))
    local normal = Packs.expected_pick(pool, 2, 1, lcg(5))
    t.ok(mega > normal, "mega (4 see / 2 pick) beats normal (2 see / 1 pick)")
  end

  -- ---- buffoon / spectral / tarot packs all produce a positive value ----
  do
    local gs = GS.new{ jokers = {}, economy = { dollars = 10 } }
    local vb = ({ Packs.value(gs, { key = "p_buffoon_mega" }, { rng = lcg(1) }) })[1]
    local vs = ({ Packs.value(gs, { key = "p_spectral_normal" }, { rng = lcg(1) }) })[1]
    local vt = ({ Packs.value(gs, { key = "p_arcana_mega" }, { rng = lcg(1) }) })[1]
    t.ok(vb > 0, "buffoon pack has positive value")
    t.ok(vs > 0, "spectral pack has positive value")
    t.ok(vt > 0, "arcana pack has positive value")
    -- a Mega buffoon (pick 2) should beat a Normal buffoon (pick 1)
    local vb_n = ({ Packs.value(gs, { key = "p_buffoon_normal" }, { rng = lcg(1) }) })[1]
    t.ok(vb >= vb_n, "mega buffoon >= normal buffoon")
  end

  -- ---- E-11 sync: the Standard-pack card pool mirrors the world's verified rates ----
  do
    local W = Packs._CARD_W
    local total = W.plain + W.enhanced + W.edition + W.seal
    t.near(W.enhanced / total, 0.40, "enhanced cards weighted at the real 40% (was ~17%)", 0.05)
    t.near(W.seal / total, 0.20, "seals weighted at the real 20%", 0.05)
    t.ok(W.edition / total < 0.10, "editions weighted at the real ~8% (was over-weighted)")
    local gs = GS.new{ jokers = {}, economy = { dollars = 10 } }
    t.ok(({ Packs.value(gs, { key = "p_standard_normal" }, { rng = lcg(1) }) })[1] > 0,
      "standard pack still values positive under the synced pool")
  end

  -- ---- B5: pack/reroll pool math ----
  do
    -- deck + a BUILT board (jokers a destructive spectral would wipe)
    local deck = {}
    for _, su in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = su } end
    end
    local built = GS.new{ deck = deck, economy = { dollars = 10 },
      jokers = { joker{ key = "j_duo", ability = { x_mult = 2 } }, joker{ key = "j_cavendish", ability = { x_mult = 3 } },
                 joker{ key = "j_baron" }, joker{ key = "j_scholar" }, joker{ key = "j_joker" } },
      run = { hand_levels = {}, hand_size = 8, joker_slots = 5 } }
    local empty = GS.new{ deck = deck, economy = { dollars = 10 }, jokers = {},
      run = { hand_levels = {}, hand_size = 8, joker_slots = 5 } }

    -- B5 (spectral): card_value accounts for Hex DESTROYING your jokers, and the spectral
    -- pool now uses it -- so Hex is a disaster on a built board (was the raw +0.6 prior).
    local hex_built = ({ CV.card_value(built, "Spectral", "c_hex", nil, 1, lcg(4)) })[1]
    local hex_empty = ({ CV.card_value(empty, "Spectral", "c_hex", nil, 1, lcg(4)) })[1]
    t.ok(hex_built < 0, "B5: Hex is negative on a built board (destroys your jokers)")
    t.ok(hex_built < hex_empty, "B5: Hex is worse the more jokers you'd lose")
    -- the Spectral pack itself stays finite/positive (Soul/Black Hole dominate; Hex floors to 0)
    local vs = ({ Packs.value(built, { key = "p_spectral_mega" }, { rng = lcg(6) }) })[1]
    t.ok(vs > 0 and vs < 100, "B5: spectral pack finite/positive; no Hex/Ankh over-valuation")

    -- ---- SPECTRAL WIRING (2026-09-04): 12 flat-prior spectrals -> the deck-aware machinery ----
    -- Black Hole (+1 level to EVERY hand) is now MEASURED (Packs.black_hole_value) not the flat 0.9 prior --
    -- one price, and deck-aware. The four SEAL spectrals were an indistinguishable flat 0.2; now each is
    -- priced by its real effect (Gold $3 / Blue Planet / Purple Tarot via card_econ_value; Red retrigger),
    -- so they DIFFER. Sigil (flush enabler) is measured off the deck, not a flat 0.3.
    do
      local Mech = require("engine.mechanics")
      local need = Mech.boss_per_hand_need(built)
      local bh = ({ CV.card_value(built, "Spectral", "c_black_hole", nil, need, lcg(4), 8) })[1]
      t.ok(bh and bh > 0, "Black Hole has a positive measured value")
      t.ok(math.abs(bh - 0.9) > 1e-6, "Black Hole is MEASURED, not the flat 0.9 prior")
      local seals = {}
      for _, k in ipairs({ "c_talisman", "c_deja_vu", "c_trance", "c_medium" }) do
        seals[k] = ({ CV.card_value(built, "Spectral", k, nil, need, lcg(4), 8) })[1]
      end
      -- they are no longer all the flat 0.2: at least two of the four differ
      local allsame = true
      for _, k in ipairs({ "c_deja_vu", "c_trance", "c_medium" }) do
        if math.abs(seals[k] - seals.c_talisman) > 1e-4 then allsame = false end
      end
      t.ok(not allsame, "the four seal spectrals are now DISTINGUISHED (not a flat 0.2 each)")
      -- each is non-negative and priced by its real effect (Blue's Planet value scales with the board's
      -- xmult -- Duo x2 * Cavendish x3 here -- so it is not bounded to <1; see the B2 note below).
      for _, k in ipairs({ "c_talisman", "c_deja_vu", "c_trance", "c_medium" }) do
        t.ok(seals[k] >= 0 and seals[k] < 5, k .. " is priced by its real seal effect (deck-aware, finite)")
      end
      local sig = ({ CV.card_value(built, "Spectral", "c_sigil", nil, need, lcg(4), 8) })[1]
      t.ok(sig and sig >= 0 and sig < 5, "Sigil is measured off the deck (finite flush value), not a flat 0.3")

      -- ---- TIER 2 (real modelling): Soul, Cryptid, Aura, and the destroy-and-add group ----
      local soul_free = ({ CV.card_value(empty, "Spectral", "c_soul", nil, need, lcg(4), 6) })[1]
      local bh_e = ({ CV.card_value(empty, "Spectral", "c_black_hole", nil, need, lcg(4), 6) })[1]
      t.ok(soul_free and soul_free > bh_e, "Soul (a Legendary joker) is the top spectral, above Black Hole")
      -- Soul is slot-aware: a legendary you'd sell for, so a full board is a haircut not zero
      local soul_full = ({ CV.card_value(built, "Spectral", "c_soul", nil, need, lcg(4), 6) })[1]
      t.ok(soul_full and soul_full > 0 and soul_full < soul_free,
        "Soul is slot-aware (full board < free slot, but still positive -- you'd sell for a Legendary)")
      -- the destroy-and-add group is modelled and scales with how many cards it adds (Incantation 4 > Grim 2)
      local fam = ({ CV.card_value(empty, "Spectral", "c_familiar", nil, need, lcg(4), 8) })[1]
      local grim = ({ CV.card_value(empty, "Spectral", "c_grim", nil, need, lcg(4), 8) })[1]
      local inc = ({ CV.card_value(empty, "Spectral", "c_incantation", nil, need, lcg(4), 8) })[1]
      t.ok(fam and grim and inc, "Familiar/Grim/Incantation are all modelled (not the flat 0.25 prior)")
      t.ok(inc > grim, "Incantation (adds 4) is worth more than Grim (adds 2)")
      -- Cryptid and Aura are modelled and finite (Cryptid floored like DNA for the compounding it can't measure)
      local cry = ({ CV.card_value(empty, "Spectral", "c_cryptid", nil, need, lcg(4), 8) })[1]
      local aura = ({ CV.card_value(empty, "Spectral", "c_aura", nil, need, lcg(4), 8) })[1]
      t.ok(cry and cry >= CV.CRYPTID_FLOOR - 1e-9, "Cryptid is modelled (>= its DNA-style compounding floor)")
      t.ok(aura and aura >= 0 and aura < 1, "Aura is a deck-aware edition estimate (not the flat 0.35)")
    end

    -- B5 (w^2): joker_pool items are now equal-weighted (rarity already sampled), so the rare
    -- tail isn't double-clipped. Sanity: the expected best joker is positive and rises with more
    -- slots seen (order statistics), which relies on a non-degenerate pool.
    local ev1 = Packs.expected_shop_joker(built, 1, { rng = lcg(7), samples = 4 })
    local ev4 = Packs.expected_shop_joker(built, 4, { rng = lcg(7), samples = 4 })
    t.ok(ev1 > 0, "B5: expected joker EV is positive (rare tail intact)")
    t.ok(ev4 >= ev1, "B5: seeing more slots never lowers the best-joker EV")

    -- B2: a Blue seal spawns a Planet if held -> its econ value must be the NORMALISED planet
    -- value (a boss-hand fraction), not the RAW best_planet() score that auto-dominated picks.
    --
    -- This asserts the NORMALISATION, not a magnitude. The original bound (blue < 0.5) was
    -- calibrated against `CV.level_gain`'s base-only figure, which understated a hand level by
    -- 1.4-19x depending on board strength; `built` carries Duo x2 AND Cavendish x3, so on that
    -- board a level really is worth a large fraction of a boss hand and the old ceiling now
    -- fails for the right reason. Pinning the ratio to best_planet keeps the regression this
    -- test exists for (a ~100x scale error) while staying correct under the fixed valuation.
    local rng = lcg(11)
    local blue = CV.card_econ_value(built, { rank_id = 13, suit = "Spades", seal = "Blue" }, rng)
    local gold = CV.card_econ_value(built, { rank_id = 13, suit = "Spades", seal = "Gold" })
    local bp = CV.best_planet(built, { samples = 6, rng = lcg(11) })
    local raw = bp and bp.value or 0
    t.ok(blue > 0, "B2: a Blue seal is worth something (it spawns a Planet)")
    t.ok(raw > 10 * blue, "B2: Blue-seal value is NORMALISED, not the raw best_planet score")
    t.ok(blue > gold, "B2: a spawned Planet beats a Gold seal's $3 on a built board")

    -- and the seal's value must be DETERMINISTIC for a given state: the Blue branch samples
    -- the deck, and sampling on the global RNG is what makes the live panel flicker.
    t.eq(CV.card_econ_value(built, { rank_id = 13, suit = "Spades", seal = "Blue" }, lcg(11)),
         CV.card_econ_value(built, { rank_id = 13, suit = "Spades", seal = "Blue" }, lcg(11)),
      "B2: Blue-seal value is deterministic under a seeded rng")
  end

  -- ---- Phase 4: pack content pools are CALCULATED (deck-aware), not static ----
  do
    -- de-dup sanity: the tarot/spectral priors live in ONE place now (CV), and the
    -- pack pools read them from there.
    t.ok(CV.TAROT_BASE.c_judgement and CV.SPECTRAL_BASE.c_soul, "tarot/spectral priors are single-sourced in consumable_value")

    local flush = {}
    for r = 2, 14 do flush[#flush + 1] = card{ id = #flush + 1, rank_id = r, suit = "Hearts" } end
    for r = 2, 14 do flush[#flush + 1] = card{ id = #flush + 1, rank_id = r, suit = "Hearts" } end
    local fgs = GS.new{ deck = flush, meta = { ante = 2 }, run = { hand_levels = {}, hand_size = 8 } }

    -- Black Hole (+1 to every hand) is MEASURED against the deck: a flush deck that
    -- reliably makes a high-value hand gets real value; no deck -> not measurable.
    local bh = Packs.black_hole_value(fgs, { samples = 16, rng = lcg(3) })
    t.ok(bh and bh > 0, "Black Hole valued by measured hand frequencies x level gain")
    t.ok(Packs.black_hole_value(GS.new{}) == nil, "no deck -> Black Hole not measurable")

    -- An enhancement tarot (Empress -> +Mult on played cards) is valued via the same
    -- MEASURED path a loose shop tarot uses -- so the Arcana pool is deck-aware, not
    -- the flat TAROT_BASE prior. The note flags that the measured branch was taken.
    local _, _, note = CV.card_value(fgs, "Tarot", "c_empress", nil, 1, lcg(3))
    t.ok(note and note:find("enhance"), "enhancement tarot took the MEASURED path (deck-aware), not the flat prior")

    -- Standard pack is deck-aware: its value is computed from the deck (differs from
    -- the no-deck static prior).
    local std_deck = ({ Packs.value(fgs, { key = "p_standard_mega" }, { rng = lcg(7) }) })[1]
    local std_none = ({ Packs.value(GS.new{}, { key = "p_standard_mega" }, { rng = lcg(7) }) })[1]
    t.ok(std_deck > 0 and math.abs(std_deck - std_none) > 1e-9, "standard pack value is calculated from the deck, not a fixed prior")
  end

  -- ---- opened pack: revealed jokers are valued by MEASUREMENT ----
  do
    local deck = {}
    for r = 2, 14 do deck[#deck + 1] = card{ id = r, rank_id = r, suit = "Hearts" } end
    for r = 2, 14 do deck[#deck + 1] = card{ id = 100 + r, rank_id = r, suit = "Hearts" } end
    local gs = GS.new{ deck = deck, run = { hand_levels = {}, hand_size = 8 },
      pack = { items = {
        { set = "Joker", key = "j_lusty_joker", name = "Lusty", joker = joker{ key = "j_lusty_joker" } },
        { set = "Joker", key = "j_wrathful_joker", name = "Wrathful", joker = joker{ key = "j_wrathful_joker" } },
      }, picks_left = 1 } }
    local r = PackOpen.recommend(gs)
    t.ok(r ~= nil and r.picks and r.picks[1], "opened-pack recommendation produced")
    t.eq(r.picks[1].key, "j_lusty_joker", "picks the measured-better joker on a Hearts deck")
    t.ok(r.picks[1].meas, "the pick value was measured")
  end

  -- ---- Mega Celestial: take BOTH free planet levels, never skip a spare pick (2026-08-27) ----
  -- A planet is used immediately to LEVEL a hand -- it never bloats the deck and costs no slot, so a
  -- free level is pure upside even when it levels a hand you rarely play (value ~0). On a starved
  -- board the engine was taking one planet and SKIPPING the second (run MALEJYHW); a thin deck makes
  -- every planet value ~0, so baseline skipped the WHOLE pack. Both spare picks must now be taken.
  do
    local deck = {}
    for _, s in ipairs({ "Spades", "Clubs" }) do
      for r = 2, 9 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = s } end
    end
    local gs = GS.new{ deck = deck, meta = { ante = 2 },
      run = { hand_levels = {}, hand_size = 8, consumable_slots = 2 },
      hand = { card{ id = 1, rank = "2", suit = "Spades" }, card{ id = 2, rank = "3", suit = "Clubs" } },
      pack = { picks_left = 2, items = {
        { set = "Planet", key = "c_pluto",   name = "Pluto" },
        { set = "Planet", key = "c_neptune", name = "Neptune" },
        { set = "Planet", key = "c_venus",   name = "Venus" },
        { set = "Planet", key = "c_mercury", name = "Mercury" },
        { set = "Planet", key = "c_mars",    name = "Mars" },
      } } }
    local r = PackOpen.recommend(gs)
    t.ok(not r.skip, "a Celestial pack of free levels is never skipped as 'bloat'")
    t.eq(#r.picks, 2, "a Mega Celestial (pick 2) takes BOTH free planet levels, not one")
    for _, pk in ipairs(r.picks) do t.eq(pk.it.set, "Planet", "...and each pick is a planet") end
  end

  -- ---- opened Buffoon pack, joker slots FULL, all-SCORER board -> CORE-PROTECTED (no sell) ----
  -- The pack-swap sell target now excludes compounding cores AND flat scorers (keep_bias > 0):
  -- selling a scorer to slot a pack joker churns the build (the p5_packswap batch lost both wins
  -- doing exactly this). A board of only flat-mult scorers therefore names NO sell -- the pick is
  -- declined and the board stays intact. (Disposable econ/utility filler IS still sellable: see the
  -- Mail-In Rebate test below.)
  do
    local deck = {}
    for r = 2, 14 do deck[#deck + 1] = card{ id = r, rank_id = r, suit = "Hearts" } end
    for r = 2, 14 do deck[#deck + 1] = card{ id = 100 + r, rank_id = r, suit = "Hearts" } end
    local gs = GS.new{
      deck = deck,
      jokers = { joker{ key = "j_lusty_joker", name = "Lusty Joker" },
                 joker{ key = "j_wrathful_joker", name = "Wrathful Joker" } },
      run = { hand_levels = {}, hand_size = 8, joker_slots = 2 },
      pack = { items = {
        { set = "Joker", key = "j_lusty_joker", name = "Lusty Joker", joker = joker{ key = "j_lusty_joker" } },
      }, picks_left = 1 } }
    local r = PackOpen.recommend(gs)
    t.eq(r.sell, nil, "all-flat-scorer full board -> core protection names NO sell (tail safety)")
  end

  -- ---- full board with a VALUE-ONLY econ joker: it must be sellable, not "unbeatable"
  -- Regression: Mail-In Rebate (econ, zero scoring) was ranked by a tier-prior scoring
  -- fraction and looked unbeatable next to a pack joker's MEASURED fraction, so the
  -- advice was "nothing here beats Mail-In Rebate". Valuing BOTH sides in FV (econ
  -- included) fixes it: a real scoring joker beats the pure-econ one -> sell it.
  do
    local deck = {}
    for r = 2, 14 do deck[#deck + 1] = card{ id = r, rank_id = r, suit = "Hearts" } end
    for r = 2, 14 do deck[#deck + 1] = card{ id = 100 + r, rank_id = r, suit = "Hearts" } end
    local gs = GS.new{
      deck = deck,
      jokers = { joker{ key = "j_lusty_joker", name = "Lusty Joker" },   -- strong on Hearts
                 joker{ key = "j_mail", name = "Mail-In Rebate" } },     -- value-only econ
      run = { hand_levels = {}, hand_size = 8, joker_slots = 2 },        -- board full (2/2)
      pack = { items = {
        { set = "Joker", key = "j_lusty_joker", name = "Lusty Joker", joker = joker{ key = "j_lusty_joker" } },
      }, picks_left = 1 } }
    local r = PackOpen.recommend(gs)
    t.ok(r.sell ~= nil, "a strong scoring pick beats the value-only econ joker -> a SELL is recommended")
    t.eq(r.sell.name, "Mail-In Rebate", "names the value-only econ joker as the weakest to drop")
    t.ok(not r.reason:find("nothing"), "no false 'nothing beats the econ joker' message")
  end

  -- ---- Arcana pack: GENERATOR tarots respect free joker/consumable slots ----------
  -- Emperor/High Priestess/Fool create consumables; Judgement creates a joker. With
  -- no room the creation overflows and is lost, so the advisor must account for slots
  -- (value it down + say how to make room) instead of blindly recommending it.
  do
    local deck = {}
    for r = 2, 14 do deck[#deck + 1] = card{ id = r, rank_id = r, suit = "Hearts" } end
    for r = 2, 14 do deck[#deck + 1] = card{ id = 100 + r, rank_id = r, suit = "Hearts" } end
    local function arc(items, o)
      local gs = { deck = deck, run = { hand_levels = {}, hand_size = 8,
        consumable_slots = (o and o.cslots) or 2, joker_slots = (o and o.jslots) or 5 },
        consumables = (o and o.held) or {}, jokers = (o and o.jokers) or {},
        pack = { picks_left = 1, items = items } }
      return GS.new(gs)
    end
    local function val(items, o)
      for _, v in ipairs(PackOpen.recommend(arc(items, o), { cheap = true }).ranked) do
        if v.key == items[1].key then return v.v end
      end
    end

    -- Emperor (creates 2 Tarots) is worth LESS with consumable slots full than free.
    local emp = { { set = "Tarot", key = "c_emperor", name = "The Emperor" } }
    local v_free = val(emp, { held = {} })
    local v_full = val(emp, { held = { { set = "Tarot", key = "c_magician", name = "The Magician" },
                                        { set = "Tarot", key = "c_devil", name = "The Devil" } } })
    t.ok(v_full < v_free, "Emperor is worth less when consumable slots are full (its created Tarots overflow)")

    -- and the advice says to USE a held consumable to make room
    local r_full = PackOpen.recommend(arc(emp, { held = {
      { set = "Tarot", key = "c_magician", name = "The Magician" },
      { set = "Tarot", key = "c_devil", name = "The Devil" } } }), { cheap = true })
    t.ok(r_full.reason:find("use") and r_full.reason:find("held"), "names using a held consumable to make room")

    -- with a free slot, no make-room warning
    t.ok(not PackOpen.recommend(arc(emp, { held = {} }), { cheap = true }).reason:find("free consumable slot"),
      "free slot -> no overflow warning")

    -- Judgement (creates a joker) with a FULL joker board -> say which joker to sell
    local rj = PackOpen.recommend(arc({ { set = "Tarot", key = "c_judgement", name = "Judgement" } },
      { jslots = 2, jokers = { joker{ key = "j_lusty_joker", name = "Lusty Joker" },
                               joker{ key = "j_mail", name = "Mail-In Rebate" } } }))
    t.ok(rj.reason:find("Joker slots are full") and rj.reason:find("sell"),
      "Judgement with a full board says to sell a joker first")

    -- a slot-blocked generator loses to a usable targeting tarot in the same pack
    local r_alt = PackOpen.recommend(arc({
      { set = "Tarot", key = "c_emperor", name = "The Emperor" },
      { set = "Tarot", key = "c_empress", name = "The Empress" } },
      { held = { { set = "Tarot", key = "c_magician", name = "The Magician" },
                 { set = "Tarot", key = "c_devil", name = "The Devil" } } }), { cheap = true })
    t.eq(r_alt.best.key, "c_empress", "with slots full, a usable Empress is taken over an overflowing Emperor")
  end

  -- ---- Standard pack: the recommendation names the SPECIFIC card (rank + suit) --
  do
    -- Cards.describe: rank + suit, with edition/enhancement front and seal trailing.
    t.eq(Cards.describe(card{ rank_id = 13, suit = "Spades" }), "King of Spades", "plain card names rank + suit")
    t.eq(Cards.describe(card{ rank_id = 14, suit = "Hearts", enhancement = "m_gold", edition = "foil", seal = "Gold" }),
      "Foil Gold Ace of Hearts (Gold seal)", "edition + enhancement + rank/suit + seal all named")

    local deck = {}
    for r = 2, 14 do deck[#deck + 1] = card{ id = r, rank_id = r, suit = "Spades" } end
    for r = 2, 14 do deck[#deck + 1] = card{ id = 100 + r, rank_id = r, suit = "Spades" } end
    local gs = GS.new{ deck = deck, run = { hand_levels = {}, hand_size = 8 },
      pack = { items = {
        -- a Standard-pack card: ability.name would be the generic "Gold Card"
        { set = "Standard", key = "m_gold", name = "Gold Card",
          card = card{ id = 900, rank_id = 13, suit = "Spades", enhancement = "m_gold", seal = "Gold" } },
      }, picks_left = 1 } }
    -- the instant (cheap) pass is what the overlay shows the moment a pack opens
    local r = PackOpen.recommend(gs, { cheap = true })
    t.ok(r ~= nil and r.picks and r.picks[1], "standard-pack recommendation produced")
    t.eq(r.picks[1].name, "Gold King of Spades (Gold seal)", "names the exact card (rank + suit + enhancement + seal)")
    t.ok(r.reason:find("King of Spades"), "the reason states the specific rank and suit, not just 'Gold Card'")
  end

  -- ---- pack valuation is time-sliceable + cheap pass is instant -------------
  -- The overlay shows a priors-only cheap ranking the instant a pack opens, then
  -- refines it with the MEASURED ranking inside a coroutine pumped a few ms/frame
  -- (the hand_eval yield hook drives the slicing). This reproduces that driver and
  -- checks: (a) the cheap pass needs no deck measurement, (b) the sliced measured
  -- result equals the synchronous measured result, (c) the slicing actually fired.
  do
    local HandEval = require("engine.hand_eval")
    local deck = {}
    for r = 2, 14 do deck[#deck + 1] = card{ id = r, rank_id = r, suit = "Hearts" } end
    for r = 2, 14 do deck[#deck + 1] = card{ id = 100 + r, rank_id = r, suit = "Hearts" } end
    local gs = GS.new{ deck = deck, run = { hand_levels = {}, hand_size = 8 },
      blind = { target_chips = 600, boss = true }, meta = { ante = 2 }, economy = { dollars = 12 },
      pack = { picks_left = 2, items = {
        { set = "Tarot", key = "c_empress", name = "The Empress" },
        { set = "Tarot", key = "c_star", name = "The Star" },
        { set = "Tarot", key = "c_magician", name = "The Magician" },
      } } }

    local cheap = PackOpen.recommend(gs, { cheap = true })
    t.ok(cheap ~= nil and cheap.reason, "cheap pack pass produces a recommendation")
    t.ok(not (cheap.picks[1] and cheap.picks[1].meas), "cheap pass is priors-only (not measured)")

    local sync = PackOpen.recommend(gs)   -- synchronous measured

    -- drive a measured recommend through a coroutine, slicing on the yield hook
    local sliced, yields, all_ok = nil, 0, true
    local co = coroutine.create(function() return PackOpen.recommend(gs) end)
    while true do
      HandEval.set_yield(function() yields = yields + 1; coroutine.yield() end)
      local ok, res = coroutine.resume(co)
      HandEval.set_yield(nil)
      if not ok then all_ok = false; break end
      if coroutine.status(co) == "dead" then sliced = res; break end
    end
    t.ok(all_ok, "pack recommend coroutine resumed without error")
    t.ok(yields > 0, "the yield hook sliced the measured pack valuation")
    t.eq(sliced.best and sliced.best.key, sync.best and sync.best.key, "sliced pick == sync pick")
    -- the hook is cleared, so a synchronous best_play (outside any coroutine) must
    -- NOT try to yield -- if the hook leaked it would error "yield across C-call".
    local ran = pcall(HandEval.best_play, gs, { deck[1], deck[2], deck[3], deck[4], deck[5] })
    t.ok(ran, "synchronous best_play runs fine after the yield hook is cleared")
  end

  -- ---- opened pack: pick ORDER respects chains (Judgement before Temperance) ----
  do
    local gs = GS.new{
      jokers = { joker{ key = "j_joker", sell_value = 3 } },
      pack = { items = {
        { set = "Tarot", key = "c_temperance", name = "Temperance" },
        { set = "Tarot", key = "c_judgement", name = "Judgement" },
      }, picks_left = 2 },
    }
    local r = PackOpen.recommend(gs)
    t.ok(r ~= nil and #r.picks == 2, "takes both tarots from a Mega pack")
    t.eq(r.picks[1].key, "c_judgement", "Judgement first (creates a joker -> bigger Temperance)")
    t.eq(r.picks[2].key, "c_temperance", "Temperance second")
  end

  -- ---- The Fool is used AFTER the best card it can copy ----
  do
    local gs = GS.new{ pack = { items = {
      { set = "Tarot", key = "c_fool", name = "The Fool" },
      { set = "Tarot", key = "c_judgement", name = "Judgement" },
    }, picks_left = 2 } }
    local r = PackOpen.recommend(gs)
    t.ok(r ~= nil and #r.picks == 2, "takes both")
    t.eq(r.picks[1].key, "c_judgement", "use the copyable (Judgement) first")
    t.eq(r.picks[2].key, "c_fool", "then the Fool, so it copies Judgement")
  end

  -- ---- The Fool copies your PREVIOUSLY-used card when it beats the pack ----
  do
    local gs = GS.new{
      last_tarot_planet = { key = "c_judgement", name = "Judgement" },
      pack = { items = {
        { set = "Tarot", key = "c_fool", name = "The Fool" },
        { set = "Tarot", key = "c_tower", name = "The Tower" },  -- weak in-pack tarot
      }, picks_left = 2 },
    }
    local r = PackOpen.recommend(gs)
    t.eq(r.picks[1].key, "c_fool", "Fool first to copy the stronger previously-used Judgement")
  end

  -- ---- enhancer is used BEFORE a copier (copy inherits the enhancement) ----
  do
    local gs = GS.new{ pack = { items = {
      { set = "Spectral", key = "c_cryptid", name = "Cryptid" },
      { set = "Tarot", key = "c_devil", name = "The Devil" },
    }, picks_left = 2 } }
    local r = PackOpen.recommend(gs)
    t.eq(r.picks[1].key, "c_devil", "enhancer (Devil) first")
    t.eq(r.picks[2].key, "c_cryptid", "copier (Cryptid) after, so copies are enhanced")
  end

  -- ---- measured card value includes the card AND deck bloat ----
  do
    local deck = {}
    for r = 2, 14 do deck[#deck + 1] = card{ id = r, rank_id = r, suit = "Hearts" } end
    for r = 2, 14 do deck[#deck + 1] = card{ id = 100 + r, rank_id = r, suit = "Hearts" } end
    local gs = GS.new{ deck = deck, run = { hand_levels = {}, hand_size = 8 } }
    local v = CV.card_add_value(gs, card{ rank_id = 14, suit = "Hearts", enhancement = "m_steel" },
                                { need = 150, samples = 12, rng = lcg(2) })
    t.ok(type(v) == "number", "adding a card to the deck has a measurable value")
  end

  -- ---- in-blind income (money-making jokers / gold seals) is estimated ----
  do
    t.ok(SA.estimate_blind_income(GS.new{ jokers = { joker{ key = "j_golden" } } }) >= 4,
      "Golden Joker contributes income")
    t.eq(SA.estimate_blind_income(GS.new{}), 0, "no income with a bare board")
    local gs = GS.new{ deck = {
      card{ rank = "Ace", suit = "Hearts", seal = "Gold" },
      card{ rank = "King", suit = "Spades", seal = "Gold" } } }
    t.ok(SA.estimate_blind_income(gs) > 0, "gold seals contribute income")
  end

  -- ---- card economy/seals are valued (for the open-a-card-pack decision) ----
  do
    local gs = GS.new{}
    t.eq(CV.card_econ_value(gs, card{ rank_id = 5, suit = "Spades" }), 0, "plain card: no economy")
    t.ok(CV.card_econ_value(gs, card{ enhancement = "m_gold" }) > 0, "Gold enhancement: $ economy")
    t.ok(CV.card_econ_value(gs, card{ enhancement = "m_lucky" }) > 0, "Lucky enhancement: $ economy")
    t.ok(CV.card_econ_value(gs, card{ seal = "Gold" }) > 0, "Gold seal: $ when played")
    t.ok(CV.card_econ_value(gs, card{ seal = "Purple" }) > 0, "Purple seal: spawns a tarot")
  end

  -- ---- cost matters: cheaper item of equal effect is preferred ----
  do
    local gs = GS.new{
      economy = { dollars = 20, interest_cap = 5 },
      shop = { jokers = {
        joker{ key = "j_baron", name = "Baron A", cost = 4 },
        joker{ key = "j_baron", name = "Baron B", cost = 9 },
      }, vouchers = {}, joker_slots = 5 },
    }
    local r = SA.recommend(gs)
    t.eq(r.best.type, "BUY_JOKER", "buys a joker")
    t.eq(r.best.target.cost, 4, "prefers the cheaper of two identical jokers")
  end

  -- ---- standalone shop consumable: Hermit at $25 should be BOUGHT ----
  do
    local gs = GS.new{
      economy = { dollars = 25, interest_cap = 5 },
      shop = { jokers = {}, vouchers = {}, consumables = {
        { set = "Tarot", key = "c_hermit", name = "The Hermit", cost = 3 } }, joker_slots = 5 },
    }
    local r = SA.recommend(gs)
    t.eq(r.best.type, "BUY_CONSUMABLE", "Hermit (+$20) beats saving")
    t.eq(r.best.target.key, "c_hermit", "recommends buying the Hermit")
  end

  -- ---- HELD Hermit at max payout: USE it now, don't sit on it (2026-08-26 advice-review #3) ----
  -- The human held a Hermit all game with >$20 and the engine never suggested using it (it only
  -- surfaced a held Hermit to FUND a buy). At >=$20 its +$20 is maxed, so holding gains nothing.
  do
    local function held_hermit(money)
      return GS.new{
        economy = { dollars = money, interest_cap = 5 },
        consumables = { { set = "Tarot", key = "c_hermit", name = "The Hermit" } },
        shop = { jokers = {}, vouchers = {}, joker_slots = 5 },
      }
    end
    -- maxed ($25 >= $20): recommend USING it, not sitting on it
    local r = SA.recommend(held_hermit(25))
    t.eq(r.best.type, "USE_CONSUMABLE", "held Hermit at $25 (maxed) -> USE it now")
    t.eq(r.best.target.key, "c_hermit", "...it is the Hermit being used")
    t.eq(r.best.gain, 20, "...banking the full $20")
    -- NOT maxed ($6 < $20): holding to let the doubling grow is fine -> do not force the use
    local r2 = SA.recommend(held_hermit(6))
    local forced = (r2.best.type == "USE_CONSUMABLE" and r2.best.target.key == "c_hermit")
    t.ok(not forced, "held Hermit at $6 (not maxed) -> not forced to use it yet")
  end

  -- ---- PACK-FIRST sequencing: open an affordable pack BEFORE a shop buy (2026-08-26 review #5) ----
  -- The human's rule: packs are free info, open them before committing cash. When a shop buy AND a
  -- positive-value pack both fit this shop, lead with the pack (non-lossy: the buy stays affordable).
  do
    local function gs(money)
      return GS.new{ economy = { dollars = money, interest_cap = 5 },
        run = { hand_levels = {}, hand_size = 8, joker_slots = 5 },
        shop = { jokers = { joker{ key = "j_baron", name = "Baron", cost = 5 } },
          boosters = { { key = "p_buffoon_normal", name = "Buffoon Pack", cost = 4 } },
          vouchers = {}, joker_slots = 5 } }
    end
    -- plenty for BOTH -> lead with the pack, the buy becomes the top alternative
    local rich = SA.recommend(gs(30))
    t.eq(rich.best.type, "BUY_PACK", "can afford both -> open the pack first")
    local buy_is_alt = false
    for _, a in ipairs(rich.alternatives or {}) do if a.type == "BUY_JOKER" then buy_is_alt = true end end
    t.ok(buy_is_alt, "...and the shop buy is still on the table as an alternative (never forfeited)")
    -- can't afford both -> do NOT reorder (the buy must not be foreclosed by opening the pack)
    local poor = SA.recommend(gs(8))
    t.eq(poor.best.type, "BUY_JOKER", "can't afford both -> keep the buy first, don't open the pack")
  end

  -- ---- reroll is situational: weak shop + cheap roll => considered; a strong
  --      current joker is bought instead of rolling ----
  do
    local gs = GS.new{ economy = { dollars = 20, interest_cap = 5 },
      shop = { jokers = {}, vouchers = {}, reroll_cost = 2, joker_slots = 5 } }
    local r = SA.recommend(gs)
    local has_reroll = (r.best.type == "REROLL")
    for _, a in ipairs(r.alternatives or {}) do if a.type == "REROLL" then has_reroll = true end end
    t.ok(has_reroll, "reroll is on the table for a weak shop with a cheap roll")
  end
  do
    local gs = GS.new{ economy = { dollars = 20, interest_cap = 5 },
      shop = { jokers = { joker{ key = "j_baron", name = "Baron", cost = 4 } },
               vouchers = {}, reroll_cost = 2, joker_slots = 5 } }
    local r = SA.recommend(gs)
    t.eq(r.best.type, "BUY_JOKER", "buy a strong current joker rather than reroll")
  end

  -- ---- a joker's EDITION raises its value (holographic > plain copy) ----
  do
    local gs = GS.new{ economy = { dollars = 20, interest_cap = 5 },
      shop = { jokers = {
        joker{ key = "j_joker", name = "Plain", cost = 4 },
        joker{ key = "j_joker", name = "Holo", cost = 4, edition = "holo" },
      }, vouchers = {}, joker_slots = 5 } }
    local r = SA.recommend(gs)
    t.eq(r.best.type, "BUY_JOKER", "buys a joker")
    t.eq(r.best.target.edition, "holo", "prefers the holographic copy of the same joker")
  end

  -- ---- pack valuation appears in shop recommendation ----
  do
    local gs = GS.new{
      economy = { dollars = 20, interest_cap = 5 },
      shop = { jokers = {}, vouchers = {}, boosters = {
        { key = "p_celestial_normal_1", name = "Celestial Pack", cost = 4 } }, joker_slots = 5 },
    }
    local r = SA.recommend(gs)
    -- a pack candidate should exist among best/alternatives
    local found = (r.best and r.best.type == "BUY_PACK")
    for _, a in ipairs(r.alternatives or {}) do if a.type == "BUY_PACK" then found = true end end
    t.ok(found, "a BUY_PACK option is generated for a Celestial pack")
  end

  -- ---- Hex/Ankh destroy your OTHER jokers -> negative with a built board ----
  do
    local function withN(n)
      local js = {}
      for i = 1, n do js[i] = joker{ key = "j_baron", name = "Baron" } end
      return GS.new{ jokers = js }
    end
    local full = ({ CV.card_value(withN(5), "Spectral", "c_hex") })[1]
    local lone = ({ CV.card_value(withN(1), "Spectral", "c_hex") })[1]
    t.ok(full < 0, "Hex with 5 jokers is valued negative (it destroys 4)")
    t.ok(lone > 0, "Hex with a single joker is fine (polychromes it)")
    t.ok(lone > full, "more jokers on board -> lower Hex value")
    t.ok(({ CV.card_value(withN(5), "Spectral", "c_ankh") })[1] < 0, "Ankh also penalised for destroying jokers")
  end

  -- ---- pack display names are SIZE-qualified (two Arcana packs distinguishable) ----
  t.eq(Packs.display_name("p_arcana_mega_1"), "Mega Arcana Pack", "mega arcana display")
  t.eq(Packs.display_name("p_arcana_normal_1"), "Arcana Pack", "normal arcana display")
  t.eq(Packs.display_name("p_celestial_jumbo_1"), "Jumbo Celestial Pack", "jumbo celestial display")
  t.eq(Packs.display_name("p_buffoon_normal_1"), "Buffoon Pack", "normal buffoon display")

  -- ---- pack-open recommendation is deterministic (no flicker between ticks) ----
  do
    local deck = {}
    for r = 2, 14 do for _, s in ipairs({ "Hearts", "Spades", "Clubs", "Diamonds" }) do
      deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = s } end end
    local gs = GS.new{ deck = deck, remaining = deck, run = { hand_levels = {}, hand_size = 8 },
      pack = { picks_left = 1, items = {
        { set = "Planet", key = "c_mercury", name = "Mercury" },
        { set = "Planet", key = "c_jupiter", name = "Jupiter" },
        { set = "Planet", key = "c_venus", name = "Venus" },
      } } }
    local r1 = PackOpen.recommend(gs)
    local r2 = PackOpen.recommend(gs)
    t.ok(r1 and r2 and r1.best and r2.best, "pack-open produces a recommendation")
    t.eq(r1.best.key, r2.best.key, "pack-open pick is stable across re-evaluations (no flicker)")
  end

  -- ---- Judgement creates a joker -> valued on the joker scale, beats a reroll ----
  do
    local gs = GS.new{
      economy = { dollars = 8, interest_cap = 5 },
      run = { consumable_slots = 2 },
      shop = { jokers = {}, vouchers = {}, boosters = {},
        consumables = { { set = "Tarot", key = "c_judgement", name = "Judgement", cost = 3 } },
        reroll_cost = 5, joker_slots = 5 },
    }
    local r = SA.recommend(gs)
    t.eq(r.best.type, "BUY_CONSUMABLE", "use the Judgement (free joker) over saving / rerolling")
    t.eq(r.best.target.key, "c_judgement", "the recommended consumable is the Judgement")
  end

  -- ---- tarot targeting names cards from the DRAWN HAND, strategy when none drawn ----
  -- A tarot applies to cards you SELECT from a drawn hand, so we only name concrete
  -- cards we actually have (an explicit pool, or gs.hand). Without a drawn hand
  -- (browsing the shop, valuing a pack before the selection hand is dealt) the specific
  -- cards aren't known -- naming a card you haven't drawn is the bug this fixes -- so it
  -- describes the strategy instead.
  do
    local Tarot = require("engine.tarot")
    local deck = {}
    local id = 0
    for r = 2, 13 do id = id + 1; deck[#deck + 1] = card{ id = id, rank_id = r, suit = "Clubs" } end -- 2..K clubs
    deck[#deck + 1] = card{ id = 100, rank = "Ace", suit = "Spades" }  -- unique highest (chip 11)
    local gs = GS.new{ deck = deck, remaining = deck, run = { hand_levels = {}, hand_size = 8 } }

    -- no drawn hand -> generic strategy, NOT a specific (undrawn) deck card
    t.eq(Tarot.target_note(gs, "c_devil"), "apply to your 1 highest-value card", "Devil: strategy when no hand drawn")
    t.eq(Tarot.target_note(gs, "c_empress"), "apply to your 2 highest-value cards", "Empress: strategy (2 cards)")
    t.ok(Tarot.target_note(gs, "c_tower"):find("weakest"), "Tower (Stone): strategy targets the weakest")
    t.ok(Tarot.target_note(gs, "c_sun"):find("non%-Hearts"), "Sun: strategy converts non-Hearts to Hearts")
    t.eq(Tarot.target_note(gs, "c_judgement"), nil, "a non-targeting tarot has no apply-note")

    -- DRAWN hand present -> names the specific hand cards (explicit pool OR gs.hand)
    local hand = { card{ id = 1, rank = "Ace", suit = "Spades" }, card{ id = 2, rank = "King", suit = "Clubs" },
                   card{ id = 3, rank = "3", suit = "Clubs" } }
    t.eq(Tarot.target_note(gs, "c_devil", hand), "apply to AS", "Devil (explicit hand) names the highest card")
    t.ok(Tarot.target_note(gs, "c_empress", hand):find("^apply to AS,"), "Empress (explicit hand) names the Ace first")
    -- gs.hand is used automatically when present (the in-pack/in-blind case)
    local gsh = GS.new{ deck = deck, hand = hand, run = { hand_levels = {}, hand_size = 8 } }
    t.eq(Tarot.target_note(gsh, "c_devil"), "apply to AS", "names a card from the DRAWN hand, never an undrawn deck card")

    -- pack-open with a drawn hand names a HAND card (regression: it named an undrawn card)
    local gs2 = GS.new{ deck = deck, hand = hand, remaining = deck, run = { hand_levels = {}, hand_size = 8 },
      pack = { picks_left = 1, items = { { set = "Tarot", key = "c_devil", name = "The Devil" } } } }
    t.ok(PackOpen.recommend(gs2).reason:find("apply to AS"), "pack-open names a drawn hand card")
  end

  -- ---- the tarot TARGET is lifted into the BIG move line, not just the reason ----
  do
    local Overlay = require("ui.overlay")
    -- in-blind "Use Empress on ..." (decision-engine USE_CONSUMABLE carries target_note)
    Overlay.set({ best = { type = "USE_CONSUMABLE", target = { name = "Empress" },
      target_note = "apply to AS, KS", reason = "Use Empress (apply to AS, KS), then play Flush." } })
    t.eq(Overlay.state.move, "Use Empress — apply to AS, KS", "the move headline names the target cards")

    -- the shop's "Buy & use" tarot carries a structured target_note for the overlay
    local deck = {}
    for r = 2, 13 do deck[#deck + 1] = card{ id = r, rank_id = r, suit = "Clubs" } end
    local gs = GS.new{ deck = deck, economy = { dollars = 12, interest_cap = 5 },
      run = { hand_levels = {}, hand_size = 8, consumable_slots = 2 },
      shop = { jokers = {}, vouchers = {}, boosters = {},
        consumables = { { set = "Tarot", key = "c_empress", name = "The Empress", cost = 3 } },
        reroll_cost = 5, joker_slots = 5 } }
    local r = SA.recommend(gs)
    local buy = nil
    if r.best and r.best.type == "BUY_CONSUMABLE" then buy = r.best end
    for _, a in ipairs(r.alternatives or {}) do if a.type == "BUY_CONSUMABLE" then buy = buy or a end end
    t.ok(buy and buy.target_note and buy.target_note:find("^apply to %w"),
      "a buy/use tarot exposes its SPECIFIC target cards as a structured note for the move line")
  end

  -- ---- suit tarots never target cards already counting as that suit ----------
  -- Same-suit cards gain nothing; a WILD card already counts as EVERY suit, so
  -- converting it is pointless and loses flexibility. Neither should be named.
  do
    local Tarot = require("engine.tarot")
    local Cards = require("util.cards")
    local hand = {
      card{ id = 1, rank = "King", suit = "Hearts" },                       -- already Hearts
      card{ id = 2, rank = "Ace", suit = "Spades", enhancement = "m_wild" }, -- wild = all suits
      card{ id = 3, rank = "Queen", suit = "Spades" },                      -- off-suit -> valid
      card{ id = 4, rank = "9", suit = "Clubs" },                           -- off-suit -> valid
    }
    local gs = GS.new{ run = { hand_levels = {}, hand_size = 8 } }
    local targets, suit = Tarot.best_targets(gs, "c_sun", hand)  -- Sun -> Hearts
    t.eq(suit, "Hearts", "Sun converts to Hearts")
    t.ok(targets and #targets > 0, "Sun has valid off-suit targets")
    for _, c in ipairs(targets) do
      t.ok(not Cards.is_suit(c, "Hearts"), "target " .. Cards.label(c) .. " is not already a Heart/Wild")
    end
  end

  -- ---- suit-tarot VALUE is flush-plan-aware ----------------------------------
  -- A suit tarot's suit is FIXED, so it only helps when that suit is your flush
  -- direction. On a Hearts-flush deck the Hearts tarot (Sun) must outrank the
  -- off-suit ones, and a tarot fighting the flush must value ~0 -- NOT the old
  -- flat 0.15 prior that made every mismatched suit tarot look worth taking.
  do
    local M = require("engine.mechanics")
    local deck = {}
    for _ = 1, 30 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = ((#deck) % 13) + 2, suit = "Hearts" } end
    for _ = 1, 8 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = 10, suit = "Spades" } end
    for _ = 1, 6 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = 9, suit = "Clubs" } end
    local gs = GS.new{ deck = deck, run = { hand_size = 8, hand_levels = {} },
      blind = { target_chips = 1000, boss = true }, meta = { ante = 3 } }
    local need = M.boss_per_hand_need(gs)
    local function vof(k) return (CV.card_value(gs, "Tarot", k, nil, need, lcg(7))) end
    local aligned = vof("c_sun")                                 -- Hearts (matches build)
    local star, moon, world = vof("c_star"), vof("c_moon"), vof("c_world") -- off-suit
    t.ok(aligned >= star and aligned >= moon and aligned >= world,
      "Hearts tarot outranks off-suit suit tarots on a Hearts flush deck")
    t.ok(star <= 0.001 and moon <= 0.001 and world <= 0.001,
      "suit tarots fighting the flush value ~0, not the flat prior")
  end

  -- ---- THE FOOL with nothing to copy is worth ZERO (live run 8, 2026-08-13) ----
  -- The Fool recreates the last Tarot/Planet you USED, so before any has been used and with
  -- none held it is a literal no-op -- the game will not even let you take it. The engine was
  -- applying TAROT_BASE's flat 0.30 prior unconditionally and advising the pick.
  do
    local World = require("sim.world")
    local function st(over)
      local o = { deck = World.standard_deck(), consumables = {}, jokers = {},
        economy = { dollars = 10 }, run = { hand_levels = {} },
        blind = { target_chips = 300, chips_scored = 0, hands_left = 4, discards_left = 4 } }
      for k, v in pairs(over or {}) do o[k] = v end
      return GS.new(o)
    end

    t.eq(CV.fool_target(st{}), nil, "no tarot used and none held -> nothing for The Fool to copy")
    t.eq(CV.fool_target(st{ last_tarot_planet = { key = "c_strength" } }), "c_strength",
      "the last USED tarot is a copy target")
    t.eq(CV.fool_target(st{ consumables = { { set = "Tarot", key = "c_death", name = "Death" } } }), "c_death",
      "a HELD tarot is a copy target")
    t.eq(CV.fool_target(st{ consumables = { { set = "Joker", key = "j_joker" } } }), nil,
      "a held JOKER is not something The Fool can copy")

    t.eq((CV.card_value(st{}, "Tarot", "c_fool", nil, 1)), 0,
      "The Fool values ZERO with nothing to copy (was the 0.30 prior)")
    t.ok((CV.card_value(st{ last_tarot_planet = { key = "c_strength" } }, "Tarot", "c_fool", nil, 1)) > 0,
      "...and is worth something once a tarot has been used")
    -- the bug was specific to The Fool: other tarots keep their prior
    t.ok((CV.card_value(st{}, "Tarot", "c_strength", nil, 1)) > 0,
      "an ordinary tarot still values off its prior on the same bare state")
  end

  -- ---- the board context must REACH every leveling channel ----
  -- CV.level_gain silently falls back to the hand's bare base when it gets no context, and a
  -- nil context is not an error -- so a channel can lose 1.4-19x of a level's value with no
  -- symptom. That happened for real: the first cut of the fix threaded the context into the
  -- shop and pack-POOL paths but not into the in-pack PICK, which is the FREE leveling channel
  -- and the one that matters most. These pin each channel against the base-only figure.
  do
    local M = require("engine.mechanics")
    local deck = {}
    for _, su in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = su } end
    end
    -- a board with real chips AND an xmult, so a level is worth clearly more than its base
    local built = GS.new{ deck = deck, economy = { dollars = 20, interest_cap = 5 },
      meta = { ante = 3 },
      jokers = { joker{ key = "j_jolly" }, joker{ key = "j_sly" }, joker{ key = "j_blue_joker" },
                 joker{ key = "j_cavendish", ability = { x_mult = 3 } }, joker{ key = "j_walkie_talkie" } },
      run = { hand_levels = {}, hand_size = 8, joker_slots = 5, consumable_slots = 2 } }

    local need = M.boss_per_hand_need(built)
    local persist = CV.level_scale(built)
    -- the base-only value a channel would report if the context failed to reach it
    local freq, hctx = CV.hand_frequencies(built, { samples = 12, rng = lcg(5) })
    local hand = "Pair"
    local base_only = persist * ((freq[hand] or 0) * CV.level_gain(built, hand, 1)) / need
    local with_ctx  = persist * ((freq[hand] or 0) * CV.level_gain(built, hand, 1, hctx)) / need
    t.ok(with_ctx > 2 * base_only, "board context materially raises a planet's value on a built board")

    -- CHANNEL 1: the Celestial pack POOL
    local pv = ({ Packs.value(built, { key = "p_celestial_normal" }, { rng = lcg(5), samples = 8 }) })[1]
    t.ok(pv > 0.2, "Celestial pack pool value uses the board context (not the base-only ~0.08)")

    -- CHANNEL 2: the in-pack PICK -- the free channel, and the one the first cut missed
    local packgs = GS.new{ deck = deck, economy = { dollars = 20, interest_cap = 5 },
      meta = { ante = 3 }, jokers = built.jokers,
      run = { hand_levels = {}, hand_size = 8, joker_slots = 5, consumable_slots = 2 },
      pack = { key = "p_celestial_normal", items = {
        { set = "Planet", key = "c_mercury" },   -- Pair
        { set = "Planet", key = "c_uranus" },    -- Two Pair
        { set = "Planet", key = "c_neptune" },   -- Straight Flush (never made)
      } } }
    local rec = PackOpen.recommend(packgs)
    t.ok(rec and rec.best and rec.ranked and #rec.ranked == 3, "pack advisor ranks a Celestial pack")
    -- the base-only value of the SAME pick was 0.089; with the context it is ~1.87 on this
    -- board. Assert well above the base-only figure, not a tuned number.
    t.ok(rec.ranked[1].v > 0.5,
      "the in-pack planet PICK uses the board context too (the channel the first cut missed)")
    -- ...and the ordering is untouched: still the hand the deck actually makes
    t.eq(rec.best.key, "c_mercury", "...and still prefers a hand the deck makes")
    t.eq(rec.ranked[3].key, "c_neptune", "...ranking Straight Flush (never made) last")
  end

  -- ---- ECTOPLASM: a contingent slot against a permanent cost (ADVICE_REVIEW R6) ----
  -- Owner live-run report: the engine took Ectoplasm to put Negative on a joker it was
  -- going to sell anyway. It fell through to a flat SPECTRAL_BASE prior of 0.7 with its
  -- permanent -1 hand size charged at ZERO, so it read the SAME on every board.
  do
    local deck = {}
    for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = s } end
    end
    local function ecto_gs(jokers, ante)
      return GS.new{ deck = deck, meta = { ante = ante or 3 }, jokers = jokers,
        economy = { dollars = 10, interest_cap = 5 },
        run = { hand_levels = {}, hand_size = 8, joker_slots = 5, consumable_slots = 2 } }
    end
    local JUNK = joker{ key = "j_joker" }            -- flat common: sellable, not a keeper
    local CORE = joker{ key = "j_hanging_chad" }     -- retrigger: BP.CORE_KEEP
    local function ecto(gs)
      local need = Mechanics.boss_per_hand_need(gs)
      return ({ CV.card_value(gs, "Spectral", "c_ectoplasm", nil, need, lcg(7), 8) })[1]
    end

    -- the measured -1 hand size price exists and is real money in boss-hand fractions
    local hc = CV.hand_size_cost(ecto_gs({ JUNK }), Mechanics.boss_per_hand_need(ecto_gs({ JUNK })),
      { rng = lcg(7), samples = 8 })
    t.ok(hc and hc > 0, "a permanent -1 hand size is MEASURED off the deck, not free")
    t.ok(CV.hand_size_cost(ecto_gs({ JUNK }), 100, {}) == nil,
      "...and never samples without a seeded rng (that is what makes the live panel flicker)")

    local none  = ecto(ecto_gs({}))
    local junk  = ecto(ecto_gs({ JUNK, JUNK, JUNK }))
    local mixed = ecto(ecto_gs({ JUNK, JUNK, CORE }))
    local cores = ecto(ecto_gs({ CORE, CORE, CORE }))

    -- THE REPORTED MISPLAY: a board of disposable commons must now DECLINE. The +1 slot
    -- rides on a random joker and leaves when you sell it; the hand size never comes back.
    t.ok(junk < 0, "R6: Ectoplasm onto a board of sellable commons is NEGATIVE (was a flat +0.7)")
    -- with no joker at all the edition lands nowhere -- but you still pay the hand size
    t.ok(none < 0, "R6: Ectoplasm with no joker does nothing and still costs hand size")
    -- ...and it is genuinely board-sensitive now, not one constant for every state
    t.ok(cores > mixed and mixed > junk,
      "R6: Ectoplasm scales with how much of the board the plan intends to KEEP")
    t.ok(cores > 0, "R6: ...and is still strongly positive on a board of keepers")

    -- runway: the same core board is worth far less at ante 8, where a new slot has no
    -- time to be filled while the hand-size loss is still charged in full.
    t.ok(ecto(ecto_gs({ CORE, CORE, CORE }, 8)) < cores,
      "R6: the slot is runway-aware (ante 8 << ante 3), which the flat prior could not see")

    -- determinism: the branch samples the deck, so it must be stable under a seeded rng
    t.eq(ecto(ecto_gs({ JUNK, CORE })), ecto(ecto_gs({ JUNK, CORE })),
      "R6: Ectoplasm's value is deterministic under a seeded rng")
  end
end
