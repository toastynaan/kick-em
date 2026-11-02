extends Node3D
## Wall slam (upgrade 2): a grabbed victim driven head first into a wall at
## Tuning.WALL_SLAM_SPEED (9 m/s, ~2,800 J for 70 kg) from Tuning.WALL_SLAM_RANGE.
## Drywall: a body-sized hole that includes the head, the panel still stands,
## and the normal events fire (wall_broken, body_impact, impact_damaged).
## Brick: a crack and a bounce, with wall_cracked and impact events.
## Also prints (does not judge) the same slam at the move's current 15 deg
## throw angle (Tuning.THROW_UP_ANGLE), which loses energy into the wall.

var _events := {}
var _ok := true

func _ready() -> void:
	for sig: StringName in [&"wall_broken", &"wall_cracked", &"body_impact", &"impact_damaged"]:
		var s := sig
		GameEvents.connect(s, func(a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null, _e: Variant = null) -> void:
			_events[s] = (_events.get(s, []) as Array) + [a])
	WorldTestUtil.make_floor(self)
	await get_tree().physics_frame
	if not await WorldTestUtil.real_ragdoll_available(self):
		print("[slam] SKIP: real ragdoll unavailable")
		get_tree().quit(1)
		return
	await _slam(&"drywall", 0.0)
	await _slam(&"brick", 12.0)
	var up := deg_to_rad(Tuning.THROW_UP_ANGLE)
	await _slam(&"drywall", 24.0, up, false)
	await _slam(&"brick", 36.0, up, false)
	print("[slam] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _slam(surface: StringName, z: float, up_angle := deg_to_rad(2.5), strict := true) -> void:
	_events.clear()
	var panel := WorldTestUtil.make_panel(self, surface, Vector3(0, 0, z))
	var decided := {}
	var cb := func(who: Node3D, w: Node3D, result: StringName, energy: float, _p: Vector3) -> void:
		if w == panel and decided.is_empty():
			decided["outcome"] = result
			decided["energy"] = energy
			decided["fighter"] = who
	ImpactResolver.wall_decided.connect(cb)
	# Victim faces the wall, centre of mass Tuning.WALL_SLAM_RANGE from the face.
	var face_x := panel.size.z * 0.5
	var f := FighterFactory.spawn_dummy(self, &"grunt",
		Transform3D(Basis.looking_at(Vector3(-1, 0, 0)), Vector3(face_x + Tuning.WALL_SLAM_RANGE, 0.05, z)))
	for i in 3:
		await get_tree().physics_frame
	var com := f.get_center_of_mass()
	f.global_position += Vector3(face_x + Tuning.WALL_SLAM_RANGE - com.x, 0, z - com.z)
	f.reset_physics_interpolation()
	await get_tree().physics_frame
	var head := f.rig.get_bone_global_position(&"Head")
	# Head first: the drive is applied at the head.
	f.launch(Vector3(-cos(up_angle), sin(up_angle), 0) * Tuning.WALL_SLAM_SPEED, head, &"Head")
	var head_at_contact := Vector3.ZERO
	var t := 0.0
	while t < 1.0:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		if decided.has("outcome") and head_at_contact == Vector3.ZERO:
			head_at_contact = f.rig.get_bone_global_position(&"Head")
	ImpactResolver.wall_decided.disconnect(cb)
	var e: float = decided.get("energy", -1.0)
	var outcome: StringName = decided.get("outcome", &"none")
	var e_ok := absf(e - 2835.0) / 2835.0 <= 0.15
	var tag := "" if strict else " [info: %.0f deg up]" % rad_to_deg(up_angle)
	var past := face_x - f.get_center_of_mass().x
	var ev := func(n: StringName) -> int: return (_events.get(n, []) as Array).filter(func(x: Variant) -> bool: return x == panel or x == f).size()
	var ok: bool
	if surface == &"drywall":
		var head_hole := panel.is_point_open(Vector3(0, clampf(head_at_contact.y, 0.2, 2.9), head_at_contact.z))
		ok = outcome == &"break" and e_ok and head_hole and not panel.is_broken and ev.call(&"wall_broken") >= 1 \
			and ev.call(&"body_impact") >= 1 and ev.call(&"impact_damaged") >= 1
		print("[slam]%s drywall: %s E=%.0f J (spec ~2,835) head at %.2f m in the hole=%s, cells left %d/%d, body %.2f m past, events broken=%d impact=%d damaged=%d -> %s" % [
			tag, outcome, e, head_at_contact.y, head_hole, panel.get_alive_count(), panel.get_cell_count(), past,
			ev.call(&"wall_broken"), ev.call(&"body_impact"), ev.call(&"impact_damaged"), "PASS" if ok else "FAIL"])
	else:
		ok = outcome == &"crack" and e_ok and panel.is_cracked and past < 0.0 and ev.call(&"wall_cracked") >= 1 \
			and ev.call(&"body_impact") >= 1 and ev.call(&"impact_damaged") >= 1
		print("[slam]%s brick: %s E=%.0f J, break energy now %.0f, body %.2f m in front, events cracked=%d impact=%d damaged=%d -> %s" % [
			tag, outcome, e, panel.break_energy, -past, ev.call(&"wall_cracked"), ev.call(&"body_impact"),
			ev.call(&"impact_damaged"), "PASS" if ok else "FAIL"])
	if strict:
		_ok = _ok and ok
	f.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame
