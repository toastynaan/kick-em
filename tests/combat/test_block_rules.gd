extends "res://tests/combat/combat_test_base.gd"
## Archetype defence rules: Brawler blocks jabs; Shield blocks strikes from the
## front only; grabs beat block; invulnerability ignores hits; heavy Brute
## staggers from a standing kick but launches from a dash kick.

func _hit_once(p: Fighter, action: int) -> int:
	clear_events()
	p.combat.press(action)
	p.combat.release(action)
	await wait_real(0.75)
	if count_events(&"hit_blocked") > 0:
		return HitInfo.Result.BLOCKED
	if count_events(&"hit_landed") > 0:
		return HitInfo.Result.HIT
	return -1

func run() -> void:
	var p := spawn(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var b := spawn(&"brawler", Vector3(0, 0, -1.0), Vector3.BACK)
	await ticks(20)
	print("brawler blocks jabs")
	var r: int = await _hit_once(p, CombatController.Action.LIGHT)
	check(r == HitInfo.Result.BLOCKED, "jab on brawler blocked")
	await wait_real(0.3)
	r = await _hit_once(p, CombatController.Action.SWEEP)
	check(r == HitInfo.Result.HIT, "sweep on brawler lands")
	b.queue_free()
	if rig_is_real(p):
		await wait_real(2.5)

	var s := spawn(&"shield", Vector3(8, 0, -1.0), Vector3.BACK)
	var p2 := spawn(&"player", Vector3(8, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	await ticks(20)
	print("shield blocks from the front")
	r = await _hit_once(p2, CombatController.Action.KICK)
	check(r == HitInfo.Result.BLOCKED, "front kick on shield blocked")
	await wait_real(0.5)
	s.global_position = Vector3(8, 0, -1.0)
	s.snap_facing(Vector3.FORWARD)  # turn his back to the player
	s.reset_physics_interpolation()
	p2.global_position = Vector3(8, 0, 0)
	p2.reset_physics_interpolation()
	await ticks(5)
	r = await _hit_once(p2, CombatController.Action.LIGHT)
	check(r == HitInfo.Result.HIT, "jab in the shield's back lands")
	await wait_real(0.5)
	s.snap_facing(Vector3.BACK)
	s.global_position = Vector3(8, 0, -1.0)
	s.reset_physics_interpolation()
	await ticks(5)
	clear_events()
	p2.combat.press(CombatController.Action.GRAB)
	p2.combat.release(CombatController.Action.GRAB)
	var ok := await wait_until(func() -> bool: return count_events(&"grab_started") > 0, 1.0)
	check(ok, "grab opens the shield")
	await wait_real(0.6)
	s.queue_free()

	print("grab beats a blocking player")
	var p3 := spawn(&"player", Vector3(16, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e3 := spawn(&"grunt", Vector3(16, 0, -1.0), Vector3.BACK)
	await ticks(20)
	clear_events()
	p3.combat.press(CombatController.Action.BLOCK)
	await wait_real(0.6)
	check(e3.combat.start_enemy_attack(&"e_grab", 0.4), "enemy grab started")
	ok = await wait_until(func() -> bool: return count_events(&"grab_started") > 0, 2.0)
	check(ok, "grab catches the blocker")
	p3.combat.release(CombatController.Action.BLOCK)
	await wait_real(1.0)

	print("invulnerable ignores hits")
	var p4 := spawn(&"player", Vector3(24, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e4 := spawn(&"grunt", Vector3(24, 0, -1.0), Vector3.BACK)
	await ticks(20)
	e4.invuln_until = TimeDirector.now() + 2.0
	var hp0 := e4.hp
	clear_events()
	p4.combat.press(CombatController.Action.LIGHT)
	await wait_real(0.4)
	check(is_equal_approx(e4.hp, hp0) and e4.combat.last_result == HitInfo.Result.IGNORED, "hit IGNORED while invulnerable")

	print("heavy brute: standing kick staggers, dash kick launches")
	var p5 := spawn(&"player", Vector3(32, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var _br := spawn(&"brute", Vector3(32, 0, -1.4), Vector3.BACK)
	await ticks(20)
	clear_events()
	p5.combat.press(CombatController.Action.KICK)
	await wait_until(func() -> bool: return count_events(&"hit_landed") > 0, 1.0)
	var inf: HitInfo = last_event(&"hit_landed")[1] if count_events(&"hit_landed") > 0 else null
	check(inf != null and inf.reaction == HitInfo.Reaction.STAGGER, "standing kick only staggers the brute")
	var p6 := spawn(&"player", Vector3(40, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var _br2 := spawn(&"brute", Vector3(40, 0, -3.8), Vector3.BACK)
	await ticks(20)
	clear_events()
	p6.move_input = Vector3.FORWARD
	p6.combat.press(CombatController.Action.DASH)
	await wait_real(0.12)
	p6.move_input = Vector3.ZERO
	p6.combat.press(CombatController.Action.KICK)
	await wait_until(func() -> bool: return count_events(&"hit_landed") > 0, 1.5)
	inf = last_event(&"hit_landed")[1] if count_events(&"hit_landed") > 0 else null
	check(inf != null and inf.reaction == HitInfo.Reaction.LAUNCH, "dash kick launches the brute (%s)" % [inf])
	done()
