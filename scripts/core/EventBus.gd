extends Node
## Global signal hub. No logic, no state — systems emit here and UI listens,
## so gameplay code never needs a hard reference to a specific panel or node.

# Inventory & hotbar
signal inventory_changed
signal item_added(id: String, count: int)
signal item_removed(id: String, count: int)
signal hotbar_changed
## Selected hotbar slot (0-based). Emitted once the HUD has a hotbar and on every
## change, so a body that spawned later still learns the current selection.
signal hotbar_selected(index: int)

# Player vitals & progression
signal hp_changed(current: float, max_hp: float)
signal stamina_changed(current: float, max_stamina: float)
signal xp_changed(current: int, needed: int)
signal level_changed(new_level: int)

# Economy & world
signal gold_changed(amount: int)
signal mushroom_gathered(mushroom_id: String, count: int)
signal species_discovered(mushroom_id: String)

# Combat: emitted once per applied hit by the creature that lost HP, so the HUD
# flash follows the damage instead of the swing.
signal enemy_hit(enemy: Node, amount: float, is_crit: bool)

# Crafting, consumables and skills
signal craft_started(recipe_id: String, seconds: float)
signal craft_progress_changed(current: float, total: float)
signal craft_cancelled(recipe_id: String)
signal item_crafted(recipe_id: String, item_id: String, count: int)
signal item_used(item_id: String)
signal skills_changed
signal skill_points_changed(available: int)

# Gathering (HUD progress bar in phase 6 listens here)
signal gather_progress_changed(current: float, total: float)
signal gather_finished(mushroom_id: String)
signal vocation_chosen(vocation_id: String)
signal chat_message_received(sender: String, text: String, channel: String)
signal player_died
signal player_respawned

# Plots & building
signal plot_purchased(plot_id: int)
signal plot_expired(plot_id: int)
signal object_placed(plot_id: int, object_id: String, cell: Vector3i)

# Multiplayer
signal network_started(is_host: bool)
signal player_joined(peer_id: int)
signal player_left(peer_id: int)

# UI
signal interaction_prompt_changed(text: String)
## Short-lived HUD message (plot purchase results, failed build placement).
signal toast_requested(text: String)
