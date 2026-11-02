class_name Furniture
extends StaticBody3D
## Round 6 breakable clutter (agent K): every kind in Tuning.FURNITURE (glass,
## cardboard, chair, coffee_table, fence, table, barrel, bench, shelf, planter,
## sofa), built from FurnitureKit parts. Implements the breakable contract
## (docs/ARCHITECTURE.md, Round 6): receive_impact / receive_strike /
## receive_blast, absorption, kind, surface, is_broken, get_face_normal,
## get_half_extent_along, group "breakables" (and "clutter"), meta "surface".
##
## Static at rest (StaticBody3D on Layers.DESTRUCTIBLE): capsules collide, the
## AI grid sees it, strikes and the ImpactResolver find it, and low pieces
## (under Tuning.VAULT_MAX) are vaulted like any static obstacle. Glass and
## cardboard carry meta "obstacle" = false: no parkour over them; a fighter
## running in at Tuning.RUN_THROUGH_SPEED smashes through (a walking one is
## stopped by glass and shoves cardboard loose).
##
## Energy model (the walls' one): a flying body's E = 1/2 M v^2 into it breaks
## it at its break energy; from Tuning.CRACK_FRACTION of that it cracks (a
## wobble, a lean, parts split and shift, star cracks on glass) and the break
## energy drops by half the hit's energy, so a second hit finishes it. Strike
## damage accumulates to strike_hp (each strike shows: a wobble and battered
## parts) and also weakens it against bodies (STRIKE_WEAKEN). Blasts arrive with
## their falloff already applied (WorldDamage): glass and cardboard
## (Tuning.RUN_THROUGH_KINDS) break at any power; every other kind never breaks
## from a blast: from its crack energy a blast cracks it (its break energy drops
## by half the blast's power, down to BLAST_CRACK_FLOOR of the original, so the
## next body breaks it easily), below that it shakes; chairs hop loose.
##
## Light kinds (chair, cardboard) that a hit cracks or a blast shoves come loose
## instead: the object becomes one LooseFurniture body (debris, stays, freezes
## at rest; capsules push it), which still breaks on a hard hit.
##
## Breaking: the parts become real pieces (DebrisManager: they stay and freeze)
## sent off with a share of the hitting velocity; glass leaves a few lasting
## shards plus fine shards on a timer (DebrisManager's chip pool); a shelf
## spills its 2-4 things as ThrowableProps; anything stacked on it comes loose.
## Collision goes off at once, so a broken object stops blocking movement and
## navigation. Emits GameEvents.furniture_broken(node, position, kind, energy, by)
## with energy in J (strikes and blasts report at least the break energy).
## OWNER: agent K (clutter).

signal broken(position: Vector3, energy: float)
signal cracked(position: Vector3, energy: float)

## Kinds that come loose (a whole-object debris body) when hit but not broken.
const LOOSE_KINDS: Array[StringName] = [&"chair", &"cardboard"]
## Strike damage weakens the object against bodies: at strike_hp - epsilon the
## break energy is (1 - STRIKE_WEAKEN) of its value.
const STRIKE_WEAKEN := 0.6
## A strike result reads "crack" from this share of strike_hp (else "chip").
const STRIKE_CRACK_SHARE := 0.34
## m/s pieces leave a strike break with, along the strike.
const STRIKE_PUSH := 2.5
## Share of the exit velocity pieces near / far from the hit take, the radial
## spread (m/s) and the distance (m) over which "near" falls off.
const PIECE_SHARE := Vector2(0.55, 1.0)
const PIECE_SPREAD := Vector2(0.6, 2.2)
const PIECE_FALLOFF := 1.2
## Battered look: parts tilt up to JITTER_DEG and shift up to JITTER_POS m at
## full damage; split parts (table tops) open SPLIT_DEG at the seam.
const JITTER_DEG := 7.0
const JITTER_POS := 0.03
const SPLIT_DEG := 7.0
## A crack leans the object away from the hit, LEAN_DEG per crack, at most LEAN_MAX_DEG.
const LEAN_DEG := 2.5
const LEAN_MAX_DEG := 5.0
## Wobble after a hit: duration (s), frequency (Hz), damping (1/s), degrees at full strength.
const WOBBLE_TIME := 0.6
const WOBBLE_FREQ := 4.5
const WOBBLE_DAMP := 6.5
const WOBBLE_DEG := 6.0
## Run-through (glass, cardboard): the Area3D reaches this far past the faces;
## a run counts within 60 degrees of straight in, when the capsule is within
## RUN_LOOKAHEAD s of travel (+ RUN_MARGIN m) of the face.
const RUN_REACH := 0.5
const RUN_COS := 0.5
const RUN_LOOKAHEAD := 3.0 / 120.0
const RUN_MARGIN := 0.06
## A fighter walking into cardboard at this speed or more (toward it) shoves it
## loose, at this share of his speed.
const SHOVE_MIN_SPEED := 0.8
const SHOVE_SHARE := 1.15
## Glass: lasting shards (stay) and fine shards (timed: life in s).
const SHARDS_LASTING := 4
const SHARDS_FINE := 8
const SHARD_LIFE := Vector2(2.5, 4.0)
## At most this many star cracks on one pane.
const GLASS_CRACKS_MAX := 3
## m: a tracked flying body this close to the hit is the one that broke it.
const FLYER_RADIUS := 2.5
## Knocked loose: share of the hitting body's velocity the object leaves with,
## and the hop (m/s up) a blast gives it (min at the edge, max at full power).
const LOOSE_SHARE := 0.6
const BLAST_HOP := Vector2(1.2, 3.2)
## J of blast power at the object below which a light object only shakes.
const BLAST_SHOVE_FROM := 30.0
## s the body that broke a loose object passes through its pieces (as ImpactResolver's chunks).
const FLYER_PASS_TIME := 1.5
## A blast never breaks anything but glass and cardboard: it cracks the rest,
## lowering the break energy at most to this share of the original.
const BLAST_CRACK_FLOOR := 0.2
## m added round the object when the AI grid re-tests its cells.
const NAV_REFRESH_PAD := 0.6

## A Tuning.FURNITURE kind.
@export var kind: StringName = &"table"
## Geometry variant (FurnitureKit): glass &"narrow", planter &"long",
## shelf &"few" / &"full", cardboard &"small" / &"big".
@export var variant: StringName = &""

var surface: StringName = &"wood"
var absorption := 0.1
var break_energy := 500.0
var original_break_energy := 500.0
var strike_hp := 60.0
## Strike power taken so far (resets never; it is the object's damage).
var damage := 0.0
## The breakable's box size (ImpactResolver, blasts); see get_box_transform().
var size := Vector3.ONE
var is_broken := false
var is_cracked := false
## True once it came loose (its LooseFurniture body carries it now).
var is_loose := false
## Pieces spawned by the break (ImpactResolver lets the breaking body pass them).
var last_chunks: Array[RigidBody3D] = []
## Shelf: the throwables it spilled.
var spilled: Array[ThrowableProp] = []
## Who broke it (a body, an attacker or a runner; null for a blast).
var broken_by: Node3D = null
var loose_body: RigidBody3D = null
## The object it stands on (a stacked box), set by the layout.
var resting_on: Furniture = null
## The breaking flyer's centre-of-mass speed just before and after a loose
## break charged it (tests).
var last_flyer_speeds := Vector2.ZERO

var _spec: FurnitureKit.Spec
var _visual: Node3D
var _mis := {}                 ## material -> MeshInstance3D
var _shapes: Array[CollisionShape3D] = []
var _area: Area3D
var _watch: Array[Fighter] = []
var _above: Array[Furniture] = []
var _battered := 0.0
var _lean := Basis()
var _wob_axis := Vector3.RIGHT
var _wob_amp := 0.0
var _tween: Tween
var _cracks: Array[MeshInstance3D] = []
var _rng := RandomNumberGenerator.new()
var _built := false

## A new object of `kind` at `xf` (in its future parent's frame).
static func create(p_kind: StringName, xf: Transform3D, p_variant: StringName = &"") -> Furniture:
	var f := Furniture.new()
	f.kind = p_kind
	f.variant = p_variant
	f.name = String(p_kind).to_pascal_case()
	f.transform = xf
	return f

func _ready() -> void:
	if not _built:
		_build()
	if resting_on != null and is_instance_valid(resting_on):
		resting_on._above.append(self)

func _build() -> void:
	_built = true
	_spec = FurnitureKit.get_spec(kind, variant)
	var data: Dictionary = Tuning.FURNITURE.get(kind, Tuning.FURNITURE[&"table"])
	break_energy = float(data["break"])
	original_break_energy = break_energy
	absorption = float(data["absorb"])
	strike_hp = float(data["strike_hp"])
	surface = data["surface"]
	collision_layer = Layers.DESTRUCTIBLE
	collision_mask = 0
	set_meta(&"surface", surface)
	if kind in Tuning.RUN_THROUGH_KINDS:
		set_meta(&"obstacle", false)
	add_to_group(&"breakables")
	add_to_group(&"clutter")
	size = _spec.bounds.size
	for sh: Array in _spec.shapes:
		var cs := CollisionShape3D.new()
		cs.shape = sh[0]
		cs.transform = sh[1]
		add_child(cs)
		_shapes.append(cs)
	_visual = Node3D.new()
	_visual.name = "Visual"
	add_child(_visual)
	_mis = FurnitureKit.add_meshes(_visual, _spec.intact)
	_rng.seed = hash(get_instance_id())
	if kind in Tuning.RUN_THROUGH_KINDS:
		_build_run_area()
	set_physics_process(false)

## The kit spec (parts, pieces, contents) this object is built from.
func get_spec() -> FurnitureKit.Spec:
	if not _built:
		_build()
	return _spec

# --- Breakable contract --------------------------------------------------------------

## The breakable's box: its bounds centre in world space (size = `size`).
func get_box_transform() -> Transform3D:
	if not _built:
		_build()
	return global_transform * Transform3D(Basis(), _spec.bounds.get_center())

## Energy at or above which a flying body cracks it (INF once broken or loose).
func get_crack_threshold() -> float:
	if is_broken or is_loose:
		return INF
	return Tuning.CRACK_FRACTION * get_break_energy()

## Break energy for a flying body now: cracks lowered it, strike damage weakens it.
func get_break_energy() -> float:
	return maxf(break_energy * (1.0 - STRIKE_WEAKEN * clampf(damage / maxf(strike_hp, 1.0), 0.0, 1.0)), 1.0)

## World unit normal of the box face a body at `from` meets: the top (or
## bottom) only when `from` is over (under) the footprint, else the side face
## toward it. A body flying past at hip height hits a coffee table's side, not
## its top, however low the table is; a body coming down on it hits the top.
func get_face_normal(from: Vector3) -> Vector3:
	var xf := get_box_transform()
	var lp := xf.affine_inverse() * from
	var h := size * 0.5
	var axis := 1
	var over := absf(lp.x) <= h.x and absf(lp.z) <= h.z
	if not over or absf(lp.y) <= h.y:
		var r := Vector3(absf(lp.x) / maxf(h.x, 0.01), absf(lp.y) / maxf(h.y, 0.01), absf(lp.z) / maxf(h.z, 0.01))
		if over:
			axis = 0 if r.x >= r.y and r.x >= r.z else (1 if r.y >= r.z else 2)
		else:
			axis = 0 if r.x >= r.z else 2
	var n := xf.basis[axis].normalized()
	return -n if lp[axis] < 0.0 else n

## Half size of the box along world direction `n`.
func get_half_extent_along(n: Vector3) -> float:
	var b := global_basis
	return absf(n.dot(b.x.normalized())) * size.x * 0.5 + absf(n.dot(b.y.normalized())) * size.y * 0.5 \
		+ absf(n.dot(b.z.normalized())) * size.z * 0.5

## Clutter is never run along.
func is_runnable() -> bool:
	return false

## A flying body (ImpactResolver, before contact): &"break", &"crack" or &"bounce".
func receive_impact(energy: float, hit_pos: Vector3, velocity: Vector3, _footprint := Rect2()) -> StringName:
	if not _built:
		_build()
	if is_broken:
		return &"break"
	if is_loose:
		return &"bounce"
	var need := get_break_energy()
	if energy >= need:
		_break(hit_pos, velocity, energy, _impact_body(hit_pos))
		return &"break"
	if energy >= Tuning.CRACK_FRACTION * need:
		_crack(hit_pos, velocity, energy, need)
		if kind in LOOSE_KINDS:
			_knock_loose(velocity * LOOSE_SHARE + Vector3.UP * 1.0, _spin(4.0))
		return &"crack"
	if energy >= Tuning.CRACK_FRACTION * need * 0.25:
		_wobble(velocity, energy / need)
	return &"bounce"

## A punch or kick (CombatController, thrown props). Returns &"chip", &"crack",
## &"break" or &"hold"; emits GameEvents.wall_struck.
func receive_strike(attacker: Node3D, hit_pos: Vector3, direction: Vector3, power: float) -> StringName:
	if not _built:
		_build()
	var d := direction.normalized() if direction.length() > 0.01 else Vector3.FORWARD
	var n := get_face_normal(hit_pos - d * 0.5)
	var result := &"hold"
	if is_broken or is_loose or power <= 0.0:
		return result
	damage += power
	if damage >= strike_hp:
		result = &"break"
		var energy := original_break_energy * maxf(damage / strike_hp, 1.0)
		var push := d * STRIKE_PUSH
		if attacker is Fighter:
			push += (attacker as Fighter).real_velocity() * 0.3
		_break(hit_pos, push, energy, attacker)
	else:
		var share := damage / strike_hp
		result = &"crack" if share >= STRIKE_CRACK_SHARE else &"chip"
		if kind == &"glass":
			_add_glass_crack(hit_pos)
		else:
			_batter(share)
			if surface == &"wood" or surface == &"concrete":
				StrikeMarks.chips(self, hit_pos, n, d, power, surface)
		_wobble(d, clampf(power / strike_hp, 0.3, 1.0))
	GameEvents.wall_struck.emit(attacker, self, hit_pos, n, power, result, surface)
	return result

## A blast (WorldDamage): `power` is the energy that reached this object (its
## falloff already applied). Glass and cardboard break at any power; every
## other kind at most cracks (weakened for the next body) or, light ones, hops
## loose. Returns &"break" (glass, cardboard only), &"crack", &"shove" or &"hold".
func receive_blast(center: Vector3, _radius: float, power: float, _source: StringName) -> StringName:
	if not _built:
		_build()
	if is_broken or is_loose or power <= 0.0:
		return &"hold"
	var box := get_box_transform()
	var away := box.origin - center
	away.y = 0.0
	away = away.normalized() if away.length() > 0.01 else Vector3(_rng.randf_range(-1, 1), 0, 1).normalized()
	var hit := _nearest_point(center)
	var k := clampf(power / maxf(original_break_energy, 1.0), 0.0, 1.0)
	if kind in Tuning.RUN_THROUGH_KINDS:
		_break(hit, away * lerpf(2.0, 5.0, k) + Vector3.UP * 1.5, maxf(power, original_break_energy), null)
		return &"break"
	var need := get_break_energy()
	if power >= Tuning.CRACK_FRACTION * need:
		_crack(hit, away, power, need, BLAST_CRACK_FLOOR * original_break_energy)
		if kind in LOOSE_KINDS:
			_knock_loose(away * lerpf(1.5, 3.5, k) + Vector3.UP * lerpf(BLAST_HOP.x, BLAST_HOP.y, k), _spin(5.0))
		return &"crack"
	if kind in LOOSE_KINDS and power >= BLAST_SHOVE_FROM:
		var h := clampf(power / (Tuning.CRACK_FRACTION * need), 0.0, 1.0)
		_knock_loose(away * lerpf(0.8, 2.0, h) + Vector3.UP * lerpf(BLAST_HOP.x, BLAST_HOP.y, h), _spin(3.0))
		return &"shove"
	_wobble(away, clampf(power / (Tuning.CRACK_FRACTION * need), 0.2, 0.8))
	return &"shove"

## Scripted break (tests, collapses): the whole object goes now.
func force_break(hit_pos: Vector3, velocity := Vector3.ZERO, by: Node3D = null) -> void:
	if not _built:
		_build()
	if is_broken or is_loose:
		return
	_break(hit_pos, velocity, maxf(original_break_energy, break_energy), by)

# --- Cracks, wobble, battered look ---------------------------------------------------

## A crack: the break energy drops by half `energy`, never under `floor_energy`
## (nor raised by it).
func _crack(hit_pos: Vector3, velocity: Vector3, energy: float, need: float, floor_energy := 1.0) -> void:
	is_cracked = true
	break_energy = maxf(break_energy - 0.5 * energy, minf(break_energy, floor_energy))
	var share := clampf(energy / need, 0.0, 1.0)
	if kind == &"glass":
		_add_glass_crack(hit_pos)
	else:
		_batter(maxf(_battered, 0.35) + 0.4 * share)
		var flat := Vector3(velocity.x, 0.0, velocity.z)
		if flat.length() > 0.01:
			var axis := global_basis.inverse() * Vector3.UP.cross(flat.normalized())
			var lean := _lean * Basis(axis.normalized(), deg_to_rad(LEAN_DEG * (0.5 + share)))
			if rad_to_deg(acos(clampf(lean.y.normalized().y, -1.0, 1.0))) <= LEAN_MAX_DEG:
				_lean = lean
	_wobble(velocity, 0.6 + 0.4 * share)
	cracked.emit(hit_pos, energy)

## Damage look 0..1: parts tilt and shift (split parts open at the seam).
func _batter(level: float) -> void:
	level = clampf(level, 0.0, 1.0)
	if level <= _battered + 0.02 or _visual == null:
		return
	_battered = level
	var xfs: Array[Transform3D] = []
	var rng := RandomNumberGenerator.new()
	for i in _spec.parts.size():
		var p: FurnitureKit.Part = _spec.parts[i]
		rng.seed = hash(get_instance_id()) + i * 7919
		var xf := p.xf
		if p.piece == FurnitureKit.GLASS:
			xfs.append(xf)
			continue
		if p.split != Vector3.ZERO:
			xf = xf * Transform3D(Basis(p.split.normalized(), deg_to_rad(SPLIT_DEG * level)), Vector3.UP * 0.01 * level)
		else:
			var axis := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
			if axis.length() < 0.01:
				axis = Vector3.RIGHT
			var off := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 0.3), rng.randf_range(-1, 1))
			xf = Transform3D(Basis(axis.normalized(), deg_to_rad(JITTER_DEG * level * rng.randf_range(0.3, 1.0))),
				off * JITTER_POS * level) * xf
		xfs.append(xf)
	var meshes := FurnitureKit.build_meshes(_spec, xfs)
	for m: StringName in meshes:
		var mi := _mis.get(m) as MeshInstance3D
		if mi != null:
			mi.mesh = meshes[m]

## Shake for WOBBLE_TIME around the lean, away from `toward` (a hit direction).
func _wobble(toward: Vector3, strength: float) -> void:
	if _visual == null or not is_inside_tree():
		return
	var flat := Vector3(toward.x, 0.0, toward.z)
	var axis := Vector3.UP.cross(flat.normalized()) if flat.length() > 0.01 else Vector3.RIGHT
	_wob_axis = (global_basis.inverse() * axis).normalized()
	var deg := WOBBLE_DEG * clampf(strength, 0.0, 1.0)
	if kind == &"glass" or _spec.tall:
		deg *= 0.4
	_wob_amp = deg_to_rad(deg)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_tween.tween_method(_wobble_step, 0.0, WOBBLE_TIME, WOBBLE_TIME)

func _wobble_step(t: float) -> void:
	if _visual == null:
		return
	var a := _wob_amp * exp(-t * WOBBLE_DAMP) * sin(t * TAU * WOBBLE_FREQ)
	if t >= WOBBLE_TIME - 1e-4:
		a = 0.0
	_visual.transform = Transform3D(_lean * Basis(_wob_axis, a), Vector3.ZERO)

## A star crack on the pane at `hit_pos` (both faces).
func _add_glass_crack(hit_pos: Vector3) -> void:
	is_cracked = true
	if _visual == null or _cracks.size() >= GLASS_CRACKS_MAX:
		return
	var pane := _pane_part()
	if pane == null:
		return
	var local := (global_transform * _visual.transform).affine_inverse() * hit_pos
	var half := pane.size * 0.5
	var c := pane.xf.origin
	local.x = clampf(local.x, c.x - half.x + 0.15, c.x + half.x - 0.15)
	local.y = clampf(local.y, c.y - half.y + 0.15, c.y + half.y - 0.15)
	local.z = c.z
	var q := QuadMesh.new()
	var s := _rng.randf_range(0.6, 0.9)
	q.size = Vector2(s, s)
	var mi := MeshInstance3D.new()
	mi.name = "Crack"
	mi.mesh = q
	mi.material_override = FurnitureKit.material(&"crack")
	mi.layers = Layers.VIS_WORLD
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.transform = Transform3D(Basis(Vector3.BACK, _rng.randf_range(0.0, TAU)), local)
	_visual.add_child(mi)
	_cracks.append(mi)
	set_meta(&"view_fade_geoms", [])

func _pane_part() -> FurnitureKit.Part:
	for p in _spec.parts:
		if p.piece == FurnitureKit.GLASS:
			return p
	return null

# --- Breaking ------------------------------------------------------------------------

func _break(hit_pos: Vector3, velocity: Vector3, energy: float, by: Node3D) -> void:
	if is_broken:
		return
	is_broken = true
	is_cracked = true
	broken_by = by
	var vis_xf := global_transform * (_visual.transform if _visual else Transform3D())
	_disable_collision()
	last_chunks = _spawn_pieces(vis_xf, hit_pos, velocity)
	if kind == &"glass":
		last_chunks.append_array(_spawn_shards(vis_xf, hit_pos, velocity))
	FurnitureKit.guard_pieces(get_parent(), last_chunks, velocity.length())
	if not _spec.contents.is_empty():
		_spill(vis_xf, velocity)
	_free_visuals()
	_release_above(velocity)
	broken.emit(hit_pos, energy)
	GameEvents.furniture_broken.emit(self, hit_pos, kind, energy, by)

## A LooseFurniture body of this object took a hard hit (`dv`: the hit's
## velocity; `by`: the body or runner, else the nearest flyer; `energy` < 0:
## from the knock): it breaks where it is.
func break_loose(body: RigidBody3D, dv: Vector3, by: Node3D = null, energy := -1.0) -> void:
	if is_broken or body == null or not is_instance_valid(body):
		return
	is_broken = true
	is_cracked = true
	var xf := body.global_transform
	var v := body.linear_velocity
	if DebrisManager.has_method(&"release"):
		DebrisManager.release(body)
	body.queue_free()
	loose_body = null
	if by == null:
		by = _find_flyer(xf.origin, false)
	broken_by = by
	last_chunks = _spawn_pieces(xf, xf.origin - dv.normalized() * 0.2, v + dv * 0.5)
	if energy < 0.0:
		energy = 0.5 * _spec.mass * dv.length_squared()
	energy = maxf(original_break_energy, energy)
	var flyer := by as Fighter
	var speed := dv.length()
	if flyer != null and is_instance_valid(flyer) and ImpactResolver.is_tracking(flyer):
		speed = flyer.get_com_velocity().length()
		_flyer_pays(flyer, xf.origin, dv, energy)
	FurnitureKit.guard_pieces(get_parent(), last_chunks, speed)
	broken.emit(xf.origin, energy)
	GameEvents.furniture_broken.emit(self, xf.origin, kind, energy, by)

## A flying body that broke this object loose costs it what the ImpactResolver
## charges for any breakable: sqrt(1 - absorption) of its speed and
## Tuning.FURNITURE_BODY_DAMAGE; and it passes through the fresh pieces
## (collision exceptions for FLYER_PASS_TIME s).
func _flyer_pays(f: Fighter, pos: Vector3, dv: Vector3, energy: float) -> void:
	var before := f.get_com_velocity()
	if f.ragdoll:
		f.ragdoll.scale_velocity(sqrt(maxf(1.0 - absorption, 0.0)))
	last_flyer_speeds = Vector2(before.length(), f.get_com_velocity().length())
	var dmg := Tuning.FURNITURE_BODY_DAMAGE
	var info := HitInfo.new()
	info.victim = f
	info.move_id = &"wall"
	info.kind = &"impact"
	info.damage = dmg
	info.reaction = HitInfo.Reaction.NONE
	info.tier = HitInfo.Tier.NONE
	info.hit_position = pos
	info.hit_direction = dv.normalized() if dv.length() > 0.01 else Vector3.DOWN
	info.energy = energy
	info.result = HitInfo.Result.HIT
	if ImpactResolver.is_thrown_flight(f):
		info.attacker = ImpactResolver.get_launcher(f) as Fighter
	f.apply_damage(dmg, &"impact", info)
	GameEvents.body_impact.emit(f, pos, -info.hit_direction, energy, surface)
	GameEvents.impact_damaged.emit(f, dmg, energy, surface, pos)
	if f.rig == null:
		return
	var bones: Array = f.rig.get_physical_bones()
	var pieces := last_chunks.duplicate()
	for c: RigidBody3D in pieces:
		for b: PhysicalBone3D in bones:
			if is_instance_valid(b):
				c.add_collision_exception_with(b)
	get_tree().create_timer(FLYER_PASS_TIME, true, true, false).timeout.connect(func() -> void:
		for c: Variant in pieces:
			if not is_instance_valid(c):
				continue
			for b: Variant in bones:
				if is_instance_valid(b):
					(c as RigidBody3D).remove_collision_exception_with(b))

func _disable_collision() -> void:
	collision_layer = 0
	_refresh_nav()
	for cs in _shapes:
		cs.set_deferred(&"disabled", true)
	if _area != null:
		_area.set_deferred(&"monitoring", false)
	_watch.clear()
	set_physics_process(false)

## The AI grid re-tests the cells this object stood on (AttackDirector's
## public queue; C may also refresh on GameEvents.furniture_broken).
func _refresh_nav() -> void:
	var ad := get_node_or_null(^"/root/AttackDirector") if is_inside_tree() else null
	if ad != null and ad.has_method(&"queue_nav_refresh"):
		ad.call(&"queue_nav_refresh", get_box_transform().origin, maxf(size.x, size.z) * 0.5 + NAV_REFRESH_PAD)

func _free_visuals() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if _visual != null:
		_visual.queue_free()
		_visual = null
	_mis.clear()
	_cracks.clear()
	set_meta(&"view_fade_geoms", [])

## Every piece of the kit, sent off with a share of `velocity` (more near the hit).
func _spawn_pieces(vis_xf: Transform3D, hit_pos: Vector3, velocity: Vector3) -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	var parent := get_parent() if get_parent() else self
	var speed := velocity.length()
	var dir := velocity / speed if speed > 0.01 else Vector3.UP
	var exit := speed * sqrt(maxf(1.0 - absorption, 0.0))
	for i in _spec.pieces.size():
		var ps: FurnitureKit.PieceSpec = _spec.pieces[i]
		var b := FurnitureKit.make_piece_body(_spec, i)
		var xf := vis_xf * Transform3D(Basis(), ps.origin)
		var r := xf.origin - hit_pos
		var dist := r.length()
		var near := clampf(1.0 - dist / PIECE_FALLOFF, 0.0, 1.0)
		var radial := r / dist if dist > 0.01 else Vector3.UP
		var v := dir * exit * lerpf(PIECE_SHARE.x, PIECE_SHARE.y, near) * _rng.randf_range(0.85, 1.1)
		v += radial * _rng.randf_range(PIECE_SPREAD.x, PIECE_SPREAD.y) * (0.4 + 0.6 * near)
		v += Vector3.UP * _rng.randf_range(0.2, 1.4)
		var w := _spin(1.5 + 5.0 * near)
		parent.add_child(b)
		b.global_transform = xf
		b.reset_physics_interpolation()
		b.linear_velocity = v
		b.angular_velocity = w
		DebrisManager.register(b, _spec.pieces[i].small)
		out.append(b)
	return out

## The pane goes: SHARDS_LASTING shards that stay, SHARDS_FINE on a timer.
func _spawn_shards(vis_xf: Transform3D, hit_pos: Vector3, velocity: Vector3) -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	var pane := _pane_part()
	if pane == null:
		return out
	var parent := get_parent() if get_parent() else self
	var pane_xf := vis_xf * pane.xf
	var local_hit := pane_xf.affine_inverse() * hit_pos
	var half := pane.size * 0.5
	var speed := velocity.length()
	var dir := velocity / speed if speed > 0.01 else -pane_xf.basis.z.normalized()
	var exit := speed * sqrt(maxf(1.0 - absorption, 0.0))
	for k in SHARDS_LASTING + SHARDS_FINE:
		var big := k < SHARDS_LASTING
		var b := FurnitureKit.make_shard(big, k)
		var at := Vector2(_rng.randf_range(-half.x, half.x), _rng.randf_range(-half.y, half.y)) * 0.85
		if not big:
			# Fine shards burst from round the hit.
			at = Vector2(clampf(local_hit.x, -half.x, half.x), clampf(local_hit.y, -half.y, half.y)) \
				+ Vector2(_rng.randf_range(-0.35, 0.35), _rng.randf_range(-0.35, 0.35))
		var xf := pane_xf * Transform3D(Basis(Vector3.BACK, _rng.randf_range(0.0, TAU)), Vector3(at.x, at.y, 0.0))
		var r := xf.origin - hit_pos
		var near := clampf(1.0 - r.length() / PIECE_FALLOFF, 0.0, 1.0)
		var v := dir * exit * lerpf(0.5, 1.05, near) * _rng.randf_range(0.8, 1.15)
		v += r.normalized() * _rng.randf_range(0.5, 2.5) * (0.3 + 0.7 * near) + Vector3.UP * _rng.randf_range(0.0, 1.5)
		parent.add_child(b)
		b.global_transform = xf
		b.reset_physics_interpolation()
		b.linear_velocity = v
		b.angular_velocity = _spin(8.0)
		if big:
			DebrisManager.register(b, true)
		else:
			DebrisManager.register(b, true, _rng.randf_range(SHARD_LIFE.x, SHARD_LIFE.y))
		out.append(b)
	return out

## Shelf contents fall out as throwables (they do not respawn).
func _spill(vis_xf: Transform3D, velocity: Vector3) -> void:
	var holder := _throwable_holder()
	for c: Array in _spec.contents:
		var p := ThrowableProp.spawn(holder, c[0], vis_xf * (c[1] as Transform3D), false)
		p.linear_velocity = velocity * 0.45 + Vector3(_rng.randf_range(-1.2, 1.2), _rng.randf_range(0.5, 2.0),
			_rng.randf_range(-1.2, 1.2))
		p.angular_velocity = _spin(4.0)
		spilled.append(p)

func _throwable_holder() -> Node:
	var arena := get_tree().get_first_node_in_group(&"arena") if is_inside_tree() else null
	if arena != null and arena.is_ancestor_of(self):
		var h := arena.get_node_or_null(^"Throwables")
		if h != null:
			return h
	return get_parent() if get_parent() else self

## Anything stacked on this comes loose (no floating boxes).
func _release_above(velocity: Vector3) -> void:
	for f in _above:
		if is_instance_valid(f) and not f.is_broken and not f.is_loose:
			f._knock_loose(velocity * 0.3 + Vector3(_rng.randf_range(-0.6, 0.6), 0.4, _rng.randf_range(-0.6, 0.6)),
				_spin(2.0))
	_above.clear()

## The whole object becomes one loose debris body (LooseFurniture) with `v`, `w`.
func _knock_loose(v: Vector3, w: Vector3) -> void:
	if is_loose or is_broken or not is_inside_tree():
		return
	is_loose = true
	var b := LooseFurniture.new()
	b.furniture = self
	b.name = "Loose" + String(kind).to_pascal_case()
	var meshes := {}
	for m: StringName in _mis:
		meshes[m] = (_mis[m] as MeshInstance3D).mesh
	FurnitureKit.add_meshes(b, meshes)
	for sh: Array in _spec.shapes:
		var cs := CollisionShape3D.new()
		cs.shape = sh[0]
		cs.transform = sh[1]
		b.add_child(cs)
	b.mass = _spec.mass
	b.angular_damp = FurnitureKit.PIECE_ANGULAR_DAMP
	b.physics_material_override = FurnitureKit.piece_physics()
	b.set_meta(&"surface", surface)
	var xf := global_transform * (_visual.transform if _visual else Transform3D())
	var parent := get_parent() if get_parent() else self
	parent.add_child(b)
	b.global_transform = xf
	b.reset_physics_interpolation()
	b.linear_velocity = v
	b.angular_velocity = w
	DebrisManager.register(b, false)
	loose_body = b
	_disable_collision()
	_free_visuals()
	_release_above(v)

# --- Run-through (glass, cardboard) -------------------------------------------------

func _build_run_area() -> void:
	_area = Area3D.new()
	_area.name = "RunThrough"
	_area.collision_layer = 0
	_area.collision_mask = Layers.CAPSULE
	_area.monitorable = false
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size + Vector3(RUN_REACH * 2.0, 0.0, RUN_REACH * 2.0)
	cs.shape = box
	cs.position = _spec.bounds.get_center()
	_area.add_child(cs)
	add_child(_area)
	_area.body_entered.connect(_on_body_entered)
	_area.body_exited.connect(_on_body_exited)

func _on_body_entered(body: Node3D) -> void:
	var f := body as Fighter
	if f != null and not _watch.has(f):
		_watch.append(f)
		set_physics_process(true)

func _on_body_exited(body: Node3D) -> void:
	_watch.erase(body as Fighter)

func _physics_process(_delta: float) -> void:
	if is_broken or is_loose or _watch.is_empty():
		set_physics_process(false)
		return
	for f in _watch.duplicate():
		if not is_instance_valid(f) or f.is_queued_for_deletion():
			_watch.erase(f)
			continue
		if f.is_dead() or f.is_body_simulating():
			continue  # bodies in the air are the ImpactResolver's
		if _check_run(f):
			return

## A capsule about to touch: smash at run speed; cardboard shoves loose when walked into.
func _check_run(f: Fighter) -> bool:
	var v := f.real_velocity()
	v.y = 0.0
	var speed := v.length()
	if speed < 0.05:
		return false
	var center := f.global_position + Vector3.UP * 0.9
	var n := get_face_normal(center)
	n.y = 0.0
	if n.length() < 0.5:
		return false
	n = n.normalized()
	var into := -v.dot(n)
	if into <= 0.0:
		return false
	var face := get_box_transform().origin + n * get_half_extent_along(n)
	var gap := (center - face).dot(n) - Fighter.CAPSULE_RADIUS
	if speed >= Tuning.RUN_THROUGH_SPEED and into >= speed * RUN_COS and gap <= into * RUN_LOOKAHEAD + RUN_MARGIN:
		var hit := _nearest_point(center)
		var energy := 0.5 * f.get_total_mass() * speed * speed
		_break(hit, v, energy, f)
		return true
	if kind == &"cardboard" and into >= SHOVE_MIN_SPEED and gap <= into * RUN_LOOKAHEAD + RUN_MARGIN:
		_knock_loose(v * SHOVE_SHARE + Vector3.UP * 0.6, _spin(2.5))
		return true
	return false

# --- Helpers -------------------------------------------------------------------------

## The flying body ImpactResolver is resolving into us right now (it sets meta
## `impact_body` before receive_impact); else the nearest tracked flyer.
func _impact_body(pos: Vector3) -> Node3D:
	var b: Variant = get_meta(&"impact_body") if has_meta(&"impact_body") else null
	if b is Node3D and is_instance_valid(b):
		return b
	return _find_flyer(pos, true)

## The flying body that just hit (a tracked flyer near `pos`); with
## `flyers_only` false also a standing fighter within 1.5 m (a runner).
func _find_flyer(pos: Vector3, flyers_only: bool) -> Node3D:
	if not is_inside_tree():
		return null
	var best: Node3D = null
	var best_d := FLYER_RADIUS
	for n in get_tree().get_nodes_in_group(&"fighters"):
		var f := n as Fighter
		if f == null:
			continue
		var tracked := ImpactResolver.is_tracking(f)
		if not tracked and flyers_only:
			continue
		var d := f.get_center_of_mass().distance_to(pos)
		if not tracked:
			d += 1.0   # a standing fighter only when no flyer is close
		if d < best_d:
			best_d = d
			best = f
	return best

func _nearest_point(p: Vector3) -> Vector3:
	var xf := get_box_transform()
	var lp := xf.affine_inverse() * p
	var h := size * 0.5
	return xf * lp.clamp(-h, h)

func _spin(amount: float) -> Vector3:
	return Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * amount
