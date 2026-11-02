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
