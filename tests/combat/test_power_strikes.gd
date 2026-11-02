extends "res://tests/combat/combat_test_base.gd"
## F3 acceptance (Feel Reference: One power number decides the reaction).
## Every worked example of the table through a REAL strike on a dummy grunt:
## the press (tap, or a hold for charge levels), the player's speed through a
## Traversal test double (speed_toward / cap; it drops to walk when told, so P
## proves the speed was sampled first), the counter bonus through a Defence
## double. Logs P and tier for each; all 12 must match. Then the launch speed
## and angle measured from the victim's body at P 5, 7, 9 and 11 against
## v = clamp(6 + 2 (P - 5), 6, 18) at 30 deg (18 deg from P 7). Last, a full
## grunt hit by a level-3 kick with no wall keeps health above 0 and gets up.

const TraversalDouble := preload("res://tests/combat/traversal_double.gd")
const DefenceDouble := preload("res://tests/combat/defence_double.gd")
const A := CombatController.Action
const T := HitInfo.Tier

var _lane := 0

func _init() -> void:
	_timeout = 120.0

## Fresh player + grunt pair on its own lane, with the doubles attached.
func _pair(speed: float, counter: float, cap: float, dist: float) -> Dictionary:
	var x := float(_lane) * 16.0
	_lane += 1
	var p := spawn(&"player", Vector3(x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(x, 0, -dist), Vector3.BACK)
	if p.traversal != null:
		p.traversal.queue_free()
	if p.defence != null:
		p.defence.queue_free()
	var tv: Traversal = TraversalDouble.new()
	tv.name = "TraversalDouble"
	p.add_child(tv)
	tv.setup(p)
	p.traversal = tv
	tv.set(&"cap", cap)
	tv.set(&"speed", speed)
	tv.set(&"sprinting", speed >= Tuning.SPRINT_START_SPEED)
	var dd: Defence = DefenceDouble.new()
	dd.name = "DefenceDouble"
	p.add_child(dd)
	dd.setup(p)
	p.defence = dd
	dd.set(&"bonus", counter)
	await ticks(12)
	return {"p": p, "g": g, "tv": tv, "dd": dd}

func _landed_on(g: Fighter, from: int) -> HitInfo:
	for i in range(from, events.size()):
		var e: Array = events[i]
		if e[0] == &"hit_landed" and (e[1] as HitInfo).victim == g:
			return e[1]
	return null

## One strike. hold > 0: held that many real seconds (a charge level).
func _strike(pr: Dictionary, action: int, hold: float) -> HitInfo:
	var p: Fighter = pr["p"]
	var g: Fighter = pr["g"]
	p.combat.force_hold_charge = hold > 0.0
	var from := events.size()
	if hold > 0.0:
		await hold_press(p, action, hold)
	else:
		tap(p, action)
	await wait_until(func() -> bool: return _landed_on(g, from) != null, 3.0)
	return _landed_on(g, from)

## First physics frame after the contact-frame hold lets the launched body go.
func _launch_velocity(g: Fighter) -> Vector3:
	await wait_until(func() -> bool:
		return g.is_launched() and not (g.ragdoll.has_method(&"is_in_hitstop") and g.ragdoll.call(&"is_in_hitstop")) \
			and not g.is_frozen(), 1.5)
	await get_tree().physics_frame
	return g.get_com_velocity()

func _free_pair(pr: Dictionary) -> void:
	for k: String in ["p", "g"]:
		var f: Fighter = pr[k]
		if is_instance_valid(f):
			f.queue_free()

func run() -> void:
	var cap0 := Tuning.debug_speed_cap
	# [name, action, hold s, speed toward the target, counter bonus, cap, P, tier]
	var table := [
		["Standing jab", A.LIGHT, 0.0, 0.0, 0.0, 8.0, 1.0, T.FLINCH],
		["Standing cross", A.HEAVY, 0.0, 0.0, 0.0, 8.0, 2.0, T.STAGGER],
		["Jab right after a parry", A.LIGHT, 0.0, 0.0, Tuning.COUNTER_BONUS_PARRY, 8.0, 3.5, T.KNOCKDOWN],
		["Jab at full sprint", A.LIGHT, 0.0, 8.0, 0.0, 8.0, 4.0, T.KNOCKDOWN],
		["Cross at full sprint", A.HEAVY, 0.0, 8.0, 0.0, 8.0, 5.0, T.LAUNCH],
		["Tapped kick after a teleport", A.KICK, 0.0, 0.0, Tuning.COUNTER_BONUS_TELEPORT, 8.0, 5.5, T.LAUNCH],
		["Standing cross, charge level 3", A.HEAVY, 1.1, 0.0, 0.0, 8.0, 6.4, T.LAUNCH],
		["Standing kick, charge level 3", A.KICK, 1.1, 0.0, 0.0, 8.0, 8.0, T.HARD_LAUNCH],
		["Kick at charge level 2 while sprinting", A.KICK, 0.75, 8.0, 0.0, 8.0, 8.75, T.HARD_LAUNCH],
		["Kick at charge level 2 after a teleport", A.KICK, 0.75, 0.0, Tuning.COUNTER_BONUS_TELEPORT, 8.0, 8.75, T.HARD_LAUNCH],
		["Kick at charge level 3 while sprinting", A.KICK, 1.1, 8.0, 0.0, 8.0, 11.0, T.SEVER],
		["Tapped kick at an upgraded 12 m/s", A.KICK, 0.0, 12.0, 0.0, 12.0, 11.5, T.SEVER],
	]
	print("worked examples (P = base x charge + speed + counter + finisher):")
	var matched := 0
	for row: Array in table:
		Tuning.debug_speed_cap = row[5]
		var speed: float = row[3]
		var pr: Dictionary = await _pair(speed, row[4], row[5], 2.6 if speed > 0.0 else 1.6)
		var info := await _strike(pr, row[1], row[2])
		if info == null:
			check(false, "%s: the strike landed" % row[0])
			_free_pair(pr)
			continue
		print("  %-42s P %5.2f (base %.1f x %.1f + speed %.2f + counter %.2f + finisher %.2f) tier %-11s want P %.2f %s" % [
			row[0], info.power, info.power_base, Power.charge_mult(info.charge_level), info.speed_bonus,
			info.counter_bonus, info.finisher_bonus, HitInfo.tier_name(info.tier), row[6], HitInfo.tier_name(row[7])])
		check(is_equal_approx(info.power, info.power_base * Power.charge_mult(info.charge_level) + info.speed_bonus \
			+ info.counter_bonus + info.finisher_bonus), "%s: the logged parts add up to P" % row[0])
		var ok: bool = absf(info.power - float(row[6])) < 0.011 and info.tier == int(row[7])
		if ok:
			matched += 1
		check(ok, "%s: P %.2f %s" % [row[0], info.power, HitInfo.tier_name(info.tier)])
		check(info.reaction == HitInfo.reaction_for_tier(info.tier), "%s: legacy reaction in step" % row[0])
		var tv: Traversal = pr["tv"]
		if speed > 0.0:
			# F2: the speed was sampled before the sprint strike dropped the player to walk.
			var strikes: Array[bool] = tv.get(&"strikes")
			check(strikes.size() == 1 and strikes[0], "%s: on_strike_started(sprint) once" % row[0])
			check(absf(tv.get_speed() - Tuning.WALK_SPEED) < 0.01, "%s: dropped to walking speed" % row[0])
			check(info.sprint, "%s: HitInfo.sprint" % row[0])
		if row[4] > 0.0:
			check(int((pr["dd"] as Defence).get(&"consumed")) >= 1, "%s: counter bonus consumed on the hit" % row[0])
		if row[0] == "Standing kick, charge level 3":
			await _check_survives(pr, info)
		_free_pair(pr)
		await ticks(2)
	print("worked examples matched: %d / %d" % [matched, table.size()])
	check(matched == table.size(), "all %d worked examples match the table" % table.size())

	# Launch speed and angle measured from the body (P 5, 7, 9, 11).
	print("launch speed and angle from the victim's body:")
	Tuning.debug_speed_cap = 8.0
	# [P, action, hold, speed]: cross sprint 5; kick L1 + sprint 7; kick L3 + 1.0 speed bonus 9; kick L3 sprint 11
	for row: Array in [[5.0, A.HEAVY, 0.0, 8.0], [7.0, A.KICK, 0.4, 8.0],
			[9.0, A.KICK, 1.1, Tuning.SPEED_BONUS_FROM + 1.0 / Tuning.SPEED_BONUS_K], [11.0, A.KICK, 1.1, 8.0]]:
		var pr: Dictionary = await _pair(row[3], 0.0, 8.0, 2.6)
		var g: Fighter = pr["g"]
		var info := await _strike(pr, row[1], row[2])
		if info == null:
			check(false, "P %.0f: the strike landed" % row[0])
			_free_pair(pr)
			continue
		var v := await _launch_velocity(g)
		var h := Vector2(v.x, v.z).length()
		var angle := rad_to_deg(atan2(v.y, h))
		var want_v := Power.launch_speed(info.power)
		var want_a := Power.launch_angle(info.power)
		print("  P %5.2f: body %5.2f m/s at %4.1f deg (formula %5.2f m/s at %4.1f deg) tier %s" % [
			info.power, v.length(), angle, want_v, want_a, HitInfo.tier_name(info.tier)])
		check(absf(info.power - float(row[0])) < 0.011, "P %.2f is %.0f" % [info.power, row[0]])
		check(absf(v.length() - want_v) <= want_v * 0.06, "P %.0f: body speed %.2f ~ %.2f m/s" % [row[0], v.length(), want_v])
		check(absf(angle - want_a) <= 1.5, "P %.0f: launch angle %.1f ~ %.0f deg" % [row[0], angle, want_a])
		var flat := Vector3(v.x, 0.0, v.z).normalized()
		check(flat.dot(Vector3.FORWARD) > 0.85, "P %.0f: flies along the strike direction" % row[0])
		_free_pair(pr)
		await ticks(2)
	Tuning.debug_speed_cap = cap0
	done()

## A full-health grunt hit by a level-3 kick with no wall: health above 0, gets up.
func _check_survives(pr: Dictionary, info: HitInfo) -> void:
	var g: Fighter = pr["g"]
	print("  level-3 kick on a full grunt: damage %.1f (strike %.1f + launch %.1f), hp %.1f / %.0f" % [
		info.damage, Power.strike_damage(&"kick", 3), Power.launch_damage(info.power, g.max_hp), g.hp, g.max_hp])
	check(absf(info.damage - (Power.strike_damage(&"kick", 3) + Power.launch_damage(info.power, g.max_hp))) < 0.01,
		"level-3 kick damage = strike 32 + launch damage")
	check(g.hp > 0.0 and not g.is_dead(), "the grunt survives the level-3 kick (hp %.1f)" % g.hp)
	var t0 := TimeDirector.now()
	var up := await wait_until(func() -> bool: return g.get_state() == RagdollController.State.ANIMATED \
		and TimeDirector.now() - t0 > 0.3, 8.0)
	print("  level-3 kick: back on its feet after %.2f s, hp %.1f" % [TimeDirector.now() - t0, g.hp])
	check(up and g.hp > 0.0, "the grunt gets up")
