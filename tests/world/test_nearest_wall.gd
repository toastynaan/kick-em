extends Node3D
## ImpactResolver.nearest_wall_dir (upgrade 2, juggles flatten toward it): in
## the Yard, the unit XZ direction to the nearest wall or pillar face; ZERO
## when none is within max_dist; props are skipped; a hole in a panel does not
## hide the wall plane; cheap enough for every juggle hit.

var _ok := true

func _ready() -> void:
	var yard := YardBuilder.new()
	add_child(yard)
	yard.build()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_case("2 m from the west offices", Vector3(-9.0, 1.0, 0.0), 8.0, Vector3(-1, 0, 0))
	_case("2.5 m from the north garage", Vector3(2.0, 1.0, -8.5), 8.0, Vector3(0, 0, -1))
	_case("beside the pillar at (6, 6)", Vector3(4.8, 1.0, 6.0), 8.0, Vector3(1, 0, 0))
	_case("courtyard centre, max 5 m", Vector3(0.0, 1.0, 0.0), 5.0, Vector3.ZERO)
	_case("south strip", Vector3(-3.0, 1.0, 9.0), 8.0, Vector3(0, 0, 1))
	# A hole in the facade straight ahead does not hide the wall plane.
	for d in yard.get_destructibles():
		if d.kind == &"panel" and d.global_position.distance_to(Vector3(-11.125, 1.5, 0.0)) < 0.1:
			d.break_hole(d.global_position, Vector3(-8, 0, 0), Rect2(-0.6, -1.5, 1.2, 2.2))
	await get_tree().physics_frame
	_case("through a facade hole", Vector3(-9.5, 1.0, 0.0), 8.0, Vector3(-1, 0, 0))
	# Props are skipped: the office desk at (-12.8, z=2.1) is not a wall.
	_case("in an office beside a desk", Vector3(-12.2, 1.0, 2.1), 8.0, Vector3(1, 0, 0))
	var t0 := Time.get_ticks_usec()
	for i in 100:
		ImpactResolver.nearest_wall_dir(Vector3(-9.0 + i * 0.05, 1.0, 1.0), 8.0)
	var per := float(Time.get_ticks_usec() - t0) / 100.0
	var cost_ok := per < 400.0
	print("[nearwall] cost %.0f us per call -> %s" % [per, _pf(cost_ok)])
	_ok = _ok and cost_ok
	print("[nearwall] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _case(label: String, from: Vector3, max_dist: float, expect: Vector3) -> void:
	var d := ImpactResolver.nearest_wall_dir(from, max_dist)
	var ok: bool
	if expect == Vector3.ZERO:
		ok = d == Vector3.ZERO
	else:
		ok = absf(d.length() - 1.0) < 0.01 and absf(d.y) < 1e-4 and d.dot(expect) > 0.97
	print("[nearwall] %-30s -> %s (expect %s) %s" % [label, d, expect, _pf(ok)])
	_ok = _ok and ok

func _pf(v: bool) -> String:
	return "PASS" if v else "FAIL"
