extends Node
## CameraRig under Round 7 (docs/Round 7 — Freeflow Combat.md: Camera): free
## camera (only input turns it with no combat target), no lock-on anywhere
## (Acceptance 10: the legacy lock actions and their old keys do nothing, the
## lock API is gone, get_lock_target() is null every frame), get_soft_target()
## is the player's combat target, sensitivity, pitch clamp, WORLD-only
## collision with fading blockers, no camera in concrete, launch framing (pull
## back and lean, no follow-cam; F1 in depth: test_cam_launch), down mode keeps
## the pelvis in view, the last-kill close-up (GameEvents.last_kill: a side-on
## cut, then back to the player's yaw), mode-change rate limit, KO, hit feel
## (kick, the teleport counter's FOV punch, the Round 7 weight punch). Lean,
## auto-yaw, glides, drive and throw: test_cam_freeflow; pursuit and spike:
## test_cam_godpath. Real player, real input events, no ray_override.

var _fails := 0
var _lock_events: Array = []

func _ready() -> void:
	for i in 5:
		await get_tree().process_frame
	if GameEvents.has_signal(&"lock_on_changed"):
		GameEvents.connect(&"lock_on_changed", func(_f: Node3D, t: Node3D) -> void: _lock_events.append(t))
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

func _press(action: StringName) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	await _frames(2)
	Input.parse_input_event(up)
	await _frames(2)

## A raw key or mouse button press and release (the old lock-on bindings).
func _press_raw(ev: InputEvent) -> void:
	var up: InputEvent = ev.duplicate()
	ev.set(&"pressed", true)
	up.set(&"pressed", false)
	Input.parse_input_event(ev)
	await _frames(2)
	Input.parse_input_event(up)
	await _frames(2)

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

func _place(f: Fighter, pos: Vector3, face := Vector3.ZERO) -> void:
	if f.has_method(&"teleport_to"):
		f.teleport_to(pos, face)
	else:
		f.global_position = pos
		f.reset_physics_interpolation()

func _yaw_err(a: float, b: float) -> float:
	return absf(wrapf(a - b, -PI, PI))

## Distance from the camera's centre ray to a world point.
func _ray_dist(cam: Camera3D, p: Vector3) -> float:
	var xf := cam.get_camera_transform()
	var d := -xf.basis.z
	var v := p - xf.origin
	return (v - d * v.dot(d)).length()

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
	var e1 := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis.looking_at(Vector3.BACK), Vector3(0, 0.05, -0.5)))
	AttackDirector.set_player(player)
	var rig := CameraRig.new()
	rig.target = player
	add_child(rig)
	CameraRig.sensitivity = 1.0
	CameraRig.invert_y = false
	await _wait_real(1.0)
	var cam := rig.camera

	# --- Basics -----------------------------------------------------------------
	_check(rig.is_in_group(&"camera_rig") and get_viewport().get_camera_3d() == cam, "rig in group, camera current")
	_check(rig.arm.collision_mask == Layers.WORLD, "camera collides with WORLD only")
	_check(rig.get_mode() == CameraRig.Mode.COMBAT and not rig.is_locked() and rig.get_lock_target() == null, "free combat camera by default")
	var vp := get_viewport().get_visible_rect()
	var sp := cam.unproject_position(player.get_aim_point())
	_check(sp.x < vp.size.x * 0.46, "player left of centre (%.0f%%)" % (100.0 * sp.x / vp.size.x))
	_check(is_zero_approx(cam.h_offset), "no projection offset (the shoulder shift is collision-checked)")

	# --- Free: nothing but input turns it -------------------------------------------
	rig.apply_manual_input(Vector2(0.9, 0.0))  # look away from the enemy
	var yaw0 := rig._yaw
	await _wait_real(3.0)
	_check(_yaw_err(rig._yaw, yaw0) < 0.0001, "3 s with an enemy near and no input: yaw unchanged")
	rig.snap_behind()
	await _frames(3)
	_place(player, Vector3(0, 0.05, 4), Vector3.BACK)   # face away from the enemy
	await _frames(3)
	rig.snap_behind()
	await _frames(3)
	var yaw_run := rig._yaw
	Input.action_press(&"move_forward")
	var drift := 0.0
	var until := TimeDirector.now() + 3.0
	while TimeDirector.now() < until:
		await get_tree().process_frame
		drift = maxf(drift, _yaw_err(rig._yaw, yaw_run))
	Input.action_release(&"move_forward")
	_check(drift < 0.0001, "holding W away from the enemy for 3 s does not turn the camera (max %.4f rad)" % drift)
	_check(player.global_position.distance_to(Vector3(0, 0.05, 4)) > 2.0, "the player did run (%.1f m)" % player.global_position.distance_to(Vector3(0, 0.05, 4)))

	# --- Sensitivity and pitch clamp ----------------------------------------------------
	var y1 := rig._yaw
	rig._mouse_delta = Vector2(100.0, 0.0)
	await _frames(1)
	var turn1 := _yaw_err(rig._yaw, y1)
	CameraRig.sensitivity = 2.0
	var y2 := rig._yaw
	rig._mouse_delta = Vector2(100.0, 0.0)
	await _frames(1)
	var turn2 := _yaw_err(rig._yaw, y2)
	CameraRig.sensitivity = 1.0
	_check(absf(turn1 - 100.0 * Tuning.CAM_MOUSE_SENS * CameraRig.mouse_scale()) < 0.002, "100 px turns %.3f rad at sensitivity 1 (CAM_MOUSE_SENS)" % turn1)
	_check(absf(turn2 - 2.0 * turn1) < 0.002, "sensitivity 2 doubles it (%.3f)" % turn2)
	rig.apply_manual_input(Vector2(0.0, -4.0))
	await _frames(3)
	_check(rig.get_view_pitch() <= deg_to_rad(Tuning.CAM_PITCH_RANGE.y) + 0.001 and cam.global_position.y > 0.3, "pitch <= +20 deg and above the floor")
	rig.apply_manual_input(Vector2(0.0, 8.0))
	await _frames(3)
	_check(rig.get_view_pitch() >= deg_to_rad(Tuning.CAM_PITCH_RANGE.x) - 0.001, "pitch >= -35 deg (%.1f)" % rad_to_deg(rig.get_view_pitch()))
	rig.apply_manual_input(Vector2(0.0, -rig._pitch + CameraRig.PITCH_DEFAULT))

	# --- No lock-on anywhere (Acceptance 10, the rig's part) ---------------------------------------
	_place(player, Vector3(0, 0.05, 4), Vector3.FORWARD)
	var e2 := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis.looking_at(Vector3.BACK), Vector3(-2.6, 0.05, -1.0)))
	var e3 := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis.looking_at(Vector3.BACK), Vector3(2.6, 0.05, -1.0)))
	await _frames(3)
	rig.snap_behind()
	await _wait_real(0.5)
	var gone := PackedStringArray()
	for m: StringName in [&"toggle_lock", &"unlock", &"cycle_lock", &"recentre", &"get_lock_aim_point", &"get_lock_aim",
			&"_set_lock", &"_lock_frame", &"_update_lock_validity", &"_pick_lock_candidate", &"_update_soft_target"]:
		if rig.has_method(m):
			gone.append(String(m))
	_check(gone.is_empty(), "the rig has no lock-on or soft-target picking API left (%s)" % (", ".join(gone) if not gone.is_empty() else "none"))
	var src: String = (load("res://scripts/game/camera_rig.gd") as GDScript).source_code
	var found := PackedStringArray()
	for needle: String in ['&"lock_on"', '&"lock_next"', '&"lock_prev"', "lock_on_changed", "LOCK_"]:
		if src.contains(needle):
			found.append(needle)
	_check(src.length() > 1000 and found.is_empty(), "the rig's code reads no lock action, emits no lock event, uses no LOCK_ tuning (%s)" % (
		", ".join(found) if not found.is_empty() else "none found"))
	# The legacy lock actions (registered without bindings) and the old lock keys
	# (Tab, middle mouse, wheel) through the real input path: nothing happens.
	var yaw_nl := rig._yaw
	var pitch_nl := rig._pitch
	_lock_events.clear()
	var sent := 0
	for a: StringName in [&"lock_on", &"lock_next", &"lock_prev"]:
		if InputMap.has_action(a):
			await _press(a)
			sent += 1
	var tab := InputEventKey.new()
	tab.keycode = KEY_TAB
	tab.physical_keycode = KEY_TAB
	await _press_raw(tab)
	for b: MouseButton in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var mb := InputEventMouseButton.new()
		mb.button_index = b
		await _press_raw(mb)
	var locked_frames := 0
	var lock_frames := 0
	until = TimeDirector.now() + 1.0
	while TimeDirector.now() < until:
		await get_tree().process_frame
		lock_frames += 1
		if rig.get_lock_target() != null or rig.is_locked():
			locked_frames += 1
	print("  no lock-on: %d legacy lock actions and Tab / MMB / wheel sent; yaw moved %.4f rad, pitch %.4f; lock events %d; locked on %d / %d frames" % [
		sent, _yaw_err(rig._yaw, yaw_nl), absf(rig._pitch - pitch_nl), _lock_events.size(), locked_frames, lock_frames])
	_check(_yaw_err(rig._yaw, yaw_nl) < 0.0001 and absf(rig._pitch - pitch_nl) < 0.0001,
		"the old lock buttons neither lock nor recentre the camera (yaw and pitch unchanged)")
	_check(locked_frames == 0 and _lock_events.is_empty(), "get_lock_target() null and is_locked() false on every frame; no lock_on_changed")
	var ct = player.combat.get_combat_target() if player.combat != null else null
	_check(rig.get_soft_target() == ct, "get_soft_target() is the player's combat target (%s)" % [str(ct)])
	_check(rig.get_soft_target() == null or not rig.get_soft_target().is_down(), "never a downed fighter")
	e1.apply_damage(99999.0, &"test")
	_place(e3, Vector3(30, 0.05, 30))
	await _frames(4)
	_check(rig.get_soft_target() != e1, "a dead enemy is never the soft target")

	# --- Walls: breakables fade, concrete collides, the camera is never inside it ---------------
	_place(e2, Vector3(0, 0.05, -1.0), Vector3.BACK)
	_place(player, Vector3(0, 0.05, 4), Vector3.FORWARD)
	rig.snap_behind()
	await _wait_real(0.8)
	var back := rig.get_flat_basis().z
	var behind := player.get_aim_point() + back * 1.4
	var panel := _box(Layers.DESTRUCTIBLE, behind, Vector3(5, 3, 0.25), "TestPanel")
	panel.look_at(panel.global_position + back, Vector3.UP)
	await _wait_real(0.5)
	_check(rig._arm_len > Tuning.CAM_MIN_DIST and rig.get_blockers().has("TestPanel"), "breakable panel: camera not moved, panel faded (%s)" % ", ".join(rig.get_blockers()))
	panel.queue_free()
	var concrete := _box(Layers.WORLD, player.get_aim_point() + back * 1.2, Vector3(6, 4, 0.3), "TestConcrete")
	concrete.look_at(concrete.global_position + back, Vector3.UP)
	var inside := 0
	var in_player := 0
	var n := 0
	var space := rig.get_world_3d().direct_space_state
	var sph := SphereShape3D.new()
	sph.radius = 0.1
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sph
	q.collision_mask = Layers.WORLD
	until = TimeDirector.now() + 1.0
	while TimeDirector.now() < until:
		await get_tree().process_frame
		n += 1
		q.transform = Transform3D(Basis(), cam.get_camera_transform().origin)
		if not space.intersect_shape(q, 1).is_empty():
			inside += 1
		if cam.global_position.distance_to(player.get_aim_point()) < 0.8 and rig.get_player_fade() < 0.4:
			in_player += 1
	_check(inside == 0, "concrete right behind the player: camera never inside it (%d/%d frames)" % [inside, n])
	_check(in_player == 0, "a camera forced within 0.8 m fades the player (%d unfaded frames)" % in_player)
	_check(rig.get_view_pitch() < deg_to_rad(-20.0), "squeezed: the view tilts down over the player (%.0f deg)" % rad_to_deg(rig.get_view_pitch()))
	_check(cam.is_position_in_frustum(player.get_aim_point()), "squeezed: the player stays in frame")
	concrete.queue_free()
	await _wait_real(1.0)

	# --- Launch framing, never a follow-cam -----------------------------------------------------
	var base_dist := rig.get_distance()
	var yaw_l := rig._yaw
	_launch_by_player(player, e2)
	_place(e2, player.global_position + rig.get_flat_basis() * Vector3(4.0, 1.5, -6.0))
	await _wait_real(0.4)
	_check(rig.get_widen() > 0.5 and rig.get_launch_body() == e2, "a launched body is framed: the look-at leans toward it (%.2f)" % rig.get_widen())
	_check(rig.get_distance() >= base_dist - 0.05 and rig.get_distance() <= Tuning.CAM_LAUNCH_DIST + 0.01,
		"it leans and pulls back only as far as needed (%.2f -> %.2f m, at most %.0f; F1 numbers: test_cam_launch)" % [
		base_dist, rig.get_distance(), Tuning.CAM_LAUNCH_DIST])
	_check(cam.is_position_in_frustum(e2.get_center_of_mass()) and cam.is_position_in_frustum(player.get_aim_point()), "player and body both in frame")
	_check(_yaw_err(rig._yaw, yaw_l) < 0.001, "no yaw while both already fit")
	_check(not rig.is_follow_cam_active() and not AttackDirector.camera_busy, "no follow-cam, tokens not blocked")
	await _wait_real(Tuning.CAM_LAUNCH_FOLLOW)
	_check(rig.get_widen() < 0.01 and rig._launch_lean.length() < 0.1, "the lean is over after %.1f s" % Tuning.CAM_LAUNCH_FOLLOW)
	await _wait_real(1.5)

	# --- Mode-change rate limit ------------------------------------------------------------------
	var t0 := TimeDirector.now() + 2.0
	var c0 := rig.get_mode_changes()
	_check(rig._request_mode(CameraRig.Mode.DOWN, t0, false), "first mode change allowed")
	_check(not rig._request_mode(CameraRig.Mode.COMBAT, t0 + 0.1, false), "second change 0.1 s later refused")
	_check(rig._request_mode(CameraRig.Mode.COMBAT, t0 + Tuning.CAM_MODE_GAP + 0.01, false), "allowed after CAM_MODE_GAP")
	_check(rig.get_mode_changes() == c0 + 2, "exactly two changes")
	rig._mode_changed_at = TimeDirector.now() - 10.0
	rig._blend_t0 = -100.0

	# --- Hit feel ----------------------------------------------------------------------------------
	var kick_info := HitInfo.new()
	kick_info.attacker = player
	kick_info.victim = e2
	kick_info.damage = 60.0
	kick_info.energy = 2600.0
	kick_info.hit_direction = Vector3(0, 0, -1)
	GameEvents.hit_landed.emit(kick_info)
	_check(rig._kick.length() > 0.15, "kick jolts the camera %.2f m" % rig._kick.length())
	GameEvents.teleport_counter.emit(player, e2)
	await _wait_real(0.06)
	_check(rig.get_fov_punch() > 2.0, "a teleport counter punches the FOV (%.2f deg)" % rig.get_fov_punch())
	await _wait_real(0.5)
	rig._fov_amp = 0.0
	GameEvents.teleported.emit(player, player.global_position, player.global_position, &"counter")
	await _wait_real(0.06)
	_check(rig.get_fov_punch() > 2.0, "the player's counter teleport punches the FOV (%.2f deg)" % rig.get_fov_punch())
	TimeDirector.reset()
	await _wait_real(0.5)
	# Round 7: a player hit (react set) punches the FOV by its weight (the counter move here).
	var counter := HitInfo.new()
	counter.attacker = player
	counter.victim = e2
	counter.move_id = &"counter"
	counter.counter = true
	counter.react = Tuning.R7_MOVES[&"counter"]["react"]
	counter.weight = Tuning.R7_MOVES[&"counter"]["weight"]
	counter.tier = HitInfo.Tier.STAGGER
	counter.hit_position = e2.get_aim_point()
	counter.hit_direction = Vector3(0, 0, -1)
	GameEvents.hit_landed.emit(counter)
	await _wait_real(0.06)
	var want_punch := float(Tuning.R7_MOVES[&"counter"]["weight"]) * Tuning.R7_CAM_PUNCH_FOV
	_check(absf(rig.get_fov_punch() - want_punch) < 0.15, "the counter punches the FOV by its weight (%.2f deg, want %.2f)" % [rig.get_fov_punch(), want_punch])
	await _wait_real(0.5)

	# --- Last-kill close-up: a cut to the side, player in frame, yaw restored ------------------------
	_place(e2, player.global_position + player.get_forward() * 1.5, Vector3.BACK)
	await _frames(3)
	var yaw_before := rig._yaw
	GameEvents.last_kill.emit(e2)
	await _frames(1)
	var line := e2.global_position - player.global_position
	var along := atan2(-line.x, -line.z)
	var side_err := absf(absf(wrapf(rig._yaw - along, -PI, PI)) - PI * 0.5)
	_check(rig.get_mode() == CameraRig.Mode.CLOSEUP and side_err < 0.1, "last kill: the next frame cuts to the side (%.0f deg off side-on)" % rad_to_deg(side_err))
	_check(absf(Engine.time_scale - float(Tuning.SLOW_TIME[&"last_kill"]["scale"])) < 0.01, "with TimeDirector's last-kill slow motion (%.2fx)" % Engine.time_scale)
	await _wait_real(0.3)
	var cd := cam.global_position.distance_to(rig._pivot)
	_check(absf(cd - Tuning.CAM_LAST_KILL_DIST) < 0.4, "close at %.1f m (%.2f)" % [Tuning.CAM_LAST_KILL_DIST, cd])
	_check(cam.is_position_in_frustum(player.get_aim_point()) and cam.is_position_in_frustum(e2.get_aim_point()), "both fighters in the close-up")
	rig.apply_manual_input(Vector2(0.5, 0.0))
	_check(rig.get_mode() == CameraRig.Mode.CLOSEUP and absf(rig._yaw - rig._cine_yaw) < 0.05, "camera input does not fight the close-up")
	await _wait_real(float(Tuning.SLOW_TIME[&"last_kill"]["time"]) + 1.0)
	_check(rig.get_mode() == CameraRig.Mode.COMBAT and _yaw_err(rig._yaw, yaw_before) < 0.05, "eased back to combat with the player's yaw")
	TimeDirector.reset()

	# --- Player down: pelvis stays in view, no orbit --------------------------------------------------
	await _wait_real(Tuning.CAM_MODE_GAP + 0.1)
	player.launch(Vector3(0, 4.0, 9.0), player.get_aim_point())
	var down_frames := 0
	var pelvis_in := 0
	var yaw_at := rig._yaw
	var yaw_drift := 0.0
	until = TimeDirector.now() + 2.5
	while TimeDirector.now() < until:
		await get_tree().process_frame
		if rig.get_mode() == CameraRig.Mode.DOWN:
			down_frames += 1
			yaw_drift = maxf(yaw_drift, _yaw_err(rig._yaw, yaw_at))
			if cam.is_position_in_frustum(rig._pelvis(player)):
				pelvis_in += 1
	_check(down_frames > 30, "down mode while the player is launched (%d frames)" % down_frames)
	_check(pelvis_in == down_frames, "pelvis in view every down frame (%d/%d)" % [pelvis_in, down_frames])
	_check(yaw_drift < 0.001, "no orbit while down")

	# --- KO, freed targets ---------------------------------------------------------------------------
	rig.start_orbit(e2)
	await _frames(10)
	_check(rig.get_mode() == CameraRig.Mode.KO, "KO mode on start_orbit")
	rig.stop_orbit()
	var e4 := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(2, 0.05, 0)))
	await _frames(2)
	rig.start_closeup(e4)
	e4.queue_free()
	await _frames(6)
	_check(true, "close-up target freed without errors")
	rig.queue_free()
	await _frames(2)
	_check(not AttackDirector.camera_busy, "camera_busy false after the rig is freed")
