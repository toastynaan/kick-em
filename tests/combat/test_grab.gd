extends "res://tests/combat/combat_test_base.gd"
## Grab connects and throws at ~12 m/s; grab break inside the window works,
## outside fails; reversal in the first 4 frames with Focus swaps roles.

func _thrown_speed() -> float:
	var ev := last_event(&"thrown")
	return (ev[3] as Vector3).length() if not ev.is_empty() else 0.0

func run() -> void:
	var p := spawn(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(0, 0, -1.0), Vector3.BACK)
	await ticks(20)

	print("grab: player grabs and throws")
	var hp0 := g.hp
	p.combat.press(CombatController.Action.GRAB)
	var ok := await wait_until(func() -> bool: return count_events(&"grab_started") > 0, 1.0)
	check(ok, "grab connected")
	check(p.combat.holding == g and g.combat.held_by == p, "holding / held_by set")
	check(g.is_in_hitstun() and not g.can_act(), "held victim cannot act")
	await wait_real(0.3)
	var socket_d := g.global_position.distance_to(p.global_position)
	check(socket_d > 0.4 and socket_d < 1.2, "victim held in front (%.2f m)" % socket_d)
	p.combat.release(CombatController.Action.GRAB)
	ok = await wait_until(func() -> bool: return count_events(&"thrown") > 0, 1.0)
	check(ok, "thrown emitted on release")
	check(absf(_thrown_speed() - Tuning.THROW_SPEED) < 0.2, "throw speed %.2f ~ %.1f" % [_thrown_speed(), Tuning.THROW_SPEED])
	var tv: Vector3 = last_event(&"thrown")[3] if ok else Vector3.ZERO
	var up_deg := rad_to_deg(asin(tv.normalized().y)) if ok else 0.0
	check(absf(up_deg - Tuning.THROW_UP_ANGLE) < 1.0, "throw %.1f deg up" % up_deg)
	check(is_equal_approx(hp0 - g.hp, Tuning.DMG_THROW), "throw damage %.0f" % (hp0 - g.hp))
	check(p.combat.holding == null and g.combat.held_by == null, "hold released")
	if rig_is_real(g):
		await ticks(2)
		check(g.is_launched(), "thrown victim LAUNCHED")

	await wait_real(1.0)
	print("grab: whiff has long recovery")
	clear_events()
	var lone := spawn(&"player", Vector3(20, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	await ticks(3)
	lone.combat.press(CombatController.Action.GRAB)
	lone.combat.release(CombatController.Action.GRAB)
	await wait_real(Tuning.frames(8 + 3 + 20))
	check(lone.combat.is_attacking(), "still recovering %d frames into a whiffed grab" % (8 + 3 + 20))
	check(count_events(&"attack_whiff") == 1, "grab whiff emitted")

	# Fresh enemy for the break tests.
	var e := spawn(&"grunt", Vector3(10, 0, -1.0), Vector3.BACK)
	var q := spawn(&"player", Vector3(10, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	p.queue_free()
	await ticks(20)

	print("break: press 0.05 s before the enemy grab goes active")
	clear_events()
	var f0 := q.focus
	check(e.combat.start_enemy_attack(&"e_grab", 0.5), "enemy grab started")
	check(count_events(&"grab_started") == 0, "no grab before active")
	await wait_until(func() -> bool: return e.combat.time_to_active() <= 0.05, 2.0)
	q.combat.press(CombatController.Action.GRAB)
	q.combat.release(CombatController.Action.GRAB)
	await wait_real(0.4)
	check(count_events(&"grab_broken") == 1, "grab_broken emitted")
	var gb := last_event(&"grab_broken")
	check(not gb.is_empty() and gb[1] == e and gb[2] == q and gb[3] == false, "grab_broken(grabber, victim, reversal=false)")
	check(q.combat.held_by == null, "victim free")
	check(is_equal_approx(q.focus, f0 + Tuning.FOCUS_GRAB_BREAK), "focus +0.5 (%.2f)" % q.focus)
	check(count_events(&"thrown") == 0, "no throw after a break")

	await wait_real(1.2)
	q.global_position = Vector3(10, 0, 0)
	e.global_position = Vector3(10, 0, -1.0)
	q.snap_facing(Vector3.FORWARD)
	e.snap_facing(Vector3.BACK)
	await ticks(10)
	print("break: press 0.25 s after connect (too late)")
	clear_events()
	var hp1 := q.hp
	check(e.combat.start_enemy_attack(&"e_grab", 0.4), "enemy grab started")
	ok = await wait_until(func() -> bool: return count_events(&"grab_started") > 0, 2.0)
	check(ok, "enemy grab connected")
	await wait_real(0.25)
	q.combat.press(CombatController.Action.GRAB)
	q.combat.release(CombatController.Action.GRAB)
	ok = await wait_until(func() -> bool: return count_events(&"thrown") > 0, 2.0)
	check(count_events(&"grab_broken") == 0, "late press does not break")
	check(ok, "player thrown")
	check(is_equal_approx(hp1 - q.hp, Tuning.DMG_ENEMY[&"e_grab"]), "enemy throw damage %.0f" % (hp1 - q.hp))

	await wait_real(1.5)
	if q.is_down():
		q.ragdoll.force_recover()
		await ticks(5)
	q.global_position = Vector3(10, 0, 0)
	e.global_position = Vector3(10, 0, -1.0)
	q.snap_facing(Vector3.FORWARD)
	e.snap_facing(Vector3.BACK)
	q.reset_physics_interpolation()
	e.reset_physics_interpolation()
	await ticks(10)
	print("reversal: press right after connect with Focus")
	clear_events()
	q.add_focus(1.0)
	var f1 := q.focus
	check(e.combat.start_enemy_attack(&"e_grab", 0.4), "enemy grab started")
	ok = await wait_until(func() -> bool: return count_events(&"grab_started") > 0, 2.0)
	check(ok, "enemy grab connected")
	q.combat.press(CombatController.Action.GRAB)
	check(count_events(&"grab_broken") == 1 and last_event(&"grab_broken")[3] == true, "reversal emitted")
	check(q.combat.holding == e and e.combat.held_by == q, "roles swapped")
	check(is_equal_approx(q.focus, f1 - Tuning.FOCUS_COST), "reversal cost 1 focus (%.2f -> %.2f)" % [f1, q.focus])
	q.combat.release(CombatController.Action.GRAB)
	ok = await wait_until(func() -> bool: return count_events(&"thrown") > 0, 2.0)
	check(ok and last_event(&"thrown")[1] == q, "reverser throws the enemy")
	done()
