extends Node3D
## Limb grab support (agent G): two identical bodies gripped by the right wrist
## and whipped round at 6 rad/s side by side, one with the gripped-only joint
## drift fix (RagdollController.grip_fix_enabled) and one without.
## Jolt varies a little run to run, so the gaps are judged robustly: the 95th
## percentile of each frame's worst free-joint gap and the worst gap held for
## 3 consecutive frames, not a single-frame peak. The fixed body must stay
## tight and beat the unfixed one. Also: no NaN, and nothing in the ragdoll
## re-applies mass while held (G makes the held arm 8x heavier on the server).

const RATE := 6.0
const FRAMES := 300
const SKIP := 30
const FREE: Array[StringName] = [&"LeftLowerArm", &"LeftLowerLeg", &"RightLowerLeg", &"LeftFoot",
	&"RightFoot", &"LeftUpperArm", &"Head", &"Spine"]
const P95_MAX := 0.022        ## m, fixed body
const HELD_MAX := 0.035       ## m, held elbow 3-frame sustained (G's pin + 8x mass; steady 2-2.6 cm)
const SUSTAINED_MAX := 0.030  ## m, fixed body
const FIX_GAIN := 0.85        ## fixed p95 must be below this x unfixed p95

func _gap(rig: HumanoidRig, bone: StringName) -> float:
	var parent: StringName = Bones.PARENT[bone]
	var pw := rig.get_physical_bone(parent).global_transform * rig.get_body_offset(parent).affine_inverse()
	var cw := rig.get_physical_bone(bone).global_transform * rig.get_body_offset(bone).affine_inverse()
	return (pw * rig.skeleton.get_bone_rest(HumanoidRig.bone_index(bone)).origin).distance_to(cw.origin)

class Whip:
	var d: LabDummy
	var anchor: RID
	var joint: RID
	var pos: Vector3
	var center: Vector3
	var yaw := 0.0
	var free: Array[float] = []
	var held: Array[float] = []
	var nan := false

func _start(x: float, _fix: bool) -> Whip:
	var w := Whip.new()
	w.d = RigTestUtil.make_dummy(self, &"player", Vector3(x, 0, -0.7), null, false)
	w.center = Vector3(x, 1.15, 0)
	return w

func _grip(w: Whip, fix: bool) -> void:
	var rc := w.d.ragdoll
	rc.grip_fix_enabled = fix
	rc.launch(Vector3(0, 0, 1.2), w.d.global_position, Bones.CHEST)
	rc.set_gripped(true)
	var held := w.d.rig.get_physical_bone(Bones.R_LOWER_ARM)
	for b in [Bones.R_UPPER_ARM, Bones.R_LOWER_ARM]:
		var pb := w.d.rig.get_physical_bone(b)
		PhysicsServer3D.body_set_param(pb.get_rid(), PhysicsServer3D.BODY_PARAM_MASS, pb.mass * 8.0)
	var wrist_local := w.d.rig.get_body_offset(Bones.R_LOWER_ARM).affine_inverse() * Vector3(0, -0.26, 0)
	w.pos = held.global_transform * wrist_local
	# Anchor created static at the wrist, then made kinematic (no first-step sweep).
	w.anchor = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(w.anchor, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(w.anchor, 0)
	PhysicsServer3D.body_set_collision_mask(w.anchor, 0)
	PhysicsServer3D.body_set_state(w.anchor, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), w.pos))
	PhysicsServer3D.body_set_space(w.anchor, get_world_3d().space)
	PhysicsServer3D.body_set_mode(w.anchor, PhysicsServer3D.BODY_MODE_KINEMATIC)
	w.joint = PhysicsServer3D.joint_create()
	PhysicsServer3D.joint_make_pin(w.joint, w.anchor, Vector3.ZERO, held.get_rid(), wrist_local)
	PhysicsServer3D.joint_disable_collisions_between_bodies(w.joint, true)
	w.yaw = atan2(w.pos.x - w.center.x, w.pos.z - w.center.z)

static func _p95(a: Array[float]) -> float:
	var s := a.duplicate()
	s.sort()
	return s[int(s.size() * 0.95)]

## Worst gap held for `n` consecutive frames (min over each window, max over windows).
static func _sustained(a: Array[float], n: int) -> float:
	var worst := 0.0
	for i in range(0, a.size() - n + 1):
		var m := INF
		for k in n:
			m = minf(m, a[i + k])
		worst = maxf(worst, m)
	return worst

func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("GRIP_WHIP FAIL (timeout)")
		get_tree().quit(1))
	RigTestUtil.make_floor(self, 200.0)
	var fixed := _start(-6.0, true)
	var plain := _start(6.0, false)
	for i in 4:
		await get_tree().physics_frame
	var total0 := fixed.d.ragdoll.get_total_mass()
	_grip(fixed, true)
	_grip(plain, false)
	var held_pb := fixed.d.rig.get_physical_bone(Bones.R_LOWER_ARM)
	var spin := 0.0
	for f in FRAMES:
		spin = minf(spin + 24.0 / 120.0, RATE)
		for w in [fixed, plain]:
			w.yaw += spin / 120.0
			w.pos = w.pos.move_toward(w.center + Vector3(sin(w.yaw), 0, cos(w.yaw)) * 0.55, 7.0 / 120.0)
			PhysicsServer3D.body_set_state(w.anchor, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), w.pos))
		await get_tree().physics_frame
		for w in [fixed, plain]:
			w.nan = w.nan or RigTestUtil.has_nan(w.d.ragdoll)
			if f < SKIP:
				continue
			var worst := 0.0
			for b in FREE:
				worst = maxf(worst, _gap(w.d.rig, b))
			w.free.append(worst)
			w.held.append(_gap(w.d.rig, Bones.R_LOWER_ARM))
		@warning_ignore("integer_division")
		if f == FRAMES / 2:
			fixed.d.ragdoll.set_profile(RagdollProfile.realistic())   # must not touch masses
			fixed.d.ragdoll.heal_arms()
	var held_mass: float = PhysicsServer3D.body_get_param(held_pb.get_rid(), PhysicsServer3D.BODY_PARAM_MASS)
	var fp95 := _p95(fixed.free)
	var fsus := _sustained(fixed.free, 3)
	var hsus := _sustained(fixed.held, 3)
	var pp95 := _p95(plain.free)
	var psus := _sustained(plain.free, 3)
	print("whip %.0f rad/s  fixed: free p95 %.1f cm, free 3-frame %.1f cm, held 3-frame %.1f cm, peak %.1f cm | unfixed: free p95 %.1f cm, 3-frame %.1f cm, peak %.1f cm" % [
		RATE, fp95 * 100.0, fsus * 100.0, hsus * 100.0, fixed.free.max() * 100.0, pp95 * 100.0, psus * 100.0, plain.free.max() * 100.0])
	print("held mass %.1f kg (x8 kept), total %.1f kg, nan %s/%s" % [held_mass, fixed.d.ragdoll.get_total_mass(), fixed.nan, plain.nan])
	var ok := not fixed.nan and not plain.nan and fp95 < P95_MAX and fsus < SUSTAINED_MAX and hsus < HELD_MAX \
		and fp95 < pp95 * FIX_GAIN and absf(held_mass - held_pb.mass * 8.0) < 0.01 \
		and absf(fixed.d.ragdoll.get_total_mass() - total0) < 0.01 \
		and fixed.d.ragdoll.state == RagdollController.State.LAUNCHED
	for w in [fixed, plain]:
		PhysicsServer3D.free_rid(w.joint)
		PhysicsServer3D.free_rid(w.anchor)
		w.d.ragdoll.set_gripped(false)
	print("GRIP_WHIP ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)
