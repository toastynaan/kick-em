extends CameraRig
## Camera tests only: a CameraRig whose Round 7 inputs from other modules are
## scripted: the combat target (CombatController.get_combat_target()), the drive
## (Carry.is_driving()) and the throw wind-up (Carry.get_throw_windup()).
## Everything else is the real rig. OWNER: agent E (camera & time).

## Untyped: a test may free the fighter it points at.
var fake_target = null
var fake_driving := false
var fake_windup := 0.0

func _combat_target():
	return fake_target

func _is_driving() -> bool:
	return fake_driving

func _throw_windup() -> float:
	return fake_windup
