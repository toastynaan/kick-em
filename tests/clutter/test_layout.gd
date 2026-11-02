extends Node3D
## Round 6 clutter layout (agent K), on the real Yard:
## - at least Tuning.CLUTTER_MIN_COUNT breakable clutter objects of at least
##   Tuning.CLUTTER_MIN_KINDS kinds stand in the courtyard (plus some in the
##   side rooms), none skipped, each a full breakable (contract members, group,
##   WorldTags.breakable_of, surface meta);
## - every clearance, measured: YardBuilder.get_structure_features() keep-clear
##   areas (centre lanes, spawns, entries, breach lanes, platform and its
##   approach, low walls, partitions, pillars, crates, lamps, doors, plaza);
##   spawn paths (rays at 3 heights, +-0.3 m); every facade panel's breach spot
##   and walk-in; the player / duel spawns; the platform's open sides; every
##   wall-run lane's strip (0.2-1.6 m off the wall) and its 3 m open-floor
##   samples; vault approaches round crates and low walls; pillar faces;
## - every courtyard item has an approachable side (M's rule: a clear sprint
##   run-up of 2.5-6 m and clear floor past it for a vault or a run-through;
##   tall items a clear 1.5 m walk square to the broad face);
## - low clutter is a vaultable obstacle (top <= Tuning.VAULT_MAX), tall clutter
##   (shelf, glass) is a wall, glass and cardboard are not parkour obstacles;
## - enemies still path from every entry to the player spawn and round the platform;
## - camera fade reaches every mesh of every object;
## - a body slam (WorldDamage.blast, two 70 kg bodies at 11 m/s) in each lobby
##   breaks only glass and cardboard: everything else it reaches cracks or holds.

const LOW_APPROACH := 0.75
## m off a wall-run lane's wall: the run strip and the open floor beside it (D's run_open).
const RUN_OPEN_TO := 3.5
## M's approach rule (tests/move/test_yard_clutter): sprint run-ups tried (m),
## the walking run-up for tall items, and the clear floor needed past a vault.
const RUN_UPS: Array[float] = [6.0, 5.0, 4.0, 3.0, 2.5]
const WALK_RUN_UP := 1.5
const LAND := 2.8

var _ok := true

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[layout] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _ready() -> void:
	var yard := YardBuilder.new()
	yard.name = "Yard"
	add_child(yard)
	var t0 := Time.get_ticks_usec()
	yard.build()
	print("[layout] yard build with clutter: %.1f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	await ClutterTestUtil.frames(self, 3)
	var space := get_world_3d().direct_space_state
	var court := ClutterLayout.get_courtyard_items(yard)
	var all := ClutterLayout.get_items(yard)
	_check_counts(yard, court, all)
	_check_contract(all)
	_check_stacks(all)
	_check_features(yard, court)
	_check_paths(yard, space)
	_check_breach(yard, space)
	_check_spawns(yard, space, court)
	_check_lanes(yard, space)
	_check_margins(yard, court)
	_check_heights(all)
	_check_approach(yard, court)
	_check_nav(yard, space)
	_check_fade(all)
	_check_lobby_slams(yard)
	print("[layout] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _check_counts(yard: YardBuilder, court: Array[Furniture], all: Array[Furniture]) -> void:
	var kinds := {}
	var places := {}
	for f in court:
		kinds[f.kind] = int(kinds.get(f.kind, 0)) + 1
		places[f.get_meta(&"place")] = int(places.get(f.get_meta(&"place"), 0)) + 1
	var skipped := ClutterLayout.get_skipped(yard)
	_line("courtyard clutter: %d objects (min %d), %d kinds (min %d) %s; places %s; side rooms %d; skipped %s" % [
		court.size(), Tuning.CLUTTER_MIN_COUNT, kinds.size(), Tuning.CLUTTER_MIN_KINDS, kinds, places,
		all.size() - court.size(), skipped],
		court.size() >= Tuning.CLUTTER_MIN_COUNT and kinds.size() >= Tuning.CLUTTER_MIN_KINDS and skipped.is_empty()
		and all.size() > court.size())
	var every := true
	for k: StringName in Tuning.FURNITURE:
		every = every and kinds.has(k)
	_line("every Tuning.FURNITURE kind stands in the courtyard (%d of %d)" % [kinds.size(), Tuning.FURNITURE.size()], every)

func _check_contract(all: Array[Furniture]) -> void:
	var bad: Array = []
	for f in all:
		var spec: Dictionary = Tuning.FURNITURE[f.kind]
		var ok: bool = f.is_in_group(&"breakables") and WorldTags.breakable_of(f) == f and f.has_method(&"receive_impact") \
			and f.has_method(&"receive_strike") and f.has_method(&"receive_blast") and f.has_method(&"get_face_normal") \
			and f.has_method(&"get_half_extent_along") and not f.is_broken \
			and is_equal_approx(f.absorption, float(spec["absorb"])) and f.surface == spec["surface"] \
			and WorldTags.surface_of(f) == spec["surface"] and f.collision_layer == Layers.DESTRUCTIBLE \
			and f.size.length() > 0.1
		if not ok:
			bad.append(f.name)
	_line("breakable contract on all %d objects (group, breakable_of, receive_*, absorb, surface, layer); bad %s" % [
		all.size(), bad], bad.is_empty())

## Gap (m) between two floor rectangles (negative: overlap depth).
static func _gap(a: AABB, b: AABB) -> float:
	var ox := minf(a.end.x, b.end.x) - maxf(a.position.x, b.position.x)
	var oz := minf(a.end.z, b.end.z) - maxf(a.position.z, b.position.z)
	if ox > 0.0 and oz > 0.0:
		return -minf(ox, oz)
	var dx := maxf(0.0, maxf(a.position.x - b.end.x, b.position.x - a.end.x))
	var dz := maxf(0.0, maxf(a.position.z - b.end.z, b.position.z - a.end.z))
	return sqrt(dx * dx + dz * dz)

static func _foot(f: Furniture) -> AABB:
	return ClutterLayout.footprint(f.kind, f.variant, f.transform)

func _check_features(yard: YardBuilder, court: Array[Furniture]) -> void:
	if not yard.has_method(&"get_structure_features"):
		_line("YardBuilder.get_structure_features() missing", false)
		return
	var gaps := {}
	var who := {}
	var hits: Array = []
	for d: Dictionary in yard.get_structure_features():
		if not bool(d["keep_clear"]):
			continue
		var kind: StringName = d["kind"]
		var a: AABB = d["aabb"]
		for f in court:
			var g := _gap(_foot(f), a)
			if g < float(gaps.get(kind, INF)):
				gaps[kind] = g
				who[kind] = f.name
			if g < 0.0:
				hits.append("%s in %s" % [f.name, kind])
	var s := ""
	for k: StringName in gaps:
		s += "%s %.2f (%s), " % [k, gaps[k], who[k]]
	_line("keep-clear features, min gap to clutter (m): %s overlaps %s" % [s, hits], hits.is_empty())

## Rays along every spawn path (3 heights, +-0.3 m) hit no clutter.
func _check_paths(yard: YardBuilder, space: PhysicsDirectSpaceState3D) -> void:
	var blocked: Array = []
	for s: Dictionary in yard.get_enemy_spawns():
		var pts: Array[Vector3] = [s["position"]]
		for p in (s["path"] as PackedVector3Array):
			pts.append(p)
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			var side := Vector3(-(b - a).normalized().z, 0, (b - a).normalized().x) * 0.3
			for h in [0.3, 1.0, 1.7]:
				for off: Vector3 in [Vector3.ZERO, side, -side]:
					var q := PhysicsRayQueryParameters3D.create(a + Vector3(0, h, 0) + off, b + Vector3(0, h, 0) + off,
						Layers.DESTRUCTIBLE | Layers.DEBRIS)
					var hit := space.intersect_ray(q)
					if not hit.is_empty() and _is_clutter(hit["collider"]):
						blocked.append("%s seg %d" % [s["name"], i])
	_line("enemy spawn paths (%d) clear of clutter at 0.3/1.0/1.7 m, +-0.3 m: blocked %s" % [
		yard.get_enemy_spawns().size(), blocked], blocked.is_empty())

func _is_clutter(c: Object) -> bool:
	return c is Furniture or c is LooseFurniture

func _clutter_in(space: PhysicsDirectSpaceState3D, shape: Shape3D, xf: Transform3D) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = xf
	q.collision_mask = Layers.DESTRUCTIBLE | Layers.DEBRIS
	for r: Dictionary in space.intersect_shape(q, 16):
		if _is_clutter(r["collider"]):
			return true
	return false

## Every facade panel: its breach spot (inside) and the walk to it, and the
## 2.5 m in front of it (courtyard side), are free of clutter.
func _check_breach(yard: YardBuilder, space: PhysicsDirectSpaceState3D) -> void:
	var panels := 0
	var bad: Array = []
	var cyl := CylinderShape3D.new()
	cyl.radius = YardBuilder.BREACH_CLEARANCE
	cyl.height = 1.8
	for w in yard.get_destructibles():
		if not w.has_meta(&"facade"):
			continue
		panels += 1
		var into := w.global_basis.z
		into.y = 0.0
		into = into.normalized()
		var spot := yard.breach_spot(w)
		if _clutter_in(space, cyl, Transform3D(Basis(), spot + Vector3.UP * 1.05)):
			bad.append("%s spot" % w.name)
		var lane := BoxShape3D.new()
		lane.size = Vector3(2.0, 1.8, 2.5 + YardBuilder.BREACH_BEHIND)
		var mid := w.global_position + into * (2.5 - YardBuilder.BREACH_BEHIND) * 0.5
		mid.y = 1.05
		if _clutter_in(space, lane, Transform3D(Basis.looking_at(into, Vector3.UP), mid)):
			bad.append("%s lane" % w.name)
	_line("facade panels %d: breach spot (r %.1f) and the 2 m wide lane from it to 2.5 m into the courtyard clear; breach walls usable %d; bad %s" % [
		panels, YardBuilder.BREACH_CLEARANCE, yard.get_breach_walls().size(), bad], bad.is_empty() and panels > 10)

func _check_spawns(yard: YardBuilder, space: PhysicsDirectSpaceState3D, court: Array[Furniture]) -> void:
	var spots: Array[Vector3] = [yard.get_player_spawn().origin]
	for t in yard.get_duel_spawns():
		spots.append(t.origin)
	for s: Dictionary in yard.get_enemy_spawns():
		var path: PackedVector3Array = s["path"]
		spots.append(path[path.size() - 1])
	var worst := INF
	var ok := true
	for p in spots:
		var pq := PhysicsPointQueryParameters3D.new()
		pq.position = p + Vector3(0, 0.9, 0)
		pq.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
		if not space.intersect_point(pq).is_empty():
			ok = false
		var pt := AABB(Vector3(p.x, 0, p.z), Vector3.ZERO)
		for f in court:
			worst = minf(worst, _gap(_foot(f), pt))
	_line("player, duel and %d entry spots free; nearest clutter %.2f m (min 1.5)" % [
		yard.get_enemy_spawns().size(), worst], ok and worst >= 1.5)
	# Platform: capsule spots 1 and 2 m off the middle of each side (D's check).
	var pl: AABB = yard.get_parkour_features()["platform"]
	var pc := pl.get_center()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.5
	var open := true
	for k in 4:
		for out: float in [1.0, 2.0]:
			var p := pc
			match k:
				0: p.x = pl.position.x - out
				1: p.x = pl.end.x + out
				2: p.z = pl.position.z - out
				3: p.z = pl.end.z + out
			if _clutter_in(space, cap, Transform3D(Basis(), Vector3(p.x, 0.95, p.z))):
				open = false
	var near := INF
	for f in court:
		near = minf(near, _gap(_foot(f), pl))
	_line("platform: every side open at 1 and 2 m; nearest clutter %.2f m from it (min 2.3: 0.3 m past its 2 m approach)" % near,
		open and near >= 2.3)

## Every wall-run lane: the run strip (0.2-1.2 m off the wall) and the open
## floor beside it (1.2-3.5 m, D's run_open band) hold no clutter: capsule
## samples every 0.5 m along the lane at 0.5, 0.9, ... 3.3 m off the wall, and
## no clutter footprint comes within RUN_OPEN_TO m of the wall.
func _check_lanes(yard: YardBuilder, space: PhysicsDirectSpaceState3D) -> void:
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.5
	for lane: Dictionary in yard.get_wall_run_lanes():
		var a: Vector3 = lane["from"]
		var b: Vector3 = lane["to"]
		var n: Vector3 = lane["normal"]
		var length: float = lane["length"]
		var steps := int(length / 0.5)
		var strip_hits := 0
		var open_hits := 0
		var open_samples := 0
		for i in steps + 1:
			var p := a.lerp(b, float(i) / float(steps))
			for off: float in [0.5, 0.9]:
				if _clutter_in(space, cap, Transform3D(Basis(), p + n * off + Vector3.UP * 0.95)):
					strip_hits += 1
			for k in 6:
				var off := 1.5 + 0.34 * k   # 1.5 .. 3.2 m: the capsule (r 0.3) covers 1.2 .. 3.5 m
				open_samples += 1
				if _clutter_in(space, cap, Transform3D(Basis(), p + n * off + Vector3.UP * 0.95)):
					open_hits += 1
		var nearest := INF
		for f in ClutterLayout.get_courtyard_items(yard):
			var fb := _foot(f)
			var c := fb.get_center()
			var along := (c - a).dot((b - a).normalized())
			if along < -0.5 or along > length + 0.5:
				continue
			var off := minf((fb.position - a).dot(n), (fb.end - a).dot(n))
			off = minf(off, (Vector3(fb.position.x, 0, fb.end.z) - a).dot(n))
			off = minf(off, (Vector3(fb.end.x, 0, fb.position.z) - a).dot(n))
			nearest = minf(nearest, off)
		_line("lane %s %.1f m: clutter in the run strip %d / %d samples, in the open floor beside it (1.2-3.5 m) %d / %d; nearest clutter %.2f m off the wall (min %.1f)" % [
			lane["name"], length, strip_hits, (steps + 1) * 2, open_hits, open_samples, nearest, RUN_OPEN_TO],
			strip_hits == 0 and open_hits == 0 and nearest >= RUN_OPEN_TO)

## Vault approaches round crates (0.6 m) and low walls (0.75 m on the vault
## sides), pillar faces (0.9 m), D's floor throwables (0.4 m).
func _check_margins(yard: YardBuilder, court: Array[Furniture]) -> void:
	var feat := yard.get_parkour_features()
	var crate_gap := INF
	for d: Destructible in feat["crates"]:
		var a := AABB(d.global_position - Vector3(0.55, d.global_position.y, 0.55), Vector3(1.1, 1.1, 1.1))
		for f in court:
			crate_gap = minf(crate_gap, _gap(_foot(f), a))
	# Low walls: 0.5 m all round, and nothing in the vault approach (0.75 m off
	# either long face, along the wall's length).
	var low_gap := INF
	var approach_hits: Array = []
	for a: AABB in feat["low_walls"]:
		var app := a
		if a.size.x < a.size.z:
			app = AABB(a.position - Vector3(LOW_APPROACH, 0, 0), a.size + Vector3(LOW_APPROACH * 2.0, 0, 0))
		else:
			app = AABB(a.position - Vector3(0, 0, LOW_APPROACH), a.size + Vector3(0, 0, LOW_APPROACH * 2.0))
		for f in court:
			low_gap = minf(low_gap, _gap(_foot(f), a))
			if _gap(_foot(f), app) < 0.0:
				approach_hits.append(f.name)
	var pillar_gap := INF
	for p: Pillar in feat["pillars"]:
		var a := AABB(p.global_position - Vector3(0.5, 0, 0.5), Vector3(1, 4, 1))
		for f in court:
			pillar_gap = minf(pillar_gap, _gap(_foot(f), a))
	var patch_gap := INF
	for r: Rect2 in [feat["water"], feat["metal"]]:
		var a := AABB(Vector3(r.position.x, 0, r.position.y), Vector3(r.size.x, 0.05, r.size.y))
		for f in court:
			patch_gap = minf(patch_gap, _gap(_foot(f), a))
	var prop_gap := INF
	for t in yard.get_throwables():
		if t.global_position.y > 0.3:
			continue
		var a := AABB(t.global_position, Vector3.ZERO)
		for f in court:
			prop_gap = minf(prop_gap, _gap(_foot(f), a))
	_line("crates %.2f m (min 0.6), low walls %.2f m (min 0.5; vault approach %.2f m off the long faces: in it %s), pillar faces %.2f m (min 0.5), water and metal patches %.2f m (min 0.3, nothing on them), floor throwables %.2f m (min 0.4)" % [
		crate_gap, low_gap, LOW_APPROACH, approach_hits, pillar_gap, patch_gap, prop_gap],
		crate_gap >= 0.6 and low_gap >= 0.5 and approach_hits.is_empty() and pillar_gap >= 0.5 and patch_gap >= 0.3 \
		and prop_gap >= 0.4)

func _check_heights(all: Array[Furniture]) -> void:
	var tops := {}
	var ok := true
	for f in all:
		var top := f.get_spec().bounds.end.y + f.position.y
		tops[f.kind] = maxf(float(tops.get(f.kind, 0.0)), f.get_spec().bounds.end.y)
		var runthrough := f.kind in Tuning.RUN_THROUGH_KINDS
		if runthrough:
			ok = ok and not WorldTags.is_obstacle(f)
		else:
			ok = ok and WorldTags.is_obstacle(f)
			if f.kind == &"shelf":
				ok = ok and top > Tuning.VAULT_MAX
			else:
				ok = ok and top <= Tuning.VAULT_MAX
	var s := ""
	for k: StringName in tops:
		s += "%s %.2f, " % [k, tops[k]]
	_line("tops (m): %s; low ones vaultable obstacles (<= %.1f), shelf / glass walls, glass and cardboard not parkour obstacles" % [
		s, Tuning.VAULT_MAX], ok)

func _check_nav(yard: YardBuilder, space: PhysicsDirectSpaceState3D) -> void:
	var grid := AINavGrid.new()
	grid.start_build(space)
	while not grid.step_build():
		pass
	var pl: AABB = yard.get_parkour_features()["platform"]
	var goals: Array[Vector3] = [yard.get_player_spawn().origin, Vector3(pl.position.x - 1.2, 0, pl.get_center().z),
		Vector3(pl.end.x + 1.2, 0, pl.get_center().z), Vector3(pl.get_center().x, 0, pl.position.z - 1.2),
		Vector3(pl.get_center().x, 0, pl.end.z + 1.2)]
	for t in yard.get_duel_spawns():
		goals.append(t.origin)
	var bad: Array = []
	for s: Dictionary in yard.get_enemy_spawns():
		var path: PackedVector3Array = s["path"]
		var entry := path[path.size() - 1]
		for g in goals:
			grid.find_path(entry, g)
			if not grid.last_path_complete:
				bad.append("%s->%s" % [s["name"], g])
	_line("nav: every entry reaches the player spawn, the duel spots and the platform sides through the clutter; failed %s" % [
		bad], bad.is_empty())

## The camera's blocker fade reaches every mesh of every object.
func _check_fade(all: Array[Furniture]) -> void:
	var meshes := 0
	var faded := 0
	for f in all:
		WorldMaterials.set_view_fade(f, 0.6)
		for g: Variant in f.get_meta(&"view_fade_geoms", []):
			var gi := g as GeometryInstance3D
			meshes += 1
			var sm := gi.material_override as ShaderMaterial
			if sm != null and sm.shader == WorldMaterials.fade_shader():
				if is_equal_approx(float(gi.get_instance_shader_parameter(&"view_fade")), 0.6):
					faded += 1
			elif gi.transparency > 0.4:
				faded += 1
		WorldMaterials.set_view_fade(f, 0.0)
	_line("camera fade: %d / %d meshes faded (shader dither or transparency)" % [faded, meshes], meshes > 0 and faded == meshes)

## Stacked boxes sit on the box under them (no floating, no sinking).
func _check_stacks(all: Array[Furniture]) -> void:
	var n := 0
	var bad: Array = []
	for f in all:
		if f.resting_on == null:
			continue
		n += 1
		var s := f.resting_on
		var top := s.position.y + s.get_spec().bounds.end.y
		var on := absf(f.position.y - top) < 0.005 and s.kind == f.kind
		var sf := ClutterLayout.footprint(s.kind, s.variant, s.transform)
		on = on and sf.has_point(Vector3(f.position.x, sf.get_center().y, f.position.z))
		if not on:
			bad.append(f.name)
	_line("stacked objects: %d, each resting on the one under it (bad %s)" % [n, bad], n >= 3 and bad.is_empty())

var _q := PhysicsShapeQueryParameters3D.new()

## M's approach rule, ported (tests/move/test_yard_clutter._clear_approach).
func _check_approach(yard: YardBuilder, court: Array[Furniture]) -> void:
	var cap := CapsuleShape3D.new()
	cap.radius = Fighter.CAPSULE_RADIUS
	cap.height = Fighter.CAPSULE_HEIGHT
	_q.shape = cap
	_q.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE | Layers.CAPSULE
	# Past an item, low clutter, run-through clutter, crates and low walls are
	# more parkour (a chain); only structure and tall clutter must leave room.
	var chain: Array = []
	for it in ClutterLayout.get_items(yard):
		var top := it.get_box_transform().origin.y + it.size.y * 0.5
		if (not it.get_spec().tall and top <= Tuning.VAULT_MAX + 0.01 and it.kind != &"glass") \
				or it.kind in Tuning.RUN_THROUGH_KINDS:
			chain.append(it)
	for crate in yard.get_parkour_features()["crates"]:
		chain.append(crate)
	for n in yard.find_children("LowWall_*", "", true, false):
		if n is CollisionObject3D:
			chain.append(n)
	var none: Array = []
	var short: Array = []
	var runups := {}
	for f in court:
		var top := f.get_box_transform().origin.y + f.size.y * 0.5
		var run_through := f.kind in Tuning.RUN_THROUGH_KINDS
		var tall := f.get_spec().tall or top > Tuning.VAULT_MAX + 0.01 or f.kind == &"glass"
		var r: Array = _clear_approach(f, not tall or run_through, [WALK_RUN_UP] if tall and not run_through else RUN_UPS,
			[0.0] if run_through else [0.0, -0.9, 0.9], chain)
		if r[0] == Vector3.ZERO:
			none.append("%s@(%.1f,%.1f)" % [f.kind, f.position.x, f.position.z])
			continue
		runups[f.name] = r[1]
		if float(r[1]) < 3.0:
			short.append("%s@(%.1f,%.1f) %.1f m" % [f.kind, f.position.x, f.position.z, r[1]])
		if tall and _square_approach(f) == Vector3.ZERO:
			none.append("%s@(%.1f,%.1f) walk" % [f.kind, f.position.x, f.position.z])
	var shortest := INF
	for k: String in runups:
		shortest = minf(shortest, float(runups[k]))
	_line("approach (M's rule): every courtyard item has a clear side: %d / %d; run-ups under 3 m: %s; none: %s" % [
		court.size() - none.size(), court.size(), short, none], none.is_empty())

func _clear_approach(f: Furniture, need_landing: bool, run_ups: Array, lanes: Array, chain: Array) -> Array:
	var c := f.get_box_transform().origin
	c.y = 0.0
	for run_up: float in run_ups:
		for i in 32:
			var a := TAU * i / 32.0
			var d := Vector3(sin(a), 0.0, cos(a))
			var h := f.get_half_extent_along(d)
			if not _sweep_clear(c - d * (h + run_up), c - d * (h + 0.45), [f]):
				continue
			var side := d.cross(Vector3.UP).normalized()
			var room := true
			if need_landing:
				for off: float in lanes:
					if not _sweep_clear(c + d * (h + 0.45) + side * off, c + d * (h + LAND) + side * off, chain):
						room = false
						break
			if room:
				return [d, run_up]
	return [Vector3.ZERO, 0.0]

func _square_approach(f: Furniture) -> Vector3:
	var b := f.get_box_transform().basis
	var axis := b.x.normalized() if f.size.x < f.size.z else b.z.normalized()
	axis.y = 0.0
	axis = axis.normalized()
	var c := f.get_box_transform().origin
	c.y = 0.0
	for d: Vector3 in [axis, -axis]:
		var h := f.get_half_extent_along(d)
		if _sweep_clear(c - d * (h + WALK_RUN_UP), c - d * (h + 0.45), [f]):
			return d
	return Vector3.ZERO

func _sweep_clear(a: Vector3, b: Vector3, ignore: Array) -> bool:
	var ex: Array[RID] = []
	for n in ignore:
		if is_instance_valid(n):
			ex.append((n as CollisionObject3D).get_rid())
	_q.exclude = ex
	_q.transform = Transform3D(Basis(), a + Vector3.UP * (Fighter.CAPSULE_HEIGHT * 0.5 + 0.06))
	var space := get_world_3d().direct_space_state
	if not space.intersect_shape(_q, 1).is_empty():
		return false
	_q.motion = b - a
	var r := space.cast_motion(_q)
	_q.motion = Vector3.ZERO
	return r.size() > 0 and r[0] >= 0.999

## A body slam's blast (WorldDamage's real blast, the energy WorldDamage gives
## a slam of two 70 kg bodies) in the middle of each lobby group.
func _check_lobby_slams(yard: YardBuilder) -> void:
	var power := 0.5 * 140.0 * 11.0 * 11.0
	for spot: Vector3 in [Vector3(-2.0, 0.1, 4.6), Vector3(2.9, 0.1, 6.1)]:
		var reached: Array = []
		var cb := func(_c: Vector3, _r: float, _p: float, _s: StringName, list: Array) -> void:
			reached.append_array(list)
		WorldDamage.blasted.connect(cb)
		WorldDamage.blast(spot, float(Tuning.BLAST[&"slam"]), power, &"slam")
		WorldDamage.blasted.disconnect(cb)
		var broke: Array = []
		var held: Array = []
		var bad: Array = []
		for r: Array in reached:
			var f := r[0] as Furniture
			if f == null:
				continue
			if f.is_broken:
				broke.append(f.kind)
				if not (f.kind in Tuning.RUN_THROUGH_KINDS):
					bad.append(f.name)
			else:
				held.append("%s:%s" % [f.kind, r[2]])
		_line("slam %.0f J at %s (radius %.1f): broke %s, held %s; wrongly broken %s" % [power, spot,
			float(Tuning.BLAST[&"slam"]), broke, held, bad], bad.is_empty() and held.size() >= 2)
