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
	if m.contains("kick") or m.contains("punt"):
		return &"kick"
	if m.contains("cross") or m.contains("hook") or m.contains("heavy") or m.contains("power") \
			or m.contains("smash") or m.contains("swing") or m.contains("thrust") or m.contains("charge"):
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
