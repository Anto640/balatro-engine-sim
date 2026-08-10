-- engine/joker_data.lua
-- Data-driven catalogue of base-game jokers. Drives shop valuation (which joker
-- to buy) and the run-strength / future-value evaluation. PURE data + lookups.
--
-- Each entry:
--   name, rarity, cost  -- display + base shop price
--   cat   -- primary category (see CATS below)
--   tier  -- 0..10 heuristic of late-game power / scaling ceiling
--   econ  -- estimated dollars/round generated (average; 0 if none)
--   tags  -- synergy descriptors; see TAG VOCAB below
--
-- TAG VOCAB: suit:Hearts|Diamonds|Clubs|Spades, rank:even|odd|face|ace,
--   enh:steel|glass|gold|lucky|stone|mult|bonus|wild, seal:gold|red|blue|purple,
--   edition:negative, handtype:pair|twopair|trips|straight|flush|fullhouse|highcard,
--   retrigger, copy, economy, discard, scaling, xmult, hand_size, deck_size,
--   consumable, probability, suit_any (cares about all suits)
--
-- NOTE: keys are the in-game center keys (j_*). A few may be imperfect; unknown
-- keys simply fall back to a neutral default (see JokerData.get), never crash.

local JokerData = {}

-- helper to build an entry tersely
local function J(name, rarity, cost, cat, tier, econ, tags)
  return { name = name, rarity = rarity, cost = cost, cat = cat,
           tier = tier, econ = econ or 0, tags = tags or {} }
end

local D = {}

-- ===================== COMMON =====================
D.j_joker            = J("Joker", "Common", 2, "flat_mult", 2, 0, {})
D.j_greedy_joker     = J("Greedy Joker", "Common", 5, "flat_mult", 4, 0, { "suit:Diamonds" })
D.j_lusty_joker      = J("Lusty Joker", "Common", 5, "flat_mult", 4, 0, { "suit:Hearts" })
D.j_wrathful_joker   = J("Wrathful Joker", "Common", 5, "flat_mult", 4, 0, { "suit:Spades" })
D.j_gluttonous_joker = J("Gluttonous Joker", "Common", 5, "flat_mult", 4, 0, { "suit:Clubs" })
-- the live game key is the misspelled "j_gluttenous_joker" (the base game's own
-- typo) -- alias it so tier/tags/synergy resolve too (see joker_effects).
D.j_gluttenous_joker = D.j_gluttonous_joker
D.j_jolly            = J("Jolly Joker", "Common", 3, "flat_mult", 3, 0, { "handtype:pair" })
D.j_zany             = J("Zany Joker", "Common", 4, "flat_mult", 4, 0, { "handtype:trips" })
D.j_mad              = J("Mad Joker", "Common", 4, "flat_mult", 4, 0, { "handtype:twopair" })
D.j_crazy            = J("Crazy Joker", "Common", 4, "flat_mult", 4, 0, { "handtype:straight" })
D.j_droll            = J("Droll Joker", "Common", 4, "flat_mult", 4, 0, { "handtype:flush" })
D.j_sly              = J("Sly Joker", "Common", 3, "flat_chips", 2, 0, { "handtype:pair" })
D.j_wily             = J("Wily Joker", "Common", 4, "flat_chips", 3, 0, { "handtype:trips" })
D.j_clever           = J("Clever Joker", "Common", 4, "flat_chips", 3, 0, { "handtype:twopair" })
D.j_devious          = J("Devious Joker", "Common", 4, "flat_chips", 3, 0, { "handtype:straight" })
D.j_crafty           = J("Crafty Joker", "Common", 4, "flat_chips", 3, 0, { "handtype:flush" })
D.j_half             = J("Half Joker", "Common", 5, "flat_mult", 4, 0, {})
D.j_stencil          = J("Joker Stencil", "Uncommon", 8, "xmult", 7, 0, { "xmult" })
D.j_four_fingers     = J("Four Fingers", "Uncommon", 7, "hand_modifier", 5, 0, { "handtype:flush", "handtype:straight" })
D.j_mime             = J("Mime", "Uncommon", 5, "retrigger", 6, 0, { "retrigger", "enh:steel", "seal:gold" })
D.j_credit_card      = J("Credit Card", "Common", 1, "utility", 1, 0, { "economy" })
D.j_ceremonial       = J("Ceremonial Dagger", "Uncommon", 6, "scaling_mult", 6, 0, { "scaling" })
D.j_banner           = J("Banner", "Common", 5, "flat_chips", 4, 0, { "discard" })
D.j_mystic_summit    = J("Mystic Summit", "Common", 5, "flat_mult", 4, 0, { "discard" })
D.j_marble           = J("Marble Joker", "Uncommon", 6, "deck_modifier", 3, 0, { "enh:stone", "deck_size" })
D.j_loyalty_card     = J("Loyalty Card", "Uncommon", 5, "xmult", 5, 0, { "xmult" })
D.j_8_ball           = J("8 Ball", "Common", 5, "card_generation", 3, 0, { "consumable", "probability" })
D.j_misprint         = J("Misprint", "Common", 4, "flat_mult", 2, 0, { "probability" })
D.j_dusk             = J("Dusk", "Uncommon", 5, "retrigger", 6, 0, { "retrigger" })
D.j_raised_fist      = J("Raised Fist", "Common", 5, "flat_mult", 3, 0, {})
D.j_chaos            = J("Chaos the Clown", "Common", 4, "utility", 3, 0, { "economy" })
D.j_fibonacci        = J("Fibonacci", "Uncommon", 8, "flat_mult", 5, 0, { "rank:ace" })
D.j_steel_joker      = J("Steel Joker", "Uncommon", 7, "xmult", 7, 0, { "xmult", "enh:steel" })
D.j_scary_face       = J("Scary Face", "Common", 4, "flat_chips", 3, 0, { "rank:face" })
D.j_abstract         = J("Abstract Joker", "Common", 4, "flat_mult", 4, 0, {})
D.j_delayed_grat     = J("Delayed Gratification", "Common", 4, "economy", 3, 4, { "economy", "discard" })
D.j_hack             = J("Hack", "Uncommon", 6, "retrigger", 6, 0, { "retrigger" })
D.j_pareidolia       = J("Pareidolia", "Uncommon", 5, "hand_modifier", 5, 0, { "rank:face" })
D.j_gros_michel      = J("Gros Michel", "Common", 5, "flat_mult", 4, 0, { "probability" })
D.j_even_steven      = J("Even Steven", "Common", 4, "flat_mult", 4, 0, { "rank:even" })
D.j_odd_todd         = J("Odd Todd", "Common", 4, "flat_chips", 4, 0, { "rank:odd" })
D.j_scholar          = J("Scholar", "Common", 4, "flat_mult", 4, 0, { "rank:ace" })
D.j_business         = J("Business Card", "Common", 4, "economy", 3, 2, { "economy", "rank:face", "probability" })
D.j_supernova        = J("Supernova", "Common", 5, "scaling_mult", 5, 0, { "scaling" })
D.j_ride_the_bus     = J("Ride the Bus", "Common", 6, "scaling_mult", 7, 0, { "scaling" })
D.j_space            = J("Space Joker", "Uncommon", 5, "utility", 5, 0, { "probability" })
D.j_egg              = J("Egg", "Common", 4, "economy", 2, 3, { "economy" })
D.j_burglar          = J("Burglar", "Uncommon", 6, "utility", 5, 0, { "hand_size" })
D.j_blackboard       = J("Blackboard", "Uncommon", 6, "xmult", 6, 0, { "xmult", "suit:Spades", "suit:Clubs" })
D.j_runner           = J("Runner", "Common", 5, "scaling_chips", 5, 0, { "scaling", "handtype:straight" })
D.j_ice_cream        = J("Ice Cream", "Common", 5, "flat_chips", 3, 0, {})
D.j_dna              = J("DNA", "Rare", 8, "deck_modifier", 8, 0, { "deck_size" })
D.j_splash           = J("Splash", "Common", 3, "hand_modifier", 3, 0, {})
D.j_blue_joker       = J("Blue Joker", "Common", 5, "flat_chips", 4, 0, { "deck_size" })
D.j_sixth_sense      = J("Sixth Sense", "Uncommon", 6, "card_generation", 4, 0, { "consumable" })
D.j_constellation    = J("Constellation", "Uncommon", 6, "xmult_scaling", 8, 0, { "xmult", "scaling", "consumable" })
D.j_hiker            = J("Hiker", "Uncommon", 5, "scaling_chips", 5, 0, { "scaling" })
D.j_faceless         = J("Faceless Joker", "Common", 4, "economy", 3, 3, { "economy", "discard", "rank:face" })
D.j_green_joker      = J("Green Joker", "Common", 4, "scaling_mult", 6, 0, { "scaling", "discard" })
D.j_superposition    = J("Superposition", "Common", 4, "card_generation", 4, 0, { "consumable", "rank:ace", "handtype:straight" })
D.j_todo_list        = J("To Do List", "Common", 4, "economy", 3, 4, { "economy" })
D.j_cavendish        = J("Cavendish", "Common", 4, "xmult", 7, 0, { "xmult", "probability" })
D.j_card_sharp       = J("Card Sharp", "Uncommon", 6, "xmult", 7, 0, { "xmult" })
D.j_red_card         = J("Red Card", "Common", 5, "scaling_mult", 5, 0, { "scaling" })
D.j_madness          = J("Madness", "Uncommon", 7, "xmult_scaling", 6, 0, { "xmult", "scaling" })
D.j_madness.growth   = 0  -- scales by DESTROYING your jokers: growth isn't free value, so don't project it (Downside prices the self-harm)
D.j_square           = J("Square Joker", "Common", 4, "scaling_chips", 5, 0, { "scaling" })
D.j_seance           = J("Séance", "Uncommon", 6, "card_generation", 4, 0, { "consumable", "handtype:flush", "handtype:straight" })
D.j_riff_raff        = J("Riff-Raff", "Common", 6, "card_generation", 4, 0, {})
D.j_vampire          = J("Vampire", "Uncommon", 7, "xmult_scaling", 8, 0, { "xmult", "scaling", "enh:glass", "enh:steel", "enh:gold" })
D.j_shortcut         = J("Shortcut", "Uncommon", 7, "hand_modifier", 5, 0, { "handtype:straight" })
D.j_hologram         = J("Hologram", "Uncommon", 7, "xmult_scaling", 8, 0, { "xmult", "scaling", "deck_size" })
D.j_vagabond         = J("Vagabond", "Rare", 8, "card_generation", 5, 0, { "consumable" })
D.j_baron            = J("Baron", "Rare", 8, "xmult", 9, 0, { "xmult", "rank:king" })
D.j_cloud_9          = J("Cloud 9", "Uncommon", 7, "economy", 4, 4, { "economy" })
D.j_rocket           = J("Rocket", "Uncommon", 6, "economy", 4, 3, { "economy", "scaling" })
D.j_obelisk          = J("Obelisk", "Rare", 8, "xmult_scaling", 8, 0, { "xmult", "scaling" })
D.j_midas_mask       = J("Midas Mask", "Uncommon", 7, "deck_modifier", 5, 0, { "enh:gold", "rank:face" })
D.j_luchador         = J("Luchador", "Uncommon", 5, "utility", 3, 0, {})
D.j_photograph       = J("Photograph", "Common", 5, "xmult", 6, 0, { "xmult", "rank:face" })
D.j_gift             = J("Gift Card", "Uncommon", 6, "economy", 3, 0, { "economy" })
D.j_turtle_bean      = J("Turtle Bean", "Uncommon", 6, "utility", 3, 0, { "hand_size" })
D.j_erosion          = J("Erosion", "Uncommon", 6, "flat_mult", 6, 0, { "deck_size" })
D.j_reserved_parking = J("Reserved Parking", "Common", 4, "economy", 3, 3, { "economy", "rank:face", "probability" })
D.j_mail             = J("Mail-In Rebate", "Common", 4, "economy", 3, 4, { "economy", "discard" })
D.j_to_the_moon      = J("To the Moon", "Uncommon", 5, "economy", 4, 4, { "economy" })
D.j_hallucination    = J("Hallucination", "Common", 4, "card_generation", 3, 0, { "consumable", "probability" })
D.j_fortune_teller   = J("Fortune Teller", "Common", 6, "scaling_mult", 5, 0, { "scaling", "consumable" })
D.j_juggler          = J("Juggler", "Common", 4, "utility", 3, 0, { "hand_size" })
D.j_drunkard         = J("Drunkard", "Common", 4, "utility", 3, 0, { "discard" })
D.j_stone            = J("Stone Joker", "Uncommon", 6, "flat_chips", 6, 0, { "enh:stone" })
D.j_golden           = J("Golden Joker", "Common", 6, "economy", 5, 4, { "economy" })
D.j_lucky_cat        = J("Lucky Cat", "Uncommon", 7, "xmult_scaling", 8, 0, { "xmult", "scaling", "enh:lucky" })
D.j_baseball         = J("Baseball Card", "Rare", 8, "xmult", 7, 0, { "xmult" })
D.j_bull             = J("Bull", "Uncommon", 6, "flat_chips", 7, 0, { "economy" })
D.j_diet_cola        = J("Diet Cola", "Uncommon", 6, "utility", 3, 0, {})
D.j_trading          = J("Trading Card", "Uncommon", 6, "economy", 3, 3, { "economy", "discard" })
D.j_flash            = J("Flash Card", "Uncommon", 5, "scaling_mult", 5, 0, { "scaling" })
D.j_popcorn          = J("Popcorn", "Common", 5, "flat_mult", 3, 0, {})
D.j_trousers         = J("Spare Trousers", "Uncommon", 6, "scaling_mult", 6, 0, { "scaling", "handtype:twopair" })
D.j_ancient          = J("Ancient Joker", "Rare", 8, "xmult", 8, 0, { "xmult" })
D.j_ramen            = J("Ramen", "Uncommon", 6, "xmult", 6, 0, { "xmult", "discard" })
D.j_walkie_talkie    = J("Walkie Talkie", "Common", 4, "flat_mult", 4, 0, { "rank:even" })
D.j_selzer           = J("Seltzer", "Uncommon", 6, "retrigger", 6, 0, { "retrigger" })
D.j_castle           = J("Castle", "Uncommon", 6, "scaling_chips", 6, 0, { "scaling", "discard" })
D.j_smiley           = J("Smiley Face", "Common", 4, "flat_mult", 4, 0, { "rank:face" })
D.j_campfire         = J("Campfire", "Rare", 9, "xmult_scaling", 8, 0, { "xmult", "scaling" })
D.j_ticket           = J("Golden Ticket", "Common", 5, "economy", 4, 3, { "economy", "enh:gold" })
D.j_mr_bones         = J("Mr. Bones", "Uncommon", 5, "utility", 6, 0, {})
D.j_acrobat          = J("Acrobat", "Uncommon", 6, "xmult", 7, 0, { "xmult" })
D.j_sock_and_buskin  = J("Sock and Buskin", "Uncommon", 6, "retrigger", 7, 0, { "retrigger", "rank:face" })
D.j_swashbuckler     = J("Swashbuckler", "Common", 4, "flat_mult", 4, 0, {})
D.j_troubadour       = J("Troubadour", "Uncommon", 6, "utility", 5, 0, { "hand_size" })
D.j_certificate      = J("Certificate", "Uncommon", 6, "deck_modifier", 4, 0, { "seal:gold" })
D.j_smeared          = J("Smeared Joker", "Uncommon", 7, "hand_modifier", 6, 0, { "suit_any", "handtype:flush" })
D.j_throwback        = J("Throwback", "Uncommon", 6, "xmult_scaling", 6, 0, { "xmult", "scaling" })
D.j_hanging_chad     = J("Hanging Chad", "Common", 4, "retrigger", 6, 0, { "retrigger" })
D.j_rough_gem        = J("Rough Gem", "Uncommon", 7, "economy", 6, 4, { "economy", "suit:Diamonds" })
D.j_bloodstone       = J("Bloodstone", "Uncommon", 7, "xmult", 7, 0, { "xmult", "suit:Hearts", "probability" })
D.j_arrowhead        = J("Arrowhead", "Uncommon", 7, "flat_chips", 6, 0, { "suit:Spades" })
D.j_onyx_agate       = J("Onyx Agate", "Uncommon", 7, "flat_mult", 6, 0, { "suit:Clubs" })
D.j_glass            = J("Glass Joker", "Uncommon", 6, "xmult_scaling", 8, 0, { "xmult", "scaling", "enh:glass" })
D.j_ring_master      = J("Showman", "Uncommon", 5, "utility", 4, 0, {})
D.j_flower_pot       = J("Flower Pot", "Uncommon", 6, "xmult", 6, 0, { "xmult", "suit_any" })
D.j_blueprint        = J("Blueprint", "Rare", 10, "xmult", 9, 0, { "xmult", "copy" })
D.j_wee              = J("Wee Joker", "Rare", 8, "scaling_chips", 7, 0, { "scaling" })
D.j_merry_andy       = J("Merry Andy", "Uncommon", 7, "utility", 4, 0, { "discard", "hand_size" })
D.j_oops             = J("Oops! All 6s", "Uncommon", 4, "utility", 5, 0, { "probability" })
D.j_idol             = J("The Idol", "Uncommon", 6, "xmult", 7, 0, { "xmult" })
D.j_seeing_double    = J("Seeing Double", "Uncommon", 6, "xmult", 6, 0, { "xmult", "suit:Clubs" })
D.j_matador          = J("Matador", "Uncommon", 7, "economy", 3, 4, { "economy" })
D.j_hit_the_road     = J("Hit the Road", "Rare", 8, "xmult_scaling", 7, 0, { "xmult", "scaling", "discard" })
D.j_duo              = J("The Duo", "Rare", 8, "xmult", 8, 0, { "xmult", "handtype:pair" })
D.j_trio             = J("The Trio", "Rare", 8, "xmult", 8, 0, { "xmult", "handtype:trips" })
D.j_family           = J("The Family", "Rare", 8, "xmult", 8, 0, { "xmult", "handtype:four" })
D.j_order            = J("The Order", "Rare", 8, "xmult", 8, 0, { "xmult", "handtype:straight" })
D.j_tribe            = J("The Tribe", "Rare", 8, "xmult", 8, 0, { "xmult", "handtype:flush" })
D.j_stuntman         = J("Stuntman", "Rare", 7, "flat_chips", 6, 0, { "hand_size" })
D.j_invisible        = J("Invisible Joker", "Rare", 8, "utility", 6, 0, { "copy" })
D.j_brainstorm       = J("Brainstorm", "Rare", 10, "xmult", 9, 0, { "xmult", "copy" })
D.j_satellite        = J("Satellite", "Uncommon", 6, "economy", 5, 4, { "economy", "consumable" })
D.j_shoot_the_moon   = J("Shoot the Moon", "Common", 5, "flat_mult", 5, 0, { "rank:queen" })
D.j_drivers_license  = J("Driver's License", "Rare", 7, "xmult", 7, 0, { "xmult" })
D.j_cartomancer      = J("Cartomancer", "Uncommon", 6, "card_generation", 5, 0, { "consumable" })
D.j_astronomer       = J("Astronomer", "Uncommon", 8, "economy", 5, 0, { "economy", "consumable" })
D.j_burnt            = J("Burnt Joker", "Uncommon", 8, "utility", 6, 0, { "discard" })
D.j_bootstraps       = J("Bootstraps", "Uncommon", 6, "flat_mult", 6, 0, { "economy" })

-- ===================== LEGENDARY (Soul) =====================
D.j_caino            = J("Canio", "Legendary", 20, "xmult_scaling", 10, 0, { "xmult", "scaling", "rank:face" })
D.j_triboulet        = J("Triboulet", "Legendary", 20, "xmult", 10, 0, { "xmult", "rank:king", "rank:queen" })
D.j_yorick           = J("Yorick", "Legendary", 20, "xmult_scaling", 9, 0, { "xmult", "scaling", "discard" })
D.j_chicot           = J("Chicot", "Legendary", 20, "utility", 8, 0, {})
D.j_perkeo           = J("Perkeo", "Legendary", 20, "card_generation", 9, 0, { "consumable" })

-- ===================== lookups =====================

local DEFAULT = { name = "Joker", rarity = "Common", cost = 4, cat = "flat_mult",
                  tier = 3, econ = 0, tags = {} }

function JokerData.get(key)
  return key and D[key] or nil
end

-- Always returns a usable entry (default for unknown keys).
function JokerData.resolve(key)
  return (key and D[key]) or DEFAULT
end

function JokerData.has_tag(key, tag)
  local e = D[key]
  if not e then return false end
  for _, t in ipairs(e.tags) do if t == tag then return true end end
  return false
end

function JokerData.is_xmult(key)
  local e = D[key]
  if not e then return false end
  return e.cat == "xmult" or e.cat == "xmult_scaling"
end

function JokerData.is_scaling(key)
  local e = D[key]
  if not e then return false end
  return e.cat == "scaling_mult" or e.cat == "scaling_chips" or e.cat == "xmult_scaling"
       or JokerData.has_tag(key, "scaling")
end

-- Per-blind fractional growth of a scaling joker's SCORE contribution, used to
-- project its value forward over the blinds remaining: a scaler bought early is
-- worth far more than its current counter because it accrues on every blind left
-- (see engine/eval_function scaling_projection). Keyed by category so it stays
-- data-driven; a per-entry `growth` override wins when present.
--
-- Only score-scaling categories grow here. The generic "scaling" TAG is NOT
-- enough (e.g. Rocket scales DOLLARS, not score -- its growth is valued through
-- econ, not here), which is why this gates on cat, not is_scaling.
local SCALING_GROWTH = {
  xmult_scaling = 0.34,   -- x-mult compounds hardest -> steepest growth
  scaling_mult  = 0.20,   -- linear +mult accrual, strong
  scaling_chips = 0.10,   -- chips get out-scaled by mult late -> smaller
}

-- Per-blind fractional growth rate for a scaling joker (0 if it doesn't scale
-- score). Unknown keys -> 0.
function JokerData.scaling_growth(key)
  local e = D[key]
  if not e then return 0 end
  return e.growth or SCALING_GROWTH[e.cat] or 0
end

-- Hands whose PLAY triggers a scaling joker's growth. Some scalers only accrue on
-- a specific played hand (Runner on a Straight; Square on an exactly-4-card hand ->
-- Two Pair / Four of a Kind under greedy play). If your deck rarely makes that
-- hand the joker barely grows, so its forward projection must be DISCOUNTED by how
-- often the trigger actually fires (see eval_function.scaling_projection). A joker
-- ABSENT from this table accrues every blind (no per-hand gate) and projects at
-- full growth -- the existing behaviour. Extend as more conditional scalers are
-- modelled (Spare Trousers/two-pair, etc.).
local SCALE_TRIGGER_HANDS = {
  j_runner = { "Straight", "Straight Flush" },
  j_square = { "Two Pair", "Four of a Kind" },
  -- K3: Spare Trousers grows only on a hand CONTAINING Two Pair, so gate its growth projection
  -- by how often the deck makes one (was omitted -> projected at full growth in every deck).
  j_trousers = { "Two Pair", "Full House", "Four of a Kind" },
}
function JokerData.scale_trigger_hands(key)
  return SCALE_TRIGGER_HANDS[key]
end

-- count of catalogued jokers (for tests / sanity)
function JokerData.count()
  local n = 0
  for _ in pairs(D) do n = n + 1 end
  return n
end

JokerData.ALL = D
return JokerData
