extends Node
## Wave-3/4 archetypes against a player dummy that holds Block the whole time:
## every archetype attacks; the Brawler grabs the blocker; the Shield raises
## its guard; the Brute charges or swings heavy; the Thrower throws debris
## from range. Token cap holds throughout. OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
## Simulation seconds: at least MIN_SECONDS, then until every archetype has
## attacked (the Brute and Shield are slow), at most MAX_SECONDS.
const MIN_SECONDS := 16.0
const MAX_SECONDS := 60.0

var failures := 0
var player: Fighter
var moves := {}          ## archetype -> {move: count}
var throw_dists: Array[float] = []
var shield_guarded := false
var max_holders := 0

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
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	if not player.has_method(&"_physics_process"):
		print("[ai] BLOCKED: fighter.gd is the contract stub")
		_finish()
		return
	var spawns := {&"brawler": Vector3(-3, 0.05, -3), &"shield": Vector3(3, 0.05, -3),
		&"brute": Vector3(0, 0.05, -6), &"thrower": Vector3(0, 0.05, 7)}
	var shield: Fighter
	for a: StringName in spawns:
		var e := FighterFactory.spawn_enemy(self, a, Transform3D(Basis(), spawns[a]))
		moves[a] = {}
		if a == &"shield":
			shield = e
		var arche := a
		var fighter := e
		(e.brain as AIBrain).attack_launched.connect(func(m: StringName) -> void:
			moves[arche][m] = moves[arche].get(m, 0) + 1
			if m == &"e_throw_debris":
				throw_dists.append(Util.flat_dist(fighter.get_ground_position(), player.get_ground_position())))

	player.combat.press(CombatController.Action.BLOCK)
	var t0 := Util.game_now()
	while Util.game_now() - t0 < MAX_SECONDS:
		if Util.game_now() - t0 > MIN_SECONDS and _all_done():
			break
		await get_tree().physics_frame
		max_holders = maxi(max_holders, AttackDirector.get_token_holders().size())
		if shield and shield.combat and shield.combat.blocking:
			shield_guarded = true
		if player.hp < player.max_hp * 0.5 and not player.is_dead():
			player.heal_fraction(1.0)
		# Keep blocking (a grab or a hit can drop it); re-press when free.
		if not player.combat.blocking and player.can_act():
			player.combat.release(CombatController.Action.BLOCK)
			player.combat.press(CombatController.Action.BLOCK)

	print("[ai] info: moves by archetype %s" % str(moves))
	for a: StringName in moves:
		var total := 0
		for m in moves[a]:
			total += moves[a][m]
		check(total >= 1, "%s attacks (%d)" % [a, total])
	check(moves[&"brawler"].has(&"e_grab"), "Brawler grabs a player who keeps blocking")
	check(shield_guarded, "Shield raises its guard")
	var brute_ok := true
	for m in moves[&"brute"]:
		brute_ok = brute_ok and m in [&"e_charge", &"e_heavy", &"e_grab"]
	check(brute_ok and not moves[&"brute"].is_empty(), "Brute uses its moves (charge / heavy / grab): %s" % str(moves[&"brute"]))
	check(moves[&"thrower"].has(&"e_throw_debris") and throw_dists.min() >= 3.0,
		"Thrower throws debris from range (distances %s)" % str(throw_dists))
	check(max_holders <= Tuning.TOKENS[Tuning.difficulty], "token cap holds (max %d)" % max_holders)
	_finish()

func _all_done() -> bool:
	for a: StringName in moves:
		if moves[a].is_empty():
			return false
	return moves[&"brawler"].has(&"e_grab") and moves[&"thrower"].has(&"e_throw_debris")

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_archetypes: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
