extends "res://tests/input/input_test_base.gd"
## Per-fighter time and the contact frame (Round 5; Round 7 cap). Agent H:
## - F0: during a 110 ms hitstop on two fighters, a third enemy's logged
##   position keeps changing (and the two frozen ones hold still, actor time 0).
## - The player's own freeze never passes Tuning.R7_PLAYER_HITSTOP_MAX
##   (Round 7: Hit feel); the victim keeps its full freeze; a real punch that
##   lands freezes the player within the cap.

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

	# --- The player's freeze is capped at R7_PLAYER_HITSTOP_MAX; the victim keeps its own.
	print("player freeze cap")
	await ticks(30)
	var worst := 0.0
	var cap_ms := Tuning.R7_PLAYER_HITSTOP_MAX * 1000.0
	for stop: float in [0.04, 0.07, 0.11, 0.14, 0.16, 0.2, 0.25]:
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
		check(p_ms <= cap_ms + 0.5 and absf(p_ms - minf(stop * 1000.0, cap_ms)) <= 1000.0 / 120.0 + 0.5,
			"player freeze %.1f ms (hitstop %.0f ms, cap %.0f ms)" % [p_ms, stop * 1000.0, cap_ms])
		check(absf(b_ms - stop * 1000.0) <= 1000.0 / 120.0 + 0.5, "victim freeze %.1f ms (want %.0f)" % [b_ms, stop * 1000.0])
	print("  longest player freeze: %.1f ms" % worst)

	# A real strike by the player (the freeze B applies through TimeDirector.hitstop).
	b.global_position = p.global_position + Vector3(0, 0, -1.0)
	b.snap_facing(Vector3.BACK)
	b.reset_physics_interpolation()
	await ticks(10)
	var frozen_seen := 0
	var victim_frozen := 0
	var hits := []
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void:
		if info.attacker == p:
			hits.append(info))
	press(&"punch")
	await ticks(1)
	release(&"punch")
	for i in 90:
		await get_tree().physics_frame
		if p.is_frozen():
			frozen_seen += 1
		if b.is_frozen():
			victim_frozen += 1
	var hs: float = (hits[0] as HitInfo).hitstop if not hits.is_empty() else 0.0
	print("  real punch: hit %s (hitstop %.3f s), player frozen %.1f ms, victim %.1f ms (last freeze %.3f s)"
		% [not hits.is_empty(), hs, frozen_seen / 0.12, victim_frozen / 0.12, p.last_freeze])
	check(not hits.is_empty() and frozen_seen > 0, "a real punch lands and freezes the player")
	check(frozen_seen / 120.0 <= Tuning.R7_PLAYER_HITSTOP_MAX + 0.5 / 120.0,
		"a real hit freezes the player within the cap (%.1f ms)" % (frozen_seen / 0.12))
	done()
