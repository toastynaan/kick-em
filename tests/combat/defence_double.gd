extends Defence
## Test double (Round 5): a Defence whose counter bonus, pursuit target and
## interception the test sets; records what CombatController asks of it.
## OWNER: agent B (combat tests). Assign with `fighter.defence = double`.

var on := true                ## is_enabled() (the real Defence's switch is static)
var bonus := 0.0              ## counter_bonus() until consumed
var consumed := 0
var pursuit: Fighter = null   ## get_pursuit_target()
var pursuit_hits: Array = []
var intercept := false        ## intercepts() answer
var intercepted: Array = []   ## [attacker, move_id] per intercepts() call
var block_presses: Array[float] = []
var dash_presses: Array[float] = []

## Only the fighter: the real setup() listens to GameEvents.
func setup(p_fighter: Fighter) -> void:
	fighter = p_fighter

func is_enabled() -> bool:
	return on

func is_vanished() -> bool:
	return false

func is_parry_locked() -> bool:
	return false

func on_block_pressed(now: float) -> void:
	block_presses.append(now)

func on_dash_pressed(now: float) -> bool:
	dash_presses.append(now)
	return false

func intercepts(attacker: Fighter, move_id: StringName) -> bool:
	intercepted.append([attacker, move_id])
	return intercept

func counter_bonus() -> float:
	return bonus

func consume_counter_bonus() -> void:
	consumed += 1
	bonus = 0.0

func get_pursuit_target() -> Fighter:
	if pursuit != null and is_instance_valid(pursuit) and not pursuit.is_dead():
		return pursuit
	return null

func on_pursuit_hit(victim: Fighter) -> void:
	pursuit_hits.append(victim)
	pursuit = null

## The real defence ticks pending presses and pursuits; the double does nothing.
func _physics_process(_delta: float) -> void:
	pass
