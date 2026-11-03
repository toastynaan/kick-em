extends "res://tests/combat/combat_test_base.gd"
## Round 7 amendment, B's part (docs/Round 7 — Freeflow Combat.md: God path):
## - sprint strikes: the speed toward the target is sampled at the press, before
##   Traversal.on_strike_started(); at the 8 and 12 m/s caps a front kick
##   launches at R7_SPRINT_LAUNCH_BASE + R7_SPRINT_LAUNCH_PER_MS (v - 6) m/s,
##   R7_SPRINT_LAUNCH_ANGLE up (11 and 17 m/s), and the body flies at it; a jab
##   pushes x (1 + R7_SPRINT_PUSH_PER_MS (v - 6)) as at least a push; the same
##   through the real sprint (Dash held, agent M's Traversal) at the 12 m/s cap;
## - the pursuit hit (Defence's pursuit body, a Defence double): stick neutral
##   relaunches along camera forward at max(its speed, R7_PURSUIT_RELAUNCH_SPEED),
##   R7_PURSUIT_RELAUNCH_ANGLE up, R7_PURSUIT_DAMAGE, Defence.on_pursuit_hit;
##   the stick pulled back spikes it straight down at R7_SPIKE_SPEED,
##   R7_SPIKE_DAMAGE, and its floor impact is a GameEvents.shockwave that
##   staggers an enemy within R7_SPIKE_BLAST_RADIUS (not one outside it);
## - every launch the player causes opens the pursuit window (a launch tier on
##   hit_landed, Defence's hook); a spike does not;
## - the teleport hooks: Dash goes to Defence first; Defence.intercepts() on
##   an enemy attack's first active frame makes it miss; a vanished fighter
##   is not hit; the Duelist's start_counter teleports behind and back-kicks.

const TraversalDouble := preload("res://tests/combat/traversal_double.gd")
const DefenceDouble := preload("res://tests/combat/defence_double.gd")
const AimBrain := preload("res://tests/combat/aim_brain.gd")

var _x := -220.0  ## lanes run along +X over the 500 m test floor

func _init() -> void:
	_timeout = 150.0

func run() -> void:
	print("sprint strikes at the 8 and 12 m/s caps (Traversal double)")
	for cap: float in [8.0, 12.0]:
		var r: Array = await _lane(cap, 1.2)
		var p: Fighter = r[0]
		var g: Fighter = r[1]
		var tv: Traversal = r[2]
		clear_events()
		tap(p, A.FRONT_KICK)
		await wait_until(func() -> bool: return not hits_on(g).is_empty(), 1.0)
		var info: HitInfo = hits_on(g)[0] if not hits_on(g).is_empty() else null
		var want := minf(Tuning.R7_SPRINT_LAUNCH_BASE + Tuning.R7_SPRINT_LAUNCH_PER_MS * (cap - Tuning.SPEED_BONUS_FROM),
			Tuning.LAUNCH_SPEED_MAX)
		var lv := info.launch_velocity if info else Vector3.ZERO
		await wait_until(func() -> bool: return g.is_launched() and not g.is_frozen(), 0.5)
		var fly := 0.0
		for i in 4:
			await get_tree().physics_frame
			fly = maxf(fly, g.get_com_velocity().length())
		var sampled: Array[float] = tv.get(&"sampled")
		print("DATA sprint front kick at the %.0f m/s cap: sampled %.1f m/s, launch %.2f m/s at %.1f deg (want %.2f at %.0f), body flies at %.2f m/s" % [
			cap, sampled[0] if not sampled.is_empty() else -1.0, lv.length(), rad_to_deg(atan2(lv.y, Vector2(lv.x, lv.z).length())),
			want, Tuning.R7_SPRINT_LAUNCH_ANGLE, fly])
		check(info != null and info.sprint and info.react == &"launch" and info.tier == HitInfo.Tier.LAUNCH
			and absf(lv.length() - want) < 0.01, "cap %.0f: the front kick launches at %.0f m/s" % [cap, want])
		check(absf(rad_to_deg(atan2(lv.y, Vector2(lv.x, lv.z).length())) - Tuning.R7_SPRINT_LAUNCH_ANGLE) < 0.1,
			"at R7_SPRINT_LAUNCH_ANGLE up")
		check(absf(fly - want) <= 1.0, "the body flies at %.2f m/s (+-1)" % fly)
		check((tv.get(&"strikes") as Array) == [true] and float(tv.get(&"speed")) == Tuning.WALK_SPEED,
			"sampled before on_strike_started(true), which drops the runner to walk")
		check(_launch_opened_pursuit(info), "the sprint launch is a launch tier on hit_landed (Defence opens its pursuit window)")
	var rj: Array = await _lane(10.0, 1.0)
	clear_events()
	tap(rj[0], A.LIGHT)
	await wait_until(func() -> bool: return not hits_on(rj[1]).is_empty(), 1.0)
	var ji: HitInfo = hits_on(rj[1])[0] if not hits_on(rj[1]).is_empty() else null
	var jwant := float(Tuning.R8_MOVES[&"jab"]["tap"]["push"]) * (1.0 + Tuning.R7_SPRINT_PUSH_PER_MS * (10.0 - Tuning.SPEED_BONUS_FROM))
	print("  a jab at 10 m/s: react %s push %.2f (want push %.2f)" % [ji.react if ji else &"-", ji.push if ji else 0.0, jwant])
	check(ji != null and ji.sprint and ji.react == &"push" and is_equal_approx(ji.push, jwant), "a sprint jab is a longer push")

	print("a real sprint (Dash held, agent M's Traversal) at the 12 m/s cap")
	await _real_sprint(12.0)

	print("the pursuit hit: relaunch (stick neutral) and spike (stick pulled back)")
	var pr: Array = await _pursuit_lane(false)
	var rel: HitInfo = pr[0]
	var dd: Defence = pr[1]
	if rel != null:
		var lv := rel.launch_velocity
		var cam: Vector3 = pr[2]
		print("DATA relaunch: %.2f m/s at %.1f deg, along camera forward %.3f, damage %.1f, body speed before %.2f" % [
			lv.length(), rad_to_deg(atan2(lv.y, Vector2(lv.x, lv.z).length())),
			Vector3(lv.x, 0, lv.z).normalized().dot(cam), rel.damage, float(pr[3])])
		var want := minf(maxf(float(pr[3]), Tuning.R7_PURSUIT_RELAUNCH_SPEED), Tuning.LAUNCH_SPEED_MAX)
		check(rel.pursuit and rel.react == &"launch" and absf(lv.length() - want) < 0.01
			and absf(rad_to_deg(atan2(lv.y, Vector2(lv.x, lv.z).length())) - Tuning.R7_PURSUIT_RELAUNCH_ANGLE) < 0.1
			and Vector3(lv.x, 0, lv.z).normalized().dot(cam) > 0.999, "stick neutral: a relaunch along camera forward")
		check(is_equal_approx(rel.damage, Tuning.R7_PURSUIT_DAMAGE * rel.damage_scale), "R7_PURSUIT_DAMAGE")
		check((dd.get(&"pursuit_hits") as Array).size() == 1, "Defence.on_pursuit_hit")
		check(_launch_opened_pursuit(rel), "the relaunch reopens the pursuit window (a launch tier)")
	else:
		check(false, "the relaunch landed")
	var sp: Array = await _pursuit_lane(true)
	var spike: HitInfo = sp[0]
	if spike != null:
		var lv := spike.launch_velocity
		print("DATA spike: %.2f m/s, %.1f deg from straight down, damage %.1f; shockwave %s; bystander at %.2f m: %s, one at %.2f m: %s" % [
			lv.length(), rad_to_deg(lv.normalized().angle_to(Vector3.DOWN)), spike.damage, sp[4], sp[5], sp[6], sp[7], sp[8]])
		check(spike.pursuit and spike.react == &"spike" and absf(lv.length() - Tuning.R7_SPIKE_SPEED) < 0.01
			and absf(rad_to_deg(lv.normalized().angle_to(Vector3.DOWN)) - CombatController.SPIKE_DRIFT) < 0.1,
			"stick pulled back: a spike straight down at R7_SPIKE_SPEED")
		check(is_equal_approx(spike.damage, Tuning.R7_SPIKE_DAMAGE * spike.damage_scale), "R7_SPIKE_DAMAGE")
		check(spike.react == &"spike", "react &\"spike\": Defence pursues a spiked body no more")
		check(sp[4] == true, "its floor impact emits GameEvents.shockwave(attacker, pos, R7_SPIKE_BLAST_RADIUS)")
		check(sp[6] == true, "an enemy within %.1f m is staggered" % Tuning.R7_SPIKE_BLAST_RADIUS)
		check(sp[8] == false, "an enemy outside it is not")
	else:
		check(false, "the spike landed")

	print("the pursuit through real input (agent H's Defence): relaunch, then spike with move_back held")
	for spike_it: bool in [false, true]:
		await _real_pursuit(spike_it)

	print("teleport hooks")
	var r2: Array = await _lane(0.0, 1.2)
	var p2: Fighter = r2[0]
	var e2: Fighter = r2[1]
	var d2: Defence = DefenceDouble.new()
	p2.add_child(d2)
	d2.setup(p2)
	p2.defence = d2
	p2.combat.press(A.DASH)
	p2.combat.release(A.DASH)
	var tv2: Traversal = r2[2]
	check((d2.get(&"dash_presses") as Array).size() == 1 and int(tv2.get(&"dash_presses")) == 1,
		"Dash asks Defence first (pursuit, teleport), then Traversal")
	d2.set(&"intercept", true)
	clear_events()
	e2.combat.start_enemy_attack(&"e_jab", 0.5)
	await wait_until(func() -> bool: return e2.combat.is_in_recovery(), 1.5)
	check((d2.get(&"intercepted") as Array).size() == 1 and hits_on(p2).is_empty(),
		"intercepts() is asked on the first active frame; an intercepted attack misses")
	d2.set(&"intercept", false)
	d2.set(&"vanished", true)
	await wait_until(func() -> bool: return not e2.combat.is_attacking(), 1.5)
	e2.combat.start_enemy_attack(&"e_jab", 0.5)
	await wait_until(func() -> bool: return e2.combat.is_in_recovery(), 1.5)
	check(hits_on(p2).is_empty() and p2.hp == p2.max_hp, "a vanished fighter is not hit")
	d2.set(&"vanished", false)
	print("the Duelist's teleport counter (start_counter)")
	var dl := spawn(&"duelist", p2.global_position + Vector3(0, 0, -3.0), Vector3.BACK)
	await ticks(15)
	clear_events()
	await wait_until(func() -> bool: return not e2.combat.is_attacking(), 1.5)
	e2.queue_free()
	await ticks(2)
	var ok := dl.combat.start_counter(p2, 0.5)
	if not ok:
		print("  start_counter refused: duelist move %s reacting %s down %s; player down %s reacting %s" % [
			dl.combat.current_move_id(), dl.is_reacting(), dl.is_down(), p2.is_down(), p2.is_reacting()])
	var behind := (dl.get_ground_position() - p2.get_ground_position()).dot(p2.get_forward())
	check(ok and behind < 0.0 and dl.combat.current_move_id() == &"back_kick", "it teleports behind the player into a back kick")
	check(not dl.combat.is_attack_counterable(), "the back kick is uncounterable (a blue tell)")
	await wait_until(func() -> bool: return not hits_on(p2).is_empty(), 1.5)
	var bk: HitInfo = hits_on(p2)[0] if not hits_on(p2).is_empty() else null
	check(bk != null and bk.move_id == &"back_kick" and bk.tier == HitInfo.Tier.KNOCKDOWN, "the back kick knocks the player down")
	done()

## True when hit_landed carried a launch tier (Defence's pursuit hook).
func _launch_opened_pursuit(info: HitInfo) -> bool:
	return info != null and info.result == HitInfo.Result.HIT and HitInfo.is_launch_tier(info.tier)

## A fake player with a Traversal double running at `speed` (cap = speed; 0 =
## standing) and a grunt `dist` m in front.
func _lane(speed: float, dist: float) -> Array:
	_x += 25.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	p.combat.sever_on_kill_chance = 0.0
	var g := spawn(&"grunt", Vector3(_x, 0, -dist), Vector3.BACK)
	var tv: Traversal = TraversalDouble.new()
	p.add_child(tv)
	tv.setup(p)
	if p.traversal != null:
		p.traversal.queue_free()
	p.traversal = tv
	if speed > 0.0:
		tv.set(&"speed", speed)
		tv.set(&"cap", speed)
		tv.set(&"sprinting", true)
	await ticks(15)
	return [p, g, tv]

## The real player sprints (Dash held) at a grunt with the speed cap at `cap`;
## the front kick pressed in reach launches at the sampled speed's sprint launch.
func _real_sprint(cap: float) -> void:
	var was := Tuning.debug_speed_cap
	Tuning.debug_speed_cap = cap
	_x += 40.0
	var p := spawn_player(Vector3(_x, 0, 0))
	var g := spawn(&"grunt", Vector3(_x, 0, -26.0), Vector3.BACK)
	await ticks(30)
	clear_events()
	Input.action_press(&"move_forward")
	Input.action_press(&"dash")
	var pressed := false
	var t0 := TimeDirector.now()
	while TimeDirector.now() - t0 < 6.0 and hits_on(g).is_empty():
		await get_tree().physics_frame
		var d := (g.get_ground_position() - p.global_position) * Vector3(1, 0, 1)
		if not pressed and d.length() < 3.0 and p.traversal.get_speed() >= cap - 0.3:
			print("  pressing at %.2f m/s, %.2f m out" % [p.traversal.get_speed(), d.length()])
			pressed = true
			Input.action_press(&"front_kick")
			await wait_real(0.05)
			Input.action_release(&"front_kick")
		elif not pressed and d.length() < 1.5:
			pressed = true  # never reached the cap: press anyway (reported below)
			Input.action_press(&"front_kick")
			await wait_real(0.05)
			Input.action_release(&"front_kick")
	release_inputs()
	var info: HitInfo = hits_on(g)[0] if not hits_on(g).is_empty() else null
	var v := Tuning.SPEED_BONUS_FROM + (info.speed_bonus / Tuning.SPEED_BONUS_K if info else 0.0)
	var want := minf(Tuning.R7_SPRINT_LAUNCH_BASE + Tuning.R7_SPRINT_LAUNCH_PER_MS * (v - Tuning.SPEED_BONUS_FROM),
		Tuning.LAUNCH_SPEED_MAX)
	print("DATA real sprint at the %.0f m/s cap: sampled %.2f m/s, front kick launch %.2f m/s (want %.2f), after: %.2f m/s" % [
		cap, v, info.launch_velocity.length() if info else 0.0, want, p.traversal.get_speed()])
	check(info != null and info.sprint and info.react == &"launch" and absf(info.launch_velocity.length() - want) < 0.05
		and v >= cap - 0.5, "real sprint at %.0f m/s: the front kick launches at %.1f m/s" % [cap, want])
	check(p.traversal.get_speed() <= Tuning.WALK_SPEED + 0.5, "the runner drops to walk")
	Tuning.debug_speed_cap = was
	await wait_real(0.5)

## The real player launches a grunt (Round 8: a charged roundhouse, R held past R8_TAP_MAX), Dashes inside
## the pursuit window (H's Defence teleports it next to the body and hangs),
## then punches: the stick neutral relaunches, move_back held spikes.
func _real_pursuit(spike: bool) -> void:
	var was := Tuning.debug_pursuit_max
	Tuning.debug_pursuit_max = maxi(was, 1)
	_x += 40.0
	var p := spawn_player(Vector3(_x, 0, 0))
	p.combat.sever_on_kill_chance = 0.0
	var g := spawn(&"grunt", Vector3(_x, 0, -1.2), Vector3.BACK)
	g.max_hp = 1000.0
	g.hp = 1000.0
	await ticks(30)
	clear_events()
	var shock := [false]
	var cb := func(f: Node3D, _pos: Vector3, rad: float, _k: float) -> void:
		if f == p and is_equal_approx(rad, Tuning.R7_SPIKE_BLAST_RADIUS):
			shock[0] = true
	GameEvents.shockwave.connect(cb)
	Input.action_press(&"roundhouse")
	await wait_real(0.3)
	Input.action_release(&"roundhouse")
	var launched := await wait_until(func() -> bool: return g.is_launched(), 1.5)
	await wait_until(func() -> bool: return not g.is_frozen(), 0.5)
	if not launched:
		print("  the charged roundhouse did not launch: hits %s" % [hits_on(g).map(func(h: HitInfo) -> String: return "%s %s" % [h.move_id, h.react])])
	await tap_input(&"dash", 0.05)
	var pursued := await wait_until(func() -> bool: return p.defence.get_pursuit_target() == g, 0.6)
	if not pursued:
		print("  no pursuit: launched %s frozen %s, player body sim %s reacting %s attacking %s, defence: %s, launch_victim %s free_at %.3f now %.3f" % [
			g.is_launched(), g.is_frozen(), p.is_body_simulating(), p.is_reacting(), p.combat.current_move_id(),
			p.defence.get_debug_text(), p.defence.get(&"_launch_victim"), float(p.defence.get(&"_launch_free_at")), TimeDirector.now()])
	if spike:
		Input.action_press(&"move_back")
		await ticks(1)
	var n := hits_on(g).size()
	await tap_input(&"punch", 0.05)
	await wait_until(func() -> bool: return hits_on(g).size() > n, 1.0)
	if spike:
		await wait_until(func() -> bool: return shock[0], 1.5)
	release_inputs()
	GameEvents.shockwave.disconnect(cb)
	var info: HitInfo = hits_on(g)[n] if hits_on(g).size() > n else null
	print("  real input %s: pursued %s, hit %s, react %s, %.2f m/s%s" % ["spike" if spike else "relaunch", pursued,
		info.move_id if info else &"-", info.react if info else &"-", info.launch_velocity.length() if info else 0.0,
		", shockwave %s" % shock[0] if spike else ""])
	if spike:
		check(pursued and info != null and info.pursuit and info.react == &"spike" and shock[0],
			"real input: move_back held at the pursuit hit spikes it, and its floor impact is a shockwave")
	else:
		check(pursued and info != null and info.pursuit and info.react == &"launch",
			"real input: Dash after the launch pursues, the punch relaunches")
	Tuning.debug_pursuit_max = was
	await wait_real(0.5)

## Launch a grunt (a heavy roundhouse's own launch), make it Defence's pursuit
## body, put the player next to it and press the punch: stick neutral or
## pulled back (spike). Returns [the pursuit HitInfo, the Defence double,
## camera forward, the body's speed before, shockwave seen, near distance,
## near staggered, far distance, far staggered].
func _pursuit_lane(spike: bool) -> Array:
	_x += 30.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	p.combat.sever_on_kill_chance = 0.0
	var brain: Node = AimBrain.new()
	p.add_child(brain)
	p.brain = brain
	var cam := Vector3(0.6, 0, -0.8).normalized()
	brain.set(&"camera_forward", cam)
	var dd: Defence = DefenceDouble.new()
	p.add_child(dd)
	dd.setup(p)
	p.defence = dd
	var g := spawn(&"grunt", Vector3(_x, 0, -1.2), Vector3.BACK)
	g.max_hp = 1000.0
	g.hp = 1000.0
	await ticks(15)
	clear_events()
	var shock := [false]
	var cb := func(f: Node3D, _pos: Vector3, rad: float, _k: float) -> void:
		if f == p and is_equal_approx(rad, Tuning.R7_SPIKE_BLAST_RADIUS):
			shock[0] = true
	GameEvents.shockwave.connect(cb)
	p.combat.play_move(&"heavy_roundhouse", g)
	await wait_until(func() -> bool: return g.is_launched() and not g.is_frozen(), 1.5)
	await wait_until(func() -> bool: return not p.combat.is_attacking() and p.can_act(), 1.0)
	# Defence's pursuit: the player appears next to the flying body.
	dd.set(&"pursuit", g)
	var at := g.get_ground_position() - cam * 0.6
	p.teleport_to(Vector3(at.x, 0.0, at.z), g.get_ground_position() - at)
	var speed_before := g.get_com_velocity().length()
	var near: Fighter = null
	var far: Fighter = null
	if spike:
		brain.set(&"stick", -cam)  # pulled back, toward the camera
	var n := hits_on(g).size()
	p.combat.press(A.LIGHT)
	p.combat.release(A.LIGHT)
	await wait_until(func() -> bool: return hits_on(g).size() > n, 1.0)
	var info: HitInfo = hits_on(g)[n] if hits_on(g).size() > n else null
	if info == null:
		print("  no pursuit hit: target %s, move %s, body %.2f m away (%.2f up), pursuit target %s" % [
			p.combat.get_attack_target(), p.combat.current_move_id(),
			((g.get_ground_position() - p.global_position) * Vector3(1, 0, 1)).length(),
			g.get_center_of_mass().y, dd.call(&"get_pursuit_target")])
	var near_d := 1.8
	var far_d := Tuning.R7_SPIKE_BLAST_RADIUS + 1.5
	if spike and info != null:
		var land := g.get_ground_position()
		var side := cam.cross(Vector3.UP).normalized()
		near = spawn(&"grunt", land + side * near_d, -side)
		far = spawn(&"grunt", land - side * far_d, side)
		await wait_until(func() -> bool: return shock[0], 1.5)
		await ticks(3)
	GameEvents.shockwave.disconnect(cb)
	var near_hit := near != null and hits_on(near).any(func(h: HitInfo) -> bool:
		return h.move_id == &"spike_shockwave" and h.tier == HitInfo.Tier.STAGGER)
	var far_hit := far != null and not hits_on(far).is_empty()
	await wait_real(0.3)
	return [info, dd, cam, speed_before, shock[0], near_d, near_hit, far_d, far_hit]
