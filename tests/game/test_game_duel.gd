extends Node
## GameMode duel: starts headless without the menu, runs ~20 s of game time,
## then killing the Duelist is the last kill (GameEvents.last_kill: close-up
## and 0.2x slow time) and the round ends in a victory panel with the stats.

const RUN_SECONDS := 20.0

var _fails := 0
var _round_started: Array = []
var _round_over: Array = []
var _last_kills: Array = []

func _ready() -> void:
	GameEvents.round_started.connect(func(m: StringName) -> void: _round_started.append(m))
	GameEvents.round_over.connect(func(w: bool) -> void: _round_over.append(w))
	GameEvents.last_kill.connect(func(f: Node3D) -> void: _last_kills.append(f))
	await get_tree().process_frame
	await _run()
	TimeDirector.reset()
	print("TEST test_game_duel: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

## keep_alive: heal the player every frame so the AI cannot end the run early.
func _physics_frames(n: int, gm: GameMode = null) -> void:
	for i in n:
		if gm and is_instance_valid(gm.player) and not gm.player.is_dead():
			gm.player.heal_fraction(1.0)
		await get_tree().physics_frame

func _run() -> void:
	var gm := GameMode.new()
	gm.show_title = false
	add_child(gm)
	gm.start_round(&"duel")
	await get_tree().process_frame

	_check(_round_started == [&"duel"], "round_started(duel) emitted")
	_check(gm.player != null and gm.player.is_in_group(&"player"), "player spawned")
	_check(gm.arena != null and gm.arena.is_inside_tree(), "arena built")
	_check(get_tree().get_first_node_in_group(&"camera_rig") is CameraRig, "camera rig in group camera_rig")
	_check(gm.hud != null and gm.hud.is_inside_tree(), "HUD built")
	var enemies := gm.get_alive_enemies()
	_check(enemies.size() == 1 and enemies[0].archetype == &"duelist", "one Duelist spawned")
	_check(enemies.size() == 1 and enemies[0].max_hp == 200.0 and gm.player.max_hp == 100.0, "Round 5 health: Duelist 200, player 100")
	_check(is_equal_approx(gm.player.focus, Tuning.debug_start_focus), "the duel starts with %.0f Focus bar" % Tuning.debug_start_focus)
	_check(gm.hud.opponent == enemies[0] and gm.hud._opp_root.visible, "duel HUD shows the Duelist's HP bar")
	_check(not gm.camera_rig.is_follow_cam_active(), "duel: no follow-cam in play")
	var cam := get_viewport().get_camera_3d()
	_check(cam != null and cam.get_parent() is CameraRig, "rig camera is current")

	var frames := int(RUN_SECONDS * Engine.physics_ticks_per_second)
	# Free camera: 20 s of fighting with no camera input must not turn it,
	# except while the player is down (the knockdown may turn it).
	var rig := gm.camera_rig
	var yaw_ref := rig._yaw
	var turned := 0.0
	var down_frames := 0
	for i in frames:
		if is_instance_valid(gm.player) and not gm.player.is_dead():
			gm.player.heal_fraction(1.0)
		await get_tree().physics_frame
		if rig.get_mode() == CameraRig.Mode.COMBAT:
			turned = maxf(turned, absf(wrapf(rig._yaw - yaw_ref, -PI, PI)))
		else:
			down_frames += 1
			yaw_ref = rig._yaw  # a knockdown may turn it; measure from where it leaves it
	_check(turned < 0.0001, "%.0f s of fighting, no camera input: yaw unchanged in play (max %.5f rad, %d down frames)" % [RUN_SECONDS, turned, down_frames])
	_check(gm.player != null and is_instance_valid(gm.player), "player alive after %.0f s" % RUN_SECONDS)
	_check(not gm.is_round_over() or gm.player.is_dead(), "round still running unless the AI killed the player")
	if gm.is_round_over():
		print("  note: round already over after the run (AI fought); skipping the KO check")
		return

	var duelist: Fighter = gm.get_alive_enemies()[0]
	duelist.apply_damage(duelist.max_hp + 10.0, &"test")
	await _physics_frames(3)
	_check(gm.is_round_over(), "killing the Duelist ends the round")
	_check(_round_over == [true], "round_over(true) emitted")
	_check(_last_kills == [duelist], "the Duelist's death is the last kill (GameEvents.last_kill)")
	var slow: Dictionary = Tuning.SLOW_TIME[&"last_kill"]
	_check(Engine.time_scale < 0.5, "last-kill slow time (scale %.2f, table %.2f)" % [Engine.time_scale, slow["scale"]])
	_check(gm.camera_rig.get_mode_name().to_lower() in ["closeup", "ko", "last_kill"], "last-kill close-up camera (%s)" % gm.camera_rig.get_mode_name())
	var t_kill := TimeDirector.now()
	await _wait_until(func() -> bool: return gm.menus.screen == GameMenus.Screen.ROUND_OVER, 5.0)
	var waited := TimeDirector.now() - t_kill
	_check(gm.phase == GameMode.Phase.OVER, "round-over phase reached")
	_check(gm.menus.screen == GameMenus.Screen.ROUND_OVER and gm.menus._over_title.text == "VICTORY",
		"VICTORY panel after the close-up (%.2f s after the kill)" % waited)
	_check(waited >= float(slow["time"]), "the panel waits for the close-up's %.1f s" % slow["time"])
	_check(int(gm.menus.last_results.get("kills", 0)) == 1 and StringName(gm.menus.last_results.get("mode", &"")) == &"duel",
		"results: duel, 1 kill (%s)" % gm.menus.last_results)
	_check(is_equal_approx(Engine.time_scale, 1.0), "time back to 1.0 after the close-up")

	# The corpse may be freed while the camera still remembers it (fade-out).
	if is_instance_valid(duelist):
		duelist.queue_free()
	await _physics_frames(10)
	_check(gm.camera_rig.get_soft_target() == null, "freed corpse drops out of the camera without errors")

	# start_round is idempotent: a second call after the round ended...
	var old_arena = gm.arena  # untyped: freed after the next start_round
	gm.start_round(&"duel")
	await _physics_frames(5)
	_check_single_round(gm, "second start_round")
	_check(gm.arena != old_arena and is_instance_valid(gm.arena), "arena rebuilt for the new round")
	await _physics_frames(int(2.0 * Engine.physics_ticks_per_second), gm)
	# ...and a third call in the middle of a running round.
	gm.start_round(&"duel")
	await _physics_frames(5)
	_check_single_round(gm, "start_round mid-round")
	var d2: Fighter = gm.get_alive_enemies()[0] if not gm.get_alive_enemies().is_empty() else null
	if d2:
		d2.apply_damage(d2.max_hp + 10.0, &"test")
		await _physics_frames(3)
		_check(gm.is_round_over() and _round_over.size() == 2, "the rebuilt round ends normally (round_over x%d)" % _round_over.size())

func _check_single_round(gm: GameMode, what: String) -> void:
	var tree := get_tree()
	_check(tree.get_nodes_in_group(&"player").size() == 1, "%s: exactly one player" % what)
	_check(tree.get_nodes_in_group(&"enemies").size() == 1 and gm.get_alive_enemies().size() == 1
		and gm.get_alive_enemies()[0].archetype == &"duelist", "%s: exactly one Duelist" % what)
	_check(tree.get_nodes_in_group(&"camera_rig").size() == 1, "%s: one camera rig" % what)
	_check(tree.get_nodes_in_group(&"arena").size() == 1, "%s: one arena" % what)
	var huds := 0
	for c in gm.get_children():
		if c is HUD:
			huds += 1
	_check(huds == 1, "%s: one HUD" % what)
	_check(gm.phase == GameMode.Phase.FIGHTING and not tree.paused and not AttackDirector.camera_busy, "%s: fighting, unpaused, camera not busy" % what)
	_check(is_equal_approx(Engine.time_scale, 1.0), "%s: time scale reset" % what)

func _wait_until(cond: Callable, max_real: float) -> void:
	var until := TimeDirector.now() + max_real
	while not cond.call() and TimeDirector.now() < until:
		await get_tree().process_frame

## Wait on the real clock (robust against long startup frames).
func _wait_real(sec: float) -> void:
	var until := TimeDirector.now() + sec
	while TimeDirector.now() < until:
		await get_tree().process_frame
