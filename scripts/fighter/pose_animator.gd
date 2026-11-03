class_name PoseAnimator
extends Node
## Procedural keyframe animator for the HumanoidRig (no Mixamo clips yet):
## locomotion cycles, one-shot moves stretched to the combat system's frame
## data, timed moves (vault, mantle, landings...), held poses and an
## upper-body overlay. All poses live in PoseLibrary.
## OWNER: agent P (poses & animation). CONTRACT STUB: keep every public signature.
##
## Move ids (play_move / play_timed): every PoseLibrary.MOVES key
##   (PoseLibrary.has_move(id)). Hold ids (hold_pose): PoseLibrary.HOLDS keys
##   or any pose name. Round 5 ids are listed in PoseLibrary (ROUND5_MOVE_IDS,
##   ROUND5_HOLD_IDS); older rounds' ids all still work.
## Strike timing: play_move(id, startup, active, recovery) puts the move's
##   contact keyframe exactly on the first active frame (t = startup), for any
##   startup. Enemy moves build their tell over the whole startup.
## Round 5 contract:
##   play_timed(id, duration): the keyframes stretch to fit exactly `duration`
##     s of this fighter's time; set_move_progress(0..1) scrubs it (drive it
##     from a tween's progress). move_finished fires at the end.
##   set_locomotion_style(&"walk"|&"sprint"|&"carry"|&"limp"|&"crawl"|&"strafe"|
##     &"wall_run_l"|&"wall_run_r"): the cycle; its speed follows set_locomotion().
##   set_upper_overlay(id): an upper-body pose (&"carry_hold", &"guard"...) held
##     over the running legs; &"" clears. The carry style shows carry_hold
##     unless another overlay is set.
## Per-fighter time: the animation advances by the scaled delta x time_scale x
##   the host's get_actor_time() (0 while frozen by hitstop). The player
##   animates on TimeDirector.player_delta() (full speed in any slow motion).
## Upper-body strikes (move "legs": &"free") and charge holds let the legs keep
##   running while the fighter moves faster than LEGS_FREE_FROM; kicks, landings
##   and parkour keep their own legs.
## Round 7 (docs/Round 7 — Freeflow Combat.md "Poses"):
##   play_move(strike, startup, active, recovery) with Tuning.R7_MOVES frames for
##     PoseLibrary.ROUND7_STRIKE_IDS (contact on the first active frame).
##   play_timed(id, d): dodge, glide, throw_release, react_snap / react_spin
##     (react_spin_r: the mirror) / react_push / react_fold / react_buckle /
##     react_lift (d = the stun). The first reaction pose lands within 0.07 s.
##   hold_pose(id): throw_windup (grows to full over R7_THROW_WINDUP_FULL),
##     drive_hold, clinch_hold, glide, counter_catch, heavy_<move>_load for
##     jab / cross / hook / leg_kick / front_kick / roundhouse (a press waiting
##     for the hold decision), react_fold, react_buckle, react_lift. Reaction holds blend in
##     within their "blend_max" (<= 0.07 s) whatever blend is passed.
##     react_lift blends rising -> falling limbs by the rig's own vertical
##     speed (not set_stance's) and flails them, so it reads while the capsule
##     flies, with or without RagdollController.limp_chain on top. Calling
##     hold_pose() again with the same id keeps its clock (no restart).
##   set_upper_overlay(id) also takes throw_windup (growing), drive_hold and
##     clinch_hold over the running legs.
## Round 8 (docs/Round 8 — Charge and Pressure.md):
##   hold_pose(PoseLibrary.charge_load_of(move)) + set_charge_amount(c) every
##     tick: the load deepens smoothly with c (light at 0, full wind-up and a
##     slight tremble at 1). play_move(strike, ...) from a held load skips the
##     strike's own wind-up keys (load -> contact on the first active frame).
##   play_timed: react_flinch (the tap's stun), react_sweep (before the
##     ragdoll), react_broken (R8_BREAK_TIME; also a hold), air_follow (the
##     launcher jump; also a hold); react_fold under 0.45 s is the quick
##     half-keel. play_move(air_jab | air_cross | air_kick, R8_AIR_FRAMES).
##
## Layers, bottom to top: locomotion (legs by IK to procedural foot targets, so
## feet stay planted) -> upper overlay -> held pose -> one-shot move ->
## cross-fade. Bones a pose does not define come from the layer below. Updates
## in _physics_process (process_physics_priority -20, before RagdollController
## at -10 and the Fighter at 0), so bone positions are current for hit
## detection in the same tick. When a RagdollController is set up it writes
## the skeleton; otherwise this node writes it (drive_skeleton).

signal move_finished(move_id: StringName)

## 0 freezes the animation (local hitstop). Multiplies the scaled delta.
var time_scale := 1.0
var rig: HumanoidRig

## Current output (height scale 1.0): local rotation of each Bones.ALL bone
## and the hips offset from its rest position.
var pose_rot: Array[Quaternion] = []
var hips_offset := Vector3.ZERO
## Write the pose to the skeleton every tick (RagdollController turns this off).
var drive_skeleton := true
## Set by RagdollController while it owns the body (ragdoll, get-up): public
## play_move/play_timed/hold_pose/release_pose/cancel are ignored.
var locked := false
## Playback rate multiplier for looping holds (the falling loop).
var loop_speed := 1.0
## Charge level 0..3 of a held &"<move>_charge" pose (set_charge_level).
var charge_level := 0
## Animation delta of the last tick (after player time, time_scale and actor time).
var last_dt := 0.0

const LOCO_SMOOTH := 12.0
const CHARGE_TREMBLE_BASE := 0.6       ## deg of tremble at charge level 0
const CHARGE_TREMBLE_PER_LEVEL := 1.4  ## deg added per charge level
const CHARGE_SINK_PER_LEVEL := 0.025   ## m the hips sink per charge level
const CROUCH_WALK_STRIDE := 0.7        ## crouch-walk stride (x standing)
const HANG_SPRING := 30.0              ## broken-arm pendulum (1/s^2)
const HANG_DAMP := 4.0                 ## broken-arm pendulum damping (1/s)
const HANG_ACCEL := 0.025              ## lag per m/s^2 of shoulder acceleration
const HIPS_I := 0
const LEG_START := 10   # LeftUpperLeg; legs are indices 10..15

# --- Round 5 tuning (local; agent P) -------------------------------------------
## s to cross-fade between locomotion styles, and to blend an overlay in/out.
const STYLE_BLEND := 0.18
const OVERLAY_BLEND := 0.15
## m/s: a "legs free" move or a charge hold hands the legs back to the
## locomotion from LEGS_FREE_FROM, fully by LEGS_FREE_FULL (charging while
## walking or sprinting keeps the feet running, Feel Reference "Charging").
const LEGS_FREE_FROM := 1.2
const LEGS_FREE_FULL := 3.0
## Sprint cycle. Step length grows with speed (Prototype's long stride):
## 1.6 m at 6 m/s, 2.0 m at the 8 m/s cap, 2.9 m at 12 m/s, ~4 steps/s.
const SPRINT_FROM := 3.6        ## m/s: the sprint cycle blends in from the run...
const SPRINT_FULL := 5.8        ## ...complete here
const SPRINT_STEP_BASE := 1.2   ## m per step at 4.5 m/s...
const SPRINT_STEP_PER_MS := 0.22 ## ...plus this per m/s above it
const SPRINT_CONTACT_TIME := 0.115 ## s a foot is on the ground per step
const SPRINT_HALF_WIDTH := 0.085 ## m: sprinting feet land near the midline
const SPRINT_LEAN := 10.0       ## deg hips + spine lean forward at full speed (each)
const SPRINT_ARM_SWING := 52.0  ## deg shoulder pump each way
## Wall run: the foot plants this far to the wall side (m, capsule radius 0.3)
## and this high; the body rolls away from the wall by WALLRUN_ROLL degrees.
const WALLRUN_FOOT_X := 0.4
const WALLRUN_FOOT_Y := 0.32
const WALLRUN_ROLL := 24.0
## Circle-strafe (step-close, feet never cross): stride and extra stance width.
const STRAFE_STRIDE := Vector2(0.5, 0.6)  ## m at low / high speed
const STRAFE_WIDEN := 0.06
## Limp: shorter, uneven steps (x walk stride), lurch amount.
const LIMP_STRIDE := 0.6
const LIMP_LURCH := 0.45
## Crawl (lost a leg): arm-pull cycle length (m of travel per arm cycle).
const CRAWL_CYCLE := 0.9
## Stumble steps (moves with "steps"): lift and minimum stride (m).
const STUMBLE_LIFT := 0.11
## Share of a cycle each foot is planted: walking, running (4.5 m/s).
const WALK_DUTY := Vector2(0.62, 0.42)

# --- Round 7 tuning (local; agent P) -------------------------------------------
## s: shortest cross-fade when a hold replaces a move or another hold.
const HOLD_XFADE_MIN := 0.04
## "by_vy" holds (react_lift): vertical speed (m/s, rig motion) at which the
## rising pose is full, and the falling pose full; smoothing rate (1/s).
const LIFT_VY_RISE := 2.0
const LIFT_VY_FALL := -3.0
const LIFT_VY_SMOOTH := 10.0
## Round 8 charge loads ("by_charge" holds): the share of the full wind-up
## shown at c = 0, the spring (1/s; critically damped, ~0.2 s to settle) the
## pose follows c with, and the tremble below full ("tremble" x FLOOR, rising
## to the full "tremble" from c = FROM to 1).
const LOAD_LIGHT_W := 0.45
const LOAD_SPRING := 22.0
const LOAD_TREMBLE_FLOOR := 0.15
const LOAD_TREMBLE_FROM := 0.7
## A strike played while its load is held at least this much skips its own
## wind-up keys (the load is the wind-up).
const LOAD_SKIP_STARTUP_W := 0.5
## "flail" holds: wobble frequencies (rad/s) of the loose limbs; arms swing
## FLAIL_ARM_MULT x the hold's amplitude, hinges FLAIL_HINGE_MULT x.
const FLAIL_FREQ := Vector2(13.0, 17.0)
const FLAIL_ARM_MULT := 1.4
const FLAIL_HINGE_MULT := 1.6
const FLAIL_BONES: Array[int] = [4, 5, 7, 8, 10, 11, 13, 14]

const STYLES: Array[StringName] = [&"walk", &"sprint", &"carry", &"limp", &"crawl", &"strafe",
	&"wall_run_l", &"wall_run_r"]
## The &"walk" style picks for itself: the host's Traversal wall run (its
## side), the sprint cycle from AUTO_SPRINT_FROM m/s (back under it minus
## 0.5), and step-close strafing for slow sideways moves (lateral share over
## AUTO_STRAFE_LAT, under AUTO_STRAFE_MAX m/s). An explicit style always wins.
const AUTO_SPRINT_FROM := 5.0
const AUTO_STRAFE_LAT := 0.75
const AUTO_STRAFE_MAX := 2.6

## One locomotion evaluation (feet, hips and upper body).
class Loco:
	var feet: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	var pitch: Array[float] = [0.0, 0.0]
	var poles: Array[Vector3] = [Vector3(-0.12, 0, -1), Vector3(0.12, 0, -1)]
	var yaw := 0.0
	var pos := Vector3.ZERO
	var rot: Array[Quaternion] = []
	func _init() -> void:
		rot.resize(10)
		for i in 10:
			rot[i] = Quaternion.IDENTITY

var _time := 0.0
# Locomotion
var _loco_target := Vector3.ZERO
var _loco_vel := Vector3.ZERO
var _max_speed := 4.5
var _phase := 0.0
var _foot_targets: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _foot_pitch: Array[float] = [0.0, 0.0]
var _foot_poles: Array[Vector3] = [Vector3(-0.12, 0, -1), Vector3(0.12, 0, -1)]
var _base_yaw := 0.0
var _stance_feet: Array[Vector3] = []
var _stance: PoseLibrary.Pose
# Styles and overlay (Round 5)
var _style: StringName = &"walk"
var _eff_style: StringName = &"walk"
var _style_prev: StringName = &"walk"
var _style_k := 1.0
var _lo_a := Loco.new()
var _lo_b := Loco.new()
var _overlay_id: StringName = &""
var _overlay_pose: PoseLibrary.Pose
var _overlay_w := 0.0
var _guard: PoseLibrary.Pose
var _carry: PoseLibrary.Pose
var _limp: PoseLibrary.Pose
var _limp_m: PoseLibrary.Pose
# Stance (Upgrade 2)
const STANCE_BLEND := 0.12     ## s to blend stand <-> crouch <-> air
var _stance_id: StringName = &"stand"
var _crouch_w := 0.0
var _air_w := 0.0
var _vy_ext := NAN
var _vy := 0.0
var _last_rig_y := NAN
var _crouch: PoseLibrary.Pose
var _crouch_feet: Array[Vector3] = []
var _jump_rise: PoseLibrary.Pose
var _jump_fall: PoseLibrary.Pose
var _rise_feet: Array[Vector3] = []
var _fall_feet: Array[Vector3] = []
var _rise_pitch: Array[float] = [0.0, 0.0]
var _fall_pitch: Array[float] = [0.0, 0.0]
# Broken arms (Upgrade 2)
var _broken := [false, false]
var _hang_lag := [Vector3.ZERO, Vector3.ZERO]
var _hang_vel := [Vector3.ZERO, Vector3.ZERO]
var _last_shoulder := [Vector3.INF, Vector3.INF]
var _last_shoulder_v := [Vector3.ZERO, Vector3.ZERO]
# Focus: the host fighter (player check) and TimeDirector
var _host: Node
var _td: Node
# Hold layer
var _hold_id: StringName = &""
var _hold_def: Dictionary = {}
var _hold_w := 0.0
var _hold_w_target := 0.0
var _hold_blend := 0.08
var _hold_t := 0.0
var _vy_k := 0.0              # "by_vy" holds: 0 rising .. 1 falling (smoothed)
# Round 8 charge loads: set_charge_amount's target, the spring's value and speed.
var _charge_target := 0.0
var _charge_k := 0.0
var _charge_v := 0.0
var _overlay_t := 0.0         # s since the overlay was set ("ramp" holds as overlays)
# Move layer
var _move_id: StringName = &""
var _move_t := 0.0
var _move_end := 0.0
var _keys: Array = []          # each: [time, kind(0 pose,1 snapshot,2 base), Pose, ease, weight, aimed Pose, pose name]
var _move_startup := 0.0
var _move_mirror := false
var _move_legs_free := false
var _move_steps := 0
var _move_step_dir := Vector3.ZERO
var _strike_pose: StringName = &""   # pose name of the first active key (aim reference)
# Aim (strike IK toward a target)
const AIM_MAX_YAW := deg_to_rad(25.0)
const AIM_MAX_HEIGHT := 0.3
var _aim_on := false
var _aim_world := Vector3.ZERO
var _aim_local := Vector3.INF
var _aim_w := 0.0
var _aim_cache := {}
var _snap_rot: Array[Quaternion] = []
var _snap_pos := Vector3.ZERO
# Cross-fade (cancel, hold switches)
var _xfade_t := 1.0
var _xfade_dur := 0.0
var _xfade_rot: Array[Quaternion] = []
var _xfade_pos := Vector3.ZERO
# Scratch
var _layer_rot: Array[Quaternion] = []
var _layer_pos := Vector3.ZERO

func _init() -> void:
	pose_rot.resize(HumanoidRig.BONE_COUNT)
	_layer_rot.resize(HumanoidRig.BONE_COUNT)
	_snap_rot.resize(HumanoidRig.BONE_COUNT)
	_xfade_rot.resize(HumanoidRig.BONE_COUNT)
	for i in HumanoidRig.BONE_COUNT:
		pose_rot[i] = Quaternion.IDENTITY
		_layer_rot[i] = Quaternion.IDENTITY
	process_physics_priority = -20

func setup(p_rig: HumanoidRig) -> void:
	rig = p_rig
	PoseLibrary.warm()
	_stance = PoseLibrary.get_pose(&"stance")
	var sd: Dictionary = PoseLibrary.POSES[&"stance"]
	_stance_feet = [sd["lankle"] as Vector3, sd["rankle"] as Vector3]
	_crouch = PoseLibrary.get_pose(&"crouch")
	var cd: Dictionary = PoseLibrary.POSES[&"crouch"]
	_crouch_feet = [cd["lankle"] as Vector3, cd["rankle"] as Vector3]
	_jump_rise = PoseLibrary.get_pose(&"jump_rise")
	_jump_fall = PoseLibrary.get_pose(&"jump_fall")
	var jr: Dictionary = PoseLibrary.POSES[&"jump_rise"]
	var jf: Dictionary = PoseLibrary.POSES[&"jump_fall"]
	_rise_feet = [jr["lankle"] as Vector3, jr["rankle"] as Vector3]
	_fall_feet = [jf["lankle"] as Vector3, jf["rankle"] as Vector3]
	_rise_pitch = [deg_to_rad(float(jr.get("lfp", 0.0))), deg_to_rad(float(jr.get("rfp", 0.0)))]
	_fall_pitch = [deg_to_rad(float(jf.get("lfp", 0.0))), deg_to_rad(float(jf.get("rfp", 0.0)))]
	_guard = PoseLibrary.get_pose(&"guard")
	_carry = PoseLibrary.get_pose(&"carry_hold")
	_limp = PoseLibrary.get_pose(&"limp_hunch")
	_limp_m = PoseLibrary.get_pose(&"limp_hunch#m")
	_host = get_parent()
	_td = get_node_or_null(^"/root/TimeDirector") if is_inside_tree() else null
	_evaluate(0.0)
	if drive_skeleton and rig and rig.skeleton:
		_write_skeleton()

func _physics_process(delta: float) -> void:
	if rig == null or _stance == null:
		return
	var dt := _anim_delta(delta) * time_scale * _actor_time()
	last_dt = dt
	_track_vertical(delta)
	if dt > 0.0:
		_evaluate(dt)
	if drive_skeleton and rig.skeleton:
		_write_skeleton()

## Focus / slow motion: the player animates on player time
## (TimeDirector.player_delta), everyone else on the scaled physics delta.
func _anim_delta(delta: float) -> float:
	if _host == null:
		_host = get_parent()
	if _host and _host.is_in_group(&"player"):
		if _td == null:
			_td = get_node_or_null(^"/root/TimeDirector")
		if _td and _td.has_method(&"player_delta"):
			return _td.player_delta(delta)
	return delta

## The host fighter's own time (Fighter.get_actor_time(): 0 while frozen by
## hitstop). Hosts without it (lab dummies) count as 1.
func _actor_time() -> float:
	if _host and _host.has_method(&"get_actor_time"):
		return maxf(float(_host.get_actor_time()), 0.0)
	return 1.0

## Vertical speed of the rig for the air stance (world, m/s).
func _track_vertical(delta: float) -> void:
	if not rig.is_inside_tree() or delta <= 0.0:
		return
	var y := rig.global_position.y
	if not is_nan(_last_rig_y):
		var v := (y - _last_rig_y) / delta
		_vy = lerpf(_vy, v, 0.5)
	_last_rig_y = y

func _write_skeleton() -> void:
	rig.apply_pose(pose_rot, rig.get_rest_hips_position() + hips_offset * rig.height_scale)

# --- Public API ----------------------------------------------------------------
## local_velocity: capsule velocity in the character's local frame (-Z forward).
func set_locomotion(local_velocity: Vector3, max_speed: float) -> void:
	_loco_target = Vector3(local_velocity.x, 0.0, local_velocity.z)
	_max_speed = maxf(max_speed, 0.1)

## One-shot move. The pose reaches its windup at `startup`, holds the strike
## pose for `active`, and returns to locomotion over `recovery` (game seconds).
## The contact keyframe is exactly at t = startup (the first active frame).
## For enemy moves `startup` includes the tell: the windup builds over the
## whole tell (60% -> 100%), freezes for ~2 frames, then snaps to the strike.
func play_move(move_id: StringName, startup: float, active: float, recovery: float) -> void:
	if locked:
		return
	_play(move_id, startup, active, recovery)

## Play `pose_id` over exactly `duration` s of the fighter's time (vault,
## mantle, wall kick-off, landings, throws, parry...). The keyframes stretch to
## fit: a move uses its "timed" split of startup / active / recovery (default
## PoseLibrary.TIMED_SPLIT); a hold or pose id blends in, holds and returns.
func play_timed(pose_id: StringName, duration: float) -> void:
	if locked:
		return
	_play_timed(pose_id, duration)

## Scrub the current move to `progress` (0..1 of its length), e.g. from a
## vault tween's progress so the pose matches the capsule exactly.
func set_move_progress(progress: float) -> void:
	if _move_id == &"":
		return
	_move_t = clampf(progress, 0.0, 1.0) * _move_end

## 0..1 through the current move (-1 when none plays).
func get_move_progress() -> float:
	return clampf(_move_t / _move_end, 0.0, 1.0) if _move_id != &"" and _move_end > 0.0 else -1.0

## Locomotion cycle: &"walk" | &"sprint" | &"carry" | &"limp" | &"crawl" |
## &"strafe" | &"wall_run_l" | &"wall_run_r". The cycle speed follows
## set_locomotion(). Switching cross-fades over STYLE_BLEND.
func set_locomotion_style(style: StringName) -> void:
	if not STYLES.has(style):
		push_warning("PoseAnimator: unknown locomotion style %s" % style)
		return
	_style = style

## The style set by set_locomotion_style().
func get_locomotion_style() -> StringName:
	return _style

## The cycle actually playing (the walk style's own sprint / strafe / wall run).
func get_effective_style() -> StringName:
	return _eff_style

func _auto_style(speed: float, dir: Vector3) -> StringName:
	if _style != &"walk":
		return _style
	if _stance_id == &"crouch" or _crouch_w > 0.5:
		return &"walk"
	var tr = _host.get(&"traversal") if _host else null
	if tr != null and tr.has_method(&"is_wall_running") and tr.call(&"is_wall_running"):
		return &"wall_run_l" if int(tr.call(&"get_wall_side")) < 0 else &"wall_run_r"
	if speed >= AUTO_SPRINT_FROM or (_eff_style == &"sprint" and speed >= AUTO_SPRINT_FROM - 0.5):
		return &"sprint"
	var lat := absf(dir.x) if speed > 0.05 else 0.0
	if speed > 0.2 and speed < AUTO_STRAFE_MAX and (lat > AUTO_STRAFE_LAT or (_eff_style == &"strafe" and lat > 0.5)):
		return &"strafe"
	return &"walk"

## Upper-body pose held over the running legs (&"carry_hold", &"guard"...). &"" clears.
func set_upper_overlay(pose_id: StringName) -> void:
	if pose_id == _overlay_id:
		return
	if pose_id == &"":
		_overlay_id = &""
		return
	var pname := pose_id
	if PoseLibrary.HOLDS.has(pose_id):
		pname = (PoseLibrary.HOLDS[pose_id]["poses"] as Array)[0]
	if not PoseLibrary.POSES.has(pname):
		push_warning("PoseAnimator: unknown overlay %s" % pose_id)
		return
	if _overlay_id == &"":
		_overlay_w = 0.0
	elif _overlay_w > 0.0:
		_start_xfade(OVERLAY_BLEND)
	_overlay_id = pose_id
	_overlay_pose = PoseLibrary.get_pose(pname)
	_overlay_t = 0.0

func get_upper_overlay() -> StringName:
	return _overlay_id

## Upgrade 2 contract: locomotion stance, set by the Fighter every tick.
## &"stand" | &"crouch" | &"air". Crouch lowers the body to about
## Tuning.CROUCH_HEIGHT (crouch-walk when moving; a held &"block" becomes
## &"block_crouch"). Air blends jump_rise -> jump_fall by vertical speed:
## pass `vertical_velocity` (m/s, + up) or leave it out and the rig's own
## vertical motion is used. Landing is a short &"land" play_move.
func set_stance(stance: StringName, vertical_velocity: float = NAN) -> void:
	_stance_id = stance
	_vy_ext = vertical_velocity

func get_stance() -> StringName:
	return _stance_id

## Charge level 0..3 for a held &"<move>_charge" pose: the tremble grows, the
## torso coils further into the wind-up and the body sinks a little. Reset to
## 0 whenever a new hold starts.
func set_charge_level(level: int) -> void:
	charge_level = clampi(level, 0, 3)

## Broken arm (side 0 = left, 1 = right): the arm hangs from the shoulder and
## swings with the body's motion, overriding every move and hold. Set by
## RagdollController.break_arm(); lasts until heal_arms().
func set_arm_broken(side: int, broken := true) -> void:
	if side >= 0 and side < 2:
		_broken[side] = broken
		_hang_lag[side] = Vector3.ZERO
		_hang_vel[side] = Vector3.ZERO

func heal_arms() -> void:
	_broken = [false, false]

func is_arm_broken(side: int) -> bool:
	return side >= 0 and side < 2 and _broken[side]

## Hold a pose until release_pose() or another play_move().
func hold_pose(pose_id: StringName, blend_time := 0.08) -> void:
	if locked:
		return
	_hold(pose_id, blend_time)

func release_pose(blend_time := 0.12) -> void:
	if locked:
		return
	_release(blend_time)

## Stop any move/held pose immediately (got hit).
func cancel() -> void:
	if locked:
		return
	_cancel(0.06)

func is_busy() -> bool:
	return _move_id != &"" or _hold_id != &""

## Aim the current and following strikes at a world point: the strike limb's
## IK targets (PoseLibrary.STRIKE_BONES) turn toward it by up to AIM_MAX_YAW
## and move up/down by up to AIM_MAX_HEIGHT, the chest turns a little with
## them; blends in over the move's startup. Stays until clear_aim_target().
## Cheap to call every tick (rebuilds only when the target moves > 5 cm).
## Moves in PoseLibrary.NO_AIM (leg_sweep, throw) ignore it; moves in
## PoseLibrary.AIM_YAW_ONLY (gut punch, leg kick, kicks, uppercut) only turn.
func set_aim_target(world_pos: Vector3) -> void:
	_aim_world = world_pos
	_aim_on = true
	_refresh_aim(false)

func clear_aim_target() -> void:
	_aim_on = false
	_aim_w = 0.0
	for key in _keys:
		key[5] = null

func has_aim_target() -> bool:
	return _aim_on

## Current animated target rotation of `bone` relative to its rest (for muscles).
func get_target_rotation(bone: StringName) -> Quaternion:
	var i := HumanoidRig.bone_index(bone)
	return pose_rot[i] if i >= 0 else Quaternion.IDENTITY

func get_current_move() -> StringName:
	return _move_id

## Seconds into the current move (game time), or -1.
func get_move_time() -> float:
	return _move_t if _move_id != &"" else -1.0

## Length of the current move (s), or 0.
func get_move_length() -> float:
	return _move_end if _move_id != &"" else 0.0

func get_hold_id() -> StringName:
	return _hold_id

## Smoothed locomotion speed (m/s).
func get_locomotion_speed() -> float:
	return Vector2(_loco_vel.x, _loco_vel.z).length()

## Cycle phase of the locomotion (radians, 0 = left foot mid-swing).
func get_locomotion_phase() -> float:
	return _phase

# --- Internal API (RagdollController) ----------------------------------------
func _play(move_id: StringName, startup: float, active: float, recovery: float, def_override: Dictionary = {}) -> void:
	var def: Dictionary = def_override
	if def.is_empty():
		if not PoseLibrary.MOVES.has(move_id):
			push_warning("PoseAnimator: unknown move %s" % move_id)
			return
		def = PoseLibrary.MOVES[move_id]
	startup = maxf(startup, 0.0)
	active = maxf(active, 0.0)
	recovery = maxf(recovery, 0.0)
	_snap_rot = pose_rot.duplicate()
	_snap_pos = hips_offset
	# Round 8: a strike released from a held charge load goes straight from
	# the load to its contact key (its own wind-up would un-load it first).
	var from_load := _hold_id != &"" and bool(_hold_def.get("by_charge", false)) \
			and _hold_w >= LOAD_SKIP_STARTUP_W and PoseLibrary.STRIKE_BONES.has(move_id)
	var load_pose: StringName = (_hold_def["poses"] as Array)[0] if from_load else &""
	if not def.get("keep_hold", false) and move_id != &"block_hit":
		_hold_id = &""
		_hold_w = 0.0
		_hold_w_target = 0.0
	var mirror := false
	if def.get("mirror_by_motion", false):
		mirror = _loco_target.x > 0.3
	_move_mirror = mirror
	_move_startup = startup
	_move_legs_free = def.get("legs", &"") == &"free"
	_move_steps = int(def.get("steps", 0))
	_move_step_dir = def.get("step_dir", Vector3.ZERO)
	if mirror:
		_move_step_dir.x = -_move_step_dir.x
	_strike_pose = &""
	var seg_start := [0.0, startup, startup + active]
	var seg_dur := [startup, active, recovery]
	_keys.clear()
	var key_defs: Array = def["keys"]
	if from_load:
		# Drop the wind-up keys up to the last one on the load's own pose (a
		# kick keeps its chamber after it); with no such key, all of them.
		var last := -1
		for j in key_defs.size():
			if int(key_defs[j][0]) == 0 and key_defs[j][2] == load_pose:
				last = j
		var kept: Array = []
		for j in key_defs.size():
			if int(key_defs[j][0]) != 0 or (last >= 0 and j > last):
				kept.append(key_defs[j])
		if not kept.is_empty():
			key_defs = kept
	var first: Array = key_defs[0]
	if not (int(first[0]) == 0 and typeof(first[1]) == TYPE_FLOAT and float(first[1]) == 0.0):
		_keys.append([0.0, 1, null, &"linear", 1.0, null, &""])
	var prev_t := -1.0
	for kd in key_defs:
		var seg := int(kd[0])
		var spec = kd[1]
		var t := 0.0
		var s0: float = seg_start[seg]
		var d: float = seg_dur[seg]
		if spec is Vector2:
			var v: Vector2 = spec
			if v.x >= 0.0:
				t = s0 + minf(v.x * d, v.y)
			else:
				t = s0 + d - minf(-v.x * d, v.y)
		else:
			t = s0 + float(spec) * d
		t = maxf(t, prev_t + 0.0005)
		prev_t = t
		var pname: StringName = kd[2]
		if mirror:
			pname = StringName(String(pname) + "#m")
		var ez: StringName = kd[3] if kd.size() > 3 else &"smooth"
		var kw: float = float(kd[4]) if kd.size() > 4 else 1.0
		_keys.append([t, 0, PoseLibrary.get_pose(pname), ez, kw, null, kd[2]])
		if seg == 1 and _strike_pose == &"":
			_strike_pose = kd[2]
	var total := startup + active + recovery
	_move_end = maxf(total, prev_t + 0.0005)
	_keys.append([_move_end, 2, null, &"smooth", 1.0, null, &""])
	_move_id = move_id
	_move_t = 0.0
	_xfade_t = 1.0
	_xfade_dur = 0.0
	_aim_local = Vector3.INF
	_aim_w = 0.0
	if _aim_on:
		_refresh_aim(true)

## play_timed without the `locked` check (RagdollController: fast get-up, stumbles).
func _play_timed(pose_id: StringName, duration: float) -> void:
	duration = maxf(duration, 0.0)
	if PoseLibrary.MOVES.has(pose_id):
		var def: Dictionary = PoseLibrary.MOVES[pose_id]
		# Round 8: a short play of a move with a "quick" variant plays the
		# variant's keys under the same id (react_fold -> the half-keel).
		var quick: Array = def.get("quick", [])
		if not quick.is_empty() and duration < float(quick[0]) and PoseLibrary.MOVES.has(quick[1]):
			def = PoseLibrary.MOVES[quick[1]]
		var sp: Vector3 = def.get("timed", PoseLibrary.TIMED_SPLIT)
		var sum := maxf(sp.x + sp.y + sp.z, 0.0001)
		var st := duration * sp.x / sum
		var ac := duration * sp.y / sum
		_play(pose_id, st, ac, maxf(duration - st - ac, 0.0), def)
		return
	var pname := pose_id
	if PoseLibrary.HOLDS.has(pose_id):
		pname = (PoseLibrary.HOLDS[pose_id]["poses"] as Array)[0]
	if not PoseLibrary.POSES.has(pname):
		push_warning("PoseAnimator: unknown timed pose %s" % pose_id)
		return
	# A plain pose: in over the first quarter, held, back over the last quarter.
	var def2 := {"keys": [[0, 1.0, pname, &"snap"], [1, 1.0, pname]]}
	_play(pose_id, duration * 0.25, duration * 0.5, duration * 0.25, def2)

func _hold(pose_id: StringName, blend_time: float) -> void:
	var def: Dictionary
	if PoseLibrary.HOLDS.has(pose_id):
		def = PoseLibrary.HOLDS[pose_id]
	elif PoseLibrary.POSES.has(pose_id):
		def = {"poses": [pose_id]}
	else:
		push_warning("PoseAnimator: unknown hold %s" % pose_id)
		return
	# Round 7: reaction holds land with the hit whatever blend the caller asks.
	if def.has("blend_max"):
		blend_time = minf(blend_time, float(def["blend_max"]))
	# A new hold (or one coming back from a release) starts its clock; calling
	# hold_pose() again with the same id keeps a ramp or loop where it is.
	var fresh := _hold_id != pose_id or _hold_w_target <= 0.0
	if _move_id != &"" or (_hold_id != &"" and _hold_id != pose_id):
		_start_xfade(maxf(blend_time, HOLD_XFADE_MIN))
		_end_move()
		_hold_w = 1.0
	elif _hold_id != pose_id:
		_hold_w = 0.0
	if _hold_id != pose_id:
		charge_level = 0
	_hold_id = pose_id
	_hold_def = def
	_hold_w_target = 1.0
	_hold_blend = maxf(blend_time, 0.0)
	if fresh:
		_hold_t = 0.0
		_vy_k = 0.0
		if def.get("by_charge", false):
			# A new charge starts light (set_charge_amount moves it on).
			_charge_target = 0.0
			_charge_k = 0.0
			_charge_v = 0.0
	if _hold_blend <= 0.0:
		_hold_w = 1.0

func _release(blend_time: float) -> void:
	if _hold_id == &"":
		return
	_hold_w_target = 0.0
	_hold_blend = maxf(blend_time, 0.0)
	if _hold_blend <= 0.0:
		_hold_w = 0.0
		_hold_id = &""

func _cancel(blend_time: float) -> void:
	if _move_id == &"" and _hold_id == &"":
		return
	_start_xfade(blend_time)
	_end_move()
	_hold_id = &""
	_hold_w = 0.0
	_hold_w_target = 0.0

func _end_move() -> void:
	_move_id = &""
	_move_steps = 0
	_move_legs_free = false

## Snap straight to the base layer with no blending (teleports, resets).
func reset_pose() -> void:
	_end_move()
	_hold_id = &""
	_hold_w = 0.0
	_hold_w_target = 0.0
	_xfade_t = 1.0
	_xfade_dur = 0.0
	_evaluate(0.0)

func _start_xfade(dur: float) -> void:
	_xfade_rot = pose_rot.duplicate()
	_xfade_pos = hips_offset
	_xfade_t = 0.0
	_xfade_dur = dur

# --- Evaluation ----------------------------------------------------------------
static func _ease(f: float, ez: StringName) -> float:
	f = clampf(f, 0.0, 1.0)
	match ez:
		&"snap":
			return 1.0 - pow(1.0 - f, 3.0)
		&"linear":
			return f
		&"accel":
			return f * f
		_:
			return f * f * (3.0 - 2.0 * f)

## 0 standing .. 1 moving fast enough that free legs keep running.
func _legs_free_k() -> float:
	var sp := Vector2(_loco_target.x, _loco_target.z).length()
	return smoothstep(LEGS_FREE_FROM, LEGS_FREE_FULL, sp)

func _evaluate(dt: float) -> void:
	_time += dt
	_update_locomotion(dt)
	var legs_held: Array[bool] = [false, false]
	var hold_pose_now: PoseLibrary.Pose = null
	var charge_amp := 0.0
	var hold_leg_w := 0.0
	# Round 8 charge amount: a critically damped spring toward the target.
	if dt > 0.0:
		var acc := LOAD_SPRING * LOAD_SPRING * (_charge_target - _charge_k) - 2.0 * LOAD_SPRING * _charge_v
		_charge_v += acc * dt
		_charge_k += _charge_v * dt
	# Hold layer.
	if _hold_id != &"":
		_hold_t += dt * loop_speed
		if _hold_def.get("by_vy", false):
			var vk := clampf((LIFT_VY_RISE - _vy) / (LIFT_VY_RISE - LIFT_VY_FALL), 0.0, 1.0)
			_vy_k = lerpf(_vy_k, vk, 1.0 - exp(-LIFT_VY_SMOOTH * dt))
		if _hold_blend > 0.0:
			_hold_w = move_toward(_hold_w, _hold_w_target, dt / _hold_blend)
		else:
			_hold_w = _hold_w_target
		hold_pose_now = _hold_pose_eval()
		var w := _hold_w * _hold_w * (3.0 - 2.0 * _hold_w)
		var is_charge: bool = _hold_def.get("charge", false)
		var by_charge: bool = _hold_def.get("by_charge", false)
		var ck := clampf(_charge_k, 0.0, 1.0)
		if by_charge:
			# Round 8 load: a light share of the wind-up at c = 0, all of it at 1.
			w *= lerpf(LOAD_LIGHT_W, 1.0, ck)
		# Charging while walking or sprinting keeps the feet running.
		var free_k := _legs_free_k() if (is_charge or _hold_def.get("legs", &"") == &"free") else 0.0
		hold_leg_w = w * (1.0 - free_k)
		for i in LEG_START:
			var q = hold_pose_now.rot[i]
			if q != null:
				_layer_rot[i] = PoseLibrary.jslerp(i, _layer_rot[i], q, w if i != HIPS_I else hold_leg_w)
		if hold_pose_now.has_pos:
			var hp := _layer_pos.lerp(hold_pose_now.pos, hold_leg_w)
			hp.y = lerpf(_layer_pos.y, hold_pose_now.pos.y, hold_leg_w)
			_layer_pos = hp
		legs_held[0] = bool(hold_pose_now.defines_legs[0])
		legs_held[1] = bool(hold_pose_now.defines_legs[1])
		var tremble := float(_hold_def.get("tremble", 0.0))
		if by_charge:
			tremble *= lerpf(LOAD_TREMBLE_FLOOR, 1.0, smoothstep(LOAD_TREMBLE_FROM, 1.0, ck))
		if is_charge:
			# Charge: the wind-up coils further and trembles harder per level.
			tremble = CHARGE_TREMBLE_BASE + CHARGE_TREMBLE_PER_LEVEL * charge_level
			var coil: Vector3 = _hold_def.get("coil", Vector3.ZERO)
			if coil != Vector3.ZERO and charge_level > 0:
				# The coil turns the waist (the chest is usually at its range already).
				_layer_rot[1] = _layer_rot[1] * Quaternion.from_euler(coil * (PI / 180.0) * charge_level * w)
			# The sink settles into planted legs; running legs keep their height.
			_layer_pos.y -= CHARGE_SINK_PER_LEVEL * charge_level * hold_leg_w
		if tremble > 0.0:
			_apply_tremble(_layer_rot, deg_to_rad(tremble) * w)
			if is_charge or by_charge:
				charge_amp = deg_to_rad(tremble) * hold_leg_w
		if is_charge or tremble > 0.0:
			for i in [1, 2, 4, 5, 7, 8]:
				_layer_rot[i] = PoseLibrary.clamp_joint(Bones.ALL[i], _layer_rot[i])
		if _hold_w <= 0.0 and _hold_w_target <= 0.0:
			_hold_id = &""
	# Move layer (torso and arms; legs below).
	var ka: Array = []
	var kb: Array = []
	var f := 0.0
	var finished: StringName = &""
	var move_leg_w := 1.0
	if _move_id != &"":
		_move_t += dt
		if _aim_on:
			_refresh_aim(false)
			var aw := clampf(_move_t / maxf(_move_startup, 0.05), 0.0, 1.0)
			_aim_w = aw * aw * (3.0 - 2.0 * aw)
		else:
			_aim_w = 0.0
		var n := _keys.size()
		var k := 0
		# The epsilon puts the contact key exactly on its tick despite float sums.
		while k < n - 2 and _move_t >= float(_keys[k + 1][0]) - 0.000001:
			k += 1
		ka = _keys[k]
		kb = _keys[k + 1]
		var ta: float = ka[0]
		var tb: float = kb[0]
		f = _ease((_move_t - ta) / maxf(tb - ta, 0.0001), kb[3])
		if _move_legs_free:
			move_leg_w = 1.0 - _legs_free_k()
		for i in LEG_START:
			var qa := _key_rot(ka, i, _layer_rot[i])
			var qb := _key_rot(kb, i, _layer_rot[i])
			pose_rot[i] = PoseLibrary.jslerp(i, qa, qb, f)
		hips_offset = _key_pos(ka, _layer_pos).lerp(_key_pos(kb, _layer_pos), f)
		if move_leg_w < 1.0:
			# Running under an upper-body strike: the hips ride the locomotion
			# (a little of the strike's dip stays for weight).
			pose_rot[HIPS_I] = _layer_rot[HIPS_I].slerp(pose_rot[HIPS_I], move_leg_w)
			var hy := lerpf(_layer_pos.y, hips_offset.y, move_leg_w + (1.0 - move_leg_w) * 0.3)
			hips_offset = _layer_pos.lerp(hips_offset, move_leg_w)
			hips_offset.y = hy
		if _move_t >= _move_end - 0.000001:
			finished = _move_id
	else:
		for i in LEG_START:
			pose_rot[i] = _layer_rot[i]
		hips_offset = _layer_pos
	# Legs: IK to the locomotion foot targets with the final hips, then the
	# hold and move layers on top.
	var hips_xf := Transform3D(Basis(pose_rot[HIPS_I]), HumanoidRig.REST[&"Hips"] + hips_offset)
	for side in 2:
		var leg := PoseLibrary.leg_ik(hips_xf, side, _foot_targets[side], _foot_poles[side], _base_yaw, _foot_pitch[side])
		var base_i := LEG_START + side * 3
		for j in 3:
			var q: Quaternion = leg[j]
			if hold_pose_now != null and legs_held[side] and hold_leg_w > 0.0:
				var hq = hold_pose_now.rot[base_i + j]
				if hq != null:
					var w := hold_leg_w * hold_leg_w * (3.0 - 2.0 * hold_leg_w)
					q = PoseLibrary.jslerp(base_i + j, q, hq, w)
			if not ka.is_empty():
				var mq := PoseLibrary.jslerp(base_i + j, _key_rot(ka, base_i + j, q), _key_rot(kb, base_i + j, q), f)
				q = PoseLibrary.jslerp(base_i + j, q, mq, move_leg_w) if move_leg_w < 1.0 else mq
			pose_rot[base_i + j] = q
		if charge_amp > 0.0 and legs_held[side] and ka.is_empty():
			# A held kick charge trembles in the chambered leg too.
			var tt := _time + side * 3.1
			pose_rot[base_i] = pose_rot[base_i] * Quaternion.from_euler(Vector3(
				sin(tt * 101.0) * charge_amp, sin(tt * 83.0 + 1.0) * charge_amp, sin(tt * 109.0 + 2.0) * charge_amp))
		# Locomotion foot targets can ask the hip for more than its range (a long
		# trailing stride): keep the thigh legal; the toe leaves a little early.
		pose_rot[base_i] = PoseLibrary.clamp_joint(Bones.ALL[base_i], pose_rot[base_i])
	# Cross-fade.
	if _xfade_t < 1.0:
		_xfade_t = minf(_xfade_t + (dt / _xfade_dur if _xfade_dur > 0.0 else 1.0), 1.0)
		var w := _xfade_t * _xfade_t * (3.0 - 2.0 * _xfade_t)
		for i in HumanoidRig.BONE_COUNT:
			pose_rot[i] = PoseLibrary.jslerp(i, _xfade_rot[i], pose_rot[i], w)
		hips_offset = _xfade_pos.lerp(hips_offset, w)
	_apply_broken_arms(dt)
	if finished != &"":
		_end_move()
		_keys.clear()
		move_finished.emit(finished)

func _key_rot(key: Array, i: int, below: Quaternion) -> Quaternion:
	match int(key[1]):
		0:
			var p: PoseLibrary.Pose = key[2]
			var q = p.rot[i]
			if q == null:
				return below
			var qq: Quaternion = q
			if _aim_w > 0.0 and key[5] != null:
				var aq = (key[5] as PoseLibrary.Pose).rot[i]
				if aq != null:
					qq = PoseLibrary.jslerp(i, qq, aq, _aim_w)
			var kw: float = key[4]
			return qq if kw >= 1.0 else PoseLibrary.jslerp(i, below, qq, kw)
		1:
			return _snap_rot[i]
		_:
			return below

func _key_pos(key: Array, below: Vector3) -> Vector3:
	match int(key[1]):
		0:
			var p: PoseLibrary.Pose = key[2]
			if not p.has_pos:
				return below
			var kw: float = key[4]
			return p.pos if kw >= 1.0 else below.lerp(p.pos, kw)
		1:
			return _snap_pos
		_:
			return below

func _hold_pose_eval() -> PoseLibrary.Pose:
	var poses: Array = _hold_def["poses"]
	var p: PoseLibrary.Pose
	if poses.size() == 1:
		p = PoseLibrary.get_pose(poses[0])
	elif _hold_def.get("by_vy", false):
		# Round 7 lift: rising pose -> falling pose by the body's vertical speed.
		p = _blend_poses(PoseLibrary.get_pose(poses[0]), PoseLibrary.get_pose(poses[1]), _vy_k)
	elif _hold_def.has("ramp"):
		# Round 7 throw wind-up: grows from poses[0] to poses[1] once, then holds.
		p = _ramp_pose(poses, _hold_t, float(_hold_def["ramp"]))
	else:
		var rate := float(_hold_def.get("rate", 1.0))
		var x := _hold_t * rate * poses.size() * 0.5
		var i0 := int(floorf(x)) % poses.size()
		var i1 := (i0 + 1) % poses.size()
		var fr := x - floorf(x)
		fr = fr * fr * (3.0 - 2.0 * fr)
		p = _blend_poses(PoseLibrary.get_pose(poses[i0]), PoseLibrary.get_pose(poses[i1]), fr)
	# Crouched variant (block -> block_crouch).
	if _hold_def.has("crouch") and _crouch_w > 0.0:
		p = _blend_poses(p, PoseLibrary.get_pose(_hold_def["crouch"]), _crouch_w)
	var flail := float(_hold_def.get("flail", 0.0))
	if flail > 0.0:
		p = _flailed(p, deg_to_rad(flail))
	return p

## poses[0] -> poses[1] over `ramp` s (smoothstep), then poses[1].
static func _ramp_pose(poses: Array, t: float, ramp: float) -> PoseLibrary.Pose:
	var r := clampf(t / maxf(ramp, 0.001), 0.0, 1.0)
	if r <= 0.0 or r >= 1.0:
		return PoseLibrary.get_pose(poses[0 if r <= 0.0 else 1])
	return _blend_poses(PoseLibrary.get_pose(poses[0]), PoseLibrary.get_pose(poses[1]), r * r * (3.0 - 2.0 * r))

## A copy of `src` with loose limbs: slow, out-of-phase wobble of the arms and
## legs (radians `amp`), kept inside the joint limits. Never edits the cached pose.
func _flailed(src: PoseLibrary.Pose, amp: float) -> PoseLibrary.Pose:
	var p := _blend_poses(src, src, 0.0)
	var t := _time
	for i in FLAIL_BONES:
		var q = p.rot[i]
		if q == null:
			continue
		var a := amp * (FLAIL_ARM_MULT if i < LEG_START else 1.0)
		var e := Vector3.ZERO
		if PoseLibrary.joint_type(i) == 2:
			e.x = sin(t * FLAIL_FREQ.x + i * 1.9) * a * FLAIL_HINGE_MULT
		else:
			e = Vector3(sin(t * FLAIL_FREQ.x + i * 1.3) * a, 0.0, sin(t * FLAIL_FREQ.y + i * 2.1) * a)
		p.rot[i] = PoseLibrary.clamp_joint(Bones.ALL[i], (q as Quaternion) * Quaternion.from_euler(e))
	return p

## Per-bone blend of two compiled poses (bones only one defines keep it).
static func _blend_poses(a: PoseLibrary.Pose, b: PoseLibrary.Pose, fr: float) -> PoseLibrary.Pose:
	var p := PoseLibrary.Pose.new()
	p.rot.resize(HumanoidRig.BONE_COUNT)
	for i in HumanoidRig.BONE_COUNT:
		var qa = a.rot[i]
		var qb = b.rot[i]
		if qa != null and qb != null:
			p.rot[i] = PoseLibrary.jslerp(i, qa, qb, fr)
		elif qa != null:
			p.rot[i] = qa
		elif qb != null:
			p.rot[i] = qb
	p.has_pos = a.has_pos or b.has_pos
	p.pos = a.pos.lerp(b.pos, fr) if a.has_pos and b.has_pos else (a.pos if a.has_pos else b.pos)
	p.defines_legs = [a.defines_legs[0] or b.defines_legs[0], a.defines_legs[1] or b.defines_legs[1]]
	return p

func _apply_tremble(rots: Array[Quaternion], amp: float) -> void:
	var t := _time
	for i in [2, 4, 5, 7, 8]:
		var e := Vector3(sin(t * 97.0 + i) * amp, sin(t * 113.0 + i * 1.7) * amp, sin(t * 89.0 + i * 2.3) * amp)
		rots[i] = rots[i] * Quaternion.from_euler(e)

# --- Locomotion ------------------------------------------------------------------
## A foot's path over one cycle (`ph` 0 = mid-swing, PI = mid-stance):
## planted for `duty` of the cycle, sliding back under the body by `contact`
## m at exactly the body's speed, then lifted `lift` m and swung forward.
## Returns (fore-aft offset, lift, swing 0..1 for the toe-down pitch).
static func _planted_path(ph: float, duty: float, contact: float, lift: float) -> Vector3:
	var c := wrapf(ph - PI, -PI, PI)
	var sp := duty * PI
	if absf(c) < sp:
		return Vector3(-c / sp * contact * 0.5, 0.0, 0.0)
	var t := ((c - sp) if c >= sp else (c + TAU - sp)) / (TAU - 2.0 * sp)
	var e := t * t * (3.0 - 2.0 * t)
	var sw := sin(PI * t)
	return Vector3(lerpf(-contact * 0.5, contact * 0.5, e), lift * sw, sw)

func _walk_stride(speed: float, cw: float) -> float:
	return clampf(0.35 + 0.15 * speed, 0.4, 1.1) * lerpf(1.0, CROUCH_WALK_STRIDE, cw)

func _sprint_step(speed: float) -> float:
	return clampf(SPRINT_STEP_BASE + SPRINT_STEP_PER_MS * (speed - 4.5), 1.1, 3.0)

func _strafe_stride(speed: float) -> float:
	return lerpf(STRAFE_STRIDE.x, STRAFE_STRIDE.y, clampf((speed - 0.8) / 1.6, 0.0, 1.0))

## Phase rate (rad/s) of a style's cycle at `speed`.
func _style_rate(style: StringName, speed: float, cw: float) -> float:
	var walk := speed / (2.0 * _walk_stride(speed, cw)) * TAU
	match style:
		&"sprint", &"carry", &"wall_run_l", &"wall_run_r":
			var sk := 1.0 if style.begins_with("wall") else smoothstep(SPRINT_FROM, SPRINT_FULL, speed)
			return lerpf(walk, speed / (2.0 * _sprint_step(speed)) * TAU, sk)
		&"strafe":
			return speed / _strafe_stride(speed) * TAU
		&"limp":
			return walk / LIMP_STRIDE
		&"crawl":
			return speed / CRAWL_CYCLE * TAU
	return walk

func _update_locomotion(dt: float) -> void:
	# Stance weights (crouch / air) blend over STANCE_BLEND.
	var step := dt / STANCE_BLEND if STANCE_BLEND > 0.0 else 1.0
	_loco_vel = _loco_vel.lerp(_loco_target, 1.0 - exp(-LOCO_SMOOTH * dt))
	var v := Vector2(_loco_vel.x, _loco_vel.z)
	var speed := v.length()
	var dir := Vector3(v.x, 0.0, v.y) / speed if speed > 0.05 else Vector3(0, 0, -1)
	var eff := _auto_style(speed, dir)
	if eff != _eff_style:
		_style_prev = _eff_style
		_eff_style = eff
		_style_k = 0.0
	var wall := _eff_style.begins_with("wall")
	_crouch_w = move_toward(_crouch_w, 1.0 if _stance_id == &"crouch" and _eff_style == &"walk" else 0.0, step)
	_air_w = move_toward(_air_w, 1.0 if _stance_id == &"air" and not wall and _eff_style != &"crawl" else 0.0, step * 1.5)
	var cw := _crouch_w * _crouch_w * (3.0 - 2.0 * _crouch_w)
	var aw := _air_w * _air_w * (3.0 - 2.0 * _air_w)
	_style_k = move_toward(_style_k, 1.0, dt / STYLE_BLEND) if STYLE_BLEND > 0.0 else 1.0
	var sk := _style_k * _style_k * (3.0 - 2.0 * _style_k)
	# Phase.
	var rate := _style_rate(_eff_style, speed, cw)
	if sk < 1.0:
		rate = lerpf(_style_rate(_style_prev, speed, cw), rate, sk)
	if _move_steps > 0 and _move_id != &"":
		# Stumble: at least `steps` quick steps over the move.
		rate = maxf(rate, float(_move_steps) * PI / maxf(_move_end, 0.1))
	if (speed > 0.05 or (_move_steps > 0 and _move_id != &"")) and (aw < 0.99 or wall):
		_phase = fmod(_phase + rate * dt, TAU)
	_eval_style(_eff_style, _lo_a, speed, dir, cw, rate)
	var lo := _lo_a
	if sk < 1.0:
		_eval_style(_style_prev, _lo_b, speed, dir, cw, rate)
		_blend_loco(_lo_b, _lo_a, sk, _lo_b)
		lo = _lo_b
	# Upper overlay (carry_hold by default while carrying).
	var ov_id := _overlay_id
	var ov_pose := _overlay_pose
	_overlay_t += dt
	if ov_id != &"" and PoseLibrary.HOLDS.has(ov_id) and PoseLibrary.HOLDS[ov_id].has("ramp"):
		# A "ramp" hold as an overlay grows the same way (the throw wind-up).
		var od: Dictionary = PoseLibrary.HOLDS[ov_id]
		ov_pose = _ramp_pose(od["poses"], _overlay_t, float(od["ramp"]))
	if ov_id == &"" and _eff_style == &"carry":
		ov_id = &"carry_hold"
		ov_pose = _carry
	var ov_on := ov_id != &""
	_overlay_w = move_toward(_overlay_w, 1.0 if ov_on else 0.0, dt / OVERLAY_BLEND) if OVERLAY_BLEND > 0.0 else (1.0 if ov_on else 0.0)
	if not ov_on and _overlay_w <= 0.0:
		_overlay_pose = null
	elif ov_on:
		_overlay_pose = ov_pose
	var ow := _overlay_w * _overlay_w * (3.0 - 2.0 * _overlay_w)
	if _overlay_pose != null and ow > 0.0:
		for i in range(1, LEG_START):
			var q = _overlay_pose.rot[i]
			if q != null:
				lo.rot[i] = PoseLibrary.jslerp(i, lo.rot[i], q, ow)
	# Air: rising -> falling by vertical speed.
	if aw > 0.0:
		var vy := _vy if is_nan(_vy_ext) else _vy_ext
		var fall_k := clampf((1.0 - vy) / 3.0, 0.0, 1.0)
		for side in 2:
			var air_foot: Vector3 = _rise_feet[side].lerp(_fall_feet[side], fall_k)
			lo.feet[side] = lo.feet[side].lerp(air_foot, aw)
			lo.pitch[side] = lerpf(lo.pitch[side], lerpf(_rise_pitch[side], _fall_pitch[side], fall_k), aw)
		lo.yaw *= 1.0 - aw
		lo.rot[0] = lo.rot[0].slerp(Quaternion.IDENTITY, aw)
		var ap := _blend_poses(_jump_rise, _jump_fall, fall_k)
		for i in range(1, LEG_START):
			var q = ap.rot[i]
			if q != null:
				lo.rot[i] = PoseLibrary.jslerp(i, lo.rot[i], q, aw * (1.0 - ow))
		if ap.has_pos:
			lo.pos = lo.pos.lerp(ap.pos, aw)
	for side in 2:
		_foot_targets[side] = lo.feet[side]
		_foot_pitch[side] = lo.pitch[side]
		_foot_poles[side] = lo.poles[side]
	_base_yaw = lo.yaw
	_layer_pos = lo.pos
	for i in LEG_START:
		_layer_rot[i] = lo.rot[i]

static func _blend_loco(a: Loco, b: Loco, w: float, out: Loco) -> void:
	for side in 2:
		out.feet[side] = a.feet[side].lerp(b.feet[side], w)
		out.pitch[side] = lerpf(a.pitch[side], b.pitch[side], w)
		out.poles[side] = a.poles[side].lerp(b.poles[side], w)
	out.yaw = lerp_angle(a.yaw, b.yaw, w)
	out.pos = a.pos.lerp(b.pos, w)
	for i in 10:
		out.rot[i] = PoseLibrary.jslerp(i, a.rot[i], b.rot[i], w)

func _eval_style(style: StringName, o: Loco, speed: float, dir: Vector3, cw: float, rate: float) -> void:
	match style:
		&"sprint", &"carry":
			var spk := smoothstep(SPRINT_FROM, SPRINT_FULL, speed)
			if spk < 1.0:
				_style_walk(o, speed, dir, cw, rate)
			if spk > 0.0:
				var tmp := _lo_tmp()
				_style_sprint(tmp, speed, dir, 0)
				if spk >= 1.0:
					_copy_loco(tmp, o)
				else:
					_blend_loco(o, tmp, spk, o)
			if style == &"carry":
				_carry_adjust(o, speed)
		&"wall_run_l":
			_style_sprint(o, maxf(speed, 4.0), dir, -1)
		&"wall_run_r":
			_style_sprint(o, maxf(speed, 4.0), dir, 1)
		&"strafe":
			_style_strafe(o, speed, dir)
		&"limp":
			_style_limp(o, speed, dir)
		&"crawl":
			_style_crawl(o, speed, dir)
		_:
			_style_walk(o, speed, dir, cw, rate)

var _tmp_loco := Loco.new()
func _lo_tmp() -> Loco:
	return _tmp_loco

static func _copy_loco(a: Loco, out: Loco) -> void:
	_blend_loco(a, a, 0.0, out)

## Idle / walk / run (the original cycle), crouch-walk, and stumble steps.
func _style_walk(o: Loco, speed: float, dir: Vector3, cw: float, rate: float) -> void:
	var k := clampf(speed / (1.2 - 0.6 * cw), 0.0, 1.0)
	var run_k := clampf((speed - 2.6) / 1.8, 0.0, 1.0) * (1.0 - cw)
	var stride := _walk_stride(speed, cw)
	var fwd := -dir.z if speed > 0.05 else 0.0
	var lat := dir.x if speed > 0.05 else 0.0
	var s := sin(_phase)
	var lift := lerpf(0.09 + 0.07 * run_k, 0.05, cw)
	var half_w := lerpf(0.11, 0.18, cw)
	var sdir := dir
	var duty := lerpf(WALK_DUTY.x, WALK_DUTY.y, run_k)
	if _move_steps > 0 and _move_id != &"":
		# Stumble steps: quick and high enough to read; the stride comes from
		# the real speed so planted feet hold (stamping in place when still).
		k = 1.0
		lift = STUMBLE_LIFT
		stride = speed * PI / maxf(rate, 0.1)
		duty = 0.45
		half_w = 0.13
	for side in 2:
		var ph := _phase + (PI if side == 1 else 0.0)
		var walk_base := Vector3(half_w if side == 1 else -half_w, 0.08, 0.0)
		var fp := _planted_path(ph, duty, duty * 2.0 * stride, lift)
		var walk := walk_base + sdir * (fp.x + 0.07 * run_k) + Vector3.UP * fp.y
		var idle: Vector3 = _stance_feet[side].lerp(_crouch_feet[side], cw)
		o.feet[side] = idle.lerp(walk, k)
		o.pitch[side] = -0.35 * fp.z * k
		o.poles[side] = Vector3(0.12 if side == 1 else -0.12, 0.0, -1.0)
	var hips_yaw_deg := lerpf(lerpf(-15.0, -12.0, cw), 0.0, k) + 7.0 * s * k * fwd * (1.0 - cw)
	o.yaw = deg_to_rad(hips_yaw_deg)
	var yaw_b := Basis(Vector3.UP, o.yaw)
	for side in 2:
		o.poles[side] = yaw_b * o.poles[side]
	var bob := (0.02 + 0.035 * run_k) * k * (0.5 - 0.5 * cos(2.0 * _phase)) * lerpf(1.0, 0.5, cw)
	o.pos = _stance.pos.lerp(_crouch.pos, cw) + Vector3(0, -bob - 0.03 * run_k, 0)
	var yaw_q := Quaternion.from_euler(Vector3(0, o.yaw, 0))
	# Pelvis: tips forward in a crouch, and a little when running (so the
	# trailing leg extends within the hip's range).
	o.rot[0] = yaw_q * Quaternion.from_euler(Vector3(deg_to_rad(-18.0 * cw - 8.0 * run_k * maxf(fwd, 0.0)), 0, 0))
	var breath := sin(_time * TAU * 0.3) * deg_to_rad(1.5)
	o.rot[1] = Quaternion.from_euler(Vector3(deg_to_rad(-4.0 - 12.0 * run_k * fwd), 0, deg_to_rad(-5.0 * lat * k)))
	o.rot[2] = (_stance.rot[2] as Quaternion) * Quaternion(Vector3.RIGHT, breath)
	var chest_yaw_deg := -6.0
	o.rot[3] = Quaternion.from_euler(Vector3(deg_to_rad(6.0 + 6.0 * run_k), deg_to_rad(clampf(-(hips_yaw_deg + chest_yaw_deg), -60.0, 60.0)), 0))
	for i in range(4, LEG_START):
		o.rot[i] = _stance.rot[i]
	if run_k > 0.0:
		var pump_l := Quaternion.from_euler(Vector3(deg_to_rad(20.0 - 45.0 * s), 0, deg_to_rad(-12.0)))
		var pump_r := Quaternion.from_euler(Vector3(deg_to_rad(20.0 + 45.0 * s), 0, deg_to_rad(12.0)))
		var elbow := Quaternion(Vector3.RIGHT, deg_to_rad(95.0))
		o.rot[4] = PoseLibrary.jslerp(4, o.rot[4], pump_l, run_k)
		o.rot[5] = PoseLibrary.jslerp(5, o.rot[5], elbow, run_k)
		o.rot[7] = PoseLibrary.jslerp(7, o.rot[7], pump_r, run_k)
		o.rot[8] = PoseLibrary.jslerp(8, o.rot[8], elbow, run_k)
	if cw > 0.0:
		# Crouch: torso, head and guard arms from the compiled crouch pose.
		for i in range(1, LEG_START):
			var cq = _crouch.rot[i]
			if cq != null:
				o.rot[i] = PoseLibrary.jslerp(i, o.rot[i], cq, cw)

## Sprint (wall = 0), or a wall run (wall = -1 wall on the left, +1 right):
## forward lean, long stride with a short ground contact, a high heel
## recovery and knee drive, hard arm pump; the hips bounce lowest at each
## foot's mid-stance.
func _style_sprint(o: Loco, speed: float, dir: Vector3, wall: int) -> void:
	var v := maxf(speed, 0.1)
	var lean := clampf(0.55 + (v - 4.5) / 5.0, 0.55, 1.0)
	var step_len := _sprint_step(v)
	var cyc := 2.0 * step_len
	var contact := clampf(v * SPRINT_CONTACT_TIME, 0.45, 0.95)
	var sfr := clampf(contact / cyc, 0.12, 0.45)
	var hmax := clampf(0.26 + 0.07 * (v - 4.5), 0.22, 0.55)
	if speed < 0.05:
		dir = Vector3(0, 0, -1)
	var fdir := Vector3(dir.x, 0.0, dir.z).normalized()
	var wsg := float(wall)
	for side in 2:
		var ph := _phase + (PI if side == 1 else 0.0)
		var c := wrapf(ph - PI, -PI, PI)
		var u := 0.0
		var h := 0.0
		var pitch := 0.0
		var on_ground := absf(c) < sfr * PI
		var t := 0.0
		if on_ground:
			var f := c / (sfr * PI)            # -1 strike .. +1 toe-off
			u = -f * contact * 0.5 + 0.05
			pitch = -0.55 * smoothstep(0.2, 1.0, f)
		else:
			t = (c - sfr * PI) if c >= sfr * PI else (c + TAU - sfr * PI)
			t /= TAU - 2.0 * sfr * PI
			var a := smoothstep(0.1, 0.8, t)
			u = lerpf(-contact * 0.5 + 0.05, contact * 0.5 + 0.15, a) - 0.1 * smoothstep(0.8, 1.0, t)
			h = hmax * sin(PI * pow(t, 0.75))
			pitch = lerpf(-0.75, 0.2, smoothstep(0.3, 0.9, t))
		var hw := SPRINT_HALF_WIDTH * (1.0 if side == 1 else -1.0)
		var foot := Vector3(hw, 0.08, 0.0) + fdir * u + Vector3.UP * h
		var pole := fdir + Vector3(0.1 if side == 1 else -0.1, 0.0, 0.0)
		if wall != 0:
			# On the wall: the planted foot presses on it beside the hips; the
			# swinging leg comes off it and drives through.
			var off := 0.0 if on_ground else sin(PI * t)
			foot.x = lerpf(wsg * WALLRUN_FOOT_X, wsg * 0.1, off)
			foot.y += WALLRUN_FOOT_Y * (1.0 - off * 0.6)
			pole = fdir + Vector3(-wsg * 0.35, 0.0, 0.0)
		o.feet[side] = foot
		o.pitch[side] = pitch
		o.poles[side] = pole
	var sph := sin(_phase)
	var bounce := 0.5 + 0.5 * cos(2.0 * _phase)
	var hips_yaw := -8.0 * sph   # the hips turn with the leg swinging through
	o.yaw = 0.0
	o.pos = Vector3(0, -0.05 - 0.035 * bounce * lean, 0.0)
	var roll := wsg * WALLRUN_ROLL if wall != 0 else 0.0   # Rz(-) tilts the head toward +X
	o.rot[0] = Quaternion.from_euler(Vector3(deg_to_rad(-SPRINT_LEAN * lean), deg_to_rad(hips_yaw), deg_to_rad(roll)))
	o.rot[1] = Quaternion.from_euler(Vector3(deg_to_rad(-SPRINT_LEAN * lean), deg_to_rad(6.0 * sph), deg_to_rad(-roll * 0.3)))
	o.rot[2] = Quaternion.from_euler(Vector3(deg_to_rad(-4.0), deg_to_rad(9.0 * sph), deg_to_rad(-roll * 0.2)))
	o.rot[3] = Quaternion.from_euler(Vector3(deg_to_rad(10.0 + 10.0 * lean), deg_to_rad(-7.0 * sph), deg_to_rad(-roll * 0.4)))
	var amp := SPRINT_ARM_SWING * lerpf(0.75, 1.0, lean)
	var inner_out := 18.0 if wall != 0 else 0.0
	var lz := -9.0 - (inner_out if wall < 0 else 0.0)
	var rz := 9.0 + (inner_out if wall > 0 else 0.0)
	o.rot[4] = Quaternion.from_euler(Vector3(deg_to_rad(8.0 - amp * sph), 0, deg_to_rad(lz)))
	o.rot[5] = Quaternion(Vector3.RIGHT, deg_to_rad(88.0 - 16.0 * sph))
	o.rot[6] = Quaternion.IDENTITY
	o.rot[7] = Quaternion.from_euler(Vector3(deg_to_rad(8.0 + amp * sph), 0, deg_to_rad(rz)))
	o.rot[8] = Quaternion(Vector3.RIGHT, deg_to_rad(88.0 + 16.0 * sph))
	o.rot[9] = Quaternion.IDENTITY

## Carrying a body: heavier bounce and a counter-lean against the load.
func _carry_adjust(o: Loco, speed: float) -> void:
	var still := 1.0 - clampf(speed / 2.0, 0.0, 1.0)
	o.rot[1] = o.rot[1] * Quaternion(Vector3.RIGHT, deg_to_rad(6.0 * still + 3.0))
	o.pos.y -= 0.02 + 0.01 * clampf(speed / 6.0, 0.0, 1.0)

## Circle-strafe: guard up, hips square to the target, step-close footwork
## (the foot on the side of travel steps first, the other closes; they never
## cross).
func _style_strafe(o: Loco, speed: float, dir: Vector3) -> void:
	var k := clampf(speed / 0.5, 0.0, 1.0)
	var stride := _strafe_stride(speed)
	var phi := fposmod(_phase / TAU, 1.0)
	var feet0: Array[Vector3] = [_stance_feet[0] + Vector3(-STRAFE_WIDEN, 0, 0), _stance_feet[1] + Vector3(STRAFE_WIDEN, 0, 0)]
	var lead := 0 if feet0[0].dot(dir) >= feet0[1].dot(dir) else 1
	for side in 2:
		var is_lead := side == lead
		var a := 0.0 if is_lead else 0.5
		var lt := clampf((phi - a) / 0.38, 0.0, 1.0)
		var adv := lt * lt * (3.0 - 2.0 * lt)
		var off := stride * (adv - phi) + (-0.31 if is_lead else 0.19) * stride
		var h := 0.07 * sin(PI * lt) if lt > 0.0 and lt < 1.0 else 0.0
		var foot := feet0[side] + dir * off + Vector3.UP * h
		o.feet[side] = feet0[side].lerp(foot, k)
		o.pitch[side] = -0.25 * sin(PI * lt) * k if lt > 0.0 and lt < 1.0 else 0.0
	o.yaw = _stance.hips_yaw
	var yaw_b := Basis(Vector3.UP, o.yaw)
	o.poles[0] = yaw_b * Vector3(-0.15, 0, -1)
	o.poles[1] = yaw_b * Vector3(0.15, 0, -1)
	var bob := 0.015 * k * absf(sin(TAU * phi))
	o.pos = _stance.pos + Vector3(0, -0.02 - bob, 0)
	o.rot[0] = Quaternion.from_euler(Vector3(0, o.yaw, deg_to_rad(-4.0 * dir.x * k)))
	for i in range(1, LEG_START):
		var q = _guard.rot[i]
		o.rot[i] = q if q != null else _stance.rot[i]

## Lost an arm: hunched and listing toward the stump, the remaining hand
## clutching it, short uneven lurching steps.
func _style_limp(o: Loco, speed: float, dir: Vector3) -> void:
	var k := clampf(speed / 0.8, 0.0, 1.0)
	var right_gone := _arm_missing() == 1
	var src := _limp_m if right_gone else _limp
	var m := 1.0 if right_gone else -1.0
	var stride := _walk_stride(speed, 0.0) * LIMP_STRIDE
	var ph0 := _phase + LIMP_LURCH * sin(_phase)   # the body lurches; the feet stay planted
	for side in 2:
		var ph := _phase + (PI if side == 1 else 0.0)
		var base := Vector3(0.13 if side == 1 else -0.13, 0.08, 0.0)
		# The stump side drags: a lower, scuffing lift.
		var drag := (side == 0) != (_arm_missing() == 1)
		var fp := _planted_path(ph, 0.66, 0.66 * 2.0 * stride, 0.03 if drag else 0.07)
		o.feet[side] = base.lerp(base + dir * fp.x + Vector3.UP * fp.y, k)
		o.pitch[side] = -0.2 * fp.z * k
		o.poles[side] = Vector3(0.12 if side == 1 else -0.12, 0.0, -1.0)
	var sway := sin(ph0)
	o.yaw = 0.0
	o.pos = Vector3(0, -0.1 - 0.035 * k * (0.5 - 0.5 * cos(2.0 * ph0)), 0.02)
	o.rot[0] = Quaternion.from_euler(Vector3(deg_to_rad(-8.0), 0, deg_to_rad(5.0 * sway * k - 4.0 * m)))
	for i in range(1, LEG_START):
		var q = src.rot[i]
		o.rot[i] = q if q != null else _stance.rot[i]
	o.rot[3] = o.rot[3] * Quaternion.from_euler(Vector3(deg_to_rad(4.0 * sway * k), 0, 0))

## Lost a leg: face down on the floor, chest raised on the arms, the hands
## reach and pull in turn (planted while pulling), the remaining leg pushes.
func _style_crawl(o: Loco, speed: float, dir: Vector3) -> void:
	var k := clampf(speed / 0.3, 0.0, 1.0)
	o.yaw = 0.0
	o.pos = Vector3(0, -0.77, 0.05)
	o.rot[0] = Quaternion.from_euler(Vector3(deg_to_rad(-82.0), 0, 0))
	o.rot[1] = Quaternion.from_euler(Vector3(deg_to_rad(12.0), 0, 0))
	o.rot[2] = Quaternion.from_euler(Vector3(deg_to_rad(14.0), 0, 0))
	o.rot[3] = Quaternion.from_euler(Vector3(deg_to_rad(34.0), 0, 0))
	var hips_xf := Transform3D(Basis(o.rot[0]), HumanoidRig.REST[&"Hips"] + o.pos)
	var spine_xf := hips_xf * Transform3D(Basis(o.rot[1]), HumanoidRig.REST[&"Spine"])
	var chest_xf := spine_xf * Transform3D(Basis(o.rot[2]), HumanoidRig.REST[&"Chest"])
	var stance := 0.55
	var reach := stance * CRAWL_CYCLE * 0.5   # half the planted hand's travel
	for side in 2:
		var ph := fposmod((_phase + (PI if side == 1 else 0.0)) / TAU, 1.0)
		var z := 0.0
		var h := 0.0
		if ph < stance:
			z = lerpf(-reach, reach, ph / stance)          # planted, the body slides over it
		else:
			var t := (ph - stance) / (1.0 - stance)
			z = lerpf(reach, -reach, t * t * (3.0 - 2.0 * t))
			h = 0.12 * sin(PI * t)
		z = lerpf(0.0, z, k)
		h *= k
		var sx := -1.0 if side == 0 else 1.0
		var fist := Vector3(sx * 0.26, 0.07 + h, -0.62 + z)
		var ua := 4 if side == 0 else 7
		var shoulder := chest_xf * (HumanoidRig.REST[Bones.L_UPPER_ARM if side == 0 else Bones.R_UPPER_ARM] as Vector3)
		var res := PoseLibrary.solve_ik(shoulder, fist, PoseLibrary.IK_ARM_UPPER, PoseLibrary.IK_ARM_LOWER,
			Vector3(sx * 1.0, 0.3, 0.6), true)
		o.rot[ua] = PoseLibrary.clamp_joint(Bones.ALL[ua], Quaternion((chest_xf.basis.inverse() * (res[0] as Basis)).orthonormalized()))
		o.rot[ua + 1] = Quaternion(Vector3.RIGHT, res[1])
		o.rot[ua + 2] = Quaternion(Vector3.RIGHT, deg_to_rad(-20.0))
		# The leg on the same side pushes while the hand reaches.
		var push := 0.5 + 0.5 * cos(TAU * ph) * k
		o.feet[side] = Vector3(sx * lerpf(0.34, 0.2, push), 0.1, lerpf(0.62, 0.9, push))
		o.pitch[side] = deg_to_rad(-40.0)
		o.poles[side] = Vector3(sx * 0.6, -1.0, 0.25)

## 0 = the left arm is gone, 1 = the right, -1 = both there.
func _arm_missing() -> int:
	if rig == null or not rig.has_method(&"is_bone_severed"):
		return -1
	if rig.is_bone_severed(Bones.R_UPPER_ARM) or rig.is_bone_severed(Bones.R_LOWER_ARM):
		return 1
	if rig.is_bone_severed(Bones.L_UPPER_ARM) or rig.is_bone_severed(Bones.L_LOWER_ARM):
		return 0
	return -1

## Broken arm: the upper arm hangs toward world down with a lagging pendulum
## that swings as the shoulder accelerates; the forearm hangs nearly straight.
func _apply_broken_arms(dt: float) -> void:
	if not (_broken[0] or _broken[1]) or rig == null or not rig.skeleton.is_inside_tree():
		return
	var skel_b := rig.skeleton.global_basis.orthonormalized()
	var chest_q := pose_rot[0] * pose_rot[1] * pose_rot[2]
	var to_chest := (skel_b * Basis(chest_q)).inverse()
	for side in 2:
		if not _broken[side]:
			continue
		var ua := 4 if side == 0 else 7
		var sh := rig.get_bone_global_position(Bones.L_UPPER_ARM if side == 0 else Bones.R_UPPER_ARM)
		var vel := Vector3.ZERO
		if _last_shoulder[side] != Vector3.INF and dt > 0.0:
			vel = (sh - _last_shoulder[side]) / dt
		var acc: Vector3 = (vel - _last_shoulder_v[side]) / dt if dt > 0.0 else Vector3.ZERO
		_last_shoulder[side] = sh
		_last_shoulder_v[side] = vel
		acc = acc.limit_length(60.0)
		# Pendulum lag (world, horizontal): spring back, damped, pushed by -acc.
		var lag: Vector3 = _hang_lag[side]
		var lv: Vector3 = _hang_vel[side]
		lv += (-HANG_SPRING * lag - HANG_DAMP * lv - Vector3(acc.x, 0.0, acc.z) * HANG_ACCEL) * dt
		lag = (lag + lv * dt).limit_length(0.8)
		_hang_lag[side] = lag
		_hang_vel[side] = lv
		var out := skel_b * (chest_q * Vector3(-1.0 if side == 0 else 1.0, 0.0, 0.0))
		var dir_world := (Vector3.DOWN + lag + Vector3(out.x, 0.0, out.z) * 0.12).normalized()
		var dir_local := to_chest * dir_world
		pose_rot[ua] = Quaternion(Vector3.DOWN, dir_local.normalized())
		pose_rot[ua + 1] = Quaternion(Vector3.RIGHT, deg_to_rad(12.0))
		pose_rot[ua + 2] = Quaternion(Vector3.RIGHT, deg_to_rad(15.0))

# --- Aim -------------------------------------------------------------------------
## Rebuild the aimed key poses when the target moved (in character space).
func _refresh_aim(force: bool) -> void:
	if not _aim_on or _move_id == &"" or rig == null or rig.skeleton == null or not rig.skeleton.is_inside_tree():
		return
	if _move_mirror or not PoseLibrary.STRIKE_BONES.has(_move_id) or _strike_pose == &"" \
			or PoseLibrary.NO_AIM.has(_move_id):
		return
	var local := rig.skeleton.global_transform.affine_inverse() * _aim_world
	local /= maxf(rig.height_scale, 0.01)
	if not force and local.distance_to(_aim_local) < 0.05:
		return
	_aim_local = local
	var limbs: Array[String] = []
	for b in PoseLibrary.STRIKE_BONES[_move_id]:
		if PoseLibrary.AIM_LIMB.has(b):
			limbs.append(PoseLibrary.AIM_LIMB[b])
	var sd: Dictionary = PoseLibrary.POSES.get(_strike_pose, {})
	var ref := ""
	for l in limbs:
		if sd.has(l):
			ref = l
			break
	if ref == "":
		return
	var t: Vector3 = sd[ref]
	if sd.get("frame", &"char") == &"body":
		t = Basis(Vector3.UP, deg_to_rad((sd.get("hips", Vector3.ZERO) as Vector3).y)) * t
	var dyaw := clampf(wrapf(atan2(-local.x, -local.z) - atan2(-t.x, -t.z), -PI, PI), -AIM_MAX_YAW, AIM_MAX_YAW)
	var dh := clampf(local.y - t.y, -AIM_MAX_HEIGHT, AIM_MAX_HEIGHT)
	if PoseLibrary.AIM_YAW_ONLY.has(_move_id):
		dh = 0.0   # Round 7: the move's height is the point of it (gut, thigh, head kick)
	if Vector2(local.x, local.z).length() < 0.2:
		dyaw = 0.0
	for key in _keys:
		if int(key[1]) == 0:
			key[5] = _aimed_pose(key[6], limbs, dyaw, dh)

func _aimed_pose(pname: StringName, limbs: Array[String], dyaw: float, dh: float) -> PoseLibrary.Pose:
	var d: Dictionary = PoseLibrary.POSES.get(pname, {})
	var touched := false
	for l in limbs:
		if d.has(l):
			touched = true
	if not touched:
		return null
	var ck := "%s|%d|%d|%s" % [pname, roundi(rad_to_deg(dyaw)), roundi(dh * 100.0), ",".join(limbs)]
	if _aim_cache.has(ck):
		return _aim_cache[ck]
	var d2 := d.duplicate()
	var rot := Basis(Vector3.UP, dyaw)
	for l in limbs:
		if d2.has(l):
			d2[l] = rot * ((d2[l] as Vector3) + Vector3(0, dh, 0))
			var pole := ("lelbow" if l == "lfist" else "relbow" if l == "rfist" else "lknee" if l == "lankle" else "rknee")
			if d2.has(pole):
				d2[pole] = rot * (d2[pole] as Vector3)
	# Torso follows a little (only where the key defines it, so the IK above
	# matches the torso the key will actually have).
	if d2.has("chest"):
		d2["chest"] = (d2["chest"] as Vector3) + Vector3(0, rad_to_deg(dyaw) * 0.4, 0)
	if d2.has("spine"):
		d2["spine"] = (d2["spine"] as Vector3) + Vector3(dh * 30.0, 0, 0)
	var p := PoseLibrary.compile(d2)
	if _aim_cache.size() > 256:
		_aim_cache.clear()
	_aim_cache[ck] = p
	return p


# =============================================================================
# Round 8 (agent P). B calls set_charge_amount every tick while charging.
# =============================================================================

## Charge amount c (0..1) of the held strike: the held charge load
## (PoseLibrary.ROUND8_LOAD_IDS, hold key "by_charge") deepens with it, from
## LOAD_LIGHT_W of the full wind-up at c = 0 to all of it at c = 1, with a
## slight tremble near full. The pose follows c through a critically damped
## spring (LOAD_SPRING), so a jump in c never pops. A fresh load hold starts
## at c = 0 (it clears an earlier c), so call this after hold_pose() or
## every tick.
func set_charge_amount(c: float) -> void:
	_charge_target = clampf(c, 0.0, 1.0)

## The charge amount the load pose shows now (the spring's value, 0..1).
func get_charge_amount() -> float:
	return clampf(_charge_k, 0.0, 1.0)

## True while the held pose is a charge load ("by_charge").
func is_charge_load_held() -> bool:
	return _hold_id != &"" and _hold_w_target > 0.0 and bool(_hold_def.get("by_charge", false))
