extends Node3D
## Debris (round 2):
## 1. Falling chunks emit GameEvents.debris_landed (throttled).
## 2. 240 large chunks in batches: the large pool settles within its cap
##    (DebrisManager.LARGE_MAX) and no chunk is ever removed while moving.
## 3. Small chunks fade after Tuning.DEBRIS_FADE_AFTER; large ones persist.
## 4. Settled rubble is never frozen STATIC: a fast 70 kg body knocks it away.
## 5. 35 real panel breaks keep both pools bounded.
## 6. reset() frees everything.

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
	var land_ok := _landed >= 5
	print("[debris] 25 falling chunks: debris_landed x%d -> %s" % [_landed, _pf(land_ok)])
	_ok = _ok and land_ok
	DebrisManager.reset()
	await get_tree().physics_frame

	# 2. Large pool cap, no removal while moving.
	var max_large := 0
	for batch in 8:
		for i in 30:
			@warning_ignore("integer_division")
			var b := _chunk(Vector3(-40 + (i % 6) * 1.6 + batch * 10.0, 0.6 + (i / 6) * 0.7, 0), false)
			b.linear_velocity = Vector3(randf_range(-1, 1), 0, randf_range(-1, 1))
			DebrisManager.register(b, false)
		await _watch(1.2)
		max_large = maxi(max_large, DebrisManager.count_large())
	await _watch(1.5)
	var settled_large := DebrisManager.count_large()
	var cap_ok := settled_large <= DebrisManager.LARGE_MAX and max_large <= DebrisManager.LARGE_MAX + DebrisManager.OVERFLOW_HARD \
		and _popped == 0
	print("[debris] 240 large chunks: peak %d, settled %d (cap %d), removed while moving %d -> %s" % [
		max_large, settled_large, DebrisManager.LARGE_MAX, _popped, _pf(cap_ok)])
	_ok = _ok and cap_ok

	# 3. Small chunks fade, large persist past DEBRIS_FADE_AFTER.
	var smalls: Array[RigidBody3D] = []
	for i in 20:
		@warning_ignore("integer_division")
		var b := _chunk(Vector3(60 + (i % 5) * 0.8, 0.3, 60 + (i / 5) * 0.8), true)
		DebrisManager.register(b, true)
		smalls.append(b)
	var large_probe := DebrisManager.get_bodies()[0]
	await WorldTestUtil.wait_game(self, Tuning.DEBRIS_FADE_AFTER + 1.2)
	var smalls_left := smalls.filter(func(b: Variant) -> bool: return is_instance_valid(b) and not (b as Node).is_queued_for_deletion()).size()
	var fade_ok := smalls_left == 0 and is_instance_valid(large_probe) and not large_probe.is_queued_for_deletion()
	print("[debris] small chunks left after %.0f s: %d; old large chunk still there: %s -> %s" % [
		Tuning.DEBRIS_FADE_AFTER + 1.2, smalls_left, is_instance_valid(large_probe), _pf(fade_ok)])
	_ok = _ok and fade_ok
	DebrisManager.reset()
	await get_tree().physics_frame

	# 4. Settled rubble wakes when a fast body hits it.
	var slab := _chunk(Vector3(0, 0.3, 40), false)
	DebrisManager.register(slab, false)
	await WorldTestUtil.wait_game(self, Tuning.DEBRIS_FREEZE_AFTER + 1.0)
	var start := slab.global_position
	var was_frozen := slab.freeze
	var ball := RigidBody3D.new()
	ball.mass = 70.0
	ball.collision_layer = Layers.RAGDOLL
	ball.collision_mask = Layers.MASK_RAGDOLL
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(0.5, 0.5, 0.5)
	cs.shape = sh
	ball.add_child(cs)
	add_child(ball)
	ball.global_position = Vector3(-2.5, 0.35, 40)
	ball.linear_velocity = Vector3(8, 0, 0)
	await WorldTestUtil.wait_game(self, 1.0)
	var moved := slab.global_position.distance_to(start)
	var wake_ok := not was_frozen and moved > 0.3
	print("[debris] settled slab frozen=%s, moved %.2f m when a 70 kg body hit it at 8 m/s -> %s" % [was_frozen, moved, _pf(wake_ok)])
	_ok = _ok and wake_ok
	ball.queue_free()
	DebrisManager.reset()
	await get_tree().physics_frame

	# 5a. Gameplay pace: 35 body-sized holes, one every 0.6 s. The large pool
	#     stays within its cap and nothing is removed while moving.
	var panels: Array[Destructible] = []
	for i in 35:
		panels.append(WorldTestUtil.make_panel(self, &"drywall" if i % 2 == 0 else &"brick", Vector3(-80.0 + i * 4.0, 0, 90.0)))
	await get_tree().physics_frame
	var spawned := 0
	var peak_l := 0
	var peak_s := 0
	_speed.clear()
	_popped = 0
	for p in panels:
		p.break_hole(p.global_position + Vector3(0.125, -0.5, 0), Vector3(-9, 0, 0), Rect2(-0.4, -1.4, 0.8, 1.8))
		spawned += p.last_chunks.size()
		await _watch(0.6)
		peak_l = maxi(peak_l, DebrisManager.count_large())
		peak_s = maxi(peak_s, DebrisManager.count_small())
	await _watch(2.0)
	var pb_ok := peak_l <= DebrisManager.LARGE_MAX + 25 and peak_s <= Tuning.DEBRIS_MAX \
		and DebrisManager.count_large() <= DebrisManager.LARGE_MAX and _popped == 0 and spawned > DebrisManager.LARGE_MAX
	print("[debris] 35 holes (one per 0.6 s) spawned %d chunks: peak large %d small %d, settled large %d, removed while moving %d -> %s" % [
		spawned, peak_l, peak_s, DebrisManager.count_large(), _popped, _pf(pb_ok)])
	_ok = _ok and pb_ok
	DebrisManager.reset()
	await get_tree().physics_frame

	# 5b. Stress: 25 whole panels in 2.5 s. The pools stay bounded (the hard
	#     overflow rule may fade airborne chunks here, by design).
	var p2: Array[Destructible] = []
	for i in 25:
		p2.append(WorldTestUtil.make_panel(self, &"brick", Vector3(-80.0 + i * 4.0, 0, 130.0)))
	await get_tree().physics_frame
	var peak := 0
	var peak_live := 0
	for p in p2:
		p.force_break(p.global_position + Vector3(0.125, 0, 0), Vector3(-9, 0, 0))
		await _watch(0.1)
		peak = maxi(peak, DebrisManager.count_large())
		peak_live = maxi(peak_live, DebrisManager.count_large(false))
	await _watch(2.0)
	var st_ok := peak_live <= DebrisManager.LARGE_MAX + DebrisManager.OVERFLOW_HARD and DebrisManager.count_large() <= DebrisManager.LARGE_MAX
	print("[debris] stress 25 whole panels in 2.5 s: peak live %d (cap %d + %d overflow), peak incl. fading %d, after 2 s %d -> %s" % [
		peak_live, DebrisManager.LARGE_MAX, DebrisManager.OVERFLOW_HARD, peak, DebrisManager.count_large(), _pf(st_ok)])
	_ok = _ok and st_ok

	# 6. Reset.
	DebrisManager.reset()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var reset_ok := DebrisManager.count() == 0 and get_tree().get_nodes_in_group(&"debris").filter(
		func(b: Node) -> bool: return not b.is_queued_for_deletion()).is_empty()
	print("[debris] reset frees all -> %s" % _pf(reset_ok))
	_ok = _ok and reset_ok
	print("[debris] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _pf(b: bool) -> String:
	return "PASS" if b else "FAIL"

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

func _chunk(pos: Vector3, small: bool) -> RigidBody3D:
	var b := RigidBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.3, 0.2, 0.25) if small else Vector3(0.6, 0.5, 0.25)
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
