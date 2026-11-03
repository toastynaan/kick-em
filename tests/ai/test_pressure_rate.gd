extends Node
## Round 8 attack rate, tells and backing off under pressure (docs/Round 8 —
## Charge and Pressure.md: Pressure, Acceptance 6). Pressure comes from the
## FakeCombat double (fake_pressure for B's get_pressure_fraction), on a lone
## grunt with its real AIBrain at an open, invulnerable player.
## A. Scripted runs of RATE_RUN s at p = 0, 0.5 and 0.9: attacks per minute,
##    the gap from a turn's last attack to the next turn's first (the brain's
##    interval x (1 + p): never under LONE_INTERVAL.x x (1 + p)), and tell
##    lengths (+Tuning.R8_PRESSURE_TELL_SLOW x p, never under the tell floor).
##    At 0.9 it backs off: no attack in BACKED_RUN s, and it moves away.
## B. Backing off: a token holder still closing in when p reaches 0.7 gives
##    its token back at once, backs off at least BACKOFF_MIN m (never past
##    AIBrain.BACK_OFF_MAX_RADIUS + slack), asks for no token and starts no
##    attack. The pressure then drains like B's meter (Tuning.R8_PRESSURE_DECAY_DELAY,
##    then Tuning.R8_PRESSURE_DECAY of max per s): the back-off ends the tick p
##    drops under Tuning.R8_PRESSURE_BACK_OFF and it attacks again within
##    REENGAGE_LIMIT s.
## C. About to swing: a holder in its move's range (held there by a pause)
##    when p reaches 0.7 keeps its token, swings its turn, then backs off.
## D. No drain (pressure stuck at 0.7): the back-off still ends after
##    AIBrain.BACK_OFF_MAX_TIME and it attacks; a new hit (p up) backs it off again.
## Measured numbers are printed. OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const FakeCombat := preload("res://tests/ai/fake_combat.gd")
const RATE_RUN := 40.0           ## s per pressure in A (0.9: BACKED_RUN)
## s of the p 0.9 run: inside AIBrain.BACK_OFF_MAX_TIME (a pressure held there
## with no drain at all is D's case; B's meter drains well before).
const BACKED_RUN := AIBrain.BACK_OFF_MAX_TIME - 0.5
const PRESSURES: Array[float] = [0.0, 0.5, 0.9]
const START_DIST := 1.5          ## m from the player each run starts at
const BACKOFF_MIN := 1.5         ## m it must back off (the doc: "a couple of metres")
const REENGAGE_LIMIT := 5.0      ## s from the back-off's end to its next attack
const TICK := 1.0 / 120.0

var failures := 0
var player: Fighter
var g: Fighter
var gb: AIBrain
var fc: FakeCombat
var turns: Array = []            ## per token turn: Array of [start time, move]
var tells: Array = []            ## [time, duration, move]
var _last_start := -1.0

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	AIBrain.test_seed = 4242
	Tuning.difficulty = Tuning.Difficulty.NORMAL
	AttackDirector.camera_busy = false
	Util.build_floor(self)
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	g = Util.spawn_pressure_enemy(self, &"grunt", Vector3(0, 0.05, -START_DIST), Vector3.BACK)
	gb = g.brain as AIBrain
	fc = g.combat as FakeCombat
	AttackDirector.token_granted.connect(func(e: Fighter) -> void:
		if e == g: turns.append([]))
	gb.attack_launched.connect(func(m: StringName) -> void:
		_last_start = Util.game_now()
		if turns.is_empty(): turns.append([])
		turns[-1].append([_last_start, m]))
	GameEvents.attack_tell.connect(func(a: Node3D, _k: StringName, d: float) -> void:
		if a == g: tells.append([Util.game_now(), d, gb.get_tell_move()]))
	await _wait(0.5)
	await _part_rates()
	await _part_backoff()
	await _part_about_to_swing()
	await _part_no_drain()
	_finish()

# --- A. Attack rate and tells by pressure ---------------------------------------------------

func _part_rates() -> void:
	var rates: Array[float] = []
	var gaps: Array[float] = []
	var tell_by: Array[Dictionary] = []
	for p in PRESSURES:
		await _reset_enemy(START_DIST, 0.0)
		fc.fake_pressure = p
		turns.clear()
		tells.clear()
		var run := RATE_RUN if p < Tuning.R8_PRESSURE_BACK_OFF else BACKED_RUN
		var t0 := Util.game_now()
		var a0 := gb.attacks_started
		var max_dist := 0.0
		var backing_ticks := 0
		var ticks := 0
		while Util.game_now() - t0 < run:
			_keep_player()
			max_dist = maxf(max_dist, _dist())
			ticks += 1
			if gb.is_backing_off():
				backing_ticks += 1
			await get_tree().physics_frame
		var attacks := gb.attacks_started - a0
		var per_min := attacks * 60.0 / run
		rates.append(per_min)
		# Turn gaps: last attack of a turn -> first of the next (the interval's part).
		var gap_sum := 0.0
		var gap_n := 0
		var gap_min := INF
		var low_bad := 0
		var prev_last: Array = []
		for t: Array in turns:
			if t.is_empty():
				continue
			if not prev_last.is_empty():
				var gap: float = float(t[0][0]) - float(prev_last[0])
				gap_sum += gap
				gap_n += 1
				gap_min = minf(gap_min, gap)
				if gap < AIBrain.LONE_INTERVAL.x * (1.0 + p) - 2.0 * TICK:
					low_bad += 1
			prev_last = t[-1]
		var mean_gap := gap_sum / gap_n if gap_n > 0 else INF
		gaps.append(mean_gap)
		var by_move := {}
		for rec: Array in tells:
			var m: StringName = rec[2]
			if not by_move.has(m):
				by_move[m] = []
			by_move[m].append(float(rec[1]))
		tell_by.append(by_move)
		var tell_txt: Array[String] = []
		var floor_s := Tuning.frames(AttackDirector.tell_min_frames())
		var under_floor := 0
		for m: StringName in by_move:
			var ds: Array = by_move[m]
			for d: float in ds:
				if d < floor_s - 1e-4:
					under_floor += 1
			tell_txt.append("%s %.3f s x%d" % [m, ds[0], ds.size()])
		print("[ai] info: p %.1f: %d attacks in %.0f s (%.1f / min), %d turns, mean turn gap %.2f s (min %.2f, floor %.2f), backing off %.0f%% of the run, farthest %.1f m; tells %s" % [
			p, attacks, run, per_min, turns.size(), mean_gap, gap_min, AIBrain.LONE_INTERVAL.x * (1.0 + p),
			100.0 * backing_ticks / maxi(ticks, 1), max_dist, ", ".join(tell_txt)])
		check(under_floor == 0, "p %.1f: no tell under the floor %.3f s (%d)" % [p, floor_s, under_floor])
		if p < Tuning.R8_PRESSURE_BACK_OFF:
			check(attacks >= 10, "p %.1f: it keeps attacking (%d attacks in %.0f s)" % [p, attacks, run])
			check(low_bad == 0, "p %.1f: no turn starts sooner than LONE_INTERVAL.x x (1 + p) = %.2f s after the last (shortest %.2f s, %d too soon)" % [
				p, AIBrain.LONE_INTERVAL.x * (1.0 + p), gap_min, low_bad])
			check(backing_ticks == 0, "p %.1f: never backs off below %.1f (%d ticks)" % [p, Tuning.R8_PRESSURE_BACK_OFF, backing_ticks])
		else:
			check(attacks == 0, "p %.1f: backs off instead of trading: no attack in %.0f s (%d)" % [p, run, attacks])
			check(max_dist >= START_DIST + BACKOFF_MIN, "p %.1f: backs off to %.1f m (from %.1f m, >= %.1f m asked)" % [
				p, max_dist, START_DIST, START_DIST + BACKOFF_MIN])
	print("[ai] info: attack rate per min by pressure: p0 %.1f, p0.5 %.1f, p0.9 %.1f; mean turn gap p0 %.2f s, p0.5 %.2f s" % [
		rates[0], rates[1], rates[2], gaps[0], gaps[1]])
	check(rates[1] < rates[0] / 1.15, "attack rate drops with pressure: %.1f / min at p 0.5 vs %.1f at p 0 (ratio %.2f, >= 1.15)" % [
		rates[1], rates[0], rates[0] / maxf(rates[1], 0.01)])
	check(gaps[1] > gaps[0] * 1.2, "time between turns grows with pressure: %.2f s at p 0.5 vs %.2f s at p 0 (ratio %.2f, >= 1.2)" % [
		gaps[1], gaps[0], gaps[1] / maxf(gaps[0], 0.01)])
	check(rates[2] < rates[1], "at p 0.9 it attacks least (%.1f / min)" % rates[2])
	# Tells: the same move's tell is R8_PRESSURE_TELL_SLOW x p longer.
	var compared := 0
	for m: StringName in tell_by[0]:
		if not tell_by[1].has(m):
			continue
		var d0: float = tell_by[0][m][0]
		var d5: float = tell_by[1][m][0]
		var want := Tuning.R8_PRESSURE_TELL_SLOW * 0.5
		compared += 1
		check(absf((d5 - d0) - want) <= 0.003, "%s tell %.3f s at p 0, %.3f s at p 0.5 (+%.3f s, expected +%.3f)" % [m, d0, d5, d5 - d0, want])
	check(compared >= 2, "tells compared for %d moves" % compared)
	# The tell floor at full pressure and without it (brain's startup, every grunt move).
	var floor_ok := true
	for m: StringName in [&"e_jab", &"e_hook", &"e_kick", &"e_grab"]:
		for p: float in [0.0, 1.0]:
			fc.fake_pressure = p
			var s := gb._startup_for(m)
			var want := AttackDirector.enemy_startup_s(m) + Tuning.R8_PRESSURE_TELL_SLOW * p
			floor_ok = floor_ok and s >= Tuning.frames(AttackDirector.tell_min_frames()) - 1e-5 and absf(s - want) < 1e-4
	check(floor_ok, "startup = the wave's + %.2f x p for every grunt move, never under the %.0f-frame floor" % [
		Tuning.R8_PRESSURE_TELL_SLOW, AttackDirector.tell_min_frames()])
	fc.fake_pressure = 0.0

# --- B. Backing off and re-engaging -----------------------------------------------------------

func _part_backoff() -> void:
	await _reset_enemy(4.5, 0.0)
	var granted := await _until(func() -> bool:
		return AttackDirector.has_token(g) and gb._has_move \
			and _dist() > float(AIBrain.MOVE_RANGE.get(gb._move_id, 1.5)) + AIBrain.RANGE_SLACK, 6.0)
	check(granted, "a holder closing in (token, %.1f m from the player)" % _dist())
	if not granted:
		return
	var d0 := _dist()
	var b0 := gb.backoffs
	fc.fake_pressure = 0.7
	await _ticks(3)
	check(not AttackDirector.has_token(g) and gb.is_backing_off() and gb.backoffs == b0 + 1,
		"at p 0.7 a holder still closing in gives its token back and backs off (token %s, backing %s)" % [
			AttackDirector.has_token(g), gb.is_backing_off()])
	var a0 := gb.attacks_started
	var req0: float = AttackDirector._last_request.get(g, -INF)
	var max_d := d0
	var token_ticks := 0
	var t0 := Util.game_now()
	while Util.game_now() - t0 < Tuning.R8_PRESSURE_DECAY_DELAY + 1.0:
		_keep_player()
		max_d = maxf(max_d, _dist())
		if AttackDirector.has_token(g):
			token_ticks += 1
		await get_tree().physics_frame
	var asked: bool = float(AttackDirector._last_request.get(g, -INF)) != req0
	print("[ai] info: back-off from %.1f m: farthest %.1f m in %.1f s (radius %.1f m), starts %d, token ticks %d, asked %s" % [
		d0, max_d, Util.game_now() - t0, gb._backoff_radius, gb.attacks_started - a0, token_ticks, asked])
	check(max_d >= minf(d0 + BACKOFF_MIN, AIBrain.BACK_OFF_MAX_RADIUS - 0.3), "backs off to %.1f m (from %.1f m)" % [max_d, d0])
	check(max_d <= AIBrain.BACK_OFF_MAX_RADIUS + 0.8, "does not run away: farthest %.1f m (cap %.1f m)" % [max_d, AIBrain.BACK_OFF_MAX_RADIUS])
	check(gb.attacks_started == a0 and token_ticks == 0 and not asked,
		"while backing off: no attack (%d), no token (%d ticks), no request (%s)" % [gb.attacks_started - a0, token_ticks, asked])
	# Drain like B's meter: R8_PRESSURE_DECAY of max per s (the delay ran above).
	var t_line := -1.0
	var t_end := -1.0
	var t_attack := -1.0
	var a1 := gb.attacks_started
	var td := Util.game_now()
	while Util.game_now() - td < 10.0:
		var p := maxf(fc.fake_pressure - Tuning.R8_PRESSURE_DECAY * TICK, 0.0)
		fc.fake_pressure = p
		if t_line < 0.0 and p < Tuning.R8_PRESSURE_BACK_OFF:
			t_line = Util.game_now()
		_keep_player()
		await get_tree().physics_frame
		if t_end < 0.0 and not gb.is_backing_off():
			t_end = Util.game_now()
		if gb.attacks_started > a1:
			t_attack = Util.game_now()
			break
	print("[ai] info: drain: p under %.1f at +%.2f s, back-off over +%.2f s, attacks again +%.2f s (%.2f s after the back-off ended)" % [
		Tuning.R8_PRESSURE_BACK_OFF, t_line - td, t_end - td, t_attack - td, t_attack - t_end])
	check(t_end >= 0.0 and t_end - t_line <= 2.0 * TICK + 1e-4, "the back-off ends as p drains under %.1f (%.3f s after)" % [
		Tuning.R8_PRESSURE_BACK_OFF, t_end - t_line])
	check(t_attack >= 0.0 and t_attack - t_end <= REENGAGE_LIMIT, "it re-engages and attacks %.2f s after the back-off (<= %.0f s)" % [
		t_attack - t_end, REENGAGE_LIMIT])
	fc.fake_pressure = 0.0

# --- C. About to swing ---------------------------------------------------------------------------

func _part_about_to_swing() -> void:
	await _reset_enemy(1.2, 0.0)
	# A pause from the grant (as after a get-up) lets it walk into range and
	# stand there with its token; then the pressure rises and it waits HOLD s more.
	var hold := 0.4
	var hit := [false]
	var on_grant := func(e: Fighter) -> void:
		if e == g and not hit[0]:
			hit[0] = true
			gb._resume_at = gb._time + 1.5
	AttackDirector.token_granted.connect(on_grant)
	var granted := await _until(func() -> bool: return hit[0], 6.0)
	AttackDirector.token_granted.disconnect(on_grant)
	var in_range := granted and await _until(func() -> bool:
		return gb._has_move and _dist() <= float(AIBrain.MOVE_RANGE.get(gb._move_id, 1.5)), 1.2)
	check(in_range and AttackDirector.has_token(g) and not g.combat.is_attacking(),
		"a holder standing in range of its %s (%.2f m), not yet swinging" % [gb._move_id, _dist()])
	if not in_range:
		return
	gb._resume_at = gb._time + hold
	fc.fake_pressure = 0.7
	var a0 := gb.attacks_started
	var t0 := Util.game_now()
	var kept := 0
	var backing := 0
	var ticks := 0
	while Util.game_now() - t0 < hold - TICK:
		await get_tree().physics_frame
		ticks += 1
		kept += 1 if AttackDirector.has_token(g) else 0
		backing += 1 if gb.is_backing_off() else 0
	var swung := await _until(func() -> bool: return gb.attacks_started > a0, 1.0)
	check(kept == ticks and backing == 0, "in range and about to swing at p 0.7: keeps its token (%d / %d ticks), not backing off (%d)" % [
		kept, ticks, backing])
	check(swung, "it swings its turn first (%.2f s after the pressure rose)" % (Util.game_now() - t0))
	var done := await _until(func() -> bool: return not AttackDirector.has_token(g) and not g.combat.is_attacking(), 4.0)
	var t_done := Util.game_now()
	var backs := await _until(func() -> bool: return gb.is_backing_off(), 0.5)
	check(done and backs, "then backs off (%.2f s after its turn ended)" % (Util.game_now() - t_done))
	fc.fake_pressure = 0.0

# --- D. No drain: the back-off still ends ---------------------------------------------------------

func _part_no_drain() -> void:
	await _reset_enemy(2.0, 0.0)
	fc.fake_pressure = 0.7
	var started := await _until(func() -> bool: return gb.is_backing_off(), 1.0)
	var t0 := Util.game_now()
	var a0 := gb.attacks_started
	var ended := await _until(func() -> bool: return not gb.is_backing_off(), AIBrain.BACK_OFF_MAX_TIME + 1.0)
	var t_end := Util.game_now() - t0
	var attacked := await _until(func() -> bool: return gb.attacks_started > a0, REENGAGE_LIMIT + 2.0)
	print("[ai] info: pressure stuck at 0.7: backed off %.2f s, then attacked %s" % [t_end, attacked])
	check(started and ended and absf(t_end - AIBrain.BACK_OFF_MAX_TIME) <= 0.1,
		"with no drain the back-off ends after %.2f s (BACK_OFF_MAX_TIME %.1f s)" % [t_end, AIBrain.BACK_OFF_MAX_TIME])
	check(attacked, "then it re-engages and attacks at p 0.7")
	await _until(func() -> bool: return not g.combat.is_attacking() and not AttackDirector.has_token(g), 4.0)
	await _ticks(2)
	var still_off := not gb.is_backing_off()
	fc.fake_pressure = 0.8  # a new hit
	var again := await _until(func() -> bool: return gb.is_backing_off(), 1.5)
	check(still_off and again, "no new back-off until a new hit raises its pressure, then it backs off again (%s, %s)" % [still_off, again])
	fc.fake_pressure = 0.0

# --- Helpers ------------------------------------------------------------------------------------------

## Put the grunt `dist` m in front of the player, out of any turn, at pressure `p`.
func _reset_enemy(dist: float, p: float) -> void:
	fc.fake_pressure = p
	await _until(func() -> bool: return not g.combat.is_attacking(), 3.0)
	AttackDirector.release_token(g)
	gb._has_move = false
	gb._following = false
	gb._string_rest.clear()
	gb._backing_off = false
	gb._backoff_spent_p = INF
	gb._interval_left = 0.3
	g.global_position = Vector3(0, 0.05, -dist)
	g.reset_physics_interpolation()
	g.snap_facing(Vector3.BACK)
	player.global_position = Vector3(0, 0.05, 0)
	player.reset_physics_interpolation()
	await _wait(0.2)

func _dist() -> float:
	return Util.flat_dist(g.get_ground_position(), player.get_ground_position())

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
	print("[ai] test_pressure_rate: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
