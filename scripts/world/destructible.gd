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
## Round 5 (Feel Reference: Launch speed and walls): every surface breaks by
## E = 1/2 M v^2 (speed straight into the face) against Tuning.SURFACES; a hit
## from Tuning.CRACK_FRACTION of the break energy cracks the panel and lowers
## its break energy by half the hit's energy. Concrete panels (15,000 J) never
## break in one hit at the 18 m/s cap; a second one does. Only panels with
## `unbreakable` (arena boundary) never break: they sit on Layers.WORLD (so a
## launched body's set_ignore_breakables never lets bones pass through them)
## and only crack (decal). Panels are runnable (WorldTags) while intact.
##
## Round 6: part of the breakable contract (group "breakables", receive_impact,
## receive_strike, receive_blast). Cells a hole leaves without support (no path
## through standing cells to a side in `support_mask`) fall Tuning.COLLAPSE_DELAY
## s later, after GameEvents.structure_collapsed (kind &"panel") so the dust and
## creak come first: no panel ever keeps floating cells. Door frames are kinds
## &"jamb" (breaks whole) and &"lintel" (falls when a jamb under it breaks).
##
## Events: this node emits GameEvents.wall_broken (every hole or full break,
## strike-made holes included) and GameEvents.wall_cracked itself, so
## ImpactResolver does not emit them again. Strikes also emit wall_struck.
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
## &"panel" (local holes) or a prop that breaks whole: &"crate", &"desk", &"lamp",
## and the Round 6 door frames &"jamb" and &"lintel".
@export var kind: StringName = &"panel"
## > 0 overrides the surface's break energy (props).
@export var break_energy_override := -1.0
## Arena boundary: never breaks, only cracks (Round 5 lead decision 7).
@export var unbreakable := false
## Panel sides that hold cells up (PanelFracture.SIDE_*): walls between columns
## are held left, right and below; free-standing partitions and low walls only below.
@export var support_mask := PanelFracture.SUPPORT_SIDES
var break_energy := 2000.0
var absorption := 0.3
## True once (nearly) every cell is gone.
var is_broken := false
var is_cracked := false

## Panels lower than this (low walls) are vaulted, not run along.
const RUNNABLE_MIN_HEIGHT := 2.0
## Chunk density, kg/m^3. Game values: a 0.25 m drywall panel is a stud wall,
## not solid gypsum, and a chunk must never stop a 70 kg body dead.
const DENSITY := {&"drywall": 80.0, &"brick": 220.0, &"concrete": 400.0, &"wood": 120.0}
const PROP_DENSITY := {&"crate": 500.0, &"desk": 600.0, &"lamp": 300.0, &"jamb": 300.0, &"lintel": 200.0}
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
## Wall strikes (round 3). Local constants, candidates for Tuning.
## The half-power spread radius grows with power above STRIKE_REF_POWER (a
## kick), so a charged kick opens a body-sized hole.
const STRIKE_REF_POWER := 60.0
const STRIKE_SPREAD_PER_POWER := 0.006    ## m of radius per power point above the reference
const STRIKE_SPREAD_MAX := 1.0
## When a cell breaks, neighbours at this fraction of their HP crumble with it.
const CRUMBLE_FRACTION := 0.6
## A fully damaged cell sinks this far into the wall and tilts this much.
const LOOSEN_DEPTH := 0.035
const LOOSEN_TILT := 0.07                 ## rad
## Speed (m/s) a struck-out cell leaves the wall along the strike.
const STRIKE_PUSH := 2.5
## Props: strike HP before they break (crate ~2 kicks, desk ~3, lamp ~6).
const PROP_STRIKE_HP := {&"crate": 110.0, &"desk": 170.0, &"lamp": 330.0, &"jamb": 200.0, &"lintel": 300.0}
## Blasts (Round 6): from this share of the crack energy a blast pops chips; from
## the crack energy itself it cracks (and weakens) the panel or prop. Blasts never
## break walls or furniture; glass shatters.
const BLAST_CHIP_SHARE := 0.4
## Weakened walls: a fully damaged footprint needs (1 - WEAKEN_MAX) of the
## break energy. A wall gives at its worst spot: the weakness is at least
## WEAK_SPOT_SHARE x the most damaged part of the footprint (a hole counts as 1).
const WEAKEN_MAX := 0.85
const WEAK_SPOT_SHARE := 0.75

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
var _cell_dmg := PackedFloat32Array()   ## strike damage per cell (round 3)
var _cell_sink := PackedFloat32Array()  ## signed local-z offset of a loosened cell
var _prop_dmg := 0.0
var _loosened := false
## Break energy the last receive_impact needed after weakening (tests / debug).
var last_impact_break_energy := 0.0
## Strike-made holes in this panel (each strike that removed cells, or a prop
## broken by strikes). Incremented before that strike's GameEvents.wall_broken.
var strike_holes := 0
## True when the latest GameEvents.wall_broken from this panel came from a
## strike (HUD: no banner for every jab that widens a hole); false after an
## impact, scripted or breach break.
var last_break_by_strike := false
## A door frame's lintel (on each jamb): it falls when a jamb under it breaks.
var lintel: Destructible = null
var _collapse_pending := false
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
	set_meta(&"surface", &"wood" if kind == &"crate" or kind == &"desk" else surface)
	add_to_group(&"breakables")
	if kind == &"panel":
		add_to_group(&"runnable")
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
	_cell_dmg.resize(n)
	_cell_dmg.fill(0.0)
	_cell_sink.resize(n)
	_cell_sink.fill(0.0)
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
		&"crate", &"desk", &"jamb", &"lintel":
			return WorldMaterials.panel(&"wood", &"planks")
		&"lamp":
			return WorldMaterials.frame()
	if style == &"boards":
		return WorldMaterials.panel(&"wood", &"planks")
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
	return unbreakable or is_inf(break_energy)

## Energy at or above which a hit cracks this panel (INF for unbreakable ones:
## they only ever crack, so bones never ignore them).
func get_crack_threshold() -> float:
	if is_unbreakable():
		return INF
	return Tuning.CRACK_FRACTION * break_energy

## The collision box (ImpactResolver sweeps against it; Pillar has the same).
func get_box_transform() -> Transform3D:
	return global_transform

## WorldTags (wall runs): an intact wall panel at least RUNNABLE_MIN_HEIGHT
## tall is runnable; a cracked, holed or broken one is not, nor a low wall, and
## props never are.
func is_runnable() -> bool:
	return kind == &"panel" and size.y >= RUNNABLE_MIN_HEIGHT and not is_cracked and not is_broken \
		and _alive_count == _alive.size()

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

## Round 3 contract: a punch or kick landed here. `direction` is the strike's
## world direction (into the wall), `power` the strike power (Tuning, Wall
## strikes). Wall panels: the cell under the contact takes the full power, the
## cells within the spread radius half (STRIKE_SPREAD, wider for strong hits);
## per-cell HP is Tuning.STRIKE_CELL_HP[surface] and damage stays for the round.
## Every hit shows progress: cracks grow around the contact, small chips pop
## out, damaged cells sink and tilt; a cell out of HP breaks out along
## `direction` (neighbours already past CRUMBLE_FRACTION go with it), and the
## partial-fracture rules drop unsupported cells and collapse a panel that is
## nearly gone. Props take PROP_STRIKE_HP and break whole. Concrete panels
## only crack (decal). Emits GameEvents.wall_struck.
## Returns &"chip" | &"crack" | &"hole" | &"break" | &"hold".
func receive_strike(attacker: Node3D, hit_pos: Vector3, direction: Vector3, power: float) -> StringName:
	if not _built:
		_build()
	var n := get_face_normal(hit_pos - direction * 0.5)
	var result := &"hold"
	if is_broken or power <= 0.0:
		result = &"hold"
	elif is_unbreakable():
		_strike_decal(hit_pos, n, power)
		_spawn_strike_chips(hit_pos, n, direction, power)
		result = &"hold"
	elif kind != &"panel":
		result = _strike_prop(hit_pos, direction, power)
	else:
		result = _strike_panel(hit_pos, n, direction, power)
	GameEvents.wall_struck.emit(attacker, self, hit_pos, n, power, result, surface)
	return result

## Called by ImpactResolver BEFORE contact. Decides break / crack / bounce by
## energy and returns &"break", &"crack" or &"bounce". `footprint` is the
## body's outline in panel-local XY (empty: an upright body at `hit_pos`).
## A break of a wall panel punches a hole of that size; props break whole.
## Strike damage weakens the panel: under a damaged or partly open footprint
## the break energy drops in proportion (WEAKEN_MAX at most).
func receive_impact(energy: float, hit_pos: Vector3, velocity: Vector3, footprint := Rect2()) -> StringName:
	if not _built:
		_build()
	if is_broken:
		return &"break"
	if is_unbreakable():
		# Boundary: cracks (decal) from the surface's crack energy, never breaks.
		var data: Dictionary = Tuning.SURFACES.get(surface, Tuning.SURFACES[&"concrete"])
		if energy >= Tuning.CRACK_FRACTION * float(data["break_energy"]):
			is_cracked = true
			spawn_crack_decal(self, hit_pos, get_face_normal(hit_pos - velocity), energy)
			cracked.emit(hit_pos, energy)
			GameEvents.wall_cracked.emit(self, hit_pos, energy)
			return &"crack"
		return &"bounce"
	var fp := footprint
	if kind == &"panel" and not fp.has_area():
		fp = Rect2(to_local2(hit_pos) - DEFAULT_FOOTPRINT * 0.5, DEFAULT_FOOTPRINT)
	var need := break_energy * (1.0 - WEAKEN_MAX * weakness(fp)) if kind == &"panel" else break_energy
	last_impact_break_energy = need
	if energy >= need:
		if kind != &"panel":
			_break_all(hit_pos, velocity, energy)
		else:
			_break_cells(hit_pos, velocity, energy, fp)
		return &"break"
	if energy >= Tuning.CRACK_FRACTION * need:
		_crack(hit_pos, energy, velocity)
		return &"crack"
	return &"bounce"

## Round 6 breakable contract: a blast (WorldDamage) reached this object with
## `power` J (already attenuated by distance) from `center`. Glass shatters;
## anything else cracks (and is weakened by the crack rule) from its crack
## energy, or pops chips from BLAST_CHIP_SHARE of it. Walls and props never
## break from a blast. Returns &"break", &"crack", &"chip" or &"hold".
func receive_blast(center: Vector3, _radius: float, power: float, _source: StringName) -> StringName:
	if not _built:
		_build()
	if is_broken or power <= 0.0:
		return &"hold"
	var p := nearest_point(center)
	var away := p - center
	away = away.normalized() if away.length() > 0.01 else Vector3.UP
	if surface == &"glass":
		_break_all(p, away * 2.0, power)
		return &"break"
	var data: Dictionary = Tuning.SURFACES.get(surface, Tuning.SURFACES[&"drywall"])
	var crack_at := Tuning.CRACK_FRACTION * (float(data["break_energy"]) if is_unbreakable() else break_energy)
	var n := get_face_normal(center)
	if power >= crack_at:
		if is_unbreakable():
			is_cracked = true
			spawn_crack_decal(self, p, n, power)
			cracked.emit(p, power)
			GameEvents.wall_cracked.emit(self, p, power)
		else:
			_crack(p, power, away)
		_spawn_strike_chips(p, n, -n, minf(power * 0.05, 120.0))
		return &"crack"
	if power >= BLAST_CHIP_SHARE * crack_at:
		_spawn_strike_chips(p, n, -n, minf(power * 0.05, 60.0))
		return &"chip"
	return &"hold"

## The point of this object's box nearest `world_pos`.
func nearest_point(world_pos: Vector3) -> Vector3:
	var xf := global_transform
	var lp := xf.affine_inverse() * world_pos
	var h := size * 0.5
	return xf * lp.clamp(-h, h)

## Cells standing with no path to a supported side right now (tests, debug):
## 0 except during the Tuning.COLLAPSE_DELAY after a hole.
func get_floating_cell_count() -> int:
	if not _built or is_broken or kind != &"panel":
		return 0
	return _unsupported_cells().size()

## True while unsupported cells wait to fall.
func is_collapse_pending() -> bool:
	return _collapse_pending

## Scripted full break (the whole panel goes).
func force_break(hit_pos: Vector3, velocity: Vector3) -> void:
	if not _built:
		_build()
	if is_broken or is_unbreakable():
		return
	_break_all(hit_pos, velocity, maxf(break_energy, 0.0))

## Scripted local hole: removes the cells under `footprint` (panel-local XY).
func break_hole(hit_pos: Vector3, velocity: Vector3, footprint: Rect2) -> void:
	if not _built:
		_build()
	if is_broken or is_unbreakable():
		return
	if kind != &"panel":
		_break_all(hit_pos, velocity, break_energy)
	else:
		_break_cells(hit_pos, velocity, break_energy, footprint)

## Scripted crack (the telegraph before an enemy bursts through): reveals
## cracks within `radius` of `hit_pos`, accumulating.
func force_crack(hit_pos: Vector3, radius := CRACK_RADIUS) -> void:
	if not _built:
		_build()
	if is_broken or is_unbreakable():
		return
	is_cracked = true
	_reveal_cracks(to_local2(hit_pos), radius)
	_update_crack_mesh()
	cracked.emit(hit_pos, 0.0)
	GameEvents.wall_cracked.emit(self, hit_pos, 0.0)

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

func _crack(hit_pos: Vector3, energy: float, velocity := Vector3.ZERO) -> void:
	is_cracked = true
	var lp := to_local2(hit_pos)
	var radius := CRACK_RADIUS * clampf(0.6 + 0.4 * energy / maxf(break_energy, 1.0), 0.6, 1.0)
	_reveal_cracks(lp, radius)
	break_energy = maxf(break_energy - 0.5 * energy, 0.0)
	if style == &"rolldoor":
		var side := -1.0 if (global_transform.affine_inverse() * (hit_pos - velocity * 0.1)).z >= 0.0 else 1.0
		_dents.append([lp, DENT_DEPTH * clampf(energy / maxf(original_break_energy, 1.0), 0.4, 1.2), side])
		_rebuild()
	else:
		_update_crack_mesh()
	cracked.emit(hit_pos, energy)
	GameEvents.wall_cracked.emit(self, hit_pos, energy)

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
func _break_cells(hit_pos: Vector3, velocity: Vector3, energy: float, footprint: Rect2) -> void:
	var lp := to_local2(hit_pos)
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
	var dropped := _settle_cells()
	is_cracked = true
	_reveal_cracks(lp, CRACK_RADIUS)
	_spawn_chunks(hit, dropped, hit_pos, velocity)
	last_removed = hit.duplicate()
	last_removed.append_array(dropped)
	_rebuild()
	holed.emit(hit_pos, last_removed.size(), is_broken)
	broken.emit(hit_pos, energy)
	last_break_by_strike = false
	GameEvents.wall_broken.emit(self, hit_pos, energy, velocity)

## Every remaining cell becomes a chunk. by_strike: a prop broken by strikes.
func _break_all(hit_pos: Vector3, velocity: Vector3, energy: float, by_strike := false) -> void:
	var all := PackedInt32Array()
	for i in _alive.size():
		if _alive[i] == 1:
			all.append(i)
			_alive[i] = 0
	_alive_count = 0
	is_broken = true
	is_cracked = true
	_spawn_chunks(all, PackedInt32Array(), hit_pos, velocity)
	last_removed = all
	_rebuild()
	holed.emit(hit_pos, all.size(), true)
	broken.emit(hit_pos, energy)
	if by_strike:
		strike_holes += 1
	last_break_by_strike = by_strike
	GameEvents.wall_broken.emit(self, hit_pos, energy, velocity)
	if kind == &"crate" or kind == &"desk":
		_break_props_above()
	if kind == &"jamb" and lintel != null and is_instance_valid(lintel) and not lintel.is_broken:
		lintel.collapse_after(Tuning.COLLAPSE_DELAY)

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

## After cells were taken out: a panel that is nearly gone loses everything left
## now (returned for spawning, is_broken set); otherwise cells left without
## support fall after Tuning.COLLAPSE_DELAY (structure_collapsed first).
func _settle_cells() -> PackedInt32Array:
	var dropped := _unsupported_cells()
	if _alive_count - dropped.size() <= maxi(2, int(ceil(_alive.size() * FULL_BREAK_LEFT))):
		var all := PackedInt32Array()
		for i in _alive.size():
			if _alive[i] == 1:
				all.append(i)
				_alive[i] = 0
		_alive_count = 0
		is_broken = true
		return all
	if not dropped.is_empty():
		_schedule_collapse(dropped)
	return PackedInt32Array()

## Unsupported cells creak (structure_collapsed: dust and sound first), then fall.
func _schedule_collapse(cells: PackedInt32Array) -> void:
	if _collapse_pending or not is_inside_tree():
		return
	_collapse_pending = true
	var c := Vector2.ZERO
	for i in cells:
		c += (_fs.chunks[i] as PanelFracture.Chunk).centroid
	c /= float(cells.size())
	GameEvents.structure_collapsed.emit(self, global_transform * Vector3(c.x, c.y, 0.0), &"panel")
	get_tree().create_timer(Tuning.COLLAPSE_DELAY, false, true).timeout.connect(_do_collapse)

func _do_collapse() -> void:
	_collapse_pending = false
	if is_broken or not is_inside_tree():
		return
	var dropped := _unsupported_cells()
	if dropped.is_empty():
		return
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
	var xf := global_transform
	for i in dropped:
		_spawn_chunk(i, xf, (_fs.chunks[i] as PanelFracture.Chunk).centroid, Vector3.DOWN, 0.5, true)
	_rebuild()

## A lintel or other piece held up by something that broke: it creaks
## (structure_collapsed), then falls whole after `delay` s.
func collapse_after(delay: float) -> void:
	if is_broken or _collapse_pending or not is_inside_tree():
		return
	_collapse_pending = true
	GameEvents.structure_collapsed.emit(self, global_position, kind)
	get_tree().create_timer(delay, false, true).timeout.connect(func() -> void:
		_collapse_pending = false
		if is_instance_valid(self) and not is_broken:
			_break_all(global_position, Vector3.DOWN * 0.5, 0.0))

## Alive cells not connected (through alive neighbours) to a supported side.
func _unsupported_cells() -> PackedInt32Array:
	var n := _alive.size()
	var reached := PackedByteArray()
	reached.resize(n)
	reached.fill(0)
	var queue: Array[int] = []
	for i in n:
		if _alive[i] == 1 and ((_fs.chunks[i] as PanelFracture.Chunk).edge_mask & support_mask) != 0:
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

func _spawn_chunks(blast: PackedInt32Array, drop: PackedInt32Array, hit_pos: Vector3, velocity: Vector3) -> void:
	last_chunks.clear()
	var xf := global_transform
	var lp := to_local2(hit_pos)
	var speed := velocity.length()
	var dir := velocity / speed if speed > 0.01 else -get_face_normal(hit_pos)
	var exit_speed := speed * sqrt(maxf(1.0 - absorption, 0.0))
	for i in blast:
		_spawn_chunk(i, xf, lp, dir, exit_speed, false, speed)
	for i in drop:
		_spawn_chunk(i, xf, lp, dir, exit_speed, true, speed)

## `ref_speed`: the break's reference speed (the hitting body's) for
## DebrisManager.hold_young; below exit_speed it is exit_speed.
func _spawn_chunk(i: int, xf: Transform3D, lp: Vector2, dir: Vector3, exit_speed: float, dropped: bool,
		ref_speed := -1.0) -> void:
	var c: PanelFracture.Chunk = _fs.chunks[i]
	# A lintel's halves come down on whoever stands in the doorway (FallingPiece).
	var body: RigidBody3D = FallingPiece.new() if kind == &"lintel" else RigidBody3D.new()
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
	# Round 5: every piece stays for the round (DebrisManager caps the total).
	DebrisManager.register(body, c.small and kind != &"lamp")
	DebrisManager.hold_young(body, maxf(ref_speed, exit_speed))
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
	if partial or not _dents.is_empty() or _loosened:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for i in _alive.size():
			if _alive[i] == 1:
				var c: PanelFracture.Chunk = _fs.chunks[i]
				st.append_from(c.mesh, 0, _cell_visual_xf(i, c))
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

## Where a cell is drawn: its rest place, sunk and tilted by strike damage.
func _cell_visual_xf(i: int, c: PanelFracture.Chunk) -> Transform3D:
	var sink := _cell_sink[i] if i < _cell_sink.size() else 0.0
	if is_zero_approx(sink):
		return Transform3D(Basis(), c.origin)
	var f := absf(sink) / LOOSEN_DEPTH
	var axis := Vector3(sin(i * 2.399), cos(i * 2.399), 0.0)
	return Transform3D(Basis(axis, LOOSEN_TILT * f * signf(sink)), c.origin + Vector3(0, 0, sink))

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

# --- Strikes (round 3) ---------------------------------------------------------

func _strike_panel(hit_pos: Vector3, n: Vector3, direction: Vector3, power: float) -> StringName:
	var hp: float = Tuning.STRIKE_CELL_HP.get(surface, 200.0)
	var lp := to_local2(hit_pos)
	var contact := _cell_near(lp, 0.45)
	if contact < 0:
		return &"hold"
	var radius := clampf(Tuning.STRIKE_SPREAD + STRIKE_SPREAD_PER_POWER * maxf(power - STRIKE_REF_POWER, 0.0),
		Tuning.STRIKE_SPREAD, STRIKE_SPREAD_MAX)
	var side := -1.0 if (global_transform.affine_inverse() * (hit_pos - direction * 0.3)).z >= 0.0 else 1.0
	for i in _alive.size():
		if _alive[i] == 0:
			continue
		var share := 1.0 if i == contact else 0.0
		if i != contact and _poly_distance((_fs.chunks[i] as PanelFracture.Chunk).polygon, lp) <= radius:
			share = 0.5
		if share <= 0.0:
			continue
		_cell_dmg[i] += power * share
		var f := clampf(_cell_dmg[i] / hp, 0.0, 1.0)
		_cell_sink[i] = side * LOOSEN_DEPTH * f
		_loosened = true
	# Cells out of HP break out; neighbours past CRUMBLE_FRACTION go with them.
	var out := PackedInt32Array()
	for i in _alive.size():
		if _alive[i] == 1 and _cell_dmg[i] >= hp:
			out.append(i)
	var k := 0
	while k < out.size():
		for j in (_fs.chunks[out[k]] as PanelFracture.Chunk).neighbors:
			if _alive[j] == 1 and not out.has(j) and _cell_dmg[j] >= CRUMBLE_FRACTION * hp:
				out.append(j)
		k += 1
	var frac := clampf(_cell_dmg[contact] / hp, 0.0, 1.0)
	_spawn_strike_chips(hit_pos, n, direction, power)
	if style == &"rolldoor":
		_dents.append([lp, DENT_DEPTH * clampf(power / STRIKE_REF_POWER, 0.4, 1.5), side])
	if out.is_empty():
		var before := _crack_edges.size()
		_reveal_cracks(lp, 0.2 + 0.8 * frac)
		is_cracked = is_cracked or _crack_edges.size() > before
		_rebuild()
		return &"crack" if frac >= 0.34 else &"chip"
	for i in out:
		_alive[i] = 0
	_alive_count -= out.size()
	var dropped := _settle_cells()
	is_cracked = true
	_reveal_cracks(lp, 0.6 + 0.6 * frac)
	_spawn_chunks_struck(out, dropped, lp, direction)
	last_removed = out.duplicate()
	last_removed.append_array(dropped)
	_rebuild()
	holed.emit(hit_pos, last_removed.size(), is_broken)
	if is_broken:
		broken.emit(hit_pos, power)
	# Cells left: tell everyone (AI nav, blood decals, camera, HUD) like any break.
	strike_holes += 1
	last_break_by_strike = true
	GameEvents.wall_broken.emit(self, hit_pos, power, _strike_dir(direction) * STRIKE_PUSH)
	return &"break" if is_broken else &"hole"

## The direction struck-out cells leave in (also the wall_broken velocity).
func _strike_dir(direction: Vector3) -> Vector3:
	return direction.normalized() if direction.length() > 0.01 else -get_face_normal(global_position)

## Struck-out cells leave along the strike; unsupported ones just drop.
func _spawn_chunks_struck(out: PackedInt32Array, drop: PackedInt32Array, lp: Vector2, direction: Vector3) -> void:
	last_chunks.clear()
	var xf := global_transform
	var dir := _strike_dir(direction)
	for i in out:
		_spawn_chunk(i, xf, lp, dir, STRIKE_PUSH, false)
	for i in drop:
		_spawn_chunk(i, xf, lp, dir, 1.0, true)

func _strike_prop(hit_pos: Vector3, direction: Vector3, power: float) -> StringName:
	var hp: float = PROP_STRIKE_HP.get(kind, 150.0)
	_prop_dmg += power
	if _prop_dmg >= hp:
		_break_all(hit_pos, direction.normalized() * STRIKE_PUSH * 2.0, power, true)
		return &"break"
	# Knocked a little out of place: the prop shifts along the strike.
	var f := clampf(_prop_dmg / hp, 0.0, 1.0)
	_intact.position = (global_basis.inverse() * Vector3(direction.x, 0.0, direction.z)).normalized() * 0.04 * f
	_spawn_strike_chips(hit_pos, get_face_normal(hit_pos - direction * 0.5), direction, power)
	return &"crack" if f >= 0.34 else &"chip"

## Index of the alive cell containing `lp`, else the nearest alive cell within
## `max_dist` of it, else -1.
func _cell_near(lp: Vector2, max_dist: float) -> int:
	var best := -1
	var best_d := max_dist
	for i in _alive.size():
		if _alive[i] == 0:
			continue
		var d := _poly_distance((_fs.chunks[i] as PanelFracture.Chunk).polygon, lp)
		if d <= 0.0:
			return i
		if d < best_d:
			best_d = d
			best = i
	return best

## 0 inside the convex polygon, else the distance to its nearest edge.
static func _poly_distance(poly: PackedVector2Array, p: Vector2) -> float:
	if PanelFracture.point_in_convex(poly, p):
		return 0.0
	var best := INF
	for k in poly.size():
		var a := poly[k]
		var b := poly[(k + 1) % poly.size()]
		var ab := b - a
		var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best

## Damage fraction (0..1) of `rect` (panel-local XY): open area counts as 1,
## standing cells by their strike damage over HP, area-weighted, and never less
## than WEAK_SPOT_SHARE x the worst spot in it.
func weakness(rect: Rect2) -> float:
	if not _built or kind != &"panel":
		return 0.0
	var face := Rect2(-size.x * 0.5, -size.y * 0.5, size.x, size.y)
	var r := rect.intersection(face)
	var area := r.get_area()
	if area < 1e-4:
		return 0.0
	var hp: float = Tuning.STRIKE_CELL_HP.get(surface, 200.0)
	var covered := 0.0
	var damaged := 0.0
	var worst := 0.0
	for i in _fs.chunks.size():
		if _alive[i] == 0:
			continue
		var clip := PanelFracture.clip_rect((_fs.chunks[i] as PanelFracture.Chunk).polygon, r)
		if clip.size() < 3:
			continue
		var a := PanelFracture.polygon_area(clip)
		var f := clampf(_cell_dmg[i] / hp, 0.0, 1.0)
		covered += a
		damaged += a * f
		worst = maxf(worst, f)
	var open := maxf(area - covered, 0.0)
	if open > 0.01:
		worst = 1.0
	return clampf(maxf((open + damaged) / area, WEAK_SPOT_SHARE * worst), 0.0, 1.0)

## Strike damage taken by the cell under `world_pos` (tests / debug).
func get_cell_damage_at(world_pos: Vector3) -> float:
	var i := _cell_near(to_local2(world_pos), 0.0)
	return _cell_dmg[i] if i >= 0 else 0.0

## Tiny chips popping off the struck face (StrikeMarks, small timed debris).
func _spawn_strike_chips(hit_pos: Vector3, n: Vector3, direction: Vector3, power: float) -> void:
	StrikeMarks.chips(self, hit_pos, n, direction, power,
		&"wood" if kind == &"crate" or kind == &"desk" else surface)

## Concrete panel strike: a crack decal that grows with repeated hits nearby.
func _strike_decal(hit_pos: Vector3, n: Vector3, power: float) -> void:
	is_cracked = true
	_prop_dmg += power
	if _prop_dmg - float(get_meta(&"last_decal_dmg", -INF)) >= 120.0:
		set_meta(&"last_decal_dmg", _prop_dmg)
		spawn_crack_decal(self, hit_pos, n, 3000.0 + _prop_dmg * 4.0)

## Concrete impact crack decal (also used by ImpactResolver for WORLD walls and
## pillars). `normal` points out of the surface. Capped at CRACK_DECAL_MAX.
static func spawn_crack_decal(context: Node, hit_pos: Vector3, normal: Vector3, energy: float) -> Decal:
	if context == null or not context.is_inside_tree():
		return null
	var d := Decal.new()
	d.texture_albedo = WorldMaterials.crack_decal_texture()
	d.modulate = Color(0.12, 0.11, 0.1, 0.9)
	var s := clampf(0.9 + energy / 9000.0, 1.0, 2.2) if energy > 0.0 else 0.6
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
	d.global_transform = Transform3D(Basis(x, n, z).rotated(n, randf() * TAU), hit_pos)
	_decals = _decals.filter(func(o: Variant) -> bool: return is_instance_valid(o))
	_decals.append(d)
	while _decals.size() > CRACK_DECAL_MAX:
		var old: Variant = _decals.pop_front()
		if is_instance_valid(old):
			old.queue_free()
	return d
