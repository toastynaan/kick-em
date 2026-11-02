extends "res://tests/defence/defence_test_base.gd"
## F6 teleport and sidestep (Feel Reference: Teleport: Dash in the same window).
## Acceptance (agent H):
## - With 0 Focus, Dash in the window logs a sidestep and no Focus change.
## - With a wall right behind the attacker the teleport uses a side position,
##   or sidesteps and refunds.
## Also: with a full bar the teleport costs 1, lands 1.2 m behind the attacker
## facing its back, the attack misses, counter bonus 3 for 1.5 s; the attacker
## is the one whose hit lands soonest; enemy grabs can be teleported away from;
## Dash outside any window does nothing here (Traversal's dash); boxed in on
## every side: sidestep and refund; a tapped kick out of a teleport is P 5.5
## and launches (B builds P).

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	await ticks(30)
	var e := spawn_attacker(p, &"grunt", Vector3(0, 0, -1.0))
	await ticks(20)

	# --- 0 Focus: a sidestep, Focus unchanged. ------------------------------------
	print("0 Focus: sidestep")
	p.focus = 0.0
	clear_events()
	var start := p.global_position
	e.combat.start_enemy_attack(&"e_jab", Tuning.frames(18))
	await wait_for_lead(e, 6 / 120.0)
	var f0 := p.focus
	press(&"dash")
	await ticks(1)
	release(&"dash")
	await wait_until(func() -> bool: return e.combat.is_in_recovery() or not e.combat.is_attacking(), 120)
	await ticks(20)
	var moved := Vector2(p.global_position.x - start.x, p.global_position.z - start.z)
	check(count_events(&"sidestepped") == 1 and count_events(&"teleported") == 0, "Dash in the window with 0 Focus: sidestep")
	check(is_equal_approx(p.focus, f0), "Focus unchanged (%.2f -> %.2f)" % [f0, p.focus])
	check(absf(moved.length() - Tuning.SIDESTEP_DIST) < 0.3, "sidestepped %.2f m (want %.1f)" % [moved.length(), Tuning.SIDESTEP_DIST])
	check(last_hit_by(e) == null, "the sidestepped jab missed")
	await _reset(p, e)

	# --- Full bar: teleport behind, facing the attacker's back. --------------------
	print("full bar: teleport")
	p.focus = 1.0
	clear_events()
	e.combat.start_enemy_attack(&"e_jab", Tuning.frames(18))
	await wait_for_lead(e, 8 / 120.0)
	press(&"dash")
	await ticks(1)
	release(&"dash")
	var tp := _teleport_event()
	check(not tp.is_empty() and tp[1] == p and tp[5] == &"counter", "teleported (kind counter)")
	check(is_equal_approx(p.focus, 0.0), "the teleport cost 1 bar (Focus %.2f)" % p.focus)
	var behind := e.get_ground_position() - e.get_forward() * 1.2
	var gap := Vector2(p.global_position.x - behind.x, p.global_position.z - behind.z).length()
	check(gap < 0.05, "appeared 1.2 m behind the attacker (off by %.3f m)" % gap)
	var to_e := e.get_ground_position() - p.global_position
	to_e.y = 0.0
	check(p.get_forward().dot(to_e.normalized()) > 0.98, "facing the attacker's back")
	check(p.defence.is_vanished() or p.is_invulnerable(), "vanished at the press")
	check(is_equal_approx(p.defence.counter_bonus(), Tuning.COUNTER_BONUS_TELEPORT), "counter bonus %.1f" % p.defence.counter_bonus())
	await wait_until(func() -> bool: return e.combat.is_in_recovery() or not e.combat.is_attacking(), 120)
	check(last_hit_by(e) == null, "the attack missed")
	# A tapped kick out of the teleport: P = 2.5 + 3 = 5.5, a launch (B).
	await wait_until(func() -> bool: return p.can_act(), 30)
	press(&"kick")
	await ticks(1)
	release(&"kick")
	await wait_until(func() -> bool: return last_hit_by(p) != null, 90)
	var info := last_hit_by(p)
	if info == null:
		check(false, "the kick after the teleport landed")
	else:
		print("  kick after the teleport: ", info)
		check(absf(info.power - 5.5) < 0.01, "tapped kick after a teleport logs P %.2f (want 5.5)" % info.power)
		check(info.tier == HitInfo.Tier.LAUNCH, "tier %s (want launch)" % HitInfo.tier_name(info.tier))
	await _reset(p, e)

	# --- Wall right behind the attacker: a side spot. ------------------------------
	print("wall behind the attacker")
	var wall := _wall(e.get_ground_position() - e.get_forward() * 0.75, e.get_forward(), Vector3(3.0, 2.5, 0.4))
	await ticks(3)
	p.focus = 1.0
	clear_events()
	e.combat.start_enemy_attack(&"e_jab", Tuning.frames(18))
	await wait_for_lead(e, 6 / 120.0)
	press(&"dash")
	await ticks(1)
	release(&"dash")
	var ev := _teleport_event()
	if not ev.is_empty():
		var to: Vector3 = ev[3]
		var rel := to - e.get_ground_position()
		rel.y = 0.0
		var side := absf(rel.dot(e.get_forward().cross(Vector3.UP).normalized()))
		check(absf(side - 1.2) < 0.05, "teleport used a side spot (%.2f m to the side, %.2f m along)" % [side, rel.dot(e.get_forward())])
		check(is_equal_approx(p.focus, 0.0), "and cost the bar")
	else:
		check(count_events(&"sidestepped") == 1 and is_equal_approx(p.focus, 1.0), "or sidestepped and refunded")
	await wait_until(func() -> bool: return e.combat.is_in_recovery() or not e.combat.is_attacking(), 120)
	wall.queue_free()
	await _reset(p, e)

	# --- Boxed in: no spot fits, sidestep and refund. ----------------------------------
	print("no room anywhere")
	var walls: Array[Node3D] = []
	var ep := e.get_ground_position()
	var ef := e.get_forward()
	var er := ef.cross(Vector3.UP).normalized()
	walls.append(_wall(ep - ef * 0.75, ef, Vector3(3.5, 2.5, 0.4)))
	walls.append(_wall(ep + er * 0.8, er, Vector3(0.4, 2.5, 1.6)))
	walls.append(_wall(ep - er * 0.8, er, Vector3(0.4, 2.5, 1.6)))
	await ticks(3)
	p.focus = 1.0
	clear_events()
	e.combat.start_enemy_attack(&"e_jab", Tuning.frames(18))
	await wait_for_lead(e, 6 / 120.0)
	press(&"dash")
	await ticks(1)
	release(&"dash")
	check(count_events(&"teleported") == 0 and count_events(&"sidestepped") == 1, "boxed in: sidestep instead of a teleport")
	check(is_equal_approx(p.focus, 1.0), "Focus refunded (%.2f)" % p.focus)
	await wait_until(func() -> bool: return e.combat.is_in_recovery() or not e.combat.is_attacking(), 120)
	for w in walls:
		w.queue_free()
	await _reset(p, e)

	# --- Two attackers: the one whose hit lands soonest. -------------------------------
	print("soonest attacker")
	var e2 := spawn_attacker(p, &"grunt", Vector3(1.0, 0, 0))
	await ticks(20)
	p.focus = 1.0
	clear_events()
	e.combat.start_enemy_attack(&"e_jab", 0.4)
	e2.combat.start_enemy_attack(&"e_jab", 0.36)  # lands ~5 ticks sooner
	await wait_for_lead(e2, 4 / 120.0)
	press(&"dash")
	await ticks(1)
	release(&"dash")
	ev = _teleport_event()
	if not ev.is_empty():
		var d2 := Vector2(ev[3].x - e2.global_position.x, ev[3].z - e2.global_position.z).length()
		check(d2 < 1.3, "teleported behind the attacker that lands first (%.2f m from it)" % d2)
	else:
		check(false, "teleported")
	await ticks(60)
	e2.queue_free()
	await _reset(p, e)

	# --- An enemy grab can be teleported away from. -------------------------------------
	print("grab")
	p.focus = 1.0
	clear_events()
	e.combat.start_enemy_attack(&"e_grab", Tuning.frames(20))
	await wait_for_lead(e, 6 / 120.0)
	press(&"dash")
	await ticks(1)
	release(&"dash")
	check(count_events(&"teleported") == 1, "Dash in a grab's window teleports")
	await ticks(40)
	check(not e.is_holding() and not p.is_held(), "the grab missed")
	await _reset(p, e)

	# --- In Focus mode (world at 0.3x): the window is still 8 frames of real time. ------------
	print("Focus mode")
	p.focus = 3.0
	press(&"focus")
	await ticks(1)
	release(&"focus")
	await ticks(1)
	check(p.is_focusing() and Engine.time_scale < 0.35, "Focus mode on (world %.2fx)" % Engine.time_scale)
	clear_events()
	e.combat.start_enemy_attack(&"e_jab", Tuning.frames(18))
	await wait_for_lead(e, 6 / 120.0)
	var f_fm := p.focus
	var t_press := TimeDirector.now()
	press(&"dash")
	await ticks(1)
	release(&"dash")
	var t_act := await wait_active(e)
	print("  Dash %.3f real s before the first active frame, world at %.2fx" % [t_act - t_press, Engine.time_scale])
	check(count_events(&"teleported") == 1 and is_equal_approx(p.focus, f_fm - 1.0), "Focus mode: Dash in the window teleports (Focus %.2f -> %.2f)" % [f_fm, p.focus])
	await wait_until(func() -> bool: return e.combat.is_in_recovery() or not e.combat.is_attacking(), 400)
	check(last_hit_by(e) == null, "Focus mode: the attack missed")
	p.end_focus()
	TimeDirector.reset()
	await _reset(p, e)

	# --- The heavy's shoulder charge from range (it lunges about 4 m). --------------------
	await _charge_from_range(p, e)

	# --- Dash with nothing coming: not Defence's. ----------------------------------------
	print("no attack")
	p.focus = 1.0
	clear_events()
	var consumed := p.defence.on_dash_pressed(TimeDirector.now())
	check(not consumed and count_events(&"teleported") == 0 and count_events(&"sidestepped") == 0,
		"Dash with no attack in the window is left to Traversal")
	# An attack further than the window away: no teleport either.
	e.combat.start_enemy_attack(&"e_jab", 0.5)
	await wait_for_lead(e, 30 / 120.0)
	consumed = p.defence.on_dash_pressed(TimeDirector.now())
	check(not consumed and is_equal_approx(p.focus, 1.0), "an attack 30 ticks away is outside the window")
	done()

## A heavy's e_charge started 3, 4.5 and 5.5 m away: Dash in the window
## teleports (a bar) or sidesteps (no bar) and the charge never knocks the
## player down. Control: with no Dash, the charge from 5.5 m does knock him down.
func _charge_from_range(p: Fighter, grunt: Fighter) -> void:
	print("heavy shoulder charge from range")
	grunt.teleport_to(Vector3(30, 0, 30), Vector3.FORWARD)
	var h := spawn_dummy(&"heavy", Vector3(0, 0, -5.5), Vector3.BACK)
	await ticks(30)
	# Control: no Dash.
	var down := await _charge(p, h, 5.5, &"")
	check(down, "control: the charge from 5.5 m knocks the player down when he does nothing")
	for d: float in [3.0, 4.5, 5.5]:
		down = await _charge(p, h, d, &"teleport")
		var ev := _teleport_event()
		check(not ev.is_empty() and ev[5] == &"counter" and not down,
			"charge from %.1f m: Dash teleports and the charge misses (down %s)" % [d, down])
	down = await _charge(p, h, 4.5, &"sidestep")
	check(count_events(&"sidestepped") == 1 and not down, "charge from 4.5 m with 0 Focus: sidestep, not knocked down")
	h.queue_free()
	await ticks(5)
	await _reset(p, grunt)

## One charge from `dist` m. `answer`: &"" (nothing), &"teleport" (a bar) or
## &"sidestep" (0 Focus). Returns true if the player was knocked down.
func _charge(p: Fighter, h: Fighter, dist: float, answer: StringName) -> bool:
	await wait_until(func() -> bool: return p.can_act() and not p.is_down(), 900)
	await reset_fighter(p, Vector3.ZERO, Vector3.FORWARD)
	await reset_fighter(h, Vector3(0, 0, -dist), Vector3.BACK)
	await settle(h)
	await ticks(30)
	p.hp = p.max_hp
	p.focus = 1.0 if answer == &"teleport" else 0.0
	clear_events()
	check(h.combat.start_enemy_attack(&"e_charge", Tuning.frames(28)), "e_charge started from %.1f m" % dist)
	var down := false
	if answer != &"":
		await wait_for_lead(h, 6 / 120.0)
		var gap := Vector2(h.global_position.x - p.global_position.x, h.global_position.z - p.global_position.z).length()
		print("  charge from %.1f m: %.2f m apart at the Dash, target %s" % [dist, gap, h.combat.get_attack_target()])
		# Defence's own backstop (no attack target from B): reach + the lunge still to come.
		var m := MoveLibrary.get_move(&"e_charge")
		var reach := m.reach * h.get_height_scale() + p.defence.AIMED_MARGIN
		var extra: float = p.defence._approach_left(h, m)
		check(gap <= reach + extra, "  without a target the charge still counts as aimed: %.2f m <= reach %.2f + lunge to come %.2f"
			% [gap, reach, extra])
		press(&"dash")
		await ticks(1)
		release(&"dash")
	for i in 240:
		down = down or p.is_down()
		if not h.combat.is_attacking():
			break
		await get_tree().physics_frame
	for i in 30:
		down = down or p.is_down()
		await get_tree().physics_frame
	return down

func _teleport_event() -> Array:
	for i in range(events.size() - 1, -1, -1):
		if events[i][0] == &"teleported":
			return events[i]
	return []

func _reset(p: Fighter, e: Fighter) -> void:
	await settle(e)
	await settle(p)
	await reset_fighter(p, Vector3.ZERO, Vector3.FORWARD)
	await reset_fighter(e, Vector3(0, 0, -1.0), Vector3.BACK)
	await settle(e)
	await ticks(40)
	p.hp = p.max_hp

## A static wall (Layers.WORLD) centred at `center`, `normal` along its local Z.
func _wall(center: Vector3, normal: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	add_child(body)
	var n := Vector3(normal.x, 0.0, normal.z).normalized()
	body.global_transform = Transform3D(Basis.looking_at(n, Vector3.UP), Vector3(center.x, size.y * 0.5, center.z))
	return body
