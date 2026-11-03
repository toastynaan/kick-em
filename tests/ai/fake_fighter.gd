extends Fighter
## Test double for AI tests: a real Fighter whose down / hitstun state and
## Round 7 reaction state (is_reacting, is_lifted, get_react_state) can be
## forced. The fake states add to the real ones. OWNER: agent C (AI tests).

var fake_down := false
var fake_hitstun := false
var fake_reacting := false
var fake_lifted := false
## Reported by get_react_state() while fake_reacting or fake_lifted is on.
var fake_react_state: StringName = &"snap"

func is_down() -> bool:
	return fake_down or super()

func is_in_hitstun() -> bool:
	return fake_hitstun or super()

func is_reacting() -> bool:
	return fake_reacting or fake_lifted or super()

func is_lifted() -> bool:
	return fake_lifted or super()

func get_react_state() -> StringName:
	if fake_lifted:
		return &"lift"
	if fake_reacting:
		return fake_react_state
	return super()

func can_act() -> bool:
	return not (fake_reacting or fake_lifted) and super()
