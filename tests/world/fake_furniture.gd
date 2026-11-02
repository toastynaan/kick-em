extends StaticBody3D
## TEST-ONLY stand-in for agent K's clutter: implements just the Round 6
## breakable contract (group "breakables", receive_impact, receive_strike,
## receive_blast, absorption, kind, surface, is_broken, get_face_normal,
## get_half_extent_along) from a Tuning.FURNITURE kind, with no `size`,
## get_box_transform() or get_crack_threshold(): ImpactResolver must work from
## its collision shapes and the Tuning table, as it will for K's classes.

var kind: StringName = &"table"
var surface: StringName = &"wood"
var absorption := 0.15
var is_broken := false
var half := Vector3(0.6, 0.4, 0.45)
var impacts: Array = []   ## [energy, outcome, the meta "impact_body" seen during the call]
var blasts: Array = []    ## [power, source]

func setup(p_kind: StringName, p_half: Vector3) -> void:
	kind = p_kind
	half = p_half
	var spec: Dictionary = Tuning.FURNITURE[kind]
	absorption = float(spec["absorb"])
	surface = spec["surface"]
	collision_layer = Layers.DESTRUCTIBLE
	collision_mask = 0
	add_to_group(&"breakables")
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = half * 2.0
	cs.shape = box
	cs.position = Vector3(0, half.y, 0)
	add_child(cs)

func receive_impact(energy: float, _hit_pos: Vector3, _velocity: Vector3, _footprint := Rect2()) -> StringName:
	var brk := float(Tuning.FURNITURE[kind]["break"])
	var out := &"bounce"
	if energy >= brk:
		out = &"break"
		is_broken = true
		for c in get_children():
			if c is CollisionShape3D:
				(c as CollisionShape3D).disabled = true
	elif energy >= Tuning.CRACK_FRACTION * brk:
		out = &"crack"
	impacts.append([energy, out, get_meta(&"impact_body", null)])
	return out

func receive_strike(_attacker: Node3D, _hit_pos: Vector3, _direction: Vector3, _power: float) -> StringName:
	return &"hold"

func receive_blast(_center: Vector3, _radius: float, power: float, source: StringName) -> StringName:
	blasts.append([power, source])
	return &"hold"

func get_face_normal(from: Vector3) -> Vector3:
	var lp := to_local(from) - Vector3(0, half.y, 0)
	var r := Vector3(absf(lp.x) / half.x, absf(lp.y) / half.y, absf(lp.z) / half.z)
	var axis := 0 if r.x >= r.y and r.x >= r.z else (1 if r.y >= r.z else 2)
	var n := global_basis[axis].normalized()
	return -n if lp[axis] < 0.0 else n

func get_half_extent_along(n: Vector3) -> float:
	var b := global_basis
	return absf(n.dot(b.x.normalized())) * half.x + absf(n.dot(b.y.normalized())) * half.y \
		+ absf(n.dot(b.z.normalized())) * half.z
