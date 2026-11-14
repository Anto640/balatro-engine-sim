-- engine/advice.lua
-- One shape for what an advisor tells its caller to do next: an ACTION.
--
--   action = { type =, target =, reason =, confidence =, ... }
--
-- The play engine and the shop advisor already rank actions. The skip advisor and the pack advisor answer in
-- their own terms (a SKIP / PLAY verdict with two values; a ranked pick list with make-room steps), and the
-- translation to the next single action used to live in main.lua, where no headless test reached it. It lives
-- here, so the overlay, the self-player and the simulator read the same thing.
--
-- Advice.TYPES is the whole vocabulary a consumer has to handle.

local Cards = require("util.cards")

local Advice = {}

Advice.TYPES = {
  -- in a blind
  PLAY = true, DISCARD = true,
  -- shop
  BUY_JOKER = true, BUY_CONSUMABLE = true, BUY_PACK = true, BUY_VOUCHER = true, REROLL = true,
  SELL_JOKER = true, SELL_TO_BUY = true, SAVE = true,
  -- shop, pack and blind
  USE_CONSUMABLE = true,
  -- blind select
  SKIP = true,       -- skip the blind for its tag; in an open pack: skip the pack
  CONTINUE = true,   -- play the blind
  -- an open pack
  PICK = true,
}

-- ---- blind select -----------------------------------------------------------
-- sk = SkipAdvisor.recommend(gs): { recommend = "SKIP" | "PLAY", tag, tag_value, play_value, reason }, or nil when
-- there is nothing to skip FOR (the boss, or a blind with no offered tag) -- then the only move is to play, and the
-- action says so rather than leaving the panel blank (2026-08-26 advice-review #10).
function Advice.from_skip(sk, gs)
  if sk then
    return {
      type = sk.recommend == "SKIP" and "SKIP" or "CONTINUE",
      target = sk.recommend == "SKIP" and { name = sk.tag } or nil,
      reason = sk.reason, confidence = 0.7,
      expected_value = (sk.tag_value - sk.play_value) / math.max(1, sk.play_value),
    }
  end
  local btype = ((gs and gs.blind) or {}).blind_type
  return {
    type = "CONTINUE", confidence = 0.7,
    reason = (btype == "Boss")
      and "Play the blind — the boss can't be skipped."
      or "Play the blind — no skip tag worth taking here.",
  }
end

-- ---- an open pack -----------------------------------------------------------
-- po = PackOpenAdvisor.recommend(gs, ...). Returns the NEXT single step (one atomic action per overlay line, for
-- the human and for the self-player, which can only actuate one action at a time):
--   1. use a held consumable first, when the pick needs the tray slot (or chains with it);
--   2. sell a joker first, when a joker pick needs a board slot;
--   3. otherwise take the best pick, or skip the pack.
function Advice.from_pack(po)
  local pick = po.best
  if po.use_first and po.use_first.key and not po.skip then
    -- MAKE ROOM IN THE TRAY: a card-making tarot from the pack needs a free consumable slot to be usable, so use
    -- the held planet first (its own step, like the make-room sell), then the pick.
    local chain = po.use_first.chain
    local tcards
    if po.use_first.cards then tcards = {}; for _, c in ipairs(po.use_first.cards) do tcards[#tcards + 1] = { id = c.id } end end
    return {
      type = "USE_CONSUMABLE",
      target = { name = po.use_first.name, key = po.use_first.key }, use_keys = { po.use_first.key },
      cards = po.use_first.cards, target_cards = tcards,
      reason = chain
        and string.format("Use %s on %s first, then take %s and copy that Gold card (three Gold cards).",
          po.use_first.name, Cards and Cards.label and Cards.label(po.use_first.cards[1]) or "a spare card", po.use_first.for_name or "the pick")
        or string.format("Use %s first to free a consumable slot for %s, then take it.",
          po.use_first.name, po.use_first.for_name or "the pick"),
      confidence = 0.7,
    }
  elseif po.sell and po.sell.key and not po.skip then
    -- MAKE ROOM IS ITS OWN STEP (owner request 2026-08-30). A joker pick into a FULL board can't be
    -- taken until a joker is sold, so the PRIMARY recommendation is the SELL ("Sell X to make room for
    -- Y") -- its own header line, not a grey note under "Take Y". After the sell the re-evaluation frees
    -- a slot and surfaces the pick.
    return {
      type = "SELL_JOKER",
      target = { name = po.sell.name, key = po.sell.key, id = po.sell.id },
      make_room_for = po.sell.for_name,
      reason = string.format("Sell %s to make room for %s, then take it.",
        po.sell.name, po.sell.for_name or (pick and (pick.name or pick.key)) or "the pick"),
      confidence = 0.7,
    }
  end
  return {
    type = po.skip and "SKIP" or "PICK",
    -- carry the center key (+ id when present) so the auto-play actuator can match the live pack card;
    -- name alone is a display string that won't match a center key (ui/autoplay.lua).
    -- the id must be the CARD's own stable id: every plain playing card shares the center key "c_base"
    -- (and every Bonus card "m_bonus"...), so a key-only match grabbed the FIRST such card in a Standard
    -- pack -- the overlay said "take 3 of Spades", the self-player took a Jack (owner 2026-09-23).
    target = pick and { name = pick.name or pick.key, key = pick.key,
      id = pick.id or (pick.card and pick.card.id) or (pick.joker and pick.joker.id) } or nil,
    target_note = po.target_note,          -- "apply to AS, KS" in the BIG line (#10)
    target_cards = po.target_cards,        -- machine-readable target hand-card ids (auto-play selects them)
    target_order = po.target_order,        -- Death: target_cards must sit left->right in the hand
    reason = po.reason, confidence = 0.75,
  }
end

return Advice
