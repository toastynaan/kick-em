extends "res://tests/combat/combat_test_base.gd"
## Round 5 kick: a standing tapped kick is P 2.5, a stagger (the grunt stays on
## its feet); the same kick at full sprint is P 5.5 (+3.0 speed bonus), a
## launch that flies at v(5.5) and much further. Done twice: with a Traversal
## test double, and through the real sprint (Dash held toward the grunt, agent
## M's Traversal), which must also drop the player to walking speed.

const TraversalDouble := preload("res://tests/combat/traversal_double.gd")
const A := CombatController.Action

func _init() -> void:
	_timeout = 60.0

func _landed_on(g: Fighter) -> HitInfo:
	for e: Array in events:
		if e[0] == &"hit_landed" and (e[1] as HitInfo).victim == g:
			return e[1]
	return null

func _flight(g: Fighter) -> float:
	var start := g.get_ground_position()
	await wait_game(0.8)
	var d := g.get_ground_position() - start
	d.y = 0.0
	return d.length()

func run() -> void:
	print("standing kick")
	var p1 := spawn(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g1 := spawn(&"grunt", Vector3(0, 0, -1.3), Vector3.BACK)
	await ticks(20)
	clear_events()
	tap(p1, A.KICK)
	await wait_until(func() -> bool: return _landed_on(g1) != null, 1.5)
	var a := _landed_on(g1)
	check(a != null, "standing kick connected")
	if a != null:
		print("  standing: P %.2f tier %s damage %.1f" % [a.power, HitInfo.tier_name(a.tier), a.damage])
		check(is_equal_approx(a.power, 2.5) and a.tier == HitInfo.Tier.STAGGER, "standing tapped kick: P 2.5, stagger")
		check(is_equal_approx(a.damage, Power.strike_damage(&"kick", 0)), "kick damage %.0f" % Power.strike_damage(&"kick", 0))
	var dist_a := await _flight(g1)
	check(not g1.is_down(), "the staggered grunt stays on its feet")
	print("  standing kick moved the grunt %.2f m" % dist_a)

	print("sprint kick (Traversal double at 8 m/s)")
	var p2 := spawn(&"player", Vector3(30, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g2 := spawn(&"grunt", Vector3(30, 0, -2.6), Vector3.BACK)
	var tv: Traversal = TraversalDouble.new()
	p2.add_child(tv)
	tv.setup(p2)
	p2.traversal = tv
	tv.set(&"speed", 8.0)
	tv.set(&"sprinting", true)
	await ticks(20)
	clear_events()
	tap(p2, A.KICK)
	await wait_until(func() -> bool: return _landed_on(g2) != null, 1.5)
	var b := _landed_on(g2)
	check(b != null, "sprint kick connected")
	if b != null:
		print("  sprint: P %.2f (speed bonus %.1f) tier %s launch %.2f m/s" % [b.power, b.speed_bonus,
			HitInfo.tier_name(b.tier), b.launch_velocity.length()])
		check(is_equal_approx(b.power, 5.5) and b.tier == HitInfo.Tier.LAUNCH, "sprint kick: P 5.5, launch")
		check(absf(b.launch_velocity.length() - Power.launch_speed(5.5)) < 0.01, "launch speed v(5.5) = %.1f" % Power.launch_speed(5.5))
	await ticks(3)
	check(g2.is_launched(), "the grunt is launched")
	var dist_b := await _flight(g2)
	print("  distance after 0.8 s game time: standing %.2f m, sprint %.2f m" % [dist_a, dist_b])
	check(dist_b >= dist_a + 2.0, "the sprint kick sends it much further")

	print("sprint kick through the real sprint (Dash held)")
	var p3 := spawn(&"player", Vector3(60, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g3 := spawn(&"grunt", Vector3(60, 0, -16.0), Vector3.BACK)
	await ticks(20)
	if p3.traversal == null or not p3.traversal.has_method(&"physics_move"):
		print("  SKIP no Traversal")
		done()
		return
	clear_events()
	p3.move_input = Vector3.FORWARD
	p3.combat.press(A.DASH)
	var pressed := false
	var speed_at := 0.0
	var t0 := TimeDirector.now()
	while TimeDirector.now() - t0 < 4.0:
		await get_tree().physics_frame
		var to := g3.get_ground_position() - p3.global_position
		to.y = 0.0
		if not pressed and to.length() < 2.8:
			speed_at = p3.traversal.get_speed()
			print("  sprint_charge at the press %.2f" % p3.traversal.sprint_charge)
			tap(p3, A.KICK)
			pressed = true
		if pressed and _landed_on(g3) != null:
			break
	p3.combat.release(A.DASH)
	p3.move_input = Vector3.ZERO
	var c := _landed_on(g3)
	print("  real sprint: %.2f m/s at the press" % speed_at)
	check(c != null, "the real sprint kick connected")
	if c != null:
		print("  real sprint kick: P %.2f (speed bonus %.2f) tier %s, sprint=%s" % [c.power, c.speed_bonus,
			HitInfo.tier_name(c.tier), c.sprint])
		check(c.speed_bonus > 2.9 and HitInfo.is_launch_tier(c.tier), "full-sprint kick: +3 speed bonus, launches")
	# Out of the hitstop and the active frames (where the lunge, then planted
	# feet, own the capsule): back at walking speed.
	await wait_until(func() -> bool: return p3.combat.is_in_recovery() and not p3.is_frozen(), 1.0)
	await ticks(3)
	check(p3.traversal.get_speed() <= Tuning.WALK_SPEED + 0.3, "the sprint strike dropped the player to walk (%.2f m/s)" % p3.traversal.get_speed())
	done()
