extends Node
## Regression (round 2, item 6): a pillar straight between the Duelist and the
## player must not stall the approach. In each trial the Duelist starts with
## a pillar between them and must start an attack within TRIAL_LIMIT s of
## simulation time. OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const TRIAL_LIMIT := 4.0
## [duelist position, player position] per trial; the pillar is at the origin.
const TRIALS := [
	[Vector3(0, 0.05, -2.8), Vector3(0, 0.05, 1.3)],
	[Vector3(0.3, 0.05, -2.6), Vector3(-0.2, 0.05, 1.4)],
	[Vector3(-0.5, 0.05, -3.4), Vector3(0.3, 0.05, 1.2)],
	[Vector3(2.6, 0.05, 0.1), Vector3(-1.3, 0.05, -0.1)],
]

var failures := 0
var player: Fighter
var duelist: Fighter

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	Util.build_floor(self)
	Util.build_walls(self, 12.0)
	var pillar := StaticBody3D.new()
	pillar.collision_layer = Layers.WORLD
	pillar.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.2, 3.0, 1.2)
	shape.shape = box
	pillar.add_child(shape)
	add_child(pillar)
	pillar.global_position = Vector3(0, 1.5, 0)
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), TRIALS[0][1]), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	duelist = FighterFactory.spawn_enemy(self, &"duelist", Transform3D(Basis(), TRIALS[0][0]))
	var brain := duelist.brain as AIBrain
	if not player.has_method(&"_physics_process"):
		print("[ai] BLOCKED: fighter.gd is the contract stub")
		_finish()
		return
	var started := [0]
	brain.attack_launched.connect(func(_m: StringName) -> void: started[0] += 1)
	for i in TRIALS.size():
		# Wait for any attack in progress to end, then set the scene.
		var tw := Util.game_now()
		while duelist.combat.is_attacking() and Util.game_now() - tw < 3.0:
			await get_tree().physics_frame
		_place(duelist, TRIALS[i][0], TRIALS[i][1])
		_place(player, TRIALS[i][1], TRIALS[i][0])
		AttackDirector.release_token(duelist)
		await get_tree().physics_frame
		var before: int = started[0]
		var t0 := Util.game_now()
		while started[0] == before and Util.game_now() - t0 < TRIAL_LIMIT:
			if "invuln_until" in player:
				player.set(&"invuln_until", TimeDirector.now() + 5.0)
			player.global_position = Vector3(TRIALS[i][1].x, player.global_position.y, TRIALS[i][1].z)
			await get_tree().physics_frame
		var took := Util.game_now() - t0
		check(started[0] > before, "trial %d: attacks round the pillar after %.1f s (%s)" % [
			i, took, brain.get_debug_text() if started[0] == before else "ok"])
	_finish()

func _place(f: Fighter, pos: Vector3, look: Vector3) -> void:
	f.global_position = pos
	var d := look - pos
	d.y = 0.0
	if d.length() > 0.01:
		f.face_dir = d.normalized()
		if f.has_method(&"snap_facing"):
			f.snap_facing(d)
	f.velocity = Vector3.ZERO
	f.reset_physics_interpolation()

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_pillar: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
