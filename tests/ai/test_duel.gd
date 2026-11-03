extends Node
## Duel: the Duelist against a passive player dummy for 60 s (override with
## `-- --seconds=N`). It must attack repeatedly (about one attack every
## 1.2-2.5 s of open time), mix its moves, and never start an attack while
## the player is down, held or in hitstun.
## Phase B (Round 7 defence, Round 8 strikes): the player dummy jabs the
## Duelist whenever he is in reach between his turns (no token, not
## attacking: a dummy that struck as he closed in would only ever meet his
## wind-up) and his pressure has calmed under PRESSURE_CALM, and throws a
## guard breaker (Round 8: a charged gut punch, uppercut or front kick, held
## BREAK_HOLD s; only charged strikes break a guard) every third time, and on
## the tick it sees a fresh read guard of his go up (as a player would: jab,
## blocked, charged gut punch; Tuning read chance, no overrides). The
## Duelist guards some (B's guard blocks the taps), never parries or
## teleports, and every broken guard that leaves him free (not broken open,
## pressure under Tuning.R8_PRESSURE_BACK_OFF) is answered with an e_hook
## (before any other attack of his) within ANSWER_LIMIT s of him being able
## to act again (an uppercut's lift ends in a knockdown and a get-up first);
## one that leaves him broken or pressured is not answered: he does nothing,
## or backs off. He never starts an attack while reacting, broken open or
## backing off.
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")

var failures := 0
var seconds := 60.0
var player: Fighter
var duelist: Fighter
var starts: Array[float] = []
var moves := {}
var starts_while_closed := 0
var combat_starts := 0
var hits := 0
var blocked := 0
var whiffs := 0
var downs := 0
## Regression (B's report): after the player gets up from a launch, the
## Duelist attacks again within RECOVER_ATTACK_MAX s while the player stays
## open, plus walking time when the player got up far away (knocked into a
## room): + (distance - 4 m) / walk speed x 1.5 for detours.
const RECOVER_ATTACK_MAX := 3.0
var recover_gaps: Array[float] = []
var waiting_since := -1.0        ## player recovery time not yet answered by an attack
var waiting_allow := RECOVER_ATTACK_MAX
var stalls := 0
## Phase B.
const PHASE_B_MIN := 30.0         ## s at least...
## ...until BREAKS_WANTED guard breaks, at most this. A break needs a read
## (Tuning read chance ~30%, more on repeats): about 3 per 100 s.
const PHASE_B_MAX := 240.0
const BREAKS_WANTED := 4
const STRIKE_GAP := 1.2           ## s between the dummy's strikes
const STRIKE_REACH := 1.9         ## m: the dummy strikes when the Duelist is this close
## s from the Duelist being able to act again after a broken guard to the hook.
const ANSWER_LIMIT := AIBrain.ANSWER_WINDOW
## s after a break in which the dummy holds off (his reaction, a knockdown and
## get-up, then the answer).
const BREAK_QUIET := 5.0
const BREAKERS: Array[int] = [CombatController.Action.GUT_PUNCH, CombatController.Action.UPPERCUT,
	CombatController.Action.FRONT_KICK]
## s a breaker is held: past Tuning.R8_TAP_MAX, a charged strike (far from full).
const BREAK_HOLD := 0.35
## The dummy jabs only while his pressure fraction is under this (it lets his
## meter drain, so most guard breaks find him free to answer).
const PRESSURE_CALM := 0.2
var breaks: Array[float] = []
var parries := 0
var counter_tells := 0
var guard_blocked := 0           ## player strikes the Duelist's guard stopped
var launch_log: Array = []        ## [time, move, reacting or stunned at the start, broken or backing off]
var pressured_breaks: Array[float] = []  ## guard breaks that left him broken or at p >= R8_PRESSURE_BACK_OFF

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seconds="):
			seconds = float(arg.get_slice("=", 1))
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _player_open() -> bool:
	return not (player.is_down() or player.is_in_hitstun() or (player.carry and player.carry.is_held()))

func _run() -> void:
	AttackDirector.reset()
	Tuning.difficulty = Tuning.Difficulty.NORMAL
	# The real Yard (walls stop launches); plain floor + walls if it is still a stub.
	var p_xform := Transform3D(Basis(), Vector3(0, 0.05, 3))
	var d_xform := Transform3D(Basis(), Vector3(0, 0.05, -3))
	var yard := Util.build_yard(self)
	if yard:
		var spawns: Array[Transform3D] = yard.get_duel_spawns()
		p_xform = spawns[0]
		d_xform = spawns[1]
		print("[ai] info: duel in the real Yard")
	else:
		Util.build_floor(self)
		Util.build_walls(self, 11.0)
	player = FighterFactory.spawn_dummy(self, &"player", p_xform, Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	duelist = FighterFactory.spawn_enemy(self, &"duelist", d_xform)
	var brain := duelist.brain as AIBrain
	brain.attack_launched.connect(func(m: StringName) -> void:
		if waiting_since >= 0.0:
			recover_gaps.append(Util.game_now() - waiting_since)
			waiting_since = -1.0
		starts.append(Util.game_now())
		moves[m] = moves.get(m, 0) + 1
		if not _player_open():
			starts_while_closed += 1)
	if duelist.combat:
		duelist.combat.attack_started.connect(func(_m: StringName) -> void: combat_starts += 1)
	GameEvents.hit_landed.connect(func(i: HitInfo) -> void:
		if i.attacker == duelist: hits += 1)
	GameEvents.hit_blocked.connect(func(i: HitInfo) -> void:
		if i.attacker == duelist: blocked += 1)
	GameEvents.attack_whiff.connect(func(a: Node3D, _m: StringName) -> void:
		if a == duelist: whiffs += 1)
	GameEvents.fighter_launched.connect(func(f: Node3D, _v: Vector3) -> void:
		if f == player: downs += 1)

	var open_time := 0.0
	var in_range_time := 0.0
	var t0 := Util.game_now()
	var last := t0
	var next_report := 10.0
	var was_down := false
	while Util.game_now() - t0 < seconds:
		await get_tree().physics_frame
		var now := Util.game_now()
		var down := player.is_down()
		if was_down and not down:
			waiting_since = now
			var d0 := Util.flat_dist(duelist.get_ground_position(), player.get_ground_position())
			waiting_allow = RECOVER_ATTACK_MAX + maxf(d0 - 4.0, 0.0) / Tuning.ENEMY_WALK_SPEED * 1.5
		elif down:
			waiting_since = -1.0
		was_down = down
		if waiting_since >= 0.0 and now - waiting_since > waiting_allow:
			if _player_open():
				stalls += 1
				print("[ai] stall: no attack %.1f s after the player got up (dist %.1f, player open %s, player at %s): %s" % [
					now - waiting_since, Util.flat_dist(duelist.get_ground_position(), player.get_ground_position()),
					AttackDirector.is_player_open(), player.get_ground_position().snapped(Vector3.ONE * 0.1),
					(duelist.brain as AIBrain).get_debug_text()])
			waiting_since = -1.0
		var dt := now - last
		last = now
		if player.hp < player.max_hp * 0.4 and not player.is_dead():
			player.heal_fraction(1.0)
		if _player_open() and not duelist.is_down():
			open_time += dt
			if Util.flat_dist(duelist.get_ground_position(), player.get_ground_position()) < Tuning.NEAR_RING.y + 0.5:
				in_range_time += dt
		if now - t0 >= next_report:
			next_report += 10.0
			print("[ai] t=%.0fs attacks=%d hits=%d blocked=%d whiffs=%d player_downs=%d dist=%.1f" % [
				now - t0, starts.size(), hits, blocked, whiffs, downs,
				Util.flat_dist(duelist.get_ground_position(), player.get_ground_position())])

	var n := starts.size()
	if n == 0:
		print("[ai] BLOCKED: the Duelist never started an attack (combat.start_enemy_attack returned false - CombatController stub?)")
		failures += 1
		_finish()
		return
	var per_open := open_time / n
	print("[ai] info: %d attacks in %.0f s (%.1f s open, %.1f s open+in range), moves %s" % [
		n, seconds, open_time, in_range_time, str(moves)])
	print("[ai] info: duelist hits=%d blocked=%d whiffs=%d, player launched %d times, vanish steps %d" % [
		hits, blocked, whiffs, downs, (duelist.brain as AIBrain).vanish_steps])
	if AttackDirector.nav:
		print("[ai] info: nav cost %s" % str(AttackDirector.nav.get_stats()))
	# Judged on open time: under --fixed-fps, B's wall-clock windows (grab hold,
	# hitstop) keep the player closed for much longer in game time.
	check(n >= maxi(3, int(open_time / 3.0)), "the Duelist attacks repeatedly (%d attacks, %.1f s open)" % [n, open_time])
	check(per_open >= 1.0 and per_open <= 2.6,
		"one attack every %.2f s of open time (target 1.2-2.5)" % per_open)
	check(starts_while_closed == 0, "never started an attack while the player was down / held / in hitstun (%d)" % starts_while_closed)
	check(moves.size() >= 3, "mixes at least 3 different moves (%d)" % moves.size())
	check(stalls == 0, "attacks again within %.0f s after every player get-up (%d get-ups answered, gaps %s, %d stalls)" % [
		RECOVER_ATTACK_MAX, recover_gaps.size(), str(recover_gaps.map(func(g: float) -> String: return "%.1f" % g)), stalls])
	check(combat_starts == 0 or combat_starts == n, "combat.attack_started matches brain starts (%d / %d)" % [combat_starts, n])
	await _phase_guard()
	_finish()

## Phase B: the dummy jabs and breaks the Duelist's guard; he guards, never
## parries or teleports, and answers every broken guard with a hook.
func _phase_guard() -> void:
	var brain := duelist.brain as AIBrain
	if GameEvents.has_signal(&"parried"):
		GameEvents.connect(&"parried", func(d: Node3D, _a: Node3D) -> void:
			if d == duelist: parries += 1)
	GameEvents.attack_tell.connect(func(a: Node3D, kind: StringName, _d: float) -> void:
		if a == duelist and kind == &"counter": counter_tells += 1)
	GameEvents.hit_blocked.connect(func(i: HitInfo) -> void:
		if i.victim == duelist: guard_blocked += 1)
	brain.attack_launched.connect(func(m: StringName) -> void:
		launch_log.append([Util.game_now(), m, duelist.is_reacting() or duelist.is_lifted() or duelist.is_in_hitstun(),
			brain.is_broken() or brain.is_backing_off()]))
	# Back to the duel spawns, in the open (phase A may have knocked the dummy
	# into the clutter); the dummy stays on its spot when on its feet.
	var home := player.get_ground_position()
	var yard := get_tree().get_first_node_in_group(&"arena")
	if yard != null and yard.has_method(&"get_duel_spawns"):
		var sp: Array = yard.get_duel_spawns()
		home = (sp[0] as Transform3D).origin
		while player.is_down():
			await get_tree().physics_frame
		player.global_position = home
		player.reset_physics_interpolation()
		if not duelist.is_down():
			duelist.global_position = (sp[1] as Transform3D).origin
			duelist.reset_physics_interpolation()
	var strikes := 0
	var states := {}                  ## the Duelist's state at each of the dummy's strikes
	var answered_read := -1           ## brain.guard_reads when the dummy last answered a guard
	var breakers := 0
	var next_strike := 0.0
	var t0 := Util.game_now()
	var reads0 := brain.guard_reads
	var seen_breaks := brain.guard_breaks
	var acts: Array[float] = []       ## times the Duelist could act again after not being able to
	var could_act := true
	var hold_action := -1             ## a breaker being charged...
	var release_at := 0.0             ## ...released at this time
	while Util.game_now() - t0 < PHASE_B_MAX:
		var now := Util.game_now()
		if now - t0 > PHASE_B_MIN and breaks.size() - pressured_breaks.size() >= BREAKS_WANTED \
				and now - breaks[-1] > BREAK_QUIET and hold_action < 0:
			break
		await get_tree().physics_frame
		var can := duelist.can_act() or (duelist.combat.is_attacking() and not duelist.is_reacting())
		if can and not could_act:
			acts.append(Util.game_now())
		could_act = can
		if brain.guard_breaks > seen_breaks:
			seen_breaks = brain.guard_breaks
			breaks.append(Util.game_now())
			if duelist.combat.is_broken() or duelist.combat.get_pressure_fraction() >= Tuning.R8_PRESSURE_BACK_OFF:
				pressured_breaks.append(breaks[-1])
		if player.hp < player.max_hp * 0.4 and not player.is_dead():
			player.heal_fraction(1.0)
		if duelist.hp < duelist.max_hp * 0.3:
			duelist.hp = duelist.max_hp
		if not player.is_down() and Util.flat_dist(player.get_ground_position(), home) > 0.6:
			player.global_position = home
			player.reset_physics_interpolation()
		var d := Util.flat_dist(duelist.get_ground_position(), player.get_ground_position())
		if hold_action >= 0:
			# Charging a breaker: keep facing him, release on time.
			player.snap_facing(duelist.get_ground_position() - player.get_ground_position())
			if Util.game_now() >= release_at:
				player.combat.release(hold_action)
				hold_action = -1
				next_strike = Util.game_now() + STRIKE_GAP
			continue
		var after_break := not breaks.is_empty() and Util.game_now() - breaks[-1] < BREAK_QUIET
		var calm := duelist.combat.get_pressure_fraction() < PRESSURE_CALM and not duelist.combat.is_broken()
		# A fresh read guard: answer it with a guard breaker at once (buffered
		# when the dummy is still in its own recovery).
		if duelist.combat.is_blocking() and brain.guard_reads != answered_read and d < STRIKE_REACH \
				and not after_break and not player.is_down() and not player.is_in_hitstun() \
				and (player.can_act() or player.combat.is_in_recovery()):
			answered_read = brain.guard_reads
			var bk: int = BREAKERS[breakers % BREAKERS.size()]
			breakers += 1
			strikes += 1
			states["guarding"] = int(states.get("guarding", 0)) + 1
			player.snap_facing(duelist.get_ground_position() - player.get_ground_position())
			player.combat.press(bk)
			hold_action = bk
			release_at = Util.game_now() + BREAK_HOLD
			continue
		if Util.game_now() < next_strike or d >= STRIKE_REACH or not player.can_act() or not calm \
				or after_break or AttackDirector.has_token(duelist) or duelist.combat.is_attacking():
			continue
		var to := duelist.get_ground_position() - player.get_ground_position()
		to.y = 0.0
		player.snap_facing(to)
		strikes += 1
		var st := "attacking" if duelist.combat.is_attacking() else ("reacting" if duelist.is_reacting() or duelist.is_down() \
			else ("stunned" if duelist.combat.is_hit_stunned() else ("guarding" if duelist.combat.is_blocking() else "free")))
		states[st] = int(states.get(st, 0)) + 1
		next_strike = Util.game_now() + STRIKE_GAP
		var action := CombatController.Action.LIGHT
		if strikes % 3 == 0:
			action = BREAKERS[breakers % BREAKERS.size()]
			breakers += 1
		player.combat.press(action)
		if action != CombatController.Action.LIGHT:
			hold_action = action  # charged: released after BREAK_HOLD
			release_at = Util.game_now() + BREAK_HOLD
			continue
		await get_tree().physics_frame
		player.combat.release(action)
	var answered := 0
	var free_breaks := 0
	var gaps: Array[String] = []
	for t in breaks:
		var pressured := t in pressured_breaks
		if not pressured:
			free_breaks += 1
		var first: Array = []
		for l: Array in launch_log:
			if l[0] > t:
				first = l
				break
		if first.is_empty():
			print("[ai] info: guard break at %.2f s: no attack after it" % (t - t0))
			continue
		var t_act := t
		for a in acts:
			if a > t and a <= first[0]:
				t_act = a
				break
		gaps.append("%s%s %.2f s after he could act (%.2f s after the break)" % [
			"(pressured) " if pressured else "", first[1], first[0] - t_act, first[0] - t])
		if not pressured and first[1] == &"e_hook" and first[0] - t_act <= ANSWER_LIMIT and not first[2]:
			answered += 1
	var bad := launch_log.filter(func(l: Array) -> bool: return l[2]).size()
	var bad_pressure := launch_log.filter(func(l: Array) -> bool: return l[3]).size()
	print("[ai] info: the Duelist at the dummy's strikes: %s" % str(states))
	print("[ai] info: phase B %.0f s: %d strikes (%d charged guard breakers), %d reads, %d blocked, %d guard breaks (%d left him broken or pressured), %d pressure breaks; first attack after each break: %s" % [
		Util.game_now() - t0, strikes, breakers, brain.guard_reads - reads0, guard_blocked,
		breaks.size(), pressured_breaks.size(), brain.pressure_breaks, "; ".join(gaps)])
	check(brain.guard_reads - reads0 >= 1 and guard_blocked >= 1,
		"the Duelist guards the player's strikes in Duel mode (%d reads, %d blocked)" % [brain.guard_reads - reads0, guard_blocked])
	check(breaks.size() >= 2, "charged guard breakers get through his raised guard in the duel (%d breaks)" % breaks.size())
	check(free_breaks >= 1 and answered == free_breaks,
		"every broken guard that leaves him free is answered with an e_hook within %.1f s of him acting again (%d / %d)" % [
			ANSWER_LIMIT, answered, free_breaks])
	check(parries == 0 and counter_tells == 0, "no parry (%d) and no teleport counter (%d) in Duel" % [parries, counter_tells])
	check(bad == 0, "never starts an attack while reacting or in hitstun (%d of %d)" % [bad, launch_log.size()])
	check(bad_pressure == 0, "never starts an attack while broken open or backing off (%d of %d)" % [bad_pressure, launch_log.size()])

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_duel: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
