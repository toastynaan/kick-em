class_name Carry
extends Node
## Round 5 grabs (Feel Reference: Grab spec): grabbing on the move, holding a
## body as a partial ragdoll, carrying it through runs, jumps and vaults, the
## hold actions (knees, throws, body slam, release), thrown bodies as
## projectiles, props in hand, and being grabbed (victim side, grab break).
## OWNER: agent G (grabs & carry). CONTRACT STUB: keep every public signature.
##
## Contract:
## - Fighter creates this node for every fighter (setup(fighter)).
## - While is_enabled() is false CombatController keeps its Upgrade 2 grab.
##   When true, CombatController routes every Grab press/release here, and every
##   attack press/release while is_holding() (on_attack_pressed returns true when
##   it consumed the press).
## - An enemy grab move's active frames touching a fighter call connect_enemy_grab().
## - Traversal reads get_move_speed_mult(), get_sprint_cap_mult() and
##   get_vault_max_height() while holding.
##
## How it works (agent G):
## - Player grab (on_grab_pressed): the target is picked at the press like a
##   strike (cone around the stick, Targeting.strike_score) among grabbable
##   bodies: standing, stunned, ragdolling (flying or down) and dead enemies.
##   Standing or walking: Tuning.GRAB_FRAMES of startup (own time), reach
##   Tuning.GRAB_RANGE, a small step in. Sprinting: reach GRAB_SPRINT_REACH,
##   the lunge keeps the sprint speed, contact keeps GRAB_SPRINT_KEEP of it for
##   SPRINT_DRAG_TIME (the victim is dragged backwards), and it is a sprint
##   strike (Traversal.on_strike_started(true) at the press). No body in reach
##   but a loose ThrowableProp within Tuning.GRAB_RANGE (sprinting too): the
##   prop is taken at once (no startup, no slowdown). Nothing at all: a whiff
##   with GRAB_WHIFF_FRAMES of recovery.
## - The body part comes from the stick relative to the target: toward it (or
##   neutral) = collar (Chest), sideways = that side's arm (forearm), away = leg
##   (shin). Ragdolling and dead bodies: the nearest bone (of the stick's part
##   when the stick is deflected) decides the part.
## - A neutral enemy is caught in a clinch: held standing in front of the
##   grabber for Tuning.GRAB_BREAK_FRAMES (real time), when its Grab press
##   breaks it (both pushed GRAB_BREAK_PUSH apart). Otherwise the hold connects
##   with GRAB_CONNECT_HITSTOP. Stunned (stagger, stumble, flinch, daze,
##   get-up), ragdolling and dead bodies connect at once.
## - The hold: RagdollController.begin_held(bone, hand, holder) (agent A's
##   target-velocity motor). `hand` is a top-level Node3D this node moves every
##   tick to the part's socket in front of the holder (SOCKETS), easing in from
##   the grip point at HAND_CATCH_UP so a grab reads as a yank, never a snap.
##   If begin_held is not available (is_held() stays false) a local fallback
##   pins the bone with a kinematic anchor and a Jolt pin joint
##   (RagdollController.set_gripped keeps the body limp; the held limb is made
##   heavier as in LimbGrab).
## - Hold actions: Light/Kick on the ground = knee (headbutt on the third),
##   flinch tier, Power.strike_damage(&"knee"); Heavy tap = throw at
##   Power.throw_speed(0, run speed) along the stick (aim-assisted toward an
##   enemy in the strike cone), Heavy held = charge levels in real time like
##   strikes; arm grabs spin the thrown body (twisting throw), leg grabs turn
##   Heavy into a trip in place (knockdown). Any attack in the air = body slam:
##   Traversal.begin_drop_strike(), the body is swung under you and knocked down
##   when you land (body_slammed; a shockwave if Traversal did not make one).
##   Grab = release (the body drops; a live body still upright lands on its
##   feet and stumbles, whatever part was held). HOLD_MAX: a live victim struggles out (both stumble); a
##   charged throw in progress fires instead. A hit on the holder drops it.
## - Victim side (connect_enemy_grab, enemy moves e_grab / e_grab_slam): the
##   victim is held standing in front of the enemy; Grab within
##   GRAB_BREAK_FRAMES (or ENEMY_BREAK_EARLY frames before the connect) breaks
##   it; otherwise the enemy throws (e_grab) or lifts and slams (e_grab_slam):
##   a preset KNOCKDOWN with Tuning.DMG_ENEMY. Never a launch, never a limb.
## - Carry assist: the motor pulls one bone, so when the holder whips round
##   faster than 75 kg can follow, the whole body gets a bounded velocity
##   change toward the hand (HOLD_ASSIST_*), the same for every bone.
## - AI enemies break a neutral grab AI_GRAB_BREAK_CHANCE of the time unless
##   their brain implements wants_grab_break(grabber) (agent C decides).
## - Upgrade 2's limb grabs (LimbGrab: arm drag, giant swing) are not in this
##   flow: carrying is a movement state, Heavy throws and Grab lets go, which a
##   camera-driven swing would contradict. The arm grab's throw spins the body
##   instead; LimbGrab stays for the Grab Lab (key 8) and its tests.

enum Phase { IDLE, REACH, CLINCH, HOLD, SLAM, RECOVER, ENEMY_HOLD }
enum Part { COLLAR, ARM, LEG }
enum Motor { NONE, HELD, PIN }
enum Cls { NEUTRAL, STUNNED, RAGDOLL, DEAD }

## On: CombatController routes every Grab here (Round 5 grabs replace Upgrade 2).
const ENABLED := true
## Tests and the Grab Lab turn the routing on before ENABLED is true.
static var force_enabled := false

# --- Local constants (candidates for Tuning) ----------------------------------------
const GRAB_ACTIVE_FRAMES := 3.0      ## frames the grab can still catch after its startup (as a jab's active frames)
const GRAB_WHIFF_FRAMES := 16.0      ## recovery of a whiffed grab (doc gives none; a cross's whiff)
const GRAB_HAND_HEIGHT := 1.1        ## m (x height) the hands reach from: ragdoll bones are measured from here
const GRAB_BODY_MARGIN := 0.35       ## m extra reach to the nearest bone of a ragdolling body (limbs, not a capsule)
const GRAB_BONE_HEIGHT := Vector2(-0.3, 2.4)  ## m: a ragdoll bone this far below / above the feet is reachable
const GRAB_CONE_DOT := 0.3           ## a standing body must be roughly in front at the active frame
const WALK_LUNGE_GAP := 0.75         ## m: a walking grab steps in to about this distance...
const WALK_LUNGE_MAX := 6.0          ## ...at most this fast
const SPRINT_DRAG_TIME := 0.3        ## s the sprint grab keeps GRAB_SPRINT_KEEP of its speed after contact
const PART_STICK_DEADZONE := 0.3     ## stick length under which the part is the collar
const PART_SIDE_ANGLE := 45.0        ## degrees off the target: collar inside, arm up to 180 - this, leg beyond
const PRESS_BUFFER := 0.2            ## s a Grab press waits for the fighter to be free
const CLINCH_DIST := 0.72            ## m (x height) in front: where a clinched / enemy-held fighter stands
const CLINCH_PULL := 6.0             ## m/s the clinched fighter is pulled into place
const HAND_CATCH_UP := 7.0           ## m/s the hand eases from the grip point to its socket (+ the holder's speed)
const TELEPORT_DROP := 1.2           ## m the socket jumps in one tick: the holder teleported, let go
const EXCEPTION_KEEP := 0.35         ## s a released body keeps ignoring its holder
const THROW_RECOVERY_FRAMES := 12.0  ## frames after a throw, trip or slam before acting again
const THROW_ANIM_TIME := 0.32        ## s of the throw pose
const KNEE_HIT_CUT := Tuning.HIT_RECOVERY_CUT
const TWIST_SPIN := 9.0              ## rad/s corkscrew of an arm (twisting) throw about its flight line
const TRIP_DOWN_SPEED := 3.5         ## m/s the leg trip slaps the body down
const SLAM_DAMAGE := 10.0            ## body slam damage (doc gives none: a kick's)
const SLAM_DOWN_SPEED := 5.0         ## m/s the slammed body is driven into the floor
const SLAM_TIMEOUT := 1.5            ## s: a slam that never lands lets go
## A released live body lands on its feet and stumbles when its torso is within
## STAND_TILT of upright and its pelvis is between these heights (x height):
## a kneeling slump on limp legs (an arm hold) still counts; lying or upside
## down (a leg hold) keeps falling.
const STAND_PELVIS := Vector2(0.15, 1.35)
const STAND_TILT := 50.0             ## degrees
const RELEASE_PUSH := 1.2            ## m/s a dropped body is pushed away
const STRUGGLE_PUSH := 2.0           ## m/s the struggle-out shove
const BREAK_PUSH_TIME := 0.18        ## s each side slides on a grab break (Tuning.GRAB_BREAK_PUSH apart in total)
const AI_GRAB_BREAK_CHANCE := 0.3    ## an AI enemy breaks a neutral grab this often (AIBrain.wants_grab_break overrides)
const AI_BREAK_REACT := Vector2(3.0, 8.0)  ## frames after the catch the AI presses Grab
const ENEMY_BREAK_EARLY := 4.0       ## frames: a Grab press this much before an enemy grab connects also breaks it
const ENEMY_THROW_AT := 0.45         ## s (enemy time) after the connect an e_grab throws
const ENEMY_SLAM_AT := 0.6           ## s an e_grab_slam slams (it lifts until then)
const ENEMY_SLAM_LIFT := 0.55        ## m the heavy lifts its victim before the slam
const ENEMY_TOSS := Vector2(2.5, 1.5)  ## m/s (forward, up) a grab-throw tosses the knocked-down victim
const ENEMY_RECOVER := 0.4           ## s after an enemy grab-throw or slam
const PROP_THROW_SPEED := 16.0       ## m/s a thrown prop leaves the hand (doc gives none)
const PROP_HAND_OFFSET := Vector3(0.0, -0.08, -0.06)  ## prop in the right-hand attachment frame
const PROP_RELEASE_AHEAD := 0.35     ## m in front of the hand a prop is let go
const PROP_HEIGHT := Vector2(-0.3, 2.0)  ## m: a prop this far below / above the feet can be taken
const HEAD_CENTER := 0.11            ## m (x height) from the head bone (the neck) to the head's centre
## Carry assist: the motor drives one bone, so a holder whipping round (a
## 100 degree turn in 0.15 s at a run) leaves 75 kg a metre behind the hand.
## Past HOLD_ASSIST_FROM the whole body (every bone alike: limbs keep swinging,
## joints do not stretch) is pulled toward the hand at up to HOLD_ASSIST_ACCEL.
const HOLD_ASSIST_FROM := 0.3        ## m from the held bone's centre to the hand
const HOLD_ASSIST_GAIN := 14.0       ## 1/s of the excess distance -> extra speed toward the hand
const HOLD_ASSIST_ACCEL := 220.0     ## m/s^2 at most, whole body (x the holder time factor squared)
const PIN_SLIP_DISTANCE := 0.45      ## m fallback pin stretch that lets go...
const PIN_SLIP_TIME := 0.15          ## ...after this long
const PIN_ARM_BOOST := 8.0           ## fallback pin: held arm chain x mass (Jolt solver aid, as LimbGrab)
const PIN_LEG_BOOST := 3.0

## Hand sockets in the holder's frame (x height scale for y and z): where the
## grip point is carried. Collar: the victim's neck held high in front so the
## feet clear the floor and the legs swing; arm: the wrist at the right side,
## chest high; leg: the ankle at hip height (the body drags).
const SOCKETS := {
	Part.COLLAR: Vector3(0.08, 1.5, -0.6),
	Part.ARM: Vector3(0.42, 1.3, -0.5),
	Part.LEG: Vector3(0.25, 1.05, -0.45),
}
## Body slam: the body is swung under and in front of the feet.
const SOCKET_SLAM := Vector3(0.0, 0.3, -0.55)

const COLLAR_BONES: Array[StringName] = [Bones.CHEST, Bones.SPINE, Bones.HEAD, Bones.HIPS]
const ARM_BONES: Array[StringName] = [Bones.L_LOWER_ARM, Bones.R_LOWER_ARM, Bones.L_UPPER_ARM, Bones.R_UPPER_ARM]
const LEG_BONES: Array[StringName] = [Bones.L_LOWER_LEG, Bones.R_LOWER_LEG, Bones.L_FOOT, Bones.R_FOOT,
	Bones.L_UPPER_LEG, Bones.R_UPPER_LEG]

var fighter: Fighter
## What this fighter holds: a Fighter (alive or dead) or a ThrowableProp. null = nothing.
var held: Node3D = null
## AI and tests: world direction for this fighter's next throw (ZERO = stick / facing).
var throw_aim := Vector3.ZERO

## Last results (tests, lab, debug).
var last_grab_result: StringName = &""   ## &"whiff" | &"clinch" | &"hold" | &"prop" | &"broken" | &"intercepted"
var last_throw_velocity := Vector3.ZERO
var last_throw_level := 0
var last_drop_reason: StringName = &""

var _phase: int = Phase.IDLE
var _t := 0.0                  # own s in the current phase
var _recover_left := 0.0
var _recover_still := false    # a whiff or break stands still; a throw keeps moving
var _break_pushed: Fighter      # the other fighter of a grab break's push (stopped with us)
var _press_buffer := -INF
var _last_grab_press := -INF   # real time of this fighter's last Grab press
# Reach
var _target: Fighter
var _reach_dir := Vector3.FORWARD
var _reach_sprint := false
var _reach_speed := 0.0
var _reach_len := 0.0
var _reach_part: int = Part.COLLAR
var _reach_side := 1.0
var _stick_part := false       # the stick picked the part (deflected)
var _strike_counted := true    # this grab already told Traversal it is a strike
# Hold (holder side)
var _victim: Fighter
var _prop: ThrowableProp
var _part: int = Part.COLLAR
var _bone: StringName = &""
var _hand: Node3D
var _hand_pos := Vector3.ZERO
var _hand_vel := Vector3.ZERO     # world-time m/s (what the held body must match)
var _phys_dt := 0.0               # this tick's physics delta (scaled by Engine.time_scale)
var _last_holder := Vector3.INF
var _motor: int = Motor.NONE
var _hold_t := 0.0
var _clinch_until := 0.0
var _queued := -1              # attack pressed during the clinch: fires on connect
var _queued_t := 0.0           # its press time (a held Heavy keeps charging from it)
var _queued_up := false        # released during the clinch
var _knees := 0
var _knee_t := -1.0
var _knee_hit := false
var _knee_queued := false
var _heavy_down := false
var _heavy_t := 0.0
var _charging := false
var _charge_level := 0
var _slam_fx_frame := -1
var _slam_pos := Vector3.ZERO
var _last_shockwave_frame := -1
# Fallback pin
var _pin_anchor := RID()
var _pin_joint := RID()
var _pin_body := RID()
var _pin_local := Vector3.ZERO
var _pin_slip := 0.0
var _boosted: Array = []
var _excepted: Array[RID] = []
# Enemy hold (holder side)
var _ehold_move: StringName = &""
var _ehold_aim := Vector3.ZERO   # the AI's throw aim seen during the hold
# Victim side
var _holder: Fighter
var _held_socket := false
var _held_at := -INF
var _break_until := -INF
var _ai_break_at := INF

func setup(p_fighter: Fighter) -> void:
	fighter = p_fighter
	process_physics_priority = 5   # after every Fighter moved its capsule (0), before ImpactResolver (100)
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.fighter_died.connect(_on_fighter_died)
	GameEvents.landing.connect(_on_landing)
	GameEvents.shockwave.connect(_on_shockwave)

func is_enabled() -> bool:
	return ENABLED or force_enabled

func on_grab_pressed(now: float) -> void:
	if fighter == null or fighter.is_dead():
		return
	_last_grab_press = now
	# Victim: the grab break.
	if is_held():
		_try_break(now)
		return
	match _phase:
		Phase.HOLD:
			drop(&"release")
			return
		Phase.REACH, Phase.CLINCH, Phase.SLAM, Phase.ENEMY_HOLD:
			return
	# Enemies grab through their moves (connect_enemy_grab); a press only breaks.
	if not fighter.is_player:
		return
	if _can_start():
		_start_grab(now)
	else:
		_press_buffer = now

func on_grab_released(_now: float) -> void:
	pass

## Attack press while holding (knee, throw, slam). true = consumed.
func on_attack_pressed(action: int, now: float) -> bool:
	match _phase:
		Phase.CLINCH:
			_queued = action
			_queued_t = now
			_queued_up = false
			return true
		Phase.SLAM, Phase.ENEMY_HOLD:
			return true
		Phase.HOLD:
			pass
		_:
			return false
	if _prop != null:
		if action == CombatController.Action.HEAVY:
			_throw_prop()
			return true
		return false   # a jab or kick with a prop in hand is a normal strike
	if _victim == null:
		return false
	if _in_air():
		_start_slam()
		return true
	if action == CombatController.Action.HEAVY:
		if _part == Part.LEG and not _victim.is_dead():
			_trip()   # a corpse cannot be tripped: held by a leg it is thrown
			return true
		if not _heavy_down:
			_heavy_down = true
			_heavy_t = now
			_charging = false
			_charge_level = 0
		return true
	_knee_press()
	return true

func on_attack_released(action: int, now: float) -> void:
	if _phase == Phase.CLINCH and action == _queued:
		_queued_up = true   # released during the clinch: a tap once the hold connects
		return
	if action != CombatController.Action.HEAVY or not _heavy_down:
		return
	if _phase != Phase.HOLD or _victim == null:
		_cancel_charge()
		return
	_heavy_down = false
	var level := 0
	if _charging:
		_charging = false
		level = _level_at(now - _heavy_t)
		_charge_level = level
		GameEvents.charge_released.emit(fighter, &"throw", level)
	_throw_body(level)

func is_holding() -> bool:
	return held != null

## This fighter is held by someone.
func is_held() -> bool:
	return _holder != null and is_instance_valid(_holder)

func get_holder() -> Fighter:
	return _holder if is_held() else null

## Enemy grab move connected with `victim` (the player). true = the hold began.
func connect_enemy_grab(victim: Fighter, move_id: StringName) -> bool:
	if fighter == null or victim == null or not is_instance_valid(victim):
		return false
	if victim == fighter:
		# Called on the victim's own Carry: the grabber is the enemy whose grab
		# move `move_id` is in its active frames, nearest to us.
		var g := _find_grabber(move_id)
		return g != null and g.carry != null and g.carry.connect_enemy_grab(victim, move_id)
	if fighter.is_dead() or fighter.is_down() or victim.is_dead() or victim.is_down():
		return false
	if victim.carry == null or victim.carry.is_held() or is_held():
		return false
	if _phase != Phase.IDLE and _phase != Phase.RECOVER:
		return false
	if victim.is_invulnerable() or victim.is_crouching():
		return false
	if victim.defence != null and victim.defence.is_enabled() and victim.defence.is_vanished():
		return false
	var now := TimeDirector.now()
	var vc := victim.carry
	# Grab pressed just before the connect: broken at once.
	var early := vc._last_grab_press >= now - Tuning.frames(ENEMY_BREAK_EARLY)
	if vc.is_holding() or vc._phase != Phase.IDLE:
		vc._abort(&"grabbed")
	if victim.combat:
		victim.combat.cancel()
	_phase = Phase.ENEMY_HOLD
	_t = 0.0
	_ehold_move = move_id
	_ehold_aim = Vector3.ZERO
	_victim = victim
	held = victim
	vc._set_holder(fighter, true, now + Tuning.frames(Tuning.GRAB_BREAK_FRAMES))
	_capsule_exception(victim, true)
	var to := fighter.get_ground_position() - victim.get_ground_position()
	victim.snap_facing(to)
	fighter.snap_facing(-to)
	_pose_hold(victim, &"held", &"held")
	_pose_hold(fighter, &"grab_hold", &"grab_hold")
	last_grab_result = &"clinch"
	GameEvents.grab_started.emit(fighter, victim)
	GameEvents.carry_changed.emit(fighter, victim)
	if early:
		_broken_by(victim)
	return true

## Let go of whatever is held. reason: &"release" | &"hit" | &"struggle" | &"death" | ...
func drop(reason: StringName) -> void:
	last_drop_reason = reason
	match _phase:
		Phase.REACH, Phase.RECOVER:
			_abort(reason)
		Phase.CLINCH, Phase.ENEMY_HOLD:
			_end_socket_hold(reason != &"death")
			_phase = Phase.IDLE
		Phase.HOLD, Phase.SLAM:
			if _prop != null:
				var p := _prop
				_prop = null
				held = null
				if is_instance_valid(p):
					p.drop(Vector3(fighter.velocity.x, 0.0, fighter.velocity.z) if fighter else Vector3.ZERO)
				GameEvents.carry_changed.emit(fighter, null)
				_phase = Phase.IDLE
				return
			var v := _victim
			var dir := fighter.get_forward() if fighter else Vector3.FORWARD
			_end_body_hold()
			if v != null and is_instance_valid(v):
				_stand_or_drop(v, dir, RELEASE_PUSH)
			_phase = Phase.IDLE

func get_move_speed_mult() -> float:
	match _phase:
		Phase.HOLD, Phase.SLAM:
			return Tuning.HOLD_WALK_MULT if _victim != null else 1.0
		Phase.CLINCH, Phase.ENEMY_HOLD:
			return 0.0
		Phase.RECOVER:
			return 0.0 if _recover_still else 1.0
	if is_held():
		return 0.0
	return 1.0

func get_sprint_cap_mult() -> float:
	return Tuning.HOLD_SPRINT_MULT if _victim != null and _phase in [Phase.HOLD, Phase.SLAM] else 1.0

func get_vault_max_height() -> float:
	return Tuning.VAULT_MAX_HOLDING if _victim != null and _phase in [Phase.HOLD, Phase.SLAM] else Tuning.VAULT_MAX

func get_debug_text() -> String:
	var names := ["idle", "reach", "clinch", "hold", "slam", "recover", "enemy_hold"]
	var s: String = "carry %s" % names[_phase]
	if _victim != null and is_instance_valid(_victim):
		s += " %s by %s (%s, %s) %.1fs knees %d" % [_victim.name, ["collar", "arm", "leg"][_part], _bone,
			["none", "held", "pin"][_motor], _hold_t, _knees]
	if _prop != null and is_instance_valid(_prop):
		s += " prop %s" % _prop.kind
	if _charging:
		s += " charge L%d" % _charge_level
	if is_held():
		s += " held by %s" % _holder.name
	return s

# --- Extra API (agent G) ---------------------------------------------------------------
## Busy with a grab: reaching, clinching, holding, slamming or recovering. H's
## can_act() should be false while this is true and not is_holding_prop().
func is_busy() -> bool:
	return _phase != Phase.IDLE and not (_phase == Phase.HOLD and _prop != null)

func is_holding_body() -> bool:
	return _victim != null and is_instance_valid(_victim) and _phase in [Phase.HOLD, Phase.SLAM]

func is_holding_prop() -> bool:
	return _prop != null and is_instance_valid(_prop)

## Charging a throw (M: steer like a charging strike).
func is_charging() -> bool:
	return _charging

func get_charge_level() -> int:
	return _charge_level if _charging else 0

## In the air with a body, waiting to land on it (M: the landing is a slam).
func is_slamming() -> bool:
	return _phase == Phase.SLAM

## &"collar" | &"arm" | &"leg" of the current hold (&"" when none).
func get_held_part() -> StringName:
	if _victim == null:
		return &""
	return [&"collar", &"arm", &"leg"][_part]

func get_held_bone() -> StringName:
	return _bone if _victim != null else &""

## Seconds (holder time) since the hold connected.
func get_hold_time() -> float:
	return _hold_t

## True while the hold uses RagdollController.begin_held (false: the local pin).
func uses_ragdoll_motor() -> bool:
	return _motor == Motor.HELD

## The node the held bone is pinned to (lab, tests).
func get_hand() -> Node3D:
	return _hand

## Take hold of `target` now, skipping the reach (lab, tests, scripted scenes).
## A neutral enemy still gets its break window unless `skip_clinch`.
func grab_now(target: Node3D, part := &"", skip_clinch := false) -> bool:
	if fighter == null or target == null or not is_instance_valid(target) or _phase != Phase.IDLE or is_held():
		return false
	if target is ThrowableProp:
		return _take_prop(target as ThrowableProp)
	var v := target as Fighter
	if v == null or not _grabbable(v):
		return false
	_reach_dir = _flat(v.get_ground_position() - fighter.get_ground_position(), fighter.get_forward())
	fighter.snap_facing(_reach_dir)
	_reach_sprint = false
	_reach_speed = 0.0
	_stick_part = part != &""
	_reach_part = {&"arm": Part.ARM, &"leg": Part.LEG}.get(part, Part.COLLAR)
	_reach_side = 1.0
	return _catch(v, skip_clinch)

## Throw what is held with exactly `velocity` (capped at Tuning.LAUNCH_SPEED_MAX).
## Tests and scripted scenes; the player throws with Heavy.
func throw_at(velocity: Vector3) -> bool:
	if _phase != Phase.HOLD:
		return false
	if _prop != null:
		_release_prop(velocity)
		return true
	if _victim == null:
		return false
	_launch_held(velocity.limit_length(Tuning.LAUNCH_SPEED_MAX), 0)
	return true

# =====================================================================================
# Tick
# =====================================================================================
func _physics_process(delta: float) -> void:
	if fighter == null or not is_instance_valid(fighter):
		return
	var now := TimeDirector.now()
	var dt := fighter.own_delta(delta) * fighter.get_actor_time()
	_phys_dt = delta
	_tick_victim(now)
	match _phase:
		Phase.REACH:
			_tick_reach(dt)
		Phase.CLINCH:
			_tick_clinch(dt, now)
		Phase.HOLD:
			_tick_hold(dt, now)
		Phase.SLAM:
			_tick_slam(dt)
		Phase.RECOVER:
			_recover_left -= dt
			if _recover_left <= 0.0:
				_phase = Phase.IDLE
				_end_break_push()
		Phase.ENEMY_HOLD:
			_tick_enemy_hold(dt)
	if _slam_fx_frame >= 0 and Engine.get_physics_frames() > _slam_fx_frame:
		_slam_fx_frame = -1
		if _last_shockwave_frame < 0 or Engine.get_physics_frames() - _last_shockwave_frame > 3:
			_fallback_shockwave(_slam_pos)
	if _press_buffer > -INF and _phase == Phase.IDLE:
		if now - _press_buffer > PRESS_BUFFER:
			_press_buffer = -INF
		elif _can_start():
			_press_buffer = -INF
			_start_grab(now)

func _exit_tree() -> void:
	if _phase in [Phase.HOLD, Phase.SLAM, Phase.CLINCH, Phase.ENEMY_HOLD]:
		drop(&"freed")
	_pin_free()
	if is_held() and _holder.carry != null:
		_holder.carry.drop(&"victim_freed")

func _can_start() -> bool:
	return _phase == Phase.IDLE and not is_held() and fighter.can_act() \
		and not (fighter.combat != null and fighter.combat.is_attacking())

# =====================================================================================
# Getting the grab
# =====================================================================================
func _start_grab(_now: float) -> void:
	# The grab takes what is in front of you (facing: your run or the lock-on);
	# the stick only picks the body part, so it never turns the grab away.
	var aim := fighter.get_forward()
	var sprint := fighter.traversal != null and fighter.traversal.is_sprinting()
	var hs := fighter.get_height_scale()
	var reach := (Tuning.GRAB_SPRINT_REACH if sprint else Tuning.GRAB_RANGE) * hs
	var speed := _run_speed()
	var startup := Tuning.frames(Tuning.GRAB_FRAMES)
	var target := _pick_body(aim, reach + speed * startup)
	if target == null:
		var prop := _pick_prop(Tuning.GRAB_RANGE * hs)   # props: 1.4 m even at a sprint
		if prop != null and _take_prop(prop):
			return
	_target = target
	_reach_sprint = sprint
	_reach_speed = speed
	_reach_len = reach
	var to := aim
	if target != null:
		to = _body_point(target) - fighter.global_position
	_reach_dir = _flat(to, fighter.get_forward())
	fighter.snap_facing(_reach_dir)
	_pick_part(target)
	_phase = Phase.REACH
	_t = 0.0
	GameEvents.strike_started.emit(fighter, target, &"grab", sprint, 0)
	# A sprint grab is a sprint strike. With no body picked yet it counts once
	# it catches one or whiffs: a prop taken at the active frame costs no speed.
	_strike_counted = false
	if target != null:
		_count_strike()
	_update_lunge()
	_pose_play(fighter, &"grab_lunge", startup + Tuning.frames(GRAB_ACTIVE_FRAMES), &"grab")

## Forced velocity while reaching: a sprint grab keeps its sprint speed (the
## short lunge), a walking grab steps in to WALK_LUNGE_GAP.
func _update_lunge() -> void:
	var startup := Tuning.frames(Tuning.GRAB_FRAMES)
	var left := maxf(startup + Tuning.frames(GRAB_ACTIVE_FRAMES) - _t, Tuning.frames(1))
	if _target != null and is_instance_valid(_target):
		_reach_dir = _flat(_body_point(_target) - fighter.global_position, _reach_dir)
		fighter.snap_facing(_reach_dir)
	var v := Vector3.ZERO
	if _reach_sprint:
		v = _reach_dir * _reach_speed
	elif _target != null and is_instance_valid(_target):
		var d := _flat_dist(_body_point(_target), fighter.global_position)
		var gap := WALK_LUNGE_GAP * fighter.get_height_scale()
		if d > gap and _t < startup:
			v = _reach_dir * minf((d - gap) / maxf(startup - _t, Tuning.frames(1)), WALK_LUNGE_MAX)
	fighter.knockback(v, left)

func _tick_reach(dt: float) -> void:
	if fighter.is_down() or fighter.is_dead() or is_held():
		_abort(&"interrupted")
		return
	if fighter.combat != null and fighter.combat.is_attacking():
		_abort(&"strike")   # a strike started over the grab: the strike wins
		return
	_t += dt
	var startup := Tuning.frames(Tuning.GRAB_FRAMES)
	_update_lunge()
	if _t < startup:
		return
	if _try_catch():
		return
	if _t >= startup + Tuning.frames(GRAB_ACTIVE_FRAMES):
		var prop := _pick_prop(Tuning.GRAB_RANGE * fighter.get_height_scale())
		if prop != null and _take_prop(prop):
			return
		_whiff()

func _try_catch() -> bool:
	var cands: Array[Fighter] = []
	if _target != null and is_instance_valid(_target):
		cands.append(_target)
	for f in _grabbables():
		if not cands.has(f):
			cands.append(f)
	var best: Fighter = null
	var best_d := INF
	for f in cands:
		if not _grabbable(f):
			continue
		var d := _reach_distance(f)
		if d <= _reach_len and d < best_d:
			best_d = d
			best = f
	if best == null:
		return false
	return _catch(best, false)

## Traversal: a grab (hit or miss) is a strike; at a sprint it drops you to walk.
func _count_strike() -> void:
	if _strike_counted:
		return
	_strike_counted = true
	if fighter.traversal != null:
		fighter.traversal.on_strike_started(_reach_sprint)

func _whiff() -> void:
	_count_strike()
	last_grab_result = &"whiff"
	GameEvents.attack_whiff.emit(fighter, &"grab")
	var rec := GRAB_WHIFF_FRAMES + (Tuning.SPRINT_WHIFF_FRAMES if _reach_sprint else 0.0)
	fighter.knockback(Vector3.ZERO, Tuning.frames(4))
	_enter_recover(Tuning.frames(rec), true)

## Contact: decide the grab by the victim's state.
func _catch(v: Fighter, skip_clinch: bool) -> bool:
	if not v.is_dead() and v.defence != null and v.defence.is_enabled() and v.defence.intercepts(fighter, &"grab"):
		last_grab_result = &"intercepted"
		_whiff()
		return true
	var cls := _class_of(v)
	var bone := _choose_bone(v, cls)
	if bone == &"":
		return false
	_count_strike()
	if _reach_sprint:
		fighter.knockback(_reach_dir * _reach_speed * Tuning.GRAB_SPRINT_KEEP, SPRINT_DRAG_TIME)
	else:
		fighter.knockback(Vector3.ZERO, Tuning.frames(2))
	GameEvents.grab_started.emit(fighter, v)
	if cls == Cls.NEUTRAL and not skip_clinch:
		_begin_clinch(v, bone)
		return true
	if not _begin_hold(v, bone):
		_whiff()
		return true
	TimeDirector.hitstop([fighter, v], Tuning.GRAB_CONNECT_HITSTOP)
	return true

# --- Clinch: a neutral enemy's break window -------------------------------------------
func _begin_clinch(v: Fighter, bone: StringName) -> void:
	var now := TimeDirector.now()
	_phase = Phase.CLINCH
	_t = 0.0
	_victim = v
	_bone = bone
	_part = _part_of(bone)
	_queued = -1
	held = v
	_clinch_until = now + Tuning.frames(Tuning.GRAB_BREAK_FRAMES)
	var vc := v.carry
	var early := vc != null and vc._last_grab_press >= now - Tuning.frames(ENEMY_BREAK_EARLY)
	if vc != null:
		if vc._phase != Phase.IDLE:
			vc._abort(&"grabbed")
		vc._set_holder(fighter, true, _clinch_until)
	if v.combat:
		v.combat.cancel()
	_capsule_exception(v, true)
	v.snap_facing(-_reach_dir)
	_pose_hold(v, &"held", &"held")
	last_grab_result = &"clinch"
	GameEvents.carry_changed.emit(fighter, v)
	if early:
		_broken_by(v)
		return
	if not v.is_player and vc != null and v.brain != null:   # brainless dummies never break
		var wants := randf() < AI_GRAB_BREAK_CHANCE
		if v.brain != null and v.brain.has_method(&"wants_grab_break"):
			wants = bool(v.brain.call(&"wants_grab_break", fighter))
		if wants:
			vc._ai_break_at = now + Tuning.frames(randf_range(AI_BREAK_REACT.x, AI_BREAK_REACT.y))

func _tick_clinch(dt: float, now: float) -> void:
	var v := _victim
	if v == null or not is_instance_valid(v) or v.is_dead() or v.is_body_simulating() or fighter.is_down():
		_end_socket_hold(true)
		_phase = Phase.IDLE
		return
	_t += dt
	_place_socket_victim(v, dt, 0.0)
	if _drag_active():
		pass
	else:
		fighter.knockback(Vector3.ZERO, Tuning.frames(2))
	if now >= _clinch_until:
		var bone := _bone
		var q := _queued
		_end_socket_hold(false, true)
		if not _begin_hold(v, bone):
			_phase = Phase.IDLE
			return
		TimeDirector.hitstop([fighter, v], Tuning.GRAB_CONNECT_HITSTOP)
		if q >= 0:
			on_attack_pressed(q, _queued_t)
			if q == CombatController.Action.HEAVY and _queued_up:
				on_attack_released(q, now)

## The break push ends: both stop where the slide put them (GRAB_BREAK_PUSH
## apart in total, no deceleration tail).
func _end_break_push() -> void:
	var o := _break_pushed
	_break_pushed = null
	if o == null:
		return
	fighter.knockback(Vector3.ZERO, Tuning.frames(1))
	fighter.velocity = Vector3(0.0, fighter.velocity.y, 0.0)
	if is_instance_valid(o) and not o.is_body_simulating():
		o.knockback(Vector3.ZERO, Tuning.frames(1))
		o.velocity = Vector3(0.0, o.velocity.y, 0.0)

func _drag_active() -> bool:
	return _reach_sprint and _t < SPRINT_DRAG_TIME

## A neutral victim (or the player held by an enemy) pressed Grab in time:
## both are pushed Tuning.GRAB_BREAK_PUSH apart.
func _broken_by(v: Fighter) -> void:
	var dir := _flat(v.get_ground_position() - fighter.get_ground_position(), fighter.get_forward())
	_end_socket_hold(true)
	_phase = Phase.IDLE
	var push := Tuning.GRAB_BREAK_PUSH * 0.5 / BREAK_PUSH_TIME
	fighter.knockback(-dir * push, BREAK_PUSH_TIME)
	if is_instance_valid(v):
		v.knockback(dir * push, BREAK_PUSH_TIME)
		_pose_play(v, &"grab_break_push", BREAK_PUSH_TIME + Tuning.frames(4), &"grab_break_push")
	_pose_play(fighter, &"grab_break_push", BREAK_PUSH_TIME + Tuning.frames(4), &"grab_break_push")
	_enter_recover(BREAK_PUSH_TIME, true)
	_break_pushed = v
	TimeDirector.hitstop([fighter, v], Tuning.GRAB_CONNECT_HITSTOP)
	last_grab_result = &"broken"
	GameEvents.grab_broken.emit(fighter, v, false)

# =====================================================================================
# Holding
# =====================================================================================
func _begin_hold(v: Fighter, bone: StringName) -> bool:
	if v.rig == null or v.ragdoll == null or v.rig.get_physical_bone(bone) == null:
		return false
	_victim = v
	_bone = bone
	_part = _part_of(bone)
	_phase = Phase.HOLD
	_t = 0.0
	_hold_t = 0.0
	_knees = 0
	_knee_t = -1.0
	_knee_queued = false
	_heavy_down = false
	_charging = false
	_charge_level = 0
	var was_held := held == v
	held = v
	if v.carry != null:
		if v.carry._phase != Phase.IDLE:
			v.carry._abort(&"grabbed")
		v.carry._set_holder(fighter, false, -INF)
	if not v.is_dead() and v.combat:
		v.combat.cancel()
	_ensure_hand()
	_hand_pos = _grip_world(v, bone)
	_last_holder = Vector3.INF
	_write_hand()
	var rd := v.ragdoll
	if v.is_dead():
		rd.wake()
	rd.begin_held(bone, _hand, fighter)
	if rd.is_held():
		_motor = Motor.HELD
	elif _pin_begin(v, bone):
		_motor = Motor.PIN
	else:
		_motor = Motor.NONE
		if v.carry != null:
			v.carry._clear_holder()
		_victim = null
		held = null
		_phase = Phase.IDLE
		return false
	_body_exception(v, true)
	_carry_pose(true)
	last_grab_result = &"hold"
	if not was_held:
		GameEvents.carry_changed.emit(fighter, v)
	return true

func _tick_hold(dt: float, now: float) -> void:
	if _prop != null:
		_tick_prop()
		return
	var v := _victim
	if v == null or not is_instance_valid(v) or not v.is_inside_tree():
		_end_body_hold()
		_phase = Phase.IDLE
		return
	if fighter.is_dead():
		drop(&"death")
		return
	if fighter.is_down():
		drop(&"down")
		return
	if not _motor_alive(v):
		drop(&"lost")
		return
	_t += dt
	_hold_t += dt
	if not _move_hand(dt, _socket(SOCKETS[_part])):
		drop(&"teleport")
		return
	if _motor == Motor.PIN and not _pin_tick(dt):
		drop(&"slip")
		return
	_assist(v, dt)
	if _knee_t >= 0.0:
		_tick_knee(dt)
		if _phase != Phase.HOLD:
			return
	if _heavy_down:
		_tick_charge_levels(now)
		if now - _heavy_t >= Tuning.CHARGE_AUTO_RELEASE:
			on_attack_released(CombatController.Action.HEAVY, now)
			return
	# Struggle-out: a live victim breaks free after HOLD_MAX. A charge in
	# progress fires instead (a throw you are charging is never lost).
	if not v.is_dead() and _hold_t >= Tuning.HOLD_MAX:
		if _heavy_down:
			on_attack_released(CombatController.Action.HEAVY, now)
		elif _knee_t < 0.0:
			_struggle_out()

func _assist(v: Fighter, dt: float) -> void:
	if dt <= 0.0 or _phys_dt <= 0.0 or v.is_frozen() or not v.ragdoll.is_full_ragdoll():
		return
	var pb := v.rig.get_physical_bone(_bone)
	if pb == null:
		return
	var c: Vector3 = (PhysicsServer3D.body_get_state(pb.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM) as Transform3D).origin
	var to := _hand_pos - c
	var d := to.length()
	if d <= HOLD_ASSIST_FROM:
		return
	# The holder's time factor (the player in slow motion: 1 / time scale):
	# speeds scale by it, accelerations by its square (Feel Reference: Time, in code).
	var k := fighter.own_time_factor()
	var want := _hand_vel + to / d * (d - HOLD_ASSIST_FROM) * HOLD_ASSIST_GAIN * k
	var dv := (want - v.get_com_velocity()).limit_length(HOLD_ASSIST_ACCEL * k * k * _phys_dt)
	v.ragdoll.add_velocity(dv)

func _motor_alive(v: Fighter) -> bool:
	match _motor:
		Motor.HELD:
			return v.ragdoll.is_held()
		Motor.PIN:
			return v.ragdoll.is_gripped() and v.ragdoll.is_full_ragdoll()
	return false

## Ease the hand toward `socket`; false = the holder teleported (let go).
func _move_hand(dt: float, socket: Vector3) -> bool:
	var hp := fighter.global_position
	if _last_holder != Vector3.INF and hp.distance_to(_last_holder) > TELEPORT_DROP:
		return false
	var speed := HAND_CATCH_UP + Vector2(fighter.velocity.x, fighter.velocity.z).length() + absf(fighter.velocity.y)
	var step := speed * maxf(dt, 0.0)
	var was := _hand_pos
	if _last_holder != Vector3.INF:
		_hand_pos += hp - _last_holder   # the hand travels with the holder...
	_hand_pos = _hand_pos.move_toward(socket, step)   # ...and eases to its socket
	_last_holder = hp
	# World-time velocity (the physics step): in slow motion the player's hand
	# moves at real speed, so the body must too (Feel Reference: Time, in code).
	_hand_vel = (_hand_pos - was) / _phys_dt if _phys_dt > 0.0 and dt > 0.0 else Vector3.ZERO
	_write_hand()
	return true

func _write_hand() -> void:
	if _hand == null:
		return
	var face := -fighter.get_forward()
	_hand.global_transform = Transform3D(Basis.looking_at(face, Vector3.UP), _hand_pos)

func _ensure_hand() -> void:
	if _hand != null and is_instance_valid(_hand):
		return
	_hand = Node3D.new()
	_hand.name = "CarryHand"
	_hand.top_level = true
	fighter.add_child(_hand)

## Socket offset (holder frame) to world.
func _socket(off: Vector3) -> Vector3:
	var h := fighter.get_height_scale()
	var b := Basis(Vector3.UP, fighter.rotation.y)
	return fighter.global_position + b * Vector3(off.x, off.y * h, off.z * h)

## Ends the physical hold (motor off, links cleared). The caller decides what
## the body does next. Collisions with the holder stay off for EXCEPTION_KEEP.
func _end_body_hold() -> void:
	var v := _victim
	_victim = null
	held = null
	_cancel_charge()
	_knee_t = -1.0
	if v != null and is_instance_valid(v):
		match _motor:
			Motor.HELD:
				if v.ragdoll.is_held():
					v.ragdoll.end_held()
			Motor.PIN:
				_pin_end(v)
		if v.carry != null and v.carry._holder == fighter:
			v.carry._clear_holder()
		_release_exceptions_later(v)
	else:
		_pin_free()
	_motor = Motor.NONE
	_carry_pose(false)
	GameEvents.carry_changed.emit(fighter, null)

## A released body (Grab, a hit on the holder, the struggle-out): a live one
## whose pelvis is upright with its feet near the floor lands on them and
## stumbles, whatever part was held; one that is ragdolling (upside down by a
## leg, lying) keeps falling and gets up; a corpse just drops.
func _stand_or_drop(v: Fighter, dir: Vector3, push: float) -> void:
	if v.is_dead() or v.ragdoll == null:
		if v.ragdoll:
			v.ragdoll.add_velocity(dir * push * 0.5)
		return
	if _upright_near_floor(v):
		var up := false
		if v.ragdoll.has_method(&"recover_upright"):
			up = bool(v.ragdoll.call(&"recover_upright"))
		else:
			v.ragdoll.force_recover()
			up = true
		if up:
			v.stumble(dir, Bones.L_LOWER_LEG)
			return
	v.ragdoll.add_velocity(dir * push)

func _upright_near_floor(v: Fighter) -> bool:
	var hips := v.rig.get_physical_bone(Bones.HIPS)
	var chest := v.rig.get_physical_bone(Bones.CHEST)
	if hips == null or chest == null:
		return false
	var hp: Vector3 = PhysicsServer3D.body_get_state(hips.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM).origin
	var cp: Vector3 = PhysicsServer3D.body_get_state(chest.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM).origin
	var up := cp - hp
	if up.length() < 0.05 or rad_to_deg(up.normalized().angle_to(Vector3.UP)) > STAND_TILT:
		return false
	var floor_y := _floor_y(hp)
	var hh := (hp.y - floor_y) / maxf(v.get_height_scale(), 0.5)
	return hh >= STAND_PELVIS.x and hh <= STAND_PELVIS.y

func _floor_y(at: Vector3) -> float:
	if fighter == null or not fighter.is_inside_tree():
		return 0.0
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.2, at + Vector3.DOWN * 6.0, Layers.WORLD | Layers.DESTRUCTIBLE)
	var hit := fighter.get_world_3d().direct_space_state.intersect_ray(q)
	return (hit["position"] as Vector3).y if not hit.is_empty() else 0.0

func _struggle_out() -> void:
	var v := _victim
	var dir := _flat(v.get_ground_position() - fighter.get_ground_position(), fighter.get_forward())
	_end_body_hold()
	_phase = Phase.IDLE
	if is_instance_valid(v):
		_stand_or_drop(v, dir, STRUGGLE_PUSH)
	fighter.stumble(-dir, Bones.L_LOWER_LEG)
	last_drop_reason = &"struggle"
	GameEvents.grab_broken.emit(fighter, v, false)

# --- Knees -----------------------------------------------------------------------------
func _knee_press() -> void:
	if _knee_t >= 0.0:
		_knee_queued = _knees < Tuning.HOLD_KNEES_MAX
		return
	if _knees >= Tuning.HOLD_KNEES_MAX:
		return
	_knees += 1
	_knee_t = 0.0
	_knee_hit = false
	var f: Vector3 = Tuning.STRIKE_FRAMES[&"knee"]
	var id := &"headbutt" if _knees == Tuning.HOLD_KNEES_MAX else &"held_knee"
	_pose_play(fighter, id, Tuning.frames(f.x + f.y + f.z * (1.0 - KNEE_HIT_CUT)), &"knee" if id == &"held_knee" else &"headbutt")

func _tick_knee(dt: float) -> void:
	_knee_t += dt
	var f: Vector3 = Tuning.STRIKE_FRAMES[&"knee"]
	if not _knee_hit and _knee_t >= Tuning.frames(f.x):
		_knee_hit = true
		_knee_land(_knees == Tuning.HOLD_KNEES_MAX)
		if _phase != Phase.HOLD:
			return
	if _knee_t >= Tuning.frames(f.x + f.y + f.z * (1.0 - KNEE_HIT_CUT)):
		_knee_t = -1.0
		if _knee_queued:
			_knee_queued = false
			_knee_press()

## A knee (or the third hit's headbutt) on the held body: a preset flinch-tier
## hit through the victim's pipeline; the hold is kept.
func _knee_land(headbutt: bool) -> void:
	var v := _victim
	if v == null or not is_instance_valid(v):
		return
	var bone := Bones.HEAD if headbutt else Bones.CHEST
	var pos := _bone_center(v, bone) if v.rig else v.get_aim_point()
	var dir := (fighter.get_forward() + Vector3.UP * (0.2 if headbutt else 0.6)).normalized()
	if v.is_dead():
		v.ragdoll.add_velocity(dir * 1.5)
		return
	var info := HitInfo.new()
	info.attacker = fighter
	info.victim = v
	info.move_id = &"headbutt" if headbutt else &"held_knee"
	info.kind = &"strike"
	info.power_base = Power.base_of(&"knee")
	info.power = Power.score(info.power_base, 0)
	info.tier = HitInfo.Tier.FLINCH
	info.reaction = HitInfo.reaction_for_tier(info.tier)
	info.damage = Power.strike_damage(&"knee", 0) * _damage_mult()
	info.hit_bone = bone
	info.hit_position = pos
	info.hit_direction = dir
	info.zone = BodyZones.Zone.HEAD if headbutt else BodyZones.Zone.TORSO
	info.level = HitInfo.Level.HIGH if headbutt else HitInfo.Level.MID
	info.hitstop = Power.hitstop_for(info.tier)
	info.unblockable = true
	info.energy = 0.5 * v.get_total_mass() * 2.0
	info.set_meta(&"held_strike", true)  # the holder's own strike: keep the hold
	info.set_meta(&"blood", &"small")    # Feel Reference: knees draw a little blood (F)
	v.take_hit(info)

# --- Throws ---------------------------------------------------------------------------------
func _tick_charge_levels(now: float) -> void:
	if not _heavy_down:
		return
	var held_s := now - _heavy_t
	if not _charging and held_s >= Tuning.HOLD_THRESHOLD:
		_charging = true
		_charge_level = 0
		GameEvents.charge_started.emit(fighter, &"throw")
		# Over the running legs (charging on the run keeps your speed).
		if fighter.animator != null and PoseLibrary.HOLDS.has(&"throw_charge"):
			fighter.animator.set_upper_overlay(&"throw_charge")
		else:
			_pose_hold(fighter, &"throw_charge", &"power_charge")
	if not _charging:
		return
	var level := _level_at(held_s)
	if level != _charge_level:
		_charge_level = level
		GameEvents.charge_level_changed.emit(fighter, level)
		if fighter.animator:
			fighter.animator.set_charge_level(level)

## A throw charge ends without a throw (dropped, hit, slam, struggle-out):
## charge_released at level 0 so the charge glow and the HUD let go of it.
func _cancel_charge() -> void:
	_heavy_down = false
	if _charging:
		_charging = false
		_charge_level = 0
		GameEvents.charge_released.emit(fighter, &"throw", 0)
		if fighter != null and fighter.animator != null:
			fighter.animator.set_charge_level(0)

## Charge level reached after holding `held_s` real seconds (Tuning.CHARGE_LEVELS).
static func _level_at(held_s: float) -> int:
	var level := 0
	for i in Tuning.CHARGE_LEVELS.size():
		if held_s + 1e-4 >= Tuning.CHARGE_LEVELS[i]:
			level = i + 1
	return level

## Heavy: throw along the stick at Power.throw_speed(level, run speed).
func _throw_body(level: int) -> void:
	if _victim == null:
		return
	var dir := _throw_dir()
	var speed := minf(Power.throw_speed(level, _throw_run_speed(dir)), Tuning.LAUNCH_SPEED_MAX)
	var a := deg_to_rad(Tuning.THROW_UP_ANGLE)
	_launch_held((dir * cos(a) + Vector3.UP * sin(a)) * speed, level)

func _launch_held(vel: Vector3, level: int) -> void:
	var v := _victim
	var part := _part
	var bone := _bone
	var sprinting := fighter.traversal != null and fighter.traversal.is_sprinting()
	_end_body_hold()
	last_throw_velocity = vel
	last_throw_level = level
	if v != null and is_instance_valid(v):
		var dv := vel - v.get_com_velocity()
		if v.is_dead():
			v.ragdoll.add_velocity(dv)
		else:
			v.launch(dv, v.get_center_of_mass(), bone)
		if part == Part.ARM:
			_twist(v, vel)
		GameEvents.thrown.emit(fighter, v, vel)
	fighter.snap_facing(vel)
	_pose_play(fighter, &"throw", THROW_ANIM_TIME, &"throw")
	if fighter.traversal != null:
		fighter.traversal.on_strike_started(sprinting)
	_enter_recover(Tuning.frames(THROW_RECOVERY_FRAMES))

## Twisting throw (arm grab): the body corkscrews about its flight line.
func _twist(v: Fighter, vel: Vector3) -> void:
	if v.rig == null or vel.length() < 0.5:
		return
	var axis := Vector3(vel.x, 0.0, vel.z).normalized()
	if axis.length_squared() < 1e-4:
		return
	var w := axis * TWIST_SPIN
	var com := v.get_center_of_mass()
	for pb: PhysicalBone3D in v.rig.get_physical_bones():
		var rid := pb.get_rid()
		if not pb.is_simulating_physics():
			continue
		var xf: Transform3D = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
		var lv: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		var av: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, lv + w.cross(xf.origin - com))
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, av + w)

## Leg grab: Heavy is a sweep that trips the body in place (knockdown).
func _trip() -> void:
	var v := _victim
	var bone := _bone
	var dir := fighter.get_forward()
	_end_body_hold()
	if v != null and is_instance_valid(v):
		if v.is_dead():
			v.ragdoll.add_velocity(Vector3.DOWN * TRIP_DOWN_SPEED)
		else:
			var info := _preset_hit(v, &"leg_trip", HitInfo.Tier.KNOCKDOWN,
				Power.strike_damage(&"sweep", 0) * _damage_mult(), bone, dir)
			info.launch_velocity = Vector3.DOWN * TRIP_DOWN_SPEED + dir
			v.take_hit(info)
			if is_instance_valid(v) and v.ragdoll.is_full_ragdoll():
				v.ragdoll.add_velocity(Vector3.DOWN * TRIP_DOWN_SPEED)
			GameEvents.tripped.emit(v)
	_pose_play(fighter, &"throw", THROW_ANIM_TIME, &"leg_sweep")
	_enter_recover(Tuning.frames(THROW_RECOVERY_FRAMES))

func _throw_dir() -> Vector3:
	var d := Vector3.ZERO
	if fighter.is_player and fighter.brain != null and fighter.brain.has_method(&"get_aim_dir"):
		d = fighter.brain.call(&"get_aim_dir")
	elif throw_aim.length_squared() > 1e-4:
		d = throw_aim
	elif fighter.combat != null and &"throw_aim" in fighter.combat:
		d = fighter.combat.get(&"throw_aim")
	d = _flat(d, fighter.get_forward())
	# Aim assist: an enemy inside the strike cone takes the throw (bowling).
	if fighter.is_player:
		var t := Targeting.pick_strike_target(fighter, d, true)
		if t != null and t != _victim:
			d = _flat(t.get_ground_position() - fighter.get_ground_position(), d)
	return d

func _run_speed() -> float:
	if fighter.traversal != null:
		var s := fighter.traversal.get_speed()
		if s > 0.0:
			return s
	return Vector2(fighter.velocity.x, fighter.velocity.z).length()

## Run speed for the throw formula: the earned speed toward the throw
## (Traversal.speed_toward, as for a strike's speed bonus: a dash burst, a
## lunge or a knockback adds nothing, so a dash-tap throw is a standing throw).
## Carrying caps the sprint at Tuning.HOLD_SPRINT_MULT of the cap; at that top
## speed (within Tuning.SPEED_CAP_SNAP, the strike speed-bonus rule) the throw
## counts as at full sprint, so "charged throw at full sprint: 16 m/s"
## (Feel Reference) holds.
func _throw_run_speed(dir: Vector3) -> float:
	if fighter.traversal == null:
		return maxf(Vector3(fighter.velocity.x, 0.0, fighter.velocity.z).dot(dir), 0.0)
	var s := fighter.traversal.speed_toward(dir)
	if _victim != null:
		var cap := Power.speed_cap()   # the base cap (Traversal's own cap is already lowered while carrying)
		var hold_cap := cap * Tuning.HOLD_SPRINT_MULT
		if hold_cap > 0.0 and s >= hold_cap * Tuning.SPEED_CAP_SNAP:
			s = cap
	return s

# --- Body slam ------------------------------------------------------------------------------
func _start_slam() -> void:
	_phase = Phase.SLAM
	_t = 0.0
	_cancel_charge()
	_knee_t = -1.0
	if fighter.traversal != null:
		fighter.traversal.begin_drop_strike()
	_pose_play(fighter, &"body_slam", 0.45, &"stomp")

func _tick_slam(dt: float) -> void:
	var v := _victim
	if v == null or not is_instance_valid(v) or fighter.is_dead() or fighter.is_down() or not _motor_alive(v):
		drop(&"lost")
		return
	_t += dt
	if not _move_hand(dt * 2.0, _socket(SOCKET_SLAM)):
		drop(&"teleport")
		return
	if _motor == Motor.PIN and not _pin_tick(dt):
		drop(&"slip")
		return
	if not _in_air() or _t >= SLAM_TIMEOUT:
		_do_slam(fighter.global_position)

func _on_landing(f: Node3D, _level: StringName, position: Vector3, _vs: float) -> void:
	if f == fighter and _phase == Phase.SLAM:
		_do_slam(position)

func _on_shockwave(f: Node3D, _p: Vector3, _sr: float, _kr: float) -> void:
	if f == fighter:
		_last_shockwave_frame = Engine.get_physics_frames()

## Landed on the body: it is knocked down under you. The heavy-landing
## shockwave is Traversal's; if it made none this frame, a local one stands in.
func _do_slam(pos: Vector3) -> void:
	if _phase != Phase.SLAM:
		return
	var v := _victim
	var dir := fighter.get_forward()
	_end_body_hold()
	if v != null and is_instance_valid(v):
		if v.is_dead():
			v.ragdoll.add_velocity(Vector3.DOWN * SLAM_DOWN_SPEED)
		else:
			var info := _preset_hit(v, &"body_slam", HitInfo.Tier.KNOCKDOWN, SLAM_DAMAGE * _damage_mult(),
				Bones.CHEST, (dir + Vector3.DOWN).normalized())
			info.launch_velocity = Vector3.DOWN * SLAM_DOWN_SPEED
			v.take_hit(info)
			if is_instance_valid(v) and v.ragdoll.is_full_ragdoll():
				v.ragdoll.add_velocity(Vector3.DOWN * SLAM_DOWN_SPEED)
	GameEvents.body_slammed.emit(fighter, v, pos)
	_slam_pos = pos
	_slam_fx_frame = Engine.get_physics_frames()
	_enter_recover(Tuning.frames(THROW_RECOVERY_FRAMES))

## Stand-in heavy-landing shockwave (Traversal did not make one): enemies within
## Tuning.SHOCK_KNOCKDOWN_RADIUS are knocked down, within SHOCK_STUMBLE_RADIUS stumble.
func _fallback_shockwave(pos: Vector3) -> void:
	if fighter == null or not fighter.is_inside_tree():
		return
	GameEvents.shockwave.emit(fighter, pos, Tuning.SHOCK_STUMBLE_RADIUS, Tuning.SHOCK_KNOCKDOWN_RADIUS)
	for f in Targeting.opponents_of(fighter):
		if f.is_down() or f.is_invulnerable():
			continue
		var d := _flat_dist(f.get_ground_position(), pos)
		if d > Tuning.SHOCK_STUMBLE_RADIUS:
			continue
		var tier := HitInfo.Tier.KNOCKDOWN if d <= Tuning.SHOCK_KNOCKDOWN_RADIUS else HitInfo.Tier.STUMBLE
		var info := _preset_hit(f, &"shockwave", tier, 0.0, Bones.L_LOWER_LEG,
			_flat(f.get_ground_position() - pos, fighter.get_forward()))
		info.kind = &"bowl"
		f.take_hit(info)

# --- Props ----------------------------------------------------------------------------------
func _take_prop(p: ThrowableProp) -> bool:
	if p == null or not is_instance_valid(p) or not p.can_pick_up():
		return false
	p.pick_up(fighter)
	_prop = p
	held = p
	_phase = Phase.HOLD
	_t = 0.0
	_tick_prop()
	last_grab_result = &"prop"
	GameEvents.prop_picked_up.emit(fighter, p)
	GameEvents.carry_changed.emit(fighter, p)
	return true

func _tick_prop() -> void:
	var p := _prop
	if p == null or not is_instance_valid(p) or not p.is_inside_tree() or not p.is_held() or p.holder != fighter:
		_prop = null
		held = null
		_phase = Phase.IDLE
		GameEvents.carry_changed.emit(fighter, null)
		return
	if fighter.is_dead() or fighter.is_down():
		drop(&"hit")
		return
	p.global_transform = _prop_hand_xform()

func _prop_hand_xform() -> Transform3D:
	var hand: Node3D = fighter.rig.get_attachment(Bones.R_HAND) if fighter.rig else null
	if hand != null and hand.is_inside_tree():
		return hand.global_transform * Transform3D(Basis(), PROP_HAND_OFFSET)
	return Transform3D(fighter.global_basis, _socket(Vector3(0.3, 1.2, -0.35)))

## Heavy with a prop: thrown at PROP_THROW_SPEED at an enemy in the strike
## cone (its chest; the bone the player's zone aim is on when that enemy is the
## aimed one, so a brick aimed at the head knocks down), else along the stick.
func _throw_prop() -> void:
	var p := _prop
	if p == null:
		return
	var dir := _flat(_aim_dir(), fighter.get_forward())
	var from := _prop_hand_xform().origin + dir * PROP_RELEASE_AHEAD
	var t := Targeting.pick_strike_target(fighter, dir, true)
	var vel: Vector3
	if t != null:
		var aim := t.get_aim_point()
		if t == fighter.aim_target and fighter.aim_bone != &"" and t.rig != null \
				and not t.rig.is_bone_severed(fighter.aim_bone):
			aim = _bone_center(t, fighter.aim_bone)
		vel = _ballistic(from, aim, PROP_THROW_SPEED)
	else:
		vel = (dir + Vector3.UP * 0.08).normalized() * PROP_THROW_SPEED
	p.global_position = from
	_release_prop(vel)

func _release_prop(vel: Vector3) -> void:
	var p := _prop
	_prop = null
	held = null
	_phase = Phase.IDLE
	if p == null or not is_instance_valid(p):
		return
	p.throw(vel, fighter)
	last_throw_velocity = vel
	last_throw_level = 0
	fighter.snap_facing(vel)
	if _run_speed() < 1.0:
		_pose_play(fighter, &"throw", THROW_ANIM_TIME * 0.8, &"throw")
	GameEvents.prop_thrown.emit(fighter, p, vel)
	GameEvents.carry_changed.emit(fighter, null)

## Middle of a bone (a bone's origin is its joint: the head's is the neck).
static func _bone_center(f: Fighter, bone: StringName) -> Vector3:
	var p := f.rig.get_bone_global_position(bone)
	if bone == Bones.HEAD:
		return p + Vector3.UP * HEAD_CENTER * f.get_height_scale()
	for c: StringName in Bones.PARENT:
		if Bones.PARENT[c] == bone and not (c in [Bones.L_UPPER_ARM, Bones.R_UPPER_ARM, Bones.L_UPPER_LEG, Bones.R_UPPER_LEG, Bones.HEAD]):
			return p.lerp(f.rig.get_bone_global_position(c), 0.5)
	return p

static func _ballistic(from: Vector3, to: Vector3, speed: float) -> Vector3:
	var g: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var d := to - from
	var flat := Vector3(d.x, 0.0, d.z)
	var t := clampf(flat.length() / maxf(speed, 1.0), 0.05, 1.6)
	return flat / t + Vector3.UP * (d.y / t + 0.5 * g * t)

# =====================================================================================
# Being grabbed (victim side) and enemy grabs (holder side)
# =====================================================================================
func _tick_enemy_hold(dt: float) -> void:
	var v := _victim
	if v == null or not is_instance_valid(v) or v.is_dead() or fighter.is_dead() or fighter.is_down() \
			or (v.ragdoll != null and v.ragdoll.is_simulating()):
		_end_socket_hold(true)
		_phase = Phase.IDLE
		return
	_t += dt
	var slam := _ehold_move == &"e_grab_slam"
	var lift := 0.0
	if slam:
		lift = ENEMY_SLAM_LIFT * clampf(_t / (ENEMY_SLAM_AT * 0.75), 0.0, 1.0)
	_place_socket_victim(v, dt, lift)
	fighter.knockback(Vector3.ZERO, Tuning.frames(2))
	if fighter.combat != null and &"throw_aim" in fighter.combat:
		var a: Vector3 = fighter.combat.get(&"throw_aim")
		if a.length_squared() > 1e-4:
			_ehold_aim = a
	if _t >= (ENEMY_SLAM_AT if slam else ENEMY_THROW_AT):
		_enemy_finish(slam)

## The enemy's grab ends: a throw (e_grab) or a slam (e_grab_slam). Either is a
## preset KNOCKDOWN with Tuning.DMG_ENEMY: enemies never launch the player.
func _enemy_finish(slam: bool) -> void:
	var v := _victim
	var move := _ehold_move
	var dir := _enemy_throw_dir()
	_end_socket_hold(false)
	fighter.snap_facing(dir)
	var toss := dir * ENEMY_TOSS.x + Vector3.UP * ENEMY_TOSS.y
	if slam:
		toss = dir * 0.5 + Vector3.DOWN * SLAM_DOWN_SPEED
	var info := _preset_hit(v, move, HitInfo.Tier.KNOCKDOWN,
		float(Tuning.DMG_ENEMY.get(move, 15.0)) * _damage_mult(), Bones.CHEST, dir)
	info.launch_velocity = toss
	v.take_hit(info)
	if is_instance_valid(v) and v.ragdoll != null and v.ragdoll.is_full_ragdoll():
		var cv := v.get_com_velocity()
		if Vector3(cv.x, 0.0, cv.z).length() < 1.0:
			v.ragdoll.add_velocity(toss)
	if not slam:
		GameEvents.thrown.emit(fighter, v, toss)
	_pose_play(fighter, &"body_slam" if slam else &"throw", THROW_ANIM_TIME, &"stomp" if slam else &"throw")
	_phase = Phase.RECOVER
	_recover_left = ENEMY_RECOVER

## The opponent whose grab move `move_id` is active, nearest to this fighter.
func _find_grabber(move_id: StringName) -> Fighter:
	var best: Fighter = null
	var best_d := INF
	for n in fighter.get_tree().get_nodes_in_group(&"fighters"):
		var f := n as Fighter
		if f == null or f == fighter or f.team == fighter.team or f.is_dead() or f.combat == null:
			continue
		if f.combat.current_move_id() != move_id:
			continue
		var d := _flat_dist(f.global_position, fighter.global_position)
		if d < best_d:
			best_d = d
			best = f
	return best

## Where an enemy's grab-throw goes: this Carry's throw_aim, else the aim the
## AI set on CombatController.throw_aim during the hold (cached: the AI clears
## it when the grab move ends), else the brain's find_throw_aim(), else facing.
func _enemy_throw_dir() -> Vector3:
	var dir := _flat(throw_aim, Vector3.ZERO)
	if dir == Vector3.ZERO:
		dir = _flat(_ehold_aim, Vector3.ZERO)
	if dir == Vector3.ZERO and fighter.brain != null and fighter.brain.has_method(&"find_throw_aim"):
		dir = _flat(fighter.brain.call(&"find_throw_aim"), Vector3.ZERO)
	return dir if dir != Vector3.ZERO else fighter.get_forward()

## Holder: put a fighter held standing (clinch, enemy grab) in front, facing us.
## A holder charging in (a sprint grab) is never pulled toward: the victim
## stays until the holder reaches it, then is pushed along (dragged backwards).
func _place_socket_victim(v: Fighter, dt: float, lift: float) -> void:
	var fwd := fighter.get_forward()
	var o := fighter.global_position
	var rel := v.global_position - o
	var along := rel.dot(fwd)
	var lateral := Vector3(rel.x, 0.0, rel.z) - fwd * along
	var want := CLINCH_DIST * fighter.get_height_scale()
	var closing := fighter.velocity.dot(fwd)
	var step := (CLINCH_PULL + maxf(closing, 0.0)) * maxf(dt, 1.0 / 120.0)
	if along < want:
		along = want   # pushed ahead of the holder
	elif closing < 1.0:
		along = move_toward(along, want, step)
	lateral = lateral.move_toward(Vector3.ZERO, step)
	var y := move_toward(v.global_position.y, o.y + lift, step)
	v.global_position = Vector3(o.x, y, o.z) + fwd * along + lateral
	v.velocity = Vector3.ZERO
	v.snap_facing(-fwd)

## Ends a standing hold (clinch or enemy grab). `to_hold` keeps `held` (the
## clinch is turning into a ragdoll hold).
func _end_socket_hold(release_pose: bool, to_hold := false) -> void:
	var v := _victim
	if not to_hold:
		_victim = null
		held = null
	if v != null and is_instance_valid(v):
		if v.carry != null and v.carry._holder == fighter:
			v.carry._clear_holder()
		if release_pose and v.animator and v.get_state() == RagdollController.State.ANIMATED:
			v.animator.release_pose()
		var wg: WeakRef = weakref(fighter)
		var wv: WeakRef = weakref(v)
		TimeDirector.real_timer(EXCEPTION_KEEP).timeout.connect(func() -> void:
			var g := wg.get_ref() as Fighter
			var o := wv.get_ref() as Fighter
			if g != null and o != null:
				g.remove_collision_exception_with(o)
				o.remove_collision_exception_with(g))
	if fighter.animator and fighter.animator.get_hold_id() == &"grab_hold":
		fighter.animator.release_pose()
	if not to_hold:
		GameEvents.carry_changed.emit(fighter, null)

# --- Victim side --------------------------------------------------------------------------
func _set_holder(h: Fighter, socket: bool, break_until: float) -> void:
	_holder = h
	_held_socket = socket
	_held_at = TimeDirector.now()
	_break_until = break_until
	_ai_break_at = INF

func _clear_holder() -> void:
	_holder = null
	_held_socket = false
	_break_until = -INF
	_ai_break_at = INF

func _tick_victim(now: float) -> void:
	if _holder == null:
		return
	if not is_instance_valid(_holder) or _holder.is_dead() or _holder.carry == null or _holder.carry.held != fighter:
		_clear_holder()
		if fighter.animator and fighter.get_state() == RagdollController.State.ANIMATED:
			fighter.animator.release_pose()
		return
	if now >= _ai_break_at:
		_ai_break_at = INF
		on_grab_pressed(now)

## Grab pressed while held: inside the window the hold breaks.
func _try_break(now: float) -> void:
	if not is_held() or now > _break_until + 1e-4:
		return
	_holder.carry._broken_by(fighter)

# --- Hits and deaths -----------------------------------------------------------------------
func _on_hit_landed(info: HitInfo) -> void:
	if info == null or fighter == null:
		return
	if info.victim == fighter:
		if bool(info.get_meta(&"held_strike", false)):
			return
		match _phase:
			Phase.HOLD, Phase.SLAM, Phase.CLINCH, Phase.ENEMY_HOLD, Phase.REACH:
				drop(&"hit")   # others don't wait: a hit makes you drop the body
		# Held standing and hit by a third party: the hold ends.
		if is_held() and _held_socket and info.attacker != _holder:
			_holder.carry.drop(&"victim_hit")

func _on_fighter_died(f: Node3D, _info: HitInfo) -> void:
	if f == fighter and _phase != Phase.IDLE:
		drop(&"death")

# =====================================================================================
# Target picking
# =====================================================================================
func _grabbables() -> Array[Fighter]:
	var out: Array[Fighter] = []
	for n in fighter.get_tree().get_nodes_in_group(&"fighters"):
		var f := n as Fighter
		if f != null and _grabbable(f):
			out.append(f)
	return out

func _grabbable(f: Fighter) -> bool:
	if f == null or f == fighter or not is_instance_valid(f) or not f.is_inside_tree() or f.is_queued_for_deletion():
		return false
	if f.team == fighter.team or f.rig == null or f.ragdoll == null or f.carry == null:
		return false
	if f.carry.is_held() or f.carry.is_holding():
		return false
	if not f.is_dead():
		if f.is_invulnerable():
			return false
		if f.defence != null and f.defence.is_enabled() and f.defence.is_vanished():
			return false
		if f.is_crouching() and not f.is_down():
			return false   # Upgrade 2: standing grabs whiff on a crouching fighter
	return true

func _class_of(f: Fighter) -> int:
	if f.is_dead():
		return Cls.DEAD
	var st := f.get_state()
	if f.ragdoll.is_full_ragdoll() or st == RagdollController.State.LAUNCHED or st == RagdollController.State.GROUNDED:
		return Cls.RAGDOLL
	if st in [RagdollController.State.FLINCH, RagdollController.State.STAGGER, RagdollController.State.GETUP]:
		return Cls.STUNNED
	if f.combat != null and (f.combat.is_hit_stunned() or f.combat.is_stumbling() or f.combat.is_dazed()):
		return Cls.STUNNED
	return Cls.NEUTRAL

## Where a body is for picking and reach: a standing capsule's feet, or a
## ragdoll's nearest bone to our hands.
func _body_point(f: Fighter) -> Vector3:
	if f.ragdoll != null and (f.ragdoll.is_full_ragdoll() or f.is_dead()):
		var b := _nearest_bone(f, Bones.PHYSICAL)
		if b != &"":
			return _bone_pos(f, b)
	return f.get_ground_position()

func _pick_body(aim: Vector3, reach: float) -> Fighter:
	var origin := fighter.get_ground_position()
	var best: Fighter = null
	var best_s := -INF
	for f in _grabbables():
		var p := _body_point(f)
		var rag := f.ragdoll.is_full_ragdoll() or f.is_dead()
		if rag and not _bone_height_ok(p):
			continue
		var s := Targeting.strike_score(origin, aim, p, reach + (GRAB_BODY_MARGIN if rag else 0.0))
		if s > best_s:
			best_s = s
			best = f
	return best

## Distance used for the reach test at the active frame.
func _reach_distance(f: Fighter) -> float:
	var origin := fighter.global_position
	if f.ragdoll.is_full_ragdoll() or f.is_dead():
		var b := _nearest_bone(f, Bones.PHYSICAL)
		if b == &"":
			return INF
		var p := _bone_pos(f, b)
		if not _bone_height_ok(p):
			return INF
		return maxf(_flat_dist(p, origin) - GRAB_BODY_MARGIN, 0.0)
	var to := f.get_ground_position() - origin
	to.y = 0.0
	var d := to.length()
	if d > 0.05 and fighter.get_forward().dot(to / d) < GRAB_CONE_DOT:
		return INF
	return d

func _bone_height_ok(p: Vector3) -> bool:
	var dy := p.y - fighter.global_position.y
	var h := fighter.get_height_scale()
	return dy >= GRAB_BONE_HEIGHT.x * h and dy <= GRAB_BONE_HEIGHT.y * h

## The stick picks the part: toward the target (or neutral) = collar, sideways =
## arm on that side, away = leg.
func _pick_part(target: Fighter) -> void:
	var stick := Vector3(fighter.move_input.x, 0.0, fighter.move_input.z)
	_reach_part = Part.COLLAR
	_reach_side = 1.0
	_stick_part = false
	if stick.length() < PART_STICK_DEADZONE:
		return
	_stick_part = true
	var to := _reach_dir
	if target != null:
		to = _flat(_body_point(target) - fighter.global_position, _reach_dir)
	var ang := rad_to_deg(to.angle_to(stick.normalized()))
	var right := to.cross(Vector3.UP)
	_reach_side = 1.0 if right.dot(stick) >= 0.0 else -1.0
	if ang <= PART_SIDE_ANGLE:
		_reach_part = Part.COLLAR
	elif ang >= 180.0 - PART_SIDE_ANGLE:
		_reach_part = Part.LEG
	else:
		_reach_part = Part.ARM

func _choose_bone(v: Fighter, cls: int) -> StringName:
	if cls == Cls.RAGDOLL or cls == Cls.DEAD:
		var pool: Array[StringName] = Bones.PHYSICAL
		if _stick_part:
			pool = [COLLAR_BONES, ARM_BONES, LEG_BONES][_reach_part]
		var b := _nearest_bone(v, pool)
		if b == &"":
			b = _nearest_bone(v, Bones.PHYSICAL)
		return _hold_bone_for(v, b)
	match _reach_part:
		Part.ARM:
			return _side_bone(v, Bones.L_LOWER_ARM, Bones.R_LOWER_ARM)
		Part.LEG:
			return _side_bone(v, Bones.L_LOWER_LEG, Bones.R_LOWER_LEG)
	return Bones.CHEST

## The bone a hold pins for a touched bone: the forearm of an arm, the shin of
## a leg, the chest for the torso and head.
func _hold_bone_for(v: Fighter, b: StringName) -> StringName:
	var want := Bones.CHEST
	match b:
		Bones.L_UPPER_ARM, Bones.L_LOWER_ARM, Bones.L_HAND:
			want = Bones.L_LOWER_ARM
		Bones.R_UPPER_ARM, Bones.R_LOWER_ARM, Bones.R_HAND:
			want = Bones.R_LOWER_ARM
		Bones.L_UPPER_LEG, Bones.L_LOWER_LEG, Bones.L_FOOT:
			want = Bones.L_LOWER_LEG
		Bones.R_UPPER_LEG, Bones.R_LOWER_LEG, Bones.R_FOOT:
			want = Bones.R_LOWER_LEG
	if v.rig.is_bone_severed(want) or v.rig.get_physical_bone(want) == null:
		return Bones.CHEST
	return want

## Of a left/right pair, the one on the grabber's `_reach_side`.
func _side_bone(v: Fighter, left: StringName, right: StringName) -> StringName:
	var r := _reach_dir.cross(Vector3.UP)
	var pl := _bone_pos(v, left)
	var pr := _bone_pos(v, right)
	var pick := right if (pr - pl).dot(r) * _reach_side >= 0.0 else left
	var other := left if pick == right else right
	if v.rig.is_bone_severed(pick):
		pick = other
	if v.rig.is_bone_severed(pick):
		return Bones.CHEST
	return pick

func _nearest_bone(v: Fighter, pool: Array[StringName]) -> StringName:
	var hands := fighter.global_position + Vector3.UP * GRAB_HAND_HEIGHT * fighter.get_height_scale() \
		+ fighter.get_forward() * 0.3
	var best: StringName = &""
	var best_d := INF
	for b in pool:
		if v.rig.get_physical_bone(b) == null or v.rig.is_bone_severed(b):
			continue
		var d := _bone_pos(v, b).distance_squared_to(hands)
		if d < best_d:
			best_d = d
			best = b
	return best

static func _part_of(bone: StringName) -> int:
	if bone in ARM_BONES:
		return Part.ARM
	if bone in LEG_BONES:
		return Part.LEG
	return Part.COLLAR

func _pick_prop(reach: float) -> ThrowableProp:
	var origin := fighter.global_position
	var best: ThrowableProp = null
	var best_d := INF
	for p in _props_near(origin, reach):
		if p.holder != null or not p.can_pick_up():
			continue
		var dy := p.global_position.y - origin.y
		if dy < PROP_HEIGHT.x or dy > PROP_HEIGHT.y:
			continue
		var d := _flat_dist(p.global_position, origin)
		if d <= reach and d < best_d:
			best_d = d
			best = p
	return best

func _props_near(origin: Vector3, reach: float) -> Array[ThrowableProp]:
	var out: Array[ThrowableProp] = []
	for n in fighter.get_tree().get_nodes_in_group(&"throwable_props"):
		if n is ThrowableProp and is_instance_valid(n):
			out.append(n as ThrowableProp)
	if not out.is_empty():
		return out
	var shape := SphereShape3D.new()
	shape.radius = reach + 0.5
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(Basis(), origin + Vector3.UP * 0.8)
	q.collision_mask = 0xFFFFFFFF
	q.collide_with_bodies = true
	q.collide_with_areas = false
	q.exclude = [fighter.get_rid()]
	for hit in fighter.get_world_3d().direct_space_state.intersect_shape(q, 32):
		var c: Object = hit.get("collider")
		if c is ThrowableProp and not out.has(c):
			out.append(c as ThrowableProp)
	return out

# =====================================================================================
# Fallback hold: kinematic anchor + pin joint (until RagdollController.begin_held lands)
# =====================================================================================
func _pin_begin(v: Fighter, bone: StringName) -> bool:
	var rd := v.ragdoll
	rd.set_gripped(true)
	if not rd.is_full_ragdoll() or not rd.is_gripped():
		rd.set_gripped(false)
		return false
	var pb := v.rig.get_physical_bone(bone)
	_pin_body = pb.get_rid()
	_pin_local = _grip_local(v, bone)
	var body_xf: Transform3D = PhysicsServer3D.body_get_state(_pin_body, PhysicsServer3D.BODY_STATE_TRANSFORM)
	var p := body_xf * _pin_local
	_hand_pos = p
	_pin_anchor = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(_pin_anchor, PhysicsServer3D.BODY_MODE_KINEMATIC)
	PhysicsServer3D.body_set_collision_layer(_pin_anchor, 0)
	PhysicsServer3D.body_set_collision_mask(_pin_anchor, 0)
	PhysicsServer3D.body_set_state(_pin_anchor, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), p))
	PhysicsServer3D.body_set_space(_pin_anchor, fighter.get_world_3d().space)
	_pin_joint = PhysicsServer3D.joint_create()
	PhysicsServer3D.joint_make_pin(_pin_joint, _pin_anchor, Vector3.ZERO, _pin_body, _pin_local)
	PhysicsServer3D.joint_disable_collisions_between_bodies(_pin_joint, true)
	_pin_slip = 0.0
	# Jolt cannot keep a 1.5 kg forearm on a hand while it carries 70 kg; a
	# heavier held chain evens the mass ratios (LimbGrab spike).
	var boost := PIN_ARM_BOOST if bone in ARM_BONES else (PIN_LEG_BOOST if bone in LEG_BONES else 1.0)
	_boosted.clear()
	if boost > 1.0:
		var c := bone
		while c != &"" and c != Bones.CHEST and c != Bones.HIPS:
			var cb := v.rig.get_physical_bone(c)
			if cb != null and not v.rig.is_bone_severed(c):
				_boosted.append([cb.get_rid(), cb.mass])
				PhysicsServer3D.body_set_param(cb.get_rid(), PhysicsServer3D.BODY_PARAM_MASS, cb.mass * boost)
			c = Bones.PARENT.get(c, &"")
	return true

## Moves the anchor to the hand; false = the grip slipped (stretched too long).
func _pin_tick(dt: float) -> bool:
	if not _pin_anchor.is_valid():
		return false
	PhysicsServer3D.body_set_state(_pin_anchor, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), _hand_pos))
	var xf: Transform3D = PhysicsServer3D.body_get_state(_pin_body, PhysicsServer3D.BODY_STATE_TRANSFORM)
	var stretch := (xf * _pin_local).distance_to(_hand_pos)
	if not is_finite(stretch):
		return false
	if stretch > PIN_SLIP_DISTANCE:
		_pin_slip += dt
		return _pin_slip < PIN_SLIP_TIME
	_pin_slip = 0.0
	return true

func _pin_end(v: Fighter) -> void:
	_pin_free()
	for bm: Array in _boosted:
		PhysicsServer3D.body_set_param(bm[0], PhysicsServer3D.BODY_PARAM_MASS, bm[1])
	_boosted.clear()
	if v != null and is_instance_valid(v) and v.ragdoll:
		v.ragdoll.set_gripped(false)

func _pin_free() -> void:
	if _pin_joint.is_valid():
		PhysicsServer3D.free_rid(_pin_joint)
	if _pin_anchor.is_valid():
		PhysicsServer3D.free_rid(_pin_anchor)
	_pin_joint = RID()
	_pin_anchor = RID()

## The grip point (neck for the chest, wrist for a forearm, ankle for a shin)
## in the bone body's frame.
static func _grip_local(f: Fighter, b: StringName) -> Vector3:
	var child: StringName = Bones.HEAD
	match b:
		Bones.L_LOWER_ARM: child = Bones.L_HAND
		Bones.R_LOWER_ARM: child = Bones.R_HAND
		Bones.L_LOWER_LEG: child = Bones.L_FOOT
		Bones.R_LOWER_LEG: child = Bones.R_FOOT
	var end := HumanoidRig.scaled(HumanoidRig.REST[child], f.rig.height_scale, f.rig.width_scale)
	return f.rig.get_body_offset(b).affine_inverse() * end

static func _grip_world(f: Fighter, b: StringName) -> Vector3:
	var pb := f.rig.get_physical_bone(b)
	if pb == null:
		return f.get_aim_point()
	var xf: Transform3D
	if pb.is_simulating_physics():
		xf = PhysicsServer3D.body_get_state(pb.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
	else:
		xf = f.rig.get_bone_global_transform(b) * f.rig.get_body_offset(b)
	return xf * _grip_local(f, b)

static func _bone_pos(f: Fighter, b: StringName) -> Vector3:
	var pb := f.rig.get_physical_bone(b)
	if pb != null and pb.is_simulating_physics():
		return (PhysicsServer3D.body_get_state(pb.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM) as Transform3D).origin
	return f.rig.get_bone_global_position(b)

# =====================================================================================
# Helpers
# =====================================================================================
## Bones of a held body ignore the holder's capsule (and back) while held and
## for EXCEPTION_KEEP after the release.
func _body_exception(v: Fighter, on: bool) -> void:
	var cap := fighter.get_rid()
	if on:
		for pb: PhysicalBone3D in v.rig.get_physical_bones():
			var r := pb.get_rid()
			if _excepted.has(r):
				continue
			PhysicsServer3D.body_add_collision_exception(r, cap)
			PhysicsServer3D.body_add_collision_exception(cap, r)
			_excepted.append(r)

func _release_exceptions_later(v: Fighter) -> void:
	var ex := _excepted.duplicate()
	_excepted.clear()
	if fighter == null or not is_instance_valid(fighter) or ex.is_empty():
		return
	# Re-add (a motor's end_held may have cleared them) and drop them once apart.
	var cap := fighter.get_rid()
	for r: RID in ex:
		PhysicsServer3D.body_add_collision_exception(r, cap)
		PhysicsServer3D.body_add_collision_exception(cap, r)
	var wg: WeakRef = weakref(fighter)
	var wv: WeakRef = weakref(v)
	TimeDirector.real_timer(EXCEPTION_KEEP).timeout.connect(func() -> void:
		if wg.get_ref() == null or wv.get_ref() == null:
			return
		for r: RID in ex:
			PhysicsServer3D.body_remove_collision_exception(r, cap)
			PhysicsServer3D.body_remove_collision_exception(cap, r))

func _capsule_exception(v: Fighter, on: bool) -> void:
	if on:
		fighter.add_collision_exception_with(v)
		v.add_collision_exception_with(fighter)
	else:
		fighter.remove_collision_exception_with(v)
		v.remove_collision_exception_with(fighter)

## Abort a reach / hold without any effect on the other body beyond letting go.
func _abort(reason: StringName) -> void:
	match _phase:
		Phase.REACH, Phase.RECOVER:
			_phase = Phase.IDLE
			_target = null
		Phase.HOLD, Phase.SLAM, Phase.CLINCH, Phase.ENEMY_HOLD:
			drop(reason)
	_press_buffer = -INF

func _enter_recover(t: float, still := false) -> void:
	_phase = Phase.RECOVER
	_recover_left = t
	_recover_still = still
	_target = null

func _in_air() -> bool:
	if fighter.traversal != null and fighter.traversal.is_airborne():
		return true
	return fighter.is_airborne() or (not fighter.is_on_floor() and fighter.velocity.y > 0.5)

## The stick in world space, or camera forward when neutral (strike aim).
func _aim_dir() -> Vector3:
	if fighter.brain != null and fighter.brain.has_method(&"get_aim_dir"):
		var d: Vector3 = fighter.brain.call(&"get_aim_dir")
		if d.length_squared() > 1e-4:
			return d
	var s := Vector3(fighter.move_input.x, 0.0, fighter.move_input.z)
	return s if s.length() > 0.2 else fighter.get_forward()

func _preset_hit(v: Fighter, move_id: StringName, tier: int, damage: float, bone: StringName,
		dir: Vector3) -> HitInfo:
	var info := HitInfo.new()
	info.attacker = fighter
	info.victim = v
	info.move_id = move_id
	info.kind = &"throw"
	info.tier = tier
	info.reaction = HitInfo.reaction_for_tier(tier)
	info.damage = damage
	info.hit_bone = bone
	info.hit_position = v.rig.get_bone_global_position(bone) if v.rig else v.get_aim_point()
	info.hit_direction = dir.normalized() if dir.length_squared() > 1e-6 else fighter.get_forward()
	info.hitstop = Power.hitstop_for(tier)
	info.unblockable = true
	info.level = HitInfo.Level.MID
	return info

func _damage_mult() -> float:
	var m := float(fighter.config.get("damage_mult", 1.0))
	if fighter.brain != null and fighter.brain.has_method(&"get_damage_mult"):
		m *= float(fighter.brain.call(&"get_damage_mult"))
	return m

static func _flat(v: Vector3, fallback: Vector3) -> Vector3:
	var f := Vector3(v.x, 0.0, v.z)
	if f.length_squared() < 1e-6:
		return fallback
	return f.normalized()

static func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

# --- Poses (agent P provides the Round 5 ids; Upgrade 2 fallbacks until then) -------------
func _pose_play(f: Fighter, id: StringName, duration: float, fallback: StringName) -> void:
	if f == null or f.animator == null:
		return
	if PoseLibrary.has_move(id):
		f.animator.play_timed(id, duration)
	elif fallback != &"" and PoseLibrary.has_move(fallback):
		f.animator.play_move(fallback, duration * 0.3, duration * 0.2, duration * 0.5)

func _pose_hold(f: Fighter, id: StringName, fallback: StringName) -> void:
	if f == null or f.animator == null:
		return
	if PoseLibrary.HOLDS.has(id):
		f.animator.hold_pose(id)
	elif fallback != &"" and PoseLibrary.HOLDS.has(fallback):
		f.animator.hold_pose(fallback)

## Carrying a body: the carry locomotion and the arm-out upper overlay (P).
func _carry_pose(on: bool) -> void:
	var a := fighter.animator
	if a == null:
		return
	if on:
		a.set_locomotion_style(&"carry")
		if PoseLibrary.has_pose(&"carry_hold") or PoseLibrary.HOLDS.has(&"carry_hold"):
			a.set_upper_overlay(&"carry_hold")
		else:
			a.hold_pose(&"grab_hold")
	else:
		a.set_locomotion_style(&"walk")
		a.set_upper_overlay(&"")
		var hid := a.get_hold_id()
		if hid == &"grab_hold" or hid == &"throw_charge" or hid == &"power_charge":
			a.release_pose()

