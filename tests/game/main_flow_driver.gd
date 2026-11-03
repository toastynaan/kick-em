extends Node
## Driver for test_main_flow.tscn (lives under the root so scene changes keep it).

var _fails := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# The test changes the debug settings: keep the user's file and values.
	var cfg_existed := FileAccess.file_exists(GameMenus.SETTINGS_PATH)
	var cfg_bytes := FileAccess.get_file_as_bytes(GameMenus.SETTINGS_PATH) if cfg_existed else PackedByteArray()
	var saved := GameMenus.own_upgrades()
	var saved_overlay := Tuning.debug_overlay
	await _frames(2)
	await _run()
	GameMenus.restore_own_upgrades()
	GameMenus.apply_upgrades(saved)
	Tuning.debug_overlay = saved_overlay
	if cfg_existed:
		var f := FileAccess.open(GameMenus.SETTINGS_PATH, FileAccess.WRITE)
		f.store_buffer(cfg_bytes)
		f.close()
	elif FileAccess.file_exists(GameMenus.SETTINGS_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameMenus.SETTINGS_PATH))
	_check(not cfg_existed or FileAccess.get_file_as_bytes(GameMenus.SETTINGS_PATH) == cfg_bytes, "the user's settings.cfg is restored byte for byte")
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

func _upgrades_match(v: Dictionary, want: Dictionary) -> bool:
	for k: String in want:
		if typeof(want[k]) == TYPE_BOOL:
			if bool(v[k]) != bool(want[k]):
				return false
		elif not is_equal_approx(float(v[k]), float(want[k])):
			return false
	return true

func _gm() -> GameMode:
	return get_tree().current_scene as GameMode

## A real key press and release, routed by the viewport as in play.
func _key(code: Key) -> void:
	for down in [true, false]:
		var ev := InputEventKey.new()
		ev.physical_keycode = code
		ev.keycode = code
		ev.pressed = down
		get_tree().root.push_input(ev)

func _pad(button: JoyButton) -> void:
	for down in [true, false]:
		var ev := InputEventJoypadButton.new()
		ev.button_index = button
		ev.pressed = down
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

	# Known starting upgrades (the Duel sets them aside and plays at max).
	GameMenus.apply_upgrades({"speed_cap": 8.0, "ram_level": 0, "teleport": true, "pursuit_max": 2,
		"charge_full": 1.0, "pressure_mult": 1.0, "launch_step": 1.0, "air_hits": 4})
	Tuning.debug_overlay = false
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
	# Pause items: resume, restart, debug settings (the player's upgrades), main menu.
	var labels2 := PackedStringArray()
	for b in gm.menus._pause.find_children("*", "Button", true, false):
		labels2.append((b as Button).text)
	print("    pause items: %s" % " | ".join(labels2))
	_check(labels2.has("RESUME") and labels2.has("RESTART  (Backspace / Back)") and labels2.has("DEBUG SETTINGS")
		and labels2.has("MAIN MENU"), "pause menu: RESUME, RESTART (Backspace / Back), DEBUG SETTINGS, MAIN MENU")

	# Debug settings (Round 7 amendment: the upgrades; Round 8 adds four). This
	# is a Duel, which plays at Tuning.R8_UPGRADE_MAX: the items show and step
	# the player's own values (saved to settings.cfg at once) while the live
	# ones stay at max. The overlay applies live.
	gm.menus.debug_settings_button.pressed.emit()
	await _frames(2)
	_check(gm.menus.screen == GameMenus.Screen.DEBUG, "DEBUG SETTINGS opens the debug screen")
	var dlabels := PackedStringArray()
	for b in gm.menus._debug.find_children("*", "Button", true, false):
		dlabels.append((b as Button).text)
	print("    debug items: %s" % " | ".join(dlabels))
	_check(gm.menus.debug_buttons.keys() == [&"speed_cap", &"ram_level", &"teleport", &"pursuit_max", &"charge_full",
		&"pressure_mult", &"launch_step", &"air_hits", &"overlay"],
		"debug items: speed cap, Battering Ram, teleport, pursuit chain, charge time, pressure, launch step, air hits, overlay (%s)" % [gm.menus.debug_buttons.keys()])
	_check(not " ".join(dlabels).contains("FOCUS"), "no starting Focus setting")
	_check(gm.menus._debug_duel_note.visible and _upgrades_match(GameMenus.upgrade_values(), Tuning.R8_UPGRADE_MAX),
		"in the Duel: every upgrade live at max, and the screen says so")
	var own := func(key: String) -> Variant: return GameMenus.own_upgrades()[key]
	(gm.menus.debug_buttons[&"speed_cap"] as Button).pressed.emit()
	_check(is_equal_approx(float(own.call("speed_cap")), 10.0) and is_equal_approx(Tuning.debug_speed_cap, 12.0),
		"speed cap 8 -> 10 (pressing the item: the own value; live stays 12)")
	gm.menus.step_debug_setting(&"speed_cap", 1)
	gm.menus.step_debug_setting(&"speed_cap", 1)
	_check(is_equal_approx(float(own.call("speed_cap")), 8.0), "speed cap cycles 10 -> 12 -> 8")
	gm.menus.step_debug_setting(&"speed_cap", -1)
	_check(is_equal_approx(float(own.call("speed_cap")), 12.0), "left steps back to 12")
	var tr := gm.player.traversal
	if tr != null and tr.has_method(&"get_speed_cap"):
		_check(is_equal_approx(float(tr.call(&"get_speed_cap")), 12.0), "live in the Duel: the player's sprint cap reads %.0f m/s" % float(tr.call(&"get_speed_cap")))
	for i in 3:
		gm.menus.step_debug_setting(&"ram_level", 1)
	_check(int(own.call("ram_level")) == 3, "Battering Ram 0 -> 3")
	_check((gm.menus.debug_buttons[&"ram_level"] as Button).text == "BATTERING RAM:  LEVEL 3  (launches)", "level 3 says it launches")
	gm.menus.step_debug_setting(&"ram_level", 1)
	_check(int(own.call("ram_level")) == 0 and Tuning.debug_ram_level == 3, "Battering Ram wraps to 0 (live stays 3)")
	gm.menus.step_debug_setting(&"ram_level", -1)
	gm.menus.step_debug_setting(&"teleport", 1)
	_check(not bool(own.call("teleport")) and Tuning.debug_teleport and (gm.menus.debug_buttons[&"teleport"] as Button).text == "TELEPORT:  OFF",
		"teleport toggles off (live stays on)")
	gm.menus.step_debug_setting(&"pursuit_max", 1)
	_check(int(own.call("pursuit_max")) == 3, "pursuit chain 2 -> 3")
	gm.menus.step_debug_setting(&"pursuit_max", 1)
	_check(int(own.call("pursuit_max")) == 0 and (gm.menus.debug_buttons[&"pursuit_max"] as Button).text == "PURSUIT CHAIN:  0  (off)",
		"pursuit chain wraps to 0 (off)")
	gm.menus.step_debug_setting(&"pursuit_max", 1)
	gm.menus.step_debug_setting(&"charge_full", 1)
	_check(is_equal_approx(float(own.call("charge_full")), 0.9) and is_equal_approx(Tuning.debug_charge_full, 0.5)
		and (gm.menus.debug_buttons[&"charge_full"] as Button).text == "CHARGE TIME:  0.9 s to full", "charge time 1.0 -> 0.9 s (live stays 0.5)")
	gm.menus.step_debug_setting(&"overlay", 1)
	_check(Tuning.debug_overlay, "debug overlay toggles on")
	await _frames(2)
	_check(gm.hud.is_debug_visible(), "HUD overlay follows the setting")
	var btn_text := (gm.menus.debug_buttons[&"speed_cap"] as Button).text
	_check(btn_text == "SPEED CAP:  12 m/s  (upgraded)", "button shows the value (%s)" % btn_text)
	var cfg2 := ConfigFile.new()
	cfg2.load(GameMenus.SETTINGS_PATH)
	_check(is_equal_approx(float(cfg2.get_value("debug", "speed_cap", 0.0)), 12.0) and int(cfg2.get_value("debug", "ram_level", -1)) == 3
		and bool(cfg2.get_value("debug", "teleport", true)) == false and int(cfg2.get_value("debug", "pursuit_max", -1)) == 1
		and is_equal_approx(float(cfg2.get_value("debug", "charge_full", 0.0)), 0.9) and int(cfg2.get_value("debug", "air_hits", -1)) == 4
		and bool(cfg2.get_value("debug", "overlay", false)) and cfg2.has_section_key("camera", "mouse_sensitivity"),
		"upgrades saved to settings.cfg next to the camera settings (%s)" % [cfg2.get_section_keys("debug")])
	# Bad values in the file are refused or clamped (loaded as the own values).
	cfg2.set_value("debug", "speed_cap", 11.0)
	cfg2.set_value("debug", "ram_level", 9)
	cfg2.set_value("debug", "pursuit_max", -4)
	cfg2.set_value("debug", "charge_full", 0.2)
	cfg2.set_value("debug", "air_hits", 40)
	cfg2.save(GameMenus.SETTINGS_PATH)
	GameMenus.load_debug_settings(true)
	_check(is_equal_approx(float(own.call("speed_cap")), 12.0) and int(own.call("ram_level")) == 3 and int(own.call("pursuit_max")) == 0
		and is_equal_approx(float(own.call("charge_full")), 0.5) and int(own.call("air_hits")) == 6
		and _upgrades_match(GameMenus.upgrade_values(), Tuning.R8_UPGRADE_MAX),
		"a cap that is not 8/10/12 is ignored; levels and Round 8 values clamp; live stays max (%s)" % [GameMenus.own_upgrades()])
	_key(KEY_ESCAPE)
	await _frames(2)
	_check(gm.menus.screen == GameMenus.Screen.PAUSE and get_tree().paused, "Esc in debug settings goes back to pause")
	Tuning.debug_overlay = false
	gm.resume()
	await _frames(2)
	_check(not get_tree().paused and gm.menus.screen == GameMenus.Screen.NONE, "resume")

	# Restart from the pause menu's item.
	gm.pause()
	await _frames(2)
	var old := gm
	gm.menus.restart_button.pressed.emit()
	await _frames(8)
	gm = _gm()
	_check(gm != null and gm != old, "pause > RESTART reloads the scene")
	if gm == null:
		return
	_check(gm.mode == &"duel" and gm.phase == GameMode.Phase.FIGHTING and gm.player != null and not get_tree().paused,
		"restart goes straight back into a duel, unpaused")
	_check(get_tree().get_nodes_in_group(&"player").size() == 1, "exactly one player after restart")

	# Backspace in play restarts (the real key, routed by the viewport as in play).
	await _frames(4)
	old = gm
	_key(KEY_BACKSPACE)
	await _frames(8)
	gm = _gm()
	_check(gm != null and gm != old and gm.phase == GameMode.Phase.FIGHTING and gm.mode == &"duel", "Backspace in play restarts the duel")
	if gm == null:
		return

	# Esc, then Backspace in the pause menu. GameMenus once called get_viewport()
	# after the reload had already taken it out of the tree: a SCRIPT ERROR that
	# froze the editor run.
	await _frames(4)
	_key(KEY_ESCAPE)
	await _frames(2)
	_check(get_tree().paused and gm.menus.screen == GameMenus.Screen.PAUSE, "Esc pauses")
	old = gm
	_key(KEY_BACKSPACE)
	await _frames(8)
	gm = _gm()
	_check(gm != null and gm != old and gm.phase == GameMode.Phase.FIGHTING and not get_tree().paused,
		"Backspace in the pause menu restarts the duel")
	if gm == null:
		return

	# Gamepad: Start pauses, Back restarts.
	await _frames(4)
	_pad(JOY_BUTTON_START)
	await _frames(2)
	_check(get_tree().paused and gm.menus.screen == GameMenus.Screen.PAUSE, "Start pauses")
	old = gm
	_pad(JOY_BUTTON_BACK)
	await _frames(8)
	gm = _gm()
	_check(gm != null and gm != old and gm.phase == GameMode.Phase.FIGHTING, "Back (gamepad) restarts the duel")
	if gm == null:
		return

	gm.back_to_menu()
	await _frames(8)
	gm = _gm()
	_check(gm != null and gm.phase == GameMode.Phase.TITLE and gm.menus.screen == GameMenus.Screen.TITLE, "main menu returns to the title")
	if gm == null:
		return
	old = gm
	_key(KEY_BACKSPACE)
	await _frames(8)
	_check(_gm() == old and gm.phase == GameMode.Phase.TITLE and gm.player == null, "Backspace on the title does nothing")

	gm.menus.waves_pressed.emit()
	await _frames(6)
	_check(gm.mode == &"waves" and gm.wave_index == 0, "WAVES starts from the menu")
	for i in 240:
		await get_tree().physics_frame
	_check(gm.get_alive_enemies().size() >= 1, "wave enemies spawned (%d alive)" % gm.get_alive_enemies().size())
	_check(get_tree().get_nodes_in_group(&"enemies").size() <= Tuning.MAX_ENEMIES_ON_FIELD, "field cap")
