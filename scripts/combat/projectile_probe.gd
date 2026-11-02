class_name ProjectileProbe
extends Node
## Child of any RigidBody3D in flight (thrown or kicked debris). Every physics
## tick it checks the opponents' hurtboxes around the body; on contact it
## delivers a HitInfo of kind &"projectile" (blockable, perfect-dodgeable).
## When it hits, lands or times out, the body goes back to DebrisManager and
## the probe frees itself. Created by ThrownChunk.launch_body().
## OWNER: agent B (fighter & combat).

const LIFETIME := 3.0        ## s of flight before it gives up
const CONTACT_GRACE := 0.15  ## s after launch during which contacts do not end the flight
const MIN_SPEED := 3.0       ## m/s: slower than this after the grace it is just debris
const MAX_SPEED := 20.0      ## m/s cap while live (no solver spikes on release)
const MAX_SPIN := 25.0       ## rad/s cap while live

var body: RigidBody3D
var thrower: Fighter
var team := -1
var damage := 50.0
var move_id: StringName = &"e_throw_debris"
var stagger_strength := 0.6
var live := true

var _age := 0.0
var _ignored := {}
var _q := PhysicsShapeQueryParameters3D.new()
var _shape := SphereShape3D.new()

func _init() -> void:
	name = "ProjectileProbe"
	process_physics_priority = -100  # clamp before anything reads the body this tick

func _ready() -> void:
	body = get_parent() as RigidBody3D
	if body == null:
		queue_free()
		return
	_shape.radius = _query_radius(body)
	_q.shape = _shape
	_q.collide_with_areas = true
	_q.collide_with_bodies = false
	_q.collision_mask = Layers.HURTBOX
	body.contact_monitor = true
	body.max_contacts_reported = maxi(body.max_contacts_reported, 4)
	body.continuous_cd = true
	if not body.body_entered.is_connected(_on_body_entered):
		body.body_entered.connect(_on_body_entered)

static func _query_radius(b: RigidBody3D) -> float:
	return clampf(body_radius(b) * 0.8 + 0.12, 0.3, 0.75)

## Bounding radius of a body's collision shapes around its origin.
static func body_radius(b: RigidBody3D) -> float:
	var r := 0.0
	for c in b.get_children():
		var cs := c as CollisionShape3D
		if cs == null or cs.shape == null:
			continue
		if cs.shape is BoxShape3D:
			r = maxf(r, (cs.shape as BoxShape3D).size.length() * 0.5)
		elif cs.shape is SphereShape3D:
			r = maxf(r, (cs.shape as SphereShape3D).radius)
		elif cs.shape is CapsuleShape3D:
			r = maxf(r, (cs.shape as CapsuleShape3D).height * 0.5)
		elif cs.shape is ConvexPolygonShape3D:
			for p in (cs.shape as ConvexPolygonShape3D).points:
				r = maxf(r, (p + cs.position).length())
	return maxf(r, 0.1)

func _physics_process(delta: float) -> void:
	if not live or body == null or not is_instance_valid(body):
		return
	_age += delta
	var v := body.linear_velocity
	if v.length() > MAX_SPEED:
		body.linear_velocity = v.normalized() * MAX_SPEED
	var w := body.angular_velocity
	if w.length() > MAX_SPIN:
		body.angular_velocity = w.normalized() * MAX_SPIN
	if _age > LIFETIME or (_age > CONTACT_GRACE and body.linear_velocity.length() < MIN_SPEED):
		finish()
		return
	_q.transform = Transform3D(Basis(), body.global_position)
	for r in body.get_world_3d().direct_space_state.intersect_shape(_q, 16):
		var area := r.get("collider") as Area3D
		if area == null or not area.has_meta(&"fighter"):
			continue
		var f := area.get_meta(&"fighter") as Fighter
		if f == null or not is_instance_valid(f) or f.team == team or f.is_dead():
			continue
		if _ignored.has(f.get_instance_id()):
			continue
		if _hit(f, area.get_meta(&"bone")):
			return

func _hit(f: Fighter, bone: StringName) -> bool:
	var v := body.linear_velocity
	var info := HitInfo.new()
	info.attacker = thrower if is_instance_valid(thrower) else null
	info.victim = f
	info.move_id = move_id
	info.kind = &"projectile"
	info.damage = damage
	# Round 5: a thrown prop is a stagger (Feel Reference: Props), its tier preset.
	info.tier = HitInfo.Tier.STAGGER
	info.reaction = HitInfo.reaction_for_tier(info.tier)
	var d := Vector3(v.x, 0.0, v.z)
	info.hit_direction = d.normalized() if d.length() > 0.1 else Vector3.FORWARD
	info.hit_position = body.global_position
	info.hit_bone = bone
	info.hitstop = Power.hitstop_for(info.tier)
	info.energy = 0.5 * body.mass * v.length_squared()
	info.set_meta(&"strength", stagger_strength)
	var res := f.take_hit(info)
	if res == HitInfo.Result.DODGED or res == HitInfo.Result.IGNORED:
		_ignored[f.get_instance_id()] = true  # fly on through the vanish
		return false
	body.linear_velocity = -v * 0.2 + Vector3.UP * 1.5
	finish()
	return true

func _on_body_entered(other: Node) -> void:
	if not live or _age < CONTACT_GRACE:
		return
	if thrower != null and is_instance_valid(thrower) and (other == thrower or thrower.is_ancestor_of(other)):
		return
	finish()

## End the flight: the body becomes ordinary debris again.
func finish() -> void:
	if not live:
		return
	live = false
	if body != null and is_instance_valid(body):
		if body.body_entered.is_connected(_on_body_entered):
			body.body_entered.disconnect(_on_body_entered)
		body.collision_mask = Layers.MASK_DEBRIS
		DebrisManager.register(body, false)  # it fades and frees the body
	queue_free()
