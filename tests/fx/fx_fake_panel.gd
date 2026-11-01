extends Node3D
## Stand-in for a locally fractured Destructible (round 2): round holes in the
## panel's XY plane; is_point_open() is true inside any hole. The node may be
## the StaticBody3D itself or a parent of cell bodies. OWNER: agent F.

var surface: StringName = &"drywall"
var is_broken := false
var holes: Array[Vector3] = []
var hole_radius := 0.6

func is_point_open(world_pos: Vector3) -> bool:
	for h in holes:
		if Vector2(world_pos.x - h.x, world_pos.y - h.y).length() < hole_radius:
			return true
	return false

func receive_impact(_energy: float, _position: Vector3, _velocity: Vector3) -> StringName:
	return &"bounce"
