extends Node
## Round 7 combo counter (J): GameEvents.chain_hit from the player drives a big
## number on the left side of the screen. It shows from HUD.COMBO_MIN hits,
## pops (scale bump) on every hit, names the move under it, ignores enemy
## chains, holds HUD.COMBO_END_HOLD after chain_ended and fades over
## HUD.COMBO_FADE; a chain whose chain_ended never comes fades after
## HUD.COMBO_STALE. Prints the measured scale, hold and fade times.

var _fails := 0

func _ready() -> void:
	for i in 5:
		await get_tree().process_frame
	await _run()
	print("TEST test_hud_combo: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
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

## Real seconds until cond() holds (or max_s), polled every frame.
func _time_until(cond: Callable, max_s: float) -> float:
	var t0 := TimeDirector.now()
	while not cond.call() and TimeDirector.now() - t0 < max_s:
		await get_tree().process_frame
	return TimeDirector.now() - t0

func _run() -> void:
	var world := Node3D.new()
	add_child(world)
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.look_at_from_position(Vector3(0, 3, 8), Vector3(0, 1, 0))
	cam.make_current()
	var player := FighterFactory.spawn_dummy(world, &"player", Transform3D(Basis(), Vector3(0, 0.05, 2)), Fighter.TEAM_PLAYER)
	var enemy := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(0, 0.05, -2)))
	var hud := HUD.new()
	add_child(hud)
	hud.set_player(player)
	hud.set_mode(&"waves")
	await _frames(3)
	_check(hud.get_combo_count() == 0 and hud.get_combo_text() == "", "no combo counter before a chain")

	# One hit is not a combo.
	GameEvents.chain_hit.emit(player, enemy, &"jab", 1)
	await _frames(2)
	_check(hud.get_combo_count() == 0 and hud.get_combo_alpha() == 0.0, "1 hit: counter hidden (shows from %d)" % HUD.COMBO_MIN)

	# Second hit: the counter shows "2" and pops.
	GameEvents.chain_hit.emit(player, enemy, &"cross", 2)
	await _frames(1)
	var pop1 := hud.get_combo_scale()
	_check(hud.get_combo_count() == 2 and hud.get_combo_text() == "2", "chain_hit count 2 -> shows '2' (%s)" % hud.get_combo_text())
	_check(hud.get_combo_move() == "CROSS", "move name under it: '%s'" % hud.get_combo_move())
	_check(pop1 > 1.25, "pops on the hit: scale %.2f on the first frame" % pop1)
	await _wait_real(HUD.COMBO_POP_TIME + 0.05)
	var settled := hud.get_combo_scale()
	_check(is_equal_approx(settled, 1.0), "settles to scale %.2f after %.2f s" % [settled, HUD.COMBO_POP_TIME])

	# Layout: large, at the side of the screen.
	var vp := get_viewport().get_visible_rect().size
	var r := hud._combo_num.get_global_rect()
	var fs := hud._combo_num.get_theme_font_size(&"font_size")
	print("    combo number rect %s (font %d px) on a %s screen" % [r, fs, vp])
	_check(fs >= 100 and r.size.y >= 100.0, "large: %d px font, %.0f px tall" % [fs, r.size.y])
	_check(r.end.x < vp.x * 0.3 and r.get_center().y > vp.y * 0.25 and r.get_center().y < vp.y * 0.75,
		"at the left side, vertically central (x %.0f..%.0f, centre y %.0f%%)" % [r.position.x, r.end.x, 100.0 * r.get_center().y / vp.y])

	# Enemy chains are not the player's combo.
	GameEvents.chain_hit.emit(enemy, player, &"e_jab", 7)
	await _frames(2)
	_check(hud.get_combo_text() == "2", "an enemy's chain_hit is ignored")

	# Third hit pops again and names the move.
	await _wait_real(0.1)
	GameEvents.chain_hit.emit(player, enemy, &"heavy_hook", 3)
	await _frames(1)
	var pop2 := hud.get_combo_scale()
	_check(hud.get_combo_text() == "3" and hud.get_combo_move() == "HEAVY HOOK" and pop2 > 1.25,
		"3rd hit: '3', 'HEAVY HOOK', pops again (scale %.2f)" % pop2)

	# Long chains heat up to the accent colour.
	for n in range(4, 11):
		GameEvents.chain_hit.emit(player, enemy, &"uppercut" if n % 2 == 0 else &"jab", n)
		await _frames(1)
	var col: Color = hud._combo_num.get_theme_color(&"font_color")
	_check(hud.get_combo_text() == "10" and col.is_equal_approx(UIKit.ACCENT), "10 hits: '10' in the accent colour (%s)" % col)

	# chain_ended: holds, then fades.
	GameEvents.chain_ended.emit(player, 10)
	await _frames(1)
	_check(hud.get_combo_text() == "10" and hud.get_combo_alpha() > 0.99, "still up right after chain_ended")
	var t_fade_start := await _time_until(func() -> bool: return hud.get_combo_alpha() < 0.99, 3.0)
	var t_gone := t_fade_start + await _time_until(func() -> bool: return hud.get_combo_alpha() <= 0.0, 3.0)
	print("    after chain_ended: fade starts at %.2f s, gone at %.2f s (hold %.2f + fade %.2f)" % [
		t_fade_start, t_gone, HUD.COMBO_END_HOLD, HUD.COMBO_FADE])
	_check(absf(t_fade_start - HUD.COMBO_END_HOLD) < 0.05, "holds %.2f s after chain_ended (%.2f)" % [HUD.COMBO_END_HOLD, t_fade_start])
	_check(absf(t_gone - HUD.COMBO_END_HOLD - HUD.COMBO_FADE) < 0.06,
		"faded out %.2f s after chain_ended (%.2f)" % [HUD.COMBO_END_HOLD + HUD.COMBO_FADE, t_gone])
	await _frames(2)
	_check(hud.get_combo_count() == 0 and hud.get_combo_text() == "", "gone: count 0, no text")

	# chain_ended from an enemy or with no combo up does nothing.
	GameEvents.chain_ended.emit(enemy, 4)
	GameEvents.chain_ended.emit(player, 1)
	await _frames(2)
	_check(hud.get_combo_alpha() == 0.0, "chain_ended with nothing up shows nothing")

	# A new chain starts from its own count, nothing left over.
	GameEvents.chain_hit.emit(player, enemy, &"leg_kick", 1)
	GameEvents.chain_hit.emit(player, enemy, &"gut_punch", 2)
	await _frames(1)
	_check(hud.get_combo_text() == "2" and hud.get_combo_move() == "GUT PUNCH", "a new chain shows '2' 'GUT PUNCH'")
	# A chain_ended with a higher final count than the last chain_hit shows the final count.
	GameEvents.chain_ended.emit(player, 3)
	await _frames(1)
	_check(hud.get_combo_text() == "3", "chain_ended's final count wins (3)")
	await _wait_real(HUD.COMBO_END_HOLD + HUD.COMBO_FADE + 0.1)

	# A missed chain_ended: the counter still goes after COMBO_STALE.
	GameEvents.chain_hit.emit(player, enemy, &"jab", 1)
	GameEvents.chain_hit.emit(player, enemy, &"cross", 2)
	await _frames(1)
	var stale := await _time_until(func() -> bool: return hud.get_combo_alpha() <= 0.0, HUD.COMBO_STALE + 2.0)
	print("    no chain_ended: gone after %.2f s" % stale)
	_check(stale > HUD.COMBO_STALE - 0.05 and stale < HUD.COMBO_STALE + HUD.COMBO_FADE + 0.1,
		"without chain_ended it fades after %.1f s (%.2f)" % [HUD.COMBO_STALE, stale])

	# Round over hides it at once.
	GameEvents.chain_hit.emit(player, enemy, &"jab", 1)
	GameEvents.chain_hit.emit(player, enemy, &"cross", 2)
	await _frames(1)
	hud.set_round_over()
	await _frames(1)
	_check(hud.get_combo_alpha() == 0.0, "round over hides the combo counter")
	GameEvents.chain_hit.emit(player, enemy, &"hook", 3)
	await _frames(1)
	_check(hud.get_combo_alpha() == 0.0, "no combo counter after the round")
