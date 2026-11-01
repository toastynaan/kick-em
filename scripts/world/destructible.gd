class_name Destructible
extends StaticBody3D
## Pre-fractured wall panel or prop (spec: Destruction). Intact mesh + collider,
## a cracked look, and a hidden set of convex cells generated procedurally
## (PanelFracture). Wall panels break LOCALLY: a hit removes the cells under the
## body's outline (a body-sized hole), cells no longer connected to a supported
## side fall as chunks, and the rest of the panel keeps standing and can be hit
## again. Props (&"crate", &"desk", &"lamp") break whole.
## OWNER: agent D (world). CONTRACT STUB: keep every public signature.
##
## Local frame: the panel face is the XY plane, thickness along Z. Local +Z is
## the "exterior" face (the yard builder points it at the courtyard).
## Concrete panels never break: they sit on Layers.WORLD (so a launched body's
## set_ignore_breakables never lets bones pass through them) and only show a
## crack decal from Tuning.SURFACES.concrete.decal_from J.
##
## Events: this node emits GameEvents.wall_broken (every hole or full break) and
## GameEvents.wall_cracked itself, so ImpactResolver does not emit them again.
## Dust and sound come from BloodFX / AudioFX listening to those events. A
## staged breach (YardBuilder.breach) sets meta &"staged_breach" = true on the
## panel before its wall_broken.

signal broken(position: Vector3, energy: float)
signal cracked(position: Vector3, energy: float)
## A break removed `count` cells; `full` when the whole panel is gone.
signal holed(position: Vector3, count: int, full: bool)

## &"drywall" | &"brick" | &"concrete" | &"wood"  (Tuning.SURFACES)
@export var surface: StringName = &"drywall"
@export var size := Vector3(3.0, 3.0, 0.25)
## Visual style: &"" / &"interior" / &"rolldoor" (slat fracture, dents).
@export var style: StringName = &""
## Fracture pattern variant (0..PanelFracture.VARIANTS-1); -1 picks one from the position.
@export var variant := -1
## &"panel" (local holes) or a prop that breaks whole: &"crate", &"desk", &"lamp".
@export var kind: StringName = &"panel"
## > 0 overrides the surface's break energy (props).
@export var break_energy_override := -1.0
var break_energy := 2000.0
var absorption := 0.3
## True once (nearly) every cell is gone.
var is_broken := false
var is_cracked := false

## Chunk density, kg/m^3. Game values: a 0.25 m drywall panel is a stud wall,
## not solid gypsum, and a chunk must never stop a 70 kg body dead.
const DENSITY := {&"drywall": 80.0, &"brick": 220.0, &"concrete": 400.0, &"wood": 120.0}
const PROP_DENSITY := {&"crate": 500.0, &"desk": 600.0, &"lamp": 300.0}
## Share of the body's exit velocity given to chunks near / far from the hit.
const CHUNK_SHARE_NEAR := 1.15
const CHUNK_SHARE_FAR := 0.6
const CHUNK_RADIAL := Vector2(0.8, 3.0)   ## m/s radial spread (min, max)
const CHUNK_FALLOFF_DIST := 1.4           ## m from the hit where the share bottoms out
const CRACK_DECAL_MAX := 48
## Local holes: the body outline is padded by this much (m) on every side.
const FOOTPRINT_PAD := 0.15
## A cell goes when this fraction of it lies under the padded outline.
const CELL_TAKE_FRACTION := 0.3
## Footprint used when a caller passes none (an upright body).
const DEFAULT_FOOTPRINT := Vector2(0.8, 1.8)
## The panel counts as broken when at most this fraction of its cells is left.
const FULL_BREAK_LEFT := 0.12
## Cracks show on cell edges within this distance (m) of a hit and accumulate.
const CRACK_RADIUS := 1.2
const DENT_RADIUS := 0.9
const DENT_DEPTH := 0.09

## Chunks spawned by the last break (ImpactResolver adds collision exceptions).
var last_chunks: Array[RigidBody3D] = []
## Cell indices removed by the last break.
var last_removed := PackedInt32Array()
var original_break_energy := 2000.0

var _fs: PanelFracture.FractureSet
var _alive := PackedByteArray()
var _alive_count := 0
var _cell_shapes: Array = []
var _box: CollisionShape3D
var _intact: MeshInstance3D
var _crack_lines: MeshInstance3D
var _crack_edges := {}
var _dents: Array = []          ## [Vector2 local point, depth, side]
var _built := false
var _rng := RandomNumberGenerator.new()

static var _decals: Array = []

func _ready() -> void:
	add_to_group(&"destructibles")
	if not _built:
		_build()

func _build() -> void:
	_built = true
	var data: Dictionary = Tuning.SURFACES.get(surface, Tuning.SURFACES[&"drywall"])
	break_energy = break_energy_override if break_energy_override > 0.0 else float(data["break_energy"])
	original_break_energy = break_energy
	absorption = data["absorption"]
	collision_layer = Layers.WORLD if is_unbreakable() else Layers.DESTRUCTIBLE
	collision_mask = 0
	if variant < 0:
		var p := global_position if is_inside_tree() else position
		variant = absi(int(floor(p.x * 1.3) * 7 + floor(p.z * 1.7) * 13 + floor(p.y))) % PanelFracture.VARIANTS
	_rng.seed = hash(get_instance_id())
	if kind == &"panel":
		_fs = PanelFracture.get_set(surface, size, maxi(variant, 0), style)
	else:
		_fs = PanelFracture.get_prop_set(kind, size)
	var n := _fs.chunks.size()
	_alive.resize(n)
	_alive.fill(1)
	_alive_count = n
	_cell_shapes.resize(n)
	_box = CollisionShape3D.new()
	_box.name = "Box"
	var box := BoxShape3D.new()
	if kind == &"lamp":
		box.size = Vector3(size.x, size.y - 0.35, size.z)
		_box.position = Vector3(0, 0.175, 0)
	else:
		box.size = size
	_box.shape = box
	add_child(_box)
	_intact = MeshInstance3D.new()
	_intact.name = "Intact"
	_intact.mesh = _fs.intact_mesh
	_intact.material_override = _material()
	_intact.layers = Layers.VIS_WORLD
	add_child(_intact)
	_crack_lines = MeshInstance3D.new()
	_crack_lines.name = "Cracks"
	_crack_lines.material_override = WorldMaterials.crack()
	_crack_lines.layers = Layers.VIS_WORLD
	_crack_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_crack_lines.visible = false
	add_child(_crack_lines)
	if kind == &"lamp":
		_build_lamp_extras()

func _material() -> Material:
	match kind:
		&"crate", &"desk":
			return WorldMaterials.panel(&"wood", &"planks")
		&"lamp":
			return WorldMaterials.frame()
	return WorldMaterials.panel(surface, style)

func _build_lamp_extras() -> void:
	# Stump (stays after the pole topples) and the lamp head on the intact pole.
	var stump := CollisionShape3D.new()
	var sb := BoxShape3D.new()
	sb.size = Vector3(size.x, 0.35, size.z)
	stump.shape = sb
	stump.position = Vector3(0, -size.y * 0.5 + 0.175, 0)
	add_child(stump)
	var sm := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = sb.size + Vector3(0.06, 0, 0.06)
	sm.mesh = bm
	sm.material_override = WorldMaterials.frame()
	sm.position = stump.position
	add_child(sm)
	_intact.add_child(_lamp_head(Vector3(0, size.y * 0.5, 0)))

static func _lamp_head(top: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "LampHead"
	var arm := MeshInstance3D.new()
	var am := BoxMesh.new()
	am.size = Vector3(0.9, 0.08, 0.08)
	arm.mesh = am
	arm.material_override = WorldMaterials.frame()
	arm.position = top + Vector3(0.4, -0.1, 0)
	root.add_child(arm)
	var head := MeshInstance3D.new()
	var hm := BoxMesh.new()
	hm.size = Vector3(0.45, 0.12, 0.28)
	head.mesh = hm
	head.material_override = WorldMaterials.frame()
	head.position = top + Vector3(0.8, -0.18, 0)
	root.add_child(head)
	var glow := MeshInstance3D.new()
	var gm := BoxMesh.new()
	gm.size = Vector3(0.38, 0.02, 0.22)
	glow.mesh = gm
	glow.material_override = WorldMaterials.lamp_glow()
	glow.position = top + Vector3(0.8, -0.25, 0)
	root.add_child(glow)
	return root

func is_unbreakable() -> bool:
	return is_inf(break_energy) or surface == &"concrete" and kind == &"panel"

## Energy at or above which a hit cracks this panel (INF for concrete).
func get_crack_threshold() -> float:
	if is_unbreakable():
		return INF
	return Tuning.CRACK_FRACTION * break_energy

## World-space unit normal of the face nearest `from` (the side a body hits).
## Panels use their two big faces; props pick the box face toward `from`.
func get_face_normal(from: Vector3) -> Vector3:
	var lp := global_transform.affine_inverse() * from
	var axis := 2
	if kind != &"panel":
		var h := size * 0.5
		var r := Vector3(absf(lp.x) / maxf(h.x, 0.01), absf(lp.y) / maxf(h.y, 0.01), absf(lp.z) / maxf(h.z, 0.01))
		axis = 0 if r.x >= r.y and r.x >= r.z else (1 if r.y >= r.z else 2)
	var n := global_basis[axis].normalized()
	return -n if lp[axis] < 0.0 else n

## Half thickness of the box along world direction `n`.
func get_half_extent_along(n: Vector3) -> float:
	var b := global_basis
	return absf(n.dot(b.x.normalized())) * size.x * 0.5 + absf(n.dot(b.y.normalized())) * size.y * 0.5 \
		+ absf(n.dot(b.z.normalized())) * size.z * 0.5

## Called by ImpactResolver BEFORE contact. Decides break / crack / bounce by
## energy and returns &"break", &"crack" or &"bounce". `footprint` is the
## body's outline in panel-local XY (empty: an upright body at `position`).
## A break of a wall panel punches a hole of that size; props break whole.
func receive_impact(energy: float, position: Vector3, velocity: Vector3, footprint := Rect2()) -> StringName:
	if not _built:
		_build()
	if is_broken:
		return &"break"
	if is_unbreakable():
		var from: float = Tuning.SURFACES.get(surface, {}).get("decal_from", INF)
		if energy >= from:
			is_cracked = true
			spawn_crack_decal(self, position, get_face_normal(position - velocity), energy)
		return &"bounce"
	if energy >= break_energy:
		if kind != &"panel":
			_break_all(position, velocity, energy)
		else:
			var lp := to_local2(position)
			var fp := footprint if footprint.has_area() else Rect2(lp - DEFAULT_FOOTPRINT * 0.5, DEFAULT_FOOTPRINT)
			_break_cells(position, velocity, energy, fp)
		return &"break"
	if energy >= Tuning.CRACK_FRACTION * break_energy:
		_crack(position, energy, velocity)
		return &"crack"
	return &"bounce"

## Scripted full break (the whole panel goes).
func force_break(position: Vector3, velocity: Vector3) -> void:
	if not _built:
		_build()
	if is_broken or is_unbreakable():
		return
	_break_all(position, velocity, maxf(break_energy, 0.0))

## Scripted local hole: removes the cells under `footprint` (panel-local XY).
func break_hole(position: Vector3, velocity: Vector3, footprint: Rect2) -> void:
	if not _built:
		_build()
	if is_broken or is_unbreakable():
		return
	if kind != &"panel":
		_break_all(position, velocity, break_energy)
	else:
		_break_cells(position, velocity, break_energy, footprint)

## Scripted crack (the telegraph before an enemy bursts through): reveals
## cracks within `radius` of `position`, accumulating.
func force_crack(position: Vector3, radius := CRACK_RADIUS) -> void:
	if not _built:
		_build()
	if is_broken or is_unbreakable():
		return
	is_cracked = true
	_reveal_cracks(to_local2(position), radius)
	_update_crack_mesh()
	cracked.emit(position, 0.0)
	GameEvents.wall_cracked.emit(self, position, 0.0)

## True where the panel's cells are gone (holes, or the whole panel broken).
## Points outside the panel's face rectangle (or more than 0.5 m off its
## faces) are never open.
func is_point_open(world_pos: Vector3) -> bool:
	if not _built:
		return false
	var lp := global_transform.affine_inverse() * world_pos
	var h := size * 0.5
	if absf(lp.x) > h.x or absf(lp.y) > h.y or absf(lp.z) > h.z + 0.5:
		return false
	if is_broken:
		return true
	if _alive_count == _alive.size():
		return false
	if kind != &"panel":
		return false
	var p := Vector2(lp.x, lp.y)
	for i in _fs.chunks.size():
		if PanelFracture.point_in_convex((_fs.chunks[i] as PanelFracture.Chunk).polygon, p):
			return _alive[i] == 0
	return false

## Fraction (0..1) of `rect` (panel-local XY, clipped to the panel) with no
## cells left. A rect entirely beside the panel counts as open.
func footprint_open_fraction(rect: Rect2) -> float:
	if not _built:
		_build()
	if is_broken:
		return 1.0
	var face := Rect2(-size.x * 0.5, -size.y * 0.5, size.x, size.y)
	var r := rect.intersection(face)
	if r.get_area() < 1e-4:
		return 1.0
	if _alive_count == _alive.size() or kind != &"panel":
		return 0.0
	var covered := 0.0
	for i in _fs.chunks.size():
		if _alive[i] == 0:
			continue
		var clip := PanelFracture.clip_rect((_fs.chunks[i] as PanelFracture.Chunk).polygon, r)
		if clip.size() >= 3:
			covered += PanelFracture.polygon_area(clip)
	return clampf(1.0 - covered / r.get_area(), 0.0, 1.0)

## Crack edges currently drawn (tests / debug).
func get_crack_edge_count() -> int:
	var n := 0
	for i: int in _crack_edges:
		var e: PanelFracture.CrackEdge = _fs.edges[i]
		if _alive[e.cells.x] == 1 and _alive[e.cells.y] == 1:
			n += 1
	return n

## Dents on a roll door (tests / debug).
func get_dent_count() -> int:
	return _dents.size()

func get_cell_count() -> int:
	return _alive.size()

func get_alive_count() -> int:
	return _alive_count

## World point -> panel-local XY.
func to_local2(world_pos: Vector3) -> Vector2:
	var lp := global_transform.affine_inverse() * world_pos
	return Vector2(lp.x, lp.y)

# --- Crack ----------------------------------------------------------------------

func _crack(position: Vector3, energy: float, velocity := Vector3.ZERO) -> void:
	is_cracked = true
	var lp := to_local2(position)
	var radius := CRACK_RADIUS * clampf(0.6 + 0.4 * energy / maxf(break_energy, 1.0), 0.6, 1.0)
	_reveal_cracks(lp, radius)
	break_energy = maxf(break_energy - 0.5 * energy, 0.0)
	if style == &"rolldoor":
		var side := -1.0 if (global_transform.affine_inverse() * (position - velocity * 0.1)).z >= 0.0 else 1.0
		_dents.append([lp, DENT_DEPTH * clampf(energy / maxf(original_break_energy, 1.0), 0.4, 1.2), side])
		_rebuild()
	else:
		_update_crack_mesh()
	cracked.emit(position, energy)
	GameEvents.wall_cracked.emit(self, position, energy)

func _reveal_cracks(lp: Vector2, radius: float) -> void:
	for i in _fs.edges.size():
		var e: PanelFracture.CrackEdge = _fs.edges[i]
		if e.mid.distance_to(lp) <= radius or e.a.distance_to(lp) <= radius * 0.8 \
				or e.b.distance_to(lp) <= radius * 0.8:
			_crack_edges[i] = true

func _update_crack_mesh() -> void:
	var ids := PackedInt32Array()
	for i: int in _crack_edges:
		var e: PanelFracture.CrackEdge = _fs.edges[i]
		if _alive[e.cells.x] == 1 and _alive[e.cells.y] == 1:
			ids.append(i)
	if ids.is_empty() or is_broken:
		_crack_lines.visible = false
		return
	_crack_lines.mesh = PanelFracture.crack_mesh_for(_fs, ids)
	_crack_lines.visible = true

# --- Break ----------------------------------------------------------------------

## Local hole: remove the cells under the padded footprint, then every cell
## that lost its connection to a supported side (left, right, floor).
func _break_cells(position: Vector3, velocity: Vector3, energy: float, footprint: Rect2) -> void:
	var lp := to_local2(position)
	var padded := footprint.grow(FOOTPRINT_PAD)
	var hit := PackedInt32Array()
	var nearest := -1
	var nearest_d := INF
	for i in _fs.chunks.size():
		if _alive[i] == 0:
			continue
		var c: PanelFracture.Chunk = _fs.chunks[i]
		var d := c.centroid.distance_to(lp)
		if d < nearest_d:
			nearest_d = d
			nearest = i
		var take := padded.has_point(c.centroid)
		if not take:
			var clip := PanelFracture.clip_rect(c.polygon, padded)
			take = clip.size() >= 3 and PanelFracture.polygon_area(clip) >= CELL_TAKE_FRACTION * c.area
		if take:
			hit.append(i)
	if hit.is_empty() and nearest >= 0:
		hit.append(nearest)
	for i in hit:
		_alive[i] = 0
	_alive_count -= hit.size()
	var dropped := _unsupported_cells()
	for i in dropped:
		_alive[i] = 0
	_alive_count -= dropped.size()
	if _alive_count <= maxi(2, int(ceil(_alive.size() * FULL_BREAK_LEFT))):
		for i in _alive.size():
			if _alive[i] == 1:
				dropped.append(i)
				_alive[i] = 0
		_alive_count = 0
		is_broken = true
	is_cracked = true
	_reveal_cracks(lp, CRACK_RADIUS)
	_spawn_chunks(hit, dropped, position, velocity)
	last_removed = hit.duplicate()
	last_removed.append_array(dropped)
	_rebuild()
	holed.emit(position, last_removed.size(), is_broken)
	broken.emit(position, energy)
	GameEvents.wall_broken.emit(self, position, energy, velocity)

## Every remaining cell becomes a chunk.
func _break_all(position: Vector3, velocity: Vector3, energy: float) -> void:
	var all := PackedInt32Array()
	for i in _alive.size():
		if _alive[i] == 1:
			all.append(i)
			_alive[i] = 0
	_alive_count = 0
	is_broken = true
	is_cracked = true
	_spawn_chunks(all, PackedInt32Array(), position, velocity)
	last_removed = all
	_rebuild()
	holed.emit(position, all.size(), true)
	broken.emit(position, energy)
	GameEvents.wall_broken.emit(self, position, energy, velocity)
	if kind == &"crate" or kind == &"desk":
		_break_props_above()

## A stacked prop resting on this one falls apart with it (no floating crates).
func _break_props_above() -> void:
	var top := global_position.y + size.y * 0.5
	for n in get_tree().get_nodes_in_group(&"destructibles"):
		var d := n as Destructible
		if d == null or d == self or d.is_broken or d.kind == &"panel" or d.kind == &"lamp":
			continue
		var bottom := d.global_position.y - d.size.y * 0.5
		var flat := Vector2(d.global_position.x - global_position.x, d.global_position.z - global_position.z)
		if absf(bottom - top) < 0.08 and flat.length() < (size.x + d.size.x) * 0.4:
			d.call_deferred(&"force_break", d.global_position, Vector3(0, -1.0, 0))

## Alive cells not connected (through alive neighbours) to a supported side.
func _unsupported_cells() -> PackedInt32Array:
	var n := _alive.size()
	var reached := PackedByteArray()
	reached.resize(n)
	reached.fill(0)
	var queue: Array[int] = []
	for i in n:
		if _alive[i] == 1 and ((_fs.chunks[i] as PanelFracture.Chunk).edge_mask & PanelFracture.SUPPORT_SIDES) != 0:
			reached[i] = 1
			queue.append(i)
	while not queue.is_empty():
		var i: int = queue.pop_back()
		for j in (_fs.chunks[i] as PanelFracture.Chunk).neighbors:
			if _alive[j] == 1 and reached[j] == 0:
				reached[j] = 1
				queue.append(j)
	var out := PackedInt32Array()
	for i in n:
		if _alive[i] == 1 and reached[i] == 0:
			out.append(i)
	return out

func _spawn_chunks(blast: PackedInt32Array, drop: PackedInt32Array, position: Vector3, velocity: Vector3) -> void:
	last_chunks.clear()
	var xf := global_transform
	var lp := to_local2(position)
	var speed := velocity.length()
	var dir := velocity / speed if speed > 0.01 else -get_face_normal(position)
	var exit_speed := speed * sqrt(maxf(1.0 - absorption, 0.0))
	for i in blast:
		_spawn_chunk(i, xf, lp, dir, exit_speed, false)
	for i in drop:
		_spawn_chunk(i, xf, lp, dir, exit_speed, true)

func _spawn_chunk(i: int, xf: Transform3D, lp: Vector2, dir: Vector3, exit_speed: float, dropped: bool) -> void:
	var c: PanelFracture.Chunk = _fs.chunks[i]
	var body := RigidBody3D.new()
	body.name = "Chunk"
	var mi := MeshInstance3D.new()
	mi.mesh = c.mesh
	mi.material_override = _material()
	mi.layers = Layers.VIS_WORLD
	body.add_child(mi)
	if kind == &"lamp":
		body.add_child(_lamp_head(Vector3(0, size.y * 0.5 - c.origin.y, 0)))
	var cs := CollisionShape3D.new()
	cs.shape = c.shape
	body.add_child(cs)
	var density: float = PROP_DENSITY.get(kind, DENSITY.get(surface, 100.0))
	body.mass = maxf(c.volume * density, 0.5)
	body.physics_material_override = _chunk_physics_material()
	body.transform = xf * Transform3D(Basis(), c.origin)
	body.set_meta(&"surface", &"wood" if kind == &"crate" or kind == &"desk" else surface)
	var v: Vector3
	var w: Vector3
	if kind == &"lamp":
		# The pole topples away from the hit.
		var away := Vector3(dir.x, 0.0, dir.z).normalized() if Vector2(dir.x, dir.z).length() > 0.01 else Vector3.RIGHT
		v = away * exit_speed * 0.25
		w = Vector3.UP.cross(away) * clampf(exit_speed * 0.35, 1.0, 3.0)
	elif dropped:
		v = dir * _rng.randf_range(0.3, 1.0) + Vector3(_rng.randf_range(-0.4, 0.4), 0.2, _rng.randf_range(-0.4, 0.4))
		w = Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * 1.2
	else:
		var r := Vector2(c.centroid.x - lp.x, c.centroid.y - lp.y)
		var dist := r.length()
		var near := clampf(1.0 - dist / CHUNK_FALLOFF_DIST, 0.0, 1.0)
		var radial := (xf.basis * Vector3(r.x, r.y, 0.0)).normalized() if dist > 0.01 else Vector3.UP
		var share := lerpf(CHUNK_SHARE_FAR, CHUNK_SHARE_NEAR, near)
		v = dir * exit_speed * share * _rng.randf_range(0.85, 1.1)
		v += radial * _rng.randf_range(CHUNK_RADIAL.x, CHUNK_RADIAL.y) * (0.4 + 0.6 * near)
		v += Vector3.UP * _rng.randf_range(0.0, 1.2)
		w = Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * (1.5 + 4.0 * near)
	body.linear_velocity = v
	body.angular_velocity = w
	(get_parent() if get_parent() else self).add_child(body)
	body.linear_velocity = v
	body.angular_velocity = w
	DebrisManager.register(body, c.small and kind != &"lamp")
	last_chunks.append(body)

static var _chunk_pm: PhysicsMaterial

static func _chunk_physics_material() -> PhysicsMaterial:
	if _chunk_pm == null:
		_chunk_pm = PhysicsMaterial.new()
		_chunk_pm.friction = 0.85
		_chunk_pm.bounce = 0.05
	return _chunk_pm

## Visual + collision for the cells still standing.
func _rebuild() -> void:
	if is_broken:
		_intact.visible = false
		_crack_lines.visible = false
		_box.disabled = true
		for i in _cell_shapes.size():
			if _cell_shapes[i] != null:
				(_cell_shapes[i] as CollisionShape3D).queue_free()
				_cell_shapes[i] = null
		if kind != &"lamp":
			collision_layer = 0   # a toppled lamp keeps its stump
		return
	var partial := _alive_count < _alive.size()
	if partial or not _dents.is_empty():
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for i in _alive.size():
			if _alive[i] == 1:
				var c: PanelFracture.Chunk = _fs.chunks[i]
				st.append_from(c.mesh, 0, Transform3D(Basis(), c.origin))
		var mesh := st.commit()
		if not _dents.is_empty():
			mesh = _apply_dents(mesh)
		_intact.mesh = mesh
	if partial:
		_box.disabled = true
		for i in _alive.size():
			var has: bool = _cell_shapes[i] != null
			if _alive[i] == 1 and not has:
				var cs := CollisionShape3D.new()
				cs.shape = (_fs.chunks[i] as PanelFracture.Chunk).static_shape
				add_child(cs)
				_cell_shapes[i] = cs
			elif _alive[i] == 0 and has:
				(_cell_shapes[i] as CollisionShape3D).queue_free()
				_cell_shapes[i] = null
	_update_crack_mesh()

func _apply_dents(mesh: ArrayMesh) -> ArrayMesh:
	if mesh.get_surface_count() == 0:
		return mesh
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for k in verts.size():
		var v := verts[k]
		var dz := 0.0
		for d: Array in _dents:
			var dist := Vector2(v.x, v.y).distance_to(d[0])
			if dist < DENT_RADIUS:
				var f := 1.0 - dist / DENT_RADIUS
				dz += float(d[1]) * f * f * float(d[2])
		v.z += dz
		verts[k] = v
	arrays[Mesh.ARRAY_VERTEX] = verts
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out

## Concrete impact crack decal (also used by ImpactResolver for WORLD walls and
## pillars). `normal` points out of the surface. Capped at CRACK_DECAL_MAX.
static func spawn_crack_decal(context: Node, position: Vector3, normal: Vector3, energy: float) -> Decal:
	if context == null or not context.is_inside_tree():
		return null
	var d := Decal.new()
	d.texture_albedo = WorldMaterials.crack_decal_texture()
	d.modulate = Color(0.12, 0.11, 0.1, 0.9)
	var s := clampf(0.9 + energy / 9000.0, 1.0, 2.2)
	d.size = Vector3(s, 0.3, s)
	d.cull_mask = Layers.VIS_WORLD
	d.upper_fade = 0.2
	d.lower_fade = 0.2
	d.normal_fade = 0.4
	var root := context.get_tree().current_scene if context.get_tree().current_scene else context
	root.add_child(d)
	var n := normal.normalized()
	var ref := Vector3.FORWARD if absf(n.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var x := ref.cross(n).normalized()
	var z := x.cross(n).normalized()
	d.global_transform = Transform3D(Basis(x, n, z).rotated(n, randf() * TAU), position)
	_decals = _decals.filter(func(o: Variant) -> bool: return is_instance_valid(o))
	_decals.append(d)
	while _decals.size() > CRACK_DECAL_MAX:
		var old: Variant = _decals.pop_front()
		if is_instance_valid(old):
			old.queue_free()
	return d
