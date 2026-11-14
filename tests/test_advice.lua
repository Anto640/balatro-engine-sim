-- tests/test_advice.lua
-- engine/advice: the skip and pack advisors' answers become the next single ACTION, in one vocabulary.
-- (This translation used to live in main.lua, out of reach of the headless suite.)

local Advice = require("engine.advice")

return function(t)
  -- ---- blind select ----
  do
    local a = Advice.from_skip({ recommend = "SKIP", tag = "Investment", tag_value = 30, play_value = 20, reason = "r" })
    t.eq(a.type, "SKIP", "skip: a SKIP verdict is a SKIP action")
    t.eq(a.target and a.target.name, "Investment", "skip: it names the tag")
    t.near(a.expected_value, 0.5, "skip: the edge is relative to playing")
    t.eq(a.reason, "r", "skip: the advisor's reason is carried")

    local p = Advice.from_skip({ recommend = "PLAY", tag = "Investment", tag_value = 5, play_value = 20, reason = "r2" })
    t.eq(p.type, "CONTINUE", "skip: a PLAY verdict is a CONTINUE action")
    t.eq(p.target, nil, "skip: with no target")

    local boss = Advice.from_skip(nil, { blind = { blind_type = "Boss" } })
    t.eq(boss.type, "CONTINUE", "skip: nothing to skip for -> play")
    t.ok(boss.reason:find("boss", 1, true) ~= nil, "skip: and says the boss can't be skipped")
    local none = Advice.from_skip(nil, { blind = { blind_type = "Small" } })
    t.ok(none.reason:find("no skip tag", 1, true) ~= nil, "skip: a blind with no tag says so")
    t.eq(Advice.from_skip(nil, nil).type, "CONTINUE", "skip: tolerates a missing state")
  end

  -- ---- an open pack: the next single step ----
  do
    local pick = { name = "Jolly Joker", key = "j_jolly", joker = { id = 41 } }

    local take = Advice.from_pack({ best = pick, reason = "take it", target_cards = { { id = 3 } }, target_note = "AS" })
    t.eq(take.type, "PICK", "pack: a plain pick")
    t.eq(take.target.key, "j_jolly", "pack: carries the center key")
    t.eq(take.target.id, 41, "pack: and the card's own id (a key alone is ambiguous for playing cards)")
    t.eq(take.target_cards[1].id, 3, "pack: target hand cards are passed through")
    t.eq(take.reason, "take it", "pack: with the advisor's reason")

    local skip = Advice.from_pack({ best = nil, skip = true, reason = "bloat" })
    t.eq(skip.type, "SKIP", "pack: skip the pack")
    t.eq(skip.target, nil, "pack: a skip has no target")

    local sell = Advice.from_pack({ best = pick, reason = "x",
      sell = { name = "Egg", key = "j_egg", id = 9, for_name = "Jolly Joker" } })
    t.eq(sell.type, "SELL_JOKER", "pack: a full board -> the make-room sale comes first")
    t.eq(sell.target.id, 9, "pack: the sale names the owned joker")
    t.eq(sell.make_room_for, "Jolly Joker", "pack: and what it makes room for")

    local use = Advice.from_pack({ best = pick, reason = "x",
      sell = { name = "Egg", key = "j_egg", id = 9 },
      use_first = { name = "Pluto", key = "c_pluto", for_name = "The Emperor" } })
    t.eq(use.type, "USE_CONSUMABLE", "pack: freeing the tray comes before a sale")
    t.eq(use.use_keys[1], "c_pluto", "pack: the held card to use")
    t.ok(use.reason:find("The Emperor", 1, true) ~= nil, "pack: the reason names what the slot is for")

    local skipped = Advice.from_pack({ skip = true, reason = "bloat",
      sell = { name = "Egg", key = "j_egg" }, use_first = { name = "Pluto", key = "c_pluto" } })
    t.eq(skipped.type, "SKIP", "pack: a skipped pack makes no room")
  end

  -- ---- one vocabulary ----
  do
    for _, a in ipairs({
      Advice.from_skip({ recommend = "SKIP", tag = "T", tag_value = 1, play_value = 1 }),
      Advice.from_skip(nil, nil),
      Advice.from_pack({ best = { key = "c_pluto" } }),
      Advice.from_pack({ skip = true }),
      Advice.from_pack({ best = { key = "j_joker" }, sell = { name = "Egg", key = "j_egg" } }),
      Advice.from_pack({ best = { key = "c_emperor" }, use_first = { name = "Pluto", key = "c_pluto" } }),
    }) do
      t.ok(Advice.TYPES[a.type] == true, "vocabulary: '" .. tostring(a.type) .. "' is a declared action type")
    end
    -- the action types the shop and play advisors emit are declared too
    local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
    for _, rel in ipairs({ "engine/shop_advisor.lua", "engine/decision_engine.lua", "engine/pack_open_advisor.lua" }) do
      local fh = io.open(here .. "../" .. rel, "r")
      if fh then
        local src = fh:read("*a"); fh:close()
        for ty in src:gmatch('type = "([A-Z][A-Z_]+)"') do
          t.ok(Advice.TYPES[ty] == true, "vocabulary: " .. rel .. " emits '" .. ty .. "', which is declared")
        end
      end
    end
  end
end
