extends Node3D
## Round 5 (Feel Reference: Actions while holding), through CombatController's
## attack routing into Carry:
## - Light on the ground: up to 3 knees (the third a headbutt), each a
##   flinch-tier hit for Power.strike_damage(&"knee"), the hold kept;
## - Heavy tap: throw along the stick at 6 m/s + half the run speed;
## - Heavy held: charge levels in real time -> 6 / 9 / 12 m/s, capped at 16;
## - arm grab: the throw spins the body (twisting throw);
## - leg grab: Heavy trips the body in place (knockdown);
## - an attack in the air: body slam, the victim knocked down under you,
##   body_slammed, and a shockwave that stumbles a bystander 2 m away.
## OWNER: agent G.

var _fail: Array[String] = []
var _hits: Array[HitInfo] = []
var _events: Array = []

func _ready() -> void:
	get_tree().create_timer(150.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	Carry.force_enabled = true
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void: _hits.append(info))
	for sig: StringName in [&"thrown", &"body_slammed", &"shockwave", &"charge_level_changed", &"tripped"]:
		var s := sig
		GameEvents.connect(s, func(a = null, b = null, c = null, d = null) -> void:
			_events.append([s, a, b, c, d]))
	GrabTestUtil.make_floor(self)
	await get_tree().physics_frame
	await _knees()
	await _tap_throw(false)
	await _tap_throw(true)
	for level in [1, 2, 3]:
		await _charged_throw(level)
	await _twist()
	await _trip()
	await _slam()
	_finish()

func _pair(part := &"") -> Array:
	GrabTestUtil.reset_world()
	_hits.clear()
	_events.clear()
	var p := GrabTestUtil.spawn(self, &"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := GrabTestUtil.spawn(self, &"grunt", Vector3(0.0, 0.0, -1.0), Vector3.BACK)
	await GrabTestUtil.frames(self, 20)
	p.carry.grab_now(e, part, true)
	await GrabTestUtil.wait(self, 0.3)
	return [p, e]

func _clear(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	await GrabTestUtil.frames(self, 4)

func _count(sig: StringName) -> int:
	return _events.filter(func(ev: Array) -> bool: return ev[0] == sig).size()

func _knees() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var hp0 := e.hp
	for i in 4:
		await GrabTestUtil.tap(self, p, CombatController.Action.LIGHT, 0.03)
		await GrabTestUtil.wait(self, 0.4)
	var knees := _hits.filter(func(h: HitInfo) -> bool: return h.victim == e and h.move_id in [&"held_knee", &"headbutt"])
	var desc := ", ".join(knees.map(func(h: HitInfo) -> String:
		return "%s %s %.0f dmg" % [h.move_id, HitInfo.tier_name(h.tier), h.damage]))
	print("[knees] 4 Light presses -> %d hits: %s; hp %.0f -> %.0f; still holding=%s" % [knees.size(), desc, hp0, e.hp,
		p.carry.is_holding_body()])
	_check(knees.size() == Tuning.HOLD_KNEES_MAX, "up to 3 knees per hold")
	var all_flinch := true
	for h: HitInfo in knees:
		all_flinch = all_flinch and h.tier == HitInfo.Tier.FLINCH and is_equal_approx(h.damage, Power.strike_damage(&"knee", 0))
	_check(all_flinch, "each a flinch-tier hit, knee damage")
	_check(knees.size() == 3 and (knees[2] as HitInfo).move_id == &"headbutt", "the third is a headbutt")
	_check(p.carry.is_holding_body(), "the knees keep the hold")
	p.carry.drop(&"release")
	await _clear(pr)

func _tap_throw(walking: bool) -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var run := 0.0
	if walking:
		p.move_input = Vector3.FORWARD
		p.face_dir = Vector3.FORWARD
		await GrabTestUtil.wait(self, 0.6)
		# The throw reads the earned speed toward it (Traversal.speed_toward).
		run = p.traversal.speed_toward(Vector3.FORWARD) if p.traversal else Vector2(p.velocity.x, p.velocity.z).length()
	await GrabTestUtil.tap(self, p, CombatController.Action.HEAVY, 0.05)
	p.move_input = Vector3.ZERO
	await GrabTestUtil.frames(self, 2)
	var v := p.carry.last_throw_velocity
	var com_v := e.get_com_velocity()
	var want := Power.throw_speed(0, run)
	print("[tap] %s throw: run %.2f m/s -> %.2f m/s (want %.2f), flat dir %s, victim %s COM %.2f m/s, thrown events %d" % [
		"walking" if walking else "standing", run, v.length(), want, Vector3(v.x, 0, v.z).normalized().snapped(Vector3.ONE * 0.01),
		GrabTestUtil.state_name(e), com_v.length(), _count(&"thrown")])
	_check(absf(v.length() - want) < 0.25, "tap throw at 6 m/s + half the run speed")
	_check(Vector3(v.x, 0, v.z).normalized().dot(Vector3.FORWARD) > 0.95, "along the stick / facing")
	_check(e.is_launched() and absf(com_v.length() - want) < 1.2 and _count(&"thrown") == 1, "the body flies (thrown)")
	await GrabTestUtil.wait(self, 0.3)
	await _clear(pr)

func _charged_throw(level: int) -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	GrabTestUtil.press(p, CombatController.Action.HEAVY)
	await GrabTestUtil.wait(self, Tuning.CHARGE_LEVELS[level - 1] + 0.04)
	var charging := p.carry.is_charging()
	var reached := p.carry.get_charge_level()
	GrabTestUtil.release(p, CombatController.Action.HEAVY)
	await GrabTestUtil.frames(self, 2)
	var v := p.carry.last_throw_velocity
	var want := Power.throw_speed(level, 0.0)
	print("[charge] held %.2f s: charging=%s level %d -> %.2f m/s (want %.2f), level events %d" % [
		Tuning.CHARGE_LEVELS[level - 1] + 0.04, charging, reached, v.length(), want, _count(&"charge_level_changed")])
	_check(charging and reached == level and p.carry.last_throw_level == level, "charge level %d in real time" % level)
	_check(absf(v.length() - want) < 0.25, "charged throw level %d at %.0f m/s" % [level, want])
	_check(e.is_launched(), "the body flies")
	await GrabTestUtil.wait(self, 0.3)
	await _clear(pr)

func _twist() -> void:
	var pr: Array = await _pair(&"arm")
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var part := p.carry.get_held_part()
	await GrabTestUtil.tap(self, p, CombatController.Action.HEAVY, 0.05)
	await GrabTestUtil.frames(self, 2)
	var axis := Vector3(p.carry.last_throw_velocity.x, 0.0, p.carry.last_throw_velocity.z).normalized()
	var spin := 0.0
	for b: StringName in [Bones.CHEST, Bones.SPINE, Bones.HIPS]:
		var av: Vector3 = PhysicsServer3D.body_get_state(e.rig.get_physical_bone(b).get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		spin += absf(av.dot(axis)) / 3.0
	print("[twist] %s grab throw: torso spin about the flight line %.1f rad/s" % [part, spin])
	_check(part == &"arm" and spin > Carry.TWIST_SPIN * 0.5, "an arm grab's throw spins the body")
	await GrabTestUtil.wait(self, 0.3)
	await _clear(pr)

func _trip() -> void:
	var pr: Array = await _pair(&"leg")
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var part := p.carry.get_held_part()
	var c0 := e.get_center_of_mass()
	GrabTestUtil.press(p, CombatController.Action.HEAVY)
	await GrabTestUtil.frames(self, 2)
	GrabTestUtil.release(p, CombatController.Action.HEAVY)
	var trip := _hits.filter(func(h: HitInfo) -> bool: return h.victim == e and h.move_id == &"leg_trip")
	await GrabTestUtil.wait(self, 1.0)
	var moved := Vector2(e.get_center_of_mass().x - c0.x, e.get_center_of_mass().z - c0.z).length()
	print("[trip] %s grab + Heavy: %d trip hits (%s, %.0f dmg), victim %s, moved %.2f m, thrown=%d" % [part, trip.size(),
		HitInfo.tier_name((trip[0] as HitInfo).tier) if trip.size() > 0 else "-",
		(trip[0] as HitInfo).damage if trip.size() > 0 else 0.0, GrabTestUtil.state_name(e), moved, _count(&"thrown")])
	_check(part == &"leg" and trip.size() == 1 and (trip[0] as HitInfo).tier == HitInfo.Tier.KNOCKDOWN,
		"a leg grab's Heavy trips the body (knockdown)")
	_check(e.is_down() and moved < 1.0 and _count(&"thrown") == 0, "in place, not thrown")
	await _clear(pr)

func _slam() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var by := GrabTestUtil.spawn(self, &"grunt", Vector3(2.0, 0.0, 0.0), Vector3.LEFT)
	await GrabTestUtil.frames(self, 10)
	var jumped := p.traversal.on_jump_pressed() if p.traversal else false
	if not jumped:
		jumped = p.jump()
	await GrabTestUtil.wait(self, 0.18)
	var air := p.carry.call(&"_in_air") as bool
	await GrabTestUtil.tap(self, p, CombatController.Action.LIGHT, 0.03)
	var slamming := p.carry.is_slamming()
	await GrabTestUtil.wait_until(self, func() -> bool: return _count(&"body_slammed") > 0, 1.5)
	await GrabTestUtil.frames(self, 4)
	var slam := _hits.filter(func(h: HitInfo) -> bool: return h.victim == e and h.move_id == &"body_slam")
	var by_hits := _hits.filter(func(h: HitInfo) -> bool: return h.victim == by)
	var by_desc := ", ".join(by_hits.map(func(h: HitInfo) -> String: return "%s %s" % [h.move_id, HitInfo.tier_name(h.tier)]))
	print("[slam] jumped=%s in air=%s slamming=%s -> body_slammed %d, victim hit %s, victim %s, shockwaves %d, bystander (2 m): %s" % [
		jumped, air, slamming, _count(&"body_slammed"),
		HitInfo.tier_name((slam[0] as HitInfo).tier) if slam.size() > 0 else "-", GrabTestUtil.state_name(e),
		_count(&"shockwave"), by_desc if by_desc != "" else "nothing"])
	_check(jumped and slamming, "an attack in the air with a body starts a body slam")
	_check(_count(&"body_slammed") == 1 and slam.size() == 1 and (slam[0] as HitInfo).tier == HitInfo.Tier.KNOCKDOWN,
		"landing knocks the victim down (body_slammed)")
	_check(_count(&"shockwave") >= 1 and by_hits.size() >= 1, "the heavy-landing shockwave reaches a bystander 2 m away")
	await GrabTestUtil.wait(self, 0.3)
	await _clear(pr + [by])

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	Carry.force_enabled = false
	if _fail.is_empty():
		print("PASS test_carry_actions")
		get_tree().quit(0)
	else:
		print("FAIL test_carry_actions: ", _fail)
		get_tree().quit(1)
