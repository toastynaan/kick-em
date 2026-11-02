extends "res://tests/combat/combat_test_base.gd"
## Power punch charge curve, leg sweep, Thrower projectile, enemy tell timing,
## pursuit and air recovery (the last two need agent A's ragdoll).

func _hit_info(move_id: StringName) -> HitInfo:
	for i in range(events.size() - 1, -1, -1):
		var ev: Array = events[i]
		if ev[0] == &"hit_landed" and (ev[1] as HitInfo).move_id == move_id:
			return ev[1]
	return null

func run() -> void:
	var p := spawn(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(0, 0, -1.1), Vector3.BACK)
	await ticks(20)

	print("HEAVY: a charged punch (level 1 on a tap, level 3 held)")
	p.combat.press(CombatController.Action.HEAVY)
	p.combat.release(CombatController.Action.HEAVY)
	await wait_until(func() -> bool: return count_events(&"hit_landed") > 0, 1.5)
	var info: HitInfo = last_event(&"hit_landed")[1] if count_events(&"hit_landed") > 0 else null
	check(info != null and info.charge_level == 1, "HEAVY tap landed at charge level 1")
	if info:
		check(info.reaction == HitInfo.Reaction.STAGGER, "level 1 jab staggers")
		check(is_equal_approx(info.damage, Tuning.DMG_JAB * Tuning.CHARGE_DAMAGE[1]), "tap damage %.0f" % info.damage)
	await wait_real(1.5)
	if g.is_down():
		g.ragdoll.force_recover()
	g.global_position = Vector3(0, 0, -1.1)
	g.snap_facing(Vector3.BACK)
	g.reset_physics_interpolation()
	g.hp = g.max_hp
	await ticks(10)
	clear_events()
	p.combat.press(CombatController.Action.HEAVY)
	await wait_real(0.5)
	check(p.combat.is_charging(), "charging while HEAVY is held")
	check(p.combat.get_charge() > 0.4 and p.combat.get_charge() < 0.7, "charge at 0.5 s = %.2f" % p.combat.get_charge())
	await wait_real(0.5)
	p.combat.release(CombatController.Action.HEAVY)
	await wait_until(func() -> bool: return count_events(&"hit_landed") > 0, 1.5)
	info = last_event(&"hit_landed")[1] if count_events(&"hit_landed") > 0 else null
	check(info != null, "held HEAVY landed")
	if info:
		check(info.charge_level == 3 and info.reaction == HitInfo.Reaction.LAUNCH and info.is_finisher,
			"level 3: launches, finisher")
		check(is_equal_approx(info.damage, Tuning.DMG_JAB * Tuning.CHARGE_DAMAGE[3]), "level 3 damage %.0f" % info.damage)
	await wait_real(2.5)

	print("leg sweep: tap = stumble, charged = trip (small launch, legs out)")
	var p2 := spawn_fake(&"player", Vector3(10, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	var g2 := spawn(&"grunt", Vector3(10, 0, -1.1), Vector3.BACK)
	await ticks(20)
	clear_events()
	tap(p2, CombatController.Action.SWEEP)
	await wait_until(func() -> bool: return _hit_info(&"leg_sweep") != null, 1.0)
	info = _hit_info(&"leg_sweep")
	check(info != null and info.reaction == HitInfo.Reaction.NONE and count_events(&"stumbled") == 1,
		"tap sweep: the victim stumbles")
	check(g2.combat.is_stumbling() and not g2.is_down(), "stumbling on its feet")
	check(info != null and is_equal_approx(info.damage, Tuning.DMG_SWEEP), "sweep damage")
	check(info != null and info.hit_bone in [&"LeftLowerLeg", &"RightLowerLeg"], "sweep hits a shin")
	await wait_real(Tuning.STUMBLE_TIME + 0.3)
	check(not g2.combat.is_stumbling() and not g2.is_down(), "an unpunished stumble recovers")
	await wait_real(Tuning.COMBO_DROP)
	clear_events()
	await hold_press(p2, CombatController.Action.SWEEP, 0.3)
	await wait_until(func() -> bool: return _hit_info(&"leg_sweep") != null, 1.0)
	info = _hit_info(&"leg_sweep")
	check(info != null and info.charge_level == 1 and info.reaction == HitInfo.Reaction.LAUNCH
		and info.launch_velocity.length() < 3.0, "level 1 sweep trips: small launch")
	check(count_events(&"tripped") == 1, "tripped emitted")
	if rig_is_real(g2):
		var start := g2.get_ground_position()
		await ticks(2)
		check(g2.is_launched(), "tripped victim goes down")
		await wait_real(1.0)
		var moved := g2.get_ground_position() - start
		moved.y = 0.0
		check(moved.length() < 1.5, "tripped victim falls in place (moved %.2f m)" % moved.length())
	var t0 := 0.0

	print("enemy tell: start_enemy_attack timing and events")
	var p3 := spawn(&"player", Vector3(20, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e3 := spawn(&"grunt", Vector3(20, 0, -1.2), Vector3.BACK)
	await ticks(20)
	clear_events()
	var tells := []
	GameEvents.attack_tell.connect(func(a: Node3D, k: StringName, d: float) -> void: tells.append([a, k, d]))
	var incoming := [-1.0]
	e3.combat.attack_incoming.connect(func(_id: StringName, t: float) -> void: incoming[0] = t)
	var ta := [0.0]
	e3.combat.attack_active.connect(func(_id: StringName) -> void: ta[0] = TimeDirector.now())
	t0 = TimeDirector.now()
	check(e3.combat.start_enemy_attack(&"e_kick", 0.45), "e_kick started")
	check(tells.size() == 1 and tells[0][1] == &"strike" and absf(tells[0][2] - 0.45) < 0.001, "attack_tell strike 0.45 s")
	check(absf(incoming[0] - 0.45) < 0.02, "attack_incoming time_to_active %.3f" % incoming[0])
	check(not e3.combat.start_enemy_attack(&"e_hook", 0.4), "cannot start a second attack mid-move")
	await wait_until(func() -> bool: return ta[0] > 0.0, 1.0)
	check(absf(ta[0] - t0 - 0.45) < 0.03, "active after the tell (%.3f s)" % (ta[0] - t0))
	await wait_until(func() -> bool: return _hit_info(&"e_kick") != null, 0.5)
	info = _hit_info(&"e_kick")
	check(info != null and absf(info.launch_velocity.length() - Tuning.ENEMY_LAUNCH[&"e_kick"]) < 0.3, "e_kick launches the player at ~10 m/s")
	tells.clear()
	await wait_real(2.5)
	if p3.is_down():
		p3.ragdoll.force_recover()
	check(e3.combat.start_enemy_attack(&"e_grab", 0.5), "e_grab started")
	check(tells.size() == 1 and tells[0][1] == &"grab", "grab tell is red (&\"grab\")")
	await wait_real(1.5)

	print("thrower projectile")
	var p4 := spawn(&"player", Vector3(30, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var th := spawn(&"thrower", Vector3(30, 0, -7.0), Vector3.BACK)
	await ticks(20)
	clear_events()
	var hp0 := p4.hp
	check(th.combat.start_enemy_attack(&"e_throw_debris", 0.4), "throw started")
	var ok := await wait_until(func() -> bool: return _hit_info(&"e_throw_debris") != null, 3.0)
	check(ok, "debris chunk hit the player")
	if ok:
		info = _hit_info(&"e_throw_debris")
		check(info.kind == &"projectile", "kind projectile")
		check(is_equal_approx(hp0 - p4.hp, Tuning.DMG_ENEMY[&"e_throw_debris"]), "projectile damage %.0f" % (hp0 - p4.hp))

	print("pursuit and air recovery")
	var p5 := spawn(&"player", Vector3(40, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g5 := spawn(&"grunt", Vector3(40, 0, -1.3), Vector3.BACK)
	await ticks(20)
	if not rig_is_real(g5):
		print("  SKIP pursuit / air recovery (stub ragdoll)")
		done()
		return
	clear_events()
	p5.add_focus(2.0)
	p5.combat.press(CombatController.Action.KICK)
	await wait_until(func() -> bool: return g5.is_launched(), 1.0)
	await wait_real(0.1)
	check(p5.combat.can_pursue(), "pursuit available after a launch")
	var f0 := p5.focus
	p5.combat.press(CombatController.Action.DASH)
	check(count_events(&"pursuit") == 1, "pursuit emitted")
	check(is_equal_approx(p5.focus, f0 - Tuning.FOCUS_COST), "pursuit costs 1 focus")
	var gap := p5.global_position.distance_to(g5.get_ground_position())
	check(gap < 2.0, "teleported beside the flying body (%.2f m)" % gap)
	clear_events()
	p5.combat.press(CombatController.Action.KICK)
	ok = await wait_until(func() -> bool: return _hit_info(&"sparta_kick") != null, 1.0)
	check(ok, "pursuit follow-up connected")
	if ok:
		info = _hit_info(&"sparta_kick")
		print("  follow-up: ", info, " energy %.0f J" % info.energy)
		check(info.reaction == HitInfo.Reaction.LAUNCH, "follow-up relaunches")
		var v_hit := info.launch_velocity
		await wait_real(0.3)
		var v_after := g5.get_com_velocity()
		print("  body velocity 0.3 s after the follow-up: %s (%.2f m/s)" % [v_after, v_after.length()])
		check(Vector2(v_after.x, v_after.z).length() > Tuning.KICK_LAUNCH * 0.9,
			"pursued body keeps flying fast (%.2f m/s)" % Vector2(v_after.x, v_after.z).length())
		check(v_hit.normalized().dot(Vector3(v_after.x, 0, v_after.z).normalized()) > 0.5, "relaunched along the flight")

	print("air recovery")
	var p6 := spawn(&"player", Vector3(50, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e6 := spawn(&"grunt", Vector3(50, 0, -1.3), Vector3.BACK)
	await ticks(20)
	clear_events()
	p6.add_focus(1.0)
	check(e6.combat.start_enemy_attack(&"e_kick", 0.4), "enemy kick started")
	ok = await wait_until(func() -> bool: return p6.is_launched(), 2.0)
	check(ok, "player launched")
	p6.combat.press(CombatController.Action.DASH)
	check(count_events(&"air_recovery") == 0 and p6.is_launched(), "no air recovery before 0.4 s")
	await wait_until(func() -> bool: return p6.ragdoll.time_since_launch() >= Tuning.AIR_RECOVERY_AFTER + 0.02, 2.0)
	var f6 := p6.focus
	if p6.is_launched():
		p6.combat.press(CombatController.Action.DASH)
		check(not p6.is_launched(), "air recovery: back on the feet")
		check(is_equal_approx(p6.focus, f6 - Tuning.FOCUS_COST), "air recovery costs 1 focus")
	else:
		print("  SKIP air recovery: player already landed")
	done()
