extends "res://tests/combat/combat_test_base.gd"
## Round 5 frame data and moves (Feel Reference: Wind-up, contact, recovery;
## Health, damage and enemies):
## - every player strike class has Tuning.STRIKE_FRAMES (startup / active /
##   recovery on a miss) in frames of the fighter's own time; a landed hit cuts
##   the recovery by Tuning.HIT_RECOVERY_CUT; a missed sprint strike adds
##   Tuning.SPRINT_WHIFF_FRAMES. Measured on real jabs and kicks.
## - sweeps: tapped = a stumble on its feet that recovers, level 3 = a knockdown.
## - the Round 5 enemy roster: startup from AttackDirector.enemy_startup_frames,
##   damage Tuning.DMG_ENEMY x the brain's get_damage_mult(), preset tiers on the
##   player (flinch / stagger / knockdown; never a launch); the tell events.
## - the Thrower's projectile: a stagger, Tuning.DMG_ENEMY damage.

const TraversalDouble := preload("res://tests/combat/traversal_double.gd")
const A := CombatController.Action
const T := HitInfo.Tier

func _init() -> void:
	_timeout = 90.0

func _hit_info(move_id: StringName) -> HitInfo:
	for i in range(events.size() - 1, -1, -1):
		var ev: Array = events[i]
		if ev[0] == &"hit_landed" and (ev[1] as HitInfo).move_id == move_id:
			return ev[1]
	return null

## Seconds from the press to the first active frame and to the move's end.
func _timing(p: Fighter, action: int) -> Vector2:
	var act := [0.0]
	var end := [0.0]
	var c1 := func(_id: StringName) -> void: act[0] = TimeDirector.now()
	var c2 := func(_id: StringName) -> void: end[0] = TimeDirector.now()
	p.combat.attack_active.connect(c1)
	p.combat.attack_ended.connect(c2)
	var t0 := TimeDirector.now()
	tap(p, action)
	await wait_until(func() -> bool: return end[0] > 0.0, 2.0)
	p.combat.attack_active.disconnect(c1)
	p.combat.attack_ended.disconnect(c2)
	return Vector2(act[0] - t0, end[0] - t0)

func run() -> void:
	print("frame data by strike class (Tuning.STRIKE_FRAMES)")
	var by_class := {&"jab": &"jab1", &"cross": &"cross", &"kick": &"sparta_kick", &"sweep": &"leg_sweep",
		&"knee": &"knee_strike", &"elbow": &"elbow", &"ground": &"ground_stomp"}
	for cls: StringName in by_class:
		var m := MoveLibrary.get_move(by_class[cls])
		var f: Vector3 = Tuning.STRIKE_FRAMES[cls]
		check(m.strike_class == cls and m.startup == f.x and m.active == f.y and m.recovery == f.z,
			"%s (%s): %d / %d / %d frames" % [m.id, cls, f.x, f.y, f.z])
		check(is_equal_approx(m.recovery_s(true), Tuning.frames(f.z) * (1.0 - Tuning.HIT_RECOVERY_CUT)),
			"%s: recovery on a hit cut %d%%" % [m.id, int(Tuning.HIT_RECOVERY_CUT * 100.0)])
	for id: StringName in [&"jab2", &"hook", &"uppercut", &"roundhouse", &"backfist", &"crouch_punch",
			&"rising_uppercut", &"knee_drop"]:
		var m2 := MoveLibrary.get_move(id)
		check(Tuning.STRIKE_FRAMES.has(m2.strike_class) and m2.startup == Tuning.STRIKE_FRAMES[m2.strike_class].x,
			"%s uses its class's frames (%s)" % [id, m2.strike_class])

	print("measured: a whiffed jab, a landed jab, a whiffed sprint jab")
	var pw := spawn(&"player", Vector3(-20, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	await ticks(15)
	var w := await _timing(pw, A.LIGHT)
	var jf: Vector3 = Tuning.STRIKE_FRAMES[&"jab"]
	print("  whiffed jab: active at %.3f s, ended at %.3f s (want %.3f / %.3f)" % [w.x, w.y,
		Tuning.frames(jf.x), Tuning.frames(jf.x + jf.y + jf.z)])
	check(absf(w.x - Tuning.frames(jf.x)) < 0.012, "jab startup %d frames" % jf.x)
	check(absf(w.y - Tuning.frames(jf.x + jf.y + jf.z)) < 0.012, "whiffed jab lasts %d frames" % (jf.x + jf.y + jf.z))
	var p := spawn(&"player", Vector3(0, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(0, 0, -1.0), Vector3.BACK)
	await ticks(15)
	var h := await _timing(p, A.LIGHT)
	var hs := minf(Power.hitstop_for(T.FLINCH), Tuning.PLAYER_HITSTOP_MAX)
	var want_hit := Tuning.frames(jf.x + jf.y) + Tuning.frames(jf.z) * (1.0 - Tuning.HIT_RECOVERY_CUT) + hs
	print("  landed jab: ended at %.3f s (want %.3f incl. %.3f hitstop)" % [h.y, want_hit, hs])
	check(absf(h.y - want_hit) < 0.02, "a landed jab recovers 40%% faster")
	var ps := spawn(&"player", Vector3(-40, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var tv: Traversal = TraversalDouble.new()
	ps.add_child(tv)
	tv.setup(ps)
	ps.traversal = tv
	tv.set(&"speed", 8.0)
	tv.set(&"sprinting", true)
	await ticks(15)
	var sw := await _timing(ps, A.LIGHT)
	var want_sw := Tuning.frames(jf.x + jf.y + jf.z + Tuning.SPRINT_WHIFF_FRAMES)
	print("  whiffed sprint jab: ended at %.3f s (want %.3f)" % [sw.y, want_sw])
	check(absf(sw.y - want_sw) < 0.012, "a missed sprint strike adds %d frames" % int(Tuning.SPRINT_WHIFF_FRAMES))
	var kp := spawn(&"player", Vector3(-60, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	await ticks(15)
	var kw := await _timing(kp, A.KICK)
	var kf: Vector3 = Tuning.STRIKE_FRAMES[&"kick"]
	check(absf(kw.x - Tuning.frames(kf.x)) < 0.012 and absf(kw.y - Tuning.frames(kf.x + kf.y + kf.z)) < 0.012,
		"whiffed kick: %d / %d / %d frames (%.3f, %.3f s)" % [kf.x, kf.y, kf.z, kw.x, kw.y])

	print("sweep: tapped stumble, level-3 knockdown")
	await wait_real(Tuning.COMBO_DROP + 0.2)
	var p2 := spawn_fake(&"player", Vector3(10, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	var g2 := spawn(&"grunt", Vector3(10, 0, -1.1), Vector3.BACK)
	await ticks(20)
	clear_events()
	tap(p2, A.SWEEP)
	await wait_until(func() -> bool: return _hit_info(&"leg_sweep") != null, 1.0)
	var info := _hit_info(&"leg_sweep")
	check(info != null and info.tier == T.STUMBLE and is_equal_approx(info.power, 1.5), "tapped sweep: P 1.5, stumble")
	check(g2.combat.is_stumbling() and not g2.is_down(), "stumbling on its feet")
	check(info != null and is_equal_approx(info.damage, Power.strike_damage(&"sweep", 0)), "sweep damage")
	check(info != null and info.hit_bone in [&"LeftLowerLeg", &"RightLowerLeg", &"LeftFoot", &"RightFoot"], "sweep hits a leg")
	await wait_real(float(Tuning.REACT_STUMBLE["act"]) + 0.4)
	check(not g2.combat.is_stumbling() and not g2.is_down(), "an unpunished stumble recovers")
	await wait_real(Tuning.COMBO_DROP)
	clear_events()
	await hold_press(p2, A.SWEEP, Tuning.CHARGE_LEVELS[2] + 0.05)
	await wait_until(func() -> bool: return _hit_info(&"leg_sweep") != null, 1.0)
	info = _hit_info(&"leg_sweep")
	check(info != null and info.charge_level == 3 and info.tier == T.KNOCKDOWN, "level-3 sweep: P %.1f, knockdown" % (info.power if info else 0.0))
	await ticks(4)
	check(g2.is_down(), "the knocked-down grunt goes down")

	print("a sweep at P 7 or more still flies as a launch (P is clamped for its flight)")
	await wait_real(Tuning.COMBO_DROP)
	var p8 := spawn_fake(&"player", Vector3(70, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	var g8 := spawn(&"grunt", Vector3(70, 0, -2.6), Vector3.BACK)
	var t8: Traversal = TraversalDouble.new()
	p8.add_child(t8)
	t8.setup(p8)
	p8.traversal = t8
	t8.set(&"speed", 8.0)
	t8.set(&"sprinting", true)
	await ticks(15)
	clear_events()
	await hold_press(p8, A.SWEEP, Tuning.CHARGE_LEVELS[2] + 0.05)
	await wait_until(func() -> bool: return _hit_info(&"leg_sweep") != null, 1.5)
	info = _hit_info(&"leg_sweep")
	if info != null:
		var lv := info.launch_velocity
		var ang := rad_to_deg(atan2(lv.y, Vector2(lv.x, lv.z).length()))
		print("  sprint level-3 sweep: P %.2f tier %s, launch %.2f m/s at %.1f deg, damage %.1f" % [info.power,
			HitInfo.tier_name(info.tier), lv.length(), ang, info.damage])
		check(info.power >= 7.0 and info.tier == T.LAUNCH, "P %.1f sweep: the launch tier" % info.power)
		check(lv.length() < Power.launch_speed(7.0) and absf(ang - Tuning.LAUNCH_ANGLE) < 0.5, "flies like a launch (under 10 m/s, 30 deg)")
		check(info.damage < Power.strike_damage(&"sweep", 3) + Power.launch_damage(7.0, g8.max_hp), "launch damage of the launch band")
	else:
		check(false, "the sprint sweep landed")

	print("enemy roster: preset tiers, damage, startup")
	var tiers := {&"e_jab": T.FLINCH, &"e_hook": T.FLINCH, &"e_kick": T.STAGGER, &"e_stick_swing": T.STAGGER,
		&"e_stick_thrust": T.FLINCH, &"e_heavy": T.STAGGER, &"e_charge": T.KNOCKDOWN}
	for id: StringName in [&"e_jab", &"e_hook", &"e_kick", &"e_grab", &"e_stick_swing", &"e_stick_thrust",
			&"e_heavy", &"e_charge", &"e_grab_slam"]:
		var m := MoveLibrary.get_move(id)
		check(m != null and m.enemy and is_equal_approx(m.damage, Tuning.DMG_ENEMY[id]), "%s: enemy move, damage %.0f" % [id, Tuning.DMG_ENEMY[id]])
		if tiers.has(id):
			check(m.preset_tier == tiers[id], "%s: %s on the player" % [id, HitInfo.tier_name(tiers[id])])
	check(MoveLibrary.get_move(&"e_stick_swing").reach >= 2.2, "the stick reaches 2.2 m")
	check(MoveLibrary.get_move(&"e_grab").kind == &"grab" and MoveLibrary.get_move(&"e_grab_slam").kind == &"grab", "grabs")

	print("enemy attack: startup from AttackDirector, the tell, a stagger on the player")
	var p3 := spawn(&"player", Vector3(20, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e3 := spawn(&"grunt", Vector3(20, 0, -1.2), Vector3.BACK)
	await ticks(20)
	clear_events()
	var tells := []
	GameEvents.attack_tell.connect(func(a: Node3D, k: StringName, d: float) -> void: tells.append([a, k, d]))
	var ta := [0.0]
	e3.combat.attack_active.connect(func(_id: StringName) -> void: ta[0] = TimeDirector.now())
	var su := Tuning.frames(AttackDirector.enemy_startup_frames(&"e_kick"))
	var t0 := TimeDirector.now()
	check(e3.combat.start_enemy_attack(&"e_kick", 0.2), "e_kick started (a shorter tell is ignored)")
	check(tells.size() == 1 and tells[0][1] == &"strike" and absf(tells[0][2] - su) < 0.001,
		"attack_tell strike %.3f s (AttackDirector startup)" % su)
	check(not e3.combat.start_enemy_attack(&"e_hook", 0.4), "cannot start a second attack mid-move")
	await wait_until(func() -> bool: return ta[0] > 0.0, 1.0)
	check(absf(ta[0] - t0 - su) < 0.02, "active after %.3f s (%.0f frames)" % [ta[0] - t0, su * 60.0])
	await wait_until(func() -> bool: return _hit_info(&"e_kick") != null, 0.5)
	info = _hit_info(&"e_kick")
	check(info != null and info.tier == T.STAGGER and info.launch_velocity == Vector3.ZERO, "e_kick staggers the player, no launch")
	check(info != null and is_equal_approx(info.damage, Tuning.DMG_ENEMY[&"e_kick"]), "e_kick damage %.0f" % Tuning.DMG_ENEMY[&"e_kick"])
	check(not p3.is_down(), "the player stays on its feet")
	tells.clear()
	await wait_real(1.5)
	check(e3.combat.start_enemy_attack(&"e_grab", 0.5), "e_grab started")
	check(tells.size() == 1 and tells[0][1] == &"grab", "grab tell (&\"grab\")")
	await wait_real(1.5)

	print("damage x the brain's get_damage_mult (one-armed enemies hit at half)")
	var p7 := spawn(&"player", Vector3(25, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e7 := spawn(&"grunt", Vector3(25, 0, -1.1), Vector3.BACK)
	var half := Node.new()
	half.set_script(_half_brain_script())
	e7.add_child(half)
	e7.brain = half
	await ticks(15)
	clear_events()
	e7.combat.start_enemy_attack(&"e_jab", 0.3)
	await wait_until(func() -> bool: return _hit_info(&"e_jab") != null, 1.5)
	info = _hit_info(&"e_jab")
	check(info != null and is_equal_approx(info.damage, Tuning.DMG_ENEMY[&"e_jab"] * 0.5), "a half-damage brain's jab: %.1f" % (info.damage if info else -1.0))
	p7.queue_free()

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
		check(info.kind == &"projectile" and info.tier == T.STAGGER, "a projectile hit: stagger")
		check(is_equal_approx(hp0 - p4.hp, Tuning.DMG_ENEMY[&"e_throw_debris"]), "projectile damage %.0f" % (hp0 - p4.hp))
	done()

## A brain that only answers get_damage_mult() = 0.5.
func _half_brain_script() -> GDScript:
	var s := GDScript.new()
	s.source_code = "extends Node\nfunc get_damage_mult() -> float:\n\treturn 0.5\n"
	s.reload()
	return s
