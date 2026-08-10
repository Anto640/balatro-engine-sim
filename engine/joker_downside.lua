-- engine/joker_downside.lua
-- Situational downside model. Some jokers carry a real cost -- they shrink your
-- hand, burn a hand each round, threaten your OTHER jokers, or decay to nothing.
-- We express that cost as a penalty in the same "future-value" units the
-- eval_function credits a joker's upside in, so a joker's NET contribution can go
-- negative -- which is what lets the advisor sell or skip it.
--
-- Crucially the penalty is STATE-DEPENDENT, not a flat tax: a -2 hand-size joker
-- barely matters with a big hand but is crippling when you're card-starved; a
-- joker-destroyer costs nothing on an empty board but a lot beside two Barons.
-- So these jokers are still taken WHEN they're worth it, and only flagged
-- harmful when the situation makes the downside outweigh the gain. PURE.

local JokerData = require("engine.joker_data")

local D = {}

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

-- Rough future-value upside of a joker by key, mirroring eval_function's
-- per-joker term (future_value adds ~1.5 * tier*0.5 = 0.75*tier). Used to price
-- "what this joker threatens to destroy".
local function own_value(key) return (JokerData.resolve(key).tier or 3) * 0.75 end

-- Jokers that DEPEND on enhanced cards staying in the deck. Vampire eats those
-- enhancements, so its real cost is how much these others rely on them.
local ENH_DEPENDENT = {
  j_steel_joker = true, j_glass = true, j_lucky_cat = true,
  j_drivers_license = true, j_vampire = true,
}

-- ability.extra is a TABLE for some jokers but a NUMBER for others, so always
-- type-check before indexing it (indexing a number throws).
local function extra_of(ab) return (type(ab) == "table" and type(ab.extra) == "table") and ab.extra or nil end

local function is_eternal(j)
  local ab = j and j.ability
  if type(ab) ~= "table" then return false end
  local ex = extra_of(ab)
  return ab.eternal or (ex and ex.eternal) or false  -- VERIFY
end

-- Downside descriptors. Extend here as jokers are modelled.  -- VERIFY effects
local SPEC = {
  j_stuntman    = { hand_size = 2 },        -- +250 chips, but -2 hand size
  j_merry_andy  = { hand_size = 1 },        -- +discards, -1 hand size
  j_troubadour  = { hands = 1 },            -- +2 hand size, -1 hand per round
  j_burglar     = { no_discards = true },   -- +3 hands, but 0 discards this blind
  j_madness     = { destroys = "random" },  -- destroys a random joker each blind
  j_ceremonial  = { destroys = "right" },   -- destroys the joker to its right
  j_vampire     = { eats_enhancements = true }, -- strips enhancements from the deck
  j_gros_michel = { fragile = 1 / 6 },      -- 1-in-6 to go extinct -> nothing
  j_ice_cream   = { decay = true },         -- melts away over hands
  j_popcorn     = { decay = true },         -- decays over rounds
  j_turtle_bean = { decay = true },         -- decays over rounds
  j_ramen       = { decay = true },         -- loses xmult as you discard
}

-- penalty(gs, joker, idx) -> future-value penalty (>= 0). idx is the joker's
-- board position (needed for "destroys the joker to its right"); pass nil when
-- valuing a shop joker not yet placed.
function D.penalty(gs, j, idx)
  if not j then return 0 end
  local pen = 0

  -- ---- per-joker (keyed) downsides ----
  local spec = SPEC[j.key]
  if spec then
    local hs = (gs.run and gs.run.hand_size) or 8
    local base_hands = (gs.blind and gs.blind.base_hands) or 4
    if base_hands <= 0 then base_hands = 4 end

    -- hand-size loss: each lost card matters more the fewer you already hold
    if spec.hand_size then
      pen = pen + spec.hand_size * 1.0 * clamp(8 / hs, 1, 2)
    end
    -- hand loss: a burned hand hurts more the fewer hands you get
    if spec.hands then
      pen = pen + spec.hands * 1.2 * clamp(4 / base_hands, 1, 2)
    end
    -- discards removed: only a cost to the extent you had discards to rely on
    if spec.no_discards then
      local bd = (gs.blind and gs.blind.base_discards) or 3
      pen = pen + math.max(0, bd) * 0.4
    end
    -- destroys a RANDOM other joker each blind: expected loss = mean value of the
    -- DESTROYABLE others (Eternal jokers are immune). Lone board -> no penalty.
    if spec.destroys == "random" then
      local sum, n = 0, 0
      for i, o in ipairs(gs.jokers or {}) do
        if i ~= idx and not is_eternal(o) then sum = sum + own_value(o.key); n = n + 1 end
      end
      if n > 0 then pen = pen + (sum / n) * 0.8 end
    end
    -- destroys the joker to its RIGHT: the cost is that neighbour's value (Eternal
    -- jokers can't be destroyed, so placing one there is safe).
    if spec.destroys == "right" and idx then
      local right = (gs.jokers or {})[idx + 1]
      if right and not is_eternal(right) then pen = pen + own_value(right.key) * 0.8 end
    end
    -- eats enhancements: the cost is how much the rest of the board relies on
    -- enhanced cards (Steel/Glass/Lucky/Driver's License) plus a little for
    -- depleting the deck. On a board that doesn't care, Vampire just converts the
    -- enhancements to its own xmult and the penalty is small.
    if spec.eats_enhancements then
      local dependents = 0
      for i, o in ipairs(gs.jokers or {}) do
        if i ~= idx and ENH_DEPENDENT[o.key] then dependents = dependents + 1 end
      end
      local enh = 0
      for _, c in ipairs(gs.deck or {}) do
        if c.enhancement and c.enhancement ~= "m_stone" then enh = enh + 1 end
      end
      pen = pen + dependents * 1.5 + math.min(enh, 12) * 0.05
    end
    -- fragile (extinction): expected fraction of its own value lost
    if spec.fragile then pen = pen + own_value(j.key) * spec.fragile * 1.5 end
    -- decaying/temporary: a small standing discount (still strong while it lasts)
    if spec.decay then pen = pen + 0.6 end
  end

  -- ---- generic stickers (apply to ANY joker, spec or not) ----
  --   Perishable -> debuffs to nothing after a few rounds; Rental -> -$3/round.
  local ab = j.ability
  if type(ab) == "table" then
    local ex = extra_of(ab)
    if ab.perishable or (ex and ex.perishable) then pen = pen + own_value(j.key) * 0.4 end -- VERIFY
    if ab.rental or (ex and ex.rental) then pen = pen + 1.0 end                            -- VERIFY
  end

  return pen
end

D.SPEC = SPEC
return D
