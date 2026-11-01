extends Node
## Autoload "ImpactResolver" (spec: Impact resolution). Every physics tick, for
## each LAUNCHED fighter: sweep the body's bounds along its centre-of-mass
## velocity (extent + 2 ticks of travel) against Destructibles and standing
## enemy capsules; decide break / crack / bounce BEFORE contact; deal impact
## damage for every hard impact (walls, pillars, floor, bodies); human bowling.
## OWNER: agent D (world). CONTRACT STUB.
##
## How a wall decision works (per tracked fighter, per tick):
## 1. Query the volume the body's AABB sweeps over the next (2 x extent along v
##    + 2 ticks of travel). Every intact Destructible in it gets an exact swept
##    AABB-vs-panel time to contact.
## 2. E = 0.5 * M * (v . -n)^2. While an undecided panel ahead has E at or above
##    its crack threshold, bones ignore breakables (ragdoll.set_ignore_breakables).
## 3. When contact is within DECIDE_TICKS ticks, the panel decides once for this
##    pass: break (fracture now, scale bone velocities by sqrt(1 - absorption),
##    slow motion, chunks ignore this body briefly) or crack/bounce (collision is
##    re-enabled before contact so the body bounces physically).
## Impact damage: wall decisions deal Tuning.impact_damage(E) at once. Every other
## hard impact (floor, concrete walls, pillars, bodies) is found from a sudden
## change of the centre-of-mass velocity over IMPACT_WINDOW (gravity removed)
## that opposes the motion; its normal and surface come from a ray toward the
## contact. A per-fighter cooldown makes one impact count once.

## Debug / test hooks (not part of the cross-module contract).
signal wall_decided(fighter: Node3D, wall: Node3D, outcome: StringName, energy: float, position: Vector3)
signal impact_dealt(fighter: Node3D, energy: float, damage: float, surface: StringName, position: Vector3)
signal impact_info(info: HitInfo)

# Local constants (candidates for Tuning).
const LOOKAHEAD_TICKS := 2.0     ## ticks of travel added to the sweep
const DECIDE_TICKS := 2.5        ## decide when contact is this many ticks away
const DECIDE_MIN_DIST := 0.1     ## m; never decide later than this gap
const SWEEP_MARGIN := 0.08       ## m added around the body AABB
const MIN_SWEEP_SPEED := 0.5     ## m/s; slower bodies are not swept
const IMPACT_WINDOW := 0.1       ## s of COM velocity history for impact detection
const IMPACT_COOLDOWN := 0.25    ## s; one impact counts once
const DECISION_FORGET := 0.3     ## s a panel must be out of the sweep before it may decide again
const CHUNK_PASS_TIME := 0.25    ## s chunks ignore the body that broke them
const STOP_GRACE := 0.15         ## s out of LAUNCHED/DEAD before tracking stops
const DEAD_SETTLE_SPEED := 0.25
const DEAD_SETTLE_TIME := 1.0
const BOWL_LIFT := 0.2           ## bowled launch gets at least this much up per horizontal m/s
const SHAKE_IMPACT_FROM := 1500.0
## s (game time) after a launch during which the body never bowls the fighter
## that launched it (a thrown body starts ~0.7 m from its grabber).
const BOWL_ATTACKER_GRACE := 0.25
## Skip a wall decision when at least this fraction of the body's outline on
## the panel is already open (it flies through an existing hole).
const OPEN_SKIP := 0.85
## Real seconds of local hitstop on a body that cracks or bounces off a breakable.
const WALL_HITSTOP := 0.06
## Same for a hard hit on static concrete (walls, pillars) from this energy.
const CONCRETE_HITSTOP := 0.05
const CONCRETE_HITSTOP_FROM := 2000.0
## Give up keeping bones off breakables this long after a break even if the
## body's centre never crossed the wall (it stopped in the hole).
const PASS_TIMEOUT := 0.5

## Fighters currently tracked (launched). Fed by GameEvents.fighter_launched.
var tracked: Array = []

class Chain:
	var count := 0

class Track:
	var fighter: Fighter
	var decided := {}            ## wall instance id -> {"outcome": StringName, "seen": float}
	var bowled := {}             ## victim instance id -> true
	var chain: Chain
	var hist_t := PackedFloat64Array()
	var hist_v := PackedVector3Array()
	var cooldown_until := 0.0    ## game time
	var suspend_until := 0.0     ## real time (hitstop)
	var ignoring := false
	var idle := 0.0
	var still := 0.0
	var peak_dv := Vector3.ZERO
	var peak_com := Vector3.ZERO
	var peak_time := 0.0
	var last_v := Vector3.ZERO
	## Walls broken this flight: wall id -> {"point": far face point, "into": unit, "until": game time}
	var passing := {}
	var flight_hits := 0         ## impacts that dealt damage this flight
	var flight_damage := 0.0
	var walls_broken := 0

var _tracks: Dictionary = {}       ## instance id -> Track
var _pending_chain: Dictionary = {} ## victim instance id -> Chain
## Victim instance id -> {"attacker": attacker instance id, "t": game time of the launch}.
var _launcher: Dictionary = {}
## Victim instance ids whose current flight is a throw (GameEvents.thrown):
## their brick / concrete impacts are finishers (spec: Dismemberment rule 2).
var _thrown: Dictionary = {}
var _time := 0.0
var _box := BoxShape3D.new()
var _query := PhysicsShapeQueryParameters3D.new()
var _gravity := Vector3(0, -9.8, 0)
var _want_ignore := false
var _need_collide := false

func _ready() -> void:
	process_physics_priority = 100
	_query.shape = _box
	_query.collide_with_areas = false
	_query.collide_with_bodies = true
	_gravity = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) \
		* ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3.DOWN)
	GameEvents.fighter_launched.connect(_on_fighter_launched)
	GameEvents.fighter_recovered.connect(_on_fighter_recovered)
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.thrown.connect(_on_thrown)

## Reset all tracking (round restart).
func reset() -> void:
	for id in _tracks.keys():
		_stop(_tracks[id])
	_tracks.clear()
	_pending_chain.clear()
	_launcher.clear()
	_thrown.clear()
	tracked.clear()

func is_tracking(fighter: Node3D) -> bool:
	return fighter != null and _tracks.has(fighter.get_instance_id())

## Bowling chain count of the fighter's current flight (0 if none).
func get_chain(fighter: Node3D) -> int:
	if fighter == null or not _tracks.has(fighter.get_instance_id()):
		return 0
	var tr: Track = _tracks[fighter.get_instance_id()]
	return tr.chain.count if tr.chain else 0

# --- Events -------------------------------------------------------------------

func _on_fighter_launched(fighter: Node3D, _velocity: Vector3) -> void:
	var f := fighter as Fighter
	if f == null:
		return
	var tr := _track_for(f)
	tr.decided.clear()
	tr.idle = 0.0
	tr.still = 0.0
	_reset_history(tr)
	var id := f.get_instance_id()
	if _pending_chain.has(id):
		tr.chain = _pending_chain[id]

func _on_fighter_recovered(fighter: Node3D) -> void:
	if fighter and _tracks.has(fighter.get_instance_id()):
		_stop(_tracks[fighter.get_instance_id()])

func _on_hit_landed(info: HitInfo) -> void:
	if info == null or info.victim == null or not is_instance_valid(info.victim):
		return
	var id := info.victim.get_instance_id()
	if info.attacker and is_instance_valid(info.attacker):
		_launcher[id] = {"attacker": info.attacker.get_instance_id(), "t": _time}
	if info.kind == &"throw":
		_thrown[id] = true
	else:
		_thrown.erase(id)
	if _tracks.has(id):
		var tr: Track = _tracks[id]
		tr.suspend_until = TimeDirector.now() + info.hitstop + 0.05
		_reset_history(tr)

func _on_thrown(grabber: Node3D, victim: Node3D, _velocity: Vector3) -> void:
	if victim == null or not is_instance_valid(victim):
		return
	var id := victim.get_instance_id()
	_thrown[id] = true
	if grabber and is_instance_valid(grabber):
		_launcher[id] = {"attacker": grabber.get_instance_id(), "t": _time}

func _track_for(f: Fighter) -> Track:
	var id := f.get_instance_id()
	if _tracks.has(id):
		return _tracks[id]
	var tr := Track.new()
	tr.fighter = f
	tr.chain = _pending_chain.get(id, Chain.new())
	_tracks[id] = tr
	if not tracked.has(f):
		tracked.append(f)
	return tr

func _stop(tr: Track) -> void:
	var f := tr.fighter
	if is_instance_valid(f):
		if tr.ignoring and f.ragdoll:
			f.ragdoll.set_ignore_breakables(false)
		tracked.erase(f)
		_tracks.erase(f.get_instance_id())
		_thrown.erase(f.get_instance_id())
		_launcher.erase(f.get_instance_id())
	else:
		for id in _tracks.keys():
			if _tracks[id] == tr:
				_tracks.erase(id)
				break
		tracked = tracked.filter(func(o: Variant) -> bool: return is_instance_valid(o))
	tr.ignoring = false

# --- Tick ---------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if delta <= 0.0:
		return
	_time += delta
	_scan_fighters()
	for id in _tracks.keys():
		var tr: Track = _tracks.get(id)
		if tr == null:
			continue
		if not _update(tr, delta):
			_stop(tr)

## Picks up launched bodies whose launch event we missed (stagger tipping over,
## a corpse sent flying).
func _scan_fighters() -> void:
	for n in get_tree().get_nodes_in_group(&"fighters"):
		var f := n as Fighter
		if f == null or f.ragdoll == null or _tracks.has(f.get_instance_id()):
			continue
		var st := f.get_state()
		if st == RagdollController.State.LAUNCHED:
			_track_for(f)
		elif st == RagdollController.State.DEAD and f.ragdoll.is_simulating() \
				and f.get_com_velocity().length() > 2.0:
			_track_for(f)

func _update(tr: Track, delta: float) -> bool:
	var f := tr.fighter
	if not is_instance_valid(f) or f.is_queued_for_deletion() or not f.is_inside_tree():
		return false
	var st := f.get_state()
	var flying := st == RagdollController.State.LAUNCHED or st == RagdollController.State.DEAD
	if not flying:
		tr.idle += delta
		if tr.ignoring and f.ragdoll:
			f.ragdoll.set_ignore_breakables(false)
			tr.ignoring = false
		return tr.idle <= STOP_GRACE
	tr.idle = 0.0
	var M := maxf(f.get_total_mass(), 1.0)
	var v := f.get_com_velocity()
	var com := f.get_center_of_mass()
	if st == RagdollController.State.DEAD:
		if v.length() < DEAD_SETTLE_SPEED:
			tr.still += delta
			if tr.still > DEAD_SETTLE_TIME:
				return false
		else:
			tr.still = 0.0
	var bounds: AABB
	if f.ragdoll:
		bounds = f.ragdoll.get_bounds()
	else:
		bounds = AABB(com - Vector3(0.3, 0.9, 0.3), Vector3(0.6, 1.8, 0.6))
	for wid in tr.decided.keys():
		if _time - float(tr.decided[wid]["seen"]) > DECISION_FORGET:
			tr.decided.erase(wid)
	_sweep(tr, f, M, v, com, bounds, delta)
	if not is_instance_valid(f):
		return false
	_detect_impact(tr, f, M, v, com, bounds)
	tr.last_v = v
	return true

## Set by _sweep when the resolver itself changed the body's velocity this tick.
var _vel_changed := false

# --- Sweep: walls and bodies ahead ---------------------------------------------

func _sweep(tr: Track, f: Fighter, M: float, v: Vector3, com: Vector3, bounds: AABB, delta: float) -> void:
	_want_ignore = false
	_need_collide = false
	_vel_changed = false
	var speed := v.length()
	# Keep bones off breakables while passing through a hole this body just
	# broke, until its centre has crossed the wall.
	for wid in tr.passing.keys():
		var pw: Dictionary = tr.passing[wid]
		if (com - (pw["point"] as Vector3)).dot(pw["into"]) > 0.05 or _time > float(pw["until"]):
			tr.passing.erase(wid)
		else:
			_want_ignore = true
	if speed > MIN_SWEEP_SPEED:
		var dir := v / speed
		var raw_half := bounds.size * 0.5
		var half := raw_half + Vector3.ONE * SWEEP_MARGIN
		var center := bounds.get_center()
		var ext := absf(half.x * dir.x) + absf(half.y * dir.y) + absf(half.z * dir.z)
		var look := 2.0 * ext + LOOKAHEAD_TICKS * speed * delta
		var decide_dist := maxf(DECIDE_TICKS * speed * delta, DECIDE_MIN_DIST)
		var start := AABB(center - half, half * 2.0)
		var sweep := start.merge(AABB(center + dir * look - half, half * 2.0))
		_box.size = sweep.size
		_query.transform = Transform3D(Basis(), sweep.get_center())
		# WORLD is included only for concrete Destructibles; the big static
		# bodies (group "world_static": floor, yard structure) are excluded so
		# their many shapes never crowd the result list.
		_query.collision_mask = Layers.DESTRUCTIBLE | Layers.CAPSULE | Layers.WORLD
		var excl: Array[RID] = [f.get_rid()]
		excl.append_array(_static_rids())
		_query.exclude = excl
		var space := f.get_world_3d().direct_space_state
		var hits := space.intersect_shape(_query, 128)  # one result per shape; holed panels have one per cell
		var seen := {}
		for h: Dictionary in hits:
			var col: Object = h.get("collider")
			if col == null or not is_instance_valid(col):
				continue
			var cid := col.get_instance_id()
			if seen.has(cid):
				continue
			seen[cid] = true
			if col is Destructible:
				var w := col as Destructible
				if not w.is_broken:
					_consider_wall(tr, f, w, M, v, com, center, half, raw_half, speed, look, decide_dist)
			elif col is Fighter and col != f:
				_consider_bowl(tr, f, col as Fighter, M, v, com, center, half, delta)
			if not is_instance_valid(f):
				return
	var ignore := _want_ignore and not _need_collide
	if ignore != tr.ignoring and f.ragdoll:
		f.ragdoll.set_ignore_breakables(ignore)
		tr.ignoring = ignore

var _static_cache: Array[RID] = []
var _static_frame := -1

func _static_rids() -> Array[RID]:
	var fr := Engine.get_physics_frames()
	if fr != _static_frame:
		_static_frame = fr
		_static_cache.clear()
		for n in get_tree().get_nodes_in_group(&"world_static"):
			if n is CollisionObject3D:
				_static_cache.append((n as CollisionObject3D).get_rid())
	return _static_cache

func _consider_wall(tr: Track, f: Fighter, w: Destructible, M: float, v: Vector3, com: Vector3,
		center: Vector3, half: Vector3, raw_half: Vector3, speed: float, look: float, decide_dist: float) -> void:
	var t_hit := time_to_contact_obb(center, half, v, w.global_transform, w.size * 0.5)
	if is_inf(t_hit) or t_hit * speed > look:
		return
	# The body's outline on the panel at contact; already open -> no decision.
	var footprint := footprint_on(w, center + v * t_hit, raw_half)
	if w.kind == &"panel" and w.footprint_open_fraction(footprint) >= OPEN_SKIP:
		return
	var dist := t_hit * speed
	var wid := w.get_instance_id()
	if tr.decided.has(wid):
		var dec: Dictionary = tr.decided[wid]
		dec["seen"] = _time
		if dec["outcome"] != &"break" and dist <= decide_dist * 2.0:
			_need_collide = true
		return
	var n := w.get_face_normal(com)
	var vin := -v.dot(n)
	if vin <= 0.05:
		return
	var energy := 0.5 * M * vin * vin
	if dist <= decide_dist:
		_decide(tr, f, w, energy, n, v, com, t_hit, footprint)
	elif energy >= w.get_crack_threshold():
		_want_ignore = true

## World AABB (centre `c`, half extents `h`) projected onto a panel's face:
## a Rect2 in panel-local XY.
static func footprint_on(w: Destructible, c: Vector3, h: Vector3) -> Rect2:
	var xf := w.global_transform
	var lc := xf.affine_inverse() * c
	var hx := _ext(xf.basis.x.normalized(), h)
	var hy := _ext(xf.basis.y.normalized(), h)
	return Rect2(lc.x - hx, lc.y - hy, hx * 2.0, hy * 2.0)

func _decide(tr: Track, f: Fighter, w: Destructible, energy: float, n: Vector3, v: Vector3,
		com: Vector3, t_hit: float, footprint: Rect2) -> void:
	var pos := _contact_point(com, v, t_hit, w, n)
	var crack_threshold := w.get_crack_threshold()
	var outcome := w.receive_impact(energy, pos, v, footprint)
	var wid := w.get_instance_id()
	tr.decided[wid] = {"outcome": outcome, "seen": _time}
	match outcome:
		&"break":
			if f.ragdoll:
				f.ragdoll.scale_velocity(sqrt(maxf(1.0 - w.absorption, 0.0)))
				_vel_changed = true
			_let_chunks_pass(f, w)
			TimeDirector.request_slowmo(Tuning.WALL_BREAK_SLOWMO.x, Tuning.WALL_BREAK_SLOWMO.y,
				TimeDirector.PRIO_WALL_BREAK)
			GameEvents.screen_shake.emit(clampf(0.35 + energy / 25000.0, 0.35, 0.8))
			# Keep bones off breakables until the centre has crossed the wall.
			_want_ignore = true
			if not w.is_broken:
				tr.passing[wid] = {"point": w.global_position - n * w.get_half_extent_along(n),
					"into": -n, "until": _time + PASS_TIMEOUT}
			tr.walls_broken += 1
			if tr.walls_broken >= 2:
				GameEvents.wall_chain.emit(f, tr.walls_broken)
		&"crack":
			_need_collide = true
			if f.ragdoll:
				var strength := clampf(energy / maxf(crack_threshold, 1.0), 1.0, 2.0)
				f.ragdoll.apply_limb_spin(v.normalized(), strength)
			_impact_feel(f, energy, WALL_HITSTOP)
		_:
			_need_collide = true
			if energy > Tuning.IMPACT_MIN_ENERGY:
				_impact_feel(f, energy, WALL_HITSTOP)
	wall_decided.emit(f, w, outcome, energy, pos)
	_reset_history(tr)
	tr.cooldown_until = _time + IMPACT_COOLDOWN
	_deal(f, energy, pos, n, w.surface, &"wall", null)

## Screen shake by energy plus a short local hitstop on the body.
func _impact_feel(f: Fighter, energy: float, hitstop: float) -> void:
	GameEvents.screen_shake.emit(clampf(energy / 15000.0, 0.08, 0.45))
	if hitstop > 0.0 and is_instance_valid(f):
		TimeDirector.hitstop([f], hitstop)

func _contact_point(com: Vector3, v: Vector3, t: float, w: Destructible, n: Vector3) -> Vector3:
	var p := com + v * t
	var face := w.global_position + n * w.get_half_extent_along(n)
	p -= n * (p - face).dot(n)
	var xf := w.global_transform
	var local := xf.affine_inverse() * p
	var h := w.size * 0.5
	local = local.clamp(-h, h)
	return xf * local

func _let_chunks_pass(f: Fighter, w: Destructible) -> void:
	if f.rig == null or w.last_chunks.is_empty():
		return
	var bones: Array = f.rig.get_physical_bones()
	if bones.is_empty():
		return
	var chunks: Array = w.last_chunks.duplicate()
	for c: RigidBody3D in chunks:
		for b: PhysicalBone3D in bones:
			if is_instance_valid(b):
				c.add_collision_exception_with(b)
	get_tree().create_timer(CHUNK_PASS_TIME, true, true, false).timeout.connect(func() -> void:
		for c: Variant in chunks:
			if not is_instance_valid(c):
				continue
			for b: Variant in bones:
				if is_instance_valid(b):
					(c as RigidBody3D).remove_collision_exception_with(b))

## Swept AABB (world-aligned half extents `half` at `center`, moving with `vel`)
## against an oriented box (transform `xf`, half extents `box_half`). Returns the
## time of first contact (0 if already overlapping) or INF if the ray misses.
static func time_to_contact_obb(center: Vector3, half: Vector3, vel: Vector3, xf: Transform3D,
		box_half: Vector3) -> float:
	var ax := xf.basis.x.normalized()
	var ay := xf.basis.y.normalized()
	var az := xf.basis.z.normalized()
	var d := center - xf.origin
	var c := Vector3(ax.dot(d), ay.dot(d), az.dot(d))
	var u := Vector3(ax.dot(vel), ay.dot(vel), az.dot(vel))
	var hl := Vector3(_ext(ax, half), _ext(ay, half), _ext(az, half))
	return _slab(c, u, box_half + hl)

static func time_to_contact_aabb(center: Vector3, half: Vector3, vel: Vector3, box_center: Vector3,
		box_half: Vector3) -> float:
	return _slab(center - box_center, vel, box_half + half)

static func _ext(axis: Vector3, half: Vector3) -> float:
	return absf(axis.x) * half.x + absf(axis.y) * half.y + absf(axis.z) * half.z

static func _slab(c: Vector3, u: Vector3, b: Vector3) -> float:
	var t_enter := -INF
	var t_exit := INF
	for i in 3:
		if absf(u[i]) < 1e-6:
			if absf(c[i]) > b[i]:
				return INF
		else:
			var t1 := (-b[i] - c[i]) / u[i]
			var t2 := (b[i] - c[i]) / u[i]
			if t1 > t2:
				var tmp := t1
				t1 = t2
				t2 = tmp
			t_enter = maxf(t_enter, t1)
			t_exit = minf(t_exit, t2)
	if t_enter > t_exit or t_exit < 0.0:
		return INF
	return maxf(t_enter, 0.0)

# --- Human bowling --------------------------------------------------------------

func _consider_bowl(tr: Track, f: Fighter, victim: Fighter, M: float, v: Vector3, com: Vector3,
		center: Vector3, half: Vector3, delta: float) -> void:
	# A flying body only ever bowls enemies: a launched player bowls enemies, an
	# enemy bowls other enemies, and nobody bowls the player.
	if victim.team != Fighter.TEAM_ENEMY or victim.is_down() or victim.is_dead():
		return
	var vid := victim.get_instance_id()
	if tr.bowled.has(vid) or tr.chain.count >= Tuning.BOWL_CHAIN_MAX:
		return
	var launcher: Dictionary = _launcher.get(f.get_instance_id(), {})
	if not launcher.is_empty() and launcher["attacker"] == vid and _time - float(launcher["t"]) < BOWL_ATTACKER_GRACE:
		return
	var cap := _capsule_box(victim)
	var v_rel := v - victim.velocity
	var rel_speed := v_rel.length()
	if rel_speed < MIN_SWEEP_SPEED:
		return
	var t_hit := time_to_contact_aabb(center, half, v_rel, cap.get_center(), cap.size * 0.5)
	if is_inf(t_hit) or t_hit * rel_speed > maxf(DECIDE_TICKS * rel_speed * delta, DECIDE_MIN_DIST):
		return
	var d := victim.get_center_of_mass() - com
	d.y = 0.0
	if d.length() < 0.05:
		d = Vector3(v_rel.x, 0.0, v_rel.z)
	if d.length() < 0.01:
		return
	d = d.normalized()
	var vin := v_rel.dot(d)
	if vin < MIN_SWEEP_SPEED:
		return  # overlapping but separating (e.g. thrown away from the grabber): no bowl
	var energy := 0.5 * M * vin * vin
	tr.bowled[vid] = true
	var pos := com + v * t_hit + d * minf(half.x, half.z)
	_bowl(tr, f, victim, energy, v, vin, pos, d)

func _bowl(tr: Track, f: Fighter, victim: Fighter, energy: float, v: Vector3, vin: float,
		pos: Vector3, d: Vector3) -> void:
	var chain := tr.chain
	chain.count += 1
	var victim_energy := 0.0
	if energy < Tuning.BOWL_FLINCH_BELOW:
		victim.flinch(d, &"Chest", clampf(energy / Tuning.BOWL_FLINCH_BELOW, 0.3, 1.0))
	elif energy < Tuning.BOWL_LAUNCH_ABOVE:
		victim.stagger(d, clampf(energy / Tuning.BOWL_LAUNCH_ABOVE, 0.4, 1.0))
		victim_energy = 0.5 * victim.get_total_mass() * pow(0.25 * vin, 2.0)
	else:
		var lv := v * Tuning.BOWL_SPEED_SHARE
		var horiz := Vector2(lv.x, lv.z).length()
		lv.y = maxf(lv.y, BOWL_LIFT * horiz)
		var vid := victim.get_instance_id()
		_pending_chain[vid] = chain
		victim.launch(lv, pos, &"Chest")
		_pending_chain.erase(vid)
		if is_instance_valid(victim):
			var vt := _track_for(victim)
			vt.chain = chain
			vt.bowled[f.get_instance_id()] = true
		victim_energy = 0.5 * victim.get_total_mass() * pow(Tuning.BOWL_SPEED_SHARE * vin, 2.0)
	GameEvents.body_bowled.emit(f, victim, energy, chain.count)
	if energy >= Tuning.BOWL_LAUNCH_ABOVE:
		GameEvents.screen_shake.emit(clampf(energy / 20000.0, 0.1, 0.4))
	if is_instance_valid(victim) and victim_energy > 0.0:
		_deal(victim, victim_energy, pos, -d, &"body", &"bowl", f)

func _capsule_box(f: Fighter) -> AABB:
	for c in f.get_children():
		var cs := c as CollisionShape3D
		if cs and cs.shape is CapsuleShape3D:
			var cap := cs.shape as CapsuleShape3D
			var p := cs.global_position
			return AABB(p - Vector3(cap.radius, cap.height * 0.5, cap.radius),
				Vector3(cap.radius * 2.0, cap.height, cap.radius * 2.0))
	var g := f.get_ground_position()
	return AABB(g + Vector3(-0.35, 0.0, -0.35), Vector3(0.7, 1.8, 0.7))

# --- Impact detection from COM deceleration ------------------------------------

func _reset_history(tr: Track) -> void:
	tr.hist_t.clear()
	tr.hist_v.clear()
	tr.peak_dv = Vector3.ZERO

func _detect_impact(tr: Track, f: Fighter, M: float, v: Vector3, com: Vector3, bounds: AABB) -> void:
	if _vel_changed:
		_reset_history(tr)
		return
	if TimeDirector.now() < tr.suspend_until or (f.has_method(&"is_frozen") and f.call(&"is_frozen")):
		_reset_history(tr)
		return
	# Hitstop on a ragdoll zeroes every bone velocity: not an impact.
	if v.length_squared() < 1e-6 and tr.last_v.length_squared() > 1.0:
		_reset_history(tr)
		return
	tr.hist_t.append(_time)
	tr.hist_v.append(v)
	while tr.hist_t.size() > 2 and _time - tr.hist_t[1] >= IMPACT_WINDOW:
		tr.hist_t.remove_at(0)
		tr.hist_v.remove_at(0)
	if _time < tr.cooldown_until or tr.hist_t.size() < 2:
		return
	var dt := _time - tr.hist_t[0]
	var v0 := tr.hist_v[0]
	var dv := v - v0 - _gravity * dt
	var threshold := sqrt(2.0 * Tuning.IMPACT_MIN_ENERGY / M) * 0.85
	var in_impact := dv.length() >= threshold and dv.dot(v0) < 0.0
	if in_impact:
		if dv.length_squared() > tr.peak_dv.length_squared():
			tr.peak_dv = dv
			tr.peak_com = com
			tr.peak_time = _time
			return
		if dv.length() > tr.peak_dv.length() * 0.8 and _time - tr.peak_time < IMPACT_WINDOW:
			return
	if tr.peak_dv != Vector3.ZERO:
		_commit_impact(tr, f, M, bounds)

func _commit_impact(tr: Track, f: Fighter, M: float, bounds: AABB) -> void:
	var dv := tr.peak_dv
	var com := tr.peak_com
	tr.peak_dv = Vector3.ZERO
	var dvn := dv.normalized()
	var reach := bounds.size.length() * 0.5 + 0.4
	var n := dvn
	var pos := com - dvn * 0.5
	var surface := &"concrete"
	var space := f.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(com, com - dvn * reach,
		Layers.WORLD | Layers.DESTRUCTIBLE | Layers.CAPSULE | Layers.RAGDOLL | Layers.DEBRIS,
		_own_rids(f))
	var hit := space.intersect_ray(q)
	var collider: Object = null
	if not hit.is_empty():
		n = hit["normal"]
		pos = hit["position"]
		collider = hit["collider"]
		surface = _surface_of(collider)
	else:
		surface = _guess_surface(f, pos)
	var dvn_mag := absf(dv.dot(n))
	if hit.is_empty():
		dvn_mag = dv.length()
	var energy := 0.5 * M * dvn_mag * dvn_mag
	if energy <= Tuning.IMPACT_MIN_ENERGY:
		return
	tr.cooldown_until = _time + IMPACT_COOLDOWN
	_reset_history(tr)
	var move := &"floor" if n.y > 0.7 else (&"body" if surface == &"body" else &"wall")
	_deal(f, energy, pos, n, surface, move, null)
	if energy >= SHAKE_IMPACT_FROM:
		GameEvents.screen_shake.emit(clampf(energy / 15000.0, 0.1, 0.5))
	if surface == &"concrete" and n.y < 0.7 and energy >= CONCRETE_HITSTOP_FROM:
		TimeDirector.hitstop([f], CONCRETE_HITSTOP)
	if surface == &"concrete" and n.y < 0.7:
		var from: float = Tuning.SURFACES[&"concrete"].get("decal_from", INF)
		if energy >= from:
			Destructible.spawn_crack_decal(f, pos, n, energy)
		if collider is Pillar:
			(collider as Pillar).chip(pos, n, energy)

func _own_rids(f: Fighter) -> Array[RID]:
	var out: Array[RID] = [f.get_rid()]
	if f.rig:
		for b in f.rig.get_physical_bones():
			if is_instance_valid(b):
				out.append(b.get_rid())
	return out

func _surface_of(col: Object) -> StringName:
	if col == null:
		return &"concrete"
	if col is Destructible:
		return (col as Destructible).surface
	if col is PhysicalBone3D or col is Fighter:
		return &"body"
	if col is Node and (col as Node).has_meta(&"surface"):
		return (col as Node).get_meta(&"surface")
	if col is RigidBody3D and (col as Node).is_in_group(&"debris"):
		return &"debris"
	return &"concrete"

func _guess_surface(f: Fighter, pos: Vector3) -> StringName:
	for n in get_tree().get_nodes_in_group(&"fighters"):
		var o := n as Fighter
		if o and o != f and o.get_center_of_mass().distance_to(pos) < 1.2:
			return &"body"
	return &"concrete"

# --- Damage --------------------------------------------------------------------

func _deal(f: Fighter, energy: float, pos: Vector3, n: Vector3, surface: StringName,
		move_id: StringName, attacker: Fighter) -> void:
	if energy > Tuning.IMPACT_MIN_ENERGY:
		GameEvents.body_impact.emit(f, pos, n, energy, surface)
	var dmg := Tuning.impact_damage(energy)
	if dmg <= 0.0:
		return
	# Per-flight rules: 2nd+ impact x IMPACT_REPEAT_MULT, flight total capped.
	var tr: Track = _tracks.get(f.get_instance_id())
	if tr != null:
		if tr.flight_hits >= 1:
			dmg *= Tuning.IMPACT_REPEAT_MULT
		dmg = minf(dmg, maxf(Tuning.IMPACT_FLIGHT_CAP - tr.flight_damage, 0.0))
		if dmg <= 0.0:
			return
		tr.flight_hits += 1
		tr.flight_damage += dmg
	var info := HitInfo.new()
	info.attacker = attacker
	info.victim = f
	info.move_id = move_id
	info.kind = &"impact"
	info.damage = dmg
	info.reaction = HitInfo.Reaction.NONE
	info.hit_position = pos
	info.hit_direction = -n
	info.hit_bone = _nearest_bone(f, pos)
	info.energy = energy
	info.result = HitInfo.Result.HIT
	# A throw into brick or concrete is a finisher (may dismember on a kill).
	if attacker == null and _thrown.has(f.get_instance_id()) and (surface == &"brick" or surface == &"concrete"):
		info.is_finisher = true
	f.apply_damage(dmg, &"impact", info)
	# HUD wording (agent E): floor slams report &"floor", body / bowling hits &"body".
	var shown := surface
	if move_id == &"floor":
		shown = &"floor"
	elif move_id == &"body" or move_id == &"bowl" or surface == &"body":
		shown = &"body"
	GameEvents.impact_damaged.emit(f, dmg, energy, shown, pos)
	impact_dealt.emit(f, energy, dmg, surface, pos)
	impact_info.emit(info)

func _nearest_bone(f: Fighter, pos: Vector3) -> StringName:
	var best := Bones.CHEST
	if f.rig == null:
		return best
	var best_d := INF
	for b in f.rig.get_physical_bones():
		if not is_instance_valid(b):
			continue
		var d := b.global_position.distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = b.bone_name
	return best
