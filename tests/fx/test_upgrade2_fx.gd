extends Node3D
## Upgrade 2 BloodFX: limb glow (handle, part emission, halo and light,
## timed / until freed / stop(), on the real rig too), set_fighter_fade, the
## U7 impact flash (sized by power, gone after a few frames), dust on floor and
## wall impacts, larger wounds on the player, the dazed swirl, stumble and trip
## dust. Round 7 removed zone aiming: aim_zone_changed no longer lights any
## part (the aimed-zone highlight is gone). OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	U.make_floor(self)
	var f := U.make_fighter(self, Vector3(0, 0, -1))
	f.add_to_group(&"fighters")
	await U.physics_frames(get_tree(), 2)

	# --- limb_glow -------------------------------------------------------------------
	var hand: MeshInstance3D = f.rig.get_bone_parts(Bones.R_HAND)[0]
	var hand_mat := hand.material_override as ShaderMaterial
	var red := Color(1.0, 0.13, 0.08)
	var g: Node3D = BloodFX.limb_glow(f, Bones.R_HAND, red, 0.0, 1.0)
	await get_tree().process_frame
	if g == null:
		fails.append("limb_glow returned null")
	else:
		if g.get_parent() != f.rig.get_attachment(Bones.R_HAND):
			fails.append("glow not on the bone's attachment")
		if g.global_position.distance_to(hand.global_position) > 0.05:
			fails.append("glow not centred on the hand mesh (%.3f m)" % g.global_position.distance_to(hand.global_position))
		if U.fparam(hand_mat, &"glow") <= 0.5:
			fails.append("hand part does not glow")
		if (hand_mat.get_shader_parameter(&"glow_color") as Color) != red:
			fails.append("wrong glow colour")
		var light := g.get_node(^"Light") as OmniLight3D
		if light == null or light.light_energy <= 0.5:
			fails.append("no light on the glow")
		var other := (f.rig.get_bone_parts(Bones.L_HAND)[0] as MeshInstance3D).material_override as ShaderMaterial
		if U.fparam(other, &"glow") > 0.0:
			fails.append("the other hand glows too")
		await get_tree().create_timer(0.5).timeout
		if not is_instance_valid(g):
			fails.append("duration <= 0 glow ended by itself")
		else:
			g.queue_free()
			await get_tree().process_frame
			if U.fparam(hand_mat, &"glow") != 0.0:
				fails.append("freeing the handle left the hand glowing")
	var timed: Node3D = BloodFX.limb_glow(f, Bones.R_FOOT, Color.WHITE, 0.2, 1.0)
	await get_tree().create_timer(0.35).timeout
	if is_instance_valid(timed):
		fails.append("timed glow outlived its duration")
	var stopped: Node3D = BloodFX.limb_glow(f, Bones.HEAD, Color(0.25, 0.6, 1.0), 0.0, 1.4)
	stopped.call(&"stop")
	await get_tree().create_timer(0.3).timeout
	if is_instance_valid(stopped):
		fails.append("stop() did not end the glow")
	print("limb_glow: live glows after the checks = %d" % BloodFX.active_glows())

	# --- set_fighter_fade -------------------------------------------------------------
	BloodFX.set_fighter_fade(f, 0.7)
	for p: MeshInstance3D in f.rig.get_mesh_parts():
		if absf(U.part_param(p, &"view_fade") - 0.7) > 0.001:
			fails.append("view_fade not on every part")
			break
	BloodFX.set_fighter_fade(f, 0.0)
	if U.fparam(hand_mat, &"view_fade") != 0.0:
		fails.append("fade did not clear")

	# --- Round 7: no aimed-zone highlight ------------------------------------------------
	var player := U.make_fighter(self, Vector3(0, 0, 2))
	player.add_to_group(&"player")
	GameEvents.aim_zone_changed.emit(player, f, BodyZones.Zone.ARM_R)
	await U.physics_frames(get_tree(), 20)
	var lit := 0
	for p: MeshInstance3D in f.rig.get_mesh_parts():
		if U.part_param(p, &"highlight") > 0.0:
			lit += 1
	print("aim_zone_changed (zone aiming removed): %d parts highlighted, BloodFX has set_zone_highlight %s" % [
		lit, BloodFX.has_method(&"set_zone_highlight")])
	if lit != 0 or BloodFX.has_method(&"set_zone_highlight"):
		fails.append("the removed zone highlight still lights parts")
	GameEvents.aim_zone_changed.emit(player, null, BodyZones.Zone.TORSO)

	# --- impact flash (Round 5: sized by tier) -----------------------------------------
	var jab := U.hit(f, &"jab1", Vector3(0, 1.4, -0.85), Vector3(0, 0, -1), 15.0, 140.0, &"strike",
			HitInfo.Tier.FLINCH)
	GameEvents.hit_landed.emit(jab)
	var small := BloodFX._impact_nodes[(BloodFX._impact_next + BloodFX.IMPACT_POOL - 1) % BloodFX.IMPACT_POOL] as MeshInstance3D
	var small_scale := small.scale.x
	var big := U.hit(f, &"power_punch", Vector3(0, 1.3, -0.85), Vector3(0, 0, -1), 120.0, 11000.0, &"strike",
			HitInfo.Tier.SEVER)
	big.charge_level = 3
	GameEvents.hit_landed.emit(big)
	var bigq := BloodFX._impact_nodes[(BloodFX._impact_next + BloodFX.IMPACT_POOL - 1) % BloodFX.IMPACT_POOL] as MeshInstance3D
	print("impact flash: flinch %.2f m, severing launch %.2f m, live %d" % [small_scale, bigq.scale.x, BloodFX.active_impact_flashes()])
	if BloodFX.active_impact_flashes() != 2 or not bigq.visible:
		fails.append("hits made no impact flash")
	if bigq.global_position.distance_to(big.hit_position) > 0.001:
		fails.append("flash not at the contact point")
	if bigq.scale.x < small_scale * 2.5:
		fails.append("flash not sized by tier")
	await get_tree().create_timer(0.25).timeout
	if BloodFX.active_impact_flashes() != 0:
		fails.append("impact flash lasted too long")

	# --- dust on floor and wall impacts ----------------------------------------------
	var d0: int = BloodFX._dust_next
	GameEvents.body_impact.emit(f, Vector3(0, 0, -1), Vector3.UP, 400.0, &"concrete")
	if BloodFX._dust_next != d0:
		fails.append("dust below Tuning.IMPACT_MIN_ENERGY")
	GameEvents.body_impact.emit(f, Vector3(0, 0, -1), Vector3.UP, 1500.0, &"concrete")
	var puff := BloodFX._puffs[d0] as GPUParticles3D
	var chips := BloodFX._chips[d0] as GPUParticles3D
	if BloodFX._dust_next == d0 or not puff.visible:
		fails.append("no dust burst on a floor impact")
	GameEvents.body_impact.emit(f, Vector3(0, 1, -2.9), Vector3.BACK, 1500.0, &"drywall")
	if BloodFX._dust_next == (d0 + 1) % BloodFX.DUST_POOL:
		fails.append("no dust burst on a wall impact")
	print("impact dust: chips on a soft floor hit %s" % chips.visible)

	# --- blood on the player -----------------------------------------------------------
	BloodFX.reset()
	var hit_e := U.hit(f, &"e_hook", f.global_position + Vector3(0, 1.35, 0.12), Vector3(0, 0, -1), 60.0, 200.0,
			&"strike", HitInfo.Tier.STAGGER)
	var hit_p := U.hit(player, &"e_hook", player.global_position + Vector3(0, 1.35, 0.12), Vector3(0, 0, -1), 60.0, 200.0,
			&"strike", HitInfo.Tier.STAGGER)
	GameEvents.hit_landed.emit(hit_e)
	GameEvents.hit_landed.emit(hit_p)
	var re: Array = BloodFX.get_wound_points(f.rig.get_bone_parts(Bones.CHEST)[0])
	var rp: Array = BloodFX.get_wound_points(player.rig.get_bone_parts(Bones.CHEST)[0])
	if re.is_empty() or rp.is_empty():
		fails.append("wounds missing (enemy %d, player %d)" % [re.size(), rp.size()])
	else:
		print("wound radius: enemy %.3f, player %.3f" % [(re[0] as Vector4).w, (rp[0] as Vector4).w])
		if (rp[0] as Vector4).w < (re[0] as Vector4).w * 1.3:
			fails.append("player wounds not drawn larger")

	# --- dazed swirl, stumble and trip dust -------------------------------------------
	GameEvents.dazed.emit(f, 0.5)
	await get_tree().process_frame
	var swirl: Node3D = null
	for s: Node3D in BloodFX._swirls:
		if s.visible:
			swirl = s
	print("dazed: swirls %d" % BloodFX.active_swirls())
	if BloodFX.active_swirls() != 1 or swirl == null:
		fails.append("no dazed swirl")
	elif swirl.global_position.y < f.rig.get_bone_global_position(Bones.HEAD).y + 0.2:
		fails.append("swirl not above the head")
	GameEvents.dazed.emit(f, 0.5)
	if BloodFX.active_swirls() != 1:
		fails.append("re-dazing stacked a second swirl")
	await get_tree().create_timer(0.7).timeout
	if BloodFX.active_swirls() != 0:
		fails.append("swirl outlived the daze")
	var d1: int = BloodFX._dust_next
	GameEvents.stumbled.emit(f, 0.6)
	GameEvents.tripped.emit(f)
	if BloodFX._dust_next != (d1 + 2) % BloodFX.DUST_POOL:
		fails.append("stumble / trip made no dust")
	GameEvents.arm_broken.emit(f, BodyZones.Zone.ARM_R)

	# --- the real rig ------------------------------------------------------------------
	var real := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis(), Vector3(-3, 0.1, 1)))
	await U.physics_frames(get_tree(), 5)
	if real.rig and not real.rig.get_mesh_parts().is_empty():
		var rg: Node3D = BloodFX.limb_glow(real, Bones.R_HAND, Color.WHITE, 0.0, 1.0)
		await get_tree().process_frame
		var hand_pos: Vector3 = real.rig.get_bone_global_position(Bones.R_HAND)
		print("real rig glow: %s, %.3f m from the wrist" % [rg != null, rg.global_position.distance_to(hand_pos) if rg else -1.0])
		if rg == null or rg.global_position.distance_to(hand_pos) > 0.2:
			fails.append("real rig: glow missing or off the hand")
		if rg != null:
			rg.queue_free()
		BloodFX.set_fighter_fade(real, 0.5)
		await U.physics_frames(get_tree(), 5)
		BloodFX.set_fighter_fade(real, 0.0)
	else:
		print("note: real HumanoidRig has no parts; skipped")
	U.finish(get_tree(), "test_upgrade2_fx", fails, errlog)
