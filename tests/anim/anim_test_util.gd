class_name AnimTestUtil
## Shared helpers for tests/anim/* (agent P): joint-limit measurement that
## matches RagdollController's soft limits, and a minimal animated host.
## OWNER: agent P (poses & animation).

## Tolerance (degrees) on the soft ranges of HumanoidRig.JOINT_LIMITS.
const LIMIT_TOL := 1.0

## Shortest rotation vector (axis * angle, radians) of q.
static func rotvec(q: Quaternion) -> Vector3:
	if q.w < 0.0:
		q = -q
	var v := Vector3(q.x, q.y, q.z)
	var s := v.length()
	if s < 0.000001:
		return v * 2.0
	return v * (2.0 * atan2(s, q.w) / s)

## Degrees by axis the way RagdollController measures a joint: hinges by the
## rotation vector's X; cones by swing X / Z and twist about the bone (Y).
static func joint_angles(bone: StringName, q: Quaternion) -> Vector3:
	var spec: Dictionary = HumanoidRig.JOINT_LIMITS[bone]
	if spec["type"] == &"hinge":
		return rotvec(q) * (180.0 / PI)
	var tq := Quaternion(0.0, q.y, 0.0, q.w)
	var tl := tq.length()
	var twist := 0.0
	var swing := q
	if tl > 0.000001:
		tq = tq / tl
		twist = wrapf(2.0 * atan2(tq.y, tq.w), -PI, PI)
		swing = q * tq.inverse()
	var sv := rotvec(swing)
	return Vector3(sv.x, twist, sv.z) * (180.0 / PI)

## How far (degrees) a local rotation of `bone` lies outside its soft range
## (0 inside). Hinges check X only (the joint itself blocks the other axes).
static func limit_excess(bone: StringName, q: Quaternion) -> float:
	if not HumanoidRig.JOINT_LIMITS.has(bone):
		return 0.0
	var spec: Dictionary = HumanoidRig.JOINT_LIMITS[bone]
	var a := joint_angles(bone, q)
	var ex := _out(a.x, spec["x"])
	if spec["type"] != &"hinge":
		ex = maxf(ex, _out(a.y, spec["y"]))
		ex = maxf(ex, _out(a.z, spec["z"]))
	return ex

static func _out(v: float, r: Vector2) -> float:
	if v < r.x:
		return r.x - v
	if v > r.y:
		return v - r.y
	return 0.0

## Worst limit excess over a full rotation array (Bones.ALL order; null = skip).
## Returns [excess_deg, bone].
static func worst_excess(rots: Array) -> Array:
	var worst := 0.0
	var wb: StringName = &""
	for i in HumanoidRig.BONE_COUNT:
		if rots[i] == null:
			continue
		var b: StringName = Bones.ALL[i]
		var e := limit_excess(b, rots[i])
		if e > worst:
			worst = e
			wb = b
	return [worst, wb]

static func make_floor(parent: Node, size := 80.0) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.name = "Floor"
	b.collision_layer = Layers.WORLD
	b.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, 1.0, size)
	cs.shape = box
	cs.position = Vector3(0, -0.5, 0)
	b.add_child(cs)
	parent.add_child(b)
	return b

## A bare animated character: HumanoidRig + PoseAnimator on a Node3D (no
## physics, no Fighter). `actor_time` stands in for Fighter.get_actor_time().
class AnimHost extends Node3D:
	var rig: HumanoidRig
	var anim: PoseAnimator
	var actor_time := 1.0
	## Stands in for Fighter.traversal (is_wall_running / get_wall_side).
	var traversal: Object = null
	func get_actor_time() -> float:
		return actor_time

static func make_host(parent: Node, archetype: StringName = &"player", pos := Vector3.ZERO) -> AnimHost:
	var h := AnimHost.new()
	h.name = "AnimHost"
	parent.add_child(h)
	h.position = pos
	var cfg: Dictionary = Tuning.ARCHETYPES.get(archetype, Tuning.ARCHETYPES[&"player"])
	h.rig = HumanoidRig.new()
	h.rig.name = "Rig"
	h.add_child(h.rig)
	h.rig.build(cfg["appearance"], float(cfg["mass"]))
	h.anim = PoseAnimator.new()
	h.anim.name = "PoseAnimator"
	h.add_child(h.anim)
	h.anim.setup(h.rig)
	return h

## Largest angle (degrees) between two rotations.
## (atan2 form: Quaternion.angle_to has ~0.05 deg of float noise near zero.)
static func angle_deg(a: Quaternion, b: Quaternion) -> float:
	var d := a.inverse() * b
	return rad_to_deg(2.0 * atan2(Vector3(d.x, d.y, d.z).length(), absf(d.w)))

## Largest angle over a range of bone indices of two pose arrays.
static func max_diff(a: Array, b: Array, from: int, to: int) -> float:
	var m := 0.0
	for i in range(from, to):
		m = maxf(m, angle_deg(a[i], b[i]))
	return m

## Character-space position of a bone (the host's frame).
static func local_pos(h: AnimHost, bone: StringName) -> Vector3:
	return h.global_transform.affine_inverse() * h.rig.get_bone_global_position(bone)

## Minimal Traversal stand-in for the wall-run style pick.
class FakeTraversal extends RefCounted:
	var side := 0
	func is_wall_running() -> bool:
		return side != 0
	func get_wall_side() -> int:
		return side
