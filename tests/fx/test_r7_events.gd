extends Node3D
## Round 7 events (docs/Round 7 — Freeflow Combat.md, Effects; acceptance row
## "effects on every Round 7 event, scaled by weight", owner F). Each event's
## effects and sounds spawn on the event's physics frame:
## - attack_tell: an orange &"strike" tell pings; every other kind (&"grab",
##   &"charge": dodge only, blue) buzzes, and a blue limb glow
##   (Tuning.TELL_COLOR_GRAB, chosen by the AI's glint) lights the limb blue;
## - strike_started of a Round 7 move: the swing whoosh follows its weight
##   (a jab whips high and quiet; heavies and kicks swing the long deep whoosh);
## - countered: a sharp cold-white flash at the attacker's caught limb (the
##   striking limb of its move; brighter than any strike), sparks, a short glow
##   on that limb, the counter sound and a small screen flash;
## - counter_whiffed: a soft whoosh and nothing else;
## - dodged: a quick whoosh and a scuff, an after-image of the pose where the
##   dodge started (fading over ScreenFX.DODGE_AFTERIMAGE_FADE) and a dust kick;
## - glide_started: a rush whoosh, speed streaks on both hands and feet and the
##   player's speed blur, all bigger for a longer glide;
## - drive_started .. drive_ended: heavy footstep thuds that quicken as the
##   speed builds, a dust puff per step and the wind loop rising with the
##   speed (a Traversal footstep during the drive lands as a thud and a puff,
##   never as a normal step); all of it stops on drive_ended;
## - drive_impact: break = a boom, a flash and a dust burst; slam = a big boom,
##   the wall slam and crumble, a flash with a shock ring, a dust burst with
##   chips, a dust ring and debris chunks (DebrisManager); bowl = a body crash,
##   a flash and dust;
## - throw_windup: the throwing arm (upper arm, forearm, hand) glows, rising
##   with the amount, flaring at 1, gone at 0 and on the throw; the release
##   whoosh is louder for a faster throw (a full wind-up layers the charged
##   whoosh), props too; G's zero-damage &"throw" release hit draws no contact
##   flash, ring, impact sound or screen flash. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")
const FakePanel := preload("res://tests/fx/fx_fake_panel.gd")
const FreeflowFX := preload("res://scripts/fx/freeflow_fx.gd")

var played: Array = []   ## [id, physics frame]

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	ScreenFX.reset()
	U.make_floor(self)
	if not await U.wait_audio(get_tree()):
		fails.append("AudioFX never finished synthesising")
	AudioFX.sound_played.connect(func(id: StringName, _p: Vector3) -> void: played.append([id, Engine.get_physics_frames()]))
	var player := U.make_fighter(self, Vector3(0, 0, 1.5))
	player.add_to_group(&"player")
	player.add_to_group(&"fighters")
	var tr: Node = player.add_traversal()
	var enemy := U.make_fighter(self, Vector3(0, 0, -0.5))
	enemy.add_to_group(&"fighters")
	var enemy2 := U.make_fighter(self, Vector3(2, 0, -0.5))
	enemy2.add_to_group(&"fighters")
	var ff: Node = BloodFX.get_freeflow_fx()
	var wfx: Node = BloodFX.get_world_fx()
	await U.physics_frames(get_tree(), 2)
	ScreenFX.set(&"_player_poll", 0.0)
	await get_tree().process_frame

	# --- Tells: orange strike, blue for everything else (grab, charge) ------------------
	var tells: Array[String] = []
	for spec in [[&"strike", &"tell_strike"], [&"grab", &"tell_grab"], [&"charge", &"tell_grab"]]:
		await U.physics_frames(get_tree(), 12)
		played.clear()
		var tf := Engine.get_physics_frames()
		GameEvents.attack_tell.emit(enemy2, spec[0], 0.5)
		tells.append("%s -> %s" % [spec[0], _ids_on(tf)])
		if _ids_on(tf) != [spec[1]]:
			fails.append("tell %s played %s, want %s" % [spec[0], _ids_on(tf), spec[1]])
	var blue: Node3D = BloodFX.limb_glow(enemy2, Bones.R_UPPER_ARM, Tuning.TELL_COLOR_GRAB, 0.3, 1.0)
	await get_tree().process_frame
	var shoulder_mat := (enemy2.rig.get_bone_parts(Bones.R_UPPER_ARM)[0] as MeshInstance3D).material_override
	var glow_col = (shoulder_mat as ShaderMaterial).get_shader_parameter(&"glow_color")
	print("TELL CHECK: %s; a charge's blue limb glow colour %s (TELL_COLOR_GRAB %s)" % [", ".join(tells), glow_col,
		Tuning.TELL_COLOR_GRAB])
	if blue == null or not (glow_col is Color) or not (glow_col as Color).is_equal_approx(Tuning.TELL_COLOR_GRAB):
		fails.append("blue tell glow not blue")
	await get_tree().create_timer(0.45).timeout

	# --- Swing whooshes by weight -----------------------------------------------------
	var swings: Array[String] = []
	var swing_db := {}
	for m: StringName in [&"jab", &"hook", &"heavy_cross", &"roundhouse"]:
		await U.physics_frames(get_tree(), 12)
		played.clear()
		var sf := Engine.get_physics_frames()
		# B reports heavies with charge level 1; the weight decides the swing.
		GameEvents.strike_started.emit(player, enemy, m, false, 1 if String(m).begins_with("heavy") else 0)
		GameEvents.attack_active.emit(player, m)  # covered by the strike_started whoosh
		var sl: Dictionary = AudioFX.round7_sounds.back()
		swing_db[m] = float(sl["db"][0])
		swings.append("%s (w %.2f) %s %+.1f dB" % [m, Tuning.R7_MOVES[m]["weight"], _ids_on(sf), sl["db"][0]])
		var want: StringName = &"whoosh_charged" if float(Tuning.R7_MOVES[m]["weight"]) >= 0.6 else &"whoosh"
		if _ids_on(sf) != [want]:
			fails.append("%s swing played %s, want %s" % [m, _ids_on(sf), want])
	print("SWING CHECK: %s" % ", ".join(swings))
	if swing_db[&"roundhouse"] <= swing_db[&"jab"] + 3.0:
		fails.append("the roundhouse swing is not louder than the jab's")

	# --- Counter ------------------------------------------------------------------------
	GameEvents.strike_started.emit(enemy, player, &"e_kick", false, 0)  # the attack being countered
	await U.physics_frames(get_tree(), 30)
	played.clear()
	var frame := Engine.get_physics_frames()
	var scr0 := ScreenFX.flash_log.size()
	var spark0: int = BloodFX._spark_next
	var glows0 := BloodFX.active_glows()
	GameEvents.countered.emit(player, enemy)
	var lc: Dictionary = ff.get(&"last_counter")
	var want_bone := FXRules.strike_limb(&"e_kick")
	var limb_at := FXRules.limb_point(enemy, want_bone)
	var nodes: Array = BloodFX.last_impact_nodes()
	var flash_node := nodes[0] as MeshInstance3D
	var tint = flash_node.get(&"instance_shader_parameters/tint")
	var bright := BloodFX.last_impact_brightness()
	var scr: bool = ScreenFX.flash_log.size() > scr0 and ScreenFX.flash_log.back()["frame"] == frame
	var ids := _ids_on(frame)
	await get_tree().process_frame
	await get_tree().process_frame
	var limb_glow := 0.0
	for p: MeshInstance3D in enemy.rig.get_bone_parts(want_bone):
		limb_glow = maxf(limb_glow, U.part_param(p, &"glow"))
	print("COUNTER CHECK: caught limb %s (the e_kick's %s), flash %.3f m from it, %.2f m wide at brightness %.2f (strikes at most %.2f), tint %s, sparks %d, limb glow %.2f, sounds %s, screen flash %s" % [
		lc.get("bone", &"-"), want_bone, flash_node.global_position.distance_to(limb_at), flash_node.scale.x, bright,
		BloodFX.R7_FLASH_BRIGHT.y, tint, (BloodFX._spark_next - spark0 + BloodFX.SPARK_POOL) % BloodFX.SPARK_POOL,
		limb_glow, ids, ("%.2f" % ScreenFX.flash_log.back()["alpha"]) if scr else "-"])
	if lc.get("bone", &"") != want_bone or flash_node.global_position.distance_to(limb_at) > 0.01:
		fails.append("counter flash not at the caught limb")
	if bright <= BloodFX.R7_FLASH_BRIGHT.y or not (tint is Color) or (tint as Color).b < (tint as Color).r:
		fails.append("counter flash not the bright cold flash")
	if BloodFX._spark_next == spark0 or BloodFX.active_glows() <= glows0 or limb_glow <= 0.5:
		fails.append("counter sparks / limb glow missing")
	if ids != [&"counter_hit"] or not scr:
		fails.append("counter sound %s / screen flash %s on the event frame" % [ids, scr])
	await get_tree().create_timer(FreeflowFX.COUNTER_GLOW_TIME + 0.25).timeout
	if BloodFX.active_glows() > glows0:
		fails.append("the caught-limb glow outlived %.2f s" % FreeflowFX.COUNTER_GLOW_TIME)
	# An attacker with no known move: the right hand.
	GameEvents.countered.emit(player, enemy2)
	print("counter on an attacker with no known move: %s" % ff.get(&"last_counter").get("bone", &"-"))
	if ff.get(&"last_counter").get("bone", &"") != Bones.R_HAND:
		fails.append("counter fallback limb wrong")
	# The real order: the window opens on the move, Defence cancels the attack
	# (current_move_id goes empty), then emits countered.
	var e3 := U.make_fighter(self, Vector3(-2, 0, -0.5))
	var fc := FakeCombat.new()
	e3.add_child(fc)
	e3.set(&"combat", fc)
	fc.move = &"e_kick"
	GameEvents.counter_window.emit(e3, player, true, true)
	fc.move = &""
	await U.physics_frames(get_tree(), 30)
	GameEvents.countered.emit(player, e3)
	print("counter after the attack was cancelled: limb %s (the window's e_kick: %s)" % [
		ff.get(&"last_counter").get("bone", &"-"), FXRules.strike_limb(&"e_kick")])
	if ff.get(&"last_counter").get("bone", &"") != FXRules.strike_limb(&"e_kick"):
		fails.append("counter limb lost when the attack is cancelled before countered")

	# --- Counter whiff ------------------------------------------------------------------
	await U.physics_frames(get_tree(), 30)
	played.clear()
	frame = Engine.get_physics_frames()
	var impact0: int = BloodFX._impact_next
	scr0 = ScreenFX.flash_log.size()
	GameEvents.counter_whiffed.emit(player)
	var wlog: Dictionary = AudioFX.round7_sounds.back()
	print("WHIFF CHECK: sounds %s at %+.1f dB (base whoosh %.1f), flashes %d, screen flashes %d" % [_ids_on(frame),
		wlog["db"][0], AudioFX.BASE_DB[&"whoosh"], (BloodFX._impact_next - impact0 + BloodFX.IMPACT_POOL) % BloodFX.IMPACT_POOL,
		ScreenFX.flash_log.size() - scr0])
	if _ids_on(frame) != [&"whoosh"] or float(wlog["db"][0]) > -6.0 or BloodFX._impact_next != impact0 \
			or ScreenFX.flash_log.size() != scr0:
		fails.append("counter whiff is not just a soft whoosh")

	# --- Dodge --------------------------------------------------------------------------
	await U.physics_frames(get_tree(), 30)
	player.rig.get_attachment(Bones.R_UPPER_ARM).rotation_degrees = Vector3(60, 0, 0)  # a pose to copy
	var start := player.global_position
	played.clear()
	frame = Engine.get_physics_frames()
	var ff0: int = ff.get(&"effect_log").size()
	GameEvents.dodged.emit(player, Vector3.RIGHT)
	ids = _ids_on(frame)
	var dusted := _logged(ff, ff0, &"dodge_dust", frame)
	var ghost: Node3D = null
	for g: Node3D in ScreenFX._ghosts:
		if g.visible:
			ghost = g
	var arm := player.rig.get_bone_parts(Bones.R_UPPER_ARM)[0] as MeshInstance3D
	var ghost_arm: MeshInstance3D = null
	var copies := 0
	if ghost != null:
		for c: MeshInstance3D in ghost.get_children():
			if c.visible:
				copies += 1
			if c.visible and c.mesh == arm.mesh:
				ghost_arm = c
	var pose_err := ghost_arm.global_transform.origin.distance_to(arm.global_transform.origin) if ghost_arm else 99.0
	for i in 30:  # 2.5 m in 0.25 s
		player.global_position = start + Vector3.RIGHT * Tuning.R7_DODGE_DIST * minf(i / 26.0, 1.0)
		await get_tree().physics_frame
	var showing := ScreenFX.active_afterimages()
	await get_tree().create_timer(ScreenFX.DODGE_AFTERIMAGE_FADE).timeout
	print("DODGE CHECK: sounds %s, dust %s, after-image of %d of %d parts at the start (pose within %.4f m), still showing %d at 0.25 s, %d after %.2f s more" % [
		ids, dusted, copies, player.rig.get_mesh_parts().size(), pose_err, showing, ScreenFX.active_afterimages(),
		ScreenFX.DODGE_AFTERIMAGE_FADE])
	if not (ids.has(&"sidestep") and ids.has(&"step")) or not dusted:
		fails.append("dodge sound / dust missing on the event frame")
	if ghost == null or copies != player.rig.get_mesh_parts().size() or pose_err > 0.001:
		fails.append("dodge after-image missing or not the pose at the start")
	if ScreenFX.active_afterimages() != 0:
		fails.append("dodge after-image did not fade")
	player.global_position = start
	player.rig.get_attachment(Bones.R_UPPER_ARM).rotation_degrees = Vector3.ZERO

	# --- Glide ------------------------------------------------------------------------------
	var glide := {}
	for dist: float in [1.0, FXRules.GLIDE_FULL]:
		await U.physics_frames(get_tree(), 40)
		ScreenFX.reset()
		played.clear()
		frame = Engine.get_physics_frames()
		GameEvents.glide_started.emit(player, enemy, dist)
		var g_ids := _ids_on(frame)
		var g_db: float = AudioFX.round7_sounds.back()["db"][0]
		var trails: Node3D = ScreenFX.get_trails()
		var time := dist / Tuning.R7_GLIDE_SPEED
		var p0 := player.global_position
		var blur := 0.0
		var lines := 0.0
		var streaks := 0
		var longest := 0.0
		var strength := 0.0
		for i in int(time * 120.0) + 2:
			player.global_position = p0 + Vector3.FORWARD * minf(Tuning.R7_GLIDE_SPEED * i / 120.0, dist)
			await get_tree().process_frame
			blur = maxf(blur, ScreenFX.get_blur_strength())
			lines = maxf(lines, ScreenFX.get_speed_lines())
			var st: Dictionary = trails.call(&"stats")
			streaks = maxi(streaks, int(st["streak"]))
			longest = maxf(longest, float(st["length"]))
			for ch in trails.get(&"_channels"):
				if ch.streak:
					strength = maxf(strength, ch.strength)
		await get_tree().create_timer(Tuning.TRAIL_FADE + ScreenFX.GLIDE_FADE + 0.15).timeout
		var left := int(trails.call(&"stats")["streak"])
		glide[dist] = {"db": g_db, "blur": blur, "streaks": streaks, "len": longest, "strength": strength}
		print("GLIDE CHECK %.2f m (%.2f s): sounds %s at %+.1f dB, blur up to %.2f, lines %.2f, %d streaks (strength %.2f, longest %.2f m), %d left after the fade" % [
			dist, time, g_ids, g_db, blur, lines, streaks, strength, longest, left])
		if g_ids != [&"rush"] or streaks != 4 or blur <= 0.0 or left != 0:
			fails.append("glide %.1f m: sound %s, streaks %d, blur %.2f, left %d" % [dist, g_ids, streaks, blur, left])
		player.global_position = p0
	var gs: Dictionary = glide[1.0]
	var gl: Dictionary = glide[FXRules.GLIDE_FULL]
	if gl["db"] <= gs["db"] or gl["blur"] <= gs["blur"] or gl["strength"] <= gs["strength"] or gl["len"] <= gs["len"]:
		fails.append("a longer glide is not bigger: %s vs %s" % [gl, gs])

	# --- Drive ----------------------------------------------------------------------------------
	await U.physics_frames(get_tree(), 40)
	tr.set(&"drive_speed", Tuning.R7_DRIVE_START_SPEED)
	played.clear()
	frame = Engine.get_physics_frames()
	var steps0: int = AudioFX.drive_steps
	var dust0: int = ff.get(&"counts").get(&"drive_dust", 0)
	GameEvents.drive_started.emit(player, enemy)
	var first_ids := _ids_on(frame)
	var first_dust: int = int(ff.get(&"counts").get(&"drive_dust", 0)) - dust0
	var step_times: Array[float] = [0.0]
	var last_steps: int = AudioFX.drive_steps
	var wind_db: Array[float] = []
	var t := 0.0
	var dstart := player.global_position
	while t < Tuning.R7_DRIVE_RAMP_TIME + 0.2:
		await get_tree().physics_frame
		t += 1.0 / 120.0
		var u := clampf(t / Tuning.R7_DRIVE_RAMP_TIME, 0.0, 1.0)
		var v := lerpf(Tuning.R7_DRIVE_START_SPEED, Tuning.R7_DRIVE_MAX_SPEED, 1.0 - (1.0 - u) * (1.0 - u))
		tr.set(&"drive_speed", v)
		player.global_position += Vector3.FORWARD * v / 120.0
		await get_tree().process_frame
		if AudioFX.drive_steps > last_steps:
			last_steps = AudioFX.drive_steps
			step_times.append(t)
		if absf(t - 0.15) < 0.005 or absf(t - (Tuning.R7_DRIVE_RAMP_TIME + 0.15)) < 0.005:
			wind_db.append(AudioFX._wind.volume_db)
	var steps: int = AudioFX.drive_steps - steps0
	var puffs: int = int(ff.get(&"counts").get(&"drive_dust", 0)) - dust0
	var gaps: Array[String] = []
	for k in range(1, step_times.size()):
		gaps.append("%.2f" % (step_times[k] - step_times[k - 1]))
	var wind_level := AudioFX.get_drive_wind()
	var wind_on: bool = AudioFX._wind.playing
	# A Traversal footstep mid-drive: a thud and a drive puff, not a normal step.
	await U.physics_frames(get_tree(), 10)
	played.clear()
	var fsf := Engine.get_physics_frames()
	var fp0: int = wfx.get(&"counts").get(&"foot_puff", 0)
	var dd0: int = ff.get(&"counts").get(&"drive_dust", 0)
	GameEvents.footstep.emit(player, player.global_position, &"concrete", 1.0)
	var fs_ids := _ids_on(fsf)
	var fs_puffs: int = int(wfx.get(&"counts").get(&"foot_puff", 0)) - fp0
	var fs_dust: int = int(ff.get(&"counts").get(&"drive_dust", 0)) - dd0
	print("footstep during the drive: sounds %s, drive puffs %d, foot puffs %d" % [fs_ids, fs_dust, fs_puffs])
	if fs_ids != [&"drive_step"] or fs_dust != 1 or fs_puffs != 1:
		fails.append("a footstep mid-drive is not a drive thud and puff")
	GameEvents.drive_ended.emit(player, &"release")
	var after0: int = AudioFX.drive_steps
	await get_tree().create_timer(1.0).timeout
	print("DRIVE CHECK: push-off %s (dust %d) on the start frame; %d thuds and %d dust puffs over %.1f s at gaps %s s; wind %s, %.1f dB at 0.15 s -> %.1f dB at %.2f s (drive level %.2f); after drive_ended: %d more thuds, drives %d, wind playing %s" % [
		first_ids, first_dust, steps, puffs, t, ", ".join(gaps), wind_on, wind_db[0] if wind_db.size() > 0 else 0.0,
		wind_db[1] if wind_db.size() > 1 else 0.0, Tuning.R7_DRIVE_RAMP_TIME + 0.15, wind_level, AudioFX.drive_steps - after0,
		AudioFX.active_drives(), AudioFX._wind.playing])
	print("drive covered %.1f m" % dstart.distance_to(player.global_position))
	if not first_ids.has(&"drive_step") or first_dust != 1:
		fails.append("no thud / dust on the drive_started frame")
	if steps < 4 or puffs < 4 or absf(steps - puffs) > 1:
		fails.append("drive steps %d, puffs %d" % [steps, puffs])
	if step_times.size() >= 3 and step_times[step_times.size() - 1] - step_times[step_times.size() - 2] \
			>= (step_times[1] - step_times[0]) * 0.75:
		fails.append("drive steps do not quicken (%s)" % [gaps])
	if not wind_on or wind_db.size() < 2 or wind_db[1] < wind_db[0] + 3.0 or wind_level < 0.95:
		fails.append("drive wind does not rise (%s, level %.2f)" % [wind_db, wind_level])
	if AudioFX.drive_steps != after0 or AudioFX.active_drives() != 0 or AudioFX._wind.playing \
			or int(ff.call(&"active_drives")) != 0:
		fails.append("the drive did not stop on drive_ended")
	player.global_position = Vector3(0, 0, 1.5)

	# --- Drive impacts --------------------------------------------------------------------------
	var panel := FakePanel.new()
	panel.surface = &"brick"
	add_child(panel)
	panel.global_position = Vector3(0, 1.0, -3.0)
	var dm := get_node_or_null(^"/root/DebrisManager")
	var want_snd := {&"break": [&"boom", &"body_slam"], &"slam": [&"boom", &"wall_slam", &"land_heavy"],
		&"bowl": [&"body_slam", &"impact_knockdown"]}
	for result: StringName in [&"break", &"slam", &"bowl"]:
		await U.physics_frames(get_tree(), 40)
		played.clear()
		frame = Engine.get_physics_frames()
		ff0 = ff.get(&"effect_log").size()
		var c0: Dictionary = wfx.get(&"counts").duplicate()
		var debris0: int = dm.call(&"count") if dm != null else 0
		var impact_i: int = BloodFX._impact_next
		var dust_i: int = BloodFX._dust_next
		var target: Node3D = enemy2 if result == &"bowl" else panel
		GameEvents.drive_impact.emit(player, enemy, target, Vector3(0, 1.0, -2.9), 8.0, result)
		var r_ids := _ids_on(frame)
		var fx_ok := _logged(ff, ff0, StringName("drive_" + String(result)), frame)
		var flashes := (BloodFX._impact_next - impact_i + BloodFX.IMPACT_POOL) % BloodFX.IMPACT_POOL
		var ring_on: bool = (BloodFX.last_impact_nodes()[1] as MeshInstance3D).visible
		var dusts := (BloodFX._dust_next - dust_i + BloodFX.DUST_POOL) % BloodFX.DUST_POOL
		var chips_on: bool = (BloodFX._chips[dust_i] as GPUParticles3D).visible
		var wd := _diff(wfx, c0)
		var debris_added: int = (dm.call(&"count") if dm != null else 0) - debris0
		var r7log: Dictionary = AudioFX.round7_sounds.back()
		print("IMPACT CHECK %s at 8 m/s: sounds %s (%s dB), flash %d (ring %s), dust %d (chips %s), world %s, debris +%d" % [
			result, r_ids, r7log["db"].map(func(d: float) -> String: return "%+.1f" % d), flashes, ring_on, dusts, chips_on,
			wd, debris_added])
		for id in want_snd[result]:
			if not r_ids.has(id):
				fails.append("drive %s: no %s on the event frame (%s)" % [result, id, r_ids])
		if not fx_ok or flashes != 1 or dusts < 1:
			fails.append("drive %s: flash / dust missing" % result)
		if result == &"slam":
			if not ring_on or not chips_on or wd.get(&"dust_ring", 0) != 1 or wd.get(&"debris", 0) < FreeflowFX.SLAM_DEBRIS.x \
					or (dm != null and debris_added != wd.get(&"debris", 0)):
				fails.append("drive slam: ring %s, chips %s, world %s, debris +%d" % [ring_on, chips_on, wd, debris_added])
	# A slower slam is smaller and quieter.
	await U.physics_frames(get_tree(), 40)
	GameEvents.drive_impact.emit(player, enemy, panel, Vector3(0, 1.0, -2.9), 3.5, &"slam")
	var slow_db: float = AudioFX.round7_sounds.back()["db"][0]
	var slow_fx: float = (ff.get(&"effect_log") as Array).back()["size"]
	await U.physics_frames(get_tree(), 40)
	GameEvents.drive_impact.emit(player, enemy, panel, Vector3(0, 1.0, -2.9), Tuning.R7_DRIVE_MAX_SPEED, &"slam")
	var fast_db: float = AudioFX.round7_sounds.back()["db"][0]
	var fast_fx: float = (ff.get(&"effect_log") as Array).back()["size"]
	print("slam by speed: 3.5 m/s boom %+.1f dB, size %.2f; %.1f m/s boom %+.1f dB, size %.2f" % [slow_db, slow_fx,
		Tuning.R7_DRIVE_MAX_SPEED, fast_db, fast_fx])
	if fast_db <= slow_db or fast_fx <= slow_fx:
		fails.append("a faster slam is not bigger")

	# --- Throw wind-up and release ------------------------------------------------------------------
	await U.physics_frames(get_tree(), 30)
	var arm_parts: Array[MeshInstance3D] = []
	for b in [Bones.R_UPPER_ARM, Bones.R_LOWER_ARM, Bones.R_HAND]:
		arm_parts.append_array(player.rig.get_bone_parts(b))
	var other_arm := player.rig.get_bone_parts(Bones.L_LOWER_ARM)[0] as MeshInstance3D
	var levels: Array[String] = []
	var intens: Array[float] = []
	var g: Node3D = null
	ff0 = ff.get(&"effect_log").size()
	frame = Engine.get_physics_frames()
	GameEvents.throw_windup.emit(player, 0.05)
	var glow_frame := _logged(ff, ff0, &"throw_glow", frame)
	for a: float in [0.05, 0.25, 0.5, 0.75, 1.0]:
		GameEvents.throw_windup.emit(player, a)
		await get_tree().process_frame
		await get_tree().process_frame
		g = ff.call(&"get_throw_glow", player)
		if g == null:
			break
		intens.append(float(g.get(&"intensity")))
		levels.append("%.2f->%.2f" % [a, g.call(&"get_level")])
	var lit := 0
	for p in arm_parts:
		if U.part_param(p, &"glow") > 0.3:
			lit += 1
	var full_color: Color = g.get(&"color") if g else Color.BLACK
	print("THROW CHECK wind-up: glow on the frame %s, on %s with %d of %d arm parts lit (other arm %.2f); level by amount %s; flares at 1: %d; colour at 1 %s" % [
		glow_frame, g.get(&"bone") if g else &"-", lit, arm_parts.size(), U.part_param(other_arm, &"glow"),
		", ".join(levels), int(ff.get(&"counts").get(&"throw_full", 0)), full_color])
	if g == null or not glow_frame or lit != arm_parts.size() or U.part_param(other_arm, &"glow") > 0.0:
		fails.append("wind-up glow not on the throwing arm")
	for k in range(1, intens.size()):
		if intens[k] <= intens[k - 1]:
			fails.append("wind-up glow does not build (%s)" % [intens])
			break
	if int(ff.get(&"counts").get(&"throw_full", 0)) != 1 or not full_color.is_equal_approx(FreeflowFX.THROW_COLOR):
		fails.append("no flare / hot colour at a full wind-up")
	# Release at full speed: the whoosh and the charged layer; the glow goes.
	played.clear()
	frame = Engine.get_physics_frames()
	GameEvents.thrown.emit(player, enemy, Vector3(0, 2.5, -17.8))
	var full_ids := _ids_on(frame)
	var full_db: float = AudioFX.round7_sounds.back()["db"][0]
	await get_tree().create_timer(0.25).timeout
	var arm_after := 0.0
	for p in arm_parts:
		arm_after = maxf(arm_after, U.part_param(p, &"glow"))
	# A tap throw at the minimum speed.
	await U.physics_frames(get_tree(), 30)
	GameEvents.throw_windup.emit(player, 0.1)
	await get_tree().process_frame
	played.clear()
	frame = Engine.get_physics_frames()
	GameEvents.thrown.emit(player, enemy, Vector3(0, 1.1, -7.9))
	var tap_ids := _ids_on(frame)
	var tap_db: float = AudioFX.round7_sounds.back()["db"][0]
	await get_tree().create_timer(0.25).timeout
	print("THROW CHECK release: 18 m/s %s at %+.1f dB; 8 m/s %s at %+.1f dB; arm glow after the throw %.2f, glow handle %s" % [
		full_ids, full_db, tap_ids, tap_db, arm_after, ff.call(&"get_throw_glow", player)])
	if full_ids != [&"throw", &"whoosh_charged"] or tap_ids != [&"throw"] or full_db <= tap_db + 3.0:
		fails.append("release whoosh not scaled by speed")
	if arm_after > 0.0 or ff.call(&"get_throw_glow", player) != null:
		fails.append("the arm glow outlived the throw")
	# G reports the release as a zero-damage &"throw" hit (launch tier, weight
	# 0.2, no react): no contact flash, ring, impact sound or screen flash.
	await U.physics_frames(get_tree(), 30)
	played.clear()
	frame = Engine.get_physics_frames()
	var rel := U.hit(enemy, &"throw", FXRules.limb_point(player, Bones.R_HAND), Vector3(0, 0, -1), 0.0, 0.0, &"throw",
			HitInfo.Tier.LAUNCH)
	rel.attacker = player
	rel.weight = 0.2
	var c_n := BloodFX.contact_log.size()
	var i_n: int = BloodFX._impact_next
	var s_n := ScreenFX.flash_log.size()
	GameEvents.hit_landed.emit(rel)
	print("THROW CHECK release hit (0 damage): sounds %s, contact frames %d, flashes %d, screen flashes %d" % [
		_ids_on(frame), BloodFX.contact_log.size() - c_n, (BloodFX._impact_next - i_n + BloodFX.IMPACT_POOL) % BloodFX.IMPACT_POOL,
		ScreenFX.flash_log.size() - s_n])
	if not _ids_on(frame).is_empty() or BloodFX.contact_log.size() != c_n or BloodFX._impact_next != i_n \
			or ScreenFX.flash_log.size() != s_n:
		fails.append("a throw's zero-damage release drew a contact")
	# Amount 0 and the end of the hold drop it too.
	GameEvents.throw_windup.emit(player, 0.6)
	GameEvents.throw_windup.emit(player, 0.0)
	var zero_drop: bool = ff.call(&"get_throw_glow", player) == null
	GameEvents.throw_windup.emit(player, 0.6)
	GameEvents.carry_changed.emit(player, null)
	var hold_drop: bool = ff.call(&"get_throw_glow", player) == null
	print("wind-up glow dropped at amount 0: %s, when the hold ends: %s" % [zero_drop, hold_drop])
	if not (zero_drop and hold_drop):
		fails.append("wind-up glow kept after 0 / the hold ended")
	# Props: the same whoosh by speed, lighter.
	await U.physics_frames(get_tree(), 30)
	GameEvents.prop_thrown.emit(player, enemy2, Vector3(0, 1, -8))
	var prop_slow: float = AudioFX.round7_sounds.back()["db"][0]
	await U.physics_frames(get_tree(), 30)
	GameEvents.prop_thrown.emit(player, enemy2, Vector3(0, 2, -18))
	var prop_fast: float = AudioFX.round7_sounds.back()["db"][0]
	print("prop throw: 8 m/s %+.1f dB, 18 m/s %+.1f dB" % [prop_slow, prop_fast])
	if prop_fast <= prop_slow + 3.0 or prop_fast >= full_db:
		fails.append("prop throw whoosh wrong")
	U.finish(get_tree(), "test_r7_events", fails, errlog)

## Sound ids played on `frame`, in order.
func _ids_on(frame: int) -> Array:
	return played.filter(func(p: Array) -> bool: return p[1] == frame).map(func(p: Array) -> StringName: return p[0])

## True when `event` was logged by FreeflowFX on `frame` after entry `from`.
static func _logged(ff: Node, from: int, event: StringName, frame: int) -> bool:
	var log: Array = ff.get(&"effect_log")
	for k in range(from, log.size()):
		if log[k]["event"] == event and log[k]["frame"] == frame:
			return true
	return false

static func _diff(wfx: Node, before: Dictionary) -> Dictionary:
	var out := {}
	var now: Dictionary = wfx.get(&"counts")
	for k in now:
		var d := int(now[k]) - int(before.get(k, 0))
		if d != 0:
			out[k] = d
	return out

## Stand-in CombatController: current_move_id() only.
class FakeCombat extends Node:
	var move := &""

	func current_move_id() -> StringName:
		return move
