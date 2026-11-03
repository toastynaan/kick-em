extends Node
## Stand-in CombatController for FX tests: the Round 8 queries effects read
## (charge, pressure, broken). The test sets the fields. OWNER: agent F.

var charging := false
var charge := 0.0
var broken := false
var pressure_fraction := 0.0

func is_charging() -> bool:
	return charging

func get_charge() -> float:
	return charge if charging else 0.0

func is_broken() -> bool:
	return broken

func get_pressure_fraction() -> float:
	return 1.0 if broken else pressure_fraction
