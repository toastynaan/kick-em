extends Node
## HUD: world popups (WALL SLAM, THROUGH N WALLS, ARMOR), staged breaches do
## not announce WALL BREAK, the duel opponent bar tracks HP, popups expire; and
## the Round 5 HUD: Focus bars, parry / teleport / sidestep feedback (EARLY /
## LATE from the wind-ups), the counter-bonus cue, off-screen arrows (orange
## strike, blue grab, gone at the first active frame), the sprint marker, the
## F3 debug overlay (P and its parts) mirroring Tuning.debug_overlay, help rows,
## and the layer above ScreenFX.

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
	# A floor, so the dummies stand where they were put (lock-on, arrows, markers).
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
	enemy.add_focus(1.5)
	await _frames(3)
	_check(enemy.hp < start_hp and hud._opp_hp_label.text == "%d" % ceili(enemy.hp), "opponent HP label follows damage (%s)" % hud._opp_hp_label.text)
	_check(absf(hud._opp_bars.hp - enemy.hp / enemy.max_hp) < 0.01 and hud._opp_bars.hp_delayed > hud._opp_bars.hp,
		"opponent bar drops with a trailing damage bar")
	_check(absf(hud._opp_bars.focus - enemy.focus) < 0.01, "opponent Focus pips follow focus (%.2f)" % enemy.focus)
	enemy.queue_free()
	await _frames(3)
	_check(hud._opp_hp_label.text == "0", "freed opponent shows an empty bar without errors")

	# --- Upgrade 2: Focus meter, reticle, combo counter, charge levels ---------
	var stranger := Node3D.new()  # a live non-player node for "enemy" emits (enemy is freed above)
	world.add_child(stranger)
	_check(hud._reticle.visible, "centre reticle shown")
	var rc := hud._reticle.get_global_rect().position
	var vsz := get_viewport().get_visible_rect().size
	_check(rc.distance_to(vsz * 0.5) < 2.0, "reticle at the screen centre")
	TimeDirector.begin_focus()
	await _frames(3)
	_check(hud._bars.focus_active and hud._focus_label.text == "FOCUS MODE", "Focus meter shows Focus mode")
	_check(hud._reticle.focus, "reticle highlights in Focus")
	await _wait_real(0.5)
	var left := hud._bars.mode_left
	_check(left > 0.6 and left < 0.85, "Focus mode's 2 s drains under the bars (%.2f left after 0.5 s)" % left)
	TimeDirector.end_focus()
	await _wait_real(0.4)
	_check(not hud._bars.focus_active and hud._focus_label.text == "FOCUS" and hud._bars.mode_left < 0.0, "Focus meter back to idle")

	GameEvents.combo_progress.emit(player, 4, 0.8)
	await _frames(2)
	_check(hud.get_combo_text() == "4 HITS" and hud._combo_sub.text == "DMG 80%", "combo counter '4 HITS' / 'DMG 80%%'")
	GameEvents.combo_progress.emit(stranger, 6, 0.6)
	await _frames(1)
	_check(hud.get_combo_text() == "4 HITS", "enemy combos are not shown")
	GameEvents.combo_ended.emit(player, 4)
	await _wait_real(0.9)
	_check(hud.get_combo_text() == "", "combo counter fades after combo_ended")

	GameEvents.charge_started.emit(player, &"punch")
	await _frames(2)
	_check(hud.get_charge_state()["visible"] and hud.get_charge_state()["charging"], "charge meter shows on charge_started")
	GameEvents.charge_level_changed.emit(player, 2)
	await _frames(2)
	_check(hud.get_charge_state()["level"] == 2 and hud._charge.level == 2, "charge level 2 shown")
	GameEvents.charge_released.emit(player, &"punch", 2)
	await _wait_real(0.6)
	_check(not hud.get_charge_state()["visible"], "charge meter hides after the release")
	GameEvents.charge_started.emit(stranger, &"e_heavy")
	await _frames(2)
	_check(not hud.get_charge_state()["visible"], "enemy charges are not shown")

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

	# --- Round 4: lock-on marker and locked reticle ---------------------------------
	var rig := CameraRig.new()
	rig.target = player
	add_child(rig)
	var far := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis.looking_at(Vector3.BACK), player.global_position + Vector3(0, 0, -7)))
	await _frames(3)
	rig.snap_behind()
	await _wait_real(0.3)
	rig._set_lock(far)
	await _wait_real(0.6)
	_check(hud.is_lock_marker_visible(), "lock marker shown on the locked target")
	_check(hud._lock_marker.half >= HUD.LOCK_MARKER_MIN, "marker readable at 7 m (half-size %.0f px)" % hud._lock_marker.half)
	_check(hud._lock_marker.center.distance_to(rig.get_camera().unproject_position(far.get_aim_point())) < 4.0, "marker on the target's chest")
	_check(hud._reticle.locked, "reticle shows the lock")
	rig.unlock()
	await _frames(3)
	_check(not hud.is_lock_marker_visible() and not hud._reticle.locked, "unlocked: no marker")
	rig.queue_free()
	far.queue_free()
	await _frames(2)
	cam.make_current()
	await _round5(hud, world, player, cam)

# --- Round 5 -----------------------------------------------------------------------------
func _round5(hud: HUD, world: Node3D, player: Fighter, cam: Camera3D) -> void:
	var foe := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(0, 0.05, -2)))
	var behind := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(3, 0.05, 14)))
	await _frames(4)

	# Layer: above every ScreenFX layer, so Focus mode's tint never dims the HUD.
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

	# Focus: 3 bars; spending a whole bar flashes it out.
	player.focus = 2.0
	await _frames(2)
	player.focus = 1.0
	await _frames(2)
	_check(is_equal_approx(hud._bars.focus, 1.0) and is_equal_approx(hud._bars.ghost_to, 2.0) and is_equal_approx(hud._bars.ghost_from, 1.0),
		"a spent bar shows as a fading ghost (%.1f -> %.1f)" % [hud._bars.ghost_to, hud._bars.ghost_from])
	player.focus = 1.0

	# Parry / teleport / sidestep feedback.
	GameEvents.parried.emit(player, foe)
	_check(hud._pop_label.text == "PARRY", "parried -> PARRY")
	GameEvents.teleported.emit(player, Vector3.ZERO, Vector3.ONE, &"counter")
	_check(hud._pop_label.text == "TELEPORT", "teleported -> TELEPORT")
	GameEvents.teleported.emit(player, Vector3.ZERO, Vector3.ONE, &"pursuit")
	_check(hud._pop_label.text == "PURSUIT", "pursuit teleport -> PURSUIT")
	player.focus = 0.4
	GameEvents.sidestepped.emit(player, Vector3.RIGHT)
	await _frames(1)
	_check(_has(hud, "SIDESTEP  ·  NO FOCUS"), "sidestep without a full bar says so")
	hud._pop_label.text = ""
	GameEvents.parried.emit(foe, player)
	_check(hud._pop_label.text == "", "an enemy's parry is not announced")
	# Parry whiffs read the wind-ups: EARLY while one is still far from active, LATE just after.
	GameEvents.attack_tell.emit(foe, &"strike", 0.5)
	GameEvents.parry_whiffed.emit(player)
	await _frames(1)
	_check(_has(hud, "EARLY"), "a Block tap 0.5 s before the hit reads EARLY")
	GameEvents.attack_active.emit(foe, &"e_jab")
	GameEvents.parry_whiffed.emit(player)
	await _frames(1)
	_check(_has(hud, "LATE"), "a Block tap just after the hit went active reads LATE")
	await _wait_real(1.0)
	GameEvents.parry_whiffed.emit(player)
	await _frames(1)
	_check(not _has(hud, "EARLY") and not _has(hud, "LATE"), "a whiff with no attack coming shows nothing")

	# Counter bonus cue: live for Tuning.COUNTER_BONUS_TIME, gone when used.
	GameEvents.counter_bonus_changed.emit(player, 2.5)
	await _frames(2)
	_check(is_equal_approx(hud.get_counter_cue(), 2.5) and hud._counter_label.text == "+2.5 COUNTER" and hud._reticle.counter_left > 0.9,
		"counter bonus cue '+2.5 COUNTER' with a full ring")
	GameEvents.counter_bonus_changed.emit(foe, 3.0)
	await _frames(1)
	_check(is_equal_approx(hud.get_counter_cue(), 2.5), "an enemy's counter bonus is not shown")
	GameEvents.counter_bonus_changed.emit(player, 0.0)
	await _frames(2)
	_check(hud.get_counter_cue() == 0.0 and hud._reticle.counter_left < 0.0, "cue gone when the bonus is used")
	GameEvents.counter_bonus_changed.emit(player, 3.0)
	await _wait_real(Tuning.COUNTER_BONUS_TIME + 0.15)
	_check(hud.get_counter_cue() == 0.0, "cue gone after %.1f s" % Tuning.COUNTER_BONUS_TIME)

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
	GameEvents.attack_tell.emit(foe, &"strike", 1.0)
	await _frames(2)
	_check(hud.get_arrows().is_empty(), "an on-screen wind-up gets no arrow")
	GameEvents.attack_active.emit(foe, &"e_jab")

	# Sprint marker: white brackets on PlayerController.get_sprint_target().
	var stub := _SprintStub.new()
	player.add_child(stub)
	player.brain = stub
	stub.target = foe
	await _wait_real(0.2)
	_check(hud.get_sprint_marker_target() == foe, "sprint marker on the sprint target")
	var r := hud.get_sprint_marker_rect()
	var c := cam.unproject_position(foe.get_aim_point())
	_check(r.has_point(c) and r.size.x >= HUD.SPRINT_MARKER_MIN * 2.0, "marker brackets the target's chest (%s around %s)" % [r, c])
	stub.target = null
	await _frames(2)
	_check(hud.get_sprint_marker_target() == null, "no sprint target: no marker")
	player.brain = null
	stub.queue_free()

	# F3 debug overlay: mirrors Tuning.debug_overlay and shows P with its parts.
	var saved_overlay := Tuning.debug_overlay
	Tuning.debug_overlay = true
	await _frames(2)
	_check(hud.is_debug_visible(), "Tuning.debug_overlay on -> overlay shown")
	var info := HitInfo.new()
	info.attacker = player
	info.victim = foe
	info.move_id = &"cross"
	info.charge_level = 3
	info.power_base = 2.0
	info.speed_bonus = 3.0
	info.counter_bonus = 2.5
	info.finisher_bonus = 0.0
	info.power = 2.0 * 3.2 + 3.0 + 2.5
	info.tier = Power.tier_of(info.power)
	info.damage = 25.6
	player.combat.last_dealt = info
	var b := HUD.power_breakdown(info)
	_check(is_equal_approx(b["base"], 2.0) and is_equal_approx(b["charge_mult"], 3.2) and is_equal_approx(b["base_part"], 6.4),
		"P parts: base 2.0 x charge 3.2 = 6.4")
	var info2 := HitInfo.new()
	info2.power_base = 6.4  # a producer that stores base x charge in power_base
	info2.charge_level = 3
	info2.power = 6.4
	_check(is_equal_approx(HUD.power_breakdown(info2)["base"], 2.0), "power_base holding base x charge is read back as base 2.0")
	var text := hud.get_debug_text()
	print("    overlay:\n      " + "\n      ".join(text.split("\n").slice(0, 6)))
	_check(text.contains("P 11.90") and text.contains("SEVER") and text.contains("base 2.00 x charge 3.20 (6.40)")
		and text.contains("speed 3.00") and text.contains("counter 2.50") and text.contains("finisher 0.00"),
		"overlay shows P 11.90, its parts and the tier")
	_check(text.contains("sprint_charge") and text.contains("FOCUS") and text.contains("HP 100 / 100"), "overlay shows speed, sprint_charge, Focus and health")
	var world_line := HUD.world_debug_line()
	print("    " + world_line)
	_check(text.contains("WORLD") and world_line.contains("debris") and world_line.contains("/%d" % Tuning.DEBRIS_MAX)
		and world_line.contains("smashed") and world_line.contains("marks"), "overlay shows debris (cap), clutter smashed and floor marks")
	hud.toggle_debug()
	_check(not hud.is_debug_visible() and not Tuning.debug_overlay, "F3 hides it and clears Tuning.debug_overlay")
	Tuning.debug_overlay = saved_overlay
	GameMenus.save_debug_settings()

	# Help rows for the Round 5 controls.
	var rows := UIKit.control_rows()
	var by_title := {}
	for row: Array in rows:
		by_title[row[0]] = row
	_check(by_title.has("Light") and by_title.has("Heavy") and by_title.has("Sweep") and by_title.has("Focus"),
		"help rows: Light, Heavy, Sweep, Focus")
	if by_title.has("Heavy") and by_title.has("Sweep") and by_title.has("Kick"):
		_check(String(by_title["Heavy"][1]).contains("RMB") and String(by_title["Heavy"][2]).contains("Y"), "Heavy: RMB / L, Y (%s | %s)" % [by_title["Heavy"][1], by_title["Heavy"][2]])
		_check(by_title["Sweep"][1] == "S + E" and String(by_title["Kick"][1]).contains("E"), "Sweep: S + E; Kick on E")
		_check(String(by_title["Block"][3]).contains("parry"), "Block row explains the parry")
	foe.queue_free()
	behind.queue_free()
	await _frames(2)

class _SprintStub extends Node:
	var target: Fighter
	func get_sprint_target() -> Fighter:
		return target if is_instance_valid(target) else null

## Stand-in for a Destructible with D's round-3 fields.
class _FakePanel extends Node3D:
	var strike_holes := 0
	var last_break_by_strike := false
	var is_broken := false
