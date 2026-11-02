class_name LooseFurniture
extends RigidBody3D
## Round 6 (agent K): a light clutter object (a chair, a cardboard box) knocked
## loose by a hit that did not break it: the whole object as one debris body.
## Furniture._knock_loose builds it and registers it with DebrisManager
## (Layers.DEBRIS: walking capsules shove it, bones and debris hit it; it stays
## for the round and freezes at rest). A hard hit still breaks it where it lies
## (Furniture.break_loose):
## - a flying body (one the ImpactResolver tracks) whose E = 1/2 M v^2 (its
##   centre-of-mass speed against this body's) reaches the object's break
##   energy when one of its bones touches it;
## - a fighter running into a loose glass or cardboard object at
##   Tuning.RUN_THROUGH_SPEED;
## - any other hard knock: a velocity change of BREAK_DV in one tick (gravity removed).
## OWNER: agent K (clutter).

## m/s of velocity change in one tick that breaks it, per kind: cardboard
## breaks at the run-through speed, a chair a bit harder.
const BREAK_DV := {&"cardboard": Tuning.RUN_THROUGH_SPEED, &"chair": 7.0}
const BREAK_DV_DEFAULT := 7.0
## s after coming loose before hits count (the knock itself is not one).
const GRACE := 0.15

var furniture: Furniture
var _last_v := Vector3.ZERO
var _age := 0.0

func _ready() -> void:
	can_sleep = true
	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_body_entered)

func _physics_process(delta: float) -> void:
	if furniture == null or not is_instance_valid(furniture) or furniture.is_broken:
		return
	if freeze or sleeping:
		_last_v = Vector3.ZERO
		return
	_age += delta
	var v := linear_velocity
	var dv := v - _last_v - get_gravity() * delta
	_last_v = v
	if _age < GRACE:
		return
	if dv.length() >= float(BREAK_DV.get(furniture.kind, BREAK_DV_DEFAULT)):
		furniture.break_loose(self, dv)

func _on_body_entered(other: Node) -> void:
	if furniture == null or not is_instance_valid(furniture) or furniture.is_broken or _age < GRACE:
		return
	var f := _fighter_of(other)
	if f == null:
		return
	var v := Vector3.ZERO
	if other is PhysicalBone3D:
		if not ImpactResolver.is_tracking(f):
			return  # a body lying there nudging it is no hit
		v = f.get_com_velocity()
	else:
		v = f.real_velocity()
		v.y = 0.0
		if not (furniture.kind in Tuning.RUN_THROUGH_KINDS) or v.length() < Tuning.RUN_THROUGH_SPEED:
			return
	var rel := v - linear_velocity
	var e := 0.5 * f.get_total_mass() * rel.length_squared()
	if other is PhysicalBone3D and e < furniture.get_break_energy():
		return
	# Contacts arrive while physics flushes its queries: break right after.
	furniture.call_deferred(&"break_loose", self, rel, f, e)

static func _fighter_of(n: Node) -> Fighter:
	var p := n
	for i in 6:
		if p == null:
			return null
		if p is Fighter:
			return p
		p = p.get_parent()
	return null
