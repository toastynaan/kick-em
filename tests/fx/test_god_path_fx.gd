extends Node3D
## God path effects (docs/Round 7 — Freeflow Combat.md, Amendment and God path:
## what Round 7 keeps and adds for the upgraded player). Each on its event's
## physics frame:
## - teleport (counter): the zap, and an after-image of the player's pose at
##   the vanish point that fades over Tuning.AFTERIMAGE_FADE; a pursuit
##   teleport and the pursuit: the zap (quieter, higher) and the full-speed
##   blur (test_speed_fx measures its fade);
## - pursuit spike (B's shockwave with no knockdown radius): a big floor boom
##   with the crumble and a low thump, a big flash with a shock ring, a dust ring
##   over the blast radius, a dust burst with chips, debris chunks and a
##   streak; a heavy landing's shockwave adds none of that (the landing has its own);
## - Battering Ram: the impact and the flash grow with the result, and the
##   level-3 launch is the heaviest: the launch impact with a boom, the biggest
##   and brightest flash, a shock ring;
## - footstep cracks at speed: a level-1 floor crack on a footstep's frame
##   under the foot plays a small crunch on the step instead of the big crack
##   (the mark is still drawn); any other crack keeps the crack.
## Parkour, the wall run, landings and the air dash: test_landing_fx and
## test_speed_fx. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")
const FreeflowFX := preload("res://scripts/fx/freeflow_fx.gd")

var played: Array = []   ## [id, physics frame]

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	ScreenFX.reset()
	U.make_floor(self)
	if not await U.wait_audio(get_tree()):
		fails.append("AudioFX never finished synthesising")
	AudioFX.sound_played.connect(func(id: StringName, _p: Vector3) -> void: played.append([id, Engine.get_physics_frames()]))
	var player := U.make_fighter(self, Vector3(0, 0, 1.2))
	player.add_to_group(&"player")
	player.add_to_group(&"fighters")
	var enemy := U.make_fighter(self, Vector3(0, 0, -0.3))
	enemy.add_to_group(&"fighters")
	var ff: Node = BloodFX.get_freeflow_fx()
	var wfx: Node = BloodFX.get_world_fx()
	var dm := get_node_or_null(^"/root/DebrisManager")
	await U.physics_frames(get_tree(), 2)
	ScreenFX.set(&"_player_poll", 0.0)
	await get_tree().process_frame

	# --- Teleport: the zap and the after-image at the vanish point ---------------------
	var vanish := player.global_position
	player.rig.get_attachment(Bones.R_UPPER_ARM).rotation_degrees = Vector3(70, 0, 0)  # a pose to copy
	player.global_position = Vector3(0, 0, -1.5)  # appeared behind the enemy
	var parts: Array[MeshInstance3D] = player.rig.get_mesh_parts()
	played.clear()
	var frame := Engine.get_physics_frames()
	GameEvents.teleported.emit(player, vanish, player.global_position, &"counter")
	var t_ids := _ids_on(frame)
	await get_tree().process_frame
	var ghost: Node3D = null
	for g: Node3D in ScreenFX._ghosts:
		if g.visible:
			ghost = g
	if ghost == null:
		fails.append("no teleport after-image")
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
		await get_tree().create_timer(Tuning.AFTERIMAGE_FADE * 0.5).timeout
		var mid_fade := float(ghost.get_child(0).get(&"instance_shader_parameters/fade"))
		await get_tree().create_timer(Tuning.AFTERIMAGE_FADE * 0.5 + 0.05).timeout
		print("TELEPORT CHECK: sounds %s; after-image %d of %d parts at the vanish point within %.4f m / %.4f rad; fade %.2f at half time, showing %d after %.2f s" % [
			t_ids, copies, parts.size(), err, rot_err, mid_fade, ScreenFX.active_afterimages(), Tuning.AFTERIMAGE_FADE + 0.05])
		if copies != parts.size() or err > 0.001 or rot_err > 0.001:
			fails.append("teleport after-image pose wrong")
		if mid_fade <= 0.05 or mid_fade >= 0.9 or ScreenFX.active_afterimages() != 0:
			fails.append("teleport after-image does not fade over AFTERIMAGE_FADE")
	if t_ids != [&"teleport"]:
		fails.append("teleport played %s" % [t_ids])
	player.global_position = Vector3(0, 0, 1.2)
	player.rig.get_attachment(Bones.R_UPPER_ARM).rotation_degrees = Vector3.ZERO
	# Pursuit: the pursuit event and its teleport both zap; the teleport blurs at full speed.
	await U.physics_frames(get_tree(), 12)
	played.clear()
	frame = Engine.get_physics_frames()
	GameEvents.pursuit.emit(player, enemy)
	var p_ids := _ids_on(frame)
	await U.physics_frames(get_tree(), 12)
	played.clear()
	frame = Engine.get_physics_frames()
	GameEvents.teleported.emit(player, player.global_position, player.global_position + Vector3(0, 1, -3), &"pursuit")
	var pt_ids := _ids_on(frame)
	await get_tree().process_frame
	await get_tree().process_frame
	var blur := ScreenFX.get_blur_strength()
	print("PURSUIT CHECK: pursuit %s, pursuit teleport %s, blur %.2f" % [p_ids, pt_ids, blur])
	if p_ids != [&"teleport"] or pt_ids != [&"teleport"] or blur < 0.5:
		fails.append("pursuit zap / blur missing")

	# --- Pursuit spike ------------------------------------------------------------------
	await U.physics_frames(get_tree(), 60)
	var spot := Vector3(2, 0, -2)
	played.clear()
	frame = Engine.get_physics_frames()
	var c0: Dictionary = wfx.get(&"counts").duplicate()
	var ff0: int = ff.get(&"effect_log").size()
	var impact_i: int = BloodFX._impact_next
	var dust_i: int = BloodFX._dust_next
	var debris0: int = dm.call(&"count") if dm != null else 0
	GameEvents.shockwave.emit(player, spot, Tuning.R7_SPIKE_BLAST_RADIUS, 0.0)
	var s_ids := _ids_on(frame)
	var s_db: Array = AudioFX.round7_sounds.back()["db"]
	var spiked := _logged(ff, ff0, &"spike", frame)
	var flashes := (BloodFX._impact_next - impact_i + BloodFX.IMPACT_POOL) % BloodFX.IMPACT_POOL
	var nodes: Array = BloodFX.last_impact_nodes()
	var ring_on: bool = (nodes[1] as MeshInstance3D).visible
	var bright := BloodFX.last_impact_brightness()
	var chips_on: bool = (BloodFX._chips[dust_i] as GPUParticles3D).visible
	var wd := _diff(wfx, c0)
	var ring_r: float = wfx.get(&"last").get(&"dust_ring", 0.0)
	var debris_added: int = (dm.call(&"count") if dm != null else 0) - debris0
	print("SPIKE CHECK: sounds %s (%s dB), flash %d (%.2f m, brightness %.2f, ring %s), chips %s, world %s, dust ring %.1f m, debris +%d" % [
		s_ids, s_db, flashes, (nodes[0] as MeshInstance3D).scale.x, bright, ring_on, chips_on, wd, ring_r, debris_added])
	for id in [&"boom", &"land_heavy", &"thump_low"]:
		if not s_ids.has(id):
			fails.append("spike: no %s on the event frame" % id)
	if not spiked or flashes != 1 or not ring_on or bright < FreeflowFX.SPIKE_BRIGHT - 0.01 or not chips_on:
		fails.append("spike flash / ring / chips missing")
	if wd.get(&"dust_ring", 0) != 1 or absf(ring_r - Tuning.R7_SPIKE_BLAST_RADIUS) > 0.001 or wd.get(&"streak", 0) != 1 \
			or wd.get(&"debris", 0) < FreeflowFX.SPIKE_DEBRIS.x or (dm != null and debris_added != wd.get(&"debris", 0)):
		fails.append("spike dust ring / streak / debris wrong: %s" % [wd])
	# A heavy landing's shockwave is the landing's business.
	await U.physics_frames(get_tree(), 60)
	played.clear()
	frame = Engine.get_physics_frames()
	ff0 = ff.get(&"effect_log").size()
	impact_i = BloodFX._impact_next
	GameEvents.shockwave.emit(player, spot, Tuning.SHOCK_STUMBLE_RADIUS, Tuning.SHOCK_KNOCKDOWN_RADIUS)
	# (WorldDamage blasts on any shockwave: its world_blast thump is not the spike's.)
	var l_ids := _ids_on(frame)
	print("heavy landing shockwave: sounds %s, spike effects %s, flashes %d" % [l_ids, _logged(ff, ff0, &"spike", frame),
		(BloodFX._impact_next - impact_i + BloodFX.IMPACT_POOL) % BloodFX.IMPACT_POOL])
	if l_ids.has(&"boom") or l_ids.has(&"land_heavy") or _logged(ff, ff0, &"spike", frame) or BloodFX._impact_next != impact_i:
		fails.append("a landing shockwave made spike effects")

	# --- Battering Ram: the launch is the heaviest ----------------------------------------
	var ram := {}
	for res: StringName in [&"stumble", &"knockdown", &"launch"]:
		await U.physics_frames(get_tree(), 40)
		played.clear()
		frame = Engine.get_physics_frames()
		GameEvents.rammed.emit(player, enemy, res, &"none")
		var r_last: Array = wfx.get(&"last").get(&"ram", [])
		var rn: Array = BloodFX.last_impact_nodes()
		ram[res] = {"ids": _ids_on(frame), "flash": (rn[0] as MeshInstance3D).scale.x, "bright": BloodFX.last_impact_brightness(),
			"ring": r_last[2] if r_last.size() > 2 else false}
		print("RAM CHECK %s: sounds %s, flash %.2f m at brightness %.2f, ring %s" % [res, ram[res]["ids"], ram[res]["flash"],
			ram[res]["bright"], ram[res]["ring"]])
	if ram[&"stumble"]["ids"] != [&"impact_stagger"] or ram[&"knockdown"]["ids"] != [&"impact_knockdown"] \
			or ram[&"launch"]["ids"] != [&"impact_launch", &"boom"]:
		fails.append("ram sounds wrong")
	if not (ram[&"launch"]["flash"] > ram[&"knockdown"]["flash"] and ram[&"knockdown"]["flash"] > ram[&"stumble"]["flash"]) \
			or ram[&"launch"]["bright"] <= ram[&"knockdown"]["bright"] or not ram[&"launch"]["ring"] or ram[&"knockdown"]["ring"]:
		fails.append("ram flash does not grow to the launch")

	# --- Footstep cracks at speed ---------------------------------------------------------------
	await U.physics_frames(get_tree(), 12)
	var marks0: int = BloodFX.get_decal_counts()["marks_created"]
	played.clear()
	frame = Engine.get_physics_frames()
	var foot := Vector3(4, 0, 4)
	GameEvents.footstep.emit(player, foot, &"concrete", 1.0)
	GameEvents.floor_damaged.emit(foot + Vector3(0.2, 0, 0.15), Tuning.FLOOR_LEVEL_RADIUS[0], 1, &"concrete")
	var fc_ids := _ids_on(frame)
	await U.physics_frames(get_tree(), 12)
	played.clear()
	var frame2 := Engine.get_physics_frames()
	GameEvents.floor_damaged.emit(Vector3(-4, 0, 4), Tuning.FLOOR_LEVEL_RADIUS[0], 1, &"concrete")  # no footstep
	var lone_ids := _ids_on(frame2)
	await U.physics_frames(get_tree(), 12)
	played.clear()
	var frame3 := Engine.get_physics_frames()
	GameEvents.footstep.emit(player, Vector3(6, 0, 4), &"concrete", 1.0)
	GameEvents.floor_damaged.emit(Vector3(9, 0, 4), Tuning.FLOOR_LEVEL_RADIUS[0], 1, &"concrete")  # far from the foot
	var far_ids := _ids_on(frame3)
	var marks: int = BloodFX.get_decal_counts()["marks_created"] - marks0
	print("CRACK CHECK: footstep + crack under it %s; a crack with no footstep %s; a footstep with a crack 3 m away %s; floor marks +%d" % [
		fc_ids, lone_ids, far_ids, marks])
	if not (fc_ids.has(&"step") and fc_ids.has(&"step_crunch")) or fc_ids.has(&"crack"):
		fails.append("footstep crack not a crunch on the step: %s" % [fc_ids])
	if lone_ids != [&"crack"] or not far_ids.has(&"crack") or far_ids.has(&"step_crunch"):
		fails.append("other cracks lost their crack sound")
	if marks != 3:
		fails.append("floor marks +%d, want 3 (the mark is DestructionFX's either way)" % marks)
	U.finish(get_tree(), "test_god_path_fx", fails, errlog)

## Sound ids played on `frame`, in order.
func _ids_on(frame: int) -> Array:
	return played.filter(func(p: Array) -> bool: return p[1] == frame).map(func(p: Array) -> StringName: return p[0])

static func _logged(ff: Node, from: int, event: StringName, frame: int) -> bool:
	var log: Array = ff.get(&"effect_log")
	for k in range(from, log.size()):
		if log[k]["event"] == event and log[k]["frame"] == frame:
			return true
	return false

static func _diff(wfx: Node, before: Dictionary) -> Dictionary:
	var out := {}
	var now: Dictionary = wfx.get(&"counts")
	for k in now:
		var d := int(now[k]) - int(before.get(k, 0))
		if d != 0:
			out[k] = d
	return out
