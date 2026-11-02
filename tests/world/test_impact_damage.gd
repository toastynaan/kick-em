extends Node3D
## Round 5 wall damage (Feel Reference: Health and damage; Launch speed and
## walls). Wall damage to the flying body is Tuning.WALL_DAMAGE (crack +5,
## drywall / wood break +10, brick +20, concrete +30) and replaces the old
## energy-based impact damage; floor landings and bounces deal none.
## 1. Drywall break: HP drops by exactly WALL_DAMAGE.drywall; body_impact and
##    impact_damaged fire.
## 2. Static concrete (unbreakable, like the arena boundary) at 10 m/s
##    (3,500 J, under the 6,000 J crack energy): one body_impact (surface
##    concrete, normal toward the body), no damage. At 14 m/s (6,860 J): a crack:
##    +5, a crack decal, wall_cracked.
## 3. A floor slam: body_impact with an upward normal, no damage.
## 4. A gentle hop: no damage.
## 5. Two drywall panels in one flight: +10 each, GameEvents.wall_chain(f, 2);
##    each panel counts once (no third damage, no chain 3), whatever the body
##    does in the holes. Ragdoll and chunk randomness are seeded.
## 6. A brick crack (10 m/s, 3,500 J): +5, local hitstop on the body, a shake.
## 7. Speed cap: a 25 m/s launch flies at Tuning.LAUNCH_SPEED_MAX (18).
## 8. A wall break freezes only the flying body (Tuning.WALL_BREAK_FREEZE): a
##    standing enemy beside the wall keeps moving.

var _impacts: Array = []
var _events: Array = []
var _damaged: Array = []
var _chains: Array = []
var _shakes: Array = []
var _cracked: Array = []
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
	GameEvents.wall_cracked.connect(func(wall: Node3D, _p: Vector3, e: float) -> void: _cracked.append([wall, e]))
	WorldTestUtil.make_floor(self, 200.0)
	await get_tree().physics_frame
	if not await WorldTestUtil.real_ragdoll_available(self):
		print("[impact] FAIL: real ragdoll unavailable")
		get_tree().quit(1)
		return

	# 1. Drywall break at 10 m/s.
	var panel := WorldTestUtil.make_panel(self, &"drywall")
	await get_tree().physics_frame
	var f := await _body(Vector3(1.6 + 0.125, 0, 0))
	var hp0 := f.hp
	_clear()
	f.launch(Vector3(-10, 1.6, 0), f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 0.6)
	var mine := _damaged.filter(func(x: Dictionary) -> bool: return x["fighter"] == f)
	var ev := _events.filter(func(x: Dictionary) -> bool: return x["fighter"] == f and x["surface"] == &"drywall")
	var d_ok: bool = mine.size() == 1 and absf(mine[0]["damage"] - Tuning.WALL_DAMAGE[&"drywall"]) < 0.01 \
		and absf(hp0 - f.hp - Tuning.WALL_DAMAGE[&"drywall"]) < 0.01 and ev.size() == 1
	_line("drywall break 10 m/s: E=%s dmg=%s hp %.0f -> %.0f (want -%.0f), body_impact=%d" % [
		_ints(mine, "energy"), _ints(mine, "damage"), hp0, f.hp, Tuning.WALL_DAMAGE[&"drywall"], ev.size()], d_ok)
	f.queue_free()
	panel.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

	# 2. Static concrete box (WORLD, unbreakable) at 10 and 14 m/s.
	var block := StaticBody3D.new()
	block.collision_layer = Layers.WORLD
	block.set_meta(&"surface", &"concrete")
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1, 4, 6)
	cs.shape = box
	block.add_child(cs)
	add_child(block)
	block.global_position = Vector3(0, 2, 20)
	await get_tree().physics_frame
	for speed: float in [10.0, 14.0]:
		f = await _body(Vector3(0.5 + 1.6, 0, 20))
		hp0 = f.hp
		_clear()
		f.launch(Vector3(-speed, 1.6, 0), f.get_center_of_mass())
		await WorldTestUtil.wait_game(self, 0.6)
		var walls := _impacts.filter(func(x: Dictionary) -> bool: return x["fighter"] == f and absf(x["pos"].x - 0.5) < 0.3)
		var wev := _events.filter(func(x: Dictionary) -> bool: return x["fighter"] == f and absf(x["pos"].x - 0.5) < 0.3)
		var crack := speed > 12.0
		var want := Tuning.WALL_DAMAGE[&"crack"] if crack else 0.0
		var c_ok: bool = walls.size() == 1 and wev.size() == 1 and wev[0]["surface"] == &"concrete" \
			and (wev[0]["normal"] as Vector3).x > 0.8 and absf(hp0 - f.hp - want) < 0.01 \
			and (_cracked.size() >= 1) == crack
		_line("static concrete %2.0f m/s: impacts=%d E=%s dmg=%s normal=%s cracked=%d (want dmg %.0f) " % [speed,
			walls.size(), _ints(walls, "energy"), _ints(walls, "damage"), wev[0]["normal"] if wev.size() > 0 else "-",
			_cracked.size(), want], c_ok)
		f.queue_free()
		WorldTestUtil.cleanup()
		await get_tree().physics_frame
	block.queue_free()

	# 3. Floor slam: driven down hard.
	f = await _body(Vector3(10, 0, 40))
	hp0 = f.hp
	f.launch(Vector3(0, 6, 0), f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 0.25)
	_clear()
	f.launch(Vector3(0, -12, 0), f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 0.8)
	var floors := _events.filter(func(x: Dictionary) -> bool: return x["fighter"] == f and (x["normal"] as Vector3).y > 0.7)
	var fl_ok: bool = floors.size() >= 1 and floors[0]["energy"] > 1000.0 and is_equal_approx(f.hp, hp0) \
		and _damaged.filter(func(x: Dictionary) -> bool: return x["fighter"] == f).is_empty()
	_line("floor slam: body_impact=%d E=%s hp %.0f -> %.0f (no damage)" % [floors.size(), _ints(floors, "energy"),
		hp0, f.hp], fl_ok)
	f.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

	# 4. Gentle hop.
	f = await _body(Vector3(-10, 0, 40))
	hp0 = f.hp
	f.launch(Vector3(0.5, 2.0, 0), f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 1.0)
	_line("gentle hop: hp %.0f -> %.0f" % [hp0, f.hp], is_equal_approx(hp0, f.hp))
	f.queue_free()
	WorldTestUtil.cleanup()

	# 5. Two drywall panels in one flight (12 m/s): +10 each, wall_chain 2.
	var a := WorldTestUtil.make_panel(self, &"drywall", Vector3(0, 0, 60))
	var b := WorldTestUtil.make_panel(self, &"drywall", Vector3(-2.75, 0, 60))
	for k in 2:
		var prng: Variant = [a, b][k].get(&"_rng")
		if prng is RandomNumberGenerator:
			(prng as RandomNumberGenerator).seed = 501 + k
	await get_tree().physics_frame
	f = await _body(Vector3(1.6 + 0.125, 0, 60))
	_clear()
	var decs: Array = []
	var on_dec := func(fi: Node3D, w: Node3D, o: StringName, _e: float, _p: Vector3) -> void:
		if fi == f:
			decs.append("%s %s" % ["a" if w == a else ("b" if w == b else String(w.name)), o])
	ImpactResolver.wall_decided.connect(on_dec)
	f.launch(Vector3(-12, 1.4, 0), f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 1.0)
	ImpactResolver.wall_decided.disconnect(on_dec)
	mine = _damaged.filter(func(x: Dictionary) -> bool: return x["fighter"] == f)
	var chain_counts: Array = _chains.filter(func(c: Array) -> bool: return c[0] == f).map(func(c: Array) -> int: return c[1])
	var two_ok := mine.size() == 2 and mine.all(func(x: Dictionary) -> bool:
		return absf(x["damage"] - Tuning.WALL_DAMAGE[&"drywall"]) < 0.01) and chain_counts == [2] \
		and decs.filter(func(d: String) -> bool: return d.ends_with("break")).size() == 2
	_line("two drywalls 12 m/s: decisions %s, damage %s, wall_chain %s" % [decs, _ints(mine, "damage"), chain_counts], two_ok)
	f.queue_free()
	a.queue_free()
	b.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

	# 6. Brick crack at 10 m/s: +5, hitstop, shake.
	var brick := WorldTestUtil.make_panel(self, &"brick", Vector3(0, 0, 80))
	await get_tree().physics_frame
	f = await _body(Vector3(1.6 + 0.125, 0, 80))
	hp0 = f.hp
	_clear()
	var st := {"decided": &"", "froze": false}
	var cb := func(fi: Node3D, _w: Node3D, o: StringName, _e: float, _p: Vector3) -> void:
		if fi == f:
			st["decided"] = o
	ImpactResolver.wall_decided.connect(cb)
	f.launch(Vector3(-10, 1.6, 0), f.get_center_of_mass())
	var t := 0.0
	while t < 0.6:
		await get_tree().physics_frame
		t += 1.0 / 120.0
		if st["decided"] != &"" and f.is_frozen():
			st["froze"] = true
	ImpactResolver.wall_decided.disconnect(cb)
	var feel_ok: bool = st["decided"] == &"crack" and st["froze"] and _shakes.size() >= 1 \
		and absf(hp0 - f.hp - Tuning.WALL_DAMAGE[&"crack"]) < 0.01
	_line("brick crack 10 m/s: outcome=%s hitstop=%s shakes=%s hp %.0f -> %.0f (want -%.0f)" % [st["decided"],
		st["froze"], _shakes, hp0, f.hp, Tuning.WALL_DAMAGE[&"crack"]], feel_ok)
	f.queue_free()
	brick.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

	# 7. Speed cap: 25 m/s flies at 18.
	f = await _body(Vector3(0, 0, 100))
	f.launch(Vector3(25, 3, 0), f.get_center_of_mass())
	var top := 0.0
	for i in 12:
		await get_tree().physics_frame
		if i >= 2:
			top = maxf(top, f.get_com_velocity().length())
	_line("speed cap: 25 m/s launch flies at %.2f m/s (cap %.0f)" % [top, Tuning.LAUNCH_SPEED_MAX],
		top <= Tuning.LAUNCH_SPEED_MAX + 0.3 and top > Tuning.LAUNCH_SPEED_MAX - 1.0)
	f.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

	# 8. Wall break freezes only the flyer: a bystander walking beside the wall keeps moving.
	var wall := WorldTestUtil.make_panel(self, &"drywall", Vector3(0, 0, 120))
	var by := WorldTestUtil.spawn_body(self, Transform3D(Basis(), Vector3(3.0, 0.05, 123.0)), false, &"grunt")
	await get_tree().physics_frame
	f = await _body(Vector3(1.6 + 0.125, 0, 120))
	by.move_input = Vector3(0, 0, -1)
	var flyer_frozen := 0.0
	var by_moved_while := 0.0
	var by_prev := by.global_position
	f.launch(Vector3(-12, 1.4, 0), f.get_center_of_mass())
	t = 0.0
	while t < 0.6:
		await get_tree().physics_frame
		t += 1.0 / 120.0
		if f.is_frozen():
			flyer_frozen += 1.0 / 120.0
			by_moved_while += by.global_position.distance_to(by_prev)
		by_prev = by.global_position
	var fr_ok := flyer_frozen >= Tuning.WALL_BREAK_FREEZE - 0.02 and flyer_frozen <= Tuning.WALL_BREAK_FREEZE + 0.04 \
		and by_moved_while > 0.05 and not by.is_frozen()
	_line("wall-break freeze: flyer frozen %.3f s (want %.2f), bystander moved %.2f m meanwhile" % [
		flyer_frozen, Tuning.WALL_BREAK_FREEZE, by_moved_while], fr_ok)
	f.queue_free()
	by.queue_free()
	wall.queue_free()
	WorldTestUtil.cleanup()

	print("[impact] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _clear() -> void:
	_impacts.clear()
	_events.clear()
	_damaged.clear()
	_chains.clear()
	_shakes.clear()
	_cracked.clear()

func _ints(a: Array, key: String) -> Array:
	return a.map(func(x: Dictionary) -> int: return int(x[key]))

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[impact] %s -> %s" % [s, "PASS" if ok else "FAIL"])

## 70 kg dummy with lots of HP (damage is read off it) whose COM sits at `com_xz`.
func _body(com_xz: Vector3) -> Fighter:
	var f := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, -PI * 0.5), com_xz + Vector3(0, 0.05, 0)),
		false, &"player")
	f.max_hp = 1000.0
	f.hp = 1000.0
	# Reproducible: the ragdoll's random limb spin is seeded (Jolt is deterministic).
	var rng: Variant = f.ragdoll.get(&"_rng") if f.ragdoll else null
	if rng is RandomNumberGenerator:
		(rng as RandomNumberGenerator).seed = 7000 + int(com_xz.z)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var c := f.get_center_of_mass()
	f.global_position += Vector3(com_xz.x - c.x, 0, com_xz.z - c.z)
	f.reset_physics_interpolation()
	await get_tree().physics_frame
	return f
