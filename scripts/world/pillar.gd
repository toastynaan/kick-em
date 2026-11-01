class_name Pillar
extends StaticBody3D
## Concrete courtyard pillar that chips (round 2). A solid core plus face slabs
## in SEGMENTS height bands. A hard impact (>= CHIP_FROM J, reported by
## ImpactResolver) knocks the slab nearest the contact off as debris, two bands
## from CHIP_BIG_FROM J. The core always stays, so bodies always bounce.
## Static, Layers.WORLD, surface &"concrete".
## OWNER: agent D (world).

const CHIP_FROM := 5000.0
const CHIP_BIG_FROM := 9000.0
const SEGMENTS := 3
const SLAB := 0.12            ## m thickness of a face slab
const DENSITY := 400.0        ## kg/m^3, same game density as concrete chunks

@export var size := Vector3(1.0, 4.0, 1.0)
var _slabs := {}              ## Vector2i(face, segment) -> [CollisionShape3D, MeshInstance3D, Vector3 size]
var chips := 0

func _ready() -> void:
	collision_layer = Layers.WORLD
	collision_mask = 0
	set_meta(&"surface", &"concrete")
	add_to_group(&"world_static")
	add_to_group(&"pillars")
	var mat := WorldMaterials.concrete(1.05)
	var core := Vector3(size.x - SLAB * 2.0, size.y, size.z - SLAB * 2.0)
	_add_box(core, Vector3(0, size.y * 0.5, 0), mat, true)
	var h := size.y / SEGMENTS
	for seg in SEGMENTS:
		var y := h * (seg + 0.5)
		# Faces 0/1 = -X/+X (full depth, cover the corners), 2/3 = -Z/+Z.
		for face in 4:
			var sz: Vector3
			var at: Vector3
			match face:
				0:
					sz = Vector3(SLAB, h, size.z)
					at = Vector3(-size.x * 0.5 + SLAB * 0.5, y, 0)
				1:
					sz = Vector3(SLAB, h, size.z)
					at = Vector3(size.x * 0.5 - SLAB * 0.5, y, 0)
				2:
					sz = Vector3(size.x - SLAB * 2.0, h, SLAB)
					at = Vector3(0, y, -size.z * 0.5 + SLAB * 0.5)
				_:
					sz = Vector3(size.x - SLAB * 2.0, h, SLAB)
					at = Vector3(0, y, size.z * 0.5 - SLAB * 0.5)
			var pair := _add_box(sz, at, mat, true)
			_slabs[Vector2i(face, seg)] = [pair[0], pair[1], sz]

func _add_box(sz: Vector3, at: Vector3, mat: Material, collide: bool) -> Array:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = sz
	mi.mesh = bm
	mi.material_override = mat
	mi.layers = Layers.VIS_WORLD
	mi.position = at
	add_child(mi)
	var cs: CollisionShape3D = null
	if collide:
		cs = CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = sz
		cs.shape = shape
		cs.position = at
		add_child(cs)
	return [cs, mi]

## Knock face slabs off near `pos` (world) on the face with outward `normal`.
## Returns how many slabs came off.
func chip(pos: Vector3, normal: Vector3, energy: float) -> int:
	if energy < CHIP_FROM:
		return 0
	var ln := global_basis.inverse() * normal
	var face := 0
	if absf(ln.x) >= absf(ln.z):
		face = 1 if ln.x > 0.0 else 0
	else:
		face = 3 if ln.z > 0.0 else 2
	var lp := to_local(pos)
	var seg := clampi(int(lp.y / (size.y / SEGMENTS)), 0, SEGMENTS - 1)
	var keys: Array[Vector2i] = [Vector2i(face, seg)]
	if energy >= CHIP_BIG_FROM:
		var other := seg + 1 if lp.y - (seg + 0.5) * size.y / SEGMENTS > 0.0 else seg - 1
		if other >= 0 and other < SEGMENTS:
			keys.append(Vector2i(face, other))
	var n := 0
	for k in keys:
		if not _slabs.has(k):
			continue
		var slab: Array = _slabs[k]
		_slabs.erase(k)
		var cs: CollisionShape3D = slab[0]
		var mi: MeshInstance3D = slab[1]
		var sz: Vector3 = slab[2]
		var xf := global_transform * Transform3D(Basis(), mi.position)
		cs.queue_free()
		mi.queue_free()
		_spawn_chip(xf, sz, normal, energy)
		n += 1
	chips += n
	return n

func _spawn_chip(xf: Transform3D, sz: Vector3, normal: Vector3, energy: float) -> void:
	# The slab comes off as two pieces (upper and lower half).
	for half in [-1.0, 1.0]:
		var piece := Vector3(sz.x, sz.y * 0.5 - 0.02, sz.z)
		var b := RigidBody3D.new()
		b.name = "PillarChip"
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = piece
		mi.mesh = bm
		mi.material_override = WorldMaterials.concrete(1.05)
		mi.layers = Layers.VIS_WORLD
		b.add_child(mi)
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = piece * 0.94
		cs.shape = shape
		b.add_child(cs)
		b.mass = maxf(piece.x * piece.y * piece.z * DENSITY, 1.0)
		b.set_meta(&"surface", &"concrete")
		b.transform = xf * Transform3D(Basis(), Vector3(0, half * sz.y * 0.25, 0))
		var v := normal * randf_range(1.5, 3.0) * clampf(energy / CHIP_FROM, 1.0, 2.0) + Vector3.UP * randf_range(0.0, 1.0)
		var w := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 3.0
		b.linear_velocity = v
		b.angular_velocity = w
		(get_parent() if get_parent() else self).add_child(b)
		b.linear_velocity = v
		b.angular_velocity = w
		DebrisManager.register(b, false)
