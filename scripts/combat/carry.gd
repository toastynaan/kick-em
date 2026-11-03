class_name Carry
extends Node
## Round 7 grabs (docs/Round 7 — Freeflow Combat.md: Grab, drive and throw):
## the player's grab (freeflow pick, glide, clinch), the hold (a collar clinch,
## the body upright in front), the knee, the baseball throw, the drive (run the
## body into things: break through, slam, bowl), props in hand, and being
## grabbed (victim side, enemy grabs, the grab break).
## OWNER: agent G (grabs, drive & throw). CONTRACT STUB: keep every public signature.
##
## Contract:
## - Fighter creates this node for every fighter (setup(fighter)).
## - CombatController routes every Grab press here. While is_holding(): LIGHT
##   (throw) and LEG_KICK (knee) go to on_attack_pressed/released (true =
##   consumed), DASH to on_drive_pressed/released, GRAB to on_grab_pressed (release).
## - An enemy grab move's active frames touching a fighter call connect_enemy_grab().
## - The drive run itself is Traversal's (begin_drive, end_drive, get_drive_speed,
##   set_drive_speed, get_drive_dir: agent M). Carry owns the hold, the probes
##   ahead of the held body and everything they meet.
## - Camera, FX and HUD read is_driving(), get_throw_windup(), is_gliding() and
##   GameEvents.drive_started / drive_ended / drive_impact / throw_windup.
##
## How it works (agent G):
## - Grab press (player): the target is picked like a strike: live enemies by
##   Targeting.pick_freeflow_target (stick from brain.get_aim_dir(), the
##   CombatController combat target, camera forward) within R7_GRAB_GLIDE;
##   downed and dead bodies by the same freeflow score from their nearest bone.
##   A target farther than GRAB_RANGE + R7_GLIDE_FROM is glided to at
##   R7_GLIDE_SPEED (at most R7_GLIDE_MAX_TIME, glide_started) until GRAB_RANGE x
##   GLIDE_STOP; then Tuning.GRAB_FRAMES of startup with a short step in. The
##   chosen target connects if it is within reach + R7_CONNECT_MARGIN at the
##   active frame. No body at all but a loose ThrowableProp within GRAB_RANGE:
##   the prop is taken at once. Nothing: a whiff (GRAB_WHIFF_FRAMES recovery).
## - A neutral standing enemy is caught in a clinch: held standing in front for
##   Tuning.GRAB_BREAK_FRAMES, when its Grab press breaks it (AIBrain
##   wants_grab_break decides for the AI). Reacting (Fighter.is_reacting, or the
##   older stun states), downed and dead bodies connect at once.
## - The hold is always the collar: RagdollController.begin_held(Chest, hand,
##   holder) keeps the body upright facing the holder, the neck at SOCKET_HOLD
##   in front. `hand` is a top-level Node3D moved every tick to the socket,
##   easing in at HAND_CATCH_UP so a grab reads as a yank. If begin_held does not
##   take, a local fallback pins the chest with a kinematic anchor and a Jolt
##   pin joint. Carry assist: past HOLD_ASSIST_FROM the whole body is pulled
##   toward the hand (bounded), so it follows a holder who turns or runs.
## - Holding: a live victim struggles out after R7_HOLD_MAX (both stumble;
##   driving resets the clock). LEG_KICK = knee (up to HOLD_KNEES_MAX, the last
##   a headbutt; a flinch-tier hit, the hold kept). GRAB = release: dropped in
##   front, a live body still upright lands on its feet and stumbles.
## - Throw (LIGHT): the press starts the wind-up (get_throw_windup 0..1, the
##   throw_windup event every tick, P's throw_windup pose); the release throws
##   at lerp(R7_THROW_SPEED_MIN, R7_THROW_SPEED_MAX, wind-up). A press released
##   within Tuning.R7_HOLD_THRESHOLD (the punch button's tap/hold split) is a
##   tap at the minimum; the wind-up then grows to full at R7_THROW_WINDUP_FULL.
##   The body swings back with it: the hand blends toward the right fist.
##   Direction: camera forward (flat), snapped to the enemy nearest the aim
##   within R7_THROW_ASSIST_CONE, pitched up R7_THROW_PITCH. While driving the
##   drive speed x Tuning.THROW_RUN_SHARE is added. Capped at
##   Tuning.LAUNCH_SPEED_MAX (every flying body's cap). The release is a preset
##   launch through victim.take_hit (kind &"throw", no damage: hit_landed opens
##   Defence's pursuit window like any player launch), then GameEvents.thrown:
##   the existing projectile (ImpactResolver bowls, walls, clutter).
## - Drive (DASH while holding a body): Traversal.begin_drive() runs the holder
##   forward (ramp, steering; agent M); a refused begin_drive is no drive (Dash
##   with a body never dodges). The body is held lower and further out (SOCKET_DRIVE, P's drive_hold) and
##   its bones ignore breakables (the probes judge them). Every tick, before the
##   body gets there:
##   - enemies standing in a box ahead of the body are bowled: a preset
##     knockdown (kind &"bowl", R7_DRIVE_BOWL_DAMAGE), the drive keeps
##     R7_DRIVE_BOWL_KEEP of its speed;
##   - a box cast ahead of the body (walls, pillars, tall clutter, from knee
##     height up) and a low one (breakable low clutter) find the first thing in
##     the way. Within DRIVE_DECIDE_TICKS of contact it is judged once: a
##     breakable (WorldTags.breakable_of) takes E = 1/2 (victim mass +
##     R7_DRIVE_MASS_SHARE x holder mass) vn^2 (vn: the drive speed into its face)
##     through receive_impact with a footprint big enough for both bodies. &"break"
##     or &"hole": the drive goes through at speed x sqrt(1 - absorption) (at least
##     R7_DRIVE_MIN_SPEED), chunks let the body pass, the victim takes
##     R7_DRIVE_BREAK_DAMAGE. Anything else, or an unbreakable wall: a slam at vn >=
##     R7_DRIVE_SLAM_MIN_SPEED (the drive and the hold end, the victim takes
##     R7_DRIVE_SLAM_DAMAGE + R7_DRIVE_SLAM_DAMAGE_PER_MS x vn and is knocked down
##     against the wall with R7_DRIVE_SLAM_HITSTOP; a killing slam severs a limb
##     with chance R7_SEVER_ON_KILL), else a shove (stagger, the hold ends). A
##     loose prop that holds is shoved aside by the body; a wall met at a
##     glancing angle (over DRIVE_GRAZE_ANGLE) is slid along.
##   - DASH released: the drive ends, the hold stays. At R7_DRIVE_MAX_TIME the
##     body is thrown forward at the drive speed. A hit on the holder ends both.
##   Damage and reactions go through victim.take_hit(HitInfo) with a preset tier
##   and info.drive = true. Events: drive_started, drive_ended(reason),
##   drive_impact(result).
## - Victim side (connect_enemy_grab, enemy moves e_grab / e_grab_slam): the
##   victim is held standing in front of the enemy; Grab within
##   GRAB_BREAK_FRAMES (or ENEMY_BREAK_EARLY frames before the connect) breaks
##   it; otherwise the enemy throws (e_grab) or lifts and slams (e_grab_slam):
##   a preset KNOCKDOWN with Tuning.DMG_ENEMY. Never a launch, never a limb.
##   An invulnerable victim, or one whose Defence intercepts the grab
##   (Defence.intercepts: the teleport or sidestep just before the grab's first
##   active frame), is not caught; the same goes for the player's own grab.
## Round 7 removed (from the player's kit): carrying through vaults, jumps and
## wall runs, the sprint grab drag, stick-chosen grab parts (arm and leg holds,
## the twisting throw, the leg trip), charged throws, the air body slam, and
## Upgrade 2's limb grabs (LimbGrab, giant swing).

enum Phase { IDLE, GLIDE, REACH, CLINCH, HOLD, RECOVER, ENEMY_HOLD }
enum Motor { NONE, HELD, PIN }
enum Cls { NEUTRAL, STUNNED, RAGDOLL, DEAD }

## On: CombatController routes every Grab here.
const ENABLED := true
## Tests and the Grab Lab turn the routing on before ENABLED is true.
static var force_enabled := false

# --- Local constants (candidates for Tuning) ----------------------------------------
const GRAB_ACTIVE_FRAMES := 3.0      ## frames the grab can still catch after its startup (as a jab's active frames)
const GRAB_WHIFF_FRAMES := 16.0      ## recovery of a whiffed grab (doc gives none; a cross's whiff)
const GRAB_HAND_HEIGHT := 1.1        ## m (x height) the hands reach from: ragdoll bones are measured from here
const GRAB_BODY_MARGIN := 0.35       ## m extra reach to the nearest bone of a ragdolling body (limbs, not a capsule)
const GRAB_BONE_HEIGHT := Vector2(-0.3, 2.4)  ## m: a ragdoll bone this far below / above the feet is reachable
const GRAB_CONE_DOT := 0.3           ## a standing body other than the chosen one must be roughly in front
const GLIDE_STOP := 0.7              ## the glide hands over to the startup at GRAB_RANGE x this (CombatController.LUNGE_GAP)
const WALK_LUNGE_GAP := 0.75         ## m: the startup steps in to about this distance...
const WALK_LUNGE_MAX := 6.0          ## ...at most this fast
const PRESS_BUFFER := 0.2            ## s a Grab press waits for the fighter to be free
const CLINCH_DIST := 0.72            ## m (x height) in front: where a clinched / enemy-held fighter stands
const CLINCH_PULL := 6.0             ## m/s the clinched fighter is pulled into place
const HAND_CATCH_UP := 7.0           ## m/s the hand eases from the grip point to its socket (+ the holder's speed)
const TELEPORT_DROP := 1.2           ## m the socket jumps in one tick: the holder teleported, let go
const EXCEPTION_KEEP := 0.35         ## s a released body keeps ignoring its holder
const THROW_RECOVERY_FRAMES := 12.0  ## frames after a throw or a slam before acting again
const THROW_ANIM_TIME := 0.32        ## s of the throw pose
const KNEE_HIT_CUT := Tuning.HIT_RECOVERY_CUT
## Throws: a press released within this is a tap (the punch button's split).
const THROW_TAP_TIME := Tuning.R7_HOLD_THRESHOLD
const THROW_ASSIST_RANGE := 14.0     ## m: enemies farther than this never take the aim assist
const THROW_HITSTOP := 0.0001        ## real s: a throw is not a strike, no freeze (0 would take the tier's default)
const THROW_WEIGHT := 0.2            ## HitInfo.weight of the throw's release (FX, camera)
## The wind-up pins the body to the right fist (P's throw_windup loads the
## right arm), blended in by the wind-up; this socket stands in without a rig.
const SOCKET_WINDUP := Vector3(0.35, 1.55, 0.05)
## A released live body lands on its feet and stumbles when its torso is within
## STAND_TILT of upright and its pelvis is between these heights (x height).
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
const ENEMY_SLAM_DOWN := 5.0         ## m/s the e_grab_slam drives its victim into the floor
const ENEMY_TOSS := Vector2(2.5, 1.5)  ## m/s (forward, up) a grab-throw tosses the knocked-down victim
const ENEMY_RECOVER := 0.4           ## s after an enemy grab-throw or slam
const PROP_THROW_SPEED := 16.0       ## m/s a thrown prop leaves the hand (doc gives none)
const PROP_HAND_OFFSET := Vector3(0.0, -0.08, -0.06)  ## prop in the right-hand attachment frame
const PROP_RELEASE_AHEAD := 0.35     ## m in front of the hand a prop is let go
const PROP_HEIGHT := Vector2(-0.3, 2.0)  ## m: a prop this far below / above the feet can be taken
const HEAD_CENTER := 0.11            ## m (x height) from the head bone (the neck) to the head's centre
## Carry assist: the motor drives one bone, so a holder whipping round (or
## driving at 9.5 m/s) leaves 75 kg behind the hand. Past HOLD_ASSIST_FROM the
## whole body (every bone alike) is pulled toward the hand at up to HOLD_ASSIST_ACCEL.
const HOLD_ASSIST_FROM := 0.3        ## m from the held bone's centre to the hand
const HOLD_ASSIST_GAIN := 14.0       ## 1/s of the excess distance -> extra speed toward the hand
const HOLD_ASSIST_ACCEL := 220.0     ## m/s^2 at most, whole body (x the holder time factor squared)
const PIN_SLIP_DISTANCE := 0.45      ## m fallback pin stretch that lets go...
const PIN_SLIP_TIME := 0.15          ## ...after this long
## Hand sockets in the holder's frame (x height scale for y and z): where the
## victim's neck is carried. Holding: high in front, the body upright, feet
## near the floor. Driving: lower and further out, the feet dragging.
const SOCKET_HOLD := Vector3(0.08, 1.5, -0.6)
const SOCKET_DRIVE := Vector3(0.0, 1.4, -0.72)
# Drive probes (x height scale). The held body is a box DRIVE_BODY_AHEAD in
# front of the holder's feet, DRIVE_BODY_HALF wide (x) and deep (z).
const DRIVE_BODY_AHEAD := 0.72       ## m: the body's centre ahead of the holder (SOCKET_DRIVE)
const DRIVE_BODY_HALF := Vector2(0.35, 0.22)  ## m half width, half depth of the held body
const DRIVE_HIGH_FROM := 0.55        ## m: the main probe starts above step height (Tuning.STEP_MAX)...
const DRIVE_TOP := 1.75              ## ...and ends at the head (door lintels at 2.4 m clear it)
const DRIVE_LOW_FROM := 0.12         ## m: the low probe (breakables only) covers the shins
const DRIVE_LOOK_TICKS := 3.0        ## ticks of travel the probes look ahead (+ DRIVE_LOOK_MARGIN)
const DRIVE_LOOK_MARGIN := 0.15      ## m
const DRIVE_DECIDE_TICKS := 2.0      ## a contact this many ticks away is judged now (+ DRIVE_DECIDE_MARGIN)
const DRIVE_DECIDE_MARGIN := 0.08    ## m
const DRIVE_GRAZE_ANGLE := 60.0      ## degrees off a wall's normal: slid along, never a slam
const DRIVE_PROBE_RETRIES := 6       ## colliders skipped per probe (debris, props, what the drive already broke)
const DRIVE_NORMAL_RAY := 0.4        ## m each side of a contact point the face-normal ray reaches along the drive
## The hole a drive punches in a panel: half width, half height from the floor
## (x height), big enough for the held body and the holder's capsule behind it.
const DRIVE_HOLE_HALF := Vector2(0.55, 1.05)
const DRIVE_OPEN_SKIP := 0.8         ## a panel already this open under the footprint is passed without a decision
const DRIVE_SLAM_INTO := 0.6         ## m/s the slammed body keeps into the wall (it crumples there)
const DRIVE_SLAM_TRAUMA := 0.5       ## camera trauma of a full-speed slam (x vn / R7_DRIVE_MAX_SPEED; Tuning.TRAUMA wall_break)
const DRIVE_BOWL_HITSTOP := 0.03     ## s: a bowl barely stops the drive (the held body freezes with the holder)
const DRIVE_BOWL_WEIGHT := 0.6       ## HitInfo.weight of a bowl (FX, sound)
const DRIVE_BOWL_WIDEN := 0.15       ## m each side the bowl box is wider than the body (shoulders)

var fighter: Fighter
## What this fighter holds: a Fighter (alive or dead) or a ThrowableProp. null = nothing.
var held: Node3D = null
## AI and tests: world direction for this fighter's next throw (ZERO = camera / facing).
var throw_aim := Vector3.ZERO

## Last results (tests, lab, debug).
var last_grab_result: StringName = &""   ## &"whiff" | &"clinch" | &"hold" | &"prop" | &"broken" | &"intercepted"
var last_throw_velocity := Vector3.ZERO
var last_throw_windup := 0.0             ## wind-up 0..1 of the last throw
var last_throw_assist: Fighter = null    ## the enemy the last throw snapped to (null = none)
var last_drop_reason: StringName = &""
var last_drive_result: StringName = &""  ## &"break" | &"slam" | &"shove" | &"bowl" of the last drive contact
var last_drive_end: StringName = &""     ## the last drive_ended reason
var last_drive_energy := 0.0             ## J of the last breakable the drive met

var _phase: int = Phase.IDLE
var _t := 0.0                  # own s in the current phase
var _recover_left := 0.0
var _recover_still := false    # a whiff, break or slam stands still; a throw keeps moving
var _break_pushed: Fighter      # the other fighter of a grab break's push (stopped with us)
var _press_buffer := -INF
var _last_grab_press := -INF   # real time of this fighter's last Grab press
# Glide and reach
var _target: Fighter
var _reach_dir := Vector3.FORWARD
var _reach_len := 0.0
# Hold (holder side)
var _victim: Fighter
var _prop: ThrowableProp
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
var _queued_t := 0.0           # its press time (a held throw keeps winding up from it)
var _queued_up := false        # released during the clinch
var _knees := 0
var _knee_t := -1.0
var _knee_hit := false
var _knee_queued := false
# Throw wind-up
var _windup_down := false
var _windup_t0 := 0.0
# Drive
var _driving := false
var _drive_queued := false     # DASH pressed during the clinch: drive once the hold connects
var _drive_t := 0.0            # own s since the drive started
var _drive_done := {}          # breakable instance id -> outcome (judged once per drive)
var _drive_bowled := {}        # fighter instance id -> true
# Fallback pin
var _pin_anchor := RID()
var _pin_joint := RID()
var _pin_body := RID()
var _pin_local := Vector3.ZERO
var _pin_slip := 0.0
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
# Probes
var _probe_box := BoxShape3D.new()
var _probe_q := PhysicsShapeQueryParameters3D.new()

func setup(p_fighter: Fighter) -> void:
	fighter = p_fighter
	process_physics_priority = 5   # after every Fighter moved its capsule (0), before ImpactResolver (100)
	_probe_q.shape = _probe_box
	_probe_q.collide_with_areas = false
	_probe_q.collide_with_bodies = true
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.fighter_died.connect(_on_fighter_died)

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
		Phase.GLIDE, Phase.REACH, Phase.CLINCH, Phase.ENEMY_HOLD:
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

## Attack press while holding: LIGHT winds up a throw, LEG_KICK knees. true = consumed.
func on_attack_pressed(action: int, now: float) -> bool:
	match _phase:
		Phase.CLINCH:
			if _is_throw_action(action) or _is_knee_action(action):
				_queued = action
				_queued_t = now
				_queued_up = false
			return true
		Phase.ENEMY_HOLD:
			return true
		Phase.HOLD:
			pass
		_:
			return false
	if _prop != null:
		if _is_throw_action(action):
			_throw_prop()
			return true
		return false   # any other button with a prop in hand is a normal strike
	if _victim == null:
		return false
	if _is_throw_action(action):
		if not _windup_down:
			_windup_down = true
			_windup_t0 = now
			_windup_pose(true)
			GameEvents.throw_windup.emit(fighter, 0.0)
		return true
	if _is_knee_action(action) and not _driving:
		_knee_press()
	return true

func on_attack_released(action: int, now: float) -> void:
	if _phase == Phase.CLINCH and action == _queued:
		_queued_up = true   # released during the clinch: a tap once the hold connects
		return
	if not _is_throw_action(action) or not _windup_down:
		return
	if _phase != Phase.HOLD or _victim == null:
		_cancel_windup()
		return
	_release_throw(now)

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
	if victim.is_invulnerable() or _intercepted(victim, move_id):
		return false   # a dodge, a counter, or Defence's teleport / sidestep took it
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
## A drive in progress ends with &"hit" for a hit, &"drop" otherwise.
func drop(reason: StringName) -> void:
	last_drop_reason = reason
	match _phase:
		Phase.GLIDE, Phase.REACH, Phase.RECOVER:
			_abort(reason)
		Phase.CLINCH, Phase.ENEMY_HOLD:
			_end_socket_hold(reason != &"death")
			_phase = Phase.IDLE
		Phase.HOLD:
			if _prop != null:
				var p := _prop
				_prop = null
				held = null
				if is_instance_valid(p):
					p.drop(Vector3(fighter.velocity.x, 0.0, fighter.velocity.z) if fighter else Vector3.ZERO)
				GameEvents.carry_changed.emit(fighter, null)
				_phase = Phase.IDLE
				return
			if _driving:
				_end_drive(&"hit" if reason == &"hit" else &"drop")
			var v := _victim
			var dir := fighter.get_forward() if fighter else Vector3.FORWARD
			_end_body_hold()
			if v != null and is_instance_valid(v):
				_stand_or_drop(v, dir, RELEASE_PUSH)
			_phase = Phase.IDLE

## Walk speed share while holding (Traversal and Fighter read it).
func get_move_speed_mult() -> float:
	match _phase:
		Phase.HOLD:
			return Tuning.HOLD_WALK_MULT if _victim != null else 1.0
		Phase.CLINCH, Phase.ENEMY_HOLD:
			return 0.0
		Phase.RECOVER:
			return 0.0 if _recover_still else 1.0
	if is_held():
		return 0.0
	return 1.0

func get_sprint_cap_mult() -> float:
	return Tuning.HOLD_SPRINT_MULT if _victim != null and _phase == Phase.HOLD else 1.0

## Round 7: nothing is vaulted with a body in hand (0 while holding one).
func get_vault_max_height() -> float:
	return 0.0 if _victim != null and _phase == Phase.HOLD else Tuning.VAULT_MAX

func get_debug_text() -> String:
	var names := ["idle", "glide", "reach", "clinch", "hold", "recover", "enemy_hold"]
	var s: String = "carry %s" % names[_phase]
	if _victim != null and is_instance_valid(_victim):
		s += " %s (%s, %s) %.1fs knees %d" % [_victim.name, _bone, ["none", "held", "pin"][_motor], _hold_t, _knees]
	if _prop != null and is_instance_valid(_prop):
		s += " prop %s" % _prop.kind
	if _windup_down:
		s += " windup %.2f" % get_throw_windup()
	if _driving:
		s += " DRIVE %.1f m/s %.1fs" % [_current_drive_speed(), _drive_t]
	if is_held():
		s += " held by %s" % _holder.name
	return s

# --- Extra API (agent G) ---------------------------------------------------------------
## Busy with a grab: gliding, reaching, clinching, holding a body or recovering.
## Fighter.can_act() is false while this is true.
func is_busy() -> bool:
	return _phase != Phase.IDLE and not (_phase == Phase.HOLD and _prop != null)

func is_holding_body() -> bool:
	return _victim != null and is_instance_valid(_victim) and _phase == Phase.HOLD

func is_holding_prop() -> bool:
	return _prop != null and is_instance_valid(_prop)

## Winding up a throw (LIGHT held with a body).
func is_charging() -> bool:
	return _windup_down

## Round 7: throws have no charge levels (the wind-up is continuous). Always 0.
func get_charge_level() -> int:
	return 0

## Round 7: the air body slam is gone. Always false (kept for older readers).
func is_slamming() -> bool:
	return false

## True while the grab glides to its target (camera smoothing; CombatController.is_gliding).
func is_gliding() -> bool:
	return _phase == Phase.GLIDE

## The grab's target while gliding or reaching (null otherwise).
func get_grab_target() -> Fighter:
	return _target if _phase in [Phase.GLIDE, Phase.REACH] and is_instance_valid(_target) else null

## &"collar" while holding a body (the only hold), &"" otherwise.
func get_held_part() -> StringName:
	return &"collar" if _victim != null else &""

func get_held_bone() -> StringName:
	return _bone if _victim != null else &""

## Seconds (holder time) of the hold clock (reset while driving).
func get_hold_time() -> float:
	return _hold_t

## True while the hold uses RagdollController.begin_held (false: the local pin).
func uses_ragdoll_motor() -> bool:
	return _motor == Motor.HELD

## The node the held bone is pinned to (lab, tests).
func get_hand() -> Node3D:
	return _hand

## Seconds the current drive has run (0 when not driving).
func get_drive_time() -> float:
	return _drive_t if _driving else 0.0

## The drive's speed now (m/s, 0 when not driving): Traversal's.
func get_drive_speed() -> float:
	return _current_drive_speed() if _driving else 0.0

## Take hold of `target` now, skipping the glide and reach (lab, tests, scripted
## scenes). A neutral enemy still gets its break window unless `skip_clinch`.
## `_part` is ignored (Round 7: always the collar).
func grab_now(target: Node3D, _part := &"", skip_clinch := false) -> bool:
	if fighter == null or target == null or not is_instance_valid(target) or _phase != Phase.IDLE or is_held():
		return false
	if target is ThrowableProp:
		return _take_prop(target as ThrowableProp)
	var v := target as Fighter
	if v == null or not _grabbable(v):
		return false
	_reach_dir = _flat(v.get_ground_position() - fighter.get_ground_position(), fighter.get_forward())
	fighter.snap_facing(_reach_dir)
	return _catch(v, skip_clinch)

## Throw what is held with exactly `velocity` (capped at Tuning.LAUNCH_SPEED_MAX).
## Tests and scripted scenes; the player throws with LIGHT.
func throw_at(velocity: Vector3) -> bool:
	if _phase != Phase.HOLD:
		return false
	if _prop != null:
		_release_prop(velocity)
		return true
	if _victim == null:
		return false
	_cancel_windup()
	_launch_held(velocity.limit_length(Tuning.LAUNCH_SPEED_MAX), &"drop")
	return true

## Throw speed (m/s) for a wind-up of `windup` 0..1, before the drive bonus and the cap.
static func throw_speed(windup: float) -> float:
	return lerpf(Tuning.R7_THROW_SPEED_MIN, Tuning.R7_THROW_SPEED_MAX, clampf(windup, 0.0, 1.0))

## Wind-up 0..1 after holding the throw button `held_s` real seconds: 0 for a
## tap (THROW_TAP_TIME), 1 at Tuning.R7_THROW_WINDUP_FULL.
static func windup_of(held_s: float) -> float:
	return clampf((held_s - THROW_TAP_TIME) / maxf(Tuning.R7_THROW_WINDUP_FULL - THROW_TAP_TIME, 0.01), 0.0, 1.0)

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
		Phase.GLIDE:
			_tick_glide(dt)
		Phase.REACH:
			_tick_reach(dt)
		Phase.CLINCH:
			_tick_clinch(dt, now)
		Phase.HOLD:
			_tick_hold(dt, now)
		Phase.RECOVER:
			_recover_left -= dt
			if _recover_left <= 0.0:
				_phase = Phase.IDLE
				_end_break_push()
		Phase.ENEMY_HOLD:
			_tick_enemy_hold(dt)
	if _press_buffer > -INF and _phase == Phase.IDLE:
		if now - _press_buffer > PRESS_BUFFER:
			_press_buffer = -INF
		elif _can_start():
			_press_buffer = -INF
			_start_grab(now)

func _exit_tree() -> void:
	if _phase in [Phase.HOLD, Phase.CLINCH, Phase.ENEMY_HOLD]:
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
	var reach := Tuning.GRAB_RANGE * fighter.get_height_scale()
	var target := _pick_target(reach)
	if target == null:
		var prop := _pick_prop(reach)
		if prop != null and _take_prop(prop):
			return
	_target = target
	_reach_len = reach
	_reach_dir = fighter.get_forward()
	if target != null:
		var p := _body_point(target)
		_reach_dir = _flat(p - fighter.global_position, _reach_dir)
		fighter.snap_facing(_reach_dir)
		var d := _flat_dist(p, fighter.global_position)
		if d > _reach_gap(target) + reach + Tuning.R7_GLIDE_FROM:
			_phase = Phase.GLIDE
			_t = 0.0
			GameEvents.glide_started.emit(fighter, target, d)
			_pose_play(fighter, &"glide", Tuning.R7_GLIDE_MAX_TIME, &"")
			_tick_glide(0.0)
			return
	_begin_reach()

## Ragdolling and dead bodies are measured to their nearest bone, which the
## hands reach GRAB_BODY_MARGIN further than a standing capsule.
func _reach_gap(f: Fighter) -> float:
	return GRAB_BODY_MARGIN if _is_lying(f) else 0.0

func _begin_reach() -> void:
	_phase = Phase.REACH
	_t = 0.0
	GameEvents.strike_started.emit(fighter, _target, &"grab", false, 0)
	_update_lunge()
	_pose_play(fighter, &"grab_lunge", Tuning.frames(Tuning.GRAB_FRAMES + GRAB_ACTIVE_FRAMES), &"grab")

## Glide (Round 7: Freeflow targeting): R7_GLIDE_SPEED toward the target until
## GRAB_RANGE x GLIDE_STOP from it (or R7_GLIDE_MAX_TIME), facing it.
func _tick_glide(dt: float) -> void:
	if fighter.is_down() or fighter.is_dead() or is_held():
		_abort(&"interrupted")
		return
	if fighter.combat != null and fighter.combat.is_attacking():
		_abort(&"strike")
		return
	_t += dt
	var tgt := _target
	if tgt == null or not is_instance_valid(tgt) or not _grabbable(tgt):
		fighter.knockback(Vector3.ZERO, Tuning.frames(1))
		_begin_reach()   # the startup still plays; the active frame takes what is there
		return
	var p := _body_point(tgt)
	_reach_dir = _flat(p - fighter.global_position, _reach_dir)
	fighter.snap_facing(_reach_dir)
	var d := _flat_dist(p, fighter.global_position) - _reach_gap(tgt)
	var stop := _reach_len * GLIDE_STOP
	if d <= stop + 0.01 or _t >= Tuning.R7_GLIDE_MAX_TIME:
		fighter.knockback(Vector3.ZERO, Tuning.frames(1))
		_begin_reach()
		return
	var step := maxf(dt, Tuning.frames(0.5))
	var speed := minf(Tuning.R7_GLIDE_SPEED, (d - stop) / step)
	fighter.knockback(_reach_dir * speed, step * 2.0)

## Forced velocity during the startup: a short step in to WALK_LUNGE_GAP.
func _update_lunge() -> void:
	var startup := Tuning.frames(Tuning.GRAB_FRAMES)
	var left := maxf(startup + Tuning.frames(GRAB_ACTIVE_FRAMES) - _t, Tuning.frames(1))
	var v := Vector3.ZERO
	if _target != null and is_instance_valid(_target):
		var p := _body_point(_target)
		_reach_dir = _flat(p - fighter.global_position, _reach_dir)
		fighter.snap_facing(_reach_dir)
		var d := _flat_dist(p, fighter.global_position) - _reach_gap(_target)
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

## The chosen target connects within reach + R7_CONNECT_MARGIN (the chosen
## target is always hit); otherwise the nearest grabbable body in reach.
func _try_catch() -> bool:
	if _target != null and is_instance_valid(_target) and _grabbable(_target) \
			and _reach_distance(_target, true) <= _reach_len + Tuning.R7_CONNECT_MARGIN:
		return _catch(_target, false)
	var best: Fighter = null
	var best_d := INF
	for f in _grabbables():
		var d := _reach_distance(f, false)
		if d <= _reach_len and d < best_d:
			best_d = d
			best = f
	if best == null:
		return false
	return _catch(best, false)

func _whiff() -> void:
	last_grab_result = &"whiff"
	GameEvents.attack_whiff.emit(fighter, &"grab")
	fighter.knockback(Vector3.ZERO, Tuning.frames(4))
	_enter_recover(Tuning.frames(GRAB_WHIFF_FRAMES), true)

## Contact: decide the grab by the victim's state. A live victim whose Defence
## intercepts the grab (teleport, sidestep) makes it a whiff.
func _catch(v: Fighter, skip_clinch: bool) -> bool:
	if not v.is_dead() and _intercepted(v, &"grab"):
		_whiff()
		last_grab_result = &"intercepted"
		return true
	var cls := _class_of(v)
	fighter.knockback(Vector3.ZERO, Tuning.frames(2))
	GameEvents.grab_started.emit(fighter, v)
	if cls == Cls.NEUTRAL and not skip_clinch:
		_begin_clinch(v)
		return true
	if not _begin_hold(v):
		_whiff()
		return true
	TimeDirector.hitstop([fighter, v], Tuning.GRAB_CONNECT_HITSTOP)
	return true

# --- Clinch: a neutral enemy's break window -------------------------------------------
func _begin_clinch(v: Fighter) -> void:
	var now := TimeDirector.now()
	_phase = Phase.CLINCH
	_t = 0.0
	_victim = v
	_bone = Bones.CHEST
	_queued = -1
	_drive_queued = false
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
	_pose_hold(fighter, &"clinch_hold", &"grab_hold")
	last_grab_result = &"clinch"
	GameEvents.carry_changed.emit(fighter, v)
	if early:
		_broken_by(v)
		return
	if not v.is_player and vc != null and v.brain != null:   # brainless dummies never break
		var wants := randf() < AI_GRAB_BREAK_CHANCE
		if v.brain.has_method(&"wants_grab_break"):
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
	fighter.knockback(Vector3.ZERO, Tuning.frames(2))
	if now >= _clinch_until:
		var q := _queued
		var drive := _drive_queued
		_end_socket_hold(false, true)
		if not _begin_hold(v):
			_phase = Phase.IDLE
			return
		TimeDirector.hitstop([fighter, v], Tuning.GRAB_CONNECT_HITSTOP)
		if q >= 0:
			on_attack_pressed(q, _queued_t)
			if _queued_up:
				on_attack_released(q, now)
		if drive and _phase == Phase.HOLD and _victim != null:
			_start_drive()

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
func _begin_hold(v: Fighter) -> bool:
	var bone := Bones.CHEST
	if v.rig == null or v.ragdoll == null or v.rig.get_physical_bone(bone) == null:
		return false
	_victim = v
	_bone = bone
	_phase = Phase.HOLD
	_t = 0.0
	_hold_t = 0.0
	_knees = 0
	_knee_t = -1.0
	_knee_queued = false
	_windup_down = false
	_driving = false
	_drive_queued = false
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
		if _driving:
			_end_drive(&"drop")
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
	if not _move_hand(dt, _hand_socket()):
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
	if _windup_down:
		GameEvents.throw_windup.emit(fighter, get_throw_windup())
	if _driving:
		_hold_t = 0.0   # driving resets the hold clock
		_tick_drive(dt)
		return
	# Struggle-out: a live victim breaks free after R7_HOLD_MAX. A wind-up in
	# progress throws instead (a throw you are winding up is never lost).
	if not v.is_dead() and _hold_t >= Tuning.R7_HOLD_MAX:
		if _windup_down:
			_release_throw(now)
		elif _knee_t < 0.0:
			_struggle_out()

## Where the hand carries the neck: in front (holding), lower and further out
## (driving), swung back toward the right fist as a throw winds up.
func _hand_socket() -> Vector3:
	if _driving:
		return _socket(SOCKET_DRIVE)
	var at := _socket(SOCKET_HOLD)
	var w := get_throw_windup()
	if w <= 0.0:
		return at
	var fist: Node3D = fighter.rig.get_attachment(Bones.R_HAND) if fighter.rig else null
	var back := fist.global_position if fist != null and fist.is_inside_tree() else _socket(SOCKET_WINDUP)
	return at.lerp(back, w)

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
	if _driving:
		_end_drive(&"drop")
	var v := _victim
	_victim = null
	held = null
	_cancel_windup()
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

## A released body (Grab, a hit on the holder, the struggle-out, a shove): a
## live one whose pelvis is upright with its feet near the floor lands on them
## and stumbles; one that is lying keeps falling and gets up; a corpse drops.
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
	info.weight = 0.3
	info.energy = 0.5 * v.get_total_mass() * 2.0
	info.set_meta(&"held_strike", true)  # the holder's own strike: keep the hold
	info.set_meta(&"blood", &"small")    # Feel Reference: knees draw a little blood (F)
	v.take_hit(info)

# --- Throws ---------------------------------------------------------------------------------
## Wind-up 0..1 while LIGHT is held with a body (0 = none).
func get_throw_windup() -> float:
	if not _windup_down:
		return 0.0
	return windup_of(TimeDirector.now() - _windup_t0)

## The throw button came up (or the hold clock ran out mid-wind-up): throw.
func _release_throw(now: float) -> void:
	var w := windup_of(now - _windup_t0)
	_cancel_windup()
	_throw_body(w)

## A wind-up ends (thrown, dropped, hit): throw_windup 0, the pose back to the hold.
func _cancel_windup() -> void:
	if not _windup_down:
		return
	_windup_down = false
	GameEvents.throw_windup.emit(fighter, 0.0)
	_windup_pose(false)

## LIGHT: the baseball throw. Speed by the wind-up, the drive's share added,
## along _throw_dir() pitched up R7_THROW_PITCH.
func _throw_body(windup: float) -> void:
	if _victim == null:
		return
	var speed := throw_speed(windup)
	var dir := _throw_dir()
	if _driving:
		speed += _current_drive_speed() * Tuning.THROW_RUN_SHARE
	speed = minf(speed, Tuning.LAUNCH_SPEED_MAX)
	last_throw_windup = windup
	_launch_held(_pitched(dir, Tuning.R7_THROW_PITCH) * speed, &"drop")

## Lets go of the body flying at `vel` (the existing projectile: thrown).
func _launch_held(vel: Vector3, drive_reason: StringName) -> void:
	var v := _victim
	if _driving:
		_end_drive(drive_reason)
	_end_body_hold()
	last_throw_velocity = vel
	if v != null and is_instance_valid(v):
		if v.is_dead():
			v.ragdoll.add_velocity(vel - v.get_com_velocity())
		else:
			# A preset launch through the victim's pipeline: hit_landed names the
			# thrower (Defence's pursuit window, ImpactResolver's launcher).
			var info := _preset_hit(v, &"throw", HitInfo.Tier.LAUNCH, 0.0, Bones.CHEST, vel)
			info.launch_velocity = vel
			info.hitstop = THROW_HITSTOP
			info.weight = THROW_WEIGHT
			info.hit_position = v.get_center_of_mass()
			info.energy = 0.5 * v.get_total_mass() * vel.length_squared()
			if v.take_hit(info) != HitInfo.Result.HIT and is_instance_valid(v):
				v.launch(vel - v.get_com_velocity(), v.get_center_of_mass(), Bones.CHEST)
		GameEvents.thrown.emit(fighter, v, vel)
	fighter.snap_facing(vel)
	_pose_play(fighter, &"throw_release", THROW_ANIM_TIME, &"throw")
	_enter_recover(Tuning.frames(THROW_RECOVERY_FRAMES))

## Throw direction (flat): throw_aim if set (AI, tests), else camera forward
## for the player (facing for others); the player's aim snaps to the enemy
## nearest it within R7_THROW_ASSIST_CONE.
func _throw_dir() -> Vector3:
	var d := Vector3.ZERO
	if throw_aim.length_squared() > 1e-4:
		d = throw_aim
	elif fighter.is_player:
		d = _camera_forward()
	elif fighter.combat != null and &"throw_aim" in fighter.combat:
		d = fighter.combat.get(&"throw_aim")
	d = _flat(d, fighter.get_forward())
	last_throw_assist = null
	if fighter.is_player:
		var t := _assist_target(d)
		if t != null:
			last_throw_assist = t
			d = _flat(t.get_ground_position() - fighter.get_ground_position(), d)
	return d

## The standing enemy within R7_THROW_ASSIST_CONE of `dir` (smallest angle),
## within THROW_ASSIST_RANGE; null if none. Never the held body.
func _assist_target(dir: Vector3) -> Fighter:
	var origin := fighter.get_ground_position()
	var best: Fighter = null
	var best_a := Tuning.R7_THROW_ASSIST_CONE
	for f in Targeting.opponents_of(fighter):
		if f == _victim or f.is_down() or (f.carry != null and f.carry.is_held()):
			continue
		var to := f.get_ground_position() - origin
		to.y = 0.0
		var dist := to.length()
		if dist < 0.5 or dist > THROW_ASSIST_RANGE:
			continue
		var a := rad_to_deg(dir.angle_to(to / dist))
		if a <= best_a:
			best_a = a
			best = f
	return best

static func _pitched(dir: Vector3, degrees: float) -> Vector3:
	var a := deg_to_rad(degrees)
	return (dir * cos(a) + Vector3.UP * sin(a)).normalized()

## Flat camera forward: the camera rig's yaw, else the viewport camera, else facing.
func _camera_forward() -> Vector3:
	var tree := fighter.get_tree()
	var rig := tree.get_first_node_in_group(&"camera_rig") if tree else null
	if rig != null and rig.has_method(&"get_flat_basis"):
		var b: Basis = rig.call(&"get_flat_basis")
		return _flat(-b.z, fighter.get_forward())
	var vp := fighter.get_viewport()
	var cam := vp.get_camera_3d() if vp else null
	if cam != null:
		return _flat(-cam.global_basis.z, fighter.get_forward())
	return fighter.get_forward()

## The stick in world space (zero when neutral): PlayerController.get_aim_dir().
func _stick() -> Vector3:
	if fighter.brain != null and fighter.brain.has_method(&"get_aim_dir"):
		var d: Vector3 = fighter.brain.call(&"get_aim_dir")
		d.y = 0.0
		return d if d.length() > 0.2 else Vector3.ZERO
	return Vector3.ZERO

# =====================================================================================
# Drive
# =====================================================================================
## Dash pressed while holding a body: start the drive. True when it took the press.
func on_drive_pressed(_now: float) -> bool:
	if _phase == Phase.CLINCH and _victim != null:
		_drive_queued = true
		return true
	if not is_holding_body():
		return false
	if not _driving:
		_start_drive()
	return true

func on_drive_released(_now: float) -> void:
	_drive_queued = false
	if _driving:
		_end_drive(&"release")

func is_driving() -> bool:
	return _driving

func _start_drive() -> void:
	if _driving or not is_holding_body():
		return
	if fighter.traversal == null or not fighter.traversal.begin_drive():
		return   # Traversal refused (down, reacting, held): no drive
	_driving = true
	_drive_t = 0.0
	_hold_t = 0.0
	_drive_done.clear()
	_drive_bowled.clear()
	_knee_t = -1.0
	_knee_queued = false
	if _victim.ragdoll != null:
		_victim.ragdoll.set_ignore_breakables(true)   # the probes judge breakables
	_drive_pose(true)
	GameEvents.drive_started.emit(fighter, _victim)

## reason: &"release" (Dash up, the hold stays) | &"slam" | &"shove" | &"timeout" | &"hit" | &"drop".
func _end_drive(reason: StringName) -> void:
	if not _driving:
		return
	var stop := reason == &"slam" or reason == &"shove"
	if stop:
		_set_drive_speed(0.0)   # stopped dead at what it hit
	_driving = false
	if fighter.traversal != null:
		fighter.traversal.end_drive()
	if _victim != null and is_instance_valid(_victim) and _victim.ragdoll != null:
		_victim.ragdoll.set_ignore_breakables(false)
	_drive_pose(false)
	last_drive_end = reason
	GameEvents.drive_ended.emit(fighter, reason)

func _current_drive_speed() -> float:
	return fighter.traversal.get_drive_speed() if fighter.traversal != null else 0.0

func _current_drive_dir() -> Vector3:
	var d := fighter.traversal.get_drive_dir() if fighter.traversal != null else Vector3.ZERO
	return _flat(d, fighter.get_forward())

func _set_drive_speed(speed: float) -> void:
	if fighter.traversal != null:
		fighter.traversal.set_drive_speed(speed)

func _tick_drive(dt: float) -> void:
	if dt <= 0.0:
		return   # frozen (hitstop): the drive waits
	if fighter.traversal == null or not fighter.traversal.is_driving():
		_end_drive(&"release")   # Traversal stopped the run: the hold stays
		return
	_drive_t += dt
	if _drive_t >= Tuning.R7_DRIVE_MAX_TIME:
		var spd := minf(_current_drive_speed(), Tuning.LAUNCH_SPEED_MAX)
		last_drive_result = &"timeout"
		_launch_held(_pitched(_current_drive_dir(), Tuning.R7_THROW_PITCH) * spd, &"timeout")
		return
	_drive_probe(_current_drive_dir(), _current_drive_speed(), dt)

## The probes ahead of the held body (see the class doc).
func _drive_probe(dir: Vector3, speed: float, dt: float) -> void:
	if speed <= 0.05 or not fighter.is_inside_tree():
		return
	var look := speed * dt * DRIVE_LOOK_TICKS + DRIVE_LOOK_MARGIN * fighter.get_height_scale()
	var decide := speed * dt * DRIVE_DECIDE_TICKS + DRIVE_DECIDE_MARGIN
	_drive_bowl(dir, look)
	if not _driving:
		return
	speed = _current_drive_speed()
	var hit := _drive_cast(dir, look, false)
	var low := _drive_cast(dir, look, true)
	if hit.is_empty() or (not low.is_empty() and float(low["dist"]) < float(hit["dist"])):
		hit = low
	if hit.is_empty() or float(hit["dist"]) > decide:
		return
	_drive_contact(hit, dir, speed)

## First solid ahead of the held body within `look`: the main box (walls,
## pillars, tall clutter) or the low box (breakables only: steps and curbs are
## stepped over). {} if none. Skips debris, loose props that are not breakable,
## bodies, what this drive already broke, and walls met at a glancing angle
## (over DRIVE_GRAZE_ANGLE: the run slides along them), so what lies beyond
## them is still seen. The hit carries "breakable" and "n" (its face normal,
## flat, toward the holder).
func _drive_cast(dir: Vector3, look: float, low: bool) -> Dictionary:
	var h := fighter.get_height_scale()
	var y0 := (DRIVE_LOW_FROM if low else DRIVE_HIGH_FROM) * h
	var y1 := (DRIVE_HIGH_FROM if low else DRIVE_TOP) * h
	var half := Vector3(DRIVE_BODY_HALF.x * h, (y1 - y0) * 0.5, DRIVE_BODY_HALF.y * h)
	var center := fighter.global_position + dir * DRIVE_BODY_AHEAD * h + Vector3.UP * (y0 + y1) * 0.5
	var xf := Transform3D(Basis.looking_at(dir, Vector3.UP), center)
	var exclude: Array[RID] = [fighter.get_rid()]
	for i in DRIVE_PROBE_RETRIES:
		var hit := _cast_box(xf, half, dir * look, Layers.WORLD | Layers.DESTRUCTIBLE, exclude)
		if hit.is_empty():
			return {}
		var col: Object = hit["collider"]
		var b: Node = WorldTags.breakable_of(col) if col != null else null
		var skip := col == null or col is PhysicalBone3D or col is CharacterBody3D
		if not skip and b != null:
			skip = _drive_done.has(b.get_instance_id()) or bool(b.get(&"is_broken"))
		elif not skip:
			skip = low or col is RigidBody3D   # low: steps; rigid: debris and loose props are shoved
		if not skip:
			hit["breakable"] = b
			hit["n"] = _contact_normal(hit, b, dir)
			skip = -dir.dot(hit["n"]) < cos(deg_to_rad(DRIVE_GRAZE_ANGLE))
		if skip:
			exclude.append(hit["rid"])
			continue
		return hit
	return {}

## The face a probe hit (flat, against the drive): the breakable's own face,
## else the face a short ray along the drive meets at the contact point (a box
## already touching a slanted wall reports an unreliable rest normal), else the
## contact normal.
func _contact_normal(hit: Dictionary, b: Node, dir: Vector3) -> Vector3:
	var n: Vector3 = hit["normal"]
	if b != null and b.has_method(&"get_face_normal"):
		n = b.call(&"get_face_normal", fighter.global_position)
	else:
		var pt: Vector3 = hit["point"]
		var q := PhysicsRayQueryParameters3D.create(pt - dir * DRIVE_NORMAL_RAY, pt + dir * DRIVE_NORMAL_RAY,
			Layers.WORLD | Layers.DESTRUCTIBLE, [fighter.get_rid()])
		var r := fighter.get_world_3d().direct_space_state.intersect_ray(q)
		if not r.is_empty() and r["rid"] == hit["rid"]:
			n = r["normal"]
	n.y = 0.0
	n = n.normalized() if n.length_squared() > 1e-6 else -dir
	return -n if n.dot(dir) > 0.0 else n

## Box cast: {} when free, else {collider, rid, point, normal, dist}. Something
## the box already overlaps is a hit at distance 0 (Jolt's cast_motion ignores
## a starting overlap).
func _cast_box(xf: Transform3D, half: Vector3, motion: Vector3, mask: int, exclude: Array[RID]) -> Dictionary:
	var space := fighter.get_world_3d().direct_space_state
	_probe_box.size = half * 2.0
	_probe_q.transform = xf
	_probe_q.motion = Vector3.ZERO
	_probe_q.collision_mask = mask
	_probe_q.exclude = exclude
	_probe_q.margin = 0.0
	var safe := 0.0
	var info := space.get_rest_info(_probe_q)
	if info.is_empty():
		_probe_q.motion = motion
		var r := space.cast_motion(_probe_q)
		if r.size() < 2 or r[1] >= 1.0:
			return {}
		safe = r[0]
		var unsafe: float = r[1]
		_probe_q.transform = xf.translated(motion * unsafe)
		_probe_q.motion = Vector3.ZERO
		_probe_q.margin = 0.01
		info = space.get_rest_info(_probe_q)
		if info.is_empty():
			var hits := space.intersect_shape(_probe_q, 1)
			if hits.is_empty():
				return {}
			info = {"collider_id": hits[0]["collider_id"], "rid": hits[0]["rid"],
				"point": xf.origin + motion * unsafe, "normal": -motion.normalized()}
	return {"collider": instance_from_id(int(info["collider_id"])), "rid": info["rid"],
		"point": info["point"], "normal": info["normal"], "dist": motion.length() * safe}

## The held body meets `hit`: break through, slam or shove.
func _drive_contact(hit: Dictionary, dir: Vector3, speed: float) -> void:
	var b: Node = hit["breakable"]
	var n: Vector3 = hit["n"]
	var vn := speed * -dir.dot(n)
	var pos: Vector3 = hit["point"]
	var target: Node3D = (b if b != null else hit["collider"]) as Node3D
	if b != null:
		var outcome := _drive_breakable(b as Node3D, pos, dir, speed, vn)
		if outcome == &"break" or outcome == &"skip":
			return
	if vn >= Tuning.R7_DRIVE_SLAM_MIN_SPEED:
		_drive_slam(target, pos, n, vn)
	else:
		_drive_shove(target, pos, n, vn)

## A breakable in the way: judged once by E = 1/2 (victim + share x holder) vn^2.
## Returns &"break" (went through), &"skip" (a loose prop that held: shoved
## aside), or the breakable's outcome (&"crack", &"bounce": a slam).
func _drive_breakable(w: Node3D, pos: Vector3, dir: Vector3, speed: float, vn: float) -> StringName:
	var id := w.get_instance_id()
	var fp := _drive_footprint(w, dir)
	if w is Destructible and fp.has_area() and w.has_method(&"footprint_open_fraction") \
			and float(w.call(&"footprint_open_fraction", fp)) >= DRIVE_OPEN_SKIP:
		_drive_done[id] = &"break"
		return &"break"   # already open: walk through the hole
	var mass := _victim.get_total_mass() + Tuning.R7_DRIVE_MASS_SHARE * fighter.get_total_mass()
	var energy := 0.5 * mass * vn * vn
	last_drive_energy = energy
	w.set_meta(&"impact_body", _victim)   # K's furniture_broken.by
	var outcome: StringName = w.call(&"receive_impact", energy, pos, dir * speed, fp)
	if outcome == &"hole":
		outcome = &"break"   # a hole the bodies fit through: as a break
	_drive_done[id] = outcome
	if outcome == &"break":
		_drive_break_through(w, pos, speed, energy)
		return outcome
	if w is RigidBody3D:
		return &"skip"
	return outcome

## Panels: the hole a drive punches, in panel-local XY (both bodies fit).
func _drive_footprint(w: Node3D, dir: Vector3) -> Rect2:
	var d := w as Destructible
	if d == null or d.kind != &"panel":
		return Rect2()
	var h := fighter.get_height_scale()
	var c := fighter.global_position + dir * DRIVE_BODY_AHEAD * h + Vector3.UP * DRIVE_HOLE_HALF.y * h
	var lc := d.global_transform.affine_inverse() * c
	var hw := DRIVE_HOLE_HALF.x * h
	var hh := DRIVE_HOLE_HALF.y * h
	return Rect2(lc.x - hw, lc.y - hh, hw * 2.0, hh * 2.0)

func _drive_break_through(w: Node3D, pos: Vector3, speed: float, energy: float) -> void:
	var keep := sqrt(maxf(1.0 - float(w.get(&"absorption")), 0.0))
	_set_drive_speed(maxf(speed * keep, Tuning.R7_DRIVE_MIN_SPEED))
	_let_chunks_pass(w)
	if w is Pillar or (w is Destructible and (w as Destructible).kind == &"panel"):
		GameEvents.wall_broken_by.emit(_victim, w, energy)
	var v := _victim
	if not v.is_dead():
		var dmg := Tuning.R7_DRIVE_BREAK_DAMAGE * _damage_mult()
		var info := _drive_info(v, &"drive_break", HitInfo.Tier.FLINCH, dmg, _current_drive_dir())
		info.hit_position = pos
		info.energy = energy
		info.weight = clampf(speed / Tuning.R7_DRIVE_MAX_SPEED, 0.2, 1.0) * 0.6
		info.set_meta(&"held_strike", true)   # the holder's own hit: the hold stays
		v.take_hit(info)
	last_drive_result = &"break"
	GameEvents.drive_impact.emit(fighter, v, w, pos, speed, &"break")

## The bodies ignore the pieces of what they just broke (as ImpactResolver does).
func _let_chunks_pass(w: Node3D) -> void:
	var chunks_v: Variant = w.get(&"last_chunks")
	if _victim == null or _victim.rig == null or not (chunks_v is Array):
		return
	var bones: Array = _victim.rig.get_physical_bones()
	for c: Variant in chunks_v:
		var rb := c as RigidBody3D
		if rb == null or not is_instance_valid(rb):
			continue
		for pb: PhysicalBone3D in bones:
			if is_instance_valid(pb):
				rb.add_collision_exception_with(pb)

## A slam: the drive and the hold end, the body is knocked down against `target`.
func _drive_slam(target: Node3D, pos: Vector3, n: Vector3, vn: float) -> void:
	var v := _victim
	var into := -n
	_end_drive(&"slam")
	_end_body_hold()
	_phase = Phase.IDLE
	if v != null and is_instance_valid(v):
		# The run stops at the wall: the body keeps only a little speed into it.
		var cv := v.get_com_velocity()
		v.ragdoll.add_velocity(into * DRIVE_SLAM_INTO - Vector3(cv.x, 0.0, cv.z))
		if v.is_dead():
			v.ragdoll.add_velocity(Vector3.DOWN * 2.0)
			TimeDirector.hitstop([fighter], Tuning.R7_DRIVE_SLAM_HITSTOP)
		else:
			var dmg := (Tuning.R7_DRIVE_SLAM_DAMAGE + Tuning.R7_DRIVE_SLAM_DAMAGE_PER_MS * vn) * _damage_mult()
			var info := _drive_info(v, &"drive_slam", HitInfo.Tier.KNOCKDOWN, dmg, into)
			info.hitstop = Tuning.R7_DRIVE_SLAM_HITSTOP
			info.react = &"knockdown"
			info.weight = clampf(vn / Tuning.R7_DRIVE_MAX_SPEED, 0.3, 1.0)
			info.hit_position = pos
			info.energy = 0.5 * v.get_total_mass() * vn * vn
			var cut := _sever_roll(v, dmg)
			v.take_hit(info)
			if cut != &"" and is_instance_valid(v) and v.is_dead():
				v.sever_limb(cut)
	GameEvents.screen_shake.emit(clampf(vn / Tuning.R7_DRIVE_MAX_SPEED, 0.2, 1.0) * DRIVE_SLAM_TRAUMA)
	last_drive_result = &"slam"
	GameEvents.drive_impact.emit(fighter, v, target, pos, vn, &"slam")
	fighter.knockback(Vector3.ZERO, Tuning.frames(2), true)
	_pose_play(fighter, &"throw_release", THROW_ANIM_TIME, &"throw")
	_enter_recover(Tuning.frames(THROW_RECOVERY_FRAMES), true)

## Too slow for a slam: the body is shoved into it (stagger), the hold ends.
func _drive_shove(target: Node3D, pos: Vector3, n: Vector3, vn: float) -> void:
	var v := _victim
	var into := -n
	_end_drive(&"shove")
	_end_body_hold()
	_phase = Phase.IDLE
	if v != null and is_instance_valid(v):
		_stand_or_drop(v, into, RELEASE_PUSH)
		if not v.is_dead():
			var info := _drive_info(v, &"drive_shove", HitInfo.Tier.STAGGER, 0.0, into)
			info.hit_position = pos
			info.weight = 0.3
			v.take_hit(info)
	last_drive_result = &"shove"
	GameEvents.drive_impact.emit(fighter, v, target, pos, vn, &"shove")
	fighter.knockback(Vector3.ZERO, Tuning.frames(2), true)
	_enter_recover(Tuning.frames(THROW_RECOVERY_FRAMES), true)

## Enemies standing in the box ahead of the held body are bowled (knockdown,
## R7_DRIVE_BOWL_DAMAGE); the drive keeps R7_DRIVE_BOWL_KEEP of its speed each.
func _drive_bowl(dir: Vector3, look: float) -> void:
	var h := fighter.get_height_scale()
	var depth := DRIVE_BODY_HALF.y * h + look * 0.5
	var center := fighter.global_position + dir * (DRIVE_BODY_AHEAD * h + look * 0.5) + Vector3.UP * 0.95 * h
	_probe_box.size = Vector3((DRIVE_BODY_HALF.x + DRIVE_BOWL_WIDEN) * h, 0.8 * h, depth) * 2.0
	_probe_q.transform = Transform3D(Basis.looking_at(dir, Vector3.UP), center)
	_probe_q.motion = Vector3.ZERO
	_probe_q.margin = 0.0
	_probe_q.collision_mask = Layers.CAPSULE
	_probe_q.exclude = [fighter.get_rid(), _victim.get_rid()]
	var hits := fighter.get_world_3d().direct_space_state.intersect_shape(_probe_q, 8)
	for hit: Dictionary in hits:
		var f := hit.get("collider") as Fighter
		if f == null or f == fighter or f == _victim or f.team == fighter.team or f.is_dead() or f.is_down():
			continue
		if f.is_invulnerable() or (f.carry != null and f.carry.is_held()) or _drive_bowled.has(f.get_instance_id()):
			continue
		_drive_bowled[f.get_instance_id()] = true
		var before := _current_drive_speed()
		var side := _flat(f.get_ground_position() - fighter.get_ground_position(), dir)
		var out := _flat(dir + side, dir)   # forward and off the drive's line
		var info := _drive_info(f, &"drive_bowl", HitInfo.Tier.KNOCKDOWN, Tuning.R7_DRIVE_BOWL_DAMAGE * _damage_mult(), out)
		info.kind = &"bowl"
		info.react = &"knockdown"
		info.weight = DRIVE_BOWL_WEIGHT
		info.hitstop = DRIVE_BOWL_HITSTOP
		info.hit_position = f.get_aim_point()
		f.take_hit(info)
		TimeDirector.hitstop([_victim], DRIVE_BOWL_HITSTOP)   # the held body stays in hand
		_set_drive_speed(before * Tuning.R7_DRIVE_BOWL_KEEP)
		last_drive_result = &"bowl"
		GameEvents.drive_impact.emit(fighter, _victim, f, info.hit_position, before, &"bowl")
		if not _driving:
			return

## A drive hit: a preset tier through the victim's pipeline, HitInfo.drive set.
func _drive_info(v: Fighter, move_id: StringName, tier: int, damage: float, dir: Vector3) -> HitInfo:
	var info := _preset_hit(v, move_id, tier, damage, Bones.CHEST, dir)
	info.drive = true
	return info

## A killing slam severs a limb with chance R7_SEVER_ON_KILL: the cut, or &"".
func _sever_roll(v: Fighter, damage: float) -> StringName:
	if v.is_dead() or damage < v.hp or v.rig == null or randf() >= Tuning.R7_SEVER_ON_KILL:
		return &""
	var cuts: Array[StringName] = []
	for c: StringName in [&"arm_l", &"arm_r", &"leg_l", &"leg_r"]:
		if Bones.CUTS.has(c) and not v.rig.is_severed(c):
			cuts.append(c)
	if cuts.is_empty():
		return &""
	var cut: StringName = cuts.pick_random()
	return cut

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

## LIGHT with a prop: thrown at PROP_THROW_SPEED at the aim-assisted enemy's
## chest (camera forward, R7_THROW_ASSIST_CONE), else straight along the aim.
func _throw_prop() -> void:
	var p := _prop
	if p == null:
		return
	var dir := _throw_dir()
	var from := _prop_hand_xform().origin + dir * PROP_RELEASE_AHEAD
	var vel: Vector3
	if last_throw_assist != null:
		vel = _ballistic(from, last_throw_assist.get_aim_point(), PROP_THROW_SPEED)
	else:
		vel = _pitched(dir, Tuning.R7_THROW_PITCH) * PROP_THROW_SPEED
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
	fighter.snap_facing(vel)
	_pose_play(fighter, &"throw_release", THROW_ANIM_TIME * 0.8, &"throw")
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
		toss = dir * 0.5 + Vector3.DOWN * ENEMY_SLAM_DOWN
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
		_drive_queued = false
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
	if fighter.animator:
		var hid := fighter.animator.get_hold_id()
		if hid == &"grab_hold" or hid == &"clinch_hold":
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
			Phase.HOLD, Phase.CLINCH, Phase.ENEMY_HOLD, Phase.GLIDE, Phase.REACH:
				drop(&"hit")   # a hit makes you drop the body (and ends a drive)
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
	if not f.is_dead() and f.is_invulnerable():
		return false
	return true

## Lying, flying or dead: measured by its nearest bone, held from the floor.
func _is_lying(f: Fighter) -> bool:
	return f.is_dead() or (f.ragdoll != null and f.ragdoll.is_full_ragdoll())

func _class_of(f: Fighter) -> int:
	if f.is_dead():
		return Cls.DEAD
	var st := f.get_state()
	if f.ragdoll.is_full_ragdoll() or st == RagdollController.State.LAUNCHED or st == RagdollController.State.GROUNDED:
		return Cls.RAGDOLL
	if f.is_reacting() or st in [RagdollController.State.FLINCH, RagdollController.State.STAGGER, RagdollController.State.GETUP]:
		return Cls.STUNNED
	var c := f.combat
	if c != null and (_call_bool(c, &"is_hit_stunned") or _call_bool(c, &"is_stumbling") or _call_bool(c, &"is_dazed")):
		return Cls.STUNNED
	return Cls.NEUTRAL

## `v`'s Defence takes this fighter's grab (Defence.intercepts: vanished in a
## teleport, sidestepping it, countering).
func _intercepted(v: Fighter, move_id: StringName) -> bool:
	var d := v.defence
	if d == null or not d.has_method(&"intercepts") or (d.has_method(&"is_enabled") and not bool(d.call(&"is_enabled"))):
		return false
	return bool(d.call(&"intercepts", fighter, move_id))

static func _call_bool(o: Object, method: StringName) -> bool:
	return o != null and o.has_method(method) and bool(o.call(method))

## Where a body is for picking and reach: a standing capsule's feet, or a
## ragdoll's nearest bone to our hands.
func _body_point(f: Fighter) -> Vector3:
	if _is_lying(f):
		var b := _nearest_bone(f, Bones.PHYSICAL)
		if b != &"":
			return _bone_pos(f, b)
	return f.get_ground_position()

## The grab's target (Round 7: picked like a strike). Live enemies through
## Targeting.pick_freeflow_target within R7_GRAB_GLIDE; downed and dead bodies
## (never freeflow targets) by the same score from their nearest bone. The
## better score wins (a live pick that scores outside the aim cone still counts).
func _pick_target(reach: float) -> Fighter:
	var max_range := maxf(Tuning.R7_GRAB_GLIDE, reach)
	var stick := _stick()
	var cam := _camera_forward() if fighter.is_player else fighter.get_forward()
	var current: Fighter = fighter.combat.get_combat_target() if fighter.combat != null else null
	var live := Targeting.pick_freeflow_target(fighter, stick, current, cam, max_range)
	if live != null and not _grabbable(live):
		live = null
	var dir := stick if stick.length_squared() > 1e-4 else cam
	var origin := fighter.get_ground_position()
	var best := live
	var best_s := -INF
	if live != null:
		best_s = Targeting.freeflow_score(origin, dir, live.get_ground_position(), max_range)
		if is_inf(best_s):
			best_s = -1.0
	for f in _grabbables():
		if not _is_lying(f) or f == live:
			continue
		var p := _body_point(f)
		if not _bone_height_ok(p):
			continue
		var s := Targeting.freeflow_score(origin, dir, p, max_range + GRAB_BODY_MARGIN)
		if s > best_s:
			best_s = s
			best = f
	return best

## Distance used for the reach test at the active frame. A standing body other
## than the chosen target must be in front (GRAB_CONE_DOT).
func _reach_distance(f: Fighter, chosen: bool) -> float:
	var origin := fighter.global_position
	if _is_lying(f):
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
	if not chosen and d > 0.05 and fighter.get_forward().dot(to / d) < GRAB_CONE_DOT:
		return INF
	return d

func _bone_height_ok(p: Vector3) -> bool:
	var dy := p.y - fighter.global_position.y
	var h := fighter.get_height_scale()
	return dy >= GRAB_BONE_HEIGHT.x * h and dy <= GRAB_BONE_HEIGHT.y * h

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
# Fallback hold: kinematic anchor + pin joint (when RagdollController.begin_held does not take)
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
	if v != null and is_instance_valid(v) and v.ragdoll:
		v.ragdoll.set_gripped(false)

func _pin_free() -> void:
	if _pin_joint.is_valid():
		PhysicsServer3D.free_rid(_pin_joint)
	if _pin_anchor.is_valid():
		PhysicsServer3D.free_rid(_pin_anchor)
	_pin_joint = RID()
	_pin_anchor = RID()

## The grip point (the neck for the chest) in the bone body's frame.
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

## Abort a glide / reach / hold without any effect on the other body beyond letting go.
func _abort(reason: StringName) -> void:
	match _phase:
		Phase.GLIDE, Phase.REACH, Phase.RECOVER:
			_phase = Phase.IDLE
			_target = null
		Phase.HOLD, Phase.CLINCH, Phase.ENEMY_HOLD:
			drop(reason)
	_press_buffer = -INF

func _enter_recover(t: float, still := false) -> void:
	_phase = Phase.RECOVER
	_recover_left = t
	_recover_still = still
	_target = null

static func _is_throw_action(action: int) -> bool:
	return action == CombatController.Action.LIGHT or action == CombatController.Action.HEAVY

static func _is_knee_action(action: int) -> bool:
	return action == CombatController.Action.LEG_KICK or action == CombatController.Action.SWEEP

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

# --- Poses (agent P's Round 7 ids; older fallbacks until they land) -------------------------
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

## An upper-body pose over the running legs: the first of `ids` P has.
func _overlay(ids: Array[StringName]) -> void:
	var a := fighter.animator
	if a == null:
		return
	for id in ids:
		if PoseLibrary.HOLDS.has(id) or PoseLibrary.has_pose(id):
			a.set_upper_overlay(id)
			return

## Holding a body: the carry locomotion and the clinch upper overlay (P).
func _carry_pose(on: bool) -> void:
	var a := fighter.animator
	if a == null:
		return
	if on:
		a.set_locomotion_style(&"carry")
		_overlay([&"clinch_hold", &"carry_hold", &"grab_hold"])
	else:
		a.set_locomotion_style(&"walk")
		a.set_upper_overlay(&"")
		var hid := a.get_hold_id()
		if hid in [&"grab_hold", &"clinch_hold", &"throw_windup", &"throw_charge", &"power_charge", &"drive_hold"]:
			a.release_pose()

## The throw wind-up over the legs (P's throw_windup), or back to the hold.
func _windup_pose(on: bool) -> void:
	if fighter.animator == null or _victim == null:
		return
	if on:
		_overlay([&"throw_windup", &"throw_charge", &"power_charge"])
	elif _driving:
		_drive_pose(true)
	else:
		_overlay([&"clinch_hold", &"carry_hold", &"grab_hold"])

## Driving: P's drive_hold (leaning in, the body ahead) over the running legs.
func _drive_pose(on: bool) -> void:
	if fighter.animator == null or _victim == null:
		return
	if on:
		_overlay([&"drive_hold", &"clinch_hold", &"carry_hold"])
	else:
		_overlay([&"clinch_hold", &"carry_hold", &"grab_hold"])
