class_name CameraRig
extends Node3D
## Third-person combat camera (Upgrade Spec 2: Camera fixes, rules 1-9).
## In group "camera_rig". OWNER: agent E (feel & flow).
##
## - Never follows a flying body in play: a body sent more than
##   Tuning.CAM_WIDEN_TRIGGER m widens the frame (pull back, FOV) for at most
##   Tuning.CAM_WIDEN_TIME s; if it leaves the frame anyway it is let go.
## - Combat framing: player + soft target, player left of centre, distance
##   Tuning.CAM_COMBAT_DIST by token-holder spread, lock-on yaw (player -> soft
##   target) that eases back only after Tuning.CAM_MOUSE_IDLE s without camera
##   input, soft-target switches turning at most Tuning.CAM_TARGET_TURN deg/s.
## - The spring arm collides with Layers.WORLD only (floor, outer walls,
##   pillars). Breakable panels, debris, ragdolls and standing fighters in the
##   way fade (WorldMaterials.set_view_fade / BloodFX.set_fighter_fade) and
##   never move the camera.
## - Pitch in Tuning.CAM_PITCH_RANGE, distance >= Tuning.CAM_MIN_DIST.
## - Modes: combat, down (player down: pelvis, heavy lag, no orbit), closeup
##   (finisher push-in), ko (round over: follows the KO'd body). At most one
##   mode change per Tuning.CAM_MODE_GAP s, blended over Tuning.CAM_MODE_BLEND s
##   (closeup and ko are cinematic and may cut in at once).
## - The camera moves in _process with real frame time (TimeDirector.frame_delta).

enum Mode { COMBAT, DOWN, CLOSEUP, KO }
const MODE_NAMES := ["combat", "down", "closeup", "ko"]

# Local tuning (candidates for Tuning).
const MOUSE_SENS := 0.0028             ## rad per screen pixel
const STICK_SPEED := 3.2               ## rad/s at full right-stick deflection
const PITCH_DEFAULT := -0.24           ## rad (~-14 deg)
const SPREAD_NEAR := 2.0               ## m token-holder spread that maps to CAM_COMBAT_DIST.x
const SPREAD_FAR := 12.0               ## m spread that maps to CAM_COMBAT_DIST.y
const FRAME_RADIUS := 16.0             ## m, ignore token holders further than this
const LOOK_TARGET_SHARE := 0.2         ## look point moves this share toward the soft target...
const LOOK_SHIFT_MAX := 1.5            ## ...but at most this far (m)
const LOOK_RATE := 9.0                 ## 1/s look point smoothing (combat)
const DOWN_LOOK_RATE := 2.0            ## 1/s: heavy lag on the pelvis while the player is down
const DIST_RATE := 3.0                 ## 1/s distance smoothing
const CLOSEUP_DIST_RATE := 8.0         ## 1/s: the finisher push-in is quick
const ARM_IN_RATE := 30.0              ## 1/s when a WORLD collider pushes the camera in
const ARM_OUT_RATE := 4.0              ## 1/s when it lets the camera back out
const RETURN_MAX_SPEED := TAU          ## rad/s cap when easing back behind the player
const SOFT_TURN_WINDOW := 1.0          ## s after a soft-target change during which turns are capped
const SOFT_TARGET_HOLD := 0.35         ## s minimum between stick-driven soft-target switches
const MIN_CAM_HEIGHT := 0.35           ## m, the camera never goes lower than this above the floor
const WIDEN_FULL_EXTRA := 4.0          ## m beyond CAM_WIDEN_TRIGGER at which the widen is full
const WIDEN_IN_RATE := 6.0             ## 1/s
const WIDEN_OUT_RATE := 3.0            ## 1/s
const FADE_MASK := Layers.DESTRUCTIBLE | Layers.DEBRIS | Layers.DEBRIS_SMALL | Layers.RAGDOLL | Layers.CAPSULE
const FADE_MAX_HITS := 6               ## blockers per view ray
const FADE_RATE := 5.0                 ## fade amount per s (in and out)
const SWING_PROBES := [0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5]  ## rad yaw offsets tried near concrete
const SWING_RECHECK := 0.15            ## s between probe sweeps
const CLOSEUP_PLAYER_SHARE := 0.35     ## close-up look point: this share toward the player
const KO_ORBIT_RATE := 0.35            ## rad/s gentle orbit on the round-over KO
const KO_DIST := 4.6
const KO_PITCH := -0.32
const KO_LOOK_RATE := 3.0
const TRAUMA_DECAY := 1.5              ## per real second
const SHAKE_OFFSET := 0.3              ## m at trauma 1 (linear in trauma)
const SHAKE_ROLL := 0.04               ## rad at trauma 1
const SHAKE_FREQ := 22.0
const KICK_MAX := 0.28                 ## m, directional kick along the hit direction
const KICK_DECAY := 14.0               ## 1/s
const KICK_DAMAGE_DIV := 500.0         ## kick m = 0.03 + damage / this + energy / KICK_ENERGY_DIV
const KICK_ENERGY_DIV := 40000.0
const FOV_BASE := 70.0
const FOV_PUNCH := 3.0                 ## degrees on counters, wall breaks and big launches
const FOV_PUNCH_MINOR := 1.0           ## degrees for a follow-up strike hole in a panel
const FOV_PUNCH_RISE := 0.04
const FOV_PUNCH_HOLD := 0.08
const FOV_PUNCH_END := 0.35
const RING_INNER := 0.42               ## m, soft-target floor ring
const RING_OUTER := 0.5
const RING_ALPHA := 0.5
const CAM_FAR := 250.0
const ARM_RADIUS := 0.25

var target: Fighter

var camera: Camera3D
var arm: SpringArm3D

var _yaw := 0.0
var _pitch := PITCH_DEFAULT
var _look := Vector3.ZERO        ## smoothed look point of the current mode
var _dist := 4.0                 ## smoothed distance of the current mode
var _arm_len := 4.0
var _widen := 0.0                ## 0..1 widen amount
var _trauma := 0.0
var _noise := FastNoiseLite.new()
var _noise_t := 0.0
var _last_manual := -100.0
var _mouse_delta := Vector2.ZERO
var _snap := true
var _kick := Vector3.ZERO
var _fov_punch := 0.0
var _fov_amp := 0.0
var _fov_age := 10.0
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _ring_alpha := 0.0
var _ring_pulse := 0.0
var _ring_for = null

# Modes and blending
var _mode: int = Mode.COMBAT
var _mode_changed_at := -100.0
var _mode_changes := 0
var _blend_t0 := -100.0
var _blend_look := Vector3.ZERO
var _blend_dist := 4.0
var _out_look := Vector3.ZERO
var _out_dist := 4.0

## Untyped on purpose: these may hold freed fighters (corpse faded, round torn
## down); a freed object in a typed variable or parameter is a script error.
var _soft = null
var _soft_changed_at := -100.0
var _framed: Array[Fighter] = []
var _widen_body = null
var _widen_t0 := -100.0
var _widen_let_go := false
var _closeup_on = null
var _closeup_until := -100.0
var _closeup_then_ko := false
var _ko_on = null
var _clear_yaw := 0.0
var _clear_checked_at := -100.0
var _squeezed := false
## Fades: instance id -> {"node", "kind" (&"world"/&"fighter"), "amount", "hit"}
var _fades := {}
var _blocker_names := PackedStringArray()

func _ready() -> void:
	add_to_group(&"camera_rig")
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	arm = SpringArm3D.new()
	arm.name = "SpringArm"
	arm.collision_mask = Layers.WORLD  # rule 4: only floor, outer walls and pillars
	var sphere := SphereShape3D.new()
	sphere.radius = ARM_RADIUS
	arm.shape = sphere
	arm.margin = 0.12
	arm.spring_length = _dist
	add_child(arm)
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.top_level = true
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.fov = FOV_BASE
	camera.near = 0.05
	camera.far = CAM_FAR
	camera.cull_mask = 0xFFFFF
	add_child(camera)
	camera.make_current()
	_build_ring()
	_noise.seed = randi()
	_noise.frequency = 1.0
	GameEvents.screen_shake.connect(_on_screen_shake)
	GameEvents.fighter_launched.connect(_on_fighter_launched)
	GameEvents.thrown.connect(_on_thrown)
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.teleport_counter.connect(_on_teleport_counter)
	GameEvents.wall_broken.connect(_on_wall_broken)
	if target == null:
		target = Targeting.player(get_tree())
	snap_behind()

func _exit_tree() -> void:
	AttackDirector.camera_busy = false  # never leave the token gate shut behind us
	_clear_all_fades()

# --- Public API ------------------------------------------------------------
func add_trauma(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)

func get_trauma() -> float:
	return _trauma

## Short camera jolt along `direction` (world), `strength` metres (capped).
func add_kick(direction: Vector3, strength: float) -> void:
	if direction.length_squared() < 0.0001:
		return
	_kick = (_kick + direction.normalized() * strength).limit_length(KICK_MAX)

## Brief widening of the field of view (counters, wall breaks, big launches).
func punch_fov(degrees: float = FOV_PUNCH) -> void:
	_fov_amp = maxf(_fov_punch, degrees)
	_fov_age = FOV_PUNCH_RISE * clampf(_fov_punch / maxf(_fov_amp, 0.001), 0.0, 1.0)

func get_fov_punch() -> float:
	return _fov_punch

## Pitch the camera really uses (after the clamp and the floor limit).
func get_view_pitch() -> float:
	return _view_pitch()

## Current soft target (enemy nearest the stick, or a token holder). Never a
## downed fighter. Agent B's auto-face prefers this target.
func get_soft_target() -> Fighter:
	return _soft if _targetable(_soft) else null

## Rule 1: there is no follow-cam in play. Kept for AttackDirector, which asks.
func is_follow_cam_active() -> bool:
	return false

## Rule 1: 0..1 how much the frame is widened for a flying body.
func get_widen() -> float:
	return _widen

func get_mode() -> int:
	return _mode

func get_mode_name() -> String:
	return MODE_NAMES[_mode]

## Number of mode changes so far (tests: rate limit).
func get_mode_changes() -> int:
	return _mode_changes

## Names of what currently blocks the view and is being faded (F3, tests).
func get_blockers() -> PackedStringArray:
	return _blocker_names

## Camera yaw basis for camera-relative movement (Y up, -Z forward on the floor).
func get_flat_basis() -> Basis:
	return Basis(Vector3.UP, _yaw)

func get_camera() -> Camera3D:
	return camera

## True if `pos` is inside the camera's view (HUD arrows, breach choice, AI rule 4).
func is_on_screen(pos: Vector3) -> bool:
	return camera != null and camera.is_inside_tree() and camera.is_position_in_frustum(pos)

## Put the camera straight behind the target at once (round start, respawn).
func snap_behind() -> void:
	if not _alive_node(target):
		return
	var f := target.get_forward()
	f.y = 0.0
	if f.length() > 0.01:
		_yaw = atan2(-f.x, -f.z)
	_pitch = PITCH_DEFAULT
	_snap = true

## U7 finisher close-up: push in to Tuning.FINISHER_CLOSEUP.y m on `victim`
## for `duration` real s with the player kept in frame, then back. The time
## scale is the caller's (GameMode requests it). then_ko: stay on the body in
## the round-over KO mode afterwards.
func start_closeup(victim: Node3D, duration: float = Tuning.FINISHER_CLOSEUP.x, then_ko := false) -> void:
	if not _alive_node(victim):
		return
	_closeup_on = victim
	_closeup_until = TimeDirector.now() + duration
	_closeup_then_ko = then_ko
	if then_ko:
		_ko_on = victim
	_request_mode(Mode.CLOSEUP, TimeDirector.now(), true)

func is_closeup_active() -> bool:
	return _mode == Mode.CLOSEUP

## Round over: follow the KO'd body (the player is not in control) with a
## gentle orbit. Kept under its old name for GameMode.
func start_orbit(focus: Node3D) -> void:
	_ko_on = focus
	if _mode != Mode.CLOSEUP:
		_request_mode(Mode.KO, TimeDirector.now(), true)

func stop_orbit() -> void:
	_ko_on = null
	_closeup_then_ko = false

## Kept for compatibility: there is no follow-cam in play any more.
func start_follow(_victim: Fighter) -> void:
	pass

func stop_follow() -> void:
	AttackDirector.camera_busy = false

func get_debug_text() -> String:
	var soft := get_soft_target()
	var what := ""
	if _mode == Mode.CLOSEUP and is_instance_valid(_closeup_on):
		what = _label_of(_closeup_on)
	elif _mode == Mode.KO and is_instance_valid(_ko_on):
		what = _label_of(_ko_on)
	elif _mode == Mode.DOWN and _alive_node(target):
		what = "pelvis of " + _label_of(target)
	elif soft != null:
		what = _label_of(soft)
	else:
		what = "-"
	var line := "cam %s  target %s  dist %.1f arm %.1f  pitch %.0f  widen %.2f  trauma %.2f" % [
		MODE_NAMES[_mode], what, _out_dist, _arm_len, rad_to_deg(_view_pitch()), _widen, _trauma]
	line += "\nblocking: %s%s" % [", ".join(_blocker_names) if not _blocker_names.is_empty() else "nothing",
		"  (squeezed by concrete)" if _squeezed else ""]
	return line

# --- Input -------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_mouse_delta += (event as InputEventMouseMotion).screen_relative

## Mouse / right stick. Any input stamps _last_manual (rule 6).
func apply_manual_input(d: Vector2) -> void:
	if d.length_squared() <= 0.0:
		return
	_yaw -= d.x
	_pitch = clampf(_pitch - d.y, _pitch_min(), _pitch_max())
	_last_manual = TimeDirector.now()

func _read_manual_input(real_dt: float) -> void:
	var d := _mouse_delta * MOUSE_SENS
	_mouse_delta = Vector2.ZERO
	var stick := Input.get_vector(&"cam_left", &"cam_right", &"cam_up", &"cam_down")
	d += stick * STICK_SPEED * real_dt
	apply_manual_input(d)

# --- Update ------------------------------------------------------------------
func _process(_delta: float) -> void:
	var t := TimeDirector.now()
	var dt := TimeDirector.frame_delta()
	if not _alive_node(target):
		target = Targeting.player(get_tree())
	_read_manual_input(dt)
	var desired := _desired_mode(t)
	# Cinematic modes (close-up, KO) cut in at once, and a close-up may hand
	# back as soon as it ends; everything else obeys the rate limit.
	_request_mode(desired, t, desired == Mode.CLOSEUP or desired == Mode.KO or _mode == Mode.CLOSEUP)

	var want_look := _look
	var want_dist := _dist
	var look_rate := LOOK_RATE
	var dist_rate := DIST_RATE
	var fov_extra := 0.0
	var shoulder := 0.0
	match _mode:
		Mode.CLOSEUP:
			var r := _closeup_frame()
			want_look = r[0]
			want_dist = r[1]
			look_rate = 7.0
			dist_rate = CLOSEUP_DIST_RATE
		Mode.KO:
			_yaw += KO_ORBIT_RATE * dt
			_pitch = lerpf(_pitch, KO_PITCH, 1.0 - exp(-2.0 * dt))
			if is_instance_valid(_ko_on):
				want_look = _point_of(_ko_on) + Vector3.UP * 0.2
			want_dist = KO_DIST
			look_rate = KO_LOOK_RATE
		Mode.DOWN:
			if _alive_node(target):
				want_look = _pelvis(target) + Vector3.UP * 0.3
			look_rate = DOWN_LOOK_RATE
			want_dist = clampf(_dist, Tuning.CAM_COMBAT_DIST.x, Tuning.CAM_COMBAT_DIST.y)
			_ease_pitch(dt)
		_:
			if _alive_node(target):
				var r := _combat_frame(t, dt)
				want_look = r[0]
				want_dist = r[1]
				_update_widen(t, dt)
				want_dist += _widen * Tuning.CAM_WIDEN_PULLBACK
				fov_extra = _widen * Tuning.CAM_WIDEN_FOV
				shoulder = 1.0

	if _snap:
		_look = want_look
		_dist = want_dist
		_arm_len = want_dist
		_out_look = want_look
		_out_dist = want_dist
		_blend_t0 = -100.0
		_snap = false
	else:
		_look = _look.lerp(want_look, 1.0 - exp(-look_rate * dt))
		_dist = lerpf(_dist, want_dist, 1.0 - exp(-dist_rate * dt))
	# Mode blend: from the pose at the switch to the new mode's track.
	var w := clampf((t - _blend_t0) / maxf(Tuning.CAM_MODE_BLEND, 0.001), 0.0, 1.0)
	w = smoothstep(0.0, 1.0, w)
	_out_look = _blend_look.lerp(_look, w)
	_out_dist = lerpf(_blend_dist, _dist, w)
	# Rule 5 minimum distance; the finisher close-up (player not in control) may push to its own 2 m.
	_out_dist = maxf(_out_dist, Tuning.FINISHER_CLOSEUP.y if _mode == Mode.CLOSEUP else Tuning.CAM_MIN_DIST)

	global_position = _out_look
	arm.rotation = Vector3(_view_pitch(), _yaw, 0.0)
	arm.spring_length = _out_dist
	var hit := arm.get_hit_length() if arm.is_inside_tree() else _out_dist
	hit = minf(hit, _out_dist)
	var rate := ARM_IN_RATE if hit < _arm_len else ARM_OUT_RATE
	_arm_len = clampf(lerpf(_arm_len, hit, 1.0 - exp(-rate * dt)), 0.3, _out_dist)
	_squeezed = _arm_len < Tuning.CAM_MIN_DIST - 0.05

	_place_camera(dt, fov_extra, shoulder)
	_update_fades(dt)
	_update_ring(dt)

func _desired_mode(t: float) -> int:
	if _mode == Mode.CLOSEUP and t < _closeup_until and is_instance_valid(_closeup_on):
		return Mode.CLOSEUP
	if is_instance_valid(_ko_on) and (_closeup_then_ko or _mode == Mode.KO or _mode == Mode.CLOSEUP):
		return Mode.KO
	if _alive_node(target) and target.is_down():
		return Mode.DOWN
	return Mode.COMBAT

## Rule 7: at most one mode change per CAM_MODE_GAP s, each blended over
## CAM_MODE_BLEND s. `force` (close-up, KO) cuts in at once.
func _request_mode(mode: int, t: float, force: bool) -> bool:
	if mode == _mode:
		return false
	if not force and t - _mode_changed_at < Tuning.CAM_MODE_GAP:
		return false
	_blend_look = _out_look
	_blend_dist = _out_dist
	_blend_t0 = t
	_mode = mode
	_mode_changed_at = t
	_mode_changes += 1
	return true

## Rule 3: player + soft target, distance by token-holder spread, lock-on yaw.
func _combat_frame(t: float, dt: float) -> Array:
	_update_soft_target(t)
	_framed.clear()
	var origin := target.get_ground_position()
	var soft := get_soft_target()
	if soft != null:
		_framed.append(soft)
	for h in _token_holders():
		if not _framed.has(h) and _flat_dist(origin, h.get_ground_position()) < FRAME_RADIUS:
			_framed.append(h)
	var p_aim := target.get_aim_point()
	var look := p_aim
	var spread := 0.0
	for f in _framed:
		spread = maxf(spread, _flat_dist(origin, f.get_ground_position()))
	if soft != null:
		var shift := (soft.get_aim_point() - p_aim) * LOOK_TARGET_SHARE
		shift.y *= 0.5
		look = p_aim + shift.limit_length(LOOK_SHIFT_MAX)
	_auto_rotate(t, dt, soft)
	var k := clampf((spread - SPREAD_NEAR) / (SPREAD_FAR - SPREAD_NEAR), 0.0, 1.0)
	return [look, lerpf(Tuning.CAM_COMBAT_DIST.x, Tuning.CAM_COMBAT_DIST.y, k)]

## Rule 6 / 7: after CAM_MOUSE_IDLE s without camera input, ease back behind
## the player (facing the soft target when there is one) over CAM_RETURN_TIME;
## within SOFT_TURN_WINDOW s of a soft-target change turn at most
## CAM_TARGET_TURN deg/s. Near concrete, prefer the closest open yaw.
func _auto_rotate(t: float, dt: float, soft: Fighter) -> void:
	if t - _last_manual < Tuning.CAM_MOUSE_IDLE:
		return
	var want := _yaw
	if soft != null:
		var to := soft.get_ground_position() - target.get_ground_position()
		to.y = 0.0
		if to.length() > 0.5:
			want = atan2(-to.x, -to.z)
	else:
		var moving := target.move_input.length() > 0.2
		if moving:
			_ease_pitch(dt)
			return  # no auto-turn while running free: avoids steering loops
		var f := target.get_forward()
		f.y = 0.0
		if f.length() > 0.1:
			want = atan2(-f.x, -f.z)
	if _squeezed:
		if t - _clear_checked_at > SWING_RECHECK:
			_clear_checked_at = t
			_clear_yaw = _best_clear_yaw(_point_of_aim(target), want)
		want = _clear_yaw
	var diff := wrapf(want - _yaw, -PI, PI)
	var rate := 3.0 / maxf(Tuning.CAM_RETURN_TIME, 0.05)
	var step := diff * (1.0 - exp(-rate * dt))
	var cap := deg_to_rad(Tuning.CAM_TARGET_TURN) if t - _soft_changed_at < SOFT_TURN_WINDOW else RETURN_MAX_SPEED
	_yaw += clampf(step, -cap * dt, cap * dt)
	_ease_pitch(dt)

func _ease_pitch(dt: float) -> void:
	if TimeDirector.now() - _last_manual < Tuning.CAM_MOUSE_IDLE:
		return
	var rate := 3.0 / maxf(Tuning.CAM_RETURN_TIME, 0.05)
	_pitch = lerpf(_pitch, PITCH_DEFAULT, 1.0 - exp(-rate * dt))

## Rule 1: a body sent more than CAM_WIDEN_TRIGGER m widens the frame for at
## most CAM_WIDEN_TIME s; once it leaves the frame it is let go.
func _update_widen(t: float, dt: float) -> void:
	var want := 0.0
	if is_instance_valid(_widen_body) and _widen_body is Fighter and not _widen_let_go \
			and t - _widen_t0 < Tuning.CAM_WIDEN_TIME:
		var body: Fighter = _widen_body
		var com := body.get_center_of_mass()
		var d := _flat_dist(target.get_ground_position(), com)
		if d > Tuning.CAM_WIDEN_TRIGGER:
			if camera.is_position_in_frustum(com):
				want = clampf((d - Tuning.CAM_WIDEN_TRIGGER) / WIDEN_FULL_EXTRA, 0.2, 1.0)
			else:
				_widen_let_go = true  # it left the frame: let it go
	var r := WIDEN_IN_RATE if want > _widen else WIDEN_OUT_RATE
	_widen = lerpf(_widen, want, 1.0 - exp(-r * dt))
	if _widen < 0.001 and want == 0.0:
		_widen = 0.0

## U7: push in on the victim with the player kept in frame.
func _closeup_frame() -> Array:
	if not _alive_node(_closeup_on):
		return [_look, _dist]
	var v := _point_of(_closeup_on) + Vector3.UP * 0.2
	if not _alive_node(target):
		return [v, Tuning.FINISHER_CLOSEUP.y]
	var p := target.get_aim_point()
	var look := v.lerp(p, CLOSEUP_PLAYER_SHARE)
	var sep := _flat_dist(p, v)
	var dist := clampf(Tuning.FINISHER_CLOSEUP.y + maxf(sep - 1.5, 0.0) * 0.6,
		Tuning.FINISHER_CLOSEUP.y, Tuning.CAM_COMBAT_DIST.x + 0.5)
	return [look, dist]

func _place_camera(dt: float, fov_extra: float, shoulder: float) -> void:
	_trauma = maxf(_trauma - TRAUMA_DECAY * dt, 0.0)
	var view_basis := Basis.from_euler(Vector3(_view_pitch(), _yaw, 0.0))
	var pos := _out_look + view_basis.z * _arm_len
	var shake := _trauma
	if shake > 0.0001:
		_noise_t += dt * SHAKE_FREQ
		var ox := clampf(_noise.get_noise_2d(_noise_t, 0.0) * 1.4, -1.0, 1.0)
		var oy := clampf(_noise.get_noise_2d(_noise_t, 100.0) * 1.4, -1.0, 1.0)
		var orr := clampf(_noise.get_noise_2d(_noise_t, 200.0) * 1.4, -1.0, 1.0)
		pos += (view_basis.x * ox + view_basis.y * oy) * SHAKE_OFFSET * shake
		view_basis = view_basis * Basis(Vector3.BACK, orr * SHAKE_ROLL * shake)
	_kick *= exp(-KICK_DECAY * dt)
	pos += _kick
	camera.global_transform = Transform3D(view_basis, pos)
	_fov_age += dt
	var k := 0.0
	if _fov_age < FOV_PUNCH_RISE:
		k = _fov_age / FOV_PUNCH_RISE
	elif _fov_age < FOV_PUNCH_END:
		k = 1.0 - smoothstep(FOV_PUNCH_HOLD, FOV_PUNCH_END, _fov_age)
	_fov_punch = _fov_amp * k
	camera.fov = FOV_BASE + fov_extra + _fov_punch
	# Rule 3: the player sits CAM_PLAYER_OFFSET_X of the screen width left of
	# centre. Shift the view (projection side, never the arm) by that share of
	# the visible width at the player's depth.
	var want_h := 0.0
	if shoulder > 0.0:
		var aspect := 16.0 / 9.0
		if is_inside_tree():
			var vs := get_viewport().get_visible_rect().size
			aspect = vs.x / maxf(vs.y, 1.0)
		var half_w := _arm_len * tan(deg_to_rad(camera.fov) * 0.5) * aspect
		want_h = -Tuning.CAM_PLAYER_OFFSET_X * 2.0 * half_w * shoulder
	camera.h_offset = lerpf(camera.h_offset, want_h, 1.0 - exp(-4.0 * dt))

## Rule 5: pitch in CAM_PITCH_RANGE, and the camera never below the floor.
func _view_pitch() -> float:
	var p := clampf(_pitch, _pitch_min(), _pitch_max())
	var floor_y := 0.0
	if _alive_node(target):
		floor_y = target.get_ground_position().y
	var room := _out_look.y - floor_y - MIN_CAM_HEIGHT
	var arm_len := maxf(minf(_arm_len, _out_dist), 0.3)
	p = minf(p, asin(clampf(room / arm_len, -1.0, 1.0)))
	return clampf(p, _pitch_min(), _pitch_max())

func _pitch_min() -> float:
	return deg_to_rad(Tuning.CAM_PITCH_RANGE.x)

func _pitch_max() -> float:
	return deg_to_rad(Tuning.CAM_PITCH_RANGE.y)

## Yaw near `around` (SWING_PROBES) with the most room behind `from` against
## the concrete the spring arm collides with, preferring small turns.
func _best_clear_yaw(from: Vector3, around: float) -> float:
	if not is_inside_tree():
		return around
	var space := get_world_3d().direct_space_state
	var best := around
	var best_score := -INF
	var need := Tuning.CAM_COMBAT_DIST.x
	for off: float in SWING_PROBES:
		var y := around + off
		var back := Basis(Vector3.UP, y).z
		var start := from + Vector3.UP * 0.3
		var q := PhysicsRayQueryParameters3D.create(start, start + back * need + Vector3.UP * 0.8, Layers.WORLD)
		var hit := space.intersect_ray(q)
		var clear := need if hit.is_empty() else start.distance_to(hit["position"])
		var score := clear - absf(off) * 0.6
		if score > best_score:
			best_score = score
			best = y
	return best

# --- Blockers fade (rule 4) -------------------------------------------------------
## Cast from the camera to the player (aim point and body) and to the soft
## target; everything on FADE_MASK in the way fades, nothing moves the camera.
func _update_fades(dt: float) -> void:
	for id in _fades:
		_fades[id]["hit"] = false
	if is_inside_tree() and _alive_node(target) and _mode != Mode.KO:
		var points: Array[Vector3] = [target.get_aim_point(), _point_of(target)]
		var soft := get_soft_target()
		if soft != null:
			points.append(soft.get_aim_point())
		var keep: Array = [target, soft]
		for p in points:
			_cast_blockers(camera.global_position, p, keep)
	_blocker_names.clear()
	var drop: Array = []
	for id in _fades:
		var e: Dictionary = _fades[id]
		var node = e["node"]
		if not is_instance_valid(node):
			drop.append(id)
			continue
		var goal := (1.0 - Tuning.CAM_BLOCKER_ALPHA) if e["hit"] else 0.0
		var amount := move_toward(float(e["amount"]), goal, FADE_RATE * dt)
		if not is_equal_approx(amount, float(e["amount"])) or (amount == 0.0 and goal == 0.0):
			_apply_fade(node, e["kind"], amount)
		e["amount"] = amount
		if e["hit"]:
			_blocker_names.append(_label_of(node))
		if amount <= 0.0 and not e["hit"]:
			drop.append(id)
	for id in drop:
		_fades.erase(id)

func _cast_blockers(from: Vector3, to: Vector3, keep: Array) -> void:
	var space := get_world_3d().direct_space_state
	var exclude: Array[RID] = []
	for i in FADE_MAX_HITS:
		var q := PhysicsRayQueryParameters3D.create(from, to, FADE_MASK, exclude)
		q.hit_from_inside = true
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return
		exclude.append(hit["rid"])
		var col = hit["collider"]
		if not is_instance_valid(col):
			continue
		var fighter := _owner_fighter(col)
		if fighter != null:
			if keep.has(fighter):
				continue
			_mark_fade(fighter, &"fighter")
		elif col is Node3D:
			_mark_fade(col, &"world")

func _mark_fade(node: Node3D, kind: StringName) -> void:
	var id := node.get_instance_id()
	if not _fades.has(id):
		_fades[id] = {"node": node, "kind": kind, "amount": 0.0, "hit": true}
	else:
		_fades[id]["hit"] = true

func _apply_fade(node, kind: StringName, amount: float) -> void:
	if not is_instance_valid(node):
		return
	if kind == &"fighter":
		BloodFX.set_fighter_fade(node, amount)
	else:
		WorldMaterials.set_view_fade(node, amount)

func _clear_all_fades() -> void:
	for id in _fades:
		var e: Dictionary = _fades[id]
		_apply_fade(e["node"], e["kind"], 0.0)
	_fades.clear()

## The Fighter a collider belongs to (capsule, physical bone, hurtbox...), or null.
static func _owner_fighter(col) -> Fighter:
	var n = col
	for i in 8:
		if n == null or not is_instance_valid(n):
			return null
		if n is Fighter:
			return n
		n = (n as Node).get_parent()
	return null

# --- Soft target ---------------------------------------------------------------
func _update_soft_target(t: float) -> void:
	var stick := Vector3.ZERO
	if target.brain != null and target.brain.has_method(&"get_stick_world"):
		stick = target.brain.get_stick_world()
	var current_ok := _targetable(_soft) and _flat_dist(target.get_ground_position(), _soft.get_ground_position()) < FRAME_RADIUS
	if stick.length() > 0.2:
		if not current_ok or t - _soft_changed_at > SOFT_TARGET_HOLD:
			_set_soft(Targeting.pick_target(target, stick), t)
		return
	var holders: Array[Fighter] = []
	for h in _token_holders():
		if _targetable(h):
			holders.append(h)
	var holder := _nearest(holders)
	if holder != null:
		_set_soft(holder, t)
	elif not current_ok:
		_set_soft(Targeting.pick_target(target, Vector3.ZERO), t)

func _set_soft(f: Fighter, t: float) -> void:
	if f != _soft:
		_soft = f
		_soft_changed_at = t

func _token_holders() -> Array[Fighter]:
	var out: Array[Fighter] = []
	for h in AttackDirector.get_token_holders():
		if _alive(h):
			out.append(h)
	return out

func _nearest(list: Array[Fighter]) -> Fighter:
	var best: Fighter = null
	var best_d := INF
	var origin := target.get_ground_position()
	for f in list:
		var d := _flat_dist(origin, f.get_ground_position())
		if d < best_d:
			best_d = d
			best = f
	return best

# --- Events --------------------------------------------------------------------
func _on_screen_shake(trauma: float) -> void:
	add_trauma(trauma)

func _on_hit_landed(info: HitInfo) -> void:
	if info == null or not _alive_node(target):
		return
	if info.attacker == target or info.victim == target:
		var k := 0.03 + info.damage / KICK_DAMAGE_DIV + info.energy / KICK_ENERGY_DIV
		add_kick(info.hit_direction, minf(k, KICK_MAX))

func _on_teleport_counter(defender: Node3D, victim: Node3D) -> void:
	if defender == target or victim == target:
		punch_fov()

func _on_wall_broken(wall: Node3D, _position: Vector3, _energy: float, _velocity: Vector3) -> void:
	# Strike-made holes report wall_broken on every jab that knocks cells out:
	# full punch for the first hole or a full break, a light one for the rest.
	punch_fov(FOV_PUNCH if is_headline_break(wall) else FOV_PUNCH_MINOR)

## Is this wall_broken worth the WALL BREAK banner and a full camera punch?
## Impact breaks always are. A strike-made hole (D: Destructible.
## last_break_by_strike / strike_holes) only on the panel's first strike hole
## or when the strike broke the whole panel; further jabs widening a hole are
## not. Reads the fields dynamically so it works before and after D adds them.
static func is_headline_break(wall) -> bool:
	if not is_instance_valid(wall) or not ("last_break_by_strike" in wall):
		return true
	if not bool(wall.get(&"last_break_by_strike")):
		return true
	var holes := int(wall.get(&"strike_holes")) if "strike_holes" in wall else 1
	var broken := bool(wall.get(&"is_broken")) if "is_broken" in wall else false
	return holes <= 1 or broken

## Rule 1: remember the newest fast enemy launch or throw so the frame can widen for it.
func _on_fighter_launched(fighter: Node3D, velocity: Vector3) -> void:
	var f := fighter as Fighter
	if f == null:
		return
	if 0.5 * f.get_total_mass() * velocity.length_squared() >= Tuning.BIG_LAUNCH_ENERGY:
		punch_fov()
	if f != target and velocity.length() > Tuning.FOLLOW_CAM_SPEED * 0.5:
		_track_widen(f)

func _on_thrown(_grabber: Node3D, victim: Node3D, _velocity: Vector3) -> void:
	var f := victim as Fighter
	if f != null and f != target:
		_track_widen(f)

func _track_widen(f: Fighter) -> void:
	_widen_body = f
	_widen_t0 = TimeDirector.now()
	_widen_let_go = false

# --- Soft-target ring ------------------------------------------------------------
func _build_ring() -> void:
	var torus := TorusMesh.new()
	torus.inner_radius = RING_INNER
	torus.outer_radius = RING_OUTER
	torus.rings = 48
	torus.ring_segments = 6
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.albedo_color = Color(UIKit.ACCENT, 0.0)
	_ring = MeshInstance3D.new()
	_ring.name = "SoftTargetRing"
	_ring.mesh = torus
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.layers = Layers.VIS_FX
	_ring.top_level = true
	_ring.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_ring.visible = false
	add_child(_ring)

func _update_ring(dt: float) -> void:
	if _ring == null:
		return
	var soft := get_soft_target()
	var show_ring := soft != null and _mode == Mode.COMBAT
	if show_ring:
		var p := soft.get_ground_position() + Vector3.UP * 0.04
		if soft != _ring_for:
			_ring_pulse = 1.0
			if not is_instance_valid(_ring_for) or _ring_alpha < 0.05:
				_ring.global_position = p
			_ring_for = soft
		_ring.global_position = _ring.global_position.lerp(p, 1.0 - exp(-20.0 * dt))
	_ring_alpha = move_toward(_ring_alpha, RING_ALPHA if show_ring else 0.0, dt * 3.0)
	_ring_pulse = move_toward(_ring_pulse, 0.0, dt * 4.0)
	var sc := 1.0 + 0.35 * _ring_pulse
	_ring.scale = Vector3(sc, 0.06, sc)
	_ring_mat.albedo_color.a = _ring_alpha
	_ring.visible = _ring_alpha > 0.01

func get_ring() -> MeshInstance3D:
	return _ring

# --- Helpers -------------------------------------------------------------------
func _targetable(f) -> bool:
	return _alive(f) and not f.is_down()

func _alive(f) -> bool:
	return is_instance_valid(f) and f is Fighter and f.is_inside_tree() and not f.is_dead()

func _alive_node(n) -> bool:
	return is_instance_valid(n) and n is Node3D and n.is_inside_tree()

func _point_of_aim(n) -> Vector3:
	if n is Fighter:
		var f := n as Fighter
		if f.is_down():
			return _pelvis(f) + Vector3.UP * 0.25
		return f.get_aim_point()
	return n.global_position

func _point_of(n) -> Vector3:
	if n is Fighter:
		return (n as Fighter).get_center_of_mass()
	return n.global_position

## Rule 8: the pelvis (Hips bone) of a downed fighter, else its centre of mass.
func _pelvis(f: Fighter) -> Vector3:
	if f.rig != null and is_instance_valid(f.rig):
		return f.rig.get_bone_global_position(Bones.HIPS)
	return f.get_center_of_mass()

## Readable name for the F3 overlay (fighters by archetype + id: node names collide).
static func _label_of(n) -> String:
	if n is Fighter:
		return "%s#%d" % [String((n as Fighter).archetype), (n as Node).get_instance_id() % 10000]
	return String((n as Node).name)

static func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
