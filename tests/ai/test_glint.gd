extends Node
## Tell glint (rule 5; Feel Reference: Enemies have to be readable first):
## GameEvents.attack_tell spawns a tell: ORANGE for strikes (and the Duelist's
## counter, a strike), BLUE for grabs (cannot be parried); the star fallback is
## unshaded, no depth test, render layer VIS_FX, pulsing, gone shortly after
## the tell; a closing ring meets it as the parry / teleport window opens.
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")

var failures := 0

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _glints(f: Node) -> Array[TellGlint]:
	var out: Array[TellGlint] = []
	for c in f.get_children():
		if c is TellGlint and not c.is_queued_for_deletion():
			out.append(c)
	return out

func _run() -> void:
	AttackDirector.reset()
	Util.build_floor(self)
	var enemy := Util.spawn_fake(self, &"grunt", Fighter.TEAM_ENEMY, Vector3(0, 0.05, -3))
	await get_tree().physics_frame

	var tex := TellGlint.get_star_texture()
	check(tex != null and tex.get_width() == TellGlint.TEXTURE_SIZE, "star texture generated in code")
	var img := tex.get_image()
	@warning_ignore("integer_division")
	var c := TellGlint.TEXTURE_SIZE / 2
	check(img.get_pixel(c, c).a > 0.9 and img.get_pixel(1, 1).a < 0.05, "star: opaque core, clear corners")

	var duration := 0.45
	GameEvents.attack_tell.emit(enemy, &"grab", duration)
	var started := Util.game_now()
	await get_tree().process_frame
	var gl := _glints(enemy)
	check(gl.size() == 1, "one glint spawned on attack_tell")
	if gl.is_empty():
		_finish()
		return
	var g := gl[0]
	check(g.get_color() == Tuning.TELL_COLOR_GRAB and g.get_color().b > 0.9 and g.get_color().r < 0.3, "grab tell glows blue (Tuning.TELL_COLOR_GRAB)")
	check(g.layers == Layers.VIS_FX, "glint on render layer VIS_FX")
	var mat := g.material_override as StandardMaterial3D
	check(mat != null and mat.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED
		and mat.no_depth_test and mat.billboard_mode == BaseMaterial3D.BILLBOARD_ENABLED,
		"unshaded, no depth test, billboard")
	check(g.global_position.y > enemy.get_aim_point().y + 0.3, "placed above the head (y=%.2f)" % g.global_position.y)

	var scales: Array[float] = []
	while Util.game_now() - started < duration * 0.9:
		scales.append(g.scale.x)
		await get_tree().process_frame
	var lo: float = scales.min()
	var hi: float = scales.max()
	check(hi - lo > 0.2, "scale pulses during the tell (%.2f..%.2f)" % [lo, hi])

	# A new tell replaces the glint; a strike is orange.
	GameEvents.attack_tell.emit(enemy, &"strike", 0.4)
	await get_tree().process_frame
	gl = _glints(enemy)
	var col := gl[0].get_color() if gl.size() == 1 else Color.BLACK
	check(gl.size() == 1 and col == Tuning.TELL_COLOR_STRIKE and col.r > 0.9 and col.g > 0.3 and col.g < 0.6 and col.b < 0.2,
		"strike tell glows orange %s, replaces the old one" % str(col))

	var t0 := Util.game_now()
	while not _glints(enemy).is_empty() and Util.game_now() - t0 < 2.0:
		await get_tree().process_frame
	var life := Util.game_now() - t0
	check(_glints(enemy).is_empty() and life < 0.4 + TellGlint.FLASH_TIME + 0.1,
		"glint fades and frees after the tell (%.2f s)" % life)

	# The Duelist's teleport counter is a strike (parry it): orange, with a
	# strong closing ring.
	GameEvents.attack_tell.emit(enemy, &"counter", 0.3)
	await get_tree().process_frame
	gl = _glints(enemy)
	check(gl.size() == 1 and gl[0].get_color() == TellGlint.STRIKE_COLOR, "counter tell glows orange (a strike)")
	check(gl.size() == 1 and gl[0].get_ring() != null and TellGlint.RING_ALPHA[&"counter"] > TellGlint.RING_ALPHA[&"strike"],
		"counter: stronger closing ring")
	await _wait_glints_gone(enemy)

	# Closing ring: on strikes, counters and grabs (a grab is answered with a
	# teleport in the same window); it meets the glow exactly when the parry
	# window opens.
	GameEvents.attack_tell.emit(enemy, &"grab", 0.4)
	await get_tree().process_frame
	gl = _glints(enemy)
	check(gl.size() == 1 and gl[0].get_ring() != null, "a grab gets the teleport-timing ring too")
	await _wait_glints_gone(enemy)
	var tell := 0.5
	GameEvents.attack_tell.emit(enemy, &"strike", tell)
	await get_tree().process_frame
	gl = _glints(enemy)
	var ring_ok := gl.size() == 1 and gl[0].get_ring() != null
	check(ring_ok, "closing ring on a strike")
	if ring_ok:
		var g2 := gl[0]
		var meet := g2.get_meet_time()
		check(absf(meet - (tell - Tuning.PARRY_WINDOW)) < 0.001,
			"ring meets the glow at active - parry window (%.3f s of %.2f)" % [meet, tell])
		var early := g2.get_ring_scale()
		var t0g := Util.game_now()
		var at_meet := -1.0
		while is_instance_valid(g2) and Util.game_now() - t0g < tell:
			if at_meet < 0.0 and g2._t >= meet:
				at_meet = g2.get_ring_scale()
			await get_tree().process_frame
		check(early > 2.5 and absf(at_meet - TellGlint.RING_MEET_SCALE) < 0.01,
			"ring shrinks from %.2f to %.2f at the window" % [early, at_meet])
	await _wait_glints_gone(enemy)

	# The glint follows a moving attacker.
	GameEvents.attack_tell.emit(enemy, &"strike", 0.5)
	await get_tree().process_frame
	enemy.global_position += Vector3(3, 0, 0)
	await get_tree().process_frame
	await get_tree().process_frame
	gl = _glints(enemy)
	check(gl.size() == 1 and absf(gl[0].global_position.x - enemy.global_position.x) < 0.2, "glint follows the attacker")

	# A dead attacker cancels the glint.
	enemy.hp = 0.0
	t0 = Util.game_now()
	while not _glints(enemy).is_empty() and Util.game_now() - t0 < 1.0:
		await get_tree().process_frame
	check(_glints(enemy).is_empty() and Util.game_now() - t0 < 0.3, "glint cancelled when the attacker dies")
	_finish()

func _wait_glints_gone(f: Node) -> void:
	var t0 := Util.game_now()
	while not _glints(f).is_empty() and Util.game_now() - t0 < 2.0:
		await get_tree().process_frame

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_glint: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
