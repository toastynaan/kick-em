extends Node
## Round 6 (more destruction): enemy navigation through the Yard's clutter and
## structure (docs/ARCHITECTURE.md, Round 6). In the real Yard with K's clutter
## and D's structure:
## A. Spawns and entries are never blocked: every spawn point and entry-path
##    point is walkable on the nav grid, a body-sized sweep passes along every
##    entry path, and the grid has a complete path from each entry's end to the
##    courtyard centre and the player spawn (any blocked one is printed with
##    its position). A body pressed against any clutter object (its own grid
##    cell solid) starts its path on its own side: the first path point is in
##    sight over the furniture, never through a wall.
## B. Enemies reach the player from every spawn through the clutter: one grunt
##    per spawn walks its entry path and joins the fight (within the ring with
##    a clear line to the player, or attacking) for each of three player spots
##    (the player spawn and two spots in the densest clutter), then one heavy
##    per spawn (the widest body: it plans on the grid's wide layer) to the
##    player spawn; the longest stuck time (wanting to move, barely moving) is
##    logged and must stay under MAX_STUCK.
## C. The grid follows the world: a broken clutter object, a rigid prop shoved
##    away and a snapped pillar's collapse all reach the grid (cells match a
##    direct test), and glass shards / a cracked pillar's beam are hazards
##    waiting enemies keep out of.
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const REACH_LIMIT := 30.0        ## s for every grunt to join the fight from its spawn
const MAX_STUCK := 3.0           ## s (Round 6 acceptance)
const CLEAR_RADIUS := 0.24       ## m: AIBrain.CLEAR_RADIUS (a body's sweep)

var failures := 0
var yard: Node3D
var player: Fighter
var sweep := PhysicsShapeQueryParameters3D.new()
var cell_q := PhysicsShapeQueryParameters3D.new()

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	Tuning.difficulty = Tuning.Difficulty.NORMAL
	yard = Util.build_yard(self)
	if yard == null:
		print("[ai] BLOCKED: YardBuilder built nothing")
		_finish()
		return
	var cap := CapsuleShape3D.new()
	cap.radius = CLEAR_RADIUS
	cap.height = AIBrain.CLEAR_HEIGHT
	sweep.shape = cap
	sweep.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
	var cell := CapsuleShape3D.new()
	cell.radius = AINavGrid.BODY_RADIUS
	cell.height = AINavGrid.BODY_HEIGHT
	cell_q.shape = cell
	cell_q.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
	for i in 3:
		await get_tree().physics_frame
	var ps: Transform3D = yard.get_player_spawn()
	player = FighterFactory.spawn_dummy(self, &"player", ps, Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	print("[ai] info: clutter %d objects, breakables %d, pillars %d" % [get_tree().get_nodes_in_group(&"clutter").size(),
		get_tree().get_nodes_in_group(&"breakables").size(), get_tree().get_nodes_in_group(&"pillars").size()])
	var nav := _fresh_grid()
	_part_spawns(nav)
	await _part_reach()
	await _part_refresh()
	_finish()

func _fresh_grid() -> AINavGrid:
	var nav := AINavGrid.new()
	nav.start_build(get_viewport().get_world_3d().direct_space_state)
	while not nav.step_build():
		pass
	return nav

# --- A. Spawns and entries --------------------------------------------------------------

func _part_spawns(nav: AINavGrid) -> void:
	var centre: Vector3 = yard.get_courtyard_bounds().get_center()
	centre.y = 0.0
	var pspawn: Vector3 = yard.get_player_spawn().origin
	var blocked: Array[String] = []
	var rows: Array[String] = []
	var i := 0
	for e: Dictionary in yard.get_enemy_spawns():
		var pos: Vector3 = e.get("position", Vector3.ZERO)
		var pts := PackedVector3Array([pos])
		pts.append_array(e.get("path", PackedVector3Array()))
		var min_clear := INF
		for k in pts.size():
			if not nav.is_walkable(pts[k]):
				blocked.append("spawn %d point %d %s not walkable" % [i, k, pts[k].snapped(Vector3.ONE * 0.1)])
			min_clear = minf(min_clear, _clutter_dist(pts[k]))
			if k > 0 and not _sweep_clear(pts[k - 1], pts[k]):
				blocked.append("spawn %d entry %s -> %s blocked" % [i, pts[k - 1].snapped(Vector3.ONE * 0.1), pts[k].snapped(Vector3.ONE * 0.1)])
			if k > 0:
				for t in 8:
					min_clear = minf(min_clear, _clutter_dist(pts[k - 1].lerp(pts[k], t / 8.0)))
		var last := pts[pts.size() - 1]
		var lens := []
		for goal in [centre, pspawn]:
			var p := nav.find_path(last, goal)
			if not nav.last_path_complete:
				blocked.append("spawn %d: no complete grid path from %s to %s" % [i, last.snapped(Vector3.ONE * 0.1), goal.snapped(Vector3.ONE * 0.1)])
			lens.append("%.1f" % AINavGrid.path_length(last, p))
		rows.append("spawn %d %s: path to centre / player spawn %s m, nearest clutter %.1f m" % [i, pos.snapped(Vector3.ONE * 0.1), " / ".join(lens), min_clear])
		i += 1
	for r in rows:
		print("[ai] info: " + r)
	for b in blocked:
		print("[ai] BLOCKED: " + b)
	check(i >= 1 and blocked.is_empty(), "every spawn and entry is clear of clutter and reaches the courtyard (%d spawns, %d blocked)" % [i, blocked.size()])
	# Pressed against clutter: the path never starts through a wall.
	var tried := 0
	var through := 0
	for c in get_tree().get_nodes_in_group(&"clutter"):
		var n := c as CollisionObject3D
		if n == null or n.collision_layer == 0:
			continue
		for dir: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
			var at := Vector3(n.global_position.x, 0.0, n.global_position.z) + dir * 0.45
			if nav.is_walkable(at):
				continue  # only bodies standing in a solid cell matter here
			tried += 1
			var p := nav.find_path(at, centre)
			if not p.is_empty() and not nav._sees(at, p[0]):
				through += 1
				print("[ai] info: path from %s starts through a wall at %s" % [at.snapped(Vector3.ONE * 0.1), p[0].snapped(Vector3.ONE * 0.1)])
	check(through == 0, "a body pressed against clutter starts its path on its own side (%d spots in solid cells, %d through a wall)" % [tried, through])

func _clutter_dist(p: Vector3) -> float:
	var best := INF
	for c in get_tree().get_nodes_in_group(&"clutter"):
		var n := c as CollisionObject3D
		if n == null or n.collision_layer == 0:
			continue
		best = minf(best, Util.flat_dist(n.global_position, p))
	return best

func _sweep_clear(a: Vector3, b: Vector3) -> bool:
	var space := get_viewport().get_world_3d().direct_space_state
	sweep.transform = Transform3D(Basis(), Vector3(a.x, a.y + AIBrain.CLEAR_CENTER, a.z))
	sweep.motion = Vector3(b.x - a.x, 0.0, b.z - a.z)
	if sweep.motion.length() < 0.01:
		return true
	var r := space.cast_motion(sweep)
	return r.size() == 0 or r[0] >= 1.0

func _direct_walkable(p: Vector3) -> bool:
	var space := get_viewport().get_world_3d().direct_space_state
	cell_q.transform = Transform3D(Basis(), Vector3(p.x, AINavGrid.FLOOR_Y + AINavGrid.BODY_CENTER, p.z))
	return space.intersect_shape(cell_q, 1).is_empty()

# --- B. Reach the player from every spawn -----------------------------------------------

func _part_reach() -> void:
	var spots: Array[Vector3] = [yard.get_player_spawn().origin]
	spots.append_array(_clutter_spots(2))
	var archs: Array[StringName] = [&"grunt", &"grunt", &"grunt", &"heavy"]
	spots.append(yard.get_player_spawn().origin)
	var worst_stuck := 0.0
	var worst_at := ""
	var all_ok := true
	for si in spots.size():
		var spot := spots[si]
		var arch: StringName = archs[si]
		player.global_position = spot + Vector3(0, 0.05, 0)
		player.reset_physics_interpolation()
		AttackDirector.reset()
		AttackDirector.set_player(player)
		var grunts: Array[Fighter] = []
		var reached := {}
		for e: Dictionary in yard.get_enemy_spawns():
			var g := FighterFactory.spawn_enemy(self, arch, Transform3D(Basis(), e.get("position", Vector3.ZERO)),
				e.get("path", PackedVector3Array()))
			grunts.append(g)
			(g.brain as AIBrain).attack_launched.connect(func(_m: StringName) -> void:
				if not reached.has(g): reached[g] = Util.game_now())
		var t0 := Util.game_now()
		while Util.game_now() - t0 < REACH_LIMIT and reached.size() < grunts.size():
			await get_tree().physics_frame
			_keep_player(spot)
			for g in grunts:
				if reached.has(g) or not is_instance_valid(g):
					continue
				var d := Util.flat_dist(g.get_ground_position(), player.get_ground_position())
				if d <= Tuning.CIRCLE_RING.y + 0.5 and _sweep_clear(g.get_ground_position(), player.get_ground_position()):
					reached[g] = Util.game_now()
		var times: Array[String] = []
		var ok := true
		for g in grunts:
			var b := g.brain as AIBrain
			if b.max_stuck_time > worst_stuck:
				worst_stuck = b.max_stuck_time
				worst_at = "spot %d, %s at %s" % [si, arch, b.max_stuck_at.snapped(Vector3.ONE * 0.1)]
			if reached.has(g):
				times.append("%.1f" % (float(reached[g]) - t0))
			else:
				ok = false
				times.append("never (at %s, %s)" % [g.get_ground_position().snapped(Vector3.ONE * 0.1), b.get_debug_text().substr(0, 90)])
		print("[ai] info: player at %s: one %s from each of %d spawns joined the fight after %s s" % [spot.snapped(Vector3.ONE * 0.1), arch, grunts.size(), ", ".join(times)])
		all_ok = all_ok and ok
		for g in grunts:
			g.queue_free()
		await get_tree().physics_frame
		await get_tree().physics_frame
	check(all_ok, "from every spawn, enemies reach the player through the clutter (grunts to 3 player spots, heavies to the spawn, %.0f s limit)" % REACH_LIMIT)
	print("[ai] info: longest stuck time %.2f s (%s)" % [worst_stuck, worst_at if worst_at != "" else "-"])
	check(worst_stuck <= MAX_STUCK, "no enemy stuck for more than %.0f s (longest %.2f s)" % [MAX_STUCK, worst_stuck])

## `n` player spots in the densest clutter: next to the clutter object with the
## most clutter within 3 m, 1.4 m toward the courtyard centre, on a walkable cell.
func _clutter_spots(n: int) -> Array[Vector3]:
	var nav := _fresh_grid()
	var ranked: Array = []
	var all := get_tree().get_nodes_in_group(&"clutter")
	for c in all:
		var a := (c as Node3D).global_position
		var k := 0
		for o in all:
			if o != c and Util.flat_dist(a, (o as Node3D).global_position) < 3.0:
				k += 1
		ranked.append([k, a])
	ranked.sort_custom(func(x: Array, y: Array) -> bool: return x[0] > y[0])
	var out: Array[Vector3] = []
	for r: Array in ranked:
		var a: Vector3 = r[1]
		var to_c := Vector3(-a.x, 0.0, -a.z).normalized()
		for dist: float in [1.4, 2.0, 2.6]:
			var p := Vector3(a.x, 0.0, a.z) + to_c * dist
			var far := true
			for q in out:
				far = far and Util.flat_dist(p, q) > 5.0
			if far and nav.is_walkable(p) and _direct_walkable(p):
				out.append(p)
				break
		if out.size() >= n:
			break
	return out

func _keep_player(at: Vector3) -> void:
	if "invuln_until" in player:
		player.set(&"invuln_until", TimeDirector.now() + 5.0)
	if player.hp < player.max_hp * 0.5:
		player.heal_fraction(1.0)
	if Util.flat_dist(player.get_ground_position(), at) > 0.4 and not player.is_down():
		player.global_position = at + Vector3(0, 0.05, 0)
		player.reset_physics_interpolation()

# --- C. The grid follows the world --------------------------------------------------------

func _part_refresh() -> void:
	AttackDirector.reset()
	AttackDirector.set_player(player)
	# A brainless dummy registers so the director builds its grid.
	var dummy := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis(), yard.get_player_spawn().origin + Vector3(3, 0.05, 0)))
	AttackDirector.register_enemy(dummy)
	var t0 := Util.game_now()
	while not AttackDirector.nav_ready() and Util.game_now() - t0 < 5.0:
		await get_tree().physics_frame
	var nav := AttackDirector.nav
	check(nav != null and nav.ready, "the director's grid is built")
	if nav == null:
		return
	# 1. Break the biggest static clutter object.
	var target: Node3D = null
	var best_size := 0.0
	for c in get_tree().get_nodes_in_group(&"clutter"):
		var f := c as StaticBody3D
		if f == null or f.collision_layer == 0 or not f.has_method(&"receive_impact"):
			continue
		var cells := 0
		for dx in [-0.4, 0.0, 0.4]:
			for dz in [-0.4, 0.0, 0.4]:
				if not nav.is_walkable(f.global_position + Vector3(dx, 0, dz)):
					cells += 1
		if cells > best_size:
			best_size = cells
			target = f
	if target != null:
		var at := target.global_position
		var solid_before := _solid_cells(nav, at, 0.8)
		var res: StringName = target.receive_impact(1.0e6, at + Vector3(0, 0.5, 0), Vector3(8, 0, 0))
		await _wait(0.6)
		var solid_after := _solid_cells(nav, at, 0.8)
		var mism := _mismatches(nav, at, 1.6)
		print("[ai] info: broke a %s at %s (%s): solid cells round it %d -> %d" % [target.get(&"kind"), at.snapped(Vector3.ONE * 0.1), res, solid_before, solid_after])
		check(solid_after < solid_before and mism == 0, "a broken clutter object opens its cells on the grid (%d -> %d, %d cells differ from a direct test)" % [solid_before, solid_after, mism])
	# 2. Shove a rigid prop on Layers.DESTRUCTIBLE.
	var prop: RigidBody3D = null
	for c in get_tree().get_nodes_in_group(&"breakables"):
		var rb := c as RigidBody3D
		if rb != null and (rb.collision_layer & Layers.DESTRUCTIBLE) != 0 and not nav.is_walkable(rb.global_position):
			prop = rb
			break
	if prop != null:
		var from := prop.global_position
		var to := from + Vector3(1.5, 0, 0) if nav.is_walkable(from + Vector3(1.5, 0, 0)) else from + Vector3(-1.5, 0, 0)
		prop.freeze = true
		prop.global_position = Vector3(to.x, from.y, to.z)
		prop.reset_physics_interpolation()
		await _wait(1.4)
		var mism := _mismatches(nav, from, 1.0) + _mismatches(nav, to, 1.0)
		print("[ai] info: shoved a %s %s -> %s: old cell walkable %s, new cell walkable %s" % [prop.name, from.snapped(Vector3.ONE * 0.1),
			to.snapped(Vector3.ONE * 0.1), nav.is_walkable(from), nav.is_walkable(to)])
		check(mism == 0, "a shoved rigid prop's old and new cells are re-tested (%d cells differ)" % mism)
		prop.freeze = false
	else:
		print("[ai] info: no rigid prop on Layers.DESTRUCTIBLE blocks a cell: shove check skipped")
	# 3. Snap a pillar: its collapse reaches the grid; cracked first, its beam is a hazard.
	var pillar: Node3D = null
	for p in get_tree().get_nodes_in_group(&"pillars"):
		if not bool(p.get(&"is_broken")):
			pillar = p
			break
	if pillar != null:
		var pc := pillar.global_position
		var crack_e: float = pillar.call(&"get_crack_threshold") * 1.05 if pillar.has_method(&"get_crack_threshold") else 9000.0
		pillar.receive_impact(crack_e, pc + Vector3(0, 1.0, 0), Vector3(10, 0, 0))
		await _wait(0.7)
		var head := pillar.get(&"head") as Node3D
		var hz := head != null and is_instance_valid(head) and AttackDirector.is_hazard(head.global_position)
		print("[ai] info: pillar at %s cracked %s; hazards (glass, beams) %s" % [pc.snapped(Vector3.ONE * 0.1), pillar.get(&"is_cracked"), str(AttackDirector.get_hazard_counts())])
		check(not bool(pillar.get(&"is_cracked")) or hz, "under a cracked pillar's beam is a hazard waiting enemies keep out of")
		if hz:
			var ring_goal := Vector3(head.global_position.x, 0.0, head.global_position.z)
			var moved := AttackDirector.avoid_hazards(ring_goal, yard.get_player_spawn().origin)
			check(not AttackDirector.is_hazard(moved), "a ring spot under the beam moves out of it (%.1f m)" % Util.flat_dist(moved, ring_goal))
		var collapsed := [false]
		var cb := func(_n: Node3D, _p: Vector3, _k: StringName) -> void: collapsed[0] = true
		GameEvents.structure_collapsed.connect(cb)
		for k in 4:
			if bool(pillar.get(&"is_broken")):
				break
			pillar.receive_impact(1.0e6, pc + Vector3(0, 1.0, 0), Vector3(18, 0, 0))
			await _wait(0.2)
		await _wait(AttackDirector.COLLAPSE_AGAIN + 1.0)
		GameEvents.structure_collapsed.disconnect(cb)
		var mism := _mismatches(nav, pc, AttackDirector.COLLAPSE_RADIUS)
		print("[ai] info: pillar snapped %s, structure_collapsed %s" % [pillar.get(&"is_broken"), collapsed[0]])
		check(not collapsed[0] or mism == 0, "a collapse reaches the grid once its pieces are down (%d cells differ round the pillar)" % mism)
	# 4. Broken glass is a hazard.
	var glass: Node3D = null
	for c in get_tree().get_nodes_in_group(&"clutter"):
		if c.get(&"kind") == &"glass" and not bool(c.get(&"is_broken")):
			glass = c
			break
	if glass != null:
		var gp := glass.global_position
		glass.receive_impact(1.0e5, gp + Vector3(0, 1.0, 0), Vector3(6, 0, 0))
		await _wait(0.2)
		check(AttackDirector.is_hazard(gp), "the floor where glass broke is a hazard (shards)")
	dummy.queue_free()

func _solid_cells(nav: AINavGrid, at: Vector3, r: float) -> int:
	var n := 0
	var c := nav.cell_of(at)
	var k := int(ceil(r / AINavGrid.CELL))
	for j in range(c.y - k, c.y + k + 1):
		for i in range(c.x - k, c.x + k + 1):
			var p := nav.cell_center(Vector2i(i, j))
			if Util.flat_dist(p, at) <= r and not nav.is_walkable(p):
				n += 1
	return n

## Cells within `r` of `at` whose grid state differs from a direct test now.
func _mismatches(nav: AINavGrid, at: Vector3, r: float) -> int:
	var n := 0
	var c := nav.cell_of(at)
	var k := int(ceil(r / AINavGrid.CELL))
	for j in range(c.y - k, c.y + k + 1):
		for i in range(c.x - k, c.x + k + 1):
			var p := nav.cell_center(Vector2i(i, j))
			if Util.flat_dist(p, at) <= r and nav.is_walkable(p) != _direct_walkable(p):
				n += 1
	return n

func _wait(s: float) -> void:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < s:
		await get_tree().physics_frame

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_clutter_nav: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
