extends Node
## Duel: the Duelist against a passive player dummy for 60 s (override with
## `-- --seconds=N`). It must attack repeatedly (about one attack every
## 1.2-2.5 s of open time), mix its moves, and never start an attack while
## the player is down, held or in hitstun.
## Phase B (Round 5 defence): the player dummy jabs the Duelist whenever he is
## in reach (Tuning read chance, no overrides). Every GameEvents.parried with
## the Duelist as defender is followed by its counter (a hook, or B's
## start_counter teleport) within COUNTER_LIMIT s. OWNER: agent C (AI tests).

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
const JAB_PHASE_MIN := 30.0       ## s at least...
const JAB_PHASE_MAX := 100.0      ## ...until PARRIES_WANTED parries, at most this
const PARRIES_WANTED := 4
const JAB_GAP := 1.6              ## s between the dummy's jabs
const JAB_REACH := 1.9            ## m: the dummy jabs when the Duelist is this close
const COUNTER_LIMIT := 1.8        ## s from a parry to the counter (the parried stagger ~0.8 s comes first)
var parries: Array[float] = []
var launch_log: Array = []        ## [time, move]

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
	await _phase_jabs()
	_finish()

## Phase B: the dummy jabs; the Duelist parries some and counters each one.
func _phase_jabs() -> void:
	var brain := duelist.brain as AIBrain
	if not (duelist.defence != null and duelist.defence.is_enabled()):
		print("[ai] info: Round 5 Defence is off: parry counters not checked")
		return
	GameEvents.parried.connect(func(d: Node3D, _a: Node3D) -> void:
		if d == duelist: parries.append(Util.game_now()))
	brain.attack_launched.connect(func(m: StringName) -> void: launch_log.append([Util.game_now(), m]))
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
	var jabs := 0
	var next_jab := 0.0
	var t0 := Util.game_now()
	var counters0 := brain.parry_counters
	var teleports0 := brain.counters_started
	while Util.game_now() - t0 < JAB_PHASE_MAX:
		var now := Util.game_now()
		if now - t0 > JAB_PHASE_MIN and parries.size() >= PARRIES_WANTED and now - parries[-1] > COUNTER_LIMIT + 0.2:
			break
		await get_tree().physics_frame
		if player.hp < player.max_hp * 0.4 and not player.is_dead():
			player.heal_fraction(1.0)
		if duelist.hp < duelist.max_hp * 0.3:
			duelist.hp = duelist.max_hp
		if not player.is_down() and Util.flat_dist(player.get_ground_position(), home) > 0.6:
			player.global_position = home
			player.reset_physics_interpolation()
		var d := Util.flat_dist(duelist.get_ground_position(), player.get_ground_position())
		var after_parry := not parries.is_empty() and now - parries[-1] < COUNTER_LIMIT + 0.2
		if now >= next_jab and d < JAB_REACH and player.can_act() and not after_parry:
			var to := duelist.get_ground_position() - player.get_ground_position()
			to.y = 0.0
			player.snap_facing(to)
			player.combat.press(CombatController.Action.LIGHT)
			await get_tree().physics_frame
			player.combat.release(CombatController.Action.LIGHT)
			jabs += 1
			next_jab = Util.game_now() + JAB_GAP
	var countered := 0
	var gaps: Array[String] = []
	var kinds := {}
	for t in parries:
		var hit := false
		for l: Array in launch_log:
			if l[0] > t and l[0] - t <= COUNTER_LIMIT and l[1] in [&"e_hook", &"counter"]:
				countered += 1
				gaps.append("%.2f" % (l[0] - t))
				kinds[l[1]] = kinds.get(l[1], 0) + 1
				hit = true
				break
		if not hit:
			var after := launch_log.filter(func(l: Array) -> bool: return l[0] > t - 0.5 and l[0] - t < 3.0)
			print("[ai] info: parry at %.2f s not countered; Duelist launches around it %s" % [t - t0,
				str(after.map(func(l: Array) -> String: return "%s@%+.2f" % [l[1], l[0] - t]))])
	print("[ai] info: phase B %.0f s: %d jabs, %d parries by the Duelist, %d countered %s (s after the parry: %s); brain: %d parry counters, %d teleport counters" % [
		Util.game_now() - t0, jabs, parries.size(), countered, str(kinds), ", ".join(gaps),
		brain.parry_counters - counters0, brain.counters_started - teleports0])
	check(parries.size() >= 1, "the Duelist parries the player's jabs in Duel mode (%d of %d jabs)" % [parries.size(), jabs])
	check(parries.size() > 0 and countered == parries.size(),
		"every parry is followed by a counter within %.1f s (%d / %d)" % [COUNTER_LIMIT, countered, parries.size()])

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_duel: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
