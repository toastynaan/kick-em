extends CameraRig
## Camera tests only: a CameraRig whose Round 7 inputs from other modules are
## scripted: the combat target (CombatController.get_combat_target()), the drive
## (Carry.is_driving()) and the throw wind-up (Carry.get_throw_windup()).
## Round 8: the charge (CombatController.get_charge()) and, with script_air on,
## the air combo state (Traversal.is_air_following(), get_air_hits(), the
## player's airborne state). Everything else is the real rig.
## OWNER: agent E (camera & time).

## Untyped: a test may free the fighter it points at.
var fake_target = null
var fake_driving := false
var fake_windup := 0.0
var fake_charge := 0.0
## Off: the air combo inputs come from the real player (as CameraRig).
var script_air := false
var fake_air_following := false
var fake_air_hits := 0
var fake_airborne := false

func _combat_target():
	return fake_target

func _is_driving() -> bool:
	return fake_driving

func _throw_windup() -> float:
	return fake_windup

func _charge_amount() -> float:
	return fake_charge

func _air_following() -> bool:
	return fake_air_following if script_air else super._air_following()

func _air_hits() -> int:
	return fake_air_hits if script_air else super._air_hits()

func _player_airborne() -> bool:
	return fake_airborne if script_air else super._player_airborne()

func _air_follow_target():
	return null if script_air else super._air_follow_target()
