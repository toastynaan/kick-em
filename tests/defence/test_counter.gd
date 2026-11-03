extends "res://tests/defence/defence_test_base.gd"
## Round 7 counter (acceptance 6, agent H with B's windows and counter move).
## Every press goes through the real input path: Input.action_press(&"counter")
## -> PlayerController -> InputInterpreter -> CombatController.press(COUNTER)
## -> Defence.on_counter_pressed.
## - A bot presses Counter at a random point inside the window of 100 orange-tell
##   enemy strikes (every orange move, several archetypes): every one is
##   countered (GameEvents.countered), the attack never lands, and B's counter
##   move hits the attacker.
## - Outside the window a press whiffs: GameEvents.counter_whiffed and the lock
##   (Tuning.R7_COUNTER_WHIFF_LOCK); a press inside a window during the lock
##   does nothing and that attack lands; a press during the lock with no window
##   extends it.
## - Blue-tell moves (grabs, the shoulder charge) cannot be countered.
## - A second attack whose first active frame falls inside the counter's
##   invulnerability misses, and the earliest of two open windows is countered.
## Prints the measured numbers.

const TRIALS := 100
const ORANGE := [[&"grunt", &"e_jab"], [&"grunt", &"e_hook"], [&"grunt", &"e_kick"],
	[&"stick", &"e_stick_swing"], [&"stick", &"e_stick_thrust"], [&"heavy", &"e_heavy"],
	[&"brawler", &"e_hook"], [&"brawler", &"e_heavy"], [&"shield", &"e_hook"], [&"duelist", &"e_kick"]]
const BLUE := [[&"grunt", &"e_grab"], [&"heavy", &"e_grab_slam"], [&"heavy", &"e_charge"]]
const FRONT := Vector3(0, 0, -1.2)   ## attacker spot in front of the player
const PARK := Vector3(40, 0, 40)      ## where unused attackers wait
const TICK := 1.0 / 120.0

var _rng := RandomNumberGenerator.new()
var _attackers := {}  ## archetype -> Fighter

func run() -> void:
	_rng.seed = 7
	var p := spawn_player(Vector3.ZERO)
	p.max_hp = 100000.0
	p.hp = p.max_hp
	if AttackDirector.has_method(&"set_player"):
		AttackDirector.set_player(p)
	var i := 0
	for arch: StringName in [&"grunt", &"stick", &"heavy", &"brawler", &"shield", &"duelist"]:
		var e: Fighter = spawn_dummy(arch, PARK + Vector3(i * 4.0, 0, 0), Vector3.FORWARD)
		e.max_hp = 100000.0  # a hundred counters must not kill anyone
		e.hp = e.max_hp
		_attackers[arch] = e
		i += 1
	await ticks(60)
	var tell_min := Tuning.R7_COUNTER_WINDOW + Tuning.R7_TELL_MARGIN

	# --- 100 orange-tell strikes, the bot presses inside each window. ------------------------
	var ok := 0
	var countered := 0
	var landed := 0
	var counter_hits := 0
	var started := 0
	var windows := 0
	var real_path := 0
	var leads: Array[float] = []
	var failed: PackedStringArray = []
	for n in TRIALS:
		var pair: Array = ORANGE[n % ORANGE.size()]
		var e: Fighter = await _bring(p, pair[0], FRONT)
		var hp0 := p.hp
		var ev0 := events.size()
		var presses0 := p.defence.counter_presses
		var tell := tell_min + _rng.randf_range(0.0, 0.3)
		if not e.combat.start_enemy_attack(pair[1], tell):
			failed.append("%d %s: attack did not start" % [n, pair[1]])
			continue
		started += 1
		var lead := _rng.randf_range(0.03, Tuning.R7_COUNTER_WINDOW - 0.03)
		await wait_for_lead(e, lead)
		var tta := e.combat.time_to_active()
		var open := e.combat.is_counter_window_open(p) and e.combat.is_attack_counterable()
		if open:
			windows += 1
		leads.append(tta)
		press(&"counter")
		await ticks(1)
		release(&"counter")
		if p.defence.counter_presses > presses0:
			real_path += 1
		# Past the attack's would-be active frames (and the counter move's contact).
		await ticks(int(ceil((tta + 0.3) / TICK)))
		var was_countered := _countered_by(p, e, ev0)
		var hits_taken := hits_on(p, e, ev0)
		var hit_back := hits_on(e, p, ev0)
		if was_countered:
			countered += 1
		if hits_taken > 0 or p.hp < hp0:
			landed += 1
		if hit_back > 0:
			counter_hits += 1
		if was_countered and hits_taken == 0 and p.hp >= hp0 and hit_back > 0:
			ok += 1
		else:
			failed.append("%d %s/%s lead %.3f: countered %s, hits taken %d, counter hits %d" % [n, pair[0], pair[1],
				tta, was_countered, hits_taken, hit_back])
	leads.sort()
	print("  orange strikes: %d started, window open at the press %d, countered %d, landed on the player %d, counter move hit %d"
		% [started, windows, countered, landed, counter_hits])
	print("  press lead before the first active frame: %.3f .. %.3f s (window %.2f s), presses through PlayerController %d"
		% [leads[0], leads[leads.size() - 1], Tuning.R7_COUNTER_WINDOW, real_path])
	for f in failed:
		print("    miss: ", f)
	check(real_path == TRIALS, "every press reached Defence through the real input path (%d/%d)" % [real_path, TRIALS])
	check(windows == TRIALS, "the window was open and counterable at every press (%d/%d)" % [windows, TRIALS])
	check(ok == TRIALS, "counter %d/%d against orange-tell strikes (countered, never hit, counter move landed)" % [ok, TRIALS])

	# --- Whiff and lock. --------------------------------------------------------------------
	await _bring_player(p)
	var ev1 := events.size()
	var t_whiff := TimeDirector.now()
	press(&"counter")
	await ticks(1)
	release(&"counter")
	var whiffed := count_since(&"counter_whiffed", ev1, p) == 1 and p.defence.is_counter_locked()
	var lock_end := -1.0
	for k in 120:
		if not p.defence.is_counter_locked():
			lock_end = TimeDirector.now()
			break
		await get_tree().physics_frame
	var lock_len := lock_end - t_whiff
	print("  a press with no window: whiff lock %.3f s (want %.2f)" % [lock_len, Tuning.R7_COUNTER_WHIFF_LOCK])
	check(whiffed, "a press with no window open whiffs (counter_whiffed) and locks")
	check(absf(lock_len - Tuning.R7_COUNTER_WHIFF_LOCK) <= 1.5 * TICK, "the lock lasts %.3f s" % lock_len)

	# A press during the lock with no window extends it (mashing never counters).
	await ticks(30)
	var t_a := TimeDirector.now()
	press(&"counter")
	await ticks(1)
	release(&"counter")
	await ticks(23)  # 0.2 s after the first press
	var ev2 := events.size()
	var t_b := TimeDirector.now()
	press(&"counter")
	await ticks(1)
	release(&"counter")
	var lock_end2 := -1.0
	for k in 120:
		if not p.defence.is_counter_locked():
			lock_end2 = TimeDirector.now()
			break
		await get_tree().physics_frame
	print("  mash: presses at +0.00 and +%.2f s, lock ends %.3f s after the first (want %.2f)"
		% [t_b - t_a, lock_end2 - t_a, t_b - t_a + Tuning.R7_COUNTER_WHIFF_LOCK])
	check(count_since(&"counter_whiffed", ev2, p) == 1 and absf(lock_end2 - (t_b + Tuning.R7_COUNTER_WHIFF_LOCK)) <= 1.5 * TICK,
		"a press inside the lock with no window whiffs again and extends the lock")

	# Whiff just before the window, then press inside it while still locked: the attack lands.
	await ticks(60)
	var e2: Fighter = await _bring(p, &"grunt", FRONT)
	var hp1 := p.hp
	var ev3 := events.size()
	e2.combat.start_enemy_attack(&"e_hook", 0.8)
	await wait_for_lead(e2, Tuning.R7_COUNTER_WINDOW + 0.15)
	var early := e2.combat.is_counter_window_open(p)
	press(&"counter")
	await ticks(1)
	release(&"counter")
	await wait_for_lead(e2, 0.3)
	var locked_in_window := p.defence.is_counter_locked() and e2.combat.is_counter_window_open(p)
	press(&"counter")
	await ticks(1)
	release(&"counter")
	await ticks(60)
	var whiffs3 := count_since(&"counter_whiffed", ev3, p)
	var counters3 := count_since(&"countered", ev3, p)
	var hit3 := hits_on(p, e2, ev3)
	print("  whiff 0.15 s before the window, press inside it during the lock: whiffs %d, counters %d, hits taken %d (hp %.0f -> %.0f)"
		% [whiffs3, counters3, hit3, hp1, p.hp])
	check(not early and locked_in_window, "the second press came inside the window while the lock ran")
	check(whiffs3 == 1 and counters3 == 0, "the locked press does nothing (no counter, no second whiff)")
	check(hit3 >= 1, "so the attack lands on the player")

	# --- Blue tells: grabs and the shoulder charge cannot be countered. -------------------------
	var blue_ok := 0
	var blue_n := 0
	for b: Array in BLUE:
		for k in 2:
			blue_n += 1
			var eb: Fighter = await _bring(p, b[0], FRONT if b[1] != &"e_charge" else Vector3(0, 0, -3.0))
			await ticks(30)  # any earlier whiff lock is long gone
			var ev4 := events.size()
			if not eb.combat.start_enemy_attack(b[1], 0.7):
				print("    blue %s did not start" % b[1])
				continue
			await wait_for_lead(eb, 0.2)
			var blue_open := eb.combat.is_counter_window_open(p) and not eb.combat.is_attack_counterable()
			var listed := p.defence.get_uncounterable_attackers().has(eb) and p.defence.get_counterable_attackers().is_empty()
			press(&"counter")
			await ticks(1)
			release(&"counter")
			await ticks(3)
			var no_counter := count_since(&"countered", ev4, p) == 0 and not p.defence.is_countering()
			var whiff := count_since(&"counter_whiffed", ev4, p) == 1
			var still := eb.combat.is_attacking()
			print("  blue %-12s window open %s, listed %s, countered %s, whiffed %s, attack goes on %s"
				% [b[1], blue_open, listed, not no_counter, whiff, still])
			if blue_open and listed and no_counter and whiff and still:
				blue_ok += 1
			await ticks(150)
	check(blue_ok == blue_n, "blue-tell moves cannot be countered (%d/%d)" % [blue_ok, blue_n])

	# --- Own move: never during its active frames (no lock), at once from its recovery. ----------
	var side_e: Fighter = await _bring(p, &"grunt", Vector3(1.3, 0, 0))
	var bag: Fighter = await _bring(p, &"shield", FRONT, false)  # the jab's target, straight ahead
	await ticks(30)
	var ev7 := events.size()
	side_e.combat.start_enemy_attack(&"e_hook", 0.9)
	await wait_for_lead(side_e, 0.38)
	press(&"punch")
	await ticks(1)
	release(&"punch")
	await wait_until(func() -> bool: return p.combat.is_attack_active(), 60)
	var in_active := p.combat.is_attack_active() and side_e.combat.is_counter_window_open(p)
	var presses_a := p.defence.counter_presses
	press(&"counter")
	await ticks(1)
	release(&"counter")
	var active_nothing := p.defence.counter_presses == presses_a + 1 and count_since(&"countered", ev7, p) == 0 \
		and count_since(&"counter_whiffed", ev7, p) == 0 and not p.defence.is_counter_locked()
	await wait_until(func() -> bool: return p.combat.is_in_recovery(), 60)
	var in_recovery := p.combat.is_in_recovery() and side_e.combat.is_counter_window_open(p)
	press(&"counter")
	await ticks(1)
	release(&"counter")
	await ticks(60)
	var from_recovery := _countered_by(p, side_e, ev7) and hits_on(p, side_e, ev7) == 0
	print("  own jab: press in its active frames (window open %s) -> nothing, no lock: %s; press in its recovery (window open %s) -> countered: %s"
		% [in_active, active_nothing, in_recovery, from_recovery])
	check(in_active and active_nothing, "a press during the player's own active frames does nothing and does not lock")
	check(in_recovery and from_recovery, "a press during the player's own recovery counters at once")
	await reset_fighter(bag, PARK + Vector3(16, 0, 0), Vector3.FORWARD)

	# --- A second attack landing inside the counter's invulnerability misses. -------------------
	var second_ok := 0
	var offsets: Array[float] = [0.05, 0.1, 0.15, 0.2, 0.25, 0.3]
	for off in offsets:
		var a1: Fighter = await _bring(p, &"grunt", FRONT)
		var a2: Fighter = await _bring(p, &"stick", Vector3(1.1, 0, -0.6), false)
		await ticks(50)
		var hp2 := p.hp
		var ev5 := events.size()
		a1.combat.start_enemy_attack(&"e_jab", 0.6)
		a2.combat.start_enemy_attack(&"e_stick_swing", 0.6 + off)
		await wait_for_lead(a1, 0.1)
		var both_open := p.defence.get_counterable_attackers().size() == 2
		var first_is_a1 := not p.defence.get_counterable_attackers().is_empty() and p.defence.get_counterable_attackers()[0] == a1
		var t_press := TimeDirector.now()
		press(&"counter")
		await ticks(1)
		release(&"counter")
		var t_a2 := await wait_active(a2)
		var inv_at_a2 := p.is_invulnerable()
		await ticks(90)
		var who: Variant = null
		for k in range(ev5, events.size()):
			if events[k][0] == &"countered" and events[k][1] == p:
				who = events[k][2]
		var a2_hits := hits_on(p, a2, ev5)
		print("  second attack %.2f s later: both windows open %s, countered %s, its first active frame %.3f s after the press (invulnerable %s), hits taken %d"
			% [off, both_open, (who as Fighter).archetype if who != null else &"none", t_a2 - t_press, inv_at_a2, a2_hits])
		if both_open and first_is_a1 and who == a1 and t_a2 > 0.0 and t_a2 - t_press < Tuning.R7_COUNTER_INVULN \
				and inv_at_a2 and a2_hits == 0 and p.hp >= hp2:
			second_ok += 1
	check(second_ok == offsets.size(), "the earliest window is countered and the second attack misses (%d/%d)" % [second_ok, offsets.size()])

	# Control: from the same spot, without a counter, that second attack lands.
	await _bring(p, &"grunt", FRONT)
	var a3: Fighter = await _bring(p, &"stick", Vector3(1.1, 0, -0.6), false)
	await ticks(50)
	var ev6 := events.size()
	a3.combat.start_enemy_attack(&"e_stick_swing", 0.6)
	await ticks(120)
	var control := hits_on(p, a3, ev6)
	print("  control: the same second attack with no counter: hits taken %d" % control)
	check(control >= 1, "without the counter that second attack lands (so the miss above is the invulnerability)")
	done()

## `arch`'s attacker at `offset` from a reset player, facing him; every other
## attacker parked. Waits until both can act.
func _bring(p: Fighter, arch: StringName, offset: Vector3, park_others := true) -> Fighter:
	await _bring_player(p)
	var e: Fighter = _attackers[arch]
	if park_others:
		var j := 0
		for a: StringName in _attackers:
			var other: Fighter = _attackers[a]
			if other != e:
				await reset_fighter(other, PARK + Vector3(j * 4.0, 0, 0), Vector3.FORWARD)
			j += 1
	await reset_fighter(e, p.global_position + offset, -offset)
	await ticks(4)
	return e

func _bring_player(p: Fighter) -> void:
	await wait_until(func() -> bool: return not p.is_down() and not p.is_held(), 600)
	await reset_fighter(p, Vector3.ZERO, Vector3.FORWARD)
	await settle(p, 240)

## GameEvents.countered(p, e) since index `from`.
func _countered_by(p: Fighter, e: Fighter, from: int) -> bool:
	for k in range(from, events.size()):
		if events[k][0] == &"countered" and events[k][1] == p and events[k][2] == e:
			return true
	return false
