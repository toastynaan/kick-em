extends Node
## Autoload "WorldDamage" (Round 6): floor damage and blasts. Listens to the
## events that hit the floor or shake the world (heavy landings and slams,
## hard body impacts on the floor, wall breaks, structure collapses), keeps a
## per-cell floor damage grid for the round (crack, crater, rubble; tiles pop
## in the tiled plaza), and applies blasts to nearby breakables through their
## receive_blast(). Emits floor_damaged and world_blast; F draws the marks.
## OWNER: agent D (world). CONTRACT STUB: keep every public signature.
##
## Floor: Tuning.FLOOR_CELL cells; energy accumulates per cell for the round
## and the level is the highest Tuning.FLOOR_LEVEL_ENERGY reached (1 crack,
## 2 crater, 3 rubble). A hit near a cell that is already damaged adds to it,
## so repeated landings on one spot deepen one mark. Every new level emits
## GameEvents.floor_damaged(cell centre, Tuning.FLOOR_LEVEL_RADIUS, level,
## surface). Water takes no marks. On a TilePlaza the tiles within the mark's
## radius also take the energy and pop out at Tuning.TILE_BREAK_ENERGY.
## Sources (energy = 1/2 M v^2 of the lander at touchdown):
## - landing &"hard": that energy (8-11 m/s: 2,240-4,235 J, a crack);
##   &"soft" marks nothing; &"heavy" (a slam or a fall over 11 m/s): at least
##   HEAVY_FLOOR_MIN (a crater), plus a &"heavy_landing" blast.
## - body_slammed: holder and victim land together at SLAM_SPEED: a crater, and
##   a &"slam" blast. shockwave: a &"slam" blast unless one already went off there.
## - body_impact on the floor (a launched or thrown body landing): its energy;
##   never on bodies, debris or breakables (a corpse or a table top is not floor).
## - wall_broken: a &"wall_break" blast of WALL_BLAST_SHARE of the break energy.
## - structure_collapsed &"panel": a &"structure" blast on the floor under the
##   falling cells. Overhead pieces and lintels blast where they land
##   (FallingPiece calls blast() from its landing), never at creak time.
## One impact is one mark: floor hits within FLOOR_DEDUPE_DIST and
## FLOOR_DEDUPE_TIME of an earlier one only add what they exceed it by (a carry
## slam's landing, its body_slammed and the victim's own floor impact are one
## crater); a landing while Carry.is_slamming() is left to body_slammed, and the
## slam victim's floor impacts are ignored for SLAM_VICTIM_IGNORE s.
## Marks go only on a real floor: a short ray down must find static,
## non-breakable WORLD geometry facing up within FLOOR_REACH m.
## Blasts: every breakable within Tuning.BLAST[source] gets receive_blast(center,
## radius, power_at_it, source) where power_at_it is the blast's power with
## linear falloff to 0 at the radius, measured at the object's nearest point
## (receivers do NOT apply falloff again). Loose bodies (props, debris) under
## HOP_MAX_MASS hop.

## Heavy landings and slams crater the floor (Tuning.FLOOR_LEVEL_ENERGY[1]).
const HEAVY_FLOOR_MIN := 5000.0
## m/s two bodies land at in a body slam (Tuning.LAND_HEAVY_SPEED).
const SLAM_SPEED := 11.0
## Floor impacts of flying bodies count from this energy (Tuning.IMPACT_MIN_ENERGY).
const FLOOR_IMPACT_MIN := 500.0
## Share of a wall break's energy that reaches the surroundings as a blast.
const WALL_BLAST_SHARE := 0.5
## J of a structure collapse blast by kind.
const STRUCTURE_BLAST := {&"panel": 400.0, &"overhead": 2500.0, &"lintel": 1200.0}
const STRUCTURE_BLAST_DEFAULT := 800.0
## Loose bodies under this mass hop in a blast, at up to HOP_SPEED (m/s) by
## falloff and power (full at HOP_FULL_POWER J).
const HOP_MAX_MASS := 30.0
const HOP_SPEED := 2.8
const HOP_FULL_POWER := 2000.0
## A second blast within this distance (m) and time (s) of the last one is the same event.
const DEDUPE_DIST := 1.0
const DEDUPE_TIME := 0.1

## Floor hits closer than this (m) and sooner than this (s) are one impact.
const FLOOR_DEDUPE_DIST := 1.5
const FLOOR_DEDUPE_TIME := 0.3
## s a body-slam victim's own floor impacts are ignored.
const SLAM_VICTIM_IGNORE := 0.3
## m below the point a floor must be found (else no mark).
const FLOOR_REACH := 0.5

## Debug / test hook: every blast and what it reached.
signal blasted(center: Vector3, radius: float, power: float, source: StringName, reached: Array)

var _cells := {}              ## Vector2i -> {"e": float, "level": int, "surface": StringName, "pos": Vector3}
var _collapses := 0           ## structure_collapsed events this round
var _floor_recent: Array = [] ## [time, Vector3, energy] of the last floor hits (dedupe)
var _slam_victims := {}       ## instance id -> time of its body slam
var _recent: Array = []       ## [time, Vector3] of the last blasts (dedupe)
var _blast_depth := 0
var _time := 0.0
var _query := PhysicsShapeQueryParameters3D.new()
var _sphere := SphereShape3D.new()

func _ready() -> void:
	process_physics_priority = 90
	_query.shape = _sphere
	_query.collide_with_areas = false
	_query.collide_with_bodies = true
	_query.collision_mask = Layers.DESTRUCTIBLE | Layers.WORLD | Layers.DEBRIS | Layers.DEBRIS_SMALL
	GameEvents.landing.connect(_on_landing)
	GameEvents.shockwave.connect(_on_shockwave)
	GameEvents.body_slammed.connect(_on_body_slammed)
	GameEvents.body_impact.connect(_on_body_impact)
	GameEvents.wall_broken.connect(_on_wall_broken)
	GameEvents.structure_collapsed.connect(_on_structure_collapsed)
	GameEvents.round_started.connect(func(_m: StringName) -> void: reset())

func _physics_process(delta: float) -> void:
	_time += delta

## Floor damage level at a world point: 0 none, 1 crack, 2 crater, 3 rubble.
func floor_level_at(pos: Vector3) -> int:
	var c: Variant = _cells.get(_key(pos))
	return int((c as Dictionary)["level"]) if c != null else 0

## Add floor damage directly (tests, scripted events). Returns the cell's new level.
func damage_floor(pos: Vector3, energy: float, surface: StringName = &"concrete") -> int:
	if energy <= 0.0:
		return 0
	var under := _floor_at(pos)
	if under.is_empty():
		return 0   # not on a floor (a table top, a pane, rubble, a stump): no mark
	var surf: StringName = under.get("surface", surface)
	var at: Vector3 = under["position"]
	if surf == &"water":
		return 0
	var key := _merge_key(at)
	var c: Dictionary = _cells.get(key, {})
	if c.is_empty():
		c = {"e": 0.0, "level": 0, "surface": surf, "pos": _cell_centre(key, at.y)}
		_cells[key] = c
	c["e"] = float(c["e"]) + energy
	var level := _level_for(float(c["e"]))
	var plaza := under.get("plaza") as TilePlaza
	if plaza != null:
		var r: float = Tuning.FLOOR_LEVEL_RADIUS[maxi(level, 1) - 1]
		plaza.damage_at(at, energy, r)
	if level > int(c["level"]):
		c["level"] = level
		GameEvents.floor_damaged.emit(c["pos"], Tuning.FLOOR_LEVEL_RADIUS[level - 1], level, c["surface"])
	return int(c["level"])

## Apply a blast to every breakable within `radius` of `center` (linear falloff).
## Returns how many objects it reached. `exclude`: the object the blast comes
## from (a wall's own break never blasts that wall).
func blast(center: Vector3, radius: float, power: float, source: StringName, exclude: Node = null) -> int:
	if radius <= 0.0 or power <= 0.0 or not is_inside_tree():
		return 0
	var world := get_viewport().find_world_3d()
	if world == null:
		return 0
	_blast_depth += 1
	_recent.append([_time, center])
	GameEvents.world_blast.emit(center, radius, power, source)
	_sphere.radius = radius
	_query.transform = Transform3D(Basis(), center)
	_query.exclude = _static_rids()
	var reached: Array = []
	var seen := {}
	for h: Dictionary in world.direct_space_state.intersect_shape(_query, 96):
		var col: Object = h.get("collider")
		if col == null or not is_instance_valid(col):
			continue
		var b := WorldTags.breakable_of(col)
		if b != null and b is Node3D:
			if b == exclude or seen.has(b.get_instance_id()) or not b.has_method(&"receive_blast") \
					or bool(b.get(&"is_broken")):
				continue
			seen[b.get_instance_id()] = true
			var d := _distance_to(b as Node3D, center)
			var f := 1.0 - d / radius
			if f <= 0.0:
				continue
			var res: Variant = b.call(&"receive_blast", center, radius, power * f, source)
			reached.append([b, power * f, res])
		elif col is RigidBody3D and not seen.has(col.get_instance_id()):
			seen[col.get_instance_id()] = true
			if _hop(col as RigidBody3D, center, radius, power):
				reached.append([col, 0.0, &"hop"])
	_blast_depth -= 1
	blasted.emit(center, radius, power, source, reached)
	return reached.size()

## Counts for the end-of-wave tally (J): {"cracks", "craters", "rubble", "tiles"}.
func get_floor_counts() -> Dictionary:
	var out := {"cracks": 0, "craters": 0, "rubble": 0, "tiles": 0}
	for k: Vector2i in _cells:
		match int((_cells[k] as Dictionary)["level"]):
			1:
				out["cracks"] += 1
			2:
				out["craters"] += 1
			3:
				out["rubble"] += 1
	if is_inside_tree():
		for p in get_tree().get_nodes_in_group(&"tile_plazas"):
			out["tiles"] += int((p as TilePlaza).popped_count) if p is TilePlaza else 0
	return out

## Structure collapses this round (panels' falling cells, lintels, overhead pieces).
func get_collapse_count() -> int:
	return _collapses

## Round restart.
func reset() -> void:
	_cells.clear()
	_recent.clear()
	_floor_recent.clear()
	_slam_victims.clear()
	_collapses = 0

# --- Events --------------------------------------------------------------------

func _on_landing(fighter: Node3D, level: StringName, pos: Vector3, vertical_speed: float) -> void:
	if level != &"hard" and level != &"heavy":
		return
	# A carry slam lands holder and victim together: body_slammed marks it.
	var carry: Variant = fighter.get(&"carry") if fighter != null else null
	if carry != null and (carry as Object).has_method(&"is_slamming") and bool((carry as Object).call(&"is_slamming")):
		return
	var m := _mass_of(fighter)
	var e := 0.5 * m * vertical_speed * vertical_speed
	if level == &"heavy":
		e = maxf(e, HEAVY_FLOOR_MIN)
	_floor_event(pos, e)
	if level == &"heavy" and not _recently_blasted(pos):
		blast(pos, float(Tuning.BLAST[&"heavy_landing"]), e, &"heavy_landing")

func _on_shockwave(fighter: Node3D, pos: Vector3, _stumble_r: float, _knock_r: float) -> void:
	if _recently_blasted(pos):
		return
	var e := maxf(0.5 * _mass_of(fighter) * SLAM_SPEED * SLAM_SPEED, HEAVY_FLOOR_MIN)
	blast(pos, float(Tuning.BLAST[&"slam"]), e, &"slam")

func _on_body_slammed(holder: Node3D, victim: Node3D, pos: Vector3) -> void:
	var e := 0.5 * (_mass_of(holder) + (_mass_of(victim) if victim != null else 0.0)) * SLAM_SPEED * SLAM_SPEED
	if victim != null and is_instance_valid(victim):
		_slam_victims[victim.get_instance_id()] = _time
	_floor_event(pos, maxf(e, HEAVY_FLOOR_MIN))
	if not _recently_blasted(pos):
		blast(pos, float(Tuning.BLAST[&"slam"]), e, &"slam")

func _on_body_impact(fighter: Node3D, pos: Vector3, normal: Vector3, energy: float, surface: StringName) -> void:
	if normal.y <= 0.7 or energy < FLOOR_IMPACT_MIN or surface == &"body" or surface == &"debris":
		return
	if fighter != null and _time - float(_slam_victims.get(fighter.get_instance_id(), -INF)) < SLAM_VICTIM_IGNORE:
		return
	_floor_event(pos, energy)

## An event-driven floor hit: within FLOOR_DEDUPE_DIST / FLOOR_DEDUPE_TIME of an
## earlier one it only adds what it exceeds that one by (one impact, one mark).
func _floor_event(pos: Vector3, energy: float) -> void:
	var keep: Array = []
	var prev := 0.0
	var at := pos
	for r: Array in _floor_recent:
		if _time - float(r[0]) > FLOOR_DEDUPE_TIME:
			continue
		keep.append(r)
		if (r[1] as Vector3).distance_to(pos) <= FLOOR_DEDUPE_DIST and float(r[2]) > prev:
			prev = float(r[2])
			at = r[1]
	_floor_recent = keep
	var extra := energy - prev
	if extra <= 0.0:
		return
	_floor_recent.append([_time, at if prev > 0.0 else pos, energy])
	damage_floor(at if prev > 0.0 else pos, extra)

func _on_wall_broken(wall: Node3D, pos: Vector3, energy: float, _velocity: Vector3) -> void:
	if _blast_depth > 0:
		return   # a blast that broke something does not chain into another blast
	blast(pos, float(Tuning.BLAST[&"wall_break"]), energy * WALL_BLAST_SHARE, &"wall_break", wall)

func _on_structure_collapsed(node: Node3D, pos: Vector3, kind: StringName) -> void:
	_collapses += 1
	# Overhead pieces and lintels blast where they land (FallingPiece); a panel's
	# falling cells shake the floor under them.
	if _blast_depth > 0 or kind != &"panel":
		return
	var ground := _ground_below(pos)
	blast(ground, float(Tuning.BLAST[&"structure"]), float(STRUCTURE_BLAST.get(kind, STRUCTURE_BLAST_DEFAULT)), &"structure",
		node)

## The floor point straight below `pos` (WORLD floors, up to 6 m), else `pos`.
func _ground_below(pos: Vector3) -> Vector3:
	if not is_inside_tree():
		return pos
	var world := get_viewport().find_world_3d()
	var q := PhysicsRayQueryParameters3D.create(pos, pos + Vector3.DOWN * 6.0, Layers.WORLD)
	var hit := world.direct_space_state.intersect_ray(q) if world else {}
	return hit["position"] if not hit.is_empty() else pos

# --- Helpers --------------------------------------------------------------------

func _recently_blasted(pos: Vector3) -> bool:
	var keep: Array = []
	var hit := false
	for r: Array in _recent:
		if _time - float(r[0]) <= DEDUPE_TIME:
			keep.append(r)
			if (r[1] as Vector3).distance_to(pos) <= DEDUPE_DIST:
				hit = true
	_recent = keep
	return hit

static func _mass_of(n: Node3D) -> float:
	if n != null and is_instance_valid(n) and n.has_method(&"get_total_mass"):
		return float(n.call(&"get_total_mass"))
	return 70.0

func _level_for(e: float) -> int:
	var level := 0
	for i in Tuning.FLOOR_LEVEL_ENERGY.size():
		if e >= Tuning.FLOOR_LEVEL_ENERGY[i]:
			level = i + 1
	return level

func _key(pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(pos.x / Tuning.FLOOR_CELL)), int(floor(pos.z / Tuning.FLOOR_CELL)))

func _cell_centre(k: Vector2i, y: float) -> Vector3:
	return Vector3((k.x + 0.5) * Tuning.FLOOR_CELL, y, (k.y + 0.5) * Tuning.FLOOR_CELL)

## The cell a hit at `pos` adds to: its own, unless a neighbour already holds
## more damage and its centre is within 0.75 cell of the point (one mark).
func _merge_key(pos: Vector3) -> Vector2i:
	var k := _key(pos)
	var best := k
	var best_e: float = float((_cells.get(k, {"e": 0.0}) as Dictionary)["e"])
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var n := Vector2i(k.x + dx, k.y + dz)
			if n == k or not _cells.has(n):
				continue
			var c: Dictionary = _cells[n]
			var cc := _cell_centre(n, pos.y)
			if float(c["e"]) > best_e and Vector2(cc.x - pos.x, cc.z - pos.z).length() <= 0.75 * Tuning.FLOOR_CELL:
				best = n
				best_e = float(c["e"])
	return best

## The floor under `pos`: {"position" (on the floor), "surface", "plaza"
## (TilePlaza or null)}, or {} when no floor (static, not breakable: never a
## pillar stump, furniture, a pane, rubble or a body; facing up) lies within
## FLOOR_REACH m below the point.
func _floor_at(pos: Vector3) -> Dictionary:
	if not is_inside_tree():
		return {}
	var world := get_viewport().find_world_3d()
	if world == null:
		return {}
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 0.3, pos + Vector3.DOWN * FLOOR_REACH, Layers.WORLD)
	var hit := world.direct_space_state.intersect_ray(q)
	if hit.is_empty() or (hit["normal"] as Vector3).y < 0.7:
		return {}
	var col := hit["collider"] as Node
	if not (col is StaticBody3D) or WorldTags.breakable_of(col) != null:
		return {}
	return {"position": hit["position"], "surface": WorldTags.surface_of(col), "plaza": col as TilePlaza}

## Distance from `center` to the nearest point of a breakable's box.
static func _distance_to(b: Node3D, center: Vector3) -> float:
	var box := ImpactResolver.box_of(b)
	var xf: Transform3D = box[0]
	var h: Vector3 = box[1]
	var lp := xf.affine_inverse() * center
	return (xf * lp.clamp(-h, h)).distance_to(center)

## A loose light body near a blast hops (frozen debris wakes first). Held props stay put.
func _hop(b: RigidBody3D, center: Vector3, radius: float, power: float) -> bool:
	if b.mass > HOP_MAX_MASS or (b is ThrowableProp and (b as ThrowableProp).is_held()):
		return false
	var d := b.global_position.distance_to(center)
	var f := 1.0 - d / radius
	if f <= 0.0:
		return false
	if b.freeze:
		if DebrisManager.is_frozen(b):
			DebrisManager.wake_near(b.global_position, 0.05)
		else:
			return false
	var away := b.global_position - center
	away.y = 0.0
	away = away.normalized() if away.length() > 0.05 else Vector3.ZERO
	var k := HOP_SPEED * f * clampf(power / HOP_FULL_POWER, 0.3, 1.0)
	b.sleeping = false
	b.linear_velocity += Vector3.UP * k + away * k * 0.4
	return true

var _static_cache: Array[RID] = []
var _static_frame := -1

func _static_rids() -> Array[RID]:
	var fr := Engine.get_physics_frames()
	if fr != _static_frame:
		_static_frame = fr
		_static_cache.clear()
		for n in get_tree().get_nodes_in_group(&"world_static"):
			if n is CollisionObject3D:
				_static_cache.append((n as CollisionObject3D).get_rid())
	return _static_cache
