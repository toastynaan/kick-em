class_name ThrowableProp
extends RigidBody3D
## Round 5 throwable props (Feel Reference: Props): bricks, bottles, chair legs,
## small crates, a stick enemy's dropped stick, and loose limbs. Picked up with
## Grab when no body is in reach, thrown with Heavy. A thrown prop is a
## projectile: a hit on a fighter is a stagger and Tuning.PROP_DAMAGE (a brick to
## the head knocks down); it breaks on impact with a burst (GameEvents.prop_broken).
## Arena props respawn at their start points after Tuning.PROP_RESPAWN s.
## OWNER: agent D (world). CONTRACT STUB: keep every public signature.
## G (Carry) picks up and throws; A spawns loose limbs as kind &"limb"; C drops &"stick".
##
## Build: _ready() gives the prop the mass, collision shape and mesh of its kind
## unless the creator already added a CollisionShape3D / mesh (A's limbs, any
## custom prop): then those are kept, and so are the creator's mass and layers.
## Layers.DEBRIS: bones and debris hit it, walking capsules do not. Group
## "throwable_props" (Carry looks there).
## Flight (after throw()): each tick a sphere sweep ahead of the prop finds
## fighters' hurtboxes (Layers.HURTBOX; never the thrower), so the hit lands
## on the bone it reaches (the head for a brick knockdown). While flying it
## passes through capsules (the hurtbox decides). A hard contact with anything
## else at Tuning.PROJECTILE_MIN_SPEED or more is an impact: walls and props
## with receive_strike() take a small strike, and the prop breaks.
## Breaking: GameEvents.prop_broken (F draws the dust or glass), pieces through
## DebrisManager for bricks, crates, chair legs and sticks (they stay); then the
## prop is gone and, if it is an arena prop (`respawns`), a new one appears at
## its start point Tuning.PROP_RESPAWN s later. Limbs never break: a thrown
## limb hits (stagger) and drops, and stays (A keeps at most LOOSE_LIMB_MAX).

## &"brick" | &"bottle" | &"chair_leg" | &"crate_small" | &"stick" | &"limb"
var kind: StringName = &"brick"
var holder: Node3D = null

## Arena props come back at `home` (global) Tuning.PROP_RESPAWN s after they
## break. Dropped sticks and loose limbs do not.
var respawns := false
var home := Transform3D()

## Per kind: box / cylinder size (m), mass (kg), surface, wall strike power,
## break pieces. Sizes are a little over real life so they read in play. Strike
## powers stay under a drywall cell's Tuning.STRIKE_CELL_HP: a thrown prop
## chips and cracks a wall but never opens a hole (a hole is a headline break).
const KINDS := {
	&"brick": {"box": Vector3(0.24, 0.08, 0.12), "mass": 2.5, "surface": &"brick", "strike": 20.0, "pieces": 4,
		"color": Color(0.6, 0.27, 0.18)},
	&"bottle": {"cyl": Vector2(0.04, 0.3), "mass": 0.6, "surface": &"glass", "strike": 5.0, "pieces": 0,
		"color": Color(0.18, 0.42, 0.22, 0.85)},
	&"chair_leg": {"box": Vector3(0.05, 0.5, 0.05), "mass": 0.8, "surface": &"wood", "strike": 15.0, "pieces": 2,
		"color": Color(0.5, 0.34, 0.2)},
	&"crate_small": {"box": Vector3(0.4, 0.34, 0.34), "mass": 4.0, "surface": &"wood", "strike": 20.0, "pieces": 6,
		"color": Color(0.64, 0.47, 0.28)},
	&"stick": {"cyl": Vector2(0.026, 0.95), "mass": 0.7, "surface": &"wood", "strike": 15.0, "pieces": 2,
		"color": Color(0.42, 0.27, 0.13)},
	&"limb": {"mass": 4.0, "surface": &"body", "strike": 10.0, "pieces": 0},
}
## Below this speed (m/s) a flying prop is just a loose prop again; at or above
## it a hard contact breaks it (Tuning.PROJECTILE_MIN_SPEED, as for bodies).
## A sudden velocity change of at least this much (m/s, gravity removed) is a hard contact.
const IMPACT_DV := 2.5
## s the thrower's own body and capsule are ignored after the throw.
const THROWER_GRACE := 0.3
## Sweep ahead of the prop this many ticks of travel.
const SWEEP_TICKS := 1.5
## Spin given on a throw (rad/s), across the throw direction.
const THROW_SPIN := 9.0
## Knockdown push (brick to the head) along the throw, m/s.
const KNOCKDOWN_PUSH := 1.5

var _thrower: Node3D = null
var _flying := false
var _fly_t := 0.0
var _last_v := Vector3.ZERO
var _broken := false
var _layer := Layers.DEBRIS
var _mask := Layers.MASK_DEBRIS
var _ccd := false             ## the creator's continuous_cd (A sets it on limbs)
var _radius := 0.1
var _query := PhysicsShapeQueryParameters3D.new()
var _sphere := SphereShape3D.new()
var _excepted: Array = []

func _ready() -> void:
	add_to_group(&"throwable_props")
	var spec: Dictionary = KINDS.get(kind, KINDS[&"brick"])
	if not _has_own_shape():
		_build_default(spec)
		mass = float(spec["mass"])
		collision_layer = Layers.DEBRIS
		collision_mask = Layers.MASK_DEBRIS
	if not has_meta(&"surface"):
		set_meta(&"surface", spec["surface"])
	_layer = collision_layer if collision_layer != 0 else Layers.DEBRIS
	_mask = collision_mask if collision_mask != 0 else Layers.MASK_DEBRIS
	_ccd = continuous_cd
	_radius = _bounding_radius()
	can_sleep = true
	_sphere.radius = clampf(_radius * 0.6, 0.06, 0.2)
	_query.shape = _sphere
	_query.collide_with_areas = true
	_query.collide_with_bodies = false
	_query.collision_mask = Layers.HURTBOX
	set_physics_process(false)

func can_pick_up() -> bool:
	return holder == null and not _broken and not is_queued_for_deletion()

## Taken into a hand: the holder places it each tick (freeze, no collisions with the holder).
func pick_up(p_holder: Node3D) -> void:
	if _broken:
		return
	holder = p_holder
	_end_flight()
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	# In the hand it touches nothing: the holder moves it every tick.
	collision_layer = 0
	collision_mask = 0
	if DebrisManager.has_method(&"release"):
		DebrisManager.release(self)
	DebrisManager.release_young(self)

## Let go without throwing.
func drop(velocity := Vector3.ZERO) -> void:
	holder = null
	_end_flight()
	_restore_collision()
	freeze = false
	linear_velocity = velocity
	sleeping = false

## Thrown by `thrower`: becomes a projectile until it hits something or slows down.
func throw(velocity: Vector3, p_thrower: Node3D) -> void:
	holder = null
	DebrisManager.release_young(self)
	_restore_collision()
	freeze = false
	sleeping = false
	linear_velocity = velocity
	var across := velocity.cross(Vector3.UP)
	angular_velocity = (across.normalized() if across.length() > 0.01 else Vector3.RIGHT) * THROW_SPIN
	_thrower = p_thrower
	_flying = velocity.length() >= Tuning.PROJECTILE_MIN_SPEED
	_fly_t = 0.0
	_last_v = velocity
	if _flying:
		# The hurtbox sweep decides fighter hits: pass through capsules meanwhile.
		collision_mask = _mask & ~Layers.CAPSULE
		continuous_cd = true
		contact_monitor = true
		max_contacts_reported = 4
		_except_thrower(true)
		set_physics_process(true)

func is_held() -> bool:
	return holder != null

## True while thrown and still fast enough to hit (tests, AI).
func is_flying() -> bool:
	return _flying

func is_broken() -> bool:
	return _broken

# --- Flight ------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not _flying or _broken or delta <= 0.0:
		return
	_fly_t += delta
	if _fly_t > THROWER_GRACE and not _excepted.is_empty():
		_except_thrower(false)
	var v := linear_velocity
	# 1. A hard contact last step (wall, floor, prop, a body's bone).
	var g: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) * Vector3.DOWN
	var dv := v - _last_v - g * delta
	if dv.length() >= IMPACT_DV and _last_v.length() >= Tuning.PROJECTILE_MIN_SPEED:
		var col: Object = null
		for b in get_colliding_bodies():
			col = b
			break
		_impact(col, _last_v)
		return
	if v.length() < Tuning.PROJECTILE_MIN_SPEED:
		_end_flight()
		return
	# 2. Fighters ahead: hurtboxes along this tick's travel (plus a margin).
	var step := maxf(_sphere.radius, 0.05)
	var travel := v * delta * SWEEP_TICKS
	var n := clampi(int(ceil(travel.length() / step)), 1, 8)
	var space := get_world_3d().direct_space_state
	for i in n + 1:
		_query.transform = Transform3D(Basis(), global_position + travel * (float(i) / float(n)))
		for hit: Dictionary in space.intersect_shape(_query, 8):
			var hb := hit.get("collider") as Area3D
			if hb == null:
				continue
			var f := hb.get_meta(&"fighter", null) as Fighter
			if f == null or f == _thrower or not is_instance_valid(f) or f.is_dead():
				continue
			if _hit_fighter(f, StringName(hb.get_meta(&"bone", &"Chest")), _query.transform.origin, v):
				return
	_last_v = v

## A thrown prop reaches `victim`'s hurtbox on `bone`: a preset-tier hit
## (stagger, a brick to the head knocks down), Tuning.PROP_DAMAGE, through the
## normal hit pipeline. true when it landed (or was blocked): the prop breaks.
func _hit_fighter(victim: Fighter, bone: StringName, pos: Vector3, v: Vector3) -> bool:
	var info := build_hit(_thrower as Fighter, victim, kind, bone, pos, v, mass)
	var result := victim.take_hit(info)
	if result == HitInfo.Result.DODGED or result == HitInfo.Result.IGNORED:
		return false
	if result == HitInfo.Result.HIT and is_instance_valid(victim):
		# Contact frame on the victim only (the thrower is meters away).
		if victim.has_method(&"set_hitstop_jitter"):
			victim.set_hitstop_jitter()
		TimeDirector.hitstop([victim], Power.hitstop_for(info.tier))
	_break(pos, -v.normalized())
	return true

## The HitInfo a thrown prop of `p_kind` deals (Feel Reference: Props): kind
## &"projectile", tier STAGGER, Tuning.PROP_DAMAGE; a brick on the head bone is
## a KNOCKDOWN. No hitstop of its own (the thrower is not frozen).
static func build_hit(attacker: Fighter, victim: Fighter, p_kind: StringName, bone: StringName, pos: Vector3,
		v: Vector3, prop_mass: float) -> HitInfo:
	var info := HitInfo.new()
	info.attacker = attacker
	info.victim = victim
	info.kind = &"projectile"
	info.move_id = StringName("prop_" + String(p_kind))
	info.tier = HitInfo.Tier.KNOCKDOWN if p_kind == &"brick" and bone == Bones.HEAD else HitInfo.Tier.STAGGER
	info.reaction = HitInfo.reaction_for_tier(info.tier)
	info.damage = Tuning.PROP_DAMAGE
	info.hit_bone = bone
	info.zone = BodyZones.of_bone(bone)
	info.level = HitInfo.Level.HIGH if bone == Bones.HEAD else HitInfo.Level.MID
	info.hit_position = pos
	var flat := Vector3(v.x, 0.0, v.z)
	info.hit_direction = flat.normalized() if flat.length() > 0.01 else Vector3.FORWARD
	info.launch_velocity = info.hit_direction * KNOCKDOWN_PUSH if info.tier == HitInfo.Tier.KNOCKDOWN else Vector3.ZERO
	info.energy = 0.5 * prop_mass * v.length_squared()
	info.hitstop = 0.0
	info.unblockable = false
	return info

## A hard contact with something other than a fighter's hurtbox.
func _impact(col: Object, v: Vector3) -> void:
	var pos := global_position
	var dir := v.normalized() if v.length() > 0.01 else Vector3.DOWN
	# A flying or downed body's bone: hit its fighter there.
	if col is PhysicalBone3D:
		var f := _fighter_of(col as Node)
		if f != null and f != _thrower and not f.is_dead():
			if _hit_fighter(f, (col as PhysicalBone3D).bone_name, pos, v):
				return
	# Walls, pillars and props take a small strike (chips, a drywall hole).
	var target := _strike_target(col as Node)
	if target != null:
		var spec: Dictionary = KINDS.get(kind, KINDS[&"brick"])
		target.call(&"receive_strike", _thrower, pos, dir, float(spec["strike"]))
	_break(pos, -dir)

static func _fighter_of(n: Node) -> Fighter:
	var p := n
	for i in 6:
		if p == null:
			return null
		if p is Fighter:
			return p
		p = p.get_parent()
	return null

static func _strike_target(n: Node) -> Node:
	var p := n
	for i in 4:
		if p == null or p is Fighter:
			return null
		if p.has_method(&"receive_strike"):
			return p
		p = p.get_parent()
	return null

func _end_flight() -> void:
	_flying = false
	_thrower_cleanup()
	set_physics_process(false)
	contact_monitor = false
	if holder == null and not _broken:
		collision_mask = _mask
		continuous_cd = _ccd

func _restore_collision() -> void:
	collision_layer = _layer
	collision_mask = _mask

func _except_thrower(on: bool) -> void:
	if on:
		_excepted.clear()
		var t := _thrower as Fighter
		if t == null or not is_instance_valid(t):
			return
		_excepted.append(t)
		if t.rig:
			for b in t.rig.get_physical_bones():
				if is_instance_valid(b):
					_excepted.append(b)
		for b: Variant in _excepted:
			add_collision_exception_with(b as PhysicsBody3D)
	else:
		_thrower_cleanup()

func _thrower_cleanup() -> void:
	for b: Variant in _excepted:
		if is_instance_valid(b):
			remove_collision_exception_with(b as PhysicsBody3D)
	_excepted.clear()

# --- Breaking -----------------------------------------------------------------------

## The prop bursts at `pos` (`normal` back toward where it came from): event,
## pieces (they stay), respawn for arena props, gone. A limb only drops.
func _break(pos: Vector3, normal: Vector3) -> void:
	if kind == &"limb":
		_end_flight()
		return
	if _broken:
		return
	_broken = true
	_flying = false
	_thrower_cleanup()
	set_physics_process(false)
	var v := linear_velocity if linear_velocity.length() > 0.5 else _last_v
	_spawn_pieces(v, normal)
	DebrisManager.note_prop_broken(self)
	GameEvents.prop_broken.emit(self, pos, kind)
	if respawns and get_parent() != null:
		_schedule_respawn(get_parent(), kind, home)
	collision_layer = 0
	collision_mask = 0
	visible = false
	queue_free()

## Breaks it now (scripted, tests). Same as an impact (a limb only drops).
func shatter() -> void:
	_break(global_position, Vector3.UP)

func _spawn_pieces(v: Vector3, normal: Vector3) -> void:
	var spec: Dictionary = KINDS.get(kind, KINDS[&"brick"])
	var count := int(spec.get("pieces", 0))
	if count <= 0 or get_parent() == null:
		return
	var parent := get_parent()
	var mat := _material(spec)
	var size: Vector3
	if spec.has("box"):
		size = spec["box"]
	else:
		var cyl: Vector2 = spec["cyl"]
		size = Vector3(cyl.x * 2.0, cyl.y, cyl.x * 2.0)
	var long_axis := 1 if size.y >= size.x and size.y >= size.z else (0 if size.x >= size.z else 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = get_instance_id()
	for i in count:
		# Bricks crumble into chunks, crates into planks, sticks snap in two.
		var piece := size
		var offset := Vector3.ZERO
		if kind == &"crate_small":
			piece = Vector3(size.x, size.y / 3.0, 0.03) if i % 2 == 0 else Vector3(0.03, size.y / 3.0, size.z)
			offset = Vector3(rng.randf_range(-0.12, 0.12), size.y * (float(i % 3) / 3.0 - 0.33), rng.randf_range(-0.12, 0.12))
		else:
			piece[long_axis] = size[long_axis] / float(count)
			offset[long_axis] = (float(i) + 0.5) / float(count) * size[long_axis] - size[long_axis] * 0.5
		var b := RigidBody3D.new()
		b.name = "PropPiece"
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = piece
		mi.mesh = bm
		mi.material_override = mat
		mi.layers = Layers.VIS_WORLD
		b.add_child(mi)
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = piece * 0.9
		cs.shape = bs
		b.add_child(cs)
		b.mass = maxf(mass / float(count), 0.1)
		b.set_meta(&"surface", spec["surface"])
		var xf := global_transform * Transform3D(Basis(), offset)
		var pv := v * rng.randf_range(0.15, 0.35) + normal * rng.randf_range(0.5, 1.8) \
			+ Vector3(rng.randf_range(-1.2, 1.2), rng.randf_range(0.6, 2.0), rng.randf_range(-1.2, 1.2))
		b.linear_velocity = pv
		b.angular_velocity = Vector3(rng.randf_range(-8, 8), rng.randf_range(-8, 8), rng.randf_range(-8, 8))
		parent.add_child(b)
		b.global_transform = xf
		b.linear_velocity = pv
		DebrisManager.register(b, piece.length() < 0.2)
		DebrisManager.hold_young(b, maxf(v.length(), pv.length()))

## Respawn a fresh arena prop at `at` after Tuning.PROP_RESPAWN s (game time),
## if its parent is still in the arena then.
static func _schedule_respawn(parent: Node, p_kind: StringName, at: Transform3D) -> void:
	if not parent.is_inside_tree():
		return
	parent.get_tree().create_timer(Tuning.PROP_RESPAWN, false, true).timeout.connect(func() -> void:
		if not is_instance_valid(parent) or not parent.is_inside_tree() or parent.is_queued_for_deletion():
			return
		spawn(parent, p_kind, at, true))

## A new prop of `p_kind` at `at` (global) under `parent`. respawn: it comes
## back at `at` after breaking.
static func spawn(parent: Node, p_kind: StringName, at: Transform3D, respawn := false) -> ThrowableProp:
	var p := ThrowableProp.new()
	p.kind = p_kind
	p.name = "Prop_" + String(p_kind)
	p.respawns = respawn
	p.home = at
	parent.add_child(p)
	p.global_transform = at
	p.reset_physics_interpolation()
	return p

# --- Build -------------------------------------------------------------------------

func _has_own_shape() -> bool:
	for c in get_children():
		if c is CollisionShape3D or c is CollisionPolygon3D:
			return true
	return false

func _build_default(spec: Dictionary) -> void:
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	if spec.has("box"):
		var size: Vector3 = spec["box"]
		var bs := BoxShape3D.new()
		bs.size = size
		cs.shape = bs
		var bm := BoxMesh.new()
		bm.size = size
		mi.mesh = bm
	elif spec.has("cyl"):
		var cyl: Vector2 = spec["cyl"]
		var shape := CylinderShape3D.new()
		shape.radius = maxf(cyl.x * 1.2, 0.03)
		shape.height = cyl.y
		cs.shape = shape
		var m := CylinderMesh.new()
		m.bottom_radius = cyl.x
		m.top_radius = cyl.x * (0.45 if kind == &"bottle" else 0.85)
		m.height = cyl.y
		m.radial_segments = 10
		m.rings = 1
		mi.mesh = m
	else:
		return
	mi.material_override = _material(spec)
	mi.layers = Layers.VIS_WORLD
	add_child(cs)
	add_child(mi)

func _material(spec: Dictionary) -> Material:
	if kind == &"crate_small":
		return WorldMaterials.panel(&"wood", &"planks")
	var c: Color = spec.get("color", Color(0.6, 0.6, 0.6))
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.15 if kind == &"bottle" else 0.85
	if c.a < 0.99:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.metallic_specular = 0.9
	return m

func _bounding_radius() -> float:
	var r := 0.05
	for c in get_children():
		var cs := c as CollisionShape3D
		if cs == null or cs.shape == null:
			continue
		var s := cs.shape
		var e := 0.1
		if s is BoxShape3D:
			e = (s as BoxShape3D).size.length() * 0.5
		elif s is CylinderShape3D:
			e = Vector2((s as CylinderShape3D).radius, (s as CylinderShape3D).height * 0.5).length()
		elif s is CapsuleShape3D:
			e = (s as CapsuleShape3D).height * 0.5
		elif s is SphereShape3D:
			e = (s as SphereShape3D).radius
		r = maxf(r, cs.position.length() + e)
	return r
