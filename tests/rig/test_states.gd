extends Node3D
## State machine coverage: flinch returns to ANIMATED after FLINCH_TIME;
## a stagger recovers on its feet after Tuning.REACT_STAGGER.fade and even a
## strong one never tips into a launch (Round 5: "a stagger keeps the legs
## animated and never turns into a launch by itself"); freeze zeroes and
## restores bone velocities; air recovery; kill -> settled (corpse frozen on
## Layers.DEAD_BODY, cheap); sever returns a RigidBody3D and hides the parts;
## set_ignore_breakables toggles the DESTRUCTIBLE bit.

var _ok := true

func _check(what: String, cond: bool, info := "") -> void:
	print("  %-34s %s %s" % [what, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("STATES FAIL (timeout)")
		get_tree().quit(1))
	RigTestUtil.make_floor(self, 200.0)
	var d := RigTestUtil.make_dummy(self, &"duelist", Vector3.ZERO, null, true)
	await _frames(4)
	var rc := d.ragdoll
	var changes: Array = []
	rc.state_changed.connect(func(o: int, n: int) -> void: changes.append([o, n]))

	# Flinch
	var head0 := d.rig.get_bone_global_position(Bones.HEAD)
	rc.flinch(Vector3(0, 0, 1), Bones.HEAD, 1.0)
	_check("flinch enters FLINCH", rc.state == RagdollController.State.FLINCH)
	await _frames(6)
	var moved := d.rig.get_bone_global_position(Bones.HEAD).distance_to(head0)
	await _frames(int(Tuning.FLINCH_TIME * 120.0) + 4)
	_check("flinch moves head then recovers", rc.state == RagdollController.State.ANIMATED and moved > 0.005, "head moved %.3f m" % moved)
	_check("capsule stays on in flinch", not (d.get_node("Capsule") as CollisionShape3D).disabled)

	# Stagger
	var p0 := d.global_position
	rc.stagger(Vector3(0, 0, 1), 0.5)
	_check("stagger enters STAGGER", rc.state == RagdollController.State.STAGGER)
	await _frames(int(float(Tuning.REACT_STAGGER["fade"]) * 120.0) + 6)
	_check("stagger recovers on its feet", rc.state == RagdollController.State.ANIMATED, "pushed %.2f m" % d.global_position.distance_to(p0))

	# A strong stagger never tips into a launch (Round 5).
	var tipped := false
	rc.stagger(Vector3(0, 0, 1), 1.2)
	for i in 300:
		await get_tree().physics_frame
		if rc.state == RagdollController.State.LAUNCHED or rc.is_full_ragdoll():
			tipped = true
			break
	_check("strong stagger never tips into a launch", not tipped and rc.state == RagdollController.State.ANIMATED)
	rc.force_recover()
	await _frames(4)
	_check("force_recover -> ANIMATED", rc.state == RagdollController.State.ANIMATED and not d.rig.top_level)

	# Freeze (hitstop) on a flying body
	rc.launch(Vector3(0, 6, 6), d.global_position + Vector3.UP, Bones.CHEST)
	await _frames(10)
	var v_before := rc.get_com_velocity()
	rc.freeze(0.1)
	await _frames(3)
	var v_frozen := RigTestUtil.max_bone_speed(rc)
	var pos_frozen := d.rig.get_physical_bone(Bones.HIPS).global_position
	await _frames(6)
	var drift := d.rig.get_physical_bone(Bones.HIPS).global_position.distance_to(pos_frozen)
	# Hitstop is real time (TimeDirector.now); tests run with --fixed-fps, so
	# wait on the wall clock.
	var t_end := TimeDirector.now() + 0.12
	while TimeDirector.now() < t_end:
		await get_tree().physics_frame
	await _frames(2)
	var v_after := rc.get_com_velocity()
	_check("freeze zeroes velocities", v_frozen < 0.05 and drift < 0.01, "speed %.3f drift %.4f" % [v_frozen, drift])
	_check("freeze restores velocity", v_after.length() > v_before.length() * 0.6, "%.2f -> %.2f" % [v_before.length(), v_after.length()])

	# Air recovery (relaunch so it is early in a flight)
	rc.launch(Vector3(0, 3, 0), d.ragdoll.get_center_of_mass(), Bones.CHEST)
	await _frames(2)
	_check("air_recover refused early", rc.air_recover() == false)
	await _frames(int(Tuning.AIR_RECOVERY_AFTER * 120.0))
	var recovered := rc.air_recover()
	_check("air_recover after 0.4 s", recovered and rc.state == RagdollController.State.ANIMATED and not (d.get_node("Capsule") as CollisionShape3D).disabled)
	await _frames(60)

	# Flight pose override (wall splat) while launched.
	rc.launch(Vector3(0, 4, 0), d.ragdoll.get_center_of_mass(), Bones.CHEST)
	rc.set_flight_pose(&"wall_splat")
	await _frames(3)
	_check("set_flight_pose drives the muscle target", d.animator.get_hold_id() == &"wall_splat")
	rc.set_flight_pose(&"")
	await _frames(3)
	_check("set_flight_pose('') restores the fall loop", d.animator.get_hold_id() == &"fall")
	rc.force_recover()
	await _frames(4)

	# ignore breakables
	rc.set_ignore_breakables(true)
	var m1 := d.rig.get_physical_bone(Bones.CHEST).collision_mask
	rc.set_ignore_breakables(false)
	var m2 := d.rig.get_physical_bone(Bones.CHEST).collision_mask
	_check("set_ignore_breakables", (m1 & Layers.DESTRUCTIBLE) == 0 and (m2 & Layers.DESTRUCTIBLE) != 0)

	# Kill -> settled
	var settled := [false]
	rc.settled.connect(func() -> void: settled[0] = true)
	rc.kill(Vector3(0, 2, 4))
	_check("kill -> DEAD", rc.state == RagdollController.State.DEAD)
	for i in 1200:
		await get_tree().physics_frame
		if settled[0]:
			break
	_check("corpse settles and freezes", settled[0] and rc.state == RagdollController.State.DEAD)
	var hips_pb := d.rig.get_physical_bone(Bones.HIPS)
	_check("corpse bones static DEAD_BODY colliders", PhysicsServer3D.body_get_mode(hips_pb.get_rid()) == PhysicsServer3D.BODY_MODE_STATIC
		and PhysicsServer3D.body_get_collision_layer(hips_pb.get_rid()) == Layers.DEAD_BODY)
	await _frames(30)
	_check("corpse costs ~nothing", rc.last_tick_ms < 0.01, "%.4f ms" % rc.last_tick_ms)

	# Re-launch a corpse, then sever the head mid-flight.
	rc.launch(Vector3(0, 5, 3), d.ragdoll.get_center_of_mass(), Bones.CHEST)
	await _frames(20)
	var head_parts := d.rig.get_bone_parts(Bones.HEAD)
	var piece := d.rig.sever(&"head")
	_check("sever returns RigidBody3D", piece != null and piece is RigidBody3D and piece.is_inside_tree())
	_check("sever hides parts", head_parts.size() > 0 and not head_parts[0].visible)
	_check("sever twice -> null", d.rig.sever(&"head") == null and d.rig.is_severed(&"head"))
	var piece2 := d.rig.sever(&"forearm_l")
	_check("sever forearm", piece2 != null and d.rig.is_severed(&"forearm_l"))
	if piece:
		_check("piece moving", piece.linear_velocity.length() > 0.5, "v=%.2f" % piece.linear_velocity.length())
	var nan := false
	for i in 240:
		await get_tree().physics_frame
		nan = nan or RigTestUtil.has_nan(rc)
	_check("no NaN after sever", not nan)
	_check("mass excludes severed", rc.get_total_mass() < 64.0, "%.1f kg" % rc.get_total_mass())
	print("STATES ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)
