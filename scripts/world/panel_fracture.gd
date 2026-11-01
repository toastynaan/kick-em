class_name PanelFracture
extends RefCounted
## Procedural pre-fracture (spec: Destruction). Results are cached per
## (kind, surface, size, variant) so a yard of panels runs each algorithm a
## handful of times.
## OWNER: agent D (world).
##
## Kinds:
## - &"voronoi" (wall panels): a 2D Voronoi of the face with 20-26 seeds, lightly
##   biased to the centre; each convex cell is clipped out of the face rectangle
##   by half-planes and extruded through the thickness. Cells know their
##   neighbours and which panel sides they touch, so Destructible can punch a
##   body-sized hole and drop unsupported islands.
## - &"slats" (roll door): horizontal slats, each cut into 1-3 pieces.
## - &"crate", &"desk", &"lamp": prop pieces (planks, top + legs, pole).
##
## Per cell: `mesh` + inset `shape` relative to `origin` (for the flying chunk),
## and `static_shape`, the full-size hull in panel-local space (for the
## remaining wall's collider). Mesh vertex layout for WorldMaterials' shader:
## UV = panel-local (x, y), UV2.x = panel-local z, COLOR.r = 1 on original
## faces and 0 on fracture faces.

const SEEDS_MIN := 20
const SEEDS_MAX := 26
const VARIANTS := 3
## Chunks with a face area under this are "small" (Layers.DEBRIS_SMALL, fade).
const SMALL_AREA := 0.22
## Seed placement: exponent > 1 pulls seeds toward the centre.
const CENTER_BIAS := 1.25
const CRACK_WIDTH := 0.02
const CRACK_OFFSET := 0.004
## Flying-chunk hulls are inset from the visual cell so neighbouring chunks (and
## the floor and the cells left around the hole) never start interpenetrating:
## packed face to face, Jolt's contact friction locks them in place.
const SHAPE_INSET := 0.035
const SHAPE_DEPTH := 0.8

## Panel sides (Chunk.edge_mask).
const SIDE_LEFT := 1
const SIDE_RIGHT := 2
const SIDE_BOTTOM := 4
const SIDE_TOP := 8
## Sides that hold a wall cell up: neighbouring panels / frames and the floor.
const SUPPORT_SIDES := SIDE_LEFT | SIDE_RIGHT | SIDE_BOTTOM

class Chunk:
	var polygon: PackedVector2Array   ## Panel-local XY, counter-clockwise (panels).
	var centroid: Vector2             ## Panel-local XY.
	var origin: Vector3               ## Panel-local position of the chunk body origin.
	var area: float                   ## m^2 of face (panels) or footprint.
	var volume: float                 ## m^3.
	var mesh: ArrayMesh               ## Vertices relative to origin.
	var shape: ConvexPolygonShape3D   ## Inset hull, relative to origin (flying chunk).
	var static_shape: ConvexPolygonShape3D  ## Full hull, panel-local (remaining wall).
	var small: bool
	var neighbors := PackedInt32Array()
	var edge_mask := 0

class CrackEdge:
	var cells := Vector2i(-1, -1)
	var a: Vector2
	var b: Vector2
	var mid: Vector2
	var verts := PackedVector3Array()   ## Triangles, both faces.
	var normals := PackedVector3Array()

class FractureSet:
	var kind: StringName = &"voronoi"
	var size: Vector3
	var seeds: PackedVector2Array
	var chunks: Array = []            ## Array[Chunk]
	var intact_mesh: ArrayMesh
	var crack_mesh: ArrayMesh         ## Every crack edge (tests / previews).
	var edges: Array = []             ## Array[CrackEdge]
	var interior_edges: Array = []    ## Array of [Vector2, Vector2] (compat).
	## Props break whole (no partial holes).
	var full_only := false

static var _cache: Dictionary = {}

## Cached fracture set for a wall panel. `variant` wraps into 0..VARIANTS-1.
## style &"rolldoor" gives horizontal slats.
static func get_set(surface: StringName, size: Vector3, variant: int, style: StringName = &"") -> FractureSet:
	var v := posmod(variant, VARIANTS)
	var kind := &"slats" if style == &"rolldoor" else &"voronoi"
	var key := "%s|%s|%.3f|%.3f|%.3f|%d" % [kind, surface, size.x, size.y, size.z, v]
	if _cache.has(key):
		return _cache[key]
	var fs: FractureSet
	if kind == &"slats":
		fs = build_slats(size, hash(key))
	else:
		fs = build_set(size, hash(key))
	_cache[key] = fs
	return fs

## Cached piece set for a prop kind (&"crate", &"desk", &"lamp").
static func get_prop_set(kind: StringName, size: Vector3) -> FractureSet:
	var key := "prop|%s|%.3f|%.3f|%.3f" % [kind, size.x, size.y, size.z]
	if _cache.has(key):
		return _cache[key]
	var fs := build_prop(kind, size)
	_cache[key] = fs
	return fs

static func clear_cache() -> void:
	_cache.clear()

# --- Wall panels: Voronoi ---------------------------------------------------------

## Build a fresh (uncached) Voronoi set. Deterministic for a given seed.
static func build_set(size: Vector3, rng_seed: int) -> FractureSet:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var half := Vector2(size.x, size.y) * 0.5
	var seeds := _make_seeds(half, rng)
	var cells := voronoi_cells(half, seeds)
	var fs := _from_polygons(cells, size, rng)
	fs.kind = &"voronoi"
	fs.seeds = seeds
	return fs

## Roll door: 0.3 m horizontal slats, each cut into 1-3 pieces.
static func build_slats(size: Vector3, rng_seed: int) -> FractureSet:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var half := Vector2(size.x, size.y) * 0.5
	var rows := maxi(2, int(round(size.y / 0.3)))
	var rh := size.y / float(rows)
	var cells: Array = []
	for r in rows:
		var y0 := -half.y + rh * r
		var y1 := y0 + rh
		var cuts: Array[float] = [-half.x]
		var pieces := rng.randi_range(1, 3)
		for k in range(1, pieces):
			cuts.append(-half.x + size.x * (float(k) / pieces + rng.randf_range(-0.12, 0.12)))
		cuts.append(half.x)
		for k in cuts.size() - 1:
			cells.append(PackedVector2Array([Vector2(cuts[k], y0), Vector2(cuts[k + 1], y0),
				Vector2(cuts[k + 1], y1), Vector2(cuts[k], y1)]))
	var fs := _from_polygons(cells, size, rng)
	fs.kind = &"slats"
	return fs

static func _from_polygons(cells: Array, size: Vector3, rng: RandomNumberGenerator) -> FractureSet:
	var fs := FractureSet.new()
	fs.size = size
	var half := Vector2(size.x, size.y) * 0.5
	var t := size.z
	for poly: PackedVector2Array in cells:
		if poly.size() < 3:
			continue
		var area := polygon_area(poly)
		if area < 1e-4:
			continue
		var c := Chunk.new()
		c.polygon = poly
		c.area = area
		c.centroid = polygon_centroid(poly)
		c.origin = Vector3(c.centroid.x, c.centroid.y, 0.0)
		c.volume = area * t
		c.small = area < SMALL_AREA
		c.mesh = _prism_mesh(poly, -t * 0.5, t * 0.5, c.origin, half, false)
		c.shape = _prism_shape(poly, t, c.centroid, true)
		c.static_shape = _prism_shape(poly, t, Vector2.ZERO, false)
		for k in poly.size():
			var a := poly[k]
			var b := poly[(k + 1) % poly.size()]
			c.edge_mask |= _on_boundary(a, half) & _on_boundary(b, half)
		fs.chunks.append(c)
	_link_neighbors(fs, rng)
	var rect := PackedVector2Array([Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
		Vector2(half.x, half.y), Vector2(-half.x, half.y)])
	fs.intact_mesh = _prism_mesh(rect, -t * 0.5, t * 0.5, Vector3.ZERO, half, true)
	var all := PackedInt32Array()
	for i in fs.edges.size():
		all.append(i)
	fs.crack_mesh = crack_mesh_for(fs, all)
	return fs

## Two cells are neighbours when they share an edge segment longer than 2 cm.
static func _link_neighbors(fs: FractureSet, rng: RandomNumberGenerator) -> void:
	var n := fs.chunks.size()
	for i in n:
		for j in range(i + 1, n):
			var seg := _shared_segment(fs.chunks[i].polygon, fs.chunks[j].polygon)
			if seg.is_empty():
				continue
			(fs.chunks[i] as Chunk).neighbors.append(j)
			(fs.chunks[j] as Chunk).neighbors.append(i)
			var e := CrackEdge.new()
			e.cells = Vector2i(i, j)
			e.a = seg[0]
			e.b = seg[1]
			e.mid = (e.a + e.b) * 0.5
			_build_crack_strip(e, fs.size.z, rng)
			fs.edges.append(e)
			fs.interior_edges.append([e.a, e.b])

static func _shared_segment(p: PackedVector2Array, q: PackedVector2Array) -> Array:
	for k in p.size():
		var a := p[k]
		var b := p[(k + 1) % p.size()]
		var d := b - a
		var seg_len := d.length()
		if seg_len < 0.02:
			continue
		var u := d / seg_len
		for m in q.size():
			var c := q[m]
			var e := q[(m + 1) % q.size()]
			# Collinear within 2 mm?
			if absf(u.cross(c - a)) > 0.002 or absf(u.cross(e - a)) > 0.002:
				continue
			var t0 := u.dot(c - a)
			var t1 := u.dot(e - a)
			var lo := maxf(0.0, minf(t0, t1))
			var hi := minf(seg_len, maxf(t0, t1))
			if hi - lo > 0.02:
				return [a + u * lo, a + u * hi]
	return []

static func _make_seeds(half: Vector2, rng: RandomNumberGenerator) -> PackedVector2Array:
	var n := rng.randi_range(SEEDS_MIN, SEEDS_MAX)
	var seeds := PackedVector2Array()
	var min_d := 0.6 * sqrt(4.0 * half.x * half.y / float(n))
	var attempts := 0
	while seeds.size() < n and attempts < 6000:
		attempts += 1
		var u := rng.randf_range(-1.0, 1.0)
		var w := rng.randf_range(-1.0, 1.0)
		var p := Vector2(signf(u) * pow(absf(u), CENTER_BIAS) * half.x * 0.96,
			signf(w) * pow(absf(w), CENTER_BIAS) * half.y * 0.96)
		var ok := true
		for s in seeds:
			if s.distance_to(p) < min_d:
				ok = false
				break
		if ok:
			seeds.append(p)
		elif attempts % 400 == 0:
			min_d *= 0.88
	return seeds

## Voronoi cells of `seeds` clipped to the rectangle [-half, half].
## Each cell is a convex CCW polygon.
static func voronoi_cells(half: Vector2, seeds: PackedVector2Array) -> Array:
	var cells: Array = []
	for i in seeds.size():
		var poly := PackedVector2Array([Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
			Vector2(half.x, half.y), Vector2(-half.x, half.y)])
		for j in seeds.size():
			if i == j:
				continue
			var nrm := seeds[j] - seeds[i]
			var mid := (seeds[i] + seeds[j]) * 0.5
			poly = clip_half_plane(poly, mid, nrm)
			if poly.size() < 3:
				break
		cells.append(_dedupe(poly))
	return cells

## Keep the part of convex `poly` where (p - point) . normal <= 0.
static func clip_half_plane(poly: PackedVector2Array, point: Vector2, normal: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var count := poly.size()
	for k in count:
		var a := poly[k]
		var b := poly[(k + 1) % count]
		var da := (a - point).dot(normal)
		var db := (b - point).dot(normal)
		var a_in := da <= 0.0
		var b_in := db <= 0.0
		if a_in:
			out.append(a)
		if a_in != b_in:
			var t := da / (da - db)
			out.append(a.lerp(b, t))
	return out

## Part of convex `poly` inside the axis-aligned `rect`.
static func clip_rect(poly: PackedVector2Array, rect: Rect2) -> PackedVector2Array:
	var p := clip_half_plane(poly, rect.position, Vector2(-1, 0))
	if p.size() >= 3:
		p = clip_half_plane(p, rect.position, Vector2(0, -1))
	if p.size() >= 3:
		p = clip_half_plane(p, rect.end, Vector2(1, 0))
	if p.size() >= 3:
		p = clip_half_plane(p, rect.end, Vector2(0, 1))
	return p

static func point_in_convex(poly: PackedVector2Array, p: Vector2) -> bool:
	var n := poly.size()
	if n < 3:
		return false
	for k in n:
		var a := poly[k]
		var b := poly[(k + 1) % n]
		if (b - a).cross(p - a) < -1e-6:
			return false
	return true

static func _dedupe(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in poly:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > 1e-4:
			out.append(p)
	while out.size() > 1 and out[0].distance_to(out[out.size() - 1]) <= 1e-4:
		out.remove_at(out.size() - 1)
	return out

static func polygon_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for k in poly.size():
		var p := poly[k]
		var q := poly[(k + 1) % poly.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5

static func polygon_centroid(poly: PackedVector2Array) -> Vector2:
	var a := 0.0
	var c := Vector2.ZERO
	for k in poly.size():
		var p := poly[k]
		var q := poly[(k + 1) % poly.size()]
		var cr := p.x * q.y - q.x * p.y
		a += cr
		c += (p + q) * cr
	if absf(a) < 1e-9:
		var s := Vector2.ZERO
		for p in poly:
			s += p
		return s / float(poly.size())
	return c / (3.0 * a)

## True if every interior angle turns the same way (strictly convex or straight).
static func is_convex(poly: PackedVector2Array) -> bool:
	var n := poly.size()
	if n < 3:
		return false
	var sign_seen := 0
	for k in n:
		var a := poly[k]
		var b := poly[(k + 1) % n]
		var c := poly[(k + 2) % n]
		var cr := (b - a).cross(c - b)
		if absf(cr) < 1e-7:
			continue
		var s := 1 if cr > 0.0 else -1
		if sign_seen == 0:
			sign_seen = s
		elif s != sign_seen:
			return false
	return true

static func _on_boundary(p: Vector2, half: Vector2) -> int:
	var m := 0
	if absf(p.x + half.x) < 1e-3: m |= SIDE_LEFT
	if absf(p.x - half.x) < 1e-3: m |= SIDE_RIGHT
	if absf(p.y + half.y) < 1e-3: m |= SIDE_BOTTOM
	if absf(p.y - half.y) < 1e-3: m |= SIDE_TOP
	return m

static func _edge_is_exterior(a: Vector2, b: Vector2, half: Vector2) -> bool:
	return (_on_boundary(a, half) & _on_boundary(b, half)) != 0

# --- Props -----------------------------------------------------------------------

## Prop piece sets. Each piece is a box: [centre, size].
static func build_prop(kind: StringName, size: Vector3) -> FractureSet:
	var fs := FractureSet.new()
	fs.kind = kind
	fs.size = size
	fs.full_only = true
	var h := size * 0.5
	var boxes: Array = []
	match kind:
		&"crate":
			# Hollow crate of 3 planks per side, 2 on top, 2 on the bottom.
			var pt := 0.05
			for k in 3:
				var y := -h.y + size.y * (k + 0.5) / 3.0
				var ph := size.y / 3.0 - 0.01
				boxes.append([Vector3(0, y, h.z - pt * 0.5), Vector3(size.x, ph, pt)])
				boxes.append([Vector3(0, y, -h.z + pt * 0.5), Vector3(size.x, ph, pt)])
				boxes.append([Vector3(h.x - pt * 0.5, y, 0), Vector3(pt, ph, size.z - pt * 2.0)])
				boxes.append([Vector3(-h.x + pt * 0.5, y, 0), Vector3(pt, ph, size.z - pt * 2.0)])
			for s in [-1.0, 1.0]:
				boxes.append([Vector3(0, h.y - pt * 0.5, s * size.z * 0.25), Vector3(size.x - pt * 2.0, pt, size.z * 0.5 - 0.01)])
				boxes.append([Vector3(0, -h.y + pt * 0.5, s * size.z * 0.25), Vector3(size.x - pt * 2.0, pt, size.z * 0.5 - 0.01)])
		&"desk":
			var top := 0.04
			for s in [-1.0, 1.0]:
				boxes.append([Vector3(s * size.x * 0.25, h.y - top * 0.5, 0), Vector3(size.x * 0.5 - 0.005, top, size.z)])
			var leg := 0.05
			for sx in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					boxes.append([Vector3(sx * (h.x - 0.06), -top * 0.5, sz * (h.z - 0.06)), Vector3(leg, size.y - top, leg)])
			boxes.append([Vector3(0, 0.05, -h.z + 0.08), Vector3(size.x - 0.2, size.y * 0.45, 0.025)])
		&"lamp":
			# One piece: everything above the 0.35 m stump falls as a whole.
			var stump := 0.35
			boxes.append([Vector3(0, stump * 0.5, 0), Vector3(size.x, size.y - stump, size.z)])
		_:
			boxes.append([Vector3.ZERO, size])
	for b: Array in boxes:
		var c := Chunk.new()
		var center: Vector3 = b[0]
		var bs: Vector3 = b[1]
		c.origin = center
		c.centroid = Vector2(center.x, center.y)
		c.polygon = PackedVector2Array([Vector2(center.x - bs.x * 0.5, center.y - bs.y * 0.5),
			Vector2(center.x + bs.x * 0.5, center.y - bs.y * 0.5), Vector2(center.x + bs.x * 0.5, center.y + bs.y * 0.5),
			Vector2(center.x - bs.x * 0.5, center.y + bs.y * 0.5)])
		c.area = bs.x * bs.z
		c.volume = bs.x * bs.y * bs.z
		c.small = c.volume < 0.01
		c.mesh = _prism_mesh(c.polygon, center.z - bs.z * 0.5, center.z + bs.z * 0.5, center, Vector2(1e6, 1e6), true)
		var inset := Vector3(minf(0.01, bs.x * 0.2), minf(0.01, bs.y * 0.2), minf(0.01, bs.z * 0.2))
		c.shape = _box_points(bs * 0.5 - inset)
		c.static_shape = _box_points(bs * 0.5, center)
		fs.chunks.append(c)
	fs.intact_mesh = ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for c: Chunk in fs.chunks:
		st.append_from(c.mesh, 0, Transform3D(Basis(), c.origin))
	fs.intact_mesh = st.commit()
	fs.crack_mesh = ArrayMesh.new()
	return fs

static func _box_points(h: Vector3, center := Vector3.ZERO) -> ConvexPolygonShape3D:
	var pts := PackedVector3Array()
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				pts.append(center + Vector3(sx * h.x, sy * h.y, sz * h.z))
	var shape := ConvexPolygonShape3D.new()
	shape.points = pts
	return shape

# --- Mesh building ------------------------------------------------------------

## Adds one triangle with Godot's clockwise front-face winding for outward normal n.
static func _tri(st: SurfaceTool, v0: Vector3, v1: Vector3, v2: Vector3, n: Vector3,
		offset: Vector3, ext: float) -> void:
	var verts := [v0, v1, v2]
	if (v1 - v0).cross(v2 - v0).dot(n) > 0.0:
		verts = [v0, v2, v1]
	for v: Vector3 in verts:
		st.set_normal(n)
		st.set_color(Color(ext, ext, ext, 1.0))
		st.set_uv(Vector2(v.x, v.y))
		st.set_uv2(Vector2(v.z, 0.0))
		st.add_vertex(v - offset)

## Extruded prism of a convex CCW polygon between z0 and z1, vertices relative
## to `offset`. all_exterior marks every face as an original face.
static func _prism_mesh(poly: PackedVector2Array, z0: float, z1: float, offset: Vector3, half: Vector2,
		all_exterior: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := poly.size()
	for k in range(1, n - 1):
		var a := Vector3(poly[0].x, poly[0].y, z1)
		var b := Vector3(poly[k].x, poly[k].y, z1)
		var c := Vector3(poly[k + 1].x, poly[k + 1].y, z1)
		_tri(st, a, b, c, Vector3(0, 0, 1), offset, 1.0)
		var a2 := Vector3(poly[0].x, poly[0].y, z0)
		var b2 := Vector3(poly[k].x, poly[k].y, z0)
		var c2 := Vector3(poly[k + 1].x, poly[k + 1].y, z0)
		_tri(st, a2, b2, c2, Vector3(0, 0, -1), offset, 1.0)
	for k in n:
		var p := poly[k]
		var q := poly[(k + 1) % n]
		var d := q - p
		if d.length() < 1e-5:
			continue
		var nrm := Vector3(d.y, -d.x, 0.0).normalized()
		var ext := 1.0 if all_exterior or _edge_is_exterior(p, q, half) else 0.0
		var pf := Vector3(p.x, p.y, z1)
		var qf := Vector3(q.x, q.y, z1)
		var pb := Vector3(p.x, p.y, z0)
		var qb := Vector3(q.x, q.y, z0)
		_tri(st, pf, qf, qb, nrm, offset, ext)
		_tri(st, pf, qb, pb, nrm, offset, ext)
	return st.commit()

## Hull of a prism of thickness t. inset = true shrinks it (flying chunk) and
## makes it relative to `center`; false keeps the full cell in panel space.
static func _prism_shape(poly: PackedVector2Array, t: float, center: Vector2, inset: bool) -> ConvexPolygonShape3D:
	var pts := PackedVector3Array()
	var hz := t * 0.5 * (SHAPE_DEPTH if inset else 1.0)
	for p in poly:
		var r := p - center
		var q := r
		if inset:
			var r_len := r.length()
			q = r * (maxf(r_len - SHAPE_INSET, r_len * 0.6) / r_len) if r_len > 1e-5 else r
		pts.append(Vector3(q.x, q.y, hz))
		pts.append(Vector3(q.x, q.y, -hz))
	var shape := ConvexPolygonShape3D.new()
	shape.points = pts
	return shape

## Jagged dark strip along a shared cell edge, slightly proud of both faces.
static func _build_crack_strip(e: CrackEdge, t: float, rng: RandomNumberGenerator) -> void:
	var hz := t * 0.5 + CRACK_OFFSET
	var d := e.b - e.a
	var seg_len := d.length()
	var perp := Vector2(-d.y, d.x) / seg_len
	var segs := maxi(2, int(seg_len / 0.16))
	var pts := PackedVector2Array()
	for i in segs + 1:
		var f := float(i) / float(segs)
		var j := 0.0 if i == 0 or i == segs else rng.randf_range(-0.03, 0.03)
		pts.append(e.a + d * f + perp * j)
	for side in [1.0, -1.0]:
		var z: float = hz * side
		var nrm := Vector3(0, 0, side)
		for i in segs:
			var p := pts[i]
			var q := pts[i + 1]
			var w := CRACK_WIDTH * rng.randf_range(0.6, 1.3)
			var sd := (q - p).normalized()
			var sp := Vector2(-sd.y, sd.x) * w * 0.5
			var quad := [Vector3(p.x + sp.x, p.y + sp.y, z), Vector3(q.x + sp.x, q.y + sp.y, z),
				Vector3(q.x - sp.x, q.y - sp.y, z), Vector3(p.x - sp.x, p.y - sp.y, z)]
			for tri in [[0, 1, 2], [0, 2, 3]]:
				var v0: Vector3 = quad[tri[0]]
				var v1: Vector3 = quad[tri[1]]
				var v2: Vector3 = quad[tri[2]]
				if (v1 - v0).cross(v2 - v0).dot(nrm) > 0.0:
					var tmp := v1
					v1 = v2
					v2 = tmp
				for v in [v0, v1, v2]:
					e.verts.append(v)
					e.normals.append(nrm)

## Crack mesh made of the given edges (indices into fs.edges).
static func crack_mesh_for(fs: FractureSet, edge_ids: PackedInt32Array) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	for i in edge_ids:
		var e: CrackEdge = fs.edges[i]
		verts.append_array(e.verts)
		normals.append_array(e.normals)
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
