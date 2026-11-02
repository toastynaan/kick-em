extends Node
## AIBrain in a crowd, against a passive player dummy:
## A. A Grunt walks its entry path into the courtyard, then takes a ring
##    position around the player.
## B. Five Grunts: ~1.6 m separation, waiting in a loose ring at
##    Tuning.CIRCLE_RING (3-5 m; the next in line on its inner part), inside
##    the bounds, never more than Tuning.TOKEN_MAX holders, first active
##    frames of different attackers >= Tuning.TOKEN_ACTIVE_GAP apart, no
##    attack starts while the player is down or held, except a holder's free
##    swing at a knocked-down player. OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const BOUNDS_HALF := 10.0  ## AIBrain.DEFAULT_BOUNDS_HALF (no arena node here)

var failures := 0
var player: Fighter
var enemies: Array[Fighter] = []
var actives: Array = []          ## [time, attacker]
var starts := 0
var starts_while_closed := 0
var ring_of := {}        ## Fighter -> last ring seen
var ring_since := {}     ## Fighter -> time the ring last changed
var attack_end := {}     ## Fighter -> time its last attack ended
var attack_end_game := {}  ## Fighter -> Util.game_now() of its last attack end
## s after its attack during which an enemy walks back out (not "waiting").
const WALK_OUT_TIME := 2.0
var outcomes := {"hit": 0, "blocked": 0, "whiff": 0}
var player_anchor := Vector3.INF
var player_still_since := 0.0

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	Tuning.difficulty = Tuning.Difficulty.NORMAL
	Util.build_floor(self)
	Util.build_walls(self, 16.0)  # outside the entry spawn at (14, -14)
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	GameEvents.attack_active.connect(func(a: Node3D, _m: StringName) -> void: actives.append([Util.game_now(), a]))
	GameEvents.hit_landed.connect(func(i: HitInfo) -> void:
		if i.attacker in enemies: outcomes.hit += 1)
	GameEvents.hit_blocked.connect(func(i: HitInfo) -> void:
		if i.attacker in enemies: outcomes.blocked += 1)
	GameEvents.attack_whiff.connect(func(a: Node3D, _m: StringName) -> void:
		if a in enemies: outcomes.whiff += 1)
	if not player.has_method(&"_physics_process"):
		print("[ai] BLOCKED: fighter.gd is the contract stub (fighters cannot move)")
		_finish()
		return

	await _part_entry()
	await _part_crowd()
	_finish()

func _spawn(pos: Vector3, path := PackedVector3Array()) -> Fighter:
	var e := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis(), pos), path)
	var brain := e.brain as AIBrain
	brain.attack_launched.connect(func(_m: StringName) -> void:
		starts += 1
		if not _player_open() and not AttackDirector.is_player_knocked_down():
			starts_while_closed += 1)
	e.combat.attack_ended.connect(func(_m: StringName) -> void:
		attack_end_game[e] = Util.game_now()
		attack_end[e] = Util.game_now())
	enemies.append(e)
	return e

## Not attacking, no token, same ring for 2 s, attack ended 2 s ago, and the
## player has stood still for 2 s: the enemy has had time to walk to its ring.
func _settled(e: Fighter) -> bool:
	var now := Util.game_now()
	var pp := player.get_ground_position()
	if player.is_down() or pp.distance_to(player_anchor) > 0.4:
		player_anchor = pp
		player_still_since = now
	if now - player_still_since < 2.0:
		return false
	var ring := AttackDirector.get_ring(e)
	if ring_of.get(e, -1) != ring:
		ring_of[e] = ring
		ring_since[e] = now
	if AttackDirector.has_token(e) or e.combat.is_attacking():
		return false
	return now - float(ring_since[e]) > 2.0 and now - float(attack_end.get(e, -INF)) > 2.0

func _player_open() -> bool:
	return not (player.is_down() or player.is_in_hitstun() or (player.carry and player.carry.is_held()))

## The player dummy stays put: invulnerable (hits ignored, no launches), so
## the test measures positioning around a fixed centre.
func _keep_player_alive() -> void:
	if "invuln_until" in player:
		player.set(&"invuln_until", TimeDirector.now() + 5.0)
	if player.hp < player.max_hp * 0.4 and not player.is_dead():
		player.heal_fraction(1.0)

func _part_entry() -> void:
	var path := PackedVector3Array([Vector3(14, 0, -9), Vector3(8, 0, -6), Vector3(4, 0, -3)])
	var g := _spawn(Vector3(14, 0.05, -14), path)
	var brain := g.brain as AIBrain
	var closest: Array[float] = [INF, INF, INF]
	var t0 := Util.game_now()
	while not brain.is_fighting() and Util.game_now() - t0 < 15.0:
		for i in path.size():
			closest[i] = minf(closest[i], Util.flat_dist(g.get_ground_position(), path[i]))
		_keep_player_alive()
		await get_tree().physics_frame
	var took := Util.game_now() - t0
	check(brain.is_fighting(), "grunt finished its entry path in %.1f s" % took)
	check(closest.max() < AIBrain.ENTRY_REACH + 0.2, "passed every waypoint (closest %s)" % str(closest))
	# Settle into the ring. No tokens meanwhile (as during a follow-cam), so
	# the lone grunt waits in its ring instead of attacking.
	AttackDirector.camera_busy = true
	var in_ring := 0
	var samples := 0
	t0 = Util.game_now()
	while Util.game_now() - t0 < 5.0:
		await get_tree().physics_frame
		_keep_player_alive()
		if not _settled(g):
			continue
		samples += 1
		if _ring_ok(g, 0.8):
			in_ring += 1
	AttackDirector.camera_busy = false
	var d := Util.flat_dist(g.get_ground_position(), player.get_ground_position())
	check(samples > 0 and in_ring >= samples * 0.8,
		"grunt holds a ring position when not attacking (%d/%d samples, now %.1f m)" % [in_ring, samples, d])
	check(_inside_bounds(g), "grunt inside the courtyard")

func _ring_ok(e: Fighter, slack: float) -> bool:
	var d := Util.flat_dist(e.get_ground_position(), player.get_ground_position())
	var ring := AttackDirector.get_ring(e)
	var band: Vector2 = (e.brain as AIBrain).ring_band(ring != AttackDirector.Ring.NEAR)
	# A FAR enemy may not fit its band near a wall; the bounds clamp wins.
	if ring != AttackDirector.Ring.NEAR and not _ring_fits(band.x):
		return d >= band.x - slack
	return d >= band.x - slack and d <= band.y + slack

func _ring_fits(r: float) -> bool:
	var p := player.get_ground_position()
	return absf(p.x) + r < BOUNDS_HALF - 1.0 or absf(p.z) + r < BOUNDS_HALF - 1.0

func _inside_bounds(e: Fighter) -> bool:
	var p := e.get_ground_position()
	return absf(p.x) <= BOUNDS_HALF + 0.3 and absf(p.z) <= BOUNDS_HALF + 0.3

func _part_crowd() -> void:
	for pos in [Vector3(-6, 0.05, -6), Vector3(6, 0.05, 6), Vector3(-7, 0.05, 5), Vector3(2, 0.05, 8)]:
		_spawn(pos)
	actives.clear()
	starts = 0
	var max_holders := 0
	var min_sep := INF
	var close_samples := 0
	var samples := 0
	var ring_ok := 0
	var ring_samples := 0
	var out_of_bounds := 0
	var t0 := Util.game_now()
	while Util.game_now() - t0 < 16.0:
		await get_tree().physics_frame
		_keep_player_alive()
		max_holders = maxi(max_holders, AttackDirector.get_token_holders().size())
		if Util.game_now() - t0 < 5.0:
			continue
		# Separation is a rule for the waiting crowd. A token holder closing in
		# (or swinging), or an enemy walking back out to the far ring after its
		# turn, may brush past a neighbour; those are not waiting.
		var standing: Array[Fighter] = []
		var now_t := Util.game_now()
		for e in enemies:
			if not e.is_down() and not e.is_dead():
				var walking_out := now_t - float(attack_end_game.get(e, -INF)) < WALK_OUT_TIME
				if not AttackDirector.has_token(e) and not e.combat.is_attacking() and not walking_out:
					standing.append(e)
				if not _inside_bounds(e):
					out_of_bounds += 1
				if _settled(e):
					ring_samples += 1
					if _ring_ok(e, 0.8):
						ring_ok += 1
		var frame_min := INF
		for i in standing.size():
			for j in range(i + 1, standing.size()):
				frame_min = minf(frame_min, Util.flat_dist(standing[i].get_ground_position(), standing[j].get_ground_position()))
		if is_finite(frame_min):
			samples += 1
			min_sep = minf(min_sep, frame_min)
			if frame_min < 1.3:
				close_samples += 1
	var cap: int = mini(Tuning.TOKENS[Tuning.difficulty], Tuning.TOKEN_MAX)
	check(max_holders <= cap, "never more than %d token holders (max %d)" % [cap, max_holders])
	check(samples > 0 and close_samples <= samples * 0.05 and min_sep > 0.8,
		"waiting enemies keep their distance: min %.2f m, < 1.3 m in %d/%d frames" % [min_sep, close_samples, samples])
	check(ring_samples > 0 and ring_ok >= ring_samples * 0.75,
		"waiting enemies hold ring positions (%d/%d samples)" % [ring_ok, ring_samples])
	check(out_of_bounds == 0, "everyone stays inside the courtyard (%d violations)" % out_of_bounds)
	check(starts_while_closed == 0, "no attack started while the player was held / in hitstun, or down beyond a free swing (%d)" % starts_while_closed)
	# Rule 6 on real attacks.
	var worst := INF
	for i in range(1, actives.size()):
		if actives[i][1] != actives[i - 1][1]:
			worst = minf(worst, actives[i][0] - actives[i - 1][0])
	if starts == 0:
		print("[ai] BLOCKED: no attack started in 11 s (combat.start_enemy_attack returned false - CombatController stub?)")
		failures += 1
	else:
		check(worst >= Tuning.TOKEN_ACTIVE_GAP - 0.005,
			"first active frames of different attackers >= %.0f frames apart (closest %.1f frames, %d actives)" % [
				Tuning.TOKEN_ACTIVE_GAP * 60.0, worst * 60.0, actives.size()])
		print("[ai] info: %d attacks started by 5 grunts in 11 s; outcomes %s" % [starts, str(outcomes)])

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_crowd: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
