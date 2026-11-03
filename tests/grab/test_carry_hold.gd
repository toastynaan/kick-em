extends Node3D
## Round 7 (Grab, drive and throw: "Holding"):
## - the held body is a partial ragdoll held by the collar, upright in front;
##   while the holder walks (straight, then a slalom) the legs keep swinging
##   (mean leg angular speed per 0.1 s window, logged) and the body stays with
##   the hand;
## - moving while holding: walk x0.7 (measured through Traversal), nothing is
##   vaulted with a body (vault limit 0);
## - R7_HOLD_MAX: the victim struggles out (both stumble); a held corpse never does;
## - driving resets the hold clock: 2 s of hold, a 1.5 s drive, and the hold
##   still lasts R7_HOLD_MAX after the drive ended;
## - a hit on the holder drops the body (a wind-up in progress ends: throw_windup
##   0, no throw); Grab releases it (lands on its feet and stumbles).
## OWNER: agent G.

const LEG_SPIN_MIN := 0.6       ## rad/s mean leg angular speed every 0.1 s window while walking
const BODY_FOLLOW := 1.3        ## m: the body's chest stays this close to the hand

var _fail: Array[String] = []
var _events: Array = []

func _ready() -> void:
	get_tree().create_timer(150.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	Carry.force_enabled = true
	for sig: StringName in [&"grab_broken", &"carry_changed", &"throw_windup", &"drive_started", &"drive_ended"]:
		var s := sig
		GameEvents.connect(s, func(a = null, b = null, c = null) -> void:
			_events.append([s, a, b, c]))
	GrabTestUtil.make_floor(self, 400.0)
	await get_tree().physics_frame
	await _walk_legs()
	await _multipliers()
	await _struggle()
	await _corpse()
	await _drive_resets_clock()
	await _hit_drops()
	await _release()
	_finish()

func _pair(dist := 1.0) -> Array:
	GrabTestUtil.reset_world()
	_events.clear()
	var p := GrabTestUtil.spawn(self, &"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := GrabTestUtil.spawn(self, &"grunt", Vector3(0.0, 0.0, -dist), Vector3.BACK)
	await GrabTestUtil.frames(self, 20)
	return [p, e]

func _hold(p: Fighter, e: Fighter) -> bool:
	var ok := p.carry.grab_now(e, &"", true)
	await GrabTestUtil.wait(self, 0.25)
	return ok and p.carry.is_holding_body()

func _clear(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	await GrabTestUtil.frames(self, 4)

func _count(sig: StringName) -> int:
	return _events.filter(func(ev: Array) -> bool: return ev[0] == sig).size()

static func _call_bool(o: Object, m: StringName) -> bool:
	return o != null and o.has_method(m) and bool(o.call(m))

static func _off_balance(f: Fighter) -> bool:
	return _call_bool(f.combat, &"is_stumbling") or f.get_state() != RagdollController.State.ANIMATED \
		or f.is_in_hitstun() or f.is_reacting()

## Walk with the body: 1.0 s straight, then a slalom (the stick swings +-50
## degrees every 0.35 s). Logs the legs' mean angular speed per 0.1 s.
func _walk_legs() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	_check(await _hold(p, e), "holding the grunt by the collar")
	var motor := "ragdoll motor" if p.carry.uses_ragdoll_motor() else "fallback pin"
	var windows: Array[float] = []
	var straight: Array[float] = []
	var follow_max := 0.0
	var tilt_max := 0.0
	var tilt_slalom := 0.0
	var acc := 0.0
	var n := 0
	var t := 0.0
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	while t < 2.1 and p.carry.is_holding_body():
		var dir := Vector3.FORWARD
		if t >= 1.0:
			var k := 1.0 if int((t - 1.0) / 0.35) % 2 == 0 else -1.0
			dir = Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(50.0) * k)
		p.move_input = dir
		p.face_dir = dir
		await get_tree().physics_frame
		t += dt
		acc += GrabTestUtil.leg_spin(e)
		n += 1
		follow_max = maxf(follow_max, e.rig.get_bone_global_position(Bones.CHEST).distance_to(p.carry.get_hand().global_position))
		var hp: Vector3 = PhysicsServer3D.body_get_state(e.rig.get_physical_bone(Bones.HIPS).get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM).origin
		var cp: Vector3 = PhysicsServer3D.body_get_state(e.rig.get_physical_bone(Bones.CHEST).get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM).origin
		var tilt := rad_to_deg((cp - hp).normalized().angle_to(Vector3.UP))
		if t > 0.3 and t < 1.0:
			tilt_max = maxf(tilt_max, tilt)
		elif t >= 1.0:
			tilt_slalom = maxf(tilt_slalom, tilt)
		if n >= 12:
			(straight if t < 1.0 else windows).append(acc / n)
			acc = 0.0
			n = 0
	p.move_input = Vector3.ZERO
	var min_w: float = windows.min() if not windows.is_empty() else 0.0
	var min_s: float = straight.slice(2).min() if straight.size() > 2 else 0.0
	print("[legs] %s; straight walk leg spin per 0.1 s: %s" % [motor,
		", ".join(straight.map(func(x: float) -> String: return "%.2f" % x))])
	print("[legs] slalom leg spin per 0.1 s: %s" % ", ".join(windows.map(func(x: float) -> String: return "%.2f" % x)))
	print("[legs] min window straight %.2f rad/s (after 0.2 s), slalom %.2f rad/s; chest-to-hand max %.2f m; torso tilt max %.0f deg walking straight, %.0f deg in the slalom" % [
		min_s, min_w, follow_max, tilt_max, tilt_slalom])
	_check(not windows.is_empty() and min_w > LEG_SPIN_MIN, "the held legs keep moving while walking (every window > %.1f rad/s)" % LEG_SPIN_MIN)
	_check(follow_max < BODY_FOLLOW, "the body stays with the hand")
	_check(tilt_max < 30.0, "the collar-held body is upright walking straight (torso within 30 degrees)")
	p.carry.drop(&"release")
	await _clear(pr)

func _multipliers() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	_check(is_equal_approx(p.carry.get_move_speed_mult(), 1.0) and is_equal_approx(p.carry.get_sprint_cap_mult(), 1.0),
		"empty-handed: no change")
	await _hold(p, e)
	print("[mult] holding: walk x%.2f, sprint cap x%.2f, vault %.2f m" % [p.carry.get_move_speed_mult(),
		p.carry.get_sprint_cap_mult(), p.carry.get_vault_max_height()])
	_check(is_equal_approx(p.carry.get_move_speed_mult(), Tuning.HOLD_WALK_MULT), "walk at 70%")
	_check(is_zero_approx(p.carry.get_vault_max_height()), "nothing is vaulted with a body in hand")
	if p.traversal != null:
		p.move_input = Vector3.FORWARD
		p.face_dir = Vector3.FORWARD
		await GrabTestUtil.wait(self, 0.7)
		var walk := GrabTestUtil.hspeed(p)
		p.move_input = Vector3.ZERO
		print("[mult] measured walk %.2f m/s (%.0f%% of %.1f)" % [walk, 100.0 * walk / Tuning.WALK_SPEED, Tuning.WALK_SPEED])
		_check(absf(walk - Tuning.WALK_SPEED * Tuning.HOLD_WALK_MULT) < 0.35, "walking with a body: 70% speed")
	p.carry.drop(&"release")
	await _clear(pr)

func _struggle() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var t0 := TimeDirector.now()
	await _hold(p, e)
	await GrabTestUtil.wait_until(self, func() -> bool: return not p.carry.is_holding(), Tuning.R7_HOLD_MAX + 1.0)
	var held_for := TimeDirector.now() - t0
	await GrabTestUtil.frames(self, 2)
	var p_off := _off_balance(p)
	var e_free := not e.carry.is_held()
	var e_off := _off_balance(e)
	print("[struggle] held %.2f s (R7_HOLD_MAX %.1f): reason %s, holder off balance=%s, victim free=%s state %s off balance=%s" % [
		held_for, Tuning.R7_HOLD_MAX, p.carry.last_drop_reason, p_off, e_free, GrabTestUtil.state_name(e), e_off])
	_check(absf(held_for - Tuning.R7_HOLD_MAX) < 0.15 and p.carry.last_drop_reason == &"struggle",
		"the victim struggles out after R7_HOLD_MAX")
	_check(p_off and e_free and e_off and _count(&"grab_broken") == 1, "both stumble")
	await _clear(pr)

func _corpse() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	e.apply_damage(e.hp + 1.0, &"test")
	await GrabTestUtil.wait(self, 1.0)
	p.carry.grab_now(e, &"", true)
	await GrabTestUtil.wait(self, Tuning.R7_HOLD_MAX + 0.5)
	print("[corpse] held a corpse %.1f s: still holding=%s" % [Tuning.R7_HOLD_MAX + 0.5, p.carry.is_holding_body()])
	_check(p.carry.is_holding_body(), "a corpse never struggles out")
	p.carry.drop(&"release")
	await _clear(pr)

## 2 s of hold, a 1.5 s drive, then the hold still lasts R7_HOLD_MAX.
func _drive_resets_clock() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	await _hold(p, e)
	await GrabTestUtil.wait(self, 2.0 - 0.25)
	var clock_before := p.carry.get_hold_time()
	p.carry.on_drive_pressed(TimeDirector.now())   # the routing itself is test_drive_yard's (real input)
	var driving := await GrabTestUtil.wait_until(self, func() -> bool: return p.carry.is_driving(), 0.2)
	await GrabTestUtil.wait(self, 1.5)
	var clock_driving := p.carry.get_hold_time()
	p.carry.on_drive_released(TimeDirector.now())
	await GrabTestUtil.frames(self, 2)
	var ended := not p.carry.is_driving()
	var t_end := TimeDirector.now()
	var held := await GrabTestUtil.wait_until(self, func() -> bool: return not p.carry.is_holding(), Tuning.R7_HOLD_MAX + 1.0)
	var after := TimeDirector.now() - t_end
	print("[clock] hold clock %.2f s before the drive, %.2f s while driving (%s), drive ended on release=%s (%s), hold lasted %.2f s more, reason %s" % [
		clock_before, clock_driving, "driving" if driving else "NOT driving",
		ended, p.carry.last_drive_end, after, p.carry.last_drop_reason])
	_check(driving and clock_driving < 0.05, "driving resets the hold clock")
	_check(ended and p.carry.last_drive_end == &"release" and _count(&"drive_ended") == 1, "releasing Dash ends the drive, the hold stays")
	_check(held and absf(after - Tuning.R7_HOLD_MAX) < 0.2 and p.carry.last_drop_reason == &"struggle",
		"the hold lasts R7_HOLD_MAX again after the drive")
	await _clear(pr)

func _hit_drops() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var other := GrabTestUtil.spawn(self, &"grunt", Vector3(1.0, 0.0, 0.5), Vector3.LEFT)
	await GrabTestUtil.frames(self, 5)
	await _hold(p, e)
	# Winding up a throw when the hit lands: the wind-up ends without a throw.
	GrabTestUtil.press(p, CombatController.Action.LIGHT)
	await GrabTestUtil.wait(self, 0.4)
	var was := p.carry.get_throw_windup()
	var info := HitInfo.new()
	info.attacker = other
	info.victim = p
	info.move_id = &"e_jab"
	info.kind = &"strike"
	info.tier = HitInfo.Tier.FLINCH
	info.reaction = HitInfo.Reaction.FLINCH
	info.damage = 10.0
	info.hit_direction = Vector3.LEFT
	info.hit_position = p.get_aim_point()
	info.unblockable = true
	var r := p.take_hit(info)
	await GrabTestUtil.frames(self, 3)
	GrabTestUtil.release(p, CombatController.Action.LIGHT)
	var wind: Array = _events.filter(func(ev: Array) -> bool: return ev[0] == &"throw_windup" and ev[1] == p)
	var last_amount: float = wind.back()[2] if not wind.is_empty() else -1.0
	print("[hit] holder hit while winding up (%.2f, result %d): holding=%s reason=%s victim held=%s, last throw_windup %.2f, thrown=%s" % [
		was, r, p.carry.is_holding(), p.carry.last_drop_reason, e.carry.is_held(), last_amount, p.carry.last_throw_velocity])
	_check(not p.carry.is_holding() and p.carry.last_drop_reason == &"hit" and not e.carry.is_held(),
		"a hit on the holder drops the body")
	_check(was > 0.0 and is_zero_approx(last_amount) and p.carry.get_throw_windup() == 0.0
		and p.carry.last_throw_velocity == Vector3.ZERO, "the cut wind-up ends at throw_windup 0, no throw")
	await _clear(pr + [other])

func _release() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	await _hold(p, e)
	await GrabTestUtil.wait(self, 0.3)
	GrabTestUtil.press(p, CombatController.Action.GRAB)
	GrabTestUtil.release(p, CombatController.Action.GRAB)
	await GrabTestUtil.frames(self, 3)
	var st := GrabTestUtil.state_name(e)
	var ahead := (e.get_ground_position() - p.global_position).dot(p.get_forward())
	var stumbling := _off_balance(e) and e.get_state() != RagdollController.State.LAUNCHED
	print("[release] Grab while holding: holding=%s victim %s %.2f m in front, stumbling=%s" % [p.carry.is_holding(), st, ahead, stumbling])
	_check(not p.carry.is_holding() and not e.carry.is_held(), "Grab releases the body")
	_check(stumbling and ahead > 0.2, "the collar-held body is dropped in front, lands and stumbles")
	await GrabTestUtil.wait(self, 2.5)
	print("[release] 2.5 s later the victim is %s" % GrabTestUtil.state_name(e))
	_check(e.get_state() == RagdollController.State.ANIMATED, "the released victim is back on its feet")
	await _clear(pr)

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	Carry.force_enabled = false
	if _fail.is_empty():
		print("PASS test_carry_hold")
		get_tree().quit(0)
	else:
		print("FAIL test_carry_hold: ", _fail)
		get_tree().quit(1)
