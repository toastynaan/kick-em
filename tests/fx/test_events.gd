extends Node3D
## Fires every GameEvents signal BloodFX and AudioFX listen to, with plausible
## and edge-case arguments (null attacker, zero vectors, freed fighters, a real
## rig's severed limb), and fails on any error raised in FX code. Also checks
## the arena particle-collision heightfield follows the "arena" group.
## OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	U.make_floor(self)
	U.make_box(self, Vector3(0, 1.5, -4.0), Vector3(10, 3, 0.2), Layers.WORLD)
	var panel := U.make_box(self, Vector3(5, 1.5, 0), Vector3(0.2, 3, 3), Layers.DESTRUCTIBLE)
	panel.add_to_group(&"destructibles")
	panel.set(&"surface", &"brick")
	var arena := Node3D.new()
	arena.name = "Arena"
	arena.add_to_group(&"arena")
	add_child(arena)

	var player := U.make_fighter(self, Vector3(0, 0, 2))
	player.add_to_group(&"fighters")
	player.add_to_group(&"player")
	var enemy := U.make_fighter(self, Vector3(0, 0, -1))
	enemy.add_to_group(&"fighters")
	enemy.add_to_group(&"enemies")
	var enemy2 := U.make_fighter(self, Vector3(2, 0, -1))
	enemy2.add_to_group(&"fighters")
	enemy2.add_to_group(&"enemies")
	var bare := Node3D.new()  # not a fighter at all
	add_child(bare)
	await U.physics_frames(get_tree(), 2)
	await U.wait_audio(get_tree())

	var chest := enemy.global_position + Vector3(0, 1.35, 0.12)
	var fwd := Vector3(0, 0, -1)
	# Combat
	for spec in [[&"jab1", &"strike", 15.0, 140.0], [&"sparta_kick", &"strike", 60.0, 2240.0],
			[&"power_punch", &"strike", 120.0, 11340.0], [&"power_punch", &"strike", 50.0, 560.0],
			[&"leg_sweep", &"strike", 30.0, 315.0], [&"back_kick", &"counter", 90.0, 8960.0],
			[&"e_hook", &"strike", 60.0, 219.0], [&"e_heavy", &"strike", 100.0, 2835.0],
			[&"grab", &"grab", 0.0, 0.0], [&"throw", &"throw", 40.0, 5040.0], [&"bowl", &"bowl", 30.0, 1600.0],
			[&"e_throw_debris", &"projectile", 50.0, 560.0]]:
		var h := U.hit(enemy, spec[0], chest, fwd, spec[2], spec[3], spec[1])
		h.attacker = player if spec[1] != &"bowl" else null
		GameEvents.hit_landed.emit(h)
		await get_tree().physics_frame
	var odd := U.hit(enemy, &"jab2", Vector3.ZERO, Vector3.ZERO, 0.0, 0.0)  # zero vectors
	GameEvents.hit_landed.emit(odd)
	var on_bare := U.hit(bare, &"jab1", Vector3(1, 1, 1), fwd, 15.0, 100.0)  # victim without a rig
	GameEvents.hit_landed.emit(on_bare)
	GameEvents.hit_blocked.emit(U.hit(player, &"e_hook", player.global_position + Vector3.UP * 1.3, Vector3.BACK, 12.0, 0.0))
	GameEvents.perfect_dodge.emit(player, enemy)
	GameEvents.teleport_counter.emit(player, enemy)
	GameEvents.pursuit.emit(player, enemy)
	GameEvents.air_recovery.emit(player)
	GameEvents.attack_tell.emit(enemy, &"strike", 0.45)
	GameEvents.attack_tell.emit(enemy2, &"grab", 0.5)
	for m in [&"jab1", &"sparta_kick", &"power_punch", &"e_heavy", &"e_grab", &"leg_sweep"]:
		GameEvents.attack_active.emit(enemy, m)
	GameEvents.attack_whiff.emit(enemy, &"e_hook")
	GameEvents.grab_started.emit(enemy, player)
	GameEvents.grab_broken.emit(enemy, player, false)
	GameEvents.grab_broken.emit(enemy, player, true)
	GameEvents.thrown.emit(player, enemy, Vector3(0, 3, -12))
	# World
	GameEvents.wall_cracked.emit(panel, Vector3(4.9, 1.2, 0), 3000.0)
	enemy.com_velocity = Vector3(9, -1, 0)
	GameEvents.body_impact.emit(enemy, Vector3(4.9, 1.2, 0), Vector3(-1, 0, 0), 4000.0, &"brick")
	GameEvents.body_impact.emit(enemy, Vector3(0, 0, -1), Vector3.UP, 1200.0, &"floor")
	GameEvents.body_impact.emit(enemy, Vector3(1, 1, -1), Vector3.BACK, 1600.0, &"body")
	GameEvents.body_impact.emit(enemy, Vector3(0, 1, -3.9), Vector3.BACK, 300.0, &"concrete")  # below threshold
	GameEvents.body_impact.emit(null, Vector3(0, 1, -3.9), Vector3.BACK, 2500.0, &"concrete")
	GameEvents.wall_broken.emit(panel, Vector3(4.9, 1.2, 0), 8000.0, Vector3(12, 0, 0))
	GameEvents.wall_broken.emit(null, Vector3(0, 1, -3.9), 2500.0, Vector3.ZERO)
	GameEvents.body_bowled.emit(enemy, enemy2, 1600.0, 2)
	# Fighters
	GameEvents.fighter_damaged.emit(enemy, 50.0, &"impact")
	GameEvents.fighter_launched.emit(enemy, Vector3(0, 2, -10))
	enemy.down = true
	enemy.com_velocity = Vector3.ZERO
	await get_tree().create_timer(1.7).timeout  # lying still -> pool
	enemy.hp = 0.0
	GameEvents.fighter_died.emit(enemy, null)
	var piece := RigidBody3D.new()
	add_child(piece)
	piece.global_position = enemy.global_position + Vector3(0, 1.7, 0)
	piece.linear_velocity = Vector3(2, 3, 1)
	for cut in Bones.CUTS:
		GameEvents.limb_severed.emit(enemy, cut, piece if cut == &"head" else null)
	GameEvents.limb_severed.emit(enemy, &"no_such_cut", null)
	GameEvents.limb_severed.emit(bare, &"head", null)
	enemy2.hp = 0.0
	GameEvents.fighter_died.emit(enemy2, null)  # last enemy
	player.hp = 0.0
	GameEvents.fighter_died.emit(player, null)
	GameEvents.fighter_died.emit(bare, null)
	# A stump whose body is freed mid-spray.
	await get_tree().create_timer(0.3).timeout
	enemy2.queue_free()
	GameEvents.limb_severed.emit(enemy2, &"forearm_l", null)
	# Round 5 signals, with edge cases (null fighters, zero vectors, odd kinds).
	var r5 := U.hit(enemy, &"kick", chest, fwd, 20.0, 0.0, &"strike", HitInfo.Tier.SEVER)
	r5.attacker = player
	r5.ground_strike = true
	GameEvents.hit_landed.emit(r5)
	var no_tier := U.hit(enemy, &"cross", chest, fwd, 8.0, 0.0)
	no_tier.power = 6.4  # power but no tier: FXRules maps it
	GameEvents.hit_landed.emit(no_tier)
	for args in [[player, enemy, &"jab1", false, 0], [player, null, &"sparta_kick", true, 3],
			[enemy, player, &"e_heavy", false, 0], [null, null, &"", false, 1], [player, enemy, &"no_such_move", true, 2]]:
		GameEvents.strike_started.emit(args[0], args[1], args[2], args[3], args[4])
	GameEvents.parried.emit(player, enemy)
	GameEvents.parried.emit(player, null)
	GameEvents.parried.emit(null, enemy)
	GameEvents.parry_whiffed.emit(player)
	GameEvents.parry_whiffed.emit(null)
	GameEvents.teleported.emit(player, Vector3(0, 0, 2), Vector3(0, 0, -2), &"counter")
	GameEvents.teleported.emit(player, Vector3.ZERO, Vector3.ZERO, &"pursuit")
	GameEvents.teleported.emit(null, Vector3.ZERO, Vector3.ONE, &"other")
	GameEvents.teleported.emit(bare, Vector3.ZERO, Vector3.ONE, &"counter")
	GameEvents.sidestepped.emit(player, Vector3.RIGHT)
	GameEvents.sidestepped.emit(player, Vector3.ZERO)
	GameEvents.sidestepped.emit(null, Vector3.LEFT)
	GameEvents.counter_bonus_changed.emit(player, 2.5)
	GameEvents.sprint_started.emit(player)
	GameEvents.sprint_started.emit(null)
	GameEvents.sprint_ended.emit(player)
	for surf in [&"concrete", &"water", &"metal", &"dirt", &"wood", &"", &"unknown"]:
		GameEvents.footstep.emit(player, Vector3(0, 0, 1), surf, 0.7)
	GameEvents.footstep.emit(null, Vector3.ZERO, &"water", 2.0)
	for kind in [&"step", &"vault", &"mantle", &"kickoff", &"air_mantle", &"bogus"]:
		GameEvents.parkour.emit(player, kind, Vector3(0, 1, -1), 1.0)
	GameEvents.parkour.emit(null, &"kickoff", Vector3.ZERO, 3.0)
	GameEvents.wall_run_started.emit(player, panel, -1)
	GameEvents.wall_run_started.emit(player, null, 1)
	GameEvents.wall_run_step.emit(player, Vector3(4.9, 1, 0), Vector3(-1, 0, 0))
	GameEvents.wall_run_step.emit(null, Vector3.ZERO, Vector3.ZERO)
	GameEvents.wall_run_ended.emit(player, &"jump")
	GameEvents.wall_run_ended.emit(null, &"time")
	for level in [&"soft", &"hard", &"heavy", &"weird"]:
		GameEvents.landing.emit(player, level, Vector3(1, 0, 1), 10.0)
	GameEvents.landing.emit(null, &"heavy", Vector3(-1, 0, 1), 0.0)
	GameEvents.shockwave.emit(player, Vector3.ZERO, 2.5, 1.0)
	GameEvents.rammed.emit(player, enemy, &"stumble", &"none")
	GameEvents.carry_changed.emit(player, enemy)
	GameEvents.carry_changed.emit(player, null)
	GameEvents.body_slammed.emit(player, enemy, Vector3(0, 0, -1))
	GameEvents.body_slammed.emit(null, null, Vector3.ZERO)
	GameEvents.prop_picked_up.emit(player, bare)
	GameEvents.prop_thrown.emit(player, bare, Vector3(0, 2, -10))
	GameEvents.prop_thrown.emit(null, null, Vector3.ZERO)
	for kind in [&"brick", &"bottle", &"chair_leg", &"crate_small", &"stick", &"limb", &""]:
		GameEvents.prop_broken.emit(null, Vector3(0, 0.3, 0), kind)
	GameEvents.wall_broken_by.emit(enemy, panel, 5000.0)
	GameEvents.fleeing_changed.emit(enemy, true)
	GameEvents.charge_started.emit(player, &"sparta_kick")
	GameEvents.charge_level_changed.emit(player, 2)
	GameEvents.charge_level_changed.emit(player, 9)
	GameEvents.charge_released.emit(player, &"sparta_kick", 2)
	GameEvents.charge_started.emit(null, &"jab1")
	GameEvents.charge_level_changed.emit(null, 1)
	GameEvents.charge_released.emit(null, &"jab1", 1)
	GameEvents.body_impact.emit(enemy, Vector3(0, 0, -1), Vector3.UP, 3000.0, &"water")
	GameEvents.focus_started.emit(player)
	GameEvents.focus_ended.emit(player)
	GameEvents.last_kill.emit(enemy)
	GameEvents.run_ended.emit({})
	# Round 6 signals, with edge cases (null nodes, unknown kinds, odd levels).
	for kind in Tuning.FURNITURE:
		GameEvents.furniture_broken.emit(null, Vector3(0, 0.5, 1), kind, 800.0, enemy)
	GameEvents.furniture_broken.emit(panel, Vector3(4.9, 1, 0), &"no_such_kind", 0.0, null)
	GameEvents.furniture_broken.emit(bare, Vector3.ZERO, &"glass", -5.0, bare)
	for kind in [&"overhead", &"panel", &"platform", &""]:
		GameEvents.structure_collapsed.emit(null, Vector3(0, 3, -2), kind)
	var piece2 := RigidBody3D.new()
	piece2.mass = 60.0
	add_child(piece2)
	GameEvents.debris_landed.emit(piece2, Vector3(0, 0.1, -2), 6.0, &"concrete")
	GameEvents.debris_landed.emit(null, Vector3.ZERO, 6.0, &"concrete")
	for level in [0, 1, 2, 3, 7]:
		GameEvents.floor_damaged.emit(Vector3(2, 0, 2), 0.0 if level == 0 else 0.8, level, &"concrete")
	for surf in [&"tile", &"water", &"metal", &"", &"glass"]:
		GameEvents.floor_damaged.emit(Vector3(-2, 0, 2), 0.6, 1, surf)
	GameEvents.world_blast.emit(Vector3.ZERO, 0.0, 0.0, &"slam")
	GameEvents.world_blast.emit(Vector3(1, 0, 1), 2.5, 50000.0, &"structure")
	GameEvents.world_blast.emit(Vector3(1, 0, 1), -1.0, -100.0, &"")
	await U.physics_frames(get_tree(), 10)
	# Flow
	GameEvents.round_started.emit(&"duel")
	GameEvents.wave_started.emit(0, 4)
	GameEvents.wave_cleared.emit(0)
	GameEvents.round_over.emit(false)
	GameEvents.screen_shake.emit(0.5)
	GameEvents.focus_changed.emit(player, 1.0)
	await get_tree().create_timer(2.5).timeout
	await U.drain(get_tree())
	print("after events: %d decals, %d stumps" % [BloodFX.decal_count(), BloodFX.active_stumps()])
	if BloodFX.decal_count() == 0:
		fails.append("events left no decals")

	# The real rig: sever a limb and let the stump follow the body-side attachment.
	var real := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis(), Vector3(-3, 0.1, 1)))
	await U.physics_frames(get_tree(), 5)
	if real.rig and not real.rig.get_mesh_parts().is_empty():
		var rh := U.hit(real, &"sparta_kick", real.get_aim_point(), fwd, 60.0, 3000.0)
		rh.attacker = player
		GameEvents.hit_landed.emit(rh)
		var real_piece := real.rig.sever(&"forearm_r")
		GameEvents.limb_severed.emit(real, &"forearm_r", real_piece)
		await get_tree().create_timer(0.5).timeout
		print("real rig sever: piece %s, stumps %d" % [real_piece, BloodFX.active_stumps()])
		if BloodFX.active_stumps() == 0:
			fails.append("no stump spray on the real rig")
	else:
		print("note: real HumanoidRig not built yet; skipped the real sever")

	# Arena heightfield follows the arena group.
	if not is_instance_valid(BloodFX._heightfield):
		fails.append("no particle-collision heightfield for the arena")
	arena.queue_free()
	await get_tree().create_timer(0.7).timeout
	if is_instance_valid(BloodFX._heightfield):
		fails.append("heightfield outlived the arena")

	U.finish(get_tree(), "test_events", fails, errlog)
