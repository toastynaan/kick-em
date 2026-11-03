extends Node
## Round 7 combat camera (docs/Round 7 — Freeflow Combat.md: Camera, Hit feel;
## Acceptance 10). The inputs other modules own are scripted through
## test_cam_fake_rig.gd (combat target, drive, throw wind-up); the player is the
## real one, moved by a physics-step mover:
## - Lean: the look-at leans R7_CAM_LEAN of the way toward the combat target,
##   eased (a target change never jumps the view), none without a target.
## - Auto-yaw: only to bring an off-screen combat target back in, at most
##   R7_CAM_AUTO_YAW_RATE, eased, settling on the safe line; never while (or
##   within CAM_MOUSE_IDLE s after) the player turns the camera, never for a
##   target the player turned away from until a hit on it re-engages it,
##   never without a target, never for one far behind.
## - Glides: eight simulated 11 m/s glides (R7_GLIDE_SPEED for R7_GLIDE_MAX_TIME)
##   in every direction around the camera, each with glide_started: the player
##   in the viewport every frame, the follow never overshoots, no jolt (camera
##   acceleration), the follow lag and the player's on-screen shift.
## - Drive (carry.is_driving): FOV + R7_CAM_DRIVE_FOV, R7_CAM_DRIVE_PULLBACK
##   further, R7_CAM_DRIVE_DROP lower, eased in and out; a 3 s drive ramping to
##   9.5 m/s with 120 deg/s turns keeps the player in the viewport.
## - Throw wind-up: the FOV narrows by R7_CAM_THROW_ZOOM_FOV at a full wind-up,
##   eases back on release.
## - Hit punch: FOV kick weight x R7_CAM_PUNCH_FOV and trauma weight x
##   R7_CAM_PUNCH_TRAUMA (in place of the tier trauma); enemy hits on the player
##   keep the tier trauma; drive impacts shake by speed (slam big, break medium).

const FakeRig := preload("res://tests/game/test_cam_fake_rig.gd")
const GLIDE_DIRS := 8
const GLIDE_REACH := 0.9        ## m short of the target where a glide stops (reach x LUNGE_GAP, about)
const MAX_CAM_ACCEL := 200.0    ## m/s^2: a jolt (a cut or a snap) is thousands
## m: a critically damped follower never lags a steady speed v by more than
## 2 v / omega (0.92 m at 11 m/s and FOLLOW_OMEGA 24); a 0.35 s glide peaks lower.
var MAX_GLIDE_LAG := 2.0 * Tuning.R7_GLIDE_SPEED / CameraRig.FOLLOW_OMEGA

var _fails := 0
var _rig: CameraRig
var _p: Fighter
var _world: Node3D

# Mover (physics, before the fighter).
var _moving := false
var _move_kind := &""
var _move_t0 := 0.0
var _move_dir := Vector3.FORWARD
var _move_time := 0.0
var _move_speed := 0.0

# Probe (after the rig).
var _probe_on := false
var _m := {}

class Probe:
	extends Node
	var owner_test: Node
	func _process(_d: float) -> void:
		owner_test.call(&"_measure")

class Mover:
	extends Node
	var owner_test: Node
	func _physics_process(delta: float) -> void:
		owner_test.call(&"_move", delta)

func _ready() -> void:
	for i in 5:
		await get_tree().process_frame
	await _run()
	AttackDirector.reset()
	TimeDirector.reset()
	print("TEST test_cam_freeflow: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _box(pos: Vector3, size: Vector3, nm: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = nm
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = pos
	add_child(body)
	return body

func _wait_real(sec: float) -> void:
	var until := TimeDirector.now() + sec
	while TimeDirector.now() < until:
		await get_tree().process_frame

func _near(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps

func _yaw_err(a: float, b: float) -> float:
	return absf(wrapf(a - b, -PI, PI))

func _fake() -> Object:
	return _rig as Object

func _place(pos: Vector3, face := Vector3.FORWARD) -> void:
	_p.teleport_to(pos, face)
	_p.velocity = Vector3.ZERO
	_p.reset_physics_interpolation()

func _enemy(pos: Vector3) -> Fighter:
	return FighterFactory.spawn_dummy(_world, &"grunt", Transform3D(Basis.looking_at(Vector3.BACK), pos + Vector3(0, 0.05, 0)))

## Pixels from the nearest viewport edge (negative = outside, -1e6 = behind the camera).
func _margin(p: Vector3) -> float:
	var cam := _rig.camera
	var size := get_viewport().get_visible_rect().size
	if cam.is_position_behind(p):
		return -1e6
	var s := cam.unproject_position(p)
	return minf(minf(s.x, size.x - s.x), minf(s.y, size.y - s.y))

## Share of the half width from the screen centre (signed: + right).
func _screen_x(p: Vector3) -> float:
	var cam := _rig.camera
	var w := get_viewport().get_visible_rect().size.x
	return (cam.unproject_position(p).x - w * 0.5) / (w * 0.5)

# --- Mover ----------------------------------------------------------------------------------
func _move(delta: float) -> void:
	if not _moving or not is_instance_valid(_p):
		return
	var t := TimeDirector.now() - _move_t0
	var v := Vector3.ZERO
	match _move_kind:
		&"glide":
			if t < _move_time:
				v = _move_dir * Tuning.R7_GLIDE_SPEED
		&"drive":
			# Speed ramps 4 -> 9.5 m/s over 1 s (ease-out), then holds; turns at
			# R7_DRIVE_TURN_RATE right for 0.5 s, then left for 0.5 s.
			var k := clampf(t / Tuning.R7_DRIVE_RAMP_TIME, 0.0, 1.0)
			_move_speed = lerpf(Tuning.R7_DRIVE_START_SPEED, Tuning.R7_DRIVE_MAX_SPEED, 1.0 - (1.0 - k) * (1.0 - k))
			var turn := 0.0
			if t > 1.2 and t < 1.7:
				turn = -1.0
			elif t > 2.2 and t < 2.7:
				turn = 1.0
			_move_dir = _move_dir.rotated(Vector3.UP, turn * deg_to_rad(Tuning.R7_DRIVE_TURN_RATE) * delta)
			if t < _move_time:
				v = _move_dir * _move_speed
	if v != Vector3.ZERO:
		_p.global_position += v * delta
		_p.velocity = Vector3.ZERO

# --- Probe ----------------------------------------------------------------------------------
func _reset_probe() -> void:
	_m = {"frames": 0, "out": 0, "worst": INF, "max_speed": 0.0, "max_look_speed": 0.0, "max_acc": 0.0,
		"max_lag": 0.0, "max_shift": 0.0, "x0": NAN, "prev": null, "prev_v": null, "prev_look": null,
		"max_fov_step": 0.0, "prev_fov": NAN, "max_combat_yaw": 0.0, "yaw_frames": 0}

func _measure() -> void:
	if not _probe_on or not is_instance_valid(_rig) or not is_instance_valid(_p):
		return
	var dt := maxf(TimeDirector.frame_delta(), 0.0001)
	var aim := _p.get_aim_point()
	_m["frames"] += 1
	var worst := INF
	for q: Vector3 in [aim, aim + Vector3.UP * 0.5, _p.get_ground_position() + Vector3.UP * 0.05]:
		worst = minf(worst, _margin(q))
	_m["worst"] = minf(_m["worst"], worst)
	if worst < 0.0:
		_m["out"] += 1
	var pos := _rig.camera.global_position
	if _m["prev"] != null:
		var v: Vector3 = (pos - _m["prev"]) / dt
		_m["max_speed"] = maxf(_m["max_speed"], v.length())
		if _m["prev_v"] != null:
			_m["max_acc"] = maxf(_m["max_acc"], (v - _m["prev_v"]).length() / dt)
		_m["prev_v"] = v
	_m["prev"] = pos
	var look := _rig._follow
	if _m["prev_look"] != null:
		_m["max_look_speed"] = maxf(_m["max_look_speed"], (look - _m["prev_look"]).length() / dt)
	_m["prev_look"] = look
	_m["max_lag"] = maxf(_m["max_lag"], (_rig._follow - aim).length())
	var x := _screen_x(aim)
	if is_nan(_m["x0"]):
		_m["x0"] = x
	_m["max_shift"] = maxf(_m["max_shift"], absf(x - _m["x0"]))
	var fov := _rig.camera.fov
	if not is_nan(_m["prev_fov"]):
		_m["max_fov_step"] = maxf(_m["max_fov_step"], absf(fov - _m["prev_fov"]))
	_m["prev_fov"] = fov
	_m["max_combat_yaw"] = maxf(_m["max_combat_yaw"], _rig.get_combat_yaw_rate())
	if _rig.get_combat_yaw_rate() > 0.0:
		_m["yaw_frames"] += 1

# --- Setup ----------------------------------------------------------------------------------
func _run() -> void:
	_box(Vector3(0, -0.5, 0), Vector3(120, 1, 120), "Floor")
	_world = Node3D.new()
	add_child(_world)
	_p = FighterFactory.spawn_player(_world, Transform3D(Basis(), Vector3(0, 0.05, 0)))
	AttackDirector.set_player(_p)
	_rig = FakeRig.new()
	_rig.target = _p
	add_child(_rig)
	var probe := Probe.new()
	probe.owner_test = self
	probe.process_priority = 1000  # after the rig: measures what is rendered
	add_child(probe)
	var mover := Mover.new()
	mover.owner_test = self
	mover.process_physics_priority = -1000  # before the fighter's own physics step
	add_child(mover)
	CameraRig.sensitivity = 1.0
	CameraRig.invert_y = false
	await _wait_real(0.5)
	_rig.snap_behind()
	await _wait_real(0.5)
	_check(GameEvents.glide_started.is_connected(_rig._on_glide_started) and GameEvents.drive_impact.is_connected(_rig._on_drive_impact),
		"camera listens to GameEvents.glide_started and drive_impact")
	await _lean()
	await _auto_yaw()
	await _glides()
	await _drive()
	await _throw()
	await _punch()
	await _drive_impacts()

# --- Lean ---------------------------------------------------------------------------------------
func _lean() -> void:
	_place(Vector3(0, 0.05, 0))
	var e1 := _enemy(Vector3(1.8, 0, -3.0))
	var e2 := _enemy(Vector3(-2.2, 0, -2.6))
	await get_tree().process_frame
	_rig.snap_behind()
	await _wait_real(1.0)
	var base_look := _rig.get_look_point()
	_check(_rig.get_combat_lean().length() < 0.001 and _rig.get_lean_target() == null, "no combat target: no lean")
	_check(_rig.get_soft_target() == null, "no combat target: get_soft_target() null")
	_fake().set(&"fake_target", e1)
	_reset_probe()
	_probe_on = true
	await _wait_real(1.6)
	var want := (e1.get_aim_point() - _p.get_aim_point()) * Tuning.R7_CAM_LEAN
	var lean := _rig.get_combat_lean()
	var look_off := _rig.get_look_point() - _p.get_aim_point()
	print("  lean toward a target %.2f m away: lean %s (want %s), look point %.2f m from the player" % [
		(e1.get_aim_point() - _p.get_aim_point()).length(), str(lean), str(want), look_off.length()])
	_check(_rig.get_soft_target() == e1 and _rig.get_lean_target() == e1, "get_soft_target() is the combat target, and the lean target")
	_check(lean.distance_to(want) < 0.05 and look_off.distance_to(want) < 0.06,
		"the look-at leans %.0f%% of the way toward the combat target (%.3f m off)" % [Tuning.R7_CAM_LEAN * 100.0, lean.distance_to(want)])
	_check(_rig.camera.is_position_in_frustum(e1.get_aim_point()) and _rig.camera.is_position_in_frustum(_p.get_aim_point()),
		"player and combat target both in frame")
	# Switch targets: eased, never a jump.
	var step := 0.0
	var last := _rig.get_look_point()
	_fake().set(&"fake_target", e2)
	var until := TimeDirector.now() + 1.6
	while TimeDirector.now() < until:
		await get_tree().process_frame
		step = maxf(step, _rig.get_look_point().distance_to(last))
		last = _rig.get_look_point()
	var want2 := (e2.get_aim_point() - _p.get_aim_point()) * Tuning.R7_CAM_LEAN
	print("  target switch: largest look-point step %.4f m/frame, lean now %s (want %s)" % [step, str(_rig.get_combat_lean()), str(want2)])
	_check(step < 0.03 and _rig.get_combat_lean().distance_to(want2) < 0.05, "a new combat target eases the lean over (largest step %.4f m per frame)" % step)
	# Out of range, dead, and none: the lean eases out.
	_place_enemy(e2, Vector3(-14.0, 0.05, -2.6))
	_place(Vector3(0, 0.05, 0))
	await _wait_real(1.6)
	_check(_rig.get_combat_lean().length() < 0.05, "a combat target beyond %.0f m: no lean (%.3f m)" % [
		Tuning.R7_TARGET_RANGE + Tuning.R7_TARGET_KEEP_EXTRA, _rig.get_combat_lean().length()])
	_fake().set(&"fake_target", e1)
	await _wait_real(1.0)
	e1.apply_damage(e1.max_hp + 10.0, &"test")
	await _wait_real(1.6)
	_check(_rig.get_soft_target() == null and _rig.get_combat_lean().length() < 0.05, "a dead combat target: no soft target, the lean eases out")
	_probe_on = false
	print("  lean phases: player in the viewport on %d / %d frames (worst margin %.0f px), on-screen shift up to %.0f%% of the half width" % [
		_m["frames"] - _m["out"], _m["frames"], _m["worst"], 100.0 * _m["max_shift"]])
	_check(_m["out"] == 0, "the player stays in the viewport while the look-at leans")
	_fake().set(&"fake_target", null)
	e1.queue_free()
	e2.queue_free()
	await _wait_real(0.5)
	_check(base_look.distance_to(_rig.get_look_point()) < 0.1, "back on the player with no target")

func _place_enemy(f: Fighter, pos: Vector3) -> void:
	f.teleport_to(pos, Vector3.BACK)
	f.reset_physics_interpolation()

# --- Auto-yaw -------------------------------------------------------------------------------------
func _auto_yaw() -> void:
	_place(Vector3(0, 0.05, 0))
	await get_tree().process_frame
	_rig.snap_behind()
	_rig._last_manual = -100.0
	await _wait_real(0.6)
	# Off screen to the right and a little behind, 6.7 m from the player (inside R7_TARGET_RANGE + 2).
	var e := _enemy(Vector3(6.2, 0, 2.5))
	await _wait_real(0.6)
	var yaw0 := _rig._yaw
	_check(not _rig.camera.is_position_in_frustum(e.get_aim_point()), "an enemy off screen to the right")
	await _wait_real(1.5)
	_check(_yaw_err(_rig._yaw, yaw0) < 0.0001, "not the combat target: the yaw never turns for it (free camera)")
	_fake().set(&"fake_target", e)
	_reset_probe()
	_probe_on = true
	var t0 := TimeDirector.now()
	await _wait_real(2.5)
	_probe_on = false
	var turned := rad_to_deg(_yaw_err(_rig._yaw, yaw0))
	var sx := _screen_x(e.get_aim_point())
	var sfeet := _screen_x(e.get_ground_position())
	print("  auto-yaw: turned %.1f deg on %d frames at up to %.1f deg/s (cap %.0f); target now at %.2f / %.2f of the half width (chest / feet); player in view %d / %d frames" % [
		turned, _m["yaw_frames"], rad_to_deg(_m["max_combat_yaw"]), Tuning.R7_CAM_AUTO_YAW_RATE, sx, sfeet,
		_m["frames"] - _m["out"], _m["frames"]])
	_check(turned > 3.0 and _rig.camera.is_position_in_frustum(e.get_aim_point()), "the combat target off screen: the yaw brings it in (%.1f deg)" % turned)
	_check(rad_to_deg(_m["max_combat_yaw"]) <= Tuning.R7_CAM_AUTO_YAW_RATE + 0.05,
		"never faster than %.0f deg/s (%.2f)" % [Tuning.R7_CAM_AUTO_YAW_RATE, rad_to_deg(_m["max_combat_yaw"])])
	_check(absf(sx) <= CameraRig.COMBAT_TARGET_SAFE + 0.05 and absf(sfeet) <= CameraRig.COMBAT_TARGET_SAFE + 0.05,
		"it turns just enough: the target sits at the %.0f%% line" % (CameraRig.COMBAT_TARGET_SAFE * 100.0))
	_check(_m["out"] == 0, "the player stays in the viewport while the yaw turns")
	var settle := -1.0
	var still := 0
	var until := TimeDirector.now() + 4.0
	while TimeDirector.now() < until and still < 60:
		await get_tree().process_frame
		if _rig.get_combat_yaw_rate() == 0.0:
			still += 1
			if settle < 0.0:
				settle = TimeDirector.now() - t0
		else:
			still = 0
			settle = -1.0
	print("  auto-yaw settled %.2f s after the target was set; target at %.3f of the half width" % [settle, _screen_x(e.get_aim_point())])
	_check(still >= 60, "then it stops, the target framed (settled after %.2f s)" % settle)
	# Never against the player's input: turn away (to the left) for 1.5 s. No
	# auto-yaw while turning, none after it (the player turned away from that
	# target), until a hit on it re-engages it.
	var input_yaw := 0.0
	var auto_during := 0
	until = TimeDirector.now() + 1.5
	while TimeDirector.now() < until:
		_rig.apply_manual_input(Vector2(-0.3 * TimeDirector.frame_delta(), 0.0))  # 0.3 rad/s to the left
		input_yaw += 0.3 * TimeDirector.frame_delta()
		await get_tree().process_frame
		if _rig.get_combat_yaw_rate() > 0.0:
			auto_during += 1
	var yaw_after_input := _rig._yaw
	var auto_after := 0
	until = TimeDirector.now() + Tuning.CAM_MOUSE_IDLE + 2.0
	while TimeDirector.now() < until:
		await get_tree().process_frame
		if _rig.get_combat_yaw_rate() > 0.0:
			auto_after += 1
	print("  input: turned %.0f deg away by hand; auto-yaw on %d frames while turning, %d frames in the %.1f s after; veto on %s; target at %.2f of the half width" % [
		rad_to_deg(input_yaw), auto_during, auto_after, Tuning.CAM_MOUSE_IDLE + 2.0, str(_rig.get_yaw_veto()), _screen_x(e.get_aim_point())])
	_check(auto_during == 0, "no auto-yaw while the player turns the camera")
	_check(auto_after == 0 and _yaw_err(_rig._yaw, yaw_after_input) < 0.0001 and _rig.get_yaw_veto() == e,
		"the player turned away from the target: it is not chased afterwards")
	var hit := HitInfo.new()
	hit.attacker = _p
	hit.victim = e
	hit.move_id = &"jab"
	hit.react = &"snap"
	hit.weight = Tuning.R7_MOVES[&"jab"]["weight"]
	hit.hit_position = e.get_aim_point()
	hit.hit_direction = Vector3.RIGHT
	GameEvents.hit_landed.emit(hit)
	var t_hit := TimeDirector.now()
	var first_auto := -1.0
	until = t_hit + 3.0
	while TimeDirector.now() < until:
		await get_tree().process_frame
		if first_auto < 0.0 and _rig.get_combat_yaw_rate() > 0.0:
			first_auto = TimeDirector.now() - t_hit
	print("  re-engaged (a hit on it): auto-yaw from %.2f s after the hit; target at %.2f of the half width" % [first_auto, _screen_x(e.get_aim_point())])
	_check(first_auto >= 0.0 and _rig.get_yaw_veto() == null and _rig.camera.is_position_in_frustum(e.get_aim_point()),
		"a hit on it re-engages: the yaw brings it back on screen")
	# Far behind the camera (beyond COMBAT_YAW_REACH even with the lean pulling the camera back): never chased.
	_place_enemy(e, Vector3(0.0, 0.05, 8.0))
	_rig.snap_behind()
	await _wait_real(0.2)
	var yaw_b := _rig._yaw
	await _wait_real(2.0)
	_check(_yaw_err(_rig._yaw, yaw_b) < 0.0001, "a combat target behind the camera is never chased (%.3f rad)" % _yaw_err(_rig._yaw, yaw_b))
	_fake().set(&"fake_target", null)
	e.queue_free()
	await _wait_real(0.3)

# --- Glides ----------------------------------------------------------------------------------------
func _glides() -> void:
	var rows: Array[String] = []
	var all_in := true
	var worst_acc := 0.0
	var worst_lag := 0.0
	var worst_shift := 0.0
	var worst_speed_ratio := 0.0
	var settle_ok := true
	var moved_ok := true
	var dist := Tuning.R7_GLIDE_SPEED * Tuning.R7_GLIDE_MAX_TIME
	for i in GLIDE_DIRS:
		var ang := TAU * float(i) / float(GLIDE_DIRS)  # 0 = straight away from the camera, PI/2 = right
		_place(Vector3(0, 0.05, 0))
		_fake().set(&"fake_target", null)
		await get_tree().process_frame
		_rig.snap_behind()
		var fwd := -_rig.get_flat_basis().z
		var right := _rig.get_flat_basis().x
		var dir := (fwd * cos(ang) + right * sin(ang)).normalized()
		var tgt := _enemy(_p.global_position + dir * (dist + GLIDE_REACH))
		await _wait_real(1.2)
		_reset_probe()
		_probe_on = true
		var start := _p.global_position
		GameEvents.glide_started.emit(_p, tgt, dist)
		_move_kind = &"glide"
		_move_dir = dir
		_move_time = Tuning.R7_GLIDE_MAX_TIME
		_move_t0 = TimeDirector.now()
		_moving = true
		await _wait_real(Tuning.R7_GLIDE_MAX_TIME)
		var glided := _p.global_position.distance_to(start)
		var lag_end: float = (_rig._follow - _p.get_aim_point()).length()
		var gliding_seen := _rig.is_glide_followed()
		# The strike lands: the target becomes the combat target.
		_fake().set(&"fake_target", tgt)
		await _wait_real(0.5)
		var lag_after: float = (_rig._follow - _p.get_aim_point()).length()
		await _wait_real(0.4)
		_moving = false
		_probe_on = false
		moved_ok = moved_ok and absf(glided - dist) < 0.15 and gliding_seen
		all_in = all_in and _m["out"] == 0
		worst_acc = maxf(worst_acc, _m["max_acc"])
		worst_lag = maxf(worst_lag, _m["max_lag"])
		worst_shift = maxf(worst_shift, _m["max_shift"])
		worst_speed_ratio = maxf(worst_speed_ratio, _m["max_look_speed"] / Tuning.R7_GLIDE_SPEED)
		settle_ok = settle_ok and lag_after < 0.05
		rows.append("%3.0f deg: glided %.2f m; player in view %d/%d (worst margin %.0f px); follow lag %.2f m at the end, %.3f m 0.5 s later; follow speed up to %.1f m/s; camera up to %.1f m/s, %.0f m/s^2; on-screen shift %.0f%%" % [
			rad_to_deg(ang), glided, _m["frames"] - _m["out"], _m["frames"], _m["worst"], lag_end, lag_after,
			_m["max_look_speed"], _m["max_speed"], _m["max_acc"], 100.0 * _m["max_shift"]])
		tgt.queue_free()
	for r in rows:
		print("  glide ", r)
	_check(moved_ok, "each glide covered %.2f m at %.0f m/s and the rig followed it as a glide" % [dist, Tuning.R7_GLIDE_SPEED])
	_check(all_in, "Acceptance 10: the player stays in the viewport through every glide")
	_check(worst_speed_ratio <= 1.0 + 0.01, "the follow never overshoots the glide's speed (at most %.3f x %.0f m/s)" % [worst_speed_ratio, Tuning.R7_GLIDE_SPEED])
	_check(worst_acc <= MAX_CAM_ACCEL, "no jolt: camera acceleration at most %.0f m/s^2 (limit %.0f)" % [worst_acc, MAX_CAM_ACCEL])
	_check(worst_lag <= MAX_GLIDE_LAG, "no lag spike: the follow lags at most %.2f m (limit %.2f)" % [worst_lag, MAX_GLIDE_LAG])
	_check(settle_ok, "the follow catches up within 0.5 s of the glide's end")
	_check(worst_shift < 0.3, "the player moves at most %.0f%% of the half width on screen" % (100.0 * worst_shift))
	_fake().set(&"fake_target", null)

# --- Drive ------------------------------------------------------------------------------------------
func _drive() -> void:
	_place(Vector3(0, 0.05, 20.0))
	await get_tree().process_frame
	_rig.snap_behind()
	await _wait_real(1.5)
	var fov0 := _rig.get_fov()
	var d0 := _rig.get_distance()
	var h0 := _rig.get_height()
	_reset_probe()
	_probe_on = true
	_move_kind = &"drive"
	_move_dir = -_rig.get_flat_basis().z
	_move_time = Tuning.R7_DRIVE_MAX_TIME
	_move_t0 = TimeDirector.now()
	_moving = true
	_fake().set(&"fake_driving", true)
	await _wait_real(0.1)
	var fov_early := _rig.get_fov()
	await _wait_real(1.4)
	var fov_mid := _rig.get_fov()
	await _wait_real(1.35)
	var fov1 := _rig.get_fov()
	var d1 := _rig.get_distance()
	var h1 := _rig.get_height()
	var speed := _move_speed
	await _wait_real(Tuning.R7_DRIVE_MAX_TIME - 2.85)
	_moving = false
	_fake().set(&"fake_driving", false)
	var in_drive := [_m["frames"] - _m["out"], _m["frames"], _m["worst"], _m["max_fov_step"]]
	_reset_probe()
	var back_t := -1.0
	var t_end := TimeDirector.now()
	while TimeDirector.now() - t_end < 2.0:
		await get_tree().process_frame
		if back_t < 0.0 and absf(_rig.get_fov() - fov0) < 0.1:
			back_t = TimeDirector.now() - t_end
	_probe_on = false
	print("  drive: speed %.1f m/s at the end; fov %.1f -> %.1f after 0.1 s -> %.1f at 1.5 s -> %.1f; distance %.2f -> %.2f m; height %+.2f -> %+.2f m; largest fov step %.2f deg/frame; player in view %d/%d (worst margin %.0f px)" % [
		speed, fov0, fov_early, fov_mid, fov1, d0, d1, h0, h1, in_drive[3], in_drive[0], in_drive[1], in_drive[2]])
	print("  drive over: back to fov %.1f in %.2f s, largest fov step %.2f deg/frame" % [fov0, back_t, _m["max_fov_step"]])
	_check(_near(speed, Tuning.R7_DRIVE_MAX_SPEED, 0.05), "the simulated drive reached %.1f m/s" % Tuning.R7_DRIVE_MAX_SPEED)
	_check(_near(fov1 - fov0, Tuning.R7_CAM_DRIVE_FOV, 0.2), "drive: FOV +%.0f deg (%+.2f)" % [Tuning.R7_CAM_DRIVE_FOV, fov1 - fov0])
	_check(_near(d1 - d0, Tuning.R7_CAM_DRIVE_PULLBACK, 0.12), "drive: pulled back %.1f m (%+.2f)" % [Tuning.R7_CAM_DRIVE_PULLBACK, d1 - d0])
	_check(_near(h0 - h1, Tuning.R7_CAM_DRIVE_DROP, 0.05), "drive: %.1f m lower (%.2f)" % [Tuning.R7_CAM_DRIVE_DROP, h0 - h1])
	_check(fov_early - fov0 < Tuning.R7_CAM_DRIVE_FOV * 0.6 and in_drive[3] < 0.5 and _m["max_fov_step"] < 0.5,
		"eased in and out (after 0.1 s %+.1f deg; largest step %.2f / %.2f deg per frame)" % [fov_early - fov0, in_drive[3], _m["max_fov_step"]])
	_check(back_t > 0.0 and back_t < 1.5, "the FOV is back %.2f s after the drive" % back_t)
	_check(in_drive[0] == in_drive[1], "Acceptance 10: the player stays in the viewport through a 3 s drive with 120 deg/s turns")

# --- Throw wind-up -------------------------------------------------------------------------------------
func _throw() -> void:
	_place(Vector3(0, 0.05, 0))
	await get_tree().process_frame
	_rig.snap_behind()
	await _wait_real(1.0)
	var fov0 := _rig.get_fov()
	_reset_probe()
	_probe_on = true
	var t0 := TimeDirector.now()
	while TimeDirector.now() - t0 < Tuning.R7_THROW_WINDUP_FULL + 0.3:
		_fake().set(&"fake_windup", clampf((TimeDirector.now() - t0) / Tuning.R7_THROW_WINDUP_FULL, 0.0, 1.0))
		await get_tree().process_frame
	var fov_full := _rig.get_fov()
	var step_in: float = _m["max_fov_step"]
	_fake().set(&"fake_windup", 0.0)  # released: thrown
	_reset_probe()
	var t1 := TimeDirector.now()
	var back_t := -1.0
	while TimeDirector.now() - t1 < 1.2:
		await get_tree().process_frame
		if back_t < 0.0 and absf(_rig.get_fov() - fov0) < 0.1:
			back_t = TimeDirector.now() - t1
	_probe_on = false
	print("  throw wind-up: fov %.1f -> %.1f at a full wind-up (largest step %.2f deg/frame); release: back in %.2f s (largest step %.2f)" % [
		fov0, fov_full, step_in, back_t, _m["max_fov_step"]])
	_check(_near(fov0 - fov_full, Tuning.R7_CAM_THROW_ZOOM_FOV, 0.2), "a full wind-up narrows the FOV by %.0f deg (%.2f)" % [Tuning.R7_CAM_THROW_ZOOM_FOV, fov0 - fov_full])
	_check(_m["max_fov_step"] < 0.5 and back_t > 0.05 and back_t < 1.0, "the release eases back (no snap)")

# --- Hit punch by weight -----------------------------------------------------------------------------------
func _punch() -> void:
	_place(Vector3(0, 0.05, 0))
	var e := _enemy(Vector3(0, 0, -1.2))
	await get_tree().process_frame
	_rig.snap_behind()
	await _wait_real(0.8)
	var rows: Array[String] = []
	var ok := true
	var last_peak := 0.0
	var mono := true
	for move: StringName in [&"jab", &"hook", &"gut_punch", &"heavy_cross", &"roundhouse"]:
		var row: Dictionary = Tuning.R7_MOVES[move]
		var w := float(row["weight"])
		_rig._trauma = 0.0
		_rig._fov_amp = 0.0
		_rig._fov_punch = 0.0
		_rig._fov_age = 10.0
		await get_tree().process_frame
		var info := HitInfo.new()
		info.attacker = _p
		info.victim = e
		info.move_id = move
		info.react = row["react"]
		info.weight = w
		info.tier = HitInfo.Tier.KNOCKDOWN if row["tier"] == &"knockdown" else (HitInfo.Tier.STAGGER if row["tier"] == &"stagger" else HitInfo.Tier.FLINCH)
		info.damage = float(row["dmg"])
		info.hit_position = e.get_aim_point()
		info.hit_direction = Vector3.FORWARD
		GameEvents.hit_landed.emit(info)
		var tr := _rig.get_trauma()
		var peak := 0.0
		var until := TimeDirector.now() + 0.35
		while TimeDirector.now() < until:
			await get_tree().process_frame
			peak = maxf(peak, _rig.camera.fov - _rig.get_fov())
		var want_fov := w * Tuning.R7_CAM_PUNCH_FOV
		var want_tr := w * Tuning.R7_CAM_PUNCH_TRAUMA
		rows.append("%s (weight %.2f, tier %s): FOV kick %.2f deg (want %.2f), trauma %.4f (want %.4f; the tier's would be %.2f)" % [
			move, w, row["tier"], peak, want_fov, tr, want_tr, Power.trauma_for(info.tier)])
		ok = ok and _near(peak, want_fov, 0.06) and _near(tr, want_tr, 0.0005)
		mono = mono and peak > last_peak
		last_peak = peak
	for r in rows:
		print("  punch ", r)
	_check(ok, "every player hit punches by its weight: FOV kick weight x %.1f deg, trauma weight x %.2f, no tier trauma" % [
		Tuning.R7_CAM_PUNCH_FOV, Tuning.R7_CAM_PUNCH_TRAUMA])
	_check(mono, "a heavier hit always punches harder")
	# An enemy hit on the player keeps the tier trauma and no FOV kick.
	_rig._trauma = 0.0
	_rig._fov_amp = 0.0
	_rig._fov_punch = 0.0
	_rig._fov_age = 10.0
	await get_tree().process_frame
	var hit := HitInfo.new()
	hit.attacker = e
	hit.victim = _p
	hit.move_id = &"e_hook"
	hit.tier = HitInfo.Tier.STAGGER
	hit.damage = 8.0
	hit.hit_position = _p.get_aim_point()
	hit.hit_direction = Vector3.BACK
	var n0 := _rig.get_r7_punch_count()
	GameEvents.hit_landed.emit(hit)
	var tr_e := _rig.get_trauma()
	var peak_e := 0.0
	var until_e := TimeDirector.now() + 0.3
	while TimeDirector.now() < until_e:
		await get_tree().process_frame
		peak_e = maxf(peak_e, _rig.camera.fov - _rig.get_fov())
	print("  enemy hook on the player: trauma %.3f (tier stagger %.3f), FOV kick %.2f deg" % [tr_e, Power.trauma_for(HitInfo.Tier.STAGGER), peak_e])
	_check(_near(tr_e, Power.trauma_for(HitInfo.Tier.STAGGER), 0.001) and peak_e < 0.01 and _rig.get_r7_punch_count() == n0,
		"an enemy hit on the player keeps the tier trauma (%.2f), no weight punch" % Power.trauma_for(HitInfo.Tier.STAGGER))
	e.queue_free()

# --- Drive impacts -------------------------------------------------------------------------------------------
func _drive_impacts() -> void:
	var other := _enemy(Vector3(3, 0, 3))
	var victim := _enemy(Vector3(-3, 0, 3))
	await get_tree().process_frame
	var vmax := Tuning.R7_DRIVE_MAX_SPEED
	var cases: Array = [
		# [what, holder, result, speed, start trauma, want]
		["slam at %.1f m/s" % vmax, _p, &"slam", vmax, 0.0, CameraRig.DRIVE_TRAUMA[&"slam"]],
		["slam at %.1f m/s" % (vmax * 0.5), _p, &"slam", vmax * 0.5, 0.0, CameraRig.DRIVE_TRAUMA[&"slam"] * 0.5],
		["break at %.1f m/s" % vmax, _p, &"break", vmax, 0.0, CameraRig.DRIVE_TRAUMA[&"break"]],
		["bowl at %.1f m/s" % vmax, _p, &"bowl", vmax, 0.0, CameraRig.DRIVE_TRAUMA[&"bowl"]],
		["shove at 2 m/s", _p, &"shove", 2.0, 0.0, CameraRig.DRIVE_TRAUMA[&"shove"] * CameraRig.DRIVE_TRAUMA_MIN_SHARE],
		["break right after the wall's own 0.50 (never stacked)", _p, &"break", vmax, 0.5, 0.5],
		["an enemy's drive (not the player)", other, &"slam", vmax, 0.0, 0.0],
	]
	var line := PackedStringArray()
	var ok := true
	for c: Array in cases:
		_rig._trauma = float(c[4])
		# Called directly (the connection is checked in _run): other listeners
		# expect a real breakable as the third argument.
		_rig._on_drive_impact(c[1], victim, null, _p.global_position + Vector3(0, 1, -1), float(c[3]), c[2])
		var tr := _rig.get_trauma()
		line.append("%s %.3f (want %.3f)" % [c[0], tr, float(c[5])])
		ok = ok and _near(tr, float(c[5]), 0.001)
	print("  drive impacts: ", ", ".join(line))
	_check(ok, "drive impacts shake by speed: slam big (%.2f at %.1f m/s), break medium (%.2f), never stacked" % [
		CameraRig.DRIVE_TRAUMA[&"slam"], vmax, CameraRig.DRIVE_TRAUMA[&"break"]])
	_rig._trauma = 0.0
	other.queue_free()
	victim.queue_free()
