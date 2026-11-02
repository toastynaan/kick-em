extends Node3D
## Round 4: BloodFX.set_fighter_fade on the player (the camera fades the
## player when walls push it close). Fade the real player to 0.75 and back to
## 0: every part's view_fade follows, the materials, shadow casting and render
## priority never change, 0 restores an exact 0, repeated calls allocate
## nothing, and a glow on the faded player fades with it. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	U.make_floor(self)
	var player := FighterFactory.spawn_player(self, Transform3D(Basis(), Vector3(0, 0.1, 0)))
	await U.physics_frames(get_tree(), 5)
	var parts: Array[MeshInstance3D] = player.rig.get_mesh_parts() if player.rig else ([] as Array[MeshInstance3D])
	if parts.is_empty():
		print("note: the real rig has no parts; using the fake fighter")
		var fake := U.make_fighter(self, Vector3(2, 0, 0))
		fake.add_to_group(&"player")
		player = fake
		parts = fake.rig.get_mesh_parts()
	# Blood on the player first, so the fade must cover wounds too.
	GameEvents.hit_landed.emit(U.hit(player, &"e_hook", player.global_position + Vector3(0, 1.35, -0.15),
			Vector3(0, 0, 1), 60.0, 200.0))
	var before_mats: Array = []
	var before_shadow: Array = []
	var before_prio: Array = []
	for p in parts:
		before_mats.append(p.material_override)
		before_shadow.append(p.cast_shadow)
		before_prio.append((p.material_override as Material).render_priority if p.material_override else 0)

	BloodFX.set_fighter_fade(player, 0.75)
	var wrong := 0
	for p in parts:
		if absf(U.part_param(p, &"view_fade") - 0.75) > 0.0001:
			wrong += 1
	print("fade 0.75: %d of %d parts wrong" % [wrong, parts.size()])
	if wrong > 0:
		fails.append("%d parts not faded" % wrong)
	if absf(BloodFX.get_fighter_fade(player) - 0.75) > 0.0001:
		fails.append("get_fighter_fade does not report 0.75")

	# A charge glow on the faded player is dimmed, not floating at full strength.
	var g: Node3D = BloodFX.limb_glow(player, Bones.R_HAND, Color.WHITE, 0.0, 1.0)
	await get_tree().process_frame
	var faded_light := (g.get_node(^"Light") as OmniLight3D).light_energy if g else -1.0

	# Repeated calls every frame: no new objects, one cached material list.
	# (AudioFX's worker thread adds streams until every variant is built: wait.)
	await U.wait_audio(get_tree(), 240000, true)
	var objs0 := Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in 600:
		BloodFX.set_fighter_fade(player, 0.6 + 0.15 * float(i % 3) / 2.0)
		if i % 60 == 0:
			await get_tree().process_frame
	var objs1 := Performance.get_monitor(Performance.OBJECT_COUNT)
	print("600 fade calls: objects %d -> %d, cached lists %d" % [objs0, objs1, BloodFX._fade_mats.size()])
	if objs1 > objs0 + 2:
		fails.append("fade calls allocate objects (%d -> %d)" % [objs0, objs1])
	if BloodFX._fade_mats.size() != 1:
		fails.append("material cache has %d entries, want 1" % BloodFX._fade_mats.size())
	BloodFX.set_fighter_fade(player, 0.75)

	# Back to 0: exact restore, nothing swapped.
	BloodFX.set_fighter_fade(player, 0.0)
	await get_tree().process_frame
	var full_light := (g.get_node(^"Light") as OmniLight3D).light_energy if g else -1.0
	print("glow light: faded %.2f, unfaded %.2f" % [faded_light, full_light])
	if g == null or faded_light > full_light * 0.4:
		fails.append("glow not dimmed with the faded player")
	for i in parts.size():
		var p := parts[i]
		if U.part_param(p, &"view_fade") != 0.0:
			fails.append("view_fade not exactly 0 on %s" % p.name)
			break
		if p.material_override != before_mats[i] or p.cast_shadow != before_shadow[i] \
				or (p.material_override as Material).render_priority != before_prio[i]:
			fails.append("material / shadow / priority changed on %s" % p.name)
			break
	if BloodFX._fade_mats.size() != 0 or BloodFX.get_fighter_fade(player) != 0.0:
		fails.append("fade state not cleared at 0")
	if not BloodFX.get_wound_points(BloodFX._bone_parts(player, Bones.CHEST)[0]).size() > 0 \
			and BloodFX.get_wound_points(BloodFX._bone_parts(player, Bones.SPINE)[0]).size() == 0:
		print("note: the hit painted no chest/spine wound")
	if g:
		g.queue_free()
	# Same amount twice is a no-op; 0 after a tiny amount writes an exact 0.
	BloodFX.set_fighter_fade(player, 0.003)
	BloodFX.set_fighter_fade(player, 0.0)
	if U.part_param(parts[0], &"view_fade") != 0.0:
		fails.append("a tiny fade did not return to exactly 0")
	U.finish(get_tree(), "test_player_fade", fails, errlog)
