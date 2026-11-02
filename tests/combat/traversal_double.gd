extends Traversal
## Test double (Round 5): a Traversal whose speed and state the test sets.
## Records what CombatController tells it, and drops to walking speed on a
## sprint strike like the real one, so a test sees whether the strike sampled
## its speed BEFORE calling on_strike_started().
## OWNER: agent B (combat tests). Assign with `fighter.traversal = double`.

var speed := 0.0            ## m/s toward anything (speed_toward) and get_speed()
var cap := 8.0
var sprinting := false
var wall_running := false
var vaulting := false
var vault_progress := 0.0
var airborne := false
var charge_steering := false
## on_strike_started() calls: the sprint flag of each, in order.
var strikes: Array[bool] = []
## speed reported by speed_toward() at each call (before / after the drop).
var sampled: Array[float] = []
var last_dir := Vector3.ZERO
var drops := 0

## Only the fighter: the real setup() builds probes.
func setup(p_fighter: Fighter) -> void:
	fighter = p_fighter

func physics_move(_delta: float) -> bool:
	return false

func speed_toward(dir: Vector3) -> float:
	last_dir = dir
	var v := cap if wall_running else speed
	sampled.append(v)
	return v

func get_speed() -> float:
	return speed

func get_speed_cap() -> float:
	return cap

func is_sprinting() -> bool:
	return sprinting

func is_charge_steering() -> bool:
	return charge_steering

func is_wall_running() -> bool:
	return wall_running

func is_vaulting() -> bool:
	return vaulting

func get_vault_progress() -> float:
	return vault_progress

func is_airborne() -> bool:
	return airborne

## Like the real one: a sprint strike drops to walk and ends a wall run.
func on_strike_started(sprint_strike: bool) -> void:
	strikes.append(sprint_strike)
	if sprint_strike:
		speed = Tuning.WALK_SPEED
		sprinting = false
		wall_running = false
		charge_steering = false

func is_drop_striking() -> bool:
	return airborne and drops > 0

func begin_drop_strike() -> bool:
	drops += 1
	return true
