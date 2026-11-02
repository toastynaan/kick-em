extends Node3D
## WorldMaterials.set_view_fade (upgrade 2, camera rule 4): a blocking panel,
## prop, debris chunk or loose prop fades per instance without breaking the
## shared materials; panels/chunks dither through the view_fade instance
## uniform, plain-material props use GeometryInstance3D.transparency; 0
## restores; static world geometry keeps the plain (no-discard) shader.

var _ok := true

func _ready() -> void:
	WorldTestUtil.make_floor(self)
	var a := WorldTestUtil.make_panel(self, &"drywall", Vector3(0, 0, 0))
	var b := WorldTestUtil.make_panel(self, &"drywall", Vector3(0, 0, 4))
	var crate := Destructible.new()
	crate.kind = &"crate"
	crate.surface = &"wood"
	crate.size = Vector3.ONE
	crate.break_energy_override = 600.0
	crate.position = Vector3(4, 0.5, 0)
	add_child(crate)
	var chair := RigidBody3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	mi.material_override = WorldMaterials.office_chair()
	chair.add_child(mi)
	add_child(chair)
	await get_tree().physics_frame
	var ga := a.get_node("Intact") as MeshInstance3D
	var gb := b.get_node("Intact") as MeshInstance3D
	WorldMaterials.set_view_fade(a, 0.6)
	WorldMaterials.set_view_fade(crate, 0.4)
	WorldMaterials.set_view_fade(chair, 0.5)
	var pa: float = ga.get_instance_shader_parameter(&"view_fade")
	var pb: Variant = gb.get_instance_shader_parameter(&"view_fade")
	var shared := ga.material_override == gb.material_override
	var crate_p: float = (crate.get_node("Intact") as MeshInstance3D).get_instance_shader_parameter(&"view_fade")
	var chair_t := mi.transparency
	var fade_ok := is_equal_approx(pa, 0.6) and (pb == null or is_zero_approx(float(pb))) and shared \
		and is_equal_approx(crate_p, 0.4) and chair_t > 0.3 and is_zero_approx(ga.transparency)
	print("[fade] panel dither=%.2f, other panel=%s, material still shared=%s, crate=%.2f, chair transparency=%.2f -> %s" % [
		pa, pb, shared, crate_p, chair_t, _pf(fade_ok)])
	_ok = _ok and fade_ok
	# Chunks of a broken panel fade too.
	a.receive_impact(5000.0, a.global_position + Vector3(0.125, 0, 0), Vector3(-10, 0, 0))
	await get_tree().physics_frame
	var chunk: RigidBody3D = a.last_chunks[0]
	WorldMaterials.set_view_fade(chunk, 0.7)
	var cmi := chunk.get_child(0) as MeshInstance3D
	var chunk_ok := is_equal_approx(float(cmi.get_instance_shader_parameter(&"view_fade")), 0.7)
	print("[fade] debris chunk dither=%.2f -> %s" % [float(cmi.get_instance_shader_parameter(&"view_fade")), _pf(chunk_ok)])
	_ok = _ok and chunk_ok
	# 0 restores.
	WorldMaterials.set_view_fade(a, 0.0)
	WorldMaterials.set_view_fade(chair, 0.0)
	var restore_ok := is_zero_approx(float(ga.get_instance_shader_parameter(&"view_fade"))) and is_zero_approx(mi.transparency)
	print("[fade] restore: panel=%.2f chair=%.2f -> %s" % [float(ga.get_instance_shader_parameter(&"view_fade")),
		mi.transparency, _pf(restore_ok)])
	_ok = _ok and restore_ok
	# Static world materials keep the shader without the fade path.
	var static_ok := WorldMaterials.concrete().shader == WorldMaterials.shader() \
		and WorldMaterials.panel(&"brick").shader == WorldMaterials.fade_shader() \
		and not WorldMaterials.shader().code.contains("#define VIEW_FADE")
	print("[fade] static concrete uses the plain shader, panels the fade variant -> %s" % _pf(static_ok))
	_ok = _ok and static_ok
	# Cost: 1,000 calls with changing amounts.
	var t0 := Time.get_ticks_usec()
	for i in 1000:
		WorldMaterials.set_view_fade(b, float(i % 10) / 10.0)
	print("[fade] 1000 calls: %d us" % (Time.get_ticks_usec() - t0))
	print("[fade] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _pf(v: bool) -> String:
	return "PASS" if v else "FAIL"
