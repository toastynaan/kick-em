extends CombatController
## Test double (tests/input only): B's CombatController with its broken status
## scripted (broken_until, real time), so Fighter's daze can be checked against
## "B's is_broken() is the status" whatever state B's pressure code is in.
## Everything else is B's real combat. Swap it in with use_on(fighter).
## OWNER: agent H (fighter, player & defence).

var broken_until := -INF  ## TimeDirector.now() until which is_broken() is true

static func use_on(f: Fighter) -> Node:
	var dbl: Node = load("res://tests/input/broken_double.gd").new()
	dbl.name = "BrokenDouble"
	var old := f.combat
	f.add_child(dbl)
	dbl.call(&"setup", f)
	f.combat = dbl as CombatController
	if old != null:
		old.queue_free()
	return dbl

func is_broken() -> bool:
	return TimeDirector.now() < broken_until

func get_broken_time_left() -> float:
	return maxf(broken_until - TimeDirector.now(), 0.0)
