extends Node3D
## Staged breach (round 2): YardBuilder.breach(wall, 1.5) thumps three times
## with growing local cracks inside the delay, then opens a body-shaped hole
## from the floor up (the panel is not fully broken) and marks the panel
## &"staged_breach". A Brute-sized capsule fits through the hole.

var _cracks: Array = []
var _breaks: Array = []
var _ok := true

func _ready() -> void:
	var yard := YardBuilder.new()
	add_child(yard)
	yard.build()
	await get_tree().physics_frame
	await get_tree().physics_frame
	GameEvents.wall_cracked.connect(func(w: Node3D, _p: Vector3, _e: float) -> void: _cracks.append([w, TimeDirector.now()]))
	GameEvents.wall_broken.connect(func(w: Node3D, _p: Vector3, _e: float, _v: Vector3) -> void: _breaks.append([w, TimeDirector.now()]))
	var wall: Destructible = null
	for d in yard.get_breach_walls():
		if d.surface == &"drywall" and absf(d.global_position.z - 3.0) < 0.1:
			wall = d
	if wall == null:
		print("[breach] no facade panel found -> FAIL")
		get_tree().quit(1)
		return
	var t0 := TimeDirector.now()
	yard.breach(wall, 1.5)
	var crack_counts: Array[int] = []
	var prev_cracks := 0
	while TimeDirector.now() - t0 < 1.8:
		await get_tree().physics_frame
		var n := wall.get_crack_edge_count()
		if n != prev_cracks:
			crack_counts.append(n)
			prev_cracks = n
	var mine_c := _cracks.filter(func(c: Array) -> bool: return c[0] == wall)
	var mine_b := _breaks.filter(func(b: Array) -> bool: return b[0] == wall)
	var t_break: float = mine_b[0][1] - t0 if mine_b.size() > 0 else -1.0
	var growing := crack_counts.size() >= 2 and crack_counts[1] > crack_counts[0]
	var timing_ok := mine_c.size() == 3 and mine_b.size() == 1 and t_break > 1.35 and t_break < 1.65 \
		and mine_c.all(func(c: Array) -> bool: return c[1] - t0 < t_break)
	print("[breach] thumps=%d (cracks drawn %s) burst at %.2f s staged=%s -> %s" % [
		mine_c.size(), crack_counts, t_break, wall.get_meta(&"staged_breach", false), _pf(timing_ok and growing)])
	_ok = _ok and timing_ok and growing and wall.get_meta(&"staged_breach", false)
	# Body-shaped hole from the floor up; the panel still stands around it.
	var open := true
	for h in [0.25, 1.0, 1.8]:
		if not wall.is_point_open(wall.global_transform * Vector3(0, -1.5 + h, 0)):
			open = false
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.44
	capsule.height = 1.9
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = capsule
	q.collision_mask = Layers.DESTRUCTIBLE | Layers.WORLD
	q.transform = Transform3D(Basis(), Vector3(-12.6, 0.98, 3.0))
	q.motion = Vector3(3.0, 0, 0)
	q.exclude = []
	for n in get_tree().get_nodes_in_group(&"world_static"):
		q.exclude.append((n as CollisionObject3D).get_rid())
	var frac := get_world_3d().direct_space_state.cast_motion(q)
	var hole_ok := open and not wall.is_broken and frac.size() == 2 and frac[0] >= 0.999
	print("[breach] hole open at 0.25/1.0/1.8 m=%s, panel still standing=%s, cells left %d/%d, Brute capsule passes=%s -> %s" % [
		open, not wall.is_broken, wall.get_alive_count(), wall.get_cell_count(), frac, _pf(hole_ok)])
	_ok = _ok and hole_ok
	# Roll door (the Brute's entry) breaches the same way.
	var door := yard.get_roll_door()
	# A crack dents the corrugated door instead of drawing Voronoi cracks.
	door.receive_impact(600.0, door.global_transform * Vector3(0.5, 0.0, 0.06), Vector3(0, 0, -6))
	var dent_ok := door.get_dent_count() == 1 and not door.is_broken and door.get_alive_count() == door.get_cell_count()
	print("[breach] roll door crack at 600 J: dents=%d, intact=%s -> %s" % [door.get_dent_count(),
		door.get_alive_count() == door.get_cell_count(), _pf(dent_ok)])
	_ok = _ok and dent_ok
	yard.breach(door, 1.5)
	await WorldTestUtil.wait_game(self, 1.8)
	var door_ok := door.get_alive_count() < door.get_cell_count() and door.is_point_open(door.global_transform * Vector3(0, -1.0, 0))
	print("[breach] roll door slats left %d/%d, open at 0.5 m=%s -> %s" % [door.get_alive_count(), door.get_cell_count(),
		door.is_point_open(door.global_transform * Vector3(0, -1.0, 0)), _pf(door_ok)])
	_ok = _ok and door_ok
	print("[breach] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _pf(b: bool) -> String:
	return "PASS" if b else "FAIL"
