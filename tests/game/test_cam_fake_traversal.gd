extends Traversal
## Camera tests only: a Traversal that reports scripted sprint, fall and
## wall-run state (sprint_charge is set directly) and never moves the player.
## OWNER: agent E (camera & time).

var fake_cap := 8.0
var fake_airborne := false
var fake_fall := 0.0
var fake_wall := false
var fake_side := 0
var fake_normal := Vector3.ZERO

func _process(_delta: float) -> void:
	pass

func _physics_process(_delta: float) -> void:
	pass

func physics_move(_delta: float) -> bool:
	return false

func get_speed_cap() -> float:
	return fake_cap

func is_sprinting() -> bool:
	return sprint_charge > 0.0

func is_airborne() -> bool:
	return fake_airborne

func get_fall_height() -> float:
	return fake_fall

func is_wall_running() -> bool:
	return fake_wall

func get_wall_side() -> int:
	return fake_side

func get_wall_normal() -> Vector3:
	return fake_normal
