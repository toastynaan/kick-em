class_name YardBuilder
extends Node3D
## Builds "The Yard" procedurally from a kit of 3 m panels (spec: The map):
## 22 x 22 m flat courtyard, drywall offices west, brick garage north and brick
## storage east, concrete outer walls on every side, 4 concrete pillars,
## stairwell spawns outside the courtyard, entries through the rooms.
## Also the floor, lighting, WorldEnvironment and sky.
## OWNER: agent D (world). CONTRACT STUB: keep every public signature.
##
## Axes: north = -Z, east = +X. Courtyard x, z in [-11, 11].
##   West  (x -11 .. -17.5): drywall offices, two rows of 3 m deep rooms split at
##         z = +-4.5. Front facade x = -11.125, inner wall x = -14.375. Doorways
##         at z = +-9 in both lines. The back-south office is a stairwell.
##   East  (x 11 .. 17.5): brick storage, mirror of the offices.
##   North (z -11 .. -17.5): brick garage, one 6 m deep room. Roll door at x = 0
##         (light "wood" surface, metal look), doorway at x = -6.
##   South: long concrete wall, z 11 .. 12.5. No rooms.
##   Corners NW / NE (x +-11.5 .. +-17.5, z -11.5 .. -17.5): concrete stairwells.
##   Concrete outer walls 1 m thick at x = +-18, z = -18; 1 m corner columns at
##   (+-11, +-11); 1 m pillars at (+-6, +-6) that chip at >= 5,000 J (Pillar).

const HALF := 11.0            ## courtyard half size
const PANEL := 3.0
const PANEL_T := 0.25
const ROOM_D := 3.0
const OUTER_IN := 17.5        ## inner face of the outer walls (x = +-17.5, z = -17.5)
const OUTER_T := 1.0
const SOUTH_Z := Vector2(11.0, 12.5)
const OUTER_H := 4.2
const COLUMN_H := 4.6
const PILLAR_H := 4.0
const PILLAR_SIZE := 1.0
const DOOR_W := 2.4
const DOOR_H := 2.4
const JAMB := 0.3
const OFFSETS: Array[float] = [-9.0, -6.0, -3.0, 0.0, 3.0, 6.0, 9.0]
const PILLARS: Array[Vector2] = [Vector2(-6, -6), Vector2(6, -6), Vector2(-6, 6), Vector2(6, 6)]
const SPAWN_Y := 0.05
## Staged breach: thumps before the burst, and the hole width from the floor.
## The hole height is the tallest non-Brute capsule + BREACH_HEADROOM
## (breach_hole_size); the Brute bursts the whole roll door.
const BREACH_THUMPS := 3
const BREACH_HOLE_WIDTH := 1.2
const BREACH_HEADROOM := 0.3
## Where GameMode puts a breaching enemy: this far behind the panel on the
## interior side (matches GameMode.BREACH_BEHIND), and the clear radius a spawn
## spot and its walk to the panel need.
const BREACH_BEHIND := 1.4
const BREACH_CLEARANCE := 0.5
## Lamp posts on the south strip (x positions), topple at LAMP_BREAK J.
const LAMPS: Array[float] = [-7.5, 0.0, 7.5]
const LAMP_BREAK := 3000.0
const DESK_BREAK := 900.0
const CRATE_BREAK := 600.0
## Strike power that breaks a loose prop (round 3): chair 1 kick, drum 3, cabinet 4.
const CHAIR_STRIKE_HP := 60.0
const DRUM_STRIKE_HP := 180.0
const CABINET_STRIKE_HP := 240.0

var _structure: StaticBody3D
var _walls: Node3D
var _spawns: Array[Dictionary] = []
var _roll_door: Destructible
var _built := false

func _ready() -> void:
	add_to_group(&"arena")

## Build everything as children of this node.
func build() -> void:
	add_to_group(&"arena")
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_spawns.clear()
	_roll_door = null
	_build_environment()
	_build_floor()
	_structure = ConcreteWall.new()
	_structure.name = "Structure"
	_structure.collision_layer = Layers.WORLD
	_structure.collision_mask = 0
	_structure.set_meta(&"surface", &"concrete")
	_structure.add_to_group(&"world_static")
	add_child(_structure)
	_walls = Node3D.new()
	_walls.name = "Walls"
	add_child(_walls)
	_build_outer_shell()
	_build_side_block(-1, &"drywall")
	_build_side_block(1, &"brick")
	_build_garage()
	_build_stairwells()
	_build_pillars()
	_build_props()
	_build_spawns()
	_built = true

func get_player_spawn() -> Transform3D:
	return Transform3D(Basis(), Vector3(0, SPAWN_Y, 6))

## Enemy spawn entries. Each: {"position": Vector3, "path": PackedVector3Array}
## where path leads from the spawn into the courtyard (walkable straight segments).
## Extra keys: "name" (StringName), "facing" (Vector3, first walking direction).
func get_enemy_spawns() -> Array[Dictionary]:
	if _spawns.is_empty():
		_build_spawns()
	return _spawns.duplicate(true)

## Duel (1v1) start positions: [player, opponent].
func get_duel_spawns() -> Array[Transform3D]:
	return [Transform3D(Basis(), Vector3(0, SPAWN_Y, 4)),
		Transform3D(Basis(Vector3.UP, PI), Vector3(0, SPAWN_Y, -4))]

## Courtyard bounds (AI keeps rings inside this).
func get_courtyard_bounds() -> AABB:
	return AABB(Vector3(-HALF, 0, -HALF), Vector3(HALF * 2.0, 4, HALF * 2.0))

## Every Destructible in the yard.
func get_destructibles() -> Array[Destructible]:
	var out: Array[Destructible] = []
	if _walls:
		for c in _walls.get_children():
			if c is Destructible:
				out.append(c)
	return out

## The garage roll door (breaks at Tuning.SURFACES.wood; the Brute's entry).
func get_roll_door() -> Destructible:
	return _roll_door

## Intact courtyard-facing panels an enemy can burst through (spec: enemies
## arrive through walls). Use breach() to stage it.
## Only panels whose breach spawn spot (BREACH_BEHIND behind, interior side)
## and walk to the panel are clear of props and structure (BREACH_CLEARANCE).
func get_breach_walls() -> Array[Destructible]:
	var out: Array[Destructible] = []
	for d in get_destructibles():
		if not d.is_broken and d.has_meta(&"facade") and is_breach_spot_clear(d):
			out.append(d)
	return out

## Where a breaching enemy waits behind `wall` (floor level).
func breach_spot(wall: Destructible) -> Vector3:
	var into := wall.global_basis.z
	into.y = 0.0
	var p := wall.global_position - into.normalized() * BREACH_BEHIND
	p.y = 0.0
	return p

## True when the spawn spot behind `wall` and the lane from it to the wall are
## free of props, rubble and structure.
func is_breach_spot_clear(wall: Destructible) -> bool:
	if not is_inside_tree():
		return true
	var space := get_world_3d().direct_space_state
	var into := wall.global_basis.z
	into.y = 0.0
	into = into.normalized()
	var spot := breach_spot(wall)
	var q := PhysicsShapeQueryParameters3D.new()
	q.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE | Layers.DEBRIS
	q.exclude = [wall.get_rid()]
	var cyl := CylinderShape3D.new()
	cyl.radius = BREACH_CLEARANCE
	cyl.height = 1.8
	q.shape = cyl
	q.transform = Transform3D(Basis(), spot + Vector3.UP * 1.05)
	if not space.intersect_shape(q, 1).is_empty():
		return false
	# The walk from the spot to the panel's back face.
	var lane_len := BREACH_BEHIND - wall.size.z * 0.5 - 0.1
	var box := BoxShape3D.new()
	box.size = Vector3(BREACH_CLEARANCE * 1.8, 1.8, lane_len)
	q.shape = box
	q.transform = Transform3D(Basis.looking_at(into, Vector3.UP), spot + into * lane_len * 0.5 + Vector3.UP * 1.05)
	return space.intersect_shape(q, 1).is_empty()

## Breach hole (width, height from the floor): fits the tallest non-Brute
## archetype's capsule (Fighter.CAPSULE_HEIGHT x appearance height) plus
## BREACH_HEADROOM.
static func breach_hole_size() -> Vector2:
	var tallest := 0.0
	for id: StringName in Tuning.ARCHETYPES:
		if id == &"brute":
			continue
		var app: Dictionary = (Tuning.ARCHETYPES[id] as Dictionary).get("appearance", {})
		tallest = maxf(tallest, Fighter.CAPSULE_HEIGHT * float(app.get("height", 1.0)))
	return Vector2(BREACH_HOLE_WIDTH, tallest + BREACH_HEADROOM)

## Staged entry (spec: enemies arrive through walls). Three thumps from the
## room side with growing local cracks inside `delay` s (each emits
## GameEvents.wall_cracked, so BloodFX / AudioFX add dust and sound), then the
## burst into the courtyard: a hole from the floor up sized by
## breach_hole_size(), or for the roll door (the Brute's entry) the whole door
## (force_break, a full break with its debris and events). The panel gets meta
## &"staged_breach" = true before its wall_broken.
func breach(wall: Destructible, delay := 1.0, speed := 7.0) -> void:
	if wall == null or wall.is_broken:
		return
	wall.set_meta(&"staged_breach", true)
	var into := wall.global_basis.z.normalized()      # exterior side = courtyard
	var h := wall.size * 0.5
	var hole := breach_hole_size()
	var hit := wall.global_transform * Vector3(0.0, -h.y + minf(hole.y, wall.size.y) * 0.5, -h.z)
	var step := delay / (BREACH_THUMPS + 0.5)
	for k in BREACH_THUMPS:
		if not is_instance_valid(wall) or wall.is_broken:
			return
		wall.force_crack(hit, 0.45 + 0.4 * k)
		GameEvents.screen_shake.emit(0.05 + 0.04 * k)
		await get_tree().create_timer(step, false, true).timeout
	await get_tree().create_timer(maxf(delay - step * BREACH_THUMPS, 0.05), false, true).timeout
	if not is_instance_valid(wall) or wall.is_broken:
		return
	if wall.has_meta(&"roll_door"):
		wall.force_break(hit, into * speed)
		return
	var fp := Rect2(-hole.x * 0.5, -h.y, hole.x, hole.y)
	wall.break_hole(hit, into * speed, fp)

# --- Environment ----------------------------------------------------------------

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.22, 0.4, 0.68)
	sm.sky_horizon_color = Color(0.72, 0.74, 0.76)
	sm.ground_bottom_color = Color(0.14, 0.13, 0.12)
	sm.ground_horizon_color = Color(0.62, 0.62, 0.62)
	sm.sun_angle_max = 25.0
	sm.sun_curve = 0.12
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 0.8
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.05
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 2.2
	env.ssao_power = 1.6
	env.ssao_detail = 0.6
	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.glow_strength = 0.9
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.1
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.fog_enabled = true
	env.fog_light_color = Color(0.7, 0.74, 0.8)
	env.fog_density = 0.0025
	env.fog_aerial_perspective = 0.35
	env.fog_sky_affect = 0.15
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.06
	env.adjustment_saturation = 1.08
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color(1.0, 0.94, 0.84)
	sun.light_energy = 1.35
	sun.light_angular_distance = 0.6
	sun.shadow_enabled = true
	sun.shadow_blur = 1.2
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 70.0
	sun.light_cull_mask = 0xFFFFF
	add_child(sun)
	# Sun in the south-west, about 48 degrees up: shadows fall north-east.
	sun.basis = Basis.looking_at(Vector3(0.45, -0.85, -0.42).normalized(), Vector3.UP)

func _build_floor() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_layer = Layers.WORLD
	floor_body.collision_mask = 0
	floor_body.set_meta(&"surface", &"concrete")
	floor_body.add_to_group(&"world_static")
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(140, 2, 140)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	floor_body.add_child(cs)
	add_child(floor_body)
	# Visual floors (no collision): ground outside, then each zone.
	_plane(floor_body, Rect2(-70, -70, 140, 140), -0.01, WorldMaterials.ground())
	_plane(floor_body, Rect2(-HALF, -HALF, HALF * 2, HALF * 2), 0.0, WorldMaterials.asphalt())
	_plane(floor_body, Rect2(-OUTER_IN, -10.5, OUTER_IN - HALF, 21.0), 0.0, WorldMaterials.office_floor())
	_plane(floor_body, Rect2(HALF, -10.5, OUTER_IN - HALF, 21.0), 0.0, WorldMaterials.concrete(0.85))
	_plane(floor_body, Rect2(-10.5, -OUTER_IN, 21.0, OUTER_IN - HALF), 0.0, WorldMaterials.concrete(0.78))
	_plane(floor_body, Rect2(-OUTER_IN, -OUTER_IN, OUTER_IN - 11.5, OUTER_IN - 11.5), 0.0,
		WorldMaterials.concrete(0.9))
	_plane(floor_body, Rect2(11.5, -OUTER_IN, OUTER_IN - 11.5, OUTER_IN - 11.5), 0.0,
		WorldMaterials.concrete(0.9))

func _plane(parent: Node3D, rect: Rect2, y: float, mat: Material) -> void:
	var pm := PlaneMesh.new()
	pm.size = rect.size
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	mi.material_override = mat
	mi.layers = Layers.VIS_WORLD
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.position = Vector3(rect.position.x + rect.size.x * 0.5, y, rect.position.y + rect.size.y * 0.5)

# --- Static concrete --------------------------------------------------------------

## Axis-aligned static box from min/max corners (WORLD layer, never breaks).
func _box(min_c: Vector3, max_c: Vector3, mat: Material = null) -> void:
	var size := max_c - min_c
	var center := (min_c + max_c) * 0.5
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	cs.position = center
	_structure.add_child(cs)
	var bm := BoxMesh.new()
	bm.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.material_override = mat if mat else WorldMaterials.concrete()
	mi.layers = Layers.VIS_WORLD
	mi.position = center
	_structure.add_child(mi)

## Static wall along X (z from z0 to z1) with optional doorways at the given x centres.
func _wall_x(x0: float, x1: float, z0: float, z1: float, h: float, doors: Array = [],
		mat: Material = null) -> void:
	var cuts: Array = []
	for dx: float in doors:
		cuts.append(Vector2(dx - DOOR_W * 0.5, dx + DOOR_W * 0.5))
	cuts.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var cur := x0
	for c: Vector2 in cuts:
		if c.x > cur:
			_box(Vector3(cur, 0, z0), Vector3(c.x, h, z1), mat)
		_box(Vector3(c.x, DOOR_H, z0), Vector3(c.y, h, z1), mat)
		cur = c.y
	if cur < x1:
		_box(Vector3(cur, 0, z0), Vector3(x1, h, z1), mat)

## Static wall along Z (x from x0 to x1) with optional doorways at the given z centres.
func _wall_z(x0: float, x1: float, z0: float, z1: float, h: float, doors: Array = [],
		mat: Material = null) -> void:
	var cuts: Array = []
	for dz: float in doors:
		cuts.append(Vector2(dz - DOOR_W * 0.5, dz + DOOR_W * 0.5))
	cuts.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var cur := z0
	for c: Vector2 in cuts:
		if c.x > cur:
			_box(Vector3(x0, 0, cur), Vector3(x1, h, c.x), mat)
		_box(Vector3(x0, DOOR_H, c.x), Vector3(x1, h, c.y), mat)
		cur = c.y
	if cur < z1:
		_box(Vector3(x0, 0, cur), Vector3(x1, h, z1), mat)

func _build_outer_shell() -> void:
	var xo := OUTER_IN + OUTER_T
	# West and east outer walls (full depth), north outer wall, long south wall.
	_box(Vector3(-xo, 0, -xo), Vector3(-OUTER_IN, OUTER_H, SOUTH_Z.y))
	_box(Vector3(OUTER_IN, 0, -xo), Vector3(xo, OUTER_H, SOUTH_Z.y))
	_box(Vector3(-OUTER_IN, 0, -xo), Vector3(OUTER_IN, OUTER_H, -OUTER_IN))
	_box(Vector3(-OUTER_IN, 0, SOUTH_Z.x), Vector3(OUTER_IN, OUTER_H, SOUTH_Z.y))
	# South ends of the side blocks (close the 0.5 m gap to the south wall).
	_box(Vector3(-OUTER_IN, 0, 10.5), Vector3(-11.5, OUTER_H, SOUTH_Z.x))
	_box(Vector3(11.5, 0, 10.5), Vector3(OUTER_IN, OUTER_H, SOUTH_Z.x))
	# North ends of the side blocks, with a doorway from each corner stairwell.
	_wall_x(-OUTER_IN, -11.5, -11.5, -10.5, OUTER_H, [-16.0])
	_wall_x(11.5, OUTER_IN, -11.5, -10.5, OUTER_H, [16.0])
	# Garage side walls; the west one opens into the NW stairwell.
	_wall_z(-11.5, -10.5, -OUTER_IN, -11.5, OUTER_H, [-15.0])
	_wall_z(10.5, 11.5, -OUTER_IN, -11.5, OUTER_H, [])
	# Corner columns.
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var c := Vector3(sx * HALF, 0, sz * HALF)
			_box(c + Vector3(-0.5, 0, -0.5), c + Vector3(0.5, COLUMN_H, 0.5), WorldMaterials.concrete(0.92))

func _build_pillars() -> void:
	for p in PILLARS:
		var pillar := Pillar.new()
		pillar.name = "Pillar_%d_%d" % [int(p.x), int(p.y)]
		pillar.size = Vector3(PILLAR_SIZE, PILLAR_H, PILLAR_SIZE)
		pillar.position = Vector3(p.x, 0, p.y)
		add_child(pillar)

# --- Props ----------------------------------------------------------------------------

## Breakable props (Destructible kinds) and loose RigidBody props. Placed off
## every spawn path and off the courtyard floor (lamps stand on the south edge).
func _build_props() -> void:
	var props := Node3D.new()
	props.name = "Props"
	add_child(props)
	# West offices: desks with chairs (front rooms), filing cabinets (back rooms).
	# Desks stay out of the breach lanes (z = 0, +-3, +-6 behind each facade
	# panel) and the doorway paths (z = +-9).
	for z in [-7.6, -1.5, 1.5, 7.6]:
		_prop(&"desk", Vector3(-12.8, 0, z), Vector3(1.4, 0.76, 0.7), DESK_BREAK, PI * 0.5)
		_chair(props, Vector3(-13.75, 0, z))
	for z in [-7.0, -6.3, -2.6, 2.6, -3.3]:
		_cabinet(props, Vector3(-17.15, 0, z))
	_prop(&"desk", Vector3(-16.0, 0, -3.6), Vector3(1.4, 0.76, 0.7), DESK_BREAK, 0.0)
	# East storage: crate stacks and drums.
	# Front-room crates sit between the breach lanes (z = 0, +-3, +-6).
	for c: Vector3 in [Vector3(12.4, 0, -7.6), Vector3(13.6, 0, -7.6), Vector3(12.6, 0, -1.5),
			Vector3(12.6, 0, 1.5), Vector3(12.4, 0, 7.6), Vector3(17.0, 0, -5.4), Vector3(17.0, 0, -6.6),
			Vector3(17.0, 0, 2.6), Vector3(17.0, 0, -2.6)]:
		_prop(&"crate", c + Vector3(0, 0.5, 0), Vector3(1.0, 1.0, 1.0), CRATE_BREAK, 0.0)
	_prop(&"crate", Vector3(12.4, 1.5, -7.6), Vector3(1.0, 1.0, 1.0), CRATE_BREAK, 0.3)
	_prop(&"crate", Vector3(17.0, 1.5, 2.6), Vector3(1.0, 1.0, 1.0), CRATE_BREAK, -0.2)
	for d: Vector3 in [Vector3(13.6, 0, -6.7), Vector3(13.4, 0, 6.6), Vector3(15.3, 0, -5.3), Vector3(15.3, 0, 2.2)]:
		_drum(props, d)
	# Garage: drums and a crate stack in the back corners.
	for d: Vector3 in [Vector3(-9.6, 0, -16.8), Vector3(-8.9, 0, -16.9), Vector3(-9.3, 0, -16.2)]:
		_drum(props, d)
	_prop(&"crate", Vector3(8.6, 0.5, -16.6), Vector3(1.0, 1.0, 1.0), CRATE_BREAK, 0.0)
	_prop(&"crate", Vector3(9.7, 0.5, -16.6), Vector3(1.0, 1.0, 1.0), CRATE_BREAK, 0.0)
	_prop(&"crate", Vector3(9.15, 1.5, -16.6), Vector3(1.0, 1.0, 1.0), CRATE_BREAK, 0.25)
	# South strip: lamp posts at the edge of the courtyard.
	for x in LAMPS:
		_prop(&"lamp", Vector3(x, 0, HALF - 0.6), Vector3(0.28, 4.6, 0.28), LAMP_BREAK, PI)

## A breakable prop centred at `at` (y = its centre; y = 0 means "on the floor").
func _prop(kind: StringName, at: Vector3, prop_size: Vector3, break_energy: float, yaw: float) -> Destructible:
	var d := Destructible.new()
	d.kind = kind
	d.surface = &"concrete" if kind == &"lamp" else &"wood"
	d.size = prop_size
	d.break_energy_override = break_energy
	var c := at
	if is_zero_approx(c.y):
		c.y = prop_size.y * 0.5
	d.name = "%s_%d_%d_%d" % [kind, int(round(c.x * 10.0)), int(round(c.y * 10.0)), int(round(c.z * 10.0))]
	d.transform = Transform3D(Basis(Vector3.UP, yaw), c)
	d.set_meta(&"prop", true)
	_walls.add_child(d)
	return d

func _loose(parent: Node3D, at: Vector3, mass: float, surface: StringName, strike_hp := 120.0) -> RigidBody3D:
	var b := LooseProp.new()
	b.mass = mass
	b.surface = surface
	b.strike_hp = strike_hp
	parent.add_child(b)
	b.position = at
	return b

func _add_box(b: Node3D, size: Vector3, at: Vector3, mat: Material, collide := true) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = at
	b.add_child(mi)
	if collide:
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		cs.shape = shape
		cs.position = at
		b.add_child(cs)

func _chair(parent: Node3D, at: Vector3) -> void:
	var b := _loose(parent, at + Vector3(0, 0.02, 0), 8.0, &"wood", CHAIR_STRIKE_HP)
	var mat := WorldMaterials.frame()
	_add_box(b, Vector3(0.45, 0.06, 0.45), Vector3(0, 0.46, 0), WorldMaterials.office_chair())
	_add_box(b, Vector3(0.45, 0.5, 0.06), Vector3(0, 0.74, 0.2), WorldMaterials.office_chair())
	_add_box(b, Vector3(0.08, 0.43, 0.08), Vector3(0, 0.215, 0), mat)
	_add_box(b, Vector3(0.5, 0.04, 0.5), Vector3(0, 0.02, 0), mat)
	b.rotation.y = randf_range(-0.6, 0.6)

func _cabinet(parent: Node3D, at: Vector3) -> void:
	var b := _loose(parent, at, 55.0, &"concrete", CABINET_STRIKE_HP)
	_add_box(b, Vector3(0.5, 1.3, 0.6), Vector3(0, 0.65, 0), WorldMaterials.cabinet())
	for k in 4:
		_add_box(b, Vector3(0.02, 0.012, 0.5), Vector3(0.26, 0.3 + 0.3 * k, 0), WorldMaterials.frame(), false)
		_add_box(b, Vector3(0.03, 0.03, 0.14), Vector3(0.265, 0.22 + 0.3 * k, 0), WorldMaterials.frame(), false)

func _drum(parent: Node3D, at: Vector3) -> void:
	var b := _loose(parent, at, 30.0, &"concrete", DRUM_STRIKE_HP)
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.29
	cm.bottom_radius = 0.29
	cm.height = 0.88
	mi.mesh = cm
	mi.material_override = WorldMaterials.drum()
	mi.position = Vector3(0, 0.44, 0)
	b.add_child(mi)
	var cs := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.29
	shape.height = 0.88
	cs.shape = shape
	cs.position = Vector3(0, 0.44, 0)
	b.add_child(cs)

# --- Breakable buildings ----------------------------------------------------------

## A Destructible panel centred at `center` (y = panel centre) whose exterior
## face (+Z local) points along `facing`.
func _panel(surface: StringName, center: Vector3, facing: Vector3, size := Vector3(PANEL, PANEL, PANEL_T),
		style: StringName = &"") -> Destructible:
	var d := Destructible.new()
	d.surface = surface
	d.size = size
	d.style = style
	d.name = "%s_%d_%d" % [surface, int(round(center.x * 10.0)), int(round(center.z * 10.0))]
	d.transform = Transform3D(Basis.looking_at(-facing, Vector3.UP), center)
	_walls.add_child(d)
	return d

## Doorway frame in a panel line: two jambs and a lintel (static, never breaks).
## `along` is the wall's run direction (unit X or Z), `c` the slot centre at y = 0.
func _door_frame(c: Vector3, along: Vector3, thickness: float) -> void:
	var across := Vector3(absf(along.z), 0, absf(along.x)) * thickness * 0.5
	var mat := WorldMaterials.frame()
	for s in [-1.0, 1.0]:
		var jc: Vector3 = c + along * s * (PANEL * 0.5 - JAMB * 0.5)
		var jh := along.abs() * JAMB * 0.5 + across
		_box(jc - jh, jc + jh + Vector3(0, PANEL, 0), mat)
	var lh := along.abs() * (DOOR_W * 0.5) + across
	_box(c - lh + Vector3(0, DOOR_H, 0), c + lh + Vector3(0, PANEL, 0), mat)

## West (side = -1, drywall offices) or east (side = 1, brick storage) block.
func _build_side_block(side: int, surface: StringName) -> void:
	var s := float(side)
	var facing := Vector3(-s, 0, 0)           # exterior faces point at the courtyard
	var x_a := s * (HALF + PANEL_T * 0.5)
	var x_b := s * (HALF + PANEL_T + ROOM_D + PANEL_T * 0.5)
	for z in OFFSETS:
		var door := absf(z) > 8.0
		for x: float in [x_a, x_b]:
			if door:
				_door_frame(Vector3(x, 0, z), Vector3(0, 0, 1), PANEL_T + 0.06)
			else:
				var inner := x != x_a and surface == &"drywall"
				var p := _panel(surface, Vector3(x, PANEL * 0.5, z), facing, Vector3(PANEL, PANEL, PANEL_T),
					&"interior" if inner else &"")
				if x == x_a:
					p.set_meta(&"facade", true)
	# Partitions between rooms (both rows), at the panel seams z = +-4.5.
	var x_front := s * (HALF + PANEL_T + ROOM_D * 0.5)
	var x_back := s * (HALF + PANEL_T + ROOM_D + PANEL_T + ROOM_D * 0.5)
	for z in [-4.5, 4.5]:
		for x in [x_front, x_back]:
			_panel(surface, Vector3(x, PANEL * 0.5, z), Vector3(0, 0, signf(z)), Vector3(PANEL, PANEL, PANEL_T),
				&"interior" if surface == &"drywall" else &"")

func _build_garage() -> void:
	var z_a := -(HALF + PANEL_T * 0.5)
	for x in OFFSETS:
		if is_equal_approx(x, -6.0):
			_door_frame(Vector3(x, 0, z_a), Vector3(1, 0, 0), PANEL_T + 0.06)
		elif is_zero_approx(x):
			_roll_door = _panel(&"wood", Vector3(x, PANEL * 0.5, z_a), Vector3(0, 0, 1),
				Vector3(PANEL, PANEL, 0.12), &"rolldoor")
			_roll_door.name = "RollDoor"
			_roll_door.set_meta(&"facade", true)
			_roll_door.set_meta(&"roll_door", true)
		else:
			var p := _panel(&"brick", Vector3(x, PANEL * 0.5, z_a), Vector3(0, 0, 1))
			p.set_meta(&"facade", true)
	# Roll door housing above the door.
	_box(Vector3(-1.7, PANEL, z_a - 0.45), Vector3(1.7, PANEL + 0.45, z_a + 0.1), WorldMaterials.frame())

## Visual + solid stairs: `steps` boxes rising along `dir` from `start` (bottom
## front edge centre), `width` across, then a landing.
func _stairs(start: Vector3, dir: Vector3, width: float, steps: int, landing: float) -> void:
	var rise := 0.25
	var run := 0.3
	var across := Vector3(absf(dir.z), 0, absf(dir.x)) * width * 0.5
	var mat := WorldMaterials.concrete(0.8)
	for k in steps:
		var a := start + dir * (run * k)
		var b := start + dir * (run * (k + 1))
		var lo := Vector3(minf(a.x, b.x), 0, minf(a.z, b.z)) - across
		var hi := Vector3(maxf(a.x, b.x), rise * (k + 1), maxf(a.z, b.z)) + across
		_box(lo, hi, mat)
	var la := start + dir * (run * steps)
	var lb := la + dir * landing
	_box(Vector3(minf(la.x, lb.x), 0, minf(la.z, lb.z)) - across,
		Vector3(maxf(la.x, lb.x), rise * steps, maxf(la.z, lb.z)) + across, mat)

func _build_stairwells() -> void:
	# NW and NE corner stairwells: a flight along the north wall up to a landing.
	_stairs(Vector3(-12.6, 0, -16.85), Vector3(-1, 0, 0), 1.3, 12, 1.3)
	_stairs(Vector3(12.6, 0, -16.85), Vector3(1, 0, 0), 1.3, 12, 1.3)
	# Back-south rooms of each side block: a flight along the outer wall.
	_stairs(Vector3(-16.9, 0, 5.0), Vector3(0, 0, 1), 1.2, 12, 1.8)
	_stairs(Vector3(16.9, 0, 5.0), Vector3(0, 0, 1), 1.2, 12, 1.8)

func _build_spawns() -> void:
	_spawns.clear()
	var y := SPAWN_Y
	_add_spawn(&"garage", Vector3(-13.5, y, -14.5),
		[Vector3(-11.0, y, -15.0), Vector3(-6.0, y, -15.0), Vector3(-6.0, y, -8.5)])
	_add_spawn(&"offices_north", Vector3(-16.0, y, -14.0),
		[Vector3(-16.0, y, -9.0), Vector3(-8.5, y, -9.0)])
	_add_spawn(&"offices_south", Vector3(-15.5, y, 6.0),
		[Vector3(-15.5, y, 9.0), Vector3(-8.5, y, 9.0)])
	_add_spawn(&"storage_north", Vector3(16.0, y, -14.0),
		[Vector3(16.0, y, -9.0), Vector3(8.5, y, -9.0)])
	_add_spawn(&"storage_south", Vector3(15.5, y, 6.0),
		[Vector3(15.5, y, 9.0), Vector3(8.5, y, 9.0)])

func _add_spawn(id: StringName, pos: Vector3, pts: Array) -> void:
	var path := PackedVector3Array()
	for p: Vector3 in pts:
		path.append(p)
	var facing := (path[0] - pos).normalized() if path.size() > 0 else Vector3.FORWARD
	_spawns.append({"name": id, "position": pos, "path": path, "facing": facing})
