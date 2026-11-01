extends Node
## AttackDirector rule 4: an enemy must be inside the camera view for
## Tuning.ONSCREEN_BEFORE_TOKEN s before it gets a token. Camera facing away:
## no token. Facing it: granted after ~0.4 s, not before.
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")

var failures := 0

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	Util.build_floor(self)
	var player := Util.spawn_fake(self, &"player", Fighter.TEAM_PLAYER, Vector3(0, 0.05, 0))
	AttackDirector.set_player(player)
	var enemy := Util.spawn_fake(self, &"grunt", Fighter.TEAM_ENEMY, Vector3(0, 0.05, -3))
	AttackDirector.register_enemy(enemy)

	var cam := Camera3D.new()
	cam.name = "TestCamera"
	add_child(cam)
	cam.current = true
	# Behind the player, looking away from the enemy (+Z).
	cam.global_position = Vector3(0, 1.8, 4)
	cam.look_at(Vector3(0, 1.3, 12))
	cam.reset_physics_interpolation()
	await get_tree().process_frame
	check(get_viewport().get_camera_3d() == cam, "test camera is the viewport camera")
	check(not cam.is_position_in_frustum(enemy.get_aim_point()), "enemy is outside the frustum")

	var granted := false
	var t0 := AttackDirector.now()
	while AttackDirector.now() - t0 < 1.0:
		granted = granted or AttackDirector.request_token(enemy)
		await get_tree().physics_frame
	check(not granted, "camera facing away: no token in 1 s")
	check(not AttackDirector.is_on_screen(enemy), "director reports off screen")

	# Turn toward the enemy.
	cam.look_at(Vector3(0, 1.3, -3))
	cam.reset_physics_interpolation()
	var turned_at := AttackDirector.now()
	await get_tree().process_frame
	check(cam.is_position_in_frustum(enemy.get_aim_point()), "enemy inside the frustum after turning")
	var granted_at := -1.0
	while AttackDirector.now() - turned_at < 1.5:
		if AttackDirector.request_token(enemy):
			granted_at = AttackDirector.now()
			break
		await get_tree().physics_frame
	var waited := granted_at - turned_at
	check(granted_at > 0.0, "camera facing the enemy: token granted (after %.3f s)" % waited)
	check(waited >= Tuning.ONSCREEN_BEFORE_TOKEN - 0.001 and waited < Tuning.ONSCREEN_BEFORE_TOKEN + 0.15,
		"granted after the on-screen delay (%.3f s, rule %.2f s)" % [waited, Tuning.ONSCREEN_BEFORE_TOKEN])

	# Leaving the view resets the clock.
	AttackDirector.release_token(enemy)
	cam.look_at(Vector3(0, 1.3, 12))
	cam.reset_physics_interpolation()
	await get_tree().process_frame
	await get_tree().process_frame
	check(not AttackDirector.request_token(enemy), "off screen again: no token")
	check(AttackDirector.onscreen_time(enemy) == 0.0, "on-screen clock reset when leaving the view")

	cam.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	check(AttackDirector.is_on_screen(enemy), "no camera: everyone counts as on screen")

	AttackDirector.reset()
	print("[ai] test_onscreen: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
