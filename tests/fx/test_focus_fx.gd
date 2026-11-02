extends Node3D
## F5 / F6 effects (Feel Reference: Parry, Teleport, Focus; Screen effects >
## Focus tint; On the character > After-image): a parry flashes white between
## the fighters with sparks and a deflect sound; a mashed Block ticks; a
## teleport leaves an after-image of the player's pose at the vanish point
## that fades over Tuning.AFTERIMAGE_FADE; a sidestep whooshes and kicks dust.
## Focus tint: ramps in over Tuning.SLOWMO_EASE while TimeDirector Focus is on,
## at Tuning.FOCUS_SATURATION; the player's materials and every glowing limb
## (enemy wind-up tells) keep full colour through the stencil mask while the
## rest of the enemy does not; glows are never dimmed; the player gets a rim
## glow; everything is restored when Focus ends. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")

var played: Array[StringName] = []

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	ScreenFX.reset()
	U.make_floor(self)
	if not await U.wait_audio(get_tree()):
		fails.append("AudioFX never finished synthesising")
	AudioFX.sound_played.connect(func(id: StringName, _p: Vector3) -> void: played.append(id))
	var player := U.make_fighter(self, Vector3(0, 0, 1.2))
	player.add_to_group(&"player")
	player.add_to_group(&"fighters")
	var enemy := U.make_fighter(self, Vector3(0, 0, -0.3))
	enemy.add_to_group(&"fighters")
	await U.physics_frames(get_tree(), 2)
	ScreenFX.set(&"_player_poll", 0.0)
	await get_tree().process_frame

	# --- Parry ----------------------------------------------------------------------------
	played.clear()
	var flashes0 := BloodFX.active_impact_flashes()
	var spark0: int = BloodFX._spark_next
	GameEvents.parried.emit(player, enemy)
	var fl := BloodFX._impact_nodes[(BloodFX._impact_next + BloodFX.IMPACT_POOL - 1) % BloodFX.IMPACT_POOL] as MeshInstance3D
	var mid: Vector3 = (player.get_aim_point() as Vector3).lerp(enemy.get_aim_point(), 0.45)
	print("parry: flash %.2f m at %.2f m from the guard point, sparks %d, sounds %s" % [fl.scale.x,
		fl.global_position.distance_to(mid), (BloodFX._spark_next - spark0 + BloodFX.SPARK_POOL) % BloodFX.SPARK_POOL, played])
	if BloodFX.active_impact_flashes() <= flashes0 or fl.global_position.distance_to(mid) > 0.01 or fl.scale.x < 1.0:
		fails.append("parry flash missing or small")
	if BloodFX._spark_next == spark0:
		fails.append("parry made no sparks")
	if not played.has(&"parry"):
		fails.append("no deflect sound")
	await U.physics_frames(get_tree(), 6)
	played.clear()
	GameEvents.parry_whiffed.emit(player)
	if not played.has(&"miss"):
		fails.append("parry whiff made no tick")

	# --- Teleport after-image ---------------------------------------------------------------
	var vanish := player.global_position
	player.rig.get_attachment(Bones.R_UPPER_ARM).rotation_degrees = Vector3(70, 0, 0)  # a pose to copy
	player.global_position = Vector3(0, 0, -1.5)  # appeared behind the enemy
	var parts: Array[MeshInstance3D] = player.rig.get_mesh_parts()
	GameEvents.teleported.emit(player, vanish, player.global_position, &"counter")
	await get_tree().process_frame
	var ghost: Node3D = null
	for g: Node3D in ScreenFX._ghosts:
		if g.visible:
			ghost = g
	if ghost == null:
		fails.append("no after-image")
	else:
		var arm := player.rig.get_bone_parts(Bones.R_UPPER_ARM)[0] as MeshInstance3D
		var ghost_arm: MeshInstance3D = null
		for c: MeshInstance3D in ghost.get_children():
			if c.mesh == arm.mesh:
				ghost_arm = c
		var want := arm.global_transform.translated(vanish - player.global_position)
		var err := ghost_arm.global_transform.origin.distance_to(want.origin) if ghost_arm else 99.0
		var rot_err := ghost_arm.global_basis.get_euler().distance_to(want.basis.get_euler()) if ghost_arm else 99.0
		var copies := 0
		for c: MeshInstance3D in ghost.get_children():
			if c.visible:
				copies += 1
		print("after-image: %d of %d parts copied, arm at the vanish point within %.4f m / %.4f rad" % [
			copies, parts.size(), err, rot_err])
		if copies != parts.size() or err > 0.001 or rot_err > 0.001:
			fails.append("after-image pose wrong")
		await get_tree().create_timer(Tuning.AFTERIMAGE_FADE * 0.5).timeout
		var mid_fade := float(ghost.get_child(0).get(&"instance_shader_parameters/fade"))
		await get_tree().create_timer(Tuning.AFTERIMAGE_FADE * 0.5 + 0.05).timeout
		print("after-image fade: %.2f at half time, showing %d after %.2f s" % [mid_fade, ScreenFX.active_afterimages(),
			Tuning.AFTERIMAGE_FADE + 0.05])
		if mid_fade <= 0.05 or mid_fade >= 0.9 or ScreenFX.active_afterimages() != 0:
			fails.append("after-image does not fade over AFTERIMAGE_FADE")
	player.global_position = Vector3(0, 0, 1.2)

	# --- Sidestep -----------------------------------------------------------------------------
	played.clear()
	var dust0: int = BloodFX._dust_next
	GameEvents.sidestepped.emit(player, Vector3.RIGHT)
	if not played.has(&"sidestep") or BloodFX._dust_next == dust0:
		fails.append("sidestep: sounds %s, dust %s" % [played, BloodFX._dust_next != dust0])

	# --- Focus tint ----------------------------------------------------------------------------
	var tell: Node3D = BloodFX.limb_glow(enemy, Bones.R_HAND, Color(1.0, 0.5, 0.1), 0.0, 1.0)
	await get_tree().create_timer(0.2).timeout
	var tell_level_before: float = tell.call(&"get_level")
	# A glowing stick: emission on its own StandardMaterial3D (AIBrain's), in
	# group &"focus_keep_color" (lead review: non-limb glows are never dimmed).
	var stick := MeshInstance3D.new()
	var stick_mesh := BoxMesh.new()
	stick_mesh.size = Vector3(0.05, 0.05, 1.0)
	stick.mesh = stick_mesh
	var stick_mat := StandardMaterial3D.new()
	stick_mat.emission_enabled = true
	stick_mat.emission = Color(1.0, 0.5, 0.1)
	stick.material_override = stick_mat
	stick.add_to_group(&"focus_keep_color")
	add_child(stick)
	if not TimeDirector.begin_focus():
		fails.append("begin_focus refused")
	var ramp: Array[String] = []
	for i in 6:  # real time: Focus slows game-time timers to 0.3x
		await TimeDirector.real_timer(0.04).timeout
		ramp.append("%.2f" % ScreenFX.get_focus_amount())
	await TimeDirector.real_timer(0.1).timeout
	var tint_mat: ShaderMaterial = ScreenFX._tint_mat
	var kept := ScreenFX.kept_materials()
	var player_mats := _mats(player)
	var hand_mats: Array = []
	for p: MeshInstance3D in enemy.rig.get_bone_parts(Bones.R_HAND):
		hand_mats.append(p.material_override)
	var body_mats := _mats(enemy).filter(func(m: Material) -> bool: return not hand_mats.has(m))
	var player_kept := player_mats.all(func(m: Material) -> bool: return kept.has(m) and m.next_pass != null)
	var glow_kept := hand_mats.all(func(m: Material) -> bool: return kept.has(m) and m.next_pass != null)
	var body_free := body_mats.all(func(m: Material) -> bool: return not kept.has(m) and m.next_pass == null)
	var rim := U.fparam(player_mats[0], &"rim_glow")
	var tell_level_focus: float = tell.call(&"get_level")
	print("focus tint ramp (every 0.04 real s): %s; amount %.2f, saturation %.2f, quad %s" % [
		", ".join(ramp), ScreenFX.get_focus_amount(), U.fparam(tint_mat, &"saturation"), ScreenFX._tint_quad.visible])
	print("focus: kept %d materials: player %s, glowing hand %s, rest of the enemy free %s; player rim glow %.2f; tell glow %.2f -> %.2f" % [
		kept.size(), player_kept, glow_kept, body_free, rim, tell_level_before, tell_level_focus])
	if ScreenFX.get_focus_amount() < 0.999 or not ScreenFX._tint_quad.visible:
		fails.append("tint not fully on")
	if absf(U.fparam(tint_mat, &"saturation") - Tuning.FOCUS_SATURATION) > 0.001:
		fails.append("tint saturation not FOCUS_SATURATION")
	if float(ramp[0]) <= 0.0 or float(ramp[0]) >= 1.0:
		fails.append("tint does not ramp (%s)" % ramp[0])
	if not (player_kept and glow_kept and body_free):
		fails.append("keep-colour mask on the wrong materials")
	if rim < ScreenFX.FOCUS_RIM_GLOW - 0.01:
		fails.append("no player rim glow")
	if absf(tell_level_focus - tell_level_before) > 0.25 * tell_level_before:
		fails.append("Focus dimmed the tell glow")
	# A glow that starts during Focus keeps colour too.
	var late: Node3D = BloodFX.limb_glow(enemy, Bones.L_FOOT, Color(0.25, 0.6, 1.0), 0.0, 1.0)
	await get_tree().process_frame
	await get_tree().process_frame
	var foot_mat := (enemy.rig.get_bone_parts(Bones.L_FOOT)[0] as MeshInstance3D).material_override
	if not ScreenFX.kept_materials().has(foot_mat):
		fails.append("a glow started during Focus is not kept in colour")
	# A second stick joins the group mid-Focus, as a parent node with a mesh child.
	var holder := Node3D.new()
	var stick2 := MeshInstance3D.new()
	stick2.mesh = stick_mesh
	stick2.material_override = stick_mat
	holder.add_child(stick2)
	add_child(holder)
	holder.add_to_group(&"focus_keep_color")
	await get_tree().process_frame
	await get_tree().process_frame
	var kept_n := ScreenFX.kept_nodes()
	print("focus_keep_color: kept %d nodes; stick overlay is the mask %s, mid-Focus stick %s; stick material untouched %s" % [
		kept_n.size(), stick.material_overlay == ScreenFX._mask_mat, stick2.material_overlay == ScreenFX._mask_mat,
		stick_mat.next_pass == null])
	if not (kept_n.has(stick) and kept_n.has(stick2)) or stick.material_overlay != ScreenFX._mask_mat \
			or stick2.material_overlay != ScreenFX._mask_mat or stick_mat.next_pass != null:
		fails.append("focus_keep_color geometry not kept in colour")
	TimeDirector.end_focus()
	await get_tree().create_timer(Tuning.SLOWMO_EASE + 0.15).timeout
	var any_mask := false
	for m in _mats(player) + _mats(enemy):
		if (m as Material).next_pass != null:
			any_mask = true
	print("after Focus: amount %.2f, kept %d, masks left %s, rim %.2f" % [ScreenFX.get_focus_amount(),
		ScreenFX.kept_materials().size(), any_mask, U.fparam(player_mats[0], &"rim_glow")])
	if ScreenFX.get_focus_amount() != 0.0 or any_mask or ScreenFX._tint_quad.visible:
		fails.append("Focus tint not cleaned up")
	if stick.material_overlay != null or stick2.material_overlay != null or not ScreenFX.kept_nodes().is_empty():
		fails.append("focus_keep_color overlays not removed after Focus")
	if absf(U.fparam(player_mats[0], &"rim_glow") - ScreenFX.RIM_DEFAULT_GLOW) > 0.001:
		fails.append("rim glow not restored")
	tell.queue_free()
	late.queue_free()
	U.finish(get_tree(), "test_focus_fx", fails, errlog)

func _mats(f: Node3D) -> Array:
	var out: Array = []
	for p: MeshInstance3D in f.rig.get_mesh_parts():
		out.append(p.material_override)
	return out
