class_name RagdollController
extends Node
## Ragdoll state machine (spec: Ragdoll system > States) plus the per-bone
## torque loop (soft limits, neutral tension, muscles) run from ONE
## _physics_process per character through PhysicsServer3D RIDs.
## OWNER: agent A (rig & ragdoll). CONTRACT STUB: keep every public signature.
##
## Pose and host:
## - This node writes the skeleton pose every physics tick
##   (process_physics_priority -10: after PoseAnimator at -20, before the
##   Fighter at 0).
## - Host contract: the host has a direct child CollisionShape3D "Capsule".
##   In full simulation (LAUNCHED, GROUNDED, DEAD, held) the capsule is
##   disabled, the rig is set top_level so moving the host never drags the
##   bones, and the host is moved every tick to the pelvis XZ on the floor
##   (so host.global_position == get_ground_position()). On get-up the host is
##   teleported to the pelvis, turned to face the get-up direction, the rig is
##   re-parented to it and the capsule re-enabled.
## - FLINCH and STAGGER (stagger and stumble) keep the capsule; this node moves
##   the host with the reaction's push through host.move_and_slide() and feeds
##   that motion to the animator's locomotion (the stumble steps). The Fighter
##   must not call move_and_slide while is_simulating().
##
## Round 5 partial ragdolls (Feel Reference: Partial ragdoll reactions):
## - Per-bone muscle strength. limp_chain() hands a chain of bones to physics:
##   strength = 1 - physics_amount, fading back to 1. Only the chain bones and
##   their descendants simulate (the descendants at full strength, shown with
##   their animated local rotation); every other bone is kinematic and tracks
##   the animation exactly. get_bone_strength() reports it. A chain bone shows
##   its physics pose until its physics share drops under CHAIN_BLEND_OUT,
##   then crossfades back to the animation, so nothing pops.
## - limp_chain() on a standing fighter keeps state ANIMATED: the fighter keeps
##   moving and attacking with, say, one limp arm.
## - Reactions by tier (Tuning.REACT_*): flinch() = the hit chain only
##   (hit_chain()); stumble() = the hit leg from the knee down + side steps;
##   stagger() = spine and up + both arms, legs animated, pushed back, never
##   tips into a launch; knockdown() = full body, low tone, drops in place;
##   launch() = full body, very low tone, limb spin. Stumbles use State.STAGGER
##   (get_reaction_kind() tells them apart).
## - Ground time before the get-up: set_getup_after(s) (any time before or
##   during the knockdown / launch; it wins over the default), else a random
##   value in the tier's Tuning.REACT_*.ground range, counted from the first
##   floor contact. The player uses Tuning.PLAYER_GETUP_AFTER counted from the
##   hit, and a fast get-up (GETUP_TIMES_FAST).
##
## Contact frame and hitstop (B and H rely on this):
## - Every tick this node polls host.is_frozen() (the Fighter's hitstop) and
##   honours freeze(). While frozen, every simulating bone is HELD: its
##   velocity is stashed and zeroed, gravity is off, torques and reaction
##   timers stop, and the visual jitters 2-4 cm (Tuning.HITSTOP_JITTER_RANGE)
##   when the hold began with a reaction. When the freeze ends the stashed
##   velocities come back and gravity returns.
## - Animation history (the last two animated poses, from which every bone's
##   starting velocity is taken) is never recorded while the host is frozen,
##   so the cache always holds the last two poses BEFORE the freeze (a frozen
##   animation would give zero).
## - Reactions apply at once: the state changes immediately, each newly
##   simulated bone starts with its cached animation velocity plus the
##   reaction impulse. During a hold those velocities go into the stash.
## - So the call order does not matter. Reaction then TimeDirector.hitstop()
##   in the same frame, hitstop then reaction, or a reaction during the
##   freeze: the victim holds its contact pose for the freeze, then moves off
##   with cached animation velocity + impulse. (If one physics step ran
##   between the reaction and the start of the hold, the bodies are put back
##   to their contact transforms.)
## - A limb severed during the hold waits frozen at the stump and flies off
##   with the bone's stashed velocity when the hold ends; a limb severed in the
##   same frame just before a launch() also gets that launch's velocity.
##
## Bodies stay (Round 5): on kill() the bones move to Layers.DEAD_BODY /
## MASK_DEAD_BODY (walking capsules ignore them). A dead body freezes into
## static colliders after Tuning.DEAD_FREEZE_AFTER s at rest (sooner when more
## than DEAD_AWAKE_MAX corpses are awake); a frozen body costs nothing (this
## node stops processing; a dead body's animator stops at death). wake() /
## nudge() / begin_held() / launch() / add_velocity() unfreeze it; it
## refreezes after DEAD_REFREEZE_AFTER s at rest.
##
## Held bodies (Round 5, Carry): begin_held() pins a bone to a hand node with
## a velocity motor (strong but force-limited, so walls stop it instead of
## snagging), the rest dangles with low tone (a live body struggles weakly in
## the "held" pose, a dead one is limp), bones are capped at 18 m/s and the
## held body never collides with the holder.

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
var active_muscles := true  ## false = passive ragdoll LOD in flight (soft limits only); partial reactions always use muscles

var animator: PoseAnimator
## Start the get-up by itself once the ground time is over.
var auto_getup := true

const GETUP_TIMES := Vector3(0.32, 0.16, 0.32)        ## startup/active/recovery of the get-up move (0.8 s total)
## Player: a fast get-up (0.24 s) so a knockdown is acted out of in about 1.1 s
## (Feel Reference F8: "act again within 1.1 s" after 0.8 s on the ground).
const GETUP_TIMES_FAST := Vector3(0.09, 0.05, 0.10)
const GETUP_BLEND_MAX := 0.3                          ## ragdoll -> get-up blend (min with Tuning.GETUP_BLEND)
const GETUP_BLEND_FAST := 0.08                        ## player
const LAUNCH_GROUNDED_FALLBACK := 6.0  ## s after a launch: GROUNDED whatever happens
const GETUP_MAX_PELVIS_SPEED := 1.5    ## wait for this before getting up...
const GETUP_WAIT_MAX := 2.0            ## ...at most this long
const PLAYER_GETUP_HIPS := 0.75        ## m: the player's ground time is up and the pelvis is this low: down enough to get up
const DEAD_SETTLE_SPEED := 0.35        ## m/s: every bone under this = at rest
const DEAD_QUIET_AFTER := 0.3          ## s at rest before a corpse's torques stop (lets Jolt sleep it)
## s at rest before a corpse that was already frozen once (woken by a nudge,
## a throw, a grab) freezes again; the first settle keeps Tuning.DEAD_FREEZE_AFTER (perf).
const DEAD_REFREEZE_AFTER := 1.0
const DEAD_WAKE_SPEED := 1.0
## m/s: only a knock this hard brings a quiet corpse's soft limits back. Below
## it the corpse stays quiet: when the torques stop, a head or leg slumps onto
## its hard limit (up to ~1.1 m/s); re-enabling the torques for that lifted it
## back and the body nodded until the awake timeout.
const DEAD_KNOCK_SPEED := 3.0           ## m/s: a quiet corpse counts as moving again only above this (its limbs sag a little when the torques stop)
const DEAD_AWAKE_MAX := 6              ## awake (unfrozen) corpses at once; over it a resting one freezes early (perf)
const DEAD_EARLY_FREEZE := 0.5         ## s at rest before an over-the-cap corpse freezes
const DEAD_AWAKE_TIMEOUT := 12.0       ## s awake at most (a pile that never quite stops)
const FLINCH_PUSH_DIST := 0.04         ## m the capsule slides on a flinch (strength 1): no step
const HEAD_TWIST := 10.0               ## rad/s a sideways head hit turns the head (a hook turns it sideways)
const CHAIN_BLEND_OUT := 0.2           ## below this physics share a chain bone crossfades back to the animation
const RESTORE_FADE := 0.12             ## s restore_chain() takes
const STUMBLE_DV := 2.5                ## m/s on the swept shin
const STUMBLE_BUCKLE := 7.0            ## rad/s the swept knee folds
const STUMBLE_DIST := 0.7              ## m covered by the 2-3 side steps
const STUMBLE_FADE := 0.1              ## s the swept shin takes to come back after its hold
const KNOCKDOWN_DV := 2.2              ## m/s the upper body tips over in the hit direction...
const KNOCKDOWN_HIPS := 0.8            ## ...the pelvis follows a little...
const KNOCKDOWN_DROP := 1.0            ## ...and drops (m/s down); the feet stay planted
const LAND_MIN_TIME := 0.12
const LAND_TONE_FADE := 0.3            ## s for the falling-loop tone to fade after landing
const AIR_RECOVER_BLEND := 0.15
const MAX_ANIM_SPEED := 14.0           ## clamp on per-bone velocity taken from animation
const FLOOR_RAY := 40.0
const BROKEN_SHOULDER_EXTRA := 30.0    ## deg a broken shoulder's limits widen (each side)
const BROKEN_ELBOW_EXTRA := 15.0       ## deg past full flexion for a broken elbow
const BROKEN_ELBOW_HYPER := 40.0       ## deg of hyperextension a broken elbow allows
const GRIP_SPEED_CAP := 18.0           ## m/s clamp on bones while gripped / held (Tuning.LAUNCH_SPEED_MAX)
const GRIP_SPIN_CAP := 35.0            ## rad/s
const GRIP_FIX := 0.6                  ## fraction of a joint gap closed per pass while gripped / held
const GRIP_FIX_ITERS := 2              ## passes per tick (gripped / held bodies only)
const GRIP_FIX_MIN := 0.01             ## m: gaps below this are left to Jolt
const HELD_POS_GAIN := 22.0            ## 1/s: pin point error -> extra target speed
const HELD_MAX_ACCEL := 320.0          ## m/s^2 the pin motor may change the pinned body's speed by
const HELD_ROT_GAIN := 9.0             ## 1/s: torso grabs keep the body upright, facing the holder
const HELD_MAX_SPIN_ACCEL := 220.0     ## rad/s^2
const HELD_LIMB_MASS_MULT := 6.0       ## a pinned limb (< 5 kg) is this much heavier while held (joint stability)
const HELD_TORSO_MASS_MULT := 3.0      ## a pinned torso / head is this much heavier while held (whipping legs move it less)
## Held bodies are clamped to this at the start of each tick, so the joint
## impulses inside the physics step keep them under Tuning.LAUNCH_SPEED_MAX (18).
const HELD_SPEED_CAP := 16.0
## 1/s: every held bone's velocity relative to the hand decays at this rate
## (the holder's arm and body soak up the swing): the body still swings with
## every start, stop and hop, but a swing about the hand settles in ~1 s.
const HELD_SWING_DAMP := 1.5
const HELD_PIN_DEPTH := 0.6            ## pin point: this share of the body's radius from its centre toward the hand

static var _active_slots := 0
static var _awake_dead := 0

# Physical body tables (index = position in Bones.PHYSICAL).
var _n := 0
var _pbs: Array[PhysicalBone3D] = []
var _rids: Array[RID] = []
var _states: Array = []                 # PhysicsDirectBodyState3D per body
var _mass := PackedFloat64Array()
var _skel_idx := PackedInt32Array()
var _phys_of := PackedInt32Array()      # skeleton bone index -> body index or -1
var _parent_body := PackedInt32Array()  # body index -> parent body index (-1 for the hips)
var _off: Array[Transform3D] = []
var _off_inv: Array[Transform3D] = []
var _sim := PackedByteArray()
var _severed := PackedByteArray()
var _tone := PackedFloat32Array()
var _amt := PackedFloat32Array()        # physics share of a chain bone (0 = not in a chain)
var _amt_rate := PackedFloat32Array()   # per second it fades by (0 = held until restore_chain)
var _amt_hold := PackedFloat32Array()   # s it holds before fading
var _w := PackedFloat32Array()          # display weight of the physics pose (partial)
var _xf: Array[Transform3D] = []
var _lv := PackedVector3Array()
var _av := PackedVector3Array()
var _hips_i := 0
var _chest_i := 2
var _head_i := 3
var _body_radius := PackedFloat32Array()   # bounding radius of each body's shape
# Joints
var _jn := 0
var _j_child := PackedInt32Array()
var _j_parent := PackedInt32Array()
var _j_hinge := PackedByteArray()
var _j_bone := PackedInt32Array()
var _j_lim: Array = []                  # [Vector2 x, Vector2 y, Vector2 z] radians
var _j_inertia := PackedVector3Array()
var _j_neutral: Array[Quaternion] = []
var _j_limp := PackedByteArray()          # joint muscles/tension off (broken arm)
# Pose output and history (for reaction velocities)
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
var _partial := false                   # some chains simulate, the rest is kinematic
var _muscles_on := false
var _has_slot := false
var _state_t := 0.0
var _launch_time := INF
var _landed := false
var _land_time := 0.0
var _slow_time := 0.0
var _last_floor_y := 0.0
var _push_vel := Vector3.ZERO
var _push_decel := 0.0
var _react_left := 0.0                  # s left in FLINCH / STAGGER
var _react_kind: StringName = &""       # &"flinch" | &"stumble" | &"stagger" | &"knockdown" | &"launch"
var _anim_locked_by_reaction := false
var _getup_move: StringName = &""
var _getup_total := 0.8
var _getup_blend := 0.3
var _snap_rot: Array[Quaternion] = []
var _snap_hips := Vector3.ZERO
var _overlay_t := 1.0
var _overlay_dur := 0.0
var _dead_frozen := false
var _dead_still_t := 0.0
var _dead_awake_t := 0.0
var _counted_awake := false
var _was_frozen := false                  # this corpse has frozen before (refreezes sooner)
var _dead_quiet := false                  # torques off at rest (sticky until a real knock)
var _ignore_breakables := false
var _ray: PhysicsRayQueryParameters3D
var _flight_pose: StringName = &""
var _gripped := false
## Gripped/held-only joint drift fix (tests and the lab switch it off to compare).
var grip_fix_enabled := true
var _clock := 0.0                         # game seconds since setup (monotonic, stops in hitstop)
var _getup_not_before := 0.0              # delay_getup(): no get-up before this _clock time
var _ground_time := 2.0                   # s on the ground before the get-up
var _ground_set_frame := -100             # physics frame of the last set_getup_after()
var _ground_t := 0.0                      # s counted toward _ground_time
var _ground_from_hit := false             # player: count from the hit (real time), not the landing
var _down_at := 0.0                       # TimeDirector.now() of the hit that put the player down
var _arm_broken := [false, false]
# Hitstop hold
var _frozen_now := false
var _hitstop_until := -1.0
var _hitstop_lv := PackedVector3Array()
var _hitstop_av := PackedVector3Array()
var _hitstop_on := false
var _jitter_amp := 0.0
var _react_frame := -100
var _react_jitter := 0.0
var _react_xf: Array[Transform3D] = []
var _hold_xf: Array[Transform3D] = []     # where each held body is pinned during the hold
var _hold_pieces: Array = []              # [RigidBody3D, linear, angular] severed during a hold
var _fresh_pieces: Array = []             # [RigidBody3D, physics frame, spawn transform] severed this or last frame
# Held by a grabber
var _held := false
var _held_i := -1
var _held_hand: Node3D
var _held_holder: Node3D
var _held_local := Vector3.ZERO
var _held_orient := false
var _held_prev_hand := Vector3.INF
var _held_mass_set := false
var _held_exc: Array[RID] = []
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
## Touches angular damping only, never mass: a limb grab (agent G) scales the
## held limb's server mass while gripped, and this controller's mass table
## (_mass, read once in setup) stays the source of truth for COM and energy.
func apply_profile() -> void:
	for pb in _pbs:
		pb.angular_damp = profile.body_angular_damp

func _build_tables() -> void:
	_n = Bones.PHYSICAL.size()
	_pbs.clear(); _rids.clear(); _states.clear(); _off.clear(); _off_inv.clear(); _xf.clear(); _react_xf.clear(); _hold_xf.clear()
	_mass.resize(_n); _skel_idx.resize(_n); _sim.resize(_n); _severed.resize(_n); _tone.resize(_n)
	_amt.resize(_n); _amt_rate.resize(_n); _amt_hold.resize(_n); _w.resize(_n); _parent_body.resize(_n)
	_lv.resize(_n); _av.resize(_n); _hitstop_lv.resize(_n); _hitstop_av.resize(_n)
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
		_react_xf.append(Transform3D())
		_hold_xf.append(Transform3D())
		_sim[i] = 0
		_severed[i] = 0
		_tone[i] = 0.0
		_amt[i] = 0.0
		_amt_rate[i] = 0.0
		_amt_hold[i] = 0.0
		_w[i] = 0.0
	for i in _n:
		var bone: StringName = Bones.PHYSICAL[i]
		_parent_body[i] = _phys_of[HumanoidRig.bone_index(Bones.PARENT[bone])] if Bones.PARENT.has(bone) else -1
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
	_j_limp.clear()
	for i in _n:
		var bone: StringName = Bones.PHYSICAL[i]
		if bone == Bones.HIPS:
			continue
		var spec: Dictionary = HumanoidRig.JOINT_LIMITS[bone]
		_j_child.append(i)
		_j_parent.append(_parent_body[i])
		_j_hinge.append(1 if spec["type"] == &"hinge" else 0)
		_j_bone.append(_skel_idx[i])
		var k := PI / 180.0
		_j_lim.append([spec["x"] * k, spec.get("y", Vector2.ZERO) * k, spec.get("z", Vector2.ZERO) * k])
		_j_inertia.append(rig.get_joint_inertia(bone))
		var nq = neutral.rot[_skel_idx[i]]
		_j_neutral.append(nq if nq != null else Quaternion.IDENTITY)
		_j_limp.append(0)
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
	_register_awake(false)
	if _held:
		end_held()

# --- Public API: reactions ------------------------------------------------------
## Flinch tier (Tuning.REACT_FLINCH): the hit chain only (hit_chain(hit_bone):
## head; or that arm's upper + lower arm; or spine + chest) goes 60% physical,
## fading to 0 over 0.25 s; impulse at the hit bone along the strike
## direction (a sideways head hit also turns the head); a tiny slide, no
## step. On a full ragdoll it nudges the hit bone (ground strikes).
func flinch(direction: Vector3, hit_bone: StringName, strength: float = 1.0) -> void:
	if rig == null:
		return
	var dir := direction.normalized() if direction.length_squared() > 1e-6 else -_host_forward()
	var s := clampf(strength, 0.2, 2.0)
	match state:
		State.LAUNCHED, State.GROUNDED, State.DEAD:
			if _full and not _dead_frozen:
				_read_bodies()
				_add_bone_velocity(_body_for(hit_bone), dir * profile.flinch_dv * s * 0.5)
				_note_reaction(_jitter_for(&"flinch"))
			return
		State.GETUP:
			return
	_read_bodies()
	var chain := hit_chain(hit_bone)
	if _body(chain[0]) >= 0 and _severed[_body(chain[0])]:
		chain = hit_chain(Bones.CHEST)   # the limb is gone: the hit lands on the body
		hit_bone = Bones.CHEST
	var r: Dictionary = Tuning.REACT_FLINCH
	_limp(chain, r["physics"], r["fade"], 0.0)
	var hb := _body_for(hit_bone)
	if hb < 0 or not _sim[hb]:
		hb = _body(chain[0])
	if hb >= 0 and _sim[hb]:
		# One punch, one impulse: a light head snaps far more than a heavy chest.
		_add_bone_velocity(hb, dir * _flinch_dv(hb, s))
		for b in chain:
			var i := _body(b)
			if i >= 0 and i != hb and _sim[i]:
				_add_bone_velocity(i, dir * _flinch_dv(i, s) * 0.4)
		if hb == _head_i:
			# The fist lands on the face, ahead of the neck: a sideways hit turns it.
			var flat := Vector3(dir.x, 0.0, dir.z)
			_add_bone_spin(hb, _host_forward().cross(flat) * HEAD_TWIST * s)
	if state == State.STAGGER:
		_note_reaction(_jitter_for(&"flinch"))
		return  # already reacting: the chain and impulse stack on the stagger
	if state == State.ANIMATED:
		_cancel_overlay()
	_set_push(dir, FLINCH_PUSH_DIST * s, r["fade"])
	_react_left = r["fade"]
	_react_kind = &"flinch"
	_note_reaction(_jitter_for(&"flinch"))
	_set_state(State.FLINCH)

## Velocity change a flinch impulse gives body i (RagdollProfile.flinch_impulse
## / bone mass, clamped to flinch_dv_min..flinch_dv_max), x strength.
func _flinch_dv(i: int, s: float) -> float:
	return clampf(profile.flinch_impulse / maxf(_mass[i], 0.1), profile.flinch_dv_min, profile.flinch_dv_max) * s

## Stagger tier (Tuning.REACT_STAGGER): spine and up plus both arms go 80%
## physical, fading to 0 over 0.6 s; pushed back 0.6-1.0 m (by strength 0..1)
## with stumble steps; the legs stay animated so the fighter stays upright. It
## never turns into a launch by itself. On a flying body it adds velocity.
func stagger(direction: Vector3, strength: float = 1.0) -> void:
	if rig == null:
		return
	var dir := direction.normalized() if direction.length_squared() > 1e-6 else -_host_forward()
	var flat := _flat_dir(direction)
	var s := clampf(strength, 0.3, 1.5)
	match state:
		State.LAUNCHED:
			if not _held:
				add_velocity(flat * profile.stagger_dv * 0.5 * s)
			return
		State.GROUNDED, State.DEAD, State.GETUP:
			return
	_read_bodies()
	var r: Dictionary = Tuning.REACT_STAGGER
	_limp(STAGGER_CHAIN, r["physics"], r["fade"], 0.0)
	for b in STAGGER_CHAIN:
		var i := _body(b)
		if i < 0 or not _sim[i]:
			continue
		var k := 1.0 if b in [Bones.SPINE, Bones.CHEST, Bones.HEAD] else 0.6
		_add_bone_velocity(i, dir * profile.stagger_dv * s * k)
	var push: Vector2 = r["push"]
	_cancel_overlay()
	_set_push(flat, lerpf(push.x, push.y, clampf(strength, 0.0, 1.0)), r["fade"])
	_react_left = r["fade"]
	_react_kind = &"stagger"
	_play_steps(flat, r["fade"], &"stagger")
	_note_reaction(_jitter_for(&"stagger"))
	_set_state(State.STAGGER)

## Sweep tier (Tuning.REACT_STUMBLE): the hit leg from the knee down goes 50%
## physical for 0.3 s (the knee folds), then 2-3 stumble steps along the
## sweep; everything else animated. State.STAGGER, get_reaction_kind() ==
## &"stumble". `leg_bone`: any bone of the swept leg (else the leg the sweep
## reaches first).
func stumble(direction: Vector3, leg_bone: StringName) -> void:
	if rig == null:
		return
	var flat := _flat_dir(direction)
	var side := _leg_side(leg_bone, flat)
	var shin: StringName = Bones.L_LOWER_LEG if side == 0 else Bones.R_LOWER_LEG
	var foot: StringName = Bones.L_FOOT if side == 0 else Bones.R_FOOT
	match state:
		State.LAUNCHED, State.GROUNDED, State.DEAD:
			if _full and not _dead_frozen and not _held:
				_read_bodies()
				_add_bone_velocity(_body_for(shin), flat * STUMBLE_DV * 0.5)
			return
		State.GETUP:
			return
	_read_bodies()
	var r: Dictionary = Tuning.REACT_STUMBLE
	_limp([shin, foot], r["physics"], STUMBLE_FADE, r["hold"])
	var si := _body(shin)
	if si >= 0 and _sim[si]:
		_add_bone_velocity(si, flat * STUMBLE_DV)
		# The knee folds (hinge X: negative = flexion), so the leg visibly gives.
		_add_bone_spin(si, -_xf[si].basis.x * STUMBLE_BUCKLE)
	_cancel_overlay()
	# The steps go sideways (the doc's "2-3 stumble steps sideways"): along the
	# sweep's sideways part, or toward the swept leg for a sweep from straight
	# ahead or behind; a little of the sweep's own direction stays in.
	var right := host.global_basis.x if host else Vector3.RIGHT
	right = Vector3(right.x, 0.0, right.z).normalized()
	var lat := flat.dot(right)
	var sgn := signf(lat) if absf(lat) > 0.3 else (-1.0 if side == 0 else 1.0)
	var step_dir := (right * sgn + (flat - right * lat) * 0.3).normalized()
	_set_push(step_dir, STUMBLE_DIST, r["act"])
	_react_left = r["act"]
	_react_kind = &"stumble"
	_play_steps(step_dir, r["act"], &"stumble")
	_note_reaction(_jitter_for(&"stumble"))
	_set_state(State.STAGGER)

## Knockdown tier (Tuning.REACT_KNOCKDOWN): full body, low muscle tone, drops
## in place with little travel (the upper body tips over in the hit direction,
## the knees buckle, the feet stay planted); gets up after the ground time
## (set_getup_after(), default 1.2-2.0 s; the player Tuning.PLAYER_GETUP_AFTER).
func knockdown(direction: Vector3, hit_bone: StringName) -> void:
	if rig == null:
		return
	var dir := _flat_dir(direction)
	if _held:
		end_held()
	match state:
		State.DEAD:
			if _full:
				add_velocity(dir)
			return
		State.GROUNDED:
			_read_bodies()
			_add_bone_velocity(_body_for(hit_bone), dir * 1.5)
			_note_reaction(_jitter_for(&"knockdown"))
			return
		State.LAUNCHED:
			# Knocked out of the air: down faster.
			_read_bodies()
			for i in _n:
				if _sim[i] and not _severed[i]:
					_add_bone_velocity(i, dir * 0.8 + Vector3.DOWN * 2.0)
			_react_kind = &"knockdown"
			_assign_ground_time(Tuning.REACT_KNOCKDOWN["ground"])
			_note_reaction(_jitter_for(&"knockdown"))
			return
	_end_partial_reaction()
	_enter_full()
	_read_bodies()
	var hb := _body_for(hit_bone)
	for i in _n:
		if not _sim[i] or _severed[i]:
			continue
		var b: StringName = Bones.PHYSICAL[i]
		var dv := Vector3.ZERO
		if b == Bones.HIPS:
			dv = dir * KNOCKDOWN_HIPS + Vector3.DOWN * KNOCKDOWN_DROP
		elif b in [Bones.L_UPPER_LEG, Bones.R_UPPER_LEG]:
			dv = Vector3.DOWN * KNOCKDOWN_DROP * 0.5
		elif b in [Bones.L_LOWER_LEG, Bones.R_LOWER_LEG, Bones.L_FOOT, Bones.R_FOOT]:
			dv = Vector3.ZERO
		else:
			dv = dir * KNOCKDOWN_DV
		if i == hb:
			dv += dir * KNOCKDOWN_DV * 0.3
		_add_bone_velocity(i, dv)
	_begin_flight(&"knockdown")
	for i in _n:
		var b: StringName = Bones.PHYSICAL[i]
		var leg := b in [Bones.L_UPPER_LEG, Bones.R_UPPER_LEG, Bones.L_LOWER_LEG, Bones.R_LOWER_LEG, Bones.L_FOOT, Bones.R_FOOT]
		_tone[i] = 0.0 if leg else profile.knockdown_tone   # the knees buckle
	_assign_ground_time(Tuning.REACT_KNOCKDOWN["ground"])
	if state != State.LAUNCHED:
		_set_state(State.LAUNCHED)
	_note_reaction(_jitter_for(&"knockdown"))
	launched.emit(_com_velocity_logical())

## Launch, hard launch and severing launch (Tuning.REACT_LAUNCH): full ragdoll,
## very low tone, limb spin. Every bone first gets its animated-pose velocity
## (the last two animated poses, cached before any hitstop), then `velocity`
## as a velocity change, extra at hit_bone. Calling launch() while flying
## re-launches (adds velocity). Ground time: set_getup_after(), default
## 1.5-2.5 s (the player Tuning.PLAYER_GETUP_AFTER). Ends a hold (begin_held).
func launch(velocity: Vector3, _hit_point: Vector3, hit_bone: StringName = &"Chest") -> void:
	if rig == null:
		return
	if _held:
		end_held()
	_end_partial_reaction()
	if not _full:
		_enter_full()
	elif _dead_frozen:
		_unfreeze_dead()
	_read_bodies()
	_apply_launch_velocity(velocity, _body_for(hit_bone))
	var spd := velocity.length()
	if spd > 0.01:
		apply_limb_spin(velocity / spd, clampf(spd / 8.0, 0.25, 2.0))
	_push_fresh_pieces(velocity)
	if state != State.DEAD:
		_begin_flight(&"launch")
		_assign_ground_time(Tuning.REACT_LAUNCH["ground"])
		if state != State.LAUNCHED:
			_set_state(State.LAUNCHED)
	else:
		_launch_time = 0.0
		_dead_still_t = 0.0
		_dead_awake_t = 0.0
	var range_j: Vector2 = Tuning.HITSTOP_JITTER_RANGE
	_note_reaction(lerpf(range_j.x + 0.01, range_j.y, clampf((spd - Tuning.LAUNCH_SPEED_MIN) / 12.0, 0.0, 1.0)))
	launched.emit(velocity)

# --- Round 5: per-chain partial ragdoll -------------------------------------------
## Per-chain partial ragdoll: `bones` go `physics_amount` (0..1) physical (muscle
## strength 1 - amount), fading back to full strength over `fade_time` s
## (0 = hold until restore_chain). Bones outside follow the animation at full
## strength. Works in ANIMATED (the fighter keeps control) and on top of a
## flinch / stagger; ignored while the whole body is a ragdoll.
func limp_chain(bones: Array[StringName], physics_amount: float, fade_time: float) -> void:
	if rig == null or _full or state == State.GETUP:
		return
	if state == State.ANIMATED:
		_cancel_overlay()
	_read_bodies()
	_limp(bones, physics_amount, fade_time, 0.0)

## Back to full strength (a short crossfade, RESTORE_FADE s).
func restore_chain(bones: Array[StringName]) -> void:
	if rig == null:
		return
	for b in bones:
		var i := _body(b)
		if i < 0 or _amt[i] <= 0.0:
			continue
		_amt[i] = minf(_amt[i], CHAIN_BLEND_OUT)
		_amt_hold[i] = 0.0
		_amt_rate[i] = _amt[i] / RESTORE_FADE

## Muscle strength 0..1 with which a bone tracks the animation (1 = fully).
## Partial reactions: 1 - the bone's physics share (1 outside every chain).
## Full ragdoll: its muscle tone relative to RagdollProfile.chain_tone (low in a
## knockdown, very low in a launch, 0 once lying down). Dead or severed: 0.
## Hands report their forearm.
func get_bone_strength(bone: StringName) -> float:
	if rig == null:
		return 1.0
	var i := _body_for_any(bone)
	if i < 0:
		return 1.0
	if _severed[i] or state == State.DEAD:
		return 0.0
	if _full:
		var on := profile.use_muscles and (_muscles_on or _held)
		return clampf(_tone[i] / maxf(profile.chain_tone, 0.001), 0.0, 1.0) if on else 0.0
	if _sim[i]:
		return 1.0 - _amt[i]
	return 1.0

## The bones a flinch on `bone` makes physical: the head; or that arm's upper
## and lower arm; or that leg from the knee down; otherwise (hips, spine,
## chest) the spine and chest.
static func hit_chain(bone: StringName) -> Array[StringName]:
	match bone:
		Bones.HEAD:
			return [Bones.HEAD]
		Bones.L_UPPER_ARM, Bones.L_LOWER_ARM, Bones.L_HAND:
			return [Bones.L_UPPER_ARM, Bones.L_LOWER_ARM]
		Bones.R_UPPER_ARM, Bones.R_LOWER_ARM, Bones.R_HAND:
			return [Bones.R_UPPER_ARM, Bones.R_LOWER_ARM]
		Bones.L_UPPER_LEG, Bones.L_LOWER_LEG, Bones.L_FOOT:
			return [Bones.L_LOWER_LEG, Bones.L_FOOT]
		Bones.R_UPPER_LEG, Bones.R_LOWER_LEG, Bones.R_FOOT:
			return [Bones.R_LOWER_LEG, Bones.R_FOOT]
	return [Bones.SPINE, Bones.CHEST]

const STAGGER_CHAIN: Array[StringName] = [Bones.SPINE, Bones.CHEST, Bones.HEAD,
	Bones.L_UPPER_ARM, Bones.L_LOWER_ARM, Bones.R_UPPER_ARM, Bones.R_LOWER_ARM]

## &"flinch" | &"stumble" | &"stagger" | &"knockdown" | &"launch" for the
## reaction in progress, &"" otherwise.
func get_reaction_kind() -> StringName:
	return _react_kind

## Ground time before the next get-up (s), for knockdowns and launches. Call
## before or after knockdown()/launch() (the same frame or later); it wins
## over the tier default.
func set_getup_after(seconds: float) -> void:
	_ground_time = maxf(seconds, 0.0)
	_ground_set_frame = Engine.get_physics_frames()

## Ground time of the current (or last) knockdown / launch, s.
func get_getup_after() -> float:
	return _ground_time

# --- Round 5: held bodies (Carry) -------------------------------------------------------
## Held by a grabber (Carry): pin `bone` to `hand` (moved by the grabber) with a
## strong target-velocity motor, not a hard joint; the rest of the body is
## physical with low tone so the legs and free arm dangle and swing. No
## collisions with `holder` while held. Works on a standing, staggering,
## flying, downed or dead body (a settled corpse wakes). A torso or head grab
## keeps the body upright facing the holder; a limb grab hangs from the hand.
## The pin point is the spot on the bone nearest the hand at the call.
func begin_held(bone: StringName, hand: Node3D, holder: Node3D) -> void:
	if rig == null or hand == null or not is_instance_valid(hand):
		return
	if _held:
		end_held()
	if state == State.DEAD:
		if _dead_frozen:
			_unfreeze_dead()
		elif not _full:
			return
	elif not _full:
		_end_partial_reaction()
		_enter_full()
		_begin_flight(&"")
		_set_state(State.LAUNCHED)
	elif state == State.GROUNDED:
		_begin_flight(&"")
		_set_state(State.LAUNCHED)
	_read_bodies()
	_held = true
	_held_hand = hand
	_held_holder = holder
	_held_prev_hand = Vector3.INF
	_held_i = _body_for(bone)
	_held_orient = Bones.PHYSICAL[_held_i] in [Bones.HIPS, Bones.SPINE, Bones.CHEST, Bones.HEAD]
	var c: Vector3 = _xf[_held_i].origin
	var p := c + (hand.global_position - c).limit_length(_body_radius[_held_i] * HELD_PIN_DEPTH)
	_held_local = _xf[_held_i].affine_inverse() * p
	_held_mass_set = true
	var mult := HELD_LIMB_MASS_MULT if _mass[_held_i] < 5.0 else HELD_TORSO_MASS_MULT
	PhysicsServer3D.body_set_param(_rids[_held_i], PhysicsServer3D.BODY_PARAM_MASS, _mass[_held_i] * mult)
	_set_holder_exceptions(holder, true)
	_release_slot()
	if state == State.DEAD:
		_set_tones(0.0)
		_dead_still_t = 0.0
		_dead_awake_t = 0.0
	else:
		for i in _n:
			var b: StringName = Bones.PHYSICAL[i]
			_tone[i] = profile.held_torso_tone if b in [Bones.SPINE, Bones.CHEST, Bones.HEAD] else profile.held_limb_tone
		if animator:
			animator.locked = true
			animator._hold(&"held", 0.15)
		_react_kind = &""

## Let go: the body keeps its velocity (a throw adds to it with launch() or
## add_velocity()). A live body falls, lands and gets up (ground time 1.2-2.0 s
## unless set_getup_after()); a dead one settles and refreezes.
func end_held() -> void:
	if not _held:
		return
	_held = false
	_set_holder_exceptions(_held_holder, false)
	if _held_mass_set and _held_i >= 0:
		PhysicsServer3D.body_set_param(_rids[_held_i], PhysicsServer3D.BODY_PARAM_MASS, _mass[_held_i])
	_held_mass_set = false
	_held_hand = null
	_held_holder = null
	if state == State.DEAD:
		_dead_still_t = 0.0
		_dead_awake_t = 0.0
		_dead_quiet = false
	elif _full:
		_begin_flight(&"launch")
		_assign_ground_time(Tuning.REACT_KNOCKDOWN["ground"])

func is_held() -> bool:
	return _held

## The fighter holding this body (null if none).
func get_holder() -> Node3D:
	return _held_holder if _held else null

## Land on the feet now, from any full-ragdoll state (a held body let go to
## stumble, Carry's release). Like air_recover() without its timing rule.
func recover_upright() -> bool:
	if not _full or state == State.DEAD or rig == null:
		return false
	if _held:
		end_held()
	if _gripped:
		set_gripped(false)
	if state == State.GROUNDED:
		_set_state(State.LAUNCHED)
	_launch_time = maxf(_launch_time, Tuning.AIR_RECOVERY_AFTER)
	return air_recover()

# --- Round 5: bodies stay -------------------------------------------------------------
## Wake a settled (frozen) dead body so it can be grabbed and thrown. It
## refreezes by itself once it settles again.
func wake() -> void:
	if state == State.DEAD and _dead_frozen:
		_unfreeze_dead()

## True for a dead body that settled and froze (static colliders, no cost).
func is_settled() -> bool:
	return state == State.DEAD and _dead_frozen

## Seconds an awake dead body has been at rest (it freezes at Tuning.DEAD_FREEZE_AFTER).
func get_dead_rest_time() -> float:
	return _dead_still_t if state == State.DEAD and not _dead_frozen else 0.0

## Push the bone nearest `at` by `dv` m/s (feet walking through a body, small
## knocks). Wakes a settled corpse. No effect on a standing fighter.
func nudge(at: Vector3, dv: Vector3) -> void:
	if rig == null or not (_full or state == State.DEAD):
		return
	if _dead_frozen:
		_unfreeze_dead()
	var best := -1
	var best_d := INF
	for i in _n:
		if not _sim[i] or _severed[i]:
			continue
		var d := _pbs[i].global_position.distance_squared_to(at)
		if d < best_d:
			best_d = d
			best = i
	if best >= 0:
		_add_bone_velocity(best, dv)

# --- Velocity helpers for other modules ------------------------------------------------
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
	if not (_full or _partial) or _dead_frozen:
		return
	for i in _n:
		if _sim[i] and not _severed[i]:
			_set_lv(i, _get_lv(i) * factor)

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
			if bi < 0 or _severed[bi] or not _sim[bi]:
				continue
			var dv := omega.cross(_xf[bi].origin - joint)
			_add_bone_velocity(bi, dv)
			_add_bone_spin(bi, omega)
			added += dv * _mass[bi]
	var m := get_total_mass()
	if m > 0.0:
		var corr := -added / m
		for i in _n:
			if _sim[i] and not _severed[i]:
				_add_bone_velocity(i, corr)

## Hitstop on this body for duration_real s (real time): every simulating bone
## holds still (velocity stashed, gravity off) and gets its velocity back at
## the end. The controller also does this by itself whenever the host's
## is_frozen() is true, so callers may skip it.
func freeze(duration_real: float) -> void:
	if duration_real <= 0.0:
		return
	_hitstop_until = maxf(_hitstop_until, _now() + duration_real)
	if _any_sim() and not _hitstop_on:
		_begin_hold()
	if _hitstop_on and Engine.get_physics_frames() - _react_frame <= 1:
		# The victim of this hit: jitter by the freeze length (40 ms 2 cm .. 180 ms 4 cm).
		var jr: Vector2 = Tuning.HITSTOP_JITTER_RANGE
		_jitter_amp = maxf(_jitter_amp, lerpf(jr.x, jr.y, clampf((duration_real - 0.04) / 0.14, 0.0, 1.0)))

## True while simulating bones are held by a hitstop.
func is_in_hitstop() -> bool:
	return _hitstop_on

## While true, bones do not collide with Layers.DESTRUCTIBLE (ImpactResolver decides).
func set_ignore_breakables(ignore: bool) -> void:
	_ignore_breakables = ignore
	_apply_layers()

## Air recovery: from LAUNCHED (after Tuning.AIR_RECOVERY_AFTER) flip upright and
## land on the feet. Returns false if not allowed right now.
## On success: ANIMATED immediately (emits state_changed and recovered), host
## upright at the body, capsule on, landing pose playing. If the body was high
## above the floor the capsule is left in the air: the Fighter's
## move_and_slide gravity brings it down.
func air_recover() -> bool:
	if state != State.LAUNCHED or _launch_time < Tuning.AIR_RECOVERY_AFTER or rig == null or _gripped or _held:
		return false
	_read_bodies()
	var com_v := _com_velocity_logical()
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

## Killed: stays a ragdoll (launching it first if it was standing) on
## Layers.DEAD_BODY. When it settles, bones freeze into static bodies and
## `settled` fires. A held body stays held.
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
		# A corpse's pose is all physics (no muscles): its animator would only
		# cost time (perf). force_recover() turns it back on.
		animator.set_physics_process(false)
	_dead_frozen = false
	_was_frozen = false
	_dead_quiet = false
	_dead_still_t = 0.0
	_dead_awake_t = 0.0
	_state_t = 0.0
	_react_kind = &""
	_set_state(State.DEAD)
	_apply_layers()
	_register_awake(true)

## Upgrade 2. Broken arm (BodyZones.Zone.ARM_L or ARM_R): the shoulder and
## elbow joints widen (Jolt hard limits and the soft ranges, the elbow can
## hyperextend), that arm's muscles and neutral tension switch off so it
## flops in the ragdoll, and the animator hangs it from the shoulder while
## standing (it swings with the body). Lasts until heal_arms() (round reset).
func break_arm(zone: int) -> void:
	if rig == null or not BodyZones.is_arm(zone):
		return
	var side := 0 if zone == BodyZones.Zone.ARM_L else 1
	if _arm_broken[side]:
		return
	_arm_broken[side] = true
	var ua: StringName = Bones.L_UPPER_ARM if side == 0 else Bones.R_UPPER_ARM
	var la: StringName = Bones.L_LOWER_ARM if side == 0 else Bones.R_LOWER_ARM
	rig.widen_joint(ua, BROKEN_SHOULDER_EXTRA, BROKEN_SHOULDER_EXTRA)
	rig.widen_joint(la, BROKEN_ELBOW_EXTRA, BROKEN_ELBOW_HYPER)
	var k := PI / 180.0
	for j in _jn:
		var b: StringName = Bones.PHYSICAL[_j_child[j]]
		if b == ua or b == la:
			_j_limp[j] = 1
			var lim: Array = _j_lim[j]
			if b == la:
				lim[0] = Vector2(lim[0].x - BROKEN_ELBOW_HYPER * k, lim[0].y + BROKEN_ELBOW_EXTRA * k)
			else:
				for a in 3:
					lim[a] = Vector2(lim[a].x - BROKEN_SHOULDER_EXTRA * k, lim[a].y + BROKEN_SHOULDER_EXTRA * k)
	if animator:
		animator.set_arm_broken(side, true)

func is_arm_broken(zone: int) -> bool:
	if not BodyZones.is_arm(zone):
		return false
	return _arm_broken[0 if zone == BodyZones.Zone.ARM_L else 1]

## Undo break_arm() on both arms (round restart).
func heal_arms() -> void:
	if rig == null:
		return
	for side in 2:
		if not _arm_broken[side]:
			continue
		_arm_broken[side] = false
		rig.widen_joint(Bones.L_UPPER_ARM if side == 0 else Bones.R_UPPER_ARM, 0.0, 0.0)
		rig.widen_joint(Bones.L_LOWER_ARM if side == 0 else Bones.R_LOWER_ARM, 0.0, 0.0)
	var k := PI / 180.0
	for j in _jn:
		var b: StringName = Bones.PHYSICAL[_j_child[j]]
		if b in [Bones.L_UPPER_ARM, Bones.L_LOWER_ARM, Bones.R_UPPER_ARM, Bones.R_LOWER_ARM]:
			var spec: Dictionary = HumanoidRig.JOINT_LIMITS[b]
			_j_lim[j] = [spec["x"] * k, spec.get("y", Vector2.ZERO) * k, spec.get("z", Vector2.ZERO) * k]
			_j_limp[j] = 0
	if animator:
		animator.heal_arms()

## Upgrade 2. Held by a limb grab (agent G): the body stays a limp ragdoll in
## LAUNCHED (no muscles, no landing/grounded/get-up/settling, no air
## recovery) until set_gripped(false), then lands and gets up normally.
## A standing body is put into full ragdoll here if the caller has not done
## it. Backstop clamp on bone speed while held (G clamps tighter).
func set_gripped(on: bool) -> void:
	if rig == null or on == _gripped:
		return
	_gripped = on
	if on:
		if not _full:
			launch(Vector3.ZERO, get_center_of_mass(), Bones.CHEST)
		elif _dead_frozen:
			_unfreeze_dead()
		if state == State.GROUNDED:
			_set_state(State.LAUNCHED)
		_release_slot()
		_set_tones(0.0)
		if animator:
			animator._hold(&"neutral", 0.2)
	else:
		_launch_time = 0.0
		_landed = false
		_land_time = 0.0
		_slow_time = 0.0
		_ground_t = 0.0
		_dead_still_t = 0.0
		_state_t = 0.0

func is_gripped() -> bool:
	return _gripped

## Upgrade 2 (ground finishers): the downed body's automatic get-up starts no
## sooner than `seconds` (game time) from now. Call it as often as you like
## while the body is launched or lying down; it only ever extends the wait,
## never shortens it. No effect once the get-up has begun.
func delay_getup(seconds: float) -> void:
	_getup_not_before = maxf(_getup_not_before, _clock + maxf(seconds, 0.0))

## Game seconds until the get-up may start (0 = not delayed).
func get_getup_delay_left() -> float:
	return maxf(_getup_not_before - _clock, 0.0)

## Debug/restart: snap straight back to ANIMATED standing at the pelvis
## (also revives a dead body: live collision layers, processing back on).
func force_recover() -> void:
	if rig == null:
		return
	if _held:
		end_held()
	var was_dead := state == State.DEAD
	var pelvis := rig.get_bone_global_position(Bones.HIPS)
	if _dead_frozen:
		pelvis = (_xf[_hips_i] * _off_inv[_hips_i]).origin
		_full = true
	if _full or _partial:
		if _full and not _dead_frozen:
			_read_bodies()
			pelvis = (_xf[_hips_i] * _off_inv[_hips_i]).origin
		if _full:
			_stop_full_sim()
		else:
			_stop_partial()
		if host.is_inside_tree():
			var floor_y := _floor_y(pelvis)
			host.global_position = Vector3(pelvis.x, floor_y, pelvis.z)
	_end_partial_reaction()
	_reattach_rig()
	_overlay_t = 1.0
	_dead_frozen = false
	_register_awake(false)
	set_physics_process(true)
	if animator:
		animator.set_physics_process(true)
		animator.locked = false
		animator.reset_pose()
	_finish_to_animated()
	if was_dead:
		_apply_layers()  # live layers again (state is ANIMATED now)

## True in every state where bodies simulate or the controller moves the host
## (FLINCH, STAGGER, LAUNCHED, GROUNDED, DEAD). A limp_chain() on a standing
## fighter does not count: the fighter keeps control.
func is_simulating() -> bool:
	return state in [State.FLINCH, State.STAGGER, State.LAUNCHED, State.GROUNDED, State.DEAD]

## True while the whole body simulates and the host follows the pelvis.
func is_full_ragdoll() -> bool:
	return _full

## True while some chains simulate on a standing fighter (partial ragdoll).
func is_partial_ragdoll() -> bool:
	return _partial

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
## During a hitstop hold this is the held (zero) velocity.
func get_com_velocity() -> Vector3:
	if rig == null or not _full:
		return host.velocity if host else Vector3.ZERO
	if _dead_frozen:
		return Vector3.ZERO
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

## [linear, angular] world velocity of a bone (for severed pieces). During a
## hitstop hold: the velocity it will get back when the hold ends.
func get_bone_velocity(bone: StringName) -> Array:
	var i := _body_for(bone)
	if (_full or _partial) and _sim[i]:
		return [_get_lv(i), _get_av(i)]
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
		_amt[i] = 0.0
		_tone[i] = 0.0
		_disable_body(i)
		if _held and i == _held_i:
			end_held()

## HumanoidRig.sever(): a loose piece cut off during a hitstop hold waits
## frozen and flies off with (linear, angular) when the hold ends; a piece cut
## off in the same frame before a launch() also gets that launch velocity.
func adopt_piece(piece: RigidBody3D, linear: Vector3, angular: Vector3) -> void:
	if piece == null:
		return
	_fresh_pieces.append([piece, Engine.get_physics_frames(), piece.global_transform])
	if _hitstop_on:
		_hold_piece(piece, linear, angular)
	else:
		piece.linear_velocity = linear
		piece.angular_velocity = angular

func _hold_piece(piece: RigidBody3D, linear: Vector3, angular: Vector3) -> void:
	for h in _hold_pieces:
		if h[0] == piece:
			return
	piece.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	piece.freeze = true
	piece.linear_velocity = Vector3.ZERO
	piece.angular_velocity = Vector3.ZERO
	_hold_pieces.append([piece, linear, angular])

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
	_frozen_now = _host_frozen() or _now() < _hitstop_until
	if _frozen_now and _any_sim():
		if not _hitstop_on:
			_begin_hold()
		_tick_hold()
		last_tick_ms = (Time.get_ticks_usec() - t0) / 1000.0
		return
	if _hitstop_on:
		_end_hitstop()
	if _frozen_now:
		delta = 0.0   # frozen and not simulating: timers stop, no history
	_state_t += delta
	_clock += delta
	match state:
		State.ANIMATED:
			_tick_animated(delta)
		State.FLINCH, State.STAGGER:
			_tick_reaction(delta)
		State.LAUNCHED:
			_tick_launched(delta)
		State.GROUNDED:
			_tick_grounded(delta)
		State.GETUP:
			_tick_getup(delta)
		State.DEAD:
			_tick_dead(delta)
	if not _fresh_pieces.is_empty():
		var f := Engine.get_physics_frames()
		_fresh_pieces = _fresh_pieces.filter(func(e: Array) -> bool: return int(e[1]) >= f)
	last_tick_ms = 0.0 if _dead_frozen else (Time.get_ticks_usec() - t0) / 1000.0

func _tick_animated(delta: float) -> void:
	if _partial:
		_tick_partial(delta, false)
		return
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

## Chains simulate, the rest follows the animation (ANIMATED, FLINCH, STAGGER).
func _tick_partial(delta: float, move_host: bool) -> void:
	_read_bodies()
	if move_host:
		_move_host_partial(delta)
	_follow_kinematic()
	var any := _tick_chains(delta)
	_apply_torques(true, false)
	_write_pose()
	_record_history(_out_rot, _out_hips(), delta)
	if not any:
		_stop_partial()

## FLINCH / STAGGER (stagger and stumble): the push, the steps, the timer.
func _tick_reaction(delta: float) -> void:
	_react_left -= delta
	if _partial:
		_tick_partial(delta, true)
	else:
		_move_host_partial(delta)
		var hips := _anim_hips()
		rig.apply_pose(animator.pose_rot, hips)
		_record_history(animator.pose_rot, hips, delta)
	_feed_locomotion()
	if _react_left <= 0.0:
		_end_partial_reaction()
		_react_kind = &""
		if animator:
			animator._release(0.15)
		_set_state(State.ANIMATED)

func _tick_launched(delta: float) -> void:
	_launch_time += delta
	_read_bodies()
	_follow_host()
	if _held:
		_tick_held(delta)
		return
	if _gripped:
		_tick_gripped()
		return
	if _landed or _ground_from_hit:
		_ground_t += delta
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
		var base := profile.knockdown_tone if _react_kind == &"knockdown" else profile.launch_tone
		_set_tones(base * maxf(0.0, 1.0 - _land_time / LAND_TONE_FADE))
	_apply_torques(_muscles_on and _tone[_chest_i] > 0.0, true)
	_write_pose()
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
		if _slow_time >= Tuning.GROUNDED_HOLD or _land_time >= Tuning.GROUNDED_TIMEOUT or _getup_due():
			_enter_grounded()
	elif _getup_due():
		_landed = true
		landed.emit()
		_enter_grounded()
	elif _launch_time >= LAUNCH_GROUNDED_FALLBACK:
		_landed = true
		landed.emit()
		_enter_grounded()

## Held by a limb grab: limp, no landing logic, backstop speed clamp, and an
## extra joint position pass (fast whips open the free elbows and ankles:
## Jolt's two global position steps are not enough for a body swung by one
## limb, and raising them would cost every ragdoll).
func _tick_gripped() -> void:
	if grip_fix_enabled:
		_fix_joint_drift()
	_cap_body_speeds()
	_apply_torques(false, true)
	_write_pose()

## Held by a grabber (begin_held): the pin motor, the speed cap, the joint fix,
## low-tone muscles (live) or soft limits only (dead).
func _tick_held(delta: float) -> void:
	if _held_hand == null or not is_instance_valid(_held_hand) or not _held_hand.is_inside_tree():
		end_held()
		_write_pose()
		return
	# In slow motion the player moves at real speed (Focus): a body the player
	# carries must keep up, so its caps and motor scale like the player does
	# (speeds x k, accelerations x k^2, k = TimeDirector.player_time_factor()).
	var k := _held_time_factor()
	var hand_xf := _held_hand.global_transform
	var hp := hand_xf.origin
	var hv := Vector3.ZERO
	if _held_prev_hand.is_finite() and delta > 0.0:
		hv = ((hp - _held_prev_hand) / delta).limit_length(GRIP_SPEED_CAP * k)
	_held_prev_hand = hp
	var i := _held_i
	if i >= 0 and _sim[i] and not _severed[i]:
		var pin := _xf[i] * _held_local
		var r := pin - _xf[i].origin
		var v_pin := _lv[i] + _av[i].cross(r)
		var v_want := hv + (hp - pin) * HELD_POS_GAIN * k
		var dv := (v_want - v_pin).limit_length(HELD_MAX_ACCEL * k * k * delta)
		_set_lv(i, _lv[i] + dv)
		if _held_orient:
			var want := _held_target_basis(hand_xf)
			var err := _rotvec(Quaternion((want * _xf[i].basis.transposed()).orthonormalized()))
			var dw := (err * HELD_ROT_GAIN * k - _av[i]).limit_length(HELD_MAX_SPIN_ACCEL * k * k * delta)
			_set_av(i, _av[i] + dw)

	var drag := minf(HELD_SWING_DAMP * k * delta, 1.0)
	for j in _n:
		if j != i and _sim[j] and not _severed[j]:
			_set_lv(j, _lv[j] - (_lv[j] - hv) * drag)
	if grip_fix_enabled:
		_fix_joint_drift()
	_cap_body_speeds(HELD_SPEED_CAP * k, GRIP_SPIN_CAP * k)
	_apply_torques(state != State.DEAD, true)
	_write_pose()

## Torso grabs: upright, facing the holder.
func _held_target_basis(hand_xf: Transform3D) -> Basis:
	var to := Vector3.ZERO
	if _held_holder != null and is_instance_valid(_held_holder):
		to = _held_holder.global_position - hand_xf.origin
	to.y = 0.0
	if to.length_squared() < 1e-4:
		to = hand_xf.basis.z
		to.y = 0.0
	if to.length_squared() < 1e-4:
		to = Vector3.FORWARD
	return Basis.looking_at(to.normalized(), Vector3.UP)

func _cap_body_speeds(cap := GRIP_SPEED_CAP, spin_cap := GRIP_SPIN_CAP) -> void:
	for i in _n:
		if not _sim[i] or _severed[i]:
			continue
		if _lv[i].length() > cap:
			_set_lv(i, _lv[i].limit_length(cap))
		if _av[i].length() > spin_cap:
			_set_av(i, _av[i].limit_length(spin_cap))

## 1, or TimeDirector.player_time_factor() while the player holds this body.
func _held_time_factor() -> float:
	if _held_holder == null or not is_instance_valid(_held_holder) or not _held_holder.is_in_group(&"player"):
		return 1.0
	var td := get_node_or_null(^"/root/TimeDirector")
	if td and td.has_method(&"player_time_factor"):
		return maxf(float(td.player_time_factor()), 1.0)
	return 1.0

## Gripped/held bodies only: GRIP_FIX_ITERS Gauss-Seidel passes that move each
## joint's two bodies back together by GRIP_FIX of the gap, weighted by their
## current server masses (a pinned limb is heavier). The first pass also
## removes the velocity that would open each gap further (an inelastic
## correction), so nothing here adds energy.
func _fix_joint_drift() -> void:
	var inv := PackedFloat64Array()
	inv.resize(_n)
	for i in _n:
		var m: float = PhysicsServer3D.body_get_param(_rids[i], PhysicsServer3D.BODY_PARAM_MASS)
		inv[i] = 1.0 / maxf(m, 0.01)
	var moved := PackedByteArray()
	moved.resize(_n)
	var vmoved := PackedByteArray()
	vmoved.resize(_n)
	for it in GRIP_FIX_ITERS:
		for j in _jn:
			var c := _j_child[j]
			var pa := _j_parent[j]
			if not _sim[c] or not _sim[pa] or _severed[c] or _severed[pa]:
				continue
			var a: Vector3 = (_xf[pa] * _off_inv[pa]) * _rest_origin[_j_bone[j]]
			var err: Vector3 = a - (_xf[c] * _off_inv[c]).origin
			if err.length_squared() < GRIP_FIX_MIN * GRIP_FIX_MIN:
				continue
			var wsum := inv[c] + inv[pa]
			_xf[c].origin += err * (GRIP_FIX * inv[c] / wsum)
			_xf[pa].origin -= err * (GRIP_FIX * inv[pa] / wsum)
			moved[c] = 1
			moved[pa] = 1
			if it == 0:
				# Also stop the joint opening further next step: remove the part
				# of the relative velocity that separates the two bodies along
				# the gap (inelastic, so it only removes energy).
				var n := err.normalized()
				var sep := (_lv[pa] - _lv[c]).dot(n)
				if sep > 0.0:
					_lv[c] += n * (sep * inv[c] / wsum)
					_lv[pa] -= n * (sep * inv[pa] / wsum)
					vmoved[c] = 1
					vmoved[pa] = 1
	for i in _n:
		if moved[i]:
			PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_TRANSFORM, _xf[i])
		if vmoved[i]:
			_set_lv(i, _lv[i])

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
	_ground_t += delta
	_read_bodies()
	_follow_host()
	_apply_torques(false, true)
	_write_pose()
	if _getup_due():
		if _lv[_hips_i].length() < GETUP_MAX_PELVIS_SPEED or _state_t >= GETUP_WAIT_MAX:
			start_getup()

func _getup_due() -> bool:
	if not auto_getup or _held or _gripped or _clock < _getup_not_before:
		return false
	if _ground_from_hit:
		# Player: real time from the hit (the freeze included: the player keeps
		# real time), and down enough even if the landing check lags behind.
		var low := _landed or (_xf[_hips_i].origin.y - _last_floor_y) < PLAYER_GETUP_HIPS
		return low and _now() - _down_at >= _ground_time
	return _landed and _ground_t >= _ground_time

## Begin the get-up now (from GROUNDED). Face up or down from the pelvis.
## The player gets the fast get-up (GETUP_TIMES_FAST).
func start_getup() -> void:
	if state != State.GROUNDED or _gripped or _held:
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
	var fast := _is_player()
	var times := GETUP_TIMES_FAST if fast else GETUP_TIMES
	_getup_total = times.x + times.y + times.z
	_getup_blend = GETUP_BLEND_FAST if fast else minf(Tuning.GETUP_BLEND, GETUP_BLEND_MAX)
	# The player's fast get-up has its own poses (P: getup_fast / getup_fast_down).
	var fast_id: StringName = &"getup_fast" if face_up else &"getup_fast_down"
	var timed := fast and PoseLibrary.has_move(fast_id) and animator != null and animator.has_method(&"_play_timed")
	if timed:
		_getup_move = fast_id
	if animator:
		animator.locked = true
		animator.loop_speed = 1.0
		animator._cancel(0.0)
		if timed:
			animator.call(&"_play_timed", _getup_move, _getup_total)
		else:
			animator._play(_getup_move, times.x, times.y, times.z)
	_state_t = 0.0
	rig.apply_pose(_snap_rot, _snap_hips)
	_set_state(State.GETUP)

func _tick_getup(delta: float) -> void:
	var hips := _anim_hips()
	var k := clampf(_state_t / maxf(_getup_blend, 0.01), 0.0, 1.0)
	k = k * k * (3.0 - 2.0 * k)
	for bi in HumanoidRig.BONE_COUNT:
		_out_rot[bi] = _snap_rot[bi].slerp(animator.pose_rot[bi], k)
	hips = _snap_hips.lerp(hips, k)
	rig.apply_pose(_out_rot, hips)
	_record_history(_out_rot, hips, delta)
	if _state_t >= _getup_total or (_state_t > _getup_blend and animator.get_current_move() != _getup_move):
		_finish_to_animated()

func _finish_to_animated() -> void:
	_flight_pose = &""
	_gripped = false
	_react_kind = &""
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
	if _held:
		_follow_host()
		_tick_held(delta)
		return
	if _gripped:
		_follow_host()
		_tick_gripped()
		return
	_dead_awake_t += delta
	var fastest := 0.0
	for i in _n:
		if _sim[i] and not _severed[i]:
			fastest = maxf(fastest, _lv[i].length())
	if _dead_quiet and fastest > DEAD_KNOCK_SPEED:
		_dead_quiet = false   # knocked about for real: soft limits back on while it moves
	if fastest < (DEAD_WAKE_SPEED if _dead_quiet else DEAD_SETTLE_SPEED):
		_dead_still_t += delta
	else:
		_dead_still_t = 0.0
	if not _dead_quiet and _dead_still_t >= DEAD_QUIET_AFTER:
		_dead_quiet = true
	if not _dead_quiet:
		_apply_torques(false, true)
	if fastest > 0.02 or not _dead_quiet:
		_follow_host()
		_write_pose()
	var over := _awake_dead > DEAD_AWAKE_MAX and _dead_still_t >= DEAD_EARLY_FREEZE
	var rest_needed := DEAD_REFREEZE_AFTER if _was_frozen else Tuning.DEAD_FREEZE_AFTER
	if _dead_still_t >= rest_needed or over or _dead_awake_t >= DEAD_AWAKE_TIMEOUT:
		_freeze_dead()

## Corpse: stop simulating, keep the pose, bones become static colliders on
## Layers.DEAD_BODY. This node and the animator stop processing (free).
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
		PhysicsServer3D.body_set_collision_layer(_rids[i], Layers.DEAD_BODY)
		PhysicsServer3D.body_set_collision_mask(_rids[i], 0)
	_dead_frozen = true
	_was_frozen = true
	_hitstop_on = false
	_record_history(_out_rot, _out_hips(), 0.0, true)
	_record_history(_out_rot, _out_hips(), 0.0, true)
	_register_awake(false)
	if animator:
		animator.set_physics_process(false)
	set_physics_process(false)
	last_tick_ms = 0.0
	settled.emit()

func _unfreeze_dead() -> void:
	_dead_frozen = false
	_dead_quiet = false
	_dead_still_t = 0.0
	_dead_awake_t = 0.0
	_state_t = 0.0
	set_physics_process(true)
	var bodies: Array[Transform3D] = []
	for i in _n:
		bodies.append(_xf[i])
	_start_sim([])
	for i in _n:
		if not _severed[i]:
			_teleport(i, bodies[i], Vector3.ZERO, Vector3.ZERO)
	_register_awake(true)

func _register_awake(on: bool) -> void:
	if on == _counted_awake:
		return
	_counted_awake = on
	_awake_dead = maxi(_awake_dead + (1 if on else -1), 0)

## Corpses awake (simulating) right now, all fighters.
static func awake_dead_count() -> int:
	return _awake_dead

# --- Hitstop hold --------------------------------------------------------------------
func _host_frozen() -> bool:
	return host != null and host.has_method(&"is_frozen") and host.is_frozen()

func _any_sim() -> bool:
	return (_full or _partial) and not _dead_frozen

func _begin_hold() -> void:
	var recent := Engine.get_physics_frames() - _react_frame <= 1
	_jitter_amp = _react_jitter if recent else 0.0
	for i in _n:
		_hitstop_lv[i] = Vector3.ZERO
		_hitstop_av[i] = Vector3.ZERO
		if not _sim[i] or _severed[i]:
			continue
		if recent:
			# A physics step may have run since the reaction: back to the contact pose.
			PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_TRANSFORM, _react_xf[i])
			_xf[i] = _react_xf[i]
		else:
			_xf[i] = PhysicsServer3D.body_get_state(_rids[i], PhysicsServer3D.BODY_STATE_TRANSFORM)
		_hold_xf[i] = _xf[i]
		_hitstop_lv[i] = PhysicsServer3D.body_get_state(_rids[i], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		_hitstop_av[i] = PhysicsServer3D.body_get_state(_rids[i], PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		PhysicsServer3D.body_set_param(_rids[i], PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE, 0.0)
	_hitstop_on = true
	_zero_velocities()
	if recent:
		# A limb cut off by this hit waits at the stump too.
		for e in _fresh_pieces:
			var piece: RigidBody3D = e[0]
			if is_instance_valid(piece) and not piece.freeze:
				var lv := piece.linear_velocity
				var av := piece.angular_velocity
				piece.global_transform = e[2]
				piece.reset_physics_interpolation()
				_hold_piece(piece, lv, av)

## Held bodies stay exactly where the hold began: zero velocity is not enough
## (Jolt's warm-started joint impulses and contact pushes creep a few mm a tick).
func _tick_hold() -> void:
	for i in _n:
		if _sim[i] and not _severed[i]:
			PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_TRANSFORM, _hold_xf[i])
			_xf[i] = _hold_xf[i]
	_zero_velocities()
	_write_pose()

func _end_hitstop() -> void:
	if not _hitstop_on:
		return
	_hitstop_on = false
	_hitstop_until = -1.0
	_jitter_amp = 0.0
	for i in _n:
		if _sim[i] and not _severed[i]:
			PhysicsServer3D.body_set_param(_rids[i], PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE, 1.0)
			PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, _hitstop_lv[i])
			PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, _hitstop_av[i])
			PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_SLEEPING, false)
			_lv[i] = _hitstop_lv[i]
			_av[i] = _hitstop_av[i]
	for e in _hold_pieces:
		var piece: RigidBody3D = e[0]
		if is_instance_valid(piece):
			piece.freeze = false
			piece.linear_velocity = e[1]
			piece.angular_velocity = e[2]
	_hold_pieces.clear()

## Every reaction ends here: remember the contact transforms (a hold that
## starts a step later puts the bodies back) and start the hold now if the
## host is already frozen.
func _note_reaction(jitter: float) -> void:
	_react_frame = Engine.get_physics_frames()
	_react_jitter = jitter
	for i in _n:
		_react_xf[i] = _xf[i]
	if _hitstop_on:
		_jitter_amp = maxf(_jitter_amp, jitter)
		for i in _n:
			_hold_xf[i] = _xf[i]   # bodies started (or moved) by a reaction inside the hold
	elif _any_sim() and (_host_frozen() or _now() < _hitstop_until):
		_begin_hold()

func _jitter_for(kind: StringName) -> float:
	var jr: Vector2 = Tuning.HITSTOP_JITTER_RANGE
	match kind:
		&"flinch":
			return jr.x
		&"stumble", &"stagger":
			return lerpf(jr.x, jr.y, 0.25)
		&"knockdown":
			return lerpf(jr.x, jr.y, 0.5)
	return jr.y

## A limb cut off this frame before the launch flies with the launch too.
func _push_fresh_pieces(dv: Vector3) -> void:
	var f := Engine.get_physics_frames()
	for e in _fresh_pieces:
		if int(e[1]) != f or not is_instance_valid(e[0]):
			continue
		var piece: RigidBody3D = e[0]
		var held := false
		for h in _hold_pieces:
			if h[0] == piece:
				h[1] = h[1] + dv
				held = true
		if not held:
			piece.linear_velocity += dv

# --- Simulation start/stop ---------------------------------------------------------
## Mark `bones` physical (merge with what is there) and start any body that
## now has to simulate: the chain bones and all their descendants.
func _limp(bones: Array, amount: float, fade: float, hold: float) -> void:
	amount = clampf(amount, 0.0, 1.0)
	if amount <= 0.0:
		return
	for b in bones:
		var i := _body(b)
		if i < 0 or _severed[i]:
			continue
		_amt[i] = maxf(_amt[i], amount)
		_amt_rate[i] = _amt[i] / fade if fade > 0.0 else 0.0
		_amt_hold[i] = maxf(_amt_hold[i], hold)
	_sync_partial()
	_update_chain_tone()

func _sync_partial() -> void:
	if _full or rig == null:
		return
	var want := PackedByteArray()
	want.resize(_n)
	var add: Array[StringName] = []
	for i in _n:
		var pb := _parent_body[i]
		if (_amt[i] > 0.0 or (pb >= 0 and want[pb] == 1)) and not _severed[i]:
			want[i] = 1
			if not _sim[i]:
				add.append(Bones.PHYSICAL[i])
	if add.is_empty():
		return
	var skel_xf := rig.skeleton.global_transform
	var xfs := _fk_bodies(_hist_cur_rot, _hist_cur_hips, skel_xf)
	var vels := _history_velocities()
	rig.simulator.physical_bones_start_simulation(add)
	for i in _n:
		_states[i] = PhysicsServer3D.body_get_direct_state(_rids[i])
		if _severed[i]:
			_disable_body(i)
			continue
		if want[i] and not _sim[i]:
			_sim[i] = 1
			PhysicsServer3D.body_set_enable_continuous_collision_detection(_rids[i], true)
			PhysicsServer3D.body_set_param(_rids[i], PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE, 0.0 if _hitstop_on else 1.0)
			_teleport(i, xfs[i], vels[0][i], vels[1][i])
	_apply_layers()
	if not _partial:
		_partial = true
		_follow_kinematic()

## Advance every chain's fade; false once no chain is left.
func _tick_chains(delta: float) -> bool:
	var any := false
	for i in _n:
		if _amt[i] <= 0.0:
			continue
		if _amt_hold[i] > 0.0:
			_amt_hold[i] = maxf(_amt_hold[i] - delta, 0.0)
		elif _amt_rate[i] > 0.0:
			_amt[i] = maxf(_amt[i] - _amt_rate[i] * delta, 0.0)
		if _amt[i] > 0.0:
			any = true
	_update_chain_tone()
	return any

## Muscle tone and display weight of each simulating bone in a partial ragdoll.
func _update_chain_tone() -> void:
	if _full:
		return
	for i in _n:
		if not _sim[i]:
			_w[i] = 0.0
			continue
		if _amt[i] > 0.0:
			_tone[i] = profile.chain_tone * (1.0 - _amt[i])
			_w[i] = clampf(_amt[i] / CHAIN_BLEND_OUT, 0.0, 1.0)
		else:
			_tone[i] = profile.chain_tone
			_w[i] = 0.0

func _stop_partial() -> void:
	rig.simulator.physical_bones_stop_simulation()
	rig.park_bodies()
	for i in _n:
		_sim[i] = 0
		_amt[i] = 0.0
		_amt_rate[i] = 0.0
		_amt_hold[i] = 0.0
		_w[i] = 0.0
	_partial = false
	_hitstop_on = false

## Leaving FLINCH / STAGGER (or skipping them): drop the push, give the animator back.
func _end_partial_reaction() -> void:
	_push_vel = Vector3.ZERO
	_react_left = 0.0
	if _anim_locked_by_reaction and animator:
		animator.locked = false
	_anim_locked_by_reaction = false

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
		keep_lv.append(_get_lv(i) if was[i] else Vector3.ZERO)
		keep_av.append(_get_av(i) if was[i] else Vector3.ZERO)
	if host.is_inside_tree():
		_last_floor_y = _floor_y(xfs[_hips_i].origin)
	rig.top_level = true
	_set_capsule(false)
	_start_sim([])
	var push := _push_vel
	for i in _n:
		_amt[i] = 0.0
		_amt_rate[i] = 0.0
		_amt_hold[i] = 0.0
		_w[i] = 1.0
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
	_overlay_t = 1.0
	_apply_layers()

## Start (or restart) a flight: landing, grounding and get-up timers.
func _begin_flight(kind: StringName) -> void:
	_launch_time = 0.0
	_landed = false
	_land_time = 0.0
	_slow_time = 0.0
	_ground_t = 0.0
	_ground_from_hit = _is_player()
	_down_at = _now()
	_flight_pose = &""
	if kind != &"":
		_react_kind = kind
	if state != State.DEAD:
		_acquire_slot()
		_set_tones(profile.launch_tone)
		if animator:
			animator.locked = true
			animator._hold(&"fall", 0.1)

## Default ground time for this hit unless set_getup_after() was called for it.
func _assign_ground_time(range_s: Vector2) -> void:
	if Engine.get_physics_frames() - _ground_set_frame <= 1:
		return
	_ground_time = Tuning.PLAYER_GETUP_AFTER if _is_player() else _rng.randf_range(range_s.x, range_s.y)

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
			PhysicsServer3D.body_set_param(_rids[i], PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE, 0.0 if _hitstop_on else 1.0)
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
	PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_SLEEPING, false)
	_xf[i] = xf
	if _hitstop_on:
		_hold_xf[i] = xf   # started inside a hold: pinned here until it ends
	_set_lv(i, lv)
	_set_av(i, av)

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

## Collision layer / mask of every bone for the current state (DEAD_BODY when
## dead), on the nodes and, for simulating or frozen bodies, on the server.
func _apply_layers() -> void:
	if rig == null:
		return
	var dead := state == State.DEAD
	var layer := Layers.DEAD_BODY if dead else Layers.RAGDOLL
	var mask := Layers.MASK_DEAD_BODY if dead else Layers.MASK_RAGDOLL
	if _ignore_breakables:
		mask &= ~Layers.DESTRUCTIBLE
	for i in _n:
		_pbs[i].collision_layer = layer
		_pbs[i].collision_mask = mask
		if _severed[i]:
			PhysicsServer3D.body_set_collision_layer(_rids[i], 0)
			PhysicsServer3D.body_set_collision_mask(_rids[i], 0)
		elif _sim[i]:
			PhysicsServer3D.body_set_collision_layer(_rids[i], layer)
			PhysicsServer3D.body_set_collision_mask(_rids[i], mask)
		elif _dead_frozen:
			PhysicsServer3D.body_set_collision_layer(_rids[i], layer)
			PhysicsServer3D.body_set_collision_mask(_rids[i], 0)
		else:
			# A non-simulating PhysicalBone3D keeps layer/mask 0 on the server.
			PhysicsServer3D.body_set_collision_layer(_rids[i], 0)
			PhysicsServer3D.body_set_collision_mask(_rids[i], 0)

## Held bodies never collide with the holder (its capsule and its bones).
func _set_holder_exceptions(holder: Node3D, on: bool) -> void:
	if on:
		_held_exc.clear()
		if holder == null or not is_instance_valid(holder):
			return
		if holder is CollisionObject3D:
			_held_exc.append((holder as CollisionObject3D).get_rid())
		var hrig = holder.get(&"rig")
		if hrig is HumanoidRig:
			for pb in (hrig as HumanoidRig).get_physical_bones():
				_held_exc.append(pb.get_rid())
		for i in _n:
			for o in _held_exc:
				PhysicsServer3D.body_add_collision_exception(_rids[i], o)
				PhysicsServer3D.body_add_collision_exception(o, _rids[i])
	else:
		var valid := holder != null and is_instance_valid(holder) and holder.is_inside_tree()
		for i in _n:
			for o in _held_exc:
				PhysicsServer3D.body_remove_collision_exception(_rids[i], o)
				if valid:
					PhysicsServer3D.body_remove_collision_exception(o, _rids[i])
		_held_exc.clear()

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

func _cancel_overlay() -> void:
	_overlay_t = 1.0

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

## Velocity a body has (or, during a hold, will get back).
func _get_lv(i: int) -> Vector3:
	if _hitstop_on:
		return _hitstop_lv[i]
	return PhysicsServer3D.body_get_state(_rids[i], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)

func _get_av(i: int) -> Vector3:
	if _hitstop_on:
		return _hitstop_av[i]
	return PhysicsServer3D.body_get_state(_rids[i], PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)

func _set_lv(i: int, v: Vector3) -> void:
	_lv[i] = v
	if _hitstop_on:
		_hitstop_lv[i] = v
		PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	else:
		PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, v)

func _set_av(i: int, v: Vector3) -> void:
	_av[i] = v
	if _hitstop_on:
		_hitstop_av[i] = v
		PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	else:
		PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, v)

func _add_bone_velocity(i: int, dv: Vector3) -> void:
	if i < 0 or not _sim[i] or _severed[i]:
		return
	_set_lv(i, _get_lv(i) + dv)
	PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_SLEEPING, false)

func _add_bone_spin(i: int, dw: Vector3) -> void:
	if i < 0 or not _sim[i] or _severed[i]:
		return
	_set_av(i, _get_av(i) + dw)

func _com_velocity_logical() -> Vector3:
	var s := Vector3.ZERO
	var m := 0.0
	for i in _n:
		if _sim[i] and not _severed[i]:
			s += _get_lv(i) * _mass[i]
			m += _mass[i]
	return s / m if m > 0.0 else Vector3.ZERO

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

func _now() -> float:
	var td := get_node_or_null(^"/root/TimeDirector")
	if td and td.has_method(&"now"):
		return td.now()
	return Time.get_ticks_usec() / 1_000_000.0

func _is_player() -> bool:
	return host != null and host.is_in_group(&"player")

func _host_forward() -> Vector3:
	if host == null:
		return Vector3.FORWARD
	var f := -host.global_basis.z
	f.y = 0.0
	return f.normalized() if f.length_squared() > 1e-6 else Vector3.FORWARD

## Flattened unit direction (the host's backward when there is none).
func _flat_dir(direction: Vector3) -> Vector3:
	var d := Vector3(direction.x, 0.0, direction.z)
	if d.length_squared() < 1e-6:
		return -_host_forward()
	return d.normalized()

## 0 = left leg, 1 = right. A leg bone names its side; otherwise the leg the
## sweep reaches first (a sweep travelling to the victim's right hits the left leg).
func _leg_side(leg_bone: StringName, flat_dir: Vector3) -> int:
	var s := String(leg_bone)
	if s.begins_with("Left"):
		return 0
	if s.begins_with("Right"):
		return 1
	var local_x := flat_dir.dot(host.global_basis.x.normalized()) if host else 0.0
	return 0 if local_x >= 0.0 else 1

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

## The torque loop: soft limits, neutral tension (if `neutral`) and muscles
## (if `muscles`, each joint scaled by its child's tone = per-bone strength)
## for every joint whose child body simulates. Torques are internal (equal
## and opposite on the parent), scaled by the joint's swing or twist inertia,
## and clamped. Every damping term is -c * I * (w . e) e on a single axis e,
## so it can only remove energy.
func _apply_torques(muscles: bool, neutral: bool) -> void:
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
		var w_pa: Vector3 = _av[pa] if _sim[pa] else Vector3.ZERO
		var ww: Vector3 = _av[c] - w_pa              # relative angular velocity, world
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
		if _j_limp[j]:
			pass
		elif p.use_neutral:
			kd += p.neutral_kd   # joint friction: even a limp chain does not swing for ever
			if neutral:
				err += _rotvec(_j_neutral[j] * q.inverse()) * p.neutral_kn
		if _held:
			kd += p.held_joint_damp
		var tone := _tone[c] if not _j_limp[j] else 0.0
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

## Kinematic (non-simulated) bodies follow the animated pose while chains
## simulate (they are never below a simulated bone).
func _follow_kinematic() -> void:
	var xfs := _fk_bodies(animator.pose_rot, _anim_hips(), rig.skeleton.global_transform)
	for i in _n:
		if _sim[i] or _severed[i]:
			continue
		_pbs[i].global_transform = xfs[i]
		PhysicsServer3D.body_set_state(_rids[i], PhysicsServer3D.BODY_STATE_TRANSFORM, xfs[i])
		_xf[i] = xfs[i]
		_lv[i] = Vector3.ZERO
		_av[i] = Vector3.ZERO

## The reaction's slide: `dist` m along `dir` over `time` s, slowing evenly.
func _set_push(dir: Vector3, dist: float, time: float) -> void:
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length_squared() < 1e-6 or dist <= 0.0 or time <= 0.0:
		_push_vel = Vector3.ZERO
		_push_decel = 0.0
		return
	var v0 := 2.0 * dist / time
	_push_vel = flat.normalized() * v0
	_push_decel = v0 / time

func _move_host_partial(delta: float) -> void:
	if not host.is_inside_tree():
		return
	var vy := host.velocity.y - Tuning.GRAVITY * delta if not host.is_on_floor() else -0.5
	host.velocity = Vector3(_push_vel.x, vy, _push_vel.z)
	host.move_and_slide()
	_push_vel = _push_vel.move_toward(Vector3.ZERO, _push_decel * delta)

## The legs step with the push (the Fighter does not drive locomotion while
## is_simulating()).
func _feed_locomotion() -> void:
	if animator and host and host.is_inside_tree():
		animator.set_locomotion(host.global_basis.inverse() * Vector3(_push_vel.x, 0.0, _push_vel.z), Tuning.WALK_SPEED)

## Stumble steps along `dir` for `duration` s: P's stumble_side_l/r,
## stumble_fwd or stumble_back when PoseLibrary has them; until then the
## `fallback_hold` loop (its legs alternate) over the pushed capsule.
func _play_steps(dir: Vector3, duration: float, fallback_hold: StringName) -> void:
	if animator == null:
		return
	var local := host.global_basis.inverse() * dir if host and host.is_inside_tree() else dir
	var id: StringName
	if absf(local.x) >= absf(local.z):
		id = &"stumble_side_r" if local.x > 0.0 else &"stumble_side_l"
	else:
		id = &"stumble_back" if local.z > 0.0 else &"stumble_fwd"
	animator.locked = true
	if PoseLibrary.has_move(id) and animator.has_method(&"_play_timed"):
		animator.call(&"_play_timed", id, duration)
	elif PoseLibrary.has_move(id):
		animator.locked = false
		animator.play_timed(id, duration)
		animator.locked = true
	else:
		animator._cancel(0.06)
		animator._hold(fallback_hold, 0.08)
	_anim_locked_by_reaction = true

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

## Write the skeleton pose: simulating bones show their physics pose (blended
## by their display weight in a partial ragdoll), the rest the animation.
## During a hitstop hold the visual jitters.
func _write_pose() -> void:
	var sinv := rig.skeleton.global_transform.affine_inverse()
	var anim: Array[Quaternion] = animator.pose_rot
	var pidx := HumanoidRig.parent_indices()
	var hips := _anim_hips()
	for bi in HumanoidRig.BONE_COUNT:
		var local: Quaternion = anim[bi]
		var p := pidx[bi]
		var pg: Basis = _final_basis[p] if p >= 0 else Basis()
		var i := _phys_of[bi]
		if i >= 0 and _sim[i] and not _severed[i]:
			var w := 1.0 if _full else _w[i]
			if w > 0.0:
				var g := sinv * _xf[i] * _off_inv[i]
				var pl := Quaternion((pg.transposed() * g.basis).orthonormalized())
				local = pl if w >= 1.0 else local.slerp(pl, w)
				if bi == 0:
					hips = g.origin if w >= 1.0 else hips.lerp(g.origin, w)
		_final_basis[bi] = pg * Basis(local)
		_out_rot[bi] = local
	if _hitstop_on and _jitter_amp > 0.0 and not _host_jitters():
		hips += Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-0.5, 0.5), _rng.randf_range(-1.0, 1.0)) * _jitter_amp
	rig.apply_pose(_out_rot, hips)

## The Fighter jitters its own rig during a freeze while its body is not
## "simulating" (FLINCH counts as not): then this node leaves it alone.
func _host_jitters() -> bool:
	return host.has_method(&"set_hitstop_jitter") and host.has_method(&"is_body_simulating") \
		and not host.is_body_simulating()

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
	_record_history(_snap_rot, _snap_hips, 0.0, true)
	_record_history(_snap_rot, _snap_hips, 0.0, true)

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

## Push the pose just written into the two-pose history the reaction
## velocities come from. Skipped while the host is frozen (a frozen animation
## would cache zero velocity) unless `force` (snapshots).
func _record_history(rots: Array[Quaternion], hips: Vector3, dt: float, force := false) -> void:
	if not force:
		if _frozen_now:
			return
		# The animator did not advance this tick (its time_scale was still 0
		# when it ran): the pose is the frozen one, keep the older history.
		var adt = animator.get(&"last_dt") if animator else null
		if adt is float and adt <= 0.0 and dt > 0.0:
			return
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

## Body index of exactly `bone` (-1 if it has no body).
func _body(bone: StringName) -> int:
	var si := HumanoidRig.bone_index(bone)
	return _phys_of[si] if si >= 0 else -1

## Body of `bone` or its nearest physical ancestor, severed included (strength queries).
func _body_for_any(bone: StringName) -> int:
	var b := bone
	while b != &"":
		var si := HumanoidRig.bone_index(b)
		if si >= 0 and _phys_of[si] >= 0:
			return _phys_of[si]
		b = Bones.PARENT.get(b, &"")
	return -1

## Body of `bone` or its nearest intact physical ancestor (the chest if none).
func _body_for(bone: StringName) -> int:
	var b := bone
	while b != &"":
		var si := HumanoidRig.bone_index(b)
		if si >= 0 and _phys_of[si] >= 0 and not _severed[_phys_of[si]]:
			return _phys_of[si]
		b = Bones.PARENT.get(b, &"")
	return _chest_i
