class_name ForestRun
extends RefCounted
## Deterministic layout for one depth layer of the layered RNG forest.
##
## This is pure data: a small graph of clearings and the paths between them.
## `LayeredForest.gd` turns it into ground, mushroom nodes, Spore Blooms, a
## structure and the gates. Keeping generation here means the shape can be
## tested without a scene tree, and every peer derives the same layout from the
## same `(layer, seed)` pair.
##
## Shape: one winding spine from the entry to the exit, plus `2 + layer` side
## branches that end in dead ends. Branch points become junctions, and a few
## spine nodes are promoted to hazards or the one loot structure.

enum Kind { ENTRY, PATH, JUNCTION, DEAD_END, EXIT }

const SPACING := 8.0
const MAX_RADIUS := 11
const DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]
const NO_CELL := Vector2i(9999, 9999)

var layer := 1
var run_seed := 0
## One entry per node: `{id, kind, cell, depth, pos: Vector2, links: Array[int]}`.
var nodes: Array[Dictionary] = []
var entry_id := 0
var exit_id := 0
## Overlays, not structural kinds: a junction can carry a bloom or the structure
## and still be a junction for the path layout.
var hazard_ids: Array[int] = []
var structure_id := -1


## Rebuilds the run for `p_layer` (1-5) and `p_seed`. Same inputs -> same graph.
func generate(p_layer: int, p_seed: int) -> void:
	layer = clampi(p_layer, 1, 5)
	run_seed = p_seed
	nodes.clear()
	hazard_ids.clear()
	structure_id = -1
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed + layer * 7919

	var occupied := {}
	var spine: Array[int] = []
	var cell := Vector2i.ZERO
	var heading := Vector2i(0, 1)
	occupied[cell] = true
	entry_id = _add(Kind.ENTRY, cell, 0)
	spine.append(entry_id)

	# The winding spine. It always trends outward, so the exit ends up far from
	# the entry instead of doubling back into the spawn clearing.
	for depth in range(1, 6 + layer):
		var next := _pick_next(rng, cell, heading, occupied)
		if next == NO_CELL:
			break
		heading = next - cell
		cell = next
		occupied[cell] = true
		var id := _add(Kind.PATH, cell, depth)
		_link(spine[-1], id)
		spine.append(id)

	# Side branches guarantee forks and dead ends regardless of the spine's luck.
	for _branch in 2 + layer:
		if spine.size() < 3:
			break
		var parent := spine[rng.randi_range(1, spine.size() - 2)]
		var from: Vector2i = nodes[parent]["cell"]
		var leaf_cell := _free_neighbour(rng, from, occupied)
		if leaf_cell == NO_CELL:
			continue
		occupied[leaf_cell] = true
		var leaf := _add(Kind.DEAD_END, leaf_cell, int(nodes[parent]["depth"]) + 1)
		_link(parent, leaf)
		# Half the branches run one clearing deeper before they end.
		if rng.randf() < 0.5:
			var deeper := _free_neighbour(rng, leaf_cell, occupied)
			if deeper != NO_CELL:
				occupied[deeper] = true
				var tail := _add(Kind.DEAD_END, deeper, int(nodes[leaf]["depth"]) + 1)
				_link(leaf, tail)

	_classify()

	# The deepest spine node is the way down. Reclassify it before hazards and
	# the structure so neither can steal the exit.
	exit_id = spine[-1]
	nodes[exit_id]["kind"] = Kind.EXIT

	# Overlays are chosen from the spine between the gates, so the entry stays a
	# safe clearing and the exit stays the way down.
	var candidates: Array[int] = []
	for id in spine:
		if id == entry_id or id == exit_id:
			continue
		if int(nodes[id]["depth"]) < 2:
			continue
		candidates.append(id)
	_mark_hazards(rng, candidates)
	_place_structure(candidates)

	# Jitter is cosmetic: a separate stream keeps the graph decisions above
	# independent of it, so changing the jitter never changes the layout.
	var jitter := RandomNumberGenerator.new()
	jitter.seed = p_seed + layer * 131
	for node in nodes:
		var base: Vector2 = Vector2(node["cell"]) * SPACING
		node["pos"] = base + Vector2(
			jitter.randf_range(-1.2, 1.2), jitter.randf_range(-1.2, 1.2)
		)


## Node dictionary by id.
func node(id: int) -> Dictionary:
	return nodes[id]


func kind_of(id: int) -> int:
	return int(nodes[id]["kind"])


func position_of(id: int) -> Vector2:
	return nodes[id]["pos"]


func ids_of_kind(kind: Kind) -> Array[int]:
	var found: Array[int] = []
	for node in nodes:
		if int(node["kind"]) == kind:
			found.append(int(node["id"]))
	return found


## Every id reachable from the entry (a connected graph should hold them all).
func reachable_ids() -> Array[int]:
	var seen := {}
	var queue: Array[int] = [entry_id]
	seen[entry_id] = true
	while not queue.is_empty():
		var id: int = queue.pop_front()
		for other: int in nodes[id]["links"]:
			if seen.has(other):
				continue
			seen[other] = true
			queue.append(other)
	var result: Array[int] = []
	for id: int in seen:
		result.append(id)
	return result


func _add(kind: Kind, cell: Vector2i, depth: int) -> int:
	var id := nodes.size()
	nodes.append({
		"id": id,
		"kind": kind,
		"cell": cell,
		"depth": depth,
		"pos": Vector2(cell) * SPACING,
		"links": [] as Array[int],
	})
	return id


func _link(a: int, b: int) -> void:
	var a_links: Array = nodes[a]["links"]
	var b_links: Array = nodes[b]["links"]
	a_links.append(b)
	b_links.append(a)


## Weighted walk: keep going straight most of the time, then turn, never step
## back onto the previous cell and never leave the radius.
func _pick_next(
	rng: RandomNumberGenerator,
	cell: Vector2i,
	heading: Vector2i,
	occupied: Dictionary
) -> Vector2i:
	var options: Array[Vector2i] = []
	if heading != Vector2i.ZERO and not occupied.has(cell + heading):
		options.append(heading)
		options.append(heading)
	for direction in DIRECTIONS:
		if direction == heading or direction == -heading:
			continue
		var candidate := cell + direction
		if absi(candidate.x) > MAX_RADIUS or absi(candidate.y) > MAX_RADIUS:
			continue
		if occupied.has(candidate):
			continue
		options.append(direction)
	if options.is_empty():
		return NO_CELL
	var choice := options[rng.randi_range(0, options.size() - 1)]
	var candidate := cell + choice
	if absi(candidate.x) > MAX_RADIUS or absi(candidate.y) > MAX_RADIUS:
		return NO_CELL
	return candidate


func _free_neighbour(rng: RandomNumberGenerator, cell: Vector2i, occupied: Dictionary) -> Vector2i:
	var options: Array[Vector2i] = []
	for direction in DIRECTIONS:
		var candidate := cell + direction
		if absi(candidate.x) > MAX_RADIUS or absi(candidate.y) > MAX_RADIUS:
			continue
		if occupied.has(candidate):
			continue
		options.append(candidate)
	if options.is_empty():
		return NO_CELL
	return options[rng.randi_range(0, options.size() - 1)]


## Degree decides the base kind: 1 = dead end, 3+ = junction. Entry and exit are
## pinned afterwards by the caller.
func _classify() -> void:
	for node in nodes:
		var degree: int = (node["links"] as Array).size()
		if int(node["kind"]) == Kind.ENTRY:
			continue
		if degree <= 1:
			node["kind"] = Kind.DEAD_END
		elif degree >= 3:
			node["kind"] = Kind.JUNCTION
		else:
			node["kind"] = Kind.PATH


## `2 + layer` blooms, kept off the entry and the exit and spread apart so one
## cloud cannot cover two of them.
func _mark_hazards(rng: RandomNumberGenerator, candidates: Array[int]) -> void:
	var pool: Array[int] = []
	for id in candidates:
		# Two cells out is at least 16 m, so a bloom can never sit in the 12 m
		# spawn clearing even when the spine curves back toward the entry.
		if Vector2(nodes[id]["cell"]).length() < 2.0:
			continue
		pool.append(id)
	var count := mini(2 + layer, pool.size())
	for _index in count:
		if pool.is_empty():
			break
		var pick := pool[rng.randi_range(0, pool.size() - 1)]
		pool.erase(pick)
		hazard_ids.append(pick)


## One structure per run, roughly halfway along the spine and never on a hazard.
func _place_structure(candidates: Array[int]) -> void:
	var middle := candidates.size() / 2
	for offset in candidates.size():
		var index := (middle + offset) % candidates.size()
		var id := candidates[index]
		if hazard_ids.has(id):
			continue
		structure_id = id
		return
