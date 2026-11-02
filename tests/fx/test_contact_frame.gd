extends Node3D
## F4 contact frame (Feel Reference: Contact frame, Effects that sell power).
## ACCEPTANCE CHECKS (agent F):
## - the flash, sound and blood spawn on the same physics frame as the hit
##   event (logged frame numbers);
## - each tier plays a different sound stream (logged).
## Also: blood none on flinch / stumble, a small spray on stagger, more from
## knockdown up, a ground strike adds a spray; a shock ring and a 15% white
## screen flash only from launch up, each at most once per 0.2 s; the victim's
## mesh jitters 2-4 cm for its freeze (the player's capped at 60 ms); a whoosh
## on every strike (a longer one for charged), strike trails on a charged
## strike's limb, and the charge glow that brightens and pulses with a sound
## at each level. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")

const TIERS: Array[int] = [HitInfo.Tier.FLINCH, HitInfo.Tier.STUMBLE, HitInfo.Tier.STAGGER,
	HitInfo.Tier.KNOCKDOWN, HitInfo.Tier.LAUNCH, HitInfo.Tier.HARD_LAUNCH, HitInfo.Tier.SEVER]

var played: Array[StringName] = []
var _sampling := false
var _flash_frames := 0

## Runs after the ScreenFX autoload's _process each frame: what gets rendered.
func _process(_delta: float) -> void:
	if _sampling and ScreenFX.get_flash_alpha() > 0.0:
		_flash_frames += 1

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	ScreenFX.reset()
	U.make_floor(self)
	if not await U.wait_audio(get_tree(), 240000, true):
		fails.append("AudioFX never finished synthesising")
	AudioFX.sound_played.connect(func(id: StringName, _p: Vector3) -> void: played.append(id))
	var player := U.make_fighter(self, Vector3(0, 0, 1.2))
	player.add_to_group(&"player")
	player.add_to_group(&"fighters")
	var victim := U.make_fighter(self, Vector3(0, 0, -0.2))
	victim.add_to_group(&"fighters")
	await U.physics_frames(get_tree(), 2)
	var chest := victim.global_position + Vector3(0, 1.35, 0.12)

	# --- Same physics frame, per tier -------------------------------------------------
	var streams_by_tier: Dictionary = {}
	for rep in 3:
		for tier in TIERS:
			await U.physics_frames(get_tree(), 30)  # past the 0.2 s ring / flash budget
			var sprays_before := _visible_sprays()
			var h := U.hit(victim, &"cross", chest, Vector3(0, 0, -1), 10.0, 0.0, &"strike", tier)
			h.attacker = player
			var frame := Engine.get_physics_frames()
			GameEvents.hit_landed.emit(h)
			var c: Dictionary = BloodFX.contact_log.back()
			var snd: Dictionary = AudioFX.hit_sounds.back()
			var scr: Dictionary = ScreenFX.flash_log.back() if not ScreenFX.flash_log.is_empty() else {}
			var screen_now: bool = not scr.is_empty() and scr["frame"] == frame
			var spray_now: bool = _visible_sprays() > sprays_before or (c["blood"] and _visible_sprays() > 0)
			var stream: AudioStream = snd["stream"]
			if not streams_by_tier.has(tier):
				streams_by_tier[tier] = {}
			(streams_by_tier[tier] as Dictionary)[absi(stream.get_instance_id()) % 100000 if stream else 0] = true
			if rep == 0:
				print("F4 CHECK %-11s hit frame %d: flash frame %d (ring %s), sound frame %d %s stream #%d, blood %s frame %d, screen flash %s" % [
					HitInfo.tier_name(tier), frame, c["frame"], c["ring"], snd["frame"], snd["id"],
					absi(stream.get_instance_id()) % 100000 if stream else 0, c["blood"], c["frame"],
					("%.2f" % scr["alpha"]) if screen_now else "-"])
			if c["frame"] != frame or snd["frame"] != frame:
				fails.append("%s: flash frame %d / sound frame %d, hit frame %d" % [HitInfo.tier_name(tier),
					c["frame"], snd["frame"], frame])
			if not c["flash"]:
				fails.append("%s: no contact flash" % HitInfo.tier_name(tier))
			var want_blood := tier >= HitInfo.Tier.STAGGER
			if c["blood"] != want_blood or (want_blood and not spray_now):
				fails.append("%s: blood %s (want %s)" % [HitInfo.tier_name(tier), c["blood"], want_blood])
			var launch := tier >= HitInfo.Tier.LAUNCH
			if c["ring"] != launch:
				fails.append("%s: shock ring %s" % [HitInfo.tier_name(tier), c["ring"]])
			if screen_now != launch or (screen_now and absf(scr["alpha"] - Tuning.HIT_FLASH_ALPHA) > 0.001):
				fails.append("%s: screen flash %s" % [HitInfo.tier_name(tier), screen_now])
			if snd["id"] != AudioFX.TIER_SOUND[tier]:
				fails.append("%s played %s" % [HitInfo.tier_name(tier), snd["id"]])
	# Distinct streams: no stream is shared by two tiers.
	var owner: Dictionary = {}
	var table: Array[String] = []
	for tier in TIERS:
		var ids: Array = (streams_by_tier[tier] as Dictionary).keys()
		table.append("%s=%s" % [HitInfo.tier_name(tier), ids])
		for sid in ids:
			if owner.has(sid) and owner[sid] != tier:
				fails.append("stream #%d plays for %s and %s" % [sid, HitInfo.tier_name(owner[sid]), HitInfo.tier_name(tier)])
			owner[sid] = tier
	print("F4 CHECK streams per tier (3 hits each): %s" % ", ".join(table))
	# The tiers really sound different: length and low-end weight of variant 0.
	var shape: Array[String] = []
	for tier in TIERS:
		var buf: PackedFloat32Array = AudioFX.synthesize(AudioFX.TIER_SOUND[tier], 0)
		shape.append("%s %.2fs low %.2f" % [HitInfo.tier_name(tier), buf.size() / 44100.0, _low_share(buf)])
	print("impact streams: %s" % ", ".join(shape))

	# --- Budget: one ring and one screen flash per 0.2 s ----------------------------------
	await U.physics_frames(get_tree(), 30)
	var rings := 0
	var flashes := ScreenFX.flash_log.size()
	for i in 3:  # three launches 0.05 s apart
		var h := U.hit(victim, &"kick", chest, Vector3(0, 0, -1), 10.0, 0.0, &"strike", HitInfo.Tier.HARD_LAUNCH)
		GameEvents.hit_landed.emit(h)
		if BloodFX.contact_log.back()["ring"]:
			rings += 1
		await U.physics_frames(get_tree(), 6)
	var burst_flashes := ScreenFX.flash_log.size() - flashes
	print("budget: 3 launches in 0.15 s -> %d shock ring(s), %d screen flash(es)" % [rings, burst_flashes])
	if rings != 1 or burst_flashes != 1:
		fails.append("budget broken: %d rings, %d flashes" % [rings, burst_flashes])

	# --- Screen flash lasts 2 rendered frames ------------------------------------------------
	await U.physics_frames(get_tree(), 30)
	await U.physics_frames(get_tree(), 30)
	_flash_frames = 0
	_sampling = true
	GameEvents.hit_landed.emit(U.hit(victim, &"kick", chest, Vector3(0, 0, -1), 10.0, 0.0, &"strike", HitInfo.Tier.LAUNCH))
	for i in 8:
		await get_tree().process_frame
	_sampling = false
	var frames_on := _flash_frames
	print("screen flash on for %d rendered frames (want %d)" % [frames_on, Tuning.HIT_FLASH_FRAMES])
	if frames_on != Tuning.HIT_FLASH_FRAMES:
		fails.append("screen flash lasted %d frames" % frames_on)

	# --- Mesh jitter through the freeze ------------------------------------------------------
	await U.physics_frames(get_tree(), 30)
	GameEvents.hit_landed.emit(U.hit(victim, &"kick", chest, Vector3(0, 0, -1), 10.0, 0.0, &"strike", HitInfo.Tier.LAUNCH))
	await get_tree().process_frame
	await get_tree().process_frame
	var j := BloodFX.get_jitter(victim).length()
	var left := BloodFX.jitter_left(victim)
	var part_j = (victim.rig.get_mesh_parts()[0] as MeshInstance3D).material_override.get_shader_parameter(&"jitter")
	await get_tree().create_timer(Power.hitstop_for(HitInfo.Tier.LAUNCH) + 0.05).timeout
	var after := BloodFX.get_jitter(victim).length()
	print("jitter: %.3f m during a launch freeze (%.3f s left), part offset %s, %.3f after" % [j, left, part_j, after])
	if j < Tuning.HITSTOP_JITTER_RANGE.x * 0.7 - 0.001 or j > Tuning.HITSTOP_JITTER_RANGE.y + 0.001 or after != 0.0:
		fails.append("jitter %.3f m, %.3f after" % [j, after])
	if not (part_j is Vector3) or (part_j as Vector3).length() < 0.001:
		fails.append("jitter not written to the mesh")
	var on_player := U.hit(player, &"e_heavy", player.global_position + Vector3.UP * 1.3, Vector3(0, 0, 1), 20.0, 0.0,
			&"strike", HitInfo.Tier.KNOCKDOWN)
	GameEvents.hit_landed.emit(on_player)
	print("player freeze jitter: %.3f s (cap %.2f)" % [BloodFX.jitter_left(player), Tuning.PLAYER_HITSTOP_MAX])
	if BloodFX.jitter_left(player) > Tuning.PLAYER_HITSTOP_MAX + 1e-4:
		fails.append("player jitter longer than PLAYER_HITSTOP_MAX")

	# --- Ground strike adds a spray into the floor -------------------------------------------
	await U.physics_frames(get_tree(), 30)
	var gs := U.hit(victim, &"stomp", victim.global_position + Vector3(0, 0.3, 0), Vector3.DOWN, 6.0, 0.0, &"strike",
			HitInfo.Tier.FLINCH)
	gs.ground_strike = true
	var sp0 := _visible_sprays()
	GameEvents.hit_landed.emit(gs)
	if not BloodFX.contact_log.back()["blood"] or _visible_sprays() <= sp0:
		fails.append("ground strike made no spray")

	# --- Whoosh on every strike; charged longer --------------------------------------------
	await U.physics_frames(get_tree(), 10)
	played.clear()
	GameEvents.strike_started.emit(player, victim, &"jab1", false, 0)
	GameEvents.attack_active.emit(player, &"jab1")  # covered by the strike_started whoosh
	await U.physics_frames(get_tree(), 10)
	GameEvents.strike_started.emit(player, victim, &"sparta_kick", true, 2)
	await get_tree().process_frame
	var w0 := AudioFX.generate(&"whoosh", 0).get_length()
	var w1 := AudioFX.generate(&"whoosh_charged", 0).get_length()
	print("strike whooshes: %s (tap %.2f s, charged %.2f s)" % [played, w0, w1])
	if played.count(&"whoosh") != 1 or played.count(&"whoosh_charged") != 1 or w1 <= w0 * 1.4:
		fails.append("strike whooshes wrong: %s" % [played])

	# --- Strike trail on a charged strike's limb --------------------------------------------
	var trails: Node3D = ScreenFX.get_trails()
	var win := FXRules.strike_window(&"sparta_kick")
	var seen := 0
	for i in int((win.x + win.y) * 120.0) + 6:
		victim.rig.get_attachment(Bones.R_FOOT).position += Vector3(0, 0.01, -0.01)
		player.rig.get_attachment(Bones.R_FOOT).position += Vector3(0, 0.012, -0.015)
		await get_tree().process_frame
		seen = maxi(seen, int(trails.call(&"stats")["strike"]))
	var pts := int(trails.call(&"stats")["points"])
	await get_tree().create_timer(Tuning.TRAIL_FADE + 0.2).timeout
	var st: Dictionary = trails.call(&"stats")
	print("strike trail: limb %s, window %.3f + %.3f s, channels seen %d, points at the end %d, after fade %s" % [
		FXRules.strike_limb(&"sparta_kick"), win.x, win.y, seen, pts, st])
	if seen != 1 or pts < 2 or int(st["strike"]) != 0:
		fails.append("strike trail wrong (seen %d, points %d)" % [seen, pts])

	# --- Charge glow ---------------------------------------------------------------------------
	played.clear()
	GameEvents.charge_started.emit(player, &"sparta_kick")
	var g := BloodFX.get_charge_glow(player)
	var levels: Array[float] = []
	if g == null:
		fails.append("no charge glow")
	else:
		if g.get(&"bone") != Bones.R_FOOT:
			fails.append("charge glow on %s, want the kicking foot" % g.get(&"bone"))
		await get_tree().create_timer(0.15).timeout
		levels.append(g.call(&"get_level"))
		for lvl in [1, 2, 3]:
			GameEvents.charge_level_changed.emit(player, lvl)
			await get_tree().process_frame
			var pulse: float = g.call(&"get_level")
			await get_tree().create_timer(0.25).timeout
			levels.append(g.call(&"get_level"))
			if pulse <= levels.back() * 1.2:
				fails.append("no pulse at level %d (%.2f vs %.2f)" % [lvl, pulse, levels.back()])
		print("charge glow levels (steady, by charge level 0..3): %s; level-up sounds %d" % [
			levels.map(func(v: float) -> String: return "%.2f" % v), played.count(&"charge_level")])
		for k in range(1, levels.size()):
			if levels[k] <= levels[k - 1] * 1.15:
				fails.append("glow not brighter at level %d" % k)
		if played.count(&"charge_level") != 3:
			fails.append("level-up sounds %d, want 3" % played.count(&"charge_level"))
		GameEvents.charge_released.emit(player, &"sparta_kick", 3)
		await get_tree().create_timer(0.3).timeout
		if is_instance_valid(g):
			fails.append("charge glow outlived the release")
	U.finish(get_tree(), "test_contact_frame", fails, errlog)

func _visible_sprays() -> int:
	var n := 0
	for e: GPUParticles3D in BloodFX._sprays:
		if e.visible and e.emitting:
			n += 1
	return n

## Share of the signal's energy under ~200 Hz (one-pole split), for the log.
static func _low_share(buf: PackedFloat32Array) -> float:
	var a := 1.0 - exp(-TAU * 200.0 / 44100.0)
	var lp := 0.0
	var low := 0.0
	var total := 0.0
	for v in buf:
		lp += a * (v - lp)
		low += lp * lp
		total += v * v
	return low / maxf(total, 1e-9)
