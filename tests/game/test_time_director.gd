extends Node
## TimeDirector, Round 5 (Feel Reference: Time, in code + Slow-time table):
## the table's scales and lengths, strongest-wins (never stacking: the F6
## check), the 1 s cooldown and the rows that ignore it, per-row ease, Focus,
## KO rows, the GameEvents triggers, the player's real time, legacy
## request_slowmo, audio, pause and reset. Real-time based: waits on now().

var _fails := 0

## Stand-in for a world node that reports a Destructible-style kind.
class KindNode:
	extends Node3D
	var kind: StringName = &"panel"

func _ready() -> void:
	for i in 10:
		await get_tree().process_frame
	await _run()
	TimeDirector.reset()
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

func _row(event: StringName) -> Dictionary:
	return Tuning.SLOW_TIME[event]

## Wait until the time scale is back to 1.0 and the cooldown is over.
func _settle() -> void:
	TimeDirector.reset()
	await get_tree().process_frame

func _run() -> void:
	await _settle()
	_check(_near(Engine.time_scale, 1.0) and _near(AudioServer.playback_speed_scale, 1.0), "starts at 1.0")
	_check(_near(TimeDirector.player_time_factor(), 1.0), "player factor 1 at normal speed")

	# --- Every row: scale, length, ease, player time -----------------------------------
	for ev: StringName in [&"parry", &"teleport", &"wall_break", &"sever", &"last_kill", &"player_death"]:
		await _settle()
		var row := _row(ev)
		var t0 := TimeDirector.now()
		_check(TimeDirector.request(ev), "%s granted" % ev)
		_check(_near(Engine.time_scale, row["scale"], 0.001) and _near(AudioServer.playback_speed_scale, row["scale"], 0.001),
			"%s: world and audio at %.2fx at once" % [ev, row["scale"]])
		var ko := TimeDirector.KO_EVENTS.has(ev)
		if ko:
			_check(_near(TimeDirector.player_time_factor(), 1.0), "%s is a KO: the player slows with the world" % ev)
		else:
			_check(_near(TimeDirector.player_time_factor() * Engine.time_scale, 1.0, 0.001),
				"%s: the player keeps real time (factor %.2f)" % [ev, TimeDirector.player_time_factor()])
		await _wait(float(row["time"]) - 0.03)
		_check(_near(Engine.time_scale, row["scale"], 0.001), "%s holds %.2fx for %.2f s" % [ev, row["scale"], row["time"]])
		await _wait(0.03 + float(row["ease"]) * 0.5)
		var mid := Engine.time_scale
		_check(mid > float(row["scale"]) + 0.02 and mid < 0.99, "%s eases back (%.2f at half its %.2f s ease)" % [ev, mid, row["ease"]])
		await _wait(float(row["ease"]) * 0.5 + 0.03)
		_check(_near(Engine.time_scale, 1.0, 0.001), "%s: back to 1.0 after %.2f s real" % [ev, TimeDirector.now() - t0])
		_check(_near(TimeDirector.player_time_factor(), 1.0), "%s over: player factor 1" % ev)

	# --- F6: two requests at once -> only the strongest applies -----------------------------
	await _settle()
	var lowest := 1.0
	var highest := 0.0
	_check(TimeDirector.request(&"teleport") and TimeDirector.request(&"wall_break"), "teleport + wall break on the same frame: both granted")
	var s_tw := Engine.time_scale
	_check(_near(s_tw, 0.25, 0.001), "F6 teleport (0.30x) + wall break (0.25x) at once: world %.3fx (product would be %.3fx)" % [s_tw, 0.3 * 0.25])
	var until := TimeDirector.now() + 0.6
	while TimeDirector.now() < until:
		await get_tree().process_frame
		lowest = minf(lowest, Engine.time_scale)
	_check(lowest >= 0.25 - 0.0005, "F6 never below the strongest request over its run (min %.3fx)" % lowest)

	await _settle()
	_check(TimeDirector.request(&"parry"), "parry granted")
	_check(TimeDirector.request(&"wall_break"), "wall break on the parry's frame joins (the cooldown never cancels a same-frame event)")
	_check(_near(Engine.time_scale, 0.25, 0.001), "F6 parry (0.50x) + wall break (0.25x): world %.3fx = the strongest" % Engine.time_scale)
	await _wait(_row(&"parry")["time"] + _row(&"parry")["ease"] + 0.02)
	_check(_near(Engine.time_scale, 0.25, 0.001), "parry over, wall break still holds 0.25x (%.3f)" % Engine.time_scale)

	await _settle()
	TimeDirector.request(&"wall_break")
	TimeDirector.request(&"wall_break")
	_check(_near(Engine.time_scale, 0.25, 0.001), "F6 two wall breaks never stack (%.3fx, not %.4fx)" % [Engine.time_scale, 0.25 * 0.25])

	await _settle()
	TimeDirector.request(&"sever")
	await _wait(0.1)
	_check(TimeDirector.request(&"last_kill"), "a stronger request mid-way cuts in")
	_check(_near(Engine.time_scale, 0.2, 0.001), "F6 sever (0.30x) then last kill (0.20x): world %.3fx" % Engine.time_scale)
	# Weaker request fully covered by a stronger one: refused, no cooldown started.
	await _settle()
	TimeDirector.request(&"last_kill")
	var refused0 := TimeDirector.get_refused()
	_check(not TimeDirector.request(&"parry"), "a parry inside the last kill's 0.20x never shows: refused")
	_check(TimeDirector.get_refused() == refused0 + 1 and TimeDirector.get_cooldown_left() < 0.001, "and it starts no cooldown")
	# Sampled: the scale is always the minimum of the rows, never a product.
	await _settle()
	TimeDirector.request(&"wall_break")
	await _wait(0.2)
	TimeDirector.request(&"teleport")
	highest = 0.0
	lowest = 1.0
	until = TimeDirector.now() + 0.8
	while TimeDirector.now() < until:
		await get_tree().process_frame
		lowest = minf(lowest, Engine.time_scale)
	print("  F6 measured: wall break at t=0, teleport at t=0.2: min world scale %.3fx over 0.8 s (strongest row 0.250x)" % lowest)
	_check(lowest >= 0.25 - 0.0005, "staggered requests never go below the strongest row")

	# --- Cooldown: 1 s between cooldown rows, teleport / last kill / death / Focus ignore it ---
	await _settle()
	var wb := _row(&"wall_break")
	_check(TimeDirector.request(&"wall_break"), "wall break granted")
	await _wait(float(wb["time"]) + float(wb["ease"]) + 0.05)
	_check(_near(Engine.time_scale, 1.0, 0.001), "wall break eased out")
	var left := TimeDirector.get_cooldown_left()
	_check(left > 0.85 and left <= Tuning.SLOW_TIME_COOLDOWN + 0.001, "cooldown running (%.2f s left of %.1f)" % [left, Tuning.SLOW_TIME_COOLDOWN])
	_check(not TimeDirector.request(&"parry"), "parry 0.05 s after the wall break eased out: refused (cooldown)")
	_check(not TimeDirector.request(&"sever"), "sever in the gap: refused (cooldown)")
	_check(not TimeDirector.request_slowmo(0.25, 0.35, TimeDirector.PRIO_WALL_BREAK), "legacy wall break in the gap: refused (cooldown)")
	_check(_near(Engine.time_scale, 1.0, 0.001), "refused requests leave the world at 1.0")
	_check(TimeDirector.request(&"teleport"), "teleport in the gap: granted (never waits on the cooldown)")
	_check(_near(Engine.time_scale, 0.3, 0.001), "teleport applies 0.30x in the gap")
	await _wait(0.3 + 0.15)
	_check(not TimeDirector.request(&"parry"), "the teleport did not reset the gap: parry still refused")
	_check(TimeDirector.begin_focus(), "Focus in the gap: granted")
	TimeDirector.end_focus()
	await _wait(0.2)
	await _wait(maxf(TimeDirector.get_cooldown_left(), 0.0) + 0.02)
	_check(TimeDirector.request(&"parry"), "after the 1 s gap: parry granted")
	await _settle()
	TimeDirector.request(&"parry")
	await _wait(0.4)
	_check(TimeDirector.request(&"last_kill"), "last kill in a parry's gap: granted")
	await _settle()
	TimeDirector.request(&"sever")
	await _wait(0.7)
	_check(TimeDirector.request(&"player_death"), "player death in a sever's gap: granted")

	# --- Focus -------------------------------------------------------------------------------
	await _settle()
	var fs := Tuning.FOCUS_SCALE
	var changes: Array = []
	TimeDirector.focus_changed.connect(func(on: bool) -> void: changes.append(on))
	_check(TimeDirector.begin_focus(), "begin_focus granted")
	_check(TimeDirector.is_focus_active() and _near(Engine.time_scale, fs), "Focus drops the world to %.2f (%.2f)" % [fs, Engine.time_scale])
	_check(TimeDirector.get_active_event() == &"focus", "active event focus")
	_check(_near(TimeDirector.player_time_factor(), 1.0 / fs, 0.01), "player factor = 1/scale (%.3f)" % TimeDirector.player_time_factor())
	_check(_near(TimeDirector.player_delta(0.1), 0.1 / fs, 0.002), "player_delta(0.1) = %.4f" % TimeDirector.player_delta(0.1))
	_check(_near(TimeDirector.player_delta(1.0 / 120.0) * Engine.time_scale, 1.0 / 120.0, 0.0001), "player moves a real-time step per tick")
	_check(not TimeDirector.request(&"parry"), "a parry (0.50x) during Focus never shows: refused")
	_check(TimeDirector.get_cooldown_left() < 0.001, "and starts no cooldown")
	_check(TimeDirector.request(&"wall_break"), "wall break (0.25x) during Focus granted")
	_check(_near(Engine.time_scale, minf(fs, 0.25)), "world at the stronger scale (%.2f)" % Engine.time_scale)
	_check(_near(TimeDirector.player_time_factor() * Engine.time_scale, 1.0, 0.01), "player still real time under the stronger scale")
	await _wait(wb["time"] + wb["ease"] + 0.05)
	_check(_near(Engine.time_scale, fs), "wall break over: back to the Focus scale (%.2f)" % Engine.time_scale)
	TimeDirector.end_focus()
	_check(not TimeDirector.is_focus_active(), "end_focus")
	_check(TimeDirector.player_time_factor() > 1.01, "player kept real time while the world eases back")
	await _wait(float(_row(&"focus")["ease"]) + 0.05)
	_check(_near(Engine.time_scale, 1.0) and _near(TimeDirector.player_time_factor(), 1.0), "after the ease: world 1.0, player factor 1")
	# A KO ends Focus; Focus cannot start during a KO.
	TimeDirector.begin_focus()
	TimeDirector.request(&"last_kill")
	_check(not TimeDirector.is_focus_active(), "the last kill ends Focus")
	_check(_near(TimeDirector.player_time_factor(), 1.0), "the player slows with the last kill")
	_check(not TimeDirector.begin_focus(), "Focus refused during a KO")
	await _settle()
	TimeDirector.begin_focus()
	_check(TimeDirector.request(&"player_death"), "player death during Focus granted (same 0.30x)")
	_check(not TimeDirector.is_focus_active() and TimeDirector.get_active_priority() == TimeDirector.PRIO_KO, "player death ends Focus, reports PRIO_KO")
	await _settle()
	TimeDirector.begin_focus()
	TimeDirector.reset()
	_check(not TimeDirector.is_focus_active() and _near(Engine.time_scale, 1.0), "reset ends Focus")
	_check(changes.size() >= 4 and changes[0] == true and changes[1] == false, "focus_changed signals (%s)" % str(changes))

	# --- GameEvents triggers ------------------------------------------------------------------
	# The handlers are called directly with stand-in nodes (other modules' listeners
	# expect real fighters); the connections themselves are checked first.
	var td: Node = TimeDirector
	for pair: Array in [[GameEvents.parried, td._on_parried], [GameEvents.teleported, td._on_teleported],
			[GameEvents.wall_broken, td._on_wall_broken], [GameEvents.limb_severed, td._on_limb_severed],
			[GameEvents.last_kill, td._on_last_kill], [GameEvents.fighter_died, td._on_fighter_died]]:
		_check((pair[0] as Signal).is_connected(pair[1]), "TimeDirector listens to GameEvents.%s" % (pair[0] as Signal).get_name())
	var fake_player := Node3D.new()
	fake_player.add_to_group(&"player")
	add_child(fake_player)
	var fake_enemy := Node3D.new()
	add_child(fake_enemy)
	var cases: Array = [
		["parried (the player parries)", func() -> void: td._on_parried(fake_player, fake_enemy), 0.5],
		["parried (the Duelist parries the player: no slow motion)", func() -> void: td._on_parried(fake_enemy, fake_player), 1.0],
		["teleported counter (the player)", func() -> void: td._on_teleported(fake_player, Vector3.ZERO, Vector3.ONE, &"counter"), 0.3],
		["teleported counter (an enemy: no slow motion)", func() -> void: td._on_teleported(fake_enemy, Vector3.ZERO, Vector3.ONE, &"counter"), 1.0],
		["teleported pursuit (no slow motion)", func() -> void: td._on_teleported(fake_player, Vector3.ZERO, Vector3.ONE, &"pursuit"), 1.0],
		["wall_broken", func() -> void: td._on_wall_broken(null, Vector3.ZERO, 5000.0, Vector3.FORWARD), 0.25],
		["limb_severed", func() -> void: td._on_limb_severed(fake_enemy, &"arm_l", null), 0.3],
		["last_kill", func() -> void: td._on_last_kill(fake_enemy), 0.2],
		["fighter_died (player)", func() -> void: td._on_fighter_died(fake_player, null), 0.3],
		["fighter_died (enemy, no slow motion)", func() -> void: td._on_fighter_died(fake_enemy, null), 1.0],
	]
	for c: Array in cases:
		await _settle()
		(c[1] as Callable).call()
		_check(_near(Engine.time_scale, float(c[2]), 0.001), "event %s -> %.2fx (%.3f)" % [c[0], c[2], Engine.time_scale])
	# wall_broken also fires for furniture and door frames: only panels and pillars slow time.
	for kind: StringName in [&"panel", &"pillar", &"desk", &"crate", &"jamb", &"lintel"]:
		await _settle()
		var w := KindNode.new()
		w.kind = kind
		add_child(w)
		td._on_wall_broken(w, Vector3.ZERO, 5000.0, Vector3.FORWARD)
		var want := 0.25 if kind in [&"panel", &"pillar"] else 1.0
		_check(_near(Engine.time_scale, want, 0.001), "wall_broken on a %s -> %.2fx (%.3f)" % [kind, want, Engine.time_scale])
		w.queue_free()
	await _settle()
	td._on_fighter_died(fake_player, null)
	_check(TimeDirector.get_active_priority() == TimeDirector.PRIO_KO and TimeDirector.is_ko_active(), "player death reports PRIO_KO")
	fake_player.queue_free()
	fake_enemy.queue_free()

	# --- Legacy request_slowmo -------------------------------------------------------------------
	await _settle()
	_check(TimeDirector.request_slowmo(0.3, 0.25, TimeDirector.PRIO_DODGE), "legacy request granted")
	_check(_near(Engine.time_scale, 0.3), "legacy scale applied")
	_check(TimeDirector.player_time_factor() > 3.0, "legacy non-KO slow motion: player in real time")
	_check(TimeDirector.request_slowmo(0.2, 0.3, TimeDirector.PRIO_KO), "legacy KO granted on top")
	_check(_near(Engine.time_scale, 0.2) and TimeDirector.get_active_priority() == TimeDirector.PRIO_KO, "legacy KO 0.2x, PRIO_KO")
	TimeDirector.begin_focus()
	_check(not TimeDirector.is_focus_active(), "Focus refused during a legacy KO")
	await _settle()
	TimeDirector.begin_focus()
	TimeDirector.request_slowmo(0.2, 0.3, TimeDirector.PRIO_KO)
	_check(not TimeDirector.is_focus_active() and _near(TimeDirector.player_time_factor(), 1.0), "a legacy KO ends Focus; the player slows")

	# --- Real-time clock, pause, reset ------------------------------------------------------------
	await _settle()
	TimeDirector.request(&"last_kill")
	var t0 := TimeDirector.now()
	await _wait(0.2)
	_check(TimeDirector.now() - t0 > 0.18, "now() is real time during slow motion")
	var fd := TimeDirector.frame_delta()
	_check(fd > 0.0 and fd <= 0.1, "frame_delta() is the unscaled frame time in slow motion (%.4f s)" % fd)
	get_tree().paused = true
	await _wait(1.0)
	get_tree().paused = false
	await get_tree().process_frame
	_check(_near(Engine.time_scale, 0.2, 0.001), "1 s of pause does not eat the last kill's 1.0 s (%.2f)" % Engine.time_scale)
	TimeDirector.reset()
	_check(_near(Engine.time_scale, 1.0) and _near(AudioServer.playback_speed_scale, 1.0), "reset returns to 1.0")
	_check(TimeDirector.get_active_priority() == 0 and TimeDirector.get_cooldown_left() < 0.001, "reset clears requests and the cooldown")
