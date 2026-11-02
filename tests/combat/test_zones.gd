extends "res://tests/combat/combat_test_base.gd"
## Upgrade 2 zones and grabs (U5) and Focus (U6): head / arm / legs effects,
## arm break, grabs by zone (headlock, limb grab or socket fallback, wall slam,
## downed pick-up), and free pursuits inside a Focus burst.

const L := CombatController.Action.LIGHT
const K := CombatController.Action.KICK
var _x := 0.0

func _init() -> void:
	_timeout = 120.0

func _lane(arch := &"grunt", dist := 1.0, e_fake := false) -> Array:
	_x += 9.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	var e: Fighter = spawn_fake(arch, Vector3(_x, 0, -dist), Vector3.BACK) if e_fake \
		else spawn(arch, Vector3(_x, 0, -dist), Vector3.BACK)
	await ticks(12)
	return [p, e]

func _aim(p: Fighter, zone: int) -> void:
	p.aim_zone = zone
	p.aim_bone = BodyZones.AIM_BONE[zone]

func _last_hit_on(e: Fighter) -> HitInfo:
	for i in range(events.size() - 1, -1, -1):
		var ev: Array = events[i]
		if ev[0] == &"hit_landed" and (ev[1] as HitInfo).victim == e:
			return ev[1]
	return null

## A crafted hit on `zone` (zone damage builds whatever the attacker).
func _zone_hit(att: Fighter, victim: Fighter, zone: int, dmg: float) -> int:
	var info := HitInfo.new()
	info.attacker = att
	info.move_id = &"jab1"
	info.kind = &"strike"
	info.damage = dmg
	info.reaction = HitInfo.Reaction.FLINCH
	info.zone = zone
	info.hit_direction = Vector3.FORWARD
	info.hit_bone = BodyZones.AIM_BONE[zone]
	info.hit_position = victim.get_aim_point()
	return victim.take_hit(info)

func run() -> void:
	print("head: +30%, high, longer stun")
	var pe: Array = await _lane()
	_aim(pe[0], BodyZones.Zone.HEAD)
	clear_events()
	tap(pe[0], L)
	await wait_until(func() -> bool: return _last_hit_on(pe[1]) != null, 1.0)
	var h := _last_hit_on(pe[1])
	check(h != null and h.zone == BodyZones.Zone.HEAD and is_equal_approx(h.damage, Tuning.DMG_JAB * Tuning.ZONE_HEAD_DAMAGE),
		"head jab x%.1f (%.1f)" % [Tuning.ZONE_HEAD_DAMAGE, h.damage if h else -1.0])
	check(h != null and h.level == HitInfo.Level.HIGH, "a head strike is high")
	check((pe[1] as Fighter).combat._stun_left > MoveLibrary.get_move(&"jab1").hitstun, "head hit stuns longer")
	pe = await _lane(&"grunt", 1.3, true)
	_aim(pe[0], BodyZones.Zone.HEAD)
	(pe[1] as Fighter).fake_crouch = true
	var hp0: float = (pe[1] as Fighter).hp
	tap(pe[0], K)  # front kick is MID, but aimed at the head it is high
	await wait_real(0.6)
	check(is_equal_approx((pe[1] as Fighter).hp, hp0), "a head-aimed kick passes over a crouch")

	print("arm: hitting the attacking arm cancels the wind-up (armour or not)")
	pe = await _lane(&"grunt", 1.2)
	var p: Fighter = pe[0]
	var e: Fighter = pe[1]
	var arm := BodyZones.of_bone(MoveLibrary.get_move(&"e_heavy").limb)
	check(BodyZones.is_arm(arm), "e_heavy strikes with an arm (%s)" % BodyZones.name_of(arm))
	var went_active := [false]
	e.combat.attack_active.connect(func(_id: StringName) -> void: went_active[0] = true)
	clear_events()
	e.combat.start_enemy_attack(&"e_heavy", 0.55)
	await wait_real(0.05)
	_aim(p, arm)
	tap(p, L)
	await wait_real(0.6)
	check(count_events(&"armor_absorbed") == 0 and not went_active[0], "jab on the attacking arm cancelled the armoured heavy")
	await wait_real(1.0)
	pe = await _lane(&"grunt", 1.2)
	p = pe[0]
	e = pe[1]
	var other := BodyZones.Zone.ARM_R if arm == BodyZones.Zone.ARM_L else BodyZones.Zone.ARM_L
	clear_events()
	e.combat.start_enemy_attack(&"e_heavy", 0.55)
	await wait_real(0.05)
	_aim(p, other)
	tap(p, L)
	await wait_real(0.25)
	check(count_events(&"armor_absorbed") == 1 and e.combat.is_attacking(), "the other arm: armour absorbs, the heavy goes on")
	await wait_real(2.0)

	print("arm damage builds and breaks the arm")
	pe = await _lane()
	p = pe[0]
	e = pe[1]
	clear_events()
	for i in 3:
		_zone_hit(p, e, BodyZones.Zone.ARM_R, 40.0)
		await wait_real(0.5)
	var totals: Array = []
	for ev in events:
		if ev[0] == &"limb_damaged" and ev[1] == e:
			totals.append(ev[3])
	check(totals == [40.0, 80.0, 120.0], "limb_damaged totals %s" % [totals])
	check(count_events(&"arm_broken") == 1 and e.combat.is_arm_broken(BodyZones.Zone.ARM_R), "arm broken at %.0f" % Tuning.ARM_BREAK_AT)
	check(count_events(&"dazed") == 1, "a broken arm dazes")
	await wait_real(Tuning.DAZED_TIME + 0.3)
	e.combat.press(CombatController.Action.BLOCK)
	await ticks(3)
	check(not e.combat._blocks(_fake_strike(p)), "no blocking with a broken arm")
	e.combat.release(CombatController.Action.BLOCK)
	clear_events()
	var php := p.hp
	e.combat.start_enemy_attack(&"e_hook", 0.35)  # RightHand, the broken arm
	await wait_until(func() -> bool: return p.hp < php, 2.0)
	check(is_equal_approx(php - p.hp, Tuning.DMG_ENEMY[&"e_hook"] * CombatController.ARM_BROKEN_DAMAGE),
		"attacks with the broken arm are weaker (%.0f)" % (php - p.hp))
	await wait_real(1.0)

	print("legs: slowed")
	pe = await _lane()
	_aim(pe[0], BodyZones.Zone.LEGS)
	tap(pe[0], L)
	await wait_real(0.6)
	e = pe[1]
	check(e.combat._leg_slow_left > 0.0, "leg hit slows")
	await wait_until(func() -> bool: return not e.combat.is_stunned(), 1.0)
	check(is_equal_approx(e.combat.get_move_speed_mult(), 1.0 - Tuning.ZONE_LEG_SLOW),
		"walk x%.1f (%.2f)" % [1.0 - Tuning.ZONE_LEG_SLOW, e.combat.get_move_speed_mult()])

	print("grabs by zone: headlock")
	pe = await _lane()
	p = pe[0]
	e = pe[1]
	_aim(p, BodyZones.Zone.HEAD)
	clear_events()
	p.combat.press(CombatController.Action.GRAB)
	await wait_until(func() -> bool: return count_events(&"grab_started") > 0, 1.0)
	check(p.combat._headlock and p.combat.holding == e, "head grab is a headlock")
	tap(p, L)
	await wait_real(0.15)
	check(_last_hit_on(e) != null and _last_hit_on(e).move_id == &"knee", "P in a headlock: knee")
	p.combat.release(CombatController.Action.GRAB)
	await wait_until(func() -> bool: return count_events(&"thrown") > 0, 1.0)
	check(_last_hit_on(e) != null and _last_hit_on(e).move_id == &"neck_throw", "release: neck throw")
	await wait_real(2.0)
	pe = await _lane()
	p = pe[0]
	e = pe[1]
	_aim(p, BodyZones.Zone.HEAD)
	clear_events()
	p.combat.press(CombatController.Action.GRAB)
	await wait_until(func() -> bool: return count_events(&"grab_started") > 0, 1.0)
	tap(p, K)
	await wait_real(0.2)
	check(_last_hit_on(e) != null and _last_hit_on(e).move_id == &"headbutt", "K in a headlock: headbutt")
	check(p.combat.holding == null and e.combat.is_dazed(), "headbutt releases a dazed enemy")
	p.combat.release(CombatController.Action.GRAB)
	await wait_real(1.5)

	print("grabs by zone: arm (limb grab, or the socket grab as fallback)")
	pe = await _lane()
	p = pe[0]
	e = pe[1]
	_aim(p, BodyZones.Zone.ARM_R)
	clear_events()
	p.combat.press(CombatController.Action.GRAB)
	await wait_until(func() -> bool: return count_events(&"grab_started") > 0, 1.0)
	var limb := p.combat._limb_grab != null
	check(count_events(&"grab_started") == 1 and (limb or p.combat.holding == e),
		"arm grab connected (%s)" % ("LimbGrab" if limb else "socket fallback"))
	check(e.combat.held_by == p, "the victim is held")
	if limb:
		check(is_equal_approx(e.combat._held_break_mult, Tuning.ARM_DRAG_BREAK_MULT), "arm drag: shorter break window")
	await wait_real(0.4)
	p.combat.release(CombatController.Action.GRAB)
	await wait_real(1.0)
	check(e.combat.held_by == null and p.combat._limb_grab == null and p.combat.holding == null, "released")
	await wait_real(2.0)

	print("wall slam: a grab next to a wall drives the head into it")
	_x += 9.0
	var wall := StaticBody3D.new()
	wall.collision_layer = Layers.WORLD
	var wcs := CollisionShape3D.new()
	var wb := BoxShape3D.new()
	wb.size = Vector3(4.0, 3.0, 0.4)
	wcs.shape = wb
	wall.add_child(wcs)
	add_child(wall)
	wall.global_position = Vector3(_x, 1.5, -2.1)  # 1.1 m behind the victim
	var pw := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	var ew := spawn(&"grunt", Vector3(_x, 0, -1.0), Vector3.BACK)
	await ticks(12)
	clear_events()
	pw.combat.press(CombatController.Action.GRAB)
	await wait_until(func() -> bool: return count_events(&"wall_slam") > 0, 1.0)
	check(count_events(&"wall_slam") == 1, "wall_slam emitted")
	var ws := _last_hit_on(ew)
	if ws:
		check(ws.move_id == &"wall_slam" and ws.hit_bone == &"Head", "head first")
		var v := ws.launch_velocity
		check(absf(v.length() - Tuning.WALL_SLAM_SPEED) < 0.1 and v.normalized().dot(Vector3.FORWARD) > 0.95,
			"%.1f m/s into the wall (%s)" % [v.length(), v])
		check(rad_to_deg(asin(v.normalized().y)) <= 5.0, "at most 5 deg up")
	pw.combat.release(CombatController.Action.GRAB)
	await wait_real(2.0)

	print("grab a downed enemy: lift it into the hold")
	pe = await _lane(&"grunt", 1.1)
	p = pe[0]
	e = pe[1]
	await hold_press(p, CombatController.Action.SWEEP, 0.3)
	await wait_until(func() -> bool: return e.get_state() == RagdollController.State.GROUNDED, 4.0)
	var tg := e.get_ground_position() - p.global_position
	tg.y = 0
	p.teleport_to(e.get_ground_position() - tg.normalized() * 0.8, tg)
	await ticks(3)
	_aim(p, BodyZones.Zone.TORSO)
	clear_events()
	p.combat.press(CombatController.Action.GRAB)
	await wait_until(func() -> bool: return count_events(&"grab_started") > 0, 1.0)
	check(p.combat.holding == e and e.get_state() == RagdollController.State.ANIMATED, "downed enemy picked up into the hold")
	p.combat.release(CombatController.Action.GRAB)
	await wait_real(2.0)

	print("Focus: pursuit chains cost no Focus")
	if not TimeDirector.has_method(&"begin_focus") or not TimeDirector.begin_focus():
		print("  SKIP: TimeDirector.begin_focus not available")
		done()
		return
	pe = await _lane(&"grunt", 1.3)
	p = pe[0]
	e = pe[1]
	p.spend_focus(p.focus)
	tap(p, K)
	await wait_until(func() -> bool: return e.is_launched(), 1.5)
	await wait_real(0.1)
	check(p.focus < Tuning.FOCUS_COST and p.combat.can_pursue(), "pursuit available with %.2f Focus inside Focus" % p.focus)
	clear_events()
	var f0 := p.focus
	p.combat.press(CombatController.Action.DASH)
	check(count_events(&"pursuit") == 1 and is_equal_approx(p.focus, f0), "pursued for free (Focus %.2f -> %.2f)" % [f0, p.focus])
	await wait_real(1.0)
	print("Focus: the player's combat timing runs in real time")
	_x += 9.0
	var pf := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	await ticks(10)
	TimeDirector.begin_focus()
	await ticks(3)
	var t_act := [0.0, 0.0]
	pf.combat.attack_active.connect(func(_id: StringName) -> void: t_act[0] = TimeDirector.now())
	pf.combat.attack_ended.connect(func(_id: StringName) -> void: t_act[1] = TimeDirector.now())
	var t0 := TimeDirector.now()
	tap(pf, K)
	await wait_until(func() -> bool: return t_act[1] > 0.0, 3.0)
	var kick := MoveLibrary.get_move(&"sparta_kick")
	var want_act := Tuning.frames(kick.startup)
	var want_all := Tuning.frames(kick.startup + kick.active + kick.recovery)
	check(Engine.time_scale < 0.5, "world slowed (%.2fx)" % Engine.time_scale)
	check(absf((t_act[0] - t0) - want_act) <= want_act * 0.05 + 1.0 / 120.0,
		"kick startup %.3f s real in Focus (normal %.3f s)" % [t_act[0] - t0, want_act])
	check(absf((t_act[1] - t0) - want_all) <= want_all * 0.05 + 1.0 / 120.0,
		"whole kick %.3f s real in Focus (normal %.3f s)" % [t_act[1] - t0, want_all])
	TimeDirector.end_focus()
	done()

func _fake_strike(att: Fighter) -> HitInfo:
	var info := HitInfo.new()
	info.attacker = att
	info.move_id = &"jab1"
	info.kind = &"strike"
	info.level = HitInfo.Level.HIGH
	info.hit_direction = Vector3.FORWARD
	return info
