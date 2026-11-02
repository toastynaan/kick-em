class_name CameraRig
extends Node3D
## Third-person combat camera: Round 4 free camera and lock-on, Round 5 framing
## (Feel Reference: Effects that sell power > Camera). In group "camera_rig".
## OWNER: agent E (camera & time).
##
## Free by default: in play only mouse / right-stick input turns the camera.
## Automatic, never fighting the player's input:
## - Crowd framing: Tuning.CAM_CROWD_DIST (7 m with CROWD_FROM enemies alive,
##   9 m with a full field) and CAM_CROWD_HEIGHT higher, pulled further back
##   when the player and the nearest CAM_CROWD_FRAME enemies would not fit; one
##   or two left: CAM_DUEL_DIST (4-5 m), low over the shoulder. Blended over time.
## - Sprint: FOV Tuning.CAM_FOV -> CAM_FOV_SPRINT (CAM_FOV_SPRINT_MAX at the
##   upgraded caps), CAM_SPRINT_PULLBACK further, CAM_SPRINT_DROP lower, all
##   by the player's Traversal.sprint_charge.
## - Launch (F1): a body launched or thrown (GameEvents.thrown) near the player pulls the camera
##   back (up to CAM_LAUNCH_DIST) until the player and the body both fit; the
##   look point leans toward the body for at most CAM_LAUNCH_FOLLOW s; yaw turns
##   (at most CAM_LAUNCH_YAW_RATE) only when the body would leave the frame and
##   the player is not turning the camera. The player always stays in frame: a
##   last pass turns the view (not the player's yaw) just enough to keep the
##   player's head, chest and feet inside PLAYER_KEEP of the frame.
## - Fall more than CAM_FALL_FROM m: roll up to CAM_FALL_ROLL, pitch down. The
##   drop is judged whole (fallen so far + height left to the floor below), so
##   the tilt eases in from the top of the fall, not in its last instant.
## - Wall run: shift CAM_WALLRUN_SHIFT toward the open side (in place of the
##   shoulder shift), roll CAM_WALLRUN_ROLL away from the wall, the wall left
##   out of the arm's casts.
## - Shake: trauma (0..1) from GameEvents, shake = trauma^2, decaying
##   Tuning.TRAUMA_DECAY per s. screen_shake stays for one-offs.
## Cinematics the player does not control: the player's own knockdown (keep the
## pelvis in view), the last-kill close-up (GameEvents.last_kill: a cut to a side
## angle at CAM_LAST_KILL_DIST for TimeDirector's last-kill slow motion, then an
## ease back), the death orbit (the player's fighter_died: a slow orbit at
## CAM_DEATH_ORBIT around the ragdoll).
##
## Lock-on (toggle, Controls `lock_on`, cycle with `lock_next` / `lock_prev`):
## the camera stays behind the player's shoulder and keeps an aim point on the
## target at the screen centre, turning at most Tuning.LOCK_TURN_SPEED (the
## launch rate while the target is down). Mouse / stick motion moves that aim
## point over the target's body so the screen-centre zone aim (H) picks the zone.
## get_soft_target() returns the lock target while locked.
##
## Placement (every mode): pivot = look point shifted toward the shoulder (the
## shift is cast against WORLD, so it never pokes into concrete); the camera
## sits `arm` metres behind the pivot along yaw/pitch. Sphere casts against
## Layers.WORLD only (never ragdolls, dead bodies or debris, so a body flying
## past never pushes the camera in): a wide one eases the camera in before a
## wall cuts the view, a narrow one clamps it at once; a line-of-sight check
## shortens the arm if concrete is between the camera and the player. Squeezed
## below CAM_MIN_DIST the view tilts toward the pitch limit instead of entering
## the player. Breakables, debris and bodies in the way fade (never move it).

enum Mode { COMBAT, DOWN, CLOSEUP, KO }
const MODE_NAMES := ["combat", "down", "closeup", "ko"]
const SETTINGS_PATH := "user://settings.cfg"

# Local tuning (candidates for Tuning).
const PITCH_DEFAULT := -0.24           ## rad (~-14 deg)
const FRAME_RADIUS := 16.0             ## m, opponents further than this are not framed / soft targets
const LOOK_RATE := 9.0                 ## 1/s look point tracking (free; a teleport moves < 0.5 m per frame)
const DIST_RATE := 3.0                 ## 1/s distance smoothing
const CLOSEUP_DIST_RATE := 8.0
const ARM_RADIUS := 0.25               ## m, hard clamp cast
const ARM_SOFT_RADIUS := 0.4           ## m, anticipation cast: eases in before the hard clamp bites
const SIGHT_SOFT_RADIUS := 0.35        ## m, anticipation on the camera -> player sight line
const PLAYER_FADE_NEAR := 1.2          ## m: a camera this close to the player starts fading the player...
const PLAYER_FADE_FULL := 0.6          ## ...fully faded (to CAM_BLOCKER_ALPHA) this close
const DOWN_SWING_RATE := 3.0           ## rad/s turn toward open space while the player is down and squeezed
const KEEP_IN_VIEW := 0.75             ## a squeezed camera keeps its subject inside this share of the half FOV
const KEEP_PITCH_MIN := -38.0          ## degrees, the steepest that correction may look down
const ARM_SOFT_IN_RATE := 10.0         ## 1/s
const ARM_OUT_RATE := 4.0              ## 1/s
const ARM_MARGIN := 0.1                ## m kept between the camera sphere and a wall
const SHOULDER_MAX := 1.6              ## m cap on the shoulder shift
const SQUEEZE_TILT_RATE := 6.0         ## 1/s easing back out
const SQUEEZE_TILT_IN_RATE := 20.0     ## 1/s rising when walls close in
const MIN_CAM_HEIGHT := 0.35           ## m above the floor
const PITCH_FLOOR := -55.0             ## degrees: the steepest the framing (crowd height, fall) may look down
const DOWN_LOOK_RATE := 4.0            ## 1/s: lag on the pelvis while the player is down...
const DOWN_MAX_LAG := 1.0              ## ...but the look point stays within this of it (keeps it in view)
const DOWN_SPEED_PULLBACK := 0.15      ## m extra distance per m/s of the flying body
const DOWN_PULLBACK_MAX := 2.0
const SOFT_HOLD := 0.6                 ## s a soft target is held before it may change
const SOFT_SWITCH_MARGIN := 1.0        ## score margin a new soft target must win by
const RECENTRE_TIME := 0.25            ## s, lock_on with nothing to lock eases behind the player
const LOCK_AIM_SENS := 2.5             ## aim units (body half-extents) per rad of camera input
const LOCK_PITCH_RATE := 10.0          ## 1/s pitch tracking while locked
const LOCK_DIST_BASE := 2.6            ## m camera behind the shoulder while locked...
const LOCK_DIST_PER_M := 0.25          ## ...plus this per m between the fighters
const LOCK_AIM_RATE := 20.0            ## 1/s aim point smoothing on the target
const FADE_MASK := Layers.DESTRUCTIBLE | Layers.DEBRIS | Layers.DEBRIS_SMALL | Layers.RAGDOLL | Layers.CAPSULE
const FADE_MAX_HITS := 6
const FADE_RATE := 5.0                 ## 1/s back to opaque once nothing blocks
const FADE_IN_RATE := 10.0             ## 1/s into the fade: a new blocker is half see-through in 50 ms
const CLEAR_PROBES := [0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 2.2, -2.2, PI]
const CLOSEUP_PLAYER_SHARE := 0.35
const RESTORE_RATE := 6.0              ## 1/s yaw ease back to the player's yaw after a close-up
const RESTORE_MAX_SPEED := PI          ## rad/s cap on that return (180 deg/s: a calm turn, not a whip)
const KO_ORBIT_RATE := 0.35            ## rad/s (an enemy's round-ending KO, legacy start_orbit)
const KO_ORBIT_SQUEEZED := 1.2         ## rad/s while a wall crowds the orbit
const KO_DIST := 4.6
const KO_PITCH := -0.32
const KO_LOOK_RATE := 3.0
const KICK_MAX := 0.28
const KICK_DECAY := 14.0
const KICK_DAMAGE_DIV := 500.0
const KICK_ENERGY_DIV := 40000.0
const FOV_PUNCH := 3.0
const FOV_PUNCH_MINOR := 1.0           ## degrees for a follow-up strike hole in a panel
const FOV_PUNCH_RISE := 0.04
const FOV_PUNCH_HOLD := 0.08
const FOV_PUNCH_END := 0.35
const RING_INNER := 0.42
const RING_OUTER := 0.5
const RING_ALPHA := 0.5
const CAM_FAR := 250.0

# Round 5 framing (local; Tuning holds the doc's numbers).
## Enemies alive for the crowd framing. The doc says "many" vs "one or two
## left", so three is already a crowd (wave 1 is three grunts).
const CROWD_FROM := 3
const CROWD_RATE := 1.5                ## 1/s blend between duel and crowd framing (95% in 2 s: smooth, never a pump)
const DUEL_SEP := Vector2(2.0, 6.0)    ## m to the farther of the last two enemies -> CAM_DUEL_DIST.x..y
const DUEL_DROP := 0.35                ## m lower than the default height: "low over the shoulder"
const FIT_STEP := 0.25                 ## m steps when fitting a distance
const CROWD_SAFE := 0.85               ## share of the half frame the framed enemies must sit inside
const HEIGHT_RATE := 2.0               ## 1/s height smoothing
const LOCK_HEIGHT_RATE := 8.0          ## 1/s: locking drops the height offset quickly (aim point on the centre ray)
## Launch framing (F1).
const LAUNCH_PLAYER_SAFE := 0.7        ## the lean never puts the player beyond this share of the half frame
const LAUNCH_BODY_SAFE := 0.9          ## the body counts as framed inside this share
const LAUNCH_LEAN_SHARE := 0.5         ## look point at most halfway to the body...
const LAUNCH_LEAN_MAX := 3.0           ## ...and at most this far (m)
const LAUNCH_LEAN_DEPTH := 1.0         ## m the look point may move away from the camera (the pull-back covers depth)
const LAUNCH_LEAN_UP := 1.5            ## m it may rise
const LAUNCH_LEAN_IN := 0.12           ## s to lean in
const LAUNCH_LEAN_OUT := Vector2(0.6, 0.88)  ## s: lean back out, done before CAM_LAUNCH_FOLLOW with the smoothing
const LAUNCH_LOOK_RATE := 14.0         ## 1/s look smoothing while a launch is framed
const LAUNCH_DIST_STEP := 0.5
const LAUNCH_LOOKAHEAD := 0.2         ## s ahead the body must also fit (game time: slow motion shortens it)
const LAUNCH_DIST_RATE := 5.0          ## 1/s pull-back for a launch (quicker than the crowd's DIST_RATE)
const LEAN_STEPS: Array[float] = [1.0, 0.66, 0.33, 0.0]  ## share of the lean tried, largest first
const LAUNCH_INPUT_YIELD := 0.4        ## s after camera input with no launch yaw (never against the player)
const LAUNCH_YAW_REACH := 100.0        ## degrees: a body further round than this is not chased (it cannot be caught)
const PLAYER_KEEP := 0.9               ## the player's head / chest / feet stay inside this share of the half frame
## Sprint, fall, wall run.
const SPRINT_RISE_RATE := 8.0          ## 1/s FOV / distance follow sprint_charge up...
const SPRINT_FALL_RATE := 4.0          ## ...and ease down (a sprint strike drops to walk at once; the FOV must not snap)
const FALL_RAMP := 0.5                 ## m past CAM_FALL_FROM to the full roll: a 3.5 m drop tilts fully (the Yard's falls are short)
const FALL_PITCH := 12.0               ## degrees down at the full fall tilt (shows the ground)
const FALL_RISE_RATE := 8.0            ## 1/s into the tilt (95% in under 0.4 s, about a third of a 3.3 m drop)...
const FALL_RATE := 5.0                 ## ...and out of it after landing
const WALLRUN_RATE := 6.0
const WALLRUN_EXCLUDE_GRACE := 0.5     ## s the run wall stays out of the casts after the run (the shift eases back)
## WORLD geometry whose top is at most this above the player's floor (low walls,
## the 1.8 m platform's deck and posts) is passed through by the arm's casts,
## shape by shape (they can be shapes of one big static body), and fades when it
## blocks the view, so running past it never yanks the camera in.
const LOW_OBSTACLE_MAX := 2.0
const LOW_SKIP_MAX := 4                ## low shapes one cast may pass through
## Shake and trauma.
const SHAKE_OFFSET := 0.35             ## m at shake 1
const SHAKE_ANGLE := 3.0               ## degrees yaw / pitch at shake 1
const SHAKE_ROLL := 3.0                ## degrees at shake 1
const SHAKE_FREQ := 22.0
const HARD_LANDING_TRAUMA := 0.15      ## the landing table's "light shake" (no Tuning row)
const FURNITURE_TRAUMA := 0.15         ## broken furniture / clutter / door frames: a small shake, no wall-break punch
const FURNITURE_GROUP := 0.1           ## s: things breaking together (one flight through a shelf and a table) shake once
const HEAVY_DEDUPE := 0.25             ## s: a body slam and its heavy landing shake once
## Round 6: a falling structure piece (a pillar's beam and sign, a lintel) landing:
## a heavy thump, Tuning.TRAUMA heavy_landing at THUMP_FULL_ENERGY J and up,
## less for lighter pieces, faded with distance like other far events.
const THUMP_FULL_ENERGY := 3000.0      ## J (the 160 kg beam off a 4 m pillar lands with ~6,000)
const THUMP_MIN_SHARE := 0.3
const THUMP_MIN_SPEED := 3.0           ## m/s falling before the landing (as FallingPiece)
const THUMP_GROUP := 0.3               ## s: pieces landing together (a collapse) are one thump, by their summed energy
const THUMP_WINDOW := 0.1              ## game s: an impact is the speed falling under half its recent falling peak within this
const STRIKE_HOLE_TRAUMA := 0.2        ## a follow-up strike hole in a panel (not a headline break)
const TRAUMA_FAR := Vector2(10.0, 25.0) ## m from the player: event trauma fades from full to TRAUMA_FAR_MIN
const TRAUMA_FAR_MIN := 0.3
## Last kill and death.
const LAST_KILL_PITCH := -0.14         ## rad (-8 deg): a low side angle
const LAST_KILL_FIT_MAX := 6.0         ## m: pulled back at most this far to keep the player in the close-up
const CINE_RETURN_BLEND := 0.5         ## s ease back from a cinematic
const DEATH_ORBIT_RATE := 0.5          ## rad/s: about 30 deg over the 1.0 s slow motion
const DEATH_PITCH := -0.38             ## rad
const DEATH_LOOK_RATE := 5.0

## Player settings (pause menu, saved to SETTINGS_PATH).
static var sensitivity := 1.0
static var invert_y := false
static var _settings_loaded := false

var target: Fighter
## False ignores lock input (round over, menus).
var input_enabled := true

var camera: Camera3D
var arm: SpringArm3D   ## kept for tools: its mask is the same WORLD-only collision

var _yaw := 0.0
var _pitch := PITCH_DEFAULT
var _view_pitch_v := PITCH_DEFAULT
var _tilt := 0.0                 ## 0..1 squeeze tilt toward the pitch limit
var _look := Vector3.ZERO
var _dist := 4.0
var _arm_len := 4.0
var _soft_len := 4.0
var _out_look := Vector3.ZERO
var _out_dist := 4.0
var _pivot := Vector3.ZERO
var _shoulder := 0.0
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

var _mode := Mode.COMBAT
var _mode_changed_at := -100.0
var _mode_changes := 0
var _blend_t0 := -100.0
var _blend_time := 0.25
var _blend_look := Vector3.ZERO
var _blend_dist := 4.0

## Untyped on purpose: may hold freed fighters (a freed object in a typed
## variable or parameter is a script error before is_instance_valid runs).
var _soft = null
var _soft_changed_at := -100.0
var _framed: Array[Fighter] = []
var _closeup_on = null
var _closeup_until := -100.0
var _closeup_then_ko := false
var _closeup_cut := false
var _cine_yaw := 0.0
var _restore_yaw := 0.0
var _restore_pitch := PITCH_DEFAULT
var _restore_pending := false
var _ko_on = null
var _lock = null
var _lock_aim := Vector2.ZERO    ## x: across the body (arms), y: up (head) / down (legs); -1..1
var _lock_aim_point := Vector3.ZERO
var _lock_hidden := 0.0
var _recentre_t0 := -100.0
var _recentre_from := 0.0
var _recentre_to := 0.0
var _squeezed := false
var _fades := {}
var _blocker_names := PackedStringArray()
var _last_cam_pos := Vector3.ZERO
var _player_fade := 0.0
var _cast_sphere := SphereShape3D.new()
var _cast_q := PhysicsShapeQueryParameters3D.new()
var _cam_snapped := 0             ## frames where the camera moved > 0.5 m (debug)

# Round 5 state.
var _tan_v := 0.7                 ## tan(half vertical FOV) of the current frame
var _tan_h := 1.24                ## tan(half horizontal FOV)
var _enemies_alive := 0
var _crowd_k := 0.0               ## 0 duel .. 1 crowd framing
var _height := 0.0                ## m the camera sits above (below) the plain orbit (smoothed)
var _out_height := 0.0            ## _height after the mode blend (what the camera uses)
var _blend_height := 0.0
var _sprint_k := 0.0              ## smoothed sprint_charge
var _fov_top := 78.0              ## FOV at sprint_charge 1 for the current cap
var _fall_k := 0.0
var _fall_sign := 1.0
var _wall_k := 0.0
var _wall_normal := Vector3.ZERO
var _wall_until := -100.0         ## the run wall stays out of the casts until this real time
var _exclude: Array[RID] = []     ## colliders left out of the arm casts (run wall + low obstacles)
var _wall_rids: Array[RID] = []   ## the wall being run on
var _floor_y := 0.0               ## the player's floor height this frame (low-geometry rule)
var _shape_boxes := {}            ## CollisionShape3D instance id -> world AABB (static geometry)
var _shape_meshes := {}           ## CollisionShape3D instance id -> the mesh drawn for it (or null)
var _pieces := {}                 ## falling piece instance id -> {"peak" m/s, "at" game s}
var _game_t := 0.0                ## game seconds (physics deltas) for the impact windows
var _last_thump := -100.0
var _last_thump_amount := 0.0
var _group_energy := 0.0          ## J landed in the current thump group
var _thumps := 0                  ## thumps that added trauma (debug, tests)
var _thump_info := {}             ## the last one: {"energy", "amount" (before distance), "pos"}
var _last_heavy := -100.0         ## real time of the last heavy-landing / slam trauma
var _last_furniture := -100.0     ## real time of the last furniture shake
var _roll := 0.0                  ## rad of framing roll (fall, wall run), before shake
var _pitch_off := 0.0             ## rad of framing pitch (fall)
var _shift := Vector3.ZERO        ## world pivot shift (wall run)
var _fov := 70.0
var _launch_body = null           ## untyped: may be freed
var _launch_t0 := -100.0
var _launch_w := 0.0              ## lean envelope 0..1 this frame
var _launch_lean := Vector3.ZERO  ## smoothed look offset toward the body
var _launch_dist := 0.0           ## fitted distance this frame (0 = none)
var _launch_body_framed := false
var _auto_yaw_rate := 0.0         ## rad/s of launch yaw this frame (tests)
var _view_corrected := 0.0        ## rad the player-in-frame pass turned the view this frame
var _death := false               ## the KO orbit is the player's death orbit

func _ready() -> void:
	add_to_group(&"camera_rig")
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	load_settings()
	arm = SpringArm3D.new()
	arm.name = "SpringArm"
	arm.collision_mask = Layers.WORLD  # only floor, outer walls and pillars: never bodies or debris
	var sphere := SphereShape3D.new()
	sphere.radius = ARM_RADIUS
	arm.shape = sphere
	arm.margin = ARM_MARGIN
	arm.spring_length = _dist
	add_child(arm)
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.top_level = true
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.fov = Tuning.CAM_FOV
	camera.near = 0.05
	camera.far = CAM_FAR
	camera.cull_mask = 0xFFFFF
	add_child(camera)
	camera.make_current()
	_fov = Tuning.CAM_FOV
	_build_ring()
	_noise.seed = randi()
	_noise.frequency = 1.0
	_cast_q.shape = _cast_sphere
	_cast_q.collision_mask = Layers.WORLD
	GameEvents.screen_shake.connect(_on_screen_shake)
	GameEvents.fighter_launched.connect(_on_fighter_launched)
	GameEvents.thrown.connect(_on_thrown)
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.teleport_counter.connect(_on_teleport_counter)
	GameEvents.teleported.connect(_on_teleported)
	GameEvents.wall_broken.connect(_on_wall_broken)
	GameEvents.limb_severed.connect(_on_limb_severed)
	GameEvents.landing.connect(_on_landing)
	GameEvents.rammed.connect(_on_rammed)
	GameEvents.last_kill.connect(_on_last_kill)
	GameEvents.fighter_died.connect(_on_fighter_died)
	GameEvents.wall_run_started.connect(_on_wall_run_started)
	GameEvents.wall_run_ended.connect(_on_wall_run_ended)
	GameEvents.body_slammed.connect(_on_body_slammed)
	GameEvents.furniture_broken.connect(_on_furniture_broken)
	if target == null:
		target = Targeting.player(get_tree())
	snap_behind()

func _exit_tree() -> void:
	AttackDirector.camera_busy = false
	_clear_all_fades()
	if _player_fade > 0.0 and is_instance_valid(target):
		BloodFX.set_fighter_fade(target, 0.0)
		_player_fade = 0.0

# --- Settings ----------------------------------------------------------------
static func load_settings() -> void:
	if _settings_loaded:
		return
	_settings_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		sensitivity = clampf(float(cfg.get_value("camera", "mouse_sensitivity", 1.0)),
			Tuning.CAM_SENS_RANGE.x, Tuning.CAM_SENS_RANGE.y)
		invert_y = bool(cfg.get_value("camera", "invert_y", false))

static func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # keep other sections
	cfg.set_value("camera", "mouse_sensitivity", sensitivity)
	cfg.set_value("camera", "invert_y", invert_y)
	cfg.save(SETTINGS_PATH)

## Mouse pixels arrive in physical pixels on HiDPI (retina) screens: scale back
## to logical points so retina and non-retina feel the same.
static func mouse_scale() -> float:
	if DisplayServer.get_name() == "headless":
		return 1.0
	var s := DisplayServer.screen_get_scale(DisplayServer.window_get_current_screen())
	return 1.0 / maxf(s, 1.0)

# --- Public API ------------------------------------------------------------
## Trauma 0..1 (shake = trauma^2). One-offs; events add their own.
func add_trauma(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)

func get_trauma() -> float:
	return _trauma

## Current shake strength (trauma^2).
func get_shake() -> float:
	return _trauma * _trauma

func add_kick(direction: Vector3, strength: float) -> void:
	if direction.length_squared() < 0.0001:
		return
	_kick = (_kick + direction.normalized() * strength).limit_length(KICK_MAX)

func punch_fov(degrees: float = FOV_PUNCH) -> void:
	_fov_amp = maxf(_fov_punch, degrees)
	_fov_age = FOV_PUNCH_RISE * clampf(_fov_punch / maxf(_fov_amp, 0.001), 0.0, 1.0)

func get_fov_punch() -> float:
	return _fov_punch

## Pitch the camera really uses (after the clamp, squeeze tilt, height and floor limit).
func get_view_pitch() -> float:
	return _view_pitch_v

## Framing distance (m) the camera is aiming for this frame, before walls.
func get_distance() -> float:
	return _out_dist

## Real camera distance behind the pivot after walls (m).
func get_arm_length() -> float:
	return _arm_len

## Living enemies the framing counts, and the crowd blend (0 duel .. 1 crowd).
func get_enemies_alive() -> int:
	return _enemies_alive

func get_crowd_factor() -> float:
	return _crowd_k

## m the camera sits above the plain orbit (crowd height, duel drop, sprint drop).
func get_height() -> float:
	return _out_height

## Framing roll (fall, wall run) in degrees, before shake.
func get_roll_degrees() -> float:
	return rad_to_deg(_roll)

## Framing FOV (sprint), before the FOV punch.
func get_fov() -> float:
	return _fov

## Launch framing: the body being framed (null when none) and its lean 0..1.
func get_launch_body() -> Fighter:
	return _launch_body if _alive_node(_launch_body) and _launch_w > 0.0 else null

## Rad/s the launch framing turned the yaw this frame (0 when it did not).
func get_auto_yaw_rate() -> float:
	return _auto_yaw_rate

## Rad the player-in-frame pass turned the view this frame (0 almost always).
func get_view_correction() -> float:
	return _view_corrected

## Seconds since the last mouse / stick camera input.
func get_input_age() -> float:
	return TimeDirector.now() - _last_manual

## &"last_kill" during the close-up, &"death" during the death orbit, &"ko" for
## an enemy's KO orbit, else &"".
func get_cinematic() -> StringName:
	if _mode == Mode.CLOSEUP:
		return &"last_kill"
	if _mode == Mode.KO:
		return &"death" if _death else &"ko"
	return &""

## Combat aim target: the lock target while locked, else a stable soft target
## (held SOFT_HOLD s, picked by facing / stick and distance). Never downed.
func get_soft_target() -> Fighter:
	if is_instance_valid(_lock) and _alive(_lock):
		return _lock
	return _soft if _targetable(_soft) else null

## Lock-on target (null when the camera is free). H reads this.
func get_lock_target() -> Fighter:
	return _lock if is_instance_valid(_lock) and _alive(_lock) else null

func is_locked() -> bool:
	return get_lock_target() != null

## Locked and the target is not flying: the lock frames it. While a locked
## target is launched the launch framing takes over (the lock stays).
func _lock_framing() -> bool:
	var lf := get_lock_target()
	return lf != null and not lf.is_launched()

## Aim point on the locked target's body (world), or Vector3.ZERO when free.
func get_lock_aim_point() -> Vector3:
	return _lock_aim_point if is_locked() else Vector3.ZERO

## -1..1 aim offset on the locked body (x: arms, y: head / legs).
func get_lock_aim() -> Vector2:
	return _lock_aim

## There is no follow-cam in play. Kept for AttackDirector, which asks.
func is_follow_cam_active() -> bool:
	return false

## Launch framing lean 0..1 (the Round 4 "widen" became the launch framing).
func get_widen() -> float:
	return _launch_w

func get_mode() -> int:
	return _mode

func get_mode_name() -> String:
	return MODE_NAMES[_mode]

func get_mode_changes() -> int:
	return _mode_changes

func get_blockers() -> PackedStringArray:
	return _blocker_names

## Camera yaw basis for camera-relative movement (Y up, -Z forward on the floor).
func get_flat_basis() -> Basis:
	return Basis(Vector3.UP, _yaw)

func get_camera() -> Camera3D:
	return camera

func is_on_screen(pos: Vector3) -> bool:
	return camera != null and camera.is_inside_tree() and camera.is_position_in_frustum(pos)

## Put the camera straight behind the target at once (round start).
func snap_behind() -> void:
	if not _alive_node(target):
		return
	_yaw = _yaw_behind(target)
	_pitch = PITCH_DEFAULT
	_snap = true

## Close-up framed from the side of the player -> victim line (the side with
## more room), then back to the yaw the player had. cut: jump there at once
## (the last kill); otherwise ease in. Calling it again on the same victim only
## extends it (the camera's own last_kill listener and GameMode may both ask).
func start_closeup(victim: Node3D, duration: float = float(Tuning.SLOW_TIME[&"last_kill"]["time"]),
		then_ko := false, cut := false) -> void:
	if not _alive_node(victim):
		return
	var t := TimeDirector.now()
	if _mode == Mode.CLOSEUP and _closeup_on == victim and t < _closeup_until:
		_closeup_until = maxf(_closeup_until, t + duration)
		_closeup_then_ko = _closeup_then_ko or then_ko
		if then_ko:
			_ko_on = victim
			_restore_pending = false
		return
	_closeup_on = victim
	_closeup_until = t + duration
	_closeup_then_ko = then_ko
	_closeup_cut = cut
	if then_ko:
		_ko_on = victim
	if _mode != Mode.CLOSEUP and _mode != Mode.KO:
		_restore_yaw = _yaw
		_restore_pitch = _pitch
		_restore_pending = not then_ko
	_cine_yaw = _side_yaw(victim)
	if _request_mode(Mode.CLOSEUP, t, true) and cut:
		_yaw = _cine_yaw
		_pitch = LAST_KILL_PITCH
		_snap = true

func is_closeup_active() -> bool:
	return _mode == Mode.CLOSEUP

## Round over: a gentle orbit around `focus` (the player is not in control),
## starting where a wall does not block it. On the player it is the death orbit
## (Tuning.CAM_DEATH_ORBIT). Calling it again on the same focus does nothing.
func start_orbit(focus: Node3D) -> void:
	if _ko_on == focus and is_instance_valid(focus) and (_mode == Mode.KO or _mode == Mode.CLOSEUP):
		return
	_ko_on = focus
	_death = focus == target
	unlock()
	if _alive_node(focus):
		_yaw = _best_clear_yaw(_point_of(focus), _yaw, _orbit_dist())
	if _mode != Mode.CLOSEUP:
		_request_mode(Mode.KO, TimeDirector.now(), true)

func stop_orbit() -> void:
	_ko_on = null
	_death = false
	_closeup_then_ko = false

func start_follow(_victim: Fighter) -> void:
	pass

func stop_follow() -> void:
	AttackDirector.camera_busy = false

# --- Lock-on -------------------------------------------------------------------
## lock_on: lock the enemy nearest the screen centre in range and in view;
## locked: unlock; nothing to lock: recentre behind the player.
func toggle_lock() -> void:
	if is_locked():
		unlock()
		return
	var best := _pick_lock_candidate()
	if best != null:
		_set_lock(best)
	else:
		recentre()

func unlock() -> void:
	if _lock != null:
		_lock = null
		_lock_aim = Vector2.ZERO
		_pitch = clampf(_view_pitch_v, _pitch_min(), _pitch_max())
		_emit_lock(null)

## +1: next enemy to the right on screen, -1: to the left.
func cycle_lock(direction: int) -> void:
	if not is_locked():
		return
	var cur: Fighter = _lock
	var cur_x := _screen_x(cur)
	var best: Fighter = null
	var best_dx := INF
	for f in _lock_candidates(true):
		if f == cur:
			continue
		var dx := (_screen_x(f) - cur_x) * float(direction)
		if dx > 0.0 and dx < best_dx:
			best_dx = dx
			best = f
	if best != null:
		_set_lock(best)

## Ease behind the player in RECENTRE_TIME (lock_on with nothing to lock).
func recentre() -> void:
	if not _alive_node(target):
		return
	_recentre_from = _yaw
	_recentre_to = _yaw_behind(target)
	_recentre_t0 = TimeDirector.now()

func _set_lock(f: Fighter) -> void:
	if f == _lock:
		return
	_lock = f
	_lock_aim = Vector2.ZERO  # chest
	_lock_hidden = 0.0
	if _alive(f):
		_lock_aim_point = _body_point(f, _lock_aim)
	_emit_lock(f)

func _emit_lock(f: Fighter) -> void:
	GameEvents.lock_on_changed.emit(target if _alive_node(target) else null, f)

func _lock_candidates(need_view: bool) -> Array[Fighter]:
	var out: Array[Fighter] = []
	if not _alive_node(target):
		return out
	var origin := target.get_ground_position()
	for f in Targeting.opponents_of(target):
		if _flat_dist(origin, f.get_ground_position()) > Tuning.LOCK_RANGE:
			continue
		if need_view and not camera.is_position_in_frustum(f.get_aim_point()):
			continue
		out.append(f)
	return out

func _pick_lock_candidate() -> Fighter:
	var best: Fighter = null
	var best_angle := INF
	var fwd := -camera.global_basis.z
	for f in _lock_candidates(true):
		var to := (f.get_aim_point() - camera.global_position).normalized()
		var ang := fwd.angle_to(to)
		if ang < best_angle:
			best_angle = ang
			best = f
	return best

func _screen_x(f: Fighter) -> float:
	var p := f.get_aim_point()
	var right := camera.global_basis.x
	return (p - camera.global_position).dot(right)

## Drops on range, hidden too long or the player's death; retargets on KO.
func _update_lock_validity(dt: float) -> void:
	if _lock == null:
		return
	if not _alive_node(target) or target.is_dead():
		unlock()
		return
	if not is_instance_valid(_lock) or not _alive(_lock):
		_lock = null
		var next: Fighter = null
		if Tuning.LOCK_RETARGET_ON_KO:
			var best_d := INF
			for f in _lock_candidates(false):
				var d := _flat_dist(target.get_ground_position(), f.get_ground_position())
				if d < best_d:
					best_d = d
					next = f
		if next != null:
			_set_lock(next)
		else:
			_lock_aim = Vector2.ZERO
			_emit_lock(null)
		return
	var lf: Fighter = _lock
	if _flat_dist(target.get_ground_position(), lf.get_ground_position()) > Tuning.LOCK_BREAK_RANGE:
		unlock()
		return
	var q := PhysicsRayQueryParameters3D.create(target.get_aim_point(), lf.get_aim_point(), Layers.WORLD)
	if not get_world_3d().direct_space_state.intersect_ray(q).is_empty():
		_lock_hidden += dt
		if _lock_hidden > Tuning.LOCK_LOS_GRACE:
			unlock()
	else:
		_lock_hidden = 0.0

## World point on `f`'s body for an aim offset: y 1 = head, 0 = chest,
## -1 = lower legs; x moves toward the forearm on that screen side. Uses the
## hurtbox capsule centres (what H's zone aim tests), else bone positions.
func _body_point(f: Fighter, aim: Vector2) -> Vector3:
	if f.rig == null or not is_instance_valid(f.rig):
		return f.get_aim_point() + Vector3.UP * aim.y * 0.5
	var chest := _part_center(f, Bones.CHEST)
	var p := chest
	if aim.y >= 0.0:
		p = chest.lerp(_part_center(f, Bones.HEAD), aim.y)
	else:
		var hips := _part_center(f, Bones.HIPS)
		var shins := (_part_center(f, Bones.L_LOWER_LEG) + _part_center(f, Bones.R_LOWER_LEG)) * 0.5
		var y := -aim.y
		p = chest.lerp(hips, minf(y * 2.0, 1.0)) if y <= 0.5 else hips.lerp(shins, (y - 0.5) * 2.0)
	if absf(aim.x) > 0.01:
		var right := camera.global_basis.x
		var la := (f.rig.get_bone_global_position(Bones.L_LOWER_ARM) + f.rig.get_bone_global_position(Bones.L_HAND)) * 0.5
		var ra := (f.rig.get_bone_global_position(Bones.R_LOWER_ARM) + f.rig.get_bone_global_position(Bones.R_HAND)) * 0.5
		var side_arm := la if (la - ra).dot(right) * signf(aim.x) > 0.0 else ra
		p = p.lerp(side_arm, absf(aim.x))
	return p

## Centre of the fighter's hurtbox capsule on `bone`, else the bone position.
func _part_center(f: Fighter, bone: StringName) -> Vector3:
	if "hurtboxes" in f:
		for hb in f.get(&"hurtboxes"):
			if is_instance_valid(hb) and hb.get(&"bone") == bone:
				for c in (hb as Node).get_children():
					if c is CollisionShape3D:
						return (c as CollisionShape3D).global_position
	return f.rig.get_bone_global_position(bone)

# --- Debug --------------------------------------------------------------------
func get_debug_text() -> String:
	var soft := get_soft_target()
	var what := "-"
	if _mode == Mode.CLOSEUP and is_instance_valid(_closeup_on):
		what = _label_of(_closeup_on)
	elif _mode == Mode.KO and is_instance_valid(_ko_on):
		what = _label_of(_ko_on)
	elif _mode == Mode.DOWN and _alive_node(target):
		what = "pelvis of " + _label_of(target)
	elif soft != null:
		what = _label_of(soft)
	var line := "cam %s%s  target %s  dist %.1f arm %.1f h %+.1f  pitch %.0f  fov %.0f  trauma %.2f" % [
		MODE_NAMES[_mode], " LOCKED" if is_locked() else " free", what, _out_dist, _arm_len, _height,
		rad_to_deg(_view_pitch_v), camera.fov if camera else 0.0, _trauma]
	line += "\nenemies %d crowd %.2f  sprint %.2f  launch %.2f%s  fall %.2f  wall %.2f  roll %.1f" % [
		_enemies_alive, _crowd_k, _sprint_k, _launch_w, " (framed)" if _launch_body_framed else "",
		_fall_k, _wall_k, rad_to_deg(_roll)]
	if is_locked():
		line += "  aim (%.2f, %.2f)" % [_lock_aim.x, _lock_aim.y]
	line += "\nblocking: %s%s" % [", ".join(_blocker_names) if not _blocker_names.is_empty() else "nothing",
		"  (squeezed by concrete)" if _squeezed else ""]
	return line

# --- Input -------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_mouse_delta += (event as InputEventMouseMotion).screen_relative * mouse_scale()
		return
	if not input_enabled or get_tree().paused or _mode == Mode.KO:
		return
	if event.is_action_pressed(&"lock_on"):
		toggle_lock()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"lock_next"):
		cycle_lock(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"lock_prev"):
		cycle_lock(-1)
		get_viewport().set_input_as_handled()

## Mouse / right stick, already in radians at sensitivity 1. Free: turns the
## camera. Locked: moves the aim point over the target's body. Ignored during
## the last-kill close-up and the death orbit (cinematics own the view).
func apply_manual_input(d: Vector2) -> void:
	if d.length_squared() <= 0.0:
		return
	if _mode == Mode.CLOSEUP or _mode == Mode.KO:
		return
	_last_manual = TimeDirector.now()
	if invert_y:
		d.y = -d.y
	if is_locked():
		_lock_aim.x = clampf(_lock_aim.x + d.x * LOCK_AIM_SENS, -1.0, 1.0)
		_lock_aim.y = clampf(_lock_aim.y - d.y * LOCK_AIM_SENS, -1.0, 1.0)
		return
	_recentre_t0 = -100.0
	_restore_pending = false
	_yaw -= d.x
	_pitch = clampf(_pitch - d.y, _pitch_min(), _pitch_max())

func _read_manual_input(dt: float) -> void:
	var d := _mouse_delta * Tuning.CAM_MOUSE_SENS * sensitivity
	_mouse_delta = Vector2.ZERO
	var stick := Input.get_vector(&"cam_left", &"cam_right", &"cam_up", &"cam_down")
	d += stick * Tuning.CAM_STICK_SPEED * sensitivity * dt
	apply_manual_input(d)

# --- Update ------------------------------------------------------------------
func _process(_delta: float) -> void:
	var t := TimeDirector.now()
	var dt := TimeDirector.frame_delta()
	if not _alive_node(target):
		target = Targeting.player(get_tree())
	_update_projection()
	_auto_yaw_rate = 0.0
	_read_manual_input(dt)
	_update_lock_validity(dt)
	var desired := _desired_mode(t)
	# Cinematic modes and the player's own knockdown cut in at once; the rest
	# obeys the rate limit (CAM_MODE_GAP).
	_request_mode(desired, t, desired == Mode.CLOSEUP or desired == Mode.KO or desired == Mode.DOWN \
		or _mode == Mode.CLOSEUP)

	_update_traversal_framing(dt)
	var want_look := _look
	var want_dist := _dist
	var want_height := 0.0
	var look_rate := LOOK_RATE
	var dist_rate := DIST_RATE
	var shoulder := 0.0
	var lift := 0.0
	var subject: Vector3 = _out_look
	var play := false
	_launch_w = 0.0
	_launch_dist = 0.0
	match _mode:
		Mode.CLOSEUP:
			var r := _closeup_frame()
			want_look = r[0]
			want_dist = r[1]
			look_rate = 12.0
			dist_rate = CLOSEUP_DIST_RATE
			_yaw = lerp_angle(_yaw, _cine_yaw, 1.0 - exp(-10.0 * dt))
			_pitch = lerpf(_pitch, LAST_KILL_PITCH, 1.0 - exp(-10.0 * dt))
			subject = want_look
		Mode.KO:
			var orbit := DEATH_ORBIT_RATE if _death else KO_ORBIT_RATE
			if _squeezed:
				orbit = KO_ORBIT_SQUEEZED
			_yaw += orbit * dt
			_pitch = lerpf(_pitch, DEATH_PITCH if _death else KO_PITCH, 1.0 - exp(-2.0 * dt))
			if is_instance_valid(_ko_on):
				want_look = _point_of(_ko_on) + Vector3.UP * 0.2
			want_dist = _orbit_dist()
			look_rate = DEATH_LOOK_RATE if _death else KO_LOOK_RATE
			dist_rate = 6.0
			subject = want_look
		Mode.DOWN:
			if _alive_node(target):
				var pelvis := _pelvis(target) + Vector3.UP * 0.3
				var lagged := _look.lerp(pelvis, 1.0 - exp(-DOWN_LOOK_RATE * dt))
				# Heavy lag, but never so far behind that the body leaves the view.
				want_look = pelvis + (lagged - pelvis).limit_length(DOWN_MAX_LAG)
				look_rate = 1000.0  # want_look already carries the lag
				var speed := target.get_com_velocity().length()
				want_dist = clampf(Tuning.CAM_DUEL_DIST.x + minf(speed * DOWN_SPEED_PULLBACK, DOWN_PULLBACK_MAX),
					Tuning.CAM_DUEL_DIST.x, Tuning.CAM_LAUNCH_DIST)
				subject = pelvis
				# Body flying at a wall behind the camera: turn toward open space
				# (allowed: the player is not in control while down).
				if _squeezed and t - _last_manual > 0.4:
					var clear := _best_clear_yaw(pelvis, _yaw, Tuning.CAM_DUEL_DIST.x)
					_yaw += clampf(wrapf(clear - _yaw, -PI, PI), -DOWN_SWING_RATE * dt, DOWN_SWING_RATE * dt)
			_restore_after_cine(dt)
		_:
			if _alive_node(target):
				play = true
				_update_soft_target(t)
				var p := target.get_aim_point()
				if _lock_framing():
					var r := _lock_frame(dt)
					want_look = r[0]
					want_dist = r[1]
					lift = r[2]
				else:
					var r := _crowd_frame(dt)
					want_look = p
					want_dist = r[0]
					want_height = r[1]
					_update_recentre(t)
					_restore_after_cine(dt)
				# Sprint: further and lower by sprint_charge. Locked, no height
				# offset (the view must pass through the lock aim point).
				want_dist += Tuning.CAM_SPRINT_PULLBACK * _sprint_k
				if not _lock_framing():
					want_height -= Tuning.CAM_SPRINT_DROP * _sprint_k
					var lf := _launch_frame(t, dt, p, want_dist, want_height)
					if lf[0]:
						want_look = p + _launch_lean
						if lf[1] > want_dist:
							want_dist = lf[1]
							dist_rate = LAUNCH_DIST_RATE
						look_rate = LAUNCH_LOOK_RATE
				else:
					_launch_lean = Vector3.ZERO
				shoulder = 1.0
				subject = p

	if not play:
		_launch_lean = Vector3.ZERO
	if _snap:
		_look = want_look
		_dist = want_dist
		_height = want_height
		_out_height = want_height
		_out_look = want_look
		_out_dist = want_dist
		_arm_len = want_dist
		_soft_len = want_dist
		_blend_t0 = -100.0
	else:
		_look = _look.lerp(want_look, 1.0 - exp(-look_rate * dt))
		_dist = lerpf(_dist, want_dist, 1.0 - exp(-dist_rate * dt))
		# Cinematics use their own height at once (the mode blend eases into it).
		var hr := LOCK_HEIGHT_RATE if _lock_framing() else HEIGHT_RATE
		_height = lerpf(_height, want_height, 1.0 - exp(-hr * dt)) if _mode == Mode.COMBAT else want_height
	var w := smoothstep(0.0, 1.0, clampf((t - _blend_t0) / maxf(_blend_time, 0.001), 0.0, 1.0))
	_out_look = _blend_look.lerp(_look, w)
	_out_height = lerpf(_blend_height, _height, w)
	_out_dist = maxf(lerpf(_blend_dist, _dist, w),
		Tuning.CAM_LAST_KILL_DIST * 0.8 if _mode == Mode.CLOSEUP else Tuning.CAM_MIN_DIST)

	_place_camera(dt, shoulder, lift, subject)
	_snap = false
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

## At most one mode change per CAM_MODE_GAP s (unless forced), blended over
## CAM_MODE_BLEND (CINE_RETURN_BLEND out of a close-up: the ease back).
func _request_mode(mode: int, t: float, force: bool) -> bool:
	if mode == _mode:
		return false
	if not force and t - _mode_changed_at < Tuning.CAM_MODE_GAP:
		return false
	_blend_look = _out_look
	_blend_dist = _out_dist
	_blend_height = _out_height
	_blend_t0 = t
	_blend_time = CINE_RETURN_BLEND if _mode == Mode.CLOSEUP else Tuning.CAM_MODE_BLEND
	_mode = mode as Mode
	_mode_changed_at = t
	_mode_changes += 1
	return true

# --- Framing ---------------------------------------------------------------------------
## Crowd / duel framing (free camera). Returns [distance, height]. The look
## point stays on the player: only distance and height change, never the yaw.
func _crowd_frame(dt: float) -> Array:
	_framed.clear()
	var origin := target.get_ground_position()
	var enemies := Targeting.opponents_of(target)
	_enemies_alive = enemies.size()
	var goal := 1.0 if _enemies_alive >= CROWD_FROM else 0.0
	_crowd_k = goal if _snap else lerpf(_crowd_k, goal, 1.0 - exp(-CROWD_RATE * dt))
	if absf(_crowd_k - goal) < 0.002:
		_crowd_k = goal
	var near: Array[Fighter] = []
	for f in enemies:
		if _flat_dist(origin, f.get_ground_position()) < FRAME_RADIUS:
			near.append(f)
	near.sort_custom(func(a: Fighter, b: Fighter) -> bool:
		return _flat_dist(origin, a.get_ground_position()) < _flat_dist(origin, b.get_ground_position()))
	if near.size() > Tuning.CAM_CROWD_FRAME:
		near.resize(Tuning.CAM_CROWD_FRAME)
	_framed.assign(near)
	# Duel: 4 m close in, 5 m with the last enemies further off (5 m with none left).
	var sep := DUEL_SEP.y
	if not near.is_empty():
		sep = 0.0
		for i in mini(near.size(), 2):
			sep = maxf(sep, _flat_dist(origin, near[i].get_ground_position()))
	var duel := lerpf(Tuning.CAM_DUEL_DIST.x, Tuning.CAM_DUEL_DIST.y,
		clampf((sep - DUEL_SEP.x) / (DUEL_SEP.y - DUEL_SEP.x), 0.0, 1.0))
	# Crowd: 7 m with three up, 9 m with a full field (MAX_ENEMIES_ON_FIELD), so the
	# distance follows the crowd as it thins; pulled further (to 9 m) when the
	# nearest three would not fit.
	var full := clampf(float(_enemies_alive - CROWD_FROM) / maxf(float(Tuning.MAX_ENEMIES_ON_FIELD - CROWD_FROM), 1.0), 0.0, 1.0)
	var crowd := lerpf(Tuning.CAM_CROWD_DIST.x, Tuning.CAM_CROWD_DIST.y, full)
	if _crowd_k > 0.001:
		var pts: Array[Vector3] = []
		for f in near:
			pts.append(f.get_aim_point())
			pts.append(f.get_ground_position() + Vector3.UP * 0.1)
		crowd = _fit_distance(target.get_aim_point(), pts, crowd, Tuning.CAM_CROWD_DIST.y,
			Tuning.CAM_CROWD_HEIGHT, CROWD_SAFE)
	return [lerpf(duel, crowd, _crowd_k), lerpf(-DUEL_DROP, Tuning.CAM_CROWD_HEIGHT, _crowd_k)]

## Smallest distance in [d_min, d_max] (FIT_STEP steps) where every point sits
## inside `safe` of the half frame, with the player's look point, current yaw /
## pitch and `height`; d_max when none does.
func _fit_distance(look: Vector3, pts: Array[Vector3], d_min: float, d_max: float, height: float, safe: float) -> float:
	if pts.is_empty():
		return d_min
	var d := d_min
	while d < d_max - 0.001:
		var xf := _view_from(look, d, height, _pitch)
		var ok := true
		for q in pts:
			if not _inside(xf, q, safe):
				ok = false
				break
		if ok:
			return d
		d += FIT_STEP
	return d_max

## F1 launch framing. Returns [active, distance]. Sets _launch_lean (smoothed
## look offset), _launch_w and may turn _yaw (launch yaw rules).
func _launch_frame(t: float, dt: float, p: Vector3, base_dist: float, height: float) -> Array:
	var age := t - _launch_t0
	if not _alive_node(_launch_body) or age > Tuning.CAM_LAUNCH_FOLLOW \
			or _flat_dist(p, _point_of(_launch_body)) > FRAME_RADIUS * 1.5:
		_launch_body = null
		_launch_body_framed = false
		_launch_lean = _launch_lean.lerp(Vector3.ZERO, 1.0 - exp(-LAUNCH_LOOK_RATE * dt))
		if _launch_lean.length() > 0.02:
			return [true, 0.0]
		_launch_lean = Vector3.ZERO
		return [false, 0.0]
	var env := smoothstep(0.0, LAUNCH_LEAN_IN, age) * (1.0 - smoothstep(LAUNCH_LEAN_OUT.x, LAUNCH_LEAN_OUT.y, age))
	_launch_w = env
	var b := _point_of(_launch_body)
	# Where it is and where it will be a moment from now: the pull-back starts
	# before the body reaches the edge (the distance eases, it cannot jump).
	var ahead: Vector3 = b + (_launch_body as Fighter).get_com_velocity() * LAUNCH_LOOKAHEAD
	ahead.y = maxf(ahead.y, (_launch_body as Fighter).get_ground_position().y + 0.2)
	var body_pts: Array[Vector3] = [b, ahead]
	var player_pts := _player_points()
	# Lean toward the body: at most halfway, LAUNCH_LEAN_MAX long, little depth.
	var lean := (b - p) * LAUNCH_LEAN_SHARE
	var fwd := -Basis(Vector3.UP, _yaw).z
	var depth := lean.dot(fwd)
	if depth > LAUNCH_LEAN_DEPTH:
		lean -= fwd * (depth - LAUNCH_LEAN_DEPTH)
	lean.y = clampf(lean.y, -0.5, LAUNCH_LEAN_UP)
	lean = lean.limit_length(LAUNCH_LEAN_MAX)
	# Largest lean, then smallest distance, that frames both (player well inside).
	var d0 := minf(base_dist, Tuning.CAM_LAUNCH_DIST)
	var chosen_w := 0.0
	var chosen_d := Tuning.CAM_LAUNCH_DIST
	var found := false
	# The player is checked at the distance the camera has now (it pulls back
	# over a few frames), the body at the distance being asked for.
	for k: float in LEAN_STEPS:
		var look := p + lean * env * k
		var d := d0
		while d <= Tuning.CAM_LAUNCH_DIST + 0.001:
			var xf := _view_from(look, d, height, _pitch)
			if _all_inside(_view_from(look, minf(d, _out_dist), _out_height, _pitch), player_pts, LAUNCH_PLAYER_SAFE) \
					and _all_inside(xf, body_pts, LAUNCH_BODY_SAFE):
				chosen_w = env * k
				chosen_d = d
				found = true
				break
			d += LAUNCH_DIST_STEP
		if found:
			break
	if not found:
		# The body cannot fit: pull all the way back and lean as far as the
		# player allows (the yaw below may bring the body in).
		for k: float in LEAN_STEPS:
			if _all_inside(_view_from(p + lean * env * k, minf(chosen_d, _out_dist), _out_height, _pitch), player_pts, LAUNCH_PLAYER_SAFE):
				chosen_w = env * k
				break
	_launch_body_framed = found
	var want_lean := lean * chosen_w
	_launch_lean = want_lean if _snap else _launch_lean.lerp(want_lean, 1.0 - exp(-LAUNCH_LOOK_RATE * dt))
	# Yaw: only when the body would leave the frame, at most CAM_LAUNCH_YAW_RATE,
	# never while the player is turning the camera.
	if not found and t - _last_manual > LAUNCH_INPUT_YIELD:
		var xf := _view_from(p + _launch_lean, chosen_d, height, _pitch)
		var l := xf.basis.transposed() * (b - xf.origin)
		var ang := atan2(l.x, -l.z)
		var excess := absf(ang) - atan(LAUNCH_BODY_SAFE * _tan_h)
		if excess > 0.0 and absf(ang) < deg_to_rad(LAUNCH_YAW_REACH):
			var step := minf(excess, deg_to_rad(Tuning.CAM_LAUNCH_YAW_RATE) * dt)
			_yaw -= signf(ang) * step
			_auto_yaw_rate = step / maxf(dt, 0.0001)
	return [true, chosen_d]

## Sprint, fall tilt and wall run from the player's Traversal (smoothed).
func _update_traversal_framing(dt: float) -> void:
	var tr: Traversal = target.traversal if _alive_node(target) and not target.is_dead() else null
	var sc := 0.0
	var fall := 0.0
	var running := false
	var cap := Tuning.SPRINT_CAPS[0]
	if tr != null and is_instance_valid(tr):
		sc = clampf(tr.sprint_charge, 0.0, 1.0)
		if tr.is_airborne() and tr.get_fall_height() > 0.02:
			# Descending: the whole drop is what fell so far plus what is left.
			fall = tr.get_fall_height() + _height_above_floor()
		running = tr.is_wall_running()
		cap = tr.get_speed_cap()
		if running:
			var n := tr.get_wall_normal()
			n.y = 0.0
			if n.length() > 0.1:
				_wall_normal = n.normalized()
	if _mode != Mode.COMBAT:
		sc = 0.0
		fall = 0.0
		running = false
	# Sprint (the FOV must not snap when a sprint strike drops you to walk).
	var rate := SPRINT_RISE_RATE if sc > _sprint_k else SPRINT_FALL_RATE
	_sprint_k = sc if _snap else lerpf(_sprint_k, sc, 1.0 - exp(-rate * dt))
	var caps := Tuning.SPRINT_CAPS
	var up := clampf((cap - caps[0]) / maxf(caps[caps.size() - 1] - caps[0], 0.01), 0.0, 1.0)
	_fov_top = lerpf(Tuning.CAM_FOV_SPRINT, Tuning.CAM_FOV_SPRINT_MAX, up)
	_fov = Tuning.CAM_FOV + (_fov_top - Tuning.CAM_FOV) * _sprint_k
	# Fall tilt past CAM_FALL_FROM.
	var fk := clampf((fall - Tuning.CAM_FALL_FROM) / FALL_RAMP, 0.0, 1.0)
	_fall_k = lerpf(_fall_k, fk, 1.0 - exp(-(FALL_RISE_RATE if fk > _fall_k else FALL_RATE) * dt))
	if fk > 0.0 and _fall_k < 0.05 and _alive_node(target):
		# Roll with the sideways drift (a fixed side when falling straight).
		var v := target.velocity
		var side := v.dot(Basis(Vector3.UP, _yaw).x)
		_fall_sign = -signf(side) if absf(side) > 0.5 else 1.0
	# Wall run.
	_wall_k = lerpf(_wall_k, 1.0 if running else 0.0, 1.0 - exp(-WALLRUN_RATE * dt))
	if running:
		_wall_until = TimeDirector.now() + WALLRUN_EXCLUDE_GRACE
	elif TimeDirector.now() > _wall_until and not _wall_rids.is_empty():
		_wall_rids.clear()
	_shift = _wall_normal * Tuning.CAM_WALLRUN_SHIFT * _wall_k
	# Roll away from the wall: a wall on the camera's right rolls the top left.
	var wall_side := clampf(-_wall_normal.dot(Basis(Vector3.UP, _yaw).x), -1.0, 1.0)
	_roll = deg_to_rad(Tuning.CAM_FALL_ROLL) * _fall_k * _fall_sign \
		+ deg_to_rad(Tuning.CAM_WALLRUN_ROLL) * _wall_k * wall_side
	_pitch_off = -deg_to_rad(FALL_PITCH) * _fall_k

## Metres from the player's feet down to the floor or platform below (WORLD or
## a wall top), 0 when nothing is found.
func _height_above_floor() -> float:
	if not _alive_node(target) or not is_inside_tree():
		return 0.0
	var from := target.global_position + Vector3.UP * 0.1
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 40.0, Layers.WORLD | Layers.DESTRUCTIBLE)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return 0.0
	return maxf(target.global_position.y - (hit["position"] as Vector3).y, 0.0)

## Locked: yaw toward the aim point (capped at LOCK_TURN_SPEED, the launch rate
## while the target is down), the pivot lifted so the shoulder -> aim line has
## the lock pitch; returns [look, dist, lift].
func _lock_frame(dt: float) -> Array:
	var lf: Fighter = _lock
	_enemies_alive = Targeting.opponents_of(target).size()
	var goal := _body_point(lf, _lock_aim)
	_lock_aim_point = _lock_aim_point.lerp(goal, 1.0 - exp(-LOCK_AIM_RATE * dt))
	var p := target.get_aim_point()
	# Yaw from the shoulder pivot (last frame's), so the aim point lands on the centre.
	var from := _pivot if _pivot != Vector3.ZERO else p
	var to := _lock_aim_point - from
	var flat := Vector2(to.x, to.z).length()
	if flat > 0.2:
		var want_yaw := atan2(-to.x, -to.z)
		var rate := Tuning.CAM_LAUNCH_YAW_RATE if lf.is_down() else Tuning.LOCK_TURN_SPEED
		var cap := deg_to_rad(rate) * dt
		_yaw += clampf(wrapf(want_yaw - _yaw, -PI, PI), -cap, cap)
	var sep := maxf(flat, 0.5)
	var lift := maxf(sep * tan(deg_to_rad(-Tuning.LOCK_PITCH)) - (_lock_aim_point.y - p.y), 0.0)
	var dist := clampf(LOCK_DIST_BASE + sep * LOCK_DIST_PER_M, Tuning.CAM_MIN_DIST, Tuning.CAM_CROWD_DIST.x)
	return [p, dist, lift]

func _update_recentre(t: float) -> void:
	var k := (t - _recentre_t0) / RECENTRE_TIME
	if k < 0.0 or k > 1.0:
		return
	_yaw = lerp_angle(_recentre_from, _recentre_to, smoothstep(0.0, 1.0, k))
	_pitch = lerpf(_pitch, PITCH_DEFAULT, smoothstep(0.0, 1.0, k))

## After a close-up the player gets back the yaw / pitch they had (unless they
## moved the camera meanwhile).
func _restore_after_cine(dt: float) -> void:
	if not _restore_pending:
		return
	var step := wrapf(_restore_yaw - _yaw, -PI, PI) * (1.0 - exp(-RESTORE_RATE * dt))
	_yaw += clampf(step, -RESTORE_MAX_SPEED * dt, RESTORE_MAX_SPEED * dt)
	_pitch = lerpf(_pitch, _restore_pitch, 1.0 - exp(-RESTORE_RATE * dt))
	if absf(wrapf(_yaw - _restore_yaw, -PI, PI)) < 0.01:
		_restore_pending = false

## Last-kill close-up: CAM_LAST_KILL_DIST from a point between the victim and
## the player, pulled back (up to LAST_KILL_FIT_MAX) only to keep the player in.
func _closeup_frame() -> Array:
	if not _alive_node(_closeup_on):
		return [_look, _dist]
	var v := _point_of(_closeup_on) + Vector3.UP * 0.2
	if not _alive_node(target):
		return [v, Tuning.CAM_LAST_KILL_DIST]
	var p := target.get_aim_point()
	var look := v.lerp(p, CLOSEUP_PLAYER_SHARE)
	var sep := _flat_dist(p, v)
	var dist := clampf(Tuning.CAM_LAST_KILL_DIST + maxf(sep - 1.5, 0.0) * 0.6,
		Tuning.CAM_LAST_KILL_DIST, LAST_KILL_FIT_MAX)
	return [look, dist]

## Yaw that views the player -> victim line from the side with more room.
func _side_yaw(victim: Node3D) -> float:
	if not _alive_node(target):
		return _yaw
	var line := _point_of(victim) - target.get_aim_point()
	line.y = 0.0
	if line.length() < 0.2:
		return _yaw
	var along := atan2(-line.x, -line.z)
	var mid := target.get_aim_point().lerp(_point_of(victim), 0.6)
	var a := along + PI * 0.5
	var b := along - PI * 0.5
	var ca := _clearance(mid, a, Tuning.CAM_DUEL_DIST.x)
	var cb := _clearance(mid, b, Tuning.CAM_DUEL_DIST.x)
	if absf(ca - cb) < 0.3:
		# Equal room: the side nearer the current view, so the cut is short.
		return a if absf(wrapf(a - _yaw, -PI, PI)) < absf(wrapf(b - _yaw, -PI, PI)) else b
	return a if ca > cb else b

func _orbit_dist() -> float:
	return Tuning.CAM_DEATH_ORBIT if _death else KO_DIST

# --- Projection math (framing solvers; ignores walls) -----------------------------
func _update_projection() -> void:
	var aspect := 16.0 / 9.0
	if is_inside_tree():
		var vs := get_viewport().get_visible_rect().size
		aspect = vs.x / maxf(vs.y, 1.0)
	_tan_v = tan(deg_to_rad(camera.fov if camera else Tuning.CAM_FOV) * 0.5)
	_tan_h = _tan_v * aspect

## Pitch and distance after raising the camera `height` m above the plain
## orbit (pitch, dist): it then looks down at the same pivot.
static func _raised(pitch: float, dist: float, height: float) -> Vector2:
	var up := -sin(pitch) * dist + height
	var horiz := cos(pitch) * dist
	return Vector2(-atan2(up, maxf(horiz, 0.05)), Vector2(horiz, up).length())

## Camera transform for a look point, distance, height and pitch at the
## current yaw, with the shoulder shift (no walls). For the framing solvers.
func _view_from(look: Vector3, dist: float, height: float, pitch: float) -> Transform3D:
	var pd := _raised(pitch + _pitch_off, dist, height)
	var p := clampf(pd.x, deg_to_rad(PITCH_FLOOR), _pitch_max())
	var b := Basis.from_euler(Vector3(p, _yaw, 0.0))
	var pivot := look + Basis(Vector3.UP, _yaw).x * _shoulder_for(pd.y) * (1.0 - _wall_k) + _shift
	return Transform3D(b, pivot + b.z * pd.y)

## Shoulder shift that puts the player CAM_PLAYER_OFFSET_X of the width left of centre.
func _shoulder_for(dist: float) -> float:
	var half_w := maxf(dist, 0.3) * _tan_h
	return minf(-Tuning.CAM_PLAYER_OFFSET_X * 2.0 * half_w, SHOULDER_MAX)

## Is `q` in front of the camera and inside `safe` of the half frame?
func _inside(xf: Transform3D, q: Vector3, safe: float) -> bool:
	var l := xf.basis.transposed() * (q - xf.origin)
	var depth := -l.z
	if depth < 0.1:
		return false
	return absf(l.x) <= safe * depth * _tan_h and absf(l.y) <= safe * depth * _tan_v

func _all_inside(xf: Transform3D, pts: Array[Vector3], safe: float) -> bool:
	for q in pts:
		if not _inside(xf, q, safe):
			return false
	return true

## Head, chest and feet of the player (what must stay in frame).
func _player_points() -> Array[Vector3]:
	var out: Array[Vector3] = []
	if not _alive_node(target):
		return out
	var aim := target.get_aim_point()
	out.append(aim)
	out.append(aim + Vector3.UP * 0.5)
	out.append(target.get_ground_position() + Vector3.UP * 0.1)
	return out

# --- Placement ---------------------------------------------------------------------
func _place_camera(dt: float, shoulder: float, lift: float, subject: Vector3) -> void:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	_floor_y = target.get_ground_position().y if _alive_node(target) else 0.0
	_exclude.clear()
	_exclude.append_array(_wall_rids)
	_cast_q.exclude = _exclude
	var player_side := _view_basis_flat()
	# Shoulder shift (player left of centre), cast against concrete first.
	var want_shoulder := 0.0
	if shoulder > 0.0:
		# Sized from the real arm (last frame): a squeezed camera must not push the
		# player off the side of a close view.
		want_shoulder = _shoulder_for(minf(_arm_len, _out_dist))
		# A wall run moves the camera to the open side instead (the shoulder
		# shift would point into a wall on the right).
		want_shoulder *= 1.0 - _wall_k
	var view_basis := Basis()
	var back := Vector3.BACK
	var arm_want := _out_dist
	var saved := [_shoulder, _soft_len, _arm_len, _pitch]
	for attempt in 2:
		if attempt == 1:  # second solve after a sudden squeeze: start from the same state
			_shoulder = saved[0]
			_soft_len = saved[1]
			_arm_len = saved[2]
			_pitch = saved[3]
		var base := _out_look + Vector3.UP * lift
		# Chain of sweeps from the subject (player / pelvis) so no link starts in concrete.
		if space != null:
			var reach := base - subject
			if reach.length() > 0.01:
				base = subject + reach.normalized() * _cast_free(space, subject, reach, ARM_RADIUS)
			if _shift.length_squared() > 0.0001:
				base += _shift.normalized() * _cast_free(space, base, _shift, ARM_RADIUS)
		else:
			base += _shift
		if space != null and want_shoulder > 0.01:
			want_shoulder = minf(want_shoulder, _cast_free(space, base, player_side.x * want_shoulder, ARM_RADIUS))
		# Narrower at once (a wall or a shorter arm must never push the player off
		# the side), wider gently; a cinematic eases the shift out instead of popping.
		var cine := _mode == Mode.KO or _mode == Mode.CLOSEUP
		if _snap or (want_shoulder < _shoulder and not cine):
			_shoulder = want_shoulder
		else:
			_shoulder = lerpf(_shoulder, want_shoulder, 1.0 - exp(-(8.0 if cine else 4.0) * dt))
		_pivot = base + player_side.x * _shoulder
		global_position = _pivot

		# Pitch: the player's (or the lock geometry), plus the framing offsets and
		# height; tilted toward the limit when squeezed; kept above the floor.
		var p := _pitch
		if _lock_framing() and _mode == Mode.COMBAT:
			var to := _lock_aim_point - _pivot
			var want_p := atan2(to.y, Vector2(to.x, to.z).length())
			_pitch = lerpf(_pitch, clampf(want_p, _pitch_min(), _pitch_max()), 1.0 - exp(-LOCK_PITCH_RATE * dt))
			p = _pitch
		var pd := _raised(p + _pitch_off, _out_dist, _out_height)
		p = clampf(pd.x, deg_to_rad(PITCH_FLOOR), _pitch_max())
		arm_want = pd.y
		p = lerpf(p, minf(p, _pitch_min()), _tilt)
		var floor_y := target.get_ground_position().y if _alive_node(target) else 0.0
		var room := _pivot.y - floor_y - MIN_CAM_HEIGHT
		p = minf(p, asin(clampf(room / maxf(arm_want, 0.3), -1.0, 1.0)))
		p = clampf(p, deg_to_rad(PITCH_FLOOR), _pitch_max())
		_view_pitch_v = p
		view_basis = Basis.from_euler(Vector3(p, _yaw, 0.0))
		back = view_basis.z

		# Arm: wide cast eases in early, narrow cast clamps at once, sight line to the player.
		var hard := arm_want
		var soft := arm_want
		if space != null:
			hard = _cast_free(space, _pivot, back * arm_want, ARM_RADIUS)
			soft = _cast_free(space, _pivot, back * arm_want, ARM_SOFT_RADIUS)
		_soft_len = soft if _snap else lerpf(_soft_len, soft, 1.0 - exp(-(ARM_SOFT_IN_RATE if soft < _soft_len else ARM_OUT_RATE) * dt))
		if space != null and arm_want > 0.4:
			# Anticipate concrete crossing the sight line: ease in before the hard check bites.
			var cam_far := _pivot + back * arm_want
			var sight := _cast_free(space, subject, cam_far - subject, SIGHT_SOFT_RADIUS)
			var frac := sight / maxf(subject.distance_to(cam_far), 0.01)
			if frac < 0.999:
				soft = minf(soft, arm_want * frac)
				_soft_len = minf(_soft_len, lerpf(_soft_len, soft, 1.0 - exp(-ARM_SOFT_IN_RATE * dt)))
		var want_arm := minf(_soft_len, hard)
		_arm_len = want_arm if (want_arm < _arm_len or _snap) else lerpf(_arm_len, want_arm, 1.0 - exp(-ARM_OUT_RATE * dt))
		_arm_len = minf(_arm_len, hard)
		if space != null and _arm_len > 0.4:
			_arm_len = _clear_sight(space, subject, _pivot, back, _arm_len)
		_arm_len = maxf(_arm_len, minf(0.3, hard))
		arm.global_transform = Transform3D(view_basis, _pivot)
		arm.spring_length = arm_want

		# Squeezed below CAM_MIN_DIST: tilt toward the pitch limit (camera rises) next frames.
		_squeezed = _arm_len < Tuning.CAM_MIN_DIST - 0.05 and _mode != Mode.CLOSEUP
		var squeeze := clampf((Tuning.CAM_MIN_DIST - _arm_len) / Tuning.CAM_MIN_DIST, 0.0, 1.0) if _squeezed else 0.0
		if attempt == 0 and squeeze - _tilt > 0.25:
			# A sudden squeeze (a pillar edge cuts in): rise this frame, not over the next few.
			_tilt = squeeze
			continue
		var tilt_rate := SQUEEZE_TILT_IN_RATE if squeeze > _tilt else SQUEEZE_TILT_RATE
		_tilt = lerpf(_tilt, squeeze, 1.0 - exp(-tilt_rate * dt))
		break

	var pos := _pivot + back * _arm_len
	# Shake (trauma^2) and kick after the clamp, and only where they stay clear of concrete.
	_trauma = maxf(_trauma - Tuning.TRAUMA_DECAY * dt, 0.0)
	_kick *= exp(-KICK_DECAY * dt)
	var shake := _trauma * _trauma
	var offset := _kick
	var roll := _roll
	var shake_rot := Vector2.ZERO
	if shake > 0.00001:
		_noise_t += dt * SHAKE_FREQ
		var nx := clampf(_noise.get_noise_2d(_noise_t, 0.0) * 1.4, -1.0, 1.0)
		var ny := clampf(_noise.get_noise_2d(_noise_t, 100.0) * 1.4, -1.0, 1.0)
		var nr := clampf(_noise.get_noise_2d(_noise_t, 200.0) * 1.4, -1.0, 1.0)
		var na := clampf(_noise.get_noise_2d(_noise_t, 300.0) * 1.4, -1.0, 1.0)
		var nb := clampf(_noise.get_noise_2d(_noise_t, 400.0) * 1.4, -1.0, 1.0)
		roll += nr * deg_to_rad(SHAKE_ROLL) * shake
		offset += (view_basis.x * nx + view_basis.y * ny) * SHAKE_OFFSET * shake
		shake_rot = Vector2(na, nb) * deg_to_rad(SHAKE_ANGLE) * shake
	if offset.length_squared() > 0.000001 and space != null:
		offset = offset.normalized() * minf(offset.length(), _cast_free(space, pos, offset, ARM_RADIUS * 0.6))
	pos += offset
	if shake_rot != Vector2.ZERO:
		view_basis = Basis(view_basis.y, shake_rot.x) * view_basis
		view_basis = Basis(view_basis.x, shake_rot.y) * view_basis
	# A squeezed (short) camera can leave the subject outside the view: turn the
	# view (not the player's yaw / pitch) just enough to keep it inside.
	# Only while the player is down: in play the player-in-frame pass does it.
	if _arm_len < Tuning.CAM_MIN_DIST and _mode == Mode.DOWN:
		view_basis = _keep_in_view(view_basis, pos, subject)
	if absf(roll) > 0.00001:
		view_basis = view_basis * Basis(Vector3.BACK, roll)
	_fov_age += dt
	var k := 0.0
	if _fov_age < FOV_PUNCH_RISE:
		k = _fov_age / FOV_PUNCH_RISE
	elif _fov_age < FOV_PUNCH_END:
		k = 1.0 - smoothstep(FOV_PUNCH_HOLD, FOV_PUNCH_END, _fov_age)
	_fov_punch = _fov_amp * k
	camera.fov = _fov + _fov_punch
	_view_corrected = 0.0
	if _mode == Mode.COMBAT or (_mode == Mode.CLOSEUP and _alive_node(_closeup_on) and _alive_node(target) \
			and _flat_dist(target.get_aim_point(), _point_of(_closeup_on)) < LAST_KILL_FIT_MAX):
		view_basis = _keep_player_in_frame(view_basis, pos)
	camera.global_transform = Transform3D(view_basis.orthonormalized(), pos)
	camera.h_offset = 0.0
	_fade_player_if_close(pos)
	if _last_cam_pos != Vector3.ZERO and pos.distance_to(_last_cam_pos) > 0.5 and _mode == Mode.COMBAT and not _snap:
		_cam_snapped += 1
	_last_cam_pos = pos

## The player always stays in frame: turn the view (never the player's yaw)
## just enough that the head, chest and feet sit inside PLAYER_KEEP of the half
## frame. With the camera too close for the whole body, the chest alone.
func _keep_player_in_frame(b: Basis, pos: Vector3) -> Basis:
	var pts := _player_points()
	if pts.is_empty():
		return b
	_update_projection()
	var tan_v := _tan_v
	var tan_h := _tan_h
	var depth0 := (pts[0] - pos).length()
	if depth0 * tan_v * PLAYER_KEEP * 2.0 < 2.0:
		pts = [pts[0]]
	var lim_x := atan(PLAYER_KEEP * tan_h)
	var lim_y := atan(PLAYER_KEEP * tan_v)
	for iter in 3:
		var ex := 0.0
		var ey := 0.0
		for q in pts:
			var l := b.transposed() * (q - pos)
			var depth := -l.z
			var ax := atan2(l.x, depth)
			var ay := atan2(l.y, maxf(depth, 0.05))
			if absf(ax) > lim_x and absf(ax) - lim_x > absf(ex):
				ex = (absf(ax) - lim_x) * signf(ax)
			if absf(ay) > lim_y and absf(ay) - lim_y > absf(ey):
				ey = (absf(ay) - lim_y) * signf(ay)
		if ex == 0.0 and ey == 0.0:
			break
		if ex != 0.0:
			b = Basis(b.y.normalized(), -ex) * b
		if ey != 0.0:
			b = Basis(b.x.normalized(), ey) * b
		b = b.orthonormalized()
		_view_corrected += absf(ex) + absf(ey)
	return b

## Walls can force the camera close to the player (back to a pillar): fade the
## player rather than fill the screen with the back of their head.
func _fade_player_if_close(pos: Vector3) -> void:
	if not _alive_node(target):
		return
	var d := pos.distance_to(target.get_aim_point())
	var k := clampf((PLAYER_FADE_NEAR - d) / (PLAYER_FADE_NEAR - PLAYER_FADE_FULL), 0.0, 1.0)
	var amount := k * (1.0 - Tuning.CAM_BLOCKER_ALPHA)
	if not is_equal_approx(amount, _player_fade):
		_player_fade = amount
		BloodFX.set_fighter_fade(target, amount)

func get_player_fade() -> float:
	return _player_fade

## Rotate `b` (camera at `pos`) so `subject` sits within KEEP_IN_VIEW of the
## vertical half field of view; never steeper than KEEP_PITCH_MIN.
func _keep_in_view(b: Basis, pos: Vector3, subject: Vector3) -> Basis:
	var to := subject - pos
	if to.length() < 0.05:
		return b
	to = to.normalized()
	var fwd := -b.z
	var ang := fwd.angle_to(to)
	var limit := deg_to_rad(camera.fov * 0.5) * KEEP_IN_VIEW
	if ang <= limit:
		return b
	var axis := fwd.cross(to)
	if axis.length() < 0.0001:
		return b
	var out := Basis(axis.normalized(), ang - limit) * b
	var out_fwd := -out.z
	var pitch := asin(clampf(out_fwd.y, -1.0, 1.0))
	if pitch < deg_to_rad(KEEP_PITCH_MIN):
		var flat := Vector3(out_fwd.x, 0.0, out_fwd.z).normalized()
		var p := deg_to_rad(KEEP_PITCH_MIN)
		var f2 := flat * cos(p) + Vector3.UP * sin(p)
		out = Basis.looking_at(f2, Vector3.UP)
	return out.orthonormalized()

## How far a sphere of `radius` can move from `from` by `motion` before
## touching concrete (Layers.WORLD, minus the wall being run on), minus
## ARM_MARGIN. Low geometry (is_low_shape) is passed through. Returns metres.
func _cast_free(space: PhysicsDirectSpaceState3D, from: Vector3, motion: Vector3, radius: float) -> float:
	var length := motion.length()
	if length < 0.0001:
		return 0.0
	var dir := motion / length
	_cast_sphere.radius = radius
	var start := 0.0
	for i in LOW_SKIP_MAX + 1:
		_cast_q.transform = Transform3D(Basis(), from + dir * start)
		_cast_q.motion = dir * (length - start)
		var r := space.cast_motion(_cast_q)
		if r.is_empty() or r[0] >= 1.0:
			return length  # nothing in the way
		var safe := start + r[0] * (length - start)
		var past := _low_exit(space, from, dir, start + r[1] * (length - start), radius)
		if past < 0.0:
			return maxf(safe - ARM_MARGIN, 0.0)
		if past >= length:
			return length
		start = past
	return maxf(start - ARM_MARGIN, 0.0)

## Shorten the arm until no concrete is between the camera and `subject`.
func _clear_sight(space: PhysicsDirectSpaceState3D, subject: Vector3, pivot: Vector3, back: Vector3, arm_len: float) -> float:
	var l := arm_len
	for i in 4:
		if _world_ray(space, subject, pivot + back * l).is_empty():
			return l
		l *= 0.6
	return l

## Is shape `shape_idx` of `col` low WORLD geometry standing on the player's
## floor (top at most LOW_OBSTACLE_MAX above it)? Not the floor itself, not what
## the player stands on, not walls or pillars.
func is_low_shape(col, shape_idx: int, floor_y: float) -> bool:
	var box := _shape_box(col, shape_idx)
	if box.size == Vector3.ZERO or maxf(box.size.x, box.size.z) > 30.0:
		return false
	return box.end.y > floor_y + 0.2 and box.end.y <= floor_y + LOW_OBSTACLE_MAX

func _shape_owner(col, shape_idx: int) -> CollisionShape3D:
	if not is_instance_valid(col) or not (col is CollisionObject3D) or shape_idx < 0:
		return null
	var co := col as CollisionObject3D
	var total := 0
	for o in co.get_shape_owners():
		total += co.shape_owner_get_shape_count(o)
	if shape_idx >= total:
		return null  # the body changed since the hit (a pillar lost its parts)
	var owner_id := co.shape_find_owner(shape_idx)
	return co.shape_owner_get_owner(owner_id) as CollisionShape3D

## World AABB of one shape (cached per CollisionShape3D: the world is static).
func _shape_box(col, shape_idx: int) -> AABB:
	var cs := _shape_owner(col, shape_idx)
	if cs == null or cs.shape == null:
		return AABB()
	var id := cs.get_instance_id()
	if not _shape_boxes.has(id):
		var mesh := cs.shape.get_debug_mesh()
		_shape_boxes[id] = cs.global_transform * mesh.get_aabb() if mesh != null else AABB()
	return _shape_boxes[id]

## The mesh drawn for a shape: a GeometryInstance3D beside it with the same
## centre (one static body can hold many boxes), or the body itself when it has
## a single shape. null: nothing to fade.
func _shape_mesh(col, shape_idx: int) -> Node3D:
	var cs := _shape_owner(col, shape_idx)
	if cs == null:
		return null
	var id := cs.get_instance_id()
	if _shape_meshes.has(id):
		var cached = _shape_meshes[id]
		return cached if is_instance_valid(cached) else null
	var found: Node3D = null
	var parent := cs.get_parent()
	if parent != null:
		for c in parent.get_children():
			if c is GeometryInstance3D and (c as Node3D).global_position.distance_to(cs.global_position) < 0.02:
				found = c
				break
	if found == null and col is CollisionObject3D and (col as CollisionObject3D).get_shape_owners().size() == 1:
		found = col
	_shape_meshes[id] = found
	return found

## Ray parameter where (from, dir) leaves `box`, or -1 when it misses it.
static func _ray_exit(box: AABB, from: Vector3, dir: Vector3) -> float:
	var t_near := -INF
	var t_far := INF
	for i in 3:
		var o: float = from[i]
		var d: float = dir[i]
		var lo: float = box.position[i]
		var hi: float = box.end[i]
		if absf(d) < 1e-6:
			if o < lo or o > hi:
				return -1.0
			continue
		var t1 := (lo - o) / d
		var t2 := (hi - o) / d
		t_near = maxf(t_near, minf(t1, t2))
		t_far = minf(t_far, maxf(t1, t2))
	if t_near > t_far or t_far < 0.0:
		return -1.0
	return t_far

## The sphere touched something at `at` along the cast: if it is a low shape,
## the distance along the cast where the sphere is clear of it; else -1.
func _low_exit(space: PhysicsDirectSpaceState3D, from: Vector3, dir: Vector3, at: float, radius: float) -> float:
	_cast_q.transform = Transform3D(Basis(), from + dir * at)
	_cast_q.motion = Vector3.ZERO
	var info := space.get_rest_info(_cast_q)
	if info.is_empty():
		return -1.0
	var col := instance_from_id(int(info["collider_id"]))
	var shape := int(info["shape"])
	if not is_low_shape(col, shape, _floor_y):
		return -1.0
	var t := _ray_exit(_shape_box(col, shape).grow(radius + ARM_MARGIN + 0.02), from, dir)
	return maxf(t, at + 0.05) if t >= 0.0 else -1.0

## First WORLD hit on the segment that is not low geometry ({} when clear).
func _world_ray(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> Dictionary:
	var from := a
	var dir := (b - a).normalized()
	for i in LOW_SKIP_MAX + 1:
		var q := PhysicsRayQueryParameters3D.create(from, b, Layers.WORLD, _exclude)
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return {}
		if not is_low_shape(hit["collider"], int(hit["shape"]), _floor_y):
			return hit
		var t := _ray_exit(_shape_box(hit["collider"], int(hit["shape"])), from, dir)
		from = from + dir * (maxf(t, 0.0) + 0.01) if t >= 0.0 else (hit["position"] as Vector3) + dir * 0.01
		if (b - from).dot(dir) <= 0.0:
			return {}
	return {}

func _view_basis_flat() -> Basis:
	return Basis(Vector3.UP, _yaw)

func _pitch_min() -> float:
	return deg_to_rad(Tuning.CAM_PITCH_RANGE.x)

func _pitch_max() -> float:
	return deg_to_rad(Tuning.CAM_PITCH_RANGE.y)

## Free distance behind `from` at yaw `y` (concrete only), at most `need`.
func _clearance(from: Vector3, y: float, need: float) -> float:
	if not is_inside_tree():
		return need
	var back := Basis(Vector3.UP, y).z
	var start := from + Vector3.UP * 0.3
	var hit := _world_ray(get_world_3d().direct_space_state, start, start + back * need + Vector3.UP * 0.8)
	return need if hit.is_empty() else start.distance_to(hit["position"])

## Yaw near `around` with the most room behind `from`, preferring small turns.
func _best_clear_yaw(from: Vector3, around: float, need: float = Tuning.CAM_DUEL_DIST.x) -> float:
	var best := around
	var best_score := -INF
	for off: float in CLEAR_PROBES:
		var y := around + off
		var score := _clearance(from, y, need) - absf(off) * 0.3
		if score > best_score:
			best_score = score
			best = y
	return best

# --- Blockers fade -------------------------------------------------------------------
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
		var amount := move_toward(float(e["amount"]), goal, (FADE_IN_RATE if goal > float(e["amount"]) else FADE_RATE) * dt)
		if not is_equal_approx(amount, float(e["amount"])) or (amount == 0.0 and goal == 0.0):
			_apply_fade(node, e["kind"], amount)
		e["amount"] = amount
		if e["hit"]:
			_blocker_names.append(_label_of(node))
		if amount <= 0.0 and not e["hit"]:
			drop.append(id)
	for id in drop:
		_fades.erase(id)

## Everything on the line from the camera to `to` that is not kept fades:
## breakables (clutter, panels, partitions, door frames, the pillars' beams and
## signs), debris and fallen pieces, bodies, and low WORLD geometry (its own
## mesh). Tall concrete is the arm's job and is passed over.
func _cast_blockers(from: Vector3, to: Vector3, keep: Array) -> void:
	var space := get_world_3d().direct_space_state
	var exclude: Array[RID] = []
	var dir := (to - from).normalized()
	var start := from
	for i in FADE_MAX_HITS:
		var q := PhysicsRayQueryParameters3D.create(start, to, FADE_MASK | Layers.WORLD, exclude)
		q.hit_from_inside = true
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return
		var col = hit["collider"]
		if not is_instance_valid(col):
			exclude.append(hit["rid"])
			continue
		if col is CollisionObject3D and ((col as CollisionObject3D).collision_layer & Layers.WORLD) != 0:
			# Concrete: low shapes fade (their own mesh), then the ray goes on past
			# that shape; tall concrete is left to the arm (and skipped).
			var shape := int(hit["shape"])
			if is_low_shape(col, shape, _floor_y):
				var mesh := _shape_mesh(col, shape)
				if mesh != null:
					_mark_fade(mesh, &"world")
				var t := _ray_exit(_shape_box(col, shape), start, dir)
				if t >= 0.0:
					start = start + dir * (t + 0.01)
					if (to - start).dot(dir) <= 0.0:
						return
					continue
			exclude.append(hit["rid"])
			continue
		exclude.append(hit["rid"])
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
## Stable: prefer the current target, hold it SOFT_HOLD s, pick by the stick
## (or the player's facing) and distance, switch only for a clearly better one.
func _update_soft_target(t: float) -> void:
	if is_locked():
		return
	var dir := Vector3.ZERO
	if target.brain != null and target.brain.has_method(&"get_stick_world"):
		dir = target.brain.get_stick_world()
	if Vector2(dir.x, dir.z).length() < 0.2:
		dir = target.get_forward()
	dir.y = 0.0
	dir = dir.normalized() if dir.length() > 0.01 else Vector3.FORWARD
	var current_ok := _targetable(_soft) and _flat_dist(target.get_ground_position(), _soft.get_ground_position()) < FRAME_RADIUS
	if current_ok and t - _soft_changed_at < SOFT_HOLD:
		return
	var best: Fighter = null
	var best_score := INF
	for f in Targeting.opponents_of(target):
		if f.is_down():
			continue
		var s := _soft_score(f, dir)
		if s < best_score:
			best_score = s
			best = f
	if not current_ok:
		_set_soft(best, t)
	elif best != null and best != _soft and best_score < _soft_score(_soft, dir) - SOFT_SWITCH_MARGIN:
		_set_soft(best, t)

func _soft_score(f: Fighter, dir: Vector3) -> float:
	var to := f.get_ground_position() - target.get_ground_position()
	to.y = 0.0
	var d := to.length()
	if d > FRAME_RADIUS:
		return INF
	var ang := 0.0 if d < 0.01 else (1.0 - dir.dot(to / d))
	return ang * 4.0 + d * 0.25

func _set_soft(f: Fighter, t: float) -> void:
	if f != _soft:
		_soft = f
		_soft_changed_at = t

# --- Events --------------------------------------------------------------------
func _on_screen_shake(trauma: float) -> void:
	add_trauma(trauma)

## Trauma from an event at `pos`: full near the player, fading with distance.
func _add_event_trauma(amount: float, pos: Vector3) -> void:
	add_trauma(amount * _event_k(pos))

## 1 within TRAUMA_FAR.x of the player, down to TRAUMA_FAR_MIN at TRAUMA_FAR.y.
func _event_k(pos: Vector3) -> float:
	if not _alive_node(target) or pos == Vector3.ZERO:
		return 1.0
	var d := target.get_aim_point().distance_to(pos)
	return lerpf(1.0, TRAUMA_FAR_MIN, clampf((d - TRAUMA_FAR.x) / (TRAUMA_FAR.y - TRAUMA_FAR.x), 0.0, 1.0))

func _on_hit_landed(info: HitInfo) -> void:
	if info == null:
		return
	var pos := info.hit_position
	if pos == Vector3.ZERO and is_instance_valid(info.victim):
		pos = info.victim.global_position
	_add_event_trauma(Power.trauma_for(info.tier), pos)
	if not _alive_node(target):
		return
	if info.attacker == target or info.victim == target:
		var k := 0.03 + info.damage / KICK_DAMAGE_DIV + info.energy / KICK_ENERGY_DIV
		add_kick(info.hit_direction, minf(k, KICK_MAX))
	if HitInfo.is_launch_tier(info.tier) and info.victim != target and info.victim is Fighter:
		_track_launch(info.victim as Fighter)
		if info.tier >= HitInfo.Tier.HARD_LAUNCH and (info.attacker == target or info.victim == target):
			punch_fov()

func _on_teleport_counter(defender: Node3D, victim: Node3D) -> void:
	if defender == target or victim == target:
		punch_fov()

func _on_teleported(fighter: Node3D, _from: Vector3, _to: Vector3, kind: StringName) -> void:
	if kind == &"counter" and fighter == target:
		punch_fov()

func _on_wall_broken(wall: Node3D, position: Vector3, _energy: float, _velocity: Vector3) -> void:
	if not TimeDirector.is_real_wall(wall):
		_furniture_shake(position)  # a desk, crate, jamb or lintel: small shake, no punch
		return
	var headline := is_headline_break(wall)
	punch_fov(FOV_PUNCH if headline else FOV_PUNCH_MINOR)
	_add_event_trauma(float(Tuning.TRAUMA[&"wall_break"]) if headline else STRIKE_HOLE_TRAUMA, position)

func _on_limb_severed(fighter: Node3D, _cut: StringName, _piece: Node3D) -> void:
	_add_event_trauma(float(Tuning.TRAUMA[&"limb_lost"]),
		fighter.global_position if is_instance_valid(fighter) else Vector3.ZERO)

func _on_landing(fighter: Node3D, level: StringName, _position: Vector3, _vertical_speed: float) -> void:
	if fighter != target:
		return
	if level == &"heavy":
		_heavy_trauma()
	elif level == &"hard":
		add_trauma(HARD_LANDING_TRAUMA)

## Round 6 clutter (K): a small shake, scaled by distance; no slow motion.
func _on_furniture_broken(_node: Node3D, position: Vector3, _kind: StringName, _energy: float, _by: Node3D) -> void:
	_furniture_shake(position)

func _furniture_shake(position: Vector3) -> void:
	var t := TimeDirector.now()
	if t - _last_furniture < FURNITURE_GROUP:
		return
	_last_furniture = t
	_add_event_trauma(FURNITURE_TRAUMA, position)

## Body slam (G): the holder lands on the body: heavy-landing trauma.
func _on_body_slammed(holder: Node3D, _victim: Node3D, _position: Vector3) -> void:
	if holder == target:
		_heavy_trauma()

## Round 6: falling structure pieces (group "falling_pieces": a pillar's beam
## and sign, a lintel, a snapped pillar's upper sections) thump when they hit
## something: falling at THUMP_MIN_SPEED or more, the speed drops under half
## its falling peak within THUMP_WINDOW (a crash into rubble takes a few ticks).
## Energy = 1/2 m peak^2. Every impact counts (a beam may clip the stump, then
## land); the peak resets, so a bounce never thumps again unless the piece
## falls fast again. Floor craters are not counted here
## (the player's slam already gave its heavy-landing trauma).
func _physics_process(delta: float) -> void:
	if not is_inside_tree():
		return
	_game_t += delta
	var seen := {}
	for n in get_tree().get_nodes_in_group(&"falling_pieces"):
		var rb := n as RigidBody3D
		if rb == null or rb.freeze or not rb.is_inside_tree() or rb.mass < Tuning.FALLING_MIN_MASS:
			continue
		var id := rb.get_instance_id()
		seen[id] = true
		var st: Dictionary = _pieces.get(id, {"peak": 0.0, "at": -100.0})
		_pieces[id] = st
		var v := rb.linear_velocity
		var speed := v.length()
		var recent := _game_t - float(st["at"]) <= THUMP_WINDOW
		if v.y < -1.0 and (speed >= float(st["peak"]) or not recent):
			st["peak"] = speed  # falling: the speed it hits with
			st["at"] = _game_t
		elif recent and float(st["peak"]) >= THUMP_MIN_SPEED and speed < float(st["peak"]) * 0.5:
			# The peak resets: the piece thumps again only after falling fast again.
			_thump(0.5 * rb.mass * float(st["peak"]) * float(st["peak"]), rb.global_position, rb)
			st["peak"] = 0.0
	for id in _pieces.keys():
		if not seen.has(id):
			_pieces.erase(id)

## A heavy thump from a landing piece of `energy` J at `pos`, scaled by
## distance. Pieces landing within THUMP_GROUP of each other are one collapse:
## their energies add up and the trauma rises to what the total is worth
## (Tuning.TRAUMA heavy_landing at most), never a stack of thumps.
func _thump(energy: float, pos: Vector3, piece: Node3D = null) -> void:
	var t := TimeDirector.now()
	var grouped := t - _last_thump < THUMP_GROUP
	if grouped:
		_group_energy += energy
	else:
		_last_thump = t
		_group_energy = energy
	var amount := float(Tuning.TRAUMA[&"heavy_landing"]) * clampf(_group_energy / THUMP_FULL_ENERGY, THUMP_MIN_SHARE, 1.0)
	var felt := amount * _event_k(pos)
	if grouped:
		# One collapse: the trauma rises to what the group's energy is worth (capped
		# at a heavy landing), never a stack of thumps.
		if felt <= _trauma:
			return
		_trauma = clampf(felt, 0.0, 1.0)
	else:
		add_trauma(felt)
	_last_thump_amount = amount
	_thumps += 1
	_thump_info = {"energy": _group_energy, "amount": amount, "pos": pos,
		"piece": String(piece.name) if piece != null else "", "mass": (piece as RigidBody3D).mass if piece is RigidBody3D else 0.0}

## Debug / tests: how many falling-piece thumps added trauma, and the last one.
func get_thump_count() -> int:
	return _thumps

func get_last_thump() -> Dictionary:
	return _thump_info

## Heavy landing / slam: once, even when both events report the same landing.
func _heavy_trauma() -> void:
	var t := TimeDirector.now()
	if t - _last_heavy < HEAVY_DEDUPE:
		return
	_last_heavy = t
	add_trauma(float(Tuning.TRAUMA[&"heavy_landing"]))

func _on_rammed(runner: Node3D, victim: Node3D, _result: StringName, _self_result: StringName) -> void:
	if runner == target or victim == target:
		add_trauma(float(Tuning.TRAUMA[&"ram"]))

## Last enemy of a wave down: cut to the close side angle for the last-kill slow motion.
func _on_last_kill(fighter: Node3D) -> void:
	if not _alive_node(fighter) or not _alive_node(target) or target.is_dead():
		return
	start_closeup(fighter, float(Tuning.SLOW_TIME[&"last_kill"]["time"]), false, true)

## The player died: slow orbit around the ragdoll.
func _on_fighter_died(fighter: Node3D, _info: HitInfo) -> void:
	if fighter != null and fighter == target:
		start_orbit(fighter)

func _on_wall_run_started(fighter: Node3D, wall: Node3D, _side: int) -> void:
	if fighter != target:
		return
	_wall_rids.clear()
	_collect_rids(wall, 0)
	_wall_until = TimeDirector.now() + Tuning.WALLRUN_TIME + WALLRUN_EXCLUDE_GRACE

func _on_wall_run_ended(fighter: Node3D, _reason: StringName) -> void:
	if fighter == target:
		_wall_until = minf(_wall_until, TimeDirector.now() + WALLRUN_EXCLUDE_GRACE)

func _collect_rids(n: Node, depth: int) -> void:
	if n == null or not is_instance_valid(n) or depth > 2:
		return
	if n is CollisionObject3D:
		_wall_rids.append((n as CollisionObject3D).get_rid())
	for c in n.get_children():
		_collect_rids(c, depth + 1)

## Is this wall_broken worth the WALL BREAK banner and a full camera punch?
## Impact breaks always are. A strike-made hole only on the panel's first
## strike hole or when the strike broke the whole panel.
static func is_headline_break(wall) -> bool:
	if not is_instance_valid(wall) or not ("last_break_by_strike" in wall):
		return true
	if not bool(wall.get(&"last_break_by_strike")):
		return true
	var holes := int(wall.get(&"strike_holes")) if "strike_holes" in wall else 1
	var broken := bool(wall.get(&"is_broken")) if "is_broken" in wall else false
	return holes <= 1 or broken

func _on_fighter_launched(fighter: Node3D, velocity: Vector3) -> void:
	var f := fighter as Fighter
	if f == null or f == target:
		return
	if velocity.length() >= Power.launch_speed(Tuning.TIER_BANDS[3]) and _launched_by_player(f):
		punch_fov()
	_track_launch(f)

func _on_thrown(_grabber: Node3D, victim: Node3D, _velocity: Vector3) -> void:
	var f := victim as Fighter
	if f != null and f != target:
		_track_launch(f)

## Frame this body for CAM_LAUNCH_FOLLOW s (a new launch restarts the window).
func _track_launch(f: Fighter) -> void:
	if not _alive_node(target) or not _alive_node(f):
		return
	if _flat_dist(target.get_ground_position(), f.get_ground_position()) > FRAME_RADIUS:
		return
	var t := TimeDirector.now()
	# The same launch reported twice (fighter_launched and hit_landed) keeps its start.
	if f == _launch_body and t - _launch_t0 < 0.1:
		return
	_launch_body = f
	_launch_t0 = t

func _launched_by_player(f: Fighter) -> bool:
	if f.combat != null and f.combat.last_received != null:
		return f.combat.last_received.attacker == target
	return true

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

func _point_of(n) -> Vector3:
	if n is Fighter:
		return (n as Fighter).get_center_of_mass()
	return n.global_position

func _pelvis(f: Fighter) -> Vector3:
	if f.rig != null and is_instance_valid(f.rig):
		return f.rig.get_bone_global_position(Bones.HIPS)
	return f.get_center_of_mass()

func _yaw_behind(f: Fighter) -> float:
	var fwd := f.get_forward()
	fwd.y = 0.0
	return atan2(-fwd.x, -fwd.z) if fwd.length() > 0.01 else _yaw

static func _label_of(n) -> String:
	if n is Fighter:
		return "%s#%d" % [String((n as Fighter).archetype), (n as Node).get_instance_id() % 10000]
	return String((n as Node).name)

## Distance on the floor plane (XZ). Public for GameMode.
static func flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

## Old name kept for callers that still use it.
static func _flat_dist(a: Vector3, b: Vector3) -> float:
	return flat_dist(a, b)
