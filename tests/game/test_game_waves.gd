extends Node
## GameMode waves: starts headless without the menu, runs ~10 s, never has more
## than Tuning.MAX_ENEMIES_ON_FIELD enemies alive, killing a whole wave
## advances to the next, and killing the player ends the round.

const RUN_SECONDS := 10.0

var _fails := 0
var _waves_started: Array = []
var _waves_cleared: Array = []
var _round_over: Array = []
var _max_alive := 0

func _ready() -> void:
	GameEvents.wave_started.connect(func(i: int, _t: int) -> void: _waves_started.append(i))
	GameEvents.wave_cleared.connect(func(i: int) -> void: _waves_cleared.append(i))
	GameEvents.round_over.connect(func(w: bool) -> void: _round_over.append(w))
	await get_tree().process_frame
	await _run()
	TimeDirector.reset()
	print("TEST test_game_waves: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _alive_on_field() -> int:
	var n := 0
	for e in get_tree().get_nodes_in_group(&"enemies"):
		var f := e as Fighter
		if f and not f.is_dead():
			n += 1
	return n

## keep_alive: heal the player every frame so the AI cannot end the run early.
func _step(gm: GameMode, frames: int, keep_alive := true) -> void:
	for i in frames:
		if keep_alive and is_instance_valid(gm.player) and not gm.player.is_dead():
			gm.player.heal_fraction(1.0)
		await get_tree().physics_frame
		_max_alive = maxi(_max_alive, maxi(_alive_on_field(), gm.get_alive_enemies().size()))
		_clear_spawns(gm)

## Walk-in stand-in: move enemies off their spawn points so the next ones can
## spawn quickly (works the same whether or not the AI walks them in).
func _clear_spawns(gm: GameMode) -> void:
	var spawns := gm.arena.get_enemy_spawns()
	for f in gm.get_alive_enemies():
		for e: Dictionary in spawns:
			var p: Vector3 = e["position"]
			if Vector2(f.global_position.x - p.x, f.global_position.z - p.z).length() < 2.5:
				f.global_position = Vector3(randf_range(-6.0, 6.0), f.global_position.y, randf_range(-6.0, 2.0))
				f.reset_physics_interpolation()
				break

func _kill_wave(gm: GameMode, max_frames: int) -> bool:
	for i in max_frames:
		for f in gm.get_alive_enemies():
			f.apply_damage(f.max_hp + 10.0, &"test")
		await _step(gm, 1, false)
		if gm.get_enemies_left() == 0:
			return true
	return false

func _run() -> void:
	var gm := GameMode.new()
	gm.show_title = false
	gm.breather_time = 1.0
	add_child(gm)
	gm.start_round(&"waves")
	await get_tree().process_frame
	_check(_waves_started == [0], "wave_started(0) emitted")
	_check(gm.wave_total == Tuning.WAVES.size(), "wave total from Tuning.WAVES")
	_check(not gm.hud._opp_root.visible, "waves show no enemy HP bar")
	_check(gm.camera_rig.follow_needs_wall and gm.camera_rig.follow_time < 1.0, "waves: short, wall-only follow-cam (%.1f s)" % gm.camera_rig.follow_time)

	# Make the queue bigger than the field cap to exercise the cap.
	for i in 5:
		gm._wave_queue.append(&"grunt")
	var tps := Engine.physics_ticks_per_second
	await _step(gm, int(RUN_SECONDS * tps))
	_check(_max_alive > 0, "enemies spawned (max alive %d)" % _max_alive)
	_check(_max_alive <= Tuning.MAX_ENEMIES_ON_FIELD, "never more than %d alive (max %d)" % [Tuning.MAX_ENEMIES_ON_FIELD, _max_alive])
	if gm.is_round_over():
		_check(false, "round ended during the free run (player died?)")
		return

	gm.player.heal_fraction(1.0)
	gm.player.apply_damage(gm.player.max_hp * 0.5, &"test")
	var hp_before := gm.player.hp
	var cleared := await _kill_wave(gm, int(30.0 * tps))
	_check(cleared, "wave 1 emptied by kills")
	await _step(gm, 3, false)
	_check(_waves_cleared == [0], "wave_cleared(0) emitted")
	var healed := gm.player.hp - hp_before
	_check(absf(healed - gm.player.max_hp * Tuning.HEAL_BETWEEN_WAVES) < 1.0, "healed %.0f%% between waves (+%.0f HP)" % [Tuning.HEAL_BETWEEN_WAVES * 100.0, healed])
	await _wait_real(gm.breather_time + 0.3)
	_check(gm.wave_index == 1 and _waves_started == [0, 1], "advanced to wave 2")
	await _step(gm, int(2.0 * tps))
	_check(gm.get_enemies_left() == 5, "wave 2 has 5 enemies (%d)" % gm.get_enemies_left())

	gm.player.apply_damage(gm.player.max_hp + 10.0, &"test")
	await _step(gm, 3, false)
	_check(gm.is_round_over(), "killing the player ends the round")
	_check(_round_over == [false], "round_over(false) emitted")
	_check(TimeDirector.get_active_priority() == TimeDirector.PRIO_KO, "KO slow motion on the player")
	await _wait_real(Tuning.KO_SLOWMO.y + GameMode.KO_PANEL_DELAY + 0.3)
	_check(gm.menus.screen == GameMenus.Screen.ROUND_OVER, "DEFEATED panel shown")
	_check(_max_alive <= Tuning.MAX_ENEMIES_ON_FIELD, "cap held for the whole test (max %d)" % _max_alive)

## Wait on the real clock (robust against long startup frames).
func _wait_real(sec: float) -> void:
	var until := TimeDirector.now() + sec
	while TimeDirector.now() < until:
		await get_tree().process_frame
