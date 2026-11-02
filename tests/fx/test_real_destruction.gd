extends Node3D
## Round 6 integration: the destruction effects against D's and K's real code
## in the real Yard. A real pillar shattered by a flying body's energy: its
## structure_collapsed (at the snap) gets the creak and sifting dust on that
## frame; its overhead piece drops Tuning.PILLAR_COLLAPSE_DELAY later and, where
## it lands, gets one boom and a dust cloud. WorldDamage floor damage draws
## the marks by level; K's clutter breaking draws its surface's burst and
## sound on the event frame. Parts the other modules have not landed yet are
## skipped with a note. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")

var events: Array[Dictionary] = []

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	if not await U.wait_audio(get_tree()):
		fails.append("AudioFX never finished synthesising")
	var dfx: Node = BloodFX.get_destruction_fx()
	GameEvents.structure_collapsed.connect(func(_n: Node3D, p: Vector3, k: StringName) -> void:
		events.append({"event": &"collapse", "frame": Engine.get_physics_frames(), "pos": p, "kind": k}))
	GameEvents.furniture_broken.connect(func(_n: Node3D, p: Vector3, k: StringName, e: float, _b: Node3D) -> void:
		events.append({"event": &"furniture", "frame": Engine.get_physics_frames(), "pos": p, "kind": k, "energy": e}))
	GameEvents.floor_damaged.connect(func(p: Vector3, r: float, l: int, s: StringName) -> void:
		events.append({"event": &"floor", "frame": Engine.get_physics_frames(), "pos": p, "level": l, "surface": s}))
	var yard := YardBuilder.new()
	yard.name = "Yard"
	add_child(yard)
	yard.build()
	await U.physics_frames(get_tree(), 5)

	# --- A real pillar: snap, creak, drop, boom ------------------------------------------
	var pillar: Node3D = null
	for n in get_tree().get_nodes_in_group(&"breakables") + get_tree().get_nodes_in_group(&"destructibles"):
		if n is Pillar and n.get(&"head") != null:
			pillar = n
			break
	if pillar == null:
		print("note: no pillar with an overhead piece in the Yard yet; skipped")
	else:
		var hit: Vector3 = pillar.global_position + Vector3(0, 1.2, 0)
		var n0: int = dfx.get(&"effect_log").size()
		var s0: int = AudioFX.destruction_sounds.size()
		events.clear()
		var res: StringName = pillar.call(&"receive_impact", 20000.0, hit, Vector3(14, 0, 0))
		var col: Array = events.filter(func(e: Dictionary) -> bool: return e["event"] == &"collapse")
		var t0 := TimeDirector.now()
		var boomed := false
		var boom_frame := -1
		var land_t := -1.0
		while TimeDirector.now() - t0 < 4.0 and not boomed:
			await get_tree().physics_frame
			for r: Dictionary in (dfx.get(&"effect_log") as Array).slice(n0):
				if r["event"] == &"collapse_landing":
					boomed = true
					boom_frame = r["frame"]
					land_t = TimeDirector.now() - t0
		var recs: Array = (dfx.get(&"effect_log") as Array).slice(n0)
		var snds: Array = AudioFX.destruction_sounds.slice(s0)
		if col.is_empty():
			print("note: the pillar (%s) emitted no structure_collapsed; collapse check skipped" % res)
		else:
			var cf: int = col[0]["frame"]
			var sift_on := recs.any(func(r: Dictionary) -> bool: return r["event"] == &"sift" and r["frame"] == cf)
			var creak_on := snds.any(func(r: Dictionary) -> bool: return r["event"] == &"collapse" and r["frame"] == cf)
			var boom_snd := snds.any(func(r: Dictionary) -> bool: return r["event"] == &"collapse_landing" and r["frame"] == boom_frame)
			var booms := recs.filter(func(r: Dictionary) -> bool: return r["event"] == &"collapse_landing").size()
			print("real pillar (%s): structure_collapsed %s at frame %d -> creak %s, sift %s on that frame; heavy piece landed and boomed %.2f s later (sound on its frame %s), booms %d" % [
				res, col[0]["kind"], cf, creak_on, sift_on, land_t, boom_snd, booms])
			if not (sift_on and creak_on):
				fails.append("collapse creak / dust not on the event frame")
			if not boomed or not boom_snd or land_t < Tuning.PILLAR_COLLAPSE_DELAY:
				fails.append("no boom where the overhead piece landed (%.2f s)" % land_t)

	# --- WorldDamage: real floor damage -------------------------------------------------------
	var wd := get_node_or_null(^"/root/WorldDamage")
	var spot := Vector3(-4.0, 0.0, 4.0)
	events.clear()
	var lvl: int = wd.call(&"damage_floor", spot, Tuning.FLOOR_LEVEL_ENERGY[2] + 1.0, &"concrete") if wd != null else 0
	var floors: Array = events.filter(func(e: Dictionary) -> bool: return e["event"] == &"floor")
	if floors.is_empty():
		print("note: WorldDamage emitted no floor_damaged yet (level %d); real floor check skipped" % lvl)
	else:
		var levels: Array[int] = BloodFX.floor_mark_levels()
		print("real WorldDamage: floor_damaged %s -> marks by level %s" % [floors.map(func(e: Dictionary) -> int: return e["level"]),
			levels])
		if levels[int(floors.back()["level"]) - 1] < 1:
			fails.append("no floor mark for WorldDamage's floor_damaged")

	# --- K's clutter: break one of each surface ------------------------------------------------
	var by_surface: Dictionary = {}
	for n in get_tree().get_nodes_in_group(&"breakables"):
		var k = n.get(&"kind")
		if k == null or not Tuning.FURNITURE.has(StringName(k)) or n.get(&"is_broken") == true:
			continue
		var surf := StringName(Tuning.FURNITURE[StringName(k)]["surface"])
		if not by_surface.has(surf):
			by_surface[surf] = n
	if by_surface.is_empty():
		print("note: no clutter in the Yard yet (K); real furniture check skipped")
	for surf: StringName in by_surface:
		var obj: Node3D = by_surface[surf]
		var k := StringName(obj.get(&"kind"))
		var n0: int = dfx.get(&"effect_log").size()
		events.clear()
		var res: StringName = obj.call(&"receive_impact", float(Tuning.FURNITURE[k]["break"]) * 3.0,
				obj.global_position + Vector3.UP * 0.4, Vector3(8, 0, 0))
		var fb: Array = events.filter(func(e: Dictionary) -> bool: return e["event"] == &"furniture")
		if fb.is_empty():
			print("note: %s (%s) returned %s with no furniture_broken" % [k, surf, res])
			continue
		var f: int = fb[0]["frame"]
		var recs: Array = (dfx.get(&"effect_log") as Array).slice(n0)
		var on_frame := recs.any(func(r: Dictionary) -> bool: return r["event"] == &"furniture" and r["frame"] == f)
		var snd: Dictionary = AudioFX.destruction_sounds.back()
		print("real clutter %s (%s): %s, effects %s on the frame %s, sounds %s on the frame %s" % [k, surf, res,
			recs.map(func(r: Dictionary) -> StringName: return r["event"]), on_frame, snd["ids"], snd["frame"] == f])
		if not on_frame or snd["frame"] != f:
			fails.append("%s: effects not on the furniture_broken frame" % k)
		await U.physics_frames(get_tree(), 4)
	U.finish(get_tree(), "test_real_destruction", fails, errlog)
