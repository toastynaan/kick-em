class_name ConcreteWall
extends StaticBody3D
## The Yard's static concrete (outer walls, columns, door frames, stairs) as a
## wall-strike target (round 3). Strikes never open it (the arena boundary
## holds): each hit pops tiny chips (StrikeMarks), and one crack decal per spot
## grows as hits pile up there; result is always &"hold". Dust and sound are
## F's. Layers.WORLD.
## OWNER: agent D (world).

## How near a hit counts as the same spot, how many spots are remembered, and
## the crack decal's size range (m) as a spot's strike power grows to GROW_POWER.
const SPOT_RADIUS := 0.6
const SPOTS_MAX := 32
const DECAL_SIZE := Vector2(0.7, 2.0)
const GROW_POWER := 1200.0

var _spots: Array = []        ## [Vector3 position, accumulated power, Decal or null]

func receive_strike(attacker: Node3D, hit_pos: Vector3, direction: Vector3, power: float) -> StringName:
	var n := _contact_normal(hit_pos, direction)
	var spot: Array = []
	for s: Array in _spots:
		if (s[0] as Vector3).distance_to(hit_pos) <= SPOT_RADIUS:
			spot = s
			break
	if spot.is_empty():
		spot = [hit_pos, 0.0, null]
		_spots.append(spot)
		if _spots.size() > SPOTS_MAX:
			_spots.pop_front()
	spot[1] = float(spot[1]) + maxf(power, 0.0)
	grow_decal(self, spot, 2, hit_pos, n, float(spot[1]), DECAL_SIZE, GROW_POWER)
	StrikeMarks.chips(self, hit_pos, n, direction, power, &"concrete")
	GameEvents.wall_struck.emit(attacker, self, hit_pos, n, power, &"hold", &"concrete")
	return &"hold"

## One crack decal per spot (kept in `holder[slot]`), sized by the spot's strike
## power. Shared with Pillar. A decal evicted by the global decal cap respawns.
static func grow_decal(context: Node, holder: Array, slot: int, pos: Vector3, n: Vector3, power: float,
		size_range: Vector2, grow_power: float) -> void:
	var sz := lerpf(size_range.x, size_range.y, clampf(power / grow_power, 0.0, 1.0))
	var d: Variant = holder[slot]
	if d == null or not is_instance_valid(d):
		var nd := Destructible.spawn_crack_decal(context, pos, n, 0.0)
		if nd == null:
			return
		holder[slot] = nd
		d = nd
	(d as Decal).size = Vector3(sz, 0.3, sz)

## Accumulated strike power at the spot nearest `pos` (tests / debug).
func get_spot_power(pos: Vector3) -> float:
	for s: Array in _spots:
		if (s[0] as Vector3).distance_to(pos) <= SPOT_RADIUS:
			return s[1]
	return 0.0

func _contact_normal(hit_pos: Vector3, direction: Vector3) -> Vector3:
	var d := direction.normalized() if direction.length() > 0.01 else Vector3.FORWARD
	if is_inside_tree():
		var q := PhysicsRayQueryParameters3D.create(hit_pos - d * 0.4, hit_pos + d * 0.4, Layers.WORLD)
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if not hit.is_empty() and hit["collider"] == self:
			return hit["normal"]
	return -d
