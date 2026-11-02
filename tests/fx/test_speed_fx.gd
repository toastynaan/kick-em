extends Node3D
## F2 speed effects (Feel Reference: Screen effects, On the character, On the
## world, Sound). ACCEPTANCE CHECK (agent F): logged blur strength is 0.15 at
## half charge and 0.6 at full. Also: the blur ramps as a curve (nothing on or
## off), speed lines only past Tuning.SPEED_LINES_FROM, ribbon trails on both
## hands and feet past Tuning.TRAIL_FROM whose length follows the speed (0.4 to
## 1.2 m), a pursuit teleport and an air dash get the full blur, the wind loop
## rises in volume and pitch with sprint_charge, sprint footsteps puff (water
## splashes and ripples, metal sparks), walking steps only sound, and the sprint
## start kicks dust. Runs against a stand-in Traversal and the real player's.
## OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")

var played: Array[StringName] = []

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	ScreenFX.reset()
	U.make_floor(self)
	var water := U.make_box(self, Vector3(8, -0.45, 0), Vector3(4, 1, 4), Layers.WORLD)
	water.set_meta(&"surface", &"water")
	var plate := U.make_box(self, Vector3(-8, -0.45, 0), Vector3(4, 1, 4), Layers.WORLD)
	plate.set_meta(&"surface", &"metal")
	if not await U.wait_audio(get_tree()):
		fails.append("AudioFX never finished synthesising")
	AudioFX.sound_played.connect(func(id: StringName, _p: Vector3) -> void: played.append(id))
	var player := U.make_fighter(self, Vector3(0, 0, 4))
	player.add_to_group(&"player")
	player.add_to_group(&"fighters")
	var tr: Node = player.add_traversal()
	await U.physics_frames(get_tree(), 2)

	# --- Blur by sprint_charge (the F2 check) ----------------------------------------
	var curve: Array[String] = []
	for c in [0.0, 0.25, 0.5, 0.75, 0.8, 0.9, 1.0]:
		tr.sprint_charge = c
		await get_tree().process_frame
		curve.append("%.2f->%.3f/%.2f" % [c, ScreenFX.get_blur_strength(), ScreenFX.get_speed_lines()])
	print("blur/lines by sprint_charge: %s" % " ".join(curve))
	tr.sprint_charge = 0.5
	await get_tree().process_frame
	var half := ScreenFX.get_blur_strength()
	tr.sprint_charge = 1.0
	await get_tree().process_frame
	var full := ScreenFX.get_blur_strength()
	print("F2 CHECK blur strength: half charge %.3f (want 0.15), full %.3f (want 0.60)" % [half, full])
	if absf(half - 0.15) > 0.001 or absf(full - 0.6) > 0.001:
		fails.append("blur %.3f at half, %.3f at full" % [half, full])
	tr.sprint_charge = 0.8
	await get_tree().process_frame
	if ScreenFX.get_speed_lines() != 0.0:
		fails.append("speed lines at sprint_charge 0.8")
	tr.sprint_charge = 0.9
	await get_tree().process_frame
	var mid_lines := ScreenFX.get_speed_lines()
	if mid_lines <= 0.0 or mid_lines >= 1.0:
		fails.append("speed lines do not ramp past 0.8 (%.2f at 0.9)" % mid_lines)
	if not ScreenFX.get_node(^"SpeedBlur").visible:
		fails.append("speed blur rect hidden at speed")
	tr.sprint_charge = 0.0
	await get_tree().process_frame
	if ScreenFX.get_blur_strength() != 0.0 or ScreenFX.get_node(^"SpeedBlur").visible:
		fails.append("blur still on at rest")

	# --- Trails: ramp with speed, length 0.4 .. 1.2 m ---------------------------------
	var trails: Node3D = ScreenFX.get_trails()
	for spec in [[0.5, 0.0], [0.7, 0.6], [1.0, 1.2]]:
		tr.sprint_charge = spec[0]
		var speed := 6.0 + 2.0 * float(spec[0])
		for i in 60:  # half a second of running
			player.global_position += Vector3(0, 0, -speed / 120.0)
			await get_tree().process_frame
		var st: Dictionary = trails.call(&"stats")
		var cap: float = trails.call(&"sprint_length", spec[0])
		print("trails at sprint_charge %.1f: %d sprint channels, longest %.2f m (cap %.2f), points %d" % [
			spec[0], st["sprint"], st["length"], cap, st["points"]])
		if spec[0] <= Tuning.TRAIL_FROM:
			if st["points"] > 0 and st["length"] > 0.01:
				fails.append("trails below TRAIL_FROM")
		else:
			if st["sprint"] != 4:
				fails.append("%d sprint trail channels, want 4 (hands and feet)" % st["sprint"])
			if absf(cap - float(spec[1])) > 0.01:
				fails.append("trail cap %.2f at %.1f, want %.2f" % [cap, spec[0], spec[1]])
			if st["length"] > cap + 0.05 or st["length"] < cap * 0.6:
				fails.append("trail length %.2f m at %.1f (cap %.2f)" % [st["length"], spec[0], cap])
	tr.sprint_charge = 0.0
	for i in 40:
		await get_tree().process_frame
	if int(trails.call(&"stats")["points"]) != 0:
		fails.append("trails did not fade out after stopping")

	# --- Pursuit teleport and air dash: the full blur ---------------------------------
	await _settle()
	GameEvents.teleported.emit(player, player.global_position, player.global_position + Vector3(0, 1, -3), &"pursuit")
	await get_tree().process_frame
	var pulse0 := ScreenFX.get_blur_strength()  # one rendered frame after the vanish
	await get_tree().create_timer(0.4).timeout
	var pulse1 := ScreenFX.get_blur_strength()
	print("pursuit teleport blur: %.2f then %.2f after 0.4 s" % [pulse0, pulse1])
	if pulse0 < 0.5 or pulse1 > 0.01:
		fails.append("pursuit blur pulse %.2f -> %.2f" % [pulse0, pulse1])
	tr.air_dashing = true
	await _settle()
	var dash_blur := ScreenFX.get_blur_strength()
	tr.air_dashing = false
	print("air dash blur: %.2f" % dash_blur)
	if absf(dash_blur - Tuning.BLUR_MAX) > 0.001:
		fails.append("air dash blur %.2f" % dash_blur)
	await get_tree().process_frame

	# --- Wind loop -------------------------------------------------------------------------
	tr.sprint_charge = 0.4
	await get_tree().create_timer(0.6).timeout
	var w_mid: float = AudioFX.get_wind_level()
	var db_mid: float = AudioFX._wind.volume_db
	var p_mid: float = AudioFX._wind.pitch_scale
	tr.sprint_charge = 1.0
	await get_tree().create_timer(0.6).timeout
	var w_top: float = AudioFX.get_wind_level()
	var db_top: float = AudioFX._wind.volume_db
	var p_top: float = AudioFX._wind.pitch_scale
	print("wind: charge 0.4 -> level %.2f %.1f dB pitch %.2f; charge 1.0 -> level %.2f %.1f dB pitch %.2f; playing %s on %s" % [
		w_mid, db_mid, p_mid, w_top, db_top, p_top, AudioFX._wind.playing, AudioFX._wind.bus])
	if not AudioFX._wind.playing or AudioFX._wind.bus != AudioFX.PLAYER_BUS:
		fails.append("wind loop not playing on the Player bus")
	if not (db_top > db_mid + 6.0 and p_top > p_mid + 0.15 and w_top > 0.95):
		fails.append("wind does not rise with sprint_charge")
	tr.sprint_charge = 0.0
	await get_tree().create_timer(1.0).timeout
	if AudioFX._wind.playing:
		fails.append("wind still playing at rest")

	# --- Upgraded caps: "same signals, stronger" (lead decision) ---------------------------
	# k = 1 + 0.5 (cap - 8) / 4: blur (at most 0.85), line density, trail length
	# cap and the wind's ceiling all scale by it; the base cap stays exactly as above.
	var trails_u: Node3D = ScreenFX.get_trails()
	for cap: float in [10.0, 12.0]:
		Tuning.debug_speed_cap = cap
		var k := 1.0 + 0.5 * (cap - 8.0) / 4.0
		tr.sprint_charge = 0.5
		await _settle()
		var half_u := ScreenFX.get_blur_strength()
		tr.sprint_charge = 1.0
		for i in 60:  # half a second at the upgraded cap
			player.global_position += Vector3(0, 0, -cap / 120.0)
			await get_tree().process_frame
		var full_u := ScreenFX.get_blur_strength()
		var density := float(ScreenFX._speed_mat.get_shader_parameter(&"density"))
		var st_u: Dictionary = trails_u.call(&"stats")
		var cap_u: float = trails_u.call(&"sprint_length", 1.0, ScreenFX.get_speed_scale())
		await get_tree().create_timer(0.5).timeout
		var wdb: float = AudioFX._wind.volume_db
		var wp: float = AudioFX._wind.pitch_scale
		print("upgraded cap %.0f m/s (k %.2f): blur half %.3f (want %.3f) full %.3f (want %.3f); line density %.2f; trail cap %.2f m, longest %.2f m; wind %.1f dB pitch %.2f (base cap %.1f dB, %.2f)" % [
			cap, ScreenFX.get_speed_scale(), half_u, minf(0.15 * k, 0.85), full_u, minf(0.6 * k, 0.85), density,
			cap_u, st_u["length"], wdb, wp, db_top, p_top])
		if absf(ScreenFX.get_speed_scale() - k) > 0.001 or absf(half_u - minf(0.15 * k, 0.85)) > 0.002 \
				or absf(full_u - minf(0.6 * k, ScreenFX.BLUR_CEILING)) > 0.002:
			fails.append("upgraded cap %.0f: k %.2f, blur %.3f / %.3f" % [cap, ScreenFX.get_speed_scale(), half_u, full_u])
		if absf(density - k) > 0.001 or absf(cap_u - 1.2 * k) > 0.001 or st_u["length"] < 1.2 * k * 0.85 \
				or st_u["length"] > 1.2 * k + 0.05:
			fails.append("upgraded cap %.0f: density %.2f, trail %.2f / %.2f" % [cap, density, st_u["length"], cap_u])
		if wdb <= db_top + 1.0 or wp <= p_top + 0.05:
			fails.append("upgraded cap %.0f: wind not stronger (%.1f dB, %.2f)" % [cap, wdb, wp])
	Tuning.debug_speed_cap = Tuning.SPRINT_CAPS[0]
	tr.sprint_charge = 0.0
	await _settle()
	if absf(ScreenFX.get_speed_scale() - 1.0) > 0.0001:
		fails.append("speed scale not 1 back at the base cap")
	await get_tree().create_timer(1.0).timeout

	# --- Footsteps and the sprint start ------------------------------------------------------
	var wfx: Node = BloodFX.get_world_fx()
	var c0: Dictionary = wfx.get(&"counts").duplicate()
	played.clear()
	GameEvents.footstep.emit(player, Vector3(0, 0, 0), &"concrete", 0.0)  # walking
	await U.physics_frames(get_tree(), 10)
	GameEvents.footstep.emit(player, Vector3(0, 0, 0), &"concrete", 1.0)
	await U.physics_frames(get_tree(), 10)
	GameEvents.footstep.emit(player, Vector3(8, 0.05, 0), &"water", 1.0)
	await U.physics_frames(get_tree(), 10)
	GameEvents.footstep.emit(player, Vector3(8, 0.05, 0), &"water", 0.0)
	await U.physics_frames(get_tree(), 10)
	GameEvents.footstep.emit(player, Vector3(-8, 0.05, 0), &"metal", 0.9)
	await U.physics_frames(get_tree(), 10)
	GameEvents.sprint_started.emit(player)
	var c1: Dictionary = wfx.get(&"counts")
	var d := func(k: StringName) -> int: return int(c1.get(k, 0)) - int(c0.get(k, 0))
	print("footsteps: puffs %d, ripples %d, splashes %d, sparks %d, sprint kicks %d; sounds %s" % [
		d.call(&"foot_puff"), d.call(&"ripple"), d.call(&"splash"), d.call(&"sparks"), d.call(&"sprint_kick"), played])
	# Concrete sprint step 1 + metal 1 + sprint kick 1 = 3 puffs (the walking step none).
	if d.call(&"foot_puff") != 3:
		fails.append("foot puffs %d, want 3" % d.call(&"foot_puff"))
	if d.call(&"ripple") != 2 or d.call(&"splash") != 1 or d.call(&"sparks") != 1 or d.call(&"sprint_kick") != 1:
		fails.append("water / metal / sprint start effects wrong")
	if played.count(&"step") < 3 or not played.has(&"step_water") or not played.has(&"step_metal"):
		fails.append("footstep sounds by surface missing: %s" % [played])
	if wfx.call(&"active_ripples") < 1:
		fails.append("no ripple showing")

	# --- The real player's Traversal: a scripted sprint ----------------------------------
	# Traversal (agent M) computes sprint_charge from the real speed every tick,
	# so hold Dash with the stick forward (as tests/move does) and compare the blur
	# with sprint_charge^2 x BLUR_MAX on every frame of the run-up.
	player.remove_from_group(&"player")
	player.queue_free()
	var real: Node3D = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.1, 10)), 0)
	await U.physics_frames(get_tree(), 3)
	if not real.is_in_group(&"player"):
		real.add_to_group(&"player")
	ScreenFX.set(&"_player_poll", 0.0)
	var rt = real.get(&"traversal")
	if rt == null or real.get(&"combat") == null:
		print("note: the real player has no Traversal yet; real check skipped")
	else:
		await _settle()
		# Spawned 0.1 m up: wait until it stands, or the Dash press is an air dash
		# (full blur by design) instead of the start of a sprint.
		for i in 120:
			if real.is_on_floor() and not rt.call(&"is_airborne"):
				break
			await get_tree().physics_frame
		real.set(&"move_input", Vector3.FORWARD)
		real.get(&"combat").call(&"press", CombatController.Action.DASH)
		var worst := 0.0
		var at_half := Vector2(-1, -1)
		var at_full := Vector2(-1, -1)
		var samples := 0
		for i in 240:
			await get_tree().process_frame
			var c := float(rt.get(&"sprint_charge"))
			await get_tree().process_frame  # ScreenFX has processed this charge
			var b := ScreenFX.get_blur_strength()
			worst = maxf(worst, absf(b - c * c * Tuning.BLUR_MAX))
			samples += 1
			if at_half.x < 0.0 and c >= 0.5:
				at_half = Vector2(c, b)
			if c >= 0.999:
				at_full = Vector2(c, b)
				break
		real.get(&"combat").call(&"release", CombatController.Action.DASH)
		print("F2 CHECK on the real player's sprint: charge %.3f -> blur %.3f (want %.3f); charge %.3f -> blur %.3f (want 0.600); worst error over %d frames %.4f" % [
			at_half.x, at_half.y, at_half.x * at_half.x * Tuning.BLUR_MAX, at_full.x, at_full.y, samples, worst])
		if at_full.x < 0.999 or worst > 0.002:
			fails.append("real sprint: full charge %.3f, worst blur error %.4f" % [at_full.x, worst])
		real.set(&"move_input", Vector3.ZERO)
	U.finish(get_tree(), "test_speed_fx", fails, errlog)

## Two process frames: whatever resumed this coroutine (a timer fires after
## _process), ScreenFX has run its _process with the new state afterwards.
func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
