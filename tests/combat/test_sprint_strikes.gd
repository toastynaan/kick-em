extends "res://tests/combat/combat_test_base.gd"
## F2 sprint strikes (Feel Reference: Sprint strikes), with a Traversal double:
## - every strike emits GameEvents.strike_started(attacker, target, move,
##   sprint, charge level) once, at its commit (the press for a tap, the
##   release for a charge); enemy attacks too (sprint false);
## - the speed is sampled BEFORE Traversal.on_strike_started(sprint): a sprint
##   strike, hit or miss, drops the player to walking speed;
## - from the press to the end of the active frames the striker's capsule
##   ignores the target (collision exception both ways) and
##   suppresses_ram_with() is true; neither holds in recovery;
## - the sprint lunge carries the run and stops Tuning.SPRINT_LUNGE_STOP short;
## - charging at a sprint keeps the speed (move mult 1), walking halves it.

const TraversalDouble := preload("res://tests/combat/traversal_double.gd")
const A := CombatController.Action
var _x := 0.0
var _started: Array = []

func _init() -> void:
	_timeout = 90.0

func _sprinter(dist: float, enemy := true) -> Array:
	_x += 14.0
	var p := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g: Fighter = spawn(&"grunt", Vector3(_x, 0, -dist), Vector3.BACK) if enemy else null
	var tv: Traversal = TraversalDouble.new()
	p.add_child(tv)
	tv.setup(p)
	p.traversal.queue_free()
	p.traversal = tv
	tv.set(&"speed", 8.0)
	tv.set(&"sprinting", true)
	await ticks(15)
	return [p, g, tv]

func _landed_on(f: Fighter) -> HitInfo:
	for e: Array in events:
		if e[0] == &"hit_landed" and (e[1] as HitInfo).victim == f:
			return e[1]
	return null

func run() -> void:
	GameEvents.strike_started.connect(func(a: Node3D, t: Node3D, m: StringName, s: bool, c: int) -> void:
		_started.append([a, t, m, s, c, TimeDirector.now()]))

	print("a sprint jab from 2.6 m: strike_started, speed sampled before the drop, exceptions, ram suppression")
	var r: Array = await _sprinter(2.6)
	var p: Fighter = r[0]
	var g: Fighter = r[1]
	var tv: Traversal = r[2]
	_started.clear()
	clear_events()
	var min_gap := [INF]
	var exc_during := [true]
	var ram_during := [true]
	var probe := func() -> void:
		if p.combat.is_attacking() and not p.combat.is_in_recovery():
			var to := g.get_ground_position() - p.global_position
			to.y = 0.0
			min_gap[0] = minf(min_gap[0], to.length())
			exc_during[0] = exc_during[0] and p.get_collision_exceptions().has(g) and g.get_collision_exceptions().has(p)
			ram_during[0] = ram_during[0] and p.combat.suppresses_ram_with(g)
	get_tree().physics_frame.connect(probe)
	tap(p, A.LIGHT)
	await wait_until(func() -> bool: return p.combat.is_in_recovery(), 1.5)
	get_tree().physics_frame.disconnect(probe)
	check(_started.size() == 1 and _started[0][0] == p and _started[0][1] == g and _started[0][2] == &"jab1" \
		and _started[0][3] == true and _started[0][4] == 0, "strike_started(p, grunt, jab1, sprint, 0) once (%s)" % [_started])
	var strikes: Array[bool] = tv.get(&"strikes")
	check(strikes == ([true] as Array[bool]), "on_strike_started(true) once")
	var info := _landed_on(g)
	check(info != null and is_equal_approx(info.speed_bonus, 3.0), "the speed bonus came from the pre-drop speed (%.1f)" % (info.speed_bonus if info else -1.0))
	check(absf(tv.get_speed() - Tuning.WALK_SPEED) < 0.01, "dropped to walking speed")
	print("  closest approach during the lunge %.2f m (stop %.1f m short)" % [min_gap[0], Tuning.SPRINT_LUNGE_STOP])
	check(min_gap[0] >= Tuning.SPRINT_LUNGE_STOP - 0.05, "the sprint lunge never comes closer than %.1f m" % Tuning.SPRINT_LUNGE_STOP)
	check(exc_during[0], "capsule exception with the target from the press to the end of the active frames")
	check(ram_during[0], "suppresses_ram_with() through startup and active")
	check(not p.get_collision_exceptions().has(g) and not g.get_collision_exceptions().has(p), "the exception ends with the active frames")
	check(not p.combat.suppresses_ram_with(g), "no ram suppression in recovery")

	print("the sprint lunge runs to its stop point when nothing is hit")
	r = await _sprinter(3.0)
	p = r[0]
	g = r[1]
	for hb in g.hurtboxes:
		hb.set_enabled(false)
	await ticks(2)
	var gap2 := [INF]
	var probe2 := func() -> void:
		var to := g.get_ground_position() - p.global_position
		to.y = 0.0
		gap2[0] = minf(gap2[0], to.length())
		if OS.has_environment("B_DEBUG"):
			print("    gap %.3f phase %s forced %s vel %s" % [to.length(), p.combat.current_move_id(),
				p.combat.get_forced_velocity(), p.velocity])
	get_tree().physics_frame.connect(probe2)
	tap(p, A.KICK)
	await wait_until(func() -> bool: return p.combat.is_in_recovery(), 1.5)
	await ticks(10)
	get_tree().physics_frame.disconnect(probe2)
	print("  kick into a target it cannot hit: stopped %.2f m from it" % gap2[0])
	check(absf(gap2[0] - Tuning.SPRINT_LUNGE_STOP) < 0.1, "the sprint lunge stops %.1f m short (%.2f)" % [Tuning.SPRINT_LUNGE_STOP, gap2[0]])

	print("a missed sprint strike also drops to walk")
	r = await _sprinter(0.0, false)
	p = r[0]
	tv = r[2]
	tap(p, A.KICK)
	await wait_until(func() -> bool: return p.combat.is_in_recovery(), 1.5)
	strikes = tv.get(&"strikes")
	check(strikes == ([true] as Array[bool]) and absf(tv.get_speed() - Tuning.WALK_SPEED) < 0.01, "a whiffed sprint kick: walking speed")

	print("a charged strike commits at the release")
	r = await _sprinter(2.6)
	p = r[0]
	g = r[1]
	tv = r[2]
	tv.set(&"sprinting", false)
	tv.set(&"charge_steering", true)  # charging at a sprint keeps the run
	_started.clear()
	p.combat.force_hold_charge = true
	p.combat.press(A.KICK)
	await wait_real(0.3)
	check(_started.is_empty(), "nothing emitted while charging")
	check(is_equal_approx(p.combat.get_move_speed_mult(), 1.0), "charging at a sprint keeps the speed (x1)")
	await wait_real(0.4)
	var t_rel := TimeDirector.now()
	p.combat.release(A.KICK)
	await ticks(1)
	check(_started.size() == 1 and _started[0][4] == 2 and _started[0][3] == true and _started[0][5] >= t_rel - 0.01,
		"strike_started at the release, charge level 2, sprint (%s)" % [_started])
	strikes = tv.get(&"strikes")
	check(strikes == ([true] as Array[bool]), "on_strike_started(true) at the release")
	await wait_until(func() -> bool: return _landed_on(g) != null, 1.5)
	info = _landed_on(g)
	check(info != null and is_equal_approx(info.power, 2.5 * Tuning.CHARGE_MULT[2] + 3.0), "P %.2f = kick L2 + full speed" % (info.power if info else -1.0))

	print("walking strikes: on_strike_started(false), no exception")
	_x += 14.0
	var pw := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var gw := spawn(&"grunt", Vector3(_x, 0, -1.2), Vector3.BACK)
	var tw: Traversal = TraversalDouble.new()
	pw.add_child(tw)
	tw.setup(pw)
	pw.traversal.queue_free()
	pw.traversal = tw
	await ticks(15)
	_started.clear()
	tap(pw, A.LIGHT)
	await ticks(2)
	check(not pw.get_collision_exceptions().has(gw), "no capsule exception for a walking strike")
	strikes = tw.get(&"strikes")
	check(strikes == ([false] as Array[bool]) and _started.size() == 1 and _started[0][3] == false, "on_strike_started(false); sprint false")
	pw.combat.force_hold_charge = true
	await wait_real(0.6)
	pw.combat.press(A.HEAVY)
	await wait_real(0.35)
	check(pw.combat.is_charging() and is_equal_approx(pw.combat.get_move_speed_mult(), Tuning.CHARGE_WALK_MULT),
		"charging while walking: x%.1f" % Tuning.CHARGE_WALK_MULT)
	pw.combat.release(A.HEAVY)

	print("enemy attacks emit strike_started too")
	_started.clear()
	_x += 14.0
	var pe := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var ee := spawn(&"grunt", Vector3(_x, 0, -1.3), Vector3.BACK)
	await ticks(15)
	ee.combat.start_enemy_attack(&"e_jab", 0.35)
	check(_started.size() == 1 and _started[0][0] == ee and _started[0][1] == pe and _started[0][2] == &"e_jab" \
		and _started[0][3] == false, "strike_started(grunt, player, e_jab, false, 0)")
	done()
