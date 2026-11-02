extends "res://tests/input/input_test_base.gd"
## Per-fighter time and the contact frame (Round 5). Acceptance (agent H):
## - F0: during a 110 ms hitstop on two fighters, a third enemy's logged
##   position keeps changing (and the two frozen ones hold still, actor time 0).
## - F4 (with B): the player's logged freeze never passes 60 ms, and a Block
##   pressed during it fires afterwards.

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	var a := spawn_dummy(&"grunt", Vector3(-3, 0, -4), Vector3.FORWARD)
	var b := spawn_dummy(&"grunt", Vector3(0, 0, -4), Vector3.FORWARD)
	var c := spawn_dummy(&"grunt", Vector3(3, 0, -4), Vector3.FORWARD)
	await ticks(40)

	# --- F0: 110 ms hitstop on two walking fighters; the third keeps walking. ---------
	print("hitstop on two fighters, the third keeps moving")
	for f in [a, b, c]:
		f.move_input = Vector3.FORWARD
	await ticks(40)
	TimeDirector.hitstop([a, b], 0.11)
	var log_c: Array[Vector3] = []
	var a0 := a.global_position
	var b0 := b.global_position
	var frozen_ticks := 0
	var actor_ok := true
	for i in 12:  # 0.1 s: inside the 110 ms freeze
		await get_tree().physics_frame
		log_c.append(c.global_position)
		if a.is_frozen() and b.is_frozen():
			frozen_ticks += 1
		actor_ok = actor_ok and a.get_actor_time() == 0.0 and b.get_actor_time() == 0.0 and c.get_actor_time() == 1.0
	var changes := 0
	for i in range(1, log_c.size()):
		if log_c[i].distance_to(log_c[i - 1]) > 1e-4:
			changes += 1
	print("  third enemy z per tick: %s" % [log_c.map(func(v: Vector3) -> String: return "%.3f" % v.z)])
	check(changes == log_c.size() - 1, "the third enemy's position changed on %d of %d ticks" % [changes, log_c.size() - 1])
	check(a.global_position.distance_to(a0) < 1e-3 and b.global_position.distance_to(b0) < 1e-3,
		"the two frozen fighters held still (moved %.4f, %.4f m)" % [a.global_position.distance_to(a0), b.global_position.distance_to(b0)])
	check(actor_ok, "actor time 0 for the frozen two, 1 for the third")
	await ticks(10)
	check(not a.is_frozen() and not b.is_frozen(), "the freeze ended")
	var a1 := a.global_position
	await ticks(10)
	check(a.global_position.distance_to(a1) > 0.05, "the frozen fighters walk again")
	for f in [a, b, c]:
		f.move_input = Vector3.ZERO

	# --- F4: the player's freeze is capped at 60 ms; the victim keeps its own. ---------
	print("player freeze cap")
	await ticks(30)
	var worst := 0.0
	for stop: float in [0.04, 0.06, 0.08, 0.11, 0.15, 0.18]:
		TimeDirector.hitstop([p, b], stop)
		var pt := 0
		var bt := 0
		for i in 40:
			await get_tree().physics_frame
			if p.is_frozen():
				pt += 1
			if b.is_frozen():
				bt += 1
		var p_ms := pt / 120.0 * 1000.0
		var b_ms := bt / 120.0 * 1000.0
		worst = maxf(worst, p_ms)
		print("  hitstop %3.0f ms: player frozen %5.1f ms, victim %5.1f ms" % [stop * 1000.0, p_ms, b_ms])
		check(p_ms <= Tuning.PLAYER_HITSTOP_MAX * 1000.0 + 0.5, "player freeze %.1f ms <= 60 ms (hitstop %.0f ms)" % [p_ms, stop * 1000.0])
		check(absf(b_ms - stop * 1000.0) <= 1000.0 / 120.0 + 0.5, "victim freeze %.1f ms (want %.0f)" % [b_ms, stop * 1000.0])
	print("  longest player freeze: %.1f ms" % worst)

	# A real strike by the player (the freeze B applies through TimeDirector.hitstop).
	b.global_position = p.global_position + Vector3(0, 0, -1.0)
	b.snap_facing(Vector3.BACK)
	b.reset_physics_interpolation()
	await ticks(10)
	var frozen_seen := 0
	var victim_frozen := 0
	press(&"kick")
	await ticks(1)
	release(&"kick")
	for i in 90:
		await get_tree().physics_frame
		if p.is_frozen():
			frozen_seen += 1
		if b.is_frozen():
			victim_frozen += 1
	print("  real kick: player frozen %.1f ms, victim %.1f ms (last freeze %.3f s)" % [frozen_seen / 0.12, victim_frozen / 0.12, p.last_freeze])
	check(frozen_seen / 120.0 <= Tuning.PLAYER_HITSTOP_MAX + 0.5 / 120.0, "a real hit freezes the player <= 60 ms (%.1f ms)" % (frozen_seen / 0.12))
	await wait_until(func() -> bool: return p.can_act(), 240)
	await wait_until(func() -> bool: return not b.is_down(), 900)
	await ticks(30)

	# --- F4: Block pressed during the player's freeze fires when it ends. ---------------
	print("Block during the freeze")
	await wait_until(func() -> bool: return Engine.time_scale > 0.99, 240)
	TimeDirector.hitstop([p, b], 0.15)
	await ticks(2)
	check(p.is_frozen(), "player frozen")
	var t_press := TimeDirector.now()
	press(&"block")
	await ticks(1)
	var guard_during := p.combat.is_blocking()
	var freeze_end := -1.0
	for i in 30:
		if not p.is_frozen() and freeze_end < 0.0:
			freeze_end = TimeDirector.now()
		await get_tree().physics_frame
	var t_def := p.defence.last_block_press_time()
	print("  pressed at %.3f, freeze ended %.3f, Defence took the press at %.3f (guard during the freeze: %s)"
		% [t_press, freeze_end, t_def, guard_during])
	check(t_def >= freeze_end - 1e-4 and t_def <= freeze_end + 1.5 / 120.0,
		"the Block press fired when the freeze ended (%.1f ms after the press)" % ((t_def - t_press) * 1000.0))
	check(p.combat.is_blocking(), "the guard is up afterwards")
	release(&"block")
	done()
