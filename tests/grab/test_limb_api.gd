extends Node3D
## LimbGrab API rules: can_grip refusals, break window (x Tuning.ARM_DRAG_BREAK_MULT
## for arms), grip lookup, break_free, drop when the grabber goes down, release
## by itself after HOLD_MAX, the victim gets up again, collision exceptions and
## masses restored, and a swing into a wall stops or slips without exploding.
## OWNER: agent G.

const EXPLODE_SPEED := 40.0

var _fail: Array[String] = []
var _released: Array = []
var _started := 0

func _ready() -> void:
	get_tree().create_timer(90.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	GameEvents.limb_grab_started.connect(func(_g: Node3D, _v: Node3D, _b: StringName) -> void:
		_started += 1)
	GameEvents.limb_grab_released.connect(func(g: Node3D, v: Node3D, vel: Vector3) -> void:
		_released.append([g, v, vel]))
	GrabTestUtil.make_floor(self)
	await get_tree().physics_frame
	await _rules()
	await _break_and_recover()
	await _grabber_down_and_timeout()
	await _wall(-1.2)
	await _wall(-0.8)
	_finish()

func _pair(victim_pos := Vector3(0.0, 0.0, -1.0)) -> Array:
	var g := GrabTestUtil.spawn(self, &"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var v := GrabTestUtil.spawn(self, &"grunt", victim_pos, -victim_pos)
	for i in 15:
		await get_tree().physics_frame
	return [g, v]

func _clear(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	for i in 3:
		await get_tree().physics_frame

func _rules() -> void:
	var p: Array = await _pair()
	var g: Fighter = p[0]
	var v: Fighter = p[1]
	_check(not LimbGrab.can_grip(g, v, BodyZones.Zone.TORSO), "torso is not a limb grab")
	_check(not LimbGrab.can_grip(g, v, BodyZones.Zone.HEAD), "head is not a limb grab")
	_check(not LimbGrab.can_grip(g, g, BodyZones.Zone.ARM_R), "no limb grab on yourself")
	_check(LimbGrab.can_grip(g, v, BodyZones.Zone.ARM_R) and LimbGrab.can_grip(g, v, BodyZones.Zone.ARM_L),
		"both arms grippable on a standing enemy")
	var far := GrabTestUtil.spawn(self, &"grunt", Vector3(0.0, 0.0, -4.0), Vector3.BACK)
	await get_tree().physics_frame
	_check(not LimbGrab.can_grip(g, far, BodyZones.Zone.ARM_R), "out of reach (4 m) refused")
	var w := LimbGrab.break_window(BodyZones.Zone.ARM_R)
	_check(is_equal_approx(w.x, Tuning.GRAB_BREAK_EARLY * Tuning.ARM_DRAG_BREAK_MULT)
		and is_equal_approx(w.y, Tuning.GRAB_BREAK_LATE * Tuning.ARM_DRAG_BREAK_MULT), "arm drag break window x ARM_DRAG_BREAK_MULT")
	var wl := LimbGrab.break_window(BodyZones.Zone.LEGS)
	_check(is_equal_approx(wl.x, Tuning.GRAB_BREAK_EARLY) and is_equal_approx(wl.y, Tuning.GRAB_BREAK_LATE), "leg grab keeps the torso break window")
	var lg := LimbGrab.start(g, v, BodyZones.Zone.ARM_L)
	_check(lg != null and lg.bone == Bones.L_LOWER_ARM, "left arm drag holds LeftLowerArm")
	if lg:
		_check(LimbGrab.get_grip_on(v) == lg and LimbGrab.get_grip_by(g) == lg, "get_grip_on / get_grip_by find it")
		_check(not LimbGrab.can_grip(g, v, BodyZones.Zone.ARM_R), "a second grip on the same pair is refused")
		var now := TimeDirector.now()
		_check(lg.in_break_window(now), "press right after the grip is in the break window")
		_check(not lg.in_break_window(lg.start_time + Tuning.GRAB_BREAK_LATE), "press at GRAB_BREAK_LATE is too late for an arm drag")
		_check(lg.in_break_window(lg.start_time + Tuning.GRAB_BREAK_LATE * Tuning.ARM_DRAG_BREAK_MULT - 0.001), "press inside the shorter window breaks")
		lg.drop()
		_check(not lg.is_active() and LimbGrab.get_grip_on(v) == null, "drop() ends it")
	await _clear([far])
	# Severed forearm: that arm can no longer be gripped.
	for i in 90:
		await get_tree().physics_frame
	v.rig.sever(&"forearm_r")
	await get_tree().physics_frame
	_check(not LimbGrab.can_grip(g, v, BodyZones.Zone.ARM_R), "severed forearm refused")
	v.apply_damage(v.hp + 10.0, &"test")
	_check(not LimbGrab.can_grip(g, v, BodyZones.Zone.ARM_L), "dead enemy refused")
	await _clear([g, v])

func _break_and_recover() -> void:
	var p: Array = await _pair()
	var g: Fighter = p[0]
	var v: Fighter = p[1]
	_released.clear()
	var lg := LimbGrab.start(g, v, BodyZones.Zone.ARM_R)
	_check(lg != null, "arm drag for break_free")
	if lg == null:
		await _clear([g, v])
		return
	_check(v.ragdoll.is_gripped() and v.get_state() == RagdollController.State.LAUNCHED, "victim gripped (RagdollController.set_gripped) and LAUNCHED while held")
	var bone_rid := v.rig.get_physical_bone(Bones.CHEST).get_rid()
	_check(g.get_collision_exceptions().any(func(o: Object) -> bool: return o is PhysicalBone3D and (o as PhysicalBone3D).get_rid() == bone_rid),
		"victim bones ignore the grabber's capsule while held")
	for i in 30:
		await get_tree().physics_frame
	lg.break_free()
	_check(not lg.is_active(), "break_free() ends it")
	_check(_released.size() == 1 and (_released[0][2] as Vector3) == Vector3.ZERO, "break_free emits limb_grab_released with ZERO")
	_check(not v.ragdoll.is_gripped(), "set_gripped(false) on break_free")
	var t0 := TimeDirector.now()
	while v.get_state() != RagdollController.State.ANIMATED and TimeDirector.now() - t0 < 8.0:
		await get_tree().physics_frame
	_check(v.get_state() == RagdollController.State.ANIMATED, "victim gets up after the grab (%.1f s)" % (TimeDirector.now() - t0))
	var vb := v.rig.get_physical_bones()
	_check(not g.get_collision_exceptions().any(func(o: Object) -> bool: return vb.has(o)),
		"capsule exceptions removed after the release")
	await _clear([g, v])

func _grabber_down_and_timeout() -> void:
	var p: Array = await _pair()
	var g: Fighter = p[0]
	var v: Fighter = p[1]
	_released.clear()
	var lg := LimbGrab.start(g, v, BodyZones.Zone.ARM_R)
	for i in 20:
		await get_tree().physics_frame
	g.launch(Vector3(0.0, 2.0, 3.0), g.get_center_of_mass(), Bones.CHEST)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(not is_instance_valid(lg) or not lg.is_active(), "grabber launched: the hand lets go")
	_check(_released.size() == 1, "drop emits limb_grab_released")
	await _clear([g, v])
	p = await _pair()
	g = p[0]
	v = p[1]
	_released.clear()
	lg = LimbGrab.start(g, v, BodyZones.Zone.ARM_R)
	var t0 := TimeDirector.now()
	while lg != null and is_instance_valid(lg) and lg.is_active() and TimeDirector.now() - t0 < LimbGrab.HOLD_MAX + 1.0:
		await get_tree().physics_frame
	var held := TimeDirector.now() - t0
	_check(absf(held - LimbGrab.HOLD_MAX) < 0.1, "releases by itself after HOLD_MAX (%.2f s)" % held)
	_check(_released.size() == 1 and v.get_state() == RagdollController.State.LAUNCHED, "the timed release flings")
	await _clear([g, v])

## A wall to the grabber's left (centre at x = wall_x, 0.4 m thick): the swing
## runs into it. It must stop or slip, never stretch past SLIP_DISTANCE for
## long, and never explode.
func _wall(wall_x: float) -> void:
	var face := wall_x + 0.2
	var wall := GrabTestUtil.make_wall(self, Vector3(wall_x, 1.5, 0.0), Vector3(0.4, 3.0, 6.0))
	var p: Array = await _pair()
	var g: Fighter = p[0]
	var v: Fighter = p[1]
	var lg := LimbGrab.start(g, v, BodyZones.Zone.ARM_R)
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	var t := 0.0
	var lin_max := 0.0
	var nan := false
	var over := 0.0
	var over_max := 0.0
	var stretch_max := 0.0
	var min_x := INF
	var stopped := 0
	var gap_max := 0.0
	while t < 2.0 and lg != null and is_instance_valid(lg) and lg.is_active():
		lg.set_swing_input(GrabTestUtil.yaw_dir(lg.get_swing_yaw() + PI * 0.5))   # toward -X, into the wall
		await get_tree().physics_frame
		t += dt
		if not is_instance_valid(lg) or not lg.is_active():
			break
		stretch_max = maxf(stretch_max, lg.get_stretch())
		gap_max = maxf(gap_max, GrabTestUtil.joint_separation(v)[0])
		if is_zero_approx(lg.get_swing_rate()):
			stopped += 1
		for b in Bones.PHYSICAL:
			min_x = minf(min_x, v.rig.get_physical_bone(b).global_position.x)
		over = over + dt if lg.get_stretch() > LimbGrab.SLIP_DISTANCE else 0.0
		over_max = maxf(over_max, over)
		var sp := GrabTestUtil.bone_speeds(v)
		lin_max = maxf(lin_max, sp[0])
		nan = nan or sp[2]
	var still := lg != null and is_instance_valid(lg) and lg.is_active()
	print("[wall %.1f m] %.2f s: grip %s, stretch max %.3f m, joint gap max %.3f m, bone peak %.1f m/s, NaN %s, nearest bone x %.2f (wall face %.1f), swing stopped %d ticks" % [
		-face, t, "held" if still else "let go", stretch_max, gap_max, lin_max, nan, min_x, face, stopped])
	_check(min_x < face + 0.15, "the swung body reached the wall %.1f m away" % -face)
	_check(not nan and lin_max < EXPLODE_SPEED, "swing into a wall %.1f m away: no NaN, no explosion" % -face)
	_check(over_max <= LimbGrab.SLIP_TIME + dt * 1.5, "never over SLIP_DISTANCE for longer than SLIP_TIME")
	_check(v.get_center_of_mass().x > face, "the body stays on the near side of the wall")
	if still:
		lg.drop()
	await _clear([g, v, wall])

func _check(ok: bool, msg: String) -> void:
	print(("  PASS " if ok else "  FAIL ") + msg)
	if not ok:
		_fail.append(msg)

func _finish() -> void:
	TimeDirector.reset()
	if _fail.is_empty():
		print("PASS test_limb_api")
		get_tree().quit(0)
	else:
		print("FAIL test_limb_api: ", _fail.size(), " check(s)")
		get_tree().quit(1)
