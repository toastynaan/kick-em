extends Node
## Round 8 AI against B's real pressure meter (docs/Round 8 — Charge and
## Pressure.md: Pressure, Acceptance 5 and 6): the player's real jab taps
## (CombatController press / release: B's tap, flinch, guard and pressure
## pipeline) on real grunts (FighterFactory.spawn_enemy, real AIBrain).
## A. Level 1 (capacity 2.5): after every tap that lands or is guarded, the
##    brain's p is B's get_pressure_fraction() and its guard chance is
##    Tuning.GUARD_TAP_CHANCE x (1 - p). The 3rd tap breaks it open: through
##    the break no attack, no token, no guard, no walking; after
##    GameEvents.pressure_recovered it attacks again within RESUME_LIMIT s.
## B. Level 2 (capacity 5): taps until p >= Tuning.R8_PRESSURE_BACK_OFF; then
##    it backs off (within BACKOFF_START s, at least BACKOFF_MIN m), attacks
##    nothing while backing off, and once B's meter drains under the line it
##    re-engages and attacks within REENGAGE_LIMIT s.
## Round 9: with Tuning.R9_BROKEN_STUN false A only checks no block through
## the break; B runs only with Tuning.R9_PRESSURE_PASSIVE.
## Measured numbers are printed. OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const TAP_GAP := 0.45          ## s between the player's taps (a jab tap takes 24 frames)
const RESUME_LIMIT := 4.0
const BACKOFF_START := 2.0     ## s after the line is crossed (a swing about to land goes first)
const BACKOFF_MIN := 1.0       ## m
const REENGAGE_LIMIT := 5.0

var failures := 0
var player: Fighter
var events: Array = []         ## [time, "landed" | "blocked", react, pressure added]
var broke_at := {}             ## Fighter -> time of its GameEvents.pressure_broken

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	AIBrain.test_seed = 31
	Tuning.difficulty = Tuning.Difficulty.NORMAL
	Tuning.debug_pressure_mult = 1.0
	AttackDirector.camera_busy = false
	Util.build_floor(self)
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	GameEvents.hit_landed.connect(func(i: HitInfo) -> void:
		if i.attacker == player: events.append([Util.game_now(), "landed", i.react, i.pressure]))
	GameEvents.hit_blocked.connect(func(i: HitInfo) -> void:
		if i.attacker == player: events.append([Util.game_now(), "blocked", i.react, i.pressure]))
	GameEvents.pressure_broken.connect(func(f: Node3D, _a: Node3D) -> void: broke_at[f] = Util.game_now())
	await _wait(0.3)
	await _part_break()
	if Tuning.R9_PRESSURE_PASSIVE:
		await _part_back_off()
	else:
		print("[ai] info: Tuning.R9_PRESSURE_PASSIVE false: Round 8 back-off part B skipped")
	_finish()

func _grunt(level: int, pos: Vector3) -> Fighter:
	var g := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis.looking_at(-pos.normalized(), Vector3.UP), pos))
	g.level = level
	return g

## One real jab tap at `g`; returns [kind ("landed" / "blocked" / ""), react, pressure added].
func _tap(g: Fighter) -> Array:
	_face(player, g)
	events.clear()
	player.combat.press(CombatController.Action.LIGHT)
	await _ticks(2)
	player.combat.release(CombatController.Action.LIGHT)
	await _until(func() -> bool: return not events.is_empty(), 0.6)
	var out: Array = ["", &"", 0.0] if events.is_empty() else [events[0][1], events[0][2], events[0][3]]
	await _until(func() -> bool: return not player.combat.is_attacking(), 0.6)
	return out

# --- A. Level 1: the 3rd tap breaks it ------------------------------------------------------------

func _part_break() -> void:
	var g := _grunt(1, Vector3(0, 0.05, -1.3))
	var gb := g.brain as AIBrain
	await _wait(0.6)
	var cap := g.combat.get_pressure_max()
	var rows: Array[String] = []
	var mismatch := 0
	var guard_bad := 0
	var counted := 0
	var tries := 0
	var broke_on := -1
	while broke_on < 0 and tries < 12:
		tries += 1
		await _until(func() -> bool: return Util.flat_dist(g.get_ground_position(), player.get_ground_position()) < 2.5, 2.0)
		var r := await _tap(g)
		if r[0] == "":
			await _wait(TAP_GAP - 0.2)
			continue
		counted += 1
		await _ticks(1)
		var b_p := g.combat.get_pressure_fraction()
		var a_p := gb.get_pressure()
		var want_guard := 0.0 if g.combat.is_broken() else Tuning.GUARD_TAP_CHANCE * (1.0 - b_p)
		mismatch += 1 if absf(b_p - a_p) > 1e-4 else 0
		guard_bad += 1 if absf(gb.get_guard_chance() - want_guard) > 1e-4 else 0
		rows.append("%d %s %s +%.1f: p %.2f (brain %.2f), guard %.3f%s" % [counted, r[0], r[1], r[2], b_p, a_p, gb.get_guard_chance(),
			" BROKEN" if g.combat.is_broken() else ""])
		if g.combat.is_broken():
			broke_on = counted
			break
		await _wait(TAP_GAP - 0.2)
	print("[ai] info: level-1 grunt (capacity %.1f), real taps: %s" % [cap, "; ".join(rows)])
	check(mismatch == 0 and guard_bad == 0, "the brain reads B's pressure (%d mismatches) and guards %.2f x (1 - p) (%d off)" % [
		mismatch, Tuning.GUARD_TAP_CHANCE, guard_bad])
	check(broke_on == 3, "a level-1 grunt breaks on the 3rd tap (%d)" % broke_on)
	if broke_on < 0:
		AttackDirector.unregister_enemy(g)
		g.queue_free()
		return
	# Through the break.
	var a0 := gb.attacks_started
	var recovered := [false]
	var on_rec := func(f: Node3D) -> void:
		if f == g: recovered[0] = true
	GameEvents.pressure_recovered.connect(on_rec)
	var t0: float = broke_at.get(g, Util.game_now())
	var react0 := g.get_react_state()
	var react0_at := Util.game_now() - t0
	var ticks := 0
	var token_ticks := 0
	var block_ticks := 0
	var walk_ticks := 0
	var aware := 0
	while not recovered[0] and Util.game_now() - t0 < Tuning.R8_BREAK_TIME + 1.0:
		_keep_player()
		await get_tree().physics_frame
		if recovered[0]:
			break
		ticks += 1
		token_ticks += 1 if ticks > 1 and AttackDirector.has_token(g) else 0
		block_ticks += 1 if g.combat.is_blocking() else 0
		walk_ticks += 1 if Vector2(g.move_input.x, g.move_input.z).length() > 0.01 else 0
		aware += 1 if gb.is_broken() else 0
	var t_rec := Util.game_now()
	var starts := gb.attacks_started - a0
	print("[ai] info: broken %.2f s (react %s %.2f s in): brain saw it %d / %d ticks, starts %d, token ticks %d, block ticks %d, walking ticks %d, pressure_broken seen %d" % [
		t_rec - t0, react0, react0_at, aware, ticks, starts, token_ticks, block_ticks, walk_ticks, gb.pressure_breaks])
	check(recovered[0] and absf((t_rec - t0) - Tuning.R8_BREAK_TIME) <= 0.15, "the break lasts %.2f s (%.1f s)" % [t_rec - t0, Tuning.R8_BREAK_TIME])
	check(aware == ticks and gb.pressure_breaks == 1, "the brain knows it is broken every tick (%d / %d) and saw pressure_broken (%d)" % [
		aware, ticks, gb.pressure_breaks])
	if Tuning.R9_BROKEN_STUN:
		check(starts == 0 and token_ticks == 0 and block_ticks == 0 and walk_ticks == 0,
			"broken: no attack (%d), no token (%d), no block (%d), no walking (%d)" % [starts, token_ticks, block_ticks, walk_ticks])
	else:
		check(block_ticks == 0, "broken (Round 9: guard broken): no block (%d ticks); it may act (starts %d, walking %d)" % [
			block_ticks, starts, walk_ticks])
	GameEvents.pressure_recovered.disconnect(on_rec)
	var back := await _until(func() -> bool: return gb.attacks_started > a0, RESUME_LIMIT)
	check(back, "after the break it attacks again (%.2f s after pressure_recovered)" % (Util.game_now() - t_rec))
	AttackDirector.unregister_enemy(g)
	g.queue_free()
	await _wait(0.3)

# --- B. Level 2: backs off at the line, re-engages as B's meter drains --------------------------------

func _part_back_off() -> void:
	var g := _grunt(2, Vector3(0, 0.05, -1.3))
	var gb := g.brain as AIBrain
	await _wait(0.6)
	var line := Tuning.R8_PRESSURE_BACK_OFF
	var rows: Array[String] = []
	var tries := 0
	while g.combat.get_pressure_fraction() < line - 1e-4 and tries < 12:
		tries += 1
		await _until(func() -> bool: return Util.flat_dist(g.get_ground_position(), player.get_ground_position()) < 2.5, 2.0)
		var r := await _tap(g)
		if r[0] != "":
			rows.append("%s %s p %.2f" % [r[0], r[1], g.combat.get_pressure_fraction()])
		await _wait(TAP_GAP - 0.2)
	var p_top := g.combat.get_pressure_fraction()
	print("[ai] info: level-2 grunt (capacity %.1f), real taps: %s" % [g.combat.get_pressure_max(), "; ".join(rows)])
	check(p_top >= line - 1e-4 and not g.combat.is_broken(), "taps raised its pressure to %.2f (>= %.1f, not broken)" % [p_top, line])
	var t0 := Util.game_now()
	var a0 := gb.attacks_started
	var d0 := Util.flat_dist(g.get_ground_position(), player.get_ground_position())
	var started := await _until(func() -> bool: return gb.is_backing_off(), BACKOFF_START)
	var t_start := Util.game_now() - t0
	var starts_before := gb.attacks_started - a0
	var a1 := gb.attacks_started
	var max_d := d0
	var t_line := -1.0
	var t_end := -1.0
	var bad_starts := 0
	while started and Util.game_now() - t0 < 8.0:
		_keep_player()
		await get_tree().physics_frame
		max_d = maxf(max_d, Util.flat_dist(g.get_ground_position(), player.get_ground_position()))
		if t_line < 0.0 and g.combat.get_pressure_fraction() < line:
			t_line = Util.game_now()
		if gb.is_backing_off() and gb.attacks_started > a1:
			bad_starts += 1
			a1 = gb.attacks_started
		if not gb.is_backing_off():
			t_end = Util.game_now()
			break
	var a2 := gb.attacks_started
	var back := t_end >= 0.0 and await _until(func() -> bool: return gb.attacks_started > a2, REENGAGE_LIMIT)
	var t_back := Util.game_now()
	print("[ai] info: at p %.2f: backs off %.2f s after the last tap (%d swing(s) first), from %.1f m to %.1f m; B's meter under %.1f at +%.2f s, back-off over at +%.2f s, attacks again %.2f s later" % [
		p_top, t_start, starts_before, d0, max_d, line, t_line - t0, t_end - t0, t_back - t_end])
	check(started, "at p >= %.1f it backs off (%.2f s after the last tap)" % [line, t_start])
	check(max_d >= d0 + BACKOFF_MIN, "it backs off %.1f m (from %.1f m to %.1f m)" % [max_d - d0, d0, max_d])
	check(bad_starts == 0, "no attack while backing off (%d)" % bad_starts)
	check(t_end >= 0.0 and t_line >= 0.0 and t_end - t_line <= 0.05, "the back-off ends as B's meter drains under the line (%.3f s after)" % (t_end - t_line))
	check(back, "it re-engages and attacks again (%.2f s after the back-off)" % (t_back - t_end))
	AttackDirector.unregister_enemy(g)
	g.queue_free()

# --- Helpers ----------------------------------------------------------------------------------------------

func _face(a: Fighter, b: Fighter) -> void:
	var to := b.get_ground_position() - a.get_ground_position()
	to.y = 0.0
	if to.length() > 0.01:
		a.snap_facing(to)
		a.face_dir = to.normalized()

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
	print("[ai] test_pressure_real: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
