extends Node
## Round 5 power score (Feel Reference: Worked examples, Launch speed and walls,
## Not a one-launch kill, Thrown bodies). Pure math: Power + Tuning.
## F3 check: "A scripted test runs every worked example and logs P and tier. All 12 match the table."

const T := HitInfo.Tier

var _fails := 0

func _ready() -> void:
	_run()
	print("TEST test_power: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)

func _near(a: float, b: float, eps := 0.01) -> bool:
	return absf(a - b) <= eps

func _run() -> void:
	var cap := 8.0
	# [name, class, charge level, speed toward target, cap, counter bonus, finisher, expected P, expected tier]
	var rows := [
		["Standing jab", &"jab", 0, 0.0, cap, 0.0, false, 1.0, T.FLINCH],
		["Standing cross", &"cross", 0, 0.0, cap, 0.0, false, 2.0, T.STAGGER],
		["Jab right after a parry", &"jab", 0, 0.0, cap, Tuning.COUNTER_BONUS_PARRY, false, 3.5, T.KNOCKDOWN],
		["Jab at full sprint", &"jab", 0, 8.0, cap, 0.0, false, 4.0, T.KNOCKDOWN],
		["Cross at full sprint", &"cross", 0, 8.0, cap, 0.0, false, 5.0, T.LAUNCH],
		["Tapped kick after a teleport", &"kick", 0, 0.0, cap, Tuning.COUNTER_BONUS_TELEPORT, false, 5.5, T.LAUNCH],
		["Standing cross, charge level 3", &"cross", 3, 0.0, cap, 0.0, false, 6.4, T.LAUNCH],
		["Standing kick, charge level 3", &"kick", 3, 0.0, cap, 0.0, false, 8.0, T.HARD_LAUNCH],
		["Kick at charge level 2 while sprinting", &"kick", 2, 8.0, cap, 0.0, false, 8.75, T.HARD_LAUNCH],
		["Kick at charge level 2 after a teleport", &"kick", 2, 0.0, cap, Tuning.COUNTER_BONUS_TELEPORT, false, 8.75, T.HARD_LAUNCH],
		["Kick at charge level 3 while sprinting", &"kick", 3, 8.0, cap, 0.0, false, 11.0, T.SEVER],
		["Tapped kick at an upgraded 12 m/s", &"kick", 0, 12.0, 12.0, 0.0, false, 11.5, T.SEVER],
	]
	for r: Array in rows:
		var p := Power.score(Power.base_of(r[1]), r[2], r[3], r[4], r[5], r[6])
		var tier := Power.tier_of(p)
		print("  %-42s P=%.2f tier=%s" % [r[0], p, HitInfo.tier_name(tier)])
		_check(_near(p, r[7]) and tier == r[8], "%s: P %.2f (want %.2f), %s (want %s)" % [
			r[0], p, r[7], HitInfo.tier_name(tier), HitInfo.tier_name(r[8])])

	# Speed bonus: 98% of the cap counts as the cap; a third tier of the ladder.
	_check(_near(Power.speed_bonus(7.84, 8.0), 3.0), "98% of the cap counts as the cap")
	_check(_near(Power.speed_bonus(7.0, 8.0), 1.5), "7 m/s gives 1.5")
	_check(_near(Power.speed_bonus(10.0, 10.0), 6.0) and _near(Power.speed_bonus(12.0, 12.0), 9.0), "upgraded caps give 6 and 9")
	_check(_near(Power.speed_bonus(4.5, 8.0), 0.0), "walking gives nothing")
	# Finisher.
	_check(_near(Power.score(1.0, 0, 0.0, cap, 0.0, true), 2.0), "third tap of a string gets +1")
	# Boundaries go to the higher tier.
	_check(Power.tier_of(1.999) == T.FLINCH and Power.tier_of(2.0) == T.STAGGER, "2.0 is a stagger")
	_check(Power.tier_of(7.0) == T.HARD_LAUNCH and Power.tier_of(9.0) == T.SEVER, "7 hard launch, 9 sever")
	# Sweep reads the leg.
	_check(Power.sweep_tier_of(Power.score(1.5, 0)) == T.STUMBLE, "tapped sweep stumbles")
	_check(Power.sweep_tier_of(3.5) == T.KNOCKDOWN and Power.sweep_tier_of(5.0) == T.LAUNCH, "sweep 3.5 trips, 5 upends")
	_check(Power.sweep_tier_of(12.0) == T.LAUNCH, "a sweep never severs")

	# Launch speed and angle (F3: P 5, 7, 9, 11).
	for row: Array in [[5.0, 6.0, 30.0], [7.0, 10.0, 18.0], [9.0, 14.0, 18.0], [11.0, 18.0, 18.0], [6.4, 8.8, 30.0]]:
		var p: float = row[0]
		_check(_near(Power.launch_speed(p), row[1]) and _near(Power.launch_angle(p), row[2]),
			"P %.1f launches at %.1f m/s, %.0f deg" % [p, Power.launch_speed(p), Power.launch_angle(p)])
	_check(_near(Power.launch_speed(20.0), 18.0), "launch speed caps at 18")
	var vel := Power.launch_velocity(7.0, Vector3(0, 0, -1))
	_check(_near(vel.length(), 10.0) and _near(rad_to_deg(asin(vel.y / vel.length())), 18.0), "launch velocity: 10 m/s at 18 deg")
	_check(_near(Power.launch_speed_for(7.0, 110.0), 8.0), "a 110 kg heavy launches at 80%")

	# Wall table: energy into the wall for a 70 kg body hitting straight on (horizontal part).
	for row: Array in [[5.0, 945.0], [6.4, 2033.0], [7.0, 3166.0], [8.0, 4559.0], [9.0, 6205.0], [11.0, 10257.0]]:
		var v := Power.launch_velocity(row[0], Vector3(0, 0, -1))
		var e := Power.wall_energy(70.0, v, Vector3(0, 0, 1))
		_check(absf(e - row[1]) < 15.0, "P %.1f into a wall: %.0f J (table %.0f J)" % [row[0], e, row[1]])

	# Not a one-launch kill.
	_check(_near(Power.launch_damage(5.0, 100.0), 10.0) and _near(Power.launch_damage(11.0, 100.0), 28.0), "launch damage 10 + 3 (P - 5)")
	_check(_near(Power.launch_damage(17.0, 100.0), 35.0), "launch damage capped at 35% of max health")
	_check(_near(Power.launch_damage(4.9, 100.0), 0.0), "no launch damage under launch tier")
	var worst := Power.strike_damage(&"kick", 3) + Power.launch_damage(20.0, 100.0) + Tuning.LIMB_LOST_DAMAGE
	_check(_near(worst, 92.0) and worst < 100.0, "worst single hit with no wall is 92 (grunt survives)")

	# Throws and thrown bodies.
	_check(_near(Power.throw_speed(0, 0.0), 6.0) and _near(Power.throw_speed(3, 0.0), 12.0), "throws 6 tapped, 12 at level 3")
	_check(_near(Power.throw_speed(3, 8.0), 16.0) and _near(Power.throw_speed(3, 12.0), 16.0), "throw capped at 16")
	var s := 16.0
	var tiers: Array[int] = []
	for i in 3:
		tiers.append(Power.bowl_tier(s))
		s *= 1.0 - Tuning.BOWL_SPEED_LOSS
	_check(tiers == [T.LAUNCH, T.KNOCKDOWN, T.STAGGER], "16 m/s bowls launch -> knockdown -> stagger")
	_check(absf(0.5 * 70.0 * 6.0 * 6.0 - 1260.0) < 1.0 and absf(0.5 * 70.0 * 16.0 * 16.0 - 8960.0) < 1.0, "throw energies 1,260 J and 8,960 J")
	# Pursuit.
	_check(_near(Power.pursuit_speed(5.0, 4.0), 12.0) and _near(Power.pursuit_speed(5.0, 15.0), 15.0), "pursuit relaunch max(current, v(P + 3))")
	# Hitstop by tier.
	_check(_near(Power.hitstop_for(T.FLINCH), 0.04) and _near(Power.hitstop_for(T.SEVER), 0.18), "hitstop 40..180 ms by tier")
