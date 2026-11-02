class_name LooseProp
extends RigidBody3D
## Loose office and storage props (chairs, filing cabinets, drums): dynamic
## bodies that flying bodies knock over and walking fighters push, and wall-strike
## targets (round 3): each strike shoves the prop and chips it; at strike_hp it
## breaks into its mesh pieces (debris that stays for the round) pushed along the strike.
## Layers.DEBRIS (bodies, debris) plus Layers.DESTRUCTIBLE (strike contact).
## Round 6 (agent K): also a breakable (group "breakables"): a flying body
## breaks it by E = 1/2 M v^2 at its break energy (a chair at Tuning.FURNITURE
## chair, a drum or cabinet at KIND_BREAK), cracks it from Tuning.CRACK_FRACTION
## (its break energy drops by half the hit's energy; the body hits it
## physically and knocks it about); a blast never breaks it (blasts break only
## glass and cardboard): from its crack energy a blast cracks it (break energy
## down by half the blast, at most to BLAST_CRACK_FLOOR of the original) and
## hops the light ones. Impact breaks emit GameEvents.furniture_broken; strike
## breaks keep emitting wall_struck "break" as before.
## OWNER: agent K (clutter; moved from D in Round 6).

## Strike power that breaks it (chair ~1 kick, drum ~3, cabinet ~4).
@export var strike_hp := 120.0
@export var surface: StringName = &"wood"
## &"chair", &"drum" or &"cabinet"; inferred from mass and surface when empty.
@export var kind: StringName = &""
var damage := 0.0
var absorption := 0.15
var break_energy := 1000.0
var original_break_energy := 1000.0
var is_broken := false
## Pieces of the last break (ImpactResolver lets the breaking body pass them).
var last_chunks: Array[RigidBody3D] = []
## The breakable's box size (from its collision shapes); see get_box_transform().
var size: Vector3:
	get = _get_size

## N s of impulse per point of strike power (a kick shoves an 8 kg chair ~0.4 m/s).
const IMPULSE_PER_POWER := 0.05
const PIECE_PUSH := 2.5
## Body-impact break energy (J) and absorption of the office kinds besides the
## chair (which uses Tuning.FURNITURE[&"chair"]). Candidates for Tuning.
const KIND_BREAK := {&"drum": 1200.0, &"cabinet": 2000.0}
const KIND_ABSORB := {&"drum": 0.2, &"cabinet": 0.3}
## A crack shoves it along the body: m/s per (energy / break energy).
const CRACK_SHOVE := 2.5
## Blasts hop props up to this mass (kg) at up to BLAST_HOP m/s (WorldDamage's hop).
const BLAST_HOP_MASS := 30.0
const BLAST_HOP := 2.8
## A blast cracks it at most down to this share of its original break energy.
const BLAST_CRACK_FLOOR := 0.2
## Share of the breaking body's exit speed its pieces leave with.
const IMPACT_PIECE_SHARE := 0.8

var _box_center := Vector3.ZERO
var _box_size := Vector3.ZERO

func _ready() -> void:
	collision_layer = Layers.DEBRIS | Layers.DESTRUCTIBLE
	collision_mask = Layers.MASK_DEBRIS
	set_meta(&"surface", surface)
	add_to_group(&"props")
	add_to_group(&"breakables")
	can_sleep = true
	if kind == &"":
		if surface == &"wood" and mass < 15.0:
			kind = &"chair"
		elif mass < 40.0:
			kind = &"drum"
		else:
			kind = &"cabinet"
	if Tuning.FURNITURE.has(kind):
		break_energy = float(Tuning.FURNITURE[kind]["break"])
		absorption = float(Tuning.FURNITURE[kind]["absorb"])
	else:
		break_energy = float(KIND_BREAK.get(kind, 1000.0))
		absorption = float(KIND_ABSORB.get(kind, 0.15))
	original_break_energy = break_energy

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

# --- Round 6 breakable contract --------------------------------------------------------

## A flying body (ImpactResolver, before contact): &"break", &"crack" or &"bounce".
func receive_impact(energy: float, hit_pos: Vector3, velocity: Vector3, _footprint := Rect2()) -> StringName:
	if is_broken:
		return &"break"
	if energy >= break_energy:
		var speed := velocity.length()
		var d := velocity / speed if speed > 0.01 else Vector3.UP
		var exit := speed * sqrt(maxf(1.0 - absorption, 0.0)) * IMPACT_PIECE_SHARE
		_shatter(d, maxf(exit, PIECE_PUSH))
		GameEvents.furniture_broken.emit(self, hit_pos, kind, energy, _flyer_near(hit_pos))
		return &"break"
	if energy >= Tuning.CRACK_FRACTION * break_energy:
		break_energy = maxf(break_energy - 0.5 * energy, 1.0)
		var flat := Vector3(velocity.x, 0.0, velocity.z)
		if flat.length() > 0.01:
			var dv := flat.normalized() * CRACK_SHOVE * clampf(energy / break_energy, 0.0, 1.5)
			apply_impulse(dv * mass, hit_pos - global_position)
		return &"crack"
	return &"bounce"

## A blast (WorldDamage; `power` already has its falloff): never breaks it.
## From its crack energy it cracks (break energy down by half the power, at most
## to BLAST_CRACK_FLOOR of the original); props up to BLAST_HOP_MASS kg hop.
## Returns &"crack", &"shove" or &"hold".
func receive_blast(center: Vector3, _radius: float, power: float, _source: StringName) -> StringName:
	if is_broken or power <= 0.0:
		return &"hold"
	var away := global_position - center
	away.y = 0.0
	away = away.normalized() if away.length() > 0.01 else Vector3.FORWARD
	var result := &"hold"
	if power >= Tuning.CRACK_FRACTION * break_energy:
		break_energy = maxf(break_energy - 0.5 * power, minf(break_energy, BLAST_CRACK_FLOOR * original_break_energy))
		result = &"crack"
	if mass > BLAST_HOP_MASS:
		return result
	var k := clampf(power / maxf(original_break_energy, 1.0), 0.15, 1.0)
	sleeping = false
	apply_central_impulse((Vector3.UP * BLAST_HOP + away * BLAST_HOP * 0.5) * k * mass)
	return result if result == &"crack" else &"shove"

func get_box_transform() -> Transform3D:
	_ensure_box()
	return global_transform * Transform3D(Basis(), _box_center)

func get_crack_threshold() -> float:
	return INF if is_broken else Tuning.CRACK_FRACTION * break_energy

func get_face_normal(from: Vector3) -> Vector3:
	var xf := get_box_transform()
	var lp := xf.affine_inverse() * from
	var h := size * 0.5
	var r := Vector3(absf(lp.x) / maxf(h.x, 0.01), absf(lp.y) / maxf(h.y, 0.01), absf(lp.z) / maxf(h.z, 0.01))
	var axis := 0 if r.x >= r.y and r.x >= r.z else (1 if r.y >= r.z else 2)
	var nrm := xf.basis[axis].normalized()
	return -nrm if lp[axis] < 0.0 else nrm

func get_half_extent_along(n: Vector3) -> float:
	var b := global_basis
	var s := size
	return absf(n.dot(b.x.normalized())) * s.x * 0.5 + absf(n.dot(b.y.normalized())) * s.y * 0.5 \
		+ absf(n.dot(b.z.normalized())) * s.z * 0.5

func is_runnable() -> bool:
	return false

func _get_size() -> Vector3:
	_ensure_box()
	return _box_size

## The box of its collision shapes, local (YardBuilder adds them after _ready).
func _ensure_box() -> void:
	if _box_size != Vector3.ZERO:
		return
	var box := AABB()
	var first := true
	for c in get_children():
		var cs := c as CollisionShape3D
		if cs == null or cs.shape == null:
			continue
		var half := Vector3.ONE * 0.1
		if cs.shape is BoxShape3D:
			half = (cs.shape as BoxShape3D).size * 0.5
		elif cs.shape is CylinderShape3D:
			var cy := cs.shape as CylinderShape3D
			half = Vector3(cy.radius, cy.height * 0.5, cy.radius)
		var a := AABB(cs.position - half, half * 2.0)
		box = a if first else box.merge(a)
		first = false
	if not first:
		_box_center = box.get_center()
		_box_size = box.size

func _flyer_near(pos: Vector3) -> Node3D:
	var b: Variant = get_meta(&"impact_body") if has_meta(&"impact_body") else null  # set by ImpactResolver before receive_impact
	if b is Node3D and is_instance_valid(b):
		return b
	var best: Node3D = null
	var best_d := 2.5
	for n in get_tree().get_nodes_in_group(&"fighters"):
		var f := n as Fighter
		if f == null or not ImpactResolver.is_tracking(f):
			continue
		var d := f.get_center_of_mass().distance_to(pos)
		if d < best_d:
			best_d = d
			best = f
	return best

## Every box / cylinder mesh child flies off as its own piece (debris that stays),
## along `d` at `push` m/s on top of the prop's own velocity.
func _shatter(d: Vector3, push := PIECE_PUSH) -> void:
	if is_broken:
		return
	is_broken = true
	last_chunks.clear()
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
		var v := linear_velocity + d * push + Vector3(randf_range(-0.6, 0.6), randf_range(0.3, 1.5), randf_range(-0.6, 0.6))
		b.linear_velocity = v
		b.angular_velocity = Vector3(randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4))
		parent.add_child(b)
		b.global_transform = xf
		b.linear_velocity = v
		DebrisManager.register(b, false)
		last_chunks.append(b)
	FurnitureKit.guard_pieces(parent, last_chunks, linear_velocity.length() + push)
	DebrisManager.note_loose_prop_broken(self)
	collision_layer = 0
	queue_free()
