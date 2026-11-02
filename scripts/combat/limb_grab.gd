class_name LimbGrab
extends Node
## A grab by an arm or the legs (Upgrade 2: Body-zone targeting and limb grabs).
## The grabber's hand is jointed to the victim's physical bone and the rest of
## the victim ragdolls, so swinging is physics, not animation.
## Arm drag: swing the victim around you with the camera/mouse, release flings.
## Legs on a tumbling or downed victim: giant swing, then release.
## OWNER: agent G. CONTRACT STUB: B's grab flow calls these.
## Round 5: the game's grabs are Carry (carry.gd); nothing in play starts a
## limb grab any more. LimbGrab stays for the Grab Lab (key 8) and its tests.
##
## How it works (agent G):
## - The "hand" is an invisible kinematic body (no shape, no collision) per
##   gripped bone, pinned to the bone's grip point (wrist or ankle) with a Jolt
##   point constraint (PhysicsServer3D pin joint). Every tick the anchor moves
##   to a point on a small circle around the grabber (reach x height scale, at
##   hand height) at the swing yaw; Jolt moves kinematic bodies with a real
##   velocity, so the victim's body is dragged and flung by the joint chain.
##   Anchors start at the bone (zero joint error) and catch up with the hand at
##   ANCHOR_SPEED, so the grab reads as a yank, never a snap.
## - Swing yaw: chases a target yaw at up to SWING_RATE_MAX (rad/s) with
##   SWING_ACCEL. The player's target turns with the camera yaw (relative: only
##   camera turns swing the body); scripted callers (tests, AI) pass a world
##   direction to set_swing_input(). If the body is blocked (wall, crowd) and
##   the grip stretches past STRETCH_STOP the swing stops; past SLIP_DISTANCE
##   for SLIP_TIME the hand lets go (never an explosion).
## - Every victim bone's velocity is clamped to BONE_SPEED_MAX / BONE_SPIN_MAX
##   while held, and the held limb is made heavier on the physics server
##   (ARM_MASS_BOOST / LEG_MASS_BOOST) so Jolt keeps the limb's joints together
##   under the swing load (see _boost_limbs).
## - A standing victim is put in full ragdoll with Fighter.launch() (a small
##   yank toward the grabber; the victim's combat reacts as to a launch), then
##   RagdollController.set_gripped(true) keeps the body LAUNCHED and limp (no
##   muscles, landing, get-up or corpse freeze; a downed body goes back to
##   LAUNCHED) until set_gripped(false) on release, when it lands and gets up
##   normally. The victim's bones ignore the grabber's capsule while held.
## - Swing speed and the joint use the world (physics) delta, not
##   TimeDirector.player_delta: in Focus the swung body is world physics, and an
##   anchor moving at player speed would tear the joint.
## Spike numbers and the method comparison: tests/grab/test_spike.gd.

enum Kind { ARM_DRAG, GIANT_SWING }
## How the hand holds the bone. PIN is the shipped default (see the spike);
## the others stay for the grab lab.
enum Method { PIN, SIX_DOF, PULL }

# Local constants (candidates for Tuning).
const ARM_REACH := 0.45            ## m from the grabber's axis to the hands (x height), arm drag
const ARM_HEIGHT := 1.15           ## m above the grabber's feet (x height): the grab_hold fists
const LEG_REACH := 0.45            ## giant swing: ankles held at the waist...
const LEG_HEIGHT := 1.2            ## ...this high (x height): lifts the hips clear of the floor
const LEG_SPREAD := 0.09           ## m each ankle sits off the swing line
const GRIP_REACH := 2.0            ## m (x height): farthest grip point a limb grab can start on
const ANCHOR_SPEED := 7.0          ## m/s the hand moves toward its place on the circle
const LEG_ANCHOR_SPEED := 4.0      ## m/s for a giant swing: lifting the hips off the floor is the hardest yank
const SPIN_UP_TIME := 0.3          ## s the swing rate limit ramps from 0 after the grip takes...
const LEG_SPIN_UP_TIME := 0.6      ## ...for a giant swing (spinning up a whole body by the ankles)
const SWING_RATE_MAX := 6.0        ## rad/s swing yaw rate: flings the body at ~10 m/s (spike holds to 12)
const SWING_ACCEL := 24.0          ## rad/s^2
const SWING_GAIN := 8.0            ## 1/s yaw rate per radian of yaw error
const SWING_LEAD_MAX := PI         ## rad the input may run ahead of the swing
const SCRIPTED_INPUT_TIME := 0.25  ## s a set_swing_input() direction stays in charge
const BONE_SPEED_MAX := 18.0       ## m/s clamp on every victim bone while held
const BONE_SPIN_MAX := 35.0        ## rad/s
const STRETCH_STOP := 0.08         ## m grip stretch that stops the swing (body blocked)...
const STOP_HOLD := 0.12            ## ...for this long, then it pushes on toward the input
const SLIP_DISTANCE := 0.3         ## m grip stretch that makes the hand let go...
const SLIP_TIME := 0.1             ## ...after this long
const HOLD_MAX := 2.5              ## s a limb grab lasts before it releases by itself
const RELEASE_BOOST := 1.1         ## fling speed x the swing speed at release
const RELEASE_SPEED_MIN := 3.0     ## m/s even an unswung release tosses the body
const RELEASE_SPEED_MAX := 14.0    ## m/s
const RELEASE_BEND_MAX := 0.698    ## rad (40 deg) throw_dir may bend the fling
const START_YANK := 1.2            ## m/s toward the grabber when the grip takes a standing body
const BREAK_PUSH := 1.5            ## m/s away from the grabber on break_free()
const PULL_GAIN := 60.0            ## 1/s, Method.PULL only: grip error closed per second
const ARM_MASS_BOOST := 8.0        ## held arm's bodies x mass while gripped (Jolt solver aid, spike)
const LEG_MASS_BOOST := 3.0        ## held legs' bodies x mass (shin 3.3 : thigh 7 : hips 9.9 is already even)
const EXCEPTION_KEEP := 0.35       ## s the bones keep ignoring the grabber after the release

## Lab / spike overrides (not gameplay API).
static var method: int = Method.PIN
static var swing_rate_max := SWING_RATE_MAX
static var clamp_bones := true
static var hold_max := HOLD_MAX
## Held-limb mass multiplier (0 = ARM_MASS_BOOST / LEG_MASS_BOOST; 1 = off).
static var mass_boost := 0.0
## false = no swing stop or slip on stretch (the spike measures raw stretch).
static var safety := true

static var _grips := {}   # victim instance id -> LimbGrab

var grabber: Fighter
var victim: Fighter
var zone: int = BodyZones.Zone.ARM_R
var kind: int = Kind.ARM_DRAG
var bone: StringName = &""     ## primary gripped bone (first of the grips)
var start_time := 0.0          ## TimeDirector.now() when the grip took
var hold_method: int = Method.PIN

## Peak grip stretch (m) and fastest victim bone (m/s, rad/s) since start (lab, tests).
var peak_stretch := 0.0
var peak_bone_speed := 0.0
var peak_bone_spin := 0.0
var nan_ticks := 0

var _grips_list: Array[Dictionary] = []  # {bone, rid, local, anchor, pos, side, joint}
var _active := false
var _yaw := 0.0
var _rate := 0.0
var _target := 0.0
var _last_in := NAN
var _last_src := 0              # 0 none, 1 camera, 2 scripted
var _scripted_dir := Vector3.ZERO
var _scripted_until := -INF
var _held_t := 0.0
var _slip_t := 0.0
var _stop_t := 0.0
var _stretch := 0.0
var _excepted: Array[RID] = []
var _boosted: Array = []            # [rid, original mass] of the held limb's bodies

# --- Contract API ------------------------------------------------------------------
## True if `grabber` may start a limb grab on `victim` at `zone` (BodyZones.Zone).
## Arms: any living victim (standing, tumbling or downed). Legs: only a tumbling
## or downed victim (is_down(), or a stagger whose legs gave way). The grip
## bone must exist, not be severed, and lie within GRIP_REACH of the grabber;
## neither fighter may already be in a limb grab.
static func can_grip(p_grabber: Fighter, p_victim: Fighter, p_zone: int) -> bool:
	if p_grabber == null or p_victim == null or p_grabber == p_victim:
		return false
	if not is_instance_valid(p_grabber) or not is_instance_valid(p_victim):
		return false
	if not p_grabber.is_inside_tree() or not p_victim.is_inside_tree():
		return false
	if not BodyZones.is_limb(p_zone):
		return false
	if p_grabber.is_dead() or p_grabber.is_down() or p_victim.is_dead():
		return false
	if p_victim.rig == null or p_victim.ragdoll == null or p_victim.rig.skeleton == null:
		return false
	if get_grip_on(p_victim) != null or get_grip_by(p_grabber) != null or get_grip_on(p_grabber) != null:
		return false
	if p_zone == BodyZones.Zone.LEGS and not _is_tumbling_or_down(p_victim):
		return false
	var bones := _grip_bones(p_victim, p_zone)
	if bones.is_empty():
		return false
	var reach := GRIP_REACH * p_grabber.get_height_scale()
	for b in bones:
		var d := _grip_world(p_victim, b) - p_grabber.global_position
		d.y = 0.0
		if d.length() > reach:
			return false
	return true

## Starts the grab; the returned node lives under the grabber. null if refused.
## The victim goes limp at once (full ragdoll); emits GameEvents.limb_grab_started
## and asks ImpactResolver.track_swing(victim, grabber). Nothing is needed per
## tick from the caller: the node swings, times out (HOLD_MAX) and lets go by
## itself if the grabber goes down or the body is torn away; check is_active().
static func start(p_grabber: Fighter, p_victim: Fighter, p_zone: int) -> LimbGrab:
	if not can_grip(p_grabber, p_victim, p_zone):
		return null
	var lg := LimbGrab.new()
	lg.name = "LimbGrab"
	lg.grabber = p_grabber
	lg.victim = p_victim
	lg.zone = p_zone
	lg.kind = Kind.GIANT_SWING if p_zone == BodyZones.Zone.LEGS else Kind.ARM_DRAG
	lg.hold_method = method
	p_grabber.add_child(lg)
	if not lg._begin():
		lg.queue_free()
		return null
	return lg

func is_active() -> bool:
	return _active

## World direction the swing should pull toward (scripted tests and AI). The
## player's swing reads the camera itself. Holds for SCRIPTED_INPUT_TIME, so
## call it every tick while scripting.
func set_swing_input(dir: Vector3) -> void:
	var d := Vector3(dir.x, 0.0, dir.z)
	if d.length_squared() < 1e-6:
		return
	_scripted_dir = d.normalized()
	_scripted_until = TimeDirector.now() + SCRIPTED_INPUT_TIME

## Let go and fling the victim along its current swing velocity, biased to `throw_dir`.
## The fling speed is the swing speed x RELEASE_BOOST, within
## [RELEASE_SPEED_MIN, RELEASE_SPEED_MAX], lifted by Tuning.THROW_UP_ANGLE;
## throw_dir (flattened; ZERO = none) bends the direction by up to
## RELEASE_BEND_MAX. The victim is relaunched (GameEvents.fighter_launched, so the
## ImpactResolver sweeps the flight). Emits limb_grab_released with the velocity.
func release(throw_dir: Vector3) -> void:
	if not _active:
		return
	var v := _victim_velocity()
	var flat := Vector3(v.x, 0.0, v.z)
	var speed := flat.length() * RELEASE_BOOST
	var dir := flat.normalized() if flat.length() > 0.5 else _yaw_dir(_yaw)
	var want := Vector3(throw_dir.x, 0.0, throw_dir.z)
	if want.length_squared() > 0.01:
		var ang := dir.signed_angle_to(want.normalized(), Vector3.UP)
		dir = dir.rotated(Vector3.UP, clampf(ang, -RELEASE_BEND_MAX, RELEASE_BEND_MAX))
	speed = clampf(speed, RELEASE_SPEED_MIN, RELEASE_SPEED_MAX)
	var vel := dir * speed + Vector3.UP * (speed * tan(deg_to_rad(Tuning.THROW_UP_ANGLE)))
	var g := grabber
	var vic := victim
	var hit_bone := bone
	_end()
	if _alive(vic):
		vic.launch(vel - v, vic.get_center_of_mass(), hit_bone)
	GameEvents.limb_grab_released.emit(g, vic, vel)

## The victim broke free (Grab at the break timing): the hand opens, the body
## gets a small push away from the grabber and is free to get up. B plays the
## grabber's stagger (as for a torso grab break). Emits limb_grab_released with
## Vector3.ZERO (no fling).
func break_free() -> void:
	if not _active:
		return
	var g := grabber
	var vic := victim
	var away := Vector3.ZERO
	if _alive(g) and _alive(vic):
		away = vic.get_ground_position() - g.get_ground_position()
		away.y = 0.0
		away = away.normalized() if away.length() > 0.05 else g.get_forward()
	_end()
	if _alive(vic) and vic.ragdoll:
		vic.ragdoll.add_velocity(away * BREAK_PUSH)
	GameEvents.limb_grab_released.emit(g, vic, Vector3.ZERO)

# --- Extra API (agent G) -----------------------------------------------------------
## Let go without a fling (the grabber was hit, stunned or killed): the body
## keeps its own momentum. Emits limb_grab_released with that velocity.
func drop() -> void:
	if not _active:
		return
	var g := grabber
	var vic := victim
	var v := _victim_velocity()
	_end()
	GameEvents.limb_grab_released.emit(g, vic, v)

## The active limb grab holding `victim`, or null.
static func get_grip_on(f: Fighter) -> LimbGrab:
	if f == null or not is_instance_valid(f):
		return null
	var o: Variant = _grips.get(f.get_instance_id())
	if o == null or not is_instance_valid(o):
		return null
	var lg := o as LimbGrab
	return lg if lg != null and lg._active else null

## The active limb grab `grabber` is performing, or null.
static func get_grip_by(f: Fighter) -> LimbGrab:
	if f == null or not is_instance_valid(f):
		return null
	for c in f.get_children():
		var lg := c as LimbGrab
		if lg != null and lg._active:
			return lg
	return null

## Break window of a limb grab on `zone`, as Vector2(early, late) seconds: a
## Grab press from `early` s before the grab became active to `late` s after it
## connected breaks it. Torso-grab timing (Tuning.GRAB_BREAK_EARLY/LATE), times
## Tuning.ARM_DRAG_BREAK_MULT for arm drags.
static func break_window(p_zone: int) -> Vector2:
	var w := Vector2(Tuning.GRAB_BREAK_EARLY, Tuning.GRAB_BREAK_LATE)
	return w * Tuning.ARM_DRAG_BREAK_MULT if BodyZones.is_arm(p_zone) else w

## True if a victim's Grab press at `press_time` (TimeDirector.now()) falls in
## the late part of the break window (after the grip took).
func in_break_window(press_time: float) -> bool:
	var dt := press_time - start_time
	return _active and dt >= -1e-4 and dt <= break_window(zone).y + 1e-4

## Current grip stretch: largest hand-to-grip-point distance (m).
func get_stretch() -> float:
	return _stretch

## Swing yaw rate (rad/s, + = counter-clockwise seen from above).
func get_swing_rate() -> float:
	return _rate

## Swing yaw (rad, unwrapped; the Fighter rotation.y convention: 0 faces -Z).
func get_swing_yaw() -> float:
	return _yaw

## Centre-of-mass velocity of the held body.
func get_swing_velocity() -> Vector3:
	return _victim_velocity()

## Seconds since the grip took (game time).
func get_held_time() -> float:
	return _held_t

## World position of a grip's hand (anchor), for FX and debug draw.
func get_hand_position(i := 0) -> Vector3:
	return (_grips_list[i]["pos"] as Vector3) if i < _grips_list.size() else Vector3.ZERO

func get_grip_count() -> int:
	return _grips_list.size()

## World grip point (wrist/ankle) of grip i on the victim's body.
func get_grip_point(i := 0) -> Vector3:
	if i >= _grips_list.size():
		return Vector3.ZERO
	var g: Dictionary = _grips_list[i]
	var xf: Transform3D = PhysicsServer3D.body_get_state(g["rid"], PhysicsServer3D.BODY_STATE_TRANSFORM)
	return xf * (g["local"] as Vector3)

# --- Start / end ---------------------------------------------------------------------
func _begin() -> bool:
	process_physics_priority = 10   # after the Fighter moved its capsule this tick
	var bones := _grip_bones(victim, zone)
	if bones.is_empty():
		return false
	# A standing (or flinching, staggering, getting-up) body: full ragdoll with a
	# yank toward the grabber, through the Fighter so its combat reacts. A
	# tumbling or downed body is already a full ragdoll; set_gripped() keeps it
	# LAUNCHED and limp while held.
	var rd := victim.ragdoll
	if not rd.is_full_ragdoll():
		var to_g := grabber.global_position - _grip_world(victim, bones[0])
		to_g.y = 0.0
		to_g = to_g.normalized() if to_g.length() > 0.05 else -grabber.get_forward()
		victim.launch(to_g * START_YANK + Vector3.UP * 0.4, _grip_world(victim, bones[0]), bones[0])
	rd.set_gripped(true)
	if not rd.is_full_ragdoll():
		rd.set_gripped(false)
		return false
	# The body must not bump into the grabber's own capsule while it swings.
	var cap_rid := grabber.get_rid()
	for pb: PhysicalBone3D in victim.rig.get_physical_bones():
		var r := pb.get_rid()
		PhysicsServer3D.body_add_collision_exception(r, cap_rid)
		PhysicsServer3D.body_add_collision_exception(cap_rid, r)
		_excepted.append(r)
	# Swing starts pointing at the grip.
	var mid := Vector3.ZERO
	for b in bones:
		mid += _grip_world(victim, b)
	mid /= float(bones.size())
	var d := mid - grabber.global_position
	_yaw = atan2(-d.x, -d.z) if Vector2(d.x, d.z).length() > 0.05 else grabber.rotation.y
	_target = _yaw
	_rate = 0.0
	var space := grabber.get_world_3d().space
	for i in bones.size():
		var b: StringName = bones[i]
		var pb := victim.rig.get_physical_bone(b)
		var rid := pb.get_rid()
		var body_xf: Transform3D = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
		var local := _grip_local(victim, b)
		var p := body_xf * local
		var anchor := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(anchor, PhysicsServer3D.BODY_MODE_KINEMATIC)
		PhysicsServer3D.body_set_collision_layer(anchor, 0)
		PhysicsServer3D.body_set_collision_mask(anchor, 0)
		PhysicsServer3D.body_set_state(anchor, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), p))
		PhysicsServer3D.body_set_space(anchor, space)
		var side := 0.0
		if bones.size() > 1:
			side = -1.0 if b == Bones.L_LOWER_LEG else 1.0
		var g := {"bone": b, "rid": rid, "local": local, "anchor": anchor, "pos": p, "side": side, "joint": RID()}
		g["joint"] = _make_joint(anchor, rid, local, body_xf)
		_grips_list.append(g)
	_boost_limbs(bones)
	bone = bones[0]
	start_time = TimeDirector.now()
	_active = true
	_grips[victim.get_instance_id()] = self
	if grabber.animator:
		grabber.animator.hold_pose(&"grab_hold")
	grabber.snap_facing(_yaw_dir(_yaw))
	var ir := _impact_resolver()
	if ir:
		ir.track_swing(victim, grabber)
	GameEvents.limb_grab_started.emit(grabber, victim, bone)
	return true

## Joint between the anchor (at the grip point, identity basis) and the bone body.
func _make_joint(anchor: RID, rid: RID, local: Vector3, body_xf: Transform3D) -> RID:
	match hold_method:
		Method.PIN:
			var j := PhysicsServer3D.joint_create()
			PhysicsServer3D.joint_make_pin(j, anchor, Vector3.ZERO, rid, local)
			PhysicsServer3D.joint_disable_collisions_between_bodies(j, true)
			return j
		Method.SIX_DOF:
			var j := PhysicsServer3D.joint_create()
			# Same world orientation on both sides; linear axes locked, angular free.
			var lb := Transform3D(body_xf.basis.inverse(), local)
			PhysicsServer3D.joint_make_generic_6dof(j, anchor, Transform3D(), rid, lb)
			for axis in 3:
				PhysicsServer3D.generic_6dof_joint_set_flag(j, axis, PhysicsServer3D.G6DOF_JOINT_FLAG_ENABLE_LINEAR_LIMIT, true)
				PhysicsServer3D.generic_6dof_joint_set_param(j, axis, PhysicsServer3D.G6DOF_JOINT_LINEAR_LOWER_LIMIT, 0.0)
				PhysicsServer3D.generic_6dof_joint_set_param(j, axis, PhysicsServer3D.G6DOF_JOINT_LINEAR_UPPER_LIMIT, 0.0)
				PhysicsServer3D.generic_6dof_joint_set_flag(j, axis, PhysicsServer3D.G6DOF_JOINT_FLAG_ENABLE_ANGULAR_LIMIT, false)
			PhysicsServer3D.joint_disable_collisions_between_bodies(j, true)
			return j
	return RID()   # Method.PULL: scripted velocity servo, no joint

## Frees the joints and anchors, restores the victim, ends tracking. Idempotent.
func _end() -> void:
	if not _active:
		return
	_active = false
	for g in _grips_list:
		var j: RID = g["joint"]
		if j.is_valid():
			PhysicsServer3D.free_rid(j)
		PhysicsServer3D.free_rid(g["anchor"])
	_grips_list.clear()
	if victim and is_instance_valid(victim):
		for bm: Array in _boosted:
			PhysicsServer3D.body_set_param(bm[0], PhysicsServer3D.BODY_PARAM_MASS, bm[1])
	_boosted.clear()
	if victim and is_instance_valid(victim):
		_grips.erase(victim.get_instance_id())
		if victim.ragdoll:
			victim.ragdoll.set_gripped(false)
		var ir := _impact_resolver()
		if ir:
			ir.untrack_swing(victim)
	else:
		for id in _grips.keys():
			if _grips[id] == self:
				_grips.erase(id)
	if grabber and is_instance_valid(grabber) and grabber.animator \
			and grabber.animator.get_hold_id() == &"grab_hold":
		grabber.animator.release_pose()
	# Bones keep ignoring the grabber until the two have separated.
	var ex := _excepted.duplicate()
	_excepted.clear()
	var cap := grabber.get_rid() if grabber and is_instance_valid(grabber) else RID()
	var tree := get_tree()
	if tree and cap.is_valid() and not ex.is_empty():
		var wg: WeakRef = weakref(grabber)
		var wv: WeakRef = weakref(victim)
		TimeDirector.real_timer(EXCEPTION_KEEP).timeout.connect(func() -> void:
			if wg.get_ref() == null or wv.get_ref() == null:
				return
			for r: RID in ex:
				PhysicsServer3D.body_remove_collision_exception(r, cap)
				PhysicsServer3D.body_remove_collision_exception(cap, r))
	queue_free()

func _exit_tree() -> void:
	if _active:
		drop()

# --- Tick --------------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if not _active:
		return
	if not _alive(grabber) or not _alive(victim) or grabber.is_dead() or grabber.is_down() \
			or victim.ragdoll == null or not victim.ragdoll.is_full_ragdoll() or not victim.ragdoll.is_gripped():
		drop()
		return
	for g in _grips_list:
		if victim.rig.is_bone_severed(g["bone"]):
			drop()
			return
	if delta <= 0.0:
		return
	_held_t += delta
	_measure()
	if nan_ticks > 0:
		push_warning("LimbGrab: NaN in the held body; letting go")
		drop()
		return
	if safety and _stretch > SLIP_DISTANCE:
		_slip_t += delta
		if _slip_t >= SLIP_TIME:
			drop()
			return
	else:
		_slip_t = 0.0
	if _held_t >= hold_max:
		release(Vector3.ZERO)
		return
	var paused := grabber.is_frozen() or victim.is_frozen()
	if not paused:
		_update_yaw(delta)
	_move_anchors(delta, paused)
	if clamp_bones:
		_clamp_bones()
	grabber.snap_facing(_yaw_dir(_yaw))

## Stretch, peak bone speeds and NaN check from the bodies after the last step.
func _measure() -> void:
	var s := 0.0
	for g in _grips_list:
		var xf: Transform3D = PhysicsServer3D.body_get_state(g["rid"], PhysicsServer3D.BODY_STATE_TRANSFORM)
		var p := xf * (g["local"] as Vector3)
		if not p.is_finite():
			nan_ticks += 1
			continue
		s = maxf(s, p.distance_to(g["pos"]))
	_stretch = s
	peak_stretch = maxf(peak_stretch, s)
	for b in Bones.PHYSICAL:
		if victim.rig.is_bone_severed(b):
			continue
		var rid := victim.rig.get_physical_bone(b).get_rid()
		var lv: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		var av: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		if not lv.is_finite() or not av.is_finite():
			nan_ticks += 1
			continue
		peak_bone_speed = maxf(peak_bone_speed, lv.length())
		peak_bone_spin = maxf(peak_bone_spin, av.length())

func _update_yaw(delta: float) -> void:
	# Input: scripted direction first, then the player's camera (relative).
	var src := 0
	var y := NAN
	if TimeDirector.now() < _scripted_until:
		src = 2
		y = atan2(-_scripted_dir.x, -_scripted_dir.z)
	elif grabber.is_player:
		var cam := grabber.get_viewport().get_camera_3d() if grabber.get_viewport() else null
		if cam:
			var f := -cam.global_basis.z
			if Vector2(f.x, f.z).length() > 0.05:
				src = 1
				y = atan2(-f.x, -f.z)
	if src == 0:
		_last_src = 0
	elif src != _last_src:
		_last_src = src
		_last_in = y
		if src == 2:
			_target = _yaw + wrapf(y - _yaw, -PI, PI)
	else:
		_target += wrapf(y - _last_in, -PI, PI)
		_last_in = y
	_target = clampf(_target, _yaw - SWING_LEAD_MAX, _yaw + SWING_LEAD_MAX)
	var spin_up := LEG_SPIN_UP_TIME if kind == Kind.GIANT_SWING else SPIN_UP_TIME
	var cap := swing_rate_max * clampf(_held_t / spin_up, 0.0, 1.0)
	var want := clampf((_target - _yaw) * SWING_GAIN, -cap, cap)
	_rate = move_toward(_rate, want, SWING_ACCEL * delta)
	# A blocked body (wall, crowd) stops the swing for STOP_HOLD instead of
	# tearing the joint; the input target is kept, so it pushes on afterwards.
	if safety and _stretch > STRETCH_STOP:
		_stop_t = STOP_HOLD
	if _stop_t > 0.0:
		_stop_t -= delta
		_rate = 0.0
	_yaw += _rate * delta

func _move_anchors(delta: float, paused: bool) -> void:
	var h := grabber.get_height_scale()
	var leg := kind == Kind.GIANT_SWING
	var dir := _yaw_dir(_yaw)
	var side := dir.cross(Vector3.UP)
	var base := grabber.global_position + dir * ((LEG_REACH if leg else ARM_REACH) * h) \
		+ Vector3.UP * ((LEG_HEIGHT if leg else ARM_HEIGHT) * h)
	for g in _grips_list:
		var cur: Vector3 = g["pos"]
		var nxt := cur
		if not paused:
			var want := base + side * (LEG_SPREAD * float(g["side"]))
			var catch_up := LEG_ANCHOR_SPEED if leg else ANCHOR_SPEED
			nxt = cur.move_toward(want, catch_up * delta + absf(_rate) * (LEG_REACH if leg else ARM_REACH) * h * delta)
		g["pos"] = nxt
		PhysicsServer3D.body_set_state(g["anchor"], PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), nxt))
		if hold_method == Method.PULL:
			_pull(g, (nxt - cur) / delta, nxt, delta)

## Method.PULL: drive the grip point's velocity toward the hand (no joint).
func _pull(g: Dictionary, hand_v: Vector3, hand: Vector3, _delta: float) -> void:
	var rid: RID = g["rid"]
	var xf: Transform3D = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
	var lv: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	var av: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
	var p := xf * (g["local"] as Vector3)
	var vp := lv + av.cross(p - xf.origin)
	var want := hand_v + (hand - p) * PULL_GAIN
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, lv + (want - vp))
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING, false)

## Solver aid: while gripped, the held limb's bodies (forearm + upper arm, or
## shin + thigh + foot) weigh mass_boost x their mass on the physics server.
## Jolt's iterative solver cannot keep a 1.5 kg forearm on a kinematic hand
## rigid while it carries the other 68 kg (spike: elbow gap 15-21 cm at 6-12
## rad/s); evening out the mass ratios along the chain fixes it (x8: 3.6-5.3
## cm). RagdollController keeps its own mass table, so COM, total mass and
## impact energies are unchanged. Restored in _end().
func _boost_limbs(bones: Array[StringName]) -> void:
	var boost := mass_boost if mass_boost > 0.0 else (LEG_MASS_BOOST if kind == Kind.GIANT_SWING else ARM_MASS_BOOST)
	if is_equal_approx(boost, 1.0):
		return
	var rig := victim.rig
	var chain := {}
	for b in bones:
		for d in HumanoidRig.subtree(b):
			chain[d] = true
		var c := b
		while not (Bones.PARENT.get(c, &"") in [&"", Bones.HIPS, Bones.CHEST]):
			c = Bones.PARENT[c]
			chain[c] = true
	for b: StringName in chain:
		var pb := rig.get_physical_bone(b)
		if pb == null or rig.is_bone_severed(b):
			continue
		_boosted.append([pb.get_rid(), pb.mass])
		PhysicsServer3D.body_set_param(pb.get_rid(), PhysicsServer3D.BODY_PARAM_MASS, pb.mass * boost)

func _clamp_bones() -> void:
	for b in Bones.PHYSICAL:
		if victim.rig.is_bone_severed(b):
			continue
		var rid := victim.rig.get_physical_bone(b).get_rid()
		var lv: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		if lv.length() > BONE_SPEED_MAX:
			PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, lv.limit_length(BONE_SPEED_MAX))
		var av: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		if av.length() > BONE_SPIN_MAX:
			PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, av.limit_length(BONE_SPIN_MAX))

# --- Helpers -------------------------------------------------------------------------------
static func _alive(f: Fighter) -> bool:
	return f != null and is_instance_valid(f) and f.is_inside_tree() and not f.is_queued_for_deletion()

static func _is_tumbling_or_down(f: Fighter) -> bool:
	if f.is_down():
		return true
	return f.get_state() == RagdollController.State.STAGGER and f.ragdoll.is_full_ragdoll()

## Bones a limb grab on `zone` holds: the forearm for an arm, both shins for the legs.
static func _grip_bones(f: Fighter, p_zone: int) -> Array[StringName]:
	var out: Array[StringName] = []
	var want: Array[StringName] = []
	if BodyZones.is_arm(p_zone):
		want.append(BodyZones.AIM_BONE[p_zone])
	elif p_zone == BodyZones.Zone.LEGS:
		want.append_array([Bones.L_LOWER_LEG, Bones.R_LOWER_LEG])
	for b in want:
		if f.rig.get_physical_bone(b) != null and not f.rig.is_bone_severed(b):
			out.append(b)
	return out

## The grip point (wrist for a forearm, ankle for a shin) in the bone body's frame.
static func _grip_local(f: Fighter, b: StringName) -> Vector3:
	var child: StringName = Bones.L_HAND
	match b:
		Bones.R_LOWER_ARM: child = Bones.R_HAND
		Bones.L_LOWER_LEG: child = Bones.L_FOOT
		Bones.R_LOWER_LEG: child = Bones.R_FOOT
	var end := HumanoidRig.scaled(HumanoidRig.REST[child], f.rig.height_scale, f.rig.width_scale)
	return f.rig.get_body_offset(b).affine_inverse() * end

static func _grip_world(f: Fighter, b: StringName) -> Vector3:
	var pb := f.rig.get_physical_bone(b)
	if pb == null:
		return f.global_position
	var xf: Transform3D = pb.global_transform
	if pb.is_simulating_physics():
		xf = PhysicsServer3D.body_get_state(pb.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
	else:
		xf = f.rig.get_bone_global_transform(b) * f.rig.get_body_offset(b)
	return xf * _grip_local(f, b)

static func _yaw_dir(y: float) -> Vector3:
	return Vector3(-sin(y), 0.0, -cos(y))

func _victim_velocity() -> Vector3:
	return victim.get_com_velocity() if _alive(victim) else Vector3.ZERO

func _impact_resolver() -> Node:
	var ir := get_node_or_null(^"/root/ImpactResolver")
	return ir if ir and ir.has_method(&"track_swing") else null
