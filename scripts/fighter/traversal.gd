class_name Traversal
extends Node
## Round 5 player locomotion (Feel Reference: Movement spec): sprint that builds,
## the short dash, jump, automatic parkour, wall run, landing levels, and
## running into enemies (Battering Ram). Player only; enemies keep Fighter's
## own walking code.
## OWNER: agent M (movement). CONTRACT STUB: keep every public signature.
##
## Contract:
## - Fighter creates this node for the player and calls physics_move() every
##   physics tick after its frozen / ragdolling / held early-outs. Return true
##   once this node moved the capsule itself (Fighter then skips its own code);
##   false falls back to Fighter's Upgrade 2 movement.
## - Player time: every velocity, acceleration and timer here runs in the
##   player's own time (Fighter.own_delta / own_time_factor), so the player keeps
##   real speed in any slow motion. Honour Fighter.knockback() and
##   CombatController.has_forced_velocity() (lunges) like Fighter does.
## - Dash routing (CombatController.press): Defence first (teleport, sidestep,
##   pursuit), then on_dash_pressed() here, then the old combat dash.
## - Jump routing (PlayerController): on_jump_pressed() here first, else Fighter.jump().
##
## How it moves (agent M):
## - `fighter.velocity` keeps Fighter's meaning: m per player second. Gravity,
##   the sprint ramp and every timer step by own_delta(); only move_and_slide()
##   sees velocity x own_time_factor(). Input windows (coyote, jump buffer, the
##   150 ms Dash hold) use TimeDirector.now() (real time).
## - Modes: GROUND (walk, short dash, sprint, release bleed, sprint charge,
##   landing pauses), AIR (jump, fall, kick-off flight, dropping strike),
##   PARKOUR (step / vault / mantle / kick-off / air mantle: the capsule follows a
##   curve driven by a manually stepped Tween, so it runs in player time and
##   stops in hitstop), WALL_RUN, HANG (pursuit).
## - Sprint speed lives in one scalar (`_speed`, along `_heading`). Below the
##   sprint start speed the capsule walks with Fighter's vector acceleration.
## - "Earned" speed (what power and the Battering Ram read) is the sprint ramp,
##   never the short-dash burst, a lunge or a knockback: a dash-tap jab is a
##   standing jab.
## - Any strike thrown fast (sprint, bleed, charge steering, wall run, dropping
##   strike) ends the sprint; a held Dash then builds again from 6 m/s once the
##   strike (or a dropping strike's landing) is over.
## - A sprinting charge (or a press not yet committed) owns the capsule: speed
##   kept, Tuning.CHARGE_SPRINT_STEER steering; B's lunge drives it from the
##   commit (on_strike_started) on.
## - A vault's dropping strike follows the vault until the body has cleared
##   the obstacle's far side, then plunges (never lands on a wall's top).

enum Mode { GROUND, AIR, PARKOUR, WALL_RUN, HANG }

# --- Local tuning (candidates for Tuning; listed in agent M's report) ----------
## The short dash (lead decision): it opens at the current speed cap (8 base;
## upgrades and carrying scale it; never above) and eases (cosine) to exactly
## Tuning.SPRINT_START_SPEED at Tuning.DASH_HOLD_SPRINT. Held, the sprint ramp
## takes over there at 6 m/s; a tap eases on to walking (to a stop with the
## stick neutral) and covers Tuning.SHORT_DASH_DIST in all.
## s the 6 -> cap ramp takes from that hand-off, so a held Dash reaches the cap
## Tuning.SPRINT_RAMP_TIME (1.2 s) after the press ("6 -> 8 m/s over 1.2 s of holding").
const RAMP_TIME := Tuning.SPRINT_RAMP_TIME - Tuning.DASH_HOLD_SPRINT
## s after a short dash ends before another burst (a held sprint is never limited).
const DASH_REARM := 0.1
## deg/s the sprint heading follows the stick. A 90-degree cut takes 0.17 s, so
## it always pays Tuning.TURN_PENALTY; a curve slower than 300 deg/s never does.
const SPRINT_STEER_RATE := 540.0
## m/s^2 back up to sprint start speed when a loss put the sprint under it
## (a turn penalty or a mantle at low speed). About twice the ramp's own
## opening slope: the 30% is felt for ~0.1-0.4 s, not undone in one tick.
const SPRINT_LOW_ACCEL := 4.0
## Ease-out power of the 6 -> cap ramp: speed = 6 + (cap - 6)(1 - (1 - t/RAMP_TIME)^p).
## 1.25 eases out to the cap exactly at 1.2 s, with 98% of the cap (where the
## power score already counts the cap) at 1.04 s and 99% at 1.11 s, so "full
## speed" reads as 1.2 s however it is measured. A quadratic ease would read
## as full speed by 0.86 s, well before the doc's 1.2 s.
const RAMP_EASE_POW := 1.25
## m/s^2 down to a lowered cap (picking up a body, a debug change).
const SPRINT_OVER_DECEL := 12.0
## A sprint pushed straight into a wall collapses to the speed it really has
## once less than this share of it survives the slide (grinding along a wall
## at a shallow angle keeps the run).
const SPRINT_BLOCKED_SHARE := 0.5
## Stick length under which the stick is neutral.
const STICK_DEADZONE := 0.2
## Sprint state kicks in from this share of SPRINT_START_SPEED (vaults, mantles,
## charge steering read "sprinting" as moving this fast).
const SPRINT_SPEED_SHARE := 0.95
## m/s: steps under Tuning.STEP_MAX happen from this speed (the doc's 3 m/s
## gate is for vaults; a slow walker must not stick on a curb).
const STEP_MIN_SPEED := 1.0
## m clearance over an obstacle's top during a vault / mantle.
const VAULT_CLEAR := 0.08
## m extra bulge of the vault arc at its middle (the legs swing over).
const VAULT_BULGE := 0.12
## m: probe sphere radius (knee, chest, head).
const PROBE_RADIUS := 0.18
## m above the feet the top-finding ray starts (above MANTLE_MAX, so a hit
## from inside means "taller than a mantle").
const TOP_RAY_FROM := 2.6
## m inside the face the top-finding ray samples.
const TOP_INSET := 0.06
## m above the floor under a falling (not jumping) player within which the
## ground's steps and vaults still run: dropping off a table, a sofa's back or
## a low wall into the next thing (a crate's corner) is still running.
const AIR_PARKOUR_HEIGHT := 1.0
## m: a top lower than this above the feet is a floor bump, not an obstacle.
const OBSTACLE_MIN := 0.05
## m: an obstacle's far edge is where its top drops this far.
const FAR_EDGE_DROP := 0.25
## m spacing of the far-edge samples.
const FAR_EDGE_STEP := 0.15
## Head-on share (velocity . -normal) needed to vault / mantle (cos 70 deg) and
## to kick off a tall wall (cos 45 deg: shallower runs along a wall are wall-run
## territory, Tuning.WALLRUN_ANGLE tops out at 45 degrees off the surface).
const VAULT_INCIDENCE := 0.34
const KICKOFF_INCIDENCE := 0.707
## A wall kick-off needs this share of the cap ("at full speed").
const KICKOFF_SPEED_SHARE := 0.9
## m the feet climb the wall during the 0.3 s kick-off, then the hop height.
const KICKOFF_RISE := 0.5
const KICKOFF_HOP := 1.0
## m: the vault lands this far below the start at most; lower = it ends in the air.
const VAULT_DROP_MAX := 0.6
## s: a vault planned short of a fighter behind the wall takes at least this
## (its distance at the run's speed; never slower than the run).
const VAULT_TIME_MIN := 0.1
## m spacing and reach of the scan for low obstacles packed in a row past a vault.
const CHAIN_STEP := 0.1
const CHAIN_MAX := 2.0
## m between the shorter landings tried when a fighter stands behind a low wall.
const VAULT_LAND_STEP := 0.15
## m sideways the vault may veer to land beside a fighter behind the wall.
const VAULT_SIDE_OFFSETS: Array[float] = [0.45, -0.45, 0.9, -0.9]
## Static geometry only (capsule checks that ignore fighters).
const WORLD_MASK := Layers.WORLD | Layers.DESTRUCTIBLE
## m above the feet the hands reach in the air (arms up), for the air mantle.
const AIR_HAND_HEIGHT := 2.0
## s the air mantle takes (shorter than the ground mantle: no foot plant).
const AIR_MANTLE_TIME := 0.35
## m above the take-off floor: the air mantle never climbs higher (one storey,
## Feel Reference "a short wall run-up (one storey)"); the Yard's 4.2 m outer
## walls and 4 m pillars stay out of reach, so nobody leaves the arena.
const AIR_MANTLE_MAX := 3.0
## s the heavy-landing roll lasts (keeps Tuning.LAND_ROLL_KEEP).
const LAND_ROLL_TIME := 0.4
## s of P's sprint_start pose (the first stride of a sprint that did not open
## with the dash burst).
const SPRINT_START_POSE := 0.35
## m/s downward a dropping strike starts at (it plunges, it does not float).
const DROP_STRIKE_SPEED := 8.0
## m/s: the wall run pulls the capsule to the wall at most this fast, and
## always presses into it at least this hard (the "small force").
const WALLRUN_PULL_MAX := 6.0
const WALLRUN_PRESS := 0.6
## Stick pointing away from the wall more than this (dot with the normal) ends the run.
const WALLRUN_STICK_AWAY := 0.5
## deg: the wall's normal may turn this much during a run (gentle curves).
const WALLRUN_NORMAL_TURN := 35.0
## Two wall hits are the same wall (the same-wall cooldown) within this many
## degrees of normal and this many m of plane offset (panels of one facade).
const WALL_SAME_DEG := 10.0
const WALL_SAME_OFFSET := 0.35
## Battering Ram: a capsule this close (beyond both radii) and in front counts as touching.
const RAM_TOUCH_GAP := 0.06
## Front cone for the ram (cos 60 deg from the heading).
const RAM_FRONT_DOT := 0.5
## s a runner and a rammed victim ignore each other's capsule / bones (ploughing through).
const RAM_PASS_TIME := 0.6
## s before the same enemy can be rammed again.
const RAM_REPEAT := 0.5
## Pushing loose rigid clutter (a chair, a drum, a cabinet): it leaves at up to
## this share of the runner's speed into it (it flies ahead, not under the feet)...
const PUSH_BODY_SHARE := 1.2
## ...the runner keeps M / (M + m) of that speed (momentum), and the two ignore
## each other this long so the capsule ploughs on instead of stopping dead.
const PUSH_PASS_TIME := 0.25
## m/s into it below which a touch is a lean, not a push.
const PUSH_MIN_SPEED := 0.5
## Share of the ram push that goes sideways (people fly aside, Prototype 2 at 2.7 s).
const RAM_SIDE_SHARE := 0.6
## s a strike stays "pending" (sprint kept) before it must have committed: a
## tap commits at the press; past CombatController's hold threshold it charges.
const STRIKE_COMMIT_GRACE := Tuning.HOLD_THRESHOLD + 2.0 / 120.0
## m/s: under this a body is "not moving" (footsteps, locomotion style).
const MOVING_SPEED := 0.5
## s window of heading samples for the turn penalty history.
const TURN_HISTORY := Tuning.TURN_PENALTY_WINDOW
## deg: after a turn penalty the heading counts as steady again (the next turn
## can be charged) once it turns less than this over a whole TURN_HISTORY.
## Half the penalty angle, so a gentle curve is steady.
const TURN_STEADY_DEG := Tuning.TURN_PENALTY_ANGLE * 0.5

var fighter: Fighter
## 0..1 = sprint start speed (6 m/s) .. the speed cap. Effects, camera and audio read it.
var sprint_charge := 0.0

# --- Logs for tests and the debug overlay --------------------------------------
var turn_penalties := 0           ## times the turn penalty was applied
var last_landing: StringName = &"" ## &"soft" | &"hard" | &"heavy"
var last_landing_speed := 0.0
var last_parkour: StringName = &""
## How the last vault landed: &"planned" | &"short" | &"side" | &"top" | &"overlap".
var last_vault_landing: StringName = &""
var rams := 0

var _mode: int = Mode.GROUND
var _clock := 0.0                 ## player s (stops in hitstop)
var _heading := Vector3.FORWARD   ## unit XZ run direction (sprint, dash, air)
var _free_hv := Vector3.ZERO      ## last horizontal velocity from our own locomotion (no forced)
var _last_pos := Vector3.INF
var _floor_collider: Object
var _capsule_shape: CapsuleShape3D
var _style: StringName = &""      ## locomotion style last sent to the animator

# Dash and sprint
var _dash_held := false
var _press_t := -INF              ## real time of the current hold's press
var _burst_left := 0.0            ## player s of the short dash left
var _burst_time := 0.0
var _burst_end_speed := 0.0
var _burst_peak := 8.0
var _burst_tail := 0.0            ## s of the tap's ease from 6 m/s to walking
var _burst_rearm_at := -INF       ## player clock
var _sprinting := false
var _speed := 0.0                 ## sprint / bleed speed along _heading (m per player s)
var _bleed_left := 0.0
var _bleed_from := 0.0
var _charge_steer := false
var _charge_speed := 0.0
var _charge_steer_frame := -10    ## physics frame charge steering was last on (a hit's reaction ends it first)
var _rebuild := false             ## a strike (or a stop) ended the sprint: a held Dash restarts it from 6 m/s
var _attack_seen := false         ## CombatController was attacking last tick
var _attack_since := 0.0          ## player clock when it started
var _committed := false           ## on_strike_started() (or the fallback) for this attack
var _commit_frame := -10          ## physics frame of the last on_strike_started()
var _turn_hist: Array[Vector2] = [] ## (clock, yaw)
var _turn_locked := false         ## a penalty was taken: none again until the heading is steady
var _step_accum := 0.0

# Jump, air, landing
var _coyote_until := -INF
var _jump_buffer_until := -INF
var _jumping := false             ## this airtime began with a jump (not a fall)
var _air_speed := 0.0             ## horizontal speed at take-off (air steering cap, earned speed)
var _air_top := -INF              ## highest feet y of this airtime
var _air_floor := 0.0             ## feet y where this airtime began (air mantle cap)
var _drop_strike := false
var _drop_sprint := false         ## the dropping strike counts as full sprint (vault drop)
var _slam := false
var _hang_attack := false         ## a pursuit hang ended by an attack: that strike is not a drop
var _land_left := 0.0             ## player s of landing pause
var _land_kind: StringName = &""  ## &"crouch" | &"three_point" | &"roll"
var _roll_vel := Vector3.ZERO
var _air_dash_left := 0.0         ## player s of the air dash left
var _air_dash_time := 0.0
var _air_dash_end := 0.0          ## m/s the air dash eases down to (the speed it started from)
var _air_dash_peak := 8.0
var _air_dashed := false          ## one air dash per airtime (reset on the floor or a wall run)

# Parkour (tween-driven curve)
var _pk_kind: StringName = &""
var _pk_tween: Tween
var _pk_p := 0.0
var _pk_start := Vector3.ZERO
var _pk_pts: Array[Vector3] = []  ## curve keys (positions)
var _pk_keys: Array[float] = []   ## progress of each key
var _pk_exit_vel := Vector3.ZERO
var _pk_exit_air := false
var _pk_sprint := false
var _pk_face := Vector3.FORWARD
var _pk_posed := false            ## this curve started a timed pose (scrubbed by progress)
var _pk_clear_p := 0.0            ## progress where the body has cleared the obstacle (vault drop)
## Steps and vaults move horizontally on a speed profile (speed linear from
## _pk_va to _pk_vb over _pk_dur along the straight path to the curve's end);
## the keys shape only the height. Mantles and kick-offs follow their keys.
var _pk_profile := false
var _pk_va := 0.0
var _pk_vb := 0.0
var _pk_time := 0.0
var _pk_len := 0.0
var _pk_drop_queued := false      ## a dropping strike waits for _pk_clear_p, then plunges

# Wall run
var _wr_t := 0.0
var _wr_side := 0
var _wr_normal := Vector3.ZERO
var _wr_dir := Vector3.ZERO
var _wr_speed := 0.0
var _wr_y0 := 0.0
var _wr_wall: Object
var _wr_step := 0.0
## Walls run on since the floor was last touched, as planes (n.x, n.z, offset
## along n): a facade of separate panels is one wall.
var _used_walls: Array[Vector3] = []

# Hang (pursuit)
var _hang_until := -INF

# Battering Ram
var _ram_last := {}               ## victim instance id -> real time

# Probes (Feel Reference: three forward ShapeCast3Ds, a downward RayCast3D)
var _probes: Array[ShapeCast3D] = []
var _ray: RayCast3D
var _q_shape := CapsuleShape3D.new()
var _q_params := PhysicsShapeQueryParameters3D.new()

func setup(p_fighter: Fighter) -> void:
	fighter = p_fighter
	_heading = fighter.get_forward()
	for i in 3:
		var sc := ShapeCast3D.new()
		sc.name = "Probe%d" % i
		var sphere := SphereShape3D.new()
		sphere.radius = PROBE_RADIUS
		sc.shape = sphere
		sc.enabled = false
		sc.max_results = 4
		sc.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE | Layers.CAPSULE
		sc.add_exception(fighter)
		add_child(sc)
		_probes.append(sc)
	_ray = RayCast3D.new()
	_ray.name = "TopRay"
	_ray.enabled = false
	_ray.hit_from_inside = true
	_ray.add_exception(fighter)
	add_child(_ray)
	_q_params.exclude = [fighter.get_rid()]
	_q_params.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE | Layers.CAPSULE
	if fighter.ragdoll != null:
		fighter.ragdoll.state_changed.connect(_on_ragdoll_state_changed)
	if fighter.combat != null:
		fighter.combat.hit_received.connect(_on_hit_received)
	GameEvents.strike_started.connect(_on_strike_event)

# =============================================================================
# Contract API
# =============================================================================

## Fighter calls this for the player. true = moved the capsule this tick.
func physics_move(delta: float) -> bool:
	if fighter == null or fighter.capsule == null:
		return false
	var pdt := fighter.own_delta(delta)
	var factor := fighter.own_time_factor()
	if pdt <= 0.0:
		return true
	_capsule_shape = fighter.capsule.shape as CapsuleShape3D
	_clock += pdt
	var now := TimeDirector.now()
	_check_discontinuity()
	_adopt_fighter_jump(now)
	_track_attack()
	if _mode != Mode.AIR and _mode != Mode.WALL_RUN:
		fighter.set_crouch_input(fighter.crouch_input)  # Fighter skips its own update
	_update_dash_hold(now)
	match _mode:
		Mode.PARKOUR:
			_tick_parkour(pdt)
		Mode.WALL_RUN:
			_tick_wall_run(pdt, factor, now)
		Mode.HANG:
			_tick_hang(pdt, factor, now)
		Mode.AIR:
			_tick_air(pdt, factor, now)
		_:
			_tick_ground(pdt, factor, now)
	_update_sprint_charge()
	_update_animator()
	_last_pos = fighter.global_position
	return true

## Dash pressed and not consumed by Defence. true = handled here (short dash
## now; still held after Tuning.DASH_HOLD_SPRINT it becomes a sprint).
func on_dash_pressed() -> bool:
	if fighter == null or fighter.is_dead() or fighter.is_down():
		return false  # the old path keeps the air recovery
	if fighter.ragdoll != null and fighter.ragdoll.is_simulating():
		return false
	_dash_held = true
	_press_t = TimeDirector.now()
	if _mode != Mode.GROUND:
		# Vault, wall run, hang: remember the hold; the sprint resumes on landing.
		# In the air a tap is the short dash too (an air dash, once per airtime).
		if _mode == Mode.AIR:
			if _air_speed >= _sprint_floor():
				_set_sprinting(true)
			_try_air_dash()
		return true
	if not _free_to_run():
		return true  # attacking, stunned, guarding: the hold sprints once free
	var cur := _earned_speed()
	if cur >= _sprint_floor():
		# Already running fast (a re-press during the release bleed): no burst,
		# the sprint resumes from the current speed (from the start speed after
		# a strike: speed spent on a strike is spent).
		_bleed_left = 0.0
		_speed = Tuning.SPRINT_START_SPEED if _rebuild else cur
		_rebuild = false
		_set_sprinting(true)
		return true
	if _clock < _burst_rearm_at:
		return true
	_start_burst()
	return true

func on_dash_released() -> void:
	_dash_held = false
	if _sprinting:
		_set_sprinting(false)
		if _mode == Mode.GROUND and not _charge_steer:
			_start_bleed(_speed)

## Jump pressed. true = handled here (jump, wall run start, wall kick-off).
func on_jump_pressed() -> bool:
	if fighter == null or fighter.is_dead() or fighter.is_down():
		return false
	if fighter.carry != null and fighter.carry.is_held():
		return false
	var now := TimeDirector.now()
	match _mode:
		Mode.WALL_RUN:
			_wall_kickoff()
			return true
		Mode.PARKOUR, Mode.HANG:
			_jump_buffer_until = now + Tuning.JUMP_BUFFER_TIME
			return true
	if _try_wall_run():
		return true
	var grounded := _mode == Mode.GROUND or (now <= _coyote_until and not _jumping)
	if grounded and _can_jump_now():
		_do_jump()
		return true
	_jump_buffer_until = now + Tuning.JUMP_BUFFER_TIME
	return true

## CombatController: a strike (or grab) started. Any strike thrown during a
## sprint drops the player to walking speed, hit or miss.
func on_strike_started(sprint_strike: bool) -> void:
	_committed = true
	_commit_frame = Engine.get_physics_frames()
	_air_dash_left = 0.0  # a strike cuts an air dash short
	if _mode == Mode.HANG:
		_end_hang(true)
	_land_left = 0.0
	_land_kind = &""
	var fast := sprint_strike or _sprinting or _charge_steer or _earned_speed() > Tuning.WALK_SPEED + 0.25
	if _mode == Mode.WALL_RUN:
		_end_wall_run(&"strike", Tuning.WALK_SPEED / maxf(_wr_speed, 0.01))
		_drop_to_walk(false)
		return
	if not fast:
		return
	if _mode == Mode.PARKOUR and not _drop_strike:
		if _pk_kind == &"vault" and _pk_p >= Tuning.VAULT_ATTACK_FROM:
			# Any strike in the last 40% of a vault (a charge released there
			# too) ends it as a dropping strike that keeps the vault speed.
			begin_drop_strike()
			_end_sprint_state()
			return
		_pk_exit_vel = _pk_exit_vel.limit_length(Tuning.WALK_SPEED)  # it leaves the curve at walking speed
	if _drop_strike:
		_end_sprint_state()  # the dropping strike keeps its momentum to the floor
		return
	_drop_to_walk(true)

## CombatController: an attack pressed in the air. true = this becomes a
## dropping strike (a ground slam from Tuning.SLAM_MIN_HEIGHT or higher).
func begin_drop_strike() -> bool:
	if fighter == null:
		return false
	if _mode == Mode.HANG or _hang_attack:
		return false  # a pursuit follow-up is not a dropping strike
	if _mode == Mode.PARKOUR:
		if _pk_kind != &"vault" or _pk_p < Tuning.VAULT_ATTACK_FROM:
			return false
		# The vault ends in a dropping strike that inherits the vault speed. Over
		# a thin obstacle the body first follows the vault until it has cleared
		# the far side (dropping straight down would land on the wall's top).
		_drop_strike = true
		_drop_sprint = _pk_sprint
		_slam = false
		if _pk_p >= _pk_clear_p:
			_vault_to_drop()
		else:
			_pk_drop_queued = true
		return true
	if _mode != Mode.AIR:
		return false
	_air_dash_left = 0.0  # the strike cuts the air dash short
	_drop_strike = true
	_drop_sprint = false
	_slam = _height_above_floor() >= Tuning.SLAM_MIN_HEIGHT
	fighter.velocity.y = minf(fighter.velocity.y, -DROP_STRIKE_SPEED)
	return true

## Defence (pursuit): hold the player in the air, no gravity, for up to this
## long or until an attack starts.
func hang(duration_real: float) -> void:
	if fighter == null or duration_real <= 0.0:
		return
	if _mode == Mode.PARKOUR:
		_finish_parkour_tween()
	if _mode == Mode.WALL_RUN:
		_end_wall_run(&"end", 1.0)
	_mode = Mode.HANG
	_air_dash_left = 0.0
	_hang_until = TimeDirector.now() + duration_real
	_hang_attack = false
	_drop_strike = false
	_slam = false
	fighter.velocity = Vector3.ZERO
	_free_hv = Vector3.ZERO

## Horizontal speed in the player's own time (m/s).
func get_speed() -> float:
	if fighter == null:
		return 0.0
	return Vector2(fighter.velocity.x, fighter.velocity.z).length()

## Speed toward `dir` for the power score's speed bonus. During a wall run or a
## vault drop this is the speed cap (they count as full-sprint attacks).
## Otherwise it is the real velocity toward `dir`, capped at the earned speed
## (the sprint ramp): a short-dash burst, a lunge or a knockback add nothing.
func speed_toward(dir: Vector3) -> float:
	if fighter == null:
		return 0.0
	if _mode == Mode.WALL_RUN:
		return get_speed_cap()
	if _mode == Mode.PARKOUR and _pk_kind == &"vault" and _pk_sprint and _pk_p >= Tuning.VAULT_ATTACK_FROM:
		return get_speed_cap()
	if _drop_strike and _drop_sprint:
		return get_speed_cap()
	var d := Vector3(dir.x, 0.0, dir.z)
	if d.length_squared() < 1e-6:
		return 0.0
	d = d.normalized()
	var hv := _free_hv
	if _mode == Mode.PARKOUR:
		hv = _pk_exit_vel
	return clampf(hv.dot(d), 0.0, _earned_speed())

## Current sprint cap (Tuning.debug_speed_cap), lowered while carrying.
func get_speed_cap() -> float:
	var cap := Tuning.debug_speed_cap
	if fighter != null and fighter.carry != null and fighter.carry.is_holding():
		cap *= fighter.carry.get_sprint_cap_mult()
	return cap

func is_sprinting() -> bool:
	return _sprinting or _charge_steer or _mode == Mode.WALL_RUN \
		or (_mode == Mode.PARKOUR and _pk_sprint)

## Charging at a sprint: speed kept, steering capped (Tuning.CHARGE_SPRINT_STEER).
func is_charge_steering() -> bool:
	return _charge_steer

func is_vaulting() -> bool:
	return _mode == Mode.PARKOUR and _pk_kind != &"step"

## 0..1 through the current vault / mantle / kick-off.
func get_vault_progress() -> float:
	return _pk_p if is_vaulting() else 0.0

func is_wall_running() -> bool:
	return _mode == Mode.WALL_RUN

## -1 wall on the left, +1 on the right, 0 none.
func get_wall_side() -> int:
	return _wr_side if _mode == Mode.WALL_RUN else 0

func get_wall_normal() -> Vector3:
	return _wr_normal if _mode == Mode.WALL_RUN else Vector3.ZERO

## In the air by jump, fall, kick-off or hang (not vaulting, not wall running).
## Fighter.is_airborne() should return this for the player (H).
func is_airborne() -> bool:
	return _mode == Mode.AIR or _mode == Mode.HANG

## m fallen below the highest point of the current airtime (camera fall tilt).
func get_fall_height() -> float:
	if _mode != Mode.AIR or fighter == null:
		return 0.0
	return maxf(_air_top - fighter.global_position.y, 0.0)

func get_debug_text() -> String:
	var mode_name: String = Mode.keys()[_mode]
	if _mode == Mode.PARKOUR:
		mode_name += " %s %.2f" % [_pk_kind, _pk_p]
	return "move %s  v %.2f  earned %.2f  charge %.2f%s%s  land %s" % [mode_name, get_speed(),
		_earned_speed(), sprint_charge, "  SPRINT" if _sprinting else "",
		"  STEER" if _charge_steer else "", last_landing]

# --- Extra queries (agent M; H / B / E / F may use them) -------------------------
## Jump now if able (H: Fighter.jump() for the player can call this). true on take-off.
func jump() -> bool:
	if _mode == Mode.GROUND and _can_jump_now():
		_do_jump()
		return true
	return false

## In a landing pause (hard crouch, three-point landing, roll).
func is_landing() -> bool:
	return _land_left > 0.0

## &"crouch" | &"three_point" | &"roll" during a landing pause, else &"".
func get_landing_kind() -> StringName:
	return _land_kind if _land_left > 0.0 else &""

## &"" when not doing parkour, else &"step" | &"vault" | &"mantle" | &"kickoff" | &"air_mantle".
func get_parkour_kind() -> StringName:
	return _pk_kind if _mode == Mode.PARKOUR else &""

## A dropping strike is falling toward the floor (B times its active frames on the landing).
func is_drop_striking() -> bool:
	return _drop_strike

## The current dropping strike is a ground slam (heavy landing + shockwave).
func is_slamming() -> bool:
	return _drop_strike and _slam

func is_hanging() -> bool:
	return _mode == Mode.HANG

## Dash is held (sprint wanted).
func is_dash_held() -> bool:
	return _dash_held

## In an air dash (a Dash tap in the air): F gives it the full sprint blur.
func is_air_dashing() -> bool:
	return _mode == Mode.AIR and _air_dash_left > 0.0

# =============================================================================
# Ground
# =============================================================================

func _tick_ground(pdt: float, factor: float, now: float) -> void:
	var stick := _stick()
	var hv := Vector3(fighter.velocity.x, 0.0, fighter.velocity.z)
	var cap := get_speed_cap()
	# A Fighter.knockback() always wins. A sprinting charge (and a press not yet
	# committed at sprint speed) owns the capsule: CombatController's lunge
	# only drives it from the commit on (after on_strike_started()).
	var forced := _knockback_velocity(pdt)
	var steering := false
	if forced == Vector3.INF and _land_left <= 0.0:
		steering = _update_charge_steer()
	if forced == Vector3.INF and not steering:
		forced = _combat_forced_velocity()
	if forced != Vector3.INF:
		hv = forced
	elif _land_left > 0.0:
		hv = _tick_landing_pause(hv, stick, pdt)
	else:
		if steering:
			_charge_steer_frame = Engine.get_physics_frames()
			if _charge_speed > cap:  # the cap dropped mid-charge (picked up a body)
				_charge_speed = maxf(_charge_speed - SPRINT_OVER_DECEL * pdt, cap)
			_steer(_stick_or(_heading), Tuning.CHARGE_SPRINT_STEER, pdt)
			hv = _heading * _charge_speed
		elif _burst_left > 0.0:
			hv = _tick_burst(stick, cap, pdt)
		elif _sprinting and _free_to_run():
			hv = _tick_sprint(stick, cap, pdt)
		elif _bleed_left > 0.0 and _free_to_run():
			hv = _tick_bleed(stick, pdt)
		else:
			if _sprinting:
				_suspend_sprint()
			_bleed_left = 0.0
			hv = _tick_walk(hv, stick, pdt)
		_free_hv = hv
	# Automatic parkour (before the move, so the capsule never stops on the face).
	if forced == Vector3.INF and _try_parkour(hv, pdt):
		return
	var pre_speed := _earned_speed()
	var vy := minf(fighter.velocity.y, 0.0)
	_apply_move(hv, vy, vy, factor)
	var pushed := _push_bodies(hv)
	_after_ground_move(hv, pre_speed, steering, forced != Vector3.INF or pushed, now)
	_update_facing(pdt)
	_tick_footsteps(pdt)

func _after_ground_move(intended: Vector3, pre_speed: float, steering: bool, forced: bool,
		now: float) -> void:
	if not forced:
		_check_ram(intended, pre_speed, now)
	if fighter.is_on_floor():
		_touch_floor()
		if not forced and _contact_step(intended):
			return  # a low edge the knee probe passes over: stepped up onto
		var actual := Vector3(fighter.velocity.x, 0.0, fighter.velocity.z)
		var running := (_sprinting or _bleed_left > 0.0 or steering) and _speed > 0.0
		if not forced and running:
			var want := intended.length()
			var along := actual.dot(_heading)
			if along < _speed * SPRINT_BLOCKED_SHARE:
				# Sprinting into a wall: a near head-on block collapses the run.
				_speed = maxf(along, 0.0)
				_charge_speed = minf(_charge_speed, _speed)
			elif actual.length() < want - 0.01 and actual.length() > 0.01:
				# Grazing an obstacle (a table's corner, a wall at a slant): the
				# run turns along it at full speed instead of bleeding.
				var hv := actual.normalized() * want
				fighter.velocity = Vector3(hv.x, fighter.velocity.y, hv.z)
				_free_hv = hv
		return
	# Walked (or was pushed) off a ledge: falling, with coyote time for a jump.
	_enter_air(false)
	_coyote_until = now + Tuning.COYOTE_TIME

func _tick_walk(hv: Vector3, stick: Vector3, pdt: float) -> Vector3:
	var desired := _lock_scaled(stick) * Tuning.WALK_SPEED * _walk_mult()
	if desired.length_squared() > 1e-4:
		_heading = desired.normalized()
	elif hv.length_squared() > 1e-4:
		_heading = hv.normalized()
	_speed = 0.0
	return hv.move_toward(desired, Fighter.ACCEL * pdt)

## The short dash: from the speed cap down to 6 m/s at the hold time, then (a
## tap) on to walking, covering Tuning.SHORT_DASH_DIST in all. Held, the sprint
## takes over at the hold time (_update_dash_hold ends the burst there).
func _tick_burst(_stick_v: Vector3, _cap: float, pdt: float) -> Vector3:
	var t := _burst_time - _burst_left
	_burst_left = maxf(_burst_left - pdt, 0.0)
	var v := _burst_speed_at(t + pdt * 0.5)  # mid-step sample: the distance comes out exact
	if _burst_left <= 0.0:
		_burst_rearm_at = _clock + DASH_REARM
		v = _burst_end_speed  # hand the velocity to the walk
	return _heading * v

## Speed `t` s into the short dash: cap -> 6 m/s by DASH_HOLD_SPRINT (cosine),
## then (a tap) 6 m/s -> walking over the tail (cosine).
func _burst_speed_at(t: float) -> float:
	var h := Tuning.DASH_HOLD_SPRINT
	var s := Tuning.SPRINT_START_SPEED
	if t <= h:
		return s + (_burst_peak - s) * cos(clampf(t / h, 0.0, 1.0) * PI * 0.5)
	if _burst_tail <= 0.0:
		return _burst_end_speed
	var k := clampf((t - h) / _burst_tail, 0.0, 1.0)
	return _burst_end_speed + (s - _burst_end_speed) * cos(k * PI * 0.5)

func _start_burst() -> void:
	var stick := _stick()
	var dir := stick.normalized() if stick.length() > STICK_DEADZONE else fighter.get_forward()
	_heading = dir
	var s := Tuning.SPRINT_START_SPEED
	var h := Tuning.DASH_HOLD_SPRINT
	# Opens at the speed cap, never above (upgrades raise it, carrying lowers it).
	_burst_peak = maxf(get_speed_cap(), s)
	# A tap eases on to walking pace along the stick (a stop with it neutral).
	var walk := Tuning.WALK_SPEED * (fighter.carry.get_move_speed_mult() if fighter.carry != null else 1.0)
	_burst_end_speed = minf(walk * minf(stick.length(), 1.0) if stick.length() > STICK_DEADZONE else 0.0, s)
	# Cosine eases: distance = T x (end + (start - end) x 2 / pi) per part; the
	# tail is as long as it takes to make SHORT_DASH_DIST in all.
	var dist_open := h * (s + (_burst_peak - s) * 2.0 / PI)
	var avg_tail := _burst_end_speed + (s - _burst_end_speed) * 2.0 / PI
	_burst_tail = maxf(Tuning.SHORT_DASH_DIST - dist_open, 0.0) / maxf(avg_tail, 0.01)
	_burst_time = h + _burst_tail
	_burst_left = _burst_time
	_bleed_left = 0.0
	_rebuild = false
	_speed = Tuning.SPRINT_START_SPEED  # the ramp starts at the press (6 m/s on the first step)
	_turn_hist.clear()
	if fighter.animator != null:
		fighter.animator.play_timed(&"dash", _burst_time)

## The short dash in the air (Feel Reference: "Any other tap: a short dash,
## 3 m"; Prototype 3's air dash): a cosine ease from the speed cap down to
## the speed it started from, along the stick (else the heading), height held
## (no gravity) while it lasts. Once per airtime; never during a dropping strike
## or an attack; it adds nothing to the power score (the earned speed stays the
## pre-dash speed).
func _try_air_dash() -> void:
	if _air_dashed or _drop_strike or _air_dash_left > 0.0:
		return
	var c := fighter.combat
	if c != null and (c.is_attacking() or c.is_stunned() or fighter.carry.is_held()):
		return
	if fighter.carry != null and fighter.carry.get_move_speed_mult() <= 0.0:
		return
	var stick := _stick()
	var hv := Vector3(fighter.velocity.x, 0.0, fighter.velocity.z)
	var dir := stick.normalized() if stick.length() > STICK_DEADZONE else (
		hv.normalized() if hv.length() > MOVING_SPEED else fighter.get_forward())
	_heading = dir
	_air_dash_end = maxf(hv.dot(dir), 0.0)
	_air_dash_peak = maxf(get_speed_cap(), _air_dash_end)  # never above the cap
	var avg := _air_dash_end + (_air_dash_peak - _air_dash_end) * 2.0 / PI
	if avg <= 0.01:
		return
	_air_dash_time = Tuning.SHORT_DASH_DIST / avg
	_air_dash_left = _air_dash_time
	_air_dashed = true
	_free_hv = dir * _air_dash_end
	_air_speed = maxf(_air_speed, _air_dash_end)
	fighter.velocity.y = 0.0
	_play_timed(&"dash", _air_dash_time)

func _tick_sprint(stick: Vector3, cap: float, pdt: float) -> Vector3:
	_speed = _ramp_step(_speed, cap, pdt)
	_steer(_stick_or(_heading), SPRINT_STEER_RATE, pdt)
	_turn_penalty_check()
	return _heading * _speed

## Releasing Dash bleeds the speed back to walking (or to a stop with the stick
## neutral) over Tuning.SPRINT_RELEASE_TIME. It never snaps.
func _tick_bleed(stick: Vector3, pdt: float) -> Vector3:
	_bleed_left = maxf(_bleed_left - pdt, 0.0)
	var target := Tuning.WALK_SPEED * _walk_mult() * minf(stick.length(), 1.0)
	var k := _bleed_left / Tuning.SPRINT_RELEASE_TIME
	_speed = lerpf(target, _bleed_from, k)
	_steer(_stick_or(_heading), SPRINT_STEER_RATE, pdt)
	_turn_penalty_check()
	if _bleed_left <= 0.0:
		_speed = 0.0
		return _heading * target
	return _heading * _speed

func _start_bleed(from_speed: float) -> void:
	if from_speed <= Tuning.WALK_SPEED * 1.01:
		_bleed_left = 0.0
		return
	_bleed_from = from_speed
	_speed = from_speed
	_bleed_left = Tuning.SPRINT_RELEASE_TIME

## Charging an attack at a sprint keeps the speed and steers at
## Tuning.CHARGE_SPRINT_STEER; the player cannot stop. Also covers the moments
## between a press and its commit (a hold that becomes a charge).
func _update_charge_steer() -> bool:
	var c := fighter.combat
	if c == null:
		_charge_steer = false
		return false
	var pending := c.is_charging() or _carry_charging() or (c.is_attacking() and not _committed \
		and _clock - _attack_since < STRIKE_COMMIT_GRACE)
	if not pending:
		_charge_steer = false
		return false
	if _charge_steer:
		return true
	# Only from a real run: a sprint, its release bleed, or speed this module
	# made itself (_free_hv). fighter.velocity is no guide: after a strike's
	# lunge or a knockback it holds that forced velocity, and a standing jab
	# must stay a standing jab (earned speed never includes a lunge).
	var run := _earned_speed()
	if (_sprinting or _bleed_left > 0.0 or run >= _sprint_floor()) and not c.is_stunned():
		_charge_steer = true
		# Never over the cap (holding a body: Carry.get_sprint_cap_mult()).
		_charge_speed = minf(maxf(run, _speed if _sprinting else 0.0), get_speed_cap())
		if _free_hv.length_squared() > 1e-4:
			_heading = Vector3(_free_hv.x, 0.0, _free_hv.z).normalized()
		return true
	return false

func _tick_landing_pause(hv: Vector3, stick: Vector3, pdt: float) -> Vector3:
	_land_left = maxf(_land_left - pdt, 0.0)
	var out: Vector3
	match _land_kind:
		&"roll":
			out = _roll_vel
			if _land_left <= 0.0:
				if _sprinting:
					_speed = _roll_vel.length()  # a held sprint rolls on at the kept speed
				else:
					_start_bleed(_roll_vel.length())
		&"three_point":
			out = hv.move_toward(Vector3.ZERO, Fighter.ACCEL * 2.0 * pdt)
		_:
			# Hard landing crouch: a held direction (or Dash) keeps the run going
			# under the dip; otherwise the feet plant.
			if stick.length() > STICK_DEADZONE or _dash_held:
				out = hv
			else:
				_bleed_left = 0.0
				_speed = 0.0
				out = hv.move_toward(Vector3.ZERO, Fighter.ACCEL * pdt)
	if _land_left <= 0.0:
		_land_kind = &""
	return out

# =============================================================================
# Sprint helpers
# =============================================================================

## Ease-out ramp: speed `t` s after the sprint's start (6 m/s at 0, the cap at RAMP_TIME).
func _ramp_speed_at(t: float, cap: float) -> float:
	var x := clampf(t / RAMP_TIME, 0.0, 1.0)
	return lerpf(Tuning.SPRINT_START_SPEED, cap, 1.0 - pow(1.0 - x, RAMP_EASE_POW))

## Inverse of _ramp_speed_at: s of holding that this speed corresponds to.
func _ramp_time_of(speed: float, cap: float) -> float:
	var span := cap - Tuning.SPRINT_START_SPEED
	if span <= 0.0:
		return RAMP_TIME
	var f := clampf((speed - Tuning.SPRINT_START_SPEED) / span, 0.0, 1.0)
	return RAMP_TIME * (1.0 - pow(1.0 - f, 1.0 / RAMP_EASE_POW))

## One step of the ramp from the current speed (so a turn penalty or a ram
## loss rebuilds along the same curve).
func _ramp_step(speed: float, cap: float, dt: float) -> float:
	if speed > cap:
		return maxf(speed - SPRINT_OVER_DECEL * dt, cap)
	if speed < Tuning.SPRINT_START_SPEED:
		return minf(speed + SPRINT_LOW_ACCEL * dt, Tuning.SPRINT_START_SPEED)
	return _ramp_speed_at(_ramp_time_of(speed, cap) + dt, cap)

## Turn the heading toward `want` at no more than `rate_deg` per player second.
func _steer(want: Vector3, rate_deg: float, dt: float) -> void:
	var w := Vector3(want.x, 0.0, want.z)
	if w.length_squared() < 1e-6:
		return
	w = w.normalized()
	var a := atan2(-_heading.x, -_heading.z)
	var b := atan2(-w.x, -w.z)
	var na := rotate_toward(a, b, deg_to_rad(rate_deg) * dt)
	_heading = Vector3(-sin(na), 0.0, -cos(na))

## A turn sharper than Tuning.TURN_PENALTY_ANGLE inside Tuning.TURN_PENALTY_WINDOW
## loses Tuning.TURN_PENALTY of the current speed; gentle curves cost nothing.
func _turn_penalty_check() -> void:
	var yaw := atan2(-_heading.x, -_heading.z)
	var worst := 0.0
	var oldest := _clock
	var i := 0
	while i < _turn_hist.size():
		var s: Vector2 = _turn_hist[i]
		if _clock - s.x > TURN_HISTORY + 1e-6:
			_turn_hist.remove_at(i)
			continue
		worst = maxf(worst, absf(angle_difference(s.y, yaw)))
		oldest = minf(oldest, s.x)
		i += 1
	if _turn_locked:
		# One turn, one penalty: the rest of a reversal is free; the lock lifts
		# once the heading has held steady over a whole window.
		if _clock - oldest >= TURN_HISTORY - 1.5 / 120.0 and worst < deg_to_rad(TURN_STEADY_DEG):
			_turn_locked = false
	elif worst > deg_to_rad(Tuning.TURN_PENALTY_ANGLE):
		_speed *= 1.0 - Tuning.TURN_PENALTY
		_charge_speed *= 1.0 - Tuning.TURN_PENALTY
		turn_penalties += 1
		_turn_locked = true
		_turn_hist.clear()
	_turn_hist.append(Vector2(_clock, yaw))

func _set_sprinting(on: bool) -> void:
	if on == _sprinting:
		return
	_sprinting = on
	if on:
		_turn_hist.clear()
		_turn_locked = false
		# The first stride of a sprint that did not open with the dash burst
		# (resumed after a strike, a stun, a landing pause, or from a run).
		if _mode == Mode.GROUND and _burst_left <= 0.0 and _land_left <= 0.0:
			_play_timed(&"sprint_start", SPRINT_START_POSE)
		GameEvents.sprint_started.emit(fighter)
	else:
		GameEvents.sprint_ended.emit(fighter)

## Dash held long enough: the sprint takes over (from the short dash, or once
## the player is free to run again after a strike, a stun or a landing).
func _update_dash_hold(now: float) -> void:
	if not _dash_held or _sprinting or _mode != Mode.GROUND:
		return
	if now - _press_t < Tuning.DASH_HOLD_SPRINT - 1e-6:
		return
	if not _free_to_run() or _land_left > 0.0:
		return
	if _rebuild and _bleed_left > 0.0:
		return  # after a strike: back down to walking first, then build again
	if _burst_left > 0.0 or _rebuild:
		# Hand-off from the dash at exactly 6 m/s (or a fresh start after a
		# strike): the ramp builds from here, never dipping.
		_speed = Tuning.SPRINT_START_SPEED
	else:
		_speed = maxf(_earned_speed(), Tuning.SPRINT_START_SPEED)
	_burst_left = 0.0
	_rebuild = false
	_bleed_left = 0.0
	if _heading.length_squared() < 0.5:
		_heading = fighter.get_forward()
	var stick := _stick()
	if stick.length() > STICK_DEADZONE and _burst_left <= 0.0:
		_heading = stick.normalized()
	_set_sprinting(true)

## The sprint cannot run right now (a committed strike, a stun, a guard): drop
## to walking; the hold restarts it from the sprint start speed when free.
func _suspend_sprint() -> void:
	_set_sprinting(false)
	_speed = 0.0
	_press_t = -INF  # still held: the sprint restarts from 6 m/s once free

func _drop_to_walk(clamp_velocity: bool) -> void:
	_end_sprint_state()
	_burst_left = 0.0
	if clamp_velocity and fighter != null:
		var hv := Vector3(fighter.velocity.x, 0.0, fighter.velocity.z)
		if hv.length() > Tuning.WALK_SPEED:
			hv = hv.normalized() * Tuning.WALK_SPEED
		fighter.velocity = Vector3(hv.x, fighter.velocity.y, hv.z)
		_free_hv = hv
		_air_speed = minf(_air_speed, Tuning.WALK_SPEED)

func _end_sprint_state() -> void:
	_set_sprinting(false)
	_charge_steer = false
	_bleed_left = 0.0
	_speed = 0.0
	_charge_speed = 0.0
	_rebuild = true
	if _dash_held:
		_press_t = -INF  # still held: the sprint rebuilds from 6 m/s once free

## Speed that counts: the sprint ramp (not a dash burst, lunge or knockback).
func _earned_speed() -> float:
	match _mode:
		Mode.WALL_RUN:
			return _wr_speed
		Mode.PARKOUR:
			return _pk_exit_vel.length()
		Mode.AIR, Mode.HANG:
			# Never more than the take-off speed (a lunge's leftover is not earned).
			return minf(Vector3(_free_hv.x, 0.0, _free_hv.z).length(), maxf(_air_speed, Tuning.WALK_SPEED))
	if _charge_steer:
		return _charge_speed
	var actual := _free_hv.length()
	if _burst_left > 0.0:
		return minf(actual, _speed if _sprinting else Tuning.WALK_SPEED)
	if _sprinting or _bleed_left > 0.0:
		return minf(actual, _speed)
	# Walking earns walking speed at most: what is left of a lunge or a
	# knockback as it decays is not speed the player built.
	return minf(actual, Tuning.WALK_SPEED)

func _sprint_floor() -> float:
	return Tuning.SPRINT_START_SPEED * SPRINT_SPEED_SHARE

func _update_sprint_charge() -> void:
	var cap := get_speed_cap()
	var span := cap - Tuning.SPRINT_START_SPEED
	var v := _earned_speed()
	sprint_charge = clampf((v - Tuning.SPRINT_START_SPEED) / span, 0.0, 1.0) if span > 0.0 else 0.0

## Free to run: not attacking (beyond a pending press), stunned, guarding or held.
func _free_to_run() -> bool:
	if fighter.is_crouching():
		return false  # crouching walks at crouch speed: no dash, no sprint
	if fighter.carry != null and (fighter.carry.is_held() or fighter.carry.get_move_speed_mult() <= 0.0):
		return false  # clinching, being held, a grab's recovery
	var c := fighter.combat
	if c == null:
		return true
	if fighter.carry.is_held() or c.is_stunned() or c.blocking:
		return false
	if c.is_attacking():
		return false
	return c.get_move_speed_mult() > 0.0

func _walk_mult() -> float:
	var m := fighter.combat.get_move_speed_mult() if fighter.combat != null else 1.0
	if fighter.carry != null:
		m *= fighter.carry.get_move_speed_mult()  # holding 70%; clinching, recovering 0
	if fighter.is_crouching():
		m *= Tuning.CROUCH_SPEED
	return m

## G's body slam is under way (holder lands on the body: a heavy landing).
func _carry_slamming() -> bool:
	return fighter.carry != null and fighter.carry.has_method(&"is_slamming") \
		and bool(fighter.carry.call(&"is_slamming"))

## Charging a throw (G) steers like a charging strike.
func _carry_charging() -> bool:
	return fighter.carry != null and fighter.carry.has_method(&"is_charging") \
		and bool(fighter.carry.call(&"is_charging"))

## Track CombatController's attack state: the commit of each attack (a tap
## commits at the press; a hold at its release). Fallback when B has not
## called on_strike_started(): a pending attack past the hold threshold that
## is not charging, or a charge that just released, commits now.
func _track_attack() -> void:
	var c := fighter.combat
	if c == null:
		return
	var attacking := c.is_attacking()
	if attacking and not _attack_seen:
		_attack_since = _clock
		# B commits taps inside its own tick, before this one: keep that commit.
		_committed = _commit_frame == Engine.get_physics_frames()
	if not attacking:
		_committed = false
	elif not _committed and not c.is_charging() and _clock - _attack_since >= STRIKE_COMMIT_GRACE:
		on_strike_started(_charge_steer or _sprinting)
	_attack_seen = attacking

# =============================================================================
# Jump and air
# =============================================================================

func _can_jump_now() -> bool:
	if fighter.is_dead() or fighter.is_frozen():
		return false
	if fighter.get_state() != RagdollController.State.ANIMATED:
		return false
	var c := fighter.combat
	if c == null:
		return true
	if fighter.carry.is_held() or c.is_stunned():
		return false  # holding a body jumps at full height (the body comes along)
	return c.is_charging() or not c.is_attacking()

## Take-off: horizontal velocity kept exactly; height 1.2 m standing to 1.5 m
## at full speed (by sprint_charge) under Tuning.PLAYER_GRAVITY rising.
func _do_jump(emit := true) -> void:
	if fighter.is_crouching():
		fighter.set_crouch_input(false)
	var h := lerpf(Tuning.JUMP_HEIGHT, Tuning.JUMP_HEIGHT_SPRINT, sprint_charge)
	var hv := _free_hv
	if _mode == Mode.GROUND and _land_left > 0.0 and _land_kind == &"roll":
		hv = _roll_vel
	_land_left = 0.0
	_land_kind = &""
	_burst_left = 0.0
	_bleed_left = 0.0
	_charge_steer = false
	_enter_air(true)
	_air_speed = hv.length()
	_free_hv = hv
	fighter.velocity = Vector3(hv.x, sqrt(2.0 * Tuning.PLAYER_GRAVITY * h), hv.z)
	_jump_buffer_until = -INF
	_coyote_until = -INF
	if emit:
		GameEvents.jumped.emit(fighter)

func _enter_air(jumped: bool) -> void:
	_mode = Mode.AIR
	_jumping = jumped
	_air_top = fighter.global_position.y
	_air_floor = fighter.global_position.y
	_air_speed = Vector3(_free_hv.x, 0.0, _free_hv.z).length()
	_burst_left = 0.0
	_bleed_left = 0.0

func _tick_air(pdt: float, factor: float, now: float) -> void:
	var hv := Vector3(fighter.velocity.x, 0.0, fighter.velocity.z)
	if _air_dash_left > 0.0 and not _drop_strike:
		_tick_air_dash(pdt, factor, now)
		return
	_air_dash_left = 0.0
	var forced := _forced_velocity(pdt)
	if forced != Vector3.INF:
		hv = forced
	elif not _drop_strike:
		# Jump steering: the stick steers at half the walk acceleration and never
		# past the take-off speed (or half walking speed for a standing hop). A
		# held direction keeps a sprint jump's speed; no stick keeps the momentum.
		var stick := _stick()
		if stick.length() > STICK_DEADZONE:
			var cap := maxf(_air_speed, Tuning.WALK_SPEED * Tuning.JUMP_AIR_STEER)
			var desired := stick.normalized() * cap * minf(stick.length(), 1.0)
			hv = hv.move_toward(desired, Fighter.ACCEL * Tuning.JUMP_AIR_STEER * pdt)
	if forced == Vector3.INF:
		_free_hv = hv
		if hv.length_squared() > 1e-4:
			_heading = hv.normalized()
	if _jumping and not _drop_strike and _try_air_mantle(hv):
		return
	if not _drop_strike and fighter.velocity.y <= 0.5 and forced == Vector3.INF \
			and hv.length() >= STEP_MIN_SPEED and _height_above_floor() <= AIR_PARKOUR_HEIGHT \
			and _try_parkour(hv, pdt):
		return
	var g := _gravity_step(fighter.velocity.y, pdt)
	var vy_before := g.y
	_apply_move(hv, g.x, g.y, factor)
	_push_bodies(hv)
	# Dropping off a table or a step's edge into the next low edge: step onto it.
	if not _drop_strike and forced == Vector3.INF and vy_before <= 0.5 \
			and _height_above_floor() <= AIR_PARKOUR_HEIGHT and _contact_step(hv):
		return
	_air_top = maxf(_air_top, fighter.global_position.y)
	_update_facing(pdt)
	if fighter.is_on_floor() and vy_before <= 0.0:
		_land(-vy_before, now)

func _tick_air_dash(pdt: float, factor: float, now: float) -> void:
	var t := _air_dash_time - _air_dash_left
	_air_dash_left = maxf(_air_dash_left - pdt, 0.0)
	var k := clampf((t + pdt * 0.5) / _air_dash_time, 0.0, 1.0)
	var v := _air_dash_end + (_air_dash_peak - _air_dash_end) * cos(k * PI * 0.5)
	var hv := _heading * v
	_free_hv = _heading * _air_dash_end  # the burst is not earned speed
	_apply_move(hv, 0.0, 0.0, factor)
	_air_top = maxf(_air_top, fighter.global_position.y)
	_update_facing(pdt)
	if _air_dash_left <= 0.0:
		fighter.velocity = Vector3(hv.x, 0.0, hv.z).limit_length(maxf(_air_dash_end, 0.01))
	if fighter.is_on_floor():
		_air_dash_left = 0.0
		_land(0.0, now)

## Exact constant-acceleration step with the gravity switch at the apex
## (9.8 rising, x1.6 falling), so jump heights and landing speeds do not depend
## on the tick rate. Returns (average vy over the step, vy at the end).
func _gravity_step(vy: float, dt: float) -> Vector2:
	var g := Tuning.PLAYER_GRAVITY
	var gf := g * Tuning.FALL_GRAVITY_MULT
	var dy := 0.0
	var v := vy
	var t := dt
	if v > 0.0:
		var t_up := minf(t, v / g)
		dy += v * t_up - 0.5 * g * t_up * t_up
		v -= g * t_up
		t -= t_up
	if t > 0.0:
		dy += v * t - 0.5 * gf * t * t
		v -= gf * t
	return Vector2(dy / dt, v)

## Landing levels by vertical speed (or any slam). The player never falls over.
func _land(vertical_speed: float, now: float) -> void:
	var pos := fighter.global_position
	var hv := _free_hv
	var struck := _drop_strike  # a dropping strike thrown at speed: no sprint carries on
	# Any slam is heavy, whatever the height: a ground slam (dropping strike from
	# Tuning.SLAM_MIN_HEIGHT up) or G's body slam (carry.is_slamming()).
	var slam := (_drop_strike and _slam) or _carry_slamming()
	_mode = Mode.GROUND
	_jumping = false
	_drop_strike = false
	_drop_sprint = false
	_slam = false
	_hang_attack = false
	_touch_floor()
	var level: StringName = &"soft"
	if slam or vertical_speed > Tuning.LAND_HEAVY_SPEED:
		level = &"heavy"
	elif vertical_speed >= Tuning.LAND_HARD_SPEED:
		level = &"hard"
	last_landing = level
	last_landing_speed = vertical_speed
	fighter.velocity.y = 0.0
	var stick := _stick()
	var held_dir := stick.length() > STICK_DEADZONE or _dash_held
	match level:
		&"heavy":
			if held_dir:
				var keep := maxf(hv.length() * Tuning.LAND_ROLL_KEEP, Tuning.WALK_SPEED)
				var roll_dir := stick.normalized() if stick.length() > STICK_DEADZONE else _heading
				_roll_vel = roll_dir * keep
				_heading = roll_dir
				fighter.velocity = Vector3(_roll_vel.x, 0.0, _roll_vel.z)
				_free_hv = _roll_vel
				_land_kind = &"roll"
				_land_left = LAND_ROLL_TIME
				_play_timed(&"land_roll", LAND_ROLL_TIME)
			else:
				_land_kind = &"three_point"
				_land_left = Tuning.LAND_HEAVY_TIME
				_play_timed(&"land_three_point", Tuning.LAND_HEAVY_TIME)
		&"hard":
			_land_kind = &"crouch"
			_land_left = Tuning.LAND_HARD_CROUCH
			_play_timed(&"land_crouch", Tuning.LAND_HARD_CROUCH)
	GameEvents.landing.emit(fighter, level, pos, vertical_speed)
	GameEvents.landed.emit(fighter)
	if level == &"heavy":
		_shockwave(pos)
	# Running on: a held Dash keeps the sprint at the kept speed; otherwise a
	# fast landing bleeds back to walking.
	var run := hv.length()
	if _land_kind == &"roll":
		run = _roll_vel.length()
	elif _land_kind == &"three_point":
		run = 0.0
	if _charge_steer:
		_charge_speed = minf(run, get_speed_cap())  # a charge carried through the air runs on
	if struck:
		# Like any sprint strike: the landing keeps its own motion (a roll's 85%),
		# then the speed bleeds back to walking and a held Dash builds again.
		_end_sprint_state()
		if _land_kind != &"three_point" and _land_kind != &"roll":
			_start_bleed(run)
	elif _dash_held and run >= _sprint_floor():
		_speed = run
		if _land_kind != &"roll" and hv.length_squared() > 1e-4:
			_heading = hv.normalized()
		_set_sprinting(true)
	else:
		_set_sprinting(false)
		if _land_kind != &"three_point" and _land_kind != &"roll":
			_start_bleed(run)
	if now <= _jump_buffer_until and _can_jump_now():
		_do_jump()

## Heavy landing: enemies within Tuning.SHOCK_STUMBLE_RADIUS stumble, within
## Tuning.SHOCK_KNOCKDOWN_RADIUS they are knocked down (preset-tier hits).
func _shockwave(pos: Vector3) -> void:
	GameEvents.shockwave.emit(fighter, pos, Tuning.SHOCK_STUMBLE_RADIUS, Tuning.SHOCK_KNOCKDOWN_RADIUS)
	for f in Targeting.opponents_of(fighter):
		if f.is_down():
			continue
		var to := f.get_ground_position() - pos
		to.y = 0.0
		var d := to.length()
		if d > Tuning.SHOCK_STUMBLE_RADIUS:
			continue
		var tier := HitInfo.Tier.KNOCKDOWN if d <= Tuning.SHOCK_KNOCKDOWN_RADIUS else HitInfo.Tier.STUMBLE
		var dir := to / d if d > 0.01 else fighter.get_forward()
		var bone := _near_leg(f, dir) if tier == HitInfo.Tier.STUMBLE else Bones.HIPS
		var info := _preset_hit(f, &"slam_shockwave", &"shockwave", tier, dir, bone)
		f.take_hit(info)

func _tick_hang(pdt: float, factor: float, now: float) -> void:
	if now >= _hang_until:
		_end_hang(false)
		_tick_air(pdt, factor, now)
		return
	if fighter.combat != null and fighter.combat.is_attacking() and _committed:
		_end_hang(true)
		_tick_air(pdt, factor, now)
		return
	fighter.velocity = Vector3.ZERO
	_free_hv = Vector3.ZERO
	_update_facing(pdt)

func _end_hang(by_attack: bool) -> void:
	if _mode != Mode.HANG:
		return
	_mode = Mode.AIR
	_jumping = false
	_air_top = fighter.global_position.y
	_air_speed = 0.0
	_hang_attack = by_attack

## m between the feet and the floor below (INF over nothing).
func _height_above_floor() -> float:
	var from := fighter.global_position + Vector3.UP * 0.05
	var hit := _cast_ray(from, from + Vector3.DOWN * 30.0, Layers.WORLD | Layers.DESTRUCTIBLE)
	if hit.is_empty():
		return INF
	return from.y - 0.05 - (hit["position"] as Vector3).y

# =============================================================================
# Automatic parkour
# =============================================================================

## Probe forward and start a step, vault, mantle or wall kick-off when one is
## due this tick. true = the capsule now follows a parkour curve.
func _try_parkour(hv: Vector3, _pdt: float) -> bool:
	var speed := hv.length()
	if speed < STEP_MIN_SPEED or fighter.is_crouching():
		return false
	var c := fighter.combat
	# Only a committed strike (or being held) blocks parkour. A charge (a strike
	# or a throw) is not busy: a sprinting charge "can't stop", and the player
	# never presses a button to get over something; it runs on through the curve.
	var charging := _charge_steer or _carry_charging() or (c != null and c.is_charging())
	var busy := (fighter.carry != null and fighter.carry.is_held()) \
		or (c != null and c.is_attacking() and not charging)
	var dir := hv / speed
	var feet := fighter.global_position
	var hs := fighter.get_height_scale()
	var probe_len := _radius() + Tuning.PARKOUR_PROBE_AHEAD * maxf(1.0, speed / Tuning.SPRINT_START_SPEED)
	# The three forward probes (knee, chest, head). The obstacle's face is the
	# nearest static geometry any of them meets (a lower probe wins a tie):
	# through a hole in the platform's skirt, or under its deck with the skirt
	# gone, only the head probe meets the deck's edge. The others find bodies
	# over or behind it and overhangs above it.
	var knee := _probe(0, feet + Vector3.UP * Tuning.PARKOUR_PROBE_HEIGHTS[0] * hs, dir, probe_len)
	var chest := _probe(1, feet + Vector3.UP * Tuning.PARKOUR_PROBE_HEIGHTS[1] * hs, dir, probe_len)
	var head := _probe(2, feet + Vector3.UP * Tuning.PARKOUR_PROBE_HEIGHTS[2] * hs, dir, probe_len)
	var base := _nearest_obstacle([knee, chest, head])
	if base.is_empty():
		return false
	var face: float = base["dist"]
	for pr: Dictionary in [knee, chest, head]:
		if _probe_body(pr) <= face + 0.05:
			return false  # a body in front of the obstacle is a target, not an obstacle
	var body := minf(_probe_body(chest), _probe_body(head))
	var n: Vector3 = base["normal"]
	var incidence := dir.dot(-n)
	if incidence < VAULT_INCIDENCE:
		return false  # glancing: the capsule slides along it
	# The top is looked for under the lowest probe that passes clear over the
	# face (a beam or a window head above a low wall is not its top).
	# A start that lands inside the obstacle (the probe only grazed it) falls
	# back to the next one up.
	# Only probes above the one that found the face count: one below it passing
	# clear went into a hollow (under the platform's deck), not over the top.
	var bi: int = base["idx"]
	var starts: Array[float] = []
	if bi < 1 and (chest.is_empty() or float(chest["dist"]) > face + 0.1):
		starts.append(feet.y + Tuning.PARKOUR_PROBE_HEIGHTS[1] * hs - PROBE_RADIUS)
	if bi < 2 and (head.is_empty() or float(head["dist"]) > face + 0.1):
		starts.append(feet.y + Tuning.PARKOUR_PROBE_HEIGHTS[2] * hs - PROBE_RADIUS)
	starts.append(NAN)  # from TOP_RAY_FROM
	var top_y := NAN
	for from_h in starts:
		top_y = _find_top(base["point"], -(base["normal"] as Vector3), feet.y, from_h)
		if is_nan(from_h) or is_nan(top_y) or top_y < from_h - 0.01:
			break  # found under the start (or nothing): done
	# Clutter (K's furniture) is judged as a whole by its box: a chair's seat
	# is not its top (the back is), and it ends where the box ends.
	var far_hint := NAN
	var box := _clutter_box(base["collider"], feet, dir)
	if not box.is_empty():
		top_y = float(box["top"]) if is_nan(top_y) else maxf(top_y, float(box["top"]))
		far_hint = float(box["exit"])
	if is_nan(top_y):
		return false
	var height := top_y - feet.y
	if height < OBSTACLE_MIN:
		return false
	var holding := fighter.carry != null and fighter.carry.is_holding()
	var vault_max := Tuning.VAULT_MAX
	if holding:
		vault_max = minf(vault_max, fighter.carry.get_vault_max_height())
	var cap := get_speed_cap()
	# Sprinting / full speed read the earned speed: a dash's opening burst runs
	# at the cap but is not a sprint (no mantle, no kick-off off a dash tap).
	var earned := _earned_speed()
	var sprinting := _sprinting or _charge_steer or earned >= _sprint_floor()
	var r := _radius()
	if height <= Tuning.STEP_MAX:
		# Something taller packed right behind it (a coffee table against a
		# sofa): one vault over both, not a step into the next one's face.
		if speed >= Tuning.PARKOUR_MIN_SPEED and not busy:
			var step_far := far_hint if not is_nan(far_hint) else _find_far_edge(feet, dir, face, top_y, face + 1.2)
			if not is_nan(step_far):
				var chain := _chain_far(feet, dir, step_far, top_y, vault_max)
				if chain.y - feet.y > Tuning.STEP_MAX:
					return _plan_vault(feet, dir, face, chain.y, speed, cap, probe_len, body, chest, head, step_far)
		if body <= face + 2.0 * r + 0.1 or _probe_overhang(chest, top_y + 1.0, face + 2.0 * r):
			return false  # someone standing right there, or no headroom over the step
		return _plan_step(feet, dir, face, top_y, speed)
	if busy or speed < Tuning.PARKOUR_MIN_SPEED:
		return false
	if height <= vault_max:
		return _plan_vault(feet, dir, face, top_y, speed, cap, probe_len, body, chest, head, far_hint)
	if holding:
		return false  # carrying: anything over the vault limit is a wall
	if height <= Tuning.MANTLE_MAX:
		if not sprinting:
			return false  # walking into it: it's a wall
		if body <= face + 2.0 * r + 0.3 or _probe_overhang(head, top_y, face + 2.0 * r + 0.3):
			return false  # a body on the ledge is a target; no room under an overhang
		return _plan_mantle(feet, dir, face, top_y, speed)
	if earned >= cap * KICKOFF_SPEED_SHARE and incidence >= KICKOFF_INCIDENCE:
		if body <= face + 0.2:
			return false
		return _plan_kickoff(feet, dir, n, face, speed)
	return false

## Step over (under Tuning.STEP_MAX): lift the capsule onto it, no animation, 100% speed.
func _plan_step(feet: Vector3, dir: Vector3, face: float, top_y: float, speed: float) -> bool:
	var r := _radius()
	var lead := speed * 0.1  # start lifting ~0.1 s before the capsule meets the face
	if face - r > lead + 0.02:
		return false
	var travel := maxf(face - r, 0.0) + 0.15
	var end := feet + dir * travel
	end.y = top_y + 0.01
	if not _capsule_free(end + Vector3.UP * 0.03):
		return false
	var dur := maxf(travel / speed, 2.0 / 120.0)
	var lift_at := clampf((face - r) / travel, 0.35, 0.9)
	var mid := feet + dir * (travel * lift_at)
	mid.y = top_y + 0.01
	_start_parkour(&"step", dur, [feet, mid, end], [0.0, lift_at, 1.0], dir * speed, false,
		top_y - feet.y, dir, false)
	_set_profile(speed, speed, dur, travel)  # 100%: the step never slows the run
	return true

## Speed vault (Tuning.STEP_MAX .. VAULT_MAX): 0.25-0.35 s (shorter when faster),
## keeps Tuning.VAULT_KEEP. Over a thin obstacle to the far side, or up onto a
## deep one.
func _plan_vault(feet: Vector3, dir: Vector3, face: float, top_y: float, speed: float,
		cap: float, probe_len: float, body := INF, chest := {}, head := {}, far_hint := NAN) -> bool:
	var r := _radius()
	var span := maxf(cap - Tuning.PARKOUR_MIN_SPEED, 0.1)
	var dur := lerpf(Tuning.VAULT_TIME.y, Tuning.VAULT_TIME.x,
		clampf((speed - Tuning.PARKOUR_MIN_SPEED) / span, 0.0, 1.0))
	var keep := speed * Tuning.VAULT_KEEP
	var travel := 0.5 * (speed + keep) * dur
	var far := far_hint if not is_nan(far_hint) else _find_far_edge(feet, dir, face, top_y, face + travel + 0.6)
	var deep := is_nan(far)
	if not deep:
		# Low obstacles packed behind it go in the same vault (it clears the
		# tallest and lands past the last), instead of a landing on top of them.
		var chain := _chain_far(feet, dir, far, top_y, Tuning.VAULT_MAX)
		far = chain.x
		top_y = chain.y
	var depth := 0.0 if deep else far - face
	var trigger := r + 0.2 if deep else clampf(0.5 * travel - 0.5 * depth, r + 0.05, probe_len)
	if face > trigger + speed / 120.0 * 1.5:
		return false  # not yet: start so the hands land on top mid-vault
	# A body on (or in front of) the obstacle is a target: never vault it. A
	# body behind it is planned around below.
	if body <= (face + r + 0.3 if deep else far) + 0.05:
		return false
	var clear_to := (face + r + 0.3) if deep else (far + r + 0.1)
	if _probe_overhang(chest, top_y, clear_to) or _probe_overhang(head, top_y, clear_to):
		return false  # something above the way across
	var height := top_y - feet.y
	var clear_y := top_y + VAULT_CLEAR
	var end: Vector3
	var exit_air := false
	var on_top := deep
	if deep:
		travel = maxf(travel, face + r + 0.2)
		end = feet + dir * travel
		end.y = top_y + 0.01
		if not _capsule_free(end + Vector3.UP * 0.03):
			return false
		last_vault_landing = &"top"
	else:
		var plan := _vault_landing(feet, dir, face, far, maxf(travel, far + r + 0.08), top_y, clear_y)
		if plan.is_empty():
			return false
		end = plan["end"]
		exit_air = plan["air"]
		on_top = plan["kind"] == &"top"
		last_vault_landing = plan["kind"]
	travel = maxf(Vector3(end.x - feet.x, 0.0, end.z - feet.z).dot(dir), face + 0.05)
	var over := feet + dir * clampf(face + 0.5 * maxf(depth, 0.3), 0.0, travel)
	over.y = clear_y
	if not _capsule_free(over, WORLD_MASK):
		return false  # the arc itself hits the world (fighters near the wall do not stop it)
	var flat_end := Vector3(end.x, feet.y, end.z)
	# Horizontal speed eases linearly from the run's speed to Tuning.VAULT_KEEP
	# of it over the vault time; a longer way across (a deep or thick obstacle)
	# goes faster, a shorter one (a landing planned short of a fighter) quicker.
	var path := Vector2(end.x - feet.x, end.z - feet.z).length()
	var nominal := 0.5 * (speed + keep) * dur
	var t_vault := dur if path >= nominal else maxf(2.0 * path / (speed + keep), VAULT_TIME_MIN)
	var vb := 2.0 * path / t_vault - speed
	var p_a := clampf(_profile_p((face - r) / travel, speed, vb, t_vault, path), 0.0, 0.8)
	var p_b := 1.0 if on_top else clampf(_profile_p((face + depth + r) / travel, speed, vb, t_vault, path), p_a + 0.05, 0.97)
	var pts: Array[Vector3] = [feet]
	var keys: Array[float] = [0.0]
	var a := feet.lerp(flat_end, p_a)
	a.y = clear_y
	pts.append(a)
	keys.append(maxf(p_a, 0.05))
	if not on_top:
		var m := feet.lerp(flat_end, 0.5 * (p_a + p_b))
		m.y = clear_y + VAULT_BULGE
		pts.append(m)
		keys.append(0.5 * (maxf(p_a, 0.05) + p_b))
		var b := feet.lerp(flat_end, p_b)
		b.y = clear_y
		pts.append(b)
		keys.append(p_b)
	if keys[keys.size() - 1] < 0.999:
		pts.append(end)
		keys.append(1.0)
	else:
		pts[pts.size() - 1] = end
	_start_parkour(&"vault", t_vault, pts, keys, dir * keep, exit_air, height, dir,
		_sprinting or speed >= _sprint_floor())
	_set_profile(speed, vb, t_vault, path)
	_pk_clear_p = 0.0 if on_top else p_b  # on top: a drop lands there; thin: past the far side
	_play_timed(&"vault_speed", t_vault)
	return true

## Low obstacles packed in a row past `far` (two barrels side by side, a
## railing just behind a planter, a sofa behind a coffee table): the scan goes
## on along `dir` while there is less than a capsule's width of open floor
## between them. Three rays across the capsule's width. Returns (far edge of
## the chain, highest top in it); stops (keeping what it has) at anything
## taller than `max_h` above the feet.
func _chain_far(feet: Vector3, dir: Vector3, far: float, top_y: float, max_h: float) -> Vector2:
	var r := _radius()
	var side := dir.cross(Vector3.UP).normalized()
	var last := far
	var top := top_y
	var d := far + CHAIN_STEP
	while d <= far + CHAIN_MAX:
		var hit_top := -INF
		for off: float in [0.0, -r * 0.8, r * 0.8]:
			var x := feet + dir * d + side * off
			var h := _cast_ray(Vector3(x.x, feet.y + max_h + 0.3, x.z), Vector3(x.x, feet.y - 0.1, x.z),
				Layers.WORLD | Layers.DESTRUCTIBLE)
			if not h.is_empty() and WorldTags.is_obstacle(h["collider"]):
				hit_top = maxf(hit_top, (h["position"] as Vector3).y)
		if hit_top > feet.y + max_h + 0.25:
			break  # something tall: not part of a low chain
		if hit_top > feet.y + OBSTACLE_MIN:
			last = d
			top = maxf(top, hit_top)
		elif d - last > 2.0 * r + 0.1:
			break  # open floor wide enough to land on
		d += CHAIN_STEP
	return Vector2(last + CHAIN_STEP * 0.5 if last > far else far, top)

## Where a vault over a thin obstacle lands. Never a dead stop for a fighter
## standing behind it: the planned spot, else a shorter landing, else one to
## the side of them, else on the obstacle's top (the run then drops off its far
## edge in front of them), else the shortest landing for the world alone (a
## capsule overlap the Battering Ram / contact rules then resolve).
## {} only when the world itself leaves no room. Returns end, air, kind.
func _vault_landing(feet: Vector3, dir: Vector3, face: float, far: float, travel: float,
		top_y: float, clear_y: float) -> Dictionary:
	var r := _radius()
	var short := far + r + 0.08
	var side := dir.cross(Vector3.UP).normalized()
	var tries: Array = []  # [distance along dir, sideways offset, kind]
	tries.append([travel, 0.0, &"planned"])
	var d := travel - VAULT_LAND_STEP
	while d > short:
		tries.append([d, 0.0, &"short"])
		d -= VAULT_LAND_STEP
	tries.append([short, 0.0, &"short"])
	for off: float in VAULT_SIDE_OFFSETS:
		tries.append([short, off, &"side"])
		tries.append([travel, off, &"side"])
	for t: Array in tries:
		var spot := _vault_spot(feet, dir, side, float(t[0]), float(t[1]), clear_y)
		if not spot.is_empty() and _capsule_free((spot["end"] as Vector3) + Vector3.UP * 0.03):
			if float(t[1]) != 0.0 and not _capsule_free(feet + dir * face + side * float(t[1]) * 0.5
					+ Vector3.UP * (clear_y - feet.y), WORLD_MASK):
				continue  # the way across to the side is blocked (a pillar, the wall's end)
			spot["kind"] = t[2]
			return spot
	# On the obstacle's top, centred over it.
	var top := feet + dir * (face + 0.5 * (far - face))
	top.y = top_y + 0.01
	if _capsule_free(top + Vector3.UP * 0.03):
		return {"end": top, "air": false, "kind": &"top"}
	var last := _vault_spot(feet, dir, side, short, 0.0, clear_y)
	if not last.is_empty() and _capsule_free((last["end"] as Vector3) + Vector3.UP * 0.03, WORLD_MASK):
		last["kind"] = &"overlap"
		return last
	return {}

## A landing `along` m ahead and `off` m to the side: on the floor there, or in
## the air above a drop. {} when there is no floor and no drop to fall into.
func _vault_spot(feet: Vector3, dir: Vector3, side: Vector3, along: float, off: float,
		clear_y: float) -> Dictionary:
	var end := feet + dir * along + side * off
	var floor_y := _floor_y_at(end, clear_y + 0.3)
	if is_nan(floor_y) or floor_y < feet.y - VAULT_DROP_MAX:
		end.y = feet.y  # a drop beyond: the vault ends in the air
		return {"end": end, "air": true}
	end.y = floor_y + 0.01
	return {"end": end, "air": false}

## Wall kick and mantle (VAULT_MAX .. MANTLE_MAX, sprinting): one foot on the
## wall, then hands, then up; Tuning.MANTLE_TIME, keeps Tuning.MANTLE_KEEP.
func _plan_mantle(feet: Vector3, dir: Vector3, face: float, top_y: float, speed: float) -> bool:
	var r := _radius()
	if face > r + 0.3 + speed / 120.0 * 1.5:
		return false
	var far := _find_far_edge(feet, dir, face, top_y, face + 2.0 * r + 0.6)
	var on_top := is_nan(far) or far - face >= 2.0 * r + 0.1
	var keep := speed * Tuning.MANTLE_KEEP
	var clear_y := top_y + VAULT_CLEAR
	var x1 := maxf(face - r - 0.02, 0.0)
	var end: Vector3
	var exit_air := false
	if on_top:
		end = feet + dir * (face + r + 0.2)
		end.y = top_y + 0.01
	else:
		# Thin: over it and down the far side, a little further on when the
		# capsule would clip it (crossed at an angle, a shelf's end).
		exit_air = true
		var fits := false
		for k in 4:
			end = feet + dir * (far + r + 0.08 + 0.15 * k)
			end.y = clear_y
			if _capsule_free(end + Vector3.UP * 0.03):
				fits = true
				break
		if not fits:
			return false
	if not _capsule_free(end + Vector3.UP * 0.03):
		return false
	var foot := feet + dir * (x1 * 0.8)
	foot.y = feet.y + (top_y - feet.y) * 0.4
	var hands := feet + dir * x1
	hands.y = clear_y
	var pts: Array[Vector3] = [feet, foot, hands, end]
	var keys: Array[float] = [0.0, 0.3, 0.6, 1.0]
	var exit_v := dir * keep
	_start_parkour(&"mantle", Tuning.MANTLE_TIME, pts, keys, exit_v, exit_air, top_y - feet.y, dir, true)
	_play_timed(&"mantle", Tuning.MANTLE_TIME)
	return true

## Over MANTLE_MAX at full speed: a single wall kick-off that turns up to
## Tuning.KICKOFF_TURN degrees, keeping Tuning.KICKOFF_KEEP, in Tuning.KICKOFF_TIME.
func _plan_kickoff(feet: Vector3, dir: Vector3, n: Vector3, face: float, speed: float) -> bool:
	var r := _radius()
	if face > r + 0.2 + speed / 120.0 * 1.5:
		return false
	var out := _kickoff_dir(dir, n)
	var x1 := maxf(face - r - 0.02, 0.0)
	var plant := feet + dir * x1 + Vector3.UP * (KICKOFF_RISE * 0.6)
	var end := feet + dir * x1 + out * 0.25 + Vector3.UP * KICKOFF_RISE
	if not _capsule_free(end + Vector3.UP * 0.02):
		return false
	var vy := sqrt(2.0 * Tuning.PLAYER_GRAVITY * KICKOFF_HOP)
	var exit_v := out * speed * Tuning.KICKOFF_KEEP + Vector3.UP * vy
	_start_parkour(&"kickoff", Tuning.KICKOFF_TIME, [feet, plant, end], [0.0, 0.45, 1.0], exit_v,
		true, INF, out, true)
	_play_timed(&"wall_kickoff", Tuning.KICKOFF_TIME)
	return true

## The reflection off the wall, turned at most Tuning.KICKOFF_TURN from the run.
## Head-on, the stick picks the side (right by default).
func _kickoff_dir(dir: Vector3, n: Vector3) -> Vector3:
	var nf := Vector3(n.x, 0.0, n.z).normalized()
	var refl := dir - 2.0 * dir.dot(nf) * nf
	refl.y = 0.0
	var a := atan2(-dir.x, -dir.z)
	var b := atan2(-refl.x, -refl.z)
	var turn := angle_difference(a, b)
	var max_turn := deg_to_rad(Tuning.KICKOFF_TURN)
	if absf(turn) > max_turn - 1e-3:
		var sgn := signf(turn)
		if absf(absf(turn) - PI) < deg_to_rad(10.0):
			var tangent := nf.cross(Vector3.UP)
			var s := _stick()
			sgn = -1.0 if s.dot(tangent) > 0.0 else 1.0
		turn = sgn * max_turn
	var c := a + turn
	return Vector3(-sin(c), 0.0, -cos(c))

## In the air: hands within Tuning.AIR_MANTLE_REACH of a ledge top → mantle up.
func _try_air_mantle(hv: Vector3) -> bool:
	var dir := hv
	var stick := _stick()
	if dir.length() < MOVING_SPEED and stick.length() > STICK_DEADZONE:
		dir = stick
	if dir.length_squared() < 1e-4:
		return false
	dir = dir.normalized()
	var r := _radius()
	var feet := fighter.global_position
	var hs := fighter.get_height_scale()
	var probes: Array = []
	for i in 3:
		probes.append(_probe(i, feet + Vector3.UP * Tuning.PARKOUR_PROBE_HEIGHTS[i] * hs, dir, r + 0.5))
	var hit := _nearest_obstacle(probes)
	if hit.is_empty():
		return false
	for pr: Dictionary in probes:
		if _probe_body(pr) <= float(hit["dist"]) + 0.05:
			return false  # a body in the way
	var n: Vector3 = hit["normal"]
	if dir.dot(-n) < VAULT_INCIDENCE:
		return false
	var hands := feet.y + AIR_HAND_HEIGHT * hs
	var top_y := _find_top(hit["point"], -(hit["normal"] as Vector3), feet.y, hands + Tuning.AIR_MANTLE_REACH + 0.3)
	if is_nan(top_y) or top_y > hands + Tuning.AIR_MANTLE_REACH or top_y < feet.y + 0.2:
		return false
	if top_y > _air_floor + AIR_MANTLE_MAX:
		return false
	if fighter.carry != null and fighter.carry.is_holding() \
			and top_y - feet.y > fighter.carry.get_vault_max_height():
		return false
	var face: float = hit["dist"]
	var far := _find_far_edge(feet, dir, face, top_y, face + 2.0 * r + 0.6)
	if not is_nan(far) and far - face < 2.0 * r + 0.1:
		return false  # too thin to stand on
	var end := feet + dir * (face + r + 0.15)
	end.y = top_y + 0.01
	if not _capsule_free(end + Vector3.UP * 0.03):
		return false
	var hands_pt := feet + dir * maxf(face - r - 0.02, 0.0)
	hands_pt.y = top_y + VAULT_CLEAR
	var speed := hv.length()
	var keep := maxf(speed * Tuning.MANTLE_KEEP, Tuning.WALK_SPEED * 0.5)
	_start_parkour(&"air_mantle", AIR_MANTLE_TIME, [feet, hands_pt, end], [0.0, 0.55, 1.0],
		dir * keep, false, top_y - feet.y, dir, _sprinting)
	_play_timed(&"mantle", AIR_MANTLE_TIME)
	return true

func _start_parkour(kind: StringName, dur: float, pts: Array, keys: Array, exit_vel: Vector3,
		exit_air: bool, height: float, face_dir: Vector3, sprint: bool) -> void:
	_finish_parkour_tween()
	_mode = Mode.PARKOUR
	_pk_kind = kind
	_pk_p = 0.0
	_pk_pts.clear()
	for p in pts:
		_pk_pts.append(p)
	_pk_keys.clear()
	for k in keys:
		_pk_keys.append(float(k))
	_pk_start = _pk_pts[0]
	_pk_face = face_dir
	_pk_exit_vel = exit_vel
	_pk_exit_air = exit_air
	_pk_sprint = sprint
	_burst_left = 0.0
	_bleed_left = 0.0
	_land_left = 0.0
	last_parkour = kind
	# Driven by a Tween stepped by hand (custom_step) in player time, so it
	# stops in hitstop and keeps real speed in slow motion.
	_pk_tween = create_tween()
	_pk_tween.tween_method(_set_pk_progress, 0.0, 1.0, dur)
	_pk_tween.pause()
	_pk_posed = false
	_pk_clear_p = 0.0
	_pk_drop_queued = false
	_pk_profile = false
	GameEvents.parkour.emit(fighter, kind, fighter.global_position, height if height != INF else -1.0)

func _set_pk_progress(p: float) -> void:
	_pk_p = p

## Leave the vault curve here as a dropping strike: the vault's kept speed
## forward, plunging at DROP_STRIKE_SPEED.
func _vault_to_drop() -> void:
	var keep := _pk_exit_vel
	var pos := fighter.global_position
	_pk_drop_queued = false
	_finish_parkour_tween()
	_mode = Mode.AIR
	_jumping = false
	_air_top = pos.y
	_air_floor = pos.y
	_air_speed = Vector3(keep.x, 0.0, keep.z).length()
	fighter.velocity = Vector3(keep.x, -DROP_STRIKE_SPEED, keep.z)
	_free_hv = Vector3(keep.x, 0.0, keep.z)
	_drop_strike = true
	_slam = _height_above_floor() >= Tuning.SLAM_MIN_HEIGHT

func _tick_parkour(pdt: float) -> void:
	var still := false
	if _pk_tween != null and _pk_tween.is_valid():
		still = _pk_tween.custom_step(pdt)
	else:
		_pk_p = 1.0
	if not still:
		_pk_p = 1.0
	var target := _pk_point(_pk_p)
	# The pose follows the curve's progress, not its own clock (P: set_move_progress).
	if _pk_posed and fighter.animator != null and fighter.animator.has_method(&"set_move_progress"):
		fighter.animator.call(&"set_move_progress", _pk_p)
	var prev := fighter.global_position
	fighter.global_position = target
	var v := (target - prev) / pdt
	fighter.velocity = v
	_free_hv = _pk_exit_vel
	_free_hv.y = 0.0
	_face_now(_pk_face, pdt)
	if _pk_drop_queued and _pk_p >= _pk_clear_p and _pk_p < 1.0:
		_vault_to_drop()
		return
	if _pk_p >= 1.0:
		_end_parkour()

## Position on the curve: Catmull-Rom through the keys (progress-parametrised).
func _pk_point(p: float) -> Vector3:
	var n := _pk_pts.size()
	if n == 0:
		return fighter.global_position
	if p <= 0.0:
		return _pk_pts[0]
	if p >= 1.0:
		return _pk_pts[n - 1]
	var i := 0
	while i < n - 2 and p > _pk_keys[i + 1]:
		i += 1
	var k0 := _pk_keys[i]
	var k1 := _pk_keys[i + 1]
	var t := clampf((p - k0) / maxf(k1 - k0, 1e-4), 0.0, 1.0)
	var p0 := _pk_pts[maxi(i - 1, 0)]
	var p1 := _pk_pts[i]
	var p2 := _pk_pts[i + 1]
	var p3 := _pk_pts[mini(i + 2, n - 1)]
	var pos := p1.cubic_interpolate(p2, p0, p3, t)
	# Never dip under the straight line between two keys that both clear an
	# obstacle (Catmull-Rom can sag between equal-height keys).
	pos.y = maxf(pos.y, minf(p1.y, p2.y)) if p1.y > _pk_start.y + 0.01 and p2.y > _pk_start.y + 0.01 else pos.y
	if _pk_profile:
		# Horizontal from the speed profile, not the keys: unevenly spaced
		# Catmull-Rom keys swing the speed (a table vault read 4.5..11 m/s).
		var f := _profile_s(p, _pk_va, _pk_vb, _pk_time, _pk_len)
		var e := _pk_pts[n - 1]
		pos.x = lerpf(_pk_start.x, e.x, f)
		pos.z = lerpf(_pk_start.z, e.z, f)
	return pos

## Share of the way covered at progress `p` when the speed runs linearly from
## `va` to `vb` over `t` s along a path `len` m long (va + vb = 2 len / t).
static func _profile_s(p: float, va: float, vb: float, t: float, length: float) -> float:
	if length <= 1e-4:
		return p
	return clampf((va * p + 0.5 * (vb - va) * p * p) * t / length, 0.0, 1.0)

## Inverse of _profile_s: the progress at which `frac` of the way is covered.
static func _profile_p(frac: float, va: float, vb: float, t: float, length: float) -> float:
	if length <= 1e-4 or t <= 0.0:
		return frac
	var a := 0.5 * (vb - va) * t / length
	var b := va * t / length
	if absf(a) < 1e-6:
		return clampf(frac / maxf(b, 1e-4), 0.0, 1.0)
	return clampf((-b + sqrt(maxf(b * b + 4.0 * a * frac, 0.0))) / (2.0 * a), 0.0, 1.0)

func _set_profile(va: float, vb: float, t: float, length: float) -> void:
	_pk_profile = true
	_pk_va = va
	_pk_vb = vb
	_pk_time = t
	_pk_len = length

func _end_parkour() -> void:
	if _pk_drop_queued:
		_vault_to_drop()
		return
	var kind := _pk_kind
	var exit_v := _pk_exit_vel
	var exit_air := _pk_exit_air
	_finish_parkour_tween()
	var hv := Vector3(exit_v.x, 0.0, exit_v.z)
	_free_hv = hv
	if hv.length_squared() > 1e-4:
		_heading = hv.normalized()
	if _charge_steer:
		# A charge held through the curve runs on at the speed the curve kept.
		_charge_speed = minf(hv.length(), get_speed_cap())
	if exit_air:
		_mode = Mode.AIR
		_jumping = kind == &"kickoff"
		_air_top = fighter.global_position.y
		_air_floor = _pk_start.y
		_air_speed = hv.length()
		fighter.velocity = exit_v
		if kind == &"kickoff":
			GameEvents.jumped.emit(fighter)
	else:
		_mode = Mode.GROUND
		fighter.velocity = Vector3(hv.x, 0.0, hv.z)
		var run := hv.length()
		if _dash_held and run >= _sprint_floor():
			_speed = run
			_set_sprinting(true)
		elif run > Tuning.WALK_SPEED:
			_set_sprinting(false)
			_speed = run
			_start_bleed(run)
	if _jump_buffer_until >= TimeDirector.now() and _mode == Mode.GROUND and _can_jump_now():
		_do_jump()

func _finish_parkour_tween() -> void:
	if _pk_tween != null and _pk_tween.is_valid():
		_pk_tween.kill()
	_pk_tween = null
	if _mode == Mode.PARKOUR:
		_mode = Mode.GROUND
	_pk_kind = &""
	_pk_p = 0.0

# =============================================================================
# Wall run
# =============================================================================

## Sprinting (sprint_charge >= Tuning.WALLRUN_MIN_CHARGE) along a runnable wall
## within Tuning.WALLRUN_REACH, heading 10-45 degrees into it, and Jump pressed.
func _try_wall_run() -> bool:
	if _mode != Mode.GROUND and _mode != Mode.AIR:
		return false
	# "You must be sprinting with sprint_charge of at least 0.6."
	if not is_sprinting() or sprint_charge < Tuning.WALLRUN_MIN_CHARGE - 1e-4:
		return false
	if not _can_jump_now() and _mode == Mode.GROUND:
		return false
	var dir := _heading
	var stick := _stick()
	if stick.length() > STICK_DEADZONE:
		dir = stick.normalized()
	var r := _radius()
	var chest := fighter.global_position + Vector3.UP * Tuning.PARKOUR_PROBE_HEIGHTS[1] * fighter.get_height_scale()
	var right := dir.cross(Vector3.UP).normalized()
	var best := {}
	var best_side := 0
	var best_angle := INF
	for side in [-1, 1]:
		var reach := (r + Tuning.WALLRUN_REACH) / cos(deg_to_rad(Tuning.WALLRUN_ANGLE.y)) + 0.1
		var hit := _cast_ray(chest, chest + right * float(side) * reach, Layers.WORLD | Layers.DESTRUCTIBLE)
		if hit.is_empty():
			continue
		var n: Vector3 = hit["normal"]
		if absf(n.y) > Tuning.WALLRUN_NORMAL_Y:
			continue
		var col: Object = hit["collider"]
		if not WorldTags.is_runnable(col) or _wall_used(n, hit["position"]):
			continue
		var gap := (chest - (hit["position"] as Vector3)).dot(n) - r
		if gap > Tuning.WALLRUN_REACH:
			continue
		var into := dir.dot(-n)
		var ang := rad_to_deg(asin(clampf(into, -1.0, 1.0)))
		if ang < Tuning.WALLRUN_ANGLE.x - 1e-3 or ang > Tuning.WALLRUN_ANGLE.y + 1e-3:
			continue
		if ang < best_angle:
			best_angle = ang
			best = hit
			best_side = side
	if best.is_empty():
		return false
	_start_wall_run(best, best_side, dir)
	return true

func _start_wall_run(hit: Dictionary, side: int, dir: Vector3) -> void:
	var n: Vector3 = hit["normal"]
	n.y = 0.0
	n = n.normalized()
	var speed := maxf(_earned_speed(), Tuning.SPRINT_START_SPEED)  # read before the mode changes
	_mode = Mode.WALL_RUN
	_air_dash_left = 0.0
	_air_dashed = false
	_wr_t = 0.0
	_wr_side = side
	_wr_normal = n
	_wr_dir = (dir - n * dir.dot(n)).normalized()
	_wr_speed = speed
	_wr_y0 = fighter.global_position.y
	_wr_wall = hit["collider"]
	_wr_step = 0.0
	_heading = _wr_dir
	_burst_left = 0.0
	_bleed_left = 0.0
	_land_left = 0.0
	_jumping = false
	_drop_strike = false
	_slam = false
	_used_walls.append(_wall_plane(n, hit["position"]))
	GameEvents.wall_run_started.emit(fighter, _wr_wall as Node3D, side)

func _tick_wall_run(pdt: float, factor: float, now: float) -> void:
	_wr_t += pdt
	var r := _radius()
	var chest := fighter.global_position + Vector3.UP * Tuning.PARKOUR_PROBE_HEIGHTS[1] * fighter.get_height_scale()
	var hit := _cast_ray(chest, chest - _wr_normal * (r + Tuning.WALLRUN_REACH + 0.4),
		Layers.WORLD | Layers.DESTRUCTIBLE)
	if hit.is_empty() or not WorldTags.is_runnable(hit["collider"]):
		_end_wall_run(&"end", Tuning.WALLRUN_DROP_KEEP)
		_tick_air(pdt, factor, now)
		return
	var n: Vector3 = hit["normal"]
	if absf(n.y) > Tuning.WALLRUN_NORMAL_Y or Vector3(n.x, 0.0, n.z).normalized().dot(_wr_normal) \
			< cos(deg_to_rad(WALLRUN_NORMAL_TURN)):
		_end_wall_run(&"end", Tuning.WALLRUN_DROP_KEEP)
		_tick_air(pdt, factor, now)
		return
	n.y = 0.0
	_wr_normal = n.normalized()
	_wr_dir = (_wr_dir - _wr_normal * _wr_dir.dot(_wr_normal)).normalized()
	var stick := _stick()
	if stick.length() > STICK_DEADZONE and stick.normalized().dot(_wr_normal) > WALLRUN_STICK_AWAY:
		_end_wall_run(&"stick", Tuning.WALLRUN_DROP_KEEP)
		_tick_air(pdt, factor, now)
		return
	if _wr_t >= Tuning.WALLRUN_TIME:
		_end_wall_run(&"time", Tuning.WALLRUN_DROP_KEEP)
		_tick_air(pdt, factor, now)
		return
	# Something ahead along the wall (a corner, a pillar): the run ends there.
	var ahead := _cast_ray(chest, chest + _wr_dir * (r + _wr_speed * pdt + 0.15), Layers.WORLD | Layers.DESTRUCTIBLE)
	if not ahead.is_empty() and (ahead["normal"] as Vector3).dot(-_wr_dir) > 0.5:
		_end_wall_run(&"end", Tuning.WALLRUN_DROP_KEEP)
		_tick_air(pdt, factor, now)
		return
	var gap := (chest - (hit["position"] as Vector3)).dot(_wr_normal) - r
	var into := clampf(gap / 0.08, WALLRUN_PRESS, WALLRUN_PULL_MAX)
	var hv := _wr_dir * _wr_speed - _wr_normal * into
	var rise_k := minf(_wr_t / Tuning.WALLRUN_RISE_TIME, 1.0)
	var y_target := _wr_y0 + Tuning.WALLRUN_RISE * (1.0 - (1.0 - rise_k) * (1.0 - rise_k))
	var vy := (y_target - fighter.global_position.y) / pdt
	_free_hv = _wr_dir * _wr_speed
	_heading = _wr_dir
	_apply_move(hv, vy, 0.0, factor)
	# The height is the run's, exactly (a capsule leaving the floor against a
	# wall loses part of an upward slide to CharacterBody3D's floor rules).
	fighter.global_position.y = y_target
	fighter.velocity.y = 0.0
	_face_now(_wr_dir, pdt)
	_wr_step += _wr_speed * pdt
	var stride := _stride(_wr_speed)
	if _wr_step >= stride:
		_wr_step -= stride
		var foot := fighter.global_position + Vector3.UP * 0.2 - _wr_normal * r
		GameEvents.wall_run_step.emit(fighter, foot, _wr_normal)

## Loose rigid clutter the capsule ran into this tick (K's LooseProps: chairs,
## drums, cabinets on the DESTRUCTIBLE layer, which capsules collide with) is
## pushed. Walking, it moves along with the walker at M / (M + m) of the pace.
## From Tuning.RUN_THROUGH_SPEED it is sent ahead at up to PUSH_BODY_SHARE of
## the speed into it, the runner keeps M / (M + m) of its speed (a chair costs
## 10%, a drum 30%, a cabinet 44%), and the two ignore each other for
## PUSH_PASS_TIME. true when a run ploughed through something.
func _push_bodies(intended: Vector3) -> bool:
	var keep := 1.0
	var pushed := _crash_through(intended)
	for i in fighter.get_slide_collision_count():
		var col := fighter.get_slide_collision(i)
		var body := col.get_collider() as RigidBody3D
		if body == null or fighter.get_collision_exceptions().has(body):
			continue
		var n := col.get_normal()
		n.y = 0.0
		if n.length_squared() < 1e-4:
			continue
		n = n.normalized()
		var into := intended.dot(-n)
		# Walking into it after the first shove, the velocity is what the
		# contact left: the stick's walk is what the walker is pushing with.
		var walking := into < Tuning.RUN_THROUGH_SPEED
		if walking and _mode == Mode.GROUND:
			into = maxf(into, (_lock_scaled(_stick()) * Tuning.WALK_SPEED * _walk_mult()).dot(-n))
		if into < PUSH_MIN_SPEED:
			continue
		var big_m := fighter.get_total_mass()
		var m := maxf(body.mass, 0.1)
		if body.freeze:
			body.freeze = false
		body.sleeping = false
		var have := body.linear_velocity.dot(-n)
		if walking:
			# Walking: an inelastic shove, the prop and the walker go on together
			# at M / (M + m) of the pace (a cabinet is heavy to push, a chair is not).
			var walk_target := into * big_m / (big_m + m)
			if walk_target > have:
				body.apply_central_impulse(-n * (walk_target - have) * m)
			var cur := Vector3(fighter.velocity.x, 0.0, fighter.velocity.z)
			var along := cur.dot(-n)
			if along < walk_target:
				cur += -n * (walk_target - along)
				fighter.velocity = Vector3(cur.x, fighter.velocity.y, cur.z)
				_free_hv = cur
			continue
		# Running: it flies ahead and the runner ploughs on.
		var target := into * minf(PUSH_BODY_SHARE, 2.0 * big_m / (big_m + m))
		if target > have:
			body.apply_central_impulse((-n * (target - have) + Vector3.UP * 0.15 * target) * m)
		keep = minf(keep, big_m / (big_m + m))
		pushed = true
		_pass_body(body, PUSH_PASS_TIME)
	if pushed:
		var hv := Vector3(intended.x, 0.0, intended.z) * keep
		fighter.velocity = Vector3(hv.x, fighter.velocity.y, hv.z)
		_free_hv = hv
		_speed *= keep
		_charge_speed *= keep
		_air_speed *= keep
	return pushed

## The capsule was stopped by a low edge (its top within Tuning.STEP_MAX of the
## feet): one the knee probe passes over (a railing's top seen from a sofa's
## back, a curb under 0.27 m). Step up onto it now. true when a step started.
func _contact_step(intended: Vector3) -> bool:
	var hv := Vector3(intended.x, 0.0, intended.z)
	var speed := hv.length()
	if speed < STEP_MIN_SPEED or fighter.is_crouching():
		return false
	var actual := Vector3(fighter.velocity.x, 0.0, fighter.velocity.z)
	if actual.length() > speed * 0.95:
		return false  # not held up
	var feet := fighter.global_position
	var dir := hv / speed
	for i in fighter.get_slide_collision_count():
		var col := fighter.get_slide_collision(i)
		var n := col.get_normal()
		if n.y > 0.7 or not WorldTags.is_obstacle(col.get_collider()):
			continue  # a floor, or a body / prop
		var nf := Vector3(n.x, 0.0, n.z)
		if nf.length_squared() < 1e-4 or dir.dot(-nf.normalized()) < VAULT_INCIDENCE:
			continue
		var point := col.get_position()
		if point.y > feet.y + Tuning.STEP_MAX + 0.02:
			continue
		var top_y := _find_top(point, -nf, feet.y, feet.y + Tuning.STEP_MAX + 0.25)
		if is_nan(top_y) or top_y - feet.y < OBSTACLE_MIN or top_y - feet.y > Tuning.STEP_MAX:
			continue
		var face := (Vector3(point.x, feet.y, point.z) - feet).dot(dir)
		if _plan_step(feet, dir, maxf(face, _radius()), top_y, speed):
			# The contact only held this tick up: report the run's own speed.
			fighter.velocity = Vector3(hv.x, fighter.velocity.y, hv.z)
			return true
	return false

## Glass and cardboard (Tuning.RUN_THROUGH_KINDS) the capsule ran into this
## tick at Tuning.RUN_THROUGH_SPEED or more: K's furniture smashes them ahead of
## contact; from an angle its look-ahead can miss, so the contact itself breaks
## them (the breakable contract, at the runner's 1/2 M v^2) and the run keeps
## its velocity: never a dead stop against them. Walking, glass is a wall.
func _crash_through(intended: Vector3) -> bool:
	var hv := Vector3(intended.x, 0.0, intended.z)
	var speed := hv.length()
	if speed < Tuning.RUN_THROUGH_SPEED:
		return false
	var crashed := false
	for i in fighter.get_slide_collision_count():
		var col := fighter.get_slide_collision(i)
		var b := WorldTags.breakable_of(col.get_collider())
		if b == null or not (b.get(&"kind") in Tuning.RUN_THROUGH_KINDS) or bool(b.get(&"is_broken")):
			continue
		var n := col.get_normal()
		n.y = 0.0
		if n.length_squared() > 1e-4 and hv.dot(-n.normalized()) < speed * 0.25:
			continue  # brushing past it, not running into it
		b.set_meta(&"impact_body", fighter)  # the contract: who hit it (furniture_broken credits the runner)
		b.call(&"receive_impact", 0.5 * fighter.get_total_mass() * speed * speed, col.get_position(), hv)
		if bool(b.get(&"is_broken")):
			crashed = true
	if crashed:
		fighter.velocity = Vector3(hv.x, fighter.velocity.y, hv.z)
		_free_hv = hv
	return crashed

## The capsule and `body` ignore each other for `t` s (ids held: either may go first).
func _pass_body(body: PhysicsBody3D, t: float) -> void:
	fighter.add_collision_exception_with(body)
	var me_id := fighter.get_instance_id()
	var b_id := body.get_instance_id()
	TimeDirector.real_timer(t).timeout.connect(func() -> void:
		var me := instance_from_id(me_id) as PhysicsBody3D
		var b := instance_from_id(b_id) as PhysicsBody3D
		if me != null and b != null:
			me.remove_collision_exception_with(b))

## A wall as a plane: (normal x, normal z, offset along the normal).
static func _wall_plane(n: Vector3, point: Vector3) -> Vector3:
	var nf := Vector3(n.x, 0.0, n.z).normalized()
	return Vector3(nf.x, nf.z, nf.dot(Vector3(point.x, 0.0, point.z)))

## The same wall (any panel of it) was run on since the floor was last touched.
func _wall_used(n: Vector3, point: Vector3) -> bool:
	var w := _wall_plane(n, point)
	for u in _used_walls:
		if Vector2(u.x, u.y).dot(Vector2(w.x, w.y)) >= cos(deg_to_rad(WALL_SAME_DEG)) \
				and absf(u.z - w.z) <= WALL_SAME_OFFSET:
			return true
	return false

## Drop off the wall keeping `keep` of the run speed (no vertical speed).
func _end_wall_run(reason: StringName, keep: float) -> void:
	if _mode != Mode.WALL_RUN:
		return
	var hv := _wr_dir * _wr_speed * keep
	_mode = Mode.AIR
	_jumping = false
	_air_top = fighter.global_position.y
	_free_hv = hv
	_air_speed = hv.length()
	fighter.velocity = Vector3(hv.x, 0.0, hv.z)
	GameEvents.wall_run_ended.emit(fighter, reason)

## Jump during the run: kick off at Tuning.WALLRUN_KICK_ANGLE away from the
## wall, keeping 100% speed and adding Tuning.WALLRUN_KICK_HEIGHT.
func _wall_kickoff() -> void:
	var a := deg_to_rad(Tuning.WALLRUN_KICK_ANGLE)
	var dir := (_wr_dir * cos(a) + _wr_normal * sin(a)).normalized()
	var speed := _wr_speed
	_mode = Mode.AIR
	_jumping = true
	_air_top = fighter.global_position.y
	_air_floor = _wr_y0
	_free_hv = dir * speed
	_air_speed = speed
	_heading = dir
	fighter.velocity = dir * speed + Vector3.UP * sqrt(2.0 * Tuning.PLAYER_GRAVITY * Tuning.WALLRUN_KICK_HEIGHT)
	GameEvents.wall_run_ended.emit(fighter, &"jump")
	GameEvents.jumped.emit(fighter)

# =============================================================================
# Battering Ram
# =============================================================================

## At Tuning.RAM_SPEED_SHARE of the cap or more, touching an enemy's capsule
## is a collision (never while a sprint attack's body ignores its target).
func _check_ram(intended: Vector3, pre_speed: float, now: float) -> void:
	if not (_sprinting or _charge_steer or _bleed_left > 0.0):
		return
	var cap := get_speed_cap()
	if pre_speed < cap * Tuning.RAM_SPEED_SHARE - 1e-4:
		return
	var dir := intended.normalized() if intended.length_squared() > 1e-4 else _heading
	var victims: Array[Fighter] = []
	for i in fighter.get_slide_collision_count():
		var col := fighter.get_slide_collision(i)
		var f := col.get_collider() as Fighter
		if f != null and not victims.has(f):
			victims.append(f)
	var r := _radius()
	for f in Targeting.opponents_of(fighter):
		if victims.has(f) or f.is_down() or f.capsule == null or f.capsule.disabled:
			continue
		var to := f.global_position - fighter.global_position
		to.y = 0.0
		var fr := (f.capsule.shape as CapsuleShape3D).radius
		if to.length() <= r + fr + RAM_TOUCH_GAP and to.normalized().dot(dir) >= RAM_FRONT_DOT:
			victims.append(f)
	for f in victims:
		if f.team == fighter.team or f.is_dead() or f.is_down():
			continue
		if fighter.combat != null and fighter.combat.suppresses_ram_with(f):
			continue
		var last: float = _ram_last.get(f.get_instance_id(), -INF)
		if now - last < RAM_REPEAT:
			continue
		var to2 := f.global_position - fighter.global_position
		to2.y = 0.0
		if to2.length_squared() > 1e-6 and to2.normalized().dot(dir) < RAM_FRONT_DOT * 0.5:
			continue
		_ram_last[f.get_instance_id()] = now
		_ram(f, dir)
		if fighter.is_down() or fighter.is_in_hitstun():
			return

func _ram(victim: Fighter, dir: Vector3) -> void:
	var lvl := clampi(Tuning.debug_ram_level, 0, Tuning.RAM_TABLE.size() - 1)
	var row: Dictionary = Tuning.RAM_TABLE[lvl]["heavy" if victim.is_heavy() else "normal"]
	var vres: StringName = row["victim"]
	var sres: StringName = row["self"]
	var loss: float = row["loss"]
	rams += 1
	# The victim is pushed aside (and on): sideways toward the side it stands on.
	var to := victim.global_position - fighter.global_position
	to.y = 0.0
	var side := dir.cross(Vector3.UP).normalized()
	if to.dot(side) < 0.0:
		side = -side
	var push := (dir * (1.0 - RAM_SIDE_SHARE) + side * RAM_SIDE_SHARE).normalized()
	var tier := HitInfo.Tier.FLINCH
	match vres:
		&"stumble":
			tier = HitInfo.Tier.STUMBLE
		&"knockdown":
			tier = HitInfo.Tier.KNOCKDOWN
	var bone := _near_leg(victim, push) if tier == HitInfo.Tier.STUMBLE else Bones.CHEST
	var info := _preset_hit(victim, &"ram", &"ram", tier, push, bone)
	victim.take_hit(info)
	# The runner: speed, then the runner's own reaction.
	if loss < 0.0:
		_drop_to_walk(true)
	else:
		_speed *= 1.0 - loss
		_charge_speed *= 1.0 - loss
		var hv := Vector3(fighter.velocity.x, 0.0, fighter.velocity.z) * (1.0 - loss)
		fighter.velocity = Vector3(hv.x, fighter.velocity.y, hv.z)
		_free_hv *= 1.0 - loss
		_pass_through(victim)
	GameEvents.rammed.emit(fighter, victim, vres, sres)
	var back := -dir
	match sres:
		&"stumble":
			_drop_to_walk(true)
			fighter.stumble(back, Bones.L_LOWER_LEG)
		&"knockdown":
			_drop_to_walk(true)
			fighter.velocity = Vector3.ZERO
			fighter.knockdown(back, Bones.CHEST)
	TimeDirector.hitstop([fighter, victim], Tuning.RAM_HITSTOP)

## Ploughing: the runner's capsule and the victim's capsule and bones ignore
## each other for RAM_PASS_TIME, so the runner is not stopped and the body is
## not bulldozed along.
func _pass_through(victim: Fighter) -> void:
	fighter.add_collision_exception_with(victim)
	var bones: Array[PhysicalBone3D] = []
	if victim.rig != null:
		bones = victim.rig.get_physical_bones()
	for b in bones:
		if is_instance_valid(b):
			b.add_collision_exception_with(fighter)
	# The timer may outlive either body: hold instance ids, never the objects.
	var me_id := fighter.get_instance_id()
	var victim_id := victim.get_instance_id()
	var bone_ids: Array[int] = []
	for b in bones:
		if is_instance_valid(b):
			bone_ids.append(b.get_instance_id())
	TimeDirector.real_timer(RAM_PASS_TIME).timeout.connect(func() -> void:
		var me := instance_from_id(me_id) as PhysicsBody3D
		if me == null:
			return
		var v := instance_from_id(victim_id) as PhysicsBody3D
		if v != null:
			me.remove_collision_exception_with(v)
		for id in bone_ids:
			var b := instance_from_id(id) as PhysicsBody3D
			if b != null:
				b.remove_collision_exception_with(me))

## The victim's lower leg on the side a push along `push_dir` comes from.
static func _near_leg(victim: Fighter, push_dir: Vector3) -> StringName:
	var right := victim.get_forward().cross(Vector3.UP)
	return Bones.R_LOWER_LEG if (-push_dir).dot(right) > 0.0 else Bones.L_LOWER_LEG

## A preset-tier hit (ram, shockwave) through the one hit pipeline.
func _preset_hit(victim: Fighter, move_id: StringName, kind: StringName, tier: int,
		dir: Vector3, bone: StringName) -> HitInfo:
	var info := HitInfo.new()
	info.attacker = fighter
	info.victim = victim
	info.move_id = move_id
	info.kind = kind
	info.tier = tier
	info.reaction = HitInfo.reaction_for_tier(tier)
	info.damage = 0.0
	info.power = 0.0
	info.unblockable = true
	info.hit_direction = Vector3(dir.x, 0.0, dir.z).normalized()
	info.hit_bone = bone
	info.hit_position = victim.get_ground_position() + Vector3.UP * (0.45 if tier == HitInfo.Tier.STUMBLE else 1.1)
	info.launch_velocity = Vector3.ZERO  # never a launch, at any level
	info.hitstop = 0.0
	info.level = HitInfo.Level.LOW if tier == HitInfo.Tier.STUMBLE else HitInfo.Level.MID
	info.set_meta(&"strength", 0.8)
	if tier == HitInfo.Tier.STUMBLE:
		info.set_meta(&"stumble", true)
	return info

# =============================================================================
# Events from other modules
# =============================================================================

## A reaction took the body (flinch, stagger, knockdown, launch, held): drop
## whatever locomotion was running.
func _on_ragdoll_state_changed(_old: int, new_state: int) -> void:
	if new_state == RagdollController.State.ANIMATED:
		return
	_interrupt(&"hit")

func _interrupt(reason: StringName, keep_hang := false) -> void:
	if _mode == Mode.WALL_RUN:
		_end_wall_run(reason, Tuning.WALLRUN_DROP_KEEP)
	if _mode == Mode.PARKOUR:
		_finish_parkour_tween()
	if _mode == Mode.HANG and not keep_hang:
		_end_hang(false)
	if _mode != Mode.HANG:
		_mode = Mode.GROUND  # the next tick finds the floor, or falls (no landing pause)
	_jumping = false
	_drop_strike = false
	_slam = false
	_air_dash_left = 0.0
	_land_left = 0.0
	_land_kind = &""
	_end_sprint_state()
	_burst_left = 0.0
	_free_hv = Vector3.ZERO

## A hit during a sprinting charge knocks the player out of it and they stumble.
func _on_hit_received(info: HitInfo) -> void:
	if info == null or info.result != HitInfo.Result.HIT:
		return
	# The hit's reaction (applied before this signal) may already have ended
	# the steering through the ragdoll's state change: look one frame back.
	if not _charge_steer and Engine.get_physics_frames() - _charge_steer_frame > 1:
		return
	_charge_steer = false
	_charge_steer_frame = -10
	if fighter.is_dead() or fighter.is_down():
		return
	var t := info.tier
	if t != HitInfo.Tier.NONE and t > HitInfo.Tier.STUMBLE:
		return  # a bigger reaction already took the body
	if t == HitInfo.Tier.NONE and info.reaction != HitInfo.Reaction.FLINCH:
		return
	fighter.stumble(info.hit_direction, Bones.L_LOWER_LEG)

## Fallback commit when B emits strike_started before (or without) calling on_strike_started().
func _on_strike_event(attacker: Node3D, _target: Node3D, _move_id: StringName, sprint: bool,
		_charge_level: int) -> void:
	if attacker != fighter or _committed:
		return
	if fighter.combat != null and fighter.combat.is_charging():
		return
	on_strike_started(sprint)

# =============================================================================
# Shared helpers
# =============================================================================

func _apply_move(hv: Vector3, vy_move: float, vy_end: float, factor: float) -> void:
	fighter.velocity = Vector3(hv.x, vy_move, hv.z) * factor
	fighter.move_and_slide()
	fighter.velocity /= factor
	if fighter.is_on_floor():
		fighter.velocity.y = minf(fighter.velocity.y, 0.0)
	elif fighter.is_on_ceiling():
		fighter.velocity.y = minf(vy_end, 0.0)
	else:
		fighter.velocity.y = vy_end
	for i in fighter.get_slide_collision_count():
		var col := fighter.get_slide_collision(i)
		if col.get_normal().y > 0.7:
			_floor_collider = col.get_collider()

func _touch_floor() -> void:
	if not _used_walls.is_empty():
		_used_walls.clear()
	_coyote_until = -INF
	_air_dashed = false
	_air_dash_left = 0.0

## Fighter.knockback() and B's lunges. Vector3.INF when nothing forces the capsule.
func _forced_velocity(pdt: float) -> Vector3:
	var kb := _knockback_velocity(pdt)
	return kb if kb != Vector3.INF else _combat_forced_velocity()

## Fighter.knockback() (its private timer, until H exposes consume_knockback()).
func _knockback_velocity(pdt: float) -> Vector3:
	if fighter.has_method(&"consume_knockback"):
		var kb: Vector3 = fighter.call(&"consume_knockback", pdt)
		if kb != Vector3.INF:
			return Vector3(kb.x, 0.0, kb.z)
		return Vector3.INF
	var left = fighter.get(&"_forced_left")
	if typeof(left) == TYPE_FLOAT and left > 0.0:
		fighter.set(&"_forced_left", left - pdt)
		var fv: Vector3 = fighter.get(&"_forced_velocity")
		return Vector3(fv.x, 0.0, fv.z)
	return Vector3.INF

## CombatController's lunges, dash and chase.
func _combat_forced_velocity() -> Vector3:
	var c := fighter.combat
	if c != null and c.has_forced_velocity():
		var f := c.get_forced_velocity()
		return Vector3(f.x, 0.0, f.z)
	return Vector3.INF

## Until H routes Jump here: Fighter.jump() (the Upgrade 2 jump) took off this
## tick. Turn it into this module's jump so Fighter's own air state never sticks.
func _adopt_fighter_jump(now: float) -> void:
	var air = fighter.get(&"_airborne")
	if typeof(air) != TYPE_BOOL or not air:
		return
	fighter.set(&"_airborne", false)
	fighter.set(&"_air_time", 0.0)
	if _mode == Mode.GROUND or now <= _coyote_until:
		if not _try_wall_run():
			_do_jump(false)
	elif _mode == Mode.WALL_RUN:
		_wall_kickoff()
	else:
		_jump_buffer_until = now + Tuning.JUMP_BUFFER_TIME

## A teleport (Defence) or a gap in our ticks: whatever curve or run was going
## is stale.
func _check_discontinuity() -> void:
	if _last_pos == Vector3.INF:
		_last_pos = fighter.global_position
		_mode = Mode.GROUND if fighter.is_on_floor() else Mode.AIR
		return
	if fighter.global_position.distance_to(_last_pos) > 1.0:
		_floor_collider = null
		_interrupt(&"end", true)  # a pursuit teleport may have just started a hang
		_air_top = fighter.global_position.y
		_air_speed = 0.0

func _stick() -> Vector3:
	var s := Vector3(fighter.move_input.x, 0.0, fighter.move_input.z)
	if s.length() > 1.0:
		s = s.normalized()
	return s

func _stick_or(fallback: Vector3) -> Vector3:
	var s := _stick()
	return s if s.length() > STICK_DEADZONE else fallback

## Round 4 lock-on (ported from Fighter): slower backpedal and strafe around the target.
func _lock_scaled(desired: Vector3) -> Vector3:
	var lt := fighter.lock_target
	if lt == null or not is_instance_valid(lt) or desired.length_squared() < 1e-6:
		return desired
	var to := lt.get_ground_position() - fighter.global_position
	to.y = 0.0
	if to.length_squared() < 1e-4:
		return desired
	to = to.normalized()
	var along := desired.dot(to)
	var side := desired - to * along
	return to * along * (Fighter.LOCK_BACK_MULT if along < 0.0 else 1.0) + side * Fighter.LOCK_STRAFE_MULT

## Facing (ported from Fighter): toward face_dir, or the run heading while
## sprinting, dashing or charge-steering (the camera / lock-on keeps face_dir
## for walking and strafing).
func _update_facing(pdt: float) -> void:
	var want := fighter.face_dir
	var running := _sprinting or _charge_steer or _burst_left > 0.0 or _land_kind == &"roll"
	var locked := fighter.lock_target != null and is_instance_valid(fighter.lock_target)
	if running and not (locked and not _sprinting):
		want = _heading
		fighter.face_dir = _heading  # in step, so ending the run never snaps back to an old facing
	var c := fighter.combat
	var allow := c.can_turn() if c != null else true
	if not allow:
		return
	var fd := Vector3(want.x, 0.0, want.z)
	if fd.length_squared() < 1e-4:
		return
	fd = fd.normalized()
	var target_yaw := atan2(-fd.x, -fd.z)
	var rate := Tuning.TURN_SPEED * (c.get_turn_mult() if c != null else 1.0)
	rate = minf(rate, fighter.max_turn_rate)
	fighter.rotation.y = rotate_toward(fighter.rotation.y, target_yaw, rate * pdt)

func _face_now(dir: Vector3, pdt: float) -> void:
	var fd := Vector3(dir.x, 0.0, dir.z)
	if fd.length_squared() < 1e-4:
		return
	fd = fd.normalized()
	fighter.rotation.y = rotate_toward(fighter.rotation.y, atan2(-fd.x, -fd.z), Tuning.TURN_SPEED * 1.5 * pdt)

func _update_animator() -> void:
	var anim := fighter.animator
	if anim == null:
		return
	var hv := Vector3(fighter.velocity.x, 0.0, fighter.velocity.z)
	var stance: StringName = &"stand"
	var style: StringName = &"walk"
	match _mode:
		Mode.AIR, Mode.HANG:
			stance = &"air"
		Mode.PARKOUR:
			stance = &"stand" if _pk_kind == &"step" else &"air"
			hv = _pk_exit_vel if _pk_kind == &"step" else Vector3.ZERO
		Mode.WALL_RUN:
			style = &"wall_run_l" if _wr_side < 0 else &"wall_run_r"
		_:
			if fighter.is_crouching():
				stance = &"crouch"
	if _mode != Mode.WALL_RUN:
		if fighter.carry != null and fighter.carry.is_holding():
			style = &"carry"
		elif hv.length() > Tuning.WALK_SPEED + 0.3:
			style = &"sprint"
		elif fighter.lock_target != null and is_instance_valid(fighter.lock_target):
			style = &"strafe"
	anim.set_stance(stance, fighter.velocity.y)
	var local_v := fighter.global_basis.inverse() * hv
	anim.set_locomotion(local_v, maxf(get_speed_cap(), Tuning.WALK_SPEED))
	if style != _style:
		_style = style
		anim.set_locomotion_style(style)

func _play_timed(pose: StringName, dur: float) -> void:
	if fighter.animator != null and dur > 0.0:
		fighter.animator.play_timed(pose, dur)
		if _mode == Mode.PARKOUR:
			_pk_posed = true

## Footsteps while moving on the floor, one per stride (the animator's stride model).
func _tick_footsteps(pdt: float) -> void:
	if _mode != Mode.GROUND or not fighter.is_on_floor():
		_step_accum = 0.0
		return
	var v := Vector2(fighter.velocity.x, fighter.velocity.z).length()
	if v < MOVING_SPEED:
		_step_accum = 0.0
		return
	_step_accum += v * pdt
	var stride := _stride(v)
	if _step_accum >= stride:
		_step_accum -= stride
		# The floor right under the foot now (a teleport or a snap leaves the
		# last slide contact stale: metal reported as the water walked before).
		var under := _cast_ray(fighter.global_position + Vector3.UP * 0.3, fighter.global_position + Vector3.DOWN * 0.4,
			Layers.WORLD | Layers.DESTRUCTIBLE)
		if not under.is_empty():
			_floor_collider = under["collider"]
		var surface := WorldTags.surface_of(_floor_collider) if _floor_collider != null else &"concrete"
		GameEvents.footstep.emit(fighter, fighter.global_position, surface, sprint_charge)

## m per footfall, matching PoseAnimator's locomotion stride.
static func _stride(speed: float) -> float:
	return clampf(0.35 + 0.15 * speed, 0.4, 1.1)

func _radius() -> float:
	return _capsule_shape.radius if _capsule_shape != null else Fighter.CAPSULE_RADIUS

## One forward probe (ShapeCast3D). {} when clear; else dist (centre to the
## face along dir), point, normal, collider, obstacle (WorldTags.is_obstacle).
func _probe(i: int, origin: Vector3, dir: Vector3, length: float) -> Dictionary:
	var sc := _probes[i]
	sc.global_transform = Transform3D(Basis(), origin)
	sc.target_position = dir * length
	sc.force_shapecast_update()
	if not sc.is_colliding():
		return {}
	var best := -1
	var best_d := INF
	var any_target := false
	for k in sc.get_collision_count():
		var col := sc.get_collider(k)
		if col == null:
			continue
		if not WorldTags.is_obstacle(col):
			any_target = true
		var d := (sc.get_collision_point(k) - origin).dot(dir)
		if d < best_d:
			best_d = d
			best = k
	if best < 0:
		return {}
	var n := sc.get_collision_normal(best)
	n.y = 0.0
	if n.length_squared() < 1e-4:
		n = -dir
	var dist := sc.get_closest_collision_safe_fraction() * length + PROBE_RADIUS
	var obstacle := not any_target and WorldTags.is_obstacle(sc.get_collider(best))
	return {"dist": dist, "point": sc.get_collision_point(best), "normal": n.normalized(),
		"collider": sc.get_collider(best), "obstacle": obstacle,
		"body": INF if obstacle else dist, "idx": i}

## The probe that met static geometry first (a lower probe wins within 0.1 m). {} when none did.
static func _nearest_obstacle(probes: Array) -> Dictionary:
	var best := {}
	for pr: Dictionary in probes:
		if pr.is_empty() or not pr["obstacle"]:
			continue
		if best.is_empty() or float(pr["dist"]) < float(best["dist"]) - 0.1:
			best = pr
	return best

## K's clutter as one box: {top (world y), exit (m along `dir` from `feet` where
## the box ends)}. {} when the collider is not clutter.
static func _clutter_box(collider: Object, feet: Vector3, dir: Vector3) -> Dictionary:
	var n := collider as Node
	if n == null or not n.is_in_group(&"clutter") or not n.has_method(&"get_box_transform"):
		return {}
	var xf: Transform3D = n.call(&"get_box_transform")
	var size: Vector3 = n.get(&"size")
	var h := size * 0.5
	var top := xf.origin.y + absf(xf.basis.y.normalized().y) * h.y
	# Slab exit of the horizontal line from the feet along dir, in box space.
	var o := xf.affine_inverse() * Vector3(feet.x, xf.origin.y, feet.z)
	var d := xf.basis.inverse() * dir
	var t_exit := INF
	for i in 3:
		if i == 1:
			continue
		if absf(d[i]) < 1e-6:
			if absf(o[i]) > h[i]:
				return {}
			continue
		var t1 := (-h[i] - o[i]) / d[i]
		var t2 := (h[i] - o[i]) / d[i]
		t_exit = minf(t_exit, maxf(t1, t2))
	if t_exit == INF or t_exit <= 0.0:
		return {}
	return {"top": top, "exit": t_exit}

## Nearest body (fighter, ragdoll, prop: anything but an obstacle) a probe met (INF: none).
static func _probe_body(pr: Dictionary) -> float:
	return INF if pr.is_empty() else float(pr["body"])

## A chest / head probe met static geometry above `top_y` before `upto`: an
## overhang (a beam, a window head, a ceiling) over the way across.
static func _probe_overhang(pr: Dictionary, top_y: float, upto: float) -> bool:
	return not pr.is_empty() and pr["obstacle"] and (pr["point"] as Vector3).y > top_y + 0.05 \
		and float(pr["dist"]) < upto

## Top of the obstacle hit at `point` on a face whose inward direction is
## `inward`, as a world y. NAN if nothing; a very large value when the ray
## starts inside (taller than the ray). It samples just inside the face (along
## the face, not the run: a thin part met at an angle, like a sofa's back, would
## be stepped past).
func _find_top(point: Vector3, inward: Vector3, feet_y: float, from_height := NAN) -> float:
	var h := TOP_RAY_FROM * fighter.get_height_scale() if is_nan(from_height) else from_height - feet_y
	var x := point + Vector3(inward.x, 0.0, inward.z).normalized() * TOP_INSET
	var from := Vector3(x.x, feet_y + h, x.z)
	var hit := _cast_ray(from, Vector3(x.x, feet_y - 0.05, x.z), Layers.WORLD | Layers.DESTRUCTIBLE)
	if hit.is_empty():
		return NAN
	if not WorldTags.is_obstacle(hit["collider"]):
		return NAN
	var p: Vector3 = hit["position"]
	if p.y >= from.y - 1e-3:
		return feet_y + 1000.0  # started inside: taller than anything we climb
	return p.y

## Distance along dir (from the feet) where the obstacle's top ends; NAN if it
## does not end before `limit` (a deep top: a platform or crate to land on).
func _find_far_edge(feet: Vector3, dir: Vector3, face: float, top_y: float, limit: float) -> float:
	var d := face + FAR_EDGE_STEP
	while d <= limit:
		var x := feet + dir * d
		var hit := _cast_ray(Vector3(x.x, top_y + 0.3, x.z), Vector3(x.x, feet.y - 1.5, x.z),
			Layers.WORLD | Layers.DESTRUCTIBLE)
		if hit.is_empty() or (hit["position"] as Vector3).y < top_y - FAR_EDGE_DROP:
			return d - FAR_EDGE_STEP * 0.5
		d += FAR_EDGE_STEP
	return NAN

## Floor y under `pos` (ray from `from_y`); NAN when there is none within 3 m.
func _floor_y_at(pos: Vector3, from_y: float) -> float:
	var hit := _cast_ray(Vector3(pos.x, from_y, pos.z), Vector3(pos.x, pos.y - 3.0, pos.z),
		Layers.WORLD | Layers.DESTRUCTIBLE)
	if hit.is_empty():
		return NAN
	var p: Vector3 = hit["position"]
	if p.y >= from_y - 1e-3:
		return NAN
	return p.y

func _cast_ray(from: Vector3, to: Vector3, mask: int) -> Dictionary:
	_ray.global_transform = Transform3D(Basis(), from)
	_ray.target_position = to - from
	_ray.collision_mask = mask
	_ray.force_raycast_update()
	if not _ray.is_colliding():
		return {}
	return {"position": _ray.get_collision_point(), "normal": _ray.get_collision_normal(),
		"collider": _ray.get_collider()}

## The player's capsule fits with its feet at `feet` (`mask`: world and
## fighters by default; WORLD_MASK for static geometry only).
func _capsule_free(feet: Vector3, mask := Layers.WORLD | Layers.DESTRUCTIBLE | Layers.CAPSULE) -> bool:
	if not fighter.is_inside_tree():
		return true
	var shape := _capsule_shape if _capsule_shape != null else fighter.capsule.shape as CapsuleShape3D
	_q_shape.radius = shape.radius
	_q_shape.height = shape.height
	_q_params.collision_mask = mask
	_q_params.shape = _q_shape
	_q_params.transform = Transform3D(Basis(), feet + Vector3.UP * (shape.height * 0.5))
	var space := fighter.get_world_3d().direct_space_state
	return space.intersect_shape(_q_params, 1).is_empty()
