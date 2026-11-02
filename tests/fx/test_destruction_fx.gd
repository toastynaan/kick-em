extends Node3D
## Round 6 effects (docs/ARCHITECTURE.md, "Round 6: more destruction";
## acceptance row "Effects for every Round 6 event", owner F). Every event's
## effects and sounds spawn on the event's physics frame:
## - furniture_broken by surface: wood splinters + crack-snap, glass shards +
##   shatter + tinkle tail, cardboard paper bits, fabric stuffing + muffled
##   thump, concrete dust and grit; bigger breaks get more;
## - structure_collapsed: a creak and sifting dust; a heavy piece landing near
##   it booms once with a dust cloud (light or far pieces do not);
## - floor_damaged: the mark grows in place crack -> crater -> rubble, grit and
##   dust, sound by level; tiles pop with a tick; marks cap at
##   Tuning.FLOOR_DECAL_MAX with the oldest fading;
## - world_blast: chips and dust over the radius and a low thump by power;
## - the new surfaces get footstep and impact sounds;
## - budgets hold: no shock rings, screen flashes or blood decals from any of it.
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
	if not await U.wait_audio(get_tree(), 240000, true):
		fails.append("AudioFX never finished synthesising")
	AudioFX.sound_played.connect(func(id: StringName, _p: Vector3) -> void: played.append(id))
	var dfx: Node = BloodFX.get_destruction_fx()
	var player := U.make_fighter(self, Vector3(0, 0, 5))
	player.add_to_group(&"player")
	var thrown := U.make_fighter(self, Vector3(-1, 0, 0))
	await U.physics_frames(get_tree(), 2)
	var rings0 := _rings()
	var flashes0 := ScreenFX.flash_log.size()
	var blood0: int = BloodFX.get_decal_counts()["blood_created"]

	# --- furniture_broken by surface, small and big ------------------------------------
	var expect := {&"wood": [&"splinters", [&"break_wood", &"snap_wood"]],
		&"glass": [&"", [&"break_glass", &"glass_tinkle"]],
		&"cardboard": [&"paper", [&"break_cardboard"]],
		&"fabric": [&"paper", [&"break_fabric"]],
		&"concrete": [&"", [&"break_brick", &"strike_concrete"]]}
	var sizes := {}
	for kind: StringName in [&"chair", &"bench", &"glass", &"cardboard", &"sofa", &"planter"]:
		var row: Dictionary = Tuning.FURNITURE[kind]
		var surf: StringName = row["surface"]
		for over in [1.0, 4.0]:
			await U.physics_frames(get_tree(), 8)
			played.clear()
			var n0: int = dfx.get(&"effect_log").size()
			var frame := Engine.get_physics_frames()
			var dust0: int = BloodFX._dust_next
			var glass0: int = int(BloodFX.get_world_fx().get(&"counts").get(&"glass", 0))
			GameEvents.furniture_broken.emit(null, Vector3(0, 0.5, 0), kind, float(row["break"]) * over, thrown)
			var recs: Array = dfx.get(&"effect_log").slice(n0)
			var snd: Dictionary = AudioFX.destruction_sounds.back()
			var prims: Array = recs.map(func(r: Dictionary) -> StringName: return r["event"])
			var frames_ok: bool = recs.all(func(r: Dictionary) -> bool: return r["frame"] == frame) and snd["frame"] == frame
			var size: float = recs.back()["size"] if not recs.is_empty() else 0.0
			sizes[[kind, over]] = size
			var want_prim: StringName = expect[surf][0]
			var visual_ok := (want_prim == &"" or prims.has(want_prim))
			if surf == &"glass":
				visual_ok = int(BloodFX.get_world_fx().get(&"counts").get(&"glass", 0)) > glass0
			elif surf == &"concrete":
				visual_ok = BloodFX._dust_next != dust0
			if over == 1.0 or kind == &"sofa":
				print("furniture %-9s (%-9s) x%.0f: frame %d, effects %s size %.2f, sounds %s, all on the frame %s" % [
					kind, surf, over, frame, prims, size, snd["ids"], frames_ok])
			if not frames_ok:
				fails.append("%s: effects not on the event frame" % kind)
			if not visual_ok:
				fails.append("%s: missing %s effect" % [kind, surf])
			for id: StringName in expect[surf][1]:
				if not played.has(id):
					fails.append("%s: no %s sound (got %s)" % [kind, id, played])
	if sizes[[&"chair", 4.0]] <= sizes[[&"chair", 1.0]] or sizes[[&"sofa", 1.0]] <= sizes[[&"chair", 1.0]]:
		fails.append("bigger breaks do not get more (%s)" % [sizes])
	print("break sizes: chair %.2f -> %.2f at 4x, bench %.2f, sofa %.2f" % [sizes[[&"chair", 1.0]],
		sizes[[&"chair", 4.0]], sizes[[&"bench", 1.0]], sizes[[&"sofa", 1.0]]])

	# --- structure_collapsed: creak, sift, then a boom where the heavy piece lands -------
	await U.physics_frames(get_tree(), 8)
	var dm0 := get_node_or_null(^"/root/DebrisManager")
	# A heavy chunk the snap itself throws off (registered before the collapse): no boom.
	var chunk := _heavy(40.0)
	if dm0 != null:
		dm0.call(&"register", chunk, false)
	var cf := Engine.get_physics_frames()
	GameEvents.structure_collapsed.emit(null, Vector3(3, 3.2, 0), &"overhead")
	var crec: Dictionary = AudioFX.destruction_sounds.back()
	var sift_ok: bool = (dfx.get(&"effect_log") as Array).any(func(r: Dictionary) -> bool:
		return r["event"] == &"sift" and r["frame"] == cf)
	await get_tree().create_timer(Tuning.PILLAR_COLLAPSE_DELAY).timeout
	# What fell: registered with DebrisManager after the collapse began (as D does).
	var heavy := _heavy(40.0)
	var light := _heavy(1.0)
	var far := _heavy(40.0)
	for b in [heavy, light, far]:
		if dm0 != null:
			dm0.call(&"register", b, false)
	await U.physics_frames(get_tree(), 2)
	GameEvents.debris_landed.emit(chunk, Vector3(3.2, 0.2, 0.0), 7.0, &"concrete")  # the snap's own chunk
	var booms0: int = int(dfx.get(&"counts").get(&"collapse_landing", 0))
	played.clear()
	var lf := Engine.get_physics_frames()
	GameEvents.debris_landed.emit(heavy, Vector3(3.4, 0.2, 0.3), 7.0, &"concrete")
	var boom_now: bool = played.has(&"boom") and AudioFX.destruction_sounds.back()["frame"] == lf
	GameEvents.debris_landed.emit(heavy, Vector3(3.4, 0.2, 0.3), 3.0, &"concrete")  # bounce: no second boom
	await U.physics_frames(get_tree(), 30)
	GameEvents.debris_landed.emit(light, Vector3(3.0, 0.1, 0.0), 7.0, &"concrete")
	GameEvents.debris_landed.emit(far, Vector3(12.0, 0.1, 0.0), 7.0, &"concrete")
	var booms: int = int(dfx.get(&"counts").get(&"collapse_landing", 0)) - booms0
	print("collapse: creak on the frame %s, sift on the frame %s; heavy piece boom on its landing frame %s; booms total %d (want 1: no snap chunk, bounce, light or far booms)" % [
		crec["frame"] == cf and crec["ids"].has(&"creak"), sift_ok, boom_now, booms])
	if not (crec["frame"] == cf and crec["ids"].has(&"creak") and sift_ok and boom_now and booms == 1):
		fails.append("collapse effects wrong")

	# --- floor_damaged: one spot grows crack -> crater -> rubble ---------------------------
	BloodFX.reset()
	await U.physics_frames(get_tree(), 2)
	var spot := Vector3(-3, 0, -3)
	var growth: Array[String] = []
	var sizes_f: Array[float] = []
	for level in [1, 2, 3]:
		await U.physics_frames(get_tree(), 8)
		played.clear()
		var ff := Engine.get_physics_frames()
		GameEvents.floor_damaged.emit(spot + Vector3(0.1 * level, 0, 0), Tuning.FLOOR_LEVEL_RADIUS[level - 1], level, &"concrete")
		var levels: Array[int] = BloodFX.floor_mark_levels()
		var marks: Array = BloodFX.get_decals().filter(func(d: Decal) -> bool: return d.has_meta(&"floor_level"))
		var fr: Dictionary = AudioFX.destruction_sounds.back()
		var size := (marks[0] as Decal).size.x if marks.size() == 1 else -1.0
		sizes_f.append(size)
		growth.append("L%d: marks %s (decals %d, %.2f m) sounds %s on the frame %s" % [level, levels, marks.size(), size,
			fr["ids"], fr["frame"] == ff])
		var want: Array[int] = [0, 0, 0]
		want[level - 1] = 1
		if levels != want or marks.size() != 1 or fr["frame"] != ff:
			fails.append("floor level %d: marks %s, %d decals" % [level, levels, marks.size()])
	print("floor spot: %s" % "; ".join(growth))
	if not (sizes_f[1] > sizes_f[0] and sizes_f[2] >= sizes_f[1]):
		fails.append("floor mark does not grow")
	# Tiles pop with a tick and dust.
	await U.physics_frames(get_tree(), 8)
	played.clear()
	var t0: int = int(dfx.get(&"counts").get(&"tile", 0))
	GameEvents.floor_damaged.emit(Vector3(5, 0, -5), Tuning.FLOOR_LEVEL_RADIUS[0], 1, &"tile")
	var tile := RigidBody3D.new()
	tile.name = "TilePiece"
	tile.set_meta(&"surface", &"tile")
	tile.freeze = true
	add_child(tile)
	await U.physics_frames(get_tree(), 8)
	var dm := get_node_or_null(^"/root/DebrisManager")
	if dm != null:
		dm.call(&"register", tile, true)
	var tiles: int = int(dfx.get(&"counts").get(&"tile", 0)) - t0
	print("tiles: %d tile pops (floor_damaged on tile + a tile piece registered), sounds %s" % [tiles, played])
	if tiles != 2 or played.count(&"tile_pop") != 2:
		fails.append("tile pops wrong")
	# Cap: 60 cracks in new spots keep Tuning.FLOOR_DECAL_MAX, the oldest fading.
	for i in 60:
		GameEvents.floor_damaged.emit(Vector3(-15 + (i % 10) * 3.0, 0, -15 + int(i / 10.0) * 3.0), 0.6, 1, &"concrete")
		if i % 10 == 9:
			await get_tree().physics_frame
	var c1 := BloodFX.get_decal_counts()
	await get_tree().create_timer(BloodFX.DECAL_FADE_TIME + 0.3).timeout
	var c2 := BloodFX.get_decal_counts()
	print("floor mark cap: after 60 more cracks %d live + %d fading; after the fade %d live (cap %d)" % [c1["marks"],
		c1["fading"], c2["marks"], Tuning.FLOOR_DECAL_MAX])
	if c1["marks"] > Tuning.FLOOR_DECAL_MAX or c2["marks"] != Tuning.FLOOR_DECAL_MAX:
		fails.append("floor mark cap broken (%d / %d)" % [c1["marks"], c2["marks"]])
	if c2["live"] + c2["fading"] + c2["evicted"] + c2["released"] != c2["created"]:
		fails.append("decal counts do not add up")

	# --- world_blast ----------------------------------------------------------------------
	await U.physics_frames(get_tree(), 8)
	var vols: Array[float] = []
	for spec in [[1.5, 2000.0], [2.5, 9000.0]]:
		await U.physics_frames(get_tree(), 8)
		var bf := Engine.get_physics_frames()
		var b0: int = dfx.get(&"effect_log").size()
		GameEvents.world_blast.emit(Vector3(0, 0, -6), spec[0], spec[1], &"slam")
		var rec: Array = dfx.get(&"effect_log").slice(b0)
		var bs: Dictionary = AudioFX.destruction_sounds.back()
		var em: GPUParticles3D = null
		for e: GPUParticles3D in dfx.get(&"_blast_puffs"):
			if e.visible:
				em = e
		vols.append(_newest_db(&"thump_low"))
		var ring := (em.process_material as ParticleProcessMaterial).emission_ring_radius if em else 0.0
		print("blast r %.1f power %.0f: effects %s on the frame %s, ring %.2f m, thump %.1f dB on the frame %s" % [
			spec[0], spec[1], rec.map(func(r: Dictionary) -> StringName: return r["event"]),
			rec.all(func(r: Dictionary) -> bool: return r["frame"] == bf), ring, vols.back(), bs["frame"] == bf])
		if rec.is_empty() or bs["frame"] != bf or absf(ring - spec[0] * 0.8) > 0.01:
			fails.append("blast effects wrong")
	if vols[1] <= vols[0]:
		fails.append("blast thump does not scale with power")

	# --- New surfaces: footsteps and impacts ---------------------------------------------
	for surf: StringName in [&"glass", &"cardboard", &"fabric"]:
		await U.physics_frames(get_tree(), 10)
		played.clear()
		GameEvents.footstep.emit(player, Vector3(0, 0, 5), surf, 0.5)
		GameEvents.body_impact.emit(thrown, Vector3(0, 0.5, 0), Vector3.UP, 2000.0, surf)
		GameEvents.wall_struck.emit(player, null, Vector3(0, 1, 0), Vector3.BACK, 60.0, &"chip", surf)
		print("%s: sounds %s" % [surf, played])
		if not (played.has(AudioFX.STEP_BY_SURFACE[surf]) and played.has(AudioFX.STRIKE_BY_SURFACE[surf])):
			fails.append("%s: footstep / impact sounds missing" % surf)

	# --- Budgets ---------------------------------------------------------------------------
	print("budgets: shock rings +%d, screen flashes +%d, blood decals +%d" % [_rings() - rings0,
		ScreenFX.flash_log.size() - flashes0, BloodFX.get_decal_counts()["blood_created"]])
	if _rings() != rings0 or ScreenFX.flash_log.size() != flashes0:
		fails.append("Round 6 effects used the ring / flash budget")
	U.finish(get_tree(), "test_destruction_fx", fails, errlog)

## Shock rings shown so far (contact log entries with a ring).
func _rings() -> int:
	var n := 0
	for c: Dictionary in BloodFX.contact_log:
		if c["ring"]:
			n += 1
	return n

func _newest_db(id: StringName) -> float:
	var want = AudioFX.last_stream.get(id)
	for p: AudioStreamPlayer3D in AudioFX._players:
		if p.playing and p.stream == want:
			return p.volume_db
	return -100.0

## A frozen rigid body of `mass` kg in the scene (stands in for debris).
func _heavy(mass: float) -> RigidBody3D:
	var b := RigidBody3D.new()
	b.mass = mass
	add_child(b)
	b.freeze = true
	return b
