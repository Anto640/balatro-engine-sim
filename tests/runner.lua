-- tests/runner.lua
-- Headless test harness. Run from the project root with stock Lua/LuaJIT:
--     lua tests/runner.lua
-- No love, no G, no Steamodded required -- this is the point of the POD design.

-- Make `require("util.cards")` etc. resolve from the project root regardless of
-- where lua is invoked, by locating this file's directory.
local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
local root = here .. ".." -- project root relative to tests/
package.path = table.concat({
  root .. "/?.lua",
  root .. "/?/init.lua",
  package.path,
}, ";")

-- ---- Assertion harness ------------------------------------------------------
local passed, failed = 0, 0
local failures = {}

local function fmt(v)
  if type(v) == "number" and math.floor(v) ~= v then return string.format("%.4f", v) end
  return tostring(v)
end

local t = {}
function t.ok(cond, msg)
  if cond then passed = passed + 1
  else failed = failed + 1; failures[#failures + 1] = msg .. "  (expected truthy)" end
end
function t.eq(got, want, msg)
  if got == want then passed = passed + 1
  else failed = failed + 1
    failures[#failures + 1] = string.format("%s  (got %s, want %s)", msg, fmt(got), fmt(want)) end
end
function t.near(got, want, msg, eps)
  eps = eps or 1e-6
  if type(got) == "number" and type(want) == "number" and math.abs(got - want) <= eps then
    passed = passed + 1
  else failed = failed + 1
    failures[#failures + 1] = string.format("%s  (got %s, want %s)", msg, fmt(got), fmt(want)) end
end

-- ---- Discover + run suites --------------------------------------------------
local suites = {
  "tests.test_hand_eval",
  "tests.test_decision",
  "tests.test_simulation",
  "tests.test_shop",
  "tests.test_build_plan",
  "tests.test_deck_plan",
  "tests.test_eval",
  "tests.test_jokers",
  "tests.test_mechanics",
  "tests.test_advisors",
  "tests.test_value_units",
  "tests.test_replay_fixture",
  "tests.test_fixture_run_state",
  "tests.test_trade_dependence",
  "tests.test_reorder_clear",
  "tests.test_paired_trade",
  "tests.test_econ_jokers",
  "tests.test_purple_slot",
  "tests.test_telemetry",
  "tests.test_probe",
  "tests.test_autoplay",
  "tests.test_hud_panel",
  "tests.test_scheduler",
  "tests.test_fast_mode",
  "tests.test_settings",
}
-- NOTE: the Phase-1 simulator integration suites (tests.test_world, tests.test_driver)
-- drive the REAL engine per hand (Monte-Carlo) and take minutes, so they are NOT in the
-- fast unit suite. Run them with:  lua tests/runner_sim.lua  (or luajit, much faster).

print("Balatro Engine Sim -- test runner")
print(string.rep("-", 50))
for _, name in ipairs(suites) do
  local ok, suite = pcall(require, name)
  if not ok then
    failed = failed + 1
    failures[#failures + 1] = "could not load suite " .. name .. ": " .. tostring(suite)
  else
    local ran, err = pcall(suite, t)
    if not ran then
      failed = failed + 1
      failures[#failures + 1] = "error in suite " .. name .. ": " .. tostring(err)
    end
  end
end

print(string.rep("-", 50))
for _, f in ipairs(failures) do print("FAIL  " .. f) end
print(string.format("%d passed, %d failed", passed, failed))

os.exit(failed == 0 and 0 or 1)
