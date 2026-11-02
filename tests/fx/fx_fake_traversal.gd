extends Node
## Stand-in for Traversal (agent M) in FX tests: the parts effects poll.
## OWNER: agent F.

var sprint_charge := 0.0
var airborne := false
var speed := 0.0
var air_dashing := false

func is_airborne() -> bool:
	return airborne

func get_speed() -> float:
	return speed

func get_speed_cap() -> float:
	return Tuning.debug_speed_cap

func is_air_dashing() -> bool:
	return air_dashing
