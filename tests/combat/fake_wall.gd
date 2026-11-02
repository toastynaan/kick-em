extends StaticBody3D
## Test double: a wall that records receive_strike calls and answers `result`.
## OWNER: agent B (combat tests).

var calls: Array = []        ## [attacker, hit_pos, direction, power, attacker position]
var result: StringName = &"chip"

func setup(size: Vector3, layer := Layers.DESTRUCTIBLE) -> void:
	collision_layer = layer
	collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	add_child(cs)

func receive_strike(attacker: Node3D, hit_pos: Vector3, direction: Vector3, power: float) -> StringName:
	calls.append([attacker, hit_pos, direction, power, attacker.global_position])
	return result
