extends "res://tests/combat/combat_test_base.gd"
## Teleport counter: perfect dodge, then Light during the slow motion ->
## reappear behind the attacker, back kick launches it at ~16 m/s, 1 Focus spent.

func run() -> void:
	var p := spawn(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := spawn(&"grunt", Vector3(0, 0, -1.2), Vector3.BACK)
	await ticks(20)
	check(e.combat.start_enemy_attack(&"e_hook", 0.5), "enemy attack started")
	await wait_until(func() -> bool: return e.combat.time_to_active() <= 0.08, 2.0)
	p.combat.press(CombatController.Action.BLOCK)
	p.combat.release(CombatController.Action.BLOCK)
	await wait_until(func() -> bool: return count_events(&"perfect_dodge") > 0, 1.0)
	check(count_events(&"perfect_dodge") == 1, "perfect dodge")
	check(p.combat.can_counter(), "counter window open")
	var focus_before := p.focus
	var behind := e.get_ground_position() - e.get_forward() * Tuning.COUNTER_BEHIND_DIST
	await ticks(2)
	p.combat.press(CombatController.Action.LIGHT)
	p.combat.release(CombatController.Action.LIGHT)
	check(count_events(&"teleport_counter") == 1, "teleport_counter emitted")
	var landed := p.global_position.distance_to(behind)
	check(landed < 0.25, "landed behind the attacker (%.2f m from the spot)" % landed)
	var to_e := e.get_ground_position() - p.global_position
	to_e.y = 0.0
	check(p.get_forward().dot(to_e.normalized()) > 0.95, "facing the attacker")
	check(is_equal_approx(p.focus, focus_before - Tuning.FOCUS_COST), "focus %.2f -> %.2f" % [focus_before, p.focus])
	var ok := await wait_until(func() -> bool:
		for ev in events:
			if ev[0] == &"hit_landed" and (ev[1] as HitInfo).move_id == &"back_kick":
				return true
		return false, 2.0)
	check(ok, "back kick landed")
	if ok:
		var info: HitInfo = null
		for ev in events:
			if ev[0] == &"hit_landed" and (ev[1] as HitInfo).move_id == &"back_kick":
				info = ev[1]
		print("  ", info)
		check(absf(info.launch_velocity.length() - Tuning.COUNTER_LAUNCH) < 0.3,
			"counter launch %.2f m/s ~ %.1f" % [info.launch_velocity.length(), Tuning.COUNTER_LAUNCH])
		check(info.is_finisher and is_equal_approx(info.damage, Tuning.DMG_COUNTER), "finisher, DMG_COUNTER")
		var dir := info.launch_velocity
		dir.y = 0.0
		check(dir.normalized().dot(to_e.normalized()) > 0.9, "launched away from the player")
		check(is_equal_approx(p.focus, focus_before - Tuning.FOCUS_COST), "counter refunds nothing (focus %.2f)" % p.focus)
		if rig_is_real(e):
			await ticks(2)
			check(e.is_launched(), "attacker LAUNCHED")
			var v := e.get_com_velocity()
			print("  attacker COM velocity after counter: %s (%.2f m/s)" % [v, v.length()])
	await wait_real(0.3)
	check(not p.combat.can_counter(), "counter window closed")
	done()
