class_name RigTestUtil
## Shared helpers for tests/rig/* (floor, wall, dummies). OWNER: agent A.

static func make_floor(parent: Node, size := 60.0) -> StaticBody3D:
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

static func make_wall(parent: Node, pos: Vector3, size: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.name = "Wall"
	b.collision_layer = Layers.WORLD
	b.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	b.add_child(cs)
	parent.add_child(b)
	b.global_position = pos
	return b

static func make_dummy(parent: Node, archetype: StringName, pos: Vector3, profile: RagdollProfile = null,
		active := true) -> LabDummy:
	var d := LabDummy.new()
	d.name = String(archetype).capitalize() + "Dummy"
	d.setup(archetype, profile, active)
	d.position = pos
	parent.add_child(d)
	return d

## True if any number in the body state is NaN/INF.
static func has_nan(rc: RagdollController) -> bool:
	for pb in rc.rig.get_physical_bones():
		var o := pb.global_position
		if is_nan(o.x) or is_nan(o.y) or is_nan(o.z) or is_inf(o.x) or is_inf(o.y) or is_inf(o.z):
			return true
	return false

static func max_bone_speed(rc: RagdollController) -> float:
	var m := 0.0
	for pb in rc.rig.get_physical_bones():
		var v: Vector3 = PhysicsServer3D.body_get_state(pb.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		m = maxf(m, v.length())
	return m

static func max_dist_from_pelvis(rc: RagdollController) -> float:
	var p := rc.rig.get_physical_bone(Bones.HIPS).global_position
	var m := 0.0
	for pb in rc.rig.get_physical_bones():
		m = maxf(m, pb.global_position.distance_to(p))
	return m
