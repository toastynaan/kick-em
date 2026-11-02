class_name TilePlaza
extends StaticBody3D
## Round 6 tiled plaza: a patch of stone tiles laid in the courtyard floor.
## One flat collision box (walkable, Layers.WORLD, surface &"tile"); the tiles
## are one MultiMesh over a dark mortar bed. WorldDamage forwards floor damage
## here: every tile within the damage radius takes the energy with linear
## falloff (the tile under the point all of it), accumulating for the round; at
## Tuning.TILE_BREAK_ENERGY a tile pops out as a persistent piece (DebrisManager)
## and leaves the mortar showing.
## OWNER: agent D (world).

const TILE_THICK := 0.04      ## m
const GAP := 0.012            ## m of mortar between tiles
const POP_SPEED := Vector2(1.2, 2.6)  ## m/s up when a tile pops
const TILE_DENSITY := 1400.0  ## kg/m^3 (a ~13 kg stone tile)

var rect := Rect2()
var tile_size := 0.5
var top_y := 0.0
var _nx := 0
var _nz := 0
var _mm: MultiMesh
var _energy := PackedFloat32Array()
var _popped := PackedByteArray()
var popped_count := 0

func _ready() -> void:
	add_to_group(&"tile_plazas")
	add_to_group(&"world_static")
	add_to_group(&"floors")

## Lay the plaza: `p_rect` (x, z) in the parent's frame, tiles of `p_tile` m,
## tile tops at `p_top` (a few mm over the main floor).
func build(p_rect: Rect2, p_tile: float, p_top: float) -> void:
	rect = p_rect
	tile_size = p_tile
	top_y = p_top
	collision_layer = Layers.WORLD
	collision_mask = 0
	set_meta(&"surface", &"tile")
	_nx = maxi(int(round(rect.size.x / tile_size)), 1)
	_nz = maxi(int(round(rect.size.y / tile_size)), 1)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(rect.size.x, 0.1, rect.size.y)
	cs.shape = box
	cs.position = Vector3(rect.get_center().x, top_y - 0.05, rect.get_center().y)
	add_child(cs)
	var bed := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = rect.size
	bed.mesh = pm
	bed.material_override = WorldMaterials.mortar()
	bed.layers = Layers.VIS_WORLD
	# Just over the main floor's surface (y 0), so the mortar, not the asphalt,
	# shows in the joints and where a tile popped out.
	bed.position = Vector3(rect.get_center().x, top_y - 0.003, rect.get_center().y)
	add_child(bed)
	var tile_mesh := BoxMesh.new()
	tile_mesh.size = Vector3(tile_size - GAP, TILE_THICK, tile_size - GAP)
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.mesh = tile_mesh
	_mm.instance_count = _nx * _nz
	for iz in _nz:
		for ix in _nx:
			_mm.set_instance_transform(iz * _nx + ix, Transform3D(Basis(), _tile_center(ix, iz)))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Tiles"
	mmi.multimesh = _mm
	mmi.material_override = WorldMaterials.plaza_tile()
	mmi.layers = Layers.VIS_WORLD
	add_child(mmi)
	_energy.resize(_nx * _nz)
	_energy.fill(0.0)
	_popped.resize(_nx * _nz)
	_popped.fill(0)

func _tile_center(ix: int, iz: int) -> Vector3:
	return Vector3(rect.position.x + (ix + 0.5) * tile_size, top_y - TILE_THICK * 0.5 + 0.001,
		rect.position.y + (iz + 0.5) * tile_size)

func get_tile_count() -> int:
	return _nx * _nz

## True when the world point (x, z) lies on the plaza.
func contains(world_pos: Vector3) -> bool:
	var lp := to_local(world_pos)
	return rect.has_point(Vector2(lp.x, lp.z))

## Floor damage at `world_pos`: tiles within `radius` take `energy` with linear
## falloff (the tile under the point takes all of it). Returns tiles popped.
func damage_at(world_pos: Vector3, energy: float, radius: float) -> int:
	if _mm == null or energy <= 0.0:
		return 0
	var lp := to_local(world_pos)
	var r := maxf(radius, tile_size * 0.5)
	var popped := 0
	var x0 := clampi(int(floor((lp.x - r - rect.position.x) / tile_size)), 0, _nx - 1)
	var x1 := clampi(int(floor((lp.x + r - rect.position.x) / tile_size)), 0, _nx - 1)
	var z0 := clampi(int(floor((lp.z - r - rect.position.y) / tile_size)), 0, _nz - 1)
	var z1 := clampi(int(floor((lp.z + r - rect.position.y) / tile_size)), 0, _nz - 1)
	for iz in range(z0, z1 + 1):
		for ix in range(x0, x1 + 1):
			var i := iz * _nx + ix
			if _popped[i] == 1:
				continue
			var c := _tile_center(ix, iz)
			var d := Vector2(c.x - lp.x, c.z - lp.z).length()
			var under := absf(c.x - lp.x) <= tile_size * 0.5 and absf(c.z - lp.z) <= tile_size * 0.5
			var f := 1.0 if under else clampf(1.0 - d / r, 0.0, 1.0)
			if f <= 0.0:
				continue
			_energy[i] += energy * f
			if _energy[i] >= Tuning.TILE_BREAK_ENERGY:
				_pop(ix, iz, lp)
				popped += 1
	return popped

## Tiles still in place within `radius` of the world point (tests).
func intact_tiles_near(world_pos: Vector3, radius: float) -> int:
	var lp := to_local(world_pos)
	var n := 0
	for iz in _nz:
		for ix in _nx:
			var c := _tile_center(ix, iz)
			if _popped[iz * _nx + ix] == 0 and Vector2(c.x - lp.x, c.z - lp.z).length() <= radius:
				n += 1
	return n

func _pop(ix: int, iz: int, from_local: Vector3) -> void:
	var i := iz * _nx + ix
	_popped[i] = 1
	popped_count += 1
	var c := _tile_center(ix, iz)
	_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), c))
	if get_parent() == null:
		return
	var b := RigidBody3D.new()
	b.name = "Tile"
	var mi := MeshInstance3D.new()
	mi.mesh = _mm.mesh
	mi.material_override = WorldMaterials.plaza_tile()
	mi.layers = Layers.VIS_WORLD
	b.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = (_mm.mesh as BoxMesh).size * 0.95
	cs.shape = bs
	b.add_child(cs)
	var sz := (_mm.mesh as BoxMesh).size
	b.mass = maxf(sz.x * sz.y * sz.z * TILE_DENSITY, 1.0)
	b.set_meta(&"surface", &"tile")
	var away := Vector3(c.x - from_local.x, 0.0, c.z - from_local.z)
	away = away.normalized() if away.length() > 0.05 else Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized()
	var v := global_basis * (away * randf_range(0.4, 1.2)) + Vector3.UP * randf_range(POP_SPEED.x, POP_SPEED.y)
	b.linear_velocity = v
	b.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-2, 2), randf_range(-6, 6))
	get_parent().add_child(b)
	b.global_transform = global_transform * Transform3D(Basis(), c + Vector3.UP * 0.02)
	b.linear_velocity = v
	DebrisManager.register(b, false)
	DebrisManager.hold_young(b, v.length())
