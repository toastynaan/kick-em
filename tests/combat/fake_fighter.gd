extends Fighter
## Test double: a Fighter whose Round 7 react state the test sets, and which
## records every reaction CombatController asks of it (then applies it).
## OWNER: agent B (combat tests).

## The state get_react_state() reports (&"" = the real one, agent H's).
var fake_react: StringName = &""
## Every react / knockdown / launch call, in order:
## [kind, direction or velocity change, push, stun, HitInfo or null].
var reacts: Array = []

func get_react_state() -> StringName:
	return fake_react if fake_react != &"" else super()

func react(kind: StringName, direction: Vector3, push: float, stun: float, info: HitInfo = null) -> void:
	reacts.append([kind, direction, push, stun, info])
	super(kind, direction, push, stun, info)

func knockdown(direction: Vector3, hit_bone: StringName = &"Chest") -> void:
	reacts.append([&"knockdown", direction, 0.0, 0.0, null])
	super(direction, hit_bone)

func launch(velocity_change: Vector3, hit_point: Vector3, hit_bone: StringName = &"Chest") -> void:
	reacts.append([&"launch", velocity_change, 0.0, 0.0, null])
	super(velocity_change, hit_point, hit_bone)

## Round 9: every add_spin(rate) call, in order (rad/s).
var spins: Array[float] = []

func add_spin(rate: float) -> void:
	spins.append(rate)
	super(rate)

## The last recorded reaction ([] when none).
func last_react() -> Array:
	return reacts[-1] if not reacts.is_empty() else []
