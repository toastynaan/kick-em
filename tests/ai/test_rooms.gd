extends Node
## Navigation into rooms of the real Yard (round 2.5). With the nav grid:
## A. a Grunt reaches a player inside a west office behind a facade panel that
##    breaks after the grid was built (wall_broken refresh);
## B. a Grunt reaches a player in the back-north office, reachable only
##    through two doorways (the straight line crosses two walls);
## C. the Duelist reaches the same player with a vanish step (the path is
##    longer than VSTEP_PATH_LEN) and attacks.
## Budgets are simulation seconds. OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const BUDGET_A := 9.0
const BUDGET_B := 16.0
const BUDGET_C := 7.0

var failures := 0
var yard: Node3D
var player: Fighter

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	yard = Util.build_yard(self)
	if yard == null:
		print("[ai] BLOCKED: YardBuilder is a stub")
		_finish()
		return
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 8)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	AttackDirector.camera_busy = true

	# --- A: office behind a facade that breaks after the grid is built.
	var grunt := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis(), Vector3(-3, 0.05, 1)))
	await _wait_nav()
	var t_nav := Util.game_now()
	var facade := _facade_near(Vector3(-11.125, 1.5, 0.0))
	check(facade != null, "found the west facade panel at z = 0")
	if facade:
		facade.force_break(facade.global_position, Vector3(-6, 0, 0))
	await _wait(0.5)
	var spot_a := _free_spot(Vector3(-12.6, 0.05, 1.2))
	_pin_player(spot_a)
	var took := await _until_attack(grunt, spot_a, BUDGET_A)
	check(took >= 0.0, "A: reaches the player inside the office behind the broken facade (%s)" % _fmt(took, grunt))
	print("[ai] info: grid built in %.1f s of sim; %s" % [t_nav, str(AttackDirector.nav.get_stats())])

	# --- B: back-north office, reachable only through two doorways.
	grunt.global_position = Vector3(-3, 0.05, -2)
	grunt.reset_physics_interpolation()
	AttackDirector.release_token(grunt)
	var spot_b := _free_spot(Vector3(-16.0, 0.05, -7.0))
	_pin_player(spot_b)
	check(not _line_clear(grunt.get_ground_position(), spot_b), "B: the straight line from the courtyard is blocked")
	took = await _until_attack(grunt, spot_b, BUDGET_B)
	check(took >= 0.0, "B: reaches the player through the doorways (%s)" % _fmt(took, grunt))
	grunt.hp = 0.0
	AttackDirector.unregister_enemy(grunt)
	grunt.queue_free()
	await get_tree().physics_frame

	# --- C: the Duelist takes a vanish step to a player far away by path.
	var duelist := FighterFactory.spawn_enemy(self, &"duelist", Transform3D(Basis(), Vector3(2, 0.05, 6)))
	var brain := duelist.brain as AIBrain
	_pin_player(spot_b)
	took = await _until_attack(duelist, spot_b, BUDGET_C)
	check(brain.vanish_steps >= 1, "C: the Duelist vanish-steps to a player a long path away (%d steps)" % brain.vanish_steps)
	check(took >= 0.0, "C: and attacks (%s)" % _fmt(took, duelist))
	print("[ai] info: nav cost %s" % str(AttackDirector.nav.get_stats()))
	_finish()

func _fmt(took: float, e: Fighter) -> String:
	if took >= 0.0:
		return "%.1f s" % took
	return "not within budget; at %s, %s" % [str(e.get_ground_position().snapped(Vector3.ONE * 0.1)),
		(e.brain as AIBrain).get_debug_text()]

## Simulation seconds until `e` starts an attack, with the player pinned at
## `spot` and invulnerable; -1 if not within `budget`.
func _until_attack(e: Fighter, spot: Vector3, budget: float) -> float:
	var brain := e.brain as AIBrain
	var before := brain.attacks_started
	AttackDirector.camera_busy = false
	var t0 := Util.game_now()
	while Util.game_now() - t0 < budget:
		_pin_player(spot)
		await get_tree().physics_frame
		if brain.attacks_started > before:
			AttackDirector.camera_busy = true
			return Util.game_now() - t0
	AttackDirector.camera_busy = true
	return -1.0

func _pin_player(spot: Vector3) -> void:
	if player.global_position.distance_to(spot) > 0.3:
		player.global_position = spot
		player.velocity = Vector3.ZERO
		player.reset_physics_interpolation()
	if "invuln_until" in player:
		player.set(&"invuln_until", TimeDirector.now() + 5.0)
	if player.hp < player.max_hp * 0.5:
		player.heal_fraction(1.0)

func _wait_nav() -> void:
	var t0 := Util.game_now()
	while not AttackDirector.nav_ready() and Util.game_now() - t0 < 5.0:
		await get_tree().physics_frame
	check(AttackDirector.nav_ready(), "nav grid built")

func _wait(s: float) -> void:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < s:
		await get_tree().physics_frame

func _facade_near(p: Vector3) -> Destructible:
	var best: Destructible = null
	var best_d := 2.0
	for n in get_tree().get_nodes_in_group(&"destructibles"):
		var d := n as Destructible
		if d and not d.is_broken and d.global_position.distance_to(p) < best_d:
			best_d = d.global_position.distance_to(p)
			best = d
	return best

## Nearest spot to `p` where a fighter capsule fits.
func _free_spot(p: Vector3) -> Vector3:
	var space := get_viewport().get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.5
	params.shape = cap
	params.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
	for r in [0.0, 0.4, 0.8, 1.2]:
		for k in 8:
			var c: Vector3 = p + Vector3(cos(k * TAU / 8.0), 0, sin(k * TAU / 8.0)) * r
			params.transform = Transform3D(Basis(), c + Vector3.UP * 0.95)
			if space.intersect_shape(params, 1).is_empty():
				return c
			if r == 0.0:
				break
	return p

func _line_clear(a: Vector3, b: Vector3) -> bool:
	var space := get_viewport().get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(a + Vector3.UP, b + Vector3.UP, Layers.WORLD | Layers.DESTRUCTIBLE)
	return space.intersect_ray(q).is_empty()

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_rooms: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
