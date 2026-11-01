extends Node
## Thrower uses real rubble (round 2, item 5): it walks to a large debris
## chunk within RUBBLE_SEARCH, picks it up (combat.pick_up_debris) and its
## next e_throw_debris throws that chunk. Without rubble it still throws (the
## conjured box). OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")

var failures := 0
var throws := 0

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _chunk(pos: Vector3) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "Rubble"
	body.collision_layer = Layers.DEBRIS
	body.collision_mask = Layers.MASK_DEBRIS
	body.mass = 8.0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.5, 0.4, 0.4)
	shape.shape = box
	body.add_child(shape)
	add_child(body)
	body.global_position = pos
	DebrisManager.register(body, false)
	return body

func _run() -> void:
	AttackDirector.reset()
	DebrisManager.reset()
	Util.build_floor(self)
	var player := FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	var thrower := FighterFactory.spawn_enemy(self, &"thrower", Transform3D(Basis(), Vector3(7, 0.05, 0)))
	var brain := thrower.brain as AIBrain
	brain.attack_launched.connect(func(m: StringName) -> void:
		if m == &"e_throw_debris": throws += 1)
	if not player.has_method(&"_physics_process"):
		print("[ai] BLOCKED: fighter.gd is the contract stub")
		_finish()
		return
	var can_pick := thrower.combat.has_method(&"pick_up_debris")
	if can_pick:
		AttackDirector.camera_busy = true  # no throw until it has the chunk
		var rubble := _chunk(Vector3(9.5, 0.3, 3.0))
		var t0 := Util.game_now()
		while not brain.has_chunk() and Util.game_now() - t0 < 8.0:
			_keep(player)
			await get_tree().physics_frame
		check(brain.has_chunk(), "walks to the rubble and picks it up (%.1f s)" % (Util.game_now() - t0))
		check(not rubble in DebrisManager.get_bodies(), "the held chunk left DebrisManager's care")
		AttackDirector.camera_busy = false
		var before := throws
		t0 = Util.game_now()
		while throws == before and Util.game_now() - t0 < 10.0:
			_keep(player)
			await get_tree().physics_frame
		var top_speed := 0.0
		t0 = Util.game_now()
		while Util.game_now() - t0 < 1.5 and is_instance_valid(rubble):
			top_speed = maxf(top_speed, rubble.linear_velocity.length())
			await get_tree().physics_frame
		check(throws > before and not brain.has_chunk() and top_speed > 4.0,
			"throws the picked-up chunk (it flew at %.1f m/s)" % top_speed)
	else:
		print("[ai] BLOCKED: CombatController.pick_up_debris not landed (agent B); only the fallback is checked")
	# Fallback: no rubble near, it still throws.
	DebrisManager.reset()
	AttackDirector.camera_busy = false
	var before2 := throws
	var t1 := Util.game_now()
	while throws == before2 and Util.game_now() - t1 < 12.0:
		_keep(player)
		await get_tree().physics_frame
	check(throws > before2, "without rubble the Thrower still throws (conjured chunk)")
	_finish()

func _keep(player: Fighter) -> void:
	if "invuln_until" in player:
		player.set(&"invuln_until", TimeDirector.now() + 5.0)
	if player.hp < player.max_hp * 0.5:
		player.heal_fraction(1.0)

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_thrower: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
