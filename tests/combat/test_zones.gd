extends "res://tests/combat/combat_test_base.gd"
## Body zones (Round 5, lead decision): zone aiming picks the hit zone and the
## hit chain (a head-aimed jab hits the Head bone and is high; a leg-aimed one a
## leg bone) with the Round 5 damage table; a head-aimed kick passes over a
## crouch. The Upgrade 2 zone effects are gone: no leg slow, no arm damage
## build-up or arm break, no cancel from hitting the attacking arm (the heavy
## ignores a jab anywhere). In Focus the player's frame data runs in real time.
## Body-part grabs are Carry's (agent G, tests/grab).

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

## The aimed zone applies only to the aimed target (Fighter.zone_for).
func _aim(p: Fighter, zone: int, target: Fighter) -> void:
	p.aim_target = target
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
	print("head: the aimed bone, high, the Round 5 damage")
	var pe: Array = await _lane()
	_aim(pe[0], BodyZones.Zone.HEAD, pe[1])
	clear_events()
	tap(pe[0], L)
	await wait_until(func() -> bool: return _last_hit_on(pe[1]) != null, 1.0)
	var h := _last_hit_on(pe[1])
	check(h != null and h.zone == BodyZones.Zone.HEAD and h.hit_bone == &"Head", "a head jab hits the Head chain (%s)" % [h.hit_bone if h else &"-"])
	check(h != null and is_equal_approx(h.damage, Power.strike_damage(&"jab", 0)), "damage %.1f (no zone multiplier)" % (h.damage if h else -1.0))
	check(h != null and h.level == HitInfo.Level.HIGH, "a head strike is high")
	check(is_equal_approx((pe[1] as Fighter).combat._stun_left, float(Tuning.REACT_FLINCH["act"])), "flinch act-again time")
	pe = await _lane(&"grunt", 1.3, true)
	_aim(pe[0], BodyZones.Zone.HEAD, pe[1])
	(pe[1] as Fighter).fake_crouch = true
	var hp0: float = (pe[1] as Fighter).hp
	tap(pe[0], K)  # front kick is MID, but aimed at the head it is high
	await wait_real(0.6)
	check(is_equal_approx((pe[1] as Fighter).hp, hp0), "a head-aimed kick passes over a crouch")

	print("legs: the leg chain, no slow")
	pe = await _lane()
	var p: Fighter = pe[0]
	var e: Fighter = pe[1]
	_aim(p, BodyZones.Zone.LEGS, e)
	clear_events()
	tap(p, L)
	await wait_until(func() -> bool: return _last_hit_on(e) != null, 1.0)
	h = _last_hit_on(e)
	check(h != null and h.zone == BodyZones.Zone.LEGS and h.hit_bone == BodyZones.AIM_BONE[BodyZones.Zone.LEGS],
		"a leg jab hits the leg chain (%s)" % [h.hit_bone if h else &"-"])
	await wait_until(func() -> bool: return not e.combat.is_stunned(), 1.0)
	check(is_equal_approx(e.combat.get_move_speed_mult(), 1.0), "no leg slow (walk x%.2f)" % e.combat.get_move_speed_mult())

	print("arms: no damage build-up, no arm break")
	pe = await _lane()
	p = pe[0]
	e = pe[1]
	e.max_hp = 1000.0
	e.hp = e.max_hp
	clear_events()
	for i in 3:
		_zone_hit(p, e, BodyZones.Zone.ARM_R, 40.0)
		await wait_real(0.5)
	check(count_events(&"limb_damaged") == 0 and count_events(&"arm_broken") == 0, "120 damage on one arm: no build-up, no break")
	e.combat.press(CombatController.Action.BLOCK)
	await ticks(3)
	check(e.combat._blocks(_fake_strike(p)), "it still guards")
	e.combat.release(CombatController.Action.BLOCK)
	clear_events()
	var php := p.hp
	e.combat.start_enemy_attack(&"e_hook", 0.35)  # RightHand, the much-hit arm
	await wait_until(func() -> bool: return p.hp < php, 2.0)
	check(is_equal_approx(php - p.hp, Tuning.DMG_ENEMY[&"e_hook"]), "its attacks with that arm hit at full damage (%.1f)" % (php - p.hp))
	await wait_real(1.0)

	print("hitting the attacking arm is a normal hit")
	pe = await _lane(&"duelist", 1.2)
	p = pe[0]
	e = pe[1]
	var went_active := [false]
	e.combat.attack_active.connect(func(_id: StringName) -> void: went_active[0] = true)
	clear_events()
	e.combat.start_enemy_attack(&"e_heavy", 0.55)
	await wait_real(0.05)
	_aim(p, BodyZones.of_bone(MoveLibrary.get_move(&"e_heavy").limb), e)
	tap(p, L)
	await wait_real(0.6)
	check(count_events(&"armor_absorbed") == 1 and went_active[0], "the Duelist's tell armor absorbs a jab on the attacking arm too")
	await wait_real(1.5)
	pe = await _lane(&"heavy", 1.3)
	p = pe[0]
	e = pe[1]
	clear_events()
	e.combat.start_enemy_attack(&"e_heavy", 0.6)
	await wait_real(0.05)
	_aim(p, BodyZones.of_bone(MoveLibrary.get_move(&"e_heavy").limb), e)
	tap(p, L)
	await wait_real(0.25)
	check(count_events(&"armor_absorbed") == 1 and e.combat.is_attacking(), "the heavy ignores a jab on the attacking arm")
	await wait_real(2.0)

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
	var want_all := Tuning.frames(kick.startup + kick.active) + kick.recovery_s(false)
	check(Engine.time_scale < 0.5, "world slowed (%.2fx)" % Engine.time_scale)
	check(absf((t_act[0] - t0) - want_act) <= want_act * 0.05 + 1.0 / 120.0,
		"kick startup %.3f s real in Focus (normal %.3f s)" % [t_act[0] - t0, want_act])
	check(absf((t_act[1] - t0) - want_all) <= want_all * 0.05 + 1.0 / 120.0,
		"whole whiffed kick %.3f s real in Focus (normal %.3f s)" % [t_act[1] - t0, want_all])
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
