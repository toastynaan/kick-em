extends Node3D
## Integration: the effects against the real game. A real player strikes real
## grunts through CombatController: a tapped jab, a held (heavy) jab and a
## roundhouse. Every hit_landed B emits must get its flash, sound and blood on
## that physics frame. Round 7 hits (HitInfo.react set) must follow their
## weight: the flash size, the sound layers (the thump exactly from 0.6), the
## screen flash (from 0.7 or a launch) and push dust (pushes of 1 m or more),
## and the roundhouse must flash bigger and play more layers than the jab.
## Hits from a B that has not landed Round 7 yet follow the tier rules (noted).
## Round 8: a real held press charges (glow and hum on charge_started); a charged
## hit plays the charged crunch, a hit that adds pressure ticks, and a hit
## that breaks the grunt plays the guard break and its burst on its frame (and
## flashes the screen whatever its weight).
## Then a real dodge through the player's Traversal (M): on its dodged frame,
## the whoosh, the dust kick and an after-image where it started.
## Skips (with a note) whatever the other modules have not landed yet.
## OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")
const HOLD := 0.35               ## s a held punch is kept down (past Tuning.R7_HOLD_THRESHOLD)

var hits: Array[Dictionary] = []
var played: Array = []           ## [id, physics frame]
var broke_frames: Array[int] = []  ## Round 8: physics frames of pressure_broken
var charge_seen: Array = []      ## Round 8: [frame, glow on, hums] at each player charge_started

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
	var ff: Node = BloodFX.get_freeflow_fx()
	GameEvents.pressure_broken.connect(func(_f: Node3D, _a: Node3D) -> void: broke_frames.append(Engine.get_physics_frames()))
	GameEvents.charge_started.connect(func(f: Node3D, _m: StringName) -> void:
		if is_instance_valid(f) and f.is_in_group(&"player"):
			charge_seen.append([Engine.get_physics_frames(), BloodFX.get_charge_glow(f) != null, AudioFX.active_hums()]))
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void:
		if info.attacker == null or not info.attacker.is_in_group(&"player"):
			return
		var frame := Engine.get_physics_frames()
		var scr: bool = not ScreenFX.flash_log.is_empty() and ScreenFX.flash_log.back()["frame"] == frame
		var log: Array = ff.get(&"effect_log")
		var dust: bool = not log.is_empty() and log.back()["event"] == &"push_dust" and log.back()["frame"] == frame
		hits.append({"frame": frame, "info": info, "fx": BloodFX.contact_log.back() if not BloodFX.contact_log.is_empty() else {},
			"snd": AudioFX.hit_sounds.back() if not AudioFX.hit_sounds.is_empty() else {}, "screen": scr, "dust": dust}))
	var p: Node3D = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis.looking_at(Vector3.FORWARD), Vector3.ZERO), 0)
	if not p.is_in_group(&"player"):
		p.add_to_group(&"player")
	await U.physics_frames(get_tree(), 15)
	var combat = p.get(&"combat")
	if combat == null:
		print("note: no CombatController; skipped")
		U.finish(get_tree(), "test_real_contact", fails, errlog)
		return

	var A: Dictionary = CombatController.Action
	# ROUNDHOUSE is Round 7's; an older CombatController kicks with KICK.
	var kick: int = A.get("ROUNDHOUSE", A.get("KICK", -1))
	var r7_flash := {}
	var r7_layers := {}
	for spec in [["tap jab", A["LIGHT"], 0.0], ["held jab", A["LIGHT"], HOLD], ["roundhouse", kick, 0.0]]:
		if int(spec[1]) < 0:
			print("note: no %s action; skipped" % spec[0])
			continue
		var g: Node3D = FighterFactory.spawn_dummy(self, &"grunt",
				Transform3D(Basis.looking_at(Vector3.BACK), Vector3(0, 0, -1.2)), 1)
		await U.physics_frames(get_tree(), 20)
		hits.clear()
		played.clear()
		charge_seen.clear()
		combat.call(&"press", spec[1])
		if float(spec[2]) > 0.0:
			var th := TimeDirector.now()
			while TimeDirector.now() - th < float(spec[2]):
				await get_tree().physics_frame
		combat.call(&"release", spec[1])
		var t1 := TimeDirector.now()
		while hits.is_empty() and TimeDirector.now() - t1 < 1.5:
			await get_tree().process_frame
		if hits.is_empty():
			print("note: %s landed no hit (B's strike did not connect); skipped" % spec[0])
			g.queue_free()
			continue
		var h: Dictionary = hits[0]
		var info: HitInfo = h["info"]
		var fx: Dictionary = h["fx"]
		var snd: Dictionary = h["snd"]
		var on_frame: Array = played.filter(func(e: Array) -> bool: return e[1] == h["frame"]).map(
				func(e: Array) -> StringName: return e[0])
		var r7 := FXRules.is_round7(info)
		print("%s: %s react %s weight %.2f push %.1f m tier %s at frame %d -> flash frame %s (%.2f m), sound frame %s %s, blood %s, screen flash %s, push dust %s; played %s" % [
			spec[0], info.move_id, info.react if r7 else &"-", info.weight, info.push, HitInfo.tier_name(info.tier),
			h["frame"], fx.get("frame", -1), fx.get("flash_size", 0.0), snd.get("frame", -1),
			snd.get("layers", [snd.get("id", &"-")]), fx.get("blood", false), h["screen"], h["dust"], on_frame])
		if fx.get("frame", -1) != h["frame"] or snd.get("frame", -1) != h["frame"]:
			fails.append("%s: effects not on the hit frame" % spec[0])
		if fx.get("blood", false) != (FXRules.tier_of(info) >= HitInfo.Tier.STAGGER):
			fails.append("%s: blood rule broken" % spec[0])
		if r7:
			var w := FXRules.weight_of(info)
			var want_layers: Array = AudioFX.hit_layers(info).map(func(l: Array) -> StringName: return l[0])
			var want_flash := lerpf(BloodFX.IMPACT_FLASH_SIZE.x, BloodFX.IMPACT_FLASH_SIZE.y,
					lerpf(BloodFX.R7_FLASH_POWER.x, BloodFX.R7_FLASH_POWER.y, w))
			if snd.get("layers", []) != want_layers or (want_layers.has(&"hit_thump") != (w >= 0.6)):
				fails.append("%s: layers %s, want %s" % [spec[0], snd.get("layers", []), want_layers])
			for id in want_layers:
				if not on_frame.has(id):
					fails.append("%s: %s not played on the hit frame" % [spec[0], id])
			if absf(float(fx.get("flash_size", 0.0)) - want_flash) > 0.001:
				fails.append("%s: flash %.2f m, want %.2f for weight %.2f" % [spec[0], fx.get("flash_size", 0.0), want_flash, w])
			# Round 8: a hit that breaks the victim's pressure flashes the screen too.
			var broke := broke_frames.has(int(h["frame"]))
			if h["screen"] != (w >= ScreenFX.R7_FLASH_FROM or info.react == &"launch" or broke):
				fails.append("%s: screen flash %s at weight %.2f (broke %s)" % [spec[0], h["screen"], w, broke])
			_check_r8(spec[0], info, on_frame, broke, fails)
			if h["dust"] != (info.push >= 1.0):
				fails.append("%s: push dust %s for %.1f m" % [spec[0], h["dust"], info.push])
			r7_flash[spec[0]] = float(fx.get("flash_size", 0.0))
			r7_layers[spec[0]] = (snd.get("layers", []) as Array).size()
		else:
			print("note: %s is not a Round 7 hit yet (B has not landed HitInfo.react); tier rules checked" % spec[0])
			if snd.get("id", &"") != AudioFX.TIER_SOUND.get(FXRules.tier_of(info), &"?"):
				fails.append("%s: sound %s for tier %s" % [spec[0], snd.get("id", &""), HitInfo.tier_name(info.tier)])
			if (FXRules.tier_of(info) >= HitInfo.Tier.LAUNCH) != fx.get("ring", false):
				fails.append("%s: ring rule broken" % spec[0])
		await get_tree().create_timer(0.8).timeout
		g.queue_free()
	if r7_flash.has("tap jab") and r7_flash.has("roundhouse"):
		print("real jab vs roundhouse: flash %.2f m vs %.2f m, layers %d vs %d" % [r7_flash["tap jab"],
			r7_flash["roundhouse"], r7_layers["tap jab"], r7_layers["roundhouse"]])
		if r7_flash["roundhouse"] <= r7_flash["tap jab"] or r7_layers["roundhouse"] <= r7_layers["tap jab"]:
			fails.append("the real roundhouse does not out-weigh the real jab")
	# --- A real dodge (Traversal.start_dodge) ----------------------------------------
	var tv = p.get(&"traversal")
	if tv == null or not (tv as Object).has_method(&"start_dodge"):
		print("note: the player's Traversal has no start_dodge yet; real dodge skipped")
	else:
		await U.physics_frames(get_tree(), 60)
		var dodge_frame := [-1]
		var cb := func(f: Node3D, _d: Vector3) -> void:
			if f == p:
				dodge_frame[0] = Engine.get_physics_frames()
		GameEvents.dodged.connect(cb)
		played.clear()
		var ff0: int = ff.get(&"effect_log").size()
		var start: Vector3 = p.global_position
		var ok: bool = tv.call(&"start_dodge", Vector3.RIGHT)
		GameEvents.dodged.disconnect(cb)
		var ids: Array = played.filter(func(e: Array) -> bool: return e[1] == dodge_frame[0]).map(
				func(e: Array) -> StringName: return e[0])
		var log: Array = ff.get(&"effect_log")
		var dusted := false
		for k in range(ff0, log.size()):
			if log[k]["event"] == &"dodge_dust" and log[k]["frame"] == dodge_frame[0]:
				dusted = true
		var ghosts := ScreenFX.active_afterimages()
		var ghost_at := Vector3.INF
		for g: Node3D in ScreenFX._ghosts:
			if g.visible and g.get_child_count() > 0:
				ghost_at = (g.get_child(0) as Node3D).global_position
		await U.physics_frames(get_tree(), 40)
		print("real dodge: started %s on frame %d, sounds %s, dust %s, after-images %d (first part %.2f m from the player's start), moved %.2f m" % [
			ok, dodge_frame[0], ids, dusted, ghosts, ghost_at.distance_to(start) if ghost_at != Vector3.INF else -1.0,
			start.distance_to(p.global_position)])
		if not ok or dodge_frame[0] < 0:
			print("note: the real dodge did not start (Traversal refused); skipped")
		elif not (ids.has(&"sidestep") and dusted and ghosts >= 1):
			fails.append("real dodge: sounds %s, dust %s, after-images %d" % [ids, dusted, ghosts])
	U.finish(get_tree(), "test_real_contact", fails, errlog)

## Round 8 on a real hit: a charged strike plays the charged crunch, a hit that
## adds pressure ticks, a break plays the guard break and bursts, all on the
## hit's frame; a real charge lit the glow and the hum on charge_started.
func _check_r8(what: String, info: HitInfo, on_frame: Array, broke: bool, fails: Array[String]) -> void:
	var cfx: Node = BloodFX.get_charge_fx()
	var bursts: Array = (cfx.get(&"effect_log") as Array).filter(func(e: Dictionary) -> bool:
		return e["event"] == &"break_burst" and broke_frames.has(int(e["frame"])))
	print("  round 8: charged %s c %.2f, pressure %.1f, broken bonus %s, broke %s; charge_started %s" % [info.charged,
		info.charge, info.pressure, info.broken_bonus, broke, charge_seen])
	for rec: Array in charge_seen:
		if not rec[1] or int(rec[2]) < 1:
			fails.append("%s: charge_started without the glow or the hum" % what)
	if info.charged and not on_frame.has(&"hit_charged"):
		fails.append("%s: charged hit without the charged crunch" % what)
	if info.pressure > 0.0 and not on_frame.has(&"pressure_tick"):
		fails.append("%s: pressure %.1f without a tick" % [what, info.pressure])
	if broke and (not on_frame.has(&"guard_break") or bursts.is_empty()):
		fails.append("%s: the break without its sound or burst" % what)

