extends "res://tests/combat/anti_infinite_base.gd"
## Round 3 anti-infinite: P mashed at 8 Hz (stick neutral) through the real
## PlayerController against each archetype's real AI for 20 s, a downed
## Brawler under P-mash, and unit checks (decay, shared victim count, juggle
## cap, a short string at full stun).

const SECONDS := 20.0
## Normal landing -> get-up is ~1.3 s (A: settle 0.4 s, getup_delay 0.5 s, get-up ~0.5-1 s);
## one allowed extension adds ~1 s.
const GROUND_UP_MAX := 2.5

func run() -> void:
	for arch: StringName in [&"grunt", &"brawler", &"brute", &"duelist"]:
		await start_duel(arch)
		await mash("P", SECONDS)
		_report("P", arch)
	await _downed_brawler()

func _report(pattern: String, arch: StringName) -> void:
	print("DATA %s vs %s: hits per combo max %d, biggest combo %.0f%% of HP (strikes), longest stun stretch %.2f s, longest knockdown stretch %.2f s (landing -> up %.2f s), relaunches after landing %d (finisher %d), escapes %d, shortest freedom after escape %.2f s, AI acted after %d/%d escapes, enemy dead %s" % [
		pattern, arch, m_max_hits, m_max_combo_dmg * 100.0, m_max_stun_noctl, m_max_down_noctl, m_max_ground_up,
		m_otg_relaunch, m_finisher_relaunch_max, m_escapes, m_escape_free_min if m_escape_free_min < INF else -1.0,
		m_acts_after_escape, m_escapes, m_deaths > 0])
	if m_max_noctl > 3.0:
		print("  longest no-control stretch (%.2f s):" % m_max_noctl)
		for l in worst_timeline():
			print("    ", l)
	check(not m_combo_kill and m_max_combo_dmg < 1.0, "%s vs %s: no single combo kills from full HP (%.0f%%)" % [pattern, arch, m_max_combo_dmg * 100.0])
	check(m_max_stun_noctl <= 3.0, "%s vs %s: longest stun stretch %.2f s <= 3.0" % [pattern, arch, m_max_stun_noctl])
	check(m_otg_relaunch == 0, "%s vs %s: no ordinary hit relaunches a landed body (%d)" % [pattern, arch, m_otg_relaunch])
	check(m_finisher_relaunch_max <= 1, "%s vs %s: at most one ground-finisher relaunch per knockdown" % [pattern, arch])
	check(m_max_ground_up <= GROUND_UP_MAX, "%s vs %s: landing -> on its feet %.2f s <= %.1f" % [pattern, arch, m_max_ground_up, GROUND_UP_MAX])
	if m_escapes > 0:
		check(m_escape_free_min >= 0.5, "%s vs %s: free for %.2f s after each escape" % [pattern, arch, m_escape_free_min])

## A downed Brawler under P-mash gets up within its normal get-up time + 1 s.
func _downed_brawler() -> void:
	print("downed Brawler under P-mash")
	var t_ref: float = await _knockdown_time(false)
	var t_mash: float = await _knockdown_time(true)
	print("DATA downed brawler: get-up %.2f s alone, %.2f s under P-mash" % [t_ref, t_mash])
	check(t_ref > 0.0 and t_mash > 0.0, "the Brawler got up both times")
	check(t_mash <= t_ref + 1.0, "under P-mash it gets up within %.2f s + 1 (%.2f)" % [t_ref, t_mash])

## Trip the Brawler (crouch + held kick), then optionally mash P over it;
## seconds from the trip until it is back on its feet.
func _knockdown_time(mash_p: bool) -> float:
	await start_duel(&"brawler")
	var br := enemy
	br.brain.set_physics_process(false)  # the Brawler just lies there and gets up
	br.global_position = player.global_position + player.get_forward() * 1.1
	br.snap_facing(-player.get_forward())
	br.reset_physics_interpolation()
	for i in 20:
		await get_tree().physics_frame
	br.combat.cancel()
	Input.action_press(&"crouch")
	await get_tree().physics_frame
	Input.action_press(&"kick")
	for i in 36:
		await get_tree().physics_frame
	Input.action_release(&"kick")
	await get_tree().physics_frame
	Input.action_release(&"crouch")
	var t0 := TimeDirector.now()
	var ok := false
	while TimeDirector.now() - t0 < 1.0:
		await get_tree().physics_frame
		if br.is_down():
			ok = true
			break
	if not ok:
		print("  the trip did not knock the Brawler down")
		return -1.0
	var next := 0.0
	while TimeDirector.now() - t0 < 12.0:
		await get_tree().physics_frame
		if not br.is_down():
			return TimeDirector.now() - t0
		if mash_p:
			var to := br.get_ground_position() - player.global_position
			to.y = 0.0
			if to.length() > 0.9:
				player.teleport_to(br.get_ground_position() - to.normalized() * 0.7, to)
			var now := TimeDirector.now()
			if now >= next:
				next = now + 0.125
				Input.action_press(&"punch")
			elif now >= next - 0.06:
				Input.action_release(&"punch")
	return -1.0
