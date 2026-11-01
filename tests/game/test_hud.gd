extends Node
## HUD: world popups (WALL SLAM, THROUGH N WALLS, ARMOR, EARLY/LATE), staged
## breaches do not announce WALL BREAK, the duel opponent bar tracks HP, and
## popups expire.

var _fails := 0

func _ready() -> void:
	for i in 5:
		await get_tree().process_frame
	await _run()
	print("TEST test_hud: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
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

func _has(hud: HUD, text: String) -> bool:
	return hud.get_popup_texts().has(text)

func _run() -> void:
	var world := Node3D.new()
	add_child(world)
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.look_at_from_position(Vector3(0, 3, 8), Vector3(0, 1, 0))
	cam.make_current()
	var player := FighterFactory.spawn_dummy(world, &"player", Transform3D(Basis(), Vector3(0, 0.05, 2)), Fighter.TEAM_PLAYER)
	var enemy := FighterFactory.spawn_dummy(world, &"duelist", Transform3D(Basis(), Vector3(0, 0.05, -2)))
	var hud := HUD.new()
	add_child(hud)
	hud.set_player(player)
	hud.set_mode(&"duel")
	await _frames(3)

	GameEvents.impact_damaged.emit(enemy, 271.0, 5920.0, &"brick", Vector3(0, 1.4, -3))
	GameEvents.impact_damaged.emit(enemy, 40.0, 1300.0, &"concrete", Vector3(0, 0.1, -3))
	GameEvents.impact_damaged.emit(enemy, 25.0, 1000.0, &"body", Vector3(0, 1.0, -3))
	GameEvents.impact_damaged.emit(enemy, 0.2, 510.0, &"concrete", Vector3(0, 1.0, -3))
	await _frames(2)
	_check(_has(hud, "WALL SLAM −271"), "wall impact popup 'WALL SLAM −271'")
	_check(_has(hud, "FLOOR SLAM −40"), "low impact reads as FLOOR SLAM")
	_check(_has(hud, "BODY SLAM −25"), "body impact reads as BODY SLAM")
	_check(hud.get_popup_texts().size() == 3, "sub-1 HP impacts make no popup")

	GameEvents.wall_chain.emit(enemy, 2)
	GameEvents.wall_chain.emit(enemy, 1)
	var armor := HitInfo.new()
	armor.attacker = player
	armor.victim = enemy
	GameEvents.armor_absorbed.emit(armor)
	GameEvents.dodge_feedback.emit(player, &"early")
	GameEvents.dodge_feedback.emit(enemy, &"late")
	await _frames(2)
	_check(_has(hud, "THROUGH 2 WALLS"), "wall chain popup 'THROUGH 2 WALLS'")
	_check(not _has(hud, "THROUGH 1 WALLS"), "a single wall is not a chain")
	_check(_has(hud, "ARMOR"), "armor_absorbed popup 'ARMOR'")
	_check(_has(hud, "EARLY") and not _has(hud, "LATE"), "dodge feedback only for the player")
	_check(hud._popups.items.size() >= 5, "popups project on screen (%d drawn)" % hud._popups.items.size())

	await _wait_real(1.8)
	_check(hud.get_popup_texts().is_empty(), "popups expire")

	# Staged breach: no WALL BREAK; a real break still announces.
	var staged := Node3D.new()
	var real := Node3D.new()
	world.add_child(staged)
	world.add_child(real)
	hud.suppress_wall_break(staged)
	hud._pop_label.text = ""
	GameEvents.wall_broken.emit(staged, Vector3.ZERO, 3000.0, Vector3.ZERO)
	_check(hud._pop_label.text != "WALL BREAK", "staged breach does not show WALL BREAK")
	GameEvents.wall_broken.emit(real, Vector3.ZERO, 3000.0, Vector3.ZERO)
	_check(hud._pop_label.text == "WALL BREAK", "a real wall break shows WALL BREAK")

	# Layout: popups stay inside safe margins and out of the banner band.
	await _wait_real(1.6)
	var vp := get_viewport().get_visible_rect()
	hud.pop_text("WALL BREAK", Color(1.0, 0.85, 0.35), 2.0)
	await _frames(12)  # let the pop-in scale settle
	var banners := hud.get_banner_rects()
	_check(banners.size() >= 1, "banner rect reported while WALL BREAK shows")
	var band_center := banners[0].get_center() if not banners.is_empty() else vp.size * 0.3
	hud.popup_at(cam.project_position(band_center, 6.0), "WALL SLAM −196", Color(1, 0.8, 0.3), 40, 1.5)
	hud.popup_at(cam.project_position(Vector2(4.0, vp.size.y * 0.6), 6.0), "WALL SLAM −138", Color(1, 0.8, 0.3), 40, 1.5)
	hud.popup_at(cam.project_position(Vector2(vp.size.x - 2.0, 10.0), 6.0), "FLOOR SLAM −55", Color(1, 0.8, 0.3), 40, 1.5)
	await _frames(3)
	var rects := hud.get_popup_rects()
	_check(rects.size() == 3, "three popups laid out (%d)" % rects.size())
	var inside := true
	var clear := true
	for r in rects:
		if not vp.grow(-8.0).encloses(r):
			inside = false
		for b in hud.get_banner_rects():
			if r.intersects(b):
				clear = false
	_check(inside, "popups clamped inside the screen margins")
	_check(clear, "popups never overlap the banner")
	await _wait_real(2.2)

	# THROUGH N WALLS merges into the banner, in either event order.
	GameEvents.wall_broken.emit(real, Vector3.ZERO, 3000.0, Vector3.ZERO)
	GameEvents.wall_chain.emit(enemy, 2)
	await _frames(2)
	_check(hud._pop_label.text == "THROUGH 2 WALLS" and not _has(hud, "THROUGH 2 WALLS"),
		"WALL BREAK then chain: one banner 'THROUGH 2 WALLS', no world popup")
	await _wait_real(1.5)
	GameEvents.wall_chain.emit(enemy, 3)
	_check(_has(hud, "THROUGH 3 WALLS"), "a chain on its own is a world popup")
	GameEvents.wall_broken.emit(real, Vector3.ZERO, 3000.0, Vector3.ZERO)
	await _frames(2)
	_check(hud._pop_label.text == "THROUGH 3 WALLS" and not _has(hud, "THROUGH 3 WALLS"),
		"chain then WALL BREAK: merged into the banner")
	await _wait_real(1.6)

	# Duel opponent bar.
	_check(not hud._opp_root.visible, "no enemy bar until set_opponent (waves keep none)")
	hud.set_opponent(enemy)
	await _frames(2)
	_check(hud._opp_root.visible, "duel opponent bar shown")
	var start_hp := enemy.hp
	enemy.apply_damage(100.0, &"test")
	enemy.add_focus(1.5)
	await _frames(3)
	_check(enemy.hp < start_hp and hud._opp_hp_label.text == "%d" % ceili(enemy.hp), "opponent HP label follows damage (%s)" % hud._opp_hp_label.text)
	_check(absf(hud._opp_bars.hp - enemy.hp / enemy.max_hp) < 0.01 and hud._opp_bars.hp_delayed > hud._opp_bars.hp,
		"opponent bar drops with a trailing damage bar")
	_check(absf(hud._opp_bars.focus - enemy.focus) < 0.01, "opponent Focus pips follow focus (%.2f)" % enemy.focus)
	enemy.queue_free()
	await _frames(3)
	_check(hud._opp_hp_label.text == "0", "freed opponent shows an empty bar without errors")
