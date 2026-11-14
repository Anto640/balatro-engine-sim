-- tests/test_rng.lua
-- util/rng: the deterministic streams the sampling advisors draw from.

local Rng = require("util.rng")

return function(t)
  -- a seed is always a valid generator state
  t.eq(Rng.seed(0), 1, "seed: zero -> 1")
  t.eq(Rng.seed(-12345.7), 12345, "seed: sign and fraction dropped")
  t.eq(Rng.seed(Rng.M), 1, "seed: a multiple of the modulus -> 1")
  t.eq(Rng.seed(Rng.M + 5), 5, "seed: reduced mod M")

  -- same seed, same stream; different seeds differ
  local a, b, c = Rng.stream(42), Rng.stream(42), Rng.stream(43)
  local same, differ = true, false
  for _ = 1, 50 do
    local x, y, z = a(), b(), c()
    if x ~= y then same = false end
    if x ~= z then differ = true end
    if x < 0 or x >= 1 then same = false end
  end
  t.ok(same, "stream: deterministic, and every draw is in [0, 1)")
  t.ok(differ, "stream: another seed gives another stream")

  -- the first draw is the Park-Miller step
  t.eq(Rng.stream(1)(), (16807 - 1) / 2147483646, "stream: the minimal-standard generator")
  t.eq(Rng.stream(0)(), Rng.stream(Rng.M - 1)(), "stream: a zero seed is lifted to a valid state")
  t.eq(Rng.from_state(42)(), Rng.stream(42)(), "from_state: continues from a valid state")

  -- the rule: generators are built here, not re-written inline (tarot.lua's is unified in a later change)
  local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
  for _, rel in ipairs({ "engine/dagger.lua", "engine/decision_engine.lua", "engine/pack_open_advisor.lua",
      "engine/search.lua", "engine/shop_advisor.lua", "engine/skip_advisor.lua", "engine/consumable_value.lua",
      "engine/eval_function.lua", "engine/joker_value.lua", "sim/world.lua", "main.lua" }) do
    local fh = io.open(here .. "../" .. rel, "r")
    if fh then
      local src = fh:read("*a"); fh:close()
      t.ok(not src:find("16807", 1, true), rel .. " builds its own generator; use util/rng.lua")
    end
  end
end
