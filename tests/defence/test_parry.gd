extends "res://tests/defence/defence_test_base.gd"
## F5 parry (Feel Reference: Parry: tap Block). Acceptance (agent H, with B):
## - A bot pressing Block inside the window parries all of 100 attacks.
## - A press outside any window locks parry for 20 frames.
## - A jab right after a parry logs P 3.5 and a knockdown (B builds P).
## Also: the parry staggers the attacker and freezes both 60 ms, +0.34 Focus,
## counter bonus 2.5 for 1.5 s real; holding Block through the window is a
## guard; grabs are never parried; one press covers two attacks in its window;
## a grunt's Block press never parries; the Duelist parries the player.
## The bot presses through the real input path (Input -> PlayerController ->
## CombatController.press(BLOCK) -> Defence).

const RING := 1.0  ## m from the player to each attacker

var _rng := RandomNumberGenerator.new()

func run() -> void:
	_rng.seed = 20261102
	var p := spawn_player(Vector3.ZERO)
	await ticks(30)
	check(p.defence != null and p.defence.is_enabled(), "Defence is on")
	var offs: Array[Vector3] = [Vector3(0, 0, -RING), Vector3(RING, 0, 0), Vector3(0, 0, RING), Vector3(-RING, 0, 0)]
	var es: Array[Fighter] = []
	for o in offs:
		es.append(spawn_attacker(p, &"grunt", o))
	await ticks(20)

	await _bot_100(p, es, offs)
	await _lockout(p, es[0], offs[0])
	await _hold_is_guard(p, es[0], offs[0])
	await _grab_not_parried(p, es[0], offs[0])
	await _one_press_two_attacks(p, es[0], es[1], offs[0], offs[1])
	await _jab_after_parry(p, es[0], offs[0])
	await _in_focus_mode(p, es[0], offs[0])
	for e in es:
		e.queue_free()
	await ticks(5)
	await _enemy_blocks(p)
	await _charge_from_range(p)
	done()

## Bot: 100 enemy jabs from four sides, each tapped Block 0-15 ticks (0-0.125 s)
## before the first active frame.
func _bot_100(p: Fighter, es: Array[Fighter], offs: Array[Vector3]) -> void:
	print("parry bot: 100 attacks")
	var parried := 0
	var landed := 0
	var leads: Array[int] = []
	var freeze_ok := true
	var stagger_ok := true
	for i in 100:
		var k := i % es.size()
		var e := es[k]
		await reset_fighter(e, p.global_position + offs[k], -offs[k])
		await settle(e)
		await settle(p)
		p.hp = p.max_hp
		clear_events()
		check_quiet(e.combat.start_enemy_attack(&"e_jab", Tuning.frames(18)), "attack %d started" % i)
		var lead_ticks := _rng.randi_range(1, 16)  # pressed (lead-1) ticks before the active frame
		leads.append(lead_ticks - 1)
		await wait_for_lead(e, lead_ticks / 120.0)
		press(&"block")
		await ticks(1)
		release(&"block")
		await wait_until(func() -> bool: return _count_parried(p, e) > 0 or e.combat.is_in_recovery() \
			or not e.combat.is_attacking(), 120)
		if _count_parried(p, e) > 0:
			parried += 1
			if not (e.is_frozen() and p.last_freeze <= Tuning.PLAYER_HITSTOP_MAX + 1e-4 \
					and absf(e.last_freeze - Tuning.PARRY_FREEZE) < 1e-4):
				freeze_ok = false
			await ticks(10)
			if not (e.get_state() == RagdollController.State.STAGGER or e.combat.is_hit_stunned()):
				stagger_ok = false
		if last_hit_by(e) != null:
			landed += 1
	var lo := 99
	var hi := 0
	for l in leads:
		lo = mini(lo, l)
		hi = maxi(hi, l)
	print("  presses %d-%d ticks (%.3f-%.3f s) before the first active frame" % [lo, hi, lo / 120.0, hi / 120.0])
	check(parried == 100, "bot parried %d / 100 attacks (hits landed %d)" % [parried, landed])
	check(landed == 0, "no parried attack landed")
	check(freeze_ok, "both froze on every parry (attacker %.3f s, player <= %.3f s)" % [Tuning.PARRY_FREEZE, Tuning.PLAYER_HITSTOP_MAX])
	check(stagger_ok, "every parried attacker staggered")

## A tap with no attack in its window locks parry for PARRY_LOCKOUT from the press.
func _lockout(p: Fighter, e: Fighter, off: Vector3) -> void:
	print("lockout")
	await reset_fighter(e, p.global_position + off, -off)
	await settle(e)
	await settle(p)
	await ticks(60)
	# Measure the lock itself.
	clear_events()
	press(&"block")
	await ticks(1)
	release(&"block")
	var t0 := p.defence.last_block_press_time()
	var locked_seen := false
	for i in 30:
		await get_tree().physics_frame
		locked_seen = locked_seen or p.defence.is_parry_locked()
	check(locked_seen and count_events(&"parry_whiffed") == 1, "a tap with nothing coming: parry_whiffed, parry locked")
	await wait_until(func() -> bool: return not p.defence.is_parry_locked(), 120)
	var lock_len := TimeDirector.now() - t0
	check(absf(lock_len - Tuning.PARRY_LOCKOUT) <= 1.5 / 120.0,
		"locked for %.3f s = %.1f frames (want %.0f)" % [lock_len, lock_len * 60.0, Tuning.PARRY_LOCKOUT * 60.0])
	await ticks(60)
	# A good press inside the lock does not parry; just after it, it does.
	for k: int in [30, 38, 41, 48]:
		await reset_fighter(e, p.global_position + off, -off)
		await settle(e)
		await settle(p)
		await ticks(60)
		p.hp = p.max_hp
		clear_events()
		e.combat.start_enemy_attack(&"e_jab", 0.7)
		# First press k + 6 ticks before the active frame (outside the window: a whiff)...
		await wait_for_lead(e, (k + 6) / 120.0)
		press(&"block")
		await ticks(1)
		release(&"block")
		# ...the second k ticks later, 5 ticks before the active frame.
		await wait_for_lead(e, 6 / 120.0)
		press(&"block")
		await ticks(1)
		release(&"block")
		await wait_until(func() -> bool: return not e.combat.is_attacking() or e.combat.is_in_recovery(), 120)
		var got := _count_parried(p, e) > 0
		var frames := k / 2.0
		var want := frames >= Tuning.PARRY_LOCKOUT * 60.0
		check(got == want, "second press %.1f frames after a whiff: %s (want %s)" % [frames,
			"parried" if got else "no parry", "parry" if want else "locked"])
		await settle(p)

## Holding Block from before the window is a normal guard, not a parry.
func _hold_is_guard(p: Fighter, e: Fighter, off: Vector3) -> void:
	print("hold = guard")
	await reset_fighter(e, p.global_position + off, -off)
	p.snap_facing(off)
	await settle(e)
	await settle(p)
	await ticks(60)
	clear_events()
	press(&"block")
	await ticks(50)
	e.combat.start_enemy_attack(&"e_jab", Tuning.frames(18))
	await wait_until(func() -> bool: return e.combat.is_in_recovery() or not e.combat.is_attacking(), 120)
	await ticks(5)
	release(&"block")
	check(_count_parried(p, e) == 0, "held Block through the window: no parry")
	check(e.combat.last_dealt != null and e.combat.last_dealt.result == HitInfo.Result.BLOCKED,
		"the jab is guarded (result %s)" % [e.combat.last_dealt.result if e.combat.last_dealt else "-"])
	await settle(p)

## Enemy grabs glow blue and cannot be parried.
func _grab_not_parried(p: Fighter, e: Fighter, off: Vector3) -> void:
	print("grab")
	await reset_fighter(e, p.global_position + off, -off)
	await settle(e)
	await settle(p)
	await ticks(60)
	clear_events()
	e.combat.start_enemy_attack(&"e_grab", Tuning.frames(20))
	await wait_for_lead(e, 6 / 120.0)
	press(&"block")
	await ticks(1)
	release(&"block")
	await ticks(30)
	check(_count_parried(p, e) == 0, "a Block tap in the window does not parry a grab")
	# Free both (a grab may have connected).
	if e.carry != null and e.carry.is_holding():
		e.carry.drop(&"release")
	await ticks(10)
	await reset_fighter(p, Vector3.ZERO, Vector3.FORWARD)
	await settle(p)

## One press covers every attack whose first active frame falls in its window.
func _one_press_two_attacks(p: Fighter, a: Fighter, b: Fighter, off_a: Vector3, off_b: Vector3) -> void:
	print("one press, two attacks")
	await reset_fighter(a, p.global_position + off_a, -off_a)
	await reset_fighter(b, p.global_position + off_b, -off_b)
	await settle(a)
	await settle(b)
	await settle(p)
	await ticks(60)
	p.hp = p.max_hp
	clear_events()
	a.combat.start_enemy_attack(&"e_jab", 0.3)
	await ticks(5)
	b.combat.start_enemy_attack(&"e_jab", 0.3)  # 5 ticks behind a
	await wait_for_lead(a, 4 / 120.0)  # b goes active 8 ticks after this press
	press(&"block")
	await ticks(1)
	release(&"block")
	await wait_until(func() -> bool: return not b.combat.is_attacking() or b.combat.is_in_recovery(), 120)
	var presses := 1
	check(_count_parried(p, a) == 1 and _count_parried(p, b) == 1,
		"%d press parried both attacks (a %d, b %d)" % [presses, _count_parried(p, a), _count_parried(p, b)])
	await settle(p)
	await settle(a)
	await settle(b)

## A jab right after a parry: P = 1.0 + 2.5 = 3.5 -> knockdown (B adds the bonus).
func _jab_after_parry(p: Fighter, e: Fighter, off: Vector3) -> void:
	print("jab after a parry")
	await reset_fighter(e, p.global_position + off, -off)
	p.snap_facing(off)
	await settle(e)
	await settle(p)
	await ticks(60)
	clear_events()
	var f0 := p.focus
	e.combat.start_enemy_attack(&"e_jab", Tuning.frames(18))
	await wait_for_lead(e, 6 / 120.0)
	press(&"block")
	await ticks(1)
	release(&"block")
	await wait_until(func() -> bool: return _count_parried(p, e) > 0, 60)
	check(_count_parried(p, e) == 1, "parried")
	var bonus := p.defence.counter_bonus()
	check(is_equal_approx(bonus, Tuning.COUNTER_BONUS_PARRY), "counter bonus %.2f (want %.1f)" % [bonus, Tuning.COUNTER_BONUS_PARRY])
	check(p.focus >= minf(f0 + float(Tuning.FOCUS_GAIN[&"parry"]), Tuning.FOCUS_MAX) - 1e-3,
		"Focus %.2f -> %.2f (+%.2f)" % [f0, p.focus, Tuning.FOCUS_GAIN[&"parry"]])
	var t_parry := TimeDirector.now()
	await wait_until(func() -> bool: return not p.is_frozen(), 30)
	press(&"punch")
	await ticks(1)
	release(&"punch")
	await wait_until(func() -> bool: return last_hit_by(p) != null, 90)
	var info := last_hit_by(p)
	if info == null:
		check(false, "the jab after the parry landed")
	else:
		print("  jab %.3f s after the parry: %s" % [TimeDirector.now() - t_parry, info])
		check(absf(info.power - 3.5) < 0.01, "jab after a parry logs P %.2f (want 3.5)" % info.power)
		check(info.tier == HitInfo.Tier.KNOCKDOWN, "tier %s (want knockdown)" % HitInfo.tier_name(info.tier))
		check(p.defence.counter_bonus() == 0.0, "the bonus is used up by the hit")
	# The bonus expires after COUNTER_BONUS_TIME real s when unused.
	await settle(p)
	await reset_fighter(e, p.global_position + off, -off)
	await settle(e)
	await ticks(60)
	clear_events()
	e.combat.start_enemy_attack(&"e_jab", Tuning.frames(18))
	await wait_for_lead(e, 6 / 120.0)
	press(&"block")
	await ticks(1)
	release(&"block")
	await wait_until(func() -> bool: return _count_parried(p, e) > 0, 60)
	var t1 := TimeDirector.now()
	await wait_until(func() -> bool: return p.defence.counter_bonus() <= 0.0, 400)
	var lasted := TimeDirector.now() - t1
	check(absf(lasted - Tuning.COUNTER_BONUS_TIME) <= 2.0 / 120.0,
		"unused counter bonus lasts %.3f real s (want %.1f)" % [lasted, Tuning.COUNTER_BONUS_TIME])
	await settle(p)

## A grunt's Block press is a guard, never a parry; the Duelist parries.
func _enemy_blocks(p: Fighter) -> void:
	print("enemy Block presses")
	await reset_fighter(p, Vector3.ZERO, Vector3.FORWARD)
	var g := spawn_dummy(&"grunt", Vector3(0, 0, -1.0), Vector3.BACK)
	await ticks(20)
	clear_events()
	p.combat.press(CombatController.Action.LIGHT)
	p.combat.release(CombatController.Action.LIGHT)  # a tap
	await wait_for_lead(p, 4 / 120.0, 120)
	g.combat.press(CombatController.Action.BLOCK)
	await wait_until(func() -> bool: return not p.combat.is_attacking() or p.combat.is_in_recovery(), 120)
	check(count_events(&"attack_active") > 0, "the player's jab went active")
	check(count_events(&"parried") == 0, "a grunt's timed Block press does not parry")
	g.combat.release(CombatController.Action.BLOCK)
	g.queue_free()
	await settle(p)
	var du := spawn_dummy(&"duelist", Vector3(0, 0, -1.0), Vector3.BACK)
	await ticks(20)
	await settle(p)
	clear_events()
	p.combat.press(CombatController.Action.LIGHT)
	p.combat.release(CombatController.Action.LIGHT)  # a tap
	await wait_for_lead(p, 4 / 120.0, 120)
	du.combat.press(CombatController.Action.BLOCK)
	await ticks(1)
	du.combat.release(CombatController.Action.BLOCK)
	await wait_until(func() -> bool: return count_events(&"parried") > 0 or not p.combat.is_attacking(), 120)
	var e := last_event(&"parried")
	check(not e.is_empty() and e[1] == du and e[2] == p, "the Duelist parries the player's jab")
	await ticks(10)
	check(p.combat.is_hit_stunned() or p.get_state() == RagdollController.State.STAGGER, "the player is staggered")
	du.queue_free()

## In Focus mode (world at 0.3x) the window is still 8 frames of real time.
func _in_focus_mode(p: Fighter, e: Fighter, off: Vector3) -> void:
	print("Focus mode")
	await reset_fighter(e, p.global_position + off, -off)
	await settle(e)
	await settle(p)
	await ticks(30)
	p.focus = 2.0
	press(&"focus")
	await ticks(1)
	release(&"focus")
	await ticks(1)
	check(p.is_focusing() and Engine.time_scale < 0.35, "Focus mode on (world %.2fx)" % Engine.time_scale)
	p.hp = p.max_hp
	clear_events()
	e.combat.start_enemy_attack(&"e_jab", Tuning.frames(18))
	await wait_for_lead(e, 6 / 120.0)
	var t_press := TimeDirector.now()
	press(&"block")
	await ticks(1)
	release(&"block")
	var scale_at := -1.0
	for i in 400:
		if _count_parried(p, e) > 0 or not e.combat.is_attacking():
			break
		scale_at = Engine.time_scale
		await get_tree().physics_frame
	var ev := last_event(&"parried")
	if not ev.is_empty():
		print("  Block %.3f real s before the parried first active frame, world at %.2fx" % [float(ev[4]) - t_press, scale_at])
	check(_count_parried(p, e) == 1 and last_hit_by(e) == null and scale_at < 0.35,
		"Focus mode: a Block tap in the window parries (world %.2fx)" % scale_at)
	# And a tap well before the window (0.3 s real, 18 frames) is a whiff.
	p.end_focus()
	TimeDirector.reset()
	await reset_fighter(e, p.global_position + off, -off)
	await settle(e)
	await settle(p)
	p.focus = 2.0
	press(&"focus")
	await ticks(1)
	release(&"focus")
	await ticks(1)
	check(p.is_focusing(), "Focus mode on again")
	clear_events()
	e.combat.start_enemy_attack(&"e_jab", Tuning.frames(18))
	await wait_for_lead(e, 0.3)
	press(&"block")
	await ticks(1)
	release(&"block")
	await wait_until(func() -> bool: return not e.combat.is_attacking() or e.combat.is_in_recovery(), 400)
	check(_count_parried(p, e) == 0, "Focus mode: a tap 0.3 real s early does not parry")
	p.end_focus()
	TimeDirector.reset()
	await settle(p)

## The heavy's shoulder charge (it lunges about 4 m) started 3, 4.5 and 5.5 m
## away: a Block tap in the window parries it and the player stays up.
func _charge_from_range(p: Fighter) -> void:
	print("heavy shoulder charge from range")
	await reset_fighter(p, Vector3.ZERO, Vector3.FORWARD)
	var h := spawn_dummy(&"heavy", Vector3(0, 0, -5.5), Vector3.BACK)
	await ticks(30)
	for d: float in [3.0, 4.5, 5.5]:
		await wait_until(func() -> bool: return p.can_act() and not p.is_down(), 900)
		await reset_fighter(p, Vector3.ZERO, Vector3.FORWARD)
		await reset_fighter(h, Vector3(0, 0, -d), Vector3.BACK)
		await settle(h)
		await settle(p)
		await ticks(30)
		p.hp = p.max_hp
		clear_events()
		h.combat.start_enemy_attack(&"e_charge", Tuning.frames(28))
		await wait_for_lead(h, 6 / 120.0)
		var gap := Vector2(h.global_position.x, h.global_position.z).length()
		press(&"block")
		await ticks(1)
		release(&"block")
		var down := false
		for i in 240:
			down = down or p.is_down()
			if _count_parried(p, h) > 0 or not h.combat.is_attacking():
				break
			await get_tree().physics_frame
		for i in 40:
			down = down or p.is_down()
			await get_tree().physics_frame
		print("  charge from %.1f m: %.2f m apart at the press, parried %d, player down %s" % [d, gap, _count_parried(p, h), down])
		check(_count_parried(p, h) == 1 and not down, "charge from %.1f m: a Block tap in the window parries it" % d)
	h.queue_free()

func _count_parried(def: Fighter, att: Fighter) -> int:
	var n := 0
	for ev in events:
		if ev[0] == &"parried" and ev[1] == def and ev[2] == att:
			n += 1
	return n

## A check that only prints on failure (inner-loop bookkeeping).
func check_quiet(cond: bool, msg: String) -> void:
	if not cond:
		check(false, msg)
