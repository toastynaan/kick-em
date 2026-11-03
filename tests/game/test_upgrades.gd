extends Node
## Round 8 upgrades (J): the pause menu's Debug settings for the four new
## upgrades, and the Duel at max.
## - GameMenus: nine items (speed cap, ram, teleport, pursuit, charge time,
##   pressure, launch step, air hits, overlay); charge time 1.0 .. 0.5 s (0.1
##   steps), pressure x1 .. x2 (0.25), launch step 1.0 .. 0.5 (0.1), air hits
##   4 .. 6; each step applies to Tuning at once, wraps both ways, and saves to
##   settings.cfg; a load reads them back; out-of-range values clamp, odd ones
##   snap to the menu's values; the screen fits 1600x900.
## - GameMode: a Duel applies every upgrade at Tuning.R8_UPGRADE_MAX before the
##   fighters spawn; saves during it write the player's own values; Debug
##   settings shows and edits the own values while the live ones stay at max
##   (a load too); a restart keeps max; the round's end, the main menu,
##   switching to Waves and freeing the GameMode restore the player's own;
##   Waves uses them as they are.
## The user's settings.cfg is put back byte for byte at the end.

var _fails := 0
var _cfg_existed := false
var _cfg_bytes := PackedByteArray()

func _ready() -> void:
	await get_tree().process_frame
	_cfg_existed = FileAccess.file_exists(GameMenus.SETTINGS_PATH)
	if _cfg_existed:
		_cfg_bytes = FileAccess.get_file_as_bytes(GameMenus.SETTINGS_PATH)
	var saved := GameMenus.upgrade_values()
	var saved_overlay := Tuning.debug_overlay
	await _run()
	GameMenus.restore_own_upgrades()
	GameMenus.apply_upgrades(saved)
	Tuning.debug_overlay = saved_overlay
	_restore_cfg()
	TimeDirector.reset()
	print("TEST test_upgrades: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _restore_cfg() -> void:
	if _cfg_existed:
		var f := FileAccess.open(GameMenus.SETTINGS_PATH, FileAccess.WRITE)
		f.store_buffer(_cfg_bytes)
		f.close()
	elif FileAccess.file_exists(GameMenus.SETTINGS_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameMenus.SETTINGS_PATH))
	var back := FileAccess.get_file_as_bytes(GameMenus.SETTINGS_PATH) if _cfg_existed else PackedByteArray()
	_check(back == _cfg_bytes, "the user's settings.cfg is restored byte for byte")

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _cfg() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(GameMenus.SETTINGS_PATH)
	return cfg

func _defaults() -> void:
	GameMenus.apply_upgrades({"speed_cap": 8.0, "ram_level": 0, "teleport": true, "pursuit_max": 2,
		"charge_full": 1.0, "pressure_mult": 1.0, "launch_step": 1.0, "air_hits": 4})

func _same(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if not is_equal_approx(float(a[i]), float(b[i])):
			return false
	return true

func _matches(v: Dictionary, want: Dictionary) -> bool:
	for k: String in want:
		if typeof(want[k]) == TYPE_BOOL:
			if bool(v[k]) != bool(want[k]):
				return false
		elif not is_equal_approx(float(v[k]), float(want[k])):
			return false
	return true

func _run() -> void:
	await _menus()
	await _duel()

# --- Debug settings ----------------------------------------------------------------------
func _menus() -> void:
	var menus := GameMenus.new()
	add_child(menus)
	await _frames(1)
	_defaults()
	menus.show_debug()
	await _frames(2)
	var keys: Array = menus.debug_buttons.keys()
	print("    debug items: %s" % " | ".join(keys.map(func(k: StringName) -> String: return (menus.debug_buttons[k] as Button).text)))
	_check(keys == [&"speed_cap", &"ram_level", &"teleport", &"pursuit_max", &"charge_full", &"pressure_mult",
		&"launch_step", &"air_hits", &"overlay"], "nine items, the Round 8 four after the pursuit chain (%s)" % [keys])
	var panel := menus._debug.find_children("*", "PanelContainer", true, false)[0] as PanelContainer
	var sz := panel.get_combined_minimum_size()
	print("    Debug settings panel minimum size %s" % sz)
	_check(sz.x <= 1600.0 and sz.y <= 900.0, "the Debug settings panel fits 1600x900 (%.0f x %.0f)" % [sz.x, sz.y])

	# Menu values: start .. Tuning.R8_UPGRADE_MAX.
	_check(_same(GameMenus.upgrade_steps("charge_full"), [1.0, 0.9, 0.8, 0.7, 0.6, 0.5]), "charge time 1.0 .. 0.5 s by 0.1 (%s)" % [GameMenus.upgrade_steps("charge_full")])
	_check(_same(GameMenus.upgrade_steps("pressure_mult"), [1.0, 1.25, 1.5, 1.75, 2.0]), "pressure x1 .. x2 by 0.25 (%s)" % [GameMenus.upgrade_steps("pressure_mult")])
	_check(_same(GameMenus.upgrade_steps("launch_step"), [1.0, 0.9, 0.8, 0.7, 0.6, 0.5]), "launch step 1.0 .. 0.5 by 0.1 (%s)" % [GameMenus.upgrade_steps("launch_step")])
	_check(_same(GameMenus.upgrade_steps("air_hits"), [4.0, 5.0, 6.0]), "air hits 4 .. 6 (%s)" % [GameMenus.upgrade_steps("air_hits")])

	# Each step applies at once, saves, and wraps.
	var seen: Array[float] = []
	for i in 6:
		(menus.debug_buttons[&"charge_full"] as Button).pressed.emit()
		seen.append(Tuning.debug_charge_full)
	_check(_same(seen, [0.9, 0.8, 0.7, 0.6, 0.5, 1.0]), "charge time steps 0.9 .. 0.5 then wraps to 1.0 (%s)" % [seen])
	menus.step_debug_setting(&"charge_full", -1)
	_check(is_equal_approx(Tuning.debug_charge_full, 0.5), "left from 1.0 goes to 0.5")
	_check((menus.debug_buttons[&"charge_full"] as Button).text == "CHARGE TIME:  0.5 s to full  (max)",
		"label: %s" % (menus.debug_buttons[&"charge_full"] as Button).text)
	_check(is_equal_approx(float(_cfg().get_value("debug", "charge_full", 0.0)), 0.5), "saved: charge_full 0.5")
	for i in 4:
		menus.step_debug_setting(&"pressure_mult", 1)
	_check(is_equal_approx(Tuning.debug_pressure_mult, 2.0) and (menus.debug_buttons[&"pressure_mult"] as Button).text == "PRESSURE:  x2.00 per hit  (max)",
		"pressure x1 -> x2 in four steps (%s)" % (menus.debug_buttons[&"pressure_mult"] as Button).text)
	menus.step_debug_setting(&"pressure_mult", 1)
	_check(is_equal_approx(Tuning.debug_pressure_mult, 1.0), "pressure wraps to x1")
	menus.step_debug_setting(&"launch_step", -1)
	_check(is_equal_approx(Tuning.debug_launch_step, 0.5) and (menus.debug_buttons[&"launch_step"] as Button).text == "LAUNCH STEP:  from 50% charge  (max)",
		"launch step: left from 1.0 is 0.5 (%s)" % (menus.debug_buttons[&"launch_step"] as Button).text)
	menus.step_debug_setting(&"launch_step", 1)
	_check(is_equal_approx(Tuning.debug_launch_step, 1.0) and (menus.debug_buttons[&"launch_step"] as Button).text == "LAUNCH STEP:  full charge  (base)",
		"and back to full charge (%s)" % (menus.debug_buttons[&"launch_step"] as Button).text)
	menus.step_debug_setting(&"air_hits", 1)
	menus.step_debug_setting(&"air_hits", 1)
	_check(Tuning.debug_air_hits == 6 and (menus.debug_buttons[&"air_hits"] as Button).text == "AIR HITS:  6 per combo  (max)",
		"air hits 4 -> 6 (%s)" % (menus.debug_buttons[&"air_hits"] as Button).text)
	menus.step_debug_setting(&"air_hits", 1)
	_check(Tuning.debug_air_hits == 4, "air hits wrap to 4")
	_check(not menus._debug_duel_note.visible, "outside a Duel: no Duel note")

	# Save, then load back.
	Tuning.debug_charge_full = 1.0
	menus.step_debug_setting(&"charge_full", 1)
	menus.step_debug_setting(&"charge_full", 1)
	menus.step_debug_setting(&"pressure_mult", 1)
	menus.step_debug_setting(&"pressure_mult", 1)
	menus.step_debug_setting(&"launch_step", 1)
	menus.step_debug_setting(&"air_hits", 1)
	var want := {"charge_full": 0.8, "pressure_mult": 1.5, "launch_step": 0.9, "air_hits": 5}
	var cfg := _cfg()
	var file := {}
	for k: String in want:
		file[k] = cfg.get_value("debug", k, -1.0)
	_check(_matches(file, want), "saved to settings.cfg next to the camera settings (%s)" % [file])
	_defaults()
	GameMenus.load_debug_settings(true)
	_check(_matches(GameMenus.upgrade_values(), want), "and load back (%s)" % [GameMenus.upgrade_values()])

	# Clamping: out of range clamps, in between snaps to a menu value.
	for case: Array in [[{"charge_full": 0.1, "pressure_mult": 9.0, "launch_step": 3.0, "air_hits": 99},
				{"charge_full": 0.5, "pressure_mult": 2.0, "launch_step": 1.0, "air_hits": 6}],
			[{"charge_full": 4.0, "pressure_mult": -1.0, "launch_step": -2.0, "air_hits": -3},
				{"charge_full": 1.0, "pressure_mult": 1.0, "launch_step": 0.5, "air_hits": 4}],
			[{"charge_full": 0.73, "pressure_mult": 1.3, "launch_step": 0.86, "air_hits": 5},
				{"charge_full": 0.7, "pressure_mult": 1.25, "launch_step": 0.9, "air_hits": 5}]]:
		cfg = _cfg()
		for k: String in case[0]:
			cfg.set_value("debug", k, case[0][k])
		cfg.save(GameMenus.SETTINGS_PATH)
		GameMenus.load_debug_settings(true)
		_check(_matches(GameMenus.upgrade_values(), case[1]), "load %s -> %s (got %s)" % [case[0], case[1], GameMenus.upgrade_values()])
	menus.queue_free()
	await _frames(1)

# --- The Duel at max ------------------------------------------------------------------------
func _duel() -> void:
	var own := {"speed_cap": 10.0, "ram_level": 1, "teleport": false, "pursuit_max": 1, "charge_full": 0.8,
		"pressure_mult": 1.25, "launch_step": 0.9, "air_hits": 5}
	GameMenus.apply_upgrades(own)
	GameMenus.save_debug_settings()
	var maxed: Dictionary = Tuning.R8_UPGRADE_MAX
	var gm := GameMode.new()
	gm.show_title = false
	add_child(gm)
	var at_spawn := {}
	var probe := func(f: Node3D) -> void:
		if f is Fighter and (f as Fighter).is_player:
			at_spawn.merge(GameMenus.upgrade_values(), true)
	GameEvents.fighter_spawned.connect(probe)
	gm.start_round(&"duel")
	GameEvents.fighter_spawned.disconnect(probe)
	await _frames(2)
	print("    duel: live %s" % [GameMenus.upgrade_values()])
	_check(_matches(GameMenus.upgrade_values(), maxed), "Duel: every upgrade at Tuning.R8_UPGRADE_MAX")
	_check(not at_spawn.is_empty() and _matches(at_spawn, maxed), "already at max when the player spawned")
	_check(GameMenus.is_max_upgrades_applied() and _matches(GameMenus.own_upgrades(), own), "the player's own values set aside")
	var tr := gm.player.traversal
	if tr != null and tr.has_method(&"get_speed_cap"):
		_check(is_equal_approx(float(tr.call(&"get_speed_cap")), 12.0), "the player's sprint cap reads %.0f m/s" % float(tr.call(&"get_speed_cap")))

	# Saves in the Duel write the own values, never the max.
	gm.hud.toggle_debug()  # F3 saves
	var cfg := _cfg()
	var file := {}
	for k: String in own:
		file[k] = cfg.get_value("debug", k, -1.0)
	_check(_matches(file, own), "a save during the Duel writes the player's own values (%s)" % [file])

	# Debug settings in the Duel: shows and edits the own values; the live ones stay max.
	gm.pause()
	await _frames(1)
	gm.menus.show_debug()
	await _frames(2)
	_check(gm.menus._debug_duel_note.visible, "Debug settings in the Duel says every upgrade is at max")
	_check((gm.menus.debug_buttons[&"charge_full"] as Button).text.begins_with("CHARGE TIME:  0.8 s")
		and (gm.menus.debug_buttons[&"speed_cap"] as Button).text.begins_with("SPEED CAP:  10 m/s"),
		"and shows the player's own values (%s, %s)" % [(gm.menus.debug_buttons[&"charge_full"] as Button).text,
			(gm.menus.debug_buttons[&"speed_cap"] as Button).text])
	gm.menus.step_debug_setting(&"charge_full", 1)
	gm.menus.step_debug_setting(&"teleport", 1)
	own["charge_full"] = 0.7
	own["teleport"] = true
	_check(_matches(GameMenus.upgrade_values(), maxed) and _matches(GameMenus.own_upgrades(), own)
		and is_equal_approx(float(_cfg().get_value("debug", "charge_full", 0.0)), 0.7) and bool(_cfg().get_value("debug", "teleport", false)),
		"a step edits and saves the own value (charge 0.7, teleport on); live stays max")
	GameMenus.load_debug_settings(true)
	_check(_matches(GameMenus.upgrade_values(), maxed) and _matches(GameMenus.own_upgrades(), own), "a load in the Duel loads the own values; live stays max")
	gm.resume()
	await _frames(1)

	# A restart keeps max.
	gm.restart()
	await _frames(3)
	_check(gm.mode == &"duel" and _matches(GameMenus.upgrade_values(), maxed) and _matches(GameMenus.own_upgrades(), own),
		"restart: the Duel again, still at max")

	# The round's end restores the player's own.
	var duelist: Fighter = gm.get_alive_enemies()[0]
	duelist.apply_damage(duelist.max_hp + 10.0, &"test")
	for i in 10:
		await get_tree().physics_frame
	_check(gm.is_round_over() and not GameMenus.is_max_upgrades_applied() and _matches(GameMenus.upgrade_values(), own),
		"the Duel's end restores the player's own upgrades (%s)" % [GameMenus.upgrade_values()])
	gm.restart()
	await _frames(3)
	_check(_matches(GameMenus.upgrade_values(), maxed), "restart from the results: max again")
	gm.back_to_menu()
	await _frames(3)
	_check(gm.phase == GameMode.Phase.TITLE and _matches(GameMenus.upgrade_values(), own), "main menu: own values back")

	# Waves use the player's own values; leaving the Duel for Waves restores them.
	gm.start_round(&"waves")
	await _frames(2)
	_check(_matches(GameMenus.upgrade_values(), own) and not GameMenus.is_max_upgrades_applied(), "Waves: the player's own upgrades")
	gm.start_round(&"duel")
	await _frames(2)
	_check(_matches(GameMenus.upgrade_values(), maxed), "Duel again: max")
	gm.start_round(&"waves")
	await _frames(2)
	_check(_matches(GameMenus.upgrade_values(), own), "Duel -> Waves: own values")
	gm.start_round(&"duel")
	await _frames(2)
	gm.queue_free()
	await _frames(2)
	_check(_matches(GameMenus.upgrade_values(), own) and not GameMenus.is_max_upgrades_applied(),
		"freeing the GameMode mid-Duel restores the own values")
	cfg = _cfg()
	file = {}
	for k: String in own:
		file[k] = cfg.get_value("debug", k, -1.0)
	_check(_matches(file, own), "settings.cfg never held the max (%s)" % [file])
