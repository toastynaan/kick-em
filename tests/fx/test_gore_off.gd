extends Node3D
## Gore OFF: every decal is dust-coloured (none red), no pools, no stump
## sprays, no red droplets, and the wound mask uses dirt. Gore BLOOD brings
## back red decals and stump sprays. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	var saved_gore := Tuning.gore
	BloodFX.reset()
	U.make_floor(self)
	U.make_box(self, Vector3(0, 1.5, -3.0), Vector3(8, 3, 0.2), Layers.WORLD)
	var panel := U.make_box(self, Vector3(4, 1.5, 0), Vector3(0.2, 3, 3), Layers.DESTRUCTIBLE)
	panel.add_to_group(&"destructibles")
	var f := U.make_fighter(self, Vector3(0, 0, -1.5))
	var chest_part: MeshInstance3D = f.rig.get_mesh_parts()[2]
	await U.physics_frames(get_tree(), 2)

	Tuning.gore = Tuning.Gore.OFF
	_fire_everything(f, panel)
	await get_tree().create_timer(2.2).timeout
	await U.drain(get_tree())
	var decals := BloodFX.get_decals()
	var red := 0
	var pools := 0
	for d: Decal in decals:
		if U.is_red(d.modulate):
			red += 1
		if BloodFX._pool_tex.has(d.texture_albedo):
			pools += 1
	var red_sprays := 0
	for e in BloodFX._sprays:
		if e.visible:
			red_sprays += 1
	var dirt: Color = (chest_part.material_override as ShaderMaterial).get_shader_parameter(&"blood_color")
	print("gore OFF: %d decals, %d red, %d pools, %d stumps, %d red sprays, wound colour %s" % [
		decals.size(), red, pools, BloodFX.active_stumps(), red_sprays, dirt])
	if decals.is_empty():
		fails.append("gore OFF left no dust marks at all")
	if red > 0:
		fails.append("%d red decals with gore OFF" % red)
	if pools > 0:
		fails.append("%d pools with gore OFF" % pools)
	if BloodFX.active_stumps() > 0:
		fails.append("stump spray with gore OFF")
	if red_sprays > 0:
		fails.append("blood droplet sprays with gore OFF")
	if U.is_red(dirt):
		fails.append("wound mask still red with gore OFF")

	# Gore BLOOD: blood is back (stumps follow BLOOD and DISMEMBER alike).
	BloodFX.reset()
	Tuning.gore = Tuning.Gore.BLOOD
	var g := U.make_fighter(self, Vector3(-2, 0, -1.5))
	await get_tree().process_frame
	GameEvents.hit_landed.emit(U.hit(g, &"sparta_kick", g.global_position + Vector3(0, 1.35, 0.12),
			Vector3(0, 0, -1), 60.0, 4000.0, &"strike", HitInfo.Tier.LAUNCH))
	GameEvents.limb_severed.emit(g, &"head", null)
	await U.drain(get_tree())
	red = 0
	for d: Decal in BloodFX.get_decals():
		if U.is_red(d.modulate):
			red += 1
	print("gore BLOOD: %d red decals, %d stumps" % [red, BloodFX.active_stumps()])
	if red == 0:
		fails.append("no red decals with gore BLOOD")
	if BloodFX.active_stumps() != 1:
		fails.append("expected one stump spray with gore BLOOD, got %d" % BloodFX.active_stumps())

	Tuning.gore = saved_gore
	U.finish(get_tree(), "test_gore_off", fails, errlog)

func _fire_everything(f: Node3D, panel: Node3D) -> void:
	var chest := f.global_position + Vector3(0, 1.35, 0.12)
	GameEvents.hit_landed.emit(U.hit(f, &"sparta_kick", chest, Vector3(0, 0, -1), 60.0, 4000.0,
			&"strike", HitInfo.Tier.KNOCKDOWN))
	GameEvents.hit_landed.emit(U.hit(f, &"back_kick", chest, Vector3(0, 0, -1), 90.0, 9000.0, &"counter",
			HitInfo.Tier.HARD_LAUNCH))
	f.hp = 400.0  # wounded: body impacts bleed (Round 5)
	f.com_velocity = Vector3(0, -2, -8)
	GameEvents.body_impact.emit(f, Vector3(0, 1.0, -2.9), Vector3(0, 0, 1), 3500.0, &"concrete")
	GameEvents.body_impact.emit(f, Vector3(0, 0.0, -1.0), Vector3.UP, 2000.0, &"floor")
	GameEvents.wall_broken.emit(panel, Vector3(3.9, 1.2, 0), 5000.0, Vector3(10, 0, 0))
	f.com_velocity = Vector3.ZERO
	f.hp = 0.0
	GameEvents.fighter_died.emit(f, null)
	var piece := RigidBody3D.new()
	add_child(piece)
	piece.global_position = f.global_position + Vector3(0.3, 1.0, 0)
	GameEvents.limb_severed.emit(f, &"forearm_r", piece)
	BloodFX.stump(f.rig.get_attachment(Bones.CHEST), 1.0)
	BloodFX.pool(f.global_position, 1.2)
