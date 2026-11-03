extends Defence
## Test double (Round 7): a Defence that records Counter and Dash presses and
## answers like the real one where the test sets it: with `counter_target` a
## Counter press cancels that attacker's attack and calls play_counter(); with
## `pursuit` set, get_pursuit_target() names that flying body until the pursuit
## hit lands (on_pursuit_hit). `intercept` answers intercepts().
## OWNER: agent B (combat tests). Assign with `fighter.defence = double`.

var presses: Array[float] = []
var dash_presses: Array[float] = []
var counter_target: Fighter = null
var played: Array[bool] = []   ## play_counter() results
var pursuit: Fighter = null
var pursuit_hits: Array = []
var intercept := false
var intercepted: Array = []    ## [attacker, move_id] per intercepts() call
var vanished := false

## Only the fighter: the real setup() listens to GameEvents.
func setup(p_fighter: Fighter) -> void:
	fighter = p_fighter

func is_enabled() -> bool:
	return true

func on_counter_pressed(now: float) -> bool:
	presses.append(now)
	if counter_target == null or not is_instance_valid(counter_target):
		return false
	if counter_target.combat != null:
		counter_target.combat.cancel()
	played.append(fighter.combat.play_counter(counter_target))
	return true

func on_dash_pressed(now: float) -> bool:
	dash_presses.append(now)
	return false

func get_pursuit_target() -> Fighter:
	if pursuit != null and is_instance_valid(pursuit) and not pursuit.is_dead():
		return pursuit
	return null

func on_pursuit_hit(victim: Fighter) -> void:
	pursuit_hits.append(victim)
	pursuit = null

func intercepts(attacker: Fighter, move_id: StringName) -> bool:
	intercepted.append([attacker, move_id])
	return intercept

func is_vanished() -> bool:
	return vanished

## The real Defence ticks windows and pursuits; the double does nothing.
func _physics_process(_delta: float) -> void:
	pass
