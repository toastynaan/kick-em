extends Node
## Test double: the parts of PlayerController a strike reads (Round 5 target
## picking): the stick, the aim direction and the lock-on target.
## OWNER: agent B (combat tests). Assign with `fighter.brain = double`.

var stick := Vector3.ZERO     ## world XZ, length 0..1
var lock: Fighter = null
var camera_forward := Vector3.FORWARD

func get_stick_world() -> Vector3:
	return stick

## The stick, or camera forward when it is neutral (PlayerController.get_aim_dir).
func get_aim_dir() -> Vector3:
	return stick.normalized() if stick.length() > 0.2 else camera_forward

func get_lock_target() -> Fighter:
	return lock
