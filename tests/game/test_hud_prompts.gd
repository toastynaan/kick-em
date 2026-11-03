extends Node
## Round 7 counter prompts (J): GameEvents.counter_window(attacker, player,
## open, counterable) puts a badge over the attacker's head while its window
## is open: orange with the Counter key for counterable attacks, blue "DODGE"
## with the dodge key for grabs and the charge. The keys follow the last device
## used (V / Y, Shift / RT). Several at once; an attacker off screen gets
## its badge at the screen edge (and no separate arrow). A prompt goes when the
## window closes, the attacker is countered, dies or goes down, after
## HUD.PROMPT_MAX_AGE, or when the round ends. A Counter press with nothing to
## counter says WHIFF, or DODGE IT when a blue attack is coming.

var _fails := 0

func _ready() -> void:
	for i in 5:
		await get_tree().process_frame
	await _run()
	print("TEST test_hud_prompts: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
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

func _prompt_for(hud: HUD, f: Fighter) -> Dictionary:
	for p: Dictionary in hud.get_counter_prompts():
		if p["fighter"] == f:
			return p
	return {}

func _push(ev: InputEvent) -> void:
	get_viewport().push_input(ev)

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
	cam.look_at_from_position(Vector3(0, 3, 8), Vector3(0, 1, 0))
	cam.make_current()
	var player := FighterFactory.spawn_dummy(world, &"player", Transform3D(Basis(), Vector3(0, 0.05, 2)), Fighter.TEAM_PLAYER)
	var left := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(-2, 0.05, -2)))
	var right := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(2, 0.05, -2)))
	var behind := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(3, 0.05, 14)))
	var hud := HUD.new()
	add_child(hud)
	hud.set_player(player)
	hud.set_mode(&"waves")
	await _frames(4)
	var saved_pad := UIKit.pad_active
	UIKit.pad_active = false
	var vp := get_viewport().get_visible_rect()

	# Counterable: orange, the Counter key, over the attacker's head.
	GameEvents.counter_window.emit(left, player, true, true)
	await _frames(1)
	var p := _prompt_for(hud, left)
	_check(hud.get_counter_prompts().size() == 1 and not p.is_empty(), "counter_window open -> one prompt")
	if not p.is_empty():
		var col: Color = p["color"]
		_check(col.is_equal_approx(UIKit.TELL_STRIKE) and p["key"] == "V" and p["caption"] == "COUNTER",
			"counterable: orange, 'V', 'COUNTER' (%s, %s, %s)" % [col, p["key"], p["caption"]])
		_check(float(p["scale"]) > 1.3, "badge pops in (scale %.2f on the first frame)" % float(p["scale"]))
	await _wait_real(HUD.PROMPT_IN + 0.05)
	p = _prompt_for(hud, left)
	if not p.is_empty():
		var head := cam.unproject_position(left.get_ground_position() + Vector3.UP * left.get_height())
		var c: Vector2 = p["center"]
		print("    prompt centre %s, head top %s, tip %s" % [c, head, p["tip"]])
		_check(is_equal_approx(float(p["scale"]), 1.0) and float(p["alpha"]) >= 1.0, "settled: scale 1, opaque")
		_check(bool(p["on_screen"]) and absf(c.x - head.x) < 2.0 and c.y < head.y - 20.0 and c.y > head.y - 120.0,
			"badge sits above the head (%.0f px above, %.1f px across)" % [head.y - c.y, absf(c.x - head.x)])

	# Uncounterable: blue, "DODGE" and the dodge key. Several at once.
	GameEvents.counter_window.emit(right, player, true, false)
	await _frames(1)
	var q := _prompt_for(hud, right)
	_check(hud.get_counter_prompts().size() == 2, "two attackers: two prompts")
	if not q.is_empty():
		var colq: Color = q["color"]
		_check(colq.is_equal_approx(UIKit.TELL_GRAB) and q["key"] == "Shift" and q["caption"] == "DODGE",
			"uncounterable: blue, 'Shift', 'DODGE' (%s, %s, %s)" % [colq, q["key"], q["caption"]])
		var cl: Vector2 = _prompt_for(hud, left).get("center", Vector2.ZERO)
		_check(cl.distance_to(q["center"]) > 60.0, "the two badges do not overlap (%.0f px apart)" % cl.distance_to(q["center"]))

	# Windows aimed at someone else are not the player's.
	GameEvents.counter_window.emit(behind, left, true, true)
	await _frames(1)
	_check(hud.get_counter_prompts().size() == 2, "a window on another fighter shows nothing")

	# The keys follow the last device used.
	var joy := InputEventJoypadButton.new()
	joy.button_index = JOY_BUTTON_DPAD_UP
	joy.pressed = true
	_push(joy)
	await _frames(1)
	_check(UIKit.pad_active and _prompt_for(hud, left).get("key") == "Y" and _prompt_for(hud, right).get("key") == "RT",
		"after a gamepad press: 'Y' and 'RT' (%s, %s)" % [_prompt_for(hud, left).get("key"), _prompt_for(hud, right).get("key")])
	var drift := InputEventJoypadMotion.new()
	drift.axis = JOY_AXIS_LEFT_X
	drift.axis_value = 0.2
	var key := InputEventKey.new()
	key.physical_keycode = KEY_K
	key.keycode = KEY_K
	key.pressed = true
	_push(key)
	_push(drift)
	await _frames(1)
	_check(not UIKit.pad_active and _prompt_for(hud, left).get("key") == "V" and _prompt_for(hud, right).get("key") == "Shift",
		"after a key press (stick drift ignored): 'V' and 'Shift'")

	# Closing a window removes only that prompt.
	GameEvents.counter_window.emit(left, player, false, true)
	await _frames(1)
	_check(hud.get_counter_prompts().size() == 1 and _prompt_for(hud, left).is_empty() and not _prompt_for(hud, right).is_empty(),
		"window closed -> its prompt goes, the other stays")

	# Counter press with nothing counterable: WHIFF, or DODGE IT with a blue attack coming.
	GameEvents.counter_whiffed.emit(player)
	await _frames(1)
	_check(hud.get_popup_texts().has("DODGE IT"), "counter press against a blue attack -> 'DODGE IT'")

	# The attacker dies: its prompt goes.
	right.apply_damage(right.max_hp + 10.0, &"test")
	await _frames(2)
	_check(hud.get_counter_prompts().is_empty() and hud.get_prompt_attackers().is_empty(), "attacker dead -> prompt gone")
	await _wait_real(0.8)
	GameEvents.counter_whiffed.emit(player)
	await _frames(1)
	_check(hud.get_popup_texts().has("WHIFF") and not hud.get_popup_texts().has("DODGE IT"), "counter press with nothing coming -> 'WHIFF'")

	# Off screen: the badge sits at the screen edge, pointing out, and replaces the arrow.
	_check(not cam.is_position_in_frustum(behind.get_aim_point()), "test attacker is behind the camera")
	GameEvents.attack_tell.emit(behind, &"strike", 1.0)
	await _frames(1)
	_check(hud.get_arrows().size() == 1, "off-screen wind-up alone: one arrow")
	GameEvents.counter_window.emit(behind, player, true, true)
	await _frames(2)
	var b := _prompt_for(hud, behind)
	_check(not b.is_empty() and not bool(b["on_screen"]), "off-screen attacker gets a prompt")
	if not b.is_empty():
		var bc: Vector2 = b["center"]
		var sz: Vector2 = b["size"]
		var inside := vp.grow(-HUD.PROMPT_MARGIN + 0.5).encloses(Rect2(bc - sz * 0.5, sz))
		var edge := minf(minf(bc.x, vp.size.x - bc.x), minf(bc.y, vp.size.y - bc.y))
		print("    off-screen prompt at %s (%.0f px from the nearest edge)" % [bc, edge])
		_check(inside and edge < 160.0, "badge inside the screen, near the edge (%.0f px)" % edge)
	_check(hud.get_arrows().is_empty(), "the prompt replaces the attack arrow")

	# Countered: the prompt goes and COUNTER pops.
	GameEvents.countered.emit(player, behind)
	await _frames(1)
	_check(_prompt_for(hud, behind).is_empty() and hud._pop_label.text == "COUNTER", "countered -> prompt gone, 'COUNTER'")
	GameEvents.attack_active.emit(behind, &"e_jab")

	# A missed close: the prompt still goes after PROMPT_MAX_AGE.
	GameEvents.counter_window.emit(left, player, true, true)
	var t0 := TimeDirector.now()
	await _frames(1)
	_check(not _prompt_for(hud, left).is_empty(), "prompt up for an attack with no close event")
	while not hud.get_prompt_attackers().is_empty() and TimeDirector.now() - t0 < HUD.PROMPT_MAX_AGE + 1.0:
		await get_tree().process_frame
	var age := TimeDirector.now() - t0
	print("    no close event: prompt gone after %.2f s" % age)
	_check(absf(age - HUD.PROMPT_MAX_AGE) < 0.1, "without a close it expires after %.1f s (%.2f)" % [HUD.PROMPT_MAX_AGE, age])

	# Knocked down: gone.
	GameEvents.counter_window.emit(left, player, true, true)
	await _frames(1)
	left.knockdown(Vector3.BACK)
	await _frames(3)
	_check(left.is_down() and _prompt_for(hud, left).is_empty(), "attacker knocked down -> prompt gone")

	# Real enemy attacks: B's CombatController opens the window
	# Tuning.R7_COUNTER_WINDOW before the first active frame and closes it after.
	var atk := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis.looking_at(Vector3.BACK), player.global_position + Vector3(0, 0, -1.3)))
	await _frames(3)
	var tell := 0.6
	var t_start := TimeDirector.now()
	var started := atk.combat.start_enemy_attack(&"e_jab", tell)
	var t_open := -1.0
	var t_active := -1.0
	var t_close := -1.0
	var open_col := Color.BLACK
	while TimeDirector.now() - t_start < 2.5:
		await get_tree().process_frame
		var now := TimeDirector.now() - t_start
		var pr := _prompt_for(hud, atk)
		if t_open < 0.0 and not pr.is_empty():
			t_open = now
			open_col = pr["color"]
		if t_active < 0.0 and atk.combat.is_attack_active():
			t_active = now
		if t_open >= 0.0 and t_close < 0.0 and pr.is_empty():
			t_close = now
			break
	print("    real e_jab (tell %.2f s): prompt at %.2f s, first active frame at %.2f s, prompt gone at %.2f s" % [tell, t_open, t_active, t_close])
	_check(started and t_open >= 0.0 and open_col.is_equal_approx(UIKit.TELL_STRIKE), "real e_jab: orange prompt from B's counter_window")
	_check(t_active > 0.0 and absf((t_active - t_open) - Tuning.R7_COUNTER_WINDOW) < 0.05,
		"prompt up %.2f s before the first active frame (window %.2f)" % [t_active - t_open, Tuning.R7_COUNTER_WINDOW])
	_check(t_close > t_active, "prompt gone after the attack (%.2f s > %.2f s)" % [t_close, t_active])
	# A missed event: Defence's open windows still raise the prompt.
	while atk.combat.is_attacking() and TimeDirector.now() - t_start < 5.0:
		await get_tree().process_frame
	await _wait_real(0.4)
	GameEvents.counter_window.disconnect(hud._on_counter_window)
	t_start = TimeDirector.now()
	started = atk.combat.start_enemy_attack(&"e_hook", tell)
	var polled_open := false
	var polled_gone := false
	while TimeDirector.now() - t_start < 2.5:
		await get_tree().process_frame
		var pr := _prompt_for(hud, atk)
		if not pr.is_empty():
			polled_open = true
		elif polled_open:
			polled_gone = true
			break
	GameEvents.counter_window.connect(hud._on_counter_window)
	_check(started and polled_open and polled_gone, "without counter_window events the prompt follows Defence's open windows (up %s, gone %s)" % [
		polled_open, polled_gone])
	atk.queue_free()
	await _frames(2)

	# Round over clears prompts and ignores new windows.
	var fresh :=FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(0, 0.05, -3)))
	await _frames(2)
	GameEvents.counter_window.emit(fresh, player, true, true)
	await _frames(1)
	_check(hud.get_counter_prompts().size() == 1, "prompt on a fresh attacker")
	# Hit during its wind-up: a reacting fighter cannot attack, its prompt goes.
	fresh.react(&"snap", Vector3.FORWARD, 0.4, 0.45)
	await _frames(2)
	if fresh.is_reacting():
		_check(_prompt_for(hud, fresh).is_empty(), "attacker reacting to a hit -> prompt gone")
		await _wait_real(0.6)
	else:
		print("    note: Fighter.react is still H's stub (is_reacting false); reacting check skipped")
	GameEvents.counter_window.emit(fresh, player, true, true)
	await _frames(1)
	hud.set_round_over()
	await _frames(1)
	GameEvents.counter_window.emit(fresh, player, true, false)
	await _frames(1)
	_check(hud.get_counter_prompts().is_empty(), "round over: no prompts")
	UIKit.pad_active = saved_pad
