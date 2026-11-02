class_name Pillar
extends StaticBody3D
## Concrete courtyard pillar. A solid core plus face slabs in SEGMENTS height
## bands, standing on its origin (the floor).
## Round 5 (Feel Reference: Launch speed and walls; lead decision 7): a pillar
## breaks like a concrete panel. ImpactResolver sweeps it like any breakable and
## calls receive_impact() before contact with E = 1/2 M v^2 (speed straight into
## the face): from Tuning.CRACK_FRACTION of its break energy it cracks (decal,
## the slab under the contact comes off, and the break energy drops by half the
## hit's energy); at the break energy (Tuning.SURFACES.concrete, 15,000 J) it
## snaps: everything above a STUMP_H stump comes down as large persistent
## debris. An 18 m/s body (10,257 J) never breaks it in one hit; a second one
## does (15,000 - 5,128 = 9,872 J). Strikes chip the slabs and never break the
## core. Static, Layers.WORLD (capsules, bones, nav and the camera all treat it
## as solid), surface &"concrete".
## Round 6: part of the breakable contract (group "breakables", receive_blast).
## Every pillar holds an overhead piece (a steel cap beam across its top with a
## hanging sign under the end toward the courtyard centre, on Layers.DESTRUCTIBLE
## so the camera fades it instead of colliding with it). When the pillar snaps
## the piece creaks (GameEvents.structure_collapsed, kind &"overhead") and drops
## Tuning.PILLAR_COLLAPSE_DELAY s later as a FallingPiece: it lands where physics
## puts it, stays, and knocks down anyone it falls on. The upper sections of a
## snapped pillar are FallingPieces too.
## OWNER: agent D (world).

const CHIP_FROM := 5000.0
const CHIP_BIG_FROM := 9000.0
const SEGMENTS := 3
const SLAB := 0.12            ## m thickness of a face slab
const DENSITY := 400.0        ## kg/m^3, same game density as concrete chunks
## kg/m^3 of crack spall (a face slab breaking off): lighter, so it scatters.
const SPALL_DENSITY := 220.0
## Round 5 break: the stump left standing (m), how the core band under the hit
## splits (pieces across), and the share of the body's speed the hit band's
## pieces leave with (the bands above topple with TOPPLE_SPEED).
const STUMP_H := 0.35
const CORE_SPLIT := 2
const HIT_SHARE := 0.75
const TOPPLE_SPEED := 1.6     ## m/s along the hit for the bands above the hit

@export var size := Vector3(1.0, 4.0, 1.0)
var _slabs := {}              ## Vector2i(face, segment) -> [CollisionShape3D, MeshInstance3D, Vector3 size]
var _slab_dmg := {}           ## Vector2i(face, segment) -> strike damage
var chips := 0
## Per face band: [accumulated strike power, Decal or null] (one decal grows).
var _marks := {}
const DECAL_SIZE := Vector2(0.5, 1.2)
const GROW_POWER := 900.0

## Breakable interface shared with Destructible (ImpactResolver duck-types it).
var surface: StringName = &"concrete"
var kind: StringName = &"pillar"
var break_energy := 15000.0
var original_break_energy := 15000.0
var absorption := 0.0
var is_broken := false
var is_cracked := false
## Pieces spawned by the break (ImpactResolver lets the body pass through them).
var last_chunks: Array[RigidBody3D] = []
var _core: Array = []         ## [CollisionShape3D, MeshInstance3D]
## Round 6 overhead piece: the static head on top while the pillar stands, then
## the FallingPiece it became (null until then).
var head: StaticBody3D
var fallen_head: FallingPiece
## m/s of the body that snapped it: the reference speed its pieces are held to
## while young (DebrisManager.hold_young).
var _break_speed := 0.0
## Overhead piece: beam length, section, steel density; the sign under its inner end.
const HEAD_LENGTH := 2.2
const HEAD_SECTION := Vector2(0.22, 0.26)   ## m width, height
const HEAD_DENSITY := 1200.0                 ## kg/m^3 (a hollow steel section, ~150 kg)
const SIGN_SIZE := Vector3(0.95, 0.42, 0.05)
const SIGN_DROP := 0.38                      ## m from the beam's underside to the sign's top
const SIGN_MASS := 9.0

func _ready() -> void:
	collision_layer = Layers.WORLD
	collision_mask = 0
	set_meta(&"surface", &"concrete")
	# Not in "world_static": ImpactResolver's sweep must see pillars (they break).
	add_to_group(&"pillars")
	var data: Dictionary = Tuning.SURFACES[&"concrete"]
	break_energy = float(data["break_energy"])
	original_break_energy = break_energy
	absorption = float(data["absorption"])
	var mat := WorldMaterials.concrete(1.05)
	var core := Vector3(size.x - SLAB * 2.0, size.y, size.z - SLAB * 2.0)
	_core = _add_box(core, Vector3(0, size.y * 0.5, 0), mat, true)
	add_to_group(&"breakables")
	var h := size.y / SEGMENTS
	for seg in SEGMENTS:
		var y := h * (seg + 0.5)
		# Faces 0/1 = -X/+X (full depth, cover the corners), 2/3 = -Z/+Z.
		for face in 4:
			var sz: Vector3
			var at: Vector3
			match face:
				0:
					sz = Vector3(SLAB, h, size.z)
					at = Vector3(-size.x * 0.5 + SLAB * 0.5, y, 0)
				1:
					sz = Vector3(SLAB, h, size.z)
					at = Vector3(size.x * 0.5 - SLAB * 0.5, y, 0)
				2:
					sz = Vector3(size.x - SLAB * 2.0, h, SLAB)
					at = Vector3(0, y, -size.z * 0.5 + SLAB * 0.5)
				_:
					sz = Vector3(size.x - SLAB * 2.0, h, SLAB)
					at = Vector3(0, y, size.z * 0.5 - SLAB * 0.5)
			var pair := _add_box(sz, at, mat, true)
			_slabs[Vector2i(face, seg)] = [pair[0], pair[1], sz]
	_build_head()

## The overhead piece: a steel beam across the pillar's top, its long axis
## toward the courtyard centre (the world origin), and a hanging sign under the
## inner end. Static on Layers.DESTRUCTIBLE until the pillar snaps.
func _build_head() -> void:
	head = StaticBody3D.new()
	head.name = "Head"
	head.collision_layer = Layers.DESTRUCTIBLE
	head.collision_mask = 0
	head.set_meta(&"surface", &"metal")
	head.set_meta(&"obstacle", false)
	add_child(head)
	# Along the pillar's face axis that points most toward the courtyard centre
	# (x first on a tie), the sign end inward: square with the faces, so it reads
	# as part of the structure and a body flying across it hits a face square on.
	var to_centre := -global_position if is_inside_tree() else -position
	var dir := Vector3.FORWARD
	if absf(to_centre.x) >= absf(to_centre.z) and absf(to_centre.x) > 0.1:
		dir = Vector3(signf(to_centre.x), 0, 0)
	elif absf(to_centre.z) > 0.1:
		dir = Vector3(0, 0, signf(to_centre.z))
	var yaw := atan2(dir.x, dir.z)
	head.transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(0, size.y + HEAD_SECTION.y * 0.5, 0))
	var steel := WorldMaterials.frame()
	# The beam runs along the head's local Z (toward the centre).
	var beam := Vector3(HEAD_SECTION.x, HEAD_SECTION.y, HEAD_LENGTH)
	_head_part(beam, Vector3.ZERO, steel)
	# Two flanges read as an I-beam from below.
	for sy in [-1.0, 1.0]:
		_head_part(Vector3(HEAD_SECTION.x + 0.08, 0.03, HEAD_LENGTH), Vector3(0, sy * (HEAD_SECTION.y * 0.5 - 0.015), 0),
			steel, false)
	var end_z := HEAD_LENGTH * 0.5 - 0.15
	var sign_y := -HEAD_SECTION.y * 0.5 - SIGN_DROP - SIGN_SIZE.y * 0.5
	for sx in [-1.0, 1.0]:
		_head_part(Vector3(0.025, SIGN_DROP, 0.025), Vector3(sx * SIGN_SIZE.x * 0.35, -HEAD_SECTION.y * 0.5 - SIGN_DROP * 0.5,
			end_z), steel, false)
	var sign_board := Vector3(SIGN_SIZE.x, SIGN_SIZE.y, SIGN_SIZE.z)
	_head_part(sign_board, Vector3(0, sign_y, end_z), WorldMaterials.sign_board(), true, Basis(Vector3.UP, PI * 0.5))
	head.set_meta(&"mass", HEAD_SECTION.x * HEAD_SECTION.y * HEAD_LENGTH * HEAD_DENSITY + SIGN_MASS)

func _head_part(sz: Vector3, at: Vector3, mat: Material, collide := true, basis := Basis()) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = sz
	mi.mesh = bm
	mi.material_override = mat
	mi.layers = Layers.VIS_WORLD
	mi.transform = Transform3D(basis, at)
	head.add_child(mi)
	if collide:
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = sz
		cs.shape = shape
		cs.transform = Transform3D(basis, at)
		head.add_child(cs)

## The overhead piece creaks now and drops after `delay` s (game time).
func _drop_head_after(delay: float) -> void:
	if head == null or not is_instance_valid(head) or not is_inside_tree():
		return
	GameEvents.structure_collapsed.emit(head, head.global_position, &"overhead")
	get_tree().create_timer(delay, false, true).timeout.connect(_drop_head)

## The static head becomes a FallingPiece with the same parts, a small tip
## toward its heavier end, and stays where it lands.
func _drop_head() -> void:
	if head == null or not is_instance_valid(head):
		return
	var piece := FallingPiece.new()
	piece.name = "FallenHead"
	piece.mass = float(head.get_meta(&"mass", 60.0))
	piece.set_meta(&"surface", &"metal")
	var xf := head.global_transform
	for c in head.get_children():
		var n := c as Node3D
		var t := n.transform
		head.remove_child(n)
		piece.add_child(n)
		n.transform = t
	head.queue_free()
	head = null
	piece.transform = xf
	piece.angular_velocity = xf.basis.x * randf_range(0.3, 0.8) * (1.0 if randf() < 0.5 else -1.0)
	(get_parent() if get_parent() else self).add_child(piece)
	piece.global_transform = xf
	piece.reset_physics_interpolation()
	DebrisManager.register(piece, false, -1.0, true)
	fallen_head = piece

func _add_box(sz: Vector3, at: Vector3, mat: Material, collide: bool) -> Array:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = sz
	mi.mesh = bm
	mi.material_override = mat
	mi.layers = Layers.VIS_WORLD
	mi.position = at
	add_child(mi)
	var cs: CollisionShape3D = null
	if collide:
		cs = CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = sz
		cs.shape = shape
		cs.position = at
		add_child(cs)
	return [cs, mi]

## Round 3 contract (same as Destructible.receive_strike): a punch or kick.
## Every hit chips the face (tiny chips, a crack decal that grows); the face
## slab under the contact takes the power against Tuning.STRIKE_CELL_HP.concrete
## and comes off as two pieces pushed along `direction` when it runs out
## (&"hole"). The core never breaks. Emits GameEvents.wall_struck.
func receive_strike(attacker: Node3D, hit_pos: Vector3, direction: Vector3, power: float) -> StringName:
	if is_broken:
		var nb := -direction.normalized() if direction.length() > 0.01 else Vector3.UP
		StrikeMarks.chips(self, hit_pos, nb, direction, power, &"concrete")
		GameEvents.wall_struck.emit(attacker, self, hit_pos, nb, power, &"hold", &"concrete")
		return &"hold"
	var face := _face_of(-direction)
	var lp := to_local(hit_pos)
	var seg := clampi(int(lp.y / (size.y / SEGMENTS)), 0, SEGMENTS - 1)
	var key := Vector2i(face, seg)
	var n := global_basis * _face_normal_local(face)
	var result := &"chip"
	if _slabs.has(key) and power > 0.0:
		_slab_dmg[key] = float(_slab_dmg.get(key, 0.0)) + power
		var hp: float = Tuning.STRIKE_CELL_HP.get(&"concrete", 900.0)
		if float(_slab_dmg[key]) >= hp:
			if _knock_off(key, n, CHIP_FROM):
				chips += 1
				result = &"hole"
	_strike_marks(key, hit_pos, n, direction, power)
	GameEvents.wall_struck.emit(attacker, self, hit_pos, n, power, result, &"concrete")
	return result

## Strike damage on the slab under `world_pos` (tests / debug); -1 if gone.
func get_slab_damage_at(world_pos: Vector3, direction: Vector3) -> float:
	var lp := to_local(world_pos)
	var key := Vector2i(_face_of(-direction), clampi(int(lp.y / (size.y / SEGMENTS)), 0, SEGMENTS - 1))
	return float(_slab_dmg.get(key, 0.0)) if _slabs.has(key) else -1.0

func _face_of(normal: Vector3) -> int:
	var ln := global_basis.inverse() * normal
	if absf(ln.x) >= absf(ln.z):
		return 1 if ln.x > 0.0 else 0
	return 3 if ln.z > 0.0 else 2

static func _face_normal_local(face: int) -> Vector3:
	match face:
		0:
			return Vector3.LEFT
		1:
			return Vector3.RIGHT
		2:
			return Vector3.FORWARD
	return Vector3.BACK

## Tiny chips every hit; one crack decal per face band grows with its damage.
func _strike_marks(key: Vector2i, hit_pos: Vector3, n: Vector3, direction: Vector3, power: float) -> void:
	var m: Array = _marks.get(key, [0.0, null])
	m[0] = float(m[0]) + maxf(power, 0.0)
	_marks[key] = m
	ConcreteWall.grow_decal(self, m, 1, hit_pos, n, float(m[0]), DECAL_SIZE, GROW_POWER)
	StrikeMarks.chips(self, hit_pos, n, direction, power, &"concrete")

## Knock face slabs off near `pos` (world) on the face with outward `normal`.
## Returns how many slabs came off.
func chip(pos: Vector3, normal: Vector3, energy: float) -> int:
	if energy < CHIP_FROM:
		return 0
	var ln := global_basis.inverse() * normal
	var face := 0
	if absf(ln.x) >= absf(ln.z):
		face = 1 if ln.x > 0.0 else 0
	else:
		face = 3 if ln.z > 0.0 else 2
	var lp := to_local(pos)
	var seg := clampi(int(lp.y / (size.y / SEGMENTS)), 0, SEGMENTS - 1)
	var keys: Array[Vector2i] = [Vector2i(face, seg)]
	if energy >= CHIP_BIG_FROM:
		var other := seg + 1 if lp.y - (seg + 0.5) * size.y / SEGMENTS > 0.0 else seg - 1
		if other >= 0 and other < SEGMENTS:
			keys.append(Vector2i(face, other))
	var n := 0
	for k in keys:
		if _knock_off(k, normal, energy):
			n += 1
	chips += n
	return n

## Remove one face slab and drop it as four pieces off the face (`normal` out).
func _knock_off(key: Vector2i, normal: Vector3, energy: float) -> bool:
	if not _slabs.has(key):
		return false
	var slab: Array = _slabs[key]
	_slabs.erase(key)
	_slab_dmg.erase(key)
	var cs: CollisionShape3D = slab[0]
	var mi: MeshInstance3D = slab[1]
	var sz: Vector3 = slab[2]
	var xf := global_transform * Transform3D(Basis(), mi.position)
	cs.queue_free()
	mi.queue_free()
	_spawn_chip(xf, sz, normal, maxf(energy, CHIP_FROM))
	return true

func _spawn_chip(xf: Transform3D, sz: Vector3, normal: Vector3, _energy: float) -> void:
	# The slab spalls off as four pieces (2 x 2), light, dropping at the base and
	# sliding off to the sides, so rubble never slows the next body into the pillar.
	var wide := 0 if sz.x >= sz.z else 2
	for k in 4:
		var half := -1.0 if k < 2 else 1.0
		var side := -1.0 if k % 2 == 0 else 1.0
		var piece := Vector3(sz.x, sz.y * 0.5 - 0.02, sz.z)
		piece[wide] = sz[wide] * 0.5 - 0.02
		var b := RigidBody3D.new()
		b.name = "PillarChip"
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = piece
		mi.mesh = bm
		mi.material_override = WorldMaterials.concrete(1.05)
		mi.layers = Layers.VIS_WORLD
		b.add_child(mi)
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = piece * 0.94
		cs.shape = shape
		b.add_child(cs)
		b.mass = maxf(piece.x * piece.y * piece.z * SPALL_DENSITY, 1.0)
		b.set_meta(&"surface", &"concrete")
		var off := Vector3(0, half * sz.y * 0.25, 0)
		off[wide] = side * sz[wide] * 0.25
		b.transform = xf * Transform3D(Basis(), off)
		var across := (global_basis * Vector3(1 if wide == 0 else 0, 0, 1 if wide == 2 else 0)).normalized()
		# Mostly sideways and down at the base: the lane in front stays clear for
		# the next body (the second 18 m/s hit must arrive at full energy).
		var v := normal * randf_range(0.3, 0.9) + across * side * randf_range(1.6, 3.0) \
			+ Vector3.UP * randf_range(0.0, 0.6)
		var w := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 3.0
		b.linear_velocity = v
		b.angular_velocity = w
		(get_parent() if get_parent() else self).add_child(b)
		b.linear_velocity = v
		b.angular_velocity = w
		DebrisManager.register(b, false)
		DebrisManager.hold_young(b, v.length())

# --- Round 5: body impacts (breakable interface, as Destructible) ----------------

## The pillar's box: centred at half height (origin is the floor).
func get_box_transform() -> Transform3D:
	return global_transform * Transform3D(Basis(), Vector3(0, size.y * 0.5, 0))

## Energy at or above which a body cracks it (INF once broken).
func get_crack_threshold() -> float:
	return INF if is_broken else Tuning.CRACK_FRACTION * break_energy

## World unit normal of the side face nearest `from`.
func get_face_normal(from: Vector3) -> Vector3:
	var xf := get_box_transform()
	var lp := xf.affine_inverse() * from
	var h := size * 0.5
	var axis := 0 if absf(lp.x) / maxf(h.x, 0.01) >= absf(lp.z) / maxf(h.z, 0.01) else 2
	var n := xf.basis[axis].normalized()
	return -n if lp[axis] < 0.0 else n

## Half size of the box along world direction `n`.
func get_half_extent_along(n: Vector3) -> float:
	var b := global_basis
	return absf(n.dot(b.x.normalized())) * size.x * 0.5 + absf(n.dot(b.y.normalized())) * size.y * 0.5 \
		+ absf(n.dot(b.z.normalized())) * size.z * 0.5

## Never runnable (too narrow for a wall run); WorldTags reads this.
func is_runnable() -> bool:
	return false

## Called by ImpactResolver BEFORE contact: &"break", &"crack" or &"bounce".
func receive_impact(energy: float, hit_pos: Vector3, velocity: Vector3, _footprint := Rect2()) -> StringName:
	if is_broken:
		return &"break"
	if energy >= break_energy:
		_shatter(hit_pos, velocity, energy)
		return &"break"
	if energy >= Tuning.CRACK_FRACTION * break_energy:
		_crack(hit_pos, velocity, energy)
		return &"crack"
	return &"bounce"

## Round 6 breakable contract: a blast reached the pillar with `power` J
## (already attenuated). From the crack energy it cracks (the crack rule); from
## Destructible.BLAST_CHIP_SHARE of it, chips. A blast never snaps a pillar.
func receive_blast(center: Vector3, _radius: float, power: float, _source: StringName) -> StringName:
	if is_broken or power <= 0.0:
		return &"hold"
	var crack_at := Tuning.CRACK_FRACTION * break_energy
	var xf := get_box_transform()
	var p := xf * (xf.affine_inverse() * center).clamp(-size * 0.5, size * 0.5)
	var n := get_face_normal(center)
	if power >= crack_at:
		_crack(p, -n, power)
		return &"crack"
	if power >= Destructible.BLAST_CHIP_SHARE * crack_at:
		StrikeMarks.chips(self, p, n, -n, minf(power * 0.05, 60.0), &"concrete")
		return &"chip"
	return &"hold"

## A crack: the slab under the contact comes off, a crack decal, and the break
## energy drops by half the hit's energy (the original spec's crack rule).
func _crack(hit_pos: Vector3, velocity: Vector3, energy: float) -> void:
	is_cracked = true
	var n := get_face_normal(hit_pos - velocity * 0.1)
	chip(hit_pos, n, maxf(energy, CHIP_FROM))
	Destructible.spawn_crack_decal(self, hit_pos, n, energy)
	break_energy = maxf(break_energy - 0.5 * energy, 0.0)
	GameEvents.wall_cracked.emit(self, hit_pos, energy)

## The break: every slab and the core above the stump come down as persistent
## debris. The band under the hit leaves with the body; the bands above topple
## the way it was going. Collision goes at once (before the body arrives).
func _shatter(hit_pos: Vector3, velocity: Vector3, energy: float) -> void:
	is_broken = true
	is_cracked = true
	last_chunks.clear()
	var speed := velocity.length()
	var dir := velocity / speed if speed > 0.01 else -get_face_normal(hit_pos)
	var flat := Vector3(dir.x, 0.0, dir.z)
	flat = flat.normalized() if flat.length() > 0.01 else Vector3.RIGHT
	var exit_speed := speed * sqrt(maxf(1.0 - absorption, 0.0))
	_break_speed = speed
	var band_h := size.y / SEGMENTS
	var hit_band := clampi(int(to_local(hit_pos).y / band_h), 0, SEGMENTS - 1)
	# Face slabs.
	for key: Vector2i in _slabs.keys():
		var slab: Array = _slabs[key]
		var mi: MeshInstance3D = slab[1]
		var xf := global_transform * Transform3D(Basis(), mi.position)
		_spawn_piece(xf, slab[2], _piece_velocity(key.y, hit_band, dir, flat, exit_speed))
		_free_part(slab[0], mi)
	_slabs.clear()
	_slab_dmg.clear()
	# Core: CORE_SPLIT x CORE_SPLIT columns per band, above the stump.
	if not _core.is_empty():
		var core_size := Vector3(size.x - SLAB * 2.0, size.y, size.z - SLAB * 2.0)
		for seg in SEGMENTS:
			var y0 := maxf(seg * band_h, STUMP_H)
			var y1 := (seg + 1) * band_h
			if y1 - y0 < 0.05:
				continue
			for ix in CORE_SPLIT:
				for iz in CORE_SPLIT:
					var piece := Vector3(core_size.x / CORE_SPLIT, y1 - y0, core_size.z / CORE_SPLIT)
					var at := Vector3(-core_size.x * 0.5 + piece.x * (ix + 0.5), (y0 + y1) * 0.5,
						-core_size.z * 0.5 + piece.z * (iz + 0.5))
					_spawn_piece(global_transform * Transform3D(Basis(), at), piece,
						_piece_velocity(seg, hit_band, dir, flat, exit_speed), seg > hit_band)
		_free_part(_core[0], _core[1])
		_core.clear()
	_build_stump()
	GameEvents.wall_broken.emit(self, hit_pos, energy, velocity)
	_drop_head_after(Tuning.PILLAR_COLLAPSE_DELAY)

func _piece_velocity(seg: int, hit_band: int, dir: Vector3, flat: Vector3, exit_speed: float) -> Vector3:
	var jitter := Vector3(randf_range(-0.6, 0.6), randf_range(0.0, 0.8), randf_range(-0.6, 0.6))
	if seg == hit_band:
		return dir * exit_speed * HIT_SHARE * randf_range(0.8, 1.05) + jitter
	if seg < hit_band:
		return dir * exit_speed * HIT_SHARE * 0.4 + jitter
	return flat * TOPPLE_SPEED * (1.0 + 0.4 * (seg - hit_band)) + jitter * 0.5

func _free_part(cs: CollisionShape3D, mi: MeshInstance3D) -> void:
	if is_instance_valid(cs):
		cs.disabled = true   # immediate on the server: the body passes this tick
		cs.queue_free()
	if is_instance_valid(mi):
		mi.queue_free()

func _spawn_piece(xf: Transform3D, sz: Vector3, v: Vector3, falling := false) -> void:
	var b: RigidBody3D = FallingPiece.new() if falling else RigidBody3D.new()
	b.name = "PillarPiece"
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = sz
	mi.mesh = bm
	mi.material_override = WorldMaterials.concrete(1.05)
	mi.layers = Layers.VIS_WORLD
	b.add_child(mi)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = sz * 0.94
	cs.shape = shape
	b.add_child(cs)
	b.mass = maxf(sz.x * sz.y * sz.z * DENSITY, 1.0)
	b.set_meta(&"surface", &"concrete")
	b.transform = xf
	var w := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 2.5
	b.linear_velocity = v
	b.angular_velocity = w
	(get_parent() if get_parent() else self).add_child(b)
	b.linear_velocity = v
	b.angular_velocity = w
	DebrisManager.register(b, false)
	DebrisManager.hold_young(b, maxf(_break_speed, v.length()))
	last_chunks.append(b)

func _build_stump() -> void:
	var sz := Vector3(size.x, STUMP_H, size.z)
	var pair := _add_box(sz, Vector3(0, STUMP_H * 0.5, 0), WorldMaterials.concrete(1.05), true)
	(pair[1] as MeshInstance3D).name = "Stump"
