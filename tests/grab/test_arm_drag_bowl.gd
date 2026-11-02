extends Node3D
## U5 acceptance: an arm drag swings one enemy into another without the joint
## stretching or exploding. The player grabs grunt A's right forearm and swings
## it (scripted swing input, shipped rate clamp) toward grunt B standing 90
## degrees around the circle; then releases toward -X.
## Checks: grip stretch under STRETCH_OK and the held arm's elbow and shoulder
## under JOINT_OK the whole time, no NaN, no bone faster than EXPLODE_SPEED and
## no joint open past EXPLODE_GAP (free limbs hitting B may open a few cm), B was hit (GameEvents.body_bowled for B, or B knocked out
## of ANIMATED, or B's capsule pushed, or one of A's bones touching B's
## capsule), limb_grab_started/released emitted, A flies after the release.
## OWNER: agent G.

const STRETCH_OK := 0.05
const JOINT_OK := 0.05
const EXPLODE_GAP := 0.2
const EXPLODE_SPEED := 40.0
const SWING_TIME := 2.0

var _events: Array = []
var _fail: Array[String] = []

func _ready() -> void:
	get_tree().create_timer(60.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	for sig: StringName in [&"limb_grab_started", &"limb_grab_released", &"body_bowled", &"fighter_launched"]:
		var s := sig
		GameEvents.connect(s, func(arg1 = null, arg2 = null, arg3 = null, arg4 = null) -> void:
			_events.append([s, arg1, arg2, arg3, arg4]))
	GrabTestUtil.make_floor(self)
	await get_tree().physics_frame
	var grabber := GrabTestUtil.spawn(self, &"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var a := GrabTestUtil.spawn(self, &"grunt", Vector3(0.0, 0.0, -1.0), Vector3.BACK)
	# B stands a quarter turn counter-clockwise (+yaw) around the grabber.
	var b_pos := Vector3(-1.5, 0.0, 0.0)
	var b := GrabTestUtil.spawn(self, &"grunt", b_pos, Vector3.RIGHT)
	for i in 20:
		await get_tree().physics_frame
	var b_start := b.global_position

	var lg := LimbGrab.start(grabber, a, BodyZones.Zone.ARM_R)
	_check(lg != null and lg.is_active(), "arm drag started on a standing grunt")
	if lg == null:
		_finish()
		return
	_check(lg.kind == LimbGrab.Kind.ARM_DRAG and lg.bone == Bones.R_LOWER_ARM, "kind ARM_DRAG on RightLowerArm")
	_check(_count(&"limb_grab_started") == 1, "limb_grab_started emitted")
	_check(a.ragdoll.is_full_ragdoll() and a.ragdoll.is_gripped(), "victim A is a gripped full ragdoll while held")

	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	var in_yaw := GrabTestUtil.yaw_of(a.global_position - grabber.global_position)
	var stretch_max := 0.0
	var gap_max := 0.0
	var gap_at := 0.0
	var gap_bone: StringName = &""
	var held_max := 0.0
	var held := GrabTestUtil.held_joints(BodyZones.Zone.ARM_R)
	var lin_max := 0.0
	var nan := false
	var hit_how := ""
	var hit_t := -1.0
	var t := 0.0
	var com_speed_at_hit := 0.0
	while t < SWING_TIME and lg.is_active():
		# Lead the swing by a quarter turn: the shipped rate clamp sets the pace.
		in_yaw = lg.get_swing_yaw() + PI * 0.5
		lg.set_swing_input(GrabTestUtil.yaw_dir(in_yaw))
		await get_tree().physics_frame
		t += dt
		if not lg.is_active():
			break
		stretch_max = maxf(stretch_max, lg.get_stretch())
		held_max = maxf(held_max, GrabTestUtil.joint_separation(a, held)[0])
		var js := GrabTestUtil.joint_separation(a)
		if js[0] > gap_max:
			gap_max = js[0]
			gap_at = t
			gap_bone = js[1]
		var sp := GrabTestUtil.bone_speeds(a)
		lin_max = maxf(lin_max, sp[0])
		nan = nan or sp[2]
		if hit_how == "":
			hit_how = _hit_route(a, b, b_start)
			if hit_how != "":
				hit_t = t
				com_speed_at_hit = a.get_com_velocity().length()
		elif t - hit_t > 0.3:
			break   # B was hit; keep swinging a little to see the joint survive the impact
	print("[arm drag] swing %.2f s, rate %.1f rad/s: stretch max %.3f m, held arm joint gap max %.3f m, any joint gap max %.3f m (%s at %.2f s), bone peak %.1f m/s, NaN %s" % [
		t, lg.get_swing_rate(), stretch_max, held_max, gap_max, gap_bone, gap_at, lin_max, nan])
	print("[arm drag] B hit: %s at %.2f s (A COM %.1f m/s); B state %d; B moved %.2f m" % [
		hit_how if hit_how != "" else "NO", hit_t, com_speed_at_hit, b.get_state(), b.global_position.distance_to(b_start)])
	_check(stretch_max < STRETCH_OK, "grip stretch %.3f m < %.2f m" % [stretch_max, STRETCH_OK])
	_check(held_max < JOINT_OK, "held arm's elbow/shoulder gap %.3f m < %.2f m" % [held_max, JOINT_OK])
	_check(not nan, "no NaN in the held body")
	_check(lin_max < EXPLODE_SPEED and gap_max < EXPLODE_GAP, "no explosion (bone peak %.1f m/s < %.0f, any joint %.3f m < %.2f)" % [
		lin_max, EXPLODE_SPEED, gap_max, EXPLODE_GAP])
	_check(hit_how != "", "the swung body hit the second enemy")

	var released_ok := lg.is_active()
	if released_ok:
		lg.release(Vector3.LEFT)
	_check(released_ok and not lg.is_active(), "release() ends the grab")
	_check(_count(&"limb_grab_released") == 1, "limb_grab_released emitted once")
	var rel := _last(&"limb_grab_released")
	if not rel.is_empty():
		var v: Vector3 = rel[3]
		print("[arm drag] release velocity %s (%.1f m/s)" % [v, v.length()])
		_check(v.length() >= LimbGrab.RELEASE_SPEED_MIN - 0.01, "fling speed %.1f m/s >= %.1f" % [v.length(), LimbGrab.RELEASE_SPEED_MIN])
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(a.get_state() == RagdollController.State.LAUNCHED, "A is LAUNCHED after the release")
	_check(not a.ragdoll.is_gripped(), "A is no longer gripped")
	_check(LimbGrab.get_grip_on(a) == null, "no grip left on A")
	_finish()

## How B was hit, or "" if not yet.
func _hit_route(a: Fighter, b: Fighter, b_start: Vector3) -> String:
	for e in _events:
		if e[0] == &"body_bowled" and e[2] == b:
			return "body_bowled (E=%.0f J)" % float(e[3])
	if b.get_state() != RagdollController.State.ANIMATED:
		return "B knocked out of ANIMATED"
	if Vector2(b.global_position.x - b_start.x, b.global_position.z - b_start.z).length() > 0.05:
		return "B's capsule pushed"
	# Contact: one of A's bones inside B's capsule (radius 0.3, 1.8 m tall).
	var base := b.global_position
	for bn in Bones.PHYSICAL:
		var p := a.rig.get_physical_bone(bn).global_position
		var y := clampf(p.y - base.y, 0.3, 1.5)
		var axis := base + Vector3.UP * y
		if p.distance_to(axis) < 0.3 + 0.08:
			return "contact (%s)" % bn
	return ""

func _count(what: StringName) -> int:
	var n := 0
	for e in _events:
		if e[0] == what:
			n += 1
	return n

func _last(what: StringName) -> Array:
	for i in range(_events.size() - 1, -1, -1):
		if _events[i][0] == what:
			return _events[i]
	return []

func _check(ok: bool, msg: String) -> void:
	print(("  PASS " if ok else "  FAIL ") + msg)
	if not ok:
		_fail.append(msg)

func _finish() -> void:
	TimeDirector.reset()
	if _fail.is_empty():
		print("PASS test_arm_drag_bowl")
		get_tree().quit(0)
	else:
		print("FAIL test_arm_drag_bowl: ", _fail.size(), " check(s)")
		get_tree().quit(1)
