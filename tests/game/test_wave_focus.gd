extends Node
## F6 acceptance (J): every wave starts with 1 Focus bar (Tuning.debug_start_focus,
## default Tuning.FOCUS_WAVE_START), whatever the player had left. Runs 6 waves,
## leaving the player with a different amount before each start, then repeats
## one wave with the debug setting at 2 bars. Prints the Focus measured at each
## wave start and the focus_changed value GameMode emitted.

const WAVES := 6
const LEFTOVER: Array[float] = [0.0, 2.7, 0.3, 3.0, 1.6, 0.0, 2.2]  ## Focus before each wave start

var _fails := 0
var _at_start: Array[Dictionary] = []   ## {wave, focus, emitted}
var _gm: GameMode
var _last_emit := -1.0

func _ready() -> void:
	GameEvents.focus_changed.connect(func(f: Node3D, v: float) -> void:
		if _gm != null and f == _gm.player:
			_last_emit = v)
	GameEvents.wave_started.connect(_on_wave_started)
	await get_tree().process_frame
	await _run()
	TimeDirector.reset()
	print("TEST test_wave_focus: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

## Read at the moment the wave starts (wave_started is emitted after GameMode set Focus).
func _on_wave_started(index: int, _total: int) -> void:
	if _gm == null or not is_instance_valid(_gm.player):
		return
	_at_start.append({"wave": index + 1, "focus": _gm.player.focus, "emitted": _last_emit})

func _run() -> void:
	var saved := Tuning.debug_start_focus
	Tuning.debug_start_focus = Tuning.FOCUS_WAVE_START
	_gm = GameMode.new()
	_gm.show_title = false
	_gm.breather_time = 0.4
	add_child(_gm)
	_gm.start_round(&"waves")
	var tps := Engine.physics_ticks_per_second
	for w in WAVES:
		# Leave a different amount of Focus before the next wave starts.
		await _kill_wave(int(20.0 * tps))
		await _wait_until(func() -> bool: return _gm.phase == GameMode.Phase.BREATHER, 5.0)
		_gm.player.focus = LEFTOVER[w + 1]
		_last_emit = -1.0
		var before := _gm.player.focus
		var n := _at_start.size()
		await _wait_until(func() -> bool: return _at_start.size() > n, _gm.breather_time + 3.0)
		print("    wave %d: Focus %.2f before the start" % [w + 2, before])
	var all_one := true
	for r in _at_start:
		print("    wave %d starts with %.2f bars (focus_changed emitted %.2f)" % [r["wave"], r["focus"], r["emitted"]])
		if not is_equal_approx(float(r["focus"]), 1.0) or not is_equal_approx(float(r["emitted"]), 1.0):
			all_one = false
	_check(_at_start.size() == WAVES + 1, "%d wave starts seen (%d)" % [WAVES + 1, _at_start.size()])
	_check(all_one, "every wave starts with exactly 1 Focus bar, and focus_changed says so")

	# Debug setting: starting Focus 2.
	Tuning.debug_start_focus = 2.0
	await _kill_wave(int(20.0 * tps))
	await _wait_until(func() -> bool: return _gm.phase == GameMode.Phase.BREATHER, 5.0)
	_gm.player.focus = 0.0
	_last_emit = -1.0
	var n2 := _at_start.size()
	await _wait_until(func() -> bool: return _at_start.size() > n2, _gm.breather_time + 3.0)
	var r2: Dictionary = _at_start.back()
	print("    debug start Focus 2: wave %d starts with %.2f bars" % [r2["wave"], r2["focus"]])
	_check(is_equal_approx(float(r2["focus"]), 2.0), "debug_start_focus 2 -> the wave starts with 2 bars (%.2f)" % r2["focus"])
	Tuning.debug_start_focus = saved

	# Duel starts with the same setting.
	Tuning.debug_start_focus = Tuning.FOCUS_WAVE_START
	_gm.start_round(&"duel")
	await get_tree().physics_frame
	_check(is_equal_approx(_gm.player.focus, 1.0), "the duel starts with 1 Focus bar (%.2f)" % _gm.player.focus)
	Tuning.debug_start_focus = saved

func _kill_wave(max_frames: int) -> void:
	for i in max_frames:
		if is_instance_valid(_gm.player):
			_gm.player.hp = _gm.player.max_hp
		for f in _gm.get_alive_enemies():
			f.apply_damage(f.max_hp + 10.0, &"test")
		await get_tree().physics_frame
		if _gm.get_enemies_left() == 0:
			return

func _wait_until(cond: Callable, max_real: float) -> void:
	var until := TimeDirector.now() + max_real
	while not cond.call() and TimeDirector.now() < until:
		if is_instance_valid(_gm.player):
			_gm.player.hp = _gm.player.max_hp
		await get_tree().physics_frame
