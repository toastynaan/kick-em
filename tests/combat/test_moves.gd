extends "res://tests/combat/combat_test_base.gd"
## Round 7 moves (docs/Round 7 — Freeflow Combat.md: Moves), with Round 8's
## strikes (docs/Round 8 — Charge and Pressure.md: Moves):
## - the player's kit is exactly the twelve Tuning.R7_MOVES ids (the eight
##   strikes of R8_MOVES on their "tap" entry's frame data and damage, never
##   breaking a guard; their charged versions on R8_RELEASE_STARTUP, the tap's
##   active frames and its recovery + R8_CHARGED_EXTRA_RECOVERY, breaking
##   guards; their air strikes on R8_AIR_FRAMES; the Round 7 heavies, the
##   counter and the dropping strike on R7_MOVES), each with its
##   frame data and damage, an anim the PoseLibrary plays (its own pose once
##   agent P adds it, else a fallback), its striking limbs, and where it lands:
##   punches, the uppercut and the roundhouse at the head (high), the gut punch
##   at the waist, the leg kick low;
## - measured on real moves: startup / active / recovery on a miss in frames of
##   the fighter's own time (legacy Heavy: the string's jab charged to full at
##   once, on its charged frames); on a hit the move ends after R7_CHAIN_CUT of its
##   recovery (plus the move's hitstop, which stops the attacker's clock);
## - enemy moves: preset tiers on the player (Round 5, kept), damage from
##   Tuning.DMG_ENEMY, counterable except grabs and the shoulder charge,
##   startup from AttackDirector, the tell, the Thrower's projectile.

const T := HitInfo.Tier
## Real s of slack on a measured phase (one 120 Hz tick plus rounding).
const SLACK := 0.011

func _init() -> void:
	_timeout = 90.0

func run() -> void:
	print("the player's kit")
	var ids: Array = Tuning.R7_MOVES.keys()
	ids.append_array(MoveLibrary.LOCAL_R7.keys())
	check(MoveLibrary.PLAYER_MOVES.size() == ids.size() and ids.all(func(id) -> bool: return MoveLibrary.PLAYER_MOVES.has(id)),
		"PLAYER_MOVES is exactly the %d R7_MOVES ids and the dropping strike" % Tuning.R7_MOVES.size())
	for id: StringName in MoveLibrary.PLAYER_MOVES:
		var m := MoveLibrary.get_move(id)
		var r8 := Tuning.R8_MOVES.has(id)
		var e: Dictionary = {}
		if m != null:
			e = (Tuning.R8_MOVES[id]["tap"] as Dictionary).duplicate() if r8 else m.r7_entry()
		if r8:
			e["guard_break"] = false  # Round 8: taps never break a guard
		var f: Vector3 = e["f"]
		var ok := m != null and m.r7 and m.r8 == r8 and m.kind == &"strike" and Vector3(m.startup, m.active, m.recovery) == f \
			and is_equal_approx(m.damage, e["dmg"]) and m.guard_break == bool(e["guard_break"])
		check(ok, "%s: %d/%d/%d frames, %.0f damage, guard break %s%s" % [id, f.x, f.y, f.z, e["dmg"], e["guard_break"],
			" (Round 8 tap)" if r8 else ""])
		if m == null:
			continue
		if r8:
			var cm := MoveLibrary.charged_move(id)
			var am := MoveLibrary.air_move(id)
			var cf := Vector3(Tuning.R8_RELEASE_STARTUP, f.y, f.z + Tuning.R8_CHARGED_EXTRA_RECOVERY)
			check(cm != null and cm.charged and cm.guard_break and cm.id == id and Vector3(cm.startup, cm.active, cm.recovery) == cf
				and PoseLibrary.has_move(cm.anim) and cm != m, "%s charged: %d/%d/%d frames, breaks guards, plays %s" % [id,
				cf.x, cf.y, cf.z, cm.anim if cm else &"-"])
			check(am != null and am.air and not am.charged and am.id == id and Vector3(am.startup, am.active, am.recovery) == Tuning.R8_AIR_FRAMES
				and PoseLibrary.has_move(am.anim), "%s in the air: R8_AIR_FRAMES, plays %s" % [id, am.anim if am else &"-"])
			check(m.charge_hold != &"" and PoseLibrary.HOLDS.has(m.charge_hold), "%s charges in %s" % [id, m.charge_hold])
		var own := PoseLibrary.has_move(id)
		check(PoseLibrary.has_move(m.anim) and (m.anim == id or not own),
			"%s plays %s%s" % [id, m.anim, "" if m.anim == id else " (fallback until P poses it)"])
		var sb: Array = PoseLibrary.STRIKE_BONES.get(id, PoseLibrary.STRIKE_BONES.get(m.anim, []))
		check(not m.limbs.is_empty() and (sb.is_empty() or m.limbs[0] == StringName(sb[0])),
			"%s strikes with %s" % [id, m.limbs])
		check(is_equal_approx(m.recovery_s(true), Tuning.frames(f.z * Tuning.R7_CHAIN_CUT))
			and is_equal_approx(m.recovery_s(false), Tuning.frames(f.z)), "%s: recovery cut to %.0f%% on a hit" % [id, Tuning.R7_CHAIN_CUT * 100.0])
	var gp := MoveLibrary.get_move(&"gut_punch")
	var lk := MoveLibrary.get_move(&"leg_kick")
	check(gp.height >= 0.9 and gp.height <= 1.1 and gp.target_bone in [Bones.SPINE, Bones.HIPS],
		"the gut punch lands at the waist (%.2f m, %s)" % [gp.height, gp.target_bone])
	check(lk.height <= 0.6 and lk.hit_level == HitInfo.Level.LOW and String(lk.target_bone).contains("Leg"),
		"the leg kick lands low (%.2f m, %s)" % [lk.height, lk.target_bone])
	for id: StringName in [&"uppercut", &"roundhouse", &"jab", &"cross", &"hook"]:
		var hm := MoveLibrary.get_move(id)
		check(hm.hit_level == HitInfo.Level.HIGH and hm.height >= 1.4 and hm.target_bone == Bones.HEAD,
			"%s lands high, at the head" % id)
	check(MoveLibrary.get_move(&"uppercut").push_dir.y > 0.5, "the uppercut pushes up")
	check(MoveLibrary.get_move(&"hook").push_dir.x > 0.5 and MoveLibrary.get_move(&"roundhouse").push_dir.x < -0.5,
		"the hook pushes to the attacker's right, the roundhouse to its left")
	check(MoveLibrary.get_move(&"front_kick").push_dir.is_equal_approx(Vector3(0, 0, 1)), "the front kick pushes straight")
	for gone: StringName in [&"jab1", &"jab2", &"elbow", &"knee_strike", &"sparta_kick", &"leg_sweep", &"backfist",
			&"crouch_punch", &"rising_uppercut", &"ground_stomp", &"knee_drop"]:
		check(not MoveLibrary.has_move(gone), "%s is gone" % gone)

	print("measured frame data (fighter's own time)")
	var p := spawn_fake(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	await ticks(15)
	for spec: Array in [[A.LIGHT, &"jab"], [A.HEAVY, &"jab"], [A.UPPERCUT, &"uppercut"],
			[A.GUT_PUNCH, &"gut_punch"], [A.LEG_KICK, &"leg_kick"], [A.FRONT_KICK, &"front_kick"],
			[A.ROUNDHOUSE, &"roundhouse"]]:
		if spec[0] == A.HEAVY:
			# Round 9: the string holds through the jab's whiff; it is back at the jab after R9_STRING_RESET.
			await wait_until(func() -> bool: return p.combat.get_string_index() == 0, Tuning.R9_STRING_RESET + 0.5)
		var r: Dictionary = await _measure(p, spec[0])
		var f: Vector3 = Tuning.R8_MOVES[spec[1]]["tap"]["f"]
		var label: String = String(spec[1])
		if spec[0] == A.HEAVY:
			f = Vector3(Tuning.R8_RELEASE_STARTUP, f.y, f.z + Tuning.R8_CHARGED_EXTRA_RECOVERY)
			label = "Heavy (the jab charged to full)"
		print("  %s miss: startup %.3f active %.3f recovery %.3f s (want %.3f / %.3f / %.3f)" % [label,
			r["startup"], r["active"], r["recovery"], Tuning.frames(f.x), Tuning.frames(f.y), Tuning.frames(f.z)])
		check(r["move"] == spec[1] and absf(r["startup"] - Tuning.frames(f.x)) <= SLACK
			and absf(r["active"] - Tuning.frames(f.y)) <= SLACK and absf(r["recovery"] - Tuning.frames(f.z)) <= SLACK,
			"%s whiffs on its frame data with the full recovery" % label)
		await ticks(4)
	print("on a hit: the recovery is cut (+ the move's hitstop on the attacker)")
	var g := spawn(&"grunt", Vector3(0, 0, -1.0), Vector3.BACK)
	await ticks(15)
	for spec: Array in [[A.LIGHT, &"jab"], [A.ROUNDHOUSE, &"roundhouse"]]:
		await wait_real(1.6)
		if g.is_down() or g.is_dead():
			break
		place_in_front(p, g, 1.0)
		await ticks(6)
		var e: Dictionary = Tuning.R8_MOVES[spec[1]]["tap"]
		var f: Vector3 = e["f"]
		var r: Dictionary = await _measure(p, spec[0])
		var want_rec := Tuning.frames(f.z * Tuning.R7_CHAIN_CUT)
		var want_act := Tuning.frames(f.y) + float(e["hitstop"])
		print("  %s hit: startup %.3f active+hitstop %.3f recovery %.3f s (want %.3f / %.3f / %.3f)" % [spec[1],
			r["startup"], r["active"], r["recovery"], Tuning.frames(f.x), want_act, want_rec])
		check(r["hit"] and absf(r["startup"] - Tuning.frames(f.x)) <= SLACK and absf(r["active"] - want_act) <= 0.02
			and absf(r["recovery"] - want_rec) <= SLACK, "%s on a hit: recovery %.3f s (%.0f%%)" % [spec[1], r["recovery"],
			Tuning.R7_CHAIN_CUT * 100.0])

	print("enemy roster: preset tiers on the player, damage, counterable")
	var tiers := {&"e_jab": T.FLINCH, &"e_hook": T.FLINCH, &"e_kick": T.STAGGER, &"e_stick_swing": T.STAGGER,
		&"e_stick_thrust": T.FLINCH, &"e_heavy": T.STAGGER, &"e_charge": T.KNOCKDOWN, &"e_grab": T.KNOCKDOWN,
		&"e_grab_slam": T.KNOCKDOWN}
	for id: StringName in tiers:
		var m := MoveLibrary.get_move(id)
		check(m != null and m.enemy and not m.r7 and is_equal_approx(m.damage, Tuning.DMG_ENEMY[id])
			and m.preset_tier == tiers[id], "%s: %s on the player, damage %.0f" % [id, HitInfo.tier_name(tiers[id]), Tuning.DMG_ENEMY[id]])
		var counterable := not (id in [&"e_grab", &"e_grab_slam", &"e_charge"])
		check(m != null and m.counterable == counterable, "%s %s" % [id, "can be countered" if counterable else "cannot be countered (blue)"])
	check(MoveLibrary.get_move(&"e_stick_swing").reach >= 2.2, "the stick reaches 2.2 m")

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
	await wait_until(func() -> bool: return last_hit(&"e_kick") != null, 0.5)
	var info := last_hit(&"e_kick")
	check(info != null and info.tier == T.STAGGER and info.react == &"" and info.launch_velocity == Vector3.ZERO,
		"e_kick staggers the player (a Round 5 tier, no Round 7 reaction, no launch)")
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
	await wait_until(func() -> bool: return last_hit(&"e_jab") != null, 1.5)
	info = last_hit(&"e_jab")
	check(info != null and is_equal_approx(info.damage, Tuning.DMG_ENEMY[&"e_jab"] * 0.5), "a half-damage brain's jab: %.1f" % (info.damage if info else -1.0))
	p7.queue_free()

	print("thrower projectile")
	var p4 := spawn(&"player", Vector3(30, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var th := spawn(&"thrower", Vector3(30, 0, -7.0), Vector3.BACK)
	await ticks(20)
	clear_events()
	var hp0 := p4.hp
	check(th.combat.start_enemy_attack(&"e_throw_debris", 0.4), "throw started")
	var ok := await wait_until(func() -> bool: return last_hit(&"e_throw_debris") != null, 3.0)
	check(ok, "debris chunk hit the player")
	if ok:
		info = last_hit(&"e_throw_debris")
		check(info.kind == &"projectile" and info.tier == T.STAGGER, "a projectile hit: stagger")
		check(is_equal_approx(hp0 - p4.hp, Tuning.DMG_ENEMY[&"e_throw_debris"]), "projectile damage %.0f" % (hp0 - p4.hp))
	done()

## Tap `action` and time the move's phases (real s; the fake player runs in real time).
func _measure(p: Fighter, action: int) -> Dictionary:
	var moves := record_moves(p)
	var hit := [false]
	var cb := func(_i: HitInfo) -> void: hit[0] = true
	p.combat.hit_dealt.connect(cb)
	await get_tree().physics_frame
	var t0 := TimeDirector.now()
	tap(p, action)
	var ta := -1.0
	var tr := -1.0
	var te := -1.0
	while TimeDirector.now() - t0 < 3.0:
		await get_tree().physics_frame
		var now := TimeDirector.now()
		if ta < 0.0 and p.combat.is_attack_active():
			ta = now
		if tr < 0.0 and p.combat.is_in_recovery():
			tr = now
		if not p.combat.is_attacking():
			te = now
			break
	p.combat.hit_dealt.disconnect(cb)
	return {"move": moves[0] if not moves.is_empty() else &"", "startup": ta - t0, "active": tr - ta,
		"recovery": te - tr, "hit": hit[0]}

## A brain that only answers get_damage_mult() = 0.5.
func _half_brain_script() -> GDScript:
	var s := GDScript.new()
	s.source_code = "extends Node\nfunc get_damage_mult() -> float:\n\treturn 0.5\n"
	s.reload()
	return s
