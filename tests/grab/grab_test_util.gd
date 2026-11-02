class_name GrabTestUtil
## Shared helpers for tests/grab/* (limb grabs) and the grab lab readout.
## OWNER: agent G.

static func make_floor(parent: Node, size := 200.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Floor"
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, 1.0, size)
	cs.shape = box
	cs.position = Vector3(0.0, -0.5, 0.0)
	body.add_child(cs)
	parent.add_child(body)
	return body

## A static concrete-like wall (Layers.WORLD) centred at `pos`.
static func make_wall(parent: Node, pos: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Wall"
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	body.position = pos
	parent.add_child(body)
	return body

static func spawn(parent: Node, archetype: StringName, pos: Vector3, facing: Vector3,
		team := Fighter.TEAM_ENEMY) -> Fighter:
	var xf := Transform3D(Basis.looking_at(facing.normalized(), Vector3.UP), pos)
	return FighterFactory.spawn_dummy(parent, archetype, xf, team)

## Joints of the limbs a limb grab on `zone` holds (forearm + upper arm, or both legs).
static func held_joints(zone: int) -> Array[StringName]:
	match zone:
		BodyZones.Zone.ARM_L:
			return [Bones.L_LOWER_ARM, Bones.L_UPPER_ARM]
		BodyZones.Zone.ARM_R:
			return [Bones.R_LOWER_ARM, Bones.R_UPPER_ARM]
		BodyZones.Zone.LEGS:
			return [Bones.L_FOOT, Bones.L_LOWER_LEG, Bones.L_UPPER_LEG, Bones.R_FOOT, Bones.R_LOWER_LEG, Bones.R_UPPER_LEG]
	return []

static func yaw_dir(y: float) -> Vector3:
	return Vector3(-sin(y), 0.0, -cos(y))

static func yaw_of(d: Vector3) -> float:
	return atan2(-d.x, -d.z)

## Largest gap (m) between where a ragdoll joint sits on the child body and on
## the parent body (the ragdoll's own joints stretching), and that joint's bone.
## `only` limits it to the joints of those child bones.
static func joint_separation(f: Fighter, only: Array[StringName] = []) -> Array:
	var rig := f.rig
	var worst := 0.0
	var worst_bone: StringName = &""
	for b in Bones.PHYSICAL:
		if b == Bones.HIPS or rig.is_bone_severed(b) or (not only.is_empty() and not only.has(b)):
			continue
		var pb := rig.get_physical_bone(b)
		var p: StringName = Bones.PARENT[b]
		var ppb := rig.get_physical_bone(p)
		if ppb == null:
			continue
		var xc: Transform3D = PhysicsServer3D.body_get_state(pb.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
		var xp: Transform3D = PhysicsServer3D.body_get_state(ppb.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
		var on_child := (xc * rig.get_body_offset(b).affine_inverse()).origin
		var rest := HumanoidRig.scaled(HumanoidRig.REST[b], rig.height_scale, rig.width_scale)
		var on_parent := xp * rig.get_body_offset(p).affine_inverse() * rest
		var d := on_child.distance_to(on_parent)
		if d > worst or not is_finite(d):
			worst = d if is_finite(d) else INF
			worst_bone = b
	return [worst, worst_bone]

## [peak linear speed, peak angular speed, any NaN] over the fighter's bones.
static func bone_speeds(f: Fighter) -> Array:
	var lin := 0.0
	var ang := 0.0
	var nan := false
	for b in Bones.PHYSICAL:
		if f.rig.is_bone_severed(b):
			continue
		var rid := f.rig.get_physical_bone(b).get_rid()
		var xf: Transform3D = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
		var lv: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		var av: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		if not xf.origin.is_finite() or not lv.is_finite() or not av.is_finite():
			nan = true
			continue
		lin = maxf(lin, lv.length())
		ang = maxf(ang, av.length())
	return [lin, ang, nan]
