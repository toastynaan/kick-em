extends Node3D
## Round 5 "Things stay" (Feel Reference: On the world, Sifu 3 at 33.3-35.7 s;
## F11, owner D, with J's end-of-wave counts). In the real Yard:
## 1. A body launched into a courtyard crate (the north pair's east one, from
##    the east) breaks it (furniture breaks when a body is thrown or launched
##    into it); the flyer takes Round 6's Tuning.FURNITURE_BODY_DAMAGE
##    (furniture is not a wall).
## 2. A body launched into the west facade opens a hole.
## 3. 35 s later (past every old debris lifetime) the crate's pieces and the
##    wall's chunks are all still there, frozen, and the hole is still open.
## 4. DebrisManager.get_world_counts() reports the broken furniture, the wall
##    hole and the debris; reset() starts the next round at zero.

var _decisions: Array = []
var _ok := true
## Everything that broke and is not a wall, as the world reported it: K's
## clutter (GameEvents.furniture_broken) and D's props and door frames
## (wall_broken from a Destructible that is not a panel).
var _broken_things := {}

func _ready() -> void:
	ImpactResolver.wall_decided.connect(func(f: Node3D, w: Node3D, outcome: StringName, e: float, _p: Vector3) -> void:
		_decisions.append({"fighter": f, "wall": w, "outcome": outcome, "energy": e}))
	GameEvents.furniture_broken.connect(func(n: Node3D, _p: Vector3, _k: StringName, _e: float, _by: Node3D) -> void:
		_broken_things[n.get_instance_id()] = true)
	GameEvents.wall_broken.connect(func(w: Node3D, _p: Vector3, _e: float, _v: Vector3) -> void:
		if w is Destructible and (w as Destructible).kind != &"panel" and (w as Destructible).is_broken:
			_broken_things[w.get_instance_id()] = true)
	var yard := YardBuilder.new()
	add_child(yard)
	yard.build()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var base := DebrisManager.get_world_counts()

	# 1. A crate in the courtyard (the one at (3.2, -6.6)) from the east at 9 m/s.
	var crate: Destructible = null
	for d: Destructible in yard.get_parkour_features()["crates"]:
		if d.global_position.distance_to(Vector3(3.2, 0.55, -6.6)) < 0.3:
			crate = d
	var f := await _body(Vector3(4.9, 0, -6.6))
	var hp0 := f.hp
	f.launch(Vector3(-9, 1.2, 0), f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 0.8)
	var dc := _decisions.filter(func(x: Dictionary) -> bool: return x["wall"] == crate)
	var crate_pieces: Array = crate.last_chunks.duplicate() if crate else []
	# The flyer's damage is what it broke: the crate (furniture, 5) plus any
	# clutter it ploughs on through (K's), each by ImpactResolver.break_damage.
	var want := _owed(f)
	var c_ok: bool = crate != null and crate.is_broken and dc.size() >= 1 and dc[0]["outcome"] == &"break" \
		and absf(ImpactResolver.break_damage(crate) - Tuning.FURNITURE_BODY_DAMAGE) < 0.01 \
		and absf(hp0 - f.hp - want) < 0.01 and crate_pieces.size() >= 4
	_line("body at 9 m/s into a courtyard crate: %s E=%s, %d pieces, crate costs %.0f (FURNITURE_BODY_DAMAGE), flyer damage %.0f for everything it broke %s (want %.0f)" % [
		dc[0]["outcome"] if dc.size() > 0 else &"none", dc.map(func(x: Dictionary) -> int: return int(x["energy"])),
		crate_pieces.size(), ImpactResolver.break_damage(crate) if crate else -1.0, hp0 - f.hp,
		_decisions.filter(func(x: Dictionary) -> bool: return x["fighter"] == f and x["outcome"] != &"bounce").map(
			func(x: Dictionary) -> String: return "%s %s" % [(x["wall"] as Node).name, x["outcome"]]), want], c_ok)
	f.queue_free()

	# 2. The west facade panel at z = 3 from the courtyard at 10 m/s.
	var panel: Destructible = null
	for d in yard.get_destructibles():
		if d.kind == &"panel" and d.global_position.distance_to(Vector3(-11.125, 1.5, 3.0)) < 0.1:
			panel = d
	f = await _body(Vector3(-9.4, 0, 3.0))
	f.launch(Vector3(-10, 1.4, 0), f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 0.8)
	var dp := _decisions.filter(func(x: Dictionary) -> bool: return x["wall"] == panel)
	var hole_at := panel.global_position + Vector3(0.0, -0.3, 0.0) if panel else Vector3.ZERO
	var wall_pieces: Array = panel.last_chunks.duplicate() if panel else []
	var p_ok: bool = panel != null and dp.size() >= 1 and dp[0]["outcome"] == &"break" and panel.is_point_open(hole_at)
	_line("body at 10 m/s into the west facade: %s, hole open=%s, %d chunks" % [
		dp[0]["outcome"] if dp.size() > 0 else &"none", panel.is_point_open(hole_at) if panel else false,
		wall_pieces.size()], p_ok)
	f.queue_free()

	# 3. 35 s later.
	await WorldTestUtil.wait_game(self, 35.0)
	var alive := func(arr: Array) -> int:
		return arr.filter(func(b: Variant) -> bool: return is_instance_valid(b) and not (b as Node).is_queued_for_deletion() \
			and (b as CollisionObject3D).collision_layer != 0).size()
	var frozen := crate_pieces.filter(func(b: Variant) -> bool: return is_instance_valid(b) and DebrisManager.is_frozen(b)).size()
	var stay_ok: bool = alive.call(crate_pieces) == crate_pieces.size() and alive.call(wall_pieces) == wall_pieces.size() \
		and panel.is_point_open(hole_at) and frozen >= crate_pieces.size() - 1
	_line("after 35 s: crate pieces %d/%d (frozen %d), wall chunks %d/%d, hole still open=%s" % [
		alive.call(crate_pieces), crate_pieces.size(), frozen, alive.call(wall_pieces), wall_pieces.size(),
		panel.is_point_open(hole_at)], stay_ok)

	# 4. Counts.
	var counts := DebrisManager.get_world_counts()
	# Panels that broke (the 10 m/s body may cross the office and hole the inner wall too).
	var holed := {}
	for d: Dictionary in _decisions:
		if d["outcome"] == &"break" and d["wall"] is Destructible and (d["wall"] as Destructible).kind == &"panel":
			holed[d["wall"]] = true
	# The broken-furniture count is everything non-wall the world reported broken
	# (the crate, plus any of K's clutter the bodies or the blasts broke).
	var n_ok: bool = int(counts["furniture_broken"]) - int(base["furniture_broken"]) == _broken_things.size() \
		and _broken_things.has(crate.get_instance_id()) \
		and int(counts["wall_holes"]) - int(base["wall_holes"]) == holed.size() and holed.size() >= 1 \
		and int(counts["debris"]) >= crate_pieces.size() + wall_pieces.size()
	_line("world counts %s (before the fight %s; panels broken %d; non-wall things reported broken %d)" % [
		counts, base, holed.size(), _broken_things.size()], n_ok)
	yard.queue_free()
	DebrisManager.reset()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var after := DebrisManager.get_world_counts()
	_line("next round starts at %s" % after, int(after["debris"]) == 0 and int(after["props_broken"]) == 0)
	print("[stay] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

## Damage a flyer should have taken from its wall decisions: each break by
## ImpactResolver.break_damage, each crack of a wall Tuning.WALL_DAMAGE.crack.
func _owed(f: Node3D) -> float:
	var total := 0.0
	for d: Dictionary in _decisions:
		if d["fighter"] != f or not is_instance_valid(d["wall"]):
			continue
		if d["outcome"] == &"break":
			total += ImpactResolver.break_damage(d["wall"])
		elif d["outcome"] == &"crack" and ImpactResolver.is_wall(d["wall"]):
			total += Tuning.WALL_DAMAGE[&"crack"]
	return total

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[stay] %s -> %s" % [s, "PASS" if ok else "FAIL"])

## 70 kg dummy (lots of HP) whose COM sits at `com_xz`.
func _body(com_xz: Vector3) -> Fighter:
	var f := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, -PI * 0.5), com_xz + Vector3(0, 0.05, 0)),
		false, &"player")
	f.max_hp = 1000.0
	f.hp = 1000.0
	await get_tree().physics_frame
	await get_tree().physics_frame
	var c := f.get_center_of_mass()
	f.global_position += Vector3(com_xz.x - c.x, 0, com_xz.z - c.z)
	f.reset_physics_interpolation()
	await get_tree().physics_frame
	return f
