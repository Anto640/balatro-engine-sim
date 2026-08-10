-- tests/runner_sim.lua
-- Phase-1 SIMULATOR integration suites. These drive the REAL engine per hand
-- (Monte-Carlo) so they take minutes under stock Lua -- run them with LuaJIT:
--     luajit tests/runner_sim.lua
-- Kept OUT of the fast unit runner (tests/runner.lua) so "run after every change"
-- stays quick. Same assertion harness as the unit runner.

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
local root = here .. ".."
package.path = table.concat({ root .. "/?.lua", root .. "/?/init.lua", package.path }, ";")

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
  if type(got) == "number" and type(want) == "number" and math.abs(got - want) <= eps then passed = passed + 1
  else failed = failed + 1
    failures[#failures + 1] = string.format("%s  (got %s, want %s)", msg, fmt(got), fmt(want)) end
end

local suites = {
  "tests.test_joker_tick",
  "tests.test_consumables",
  "tests.test_vouchers",
  "tests.test_tags",
  "tests.test_content_rates",
  "tests.test_economy_boss",
  "tests.test_world",
  "tests.test_driver",
  "tests.test_replay_harness",
}

print("BES simulator (Phase 1) -- integration suites")
print(string.rep("-", 50))
for _, name in ipairs(suites) do
  local ok, suite = pcall(require, name)
  if not ok then
    failed = failed + 1; failures[#failures + 1] = "could not load " .. name .. ": " .. tostring(suite)
  else
    local ran, err = pcall(suite, t)
    if not ran then failed = failed + 1; failures[#failures + 1] = "error in " .. name .. ": " .. tostring(err) end
  end
end

print(string.rep("-", 50))
for _, f in ipairs(failures) do print("FAIL  " .. f) end
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
