extends Node
## A grunt knocked out of the courtyard (behind a wall) walks the nearest
## visible spawn path back in, then fights. Uses a stand-in arena node with
## the YardBuilder API (get_courtyard_bounds, get_enemy_spawns).
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")

class FakeArena extends Node3D:
	func get_courtyard_bounds() -> AABB:
		return AABB(Vector3(-8, 0, -8), Vector3(16, 4, 16))
	func get_enemy_spawns() -> Array[Dictionary]:
		return [{"position": Vector3(12, 0.05, 4),
			"path": PackedVector3Array([Vector3(12, 0, -10), Vector3(5, 0, -10), Vector3(5, 0, -5)])}]

var failures := 0

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _wall(parent: Node, center: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	parent.add_child(body)
	body.global_position = center
	return body

func _run() -> void:
	AttackDirector.reset()
	Util.build_floor(self)
	var arena := FakeArena.new()
	arena.name = "FakeArena"
	add_child(arena)
	arena.add_to_group(&"arena")
	# East wall at x = 9 from z = -7 to z = 12; the way in is around its north end.
	var solid := _wall(self, Vector3(9, 1.5, 2.5), Vector3(0.4, 3, 19))
	var player := FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	AttackDirector.camera_busy = true  # no attacks: only movement matters here
	if not player.has_method(&"_physics_process"):
		print("[ai] BLOCKED: fighter.gd is the contract stub")
		_finish()
		return
	var g := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis(), Vector3(11, 0.05, 3)))
	var brain := g.brain as AIBrain
	var went_entry := false
	var t0 := Util.game_now()
	var inside_at := -1.0
	while Util.game_now() - t0 < 16.0:
		await get_tree().physics_frame
		if brain.mode == AIBrain.Mode.ENTRY or not brain._nav_path.is_empty():
			went_entry = true
		var p := g.get_ground_position()
		if absf(p.x) < 8.0 and absf(p.z) < 8.0 and brain.mode == AIBrain.Mode.FIGHT:
			inside_at = Util.game_now() - t0
			break
	check(went_entry, "outside the courtyard: follows a way back (nav path or spawn path)")
	check(inside_at > 0.0, "back inside the courtyard and fighting after %.1f s" % inside_at)

	# Phase 2: the player is knocked into the "room" behind the wall. The grunt
	# walks round the wall (waypoints) to a ring point it can see the player
	# from, then attacks.
	player.global_position = Vector3(11, 0.05, 3)
	player.reset_physics_interpolation()
	g.global_position = Vector3(5, 0.05, 3)
	g.reset_physics_interpolation()
	var space := g.get_world_3d().direct_space_state
	var seen_at := -1.0
	t0 = Util.game_now()
	while Util.game_now() - t0 < 14.0:
		await get_tree().physics_frame
		var a := g.get_ground_position() + Vector3.UP * 0.6
		var b := player.get_ground_position() + Vector3.UP * 0.6
		var q := PhysicsRayQueryParameters3D.create(a, b, Layers.WORLD | Layers.DESTRUCTIBLE)
		if space.intersect_ray(q).is_empty() and a.distance_to(b) < Tuning.NEAR_RING.y + 0.5:
			seen_at = Util.game_now() - t0
			break
	check(seen_at > 0.0, "walks round the wall to see the player in the room (%.1f s)" % seen_at)
	AttackDirector.camera_busy = false
	var starts := [0]
	brain.attack_launched.connect(func(_m: StringName) -> void: starts[0] += 1)
	t0 = Util.game_now()
	while Util.game_now() - t0 < 4.0 and starts[0] == 0:
		if "invuln_until" in player:
			player.set(&"invuln_until", TimeDirector.now() + 5.0)
		await get_tree().physics_frame
	check(starts[0] > 0, "attacks the player in the room")

	# Phase 3: the wall now has a waist-high hole (a body-sized check must not
	# treat it as a way through): the grunt still walks round and attacks.
	solid.queue_free()
	_wall(self, Vector3(9, 0.15, 2.5), Vector3(0.4, 0.3, 19))   # below the hole
	_wall(self, Vector3(9, 2.15, 2.5), Vector3(0.4, 1.7, 19))   # above it (hole 0.3-1.3 m)
	await get_tree().physics_frame
	AttackDirector.rebuild_nav()  # walls moved without a break event
	var tn := Util.game_now()
	while not AttackDirector.nav_ready() and Util.game_now() - tn < 5.0:
		await get_tree().physics_frame
	AttackDirector.camera_busy = false
	player.global_position = Vector3(11, 0.05, 3)
	player.reset_physics_interpolation()
	g.global_position = Vector3(5, 0.05, 3)
	g.reset_physics_interpolation()
	var before: int = starts[0]
	t0 = Util.game_now()
	while Util.game_now() - t0 < 18.0 and starts[0] == before:
		if "invuln_until" in player:
			player.set(&"invuln_until", TimeDirector.now() + 5.0)
		player.global_position = Vector3(11, player.global_position.y, 3)
		await get_tree().physics_frame
	check(starts[0] > before, "a waist-high hole is not a way through: walks round and attacks (%.1f s)" % (Util.game_now() - t0))
	_finish()

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_return: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
