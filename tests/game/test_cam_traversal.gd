extends Node
## The camera against the real Traversal (agent M), driven like tests/move:
## - F2: a real sprint to the cap widens the FOV 70 -> 78, pulls back 1.5 m and
##   drops 0.3 m by sprint_charge; a sprint strike's drop to walk eases back.
## - F7b: a real wall run (sprint + Jump by a runnable wall) shifts the camera
##   toward the open side, rolls it away from the wall, and the run wall does
##   not pull the arm in even with the camera behind it.
## - F7: the Yard's biggest fall, a sprint jump off the 1.8 m platform (about
##   3.3 m from the apex), tilts the camera (roll, pitch down) through the drop,
##   easing in and out with no snap; a walk off a 7 m ledge reaches the full 8
##   deg; the heavy landing adds its trauma and the roll clears.
## The camera never turns on its own through any of it.

var _fails := 0
var _rig: CameraRig
var _p: Fighter

func _ready() -> void:
	for i in 3:
		await get_tree().physics_frame
	await _run()
	Tuning.debug_speed_cap = Tuning.SPRINT_CAPS[0]
	TimeDirector.reset()
	print("TEST test_cam_traversal: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _box(center: Vector3, size: Vector3, nm: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = nm
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	add_child(body)
	body.global_position = center
	return body

func _ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _wait_until(cond: Callable, max_ticks: int) -> bool:
	for i in max_ticks:
		if cond.call():
			return true
		await get_tree().physics_frame
	return cond.call()

func _settle(n := 40) -> void:
	_p.move_input = Vector3.ZERO
	if _p.traversal.has_method(&"is_dash_held") and _p.traversal.call(&"is_dash_held"):
		_p.combat.release(CombatController.Action.DASH)
	await _ticks(n)

func _place(pos: Vector3) -> void:
	_p.global_position = pos
	_p.rotation.y = 0.0
	_p.velocity = Vector3.ZERO
	_p.reset_physics_interpolation()
	_rig.snap_behind()

func _run() -> void:
	_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400), "Floor")
	# Runnable concrete wall at x = 1.2 along z 0..-12 (face toward -X), as in tests/move.
	var wall := _box(Vector3(1.2, 2.0, -6.0), Vector3(0.4, 4.0, 12.0), "RunWall")
	wall.add_to_group(&"runnable")
	# A 7 m ledge far off to walk off.
	_box(Vector3(40.0, 3.5, 0.0), Vector3(6.0, 7.0, 6.0), "Ledge")
	# The Yard's 1.8 m platform, long enough to reach the sprint cap on it.
	_box(Vector3(-40.0, 0.9, 0.0), Vector3(6.0, 1.8, 16.0), "Platform")
	_p = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(-20, 0, 20)), Fighter.TEAM_PLAYER)
	_p.name = "Player"
	_rig = CameraRig.new()
	_rig.target = _p
	add_child(_rig)
	await _ticks(30)
	_check(_p.traversal != null and _p.traversal.get_script() != null, "the player has the real Traversal")
	await _sprint()
	await _wall_run(wall)
	await _platform_jump()
	await _fall()

# --- F2 ------------------------------------------------------------------------------------
func _sprint() -> void:
	_place(Vector3(-20, 0.02, 20))
	await _ticks(60)
	var fov0 := _rig.camera.fov
	var d0 := _rig.get_distance()
	var h0 := _rig.get_height()
	var yaw0 := _rig._yaw
	_p.move_input = Vector3.FORWARD
	_p.combat.press(CombatController.Action.DASH)
	var samples := PackedStringArray()
	var t0 := TimeDirector.now()
	var capped := false
	for i in 300:
		await get_tree().physics_frame
		if i % 24 == 0:
			samples.append("%.1fs charge %.2f fov %.1f" % [TimeDirector.now() - t0, _p.traversal.sprint_charge, _rig.camera.fov])
		if _p.traversal.sprint_charge >= 0.999 and not capped:
			capped = true
			await _ticks(60)
			break
	var fov1 := _rig.camera.fov
	var d1 := _rig.get_distance()
	var h1 := _rig.get_height()
	print("  F2 real sprint: ", ", ".join(samples))
	print("  F2 at the cap: fov %.1f -> %.1f, distance %.2f -> %.2f m, height %+.2f -> %+.2f m, yaw moved %.4f rad" % [
		fov0, fov1, d0, d1, h0, h1, absf(wrapf(_rig._yaw - yaw0, -PI, PI))])
	_check(capped, "the real sprint reaches the cap (sprint_charge 1)")
	_check(absf(fov1 - Tuning.CAM_FOV_SPRINT) < 0.3, "F2: FOV %.0f at the 8 m/s cap (%.1f)" % [Tuning.CAM_FOV_SPRINT, fov1])
	_check(absf((d1 - d0) - Tuning.CAM_SPRINT_PULLBACK) < 0.2, "F2: +%.1f m at the cap (+%.2f)" % [Tuning.CAM_SPRINT_PULLBACK, d1 - d0])
	_check(absf((h0 - h1) - Tuning.CAM_SPRINT_DROP) < 0.08, "F2: %.1f m lower at the cap (%.2f)" % [Tuning.CAM_SPRINT_DROP, h0 - h1])
	_check(absf(wrapf(_rig._yaw - yaw0, -PI, PI)) < 0.0001, "the camera does not turn by itself during the sprint")
	# A sprint strike drops you to walk: the FOV eases back, never snaps.
	_p.combat.press(CombatController.Action.LIGHT)
	await _ticks(1)
	_p.combat.release(CombatController.Action.LIGHT)
	var max_drop := 0.0
	var last := _rig.camera.fov
	var charge_after := 1.0
	for i in 90:
		await get_tree().process_frame
		max_drop = maxf(max_drop, last - _rig.camera.fov)
		last = _rig.camera.fov
		charge_after = minf(charge_after, _p.traversal.sprint_charge)
	print("  F2 sprint strike: sprint_charge down to %.2f, largest FOV drop per frame %.2f deg, FOV now %.1f" % [charge_after, max_drop, _rig.camera.fov])
	_check(charge_after < 0.05 and max_drop < 0.6, "F2: a sprint strike eases the FOV back (%.2f deg/frame at most)" % max_drop)
	await _settle(60)

# --- F7b ------------------------------------------------------------------------------------
func _wall_run(wall: StaticBody3D) -> void:
	var started_wall: Array = []
	var cb := func(f: Node3D, w: Node3D, _side: int) -> void:
		if f == _p:
			started_wall.append(w)
	GameEvents.wall_run_started.connect(cb)
	_place(Vector3(0.3, 0.02, 16.0))
	await _ticks(20)
	_p.move_input = Vector3.FORWARD
	_p.combat.press(CombatController.Action.DASH)
	await _wait_until(func() -> bool: return _p.global_position.z <= 0.2, 600)
	var into := deg_to_rad(20.0)
	_p.move_input = Vector3(sin(into), 0.0, -cos(into))
	await _wait_until(func() -> bool: return _p.global_position.z <= -0.8, 60)
	_p.traversal.on_jump_pressed()
	await _ticks(1)
	var running := _p.traversal.is_wall_running()
	_check(running and started_wall.size() == 1 and started_wall[0] == wall, "a real wall run started on the runnable wall")
	if not running:
		GameEvents.wall_run_started.disconnect(cb)
		await _settle()
		return
	# First half: the camera behind (looking -Z), the wall on its right.
	var shift := 0.0
	var roll := 0.0
	var t0 := TimeDirector.now()
	while _p.traversal.is_wall_running() and TimeDirector.now() - t0 < 0.45:
		await get_tree().process_frame
		var rel := _rig._pivot - _p.get_aim_point()
		shift = maxf(shift, rel.dot(_p.traversal.get_wall_normal()))
		roll = maxf(roll, _rig.get_roll_degrees())
	# Second half: swing the camera behind the wall (looking -X); the run wall
	# is out of the casts, so the arm keeps its length.
	_rig._yaw = PI * 0.5
	var arm_min := INF
	var frames := 0
	await _ticks(6)
	while _p.traversal.is_wall_running():
		await get_tree().process_frame
		arm_min = minf(arm_min, _rig.get_arm_length())
		frames += 1
	print("  F7b real wall run: pivot shift toward the open side up to %.2f m, roll up to %+.2f deg; camera behind the wall for %d frames, arm >= %.2f m" % [
		shift, roll, frames, arm_min])
	_check(shift > Tuning.CAM_WALLRUN_SHIFT * 0.8 and shift < Tuning.CAM_WALLRUN_SHIFT + 0.2,
		"F7b: the camera shifts %.1f m toward the open side (%.2f m from the player)" % [Tuning.CAM_WALLRUN_SHIFT, shift])
	_check(roll > Tuning.CAM_WALLRUN_ROLL * 0.75 and roll < Tuning.CAM_WALLRUN_ROLL + 0.3,
		"F7b: rolls away from the wall on the right (top leans left, up to %.2f deg; doc %.0f)" % [roll, Tuning.CAM_WALLRUN_ROLL])
	_check(frames == 0 or arm_min > 2.5, "F7b: the run wall does not pull the camera in (arm >= %.2f m with the camera behind it)" % arm_min)
	GameEvents.wall_run_started.disconnect(cb)
	await _settle(120)
	_rig.snap_behind()
	await _ticks(60)
	_check(absf(_rig.get_roll_degrees()) < 0.2, "the roll clears after the run (%.2f deg)" % _rig.get_roll_degrees())

# --- F7 ---------------------------------------------------------------------------------------
## Watch the camera through a fall until the roll has cleared after landing.
## Returns {max_roll, max_fall, top, min_pitch, step_in, step_out, landed, levels, trauma}.
func _watch_fall(pitch0: float, max_frames: int) -> Dictionary:
	var r := {"max_roll": 0.0, "max_fall": 0.0, "top": -INF, "min_pitch": pitch0, "step_in": 0.0,
		"step_out": 0.0, "landed": false, "levels": [], "trauma": 0.0, "roll_at_land": 0.0}
	var cb := func(f: Node3D, level: StringName, _pos: Vector3, _vs: float) -> void:
		if f == _p:
			(r["levels"] as Array).append(level)
	GameEvents.landing.connect(cb)
	var last := _rig.get_roll_degrees()
	for i in max_frames:
		await get_tree().process_frame
		var roll := _rig.get_roll_degrees()
		var step := absf(roll - last)
		last = roll
		r["top"] = maxf(r["top"], _p.global_position.y)
		r["max_fall"] = maxf(r["max_fall"], _p.traversal.get_fall_height())
		r["max_roll"] = maxf(r["max_roll"], absf(roll))
		r["min_pitch"] = minf(r["min_pitch"], _rig.get_view_pitch())
		if r["landed"]:
			r["step_out"] = maxf(r["step_out"], step)
		else:
			r["step_in"] = maxf(r["step_in"], step)
		if not (r["levels"] as Array).is_empty() and not r["landed"]:
			r["landed"] = true
			r["trauma"] = _rig.get_trauma()
			r["roll_at_land"] = absf(roll)
			_p.move_input = Vector3.ZERO
			_p.combat.release(CombatController.Action.DASH)
		if r["landed"] and absf(roll) < 0.05 and (r["max_roll"] as float) > 0.0:
			break
	GameEvents.landing.disconnect(cb)
	return r

## The Yard's biggest fall: a full-speed sprint jump off the 1.8 m platform.
func _platform_jump() -> void:
	_place(Vector3(-40.0, 1.85, 7.0))
	await _ticks(60)
	var pitch0 := _rig.get_view_pitch()
	_p.move_input = Vector3.FORWARD
	_p.combat.press(CombatController.Action.DASH)
	await _wait_until(func() -> bool: return _p.global_position.z <= -7.4, 600)
	var charge := _p.traversal.sprint_charge
	_p.traversal.on_jump_pressed()
	var r := await _watch_fall(pitch0, 600)
	var drop: float = r["top"] - 0.0
	print("  F7 platform sprint jump: sprint_charge %.2f at take-off, apex %.2f m above the ground, fell %.2f m; roll %.2f deg (%.2f at touchdown), pitch %.1f -> %.1f deg; roll step per frame: in %.2f, out %.2f deg; landing %s" % [
		charge, drop, r["max_fall"], r["max_roll"], r["roll_at_land"], rad_to_deg(pitch0), rad_to_deg(r["min_pitch"]),
		r["step_in"], r["step_out"], str(r["levels"])])
	_check(charge > 0.95 and drop > Tuning.CAM_FALL_FROM, "a full-speed sprint jump off the platform drops more than %.0f m (%.2f)" % [Tuning.CAM_FALL_FROM, drop])
	var want := Tuning.CAM_FALL_ROLL * clampf((drop - Tuning.CAM_FALL_FROM) / CameraRig.FALL_RAMP, 0.0, 1.0)
	_check(r["max_roll"] > want * 0.8 and r["max_roll"] > 3.0,
		"F7: the platform sprint jump tilts the camera visibly (%.2f deg; %.2f for a %.2f m drop)" % [r["max_roll"], want, drop])
	_check(r["min_pitch"] < pitch0 - deg_to_rad(3.0), "F7: and pitches down to show the ground")
	_check(r["step_in"] < 0.8 and r["step_out"] < 0.8, "F7: eases in and out, no snap (largest step %.2f deg per frame)" % maxf(r["step_in"], r["step_out"]))
	_check(r["landed"] and absf(_rig.get_roll_degrees()) < 0.1, "the roll clears after landing")
	await _settle(60)

func _fall() -> void:
	var levels: Array = []
	var cb := func(f: Node3D, level: StringName, _pos: Vector3, _vs: float) -> void:
		if f == _p:
			levels.append(level)
	GameEvents.landing.connect(cb)
	_place(Vector3(40.0, 7.05, -1.5))
	await _ticks(60)
	var pitch0 := _rig.get_view_pitch()
	_rig._trauma = 0.0
	_p.move_input = Vector3.FORWARD  # walk off the -Z edge, away from the camera
	var max_roll := 0.0
	var max_fall := 0.0
	var min_pitch := pitch0
	var trauma_after := 0.0
	var landed := false
	for i in 400:
		await get_tree().process_frame
		max_fall = maxf(max_fall, _p.traversal.get_fall_height())
		max_roll = maxf(max_roll, absf(_rig.get_roll_degrees()))
		min_pitch = minf(min_pitch, _rig.get_view_pitch())
		if not levels.is_empty() and not landed:
			landed = true
			trauma_after = _rig.get_trauma()
			_p.move_input = Vector3.ZERO
		if landed and i > 0 and absf(_rig.get_roll_degrees()) < 0.1:
			break
	GameEvents.landing.disconnect(cb)
	print("  F7 7 m ledge: fell %.2f m, roll up to %.2f deg, pitch %.1f -> %.1f deg, landing %s, trauma %.2f after it, roll now %.2f" % [
		max_fall, max_roll, rad_to_deg(pitch0), rad_to_deg(min_pitch), str(levels), trauma_after, _rig.get_roll_degrees()])
	_check(max_fall > Tuning.CAM_FALL_FROM + 1.5, "the player really fell (%.2f m)" % max_fall)
	_check(max_roll > Tuning.CAM_FALL_ROLL * 0.95 and max_roll <= Tuning.CAM_FALL_ROLL + 0.05,
		"F7: falling past %.0f m rolls the camera (up to %.2f deg, cap %.0f)" % [Tuning.CAM_FALL_FROM, max_roll, Tuning.CAM_FALL_ROLL])
	_check(min_pitch < pitch0 - deg_to_rad(5.0), "F7: and pitches down to show the ground")
	_check(levels.has(&"heavy") and trauma_after > float(Tuning.TRAUMA[&"heavy_landing"]) - 0.05,
		"heavy landing adds its trauma (%.2f)" % trauma_after)
	_check(absf(_rig.get_roll_degrees()) < 0.2, "landing clears the roll")
