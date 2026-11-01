extends Node3D
## Smoke test: build a dummy, stand, walk, play every move and hold, launch,
## recover. Fails on any NaN or if the body never recovers.

func _ready() -> void:
	RigTestUtil.make_floor(self)
	var d := RigTestUtil.make_dummy(self, &"player", Vector3.ZERO)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var rig := d.rig
	print("height=", rig.get_height(), " hips=", rig.get_bone_global_position(Bones.HIPS), " head=", rig.get_bone_global_position(Bones.HEAD))
	print("mesh parts=", rig.get_mesh_parts().size(), " physical bones=", rig.get_physical_bones().size())
	var hand_att := rig.get_attachment(Bones.L_HAND)
	print("L hand bone=", rig.get_bone_global_position(Bones.L_HAND), " attachment=", hand_att.global_position)
	d.move_input = Vector3(0, 0, -1)
	for i in 120:
		await get_tree().physics_frame
	print("walked to ", d.global_position, " hand=", rig.get_bone_global_position(Bones.L_HAND), " att=", hand_att.global_position)
	d.move_input = Vector3.ZERO
	for id in PoseLibrary.ALL_MOVE_IDS:
		if id in [&"getup_face_up", &"getup_face_down"]:
			continue
		d.animator.play_move(id, 0.2, 0.1, 0.2)
		for i in 60:
			await get_tree().physics_frame
	for id in PoseLibrary.ALL_HOLD_IDS:
		d.animator.hold_pose(id)
		for i in 30:
			await get_tree().physics_frame
	d.animator.release_pose()
	for i in 30:
		await get_tree().physics_frame
	d.ragdoll.launch(Vector3(0, 3, 8), d.global_position + Vector3.UP, Bones.CHEST)
	var t := 0
	while d.ragdoll.state != RagdollController.State.ANIMATED and t < 1200:
		await get_tree().physics_frame
		t += 1
		if t % 120 == 0:
			print("t=", t / 120.0, " state=", d.ragdoll.state, " pelvis=", rig.get_physical_bone(Bones.HIPS).global_position, " host=", d.global_position)
	print("recovered after ", t / 120.0, " s state=", d.ragdoll.state)
	var ok := d.ragdoll.state == RagdollController.State.ANIMATED and not RigTestUtil.has_nan(d.ragdoll)
	print("SMOKE ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)
