class_name CameraRig
extends Node3D
## BT3-style third-person camera (spec: Game feel > Camera): behind the player,
## mouse / right-stick orbit, frames player + soft target + token holders
## (3-9 m), launch follow-cam, spring arm that ignores debris and ragdolls,
## trauma screen shake. In group "camera_rig".
## OWNER: agent E (feel & flow).
##
## Layout: this node sits on the look point. A SpringArm3D child (rotated by
## yaw/pitch) measures how far back the camera may sit; the Camera3D is
## top_level and placed in _process from the arm's hit length, so it moves at
## frame rate. All smoothing uses real delta so the camera stays responsive in
## slow motion.

# Local tuning (candidates for Tuning).
const MOUSE_SENS := 0.0028             ## rad per screen pixel
const STICK_SPEED := 3.2               ## rad/s at full right-stick deflection
const PITCH_MIN := -1.0                ## rad (~-57 deg, looking down)
const PITCH_MAX := 0.22                ## rad (~13 deg, looking up)
const PITCH_DEFAULT := -0.24           ## rad (~-14 deg)
const TARGET_WEIGHT := 0.33            ## look point: 33% of the way to the framed enemies
const LOOK_SHIFT_MAX := 2.5            ## m, cap on how far the look point leaves the player
const SPREAD_NEAR := 2.0               ## m spread that maps to Tuning.CAM_MIN_DIST
const SPREAD_FAR := 12.0               ## m spread that maps to Tuning.CAM_MAX_DIST
const FRAME_RADIUS := 16.0             ## m, ignore token holders further than this
const POS_SMOOTH := 9.0                ## 1/s look point smoothing
const DIST_SMOOTH := 3.0               ## 1/s distance smoothing
const ARM_IN_SMOOTH := 30.0            ## 1/s when a wall pushes the camera in
const ARM_OUT_SMOOTH := 4.0            ## 1/s when it lets the camera back out
const FOLLOW_LAG := 4.5                ## 1/s look point smoothing on the follow-cam
const FOLLOW_STEER := 2.2              ## rad/s yaw steer toward the flying body
const FOLLOW_END_SPEED := 1.5          ## m/s: follow ends early once the body is this slow
const ASSIST_DEADZONE := 0.75          ## rad off-centre before the framing assist turns the camera
const ASSIST_RATE := 1.4               ## rad/s
const ASSIST_IDLE := 1.0               ## s without manual camera input before the assist acts
const SOFT_TARGET_HOLD := 0.35         ## s minimum between stick-driven soft-target switches
const TRAUMA_DECAY := 1.5              ## per real second
const SHAKE_OFFSET := 0.3              ## m at trauma 1; shake is linear in trauma so light hits show
const SHAKE_ROLL := 0.04               ## rad at trauma 1
const SHAKE_FREQ := 22.0
const KICK_MAX := 0.28                 ## m, directional kick along the hit direction
const KICK_DECAY := 14.0               ## 1/s recovery of the kick
const KICK_DAMAGE_DIV := 500.0         ## kick m = 0.03 + damage / this + energy / KICK_ENERGY_DIV
const KICK_ENERGY_DIV := 40000.0
const FOV_BASE := 70.0
const FOV_PUNCH := 3.0                 ## degrees on counters, wall breaks and big launches
const FOV_PUNCH_RISE := 0.04           ## s to reach the full punch
const FOV_PUNCH_HOLD := 0.08           ## s, full punch held until here
const FOV_PUNCH_END := 0.35            ## s, back to the base FOV
const RING_INNER := 0.42               ## m, soft-target floor ring
const RING_OUTER := 0.5
const RING_ALPHA := 0.5
const FOLLOW_WALL_RANGE := 8.0         ## m, waves: follow only launches heading at a wall this close
const ORBIT_RATE := 0.5                ## rad/s on the KO orbit
const ORBIT_DIST := 4.6
const ORBIT_PITCH := -0.32
const CAM_FAR := 250.0
const SHOULDER_OFFSET := 0.45          ## m, camera shifted right so the player does not hide the target
const MIN_CAM_HEIGHT := 0.35           ## m, camera never goes lower than this above the floor
const TUCK_TARGET_PITCH := -0.8       ## rad (~46 deg down) the view blends to when a wall leaves no room
const TUCK_RATE := 4.0                 ## 1/s
const CLEAR_BEHIND := 1.4              ## m the camera wants between itself and the player (horizontal)
const PITCH_FLOOR := -0.96             ## rad, steepest look-down including the tuck (~55 deg)
const SWING_PROBES := [0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5]  ## rad yaw offsets tried when squeezed
const SWING_RATE := 2.2                ## rad/s yaw swing toward open space along a wall
const SWING_NEED := 3.2                ## m of clear space wanted behind the subject
const SWING_RECHECK := 0.15            ## s between probe sweeps
const DOWN_TARGET_WEIGHT := 0.12       ## look-point weight toward enemies while the player is down
const DOWN_SHIFT_MAX := 0.5            ## m the look point may leave a downed player's body
const ARM_RADIUS := 0.25

var target: Fighter
## Follow-cam length (real s). GameMode shortens it in waves so crowds keep attacking.
var follow_time: float = Tuning.FOLLOW_CAM_TIME
## When true (waves), the follow-cam only runs for launches heading at a wall within FOLLOW_WALL_RANGE.
var follow_needs_wall := false

var camera: Camera3D
var arm: SpringArm3D

var _yaw := 0.0
var _pitch := PITCH_DEFAULT
var _look := Vector3.ZERO
var _dist := Tuning.CAM_MIN_DIST
var _arm_len := Tuning.CAM_MIN_DIST
var _trauma := 0.0
var _noise := FastNoiseLite.new()
var _noise_t := 0.0
var _last_real := 0.0
var _last_manual := -100.0
var _mouse_delta := Vector2.ZERO
var _snap := true
var _kick := Vector3.ZERO       ## directional kick offset (world), decays fast
var _fov_punch := 0.0
var _fov_amp := 0.0
var _fov_age := 10.0
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _ring_alpha := 0.0
var _ring_pulse := 0.0
var _ring_for = null            ## fighter the ring sits under (untyped: may be freed)
var _shoulder := SHOULDER_OFFSET
var _tuck := 0.0                ## 0..1 blend toward TUCK_TARGET_PITCH while a wall leaves no room
var _squeeze := 0.0
var _swing_yaw := 0.0
var _swing_checked_at := -100.0
var _swinging := false          ## latched until the swing reaches its yaw (or the player takes the camera)

## Untyped on purpose: these may hold a freed Fighter (corpse faded, round
## torn down), and passing a freed object to a typed variable or parameter is
## a script error before any is_instance_valid() check can run.
var _soft = null
var _soft_changed_at := -100.0
var _framed: Array[Fighter] = []

# Follow-cam
var _follow = null
var _follow_active := false
var _follow_started := 0.0
var _pending_launch = null
var _pending_launch_at := -100.0
var _recent_player_hits := {}  ## Fighter instance id -> real time the player hit/threw it

# KO orbit
var _orbit = null

# Pursuit cut
var _cut_frames := 0
var _cut_dir := Vector3.ZERO

func _ready() -> void:
	add_to_group(&"camera_rig")
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	arm = SpringArm3D.new()
	arm.name = "SpringArm"
	arm.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
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
	_last_real = TimeDirector.now()
	GameEvents.screen_shake.connect(_on_screen_shake)
	GameEvents.fighter_launched.connect(_on_fighter_launched)
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.thrown.connect(_on_thrown)
	GameEvents.teleport_counter.connect(_on_teleport_counter)
	GameEvents.pursuit.connect(_on_pursuit)
	GameEvents.fighter_grounded.connect(_on_fighter_grounded)
	GameEvents.wall_broken.connect(_on_wall_broken)
	if target == null:
		target = Targeting.player(get_tree())
	snap_behind()

func _exit_tree() -> void:
	# Never leave the token gate shut behind us.
	AttackDirector.camera_busy = false
	_follow_active = false
	_follow = null

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
	# Restart at the current level so overlapping punches never dip.
	_fov_amp = maxf(_fov_punch, degrees)
	_fov_age = FOV_PUNCH_RISE * clampf(_fov_punch / maxf(_fov_amp, 0.001), 0.0, 1.0)

## Pitch the camera is really using (after the wall tuck and floor clamp).
func get_view_pitch() -> float:
	return _view_pitch()

func get_fov_punch() -> float:
	return _fov_punch

## Current soft target (enemy nearest the stick, or a token holder). Never a
## downed fighter. Agent B's auto-face prefers this target.
func get_soft_target() -> Fighter:
	return _soft if _targetable(_soft) else null

func is_follow_cam_active() -> bool:
	return _follow_active

## Camera yaw basis for camera-relative movement (Y up, -Z forward on the floor).
func get_flat_basis() -> Basis:
	return Basis(Vector3.UP, _yaw)

func get_camera() -> Camera3D:
	return camera

## True if `pos` is inside the camera's view (used by the HUD, handy for AI rule 4).
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

## Start a launch follow-cam on `victim` (normally triggered by events).
func start_follow(victim: Fighter) -> void:
	if not _alive_node(victim) or is_instance_valid(_orbit):
		return
	_follow = victim
	_follow_active = true
	_follow_started = TimeDirector.now()
	AttackDirector.camera_busy = true

func stop_follow() -> void:
	AttackDirector.camera_busy = false
	_follow_active = false
	_follow = null

## KO camera: slowly orbit `focus` until stop_orbit().
func start_orbit(focus: Node3D) -> void:
	stop_follow()
	_orbit = focus

func stop_orbit() -> void:
	_orbit = null

func get_debug_text() -> String:
	var mode := "orbit" if is_instance_valid(_orbit) else ("follow" if _follow_active else "frame")
	var soft := get_soft_target()
	return "cam %s  dist %.1f/%.1f  soft %s  trauma %.2f" % [mode, _dist, _arm_len,
		String(soft.name) if soft else "-", _trauma]

# --- Input -------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_mouse_delta += (event as InputEventMouseMotion).screen_relative

func _read_manual_input(real_dt: float) -> void:
	var d := _mouse_delta * MOUSE_SENS
	_mouse_delta = Vector2.ZERO
	var stick := Input.get_vector(&"cam_left", &"cam_right", &"cam_up", &"cam_down")
	d += stick * STICK_SPEED * real_dt
	if d.length_squared() > 0.0:
		_yaw -= d.x
		_pitch = clampf(_pitch - d.y, PITCH_MIN, PITCH_MAX)
		_last_manual = TimeDirector.now()

# --- Update ------------------------------------------------------------------
func _process(_delta: float) -> void:
	var t := TimeDirector.now()
	var real_dt := TimeDirector.frame_delta()
	_last_real = t
	# Hard stop: the follow-cam can never hold AttackDirector's tokens past its time.
	if _follow_active and t - _follow_started > follow_time + 0.25:
		stop_follow()
	if not _alive_node(target):
		target = Targeting.player(get_tree())
	_read_manual_input(real_dt)
	_resolve_pending_launch(t)

	var want_look := _look
	var want_dist := _dist
	var look_rate := POS_SMOOTH
	var want_shoulder := 0.0
	if is_instance_valid(_orbit):
		_yaw += ORBIT_RATE * real_dt
		_pitch = lerpf(_pitch, ORBIT_PITCH, 1.0 - exp(-2.0 * real_dt))
		want_look = _point_of(_orbit) + Vector3.UP * 0.2
		want_dist = ORBIT_DIST
		look_rate = 3.0
	elif _follow_active:
		var r := _update_follow(t, real_dt)
		if r.size() >= 2:
			want_look = r[0]
			want_dist = r[1]
		look_rate = FOLLOW_LAG
	elif _alive_node(target):
		var r := _update_frame(t, real_dt)
		if r.size() >= 2:
			want_look = r[0]
			want_dist = r[1]
		want_shoulder = 0.0 if target.is_down() else SHOULDER_OFFSET

	if _cut_frames > 0:
		_cut_frames -= 1
		if _cut_dir.length() > 0.01:
			_yaw = atan2(-_cut_dir.x, -_cut_dir.z)
		_snap = true

	_shoulder = lerpf(_shoulder, want_shoulder, 1.0 - exp(-3.0 * real_dt))
	if _snap:
		_look = want_look
		_dist = want_dist
		_arm_len = want_dist
		_snap = false
	else:
		_look = _look.lerp(want_look, 1.0 - exp(-look_rate * real_dt))
		_dist = lerpf(_dist, want_dist, 1.0 - exp(-DIST_SMOOTH * real_dt))

	global_position = _look
	arm.rotation = Vector3(_view_pitch(), _yaw, 0.0)
	arm.spring_length = _dist
	var hit := arm.get_hit_length() if arm.is_inside_tree() else _dist
	hit = minf(hit, _dist)
	var rate := ARM_IN_SMOOTH if hit < _arm_len else ARM_OUT_SMOOTH
	_arm_len = lerpf(_arm_len, hit, 1.0 - exp(-rate * real_dt))
	_arm_len = clampf(_arm_len, 0.3, _dist)
	# Backed against a wall, the arm stops at the wall and the camera ends up
	# inside the player's body. Measure the horizontal gap between camera and
	# subject; when it is short, tilt down so the camera rises over the head.
	# First choice is to swing sideways along the wall toward open space; the
	# tuck (rising over the head) only covers what the swing cannot fix.
	var subject = _orbit if is_instance_valid(_orbit) else target
	var squeeze := 0.0
	if _alive_node(subject):
		var back := Basis(Vector3.UP, _yaw).z
		var behind := (_point_of_aim(subject) - _look).dot(back)
		var gap := _arm_len * cos(_view_pitch()) - behind
		squeeze = clampf((CLEAR_BEHIND - gap) / (CLEAR_BEHIND * 0.5), 0.0, 1.0)
		if t - _last_manual < 0.4 or is_instance_valid(_orbit):
			_swinging = false
		elif squeeze > 0.3 and not _swinging:
			_swinging = true
			_swing_checked_at = -100.0
		if _swinging:
			if t - _swing_checked_at > SWING_RECHECK:
				_swing_checked_at = t
				_swing_yaw = _best_clear_yaw(_point_of_aim(subject))
			var dy := wrapf(_swing_yaw - _yaw, -PI, PI)
			_yaw += clampf(dy, -SWING_RATE * real_dt, SWING_RATE * real_dt)
			if absf(dy) < 0.05 and squeeze < 0.3:
				_swinging = false
	_squeeze = squeeze
	_tuck = lerpf(_tuck, squeeze, 1.0 - exp(-TUCK_RATE * real_dt))

	_place_camera(real_dt)
	_update_ring(real_dt)

## Yaw (among SWING_PROBES around the current one) with the most open space
## behind `from`, preferring small turns.
func _best_clear_yaw(from: Vector3) -> float:
	if not is_inside_tree():
		return _yaw
	var space := get_world_3d().direct_space_state
	var best := _yaw
	var best_score := -INF
	for off: float in SWING_PROBES:
		var y := _yaw + off
		var back := Basis(Vector3.UP, y).z
		var start := from + Vector3.UP * 0.3
		var end := start + back * SWING_NEED + Vector3.UP * 0.8
		var q := PhysicsRayQueryParameters3D.create(start, end, Layers.WORLD | Layers.DESTRUCTIBLE)
		var hit := space.intersect_ray(q)
		var clear := SWING_NEED if hit.is_empty() else start.distance_to(hit["position"])
		var score := clear - absf(off) * 0.6
		if score > best_score:
			best_score = score
			best = y
	return best

## Pitch actually used: the player's pitch, blended toward a steep look-down
## when squeezed against a wall (so the camera rises over the head whatever
## the stick says), and limited so the camera stays MIN_CAM_HEIGHT above the
## floor (camera height is look.y - sin(pitch) * arm length).
func _view_pitch() -> float:
	var p := lerpf(_pitch, minf(_pitch, TUCK_TARGET_PITCH), _tuck)
	var floor_y := 0.0
	if _alive_node(target):
		floor_y = target.get_ground_position().y
	var room := _look.y - floor_y - MIN_CAM_HEIGHT
	var arm_len := maxf(minf(_arm_len, _dist), 0.3)
	p = minf(p, asin(clampf(room / arm_len, -1.0, 1.0)))
	return clampf(p, PITCH_FLOOR, PITCH_MAX)

## Normal framing: player + soft target + token holders.
func _update_frame(t: float, real_dt: float) -> Array:
	_update_soft_target(t)
	_framed.clear()
	var origin := target.get_ground_position()
	var soft := get_soft_target()
	if soft != null:
		_framed.append(soft)
	for h in _token_holders():
		if not _framed.has(h) and _flat_dist(origin, h.get_ground_position()) < FRAME_RADIUS:
			_framed.append(h)
	var p_aim := _point_of_aim(target)
	var look := p_aim
	var spread := 0.0
	var weight := DOWN_TARGET_WEIGHT if target.is_down() else TARGET_WEIGHT
	if not _framed.is_empty():
		var centroid := Vector3.ZERO
		for f in _framed:
			centroid += f.get_aim_point()
			spread = maxf(spread, _flat_dist(origin, f.get_ground_position()))
		centroid /= float(_framed.size())
		var shift := (centroid - p_aim) * weight
		shift.y *= 0.5
		look = p_aim + shift.limit_length(DOWN_SHIFT_MAX if target.is_down() else LOOK_SHIFT_MAX)
		if _squeeze < 0.3:  # the wall swing owns the yaw while squeezed
			_framing_assist(t, real_dt, centroid)
	var k := clampf((spread - SPREAD_NEAR) / (SPREAD_FAR - SPREAD_NEAR), 0.0, 1.0)
	return [look, lerpf(Tuning.CAM_MIN_DIST, Tuning.CAM_MAX_DIST, k)]

## Turn the camera slowly toward the framed group when it drifts far off-centre
## and the player has not touched the camera for a moment.
func _framing_assist(t: float, real_dt: float, centroid: Vector3) -> void:
	if t - _last_manual < ASSIST_IDLE:
		return
	var to := centroid - _point_of_aim(target)
	to.y = 0.0
	if to.length() < 1.0:
		return
	var want := atan2(-to.x, -to.z)
	var diff := wrapf(want - _yaw, -PI, PI)
	if absf(diff) < ASSIST_DEADZONE:
		return
	var excess := diff - signf(diff) * ASSIST_DEADZONE
	_yaw += clampf(excess, -ASSIST_RATE * real_dt, ASSIST_RATE * real_dt)

func _update_follow(t: float, real_dt: float) -> Array:
	var elapsed := t - _follow_started
	if not _alive_node(_follow) or elapsed >= follow_time \
			or (elapsed > 0.3 and _follow.get_com_velocity().length() < FOLLOW_END_SPEED):
		stop_follow()
		if _alive_node(target):
			return _update_frame(t, real_dt)
		return [_look, _dist]
	var com: Vector3 = _follow.get_center_of_mass()
	var p_aim := _point_of_aim(target) if _alive_node(target) else com
	var look := p_aim.lerp(com, 0.7)
	var sep := _flat_dist(p_aim, com)
	var dist := clampf(4.5 + sep * 0.35, Tuning.CAM_MIN_DIST, Tuning.CAM_MAX_DIST)
	var to := com - p_aim
	to.y = 0.0
	if to.length() > 1.0 and t - _last_manual > 0.3:
		var want := atan2(-to.x, -to.z)
		var diff := wrapf(want - _yaw, -PI, PI)
		if absf(diff) > 0.35:
			_yaw += clampf(diff, -FOLLOW_STEER * real_dt, FOLLOW_STEER * real_dt)
	return [look, dist]

func _place_camera(real_dt: float) -> void:
	_trauma = maxf(_trauma - TRAUMA_DECAY * real_dt, 0.0)
	var view_basis := Basis.from_euler(Vector3(_view_pitch(), _yaw, 0.0))
	var pos := _look + view_basis.z * _arm_len
	var shake := _trauma  # linear: a 0.1-trauma jab still moves the view ~3 cm
	if shake > 0.0001:
		_noise_t += real_dt * SHAKE_FREQ
		var ox := clampf(_noise.get_noise_2d(_noise_t, 0.0) * 1.4, -1.0, 1.0)
		var oy := clampf(_noise.get_noise_2d(_noise_t, 100.0) * 1.4, -1.0, 1.0)
		var orr := clampf(_noise.get_noise_2d(_noise_t, 200.0) * 1.4, -1.0, 1.0)
		pos += (view_basis.x * ox + view_basis.y * oy) * SHAKE_OFFSET * shake
		view_basis = view_basis * Basis(Vector3.BACK, orr * SHAKE_ROLL * shake)
	_kick *= exp(-KICK_DECAY * real_dt)
	pos += _kick
	camera.global_transform = Transform3D(view_basis, pos)
	# FOV punch envelope (real time): rise, hold, smooth fall.
	_fov_age += real_dt
	var k := 0.0
	if _fov_age < FOV_PUNCH_RISE:
		k = _fov_age / FOV_PUNCH_RISE
	elif _fov_age < FOV_PUNCH_END:
		k = 1.0 - smoothstep(FOV_PUNCH_HOLD, FOV_PUNCH_END, _fov_age)
	_fov_punch = _fov_amp * k
	camera.fov = FOV_BASE + _fov_punch
	# Projection-side shift: moves the view, never the spring arm's origin.
	camera.h_offset = _shoulder

# --- Soft target ---------------------------------------------------------------
func _update_soft_target(t: float) -> void:
	var stick := Vector3.ZERO
	if target.brain != null and target.brain.has_method(&"get_stick_world"):
		stick = target.brain.get_stick_world()
	# Downed fighters are not targets (matches Targeting.pick_target and B's auto-face).
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
	# Directional kick for hits the player deals or takes (crowd hits elsewhere do not jolt).
	if info.attacker == target or info.victim == target:
		var k := 0.03 + info.damage / KICK_DAMAGE_DIV + info.energy / KICK_ENERGY_DIV
		add_kick(info.hit_direction, minf(k, KICK_MAX))
	if info.attacker != null and info.attacker == target:
		_mark_player_hit(info.victim)

func _on_thrown(grabber: Node3D, victim: Node3D, _velocity: Vector3) -> void:
	if grabber == target:
		_mark_player_hit(victim)

func _on_teleport_counter(defender: Node3D, victim: Node3D) -> void:
	if defender == target or victim == target:
		punch_fov()
	if defender == target:
		_mark_player_hit(victim)

func _on_wall_broken(_wall: Node3D, _position: Vector3, _energy: float, _velocity: Vector3) -> void:
	punch_fov()

func _mark_player_hit(victim: Node3D) -> void:
	if victim == null or not is_instance_valid(victim):
		return
	var t := TimeDirector.now()
	_recent_player_hits[victim.get_instance_id()] = t
	_resolve_pending_launch(t)

## A big enemy launch caused by the player starts the follow-cam. The launch
## event and the hit event can arrive in either order within a frame or two,
## so both are matched within PLAYER_CAUSE_WINDOW.
const PLAYER_CAUSE_WINDOW := 0.3

func _on_fighter_launched(fighter: Node3D, velocity: Vector3) -> void:
	var f := fighter as Fighter
	if f == null:
		return
	if 0.5 * f.get_total_mass() * velocity.length_squared() >= Tuning.BIG_LAUNCH_ENERGY:
		punch_fov()
	if f == target or not _alive_node(target) or f.team == target.team:
		return
	if velocity.length() <= Tuning.FOLLOW_CAM_SPEED:
		return
	if follow_needs_wall and not _heading_at_wall(f, velocity):
		return
	_pending_launch = f
	_pending_launch_at = TimeDirector.now()
	_resolve_pending_launch(_pending_launch_at)

## Waves pacing: is a wall (or breakable panel) within FOLLOW_WALL_RANGE along
## the flight? Called from the launch event, which fires inside the physics
## step, so the direct space state is safe to query here.
func _heading_at_wall(f: Fighter, velocity: Vector3) -> bool:
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	if flat.length() < 0.1 or not is_inside_tree():
		return false
	var from := f.get_center_of_mass()
	var query := PhysicsRayQueryParameters3D.create(from, from + flat.normalized() * FOLLOW_WALL_RANGE,
		Layers.WORLD | Layers.DESTRUCTIBLE)
	return not get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func _resolve_pending_launch(t: float) -> void:
	for id in _recent_player_hits.keys():  # forget old hits
		if t - float(_recent_player_hits[id]) > 2.0:
			_recent_player_hits.erase(id)
	if not is_instance_valid(_pending_launch) or t - _pending_launch_at > PLAYER_CAUSE_WINDOW:
		_pending_launch = null
		return
	var hit_at: float = _recent_player_hits.get(_pending_launch.get_instance_id(), -100.0)
	if absf(hit_at - _pending_launch_at) <= PLAYER_CAUSE_WINDOW:
		start_follow(_pending_launch)  # newest big launch wins
		_pending_launch = null

func _on_pursuit(attacker: Node3D, victim: Node3D) -> void:
	if attacker != target:
		return
	stop_follow()
	var a := attacker as Fighter
	var from := a.get_ground_position() if a else attacker.global_position
	var to_pos := (victim as Fighter).get_ground_position() if victim is Fighter else victim.global_position
	_cut_dir = to_pos - from
	_cut_dir.y = 0.0
	if _cut_dir.length() < 0.1 and a:
		_cut_dir = a.get_forward()
	_cut_frames = 3

func _on_fighter_grounded(fighter: Node3D) -> void:
	if fighter == _follow and TimeDirector.now() - _follow_started > 0.3:
		stop_follow()

# --- Soft-target ring ------------------------------------------------------------
## Subtle floor ring under get_soft_target(), so the player knows who attacks
## will auto-face. Flattened torus, unshaded, no shadow, on the FX render layer.
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

func _update_ring(real_dt: float) -> void:
	if _ring == null:
		return
	var soft := get_soft_target()
	var show_ring := soft != null and not _follow_active and not is_instance_valid(_orbit)
	if show_ring:
		var p := soft.get_ground_position() + Vector3.UP * 0.04
		if soft != _ring_for:
			_ring_pulse = 1.0
			if not is_instance_valid(_ring_for) or _ring_alpha < 0.05:
				_ring.global_position = p  # appear in place; slide only between live targets
			_ring_for = soft
		_ring.global_position = _ring.global_position.lerp(p, 1.0 - exp(-20.0 * real_dt))
	_ring_alpha = move_toward(_ring_alpha, RING_ALPHA if show_ring else 0.0, real_dt * 3.0)
	_ring_pulse = move_toward(_ring_pulse, 0.0, real_dt * 4.0)
	var sc := 1.0 + 0.35 * _ring_pulse
	_ring.scale = Vector3(sc, 0.06, sc)
	_ring_mat.albedo_color.a = _ring_alpha
	_ring.visible = _ring_alpha > 0.01

func get_ring() -> MeshInstance3D:
	return _ring

# --- Helpers -------------------------------------------------------------------
## Untyped parameters: safe to call with a freed instance.
func _targetable(f) -> bool:
	return _alive(f) and not f.is_down()

func _alive(f) -> bool:
	return is_instance_valid(f) and f is Fighter and f.is_inside_tree() and not f.is_dead()

func _alive_node(n) -> bool:
	return is_instance_valid(n) and n is Node3D and n.is_inside_tree()

## Point to frame: the aim point, or the body's centre of mass while down
## (the capsule origin can sit far from a ragdoll).
func _point_of_aim(n) -> Vector3:
	if n is Fighter:
		var f := n as Fighter
		if f.is_down():
			return f.get_center_of_mass() + Vector3.UP * 0.25
		return f.get_aim_point()
	return n.global_position

func _point_of(n) -> Vector3:
	if n is Fighter:
		return (n as Fighter).get_center_of_mass()
	return n.global_position

static func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
