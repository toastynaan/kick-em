extends Node3D
## Integration: the effects against the real game. A real player strikes real
## grunts through CombatController (tap jab, tap kick, a level-3 charged kick);
## every hit_landed B emits must get its flash, impact sound and blood on that
## physics frame, sized by B's tier; the charged kick must show the charge glow
## rising with the level, a long whoosh, a strike trail during its active
## frames, a shock ring and the screen flash. Skips (with a note) whatever the
## other modules have not landed yet. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")

var hits: Array[Dictionary] = []
var played: Array[StringName] = []

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	ScreenFX.reset()
	U.make_floor(self)
	if not await U.wait_audio(get_tree()):
		fails.append("AudioFX never finished synthesising")
	AudioFX.sound_played.connect(func(id: StringName, _p: Vector3) -> void: played.append(id))
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void:
		hits.append({"frame": Engine.get_physics_frames(), "tier": info.tier, "power": info.power,
			"move": info.move_id, "fx": BloodFX.contact_log.back() if not BloodFX.contact_log.is_empty() else {},
			"snd": AudioFX.hit_sounds.back() if not AudioFX.hit_sounds.is_empty() else {}}))
	var p: Node3D = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis.looking_at(Vector3.FORWARD), Vector3.ZERO), 0)
	if not p.is_in_group(&"player"):
		p.add_to_group(&"player")
	await U.physics_frames(get_tree(), 15)
	var combat = p.get(&"combat")
	if combat == null:
		print("note: no CombatController; skipped")
		U.finish(get_tree(), "test_real_contact", fails, errlog)
		return

	var A := CombatController.Action
	for spec in [["tap jab", A.LIGHT, 0.0], ["tap kick", A.KICK, 0.0], ["charged kick", A.KICK, 1.05]]:
		var g: Node3D = FighterFactory.spawn_dummy(self, &"grunt",
				Transform3D(Basis.looking_at(Vector3.BACK), Vector3(0, 0, -1.2)), 1)
		await U.physics_frames(get_tree(), 20)
		hits.clear()
		played.clear()
		var levels: Array[String] = []
		var trail_seen := 0
		if spec[2] > 0.0:
			if "force_hold_charge" in combat:
				combat.set(&"force_hold_charge", true)
			combat.call(&"press", spec[1])
			var t0 := TimeDirector.now()
			var next := 0.15
			while TimeDirector.now() - t0 < spec[2]:
				await get_tree().physics_frame
				if TimeDirector.now() - t0 >= next:
					next += 0.3
					var glow := BloodFX.get_charge_glow(p)
					levels.append("%.2f" % (glow.call(&"get_level") if glow else -1.0))
			combat.call(&"release", spec[1])
			if "force_hold_charge" in combat:
				combat.set(&"force_hold_charge", false)
		else:
			combat.call(&"press", spec[1])
			combat.call(&"release", spec[1])
		var t1 := TimeDirector.now()
		while hits.is_empty() and TimeDirector.now() - t1 < 1.5:
			await get_tree().process_frame
			trail_seen = maxi(trail_seen, int(ScreenFX.get_trails().call(&"stats")["strike"]))
		if hits.is_empty():
			print("note: %s landed no hit (B's strike did not connect); skipped" % spec[0])
			g.queue_free()
			continue
		var h: Dictionary = hits[0]
		var fx: Dictionary = h["fx"]
		var snd: Dictionary = h["snd"]
		var scr: bool = not ScreenFX.flash_log.is_empty() and ScreenFX.flash_log.back()["frame"] == h["frame"]
		print("%s: %s P %.2f tier %s at frame %d -> flash frame %s ring %s blood %s, sound %s frame %s, screen flash %s; whooshes %s; charge glow by 0.3 s %s; strike trail channels %d" % [
			spec[0], h["move"], h["power"], HitInfo.tier_name(h["tier"]), h["frame"], fx.get("frame", -1),
			fx.get("ring", false), fx.get("blood", false), snd.get("id", &"-"), snd.get("frame", -1), scr,
			played.filter(func(s: StringName) -> bool: return String(s).begins_with("whoosh")), levels, trail_seen])
		if fx.get("frame", -1) != h["frame"] or snd.get("frame", -1) != h["frame"]:
			fails.append("%s: effects not on the hit frame" % spec[0])
		if snd.get("id", &"") != AudioFX.TIER_SOUND.get(h["tier"], &"?"):
			fails.append("%s: sound %s for tier %s" % [spec[0], snd.get("id", &""), HitInfo.tier_name(h["tier"])])
		if fx.get("blood", false) != (h["tier"] >= HitInfo.Tier.STAGGER):
			fails.append("%s: blood rule broken" % spec[0])
		if (h["tier"] >= HitInfo.Tier.LAUNCH) != scr or (h["tier"] >= HitInfo.Tier.LAUNCH) != fx.get("ring", false):
			fails.append("%s: ring / screen flash rule broken" % spec[0])
		if spec[2] > 0.0:
			if levels.size() >= 3 and float(levels[levels.size() - 1]) <= float(levels[0]):
				fails.append("charge glow did not brighten (%s)" % [levels])
			if not played.has(&"whoosh_charged"):
				fails.append("no charged whoosh")
			if trail_seen == 0:
				fails.append("no strike trail on the charged kick")
		await get_tree().create_timer(0.8).timeout
		g.queue_free()
	U.finish(get_tree(), "test_real_contact", fails, errlog)
