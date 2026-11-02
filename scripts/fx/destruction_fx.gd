extends Node
## Round 6 destruction effects (docs/ARCHITECTURE.md, "Round 6: more
## destruction"). A child of BloodFX ("DestructionFX"); every effect listens to
## GameEvents and spawns on the event's physics frame:
## - furniture_broken (K), by the object's surface, bigger breaks get more:
##   wood = a splinter burst and wood dust; glass = glinting shards and sparkle;
##   cardboard = a soft burst of paper bits; fabric (sofa) = stuffing puffs and
##   tufts; concrete (planter) = dust and grit.
## - structure_collapsed (D): dust sifting down where it gave way; when a heavy
##   piece (Tuning.FALLING_MIN_MASS) lands near a recent collapse
##   (debris_landed): a dust cloud, a dust ring and a deep boom (AudioFX).
## - floor_damaged (D, WorldDamage): the floor mark by level (BloodFX.floor_mark:
##   crack, crater, rubble, growing in place, capped at Tuning.FLOOR_DECAL_MAX)
##   plus grit and dust; tile pops in the tiled plaza add a tick-crack and dust
##   (floor_damaged on &"tile", or a tile piece registered with DebrisManager).
## - world_blast (D): chips and dust kicked up off the floor inside the radius.
## Sounds are AudioFX's (same events). OWNER: agent F (FX & audio).

# --- Local tuning (candidates for Tuning) ---------------------------------------
const SPLINTER_POOL := 6
const PAPER_POOL := 4
const SIFT_POOL := 3
const BLAST_POOL := 3
const BREAK_SIZE_REF := 1500.0   ## J: a sofa-sized break (the biggest kind) is size 1
const BREAK_OVERKILL := 4.0      ## energy past the break counts up to this many times
const COLLAPSE_BOOM_RADIUS := 5.0  ## m: a heavy piece landing this near a fresh collapse booms
const COLLAPSE_BOOM_WINDOW := 3.0  ## s after the collapse event
const COLLAPSE_SIFT_HEIGHT := 2.6  ## m above a floor-level collapse point the dust sifts from
const BOOM_GAP := 0.15           ## s between two collapse booms
const TILE_GAP := 0.04           ## s between two tile-pop effects (a burst of tiles)
## Falling pieces are watched each tick (DebrisManager's debris_landed is rate
## limited for audio, so a piece landing with the rubble can go unreported):
## a touchdown is a downward speed of at least LAND_VY cut by LAND_DV in one tick.
const LAND_VY := 2.0
const LAND_DV := 2.0
const WATCH_MAX := 4.0           ## s a falling piece is watched
const WOOD_COLOR := Color(0.55, 0.4, 0.25)
const PAPER_COLOR := Color(0.74, 0.62, 0.44)
const STUFFING_COLOR := Color(0.95, 0.94, 0.9)
const TILE_KEYS: Array[StringName] = [&"tile", &"tiles"]

## Every Round 6 effect spawned: {frame (physics), event, kind/surface/level, size} (tests).
var effect_log: Array[Dictionary] = []
## Effects since the last reset, by name (tests).
var counts: Dictionary = {}
var rng := RandomNumberGenerator.new()

var _fx: Node          ## BloodFX
var _world: Node       ## WorldFX
var _holder: Node3D
var _splinters: Array[GPUParticles3D] = []
var _splinter_next := 0
var _paper: Array[GPUParticles3D] = []
var _paper_next := 0
var _sift: Array[GPUParticles3D] = []
var _sift_next := 0
var _blast_puffs: Array[GPUParticles3D] = []
var _blast_grit: Array[GPUParticles3D] = []
var _blast_next := 0
var _collapses: Array = []        ## [position, real time]
var _boomed: Dictionary = {}      ## body id -> true (one boom per falling piece)
var _registered_at: Dictionary = {} ## body id -> real time DebrisManager took it
var _watch: Array = []            ## [RigidBody3D, previous velocity, age] of falling pieces
var _last_boom := -INF
var _last_tile := -INF

func setup(fx: Node, world: Node, holder: Node3D) -> void:
	_fx = fx
	_world = world
	_holder = holder
	rng.randomize()
	_build()
	GameEvents.furniture_broken.connect(_on_furniture_broken)
	GameEvents.structure_collapsed.connect(_on_structure_collapsed)
	GameEvents.floor_damaged.connect(_on_floor_damaged)
	GameEvents.world_blast.connect(_on_world_blast)
	GameEvents.debris_landed.connect(_on_debris_landed)
	var dm := get_node_or_null(^"/root/DebrisManager")
	if dm != null and dm.has_signal(&"body_registered"):
		dm.connect(&"body_registered", _on_debris_registered)

func reset() -> void:
	effect_log.clear()
	counts.clear()
	_collapses.clear()
	_boomed.clear()
	_registered_at.clear()
	_watch.clear()
	_last_boom = -INF
	_last_tile = -INF
	for list in [_splinters, _paper, _sift, _blast_puffs, _blast_grit]:
		for e: GPUParticles3D in list:
			e.emitting = false
			e.visible = false

func _record(event: StringName, what: Variant, size: float) -> void:
	counts[event] = int(counts.get(event, 0)) + 1
	effect_log.append({"frame": Engine.get_physics_frames(), "event": event, "what": what, "size": size})
	if effect_log.size() > 128:
		effect_log.pop_front()

static func _now() -> float:
	return Engine.get_physics_frames() / float(Engine.physics_ticks_per_second)


# =============================================================================
# Sizes and surfaces (shared with AudioFX)
# =============================================================================

## Surface of a broken clutter object: its `surface` member, else
## Tuning.FURNITURE[kind].surface, else wood.
static func surface_for(node: Object, kind: StringName) -> StringName:
	if is_instance_valid(node):
		var s = node.get(&"surface")
		if s != null and StringName(s) != &"":
			return StringName(s)
	var row: Dictionary = Tuning.FURNITURE.get(kind, {})
	return StringName(row.get("surface", &"wood"))

## 0..1 size of a break: the object's size (its break energy against a sofa's)
## raised by how far the hit went past the break, so bigger breaks get more.
static func break_size(kind: StringName, energy: float) -> float:
	var row: Dictionary = Tuning.FURNITURE.get(kind, {})
	var brk: float = row.get("break", 600.0)
	var base := clampf(brk / BREAK_SIZE_REF, 0.25, 1.0)
	var over := clampf(energy / maxf(brk, 1.0), 1.0, BREAK_OVERKILL)
	return clampf(base * (0.75 + 0.25 * over), 0.2, 1.0)


# =============================================================================
# Events
# =============================================================================

func _on_furniture_broken(node: Node3D, position: Vector3, kind: StringName, energy: float, by: Node3D) -> void:
	var surface := surface_for(node, kind)
	var s := break_size(kind, energy)
	var dir := Vector3.UP
	if is_instance_valid(by):
		var away := position - by.global_position
		away.y = 0.0
		if away.length_squared() > 1e-4:
			dir = (away.normalized() + Vector3.UP * 0.6).normalized()
	var table: Dictionary = _fx.get(&"DUST_BY_SURFACE")
	match surface:
		&"glass":
			_world.call(&"glass", position, s)
			if s > 0.6:
				_world.call(&"glass", position + Vector3.UP * 0.3, s * 0.7)
			_fx.call(&"spark", position, dir, lerpf(0.4, 1.0, s))  # glints
		&"cardboard":
			paper(position, s, PAPER_COLOR, dir)
			_fx.call(&"dust", position, table[&"cardboard"], lerpf(500.0, 1500.0, s), dir, false)
		&"fabric":
			paper(position, s * 0.8, STUFFING_COLOR, Vector3.UP, true)
			_fx.call(&"dust", position, STUFFING_COLOR, lerpf(1500.0, 4500.0, s), Vector3.UP, false)
		&"concrete", &"brick":
			_fx.call(&"dust", position, table.get(surface, table[&"concrete"]), lerpf(2000.0, 6000.0, s), dir, true,
					lerpf(0.6, 1.2, s))
		_:  # wood
			splinters(position, s, WOOD_COLOR, dir)
			_fx.call(&"dust", position, table[&"wood"], lerpf(800.0, 2600.0, s), dir, false)
	_record(&"furniture", [kind, surface], s)

## Structure gave way: dust sifts down from where it broke (the creak is AudioFX's).
func _on_structure_collapsed(_node: Node3D, position: Vector3, kind: StringName) -> void:
	var top := position
	if position.y < 1.0:
		top = position + Vector3.UP * COLLAPSE_SIFT_HEIGHT
	sift(top, 1.0 if kind == &"overhead" else 0.7)
	var table: Dictionary = _fx.get(&"DUST_BY_SURFACE")
	_fx.call(&"dust", top, table[&"concrete"], 2500.0, Vector3.DOWN, true, 0.5)
	_collapses.append([position, _now()])
	if _collapses.size() > 16:
		_collapses.pop_front()
	_record(&"collapse", kind, 1.0)

## A heavy piece that FELL from a collapse landing: a dust cloud, a ring and a
## boom. A falling piece is D's FallingPiece (a dropped overhead piece), or a
## heavy body DebrisManager took after a collapse began near it (panel cells
## drop Tuning.COLLAPSE_DELAY after the event); the pieces a pillar shatters
## into at the snap itself do not count.
func _on_debris_landed(body: Node3D, position: Vector3, speed: float, surface: StringName) -> void:
	_try_boom(body, position, speed, surface)

func _try_boom(body: Node3D, position: Vector3, speed: float, surface: StringName) -> void:
	if not is_instance_valid(body) or _boomed.has(body.get_instance_id()):
		return
	var mass := (body as RigidBody3D).mass if body is RigidBody3D else 0.0
	if mass < Tuning.FALLING_MIN_MASS:
		return
	var now := _now()
	var falling := _is_falling_piece(body)
	var reg: float = _registered_at.get(body.get_instance_id(), -INF)
	var near := false
	for c in _collapses:
		var p: Vector3 = c[0]
		var t: float = c[1]
		if now - t <= COLLAPSE_BOOM_WINDOW and Vector2(p.x - position.x, p.z - position.z).length() <= COLLAPSE_BOOM_RADIUS \
				and (falling or reg > t + 1e-4):
			near = true
	if not near or now - _last_boom < BOOM_GAP:
		return
	_boomed[body.get_instance_id()] = true
	_last_boom = now
	var energy := 0.5 * mass * speed * speed
	var table: Dictionary = _fx.get(&"DUST_BY_SURFACE")
	var c: Color = table.get(surface, table[&"concrete"])
	_fx.call(&"dust", position + Vector3.UP * 0.1, c, clampf(energy, 3000.0, 8000.0), Vector3.UP, true, 1.0)
	_world.call(&"dust_ring", position, 2.0, c)
	var afx := get_node_or_null(^"/root/AudioFX")
	if afx != null and afx.has_method(&"collapse_boom"):
		afx.call(&"collapse_boom", position, energy)
	_record(&"collapse_landing", mass, clampf(energy / 8000.0, 0.0, 1.0))

## Floor damage: the mark by level plus grit and dust; tiles pop with a tick.
## Level 0 (no new level, e.g. a lone tile pop) marks nothing: grit and dust only.
func _on_floor_damaged(position: Vector3, radius: float, level: int, surface: StringName) -> void:
	if level >= 1:
		_fx.call(&"floor_mark", position, radius, level, surface)
	var table: Dictionary = _fx.get(&"DUST_BY_SURFACE")
	var c: Color = table.get(surface, table[&"concrete"])
	var lvl := clampi(level, 1, 3)
	_fx.call(&"dust", position + Vector3.UP * 0.05, c, [1500.0, 3500.0, 6000.0][lvl - 1], Vector3.UP, true,
			[0.5, 0.8, 1.2][lvl - 1])
	if TILE_KEYS.has(surface):
		tile_pop(position)
	_record(&"floor", lvl, radius)

## A blast: chips and dust kicked up off the floor inside the radius.
func _on_world_blast(center: Vector3, radius: float, power: float, source: StringName) -> void:
	blast(center, radius, power)
	_record(&"blast", source, clampf(power / 8000.0, 0.0, 1.0))

## Falling pieces: a touchdown (a sharp cut in the downward speed) booms.
func _physics_process(delta: float) -> void:
	var i := _watch.size() - 1
	while i >= 0:
		var w: Array = _watch[i]
		var b = w[0]
		w[2] = float(w[2]) + delta
		if not is_instance_valid(b) or not (b as Node3D).is_inside_tree() or float(w[2]) > WATCH_MAX \
				or _boomed.has((b as Object).get_instance_id()):
			_watch.remove_at(i)
			i -= 1
			continue
		var v: Vector3 = (b as RigidBody3D).linear_velocity
		var pv: Vector3 = w[1]
		w[1] = v
		if pv.y <= -LAND_VY and v.y - pv.y >= LAND_DV:
			var pos := (b as Node3D).global_position
			_try_boom(b, pos, pv.length(), FXRules.floor_surface((b as Node3D).get_world_3d(), pos))
		i -= 1

## A body DebrisManager took: note when (collapse booms), and a tile piece
## from the tiled plaza pops.
func _on_debris_registered(body: RigidBody3D) -> void:
	if not is_instance_valid(body):
		return
	if body.mass >= Tuning.FALLING_MIN_MASS:
		if _registered_at.size() > 512:
			_registered_at.clear()
		var now := _now()
		_registered_at[body.get_instance_id()] = now
		var fresh := false
		for c in _collapses:
			if now - float(c[1]) <= COLLAPSE_BOOM_WINDOW and now > float(c[1]) + 1e-4:
				fresh = true
		if fresh or _is_falling_piece(body):
			_watch.append([body, body.linear_velocity, 0.0])
	var tag := StringName(body.get_meta(&"surface", &""))
	var kind := StringName(body.get_meta(&"kind", &""))
	if TILE_KEYS.has(tag) or TILE_KEYS.has(kind) or String(body.name).begins_with("Tile"):
		tile_pop(body.global_position)


# =============================================================================
# Effect primitives
# =============================================================================

## Wood splinters: long thin pieces tumbling out along `dir`.
func splinters(position: Vector3, size: float, color: Color, dir := Vector3.UP) -> void:
	var e := _splinters[_splinter_next]
	_splinter_next = (_splinter_next + 1) % _splinters.size()
	var pm := e.process_material as ParticleProcessMaterial
	pm.color = color
	pm.initial_velocity_min = lerpf(1.5, 3.0, size)
	pm.initial_velocity_max = lerpf(3.5, 7.0, size)
	pm.scale_min = lerpf(0.5, 0.8, size)
	pm.scale_max = lerpf(1.1, 1.8, size)
	e.amount_ratio = lerpf(0.3, 1.0, size)
	e.global_transform = Transform3D(_basis_toward(dir), position)
	e.visible = true
	e.restart()
	_record(&"splinters", color, size)

## Paper bits (cardboard) or stuffing tufts (fabric): light flakes that flutter down.
func paper(position: Vector3, size: float, color: Color, dir := Vector3.UP, slow := false) -> void:
	var e := _paper[_paper_next]
	_paper_next = (_paper_next + 1) % _paper.size()
	var pm := e.process_material as ParticleProcessMaterial
	pm.color = color
	pm.gravity = Vector3(0, -1.4 if slow else -2.6, 0)
	pm.initial_velocity_min = lerpf(0.8, 1.5, size)
	pm.initial_velocity_max = lerpf(2.0, 3.8, size)
	e.amount_ratio = lerpf(0.35, 1.0, size)
	e.global_transform = Transform3D(_basis_toward(dir), position)
	e.visible = true
	e.restart()
	_record(&"paper", color, size)

## Dust sifting down from above (a collapse), `size` 0..1.
func sift(position: Vector3, size: float) -> void:
	var e := _sift[_sift_next]
	_sift_next = (_sift_next + 1) % _sift.size()
	e.amount_ratio = clampf(size, 0.3, 1.0)
	e.global_transform = Transform3D(Basis(), position)
	e.visible = true
	e.restart()
	_record(&"sift", position.y, size)

## Floor chips and dust kicked up inside `radius` around `center`.
func blast(center: Vector3, radius: float, power: float) -> void:
	var i := _blast_next
	_blast_next = (_blast_next + 1) % _blast_puffs.size()
	var s := clampf(power / 8000.0, 0.15, 1.0) * clampf(radius / 2.5, 0.5, 1.2)
	var table: Dictionary = _fx.get(&"DUST_BY_SURFACE")
	for e: GPUParticles3D in [_blast_puffs[i], _blast_grit[i]]:
		var pm := e.process_material as ParticleProcessMaterial
		pm.emission_ring_radius = maxf(radius * 0.8, 0.3)
		pm.emission_ring_inner_radius = maxf(radius * 0.15, 0.05)
		pm.initial_velocity_min = lerpf(0.8, 2.0, s)
		pm.initial_velocity_max = lerpf(2.0, 5.0, s)
		e.amount_ratio = clampf(s * 1.1, 0.25, 1.0)
		e.global_transform = Transform3D(Basis(), center + Vector3.UP * 0.05)
		e.visible = true
		e.restart()
	(_blast_puffs[i].process_material as ParticleProcessMaterial).color = table[&"concrete"]
	_record(&"blast_fx", radius, s)

## A plaza tile popping: a tick-crack (AudioFX) and a little dust and grit.
func tile_pop(position: Vector3) -> void:
	var now := _now()
	if now - _last_tile < TILE_GAP:
		return
	_last_tile = now
	var table: Dictionary = _fx.get(&"DUST_BY_SURFACE")
	_fx.call(&"dust", position + Vector3.UP * 0.05, table[&"tile"], 900.0, Vector3.UP, true, 0.45)
	var afx := get_node_or_null(^"/root/AudioFX")
	if afx != null and afx.has_method(&"tile_pop"):
		afx.call(&"tile_pop", position)
	_record(&"tile", position, 0.3)


# =============================================================================
# Startup
# =============================================================================

## D's FallingPiece (by script class name: no compile dependency on world code).
static func _is_falling_piece(body: Object) -> bool:
	var sc = body.get_script()
	while sc != null:
		if (sc as Script).get_global_name() == &"FallingPiece":
			return true
		sc = (sc as Script).get_base_script()
	return false

static func _basis_toward(dir: Vector3) -> Basis:
	var d := dir.normalized() if dir.length_squared() > 1e-6 else Vector3.UP
	var up := Vector3.UP if absf(d.y) < 0.95 else Vector3.FORWARD
	return Basis.looking_at(d, up)

func _build() -> void:
	var puff_tex: Texture2D = _fx.get(&"_puff_tex")
	# Splinters: thin wood slivers that tumble, bounce and settle.
	var sliver := BoxMesh.new()
	sliver.size = Vector3(0.018, 0.012, 0.13)
	var wood_mat := StandardMaterial3D.new()
	wood_mat.vertex_color_use_as_albedo = true
	wood_mat.roughness = 0.9
	sliver.material = wood_mat
	for i in SPLINTER_POOL:
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(0, 0, -1)
		pm.spread = 70.0
		pm.gravity = Vector3(0, -9.8, 0)
		pm.angular_velocity_min = -900.0
		pm.angular_velocity_max = 900.0
		pm.particle_flag_rotate_y = true
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		pm.emission_sphere_radius = 0.2
		pm.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
		pm.collision_bounce = 0.3
		pm.collision_friction = 0.6
		pm.collision_use_scale = true
		_splinters.append(_emitter(sliver, pm, 32, 2.4, 0.95))
	# Paper bits and stuffing tufts: flat flakes, double-sided, fluttering down.
	var flake := QuadMesh.new()
	flake.size = Vector2(0.07, 0.05)
	var flake_mat := StandardMaterial3D.new()
	flake_mat.vertex_color_use_as_albedo = true
	flake_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	flake_mat.roughness = 1.0
	flake.material = flake_mat
	for i in PAPER_POOL:
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(0, 0, -1)
		pm.spread = 80.0
		pm.damping_min = 1.0
		pm.damping_max = 2.0
		pm.angular_velocity_min = -400.0
		pm.angular_velocity_max = 400.0
		pm.angle_min = 0.0
		pm.angle_max = 360.0
		pm.scale_min = 0.6
		pm.scale_max = 1.5
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		pm.emission_sphere_radius = 0.25
		pm.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
		pm.collision_bounce = 0.0
		pm.collision_friction = 1.0
		_paper.append(_emitter(flake, pm, 28, 2.6, 0.9))
	# Sifting dust: puffs released over a moment, drifting down.
	var puff := QuadMesh.new()
	puff.size = Vector2(0.5, 0.5)
	var puff_mat := StandardMaterial3D.new()
	puff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	puff_mat.vertex_color_use_as_albedo = true
	puff_mat.albedo_texture = puff_tex
	puff.material = puff_mat
	var alpha := GradientTexture1D.new()
	alpha.gradient = Gradient.new()
	alpha.gradient.set_color(0, Color(1, 1, 1, 0.0))
	alpha.gradient.set_color(1, Color(1, 1, 1, 0.0))
	alpha.gradient.add_point(0.15, Color(1, 1, 1, 0.6))
	alpha.gradient.add_point(0.6, Color(1, 1, 1, 0.3))
	var table: Dictionary = _fx.get(&"DUST_BY_SURFACE")
	for i in SIFT_POOL:
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(0, -1, 0)
		pm.spread = 25.0
		pm.initial_velocity_min = 0.2
		pm.initial_velocity_max = 1.0
		pm.gravity = Vector3(0, -2.2, 0)
		pm.damping_min = 0.5
		pm.damping_max = 1.0
		pm.color = table[&"concrete"]
		pm.color_ramp = alpha
		pm.scale_min = 0.6
		pm.scale_max = 1.6
		pm.angle_min = 0.0
		pm.angle_max = 360.0
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = Vector3(0.7, 0.2, 0.7)
		_sift.append(_emitter(puff, pm, 30, 1.8, 0.15))
	# Blast: puffs and grit thrown up from a ring on the floor.
	var grit := BoxMesh.new()
	grit.size = Vector3(0.035, 0.025, 0.03)
	var grit_mat := StandardMaterial3D.new()
	grit_mat.albedo_color = table[&"concrete"].darkened(0.2)
	grit_mat.roughness = 0.95
	grit.material = grit_mat
	for i in BLAST_POOL:
		for which in 2:
			var pm := ParticleProcessMaterial.new()
			pm.direction = Vector3(0, 1, 0)
			pm.spread = 30.0 if which == 0 else 40.0
			pm.gravity = Vector3(0, -1.0, 0) if which == 0 else Vector3(0, -12.0, 0)
			pm.damping_min = 1.5 if which == 0 else 0.0
			pm.damping_max = 2.5 if which == 0 else 0.0
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
			pm.emission_ring_axis = Vector3.UP
			pm.emission_ring_height = 0.05
			pm.emission_ring_radius = 1.0
			pm.emission_ring_inner_radius = 0.1
			if which == 0:
				pm.color_ramp = alpha
				pm.scale_min = 0.6
				pm.scale_max = 1.4
				pm.angle_min = 0.0
				pm.angle_max = 360.0
				_blast_puffs.append(_emitter(puff, pm, 40, 1.4, 0.9))
			else:
				pm.angular_velocity_min = -720.0
				pm.angular_velocity_max = 720.0
				pm.scale_min = 0.5
				pm.scale_max = 1.3
				pm.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
				pm.collision_bounce = 0.25
				pm.collision_friction = 0.6
				pm.collision_use_scale = true
				_blast_grit.append(_emitter(grit, pm, 36, 1.4, 0.95))

func _emitter(mesh: Mesh, pm: ParticleProcessMaterial, amount: int, lifetime: float,
		explosiveness: float) -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.amount = amount
	e.lifetime = lifetime
	e.one_shot = true
	e.explosiveness = explosiveness
	e.randomness = 0.3
	e.emitting = false
	e.visible = false
	e.local_coords = false
	e.draw_pass_1 = mesh
	e.process_material = pm
	e.collision_base_size = 0.02
	e.visibility_aabb = AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16))
	e.layers = Layers.VIS_FX
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	e.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_holder.add_child(e)
	return e
