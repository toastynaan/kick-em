class_name CombatController
extends Node
## Moves, frame data, hit detection (hit registry: each attack hits each target
## once), the hit pipeline, block, perfect dodge + teleport counter, Focus use,
## dash momentum, pursuit, air recovery, grab / throw / break / reversal.
## Same component for the player and for enemies; enemies start attacks via
## start_enemy_attack() (tell + startup) instead of button presses.
## OWNER: agent B (fighter & combat). CONTRACT STUB: keep every public signature.
##
## Timing: move phases, stun and dash run on the scaled physics delta (they
## slow down in slow motion and stop during this fighter's hitstop). Input
## windows (perfect dodge, grab break, counter, pursuit) and cooldowns use
## TimeDirector.now() (real time).

enum Action { LIGHT, HEAVY, KICK, SWEEP, GRAB, BLOCK, DASH }
enum Phase { IDLE, CHARGING, STARTUP, ACTIVE, RECOVERY, HOLDING }
enum Stun { NONE, HIT, BLOCK, STUMBLE, DAZE }

signal attack_started(move_id: StringName)
## Real seconds until the first active frame, sent when an attack starts (AI dodge timing).
signal attack_incoming(move_id: StringName, time_to_active: float)
signal attack_active(move_id: StringName)
signal attack_ended(move_id: StringName)
signal hit_dealt(info: HitInfo)
signal hit_received(info: HitInfo)

# --- Local tuning (candidates for Tuning) -----------------------------------
const STAGGER_TIME := 0.7          ## s of stun on a stagger
const STAGGER_STRENGTH := 0.75     ## default stagger strength (< 1 recovers on the feet)
const HEAVY_STAGGER_STRENGTH := 0.9  ## heavy victim that was too heavy to launch
const BUFFER_MAX_AGE := 0.8        ## s: presses older than this are dropped (no surprise moves)
# Upgrade 2 (local tuning starts; candidates for Tuning)
const CHARGE_RELEASE_FRAMES := 4.0 ## frames from a charge's release to its active frames
const CHARGE_GLOW_TIME := 0.45     ## s the L3 limb glows after the release
const CHARGE_GLOW_COLOR := Color(1.0, 0.75, 0.3)
const CHARGE_FACE_RANGE := 6.0     ## m: a charge turns toward an opponent this close, else keeps facing
const STRIKE_BREAK_HITSTOP_MULT := 2.0  ## wall strike hitstop x on &"break"
const STRIKE_RECOIL_TIME := 0.15   ## s of the recoil slide off a wall that holds
const STRIKE_FIGHTER_MARGIN := 0.6 ## m beyond reach in which an opponent takes priority over a wall
const FLOOR_NORMAL_Y := 0.7        ## contacts with a more upward normal are floors, never struck
const RISING_WINDOW := 0.25        ## s after releasing crouch in which P is a rising uppercut
const MOUNT_PUNCHES := 3           ## mount punches per down
const STOMP_RANGE := 0.9           ## m: a downed body this close is under you (stomp, not punt)
const GROUND_HOLD := 0.6           ## s a mount punch keeps a downed body from getting up
const BACKFIST_RANGE := 3.0        ## m: backfist turns to an opponent behind within this
const CHARGE_LAUNCH_MULT: Array[float] = [1.0, 1.0, 1.15, 1.5]   ## launch x by charge level
const CHARGE_LAUNCH_MIN: Array[float] = [0.0, 0.0, 8.0, 15.5]    ## m/s; L3 15.5 breaks brick (70 kg)
const CHARGE_HITSTOP_BONUS := 0.25 ## hitstop +25% per charge level
const KNOCKDOWN_LAUNCH := 2.0      ## m/s: a second sweep in a combo only knocks down
const JUGGLE_MIN_LAUNCH := 5.0     ## m/s before Tuning.JUGGLE_LAUNCH on a juggle hit
const JUGGLE_UP_ANGLE := 6.0       ## degrees: juggles fly flat toward the wall
const JUGGLE_WALL_RANGE := 10.0    ## m searched for the wall a juggle flattens toward
const WALL_RAYS := 16
const DAZED_LAUNCH := 9.0          ## m/s: the hit after a daze always launches
const AIR_COUNTER_MIN := 5.0       ## m/s before Tuning.AIR_COUNTER_LAUNCH on a jumping victim
const LIFT_HORIZONTAL := 1.2       ## m/s sideways drift of launchers
const HEAD_STUN_MULT := 1.6        ## head hits flinch this much longer
const ARM_BROKEN_DAMAGE := 0.6     ## attacks with a broken arm
const ARM_HIT_CANCEL := true       ## striking the attacking arm in a wind-up cancels it
const LEG_SLOW_MULT := 1.0 - Tuning.ZONE_LEG_SLOW
const BLOCK_WALK_MULT := 0.35      ## walking while guarding
const ROUNDHOUSE_SPIN := 2.0       ## limb-spin strength of the roundhouse's sideways launch
const BLOCKED_HITS_WINDOW := 2.0   ## s: blocked hits closer than this count toward a daze
const MAX_KNEES := 3               ## knees per hold (spec: Grab, P up to 3)
const ESCAPE_PUSH_TIME := 0.2      ## s of the break-away slide
const ESCAPE_VICTIM_SHARE := 0.8   ## of Tuning.COMBO_ESCAPE_PUSH covered by the victim
const LYING_HEIGHT := 0.45         ## m: a launched body with its COM this low...
const LYING_SPEED := 2.0           ## ...and slower than this is lying, not airborne
const LIMB_HOLD_MAX := 3.0         ## s an arm drag / giant swing lasts at most
const WALL_SLAM_UP_ANGLE := 4.0    ## degrees: ~8.98 m/s into the wall, ~2,810 J at 70 kg (cracks brick, D)
const UPWARD_THROW_DRIFT := 0.6    ## m/s forward drift of the upward throw
const GRAB_SOCKET := 0.72          ## m in front of the grabber (x height scale)
const GRAB_CONE_DOT := 0.4         ## grab only catches fighters roughly in front
const GRAB_MIN_HOLD := 0.15        ## real s before a released Grab throws (lets the catch read)
const ENEMY_HOLD_TIME := 0.55      ## real s an enemy holds before throwing (> GRAB_BREAK_LATE)
const GRAB_BREAK_PUSH_TIME := 0.18 ## s the break push slide lasts
const DODGE_CHECK_EXTRA := 2.0     ## m beyond the move's reach in which defenders may dodge
const COUNTER_GRACE := 0.05        ## real s added to the dodge slow-mo window for the counter press
const COUNTER_INVULN := 0.45       ## real s of invulnerability from the teleport
const PURSUIT_TIME := 0.6          ## real s after the pursuit teleport for the follow-up hit
const PURSUIT_OFFSET := 1.0        ## m behind the flying body along its flight
const PURSUIT_REACH := 2.8         ## m: the follow-up connects with the locked body inside this
const PURSUIT_MIN_LAUNCH := 6.0    ## m/s: any pursuit follow-up relaunches at least this hard
const PURSUIT_MAX_CHASE := 30.0    ## m/s capsule chase speed cap
const HEAVY_MASS_REF := 85.0       ## kg: heavier victims get move launch x (ref / mass)
const HEAVY_MIN_LAUNCH := 6.0      ## m/s: below this a heavy victim staggers instead (standing kick on a Brute)
const BLOCK_PUSH_TIME := 0.15
const SHIELD_FRONT_DOT := 0.2      ## attacker this far in front of a Shield -> blocked
const TELL_MIN := 12.0             ## frames: enemy startup never shorter than this
const PROJECTILE_SPEED := 15.0     ## m/s debris chunk
const LAUNCH_SHAKE_ENERGY := 12000.0  ## J for full screen-shake trauma
const LOCKED_TARGET_REACH := 0.9   ## m beyond reach in which a locked target (counter) still connects
const AI_COUNTER_INVULN := 0.1     ## real s of invulnerability on the AI teleport (the tell is hittable)
const CARRY_OFFSET := Vector3(0.0, -0.16, -0.05)  ## chunk position in the right-hand attachment
const GUARD_FRONT_DOT := 0.3       ## enemy guards and archetype blocks cover this front cone
const MAGNET_EXTRA := 1.2          ## m beyond reach in which a strike pulls toward its target
const MAGNET_MAX_SPEED := 6.0      ## m/s cap of that pull (startup only)
const MAGNET_GAP := 0.7            ## the pull stops at this fraction of the move's reach
const MAGNET_REACH_BONUS := 0.3    ## m added to the fallback query's reach toward a magnet target
const PUNT_RANGE := 1.6            ## m: a downed opponent this close ahead turns Kick into a punt
const PUNT_FLOOR_HEIGHT := 0.75    ## m: COM this low counts as "on the floor"
const DEBRIS_KICK_RADIUS := 0.7    ## m from the kicking foot
const DEBRIS_KICK_SPEED := 14.0    ## m/s
const DEBRIS_KICK_DAMAGE := 40.0
const PURSUIT_REFUND := 0.5        ## Focus back when a pursuit follow-up breaks/cracks a wall or bowls
const PURSUIT_REFUND_RADIUS := 2.5 ## m between the flying body and the wall event
const ARMOR_HITSTOP := 0.05
const LATE_DODGE_FEEDBACK_EXTRA := 2.0  ## m beyond reach for "late" dodge feedback

var fighter: Fighter
var blocking := false
var holding: Fighter = null   ## Victim we hold in a grab.
var held_by: Fighter = null   ## Grabber holding us.
## AI: world direction for the next throw (ZERO = facing).
var throw_aim := Vector3.ZERO
## Result of the last receive_hit() (HitInfo.Result), -1 before any hit.
var last_result := -1
## Last HitInfo this fighter received / dealt (tests, debug HUD).
var last_received: HitInfo
var last_dealt: HitInfo
## Last wall strike {target, position, normal, power, result} (tests, debug HUD).
var last_wall_strike: Dictionary = {}

var _phase: int = Phase.IDLE
var _move: MoveData
var _seq_id: StringName = &""   ## move id reported by attack_ended
var _t := 0.0                   ## game s in the current phase
var _startup := 0.0
var _active := 0.0
var _recovery := 0.0
# Upgrade 2: press model, charge, strings
## Tests and the lab: read press/release like the player's buttons (tap vs hold)
## even without a PlayerController. HEAVY always charges while held.
var force_hold_charge := false
var graph: ComboGraph = ComboGraph.default_graph()
var _btn_down := {}             ## Action -> held
var _btn_time := {}             ## Action -> real press time
var _press_action := -1         ## button that started the current move (-1: tap / scripted)
var _press_t := 0.0             ## its press time (real)
var _press_released := true
var _min_charge := 0            ## HEAVY: at least level 1
var _charge_level := 0          ## level reached while charging
var _move_charge := 0           ## level the current move fires with
var _release_after_dash := false
var _waited := false            ## the strike reached the end of its startup before the release
var _charge_glow: Node3D
var _last_move_id: StringName = &""
var _last_move_end := -INF
var _crouch_was := false
var _crouch_released_at := -INF
## Victim side: ground finishers taken this time down (reset on getting up):
## mount punches (up to MOUNT_PUNCHES) and one stomp or punt.
var downed_hits := 0
var downed_kicked := false
var _combo_count := 0           ## attacker: hits in the current combo
var _combo_last := -INF         ## real time of its last hit
var _combo_tripped := {}        ## victim id -> true: one trip per combo
var _leg_slow_left := 0.0       ## victim: legs struck, walk slowed
var limb_damage := {}           ## victim: BodyZones.Zone -> zone damage taken
var broken_arms := {}           ## victim: BodyZones.Zone -> true
var _taken := 0                 ## victim: hits taken in the current combo (from anyone)
var _taken_last := -INF
var _taken_stun := 0.0          ## victim: stun taken in the current combo (break-away at COMBO_ESCAPE_STUN)
var _escape_guard_until := 0.0  ## victim: break-away auto-guard
var juggle_relaunches := 0      ## victim: juggle relaunches this flight (cap Tuning.JUGGLE_MAX_RELAUNCH)
var getup_extended := false     ## victim: a ground hit already delayed this get-up
var _blocked_hits := 0          ## victim: consecutive blocked hits (daze at Tuning.DAZE_BLOCKED_HITS)
var _blocked_last := -INF
var _hit_any := false
var _hit_confirmed := false     ## this attack landed a clean HIT (cancels)
var _magnet: Fighter            ## strike pulls toward / aims at this target
var _magnet_velocity := Vector3.ZERO
var _has_magnet := false
var _aim_set := false
var _debris_kicked := false
var _wall_struck := false       ## this move already struck a wall (once per move)
var _strike_dash := false       ## dash momentum was on when this move started
var _last_swept: Fighter        ## last fighter our sweep hit (sweep -> punt cancel)
var _refund_victim: Fighter     ## pursuit follow-up victim still in flight
var _refund_until := 0.0
var _registry := {}             ## victim instance id -> true
var _prev_limb := Vector3.INF
var _prev_limbs := {}           ## bone -> last tick's position (limb sweep)
var _locked_target: Fighter
var _pursuit_hit := false
var _approach_v := Vector3.ZERO
var _active_start_real := 0.0
var _freeze_until := 0.0
var _stun_left := 0.0
var _stun_kind: int = Stun.NONE
var _guard_stun := false        ## blockstun came from a real guard (stays blocking)

var _block_held := false
var _block_since := 0.0
var _grab_held := false
var _block_presses: Array[float] = []
var _grab_presses: Array[float] = []
var _dodge_lockout_until := 0.0
var _vanish_until := 0.0
var _vanished := false          ## body hidden by a perfect dodge
var _counter_until := 0.0
var _dodged_attacker: Fighter
var _counter_cooldown_until := 0.0
var _teleport_invuln_until := 0.0
var _buffer_action := -1
var _buffer_time := 0.0

var _dash_left := 0.0
var _dash_velocity := Vector3.ZERO
var _dash_end_real := -INF
var _dash_cooldown_until := 0.0

var _last_launch_victim: Fighter
var _last_launch_time := -INF
var _pursuit_target: Fighter
var _pursuit_until := 0.0
var _pursuit_dir := Vector3.ZERO
var _pursuit_side := Vector3.ZERO
var _chase_velocity := Vector3.ZERO
var _has_chase := false

var _ai_counter := false        ## current back_kick came from start_counter (perfect-dodgeable)
var _pending_counter: Fighter   ## start_counter called during the vanish
var _pending_counter_tell := 0.0
var _carried: RigidBody3D       ## debris chunk in the right hand (Thrower)

var _hold_start := 0.0
var _knees := 0                 ## knees thrown in this hold
var _focus_pursuits := {}       ## victim id -> pursuits in the current Focus burst
var _focus_was := false
var _limb_grab: LimbGrab        ## arm drag / giant swing in progress (agent G)
var _limb_victim: Fighter
var _limb_zone: int = BodyZones.Zone.TORSO
var _held_break_mult := 1.0     ## victim: break window x (arm drags: Tuning.ARM_DRAG_BREAK_MULT)
var _held_via_grab := false     ## victim: held_by came from a grab (the watchdog polices it)
var _headlock := false          ## holding by the head (knee / headbutt / neck throw)
var _held_connect_time := -INF  ## victim side: when the grab connected (real)
var _held_breakable := true

var _q_sphere := SphereShape3D.new()
var _q_capsule := CapsuleShape3D.new()
var _q_params := PhysicsShapeQueryParameters3D.new()

func setup(p_fighter: Fighter) -> void:
	fighter = p_fighter
	if fighter.is_player:
		GameEvents.wall_broken.connect(_on_wall_broken)
		GameEvents.wall_cracked.connect(_on_wall_cracked)
		GameEvents.body_bowled.connect(_on_body_bowled)

# =============================================================================
# Input
# =============================================================================

## Button input (player, or AI using player-style actions such as BLOCK/DASH).
## Upgrade 2 input model: an attack press starts its wind-up at once; released
## before Tuning.HOLD_THRESHOLD it fires the normal move (waiting for the
## release if the startup is shorter); still held, it freezes in the move's
## charge pose and charges through Tuning.CHARGE_LEVELS until released (or
## Tuning.CHARGE_AUTO_RELEASE). Which move a press means comes from the
## ComboGraph and the fighter's stance (crouch, jump, forward/back).
func press(action: int) -> void:
	if fighter == null or fighter.is_dead():
		return
	var now := TimeDirector.now()
	match action:
		Action.BLOCK:
			_block_presses.append(now)
			_trim_presses(_block_presses, now)
			if not _block_held:
				_block_since = now
			_block_held = true
			_guard_cancels_windup()
			_update_block_state()
			_check_late_press()
		Action.DASH:
			_on_dash_pressed(now)
		Action.GRAB:
			_grab_presses.append(now)
			_trim_presses(_grab_presses, now)
			_grab_held = true
			if held_by != null:
				if is_instance_valid(held_by):
					held_by.combat._try_break_by(fighter, now)
				return
			_grab_press(now)
		Action.LIGHT, Action.KICK, Action.HEAVY, Action.SWEEP:
			_btn_down[action] = true
			_btn_time[action] = now
			if (action == Action.LIGHT or action == Action.KICK) and _try_counter(now):
				return
			_attack_press(action, now)

func release(action: int) -> void:
	match action:
		Action.BLOCK:
			_block_held = false
			_update_block_state()
		Action.GRAB:
			_grab_held = false
		Action.LIGHT, Action.KICK, Action.HEAVY, Action.SWEEP:
			_btn_down[action] = false
			if action == _press_action and not _press_released:
				_press_released = true
				if _phase == Phase.CHARGING:
					_release_charge()
				elif _phase == Phase.STARTUP:
					_move_charge = maxi(_move_charge, _min_charge)  # a HEAVY tap is level 1

## Enemy attack entry point. `move_id` is an enemy move (e_hook, e_heavy, e_kick,
## e_grab, e_charge, e_throw_debris). The tell (pose + glint + sound, emitted as
## GameEvents.attack_tell) lasts `tell_time` and is part of startup.
## Returns false if the fighter cannot attack now.
func start_enemy_attack(move_id: StringName, tell_time: float) -> bool:
	var m := MoveLibrary.get_move(move_id)
	if m == null:
		push_warning("CombatController: unknown move %s" % move_id)
		return false
	if not _can_start():
		return false
	var startup := maxf(tell_time, Tuning.frames(TELL_MIN))
	_press_action = -1
	_move_charge = 0
	GameEvents.attack_tell.emit(fighter, m.tell_kind, startup)
	_begin(m, startup)
	return true

# =============================================================================
# Queries
# =============================================================================

func is_attacking() -> bool:
	return _phase != Phase.IDLE

func is_attack_active() -> bool:
	return _phase == Phase.ACTIVE

func is_in_recovery() -> bool:
	return _phase == Phase.RECOVERY

func is_charging() -> bool:
	return _phase == Phase.CHARGING

func is_holding_grab() -> bool:
	return _phase == Phase.HOLDING and holding != null

## Current move id, or &"" when idle.
func current_move_id() -> StringName:
	if _phase == Phase.IDLE or _move == null:
		return &""
	return _move.id

## Real seconds until the current attack's first active frame (INF if none).
func time_to_active() -> float:
	match _phase:
		Phase.STARTUP:
			var scale := maxf(Engine.time_scale, 0.05)
			var frozen := maxf(_freeze_until - TimeDirector.now(), 0.0)
			return maxf(_startup - _t, 0.0) / scale + frozen
		Phase.ACTIVE:
			return 0.0
	return INF

func is_invulnerable() -> bool:
	var now := TimeDirector.now()
	return now < _teleport_invuln_until or now < _vanish_until

## Vanished by a perfect dodge (hits return DODGED, body hidden).
func is_vanished() -> bool:
	return _vanished or TimeDirector.now() < _vanish_until

## Show the body again if a perfect dodge hid it (death, get-up).
func force_reappear() -> void:
	_reappear()

## down_ok: the player's grabs also catch tumbling and downed fighters
## (Upgrade 2); enemy grabs only catch a standing fighter.
func can_be_grabbed(down_ok := false) -> bool:
	if fighter == null or fighter.is_dead() or held_by != null or holding != null:
		return false
	if fighter.is_invulnerable():
		return false
	var st := fighter.get_state()
	if down_ok and (st == RagdollController.State.LAUNCHED or st == RagdollController.State.GROUNDED):
		return true
	if fighter.is_in_hitstun() and not is_stumbling() and not is_dazed():
		return false
	return st == RagdollController.State.ANIMATED

## Any stun (hit or block). Fighter.is_in_hitstun() uses this.
func is_stunned() -> bool:
	return _stun_left > 0.0

## Flinch / stagger / grab-break stun, stumble and daze (not blockstun).
func is_hit_stunned() -> bool:
	return _stun_left > 0.0 and _stun_kind in [Stun.HIT, Stun.STUMBLE, Stun.DAZE]

func is_blocking() -> bool:
	if fighter == null or fighter.is_dead() or held_by != null or holding != null:
		return false
	if _phase != Phase.IDLE or fighter.is_down():
		return false
	if is_hit_stunned():
		return false
	if _stun_left > 0.0 and _stun_kind == Stun.BLOCK and _guard_stun:
		return true
	return _block_held

## Real seconds block has been held (Brawler AI grabs long blockers).
func get_block_time() -> float:
	return TimeDirector.now() - _block_since if is_blocking() and _block_held else 0.0

func is_dodge_locked_out() -> bool:
	return TimeDirector.now() < _dodge_lockout_until

## True during the perfect-dodge slow motion, when Light/Kick teleport-counters.
func can_counter() -> bool:
	var now := TimeDirector.now()
	return fighter.is_player and now <= _counter_until and now >= _counter_cooldown_until \
		and fighter.focus + 1e-4 >= Tuning.FOCUS_COST

func get_counter_cooldown_left() -> float:
	return maxf(_counter_cooldown_until - TimeDirector.now(), 0.0)

## Within Tuning.PURSUIT_WINDOW of our last launch, with Focus: Dash pursues.
func can_pursue() -> bool:
	return _pursuit_candidate() != null

func is_dashing() -> bool:
	return _dash_left > 0.0

## Charge 0..1 toward level 3 while charging (HUD), else the last move's level / 3.
func get_charge() -> float:
	if _phase == Phase.CHARGING:
		var held := TimeDirector.now() - _press_t
		return clampf((held - Tuning.HOLD_THRESHOLD) / (Tuning.CHARGE_LEVELS[2] - Tuning.HOLD_THRESHOLD), 0.0, 1.0)
	return _move_charge / 3.0

# --- Movement hooks for Fighter -----------------------------------------------
func get_move_speed_mult() -> float:
	var legs := LEG_SLOW_MULT if _leg_slow_left > 0.0 else 1.0
	if held_by != null:
		return 0.0
	if _phase == Phase.HOLDING:
		return Tuning.GRAB_WALK_MULT * legs
	if _phase == Phase.CHARGING and _stun_left <= 0.0:
		return Tuning.CHARGE_WALK[clampi(_charge_level, 0, 3)] * legs
	if _phase != Phase.IDLE or _stun_left > 0.0:
		return 0.0
	if is_blocking():
		return BLOCK_WALK_MULT * legs
	return legs

func has_forced_velocity() -> bool:
	return _forced_velocity_or_inf() != Vector3.INF

## Horizontal velocity that overrides walking this tick, or Vector3.INF for none.
func get_forced_velocity() -> Vector3:
	return _forced_velocity_or_inf()

func _forced_velocity_or_inf() -> Vector3:
	if _has_chase:
		return _chase_velocity
	if _dash_left > 0.0:
		return _dash_velocity
	if _has_magnet and (_phase == Phase.STARTUP or _phase == Phase.ACTIVE):
		return _magnet_velocity
	if _move != null and _move.lunge_speed > 0.0:
		var lunging := (_phase == Phase.STARTUP and _t >= _startup * _move.lunge_start) \
			or (_phase == Phase.ACTIVE and _move.lunge_through_active)
		if lunging:
			return fighter.get_forward() * _move.lunge_speed * fighter.get_height_scale()
	return Vector3.INF

func can_turn() -> bool:
	if held_by != null:
		return false
	if _phase == Phase.CHARGING:
		return true
	if _phase == Phase.ACTIVE or _phase == Phase.RECOVERY:
		return false
	return not is_hit_stunned()

func get_turn_mult() -> float:
	if _phase == Phase.STARTUP:
		return 0.6
	if _phase == Phase.HOLDING:
		return 0.7
	return 1.0

# =============================================================================
# Per-tick update (called by Fighter._physics_process before it moves)
# =============================================================================

func physics_tick(delta: float) -> void:
	if fighter == null or fighter.is_dead():
		return
	# Upgrade 2: the player's combat timers run in player time (full speed in Focus).
	if fighter.is_player:
		delta = TimeDirector.player_delta(delta)
	var now := TimeDirector.now()
	_has_chase = false
	_check_held_by()
	_tick_upgrade2(delta, now)
	if _vanished and now >= _vanish_until:
		_reappear()  # backstop for the real-time timer
	if _pending_counter != null and not _vanished and now >= _vanish_until:
		var pc := _pending_counter
		_pending_counter = null
		_do_ai_counter(pc, _pending_counter_tell)
	if now < _freeze_until:
		return
	if _stun_left > 0.0:
		_stun_left -= delta
		if _stun_left <= 0.0:
			_stun_left = 0.0
			_on_stun_end()
	if _dash_left > 0.0:
		_dash_left -= delta
		if _dash_left <= 0.0:
			_dash_left = 0.0
			_dash_end_real = now
			if _release_after_dash and _phase == Phase.CHARGING:
				_release_charge()
	if _pursuit_target != null:
		_tick_pursuit(delta, now)
	if _refund_victim != null and (not is_instance_valid(_refund_victim) or now > _refund_until \
			or not _refund_victim.is_launched()):
		_refund_victim = null
	_update_magnet()

	match _phase:
		Phase.CHARGING:
			_tick_charge(now)
		Phase.STARTUP, Phase.ACTIVE, Phase.RECOVERY:
			_advance(delta)
		Phase.HOLDING:
			_tick_hold(now)

	_update_block_state()

	# Buffered press: it waits while the fighter is busy (blockstun, hitstop,
	# recovery) and fires the first tick it can; only very old presses expire.
	if _buffer_action >= 0:
		if now - _buffer_time > BUFFER_MAX_AGE:
			_buffer_action = -1
		else:
			_fire_buffer(now)

## A stored press fires as a hit cancel during recovery, or the moment the
## fighter is free.
func _fire_buffer(now: float) -> void:
	var a := _buffer_action
	if a == Action.GRAB:
		if _can_start() or (_phase == Phase.RECOVERY and _hit_cancel_ok(&"grab")):
			_buffer_action = -1
			_grab_press(now)
		return
	if _phase == Phase.RECOVERY:
		var id := _resolve_move(a)
		if id != &"" and _hit_cancel_ok(id):
			_buffer_action = -1
			_cancel_into(a, id, _buffer_time)
		return
	if _can_start():
		_buffer_action = -1
		var id2 := _resolve_move(a)
		if id2 != &"":
			_start_press(a, id2, _buffer_time)

func freeze_until(real_time: float) -> void:
	var now := TimeDirector.now()
	if real_time > _freeze_until:
		var extra := real_time - maxf(_freeze_until, now)
		if _buffer_action >= 0:
			_buffer_time += extra
		_freeze_until = real_time

# =============================================================================
# Starting moves
# =============================================================================

func _can_start() -> bool:
	return _phase == Phase.IDLE and fighter.can_act()

## Tap vs hold applies to the real player's buttons, to tests and the lab
## (force_hold_charge), and always to Action.HEAVY (the scripted charged punch).
## Other scripted presses (bots, AI) are taps.
func _hold_enabled(action: int) -> bool:
	if action == Action.HEAVY:
		return true
	return force_hold_charge or (fighter.brain != null and fighter.brain is PlayerController)

func _attack_press(action: int, now: float) -> void:
	if holding != null:
		_held_followup(action, now)
		return
	if _phase == Phase.CHARGING or held_by != null:
		return
	var id := _resolve_move(action)
	if id == &"":
		return
	# A press continuing the string during a move's startup is remembered (P,P,P mashed).
	if _phase == Phase.STARTUP and _move != null and graph.is_link(_move.id, id):
		_buffer_action = action
		_buffer_time = now
		return
	if _can_start():
		_start_press(action, id, now)
		return
	if _phase == Phase.RECOVERY and _hit_cancel_ok(id):
		_cancel_into(action, id, now)
		return
	if id == &"backfist" and _can_backfist():
		_cancel_into(action, id, now)
		return
	if _buffer_window_open():
		_buffer_action = action
		_buffer_time = now

## Presses are stored during the active frames, the last Tuning.BUFFER_FRAMES
## of recovery, and while stunned or frozen (they fire the moment the fighter
## is free). Earlier presses during a move are dropped: whiffs stay punishable.
func _buffer_window_open() -> bool:
	match _phase:
		Phase.ACTIVE:
			return true
		Phase.RECOVERY:
			return _recovery - _t <= Tuning.frames(Tuning.BUFFER_FRAMES) or _hit_confirmed
		Phase.IDLE:
			return true  # stunned, frozen, held: wait for free
	return false

func _grab_press(now: float) -> void:
	_press_action = -1
	if _can_start():
		_begin(MoveLibrary.get_move(&"grab"))
	elif _phase == Phase.RECOVERY and _hit_cancel_ok(&"grab"):
		_end_sequence()
		_phase = Phase.IDLE
		_clear_aim()
		_begin(MoveLibrary.get_move(&"grab"))
	elif _buffer_window_open():
		_buffer_action = Action.GRAB
		_buffer_time = now

## Input token for a press (ComboGraph): button + stance + stick intent.
func _token(action: int) -> StringName:
	var air := fighter.is_airborne()
	var crouch := fighter.is_crouching()
	var intent := fighter.get_input_intent()
	match action:
		Action.KICK:
			if air:
				return ComboGraph.JK
			if crouch:
				return ComboGraph.CK
			return ComboGraph.K
		Action.SWEEP:
			return ComboGraph.CK
		_:
			if air:
				return ComboGraph.JP
			if crouch:
				return ComboGraph.CP
			if intent == &"back":
				return ComboGraph.BP
			if TimeDirector.now() - _crouch_released_at <= RISING_WINDOW:
				return ComboGraph.RP
			if intent == &"forward":
				return ComboGraph.FP
			return ComboGraph.P

## The move a press means right now: ground finishers over a downed enemy,
## else the next move of the running string (ComboGraph), else a starter.
func _resolve_move(action: int) -> StringName:
	var tok := _token(action)
	if tok == ComboGraph.P or tok == ComboGraph.K or tok == ComboGraph.FP:
		var downed := _punt_target()
		if downed != null and downed.combat != null:
			if action == Action.KICK and not downed.combat.downed_kicked:
				return &"stomp" if _on_top_of(downed) else &"punt"
			if action != Action.KICK and downed.combat.downed_hits < MOUNT_PUNCHES:
				return &"mount_punch"
	var prev := _string_prev()
	if prev == &"mount_punch":
		prev = &""  # ground finishers only chain over a downed body (handled above)
	return graph.next_move(prev, tok)

## The string move a press follows: the current move, or the last one if it
## ended less than Tuning.STRING_RESET ago.
func _string_prev() -> StringName:
	if _phase != Phase.IDLE and _move != null:
		return _move.id
	if TimeDirector.now() - _last_move_end <= Tuning.STRING_RESET:
		return _last_move_id
	return &""

func _start_press(action: int, id: StringName, press_t: float) -> void:
	var m := MoveLibrary.get_move(id)
	if m == null:
		return
	var lock: Fighter = null
	if m.ground_hit and id != &"hammer_fist":
		lock = _punt_target()
		if lock != null:
			fighter.snap_facing(lock.get_ground_position() - fighter.global_position)
	if m.hits_behind:
		_turn_to_back()
	var hold := _hold_enabled(action) and m.chargeable
	_press_action = action if hold else -1
	_press_t = press_t
	_press_released = not (hold and bool(_btn_down.get(action, false)))
	_min_charge = 1 if action == Action.HEAVY and m.chargeable else 0
	_charge_level = 0
	_move_charge = _min_charge if _press_released else 0
	_begin(m, -1.0, true, lock)

## Cancel the current move into a new press (hit cancel or backfist).
func _cancel_into(action: int, id: StringName, now: float) -> void:
	_end_sequence()
	_phase = Phase.IDLE
	_clear_aim()
	_start_press(action, id, float(_btn_time.get(action, now)))

## Cancel rule 1: on HIT, from the end of the active frames for
## MoveData.cancel_window frames, into the string's next move, or into another
## string's starter unless this move is an ender. Rule 2: no cancels on whiff.
## Rule 4: charged moves never hit-cancel.
func _hit_cancel_ok(next_id: StringName) -> bool:
	if _move == null or not _hit_confirmed or _move_charge > 0 or _move.enemy:
		return false
	if _phase != Phase.RECOVERY or _t > Tuning.frames(_move.cancel_window):
		return false
	if graph.is_link(_move.id, next_id):
		return true
	if _move.ender:
		return false
	return graph.is_starter(next_id) or next_id == &"grab"

## Back + P works at any point of a basic (uncharged) move.
func _can_backfist() -> bool:
	if _move_charge > 0 or _phase == Phase.CHARGING or _phase == Phase.HOLDING:
		return false
	if fighter.is_down() or is_hit_stunned() or held_by != null or holding != null:
		return false
	return _phase == Phase.STARTUP or _phase == Phase.ACTIVE or _phase == Phase.RECOVERY

## Cancel rule 3: Block cancels a basic strike's wind-up; it drops a charge.
func _guard_cancels_windup() -> void:
	if _phase == Phase.CHARGING:
		cancel()
		return
	if _phase == Phase.STARTUP and _move != null and _move_charge == 0 and _press_action >= 0 \
			and _move.kind == &"strike":
		cancel()

func _on_top_of(f: Fighter) -> bool:
	var d := f.get_ground_position() - fighter.get_ground_position()
	d.y = 0.0
	return d.length() <= STOMP_RANGE

func _turn_to_back() -> void:
	var fwd := fighter.get_forward()
	var best: Fighter = null
	var best_d := BACKFIST_RANGE
	for opp in Targeting.opponents_of(fighter):
		if opp.is_down():
			continue
		var to := opp.get_ground_position() - fighter.get_ground_position()
		to.y = 0.0
		var d := to.length()
		if d < best_d and (d < 0.05 or fwd.dot(to / d) < 0.2):
			best_d = d
			best = opp
	if best != null:
		fighter.snap_facing(best.get_ground_position() - fighter.global_position)
	else:
		fighter.snap_facing(-fwd)

## A downed opponent (on the floor) within PUNT_RANGE ahead, with no standing
## opponent in kick reach. Else null. Ground finishers (mount punch, stomp,
## punt) hit it.
func _punt_target() -> Fighter:
	var fwd := fighter.get_forward()
	var origin := fighter.get_ground_position()
	var kick := MoveLibrary.get_move(&"sparta_kick")
	var kick_reach := kick.reach * fighter.get_height_scale() + 0.4
	var best: Fighter = null
	var best_d := INF
	for opp in Targeting.opponents_of(fighter):
		var to := opp.get_ground_position() - origin
		to.y = 0.0
		var d := to.length()
		var ahead := d < 0.05 or fwd.dot(to / d) > 0.2
		if not opp.is_down():
			if d <= kick_reach and ahead:
				return null  # a standing opponent is in reach: kick him instead
			continue
		var st := opp.get_state()
		if not (st == RagdollController.State.GROUNDED or st == RagdollController.State.LAUNCHED):
			continue
		if d > PUNT_RANGE or not ahead:
			continue
		var low := opp.get_center_of_mass().y - opp.get_ground_position().y < PUNT_FLOOR_HEIGHT
		if not low and opp != _last_swept:
			continue
		if d < best_d:
			best_d = d
			best = opp
	return best

## Start a move's startup. startup_override < 0 uses the move's frame data.
func _begin(m: MoveData, startup_override := -1.0, emit_start := true, lock: Fighter = null) -> void:
	if m == null:
		return
	var now := TimeDirector.now()
	_move = m
	_phase = Phase.STARTUP
	_t = 0.0
	_startup = startup_override if startup_override >= 0.0 else m.startup_s()
	_active = m.active_s()
	_recovery = m.recovery_s(true)
	_registry.clear()
	_hit_any = false
	_hit_confirmed = false
	_waited = false
	_debris_kicked = false
	_wall_struck = false
	_strike_dash = _dash_momentum_on(now)
	_prev_limb = Vector3.INF
	_prev_limbs.clear()
	_buffer_action = -1
	if m.id != &"back_kick":
		_ai_counter = false
	var approach := _momentum_velocity(now)
	_approach_v = approach
	if _dash_left > 0.0:
		_dash_left = 0.0
		_dash_end_real = now
	# Pursuit follow-up locks onto the flying body.
	if _pursuit_target != null and is_instance_valid(_pursuit_target) and m.kind == &"strike":
		_locked_target = _pursuit_target
		_pursuit_hit = true
		var to := _pursuit_target.get_center_of_mass() - fighter.global_position
		fighter.snap_facing(to)
	elif lock != null:
		_locked_target = lock
		_pursuit_hit = false
	elif m.kind != &"counter":
		_locked_target = null
		_pursuit_hit = false
	_magnet = _find_magnet_target(m)
	_has_magnet = false
	if blocking:
		blocking = false
	if emit_start:
		_seq_id = m.id
	if fighter.animator:
		fighter.animator.play_move(m.anim, _startup, _active,
			m.recovery_s(m.kind != &"grab"))
	if emit_start:
		attack_started.emit(m.id)
	attack_incoming.emit(m.id, time_to_active())
	_update_aim()

# --- Magnetism: strikes pull toward and aim at a target in range ---------------
func _find_magnet_target(m: MoveData) -> Fighter:
	if not (m.kind == &"strike" or m.kind == &"counter"):
		return null
	if _locked_target != null and is_instance_valid(_locked_target) and not _locked_target.is_dead():
		return _locked_target
	var fwd := fighter.get_forward()
	var origin := fighter.get_ground_position()
	var max_d := m.reach * fighter.get_height_scale() + MAGNET_EXTRA
	var best: Fighter = null
	var best_score := INF
	for opp in Targeting.opponents_of(fighter):
		if opp.is_down():
			continue
		var to := opp.get_ground_position() - origin
		to.y = 0.0
		var d := to.length()
		if d > max_d:
			continue
		var dot := fwd.dot(to / d) if d > 0.05 else 1.0
		if dot < 0.5:
			continue
		var score := d * (2.0 - dot)
		if score < best_score:
			best_score = score
			best = opp
	return best

## Per tick: pull velocity during startup (player strikes and the AI counter)
## and the animator's aim target during startup and active.
func _update_magnet() -> void:
	_has_magnet = false
	if _magnet == null and _move != null and (_phase == Phase.STARTUP or (_phase == Phase.ACTIVE and not _hit_any)):
		_magnet = _find_magnet_target(_move)  # an opponent may step into range mid-swing
	var tgt := _magnet
	if tgt == null or _move == null:
		return
	if not is_instance_valid(tgt) or tgt.is_dead() or (tgt.is_down() and tgt != _locked_target):
		_magnet = null
		_clear_aim()
		return
	if _phase != Phase.STARTUP and _phase != Phase.ACTIVE:
		return
	_update_aim()
	if not (fighter.is_player or _ai_counter):
		return
	if _phase == Phase.ACTIVE and _hit_any:
		return  # connected: plant the feet
	var to := tgt.get_ground_position() - fighter.global_position
	to.y = 0.0
	var d := to.length()
	if d < 0.05:
		return
	var dir := to / d
	fighter.face_dir = dir
	var gap := d - _move.reach * fighter.get_height_scale() * MAGNET_GAP
	if gap <= 0.0:
		return
	var left := maxf((_startup - _t) if _phase == Phase.STARTUP else (_active - _t), 1.0 / 60.0)
	var speed := minf(gap / left, MAGNET_MAX_SPEED)
	if speed > _move.lunge_speed:
		_magnet_velocity = dir * speed
		_has_magnet = true

func _update_aim() -> void:
	var tgt := _magnet
	if tgt == null or not is_instance_valid(tgt) or fighter.animator == null:
		return
	if not fighter.animator.has_method(&"set_aim_target"):
		return
	var p := tgt.get_aim_point()
	if _move != null and _move.height < 0.6:
		p = tgt.get_center_of_mass()  # low strikes aim at the hips
	fighter.animator.call(&"set_aim_target", p)
	_aim_set = true

func _clear_aim() -> void:
	if not _aim_set:
		return
	_aim_set = false
	if fighter and fighter.animator and fighter.animator.has_method(&"clear_aim_target"):
		fighter.animator.call(&"clear_aim_target")

# --- Charging (Upgrade 2: hold to charge) --------------------------------------
static func level_for(held: float) -> int:
	var lvl := 0
	for i in Tuning.CHARGE_LEVELS.size():
		if held >= Tuning.CHARGE_LEVELS[i]:
			lvl = i + 1
	return lvl

func _enter_charge(now: float) -> void:
	_phase = Phase.CHARGING
	_charge_level = maxi(level_for(now - _press_t), 1)
	if fighter.animator:
		fighter.animator.hold_pose(_move.charge_hold if _move.charge_hold != &"" else &"power_charge")
		fighter.animator.set_charge_level(_charge_level)  # tremble grows with the level
	GameEvents.charge_started.emit(fighter, _move.id)
	GameEvents.charge_level_changed.emit(fighter, _charge_level)

func _tick_charge(now: float) -> void:
	var held := now - _press_t
	var lvl := maxi(level_for(held), 1)
	if lvl != _charge_level:
		_charge_level = lvl
		if fighter.animator:
			fighter.animator.set_charge_level(lvl)
		GameEvents.charge_level_changed.emit(fighter, lvl)
		if lvl >= 3:
			_glow(_move.limb, 0.0)  # until stopped on release
	_face_soft_target()
	if held >= Tuning.CHARGE_AUTO_RELEASE and _dash_left <= 0.0:
		_press_released = true
		_release_charge()

## Fire the charged move. Jumping or crouching keeps the charge: a jump +
## held K releases as a charged flying kick.
func _release_charge() -> void:
	if _phase != Phase.CHARGING:
		return
	if _dash_left > 0.0:
		_release_after_dash = true  # dashing releases at the end of the dash
		return
	_release_after_dash = false
	var lvl := maxi(_charge_level, _min_charge)
	var m := _move
	var token := _token(_press_action) if _press_action >= 0 else &""
	if token in [ComboGraph.JK, ComboGraph.JP, ComboGraph.CK, ComboGraph.CP]:
		var alt := MoveLibrary.get_move(graph.starters.get(token, m.id))
		if alt != null and alt.chargeable:
			m = alt
	_move_charge = lvl
	_press_released = true
	_drop_glow()
	GameEvents.charge_released.emit(fighter, m.id, lvl)
	_move = m
	_phase = Phase.STARTUP
	_t = 0.0
	_startup = Tuning.frames(CHARGE_RELEASE_FRAMES)
	_active = m.active_s()
	_recovery = m.recovery_s(true)
	_registry.clear()
	_approach_v = _momentum_velocity(TimeDirector.now())
	_strike_dash = _dash_momentum_on(TimeDirector.now())
	if fighter.animator:
		fighter.animator.play_move(m.anim, _startup, _active, _recovery)
	if lvl >= 3:
		_glow(m.limb, CHARGE_GLOW_TIME)
	attack_incoming.emit(m.id, time_to_active())

func _face_soft_target() -> void:
	var t := _soft_target()
	if t == null:
		return
	var to := t.get_ground_position() - fighter.global_position
	to.y = 0.0
	if to.length_squared() > 1e-4:
		fighter.face_dir = to.normalized()

## The camera's soft target, else the opponent ahead, within CHARGE_FACE_RANGE
## (a charge at a wall with nobody near keeps facing the wall).
func _soft_target() -> Fighter:
	var rig := fighter.get_tree().get_first_node_in_group(&"camera_rig") if fighter.is_inside_tree() else null
	if rig != null and rig.has_method(&"get_soft_target"):
		var t := rig.call(&"get_soft_target") as Fighter
		if t != null and is_instance_valid(t) and not t.is_dead() and t.team != fighter.team \
				and t.get_ground_position().distance_to(fighter.get_ground_position()) <= CHARGE_FACE_RANGE:
			return t
	return Targeting.pick_target(fighter, fighter.get_forward(), CHARGE_FACE_RANGE)

func _glow(bone: StringName, duration: float) -> void:
	_drop_glow()
	if BloodFX.has_method(&"limb_glow"):
		var h = BloodFX.call(&"limb_glow", fighter, bone, CHARGE_GLOW_COLOR, duration, 1.0)
		_charge_glow = h as Node3D

func _drop_glow() -> void:
	if _charge_glow != null and is_instance_valid(_charge_glow):
		if _charge_glow.has_method(&"stop"):
			_charge_glow.call(&"stop")
		else:
			_charge_glow.queue_free()
	_charge_glow = null

func _dash_momentum_on(now: float) -> bool:
	return _dash_left > 0.0 or now - _dash_end_real <= Tuning.DASH_MOMENTUM_TIME

func _momentum_velocity(now: float) -> Vector3:
	var v := Vector3(fighter.velocity.x, 0.0, fighter.velocity.z)
	if _dash_left > 0.0 or now - _dash_end_real <= Tuning.DASH_MOMENTUM_TIME:
		if _dash_velocity.length() > v.length():
			v = _dash_velocity
	return v

# =============================================================================
# Phase machine
# =============================================================================

func _advance(delta: float) -> void:
	_t += delta
	if _phase == Phase.STARTUP:
		# Still held: past Tuning.HOLD_THRESHOLD it charges; before that the
		# strike waits at the end of its startup for the release.
		if _press_action >= 0 and not _press_released:
			if TimeDirector.now() - _press_t >= Tuning.HOLD_THRESHOLD:
				_enter_charge(TimeDirector.now())
				return
			if _t >= _startup:
				_t = _startup
				_waited = true
				return
		if _t < _startup:
			return
		if _waited and fighter.animator:
			# The strike waited for the release: snap the pose to it now.
			fighter.animator.play_move(_move.anim, Tuning.frames(1), _active, _move.recovery_s(_move.kind != &"grab"))
		_waited = false
		_t -= _startup
		_enter_active()
		if _phase != Phase.ACTIVE:
			return
	if _phase == Phase.ACTIVE:
		if _move.kind == &"grab":
			_detect_grab()
			if _phase != Phase.ACTIVE:
				return
		elif _move.kind == &"strike" or _move.kind == &"counter":
			_detect_hits()
		if _t < _active:
			return
		_t -= _active
		_enter_recovery()
		if _phase != Phase.RECOVERY:
			return
	if _phase == Phase.RECOVERY:
		if _t >= _recovery:
			_finish()

func _enter_active() -> void:
	_phase = Phase.ACTIVE
	_active_start_real = TimeDirector.now()
	_prev_limb = _limb_point()
	_prev_limbs.clear()
	if _move.kind == &"strike" or _move.kind == &"counter":
		_check_perfect_dodges()
	attack_active.emit(_move.id)
	GameEvents.attack_active.emit(fighter, _move.id)
	if _move.kind == &"projectile":
		_spawn_projectile()
		_hit_any = true

func _enter_recovery() -> void:
	if not _hit_any and _move.kind in [&"strike", &"grab", &"counter"]:
		GameEvents.attack_whiff.emit(fighter, _move.id)
	_phase = Phase.RECOVERY
	_recovery = _move.recovery_s(_hit_any)
	_clear_aim()
	if _buffer_action >= 0:
		_fire_buffer(TimeDirector.now())

func _finish() -> void:
	if _move != null:
		_last_move_id = _move.id
		_last_move_end = TimeDirector.now()
	_phase = Phase.IDLE
	_press_action = -1
	_move_charge = 0
	_locked_target = null
	_magnet = null
	_clear_aim()
	if _pursuit_hit:
		_end_pursuit()
	_pursuit_hit = false
	_end_sequence()
	_update_block_state()

func _end_sequence() -> void:
	if _seq_id != &"":
		var id := _seq_id
		_seq_id = &""
		attack_ended.emit(id)

## Abort the current move (got hit, launched, died).
func cancel() -> void:
	if holding != null or _limb_grab != null:
		drop_hold()
	var was_busy := _phase != Phase.IDLE
	_phase = Phase.IDLE
	_registry.clear()
	_locked_target = null
	_pursuit_hit = false
	_dash_left = 0.0
	_has_chase = false
	_magnet = null
	_has_magnet = false
	_clear_aim()
	_press_action = -1
	_press_released = true
	_move_charge = 0
	_release_after_dash = false
	_drop_glow()
	if was_busy:
		_end_sequence()
		if fighter and fighter.animator:
			fighter.animator.cancel()
	blocking = false

func _cancel_quiet() -> void:
	var was_busy := _phase != Phase.IDLE
	_phase = Phase.IDLE
	_press_action = -1
	_press_released = true
	_move_charge = 0
	_drop_glow()
	_registry.clear()
	_magnet = null
	_has_magnet = false
	_clear_aim()
	if was_busy:
		_end_sequence()

## Release a held victim without throwing (holder got hit).
func drop_hold() -> void:
	if _limb_grab != null:
		if is_instance_valid(_limb_grab) and _limb_grab.is_active():
			_limb_grab.drop()  # let go without a fling
		_end_limb_grab()
		return
	if holding == null:
		return
	var v := holding
	_release_hold_links()
	if is_instance_valid(v) and v.combat:
		v.combat._on_released()
	if _phase == Phase.HOLDING:
		_phase = Phase.IDLE
		_end_sequence()
		if fighter.animator:
			fighter.animator.release_pose()

# --- Reactions (called by Fighter.flinch / stagger / launch) --------------------
func on_reaction(reaction: int, stun: float) -> void:
	cancel()
	_buffer_action = -1
	_pending_counter = null
	drop_debris()
	if held_by != null:
		var g := held_by
		if is_instance_valid(g) and g.combat:
			g.combat.drop_hold()
		held_by = null
	if _vanished or _vanish_until > 0.0:
		_reappear()
	_end_pursuit()
	match reaction:
		HitInfo.Reaction.FLINCH, HitInfo.Reaction.STAGGER:
			_stun_left = maxf(_stun_left, stun)
			_stun_kind = Stun.HIT
		HitInfo.Reaction.LAUNCH:
			_stun_left = 0.0
			_stun_kind = Stun.NONE

func on_death() -> void:
	cancel()
	_pending_counter = null
	drop_debris()
	_clear_aim()
	if held_by != null and is_instance_valid(held_by) and held_by.combat:
		held_by.combat.drop_hold()
	held_by = null
	_stun_left = 0.0
	_block_held = false
	blocking = false
	_end_pursuit()

func _on_stun_end() -> void:
	var was := _stun_kind
	_stun_kind = Stun.NONE
	if (was == Stun.STUMBLE or was == Stun.DAZE) and fighter.animator \
			and fighter.get_state() == RagdollController.State.ANIMATED and not is_blocking():
		fighter.animator.release_pose()
	if fighter.animator and fighter.get_state() == RagdollController.State.ANIMATED:
		if is_blocking():
			fighter.animator.hold_pose(&"block")
			blocking = true

func _update_block_state() -> void:
	var want := is_blocking()
	if want == blocking:
		return
	blocking = want
	if fighter.animator == null:
		return
	if want:
		fighter.animator.hold_pose(&"block")
	elif _phase == Phase.IDLE and _stun_left <= 0.0 and held_by == null:
		fighter.animator.release_pose()

# =============================================================================
# Hit detection (attacker side)
# =============================================================================

func _limb_point() -> Vector3:
	if _move == null:
		return Vector3.INF
	return _bone_point(_move.limb)

## Striking point of a bone: the fist for hands, else the bone origin.
func _bone_point(bone: StringName) -> Vector3:
	if not _rig_ready():
		return Vector3.INF
	if String(bone).ends_with("Hand") and fighter.rig.has_method(&"get_fist_position"):
		return fighter.rig.call(&"get_fist_position", bone)
	return fighter.rig.get_bone_global_position(bone)

func _rig_ready() -> bool:
	return fighter.rig != null and fighter.rig.skeleton != null

func _detect_hits() -> void:
	var space := fighter.get_world_3d().direct_space_state
	var found := {}  # Fighter -> [dist, bone, pos]
	var m := _move
	var hs := fighter.get_height_scale()
	# 1. Striking limbs (PoseLibrary.STRIKE_BONES), each swept from the previous tick.
	_q_sphere.radius = m.limb_radius
	for bone in m.strike_limbs():
		var limb := _bone_point(bone)
		if limb == Vector3.INF:
			break
		var prev: Vector3 = _prev_limbs.get(bone, limb)
		var seg := limb - prev
		var n := clampi(int(ceil(seg.length() / maxf(m.limb_radius, 0.05))), 1, 8)
		for i in n + 1:
			var p := prev.lerp(limb, float(i) / float(n))
			_query(space, _q_sphere, Transform3D(Basis(), p), p, found)
		_prev_limbs[bone] = limb
	# 2. Fallback: chest-height capsule forward along facing to the move's reach.
	var fwd := fighter.get_forward()
	var base := fighter.global_position + Vector3.UP * m.height * hs
	var a := base + fwd * 0.2
	var reach_len := m.reach * hs
	if _magnet != null and is_instance_valid(_magnet):
		reach_len += MAGNET_REACH_BONUS
	var b := base + fwd * reach_len
	var mid := (a + b) * 0.5
	_q_capsule.radius = m.reach_radius
	_q_capsule.height = maxf((b - a).length() + m.reach_radius * 2.0, m.reach_radius * 2.0 + 0.01)
	# Capsule axis is local Y; rotate it onto the facing direction.
	var basis := Basis(Quaternion(Vector3.UP, fwd))
	_query(space, _q_capsule, Transform3D(basis, mid), b, found)
	# 3. Locked target (teleport counter, pursuit follow-up) connects if close enough.
	var lt := _locked_target
	if lt != null and is_instance_valid(lt) and _valid_victim(lt) and not found.has(lt):
		var reach := (PURSUIT_REACH if _pursuit_hit else m.reach * hs + LOCKED_TARGET_REACH)
		var com := lt.get_center_of_mass()
		var flat := Vector3(com.x - fighter.global_position.x, 0.0, com.z - fighter.global_position.z)
		if flat.length() <= reach and absf(com.y - base.y) < 3.0:
			found[lt] = [0.0, m.target_bone, com]
	for victim: Fighter in found:
		if not is_instance_valid(victim) or _registry.has(victim.get_instance_id()):
			continue
		var rec: Array = found[victim]
		_deliver(victim, rec[1], rec[2])
		if _phase != Phase.ACTIVE:
			return
	if found.is_empty() and not _hit_any:
		_try_wall_strike(space)
	if found.is_empty() and not _hit_any:
		_try_debris_kick()

# --- Wall strikes (Round 3): the player's punches and kicks hit walls ---------
## A player strike that reaches world geometry with a `receive_strike` method
## (Destructible panels, pillars, props, outer walls) strikes it once per move.
## Fighters win: nothing is struck while an opponent is in the move's reach.
func _try_wall_strike(space: PhysicsDirectSpaceState3D) -> void:
	if _wall_struck or not fighter.is_player or _move == null:
		return
	if _move.kind != &"strike" or _move.on_held or _move.ground_hit:
		return
	if _opponent_in_reach():
		return
	var contact := _wall_contact(space)
	if contact.is_empty():
		return
	var target: Node = contact["target"]
	var pos: Vector3 = contact["position"]
	var normal: Vector3 = contact["normal"]
	var dir := fighter.get_forward()
	var power := strike_power()
	_wall_struck = true
	_hit_any = true  # no whiff (and no whiff recovery) off a wall
	var result: Variant = target.call(&"receive_strike", fighter, pos, dir, power)
	var res: StringName = result if result is StringName else &"hold"
	last_wall_strike = {"target": target, "position": pos, "normal": normal, "power": power, "result": res}
	_wall_feel(res, normal)

## Strike power on a wall: move damage x charge x dash momentum (Tuning, Wall strikes).
func strike_power() -> float:
	if _move == null:
		return 0.0
	var p := _move.damage * Tuning.CHARGE_DAMAGE[clampi(_move_charge, 0, 3)]
	if _strike_dash:
		p *= 1.0 + Tuning.STRIKE_DASH_BONUS
	return p

func _wall_feel(result: StringName, normal: Vector3) -> void:
	var broke := result == &"break" or result == &"hole"
	var stop := Tuning.STRIKE_HITSTOP * (STRIKE_BREAK_HITSTOP_MULT if result == &"break" else 1.0)
	fighter.freeze_hitstop(stop)  # attacker only
	if result in [&"hold", &"chip", &"crack"]:
		var back := Vector3(normal.x, 0.0, normal.z)
		if back.length_squared() < 1e-4:
			back = -fighter.get_forward()
		_fighter_call(&"knockback", [back.normalized() * Tuning.STRIKE_RECOIL, STRIKE_RECOIL_TIME])
	GameEvents.screen_shake.emit(Tuning.STRIKE_SHAKE * (2.0 if broke else 1.0))

## An opponent the current move could still hit (the fighter wins over a wall).
func _opponent_in_reach() -> bool:
	var reach := _move.reach * fighter.get_height_scale() + STRIKE_FIGHTER_MARGIN
	var fwd := fighter.get_forward()
	for opp in Targeting.opponents_of(fighter):
		if _registry.has(opp.get_instance_id()) or not _height_connects(opp):
			continue
		var to := opp.get_ground_position() - fighter.get_ground_position()
		to.y = 0.0
		var d := to.length()
		if d <= reach and (d < 0.05 or fwd.dot(to / d) > 0.3):
			return true
	return false

## Contact with a strikeable world node: the striking limbs first (the same
## limb points the fighter query uses), else a ray along facing at the move's
## height to its reach. Floors (normal mostly up) and nodes without
## receive_strike are ignored. {} when nothing.
func _wall_contact(space: PhysicsDirectSpaceState3D) -> Dictionary:
	var m := _move
	var hs := fighter.get_height_scale()
	var fwd := fighter.get_forward()
	var mask := Layers.WORLD | Layers.DESTRUCTIBLE
	for bone in m.strike_limbs():
		var limb := _bone_point(bone)
		if limb == Vector3.INF:
			break
		_q_sphere.radius = m.limb_radius + 0.05
		_q_params.shape = _q_sphere
		_q_params.transform = Transform3D(Basis(), limb)
		_q_params.collide_with_areas = false
		_q_params.collide_with_bodies = true
		_q_params.collision_mask = mask
		for r in space.intersect_shape(_q_params, 8):
			var target := _strike_target(r.get("collider") as Node)
			if target == null:
				continue
			var hit := _ray_to(space, limb - fwd * 0.6, limb + fwd * (m.limb_radius + 0.2), target)
			if hit.is_empty():
				# The limb is inside the surface: ask the solver for the contact normal.
				var rest := space.get_rest_info(_q_params)
				if rest.is_empty() or _strike_target(instance_from_id(rest.get("collider_id", 0)) as Node) != target:
					continue
				hit = {"position": rest["point"], "normal": rest["normal"]}
			if absf((hit["normal"] as Vector3).y) > FLOOR_NORMAL_Y:
				continue
			hit["target"] = target
			return hit
	# Fallback: facing ray at the move's height (poses that stop short of the wall).
	var base := fighter.global_position + Vector3.UP * m.height * hs
	var reach := m.reach * hs + m.reach_radius * 0.5
	var ray := PhysicsRayQueryParameters3D.create(base, base + fwd * reach, mask, [fighter.get_rid()])
	for _i in 3:
		var h := space.intersect_ray(ray)
		if h.is_empty():
			break
		var tgt := _strike_target(h.get("collider") as Node)
		var n: Vector3 = h["normal"]
		if tgt != null and absf(n.y) <= FLOOR_NORMAL_Y:
			return {"target": tgt, "position": h["position"], "normal": n}
		var ex: Array[RID] = ray.exclude
		ex.append(h["rid"])
		ray.exclude = ex
	return {}

## Ray toward `target` only (other colliders are skipped).
func _ray_to(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, target: Node) -> Dictionary:
	var ray := PhysicsRayQueryParameters3D.create(from, to, Layers.WORLD | Layers.DESTRUCTIBLE, [fighter.get_rid()])
	for _i in 4:
		var h := space.intersect_ray(ray)
		if h.is_empty():
			return {}
		if _strike_target(h.get("collider") as Node) == target:
			return {"position": h["position"], "normal": h["normal"]}
		var ex: Array[RID] = ray.exclude
		ex.append(h["rid"])
		ray.exclude = ex
	return {}

## The first node on `n` or its ancestors with receive_strike (never a fighter).
static func _strike_target(n: Node) -> Node:
	while n != null:
		if n is Fighter:
			return null
		if n.has_method(&"receive_strike"):
			return n
		n = n.get_parent()
	return null

## The player's kick sweeping through a large debris chunk kicks it at the
## soft target (or straight ahead) as a projectile.
func _try_debris_kick() -> void:
	if _debris_kicked or not fighter.is_player or _move == null:
		return
	if not (_move.id == &"sparta_kick" or _move.id == &"punt"):
		return
	var foot := _bone_point(&"RightFoot")
	if foot == Vector3.INF:
		foot = fighter.global_position + fighter.get_forward() * 0.8 + Vector3.UP * 0.4
	var low := Vector3(foot.x, fighter.global_position.y + 0.25, foot.z)
	var body := DebrisManager.find_nearest(foot, DEBRIS_KICK_RADIUS, true)
	if body == null:
		body = DebrisManager.find_nearest(low, DEBRIS_KICK_RADIUS, true)
	if body == null or not is_instance_valid(body):
		return
	_debris_kicked = true
	_hit_any = true
	DebrisManager.release(body)
	var aim := Vector3.INF
	var rig := fighter.get_tree().get_first_node_in_group(&"camera_rig")
	if rig != null and rig.has_method(&"get_soft_target"):
		var t := rig.call(&"get_soft_target") as Fighter
		if t != null and is_instance_valid(t) and not t.is_dead() and t.team != fighter.team:
			aim = t.get_aim_point() - Vector3.UP * 0.2
	if aim == Vector3.INF:
		var t2 := Targeting.pick_target(fighter, fighter.get_forward(), 20.0)
		if t2 != null and fighter.get_forward().dot((t2.get_ground_position() - fighter.global_position).normalized()) > 0.5:
			aim = t2.get_aim_point() - Vector3.UP * 0.2
	var v: Vector3
	if aim != Vector3.INF:
		v = ThrownChunk.ballistic_velocity(body.global_position, aim, DEBRIS_KICK_SPEED, body.gravity_scale)
	else:
		v = fighter.get_forward() * DEBRIS_KICK_SPEED + Vector3.UP * 3.0
	ThrownChunk.launch_body(body, v, fighter, DEBRIS_KICK_DAMAGE, &"debris_kick")

func _query(space: PhysicsDirectSpaceState3D, shape: Shape3D, xform: Transform3D,
		ref: Vector3, found: Dictionary) -> void:
	_q_params.shape = shape
	_q_params.transform = xform
	_q_params.collide_with_areas = true
	_q_params.collide_with_bodies = false
	_q_params.collision_mask = Layers.HURTBOX
	for r in space.intersect_shape(_q_params, 32):
		var area := r.get("collider") as Area3D
		if area == null or not area.has_meta(&"fighter"):
			continue
		var f := area.get_meta(&"fighter") as Fighter
		if not _valid_victim(f):
			continue
		var p := area.global_position
		if area.get_child_count() > 0 and area.get_child(0) is Node3D:
			p = (area.get_child(0) as Node3D).global_position
		var d := p.distance_to(ref)
		if not found.has(f) or (found[f][0] as float) > d:
			found[f] = [d, area.get_meta(&"bone"), p]

func _valid_victim(f: Fighter) -> bool:
	if f == null or not is_instance_valid(f) or f == fighter or f.team == fighter.team \
			or f.is_dead() or _registry.has(f.get_instance_id()):
		return false
	return _height_connects(f)

## Highs pass over a crouching fighter; lows under a jumping one.
func _height_connects(f: Fighter) -> bool:
	if _move == null or not (_move.kind == &"strike" or _move.kind == &"counter"):
		return true
	var lvl := _effective_level()
	if lvl == HitInfo.Level.HIGH and f.is_crouching():
		return false
	if lvl == HitInfo.Level.LOW and f.is_airborne():
		return false
	return true

func _deliver(victim: Fighter, bone: StringName, pos: Vector3) -> void:
	_registry[victim.get_instance_id()] = true
	var info := _build_hit(victim, bone, pos)
	var result := victim.take_hit(info)
	_hit_any = true
	last_dealt = info
	hit_dealt.emit(info)
	if result == HitInfo.Result.HIT and not info.get_meta(&"armored", false):
		_hit_confirmed = true
		_commit_combo(info)
		if info.get_meta(&"trip", false):
			_combo_tripped[victim.get_instance_id()] = true
		if _move != null and _move.sweep:
			_last_swept = victim
		if _move != null and _move.ground_hit and victim.combat and victim.is_down():
			if info.reaction != HitInfo.Reaction.NONE:
				victim.combat.getup_extended = true  # the one extension of this knockdown
			if _move.is_kick:
				victim.combat.downed_kicked = true
			else:
				victim.combat.downed_hits += 1
				# Keep the body down for the finisher: at most once per knockdown.
				if info.reaction != HitInfo.Reaction.NONE and victim.ragdoll \
						and victim.ragdoll.has_method(&"delay_getup"):
					victim.ragdoll.call(&"delay_getup", GROUND_HOLD)
		if info.reaction == HitInfo.Reaction.LAUNCH:
			_last_launch_victim = victim
			_last_launch_time = TimeDirector.now()
			if fighter.is_player and info.kind == &"strike" and not _pursuit_hit:
				fighter.add_focus(Tuning.FOCUS_LAUNCH_LANDS)
			if _pursuit_hit and victim == _locked_target:
				_refund_victim = victim
				_refund_until = TimeDirector.now() + 4.0
		if _pursuit_hit and victim == _locked_target:
			_end_pursuit()

## A landed hit extends the combo (Tuning.COMBO_DROP) and reports it.
func _commit_combo(info: HitInfo) -> void:
	var now := TimeDirector.now()
	if now - _combo_last > Tuning.COMBO_DROP:
		if _combo_count > 0:
			GameEvents.combo_ended.emit(fighter, _combo_count)
		_combo_count = 0
		_combo_tripped.clear()
	_combo_count += 1
	_combo_last = now
	info.combo_index = _combo_count
	GameEvents.combo_progress.emit(fighter, _combo_count, info.damage_scale)

## Attacker side of the hit pipeline: steps 3 (power) and the HitInfo.
## Upgrade 2 order: charge level, zone, sweep outcome, the victim's state
## (dazed, juggle, air counter), launch shape (lift, sideways, flattened toward
## the wall), combo damage scaling, then speed is power.
func _build_hit(victim: Fighter, bone: StringName, pos: Vector3) -> HitInfo:
	var m := _move
	var info := HitInfo.new()
	info.attacker = fighter
	info.victim = victim
	info.move_id = m.id
	info.kind = m.kind
	var d := victim.get_ground_position() - fighter.get_ground_position()
	d.y = 0.0
	if m.kind == &"counter" or d.length() < 0.05:
		d = fighter.get_forward()
	info.hit_direction = d.normalized()
	info.hit_position = pos
	var zone := _strike_zone()
	info.zone = zone
	info.hit_bone = m.target_bone if (m.sweep or m.force_bone) else bone
	if m.sweep and bone in [&"LeftLowerLeg", &"RightLowerLeg"]:
		info.hit_bone = bone
	elif fighter.is_player and zone != BodyZones.Zone.TORSO and not m.force_bone:
		info.hit_bone = fighter.aim_bone
	info.level = _effective_level()
	var lvl := clampi(_move_charge, 0, 3)
	info.charge_level = lvl
	var dmg := m.damage * Tuning.CHARGE_DAMAGE[lvl]
	var reaction := m.reaction
	var launch := m.launch_speed
	var lift := m.launch_lift
	var fixed := m.fixed_launch
	var up_deg := m.up_angle
	var hitstop := m.hitstop_time() * (1.0 + CHARGE_HITSTOP_BONUS * lvl)
	var finisher := m.is_finisher or lvl >= 3
	var shake := m.shake + 0.08 * lvl
	var flatten := false
	var vc := victim.combat
	# Charge levels (spec: L1 jabs and crosses stagger, L2 any strike launches).
	if lvl == 1 and m.stagger_l1 and reaction == HitInfo.Reaction.FLINCH:
		reaction = HitInfo.Reaction.STAGGER
	if lvl >= 2 and m.kind == &"strike" and not m.sweep and lift <= 0.0 and not m.on_held:
		if reaction != HitInfo.Reaction.LAUNCH:
			reaction = HitInfo.Reaction.LAUNCH
			launch = CHARGE_LAUNCH_MIN[lvl]
			fixed = false
		else:
			launch = maxf(launch * CHARGE_LAUNCH_MULT[lvl], CHARGE_LAUNCH_MIN[lvl])
	if lvl >= 2 and lift > 0.0:
		lift *= 1.0 + 0.25 * (lvl - 1)
	# Zones (player aim; enemies strike the torso).
	if zone == BodyZones.Zone.HEAD:
		dmg *= Tuning.ZONE_HEAD_DAMAGE
		info.set_meta(&"stun_mult", HEAD_STUN_MULT)
		if lvl >= 2 and m.kind == &"strike" and not victim.is_down():
			reaction = HitInfo.Reaction.NONE  # a charged head hit dazes instead of launching
			info.set_meta(&"daze", true)
	elif zone == BodyZones.Zone.LEGS:
		info.set_meta(&"leg_slow", true)
	if _arm_broken_for(m.limb):
		dmg *= ARM_BROKEN_DAMAGE
	# Ordinary strikes never relaunch a body lying on the floor (anti-infinite);
	# ground finishers keep their designed effect.
	var lying := vc != null and vc.is_lying()
	if lying and m.kind == &"strike" and not m.on_held \
			and (not m.ground_hit or vc.getup_extended):
		# Ordinary strikes, and ground finishers after this knockdown's one
		# extension: damage only.
		reaction = HitInfo.Reaction.NONE
		lift = 0.0
		info.set_meta(&"no_juggle", true)
		info.set_meta(&"lying", true)
	# Sweeps: tap = stumble, L1-2 = trip, L3 = launch upward. One trip per combo:
	# a body already tripped in this combo is only knocked down.
	if lying:
		pass
	elif m.sweep and not m.enemy and victim.is_launched() and _combo_tripped.has(victim.get_instance_id()):
		reaction = HitInfo.Reaction.LAUNCH
		launch = KNOCKDOWN_LAUNCH
		lift = 0.0
		info.set_meta(&"no_juggle", true)
	elif m.sweep and not m.enemy and not victim.is_down():
		var armoured := victim.get_total_mass() > HEAVY_MASS_REF
		if armoured and lvl < 3:
			reaction = HitInfo.Reaction.NONE
		elif lvl == 0 or (armoured and lvl == 3):
			reaction = HitInfo.Reaction.NONE
			info.set_meta(&"stumble", true)
		elif lvl < 3:
			reaction = HitInfo.Reaction.LAUNCH
			if _combo_tripped.has(victim.get_instance_id()):
				launch = KNOCKDOWN_LAUNCH  # second sweep in a combo only knocks down
			else:
				info.set_meta(&"trip", true)
		else:
			reaction = HitInfo.Reaction.LAUNCH
			lift = Tuning.LAUNCHER_LIFT
	# The victim's state.
	var stumbling := vc != null and vc.is_stumbling()
	var tumbling := victim.get_state() == RagdollController.State.LAUNCHED
	if vc != null and vc.is_dazed() and m.kind == &"strike":
		reaction = HitInfo.Reaction.LAUNCH  # the next hit on a dazed fighter always launches
		launch = maxf(launch, DAZED_LAUNCH)
		info.set_meta(&"undaze", true)
		info.remove_meta(&"daze")
		flatten = true
	elif m.kind == &"strike" and not m.on_held and not m.ground_hit and not info.has_meta(&"no_juggle") \
			and (tumbling or (stumbling and (m.is_kick or lvl >= 1))) \
			and not (m.sweep and not m.enemy and tumbling == false):
		info.juggle = true
		info.remove_meta(&"stumble")
		if tumbling and vc != null and vc.juggle_relaunches >= Tuning.JUGGLE_MAX_RELAUNCH:
			# Past the juggle cap: scaled damage only, the body falls.
			reaction = HitInfo.Reaction.NONE
			lift = 0.0
			info.set_meta(&"juggle_capped", true)
		else:
			reaction = HitInfo.Reaction.LAUNCH
			launch = maxf(launch, JUGGLE_MIN_LAUNCH) * Tuning.JUGGLE_LAUNCH
			flatten = lift <= 0.0
	if victim.is_airborne() and m.kind == &"strike" and not lying:
		info.air_counter = true
		reaction = HitInfo.Reaction.LAUNCH
		launch = maxf(launch, AIR_COUNTER_MIN) * Tuning.AIR_COUNTER_LAUNCH
	# Combo damage scaling by the hits the VICTIM has taken from anyone
	# (environment damage is never scaled).
	var n := vc.next_taken_index() if vc != null else get_combo_count() + 1
	var scale := combo_scale(n)
	dmg *= scale
	info.damage_scale = scale
	info.combo_index = n
	var mv := victim.get_total_mass()
	var ma := fighter.get_total_mass()
	var pursuit := _pursuit_hit and victim == _locked_target
	if pursuit:
		reaction = HitInfo.Reaction.LAUNCH
		launch = maxf(launch, PURSUIT_MIN_LAUNCH)
		d = victim.get_com_velocity()
		d.y = 0.0
		if d.length() < 0.5:
			d = info.hit_direction
		info.hit_direction = d.normalized()
	if reaction == HitInfo.Reaction.LAUNCH:
		var dir := info.hit_direction
		if m.sideways:
			var right := fighter.get_forward().cross(Vector3.UP).normalized()
			dir = (fighter.get_forward() * 0.4 - right).normalized()
			info.set_meta(&"spin", true)
		if flatten:
			var wd := nearest_wall_dir(victim.get_center_of_mass(), JUGGLE_WALL_RANGE)
			if wd != Vector3.ZERO:
				dir = (dir + wd * 2.0).normalized()
			up_deg = JUGGLE_UP_ANGLE
		if lift > 0.0 and not info.juggle:
			var g: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
			info.launch_velocity = dir * LIFT_HORIZONTAL + Vector3.UP * sqrt(2.0 * g * lift)
		else:
			var speed := launch
			if not pursuit and not fixed:
				speed *= minf(1.0, HEAVY_MASS_REF / mv)
				speed += Tuning.SPEED_POWER_K * ma * maxf(0.0, _approach_v.dot(dir)) / mv
			if victim.is_launched() and victim.flight_launches >= Tuning.PURSUIT_HALF_AT:
				speed *= 0.5
			var forced := info.juggle or info.air_counter or info.has_meta(&"undaze")
			if mv > HEAVY_MASS_REF and speed < HEAVY_MIN_LAUNCH and not victim.is_launched() and not forced:
				reaction = HitInfo.Reaction.STAGGER
				info.set_meta(&"strength", HEAVY_STAGGER_STRENGTH)
			else:
				var up := deg_to_rad(up_deg)
				var flat := Vector3(dir.x, 0.0, dir.z).normalized()
				info.launch_velocity = (flat * cos(up) + Vector3.UP * sin(up)) * speed
		if reaction == HitInfo.Reaction.LAUNCH:
			var v_total := info.launch_velocity
			if victim.is_launched():
				v_total += victim.get_com_velocity()
			info.energy = 0.5 * mv * v_total.length_squared()
	if reaction != HitInfo.Reaction.LAUNCH:
		info.energy = 0.5 * mv * m.nominal_speed * m.nominal_speed * (1.0 + lvl)
	info.damage = dmg * _damage_mult()
	info.reaction = reaction
	info.hitstop = hitstop
	info.unblockable = m.unblockable
	info.is_finisher = finisher
	info.set_meta(&"shake", shake)
	return info

## Zone a strike lands in: the player's aim, else the torso.
func _strike_zone() -> int:
	if fighter.is_player and _move != null and (_move.kind == &"strike" or _move.kind == &"counter"):
		return fighter.aim_zone
	return BodyZones.Zone.TORSO

## Attack height of the current move; strikes aimed at the head are high.
func _effective_level() -> int:
	if _move == null:
		return HitInfo.Level.MID
	if _move.kind == &"strike" and _strike_zone() == BodyZones.Zone.HEAD:
		return HitInfo.Level.HIGH
	return _move.hit_level

## The attacker's limb for this move sits in a broken arm.
func _arm_broken_for(limb: StringName) -> bool:
	if broken_arms.is_empty():
		return false
	return broken_arms.has(BodyZones.of_bone(limb))

## Unit XZ direction to the nearest wall or pillar within max_dist (ZERO if
## none): ImpactResolver.nearest_wall_dir(), with our own ray fan as a
## fallback while it is a stub.
func nearest_wall_dir(from: Vector3, max_dist := JUGGLE_WALL_RANGE) -> Vector3:
	var wd: Vector3 = ImpactResolver.nearest_wall_dir(from, max_dist)
	if wd != Vector3.ZERO:
		return wd
	if fighter == null or not fighter.is_inside_tree():
		return Vector3.ZERO
	var space := fighter.get_world_3d().direct_space_state
	var origin := Vector3(from.x, maxf(from.y, fighter.global_position.y + 0.9), from.z)
	var best := Vector3.ZERO
	var best_d := max_dist
	for i in WALL_RAYS:
		var a := TAU * float(i) / float(WALL_RAYS)
		var dir := Vector3(sin(a), 0.0, cos(a))
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * max_dist,
			Layers.WORLD | Layers.DESTRUCTIBLE)
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var n: Vector3 = hit["normal"]
		if absf(n.y) > 0.6:
			continue  # floor or slope, not a wall
		var dist := origin.distance_to(hit["position"])
		if dist < best_d:
			best_d = dist
			best = dir
	return best

# =============================================================================
# Defender side
# =============================================================================

## Defender side of the hit pipeline. Returns HitInfo.Result.
func receive_hit(info: HitInfo) -> int:
	info.victim = fighter
	last_received = info
	if fighter.is_dead():
		info.result = HitInfo.Result.IGNORED
		return info.result
	var now := TimeDirector.now()
	match info.kind:
		&"throw":
			return _apply_hit(info)
		&"bowl":
			if fighter.is_invulnerable():
				return _ignored(info)
			return _apply_hit(info)
	if now < _vanish_until:
		info.result = HitInfo.Result.DODGED
		last_result = info.result
		return info.result
	if fighter.is_invulnerable():
		return _ignored(info)
	if info.kind == &"projectile" and _try_late_dodge(info.attacker as Fighter, now):
		info.result = HitInfo.Result.DODGED
		last_result = info.result
		return info.result
	if not info.unblockable and _blocks(info):
		return _apply_block(info)
	return _apply_hit(info)

func _ignored(info: HitInfo) -> int:
	info.result = HitInfo.Result.IGNORED
	last_result = info.result
	return info.result

func _blocks(info: HitInfo) -> bool:
	if not (info.kind == &"strike" or info.kind == &"projectile"):
		return false
	# Break-away auto-guard: frontal strikes count as blocked (grabs still work).
	if TimeDirector.now() < _escape_guard_until and _attacker_in_front(info, GUARD_FRONT_DOT) \
			and not fighter.is_down():
		info.set_meta(&"escape_guard", true)
		return true
	if not broken_arms.is_empty() or is_dazed() or is_stumbling():
		return false  # no blocking with a broken arm, dazed or off balance
	var full_power := info.charge_level >= 3 or (info.move_id == &"power_punch" and info.is_finisher)
	var front := _attacker_in_front(info, GUARD_FRONT_DOT)
	if is_blocking():
		# Every guard is a front cone (the player's too). A standing guard stops
		# highs and mids; a crouching guard stops lows (mids hit it).
		if not front or full_power:
			return false
		if fighter.is_crouching():
			if info.level != HitInfo.Level.LOW:
				return false
		elif info.level == HitInfo.Level.LOW:
			return false
		if fighter.config.get("blocks_jabs", false):
			return _is_jab(info) or _is_kick(info)  # Brawler guard: jabs and kicks only
		return true
	if fighter.is_down() or held_by != null or is_hit_stunned():
		return false
	if fighter.get_state() != RagdollController.State.ANIMATED or not front:
		return false
	if info.level == HitInfo.Level.LOW or full_power:
		return false
	if fighter.config.get("blocks_jabs", false) and _is_jab(info):
		if _phase != Phase.ACTIVE and _phase != Phase.RECOVERY:
			return true
	if fighter.config.get("front_block", false):
		return true  # Shield: every strike from the front
	return false

func _attacker_in_front(info: HitInfo, min_dot: float) -> bool:
	var to_attacker := -info.hit_direction
	var att := info.attacker as Fighter
	if att != null and is_instance_valid(att) and info.kind != &"projectile":
		to_attacker = att.get_ground_position() - fighter.get_ground_position()
	to_attacker.y = 0.0
	if to_attacker.length_squared() < 1e-4:
		return true
	return fighter.get_forward().dot(to_attacker.normalized()) > min_dot

static func _is_jab(info: HitInfo) -> bool:
	return String(info.move_id).begins_with("jab") or info.move_id == &"cross"

static func _is_kick(info: HitInfo) -> bool:
	var m := MoveLibrary.get_move(info.move_id)
	return m != null and m.is_kick and not m.sweep

## Tell armor of the move in progress (0 when not in startup/active).
func get_armor_level() -> int:
	if _move == null or not (_phase == Phase.STARTUP or _phase == Phase.ACTIVE):
		return 0
	if fighter.is_player:
		return _move.armor
	return _move.armor + int(fighter.config.get("armor_bonus", 0))

func _apply_block(info: HitInfo) -> int:
	info.result = HitInfo.Result.BLOCKED
	last_result = info.result
	var m := MoveLibrary.get_move(info.move_id)
	var stun := Tuning.frames(m.blockstun if m else 10.0)
	var chip := info.damage * Tuning.BLOCK_DAMAGE_MULT
	info.damage = chip
	info.reaction = HitInfo.Reaction.NONE
	info.launch_velocity = Vector3.ZERO
	var push := m.block_pushback if m else 0.0
	var auto_guard: bool = info.get_meta(&"escape_guard", false)
	if auto_guard:
		push = 0.0  # no blockstun or slide: the break-away keeps the fighter free
	elif _phase == Phase.IDLE:
		# A real guard (or an idle archetype block): blockstun, pushback, block-hit pose.
		var guard := is_blocking()
		_stun_left = maxf(_stun_left, stun)
		_stun_kind = Stun.BLOCK
		_guard_stun = guard
		if push > 0.0:
			var d := Vector3(info.hit_direction.x, 0.0, info.hit_direction.z)
			if d.length_squared() > 1e-4:
				_fighter_call(&"knockback", [d.normalized() * push, BLOCK_PUSH_TIME])
		if fighter.animator:
			fighter.animator.play_move(&"block_hit", Tuning.frames(2), Tuning.frames(2), maxf(stun - Tuning.frames(4), 0.05))
		blocking = false  # re-held when blockstun ends
	# Mid-move archetype block (Brawler vs jabs, Shield from the front): the
	# hit is absorbed and the move carries on.
	var att := info.attacker as Fighter
	var who: Array = [fighter]
	if att != null and is_instance_valid(att):
		who.append(att)
	TimeDirector.hitstop(who, Tuning.HITSTOP[&"jab"])
	fighter.apply_damage(chip, &"block", info)
	GameEvents.hit_blocked.emit(info)
	if not fighter.is_player and not fighter.is_dead() and not auto_guard:
		var now := TimeDirector.now()
		_blocked_hits = _blocked_hits + 1 if now - _blocked_last <= BLOCKED_HITS_WINDOW else 1
		_blocked_last = now
		if _blocked_hits >= Tuning.DAZE_BLOCKED_HITS:
			_blocked_hits = 0
			apply_daze(Tuning.DAZED_TIME)  # guard broken
	GameEvents.screen_shake.emit(0.03 + (0.05 if push > 0.0 else 0.0))
	hit_received.emit(info)
	return info.result

func _apply_hit(info: HitInfo) -> int:
	info.result = HitInfo.Result.HIT
	last_result = info.result
	var att := info.attacker as Fighter
	# Hitting the attacking arm during a wind-up cancels the attack (armour or not).
	var arm_cancel := ARM_HIT_CANCEL and BodyZones.is_arm(info.zone) and _phase == Phase.STARTUP \
		and _move != null and BodyZones.of_bone(_move.limb) == info.zone
	if arm_cancel and info.reaction == HitInfo.Reaction.NONE:
		info.reaction = HitInfo.Reaction.FLINCH
	# Tell armor: flinches (armor 1) and staggers (armor 2) are absorbed during
	# startup/active; launches always go through.
	if info.kind != &"throw" and info.kind != &"bowl" and held_by == null and not arm_cancel:
		var armor := get_armor_level()
		if (info.reaction == HitInfo.Reaction.FLINCH and armor >= 1) \
				or (info.reaction == HitInfo.Reaction.STAGGER and armor >= 2):
			return _apply_armor(info)
	if held_by != null and info.kind != &"throw":
		if is_instance_valid(held_by) and held_by.combat:
			held_by.combat.drop_hold()
		held_by = null
	if holding != null:
		drop_hold()
	var lethal := info.damage >= fighter.hp
	var strength: float = info.get_meta(&"strength", 1.0)
	var m := MoveLibrary.get_move(info.move_id)
	if arm_cancel:
		cancel()
	# Anti-infinite (every fighter): hits taken from anyone, stun decay, break-away.
	var n := next_taken_index()
	var decay := stun_decay(n)
	var escape := not lethal and _breakaway_due(info, m, n, decay)
	_register_taken()
	if escape:
		_break_away(info, att)
	elif info.juggle and info.reaction == HitInfo.Reaction.LAUNCH:
		juggle_relaunches += 1
	match info.reaction if not escape else HitInfo.Reaction.NONE:
		HitInfo.Reaction.LAUNCH:
			fighter.launch(info.launch_velocity, info.hit_position, info.hit_bone)
			if m != null and m.sweep:
				_sweep_legs(info.hit_direction)
			if info.get_meta(&"spin", false):
				fighter.ragdoll.apply_limb_spin(info.launch_velocity.normalized(), ROUNDHOUSE_SPIN)
			if info.get_meta(&"trip", false):
				GameEvents.tripped.emit(fighter)
		HitInfo.Reaction.STAGGER:
			if not lethal:
				var st: float = info.get_meta(&"strength", STAGGER_STRENGTH)
				fighter.stagger(info.hit_direction, st * decay)
				_set_hit_stun(STAGGER_TIME * st * decay)
		HitInfo.Reaction.FLINCH:
			if not lethal:
				fighter.flinch(info.hit_direction, info.hit_bone, strength)
				var stun_mult: float = info.get_meta(&"stun_mult", 1.0)
				_set_hit_stun((m.hitstun if m != null else Tuning.FLINCH_TIME) * stun_mult * decay)
		HitInfo.Reaction.NONE:
			if not lethal and not escape and info.get_meta(&"stumble", false):
				apply_stumble(Tuning.STUMBLE_TIME * decay)
				_taken_stun += Tuning.STUMBLE_TIME * decay
			elif not lethal and not escape and info.get_meta(&"daze", false):
				apply_daze(Tuning.DAZED_TIME * decay)
				_taken_stun += Tuning.DAZED_TIME * decay
	if not lethal:
		_apply_zone_damage(info)
	# Local hitstop (after a launch so RagdollController.freeze holds the launch).
	# A hit that does nothing to a downed body freezes only the attacker, so
	# the body's grounding and get-up timers keep running.
	if info.hitstop > 0.0:
		var who: Array = []
		if not (fighter.is_down() and info.reaction == HitInfo.Reaction.NONE):
			who.append(fighter)
			_fighter_call(&"set_hitstop_jitter", [])
		if att != null and is_instance_valid(att):
			who.append(att)
		TimeDirector.hitstop(who, info.hitstop)
	fighter.apply_damage(info.damage, info.move_id, info)
	GameEvents.hit_landed.emit(info)
	hit_received.emit(info)
	var trauma: float = info.get_meta(&"shake", 0.1)
	if info.reaction == HitInfo.Reaction.LAUNCH:
		trauma = maxf(trauma, clampf(info.energy / LAUNCH_SHAKE_ENERGY, 0.1, 0.7))
		if info.energy >= Tuning.BIG_LAUNCH_ENERGY:
			TimeDirector.request_slowmo(Tuning.BIG_LAUNCH_SLOWMO.x, Tuning.BIG_LAUNCH_SLOWMO.y,
				TimeDirector.PRIO_BIG_LAUNCH)
	GameEvents.screen_shake.emit(trauma)
	return info.result

func _apply_armor(info: HitInfo) -> int:
	_register_taken()
	info.set_meta(&"armored", true)
	info.reaction = HitInfo.Reaction.NONE
	info.launch_velocity = Vector3.ZERO
	var att := info.attacker as Fighter
	var who: Array = [fighter]
	if att != null and is_instance_valid(att):
		who.append(att)
	TimeDirector.hitstop(who, ARMOR_HITSTOP)
	_fighter_call(&"flash_white", [])
	AudioFX.play(&"clank", info.hit_position if info.hit_position != Vector3.ZERO else fighter.get_aim_point(),
		0.0, 1.0, fighter)
	fighter.apply_damage(info.damage, info.move_id, info)
	GameEvents.armor_absorbed.emit(info)
	GameEvents.screen_shake.emit(0.04)
	hit_received.emit(info)
	return info.result

# --- Anti-infinite (victim side) ---------------------------------------------------
## Hits this fighter has taken in the current combo (from anyone, no COMBO_DROP gap).
func hits_taken() -> int:
	return _taken if TimeDirector.now() - _taken_last <= Tuning.COMBO_DROP else 0

## 1-based number of the next hit this fighter takes (scales its damage).
func next_taken_index() -> int:
	return hits_taken() + 1

func _register_taken() -> void:
	var now := TimeDirector.now()
	if now - _taken_last > Tuning.COMBO_DROP:
		_taken = 0
		_taken_stun = 0.0
	_taken += 1
	_taken_last = now

## Stun multiplier of the n-th hit taken (Tuning.COMBO_STUN_*).
static func stun_decay(n: int) -> float:
	if n < Tuning.COMBO_STUN_DECAY_FROM:
		return 1.0
	return maxf(Tuning.COMBO_STUN_MIN,
		1.0 - Tuning.COMBO_STUN_DECAY * float(n - Tuning.COMBO_STUN_DECAY_FROM + 1))

## Hit stun from a flinch or stagger: set (not extended) and summed for the break-away.
func _set_hit_stun(t: float) -> void:
	_stun_left = t
	_stun_kind = Stun.HIT
	_taken_stun += t

## The hit that would be number Tuning.COMBO_ESCAPE_HITS, or that would push the
## combo's stun past Tuning.COMBO_ESCAPE_STUN, breaks the fighter away. A launch
## ends a loop by itself (unless it is a capped juggle, which is no launch).
func _breakaway_due(info: HitInfo, m: MoveData, n: int, decay: float) -> bool:
	if info.reaction == HitInfo.Reaction.LAUNCH:
		return false
	if not (info.kind == &"strike" or info.kind == &"projectile") or fighter.is_down():
		return false
	if n >= Tuning.COMBO_ESCAPE_HITS:
		return true
	var stun := 0.0
	match info.reaction:
		HitInfo.Reaction.FLINCH:
			stun = (m.hitstun if m != null else Tuning.FLINCH_TIME) * float(info.get_meta(&"stun_mult", 1.0)) * decay
		HitInfo.Reaction.STAGGER:
			stun = STAGGER_TIME * float(info.get_meta(&"strength", STAGGER_STRENGTH)) * decay
		HitInfo.Reaction.NONE:
			if info.get_meta(&"stumble", false):
				stun = Tuning.STUMBLE_TIME * decay
			elif info.get_meta(&"daze", false):
				stun = Tuning.DAZED_TIME * decay
	return stun > 0.0 and _taken_stun + stun >= Tuning.COMBO_ESCAPE_STUN

## Break-away: no stun from this hit, a short auto-guard, the two pushed apart
## (mostly the victim), the count reset, combo_escaped emitted.
func _break_away(info: HitInfo, att: Fighter) -> void:
	var now := TimeDirector.now()
	_taken = 0
	_taken_stun = 0.0
	_stun_left = 0.0
	_stun_kind = Stun.NONE
	_escape_guard_until = now + Tuning.COMBO_ESCAPE_GUARD
	var st := fighter.get_state()
	if (st == RagdollController.State.FLINCH or st == RagdollController.State.STAGGER) and fighter.ragdoll:
		fighter.ragdoll.force_recover()  # regain balance at once
	if fighter.animator and fighter.get_state() == RagdollController.State.ANIMATED and _phase == Phase.IDLE:
		fighter.animator.release_pose()
	var dir := Vector3(info.hit_direction.x, 0.0, info.hit_direction.z)
	if att != null and is_instance_valid(att):
		var to := fighter.get_ground_position() - att.get_ground_position()
		to.y = 0.0
		if to.length_squared() > 1e-4:
			dir = to
	dir = dir.normalized() if dir.length_squared() > 1e-4 else -fighter.get_forward()
	var push := Tuning.COMBO_ESCAPE_PUSH
	_fighter_call(&"knockback", [dir * push * ESCAPE_VICTIM_SHARE / ESCAPE_PUSH_TIME, ESCAPE_PUSH_TIME])
	if att != null and is_instance_valid(att) and att.has_method(&"knockback") and not att.is_down():
		att.knockback(-dir * push * (1.0 - ESCAPE_VICTIM_SHARE) / ESCAPE_PUSH_TIME, ESCAPE_PUSH_TIME)
	info.set_meta(&"escaped", true)
	info.reaction = HitInfo.Reaction.NONE
	GameEvents.combo_escaped.emit(fighter, att)

## Lying on the floor or getting up from it (grounded, getting up, or a
## launched body that has come to rest low): ordinary strikes never relaunch it.
func is_lying() -> bool:
	var st := fighter.get_state()
	if st == RagdollController.State.GROUNDED or st == RagdollController.State.GETUP:
		return true
	if st != RagdollController.State.LAUNCHED:
		return false
	var h := fighter.get_center_of_mass().y - fighter.get_ground_position().y
	return h < LYING_HEIGHT and fighter.get_com_velocity().length() < LYING_SPEED

## Tap sweep: off balance for `duration`, one foot out; cannot attack or block.
## A kick or charged punch in the window knocks the fighter down (juggle).
func apply_stumble(duration: float) -> void:
	if fighter.is_dead() or fighter.is_down():
		return
	cancel()
	_stun_left = maxf(_stun_left, duration)
	_stun_kind = Stun.STUMBLE
	if fighter.animator:
		fighter.animator.hold_pose(_hold_or(&"stumble", &"stagger"))
	GameEvents.stumbled.emit(fighter, duration)

## Hunched, no actions for `duration`; the next hit always launches.
func apply_daze(duration: float) -> void:
	if fighter.is_dead() or fighter.is_down():
		return
	cancel()
	_block_held = false
	_stun_left = maxf(_stun_left, duration)
	_stun_kind = Stun.DAZE
	if fighter.animator:
		fighter.animator.hold_pose(_hold_or(&"dazed", &"stagger"))
	GameEvents.dazed.emit(fighter, duration)

static func _hold_or(id: StringName, fallback: StringName) -> StringName:
	return id if PoseLibrary.HOLDS.has(id) or PoseLibrary.POSES.has(id) else fallback

## Zone effects that build up: arm damage (breaks at Tuning.ARM_BREAK_AT, then
## weaker attacks, no blocking, dazed) and leg hits (slowed).
func _apply_zone_damage(info: HitInfo) -> void:
	var zone := info.zone
	if not BodyZones.is_limb(zone) or info.damage <= 0.0:
		return
	var total: float = limb_damage.get(zone, 0.0) + info.damage
	limb_damage[zone] = total
	GameEvents.limb_damaged.emit(fighter, zone, total)
	if zone == BodyZones.Zone.LEGS or info.get_meta(&"leg_slow", false):
		_leg_slow_left = Tuning.ZONE_LEG_SLOW_TIME
	if BodyZones.is_arm(zone) and total >= Tuning.ARM_BREAK_AT and not broken_arms.has(zone):
		broken_arms[zone] = true
		if fighter.ragdoll:
			fighter.ragdoll.break_arm(zone)
		GameEvents.arm_broken.emit(fighter, zone)
		if not fighter.is_down():
			apply_daze(Tuning.DAZED_TIME)

## Fighter helpers that live in agent H's fighter.gd; skipped if renamed.
func _fighter_call(method: StringName, args: Array) -> void:
	if fighter.has_method(method):
		fighter.callv(method, args)

func is_arm_broken(zone: int) -> bool:
	return broken_arms.has(zone)

## Leg sweep: the legs go out from under the body (Overgrowth sweep).
func _sweep_legs(direction: Vector3) -> void:
	var rig := fighter.rig
	if rig == null:
		return
	var d := Vector3(direction.x, 0.0, direction.z).normalized()
	var axis := d.cross(Vector3.UP)
	fighter.ragdoll.apply_limb_spin(d, 0.6)
	# Next tick, so the ragdoll's own launch velocities are already in.
	await fighter.get_tree().physics_frame
	if not is_instance_valid(fighter):
		return
	for b: StringName in [&"LeftLowerLeg", &"RightLowerLeg", &"LeftFoot", &"RightFoot",
			&"LeftUpperLeg", &"RightUpperLeg"]:
		var pb := rig.get_physical_bone(b)
		if pb == null:
			continue
		var lower := b.ends_with("Foot") or b.ends_with("LowerLeg")
		pb.linear_velocity += d * (3.5 if lower else 1.5) + Vector3.UP * (1.5 if lower else 0.5)
		pb.angular_velocity += axis * Tuning.SWEEP_SPIN * (1.0 if lower else 0.6)

# =============================================================================
# Perfect dodge and teleport counter
# =============================================================================

func _trim_presses(arr: Array[float], now: float) -> void:
	while arr.size() > 0 and now - arr[0] > 1.0:
		arr.remove_at(0)

## Attacker side: at the first active frame, let every opponent in range try a
## perfect dodge (spec: Perfect dodge rules 1 and 3).
func _check_perfect_dodges() -> void:
	var now := TimeDirector.now()
	var dodge_range := _move.reach * fighter.get_height_scale() + DODGE_CHECK_EXTRA
	for opp in Targeting.opponents_of(fighter):
		if opp.combat == null:
			continue
		var dist := opp.get_ground_position().distance_to(fighter.get_ground_position())
		if dist > dodge_range:
			continue
		if opp.combat.try_perfect_dodge(fighter, now):
			_registry[opp.get_instance_id()] = true

## Only the player and fighters with config "perfect_dodge" (the Duelist) can
## perfect-dodge; anyone else's Block press is a plain guard.
func can_perfect_dodge() -> bool:
	return fighter != null and (fighter.is_player or bool(fighter.config.get("perfect_dodge", false)))

## Defender side. `t_active` is the real time the attack went active.
## Returns true if this defender perfect-dodged.
func try_perfect_dodge(attacker: Fighter, t_active: float) -> bool:
	if not can_perfect_dodge():
		return false
	_trim_presses(_block_presses, t_active)
	var in_window := false
	var attempt := false
	var keep: Array[float] = []
	for t in _block_presses:
		var dt := t_active - t
		if dt < -0.001:
			keep.append(t)
			continue
		if dt <= Tuning.PERFECT_DODGE_WINDOW:
			in_window = true
		elif dt <= Tuning.DODGE_ATTEMPT_HORIZON:
			attempt = true
		else:
			keep.append(t)
	if attempt:
		# A press inside the horizon but outside the window: anti-mash lockout.
		_block_presses = keep
		_dodge_lockout_until = maxf(_dodge_lockout_until, t_active + Tuning.DODGE_LOCKOUT)
		GameEvents.dodge_feedback.emit(fighter, &"early")
		return false
	if not in_window:
		return false
	_block_presses = keep
	if t_active < _dodge_lockout_until or not _can_dodge_now():
		return false
	_perfect_dodge(attacker)
	return true

## Projectiles: dodge if block was pressed within the window before contact.
func _try_late_dodge(attacker: Fighter, now: float) -> bool:
	if not can_perfect_dodge() or now < _dodge_lockout_until or not _can_dodge_now():
		return false
	for t in _block_presses:
		var dt := now - t
		if dt >= 0.0 and dt <= Tuning.PERFECT_DODGE_WINDOW:
			_block_presses.clear()
			_perfect_dodge(attacker)
			return true
	return false

## A dodge-eligible Block press while an opponent's attack in range is
## already active: too late. HUD feedback only (the press still guards).
func _check_late_press() -> void:
	if not can_perfect_dodge() or is_vanished() or not _can_dodge_now():
		return
	for opp in Targeting.opponents_of(fighter):
		var oc := opp.combat
		if oc == null or not oc.is_attack_active() or oc._move == null:
			continue
		if not (oc._move.kind == &"strike" or oc._move.kind == &"counter"):
			continue
		var reach := oc._move.reach * opp.get_height_scale() + LATE_DODGE_FEEDBACK_EXTRA
		if opp.get_ground_position().distance_to(fighter.get_ground_position()) <= reach:
			GameEvents.dodge_feedback.emit(fighter, &"late")
			return

func _can_dodge_now() -> bool:
	if fighter.is_dead() or fighter.is_down() or held_by != null or holding != null:
		return false
	if fighter.get_state() == RagdollController.State.STAGGER or is_dazed() or is_stumbling():
		return false
	if _phase == Phase.IDLE:
		return true
	# Cancel rule 4: a charge or a charged move cancels only into a perfect dodge.
	return _phase == Phase.CHARGING or (_move_charge > 0 and _phase != Phase.ACTIVE)

func _perfect_dodge(attacker: Fighter) -> void:
	var now := TimeDirector.now()
	if _phase != Phase.IDLE:
		cancel()  # drops a charge or a charged move
	last_result = HitInfo.Result.DODGED
	_vanish_until = now + Tuning.VANISH_INVULN
	fighter.invuln_until = maxf(fighter.invuln_until, now + Tuning.VANISH_INVULN)
	_stun_left = 0.0
	_stun_kind = Stun.NONE
	_dodged_attacker = attacker
	_counter_until = now + Tuning.DODGE_SLOWMO_TIME + COUNTER_GRACE
	if fighter.rig:
		CombatFX.afterimage(fighter)
		fighter.rig.set_body_visible(false)
		_vanished = true
	if fighter.animator:
		fighter.animator.play_move(&"dodge", 0.0, Tuning.VANISH_INVULN, 0.1)
	TimeDirector.real_timer(Tuning.VANISH_INVULN).timeout.connect(_reappear_if_due)
	fighter.add_focus(Tuning.FOCUS_PERFECT_DODGE)
	GameEvents.perfect_dodge.emit(fighter, attacker)
	var player_involved := fighter.is_player or (attacker != null and is_instance_valid(attacker) and attacker.is_player)
	if player_involved:
		TimeDirector.request_slowmo(Tuning.DODGE_SLOWMO_SCALE, Tuning.DODGE_SLOWMO_TIME, TimeDirector.PRIO_DODGE)

func _reappear_if_due() -> void:
	if not is_instance_valid(fighter) or fighter.is_dead():
		return
	if TimeDirector.now() + 0.02 >= _vanish_until:
		_reappear()

func _reappear() -> void:
	_vanish_until = 0.0
	if _vanished:
		_vanished = false
		if fighter.rig:
			fighter.rig.set_body_visible(true)

## Light or Kick during the dodge slow motion: teleport behind the target and
## back-kick it (spec: Perfect dodge rule 2). The player's version.
func _try_counter(now: float) -> bool:
	if not fighter.is_player or now > _counter_until:
		return false
	if now < _counter_cooldown_until or fighter.focus + 1e-4 < Tuning.FOCUS_COST:
		return false
	if fighter.is_down() or held_by != null:
		return false
	# Candidates in order: the opponent the stick points at, the attacker we
	# dodged, the nearest opponent. Downed or unreachable ones are skipped so a
	# bad stick read never wastes the counter.
	var candidates: Array[Fighter] = []
	var stick := _stick()
	if stick.length() > 0.2:
		candidates.append(Targeting.pick_target(fighter, stick))
	candidates.append(_dodged_attacker)
	candidates.append(Targeting.pick_target(fighter, Vector3.ZERO))
	_counter_until = 0.0
	for target in candidates:
		if target == null or not is_instance_valid(target) or target.is_dead() or target.is_down():
			continue
		var spot := _find_counter_spot(target)
		if spot == Vector3.INF:
			continue
		fighter.spend_focus(Tuning.FOCUS_COST)
		_counter_cooldown_until = now + Tuning.COUNTER_COOLDOWN
		_teleport_invuln_until = now + COUNTER_INVULN
		_teleport_behind(target, spot)
		_ai_counter = false
		_begin(MoveLibrary.get_move(&"back_kick"))
		return true
	return true  # consumed: plain dodge

## AI teleport counter (Duelist): costs 1 Focus, teleports behind `target`
## (same spot search as the player's), shows a blue tell (attack_tell kind
## &"counter") for `tell_time`, then a back_kick at a fixed Tuning.COUNTER_LAUNCH.
## The player can perfect-dodge it and counter back (the BT3 vanish exchange).
## Called during this fighter's own perfect-dodge vanish, it is queued and
## starts the moment the fighter reappears (returns true); it never starts
## while vanished. Returns false if it cannot happen.
func start_counter(target: Fighter, tell_time: float) -> bool:
	if fighter == null or fighter.is_dead() or fighter.is_down() or held_by != null or holding != null:
		return false
	if target == null or not is_instance_valid(target) or target.is_dead() or target.is_down():
		return false
	if fighter.focus + 1e-4 < Tuning.FOCUS_COST:
		return false
	if _vanished or TimeDirector.now() < _vanish_until:
		_pending_counter = target
		_pending_counter_tell = tell_time
		return true
	return _do_ai_counter(target, tell_time)

func _do_ai_counter(target: Fighter, tell_time: float) -> bool:
	if target == null or not is_instance_valid(target) or target.is_dead() or target.is_down():
		return false
	if fighter.is_dead() or fighter.is_down() or held_by != null or holding != null or is_hit_stunned():
		return false
	if not (_phase == Phase.IDLE or _phase == Phase.RECOVERY):
		return false
	if fighter.focus + 1e-4 < Tuning.FOCUS_COST:
		return false
	var spot := _find_counter_spot(target)
	if spot == Vector3.INF:
		return false
	fighter.spend_focus(Tuning.FOCUS_COST)
	_teleport_invuln_until = TimeDirector.now() + AI_COUNTER_INVULN
	_teleport_behind(target, spot)
	_ai_counter = true
	var startup := maxf(tell_time, Tuning.frames(TELL_MIN))
	GameEvents.attack_tell.emit(fighter, &"counter", startup)
	_begin(MoveLibrary.get_move(&"back_kick"), startup)
	return true

func _teleport_behind(target: Fighter, spot: Vector3) -> void:
	_cancel_quiet()
	var look := target.get_ground_position() - spot
	fighter.teleport_to(spot, look)
	_reappear()
	if fighter.rig:
		CombatFX.puff(fighter.get_aim_point())
	GameEvents.teleport_counter.emit(fighter, target)
	_locked_target = target
	_pursuit_hit = false

func _find_counter_spot(target: Fighter) -> Vector3:
	var tp := target.get_ground_position()
	var tf := target.get_forward()
	var right := tf.cross(Vector3.UP).normalized()
	var dist := Tuning.COUNTER_BEHIND_DIST
	for c: Vector3 in [tp - tf * dist, tp + right * dist, tp - right * dist]:
		if _spot_clear(c):
			return c
	return Vector3.INF

## Capsule-sized shape cast at a floor point: clear of walls and capsules, with floor below.
func _spot_clear(p: Vector3) -> bool:
	var space := fighter.get_world_3d().direct_space_state
	var shape := fighter.capsule.shape as CapsuleShape3D if fighter.capsule else null
	var cap := CapsuleShape3D.new()
	cap.radius = shape.radius if shape else 0.3
	cap.height = (shape.height if shape else 1.8) - 0.1
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.transform = Transform3D(Basis(), p + Vector3.UP * (cap.height * 0.5 + 0.08))
	q.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE | Layers.CAPSULE
	q.exclude = [fighter.get_rid()]
	if not space.intersect_shape(q, 1).is_empty():
		return false
	var ray := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.5, p + Vector3.DOWN * 1.0,
		Layers.WORLD | Layers.DESTRUCTIBLE)
	return not space.intersect_ray(ray).is_empty()

func _stick() -> Vector3:
	if fighter.brain != null and fighter.brain.has_method(&"get_stick_world"):
		return fighter.brain.get_stick_world()
	return Vector3.ZERO

# =============================================================================
# Dash, pursuit, air recovery
# =============================================================================

func _on_dash_pressed(now: float) -> void:
	if fighter.is_player and fighter.is_launched():
		_try_air_recovery()
		return
	var victim := _pursuit_candidate()
	if victim != null:
		_start_pursuit(victim, now)
		return
	var charging := _phase == Phase.CHARGING
	if now < _dash_cooldown_until or not (_can_start() or (charging and not is_hit_stunned())):
		return
	if charging:
		_release_after_dash = true  # the charge fires at the end of the dash
	var dir := Vector3(fighter.move_input.x, 0.0, fighter.move_input.z)
	if dir.length() < 0.2:
		dir = fighter.get_forward()
	_dash_velocity = dir.normalized() * Tuning.DASH_SPEED
	_dash_left = Tuning.DASH_TIME
	_dash_cooldown_until = now + Tuning.DASH_TIME + Tuning.DASH_COOLDOWN
	if blocking:
		blocking = false
	if fighter.animator and not charging:
		fighter.animator.play_move(&"dash", 0.02, Tuning.DASH_TIME, 0.08)
	AudioFX.play(&"whoosh", fighter.get_aim_point(), -6.0, 1.2, fighter)  # player sounds keep pitch in Focus

func _try_air_recovery() -> void:
	if fighter.focus + 1e-4 < Tuning.FOCUS_COST:
		return
	if fighter.ragdoll.time_since_launch() < Tuning.AIR_RECOVERY_AFTER:
		return
	if fighter.ragdoll.air_recover():
		fighter.spend_focus(Tuning.FOCUS_COST)
		GameEvents.air_recovery.emit(fighter)

func _pursuit_candidate() -> Fighter:
	if not fighter.is_player:
		return null
	var v := _last_launch_victim
	if v == null or not is_instance_valid(v) or not v.is_launched():
		return null
	if TimeDirector.now() - _last_launch_time > Tuning.PURSUIT_WINDOW:
		return null
	if not _focus_pursuit_free(v) and fighter.focus + 1e-4 < Tuning.FOCUS_COST:
		return null
	if fighter.is_down() or held_by != null or holding != null or is_hit_stunned():
		return null
	var landed_hit := _phase == Phase.ACTIVE and _hit_any
	if not (_phase == Phase.IDLE or _phase == Phase.RECOVERY or landed_hit):
		return null
	return v

## Inside a Focus burst, pursuits cost nothing beyond the meter drain, up to
## Tuning.FOCUS_PURSUIT_CHAIN on one body.
func _focus_pursuit_free(v: Fighter) -> bool:
	if not TimeDirector.is_focus_active():
		return false
	return int(_focus_pursuits.get(v.get_instance_id(), 0)) < Tuning.FOCUS_PURSUIT_CHAIN

func _start_pursuit(victim: Fighter, now: float) -> void:
	if _focus_pursuit_free(victim):
		var id := victim.get_instance_id()
		_focus_pursuits[id] = int(_focus_pursuits.get(id, 0)) + 1
	else:
		fighter.spend_focus(Tuning.FOCUS_COST)
	_cancel_quiet()
	_last_launch_victim = null
	var vel := victim.get_com_velocity()
	var dir := Vector3(vel.x, 0.0, vel.z)
	if dir.length() < 0.5:
		dir = victim.get_ground_position() - fighter.get_ground_position()
		dir.y = 0.0
	dir = dir.normalized() if dir.length() > 0.01 else fighter.get_forward()
	var side := dir.cross(Vector3.UP).normalized()
	_pursuit_dir = dir
	_pursuit_side = side * 0.5
	var gp := victim.get_ground_position()
	var spot := Vector3.INF
	for c: Vector3 in [gp - dir * PURSUIT_OFFSET + side * 0.5, gp - dir * PURSUIT_OFFSET - side * 0.5,
			gp - dir * PURSUIT_OFFSET, gp + side * 1.0, gp - side * 1.0]:
		if _spot_clear(c):
			spot = c
			break
	if spot != Vector3.INF:
		CombatFX.puff(fighter.get_aim_point())
		fighter.teleport_to(spot, dir)
	_pursuit_target = victim
	_pursuit_until = now + PURSUIT_TIME
	GameEvents.pursuit.emit(fighter, victim)

func _tick_pursuit(delta: float, now: float) -> void:
	var v := _pursuit_target
	if v == null or not is_instance_valid(v) or now > _pursuit_until or fighter.is_down():
		_end_pursuit()
		return
	if _phase == Phase.ACTIVE or _phase == Phase.RECOVERY:
		return  # the follow-up swing plants the feet
	# Ride along beside the flying body until the follow-up swing.
	var vel := v.get_com_velocity()
	var hv := Vector3(vel.x, 0.0, vel.z)
	if hv.length() > 0.5:
		_pursuit_dir = hv.normalized()
	var target := v.get_ground_position() - _pursuit_dir * PURSUIT_OFFSET + _pursuit_side
	var to := target - fighter.global_position
	to.y = 0.0
	_chase_velocity = (to / maxf(delta, 1e-4)).limit_length(PURSUIT_MAX_CHASE)
	_has_chase = true
	if _phase == Phase.IDLE:
		fighter.face_dir = _pursuit_dir

# --- Pursuit refund: the follow-up ended in a wall break / crack / bowl ------
func _on_wall_broken(_wall: Node3D, pos: Vector3, _energy: float, _vel: Vector3) -> void:
	_check_refund_at(pos)

func _on_wall_cracked(_wall: Node3D, pos: Vector3, _energy: float) -> void:
	_check_refund_at(pos)

func _on_body_bowled(flyer: Node3D, _victim: Node3D, _energy: float, _chain: int) -> void:
	if _refund_victim != null and flyer == _refund_victim:
		_refund_pursuit()

func _check_refund_at(pos: Vector3) -> void:
	var v := _refund_victim
	if v == null or not is_instance_valid(v) or TimeDirector.now() > _refund_until:
		return
	if v.get_center_of_mass().distance_to(pos) <= PURSUIT_REFUND_RADIUS:
		_refund_pursuit()

func _refund_pursuit() -> void:
	_refund_victim = null
	fighter.add_focus(PURSUIT_REFUND)

func _end_pursuit() -> void:
	_pursuit_target = null
	_has_chase = false

# =============================================================================
# Grab, hold, throw, break, reversal
# =============================================================================

func _detect_grab() -> void:
	var best: Fighter = null
	var best_d := INF
	var reach := Tuning.GRAB_RANGE * fighter.get_height_scale()
	var fwd := fighter.get_forward()
	for opp in Targeting.opponents_of(fighter):
		if _registry.has(opp.get_instance_id()) or opp.combat == null:
			continue
		if not opp.combat.can_be_grabbed(fighter.is_player):
			continue
		if opp.is_crouching() and not opp.is_down():
			continue  # standing grabs whiff on a crouching fighter
		var to := opp.get_ground_position() - fighter.get_ground_position()
		to.y = 0.0
		var d := to.length()
		if d > reach:
			continue
		if d > 0.05 and fwd.dot(to / d) < GRAB_CONE_DOT:
			continue
		if d < best_d:
			best_d = d
			best = opp
	if best != null:
		_connect_grab(best)

func _connect_grab(victim: Fighter) -> void:
	var now := TimeDirector.now()
	_registry[victim.get_instance_id()] = true
	_hit_any = true
	var vc := victim.combat
	var zone := fighter.aim_zone if fighter.is_player else BodyZones.Zone.TORSO
	var down := victim.is_down()
	# Limb grabs (agent G): an arm, or the legs of a tumbling/downed fighter.
	# Their early break window is LimbGrab.break_window(zone).x (arm drags: shorter).
	if BodyZones.is_arm(zone) or (zone == BodyZones.Zone.LEGS and down):
		if _start_limb_grab(victim, zone, now):
			var early := LimbGrab.break_window(zone).x
			if vc._pressed_between(vc._grab_presses, _active_start_real - early, now):
				vc._grab_presses.clear()
				var lg := _limb_grab
				_end_limb_grab()
				if lg != null and is_instance_valid(lg):
					lg.break_free()
				_grab_broken(victim, false)
			return
	# Break window opens GRAB_BREAK_EARLY before our grab became active.
	if vc._pressed_between(vc._grab_presses, _active_start_real - Tuning.GRAB_BREAK_EARLY, now):
		vc._grab_presses.clear()
		_grab_broken(victim, false)
		return
	# Wall slam: a torso or head grab next to a wall drives the head into it.
	if not down:
		var wall := nearest_wall_dir(victim.get_center_of_mass(), Tuning.WALL_SLAM_RANGE)
		if wall != Vector3.ZERO:
			_wall_slam(victim, wall)
			return
	# Picking up a tumbling or downed body: stand it up into the hold.
	if down and victim.ragdoll:
		victim.ragdoll.force_recover()
	holding = victim
	_knees = 0
	_headlock = zone == BodyZones.Zone.HEAD
	vc._become_held(fighter, now, true)
	fighter.add_collision_exception_with(victim)
	victim.add_collision_exception_with(fighter)
	_phase = Phase.HOLDING
	_hold_start = now
	_t = 0.0
	if fighter.animator:
		fighter.animator.hold_pose(_hold_or(&"headlock", &"grab_hold") if _headlock else &"grab_hold")
	_place_victim()
	GameEvents.grab_started.emit(fighter, victim)

## Arm drag / giant swing through LimbGrab (agent G). False: fall back to the
## socket grab (LimbGrab refused or not built yet).
func _start_limb_grab(victim: Fighter, zone: int, now: float) -> bool:
	if not _limb_grab_available():
		return false
	if not LimbGrab.can_grip(fighter, victim, zone):
		return false
	var lg := LimbGrab.start(fighter, victim, zone)
	if lg == null:
		return false
	_limb_grab = lg
	_limb_victim = victim
	_limb_zone = zone
	victim.combat._become_held(fighter, now, true, true)
	victim.combat._held_break_mult = Tuning.ARM_DRAG_BREAK_MULT if BodyZones.is_arm(zone) else 1.0
	_phase = Phase.HOLDING
	_hold_start = now
	_t = 0.0
	GameEvents.grab_started.emit(fighter, victim)
	return true

static var _limb_api := -1

## LimbGrab (agent G) compiled with its static API (else: socket grabs only).
static func _limb_grab_available() -> bool:
	if _limb_api < 0:
		_limb_api = 0
		var scr: Script = LimbGrab
		if scr != null and scr.can_instantiate():
			for md in scr.get_script_method_list():
				if md.get("name", "") == "can_grip":
					_limb_api = 1
					break
	return _limb_api == 1

## Grab next to a wall: the victim goes head first into it at
## Tuning.WALL_SLAM_SPEED (the impact resolver decides crack / break).
func _wall_slam(victim: Fighter, wall_dir: Vector3) -> void:
	var m := MoveLibrary.get_move(&"wall_slam")
	var dir := Vector3(wall_dir.x, 0.0, wall_dir.z).normalized()
	var up := deg_to_rad(WALL_SLAM_UP_ANGLE)
	var vel := (dir * cos(up) + Vector3.UP * sin(up)) * Tuning.WALL_SLAM_SPEED
	fighter.snap_facing(dir)
	var info := HitInfo.new()
	info.attacker = fighter
	info.victim = victim
	info.move_id = &"wall_slam"
	info.kind = &"throw"
	info.damage = m.damage * _damage_mult()
	info.reaction = HitInfo.Reaction.LAUNCH
	info.launch_velocity = vel
	info.hit_position = victim.rig.get_bone_global_position(&"Head") if victim.rig else victim.get_aim_point()
	info.hit_direction = dir
	info.hit_bone = &"Head"
	info.zone = BodyZones.Zone.HEAD
	info.hitstop = Tuning.HITSTOP[&"throw"]
	info.energy = 0.5 * victim.get_total_mass() * vel.length_squared()
	info.unblockable = true
	info.is_finisher = true
	info.set_meta(&"shake", 0.4)
	_move = m
	_phase = Phase.RECOVERY
	_t = 0.0
	_recovery = m.active_s() + m.recovery_s()
	_hit_any = true
	_hit_confirmed = true
	if fighter.animator:
		fighter.animator.play_move(m.anim, 0.0, m.active_s(), m.recovery_s())
	victim.take_hit(info)
	last_dealt = info
	hit_dealt.emit(info)
	GameEvents.wall_slam.emit(fighter, victim, null)
	_last_launch_victim = victim
	_last_launch_time = TimeDirector.now()

func _become_held(grabber: Fighter, now: float, breakable: bool, limb := false) -> void:
	_held_break_mult = 1.0
	cancel()
	_held_via_grab = true
	_buffer_action = -1
	_pending_counter = null
	drop_debris()
	_stun_left = 0.0
	_stun_kind = Stun.NONE
	held_by = grabber
	_held_connect_time = now
	_held_breakable = breakable
	_end_pursuit()
	if _vanished or _vanish_until > 0.0:
		_reappear()
	_fighter_call(&"clear_forced_velocity", [])
	fighter.velocity = Vector3.ZERO
	if fighter.animator and not limb:
		fighter.animator.hold_pose(&"held")

## Victim-side watchdog: a grabber that was freed, died, went down or no
## longer holds us must never leave us frozen as "held".
func _check_held_by() -> void:
	if held_by == null:
		_held_via_grab = false
		return
	var g := held_by
	var gone := not is_instance_valid(g) or g.is_dead()
	# Holds made by our grab flow are fully policed; a held_by set directly
	# (tests, scripted scenes) is only cleared when its grabber is gone.
	var lost := _held_via_grab and not gone and (g.is_down() or g.combat == null
		or not (g.combat.holding == fighter or g.combat._limb_victim == fighter))
	if not gone and not lost:
		return
	_held_via_grab = false
	if _limb_api_ready():
		var lg := LimbGrab.get_grip_on(fighter)
		if lg != null and is_instance_valid(lg):
			lg.drop()
	held_by = null
	_held_break_mult = 1.0
	if fighter.animator and fighter.get_state() == RagdollController.State.ANIMATED:
		fighter.animator.release_pose()

static func _limb_api_ready() -> bool:
	return _limb_grab_available()

func _on_released() -> void:
	held_by = null
	if fighter.animator and fighter.get_state() == RagdollController.State.ANIMATED:
		fighter.animator.release_pose()

func _pressed_between(arr: Array[float], from_t: float, to_t: float) -> bool:
	for t in arr:
		if t >= from_t - 1e-4 and t <= to_t + 1e-4:
			return true
	return false

func _place_victim() -> void:
	var v := holding
	if v == null or not is_instance_valid(v):
		return
	var fwd := fighter.get_forward()
	var dist := GRAB_SOCKET * fighter.get_height_scale()
	# Keep the socket out of walls.
	var space := fighter.get_world_3d().direct_space_state
	var from := fighter.global_position + Vector3.UP * 1.0
	var ray := PhysicsRayQueryParameters3D.create(from, from + fwd * (dist + 0.35),
		Layers.WORLD | Layers.DESTRUCTIBLE)
	var hit := space.intersect_ray(ray)
	if not hit.is_empty():
		dist = maxf(from.distance_to(hit["position"]) - 0.35, 0.3)
	v.global_position = fighter.global_position + fwd * dist
	v.velocity = Vector3.ZERO
	v.snap_facing(-fwd)

func _tick_hold(now: float) -> void:
	if _limb_grab != null:
		_tick_limb_grab(now)
		return
	var v := holding
	if v == null or not is_instance_valid(v) or v.is_dead() or v.is_body_simulating():
		drop_hold()
		return
	_place_victim()
	var held_for := now - _hold_start
	if fighter.is_player:
		if (not _grab_held and held_for >= GRAB_MIN_HOLD) or held_for >= Tuning.GRAB_HOLD_MAX:
			_throw()
	elif held_for >= ENEMY_HOLD_TIME or held_for >= Tuning.GRAB_HOLD_MAX:
		_throw()

func _tick_limb_grab(now: float) -> void:
	var lg := _limb_grab
	var v := _limb_victim
	if lg == null or not is_instance_valid(lg) or not lg.is_active() or v == null or not is_instance_valid(v) \
			or v.is_dead():
		if lg != null and is_instance_valid(lg) and lg.is_active():
			lg.drop()  # victim died: let go without a fling
		_end_limb_grab()
		return
	var held_for := now - _hold_start
	var let_go := (not _grab_held and held_for >= GRAB_MIN_HOLD) if fighter.is_player else held_for >= ENEMY_HOLD_TIME
	if let_go or held_for >= LIMB_HOLD_MAX:
		var dir := _stick() if fighter.is_player else throw_aim
		dir.y = 0.0
		# No stick: ZERO lets the body fly along its swing (facing would bend it).
		lg.release(dir.normalized() if dir.length() >= 0.2 else Vector3.ZERO)
		_last_launch_victim = v
		_last_launch_time = now
		_end_limb_grab()

func _end_limb_grab() -> void:
	var v := _limb_victim
	_limb_grab = null
	_limb_victim = null
	if v != null and is_instance_valid(v) and v.combat and v.combat.held_by == fighter:
		v.combat.held_by = null
		v.combat._held_break_mult = 1.0
	if _phase == Phase.HOLDING:
		_phase = Phase.IDLE
		_end_sequence()

func _release_hold_links() -> void:
	var v := holding
	holding = null
	if v != null and is_instance_valid(v):
		if v.combat and v.combat.held_by == fighter:
			v.combat.held_by = null
		var me := fighter
		# Remove the capsule exceptions once the two have separated.
		TimeDirector.real_timer(0.35).timeout.connect(func() -> void:
			if is_instance_valid(me) and is_instance_valid(v):
				me.remove_collision_exception_with(v)
				v.remove_collision_exception_with(me))

func _throw() -> void:
	var v := holding
	if v == null:
		return
	_release_hold_links()
	var dir := Vector3.ZERO
	if fighter.is_player:
		dir = _stick()
	elif throw_aim.length_squared() > 1e-4:
		dir = throw_aim
	dir.y = 0.0
	if dir.length() < 0.2:
		dir = fighter.get_forward()
	dir = dir.normalized()
	fighter.snap_facing(dir)
	var speed: float = fighter.config.get("throw_speed", Tuning.THROW_SPEED)
	var throw_id := &"throw"
	var up := deg_to_rad(Tuning.THROW_UP_ANGLE)
	var vel := (dir * cos(up) + Vector3.UP * sin(up)) * speed
	if fighter.is_player and fighter.get_input_intent() == &"back":
		# Upward throw: straight up Tuning.UPWARD_THROW_LIFT for a flying kick or pursuit.
		throw_id = &"upward_throw"
		var g: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
		dir = fighter.get_forward()
		vel = dir * UPWARD_THROW_DRIFT + Vector3.UP * sqrt(2.0 * g * Tuning.UPWARD_THROW_LIFT)
		speed = vel.length()
	elif _headlock:
		throw_id = &"neck_throw"
		var tm := MoveLibrary.get_move(throw_id)
		up = deg_to_rad(tm.up_angle)
		vel = (dir * cos(up) + Vector3.UP * sin(up)) * speed
	var info := HitInfo.new()
	info.attacker = fighter
	info.victim = v
	info.move_id = throw_id
	info.kind = &"throw"
	var base_dmg: float = Tuning.DMG_THROW if fighter.is_player else Tuning.DMG_ENEMY.get(&"e_grab", Tuning.DMG_THROW)
	if throw_id != &"throw":
		base_dmg = MoveLibrary.get_move(throw_id).damage
	info.damage = base_dmg * _damage_mult()
	info.reaction = HitInfo.Reaction.LAUNCH
	info.launch_velocity = vel
	info.hit_position = v.get_aim_point()
	info.hit_direction = dir
	info.hit_bone = &"Chest"
	info.hitstop = Tuning.HITSTOP[&"throw"]
	info.energy = 0.5 * v.get_total_mass() * speed * speed
	info.unblockable = true
	info.is_finisher = true
	info.set_meta(&"shake", 0.3)
	# Throw recovery is part of the grab sequence (one attack_started/ended pair).
	var th := MoveLibrary.get_move(throw_id)
	_headlock = false
	_move = th
	_phase = Phase.RECOVERY
	_t = 0.0
	_recovery = th.active_s() + th.recovery_s()
	_hit_any = true
	if fighter.animator:
		fighter.animator.play_move(th.anim, 0.0, th.active_s(), th.recovery_s())
	if v.combat:
		v.combat._on_released()
	v.take_hit(info)
	last_dealt = info
	hit_dealt.emit(info)
	GameEvents.thrown.emit(fighter, v, vel)
	_last_launch_victim = v
	_last_launch_time = TimeDirector.now()

## Victim pressed Grab while we hold it.
func _try_break_by(victim: Fighter, press_time: float) -> bool:
	if _phase != Phase.HOLDING or victim.combat == null:
		return false
	var vc := victim.combat
	if _limb_grab != null and _limb_victim == victim:
		var ldt := press_time - vc._held_connect_time
		if not vc._held_breakable or ldt > Tuning.GRAB_BREAK_LATE * vc._held_break_mult:
			return false
		if is_instance_valid(_limb_grab):
			_limb_grab.break_free()
		_end_limb_grab()
		_grab_broken(victim, false)
		return true
	if holding != victim:
		return false
	if not vc._held_breakable:
		return false
	var dt := press_time - vc._held_connect_time
	if dt > Tuning.GRAB_BREAK_LATE:
		return false
	var reversal := dt >= -1e-4 and dt <= Tuning.GRAB_REVERSAL_LATE \
		and victim.focus + 1e-4 >= Tuning.FOCUS_COST
	_grab_broken(victim, reversal)
	return true

func _grab_broken(victim: Fighter, reversal: bool) -> void:
	var grabber := fighter
	if holding == victim:
		_release_hold_links()
	victim.combat.held_by = null
	TimeDirector.hitstop([grabber, victim], Tuning.HITSTOP[&"grab_break"])
	if reversal and victim.spend_focus(Tuning.FOCUS_COST):
		GameEvents.grab_broken.emit(grabber, victim, true)
		_cancel_quiet()
		victim.combat._take_hold_of(grabber)
		return
	victim.add_focus(Tuning.FOCUS_GRAB_BREAK)
	CombatFX.spark((grabber.get_aim_point() + victim.get_aim_point()) * 0.5)
	var dir := victim.get_ground_position() - grabber.get_ground_position()
	dir.y = 0.0
	dir = dir.normalized() if dir.length() > 0.05 else grabber.get_forward()
	var push_speed := Tuning.GRAB_BREAK_PUSH * 0.5 / GRAB_BREAK_PUSH_TIME
	# Grabber staggers.
	_cancel_quiet()
	_stun_left = Tuning.GRAB_BREAK_STAGGER
	_stun_kind = Stun.HIT
	grabber.knockback(-dir * push_speed, GRAB_BREAK_PUSH_TIME)
	if grabber.animator:
		grabber.animator.play_move(&"grab_break_push", 0.0, Tuning.frames(4), Tuning.GRAB_BREAK_STAGGER)
	# Victim is free and pushed away.
	var vc := victim.combat
	vc._cancel_quiet()
	vc._stun_left = 0.0
	victim.knockback(dir * push_speed, GRAB_BREAK_PUSH_TIME)
	if victim.animator:
		victim.animator.play_move(&"grab_break_push", 0.0, Tuning.frames(4), Tuning.frames(10))
	GameEvents.grab_broken.emit(grabber, victim, false)

## A punch or kick while holding someone: knees (P, up to MAX_KNEES), and in a
## headlock a headbutt (K).
func _held_followup(action: int, _now: float) -> void:
	if _phase != Phase.HOLDING or holding == null or not is_instance_valid(holding):
		return
	if action == Action.LIGHT or action == Action.HEAVY:
		if _knees < MAX_KNEES:
			_knees += 1
			_held_strike(MoveLibrary.get_move(&"knee"))
	elif action == Action.KICK and _headlock:
		_held_strike(MoveLibrary.get_move(&"headbutt"))

## Strike the fighter we hold (no hit detection; stays held).
func _held_strike(m: MoveData) -> void:
	if m == null or holding == null:
		return
	var v := holding
	var info := HitInfo.new()
	info.attacker = fighter
	info.victim = v
	info.move_id = m.id
	info.kind = &"strike"
	info.damage = m.damage * _damage_mult()
	info.reaction = HitInfo.Reaction.NONE
	info.level = m.hit_level
	info.zone = BodyZones.Zone.HEAD if _headlock else BodyZones.Zone.TORSO
	info.hit_direction = fighter.get_forward()
	info.hit_position = v.get_aim_point()
	info.hit_bone = &"Head" if m.id == &"headbutt" else &"Chest"
	info.hitstop = m.hitstop_time()
	info.unblockable = true
	info.energy = 0.5 * v.get_total_mass() * m.nominal_speed * m.nominal_speed
	info.set_meta(&"shake", m.shake)
	_hold_start = TimeDirector.now()  # each knee extends the hold
	if fighter.animator:
		fighter.animator.play_move(m.anim, Tuning.frames(m.startup), Tuning.frames(m.active),
			Tuning.frames(m.recovery))
	v.combat._apply_held_hit(info)
	last_dealt = info
	hit_dealt.emit(info)
	if m.id == &"headbutt":
		var victim := holding
		drop_hold()
		if is_instance_valid(victim) and victim.combat:
			victim.combat.apply_daze(Tuning.DAZED_TIME)

## Victim side of a knee / headbutt: damage and feedback, stays held.
func _apply_held_hit(info: HitInfo) -> void:
	_register_taken()
	info.result = HitInfo.Result.HIT
	last_result = info.result
	last_received = info
	var att := info.attacker as Fighter
	if info.hitstop > 0.0:
		var who: Array = [fighter]
		if att != null and is_instance_valid(att):
			who.append(att)
		TimeDirector.hitstop(who, info.hitstop)
	fighter.apply_damage(info.damage, info.move_id, info)
	GameEvents.hit_landed.emit(info)
	hit_received.emit(info)
	if att != null and is_instance_valid(att) and att.combat:
		att.combat._commit_combo(info)
	GameEvents.screen_shake.emit(info.get_meta(&"shake", 0.08))

## Reversal: we (the former victim) now hold `target`.
func _take_hold_of(target: Fighter) -> void:
	var now := TimeDirector.now()
	cancel()
	held_by = null
	_move = MoveLibrary.get_move(&"grab")
	_seq_id = _move.id
	attack_started.emit(_move.id)
	holding = target
	target.combat._become_held(fighter, now, false)
	fighter.add_collision_exception_with(target)
	target.add_collision_exception_with(fighter)
	_phase = Phase.HOLDING
	_hold_start = now
	_hit_any = true
	if fighter.animator:
		fighter.animator.hold_pose(&"grab_hold")
	var to := target.get_ground_position() - fighter.get_ground_position()
	fighter.snap_facing(to)
	_place_victim()
	GameEvents.grab_started.emit(fighter, target)

# =============================================================================
# Projectile (Thrower)
# =============================================================================

func _spawn_projectile() -> void:
	# The opponent the thrower faces (the AI faces the player), else the player.
	var target := Targeting.pick_target(fighter, fighter.get_forward(), 25.0)
	if target == null:
		var p := Targeting.player(fighter.get_tree())
		if p != null and p.team != fighter.team and not p.is_dead():
			target = p
	var hs := fighter.get_height_scale()
	var start := fighter.global_position + Vector3.UP * 1.7 * hs + fighter.get_forward() * 0.45
	if _rig_ready():
		var hand := fighter.rig.get_bone_global_position(&"RightHand")
		if hand.distance_to(fighter.global_position) < 3.0:
			start = hand + Vector3.UP * 0.1 + fighter.get_forward() * 0.25
	var aim := target.get_aim_point() - Vector3.UP * 0.25 if target else start + fighter.get_forward() * 8.0
	var dmg := _move.damage * _damage_mult()
	if _carried != null and is_instance_valid(_carried):
		var body := _carried
		_carried = null
		# Leave the hand at a point clear of the thrower and the walls, with no
		# leftover velocity, before collisions come back on (launch_body).
		var from := _clear_launch_point(body)
		body.reparent(fighter.get_parent(), true)
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		body.global_position = from
		body.reset_physics_interpolation()
		ThrownChunk.launch_body(body, ThrownChunk.ballistic_velocity(from, aim, PROJECTILE_SPEED,
			body.gravity_scale), fighter, dmg)
		return
	var chunk := ThrownChunk.new()
	chunk.setup(fighter, dmg)
	var parent := fighter.get_parent()
	parent.add_child(chunk)
	chunk.global_position = start
	chunk.reset_physics_interpolation()
	chunk.launch_at(aim, PROJECTILE_SPEED)

## Release point for a carried chunk: in front of the thrower's chest, far
## enough out that the chunk does not overlap the thrower, and not inside a
## wall, floor or other body (else the solver would fling it out).
func _clear_launch_point(body: RigidBody3D) -> Vector3:
	var r := ProjectileProbe.body_radius(body)
	var hs := fighter.get_height_scale()
	var fwd := fighter.get_forward()
	var cap_r := (fighter.capsule.shape as CapsuleShape3D).radius if fighter.capsule else 0.3
	var out := cap_r + r + 0.12
	var base := fighter.global_position
	var shape := SphereShape3D.new()
	shape.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE | Layers.DEBRIS | Layers.CAPSULE | Layers.RAGDOLL
	var ex: Array[RID] = [fighter.get_rid(), body.get_rid()]
	if fighter.rig:
		for pb in fighter.rig.get_physical_bones():
			ex.append(pb.get_rid())
	q.exclude = ex
	var space := fighter.get_world_3d().direct_space_state
	for c: Vector3 in [base + Vector3.UP * 1.5 * hs + fwd * out, base + Vector3.UP * 1.9 * hs + fwd * out,
			base + Vector3.UP * (2.0 * hs + r) + fwd * 0.1]:
		q.transform = Transform3D(Basis(), c)
		if space.intersect_shape(q, 1).is_empty():
			return c
	return base + Vector3.UP * (2.0 * hs + r + 0.1)

## Thrower: take a chunk out of DebrisManager into the right hand. The next
## e_throw_debris throws this chunk instead of spawning a box.
func pick_up_debris(body: RigidBody3D) -> bool:
	if body == null or not is_instance_valid(body) or not body.is_inside_tree():
		return false
	if fighter.is_dead() or fighter.is_down() or held_by != null or holding != null:
		return false
	if _carried != null and is_instance_valid(_carried):
		return false
	if _phase != Phase.IDLE and not (_move != null and _move.id == &"e_throw_debris" and _phase == Phase.STARTUP):
		return false
	DebrisManager.release(body)
	for c in body.get_children():
		if c is ProjectileProbe:
			(c as ProjectileProbe).live = false
			c.queue_free()
	var hand: Node3D = fighter.rig.get_attachment(&"RightHand") if fighter.rig else null
	if hand == null:
		hand = fighter
	# STATIC, not KINEMATIC: a kinematic body reports the hand's motion as its
	# velocity (a pose snap read as ~46 m/s); a static one carries none.
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	body.freeze = true
	body.collision_layer = 0
	body.collision_mask = 0
	body.reparent(hand, false)
	body.position = CARRY_OFFSET if hand != fighter else Vector3(0.3, 1.2, -0.3)
	body.rotation = Vector3.ZERO
	body.reset_physics_interpolation()
	_carried = body
	return true

## The chunk in hand, if any.
func get_carried_debris() -> RigidBody3D:
	return _carried if _carried != null and is_instance_valid(_carried) else null

## Let go of a carried chunk (hit, grabbed, died): it falls as debris.
func drop_debris() -> void:
	var body := _carried
	_carried = null
	if body == null or not is_instance_valid(body) or not fighter.is_inside_tree():
		return
	var at := _clear_launch_point(body)
	body.reparent(fighter.get_parent(), true)
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	body.global_position = at
	body.reset_physics_interpolation()
	body.freeze = false
	body.collision_layer = Layers.DEBRIS
	body.collision_mask = Layers.MASK_DEBRIS
	DebrisManager.register(body, false)

func _damage_mult() -> float:
	return float(fighter.config.get("damage_mult", 1.0))

# --- Upgrade 2 contract (agent B implements) -------------------------------------
## 0 = not charging or tapped, 1..3 = charge level reached (Tuning.CHARGE_LEVELS).
func get_charge_level() -> int:
	if _phase == Phase.CHARGING:
		return _charge_level
	return _move_charge if _phase != Phase.IDLE else 0

## Hits in the current combo (0 when none).
func get_combo_count() -> int:
	return _combo_count if TimeDirector.now() - _combo_last <= Tuning.COMBO_DROP else 0

## Damage multiplier the next combo hit gets (Tuning.COMBO_*).
func get_damage_scale() -> float:
	return combo_scale(get_combo_count() + 1)

## Damage multiplier of the n-th hit of a combo (1-based).
static func combo_scale(n: int) -> float:
	if n <= Tuning.COMBO_FULL_HITS:
		return 1.0
	return maxf(1.0 - Tuning.COMBO_SCALE_STEP * float(n - Tuning.COMBO_FULL_HITS), Tuning.COMBO_SCALE_MIN)

func is_dazed() -> bool:
	return _stun_left > 0.0 and _stun_kind == Stun.DAZE

func is_stumbling() -> bool:
	return _stun_left > 0.0 and _stun_kind == Stun.STUMBLE

## Per tick bookkeeping for Upgrade 2 (stance, combos, downed counters).
func _tick_upgrade2(delta: float, now: float) -> void:
	var c := fighter.is_crouching()
	if _crouch_was and not c:
		_crouch_released_at = now
	_crouch_was = c
	if not fighter.is_down():
		downed_hits = 0
		downed_kicked = false
		juggle_relaunches = 0
		getup_extended = false
	if _taken > 0 and now - _taken_last > Tuning.COMBO_DROP:
		_taken = 0
		_taken_stun = 0.0
	if _combo_count > 0 and now - _combo_last > Tuning.COMBO_DROP:
		GameEvents.combo_ended.emit(fighter, _combo_count)
		_combo_count = 0
		_combo_tripped.clear()
	if _leg_slow_left > 0.0:
		_leg_slow_left -= delta
	var focus := TimeDirector.is_focus_active()
	if _focus_was and not focus:
		_focus_pursuits.clear()
	_focus_was = focus
