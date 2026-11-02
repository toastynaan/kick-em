extends Node3D
## Debris, Round 5 (Feel Reference: "Things stay", Budget; F11, owner D):
## 1. Falling chunks emit GameEvents.debris_landed (throttled).
## 2. Tuning.DEBRIS_MAX + 90 chunks in batches of 30: the pool settles within
##    Tuning.DEBRIS_MAX, the oldest settled ones fade first (the first batch is
##    gone, the newest all there), and no chunk is ever removed while moving.
## 3. Nothing times out: large and small chunks are all still there after the
##    old 10 s / 30 s lifetimes (only strike chips, an effect, fade).
## 4. A chunk at rest freezes after Tuning.DEBRIS_FREEZE_AFTER (4 s), not before;
##    a launched 70 kg body flying into frozen rubble wakes it and knocks it
##    away; a fighter walking through frozen rubble wakes it too.
## 5. Real holes at play pace until more than Tuning.DEBRIS_MAX + 40 chunks have
##    spawned: the pool stays within its cap, the newest chunks are the ones
##    kept, nothing removed while moving.
## 6. Counters for the end-of-wave check: wall_holes_count, furniture_broken_count,
##    props_broken_total, get_world_counts; reset() frees everything and zeroes them.

var _ok := true
var _landed := 0
var _speed := {}   ## body -> last seen speed
var _popped := 0

func _ready() -> void:
	GameEvents.debris_landed.connect(func(_b: Node3D, _p: Vector3, _s: float, _surf: StringName) -> void: _landed += 1)
	WorldTestUtil.make_floor(self, 300.0)
	await get_tree().physics_frame

	# 1. Landings.
	for i in 25:
		@warning_ignore("integer_division")
		var b := _chunk(Vector3(-60 + (i % 5) * 1.5, 1.5 + i * 0.35, -60 + (i / 5) * 1.5), false)
		b.linear_velocity = Vector3(0, -6, 0)
		DebrisManager.register(b, false)
	await WorldTestUtil.wait_game(self, 1.5)
	_line("25 falling chunks: debris_landed x%d" % _landed, _landed >= 5)
	DebrisManager.reset()
	await get_tree().physics_frame

	# 2. Round cap, oldest settled first, no removal while moving.
	var first: Array[RigidBody3D] = []
	var last_batch: Array[RigidBody3D] = []
	var peak := 0
	# Enough batches to overflow the cap by 90: the three oldest batches must go.
	var batches := int(ceil(float(Tuning.DEBRIS_MAX + 90) / 30.0))
	for batch in batches:
		last_batch.clear()
		for i in 30:
			@warning_ignore("integer_division")
			var b := _chunk(Vector3(-40 + (i % 6) * 1.6 + batch * 10.0, 0.6 + (i / 6) * 0.7, 0), false)
			b.linear_velocity = Vector3(randf_range(-1, 1), 0, randf_range(-1, 1))
			DebrisManager.register(b, false)
			if batch == 0:
				first.append(b)
			last_batch.append(b)
		await _watch(1.2)
		peak = maxi(peak, DebrisManager.count_debris(false))
	await _watch(1.5)
	var kept_new := last_batch.filter(func(b: Variant) -> bool: return _alive(b)).size()
	var kept_old := first.filter(func(b: Variant) -> bool: return _alive(b)).size()
	_line("%d chunks: peak live %d, settled %d (cap %d), newest batch kept %d/30, first batch kept %d/30, removed while moving %d" % [
		batches * 30, peak, DebrisManager.count_debris(false), Tuning.DEBRIS_MAX, kept_new, kept_old, _popped],
		DebrisManager.count_debris(false) <= Tuning.DEBRIS_MAX and peak <= Tuning.DEBRIS_MAX + DebrisManager.OVERFLOW_HARD \
		and kept_new == 30 and kept_old == 0 and _popped == 0)
	DebrisManager.reset()
	await get_tree().physics_frame

	# 3. Nothing times out (strike chips do).
	var probes: Array[RigidBody3D] = []
	for i in 20:
		@warning_ignore("integer_division")
		var b := _chunk(Vector3(60 + (i % 5) * 0.8, 0.3, 60 + (i / 5) * 0.8), i % 2 == 0)
		DebrisManager.register(b, i % 2 == 0, DebrisManager.MEDIUM_LIFE if i % 4 == 1 else -1.0)
		probes.append(b)
	var chips: Array[RigidBody3D] = []
	for i in 6:
		var c := _chunk(Vector3(70 + i * 0.5, 0.3, 70), true)
		DebrisManager.register(c, true, StrikeMarks.CHIP_LIFE)
		chips.append(c)
	await WorldTestUtil.wait_game(self, Tuning.DEBRIS_FADE_AFTER + 1.5)
	var left := probes.filter(func(b: Variant) -> bool: return _alive(b)).size()
	var chips_left := chips.filter(func(b: Variant) -> bool: return _alive(b)).size()
	_line("after %.1f s: %d/20 chunks (small, large, 'medium') still there, strike chips left %d/6" % [
		Tuning.DEBRIS_FADE_AFTER + 1.5, left, chips_left], left == 20 and chips_left == 0)
	DebrisManager.reset()
	await get_tree().physics_frame

	# 4a. Freeze at 4 s of rest, not before.
	var slab := _chunk(Vector3(0, 0.45, 40), false, Vector3(0.5, 0.9, 0.6))
	DebrisManager.register(slab, false)
	var t := 0.0
	var frozen_at := -1.0
	while t < Tuning.DEBRIS_FREEZE_AFTER + 2.0 and frozen_at < 0.0:
		await get_tree().physics_frame
		t += 1.0 / 120.0
		if slab.freeze:
			frozen_at = t
	var fr_ok := frozen_at >= Tuning.DEBRIS_FREEZE_AFTER and frozen_at <= Tuning.DEBRIS_FREEZE_AFTER + 1.2
	_line("a chunk at rest froze after %.2f s (Tuning.DEBRIS_FREEZE_AFTER %.0f s)" % [frozen_at, Tuning.DEBRIS_FREEZE_AFTER], fr_ok)
	# 4b. A launched body flies into the frozen slab: it wakes and is knocked away.
	var body := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(-2.4, 0.05, 40)), false, &"player")
	for i in 3:
		await get_tree().physics_frame
	var start := slab.global_position
	body.launch(Vector3(9, 0.6, 0), body.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 1.0)
	var moved := slab.global_position.distance_to(start)
	_line("frozen slab hit by a body launched at 9 m/s: moved %.2f m, frozen now=%s" % [moved, slab.freeze],
		moved > 0.2)
	body.queue_free()
	DebrisManager.reset()
	await get_tree().physics_frame
	# 4c. A fighter walking through frozen rubble wakes it.
	var rubble := _chunk(Vector3(0, 0.2, 60), true)
	DebrisManager.register(rubble, true)
	await WorldTestUtil.wait_game(self, Tuning.DEBRIS_FREEZE_AFTER + 1.0)
	var was := DebrisManager.is_frozen(rubble)
	var walker := WorldTestUtil.spawn_body(self, Transform3D(Basis(), Vector3(-2.0, 0.05, 60)), false)
	await get_tree().physics_frame
	walker.move_input = Vector3(1, 0, 0)
	var woke := false
	t = 0.0
	while t < 1.5:
		await get_tree().physics_frame
		t += 1.0 / 120.0
		woke = woke or not rubble.freeze
	_line("a fighter walking through frozen rubble: was frozen=%s, woke=%s" % [was, woke], was and woke)
	walker.queue_free()
	DebrisManager.reset()
	await get_tree().physics_frame

	# 5. Play pace: body-sized holes, one every 0.6 s, until the chunks spawned
	#    overflow the cap by 40.
	var panels: Array[Destructible] = []
	var spawned := 0
	peak = 0
	_speed.clear()
	_popped = 0
	var newest: Array = []
	while spawned <= Tuning.DEBRIS_MAX + 40 and panels.size() < 70:
		var i := panels.size()
		var p := WorldTestUtil.make_panel(self, &"drywall" if i % 2 == 0 else &"brick",
			Vector3(-140.0 + (i % 35) * 8.0, 0, 90.0 + 8.0 * floorf(i / 35.0)))
		panels.append(p)
		await get_tree().physics_frame
		p.break_hole(p.global_position + Vector3(0.125, -0.5, 0), Vector3(-9, 0, 0), Rect2(-0.4, -1.4, 0.8, 1.8))
		spawned += p.last_chunks.size()
		newest = p.last_chunks.duplicate()
		await _watch(0.6)
		peak = maxi(peak, DebrisManager.count_debris(false))
	await _watch(2.0)
	var newest_kept := newest.filter(func(b: Variant) -> bool: return _alive(b)).size()
	_line("%d holes spawned %d chunks: peak live %d, settled %d (cap %d), newest hole's chunks kept %d/%d, removed while moving %d" % [
		panels.size(), spawned, peak, DebrisManager.count_debris(false), Tuning.DEBRIS_MAX, newest_kept, newest.size(), _popped],
		peak <= Tuning.DEBRIS_MAX + 25 and DebrisManager.count_debris(false) <= Tuning.DEBRIS_MAX and _popped == 0 \
		and spawned > Tuning.DEBRIS_MAX and newest_kept == newest.size())

	# 6. Counters, then reset.
	var crate := Destructible.new()
	crate.kind = &"crate"
	crate.surface = &"wood"
	crate.size = Vector3(1, 1, 1)
	crate.break_energy_override = 600.0
	add_child(crate)
	crate.global_position = Vector3(0, 0.5, 120)
	var tp := ThrowableProp.spawn(self, &"bottle", Transform3D(Basis(), Vector3(4, 0.3, 120)))
	await get_tree().physics_frame
	crate.force_break(crate.global_position, Vector3(-3, 0, 0))
	tp.shatter()
	await get_tree().physics_frame
	var counts := DebrisManager.get_world_counts()
	var c_ok: bool = DebrisManager.wall_holes_count() == panels.size() and DebrisManager.furniture_broken_count() == 1 \
		and DebrisManager.props_broken_total() == 1 and counts["wall_holes"] == panels.size() and counts["debris"] > 0
	_line("counts %s" % counts, c_ok)
	DebrisManager.reset()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var reset_ok := DebrisManager.count() == 0 and DebrisManager.props_broken_total() == 0 \
		and get_tree().get_nodes_in_group(&"debris").filter(func(b: Node) -> bool: return not b.is_queued_for_deletion()).is_empty()
	_line("reset frees all and zeroes the counters", reset_ok)
	print("[debris] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[debris] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _alive(b: Variant) -> bool:
	return is_instance_valid(b) and not (b as Node).is_queued_for_deletion() and (b as CollisionObject3D).collision_layer != 0

## Step `seconds` of game time, flagging any debris body that disappears
## (or starts fading) while it was still moving.
func _watch(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		for b in get_tree().get_nodes_in_group(&"debris"):
			var rb := b as RigidBody3D
			if rb == null:
				continue
			var fading := rb.is_queued_for_deletion() or rb.collision_layer == 0
			if fading and not _speed.has(rb.get_instance_id() * -1):
				if float(_speed.get(rb.get_instance_id(), 0.0)) > 0.5:
					_popped += 1
				_speed[rb.get_instance_id() * -1] = true
			elif not fading:
				_speed[rb.get_instance_id()] = rb.linear_velocity.length()
		await get_tree().physics_frame
		t += get_physics_process_delta_time()

func _chunk(pos: Vector3, small: bool, size := Vector3.ZERO) -> RigidBody3D:
	var b := RigidBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size if size != Vector3.ZERO else (Vector3(0.3, 0.2, 0.25) if small else Vector3(0.6, 0.5, 0.25))
	cs.shape = box
	b.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mi.mesh = bm
	b.add_child(mi)
	b.mass = 5.0 if small else 30.0
	add_child(b)
	b.global_position = pos
	return b
