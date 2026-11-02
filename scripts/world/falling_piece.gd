class_name FallingPiece
extends RigidBody3D
## Round 6: a heavy piece of structure coming down (a pillar's overhead piece,
## a door lintel, the upper sections of a snapped pillar). While it moves it
## sweeps a little ahead of itself:
## - Fighters' capsules: the first time it reaches a fighter (any fighter, the
##   player included) while falling (v.y < -HIT_FALL_SPEED) or fast (at least
##   HIT_MIN_SPEED) it hits through the normal pipeline with a preset-tier
##   HitInfo, kind &"debris", by its energy E = 1/2 m v^2:
##   Tuning.FALLING_HIT_ENERGY.y and up a knockdown, .x and up a stagger,
##   Tuning.FALLING_DAMAGE. A piece rolling slowly hurts nobody.
## - Breakables (the Round 6 contract: K's clutter, panels, props): once each,
##   receive_impact(E, contact, v) with meta "impact_body" = this piece. They
##   break, crack or bounce; through a broken one the piece keeps
##   sqrt(1 - absorption) of its speed and falls on, through its pieces for
##   BREAK_GHOST s.
## Its first landing (a sharp stop, or coming to rest after a fast fall) sets
## off a &"structure" blast where it lands (WorldDamage.blast, power E) and
## marks the floor only if what is right under it is floor (not a pane, rubble
## or a body). Lighter than
## Tuning.FALLING_MIN_MASS it never hurts or breaks anything (small debris
## never hurts). It stops checking once at rest; DebrisManager keeps it.
## OWNER: agent D (world).

## m/s: under this for REST_TIME s the piece is at rest and stops checking.
const REST_SPEED := 0.3
const REST_TIME := 0.5
## s of travel looked ahead each tick.
const LOOK_AHEAD := 2.0 / 120.0
## A landing: within LAND_WINDOW s the speed drops under LAND_DROP of its peak,
## the peak moving down at least LAND_MIN_SPEED (a stop spread over a few ticks
## on rubble counts too).
const LAND_DROP := 0.5
const LAND_MIN_SPEED := 3.0
const LAND_WINDOW := 0.08
## A piece that came down at least LAND_MIN_SPEED and has been at rest this
## long without a landing (a slow stop on a body or on rubble) lands there.
const LAND_REST := 0.1
## s the piece passes through the pieces of something it just broke (they are
## young debris then: DebrisManager holds their speed when it ends), so the
## staves of a barrel do not hold a beam up.
const BREAK_GHOST := 0.15
## Knockdown push along the piece's horizontal motion (m/s).
const KNOCKDOWN_PUSH := 1.5
## Hits fighters only while falling faster than this (m/s down) or moving at least HIT_MIN_SPEED.
const HIT_FALL_SPEED := 1.0
const HIT_MIN_SPEED := 3.0
## Breakables are only judged while the piece moves at least this fast (m/s).
const BREAK_MIN_SPEED := 1.0
## m: what is right under the landing piece must be floor within this.
const FLOOR_CONTACT := 0.15

## Fighters already hit by this piece (instance id -> true).
var hit_fighters := {}
## Breakables already judged (instance id -> outcome).
var hit_breakables := {}
var has_landed := false
## Emitted for every fighter it hits and every breakable it judges (tests, debug).
signal hit_fighter(fighter: Node3D, energy: float, tier: int)
signal hit_breakable(breakable: Node3D, energy: float, outcome: StringName)
signal landed_at(position: Vector3, energy: float, on_floor: bool)

var _rest := 0.0
var _peak := Vector3.ZERO
var _peak_age := 0.0
## Its fastest fall so far (the velocity with the lowest y).
var _fall_peak := Vector3.ZERO
## [seconds left, Array of bodies] it passes through.
var _ghosts: Array = []
var _query := PhysicsShapeQueryParameters3D.new()
var _box := BoxShape3D.new()

func _ready() -> void:
	add_to_group(&"falling_pieces")
	_query.shape = _box
	_query.collision_mask = Layers.CAPSULE | Layers.DESTRUCTIBLE | Layers.WORLD
	_query.collide_with_areas = false
	_query.collide_with_bodies = true
	if not has_meta(&"surface"):
		set_meta(&"surface", &"concrete")

func _physics_process(delta: float) -> void:
	if delta <= 0.0 or freeze:
		return
	if not _ghosts.is_empty():
		_tick_ghosts(delta)
	var v := linear_velocity
	var speed := v.length()
	# A landing first: a clean stop on hard floor ends below REST_SPEED in one tick.
	if not has_landed and _peak.length() >= LAND_MIN_SPEED and _peak.y < -1.0 and speed < _peak.length() * LAND_DROP:
		_land(_peak)
	_peak_age += delta
	if speed >= _peak.length() or _peak_age > LAND_WINDOW:
		_peak = v
		_peak_age = 0.0
	if v.y < _fall_peak.y:
		_fall_peak = v
	if speed < REST_SPEED:
		_rest += delta
		if not has_landed and _rest >= LAND_REST and -_fall_peak.y >= LAND_MIN_SPEED:
			_land(_fall_peak)
		if _rest >= REST_TIME and _ghosts.is_empty():
			set_physics_process(false)
		return
	_rest = 0.0
	if mass >= Tuning.FALLING_MIN_MASS:
		_sweep(v)

## The piece's world AABB from its collision shapes.
func get_bounds() -> AABB:
	var out := AABB()
	var first := true
	for c in get_children():
		var cs := c as CollisionShape3D
		if cs == null or cs.shape == null:
			continue
		var a: AABB = cs.global_transform * cs.shape.get_debug_mesh().get_aabb()
		out = a if first else out.merge(a)
		first = false
	return out if not first else AABB(global_position - Vector3.ONE * 0.2, Vector3.ONE * 0.4)

func _sweep(v: Vector3) -> void:
	var b := get_bounds()
	var sweep := b.merge(AABB(b.position + v * LOOK_AHEAD, b.size)).grow(0.03)
	_box.size = sweep.size
	_query.transform = Transform3D(Basis(), sweep.get_center())
	var excl: Array[RID] = [get_rid()]
	for n in get_tree().get_nodes_in_group(&"world_static"):
		if n is CollisionObject3D:
			excl.append((n as CollisionObject3D).get_rid())
	_query.exclude = excl
	var speed := v.length()
	var falling := v.y < -HIT_FALL_SPEED or speed >= HIT_MIN_SPEED
	var seen := {}
	for h: Dictionary in get_world_3d().direct_space_state.intersect_shape(_query, 24):
		var col: Object = h.get("collider")
		if col == null or not is_instance_valid(col):
			continue
		if col is Fighter:
			if falling:
				_check_fighter(col as Fighter, v)
			continue
		var br := WorldTags.breakable_of(col)
		if br == null or not (br is Node3D) or seen.has(br.get_instance_id()):
			continue
		seen[br.get_instance_id()] = true
		if speed >= BREAK_MIN_SPEED:
			_check_breakable(br as Node3D, v, b)

func _check_fighter(f: Fighter, v: Vector3) -> void:
	if f.is_dead() or hit_fighters.has(f.get_instance_id()):
		return
	hit_fighters[f.get_instance_id()] = true
	var e := 0.5 * mass * v.length_squared()
	var tier := HitInfo.Tier.NONE
	if e >= Tuning.FALLING_HIT_ENERGY.y:
		tier = HitInfo.Tier.KNOCKDOWN
	elif e >= Tuning.FALLING_HIT_ENERGY.x:
		tier = HitInfo.Tier.STAGGER
	if tier == HitInfo.Tier.NONE:
		return
	var info := build_hit(f, tier, v, global_position, e)
	f.take_hit(info)
	if info.result == HitInfo.Result.HIT and is_instance_valid(f):
		TimeDirector.hitstop([f], Power.hitstop_for(tier))
	hit_fighter.emit(f, e, tier)

## A breakable in the piece's path: judged once, before contact (so a broken one
## lets the piece through).
func _check_breakable(br: Node3D, v: Vector3, bounds: AABB) -> void:
	if hit_breakables.has(br.get_instance_id()) or bool(br.get(&"is_broken")) or not br.has_method(&"receive_impact"):
		return
	var box := ImpactResolver.box_of(br)
	var speed := v.length()
	var t_hit := ImpactResolver.time_to_contact_obb(bounds.get_center(), bounds.size * 0.5, v, box[0], box[1])
	if is_inf(t_hit) or t_hit * speed > maxf(speed * LOOK_AHEAD * 1.5, 0.05):
		return
	var e := 0.5 * mass * v.length_squared()
	var xf: Transform3D = box[0]
	var half: Vector3 = box[1]
	var contact := xf * (xf.affine_inverse() * bounds.get_center()).clamp(-half, half)
	br.set_meta(&"impact_body", self)
	var out: StringName = br.call(&"receive_impact", e, contact, v, Rect2())
	hit_breakables[br.get_instance_id()] = out
	if out == &"break" or out == &"hole":
		linear_velocity *= sqrt(maxf(1.0 - float(br.get(&"absorption")), 0.0))
		_ghost_through(br)
	hit_breakable.emit(br, e, out)

## Pass through the pieces `br` just broke into for BREAK_GHOST s.
func _ghost_through(br: Node3D) -> void:
	var chunks: Variant = br.get(&"last_chunks")
	if not (chunks is Array):
		return
	var bodies: Array = []
	for c: Variant in chunks:
		if c is PhysicsBody3D and is_instance_valid(c):
			add_collision_exception_with(c as PhysicsBody3D)
			bodies.append(c)
	if not bodies.is_empty():
		_ghosts.append([BREAK_GHOST, bodies])

func _tick_ghosts(delta: float) -> void:
	var keep: Array = []
	for g: Array in _ghosts:
		g[0] = float(g[0]) - delta
		if float(g[0]) > 0.0:
			keep.append(g)
			continue
		for b: Variant in g[1]:
			if is_instance_valid(b):
				remove_collision_exception_with(b as PhysicsBody3D)
	_ghosts = keep

## First landing: the structure blast where it came down, and a floor mark if
## what is right under it is floor.
func _land(v: Vector3) -> void:
	has_landed = true
	var e := 0.5 * mass * v.length_squared()
	var b := get_bounds()
	var bottom := Vector3(b.get_center().x, b.position.y, b.get_center().z)
	var on_floor := false
	var floor_pt := bottom
	var self_rid: Array[RID] = [get_rid()]
	var q := PhysicsRayQueryParameters3D.create(bottom + Vector3.UP * 0.1, bottom + Vector3.DOWN * FLOOR_CONTACT,
		Layers.WORLD | Layers.DESTRUCTIBLE | Layers.DEBRIS | Layers.DEBRIS_SMALL | Layers.RAGDOLL | Layers.DEAD_BODY,
		self_rid)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty() and hit["collider"] is StaticBody3D and WorldTags.breakable_of(hit["collider"]) == null \
			and (hit["normal"] as Vector3).y > 0.7:
		on_floor = true
		floor_pt = hit["position"]
	var wd := get_node_or_null(^"/root/WorldDamage")
	if wd != null:
		if on_floor:
			WorldDamage.damage_floor(floor_pt, e, &"concrete")
		WorldDamage.blast(bottom, float(Tuning.BLAST[&"structure"]), e, &"structure", self)
	landed_at.emit(bottom, e, on_floor)

## A falling piece of structure hitting `victim` (Round 6): preset tier, kind
## &"debris", no attacker, Tuning.FALLING_DAMAGE, unblockable, on the head.
static func build_hit(victim: Fighter, tier: int, v: Vector3, pos: Vector3, energy: float) -> HitInfo:
	var info := HitInfo.new()
	info.attacker = null
	info.victim = victim
	info.kind = &"debris"
	info.move_id = &"falling_debris"
	info.tier = tier
	info.reaction = HitInfo.reaction_for_tier(tier)
	info.damage = float(Tuning.FALLING_DAMAGE.get(HitInfo.tier_name(tier), 0.0))
	info.hit_bone = Bones.HEAD
	info.zone = BodyZones.of_bone(Bones.HEAD)
	info.level = HitInfo.Level.HIGH
	info.hit_position = pos
	var flat := Vector3(v.x, 0.0, v.z)
	if flat.length() < 0.2:
		flat = victim.get_ground_position() - Vector3(pos.x, victim.get_ground_position().y, pos.z)
	info.hit_direction = flat.normalized() if flat.length() > 0.01 else Vector3.BACK
	info.launch_velocity = info.hit_direction * KNOCKDOWN_PUSH if tier == HitInfo.Tier.KNOCKDOWN else Vector3.ZERO
	info.energy = energy
	info.unblockable = true
	info.hitstop = 0.0
	return info
