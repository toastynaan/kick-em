extends Node3D
## Duck-typed fighter for FX tests (the parts BloodFX / AudioFX read).
## OWNER: agent F.

const FakeRig := preload("res://tests/fx/fx_fake_rig.gd")

var rig: Node3D
var traversal: Node   ## tests/fx/fx_fake_traversal.gd when a test needs one
var hp := 1000.0
var max_hp := 1000.0
var com_velocity := Vector3.ZERO
var down := false
var launched := false

func _init() -> void:
	var r := FakeRig.new()
	r.name = "Rig"
	rig = r
	add_child(r)

func build_body() -> void:
	(rig as FakeRig).build_body()

func is_dead() -> bool:
	return hp <= 0.0

func is_down() -> bool:
	return down or is_dead()

func is_launched() -> bool:
	return launched

func get_com_velocity() -> Vector3:
	return com_velocity

func get_center_of_mass() -> Vector3:
	return global_position + Vector3.UP

func get_aim_point() -> Vector3:
	return global_position + Vector3.UP * 1.3

func get_ground_position() -> Vector3:
	return global_position

## Attach a fake Traversal (sprint_charge, airborne, speed).
func add_traversal() -> Node:
	traversal = preload("res://tests/fx/fx_fake_traversal.gd").new()
	traversal.name = "Traversal"
	add_child(traversal)
	return traversal
