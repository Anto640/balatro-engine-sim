# ADVICE_REVIEW.md — human observations from live advice-review runs

> **What this is.** A catalogue of EVERY observation the mod owner (a very strong Balatro player, ~7/8
> real winrate) made while following the engine's live overlay through two full runs (2026-08-26). It is a
> **reference, not a spec** — his read, to be weighed and validated (with the "run both sides" gate), not
> followed 100%. Runs: **R1** (Z9PBGTL2, died a3 boss 92%), **R2** (9UZ3Q5Q5, died a3 Big 80%).
> Legend: 🔧 issue · 🎨 overlay UX · ❓ method question · ✅ the engine got it right · [status].

---

## 1. In-blind play & digging (the play engine)

- 🔧 **[R1] Didn't discard a dead low card in a marginal draw.** Opening hand held a 4-diamond flush draw
  *including a 2♦*; it kept the 2♦ chasing the flush, but a flush with a 2 rarely one-shots — the 2 should
  be pitched to dig. *(Nuance found: on that exact hand the discard-selection actually keeps the right high
  cards — see §Discard-selection is OK.)*
- 🔧 **[R1] The first blind should be ~always solvable.** Trivially winnable (no jokers, standard deck,
  red-deck extra discard); the engine took 2 hands where 1 should do with correct dig-play. [confirmed: a1
  small took 2 hands]
- 🔧 **[R1] Ante-3 boss: used one partial hand with lots of card resources instead of digging for one
  winning hand.** [play-vs-discard]
- 🔧 **[R1] Discarded a King that could have scored with Smiley Face + more Kings** (threw a synergy face
  card). [confirmed the board degraded from K/QQ/JJ to Ace-high/low pairs]
- 🔧 **[R1] Played lone face cards without selecting others to dig** — should discard chaff and keep
  set-potential cards; caused the death.
- 🔧 **[R2] The "death spiral".** a3-Big: chased straights all game, missed one card, switched to a
  full-house that scored little, then **played 6 weak hands** (a lone Ace, then pairs) without digging;
  even after luckily drawing an ace-low straight it played seemingly random cards, not looking for another
  straight. Died 80%. [confirmed in the per-hand log]
- 🔧 **[R2] Doesn't commit to the line it's clearly on** (straights all game) — abandons it instead of
  digging toward it.
- **NOTE (validated 2026-08-26): the discard *card-selection* is NOT the bug.** Reproducing R1's boss hand,
  the current logic already keeps K+QQ and scores highest; a synergy-weighted variant scored *lower* and
  threw the King. So the real issue is the **PLAY-vs-DISCARD decision** (choosing to play a weak made hand
  instead of discarding to dig), not which cards to throw.

## 2. Money-farming / "milk" spare resources — RECURRING, HIGH VALUE

- 🔧 **[R1] Bought an $8 Arcana pack with good scoring + little need**, dropping under the interest cap and
  gutting a would-be Hermit's payout (so it didn't take Hermit).
- 🔧 **[R2] Cleared blinds immediately with hands/discards to spare instead of farming money.** With
  Faceless (+$ per face card discarded) + Pareidolia (all cards face), every spare discard was free money.
  [confirmed: a1-Boss cleared 1184/600 with **3 hands + 2 discards unused**; a2-Big 1820/1200 with **4 hands
  + 1 discard unused**; happened almost every blind]
- 🔧 **[R2] Once the winning hand was secured it played immediately** rather than spending 2 spare discards
  for ~$10 from Faceless first — "$5 from Faceless outweighs using the hands." Did this **many times**.
- 🔧 **[R2] Discarded only 2 when it could discard 3**, missing money generation — repeatedly.
- 🔧 **[R2] Without Pareidolia it would never have used Faceless at all** — holds the money engine but does
  not leverage it.

## 3. Joker churn (buy-then-sell) & sell-value — CLEAR BUG

- 🔧 **[R2] Buys jokers then immediately says to sell them.** Confirmed pairs: **+Wily→−Wily,
  +Burglar→−Burglar, +Ride the Bus→−Ride the Bus, +Pareidolia→−Pareidolia**. Pure waste (buy price sunk).
- 🔧 **[R1/R2] Took a joker just to sell it, but picked the wrong one.** Took **Ride the Bus** (to sell)
  when **Sixth Sense** was available and **sells for more** — free money left on the table from the pack.
- 🔧 **[R2] Sold a synergy piece for a dead one.** Dumped Pareidolia (its only Faceless enabler) for
  **Satellite**, which produced nothing (it never bought planets).

## 4. Consumable usage (held / timing)

- 🔧 **[R2] Held consumables unused all game.** Only **1** consumable used the entire run; sat on **Hermit**
  and **High Priestess**. [confirmed]
- 🔧 **[R2] Got Hermit but didn't use it immediately** due to inefficient spending; later, with >$20, still
  didn't use it — and opened a tarot pack that **blocked** the useful Hermit.

## 5. Pack ordering & timing

- 🔧 **[R2] Buys shop jokers/vouchers BEFORE opening packs.** e.g. bought Hiker then a Buffoon; said buy a
  voucher before opening a pack. Should **open packs first** — the pack may contain the joker/Hermit that
  makes the buy pointless (Hiker gives no scoring anyway). [FIXED: when a shop buy AND a positive-value
  pack both fit this shop, the shop advisor now leads with the pack (non-lossy reorder — the buy stays an
  affordable alternative). Advice-sequencing; sim impact bounded (both actions still happen), not A/B'd.]
- ❓ **[R2] Opening the bigger/more expensive pack first is questionable** — spending down first lowers a
  later Hermit's payout; sequence money-tarots against current cash.

## 6. Deck-shaping / tarot valuation

- 🔧 **[R1] Took Tower (Stone card, ~nothing) over Strength** (Q→K), which builds toward K-based
  three/four/five-of-a-kind — undervalues deck concentration. [confirmed: Strength was in the pack; engine
  narrated "Face build" yet shaped away from it]
- 🔧 **[R2] Picked Wheel of Fortune** (low edition chance, and the jokers were temporary anyway) over
  destroying a card (e.g. a King) — and generally undervalues deck-shaping (Hanged Man).
- 🔧 **[R2] For Faceless, kept 2 Jacks while going for straights** (which need only one) — redundant with
  Pareidolia (all cards already face). **Reminder: debuffed cards don't count for Faceless.**

## 7. Skip / blind-select

- 🔧 **[R1] Took the Uncommon-Joker skip tag** with strong scoring + money over the interest cap — a weak
  tag, and skipping forfeits interest + blind money + a whole shop ("free reroll"). Skip less in white stake.
- ✅ **[R1] Correctly took the Investment tag** at $0 with no interest/econ.

## 8. Reroll discipline

- 🔧 **[R2] Rerolled with many good options present** (tarot, packs, voucher), leaving too little money to
  buy them while staying liquid.

## 9. Planets

- 🔧 **[R2] Rarely buys planets** in live play — contradicts the sim, which was buying several. Bought
  Satellite ($/planet) while buying zero planets, so it did nothing.

## 10. Overlay UX

- 🎨 **[R1] Pack size/cost was in small grey text, not the main line**; didn't differentiate small vs medium
  (only "Mega"). [FIXED: main line now shows size + pick + cost]
- 🎨 **[R1] The target card ("apply to which card") should be in the main line, not grey.** [partly done for
  owned/shop tarots]
- 🎨 **[R1] "Discard QH" was ambiguous** between a steel and a standard Queen of Hearts. [FIXED:
  "QH (steel)" vs "QH (plain)"]
- 🎨 **[R2] Still no main-line target text for applying Empress *inside a PACK*** — present for owned
  consumables but not pack picks. [FIXED: pack advisor returns `target_note`; big line shows "Take
  Empress — apply to AS, KS"]
- 🎨 **[R2] Should say "Play blind" at a boss with no skip option** (currently shows nothing). [FIXED:
  blind-select falls back to a CONTINUE "Play blind — the boss can't be skipped." action]

## 11. Method / efficiency questions

- ❓ **[R2] Run Monte-Carlo once the hand is fully drawn, not after every individual card** drawn/played/
  discarded — it recomputes nearly the same thing repeatedly (compute + lag). [valid optimisation]
- ❓ **[R1] Can we just A/B both sides for winrate when changing a constant?** Yes — but autonomous winrate
  is a weak, chaotic signal for subtle/advice changes, so validate each fix with the sharpest measure
  (per-blind scoring, agreement vs the human's actual plays, or the "run both sides" hand check).

## 12. Positives (what it got right)

- ✅ **[R1] Investment tag** at $0 (see §7).
- ✅ **[R2] Kept two pairs to chase three-of-a-kind for Wily** in the first big blind.
- ✅ **[R2] Took Pareidolia for Faceless synergy.**

---

### Fix order being worked (see the session commits / MCTS is unrelated)
1. Joker buy-then-sell churn (§3) · 2. Milk spare resources (§2) · 3. Use held consumables (§4) ·
4. Pack-first ordering + Hermit-cash sequencing (§5) · reroll (§8) · deck-shaping/tarot (§6) · play-spiral
(§1) · 5. UX: "Play blind" + pack-pick target text (§10) · 6. MC-timing (§11).
Fixes done so far: Ankh(0-jokers)+duplicate-value valuation; overlay cost/size/pick + duplicate
disambiguation; per-hand PLAY/DISCARD logging (enables §1/§2 diagnosis); **§3 churn** first-pass
(`SA.TIER_FUNDER_FLOOR` — don't dump a decent joker as a free SELL_TO_BUY funder); **§2 money-dig**
(`DE.DIG_FOR_MONEY` — with Faceless, dig 3+ face cards for the $5 before playing a locked clear).
