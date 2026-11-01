extends Node3D
## During a launch, get_ground_position() and the host stay within 0.5 m (XZ)
## of the pelvis, and the capsule is disabled. Teleporting the host
## mid-flight must not disturb the simulated bones (compared against a twin
## launched identically). On get-up the host is back at the body, upright,
## capsule enabled, rig re-attached.

func _ready() -> void:
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		print("HOST_FOLLOW FAIL (timeout)")
		get_tree().quit(1))
	RigTestUtil.make_floor(self, 200.0)
	var a := RigTestUtil.make_dummy(self, &"player", Vector3(-3, 0, 0), RagdollProfile.hard_limits_only(), false)
	var b := RigTestUtil.make_dummy(self, &"player", Vector3(3, 0, 0), RagdollProfile.hard_limits_only(), false)
	for i in 3:
		await get_tree().physics_frame
	var v := Vector3(2, 5, -9)
	a.ragdoll.launch(v, a.global_position + Vector3.UP, Bones.CHEST)
	b.ragdoll.launch(v, b.global_position + Vector3.UP, Bones.CHEST)
	var worst_ground := 0.0
	var worst_host := 0.0
	var worst_twin := 0.0
	var capsule_off := true
	var top_level_ok := true
	for f in 240:
		if f == 30:
			# Yank the host 10 m away; the bones must not notice.
			a.global_position += Vector3(10, 3, 10)
		await get_tree().physics_frame
		var pa := a.rig.get_physical_bone(Bones.HIPS).global_position
		var pb := b.rig.get_physical_bone(Bones.HIPS).global_position
		var g := a.ragdoll.get_ground_position()
		worst_ground = maxf(worst_ground, Vector2(g.x - pa.x, g.z - pa.z).length())
		if f != 30:
			worst_host = maxf(worst_host, Vector2(a.global_position.x - pa.x, a.global_position.z - pa.z).length())
		if f < 70:  # airborne part (contact chaos makes twins diverge after landing)
			worst_twin = maxf(worst_twin, (pa - Vector3(-3, 0, 0)).distance_to(pb - Vector3(3, 0, 0)))
		capsule_off = capsule_off and (a.get_node("Capsule") as CollisionShape3D).disabled
		top_level_ok = top_level_ok and a.rig.top_level
		if a.ragdoll.state != RagdollController.State.LAUNCHED:
			break
	# Let it recover.
	var t := 0
	while a.ragdoll.state != RagdollController.State.ANIMATED and t < 1200:
		await get_tree().physics_frame
		t += 1
	var pelvis := a.rig.get_bone_global_position(Bones.HIPS)
	var after_ok: bool = a.ragdoll.state == RagdollController.State.ANIMATED \
		and not (a.get_node("Capsule") as CollisionShape3D).disabled and not a.rig.top_level \
		and Vector2(a.global_position.x - pelvis.x, a.global_position.z - pelvis.z).length() < 0.2 \
		and a.global_basis.y.dot(Vector3.UP) > 0.99 and absf(a.global_position.y) < 0.05
	print("ground-vs-pelvis max %.3f m, host-vs-pelvis max %.3f m, twin divergence after host yank %.4f m, capsule off in flight %s, rig top_level %s, after get-up ok %s" % [
		worst_ground, worst_host, worst_twin, capsule_off, top_level_ok, after_ok])
	var ok := worst_ground < 0.5 and worst_host < 0.5 and worst_twin < 0.05 and capsule_off and top_level_ok and after_ok
	print("HOST_FOLLOW ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)
