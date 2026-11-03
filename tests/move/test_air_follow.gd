extends "res://tests/move/move_test_base.gd"
## Round 8 launcher jump (docs/Round 8 — Charge and Pressure.md: Air combo).
## Checks, with measured numbers:
## - a body lifted 2.5 m and 1.0 m (Fighter.react(&"lift")) is reached: the
##   player's chest within 0.2 m of the body's chest within 0.3 s, about
##   AIR_FOLLOW_STOP short of it, facing it, still rising at the top; Jump
##   pressed early (body rising), late (near or past its peak) and from a
##   short jump already under way;
## - is_air_following() during the leap only; one air_follow_started event;
## - the landing afterwards uses the landing levels and the player stays up;
## - a hang() begun during an attack (B's air strike) lasts its whole time;
## - refusals: no target, a standing body, out of range, a reacting player, a
##   player holding a body, active frames, a second call mid-leap; a strike's
##   recovery is cancelled instead;
## - the real Jump key path (PlayerController -> start_air_follow) once H's
##   wiring and B's get_air_follow_target() are in.

const TOL := 0.2       ## m chest to chest
const REACH_BY := 0.3  ## s

var _row := 0

func _init() -> void:
	_timeout = 600.0

func run() -> void:
	GameEvents.air_follow_started.connect(func(a: Node3D, b: Node3D) -> void:
		events.append([&"air_follow_started", [a, b], TimeDirector.now()]))
	if GameEvents.has_signal(&"air_hit"):
		GameEvents.air_hit.connect(func(a: Node3D, b: Node3D, n: int) -> void:
			events.append([&"air_hit", [a, b, n], TimeDirector.now()]))
	var p := spawn_player(Vector3.ZERO)
	await ticks(30)
	await _follow(p, 2.5, 0.1, false, "2.5 m lift, Jump at 0.10 s (rising)")
	await _follow(p, 2.5, 0.35, false, "2.5 m lift, Jump at 0.35 s (near the peak)")
	await _follow(p, 2.5, 0.55, false, "2.5 m lift, Jump at 0.55 s (at the peak)")
	await _follow(p, 2.5, Tuning.R8_AIR_FOLLOW_WINDOW, false, "2.5 m lift, Jump at the window's end (falling)")
	await _follow(p, 1.0, 0.05, false, "1.0 m lift, Jump at 0.05 s")
	await _follow(p, 1.0, 0.25, false, "1.0 m lift, Jump at 0.25 s (falling)")
	await _follow(p, 2.5, 0.1, true, "2.5 m lift, from a short jump under way")
	await _follow(p, 2.5, 0.2, false, "2.5 m lift in slow motion (0.3), Jump at 0.20 real s", true)
	await _hang_during_attack(p)
	await _refusals(p)
	await _real_input()
	done()

## A fresh enemy `dist` m in front of the player on a new row, lifted `h` m.
func _lifted_enemy(p: Fighter, h: float, dist := 2.5) -> Fighter:
	_row += 1
	var base := Vector3(_row * 12.0, 0.0, 0.0)
	await settle(p, 10)
	await place(p, base, Vector3.FORWARD)
	var e := spawn_enemy(&"grunt", base + Vector3(0.0, 0.0, -dist), Vector3.BACK)
	await ticks(20)
	var info := HitInfo.new()
	info.attacker = p
	info.lift_height = h
	e.react(&"lift", Vector3.FORWARD, 0.0, 0.0, info)
	return e

func _chest_y(f: Fighter) -> float:
	return f.rig.get_bone_global_position(Bones.CHEST).y

func _follow(p: Fighter, h: float, delay: float, from_jump: bool, label: String, slowmo := false) -> void:
	var scale := 1.0
	if slowmo:
		await settle(p, 10)
		TimeDirector.request_slowmo(0.3, 4.0, TimeDirector.PRIO_DODGE)
		await ticks(40)
		scale = Engine.time_scale
	var e := await _lifted_enemy(p, h)
	var peak := 0.0
	var t_lift := TimeDirector.now()
	if from_jump:
		await ticks(int(round((delay - 0.08) * 120.0)))
		p.traversal.on_jump_pressed()
		await ticks(10)
	else:
		await ticks(int(round(delay * 120.0)))
	var lift_at := e.get_lift_height()
	clear_events()
	var vy0 := p.velocity.y
	var ok := p.traversal.start_air_follow(e)
	var t0 := TimeDirector.now()
	var reached := -1.0
	var following_ticks := 0
	var end_diff := INF
	var end_gap := 0.0
	var end_vy := 0.0
	var end_face := 0.0
	var end_t := -1.0
	var max_v := 0.0
	while TimeDirector.now() - t0 < 0.5:
		await get_tree().physics_frame
		peak = maxf(peak, e.get_lift_height())
		var t := TimeDirector.now() - t0
		var diff := _chest_y(p) - _chest_y(e)
		max_v = maxf(max_v, p.velocity.length())
		# Reached: within TOL from then on through the leap's end.
		if absf(diff) > TOL:
			if end_t < 0.0:
				reached = -1.0
		elif reached < 0.0:
			reached = t
		if p.traversal.is_air_following():
			following_ticks += 1
		elif end_t < 0.0:
			end_t = t
			end_diff = diff
			var to := e.global_position - p.global_position
			end_gap = Vector2(to.x, to.z).length()
			end_vy = p.velocity.y
			var fl := Vector3(to.x, 0.0, to.z).normalized()
			end_face = p.get_forward().dot(fl)
	var ev := events_of(&"air_follow_started")
	if slowmo:
		print("    time scale %.2f (times are real s)" % scale)
		check(scale < 0.5, "%s: slow motion is on (%.2f)" % [label, scale])
	print("  %s: started %s (body %.2f m up, player vy %.2f), chest within %.1f m from %.3f s, leap %.3f s, at its end chest diff %+.3f m, gap %.2f m, vy %.2f m/s, facing %.2f, peak speed %.1f m/s" % [
		label, ok, lift_at, vy0, TOL, reached, end_t, end_diff, end_gap, end_vy, end_face, max_v])
	check(ok, "%s: start_air_follow accepted" % label)
	check(reached >= 0.0 and reached <= REACH_BY + 1e-3, "%s: chest within %.1f m of the body's by %.2f s (%.3f s)" % [label, TOL, REACH_BY, reached])
	check(absf(end_diff) <= TOL, "%s: chest diff at the leap's end %+.3f m" % [label, end_diff])
	check(near(end_t, Tuning.R8_AIR_FOLLOW_TIME, 0.02), "%s: the leap takes %.3f s (%.2f)" % [label, end_t, Tuning.R8_AIR_FOLLOW_TIME])
	check(near(end_gap, 1.0, 0.25), "%s: stops %.2f m short of the body (about 1)" % [label, end_gap])
	check(end_vy > 0.5, "%s: still rising at the top (%.2f m/s)" % [label, end_vy])
	check(end_face > 0.95, "%s: faces the body (%.2f)" % [label, end_face])
	check(ev.size() == 1 and ev[0][0] == p and ev[0][1] == e, "%s: one air_follow_started(player, body)" % label)
	check(following_ticks > 0 and not p.traversal.is_air_following(), "%s: is_air_following() during the leap only (%d ticks)" % [label, following_ticks])
	# The fall and the landing levels (the player never falls over).
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 400)
	var land := last_event(&"landing")
	print("    landed %s at %.2f m/s, player down %s" % [land[1] if not land.is_empty() else &"none",
		float(land[3]) if not land.is_empty() else 0.0, p.is_down()])
	check(not land.is_empty() and not p.is_down(), "%s: lands with a landing level and stays up" % label)
	if slowmo:
		TimeDirector.reset()
		await wait_until(func() -> bool: return not e.is_lifted(), 600)
	e.queue_free()
	await ticks(2)

## B's air strike hangs the player during its attack: the hang lasts its
## whole time (Traversal does not end a hang that began during an attack).
## With B's air strikes in, a LIGHT press after the leap is a real air strike
## whose hit calls hang(); without them the test calls hang() itself.
func _hang_during_attack(p: Fighter) -> void:
	var e := await _lifted_enemy(p, 2.5)
	await ticks(12)
	p.traversal.start_air_follow(e)
	await wait_until(func() -> bool: return not p.traversal.is_air_following(), 60)
	clear_events()
	p.combat.press(CombatController.Action.LIGHT)
	p.combat.release(CombatController.Action.LIGHT)
	var by_b := await wait_until(func() -> bool: return p.traversal.is_hanging(), 30)
	var attacking := p.combat.is_attacking()
	# R8_AIR_HANG runs from the air hit (B's air_hit), hitstop included, to
	# when the player starts falling (B and H measure it so; the body matches).
	var t0 := last_event_time(&"air_hit")
	if not by_b or t0 < 0.0:
		by_b = false
		attacking = p.combat.is_attacking()
		t0 = TimeDirector.now()
		p.hang(Tuning.R8_AIR_HANG)
	var frozen := 0.0
	var y0 := p.global_position.y
	var fall_t := -1.0
	for i in 240:
		await get_tree().physics_frame
		if p.is_frozen():
			frozen += 1.0 / 120.0
		if not p.traversal.is_hanging() and p.velocity.y < 0.0:
			fall_t = TimeDirector.now()
			break
	var held := fall_t - t0 if fall_t >= 0.0 else INF
	var drift := absf(p.global_position.y - y0)
	print("  hang during an attack (%s, attacking %s): from the hit to the fall %.3f s (%.2f, %.3f s of it hitstop), drift %.3f m" % [
		"B's air strike" if by_b else "hang() from the test", attacking, held, Tuning.R8_AIR_HANG, frozen, drift])
	check(attacking, "the strike is running when the hang starts")
	check(near(held, Tuning.R8_AIR_HANG, 0.03), "the hang lasts %.3f s from the air hit, hitstop included (%.2f)" % [held, Tuning.R8_AIR_HANG])
	check(drift < 0.02, "the player holds still in the hang (%.3f m)" % drift)
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 400)
	e.queue_free()
	await ticks(2)

func _refused(p: Fighter, target: Fighter, label: String) -> void:
	clear_events()
	var ok := p.traversal.start_air_follow(target)
	await ticks(2)
	var clean := not ok and not p.traversal.is_air_following() and count_events(&"air_follow_started") == 0
	print("  refusal, %s: %s" % [label, "refused" if clean else "ACCEPTED"])
	check(clean, "refused: %s" % label)

func _refusals(p: Fighter) -> void:
	await settle(p, 10)
	await _refused(p, null, "no target")
	# A standing body.
	_row += 1
	var base := Vector3(_row * 12.0, 0.0, 0.0)
	await place(p, base)
	var st := spawn_enemy(&"grunt", base + Vector3(0.0, 0.0, -2.0))
	await ticks(10)
	await _refused(p, st, "a body that is not lifted")
	st.queue_free()
	# Out of range.
	var far := await _lifted_enemy(p, 2.5, Tuning.R8_AIR_FOLLOW_RANGE + 1.0)
	await ticks(6)
	await _refused(p, far, "a body %.1f m away" % (Tuning.R8_AIR_FOLLOW_RANGE + 1.0))
	await wait_until(func() -> bool: return not far.is_lifted(), 200)
	far.queue_free()
	# The player reacting to a hit.
	var e := await _lifted_enemy(p, 2.5)
	p.react(&"snap", Vector3.BACK, 0.0, 0.3)
	await ticks(1)
	await _refused(p, e, "the player reacting (snap)")
	await wait_until(func() -> bool: return not e.is_lifted(), 200)
	e.queue_free()
	await settle(p, 40)
	# Holding a body.
	e = await _lifted_enemy(p, 2.5)
	var d := install_carry_double(p, 0.7, false)
	await ticks(2)
	await _refused(p, e, "the player holding a body")
	remove_carry_double(p, d)
	await wait_until(func() -> bool: return not e.is_lifted(), 200)
	e.queue_free()
	# Active frames refuse; the recovery is cancelled instead.
	e = await _lifted_enemy(p, 2.5, 3.5)
	p.snap_facing(Vector3.BACK)
	p.combat.press(CombatController.Action.LIGHT)
	p.combat.release(CombatController.Action.LIGHT)
	var active := await wait_until(func() -> bool: return p.combat.is_attack_active(), 60)
	check(active, "the test strike reaches its active frames")
	clear_events()
	var ok_active := p.traversal.start_air_follow(e)
	check(not ok_active and count_events(&"air_follow_started") == 0, "refused: active frames")
	var rec := await wait_until(func() -> bool: return p.combat.is_in_recovery(), 60)
	var ok_rec := rec and p.traversal.start_air_follow(e)
	print("  recovery: in recovery %s, accepted %s, attack cancelled %s" % [rec, ok_rec, not p.combat.is_attacking()])
	check(ok_rec and not p.combat.is_attacking(), "a strike's recovery is cancelled by the launcher jump")
	check(not p.traversal.start_air_follow(e), "refused: a second call mid-leap")
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 400)
	await wait_until(func() -> bool: return not e.is_lifted(), 200)
	e.queue_free()
	await settle(p, 20)

## The real path: hold the uppercut key (E) to a full charge, release on a
## grunt, then the Jump key: PlayerController -> combat.get_air_follow_target()
## -> start_air_follow. The player's chest reaches the body's within 0.3 s.
func _real_input() -> void:
	var base := Vector3(-30.0, 0.0, 0.0)
	var rp := spawn_real_player(base)
	await ticks(20)
	var e := spawn_enemy(&"grunt", base + Vector3(0.0, 0.0, -1.6), Vector3.BACK)
	await ticks(30)
	clear_events()
	hold(&"uppercut")
	await ticks(int(round((Tuning.debug_charge_full + 0.05) * 120.0)))
	let_go(&"uppercut")
	var lifted := await wait_until(func() -> bool: return e.is_lifted(), 120)
	await wait_until(func() -> bool: return rp.combat.get_air_follow_target() != null, 30)
	var target := rp.combat.get_air_follow_target()
	print("  real input: charged uppercut lifted %s (lift height now %.2f m), air follow target %s" % [
		lifted, e.get_lift_height(), target != null])
	check(lifted and target == e, "real input: a full charged uppercut (E held) lifts the grunt and is the air follow target")
	if target == null:
		e.queue_free()
		rp.queue_free()
		return
	# How long the uppercut's active frames (and its hitstop) run past the lift.
	var t_lift := TimeDirector.now()
	await wait_until(func() -> bool: return not rp.combat.is_attack_active() and not rp.is_frozen(), 60)
	var busy := TimeDirector.now() - t_lift
	print("  real input: active frames / hitstop end %.3f s after the lift is seen (frozen %s)" % [busy, rp.is_frozen()])
	await tap(&"jump", 3)
	var t0 := last_event_time(&"air_follow_started")
	var started := count_events(&"air_follow_started")
	var reached := -1.0
	var end_diff := INF
	var peak := 0.0
	while TimeDirector.now() - t0 < 0.4:
		await get_tree().physics_frame
		peak = maxf(peak, e.get_lift_height())
		var diff := _chest_y(rp) - _chest_y(e)
		if absf(diff) > TOL:
			if rp.traversal.is_air_following():
				reached = -1.0
		elif reached < 0.0:
			reached = TimeDirector.now() - t0
		if not rp.traversal.is_air_following() and end_diff == INF:
			end_diff = diff
	print("  real input: air_follow_started %d, chest within %.1f m from %.3f s, diff at the leap's end %+.3f m, body peak %.2f m" % [
		started, TOL, reached, end_diff, peak])
	check(started == 1, "real Jump key: a launcher jump")
	check(reached >= 0.0 and reached <= REACH_BY + 1e-3, "real Jump key: chest within %.1f m of the body's by %.3f s" % [TOL, reached])
	release_all_input()
	await wait_until(func() -> bool: return not rp.traversal.is_airborne(), 400)
	e.queue_free()
	rp.queue_free()
