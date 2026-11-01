class_name RagdollController
extends Node
## Ragdoll state machine (spec: Ragdoll system > States) plus the per-bone
## torque loop (soft limits, neutral tension, muscles) run from ONE
## _physics_process per character through PhysicsServer3D RIDs.
## OWNER: agent A (rig & ragdoll). CONTRACT STUB: keep every public signature.
##
## How it works (agent A):
## - This node writes the skeleton pose every physics tick
##   (process_physics_priority -10: after PoseAnimator at -20, before the
##   Fighter at 0). ANIMATED: the animator pose. Simulating: the pose read from
##   the PhysicalBone3D bodies (blended with the animation in FLINCH).
## - Host contract: the host has a direct child CollisionShape3D "Capsule".
##   In full simulation (STAGGER after the legs give, LAUNCHED, GROUNDED,
##   DEAD) the capsule is disabled, the rig is set top_level so moving the host
##   never drags the bones, and the host is moved every tick to the pelvis XZ
##   on the floor (so host.global_position == get_ground_position()). On
##   get-up the host is teleported to the pelvis, turned to face the get-up
##   direction, the rig is re-parented to it and the capsule re-enabled.
##   FLINCH and partial STAGGER keep the capsule and move the host with a
##   small knock-back through host.move_and_slide() (the Fighter must not call
##   move_and_slide while is_simulating()).

enum State { ANIMATED, FLINCH, STAGGER, LAUNCHED, GROUNDED, GETUP, DEAD }

signal state_changed(old_state: int, new_state: int)
signal launched(velocity: Vector3)
signal landed()        ## First floor contact after a launch.
signal grounded()      ## Entered GROUNDED.
signal recovered()     ## Get-up finished, back to ANIMATED.
signal settled()       ## DEAD body came to rest and froze.

var state: int = State.ANIMATED
var profile: RagdollProfile
var host: CharacterBody3D
var rig: HumanoidRig
var active_muscles := true  ## false = passive ragdoll LOD (soft limits only)

var animator: PoseAnimator
## Start the get-up by itself once GROUNDED for getup_delay seconds.
var auto_getup := true
var getup_delay := 0.5          ## s lying still before the get-up (local tuning)

const GETUP_TIMES := Vector3(0.32, 0.16, 0.32)   ## startup/active/recovery of the get-up move (0.8 s total)
const GETUP_BLEND_MAX := 0.3                     ## ragdoll -> get-up blend (min with Tuning.GETUP_BLEND)
const LAUNCH_GROUNDED_FALLBACK := 6.0  ## s after a launch: GROUNDED whatever happens
const GETUP_MAX_PELVIS_SPEED := 1.5    ## wait for this before getting up
const GETUP_WAIT_MAX := 2.0
const DEAD_SETTLE_SPEED := 0.35
const DEAD_SETTLE_TIME := 0.6
const DEAD_SETTLE_TIMEOUT := 8.0
const FLINCH_PUSH := 0.9               ## m/s knock-back of the capsule on a flinch (strength 1)
const STAGGER_PUSH := 2.6              ## m/s knock-back on a stagger (strength 1)
const STAGGER_TIMEOUT := 1.4
const PUSH_DECEL := 3.2                ## m/s^2 the flinch/stagger knock-back slows by
const LAND_MIN_TIME := 0.12
const LAND_TONE_FADE := 0.3            ## s for the falling-loop tone to fade after landing
const AIR_RECOVER_BLEND := 0.15
const MAX_ANIM_SPEED := 14.0           ## clamp on per-bone velocity taken from animation
const FLOOR_RAY := 40.0

static var _active_slots := 0

# Physical body tables (index = position in Bones.PHYSICAL).
var _n := 0
var _pbs: Array[PhysicalBone3D] = []
var _rids: Array[RID] = []
var _states: Array = []                 # PhysicsDirectBodyState3D per body
var _mass := PackedFloat64Array()
var _skel_idx := PackedInt32Array()
var _phys_of := PackedInt32Array()      # skeleton bone index -> body index or -1
var _off: Array[Transform3D] = []
var _off_inv: Array[Transform3D] = []
var _sim := PackedByteArray()
var _severed := PackedByteArray()
var _tone := PackedFloat32Array()
var _xf: Array[Transform3D] = []
var _lv := PackedVector3Array()
var _av := PackedVector3Array()
var _hips_i := 0
var _chest_i := 2
var _head_i := 3
# Joints
var _jn := 0
var _j_child := PackedInt32Array()
var _j_parent := PackedInt32Array()
var _j_hinge := PackedByteArray()
var _j_bone := PackedInt32Array()
var _j_lim: Array = []                  # [Vector2 x, Vector2 y, Vector2 z] radians
var _j_inertia := PackedVector3Array()
var _j_neutral: Array[Quaternion] = []
# Pose output and history (for launch velocities)
var _out_rot: Array[Quaternion] = []
var _final_basis: Array[Basis] = []
var _rest_origin := PackedVector3Array()
var _hist_prev_rot: Array[Quaternion] = []
var _hist_cur_rot: Array[Quaternion] = []
var _hist_prev_hips := Vector3.ZERO
var _hist_cur_hips := Vector3.ZERO
var _hist_prev_xf := Transform3D()
var _hist_cur_xf := Transform3D()
var _hist_dt := 0.0
# State
var _rig_local := Transform3D.IDENTITY
var _full := false                      # full-body simulation (host follows)
var _partial := false                   # upper-body simulation
var _muscles_on := false
var _has_slot := false
var _state_t := 0.0
var _launch_time := INF
var _landed := false
var _land_time := 0.0
var _slow_time := 0.0
var _last_floor_y := 0.0
var _push_vel := Vector3.ZERO
var _flinch_w := 0.0
var _stagger_strength := 1.0
var _stagger_dir := Vector3.ZERO
var _stagger_full_t := 0.0
var _partial_w := 1.0
var _getup_move: StringName = &""
var _snap_rot: Array[Quaternion] = []
var _snap_hips := Vector3.ZERO
var _overlay_t := 1.0
var _overlay_dur := 0.0
var _dead_frozen := false
var _dead_still_t := 0.0
var _ignore_breakables := false
var _ray: PhysicsRayQueryParameters3D
var _flight_pose: StringName = &""
var _body_radius := PackedFloat32Array()   # bounding radius of each body's shape
# Hitstop freeze
var _hitstop_until := -1.0
var _hitstop_lv := PackedVector3Array()
var _hitstop_av := PackedVector3Array()
var _hitstop_on := false
var _rng := RandomNumberGenerator.new()
# Profiling (ms of the last physics tick spent in this controller).
var last_tick_ms := 0.0

## host: the fighter capsule. The ragdoll disables the host's capsule collision
## while simulating and re-enables it on get-up; the host's own capsule never
## collides with its bones (collision exceptions).
## Call after rig.build(). p_animator is required.
func setup(p_host: CharacterBody3D, p_rig: HumanoidRig, p_animator: PoseAnimator, p_active_muscles: bool) -> void:
	host = p_host
	rig = p_rig
	animator = p_animator
	active_muscles = p_active_muscles
	if profile == null:
		profile = RagdollProfile.realistic()
	process_physics_priority = -10
	rig.controller = self
	if animator:
		animator.drive_skeleton = false
		if animator.rig == null:
			animator.setup(rig)
	_rig_local = rig.transform
	_build_tables()
	for pb in _pbs:
		PhysicsServer3D.body_add_collision_exception(pb.get_rid(), host.get_rid())
		PhysicsServer3D.body_add_collision_exception(host.get_rid(), pb.get_rid())
	apply_profile()
	_ray = PhysicsRayQueryParameters3D.new()
	_ray.collision_mask = Layers.WORLD
	if host.is_inside_tree():
		_last_floor_y = host.global_position.y
	_rng.randomize()
	_reset_history()

## Re-apply profile values that live on the bodies (call after changing profile).
func apply_profile() -> void:
	for pb in _pbs:
		pb.angular_damp = profile.body_angular_damp

func _build_tables() -> void:
	_n = Bones.PHYSICAL.size()
	_pbs.clear(); _rids.clear(); _states.clear(); _off.clear(); _off_inv.clear(); _xf.clear()
	_mass.resize(_n); _skel_idx.resize(_n); _sim.resize(_n); _severed.resize(_n); _tone.resize(_n)
	_lv.resize(_n); _av.resize(_n)
	_phys_of.resize(HumanoidRig.BONE_COUNT)
	_phys_of.fill(-1)
	for i in _n:
		var bone: StringName = Bones.PHYSICAL[i]
		var pb := rig.get_physical_bone(bone)
		_pbs.append(pb)
		_rids.append(pb.get_rid())
		_states.append(null)
		_mass[i] = pb.mass
		var si := HumanoidRig.bone_index(bone)
		_skel_idx[i] = si
		_phys_of[si] = i
		var off := rig.get_body_offset(bone)
		_off.append(off)
		_off_inv.append(off.affine_inverse())
		_xf.append(Transform3D())
		_sim[i] = 0
		_severed[i] = 0
		_tone[i] = 0.0
	_body_radius.resize(_n)
	for i in _n:
		var r := 0.15
		var cs := _pbs[i].get_node_or_null(^"Shape") as CollisionShape3D
		if cs and cs.shape:
			var sh := cs.shape
			if sh is BoxShape3D:
				r = (sh as BoxShape3D).size.length() * 0.5
			elif sh is SphereShape3D:
				r = (sh as SphereShape3D).radius
			elif sh is CapsuleShape3D:
				r = (sh as CapsuleShape3D).height * 0.5
			r += cs.position.length()
		_body_radius[i] = r
	_hips_i = _phys_of[HumanoidRig.bone_index(Bones.HIPS)]
	_chest_i = _phys_of[HumanoidRig.bone_index(Bones.CHEST)]
	_head_i = _phys_of[HumanoidRig.bone_index(Bones.HEAD)]
	var neutral := PoseLibrary.get_pose(&"neutral")
	_jn = 0
	_j_child.clear(); _j_parent.clear(); _j_hinge.clear(); _j_bone.clear(); _j_lim.clear(); _j_inertia.clear(); _j_neutral.clear()
	for i in _n:
		var bone: StringName = Bones.PHYSICAL[i]
		if bone == Bones.HIPS:
			continue
		var spec: Dictionary = HumanoidRig.JOINT_LIMITS[bone]
		_j_child.append(i)
		_j_parent.append(_phys_of[HumanoidRig.bone_index(Bones.PARENT[bone])])
		_j_hinge.append(1 if spec["type"] == &"hinge" else 0)
		_j_bone.append(_skel_idx[i])
		var k := PI / 180.0
		_j_lim.append([spec["x"] * k, spec.get("y", Vector2.ZERO) * k, spec.get("z", Vector2.ZERO) * k])
		_j_inertia.append(rig.get_joint_inertia(bone))
		var nq = neutral.rot[_skel_idx[i]]
		_j_neutral.append(nq if nq != null else Quaternion.IDENTITY)
		_jn += 1
	_out_rot.resize(HumanoidRig.BONE_COUNT)
	_final_basis.resize(HumanoidRig.BONE_COUNT)
	_snap_rot.resize(HumanoidRig.BONE_COUNT)
	_rest_origin.resize(HumanoidRig.BONE_COUNT)
	for bi in HumanoidRig.BONE_COUNT:
		_rest_origin[bi] = rig.skeleton.get_bone_rest(bi).origin
		_out_rot[bi] = Quaternion.IDENTITY
		_snap_rot[bi] = Quaternion.IDENTITY

func _exit_tree() -> void:
	_release_slot()

# --- Public API ----------------------------------------------------------------
## Light hit: partial ragdoll of Bones.UPPER_BODY, influence 0.3 -> 0 over ~0.3 s.
func flinch(direction: Vector3, hit_bone: StringName, strength: float = 1.0) -> void:
	if rig == null:
		return
	match state:
		State.LAUNCHED, State.GROUNDED, State.DEAD:
			if _full and not _dead_frozen:
				_add_bone_velocity(_body_for(hit_bone), direction.normalized() * profile.flinch_dv * strength * 0.5)
			return
		State.GETUP, State.STAGGER:
			return
	var was_flinch := state == State.FLINCH
	if not was_flinch:
		_start_partial()
	_read_bodies()
	var dir := direction.normalized()
	var hb := _body_for(hit_bone)
	if not Bones.UPPER_BODY.has(Bones.PHYSICAL[hb]):
		hb = _chest_i
	_add_bone_velocity(hb, dir * profile.flinch_dv * strength)
	var parent_bone: StringName = Bones.PARENT.get(Bones.PHYSICAL[hb], &"")
	if Bones.UPPER_BODY.has(parent_bone):
		_add_bone_velocity(_phys_of[HumanoidRig.bone_index(parent_bone)], dir * profile.flinch_dv * strength * 0.5)
	_push_vel = Vector3(dir.x, 0, dir.z) * FLINCH_PUSH * strength
	for i in _n:
		_tone[i] = profile.flinch_tone if Bones.UPPER_BODY.has(Bones.PHYSICAL[i]) else 0.0
	_flinch_w = 0.3
	_partial_w = 0.3
	_state_t = 0.0
	if not was_flinch:
		_set_state(State.FLINCH)

## Medium hit: arms/spine go limp at once, legs over 0.5-1 s; tips into LAUNCHED
## past Tuning.STAGGER_TIP_ANGLE. strength < 1 recovers to ANIMATED after
## 0.3 + 0.45 * strength s; strength >= 1 makes the legs give way (the body
## falls and tips into LAUNCHED).
func stagger(direction: Vector3, strength: float = 1.0) -> void:
	if rig == null:
		return
	if state in [State.LAUNCHED, State.GROUNDED, State.DEAD, State.GETUP]:
		if state == State.LAUNCHED:
			add_velocity(direction.normalized() * profile.stagger_dv * 0.5 * strength)
		return
	if state == State.STAGGER:
		_stagger_strength = maxf(_stagger_strength, strength)
		return
	if state != State.FLINCH:
		_start_partial()
	_read_bodies()
	var dir := direction.normalized()
	_stagger_dir = Vector3(dir.x, 0, dir.z).normalized()
	_stagger_strength = strength
	for i in _n:
		var b: StringName = Bones.PHYSICAL[i]
		if b in [Bones.SPINE, Bones.CHEST, Bones.HEAD]:
			_add_bone_velocity(i, dir * profile.stagger_dv * strength)
			_tone[i] = profile.stagger_spine_tone
		elif Bones.UPPER_BODY.has(b):
			_add_bone_velocity(i, dir * profile.stagger_dv * strength * 0.6)
			_tone[i] = profile.stagger_arm_tone
		else:
			_tone[i] = profile.stagger_leg_tone
	_push_vel = _stagger_dir * STAGGER_PUSH * clampf(strength, 0.3, 1.5)
	_partial_w = 1.0
	_stagger_full_t = -1.0
	_state_t = 0.0
	if animator:
		animator.locked = true
		animator._hold(&"stagger", 0.08)
	_set_state(State.STAGGER)

## Full ragdoll. Every bone first gets its animated-pose velocity (difference
## of the last two animated poses), then `velocity` as a velocity change
## (impulse = bone mass * velocity), extra impulse at hit_bone, then limb spin.
## Calling launch() while already LAUNCHED re-launches (adds velocity).
func launch(velocity: Vector3, hit_point: Vector3, hit_bone: StringName = &"Chest") -> void:
	if rig == null:
		return
	if not _full:
		_enter_full()
	elif _dead_frozen:
		_unfreeze_dead()
	_read_bodies()
	_apply_launch_velocity(velocity, _body_for(hit_bone))
	var spd := velocity.length()
	if spd > 0.01:
		apply_limb_spin(velocity / spd, clampf(spd / 8.0, 0.25, 2.0))
	_launch_time = 0.0
	_landed = false
	_land_time = 0.0
	_slow_time = 0.0
	if state != State.DEAD:
		_acquire_slot()
		_set_tones(profile.launch_tone)
		if animator:
			animator.locked = true
			animator._hold(&"fall", 0.1)
		if state != State.LAUNCHED:
			_set_state(State.LAUNCHED)
	launched.emit(velocity)

## Add a velocity change to every simulated bone (pursuit relaunch, bowling).
## No effect on a body that is not fully simulating.
func add_velocity(dv: Vector3) -> void:
	if not _full:
		return
	if _dead_frozen:
		_unfreeze_dead()
	for i in _n:
		if _sim[i] and not _severed[i]:
			_add_bone_velocity(i, dv)

## Multiply every simulated bone's linear velocity (wall break absorption).
func scale_velocity(factor: float) -> void:
	if not (_full or _partial):
		return
	for i in _n:
		if _sim[i] and not _severed[i]:
			var v: Vector3 = PhysicsServer3D.body_get_state(_rids[i], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
			PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, v * factor)
			_lv[i] = v * factor
	if _hitstop_on:
		for i in _n:
			_hitstop_lv[i] *= factor

## V1 limb spin: upper arms spin against `direction`, thighs along it, +-25% random.
## Each limb rotates as a whole about its shoulder/hip; the net linear
## momentum this adds is removed again so the body's COM speed is unchanged.
func apply_limb_spin(direction: Vector3, strength: float = 1.0) -> void:
	if not _full or profile.limb_spin <= 0.0:
		return
	var d := direction.normalized()
	var added := Vector3.ZERO
	for root in [Bones.L_UPPER_ARM, Bones.R_UPPER_ARM, Bones.L_UPPER_LEG, Bones.R_UPPER_LEG]:
		var ri := _phys_of[HumanoidRig.bone_index(root)]
		if _severed[ri]:
			continue
		var joint: Vector3 = (_xf[ri] * _off_inv[ri]).origin
		var axis_dir: Vector3 = -_xf[ri].basis.y      # bone points -Y
		var is_arm: bool = root in [Bones.L_UPPER_ARM, Bones.R_UPPER_ARM]
		var want: Vector3 = -d if is_arm else d
		var omega := axis_dir.cross(want)
		omega *= profile.limb_spin * strength * (1.0 + _rng.randf_range(-profile.limb_spin_random, profile.limb_spin_random))
		for b in HumanoidRig.subtree(root):
			var bi := _phys_of[HumanoidRig.bone_index(b)]
			if bi < 0 or _severed[bi]:
				continue
			var dv := omega.cross(_xf[bi].origin - joint)
			_lv[bi] += dv
			_av[bi] += omega
			added += dv * _mass[bi]
			PhysicsServer3D.body_set_state(_rids[bi], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, _lv[bi])
			PhysicsServer3D.body_set_state(_rids[bi], PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, _av[bi])
	var m := get_total_mass()
	if m > 0.0:
		var corr := -added / m
		for i in _n:
			if _sim[i] and not _severed[i]:
				_add_bone_velocity(i, corr)

## Hitstop on a ragdoll: store and zero bone velocities for duration_real, then restore.
func freeze(duration_real: float) -> void:
	if not (_full or _partial) or _dead_frozen or duration_real <= 0.0:
		return
	var now := _now()
	if not _hitstop_on:
		_hitstop_lv.resize(_n)
		_hitstop_av.resize(_n)
		for i in _n:
			_hitstop_lv[i] = Vector3.ZERO
			_hitstop_av[i] = Vector3.ZERO
			if _sim[i] and not _severed[i]:
				_hitstop_lv[i] = PhysicsServer3D.body_get_state(_rids[i], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
				_hitstop_av[i] = PhysicsServer3D.body_get_state(_rids[i], PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
				PhysicsServer3D.body_set_param(_rids[i], PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE, 0.0)
		_hitstop_on = true
	_hitstop_until = maxf(_hitstop_until, now + duration_real)
	_zero_velocities()
	var tree := get_tree()
	if tree:
		var td := get_node_or_null(^"/root/TimeDirector")
		var timer: SceneTreeTimer = td.real_timer(duration_real + 0.001) if td and td.has_method(&"real_timer") \
				else tree.create_timer(duration_real + 0.001, true, false, true)
		timer.timeout.connect(_check_hitstop_end)

## While true, bones do not collide with Layers.DESTRUCTIBLE (ImpactResolver decides).
func set_ignore_breakables(ignore: bool) -> void:
	_ignore_breakables = ignore
	var mask := Layers.MASK_RAGDOLL & ~Layers.DESTRUCTIBLE if ignore else Layers.MASK_RAGDOLL
	for i in _n:
		_pbs[i].collision_mask = mask
		if not _sim[i] or _severed[i]:
			# A non-simulating PhysicalBone3D keeps layer/mask 0 on the server.
			PhysicsServer3D.body_set_collision_mask(_rids[i], 0)

## Air recovery: from LAUNCHED (after Tuning.AIR_RECOVERY_AFTER) flip upright and
## land on the feet. Returns false if not allowed right now.
## On success: ANIMATED immediately (emits state_changed and recovered), host
## upright at the body, capsule on, landing pose playing. If the body was high
## above the floor the capsule is left in the air: the Fighter's
## move_and_slide gravity brings it down.
func air_recover() -> bool:
	if state != State.LAUNCHED or _launch_time < Tuning.AIR_RECOVERY_AFTER or rig == null:
		return false
	_read_bodies()
	var com_v := get_com_velocity()
	var bodies := _bone_world_transforms()
	var pelvis: Vector3 = bodies[_hips_i].origin
	_stop_full_sim()
	var floor_y := _floor_y(pelvis)
	var hh := 0.95 * rig.height_scale
	var y := floor_y if pelvis.y - floor_y < hh + 0.35 else pelvis.y - hh
	var hb := host.global_basis.orthonormalized()
	host.global_transform = Transform3D(hb, Vector3(pelvis.x, y, pelvis.z))
	host.velocity = Vector3(com_v.x * 0.3, minf(com_v.y, 0.0) * 0.5, com_v.z * 0.3)
	_reattach_rig()
	_snapshot_from_bones(bodies)
	_overlay_t = 0.0
	_overlay_dur = AIR_RECOVER_BLEND
	if animator:
		animator.locked = false
		animator._cancel(0.0)
		animator._play(&"land", 0.0, 0.1, 0.3)
	_finish_to_animated()
	return true

## Killed: stays a ragdoll (launching it first if it was standing). When it
## settles, bones freeze into static bodies and `settled` fires.
func kill(velocity: Vector3 = Vector3.ZERO) -> void:
	if rig == null:
		return
	if state == State.DEAD:
		if velocity.length() > 0.01:
			add_velocity(velocity)
		return
	if not _full:
		var v := velocity
		if v.length() < 0.3:
			var back := host.global_basis.z if host else Vector3.BACK
			v = Vector3(back.x, 0, back.z).normalized() * 0.8 + Vector3(_rng.randf_range(-0.3, 0.3), 0, _rng.randf_range(-0.3, 0.3))
		launch(v, get_center_of_mass(), Bones.CHEST)
	elif velocity.length() > 0.01:
		add_velocity(velocity)
	_release_slot()
	_set_tones(0.0)
	if animator:
		animator.locked = true
		animator._hold(&"neutral", 0.2)
	_dead_frozen = false
	_dead_still_t = 0.0
	_state_t = 0.0
	_set_state(State.DEAD)

## Debug/restart: snap straight back to ANIMATED standing at the pelvis.
func force_recover() -> void:
	if rig == null:
		return
	var pelvis := rig.get_bone_global_position(Bones.HIPS)
	if _full or _partial:
		if _full:
			_read_bodies()
			pelvis = (_xf[_hips_i] * _off_inv[_hips_i]).origin
		if _full:
			_stop_full_sim()
		else:
			_stop_partial()
		if host.is_inside_tree():
			var floor_y := _floor_y(pelvis)
			host.global_position = Vector3(pelvis.x, floor_y, pelvis.z)
	_reattach_rig()
	_overlay_t = 1.0
	_dead_frozen = false
	if animator:
		animator.locked = false
		animator.reset_pose()
	_finish_to_animated()

func is_simulating() -> bool:
	return state in [State.FLINCH, State.STAGGER, State.LAUNCHED, State.GROUNDED, State.DEAD]

## True while the whole body simulates and the host follows the pelvis.
func is_full_ragdoll() -> bool:
	return _full

## Seconds since the last launch (INF if not launched). Game time.
func time_since_launch() -> float:
	if state in [State.LAUNCHED, State.GROUNDED, State.DEAD]:
		return _launch_time
	return INF

func get_total_mass() -> float:
	if rig == null:
		return 70.0
	var m := 0.0
	for i in _n:
		if not _severed[i]:
			m += _mass[i]
	return m

## Mass-weighted centre of the simulated bones; capsule centre when animated.
func get_center_of_mass() -> Vector3:
	if rig == null:
		return host.global_position + Vector3.UP if host else Vector3.ZERO
	if _full:
		# Live body positions (synced after every physics step), so callers get
		# the current value whatever their process order.
		var s := Vector3.ZERO
		var m := 0.0
		for i in _n:
			if not _severed[i]:
				s += _pbs[i].global_position * _mass[i]
				m += _mass[i]
		return s / m if m > 0.0 else host.global_position
	return rig.get_bone_global_position(Bones.HIPS) + Vector3.UP * 0.05 * rig.height_scale

## Sum(m_i v_i) / Sum(m_i) over simulated bones; capsule velocity when animated.
func get_com_velocity() -> Vector3:
	if rig == null or not _full:
		return host.velocity if host else Vector3.ZERO
	var s := Vector3.ZERO
	var m := 0.0
	for i in _n:
		if not _severed[i]:
			var st: PhysicsDirectBodyState3D = _states[i]
			s += (st.linear_velocity if st else _lv[i]) * _mass[i]
			m += _mass[i]
	return s / m if m > 0.0 else Vector3.ZERO

## World AABB of all physical bones (resolver sweep extent).
func get_bounds() -> AABB:
	if rig == null or not _full:
		var c := host.global_position if host else Vector3.ZERO
		var h := rig.get_height() if rig else 1.8
		return AABB(c - Vector3(0.35, 0.0, 0.35), Vector3(0.7, h, 0.7))
	# Each body contributes a sphere that encloses its whole collision shape
	# (capsule tips, foot toes, head), so the box covers every shape.
	var box := AABB(_pbs[_hips_i].global_position, Vector3.ZERO)
	for i in _n:
		if not _severed[i]:
			var r := Vector3.ONE * _body_radius[i]
			box = box.merge(AABB(_pbs[i].global_position - r, r * 2.0))
	return box.grow(0.02)

## Body position projected to the floor, valid in every state. Other modules
## must use this (via Fighter.get_ground_position) rather than host position
## while a body is in flight.
func get_ground_position() -> Vector3:
	if host == null:
		return Vector3.ZERO
	if _full and rig:
		var p := _pbs[_hips_i].global_position
		return Vector3(p.x, _last_floor_y, p.z)
	return host.global_position

## [linear, angular] world velocity of a bone (for severed pieces).
func get_bone_velocity(bone: StringName) -> Array:
	var i := _body_for(bone)
	if (_full or _partial) and _sim[i]:
		return [PhysicsServer3D.body_get_state(_rids[i], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY),
			PhysicsServer3D.body_get_state(_rids[i], PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)]
	var v := _history_velocities()
	return [v[0][i], v[1][i]]

## Called by HumanoidRig.sever(): take the subtree's bodies out of the ragdoll.
func on_bones_severed(bones: Array[StringName]) -> void:
	rig.break_joint(bones[0])
	for b in bones:
		var si := HumanoidRig.bone_index(b)
		var i := _phys_of[si]
		if i < 0:
			continue
		_severed[i] = 1
		_disable_body(i)

## Muscle target while LAUNCHED (e.g. &"wall_splat" while pinned to a
## wall); &"" restores the default falling loop / neutral after landing.
## Any PoseLibrary hold id or pose name works. Tone stays the launch tone,
## so a splat needs active muscles to show.
func set_flight_pose(pose_id: StringName) -> void:
	_flight_pose = pose_id
	if pose_id != &"" and state == State.LAUNCHED and _landed:
		_set_tones(profile.launch_tone)
		_land_time = 0.0

## Change the profile at runtime (lab).
func set_profile(p: RagdollProfile) -> void:
	profile = p
	apply_profile()
	if not profile.use_muscles:
		_release_slot()

# --- State machine -------------------------------------------------------------
func _set_state(s: int) -> void:
	if s == state:
		return
	var old := state
	state = s
	state_changed.emit(old, s)

func _physics_process(delta: float) -> void:
	if rig == null or host == null or animator == null:
		return
	var t0 := Time.get_ticks_usec()
	if _hitstop_on:
		if _now() >= _hitstop_until:
			_end_hitstop()
		else:
			if _full or _partial:
				_zero_velocities()
				_read_bodies()
				_write_physics_pose(_partial_w if _partial else 1.0)
			last_tick_ms = (Time.get_ticks_usec() - t0) / 1000.0
			return
	_state_t += delta
	match state:
		State.ANIMATED:
			_tick_animated(delta)
		State.FLINCH:
			_tick_flinch(delta)
		State.STAGGER:
			_tick_stagger(delta)
		State.LAUNCHED:
			_tick_launched(delta)
		State.GROUNDED:
			_tick_grounded(delta)
		State.GETUP:
			_tick_getup(delta)
		State.DEAD:
			_tick_dead(delta)
	last_tick_ms = (Time.get_ticks_usec() - t0) / 1000.0

func _tick_animated(delta: float) -> void:
	var hips := _anim_hips()
	if _overlay_t < 1.0:
		_overlay_t = minf(_overlay_t + (delta / _overlay_dur if _overlay_dur > 0.0 else 1.0), 1.0)
		var k := _overlay_t * _overlay_t * (3.0 - 2.0 * _overlay_t)
		for bi in HumanoidRig.BONE_COUNT:
			_out_rot[bi] = _snap_rot[bi].slerp(animator.pose_rot[bi], k)
		hips = _snap_hips.lerp(hips, k)
		rig.apply_pose(_out_rot, hips)
		_record_history(_out_rot, hips, delta)
	else:
		rig.apply_pose(animator.pose_rot, hips)
		_record_history(animator.pose_rot, hips, delta)

func _tick_flinch(delta: float) -> void:
	_read_bodies()
	_move_host_partial(delta)
	_follow_kinematic()
	_partial_w = _flinch_w * maxf(0.0, 1.0 - _state_t / Tuning.FLINCH_TIME)
	_apply_torques(active_muscles and profile.use_muscles)
	_write_physics_pose(_partial_w)
	_record_history(_out_rot, _out_hips(), delta)
	if _state_t >= Tuning.FLINCH_TIME:
		_stop_partial()
		_set_state(State.ANIMATED)

func _tick_stagger(delta: float) -> void:
	_read_bodies()
	var muscles := active_muscles and profile.use_muscles
	if not _full:
		_move_host_partial(delta)
		_follow_kinematic()
		var dur := 0.3 + 0.45 * clampf(_stagger_strength, 0.0, 1.0)
		var leg_t := lerpf(0.9, 0.5, clampf(_stagger_strength - 1.0, 0.0, 1.0))
		if _stagger_strength >= 1.0 and _state_t >= leg_t:
			_enter_full()
			_stagger_full_t = 0.0
			_acquire_slot()
			muscles = muscles and _has_slot
		elif _stagger_strength < 1.0:
			var fade := 0.2
			_partial_w = clampf((dur - _state_t) / fade, 0.0, 1.0)
			if _state_t > dur - fade:
				for i in _n:
					_tone[i] = lerpf(_tone[i], 1.0, 0.1)
		if not _full:
			_apply_torques(muscles)
			_write_physics_pose(_partial_w)
			_record_history(_out_rot, _out_hips(), delta)
			if _stagger_strength < 1.0 and _state_t >= dur:
				_stop_partial()
				if animator:
					animator.locked = false
					animator._release(0.15)
				_set_state(State.ANIMATED)
			return
	# Legs are giving way: full body, leg tone ramps down, tip -> LAUNCHED.
	_stagger_full_t += delta
	_follow_host()
	var k := clampf(_stagger_full_t / 0.45, 0.0, 1.0)
	for i in _n:
		var b: StringName = Bones.PHYSICAL[i]
		if not Bones.UPPER_BODY.has(b):
			_tone[i] = lerpf(profile.stagger_leg_tone, profile.launch_tone * 0.5, k)
	_apply_torques(muscles and _has_slot)
	_write_physics_pose(1.0)
	var up: Vector3 = _xf[_hips_i].basis.y
	var tilt := rad_to_deg(acos(clampf(up.dot(Vector3.UP), -1.0, 1.0)))
	if tilt > Tuning.STAGGER_TIP_ANGLE or _stagger_full_t > STAGGER_TIMEOUT:
		_launch_time = 0.0
		_landed = false
		_land_time = 0.0
		_slow_time = 0.0
		_set_tones(profile.launch_tone)
		if animator:
			animator._hold(&"fall", 0.15)
		_set_state(State.LAUNCHED)
		launched.emit(get_com_velocity())

func _tick_launched(delta: float) -> void:
	_launch_time += delta
	_read_bodies()
	_follow_host()
	if animator:
		var want: StringName = &"neutral" if _landed else &"fall"
		if _flight_pose != &"":
			want = _flight_pose
		if animator.get_hold_id() != want:
			animator._hold(want, 0.25 if _landed else 0.1)
		var vy: float = _lv[_hips_i].y
		animator.loop_speed = 1.0 + profile.fall_rate_by_vy * clampf(vy / 6.0, -1.0, 1.0)
	if _landed and _flight_pose == &"":
		# Landed: the falling-loop pull fades out (only soft limits and neutral
		# tension remain), so the body does not crawl along the floor.
		_set_tones(profile.launch_tone * maxf(0.0, 1.0 - _land_time / LAND_TONE_FADE))
	_apply_torques(_muscles_on and _tone[_chest_i] > 0.0)
	_write_physics_pose(1.0)
	var pelvis: Vector3 = _xf[_hips_i].origin
	var hips_h := pelvis.y - _last_floor_y
	if not _landed and _launch_time >= LAND_MIN_TIME:
		var low := INF
		for i in _n:
			if not _severed[i]:
				low = minf(low, _xf[i].origin.y)
		low -= _last_floor_y
		if hips_h < 0.55 or (low < 0.16 and _launch_time > 0.3 and hips_h < 0.8):
			_landed = true
			_land_time = 0.0
			landed.emit()
	if _landed:
		_land_time += delta
		if _lv[_hips_i].length() < Tuning.GROUNDED_SPEED:
			_slow_time += delta
		else:
			_slow_time = 0.0
		if _slow_time >= Tuning.GROUNDED_HOLD or _land_time >= Tuning.GROUNDED_TIMEOUT:
			_enter_grounded()
	elif _launch_time >= LAUNCH_GROUNDED_FALLBACK:
		_landed = true
		landed.emit()
		_enter_grounded()

func _enter_grounded() -> void:
	_release_slot()
	_set_tones(0.0)
	if animator:
		animator.loop_speed = 1.0
		animator._hold(&"neutral", 0.3)
	_state_t = 0.0
	_set_state(State.GROUNDED)
	grounded.emit()

func _tick_grounded(delta: float) -> void:
	_launch_time += delta
	_read_bodies()
	_follow_host()
	_apply_torques(false)
	_write_physics_pose(1.0)
	if auto_getup and _state_t >= getup_delay:
		if _lv[_hips_i].length() < GETUP_MAX_PELVIS_SPEED or _state_t >= getup_delay + GETUP_WAIT_MAX:
			start_getup()

## Begin the get-up now (from GROUNDED). Face up or down from the pelvis.
func start_getup() -> void:
	if state != State.GROUNDED:
		return
	_read_bodies()
	var bodies := _bone_world_transforms()
	var hips_b: Basis = bodies[_hips_i].basis
	var chest_b: Basis = bodies[_chest_i].basis
	var front := -(hips_b.z + chest_b.z)
	var face_up := front.y > 0.0
	var pelvis: Vector3 = bodies[_hips_i].origin
	var along: Vector3 = (bodies[_chest_i].origin - pelvis) * 1.0
	if not _severed[_head_i]:
		along = bodies[_head_i].origin - pelvis
	along.y = 0.0
	var facing := -along if face_up else along
	if facing.length() < 0.1:
		facing = Vector3(front.x, 0.0, front.z)
	if facing.length() < 0.01:
		facing = -host.global_basis.z
	facing = Vector3(facing.x, 0.0, facing.z).normalized()
	_stop_full_sim()
	var floor_y := _floor_y(pelvis)
	host.global_transform = Transform3D(Basis.looking_at(facing, Vector3.UP), Vector3(pelvis.x, floor_y, pelvis.z))
	host.velocity = Vector3.ZERO
	_reattach_rig()
	_snapshot_from_bones(bodies)
	_getup_move = &"getup_face_up" if face_up else &"getup_face_down"
	if animator:
		animator.locked = true
		animator.loop_speed = 1.0
		animator._cancel(0.0)
		animator._play(_getup_move, GETUP_TIMES.x, GETUP_TIMES.y, GETUP_TIMES.z)
	_state_t = 0.0
	rig.apply_pose(_snap_rot, _snap_hips)
	_set_state(State.GETUP)

func _tick_getup(delta: float) -> void:
	var hips := _anim_hips()
	var k := clampf(_state_t / maxf(minf(Tuning.GETUP_BLEND, GETUP_BLEND_MAX), 0.01), 0.0, 1.0)
	k = k * k * (3.0 - 2.0 * k)
	for bi in HumanoidRig.BONE_COUNT:
		_out_rot[bi] = _snap_rot[bi].slerp(animator.pose_rot[bi], k)
	hips = _snap_hips.lerp(hips, k)
	rig.apply_pose(_out_rot, hips)
	_record_history(_out_rot, hips, delta)
	var total := GETUP_TIMES.x + GETUP_TIMES.y + GETUP_TIMES.z
	if _state_t >= total or (_state_t > GETUP_BLEND_MAX and animator.get_current_move() != _getup_move):
		_finish_to_animated()

func _finish_to_animated() -> void:
	_flight_pose = &""
	if animator:
		animator.locked = false
	_launch_time = INF
	_set_state(State.ANIMATED)
	recovered.emit()

func _tick_dead(delta: float) -> void:
	_launch_time += delta
	if _dead_frozen:
		return
	_read_bodies()
	_follow_host()
	_apply_torques(false)
	_write_physics_pose(1.0)
	var fastest := 0.0
	for i in _n:
		if not _severed[i]:
			fastest = maxf(fastest, _lv[i].length())
	if fastest < DEAD_SETTLE_SPEED:
		_dead_still_t += delta
	else:
		_dead_still_t = 0.0
	if _dead_still_t >= DEAD_SETTLE_TIME or _state_t >= DEAD_SETTLE_TIMEOUT:
		_freeze_dead()

## Corpse: stop simulating, keep the pose, bones become static colliders.
func _freeze_dead() -> void:
	var bodies: Array[Transform3D] = []
	for i in _n:
		bodies.append(_xf[i])
	rig.simulator.physical_bones_stop_simulation()
	for i in _n:
		_sim[i] = 0
		if _severed[i]:
			continue
		_pbs[i].global_transform = bodies[i]
		PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_TRANSFORM, bodies[i])
		PhysicsServer3D.body_set_collision_layer(_rids[i], Layers.RAGDOLL)
		PhysicsServer3D.body_set_collision_mask(_rids[i], 0)
	_dead_frozen = true
	_record_history(_out_rot, _out_hips(), 0.0)
	_record_history(_out_rot, _out_hips(), 0.0)
	settled.emit()

func _unfreeze_dead() -> void:
	_dead_frozen = false
	_dead_still_t = 0.0
	_state_t = 0.0
	var bodies: Array[Transform3D] = []
	for i in _n:
		bodies.append(_xf[i])
	_start_sim([])
	for i in _n:
		if not _severed[i]:
			_teleport(i, bodies[i], Vector3.ZERO, Vector3.ZERO)

# --- Simulation start/stop ---------------------------------------------------------
func _start_partial() -> void:
	var xfs := _fk_bodies(_hist_cur_rot, _hist_cur_hips, rig.skeleton.global_transform)
	var vels := _history_velocities()
	_start_sim(Bones.UPPER_BODY)
	for i in _n:
		if _severed[i]:
			continue
		if _sim[i]:
			_teleport(i, xfs[i], vels[0][i], vels[1][i])
		else:
			_pbs[i].global_transform = xfs[i]
			PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_TRANSFORM, xfs[i])
			_xf[i] = xfs[i]
	_partial = true
	_full = false

func _stop_partial() -> void:
	rig.simulator.physical_bones_stop_simulation()
	rig.park_bodies()
	for i in _n:
		_sim[i] = 0
	_partial = false
	_push_vel = Vector3.ZERO

func _enter_full() -> void:
	var skel_xf := rig.skeleton.global_transform
	var xfs := _fk_bodies(_hist_cur_rot, _hist_cur_hips, skel_xf)
	var vels := _history_velocities()
	var keep_xf: Array[Transform3D] = []
	var keep_lv := PackedVector3Array()
	var keep_av := PackedVector3Array()
	var was := _sim.duplicate()
	if _partial:
		_read_bodies()
	for i in _n:
		keep_xf.append(_xf[i])
		keep_lv.append(_lv[i])
		keep_av.append(_av[i])
	if host.is_inside_tree():
		_last_floor_y = _floor_y(xfs[_hips_i].origin)
	rig.top_level = true
	_set_capsule(false)
	_start_sim([])
	var push := _push_vel
	for i in _n:
		if _severed[i]:
			continue
		if was[i]:
			_teleport(i, keep_xf[i], keep_lv[i], keep_av[i])
		else:
			_teleport(i, xfs[i], vels[0][i] + push, vels[1][i])
	_partial = false
	_full = true
	_push_vel = Vector3.ZERO
	_dead_frozen = false

func _stop_full_sim() -> void:
	rig.simulator.physical_bones_stop_simulation()
	rig.park_bodies()
	for i in _n:
		_sim[i] = 0
	_full = false
	_partial = false
	_release_slot()
	if _hitstop_on:
		_hitstop_on = false
		_hitstop_until = -1.0

## Start simulating `bones` (and their descendants; [] = whole body).
func _start_sim(bones: Array) -> void:
	var names: Array[StringName] = []
	for b in bones:
		names.append(b)
	rig.simulator.physical_bones_start_simulation(names)
	for i in _n:
		var on := names.is_empty()
		if not on:
			var b: StringName = Bones.PHYSICAL[i]
			for root in names:
				if b == root or _is_descendant(b, root):
					on = true
					break
		_sim[i] = 1 if on and not _severed[i] else 0
		_states[i] = PhysicsServer3D.body_get_direct_state(_rids[i])
		if _severed[i]:
			_disable_body(i)
		else:
			PhysicsServer3D.body_set_param(_rids[i], PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE, 1.0)
			if _sim[i]:
				PhysicsServer3D.body_set_enable_continuous_collision_detection(_rids[i], true)

static func _is_descendant(bone: StringName, root: StringName) -> bool:
	var p: StringName = Bones.PARENT.get(bone, &"")
	while p != &"":
		if p == root:
			return true
		p = Bones.PARENT.get(p, &"")
	return false

func _disable_body(i: int) -> void:
	_sim[i] = 0
	PhysicsServer3D.body_set_mode(_rids[i], PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(_rids[i], 0)
	PhysicsServer3D.body_set_collision_mask(_rids[i], 0)

func _teleport(i: int, xf: Transform3D, lv: Vector3, av: Vector3) -> void:
	_pbs[i].global_transform = xf
	PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, lv)
	PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, av)
	PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_SLEEPING, false)
	_xf[i] = xf
	_lv[i] = lv
	_av[i] = av

func _reattach_rig() -> void:
	rig.top_level = false
	rig.transform = _rig_local
	_set_capsule(true)
	if host.is_inside_tree():
		host.reset_physics_interpolation()

func _set_capsule(enabled: bool) -> void:
	var cap := host.get_node_or_null(^"Capsule") as CollisionShape3D
	if cap:
		cap.disabled = not enabled

func _acquire_slot() -> void:
	_muscles_on = false
	if not active_muscles or not profile.use_muscles:
		return
	if not _has_slot and _active_slots < Tuning.ACTIVE_RAGDOLL_MAX:
		_has_slot = true
		_active_slots += 1
	_muscles_on = _has_slot

func _release_slot() -> void:
	if _has_slot:
		_has_slot = false
		_active_slots = maxi(_active_slots - 1, 0)
	_muscles_on = false

func _set_tones(t: float) -> void:
	for i in _n:
		_tone[i] = t

# --- Per-tick physics helpers --------------------------------------------------------
func _read_bodies() -> void:
	for i in _n:
		if not _sim[i] or _severed[i]:
			continue
		var st: PhysicsDirectBodyState3D = _states[i]
		if st == null:
			st = PhysicsServer3D.body_get_direct_state(_rids[i])
			_states[i] = st
		_xf[i] = st.transform
		_lv[i] = st.linear_velocity
		_av[i] = st.angular_velocity

func _add_bone_velocity(i: int, dv: Vector3) -> void:
	if i < 0 or not _sim[i] or _severed[i]:
		return
	var cur: Vector3 = PhysicsServer3D.body_get_state(_rids[i], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	_lv[i] = cur + dv
	PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, _lv[i])
	PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_SLEEPING, false)

func _apply_launch_velocity(dv: Vector3, hit_i: int) -> void:
	var total := get_total_mass()
	var extra_p := Vector3.ZERO
	for i in _n:
		if not _sim[i] or _severed[i]:
			continue
		var add := dv
		if i == hit_i:
			add += dv * profile.hit_bone_extra
			extra_p += dv * profile.hit_bone_extra * _mass[i]
		if i == _hips_i:
			add += dv * profile.pelvis_extra
			extra_p += dv * profile.pelvis_extra * _mass[i]
		_add_bone_velocity(i, add)
	if total > 0.0:
		var corr := -extra_p / total
		for i in _n:
			if _sim[i] and not _severed[i]:
				_add_bone_velocity(i, corr)

func _zero_velocities() -> void:
	for i in _n:
		if _sim[i] and not _severed[i]:
			PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
			PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)

func _check_hitstop_end() -> void:
	if _hitstop_on and _now() >= _hitstop_until - 0.002:
		_end_hitstop()

func _end_hitstop() -> void:
	if not _hitstop_on:
		return
	_hitstop_on = false
	_hitstop_until = -1.0
	for i in _n:
		if _sim[i] and not _severed[i]:
			PhysicsServer3D.body_set_param(_rids[i], PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE, 1.0)
			PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, _hitstop_lv[i])
			PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, _hitstop_av[i])
			_lv[i] = _hitstop_lv[i]
			_av[i] = _hitstop_av[i]

func _now() -> float:
	var td := get_node_or_null(^"/root/TimeDirector")
	if td and td.has_method(&"now"):
		return td.now()
	return Time.get_ticks_usec() / 1_000_000.0

## Rotation vector (axis * angle) of the shortest rotation q.
static func _rotvec(q: Quaternion) -> Vector3:
	if q.w < 0.0:
		q = -q
	var v := Vector3(q.x, q.y, q.z)
	var s := v.length()
	if s < 0.000001:
		return v * 2.0
	return v * (2.0 * atan2(s, q.w) / s)

## Soft limit on one axis: returns Vector2(spring torque per unit inertia,
## damping coefficient c(theta) >= 0). c ramps 0 -> soft_limit_damping through
## the last soft_limit_zone of the range and acts on any motion there.
func _limit_axis(v: float, lim: Vector2) -> Vector2:
	var zone := maxf((lim.y - lim.x) * profile.soft_limit_zone, 0.01)
	var hi := lim.y - zone
	var lo := lim.x + zone
	if v > hi:
		var pen := minf((v - hi) / zone, 1.0)
		return Vector2(-profile.soft_limit_spring * (v - hi), profile.soft_limit_damping * pen * pen * (3.0 - 2.0 * pen))
	if v < lo:
		var pen := minf((lo - v) / zone, 1.0)
		return Vector2(profile.soft_limit_spring * (lo - v), profile.soft_limit_damping * pen * pen * (3.0 - 2.0 * pen))
	return Vector2.ZERO

## The torque loop: soft limits, neutral tension and muscles for every joint
## whose child body simulates. Torques are internal (equal and opposite on
## the parent), scaled by the joint's swing or twist inertia, and clamped.
## Every damping term is -c * I * (w . e) e on a single axis e, so it can only
## remove energy.
func _apply_torques(muscles: bool) -> void:
	var p := profile
	var tmax := p.max_torque * rig.mass_kg / 70.0
	var use_m := muscles and p.use_muscles
	var anim: Array[Quaternion] = animator.pose_rot
	for j in _jn:
		var c := _j_child[j]
		if not _sim[c] or _severed[c]:
			continue
		var pa := _j_parent[j]
		var rp: Basis = _xf[pa].basis
		var rp_t := rp.transposed()
		var q := Quaternion((rp_t * _xf[c].basis).orthonormalized())
		var ww: Vector3 = _av[c] - _av[pa]           # relative angular velocity, world
		var w: Vector3 = rp_t * ww                    # ... in the parent frame
		var ax: Vector3 = _xf[c].basis.y              # child bone axis (twist), world
		var w_ax := ww.dot(ax)
		var inert: Vector3 = _j_inertia[j]
		var i_s := (inert.x + inert.z) * 0.5
		var i_t := inert.y
		var tw := Vector3.ZERO
		if p.use_soft_limits:
			var lim: Array = _j_lim[j]
			if _j_hinge[j]:
				var lx := _limit_axis(_rotvec(q).x, lim[0])
				tw += rp.x * ((lx.x - lx.y * w.x) * i_s)
			else:
				var tq := Quaternion(0.0, q.y, 0.0, q.w)
				var tl := tq.length()
				var twist := 0.0
				var swing := q
				if tl > 0.000001:
					tq = tq / tl
					twist = wrapf(2.0 * atan2(tq.y, tq.w), -PI, PI)
					swing = q * tq.inverse()
				var sv := _rotvec(swing)
				var lx := _limit_axis(sv.x, lim[0])
				var ly := _limit_axis(twist, lim[1])
				var lz := _limit_axis(sv.z, lim[2])
				tw += rp.x * ((lx.x - lx.y * w.x) * i_s)
				tw += rp.z * ((lz.x - lz.y * w.z) * i_s)
				tw += ax * ((ly.x - ly.y * w_ax) * i_t)
		var err := Vector3.ZERO
		var kd := 0.0
		if p.use_neutral:
			err += _rotvec(_j_neutral[j] * q.inverse()) * p.neutral_kn
			kd += p.neutral_kd
		var tone := _tone[c]
		if use_m and tone > 0.0:
			err += _rotvec(anim[_j_bone[j]] * q.inverse()) * (p.muscle_kp * tone)
			kd += p.muscle_kd * tone
		if err != Vector3.ZERO or kd > 0.0:
			var ew: Vector3 = rp * err
			var ea := ax * ew.dot(ax)
			tw += (ew - ea) * i_s + ea * i_t
			var wa := ax * w_ax
			tw -= ((ww - wa) * i_s + wa * i_t) * kd
		var mag := tw.length()
		if mag > tmax:
			tw *= tmax / mag
		elif mag < 0.0001:
			continue
		var st: PhysicsDirectBodyState3D = _states[c]
		st.apply_torque(tw)
		if _sim[pa]:
			(_states[pa] as PhysicsDirectBodyState3D).apply_torque(-tw)

## Kinematic (non-simulated) bodies follow the animated pose during FLINCH /
## partial STAGGER.
func _follow_kinematic() -> void:
	var xfs := _fk_bodies(animator.pose_rot, _anim_hips(), rig.skeleton.global_transform)
	for i in _n:
		if _sim[i] or _severed[i]:
			continue
		_pbs[i].global_transform = xfs[i]
		PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_TRANSFORM, xfs[i])
		_xf[i] = xfs[i]

func _move_host_partial(delta: float) -> void:
	if not host.is_inside_tree():
		return
	var g := Tuning.GRAVITY
	var vy := host.velocity.y - g * delta if not host.is_on_floor() else -0.5
	host.velocity = Vector3(_push_vel.x, vy, _push_vel.z)
	host.move_and_slide()
	_push_vel = _push_vel.move_toward(Vector3.ZERO, PUSH_DECEL * delta)

## Full simulation: keep the host on the floor under the pelvis.
func _follow_host() -> void:
	var pelvis: Vector3 = _xf[_hips_i].origin
	var fy := _floor_y(pelvis)
	host.global_position = Vector3(pelvis.x, fy, pelvis.z)

func _floor_y(at: Vector3) -> float:
	if not host.is_inside_tree():
		return _last_floor_y
	var space := host.get_world_3d().direct_space_state
	_ray.from = at + Vector3.UP * 0.25
	_ray.to = at + Vector3.DOWN * FLOOR_RAY
	var hit := space.intersect_ray(_ray)
	if not hit.is_empty():
		_last_floor_y = (hit["position"] as Vector3).y
	return _last_floor_y

# --- Pose plumbing --------------------------------------------------------------------
func _anim_hips() -> Vector3:
	return rig.get_rest_hips_position() + animator.hips_offset * rig.height_scale

func _out_hips() -> Vector3:
	return rig.skeleton.get_bone_pose_position(0)

## World transforms of every bone that has a body (body * offset^-1).
func _bone_world_transforms() -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for i in _n:
		out.append(_xf[i] * _off_inv[i])
	return out

## Write the skeleton pose from the bodies; `weight` blends the simulated
## bones over the animated pose (1 = pure ragdoll).
func _write_physics_pose(weight: float) -> void:
	var sinv := rig.skeleton.global_transform.affine_inverse()
	var anim: Array[Quaternion] = animator.pose_rot
	var pidx := HumanoidRig.parent_indices()
	var hips := _anim_hips()
	for bi in HumanoidRig.BONE_COUNT:
		var local: Quaternion = anim[bi]
		var p := pidx[bi]
		var pg: Basis = _final_basis[p] if p >= 0 else Basis()
		var i := _phys_of[bi]
		if i >= 0 and _sim[i] and weight > 0.0 and not _severed[i]:
			var g := sinv * _xf[i] * _off_inv[i]
			var pl := Quaternion((pg.transposed() * g.basis).orthonormalized())
			local = pl if weight >= 1.0 else local.slerp(pl, weight)
			if bi == 0:
				hips = g.origin if weight >= 1.0 else hips.lerp(g.origin, weight)
		_final_basis[bi] = pg * Basis(local)
		_out_rot[bi] = local
	rig.apply_pose(_out_rot, hips)

## Convert world bone transforms (one per body) into a local pose for the
## current skeleton placement, into _snap_rot / _snap_hips.
func _snapshot_from_bones(bones_world: Array[Transform3D]) -> void:
	var sinv := rig.skeleton.global_transform.affine_inverse()
	var pidx := HumanoidRig.parent_indices()
	for bi in HumanoidRig.BONE_COUNT:
		var p := pidx[bi]
		var pg: Basis = _final_basis[p] if p >= 0 else Basis()
		var i := _phys_of[bi]
		var local := Quaternion.IDENTITY
		if i >= 0 and not _severed[i]:
			var g: Transform3D = sinv * bones_world[i]
			local = Quaternion((pg.transposed() * g.basis).orthonormalized())
			if bi == 0:
				_snap_hips = g.origin
		elif bi < animator.pose_rot.size():
			local = animator.pose_rot[bi] if Bones.ALL[bi] in [Bones.L_HAND, Bones.R_HAND] else _out_rot[bi]
		_final_basis[bi] = pg * Basis(local)
		_snap_rot[bi] = local
	_record_history(_snap_rot, _snap_hips, 0.0)
	_record_history(_snap_rot, _snap_hips, 0.0)

func _reset_history() -> void:
	var rots: Array[Quaternion] = animator.pose_rot.duplicate() if animator else _out_rot.duplicate()
	var hips := _anim_hips() if animator else rig.get_rest_hips_position()
	_hist_prev_rot = rots.duplicate()
	_hist_cur_rot = rots.duplicate()
	_hist_prev_hips = hips
	_hist_cur_hips = hips
	var xf := _nominal_skeleton_xf() if rig.skeleton.is_inside_tree() else rig.skeleton.transform
	_hist_prev_xf = xf
	_hist_cur_xf = xf
	_hist_dt = 0.0

func _record_history(rots: Array[Quaternion], hips: Vector3, dt: float) -> void:
	var tmp := _hist_prev_rot
	_hist_prev_rot = _hist_cur_rot
	_hist_cur_rot = tmp
	for bi in HumanoidRig.BONE_COUNT:
		_hist_cur_rot[bi] = rots[bi]
	_hist_prev_hips = _hist_cur_hips
	_hist_cur_hips = hips
	_hist_prev_xf = _hist_cur_xf
	_hist_cur_xf = _nominal_skeleton_xf()
	_hist_dt = dt

## Skeleton placement without any cosmetic offset the host puts on the rig
## (the Fighter jitters rig.position during hitstop; that must not turn into
## launch velocity).
func _nominal_skeleton_xf() -> Transform3D:
	if rig.top_level or not host.is_inside_tree():
		return rig.skeleton.global_transform
	return host.global_transform * _rig_local * rig.skeleton.transform

## World transforms of all bodies for a local pose at skeleton transform skel_xf.
func _fk_bodies(rots: Array[Quaternion], hips: Vector3, skel_xf: Transform3D) -> Array[Transform3D]:
	var g: Array[Transform3D] = []
	g.resize(HumanoidRig.BONE_COUNT)
	var pidx := HumanoidRig.parent_indices()
	for bi in HumanoidRig.BONE_COUNT:
		var local := Transform3D(Basis(rots[bi]), hips if bi == 0 else _rest_origin[bi])
		g[bi] = (g[pidx[bi]] if pidx[bi] >= 0 else skel_xf) * local
	var out: Array[Transform3D] = []
	for i in _n:
		out.append(g[_skel_idx[i]] * _off[i])
	return out

## Per-body [linear, angular] velocities from the last two recorded poses.
func _history_velocities() -> Array:
	var lin := PackedVector3Array()
	var ang := PackedVector3Array()
	lin.resize(_n)
	ang.resize(_n)
	if _hist_dt <= 0.0:
		return [lin, ang]
	var a := _fk_bodies(_hist_prev_rot, _hist_prev_hips, _hist_prev_xf)
	var b := _fk_bodies(_hist_cur_rot, _hist_cur_hips, _hist_cur_xf)
	for i in _n:
		lin[i] = ((b[i].origin - a[i].origin) / _hist_dt).limit_length(MAX_ANIM_SPEED)
		ang[i] = (_rotvec(Quaternion((b[i].basis * a[i].basis.transposed()).orthonormalized())) / _hist_dt).limit_length(30.0)
	return [lin, ang]

func _body_for(bone: StringName) -> int:
	var b := bone
	while b != &"":
		var si := HumanoidRig.bone_index(b)
		if si >= 0 and _phys_of[si] >= 0 and not _severed[_phys_of[si]]:
			return _phys_of[si]
		b = Bones.PARENT.get(b, &"")
	return _chest_i
