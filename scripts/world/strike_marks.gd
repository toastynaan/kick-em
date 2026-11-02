class_name StrikeMarks
extends RefCounted
## Small visual progress shared by everything that takes wall strikes (round 3):
## tiny chips popping off the struck face. Chips are small timed debris
## (Layers.DEBRIS_SMALL, CHIP_LIFE s), so 50 rapid strikes stay well inside the
## DebrisManager caps. Dust and sound are F's (GameEvents.wall_struck).
## OWNER: agent D (world).

const CHIPS_PER_STRIKE := 2       ## at a kick's power; 1-3 by power
const CHIP_LIFE := 3.0            ## s
const REF_POWER := 60.0

static var _rng := RandomNumberGenerator.new()
static var _meshes: Array = []
static var _shapes: Array = []

## Pop 1-3 tiny chips off `hit_pos` on the face with outward normal `n`.
static func chips(context: Node3D, hit_pos: Vector3, n: Vector3, direction: Vector3, power: float,
		surface: StringName) -> void:
	if context == null or not context.is_inside_tree():
		return
	_ensure()
	var count := clampi(int(round(CHIPS_PER_STRIKE * clampf(power / REF_POWER, 0.5, 1.5))), 1, 3)
	var parent := context.get_parent() if context.get_parent() else context
	var mat := WorldMaterials.chip_material(surface)
	var across := n.cross(Vector3.UP)
	across = across.normalized() if across.length() > 0.01 else Vector3.RIGHT
	for k in count:
		var b := RigidBody3D.new()
		b.name = "StrikeChip"
		var mi := MeshInstance3D.new()
		mi.mesh = _meshes[k % _meshes.size()]
		mi.material_override = mat
		mi.layers = Layers.VIS_WORLD
		b.add_child(mi)
		var cs := CollisionShape3D.new()
		cs.shape = _shapes[k % _shapes.size()]
		b.add_child(cs)
		b.mass = 0.3
		b.set_meta(&"surface", surface)
		var v := n * _rng.randf_range(1.0, 2.5) - direction * 0.3 + Vector3.UP * _rng.randf_range(0.5, 2.0) \
			+ across * _rng.randf_range(-1.2, 1.2)
		var w := Vector3(_rng.randf_range(-8, 8), _rng.randf_range(-8, 8), _rng.randf_range(-8, 8))
		b.linear_velocity = v
		b.angular_velocity = w
		parent.add_child(b)
		b.global_position = hit_pos + n * 0.06 + across * _rng.randf_range(-0.08, 0.08) \
			+ Vector3.UP * _rng.randf_range(-0.08, 0.08)
		b.linear_velocity = v
		b.angular_velocity = w
		DebrisManager.register(b, true, CHIP_LIFE)

static func _ensure() -> void:
	if not _meshes.is_empty():
		return
	for sz: Vector3 in [Vector3(0.07, 0.05, 0.04), Vector3(0.05, 0.08, 0.035), Vector3(0.09, 0.04, 0.05)]:
		var bm := BoxMesh.new()
		bm.size = sz
		_meshes.append(bm)
		var bs := BoxShape3D.new()
		bs.size = sz * 0.9
		_shapes.append(bs)
