extends Node
## HUD: world popups (WALL SLAM, THROUGH N WALLS, ARMOR), staged breaches do
## not announce WALL BREAK, the duel opponent bar tracks HP, popups expire, the
## layer sits above ScreenFX, HP on the 100 scale, off-screen arrows (orange
## strike, blue grab or charge, gone at the first active frame), and the Round 7
## F3 debug overlay (move, string, chain, glide, the target's reaction state,
## the last hit's Round 7 fields) mirroring Tuning.debug_overlay. Round 7
## removed the Focus bars, the reticle and lock-on marker, the charge meter,
## the counter-bonus cue, parry feedback and the sprint marker: none is built.
## (Combo counter: test_hud_combo. Counter prompts: test_hud_prompts. Help:
## test_help_controls.)

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
	# A floor, so the dummies stand where they were put (arrows, prompts).
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
	await _frames(2)
	_check(_has(hud, "THROUGH 2 WALLS"), "wall chain popup 'THROUGH 2 WALLS'")
	_check(not _has(hud, "THROUGH 1 WALLS"), "a single wall is not a chain")
	_check(_has(hud, "ARMOR"), "armor_absorbed popup 'ARMOR'")
	_check(hud._popups.items.size() >= 4, "popups project on screen (%d drawn)" % hud._popups.items.size())

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
	await _frames(3)
	_check(enemy.hp < start_hp and hud._opp_hp_label.text == "%d" % ceili(enemy.hp), "opponent HP label follows damage (%s)" % hud._opp_hp_label.text)
	_check(absf(hud._opp_bars.hp - enemy.hp / enemy.max_hp) < 0.01 and hud._opp_bars.hp_delayed > hud._opp_bars.hp,
		"opponent bar drops with a trailing damage bar")
	enemy.queue_free()
	await _frames(3)
	_check(hud._opp_hp_label.text == "0", "freed opponent shows an empty bar without errors")

	# --- Round 3: strike-made holes announce WALL BREAK once, not on every jab ----
	var panel := _FakePanel.new()
	world.add_child(panel)
	var shows := func(p: _FakePanel, holes: int, by_strike: bool, broken: bool) -> bool:
		p.strike_holes = holes
		p.last_break_by_strike = by_strike
		p.is_broken = broken
		hud._pop_label.text = ""
		GameEvents.wall_broken.emit(p, Vector3.ZERO, 900.0, Vector3.ZERO)
		return hud._pop_label.text == "WALL BREAK"
	_check(shows.call(panel, 1, true, false), "first strike hole shows WALL BREAK")
	_check(not shows.call(panel, 2, true, false), "a jab widening the hole shows no banner")
	_check(not shows.call(panel, 3, true, false), "nor the next one")
	_check(shows.call(panel, 4, true, true), "a strike that breaks the whole panel shows it again")
	var other_panel := _FakePanel.new()
	world.add_child(other_panel)
	_check(shows.call(other_panel, 0, false, true), "a body impact break still shows WALL BREAK")
	_check(shows.call(other_panel, 2, false, false), "impact breaks ignore the strike-hole count")
	var plain := Node3D.new()
	world.add_child(plain)
	hud._pop_label.text = ""
	GameEvents.wall_broken.emit(plain, Vector3.ZERO, 900.0, Vector3.ZERO)
	_check(hud._pop_label.text == "WALL BREAK", "walls without the strike fields (before D lands) still announce")
	# The pop sits in the upper band, off the screen centre where the hole is.
	var pr := hud._pop_label.get_global_rect()
	var pop_center_y := pr.position.y + pr.size.y * 0.5
	var vh := get_viewport().get_visible_rect().size.y
	_check(pop_center_y < vh * 0.25 and pop_center_y > vh * 0.12, "WALL BREAK pop in the upper band (%.0f%% of height)" % (100.0 * pop_center_y / vh))

	await _round7(hud, world, player, cam)

# --- Layer, HP, arrows, Round 7 debug overlay --------------------------------------------
func _round7(hud: HUD, world: Node3D, player: Fighter, cam: Camera3D) -> void:
	var foe := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(0, 0.05, -2)))
	var behind := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(3, 0.05, 14)))
	# The wall breaks above were granted slow time; wind-up clocks run in game
	# time, so start the arrow checks at full speed.
	TimeDirector.reset()
	await _frames(4)

	# Layer: above every ScreenFX layer, so screen effects never dim the HUD.
	var fx_top := -1000
	var fx := get_tree().root.get_node_or_null(^"ScreenFX")
	for l: CanvasLayer in (fx.find_children("*", "CanvasLayer", true, false) if fx else []):
		fx_top = maxi(fx_top, l.layer)
	if fx is CanvasLayer:
		fx_top = maxi(fx_top, (fx as CanvasLayer).layer)
	_check(hud.layer > fx_top and hud.layer >= HUD.HUD_LAYER, "HUD layer %d above ScreenFX (%d)" % [hud.layer, fx_top])

	# HP on the 100 scale.
	player.hp = player.max_hp
	await _frames(2)
	_check(player.max_hp == 100.0 and hud._hp_label.text == "100", "player HP reads 100 (%s)" % hud._hp_label.text)

	# Off-screen arrows: from the wind-up to the first active frame.
	_check(not cam.is_position_in_frustum(behind.get_aim_point()), "test enemy is behind the camera")
	GameEvents.attack_tell.emit(behind, &"strike", 1.0)
	await _frames(2)
	var arrows := hud.get_arrows()
	_check(arrows.size() == 1 and (arrows[0]["color"] as Color).is_equal_approx(UIKit.TELL_STRIKE), "off-screen strike wind-up: one orange arrow")
	if arrows.size() == 1:
		var pos: Vector2 = arrows[0]["pos"]
		var vp := get_viewport().get_visible_rect().size
		var at_edge := pos.x <= HUD.ARROW_MARGIN + 1.0 or pos.x >= vp.x - HUD.ARROW_MARGIN - 1.0 \
			or pos.y <= HUD.ARROW_MARGIN + 1.0 or pos.y >= vp.y - HUD.ARROW_MARGIN - 1.0
		_check(at_edge, "arrow sits at the screen edge (%s)" % pos)
	GameEvents.attack_active.emit(behind, &"e_jab")
	await _frames(2)
	_check(hud.get_arrows().is_empty(), "arrow gone on the first active frame")
	GameEvents.attack_tell.emit(behind, &"grab", 0.2)
	await _frames(2)
	arrows = hud.get_arrows()
	_check(arrows.size() == 1 and (arrows[0]["color"] as Color).is_equal_approx(UIKit.TELL_GRAB), "off-screen grab wind-up: one blue arrow")
	await _wait_real(0.2 + HUD.ARROW_GRACE + 0.15)
	_check(hud.get_arrows().is_empty(), "an interrupted wind-up's arrow expires")
	GameEvents.attack_tell.emit(behind, &"charge", 0.5)
	await _frames(2)
	arrows = hud.get_arrows()
	_check(arrows.size() == 1 and (arrows[0]["color"] as Color).is_equal_approx(UIKit.TELL_GRAB), "off-screen charge (uncounterable): blue arrow")
	GameEvents.attack_active.emit(behind, &"e_charge")
	GameEvents.attack_tell.emit(foe, &"strike", 1.0)
	await _frames(2)
	_check(hud.get_arrows().is_empty(), "an on-screen wind-up gets no arrow")
	GameEvents.attack_active.emit(foe, &"e_jab")

	# Removed Round 5 UI is not built.
	_check(not ("_reticle" in hud) and not ("_lock_marker" in hud) and not ("_charge" in hud)
		and not ("_counter_label" in hud) and not ("_sprint_marker" in hud) and not ("_focus_label" in hud)
		and not ("focus" in hud._bars), "no Focus bars, reticle, lock marker, charge meter, counter-bonus cue or sprint marker")

	# F3 debug overlay: mirrors Tuning.debug_overlay; shows the Round 7 combat state.
	var saved_overlay := Tuning.debug_overlay
	Tuning.debug_overlay = true
	await _frames(2)
	_check(hud.is_debug_visible(), "Tuning.debug_overlay on -> overlay shown")
	var info := HitInfo.new()
	info.attacker = player
	info.victim = foe
	info.move_id = &"cross"
	info.react = &"snap"
	info.damage = 7.0
	info.weight = 0.3
	info.push = 0.6
	info.stun = 0.5
	info.chain_index = 2
	player.combat.last_dealt = info
	var text := hud.get_debug_text()
	var own := text.substr(0, text.find("FPS"))
	print("    overlay:\n      " + "\n      ".join(own.strip_edges().split("\n")))
	_check(own.contains("MOVE") and own.contains("STRING     1/3 (next punch: JAB)") and own.contains("CHAIN 0 hits")
		and own.contains("GLIDE off"), "overlay: move, string position, chain, glide")
	_check(own.contains("TARGET     %s (last hit)  react " % foe.name), "overlay: the target (falls back to the last hit's victim) and its reaction state")
	_check(own.contains("LAST HIT   cross") and own.contains("SNAP") and own.contains("w 0.30") and own.contains("push 0.60")
		and own.contains("stun 0.50") and own.contains("chain #2"), "overlay: the last hit's Round 7 fields")
	_check(own.contains("HP 100 / 100") and own.contains("SPEED") and own.contains("PROMPTS"), "overlay: speed, health, open prompts")
	_check(own.contains("UPGRADES   speed cap") and own.contains("teleport") and own.contains("pursuit x"),
		"overlay: the god-path upgrades (speed cap, ram, teleport, pursuit chain)")
	var stale := PackedStringArray()
	for w in ["FOCUS", "sprint_charge", "charge", "P 0."]:
		if own.contains(w):
			stale.append(w)
	_check(stale.is_empty(), "overlay: nothing from removed systems (found: %s)" % ", ".join(stale))
	var world_line := HUD.world_debug_line()
	print("    " + world_line)
	_check(text.contains("WORLD") and world_line.contains("debris") and world_line.contains("/%d" % Tuning.DEBRIS_MAX)
		and world_line.contains("smashed") and world_line.contains("marks"), "overlay shows debris (cap), clutter smashed and floor marks")
	# The overlay lines for a live strike (B's values through the contract).
	var lines := "\n".join(HUD.combat_debug_lines({"move": &"uppercut", "phase": "ACTIVE", "string_index": 2, "chain": 4,
		"glide": true, "buffered": "punch", "hud_combo": 4, "target": "Grunt3 (combat target)", "target_react": &"fold",
		"target_left": 0.62, "target_dist": 1.4, "target_down": false, "target_lifted": false}))
	print("    live strike:\n      " + lines.replace("\n", "\n      "))
	_check(lines.contains("uppercut") and lines.contains("ACTIVE") and lines.contains("buffered punch")
		and lines.contains("3/3 (next punch: HOOK)") and lines.contains("CHAIN 4 hits") and lines.contains("GLIDE ON")
		and lines.contains("Grunt3 (combat target)  react FOLD 0.62 s"), "overlay lines: move, phase, buffer, string, chain, glide, target state")
	var probe := hud.gather_combat_debug()
	_check(probe.has("move") and probe.has("string_index") and probe.has("chain") and probe.has("glide") and probe.has("target_react"),
		"gather_combat_debug reads the contract (%s)" % [probe.keys()])
	hud.toggle_debug()
	_check(not hud.is_debug_visible() and not Tuning.debug_overlay, "F3 hides it and clears Tuning.debug_overlay")
	Tuning.debug_overlay = saved_overlay
	GameMenus.save_debug_settings()
	foe.queue_free()
	behind.queue_free()
	await _frames(2)

## Stand-in for a Destructible with D's round-3 fields.
class _FakePanel extends Node3D:
	var strike_holes := 0
	var last_break_by_strike := false
	var is_broken := false
