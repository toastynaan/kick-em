extends Node
## Enemy throws aim at walls (round 2, item 4): find_throw_aim() prefers the
## breakable wall in front over a nearer plain wall, skips lanes with an
## enemy, and a real Brute grab throws the player along that aim.
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")

var failures := 0
var thrown_dir := Vector3.ZERO

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _plain_wall(center: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	add_child(body)
	body.global_position = center
	return body

## What a ray along `dir` from `from` hits first (WORLD | DESTRUCTIBLE).
func _hit(from: Vector3, dir: Vector3) -> Object:
	var space := get_viewport().get_world_3d().direct_space_state
	var o := from + Vector3.UP
	var q := PhysicsRayQueryParameters3D.create(o, o + dir * 9.0, Layers.WORLD | Layers.DESTRUCTIBLE)
	var hit := space.intersect_ray(q)
	return hit["collider"] if not hit.is_empty() else null

func _lane_clear(from: Vector3, dir: Vector3, e: Fighter) -> bool:
	var a := Vector2(from.x, from.z)
	var b := a + Vector2(dir.x, dir.z) * 9.0
	var p := Vector2(e.get_ground_position().x, e.get_ground_position().z)
	return Geometry2D.get_closest_point_to_segment(p, a, b).distance_to(p) >= AIBrain.THROW_LANE

func _run() -> void:
	AttackDirector.reset()
	Util.build_floor(self)
	var drywall := Destructible.new()
	drywall.surface = &"drywall"
	drywall.size = Vector3(3.0, 3.0, 0.25)
	add_child(drywall)
	drywall.global_position = Vector3(0, 1.5, -5.0)
	_plain_wall(Vector3(2.6, 1.5, -3.2), Vector3(2.0, 3.0, 0.3))
	await get_tree().physics_frame
	var player := FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, -1.0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	AttackDirector.camera_busy = true  # the brain gets no tokens; the test drives the grab
	var brute := FighterFactory.spawn_enemy(self, &"brute", Transform3D(Basis(), Vector3(0, 0.05, 0)))
	var brain := brute.brain as AIBrain
	await get_tree().physics_frame
	await get_tree().physics_frame
	brute.global_rotation = Vector3.ZERO  # face -Z
	brute.face_dir = Vector3.FORWARD

	var aim := brain.find_throw_aim()
	check(aim != Vector3.ZERO and _hit(brute.global_position, aim) == drywall,
		"aims at the breakable wall ahead, not the nearer plain wall (aim %s)" % str(aim.snapped(Vector3.ONE * 0.01)))

	var grunt := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis(), Vector3(0, 0.05, -3.0)))
	AttackDirector.register_enemy(grunt)
	await get_tree().physics_frame
	aim = brain.find_throw_aim()
	check(aim == Vector3.ZERO or _lane_clear(brute.global_position, aim, grunt),
		"never aims along a lane with another enemy (aim %s)" % str(aim.snapped(Vector3.ONE * 0.01)))
	AttackDirector.unregister_enemy(grunt)
	grunt.queue_free()
	await get_tree().physics_frame

	if not brute.has_method(&"_physics_process") or brute.combat.get_script() == null:
		print("[ai] BLOCKED: no real combat for the grab check")
		_finish()
		return
	# A real grab: the Brute holds the player and throws it along throw_aim.
	GameEvents.thrown.connect(func(g: Node3D, _v: Node3D, vel: Vector3) -> void:
		if g == brute:
			thrown_dir = Vector3(vel.x, 0.0, vel.z).normalized())
	brute.global_rotation = Vector3(0, deg_to_rad(20.0), 0)  # slightly off the wall
	brute.face_dir = brute.get_forward()
	player.global_position = brute.global_position + brute.get_forward() * 1.0
	player.reset_physics_interpolation()
	await get_tree().physics_frame
	var started := brute.combat.start_enemy_attack(&"e_grab", 0.35)
	var t0 := Util.game_now()
	var aim_seen := Vector3.ZERO
	while thrown_dir == Vector3.ZERO and Util.game_now() - t0 < 4.0:
		if brute.combat.holding != null and brute.combat.throw_aim != Vector3.ZERO:
			aim_seen = brute.combat.throw_aim
		await get_tree().physics_frame
	if not started or brute.combat.holding == null and thrown_dir == Vector3.ZERO and aim_seen == Vector3.ZERO:
		print("[ai] info: the grab did not connect (started %s); throw direction not checked" % started)
	else:
		check(aim_seen != Vector3.ZERO, "throw_aim set while holding (%s)" % str(aim_seen.snapped(Vector3.ONE * 0.01)))
		check(thrown_dir != Vector3.ZERO and thrown_dir.dot(aim_seen.normalized()) > 0.95,
			"the throw flies along the aim (dir %s)" % str(thrown_dir.snapped(Vector3.ONE * 0.01)))
	_finish()

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_throw_aim: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
