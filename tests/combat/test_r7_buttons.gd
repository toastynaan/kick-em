extends "res://tests/combat/combat_test_base.gd"
## Round 7 acceptance check 1 (docs/Round 7 — Freeflow Combat.md: Controls,
## Moves), through the real input path (Input.action_press -> PlayerController
## -> InputInterpreter -> CombatController):
## - each button fires its move: punch (LMB) the jab, leg_kick (RMB), gut_punch
##   (Q), uppercut (E), front_kick (F), roundhouse (R); counter (Space) inside
##   an enemy's counter window plays the counter;
## - LMB tapped counts jab -> cross -> hook and wraps; held it gives the heavy of
##   that position; a heavy's startup counts from the press; a tap fires on its
##   own frame data;
## - the string resets to the jab on a whiff and on a dropped chain.

const PRESS := 0.05   ## s a tap holds the button
const HOLD := 0.3     ## s a hold holds it (past Tuning.R7_HOLD_THRESHOLD)

var _p: Fighter
var _moves: Array[StringName] = []
var _active_at := {}  ## move id -> real time of its last attack_active

func _init() -> void:
	_timeout = 120.0

func run() -> void:
	_p = spawn_player(Vector3.ZERO)
	# The move each press became (attack_active: a held punch has turned into its heavy by then).
	_p.combat.attack_active.connect(func(id: StringName) -> void:
		_active_at[id] = TimeDirector.now()
		_moves.append(id))
	await ticks(20)

	print("each button fires its move (no enemy near: they whiff along the facing)")
	for spec: Array in [[&"punch", &"jab"], [&"leg_kick", &"leg_kick"], [&"gut_punch", &"gut_punch"],
			[&"uppercut", &"uppercut"], [&"front_kick", &"front_kick"], [&"roundhouse", &"roundhouse"]]:
		await _idle()
		_moves.clear()
		await tap_input(spec[0], PRESS)
		await wait_until(func() -> bool: return not _moves.is_empty(), 0.5)
		check(_moves.size() == 1 and _moves[0] == spec[1], "%s fires %s (%s)" % [spec[0], spec[1], _moves])
		await _idle()

	print("counter inside an enemy's counter window")
	var e := spawn(&"grunt", Vector3(0, 0, -1.4), Vector3.BACK)
	await ticks(15)
	await _idle()
	_moves.clear()
	e.combat.start_enemy_attack(&"e_hook", 0.6)
	var opened := await wait_until(func() -> bool: return e.combat.is_counter_window_open(_p), 1.0)
	await tap_input(&"counter", PRESS)
	await wait_until(func() -> bool: return _moves.has(&"counter"), 0.5)
	check(opened and _moves.has(&"counter"), "counter (Space) in the window plays the counter (%s)" % _moves)
	await wait_real(1.0)
	e.queue_free()

	print("LMB: tap / hold along the string, the wrap")
	var g := spawn(&"grunt", _p.global_position + _p.get_forward() * 1.2, -_p.get_forward())
	await ticks(15)

	await _idle()
	var want: Array[StringName] = [&"jab", &"heavy_cross", &"hook", &"jab", &"cross", &"heavy_hook"]
	_moves.clear()
	for id: StringName in want:
		await _press_in_chain(id.begins_with("heavy"))
	await _idle()
	print("  pressed tap, hold, tap, tap, tap, hold -> %s" % [_moves])
	check(_moves == want, "LMB string: jab, heavy cross, hook, then wraps to jab, cross, heavy hook")
	var lands := hits_on(g)
	check(lands.size() == want.size(), "every one of them landed on the grunt (%d)" % lands.size())

	print("hold for heavy: the punch and the three kicks, through the input path and press()/release()")
	var plain := spawn_dummy_player()
	await ticks(10)
	for spec: Array in [[&"punch", A.LIGHT, &"heavy_jab"], [&"leg_kick", A.LEG_KICK, &"heavy_leg_kick"],
			[&"front_kick", A.FRONT_KICK, &"heavy_front_kick"], [&"roundhouse", A.ROUNDHOUSE, &"heavy_roundhouse"]]:
		await _fresh_chain()
		_moves.clear()
		Input.action_press(spec[0])
		await wait_real(HOLD)
		Input.action_release(spec[0])
		await wait_until(func() -> bool: return not _moves.is_empty(), 1.0)
		check(_moves.size() == 1 and _moves[0] == spec[2], "%s held %.2f s (input): %s (%s)" % [spec[0], HOLD, spec[2], _moves])
		await _fresh_chain()
		var got: Array[StringName] = []
		var cb := func(id: StringName) -> void: got.append(id)
		plain.combat.attack_active.connect(cb)
		plain.combat.press(spec[1])
		await wait_real(0.35)
		plain.combat.release(spec[1])
		await wait_until(func() -> bool: return not got.is_empty(), 1.0)
		plain.combat.attack_active.disconnect(cb)
		check(got.size() == 1 and got[0] == spec[2], "press()/release() held 0.35 s on a player with no PlayerController: %s (%s)" % [spec[2], got])
		await wait_until(func() -> bool: return not plain.combat.is_attacking(), 2.0)
	plain.queue_free()

	print("startup timing: a tap fires on its frame data, a heavy's startup counts from the press")
	g.queue_free()
	await _fresh_chain()
	var t0 := await _press_timed(false)
	var tap_su := float(_active_at.get(&"jab", INF)) - t0
	await _idle()
	await _fresh_chain()
	var t1 := await _press_timed(true)
	var heavy_su := float(_active_at.get(&"heavy_jab", INF)) - t1
	print("  jab tap: active %.3f s after the press (%.3f); heavy jab hold: %.3f s (%.3f)" % [tap_su,
		Tuning.frames(7), heavy_su, Tuning.frames(20)])
	check(absf(tap_su - Tuning.frames(Tuning.R7_MOVES[&"jab"]["f"].x)) <= 0.011, "the tapped jab's startup is its own")
	check(absf(heavy_su - Tuning.frames(Tuning.R7_MOVES[&"heavy_jab"]["f"].x)) <= 0.011,
		"the heavy jab's startup counts from the press (not after the %.1f s hold)" % Tuning.R7_HOLD_THRESHOLD)

	print("the string resets on a whiff and on a dropped chain")
	await _idle()
	var g2 := spawn(&"grunt", _p.global_position + _p.get_forward() * 1.2, -_p.get_forward())
	await ticks(15)
	await _fresh_chain()
	_moves.clear()
	await _press_in_chain(false)   # jab, lands
	await _press_in_chain(false)   # cross, lands
	await wait_until(func() -> bool: return hits_on(g2).size() >= 2, 1.0)
	g2.global_position = _p.global_position - _p.get_forward() * 12.0  # out of reach and behind
	g2.reset_physics_interpolation()
	await _press_in_chain(false)   # hook: nothing to hit, a whiff
	check(_moves.size() == 3 and _moves[2] == &"hook" and _p.combat.get_string_index() == 0,
		"after a whiffed hook the string is back at the jab (index %d)" % _p.combat.get_string_index())
	await _idle()
	place_in_front(_p, g2, 1.2)
	await ticks(10)
	await _press_in_chain(false)   # jab after the whiff
	check(_moves.size() == 4 and _moves[3] == &"jab", "the press after the whiff is a jab (%s)" % [_moves])
	await _idle()
	var wait := Tuning.R7_CHAIN_GRACE + 0.15
	await wait_real(wait)
	check(_p.combat.get_chain_count() == 0 and _p.combat.get_string_index() == 0,
		"%.2f s after the recovery the chain has dropped, the string is back at the jab" % wait)
	place_in_front(_p, g2, 1.2)
	await ticks(4)
	await _press_in_chain(false)
	check(_moves.size() == 5 and _moves[4] == &"jab", "the press after a dropped chain is a jab, not a cross (%s)" % [_moves])
	release_inputs()
	done()

## A player-team fighter with no PlayerController (press()/release() directly), out of the way.
func spawn_dummy_player() -> Fighter:
	return spawn(&"player", _p.global_position + Vector3(30, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)

## Wait until the player is free (move over).
func _idle() -> void:
	await wait_until(func() -> bool: return not _p.combat.is_attacking() and _p.can_act(), 3.0)

## Wait until the player is free and its chain has dropped.
func _fresh_chain() -> void:
	await _idle()
	await wait_until(func() -> bool: return _p.combat.get_chain_count() == 0, 2.0)
	await ticks(2)

## One LMB press at the next moment it counts: during the current move's
## recovery (buffered) or once free. Waits for the move's first active frame.
func _press_in_chain(hold: bool) -> void:
	await wait_until(func() -> bool: return _p.combat.is_in_recovery() or not _p.combat.is_attacking(), 3.0)
	var n := _moves.size()
	Input.action_press(&"punch")
	await wait_real(HOLD if hold else PRESS)
	Input.action_release(&"punch")
	await wait_until(func() -> bool: return _moves.size() > n, 2.0)
	await ticks(1)


## Press LMB from idle; returns the real time the move started (attack_started).
func _press_timed(hold: bool) -> float:
	var at := [INF]
	var cb := func(_id: StringName) -> void: at[0] = minf(at[0], TimeDirector.now())
	_p.combat.attack_started.connect(cb)
	Input.action_press(&"punch")
	await wait_real(HOLD if hold else PRESS)
	Input.action_release(&"punch")
	await wait_until(func() -> bool: return _p.combat.is_attack_active() or not _p.combat.is_attacking(), 1.0)
	_p.combat.attack_started.disconnect(cb)
	return at[0]
