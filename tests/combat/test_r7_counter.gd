extends "res://tests/combat/combat_test_base.gd"
## Round 7 counter, B's side (docs/Round 7 — Freeflow Combat.md: Defence >
## Counter; agent H's Defence runs the press itself):
## - every enemy attack emits GameEvents.counter_window(attacker, target, true,
##   counterable) R7_COUNTER_WINDOW before its first active frame and false
##   when it ends, is cancelled, the attacker is hit or dies;
##   is_counter_window_open(on) and is_attack_counterable() report it; grabs
##   and the shoulder charge are uncounterable with a non-strike tell kind;
## - Counter routes to Defence; play_counter() cancels the player's own glide,
##   startup or recovery (never active frames: can_cancel()), glides up to
##   R7_COUNTER_GLIDE and the counter move connects (HitInfo.counter);
## - an attack whose first active frame finds its target invulnerable misses it
##   for good, even when the invulnerability ends inside its active frames.

const DefenceDouble := preload("res://tests/combat/defence_double.gd")

var _x := 0.0
var _windows: Array = []  ## [attacker, target, open, counterable, real time]

func _init() -> void:
	_timeout = 120.0

func run() -> void:
	GameEvents.counter_window.connect(func(a: Node3D, t: Node3D, open: bool, c: bool) -> void:
		_windows.append([a, t, open, c, TimeDirector.now()]))
	var tells := []
	GameEvents.attack_tell.connect(func(a: Node3D, k: StringName, _d: float) -> void: tells.append([a, k]))

	print("the window opens R7_COUNTER_WINDOW before the first active frame, closes when the attack ends")
	var p := _player()
	var e := spawn(&"grunt", p.global_position + Vector3(0, 0, -1.3), Vector3.BACK)
	await ticks(15)
	var act := [0.0]
	e.combat.attack_active.connect(func(_id: StringName) -> void: act[0] = TimeDirector.now() if act[0] == 0.0 else act[0])
	_windows.clear()
	e.combat.start_enemy_attack(&"e_hook", 0.8)
	await wait_until(func() -> bool: return _opened(e) != null, 1.0)
	var w: Array = _opened(e)
	check(w != null and w[1] == p and w[3] == true, "counter_window(attacker, player, true, counterable)")
	check(e.combat.is_counter_window_open(p) and not e.combat.is_counter_window_open(e) and e.combat.is_attack_counterable(),
		"is_counter_window_open(player) and is_attack_counterable() while it is open")
	await wait_until(func() -> bool: return act[0] > 0.0, 1.5)
	var lead: float = act[0] - float(w[4]) if w != null else -1.0
	print("DATA window opened %.3f s before the first active frame (R7_COUNTER_WINDOW %.2f)" % [lead, Tuning.R7_COUNTER_WINDOW])
	check(absf(lead - Tuning.R7_COUNTER_WINDOW) <= 1.0 / 60.0, "it opens R7_COUNTER_WINDOW before the first active frame")
	check(e.combat.is_counter_window_open(p), "still open through the active frames")
	await wait_until(func() -> bool: return e.combat.is_in_recovery(), 1.0)
	await ticks(1)
	var c: Array = _closed(e)
	check(c != null and c[1] == p and not e.combat.is_counter_window_open(p), "closed (false) when the active frames end")
	await wait_until(func() -> bool: return not e.combat.is_attacking(), 2.0)

	print("closes on cancel, on a hit, on death; uncounterable attacks")
	for how: String in ["cancel", "hit", "death"]:
		await wait_real(0.6)
		place_in_front(p, e, 1.3)
		await ticks(4)
		_windows.clear()
		e.combat.start_enemy_attack(&"e_heavy", 0.6)
		await wait_until(func() -> bool: return _opened(e) != null, 1.0)
		match how:
			"cancel":
				e.combat.cancel()
			"hit":
				p.combat.play_move(&"jab", e)
				await wait_until(func() -> bool: return not hits_on(e).is_empty(), 1.0)
			"death":
				e.apply_damage(e.hp + 1.0, &"test")
		await ticks(1)
		check(_opened(e) != null and _closed(e) != null and not e.combat.is_counter_window_open(p),
			"the open window closes on %s" % how)
		clear_events()
		await wait_until(func() -> bool: return not p.combat.is_attacking(), 1.5)
	e.queue_free()
	for spec: Array in [[&"grunt", &"e_grab", &"grab"], [&"heavy", &"e_charge", &"charge"], [&"grunt", &"e_jab", &"strike"]]:
		var a := spawn(spec[0], p.global_position + Vector3(0, 0, -1.4), Vector3.BACK)
		await ticks(15)
		_windows.clear()
		tells.clear()
		a.combat.start_enemy_attack(spec[1], 0.7)
		await wait_until(func() -> bool: return _opened(a) != null, 1.0)
		var ow: Array = _opened(a)
		var counterable: bool = spec[2] == &"strike"
		check(ow != null and ow[3] == counterable and a.combat.is_attack_counterable() == counterable
			and not tells.is_empty() and tells[0][1] == spec[2],
			"%s: window counterable %s, tell %s" % [spec[1], counterable, spec[2]])
		a.combat.cancel()
		a.queue_free()
		await ticks(2)

	print("Counter routes to Defence; play_counter from idle glides and connects")
	p = _player()
	var dd: Defence = DefenceDouble.new()
	p.add_child(dd)
	dd.setup(p)
	p.defence = dd
	var att := spawn(&"grunt", p.global_position + Vector3(0, 0, -2.6), Vector3.BACK)
	await ticks(15)
	clear_events()
	att.combat.start_enemy_attack(&"e_hook", 0.8)
	await wait_until(func() -> bool: return att.combat.is_counter_window_open(p), 1.0)
	dd.set(&"counter_target", att)
	p.combat.press(A.COUNTER)
	var glided := p.combat.is_gliding()
	await wait_until(func() -> bool: return not hits_on(att).is_empty(), 1.0)
	var ci: HitInfo = hits_on(att)[0] if not hits_on(att).is_empty() else null
	check((dd.get(&"presses") as Array).size() == 1 and (dd.get(&"played") as Array) == [true],
		"Counter goes to Defence, which plays the counter")
	check(glided and not last_event(&"glide_started").is_empty(), "the counter glides to an attacker 2.6 m away")
	check(ci != null and ci.move_id == &"counter" and ci.counter and ci.react == &"push", "the counter connects (HitInfo.counter, push)")
	check(_closed(att) != null and not att.combat.is_attacking() or att.is_reacting(), "the countered attack is over")
	await wait_until(func() -> bool: return not p.combat.is_attacking(), 1.5)

	print("play_counter cancels the player's own startup or recovery, never active frames")
	for phase: String in ["startup", "recovery", "active"]:
		await wait_real(0.8)
		var v := spawn(&"grunt", p.global_position + p.get_forward() * 1.2, -p.get_forward())
		await ticks(12)
		p.combat.play_move(&"roundhouse", null)
		match phase:
			"startup":
				await ticks(4)
			"active":
				await wait_until(func() -> bool: return p.combat.is_attack_active(), 1.0)
			"recovery":
				await wait_until(func() -> bool: return p.combat.is_in_recovery(), 1.0)
		var can := p.combat.can_cancel()
		var ok := p.combat.play_counter(v)
		var now_move := p.combat.current_move_id()
		print("  in its %s: can_cancel %s, play_counter %s, move now %s" % [phase, can, ok, now_move])
		if phase == "active":
			check(not can and not ok and now_move == &"roundhouse", "never in the active frames")
		else:
			check(can and ok and now_move == &"counter", "the %s is cancelled into the counter" % phase)
		await wait_until(func() -> bool: return not p.combat.is_attacking(), 2.0)
		v.queue_free()

	print("an attack whose first active frame finds its target invulnerable misses it")
	p = _player()
	var hv := spawn(&"grunt", p.global_position + Vector3(0, 0, -1.2), Vector3.BACK)
	await ticks(15)
	clear_events()
	hv.combat.start_enemy_attack(&"e_heavy", 0.5)
	await wait_until(func() -> bool: return hv.combat.time_to_active() <= 1.5 / 120.0, 1.5)
	p.invuln_until = TimeDirector.now() + 2.5 / 120.0  # covers the first active frame only
	var hp0 := p.hp
	await wait_until(func() -> bool: return hv.combat.is_in_recovery(), 1.5)
	print("  e_heavy: %d active frames, the player invulnerable only for its first; hits %d, damage %.1f" % [
		int(MoveLibrary.get_move(&"e_heavy").active), hits_on(p).size(), hp0 - p.hp])
	check(hits_on(p).is_empty() and is_equal_approx(p.hp, hp0), "the attack misses for good")
	done()

func _player() -> Fighter:
	_x += 20.0
	return spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)

func _opened(a: Fighter) -> Variant:
	for w: Array in _windows:
		if w[0] == a and w[2]:
			return w
	return null

func _closed(a: Fighter) -> Variant:
	for w: Array in _windows:
		if w[0] == a and not w[2]:
			return w
	return null
