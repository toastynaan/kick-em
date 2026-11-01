class_name HumanoidRig
extends Node3D
## Procedural humanoid: Skeleton3D with the bones in Bones.ALL, one primitive
## mesh per bone (on BoneAttachment3D), and a PhysicalBoneSimulator3D with a
## PhysicalBone3D per Bones.PHYSICAL bone (cone joints for shoulders, hips,
## neck; hinge joints for elbows and knees; Dempster masses).
## OWNER: agent A (rig & ragdoll). This file is a CONTRACT STUB: keep every
## public signature; add whatever else you need.
##
## Implementation notes (agent A):
## - The skeleton pose is written by RagdollController (or by PoseAnimator when
##   no controller exists) through apply_pose(). The PhysicalBoneSimulator3D is
##   kept INACTIVE as a skeleton modifier: it is only used to switch bodies
##   between static and rigid. Bone poses during simulation are computed by
##   RagdollController from the body transforms.
## - Joints are our own PhysicsServer3D joints (PhysicalBone3D.joint_type is
##   NONE), so we control frames and limits: cone twist with an off-centre cone
##   for shoulders, hips, spine and neck; hinges for elbows, knees and ankles.
##   Jolt hard limits are JOINT_LIMIT_MARGIN degrees wider than the soft ranges.
## - Body transforms are rest-aligned (identity basis), so a body's rotation is
##   the bone's global rotation.

const SHADER := preload("res://shaders/fighter.gdshader")
const BONE_COUNT := 16
const JOINT_LIMIT_MARGIN := 12.0   ## degrees the Jolt hard limit is wider than the soft range
const STUMP_COLOR := Color(0.33, 0.02, 0.03)

## Rest offset of each bone from its parent at height 1.0 / width 1.0 (metres).
## Character faces -Z, right is +X. Hips 0.95 m, shoulders 1.46, neck 1.52,
## head top ~1.79, hip joints 0.90, knees 0.48, ankles 0.08.
const REST := {
	&"Hips": Vector3(0, 0.95, 0),
	&"Spine": Vector3(0, 0.11, 0),
	&"Chest": Vector3(0, 0.19, 0),
	&"Head": Vector3(0, 0.27, 0),
	&"LeftUpperArm": Vector3(-0.19, 0.21, 0),
	&"LeftLowerArm": Vector3(0, -0.29, 0),
	&"LeftHand": Vector3(0, -0.26, 0),
	&"RightUpperArm": Vector3(0.19, 0.21, 0),
	&"RightLowerArm": Vector3(0, -0.29, 0),
	&"RightHand": Vector3(0, -0.26, 0),
	&"LeftUpperLeg": Vector3(-0.095, -0.05, 0),
	&"LeftLowerLeg": Vector3(0, -0.42, 0),
	&"LeftFoot": Vector3(0, -0.40, 0),
	&"RightUpperLeg": Vector3(0.095, -0.05, 0),
	&"RightLowerLeg": Vector3(0, -0.42, 0),
	&"RightFoot": Vector3(0, -0.40, 0),
}
const FIST_OFFSET := Vector3(0, -0.07, 0)  ## hand bone origin (wrist) -> fist centre

## Physical body per bone: shape, size and centre (bone-local, unscaled).
const BODY := {
	&"Hips": {"shape": &"box", "size": Vector3(0.30, 0.20, 0.20), "center": Vector3(0, -0.01, 0)},
	&"Spine": {"shape": &"box", "size": Vector3(0.26, 0.19, 0.17), "center": Vector3(0, 0.095, 0)},
	&"Chest": {"shape": &"box", "size": Vector3(0.33, 0.27, 0.20), "center": Vector3(0, 0.135, 0)},
	&"Head": {"shape": &"sphere", "radius": 0.11, "center": Vector3(0, 0.15, 0)},
	&"LeftUpperArm": {"shape": &"capsule", "radius": 0.055, "height": 0.29, "center": Vector3(0, -0.145, 0)},
	&"RightUpperArm": {"shape": &"capsule", "radius": 0.055, "height": 0.29, "center": Vector3(0, -0.145, 0)},
	&"LeftLowerArm": {"shape": &"capsule", "radius": 0.045, "height": 0.42, "center": Vector3(0, -0.20, 0)},
	&"RightLowerArm": {"shape": &"capsule", "radius": 0.045, "height": 0.42, "center": Vector3(0, -0.20, 0)},
	&"LeftUpperLeg": {"shape": &"capsule", "radius": 0.075, "height": 0.42, "center": Vector3(0, -0.21, 0)},
	&"RightUpperLeg": {"shape": &"capsule", "radius": 0.075, "height": 0.42, "center": Vector3(0, -0.21, 0)},
	&"LeftLowerLeg": {"shape": &"capsule", "radius": 0.06, "height": 0.40, "center": Vector3(0, -0.20, 0)},
	&"RightLowerLeg": {"shape": &"capsule", "radius": 0.06, "height": 0.40, "center": Vector3(0, -0.20, 0)},
	&"LeftFoot": {"shape": &"box", "size": Vector3(0.10, 0.07, 0.24), "center": Vector3(0, -0.045, -0.05)},
	&"RightFoot": {"shape": &"box", "size": Vector3(0.10, 0.07, 0.24), "center": Vector3(0, -0.045, -0.05)},
}

## Soft (target) joint ranges in degrees, per bone-local axis of the child
## relative to its parent. x = flex (+ swings a hanging limb forward, leans the
## spine back), z = abduction (+ toward +X), y = twist about the bone.
## The ragdoll's soft-limit torques use these; Jolt hard limits are wider.
const JOINT_LIMITS := {
	&"Spine": {"type": &"cone", "x": Vector2(-40, 20), "z": Vector2(-25, 25), "y": Vector2(-25, 25)},
	&"Chest": {"type": &"cone", "x": Vector2(-35, 20), "z": Vector2(-25, 25), "y": Vector2(-30, 30)},
	&"Head": {"type": &"cone", "x": Vector2(-50, 40), "z": Vector2(-35, 35), "y": Vector2(-70, 70)},
	&"LeftUpperArm": {"type": &"cone", "x": Vector2(-50, 170), "z": Vector2(-165, 30), "y": Vector2(-80, 80)},
	&"RightUpperArm": {"type": &"cone", "x": Vector2(-50, 170), "z": Vector2(-30, 165), "y": Vector2(-80, 80)},
	&"LeftLowerArm": {"type": &"hinge", "x": Vector2(0, 150)},
	&"RightLowerArm": {"type": &"hinge", "x": Vector2(0, 150)},
	&"LeftUpperLeg": {"type": &"cone", "x": Vector2(-25, 125), "z": Vector2(-70, 25), "y": Vector2(-40, 40)},
	&"RightUpperLeg": {"type": &"cone", "x": Vector2(-25, 125), "z": Vector2(-25, 70), "y": Vector2(-40, 40)},
	&"LeftLowerLeg": {"type": &"hinge", "x": Vector2(-150, 0)},
	&"RightLowerLeg": {"type": &"hinge", "x": Vector2(-150, 0)},
	&"LeftFoot": {"type": &"hinge", "x": Vector2(-50, 25)},
	&"RightFoot": {"type": &"hinge", "x": Vector2(-50, 25)},
}

## Pairs of physical bones that never collide with each other (overlapping at rest).
const SELF_EXCEPTIONS := [
	[&"Hips", &"Spine"], [&"Hips", &"Chest"], [&"Spine", &"Chest"], [&"Spine", &"Head"], [&"Chest", &"Head"],
	[&"Chest", &"LeftUpperArm"], [&"Chest", &"RightUpperArm"], [&"Spine", &"LeftUpperArm"], [&"Spine", &"RightUpperArm"],
	[&"LeftUpperArm", &"LeftLowerArm"], [&"RightUpperArm", &"RightLowerArm"],
	[&"Hips", &"LeftUpperLeg"], [&"Hips", &"RightUpperLeg"], [&"Spine", &"LeftUpperLeg"], [&"Spine", &"RightUpperLeg"],
	[&"LeftUpperLeg", &"RightUpperLeg"], [&"LeftUpperLeg", &"LeftLowerLeg"], [&"RightUpperLeg", &"RightLowerLeg"],
	[&"LeftLowerLeg", &"LeftFoot"], [&"RightLowerLeg", &"RightFoot"],
]

var skeleton: Skeleton3D
var simulator: PhysicalBoneSimulator3D
var mass_kg: float = 70.0

## Set by RagdollController.setup (used by sever() for velocities and to
## remove severed bones from the simulation).
var controller: RagdollController
var appearance: Dictionary = {}
var height_scale := 1.0
var width_scale := 1.0
var accessory: StringName = &"none"

var _attachments := {}        # bone -> BoneAttachment3D
var _pbs := {}                # bone -> PhysicalBone3D
var _pb_list: Array[PhysicalBone3D] = []
var _parts: Array[MeshInstance3D] = []
var _parts_by_bone := {}      # bone -> Array[MeshInstance3D]
var _joints := {}             # child bone -> joint RID
var _joints_pending := false
var _severed := {}            # cut -> true
var _severed_bones := {}      # bone -> true
var _body_offsets := {}       # bone -> Transform3D (bone -> body)
var _rest_global := {}        # bone -> Transform3D (skeleton space, rest)
var _joint_inertia := {}      # child bone -> float (kg m^2 of the subtree about the joint)
var _stumps: Array[MeshInstance3D] = []

static var _idx_cache := {}
static var _parent_idx_cache := PackedInt32Array()

# --- Static bone tables -------------------------------------------------------
static func bone_index(bone: StringName) -> int:
	if _idx_cache.is_empty():
		for i in Bones.ALL.size():
			_idx_cache[Bones.ALL[i]] = i
	return _idx_cache.get(bone, -1)

static func parent_indices() -> PackedInt32Array:
	if _parent_idx_cache.is_empty():
		_parent_idx_cache.resize(BONE_COUNT)
		for i in BONE_COUNT:
			var b: StringName = Bones.ALL[i]
			_parent_idx_cache[i] = bone_index(Bones.PARENT[b]) if Bones.PARENT.has(b) else -1
	return _parent_idx_cache

## Bones in the subtree rooted at `bone` (including it), parents first.
static func subtree(bone: StringName) -> Array[StringName]:
	var out: Array[StringName] = [bone]
	for b in Bones.ALL:
		if out.has(Bones.PARENT.get(b, &"")):
			out.append(b)
	return out

static func scaled(v: Vector3, h: float, w: float) -> Vector3:
	return Vector3(v.x * w, v.y * h, v.z * w)

# --- Build -------------------------------------------------------------------
## Build the whole rig. `appearance` is Tuning.ARCHETYPES[id]["appearance"];
## `mass_kg` scales bone masses (Bones.MASS_70 * mass_kg / 70.1).
## Fighter meshes go on render layer Layers.VIS_CHARACTERS and use the
## ShaderMaterial from res://shaders/fighter.gdshader (uniform `albedo`).
## May be called before or after the rig enters the tree.
func build(p_appearance: Dictionary, p_mass_kg: float) -> void:
	mass_kg = p_mass_kg
	appearance = p_appearance
	height_scale = float(appearance.get("height", 1.0))
	width_scale = float(appearance.get("width", 1.0))
	accessory = StringName(appearance.get("accessory", &"none"))
	if skeleton:
		_free_joints()
		skeleton.queue_free()
		_attachments.clear(); _pbs.clear(); _pb_list.clear(); _parts.clear(); _parts_by_bone.clear()
		_severed.clear(); _severed_bones.clear(); _stumps.clear()
	_build_skeleton()
	_build_meshes()
	_build_physics()
	if is_inside_tree():
		_create_joints()
	else:
		_joints_pending = true

func _ready() -> void:
	if _joints_pending:
		_create_joints()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_free_joints()

func _build_skeleton() -> void:
	skeleton = Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	for bone in Bones.ALL:
		skeleton.add_bone(bone)
	for i in BONE_COUNT:
		var bone: StringName = Bones.ALL[i]
		var pi: int = parent_indices()[i]
		if pi >= 0:
			skeleton.set_bone_parent(i, pi)
		skeleton.set_bone_rest(i, Transform3D(Basis(), scaled(REST[bone], height_scale, width_scale)))
	skeleton.reset_bone_poses()
	add_child(skeleton)
	_rest_global.clear()
	for i in BONE_COUNT:
		var bone: StringName = Bones.ALL[i]
		var local := Transform3D(Basis(), scaled(REST[bone], height_scale, width_scale))
		var pi: int = parent_indices()[i]
		_rest_global[bone] = (_rest_global[Bones.ALL[pi]] * local) if pi >= 0 else local
	for bone in Bones.ALL:
		var att := BoneAttachment3D.new()
		att.name = "Att_" + String(bone)
		att.bone_name = bone
		skeleton.add_child(att)
		_attachments[bone] = att
		_parts_by_bone[bone] = [] as Array[MeshInstance3D]

# --- Meshes ------------------------------------------------------------------
func _mat(color: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter(&"albedo", color)
	return m

## Adds one primitive part on `bone`'s attachment. `offset`/`rot_deg` are
## bone-local and unscaled (scaled here by height/width).
func _part(bone: StringName, mesh: Mesh, offset: Vector3, color: Color, rot_deg := Vector3.ZERO,
		scale_v := Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Part_%s_%d" % [bone, _parts_by_bone[bone].size()]
	mi.mesh = mesh
	mi.material_override = _mat(color)
	mi.layers = Layers.VIS_CHARACTERS
	var b := Basis.from_euler(rot_deg * (PI / 180.0)).scaled(Vector3(width_scale, height_scale, width_scale) * scale_v)
	mi.transform = Transform3D(b, scaled(offset, height_scale, width_scale))
	mi.set_meta(&"bone", bone)
	_attachments[bone].add_child(mi)
	_parts.append(mi)
	_parts_by_bone[bone].append(mi)
	return mi

static func _capsule(r: float, h: float) -> CapsuleMesh:
	var m := CapsuleMesh.new()
	m.radius = r
	m.height = maxf(h, r * 2.0 + 0.001)
	m.radial_segments = 16
	m.rings = 6
	return m

static func _sphere(r: float, h: float = -1.0) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0 if h < 0.0 else h
	m.radial_segments = 16
	m.rings = 10
	return m

static func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m

static func _cyl(r: float, h: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = r
	m.bottom_radius = r
	m.height = h
	m.radial_segments = 20
	return m

func _build_meshes() -> void:
	var skin: Color = appearance.get("skin", Color(0.87, 0.69, 0.55))
	var shirt: Color = appearance.get("shirt", Color(0.5, 0.5, 0.5))
	var pants: Color = appearance.get("pants", Color(0.2, 0.2, 0.2))
	var shoe := pants.darkened(0.45)
	var dark := Color(0.06, 0.05, 0.05)
	# Torso
	_part(&"Hips", _capsule(0.115, 0.34), Vector3(0, -0.01, 0), pants, Vector3(0, 0, 90))
	_part(&"Hips", _box(Vector3(0.30, 0.04, 0.21)), Vector3(0, 0.07, 0), shoe)   # belt
	_part(&"Spine", _capsule(0.125, 0.30), Vector3(0, 0.10, 0), shirt, Vector3.ZERO, Vector3(1, 1, 0.8))
	_part(&"Chest", _capsule(0.15, 0.34), Vector3(0, 0.12, 0), shirt, Vector3.ZERO, Vector3(1.05, 1, 0.75))
	_part(&"Chest", _capsule(0.085, 0.48), Vector3(0, 0.205, 0), shirt, Vector3(0, 0, 90))  # shoulders
	# Head
	_part(&"Head", _cyl(0.05, 0.12), Vector3(0, 0.03, 0), skin)
	_part(&"Head", _sphere(0.11, 0.25), Vector3(0, 0.155, 0), skin)
	_part(&"Head", _sphere(0.017), Vector3(-0.042, 0.17, -0.097), dark)
	_part(&"Head", _sphere(0.017), Vector3(0.042, 0.17, -0.097), dark)
	_part(&"Head", _box(Vector3(0.025, 0.04, 0.03)), Vector3(0, 0.14, -0.11), skin.darkened(0.08))
	_part(&"Head", _sphere(0.115, 0.13), Vector3(0, 0.215, 0.01), skin.darkened(0.55))  # hair cap
	# Arms
	for side in [&"Left", &"Right"]:
		_part(StringName(side + "UpperArm"), _capsule(0.058, 0.33), Vector3(0, -0.14, 0), shirt)
		_part(StringName(side + "LowerArm"), _capsule(0.047, 0.30), Vector3(0, -0.13, 0), skin)
		_part(StringName(side + "Hand"), _box(Vector3(0.08, 0.10, 0.09)), Vector3(0, -0.06, 0), skin)
		_part(StringName(side + "UpperLeg"), _capsule(0.078, 0.47), Vector3(0, -0.21, 0), pants)
		_part(StringName(side + "LowerLeg"), _capsule(0.062, 0.44), Vector3(0, -0.20, 0), pants)
		_part(StringName(side + "Foot"), _box(Vector3(0.10, 0.07, 0.25)), Vector3(0, -0.045, -0.05), shoe)
	# Accessories: each archetype must read at a glance in a crowd.
	match accessory:
		&"bandana":
			var red := Color(0.78, 0.07, 0.07)
			_part(&"Head", _cyl(0.118, 0.05), Vector3(0, 0.19, 0), red)
			_part(&"Head", _box(Vector3(0.03, 0.16, 0.015)), Vector3(-0.03, 0.12, 0.125), red, Vector3(15, 0, 12))
			_part(&"Head", _box(Vector3(0.03, 0.14, 0.015)), Vector3(0.03, 0.125, 0.125), red, Vector3(15, 0, -15))
		&"shield":
			var wood := Color(0.42, 0.27, 0.13)
			var metal := Color(0.55, 0.57, 0.6)
			_part(&"LeftLowerArm", _box(Vector3(0.50, 0.66, 0.05)), Vector3(0, -0.16, 0.085), wood)
			_part(&"LeftLowerArm", _box(Vector3(0.54, 0.05, 0.06)), Vector3(0, 0.15, 0.085), metal)
			_part(&"LeftLowerArm", _box(Vector3(0.54, 0.05, 0.06)), Vector3(0, -0.47, 0.085), metal)
			_part(&"LeftLowerArm", _sphere(0.07, 0.07), Vector3(0, -0.16, 0.115), metal)
		&"armor":
			var steel := Color(0.40, 0.42, 0.46)
			_part(&"Chest", _box(Vector3(0.40, 0.33, 0.27)), Vector3(0, 0.13, -0.005), steel)
			_part(&"Spine", _box(Vector3(0.33, 0.12, 0.23)), Vector3(0, 0.12, -0.005), steel.darkened(0.2))
			for side in [&"Left", &"Right"]:
				_part(StringName(side + "UpperArm"), _sphere(0.10, 0.12), Vector3(0, -0.01, 0), steel, Vector3.ZERO, Vector3(1.15, 1, 1.15))
			_part(&"Head", _sphere(0.122, 0.16), Vector3(0, 0.205, 0.0), steel)   # helmet cap
		_:
			pass

## Every visual mesh part, keyed by bone name (a bone may have several parts).
func get_mesh_parts() -> Array[MeshInstance3D]:
	return _parts

## Mesh parts riding one bone (includes accessories on that bone).
func get_bone_parts(bone: StringName) -> Array[MeshInstance3D]:
	var a: Array[MeshInstance3D] = []
	a.assign(_parts_by_bone.get(bone, []))
	return a

# --- Physics -------------------------------------------------------------------
func _build_physics() -> void:
	simulator = PhysicalBoneSimulator3D.new()
	simulator.name = "Simulator"
	simulator.active = false   # we write the skeleton pose ourselves
	skeleton.add_child(simulator)
	_body_offsets.clear()
	for bone in Bones.PHYSICAL:
		var spec: Dictionary = BODY[bone]
		var pb := PhysicalBone3D.new()
		pb.name = "PB_" + String(bone)
		pb.bone_name = bone
		var center := scaled(spec["center"], height_scale, width_scale)
		var off := Transform3D(Basis(), center)
		_body_offsets[bone] = off
		pb.body_offset = off
		pb.joint_type = PhysicalBone3D.JOINT_TYPE_NONE
		var cs := CollisionShape3D.new()
		cs.name = "Shape"
		match spec["shape"]:
			&"box":
				var b := BoxShape3D.new()
				var s: Vector3 = spec["size"]
				b.size = Vector3(s.x * width_scale, s.y * height_scale, s.z * width_scale)
				cs.shape = b
			&"sphere":
				var sp := SphereShape3D.new()
				sp.radius = float(spec["radius"]) * (height_scale + width_scale) * 0.5
				cs.shape = sp
			_:
				var c := CapsuleShape3D.new()
				c.radius = float(spec["radius"]) * width_scale
				c.height = maxf(float(spec["height"]) * height_scale, c.radius * 2.0 + 0.01)
				cs.shape = c
		pb.add_child(cs)
		pb.mass = Bones.MASS_70[bone] * mass_kg / 70.1
		pb.friction = 0.8
		pb.bounce = 0.0
		pb.linear_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
		pb.linear_damp = 0.0
		pb.angular_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
		pb.angular_damp = 0.8
		pb.collision_layer = Layers.RAGDOLL
		pb.collision_mask = Layers.MASK_RAGDOLL
		pb.transform = _rest_global[bone] * off
		simulator.add_child(pb)
		_pbs[bone] = pb
		_pb_list.append(pb)
	for pair in SELF_EXCEPTIONS:
		var a: PhysicalBone3D = _pbs[pair[0]]
		var b2: PhysicalBone3D = _pbs[pair[1]]
		PhysicsServer3D.body_add_collision_exception(a.get_rid(), b2.get_rid())
		PhysicsServer3D.body_add_collision_exception(b2.get_rid(), a.get_rid())
	_compute_joint_inertia()

## Effective inertia of each joint per bone-local axis (x flex, y twist,
## z abduction): the reduced inertia I_c*I_p/(I_c+I_p) of the child BODY and
## the parent BODY about the joint, in the rest pose. Torque gains are
## multiplied by it per axis. Only the two bodies of the joint count: the
## neighbouring cone joints are free to rotate, so a torque reaches nothing
## else within a step, and using a whole-subtree inertia here makes the
## explicit damping unstable (the body crawls along the floor). Twist (about
## the bone) has far less inertia than swing, hence per axis.
func _compute_joint_inertia() -> void:
	_joint_inertia.clear()
	for bone in Bones.PHYSICAL:
		if bone == Bones.HIPS:
			continue
		var joint_pos: Vector3 = _rest_global[bone].origin
		var ic := _body_inertia_about(bone, joint_pos)
		var ip := _body_inertia_about(Bones.PARENT[bone], joint_pos)
		var red := Vector3.ZERO
		for k in 3:
			red[k] = maxf(ic[k] * ip[k] / maxf(ic[k] + ip[k], 0.000001), 0.0005)
		_joint_inertia[bone] = red

func _body_inertia_about(b: StringName, point: Vector3) -> Vector3:
	var m := (_pbs[b] as PhysicalBone3D).mass
	var d: Vector3 = (_rest_global[b] * _body_offsets[b]).origin - point
	return Vector3(m * (d.y * d.y + d.z * d.z), m * (d.x * d.x + d.z * d.z), m * (d.x * d.x + d.y * d.y)) + _own_inertia(b, m)

## Inertia of one body about its own centre (rest axes).
func _own_inertia(bone: StringName, m: float) -> Vector3:
	var spec: Dictionary = BODY[bone]
	match spec["shape"]:
		&"box":
			var sz: Vector3 = spec["size"]
			sz = Vector3(sz.x * width_scale, sz.y * height_scale, sz.z * width_scale)
			return Vector3(sz.y * sz.y + sz.z * sz.z, sz.x * sz.x + sz.z * sz.z, sz.x * sz.x + sz.y * sz.y) * (m / 12.0)
		&"sphere":
			var r := float(spec["radius"]) * width_scale
			return Vector3.ONE * (0.4 * m * r * r)
		_:
			var r := float(spec["radius"]) * width_scale
			var h := float(spec["height"]) * height_scale
			var t := m * (3.0 * r * r + h * h) / 12.0
			return Vector3(t, 0.5 * m * r * r, t)

func _joint_frame_basis(bone: StringName) -> Basis:
	var spec: Dictionary = JOINT_LIMITS[bone]
	if spec["type"] == &"hinge":
		# Z' (hinge axis) = bone-local X.
		return Basis(Vector3(0, -1, 0), Vector3(0, 0, -1), Vector3(1, 0, 0))
	if bone in [Bones.SPINE, Bones.CHEST, Bones.HEAD]:
		# X' (twist axis) = +Y (bone points up).
		return Basis(Vector3(0, 1, 0), Vector3(0, 0, -1), Vector3(-1, 0, 0))
	return Basis(Vector3(0, -1, 0), Vector3(0, 0, -1), Vector3(1, 0, 0))

func _create_joints() -> void:
	_joints_pending = false
	_free_joints()
	var m := deg_to_rad(JOINT_LIMIT_MARGIN)
	for bone in Bones.PHYSICAL:
		if bone == Bones.HIPS:
			continue
		var parent: StringName = Bones.PARENT[bone]
		var spec: Dictionary = JOINT_LIMITS[bone]
		var pa: PhysicalBone3D = _pbs[parent]
		var pbb: PhysicalBone3D = _pbs[bone]
		var origin: Vector3 = _rest_global[bone].origin
		var body_a: Transform3D = _rest_global[parent] * _body_offsets[parent]
		var body_b: Transform3D = _rest_global[bone] * _body_offsets[bone]
		var fb := _joint_frame_basis(bone)
		var j := PhysicsServer3D.joint_create()
		var xr: Vector2 = spec["x"] * (PI / 180.0)
		if spec["type"] == &"hinge":
			var jw := Transform3D(fb, origin)
			PhysicsServer3D.joint_make_hinge(j, pa.get_rid(), body_a.affine_inverse() * jw, pbb.get_rid(), body_b.affine_inverse() * jw)
			PhysicsServer3D.hinge_joint_set_flag(j, PhysicsServer3D.HINGE_JOINT_FLAG_USE_LIMIT, true)
			# Jolt measures the hinge angle with the opposite sign: X range [a, b] -> lower -b, upper -a.
			PhysicsServer3D.hinge_joint_set_param(j, PhysicsServer3D.HINGE_JOINT_LIMIT_LOWER, -(xr.y + m))
			PhysicsServer3D.hinge_joint_set_param(j, PhysicsServer3D.HINGE_JOINT_LIMIT_UPPER, -(xr.x - m))
		else:
			var zr: Vector2 = spec["z"] * (PI / 180.0)
			var yr: Vector2 = spec["y"] * (PI / 180.0)
			var cx := (xr.x + xr.y) * 0.5
			var cz := (zr.x + zr.y) * 0.5
			var center := Basis.from_euler(Vector3(cx, 0, cz))
			var span := maxf((xr.y - xr.x) * 0.5, (zr.y - zr.x) * 0.5) + m
			var twist := maxf(absf(yr.x), absf(yr.y)) + m
			var jw_a := Transform3D(center * fb, origin)
			var jw_b := Transform3D(fb, origin)
			PhysicsServer3D.joint_make_cone_twist(j, pa.get_rid(), body_a.affine_inverse() * jw_a, pbb.get_rid(), body_b.affine_inverse() * jw_b)
			PhysicsServer3D.cone_twist_joint_set_param(j, PhysicsServer3D.CONE_TWIST_JOINT_SWING_SPAN, minf(span, PI * 0.95))
			PhysicsServer3D.cone_twist_joint_set_param(j, PhysicsServer3D.CONE_TWIST_JOINT_TWIST_SPAN, minf(twist, PI * 0.95))
		PhysicsServer3D.joint_disable_collisions_between_bodies(j, true)
		_joints[bone] = j
	for pb in _pb_list:
		PhysicsServer3D.body_set_enable_continuous_collision_detection(pb.get_rid(), true)
	park_bodies()

## Idle (non-simulating) bodies are top-level so they do not follow the host
## around and push a transform to the physics server every tick. They are
## static with no collision until the ragdoll starts (it teleports them).
func park_bodies() -> void:
	for pb in _pb_list:
		if not pb.is_simulating_physics():
			pb.top_level = true

func _free_joints() -> void:
	for j in _joints.values():
		PhysicsServer3D.free_rid(j)
	_joints.clear()

## Remove a bone's joint to its parent (used when severing).
func break_joint(bone: StringName) -> void:
	if _joints.has(bone):
		PhysicsServer3D.free_rid(_joints[bone])
		_joints.erase(bone)

# --- Queries -----------------------------------------------------------------
func get_bone_global_transform(bone: StringName) -> Transform3D:
	if not skeleton:
		return global_transform
	var i := bone_index(bone)
	if i < 0:
		return global_transform
	return skeleton.global_transform * skeleton.get_bone_global_pose(i)

func get_bone_global_position(bone: StringName) -> Vector3:
	return get_bone_global_transform(bone).origin

## World position of the fist centre (hand bone origin is the wrist).
func get_fist_position(side_bone: StringName) -> Vector3:
	return get_bone_global_transform(side_bone) * scaled(FIST_OFFSET, height_scale, width_scale)

## BoneAttachment3D that follows `bone` in every state (animated or ragdoll).
## Other modules parent hurtboxes, glints and FX to it.
func get_attachment(bone: StringName) -> BoneAttachment3D:
	return _attachments.get(bone)

func get_physical_bone(bone: StringName) -> PhysicalBone3D:
	return _pbs.get(bone)

func get_physical_bones() -> Array[PhysicalBone3D]:
	return _pb_list

## Transform from bone to its physical body (pure translation).
func get_body_offset(bone: StringName) -> Transform3D:
	return _body_offsets.get(bone, Transform3D())

## Rest transform of `bone` in skeleton space.
func get_rest_global(bone: StringName) -> Transform3D:
	return _rest_global.get(bone, Transform3D())

## Effective inertia (kg m^2) of `bone`'s joint per bone-local axis
## (x flex, y twist, z abduction).
func get_joint_inertia(bone: StringName) -> Vector3:
	return _joint_inertia.get(bone, Vector3(0.1, 0.01, 0.1))

func get_joint_rid(bone: StringName) -> RID:
	return _joints.get(bone, RID())

## Approximate total height in metres (for camera framing, glint placement).
func get_height() -> float:
	return 1.8 * height_scale

## Hide/show the whole body (teleport vanish). Hurtboxes are not affected.
func set_body_visible(v: bool) -> void:
	for p in _parts:
		var bone: StringName = p.get_meta(&"bone", &"")
		p.visible = v and not _severed_bones.has(bone)
	for s in _stumps:
		s.visible = v

## Write a full local pose: rots[i] is the local rotation of Bones.ALL[i]
## (rest rotations are identity); hips_pos is the Hips bone position in
## skeleton space.
func apply_pose(rots: Array[Quaternion], hips_pos: Vector3) -> void:
	for i in BONE_COUNT:
		skeleton.set_bone_pose_rotation(i, rots[i])
	skeleton.set_bone_pose_position(0, hips_pos)

func get_rest_hips_position() -> Vector3:
	return scaled(REST[&"Hips"], height_scale, width_scale)

func is_bone_severed(bone: StringName) -> bool:
	return _severed_bones.has(bone)

# --- Dismemberment -------------------------------------------------------------
## Dismemberment: detach the subtree of Bones.CUTS[cut]. Hides those mesh parts,
## shows a stump cap, removes their physical bones from the simulation, and
## returns a loose RigidBody3D copy (with the same pose and velocity) that has
## already been registered with DebrisManager. Returns null if already severed.
func sever(cut: StringName) -> RigidBody3D:
	if not Bones.CUTS.has(cut) or _severed.has(cut) or not skeleton or not is_inside_tree():
		return null
	var root_bone: StringName = Bones.CUTS[cut]
	if _severed_bones.has(root_bone):
		return null
	var sub := subtree(root_bone)
	_severed[cut] = true
	var root_xf := get_bone_global_transform(root_bone)
	var root_inv := root_xf.affine_inverse()
	var lin := Vector3.ZERO
	var ang := Vector3.ZERO
	if controller:
		var vel: Array = controller.get_bone_velocity(root_bone)
		lin = vel[0]
		ang = vel[1]
	var piece := RigidBody3D.new()
	piece.name = "Severed_" + String(cut)
	var total_mass := 0.0
	var limb_radius := 0.05
	for bone in sub:
		var bone_xf := get_bone_global_transform(bone)
		for part in _parts_by_bone.get(bone, []):
			var mi: MeshInstance3D = part
			var copy := MeshInstance3D.new()
			copy.mesh = mi.mesh
			copy.material_override = mi.material_override.duplicate() if mi.material_override else null
			copy.layers = mi.layers
			copy.transform = root_inv * bone_xf * mi.transform
			piece.add_child(copy)
			mi.visible = false
		_severed_bones[bone] = true
		if _pbs.has(bone):
			var pb: PhysicalBone3D = _pbs[bone]
			total_mass += pb.mass
			var cs := pb.get_node_or_null(^"Shape") as CollisionShape3D
			if cs and cs.shape:
				var shape_copy := CollisionShape3D.new()
				shape_copy.shape = cs.shape
				shape_copy.transform = root_inv * bone_xf * _body_offsets[bone] * cs.transform
				piece.add_child(shape_copy)
				if bone == root_bone:
					var s := cs.shape
					if s is CapsuleShape3D:
						limb_radius = (s as CapsuleShape3D).radius
					elif s is SphereShape3D:
						limb_radius = 0.06 * width_scale
	# Stump caps: one on the piece at the cut, one on the body side.
	var cap_mesh := _cyl(limb_radius * 1.08, 0.025)
	var piece_cap := MeshInstance3D.new()
	piece_cap.mesh = cap_mesh
	piece_cap.material_override = _mat(STUMP_COLOR)
	piece_cap.layers = Layers.VIS_CHARACTERS
	piece.add_child(piece_cap)
	var parent_bone: StringName = Bones.PARENT[root_bone]
	var body_cap := MeshInstance3D.new()
	body_cap.name = "Stump_" + String(cut)
	body_cap.mesh = cap_mesh
	body_cap.material_override = _mat(STUMP_COLOR)
	body_cap.layers = Layers.VIS_CHARACTERS
	body_cap.position = scaled(REST[root_bone], height_scale, width_scale)
	_attachments[parent_bone].add_child(body_cap)
	_stumps.append(body_cap)
	_parts.append(body_cap)
	body_cap.set_meta(&"bone", parent_bone)
	_parts_by_bone[parent_bone].append(body_cap)
	# Loose piece physics.
	piece.mass = maxf(total_mass, 0.5)
	piece.collision_layer = Layers.DEBRIS
	piece.collision_mask = Layers.MASK_DEBRIS
	piece.continuous_cd = true
	var world_parent: Node = get_tree().current_scene
	if world_parent == null or not world_parent.is_inside_tree():
		world_parent = get_parent()
	world_parent.add_child(piece)
	piece.global_transform = root_xf.orthonormalized()
	piece.linear_velocity = lin
	piece.angular_velocity = ang
	for pb in _pb_list:
		piece.add_collision_exception_with(pb)
	piece.reset_physics_interpolation()
	if controller:
		controller.on_bones_severed(sub)
	else:
		break_joint(root_bone)
	var dm := get_node_or_null(^"/root/DebrisManager")
	if dm and dm.has_method(&"register"):
		dm.register(piece)
	return piece

func is_severed(cut: StringName) -> bool:
	return _severed.has(cut)
