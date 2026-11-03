extends Node
## Round 7 amendment (J): the god path's pursuit cues. A launch the player
## caused opens the pursuit window: "DASH: PURSUE" (the Dash key in the badge)
## near the flying body until the window closes (hitstop + Tuning.PURSUIT_WINDOW).
## A Dash then (the real Defence.on_dash_pressed) starts the pursuit: during the
## hang the cue reads "ATTACK: LAUNCH  /  BACK + ATTACK: SPIKE" at the body; the
## pursuit hit's relaunch opens the next link's "DASH: PURSUE" while the chain
## (Tuning.debug_pursuit_max) allows. No cue for non-launch hits, enemy
## launches, pursuit off (0), a spent chain, a spike, or after the round. Also
## TELEPORT / SIDESTEP feedback. Prints the measured window and hang times.

var _fails := 0

func _ready() -> void:
	for i in 5:
		await get_tree().process_frame
	await _run()
	print("TEST test_hud_pursuit: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _wait_real(sec: float) -> void:
	var until := TimeDirector.now() + sec
	while TimeDirector.now() < until:
		await get_tree().process_frame

## Real seconds from t0 until cond() holds (or max_s), polled every frame.
func _until(t0: float, cond: Callable, max_s: float) -> float:
	while not cond.call() and TimeDirector.now() - t0 < max_s:
		await get_tree().process_frame
	return TimeDirector.now() - t0

func _info(att: Fighter, vic: Fighter, tier: int, react: StringName, pursuit := false) -> HitInfo:
	var i := HitInfo.new()
	i.attacker = att
	i.victim = vic
	i.move_id = &"roundhouse"
	i.react = react
	i.tier = tier
	i.reaction = HitInfo.reaction_for_tier(tier)
	i.result = HitInfo.Result.HIT
	i.hitstop = 0.1
	i.damage = 10.0
	i.pursuit = pursuit
	return i

## Launch `vic` for real (the body flies) and report it as the hit that did it.
func _launch_hit(att: Fighter, vic: Fighter, vel: Vector3, pursuit := false) -> void:
	vic.launch(vel, vic.get_center_of_mass())
	GameEvents.hit_landed.emit(_info(att, vic, HitInfo.Tier.LAUNCH, &"launch", pursuit))

func _cue(hud: HUD) -> Dictionary:
	return hud.get_pursuit_cue()

func _run() -> void:
	var world := Node3D.new()
	add_child(world)
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = Layers.WORLD
	floor_body.collision_mask = 0
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80, 1, 80)
	floor_shape.shape = box
	floor_shape.position = Vector3(0, -0.5, 0)
	floor_body.add_child(floor_shape)
	world.add_child(floor_body)
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.look_at_from_position(Vector3(0, 4, 10), Vector3(0, 1.5, -2))
	cam.make_current()
	var player := FighterFactory.spawn_dummy(world, &"player", Transform3D(Basis(), Vector3(0, 0.05, 2)), Fighter.TEAM_PLAYER)
	var a := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(-1.5, 0.05, 0)))
	var b := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(1.5, 0.05, 0)))
	var c := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(0, 0.05, -1)))
	var hud := HUD.new()
	add_child(hud)
	hud.set_player(player)
	hud.set_mode(&"waves")
	await _frames(4)
	var saved_max := Tuning.debug_pursuit_max
	var saved_pad := UIKit.pad_active
	Tuning.debug_pursuit_max = 2
	UIKit.pad_active = false

	# Nothing without a launch of the player's.
	GameEvents.hit_landed.emit(_info(player, a, HitInfo.Tier.STAGGER, &"snap"))
	await _frames(2)
	_check(_cue(hud).is_empty(), "a non-launch hit opens no pursuit cue")
	GameEvents.hit_landed.emit(_info(c, a, HitInfo.Tier.LAUNCH, &"launch"))
	await _frames(2)
	_check(_cue(hud).is_empty(), "an enemy's launch opens no pursuit cue")

	# The player's launch: DASH: PURSUE near the flying body, until the window closes.
	var t0 := TimeDirector.now()
	_launch_hit(player, a, Vector3(0, 7, -2))
	await _frames(2)
	var q := _cue(hud)
	_check(q.get("kind") == &"pursue" and q.get("text") == "DASH: PURSUE" and q.get("key") == "Shift" and q.get("fighter") == a,
		"launch -> 'DASH: PURSUE' with 'Shift' on the body (%s, %s, %s)" % [q.get("kind"), q.get("text"), q.get("key")])
	if not q.is_empty():
		var col: Color = q["color"]
		var body := cam.unproject_position(a.get_center_of_mass() + Vector3.UP * HUD.PURSUE_ABOVE)
		var tip: Vector2 = q["tip"]
		print("    pursue cue tip %s, body %s (%.1f px)" % [tip, body, tip.distance_to(body)])
		_check(bool(q["on_screen"]) and tip.distance_to(body) < 40.0, "the cue points at the flying body (%.1f px)" % tip.distance_to(body))
		_check(col.is_equal_approx(UIKit.PURSUIT_COLOR), "pursuit colour, apart from counter orange and dodge blue")
	var shut := await _until(t0, func() -> bool: return _cue(hud).is_empty(), 2.0)
	var want := 0.1 + Tuning.PURSUIT_WINDOW
	print("    pursue cue gone %.2f s after the launch (hitstop 0.10 + window %.2f)" % [shut, Tuning.PURSUIT_WINDOW])
	_check(absf(shut - want) < 0.05, "cue closes with the window at %.2f s (%.2f)" % [want, shut])

	# Pursuit off: no cue.
	Tuning.debug_pursuit_max = 0
	_launch_hit(player, c, Vector3(0, 6, -2))
	await _frames(2)
	_check(_cue(hud).is_empty(), "pursuit chain 0 (off): no cue")
	Tuning.debug_pursuit_max = 2
	await _frames(2)
	_check(_cue(hud).get("fighter") == c, "turned back on inside the window: the cue shows")

	# A spike closes it.
	GameEvents.hit_landed.emit(_info(player, c, HitInfo.Tier.LAUNCH, &"spike", true))
	await _frames(2)
	_check(_cue(hud).is_empty(), "a spike leaves no pursuit cue")

	# The real pursuit: Dash in the window -> the hang cue.
	_launch_hit(player, b, Vector3(0, 7, -1))
	await _wait_real(0.13)  # past the launch's hitstop
	var dashed := player.defence.on_dash_pressed(TimeDirector.now())
	var t_dash := TimeDirector.now()
	await _frames(2)
	if not dashed or player.defence.get_pursuit_target() != b:
		_check(false, "Defence.on_dash_pressed started a pursuit on the flying body (dashed %s, target %s)" % [
			dashed, player.defence.get_pursuit_target()])
	else:
		q = _cue(hud)
		_check(q.get("kind") == &"hang" and q.get("text") == HUD.HANG_TEXT and q.get("fighter") == b,
			"pursuit hang -> '%s' (%s)" % [HUD.HANG_TEXT, q.get("text")])
		# The pursuit hit relaunches: the hang cue goes, the next link's DASH: PURSUE shows.
		_launch_hit(player, b, Vector3(0, 6, -6), true)
		await _frames(2)
		q = _cue(hud)
		_check(q.get("kind") == &"pursue" and q.get("fighter") == b and player.defence.pursuit_chain(b) == 1,
			"pursuit hit relaunches -> next 'DASH: PURSUE' (chain %d of %d)" % [player.defence.pursuit_chain(b), Tuning.debug_pursuit_max])
		Tuning.debug_pursuit_max = 1
		await _frames(1)
		_check(_cue(hud).is_empty(), "chain spent (1 of 1): no cue")
		Tuning.debug_pursuit_max = 2
		await _frames(1)
		_check(_cue(hud).get("kind") == &"pursue", "chain room again (1 of 2): the cue is back")
		# Second pursuit, no hit: the hang cue lasts the hang plus Defence's grace.
		await _wait_real(0.13)
		dashed = player.defence.on_dash_pressed(TimeDirector.now())
		t_dash = TimeDirector.now()
		await _frames(1)
		_check(dashed and _cue(hud).get("kind") == &"hang", "second pursuit: hang cue")
		var hang_s := await _until(t_dash, func() -> bool: return _cue(hud).get("kind") != &"hang", 2.0)
		print("    hang cue lasted %.2f s (hang %.2f + grace %.2f)" % [hang_s, Tuning.PURSUIT_HANG, HUD.HANG_GRACE])
		_check(absf(hang_s - Tuning.PURSUIT_HANG - HUD.HANG_GRACE) < 0.05, "hang cue gone after %.2f s with no hit (%.2f)" % [
			Tuning.PURSUIT_HANG + HUD.HANG_GRACE, hang_s])
		await _frames(1)
		_check(_cue(hud).is_empty(), "the used window shows no new cue")

	# Teleport and sidestep feedback.
	GameEvents.teleported.emit(player, Vector3.ZERO, Vector3.ONE, &"counter")
	_check(hud._pop_label.text == "TELEPORT", "teleport -> 'TELEPORT'")
	hud._pop_label.text = ""
	GameEvents.teleported.emit(player, Vector3.ZERO, Vector3.ONE, &"pursuit")
	GameEvents.teleported.emit(a, Vector3.ZERO, Vector3.ONE, &"counter")
	_check(hud._pop_label.text == "", "a pursuit teleport or an enemy's teleport pops nothing")
	GameEvents.sidestepped.emit(player, Vector3.RIGHT)
	await _frames(1)
	_check(hud.get_popup_texts().has("SIDESTEP"), "no spot to teleport: 'SIDESTEP'")

	# The overlay names the upgrades.
	var text := hud.get_debug_text()
	_check(text.contains("UPGRADES   speed cap %d m/s  ram %d  teleport %s  pursuit x2" % [roundi(Tuning.debug_speed_cap),
		Tuning.debug_ram_level, "ON" if Tuning.debug_teleport else "off"]), "overlay lists the upgrades")

	# Round over: no cue.
	var d := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(2.5, 0.05, -1)))
	await _frames(2)
	_launch_hit(player, d, Vector3(0, 7, -2))
	await _frames(2)
	_check(_cue(hud).get("fighter") == d, "fresh launch: cue")
	hud.set_round_over()
	await _frames(1)
	_check(_cue(hud).is_empty(), "round over: no pursuit cue")
	Tuning.debug_pursuit_max = saved_max
	UIKit.pad_active = saved_pad
