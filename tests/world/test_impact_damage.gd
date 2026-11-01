extends Node3D
## Impact damage (spec: Mode and rules): (E - 500) / 20 HP, max 300.
## 1. Drywall break at ~2,240 J deals ~87 HP (HP really drops by that much).
## 2. A concrete pillar (static WORLD) hit at 10 m/s: one impact, E ~3,500 J,
##    body_impact with surface concrete and a normal facing the body.
## 3. A floor slam deals damage with an upward normal.
## 4. A gentle landing deals (almost) none.
## 5. Per-flight rules: the 2nd impact deals x Tuning.IMPACT_REPEAT_MULT.
## 6. A flight never deals more than Tuning.IMPACT_FLIGHT_CAP; breaking a 2nd
##    wall emits GameEvents.wall_chain(fighter, 2).
## 7. A bounce off a breakable shakes the screen and hitstops the body.
## Every impact emits GameEvents.impact_damaged (floor slams as &"floor").

var _use_fake := false
var _impacts: Array = []
var _events: Array = []
var _damaged: Array = []
var _chains: Array = []
var _shakes: Array = []
var _ok := true

func _ready() -> void:
	ImpactResolver.impact_dealt.connect(func(fighter: Node3D, e: float, dmg: float, surface: StringName, pos: Vector3) -> void:
		_impacts.append({"fighter": fighter, "energy": e, "damage": dmg, "surface": surface, "pos": pos}))
	GameEvents.body_impact.connect(func(fighter: Node3D, pos: Vector3, n: Vector3, e: float, surface: StringName) -> void:
		_events.append({"fighter": fighter, "pos": pos, "normal": n, "energy": e, "surface": surface}))
	GameEvents.impact_damaged.connect(func(fighter: Node3D, dmg: float, e: float, surface: StringName, pos: Vector3) -> void:
		_damaged.append({"fighter": fighter, "damage": dmg, "energy": e, "surface": surface, "pos": pos}))
	GameEvents.wall_chain.connect(func(fighter: Node3D, count: int) -> void: _chains.append([fighter, count]))
	GameEvents.screen_shake.connect(func(trauma: float) -> void: _shakes.append(trauma))
	WorldTestUtil.make_floor(self)
	await get_tree().physics_frame
	_use_fake = not await WorldTestUtil.real_ragdoll_available(self)
	print("[impact] ragdoll: ", "TEST STAND-IN" if _use_fake else "real RagdollController")

	# 1. Drywall break at 8 m/s.
	var panel := WorldTestUtil.make_panel(self, &"drywall")
	await get_tree().physics_frame
	var f := await _body(Vector3(2.0 + 0.125, 0, 0))
	var hp0 := f.hp
	_impacts.clear()
	f.launch(Vector3(-8, 1.8, 0), f.get_center_of_mass())
	var t := 0.0
	var brk: Dictionary = {}
	while t < 0.6 and brk.is_empty():
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		for im: Dictionary in _impacts:
			if im["surface"] == &"drywall":
				brk = im
	var hp_drop := hp0 - f.hp
	var d_ok: bool = not brk.is_empty() and absf(brk["damage"] - 87.0) <= 87.0 * 0.15 and absf(hp_drop - brk["damage"]) < 0.5
	print("[impact] drywall break: E=%.0f J dmg=%.1f HP (spec 87) hp %.0f -> %.0f -> %s" % [
		brk.get("energy", -1.0), brk.get("damage", -1.0), hp0, f.hp, "PASS" if d_ok else "FAIL"])
	_ok = _ok and d_ok
	f.queue_free()
	panel.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

	# 2. Concrete pillar at 10 m/s.
	var pillar := StaticBody3D.new()
	pillar.collision_layer = Layers.WORLD
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1, 4, 1)
	cs.shape = box
	pillar.add_child(cs)
	add_child(pillar)
	pillar.global_position = Vector3(0, 2, 0)
	await get_tree().physics_frame
	f = await _body(Vector3(0.5 + 2.0, 0, 0))
	_impacts.clear()
	_events.clear()
	f.launch(Vector3(-10, 1.6, 0), f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 0.6)
	var walls := _impacts.filter(func(x: Dictionary) -> bool: return x["fighter"] == f and absf(x["pos"].x - 0.5) < 0.3)
	var ev := _events.filter(func(x: Dictionary) -> bool: return x["fighter"] == f and absf(x["pos"].x - 0.5) < 0.3)
	var p_ok: bool = walls.size() == 1 and ev.size() == 1 and absf(walls[0]["energy"] - 3500.0) <= 3500.0 * 0.3 \
		and ev[0]["surface"] == &"concrete" and (ev[0]["normal"] as Vector3).x > 0.8
	print("[impact] pillar 10 m/s: impacts=%d E=%s dmg=%s normal=%s surface=%s -> %s" % [
		walls.size(), walls.map(func(x: Dictionary) -> int: return int(x["energy"])),
		walls.map(func(x: Dictionary) -> int: return int(x["damage"])),
		ev[0]["normal"] if ev.size() > 0 else "-", ev[0]["surface"] if ev.size() > 0 else "-", "PASS" if p_ok else "FAIL"])
	_ok = _ok and p_ok
	f.queue_free()
	pillar.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

	# 3. Floor slam: driven down at 7 m/s.
	f = await _body(Vector3(10, 0, 10))
	_impacts.clear()
	_events.clear()
	f.launch(Vector3(0, 6, 0), f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 0.25)
	f.launch(Vector3(0, -12, 0), f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 0.8)
	var floors := _events.filter(func(x: Dictionary) -> bool: return x["fighter"] == f and (x["normal"] as Vector3).y > 0.7)
	var fdmg := _damaged.filter(func(x: Dictionary) -> bool: return x["fighter"] == f)
	var fl_ok: bool = floors.size() >= 1 and floors[0]["energy"] > 1000.0 and fdmg.size() >= 1 and fdmg[0]["surface"] == &"floor"
	print("[impact] floor slam: impacts=%d E=%s impact_damaged surface=%s -> %s" % [floors.size(),
		floors.map(func(x: Dictionary) -> int: return int(x["energy"])),
		fdmg[0]["surface"] if fdmg.size() > 0 else "-", "PASS" if fl_ok else "FAIL"])
	_ok = _ok and fl_ok
	f.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

	# 4. Gentle hop: at most the few HP of the body toppling onto the floor.
	f = await _body(Vector3(-10, 0, 10))
	var hp1 := f.hp
	_impacts.clear()
	f.launch(Vector3(0.5, 2.0, 0), f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 1.0)
	var g_ok: bool = hp1 - f.hp <= 5.0
	print("[impact] gentle hop: impacts=%d hp %.0f -> %.0f -> %s" % [
		_impacts.size(), hp1, f.hp, "PASS" if g_ok else "FAIL"])
	_ok = _ok and g_ok
	f.queue_free()
	WorldTestUtil.cleanup()

	# 5. Per-flight rules: 10 m/s through drywall, then a second drywall 2 m
	#    behind it: the 2nd impact deals x IMPACT_REPEAT_MULT.
	var a := WorldTestUtil.make_panel(self, &"drywall", Vector3(0, 0, 20))
	var b := WorldTestUtil.make_panel(self, &"drywall", Vector3(-2.25, 0, 20))
	await get_tree().physics_frame
	f = await _body(Vector3(2.125, 0, 20))
	_damaged.clear()
	_chains.clear()
	f.launch(Vector3(-10, 1.6, 0), f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 0.8)
	var mine := _damaged.filter(func(x: Dictionary) -> bool: return x["fighter"] == f)
	var r_ok := mine.size() >= 2 and absf(mine[0]["damage"] - Tuning.impact_damage(mine[0]["energy"])) < 0.01 \
		and absf(mine[1]["damage"] - Tuning.impact_damage(mine[1]["energy"]) * Tuning.IMPACT_REPEAT_MULT) < 0.01
	print("[impact] repeat rule: %s -> %s" % [mine.map(func(x: Dictionary) -> String: return "%s E=%.0f dmg=%.1f" % [
		x["surface"], x["energy"], x["damage"]]), "PASS" if r_ok else "FAIL"])
	_ok = _ok and r_ok
	f.queue_free()
	a.queue_free()
	b.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

	# 6. Flight cap and wall chain: 18 m/s through two drywall panels.
	a = WorldTestUtil.make_panel(self, &"drywall", Vector3(0, 0, 40))
	b = WorldTestUtil.make_panel(self, &"drywall", Vector3(-3.25, 0, 40))
	await get_tree().physics_frame
	f = await _body(Vector3(2.125, 0, 40))
	_damaged.clear()
	_chains.clear()
	f.launch(Vector3(-18, 1.6, 0), f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 1.0)
	mine = _damaged.filter(func(x: Dictionary) -> bool: return x["fighter"] == f)
	var total := 0.0
	for x: Dictionary in mine:
		total += x["damage"]
	var chain_counts: Array = _chains.filter(func(c: Array) -> bool: return c[0] == f).map(func(c: Array) -> int: return c[1])
	var cap_ok := total <= Tuning.IMPACT_FLIGHT_CAP + 0.01 and mine.size() >= 1 and absf(mine[0]["damage"] - Tuning.IMPACT_FLIGHT_CAP) < 0.01 \
		and chain_counts.has(2)
	print("[impact] flight cap: damage %s total %.1f (cap %.0f), wall_chain counts %s -> %s" % [
		mine.map(func(x: Dictionary) -> int: return int(x["damage"])), total, Tuning.IMPACT_FLIGHT_CAP, chain_counts,
		"PASS" if cap_ok else "FAIL"])
	_ok = _ok and cap_ok
	f.queue_free()
	a.queue_free()
	b.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

	# 7. A bounce off brick shakes the screen and hitstops the body.
	var brick := WorldTestUtil.make_panel(self, &"brick", Vector3(0, 0, 60))
	await get_tree().physics_frame
	f = await _body(Vector3(2.125, 0, 60))
	_shakes.clear()
	var froze := false
	var st := {"decided": false}
	var cb := func(fi: Node3D, _w: Node3D, _o: StringName, _e: float, _p: Vector3) -> void:
		if fi == f:
			st["decided"] = true
	ImpactResolver.wall_decided.connect(cb)
	f.launch(Vector3(-8, 1.6, 0), f.get_center_of_mass())
	var t2 := 0.0
	while t2 < 0.6:
		await get_tree().physics_frame
		t2 += get_physics_process_delta_time()
		if st["decided"] and f.has_method(&"is_frozen") and f.call(&"is_frozen"):
			froze = true
	ImpactResolver.wall_decided.disconnect(cb)
	var feel_ok: bool = st["decided"] and froze and _shakes.size() >= 1
	print("[impact] brick bounce: decided=%s hitstop=%s shakes=%s -> %s" % [st["decided"], froze, _shakes, "PASS" if feel_ok else "FAIL"])
	_ok = _ok and feel_ok
	f.queue_free()
	brick.queue_free()
	WorldTestUtil.cleanup()

	print("[impact] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

## 70 kg dummy (Brawler HP so a break does not kill it) whose COM sits at `com_xz`.
func _body(com_xz: Vector3) -> Fighter:
	var f := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, -PI * 0.5), com_xz + Vector3(0, 0.05, 0)),
		_use_fake, &"grunt")
	f.max_hp = 1000.0
	f.hp = 1000.0
	await get_tree().physics_frame
	await get_tree().physics_frame
	var c := f.get_center_of_mass()
	f.global_position += Vector3(com_xz.x - c.x, 0, com_xz.z - c.z)
	f.reset_physics_interpolation()
	await get_tree().physics_frame
	return f
