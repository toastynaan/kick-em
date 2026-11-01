extends Fighter
## Test double for AI tests: a real Fighter whose down / hitstun state can be
## forced. OWNER: agent C (AI tests).

var fake_down := false
var fake_hitstun := false

func is_down() -> bool:
	return fake_down or super()

func is_in_hitstun() -> bool:
	return fake_hitstun or super()
