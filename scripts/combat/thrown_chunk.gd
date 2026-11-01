class_name ThrownChunk
extends RigidBody3D
## A box of rubble the Thrower throws when it has no real debris in hand
## (e_throw_debris). The flight logic lives in ProjectileProbe, so any
## RigidBody3D can be thrown or kicked the same way: see launch_body().
## OWNER: agent B (fighter & combat).

const CHUNK_MASS := 6.0
const SIZE := Vector3(0.38, 0.28, 0.32)

var thrower: Fighter
var damage := 50.0

func setup(p_thrower: Fighter, p_damage: float) -> void:
	thrower = p_thrower
	damage = p_damage

func _init() -> void:
	name = "ThrownChunk"
	mass = CHUNK_MASS
	collision_layer = Layers.DEBRIS
	collision_mask = Layers.MASK_DEBRIS
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = SIZE
	cs.shape = box
	add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = SIZE
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.53, 0.5)
	mat.roughness = 0.95
	mi.material_override = mat
	add_child(mi)

## Ballistic launch toward `target` at roughly `speed` m/s.
func launch_at(target: Vector3, speed: float) -> void:
	launch_body(self, ballistic_velocity(global_position, target, speed, gravity_scale), thrower, damage)

## Turn any RigidBody3D (already in the tree) into a projectile: it flies at
## `velocity`, hits the hurtboxes of `thrower`'s opponents as a HitInfo of kind
## &"projectile", then is handed back to DebrisManager. damage < 0 uses the
## thrower's e_throw_debris damage (x its config "damage_mult").
static func launch_body(body: RigidBody3D, velocity: Vector3, p_thrower: Fighter, p_damage := -1.0,
		move_id: StringName = &"e_throw_debris") -> ProjectileProbe:
	if body == null or not is_instance_valid(body) or not body.is_inside_tree():
		return null
	for c in body.get_children():
		if c is ProjectileProbe:
			(c as ProjectileProbe).live = false
			c.queue_free()
	var dmg := p_damage
	if dmg < 0.0:
		dmg = Tuning.DMG_ENEMY.get(&"e_throw_debris", 50.0)
		if p_thrower != null and is_instance_valid(p_thrower):
			dmg *= float(p_thrower.config.get("damage_mult", 1.0))
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	body.freeze = false
	body.sleeping = false
	body.collision_layer = Layers.DEBRIS
	# No capsules while live: the probe must reach the hurtboxes before the
	# capsule bounces the body away.
	body.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE | Layers.RAGDOLL | Layers.DEBRIS
	if p_thrower != null and is_instance_valid(p_thrower):
		body.add_collision_exception_with(p_thrower)
		if p_thrower.rig:
			for pb in p_thrower.rig.get_physical_bones():
				body.add_collision_exception_with(pb)
	body.linear_velocity = velocity.limit_length(ProjectileProbe.MAX_SPEED)
	body.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6))
	var probe := ProjectileProbe.new()
	probe.thrower = p_thrower
	probe.team = p_thrower.team if p_thrower != null and is_instance_valid(p_thrower) else -1
	probe.damage = dmg
	probe.move_id = move_id
	body.add_child(probe)
	return probe

## Launch velocity that lands on `to` from `from` at about `speed` m/s.
static func ballistic_velocity(from: Vector3, to: Vector3, speed: float, g_scale := 1.0) -> Vector3:
	var g: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) * g_scale
	var d := to - from
	var flat := Vector3(d.x, 0.0, d.z)
	var t := clampf(flat.length() / maxf(speed, 1.0), 0.2, 1.6)
	return flat / t + Vector3.UP * (d.y / t + 0.5 * g * t)
