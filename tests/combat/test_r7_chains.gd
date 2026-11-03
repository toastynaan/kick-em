extends "res://tests/combat/combat_test_base.gd"
## Round 7 acceptance check 2 (docs/Round 7 — Freeflow Combat.md: Chains and
## the input buffer), through the real input path (Input.action_press ->
## PlayerController -> InputInterpreter -> CombatController):
## - presses during a move's glide and startup are dropped; from its first
##   active frame on (hitstop and recovery included) the latest press is
##   buffered (one press only); still held when it starts, it charges (Round 8);
## - on a hit the buffered press starts after R7_CHAIN_CUT of the recovery; on a
##   whiff only after the full recovery, and the punch string resets;
## - mashing LMB at 20 Hz never makes a 3-hit string faster than pressing once
##   per move at the right moment (nor faster than its frame data);
## - the chain: chain_hit counts 1, 2, 3 (get_chain_count matches), it survives
##   R7_CHAIN_GRACE after the recovery, then chain_ended reports its length.

const SLACK := 1.0 / 120.0 + 0.002  ## one physics tick

var _p: Fighter
var _moves: Array = []   ## [move id, real time of attack_active]
var _starts: Array = []  ## [move id, real time of attack_started]
var _rec: Array = []     ## real times the player entered recovery
var _x := 0.0

func _init() -> void:
	_timeout = 150.0

func run() -> void:
	_p = spawn_player(Vector3.ZERO)
	_p.combat.attack_active.connect(func(id: StringName) -> void:
		_moves.append([id, TimeDirector.now(), _p.combat.get_strike_debug()["charged"]]))
	_p.combat.attack_started.connect(func(id: StringName) -> void: _starts.append([id, TimeDirector.now()]))
	await ticks(20)

	print("a press in the startup is dropped; one in the active frames is buffered")
	await _idle()
	_clear()
	await tap_input(&"front_kick")
	await wait_real(0.06)
	var in_startup := _p.combat.is_attacking() and not _p.combat.is_attack_active() and not _p.combat.is_in_recovery()
	await tap_input(&"gut_punch")       # startup: dropped
	await wait_until(func() -> bool: return _p.combat.is_attack_active(), 1.0)
	Input.action_press(&"roundhouse")     # active frames: buffered
	await ticks(1)
	Input.action_release(&"roundhouse")
	var active_still := _p.combat.is_attack_active()
	await wait_until(func() -> bool: return _p.combat.is_in_recovery(), 1.0)
	var rec_t := TimeDirector.now()
	await wait_until(func() -> bool: return _moves.size() >= 2, 1.5)
	var ids := _moves.map(func(m: Array) -> StringName: return m[0])
	var rh := _start_of(&"roundhouse")
	print("  moves %s; the roundhouse started %.3f s after the whiff's recovery began (full recovery %.3f)" % [ids,
		rh - rec_t, Tuning.frames(Tuning.R8_MOVES[&"front_kick"]["tap"]["f"].z)])
	check(in_startup and active_still, "the gut punch fell in the startup, the roundhouse in the active frames")
	check(ids == [&"front_kick", &"roundhouse"], "the startup press was dropped, the active-frame press came out")
	check(absf(rh - rec_t - Tuning.frames(Tuning.R8_MOVES[&"front_kick"]["tap"]["f"].z)) <= SLACK * 2.0,
		"on a whiff the buffered press waits for the full recovery")
	await _idle()

	print("one press only: the latest of the active frames and the recovery wins")
	_clear()
	await tap_input(&"front_kick")
	await wait_until(func() -> bool: return _p.combat.is_attack_active(), 1.0)
	await tap_input(&"roundhouse", 0.02)  # active
	await wait_until(func() -> bool: return _p.combat.is_in_recovery(), 1.0)
	await tap_input(&"uppercut")        # recovery: replaces it...
	await tap_input(&"leg_kick")        # ...and this replaces that
	await _idle()
	await wait_real(0.1)
	ids = _moves.map(func(m: Array) -> StringName: return m[0])
	print("  moves %s" % [ids])
	check(ids == [&"front_kick", &"leg_kick"], "only the latest press (leg kick) came out")

	print("a buffered press still held when its move starts charges (Round 8)")
	await _idle()
	_clear()
	await tap_input(&"front_kick")
	await wait_until(func() -> bool: return _p.combat.is_attack_active(), 1.0)
	Input.action_press(&"leg_kick")       # active frames, held through the recovery
	var charging := await wait_until(func() -> bool: return _p.combat.is_charging(), 1.5)
	var charge_move := _p.combat.get_charge_move()
	Input.action_release(&"leg_kick")
	await wait_until(func() -> bool: return _moves.size() >= 2, 1.0)
	ids = _moves.map(func(m: Array) -> StringName: return m[0])
	check(charging and charge_move == &"leg_kick" and ids.size() == 2 and ids[1] == &"leg_kick" and bool(_moves[1][2]),
		"held: the buffered leg kick charges, then comes out charged (%s)" % [_moves])
	await _idle()

	print("a press during a glide is dropped")
	var gg := await _grunt(4.0)
	await _fresh()
	_clear()
	await tap_input(&"punch")
	await ticks(1)  # Round 8: a held press glides once it turns out a tap (its release)
	var glid := _p.combat.is_gliding()
	await tap_input(&"uppercut", 0.03)  # still gliding: dropped
	var still_gliding := _p.combat.is_gliding()
	await _idle()
	await wait_real(0.1)
	ids = _moves.map(func(m: Array) -> StringName: return m[0])
	check(glid and still_gliding and ids == [&"jab"], "the press during the glide was dropped (%s)" % [ids])
	gg.queue_free()

	print("chain cut on a hit only")
	var g := await _grunt()
	await _fresh()
	_clear()
	await tap_input(&"punch")
	await wait_until(func() -> bool: return _p.combat.is_in_recovery(), 1.0)
	var r_hit := TimeDirector.now()
	await tap_input(&"punch")
	await wait_until(func() -> bool: return _starts.size() >= 2, 1.0)
	var cross_after := _start_of(&"cross") - r_hit
	var cut := Tuning.frames(Tuning.R8_MOVES[&"jab"]["tap"]["f"].z * Tuning.R7_CHAIN_CUT)
	print("  jab hit: the buffered cross started %.3f s into the recovery (cut %.3f, full %.3f)" % [cross_after, cut,
		Tuning.frames(Tuning.R8_MOVES[&"jab"]["tap"]["f"].z)])
	check(hits_on(g).size() >= 1 and absf(cross_after - cut) <= SLACK * 2.0, "on a hit the next move starts after %.0f%% of the recovery" % (Tuning.R7_CHAIN_CUT * 100.0))
	g.queue_free()
	await _fresh()
	_clear()
	await tap_input(&"punch")  # nothing in reach: a whiff
	await wait_until(func() -> bool: return _p.combat.is_in_recovery(), 1.0)
	var r_miss := TimeDirector.now()
	await tap_input(&"punch")
	await wait_until(func() -> bool: return _starts.size() >= 2, 1.0)
	var next_after: float = _starts[1][1] - r_miss
	var full := Tuning.frames(Tuning.R8_MOVES[&"jab"]["tap"]["f"].z)
	print("  jab whiff: the next press started %.3f s into the recovery (full %.3f) as a %s" % [next_after, full, _starts[1][0]])
	check(absf(next_after - full) <= SLACK * 2.0, "on a whiff it waits for the full recovery")
	check(_starts[1][0] == &"jab", "and the string reset: the press after the whiffed jab is a jab, not a cross")

	print("the chain: chain_hit 1, 2, 3, grace, chain_ended")
	await _idle()
	g = await _grunt()
	await _fresh()
	clear_events()
	_clear()
	var counts: Array[int] = []
	for i in 3:
		await _press_when_ready()
		await wait_until(func() -> bool: return hits_on(g).size() > i, 1.0)
		counts.append(_p.combat.get_chain_count())
	var hit_counts := events.filter(func(e: Array) -> bool: return e[0] == &"chain_hit").map(func(e: Array) -> int: return e[4])
	print("  chain_hit counts %s, get_chain_count after each hit %s, string index next %d" % [hit_counts, counts,
		_p.combat.get_string_index()])
	check(hit_counts == [1, 2, 3] and Array(counts) == [1, 2, 3], "chain_hit counts 1, 2, 3 and get_chain_count matches")
	check(_p.combat.get_string_index() == 0, "after the hook the string wraps to the jab")
	await _idle()
	var idle_t := TimeDirector.now()
	await wait_until(func() -> bool: return count_events(&"chain_ended") > 0, 1.0)
	var ended := last_event(&"chain_ended")
	var after := TimeDirector.now() - idle_t
	print("  chain_ended %.3f s after the hook's recovery (grace %.2f), count %s" % [after, Tuning.R7_CHAIN_GRACE,
		ended[2] if not ended.is_empty() else -1])
	check(not ended.is_empty() and ended[1] == _p and int(ended[2]) == 3 and absf(after - Tuning.R7_CHAIN_GRACE) <= 0.03,
		"the chain survives R7_CHAIN_GRACE, then chain_ended reports 3")
	check(_p.combat.get_chain_count() == 0 and _p.combat.get_string_index() == 0, "the chain and the string are reset")
	g.queue_free()

	print("mashing at 20 Hz never shortens a 3-hit string")
	var ideal := await _string_time(false)
	var mash := await _string_time(true)
	var theory := 0.0
	for id: StringName in [&"jab", &"cross"]:
		var f: Vector3 = Tuning.R8_MOVES[id]["tap"]["f"]
		theory += Tuning.frames(f.x + f.y + f.z * Tuning.R7_CHAIN_CUT) + float(Tuning.R8_MOVES[id]["tap"]["hitstop"])
	theory += Tuning.frames(Tuning.R8_MOVES[&"hook"]["tap"]["f"].x)
	print("DATA first press -> the hook's first active frame: one press per move %.3f s, mashing at 20 Hz %.3f s, frame data %.3f s" % [
		ideal, mash, theory])
	check(ideal > 0.0 and mash > 0.0, "both strings landed three hits")
	check(mash >= ideal - SLACK, "mashing (%.3f s) is never faster than pressing once per move (%.3f s)" % [mash, ideal])
	# 120 Hz ticks: the press tick counts as the first startup tick, and each
	# hitstop ends on a tick boundary (up to one tick either way).
	check(mash >= theory - SLACK * 3.0 and ideal >= theory - SLACK * 3.0,
		"neither beats the frame data (%.3f s, three ticks of rounding)" % theory)
	release_inputs()
	done()

func _clear() -> void:
	_moves.clear()
	_starts.clear()

func _start_of(id: StringName) -> float:
	for s: Array in _starts:
		if s[0] == id:
			return s[1]
	return INF

func _idle() -> void:
	await wait_until(func() -> bool: return not _p.combat.is_attacking() and _p.can_act(), 3.0)

## Idle, and the chain dropped (a fresh string).
func _fresh() -> void:
	await _idle()
	await wait_until(func() -> bool: return _p.combat.get_chain_count() == 0, 2.0)
	await ticks(2)

## A grunt dummy `dist` m in front of the player, the player moved to fresh ground.
func _grunt(dist := 1.1) -> Fighter:
	_x += 10.0
	_p.teleport_to(Vector3(_x, 0, 0), Vector3.FORWARD)
	var g := spawn(&"grunt", Vector3(_x, 0, -dist), Vector3.BACK)
	await ticks(15)
	return g

## One LMB tap as soon as it counts (recovery or idle).
func _press_when_ready() -> void:
	await wait_until(func() -> bool: return _p.combat.is_in_recovery() or not _p.combat.is_attacking(), 3.0)
	var n := _moves.size()
	await tap_input(&"punch", 0.03)
	await wait_until(func() -> bool: return _moves.size() > n, 2.0)

## Seconds from the first LMB press to the hook's first active frame on a fresh
## grunt: one press per move (when it counts), or LMB mashed at 20 Hz.
func _string_time(mash: bool) -> float:
	await _fresh()
	var g := await _grunt()
	_clear()
	clear_events()
	var t0 := TimeDirector.now()
	if mash:
		while TimeDirector.now() - t0 < 3.0 and _moves.size() < 3:
			Input.action_press(&"punch")
			await wait_real(0.025)
			Input.action_release(&"punch")
			await wait_real(0.025)
	else:
		for i in 3:
			await _press_when_ready()
	await wait_until(func() -> bool: return _moves.size() >= 3, 2.0)
	release_inputs()
	var ok: bool = _moves.size() >= 3 and _moves[2][0] == &"hook" and hits_on(g).size() >= 2
	var first: float = _starts[0][1] if not _starts.is_empty() else t0
	print("  %s: %s, %d hits" % ["mash" if mash else "one press per move",
		_moves.map(func(m: Array) -> String: return "%s@%.3f" % [m[0], float(m[1]) - first]), hits_on(g).size()])
	await _idle()
	g.queue_free()
	return float(_moves[2][1]) - first if ok else -1.0
