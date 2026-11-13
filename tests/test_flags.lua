-- tests/test_flags.lua
-- engine/flags.lua is the only reader of the environment and of the BES_* globals in engine/ and sim/.
-- Covers the reader semantics and guards the rule itself (a direct os.getenv in an engine file fails here).

local Flags = require("engine.flags")

return function(t)
  -- ---- reader semantics (through Flags.set, which stands in for the environment) ----
  Flags.reset()
  t.eq(Flags.on("BES_TEST_FLAG_A"), true, "on: unset -> true")
  t.eq(Flags.off("BES_TEST_FLAG_A"), false, "off: unset -> false")
  t.eq(Flags.num("BES_TEST_FLAG_A", 7), 7, "num: unset -> default")
  t.eq(Flags.num("BES_TEST_FLAG_A"), nil, "num: unset, no default -> nil")
  t.eq(Flags.str("BES_TEST_FLAG_A", "x"), "x", "str: unset -> default")

  Flags.set("BES_TEST_FLAG_A", "0")
  t.eq(Flags.on("BES_TEST_FLAG_A"), false, "on: '0' -> false")
  t.eq(Flags.off("BES_TEST_FLAG_A"), false, "off: '0' -> false")
  t.eq(Flags.num("BES_TEST_FLAG_A", 7), 0, "num: '0' -> 0")

  Flags.set("BES_TEST_FLAG_A", "1")
  t.eq(Flags.on("BES_TEST_FLAG_A"), true, "on: '1' -> true")
  t.eq(Flags.off("BES_TEST_FLAG_A"), true, "off: '1' -> true")

  Flags.set("BES_TEST_FLAG_A", "all")
  t.eq(Flags.num("BES_TEST_FLAG_A", 8), 8, "num: unparsable -> default")
  t.eq(Flags.str("BES_TEST_FLAG_A"), "all", "str: raw value")
  t.eq(Flags.on("BES_TEST_FLAG_A"), true, "on: anything but '0' -> true")

  Flags.set("BES_TEST_FLAG_A", nil)
  t.eq(Flags.str("BES_TEST_FLAG_A"), nil, "set(nil) clears the override")

  -- ---- the sample cap ----
  local saved = rawget(_G, "BES_MC_CAP")
  rawset(_G, "BES_MC_CAP", nil)
  t.eq(Flags.mc_cap(40), 40, "mc_cap: no cap -> unchanged")
  rawset(_G, "BES_MC_CAP", 3)
  t.eq(Flags.mc_cap(40), 3, "mc_cap: clipped to the cap")
  t.eq(Flags.mc_cap(2), 2, "mc_cap: below the cap -> unchanged")
  rawset(_G, "BES_MC_CAP", saved)

  -- ---- the inventory records what was read ----
  local seen = {}
  for _, f in ipairs(Flags.list()) do seen[f.name] = f end
  t.ok(seen.BES_TEST_FLAG_A ~= nil, "list: a read flag is recorded")
  Flags.reset()

  -- ---- the rule: no engine/ or sim/ file reads the environment or a BES_* global directly ----
  local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
  local root = here .. "../"
  local files = {
    "build_plan", "boss_effect", "consumable_value", "dagger", "decision_engine", "deck_plan", "discard_fuel",
    "discard_value", "eval_function", "farm", "generators", "hand_eval", "heuristics", "hold_fuel", "joker_data",
    "joker_downside", "joker_effects", "joker_value", "mechanics", "ordering", "owned_synergy", "pacing",
    "pack_open_advisor", "packs", "perkeo", "scaling_fuel", "search", "shop_advisor", "simulation", "skip_advisor",
    "tags", "tarot", "value_units", "vouchers",
  }
  local paths = {}
  for _, n in ipairs(files) do paths[#paths + 1] = "engine/" .. n .. ".lua" end
  for _, n in ipairs({ "content", "driver", "joker_tick", "lookahead", "probe", "search", "world" }) do
    paths[#paths + 1] = "sim/" .. n .. ".lua"
  end
  local opened = 0
  for _, rel in ipairs(paths) do
    local fh = io.open(root .. rel, "r")
    if fh then
      opened = opened + 1
      local bad
      for line in fh:lines() do
        local code = line:gsub("%-%-.*$", "")
        if code:find("os%.getenv") or code:find("_G%.BES_") or code:find('rawget%(_G, *"BES_') then bad = line; break end
      end
      fh:close()
      t.ok(bad == nil, rel .. " reads the environment / a BES_ global directly; go through engine/flags.lua")
    end
  end
  t.ok(opened >= 30, "the purity scan found the engine files (opened " .. opened .. ")")
end
