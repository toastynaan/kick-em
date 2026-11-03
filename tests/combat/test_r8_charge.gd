extends "res://tests/combat/combat_test_base.gd"
## Round 8 acceptance checks 1 and 4 (docs/Round 8 — Charge and Pressure.md:
## Charge), through the real input path (Input.action_press ->
## PlayerController -> InputInterpreter -> CombatController):
## 1. a 0.2 s press is the tap; a 0.6 s hold gives c = 0.47 +-0.03 at the
##    release (base); the charge starts at R8_TAP_MAX, is full at
##    debug_charge_full (1.0 s) and fires itself R8_CHARGE_HOLD_AT_FULL later;
##    with debug_charge_full 0.5 it is full at 0.5 s. The events
##    (charge_started, charge_level_changed at the move's steps, charge_full,
##    charge_released) and get_charge / get_charge_steps / is_charge_full; a
##    buffered press still held when it starts charges (c from its press).
## 4. walking while charging is R8_CHARGE_WALK_MULT of the walk; the release
##    glides R8_CHARGE_LUNGE: 3 m at c = 0, 6 m at c = 1 (to a target beyond
##    the lunge); a hit on the charging player cancels it (charge_cancelled
##    &"hit", no strike on the release).

const C_TOL := 0.03

var _p: Fighter
var _x := 0.0
var _active: Array = []   ## [move id, real time, charged]
var _starts: Array = []   ## [move id, real time]

func _init() -> void:
	_timeout = 150.0

func run() -> void:
	_p = spawn_player(Vector3.ZERO)
	_p.combat.attack_active.connect(func(id: StringName) -> void:
		_active.append([id, TimeDirector.now(), bool(_p.combat.get_strike_debug()["charged"])]))
	_p.combat.attack_started.connect(func(id: StringName) -> void: _starts.append([id, TimeDirector.now()]))
	await ticks(20)

	print("1. a 0.2 s press is the tap")
	await _fresh()
	await tap_input(&"punch", 0.2)
	await wait_until(func() -> bool: return not _active.is_empty(), 1.0)
	var lv := _strike_levels()
	print("  moves %s, charge events %d, strike_started levels %s" % [_ids(), events_of(&"charge_started").size(), lv])
	check(_active.size() == 1 and _active[0][0] == &"jab" and not _active[0][2] and events_of(&"charge_started").is_empty()
		and lv == [0], "0.2 s: the jab tap, no charge (strike_started level 0)")
	var tap_su: float = _active[0][1] - _starts[0][1] if not _active.is_empty() and not _starts.is_empty() else INF
	print("  the tap's first active frame %.3f s after the press (its startup %.3f s)" % [tap_su, Tuning.frames(7)])
	check(tap_su <= 0.2 + 1.0 / 60.0, "the tap goes active on the release (it waited at the end of its startup)")

	print("1. a 0.6 s hold: c at the release")
	await _fresh()
	Input.action_press(&"punch")
	await wait_real(0.6)
	var c_before := _p.combat.get_charge()
	var charging := _p.combat.is_charging() and _p.combat.get_charge_move() == &"jab"
	Input.action_release(&"punch")
	await wait_until(func() -> bool: return not events_of(&"charge_released").is_empty(), 0.5)
	var c_rel := float(_p.combat.get_strike_debug()["strike_c"])
	var t_press: float = _starts[0][1] if not _starts.is_empty() else INF
	print("DATA 0.6 s hold: c %.3f just before the release, %.3f at the release (want %.3f +-%.2f); charge_started %.3f s after the press" % [
		c_before, c_rel, (0.6 - Tuning.R8_TAP_MAX) / (Tuning.debug_charge_full - Tuning.R8_TAP_MAX), C_TOL,
		first_time(&"charge_started") - t_press])
	check(charging, "it was charging the jab (get_charge_move)")
	check(absf(c_rel - 0.47) <= C_TOL, "c = 0.47 +-0.03 at the release (%.3f)" % c_rel)
	check(absf(first_time(&"charge_started") - t_press - Tuning.R8_TAP_MAX) <= 1.5 / 120.0,
		"charge_started at R8_TAP_MAX after the press")
	await wait_until(func() -> bool: return not _active.is_empty(), 1.0)
	check(_active.size() == 1 and _active[0][2] and _strike_levels().size() == 1 and _strike_levels()[0] >= 1,
		"the release fires the charged jab (strike_started level %s)" % [_strike_levels()])
	check(events_of(&"charge_released").size() == 1 and events_of(&"charge_released")[0][2] == &"jab",
		"charge_released(player, jab, level)")

	for full: float in [1.0, 0.5]:
		print("1. held on: full at debug_charge_full %.1f s, then it fires itself %.1f s later" % [full, Tuning.R8_CHARGE_HOLD_AT_FULL])
		Tuning.debug_charge_full = full
		await _fresh()
		Input.action_press(&"front_kick")
		var steps: Array[float] = []
		var full_flag := [false, false]  # is_charge_full before / after charge_full
		await wait_until(func() -> bool: return _p.combat.is_charging(), 1.0)
		steps = _p.combat.get_charge_steps()
		await wait_until(func() -> bool:
			if not full_flag[1] and events_of(&"charge_full").is_empty() and _p.combat.is_charge_full():
				full_flag[0] = true
			if not events_of(&"charge_full").is_empty() and _p.combat.is_charge_full():
				full_flag[1] = true
			return not events_of(&"charge_released").is_empty(), full + 1.5)
		var still_down := Input.is_action_pressed(&"front_kick")
		await wait_until(func() -> bool: return not _active.is_empty(), 1.0)
		await wait_real(0.3)
		Input.action_release(&"front_kick")
		await wait_real(0.2)
		t_press = _starts[0][1] if not _starts.is_empty() else INF
		var t_start := first_time(&"charge_started") - t_press
		var t_full := first_time(&"charge_full") - t_press
		var t_fire := first_time(&"charge_released") - t_press
		var levels := events_of(&"charge_level_changed").map(func(e: Array) -> Array: return [e[2], float(e[6]) - t_press])
		print("DATA debug_charge_full %.1f: charge_started %.3f s, charge_full %.3f s, fired itself %.3f s (still held: %s); steps %s; charge_level_changed %s; moves %s" % [
			full, t_start, t_full, t_fire, still_down, steps, levels, _ids()])
		check(absf(t_full - full) <= 1.5 / 120.0, "full at %.1f s (%.3f)" % [full, t_full])
		check(absf(t_fire - full - Tuning.R8_CHARGE_HOLD_AT_FULL) <= 1.5 / 120.0 and still_down,
			"it held %.1f s at full and fired itself with the button still down (%.3f)" % [Tuning.R8_CHARGE_HOLD_AT_FULL, t_fire])
		check(full_flag[1] and not full_flag[0], "is_charge_full() turns true with charge_full")
		check(_active.size() == 1 and _active[0][0] == &"front_kick" and _active[0][2], "one charged front kick, nothing on the late release")
		var t_half := Tuning.R8_TAP_MAX + 0.5 * (full - Tuning.R8_TAP_MAX)
		check(steps.size() == 2 and is_equal_approx(steps[0], 0.5) and is_equal_approx(steps[1], 1.0) and levels.size() == 2
			and int(levels[0][0]) == 1 and absf(float(levels[0][1]) - t_half) <= 1.5 / 120.0
			and int(levels[1][0]) == 2 and absf(float(levels[1][1]) - full) <= 1.5 / 120.0,
			"the front kick's steps [0.5, 1.0] (its launch at 1.0, padded): charge_level_changed 1 at c = 0.5, 2 at full")
	Tuning.debug_charge_full = 1.0

	print("1. steps per move (get_charge_steps while charging; at least two, ending at 1.0; debug_launch_step)")
	var want_steps := {&"jab": [0.5, 1.0], &"cross": [0.5, 1.0], &"hook": [0.5, 1.0], &"leg_kick": [0.5, 1.0],
		&"gut_punch": [0.5, 1.0], &"uppercut": [(Tuning.R8_AIR_FOLLOW_MIN_LIFT - 0.8) / 1.7, 1.0],
		&"front_kick": [0.5, 1.0], &"roundhouse": [0.5, 1.0]}
	var got_steps := {}
	for spec: Array in [[&"punch", &"jab"], [&"leg_kick", &"leg_kick"], [&"gut_punch", &"gut_punch"],
			[&"uppercut", &"uppercut"], [&"front_kick", &"front_kick"], [&"roundhouse", &"roundhouse"]]:
		await _fresh()
		Input.action_press(spec[0])
		await wait_until(func() -> bool: return _p.combat.is_charging(), 1.0)
		got_steps[spec[1]] = _p.combat.get_charge_steps()
		Input.action_release(spec[0])
	for id: StringName in got_steps:
		var w: Array = want_steps[id]
		var g: Array = got_steps[id]
		var same := g.size() == w.size()
		for i in mini(g.size(), w.size()):
			same = same and absf(float(g[i]) - float(w[i])) < 1e-3
		check(same, "%s steps %s (want %s)" % [id, g, w])
	Tuning.debug_launch_step = 0.5
	await _fresh()
	Input.action_press(&"front_kick")
	await wait_until(func() -> bool: return _p.combat.is_charging(), 1.0)
	var fk_steps := _p.combat.get_charge_steps()
	Input.action_release(&"front_kick")
	Tuning.debug_launch_step = 1.0
	check(fk_steps.size() == 2 and is_equal_approx(fk_steps[0], 0.5) and is_equal_approx(fk_steps[1], 1.0),
		"debug_launch_step 0.5: the front kick's launch step c = 0.5, then 1.0 (%s)" % [fk_steps])
	Tuning.debug_launch_step = 0.3
	await _fresh()
	Input.action_press(&"front_kick")
	await wait_until(func() -> bool: return _p.combat.is_charging(), 1.0)
	var fk3_steps := _p.combat.get_charge_steps()
	Input.action_release(&"front_kick")
	Tuning.debug_launch_step = 1.0
	check(fk3_steps.size() == 2 and is_equal_approx(fk3_steps[0], 0.3) and is_equal_approx(fk3_steps[1], 1.0),
		"debug_launch_step 0.3: the front kick's steps [0.3, 1.0] (%s)" % [fk3_steps])
	await _fresh()

	print("1. a buffered press still held when it starts charges (c counts from its press)")
	await _fresh()
	await tap_input(&"front_kick")
	await wait_until(func() -> bool: return _p.combat.is_attack_active(), 1.0)
	Input.action_press(&"leg_kick")  # active frames: buffered, held through the recovery and on
	var t_buf := TimeDirector.now()
	await wait_until(func() -> bool: return _p.combat.is_charging(), 1.5)
	var buf_move := _p.combat.get_charge_move()
	var buf_start := first_time(&"charge_started") - t_buf
	await wait_real(maxf(0.6 - (TimeDirector.now() - t_buf), 0.0))
	var buf_c := _p.combat.get_charge()
	Input.action_release(&"leg_kick")
	print("  buffered leg kick: charging %s, charge_started %.3f s after its press (when the front kick ended), c %.3f at 0.6 s" % [
		buf_move, buf_start, buf_c])
	check(buf_move == &"leg_kick" and buf_start >= Tuning.R8_TAP_MAX and absf(buf_c - 0.47) <= C_TOL,
		"the buffered leg kick starts as a charge, its c counted from its press (0.47 at 0.6 s)")
	await _fresh()

	print("4. walking while charging")
	var walk := await _walk_speed(false)
	var charge_walk := await _walk_speed(true)
	print("DATA walk %.2f m/s, walking while charging %.2f m/s (x%.2f, want x%.2f)" % [walk, charge_walk,
		charge_walk / maxf(walk, 0.01), Tuning.R8_CHARGE_WALK_MULT])
	check(walk > 1.0 and absf(charge_walk / walk - Tuning.R8_CHARGE_WALK_MULT) <= 0.05, "walk at half speed while charging")

	print("4. the release glides R8_CHARGE_LUNGE")
	for spec: Array in [[4.5, 0.27, false], [6.9, 2.0, true]]:
		var r: Dictionary = await _glide_trial(spec[0], spec[1])
		var want := lerpf(Tuning.R8_CHARGE_LUNGE.x, Tuning.R8_CHARGE_LUNGE.y, float(r["c"]))
		print("DATA target %.1f m, c %.3f: glided %.2f m (lunge %.2f m), the strike %s" % [spec[0], r["c"], r["glide"], want,
			"landed" if r["hit"] else "missed"])
		check(absf(float(r["glide"]) - want) <= 0.1 and absf(float(r["glide"]) - (6.0 if spec[2] else 3.0)) <= 0.15,
			"c = %d: the release glides %.0f m (%.2f)" % [1 if spec[2] else 0, 6.0 if spec[2] else 3.0, r["glide"]])
		check(r["hit"], "and the charged strike lands on the target")

	print("4. a hit on the charging player cancels the charge")
	await _fresh()
	_move_to_fresh_ground()
	var e := spawn(&"grunt", _p.global_position + Vector3(0, 0, -1.3), Vector3.BACK)
	await ticks(15)
	await _fresh()
	Input.action_press(&"punch")
	await wait_until(func() -> bool: return _p.combat.is_charging(), 1.0)
	check(_p.combat.get_charge_target() == e, "get_charge_target() is the grunt picked at the press")
	e.combat.start_enemy_attack(&"e_jab", 0.5)
	var cancelled := await wait_until(func() -> bool: return not events_of(&"charge_cancelled").is_empty(), 1.5)
	var ev: Array = events_of(&"charge_cancelled")[0] if cancelled else []
	var n_active := _active.size()
	await wait_real(0.2)
	Input.action_release(&"punch")
	await wait_real(0.6)
	print("  the grunt's jab landed %d time(s); charge_cancelled %s; strikes after the release %d" % [
		hits_on(_p).size(), [ev[2], ev[3]] if cancelled else [], _active.size() - n_active])
	check(cancelled and ev[1] == _p and ev[2] == &"jab" and ev[3] == &"hit" and not _p.combat.is_charging()
		and _p.combat.get_charge_target() == null, "charge_cancelled(player, jab, &\"hit\"); no charge target after it")
	check(_active.size() == n_active and events_of(&"charge_released").is_empty(), "no strike on the release")
	e.queue_free()
	release_inputs()
	done()

func _ids() -> Array:
	return _active.map(func(a: Array) -> StringName: return a[0])

func _strike_levels() -> Array:
	return events_of(&"strike_started").filter(func(e: Array) -> bool: return e[1] == _p).map(
		func(e: Array) -> int: return int(e[5]))

## Idle, the chain dropped, records and events cleared.
func _fresh() -> void:
	release_inputs()
	await wait_until(func() -> bool: return not _p.combat.is_attacking() and _p.can_act(), 3.0)
	await wait_until(func() -> bool: return _p.combat.get_chain_count() == 0, 2.0)
	# Round 9: the punch string is back at the jab only after R9_STRING_RESET idle.
	await wait_until(func() -> bool: return _p.combat.get_string_index() == 0, Tuning.R9_STRING_RESET + 0.5)
	await ticks(2)
	_active.clear()
	_starts.clear()
	clear_events()

func _move_to_fresh_ground() -> void:
	_x += 25.0
	_p.teleport_to(Vector3(_x, 0, 0), Vector3.FORWARD)
	await ticks(2)

## Steady walking speed forward (W), optionally while charging the punch (no target).
func _walk_speed(charging: bool) -> float:
	await _fresh()
	await _move_to_fresh_ground()
	if charging:
		Input.action_press(&"punch")
		await wait_until(func() -> bool: return _p.combat.is_charging(), 1.0)
	Input.action_press(&"move_forward")
	await wait_real(0.4)
	var p0 := _p.global_position
	var t0 := TimeDirector.now()
	await wait_real(0.4)
	var ok := not charging or _p.combat.is_charging()
	var v := Vector2(_p.global_position.x - p0.x, _p.global_position.z - p0.z).length() / (TimeDirector.now() - t0)
	Input.action_release(&"move_forward")
	if charging:
		Input.action_release(&"punch")
	await _fresh()
	return v if ok else -1.0

## A grunt `dist` m ahead; hold the punch `hold` s (2 s: it fires itself at
## full) and measure the glide from the release to the startup.
func _glide_trial(dist: float, hold: float) -> Dictionary:
	await _fresh()
	await _move_to_fresh_ground()
	var g := spawn(&"grunt", _p.global_position + Vector3(0, 0, -dist), Vector3.BACK)
	await ticks(15)
	await _fresh()
	Input.action_press(&"punch")
	var t0 := TimeDirector.now()
	var at := [Vector3.INF, Vector3.INF]
	while TimeDirector.now() - t0 < hold and events_of(&"charge_released").is_empty():
		await get_tree().physics_frame
	if events_of(&"charge_released").is_empty():
		Input.action_release(&"punch")
	await wait_until(func() -> bool: return not events_of(&"charge_released").is_empty(), 0.5)
	at[0] = _p.global_position
	var c := float(_p.combat.get_strike_debug()["strike_c"])
	await wait_until(func() -> bool: return _p.combat.is_gliding(), 0.2)
	await wait_until(func() -> bool: return not _p.combat.is_gliding(), 1.5)
	at[1] = _p.global_position
	Input.action_release(&"punch")
	await wait_until(func() -> bool: return not hits_on(g).is_empty(), 0.6)
	var hit := not hits_on(g).is_empty() and hits_on(g)[0].charged
	await _fresh()
	g.queue_free()
	return {"c": c, "glide": Vector2(at[1].x - at[0].x, at[1].z - at[0].z).length(), "hit": hit}
