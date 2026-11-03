extends Node
## Round 8: a broken enemy does nothing (docs/Round 8 — Charge and Pressure.md:
## Pressure "Full: broken open ... They can't block or attack"; Acceptance 5:
## the break lasts 1.5 s with no enemy attack or block). Enemies have their
## real AIBrain; the break comes from test doubles while B's and H's code is
## in progress: FakeCombat.fake_broken (B's is_broken) or the FakeFighter's
## react state &"broken" (H's reaction), plus GameEvents.pressure_broken /
## pressure_recovered as B emits them.
## A. A grunt mid-turn with its tap guard up breaks (B's is_broken): the guard
##    drops; for Tuning.R8_BREAK_TIME no attack, no token (after one tick), no
##    token request, no tap guard against the tapped punches aimed at it (one
##    every TAP_EVERY s), no block held, no walking, no grab break, out of the
##    line. After pressure_recovered it attacks again within RESUME_LIMIT s.
## B. The same with H's &"broken" reaction state instead.
## C. Broken during its wind-up (B cancels the move): the token goes back
##    and nothing starts until it recovers.
## D. The Duelist (reads forced on) with his read guard up breaks: the guard
##    drops, no read and no answer through the break; he fights after it.
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const FakeCombat := preload("res://tests/ai/fake_combat.gd")
const RESUME_LIMIT := 4.0   ## s after pressure_recovered in which it must attack again
const TAP_EVERY := 0.1      ## s between the tapped punches aimed at it while broken

var failures := 0
var player: Fighter

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	AIBrain.test_seed = 515
	Tuning.difficulty = Tuning.Difficulty.NORMAL
	AttackDirector.camera_busy = false
	Util.build_floor(self)
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	await _wait(0.3)
	await _part_turn(&"is_broken")
	await _part_turn(&"react")
	await _part_windup()
	await _part_duelist()
	_finish()

## Force or clear the break on `e` the way `how` says (B's flag or H's state).
func _set_broken(e: Fighter, on: bool, how: StringName) -> void:
	var fc := e.combat as FakeCombat
	if how == &"react":
		e.set(&"fake_react_state", &"broken" if on else &"snap")
		e.set(&"fake_reacting", on)
	else:
		fc.fake_broken = on
	if on:
		GameEvents.pressure_broken.emit(e, player)
	else:
		GameEvents.pressure_recovered.emit(e)

# --- A / B. Broken mid-turn -------------------------------------------------------------------

func _part_turn(how: StringName) -> void:
	var g := Util.spawn_pressure_enemy(self, &"grunt", Vector3(0, 0.05, -2.5), Vector3.BACK)
	var gb := g.brain as AIBrain
	await _wait(0.3)
	var turn := await _until(func() -> bool: return AttackDirector.has_token(g) and not g.combat.is_attacking(), 6.0)
	check(turn, "%s: grunt mid-turn (token, not yet swinging)" % how)
	gb._tap_guard(player)
	await _ticks(1)
	var guard_before := g.combat.is_blocking()
	var r := await _watch_break(g, func() -> void: _set_broken(g, true, how))
	print("[ai] info: %s: broken %.2f s: starts %d, token ticks %d, requests %d, tap guards %d of %d taps, block ticks %d, walking ticks %d, in line %d ticks, grab break chance %.2f, guard chance %.2f" % [
		how, r.time, r.starts, r.token_ticks, r.requests, r.guards, r.taps, r.block_ticks, r.walk_ticks, r.line_ticks,
		r.grab_break, r.guard_chance])
	check(guard_before and r.block_ticks == 0, "%s: a raised guard drops at the break and stays down (up before %s, %d ticks up)" % [
		how, guard_before, r.block_ticks])
	check(r.starts == 0 and r.token_ticks == 0 and r.requests == 0,
		"%s: no attack (%d), no token (%d ticks), no request (%d) for %.1f s" % [how, r.starts, r.token_ticks, r.requests, r.time])
	check(r.guards == 0 and r.guard_chance == 0.0, "%s: no tap guard against %d tapped punches (%d; chance %.2f)" % [
		how, r.taps, r.guards, r.guard_chance])
	check(r.walk_ticks == 0 and r.line_ticks == 0, "%s: stands dazed (walking %d ticks), out of the line (%d ticks)" % [
		how, r.walk_ticks, r.line_ticks])
	check(r.grab_break == 0.0, "%s: no grab break while broken (%.2f)" % [how, r.grab_break])
	_set_broken(g, false, how)
	var t0 := Util.game_now()
	var a0 := gb.attacks_started
	var back := await _until(func() -> bool: return gb.attacks_started > a0, RESUME_LIMIT)
	check(back, "%s: after pressure_recovered it attacks again (%.2f s)" % [how, Util.game_now() - t0])
	AttackDirector.unregister_enemy(g)
	g.queue_free()
	await _wait(0.2)

## Break `e` with `do_break`, then watch it for Tuning.R8_BREAK_TIME while
## tapped punches come in.
func _watch_break(e: Fighter, do_break: Callable) -> Dictionary:
	var b := e.brain as AIBrain
	var out := {"time": 0.0, "starts": 0, "token_ticks": 0, "requests": 0, "guards": 0, "taps": 0,
		"block_ticks": 0, "walk_ticks": 0, "line_ticks": 0, "grab_break": 0.0, "guard_chance": 0.0}
	var a0 := b.attacks_started
	var g0 := b.tap_guards
	do_break.call()
	var req0: float = AttackDirector._last_request.get(e, -INF)
	var t0 := Util.game_now()
	var next_tap := t0
	var ticks := 0
	while Util.game_now() - t0 < Tuning.R8_BREAK_TIME:
		if Util.game_now() >= next_tap:
			next_tap += TAP_EVERY
			out["taps"] += 1
			GameEvents.strike_started.emit(player, e, &"jab", false, 0)
		_keep_player()
		await get_tree().physics_frame
		ticks += 1
		if ticks > 1 and AttackDirector.has_token(e):
			out["token_ticks"] += 1
		if float(AttackDirector._last_request.get(e, -INF)) != req0:
			out["requests"] += 1
			req0 = AttackDirector._last_request.get(e, -INF)
		if e.combat.is_blocking():
			out["block_ticks"] += 1
		if Vector2(e.move_input.x, e.move_input.z).length() > 0.01:
			out["walk_ticks"] += 1
		if e in AttackDirector._line:
			out["line_ticks"] += 1
		out["grab_break"] = maxf(out["grab_break"], b.grab_break_chance())
		out["guard_chance"] = maxf(out["guard_chance"], b.get_guard_chance())
	out["time"] = Util.game_now() - t0
	out["starts"] = b.attacks_started - a0
	out["guards"] = b.tap_guards - g0
	return out

# --- C. Broken during the wind-up ----------------------------------------------------------------

func _part_windup() -> void:
	var g := Util.spawn_pressure_enemy(self, &"grunt", Vector3(0, 0.05, -1.3), Vector3.BACK)
	var gb := g.brain as AIBrain
	await _wait(0.3)
	var winding := await _until(func() -> bool: return g.combat.is_attacking() and not g.combat.is_attack_active() \
		and AttackDirector.has_token(g), 6.0)
	check(winding, "a grunt winding up")
	var fc := g.combat as FakeCombat
	var r := await _watch_break(g, func() -> void:
		fc.fake_broken = true
		g.combat.cancel()  # B: the break's reaction cancels the move
		GameEvents.pressure_broken.emit(g, player))
	print("[ai] info: broken in its wind-up: starts %d, token ticks %d, requests %d" % [r.starts, r.token_ticks, r.requests])
	check(r.starts == 0 and r.token_ticks == 0 and r.requests == 0,
		"broken in its wind-up: the token goes back, nothing starts (starts %d, token ticks %d, requests %d)" % [
			r.starts, r.token_ticks, r.requests])
	_set_broken(g, false, &"is_broken")
	var a0 := gb.attacks_started
	check(await _until(func() -> bool: return gb.attacks_started > a0, RESUME_LIMIT), "and attacks again after it recovers")
	AttackDirector.unregister_enemy(g)
	g.queue_free()
	await _wait(0.2)

# --- D. The Duelist --------------------------------------------------------------------------------

func _part_duelist() -> void:
	var d := Util.spawn_pressure_enemy(self, &"duelist", Vector3(0, 0.05, -2.0), Vector3.BACK)
	var db := d.brain as AIBrain
	db.read_chance_override = 1.0
	player.snap_facing(Vector3.FORWARD)
	await _wait(0.3)
	await _until(func() -> bool: return not d.combat.is_attacking(), 4.0)
	player.combat.attack_incoming.emit(&"jab", 0.3)
	await _ticks(1)
	var up := d.combat.is_blocking()
	db._on_guard_broken()  # a guard break waiting for its answer
	var r0 := db.guard_reads
	var a0 := db.attacks_started
	var blocked := 0
	var answer := 0
	var dfc := d.combat as FakeCombat
	dfc.fake_broken = true
	GameEvents.pressure_broken.emit(d, player)
	var t0 := Util.game_now()
	var next_read := t0
	while Util.game_now() - t0 < Tuning.R8_BREAK_TIME:
		if Util.game_now() >= next_read:
			next_read += 0.2
			player.combat.attack_incoming.emit(&"jab", 0.3)
		_keep_player()
		await get_tree().physics_frame
		blocked += 1 if d.combat.is_blocking() else 0
		answer += 1 if db._answer_pending else 0
	var reads := db.guard_reads - r0
	var starts := db.attacks_started - a0
	print("[ai] info: Duelist broken: guard up before %s, reads %d, block ticks %d, answer pending ticks %d, starts %d" % [
		up, reads, blocked, answer, starts])
	check(up and blocked == 0 and reads == 0, "Duelist: the read guard drops at the break; no read, no block through it (%d reads, %d ticks)" % [
		reads, blocked])
	check(answer == 0 and starts == 0, "Duelist: no answer and no attack while broken (%d, %d)" % [answer, starts])
	_set_broken(d, false, &"is_broken")
	db.read_chance_override = -1.0
	check(await _until(func() -> bool: return db.attacks_started > a0, RESUME_LIMIT + 2.0), "Duelist: fights again after it recovers")
	AttackDirector.unregister_enemy(d)
	d.queue_free()

# --- Helpers ---------------------------------------------------------------------------------------

func _until(cond: Callable, limit: float) -> bool:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < limit:
		if cond.call():
			return true
		_keep_player()
		await get_tree().physics_frame
	return bool(cond.call())

func _keep_player() -> void:
	player.set(&"invuln_until", TimeDirector.now() + 5.0)
	if player.hp < player.max_hp * 0.5:
		player.heal_fraction(1.0)

func _ticks(n: int) -> void:
	for i in n:
		_keep_player()
		await get_tree().physics_frame

func _wait(s: float) -> void:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < s:
		_keep_player()
		await get_tree().physics_frame

func _finish() -> void:
	AttackDirector.reset()
	AIBrain.test_seed = -1
	print("[ai] test_broken: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
