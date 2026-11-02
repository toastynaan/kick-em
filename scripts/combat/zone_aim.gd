class_name ZoneAim
extends RefCounted
## Body-zone aiming for the player (Upgrade 2: Body-zone targeting > Picking a
## zone). Each tick PlayerController calls update() with the soft target:
## 1. A ray from the screen centre of the active Camera3D is tested against
##    the target's hurtboxes (each Hurtbox knows its bone); the nearest one
##    along the ray picks the zone (BodyZones.of_bone).
## 2. A miss falls back to the torso.
## 3. The aimer's crouch forces the legs; a jump forces the head.
## 4. In Focus the aim is exact (no settle delay) and more forgiving: every
##    hurtbox is FOCUS_MARGIN fatter, so a near miss still picks the nearest part.
## Writes fighter.aim_zone / aim_bone and emits GameEvents.aim_zone_changed
## (aimer, target, zone) when the zone or the target changes (target null = none).
##
## The ray test is analytic against the hurtbox capsules (no physics query), so
## only the target's own hurtboxes count: the player's body, other enemies and
## walls never steal the aim. Fighters whose hurtbox set has no arm boxes
## (minions) get arm capsules built from the rig's bone positions, so every zone
## can be aimed at on every body.
## OWNER: agent H (body & player input).

const FOCUS_MARGIN := 0.15   ## m added to every hurtbox radius in Focus (forgiving aim)
const SETTLE_TIME := 0.06    ## player s a new zone must stay under the crosshair before it shows (outside Focus)
const MAX_RAY := 60.0        ## m
## Arm capsules for fighters without arm hurtboxes: [bone, from, to].
const ARM_SEGMENTS := [
	[&"LeftUpperArm", &"LeftUpperArm", &"LeftLowerArm"],
	[&"LeftLowerArm", &"LeftLowerArm", &"LeftHand"],
	[&"RightUpperArm", &"RightUpperArm", &"RightLowerArm"],
	[&"RightLowerArm", &"RightLowerArm", &"RightHand"],
]

var fighter: Fighter
## Current aim target (null = none).
var target: Fighter
## Bone the last ray hit (&"" on a miss or a forced zone). Debug, tests.
var hit_bone: StringName = &""
## Tests set this to aim without a camera: [origin, direction]. Empty = camera.
var ray_override: Array = []

var _shown_zone := -1
var _shown_target: Fighter = null
var _shown_once := false
var _pending_zone := -1
var _pending_since := 0.0
var _clock := 0.0

func _init(p_fighter: Fighter = null) -> void:
	fighter = p_fighter

## Run once per physics tick. `p_target` is the soft target (null = none),
## `delta` the physics delta, `focus` true while the player is in Focus.
func update(p_target: Fighter, delta: float, focus := false) -> void:
	if fighter == null:
		return
	_clock += TimeDirector.player_delta(delta)
	if p_target != null and (not is_instance_valid(p_target) or p_target.is_dead()):
		p_target = null
	var zone: int = BodyZones.Zone.TORSO
	var bone: StringName = &""
	hit_bone = &""
	if fighter.is_crouching():
		zone = BodyZones.Zone.LEGS
	elif fighter.is_airborne():
		zone = BodyZones.Zone.HEAD
	elif p_target != null:
		var ray := _ray()
		if not ray.is_empty():
			bone = pick_bone(p_target, ray[0], ray[1], FOCUS_MARGIN if focus else 0.0)
			hit_bone = bone
			if bone != &"":
				zone = BodyZones.of_bone(bone)
	var aim := aim_bone_for(zone, bone)
	# Outside Focus a new zone must hold for SETTLE_TIME so the highlight does
	# not flicker on a boundary; a new target, a forced zone or Focus shows at once.
	var instant := focus or p_target != target or bone == &"" or not _shown_once
	if zone != _shown_zone and not instant:
		if zone != _pending_zone:
			_pending_zone = zone
			_pending_since = _clock
		if _clock - _pending_since < SETTLE_TIME:
			return
	_pending_zone = -1
	target = p_target
	fighter.aim_zone = zone
	fighter.aim_bone = aim
	if not _shown_once or zone != _shown_zone or target != _shown_target:
		_shown_once = true
		_shown_zone = zone
		_shown_target = target
		GameEvents.aim_zone_changed.emit(fighter, target, zone)

## Forget the target (input disabled, death): torso, and tell listeners.
func clear() -> void:
	_pending_zone = -1
	target = null
	hit_bone = &""
	if fighter != null:
		fighter.aim_zone = BodyZones.Zone.TORSO
		fighter.aim_bone = Bones.CHEST
	if _shown_once and (_shown_target != null or _shown_zone != BodyZones.Zone.TORSO):
		_shown_zone = BodyZones.Zone.TORSO
		_shown_target = null
		GameEvents.aim_zone_changed.emit(fighter, null, BodyZones.Zone.TORSO)

## [origin, unit direction] of the screen-centre ray, or [] without a camera.
## The centre pixel's ray is the camera transform's -Z (h_offset/v_offset,
## used for the shoulder view, are part of that transform).
func _ray() -> Array:
	if ray_override.size() == 2:
		return ray_override
	if fighter == null or not fighter.is_inside_tree():
		return []
	var vp := fighter.get_viewport()
	var cam := vp.get_camera_3d() if vp else null
	if cam == null or not cam.is_inside_tree():
		return []
	var xf := cam.get_camera_transform()
	return [xf.origin, -xf.basis.z.normalized()]

## Bone of the target's hurtbox the ray hits first (&"" on a miss). With a
## margin, every capsule is that much fatter and, if no capsule is hit, the one
## nearest the ray within the margin is taken.
static func pick_bone(t: Fighter, origin: Vector3, dir: Vector3, margin := 0.0) -> StringName:
	if t == null or dir.length_squared() < 1e-8:
		return &""
	dir = dir.normalized()
	var best_bone: StringName = &""
	var best_t := INF
	var near_bone: StringName = &""
	var near_d := INF
	for cap in capsules_of(t):
		var r: float = cap[3] + margin
		var res := _ray_segment(origin, dir, cap[1], cap[2])
		var d: float = res.x
		var along: float = res.y
		if along < 0.0 or along > MAX_RAY:
			continue
		if d <= cap[3]:
			var entry := along - sqrt(maxf(cap[3] * cap[3] - d * d, 0.0))
			if entry < best_t:
				best_t = entry
				best_bone = cap[0]
		elif d <= r and d - cap[3] < near_d:
			near_d = d - cap[3]
			near_bone = cap[0]
	return best_bone if best_bone != &"" else near_bone

## The target's hurtbox capsules in world space: [bone, a, b, radius] each,
## plus rig-built arm capsules when the hurtbox set has no arms.
static func capsules_of(t: Fighter) -> Array:
	var out: Array = []
	var has_arm := false
	for hb in t.hurtboxes:
		if not is_instance_valid(hb) or not hb.is_inside_tree() or not hb.monitorable:
			continue
		for c in hb.get_children():
			var cs := c as CollisionShape3D
			if cs == null or cs.disabled or not (cs.shape is CapsuleShape3D):
				continue
			var shape := cs.shape as CapsuleShape3D
			var xf := cs.global_transform
			var sc := xf.basis.get_scale()
			var axis := xf.basis.y.normalized()
			var r := shape.radius * maxf(sc.x, sc.z)
			var half := maxf(shape.height * 0.5 * sc.y - r, 0.0)
			out.append([hb.bone, xf.origin - axis * half, xf.origin + axis * half, r])
			if BodyZones.is_arm(BodyZones.of_bone(hb.bone)):
				has_arm = true
	if not has_arm and t.rig != null and t.rig.skeleton != null:
		var w := float(t.config.get("appearance", {}).get("width", 1.0))
		for seg in ARM_SEGMENTS:
			var bone: StringName = seg[0]
			var a := t.rig.get_bone_global_position(seg[1])
			var b := t.rig.get_bone_global_position(seg[2])
			if a.distance_squared_to(b) < 1e-4:
				continue
			out.append([bone, a, b, float(Hurtbox.RADIUS.get(bone, 0.08)) * lerpf(1.0, w, 0.7)])
	return out

## Bone a strike aims at / a limb grab anchors to for `zone`. Torso and head
## keep the exact bone the ray hit (hips, spine, chest, head); limbs take the
## zone's anchor bone (BodyZones.AIM_BONE) on the side that was hit.
static func aim_bone_for(zone: int, bone: StringName) -> StringName:
	match zone:
		BodyZones.Zone.TORSO, BodyZones.Zone.HEAD:
			if bone != &"" and BodyZones.of_bone(bone) == zone:
				return bone
		BodyZones.Zone.LEGS:
			if String(bone).begins_with("Right"):
				return Bones.R_LOWER_LEG
	return BodyZones.AIM_BONE.get(zone, Bones.CHEST)

## Closest approach between a ray (origin o, unit dir d) and segment [a, b]:
## Vector2(distance, ray parameter at the closest point).
static func _ray_segment(o: Vector3, d: Vector3, a: Vector3, b: Vector3) -> Vector2:
	var u := b - a
	var w := o - a
	var uu := u.dot(u)
	var ud := u.dot(d)
	var uw := u.dot(w)
	var dw := d.dot(w)
	var s := 0.0   # segment parameter 0..1
	var t := 0.0   # ray parameter
	var den := uu - ud * ud  # |d| = 1
	if uu < 1e-8:
		t = -dw
	else:
		if den > 1e-8:
			s = clampf((uw - ud * dw) / den, 0.0, 1.0)
		t = s * ud - dw
		if t < 0.0:
			t = 0.0
			s = clampf(uw / uu, 0.0, 1.0)
		else:
			# Re-project: the clamped segment point may move the best ray point.
			s = clampf((t * ud + uw) / uu, 0.0, 1.0)
			t = maxf(s * ud - dw, 0.0)
	var p := o + d * t
	var q := a + u * s
	return Vector2(p.distance_to(q), t)
