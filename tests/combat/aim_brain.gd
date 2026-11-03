extends Node
## Test double: the parts of PlayerController a strike reads (Round 7 freeflow
## target picking): the camera-relative stick (zero when neutral) and camera
## forward.
## OWNER: agent B (combat tests). Assign with `fighter.brain = double`.

var stick := Vector3.ZERO           ## world XZ, length 0..1
var camera_forward := Vector3.FORWARD

func get_stick_world() -> Vector3:
	return stick

## PlayerController.get_aim_dir (Round 7): the stick, zero when neutral.
func get_aim_dir() -> Vector3:
	return stick if stick.length() > 0.2 else Vector3.ZERO

## PlayerController.get_camera_forward.
func get_camera_forward() -> Vector3:
	return camera_forward
