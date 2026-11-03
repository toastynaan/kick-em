extends Carry
## Test double (agent M, tests/move): a Carry that reports a held body (or,
## with `prop`, a prop in hand) and a walking share, so movement checks do not
## depend on a real grab connecting.
## It never moves anything and never takes Dash (the drive is started by the
## test through Traversal.begin_drive()). Install with
## move_test_base.install_carry_double(); `real` keeps the fighter's own Carry.

var real: Carry
var holding := true
var prop := false   ## a prop in hand instead of a body (Dash stays dodge / sprint)
var move_mult := 0.7

## Only the fighter: the real setup() connects events and builds probes.
func setup(p_fighter: Fighter) -> void:
	fighter = p_fighter

func _physics_process(_delta: float) -> void:
	pass

func _exit_tree() -> void:
	pass

func is_enabled() -> bool:
	return true

func is_holding() -> bool:
	return holding

func is_holding_body() -> bool:
	return holding and not prop

func is_holding_prop() -> bool:
	return holding and prop

func is_held() -> bool:
	return false

func get_holder() -> Fighter:
	return null

func is_busy() -> bool:
	return holding and not prop

func get_move_speed_mult() -> float:
	return move_mult if holding and not prop else 1.0

func on_grab_pressed(_now: float) -> void:
	pass

func on_grab_released(_now: float) -> void:
	pass

func on_attack_pressed(_action: int, _now: float) -> bool:
	return holding

func on_attack_released(_action: int, _now: float) -> void:
	pass

func on_drive_pressed(_now: float) -> bool:
	return is_holding_body()

func on_drive_released(_now: float) -> void:
	pass

func is_driving() -> bool:
	return fighter != null and fighter.traversal != null and fighter.traversal.is_driving()

func drop(_reason: StringName) -> void:
	holding = false
