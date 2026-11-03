extends Node
## TimeDirector, Round 5 table rules under Round 7 (docs/Round 7 — Freeflow
## Combat.md: Hit feel, and the amendment's god path): the table's scales and
## lengths (finisher, teleport, wall break, sever, last kill, player death),
## strongest-wins (never stacking: the F6 check), the 1 s cooldown and the rows
## that ignore it (teleport, last kill, player death), per-row ease, KO rows,
## the GameEvents triggers (the finisher once per player launch payoff, the
## teleport for the player's counter teleport only), the player's real time,
## Focus removed (begin_focus / end_focus / is_focus_active harmless), legacy
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

## Back to 1.0 with no cooldown.
func _settle() -> void:
	TimeDirector.reset()
	await get_tree().process_frame

## A Round 7 player hit (HitInfo.react set) from `attacker` on `victim`.
func _r7_hit(attacker: Node3D, victim: Node3D, react: StringName, move: StringName) -> HitInfo:
	var info := HitInfo.new()
	info.attacker = attacker
	info.victim = victim
	info.move_id = move
	info.react = react
	info.weight = float(Tuning.R7_MOVES[move]["weight"]) if Tuning.R7_MOVES.has(move) else 0.8
	info.payoff = react == &"launch"
	info.tier = HitInfo.Tier.LAUNCH if react == &"launch" else HitInfo.Tier.STAGGER
	return info

func _run() -> void:
	await _settle()
	_check(_near(Engine.time_scale, 1.0) and _near(AudioServer.playback_speed_scale, 1.0), "starts at 1.0")
	_check(_near(TimeDirector.player_time_factor(), 1.0), "player factor 1 at normal speed")

	# --- Every Round 7 row: scale, length, ease, player time ----------------------------
	for ev: StringName in [&"finisher", &"teleport", &"wall_break", &"sever", &"last_kill", &"player_death"]:
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
	_check(TimeDirector.request(&"finisher") and TimeDirector.request(&"wall_break"), "finisher + wall break on the same frame: both granted")
	var s_fw := Engine.time_scale
	_check(_near(s_fw, 0.25, 0.001), "F6 finisher (0.35x) + wall break (0.25x) at once: world %.3fx (product would be %.4fx)" % [s_fw, 0.35 * 0.25])
	var until := TimeDirector.now() + 0.6
	while TimeDirector.now() < until:
		await get_tree().process_frame
		lowest = minf(lowest, Engine.time_scale)
	_check(lowest >= 0.25 - 0.0005, "F6 never below the strongest request over its run (min %.3fx)" % lowest)

	await _settle()
	_check(TimeDirector.request(&"finisher"), "finisher granted")
	_check(TimeDirector.request(&"wall_break"), "wall break on the finisher's frame joins (the cooldown never cancels a same-frame event)")
	_check(_near(Engine.time_scale, 0.25, 0.001), "F6 finisher (0.35x) + wall break (0.25x): world %.3fx = the strongest" % Engine.time_scale)
	await _wait(float(_row(&"finisher")["time"]) + 0.02)
	_check(_near(Engine.time_scale, 0.25, 0.001), "past the finisher's hold, the wall break still holds 0.25x (%.3f)" % Engine.time_scale)

	await _settle()
	_check(TimeDirector.request(&"teleport") and TimeDirector.request(&"wall_break"), "teleport + wall break on the same frame: both granted")
	_check(_near(Engine.time_scale, 0.25, 0.001), "F6 teleport (0.30x) + wall break (0.25x) at once: world %.3fx (product would be %.3fx)" % [Engine.time_scale, 0.3 * 0.25])

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
	_check(not TimeDirector.request(&"finisher"), "a finisher inside the last kill's 0.20x never shows: refused")
	_check(TimeDirector.get_refused() == refused0 + 1 and TimeDirector.get_cooldown_left() < 0.001, "and it starts no cooldown")
	# Sampled: the scale is always the minimum of the rows, never a product.
	await _settle()
	TimeDirector.request(&"wall_break")
	await _wait(0.2)
	TimeDirector.request(&"sever")
	lowest = 1.0
	until = TimeDirector.now() + 0.8
	while TimeDirector.now() < until:
		await get_tree().process_frame
		lowest = minf(lowest, Engine.time_scale)
	print("  F6 measured: wall break at t=0, sever at t=0.2: min world scale %.3fx over 0.8 s (strongest row 0.250x)" % lowest)
	_check(lowest >= 0.25 - 0.0005, "staggered requests never go below the strongest row")

	# --- Cooldown: 1 s between cooldown rows; last kill and player death ignore it ---
	await _settle()
	var wb := _row(&"wall_break")
	_check(TimeDirector.request(&"wall_break"), "wall break granted")
	await _wait(float(wb["time"]) + float(wb["ease"]) + 0.05)
	_check(_near(Engine.time_scale, 1.0, 0.001), "wall break eased out")
	var left := TimeDirector.get_cooldown_left()
	_check(left > 0.85 and left <= Tuning.SLOW_TIME_COOLDOWN + 0.001, "cooldown running (%.2f s left of %.1f)" % [left, Tuning.SLOW_TIME_COOLDOWN])
	_check(not TimeDirector.request(&"finisher"), "finisher 0.05 s after the wall break eased out: refused (cooldown)")
	_check(not TimeDirector.request(&"sever"), "sever in the gap: refused (cooldown)")
	_check(not TimeDirector.request_slowmo(0.25, 0.35, TimeDirector.PRIO_WALL_BREAK), "legacy wall break in the gap: refused (cooldown)")
	_check(_near(Engine.time_scale, 1.0, 0.001), "refused requests leave the world at 1.0")
	_check(TimeDirector.request(&"teleport"), "teleport in the gap: granted (never waits on the cooldown)")
	_check(_near(Engine.time_scale, 0.3, 0.001), "teleport applies 0.30x in the gap")
	await _wait(float(_row(&"teleport")["time"]) + float(_row(&"teleport")["ease"]))
	_check(not TimeDirector.request(&"finisher"), "the teleport did not reset the gap: finisher still refused")
	var left_before := TimeDirector.get_cooldown_left()
	_check(TimeDirector.request(&"last_kill"), "last kill in the gap: granted (never waits on the cooldown)")
	_check(_near(Engine.time_scale, 0.2, 0.001), "last kill applies 0.20x in the gap")
	await _wait(0.1)
	var left_after := TimeDirector.get_cooldown_left()
	_check(left_after <= left_before - 0.08, "the last kill did not restart the gap (%.2f -> %.2f s left)" % [left_before, left_after])
	await _settle()
	TimeDirector.request(&"finisher")
	await _wait(0.4)
	_check(TimeDirector.request(&"player_death"), "player death in a finisher's gap: granted")
	await _settle()
	TimeDirector.request(&"finisher")
	await _wait(_row(&"finisher")["time"] + _row(&"finisher")["ease"] + 0.05)
	_check(not TimeDirector.request(&"finisher"), "a second finisher inside the gap after the first: refused (cooldown row)")
	await _wait(maxf(TimeDirector.get_cooldown_left(), 0.0) + 0.02)
	_check(TimeDirector.request(&"finisher"), "after the 1 s gap: finisher granted")

	# --- Focus is gone (Round 7): the old calls are harmless -------------------------------
	await _settle()
	var changes: Array = []
	var cb := func(on: bool) -> void: changes.append(on)
	TimeDirector.focus_changed.connect(cb)
	_check(not TimeDirector.begin_focus(), "begin_focus() is refused (Focus mode removed)")
	_check(not TimeDirector.is_focus_active(), "is_focus_active() is false")
	_check(_near(Engine.time_scale, 1.0, 0.001), "begin_focus leaves the world at 1.0")
	_check(_near(TimeDirector.player_time_factor(), 1.0, 0.0001), "player_time_factor() is 1.0 outside slow motion")
	_check(_near(TimeDirector.player_delta(0.1), 0.1, 0.0001), "player_delta(0.1) = %.4f outside slow motion" % TimeDirector.player_delta(0.1))
	TimeDirector.end_focus()
	_check(_near(Engine.time_scale, 1.0, 0.001) and changes.is_empty(), "end_focus() does nothing; focus_changed never fires")
	_check(not TimeDirector.request(&"focus"), "request(&\"focus\") is refused")
	TimeDirector.request(&"wall_break")
	TimeDirector.end_focus()
	_check(_near(Engine.time_scale, 0.25, 0.001), "end_focus() never ends other slow motion")
	_check(_near(TimeDirector.player_time_factor() * Engine.time_scale, 1.0, 0.001), "the player still keeps real time in it")
	TimeDirector.focus_changed.disconnect(cb)

	# --- GameEvents triggers ------------------------------------------------------------------
	# The handlers are called directly with stand-in nodes (other modules' listeners
	# expect real fighters); the connections themselves are checked first.
	var td: Node = TimeDirector
	for pair: Array in [[GameEvents.hit_landed, td._on_hit_landed], [GameEvents.teleported, td._on_teleported],
			[GameEvents.wall_broken, td._on_wall_broken], [GameEvents.limb_severed, td._on_limb_severed],
			[GameEvents.last_kill, td._on_last_kill], [GameEvents.fighter_died, td._on_fighter_died]]:
		_check((pair[0] as Signal).is_connected(pair[1]), "TimeDirector listens to GameEvents.%s" % (pair[0] as Signal).get_name())
	var parry_heard := false
	if GameEvents.has_signal(&"parried"):
		for c: Dictionary in GameEvents.get_signal_connection_list(&"parried"):
			parry_heard = parry_heard or (c["callable"] as Callable).get_object() == td
	_check(not parry_heard, "TimeDirector no longer listens to parried (parry is gone)")
	var fake_player := Node3D.new()
	fake_player.add_to_group(&"player")
	add_child(fake_player)
	var fake_enemy := Node3D.new()
	add_child(fake_enemy)
	var cases: Array = [
		["teleported counter (the player)", func() -> void: td._on_teleported(fake_player, Vector3.ZERO, Vector3.ONE, &"counter"), 0.3],
		["teleported counter (an enemy: no slow motion)", func() -> void: td._on_teleported(fake_enemy, Vector3.ZERO, Vector3.ONE, &"counter"), 1.0],
		["teleported pursuit (the player's pursuit: no slow motion)", func() -> void: td._on_teleported(fake_player, Vector3.ZERO, Vector3.ONE, &"pursuit"), 1.0],
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

	# --- Round 7: the finisher, once per launch payoff -------------------------------------------
	var fin := _row(&"finisher")
	var rows := PackedStringArray()
	var finisher_cases: Array = [
		# [what, attacker, react, move, expected requests, expected scale]
		["player launch payoff (roundhouse on lift)", fake_player, &"launch", &"roundhouse", 1, float(fin["scale"])],
		["player launch payoff (front kick on fold)", fake_player, &"launch", &"front_kick", 1, float(fin["scale"])],
		["player knockdown (roundhouse)", fake_player, &"knockdown", &"roundhouse", 0, 1.0],
		["player lift (uppercut)", fake_player, &"lift", &"uppercut", 0, 1.0],
		["player re-pop (jab)", fake_player, &"repop", &"jab", 0, 1.0],
		["player pursuit spike (react spike)", fake_player, &"spike", &"roundhouse", 0, 1.0],
		["enemy launch (an enemy's react launch)", fake_enemy, &"launch", &"roundhouse", 0, 1.0],
		["Round 5 launch tier, no react (thrown body, old source)", fake_player, &"", &"kick", 0, 1.0],
	]
	for c: Array in finisher_cases:
		await _settle()
		var n0 := TimeDirector.get_finisher_requests()
		var g0 := TimeDirector.get_granted()
		var info := _r7_hit(c[1], fake_enemy if c[1] == fake_player else fake_player, c[2], c[3])
		if c[2] == &"":
			info.tier = HitInfo.Tier.HARD_LAUNCH
		td._on_hit_landed(info)
		var dn := TimeDirector.get_finisher_requests() - n0
		var scale := Engine.time_scale
		rows.append("%s: %d request(s), %d granted, world %.2fx" % [c[0], dn, TimeDirector.get_granted() - g0, scale])
		_check(dn == int(c[4]) and _near(scale, float(c[5]), 0.001),
			"%s -> %d finisher request(s), world %.2fx (%d, %.3f)" % [c[0], c[4], c[5], dn, scale])
		if int(c[4]) > 0:
			_check(TimeDirector.get_active_event() == &"finisher" and TimeDirector.player_time_factor() > 2.0,
				"the finisher holds (%s); the player keeps real time (x%.2f)" % [TimeDirector.get_active_event(), TimeDirector.player_time_factor()])
	# One request per payoff: the same hit reported more than once asks once.
	await _settle()
	var once := _r7_hit(fake_player, fake_enemy, &"launch", &"roundhouse")
	var n1 := TimeDirector.get_finisher_requests()
	for i in 3:
		td._on_hit_landed(once)
	_check(TimeDirector.get_finisher_requests() - n1 == 1, "the same launch payoff reported 3 times asks once (%d)" % (TimeDirector.get_finisher_requests() - n1))
	# Two payoffs: each asks once; the second inside the gap is refused by the cooldown row rule.
	await _settle()
	var n2 := TimeDirector.get_finisher_requests()
	var g2 := TimeDirector.get_granted()
	td._on_hit_landed(_r7_hit(fake_player, fake_enemy, &"launch", &"front_kick"))
	await _wait(float(fin["time"]) + float(fin["ease"]) + 0.1)
	td._on_hit_landed(_r7_hit(fake_player, fake_enemy, &"launch", &"roundhouse"))
	var asked := TimeDirector.get_finisher_requests() - n2
	var granted := TimeDirector.get_granted() - g2
	rows.append("two payoffs %.2f s apart: %d requests, %d granted (the second in the 1 s gap)" % [
		float(fin["time"]) + float(fin["ease"]) + 0.1, asked, granted])
	_check(asked == 2 and granted == 1, "two launch payoffs: two requests, the second refused by the 1 s gap (%d asked, %d granted)" % [asked, granted])
	for r in rows:
		print("  finisher: ", r)
	fake_player.queue_free()
	fake_enemy.queue_free()

	# --- Legacy request_slowmo -------------------------------------------------------------------
	await _settle()
	_check(TimeDirector.request_slowmo(0.3, 0.25, TimeDirector.PRIO_DODGE), "legacy request granted")
	_check(_near(Engine.time_scale, 0.3), "legacy scale applied")
	_check(TimeDirector.player_time_factor() > 3.0, "legacy non-KO slow motion: player in real time")
	_check(TimeDirector.request_slowmo(0.2, 0.3, TimeDirector.PRIO_KO), "legacy KO granted on top")
	_check(_near(Engine.time_scale, 0.2) and TimeDirector.get_active_priority() == TimeDirector.PRIO_KO, "legacy KO 0.2x, PRIO_KO")
	_check(_near(TimeDirector.player_time_factor(), 1.0), "a legacy KO: the player slows with the world")

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
