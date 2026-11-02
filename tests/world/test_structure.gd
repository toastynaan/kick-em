extends Node3D
## Round 6 structure (docs/ARCHITECTURE.md, Round 6 checks, owner D), in the
## real Yard with real 70 kg bodies launched at it:
## 1. The platform: its four faces are breakable wood skirt panels
##    (Tuning.PLATFORM_SKIRT_SURFACE); a 6 m/s body (1,260 J) opens a hole and
##    ends inside the hollow, the posts stand; the deck stays: a ray finds it at
##    1.8 m and a fighter put on it stays standing on it.
## 2. The second low wall is concrete: an 18 m/s body cracks it (10,261 J), a
##    second breaks it (break energy now 15,000 - E/2); strikes chip it.
## 3. At least Tuning.PARTITION_MIN free-standing partitions; a 10 m/s body
##    breaks each, and no cell is left floating afterwards.
## 4. Door frames: a body breaks a wood jamb; the lintel over it creaks
##    (structure_collapsed &"lintel") and falls within Tuning.COLLAPSE_DELAY;
##    its pieces stay. Its &"structure" blasts go off where the pieces land
##    (under 1 m), never at creak time at lintel height.
## 5. YardBuilder.get_structure_features() lists every structure kind K avoids.

var yard: YardBuilder
var _decisions: Array = []
var _collapses: Array = []
var _ok := true
## Game-time clock (physics delta is scaled by Engine.time_scale) and the lintel watch.
var _game := 0.0
var _watch_lintel: Destructible = null
var _lintel_fell := -1.0
var _blasts: Array = []

func _physics_process(delta: float) -> void:
	_game += delta
	if _watch_lintel != null and _lintel_fell < 0.0 and is_instance_valid(_watch_lintel) and _watch_lintel.is_broken:
		_lintel_fell = _game

func _ready() -> void:
	ImpactResolver.wall_decided.connect(func(f: Node3D, w: Node3D, outcome: StringName, e: float, _p: Vector3) -> void:
		_decisions.append({"fighter": f, "wall": w, "outcome": outcome, "energy": e, "t": TimeDirector.now()}))
	GameEvents.structure_collapsed.connect(func(n: Node3D, p: Vector3, kind: StringName) -> void:
		_collapses.append({"node": n, "pos": p, "kind": kind, "t": TimeDirector.now(), "g": _game}))
	GameEvents.world_blast.connect(func(c: Vector3, r: float, power: float, source: StringName) -> void:
		_blasts.append({"center": c, "radius": r, "power": power, "source": source, "g": _game}))
	yard = YardBuilder.new()
	add_child(yard)
	yard.build()
	# This tests D's structure: agent K's clutter in the test lanes is cleared first.
	var lanes: Array[Vector3] = [Vector3(-5.0, 0, 0.3), Vector3(0.3, 0, -6.0), Vector3(-9.6, 0, 7.65)]
	for w: Array in YardBuilder.PARTITIONS:
		lanes.append(Vector3((w[0] as Vector2).x, 0, (w[0] as Vector2).y))
	for c: Vector3 in lanes:
		WorldTestUtil.clear_clutter_near(get_tree(), c, 2.5)
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not await WorldTestUtil.real_ragdoll_available(self):
		print("[structure] FAIL: real ragdoll unavailable")
		get_tree().quit(1)
		return
	_run_lanes_clear()
	await _platform()
	await _concrete_low_wall()
	await _partitions()
	await _door_frame()
	_features()
	print("[structure] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[structure] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _find(meta: StringName, near: Vector3, radius := 1.0) -> Destructible:
	for d in yard.get_destructibles():
		if d.has_meta(meta) and d.global_position.distance_to(near) < radius:
			return d
	return null

## Launch a fresh 70 kg body whose COM starts at `com_xz` with `vel`; returns
## {"dec": decisions of this body, "end": COM after `seconds`, "hp_lost"}.
func _fly(com_xz: Vector3, vel: Vector3, seconds: float) -> Dictionary:
	_decisions.clear()
	var d := Vector3(-vel.x, 0, -vel.z).normalized()
	var f := WorldTestUtil.spawn_body(self, Transform3D(Basis.looking_at(d, Vector3.UP), com_xz + Vector3(0, 0.05, 0)),
		false, &"player")
	f.max_hp = 2000.0
	f.hp = 2000.0
	await get_tree().physics_frame
	await get_tree().physics_frame
	var c := f.get_center_of_mass()
	f.global_position += Vector3(com_xz.x - c.x, 0, com_xz.z - c.z)
	f.reset_physics_interpolation()
	await get_tree().physics_frame
	f.launch(vel, f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, seconds)
	var res := {"dec": _decisions.filter(func(x: Dictionary) -> bool: return x["fighter"] == f),
		"end": f.get_center_of_mass(), "hp_lost": 2000.0 - f.hp}
	f.queue_free()
	ImpactResolver.reset()
	await get_tree().physics_frame
	return res

func _platform() -> void:
	var skirts := yard.get_destructibles().filter(func(d: Destructible) -> bool: return d.has_meta(&"platform_skirt"))
	var all_wood := skirts.all(func(d: Destructible) -> bool: return d.surface == Tuning.PLATFORM_SKIRT_SURFACE)
	var east := _find(&"platform_skirt", Vector3(-5.05, 0.825, 0.0))
	var plat: AABB = yard.get_parkour_features()["platform"]
	# 6 m/s body from the east, COM 1.6 m off the face.
	var r := await _fly(Vector3(-5.0 + 1.6, 0, 0.3), Vector3(-6.0, 0.6, 0), 1.2)
	var dec: Array = r["dec"].filter(func(x: Dictionary) -> bool: return x["wall"] == east)
	var holed := east != null and east.get_alive_count() < east.get_cell_count() and not east.is_broken
	var inside: bool = (r["end"] as Vector3).x < -5.1
	# The deck: a ray from above finds it at 1.8 m; a fighter put on it stays up there.
	var q := PhysicsRayQueryParameters3D.create(Vector3(-6.5, 3.0, 0.0), Vector3(-6.5, 0.5, 0.0), Layers.WORLD | Layers.DESTRUCTIBLE)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var deck_y: float = hit["position"].y if not hit.is_empty() else -1.0
	var stander := WorldTestUtil.spawn_body(self, Transform3D(Basis(), Vector3(-6.5, PLATFORM_TOP + 0.05, -1.0)), false)
	await WorldTestUtil.wait_game(self, 1.0)
	var stand_y := stander.global_position.y
	var posts := 0
	for pc in YardBuilder.PLATFORM_POSTS:
		var pq := PhysicsPointQueryParameters3D.new()
		pq.position = Vector3(pc.x, 0.8, pc.y)
		pq.collision_mask = Layers.WORLD
		if not get_world_3d().direct_space_state.intersect_point(pq).is_empty():
			posts += 1
	_line("platform: %d skirt faces (%s), a 6 m/s body -> %s E=%s, hole=%s (%d/%d boards left), body inside=%s; deck at %.2f m, a fighter on it stands at y=%.2f; posts standing %d/%d" % [
		skirts.size(), Tuning.PLATFORM_SKIRT_SURFACE, dec.map(func(x: Dictionary) -> String: return String(x["outcome"])),
		dec.map(func(x: Dictionary) -> int: return int(x["energy"])), holed, east.get_alive_count() if east else -1,
		east.get_cell_count() if east else -1, inside, deck_y, stand_y, posts, YardBuilder.PLATFORM_POSTS.size()],
		skirts.size() == 4 and all_wood and dec.size() >= 1 and dec[0]["outcome"] == &"break" and holed and inside \
		and absf(deck_y - plat.end.y) < 0.02 and absf(stand_y - plat.end.y) < 0.1 \
		and posts == YardBuilder.PLATFORM_POSTS.size())
	stander.queue_free()

const PLATFORM_TOP := YardBuilder.PLATFORM_H

func _concrete_low_wall() -> void:
	var w := _find(&"low_wall", Vector3(0.0, 0.45, -6.5))
	var surface_ok := w != null and w.surface == &"concrete" and not w.is_unbreakable()
	# Strikes chip it.
	var res := w.receive_strike(null, Vector3(0.4, 0.5, -6.35), Vector3(0, 0, -1), 60.0) if w else &"none"
	var dmg := w.get_cell_damage_at(Vector3(0.4, 0.5, -6.35)) if w else 0.0
	var outs: Array = []
	var be := 0.0
	for k in 2:
		var r := await _fly(Vector3(0.3, 0, -6.35 + 1.6), Power.launch_velocity(11.0, Vector3.FORWARD, 70.0), 0.8)
		for d: Dictionary in r["dec"]:
			if d["wall"] == w:
				outs.append("%s(%.0f J)" % [d["outcome"], d["energy"]])
		if k == 0 and w:
			be = w.break_energy
	var ok: bool = surface_ok and (res == &"chip" or res == &"crack") and dmg > 0.0 and outs.size() == 2 \
		and String(outs[0]).begins_with("crack") and String(outs[1]).begins_with("break")
	_line("concrete low wall: surface %s, a strike -> %s (cell damage %.0f), two 18 m/s bodies -> %s, break energy after the first %.0f J (15,000 - E/2)" % [
		w.surface if w else &"-", res, dmg, outs, be], ok)

func _partitions() -> void:
	var parts := yard.get_destructibles().filter(func(d: Destructible) -> bool: return d.has_meta(&"partition"))
	var rows: Array = []
	var all_ok := parts.size() >= Tuning.PARTITION_MIN
	for p: Destructible in parts:
		var n := p.global_basis.z.normalized()
		# From the open side: the west partition stands beside a pillar.
		for pl: Vector2 in YardBuilder.PILLARS:
			var side := p.global_position + n * 1.6
			if Vector2(side.x - pl.x, side.z - pl.y).length() < 1.5:
				n = -n
		var start := p.global_position + n * 1.6
		start.y = 0.0
		var r := await _fly(start, -n * 10.0 + Vector3.UP * 0.8, 0.8)
		await WorldTestUtil.wait_game(self, Tuning.COLLAPSE_DELAY + 0.1)
		var dec: Array = r["dec"].filter(func(x: Dictionary) -> bool: return x["wall"] == p)
		var broke: bool = dec.size() >= 1 and dec[0]["outcome"] == &"break"
		var floating := p.get_floating_cell_count()
		rows.append("%s %s %s floating=%d" % [p.name, p.surface, dec.map(func(x: Dictionary) -> String: return String(x["outcome"])),
			floating])
		all_ok = all_ok and broke and floating == 0
	_line("partitions: %d (min %d): %s" % [parts.size(), Tuning.PARTITION_MIN, rows], all_ok)

func _door_frame() -> void:
	# The west facade doorway at z = 9: the jamb at z = 9 - 1.35, hit from the courtyard.
	var jamb := _find(&"door_frame", Vector3(-11.125, 1.5, 9.0 - 1.35), 0.2)
	var lintel: Destructible = jamb.lintel if jamb else null
	_collapses.clear()
	_blasts.clear()
	_watch_lintel = lintel
	var r := await _fly(Vector3(-11.0 + 1.6, 0, 9.0 - 1.35), Vector3(-8.0, 0.8, 0), 1.0)
	var dec: Array = r["dec"].filter(func(x: Dictionary) -> bool: return x["wall"] == jamb)
	var t_break: float = dec[0]["t"] if dec.size() > 0 else -1.0
	var creak := _collapses.filter(func(c: Dictionary) -> bool: return c["node"] == lintel and c["kind"] == &"lintel")
	# Game time from the creak (the collapse runs in world time: the wall-break
	# slow motion stretches it in real time, like every other falling thing).
	var fell_at := _lintel_fell
	var pieces: Array = lintel.last_chunks.duplicate() if lintel else []
	await WorldTestUtil.wait_game(self, 5.0)
	var kept := pieces.filter(func(b: Variant) -> bool: return is_instance_valid(b) and (b as CollisionObject3D).collision_layer != 0).size()
	var delay: float = fell_at - (float(creak[0]["g"]) if creak.size() > 0 else 0.0)
	var ok: bool = jamb != null and jamb.surface == &"wood" and dec.size() >= 1 and dec[0]["outcome"] == &"break" \
		and jamb.is_broken and creak.size() == 1 and fell_at > 0.0 and delay <= Tuning.COLLAPSE_DELAY + 0.02 \
		and pieces.size() >= 2 and kept == pieces.size() and pieces.all(func(b: Variant) -> bool: return b is FallingPiece)
	_line("door frame: a body into the wood jamb -> %s (E=%s), lintel creak %d, falls %.3f s (game time) later (COLLAPSE_DELAY %.2f), %d pieces (FallingPiece), %d still there 5 s on" % [
		dec.map(func(x: Dictionary) -> String: return String(x["outcome"])), dec.map(func(x: Dictionary) -> int: return int(x["energy"])),
		creak.size(), delay, Tuning.COLLAPSE_DELAY, pieces.size(), kept], ok)
	var structure := _blasts.filter(func(b: Dictionary) -> bool: return b["source"] == &"structure")
	var high := structure.filter(func(b: Dictionary) -> bool: return (b["center"] as Vector3).y >= 1.0)
	var before := structure.filter(func(b: Dictionary) -> bool: return fell_at < 0.0 or float(b["g"]) < fell_at)
	_line("lintel structure blasts: %s (want each under 1 m, after the fall starts)" % [structure.map(func(b: Dictionary) -> String:
		return "at y %.2f %.0f J, %.2f s after the fall" % [(b["center"] as Vector3).y, b["power"], float(b["g"]) - fell_at])],
		structure.size() >= 1 and high.is_empty() and before.is_empty())
	var frames := yard.get_destructibles().filter(func(d: Destructible) -> bool: return d.has_meta(&"door_frame"))
	var jambs := frames.filter(func(d: Destructible) -> bool: return d.kind == &"jamb")
	_line("door frames: %d jambs and %d lintels, all wood breakables" % [jambs.size(), frames.size() - jambs.size()],
		jambs.size() >= 2 and frames.all(func(d: Destructible) -> bool: return d.surface == &"wood" and d.is_in_group(&"breakables")))

func _features() -> void:
	var feats := yard.get_structure_features()
	var kinds := {}
	for f: Dictionary in feats:
		kinds[f["kind"]] = int(kinds.get(f["kind"], 0)) + 1
	var want: Array[StringName] = [&"platform", &"platform_approach", &"low_wall", &"partition", &"pillar", &"pillar_fall",
		&"crate", &"lamp", &"door", &"plaza", &"run_strip", &"run_open", &"breach", &"entry", &"spawn", &"lane"]
	var missing := want.filter(func(k: StringName) -> bool: return not kinds.has(k))
	_line("get_structure_features: %d entries %s, missing %s" % [feats.size(), kinds, missing], missing.is_empty())

## Round 6 review: the wall-run lanes' strip and open floor hold none of the
## Yard's own solid pieces (low walls, partitions, pillars, crates, lamps) or
## throwables. The platform's west edge is the one exception: 0.5 m into the
## west lane's open floor, a kick-off target.
func _run_lanes_clear() -> void:
	var feats := yard.get_structure_features()
	var zones: Array[AABB] = []
	for f: Dictionary in feats:
		if f["kind"] == &"run_strip" or f["kind"] == &"run_open":
			var a: AABB = f["aabb"]
			zones.append(AABB(Vector3(a.position.x, -1.0, a.position.z), Vector3(a.size.x, 10.0, a.size.z)))
	var bad: Array = []
	var solids := 0
	for f: Dictionary in feats:
		if not f["kind"] in [&"low_wall", &"partition", &"pillar", &"crate", &"lamp"]:
			continue
		solids += 1
		var box: AABB = (f["aabb"] as AABB).grow(-0.02)
		for z in zones:
			if z.intersects(box):
				bad.append("%s at %s" % [f["kind"], box.get_center()])
	var props := yard.get_throwables()
	for t: ThrowableProp in props:
		for z in zones:
			if z.grow(0.1).has_point(Vector3(t.global_position.x, 0.0, t.global_position.z)):
				bad.append("%s at %s" % [t.name, t.global_position])
	_line("run lanes (%d strips and open floors) clear of %d solid pieces and %d throwables: in the way %s" % [
		zones.size(), solids, props.size(), bad], zones.size() == 8 and solids > 0 and props.size() > 0 and bad.is_empty())
