extends "res://tests/combat/combat_test_base.gd"
## Round 5 teleport and pursuit through combat (replaces the Upgrade 2
## teleport counter; Defence is agent H's):
## - a fresh Dash in the window with a full Focus bar teleports behind the
##   attacker (the attack misses); a tapped kick then is P 5.5 (+3 counter
##   bonus), a launch;
## - pursuit: a hit on Defence's pursuit target relaunches it at
##   Power.pursuit_speed(P, its speed), along the stick (the stick decides where
##   it flies next), never as a dropping strike, and Defence is told
##   (on_pursuit_hit).

const DefenceDouble := preload("res://tests/combat/defence_double.gd")
const AimBrain := preload("res://tests/combat/aim_brain.gd")
const A := CombatController.Action

func _init() -> void:
	_timeout = 60.0

func _landed_on(f: Fighter) -> HitInfo:
	for e: Array in events:
		if e[0] == &"hit_landed" and (e[1] as HitInfo).victim == f:
			return e[1]
	return null

func run() -> void:
	print("teleport in the window, then a tapped kick")
	var p := spawn(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := spawn(&"grunt", Vector3(0, 0, -1.3), Vector3.BACK)
	await ticks(20)
	p.focus = Tuning.TELEPORT_COST
	var tele := [false]
	GameEvents.teleported.connect(func(f: Node3D, _a: Vector3, _b: Vector3, k: StringName) -> void:
		if f == p and k == &"counter":
			tele[0] = true)
	clear_events()
	var hp0 := p.hp
	e.combat.start_enemy_attack(&"e_hook", 0.5)
	await wait_until(func() -> bool: return e.combat.time_to_active() <= 0.08, 2.0)
	p.combat.press(A.DASH)
	p.combat.release(A.DASH)
	await wait_real(0.3)
	check(tele[0], "teleported behind the attacker")
	check(is_equal_approx(p.hp, hp0), "the hook missed")
	await wait_until(func() -> bool: return not p.defence.is_vanished(), 0.5)
	clear_events()
	tap(p, A.KICK)
	await wait_until(func() -> bool: return _landed_on(e) != null, 1.0)
	var info := _landed_on(e)
	if info != null:
		print("  kick after a teleport: P %.2f (counter %.2f) tier %s" % [info.power, info.counter_bonus, HitInfo.tier_name(info.tier)])
	check(info != null and is_equal_approx(info.power, 5.5) and info.tier == HitInfo.Tier.LAUNCH, "P 5.5, a launch")

	print("pursuit: the relaunch rule, along the stick")
	var p2 := spawn(&"player", Vector3(20, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g2 := spawn(&"grunt", Vector3(20, 0, -1.2), Vector3.BACK)
	var br: Node = AimBrain.new()
	p2.add_child(br)
	p2.brain = br
	await ticks(20)
	p2.defence.queue_free()
	var dd: Defence = DefenceDouble.new()
	p2.add_child(dd)
	dd.setup(p2)
	p2.defence = dd
	g2.launch(Vector3(0, 4.0, -5.0), g2.get_center_of_mass(), &"Chest")
	await wait_real(0.2)
	dd.set(&"pursuit", g2)
	var stick := Vector3(1, 0, 0)  # the stick sends the body to the right
	br.set(&"stick", stick)
	# The player appears next to the body (Defence's job), facing it.
	var gp := g2.get_center_of_mass()
	p2.teleport_to(Vector3(gp.x - 0.9, 0.0, gp.z), Vector3.RIGHT)
	await ticks(1)
	var v_before := g2.get_com_velocity().length()
	clear_events()
	var started: Array = []
	p2.combat.attack_started.connect(func(id: StringName) -> void: started.append(id))
	tap(p2, A.LIGHT)
	await wait_until(func() -> bool: return _landed_on(g2) != null, 1.0)
	info = _landed_on(g2)
	check(not started.is_empty() and started[0] != &"drop_strike", "a pursuit hit is not a dropping strike (%s)" % [started])
	check(info != null and info.pursuit and HitInfo.is_launch_tier(info.tier), "the hit relaunches the pursued body")
	if info != null:
		var want := Power.pursuit_speed(info.power, v_before, g2.get_total_mass(), g2.is_heavy())
		print("  pursuit hit: P %.2f, body %.2f m/s before, relaunch %.2f m/s (want >= max(%.2f, v(P+3) %.2f))" % [
			info.power, v_before, info.launch_velocity.length(), v_before, Power.launch_speed(info.power + 3.0)])
		check(info.launch_velocity.length() >= minf(want, Tuning.LAUNCH_SPEED_MAX) - 0.01, "at max(current speed, v(P + 3))")
		var flat := Vector3(info.launch_velocity.x, 0.0, info.launch_velocity.z).normalized()
		check(flat.dot(stick) > 0.95, "along the stick (dot %.2f)" % flat.dot(stick))
	check((dd.get(&"pursuit_hits") as Array).size() == 1, "Defence.on_pursuit_hit(victim) once")
	check(int(dd.get(&"consumed")) >= 1, "consume_counter_bonus() on the hit")
	done()
