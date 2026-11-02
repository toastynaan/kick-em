extends Node
## The Round 5 roster fighting together (Feel Reference: Enemy types) round a
## passive player dummy (healed, never invulnerable): two grunts, a stick
## enemy and a heavy. Every archetype attacks; grunts throw the jab-cross
## string (e_jab then e_hook from the same grunt); the stick enemy swings from
## his reach (about 2 m) and waits about 3 m out; the heavy smashes, grabs and
## shoulder-charges from range; never more than Tuning.TOKEN_MAX holders and
## first active frames of different enemies >= Tuning.TOKEN_ACTIVE_GAP apart.
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const MIN_SECONDS := 20.0
const MAX_SECONDS := 70.0

var failures := 0
var player: Fighter
var moves := {}           ## archetype -> {move: count}
var start_dist := {}      ## archetype -> Array[float] distances at attack start
var strings := 0
var last_jab := {}        ## grunt -> world time of its last e_jab start
var wait_dists: Array[float] = []   ## stick enemy, waiting (no token)
var max_holders := 0
var actives: Array = []   ## [world time, attacker]

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	AttackDirector.set_wave(3)
	Tuning.difficulty = Tuning.Difficulty.NORMAL
	Util.build_floor(self)
	Util.build_walls(self, 12.0)
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	GameEvents.attack_active.connect(func(a: Node3D, _m: StringName) -> void:
		if a is Fighter and not (a as Fighter).is_player: actives.append([AttackDirector.world_now(), a]))
	var spawns := [[&"grunt", Vector3(-4, 0.05, -2)], [&"grunt", Vector3(4, 0.05, -2)],
		[&"stick", Vector3(0, 0.05, -5)], [&"heavy", Vector3(0, 0.05, 5)]]
	var stick: Fighter
	for s: Array in spawns:
		var arch: StringName = s[0]
		var e := FighterFactory.spawn_enemy(self, arch, Transform3D(Basis(), s[1]))
		if arch == &"stick":
			stick = e
		moves[arch] = moves.get(arch, {})
		start_dist[arch] = start_dist.get(arch, [])
		var f := e
		(e.brain as AIBrain).attack_launched.connect(func(m: StringName) -> void:
			moves[arch][m] = moves[arch].get(m, 0) + 1
			start_dist[arch].append(Util.flat_dist(f.get_ground_position(), player.get_ground_position()))
			if m == &"e_jab":
				last_jab[f] = AttackDirector.world_now()
			elif m == &"e_hook" and AttackDirector.world_now() - float(last_jab.get(f, -INF)) < 1.2:
				strings += 1)
	var t0 := Util.game_now()
	while Util.game_now() - t0 < MAX_SECONDS:
		if Util.game_now() - t0 > MIN_SECONDS and _all_done():
			break
		await get_tree().physics_frame
		max_holders = maxi(max_holders, AttackDirector.get_token_holders().size())
		if player.hp < player.max_hp * 0.5 and not player.is_dead():
			player.heal_fraction(1.0)
		if player.get_ground_position().length() > 0.5 and not player.is_down():
			player.global_position = Vector3(0, 0.05, 0)
			player.reset_physics_interpolation()
		var sb := stick.brain as AIBrain
		if stick and not stick.is_dead() and sb.has_stick() and sb.is_fighting() and not AttackDirector.has_token(stick) \
				and not stick.combat.is_attacking() and not stick.is_down() and Engine.get_physics_frames() % 30 == 0 \
				and AttackDirector.get_ring(stick) == AttackDirector.Ring.FAR:
			wait_dists.append(Util.flat_dist(stick.get_ground_position(), player.get_ground_position()))
	var took := Util.game_now() - t0
	print("[ai] info: %.0f s; moves by archetype %s; strings %d" % [took, str(moves), strings])
	for a: StringName in moves:
		var total := 0
		for m in moves[a]:
			total += moves[a][m]
		check(total >= 1, "%s attacks (%d)" % [a, total])
	check(strings >= 1, "grunts throw the jab-cross string (%d)" % strings)
	var stick_moves: Dictionary = moves.get(&"stick", {})
	var stick_d: Array = start_dist.get(&"stick", [])
	var stick_far := 0
	for d: float in stick_d:
		if d >= 1.6:
			stick_far += 1
	check(stick_moves.has(&"e_stick_swing") or stick_moves.has(&"e_stick_thrust"), "the stick enemy swings or thrusts (%s)" % str(stick_moves))
	check(stick_d.is_empty() or stick_far * 2 >= stick_d.size(),
		"the stick enemy attacks from his reach (start distances %s)" % str(stick_d.map(func(x): return snappedf(x, 0.1))))
	var mean_wait := 0.0
	for d in wait_dists:
		mean_wait += d
	mean_wait = mean_wait / wait_dists.size() if not wait_dists.is_empty() else 0.0
	check(wait_dists.is_empty() or mean_wait >= 2.8, "the armed stick enemy waits about 3 m out (mean %.1f m over %d samples)" % [mean_wait, wait_dists.size()])
	var heavy_moves: Dictionary = moves.get(&"heavy", {})
	check(heavy_moves.keys().all(func(m): return m in [&"e_heavy", &"e_charge", &"e_grab_slam", &"e_grab"]),
		"the heavy uses smash / charge / grab-and-slam (%s)" % str(heavy_moves))
	check(max_holders <= Tuning.TOKEN_MAX, "never more than %d token holders (max %d)" % [Tuning.TOKEN_MAX, max_holders])
	var worst := INF
	for i in range(1, actives.size()):
		if actives[i][1] != actives[i - 1][1]:
			worst = minf(worst, actives[i][0] - actives[i - 1][0])
	check(worst >= Tuning.TOKEN_ACTIVE_GAP - 0.004, "first active frames of different enemies >= %.0f frames apart (closest %.1f, %d actives)" % [
		Tuning.TOKEN_ACTIVE_GAP * 60.0, worst * 60.0, actives.size()])
	_finish()

func _all_done() -> bool:
	for a: StringName in [&"grunt", &"stick", &"heavy"]:
		if (moves.get(a, {}) as Dictionary).is_empty():
			return false
	return strings >= 1

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_roster_fight: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
