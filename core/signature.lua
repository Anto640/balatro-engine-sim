-- core/signature.lua
-- Cheap change-detection. We hash the parts of G that affect a recommendation,
-- so the (expensive) evaluation only re-runs when something relevant changed.
-- This keeps the mod off the per-frame hot path (see DESIGN.md Phase 7).
--
-- Operates on a normalised GameState (POD), NOT on G directly, so it is also
-- testable headless.

local Sig = {}

local function card_sig(c)
  return table.concat({
    tostring(c.id or "?"),
    tostring(c.rank_id or c.rank or "?"),
    tostring(c.suit or "?"),
    tostring(c.enhancement or "-"),
    tostring(c.edition or "-"),
    tostring(c.seal or "-"),
    c.debuffed and "D" or "",
  }, ":")
end

-- A stable string describing everything that changes the best move.
function Sig.of(gs)
  if not gs then return "" end
  local parts = {}

  -- game state (incl. blind-select) so EVERY transition blind->shop->pack->blind
  -- forces a re-evaluation, not just hand/joker edits.
  parts[#parts + 1] = "S=" .. tostring(gs.meta and gs.meta.state)
    .. "/" .. tostring(gs.meta and gs.meta.in_blind_select)
  parts[#parts + 1] = "$=" .. tostring(gs.economy and gs.economy.dollars)

  -- hand (selection + order matters for the UI, but not for scoring; we include
  -- identity so re-selection triggers a recompute)
  local h = {}
  for _, c in ipairs(gs.hand or {}) do h[#h + 1] = card_sig(c) end
  parts[#parts + 1] = "H=" .. table.concat(h, "|")

  -- jokers: ORDER MATTERS -> include positionally
  local j = {}
  for _, jk in ipairs(gs.jokers or {}) do
    j[#j + 1] = (jk.key or "?") .. "/" .. tostring(jk.edition or "-")
  end
  parts[#parts + 1] = "J=" .. table.concat(j, ">")

  -- blind + counters (chips_scored too, so mid-blind progress re-evaluates the
  -- remaining target). blind_type + skip_tag are the BLIND-SELECT identity: when you
  -- SKIP, the on-deck blind advances (Small->Big) and its skip tag changes while the
  -- played-blind counters don't -- without these the signature wouldn't change and
  -- the skip/continue advice would stay stale until you actually select a blind.
  if gs.blind then
    parts[#parts + 1] = "B=" .. table.concat({
      tostring(gs.blind.name), tostring(gs.blind.target_chips),
      tostring(gs.blind.chips_scored),
      tostring(gs.blind.hands_left), tostring(gs.blind.discards_left),
      tostring(gs.blind.blind_type), tostring(gs.blind.skip_tag), tostring(gs.blind.skip_tag_hand),
    }, ",")
  end

  -- held consumables + hand levels: using a held planet/tarot in the shop changes neither the dollars nor the
  -- board, so without these the panel kept advising "Use Jupiter" after Jupiter was gone.
  local c = {}
  for _, it in ipairs(gs.consumables or {}) do c[#c + 1] = it.key or "?" end
  parts[#parts + 1] = "C=" .. table.concat(c, ",")
  local lv = {}
  for name, h in pairs((gs.run and gs.run.hand_levels) or {}) do lv[#lv + 1] = name .. (h.level or 1) end
  table.sort(lv)
  parts[#parts + 1] = "L=" .. table.concat(lv, ",")

  -- shop contents (only when present). EVERY offer, not just the jokers: the game stocks the shop in one event
  -- after the screen opens, so the first evaluation sees an EMPTY shop. With only the jokers here, a shop that
  -- offered no jokers (all tarot/planet slots) never re-evaluated once its packs appeared -- the empty shop's
  -- "Bank $16" stayed on the panel and the self-player left a shop it would have opened a pack in (live
  -- LBUI8IK1, 2026-09-28: at ~56% death risk; 6 shops in 9 runs, 5 of them a different decision).
  if gs.shop then
    local s = {}
    for _, it in ipairs(gs.shop.jokers or {}) do s[#s + 1] = it.key or "?" end
    s[#s + 1] = "|"
    for _, it in ipairs(gs.shop.consumables or {}) do s[#s + 1] = it.key or "?" end
    s[#s + 1] = "|"
    for _, it in ipairs(gs.shop.boosters or {}) do s[#s + 1] = it.key or it.name or "?" end
    s[#s + 1] = "|"
    for _, it in ipairs(gs.shop.vouchers or {}) do s[#s + 1] = it.key or "?" end
    parts[#parts + 1] = "SHOP=" .. table.concat(s, ",") .. "@" .. tostring(gs.shop.reroll_cost)
  end

  -- open booster pack (its revealed choices + picks left). WITHOUT this, opening
  -- a pack doesn't change the signature, so the advisor stays a step behind and
  -- only updates once picking a card mutates the jokers/consumables instead.
  if gs.pack then
    local p = {}
    for _, it in ipairs(gs.pack.items or {}) do p[#p + 1] = it.key or it.set or "?" end
    parts[#parts + 1] = "PACK=" .. table.concat(p, ",") .. "#" .. tostring(gs.pack.picks_left)
  end

  return table.concat(parts, ";")
end

-- Convenience stateful tracker.
function Sig.tracker()
  local last = nil
  return {
    -- returns true if changed (and stores the new signature)
    changed = function(gs)
      local cur = Sig.of(gs)
      if cur ~= last then last = cur; return true end
      return false
    end,
    current = function() return last end,
    -- forget the stored signature so the next changed() re-evaluates even an unchanged state
    reset = function() last = nil end,
  }
end

return Sig
