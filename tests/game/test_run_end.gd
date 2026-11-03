extends Node
## F11 acceptance (J): player death plays the death camera (E) and then the
## results screen. Waves: clear a wave, land a big hit, break a wall, take a
## limb, smash clutter and snap a pillar, then die: round_over(false), slow time at the player-death scale, the
## death camera on the body for the slow motion's 1 s, then the results screen
## (waves cleared, kills, time, biggest hit: the most damage in one player hit
## with its move and reaction (Round 7), walls broken, objects smashed,
## structures brought down, limbs taken) and
## GameEvents.run_ended(stats) once, with the same stats. Restart from the
## results works. Duel: dying loses the round (DEFEATED), no run_ended.

var _fails := 0
var _run_ended: Array = []
var _gm: GameMode

func _ready() -> void:
	GameEvents.run_ended.connect(func(stats: Dictionary) -> void: _run_ended.append(stats))
	await get_tree().process_frame
	await _run()
	TimeDirector.reset()
	print("TEST test_run_end: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _hold_still() -> void:
	for f in _gm.get_alive_enemies():
		if f.brain and f.brain.process_mode != Node.PROCESS_MODE_DISABLED:
			f.brain.process_mode = Node.PROCESS_MODE_DISABLED

func _frames(n: int) -> void:
	for i in n:
		_hold_still()
		await get_tree().physics_frame

func _wait_until(cond: Callable, max_real: float) -> void:
	var until := TimeDirector.now() + max_real
	while not cond.call() and TimeDirector.now() < until:
		_hold_still()
		await get_tree().physics_frame

func _run() -> void:
	_gm = GameMode.new()
	_gm.show_title = false
	_gm.breather_time = 0.5
	add_child(_gm)
	_gm.start_round(&"waves")
	await _frames(3)

	# Wave 1: three kills, one of them launched by a 21-damage roundhouse payoff.
	var tps := Engine.physics_ticks_per_second
	for i in int(20.0 * tps):
		for f in _gm.get_alive_enemies():
			if _gm.kills == 0:
				var jab := HitInfo.new()
				jab.attacker = _gm.player
				jab.victim = f
				jab.move_id = &"jab"
				jab.react = &"snap"
				jab.damage = 5.0
				GameEvents.hit_landed.emit(jab)
				var big := HitInfo.new()
				big.attacker = _gm.player
				big.victim = f
				big.move_id = &"roundhouse"
				big.react = &"launch"
				big.payoff = true
				big.damage = 21.0
				GameEvents.hit_landed.emit(big)
				var small := HitInfo.new()
				small.attacker = f
				small.victim = _gm.player
				small.damage = 40.0  # an enemy's hit never counts as the player's biggest
				GameEvents.hit_landed.emit(small)
				GameEvents.limb_severed.emit(f, &"arm_l", null)
			f.apply_damage(f.max_hp + 10.0, &"test")
		await _frames(1)
		if _gm.get_enemies_left() == 0:
			break
	await _wait_until(func() -> bool: return _gm.wave_index == 1 and _gm.get_alive_enemies().size() > 0, 6.0)
	_check(_gm.waves_cleared == 1 and _gm.wave_index == 1, "wave 1 cleared, wave 2 running")
	var panel: Destructible = null
	for d in _gm.arena.get_destructibles():
		if d.kind == &"panel" and not d.is_unbreakable() and not d.is_broken and d.style != &"rolldoor" \
				and not d.has_meta(&"staged_breach") and d.get_alive_count() == d.get_cell_count():
			panel = d
			break
	if panel:
		panel.force_break(panel.global_position, -panel.global_basis.z * 6.0)
	# Round 6: two clutter objects smashed and a pillar brought down.
	var smashed := 0
	for c in get_tree().get_nodes_in_group(&"clutter"):
		if smashed >= 2:
			break
		if c.get(&"is_broken") == false and c.get(&"is_loose") != true:
			c.call(&"force_break", (c as Node3D).global_position, Vector3.FORWARD * 3.0, _gm.player)
			smashed += 1
	var pillar: Node3D = null
	for n in get_tree().get_nodes_in_group(&"pillars"):
		if n.get(&"is_broken") == false:
			pillar = n
			break
	if pillar:
		pillar.call(&"receive_impact", float(pillar.get(&"break_energy")) * 1.5 + 1.0,
			pillar.global_position + Vector3.UP, Vector3(10.0, 0.0, 0.0))
	var kills_before := _gm.kills
	var victim: Fighter = _gm.get_alive_enemies()[0] if not _gm.get_alive_enemies().is_empty() else null
	if victim:
		victim.apply_damage(victim.max_hp + 10.0, &"test")
	await _frames(3)
	await _wait_real(1.0)

	# Death.
	var t0 := TimeDirector.now()
	_gm.player.apply_damage(_gm.player.max_hp + 10.0, &"test")
	await _frames(2)
	_check(_gm.is_round_over() and _gm.phase == GameMode.Phase.ENDING, "player death ends the run")
	var min_scale := Engine.time_scale
	var modes := {}
	var results_at := -1.0
	var mode_at_slow_end := ""
	var slow: Dictionary = Tuning.SLOW_TIME[&"player_death"]
	while TimeDirector.now() - t0 < 4.0:
		await get_tree().process_frame
		min_scale = minf(min_scale, Engine.time_scale)
		var m := _gm.camera_rig.get_mode_name().to_lower()
		modes[m] = true
		var dt := TimeDirector.now() - t0
		if mode_at_slow_end == "" and dt >= float(slow["time"]) * 0.9:
			mode_at_slow_end = m
		if results_at < 0.0 and _gm.menus.screen == GameMenus.Screen.ROUND_OVER:
			results_at = dt
			break
	print("    death: min time scale %.2f (table %.2f), camera modes %s, results after %.2f s" % [
		min_scale, slow["scale"], modes.keys(), results_at])
	_check(absf(min_scale - float(slow["scale"])) < 0.06, "death slow motion at %.2fx (%.2f)" % [slow["scale"], min_scale])
	_check(mode_at_slow_end in ["ko", "death"], "death camera on the body through the slow motion (%s)" % mode_at_slow_end)
	var hold := float(slow["time"]) + float(slow["ease"])
	_check(results_at >= hold and results_at < hold + 1.0, "results screen after the death camera (%.2f s; slow time %.2f s)" % [results_at, hold])
	_check(_gm.phase == GameMode.Phase.OVER and _gm.menus._over_title.text == "RUN OVER", "results panel 'RUN OVER'")
	_check(_run_ended.size() == 1, "run_ended emitted once (%d)" % _run_ended.size())
	var stats: Dictionary = _run_ended[0] if not _run_ended.is_empty() else {}
	print("    stats %s" % stats)
	_check(stats == _gm.menus.last_results, "the results screen shows run_ended's stats")
	_check(int(stats.get("waves_cleared", -1)) == 1, "waves cleared 1")
	_check(int(stats.get("kills", -1)) == kills_before + 1 and _gm.kills == 4, "kills %d" % int(stats.get("kills", -1)))
	_check(is_equal_approx(float(stats.get("biggest_hit", 0.0)), 21.0) and stats.get("biggest_hit_move") == &"roundhouse"
		and stats.get("biggest_hit_react") == &"launch",
		"biggest hit 21 roundhouse launch (%s %s %s)" % [stats.get("biggest_hit"), stats.get("biggest_hit_move"), stats.get("biggest_hit_react")])
	_check(int(stats.get("walls_broken", -1)) >= 2, "walls broken %d (a panel and a pillar)" % int(stats.get("walls_broken", -1)))
	_check(int(stats.get("objects_smashed", -1)) >= smashed and smashed == 2,
		"objects smashed %d (2 clutter smashed by hand, plus anything the blasts broke)" % int(stats.get("objects_smashed", -1)))
	_check(int(stats.get("structures_down", -1)) >= 1, "structures brought down %d" % int(stats.get("structures_down", -1)))
	_check(int(stats.get("limbs_taken", -1)) == 1, "limbs taken 1")
	_check(float(stats.get("time", 0.0)) > 1.0, "run time %.1f s" % float(stats.get("time", 0.0)))
	var rows := GameMenus.results_rows(stats)
	var labels := PackedStringArray()
	for r: Array in rows:
		labels.append(r[0])
	_check(labels == PackedStringArray(["WAVES CLEARED", "KILLS", "TIME", "BIGGEST HIT", "WALLS BROKEN",
		"OBJECTS SMASHED", "STRUCTURES BROUGHT DOWN", "LIMBS TAKEN"]),
		"results rows: %s" % ", ".join(labels))
	var shown := PackedStringArray()
	for c in _gm.menus._over_grid.get_children():
		shown.append((c as Label).text)
	print("    results screen: %s" % " | ".join(shown))
	_check(shown.has("21  ROUNDHOUSE  LAUNCH"), "biggest hit row reads '21  ROUNDHOUSE  LAUNCH'")
	_check(GameMenus.biggest_hit_text({"biggest_hit": 9.4, "biggest_hit_move": &"heavy_hook", "biggest_hit_react": &"spin"}) == "9  HEAVY HOOK"
		and GameMenus.biggest_hit_text({}) == "-", "a hit with no knockdown or launch shows damage and move; no hit shows '-'")

	# Restart from the results screen.
	_gm.restart()
	await _frames(5)
	_check(_gm.phase == GameMode.Phase.FIGHTING and _gm.mode == &"waves" and _gm.wave_index == 0 and _gm.waves_cleared == 0,
		"restart from the results starts a fresh run")
	_check(is_equal_approx(Engine.time_scale, 1.0), "time scale back to 1")

	# Duel: dying loses the round, no run_ended.
	_gm.start_round(&"duel")
	await _frames(5)
	_gm.player.apply_damage(_gm.player.max_hp + 10.0, &"test")
	await _wait_until(func() -> bool: return _gm.menus.screen == GameMenus.Screen.ROUND_OVER, 4.0)
	_check(_gm.menus._over_title.text == "DEFEATED", "duel: dying loses the round (DEFEATED)")
	_check(_run_ended.size() == 1, "duel: no run_ended")

func _wait_real(sec: float) -> void:
	var until := TimeDirector.now() + sec
	while TimeDirector.now() < until:
		_hold_still()
		await get_tree().physics_frame
