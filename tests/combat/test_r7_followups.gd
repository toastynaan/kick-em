extends "res://tests/combat/combat_test_base.gd"
## Follow-ups pressed on the beat of the hit (Round 7 integration fix: docs/
## Round 7 — Freeflow Combat.md: Chains and the input buffer), through the real
## input path (Input.action_press -> PlayerController -> InputInterpreter):
## - a charged uppercut (E held 0.4 s: Round 8, only a charged uppercut lifts),
##   then the roundhouse key (R) pressed during the uppercut's hitstop: the
##   press is buffered, the roundhouse comes out after the chain cut and
##   launches the lifted grunt at 15 m/s +-1 (the payoff; a level-3 grunt, so
##   the uppercut's pressure does not break it open and add the break bonus);
## - after that launch, a Dash tap 0.2 s later pursues (agent H's Defence), and
##   the next punch relaunches the body (the pursuit hit).

func _init() -> void:
	_timeout = 90.0

func run() -> void:
	var was := Tuning.debug_pursuit_max
	Tuning.debug_pursuit_max = maxi(was, 1)
	var p := spawn_player(Vector3.ZERO)
	p.combat.sever_on_kill_chance = 0.0
	var g := spawn(&"grunt", Vector3(0, 0, -1.0), Vector3.BACK)
	g.max_hp = 1000.0
	g.hp = 1000.0
	g.level = 3
	var moves: Array[StringName] = []
	p.combat.attack_active.connect(func(id: StringName) -> void: moves.append(id))
	await ticks(30)
	clear_events()

	print("a charged uppercut, then the roundhouse pressed during the uppercut's hitstop")
	await tap_input(&"uppercut", 0.4)
	await wait_until(func() -> bool: return not hits_on(g).is_empty(), 1.0)
	var up_t := TimeDirector.now()
	var frozen_at_press := p.is_frozen() and p.combat.is_attack_active()
	var press_dt := TimeDirector.now() - up_t
	await tap_input(&"roundhouse", 0.03)
	var lifted := g.is_lifted()
	await wait_until(func() -> bool: return hits_on(g).size() >= 2, 1.5)
	var rh: HitInfo = hits_on(g)[1] if hits_on(g).size() >= 2 else null
	var rh_t := TimeDirector.now()
	print("  pressed %s (player frozen in the uppercut's active frames: %s); the grunt lifted %s; moves %s" % [
		"on the hitstop", frozen_at_press, lifted, moves])
	check(frozen_at_press, "the roundhouse key went down inside the uppercut's hitstop")
	check(moves.size() >= 2 and moves[1] == &"roundhouse", "the buffered roundhouse came out")
	if rh == null:
		check(false, "the roundhouse landed on the lifted grunt")
		release_inputs()
		Tuning.debug_pursuit_max = was
		done()
		return
	await wait_until(func() -> bool: return g.is_launched() and not g.is_frozen(), 0.5)
	var speed := 0.0
	var vel := Vector3.ZERO
	for i in 4:
		await get_tree().physics_frame
		var v := g.get_com_velocity()
		if v.length() > speed:
			speed = v.length()
			vel = v
	print("DATA uppercut -> buffered roundhouse (pressed %.3f s after the uppercut landed, it landed %.3f s after): %s on %s, the grunt flies at %.2f m/s, %.1f deg up" % [
		press_dt, rh_t - up_t, rh.react, rh.victim_state, speed, rad_to_deg(atan2(vel.y, Vector2(vel.x, vel.z).length()))])
	check(rh.victim_state == &"lift" and rh.react == &"launch" and rh.payoff, "it is the launch payoff on the lifted body")
	check(absf(speed - 15.0) <= 1.0, "the grunt flies at 15 m/s +-1 (%.2f)" % speed)

	print("Dash 0.2 s after the launch pursues; the next punch relaunches")
	while TimeDirector.now() - rh_t < 0.2:
		await get_tree().physics_frame
	await tap_input(&"dash", 0.05)
	var pursued := await wait_until(func() -> bool: return p.defence.get_pursuit_target() == g, 0.6)
	var n := hits_on(g).size()
	await tap_input(&"punch", 0.05)
	await wait_until(func() -> bool: return hits_on(g).size() > n, 1.0)
	var ph: HitInfo = hits_on(g)[n] if hits_on(g).size() > n else null
	release_inputs()
	print("DATA pursuit: pursued %s, the punch %s: pursuit %s, react %s, %.2f m/s" % [pursued,
		ph.move_id if ph else &"-", ph.pursuit if ph else false, ph.react if ph else &"-",
		ph.launch_velocity.length() if ph else 0.0])
	check(pursued, "the Dash tap 0.2 s after the launch pursues (Defence's pursuit target is the grunt)")
	check(ph != null and ph.pursuit and ph.react == &"launch"
		and ph.launch_velocity.length() >= Tuning.R7_PURSUIT_RELAUNCH_SPEED - 0.01, "the next punch relaunches it")
	Tuning.debug_pursuit_max = was
	done()
