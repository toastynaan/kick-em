extends "res://tests/input/input_test_base.gd"
## Round 4 lock-on, player side, through the real PlayerController and Input:
## locked, the fighter faces the target (dot > 0.95 throughout), W closes in,
## S backs off at Fighter.LOCK_BACK_MULT still facing it, A/D circle it at a
## steady distance (+-0.5 m over 2 s) at Fighter.LOCK_STRAFE_MULT; unlock and
## retarget turn at PlayerController.LOCK_TURN_RATE (no snap); unlocked
## movement still faces where it goes.
## Uses the real CameraRig when it has get_lock_target() (locks with real
## lock_on / lock_next input events), else tests/input/stand_in_lock_rig.gd.

const STAND_IN := "res://tests/input/stand_in_lock_rig.gd"

var rig: Node3D
var real_rig := false
var _min_dot := 1.0
## Per-tick yaw step tracker (runs before the fighters each tick: parent first).
var _track: Fighter
var _track_prev := 0.0
var _track_max := 0.0

func _physics_process(_delta: float) -> void:
	if _track == null:
		return
	_track_max = maxf(_track_max, absf(wrapf(_track.rotation.y - _track_prev, -PI, PI)))
	_track_prev = _track.rotation.y

func _start_track(p: Fighter) -> void:
	_track = p
	_track_prev = p.rotation.y
	_track_max = 0.0

func run() -> void:
	var p := spawn_player(Vector3(0, 0, 4))
	var a := spawn_dummy(&"grunt", Vector3(0, 0, 0), Vector3.BACK)
	var b := spawn_dummy(&"grunt", Vector3(3, 0, -4), Vector3.BACK)  # north of A: off the orbit, in lock range
	AttackDirector.set_player(p)
	rig = _make_rig(p)
	await ticks(60)
	print("  NOTE using %s" % ("the real CameraRig" if real_rig else "the stand-in lock rig (E's get_lock_target() not in yet)"))

	await _lock(a)
	check(_lock_target() == a, "locked on enemy A")
	check((p.brain as PlayerController).get_lock_target() == a and p.lock_target == a, "player side sees the lock")
	await ticks(60)
	check(_dot(p, a) > 0.95, "locked: facing A (dot %.3f)" % _dot(p, a))

	# W closes in.
	var d0 := _dist(p, a)
	_min_dot = 1.0
	await _hold(&"move_forward", 40, p, a)
	var d1 := _dist(p, a)
	check(d1 < d0 - 1.0, "W closes in: %.2f -> %.2f m" % [d0, d1])
	check(_min_dot > 0.95, "W: facing dot >= %.3f" % _min_dot)
	await _stop(p)

	# S backs off, still facing it, at the backpedal speed.
	d0 = _dist(p, a)
	_min_dot = 1.0
	var sp := await _hold(&"move_back", 90, p, a)
	d1 = _dist(p, a)
	check(d1 > d0 + 1.5, "S backs off: %.2f -> %.2f m" % [d0, d1])
	check(near(sp, Tuning.WALK_SPEED * Fighter.LOCK_BACK_MULT, 0.06), "backpedal %.2f m/s (want %.2f)" % [sp, Tuning.WALK_SPEED * Fighter.LOCK_BACK_MULT])
	check(_min_dot > 0.95, "S: facing dot >= %.3f" % _min_dot)
	await _stop(p)

	# A and D circle it at a steady distance.
	for act: StringName in [&"move_left", &"move_right"]:
		d0 = _dist(p, a)
		var ang0 := _angle(p, a)
		_min_dot = 1.0
		var lo := INF
		var hi := 0.0
		press(act)
		var t0 := TimeDirector.now()
		var path := 0.0
		var last := p.global_position
		while TimeDirector.now() - t0 < 2.0:
			await get_tree().physics_frame
			var d := _dist(p, a)
			lo = minf(lo, d)
			hi = maxf(hi, d)
			_min_dot = minf(_min_dot, _dot(p, a))
			path += Vector2(p.global_position.x - last.x, p.global_position.z - last.z).length()
			last = p.global_position
		release(act)
		var swept := absf(wrapf(_angle(p, a) - ang0, -PI, PI))
		check(lo > d0 - 0.5 and hi < d0 + 0.5, "%s orbits: distance %.2f..%.2f m (start %.2f)" % [act, lo, hi, d0])
		check(swept > deg_to_rad(60.0), "%s moves around the target (%.0f deg)" % [act, rad_to_deg(swept)])
		check(near(path / 2.0, Tuning.WALK_SPEED * Fighter.LOCK_STRAFE_MULT, 0.08), "%s strafe %.2f m/s (want %.2f)" % [act, path / 2.0, Tuning.WALK_SPEED * Fighter.LOCK_STRAFE_MULT])
		check(_min_dot > 0.95, "%s: facing dot >= %.3f" % [act, _min_dot])
		await _stop(p)

	# Retarget: no snap, the facing turns at the cap.
	var cap := PlayerController.LOCK_TURN_RATE / float(Engine.physics_ticks_per_second)
	var max_step := await _retarget_steps(p, b)
	check(_lock_target() == b, "lock moved to enemy B")
	check(max_step <= cap * 1.05, "retarget turns at most %.3f rad/tick (max %.3f)" % [cap, max_step])
	check(_dot(p, b) > 0.95, "now facing B (dot %.3f)" % _dot(p, b))

	# Unlock: no snap either; then movement facing is back (faces where it walks).
	_start_track(p)
	await _unlock()
	check(_lock_target() == null and p.lock_target == null, "unlocked")
	press(&"move_back")
	await ticks(60)
	max_step = _track_max
	_track = null
	var walk_dir := Vector3(p.velocity.x, 0.0, p.velocity.z).normalized()
	release(&"move_back")
	check(max_step <= cap * 1.05, "after unlock the turn is capped (max %.3f rad/tick)" % max_step)
	check(p.get_forward().dot(walk_dir) > 0.95, "unlocked: faces where it walks (dot %.3f)" % p.get_forward().dot(walk_dir))
	check(p.max_turn_rate == INF, "turn cap lifted once caught up")
	done()

func _make_rig(p: Fighter) -> Node3D:
	var probe := CameraRig.new()
	real_rig = probe.has_method(&"get_lock_target")
	probe.free()
	var r: Node3D
	if real_rig:
		var cr := CameraRig.new()
		cr.target = p
		r = cr
	else:
		r = Node3D.new()
		r.set_script(load(STAND_IN))
		r.set(&"target", p)
	add_child(r)
	return r

func _lock_target() -> Fighter:
	return rig.call(&"get_lock_target") as Fighter

func _lock(f: Fighter) -> void:
	if not real_rig:
		rig.call(&"set_lock", f)
		await ticks(2)
		return
	for i in 4:
		if _lock_target() == f:
			return
		await tap_action(&"lock_on")
		await ticks(10)

func _unlock() -> void:
	if not real_rig:
		rig.call(&"set_lock", null)
		await ticks(2)
		return
	if _lock_target() != null:
		await tap_action(&"lock_on")
		await ticks(10)

## Switch the lock to `f` and return the largest per-tick yaw step while turning.
func _retarget_steps(p: Fighter, f: Fighter) -> float:
	_start_track(p)
	if real_rig:
		for i in 4:
			if _lock_target() == f:
				break
			await tap_action(&"lock_next")
			await ticks(6)
	else:
		rig.call(&"set_lock", f)
	await ticks(90)
	_track = null
	return _track_max

## Hold `act` for n ticks, tracking the facing dot; returns the speed over the
## last half (m/s).
func _hold(act: StringName, n: int, p: Fighter, t: Fighter) -> float:
	press(act)
	var mid := Vector3.ZERO
	for i in n:
		await get_tree().physics_frame
		_min_dot = minf(_min_dot, _dot(p, t))
		if i == n >> 1:
			mid = p.global_position
	release(act)
	var end := p.global_position
	return Vector2(end.x - mid.x, end.z - mid.z).length() / ((n - (n >> 1) - 1) / float(Engine.physics_ticks_per_second))

func _stop(p: Fighter) -> void:
	await wait_until(func() -> bool: return Vector2(p.velocity.x, p.velocity.z).length() < 0.05, 120)
	await ticks(5)

func _dist(p: Fighter, t: Fighter) -> float:
	var d := t.global_position - p.global_position
	return Vector2(d.x, d.z).length()

func _angle(p: Fighter, t: Fighter) -> float:
	var d := p.global_position - t.global_position
	return atan2(d.x, d.z)

func _dot(p: Fighter, t: Fighter) -> float:
	var d := t.global_position - p.global_position
	d.y = 0.0
	return p.get_forward().dot(d.normalized()) if d.length_squared() > 1e-4 else 1.0
