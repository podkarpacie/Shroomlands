extends SceneTree
## Pure-data checks for `ForestRun`: deterministic output, a connected graph,
## an entry/exit pair, guaranteed forks, dead ends, hazards and one structure.

const ForestRun := preload("res://scripts/world/ForestRun.gd")
const SEED := 20261106

var _failures := 0


func _initialize() -> void:
	for layer in range(1, 6):
		_check_layer(layer)
	_check_determinism()
	_check_variation()
	_finish()


func _check_layer(layer: int) -> void:
	var run = ForestRun.new()
	run.generate(layer, SEED)
	var count: int = run.nodes.size()
	_check("layer %d has a run (%d nodes)" % [layer, count], count >= 4)
	_check("layer %d entry exists" % layer, run.entry_id >= 0 and run.entry_id < count)
	_check("layer %d exit exists" % layer, run.exit_id >= 0 and run.exit_id < count)
	_check("layer %d exit is not the entry" % layer, run.exit_id != run.entry_id)
	if run.exit_id == run.entry_id:
		return
	_check("layer %d entry kind" % layer, run.kind_of(run.entry_id) == ForestRun.Kind.ENTRY)
	_check("layer %d exit kind" % layer, run.kind_of(run.exit_id) == ForestRun.Kind.EXIT)

	var reachable: Array = run.reachable_ids()
	_check(
		"layer %d is fully connected (%d/%d)" % [layer, reachable.size(), count],
		reachable.size() == count
	)

	var junctions: Array = run.ids_of_kind(ForestRun.Kind.JUNCTION)
	var dead_ends: Array = run.ids_of_kind(ForestRun.Kind.DEAD_END)
	var hazards: Array = run.hazard_ids
	_check("layer %d has at least 2 forks (%d)" % [layer, junctions.size()], junctions.size() >= 2)
	_check("layer %d has at least 2 dead ends (%d)" % [layer, dead_ends.size()], dead_ends.size() >= 2)
	_check("layer %d has hazards (%d)" % [layer, hazards.size()], hazards.size() >= 2)
	_check("layer %d has exactly one structure (%d)" % [layer, run.structure_id],
		run.structure_id >= 0 and not hazards.has(run.structure_id))

	# The exit must be the deepest spine node: otherwise "deeper layers" would
	# walk back toward the entrance.
	var deepest := 0
	for node in run.nodes:
		deepest = maxi(deepest, int(node["depth"]))
	_check(
		"layer %d exit is the deepest node (%d of %d)" % [layer, int(run.node(run.exit_id)["depth"]), deepest],
		int(run.node(run.exit_id)["depth"]) == deepest
	)


func _check_determinism() -> void:
	var a = ForestRun.new()
	var b = ForestRun.new()
	a.generate(3, 777)
	b.generate(3, 777)
	var same: bool = a.nodes.size() == b.nodes.size() and a.exit_id == b.exit_id
	if same:
		for index in a.nodes.size():
			if int(a.nodes[index]["kind"]) != int(b.nodes[index]["kind"]):
				same = false
				break
			if not a.nodes[index]["pos"].is_equal_approx(b.nodes[index]["pos"]):
				same = false
				break
	_check("the same (layer, seed) reproduces the same graph", same)


func _check_variation() -> void:
	var one = ForestRun.new()
	var two = ForestRun.new()
	one.generate(1, 100)
	two.generate(1, 200)
	var differs: bool = one.nodes.size() != two.nodes.size()
	if not differs:
		for index in mini(one.nodes.size(), two.nodes.size()):
			if not one.nodes[index]["pos"].is_equal_approx(two.nodes[index]["pos"]):
				differs = true
				break
	_check("a different seed produces a different run", differs)


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all forest run assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
