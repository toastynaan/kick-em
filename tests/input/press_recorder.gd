extends CombatController
## Test double (tests/input only): a CombatController that records every
## press() and release() PlayerController makes and starts no move, so the
## key map is checked whatever state agent B's combat is in. Swap it in with
## use_on(fighter); `facing` is the fighter's forward at each press (auto_face).
## OWNER: agent H (fighter, player & defence).

var calls: Array = []  ## [action (CombatController.Action), pressed, physics frame, facing at the press]

static func use_on(f: Fighter) -> Node:
	var rec: Node = load("res://tests/input/press_recorder.gd").new()
	rec.name = "PressRecorder"
	var old := f.combat
	f.add_child(rec)
	rec.call(&"setup", f)
	f.combat = rec as CombatController
	if old != null:
		old.queue_free()
	return rec

func press(action: int) -> void:
	calls.append([action, true, Engine.get_physics_frames(), fighter.get_forward()])

func release(action: int) -> void:
	calls.append([action, false, Engine.get_physics_frames(), fighter.get_forward()])

## The recorded [action, pressed] pairs (no frames), for compact checks.
func pairs() -> Array:
	var out := []
	for e: Array in calls:
		out.append([e[0], e[1]])
	return out

# --- Round 8 doubles: what PlayerController reads from B ---------------------------
var follow_target: Fighter = null   ## get_air_follow_target()
var charging := false               ## is_charging()
var charge_target: Fighter = null   ## get_charge_target()

func get_air_follow_target() -> Fighter:
	return follow_target

func is_charging() -> bool:
	return charging

func get_charge_target() -> Fighter:
	return charge_target
