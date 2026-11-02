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
##   (+-11, +-11); 1 m pillars at (+-6, +-6) that crack at 6,000 J and break on a
##   second 18 m/s body (Pillar, Round 5).
##
## Round 5 courtyard (Feel Reference: Movement spec; F7, F7b, F11). Map, north up:
##
##        x=-11            x=0             x=+11
##   z=-11 +--door--[brick][ROLL][brick][brick][brick]--door--+   garage facade:
##         |       P(-6,-6)  ===   [cr][cr]   P(6,-6)          |   15 m runnable
##         |                 low wall 0.9 (static)            |
##   west  |      ::metal::                                   |   east facade
##   facade| [PLATFORM]                     |low wall 0.9      |   (brick, 15 m
##   (dry- | [ 1.8 m  ]                     |(brick, breaks)   |   runnable)
##   wall, | [        ]         ~~water~~   |                  |
##   15 m  |                                                  |
##   run.) |       P(-6,6)   player(0,6)        P(6,6)        |
##         |   [cr][cr]                     [cr]              |
##   z=+11 +--door-L---------- south concrete wall --------L--door--+  (18 m runnable lane)
##   P pillar, [cr] 1.1 m crate (breaks into pieces that stay), L lamp post.
## - Vault: two 0.9 m low walls and 1.1 m crates; mantle: the 1.8 m platform
##   (x -8..-5, z -2..2), 3 m off the west facade so a wall-run kick-off lands on
##   it, open floor on every side.
## - Wall runs: the west / east facades and the garage facade (destructible
##   panels, runnable while intact) and the south concrete wall (arena wall,
##   group "runnable"); every lane has open floor beside it (get_wall_run_lanes).
## - Floors are tagged for footsteps and landings (WorldTags.surface_of): the
##   main floor &"concrete", offices &"wood", a shallow &"water" patch and a
##   &"metal" plate in the courtyard, the ground outside &"dirt".
## - Nothing new stands on a spawn path, an entry, a breach lane or the duel line.

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
## Round 5: lamps stand at the ends of the south wall so its run lane stays clear.
const LAMPS: Array[float] = [-9.4, 9.4]
const LAMP_Z := HALF - 0.8
const LAMP_BREAK := 3000.0
const DESK_BREAK := 900.0
const CRATE_BREAK := 600.0
## Strike power that breaks a loose prop (round 3): chair 1 kick, drum 3, cabinet 4.
const CHAIR_STRIKE_HP := 60.0
const DRUM_STRIKE_HP := 180.0
const CABINET_STRIKE_HP := 240.0
## Round 5 parkour features (Feel Reference: "The arena needs things to vault").
const LOW_WALL_H := 0.9
const LOW_WALL_T := 0.3
const CRATE_H := 1.1
const PLATFORM_H := 1.8
const PLATFORM_RECT := Rect2(-8.0, -2.0, 3.0, 4.0)   ## x, z, size x, size z
## [centre (x, z), length, along x?, surface]. Round 6: both break: brick at
## 6,000 J, concrete (15,000 J) on the second 18 m/s body; strikes chip them.
## The concrete one stands at z -6.5, out of the garage lane's open floor
## (keep-clear from z -7.5 north).
const LOW_WALLS := [[Vector2(6.5, 0.0), 4.0, false, &"brick"], [Vector2(0.0, -6.5), 3.0, true, &"concrete"]]
## Round 6 platform: a deck on posts behind four breakable skirt faces
## (Tuning.PLATFORM_SKIRT_SURFACE). Deck slab thickness, skirt thickness, posts.
const DECK_T := 0.15
const SKIRT_T := 0.1
const PLATFORM_POSTS: Array[Vector2] = [Vector2(-7.7, -1.7), Vector2(-7.7, 1.7), Vector2(-5.3, -1.7), Vector2(-5.3, 1.7),
	Vector2(-6.5, -1.7), Vector2(-6.5, 1.7), Vector2(-6.5, 0.0)]
const POST_SIZE := 0.2
## Round 6 free-standing drywall partitions at the edges of the fight space
## (Tuning.PARTITION_MIN): [centre (x, z), length, along x?]. Each runs along z
## just inside the east / west run lane's open floor (3.5 m off the facade,
## feet included), clear of the platform's approach, the centre lanes, breach
## lanes and entries. The west one stands beside the south-west pillar (a
## remnant wall by a column: too narrow a gap to walk through).
const PARTITIONS := [[Vector2(7.1, -3.4), 2.4, false], [Vector2(-7.1, 5.8), 2.4, false]]
const PARTITION_H := 2.4
const PARTITION_T := 0.12
## Round 6 tiled plaza at the centre of the fight space (x, z, w, d), 0.5 m tiles.
const PLAZA_RECT := Rect2(-2.5, -2.0, 3.5, 4.0)
const PLAZA_TILE := 0.5
## Round 6: all short of the run lanes' keep-clear open floor (z -7.5 north,
## z 7.5 south). The north pair steps up from the concrete low wall's east end
## and leaves 1.75 m to the pillar at (6, -6); one stands south-west. (The
## south band's other crates had no room left: K's lobby needs its approaches.)
const CRATES: Array[Vector2] = [Vector2(2.05, -6.6), Vector2(3.2, -6.6), Vector2(-3.6, 6.9)]
## Round 5 throwable props (Feel Reference: Props): [kind, position (y = the
## surface it rests on), yaw]. Bricks on ledges at hand height (Sifu 2 opens by
## taking one mid-stride), bottles on crates, chair legs and small crates on the
## floor, all clear of the run lanes and their open floor. They respawn here
## Tuning.PROP_RESPAWN s after they break.
const THROWABLES := [
	[&"brick", Vector3(-0.8, LOW_WALL_H, -6.5), 0.3], [&"brick", Vector3(0.7, LOW_WALL_H, -6.5), -0.4],
	[&"brick", Vector3(6.5, LOW_WALL_H, -1.1), 1.4], [&"brick", Vector3(6.5, LOW_WALL_H, 1.2), 1.8],
	[&"brick", Vector3(-5.35, PLATFORM_H, 1.3), 0.2],
	[&"bottle", Vector3(3.2, CRATE_H, -6.6), 0.0], [&"bottle", Vector3(-3.6, CRATE_H, 6.9), 0.0],
	[&"chair_leg", Vector3(-6.8, 0.0, -4.6), 0.9], [&"chair_leg", Vector3(6.9, 0.0, 4.6), -0.5],
	[&"crate_small", Vector3(-2.4, 0.0, 7.1), 0.25], [&"crate_small", Vector3(5.4, 0.0, -4.4), -0.3],
]
## Floor patches: [rect (x, z, w, d), surface, top y]. Thin bodies a few mm over
## the main floor so a ray down hits them first.
const WATER_RECT := Rect2(1.5, 1.6, 3.4, 2.4)
const METAL_RECT := Rect2(-3.6, -5.0, 2.4, 2.4)
const PATCH_TOP := 0.004
const WATER_TOP := 0.006
const METAL_TOP := 0.008

var _structure: StaticBody3D
## Round 5: arena walls (outer shell, south wall) as their own body so only
## they carry the "runnable" tag (door frames, stairs and columns do not).
var _arena_walls: StaticBody3D
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
	_arena_walls = ConcreteWall.new()
	_arena_walls.name = "ArenaWalls"
	_arena_walls.collision_layer = Layers.WORLD
	_arena_walls.collision_mask = 0
	_arena_walls.set_meta(&"surface", &"concrete")
	_arena_walls.add_to_group(&"world_static")
	_arena_walls.add_to_group(&"runnable")
	add_child(_arena_walls)
	_walls = Node3D.new()
	_walls.name = "Walls"
	add_child(_walls)
	_build_outer_shell()
	_build_side_block(-1, &"drywall")
	_build_side_block(1, &"brick")
	_build_garage()
	_build_stairwells()
	_build_pillars()
	_build_courtyard()
	_build_props()
	_build_spawns()
	ClutterLayout.build(self)  # Round 6 (agent K): breakable clutter in the fight area
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
	floor_body.add_to_group(&"floors")
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
	# Round 5 tagged floor surfaces (footsteps, landings, bodies): offices are
	# wood, the ground outside the walls dirt, plus a water patch and a metal
	# plate in the courtyard where the fights happen.
	_floor_patch("FloorOffices", Rect2(-OUTER_IN, -10.5, OUTER_IN - HALF, 21.0), PATCH_TOP, &"wood", null)
	_floor_patch("Water", WATER_RECT, WATER_TOP, &"water", WorldMaterials.water())
	_floor_patch("MetalPlate", METAL_RECT, METAL_TOP, &"metal", WorldMaterials.metal_plate())
	for r: Rect2 in [Rect2(-70, -70, 140, 70 - OUTER_IN - OUTER_T), Rect2(-70, SOUTH_Z.y, 140, 70 - SOUTH_Z.y),
			Rect2(-70, -OUTER_IN - OUTER_T, 70 - OUTER_IN - OUTER_T, OUTER_IN + OUTER_T + SOUTH_Z.y),
			Rect2(OUTER_IN + OUTER_T, -OUTER_IN - OUTER_T, 70 - OUTER_IN - OUTER_T, OUTER_IN + OUTER_T + SOUTH_Z.y)]:
		_floor_patch("Ground", r, PATCH_TOP, &"dirt", null)

## A thin floor body tagged `surface` (WorldTags.surface_of) whose top sits at
## `top` (a few mm over the main floor, so rays down hit it first). With a
## material it also draws its own top face.
func _floor_patch(id: String, rect: Rect2, top: float, surface: StringName, mat: Material) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = id
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	body.set_meta(&"surface", surface)
	body.add_to_group(&"world_static")
	body.add_to_group(&"floors")
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(rect.size.x, 0.1, rect.size.y)
	cs.shape = box
	cs.position = Vector3(rect.position.x + rect.size.x * 0.5, top - 0.05, rect.position.y + rect.size.y * 0.5)
	body.add_child(cs)
	add_child(body)
	if mat:
		_plane(body, rect, top + 0.001, mat)
	return body

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

## Axis-aligned static box from min/max corners (WORLD layer, never breaks),
## part of `body` (the structure unless given).
func _box(min_c: Vector3, max_c: Vector3, mat: Material = null, body: StaticBody3D = null) -> void:
	var parent := body if body else _structure
	var size := max_c - min_c
	var center := (min_c + max_c) * 0.5
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	cs.position = center
	parent.add_child(cs)
	var bm := BoxMesh.new()
	bm.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.material_override = mat if mat else WorldMaterials.concrete()
	mi.layers = Layers.VIS_WORLD
	mi.position = center
	parent.add_child(mi)

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
	# West and east outer walls (full depth), north outer wall, long south wall:
	# the runnable arena walls (they never break).
	_box(Vector3(-xo, 0, -xo), Vector3(-OUTER_IN, OUTER_H, SOUTH_Z.y), null, _arena_walls)
	_box(Vector3(OUTER_IN, 0, -xo), Vector3(xo, OUTER_H, SOUTH_Z.y), null, _arena_walls)
	_box(Vector3(-OUTER_IN, 0, -xo), Vector3(OUTER_IN, OUTER_H, -OUTER_IN), null, _arena_walls)
	_box(Vector3(-OUTER_IN, 0, SOUTH_Z.x), Vector3(OUTER_IN, OUTER_H, SOUTH_Z.y), null, _arena_walls)
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

# --- Round 5 courtyard: things to vault, mantle and run along -------------------------

## Low walls (0.9 m: speed vault), crates (1.1 m: vault; furniture that breaks
## when a body is thrown into it) and the 1.8 m platform (sprint mantle, wall-run
## kick-off). The pillars are the four at (+-6, +-6).
func _build_courtyard() -> void:
	_build_platform()
	for w: Array in LOW_WALLS:
		var c: Vector2 = w[0]
		var length: float = w[1]
		var along_x: bool = w[2]
		var face := Vector3(0, 0, 1) if along_x else Vector3(1, 0, 0)
		var p := _panel(w[3], Vector3(c.x, LOW_WALL_H * 0.5, c.y), face, Vector3(length, LOW_WALL_H, LOW_WALL_T))
		p.name = "LowWall_%d_%d" % [int(c.x), int(c.y)]
		p.set_meta(&"low_wall", true)
		p.support_mask = PanelFracture.SIDE_BOTTOM   # free-standing: held from below only
	for w: Array in PARTITIONS:
		var c: Vector2 = w[0]
		var length: float = w[1]
		var along_x: bool = w[2]
		var face := Vector3(0, 0, 1) if along_x else Vector3(1, 0, 0)
		var p := _panel(&"drywall", Vector3(c.x, PARTITION_H * 0.5 + 0.02, c.y), face,
			Vector3(length, PARTITION_H, PARTITION_T), &"interior")
		p.name = "Partition_%d_%d" % [int(c.x), int(c.y)]
		p.set_meta(&"partition", true)
		p.support_mask = PanelFracture.SIDE_BOTTOM
		# Steel feet at both ends (a free-standing office divider).
		var along := Vector3(1, 0, 0) if along_x else Vector3(0, 0, 1)
		for sgn in [-1.0, 1.0]:
			var fc: Vector3 = Vector3(c.x, 0.0, c.y) + along * sgn * (length * 0.5 - 0.1)
			var fh := along * 0.06 + Vector3(absf(along.z), 0, absf(along.x)) * 0.22
			_box(fc - fh, fc + fh + Vector3(0, 0.04, 0), WorldMaterials.frame())
	var plaza := TilePlaza.new()
	plaza.name = "TilePlaza"
	add_child(plaza)
	plaza.build(PLAZA_RECT, PLAZA_TILE, PATCH_TOP)
	for c in CRATES:
		var d := _prop(&"crate", Vector3(c.x, CRATE_H * 0.5, c.y), Vector3(CRATE_H, CRATE_H, CRATE_H), CRATE_BREAK,
			0.15 * sin(c.x * 3.1 + c.y))
		d.set_meta(&"courtyard", true)

## Round 6 platform: a deck slab on posts, with four breakable skirt faces
## (Tuning.PLATFORM_SKIRT_SURFACE boards). Walking into it is blocked, a sprint
## mantles onto the deck, and a body thrown into a face opens a hole into the
## hollow underneath (the posts show through). The deck never breaks.
func _build_platform() -> void:
	var r := PLATFORM_RECT
	_box(Vector3(r.position.x, PLATFORM_H - DECK_T, r.position.y), Vector3(r.end.x, PLATFORM_H, r.end.y),
		WorldMaterials.concrete(0.88))
	# A lip of darker concrete round the top edge so the ledge reads from below.
	var lip := 0.06
	_box(Vector3(r.position.x - lip, PLATFORM_H - 0.08, r.position.y - lip),
		Vector3(r.end.x + lip, PLATFORM_H, r.end.y + lip), WorldMaterials.concrete(0.7))
	for pc in PLATFORM_POSTS:
		_box(Vector3(pc.x - POST_SIZE * 0.5, 0, pc.y - POST_SIZE * 0.5),
			Vector3(pc.x + POST_SIZE * 0.5, PLATFORM_H - DECK_T, pc.y + POST_SIZE * 0.5), WorldMaterials.concrete(0.6))
	var skirt_h := PLATFORM_H - DECK_T
	var surface := Tuning.PLATFORM_SKIRT_SURFACE
	# West and east faces run the full depth; north and south fit between them.
	var faces := [
		[Vector3(r.position.x + SKIRT_T * 0.5, skirt_h * 0.5, r.get_center().y), Vector3.LEFT, r.size.y],
		[Vector3(r.end.x - SKIRT_T * 0.5, skirt_h * 0.5, r.get_center().y), Vector3.RIGHT, r.size.y],
		[Vector3(r.get_center().x, skirt_h * 0.5, r.position.y + SKIRT_T * 0.5), Vector3.FORWARD, r.size.x - SKIRT_T * 2.0],
		[Vector3(r.get_center().x, skirt_h * 0.5, r.end.y - SKIRT_T * 0.5), Vector3.BACK, r.size.x - SKIRT_T * 2.0],
	]
	for f: Array in faces:
		var p := _panel(surface, f[0], f[1], Vector3(f[2], skirt_h, SKIRT_T), &"boards")
		p.name = "PlatformSkirt_%s" % ["W", "E", "N", "S"][faces.find(f)]
		p.set_meta(&"platform_skirt", true)

## Round 6: what K's clutter layout must keep clear of, and what it may sit
## beside. Each {"kind": StringName, "aabb": AABB (floor level up), "keep_clear":
## bool (true: nothing may stand inside it)}. Kinds: &"platform",
## &"platform_approach" (2 m round the platform), &"low_wall", &"partition",
## &"pillar", &"pillar_fall" (where an overhead piece can land), &"crate",
## &"lamp", &"door" (door frames and their walk-through), &"plaza", &"water",
## &"metal", &"run_strip" (a wall-run lane's strip, 1.2 m off the wall),
## &"run_open" (the open floor beside it, to 3.5 m), &"breach" (2.5 m in front
## of each breach panel), &"entry" (the end of each spawn path), &"spawn"
## (player and duel spawns), &"lane" (the centre fight lanes). The run lanes'
## open floor (&"run_open") is keep-clear too (lead decision, Round 6 review).
func get_structure_features() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var add := func(kind: StringName, aabb: AABB, keep_clear: bool) -> void:
		out.append({"kind": kind, "aabb": aabb, "keep_clear": keep_clear})
	var r := PLATFORM_RECT
	var plat := AABB(Vector3(r.position.x, 0, r.position.y), Vector3(r.size.x, PLATFORM_H, r.size.y))
	add.call(&"platform", plat, true)
	add.call(&"platform_approach", plat.grow(2.0), true)
	var feats := get_parkour_features()
	for a: AABB in feats["low_walls"]:
		add.call(&"low_wall", a, true)
	for w: Array in PARTITIONS:
		var c: Vector2 = w[0]
		var sz := Vector3(w[1], PARTITION_H, PARTITION_T) if w[2] else Vector3(PARTITION_T, PARTITION_H, w[1])
		add.call(&"partition", AABB(Vector3(c.x, 0, c.y) - Vector3(sz.x, 0, sz.z) * 0.5, sz).grow(0.3), true)
	for p in PILLARS:
		add.call(&"pillar", AABB(Vector3(p.x - 0.5, 0, p.y - 0.5), Vector3(1, PILLAR_H, 1)), true)
		add.call(&"pillar_fall", AABB(Vector3(p.x - 1.6, 0, p.y - 1.6), Vector3(3.2, PILLAR_H + 0.5, 3.2)), false)
	for d: Destructible in feats["crates"]:
		add.call(&"crate", AABB(d.global_position - Vector3(0.6, d.global_position.y, 0.6), Vector3(1.2, CRATE_H, 1.2)), true)
	for x in LAMPS:
		add.call(&"lamp", AABB(Vector3(x - 0.4, 0, LAMP_Z - 0.4), Vector3(0.8, 4.6, 0.8)), true)
	for z in [-9.0, 9.0]:
		for x in [-HALF, HALF]:
			add.call(&"door", AABB(Vector3(x - 2.0 if x < 0 else x - 1.0, 0, z - 1.6), Vector3(3.0, 3.0, 3.2)), true)
	add.call(&"door", AABB(Vector3(-7.6, 0, -HALF - 1.0), Vector3(3.2, 3.0, 3.0)), true)
	add.call(&"plaza", AABB(Vector3(PLAZA_RECT.position.x, 0, PLAZA_RECT.position.y),
		Vector3(PLAZA_RECT.size.x, 0.05, PLAZA_RECT.size.y)), true)
	add.call(&"water", AABB(Vector3(WATER_RECT.position.x, 0, WATER_RECT.position.y), Vector3(WATER_RECT.size.x, 0.05, WATER_RECT.size.y)), false)
	add.call(&"metal", AABB(Vector3(METAL_RECT.position.x, 0, METAL_RECT.position.y), Vector3(METAL_RECT.size.x, 0.05, METAL_RECT.size.y)), false)
	for lane: Dictionary in get_wall_run_lanes():
		var a: Vector3 = lane["from"]
		var b: Vector3 = lane["to"]
		var n: Vector3 = lane["normal"]
		var strip := AABB(a, Vector3.ZERO).expand(b).expand(a + n * 1.2).expand(b + n * 1.2)
		strip.size.y = 3.0
		add.call(&"run_strip", strip, true)
		var open := AABB(a + n * 1.2, Vector3.ZERO).expand(b + n * 1.2).expand(a + n * 3.5).expand(b + n * 3.5)
		open.size.y = 3.0
		add.call(&"run_open", open, true)
	for wall in get_breach_walls():
		var into := wall.global_basis.z
		into.y = 0.0
		into = into.normalized()
		var c0 := wall.global_position
		c0.y = 0.0
		var lane := AABB(c0 - Vector3(absf(into.z), 0, absf(into.x)) * 1.0, Vector3.ZERO)
		lane = lane.expand(c0 + Vector3(absf(into.z), 0, absf(into.x)) * 1.0).expand(c0 + into * 2.5 \
			+ Vector3(absf(into.z), 0, absf(into.x)) * 1.0)
		lane.size.y = 2.5
		add.call(&"breach", lane, true)
	for s: Dictionary in get_enemy_spawns():
		var path: PackedVector3Array = s["path"]
		var e := path[path.size() - 1]
		add.call(&"entry", AABB(Vector3(e.x - 1.5, 0, e.z - 1.5), Vector3(3.0, 2.5, 3.0)), true)
	var spots: Array[Transform3D] = [get_player_spawn()]
	spots.append_array(get_duel_spawns())
	for t in spots:
		add.call(&"spawn", AABB(Vector3(t.origin.x - 1.5, 0, t.origin.z - 1.5), Vector3(3.0, 2.5, 3.0)), true)
	add.call(&"lane", AABB(Vector3(-1.5, 0, -HALF), Vector3(3.0, 2.5, HALF * 2.0)), true)
	add.call(&"lane", AABB(Vector3(-HALF + 3.5, 0, -1.0), Vector3(HALF * 2.0 - 7.0, 2.5, 2.0)), true)
	return out

## Straight runnable wall lanes in the courtyard (F7b): each {"name", "from",
## "to" (Vector3 on the wall face, floor level), "normal" (into the courtyard),
## "length"}. Every lane has open floor beside it.
func get_wall_run_lanes() -> Array[Dictionary]:
	var face_x := HALF
	var face_z := HALF
	# Facade lanes run between the doorway jambs (JAMB inside the door slots).
	var facade_end := 7.5 - 0.2
	var lanes: Array[Dictionary] = [
		{"name": &"west_facade", "from": Vector3(-face_x, 0, -facade_end), "to": Vector3(-face_x, 0, facade_end),
			"normal": Vector3.RIGHT},
		{"name": &"east_facade", "from": Vector3(face_x, 0, -facade_end), "to": Vector3(face_x, 0, facade_end),
			"normal": Vector3.LEFT},
		{"name": &"garage_facade", "from": Vector3(-4.3, 0, -face_z), "to": Vector3(10.3, 0, -face_z), "normal": Vector3.BACK},
		{"name": &"south_wall", "from": Vector3(LAMPS[0] + 0.4, 0, face_z), "to": Vector3(LAMPS[1] - 0.4, 0, face_z),
			"normal": Vector3.FORWARD},
	]
	for l: Dictionary in lanes:
		l["length"] = (l["from"] as Vector3).distance_to(l["to"])
	return lanes

## Parkour features (tests, AI, debug): {"low_walls": [AABB], "crates": [Destructible],
## "platform": AABB, "pillars": [Pillar], "water": Rect2, "metal": Rect2}.
func get_parkour_features() -> Dictionary:
	var lows: Array[AABB] = []
	for w: Array in LOW_WALLS:
		var c: Vector2 = w[0]
		var length: float = w[1]
		var sz := Vector3(length, LOW_WALL_H, LOW_WALL_T) if w[2] else Vector3(LOW_WALL_T, LOW_WALL_H, length)
		lows.append(AABB(Vector3(c.x, 0, c.y) - Vector3(sz.x, 0, sz.z) * 0.5, sz))
	var crates: Array[Destructible] = []
	for d in get_destructibles():
		if d.kind == &"crate" and d.has_meta(&"courtyard"):
			crates.append(d)
	var pillars: Array[Pillar] = []
	for c in get_children():
		if c is Pillar:
			pillars.append(c)
	var r := PLATFORM_RECT
	return {"low_walls": lows, "crates": crates, "pillars": pillars,
		"platform": AABB(Vector3(r.position.x, 0, r.position.y), Vector3(r.size.x, PLATFORM_H, r.size.y)),
		"water": WATER_RECT, "metal": METAL_RECT}

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
	_build_throwables()
	# South strip: lamp posts at the two ends of the south wall's run lane.
	for x in LAMPS:
		_prop(&"lamp", Vector3(x, 0, LAMP_Z), Vector3(0.28, 4.6, 0.28), LAMP_BREAK, 0.0 if x < 0.0 else PI)

## Throwable props resting on their ledges (each respawns at its spot).
func _build_throwables() -> void:
	var holder := Node3D.new()
	holder.name = "Throwables"
	add_child(holder)
	for t: Array in THROWABLES:
		var kind: StringName = t[0]
		var at: Vector3 = t[1]
		var spec: Dictionary = ThrowableProp.KINDS[kind]
		var lift := 0.0
		var basis := Basis(Vector3.UP, float(t[2]))
		if kind == &"chair_leg" or kind == &"stick":
			# Long thin props lie on their side.
			basis = basis * Basis(Vector3.RIGHT, PI * 0.5)
			lift = (spec["box"] as Vector3).x * 0.5 if spec.has("box") else (spec["cyl"] as Vector2).x * 1.2
		elif spec.has("box"):
			lift = (spec["box"] as Vector3).y * 0.5
		elif spec.has("cyl"):
			lift = (spec["cyl"] as Vector2).y * 0.5
		ThrowableProp.spawn(holder, kind, Transform3D(basis, at + Vector3(0, lift + 0.005, 0)), true)

## Every throwable prop in the yard (tests, AI).
func get_throwables() -> Array[ThrowableProp]:
	var out: Array[ThrowableProp] = []
	var holder := get_node_or_null(^"Throwables")
	if holder:
		for c in holder.get_children():
			if c is ThrowableProp and not c.is_queued_for_deletion():
				out.append(c)
	return out

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
## Round 6: a door frame is two wood jambs (Destructible kind &"jamb", break
## whole at Tuning.SURFACES.wood) and the lintel over the opening (kind
## &"lintel"), which creaks and falls when either jamb breaks.
func _door_frame(c: Vector3, along: Vector3, thickness: float) -> void:
	var yaw := 0.0 if absf(along.x) > 0.5 else PI * 0.5
	var lintel := Destructible.new()
	lintel.kind = &"lintel"
	lintel.surface = &"wood"
	lintel.size = Vector3(DOOR_W, PANEL - DOOR_H, thickness)
	lintel.name = "Lintel_%d_%d" % [int(round(c.x * 10.0)), int(round(c.z * 10.0))]
	lintel.transform = Transform3D(Basis(Vector3.UP, yaw), c + Vector3(0, DOOR_H + (PANEL - DOOR_H) * 0.5, 0))
	lintel.set_meta(&"door_frame", true)
	_walls.add_child(lintel)
	for sgn in [-1.0, 1.0]:
		var j := Destructible.new()
		j.kind = &"jamb"
		j.surface = &"wood"
		j.size = Vector3(JAMB, PANEL, thickness)
		j.name = "Jamb_%d_%d_%d" % [int(round(c.x * 10.0)), int(round(c.z * 10.0)), int(sgn)]
		j.transform = Transform3D(Basis(Vector3.UP, yaw), c + along * sgn * (PANEL * 0.5 - JAMB * 0.5) + Vector3(0, PANEL * 0.5, 0))
		j.set_meta(&"door_frame", true)
		j.lintel = lintel
		_walls.add_child(j)

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
