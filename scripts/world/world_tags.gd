class_name WorldTags
## Round 5 world queries for movement and effects: which surfaces can be run
## on, what a floor is made of, and what counts as an obstacle.
## OWNER: agent D (world). CONTRACT STUB: keep every public signature.
##
## Tagging (test scenes can tag their own geometry the same way):
## - runnable: the collider or one of its ancestors (up to TAG_DEPTH levels) is
##   in group "runnable"; if that node has is_runnable(), it must also return true
##   (a Destructible returns false once cracked, holed or broken, and for low
##   walls). In the Yard: the arena walls (body "ArenaWalls") and every wall
##   panel. Bodies (fighters, bones, dead bodies) and debris never are.
## - surface: meta "surface" (StringName) on the collider or an ancestor; else a
##   `surface` property (Destructible, Pillar, LooseProp); else &"concrete". The
##   Yard tags every floor: main floor &"concrete", offices &"wood", outside
##   &"dirt", plus a &"water" patch and a &"metal" plate in the courtyard.
## - obstacle: static geometry (StaticBody3D: walls, low walls, crates, the
##   platform, pillars, desks) unless meta "obstacle" = false on it or an
##   ancestor (meta "obstacle" = true makes any node one). Never a fighter, a
##   ragdoll bone, debris, a loose or throwable prop.

const TAG_DEPTH := 3

## Arena walls and building faces tagged runnable; destructible panels while
## intact (a cracked panel is not). Bodies and debris never.
static func is_runnable(collider: Object) -> bool:
	if _is_body_or_debris(collider):
		return false
	var n := collider as Node
	for i in TAG_DEPTH + 1:
		if n == null:
			return false
		if n.is_in_group(&"runnable"):
			return not n.has_method(&"is_runnable") or n.is_runnable()
		n = n.get_parent()
	return false

## Floor material for footsteps and landings: &"concrete" (default), &"dirt",
## &"wood", &"metal", &"water", &"drywall", &"brick".
static func surface_of(collider: Object) -> StringName:
	var n := collider as Node
	for i in TAG_DEPTH + 1:
		if n == null:
			break
		if n.has_meta(&"surface"):
			return StringName(n.get_meta(&"surface"))
		if n is Destructible or n is Pillar or n is LooseProp:
			return StringName(n.get(&"surface"))
		n = n.get_parent()
	return &"concrete"

## Static geometry the player can step, vault or mantle over (never a fighter,
## a ragdoll body, debris or a prop).
static func is_obstacle(collider: Object) -> bool:
	if collider == null or _is_body_or_debris(collider):
		return false
	var n := collider as Node
	for i in TAG_DEPTH + 1:
		if n == null:
			break
		if n.has_meta(&"obstacle"):
			return bool(n.get_meta(&"obstacle"))
		n = n.get_parent()
	return collider is StaticBody3D

## Round 6 breakable contract: the node (the collider or an ancestor up to
## TAG_DEPTH) that a flying body, a strike or a blast breaks, or null. A node is
## breakable when it is in group "breakables" or has receive_impact().
static func breakable_of(collider: Object) -> Node:
	var n := collider as Node
	for i in TAG_DEPTH + 1:
		if n == null:
			return null
		if n.is_in_group(&"breakables") or n.has_method(&"receive_impact"):
			return n
		n = n.get_parent()
	return null

## Fighters (capsules), ragdoll bones, dead bodies, debris and props.
static func _is_body_or_debris(collider: Object) -> bool:
	return collider is CharacterBody3D or collider is PhysicalBone3D or collider is RigidBody3D
