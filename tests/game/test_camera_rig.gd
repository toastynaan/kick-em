extends Node
## CameraRig (Upgrade 2 camera rules): no follow-cam (a fast launch widens the
## frame instead), pitch clamp, no auto-rotation within 1 s of mouse input then
## ease back, mode-change rate limit, spring arm collides with WORLD only and
## DESTRUCTIBLE blockers are reported for fading, down mode looks at the pelvis
## without orbiting, finisher close-up, KO, hit kick, FOV punch, soft-target
## ring, freed-target safety.

var _fails := 0

func _ready() -> void:
	for i in 5:
		await get_tree().process_frame
	await _run()
	AttackDirector.reset()
	TimeDirector.reset()
	print("TEST test_camera_rig: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _wait_real(sec: float) -> void:
	var until := TimeDirector.now() + sec
	while TimeDirector.now() < until:
		await get_tree().process_frame

func _box(layer: int, pos: Vector3, size: Vector3, nm: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = nm
	body.collision_layer = layer
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = pos
	add_child(body)
	return body

func _launch_by_player(player: Fighter, victim: Fighter, v := Vector3(0, 2, -14)) -> void:
	var info := HitInfo.new()
	info.attacker = player
	info.victim = victim
	GameEvents.fighter_launched.emit(victim, v)
	GameEvents.hit_landed.emit(info)

func _run() -> void:
	_box(Layers.WORLD, Vector3(0, -0.5, 0), Vector3(80, 1, 80), "Floor")
	var world := Node3D.new()
	add_child(world)
	var player := FighterFactory.spawn_player(world, Transform3D(Basis(), Vector3(0, 0.05, 4)))
	var enemy := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis.looking_at(Vector3.BACK), Vector3(0, 0.05, -1)))
	AttackDirector.set_player(player)
	var rig := CameraRig.new()
	rig.target = player
	add_child(rig)
	await _wait_real(1.2)

	# --- Basics -------------------------------------------------------------
	_check(rig.is_in_group(&"camera_rig") and get_viewport().get_camera_3d() == rig.camera, "rig in group, camera current")
	_check(rig.arm.collision_mask == Layers.WORLD, "spring arm collides with WORLD only (rule 4)")
	_check(rig.camera.cull_mask == 0xFFFFF and rig.camera.far >= 100.0, "camera sees every layer, far %.0f m" % rig.camera.far)
	_check(rig.get_soft_target() == enemy, "soft target is the nearest enemy")
	_check(rig.get_mode() == CameraRig.Mode.COMBAT, "combat mode (%s)" % rig.get_mode_name())
	var cam_pos := rig.camera.global_position
	var flat := Vector2(cam_pos.x - player.global_position.x, cam_pos.z - player.global_position.z).length()
	_check(cam_pos.z > player.global_position.z and flat >= 1.0, "camera behind the player (%.1f m)" % flat)
	_check(rig._out_dist >= Tuning.CAM_COMBAT_DIST.x - 0.05 and rig._out_dist <= Tuning.CAM_COMBAT_DIST.y + 0.05,
		"combat distance %.2f m in CAM_COMBAT_DIST" % rig._out_dist)
	var vp := get_viewport().get_visible_rect()
	var sp := rig.camera.unproject_position(player.get_aim_point())
	_check(sp.x < vp.size.x * 0.5 - vp.size.x * 0.04, "player sits left of centre (%.0f%% of width)" % (100.0 * sp.x / vp.size.x))
	_check(rig.camera.is_position_in_frustum(enemy.get_aim_point()), "soft target in frame")

	# --- Pitch clamp (rule 5) ---------------------------------------------------
	rig.apply_manual_input(Vector2(0.0, -4.0))   # look far up
	await _frames(3)
	_check(rig.get_view_pitch() <= deg_to_rad(Tuning.CAM_PITCH_RANGE.y) + 0.001, "pitch <= +%.0f deg (%.1f)" % [Tuning.CAM_PITCH_RANGE.y, rad_to_deg(rig.get_view_pitch())])
	_check(rig.camera.global_position.y > 0.3, "camera stays above the floor looking up (y %.2f)" % rig.camera.global_position.y)
	rig.apply_manual_input(Vector2(0.0, 8.0))    # look far down
	await _frames(3)
	_check(rig.get_view_pitch() >= deg_to_rad(Tuning.CAM_PITCH_RANGE.x) - 0.001, "pitch >= %.0f deg (%.1f)" % [Tuning.CAM_PITCH_RANGE.x, rad_to_deg(rig.get_view_pitch())])
	_check(rig._out_dist >= Tuning.CAM_MIN_DIST, "distance >= CAM_MIN_DIST")

	# --- Mouse idle, then ease back (rule 6) ------------------------------------
	await _wait_real(Tuning.CAM_MOUSE_IDLE + 1.0)
	var lock_yaw := rig._yaw
	rig.apply_manual_input(Vector2(1.0, 0.0))
	var turned := rig._yaw
	await _wait_real(Tuning.CAM_MOUSE_IDLE * 0.8)
	_check(absf(wrapf(rig._yaw - turned, -PI, PI)) < 0.01, "no auto-rotation within %.1f s of mouse input" % Tuning.CAM_MOUSE_IDLE)
	await _wait_real(Tuning.CAM_MOUSE_IDLE * 0.2 + Tuning.CAM_RETURN_TIME + 0.15)
	_check(absf(wrapf(rig._yaw - lock_yaw, -PI, PI)) < 0.12, "eases back behind the player after the idle time (off %.2f rad)" % absf(wrapf(rig._yaw - lock_yaw, -PI, PI)))

	# --- Mode-change rate limit (rule 7) ----------------------------------------
	var t0 := TimeDirector.now() + 2.0  # well clear of earlier changes
	var c0 := rig.get_mode_changes()
	_check(rig._request_mode(CameraRig.Mode.DOWN, t0, false), "first mode change allowed")
	_check(not rig._request_mode(CameraRig.Mode.COMBAT, t0 + 0.1, false), "second change 0.1 s later refused")
	_check(not rig._request_mode(CameraRig.Mode.COMBAT, t0 + Tuning.CAM_MODE_GAP - 0.05, false), "refused until CAM_MODE_GAP")
	_check(rig._request_mode(CameraRig.Mode.COMBAT, t0 + Tuning.CAM_MODE_GAP + 0.01, false), "allowed after CAM_MODE_GAP")
	_check(rig.get_mode_changes() == c0 + 2, "exactly two changes")
	rig._mode_changed_at = TimeDirector.now() - 10.0
	rig._blend_t0 = -100.0

	# --- Spring arm ignores DESTRUCTIBLE; the blocker is faded instead (rule 4) --
	await _wait_real(0.6)
	var back := rig.get_flat_basis().z
	var behind := player.get_aim_point() + back * 1.2
	var panel := _box(Layers.DESTRUCTIBLE, behind, Vector3(4, 3, 0.25), "TestPanel")
	panel.look_at(panel.global_position + back, Vector3.UP)
	await _wait_real(0.5)
	_check(rig._arm_len > Tuning.CAM_MIN_DIST and absf(rig._arm_len - rig._out_dist) < 0.15,
		"breakable panel behind the player does not move the camera (arm %.2f / %.2f)" % [rig._arm_len, rig._out_dist])
	_check(rig.get_blockers().has("TestPanel"), "panel reported as a view blocker to fade (%s)" % ", ".join(rig.get_blockers()))
	_check(rig.get_debug_text().contains("TestPanel"), "F3 text names the blocker")
	panel.queue_free()
	var concrete := _box(Layers.WORLD, behind, Vector3(4, 3, 0.25), "TestConcrete")
	concrete.look_at(concrete.global_position + back, Vector3.UP)
	await _wait_real(0.4)
	_check(rig._arm_len < rig._out_dist - 1.0, "concrete (WORLD) behind the player does collide (arm %.2f of %.2f)" % [rig._arm_len, rig._out_dist])
	concrete.queue_free()
	await _wait_real(1.5)

	# --- Widen, never follow (rule 1) ---------------------------------------------
	var base_fov := rig.camera.fov
	var base_dist := rig._out_dist
	var e2 := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(0.5, 0.05, -1)))
	await _frames(3)
	_launch_by_player(player, e2)
	e2.global_position = Vector3(0.5, 1.0, -6.0)   # 10 m out, ahead of the camera
	e2.reset_physics_interpolation()
	await _wait_real(0.5)
	var look_err := rig._out_look.distance_to(player.get_aim_point())
	_check(rig.get_widen() > 0.2, "a body sent > %.0f m widens the frame (%.2f)" % [Tuning.CAM_WIDEN_TRIGGER, rig.get_widen()])
	_check(rig.camera.fov > base_fov + 1.5 and rig.camera.fov <= base_fov + Tuning.CAM_WIDEN_FOV + 0.1,
		"FOV widened %.1f deg (max %.0f)" % [rig.camera.fov - base_fov, Tuning.CAM_WIDEN_FOV])
	_check(rig._out_dist > base_dist + 0.3 and rig._out_dist <= base_dist + Tuning.CAM_WIDEN_PULLBACK + 0.6,
		"pulled back %.2f m (max %.0f)" % [rig._out_dist - base_dist, Tuning.CAM_WIDEN_PULLBACK])
	_check(not rig.is_follow_cam_active() and not AttackDirector.camera_busy, "no follow-cam, tokens not blocked")
	_check(look_err < 2.0, "camera still looks at the player (%.2f m off)" % look_err)
	await _wait_real(Tuning.CAM_WIDEN_TIME + 0.8)
	_check(rig.get_widen() < 0.05, "widen released within CAM_WIDEN_TIME (%.2f)" % rig.get_widen())
	# A body that leaves the frame is let go.
	_launch_by_player(player, e2)
	e2.global_position = rig.camera.global_position + rig.get_flat_basis().z * 8.0
	e2.reset_physics_interpolation()
	await _wait_real(0.4)
	_check(rig.get_widen() < 0.05, "a body behind the camera is let go (%.2f)" % rig.get_widen())
	e2.queue_free()
	await _wait_real(0.5)

	# --- Hit feel: kick, shake, FOV punch -------------------------------------------
	var kick_info := HitInfo.new()
	kick_info.attacker = player
	kick_info.victim = enemy
	kick_info.damage = 60.0
	kick_info.energy = 2600.0
	kick_info.hit_direction = Vector3(0, 0, -1)
	GameEvents.hit_landed.emit(kick_info)
	_check(rig._kick.length() > 0.15, "kick jolts the camera %.2f m" % rig._kick.length())
	await _wait_real(0.4)
	_check(rig._kick.length() < 0.01, "kick recovers")
	GameEvents.screen_shake.emit(0.1)
	await _frames(2)
	_check(rig.get_trauma() > 0.05, "light shake registers")
	GameEvents.teleport_counter.emit(player, enemy)
	await _wait_real(0.06)
	_check(rig.get_fov_punch() > 2.0, "counter punches the FOV (+%.1f)" % rig.get_fov_punch())
	await _wait_real(0.6)

	# Strike holes: full punch on the first hole or a full break, light on the rest.
	var fake := _FakePanel.new()
	add_child(fake)
	fake.last_break_by_strike = true
	fake.strike_holes = 2
	GameEvents.wall_broken.emit(fake, Vector3.ZERO, 900.0, Vector3.ZERO)
	await _wait_real(0.06)
	_check(rig.get_fov_punch() <= CameraRig.FOV_PUNCH_MINOR + 0.01, "follow-up strike hole: light punch (+%.1f)" % rig.get_fov_punch())
	await _wait_real(0.5)
	fake.strike_holes = 1
	GameEvents.wall_broken.emit(fake, Vector3.ZERO, 900.0, Vector3.ZERO)
	await _wait_real(0.06)
	_check(rig.get_fov_punch() > 2.0, "first strike hole: full punch (+%.1f)" % rig.get_fov_punch())
	await _wait_real(0.5)
	fake.queue_free()

	# --- Soft-target ring ---------------------------------------------------------------
	var ring := rig.get_ring()
	var soft := rig.get_soft_target()
	_check(soft != null and ring.visible and Vector2(ring.global_position.x - soft.global_position.x,
		ring.global_position.z - soft.global_position.z).length() < 0.25, "soft-target ring under the soft target")

	# --- Finisher close-up (U7) -------------------------------------------------------------
	enemy.global_position = player.global_position + player.get_forward() * 1.5  # finishers are at melee range
	enemy.reset_physics_interpolation()
	await _frames(2)
	rig.start_closeup(enemy, Tuning.FINISHER_CLOSEUP.x)
	await _wait_real(0.35)
	_check(rig.get_mode() == CameraRig.Mode.CLOSEUP, "close-up mode")
	_check(rig._out_dist <= Tuning.FINISHER_CLOSEUP.y + 1.0, "pushed in to %.2f m" % rig._out_dist)
	_check(rig.camera.is_position_in_frustum(player.get_aim_point()), "player stays in frame in the close-up")
	await _wait_real(Tuning.FINISHER_CLOSEUP.x + Tuning.CAM_MODE_GAP + 0.2)
	_check(rig.get_mode() == CameraRig.Mode.COMBAT, "back to combat after the close-up (%s)" % rig.get_mode_name())

	# --- Player down: pelvis, heavy lag, no orbit (rule 8) -------------------------------------
	await _wait_real(Tuning.CAM_MODE_GAP + 0.1)
	player.launch(Vector3(0, 3.0, 2.0), player.get_aim_point())
	var down_seen := false
	var yaw_at_down := 0.0
	var yaw_drift := 0.0
	var pelvis_err := INF
	var until := TimeDirector.now() + 2.0
	while TimeDirector.now() < until:
		await get_tree().process_frame
		if rig.get_mode() == CameraRig.Mode.DOWN:
			if not down_seen:
				down_seen = true
				yaw_at_down = rig._yaw
			yaw_drift = maxf(yaw_drift, absf(wrapf(rig._yaw - yaw_at_down, -PI, PI)))
			pelvis_err = rig._look.distance_to(rig._pelvis(player) + Vector3.UP * 0.3)
	_check(down_seen, "down mode while the player is launched")
	_check(yaw_drift < 0.02, "no orbit while down (yaw drift %.3f rad)" % yaw_drift)
	_check(pelvis_err < 1.0, "looks at the pelvis (%.2f m)" % pelvis_err)
	_check(rig.get_debug_text().begins_with("cam "), "F3 text: %s" % rig.get_debug_text().split("\n")[0])

	# --- KO and freed targets -------------------------------------------------------------------
	rig.start_orbit(enemy)
	await _frames(10)
	_check(rig.get_mode() == CameraRig.Mode.KO, "KO mode on start_orbit")
	rig.stop_orbit()
	var e3 := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(2, 0.05, 0)))
	await _frames(2)
	rig.start_closeup(e3)
	e3.queue_free()
	await _frames(6)
	_check(true, "close-up target freed without errors")
	enemy.apply_damage(9999.0, &"test")
	await _frames(10)
	_check(rig.get_soft_target() == null, "dead enemy is dropped as soft target")
	rig.queue_free()
	await _frames(2)
	_check(not AttackDirector.camera_busy, "camera_busy false after the rig is freed")

## Stand-in for a Destructible with D's round-3 fields.
class _FakePanel extends Node3D:
	var strike_holes := 0
	var last_break_by_strike := false
	var is_broken := false
