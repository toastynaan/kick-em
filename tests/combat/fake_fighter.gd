extends Fighter
## Test double: a Fighter whose stance queries (agent H's) are set by the test.
## OWNER: agent B (combat tests).

var fake_crouch := false
var fake_air := false
var fake_intent: StringName = &"neutral"

func is_crouching() -> bool:
	return fake_crouch

func is_airborne() -> bool:
	return fake_air

func get_input_intent() -> StringName:
	return fake_intent
