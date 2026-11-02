extends "res://tests/input/input_test_base.gd"
## Focus mode (Round 5, Feel Reference: Focus) against the real TimeDirector:
## the Focus button is a press; it needs a full bar and costs it
## (Tuning.FOCUS_MODE_COST); the world runs at Tuning.FOCUS_SCALE for
## Tuning.FOCUS_MODE_TIME s of real time (a pause does not count); a press while
## it runs does nothing; it ends early on a KO slow motion
## (TimeDirector.focus_changed), a knockdown, a launch and death; nothing refills
## during it; kills give no Focus (the older income is gone); setting
## fighter.focus (J's wave start) emits focus_changed; focus_started / ended.

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	await ticks(30)
	if not TimeDirector.has_method(&"begin_focus"):
		check(false, "TimeDirector has begin_focus()")
		done()
		return

	# --- Setting focus (wave start) emits focus_changed. --------------------------
	clear_events()
	p.focus = 1.0
	p.focus = 2.0
	check(count_events(&"focus_changed") >= 1 and is_equal_approx(last_event(&"focus_changed")[2], 2.0),
		"assigning focus emits GameEvents.focus_changed")
	p.focus = 9.0
	check(is_equal_approx(p.focus, Tuning.FOCUS_MAX), "focus is capped at %.0f bars" % Tuning.FOCUS_MAX)

	# --- Less than a bar: nothing. ---------------------------------------------------
	clear_events()
	p.focus = Tuning.FOCUS_MODE_COST - 0.05
	await _tap(&"focus")
	check(not p.is_focusing() and count_events(&"focus_started") == 0, "%.2f bars: Focus mode does not start" % p.focus)
	check(not TimeDirector.is_focus_active() and Engine.time_scale > 0.99, "world at normal speed")

	# --- A full bar: 1 bar, 0.3x for 2.0 s of real time. ----------------------------
	p.focus = 1.5
	await _tap(&"focus")
	check(p.is_focusing() and count_events(&"focus_started") == 1, "1.5 bars: Focus mode starts (focus_started)")
	check(is_equal_approx(p.focus, 0.5), "it cost one bar (%.2f left)" % p.focus)
	check(TimeDirector.is_focus_active() and near(Engine.time_scale, Tuning.FOCUS_SCALE, 0.02),
		"world at %.2fx" % Engine.time_scale)
	var t0 := last_event(&"focus_started")[4] as float
	# A press while it runs does nothing (no second bar, no restart).
	await ticks(30)
	p.focus = 2.0
	await _tap(&"focus")
	check(is_equal_approx(p.focus, 2.0) and count_events(&"focus_started") == 1, "a press during Focus mode does nothing")
	await wait_until(func() -> bool: return not p.is_focusing(), 600)
	var lasted := TimeDirector.now() - t0
	check(absf(lasted - Tuning.FOCUS_MODE_TIME) <= 1.5 / 120.0,
		"Focus mode lasted %.3f real s (want %.1f)" % [lasted, Tuning.FOCUS_MODE_TIME])
	check(count_events(&"focus_ended") == 1 and not TimeDirector.is_focus_active(), "focus_ended; TimeDirector left Focus")
	await wait_until(func() -> bool: return Engine.time_scale > 0.99, 240)
	check(Engine.time_scale > 0.99, "the world eases back to 1x")

	# --- Holding the button does not chain a second Focus mode. ----------------------
	clear_events()
	p.focus = 3.0
	press(&"focus")
	await ticks(2)
	check(p.is_focusing(), "pressed and held: Focus mode on")
	await wait_until(func() -> bool: return not p.is_focusing(), 600)
	await ticks(30)
	check(not p.is_focusing() and count_events(&"focus_started") == 1 and is_equal_approx(p.focus, 2.0),
		"still held after it ended: no second Focus mode, one bar spent")
	release(&"focus")
	await ticks(2)
	await wait_until(func() -> bool: return Engine.time_scale > 0.99, 240)

	# --- A pause does not use up Focus mode's time. -------------------------------------
	clear_events()
	await _tap(&"focus")
	check(p.is_focusing(), "Focus mode on again")
	await ticks(60)
	var left := p.get_focus_time_left()
	process_mode = Node.PROCESS_MODE_ALWAYS
	p.process_mode = Node.PROCESS_MODE_PAUSABLE
	get_tree().paused = true
	var tp := TimeDirector.now()
	while TimeDirector.now() - tp < 3.0:
		await get_tree().physics_frame
	get_tree().paused = false
	await ticks(1)
	check(p.is_focusing() and absf(p.get_focus_time_left() - left) < 0.03,
		"3 s paused: Focus mode time %.3f -> %.3f s" % [left, p.get_focus_time_left()])

	# --- A KO slow motion ends it on TimeDirector's side. --------------------------------
	clear_events()
	TimeDirector.request_slowmo(0.2, 0.3, TimeDirector.PRIO_KO)
	await ticks(1)
	check(not p.is_focusing() and count_events(&"focus_ended") == 1, "KO slow motion ends Focus mode (focus_ended)")
	TimeDirector.reset()
	await ticks(5)

	# --- A knockdown ends it. --------------------------------------------------------------
	clear_events()
	p.focus = 2.0
	await _tap(&"focus")
	check(p.is_focusing(), "Focus mode on before the knockdown")
	p.knockdown(Vector3.FORWARD, Bones.CHEST)
	await ticks(2)
	check(not p.is_focusing() and count_events(&"focus_ended") == 1, "a knockdown ends Focus mode")
	await _tap(&"focus")
	check(not p.is_focusing(), "no Focus mode while down")
	await wait_until(func() -> bool: return p.can_act(), 1500)
	await wait_until(func() -> bool: return Engine.time_scale > 0.99, 240)
	await ticks(10)

	# --- Nothing refills during it; kills give nothing at all. ----------------------------
	var g1 := spawn_dummy(&"grunt", Vector3(6, 0, -6), Vector3.BACK)
	await ticks(5)
	p.focus = 1.0
	var info := HitInfo.new()
	info.attacker = p
	info.victim = g1
	g1.apply_damage(99999.0, &"test", info)
	await ticks(1)
	check(is_equal_approx(p.focus, 1.0), "a kill by the player gives no Focus (%.3f)" % p.focus)
	p.focus = 2.0
	await _tap(&"focus")
	check(p.is_focusing(), "Focus mode on")
	var f_in := p.focus
	p.add_focus(0.34, &"parry")
	p.add_focus(0.25, &"launch")
	p.add_focus(0.5, &"wall_break")
	check(is_equal_approx(p.focus, f_in), "add_focus during Focus mode adds nothing (%.2f)" % p.focus)
	p.add_focus(-0.5)
	check(is_equal_approx(p.focus, f_in - 0.5), "spending still works during Focus mode")

	# --- Death ends it. -----------------------------------------------------------------
	clear_events()
	p.apply_damage(99999.0, &"test")
	await ticks(2)
	check(not p.is_focusing() and count_events(&"focus_ended") == 1, "death ends Focus mode")
	done()

func _tap(action: StringName) -> void:
	press(action)
	await ticks(1)
	release(action)
	await ticks(1)
