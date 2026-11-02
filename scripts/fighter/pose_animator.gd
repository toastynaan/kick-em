class_name PoseAnimator
extends Node
## Procedural keyframe animator for the HumanoidRig (no Mixamo clips yet):
## locomotion (idle / walk / run blend), one-shot moves stretched to the
## combat system's frame data, and held poses. All poses live in PoseLibrary.
## OWNER: agent A (rig & ragdoll). CONTRACT STUB: keep every public signature.
##
## Move ids (play_move): jab1, jab2, jab3, power_punch, sparta_kick, leg_sweep,
##   grab, throw, back_kick, dash, block_hit, dodge, getup_face_up,
##   getup_face_down, e_hook, e_heavy, e_kick, e_grab, e_charge, e_throw_debris,
##   grab_break_push, taunt, punt (round 2), land (air recovery)
## Hold ids (hold_pose): block, power_charge, grab_hold, held, stagger, guard,
##   fall, neutral, wall_splat (round 2)
## Round 2: set_aim_target()/clear_aim_target() bend strike IK toward a point;
##   PoseLibrary.has_move(id) checks a move id.
## Upgrade 2 moves: cross, hook, uppercut, roundhouse, backfist (spinning, hits
##   behind), flying_kick, hammer_fist, crouch_punch, rising_uppercut, knee,
##   headbutt, neck_throw, mount_punch, stomp, upward_throw, wall_slam,
##   e_sweep (low, with a building tell), stumble, dazed (also holds).
## Upgrade 2 holds: crouch, crouch_walk, block_crouch, jump_rise, jump_fall,
##   land, stumble, dazed, headlock, arm_drag, giant_swing, and
##   <move>_charge for every PoseLibrary.CHARGEABLE move
##   (PoseLibrary.charge_hold_of(id)); set_charge_level(0..3) grows the
##   tremble and coil. set_stance(&"stand"|&"crouch"|&"air"[, vy]) every tick.
##   A held &"block" turns into block_crouch while crouched.
## Focus (U6): the player's animator steps on TimeDirector.player_delta().
##
## Layers, bottom to top: locomotion (legs by IK to procedural foot targets, so
## feet stay planted) -> held pose -> one-shot move -> cross-fade. Bones a
## pose does not define come from the layer below. Updates in
## _physics_process (process_physics_priority -20, before RagdollController
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
## play_move/hold_pose/release_pose/cancel are ignored.
var locked := false
## Playback rate multiplier for looping holds (the falling loop).
var loop_speed := 1.0
## Charge level 0..3 of a held &"<move>_charge" pose (set_charge_level).
var charge_level := 0
## Animation delta of the last tick (after Focus player time and time_scale).
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

var _time := 0.0
# Locomotion
var _loco_target := Vector3.ZERO
var _loco_vel := Vector3.ZERO
var _max_speed := 4.5
var _phase := 0.0
var _foot_targets: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _foot_pitch: Array[float] = [0.0, 0.0]
var _base_yaw := 0.0
var _stance_feet: Array[Vector3] = []
var _stance: PoseLibrary.Pose
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
# Move layer
var _move_id: StringName = &""
var _move_t := 0.0
var _move_end := 0.0
var _keys: Array = []          # each: [time, kind(0 pose,1 snapshot,2 base), Pose, ease]
var _move_startup := 0.0
var _move_mirror := false
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
	process_physics_priority = -20

func setup(p_rig: HumanoidRig) -> void:
	rig = p_rig
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
	_host = get_parent()
	_td = get_node_or_null(^"/root/TimeDirector") if is_inside_tree() else null
	_evaluate(0.0)
	if drive_skeleton and rig and rig.skeleton:
		_write_skeleton()

func _physics_process(delta: float) -> void:
	if rig == null or _stance == null:
		return
	var dt := _anim_delta(delta) * time_scale
	last_dt = dt
	_track_vertical(delta)
	if dt > 0.0:
		_evaluate(dt)
	if drive_skeleton and rig.skeleton:
		_write_skeleton()

## Focus (U6): the player animates on player time (TimeDirector.player_delta),
## everyone else on the scaled physics delta.
func _anim_delta(delta: float) -> float:
	if _host == null:
		_host = get_parent()
	if _host and _host.is_in_group(&"player"):
		if _td == null:
			_td = get_node_or_null(^"/root/TimeDirector")
		if _td and _td.has_method(&"player_delta"):
			return _td.player_delta(delta)
	return delta

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
## For enemy moves `startup` includes the tell: the windup builds over the
## whole tell (60% -> 100%), freezes for ~2 frames, then snaps to the strike.
func play_move(move_id: StringName, startup: float, active: float, recovery: float) -> void:
	if locked:
		return
	_play(move_id, startup, active, recovery)

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
## Moves in PoseLibrary.NO_AIM (leg_sweep, throw) ignore it.
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

func get_hold_id() -> StringName:
	return _hold_id

## Smoothed locomotion speed (m/s).
func get_locomotion_speed() -> float:
	return Vector2(_loco_vel.x, _loco_vel.z).length()

# --- Internal API (RagdollController) ----------------------------------------
func _play(move_id: StringName, startup: float, active: float, recovery: float) -> void:
	if not PoseLibrary.MOVES.has(move_id):
		push_warning("PoseAnimator: unknown move %s" % move_id)
		return
	var def: Dictionary = PoseLibrary.MOVES[move_id]
	startup = maxf(startup, 0.0)
	active = maxf(active, 0.0)
	recovery = maxf(recovery, 0.0)
	_snap_rot = pose_rot.duplicate()
	_snap_pos = hips_offset
	if not def.get("keep_hold", false) and move_id != &"block_hit":
		_hold_id = &""
		_hold_w = 0.0
		_hold_w_target = 0.0
	var mirror := false
	if def.get("mirror_by_motion", false):
		mirror = _loco_target.x > 0.3
	_move_mirror = mirror
	_move_startup = startup
	_strike_pose = &""
	var seg_start := [0.0, startup, startup + active]
	var seg_dur := [startup, active, recovery]
	_keys.clear()
	var key_defs: Array = def["keys"]
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

func _hold(pose_id: StringName, blend_time: float) -> void:
	var def: Dictionary
	if PoseLibrary.HOLDS.has(pose_id):
		def = PoseLibrary.HOLDS[pose_id]
	elif PoseLibrary.POSES.has(pose_id):
		def = {"poses": [pose_id]}
	else:
		push_warning("PoseAnimator: unknown hold %s" % pose_id)
		return
	if _move_id != &"" or (_hold_id != &"" and _hold_id != pose_id):
		_start_xfade(maxf(blend_time, 0.05))
		_move_id = &""
		_hold_w = 1.0
	elif _hold_id != pose_id:
		_hold_w = 0.0
	if _hold_id != pose_id:
		charge_level = 0
	_hold_id = pose_id
	_hold_def = def
	_hold_w_target = 1.0
	_hold_blend = maxf(blend_time, 0.0)
	_hold_t = 0.0
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
	_move_id = &""
	_hold_id = &""
	_hold_w = 0.0
	_hold_w_target = 0.0

## Snap straight to the base layer with no blending (teleports, resets).
func reset_pose() -> void:
	_move_id = &""
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
		_:
			return f * f * (3.0 - 2.0 * f)

func _evaluate(dt: float) -> void:
	_time += dt
	_update_locomotion(dt)
	var legs_held: Array[bool] = [false, false]
	var hold_pose_now: PoseLibrary.Pose = null
	var charge_amp := 0.0
	# Hold layer.
	if _hold_id != &"":
		_hold_t += dt * loop_speed
		if _hold_blend > 0.0:
			_hold_w = move_toward(_hold_w, _hold_w_target, dt / _hold_blend)
		else:
			_hold_w = _hold_w_target
		hold_pose_now = _hold_pose_eval()
		var w := _hold_w * _hold_w * (3.0 - 2.0 * _hold_w)
		for i in LEG_START:
			var q = hold_pose_now.rot[i]
			if q != null:
				_layer_rot[i] = _layer_rot[i].slerp(q, w)
		if hold_pose_now.has_pos:
			_layer_pos = _layer_pos.lerp(hold_pose_now.pos, w)
		legs_held[0] = bool(hold_pose_now.defines_legs[0])
		legs_held[1] = bool(hold_pose_now.defines_legs[1])
		var tremble := float(_hold_def.get("tremble", 0.0))
		if _hold_def.get("charge", false):
			# Charge: the wind-up coils further and trembles harder per level.
			tremble = CHARGE_TREMBLE_BASE + CHARGE_TREMBLE_PER_LEVEL * charge_level
			var coil: Vector3 = _hold_def.get("coil", Vector3.ZERO)
			if coil != Vector3.ZERO and charge_level > 0:
				_layer_rot[2] = _layer_rot[2] * Quaternion.from_euler(coil * (PI / 180.0) * charge_level * w)
			_layer_pos.y -= CHARGE_SINK_PER_LEVEL * charge_level * w
		if tremble > 0.0:
			_apply_tremble(_layer_rot, deg_to_rad(tremble) * w)
			if _hold_def.get("charge", false):
				charge_amp = deg_to_rad(tremble) * w
		if _hold_w <= 0.0 and _hold_w_target <= 0.0:
			_hold_id = &""
	# Move layer (torso and arms; legs below).
	var ka: Array = []
	var kb: Array = []
	var f := 0.0
	var finished: StringName = &""
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
		while k < n - 2 and _move_t >= float(_keys[k + 1][0]):
			k += 1
		ka = _keys[k]
		kb = _keys[k + 1]
		var ta: float = ka[0]
		var tb: float = kb[0]
		f = _ease((_move_t - ta) / maxf(tb - ta, 0.0001), kb[3])
		for i in LEG_START:
			var qa := _key_rot(ka, i, _layer_rot[i])
			var qb := _key_rot(kb, i, _layer_rot[i])
			pose_rot[i] = qa.slerp(qb, f)
		hips_offset = _key_pos(ka, _layer_pos).lerp(_key_pos(kb, _layer_pos), f)
		if _move_t >= _move_end:
			finished = _move_id
	else:
		for i in LEG_START:
			pose_rot[i] = _layer_rot[i]
		hips_offset = _layer_pos
	# Legs: IK to the locomotion foot targets with the final hips, then the
	# hold and move layers on top.
	var hips_xf := Transform3D(Basis(pose_rot[HIPS_I]), HumanoidRig.REST[&"Hips"] + hips_offset)
	var yaw_b := Basis(Vector3.UP, _base_yaw)
	for side in 2:
		var pole := yaw_b * Vector3(0.12 if side == 1 else -0.12, 0.0, -1.0)
		var leg := PoseLibrary.leg_ik(hips_xf, side, _foot_targets[side], pole, _base_yaw, _foot_pitch[side])
		var base_i := LEG_START + side * 3
		for j in 3:
			var q: Quaternion = leg[j]
			if hold_pose_now != null and legs_held[side]:
				var hq = hold_pose_now.rot[base_i + j]
				if hq != null:
					var w := _hold_w * _hold_w * (3.0 - 2.0 * _hold_w)
					q = q.slerp(hq, w)
			if not ka.is_empty():
				q = _key_rot(ka, base_i + j, q).slerp(_key_rot(kb, base_i + j, q), f)
			pose_rot[base_i + j] = q
		if charge_amp > 0.0 and legs_held[side] and ka.is_empty():
			# A held kick charge trembles in the chambered leg too.
			var tt := _time + side * 3.1
			pose_rot[base_i] = pose_rot[base_i] * Quaternion.from_euler(Vector3(
				sin(tt * 101.0) * charge_amp, sin(tt * 83.0 + 1.0) * charge_amp, sin(tt * 109.0 + 2.0) * charge_amp))
	# Cross-fade.
	if _xfade_t < 1.0:
		_xfade_t = minf(_xfade_t + (dt / _xfade_dur if _xfade_dur > 0.0 else 1.0), 1.0)
		var w := _xfade_t * _xfade_t * (3.0 - 2.0 * _xfade_t)
		for i in HumanoidRig.BONE_COUNT:
			pose_rot[i] = _xfade_rot[i].slerp(pose_rot[i], w)
		hips_offset = _xfade_pos.lerp(hips_offset, w)
	_apply_broken_arms(dt)
	if finished != &"":
		_move_id = &""
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
					qq = qq.slerp(aq, _aim_w)
			var kw: float = key[4]
			return qq if kw >= 1.0 else below.slerp(qq, kw)
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
	return p

## Per-bone blend of two compiled poses (bones only one defines keep it).
static func _blend_poses(a: PoseLibrary.Pose, b: PoseLibrary.Pose, fr: float) -> PoseLibrary.Pose:
	var p := PoseLibrary.Pose.new()
	p.rot.resize(HumanoidRig.BONE_COUNT)
	for i in HumanoidRig.BONE_COUNT:
		var qa = a.rot[i]
		var qb = b.rot[i]
		if qa != null and qb != null:
			p.rot[i] = (qa as Quaternion).slerp(qb, fr)
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

func _update_locomotion(dt: float) -> void:
	# Stance weights (crouch / air) blend over STANCE_BLEND.
	var step := dt / STANCE_BLEND if STANCE_BLEND > 0.0 else 1.0
	_crouch_w = move_toward(_crouch_w, 1.0 if _stance_id == &"crouch" else 0.0, step)
	_air_w = move_toward(_air_w, 1.0 if _stance_id == &"air" else 0.0, step * 1.5)
	var cw := _crouch_w * _crouch_w * (3.0 - 2.0 * _crouch_w)
	var aw := _air_w * _air_w * (3.0 - 2.0 * _air_w)
	_loco_vel = _loco_vel.lerp(_loco_target, 1.0 - exp(-LOCO_SMOOTH * dt))
	var v := Vector2(_loco_vel.x, _loco_vel.z)
	var speed := v.length()
	var k := clampf(speed / (1.2 - 0.6 * cw), 0.0, 1.0)
	var run_k := clampf((speed - 2.6) / 1.8, 0.0, 1.0) * (1.0 - cw)
	var stride := clampf(0.35 + 0.15 * speed, 0.4, 1.1) * lerpf(1.0, CROUCH_WALK_STRIDE, cw)
	if speed > 0.05 and aw < 0.99:
		_phase = fmod(_phase + speed / (2.0 * stride) * TAU * dt, TAU)
	var dir := Vector3(v.x, 0.0, v.y) / speed if speed > 0.05 else Vector3(0, 0, -1)
	var fwd := -v.y / speed if speed > 0.05 else 0.0
	var lat := v.x / speed if speed > 0.05 else 0.0
	var s := sin(_phase)
	var lift := lerpf(0.09 + 0.07 * run_k, 0.05, cw)
	var half_w := lerpf(0.11, 0.18, cw)
	# Air: rising -> falling by vertical speed.
	var vy := _vy if is_nan(_vy_ext) else _vy_ext
	var fall_k := clampf((1.0 - vy) / 3.0, 0.0, 1.0)
	for side in 2:
		var ph := _phase + (PI if side == 1 else 0.0)
		var walk_base := Vector3(half_w if side == 1 else -half_w, 0.08, 0.0)
		var walk := walk_base + dir * (stride * 0.5) * sin(ph) + Vector3.UP * lift * maxf(0.0, cos(ph))
		var idle: Vector3 = _stance_feet[side].lerp(_crouch_feet[side], cw)
		var foot: Vector3 = idle.lerp(walk, k)
		var pitch := -0.35 * maxf(0.0, cos(ph)) * k
		if aw > 0.0:
			var air_foot: Vector3 = _rise_feet[side].lerp(_fall_feet[side], fall_k)
			foot = foot.lerp(air_foot, aw)
			pitch = lerpf(pitch, lerpf(_rise_pitch[side], _fall_pitch[side], fall_k), aw)
		_foot_targets[side] = foot
		_foot_pitch[side] = pitch
	var hips_yaw_deg := lerpf(lerpf(-15.0, -12.0, cw), 0.0, k) + 7.0 * s * k * fwd * (1.0 - cw)
	hips_yaw_deg *= 1.0 - aw
	_base_yaw = deg_to_rad(hips_yaw_deg)
	var bob := (0.02 + 0.035 * run_k) * k * (0.5 - 0.5 * cos(2.0 * _phase)) * lerpf(1.0, 0.5, cw)
	_layer_pos = _stance.pos.lerp(_crouch.pos, cw) + Vector3(0, -bob - 0.03 * run_k, 0)
	var yaw_q := Quaternion.from_euler(Vector3(0, _base_yaw, 0))
	_layer_rot[0] = yaw_q * Quaternion.IDENTITY.slerp(Quaternion.from_euler(Vector3(deg_to_rad(-18.0), 0, 0)), cw)
	var breath := sin(_time * TAU * 0.3) * deg_to_rad(1.5)
	_layer_rot[1] = Quaternion.from_euler(Vector3(deg_to_rad(-4.0 - 12.0 * run_k * fwd), 0, deg_to_rad(-5.0 * lat * k)))
	_layer_rot[2] = (_stance.rot[2] as Quaternion) * Quaternion(Vector3.RIGHT, breath)
	var chest_yaw_deg := -6.0
	_layer_rot[3] = Quaternion.from_euler(Vector3(deg_to_rad(6.0 + 6.0 * run_k), deg_to_rad(-(hips_yaw_deg + chest_yaw_deg)), 0))
	for i in range(4, LEG_START):
		_layer_rot[i] = _stance.rot[i]
	if run_k > 0.0:
		var pump_l := Quaternion.from_euler(Vector3(deg_to_rad(20.0 - 45.0 * s), 0, deg_to_rad(-12.0)))
		var pump_r := Quaternion.from_euler(Vector3(deg_to_rad(20.0 + 45.0 * s), 0, deg_to_rad(12.0)))
		var elbow := Quaternion(Vector3.RIGHT, deg_to_rad(95.0))
		_layer_rot[4] = _layer_rot[4].slerp(pump_l, run_k)
		_layer_rot[5] = _layer_rot[5].slerp(elbow, run_k)
		_layer_rot[7] = _layer_rot[7].slerp(pump_r, run_k)
		_layer_rot[8] = _layer_rot[8].slerp(elbow, run_k)
	if cw > 0.0:
		# Crouch: torso, head and guard arms from the compiled crouch pose.
		for i in range(1, LEG_START):
			var cq = _crouch.rot[i]
			if cq != null:
				_layer_rot[i] = _layer_rot[i].slerp(cq, cw)
	if aw > 0.0:
		var ap := _blend_poses(_jump_rise, _jump_fall, fall_k)
		for i in range(1, LEG_START):
			var q = ap.rot[i]
			if q != null:
				_layer_rot[i] = _layer_rot[i].slerp(q, aw)
		if ap.has_pos:
			_layer_pos = _layer_pos.lerp(ap.pos, aw)

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
