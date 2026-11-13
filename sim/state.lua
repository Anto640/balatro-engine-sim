-- sim/state.lua
-- The simulator's adapter to engine/decision_state: builds the state the engine decides on from the referee's
-- `run`, for each decision kind (shop / pack, in-blind, skip). core/state_extraction is the live counterpart.
--
-- One place, so the three kinds are built from the same run facts. Where a kind does NOT yet carry a fact the
-- live state has, it is listed in SimState.GAPS rather than silently left out -- each entry is a known fidelity
-- gap (the engine falls back to a default there), kept only so the refactor that introduced this file changed
-- no decision. Closing a gap is a behaviour change: delete the entry and measure it as its own arm.

local GS    = require("model.game_state")
local DS    = require("engine.decision_state")
local Flags = require("engine.flags")

local SimState = {}

-- kind -> { "section.field" = true }: facts the live state carries that this sim state does not.
SimState.GAPS = {
  shop = {},
  skip = {
    ["meta.round"] = true, ["meta.state"] = true, ["meta.seed_hash"] = true,
    ["consumables"] = true,
    ["last_tarot_planet"] = true,
    ["run.vouchers_owned"] = true, ["run.tags"] = true, ["run.hand_size"] = true,
    ["run.consumable_slots"] = true,
    ["run.joker_slots"] = true,       -- tag valuation falls back to 5 slots
    ["run.hand_type_plays"] = true,
    ["run.hands_played"] = true,
  },
}

-- BES_LIVE_CAP_BUG=1 (experiment only; inert otherwise): hand the ADVISORS the interest cap the way the LIVE
-- game reports it -- in DOLLARS (25/50/100) instead of the sim's interest units (5/10/20) -- so the sim can
-- measure what the live-only unit bug costs (the engine's reroll/pack spending keys off cap*5). A COPY, so the
-- world's own interest payouts are untouched.
local LIVE_CAP_BUG = Flags.off("BES_LIVE_CAP_BUG")
local function advisor_economy(run)
  if not LIVE_CAP_BUG then return run.economy end
  local e = {}
  for k, v in pairs(run.economy) do e[k] = v end
  e.interest_cap = (run.economy.interest_cap or 5) * 5
  return e
end

-- what The Fool would copy (the world tracks it as run._last_consumable)
local function last_consumable(run)
  return run._last_consumable and { key = run._last_consumable.key, name = run._last_consumable.name } or nil
end

-- The shop / open-pack decision.
function SimState.shop(run, shop, pack)
  local gaps = SimState.GAPS.shop
  return DS.derive(GS.new{
    meta = { ante = run.ante, round = run.round, state = "SHOP", seed_hash = tostring(run.seed) },
    deck = run.deck, jokers = run.jokers, consumables = run.consumables,
    economy = advisor_economy(run),
    last_tarot_planet = (not gaps["last_tarot_planet"]) and last_consumable(run) or nil,
    -- the round's resource BUDGET, as the live shop state carries it (state_extraction reads the last blind:
    -- base_discards 4 / discards_left 4 on a red deck). Without it GS.new defaulted both to 0, so every shop
    -- valuation that reads the discard budget (Banner/Mystic Summit expected discards, Burnt, Burglar, the
    -- resource table, seals, hand frequencies) saw a ZERO-discard game in the sim but 4 live (2026-09-26).
    blind = { base_hands = run.base_hands, base_discards = run.base_discards,
              hands_left = run.base_hands, discards_left = run.base_discards, discards_used = 0,
              next_blind = run._next_blind },   -- the blind after this shop (live: state_extraction's next_blind)
    run = { hand_levels = run.hand_levels, vouchers_owned = run.vouchers_owned, tags = run.tags,
            hand_size = run.hand_size, consumable_slots = run.consumable_slots,
            joker_slots = run.joker_slots, boss_key = run._next_boss,
            hand_type_plays = run.hand_type_plays, hands_played = run.hands_played,
            build_plan = run.build_plan,    -- K1/K2 + Phase 5 persistent archetype
            pending_swap = run._pending_swap,   -- a paired trade's sale was made; its buy is due (SA.paired_trade)
            ante_back = run._ante_back },       -- a pending Hieroglyph/Petroglyph replay (SA.final_shop)
    shop = shop, pack = pack,
  })
end

-- ONE decision inside a blind. `eff` = the boss's scoring effect, resolved once per blind by the referee.
function SimState.blind(run, blind, hand, draw_pile, eff)
  return DS.derive(GS.new{
    meta = { ante = run.ante, round = run.round, state = "SELECTING_HAND", seed_hash = tostring(run.seed) },
    deck = run.deck,
    remaining = draw_pile,          -- undrawn cards still in the draw pile this blind
    hand = hand,
    jokers = run.jokers,
    consumables = run.consumables,
    economy = run.economy,
    last_tarot_planet = last_consumable(run),
    blind = {
      name = blind.name or blind.type, target_chips = blind.target, chips_scored = blind.scored,
      boss = (blind.type == "Boss"), blind_type = blind.type,
      boss_effect_key = blind.boss_key,
      hands_left = blind.hands_left, discards_left = blind.discards_left,
      base_hands = blind.base_hands, base_discards = blind.base_discards,
      discards_used = blind._first_discard_done and 1 or 0,   -- Burnt Joker: is the next discard the first?
      played_hand_types = blind.played_types,   -- K2: hand types played THIS blind (Card Sharp)
      first_hand_type = blind._pstate and blind._pstate.first,   -- the Mouth lock
    },
    run = {
      hand_levels = run.hand_levels, vouchers_owned = run.vouchers_owned, tags = run.tags,
      hand_size = blind.hand_size, consumable_slots = run.consumable_slots,
      joker_slots = run.joker_slots, boss_key = blind.boss_key,
      hand_type_plays = run.hand_type_plays,     -- K1: per-type run play counts (Supernova)
      hands_played = run.hands_played,            -- K2: total hands played (Loyalty)
      build_plan = run.build_plan,                 -- Phase 5: sticky archetype commitment
    },
  }, eff)
end

-- The skip-or-play decision at a Small / Big blind (blind.skip_tag = the tag on offer).
function SimState.skip(run, blind)
  local gaps = SimState.GAPS.skip
  local function keep(name, v) if gaps[name] then return nil end; return v end
  return GS.new{
    deck = run.deck, jokers = run.jokers, economy = run.economy,
    consumables = keep("consumables", run.consumables),
    last_tarot_planet = keep("last_tarot_planet", last_consumable(run)),
    meta = { ante = run.ante, round = keep("meta.round", run.round), state = keep("meta.state", "BLIND_SELECT"),
             seed_hash = keep("meta.seed_hash", tostring(run.seed)) },
    run = { hand_levels = run.hand_levels,
            base_hands = run.base_hands, build_plan = run.build_plan,
            vouchers_owned = keep("run.vouchers_owned", run.vouchers_owned), tags = keep("run.tags", run.tags),
            hand_size = keep("run.hand_size", run.hand_size),
            consumable_slots = keep("run.consumable_slots", run.consumable_slots),
            joker_slots = keep("run.joker_slots", run.joker_slots),
            hand_type_plays = keep("run.hand_type_plays", run.hand_type_plays),
            hands_played = keep("run.hands_played", run.hands_played) },
    blind = { blind_type = blind.type, base_hands = run.base_hands, skip_tag = blind.skip_tag,
              skip_tag_hand = run._orbital_hand },
  }
end

return SimState
