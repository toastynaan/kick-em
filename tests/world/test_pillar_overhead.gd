extends Node3D
## Round 6 "pillars hold something" (docs/ARCHITECTURE.md Round 6 check, owner D),
## in the real Yard:
## 1. Every pillar holds an overhead piece (a steel beam with a hanging sign)
##    of at least Tuning.FALLING_MIN_MASS.
## 2. Real 18 m/s bodies snap a pillar (crack, then break), launched 1 m off
##    its face so they arrive at full speed; each decision is checked against
##    the rule at the energy it arrived with (break from the pillar's break
##    energy at that moment, crack from its crack threshold), and a body that
##    arrived a little slow is followed by another (at most 4). The piece
##    creaks at once (structure_collapsed &"overhead") and drops
##    Tuning.PILLAR_COLLAPSE_DELAY s (game time) later: its height is printed
##    every 0.25 s and must fall from ~4 m to the floor.
## 3. It knocks down the fighter standing under its inner end, through the hit
##    pipeline (kind &"debris", knockdown tier, Tuning.FALLING_DAMAGE): an enemy
##    at one pillar, the player at another.
## 4. It lands, stays (8 s later, still there), and freezes like debris.
## 5. Round 6 review: the overhead piece's &"structure" blast goes off where it
##    lands (under 1 m, after the drop), never at creak time at beam height; no
##    new piece of the snap leaves faster than 1.2x the 18 m/s body while young
##    (DebrisManager's young hold; raw solver speeds printed).

var yard: YardBuilder
var _decisions: Array = []
var _collapses: Array = []
var _hits: Array[HitInfo] = []
var _game := 0.0
var _ok := true
## The pillar being snapped and the game time its overhead piece first appeared.
var _watch: Pillar = null
var _dropped_g := -1.0
var _blasts: Array = []
## The overhead piece's landing (FallingPiece.landed_at).
var _head_land := {}
## Debris registered during a snap: [body, game time registered]; the fastest
## young speed seen before and after DebrisManager's hold.
var _young: Array = []
var _young_raw := 0.0
var _young_held := 0.0

func _physics_process(delta: float) -> void:
	_game += delta
	# This node runs after DebrisManager (process_physics_priority 60 > 50).
	for y: Array in _young:
		if is_instance_valid(y[0]) and _game - float(y[1]) <= DebrisManager.YOUNG_TIME:
			_young_held = maxf(_young_held, (y[0] as RigidBody3D).linear_velocity.length())
	if _watch != null and _dropped_g < 0.0 and is_instance_valid(_watch) and _watch.fallen_head != null:
		_dropped_g = _game
		_watch.fallen_head.landed_at.connect(func(p: Vector3, e: float, on_floor: bool) -> void:
			_head_land.merge({"pos": p, "energy": e, "on_floor": on_floor, "g": _game}, true))

func _ready() -> void:
	process_physics_priority = 60
	get_tree().physics_frame.connect(func() -> void:
		for y: Array in _young:
			if is_instance_valid(y[0]) and _game - float(y[1]) <= DebrisManager.YOUNG_TIME:
				_young_raw = maxf(_young_raw, (y[0] as RigidBody3D).linear_velocity.length()))
	DebrisManager.body_registered.connect(func(b: RigidBody3D) -> void: _young.append([b, _game]))
	GameEvents.world_blast.connect(func(c: Vector3, r: float, power: float, source: StringName) -> void:
		_blasts.append({"center": c, "radius": r, "power": power, "source": source, "g": _game}))
	ImpactResolver.wall_decided.connect(func(f: Node3D, w: Node3D, outcome: StringName, e: float, _p: Vector3) -> void:
		_decisions.append({"fighter": f, "wall": w, "outcome": outcome, "energy": e, "g": _game}))
	GameEvents.structure_collapsed.connect(func(n: Node3D, p: Vector3, kind: StringName) -> void:
		_collapses.append({"node": n, "pos": p, "kind": kind, "g": _game}))
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void: _hits.append(info))
	yard = YardBuilder.new()
	add_child(yard)
	yard.build()
	# This tests D's pillars: agent K's clutter round them is cleared first.
	for pl: Vector2 in YardBuilder.PILLARS:
		WorldTestUtil.clear_clutter_near(get_tree(), Vector3(pl.x, 0, pl.y), 4.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not await WorldTestUtil.real_ragdoll_available(self):
		print("[overhead] FAIL: real ragdoll unavailable")
		get_tree().quit(1)
		return
	var pillars: Array = yard.get_parkour_features()["pillars"]
	var rows: Array = []
	var all_ok := pillars.size() == 4
	for p: Pillar in pillars:
		var m := float(p.head.get_meta(&"mass", 0.0)) if p.head else 0.0
		rows.append("%s %.0f kg" % [p.name, m])
		all_ok = all_ok and p.head != null and m >= Tuning.FALLING_MIN_MASS
	_line("every pillar holds an overhead piece: %s (min %.0f kg)" % [rows, Tuning.FALLING_MIN_MASS], all_ok)
	await _snap(_pillar_at(pillars, Vector2(6, 6)), &"grunt", Fighter.TEAM_ENEMY)
	await _snap(_pillar_at(pillars, Vector2(-6, -6)), &"player", Fighter.TEAM_PLAYER)
	print("[overhead] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[overhead] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _pillar_at(pillars: Array, xz: Vector2) -> Pillar:
	for p: Pillar in pillars:
		if Vector2(p.global_position.x, p.global_position.z).distance_to(xz) < 0.1:
			return p
	return null

## Snap `pillar` with two 18 m/s bodies flying across the beam's line, while a
## fighter of `arch` stands under the beam's inner end.
func _snap(pillar: Pillar, arch: StringName, team: int) -> void:
	_decisions.clear()
	_collapses.clear()
	_hits.clear()
	_blasts.clear()
	_head_land.clear()
	_young.clear()
	_young_raw = 0.0
	_young_held = 0.0
	var head_xf := pillar.head.global_transform
	var axis := head_xf.basis.z.normalized()           # the beam's long axis, toward the centre
	axis.y = 0.0
	axis = axis.normalized()
	var inner := head_xf.origin + axis * (Pillar.HEAD_LENGTH * 0.5 - 0.15)
	var under := Vector3(inner.x, 0.05, inner.z)
	var stander := WorldTestUtil.spawn_body(self, Transform3D(Basis(), under), false, arch, team)
	stander.max_hp = 500.0
	stander.hp = 500.0
	# Fly across the beam's line (perpendicular), so the bodies never touch the stander.
	var across := Vector3.UP.cross(axis).normalized()
	var base := Vector3(pillar.global_position.x, 0.0, pillar.global_position.z)
	var snap_g := -1.0
	_watch = pillar
	_dropped_g = -1.0
	var rule_rows: Array = []
	var rule_ok := true
	var k := 0
	while k < 4 and not pillar.is_broken:
		var be := pillar.break_energy
		var ct := ImpactResolver.crack_threshold_of(pillar)
		var start := base - across * (0.5 + 1.0)
		var f := WorldTestUtil.spawn_body(self, Transform3D(Basis.looking_at(-across, Vector3.UP), start + Vector3(0, 0.05, 0)),
			false, &"player")
		await get_tree().physics_frame
		await get_tree().physics_frame
		var c := f.get_center_of_mass()
		f.global_position += Vector3(start.x - c.x, 0, start.z - c.z)
		f.reset_physics_interpolation()
		await get_tree().physics_frame
		f.launch(Power.launch_velocity(11.0, across, 70.0), f.get_center_of_mass())
		await WorldTestUtil.wait_game(self, 0.5)
		var mine := _decisions.filter(func(d: Dictionary) -> bool: return d["wall"] == pillar and d["fighter"] == f)
		if mine.is_empty():
			rule_ok = false
			rule_rows.append("body %d: no decision" % (k + 1))
		else:
			var e := float(mine[0]["energy"])
			var out: StringName = mine[0]["outcome"]
			var want := &"break" if e >= be else (&"crack" if e >= ct else &"bounce")
			rule_ok = rule_ok and out == want
			rule_rows.append("body %d: %.0f J vs break %.0f / crack %.0f -> %s (rule %s)" % [k + 1, e, be, ct, out, want])
		f.queue_free()
		ImpactResolver.reset()
		k += 1
	var dec := _decisions.filter(func(d: Dictionary) -> bool: return d["wall"] == pillar)
	var outs: Array = dec.map(func(d: Dictionary) -> String: return "%s(%.0f J)" % [d["outcome"], d["energy"]])
	for d: Dictionary in dec:
		if d["outcome"] == &"break":
			snap_g = d["g"]
	var creak := _collapses.filter(func(c: Dictionary) -> bool: return c["kind"] == &"overhead")
	# Follow the piece: when it appears, its height, its landing.
	var heights: Array = []
	var t := 0.0
	while t < 4.0:
		await get_tree().physics_frame
		t += 1.0 / 120.0
		if pillar.fallen_head != null and is_instance_valid(pillar.fallen_head) and int(t * 120.0) % 30 == 0:
			heights.append("%.2f" % pillar.fallen_head.global_position.y)
	var piece := pillar.fallen_head
	var drop_delay := _dropped_g - snap_g if _dropped_g >= 0.0 and snap_g >= 0.0 else -1.0
	var bottom := piece.get_bounds().position.y if piece else 99.0
	# Landed: it came down from ~4 m to rest on the floor or the rubble.
	var landed: bool = piece != null and bottom < 0.9
	var hit: Array = _hits.filter(func(i: HitInfo) -> bool: return i.victim == stander and i.kind == &"debris")
	var by_head: bool = piece != null and piece.hit_fighters.has(stander.get_instance_id())
	var down := stander.is_down() or (hit.size() > 0 and (hit[0] as HitInfo).tier == HitInfo.Tier.KNOCKDOWN)
	_line("%s: 18 m/s bodies 1 m off the face: %s" % [pillar.name, rule_rows],
		rule_ok and pillar.is_broken and k >= 2)
	_line("%s: decisions %s; creak events %d; the piece drops %.3f s (game) after the snap (PILLAR_COLLAPSE_DELAY %.2f); heights every 0.25 s %s; lowest point %.2f m" % [
		pillar.name, outs, creak.size(), drop_delay, Tuning.PILLAR_COLLAPSE_DELAY, heights, bottom],
		pillar.is_broken and creak.size() == 1 and drop_delay >= 0.0 and drop_delay <= Tuning.PILLAR_COLLAPSE_DELAY + 0.02 and landed)
	_line("%s under it (%s): hit by the overhead piece=%s, HitInfo %s, down=%s, hp %.0f -> %.0f" % [arch, stander.name, by_head,
		hit.map(func(i: HitInfo) -> String: return "%s %s %.0f dmg" % [i.kind, HitInfo.tier_name(i.tier), i.damage]),
		down, 500.0, stander.hp], by_head and hit.size() >= 1 and down \
		and absf(500.0 - stander.hp - Tuning.FALLING_DAMAGE[&"knockdown"]) < 0.01)
	# Structure blasts: the overhead piece's, and the snapped pillar's upper
	# sections' (FallingPieces too, which may land on the stump or rubble, up
	# to ~1.3 m); none before the drop, none up at beam height (the old creak
	# blast went off at 4.1 m).
	var structure := _blasts.filter(func(b: Dictionary) -> bool: return b["source"] == &"structure")
	var early := structure.filter(func(b: Dictionary) -> bool: return _dropped_g < 0.0 or float(b["g"]) < _dropped_g)
	var high := structure.filter(func(b: Dictionary) -> bool: return (b["center"] as Vector3).y >= 2.0)
	var lp: Vector3 = _head_land.get("pos", Vector3(0, 99, 0))
	var head_blast := structure.filter(func(b: Dictionary) -> bool: return (b["center"] as Vector3).distance_to(lp) < 0.01)
	_line("%s's overhead piece lands %s, %.2f s after the drop; its structure blast %s; all structure blasts at heights %s; before the drop %d, at or over 2 m %d (want 0, 0)" % [
		pillar.name, lp, float(_head_land.get("g", -1.0)) - _dropped_g, head_blast.map(func(b: Dictionary) -> String:
			return "%.0f J r %.1f" % [b["power"], b["radius"]]),
		structure.map(func(b: Dictionary) -> float: return snappedf((b["center"] as Vector3).y, 0.01)), early.size(), high.size()],
		not _head_land.is_empty() and lp.y < 1.0 and head_blast.size() == 1 and early.is_empty() and high.is_empty())
	_line("%s's new pieces while young (%.2f s): fastest %.1f m/s raw, %.1f m/s after DebrisManager's hold (want at most 1.2 x 18 = %.1f), %d pieces" % [
		pillar.name, DebrisManager.YOUNG_TIME, _young_raw, _young_held, 18.0 * DebrisManager.YOUNG_SHARE, _young.size()],
		_young.size() > 0 and _young_held <= 18.0 * DebrisManager.YOUNG_SHARE + 0.1)
	var pos0 := piece.global_position if piece else Vector3.ZERO
	await WorldTestUtil.wait_game(self, 8.0)
	var stays := piece != null and is_instance_valid(piece) and not piece.is_queued_for_deletion() \
		and piece.collision_layer != 0 and piece.global_position.distance_to(pos0) < 0.5
	_line("%s's piece 8 s later: still there=%s, frozen=%s" % [pillar.name, stays, DebrisManager.is_frozen(piece) if stays else false],
		stays and DebrisManager.is_frozen(piece))
	stander.queue_free()
	await get_tree().physics_frame
