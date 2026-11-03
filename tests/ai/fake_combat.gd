extends CombatController
## Test double: B's CombatController with forceable dazed / stumbling /
## attacking states, and (Round 8) a forceable pressure fraction and break.
## OWNER: agent C (AI tests).

var fake_dazed := false
var fake_stumbling := false
var fake_attacking := false
## Round 8: >= 0 replaces get_pressure_fraction(); fake_broken adds to is_broken().
var fake_pressure := -1.0
var fake_broken := false

func is_dazed() -> bool:
	return fake_dazed or super()

func is_stumbling() -> bool:
	return fake_stumbling or super()

func is_attacking() -> bool:
	return fake_attacking or super()

func get_pressure_fraction() -> float:
	return fake_pressure if fake_pressure >= 0.0 else super()

func is_broken() -> bool:
	return fake_broken or super()
