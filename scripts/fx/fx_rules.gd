class_name FXRules
## Round 5 effect rules shared by BloodFX, AudioFX and ScreenFX (Feel
## Reference: Effects that sell power). Effect size follows ONE number: the
## hit tier for strikes, sprint_charge for movement. Pure helpers, no state.
## Other modules (MoveLibrary, WorldTags) are loaded at runtime so a file that
## is mid-edit elsewhere never stops the effects from compiling.
## OWNER: agent F (FX & audio).

const MOVE_LIBRARY := "res://scripts/combat/move_library.gd"
const WORLD_TAGS := "res://scripts/world/world_tags.gd"

## Tier of a landed hit. Round 5 hits carry HitInfo.tier; an older path that
## only set power or the legacy reaction still maps onto a tier.
static func tier_of(info: HitInfo) -> int:
	if info == null:
		return HitInfo.Tier.NONE
	if info.tier != HitInfo.Tier.NONE:
		return info.tier
	if info.power > 0.0:
		return Power.tier_of(info.power)
	match info.reaction:
		HitInfo.Reaction.STAGGER:
			return HitInfo.Tier.STAGGER
		HitInfo.Reaction.LAUNCH:
			return HitInfo.Tier.HARD_LAUNCH if info.energy >= 4500.0 else HitInfo.Tier.LAUNCH
	return HitInfo.Tier.FLINCH

## 0..1 position of a tier on the ladder (flinch 0 .. severing launch 1).
static func tier_t(tier: int) -> float:
	return clampf(float(tier - HitInfo.Tier.FLINCH) / float(HitInfo.Tier.SEVER - HitInfo.Tier.FLINCH), 0.0, 1.0)

## Power-score class of a move id (Tuning.POWER_BASE keys) from its name.
## Round 7 ids: the roundhouse is a kick; the uppercut and gut punch are
## rear-hand punches (cross class).
static func strike_class(move_id: StringName) -> StringName:
	var m := String(move_id)
	if m.contains("sweep"):
		return &"sweep"
	if m.contains("knee") or m.contains("headbutt"):
		return &"knee"
	if m.contains("elbow"):
		return &"elbow"
	if m.contains("stomp") or m.contains("ground") or m.contains("knee_drop"):
		return &"ground"
	if m.contains("kick") or m.contains("punt") or m.contains("roundhouse"):
		return &"kick"
	if m.contains("cross") or m.contains("hook") or m.contains("heavy") or m.contains("power") \
			or m.contains("smash") or m.contains("swing") or m.contains("thrust") or m.contains("charge") \
			or m.contains("uppercut") or m.contains("gut"):
		return &"cross"
	return &"jab"

## The striking bone of a move: MoveData.limb when the move library knows it,
## else from the move's class (jab left hand, cross right hand, kicks right foot).
static func strike_limb(move_id: StringName) -> StringName:
	var md := _move(move_id)
	if md != null:
		var limb = md.get(&"limb")
		if limb != null and StringName(limb) != &"":
			return StringName(limb)
	match strike_class(move_id):
		&"jab":
			return Bones.L_HAND
		&"kick", &"sweep", &"ground":
			return Bones.R_FOOT
		&"knee":
			return Bones.R_LOWER_LEG
		&"elbow":
			return Bones.R_LOWER_ARM
	return Bones.R_HAND

## Real seconds (startup, active) of a move: MoveData when known, else
## Tuning.STRIKE_FRAMES for its class. A charged move's hold is not included.
static func strike_window(move_id: StringName) -> Vector2:
	var md := _move(move_id)
	if md != null and md.has_method(&"startup_s") and md.has_method(&"active_s"):
		return Vector2(float(md.call(&"startup_s")), float(md.call(&"active_s")))
	var f: Vector3 = Tuning.STRIKE_FRAMES.get(strike_class(move_id), Vector3(5, 3, 10))
	return Vector2(Tuning.frames(f.x), Tuning.frames(f.y))

static func _move(move_id: StringName) -> Object:
	if move_id == &"" or not ResourceLoader.exists(MOVE_LIBRARY):
		return null
	var lib = load(MOVE_LIBRARY)
	if lib == null or not lib.has_method(&"get_move"):
		return null
	return lib.call(&"get_move", move_id)

## Floor material of a collider: WorldTags.surface_of when it loads, else the
## documented tagging (meta "surface" on the collider or an ancestor).
static func surface_of(collider: Object) -> StringName:
	if collider == null:
		return &"concrete"
	if ResourceLoader.exists(WORLD_TAGS):
		var tags = load(WORLD_TAGS)
		if tags != null and tags.has_method(&"surface_of"):
			return StringName(tags.call(&"surface_of", collider))
	var n := collider as Node
	for i in 4:
		if n == null:
			break
		if n.has_meta(&"surface"):
			return StringName(n.get_meta(&"surface"))
		n = n.get_parent()
	return &"concrete"

## Surface under a point: a short ray down through world and destructible
## geometry. Call from physics-time code (event handlers of physics events).
static func floor_surface(world: World3D, position: Vector3) -> StringName:
	if world == null:
		return &"concrete"
	var space := world.direct_space_state
	if space == null:
		return &"concrete"
	var q := PhysicsRayQueryParameters3D.create(position + Vector3.UP * 0.4, position + Vector3.DOWN * 1.2,
			Layers.WORLD | Layers.DESTRUCTIBLE)
	var hit := space.intersect_ray(q)
	return surface_of(hit.get(&"collider")) if not hit.is_empty() else &"concrete"

## The player fighter (group "player"), or null.
static func player(tree: SceneTree) -> Node3D:
	return tree.get_first_node_in_group(&"player") as Node3D if tree != null else null

## sprint_charge of a fighter's Traversal (0 when it has none).
static func sprint_charge(f: Node) -> float:
	if f == null or not is_instance_valid(f):
		return 0.0
	var tr = f.get(&"traversal")
	if tr == null or not is_instance_valid(tr):
		return 0.0
	var c = tr.get(&"sprint_charge")
	return clampf(float(c), 0.0, 1.0) if c != null else 0.0

## A fighter that cannot be charging: dead, down, flying, or held by someone
## (an interrupted charge drops its glow and hum).
static func cannot_charge(f: Node) -> bool:
	if f == null or not is_instance_valid(f):
		return true
	for q in [&"is_dead", &"is_down", &"is_launched"]:
		if f.has_method(q) and f.call(q):
			return true
	var carry = f.get(&"carry")
	return carry != null and is_instance_valid(carry) and carry.has_method(&"is_held") and carry.call(&"is_held")


# =============================================================================
# Round 7: Freeflow combat (docs/Round 7 — Freeflow Combat.md, Effects and Hit
# feel). Player hits carry HitInfo.react and HitInfo.weight; their flash, ring,
# screen flash and sound layers follow the weight. Every other hit keeps the
# tier rules above.
# =============================================================================

## Glide distance (m) that gets the full rush: the longest glide the doc allows.
const GLIDE_FULL := Tuning.R7_GLIDE_SPEED * Tuning.R7_GLIDE_MAX_TIME
## Drive steps: one stride (m) per footstep at a run; the gap (s) between two
## steps stays inside DRIVE_STEP_GAP (fastest .. slowest).
const DRIVE_STRIDE := 1.7
const DRIVE_STEP_GAP := Vector2(0.17, 0.42)
const DEFAULT_MASS := 70.0       ## kg, a fighter whose mass is unknown

## A Round 7 player hit: effects follow HitInfo.weight instead of the tier.
static func is_round7(info: HitInfo) -> bool:
	return info != null and info.react != &""

## A player throw's release (G): a hit_landed with kind &"throw" and no damage.
## It is not a contact: no flash, ring, jitter or impact sound (the release
## whoosh comes from `thrown`); the thrown body's later impacts are contacts.
static func is_throw_release(info: HitInfo) -> bool:
	return info != null and info.kind == &"throw" and info.damage <= 0.0

## 0..1 weight of a hit: HitInfo.weight, or (a Round 7 source that left it 0)
## the tier's place on the ladder mapped onto the move weights (0.2 .. 1).
static func weight_of(info: HitInfo) -> float:
	if info == null:
		return 0.0
	if info.weight > 0.0:
		return clampf(info.weight, 0.0, 1.0)
	return lerpf(0.2, 1.0, tier_t(tier_of(info)))

## 0..1 share of the longest glide (rush level, speed streaks).
static func glide_share(distance: float) -> float:
	return clampf(distance / GLIDE_FULL, 0.0, 1.0)

## Current drive speed (m/s) of a holder `t` s into its drive: Traversal's
## get_drive_speed() when it reports one, else the doc's ease-out ramp from
## R7_DRIVE_START_SPEED to R7_DRIVE_MAX_SPEED over R7_DRIVE_RAMP_TIME.
static func drive_speed(holder: Node, t: float) -> float:
	if holder != null and is_instance_valid(holder):
		var tr = holder.get(&"traversal")
		if tr != null and is_instance_valid(tr) and (tr as Object).has_method(&"get_drive_speed"):
			var v := float(tr.call(&"get_drive_speed"))
			if v > 0.0:
				return v
	var u := clampf(t / maxf(Tuning.R7_DRIVE_RAMP_TIME, 0.01), 0.0, 1.0)
	return lerpf(Tuning.R7_DRIVE_START_SPEED, Tuning.R7_DRIVE_MAX_SPEED, 1.0 - (1.0 - u) * (1.0 - u))

## 0..1 place of a drive speed between the start and the top speed.
static func drive_share(speed: float) -> float:
	return clampf((speed - Tuning.R7_DRIVE_START_SPEED)
			/ maxf(Tuning.R7_DRIVE_MAX_SPEED - Tuning.R7_DRIVE_START_SPEED, 0.01), 0.0, 1.0)

## Seconds between two drive footsteps at `speed` m/s.
static func drive_step_gap(speed: float) -> float:
	return clampf(DRIVE_STRIDE / maxf(speed, 0.1), DRIVE_STEP_GAP.x, DRIVE_STEP_GAP.y)

## The doc's drive impact energy: 1/2 (victim mass + R7_DRIVE_MASS_SHARE x
## holder mass) v^2 (J).
static func drive_energy(victim: Node, holder: Node, speed: float) -> float:
	var m := mass_of(victim) + Tuning.R7_DRIVE_MASS_SHARE * mass_of(holder)
	return 0.5 * m * speed * speed

## 0..1 place of a throw speed between a tap and a full wind-up.
static func throw_share(speed: float) -> float:
	return clampf((speed - Tuning.R7_THROW_SPEED_MIN)
			/ maxf(Tuning.R7_THROW_SPEED_MAX - Tuning.R7_THROW_SPEED_MIN, 0.01), 0.0, 1.0)

## Mass (kg) of a fighter: get_total_mass(), a mass_kg member, else DEFAULT_MASS.
static func mass_of(f: Node) -> float:
	if f == null or not is_instance_valid(f):
		return DEFAULT_MASS
	if f.has_method(&"get_total_mass"):
		var m := float(f.call(&"get_total_mass"))
		if m > 0.0:
			return m
	var k = f.get(&"mass_kg")
	return float(k) if k != null and float(k) > 0.0 else DEFAULT_MASS

## World position of a limb: the centre of the bone's mesh part (the fist, not
## the wrist), else the bone origin, else chest height.
static func limb_point(f: Node3D, bone: StringName) -> Vector3:
	if f == null or not is_instance_valid(f):
		return Vector3.ZERO
	var rig = f.get(&"rig")
	if rig is Node3D and is_instance_valid(rig):
		if (rig as Node3D).has_method(&"get_bone_parts"):
			for part in rig.call(&"get_bone_parts", bone):
				if part is MeshInstance3D and is_instance_valid(part) and (part as MeshInstance3D).is_visible_in_tree():
					var mi := part as MeshInstance3D
					return mi.global_transform * mi.get_aabb().get_center()
		if (rig as Node3D).has_method(&"get_bone_global_position"):
			return rig.call(&"get_bone_global_position", bone)
	return f.global_position + Vector3.UP * 1.3

## God path (amendment): the pursuit spike's floor impact. B emits
## shockwave(attacker, pos, Tuning.R7_SPIKE_BLAST_RADIUS, 0.0); a heavy
## landing's shockwave always has a knockdown radius (and its own landing event).
static func is_spike_shockwave(knockdown_radius: float) -> bool:
	return knockdown_radius <= 0.0

## Feet of a fighter: get_ground_position(), else its origin.
static func feet_of(f: Node3D) -> Vector3:
	if f == null or not is_instance_valid(f):
		return Vector3.ZERO
	return f.call(&"get_ground_position") if f.has_method(&"get_ground_position") else f.global_position

## Flat facing of a fighter: get_forward(), else -basis.z.
static func forward_of(f: Node3D) -> Vector3:
	var v := Vector3.FORWARD
	if f != null and is_instance_valid(f):
		v = f.call(&"get_forward") if f.has_method(&"get_forward") else -f.global_basis.z
	v.y = 0.0
	return v.normalized() if v.length_squared() > 1e-6 else Vector3.FORWARD
