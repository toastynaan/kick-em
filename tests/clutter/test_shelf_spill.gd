extends Node3D
## Round 6 shelves (agent K): a broken shelf spills Tuning.SHELF_SPILL (2-4)
## ThrowableProps (bottles, bricks, small crates): the "few" rack 2, the plain
## one 3, the "full" one 4. Each lands as a pick-up-able prop (Carry's group
## "throwable_props", can_pick_up, no respawn). One rack is broken by a real
## thrown body through the ImpactResolver, one by kicks. A slam blast 1 m away
## (WorldDamage) only cracks the third (no spill; blasts break only glass and
## cardboard) and lowers its break energy, so a slow body then breaks it.

var _ok := true

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[shelf] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _ready() -> void:
	ClutterTestUtil.make_floor(self)
	await ClutterTestUtil.frames(self, 2)
	await _body(&"full", Vector3(0, 0, 0))
	await _kicks(&"", Vector3(0, 0, 12))
	await _blast(&"few", Vector3(0, 0, 24))
	print("[shelf] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _report(label: String, shelf: Furniture, want: int) -> void:
	await ClutterTestUtil.wait_game(self, 1.5)
	var kinds: Array = []
	var ok := shelf.is_broken and shelf.spilled.size() == want and want >= Tuning.SHELF_SPILL.x and want <= Tuning.SHELF_SPILL.y
	for p in shelf.spilled:
		kinds.append(p.kind)
		ok = ok and is_instance_valid(p) and p.is_in_group(&"throwable_props") and p.can_pick_up() and not p.respawns \
			and p.global_position.y < 1.0
	_line("%s: broken=%s, spilled %d throwables %s (want %d, in [%d, %d]), all on the floor and pick-up-able" % [
		label, shelf.is_broken, shelf.spilled.size(), kinds, want, Tuning.SHELF_SPILL.x, Tuning.SHELF_SPILL.y], ok)

func _body(variant: StringName, at: Vector3) -> void:
	var shelf := ClutterTestUtil.make(self, &"shelf", at, PI * 0.5, variant)
	await ClutterTestUtil.frames(self, 1)
	var face_x := shelf.get_box_transform().origin.x + shelf.get_half_extent_along(Vector3.RIGHT)
	var thrower := ClutterTestUtil.spawn_body(self, at + Vector3(face_x + 2.6, 0.05, 1.5), 0.0, &"player",
		Fighter.TEAM_PLAYER)
	var body := ClutterTestUtil.spawn_body(self, at + Vector3(face_x + 1.2, 0.05, 0), -PI * 0.5)
	await ClutterTestUtil.frames(self, 8)
	var v := Vector3(-9.0, 1.0, 0)
	body.launch(v, body.get_center_of_mass())
	GameEvents.thrown.emit(thrower, body, v)
	await _report("full rack, thrown body at 9 m/s", shelf, 4)
	for n in [shelf, thrower, body]:
		n.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)

func _kicks(variant: StringName, at: Vector3) -> void:
	var shelf := ClutterTestUtil.make(self, &"shelf", at, 0.0, variant)
	await ClutterTestUtil.frames(self, 1)
	var hit := shelf.get_box_transform().origin + Vector3(0, -0.4, shelf.size.z * 0.5)
	var n := 0
	while not shelf.is_broken and n < 10:
		shelf.receive_strike(null, hit, Vector3.FORWARD, 60.0)
		n += 1
	await _report("plain rack, %d kicks (strike_hp %.0f)" % [n, float(Tuning.FURNITURE[&"shelf"]["strike_hp"])], shelf, 3)
	shelf.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)

func _blast(variant: StringName, at: Vector3) -> void:
	var shelf := ClutterTestUtil.make(self, &"shelf", at, PI * 0.5, variant)
	await ClutterTestUtil.frames(self, 1)
	var b0 := shelf.break_energy
	var center := at + Vector3(-1.0, 0.1, 0.0)
	var res: Array = []
	var cb := func(_c: Vector3, _r: float, _p: float, _s: StringName, reached: Array) -> void:
		for r: Array in reached:
			if r[0] == shelf:
				res.append([r[1], r[2]])
	WorldDamage.blasted.connect(cb)
	WorldDamage.blast(center, float(Tuning.BLAST[&"slam"]), 4000.0, &"slam")
	WorldDamage.blasted.disconnect(cb)
	await ClutterTestUtil.wait_game(self, 0.5)
	var cracked_ok: bool = res.size() == 1 and res[0][1] == &"crack" and not shelf.is_broken and shelf.spilled.is_empty() \
		and shelf.break_energy < b0
	_line("few rack, slam blast 1 m away: reached with %.0f J -> %s, broken=%s, spilled %d, break energy %.0f -> %.0f" % [
		float(res[0][0]) if res.size() > 0 else -1.0, res[0][1] if res.size() > 0 else &"none", shelf.is_broken,
		shelf.spilled.size(), b0, shelf.break_energy], cracked_ok)
	# The weakened rack: a slow body (well under its original break energy) breaks it.
	var face_x := shelf.get_box_transform().origin.x + shelf.get_half_extent_along(Vector3.RIGHT)
	var body := ClutterTestUtil.spawn_body(self, at + Vector3(face_x - at.x + 1.2, 0.05, 0), -PI * 0.5)
	await ClutterTestUtil.frames(self, 8)
	var speed := sqrt(2.0 * 1.6 * shelf.break_energy / body.get_total_mass())
	body.launch(Vector3(-speed, 0.6, 0), body.get_center_of_mass())
	await _report("few rack, then a body at %.1f m/s (%.0f J, original break %.0f J)" % [
		speed, 0.8 * shelf.break_energy * 2.0, b0], shelf, 2)
	for n in [shelf, body]:
		if is_instance_valid(n):
			n.queue_free()
	ClutterTestUtil.cleanup()
	WorldDamage.reset()
	await ClutterTestUtil.frames(self, 2)
