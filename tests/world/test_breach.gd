extends Node3D
## Staged breach: YardBuilder.breach(wall, 1.5) thumps three times with growing
## local cracks inside the delay, then opens the way and marks the panel
## &"staged_breach".
## - Facade panels get a hole from the floor up that every non-Brute archetype's
##   capsule fits through (capsule casts on drywall and brick); the panel stands.
## - The roll door (the Brute's entry) bursts whole, and a Brute capsule fits.
## - Every wall get_breach_walls() returns has a clear spawn spot
##   GameMode.BREACH_BEHIND behind it (0.5 m clearance), and there are >= 4.
## - Wave-4 style: a real Brute staged behind the roll door reaches the
##   courtyard within 8 s.

var _cracks: Array = []
var _breaks: Array = []
var _ok := true
var yard: YardBuilder

func _ready() -> void:
	yard = YardBuilder.new()
	add_child(yard)
	yard.build()
	await get_tree().physics_frame
	await get_tree().physics_frame
	GameEvents.wall_cracked.connect(func(w: Node3D, _p: Vector3, _e: float) -> void: _cracks.append([w, TimeDirector.now()]))
	GameEvents.wall_broken.connect(func(w: Node3D, _p: Vector3, _e: float, _v: Vector3) -> void: _breaks.append([w, TimeDirector.now()]))

	# 1. Usable breach walls: clear spawn spots, at least 4.
	var behind := float(GameMode.BREACH_BEHIND)
	var walls := yard.get_breach_walls()
	var all_count := yard.get_destructibles().filter(func(d: Destructible) -> bool: return d.has_meta(&"facade")).size()
	var blocked: Array[String] = []
	for w in walls:
		if not _spot_clear(w, behind):
			blocked.append(String(w.name))
	var spots_ok: bool = walls.size() >= 4 and blocked.is_empty() and is_equal_approx(behind, YardBuilder.BREACH_BEHIND)
	_line("breach walls: %d of %d facade panels usable, spot %.1f m behind (GameMode.BREACH_BEHIND), blocked spots %s" % [
		walls.size(), all_count, behind, blocked], spots_ok)

	# 2. A drywall breach: thumps inside the delay, growing cracks, hole fits everyone but the Brute.
	var dry := _pick(walls, &"drywall")
	var t0 := TimeDirector.now()
	yard.breach(dry, 1.5)
	var crack_counts: Array[int] = []
	var prev := 0
	while TimeDirector.now() - t0 < 1.8:
		await get_tree().physics_frame
		var n := dry.get_crack_edge_count()
		if n != prev:
			crack_counts.append(n)
			prev = n
	var mine_c := _cracks.filter(func(c: Array) -> bool: return c[0] == dry)
	var mine_b := _breaks.filter(func(b: Array) -> bool: return b[0] == dry)
	var t_break: float = mine_b[0][1] - t0 if mine_b.size() > 0 else -1.0
	var growing := crack_counts.size() >= 2 and crack_counts[1] > crack_counts[0]
	var timing_ok: bool = mine_c.size() == 3 and mine_b.size() == 1 and t_break > 1.35 and t_break < 1.65 \
		and mine_c.all(func(c: Array) -> bool: return c[1] - t0 < t_break)
	_line("drywall breach: thumps=%d (cracks drawn %s) burst at %.2f s, staged=%s, still standing=%s (%d/%d cells)" % [
		mine_c.size(), crack_counts, t_break, dry.get_meta(&"staged_breach", false), not dry.is_broken,
		dry.get_alive_count(), dry.get_cell_count()],
		timing_ok and growing and dry.get_meta(&"staged_breach", false) and not dry.is_broken)
	_capsules_through(dry, "drywall")

	# 3. A brick breach (garage or storage facade).
	var brick := _pick(walls, &"brick")
	yard.breach(brick, 1.5)
	await WorldTestUtil.wait_game(self, 1.8)
	_capsules_through(brick, "brick")

	# 4. The roll door bursts whole for the Brute.
	var door := yard.get_roll_door()
	yard.breach(door, 1.5)
	await WorldTestUtil.wait_game(self, 1.8)
	var door_ok: bool = door.is_broken and door.get_meta(&"staged_breach", false) \
		and _breaks.filter(func(b: Array) -> bool: return b[0] == door).size() == 1
	_line("roll door breach: whole door gone=%s, one wall_broken, staged=%s" % [door.is_broken,
		door.get_meta(&"staged_breach", false)], door_ok)
	var brute := _capsule_of(&"brute")
	var frac := _cast(door, brute.x, brute.y, behind)
	_line("brute capsule (r %.2f, h %.2f) through the roll door: %.2f of the way" % [brute.x, brute.y, frac], frac >= 0.999)

	# 5. Wave-4 style: a real Brute staged behind a fresh roll door reaches the courtyard.
	await _brute_entry()

	print("[breach] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _line(text: String, ok: bool) -> void:
	print("[breach] %s -> %s" % [text, "PASS" if ok else "FAIL"])
	_ok = _ok and ok

func _pick(walls: Array[Destructible], surface: StringName) -> Destructible:
	for w in walls:
		if w.surface == surface and w.style != &"rolldoor":
			return w
	return null

## Capsule (radius, height) of an archetype, the way Fighter builds it.
static func _capsule_of(id: StringName) -> Vector2:
	var app: Dictionary = (Tuning.ARCHETYPES[id] as Dictionary).get("appearance", {})
	var w := float(app.get("width", 1.0))
	var h := float(app.get("height", 1.0))
	return Vector2(Fighter.CAPSULE_RADIUS * lerpf(1.0, w, 0.6), Fighter.CAPSULE_HEIGHT * h)

## Every archetype but the Brute through the hole in `wall`.
func _capsules_through(wall: Destructible, label: String) -> void:
	var worst := 1.0
	var notes: Array[String] = []
	for id: StringName in Tuning.ARCHETYPES:
		if id == &"brute":
			continue
		var cap := _capsule_of(id)
		var frac := _cast(wall, cap.x, cap.y, float(GameMode.BREACH_BEHIND))
		worst = minf(worst, frac)
		if frac < 0.999:
			notes.append("%s %.2f" % [id, frac])
	_line("%s hole (%s): every non-Brute capsule passes, worst %.2f %s" % [label, YardBuilder.breach_hole_size(),
		worst, notes], worst >= 0.999)

## Fraction of the way a standing capsule gets from the spawn spot to 2.5 m
## past the wall (1.0 = all the way).
func _cast(wall: Destructible, radius: float, height: float, behind: float) -> float:
	var into := wall.global_basis.z
	into.y = 0.0
	into = into.normalized()
	var start := wall.global_position - into * behind
	start.y = 0.06 + height * 0.5
	var cap := CapsuleShape3D.new()
	cap.radius = radius
	cap.height = height
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.transform = Transform3D(Basis(), start)
	q.motion = into * (behind + 2.5)
	q.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
	var excl: Array[RID] = []
	for n in get_tree().get_nodes_in_group(&"world_static"):
		if n is CollisionObject3D and n.name == "Floor":
			excl.append((n as CollisionObject3D).get_rid())
	q.exclude = excl
	var r := get_world_3d().direct_space_state.cast_motion(q)
	return r[0] if r.size() == 2 else 0.0

func _spot_clear(wall: Destructible, behind: float) -> bool:
	var into := wall.global_basis.z
	into.y = 0.0
	var spot := wall.global_position - into.normalized() * behind
	spot.y = 1.05
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.5
	cyl.height = 1.8
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cyl
	q.transform = Transform3D(Basis(), spot)
	q.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE | Layers.DEBRIS
	q.exclude = [wall.get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()

func _brute_entry() -> void:
	if not await WorldTestUtil.real_ragdoll_available(self):
		_line("wave-4 brute: real fighters unavailable", false)
		return
	# Fresh yard so the roll door is intact.
	yard.queue_free()
	DebrisManager.reset()
	await get_tree().physics_frame
	yard = YardBuilder.new()
	add_child(yard)
	yard.build()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var player := FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 4)), Fighter.TEAM_PLAYER)
	var door := yard.get_roll_door()
	var into := door.global_basis.z
	into.y = 0.0
	into = into.normalized()
	var base := door.global_position
	base.y = yard.get_player_spawn().origin.y
	var pos := base - into * float(GameMode.BREACH_BEHIND)
	var xf := Transform3D(Basis.looking_at(into, Vector3.UP), pos)
	var brute := FighterFactory.spawn_enemy(self, &"brute", xf, PackedVector3Array([base + into * 2.5]))
	if Engine.has_singleton(&"AttackDirector") or get_tree().root.has_node(^"AttackDirector"):
		var ad := get_tree().root.get_node(^"AttackDirector")
		if ad.has_method(&"register_enemy"):
			ad.call(&"register_enemy", brute)
	yard.breach(door, 1.5)
	var t := 0.0
	var reached := -1.0
	while t < 8.0:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		if brute.get_ground_position().z > -10.5:
			reached = t
			break
	_line("wave-4 brute behind the roll door reaches the courtyard (z > -10.5) at %.2f s (limit 8 s), z=%.2f" % [
		reached, brute.get_ground_position().z], reached > 0.0 and reached <= 8.0)
	player.queue_free()
