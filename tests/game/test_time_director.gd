extends Node
## TimeDirector: priority stack, refusal of lower priority, budget, KO exemption,
## easing back, reset. Real-time based, so the test waits on real timers.

var _fails := 0

func _ready() -> void:
	for i in 10:
		await get_tree().process_frame
	await _run()
	print("TEST test_time_director: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what, "  (scale=%.3f audio=%.3f)" % [Engine.time_scale, AudioServer.playback_speed_scale])

## Wait on the real clock (a SceneTreeTimer created mid-frame would consume
## that frame's delta, which is large right after startup).
func _wait(sec: float) -> void:
	var until := TimeDirector.now() + sec
	while TimeDirector.now() < until:
		await get_tree().process_frame

func _near(a: float, b: float, eps := 0.02) -> bool:
	return absf(a - b) <= eps

func _run() -> void:
	TimeDirector.reset()
	_check(_near(Engine.time_scale, 1.0) and _near(AudioServer.playback_speed_scale, 1.0), "starts at 1.0")

	# Stack: a KO on top of a dodge restores the dodge's scale, not 1.0.
	_check(TimeDirector.request_slowmo(0.3, 1.0, TimeDirector.PRIO_DODGE), "dodge request granted")
	_check(_near(Engine.time_scale, 0.3), "dodge applies 0.3 instantly")
	_check(_near(AudioServer.playback_speed_scale, 0.3), "audio follows time scale")
	_check(TimeDirector.request_slowmo(0.2, 0.2, TimeDirector.PRIO_KO), "KO request on top granted")
	_check(_near(Engine.time_scale, 0.2), "KO applies 0.2")
	_check(TimeDirector.get_active_priority() == TimeDirector.PRIO_KO, "KO is the active priority")
	_check(not TimeDirector.request_slowmo(0.25, 0.3, TimeDirector.PRIO_WALL_BREAK), "wall break refused while KO active")
	_check(not TimeDirector.request_slowmo(0.35, 0.3, TimeDirector.PRIO_BIG_LAUNCH), "big launch refused while KO active")
	await _wait(0.2 + Tuning.SLOWMO_EASE + 0.08)
	_check(_near(Engine.time_scale, 0.3), "KO ended: dodge scale 0.3 restored (not 1.0)")
	_check(TimeDirector.get_active_priority() == TimeDirector.PRIO_DODGE, "dodge active again")
	await _wait(0.75)
	_check(TimeDirector.get_active_priority() == 0, "dodge ended")
	_check(Engine.time_scale > 0.3, "easing back up after the last request")
	await _wait(Tuning.SLOWMO_EASE + 0.05)
	_check(_near(Engine.time_scale, 1.0), "back to 1.0 after ease")

	# Ease: going faster takes SLOWMO_EASE, not one frame.
	TimeDirector.reset()
	_check(TimeDirector.request_slowmo(0.25, 0.1, TimeDirector.PRIO_WALL_BREAK), "wall break granted")
	await _wait(0.1 + Tuning.SLOWMO_EASE * 0.4)
	_check(Engine.time_scale > 0.26 and Engine.time_scale < 0.99, "mid-ease scale is between (%.2f)" % Engine.time_scale)

	# Budget: 15% of 10 s = 1.5 s of non-KO slow motion.
	TimeDirector.reset()
	var budget := Tuning.SLOWMO_BUDGET_FRACTION * Tuning.SLOWMO_BUDGET_WINDOW
	_check(not TimeDirector.request_slowmo(0.3, budget + 0.1, TimeDirector.PRIO_DODGE), "single request over budget refused")
	_check(_near(Engine.time_scale, 1.0), "refused request leaves scale at 1.0")
	_check(TimeDirector.request_slowmo(0.35, 0.5, TimeDirector.PRIO_BIG_LAUNCH), "0.5 s granted (1)")
	await _wait(0.55)
	_check(TimeDirector.request_slowmo(0.35, 0.5, TimeDirector.PRIO_BIG_LAUNCH), "0.5 s granted (2)")
	await _wait(0.55)
	_check(TimeDirector.request_slowmo(0.35, 0.45, TimeDirector.PRIO_BIG_LAUNCH), "0.45 s granted (3), total 1.45 s")
	await _wait(0.5)
	_check(not TimeDirector.request_slowmo(0.3, 0.25, TimeDirector.PRIO_DODGE), "4th request refused: budget spent")
	_check(not TimeDirector.request_slowmo(0.25, 0.35, TimeDirector.PRIO_WALL_BREAK), "wall break also refused by budget")
	_check(TimeDirector.get_budget_used() > budget - 0.1, "budget used reported (%.2f s)" % TimeDirector.get_budget_used())

	# KO ignores the budget.
	_check(TimeDirector.request_slowmo(Tuning.KO_SLOWMO.x, 0.3, TimeDirector.PRIO_KO), "KO ignores the budget")
	_check(_near(Engine.time_scale, Tuning.KO_SLOWMO.x), "KO scale applied")

	# reset() returns to 1.0 at once.
	TimeDirector.reset()
	_check(_near(Engine.time_scale, 1.0) and _near(AudioServer.playback_speed_scale, 1.0), "reset returns to 1.0")
	_check(TimeDirector.get_active_priority() == 0 and TimeDirector.get_budget_used() < 0.001, "reset clears stack and budget")
	_check(TimeDirector.request_slowmo(0.3, 0.25, TimeDirector.PRIO_DODGE), "after reset a dodge is granted again")
	TimeDirector.reset()

	# Real-time clock keeps running in slow motion.
	TimeDirector.request_slowmo(0.2, 0.3, TimeDirector.PRIO_KO)
	var t0 := TimeDirector.now()
	await _wait(0.2)
	_check(TimeDirector.now() - t0 > 0.18, "now() is real time during slow motion")
	var fd := TimeDirector.frame_delta()
	_check(fd > 0.0 and fd <= 0.1, "frame_delta() is the unscaled frame time in slow motion (%.4f s)" % fd)
	TimeDirector.reset()

	# --- Focus (Upgrade 2): the world slows, the player does not ----------------
	var fs := Tuning.FOCUS_SCALE
	var changes: Array = []
	TimeDirector.focus_changed.connect(func(on: bool) -> void: changes.append(on))
	_check(not TimeDirector.is_focus_active() and is_equal_approx(TimeDirector.player_time_factor(), 1.0), "no Focus: player factor 1")
	_check(TimeDirector.begin_focus(), "begin_focus granted")
	_check(TimeDirector.is_focus_active() and _near(Engine.time_scale, fs), "Focus drops the world to %.2f (%.2f)" % [fs, Engine.time_scale])
	_check(_near(TimeDirector.player_time_factor(), 1.0 / fs, 0.01), "player factor = 1/scale (%.3f)" % TimeDirector.player_time_factor())
	_check(_near(TimeDirector.player_delta(0.1), 0.1 / fs, 0.002), "player_delta(0.1) = %.4f" % TimeDirector.player_delta(0.1))
	_check(_near(TimeDirector.player_delta(1.0 / 120.0) * Engine.time_scale, 1.0 / 120.0, 0.0001), "player moves a real-time step per tick")
	await _wait(0.6)
	_check(TimeDirector.get_budget_used() < 0.001, "Focus does not use the slow-motion budget")
	# Stacking: a slower request during Focus wins; the player stays real time.
	_check(TimeDirector.request_slowmo(Tuning.WALL_BREAK_SLOWMO.x, 0.3, TimeDirector.PRIO_WALL_BREAK), "wall break during Focus granted")
	_check(_near(Engine.time_scale, minf(fs, Tuning.WALL_BREAK_SLOWMO.x)), "world at the slower scale (%.2f)" % Engine.time_scale)
	_check(_near(TimeDirector.player_time_factor() * Engine.time_scale, 1.0, 0.01), "player still real time under the stacked scale")
	await _wait(0.3 + Tuning.SLOWMO_EASE + 0.05)
	_check(_near(Engine.time_scale, fs), "wall break over: back to the Focus scale (%.2f)" % Engine.time_scale)
	# A faster request during Focus does not speed the world up.
	TimeDirector.request_slowmo(0.5, 0.3, TimeDirector.PRIO_BIG_LAUNCH)
	_check(_near(Engine.time_scale, fs), "a 0.5x request does not lift the Focus scale")
	await _wait(0.4)
	TimeDirector.end_focus()
	_check(not TimeDirector.is_focus_active(), "end_focus")
	_check(TimeDirector.player_time_factor() > 1.01, "player kept real time while the world eases back")
	await _wait(Tuning.SLOWMO_EASE + 0.05)
	_check(_near(Engine.time_scale, 1.0) and _near(TimeDirector.player_time_factor(), 1.0), "after the ease: world 1.0, player factor 1")
	# The KO ends Focus and Focus cannot start during a KO.
	TimeDirector.begin_focus()
	TimeDirector.request_slowmo(Tuning.KO_SLOWMO.x, 0.3, TimeDirector.PRIO_KO)
	_check(not TimeDirector.is_focus_active(), "a KO ends Focus")
	_check(_near(TimeDirector.player_time_factor(), 1.0), "the player slows with the KO")
	_check(not TimeDirector.begin_focus(), "Focus refused during a KO")
	TimeDirector.reset()
	TimeDirector.begin_focus()
	TimeDirector.reset()
	_check(not TimeDirector.is_focus_active() and _near(Engine.time_scale, 1.0), "reset ends Focus")
	_check(changes.size() >= 4 and changes[0] == true and changes[1] == false, "focus_changed signals (%s)" % str(changes))
