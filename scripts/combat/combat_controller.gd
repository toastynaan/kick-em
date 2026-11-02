class_name CombatController
extends Node
## Moves, frame data, hit detection (hit registry: each attack hits each target
## once), the hit pipeline, guard, and the routing hub to Defence (parry,
## teleport, pursuit: agent H), Carry (grabs, holds, throws: agent G) and
## Traversal (dash, sprint, parkour: agent M). Same component for the player
## and for enemies; enemies start attacks via start_enemy_attack() (tell +
## startup) instead of button presses.
## OWNER: agent B (combat). CONTRACT STUB: keep every public signature.
##
## Round 5 (Feel Reference: Strikes and body reactions):
## - Target: every strike picks its target at the press (Targeting.pick_strike_target
##   along PlayerController.get_aim_dir(); the lock-on target while locked),
##   turns to it and lunges up to Tuning.LUNGE_MAX; a sprint strike carries its
##   speed and stops Tuning.SPRINT_LUNGE_STOP short. No target: along the stick.
## - Power: P = Power.score(class base, charge level, speed toward the target
##   sampled at the commit (the press, or the charge release) BEFORE
##   Traversal.on_strike_started(), the speed cap, Defence.counter_bonus() at
##   contact, finisher on the third hit of a tap string). The tier comes from P
##   (sweeps: Power.sweep_tier_of). Hits from elsewhere preset their tier.
## - Contact frame: the reaction is applied on the contact physics frame, then
##   hitstop on the attacker and victim only (Power.hitstop_for, the player
##   capped at Tuning.PLAYER_HITSTOP_MAX), then hit_landed. RagdollController
##   holds the reacting bones through the freeze (the victim keeps its contact
##   pose and jitters) and releases them with the animation velocities it
##   cached before the freeze plus the impulse (see its header). Block and Dash
##   pressed during the player's own freeze fire when it ends.
## - Effects, camera shake and slow time listen to GameEvents; this file never
##   spawns contact effects or shakes the screen for hits.
##
## Timing: move phases and stun run in the fighter's own time (the player's in
## player time, full speed in any slow motion) and stop during its hitstop.
## Input windows and charge levels use TimeDirector.now() (real time).

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
const STAGGER_TIME := 0.7          ## s: Fighter.stagger's fallback stun (H); Round 5 uses Tuning.REACT_STAGGER.act
const STAGGER_STRENGTH := 0.75     ## stagger strength: < 1 stays on its feet (a stagger never tips into a launch)
const BUFFER_MAX_AGE := 0.8        ## s: presses older than this are dropped (no surprise moves)
const STRIKE_BREAK_HITSTOP_MULT := 2.0  ## wall strike hitstop x on &"break"
const STRIKE_RECOIL_TIME := 0.15   ## s of the recoil slide off a wall that holds
const STRIKE_FIGHTER_MARGIN := 0.6 ## m beyond reach in which an opponent takes priority over a wall
const FLOOR_NORMAL_Y := 0.7        ## contacts with a more upward normal are floors, never struck
const RISING_WINDOW := 0.25        ## s after releasing crouch in which Light / Heavy is a rising uppercut
const GROUND_HOLD := 0.6           ## s the first ground strike of a knockdown keeps the body down
const BACKFIST_RANGE := 3.0        ## m: backfist turns to an opponent behind within this
const BLOCK_WALK_MULT := 0.35      ## walking while guarding
const BLOCK_PUSH_TIME := 0.15      ## s the guard push-back slide lasts
const ESCAPE_PUSH_TIME := 0.2      ## s of the break-away slide
const ESCAPE_VICTIM_SHARE := 0.8   ## of Tuning.COMBO_ESCAPE_PUSH covered by the victim
const LYING_HEIGHT := 0.45         ## m: a launched body with its COM this low...
const LYING_SPEED := 2.0           ## ...and slower than this is lying, not airborne
const GRAB_CONE_DOT := 0.4         ## grab only catches fighters roughly in front
const DODGE_CHECK_EXTRA := 2.0     ## m beyond the move's reach in which defenders may parry / dodge
const INTERCEPT_FRONT_DOT := 0.0   ## an attack is "aimed at" a fighter roughly in front of the attacker
const ENEMY_REACH_MARGIN := 0.5    ## m beyond an enemy move's reach + lunge in which the player is still its target
const ENEMY_REACH_FRONT_DOT := 0.5 ## ...when within 60 degrees of the enemy's facing
const PURSUIT_REACH := 2.8         ## m: the follow-up connects with the locked body inside this
const PROJECTILE_SPEED := 15.0     ## m/s debris chunk
const LOCKED_TARGET_REACH := 0.9   ## m beyond reach in which a locked target (counter, ground strike) still connects
const AI_COUNTER_INVULN := 0.1     ## real s of invulnerability on the AI teleport (the tell is hittable)
const CARRY_OFFSET := Vector3(0.0, -0.16, -0.05)  ## chunk position in the right-hand attachment
const GUARD_FRONT_DOT := 0.3       ## guards and archetype blocks cover this front cone
const DEBRIS_KICK_RADIUS := 0.7    ## m from the kicking foot
const DEBRIS_KICK_SPEED := 14.0    ## m/s
const DEBRIS_KICK_DAMAGE := 8.0    ## Round 5: a kicked chunk hits like a thrown prop (Tuning.PROP_DAMAGE)
const ARMOR_HITSTOP := 0.05
# Round 5 (local; candidates for Tuning)
## Wall strikes keep Round 3's scale: power = this x P, so a tapped kick (P 2.5)
## strikes a wall with 60, the old kick, and D's STRIKE_CELL_HP feel targets hold.
const WALL_POWER_PER_P := 24.0
## A normal lunge stops when the target is this share of the move's reach away
## (the fist lands with the arm still bending, not fully extended).
const LUNGE_GAP := 0.7
## m/s cap of a normal (walking) lunge: 1 m in a jab's 5 frames would be 12 m/s,
## which reads as a teleport; 8 m/s keeps it a step (a jab covers ~0.7 m).
const LUNGE_SPEED_MAX := 8.0
## s: a dropping strike stays active while Traversal still falls, at most this long.
const DROP_ACTIVE_LIMIT := 3.0
## s an attack pressed early in a vault waits for the landing before it is dropped.
const VAULT_PRESS_KEEP := 1.0
## A sprint lunge runs at the sprint speed, and up to this x it when that is
## needed to reach the stop point by the end of the active frames: a sprint jab
## pressed 2.5 m out (8 frames to cover 1.6 m) still lands on the marked target.
const SPRINT_LUNGE_BOOST := 1.5
## Nudge strength on a body already down (flying past the juggle cap, lying,
## ground strikes): 0.5 + this x P, at most NUDGE_MAX (Fighter.flinch strength).
const NUDGE_PER_P := 0.2
const NUDGE_MAX := 1.6
## Contact-frame jitter in m by tier (Tuning.HITSTOP_JITTER_RANGE from flinch to sever).
## Body speed (m/s) used for HitInfo.energy on hits that do not launch (old listeners scale on it).
const NOMINAL_SPEED := {HitInfo.Tier.FLINCH: 2.0, HitInfo.Tier.STUMBLE: 2.5, HitInfo.Tier.STAGGER: 3.0,
	HitInfo.Tier.KNOCKDOWN: 4.0}

var fighter: Fighter
var blocking := false
## AI: world direction for the next throw (Carry reads it for enemy grab-throws).
var throw_aim := Vector3.ZERO
## Result of the last receive_hit() (HitInfo.Result), -1 before any hit.
var last_result := -1
## Last HitInfo this fighter received / dealt (tests, debug HUD, overlay).
var last_received: HitInfo
var last_dealt: HitInfo
## Last wall strike {target, position, normal, power, result} (tests, debug HUD).
var last_wall_strike: Dictionary = {}

var _phase: int = Phase.IDLE
var _move: MoveData
var _seq_id: StringName = &""   ## move id reported by attack_ended
var _t := 0.0                   ## own-time s in the current phase
var _startup := 0.0
var _active := 0.0
var _recovery := 0.0
# Press model, charge, strings
## Tests and the lab: read press/release like the player's buttons (tap vs hold)
## even without a PlayerController.
var force_hold_charge := false
var graph: ComboGraph = ComboGraph.default_graph()
var _btn_down := {}             ## Action -> held
var _btn_time := {}             ## Action -> real press time
var _press_action := -1         ## button that started the current move (-1: tap / scripted)
var _press_t := 0.0             ## its press time (real)
var _press_released := true
var _charge_level := 0          ## level reached while charging
var _move_charge := 0           ## level the current move fires with
var _waited := false            ## the strike reached the end of its startup before the release
var _last_move_id: StringName = &""
var _last_move_end := -INF
var _crouch_was := false
var _crouch_released_at := -INF
var _string_pos := 0            ## 1-based position of the current / last string move (0 = none)
var _string_tap := true         ## every move of the string so far was a tap
## Victim side: ground strikes taken this time down (reset on getting up).
var downed_hits := 0
var _combo_count := 0           ## attacker: hits in the current combo
var _combo_last := -INF         ## real time of its last hit
var _taken := 0                 ## victim: hits taken in the current combo (from anyone)
var _taken_last := -INF
var _taken_stun := 0.0          ## victim: stun taken in the current combo (break-away at COMBO_ESCAPE_STUN)
var _escape_guard_until := 0.0  ## victim: break-away auto-guard
var juggle_relaunches := 0      ## victim: relaunches this flight (cap Tuning.JUGGLE_MAX_RELAUNCH)
var getup_extended := false     ## victim: a ground strike already delayed this get-up
var _hit_any := false
var _hit_confirmed := false     ## this attack landed a clean HIT (cancels)
var _aim_set := false
var _debris_kicked := false
var _wall_struck := false       ## this move already struck a wall (once per move)
var _registry := {}             ## victim instance id -> true
var _prev_limb := Vector3.INF
var _prev_limbs := {}           ## bone -> last tick's position (limb sweep)
var _locked_target: Fighter     ## always connects when close (pursuit, ground strike, counter)
var _active_start_real := 0.0
var _freeze_until := 0.0
var _stun_left := 0.0
var _stun_kind: int = Stun.NONE
var _guard_stun := false        ## blockstun came from a real guard (stays blocking)
# Round 5: targeting, lunge, power, contact frame
var _target: Fighter            ## the strike's target, picked at the press
var _lunge_left := 0.0          ## m of normal lunge left (Tuning.LUNGE_MAX)
var _lunge_sprint := false      ## sprint strike: the lunge carries the run and stops SPRINT_LUNGE_STOP short
var _lunge_speed := 0.0         ## m/s of a sprint lunge
var _lunge_velocity := Vector3.ZERO
var _has_lunge := false
var _strike_class: StringName = &""  ## class of the current strike (the drop strike's comes from its button)
var _committed := false         ## speed sampled and Traversal told for this strike
var _p_speed := 0.0             ## m/s toward the target at the commit
var _p_cap := 8.0               ## speed cap at the commit
var _p_sprint := false          ## thrown at sprint speed (sprint, wall run, vault drop)
var _p_finisher := false        ## third hit of a tap string
var _press_sample: Array = []   ## [speed toward the target, cap, sprinting] taken at the press
var _resample := false          ## a charge release samples its own speed
var _sprint_excepted: Fighter   ## capsule collision exception of a sprint strike
var _drop_from_vault := false
var _drop_t := 0.0              ## own-time s in the current dropping strike's active frames
var _vault_action := -1         ## attack pressed early in a vault: a normal strike once landed
var _vault_press_t := 0.0
var _freeze_inputs: Array = []  ## [action, pressed] Block / Dash during the player's freeze

var _block_held := false
var _block_since := 0.0
var _teleport_invuln_until := 0.0
var _buffer_action := -1
var _buffer_time := 0.0

var _slide_left := 0.0          ## guard push-back slide (own time s)
var _slide_velocity := Vector3.ZERO
var _slide_plant := false       ## feet planted for the rest of the blockstun after the slide
var _dash_left := 0.0
var _dash_velocity := Vector3.ZERO
var _dash_cooldown_until := 0.0

var _carried: RigidBody3D       ## debris chunk in the right hand (Thrower)


var _q_sphere := SphereShape3D.new()
var _q_capsule := CapsuleShape3D.new()
var _q_params := PhysicsShapeQueryParameters3D.new()

func setup(p_fighter: Fighter) -> void:
	fighter = p_fighter

# =============================================================================
# Input
# =============================================================================

## Button input (player, or AI using player-style actions such as BLOCK/DASH).
## An attack press starts its wind-up at once; released before
## Tuning.HOLD_THRESHOLD it fires the normal move (waiting for the release if
## the startup is shorter); still held, it freezes in the move's charge pose and
## charges through Tuning.CHARGE_LEVELS (real time) until released (or
## Tuning.CHARGE_AUTO_RELEASE). Which move a press means: a dropping strike in
## the air or late in a vault, a ground strike next to a body on the ground,
## else the ComboGraph string for the button and the fighter's stance.
func press(action: int) -> void:
	if fighter == null or fighter.is_dead():
		return
	var now := TimeDirector.now()
	# Contact frame: Block and Dash pressed during the player's own freeze fire when it ends.
	if (action == Action.BLOCK or action == Action.DASH) and _in_own_freeze(now):
		_freeze_inputs.append([action, true])
		return
	match action:
		Action.BLOCK:
			# Round 5: Defence sees every Block press first (parry / anti-mash lockout).
			if fighter.defence != null:
				fighter.defence.on_block_pressed(now)
			if not _block_held:
				_block_since = now
			_block_held = true
			_guard_cancels_windup()
			_update_block_state()
		Action.DASH:
			# Round 5 Dash routing: Defence (teleport, sidestep, pursuit), then
			# Traversal (short dash, sprint), then the fallback dash.
			if fighter.defence != null and fighter.defence.on_dash_pressed(now):
				return
			if fighter.traversal != null and fighter.traversal.on_dash_pressed():
				return
			_on_dash_pressed(now)
		Action.GRAB:
			# Grabs, holds, throws and grab breaks are Carry's (agent G).
			if _new_carry():
				fighter.carry.on_grab_pressed(now)
		Action.LIGHT, Action.KICK, Action.HEAVY, Action.SWEEP:
			_btn_down[action] = true
			_btn_time[action] = now
			if _new_carry() and fighter.carry.is_holding() and fighter.carry.on_attack_pressed(action, now):
				return
			_attack_press(action, now)

func release(action: int) -> void:
	if (action == Action.BLOCK or action == Action.DASH) and _has_frozen_press(action):
		_freeze_inputs.append([action, false])
		return
	match action:
		Action.BLOCK:
			_block_held = false
			_update_block_state()
		Action.DASH:
			if fighter != null and fighter.traversal != null:
				fighter.traversal.on_dash_released()
		Action.GRAB:
			if _new_carry():
				fighter.carry.on_grab_released(TimeDirector.now())
		Action.LIGHT, Action.KICK, Action.HEAVY, Action.SWEEP:
			if _new_carry() and fighter.carry.is_holding():
				fighter.carry.on_attack_released(action, TimeDirector.now())
			_btn_down[action] = false
			if _vault_action == action:
				return  # a vault press fires as a tap later
			if action == _press_action and not _press_released:
				_press_released = true
				if _phase == Phase.CHARGING:
					_release_charge()
				elif _phase == Phase.STARTUP:
					_commit()  # a tap: the strike commits on the release

## The player is inside its own hitstop freeze.
func _in_own_freeze(now: float) -> bool:
	return fighter.is_player and (now < _freeze_until or fighter.is_frozen())

func _has_frozen_press(action: int) -> bool:
	for e: Array in _freeze_inputs:
		if e[0] == action and e[1]:
			return true
	return false

## Replay Block / Dash presses and releases buffered during the freeze, in order.
func _flush_freeze_inputs() -> void:
	var q := _freeze_inputs
	_freeze_inputs = []
	for e: Array in q:
		if e[1]:
			press(e[0])
		else:
			release(e[0])

## Enemy attack entry point. `move_id` is an enemy move (MoveLibrary.ENEMY_MOVES).
## Startup: AttackDirector.enemy_startup_frames(move_id) (frames of the enemy's
## own time), or `tell_time` when that is longer (AttackDirector spaces the
## token holders' active frames). The tell (pose + glow, GameEvents.attack_tell)
## covers the whole startup. Returns false if the fighter cannot attack now.
func start_enemy_attack(move_id: StringName, tell_time: float) -> bool:
	var m := MoveLibrary.get_move(move_id)
	if m == null:
		push_warning("CombatController: unknown move %s" % move_id)
		return false
	if not _can_start():
		return false
	var frames: float = Tuning.ENEMY_STARTUP.get(move_id, m.startup)
	if AttackDirector.has_method(&"enemy_startup_frames"):
		frames = float(AttackDirector.call(&"enemy_startup_frames", move_id))
	var startup := maxf(maxf(tell_time, Tuning.frames(frames)), Tuning.frames(Tuning.ENEMY_STARTUP_MIN))
	_press_action = -1
	_move_charge = 0
	_string_pos = 0
	_target = Targeting.pick_strike_target(fighter, fighter.get_forward(), false)
	if _target == null:
		_target = _enemy_reach_target(m, startup)
	# A token holder's one free swing at a knocked-down player (Feel Reference:
	# Running into enemies): it locks onto the body so the swing can land.
	var lock: Fighter = null
	if _target == null and m.kind == &"strike" and AttackDirector.has_method(&"is_player_knocked_down") \
			and bool(AttackDirector.call(&"is_player_knocked_down")):
		var pl: Fighter = AttackDirector.call(&"get_player") if AttackDirector.has_method(&"get_player") \
			else Targeting.player(fighter.get_tree())
		if pl != null and pl.team != fighter.team:
			var to := pl.get_center_of_mass() - fighter.global_position
			to.y = 0.0
			if to.length() <= m.reach * fighter.get_height_scale() + LOCKED_TARGET_REACH + 1.0:
				_target = pl
				lock = pl
	GameEvents.attack_tell.emit(fighter, m.tell_kind, startup)
	_begin(m, startup, true, lock)
	_commit()
	return true

## A ranged enemy move (the heavy's shoulder charge from 5 m) still has a
## target: the player in front within the move's reach plus its lunge, so
## Defence sees it coming.
func _enemy_reach_target(m: MoveData, startup: float) -> Fighter:
	var pl: Fighter = AttackDirector.call(&"get_player") if AttackDirector.has_method(&"get_player") \
		else Targeting.player(fighter.get_tree())
	if pl == null or not is_instance_valid(pl) or pl.team == fighter.team or pl.is_dead() or pl.is_down():
		return null
	var hs := fighter.get_height_scale()
	var lunge := m.lunge_speed * hs * (startup * (1.0 - m.lunge_start) + m.active_s())
	var to := pl.get_ground_position() - fighter.get_ground_position()
	to.y = 0.0
	var d := to.length()
	if d > m.reach * hs + lunge + ENEMY_REACH_MARGIN:
		return null
	if d > 0.05 and fighter.get_forward().dot(to / d) < ENEMY_REACH_FRONT_DOT:
		return null
	return pl

# =============================================================================
# Queries
# =============================================================================

# --- Round 5 contract (agent B implements) -------------------------------------
## The new Carry (G) owns grabs once it is enabled.
func _new_carry() -> bool:
	return fighter != null and fighter.carry != null and fighter.carry.is_enabled()

## The fighter the current attack is aimed at (null when none). Defence and
## the camera read it.
func get_attack_target() -> Fighter:
	if not is_attacking():
		return null
	if _target != null and is_instance_valid(_target) and not _target.is_dead():
		return _target
	if _locked_target != null and is_instance_valid(_locked_target):
		return _locked_target
	return null

## Sprint strike rule: from the press to the end of its active frames this
## fighter's body ignores the target, and Traversal skips the Battering Ram
## collision with anyone (a strike never doubles as a ram).
func suppresses_ram_with(_other: Fighter) -> bool:
	return _phase == Phase.CHARGING or _phase == Phase.STARTUP or _phase == Phase.ACTIVE

func is_attacking() -> bool:
	return _phase != Phase.IDLE

func is_attack_active() -> bool:
	return _phase == Phase.ACTIVE

func is_in_recovery() -> bool:
	return _phase == Phase.RECOVERY

func is_charging() -> bool:
	return _phase == Phase.CHARGING

## Holding a body or a prop (Carry).
func is_holding_grab() -> bool:
	return fighter != null and fighter.carry != null and fighter.carry.is_holding()

## Current move id, or &"" when idle.
func current_move_id() -> StringName:
	if _phase == Phase.IDLE or _move == null:
		return &""
	return _move.id

## Real seconds until the current attack's first active frame (INF if none).
func time_to_active() -> float:
	match _phase:
		Phase.STARTUP:
			# Own time per real second: the player keeps real time in slow motion.
			var own := TimeDirector.player_time_factor() if fighter.is_player else 1.0
			var scale := maxf(Engine.time_scale * own, 0.05)
			var frozen := maxf(_freeze_until - TimeDirector.now(), 0.0)
			return maxf(_startup - _t, 0.0) / scale + frozen
		Phase.ACTIVE:
			return 0.0
	return INF

## Power score parts of the strike in progress (debug overlay): {class, base,
## charge, speed, cap, sprint, finisher}. Empty when not striking.
func get_strike_debug() -> Dictionary:
	if _move == null or _phase == Phase.IDLE or _strike_class == &"":
		return {}
	return {"class": _strike_class, "charge": _move_charge, "speed": _p_speed, "cap": _p_cap,
		"sprint": _p_sprint, "finisher": _p_finisher, "string_pos": _string_pos}

## The Duelist's teleport counter is briefly untouchable (Defence owns the player's).
func is_invulnerable() -> bool:
	return TimeDirector.now() < _teleport_invuln_until

## Vanished mid-teleport (Defence): hits miss, the body is hidden.
func is_vanished() -> bool:
	return fighter != null and fighter.defence != null and fighter.defence.is_vanished()

## Kept for callers of the Upgrade 2 vanish (Defence shows the body itself now).
func force_reappear() -> void:
	pass

## Held by someone (Carry, agent G).
func _held() -> bool:
	return fighter != null and fighter.carry != null and fighter.carry.is_held()

## Holding a body (Carry): no guard, no attacks of ours.
func _holding_body() -> bool:
	return fighter != null and fighter.carry != null and fighter.carry.is_holding_body()

## Any stun (hit or block). Fighter.is_in_hitstun() uses this.
func is_stunned() -> bool:
	return _stun_left > 0.0

## Flinch / stagger / grab-break stun, stumble and daze (not blockstun).
func is_hit_stunned() -> bool:
	return _stun_left > 0.0 and _stun_kind in [Stun.HIT, Stun.STUMBLE, Stun.DAZE]

func is_blocking() -> bool:
	if fighter == null or fighter.is_dead() or _held() or _holding_body():
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

## Parry locked out after a mashed Block (Defence).
func is_dodge_locked_out() -> bool:
	return fighter != null and fighter.defence != null and fighter.defence.is_parry_locked()

func is_dashing() -> bool:
	return _dash_left > 0.0

## Charge 0..1 toward level 3 while charging (HUD), else the last move's level / 3.
func get_charge() -> float:
	if _phase == Phase.CHARGING:
		var held := TimeDirector.now() - _press_t
		return clampf((held - Tuning.HOLD_THRESHOLD) / (Tuning.CHARGE_LEVELS[2] - Tuning.HOLD_THRESHOLD), 0.0, 1.0)
	return _move_charge / 3.0

# --- Movement hooks for Fighter / Traversal --------------------------------------
## Charging while walking moves at Tuning.CHARGE_WALK_MULT; charging at a
## sprint keeps its speed (Traversal steers it, Tuning.CHARGE_SPRINT_STEER).
func get_move_speed_mult() -> float:
	if _held():
		return 0.0
	if _phase == Phase.CHARGING and _stun_left <= 0.0:
		var t := fighter.traversal
		if t != null and (t.is_charge_steering() or t.is_sprinting()):
			return 1.0
		return Tuning.CHARGE_WALK_MULT
	if _phase != Phase.IDLE or _stun_left > 0.0:
		return 0.0
	if is_blocking():
		return BLOCK_WALK_MULT
	return 1.0

func has_forced_velocity() -> bool:
	return _forced_velocity_or_inf() != Vector3.INF

## Horizontal velocity that overrides walking this tick, or Vector3.INF for none.
func get_forced_velocity() -> Vector3:
	return _forced_velocity_or_inf()

func _forced_velocity_or_inf() -> Vector3:
	if _slide_left > 0.0:
		return _slide_velocity
	if _slide_plant and _stun_left > 0.0 and _stun_kind == Stun.BLOCK:
		return Vector3.ZERO  # the guard slid exactly GUARD_PUSH; no drift after it
	if _dash_left > 0.0:
		return _dash_velocity
	if _has_lunge and (_phase == Phase.STARTUP or _phase == Phase.ACTIVE or _phase == Phase.RECOVERY):
		return _lunge_velocity
	# Enemy moves keep their own telegraphed step; a player strike with no
	# target strikes along the stick where it stands (Round 5).
	if _move != null and _move.enemy and _move.lunge_speed > 0.0:
		var e_lunging := (_phase == Phase.STARTUP and _t >= _startup * _move.lunge_start) \
			or (_phase == Phase.ACTIVE and _move.lunge_through_active and not _hit_any)
		if e_lunging:
			return fighter.get_forward() * _move.lunge_speed * fighter.get_height_scale()
	return Vector3.INF

func can_turn() -> bool:
	if _held():
		return false
	if _phase == Phase.CHARGING:
		return true
	if _phase == Phase.ACTIVE or _phase == Phase.RECOVERY:
		return false
	return not is_hit_stunned()

func get_turn_mult() -> float:
	if _phase == Phase.STARTUP:
		return 0.6
	return 1.0

# =============================================================================
# Per-tick update (called by Fighter._physics_process before it moves)
# =============================================================================

func physics_tick(delta: float) -> void:
	if fighter == null or fighter.is_dead():
		return
	var now := TimeDirector.now()
	# The player's combat timers run in player time (full speed in any slow motion).
	if fighter.is_player:
		delta = TimeDirector.player_delta(delta)
	_tick_upgrade2(delta, now)
	if now < _freeze_until or fighter.is_frozen():
		return
	if not _freeze_inputs.is_empty():
		_flush_freeze_inputs()
		if fighter.is_dead():
			return
	if _slide_left > 0.0:
		_slide_left -= delta
	if _stun_left > 0.0:
		_stun_left -= delta
		if _stun_left <= 0.0:
			_stun_left = 0.0
			_on_stun_end()
	if _dash_left > 0.0:
		_dash_left -= delta
		if _dash_left <= 0.0:
			_dash_left = 0.0
	if _vault_action >= 0:
		_tick_vault_press()
	_update_lunge(delta)

	match _phase:
		Phase.CHARGING:
			_tick_charge(now)
		Phase.STARTUP, Phase.ACTIVE, Phase.RECOVERY:
			_advance(delta)

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
	if _phase == Phase.RECOVERY:
		if _hit_cancel_ok(&""):
			var id := _resolve_move(a)
			if id != &"":
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

## Tap vs hold applies to the real player's buttons and to tests and the lab
## (force_hold_charge). Other scripted presses (bots, AI) are taps.
func _hold_enabled(_action: int) -> bool:
	return force_hold_charge or (fighter.brain != null and fighter.brain is PlayerController)

func _attack_press(action: int, now: float) -> void:
	if _phase == Phase.CHARGING or _held():
		return
	# Vault (Feel Reference: attack out of a vault): in its last 40% the vault
	# ends in a dropping strike that inherits the vault speed; earlier (or in a
	# mantle / kick-off, which Traversal refuses) the press waits.
	if _vaulting() and _phase == Phase.IDLE:
		if _vault_progress() >= Tuning.VAULT_ATTACK_FROM and fighter.traversal.begin_drop_strike():
			_drop_from_vault = true
			_start_press(action, &"drop_strike", now, true)
		else:
			_vault_action = action  # earlier (or a mantle): a normal strike once landed
			_vault_press_t = now
		return
	var id := _resolve_move(action)
	if id == &"":
		return
	# A press continuing the string during a move's startup is remembered (L, L, L mashed).
	if _phase == Phase.STARTUP and _move != null and _string_can_continue():
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

## Input token for a press (ComboGraph): button + crouch / back / rising.
func _token(action: int) -> StringName:
	var crouch := fighter.is_crouching()
	var intent := fighter.get_input_intent()
	match action:
		Action.KICK:
			if crouch:
				return ComboGraph.CK
			if intent == &"back":
				return ComboGraph.BK
			return ComboGraph.K
		Action.SWEEP:
			return ComboGraph.BK
		Action.HEAVY:
			if crouch:
				return ComboGraph.CP
			if TimeDirector.now() - _crouch_released_at <= RISING_WINDOW:
				return ComboGraph.RP
			return ComboGraph.H
		_:
			if crouch:
				return ComboGraph.CP
			if intent == &"back":
				return ComboGraph.BP
			if TimeDirector.now() - _crouch_released_at <= RISING_WINDOW:
				return ComboGraph.RP
			return ComboGraph.P

## Strike class of a button for strikes whose class follows the button (the
## dropping strike): Light jab, Heavy cross, Kick kick.
static func class_of_action(action: int) -> StringName:
	match action:
		Action.LIGHT:
			return &"jab"
		Action.HEAVY:
			return &"cross"
	return &"kick"

## The move a press means right now: a dropping strike in the air (or late in a
## vault), a ground strike next to a body on the ground, else the next move of
## the running string (ComboGraph).
func _resolve_move(action: int) -> StringName:
	if _drop_ok():
		return &"drop_strike"
	if fighter.is_player and _pursuit_victim() == null and _ground_target() != null:
		return &"ground_stomp" if action == Action.KICK or action == Action.SWEEP else &"knee_drop"
	return graph.next_move(_string_prev(), _token(action), _next_pos())

## The string move a press follows: the current move, or the last one if it
## ended less than Tuning.STRING_RESET ago. &"" when the string is over.
func _string_prev() -> StringName:
	if _string_pos <= 0:
		return &""
	if _phase != Phase.IDLE and _move != null:
		return _move.id
	if TimeDirector.now() - _last_move_end <= Tuning.STRING_RESET:
		return _last_move_id
	return &""

## The string can take another hit (1st or 2nd hit, all taps so far).
func _string_can_continue() -> bool:
	return _string_prev() != &"" and _string_pos < ComboGraph.MAX_HITS and _string_tap \
		and _move_charge == 0

## 1-based position the next string press plays.
func _next_pos() -> int:
	return _string_pos + 1 if _string_can_continue() else 1

func _start_press(action: int, id: StringName, press_t: float, drop_begun := false) -> void:
	var m := MoveLibrary.get_move(id)
	if m == null:
		return
	# String bookkeeping (ground and dropping strikes stand outside strings).
	if m.ground_strike:
		_string_pos = 0
	elif m.drop:
		_string_pos = 0
	else:
		var pos := _next_pos()
		if pos == 1:
			_string_tap = true
		_string_pos = pos
	_strike_class = class_of_action(action) if m.drop else m.strike_class
	# Target (Feel Reference: Picking the target): turn to it; no target, strike along the stick.
	# A sweep is pull back + Kick: the stick points back at the camera, so the
	# sweep picks its target along the current facing and never turns round.
	var tgt: Fighter = _ground_target() if m.ground_strike else _pick_target(m.sweep)
	_target = tgt
	_drop_from_vault = drop_begun
	if tgt != null:
		fighter.snap_facing(tgt.get_ground_position() - fighter.global_position)
	elif m.hits_behind:
		_turn_to_back()
	elif not m.sweep:
		var stick := _stick()
		if stick.length() > 0.2:
			fighter.snap_facing(stick)
	var hold := _hold_enabled(action) and m.chargeable
	_press_action = action if hold else -1
	_press_t = press_t
	_press_released = not (hold and bool(_btn_down.get(action, false)))
	_charge_level = 0
	_move_charge = 0
	if m.drop and not drop_begun and fighter.traversal != null:
		fighter.traversal.begin_drop_strike()
	_begin(m, -1.0, true, tgt if (m.ground_strike or _is_pursuit_target(tgt)) else null)
	# The speed a tap strikes with is the speed at the press, before any lunge
	# moves the fighter (Feel Reference: sampled at the press, or the charge release).
	_press_sample = _sample_speed()
	if _press_sample[2]:
		_lunge_sprint = true  # a sprint press carries the run from the press
		_lunge_speed = maxf(float(_press_sample[0]), Tuning.WALK_SPEED)
	if _press_released:
		_commit()

## Cancel the current move into a new press (hit cancel or backfist).
func _cancel_into(action: int, id: StringName, now: float) -> void:
	if _move != null:
		_last_move_id = _move.id
		_last_move_end = TimeDirector.now()
	_end_sprint_exception()
	_end_sequence()
	_phase = Phase.IDLE
	_clear_aim()
	_start_press(action, id, float(_btn_time.get(action, now)))

## Cancel rule 1: on HIT, from the end of the active frames for
## MoveData.cancel_window frames, into the string's next hit. Rule 2: no
## cancels on whiff. Rule 4: charged strikes never hit-cancel. Round 5: the
## third hit ends the string (no cancel out of it).
func _hit_cancel_ok(next_id: StringName) -> bool:
	if _move == null or not _hit_confirmed or _move_charge > 0 or _move.enemy:
		return false
	if _phase != Phase.RECOVERY or _t > Tuning.frames(_move.cancel_window):
		return false
	return _string_can_continue()

## Back + Light works at any point of a basic (uncharged) move.
func _can_backfist() -> bool:
	if _move_charge > 0 or _phase == Phase.CHARGING:
		return false
	if fighter.is_down() or is_hit_stunned() or _held():
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
		_target = best
	else:
		fighter.snap_facing(-fwd)

# --- Round 5 targeting (Feel Reference: Picking the target) -------------------------
## Strike aim: the player's stick (camera forward when neutral), else facing.
func _aim_dir() -> Vector3:
	if fighter.brain != null and fighter.brain.has_method(&"get_aim_dir"):
		var d: Vector3 = fighter.brain.call(&"get_aim_dir")
		if d.length_squared() > 1e-4:
			return d
	var s := _stick()
	if s.length() > 0.2:
		return s
	return fighter.get_forward()

## The player's lock-on target (Round 4), or null.
func _lock_target() -> Fighter:
	var t: Fighter = null
	if fighter.brain != null and fighter.brain.has_method(&"get_lock_target"):
		t = fighter.brain.call(&"get_lock_target") as Fighter
	elif fighter.is_inside_tree():
		var rig := fighter.get_tree().get_first_node_in_group(&"camera_rig")
		if rig != null and rig.has_method(&"get_lock_target"):
			t = rig.call(&"get_lock_target") as Fighter
	if t == null or not is_instance_valid(t) or t.is_dead() or t.team == fighter.team:
		return null
	return t

## The strike's target: the pursuit body, the lock-on target, else the best
## scored opponent in the aim cone (Targeting.pick_strike_target).
## along_facing: pick along the current facing instead of the stick (sweeps).
func _pick_target(along_facing := false) -> Fighter:
	var pt := _pursuit_victim()
	if pt != null:
		return pt
	if fighter.is_player:
		var lock := _lock_target()
		if lock != null and not lock.is_down():
			return lock
	var aim := fighter.get_forward() if along_facing else _aim_dir()
	return Targeting.pick_strike_target(fighter, aim, _sprinting_now())

## A body on the ground near enough for a ground strike (lying, or a fleeing
## enemy crawling: Targeting.pick_ground_target), unless a standing opponent is
## closer (you strike him). A body still flying is struck, never stomped.
func _ground_target() -> Fighter:
	if fighter.is_airborne() or (fighter.traversal != null and fighter.traversal.is_airborne()):
		return null
	var aim := _aim_dir()
	var g := Targeting.pick_ground_target(fighter, aim)
	if g == null:
		return null
	if not Targeting.is_crawling(g) and g.combat != null and not g.combat.is_lying():
		return null  # still flying: a strike, not a stomp
	var origin := fighter.get_ground_position()
	var to_g := g.get_center_of_mass() - origin
	to_g.y = 0.0
	var s := Targeting.pick_strike_target(fighter, aim, false)
	if s != null:
		var to_s := s.get_ground_position() - origin
		to_s.y = 0.0
		if to_s.length() < to_g.length():
			return null
	return g

## Sprinting right now (sprint, wall run, sprint charge).
func _sprinting_now() -> bool:
	var t := fighter.traversal
	return t != null and (t.is_sprinting() or t.is_wall_running() or t.is_charge_steering())

func _vaulting() -> bool:
	return fighter.traversal != null and fighter.traversal.is_vaulting()

func _vault_progress() -> float:
	return fighter.traversal.get_vault_progress() if fighter.traversal != null else 0.0

## In the air (a jump, a fall, a kick-off), not wall running, not in parkour
## and not hanging for a pursuit: an attack here is a dropping strike.
func _drop_ok() -> bool:
	if not fighter.is_player or _pursuit_victim() != null:
		return false
	var t := fighter.traversal
	if t != null and (t.is_wall_running() or t.is_vaulting()):
		return false
	return fighter.is_airborne() or (t != null and t.is_airborne())

## Still falling in a dropping strike: Traversal's drop (timed on the real
## landing), else the jump / air state.
func _drop_falling() -> bool:
	var t := fighter.traversal
	if t != null and t.has_method(&"is_drop_striking") and bool(t.call(&"is_drop_striking")):
		return true
	return _in_air()

func _in_air() -> bool:
	var t := fighter.traversal
	if t != null and (t.is_airborne() or t.is_vaulting()):
		return true
	return fighter.is_airborne()

## An attack pressed in the first 60% of a vault (or in a mantle or kick-off)
## is not a dropping strike: it fires as a normal strike once the fighter is
## back on the ground (dropped if that takes longer than VAULT_PRESS_KEEP).
func _tick_vault_press() -> void:
	var a := _vault_action
	var now := TimeDirector.now()
	if now - _vault_press_t > VAULT_PRESS_KEEP:
		_vault_action = -1
		return
	if _vaulting() or _in_air():
		return
	_vault_action = -1
	if _phase == Phase.IDLE:
		_attack_press(a, now)

# --- Commit: the strike's speed sample (Feel Reference: power score) ----------------
## The press for a tap, the release for a charge. Samples the speed toward the
## target BEFORE Traversal.on_strike_started() drops a sprinting player to walk,
## emits strike_started (the AI's sidestep and guard, the whoosh) and decides
## the finisher bonus.
func _commit() -> void:
	if _committed or _move == null:
		return
	_committed = true
	# A tap strikes with the speed of its press; a charge with the speed at its release.
	var sample := _press_sample if (_press_sample.size() == 3 and not _resample) else _sample_speed()
	_resample = false
	_p_speed = sample[0]
	_p_cap = sample[1]
	_p_sprint = sample[2]
	var t := fighter.traversal
	if t != null and not _move.enemy:
		if _p_sprint:
			_lunge_sprint = true
			_lunge_speed = maxf(maxf(_p_speed, _lunge_speed), Tuning.WALK_SPEED)
		else:
			_lunge_sprint = false
		if _move.kind == &"strike" or _move.kind == &"counter":
			t.on_strike_started(_p_sprint)
	if _move_charge > 0:
		_string_tap = false  # charging ends the string after this hit
	# Feel Reference: +1 on the third hit of a tap string.
	_p_finisher = _string_pos == ComboGraph.MAX_HITS and _string_tap and _move_charge == 0
	if _move.kind == &"strike" or _move.kind == &"counter":
		GameEvents.strike_started.emit(fighter, get_attack_target(), _move.id, _p_sprint, _move_charge)

## [speed toward the target, speed cap, sprinting] right now (zeros without Traversal).
func _sample_speed() -> Array:
	var t := fighter.traversal
	if t == null or _move == null or _move.enemy:
		return [0.0, Power.speed_cap(), false]
	return [maxf(t.speed_toward(_speed_dir()), 0.0), t.get_speed_cap(), _sprinting_now() or _drop_from_vault]

## Direction of the speed bonus: toward the target, else facing.
func _speed_dir() -> Vector3:
	if _target != null and is_instance_valid(_target):
		var to := _target.get_ground_position() - fighter.get_ground_position()
		to.y = 0.0
		if to.length_squared() > 1e-4:
			return to.normalized()
	return fighter.get_forward()

## Start a move's startup. startup_override < 0 uses the move's frame data.
func _begin(m: MoveData, startup_override := -1.0, emit_start := true, lock: Fighter = null) -> void:
	if m == null:
		return
	_end_sprint_exception()
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
	_committed = false
	_press_sample = []
	_resample = false
	_p_speed = 0.0
	_p_sprint = false
	_p_finisher = false
	_lunge_sprint = false
	_lunge_speed = 0.0
	_lunge_left = Tuning.LUNGE_MAX
	_has_lunge = false
	_prev_limb = Vector3.INF
	_prev_limbs.clear()
	_buffer_action = -1
	if m.kind != &"strike" and m.kind != &"counter":
		_strike_class = m.strike_class
	if _dash_left > 0.0:
		_dash_left = 0.0
	# The pursuit follow-up, ground strikes and the counter lock onto their body.
	_locked_target = lock
	if blocking:
		blocking = false
	# Sprint strike: from the press to the end of the active frames the capsule ignores the target.
	if fighter.is_player and _sprinting_now() and _target != null and is_instance_valid(_target):
		_sprint_excepted = _target
		fighter.add_collision_exception_with(_target)
		_target.add_collision_exception_with(fighter)
	if emit_start:
		_seq_id = m.id
	if fighter.animator:
		fighter.animator.play_move(m.anim, _startup, _active, m.recovery_s(m.kind != &"grab"))
	if emit_start:
		attack_started.emit(m.id)
	attack_incoming.emit(m.id, time_to_active())
	_update_aim()

func _end_sprint_exception() -> void:
	var t := _sprint_excepted
	_sprint_excepted = null
	if t == null or not is_instance_valid(t) or fighter == null:
		return
	fighter.remove_collision_exception_with(t)
	t.remove_collision_exception_with(fighter)

# --- Lunge: strikes step toward their target ----------------------------------------
## Per tick: the player's strike turns to its target and lunges toward it, up
## to Tuning.LUNGE_MAX over the startup, stopping when the target is LUNGE_GAP
## of the move's reach away. A sprint strike carries its run speed instead and
## stops Tuning.SPRINT_LUNGE_STOP short, through the active frames. Once the
## gap is closed (or the hit lands) the feet are planted: the forced velocity
## is zero, so a run never carries the striker into its target.
func _update_lunge(delta: float) -> void:
	_has_lunge = false
	var tgt := _target
	if tgt == null or _move == null or not is_instance_valid(tgt) or tgt.is_dead():
		if tgt != null and (not is_instance_valid(tgt) or tgt.is_dead()):
			_target = null
			_clear_aim()
		return
	if _phase != Phase.STARTUP and _phase != Phase.ACTIVE and _phase != Phase.RECOVERY:
		return
	if _phase != Phase.RECOVERY:
		_update_aim()
	if not fighter.is_player or _move.drop:
		return
	_lunge_velocity = Vector3.ZERO
	_has_lunge = true
	if _phase == Phase.RECOVERY or (_phase == Phase.ACTIVE and _hit_any):
		return  # connected, or the lunge is over: the feet stay planted (no slide)
	var to := tgt.get_ground_position() - fighter.global_position
	to.y = 0.0
	var d := to.length()
	if d < 0.05:
		return
	var dir := to / d
	fighter.face_dir = dir
	var stop := Tuning.SPRINT_LUNGE_STOP if _lunge_sprint else _move.reach * fighter.get_height_scale() * LUNGE_GAP
	var gap := d - stop
	if gap <= 0.0:
		return
	var speed := 0.0
	if _lunge_sprint:
		var left_s := maxf((_startup - _t) + _active if _phase == Phase.STARTUP else _active - _t, 1.0 / 60.0)
		var want := clampf(gap / left_s, _lunge_speed, _lunge_speed * SPRINT_LUNGE_BOOST)
		speed = minf(want, gap / maxf(delta, 1e-4))
	else:
		if _lunge_left <= 0.0 or _phase != Phase.STARTUP:
			return
		var left := maxf(_startup - _t, 1.0 / 60.0)
		speed = minf(minf(gap, _lunge_left) / left, LUNGE_SPEED_MAX)
		_lunge_left -= speed * delta
	_lunge_velocity = dir * speed

func _update_aim() -> void:
	var tgt := _target
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

# --- Charging (hold to charge; levels in real time) ---------------------------------
static func level_for(held: float) -> int:
	var lvl := 0
	for i in Tuning.CHARGE_LEVELS.size():
		if held >= Tuning.CHARGE_LEVELS[i]:
			lvl = i + 1
	return lvl

func _enter_charge(now: float) -> void:
	_phase = Phase.CHARGING
	_has_lunge = false
	_charge_level = level_for(now - _press_t)
	if fighter.animator:
		fighter.animator.hold_pose(_move.charge_hold if _move.charge_hold != &"" else &"power_charge")
		fighter.animator.set_charge_level(_charge_level)  # tremble grows with the level
	GameEvents.charge_started.emit(fighter, _move.id)
	if _charge_level > 0:
		GameEvents.charge_level_changed.emit(fighter, _charge_level)

func _tick_charge(now: float) -> void:
	var held := now - _press_t
	var lvl := level_for(held)
	if lvl != _charge_level:
		_charge_level = lvl
		if fighter.animator:
			fighter.animator.set_charge_level(lvl)
		GameEvents.charge_level_changed.emit(fighter, lvl)
	_face_target()
	if held >= Tuning.CHARGE_AUTO_RELEASE and _dash_left <= 0.0:
		_press_released = true
		_release_charge()

## Fire the charged move: its full startup plays after the release ("charging
## adds hold time on top"). Released in the air it becomes a dropping strike.
func _release_charge() -> void:
	if _phase != Phase.CHARGING:
		return
	var lvl := _charge_level
	var m := _move
	# Released in the air, or in the last 40% of a vault: a dropping strike.
	var vault_drop := not m.drop and _vaulting() and _vault_progress() >= Tuning.VAULT_ATTACK_FROM \
		and fighter.traversal.begin_drop_strike()
	if vault_drop or (_drop_ok() and not m.drop):
		m = MoveLibrary.get_move(&"drop_strike")
		_strike_class = class_of_action(_press_action) if _press_action >= 0 else _strike_class
		_string_pos = 0
		_drop_from_vault = vault_drop
		if not vault_drop and fighter.traversal != null:
			fighter.traversal.begin_drop_strike()
	_move_charge = lvl
	_press_released = true
	GameEvents.charge_released.emit(fighter, m.id, lvl)
	_move = m
	_phase = Phase.STARTUP
	_t = 0.0
	_startup = m.startup_s()
	_active = m.active_s()
	_recovery = m.recovery_s(true)
	_registry.clear()
	_lunge_left = Tuning.LUNGE_MAX
	if _target != null and is_instance_valid(_target) and not _target.is_dead():
		fighter.snap_facing(_target.get_ground_position() - fighter.global_position)
	if fighter.animator:
		fighter.animator.play_move(m.anim, _startup, _active, _recovery)
	_resample = true
	_commit()
	attack_incoming.emit(m.id, time_to_active())

## While charging, keep facing the target (or re-pick one along the stick).
func _face_target() -> void:
	var t := _target
	if t == null or not is_instance_valid(t) or t.is_dead() or t.is_down():
		t = _pick_target()
		_target = t
	if t == null:
		return
	var to := t.get_ground_position() - fighter.global_position
	to.y = 0.0
	if to.length_squared() > 1e-4:
		fighter.face_dir = to.normalized()

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
		_commit()
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
			if _phase != Phase.ACTIVE:
				return
		if _move.drop:
			var dropping := _drop_falling()
			_drop_t += delta
			if _t >= Tuning.frames(2.0) and not dropping:
				_t = _active  # the dropping strike ends on landing
			elif dropping and _t >= _active and _drop_t < DROP_ACTIVE_LIMIT:
				_t = _active - 1e-4  # a high drop stays active until it lands
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
	_drop_t = 0.0
	_active_start_real = TimeDirector.now()
	_prev_limb = _limb_point()
	_prev_limbs.clear()
	if _move.kind in [&"strike", &"counter", &"grab"]:
		_check_interceptions()
		if _phase != Phase.ACTIVE:
			return  # parried: the parry stagger cancelled this attack
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
	if not _hit_any and _p_sprint:
		_recovery += Tuning.frames(Tuning.SPRINT_WHIFF_FRAMES)  # a missed sprint strike
	_end_sprint_exception()
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
	_target = null
	_has_lunge = false
	_end_sprint_exception()
	_clear_aim()
	_end_sequence()
	_update_block_state()

func _end_sequence() -> void:
	if _seq_id != &"":
		var id := _seq_id
		_seq_id = &""
		attack_ended.emit(id)

## A charge that ends without firing (hit, grab, guard, death): the charge
## glow and sound stop (GameEvents.charge_released at level 0).
func _end_charge_unfired() -> void:
	if _phase == Phase.CHARGING and _move != null and fighter != null:
		GameEvents.charge_released.emit(fighter, _move.id, 0)

## Abort the current move (got hit, launched, died).
func cancel() -> void:
	_end_charge_unfired()
	var was_busy := _phase != Phase.IDLE
	_phase = Phase.IDLE
	_registry.clear()
	_locked_target = null
	_target = null
	_dash_left = 0.0
	_has_lunge = false
	_vault_action = -1
	_end_sprint_exception()
	_clear_aim()
	_press_action = -1
	_press_released = true
	_move_charge = 0
	_string_pos = 0
	if was_busy:
		_end_sequence()
		if fighter and fighter.animator:
			fighter.animator.cancel()
	blocking = false

func _cancel_quiet() -> void:
	_end_charge_unfired()
	var was_busy := _phase != Phase.IDLE
	_phase = Phase.IDLE
	_press_action = -1
	_press_released = true
	_move_charge = 0
	_registry.clear()
	_target = null
	_has_lunge = false
	_end_sprint_exception()
	_clear_aim()
	if was_busy:
		_end_sequence()

## Kept for callers of the Upgrade 2 grab: let go of a held body (Carry's).
func drop_hold() -> void:
	if fighter != null and fighter.carry != null and fighter.carry.is_holding():
		fighter.carry.drop(&"hit")

# --- Reactions (called by Fighter.flinch / stagger / stumble / knockdown / launch) ---
func on_reaction(reaction: int, stun: float) -> void:
	cancel()
	_buffer_action = -1
	drop_debris()
	match reaction:
		HitInfo.Reaction.FLINCH, HitInfo.Reaction.STAGGER:
			_stun_left = maxf(_stun_left, stun)
			_stun_kind = Stun.HIT
		HitInfo.Reaction.LAUNCH:
			_stun_left = 0.0
			_stun_kind = Stun.NONE

func on_death() -> void:
	cancel()
	drop_debris()
	_clear_aim()
	_stun_left = 0.0
	_block_held = false
	blocking = false
	_freeze_inputs.clear()

func _on_stun_end() -> void:
	var was := _stun_kind
	_stun_kind = Stun.NONE
	_slide_plant = false
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
	elif _phase == Phase.IDLE and _stun_left <= 0.0 and not _held() \
			and not (fighter.carry != null and fighter.carry.is_holding()):
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

## Round 5: on the first active frame of every attack, each fighter it is aimed
## at gets the first say: Defence.intercepts() (parry, teleport, sidestep). An
## intercepted attack cannot hit that fighter; with no other hit it whiffs
## (unless the parry already staggered this attacker, which cancels the attack).
func _check_interceptions() -> void:
	var reach := _move.reach * fighter.get_height_scale() + DODGE_CHECK_EXTRA
	var fwd := fighter.get_forward()
	for opp in Targeting.opponents_of(fighter):
		if _phase != Phase.ACTIVE:
			return  # parried: this attack is over
		var to := opp.get_ground_position() - fighter.get_ground_position()
		to.y = 0.0
		var d := to.length()
		if d > reach:
			continue
		if opp != get_attack_target() and d > 0.05 and fwd.dot(to / d) < INTERCEPT_FRONT_DOT:
			continue
		if opp.defence != null and opp.defence.is_enabled() and opp.defence.intercepts(fighter, _move.id):
			_registry[opp.get_instance_id()] = true

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
	# 2. Fallback: capsule forward along facing to the move's reach.
	var fwd := fighter.get_forward()
	var base := fighter.global_position + Vector3.UP * m.height * hs
	var a := base + fwd * 0.2
	var reach_len := m.reach * hs
	var b := base + fwd * reach_len
	var mid := (a + b) * 0.5
	_q_capsule.radius = m.reach_radius
	_q_capsule.height = maxf((b - a).length() + m.reach_radius * 2.0, m.reach_radius * 2.0 + 0.01)
	# Capsule axis is local Y; rotate it onto the facing direction.
	var basis := Basis(Quaternion(Vector3.UP, fwd))
	_query(space, _q_capsule, Transform3D(basis, mid), b, found)
	# 3. Locked target (pursuit follow-up, ground strike, teleport counter) connects if close enough.
	var lt := _locked_target
	if lt != null and is_instance_valid(lt) and _valid_victim(lt) and not found.has(lt):
		var reach := (PURSUIT_REACH if _is_pursuit_target(lt) else m.reach * hs + LOCKED_TARGET_REACH)
		var com := lt.get_center_of_mass()
		var flat := Vector3(com.x - fighter.global_position.x, 0.0, com.z - fighter.global_position.z)
		if flat.length() <= reach and absf(com.y - base.y) < 3.0:
			var bone := m.target_bone
			if m.ground_strike or lt.is_down():
				bone = _nearest_bone(lt, _limb_point() if _limb_point() != Vector3.INF else com)
			found[lt] = [0.0, bone, com]
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

## The victim's physical bone nearest `point` (ground strikes push the nearest bone).
static func _nearest_bone(victim: Fighter, point: Vector3) -> StringName:
	if victim.rig == null:
		return Bones.CHEST
	var best := Bones.CHEST
	var best_d := INF
	for b: StringName in [Bones.HEAD, Bones.CHEST, Bones.SPINE, Bones.HIPS, Bones.L_UPPER_LEG,
			Bones.R_UPPER_LEG, Bones.L_UPPER_ARM, Bones.R_UPPER_ARM]:
		var d := victim.rig.get_bone_global_position(b).distance_to(point)
		if d < best_d:
			best_d = d
			best = b
	return best

# --- Wall strikes (Round 3): the player's punches and kicks hit walls ---------
## A player strike that reaches world geometry with a `receive_strike` method
## (Destructible panels, pillars, props, outer walls) strikes it once per move.
## Fighters win: nothing is struck while an opponent is in the move's reach.
func _try_wall_strike(space: PhysicsDirectSpaceState3D) -> void:
	if _wall_struck or not fighter.is_player or _move == null:
		return
	if _move.kind != &"strike" or _move.ground_hit:
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

## Round 5: strike power on a wall follows the power score, so charge and speed
## count exactly as on a body: WALL_POWER_PER_P x P (counter bonus included).
func strike_power() -> float:
	if _move == null:
		return 0.0
	return WALL_POWER_PER_P * current_power()

## P the current strike would deal now (0 when not striking).
func current_power() -> float:
	if _move == null or _strike_class == &"":
		return 0.0
	return Power.score(Power.base_of(_strike_class), clampi(_move_charge, 0, 3), _p_speed, _p_cap,
		_counter_bonus_now(), _p_finisher)

func _wall_feel(result: StringName, normal: Vector3) -> void:
	var broke := result == &"break" or result == &"hole"
	var stop := Tuning.STRIKE_HITSTOP * (STRIKE_BREAK_HITSTOP_MULT if result == &"break" else 1.0)
	fighter.freeze_hitstop(stop)  # attacker only
	if result in [&"hold", &"chip", &"crack"]:
		var back := Vector3(normal.x, 0.0, normal.z)
		if back.length_squared() < 1e-4:
			back = -fighter.get_forward()
		_fighter_call(&"knockback", [back.normalized() * Tuning.STRIKE_RECOIL, STRIKE_RECOIL_TIME])
	# A one-off (not a hit on a body): wall strikes keep their own shake.
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
## target (or straight ahead) as a projectile.
func _try_debris_kick() -> void:
	if _debris_kicked or not fighter.is_player or _move == null:
		return
	if not (_move.id == &"sparta_kick" or _move.id == &"roundhouse"):
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
	var t := Targeting.pick_strike_target(fighter, _aim_dir(), true)
	if t != null:
		aim = t.get_aim_point() - Vector3.UP * 0.2
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
	var lvl := _effective_level(f)
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
	if result != HitInfo.Result.HIT:
		return
	# The counter bonus lasts until the next hit lands.
	if fighter.defence != null:
		fighter.defence.consume_counter_bonus()
	if info.pursuit and fighter.defence != null:
		fighter.defence.on_pursuit_hit(victim)
	if info.get_meta(&"armored", false):
		return
	_hit_confirmed = true
	_commit_combo(info)
	if _move != null and _move.ground_strike and victim.combat and victim.is_down():
		victim.combat.downed_hits += 1
		if not victim.combat.getup_extended:
			# Keep the body down for the finish: once per knockdown.
			victim.combat.getup_extended = true
			if victim.ragdoll and victim.ragdoll.has_method(&"delay_getup"):
				victim.ragdoll.call(&"delay_getup", GROUND_HOLD)

## A landed hit extends the combo (Tuning.COMBO_DROP) and reports it.
func _commit_combo(info: HitInfo) -> void:
	var now := TimeDirector.now()
	if now - _combo_last > Tuning.COMBO_DROP:
		if _combo_count > 0:
			GameEvents.combo_ended.emit(fighter, _combo_count)
		_combo_count = 0
	_combo_count += 1
	_combo_last = now
	info.combo_index = _combo_count
	GameEvents.combo_progress.emit(fighter, _combo_count, info.damage_scale)

# --- Round 5: the hit an attack deals ------------------------------------------
## Attacker side of the hit pipeline. A player strike gets its power score and
## tier from P (_fill_power); enemy moves deal their preset tier (_fill_preset).
func _build_hit(victim: Fighter, bone: StringName, pos: Vector3) -> HitInfo:
	var m := _move
	var info := HitInfo.new()
	info.attacker = fighter
	info.victim = victim
	info.move_id = m.id
	info.kind = m.kind
	var sdir := _strike_dir(victim)
	var flat := Vector3(sdir.x, 0.0, sdir.z)
	if flat.length_squared() < 1e-4:
		flat = fighter.get_forward()
	info.hit_direction = flat.normalized()
	info.hit_position = pos
	info.set_meta(&"strike_dir", sdir)
	var zone := _strike_zone(victim)
	info.zone = zone
	# The hit chain comes from the hurtbox that was hit (or the aimed bone).
	info.hit_bone = bone
	if m.sweep:
		if not bone in [Bones.L_LOWER_LEG, Bones.R_LOWER_LEG, Bones.L_FOOT, Bones.R_FOOT]:
			info.hit_bone = m.target_bone
	elif m.force_bone and not fighter.is_player:
		info.hit_bone = m.target_bone
	elif fighter.is_player and zone != BodyZones.Zone.TORSO and not m.ground_strike:
		info.hit_bone = fighter.aim_bone_for(victim)
	info.level = _effective_level(victim)
	info.charge_level = clampi(_move_charge, 0, 3)
	info.unblockable = m.unblockable
	if fighter.is_player and _strike_class != &"":
		_fill_power(info, victim)
	else:
		_fill_preset(info, victim)
	return info

## World direction the strike pushes `victim`: MoveData.push_dir in the frame
## of the line from the attacker to the victim (a hook turns the head across,
## an uppercut lifts, a roundhouse sweeps sideways).
func _strike_dir(victim: Fighter) -> Vector3:
	var base := victim.get_ground_position() - fighter.get_ground_position()
	base.y = 0.0
	base = base.normalized() if base.length() > 0.05 else fighter.get_forward()
	if _move == null:
		return base
	if _move.kind == &"counter":
		base = fighter.get_forward()
	var p := _move.push_dir
	var right := base.cross(Vector3.UP).normalized()
	var d := right * p.x + Vector3.UP * p.y + base * p.z
	return d.normalized() if d.length_squared() > 1e-6 else base

## Counter bonus on the next landed hit: Defence's (parry +2.5, teleport +3).
func _counter_bonus_now() -> float:
	return fighter.defence.counter_bonus() if fighter.defence != null else 0.0

## The flying body a pursuit is chasing (Defence).
func _pursuit_victim() -> Fighter:
	var v: Fighter = null
	if fighter.defence != null:
		v = fighter.defence.get_pursuit_target()
	if v == null or not is_instance_valid(v) or v.is_dead():
		return null
	return v

func _is_pursuit_target(f: Fighter) -> bool:
	return f != null and f == _pursuit_victim()

## P, tier, launch, damage of a player strike (Feel Reference: One power number
## decides the reaction). The victim's state decides what the body can do with
## the tier: a pursuit always relaunches; a body lying on the floor (and any
## ground strike) only takes a nudge; a flying body relaunches up to
## Tuning.JUGGLE_MAX_RELAUNCH times per flight, then only takes nudges.
func _fill_power(info: HitInfo, victim: Fighter) -> void:
	var m := _move
	var cls := _strike_class
	var lvl := info.charge_level
	var base := Power.base_of(cls)
	var counter := _counter_bonus_now()
	var p := Power.score(base, lvl, _p_speed, _p_cap, counter, _p_finisher)
	info.power = p
	# Raw class base (lead decision): P = power_base x Power.charge_mult(charge_level)
	# + speed_bonus + counter_bonus + finisher_bonus.
	info.power_base = base
	info.speed_bonus = Power.speed_bonus(_p_speed, _p_cap)
	info.counter_bonus = counter
	info.finisher_bonus = Tuning.FINISHER_BONUS if _p_finisher else 0.0
	info.sprint = _p_sprint
	info.ground_strike = m.ground_strike
	var tier := Power.sweep_tier_of(p) if m.sweep else Power.tier_of(p)
	var vc := victim.combat
	var mass := victim.get_total_mass()
	var heavy := victim.is_heavy()
	var lying := vc != null and vc.is_lying()
	var flying := victim.is_launched() and not lying
	var vel := Vector3.ZERO
	var nudge := false
	# A sweep tops out at the launch tier: it also flies like one (no hard-launch speed or angle).
	var pl := minf(p, Tuning.TIER_BANDS[3] - 0.001) if m.sweep else p
	if _is_pursuit_target(victim):
		# Pursuit: relaunch at max(current speed, v(P + 3)) where the stick points.
		info.pursuit = true
		tier = maxi(tier, HitInfo.Tier.LAUNCH)
		var dir := info.hit_direction
		var stick := _stick()
		if stick.length() > 0.2:
			dir = Vector3(stick.x, 0.0, stick.z).normalized()
		info.hit_direction = dir
		var speed := Power.pursuit_speed(pl, victim.get_com_velocity().length(), mass, heavy)
		var a := deg_to_rad(Power.launch_angle(pl + Tuning.PURSUIT_POWER_ADD))
		vel = (dir * cos(a) + Vector3.UP * sin(a)) * speed
	elif m.ground_strike or lying:
		nudge = true  # never relaunches a body on the floor
	elif flying:
		if HitInfo.is_launch_tier(tier) and (vc == null or vc.juggle_relaunches < Tuning.JUGGLE_MAX_RELAUNCH):
			info.juggle = true
			vel = Power.launch_velocity(pl, info.hit_direction, mass, heavy)
			var cur := victim.get_com_velocity()
			if cur.length() > vel.length():
				vel = vel.normalized() * cur.length()  # a relaunch redirects, never slows
		else:
			if HitInfo.is_launch_tier(tier):
				info.set_meta(&"juggle_capped", true)
			nudge = true
	elif HitInfo.is_launch_tier(tier):
		vel = Power.launch_velocity(pl, info.hit_direction, mass, heavy)
	if nudge:
		tier = HitInfo.Tier.FLINCH
		info.set_meta(&"nudge", clampf(0.5 + NUDGE_PER_P * p, 0.5, NUDGE_MAX))
	if tier == HitInfo.Tier.SEVER:
		var cut := _sever_cut(victim, info)
		if cut == &"":
			tier = HitInfo.Tier.HARD_LAUNCH  # gore off, or no limb left to take
		else:
			info.sever_cut = cut
	info.tier = tier
	info.reaction = HitInfo.reaction_for_tier(tier)
	info.launch_velocity = vel if HitInfo.is_launch_tier(tier) else Vector3.ZERO
	info.hitstop = Power.hitstop_for(tier)
	info.is_finisher = tier == HitInfo.Tier.SEVER
	# Damage: strike damage (combo scaled) + launch damage + a limb.
	var n := vc.next_taken_index() if vc != null else get_combo_count() + 1
	var scale := combo_scale(n)
	var dmg := Power.strike_damage(cls, lvl) * scale
	if HitInfo.is_launch_tier(tier):
		dmg += Power.launch_damage(pl, victim.max_hp)
	if info.sever_cut != &"":
		dmg += Tuning.LIMB_LOST_DAMAGE
	info.damage = dmg * _damage_mult()
	if victim.is_fleeing():
		info.damage = maxf(info.damage, victim.hp)  # any landed strike finishes a fleeing enemy
	info.damage_scale = scale
	info.combo_index = n
	info.energy = _energy_of(info, mass)

## Enemy moves (and the Duelist's counter) deal a preset tier: punches and
## kicks flinch or stagger, the heavy's charge and grab-throws knock down.
## Enemies never launch the player or take its limbs.
func _fill_preset(info: HitInfo, victim: Fighter) -> void:
	var m := _move
	var tier := m.preset_tier if m.preset_tier >= 0 else HitInfo.Tier.FLINCH
	if victim.is_player:
		tier = mini(tier, HitInfo.Tier.KNOCKDOWN)
	var vc := victim.combat
	if vc != null and vc.is_lying():
		# A swing at a body on the floor (the free swing at a downed player):
		# damage and a push into the nearest bone; it never knocks it down again.
		tier = HitInfo.Tier.FLINCH
		info.set_meta(&"nudge", 1.0)
	var n := vc.next_taken_index() if vc != null else 1
	var scale := combo_scale(n)
	var dmg: float = Tuning.DMG_ENEMY.get(m.id, m.damage)
	info.tier = tier
	info.reaction = HitInfo.reaction_for_tier(tier)
	info.hitstop = Power.hitstop_for(tier)
	if HitInfo.is_launch_tier(tier):
		info.launch_velocity = Power.launch_velocity(Tuning.TIER_BANDS[2], info.hit_direction,
			victim.get_total_mass(), victim.is_heavy())
	info.damage = dmg * scale * _damage_mult()
	info.damage_scale = scale
	info.combo_index = n
	info.energy = _energy_of(info, victim.get_total_mass())

## HitInfo.energy for old listeners: the launch's kinetic energy, else a
## nominal body speed by tier.
static func _energy_of(info: HitInfo, mass: float) -> float:
	if HitInfo.is_launch_tier(info.tier):
		return 0.5 * mass * info.launch_velocity.length_squared()
	var v: float = NOMINAL_SPEED.get(info.tier, 2.0)
	return 0.5 * mass * v * v

## Which limb a severing launch takes: the hit hurtbox's limb, or for head and
## torso hits the arm nearest the hit point. &"" when gore is off or none is left.
func _sever_cut(victim: Fighter, info: HitInfo) -> StringName:
	if Tuning.gore != Tuning.Gore.DISMEMBER or victim.rig == null or victim.is_player:
		return &""
	if victim.has_method(&"get_lost_limbs") and victim.get_lost_limbs().size() >= Fighter.MAX_SEVERS:
		return &""  # no more limbs come off this body: a hard launch
	var cut := Bones.limb_cut_for(info.hit_bone)
	if cut != &"" and not _cut_gone(victim, cut):
		return cut
	var best: StringName = &""
	var best_d := INF
	for c: StringName in [&"arm_l", &"arm_r"]:
		if _cut_gone(victim, c):
			continue
		var d := victim.rig.get_bone_global_position(Bones.CUTS[c]).distance_to(info.hit_position)
		if d < best_d:
			best_d = d
			best = c
	return best

static func _cut_gone(victim: Fighter, cut: StringName) -> bool:
	return victim.rig.is_severed(cut) or (victim.rig.has_method(&"is_bone_severed") \
		and victim.rig.is_bone_severed(Bones.CUTS[cut]))

## Zone a strike lands in on `victim`: the player's aimed zone only on the
## aimed target (Fighter.zone_for), else the torso.
func _strike_zone(victim: Fighter) -> int:
	if fighter.is_player and _move != null and (_move.kind == &"strike" or _move.kind == &"counter"):
		return fighter.zone_for(victim)
	return BodyZones.Zone.TORSO

## Attack height of the current move on `victim`; strikes aimed at its head are high.
func _effective_level(victim: Fighter) -> int:
	if _move == null:
		return HitInfo.Level.MID
	if _move.kind == &"strike" and _strike_zone(victim) == BodyZones.Zone.HEAD:
		return HitInfo.Level.HIGH
	return _move.hit_level

## Unit XZ direction to the nearest wall or pillar within max_dist (ZERO if
## none): ImpactResolver.nearest_wall_dir(), with our own ray fan as a
## fallback while it is a stub.
func nearest_wall_dir(from: Vector3, max_dist := 10.0) -> Vector3:
	var wd: Vector3 = ImpactResolver.nearest_wall_dir(from, max_dist)
	if wd != Vector3.ZERO:
		return wd
	if fighter == null or not fighter.is_inside_tree():
		return Vector3.ZERO
	var space := fighter.get_world_3d().direct_space_state
	var origin := Vector3(from.x, maxf(from.y, fighter.global_position.y + 0.9), from.z)
	var best := Vector3.ZERO
	var best_d := max_dist
	for i in 16:
		var a := TAU * float(i) / 16.0
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

## Defender side of the hit pipeline: Defence / dodge, guard, armor and
## ignore_flinch, damage, the contact frame, then the reaction by tier.
## Returns HitInfo.Result.
func receive_hit(info: HitInfo) -> int:
	info.victim = fighter
	last_received = info
	if fighter.is_dead():
		info.result = HitInfo.Result.IGNORED
		return info.result
	_resolve_tier(info)
	match info.kind:
		&"throw":
			return _apply_hit(info)
		&"bowl":
			if fighter.is_invulnerable():
				return _ignored(info)
			return _apply_hit(info)
	if fighter.defence != null and fighter.defence.is_vanished():
		info.result = HitInfo.Result.DODGED
		last_result = info.result
		return info.result
	if fighter.is_invulnerable():
		return _ignored(info)
	if not info.unblockable and _blocks(info):
		return _apply_block(info)
	return _apply_hit(info)

## Hits from sources that set neither tier nor power (older callers) get a tier
## from their legacy reaction; power-scored ones from P.
static func _resolve_tier(info: HitInfo) -> void:
	if info.tier != HitInfo.Tier.NONE:
		return
	if info.power > 0.0:
		var m := MoveLibrary.get_move(info.move_id)
		info.tier = Power.sweep_tier_of(info.power) if m != null and m.sweep else Power.tier_of(info.power)
	else:
		match info.reaction:
			HitInfo.Reaction.FLINCH:
				info.tier = HitInfo.Tier.FLINCH
			HitInfo.Reaction.STAGGER:
				info.tier = HitInfo.Tier.STAGGER
			HitInfo.Reaction.LAUNCH:
				info.tier = HitInfo.Tier.LAUNCH
	if info.hitstop <= 0.0 and info.tier != HitInfo.Tier.NONE:
		info.hitstop = Power.hitstop_for(info.tier)

func _ignored(info: HitInfo) -> int:
	info.result = HitInfo.Result.IGNORED
	last_result = info.result
	return info.result

## Holding Block guards strikes from the front (a crouching guard stops lows,
## a standing one highs and mids). Round 5: a launch-tier strike (P 5 and up)
## breaks through any guard: "launches can happen from any strike".
func _blocks(info: HitInfo) -> bool:
	if not (info.kind == &"strike" or info.kind == &"projectile"):
		return false
	# Break-away auto-guard: frontal strikes count as blocked (grabs still work).
	if TimeDirector.now() < _escape_guard_until and _attacker_in_front(info, GUARD_FRONT_DOT) \
			and not fighter.is_down():
		info.set_meta(&"escape_guard", true)
		return true
	if is_dazed() or is_stumbling():
		return false  # no guard off balance
	if HitInfo.is_launch_tier(info.tier):
		return false
	var front := _attacker_in_front(info, GUARD_FRONT_DOT)
	if is_blocking():
		if not front:
			return false
		if fighter.is_crouching():
			if info.level != HitInfo.Level.LOW:
				return false
		elif info.level == HitInfo.Level.LOW:
			return false
		if fighter.config.get("blocks_jabs", false):
			return _is_jab(info) or _is_kick(info)  # legacy Brawler guard: jabs and kicks only
		return true
	# Legacy archetypes (out of Round 5 waves): passive blocks.
	if fighter.is_down() or _held() or is_hit_stunned():
		return false
	if fighter.get_state() != RagdollController.State.ANIMATED or not front:
		return false
	if info.level == HitInfo.Level.LOW:
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

## Guard (Feel Reference: Holding Block): Tuning.GUARD_DAMAGE_MULT of the
## damage; a stagger-tier or heavier hit pushes the guard back Tuning.GUARD_PUSH m.
func _apply_block(info: HitInfo) -> int:
	info.result = HitInfo.Result.BLOCKED
	last_result = info.result
	var m := MoveLibrary.get_move(info.move_id)
	var stun := Tuning.frames(m.blockstun if m else 10.0)
	var heavy_hit := info.tier >= HitInfo.Tier.STAGGER
	info.set_meta(&"guarded_tier", info.tier)
	var chip := info.damage * Tuning.GUARD_DAMAGE_MULT
	info.damage = chip
	info.tier = HitInfo.Tier.NONE
	info.reaction = HitInfo.Reaction.NONE
	info.launch_velocity = Vector3.ZERO
	var push := Tuning.GUARD_PUSH if heavy_hit else 0.0
	var auto_guard: bool = info.get_meta(&"escape_guard", false)
	if auto_guard:
		push = 0.0  # no blockstun or slide: the break-away keeps the fighter free
	elif _phase == Phase.IDLE:
		# A real guard (or an idle archetype block): blockstun, push-back, block-hit pose.
		var guard := is_blocking()
		_stun_left = maxf(_stun_left, stun)
		_stun_kind = Stun.BLOCK
		_guard_stun = guard
		var d := Vector3(info.hit_direction.x, 0.0, info.hit_direction.z)
		if push > 0.0 and d.length_squared() > 1e-4:
			_slide_velocity = d.normalized() * push / BLOCK_PUSH_TIME
			_slide_left = BLOCK_PUSH_TIME
		_slide_plant = true
		if fighter.animator:
			fighter.animator.play_move(&"block_hit", Tuning.frames(2), Tuning.frames(2), maxf(stun - Tuning.frames(4), 0.05))
		blocking = false  # re-held when blockstun ends
	_freeze_pair(info.attacker as Fighter, Power.hitstop_for(HitInfo.Tier.FLINCH), true)
	fighter.apply_damage(chip, &"block", info)
	GameEvents.hit_blocked.emit(info)
	hit_received.emit(info)
	return info.result

## Contact-frame hitstop on this fighter (the victim) and the attacker only;
## the player's own freeze never passes Tuning.PLAYER_HITSTOP_MAX.
func _freeze_pair(att: Fighter, duration: float, victim_too: bool) -> void:
	if duration <= 0.0:
		return
	var now := TimeDirector.now()
	if victim_too:
		var hv := minf(duration, Tuning.PLAYER_HITSTOP_MAX) if fighter.is_player else duration
		TimeDirector.hitstop([fighter], hv)
		freeze_until(now + hv)
	if att != null and is_instance_valid(att) and att != fighter:
		var ha := minf(duration, Tuning.PLAYER_HITSTOP_MAX) if att.is_player else duration
		TimeDirector.hitstop([att], ha)
		if att.combat != null:
			att.combat.freeze_until(now + ha)

func _apply_hit(info: HitInfo) -> int:
	info.result = HitInfo.Result.HIT
	last_result = info.result
	var att := info.attacker as Fighter
	var tier := info.tier
	if HitInfo.is_launch_tier(tier) and info.launch_velocity.length_squared() < 1e-4 \
			and not info.has_meta(&"nudge"):
		# A preset launch with no velocity: the band's lowest launch.
		var bp: float = Tuning.TIER_BANDS[clampi(tier - HitInfo.Tier.LAUNCH + 2, 2, 4)]
		info.launch_velocity = Power.launch_velocity(bp, info.hit_direction, fighter.get_total_mass(), fighter.is_heavy())
	# Heavies (ignore_flinch) take the damage but only a stagger or more
	# interrupts them; Upgrade 2 tell armor (legacy archetypes, the Duelist) too.
	if info.kind != &"throw" and info.kind != &"bowl" \
			and not info.has_meta(&"nudge"):
		var light := tier == HitInfo.Tier.FLINCH or tier == HitInfo.Tier.STUMBLE
		if light and bool(fighter.config.get("ignore_flinch", false)):
			return _apply_armor(info)
		var armor := get_armor_level()
		if (light and armor >= 1) or (tier == HitInfo.Tier.STAGGER and armor >= 2):
			return _apply_armor(info)
	var lethal := info.damage >= fighter.hp
	# Anti-infinite (every fighter): hits taken from anyone, stun decay, break-away.
	var n := next_taken_index()
	var decay := stun_decay(n)
	var escape := not lethal and _breakaway_due(info, n, decay)
	_register_taken()
	info.set_meta(&"decay", decay)
	if escape:
		_break_away(info, att)
	elif info.juggle:
		juggle_relaunches += 1
	# Contact frame: the reaction now, then the freeze holds the body in its
	# contact pose (RagdollController) and releases it with the cached
	# animation velocities + the impulse. A lethal hit only keeps its launch.
	if not escape and info.tier != HitInfo.Tier.NONE \
			and (not lethal or HitInfo.is_launch_tier(info.tier)):
		_react(info)
	# A hit that does nothing to a body on the floor freezes only the attacker,
	# so the body's grounding and get-up timers keep running.
	var victim_freezes := not (info.has_meta(&"nudge") and is_lying())
	if victim_freezes:
		_fighter_call(&"set_hitstop_jitter", [_jitter_for(info.tier)])
	_freeze_pair(att, info.hitstop, victim_freezes)
	fighter.apply_damage(info.damage, info.move_id, info)
	GameEvents.hit_landed.emit(info)
	hit_received.emit(info)
	return info.result

## Mesh jitter for a tier (Tuning.HITSTOP_JITTER_RANGE, flinch to sever).
static func _jitter_for(tier: int) -> float:
	var r := Tuning.HITSTOP_JITTER_RANGE
	var k := clampf(float(tier - HitInfo.Tier.FLINCH) / float(HitInfo.Tier.SEVER - HitInfo.Tier.FLINCH), 0.0, 1.0)
	return lerpf(r.x, r.y, k)

## The body's reaction to a hit by tier (Feel Reference: Partial ragdoll
## reactions): flinch the hit chain, stumble the hit leg, stagger the upper
## body (legs animated), knock down, or launch (a severing launch takes the
## limb and still launches). Act-again times from Tuning.REACT_*; ground time
## through RagdollController.set_getup_after().
func _react(info: HitInfo) -> void:
	if fighter == null or not is_instance_valid(fighter):
		return
	var tier := info.tier
	var dir3: Vector3 = info.get_meta(&"strike_dir", info.hit_direction)
	var flat := info.hit_direction
	var decay: float = info.get_meta(&"decay", 1.0)
	if fighter.is_dead():
		if HitInfo.is_launch_tier(tier):
			_launch_body(info)
		return
	if info.has_meta(&"nudge"):
		fighter.flinch(dir3, info.hit_bone, float(info.get_meta(&"nudge")))
		return
	match tier:
		HitInfo.Tier.FLINCH:
			fighter.flinch(dir3, info.hit_bone, 1.0)
			_set_hit_stun(float(Tuning.REACT_FLINCH["act"]) * decay)
		HitInfo.Tier.STUMBLE:
			var stun := float(Tuning.REACT_STUMBLE["act"]) * decay
			fighter.stumble(flat, _leg_bone_for(info))
			_set_hit_stun(stun)
			_stun_kind = Stun.STUMBLE
			GameEvents.stumbled.emit(fighter, stun)
		HitInfo.Tier.STAGGER:
			fighter.stagger(flat, STAGGER_STRENGTH)
			_set_hit_stun(float(Tuning.REACT_STAGGER["act"]) * decay)
		HitInfo.Tier.KNOCKDOWN:
			fighter.knockdown(flat, info.hit_bone)
			_set_getup(Tuning.REACT_KNOCKDOWN["ground"])
		HitInfo.Tier.LAUNCH, HitInfo.Tier.HARD_LAUNCH, HitInfo.Tier.SEVER:
			_launch_body(info)
			_set_getup(Tuning.REACT_LAUNCH["ground"])

## Launch the body so it flies at info.launch_velocity (a relaunch sets the
## flight, it does not add to it). A severing launch takes its limb first, in
## the same frame, so the loose limb flies off with the launch.
func _launch_body(info: HitInfo) -> void:
	var change := info.launch_velocity
	if fighter.is_body_simulating():
		change = info.launch_velocity - fighter.get_com_velocity()
	if info.sever_cut != &"":
		fighter.sever_limb(info.sever_cut)
	fighter.launch(change, info.hit_position, info.hit_bone)
	var m := MoveLibrary.get_move(info.move_id)
	if m != null and m.sweep:
		_sweep_legs(info.hit_direction)  # upended: the legs go first

func _set_getup(ground: Vector2) -> void:
	if fighter.ragdoll == null:
		return
	var t := Tuning.PLAYER_GETUP_AFTER if fighter.is_player else randf_range(ground.x, ground.y)
	fighter.ragdoll.set_getup_after(t)

## The leg a stumble buckles: the hit leg, else the lower leg nearest the hit.
func _leg_bone_for(info: HitInfo) -> StringName:
	match info.hit_bone:
		Bones.L_UPPER_LEG, Bones.L_LOWER_LEG, Bones.L_FOOT:
			return Bones.L_LOWER_LEG
		Bones.R_UPPER_LEG, Bones.R_LOWER_LEG, Bones.R_FOOT:
			return Bones.R_LOWER_LEG
	if fighter.rig == null:
		return Bones.L_LOWER_LEG
	var dl := fighter.rig.get_bone_global_position(Bones.L_LOWER_LEG).distance_to(info.hit_position)
	var dr := fighter.rig.get_bone_global_position(Bones.R_LOWER_LEG).distance_to(info.hit_position)
	return Bones.L_LOWER_LEG if dl <= dr else Bones.R_LOWER_LEG

## Damage, no reaction: heavies under a stagger (ignore_flinch) and Upgrade 2
## tell armor. The hit still lands (hit_landed: flash, sound) and the
## attacker feels it.
func _apply_armor(info: HitInfo) -> int:
	_register_taken()
	info.set_meta(&"armored", true)
	info.reaction = HitInfo.Reaction.NONE
	info.launch_velocity = Vector3.ZERO
	_freeze_pair(info.attacker as Fighter, ARMOR_HITSTOP, true)
	fighter.apply_damage(info.damage, info.move_id, info)
	GameEvents.hit_landed.emit(info)
	GameEvents.armor_absorbed.emit(info)
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

## Act-again time after a flinch, stumble or stagger: set (not extended) and
## summed for the break-away.
func _set_hit_stun(t: float) -> void:
	_stun_left = t
	_stun_kind = Stun.HIT
	_taken_stun += t

## Act-again time of a tier before decay (0 for tiers that leave no stun).
static func stun_of_tier(tier: int) -> float:
	match tier:
		HitInfo.Tier.FLINCH:
			return float(Tuning.REACT_FLINCH["act"])
		HitInfo.Tier.STUMBLE:
			return float(Tuning.REACT_STUMBLE["act"])
		HitInfo.Tier.STAGGER:
			return float(Tuning.REACT_STAGGER["act"])
	return 0.0

## The hit that would be number Tuning.COMBO_ESCAPE_HITS, or that would push the
## combo's stun past Tuning.COMBO_ESCAPE_STUN, breaks the fighter away. A
## knockdown or launch ends a loop by itself.
func _breakaway_due(info: HitInfo, n: int, decay: float) -> bool:
	if info.tier >= HitInfo.Tier.KNOCKDOWN or info.has_meta(&"nudge"):
		return false
	if not (info.kind == &"strike" or info.kind == &"projectile") or fighter.is_down():
		return false
	if n >= Tuning.COMBO_ESCAPE_HITS:
		return true
	var stun := stun_of_tier(info.tier) * decay
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
	info.tier = mini(info.tier, HitInfo.Tier.FLINCH)  # the hit lands; the stun does not
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

## Off balance for `duration`: cannot attack or block (grabs always connect).
func apply_stumble(duration: float) -> void:
	if fighter.is_dead() or fighter.is_down():
		return
	cancel()
	_stun_left = maxf(_stun_left, duration)
	_stun_kind = Stun.STUMBLE
	if fighter.animator:
		fighter.animator.hold_pose(_hold_or(&"stumble", &"stagger"))
	GameEvents.stumbled.emit(fighter, duration)

## Hunched, no actions for `duration` (Upgrade 2 headbutt while holding).
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

## Fighter helpers that live in agent H's fighter.gd; skipped if renamed.
func _fighter_call(method: StringName, args: Array) -> void:
	if fighter.has_method(method):
		fighter.callv(method, args)

## Upended by a launch-tier sweep: the legs go out from under the body.
func _sweep_legs(direction: Vector3) -> void:
	var rig := fighter.rig
	if rig == null or fighter.ragdoll == null:
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
# The Duelist's teleport counter (AI) and the fallback dash
# =============================================================================

## AI teleport counter (Duelist): costs Tuning.TELEPORT_COST Focus, teleports
## behind `target` (the first free spot of Tuning.TELEPORT_SPOTS, as the
## player's teleport), shows a blue tell (attack_tell kind
## &"counter") for `tell_time`, then a back_kick (on the player: a knockdown).
## The player can parry it or teleport away (Defence). Returns false if it
## cannot happen.
func start_counter(target: Fighter, tell_time: float) -> bool:
	if fighter == null or fighter.is_dead() or fighter.is_down() or _held() or _holding_body():
		return false
	if target == null or not is_instance_valid(target) or target.is_dead() or target.is_down():
		return false
	if not (_phase == Phase.IDLE or _phase == Phase.RECOVERY) or is_hit_stunned():
		return false
	if fighter.focus + 1e-4 < Tuning.TELEPORT_COST:
		return false
	var spot := _find_counter_spot(target)
	if spot == Vector3.INF:
		return false
	fighter.spend_focus(Tuning.TELEPORT_COST)
	_teleport_invuln_until = TimeDirector.now() + AI_COUNTER_INVULN
	_teleport_behind(target, spot)
	var startup := maxf(tell_time, Tuning.frames(Tuning.ENEMY_STARTUP_MIN))
	GameEvents.attack_tell.emit(fighter, &"counter", startup)
	_string_pos = 0
	_strike_class = &""
	_target = target
	_begin(MoveLibrary.get_move(&"back_kick"), startup, true, target)
	_commit()
	return true

func _teleport_behind(target: Fighter, spot: Vector3) -> void:
	_cancel_quiet()
	var look := target.get_ground_position() - spot
	fighter.teleport_to(spot, look)
	if fighter.rig:
		CombatFX.puff(fighter.get_aim_point())
	GameEvents.teleport_counter.emit(fighter, target)

func _find_counter_spot(target: Fighter) -> Vector3:
	var tp := target.get_ground_position()
	var tf := target.get_forward()
	var right := tf.cross(Vector3.UP).normalized()
	for sp: Vector2 in Tuning.TELEPORT_SPOTS:
		var c := tp - tf * sp.y + right * sp.x
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

## The fallback dash for a fighter without Traversal (no enemy needs more):
## a short burst along its move input when it is free to act.
func _on_dash_pressed(now: float) -> void:
	if now < _dash_cooldown_until or not _can_start():
		return
	var dir := Vector3(fighter.move_input.x, 0.0, fighter.move_input.z)
	if dir.length() < 0.2:
		dir = fighter.get_forward()
	_dash_velocity = dir.normalized() * Tuning.DASH_SPEED
	_dash_left = Tuning.DASH_TIME
	_dash_cooldown_until = now + Tuning.DASH_TIME + Tuning.DASH_COOLDOWN

# =============================================================================
# Enemy grabs (the player's grabs, holds and throws are Carry's, agent G)
# =============================================================================

## Active frames of an enemy grab move (e_grab, e_grab_slam): the first fighter
## in front within reach that Carry lets connect is held (Carry runs the hold,
## the break window and the throw or slam). Defence already had its say on the
## first active frame (_check_interceptions).
func _detect_grab() -> void:
	if not _move.enemy:
		return
	var reach := _move.reach * fighter.get_height_scale()
	var fwd := fighter.get_forward()
	var best: Fighter = null
	var best_d := INF
	for opp in Targeting.opponents_of(fighter):
		if _registry.has(opp.get_instance_id()) or opp.carry == null or opp.is_down():
			continue
		if opp.is_crouching():
			continue  # standing grabs whiff on a crouching fighter
		var to := opp.get_ground_position() - fighter.get_ground_position()
		to.y = 0.0
		var d := to.length()
		if d > reach or (d > 0.05 and fwd.dot(to / d) < GRAB_CONE_DOT):
			continue
		if d < best_d:
			best_d = d
			best = opp
	if best == null:
		return
	if best.carry.is_enabled() and best.carry.connect_enemy_grab(best, _move.id):
		_registry[best.get_instance_id()] = true
		_hit_any = true

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
	if fighter.is_dead() or fighter.is_down() or _held() or _holding_body():
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

## Damage multiplier of this fighter's attacks: its archetype's damage_mult
## (the Duelist) x AIBrain.get_damage_mult() (one-armed enemies hit at half).
func _damage_mult() -> float:
	var m := float(fighter.config.get("damage_mult", 1.0))
	if fighter.brain != null and fighter.brain.has_method(&"get_damage_mult"):
		m *= float(fighter.brain.call(&"get_damage_mult"))
	return m

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
		juggle_relaunches = 0
		getup_extended = false
	if _taken > 0 and now - _taken_last > Tuning.COMBO_DROP:
		_taken = 0
		_taken_stun = 0.0
	if _combo_count > 0 and now - _combo_last > Tuning.COMBO_DROP:
		GameEvents.combo_ended.emit(fighter, _combo_count)
		_combo_count = 0
