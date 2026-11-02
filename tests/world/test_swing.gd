extends Node3D
## Limb-grab swings (upgrade 2): ImpactResolver.track_swing(body, holder).
## A swung body (driven round its holder like a grip would) bowls an enemy
## in its path, never bowls its holder, takes no impact damage from the
## grip's pull, decides on a wall it is swung into, and its impact damage
## stays under the per-swing cap. untrack_swing ends it.
## Release: GameEvents.limb_grab_released (as agent G emits it) makes the
## grabber the launcher of the fling, the flight a throw, and the grabber gets
## the credit for an enemy the flung body bowls. A break-free (no fling
## velocity) throws nothing.

const RADIUS := 1.1
const SPEED := 8.0
var _bowls: Array = []
var _decisions: Array = []
var _damage: Array = []
var _infos: Array[HitInfo] = []

func _ready() -> void:
	GameEvents.body_bowled.connect(func(fl: Node3D, vi: Node3D, e: float, c: int) -> void: _bowls.append([fl, vi, e, c]))
	GameEvents.impact_damaged.connect(func(f: Node3D, d: float, e: float, s: StringName, p: Vector3) -> void: _damage.append([f, d, e, s, p]))
	ImpactResolver.wall_decided.connect(func(f: Node3D, w: Node3D, o: StringName, e: float, _p: Vector3) -> void: _decisions.append([f, w, o, e]))
	ImpactResolver.impact_info.connect(func(info: HitInfo) -> void: _infos.append(info))
	WorldTestUtil.make_floor(self)
	await get_tree().physics_frame
	if not await WorldTestUtil.real_ragdoll_available(self):
		print("[swing] SKIP: real ragdoll unavailable")
		get_tree().quit(1)
		return
	# Holder (an enemy here, so only the holder rule keeps it from being bowled),
	# swung body, an enemy on the circle at 90 deg, a drywall panel at ~200 deg.
	var holder := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis(), Vector3(0, 0.05, 0)))
	var body := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis(), Vector3(RADIUS, 0.05, 0)))
	var target := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis(), Vector3(0, 0.05, RADIUS)))
	var panel := Destructible.new()
	panel.surface = &"drywall"
	panel.transform = Transform3D(Basis(), Vector3(-1.5, 1.5, -0.75))   # faces +Z
	add_child(panel)
	for i in 6:
		await get_tree().physics_frame
	body.launch(Vector3(0, 1.0, 0), body.get_center_of_mass())
	await get_tree().physics_frame
	ImpactResolver.track_swing(body, holder)
	var swinging_ok := ImpactResolver.is_swinging(body)
	var pull_damage := -1.0
	var t := 0.0
	while t < 1.0:
		await get_tree().physics_frame
		var dt := get_physics_process_delta_time()
		t += dt
		# Grip: pull the body's centre of mass round the holder at SPEED.
		var body_com := body.get_center_of_mass()
		var r := Vector3(body_com.x, 0, body_com.z)
		var ang := atan2(r.z, r.x)
		var tangent := Vector3(-sin(ang), 0, cos(ang))
		var want := tangent * SPEED + (Vector3(cos(ang), 0, sin(ang)) * RADIUS - r) * 6.0
		want.y = (1.0 - body_com.y) * 6.0
		body.ragdoll.add_velocity(want - body.get_com_velocity())
		if pull_damage < 0.0 and ang > deg_to_rad(150.0):
			pull_damage = _sum_damage(body)
	ImpactResolver.untrack_swing(body)
	var bowled_target := _bowls.any(func(b: Array) -> bool: return b[0] == body and b[1] == target)
	var bowled_holder := _bowls.any(func(b: Array) -> bool: return b[1] == holder)
	var wall := _decisions.filter(func(d: Array) -> bool: return d[0] == body and d[1] == panel)
	var total := _sum_damage(body)
	print("[swing] tracking while swung=%s, bowled the enemy in its path=%s (E=%s), bowled its holder=%s" % [
		swinging_ok, bowled_target, _bowls.map(func(b: Array) -> int: return int(b[2])), bowled_holder])
	print("[swing] grip pull alone dealt %.1f HP; wall decision=%s; swing impact damage %.1f (cap %.0f); untracked=%s" % [
		pull_damage, wall.map(func(d: Array) -> String: return "%s %.0f J" % [d[2], d[3]]), total,
		ImpactResolver.SWING_DAMAGE_CAP, not ImpactResolver.is_swinging(body)])
	var ok := swinging_ok and bowled_target and not bowled_holder and is_zero_approx(maxf(pull_damage, 0.0)) \
		and wall.size() >= 1 and total <= ImpactResolver.SWING_DAMAGE_CAP + 0.01 and not ImpactResolver.is_swinging(body)

	# Release: fling the body at a second enemy, then emit limb_grab_released
	# exactly as LimbGrab.release() does (relaunch first, then the event).
	var com := body.get_center_of_mass()
	var away := Vector3(com.x, 0, com.z).normalized()
	if away.length() < 0.5:
		away = Vector3.RIGHT
	var target2 := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis(), Vector3(com.x, 0.05, com.z) + away * 2.6))
	for i in 4:
		await get_tree().physics_frame
	_bowls.clear()
	_infos.clear()
	var fling := away * 10.0 + Vector3.UP * 1.2
	body.launch(fling - body.get_com_velocity(), body.get_center_of_mass())
	GameEvents.limb_grab_released.emit(holder, body, fling)
	var launcher_ok := ImpactResolver.get_launcher(body) == holder and ImpactResolver.is_thrown_flight(body)
	await WorldTestUtil.wait_game(self, 0.8)
	var hit2 := _bowls.any(func(b: Array) -> bool: return b[0] == body and b[1] == target2)
	var credit := _infos.filter(func(i: HitInfo) -> bool: return i.victim == target2 and i.move_id == &"bowl")
	var credit_ok: bool = credit.size() >= 1 and credit[0].attacker == holder
	# A break-free (zero velocity) is not a throw.
	var bystander := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis(), Vector3(-6, 0.05, 6)))
	await get_tree().physics_frame
	GameEvents.limb_grab_released.emit(holder, bystander, Vector3.ZERO)
	var free_ok := not ImpactResolver.is_thrown_flight(bystander) and ImpactResolver.get_launcher(bystander) == null
	print("[swing] release: launcher is the grabber=%s, thrown flight=%s, fling bowled the 2nd enemy=%s, credit to the grabber=%s, break-free throws nothing=%s -> %s" % [
		ImpactResolver.get_launcher(body) == holder, ImpactResolver.is_thrown_flight(body) or launcher_ok, hit2,
		credit_ok, free_ok, "PASS" if launcher_ok and hit2 and credit_ok and free_ok else "FAIL"])
	ok = ok and launcher_ok and hit2 and credit_ok and free_ok
	print("[swing] RESULT: ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)

func _sum_damage(f: Node3D) -> float:
	var s := 0.0
	for d: Array in _damage:
		if d[0] == f:
			s += d[1]
	return s
