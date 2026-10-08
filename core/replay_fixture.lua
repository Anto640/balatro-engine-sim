-- core/replay_fixture.lua
-- SHARED replay-fixture serialization (methodology-shift-2026-08, Step 2-B).
--
-- One decision state, serialised to a JSON-able POD complete enough to RE-RUN the current engine
-- on it (shop_advisor / pack_open_advisor / decision_engine). Used by BOTH data sources of the
-- per-decision agreement objective:
--   * Source A -- the sim's World._capture hook (reference-policy agreement over sim states);
--   * Source B -- the live mod's telemetry (agreement vs a winning human's choice).
-- Emitting the SAME shape from both means one rehydrate + one replay path.
--
-- This SUPERSEDES tools/replay_lib.lua's in-blind-only fixture_of by ALSO carrying gs.shop and
-- gs.pack -- the shop/pack decisions are the economy/build channel the objective is really about.
-- PURE: no G, no globals. Loadable in the live mod (core.* is on the mod searcher) and headless.

local Json       = require("util.json")
local BossEffect = require("engine.boss_effect")

local RF = {}

-- deep copy of a POD subtree (skips functions/userdata/threads). CYCLE-SAFE: a live joker's `ability` table can hold a
-- reference back into itself or the game (live 2026-10-09: the auto death-save hit "stack overflow" here and kept 2
-- of 12 decisions), so a table already being copied is skipped and the depth is capped.
local DEEP_MAX = 12
local function deep(v, seen, depth)
  if type(v) ~= "table" then return v end
  seen, depth = seen or {}, depth or 0
  if seen[v] or depth >= DEEP_MAX then return nil end
  seen[v] = true
  local out = {}
  for k, x in pairs(v) do
    local tx = type(x)
    if tx == "table" then out[k] = deep(x, seen, depth + 1)
    elseif tx ~= "function" and tx ~= "userdata" and tx ~= "thread" then out[k] = x end
  end
  seen[v] = nil   -- a table shared by two branches (not a cycle) is copied in both
  return out
end
RF.deep = deep

local function card_pod(c)
  return { id = c.id, rank_id = c.rank_id, rank = c.rank, suit = c.suit,
           enhancement = c.enhancement, edition = c.edition, seal = c.seal,
           debuffed = c.debuffed or nil, forced = c.forced or nil }
end
local function cards_pod(list)
  local out = Json.array({})
  for _, c in ipairs(list or {}) do out[#out + 1] = card_pod(c) end
  return out
end
local function joker_pod(j)
  return { id = j.id, key = j.key, name = j.name, position = j.position, edition = j.edition,
           rarity = j.rarity, sell_value = j.sell_value, cost = j.cost, debuffed = j.debuffed or nil,
           ability = deep(j.ability or { extra = {} }) }
end
local function jokers_pod(list)
  local out = Json.array({})
  for _, j in ipairs(list or {}) do out[#out + 1] = joker_pod(j) end
  return out
end
local function cons_pod(list)
  local out = Json.array({})
  for _, c in ipairs(list or {}) do
    out[#out + 1] = { id = c.id, key = c.key, set = c.set, name = c.name }
  end
  return out
end

-- shop: offered jokers (full joker POD -- editions/abilities matter to valuation), boosters,
-- vouchers, and the reroll/slot context the shop advisor reads.
local function shop_pod(sh)
  if not sh then return nil end
  local boosters = Json.array({})
  for _, p in ipairs(sh.boosters or {}) do
    boosters[#boosters + 1] = { key = p.key, name = p.name, cost = p.cost }
  end
  local vouchers = Json.array({})
  for _, v in ipairs(sh.vouchers or {}) do
    vouchers[#vouchers + 1] = { key = v.key, name = v.name, cost = v.cost }
  end
  -- tarots/planets/spectrals for sale share the joker slots (a reroll replaces them too); without them a
  -- replayed shop can never reproduce a consumable buy (live seed 5XX3FFG3: Emperor/Strength/planets)
  local consumables = Json.array({})
  for _, c in ipairs(sh.consumables or {}) do
    consumables[#consumables + 1] = { key = c.key, name = c.name, set = c.set, cost = c.cost }
  end
  return { jokers = jokers_pod(sh.jokers), consumables = consumables, boosters = boosters, vouchers = vouchers,
           reroll_cost = sh.reroll_cost, joker_slots = sh.joker_slots,
           free_rerolls = sh.free_rerolls }
end

-- pack: the items on offer (set/key + card POD when it's a card pack), and pick counts.
local function pack_pod(pk)
  if not pk then return nil end
  local items = Json.array({})
  for _, it in ipairs(pk.items or {}) do
    items[#items + 1] = { set = it.set, key = it.key,
                          card = it.card and card_pod(it.card) or nil,
                          joker = it.joker and joker_pod(it.joker) or nil }
  end
  return { items = items, pick = pk.pick, picks_left = pk.picks_left, kind = pk.kind }
end

-- fixture_of(gs, choice, idx, kind) -> a serialisable fixture.
--   choice : what was chosen here (engine advice OR the human's action), metadata only --
--            replay re-decides with the CURRENT engine and compares against this.
--   idx    : decision ordinal within the run (also feeds a fixed oracle seed).
--   kind   : "shop" | "pack" | "blind" -- which advisor replay should call.
function RF.fixture_of(gs, choice, idx, kind)
  local m, b, r = gs.meta or {}, gs.blind or {}, gs.run or {}
  return {
    kind = "state", v = 2, decision = kind, idx = idx,
    seed = tonumber(m.seed_hash) or m.seed_hash,
    ante = m.ante, round = m.round, blind_type = b.blind_type, boss_key = b.boss_effect_key,
    chose = choice and { type = choice.type, target = choice.target, hand_type = choice.hand_type,
                         key = choice.key } or nil,
    gs = {
      meta = { ante = m.ante, round = m.round, state = m.state, seed_hash = m.seed_hash },
      hand = cards_pod(gs.hand), remaining = cards_pod(gs.remaining), deck = cards_pod(gs.deck),
      jokers = jokers_pod(gs.jokers), consumables = cons_pod(gs.consumables),
      economy = { dollars = (gs.economy or {}).dollars or 0,
                  interest_cap = (gs.economy or {}).interest_cap },
      shop = shop_pod(gs.shop), pack = pack_pod(gs.pack),
      last_tarot_planet = gs.last_tarot_planet and { key = gs.last_tarot_planet.key } or nil,   -- what the Fool copies
      blind = { name = b.name, blind_type = b.blind_type, boss = b.boss or nil,
                boss_effect_key = b.boss_effect_key, target_chips = b.target_chips,
                chips_scored = b.chips_scored, hands_left = b.hands_left,
                discards_left = b.discards_left, discards_used = b.discards_used, base_hands = b.base_hands,
                base_discards = b.base_discards, played_hand_types = deep(b.played_hand_types),
                skip_tag = b.skip_tag, skip_tag_hand = b.skip_tag_hand,
                first_hand_type = b.first_hand_type },   -- the Mouth lock (main.lua BES.run_state_for)   -- for the SKIP decision replay (blind-select)
      run = { hand_levels = deep(r.hand_levels), vouchers_owned = deep(r.vouchers_owned),
              tags = deep(r.tags), hand_size = r.hand_size, consumable_slots = r.consumable_slots,
              joker_slots = r.joker_slots, boss_key = r.boss_key,
              hand_type_plays = deep(r.hand_type_plays), hands_played = r.hands_played,
              build_plan = deep(r.build_plan), pending_swap = deep(r.pending_swap) },
    },
  }
end

-- fixture -> GameState (mirrors sim/world build_gs; boss_effect re-derived from the key).
function RF.rehydrate(fix)
  local g = fix.gs or {}
  local gs = {
    meta = g.meta or { ante = fix.ante or 1, round = fix.round or 1,
                       state = "SHOP", seed_hash = tostring(fix.seed) },
    deck = g.deck or {}, remaining = g.remaining or {}, hand = g.hand or {},
    jokers = g.jokers or {}, consumables = g.consumables or {},
    economy = g.economy or { dollars = 0, interest_cap = 5 },
    shop = g.shop, pack = g.pack, blind = g.blind or {}, run = g.run or {}, last_tarot_planet = g.last_tarot_planet,
  }
  for _, j in ipairs(gs.jokers) do j.ability = j.ability or { extra = {} } end
  -- a pack joker: live state carries its read joker (item.joker); fixtures written before 2026-09-24
  -- stored only the key, so rebuild it (the pack advisor's full-board swap only sees items with .joker)
  for _, it in ipairs((gs.pack or {}).items or {}) do
    if it.set == "Joker" and it.key then
      it.joker = it.joker or { key = it.key }
      it.joker.ability = it.joker.ability or { extra = {} }
    end
  end
  local r = gs.run
  r.hand_levels = r.hand_levels or {}
  r.vouchers_owned = r.vouchers_owned or {}
  r.tags = r.tags or {}
  r.hand_size = r.hand_size or 8
  r.consumable_slots = r.consumable_slots or 2
  local b = gs.blind
  if b.boss and b.boss_effect_key then gs.boss_effect = BossEffect.of(b.boss_effect_key) end
  return gs
end

return RF
