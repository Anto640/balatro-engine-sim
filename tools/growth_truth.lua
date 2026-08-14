-- tools/growth_truth.lua
-- WHAT GROWTH DOES THE ENGINE ACTUALLY REALIZE, and how does `Pacing.growth_factor` compare?
--
-- §25b found `P.pace` over-confident by an order of magnitude (ante 4: believes 12.1x the ante-8
-- requirement, while 57 runs die at antes 3-5) and §26b found the error is not the LEVEL but the
-- TREND -- realized growth falls as the board saturates while the model's rises. `growth_factor` has
-- never been validated against realized growth, which has been recorded in `metrics.capacity` in
-- every batch this project has ever run.
--
-- ⚠ SURVIVORSHIP, and how this removes most of it. Taking ratios only between consecutive `ante`
-- records conditions on reaching ante a+1, so runs that fell behind leave the sample and the late
-- figures are biased UP -- optimistic exactly where the engine dies. But the `death` record carries
-- `metrics.capacity` too, so the FATAL transition is observable: a run dying in ante a+1 still
-- contributes capacity(a) -> capacity(death). Including it makes the denominator death-inclusive.
--
-- Reports both, because the gap between them is itself the survivorship bias, measured.
--
--   usage: lua tools/growth_truth.lua <batch.jsonl> [more.jsonl ...]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")
local Mechanics = require("engine.mechanics")

local function num(s, k) return tonumber(s:match('"' .. k .. '":([%-%d%.e%+]+)')) end

local REQ = {}
for a = 1, 8 do REQ[a] = Mechanics.blind_requirement(a, "Boss") end

for _, f in ipairs({ ... }) do
  local runs = {}
  local fh = io.open(f)
  if not fh then print("missing " .. f)
  else
    for line in fh:lines() do
      local seed = line:match('"seed":"(%d+)"')
      if seed then
        local m = line:match('"metrics":(.*)$')
        if line:match('"kind":"ante"') and m then
          local a, cap, mg = num(line, "ante"), num(m, "capacity"), num(m, "pace_margin")
          if a and cap and cap > 0 then
            runs[seed] = runs[seed] or { ante = {} }
            runs[seed].ante[a] = { cap = cap, mg = mg }
          end
        elseif line:match('"kind":"death"') and m then
          local a, cap = num(line, "ante"), num(m, "capacity")
          if a and cap and cap > 0 then
            runs[seed] = runs[seed] or { ante = {} }
            runs[seed].death = { ante = a, cap = cap }
          end
        end
      end
    end
    fh:close()

    local surv, all = {}, {}
    for _, r in pairs(runs) do
      for a = 1, 7 do
        local cur = r.ante[a]
        if cur then
          local nxt = r.ante[a + 1]
          if nxt then
            surv[a] = surv[a] or { n = 0, s = 0 }; all[a] = all[a] or { n = 0, s = 0 }
            surv[a].n = surv[a].n + 1; surv[a].s = surv[a].s + nxt.cap / cur.cap
            all[a].n  = all[a].n + 1;  all[a].s  = all[a].s + nxt.cap / cur.cap
          elseif r.death and r.death.ante == a + 1 then
            -- the FATAL transition: observable, and exactly what the survivor-only view drops
            all[a] = all[a] or { n = 0, s = 0 }
            all[a].n = all[a].n + 1; all[a].s = all[a].s + r.death.cap / cur.cap
          end
        end
      end
    end

    -- the model's own g, recovered exactly from pace_margin (see pacing_screen.lua)
    local model = {}
    for _, r in pairs(runs) do
      for a = 1, 7 do
        local c = r.ante[a]
        if c and c.mg and c.mg > 0 then
          local g = (c.mg * math.max(1, REQ[8]) / c.cap) ^ (1 / (8 - a))
          model[a] = model[a] or { n = 0, s = 0 }
          model[a].n = model[a].n + 1; model[a].s = model[a].s + g
        end
      end
    end

    print(("%s"):format(f:gsub(".*/", "")))
    print(("  %-8s %8s %10s %8s %10s %10s %10s")
      :format("ante", "n(surv)", "surv only", "n(all)", "DEATH-INC", "model g", "required"))
    for a = 1, 7 do
      local s, al, mo = surv[a], all[a], model[a]
      if al and al.n >= 10 then
        print(("  a%d->a%d %8d %10.2f %8d %10.2f %10.2f %10.2f")
          :format(a, a + 1, s and s.n or 0, s and (s.s / s.n) or 0, al.n, al.s / al.n,
                  mo and (mo.s / mo.n) or 0, REQ[a + 1] / REQ[a]))
      end
    end
    print("  (surv only conditions on reaching a+1; DEATH-INC adds the fatal transition, so the gap")
    print("   between the two columns IS the survivorship bias, measured rather than assumed)")
  end
end
