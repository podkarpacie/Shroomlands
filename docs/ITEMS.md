# Mycelia — Item & Mushroom Design

Single source of truth for item identity. Code data lives in `scripts/core/Lore.gd`;
this file explains *intent*, so it can be reviewed without reading GDScript.

Names stay short and unexplained in-game — the player learns what they do by using them,
reading a found note, or asking the Alchemist. Nothing here is spelled out in the UI.

---

## 1. Rarity

| Tier | Colour | Meaning | Where it grows |
| --- | --- | --- | --- |
| `common` | pale bone `#cfd8d0` | everyday, replaceable | Layer 1 |
| `rare` | cold blue `#4a86c8` | worth a trip | Layer 2-3 |
| `epic` | violet `#a25bd0` | the reason to go deeper | Layer 3-4 |
| `legendary` | ember gold `#e08a2e` | one per expedition, if you're lucky | Layer 4-5 |

Rarity drives: name colour in inventory, drop weight, regrow time, and how loudly the
pickup plays. Rarity does **not** mean "safer" — Fury is legendary and will hurt you raw.

---

## 2. Depth layers (the forest)

The town sits at the edge. The forest is layered and each layer is a separate roll:
stronger spawns, better mushrooms, darker light, longer paths back.

| Layer | Name | Level band | Grows | Danger |
| --- | --- | --- | --- | --- |
| 1 | The Shallows | 1-10 | Konop, Shitake, Motoko | sparring enemies, teaching traps |
| 2 | The Thicket | 10-22 | Borowik, Kazar, Kora, Altak | packs, first toxic blooms |
| 3 | The Rotting Hollow | 22-35 | Bedak, Altak, Pesta, Celtus | spore clouds, ambush |
| 4 | The Gloomroot | 35-50 | Altak, Pesta, Celtus, Fury | low light, elites |
| 5 | The Pale Depths | 50+ | Fury | legendary spawns, raids |

The per-mushroom `Layers` column in §3 is authoritative; this table is derived from it.
(Konop is universal and can appear in any layer at low weight.)

**Rules of thumb**
- A mushroom only grows in its listed layers; deeper layers roll the *same* species more
  often at higher yield, which is why they stay valuable.
- Konop grows in every layer at low weight — it is the universal tutorial mushroom.
- RNG forest: layered path graph. Each node is one of — safe path · fork · dead end ·
  hazard (toxic bloom / snare) · structure (house, mini-castle, dungeon) with loot & enemies.
  Deeper nodes have better loot tables and worse encounters.

---

## 3. Mushrooms

Eat = what happens if you consume it raw (fast, free, weaker).
Brew = what the Alchemy Table turns it into (needs the mushroom + a small gold fee).
Tox = toxicity. Above 0 it costs HP when eaten raw; the Alchemist can process it safely.

| # | Name | Rarity | Layers | Eat (raw) | Brewed at Alchemy Table | Tox | Regrow |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | **Konop** | common | all | +15 HP | **Konop Draught** — +45 HP | 0 | 30 s |
| 2 | **Shitake** | common | 1-2 | +10 HP, +5 stamina | **Hearty Stew** — +30 HP over 10 s | 0 | 40 s |
| 3 | **Motoko** | common | 1-2 | +20 stamina | **Spore Tonic** — +50 stamina | 0 | 40 s |
| 4 | **Borowik** | rare | 2-3 | +25 max HP for 120 s | **Ironblood Tonic** — +50 max HP for 180 s | 0 | 90 s |
| 5 | **Kazar** | rare | 2-3 | 8 damage to self | **Weapon Oil** — +20 % damage for 90 s | 2 | 90 s |
| 6 | **Kora** | rare | 2-3 | nausea, no benefit | **Armour Patch** — repairs 40 % of equipped armour | 1 | 120 s |
| 7 | **Altak** | rare | 2-4 | blurred vision 20 s | **Nighteye Draught** — see in the dark 180 s | 2 | 120 s |
| 8 | **Bedak** | rare | 2-3 | poison, 10 dmg over 8 s | **Spore Bomb** — thrown, 3 m toxic cloud | 4 | 120 s |
| 9 | **Celtus** | epic | 3-4 | +60 HP, clears poison | **Elixir of Renewal** — full heal, cleanse | 0 | 240 s |
| 10 | **Pesta** | epic | 3-4 | poison, 15 dmg over 10 s | **Blight Flask** — enemies deal −30 % for 15 s | 6 | 240 s |
| 11 | **Fury** | legendary | 4-5 | 20 damage to self, then rage | **Fury Draught** — +50 % damage, −30 % armour, 20 s | 5 | 600 s |

### Why each one exists

- **Konop** — the tutorial. Universal (all vocations), safe, fast regrow, grows everywhere.
  Raw = small heal; brewed = real heal. It teaches the eat-vs-brew tradeoff without punishing.
- **Shitake** — first cooking ingredient; teaches slow healing (over time) vs instant.
- **Motoko** — the stamina answer, so sprinting and heavy swings stop being a trap.
- **Borowik** — the Knight's friend: temporary max HP, not a heal. Encourages pre-fight prep.
- **Kazar** — the damage mushroom. Raw it punishes you; processed it is the best early buff.
  This is the first "respect the alchemist" lesson.
- **Kora** — the Harvester's economy: armour repair without a smith. Useless to eat.
- **Altak** — vision. Deeper layers get dark; without it you fight blind. Raw it blinds you.
- **Bedak** — ranged crowd control from a mushroom. Also the tutorial for throwables.
- **Celtus** — the panic button: big instant heal + cleanse. Epic because it trivialises
  poison layers if it were common.
- **Pesta** — offensive debuff and the antidote base. High toxicity, so it can only be
  handled by someone with alchemy.
- **Fury** — legendary risk/reward: it hurts you to hold, and the draught makes you hit
  harder but take more. Endgame flavour, not a stat stick.

---

## 4. Potions (Alchemy Table output)

Potion = mushroom + gold fee, made at an **Alchemy Table** (town vendor, or placed on your
own plot). One item id each, so inventory/UI needs no special cases.

| Potion | From | Effect | Fee |
| --- | --- | --- | --- |
| Konop Draught | Konop ×1 | +45 HP | 5 g |
| Hearty Stew | Shitake ×1 | +30 HP over 10 s | 5 g |
| Spore Tonic | Motoko ×1 | +50 stamina | 5 g |
| Ironblood Tonic | Borowik ×1 | +50 max HP, 180 s | 15 g |
| Weapon Oil | Kazar ×1 | +20 % damage, 90 s | 15 g |
| Armour Patch | Kora ×1 | repair equipped armour | 15 g |
| Nighteye Draught | Altak ×1 | vision in darkness, 180 s | 15 g |
| Spore Bomb | Bedak ×1 | throwable, 3 m toxic cloud | 20 g |
| Elixir of Renewal | Celtus ×1 | full heal + cleanse | 40 g |
| Blight Flask | Pesta ×1 | −30 % enemy damage, 15 s | 30 g |
| Fury Draught | Fury ×1 | +50 % damage, −30 % armour, 20 s | 60 g |

---

## 5. Hazards (not loot)

**Spore Bloom** — a fat, veined mushroom that never drops anything. When the player comes
within ~2.5 m it swells for 0.6 s and bursts into a toxic cloud (3 m radius, damage per
tick, 6 s). Destroyable at range before it bursts. Deeper layers place them on narrow path
segments so they punish careless running.

---

## 6. Effect system the code needs

Two kinds, both on `PlayerStats`:

- **Instant** — heal, stamina, self-damage, cleanse. Applied once.
- **Timed buff** — `{id, duration, modifiers}` where modifiers may include
  `max_hp_flat`, `max_stamina_flat`, `damage_mult`, `armor_mult`, `vision`, `speed_mult`.
  Stacks refresh, do not stack additively. One HUD row shows active buffs with a countdown.

Poison is a timed damage-over-time with its own icon and no stacking beyond refresh.

---

## 7. What this implies for the build (ordered)

1. Replace the six placeholder mushrooms with these eleven in `Lore.gd` (rarity, layer,
   effects, brew recipe, regrow). Update every consumer: harvest nodes, item icons,
   held-item hand model, tests.
2. Effect system (instant + timed buffs + poison) and the HUD buff row.
3. Eating: right-click / hotbar use applies the raw effect. Alchemy Table object +
   crafting panel applies the brew recipe for gold.
4. Eleven unique blocky mushroom models with their own textures, one per species.
5. Depth layers, RNG path graph, hazard Spore Blooms, then the town (shop, alchemy,
   repair, plot access) as the hub.
