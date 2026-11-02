extends Node3D
## Contact frame and hitstop (Feel Reference F0/F4), agent A. Twin dummies walk
## side by side; at the same frame both get the same launch, one inside a
## TimeDirector.hitstop() (the Fighter path: freeze_hitstop + is_frozen()).
## 1. B's order (reaction, then hitstop): the frozen twin holds its contact
##    pose for the whole freeze, then leaves with the same velocity as the
##    unfrozen twin had: cached walk velocity + launch impulse.
## 2. Reverse order (hitstop, then the reaction 3 ticks into the freeze): the
##    velocity still carries the walk (cached BEFORE the freeze, not zero).
## 3. Flinch (H never calls freeze() for FLINCH; the controller polls the
##    host): the head holds still, the mesh jitters 2-4 cm, then the head snaps.
## 4. A flying body frozen (wall-break freeze): stores its velocities, gravity
##    off (no drop), gets them back.

var _ok := true

func _check(what: String, cond: bool, info := "") -> void:
	print("  %-60s %s %s" % [what, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _reset(d: LabDummy, pos: Vector3) -> void:
	d.ragdoll.force_recover()
	d.global_transform = Transform3D(Basis(), pos)
	d.velocity = Vector3.ZERO
	d.move_input = Vector3.ZERO
	d.reset_physics_interpolation()
	d.animator.reset_pose()

func _body_xfs(d: LabDummy) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for pb in d.rig.get_physical_bones():
		out.append(PhysicsServer3D.body_get_state(pb.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM))
	return out

func _max_move(a: Array[Transform3D], b: Array[Transform3D]) -> float:
	var m := 0.0
	for i in a.size():
		m = maxf(m, a[i].origin.distance_to(b[i].origin))
	return m

func _ready() -> void:
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("HITSTOP FAIL (timeout)")
		get_tree().quit(1))
	RigTestUtil.make_floor(self, 300.0)
	var v := Vector3(0, 3.0, 6.0)   # launched back along +Z (they walk toward -Z)
	var walk := Tuning.WALK_SPEED
	var x := 0.0
	var a: LabDummy
	var b: LabDummy

	for order in ["reaction then hitstop", "hitstop then reaction"]:
		# Fresh twins each time: same gait phase on the same frame.
		x += 12.0
		a = RigTestUtil.make_dummy(self, &"player", Vector3(x - 3.0, 0, 0), null, true)
		b = RigTestUtil.make_dummy(self, &"player", Vector3(x + 3.0, 0, 0), null, true)
		await _frames(10)
		a.move_input = Vector3(0, 0, -1)
		b.move_input = Vector3(0, 0, -1)
		await _frames(70)
		var t_hit := TimeDirector.now()
		# The free twin is launched at the freeze's first frame: both reactions
		# start from the same (pre-freeze) animated pose and velocities.
		var vb := Vector3.ZERO
		if order == "reaction then hitstop":
			a.ragdoll.launch(v, a.global_position + Vector3.UP, Bones.CHEST)
			TimeDirector.hitstop([a], 0.11)
			b.ragdoll.launch(v, b.global_position + Vector3.UP, Bones.CHEST)
			await get_tree().physics_frame
			vb = b.ragdoll.get_com_velocity()
		else:
			TimeDirector.hitstop([a], 0.11)
			b.ragdoll.launch(v, b.global_position + Vector3.UP, Bones.CHEST)
			await get_tree().physics_frame
			vb = b.ragdoll.get_com_velocity()
			await _frames(2)
			a.ragdoll.launch(v, a.global_position + Vector3.UP, Bones.CHEST)
		a.move_input = Vector3.ZERO
		b.move_input = Vector3.ZERO
		var contact := _body_xfs(a)
		var drift := 0.0
		var speed := 0.0
		var grav_off := true
		var held_frames := 0
		while a.ragdoll.is_in_hitstop() and held_frames < 60:
			drift = maxf(drift, _max_move(contact, _body_xfs(a)))
			speed = maxf(speed, RigTestUtil.max_bone_speed(a.ragdoll))
			var g: float = PhysicsServer3D.body_get_param(a.rig.get_physical_bone(Bones.CHEST).get_rid(), PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE)
			grav_off = grav_off and g == 0.0
			held_frames += 1
			await get_tree().physics_frame
		var held_for := TimeDirector.now() - t_hit
		await get_tree().physics_frame
		var va := a.ragdoll.get_com_velocity()
		print("  %s: held %.3f s (%d ticks), contact drift %.4f m, max speed %.3f m/s; after: frozen twin %s, free twin %s" % [
			order, held_for, held_frames, drift, speed, va, vb])
		_check(order + ": contact pose held, gravity off", drift < 0.005 and speed < 0.05 and grav_off
			and absf(held_for - 0.11) < 0.02)
		_check(order + ": leaves with cached walk + impulse", va.distance_to(vb) < 0.4 and va.z < v.z - walk * 0.6,
			"|dv| %.2f m/s, z %.2f (impulse %.1f - walk %.1f)" % [va.distance_to(vb), va.z, v.z, walk])
		await _frames(30)
		b.queue_free()
		if order != "hitstop then reaction":
			a.queue_free()

	# --- 3. Flinch: the controller holds it from host.is_frozen() alone -----------------------
	_reset(a, Vector3(-3, 0, 0))
	await _frames(20)
	a.ragdoll.flinch(Vector3(0, 0, 1), Bones.HEAD, 1.0)
	TimeDirector.hitstop([a], 0.06)
	var head_pb := a.rig.get_physical_bone(Bones.HEAD).get_rid()
	var head0: Transform3D = PhysicsServer3D.body_get_state(head_pb, PhysicsServer3D.BODY_STATE_TRANSFORM)
	var anim_hips := a.rig.get_rest_hips_position() + a.animator.hips_offset * a.rig.height_scale
	var hold_head := 0.0
	var jit_max := 0.0
	var n := 0
	await get_tree().physics_frame
	while a.ragdoll.is_in_hitstop() and n < 30:
		var hx: Transform3D = PhysicsServer3D.body_get_state(head_pb, PhysicsServer3D.BODY_STATE_TRANSFORM)
		hold_head = maxf(hold_head, hx.origin.distance_to(head0.origin))
		jit_max = maxf(jit_max, a.rig.skeleton.get_bone_pose_position(0).distance_to(anim_hips))
		n += 1
		await get_tree().physics_frame
	var snap := 0.0
	for f in 30:
		await get_tree().physics_frame
		var i := HumanoidRig.bone_index(Bones.HEAD)
		snap = maxf(snap, rad_to_deg(a.rig.skeleton.get_bone_pose_rotation(i).angle_to(a.animator.pose_rot[i])))
	var jit_after := a.rig.skeleton.get_bone_pose_position(0).distance_to(a.rig.get_rest_hips_position() + a.animator.hips_offset * a.rig.height_scale)
	_check("flinch: head held for the freeze (host poll only)", n >= 6 and hold_head < 0.003,
		"%d ticks, head moved %.4f m" % [n, hold_head])
	_check("flinch: mesh jitters 2-4 cm during the freeze, not after", jit_max >= 0.01 and jit_max <= 0.045 and jit_after < 0.001,
		"jitter %.3f m, after %.4f m" % [jit_max, jit_after])
	_check("flinch: head snaps back after the freeze", snap > 15.0, "%.1f deg" % snap)

	# --- 4. A flying body frozen mid-air keeps its velocity ------------------------------------
	_reset(a, Vector3(-3, 0, 0))
	await _frames(20)
	a.ragdoll.launch(Vector3(0, 6.0, 5.0), a.global_position + Vector3.UP, Bones.CHEST)
	await _frames(12)
	var v_before := a.ragdoll.get_com_velocity()
	var hips_y := a.rig.get_physical_bone(Bones.HIPS).global_position.y
	a.ragdoll.freeze(0.15)   # ImpactResolver's wall-break freeze (Fighter.freeze_hitstop calls this too)
	var drop := 0.0
	var m := 0
	while m < 40:
		await get_tree().physics_frame
		if not a.ragdoll.is_in_hitstop():
			break   # released in the tick just run (it has moved one free step since)
		drop = maxf(drop, absf(a.rig.get_physical_bone(Bones.HIPS).global_position.y - hips_y))
		m += 1
	var v_after := a.ragdoll.get_com_velocity() - Vector3.DOWN * 9.8 / 120.0   # minus that one step of gravity
	_check("flying body: held in place, gravity off, velocity back", drop < 0.002 and v_after.distance_to(v_before) < 0.1
		and absf(m / 120.0 - 0.15) < 0.02,
		"held %d ticks, moved %.4f m, %s -> %s" % [m, drop, v_before, v_after])

	print("HITSTOP ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)
