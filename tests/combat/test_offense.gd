extends "res://tests/combat/combat_test_base.gd"
## Round 2 offence: input buffer through blockstun, block punish, hit cancels,
## punt, magnetism, jab hands from PoseLibrary.STRIKE_BONES.

var _x := 0.0

func _pair(arch: StringName, dist: float) -> Array:
	_x += 8.0
	var p := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := spawn(arch, Vector3(_x, 0, -dist), Vector3.BACK)
	await ticks(15)
	return [p, e]

func _started(f: Fighter) -> Array:
	var starts: Array = []
	f.combat.attack_started.connect(func(id: StringName) -> void: starts.append([id, TimeDirector.now()]))
	return starts

func _landed(move_id: StringName, victim: Fighter = null) -> HitInfo:
	for i in range(events.size() - 1, -1, -1):
		var ev: Array = events[i]
		if ev[0] == &"hit_landed" and (ev[1] as HitInfo).move_id == move_id \
				and (victim == null or (ev[1] as HitInfo).victim == victim):
			return ev[1]
	return null

func run() -> void:
	const K := CombatController.Action.KICK
	const L := CombatController.Action.LIGHT
	const B := CombatController.Action.BLOCK

	print("jab limbs follow PoseLibrary.STRIKE_BONES")
	for id: StringName in [&"jab1", &"jab2", &"jab3", &"sparta_kick", &"e_hook"]:
		var want: StringName = PoseLibrary.STRIKE_BONES[id][0]
		check(MoveLibrary.get_move(id).limb == want, "%s strikes with %s" % [id, want])

	print("buffer: kick pressed in blockstun comes out")
	var pe: Array = await _pair(&"grunt", 1.2)
	var p: Fighter = pe[0]
	var e: Fighter = pe[1]
	var started := _started(p)
	p.combat.press(B)
	await ticks(5)
	clear_events()
	e.combat.start_enemy_attack(&"e_heavy", 0.4)
	await wait_until(func() -> bool: return count_events(&"hit_blocked") > 0, 2.0)
	var t_block := TimeDirector.now()
	check(p.combat.is_stunned(), "player in blockstun")
	p.combat.release(B)
	p.combat.press(K)
	p.combat.release(K)
	await wait_until(func() -> bool: return not started.is_empty(), 1.0)
	check(not started.is_empty() and started[0][0] == &"sparta_kick", "buffered kick started after blockstun")
	if not started.is_empty():
		var dt: float = started[0][1] - t_block
		var stun := Tuning.HITSTOP[&"jab"] + Tuning.frames(MoveLibrary.get_move(&"e_heavy").blockstun)
		check(dt >= stun - 0.02 and dt < stun + 0.1, "kick came out %.3f s after the block (blockstun+hitstop %.3f)" % [dt, stun])

	print("block punish: a blocked e_hook is punished by a kick")
	pe = await _pair(&"grunt", 1.2)
	p = pe[0]
	e = pe[1]
	var e_active := [0.0]
	e.combat.attack_active.connect(func(_id: StringName) -> void: e_active[0] = TimeDirector.now())
	p.combat.press(B)
	await ticks(5)
	clear_events()
	e.combat.start_enemy_attack(&"e_hook", 0.4)
	await wait_until(func() -> bool: return count_events(&"hit_blocked") > 0, 2.0)
	p.combat.release(B)
	p.combat.press(K)
	p.combat.release(K)
	var ok := await wait_until(func() -> bool: return _landed(&"sparta_kick", e) != null, 1.5)
	check(ok, "punishing kick landed")
	var hook := MoveLibrary.get_move(&"e_hook")
	var hook_left := Tuning.frames(hook.active + hook.recovery) + Tuning.HITSTOP[&"jab"]
	var t_hit := TimeDirector.now()
	check(ok and t_hit - e_active[0] < hook_left + 0.02,
		"kick hit %.3f s after the hook went active (hook busy for %.3f s)" % [t_hit - e_active[0], hook_left])

	print("cancel: jab hit -> kick")
	pe = await _pair(&"grunt", 1.0)
	p = pe[0]
	e = pe[1]
	started = _started(p)
	clear_events()
	p.combat.press(L)
	p.combat.release(L)
	await wait_until(func() -> bool: return _landed(&"jab1", e) != null, 1.0)
	p.combat.press(K)
	p.combat.release(K)
	ok = await wait_until(func() -> bool: return _landed(&"sparta_kick", e) != null, 1.5)
	check(ok, "jab -> kick cancel landed")
	if started.size() >= 2:
		var jab := MoveLibrary.get_move(&"jab1")
		var full := Tuning.frames(jab.startup + jab.active + jab.recovery)
		var gap: float = started[1][1] - started[0][1]
		check(started[1][0] == &"sparta_kick" and gap < full,
			"kick started %.3f s after the jab (jab alone lasts %.3f s)" % [gap, full])

	print("no cancel on a whiff")
	_x += 8.0
	var lone := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	await ticks(10)
	started = _started(lone)
	lone.combat.press(L)
	lone.combat.release(L)
	await wait_until(func() -> bool: return lone.combat.is_attack_active(), 1.0)
	lone.combat.press(K)
	lone.combat.release(K)
	await wait_until(func() -> bool: return started.size() >= 2, 1.0)
	if started.size() >= 2:
		var jab := MoveLibrary.get_move(&"jab1")
		var full := Tuning.frames(jab.startup + jab.active + jab.recovery)
		var gap: float = started[1][1] - started[0][1]
		check(gap >= full - 0.02, "whiffed jab is not cancelled (kick after %.3f s >= %.3f)" % [gap, full])
	else:
		check(false, "kick came out after the whiffed jab")

	print("punt a downed grunt")
	pe = await _pair(&"grunt", 1.1)
	p = pe[0]
	e = pe[1]
	clear_events()
	p.combat.press(CombatController.Action.SWEEP)
	await wait_until(func() -> bool: return _landed(&"leg_sweep", e) != null, 1.0)
	await wait_until(func() -> bool: return e.get_state() == RagdollController.State.GROUNDED \
		or (e.is_launched() and e.get_center_of_mass().y - e.get_ground_position().y < 0.6), 3.0)
	await wait_real(0.6)
	var to_e := e.get_ground_position() - p.global_position
	to_e.y = 0.0
	print("  downed state %d, %.2f m away" % [e.get_state(), to_e.length()])
	if to_e.length() > 1.4:
		p.teleport_to(e.get_ground_position() - to_e.normalized() * 1.0, to_e)
		await ticks(2)
	started = _started(p)
	p.combat.press(K)
	p.combat.release(K)
	check(not started.is_empty() and started[0][0] == &"punt", "Kick near a downed body is a punt")
	ok = await wait_until(func() -> bool: return _landed(&"punt", e) != null, 1.0)
	check(ok, "punt landed")
	if ok:
		var info := _landed(&"punt", e)
		var v := info.launch_velocity
		check(absf(v.length() - MoveLibrary.PUNT_LAUNCH) < 0.3, "punt launch %.2f m/s" % v.length())
		check(absf(rad_to_deg(asin(v.normalized().y)) - MoveLibrary.PUNT_UP_ANGLE) < 1.0, "punt 15 deg up")
		check(info.hit_bone == &"Hips", "punt hits the hips")
		check(e.downed_hits == 1, "one punt counted")
	await wait_until(func() -> bool: return not p.combat.is_attacking(), 1.0)
	await wait_until(func() -> bool: return e.get_state() == RagdollController.State.GROUNDED, 3.0)
	to_e = e.get_ground_position() - p.global_position
	to_e.y = 0.0
	p.teleport_to(e.get_ground_position() - to_e.normalized() * 1.0, to_e)
	await ticks(2)
	started.clear()
	if e.is_down():
		p.combat.press(K)
		p.combat.release(K)
		check(not started.is_empty() and started[0][0] == &"sparta_kick", "no second punt in the same down")
	await wait_until(func() -> bool: return not p.combat.is_attacking(), 1.0)

	print("cancel: sweep hit -> punt")
	pe = await _pair(&"grunt", 1.1)
	p = pe[0]
	e = pe[1]
	started = _started(p)
	clear_events()
	p.combat.press(CombatController.Action.SWEEP)
	p.combat.release(CombatController.Action.SWEEP)
	await wait_until(func() -> bool: return _landed(&"leg_sweep", e) != null, 1.0)
	p.combat.press(K)
	p.combat.release(K)
	await wait_until(func() -> bool: return started.size() >= 2, 1.0)
	check(started.size() >= 2 and started[1][0] == &"punt", "sweep cancels into a punt")
	if started.size() >= 2:
		var sw := MoveLibrary.get_move(&"leg_sweep")
		var gap: float = started[1][1] - started[0][1]
		check(gap < Tuning.frames(sw.startup + sw.active + sw.recovery), "punt came out inside the sweep's recovery (%.3f s)" % gap)
	ok = await wait_until(func() -> bool: return _landed(&"punt", e) != null, 1.0)
	check(ok, "sweep -> punt landed")

	print("magnetism: a jab from 2 m connects")
	pe = await _pair(&"grunt", 2.0)
	p = pe[0]
	e = pe[1]
	clear_events()
	var hp0 := e.hp
	p.combat.press(L)
	p.combat.release(L)
	await wait_real(0.5)
	check(e.hp < hp0, "jab pulled in and hit from 2.0 m (moved %.2f m)" % absf(p.global_position.z))
	pe = await _pair(&"grunt", 3.6)
	p = pe[0]
	e = pe[1]
	hp0 = e.hp
	p.combat.press(L)
	p.combat.release(L)
	await wait_real(0.5)
	check(is_equal_approx(e.hp, hp0) and absf(p.global_position.z) < 0.5, "no pull from 3.6 m (out of reach + 1.2)")
	done()
