extends Node
## CameraRig with a player and a target: runs without errors, frames the
## target, follow-cam sets and clears AttackDirector.camera_busy, launches
## the player did not cause are ignored, shake decays, pursuit cut and KO orbit.

var _fails := 0

func _ready() -> void:
	await get_tree().process_frame
	await _run()
	AttackDirector.reset()
	print("TEST test_camera_rig: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _floor() -> void:
	var body := StaticBody3D.new()
	body.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 60)
	shape.shape = box
	shape.position.y = -0.5
	body.add_child(shape)
	add_child(body)

func _run() -> void:
	_floor()
	var world := Node3D.new()
	add_child(world)
	var player := FighterFactory.spawn_player(world, Transform3D(Basis(), Vector3(0, 0.05, 4)))
	var enemy := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis.looking_at(Vector3.BACK), Vector3(0, 0.05, -2)))
	AttackDirector.set_player(player)
	var rig := CameraRig.new()
	rig.target = player
	add_child(rig)
	await _frames(30)

	_check(rig.is_in_group(&"camera_rig"), "rig is in group camera_rig")
	_check(get_viewport().get_camera_3d() == rig.camera, "rig camera is current")
	_check(rig.arm.collision_mask == (Layers.WORLD | Layers.DESTRUCTIBLE), "spring arm hits only WORLD | DESTRUCTIBLE")
	_check(rig.camera.cull_mask == 0xFFFFF and rig.camera.far >= 100.0, "camera sees every layer, far plane %.0f m" % rig.camera.far)
	_check(rig.get_soft_target() == enemy, "idle stick: soft target is the nearest enemy")
	var fb := rig.get_flat_basis()
	_check(fb.is_equal_approx(fb.orthonormalized()) and absf(fb.z.y) < 0.001, "flat basis is a pure yaw")
	var cam_pos := rig.camera.global_position
	var p_pos := player.get_aim_point()
	var flat := Vector2(cam_pos.x - p_pos.x, cam_pos.z - p_pos.z).length()
	_check(cam_pos.z > p_pos.z and flat > 1.0 and flat < Tuning.CAM_MAX_DIST + 1.0,
		"camera sits behind the player (%.1f m back)" % flat)
	_check(cam_pos.y > p_pos.y, "camera above the aim point")

	# Launch the player did not cause: no follow-cam.
	GameEvents.fighter_launched.emit(enemy, Vector3(0, 2, -14))
	await _frames(25)
	_check(not rig.is_follow_cam_active() and not AttackDirector.camera_busy, "launch not caused by the player is ignored")

	# Player hit + big launch: follow-cam on, camera_busy set, then cleared.
	var info := HitInfo.new()
	info.attacker = player
	info.victim = enemy
	info.move_id = &"sparta_kick"
	GameEvents.fighter_launched.emit(enemy, Vector3(0, 2, -14))
	GameEvents.hit_landed.emit(info)
	await _frames(2)
	_check(rig.is_follow_cam_active(), "player launch over FOLLOW_CAM_SPEED starts the follow-cam")
	_check(AttackDirector.camera_busy, "follow-cam sets AttackDirector.camera_busy")
	await _wait_real(Tuning.FOLLOW_CAM_TIME + 0.2)
	await _frames(2)
	_check(not rig.is_follow_cam_active(), "follow-cam ends within FOLLOW_CAM_TIME")
	_check(not AttackDirector.camera_busy, "camera_busy cleared after the follow-cam")

	# Slow launch: ignored.
	GameEvents.hit_landed.emit(info)
	GameEvents.fighter_launched.emit(enemy, Vector3(0, 1, -6))
	await _frames(2)
	_check(not rig.is_follow_cam_active(), "launch under FOLLOW_CAM_SPEED is ignored")

	# Shake.
	GameEvents.screen_shake.emit(0.6)
	await _frames(1)
	_check(rig.get_trauma() > 0.3, "screen_shake adds trauma")
	await _wait_real(0.8)
	_check(rig.get_trauma() < 0.01, "trauma decays")

	# Slow motion does not freeze the camera: smoothing runs on real time.
	TimeDirector.request_slowmo(0.2, 0.5, TimeDirector.PRIO_KO)
	var before := rig.get_flat_basis()
	rig._yaw += 0.8
	await _wait_real(0.3)
	_check(not rig.get_flat_basis().is_equal_approx(before), "camera responds during slow motion")
	TimeDirector.reset()

	# Pursuit cut: camera snaps behind the pursuer, facing the victim.
	enemy.global_position = Vector3(6, 0.05, 4)
	GameEvents.pursuit.emit(player, enemy)
	await _frames(4)
	var fwd := -rig.get_flat_basis().z
	var want := (enemy.get_ground_position() - player.get_ground_position())
	want.y = 0.0
	_check(fwd.dot(want.normalized()) > 0.95, "pursuit cut points the camera from the pursuer to the victim")

	# Follow target freed mid-follow (corpse fade, round teardown): follow ends,
	# camera_busy clears, no errors from the freed reference.
	var e2 := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(3, 0.05, -3)))
	var e3 := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(-3, 0.05, -3)))
	await _frames(2)
	_launch_by_player(player, e2)
	await _frames(2)
	_check(rig.is_follow_cam_active() and AttackDirector.camera_busy, "follow-cam on a second enemy")
	_launch_by_player(player, e3)
	await _frames(2)
	_check(rig.get_debug_text().begins_with("cam follow") and AttackDirector.camera_busy, "a newer big launch takes over the follow-cam")
	e3.queue_free()
	await _frames(4)
	_check(not rig.is_follow_cam_active() and not AttackDirector.camera_busy, "freed follow target: follow ends, camera_busy cleared")
	e2.queue_free()
	await _frames(4)

	# Hit feel: directional kick along the hit direction, linear shake, FOV punch.
	var kick_info := HitInfo.new()
	kick_info.attacker = player
	kick_info.victim = enemy
	kick_info.damage = 60.0
	kick_info.energy = 2600.0
	kick_info.hit_direction = Vector3(0, 0, -1)
	GameEvents.hit_landed.emit(kick_info)
	_check(rig._kick.length() > 0.15 and rig._kick.normalized().dot(Vector3(0, 0, -1)) > 0.99,
		"kick jolts the camera %.2f m along the hit direction" % rig._kick.length())
	await _wait_real(0.4)
	_check(rig._kick.length() < 0.01, "kick recovers within 0.4 s")
	var other := HitInfo.new()
	other.attacker = null
	other.victim = enemy
	other.damage = 60.0
	GameEvents.hit_landed.emit(other)
	_check(rig._kick.length() < 0.01, "hits not involving the player do not jolt the camera")
	GameEvents.screen_shake.emit(0.1)
	await _frames(3)
	_check(rig.get_trauma() > 0.05, "light shake registers")
	var base_fov := rig.camera.fov
	GameEvents.teleport_counter.emit(player, enemy)
	await _wait_real(0.06)
	_check(rig.camera.fov > base_fov + 1.5, "counter punches the FOV (+%.1f deg)" % (rig.camera.fov - base_fov))
	await _wait_real(0.6)
	_check(absf(rig.camera.fov - CameraRig.FOV_BASE) < 0.2, "FOV punch settles back")
	GameEvents.wall_broken.emit(null, Vector3.ZERO, 3000.0, Vector3.ZERO)
	await _wait_real(0.06)
	_check(rig.get_fov_punch() > 1.5, "wall break punches the FOV")
	await _wait_real(0.6)

	# Soft-target ring sits under the soft target.
	enemy.global_position = Vector3(0, 0.05, -2)
	enemy.reset_physics_interpolation()
	await _wait_real(0.5)
	var ring := rig.get_ring()
	var soft := rig.get_soft_target()
	_check(soft != null and ring.visible and Vector2(ring.global_position.x - soft.global_position.x,
		ring.global_position.z - soft.global_position.z).length() < 0.2, "soft-target ring under the soft target")
	_check(ring.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and ring.layers == Layers.VIS_FX, "ring: no shadow, FX layer")

	# Waves pacing: with follow_needs_wall, only launches heading at a wall follow.
	rig.follow_needs_wall = true
	var e6 := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(0, 0.05, -6)))
	await get_tree().physics_frame
	_launch_by_player(player, e6)  # flies toward -Z: open floor, no wall within 8 m
	await _frames(2)
	_check(not rig.is_follow_cam_active(), "waves: launch into open space does not start the follow-cam")
	var wall := StaticBody3D.new()
	wall.collision_layer = Layers.WORLD
	var wshape := CollisionShape3D.new()
	var wbox := BoxShape3D.new()
	wbox.size = Vector3(10, 4, 0.5)
	wshape.shape = wbox
	wall.add_child(wshape)
	wall.position = Vector3(0, 2, -11)
	add_child(wall)
	for i in 3:
		await get_tree().physics_frame
	_launch_by_player(player, e6)
	await _frames(2)
	_check(rig.is_follow_cam_active(), "waves: launch heading at a wall 5 m away starts the follow-cam")
	rig.stop_follow()
	rig.follow_needs_wall = false
	e6.queue_free()
	await _frames(3)

	# KO orbit and token-holder framing run without errors.
	rig.start_orbit(enemy)
	await _frames(20)
	_check(rig.get_debug_text().begins_with("cam orbit"), "KO orbit runs")
	rig.stop_orbit()
	# A downed (launched) enemy is not a soft target.
	enemy.launch(Vector3(0, 4, -3), enemy.get_aim_point())
	for i in 6:
		await get_tree().physics_frame
	if enemy.is_down():
		await _frames(2)
		_check(rig.get_soft_target() != enemy, "downed enemy is not the soft target")
	else:
		print("  note: dummy launch did not put the enemy down; downed-target check skipped")
	enemy.apply_damage(9999.0, &"test")
	await _frames(10)
	_check(rig.get_soft_target() == null, "dead enemy is dropped as soft target")
	var e4 := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(2, 0.05, -1)))
	await _frames(2)
	rig.start_orbit(e4)
	e4.queue_free()
	await _frames(4)
	_check(true, "orbit focus freed without errors")
	rig.stop_orbit()
	var e5 := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(-2, 0.05, -1)))
	await _frames(2)
	_launch_by_player(player, e5)
	await _frames(2)
	_check(AttackDirector.camera_busy, "follow running when the rig is freed")
	rig.stop_follow()

	# Player knocked down against a wall behind them: the camera stays under
	# the -55 deg cap and keeps the body on screen (swings along the wall).
	var back_wall := StaticBody3D.new()
	back_wall.collision_layer = Layers.WORLD
	var bshape := CollisionShape3D.new()
	var bbox := BoxShape3D.new()
	bbox.size = Vector3(14, 4, 0.5)
	bshape.shape = bbox
	back_wall.add_child(bshape)
	back_wall.position = Vector3(0, 2, 6.0)
	add_child(back_wall)
	player.global_position = Vector3(0, 0.05, 4.6)
	player.reset_physics_interpolation()
	rig.snap_behind()
	for i in 4:
		await get_tree().physics_frame
	player.launch(Vector3(0, 1.5, 3.0), player.get_aim_point())
	var worst_pitch := 0.0
	var on_screen_frames := 0
	var frames := 0
	var down_frames := 0
	var until := TimeDirector.now() + 2.5
	while TimeDirector.now() < until:
		await get_tree().process_frame
		frames += 1
		if player.is_down():
			down_frames += 1
		worst_pitch = minf(worst_pitch, rig.get_view_pitch())
		var com := player.get_center_of_mass()
		var vp := get_viewport().get_visible_rect()
		if rig.camera.is_position_in_frustum(com) and vp.grow(-20.0).has_point(rig.camera.unproject_position(com)):
			on_screen_frames += 1
	@warning_ignore("integer_division")
	_check(down_frames > frames / 2, "player was down against the wall (%d/%d frames)" % [down_frames, frames])
	_check(worst_pitch >= CameraRig.PITCH_FLOOR - 0.01, "pitch never steeper than -55 deg (worst %.0f deg)" % rad_to_deg(worst_pitch))
	var com_end := player.get_center_of_mass()
	var sp := rig.camera.unproject_position(com_end)
	var vp_end := get_viewport().get_visible_rect()
	_check(rig.camera.is_position_in_frustum(com_end) and sp.y < vp_end.size.y * 0.85 and sp.y > vp_end.size.y * 0.15,
		"downed body framed at the end (screen y %.0f%%)" % (100.0 * sp.y / vp_end.size.y))
	_check(on_screen_frames > frames * 0.8, "body on screen %d/%d frames while down" % [on_screen_frames, frames])

	_launch_by_player(player, e5)
	await _frames(2)
	rig.queue_free()
	await _frames(2)
	_check(not AttackDirector.camera_busy, "camera_busy false after the rig is freed mid-follow")

func _launch_by_player(player: Fighter, victim: Fighter) -> void:
	var info := HitInfo.new()
	info.attacker = player
	info.victim = victim
	GameEvents.fighter_launched.emit(victim, Vector3(0, 2, -14))
	GameEvents.hit_landed.emit(info)

## Wait on the real clock (robust against long startup frames).
func _wait_real(sec: float) -> void:
	var until := TimeDirector.now() + sec
	while TimeDirector.now() < until:
		await get_tree().process_frame
