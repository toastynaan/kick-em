class_name FurnitureKit
extends RefCounted
## Round 6 clutter geometry, materials and pieces (agent K). Every clutter kind
## (Tuning.FURNITURE) is a list of parts (boxes, n-gon prisms, rings) in the
## object's own frame (origin on the floor at its centre, +Z its front). The
## same parts draw the intact object (one merged mesh per material, shared by
## every object of that kind) and become its pieces when it breaks (each piece
## a group of parts: a table's two top halves and four legs, a sofa's base,
## back, arms and cushions, a barrel's staves, hoops and lid). Meshes carry the
## object-space pattern position in UV / UV2 and white vertex colour, the
## convention WorldMaterials' world shader reads, so wood grain stays on a piece
## as it flies. Wood and concrete use that shader's view-fade variant (the
## camera dithers them out, WorldMaterials.set_view_fade); fabric, metal,
## cardboard and glass are shared StandardMaterial3Ds (faded by transparency).
## Glass panes break into shards instead (make_shard).
## OWNER: agent K (clutter).

enum Shape { BOX, PRISM, RING }

## Part piece codes: >= 0 a piece index; NONE disappears with the object (a
## shelf's contents become ThrowableProps instead); GLASS becomes shards.
const NONE := -1
const GLASS := -2

## kg/m^3 per material (game values: pieces must never stop a flying body).
const DENSITY := {&"wood_dark": 550.0, &"wood_light": 500.0, &"wood_barrel": 550.0, &"paint": 500.0,
	&"metal": 1800.0, &"fabric": 110.0, &"cushion": 90.0, &"concrete": 1300.0, &"soil": 1100.0,
	&"leaf": 60.0, &"glass": 2500.0, &"cardboard": 120.0, &"tape": 120.0}
## Surface a piece of each material reports (effects, footsteps on rubble).
const MAT_SURFACE := {&"metal": &"metal", &"fabric": &"fabric", &"cushion": &"fabric",
	&"concrete": &"concrete", &"soil": &"dirt", &"leaf": &"fabric", &"glass": &"glass",
	&"cardboard": &"cardboard", &"tape": &"cardboard"}
## Piece mass limits (kg) and the volume under which a piece is small debris
## (Layers.DEBRIS_SMALL: small pieces never collide with each other).
const PIECE_MASS := Vector2(0.3, 25.0)
const SMALL_VOLUME := 0.005
## Piece collision shapes are this much smaller than the part, so parts that
## touch in the object never start a break overlapping (no explosive separation).
const PIECE_SHAPE_SCALE := 0.92
## Pieces (and loose objects) settle instead of rolling on: extra angular damping.
const PIECE_ANGULAR_DAMP := 1.0
## A bush piece collides as one box this share of its bounds.
const BUSH_SHAPE_SCALE := 0.75
## For PIECE_GUARD_TIME s after a break, no piece moves faster than
## PIECE_GUARD_SHARE x the breaking speed (at least PIECE_GUARD_MIN m/s) or
## spins faster than PIECE_GUARD_SPIN rad/s: the solver pushing apart a piece
## that spawned touching something can fling a light one at 2-3x the body's speed.
const PIECE_GUARD_TIME := 0.2
const PIECE_GUARD_SHARE := 1.2
const PIECE_GUARD_MIN := 4.0
const PIECE_GUARD_SPIN := 25.0
## Widths (m) of the glass variants.
const GLASS_WIDTH := {&"": 1.4, &"narrow": 0.94}
const GLASS_H := 2.3
const SHARD_T := 0.012

class Part:
	var shape := Shape.BOX
	var size := Vector3.ONE         ## box size; prism / ring: (2r, h, 2r)
	var xf := Transform3D()         ## object space
	var mat: StringName = &"wood_light"
	var piece := 0
	var sides := 10
	## Crack look: a part that splits along this local axis (a table top half
	## lifting at the seam) instead of a random jitter.
	var split := Vector3.ZERO

class PieceSpec:
	var origin := Vector3.ZERO      ## object space (centre of its parts)
	var meshes := {}                ## mat -> ArrayMesh (piece space)
	var shapes: Array = []          ## [Shape3D, Transform3D piece space]
	var mass := 1.0
	var small := false
	var surface: StringName = &"wood"
	var size := Vector3.ONE         ## AABB size (velocity spread, tests)

class Spec:
	var kind: StringName
	var variant: StringName
	var parts: Array[Part] = []
	## Static collision: [Shape3D, Transform3D object space].
	var shapes: Array = []
	## The breakable's box (ImpactResolver, strikes, blasts), object space.
	var bounds := AABB()
	## Everything it draws (glass feet, a bush over a planter), object space.
	var visual_bounds := AABB()
	var intact := {}                ## mat -> ArrayMesh (object space)
	var pieces: Array[PieceSpec] = []
	## Shelf contents: [ThrowableProp kind, Transform3D object space].
	var contents: Array = []
	var mass := 10.0                ## whole object (knocked loose)
	var tall := false

static var _specs := {}
static var _mats := {}
static var _shard_cache := {}

## The (cached) spec of a kind / variant.
static func get_spec(kind: StringName, variant: StringName = &"") -> Spec:
	var key := "%s/%s" % [kind, variant]
	if _specs.has(key):
		return _specs[key]
	var s := Spec.new()
	s.kind = kind
	s.variant = variant
	match kind:
		&"coffee_table": _coffee_table(s)
		&"table": _table(s)
		&"chair": _chair(s)
		&"bench": _bench(s)
		&"sofa": _sofa(s)
		&"planter": _planter(s)
		&"barrel": _barrel(s)
		&"shelf": _shelf(s)
		&"fence": _fence(s)
		&"glass": _glass(s)
		&"cardboard": _cardboard(s)
		_:
			push_error("FurnitureKit: unknown kind %s" % kind)
			_table(s)
	_finish(s)
	_specs[key] = s
	return s

# --- Kinds -------------------------------------------------------------------------

static func _part(s: Spec, size: Vector3, at: Vector3, mat: StringName, piece: int, rot_deg := Vector3.ZERO,
		shape := Shape.BOX, sides := 10) -> Part:
	var p := Part.new()
	p.size = size
	p.xf = Transform3D(Basis.from_euler(rot_deg * (PI / 180.0)), at)
	p.mat = mat
	p.piece = piece
	p.shape = shape
	p.sides = sides
	s.parts.append(p)
	return p

static func _box_shape(s: Spec, size: Vector3, center: Vector3) -> void:
	var b := BoxShape3D.new()
	b.size = size
	s.shapes.append([b, Transform3D(Basis(), center)])

## Coffee table 1.1 x 0.42 x 0.6: a top in two halves on four legs.
static func _coffee_table(s: Spec) -> void:
	for sx in [-1.0, 1.0]:
		var p := _part(s, Vector3(0.55, 0.035, 0.6), Vector3(0.275 * sx, 0.4025, 0), &"wood_dark", 0 if sx < 0 else 1)
		p.split = Vector3(0, 0, -sx)
	var k := 2
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_part(s, Vector3(0.05, 0.385, 0.05), Vector3(0.49 * sx, 0.1925, 0.24 * sz), &"wood_dark", k)
			k += 1
	_box_shape(s, Vector3(1.1, 0.42, 0.6), Vector3(0, 0.21, 0))
	s.mass = 14.0

## Market / work table 1.4 x 0.76 x 0.8.
static func _table(s: Spec) -> void:
	for sx in [-1.0, 1.0]:
		var p := _part(s, Vector3(0.7, 0.045, 0.8), Vector3(0.35 * sx, 0.7375, 0), &"wood_light", 0 if sx < 0 else 1)
		p.split = Vector3(0, 0, -sx)
	var k := 2
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_part(s, Vector3(0.065, 0.715, 0.065), Vector3(0.63 * sx, 0.3575, 0.33 * sz), &"wood_dark", k)
			k += 1
	_box_shape(s, Vector3(1.4, 0.76, 0.8), Vector3(0, 0.38, 0))
	s.mass = 22.0

## Wooden chair 0.44 x 0.92 x 0.44: seat, slatted back, back posts, front legs.
static func _chair(s: Spec) -> void:
	_part(s, Vector3(0.44, 0.04, 0.42), Vector3(0, 0.45, 0.01), &"wood_light", 0)
	_part(s, Vector3(0.36, 0.3, 0.025), Vector3(0, 0.72, -0.195), &"wood_light", 1, Vector3(-6, 0, 0))
	for sx in [-1.0, 1.0]:
		_part(s, Vector3(0.04, 0.9, 0.04), Vector3(0.19 * sx, 0.45, -0.19), &"wood_dark", 2 if sx < 0 else 3)
		_part(s, Vector3(0.04, 0.43, 0.04), Vector3(0.19 * sx, 0.215, 0.18), &"wood_dark", 4 if sx < 0 else 5)
	_box_shape(s, Vector3(0.44, 0.47, 0.44), Vector3(0, 0.235, 0))
	_box_shape(s, Vector3(0.44, 0.45, 0.06), Vector3(0, 0.695, -0.19))
	s.mass = 6.0

## Park bench 1.6 x 0.45 x 0.42: three slats on two steel supports.
static func _bench(s: Spec) -> void:
	var k := 0
	for z in [-0.14, 0.0, 0.14]:
		_part(s, Vector3(1.6, 0.035, 0.12), Vector3(0, 0.4325, z), &"wood_light", k)
		k += 1
	for sx in [-1.0, 1.0]:
		_part(s, Vector3(0.06, 0.415, 0.4), Vector3(0.62 * sx, 0.2075, 0), &"metal", k)
		k += 1
	_box_shape(s, Vector3(1.6, 0.45, 0.42), Vector3(0, 0.225, 0))
	s.mass = 30.0

## Lobby sofa 1.9 x 0.85 x 0.88: base in two halves, two seat cushions, back, arms.
static func _sofa(s: Spec) -> void:
	for sx in [-1.0, 1.0]:
		_part(s, Vector3(0.95, 0.24, 0.88), Vector3(0.475 * sx, 0.16, 0), &"fabric", 0 if sx < 0 else 1)
		_part(s, Vector3(0.78, 0.14, 0.64), Vector3(0.39 * sx, 0.35, 0.09), &"cushion", 2 if sx < 0 else 3)
		_part(s, Vector3(0.18, 0.34, 0.66), Vector3(0.86 * sx, 0.45, 0.11), &"fabric", 5 if sx < 0 else 6)
		for sz in [-1.0, 1.0]:
			_part(s, Vector3(0.06, 0.04, 0.06), Vector3(0.88 * sx, 0.02, 0.38 * sz), &"wood_dark", NONE)
	_part(s, Vector3(1.9, 0.48, 0.2), Vector3(0, 0.57, -0.34), &"fabric", 4, Vector3(-6, 0, 0))
	_box_shape(s, Vector3(1.9, 0.42, 0.88), Vector3(0, 0.21, 0))
	_box_shape(s, Vector3(1.9, 0.85, 0.22), Vector3(0, 0.425, -0.33))
	s.mass = 45.0

## Concrete planter with soil and a bush. Variant &"long": a 1.4 m trough, two bushes.
static func _planter(s: Spec) -> void:
	var w := 1.4 if s.variant == &"long" else 0.7
	var d := 0.5 if s.variant == &"long" else 0.7
	var h := 0.5 if s.variant == &"long" else 0.55
	var t := 0.075
	_part(s, Vector3(w, h, t), Vector3(0, h * 0.5, d * 0.5 - t * 0.5), &"concrete", 0)
	_part(s, Vector3(w, h, t), Vector3(0, h * 0.5, -d * 0.5 + t * 0.5), &"concrete", 1)
	_part(s, Vector3(t, h, d - t * 2.0), Vector3(w * 0.5 - t * 0.5, h * 0.5, 0), &"concrete", 2)
	_part(s, Vector3(t, h, d - t * 2.0), Vector3(-w * 0.5 + t * 0.5, h * 0.5, 0), &"concrete", 3)
	_part(s, Vector3(w - t * 2.0, 0.06, d - t * 2.0), Vector3(0, h - 0.07, 0), &"soil", 4)
	var bushes: Array = [-0.33, 0.33] if s.variant == &"long" else [0.0]
	var k := 5
	for bx: float in bushes:
		_part(s, Vector3(0.42, 0.34, 0.42), Vector3(bx, h + 0.15, 0), &"leaf", k, Vector3(0, 20, 0))
		_part(s, Vector3(0.32, 0.28, 0.32), Vector3(bx + 0.06, h + 0.36, -0.04), &"leaf", k, Vector3(15, 40, 10))
		_part(s, Vector3(0.28, 0.24, 0.28), Vector3(bx - 0.08, h + 0.3, 0.08), &"leaf", k, Vector3(-10, 65, 5))
		k += 1
	_box_shape(s, Vector3(w, h, d), Vector3(0, h * 0.5, 0))
	s.mass = 90.0 if s.variant == &"long" else 60.0

## Wooden barrel 0.6 x 0.88: eight staves, two steel hoops, a lid.
static func _barrel(s: Spec) -> void:
	var r := 0.28
	var h := 0.88
	var n := 8
	var w := 2.0 * (r + 0.02) * tan(PI / n) * 1.04
	for i in n:
		var a := TAU * (float(i) + 0.5) / n
		var at := Vector3(sin(a) * r, h * 0.5, cos(a) * r)
		_part(s, Vector3(w, h, 0.045), at, &"wood_barrel", int(i / 2.0), Vector3(0, rad_to_deg(a), 0))
	# The hoops are thin bands: they go with the break (NONE); staves and lid stay.
	for y: float in [0.18, 0.7]:
		_part(s, Vector3(0.61, 0.05, 0.61), Vector3(0, y, 0), &"metal", NONE, Vector3.ZERO, Shape.RING, 12)
	_part(s, Vector3(0.5, 0.03, 0.5), Vector3(0, h - 0.04, 0), &"wood_barrel", 4, Vector3.ZERO, Shape.PRISM, 12)
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.3
	cyl.height = h
	s.shapes.append([cyl, Transform3D(Basis(), Vector3(0, h * 0.5, 0))])
	s.mass = 20.0

## Tall storage rack 1.2 x 2.0 x 0.45: steel uprights, four boards and 2-4
## things on them (bottles, bricks, small crates) that spill as throwables.
static func _shelf(s: Spec) -> void:
	var h := 2.0
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_part(s, Vector3(0.04, h, 0.04), Vector3(0.58 * sx, h * 0.5, 0.205 * sz), &"metal", 0 if sx < 0 else 1)
		_part(s, Vector3(0.025, 0.025, 0.41), Vector3(0.58 * sx, 1.0, 0), &"metal", 0 if sx < 0 else 1)
	var boards: Array[float] = [0.12, 0.66, 1.2, 1.74]
	for i in boards.size():
		_part(s, Vector3(1.12, 0.025, 0.45), Vector3(0, boards[i], 0), &"wood_light", 2 + i)
	# Contents: 2-4 by variant (&"" 3, &"few" 2, &"full" 4), on the upper boards.
	var slots := [[&"bottle", Vector3(-0.32, 0.66, 0.02), 0.0], [&"crate_small", Vector3(0.22, 1.2, 0.0), 0.15],
		[&"brick", Vector3(-0.2, 1.74, 0.05), 0.4], [&"bottle", Vector3(0.36, 0.66, -0.05), 0.0]]
	var count := 3
	if s.variant == &"few":
		count = 2
	elif s.variant == &"full":
		count = 4
	count = clampi(count, Tuning.SHELF_SPILL.x, Tuning.SHELF_SPILL.y)
	for i in count:
		var it: Array = slots[i]
		var kind: StringName = it[0]
		var at: Vector3 = it[1]
		var spec: Dictionary = ThrowableProp.KINDS[kind]
		var lift := 0.0125
		var xf := Transform3D(Basis(Vector3.UP, float(it[2])), at)
		if spec.has("box"):
			var b: Vector3 = spec["box"]
			lift += b.y * 0.5
			xf.origin.y += lift
			_part(s, b, xf.origin, &"crate" if kind == &"crate_small" else &"brick", NONE, Vector3(0, rad_to_deg(float(it[2])), 0))
		else:
			var c: Vector2 = spec["cyl"]
			lift += c.y * 0.5
			xf.origin.y += lift
			_part(s, Vector3(c.x * 2.0, c.y, c.x * 2.0), xf.origin, &"bottle", NONE, Vector3.ZERO, Shape.PRISM, 8)
		s.contents.append([kind, xf])
	_box_shape(s, Vector3(1.2, h, 0.45), Vector3(0, h * 0.5, 0))
	s.tall = true
	s.mass = 40.0

## Painted wooden railing section 1.6 x 1.0: two posts, two rails, five balusters.
static func _fence(s: Spec) -> void:
	for sx in [-1.0, 1.0]:
		_part(s, Vector3(0.09, 1.0, 0.09), Vector3(0.755 * sx, 0.5, 0), &"paint", 0 if sx < 0 else 1)
	_part(s, Vector3(1.42, 0.07, 0.06), Vector3(0, 0.93, 0), &"paint", 2)
	_part(s, Vector3(1.42, 0.06, 0.05), Vector3(0, 0.22, 0), &"paint", 3)
	var xs: Array[float] = [-0.5, -0.25, 0.0, 0.25, 0.5]
	for i in xs.size():
		_part(s, Vector3(0.05, 0.84, 0.025), Vector3(xs[i], 0.53, 0.047), &"paint", 2 if i % 2 == 1 else 3)
	_box_shape(s, Vector3(1.6, 1.0, 0.12), Vector3(0, 0.5, 0))
	s.mass = 18.0

## Free-standing glass pane 2.3 m tall in a steel frame on two feet, with a
## steel kick panel. Variant &"narrow" (0.94 m) fits between breach lanes.
static func _glass(s: Spec) -> void:
	var w: float = GLASS_WIDTH.get(s.variant, 1.4)
	var h := GLASS_H
	for sx in [-1.0, 1.0]:
		_part(s, Vector3(0.06, h, 0.08), Vector3((w * 0.5 - 0.03) * sx, h * 0.5, 0), &"metal", 0 if sx < 0 else 1)
		_part(s, Vector3(0.08, 0.04, 0.5), Vector3((w * 0.5 - 0.03) * sx, 0.02, 0), &"metal", 0 if sx < 0 else 1)
	_part(s, Vector3(w - 0.12, 0.06, 0.08), Vector3(0, h - 0.03, 0), &"metal", 2)
	_part(s, Vector3(w - 0.12, 0.32, 0.05), Vector3(0, 0.2, 0), &"metal", 3)
	var pane_h := h - 0.42
	_part(s, Vector3(w - 0.12, pane_h, SHARD_T), Vector3(0, 0.36 + pane_h * 0.5, 0), &"glass", GLASS)
	_box_shape(s, Vector3(w, h, 0.1), Vector3(0, h * 0.5, 0))
	s.tall = true
	s.mass = 30.0

## Cardboard box from six panels (and a tape strip). Variants &"" / &"small" / &"big".
static func _cardboard(s: Spec) -> void:
	var sz := Vector3(0.55, 0.42, 0.42)
	if s.variant == &"small":
		sz = Vector3(0.45, 0.36, 0.38)
	elif s.variant == &"big":
		sz = Vector3(0.62, 0.48, 0.46)
	var t := 0.012
	var h := sz * 0.5
	_part(s, Vector3(sz.x, sz.y, t), Vector3(0, h.y, h.z - t * 0.5), &"cardboard", 0)
	_part(s, Vector3(sz.x, t, sz.z - t * 2.0), Vector3(0, sz.y - t * 0.5, 0), &"cardboard", 0)
	_part(s, Vector3(0.06, 0.004, sz.z - t * 2.0), Vector3(0, sz.y + 0.002, 0), &"tape", 0)
	_part(s, Vector3(sz.x, sz.y, t), Vector3(0, h.y, -h.z + t * 0.5), &"cardboard", 1)
	_part(s, Vector3(sz.x, t, sz.z - t * 2.0), Vector3(0, t * 0.5, 0), &"cardboard", 1)
	_part(s, Vector3(t, sz.y - t * 2.0, sz.z - t * 2.0), Vector3(h.x - t * 0.5, h.y, 0), &"cardboard", 2)
	_part(s, Vector3(t, sz.y - t * 2.0, sz.z - t * 2.0), Vector3(-h.x + t * 0.5, h.y, 0), &"cardboard", 3)
	_box_shape(s, sz, Vector3(0, h.y, 0))
	s.mass = 2.5 if s.variant != &"big" else 4.0

# --- Building ------------------------------------------------------------------------

static func _finish(s: Spec) -> void:
	var b := AABB()
	var first := true
	for sh: Array in s.shapes:
		var shape: Shape3D = sh[0]
		var xf: Transform3D = sh[1]
		var half := Vector3.ZERO
		if shape is BoxShape3D:
			half = (shape as BoxShape3D).size * 0.5
		elif shape is CylinderShape3D:
			var c := shape as CylinderShape3D
			half = Vector3(c.radius, c.height * 0.5, c.radius)
		var a := AABB(xf.origin - half, half * 2.0)
		b = a if first else b.merge(a)
		first = false
	s.bounds = b
	var vb := b
	for p in s.parts:
		vb = vb.merge(p.xf * AABB(-p.size * 0.5, p.size))
	s.visual_bounds = vb
	var xfs: Array[Transform3D] = []
	for p in s.parts:
		xfs.append(p.xf)
	s.intact = build_meshes(s, xfs)
	var count := 0
	for p in s.parts:
		count = maxi(count, p.piece + 1)
	for i in count:
		s.pieces.append(_piece(s, i))

## Merged meshes (one per material) of the parts at `xfs` (object space). With
## `piece` >= 0 only that piece's parts, relative to `origin`.
static func build_meshes(s: Spec, xfs: Array[Transform3D], piece := -100, origin := Vector3.ZERO) -> Dictionary:
	var by_mat := {}
	for i in s.parts.size():
		var p: Part = s.parts[i]
		if piece != -100 and p.piece != piece:
			continue
		var arr: MeshArrays = by_mat.get(p.mat)
		if arr == null:
			arr = MeshArrays.new()
			by_mat[p.mat] = arr
		var uv_xf: Transform3D = xfs[i]
		var mesh_xf := Transform3D(Basis(), -origin) * uv_xf
		match p.shape:
			Shape.BOX:
				arr.add_box(p.size, mesh_xf, uv_xf)
			Shape.PRISM:
				arr.add_prism(p.size.x * 0.5, p.size.y, p.sides, true, mesh_xf, uv_xf)
			Shape.RING:
				arr.add_prism(p.size.x * 0.5, p.size.y, p.sides, false, mesh_xf, uv_xf)
	var out := {}
	for m: StringName in by_mat:
		out[m] = (by_mat[m] as MeshArrays).commit()
	return out

static func _piece(s: Spec, index: int) -> PieceSpec:
	var ps := PieceSpec.new()
	var box := AABB()
	var first := true
	var vol := 0.0
	var mass := 0.0
	var mats := {}
	for p in s.parts:
		if p.piece != index:
			continue
		var half := p.size * 0.5
		var a := AABB(p.xf.origin - half, p.size)
		box = a if first else box.merge(a)
		first = false
		var v := p.size.x * p.size.y * p.size.z
		if p.shape != Shape.BOX:
			v *= PI / 4.0
			if p.shape == Shape.RING:
				v *= 0.08
		vol += v
		mass += v * float(DENSITY.get(p.mat, 500.0))
		mats[p.mat] = mats.get(p.mat, 0.0) + v
	ps.origin = box.get_center()
	ps.size = box.size
	ps.mass = clampf(mass, PIECE_MASS.x, PIECE_MASS.y)
	ps.small = vol < SMALL_VOLUME
	var main: StringName = &"wood_light"
	var best := -1.0
	for m: StringName in mats:
		if float(mats[m]) > best:
			best = mats[m]
			main = m
	ps.surface = MAT_SURFACE.get(main, &"wood")
	var xfs: Array[Transform3D] = []
	for p in s.parts:
		xfs.append(p.xf)
	ps.meshes = build_meshes(s, xfs, index, ps.origin)
	if main == &"leaf":
		# A bush is several tilted boxes: as one compound it rocks and rolls for
		# seconds. One flat box under its bulk lands and stays.
		var bush := BoxShape3D.new()
		bush.size = Vector3(ps.size.x, ps.size.y, ps.size.z) * BUSH_SHAPE_SCALE
		ps.shapes.append([bush, Transform3D()])
		return ps
	for p in s.parts:
		if p.piece != index:
			continue
		var sh: Shape3D
		if p.shape == Shape.BOX:
			var b := BoxShape3D.new()
			b.size = (p.size * PIECE_SHAPE_SCALE).max(Vector3.ONE * 0.02)
			sh = b
		else:
			# An n-gon hull, not a cylinder: a lid or ring lands on a facet
			# instead of rolling away on its rim like a coin.
			var hull := PackedVector3Array()
			var r := p.size.x * 0.5 * PIECE_SHAPE_SCALE
			var hh := maxf(p.size.y * PIECE_SHAPE_SCALE, 0.03) * 0.5
			for k in p.sides:
				var a := TAU * float(k) / p.sides
				hull.append(Vector3(sin(a) * r, -hh, cos(a) * r))
				hull.append(Vector3(sin(a) * r, hh, cos(a) * r))
			var c := ConvexPolygonShape3D.new()
			c.points = hull
			sh = c
		ps.shapes.append([sh, Transform3D(Basis(), -ps.origin) * p.xf])
	return ps

## A debris body for piece `index` (not in the tree yet).
static func make_piece_body(s: Spec, index: int) -> RigidBody3D:
	var ps := s.pieces[index]
	var body := RigidBody3D.new()
	body.name = "%sPiece" % String(s.kind).capitalize().replace(" ", "")
	add_meshes(body, ps.meshes)
	for sh: Array in ps.shapes:
		var cs := CollisionShape3D.new()
		cs.shape = sh[0]
		cs.transform = sh[1]
		body.add_child(cs)
	body.mass = ps.mass
	body.angular_damp = PIECE_ANGULAR_DAMP
	body.physics_material_override = piece_physics()
	body.set_meta(&"surface", ps.surface)
	body.set_meta(&"clutter_piece", s.kind)
	return body

## One MeshInstance3D per material under `parent` (material_override, so
## WorldMaterials.set_view_fade can dither or fade each). Returns them by material.
static func add_meshes(parent: Node3D, meshes: Dictionary) -> Dictionary:
	var out := {}
	for m: StringName in meshes:
		var mi := MeshInstance3D.new()
		mi.name = "Mesh_" + String(m)
		mi.mesh = meshes[m]
		mi.material_override = material(m)
		mi.layers = Layers.VIS_WORLD
		if m == &"glass":
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
		out[m] = mi
	return out

## Clamp fresh `bodies` to the guard speed for `speed` (the breaking body's or
## the hit's) for PIECE_GUARD_TIME s. The guard node lives under `parent`.
static func guard_pieces(parent: Node, bodies: Array, speed: float) -> void:
	if parent == null or not parent.is_inside_tree() or bodies.is_empty():
		return
	var g := PieceGuard.new()
	g.name = "PieceGuard"
	g.bodies = bodies.duplicate()
	g.cap = maxf(PIECE_GUARD_SHARE * speed, PIECE_GUARD_MIN)
	g.left = PIECE_GUARD_TIME
	parent.add_child(g)

## See guard_pieces(). Runs before other physics callbacks (priority).
class PieceGuard extends Node:
	var bodies: Array = []
	var cap := PIECE_GUARD_MIN
	var left := PIECE_GUARD_TIME

	func _ready() -> void:
		process_physics_priority = -100

	func _physics_process(delta: float) -> void:
		for b: Variant in bodies:
			if not is_instance_valid(b):
				continue
			var rb := b as RigidBody3D
			var v := rb.linear_velocity
			if v.length() > cap:
				rb.linear_velocity = v.normalized() * cap
			var w := rb.angular_velocity
			if w.length() > PIECE_GUARD_SPIN:
				rb.angular_velocity = w.normalized() * PIECE_GUARD_SPIN
		left -= delta
		if left <= 0.0:
			queue_free()

static var _piece_pm: PhysicsMaterial

static func piece_physics() -> PhysicsMaterial:
	if _piece_pm == null:
		_piece_pm = PhysicsMaterial.new()
		_piece_pm.friction = 0.8
		_piece_pm.bounce = 0.08
	return _piece_pm

# --- Glass shards ------------------------------------------------------------------

## A triangular glass shard (pane-local: the triangle in XY, thickness along Z)
## as a body, centred on its centroid. `big`: a lasting shard (0.2-0.4 m), else
## a fine one (0.05-0.12 m). Shapes and meshes are cached per template.
static func make_shard(big: bool, template: int) -> RigidBody3D:
	var key := "%s_%d" % ["big" if big else "fine", template % 4]
	var entry: Array = _shard_cache.get(key, [])
	if entry.is_empty():
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(key)
		var scale := rng.randf_range(0.2, 0.4) if big else rng.randf_range(0.05, 0.12)
		var pts: Array[Vector2] = []
		for k in 3:
			var a := TAU * (float(k) / 3.0) + rng.randf_range(-0.5, 0.5)
			pts.append(Vector2(cos(a), sin(a)) * scale * rng.randf_range(0.6, 1.0))
		var c := (pts[0] + pts[1] + pts[2]) / 3.0
		for k in 3:
			pts[k] -= c
		var arr := MeshArrays.new()
		arr.add_tri_prism(pts, SHARD_T)
		var mesh := arr.commit()
		var hull := PackedVector3Array()
		for p in pts:
			hull.append(Vector3(p.x, p.y, -0.01))
			hull.append(Vector3(p.x, p.y, 0.01))
		var shape := ConvexPolygonShape3D.new()
		shape.points = hull
		var area := absf((pts[1] - pts[0]).cross(pts[2] - pts[0])) * 0.5
		entry = [mesh, shape, maxf(area * SHARD_T * float(DENSITY[&"glass"]), 0.15)]
		_shard_cache[key] = entry
	var body := RigidBody3D.new()
	body.name = "GlassShard"
	var mi := MeshInstance3D.new()
	mi.mesh = entry[0]
	mi.material_override = material(&"glass")
	mi.layers = Layers.VIS_WORLD
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	cs.shape = entry[1]
	body.add_child(cs)
	body.mass = entry[2]
	body.physics_material_override = piece_physics()
	body.set_meta(&"surface", &"glass")
	body.set_meta(&"clutter_piece", &"glass")
	body.set_meta(&"glass_shard", big)
	return body

# --- Materials ---------------------------------------------------------------------

static func material(id: StringName) -> Material:
	if _mats.has(id):
		return _mats[id]
	var m: Material
	match id:
		&"wood_dark":
			m = _shader_mat(WorldMaterials.Pattern.WOOD, Color(0.34, 0.21, 0.12), Color(0.2, 0.12, 0.07),
				Color(0.62, 0.46, 0.3), 0.7)
		&"wood_light":
			m = _shader_mat(WorldMaterials.Pattern.WOOD, Color(0.68, 0.52, 0.33), Color(0.47, 0.33, 0.19),
				Color(0.82, 0.68, 0.48), 0.8)
		&"wood_barrel":
			m = _shader_mat(WorldMaterials.Pattern.WOOD, Color(0.5, 0.31, 0.16), Color(0.32, 0.19, 0.09),
				Color(0.7, 0.52, 0.32), 0.75)
		&"paint":
			m = _shader_mat(WorldMaterials.Pattern.WOOD, Color(0.2, 0.36, 0.3), Color(0.15, 0.27, 0.22),
				Color(0.72, 0.6, 0.44), 0.65)
		&"concrete":
			m = _shader_mat(WorldMaterials.Pattern.CONCRETE, Color(0.66, 0.64, 0.6), Color(0.52, 0.52, 0.5),
				Color(0.7, 0.69, 0.66), 0.9)
		&"crate":
			m = _shader_mat(WorldMaterials.Pattern.WOOD, Color(0.64, 0.47, 0.28), Color(0.42, 0.28, 0.15),
				Color(0.78, 0.62, 0.42), 0.8)
		&"metal":
			m = _std(Color(0.19, 0.2, 0.21), 0.42, 0.65)
		&"fabric":
			m = _std(Color(0.4, 0.14, 0.1), 0.72)
		&"cushion":
			m = _std(Color(0.47, 0.18, 0.13), 0.8)
		&"soil":
			m = _std(Color(0.19, 0.13, 0.08), 1.0)
		&"leaf":
			m = _std(Color(0.18, 0.4, 0.15), 0.85)
		&"cardboard":
			m = _std(Color(0.63, 0.47, 0.29), 0.95)
		&"tape":
			m = _std(Color(0.74, 0.66, 0.48), 0.5)
		&"brick":
			m = _std(Color(0.6, 0.27, 0.18), 0.9)
		&"bottle":
			m = _std(Color(0.14, 0.36, 0.18), 0.15, 0.1)
		&"glass":
			var g := StandardMaterial3D.new()
			g.albedo_color = Color(0.62, 0.78, 0.82, 0.2)
			g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			g.roughness = 0.04
			g.metallic_specular = 0.9
			g.cull_mode = BaseMaterial3D.CULL_DISABLED
			m = g
		&"crack":
			var c := StandardMaterial3D.new()
			c.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			c.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			c.albedo_texture = crack_texture()
			c.albedo_color = Color(0.92, 0.96, 1.0, 0.9)
			c.cull_mode = BaseMaterial3D.CULL_DISABLED
			m = c
		_:
			m = _std(Color(0.5, 0.5, 0.5), 0.8)
	_mats[id] = m
	return m

## Wood and concrete: WorldMaterials' world shader with the view-fade dither,
## pattern position from UV / UV2 (object space).
static func _shader_mat(pattern: int, a: Color, b: Color, core: Color, rough: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = WorldMaterials.fade_shader()
	m.set_shader_parameter(&"pattern", pattern)
	m.set_shader_parameter(&"world_space", false)
	m.set_shader_parameter(&"color_a", a)
	m.set_shader_parameter(&"color_b", b)
	m.set_shader_parameter(&"color_core", core)
	m.set_shader_parameter(&"rough", rough)
	m.set_shader_parameter(&"metal", 0.0)
	return m

static func _std(c: Color, rough: float, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m

static var _crack_tex: Texture2D

## A white star crack (radial lines with a ring) on transparent, for glass.
static func crack_texture() -> Texture2D:
	if _crack_tex != null:
		return _crack_tex
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 6061
	var c := Vector2(n, n) * 0.5
	var rays := 9
	var ends: Array[Vector2] = []
	for i in rays:
		var a := TAU * float(i) / rays + rng.randf_range(-0.25, 0.25)
		var p := c
		var length := rng.randf_range(0.32, 0.48) * n
		var steps := int(length / 2.0)
		for k in steps:
			a += rng.randf_range(-0.12, 0.12)
			p += Vector2(cos(a), sin(a)) * 2.0
			var alpha := 1.0 - float(k) / steps * 0.6
			_dot(img, p, alpha)
			if k == int(steps * 0.45):
				ends.append(p)
	for i in ends.size():
		var a := ends[i]
		var b := ends[(i + 1) % ends.size()]
		for k in 24:
			_dot(img, a.lerp(b, k / 23.0) + Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)), 0.55)
	_crack_tex = ImageTexture.create_from_image(img)
	return _crack_tex

static func _dot(img: Image, p: Vector2, alpha: float) -> void:
	var x := int(p.x)
	var y := int(p.y)
	if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return
	var cur := img.get_pixel(x, y)
	img.set_pixel(x, y, Color(1, 1, 1, maxf(cur.a, alpha)))

## Vertex arrays for the procedural parts: object-space pattern position in
## UV (x, y) / UV2 (z), white vertex colour (the world shader's "exterior"
## face), clockwise front faces (Godot's winding).
class MeshArrays:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()

	func _vert(p: Vector3, nrm: Vector3, uvp: Vector3) -> void:
		v.append(p)
		n.append(nrm)
		uv.append(Vector2(uvp.x, uvp.y))
		uv2.append(Vector2(uvp.z, 0.0))
		col.append(Color.WHITE)

	## Quad a, b, c, d counter-clockwise seen from its front.
	func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, nrm: Vector3, mesh_xf: Transform3D,
			uv_xf: Transform3D) -> void:
		var i := v.size()
		var wn := (mesh_xf.basis * nrm).normalized()
		for p: Vector3 in [a, b, c, d]:
			_vert(mesh_xf * p, wn, uv_xf * p)
		idx.append_array(PackedInt32Array([i, i + 2, i + 1, i, i + 3, i + 2]))

	func add_box(size: Vector3, mesh_xf: Transform3D, uv_xf: Transform3D) -> void:
		var h := size * 0.5
		var faces := [[Vector3.RIGHT, Vector3.FORWARD, Vector3.UP], [Vector3.LEFT, Vector3.BACK, Vector3.UP],
			[Vector3.UP, Vector3.RIGHT, Vector3.FORWARD], [Vector3.DOWN, Vector3.RIGHT, Vector3.BACK],
			[Vector3.BACK, Vector3.RIGHT, Vector3.UP], [Vector3.FORWARD, Vector3.LEFT, Vector3.UP]]
		for f: Array in faces:
			var nn: Vector3 = f[0]
			var c := nn * h
			var hu := (f[1] as Vector3) * h
			var hv := (f[2] as Vector3) * h
			_quad(c - hu - hv, c + hu - hv, c + hu + hv, c - hu + hv, nn, mesh_xf, uv_xf)

	## An n-gon prism round Y (radius r, height h); caps false: a ring (sides only).
	func add_prism(r: float, h: float, sides: int, caps: bool, mesh_xf: Transform3D, uv_xf: Transform3D) -> void:
		var y0 := -h * 0.5
		var y1 := h * 0.5
		for i in sides:
			var a0 := TAU * float(i) / sides
			var a1 := TAU * float(i + 1) / sides
			var p0 := Vector3(sin(a0) * r, 0, cos(a0) * r)
			var p1 := Vector3(sin(a1) * r, 0, cos(a1) * r)
			var nrm := ((p0 + p1) * 0.5).normalized()
			_quad(Vector3(p0.x, y0, p0.z), Vector3(p1.x, y0, p1.z), Vector3(p1.x, y1, p1.z), Vector3(p0.x, y1, p0.z),
				nrm, mesh_xf, uv_xf)
		if not caps:
			return
		for top: bool in [true, false]:
			var y := y1 if top else y0
			var nrm := Vector3.UP if top else Vector3.DOWN
			var ci := v.size()
			var wn := (mesh_xf.basis * nrm).normalized()
			_vert(mesh_xf * Vector3(0, y, 0), wn, uv_xf * Vector3(0, y, 0))
			for i in sides:
				var a := TAU * float(i) / sides
				var p := Vector3(sin(a) * r, y, cos(a) * r)
				_vert(mesh_xf * p, wn, uv_xf * p)
			for i in sides:
				var j := (i + 1) % sides
				if top:
					idx.append_array(PackedInt32Array([ci, ci + 1 + j, ci + 1 + i]))
				else:
					idx.append_array(PackedInt32Array([ci, ci + 1 + i, ci + 1 + j]))

	## A thin triangular prism: triangle `pts` in XY, thickness `t` along Z.
	func add_tri_prism(pts: Array[Vector2], t: float) -> void:
		var id := Transform3D()
		var z0 := -t * 0.5
		var z1 := t * 0.5
		var a := Vector3(pts[0].x, pts[0].y, z1)
		var b := Vector3(pts[1].x, pts[1].y, z1)
		var c := Vector3(pts[2].x, pts[2].y, z1)
		var ccw := (b - a).cross(c - a).z > 0.0
		if not ccw:
			var tmp := b
			b = c
			c = tmp
		var i := v.size()
		for p: Vector3 in [a, b, c]:
			_vert(p, Vector3.BACK, p)
		idx.append_array(PackedInt32Array([i, i + 2, i + 1]))
		i = v.size()
		for p: Vector3 in [a, b, c]:
			var q := Vector3(p.x, p.y, z0)
			_vert(q, Vector3.FORWARD, q)
		idx.append_array(PackedInt32Array([i, i + 1, i + 2]))
		var ring: Array[Vector3] = [a, b, c]
		for k in 3:
			var p0 := ring[k]
			var p1 := ring[(k + 1) % 3]
			var e := p1 - p0
			var nrm := Vector3(e.y, -e.x, 0).normalized()
			_quad(Vector3(p0.x, p0.y, z0), Vector3(p1.x, p1.y, z0), Vector3(p1.x, p1.y, z1), Vector3(p0.x, p0.y, z1),
				nrm, id, id)

	func commit() -> ArrayMesh:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = v
		arrays[Mesh.ARRAY_NORMAL] = n
		arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
		arrays[Mesh.ARRAY_COLOR] = col
		arrays[Mesh.ARRAY_INDEX] = idx
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		return mesh
