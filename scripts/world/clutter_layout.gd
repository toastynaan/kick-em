class_name ClutterLayout
## Round 6: breakable clutter in the fight area (tables, coffee tables,
## benches, sofas, shelves, barrels, cardboard boxes, fences, glass panes,
## planters, chairs), placed by YardBuilder.build() after the spawns exist.
## OWNER: agent K (clutter). CONTRACT STUB: keep the signature.
##
## Designed as places, not scatter (map, north up, courtyard x, z in [-11, 11];
## the 3.5 m along every wall-run lane, D's run_open band, stays empty):
##
##   z=-11 +--door-[ ]--[ ]--[ROLL]--[ ]--[ ]--[ ]--+
##         |      P(-6,-6)      low wall  [cr][cr]  P(6,-6) |  MARKET (NE): a display
##         |  NW: bench, planters,  gl SHELF       bb      |  window and a full rack at
##         |      barrel, box     bb       (open)      |part|  the back, stalls (barrels,
##         |  [PLATFORM]  ~metal~ bb ch   TA ch  cb cb bb   |  chair, table, boxes) round
##         |  [ 1.8 m  ]   PLAZA        centre lanes        |  an open middle
##         |  ==railing==  SOFA   ~~water~~   L-railing,    |  GARDEN (E): railing L,
##         |  P(-6,6) [cr]  tb  player(0,6) gl SOFA ch bench|  bench, two planters
##         |         [cr]   ch           tb  [cr]  P(6,6)   |  LOBBY (Sifu 3): a sofa
##         |                            planter             |  group each side of the spawn
##   z=+11 +--------------- south concrete wall -------------+
##
## Every courtyard item has an approachable side (M's rule: a clear sprint
## run-up of 2.5-6 m and clear floor past it for the vault; tall items a clear
## walk to the broad face), so low clutter is vaulted, glass and cardboard
## smashed through and shelves walked into, all from the open floor.
##
## Outside the courtyard: a workshop in the garage (workbenches, shelves,
## barrels, cardboard), a storeroom in the closed middle office (shelf, boxes,
## a chair at the desk) and in the middle storage room (shelf, barrels, a box).
##
## Kept clear (measured by tests/clutter/test_layout): YardBuilder's
## get_structure_features() keep-clear areas (platform and its 2 m approach,
## low walls, partitions, pillars, crates, lamps, doors, plaza, every breach
## lane, every entry, the spawns, the centre lanes, every wall-run lane's strip
## and open floor), plus this layout's own margins: 0.3 m more round the
## platform's approach, a vault approach round the low walls and crates, 0.5 m
## off the pillar faces, 0.3 m round the water and metal patches, and D's floor
## throwables. Anything that would overlap a keep-clear area at build time (the
## Yard changed) is skipped and listed in get_skipped().

const HOLDER := "Clutter"

## [kind, centre (x, z), yaw degrees (0: front toward +Z), variant, place,
## stacked on the item just before it (false: on the floor)].
const ITEMS := [
	# Lobby east of the player spawn (Sifu 3): a sofa facing the pool, a glass
	# screen, a coffee table and a chair.
	[&"sofa", Vector2(3.2, 5.15), 180.0, &"", &"lobby", false],
	[&"glass", Vector2(1.95, 4.9), 90.0, &"narrow", &"lobby", false],
	[&"coffee_table", Vector2(1.95, 6.15), 90.0, &"", &"lobby", false],
	[&"chair", Vector2(4.55, 5.0), -90.0, &"", &"lobby", false],
	# Lobby west of the spawn, by the plaza: a sofa facing the spawn and a coffee table.
	[&"sofa", Vector2(-2.05, 3.55), 90.0, &"", &"lobby", false],
	[&"coffee_table", Vector2(-1.95, 5.8), 90.0, &"", &"lobby", false],
	# Railing run along the platform's south side, short of the south-west pillar.
	[&"fence", Vector2(-4.25, 4.5), 0.0, &"", &"railing", false],
	[&"fence", Vector2(-5.85, 4.5), 0.0, &"", &"railing", false],
	# Garden by the pool and the brick low wall: an L of railing, a bench, two planters.
	[&"fence", Vector2(6.3, 2.65), 0.0, &"", &"garden", false],
	[&"fence", Vector2(7.25, 3.3), 90.0, &"", &"garden", false],
	[&"bench", Vector2(6.15, 3.9), 0.0, &"", &"garden", false],
	[&"planter", Vector2(5.6, 3.25), 0.0, &"", &"garden", false],
	[&"planter", Vector2(5.95, 4.6), 0.0, &"", &"pillars", false],
	# Round the north-west pillar: a bench, planters, a barrel and a box.
	[&"bench", Vector2(-3.5, -6.85), 0.0, &"", &"pillars", false],
	[&"planter", Vector2(-4.2, -5.7), 0.0, &"", &"pillars", false],
	[&"barrel", Vector2(-2.45, -5.9), 0.0, &"", &"pillars", false],
	[&"planter", Vector2(-4.3, -4.75), 0.0, &"", &"pillars", false],
	[&"cardboard", Vector2(-2.35, -7.15), 10.0, &"", &"pillars", false],
	[&"cardboard", Vector2(-2.33, -7.13), -15.0, &"small", &"pillars", true],
	# Market (NE): a display window and a full rack at the back, stalls round an
	# open middle (every stall has a clear run-up and floor past it).
	[&"glass", Vector2(2.6, -5.0), 0.0, &"narrow", &"market", false],
	[&"shelf", Vector2(4.0, -5.1), 0.0, &"full", &"market", false],
	[&"barrel", Vector2(1.9, -3.9), 0.0, &"", &"market", false],
	[&"barrel", Vector2(1.9, -3.25), 0.0, &"", &"market", false],
	[&"chair", Vector2(1.9, -2.6), 90.0, &"", &"market", false],
	[&"table", Vector2(3.0, -1.75), 0.0, &"", &"market", false],
	[&"chair", Vector2(3.0, -2.45), 0.0, &"", &"market", false],
	[&"cardboard", Vector2(4.3, -1.8), 15.0, &"big", &"market", false],
	[&"cardboard", Vector2(4.3, -1.8), -10.0, &"small", &"market", true],
	[&"cardboard", Vector2(5.0, -1.7), -20.0, &"", &"market", false],
	[&"cardboard", Vector2(5.02, -1.68), 12.0, &"small", &"market", true],
	[&"barrel", Vector2(5.25, -2.5), 0.0, &"", &"market", false],
	[&"barrel", Vector2(6.25, -4.65), 0.0, &"", &"pillars", false],
	# Garage workshop (behind the roll door, clear of the breach spots and the spawn path).
	[&"table", Vector2(-2.0, -16.95), 0.0, &"", &"workshop", false],
	[&"table", Vector2(0.2, -16.95), 0.0, &"", &"workshop", false],
	[&"chair", Vector2(-2.0, -16.2), 180.0, &"", &"workshop", false],
	[&"chair", Vector2(0.2, -16.15), 165.0, &"", &"workshop", false],
	[&"shelf", Vector2(2.3, -17.2), 0.0, &"", &"workshop", false],
	[&"shelf", Vector2(3.7, -17.2), 0.0, &"full", &"workshop", false],
	[&"barrel", Vector2(-3.6, -17.1), 0.0, &"", &"workshop", false],
	[&"barrel", Vector2(-3.55, -16.45), 30.0, &"", &"workshop", false],
	[&"cardboard", Vector2(5.3, -17.05), 5.0, &"big", &"workshop", false],
	[&"cardboard", Vector2(5.32, -17.03), -20.0, &"small", &"workshop", true],
	[&"cardboard", Vector2(6.0, -16.95), 12.0, &"", &"workshop", false],
	# Closed middle office (west): a storage rack, boxes, a chair at the desk.
	[&"shelf", Vector2(-17.2, 0.4), 90.0, &"few", &"offices", false],
	[&"cardboard", Vector2(-15.0, 3.6), 0.0, &"big", &"offices", false],
	[&"cardboard", Vector2(-15.02, 3.62), 25.0, &"small", &"offices", true],
	[&"chair", Vector2(-16.0, -2.85), 180.0, &"", &"offices", false],
	# Middle storage room (east): a rack, barrels, a box.
	[&"shelf", Vector2(17.2, -0.4), -90.0, &"", &"storage", false],
	[&"barrel", Vector2(15.4, -1.4), 0.0, &"", &"storage", false],
	[&"barrel", Vector2(15.5, -0.75), 60.0, &"", &"storage", false],
	[&"cardboard", Vector2(15.3, -3.5), -10.0, &"big", &"storage", false],
]

## Courtyard bounds (YardBuilder.HALF): items inside count as fight-area clutter.
const COURTYARD_HALF := 11.0

## Build the clutter into `yard` (a YardBuilder) under a "Clutter" node.
static func build(yard: Node3D) -> void:
	if yard == null:
		return
	var old := yard.get_node_or_null(HOLDER)
	if old != null:
		yard.remove_child(old)
		old.queue_free()
	var holder := Node3D.new()
	holder.name = HOLDER
	yard.add_child(holder)
	var keep := keep_clear_areas(yard)
	var made := {}
	var skipped: Array = []
	for i in ITEMS.size():
		var it: Array = ITEMS[i]
		var kind: StringName = it[0]
		var at: Vector2 = it[1]
		var variant: StringName = it[3]
		var stacked: bool = it[5]
		var below: Furniture = made.get(i - 1) if stacked else null
		if stacked and below == null:
			skipped.append([i, kind, &"support_missing"])
			continue
		var y := 0.0
		if below != null:
			y = below.position.y + below.get_spec().bounds.end.y
		var xf := Transform3D(Basis(Vector3.UP, deg_to_rad(float(it[2]))), Vector3(at.x, y, at.y))
		var foot := footprint(kind, variant, xf)
		if below == null:
			var hit := _blocked(foot, keep)
			if hit != &"":
				skipped.append([i, kind, hit])
				continue
		var f := Furniture.create(kind, xf, variant)
		f.name = "%s_%d" % [String(kind).to_pascal_case(), i]
		f.set_meta(&"place", it[4])
		f.set_meta(&"layout_index", i)
		f.resting_on = below
		holder.add_child(f)
		made[i] = f
	holder.set_meta(&"skipped", skipped)

## Every clutter object the layout built in `yard` (broken ones included).
static func get_items(yard: Node3D) -> Array[Furniture]:
	var out: Array[Furniture] = []
	var holder := yard.get_node_or_null(HOLDER) if yard != null else null
	if holder == null:
		return out
	for c in holder.get_children():
		if c is Furniture:
			out.append(c)
	return out

## The ones standing in the courtyard (the fight area).
static func get_courtyard_items(yard: Node3D) -> Array[Furniture]:
	var out: Array[Furniture] = []
	for f in get_items(yard):
		var p := f.position
		if absf(p.x) <= COURTYARD_HALF and absf(p.z) <= COURTYARD_HALF:
			out.append(f)
	return out

## Items the last build skipped: [index, kind, reason (the keep-clear kind)].
static func get_skipped(yard: Node3D) -> Array:
	var holder := yard.get_node_or_null(HOLDER) if yard != null else null
	return holder.get_meta(&"skipped", []) if holder != null else []

## Floor footprint (yard frame, y 0 .. top) of a kind placed at `xf`.
static func footprint(kind: StringName, variant: StringName, xf: Transform3D) -> AABB:
	var spec := FurnitureKit.get_spec(kind, variant)
	return xf * spec.visual_bounds

## Keep-clear areas: YardBuilder.get_structure_features() entries with
## keep_clear (when the Yard has them), as [kind, AABB].
static func keep_clear_areas(yard: Node3D) -> Array:
	var out: Array = []
	if yard == null or not yard.has_method(&"get_structure_features"):
		return out
	for d: Dictionary in yard.call(&"get_structure_features"):
		if bool(d.get("keep_clear", false)):
			out.append([d.get("kind", &""), d["aabb"]])
	return out

## The first keep-clear area `foot` overlaps on the floor plan (&"" if none).
static func _blocked(foot: AABB, keep: Array) -> StringName:
	for k: Array in keep:
		var a: AABB = k[1]
		if foot.position.x < a.end.x and a.position.x < foot.end.x \
				and foot.position.z < a.end.z and a.position.z < foot.end.z:
			return k[0]
	return &""
