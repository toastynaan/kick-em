extends Node
## Driver for test_main_flow.tscn (lives under the root so scene changes keep it).

var _fails := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	await _frames(2)
	await _run()
	TimeDirector.reset()
	print("TEST test_main_flow: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _gm() -> GameMode:
	return get_tree().current_scene as GameMode

func _press(action: StringName) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	get_tree().root.push_input(ev)

func _run() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")
	await _frames(6)
	var gm := _gm()
	_check(gm != null, "main.tscn root is a GameMode")
	if gm == null:
		return
	_check(gm.phase == GameMode.Phase.TITLE and gm.menus.screen == GameMenus.Screen.TITLE, "launch shows the title menu")
	_check(gm.arena != null and gm.player == null, "title has the arena backdrop and no fighters")
	var labels := PackedStringArray()
	for b in gm.menus.find_children("*", "Button", true, false):
		labels.append((b as Button).text)
	_check(labels.has("RAGDOLL LAB") and labels.has("GRAB LAB"), "title lists RAGDOLL LAB and GRAB LAB")

	gm.menus.duel_pressed.emit()
	await _frames(6)
	_check(gm.mode == &"duel" and gm.player != null and gm.get_alive_enemies().size() == 1, "DUEL starts from the menu")
	_check(gm.menus.screen == GameMenus.Screen.NONE, "menu hidden in the round")

	gm.pause()
	await _frames(2)
	_check(get_tree().paused and gm.menus.screen == GameMenus.Screen.PAUSE, "pause shows the pause menu")
	# Mouse sensitivity setting: slider -> CameraRig.sensitivity -> user://settings.cfg.
	var old_sens := CameraRig.sensitivity
	var old_inv := CameraRig.invert_y
	gm.menus.sens_slider.value = 1.5
	var cfg := ConfigFile.new()
	cfg.load(CameraRig.SETTINGS_PATH)
	_check(is_equal_approx(CameraRig.sensitivity, 1.5) and is_equal_approx(float(cfg.get_value("camera", "mouse_sensitivity", 0.0)), 1.5),
		"pause-menu sensitivity applies and saves to settings.cfg")
	gm.menus.invert_check.button_pressed = true
	_check(CameraRig.invert_y, "invert Y toggles")
	gm.menus.sens_slider.value = old_sens  # restore the user's settings
	gm.menus.invert_check.button_pressed = old_inv
	# Debug settings (pause > DEBUG SETTINGS): Tuning debug vars, saved to settings.cfg.
	var saved := [Tuning.debug_speed_cap, Tuning.debug_ram_level, Tuning.debug_start_focus, Tuning.debug_overlay]
	var labels2 := PackedStringArray()
	for b in gm.menus._pause.find_children("*", "Button", true, false):
		labels2.append((b as Button).text)
	_check(labels2.has("DEBUG SETTINGS"), "pause menu lists DEBUG SETTINGS")
	gm.menus.show_debug()
	await _frames(2)
	_check(gm.menus.screen == GameMenus.Screen.DEBUG, "debug settings screen opens")
	Tuning.debug_speed_cap = 8.0
	Tuning.debug_ram_level = 0
	Tuning.debug_start_focus = 1.0
	Tuning.debug_overlay = false
	gm.menus.step_debug_setting(&"speed_cap", 1)
	_check(is_equal_approx(Tuning.debug_speed_cap, 10.0), "speed cap 8 -> 10")
	gm.menus.step_debug_setting(&"speed_cap", 1)
	gm.menus.step_debug_setting(&"speed_cap", 1)
	_check(is_equal_approx(Tuning.debug_speed_cap, 8.0), "speed cap cycles 10 -> 12 -> 8")
	gm.menus.step_debug_setting(&"speed_cap", -1)
	_check(is_equal_approx(Tuning.debug_speed_cap, 12.0), "left steps back to 12")
	for i in 3:
		gm.menus.step_debug_setting(&"ram_level", 1)
	_check(Tuning.debug_ram_level == 3, "Battering Ram 0 -> 3")
	gm.menus.step_debug_setting(&"ram_level", 1)
	_check(Tuning.debug_ram_level == 0, "Battering Ram wraps to 0")
	gm.menus.step_debug_setting(&"ram_level", -1)
	gm.menus.step_debug_setting(&"start_focus", 1)
	_check(is_equal_approx(Tuning.debug_start_focus, 2.0), "starting Focus 1 -> 2")
	gm.menus.step_debug_setting(&"overlay", 1)
	_check(Tuning.debug_overlay, "debug overlay toggles on")
	await _frames(2)
	_check(gm.hud.is_debug_visible(), "HUD overlay follows the setting")
	var btn_text := (gm.menus.debug_buttons[&"speed_cap"] as Button).text
	_check(btn_text.contains("12 m/s"), "button shows the value (%s)" % btn_text)
	var cfg2 := ConfigFile.new()
	cfg2.load(GameMenus.SETTINGS_PATH)
	_check(is_equal_approx(float(cfg2.get_value("debug", "speed_cap", 0.0)), 12.0) and int(cfg2.get_value("debug", "ram_level", -1)) == 3
		and is_equal_approx(float(cfg2.get_value("debug", "start_focus", 0.0)), 2.0) and bool(cfg2.get_value("debug", "overlay", false))
		and cfg2.has_section_key("camera", "mouse_sensitivity"),
		"debug settings saved to settings.cfg next to the camera settings")
	Tuning.debug_speed_cap = 8.0
	Tuning.debug_ram_level = 0
	GameMenus.load_debug_settings(true)
	_check(is_equal_approx(Tuning.debug_speed_cap, 12.0) and Tuning.debug_ram_level == 3, "settings load back from settings.cfg")
	_press(&"pause")
	await _frames(2)
	_check(gm.menus.screen == GameMenus.Screen.PAUSE and get_tree().paused, "Esc in debug settings goes back to pause")
	Tuning.debug_speed_cap = saved[0]
	Tuning.debug_ram_level = saved[1]
	Tuning.debug_start_focus = saved[2]
	Tuning.debug_overlay = saved[3]
	GameMenus.save_debug_settings()  # restore the user's settings
	gm.resume()
	await _frames(2)
	_check(not get_tree().paused and gm.menus.screen == GameMenus.Screen.NONE, "resume")

	var old := gm
	gm.restart()
	await _frames(8)
	gm = _gm()
	_check(gm != null and gm != old, "restart reloads the scene")
	if gm == null:
		return
	_check(gm.mode == &"duel" and gm.phase == GameMode.Phase.FIGHTING and gm.player != null, "restart goes straight back into a duel")
	_check(get_tree().get_nodes_in_group(&"player").size() == 1, "exactly one player after restart")

	# Same restart through the keys (Esc, then R), routed by the viewport as in
	# play. GameMenus once called get_viewport() after the reload had already
	# taken it out of the tree: a SCRIPT ERROR that froze the editor run.
	_press(&"pause")
	await _frames(2)
	_check(get_tree().paused and gm.menus.screen == GameMenus.Screen.PAUSE, "Esc pauses")
	old = gm
	_press(&"restart")
	await _frames(8)
	gm = _gm()
	_check(gm != null and gm != old and gm.phase == GameMode.Phase.FIGHTING, "R in the pause menu restarts the duel")
	if gm == null:
		return

	gm.back_to_menu()
	await _frames(8)
	gm = _gm()
	_check(gm != null and gm.phase == GameMode.Phase.TITLE and gm.menus.screen == GameMenus.Screen.TITLE, "main menu returns to the title")
	if gm == null:
		return

	gm.menus.waves_pressed.emit()
	await _frames(6)
	_check(gm.mode == &"waves" and gm.wave_index == 0, "WAVES starts from the menu")
	for i in 240:
		await get_tree().physics_frame
	_check(gm.get_alive_enemies().size() >= 1, "wave enemies spawned (%d alive)" % gm.get_alive_enemies().size())
	_check(get_tree().get_nodes_in_group(&"enemies").size() <= Tuning.MAX_ENEMIES_ON_FIELD, "field cap")
