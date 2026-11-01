extends Node3D
## Wound painting writes blood_points into the hit part's local space, keeps
## at most 16 per part (oldest overwritten), pushes points inside a part out to
## the side the blow came from, sets blood_level = 1 - hp/max_hp on every part,
## flashes, and gives a part that shares its material a copy. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	var f := U.make_fighter(self, Vector3(2, 0, 1), false)
	var rig = f.rig
	# Chest turned 30 degrees and scaled, so local != world offsets.
	var chest: MeshInstance3D = rig.add_part(Bones.CHEST, Vector3(0.4, 0.3, 0.24), Vector3(0, 1.35, 0),
			Basis(Vector3.UP, deg_to_rad(30.0)).scaled(Vector3(1.2, 1.2, 1.2)))
	var arm: MeshInstance3D = rig.add_part(Bones.R_UPPER_ARM, Vector3(0.1, 0.28, 0.1), Vector3(0.6, 1.3, 0))
	await get_tree().process_frame

	# 1. A point on the chest's front face lands in the chest's local space.
	var local_target := Vector3(0.05, 0.04, 0.12)  # on the +Z face (half depth 0.12)
	var world := chest.global_transform * local_target
	BloodFX.wound(f, world, 0.5)
	var pts := BloodFX.get_wound_points(chest)
	if pts.size() != 1:
		fails.append("chest got %d points, want 1" % pts.size())
	else:
		var p: Vector4 = pts[0]
		var got := Vector3(p.x, p.y, p.z)
		print("wound local %s (want %s), radius %.3f" % [got, local_target, p.w])
		if got.distance_to(local_target) > 0.001:
			fails.append("wrong local point %s" % got)
		# 0.05..0.13 m world radius divided by the 1.2 scale.
		if p.w < 0.05 / 1.2 - 0.001 or p.w > 0.13 / 1.2 + 0.001:
			fails.append("radius not in local units: %.3f" % p.w)
	var mat := chest.material_override as ShaderMaterial
	var param: Array = mat.get_shader_parameter(&"blood_points")
	if param.is_empty() or (param[0] as Vector4).distance_to(Vector4(local_target.x, local_target.y, local_target.z, (pts[0] as Vector4).w)) > 0.001:
		fails.append("shader blood_points not written")
	if int(mat.get_shader_parameter(&"blood_count")) != 1:
		fails.append("blood_count != 1")
	if not BloodFX.get_wound_points(arm).is_empty():
		fails.append("far part (arm) was painted")
	if float(mat.get_shader_parameter(&"flash")) < 0.99:
		fails.append("no hit flash")

	# 2. Cap at 16: older points are overwritten in a ring.
	for i in 20:
		BloodFX.wound(f, chest.global_transform * Vector3(-0.15 + i * 0.015, 0.0, 0.12), 0.3)
	pts = BloodFX.get_wound_points(chest)
	var count := int(mat.get_shader_parameter(&"blood_count"))
	print("after 21 wounds: %d points, blood_count %d" % [pts.size(), count])
	if pts.size() != 16 or count != 16:
		fails.append("cap: %d points / count %d, want 16" % [pts.size(), count])
	var has_first := false
	for p: Vector4 in pts:
		if Vector3(p.x, p.y, p.z).distance_to(local_target) < 0.001:
			has_first = true
	if has_first:
		fails.append("oldest point was not overwritten")

	# 3. A hit whose point is inside the chest goes on the face toward the attacker.
	BloodFX.reset()
	f.hp = 250.0
	var attacker_dir := chest.global_basis.z.normalized()  # attacker on the chest's +Z side
	var info := U.hit(f, &"sparta_kick", chest.global_position, -attacker_dir, 60.0, 2500.0)
	GameEvents.hit_landed.emit(info)
	pts = BloodFX.get_wound_points(chest)
	if pts.size() != 1:
		fails.append("hit_landed painted %d chest points" % pts.size())
	else:
		var p: Vector4 = pts[0]
		print("hit inside chest -> local %s" % Vector3(p.x, p.y, p.z))
		if not U.near(p.z, 0.12, 0.002) or absf(p.x) > 0.002 or absf(p.y) > 0.002:
			fails.append("inside point not pushed to the attacker-facing face: %s" % p)
	# blood_level = 1 - hp/max_hp on every part.
	for part in [chest, arm]:
		var lvl := float((part.material_override as ShaderMaterial).get_shader_parameter(&"blood_level"))
		if not U.near(lvl, 0.75, 0.001):
			fails.append("blood_level %.3f on %s, want 0.75" % [lvl, part.get_parent().name])
	# Flash decays back to 0.
	await get_tree().create_timer(0.3).timeout
	if float(mat.get_shader_parameter(&"flash")) > 0.001:
		fails.append("flash did not decay")

	# 4. Two parts sharing one material: the second gets its own copy.
	var shared := ShaderMaterial.new()
	shared.shader = load("res://shaders/fighter.gdshader")
	var g := U.make_fighter(self, Vector3(-2, 0, 1), false)
	var a: MeshInstance3D = g.rig.add_part(Bones.L_LOWER_LEG, Vector3(0.1, 0.4, 0.1), Vector3(-0.1, 0.25, 0), Basis(), shared)
	var b: MeshInstance3D = g.rig.add_part(Bones.R_LOWER_LEG, Vector3(0.1, 0.4, 0.1), Vector3(0.1, 0.25, 0), Basis(), shared)
	await get_tree().process_frame
	BloodFX.wound(g, a.global_transform * Vector3(0, 0, 0.05), 0.2)
	BloodFX.wound(g, b.global_transform * Vector3(0, 0, 0.05), 0.2)
	if a.material_override == b.material_override:
		fails.append("shared material was not split")
	elif int((a.material_override as ShaderMaterial).get_shader_parameter(&"blood_count")) != 1 \
			or int((b.material_override as ShaderMaterial).get_shader_parameter(&"blood_count")) != 1:
		fails.append("split materials hold the wrong counts")

	# 5. Optional: the real rig, once agent A's HumanoidRig builds mesh parts.
	var real := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis(), Vector3(0, 0, -3)))
	await U.physics_frames(get_tree(), 3)
	var parts: Array[MeshInstance3D] = real.rig.get_mesh_parts() if real.rig else ([] as Array[MeshInstance3D])
	if parts.is_empty():
		print("note: real HumanoidRig has no mesh parts yet; skipped real-rig check")
	else:
		var target := real.rig.get_bone_global_position(Bones.CHEST)
		BloodFX.wound(real, target + real.get_forward() * 0.3, 0.6)
		var painted := 0
		for p in parts:
			painted += BloodFX.get_wound_points(p).size()
		print("real rig: %d parts, %d points painted" % [parts.size(), painted])
		if painted == 0:
			fails.append("real rig: nothing painted")

	U.finish(get_tree(), "test_wounds", fails, errlog)
