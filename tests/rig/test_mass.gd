extends Node3D
## Physical bone masses sum to the archetype mass: Round 5 F0 check "logged
## ragdoll masses total 70, 75 and 110 kg, within 1 kg" for the player, grunt,
## stick and heavy (Bones.MASS_70 fractions x the Tuning.ARCHETYPES mass, as
## Fighter builds them), measured on the rig and on a live RagdollController;
## legacy brute / duelist too. Rig has exactly Bones.ALL / Bones.PHYSICAL;
## standing proportions.

func _ready() -> void:
	var ok := true
	# Round 5 roster: the archetype mass and the total the doc wants.
	for case in [[&"player", 70.0], [&"grunt", 75.0], [&"stick", 75.0], [&"heavy", 110.0]]:
		var mass := float(Tuning.ARCHETYPES[case[0]]["mass"])
		var d := RigTestUtil.make_dummy(self, case[0], Vector3(randf_range(-20, 20), 0, 0), null, false)
		await get_tree().physics_frame
		var total := d.ragdoll.get_total_mass()
		var rig_total := 0.0
		for pb in d.rig.get_physical_bones():
			rig_total += pb.mass
		var good := absf(total - float(case[1])) <= 1.0 and absf(rig_total - float(case[1])) <= 1.0 and absf(mass - float(case[1])) < 0.001
		print("ragdoll mass %-7s %.2f kg (rig %.2f kg, archetype %.1f, want %.0f +- 1) %s" % [case[0], total, rig_total, mass, case[1], "ok" if good else "FAILED"])
		ok = ok and good
		d.queue_free()
	for case in [[&"player", 70.0, 0.5], [&"brute", float(Tuning.ARCHETYPES[&"brute"]["mass"]), 1.0], [&"duelist", 65.0, 0.5]]:
		var cfg: Dictionary = Tuning.ARCHETYPES[case[0]]
		var rig := HumanoidRig.new()
		add_child(rig)
		rig.build(cfg["appearance"], case[1])
		await get_tree().physics_frame
		var total := 0.0
		for pb in rig.get_physical_bones():
			total += pb.mass
		var mass_ok := absf(total - float(case[1])) <= float(case[2])
		var bones_ok := rig.skeleton.get_bone_count() == Bones.ALL.size()
		for i in Bones.ALL.size():
			bones_ok = bones_ok and rig.skeleton.get_bone_name(i) == String(Bones.ALL[i])
			bones_ok = bones_ok and rig.skeleton.get_bone_rest(i).basis.is_equal_approx(Basis())
		var phys_ok := rig.get_physical_bones().size() == Bones.PHYSICAL.size()
		for b in Bones.PHYSICAL:
			phys_ok = phys_ok and rig.get_physical_bone(b) != null and rig.get_physical_bone(b).bone_name == String(b)
		var att_ok := true
		for b in Bones.ALL:
			att_ok = att_ok and rig.get_attachment(b) != null
		var parts_ok := rig.get_mesh_parts().size() >= 16
		for p in rig.get_mesh_parts():
			parts_ok = parts_ok and p.layers == Layers.VIS_CHARACTERS and p.material_override is ShaderMaterial
		var h := float(cfg["appearance"]["height"])
		var hips_y := rig.get_rest_global(Bones.HIPS).origin.y
		var prop_ok := absf(hips_y - 0.95 * h) < 0.02 and absf(rig.get_height() - 1.8 * h) < 0.01
		var layer_ok := true
		for pb in rig.get_physical_bones():
			layer_ok = layer_ok and pb.collision_layer == Layers.RAGDOLL and pb.collision_mask == Layers.MASK_RAGDOLL
			# Not simulating: no collisions on the server.
			layer_ok = layer_ok and PhysicsServer3D.body_get_collision_layer(pb.get_rid()) == 0
		var ccd_ok := PhysicsServer3D.body_is_continuous_collision_detection_enabled(rig.get_physical_bone(Bones.CHEST).get_rid())
		print("%s mass=%.3f (want %.1f) bones=%s phys=%s attach=%s parts=%d/%s proportions=%s layers=%s ccd=%s" % [
			case[0], total, case[1], bones_ok, phys_ok, att_ok, rig.get_mesh_parts().size(), parts_ok, prop_ok, layer_ok, ccd_ok])
		ok = ok and mass_ok and bones_ok and phys_ok and att_ok and parts_ok and prop_ok and layer_ok
		rig.queue_free()
	print("MASS ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)
