extends "res://tests/input/input_test_base.gd"
## Focus (hold E) against the real TimeDirector: needs Tuning.FOCUS_MIN_START
## bars, drains Tuning.FOCUS_DRAIN bars per real second, ends on release,
## empty meter, launch, a KO slow motion (TimeDirector.focus_changed) and
## death; +Tuning.FOCUS_KILL per kill by the player; focus_started/ended events.

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	await ticks(30)
	if not TimeDirector.has_method(&"begin_focus"):
		check(false, "TimeDirector has begin_focus()")
		done()
		return

	# --- Minimum to start. ----------------------------------------------------
	clear_events()
	p.focus = Tuning.FOCUS_MIN_START - 0.1
	press(&"focus")
	await ticks(3)
	check(not p.is_focusing() and count_events(&"focus_started") == 0, "%.2f bars: Focus does not start" % p.focus)
	check(not TimeDirector.is_focus_active(), "TimeDirector not in Focus")
	release(&"focus")
	await ticks(3)

	p.focus = 1.0
	press(&"focus")
	await ticks(3)
	check(p.is_focusing() and count_events(&"focus_started") == 1, "1 bar: Focus starts (focus_started)")
	check(TimeDirector.is_focus_active(), "TimeDirector in Focus")
	check(near(Engine.time_scale, Tuning.FOCUS_SCALE, 0.05), "world at %.2fx" % Engine.time_scale)

	# --- Drain per real second. -------------------------------------------------
	var f0 := p.focus
	await ticks(Engine.physics_ticks_per_second)  # 1 real second
	var drained := f0 - p.focus
	check(near(drained, Tuning.FOCUS_DRAIN, 0.05), "drains %.3f bars per real second (Tuning %.2f)" % [drained, Tuning.FOCUS_DRAIN])

	# --- Release ends it. -------------------------------------------------------
	release(&"focus")
	await ticks(2)
	check(not p.is_focusing() and count_events(&"focus_ended") == 1, "release ends Focus (focus_ended)")
	check(not TimeDirector.is_focus_active(), "TimeDirector left Focus")
	var left := p.focus
	await ticks(60)
	check(is_equal_approx(left, p.focus), "no drain after Focus ends")
	await wait_until(func() -> bool: return Engine.time_scale > 0.99, 240)

	# --- Empty meter ends it. ---------------------------------------------------
	clear_events()
	p.focus = Tuning.FOCUS_MIN_START
	press(&"focus")
	await ticks(2)
	check(p.is_focusing(), "half a bar starts Focus")
	var t0 := TimeDirector.now()
	await wait_until(func() -> bool: return not p.is_focusing(), 600)
	var lasted := TimeDirector.now() - t0
	var want := Tuning.FOCUS_MIN_START / Tuning.FOCUS_DRAIN
	check(not p.is_focusing() and p.focus <= 1e-4, "meter empty ends Focus (focus %.3f)" % p.focus)
	check(near(lasted, want, 0.05), "half a bar lasts %.2f s (want %.2f)" % [lasted, want])
	check(count_events(&"focus_ended") == 1, "focus_ended on empty")
	release(&"focus")
	await wait_until(func() -> bool: return Engine.time_scale > 0.99, 240)

	# --- Holding on does not restart it; a new press does (with meter). ----------
	p.focus = 2.0
	press(&"focus")
	await ticks(2)
	check(p.is_focusing(), "Focus on again")

	# --- A KO slow motion ends Focus on TimeDirector's side (focus_changed). -----
	clear_events()
	TimeDirector.request_slowmo(0.2, 0.3, TimeDirector.PRIO_KO)
	await ticks(1)
	check(not p.is_focusing() and count_events(&"focus_ended") == 1, "KO slow motion ends Focus (focus_ended)")
	var after_ko := p.focus
	await ticks(30)
	check(is_equal_approx(after_ko, p.focus), "no drain after the KO took over")
	release(&"focus")
	await ticks(2)
	TimeDirector.reset()
	await ticks(5)

	# --- Getting launched ends it. ------------------------------------------------
	clear_events()
	p.focus = 2.0
	press(&"focus")
	await ticks(2)
	check(p.is_focusing(), "Focus on before the launch")
	p.launch(Vector3(0.0, 3.0, 5.0), p.get_center_of_mass(), Bones.CHEST)
	await ticks(2)
	check(not p.is_focusing() and count_events(&"focus_ended") == 1, "launch ends Focus")
	await ticks(10)
	check(not p.is_focusing(), "still holding E while down: no restart")
	press(&"focus")  # (still held)
	release(&"focus")
	await wait_until(func() -> bool: return p.can_act(), 1500)
	await wait_until(func() -> bool: return Engine.time_scale > 0.99, 240)
	await ticks(10)

	# --- Kills by the player give Focus; other deaths do not. --------------------
	var g1 := spawn_dummy(&"grunt", Vector3(6, 0, -6), Vector3.BACK)
	var g2 := spawn_dummy(&"grunt", Vector3(-6, 0, -6), Vector3.BACK)
	await ticks(5)
	p.focus = 1.0
	var info := HitInfo.new()
	info.attacker = p
	info.victim = g1
	g1.apply_damage(99999.0, &"test", info)
	await ticks(1)
	check(near(p.focus, 1.0 + Tuning.FOCUS_KILL, 0.001), "player kill: +%.2f bars (%.3f)" % [Tuning.FOCUS_KILL, p.focus])
	var other := HitInfo.new()
	other.attacker = null
	other.victim = g2
	g2.apply_damage(99999.0, &"test", other)
	await ticks(1)
	check(near(p.focus, 1.0 + Tuning.FOCUS_KILL, 0.001), "environment kill: no Focus")

	# --- Death ends it. -------------------------------------------------------------
	clear_events()
	p.focus = 2.0
	press(&"focus")
	await ticks(2)
	check(p.is_focusing(), "Focus on before death")
	p.apply_damage(99999.0, &"test")
	await ticks(2)
	check(not p.is_focusing() and count_events(&"focus_ended") == 1, "death ends Focus")
	release(&"focus")
	done()
