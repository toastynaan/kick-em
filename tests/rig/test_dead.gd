extends Node3D
## Bodies stay (Feel Reference), agent A. A killed body moves to
## Layers.DEAD_BODY / MASK_DEAD_BODY; a walking capsule passes through it
## without pushing it; it freezes Tuning.DEAD_FREEZE_AFTER s after coming to
## rest and then costs nothing (the controller stops processing; the animator
## already stopped at death); wake() unfreezes it, a thrown corpse flies,
## lands, settles and refreezes after RagdollController.DEAD_REFREEZE_AFTER s;
## eight corpses killed in a heap settle into a still pile (no jitter) with the
## awake cap respected, and cost nothing once frozen.

var _ok := true

func _check(what: String, cond: bool, info := "") -> void:
	print("  %-56s %s %s" % [what, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

## Fastest bone (m/s) of a body (0 when frozen).
func _fastest(rc: RagdollController) -> float:
	if rc.is_settled():
		return 0.0
	return RigTestUtil.max_bone_speed(rc)

## Wait until `rc` settles; returns [seconds waited, seconds at rest before the freeze].
func _until_settled(rc: RagdollController, max_s: float) -> Array:
	var n := 0
	var rest := 0.0
	while not rc.is_settled() and n < int(max_s * 120.0):
		rest = rc.get_dead_rest_time()
		await get_tree().physics_frame
		n += 1
	return [n / 120.0, rest + 1.0 / 120.0]

func _ready() -> void:
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		print("DEAD FAIL (timeout)")
		get_tree().quit(1))
	RigTestUtil.make_floor(self, 300.0)
	var d := RigTestUtil.make_dummy(self, &"grunt", Vector3.ZERO, null, false)
	await _frames(6)
	var rc := d.ragdoll

	# --- Layers -------------------------------------------------------------------------
	rc.kill(Vector3(0, 0.5, 1.5))
	var layers_ok := true
	for pb in d.rig.get_physical_bones():
		layers_ok = layers_ok and PhysicsServer3D.body_get_collision_layer(pb.get_rid()) == Layers.DEAD_BODY \
			and PhysicsServer3D.body_get_collision_mask(pb.get_rid()) == Layers.MASK_DEAD_BODY \
			and pb.collision_layer == Layers.DEAD_BODY
	_check("killed: bones on DEAD_BODY / MASK_DEAD_BODY, animator stopped", rc.state == RagdollController.State.DEAD and layers_ok
		and not d.animator.is_physics_processing())
	var awake_tick := 0.0
	for i in 60:
		await get_tree().physics_frame
		awake_tick = maxf(awake_tick, rc.last_tick_ms)

	# --- Freeze after DEAD_FREEZE_AFTER s at rest -------------------------------------------
	var w := await _until_settled(rc, 12.0)
	_check("freezes %.1f s after coming to rest" % Tuning.DEAD_FREEZE_AFTER, rc.is_settled()
		and absf(w[1] - Tuning.DEAD_FREEZE_AFTER) < 0.15, "settled after %.2f s, %.2f s at rest" % [w[0], w[1]])
	var hips := d.rig.get_physical_bone(Bones.HIPS).get_rid()
	_check("frozen: static DEAD_BODY colliders, no processing", PhysicsServer3D.body_get_mode(hips) == PhysicsServer3D.BODY_MODE_STATIC
		and PhysicsServer3D.body_get_collision_layer(hips) == Layers.DEAD_BODY and not rc.is_physics_processing()
		and not d.animator.is_physics_processing() and rc.last_tick_ms == 0.0,
		"awake corpse cost %.3f ms/tick (max), frozen %.3f" % [awake_tick, rc.last_tick_ms])

	# --- A walking capsule passes through without pushing ------------------------------------
	for awake in [false, true]:
		if awake:
			rc.wake()
			await _frames(30)
		var walker := CharacterBody3D.new()
		walker.collision_layer = Layers.CAPSULE
		walker.collision_mask = Layers.MASK_CAPSULE
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.3
		cap.height = 1.8
		cs.shape = cap
		cs.position = Vector3(0, 0.9, 0)
		walker.add_child(cs)
		add_child(walker)
		var c := rc.get_ground_position()
		walker.global_position = c + Vector3(-2.5, 0, 0)
		var hips0 := d.rig.get_physical_bone(Bones.HIPS).global_position
		for i in 300:
			walker.velocity = Vector3(Tuning.WALK_SPEED, -1.0, 0)
			walker.move_and_slide()
			await get_tree().physics_frame
		var went := walker.global_position.x - (c.x - 2.5)
		var pushed := d.rig.get_physical_bone(Bones.HIPS).global_position.distance_to(hips0)
		_check("a walking capsule passes through a %s body" % ("woken" if awake else "frozen"), went > 5.0 and pushed < 0.02,
			"walker went %.1f m, body moved %.3f m" % [went, pushed])
		walker.queue_free()

	# --- wake / throw / refreeze ---------------------------------------------------------------
	rc.wake()
	_check("wake(): simulating again", not rc.is_settled() and rc.is_physics_processing())
	var p0 := rc.get_ground_position()
	rc.add_velocity(Vector3(0, 4.0, 7.0))   # a throw (Carry adds velocity like this)
	w = await _until_settled(rc, 14.0)
	var flew := rc.get_ground_position().distance_to(p0)
	_check("a thrown corpse flies, lands, settles and refreezes", rc.is_settled() and flew > 2.0
		and absf(w[1] - RagdollController.DEAD_REFREEZE_AFTER) < 0.15,
		"flew %.1f m, refroze after %.2f s (%.2f s at rest)" % [flew, w[0], w[1]])

	# --- A heap of eight ----------------------------------------------------------------------------
	var heap: Array[LabDummy] = []
	for i in 8:
		var pos := Vector3(20.0 + (i % 3) * 0.45, 0, (i / 3) * 0.45)
		heap.append(RigTestUtil.make_dummy(self, &"grunt", pos, null, false))
	await _frames(8)
	for i in heap.size():
		heap[i].ragdoll.kill(Vector3(0.3 * (i % 2) - 0.15, 0.2, 0.6))
	# Every awake corpse's hips are tracked every tick; at-rest motion is the
	# step between two consecutive ticks that are both well into a rest (a body
	# knocked out of its rest restarts its timer and is not "at rest" again
	# until it has been still for a second).
	var max_awake := 0
	var over_cap_resting := 0
	var n := 0
	var all := false
	var jitter := 0.0
	var rest_ticks := 0
	var prev := {}
	var prev_rest := {}
	var resets: Array[String] = []
	var late := RagdollController.DEAD_EARLY_FREEZE + 2.0 / 120.0
	while n < 120 * 20 and not all:
		await get_tree().physics_frame
		n += 1
		var awake := RagdollController.awake_dead_count()
		max_awake = maxi(max_awake, awake)
		all = true
		var rested_long := false
		for h in heap:
			var hrc := h.ragdoll
			all = all and hrc.is_settled()
			var p := h.rig.get_physical_bone(Bones.HIPS).global_position
			var rest := hrc.get_dead_rest_time()
			if prev.has(h) and not hrc.is_settled():
				var step: float = p.distance_to(prev[h])
				if float(prev_rest[h]) > 1.0 and rest > 1.0:
					rest_ticks += 1
					jitter = maxf(jitter, step)
				if float(prev_rest[h]) > 0.5 and rest == 0.0:
					resets.append("%s at %.2f s (%.3f m in the tick)" % [h.name, n / 120.0, step])
			if not hrc.is_settled() and rest > late:
				rested_long = true
			prev[h] = p
			prev_rest[h] = rest
		# The cap: while more than DEAD_AWAKE_MAX corpses are awake, none may stay
		# at rest past DEAD_EARLY_FREEZE (bodies still falling can't be frozen).
		if awake > RagdollController.DEAD_AWAKE_MAX and rested_long:
			over_cap_resting += 1
	if not resets.is_empty():
		print("    rest interrupted (knocked by the pile): ", resets)
	var cost := 0.0
	for h in heap:
		cost += h.ragdoll.last_tick_ms
	var hip_pos := []
	for h in heap:
		hip_pos.append(h.rig.get_physical_bone(Bones.HIPS).global_position)
	await _frames(240)
	var moved := 0.0
	for i in heap.size():
		moved = maxf(moved, heap[i].rig.get_physical_bone(Bones.HIPS).global_position.distance_to(hip_pos[i]))
	_check("eight corpses in a heap all freeze", all, "after %.2f s" % [n / 120.0])
	_check("awake cap: over %d awake, no corpse stays at rest past %.1f s" % [RagdollController.DEAD_AWAKE_MAX,
		RagdollController.DEAD_EARLY_FREEZE], over_cap_resting == 0,
		"%d ticks broke it; at most %d awake at once (all falling together)" % [over_cap_resting, max_awake])
	_check("the pile is still: no jitter at rest, none once frozen", jitter < 0.003 and rest_ticks > 0 and moved < 0.0001,
		"rest jitter %.4f m/tick over %d resting ticks, frozen drift %.5f m" % [jitter, rest_ticks, moved])
	_check("a frozen pile costs nothing", cost == 0.0, "%.3f ms/tick" % cost)
	print("DEAD ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)
