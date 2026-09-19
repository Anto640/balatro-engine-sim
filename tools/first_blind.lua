-- tools/first_blind.lua -- dumps the engine's ANTE-1 SMALL-BLIND play, the most reproducible decision in the
-- game (fixed 300 target, starting deck, no jokers). Owner: even here the play is less than optimal.
--   usage: luajit tools/first_blind.lua [nseeds]
package.path = "./?.lua;./?/init.lua;" .. package.path
local World    = require("sim.world")
local Driver   = require("sim.driver")
local Content  = require("sim.content")
local HandEval = require("engine.hand_eval")

local function brief(c)
  local RM={[11]="J",[12]="Q",[13]="K",[14]="A"}; local r=RM[c.rank_id] or tostring(c.rank_id or "?"); local s=tostring(c.suit or "?"):sub(1,1)
  local e = c.enhancement and ("/" .. tostring(c.enhancement):gsub("m_","")) or ""
  return r .. s .. e
end
local function hs(cards) local t={}; for _,c in ipairs(cards or {}) do t[#t+1]=brief(c) end; return table.concat(t," ") end

local nseeds = tonumber(arg[1]) or 6
for s = 1, nseeds do
  local seed = s * 1000 + 3
  local step = 0
  print(("\n===== seed %d ====="):format(seed))
  World._capture = function(gs, ranked)
    local b = gs.blind or {}
    local ante = (gs.meta and gs.meta.ante) or 1
    -- ante 1, first (Small) blind only, before any joker is owned
    if ante ~= 1 then return end
    if (b.name or ""):lower():find("small") == nil and (b.type or ""):lower():find("small") == nil then return end
    step = step + 1
    if step > 6 then return end
    local act = ranked and ranked.best
    local remaining = math.max(0, (b.target_chips or 0) - (b.chips_scored or 0))
    local mx = HandEval.best_play(gs, gs.hand or {})
    local chosen_s = (act and act.cards) and (HandEval.score(gs, act.cards).score or 0) or 0
    print(("  [%d] target=%d scored=%d rem=%d hands=%s disc=%s njok=%d  hand: %s")
      :format(step, b.target_chips or 0, b.chips_scored or 0, remaining,
              tostring(b.hands_left), tostring(b.discards_left), #(gs.jokers or {}), hs(gs.hand)))
    print(("       ENGINE: %s %s  (score %.0f)")
      :format(act and act.type or "?", act and act.cards and hs(act.cards) or (act and act.hand_type or ""), chosen_s))
    print(("       MAX-PLAY: %s  (score %.0f, %s)")
      :format(mx and hs((select(2, HandEval.best_play(gs, gs.hand or {})))) or "?",
              mx and mx.score or 0, mx and mx.hand_type or "?"))
  end
  pcall(Driver.run, seed, { content = Content, max_ante = 1 })
  World._capture = nil
end
