extends "res://tests/defence/defence_test_base.gd"
## Teleport (Feel Reference: Teleport; Round 7 God path amendment: free, with
## Tuning.R7_TELEPORT_WINDOW, Tuning.R7_TELEPORT_COOLDOWN and the
## Tuning.debug_teleport switch). Every press is real input: Shift (dash) ->
## PlayerController -> CombatController.press(DASH) -> Defence.on_dash_pressed,
## else Traversal's dodge. Agent H:
## - Inside the window the press teleports 1.2 m behind the attacker, facing its
##   back, free; the attack misses.
## - Outside the window, during the cooldown, or with debug_teleport off, the
##   same press is a dodge (GameEvents.dodged), not a teleport.
## - A wall right behind the attacker: a side spot; boxed in on every side: the
##   sidestep fallback, and the attack still misses.
## - The attacker is the one whose hit lands soonest; enemy grabs and the
##   heavy's shoulder charge from range can be teleported away from.

const LEAD := 6.0 / 120.0  ## real s before the first active frame: well inside the window

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	await ticks(30)
	var e := spawn_attacker(p, &"grunt", Vector3(0, 0, -1.0))
	await ticks(20)
	var teleport_was := Tuning.debug_teleport
	Tuning.debug_teleport = true

	# --- Inside the window: teleport behind, free. --------------------------------------------
	print("inside the window: teleport")
	clear_events()
	e.combat.start_enemy_attack(&"e_jab", 0.6)
	await wait_for_lead(e, LEAD)
	await _dash()
	var tp := _teleport_event()
	check(not tp.is_empty() and tp[1] == p and tp[5] == &"counter", "teleported (kind counter)")
	var behind := e.get_ground_position() - e.get_forward() * 1.2
	var gap := Vector2(p.global_position.x - behind.x, p.global_position.z - behind.z).length()
	check(gap < 0.05, "appeared 1.2 m behind the attacker (off by %.3f m)" % gap)
	var to_e := e.get_ground_position() - p.global_position
	to_e.y = 0.0
	check(p.get_forward().dot(to_e.normalized()) > 0.98, "facing the attacker's back")
	check(p.defence.is_vanished() and p.is_invulnerable(), "vanished and untouchable at the press")
	check(count_events(&"dodged") == 0, "no dodge on top of the teleport")
	await wait_until(func() -> bool: return e.combat.is_in_recovery() or not e.combat.is_attacking(), 120)
	check(last_hit_by(e) == null, "the attack missed")
	await _reset(p, e)

	# --- Outside the window: a dodge. ---------------------------------------------------------
	print("outside the window: dodge")
	clear_events()
	e.combat.start_enemy_attack(&"e_jab", 0.6)
	var lead_out := Tuning.R7_TELEPORT_WINDOW + 0.1
	await wait_for_lead(e, lead_out)
	await _dash()
	check(count_events(&"teleported") == 0 and count_events(&"dodged") == 1,
		"a press %.2f s before the hit (window %.2f s) dodges instead" % [lead_out, Tuning.R7_TELEPORT_WINDOW])
	await wait_until(func() -> bool: return e.combat.is_in_recovery() or not e.combat.is_attacking(), 120)
	await _reset(p, e)

	# --- Cooldown: a second teleport waits R7_TELEPORT_COOLDOWN. -----------------------------------
	# Two attackers at once: the second lands 0.3 s after the first, so its
	# window comes inside the cooldown the first teleport started.
	print("cooldown")
	var e3 := spawn_attacker(p, &"stick", Vector3(-1.1, 0, -0.4))
	await ticks(20)
	clear_events()
	e.combat.start_enemy_attack(&"e_jab", 0.6)
	e3.combat.start_enemy_attack(&"e_stick_thrust", 0.9)
	await wait_for_lead(e, LEAD)
	var t_first := TimeDirector.now()
	await _dash()
	var first_ok := count_events(&"teleported") == 1
	var cd0 := p.defence.get_teleport_cooldown()
	await wait_for_lead(e3, LEAD)
	var t_second := TimeDirector.now()
	var aimed := e3.combat.get_attack_target() == p
	clear_events()
	await _dash()
	var second_blocked := count_events(&"teleported") == 0 and count_events(&"dodged") == 1
	print("  first teleport, cooldown %.2f s; a press %.2f s later inside the second window (aimed at the player %s): teleport %d, dodge %d"
		% [cd0, t_second - t_first, aimed, count_events(&"teleported"), count_events(&"dodged")])
	check(first_ok and absf(cd0 - (Tuning.R7_TELEPORT_COOLDOWN - 1.0 / 120.0)) <= 1.5 / 120.0,
		"the teleport starts a %.2f s cooldown (%.3f left a tick later)" % [Tuning.R7_TELEPORT_COOLDOWN, cd0])
	check(aimed and t_second - t_first < Tuning.R7_TELEPORT_COOLDOWN and second_blocked, "inside the cooldown the press dodges, no teleport")
	await wait_until(func() -> bool: return not e3.combat.is_attacking() and not e.combat.is_attacking(), 240)
	e3.queue_free()
	await _reset(p, e)
	check(p.defence.get_teleport_cooldown() == 0.0, "the cooldown ran out")
	clear_events()
	e.combat.start_enemy_attack(&"e_jab", 0.6)
	await wait_for_lead(e, LEAD)
	await _dash()
	check(count_events(&"teleported") == 1, "after the cooldown the press teleports again")
	await _reset(p, e)

	# --- debug_teleport off: a dodge. -------------------------------------------------------------
	print("debug_teleport off")
	Tuning.debug_teleport = false
	clear_events()
	e.combat.start_enemy_attack(&"e_jab", 0.6)
	await wait_for_lead(e, LEAD)
	await _dash()
	check(count_events(&"teleported") == 0 and count_events(&"dodged") == 1, "with debug_teleport off the press is a dodge")
	Tuning.debug_teleport = true
	await wait_until(func() -> bool: return e.combat.is_in_recovery() or not e.combat.is_attacking(), 120)
	await _reset(p, e)

	# --- Wall right behind the attacker: a side spot. ------------------------------
	print("wall behind the attacker")
	var wall := _wall(e.get_ground_position() - e.get_forward() * 0.75, e.get_forward(), Vector3(3.0, 2.5, 0.4))
	await ticks(3)
	clear_events()
	e.combat.start_enemy_attack(&"e_jab", 0.6)
	await wait_for_lead(e, LEAD)
	await _dash()
	var ev := _teleport_event()
	if not ev.is_empty():
		var to: Vector3 = ev[3]
		var rel := to - e.get_ground_position()
		rel.y = 0.0
		var side := absf(rel.dot(e.get_forward().cross(Vector3.UP).normalized()))
		check(absf(side - 1.2) < 0.05, "teleport used a side spot (%.2f m to the side, %.2f m along)" % [side, rel.dot(e.get_forward())])
	else:
		check(count_events(&"sidestepped") == 1, "or sidestepped")
	await wait_until(func() -> bool: return e.combat.is_in_recovery() or not e.combat.is_attacking(), 120)
	check(last_hit_by(e) == null, "the attack missed")
	wall.queue_free()
	await _reset(p, e)

	# --- Boxed in: no spot fits, the sidestep fallback. ----------------------------------
	print("no room anywhere")
	var walls: Array[Node3D] = []
	var ep := e.get_ground_position()
	var ef := e.get_forward()
	var er := ef.cross(Vector3.UP).normalized()
	# Every TELEPORT_SPOTS spot (behind, and 1.2 m to either side) is walled
	# off; the side walls stop short of the player so the sidestep runs free.
	walls.append(_wall(ep - ef * 0.75, ef, Vector3(3.5, 2.5, 0.4)))
	walls.append(_wall(ep + er * 0.8 - ef * 0.2, er, Vector3(0.4, 2.5, 1.0)))
	walls.append(_wall(ep - er * 0.8 - ef * 0.2, er, Vector3(0.4, 2.5, 1.0)))
	await ticks(3)
	clear_events()
	var start := p.global_position
	e.combat.start_enemy_attack(&"e_jab", 0.6)
	await wait_for_lead(e, LEAD)
	await _dash()
	check(count_events(&"teleported") == 0 and count_events(&"sidestepped") == 1, "boxed in: the sidestep fallback")
	await wait_until(func() -> bool: return e.combat.is_in_recovery() or not e.combat.is_attacking(), 120)
	await ticks(20)  # the slide outlasts the jab's active frames
	var moved := Vector2(p.global_position.x - start.x, p.global_position.z - start.z).length()
	check(absf(moved - Tuning.SIDESTEP_DIST) < 0.3, "sidestepped %.2f m (want %.1f)" % [moved, Tuning.SIDESTEP_DIST])
	check(last_hit_by(e) == null, "the sidestepped jab missed")
	for w in walls:
		w.queue_free()
	await _reset(p, e)

	# --- Two attackers: the one whose hit lands soonest. -------------------------------
	print("soonest attacker")
	var e2 := spawn_attacker(p, &"grunt", Vector3(1.0, 0, 0))
	await ticks(20)
	clear_events()
	# Round 7 tells last at least R7_COUNTER_WINDOW + R7_TELL_MARGIN (0.5 s): both above it.
	e.combat.start_enemy_attack(&"e_jab", 0.64)
	e2.combat.start_enemy_attack(&"e_jab", 0.6)  # lands ~5 ticks sooner
	await wait_for_lead(e2, 4 / 120.0)
	await _dash()
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
	clear_events()
	e.combat.start_enemy_attack(&"e_grab", 0.6)
	await wait_for_lead(e, LEAD)
	await _dash()
	check(count_events(&"teleported") == 1, "a press in a grab's window teleports")
	await ticks(40)
	check(not e.is_holding() and not p.is_held(), "the grab missed")
	await _reset(p, e)

	# --- The heavy's shoulder charge from range (it lunges about 4 m). --------------------
	await _charge_from_range(p, e)

	# --- A press with nothing coming: not Defence's. ----------------------------------------
	print("no attack")
	clear_events()
	var consumed := p.defence.on_dash_pressed(TimeDirector.now())
	check(not consumed and count_events(&"teleported") == 0 and count_events(&"sidestepped") == 0,
		"with no attack in the window Defence leaves the press to Traversal")
	Tuning.debug_teleport = teleport_was
	done()

## A heavy's e_charge started 3, 4.5 and 5.5 m away: a press in the window
## teleports and the charge never knocks the player down. Control: with no
## press, the charge from 5.5 m does knock him down.
func _charge_from_range(p: Fighter, grunt: Fighter) -> void:
	print("heavy shoulder charge from range")
	grunt.teleport_to(Vector3(30, 0, 30), Vector3.FORWARD)
	var h := spawn_dummy(&"heavy", Vector3(0, 0, -5.5), Vector3.BACK)
	await ticks(30)
	var down := await _charge(p, h, 5.5, false)
	check(down, "control: the charge from 5.5 m knocks the player down when he does nothing")
	for d: float in [3.0, 4.5, 5.5]:
		down = await _charge(p, h, d, true)
		var ev := _teleport_event()
		check(not ev.is_empty() and ev[5] == &"counter" and not down,
			"charge from %.1f m: the press teleports and the charge misses (down %s)" % [d, down])
	h.queue_free()
	await ticks(5)
	await _reset(p, grunt)

## One charge from `dist` m, with or without the press. true if the player was knocked down.
func _charge(p: Fighter, h: Fighter, dist: float, dash: bool) -> bool:
	await wait_until(func() -> bool: return p.can_act() and not p.is_down(), 900)
	await wait_real(Tuning.R7_TELEPORT_COOLDOWN)
	await reset_fighter(p, Vector3.ZERO, Vector3.FORWARD)
	await reset_fighter(h, Vector3(0, 0, -dist), Vector3.BACK)
	await settle(h)
	await ticks(30)
	p.hp = p.max_hp
	clear_events()
	check(h.combat.start_enemy_attack(&"e_charge", 0.6), "e_charge started from %.1f m" % dist)
	var down := false
	if dash:
		await wait_for_lead(h, LEAD)
		var gap := Vector2(h.global_position.x - p.global_position.x, h.global_position.z - p.global_position.z).length()
		print("  charge from %.1f m: %.2f m apart at the press, target %s" % [dist, gap, h.combat.get_attack_target()])
		await _dash()
	for i in 240:
		down = down or p.is_down()
		if not h.combat.is_attacking():
			break
		await get_tree().physics_frame
	for i in 30:
		down = down or p.is_down()
		await get_tree().physics_frame
	return down

## A real Dash tap (Shift): B gives it to Defence first, else Traversal.
func _dash() -> void:
	press(&"dash")
	await ticks(1)
	release(&"dash")
	await ticks(1)

func _teleport_event() -> Array:
	for i in range(events.size() - 1, -1, -1):
		if events[i][0] == &"teleported":
			return events[i]
	return []

func _reset(p: Fighter, e: Fighter) -> void:
	await settle(e)
	await settle(p)
	await wait_real(Tuning.R7_TELEPORT_COOLDOWN)
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
