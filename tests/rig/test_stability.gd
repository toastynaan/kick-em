extends Node3D
## Toggle the full ragdoll on and off 50 times on a floor (plus flinches and
## staggers in between): no NaN, no bone speed above 40 m/s, no bone more than
## 2.5 m from the pelvis, and the body comes to rest afterwards.

const CYCLES := 50

func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("STABILITY FAIL (timeout)")
		get_tree().quit(1))
	RigTestUtil.make_floor(self)
	var dummies: Array[LabDummy] = [
		RigTestUtil.make_dummy(self, &"player", Vector3(-2, 0, 0), null, true),
		RigTestUtil.make_dummy(self, &"brute", Vector3(2, 0, 0), null, false),
	]
	for i in 3:
		await get_tree().physics_frame
	var worst_speed := 0.0
	var worst_dist := 0.0
	var nan := false
	var ccd_ok := true
	for c in CYCLES:
		for d in dummies:
			match c % 5:
				0, 1, 2:
					d.ragdoll.launch(Vector3.ZERO, d.global_position + Vector3.UP, Bones.CHEST)
				3:
					d.ragdoll.flinch(Vector3(0, 0, 1), Bones.HEAD, 1.0)
				4:
					d.ragdoll.stagger(Vector3(1, 0, 0), 0.6)
			d.animator.time_scale = 1.0
		for f in 40 + (c % 3) * 25:
			await get_tree().physics_frame
			for d in dummies:
				if d.ragdoll.is_simulating():
					worst_speed = maxf(worst_speed, RigTestUtil.max_bone_speed(d.ragdoll))
					if d.ragdoll.is_full_ragdoll():
						worst_dist = maxf(worst_dist, RigTestUtil.max_dist_from_pelvis(d.ragdoll))
					nan = nan or RigTestUtil.has_nan(d.ragdoll)
		for d in dummies:
			if d.ragdoll.is_full_ragdoll():
				ccd_ok = ccd_ok and PhysicsServer3D.body_is_continuous_collision_detection_enabled(d.rig.get_physical_bone(Bones.L_LOWER_ARM).get_rid())
			d.ragdoll.force_recover()
		for f in 8:
			await get_tree().physics_frame
	# Final drop: must come to rest.
	for d in dummies:
		d.ragdoll.auto_getup = false
		d.ragdoll.launch(Vector3(0, 0, 1), d.global_position + Vector3.UP, Bones.CHEST)
	for f in 600:
		await get_tree().physics_frame
		for d in dummies:
			worst_speed = maxf(worst_speed, RigTestUtil.max_bone_speed(d.ragdoll))
			worst_dist = maxf(worst_dist, RigTestUtil.max_dist_from_pelvis(d.ragdoll))
			nan = nan or RigTestUtil.has_nan(d.ragdoll)
	var rest_speed := 0.0
	var states := []
	for d in dummies:
		rest_speed = maxf(rest_speed, RigTestUtil.max_bone_speed(d.ragdoll))
		states.append(d.ragdoll.state)
	print("cycles=%d worst_speed=%.2f m/s worst_dist_from_pelvis=%.2f m nan=%s rest_speed=%.3f states=%s ccd_on_sim_bones=%s" % [
		CYCLES, worst_speed, worst_dist, nan, rest_speed, states, ccd_ok])
	var ok := not nan and worst_speed < 40.0 and worst_dist < 2.5 and rest_speed < 0.5
	print("STABILITY ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)
