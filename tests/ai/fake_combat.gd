extends CombatController
## Test double: B's CombatController with forceable dazed / stumbling states.
## OWNER: agent C (AI tests).

var fake_dazed := false
var fake_stumbling := false

func is_dazed() -> bool:
	return fake_dazed or super()

func is_stumbling() -> bool:
	return fake_stumbling or super()
