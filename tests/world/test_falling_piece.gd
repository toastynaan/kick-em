extends Node3D
## Round 6 review (owner D): FallingPiece against clutter, where its blast goes,
## where floor marks may go, slow pieces, and the young-debris speed hold.
## 1. A 160 kg beam (a pillar's overhead piece) dropped from 4 m onto each kind
##    of K's clutter (Tuning.FURNITURE) breaks it through receive_impact
##    (GameEvents.furniture_broken names the beam as `by`) and falls on through.
## 2. A beam dropped from 4 m onto bare floor sets off exactly one &"structure"
##    blast, at the floor where it lands (power = its 1/2 m v^2), after the fall
##    and not before, and craters the floor there.
## 3. Marks go only on real floor: a beam landing on a concrete slab (a
##    breakable) or on rubble marks nothing; damage_floor in mid-air, on a
##    table top or on rubble returns 0; a body_impact on a body or on debris
##    marks nothing (one on concrete does).
## 4. A 77 kg piece rolling at 2.3 m/s into a standing fighter hurts nobody
##    (it arrives with more than Tuning.FALLING_HIT_ENERGY.x: the old rule
##    staggered); the same piece at 4.5 m/s hits.
## 5. A break's new piece (DebrisManager.hold_young) is held near the break's
##    speed for DebrisManager.YOUNG_TIME s: a 28 m/s solver spike on a 10 m/s
##    piece is cut to the cap; after that window nothing holds it. Only those:
##    a body only registered keeps a 28 m/s push; a break's piece launched
##    within 0.05 s by ThrownChunk.launch_body at 14 m/s keeps 14 m/s, and one
##    released (release_young) or frozen (picked up) is let go at once.

var _floor_events: Array = []
var _blasts: Array = []
var _broken: Array = []
var _ok := true
var _game := 0.0
## Speed of `_probe` sampled after DebrisManager's tick (this node runs after it).
var _probe: RigidBody3D = null
var _probe_speeds: Array[float] = []

func _physics_process(delta: float) -> void:
	_game += delta
	if _probe != null and is_instance_valid(_probe):
		_probe_speeds.append(_probe.linear_velocity.length())

func _ready() -> void:
	# After DebrisManager (50) and WorldDamage (90): samples see this tick's holds.
	process_physics_priority = 120
	GameEvents.floor_damaged.connect(func(p: Vector3, r: float, level: int, surface: StringName) -> void:
		_floor_events.append({"pos": p, "radius": r, "level": level, "surface": surface, "g": _game}))
	GameEvents.world_blast.connect(func(c: Vector3, r: float, power: float, source: StringName) -> void:
		_blasts.append({"center": c, "radius": r, "power": power, "source": source, "g": _game}))
	GameEvents.furniture_broken.connect(func(n: Node3D, _p: Vector3, kind: StringName, e: float, by: Node3D) -> void:
		_broken.append({"node": n, "kind": kind, "energy": e, "by": by}))
	WorldTestUtil.make_floor(self, 200.0)
	WorldDamage.reset()
	await get_tree().physics_frame
	await _clutter()
	await _clean_drop()
	await _not_floor()
	await _slow_roll()
	await _young_hold()
	WorldDamage.reset()
	DebrisManager.reset()
	print("[falling] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[falling] %s -> %s" % [s, "PASS" if ok else "FAIL"])

## A pillar's overhead piece: a 2.2 m beam of `mass` kg whose bottom is at `bottom`.
func _beam(bottom: Vector3, mass := 160.0) -> FallingPiece:
	var piece := FallingPiece.new()
	piece.mass = mass
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.2, 0.26, 0.22)
	cs.shape = box
	piece.add_child(cs)
	add_child(piece)
	piece.global_position = bottom + Vector3(0, 0.13, 0)
	piece.reset_physics_interpolation()
	DebrisManager.register(piece, false, -1.0, true)
	return piece

## 1. One beam over each kind of K's clutter, all at once, 7 m apart.
func _clutter() -> void:
	var rows: Array = []
	var all_ok := true
	var kinds: Array = Tuning.FURNITURE.keys()
	var items: Array = []
	for i in kinds.size():
		var at := Vector3(-35.0 + i * 7.0, 0.0, 30.0)
		var f := Furniture.create(kinds[i], Transform3D(Basis(), at))
		add_child(f)
		items.append([f, at])
	for i in 10:
		await get_tree().physics_frame
	var pieces: Array = []
	var outs := {}
	for it: Array in items:
		var b := _beam((it[1] as Vector3) + Vector3(0, 4.0, 0))
		var key := b.get_instance_id()
		outs[key] = []
		b.hit_breakable.connect(func(br: Node3D, e: float, out: StringName) -> void:
			(outs[key] as Array).append([br, e, out]))
		pieces.append(b)
	await WorldTestUtil.wait_game(self, 2.5)
	for i in items.size():
		var f: Furniture = items[i][0]
		var b: FallingPiece = pieces[i]
		var mine: Array = (outs[b.get_instance_id()] as Array).filter(func(x: Array) -> bool: return x[0] == f)
		var by_beam := _broken.filter(func(x: Dictionary) -> bool: return x["node"] == f and x["by"] == b).size() == 1
		var bottom := b.get_bounds().position.y
		var ok: bool = f.is_broken and mine.size() == 1 and mine[0][2] == &"break" and by_beam and bottom < 0.7 and b.has_landed
		rows.append("%s %s %.0f J (break %.0f) by beam=%s, beam landed=%s, bottom %.2f m" % [kinds[i],
			mine[0][2] if mine.size() > 0 else &"none", float(mine[0][1]) if mine.size() > 0 else 0.0,
			float(Tuning.FURNITURE[kinds[i]]["break"]), by_beam, b.has_landed, bottom])
		all_ok = all_ok and ok
	_line("160 kg beam from 4 m onto %d clutter kinds: %s" % [kinds.size(), rows], all_ok and kinds.size() >= 8)
	for b: FallingPiece in pieces:
		b.queue_free()
	for it: Array in items:
		if is_instance_valid(it[0]):
			(it[0] as Node).queue_free()
	await get_tree().physics_frame

## 2. A clean drop onto bare floor.
func _clean_drop() -> void:
	var at := Vector3(0.0, 0.0, -30.0)
	var n_b := _blasts.size()
	var n_f := _floor_events.size()
	var t0 := _game
	var b := _beam(at + Vector3(0, 4.0, 0))
	var land := {}
	b.landed_at.connect(func(p: Vector3, e: float, on_floor: bool) -> void:
		land.merge({"pos": p, "energy": e, "on_floor": on_floor, "g": _game}, true))
	await WorldTestUtil.wait_game(self, 2.0)
	var blasts := _blasts.slice(n_b).filter(func(x: Dictionary) -> bool: return x["source"] == &"structure")
	var marks := _floor_events.slice(n_f)
	var fall_t := sqrt(2.0 * 4.0 / 9.8)
	var ok: bool = not land.is_empty() and blasts.size() == 1 and not marks.is_empty()
	if ok:
		var c: Vector3 = blasts[0]["center"]
		var lp: Vector3 = land["pos"]
		ok = c.y < 0.05 and Vector2(c.x - at.x, c.z - at.z).length() < 0.5 and c.distance_to(lp) < 0.01 \
			and absf(float(blasts[0]["power"]) - float(land["energy"])) < 1.0 and float(blasts[0]["g"]) - t0 >= fall_t - 0.05 \
			and bool(land["on_floor"]) and (marks[0]["pos"] as Vector3).y < 0.05 and int(marks.back()["level"]) == 2 \
			and WorldDamage.floor_level_at(Vector3(lp.x, 0.0, lp.z)) == 2
	_line("160 kg beam from 4 m onto bare floor: landed %s; structure blasts %s; floor marks %s (want one blast at the floor after the %.2f s fall, power = its energy, a crater)" % [
		_fmt_land(land), blasts.map(func(x: Dictionary) -> String: return "at %s %.0f J after %.2f s" % [
			x["center"], x["power"], float(x["g"]) - t0]),
		marks.map(func(x: Dictionary) -> String: return "level %d at y %.2f" % [x["level"], (x["pos"] as Vector3).y]), fall_t], ok)
	b.queue_free()
	await get_tree().physics_frame

func _fmt_land(land: Dictionary) -> String:
	if land.is_empty():
		return "never"
	return "at %s, %.0f J, on floor=%s" % [land["pos"], land["energy"], land["on_floor"]]

## 3. Marks only on floor.
func _not_floor() -> void:
	# A beam onto a concrete slab (a breakable, 0.8 m tall) from 1.5 m above it.
	var slab := Destructible.new()
	slab.surface = &"concrete"
	slab.size = Vector3(3.0, 0.8, 1.4)
	slab.support_mask = PanelFracture.SIDE_BOTTOM
	slab.transform = Transform3D(Basis(), Vector3(30.0, 0.4, -30.0))
	add_child(slab)
	# Rubble: six 0.5 m concrete blocks on the floor.
	var rubble: Array[RigidBody3D] = []
	for i in 6:
		var r := RigidBody3D.new()
		r.mass = 40.0
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.5, 0.5, 0.5)
		cs.shape = box
		r.add_child(cs)
		r.set_meta(&"surface", &"concrete")
		add_child(r)
		r.global_position = Vector3(-30.25 + (i % 3) * 0.5, 0.25, -30.25 + (i / 3) * 0.5)
		DebrisManager.register(r, false, -1.0, true)
		rubble.append(r)
	# A table to read damage_floor on its top.
	var table := Furniture.create(&"table", Transform3D(Basis(), Vector3(-30.0, 0.0, 0.0)))
	add_child(table)
	await WorldTestUtil.wait_game(self, 1.0)
	var n_f := _floor_events.size()
	var n_b := _blasts.size()
	var on_slab := _beam(Vector3(30.0, 0.8 + 1.5, -30.0))
	var on_rubble := _beam(Vector3(-30.0, 0.5 + 2.5, -30.0))
	var lands := {}
	for b: FallingPiece in [on_slab, on_rubble]:
		var key := b.get_instance_id()
		b.landed_at.connect(func(p: Vector3, e: float, on_floor: bool) -> void:
			lands[key] = {"pos": p, "energy": e, "on_floor": on_floor})
	await WorldTestUtil.wait_game(self, 2.0)
	var marks := _floor_events.slice(n_f)
	var blasts := _blasts.slice(n_b).filter(func(x: Dictionary) -> bool: return x["source"] == &"structure")
	var ls: Dictionary = lands.get(on_slab.get_instance_id(), {})
	var lr: Dictionary = lands.get(on_rubble.get_instance_id(), {})
	_line("beam onto a concrete slab: landed %s (slab broken=%s); beam onto rubble: landed %s; structure blasts %d; floor marks %s (want none)" % [
		_fmt_land(ls), slab.is_broken, _fmt_land(lr), blasts.size(), marks.map(func(x: Dictionary) -> String:
			return "level %d at %s" % [x["level"], x["pos"]])],
		not ls.is_empty() and not bool(ls["on_floor"]) and (ls["pos"] as Vector3).y > 0.7 and not lr.is_empty() \
		and not bool(lr["on_floor"]) and (lr["pos"] as Vector3).y > 0.3 and marks.is_empty() and blasts.size() == 2)
	on_slab.queue_free()
	on_rubble.queue_free()
	await get_tree().physics_frame
	# Direct calls.
	n_f = _floor_events.size()
	var top := ImpactResolver.box_of(table)
	var top_y: float = ((top[0] as Transform3D).origin + (top[0] as Transform3D).basis.y * (top[1] as Vector3).y).y
	var block: RigidBody3D = rubble[0]
	var mid_air := WorldDamage.damage_floor(Vector3(10.0, 2.43, 10.0), 3000.0)
	var on_table := WorldDamage.damage_floor(Vector3(-30.0, top_y + 0.01, 0.0), 3000.0)
	var on_block := WorldDamage.damage_floor(block.global_position + Vector3(0, 0.26, 0), 3000.0)
	var on_floor := WorldDamage.damage_floor(Vector3(10.0, 0.02, 10.0), 3000.0)
	var direct := _floor_events.slice(n_f)
	_line("damage_floor 3,000 J: mid-air (y 2.43) -> %d, table top (y %.2f) -> %d, rubble top -> %d, floor -> %d; floor_damaged %d (want 0, 0, 0, 1, one event)" % [
		mid_air, top_y, on_table, on_block, on_floor, direct.size()],
		mid_air == 0 and on_table == 0 and on_block == 0 and on_floor == 1 and direct.size() == 1)
	# body_impact on a body, on debris, on concrete.
	n_f = _floor_events.size()
	WorldDamage.reset()
	GameEvents.body_impact.emit(null, Vector3(14.0, 0.0, 14.0), Vector3.UP, 3000.0, &"body")
	GameEvents.body_impact.emit(null, Vector3(18.0, 0.0, 14.0), Vector3.UP, 3000.0, &"debris")
	GameEvents.body_impact.emit(null, Vector3(22.0, 0.0, 14.0), Vector3.UP, 3000.0, &"concrete")
	var imp := _floor_events.slice(n_f)
	_line("body_impact 3,000 J on a body / debris / concrete: floor_damaged at x %s (want only x 22)" % [
		imp.map(func(x: Dictionary) -> float: return snappedf((x["pos"] as Vector3).x, 0.1))],
		imp.size() == 1 and absf((imp[0]["pos"] as Vector3).x - 22.0) < 0.5)
	slab.queue_free()
	table.queue_free()
	for r in rubble:
		r.queue_free()
	await get_tree().physics_frame

## 4. A 77 kg ball rolling into a standing fighter: slow, then fast.
func _slow_roll() -> void:
	var rows: Array = []
	var res := {}
	for speed: float in [2.3, 4.5]:
		var z := 50.0 if speed < 3.0 else 56.0
		var f := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis.looking_at(Vector3.LEFT, Vector3.UP),
			Vector3(0.0, 0.05, z)), Fighter.TEAM_ENEMY)
		f.max_hp = 500.0
		f.hp = 500.0
		await WorldTestUtil.wait_game(self, 0.3)
		var ball := FallingPiece.new()
		ball.mass = 77.0
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 0.35
		cs.shape = sph
		ball.add_child(cs)
		add_child(ball)
		ball.global_position = Vector3(-1.6, 0.36, z)
		ball.reset_physics_interpolation()
		ball.linear_velocity = Vector3(speed, 0, 0)
		ball.angular_velocity = Vector3(0, 0, -speed / 0.35)
		DebrisManager.register(ball, false, -1.0, true)
		var hits := {"n": 0, "e": 0.0}
		ball.hit_fighter.connect(func(_f: Node3D, e: float, _t: int) -> void:
			hits["n"] = int(hits["n"]) + 1
			hits["e"] = e)
		var closest := 99.0
		var at_contact := 0.0
		var arrive := -1.0
		var t := 0.0
		while t < 1.2:
			await get_tree().physics_frame
			t += 1.0 / 120.0
			var d := Vector2(ball.global_position.x - f.global_position.x, ball.global_position.z - f.global_position.z).length()
			if d < closest:
				closest = d
				at_contact = ball.linear_velocity.length()
			if d < 0.8 and arrive < 0.0:
				arrive = ball.linear_velocity.length()
		res[speed] = {"hits": hits["n"], "hp": f.hp, "arrive_e": 0.5 * 77.0 * arrive * arrive}
		rows.append("%.1f m/s: arrives at %.2f m/s (%.0f J), closest %.2f m from the fighter (%.1f m/s), hits %d (%.0f J), hp %.0f" % [
			speed, arrive, 0.5 * 77.0 * arrive * arrive, closest, at_contact, hits["n"], hits["e"], f.hp])
		res[speed]["closest"] = closest
		ball.queue_free()
		f.queue_free()
		await get_tree().physics_frame
	var slow: Dictionary = res[2.3]
	var fast: Dictionary = res[4.5]
	_line("77 kg ball rolling into a fighter: %s (want none slow, a hit fast; hits only when falling faster than %.0f m/s or moving %.0f m/s)" % [
		rows, FallingPiece.HIT_FALL_SPEED, FallingPiece.HIT_MIN_SPEED],
		int(slow["hits"]) == 0 and float(slow["hp"]) == 500.0 and float(slow["closest"]) < 0.8 \
		and float(slow["arrive_e"]) >= Tuning.FALLING_HIT_ENERGY.x and int(fast["hits"]) == 1)

## 5. The young-debris hold.
func _young_hold() -> void:
	var cap := maxf(10.0 * DebrisManager.YOUNG_SHARE, 10.0 + DebrisManager.YOUNG_ALLOW)
	# A break's piece at 10 m/s, then a solver spike.
	var b := _chunk(Vector3(40.0, 3.0, 40.0), Vector3(10.0, 0.0, 0.0), 10.0)
	await get_tree().physics_frame
	var held := await _push(b, Vector3(28.0, 0.0, 0.0))
	await WorldTestUtil.wait_game(self, DebrisManager.YOUNG_TIME + 0.05)
	var later := await _push(b, Vector3(28.0, 0.0, 0.0))
	_line("a break's 10 m/s piece hit by a 28 m/s spike: %.1f m/s after DebrisManager's tick (cap %.1f); %.2f s later the same spike stays %.1f m/s" % [
		held, cap, DebrisManager.YOUNG_TIME + 0.05, later], held > 0.0 and held <= cap + 0.1 and later > 25.0)
	b.queue_free()
	# A body only registered (no break): never held.
	var plain := _chunk(Vector3(40.0, 3.0, 44.0), Vector3(10.0, 0.0, 0.0), -1.0)
	await get_tree().physics_frame
	var plain_v := await _push(plain, Vector3(28.0, 0.0, 0.0))
	_line("a body only registered, pushed to 28 m/s at once: %.1f m/s (held=%s)" % [plain_v,
		DebrisManager.is_held_young(plain)], plain_v > 25.0 and not DebrisManager.is_held_young(plain))
	plain.queue_free()
	# A break's piece launched by ThrownChunk 0.04 s after it appeared.
	var chunk := _chunk(Vector3(40.0, 1.5, 48.0), Vector3(2.0, 1.0, 0.0), 6.0)
	await WorldTestUtil.wait_game(self, 0.04)
	var held_before := DebrisManager.is_held_young(chunk)
	ThrownChunk.launch_body(chunk, Vector3(14.0, 0.0, 0.0), null, 0.0)
	_probe_speeds.clear()
	_probe = chunk
	for i in 6:
		await get_tree().physics_frame
	_probe = null
	var launched := _probe_speeds.duplicate()
	_line("a break's piece (held=%s) launched by ThrownChunk.launch_body at 14 m/s 0.04 s after it appeared: speeds after DebrisManager's tick %s (want 14 kept; cap was %.1f), held after=%s" % [
		held_before, launched.map(func(x: float) -> float: return snappedf(x, 0.01)),
		maxf(6.0 * DebrisManager.YOUNG_SHARE, 6.0 + DebrisManager.YOUNG_ALLOW), DebrisManager.is_held_young(chunk)],
		held_before and launched.size() == 6 and launched.all(func(x: float) -> bool: return x >= 13.9) \
		and not DebrisManager.is_held_young(chunk))
	chunk.queue_free()
	# Released by hand, or frozen (picked up): let go at once.
	var r1 := _chunk(Vector3(44.0, 3.0, 40.0), Vector3(4.0, 0.0, 0.0), 4.0)
	var r2 := _chunk(Vector3(44.0, 3.0, 44.0), Vector3(4.0, 0.0, 0.0), 4.0)
	await get_tree().physics_frame
	DebrisManager.release_young(r1)
	r2.freeze = true
	await get_tree().physics_frame
	r2.freeze = false
	var r1_v := await _push(r1, Vector3(20.0, 0.0, 0.0))
	var r2_v := await _push(r2, Vector3(20.0, 0.0, 0.0))
	_line("a break's 4 m/s piece released (release_young) / frozen once (picked up), then pushed to 20 m/s: %.1f / %.1f m/s (cap was %.1f)" % [
		r1_v, r2_v, maxf(4.0 * DebrisManager.YOUNG_SHARE, 4.0 + DebrisManager.YOUNG_ALLOW)], r1_v > 19.0 and r2_v > 19.0)
	r1.queue_free()
	r2.queue_free()

## A 20 kg debris box at `at` moving at `v`, registered; with ref_speed >= 0 a
## break's piece (DebrisManager.hold_young).
func _chunk(at: Vector3, v: Vector3, ref_speed: float) -> RigidBody3D:
	var b := RigidBody3D.new()
	b.mass = 20.0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.4, 0.4, 0.4)
	cs.shape = box
	b.add_child(cs)
	add_child(b)
	b.global_position = at
	b.linear_velocity = v
	DebrisManager.register(b, false, -1.0, true)
	if ref_speed >= 0.0:
		DebrisManager.hold_young(b, ref_speed)
	return b

## Set `b` to `v` at the start of a tick; its speed after DebrisManager's tick.
func _push(b: RigidBody3D, v: Vector3) -> float:
	_probe_speeds.clear()
	_probe = b
	b.linear_velocity = v
	await get_tree().physics_frame
	_probe = null
	return _probe_speeds[0] if not _probe_speeds.is_empty() else -1.0
