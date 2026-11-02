extends Node3D
## Round 6 floor and impact damage (docs/ARCHITECTURE.md Round 6 check, owner D;
## the marks themselves are drawn by F). Real landings: the player (with M's
## Traversal) dropped from a height lands soft, hard or heavy and emits
## GameEvents.landing; WorldDamage takes it from there.
## 1. A soft landing (1 m drop) marks nothing.
## 2. A hard landing (2.6 m drop, ~9 m/s, 1/2 M v^2 ~ 2,800 J) cracks (level 1);
##    a second hard landing on the same spot makes it a crater (level 2).
## 3. A slam (an air attack from over 2 m) craters at once (exactly level 2:
##    one impact, one mark), and its blast shatters a glass pane 2.0 m away (not
##    one 3.2 m away) and hops a brick.
## 3b. A real carry body slam (G's Carry: grab, a normal jump, Light in the air)
##    is one crater: exactly one floor mark, level 2 (the landing, body_slammed
##    and the victim's own floor impact are one impact), and its blast breaks
##    K's glass (Furniture &"glass") 1.8 m away.
## 4. A launched body slammed into the floor marks it (body_impact).
## 5. The tiled plaza: a hard landing on it pops tiles as persistent pieces
##    (surface &"tile"), and floor_damaged reports &"tile".
## 6. Marks and counts persist (get_floor_counts unchanged 10 s on); reset()
##    clears them.

var _floor_events: Array = []
var _blasts: Array = []
var _landings: Array = []
var _ok := true

func _ready() -> void:
	GameEvents.floor_damaged.connect(func(p: Vector3, r: float, level: int, surface: StringName) -> void:
		_floor_events.append({"pos": p, "radius": r, "level": level, "surface": surface}))
	GameEvents.world_blast.connect(func(c: Vector3, r: float, power: float, source: StringName) -> void:
		_blasts.append({"center": c, "radius": r, "power": power, "source": source}))
	GameEvents.landing.connect(func(f: Node3D, level: StringName, p: Vector3, v: float) -> void:
		_landings.append({"fighter": f, "level": level, "pos": p, "v": v}))
	WorldTestUtil.make_floor(self, 200.0)
	WorldDamage.reset()
	await get_tree().physics_frame
	var plaza := TilePlaza.new()
	add_child(plaza)
	plaza.build(Rect2(20.0, -2.0, 3.5, 4.0), 0.5, 0.004)
	var p := FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	p.max_hp = 1000.0
	p.hp = 1000.0
	for i in 30:
		await get_tree().physics_frame

	# 1. Soft landing.
	var r := await _drop(p, Vector3(0, 0, 0), 1.0, false)
	_line("soft landing (1 m): %s at %.1f m/s -> floor level %d, marks %d" % [r["level"], r["v"], r["floor"], r["marks"]],
		r["level"] == &"soft" and r["floor"] == 0 and r["marks"] == 0)
	# 2. Hard landing, then a second one on the same spot.
	r = await _drop(p, Vector3(5, 0, 0), 2.6, false)
	var e1 := 0.5 * p.get_total_mass() * float(r["v"]) * float(r["v"])
	var lvl1: int = r["floor"]
	_line("hard landing (2.6 m): %s at %.1f m/s (%.0f J) -> floor level %d (crack)" % [r["level"], r["v"], e1, lvl1],
		r["level"] == &"hard" and lvl1 == 1)
	r = await _drop(p, Vector3(5, 0, 0), 2.6, false)
	_line("a second hard landing on the same spot: %s at %.1f m/s -> floor level %d (crater from %.0f J total)" % [
		r["level"], r["v"], r["floor"], Tuning.FLOOR_LEVEL_ENERGY[1]], r["level"] == &"hard" and r["floor"] == 2)

	# 3. A slam next to two glass panes and a brick.
	var slam_at := Vector3(-8, 0, 0)
	var near_glass := _glass(slam_at + Vector3(0, 0, 2.0))
	var far_glass := _glass(slam_at + Vector3(0, 0, -3.2))
	var brick := ThrowableProp.spawn(self, &"brick", Transform3D(Basis(), slam_at + Vector3(1.5, 0.05, 0)))
	for i in 20:
		await get_tree().physics_frame
	var hop := {"vy": 0.0}
	var watch := func() -> void:
		if is_instance_valid(brick):
			hop["vy"] = maxf(float(hop["vy"]), brick.linear_velocity.y)
	get_tree().physics_frame.connect(watch)
	_blasts.clear()
	r = await _drop(p, slam_at, 3.5, true)
	await WorldTestUtil.wait_game(self, 0.3)
	get_tree().physics_frame.disconnect(watch)
	var slam_blasts := _blasts.filter(func(b: Dictionary) -> bool: return (b["center"] as Vector3).distance_to(slam_at) < 1.0)
	_line("slam (3.5 m drop): %s at %.1f m/s -> floor level %d (crater); blasts %s; glass at 2.0 m shattered=%s, glass at 3.2 m shattered=%s; brick at 1.5 m hopped at %.2f m/s" % [
		r["level"], r["v"], r["floor"], slam_blasts.map(func(b: Dictionary) -> String: return "%s %.1f m %.0f J" % [b["source"],
			b["radius"], b["power"]]), near_glass.is_broken, far_glass.is_broken, hop["vy"]],
		r["level"] == &"heavy" and r["floor"] == 2 and slam_blasts.size() == 1 and near_glass.is_broken \
		and not far_glass.is_broken and float(hop["vy"]) > 0.5)

	# 3b. A real carry body slam.
	await _carry_slam(p)

	# 4. A launched body slammed down into the floor.
	var body := WorldTestUtil.spawn_body(self, Transform3D(Basis(), Vector3(-15, 0.05, 10)), false, &"player")
	for i in 4:
		await get_tree().physics_frame
	body.launch(Vector3(0, 5, 0), body.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 0.25)
	var n0 := _floor_events.size()
	body.launch(Vector3(0, -13, 0), body.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 0.8)
	var body_marks := _floor_events.slice(n0)
	_line("a body slammed into the floor: floor_damaged %s" % [body_marks.map(func(e: Dictionary) -> String:
		return "level %d %s" % [e["level"], e["surface"]])], body_marks.size() >= 1)
	body.queue_free()
	ImpactResolver.reset()

	# 5. The tiled plaza.
	var debris0 := DebrisManager.count_debris()
	n0 = _floor_events.size()
	r = await _drop(p, Vector3(21.75, 0, 0), 2.6, false)
	var tile_marks := _floor_events.slice(n0).filter(func(e: Dictionary) -> bool: return e["surface"] == &"tile")
	var tiles: Array = get_tree().get_nodes_in_group(&"debris").filter(func(b: Node) -> bool:
		return b.get_meta(&"surface", &"") == &"tile")
	_line("hard landing on the plaza: %d of %d tiles popped (TILE_BREAK_ENERGY %.0f J), %d tile pieces (surface tile) in DebrisManager (debris %d -> %d), floor_damaged on tile %d" % [
		plaza.popped_count, plaza.get_tile_count(), Tuning.TILE_BREAK_ENERGY, tiles.size(), debris0, DebrisManager.count_debris(),
		tile_marks.size()], plaza.popped_count >= 1 and tiles.size() == plaza.popped_count and tile_marks.size() >= 1)

	# 6. Persistence and reset.
	var counts := WorldDamage.get_floor_counts()
	await WorldTestUtil.wait_game(self, 10.0)
	var later := WorldDamage.get_floor_counts()
	var tiles_left: int = get_tree().get_nodes_in_group(&"debris").filter(func(b: Node) -> bool:
		return b.get_meta(&"surface", &"") == &"tile" and not b.is_queued_for_deletion()).size()
	WorldDamage.reset()
	var after := WorldDamage.get_floor_counts()
	_line("counts %s, 10 s later %s, tile pieces still there %d; after reset() %s" % [counts, later, tiles_left, after],
		counts == later and int(counts["cracks"]) + int(counts["craters"]) >= 3 and tiles_left == tiles.size() \
		and int(after["cracks"]) == 0 and int(after["craters"]) == 0)
	print("[floor] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[floor] %s -> %s" % [s, "PASS" if ok else "FAIL"])

## A glass pane (Destructible, surface &"glass") standing at `at`.
func _glass(at: Vector3) -> Destructible:
	var d := Destructible.new()
	d.surface = &"glass"
	d.size = Vector3(1.2, 1.6, 0.03)
	d.support_mask = PanelFracture.SIDE_BOTTOM
	d.transform = Transform3D(Basis(), at + Vector3(0, 0.8, 0))
	add_child(d)
	return d

## Drop the player from `height` m over `at` (Traversal lands it); slam: an air
## attack from over 2 m. Returns {"level", "v", "floor" (level there), "marks"}.
func _drop(p: Fighter, at: Vector3, height: float, slam: bool) -> Dictionary:
	_landings.clear()
	var n0 := _floor_events.size()
	p.velocity = Vector3.ZERO
	p.global_position = at + Vector3(0, height, 0)
	p.reset_physics_interpolation()
	var t := 0.0
	var slammed := false
	while _landings.is_empty() and t < 3.0:
		await get_tree().physics_frame
		t += 1.0 / 120.0
		if slam and not slammed and p.velocity.y < -1.0 and p.global_position.y > 2.05:
			slammed = p.traversal.begin_drop_strike()
	await WorldTestUtil.wait_game(self, 0.1)
	var land: Dictionary = _landings[0] if not _landings.is_empty() else {"level": &"none", "v": 0.0}
	var res := {"level": land["level"], "v": land["v"], "floor": WorldDamage.floor_level_at(at),
		"marks": _floor_events.size() - n0}
	await WorldTestUtil.wait_game(self, 0.6)
	return res

## 3b. The player grabs a grunt (G's Carry), jumps (a normal jump) and presses
## Light in the air: a body slam. K's glass stands 1.8 m to the side.
func _carry_slam(p: Fighter) -> void:
	Carry.force_enabled = true
	var at := Vector3(0.0, 0.0, 12.0)
	p.velocity = Vector3.ZERO
	p.global_transform = Transform3D(Basis.looking_at(Vector3.FORWARD, Vector3.UP), at + Vector3(0, 0.05, 0))
	p.reset_physics_interpolation()
	var glass := Furniture.create(&"glass", Transform3D(Basis(Vector3.UP, PI * 0.5), at + Vector3(1.8, 0.0, 0.3)))
	add_child(glass)
	var e := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis.looking_at(Vector3.BACK, Vector3.UP),
		at + Vector3(0.0, 0.05, -1.0)), Fighter.TEAM_ENEMY)
	e.max_hp = 1000.0
	e.hp = 1000.0
	await WorldTestUtil.wait_game(self, 0.2)
	var slams: Array = []
	var on_slam := func(h: Node3D, v: Node3D, pos: Vector3) -> void: slams.append([h, v, pos])
	GameEvents.body_slammed.connect(on_slam)
	var reached: Array = []
	var on_blast := func(c: Vector3, _r: float, _pw: float, source: StringName, hit: Array) -> void:
		for x: Array in hit:
			if x[0] == glass:
				reached.append("%s %.0f J -> %s" % [source, x[1], x[2]])
	WorldDamage.blasted.connect(on_blast)
	var held := p.carry.grab_now(e, &"", true)
	await WorldTestUtil.wait_game(self, 0.35)
	var n0 := _floor_events.size()
	var cells0 := WorldDamage.get_floor_counts()
	var jumped := p.traversal.on_jump_pressed()
	await WorldTestUtil.wait_game(self, 0.18)
	p.combat.press(CombatController.Action.LIGHT)
	await WorldTestUtil.wait_game(self, 0.03)
	var slamming := p.carry.is_slamming()
	p.combat.release(CombatController.Action.LIGHT)
	var t := 0.0
	while slams.is_empty() and t < 1.5:
		await get_tree().physics_frame
		t += 1.0 / 120.0
	await WorldTestUtil.wait_game(self, 1.0)
	GameEvents.body_slammed.disconnect(on_slam)
	WorldDamage.blasted.disconnect(on_blast)
	var marks := _floor_events.slice(n0)
	var cells := WorldDamage.get_floor_counts()
	var pos: Vector3 = slams[0][2] if not slams.is_empty() else at
	var e_slam := 0.5 * (p.get_total_mass() + e.get_total_mass()) * WorldDamage.SLAM_SPEED * WorldDamage.SLAM_SPEED
	var new_craters := int(cells["craters"]) - int(cells0["craters"])
	var new_cracks := int(cells["cracks"]) - int(cells0["cracks"])
	var new_rubble := int(cells["rubble"]) - int(cells0["rubble"])
	var glass_by_blast := reached.filter(func(x: String) -> bool: return x.ends_with("break")).size() >= 1
	_line("carry body slam (grab=%s, jump=%s, slamming=%s, body_slammed %d at %s, %.0f J): floor_damaged %s; new cells: %d cracks, %d craters, %d rubble; floor level there %d; K's glass at 1.8 m: %s, broken=%s" % [
		held, jumped, slamming, slams.size(), pos, e_slam, marks.map(func(x: Dictionary) -> String: return "level %d at %s" % [
			x["level"], x["pos"]]), new_cracks, new_craters, new_rubble, WorldDamage.floor_level_at(pos), reached,
		glass.is_broken],
		held and jumped and slamming and slams.size() == 1 and marks.size() == 1 and int(marks[0]["level"]) == 2 \
		and new_craters == 1 and new_cracks == 0 and new_rubble == 0 and WorldDamage.floor_level_at(pos) == 2 \
		and glass.is_broken and glass_by_blast)
	Carry.force_enabled = false
	e.queue_free()
	if is_instance_valid(glass):
		glass.queue_free()
	p.velocity = Vector3.ZERO
	await WorldTestUtil.wait_game(self, 0.5)
