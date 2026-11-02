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
var _slab_dmg := {}           ## Vector2i(face, segment) -> strike damage
var chips := 0
## Per face band: [accumulated strike power, Decal or null] (one decal grows).
var _marks := {}
const DECAL_SIZE := Vector2(0.5, 1.2)
const GROW_POWER := 900.0

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

## Round 3 contract (same as Destructible.receive_strike): a punch or kick.
## Every hit chips the face (tiny chips, a crack decal that grows); the face
## slab under the contact takes the power against Tuning.STRIKE_CELL_HP.concrete
## and comes off as two pieces pushed along `direction` when it runs out
## (&"hole"). The core never breaks. Emits GameEvents.wall_struck.
func receive_strike(attacker: Node3D, hit_pos: Vector3, direction: Vector3, power: float) -> StringName:
	var face := _face_of(-direction)
	var lp := to_local(hit_pos)
	var seg := clampi(int(lp.y / (size.y / SEGMENTS)), 0, SEGMENTS - 1)
	var key := Vector2i(face, seg)
	var n := global_basis * _face_normal_local(face)
	var result := &"chip"
	if _slabs.has(key) and power > 0.0:
		_slab_dmg[key] = float(_slab_dmg.get(key, 0.0)) + power
		var hp: float = Tuning.STRIKE_CELL_HP.get(&"concrete", 900.0)
		if float(_slab_dmg[key]) >= hp:
			if _knock_off(key, n, CHIP_FROM):
				chips += 1
				result = &"hole"
	_strike_marks(key, hit_pos, n, direction, power)
	GameEvents.wall_struck.emit(attacker, self, hit_pos, n, power, result, &"concrete")
	return result

## Strike damage on the slab under `world_pos` (tests / debug); -1 if gone.
func get_slab_damage_at(world_pos: Vector3, direction: Vector3) -> float:
	var lp := to_local(world_pos)
	var key := Vector2i(_face_of(-direction), clampi(int(lp.y / (size.y / SEGMENTS)), 0, SEGMENTS - 1))
	return float(_slab_dmg.get(key, 0.0)) if _slabs.has(key) else -1.0

func _face_of(normal: Vector3) -> int:
	var ln := global_basis.inverse() * normal
	if absf(ln.x) >= absf(ln.z):
		return 1 if ln.x > 0.0 else 0
	return 3 if ln.z > 0.0 else 2

static func _face_normal_local(face: int) -> Vector3:
	match face:
		0:
			return Vector3.LEFT
		1:
			return Vector3.RIGHT
		2:
			return Vector3.FORWARD
	return Vector3.BACK

## Tiny chips every hit; one crack decal per face band grows with its damage.
func _strike_marks(key: Vector2i, hit_pos: Vector3, n: Vector3, direction: Vector3, power: float) -> void:
	var m: Array = _marks.get(key, [0.0, null])
	m[0] = float(m[0]) + maxf(power, 0.0)
	_marks[key] = m
	ConcreteWall.grow_decal(self, m, 1, hit_pos, n, float(m[0]), DECAL_SIZE, GROW_POWER)
	StrikeMarks.chips(self, hit_pos, n, direction, power, &"concrete")

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
		if _knock_off(k, normal, energy):
			n += 1
	chips += n
	return n

## Remove one face slab and drop it as two pieces off the face (`normal` out).
func _knock_off(key: Vector2i, normal: Vector3, energy: float) -> bool:
	if not _slabs.has(key):
		return false
	var slab: Array = _slabs[key]
	_slabs.erase(key)
	_slab_dmg.erase(key)
	var cs: CollisionShape3D = slab[0]
	var mi: MeshInstance3D = slab[1]
	var sz: Vector3 = slab[2]
	var xf := global_transform * Transform3D(Basis(), mi.position)
	cs.queue_free()
	mi.queue_free()
	_spawn_chip(xf, sz, normal, maxf(energy, CHIP_FROM))
	return true

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
