extends Node
## Upgrade 2 state gating: dazed, stumbling or tripped enemies do not get
## tokens and lose held ones; a brain on a dazed enemy does not ask; an
## enemy with a broken arm picks kicks. OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const FakeCombat := preload("res://tests/ai/fake_combat.gd")

var failures := 0
var player: Fighter

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

## Point the fighter's `combat` at a FakeCombat (the real one stays as a node).
func _fake_combat(f: Fighter) -> FakeCombat:
	var fc: FakeCombat = FakeCombat.new()
	fc.name = "FakeCombat"
	fc.setup(f)
	f.add_child(fc)
	f.combat = fc
	return fc

func _grant(e: Fighter) -> bool:
	var t0 := AttackDirector.now()
	while AttackDirector.now() - t0 < 1.0:
		if AttackDirector.request_token(e, true):
			return true
		await get_tree().physics_frame
	return false

func _run() -> void:
	AttackDirector.reset()
	Util.build_floor(self)
	player = Util.spawn_fake(self, &"player", Fighter.TEAM_PLAYER, Vector3(0, 0.05, 0))
	AttackDirector.set_player(player)
	var a := Util.spawn_fake(self, &"grunt", Fighter.TEAM_ENEMY, Vector3(0, 0.05, -3))
	var b := Util.spawn_fake(self, &"grunt", Fighter.TEAM_ENEMY, Vector3(3, 0.05, 0))
	AttackDirector.register_enemy(a)
	AttackDirector.register_enemy(b)
	var fa := _fake_combat(a)
	await get_tree().physics_frame

	# Dazed: no token; a holder that becomes dazed loses it.
	fa.fake_dazed = true
	check(not AttackDirector.request_token(a, true) and AttackDirector.get_last_denial(a) == "enemy busy",
		"a dazed enemy gets no token (%s)" % AttackDirector.get_last_denial(a))
	fa.fake_dazed = false
	check(await _grant(a), "token granted once no longer dazed")
	fa.fake_dazed = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(not AttackDirector.has_token(a), "a holder that becomes dazed loses its token")
	fa.fake_dazed = false

	# Stumbling: same.
	check(await _grant(a), "token granted (stumble check)")
	fa.fake_stumbling = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(not AttackDirector.has_token(a), "a holder that starts stumbling loses its token")
	check(not AttackDirector.request_token(a, true), "a stumbling enemy gets no token")
	fa.fake_stumbling = false

	# Events: dazed / stumbled / tripped release at once.
	for ev in ["dazed", "stumbled", "tripped"]:
		check(await _grant(b), "token granted to b (%s event)" % ev)
		match ev:
			"dazed":
				GameEvents.dazed.emit(b, 1.5)
			"stumbled":
				GameEvents.stumbled.emit(b, 0.8)
			"tripped":
				GameEvents.tripped.emit(b)
		check(not AttackDirector.has_token(b), "GameEvents.%s releases the token at once" % ev)

	# A brain on a dazed enemy does not ask for a token.
	var g := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis(), Vector3(-2, 0.05, -2)))
	var gb := g.brain as AIBrain
	if not g.has_method(&"_physics_process"):
		print("[ai] BLOCKED: fighter.gd is a stub")
		_finish()
		return
	var gfc := _fake_combat(g)
	gfc.fake_dazed = true
	var t0 := Util.game_now()
	var got := false
	while Util.game_now() - t0 < 2.0:
		got = got or AttackDirector.has_token(g)
		await get_tree().physics_frame
	check(not got and gb.attacks_started == 0, "a dazed enemy's brain neither holds a token nor attacks")
	gfc.fake_dazed = false

	# Broken arm: kicks only.
	GameEvents.arm_broken.emit(g, 0)
	var moves := {}
	for i in 200:
		var m: StringName = gb._pick_move(1.5, player)
		moves[m] = moves.get(m, 0) + 1
	var ok := true
	for m: StringName in moves:
		ok = ok and m in AIBrain.ARM_FREE_MOVES
	check(ok and not moves.is_empty(), "a broken arm picks kicks only: %s" % str(moves))
	_finish()

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_states: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
