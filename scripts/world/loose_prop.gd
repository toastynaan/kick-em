class_name LooseProp
extends RigidBody3D
## Loose office and storage props (chairs, filing cabinets, drums): dynamic
## bodies that flying bodies knock over and walking fighters push, and wall-strike
## targets (round 3): each strike shoves the prop and chips it; at strike_hp it
## breaks into its mesh pieces (timed debris) pushed along the strike.
## Layers.DEBRIS (bodies, debris) plus Layers.DESTRUCTIBLE (strike contact).
## OWNER: agent D (world).

## Strike power that breaks it (chair ~1 kick, drum ~3, cabinet ~4).
@export var strike_hp := 120.0
@export var surface: StringName = &"wood"
var damage := 0.0

## N s of impulse per point of strike power (a kick shoves an 8 kg chair ~0.4 m/s).
const IMPULSE_PER_POWER := 0.05
const PIECE_PUSH := 2.5

func _ready() -> void:
	collision_layer = Layers.DEBRIS | Layers.DESTRUCTIBLE
	collision_mask = Layers.MASK_DEBRIS
	set_meta(&"surface", surface)
	add_to_group(&"props")
	can_sleep = true

func receive_strike(attacker: Node3D, hit_pos: Vector3, direction: Vector3, power: float) -> StringName:
	var d := direction.normalized() if direction.length() > 0.01 else Vector3.FORWARD
	var n := -Vector3(d.x, 0.0, d.z).normalized() if Vector2(d.x, d.z).length() > 0.01 else Vector3.UP
	damage += maxf(power, 0.0)
	var result := &"crack" if damage >= strike_hp * 0.34 else &"chip"
	StrikeMarks.chips(self, hit_pos, n, d, power, surface)
	if damage >= strike_hp:
		result = &"break"
		_shatter(d)
	else:
		apply_impulse(d * power * IMPULSE_PER_POWER, hit_pos - global_position)
	GameEvents.wall_struck.emit(attacker, self, hit_pos, n, power, result, surface)
	return result

## Every box / cylinder mesh child flies off as its own piece (timed debris).
func _shatter(d: Vector3) -> void:
	var parent := get_parent() if get_parent() else self
	for c in get_children():
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var shape: Shape3D = null
		if mi.mesh is BoxMesh:
			var bs := BoxShape3D.new()
			bs.size = (mi.mesh as BoxMesh).size * 0.95
			shape = bs
		elif mi.mesh is CylinderMesh:
			var cy := CylinderShape3D.new()
			cy.radius = (mi.mesh as CylinderMesh).bottom_radius * 0.95
			cy.height = (mi.mesh as CylinderMesh).height * 0.95
			shape = cy
		if shape == null:
			continue
		var b := RigidBody3D.new()
		b.name = "PropPiece"
		var pm := MeshInstance3D.new()
		pm.mesh = mi.mesh
		pm.material_override = mi.material_override
		b.add_child(pm)
		var cs := CollisionShape3D.new()
		cs.shape = shape
		b.add_child(cs)
		b.mass = maxf(mass / maxf(float(get_child_count()) * 0.5, 1.0), 0.5)
		b.set_meta(&"surface", surface)
		var xf := mi.global_transform
		var v := linear_velocity + d * PIECE_PUSH + Vector3(randf_range(-0.6, 0.6), randf_range(0.3, 1.5), randf_range(-0.6, 0.6))
		b.linear_velocity = v
		b.angular_velocity = Vector3(randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4))
		parent.add_child(b)
		b.global_transform = xf
		b.linear_velocity = v
		DebrisManager.register(b, false, DebrisManager.MEDIUM_LIFE)
	queue_free()
