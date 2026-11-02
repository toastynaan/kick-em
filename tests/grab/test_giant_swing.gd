extends Node3D
## Giant swing: legs can only be gripped on a tumbling or downed enemy. Knock a
## grunt down, grab both shins, swing at the shipped rate limit for 2 s and
## release. Checks: refused while standing, accepted when down, two grips;
## once spun up (after LimbGrab.LEG_SPIN_UP_TIME) stretch and the held legs'
## joints stay under 5 cm; over the whole grab (the lift off the floor
## included, which can reach ~9 cm on some landings) nothing opens past
## EXPLODE_GAP, no NaN; the body really swings, the release flings it and
## restores the held limbs' masses.
## OWNER: agent G.

const STRETCH_OK := 0.05
const JOINT_OK := 0.05
const EXPLODE_GAP := 0.15
const EXPLODE_SPEED := 40.0

var _fail: Array[String] = []
var _released: Array = []

func _ready() -> void:
	get_tree().create_timer(60.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	GameEvents.limb_grab_released.connect(func(g: Node3D, v: Node3D, vel: Vector3) -> void:
		_released.append([g, v, vel]))
	GrabTestUtil.make_floor(self)
	await get_tree().physics_frame
	var grabber := GrabTestUtil.spawn(self, &"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var a := GrabTestUtil.spawn(self, &"grunt", Vector3(0.0, 0.0, -1.2), Vector3.BACK)
	for i in 20:
		await get_tree().physics_frame
	_check(not LimbGrab.can_grip(grabber, a, BodyZones.Zone.LEGS), "legs refused on a standing enemy")
	_check(LimbGrab.start(grabber, a, BodyZones.Zone.LEGS) == null, "start() refuses legs on a standing enemy")

	# Knock A down (backwards, away from the grabber) and wait for GROUNDED.
	a.launch(Vector3(0.0, 1.5, -1.5), a.get_center_of_mass(), Bones.CHEST)
	var t0 := TimeDirector.now()
	while a.get_state() != RagdollController.State.GROUNDED and TimeDirector.now() - t0 < 5.0:
		await get_tree().physics_frame
	_check(a.get_state() == RagdollController.State.GROUNDED, "A is downed")
	# Step up to the legs (the knock-down lands a little differently each run).
	var mid := (a.rig.get_physical_bone(Bones.L_LOWER_LEG).global_position
		+ a.rig.get_physical_bone(Bones.R_LOWER_LEG).global_position) * 0.5
	mid.y = 0.0
	grabber.teleport_to(mid + Vector3(0.0, 0.0, 0.9), Vector3.FORWARD)
	await get_tree().physics_frame
	_check(LimbGrab.can_grip(grabber, a, BodyZones.Zone.LEGS), "legs accepted on a downed enemy")
	var masses := {}
	for b in [Bones.L_LOWER_LEG, Bones.R_LOWER_LEG, Bones.L_UPPER_LEG, Bones.R_UPPER_LEG, Bones.L_FOOT, Bones.R_FOOT]:
		masses[b] = a.rig.get_physical_bone(b).mass
	var lg := LimbGrab.start(grabber, a, BodyZones.Zone.LEGS)
	_check(lg != null and lg.is_active(), "giant swing started")
	if lg == null:
		_finish()
		return
	_check(lg.kind == LimbGrab.Kind.GIANT_SWING and lg.get_grip_count() == 2, "kind GIANT_SWING with two grips (both shins)")
	var boosted: float = PhysicsServer3D.body_get_param(a.rig.get_physical_bone(Bones.L_UPPER_LEG).get_rid(), PhysicsServer3D.BODY_PARAM_MASS)
	_check(is_equal_approx(boosted, masses[Bones.L_UPPER_LEG] * LimbGrab.LEG_MASS_BOOST), "held legs weigh x%.0f while gripped" % LimbGrab.LEG_MASS_BOOST)

	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	var t := 0.0
	var stretch_max := 0.0
	var gap_max := 0.0
	var gap_bone: StringName = &""
	var held_max := 0.0
	var held := GrabTestUtil.held_joints(BodyZones.Zone.LEGS)
	var start_peak := 0.0
	var lin_max := 0.0
	var nan := false
	var com_speed_max := 0.0
	while t < 2.0 and lg.is_active():
		lg.set_swing_input(GrabTestUtil.yaw_dir(lg.get_swing_yaw() - PI * 0.5))   # clockwise this time
		await get_tree().physics_frame
		t += dt
		if not lg.is_active():
			continue
		var js := GrabTestUtil.joint_separation(a)
		if t < LimbGrab.LEG_SPIN_UP_TIME:
			start_peak = maxf(start_peak, maxf(lg.get_stretch(), js[0]))
			if js[0] > gap_max:
				gap_max = js[0]
				gap_bone = js[1]
			continue
		stretch_max = maxf(stretch_max, lg.get_stretch())
		held_max = maxf(held_max, GrabTestUtil.joint_separation(a, held)[0])
		if js[0] > gap_max:
			gap_max = js[0]
			gap_bone = js[1]
		var sp := GrabTestUtil.bone_speeds(a)
		lin_max = maxf(lin_max, sp[0])
		nan = nan or sp[2]
		com_speed_max = maxf(com_speed_max, a.get_com_velocity().length())
	print("[giant swing] %.2f s at %.1f rad/s: spun up: stretch max %.3f m, held-leg joint gap max %.3f m; lift (first %.1f s) peak %.3f m; any joint gap max %.3f m (%s), bone peak %.1f m/s, body COM up to %.1f m/s, NaN %s" % [
		t, lg.get_swing_rate(), stretch_max, held_max, LimbGrab.LEG_SPIN_UP_TIME, start_peak, gap_max, gap_bone, lin_max, com_speed_max, nan])
	_check(lg.is_active(), "grip held for the whole swing")
	_check(stretch_max < STRETCH_OK, "grip stretch %.3f m < %.2f" % [stretch_max, STRETCH_OK])
	_check(held_max < JOINT_OK, "held legs' joints gap %.3f m < %.2f" % [held_max, JOINT_OK])
	_check(not nan and lin_max < EXPLODE_SPEED and gap_max < EXPLODE_GAP and start_peak < EXPLODE_GAP,
		"no NaN, no explosion (bone peak, any joint and the lift < %.2f m)" % EXPLODE_GAP)
	_check(com_speed_max > 4.0, "the body swings (COM %.1f m/s > 4)" % com_speed_max)
	_check(lg.get_swing_rate() < 0.0, "clockwise input swings clockwise")

	var throw_dir := Vector3.RIGHT
	lg.release(throw_dir)
	_check(_released.size() == 1, "limb_grab_released emitted")
	if _released.size() == 1:
		var vel: Vector3 = _released[0][2]
		print("[giant swing] release velocity %s (%.1f m/s)" % [vel, vel.length()])
		_check(vel.length() > 4.0, "release flings the body (%.1f m/s)" % vel.length())
	var restored := true
	for b: StringName in masses:
		var m: float = PhysicsServer3D.body_get_param(a.rig.get_physical_bone(b).get_rid(), PhysicsServer3D.BODY_PARAM_MASS)
		restored = restored and is_equal_approx(m, masses[b])
	_check(restored, "held limbs' masses restored after the release")
	await get_tree().physics_frame
	_check(a.get_state() == RagdollController.State.LAUNCHED, "A flies after the release")
	_finish()

func _check(ok: bool, msg: String) -> void:
	print(("  PASS " if ok else "  FAIL ") + msg)
	if not ok:
		_fail.append(msg)

func _finish() -> void:
	TimeDirector.reset()
	if _fail.is_empty():
		print("PASS test_giant_swing")
		get_tree().quit(0)
	else:
		print("FAIL test_giant_swing: ", _fail.size(), " check(s)")
		get_tree().quit(1)
