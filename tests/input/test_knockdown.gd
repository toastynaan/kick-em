extends "res://tests/input/input_test_base.gd"
## F8 support (agent H): the player knocked down (running into a heavy, the
## heavy's shoulder charge, a grab-throw) gets up Tuning.PLAYER_GETUP_AFTER on
## the ground (the fast get-up) and cannot be hit for Tuning.PLAYER_GETUP_INVULN
## after it; M's check "act again within 1.1 s" depends on it. While down he
## can still be hit (enemies get one free swing). Enemies keep their longer
## knockdown. Prints the measured times.

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	var g := spawn_dummy(&"grunt", Vector3(0, 0, -6), Vector3.BACK)
	await ticks(40)
	var acts: Array[float] = []
	for i in 3:
		await wait_until(func() -> bool: return p.can_act(), 600)
		await ticks(30)
		var t0 := TimeDirector.now()
		p.knockdown(Vector3(0, 0, 1) if i % 2 == 0 else Vector3(1, 0, 0), Bones.CHEST)
		await ticks(2)
		check(p.is_down(), "knocked down (%d)" % i)
		var t_ground := -1.0
		var hit_while_down := false
		var probe_done := false
		while not p.can_act() and TimeDirector.now() - t0 < 4.0:
			await get_tree().physics_frame
			if t_ground < 0.0 and p.get_state() == RagdollController.State.GROUNDED:
				t_ground = TimeDirector.now()
			if not probe_done and p.get_state() == RagdollController.State.GROUNDED:
				probe_done = true
				hit_while_down = not p.is_invulnerable()
		var act := TimeDirector.now() - t0
		acts.append(act)
		var t_up := TimeDirector.now()
		var inv := p.is_invulnerable()
		var inv_left := 0.0
		while p.is_invulnerable() and inv_left < 2.0:
			await get_tree().physics_frame
			inv_left = TimeDirector.now() - t_up
		print("  knockdown %d: grounded after %.3f s, can act after %.3f s, untouchable %.3f s after getting up"
			% [i, t_ground - t0 if t_ground > 0.0 else -1.0, act, inv_left])
		check(hit_while_down, "can be hit while on the ground (one free swing)")
		check(inv and absf(inv_left - Tuning.PLAYER_GETUP_INVULN) <= 1.5 / 120.0,
			"untouchable %.3f s after getting up (want %.1f)" % [inv_left, Tuning.PLAYER_GETUP_INVULN])
	var worst := 0.0
	for a in acts:
		worst = maxf(worst, a)
	check(worst <= 1.1 + 1e-3, "the player acts again within 1.1 s of a knockdown (worst %.3f s)" % worst)

	# Enemies keep the longer knockdown (Tuning.REACT_KNOCKDOWN.ground).
	var t1 := TimeDirector.now()
	g.knockdown(Vector3.FORWARD, Bones.CHEST)
	await ticks(2)
	await wait_until(func() -> bool: return g.can_act(), 900)
	var g_act := TimeDirector.now() - t1
	print("  grunt knockdown: acts again after %.3f s" % g_act)
	check(g_act > 1.1, "an enemy stays down longer than the player (%.2f s)" % g_act)
	done()
