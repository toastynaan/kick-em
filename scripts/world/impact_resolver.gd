extends Node
## Autoload "ImpactResolver" (Feel Reference: Launch speed and walls; Thrown
## bodies are projectiles). Every physics tick, for each FLYING body (launched,
## thrown, flung, or a dead body moving fast): sweep the body's bounds along its
## centre-of-mass velocity (extent + 2 ticks of travel) against breakables (the
## Round 6 breakable contract: WorldTags.breakable_of: Destructible panels and
## props, Pillars, K's clutter) and standing enemy capsules; decide
## break / crack / bounce BEFORE contact; deal wall damage; bowl enemies.
## OWNER: agent D (world). CONTRACT STUB: keep every public signature.
##
## Walls (F3):
## 1. Query the volume the body's AABB sweeps over the next (2 x extent along v
##    + 2 ticks of travel). Every intact breakable in it gets an exact swept
##    AABB-vs-box time to contact. At 120 Hz an 18 m/s body moves 0.15 m a tick,
##    so 0.25 m panels never tunnel.
## 2. E = Power.wall_energy(M, v, n): 1/2 M v^2 with the speed straight into the
##    face. While an undecided breakable ahead has E at or above its crack
##    threshold (Tuning.CRACK_FRACTION of its break energy), bones ignore
##    breakables (ragdoll.set_ignore_breakables).
## 3. When contact is within DECIDE_TICKS ticks, the breakable decides once for
##    this pass (receive_impact): break (fracture now, bone velocities x
##    sqrt(1 - absorption), chunks let the body through, the flying body alone
##    freezes Tuning.WALL_BREAK_FREEZE at the moment its front reaches the face,
##    GameEvents.wall_broken_by for walls), or crack / bounce (collision back on before
##    contact so the body bounces physically). A crack lowers the break energy by
##    half the hit's energy, so concrete is a two-hit payoff.
## Wall damage to the flying body: Tuning.WALL_DAMAGE (crack +5, drywall / wood
## +10, brick +20, concrete +30). Round 6: anything else breakable (furniture,
## props, door frames, clutter) is not a wall: breaking it costs the body
## Tuning.FURNITURE_BODY_DAMAGE and sqrt(1 - absorption) of its speed, with no
## freeze and no Focus, and one flight can break several things. Floor landings and body-on-body contacts deal
## none (bodies hit by a flying body are bowled instead). Static concrete (the
## arena boundary, which never breaks) cracks from the concrete crack energy:
## found from a sudden change of the centre-of-mass velocity (gravity removed),
## E from the velocity just before it along the contact normal.
## Every flying body is capped at Tuning.LAUNCH_SPEED_MAX (throws included).
##
## Bowling (F9): a flying body whose pelvis moves across the floor faster than
## Tuning.PROJECTILE_MIN_SPEED hits standing enemies by that speed (Power.bowl_tier:
## stagger / knockdown / launch, Tuning.BOWL_DAMAGE), as a preset-tier HitInfo
## (kind &"bowl", attacker = whoever launched or threw the flyer) through
## victim.take_hit(); it loses Tuning.BOWL_SPEED_LOSS of its speed per hit and
## keeps tumbling (16 m/s: launch -> knockdown at 9.6 -> stagger at 5.8): it
## passes through each body it bowled, and the victims scatter off its line.
## Dead bodies (Layers.DEAD_BODY) are flyers like any other: a thrown corpse
## breaks walls and bowls. Settled corpses are skipped (perf).

## Debug / test hooks (not part of the cross-module contract).
signal wall_decided(fighter: Node3D, wall: Node3D, outcome: StringName, energy: float, position: Vector3)
## Every wall / floor impact the resolver judged (damage may be 0).
signal impact_dealt(fighter: Node3D, energy: float, damage: float, surface: StringName, position: Vector3)
signal impact_info(info: HitInfo)
## A bowl hit was sent: speed = the flyer's pelvis speed, tier = HitInfo.Tier.
signal bowl_dealt(flyer: Node3D, victim: Node3D, speed: float, tier: int, info: HitInfo)

# Local constants (candidates for Tuning).
const LOOKAHEAD_TICKS := 2.0     ## ticks of travel added to the sweep
const DECIDE_TICKS := 2.5        ## decide when contact is this many ticks away
const DECIDE_MIN_DIST := 0.1     ## m; never decide later than this gap
const SWEEP_MARGIN := 0.08       ## m added around the body AABB
const MIN_SWEEP_SPEED := 0.5     ## m/s; slower bodies are not swept
const IMPACT_WINDOW := 0.1       ## s of COM velocity history for impact detection
const IMPACT_COOLDOWN := 0.25    ## s; one impact counts once
const DECISION_FORGET := 0.3     ## s a panel must be out of the sweep before it may decide again
## s chunks ignore the body that broke them. Long enough that the body is past
## the chunks flying with it and the ones already on the floor ahead of it.
const CHUNK_PASS_TIME := 1.5
const STOP_GRACE := 0.15         ## s out of a flying state before tracking stops
const DEAD_SETTLE_SPEED := 0.25
const DEAD_SETTLE_TIME := 1.0
## A dead body starts being tracked (thrown, kicked, knocked) above this COM speed.
const DEAD_TRACK_SPEED := 2.0
## s (game time) after a launch during which the body never bowls the fighter
## that launched it (a thrown body starts ~0.7 m from its grabber).
const BOWL_ATTACKER_GRACE := 0.25
## A bowled knockdown drops in place: this much push along the flyer (m/s).
const BOWL_KNOCKDOWN_PUSH := 1.5
## After a bowl hit the flyer passes through its victim (collision exceptions,
## both ways, flyer bones x victim capsule and bones): its 40% loss is the whole
## cost of the hit, so the chain runs 16 -> 9.6 -> 5.8 as the doc says, instead of
## the flyer ploughing into the slower victim's back. Ends once the flyer's
## centre is GHOST_CLEAR m past the victim's along the flight, or after GHOST_TIME s.
const GHOST_TIME := 0.6
const GHOST_CLEAR := 0.9
## A bowled victim leaves this many degrees off the flyer's line (min with no
## sideways offset, max at BOWL_DEFLECT_OFFSET m): the bodies scatter like pins
## and leave the lane, so the thrown body reaches the next enemy itself, as the
## doc's chain says. A launched victim starts ~1.2 m ahead of the flyer's centre
## and tumbles with ~1.8 m bounds, so it must leave wide (45-60 deg: ~4 m/s
## along the line, ~5 m/s across): at 25 deg it still reached the next enemy
## 2.5 m on first. Knockdowns and staggers barely travel: 25-40 deg.
const BOWL_DEFLECT := Vector2(25.0, 40.0)
const BOWL_DEFLECT_LAUNCH := Vector2(45.0, 60.0)
const BOWL_DEFLECT_OFFSET := 0.5
## Skip a wall decision when at least this fraction of the body's outline on
## the panel is already open (it flies through an existing hole).
const OPEN_SKIP := 0.85
## Real seconds of local hitstop on a body that cracks or bounces off a wall.
const WALL_HITSTOP := 0.06
## Bones keep ignoring breakables after a break until the body's centre is
## PASS_BEYOND m past the wall (trailing limbs clear the rim), or PASS_TIMEOUT s
## have passed (it stopped in the hole).
const PASS_BEYOND := 0.5
const PASS_TIMEOUT := 0.8
## Limb-grab swings (upgrade 2): wall damage one swing may deal to the swung body.
const SWING_DAMAGE_CAP := 120.0
## The wall-break freeze waits for the body's front to reach the face, at most this long (s).
const BREAK_FREEZE_WAIT := 0.06
## nearest_wall_dir: horizontal rays cast around the point, and the prop retries per ray.
const WALL_DIR_RAYS := 16
const WALL_DIR_RETRIES := 3

## Fighters currently tracked (flying). Fed by GameEvents and a scan.
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
	var peak_v0 := Vector3.ZERO  ## COM velocity just before the impact being measured
	var peak_com := Vector3.ZERO
	var peak_time := 0.0
	var last_v := Vector3.ZERO
	## Walls broken this flight: wall id -> {"point": far face point, "into": unit, "until": game time}
	var passing := {}
	var walls_broken := 0
	## Breakables this flight broke or holed: id -> true. Each counts once per
	## flight (one damage, one chain step): never judged again by this flight.
	var broke := {}
	## Pending wall-break freeze: {"point": face point, "into": unit, "until": game time}.
	var freeze_at := {}
	## Bodies this flight bowled and now passes through: {"mine", "theirs", "dir", "victim", "until"}.
	var ghosts: Array = []
	## Limb-grab swing (track_swing): the holder is never bowled, joint pulls are not impacts.
	var swinging := false
	var swing_holder: Node3D = null
	var swing_damage := 0.0

var _tracks: Dictionary = {}       ## instance id -> Track
var _pending_chain: Dictionary = {} ## victim instance id -> Chain
## Victim instance id -> {"attacker": instance id, "node": the launcher, "t": game time}.
## Fed by hit_landed (the striker), thrown and limb_grab_released (the grabber);
## a body launched by bowling inherits the flyer's launcher (bowling credit).
var _launcher: Dictionary = {}
## Victim instance ids whose current flight is a throw (GameEvents.thrown, a
## throw hit or a limb-grab fling): their brick / concrete impacts are
## finishers and their impacts name the thrower as attacker.
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
	GameEvents.limb_grab_released.connect(_on_limb_grab_released)

## Upgrade 2 contract. A body swung by a limb grab is swept like a flying body:
## walls it hits decide break / crack / bounce with the same energy rules and
## fighters it reaches are bowled (never `holder`), until untrack_swing(). The
## grip's own pull never counts as an impact.
func track_swing(fighter: Node3D, holder: Node3D) -> void:
	var f := fighter as Fighter
	if f == null or not is_instance_valid(f):
		return
	var track := _track_for(f)
	track.swinging = true
	track.swing_holder = holder
	track.swing_damage = 0.0
	track.decided.clear()
	track.broke.clear()
	track.bowled.clear()
	if holder and is_instance_valid(holder):
		track.bowled[holder.get_instance_id()] = true
	track.idle = 0.0
	track.still = 0.0
	_reset_history(track)

## End a swing (release or break free). A released body that is LAUNCHED keeps
## being tracked as a normal flight; otherwise tracking ends shortly after.
func untrack_swing(fighter: Node3D) -> void:
	if fighter == null or not _tracks.has(fighter.get_instance_id()):
		return
	var track: Track = _tracks[fighter.get_instance_id()]
	track.swinging = false
	track.swing_holder = null
	track.idle = 0.0
	_reset_history(track)

func is_swinging(fighter: Node3D) -> bool:
	return fighter != null and _tracks.has(fighter.get_instance_id()) \
		and (_tracks[fighter.get_instance_id()] as Track).swinging

## Unit XZ direction from `from` to the nearest wall or pillar face within
## max_dist (ZERO if none). Juggles flatten their launch toward it.
## WALL_DIR_RAYS horizontal rays at body height against WORLD and breakable
## walls (props are skipped, holes let the ray through); the answer is the
## inward normal of the face the closest ray hit.
func nearest_wall_dir(from: Vector3, max_dist := 8.0) -> Vector3:
	if not is_inside_tree():
		return Vector3.ZERO
	var world: World3D = get_viewport().find_world_3d()
	if world == null:
		return Vector3.ZERO
	var space := world.direct_space_state
	var o := Vector3(from.x, clampf(from.y, 0.6, 2.2), from.z)
	var best_d := max_dist
	var best := Vector3.ZERO
	for i in WALL_DIR_RAYS:
		var ang := TAU * float(i) / float(WALL_DIR_RAYS)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var hit := _wall_ray(space, o, dir, max_dist)
		if hit.is_empty():
			continue
		var n: Vector3 = hit["normal"]
		# A panel or pillar answers with its own face (a ray grazing a hole's
		# rim or a cell edge returns an edge normal).
		var col: Object = hit["collider"]
		var wb := WorldTags.breakable_of(col)
		if wb != null and wb.has_method(&"get_face_normal"):
			n = (wb as Node3D).call(&"get_face_normal", o)
		n.y = 0.0
		var p: Vector3 = hit["position"]
		# Rank by the real distance to the hit (a pillar corner is farther than
		# its face plane); answer with the face's inward normal.
		var d := o.distance_to(p)
		var into := -n.normalized() if n.length() > 0.5 else dir
		if d < best_d:
			best_d = d
			best = into
	return best

var _ray := PhysicsRayQueryParameters3D.new()

func _wall_ray(space: PhysicsDirectSpaceState3D, o: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	_ray.from = o
	_ray.to = o + dir * max_dist
	_ray.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
	_ray.collide_with_areas = false
	var excl: Array[RID] = []
	for _k in WALL_DIR_RETRIES + 1:
		_ray.exclude = excl
		var hit := space.intersect_ray(_ray)
		if hit.is_empty():
			return hit
		var obj: Object = hit["collider"]
		# Props, furniture and clutter (breakable or loose) are not walls; loose
		# props sit on DESTRUCTIBLE too so strikes reach them.
		var b := WorldTags.breakable_of(obj)
		if (b != null and not is_wall(b)) or obj is RigidBody3D:
			excl.append((obj as CollisionObject3D).get_rid())
			continue
		return hit
	return {}

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
	var track: Track = _tracks[fighter.get_instance_id()]
	return track.chain.count if track.chain else 0

## Walls this fighter's current flight broke (0 if not flying).
func get_walls_broken(fighter: Node3D) -> int:
	if fighter == null or not _tracks.has(fighter.get_instance_id()):
		return 0
	return (_tracks[fighter.get_instance_id()] as Track).walls_broken

# --- Events -------------------------------------------------------------------

func _on_fighter_launched(fighter: Node3D, _velocity: Vector3) -> void:
	var f := fighter as Fighter
	if f == null:
		return
	var track := _track_for(f)
	track.decided.clear()
	track.broke.clear()
	track.idle = 0.0
	track.still = 0.0
	_reset_history(track)
	var id := f.get_instance_id()
	if _pending_chain.has(id):
		track.chain = _pending_chain[id]

func _on_fighter_recovered(fighter: Node3D) -> void:
	if fighter and _tracks.has(fighter.get_instance_id()):
		_stop(_tracks[fighter.get_instance_id()])

func _on_hit_landed(info: HitInfo) -> void:
	if info == null or info.victim == null or not is_instance_valid(info.victim):
		return
	var id := info.victim.get_instance_id()
	if info.attacker and is_instance_valid(info.attacker):
		_set_launcher(id, info.attacker)
	if info.kind == &"throw":
		_thrown[id] = true
	else:
		_thrown.erase(id)
	if _tracks.has(id):
		var track: Track = _tracks[id]
		track.suspend_until = TimeDirector.now() + info.hitstop + 0.05
		_reset_history(track)

## A body leaves a grabber's hands (G / B emit thrown): track it now, alive or
## dead, so the very first tick of the throw is swept.
func _on_thrown(grabber: Node3D, victim: Node3D, _velocity: Vector3) -> void:
	if victim == null or not is_instance_valid(victim):
		return
	var id := victim.get_instance_id()
	_thrown[id] = true
	if grabber and is_instance_valid(grabber):
		_set_launcher(id, grabber)
	var f := victim as Fighter
	if f != null and f.is_inside_tree():
		var track := _track_for(f)
		_new_flight(track, grabber)

## A limb-grab fling counts like a throw (agent G): the grabber launched this
## flight, which starts fresh (bowling chain). A break-free (no fling velocity)
## throws nothing.
func _on_limb_grab_released(grabber: Node3D, victim: Node3D, velocity: Vector3) -> void:
	if victim == null or not is_instance_valid(victim) or velocity.length() < MIN_SWEEP_SPEED:
		return
	var id := victim.get_instance_id()
	_thrown[id] = true
	if grabber and is_instance_valid(grabber):
		_set_launcher(id, grabber)
	if _tracks.has(id):
		_new_flight(_tracks[id], grabber)

## A throw or fling starts a new flight: fresh chain, walls and bowled set; the
## thrower is never bowled by it.
func _new_flight(track: Track, thrower: Node3D) -> void:
	track.walls_broken = 0
	track.chain = Chain.new()
	track.bowled.clear()
	if thrower and is_instance_valid(thrower):
		track.bowled[thrower.get_instance_id()] = true
	track.decided.clear()
	track.broke.clear()
	track.idle = 0.0
	track.still = 0.0
	_reset_history(track)

func _set_launcher(victim_id: int, who: Node3D) -> void:
	_launcher[victim_id] = {"attacker": who.get_instance_id(), "node": who, "t": _time}

## True while `f` is held by a grabber (Carry / RagdollController held state).
static func is_held_body(f: Fighter) -> bool:
	if f.carry != null and f.carry.is_held():
		return true
	return f.ragdoll != null and f.ragdoll.is_held()

## Who launched (struck, threw or flung) this fighter's current flight, or null.
func get_launcher(fighter: Node3D) -> Node3D:
	if fighter == null:
		return null
	var l: Dictionary = _launcher.get(fighter.get_instance_id(), {})
	var who: Variant = l.get("node")
	return who as Node3D if who != null and is_instance_valid(who) else null

## True while the fighter's flight is a throw (thrown or flung by a limb grab).
func is_thrown_flight(fighter: Node3D) -> bool:
	return fighter != null and _thrown.has(fighter.get_instance_id())

func _track_for(f: Fighter) -> Track:
	var id := f.get_instance_id()
	if _tracks.has(id):
		return _tracks[id]
	var track := Track.new()
	track.fighter = f
	track.chain = _pending_chain.get(id, Chain.new())
	_tracks[id] = track
	if not tracked.has(f):
		tracked.append(f)
	return track

func _stop(track: Track) -> void:
	for g: Dictionary in track.ghosts:
		_unghost(g)
	track.ghosts.clear()
	var f := track.fighter
	if is_instance_valid(f):
		if track.ignoring and f.ragdoll:
			f.ragdoll.set_ignore_breakables(false)
		tracked.erase(f)
		_tracks.erase(f.get_instance_id())
		_thrown.erase(f.get_instance_id())
		_launcher.erase(f.get_instance_id())
	else:
		for id in _tracks.keys():
			if _tracks[id] == track:
				_tracks.erase(id)
				break
		tracked = tracked.filter(func(o: Variant) -> bool: return is_instance_valid(o))
	track.ignoring = false

# --- Tick ---------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if delta <= 0.0:
		return
	_time += delta
	_scan_fighters()
	for id in _tracks.keys():
		var track: Track = _tracks.get(id)
		if track == null:
			continue
		if not _update(track, delta):
			_stop(track)

## Picks up flying bodies whose launch event we missed (a corpse sent flying,
## a thrown dead body). Settled corpses (frozen, RagdollController.is_settled)
## are skipped so 20 bodies on the floor cost nothing; grabbing, throwing or
## hitting one wakes it and the scan sees it again.
func _scan_fighters() -> void:
	for n in get_tree().get_nodes_in_group(&"fighters"):
		var f := n as Fighter
		if f == null or f.ragdoll == null or _tracks.has(f.get_instance_id()) or is_held_body(f):
			continue
		var st := f.get_state()
		if st == RagdollController.State.LAUNCHED:
			_track_for(f)
		elif st == RagdollController.State.DEAD and f.ragdoll.is_simulating():
			if f.ragdoll.has_method(&"is_settled") and f.ragdoll.call(&"is_settled"):
				continue
			if f.get_com_velocity().length() > DEAD_TRACK_SPEED:
				_track_for(f)

func _update(track: Track, delta: float) -> bool:
	var f := track.fighter
	if not is_instance_valid(f) or f.is_queued_for_deletion() or not f.is_inside_tree():
		return false
	var st := f.get_state()
	# A body in someone's hands (Carry) is not a projectile until it is thrown
	# (GameEvents.thrown starts a fresh flight).
	var flying := track.swinging or (not is_held_body(f) \
		and (st == RagdollController.State.LAUNCHED or st == RagdollController.State.DEAD))
	if not flying:
		track.idle += delta
		if track.ignoring and f.ragdoll:
			f.ragdoll.set_ignore_breakables(false)
			track.ignoring = false
		return track.idle <= STOP_GRACE
	track.idle = 0.0
	var M := maxf(f.get_total_mass(), 1.0)
	var v := f.get_com_velocity()
	var com := f.get_center_of_mass()
	if st == RagdollController.State.DEAD and not track.swinging:
		if v.length() < DEAD_SETTLE_SPEED:
			track.still += delta
			if track.still > DEAD_SETTLE_TIME:
				return false
		else:
			track.still = 0.0
	# Every flying body is capped (Feel Reference: Speed and tunnelling).
	var speed := v.length()
	if speed > Tuning.LAUNCH_SPEED_MAX + 0.05 and f.ragdoll and not f.is_frozen():
		var k := Tuning.LAUNCH_SPEED_MAX / speed
		f.ragdoll.scale_velocity(k)
		v *= k
		_reset_history(track)
	var bounds: AABB
	if f.ragdoll:
		bounds = f.ragdoll.get_bounds()
	else:
		bounds = AABB(com - Vector3(0.3, 0.9, 0.3), Vector3(0.6, 1.8, 0.6))
	for wid in track.decided.keys():
		if _time - float(track.decided[wid]["seen"]) > DECISION_FORGET:
			track.decided.erase(wid)
	_update_ghosts(track, com)
	_sweep(track, f, M, v, com, bounds, delta)
	if not is_instance_valid(f):
		return false
	_check_break_freeze(track, f, bounds)
	_detect_impact(track, f, M, v, com, bounds)
	track.last_v = v
	return true

## Set by _sweep when the resolver itself changed the body's velocity this tick.
var _vel_changed := false

# --- Sweep: walls and bodies ahead ---------------------------------------------

func _sweep(track: Track, f: Fighter, M: float, v: Vector3, com: Vector3, bounds: AABB, delta: float) -> void:
	_want_ignore = false
	_need_collide = false
	_vel_changed = false
	var speed := v.length()
	# Keep bones off breakables while passing through a hole this body just
	# broke, until its centre has crossed the wall.
	for wid in track.passing.keys():
		var pw: Dictionary = track.passing[wid]
		if (com - (pw["point"] as Vector3)).dot(pw["into"]) > PASS_BEYOND or _time > float(pw["until"]):
			track.passing.erase(wid)
		else:
			_want_ignore = true
	if speed > MIN_SWEEP_SPEED and not f.is_frozen():
		var dir := v / speed
		var raw_half := bounds.size * 0.5
		var half := raw_half + Vector3.ONE * SWEEP_MARGIN
		var center := bounds.get_center()
		var ext := absf(half.x * dir.x) + absf(half.y * dir.y) + absf(half.z * dir.z)
		var look := 2.0 * ext + LOOKAHEAD_TICKS * speed * delta
		var decide_dist := maxf(DECIDE_TICKS * speed * delta, DECIDE_MIN_DIST)
		var start := AABB(center - half, half * 2.0)
		var sweep := start.merge(AABB(center + dir * look - half, half * 2.0))
		# Frozen rubble ahead turns dynamic again, so the body knocks it about.
		DebrisManager.wake_in_box(sweep.grow(0.2))
		_box.size = sweep.size
		_query.transform = Transform3D(Basis(), sweep.get_center())
		# WORLD is included for Pillars and unbreakable Destructibles; the big
		# static bodies (group "world_static": floor, yard structure) are
		# excluded so their many shapes never crowd the result list.
		_query.collision_mask = Layers.DESTRUCTIBLE | Layers.CAPSULE | Layers.WORLD
		var excl: Array[RID] = [f.get_rid()]
		excl.append_array(_static_rids())
		_query.exclude = excl
		var space := f.get_world_3d().direct_space_state
		var hits := space.intersect_shape(_query, 128)  # one result per shape; holed panels have one per cell
		var seen := {}
		var pelvis_speed := -1.0
		for h: Dictionary in hits:
			var col: Object = h.get("collider")
			if col == null or not is_instance_valid(col):
				continue
			var breakable := WorldTags.breakable_of(col) if not (col is Fighter) else null
			var cid := breakable.get_instance_id() if breakable != null else col.get_instance_id()
			if seen.has(cid):
				continue
			seen[cid] = true
			if breakable != null and breakable is Node3D:
				var w := breakable as Node3D
				if not w.get(&"is_broken"):
					_consider_wall(track, f, w, M, v, com, center, half, raw_half, speed, look, decide_dist)
			elif col is Fighter and col != f:
				if pelvis_speed < 0.0:
					pelvis_speed = _pelvis_speed(f, v)
				if pelvis_speed >= Tuning.PROJECTILE_MIN_SPEED:
					_consider_bowl(track, f, col as Fighter, v, com, center, half, delta, pelvis_speed)
			if not is_instance_valid(f):
				return
	var ignore := _want_ignore and not _need_collide
	if ignore != track.ignoring and f.ragdoll:
		f.ragdoll.set_ignore_breakables(ignore)
		track.ignoring = ignore

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

## The breakable's collision box: transform and half size.
static func _box_xf(w: Node3D) -> Transform3D:
	return box_of(w)[0]

static func _box_half(w: Node3D) -> Vector3:
	return box_of(w)[1]

## A breakable's box [Transform3D, half size]: get_box_transform() and `size`
## when it has them (Destructible, Pillar), else the box of its own collision
## shapes in its own frame (computed once, cached in meta "_ir_box").
static func box_of(w: Node3D) -> Array:
	var sz: Variant = w.get(&"size")
	if w.has_method(&"get_box_transform") and sz is Vector3:
		return [w.call(&"get_box_transform"), (sz as Vector3) * 0.5]
	var local: AABB
	if w.has_meta(&"_ir_box"):
		local = w.get_meta(&"_ir_box")
	else:
		local = _shapes_aabb(w)
		w.set_meta(&"_ir_box", local)
	var xf := w.global_transform.orthonormalized()
	return [xf * Transform3D(Basis(), local.get_center()), local.size * 0.5]

## The AABB of every collision shape under `root` (3 levels), in root's frame.
static func _shapes_aabb(root: Node3D) -> AABB:
	var inv := root.global_transform.orthonormalized().affine_inverse()
	var out := AABB()
	var first := true
	var stack: Array = [[root, 0]]
	while not stack.is_empty():
		var e: Array = stack.pop_back()
		var n: Node = e[0]
		var cs := n as CollisionShape3D
		if cs != null and cs.shape != null and not cs.disabled:
			var a: AABB = (inv * cs.global_transform) * cs.shape.get_debug_mesh().get_aabb()
			out = a if first else out.merge(a)
			first = false
		if int(e[1]) < 3:
			for c in n.get_children():
				stack.append([c, int(e[1]) + 1])
	return AABB(Vector3(-0.3, -0.3, -0.3), Vector3(0.6, 0.6, 0.6)) if first else out

## Walls (the old rules: freeze, Focus, the wall table): wall panels and pillars.
static func is_wall(w: Node) -> bool:
	return w is Pillar or (w is Destructible and (w as Destructible).kind == &"panel")

## Energy at which a flying body cracks `w`: get_crack_threshold() if it has one,
## else Tuning.CRACK_FRACTION of its break_energy, else of its Tuning.FURNITURE
## kind's break energy; INF if none (bones never ignore it).
static func crack_threshold_of(w: Node) -> float:
	if w.has_method(&"get_crack_threshold"):
		return float(w.call(&"get_crack_threshold"))
	var be: Variant = w.get(&"break_energy")
	if be is float or be is int:
		return Tuning.CRACK_FRACTION * float(be)
	var spec: Dictionary = Tuning.FURNITURE.get(w.get(&"kind"), {})
	if spec.has("break"):
		return Tuning.CRACK_FRACTION * float(spec["break"])
	return INF

func _consider_wall(track: Track, f: Fighter, w: Node3D, M: float, v: Vector3, com: Vector3,
		center: Vector3, half: Vector3, raw_half: Vector3, speed: float, look: float, decide_dist: float) -> void:
	if track.broke.has(w.get_instance_id()):
		return   # broken or holed by this flight already: it counts once
	var t_hit := time_to_contact_obb(center, half, v, _box_xf(w), _box_half(w))
	if is_inf(t_hit) or t_hit * speed > look:
		return
	# The body's outline on the panel at contact; already open -> no decision.
	var footprint := Rect2()
	var panel := w as Destructible
	if panel != null:
		footprint = footprint_on(panel, center + v * t_hit, raw_half)
		if panel.kind == &"panel" and panel.footprint_open_fraction(footprint) >= OPEN_SKIP:
			return
	var dist := t_hit * speed
	var wid := w.get_instance_id()
	if track.decided.has(wid):
		var dec: Dictionary = track.decided[wid]
		dec["seen"] = _time
		if dec["outcome"] != &"break" and dist <= decide_dist * 2.0:
			_need_collide = true
		return
	var n: Vector3 = w.call(&"get_face_normal", com)
	var energy := Power.wall_energy(M, v, n)
	if energy <= 0.5 * M * 0.05 * 0.05:
		return
	if dist <= decide_dist:
		_decide(track, f, w, energy, n, v, com, t_hit, footprint)
	elif energy >= crack_threshold_of(w):
		_want_ignore = true

## World AABB (centre `c`, half extents `h`) projected onto a panel's face:
## a Rect2 in panel-local XY.
static func footprint_on(w: Destructible, c: Vector3, h: Vector3) -> Rect2:
	var xf := w.global_transform
	var lc := xf.affine_inverse() * c
	var hx := _ext(xf.basis.x.normalized(), h)
	var hy := _ext(xf.basis.y.normalized(), h)
	return Rect2(lc.x - hx, lc.y - hy, hx * 2.0, hy * 2.0)

func _decide(track: Track, f: Fighter, w: Node3D, energy: float, n: Vector3, v: Vector3,
		com: Vector3, t_hit: float, footprint: Rect2) -> void:
	var pos := _contact_point(com, v, t_hit, w, n)
	var crack_threshold := crack_threshold_of(w)
	# The breakable can name what broke it (K's furniture_broken.by): the flying
	# body, set just before the call (meta "impact_body", kept until the next impact).
	w.set_meta(&"impact_body", f)
	var outcome: StringName = w.call(&"receive_impact", energy, pos, v, footprint)
	if outcome == &"hole":
		outcome = &"break"   # a hole the body fits through: it passes like a break
	var wid := w.get_instance_id()
	track.decided[wid] = {"outcome": outcome, "seen": _time}
	var surface: StringName = w.get(&"surface")
	var wall := is_wall(w)
	var dmg := 0.0
	match outcome:
		&"break":
			track.broke[wid] = true
			dmg = break_damage(w)
			if f.ragdoll:
				f.ragdoll.scale_velocity(sqrt(maxf(1.0 - float(w.get(&"absorption")), 0.0)))
				_vel_changed = true
			_let_chunks_pass(f, w)
			# Keep bones off breakables until the centre has crossed the far face.
			_want_ignore = true
			var origin := _box_xf(w).origin
			var half_n := float(w.call(&"get_half_extent_along", n))
			track.passing[wid] = {"point": origin - n * half_n, "into": -n, "until": _time + PASS_TIMEOUT}
			# Walls (panels, pillars) freeze the flyer, count for the chain and the
			# launcher's Focus; furniture breaking is the environment paying off.
			if wall:
				# Wall-break freeze: the flying body alone, when its front reaches the near face.
				track.freeze_at = {"point": origin + n * half_n, "into": -n, "until": _time + BREAK_FREEZE_WAIT}
				track.walls_broken += 1
				if track.walls_broken >= 2:
					GameEvents.wall_chain.emit(f, track.walls_broken)
				GameEvents.wall_broken_by.emit(f, w, energy)
		&"crack":
			dmg = float(Tuning.WALL_DAMAGE[&"crack"]) if wall else 0.0
			_need_collide = true
			if f.ragdoll:
				var strength := clampf(energy / maxf(crack_threshold, 1.0), 1.0, 2.0) if is_finite(crack_threshold) else 1.0
				f.ragdoll.apply_limb_spin(v.normalized(), strength)
			_impact_feel(f, energy, WALL_HITSTOP)
		_:
			_need_collide = true
			if energy > Tuning.IMPACT_MIN_ENERGY:
				_impact_feel(f, energy, WALL_HITSTOP)
	wall_decided.emit(f, w, outcome, energy, pos)
	_reset_history(track)
	track.cooldown_until = _time + IMPACT_COOLDOWN
	_wall_hit(f, energy, dmg, pos, n, surface, &"wall")

## Damage to a flying body that breaks `w`: Tuning.WALL_DAMAGE by surface for
## walls, Tuning.FURNITURE_BODY_DAMAGE for anything else.
static func break_damage(w: Node3D) -> float:
	if not is_wall(w):
		return Tuning.FURNITURE_BODY_DAMAGE
	var surface: StringName = w.get(&"surface")
	return float(Tuning.WALL_DAMAGE.get(surface, Tuning.WALL_DAMAGE[&"drywall"]))

## Fires the pending wall-break freeze once the body's leading edge reaches the
## broken face (or BREAK_FREEZE_WAIT passed): the flyer alone holds for
## Tuning.WALL_BREAK_FREEZE while the chunks burst around it.
func _check_break_freeze(track: Track, f: Fighter, bounds: AABB) -> void:
	if track.freeze_at.is_empty():
		return
	var into: Vector3 = track.freeze_at["into"]
	var h := bounds.size * 0.5
	var front := bounds.get_center().dot(into) + absf(h.x * into.x) + absf(h.y * into.y) + absf(h.z * into.z)
	if front >= (track.freeze_at["point"] as Vector3).dot(into) or _time >= float(track.freeze_at["until"]):
		track.freeze_at = {}
		f.freeze_hitstop(Tuning.WALL_BREAK_FREEZE)
		_reset_history(track)

## Screen shake by energy plus a short local hitstop on the body (cracks and
## hard bounces; wall-break trauma is the camera's, from wall_broken).
func _impact_feel(f: Fighter, energy: float, hitstop: float) -> void:
	GameEvents.screen_shake.emit(clampf(energy / 30000.0, 0.05, 0.2))
	if hitstop > 0.0 and is_instance_valid(f):
		TimeDirector.hitstop([f], hitstop)

func _contact_point(com: Vector3, v: Vector3, t: float, w: Node3D, n: Vector3) -> Vector3:
	var xf := _box_xf(w)
	var p := com + v * t
	var face := xf.origin + n * float(w.call(&"get_half_extent_along", n))
	p -= n * (p - face).dot(n)
	var local := xf.affine_inverse() * p
	var h := _box_half(w)
	local = local.clamp(-h, h)
	return xf * local

func _let_chunks_pass(f: Fighter, w: Node3D) -> void:
	var chunks_v: Variant = w.get(&"last_chunks")
	if f.rig == null or chunks_v == null or (chunks_v as Array).is_empty():
		return
	var bones: Array = f.rig.get_physical_bones()
	if bones.is_empty():
		return
	var chunks: Array = (chunks_v as Array).duplicate()
	for c: RigidBody3D in chunks:
		for b: PhysicalBone3D in bones:
			if is_instance_valid(b) and is_instance_valid(c):
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

# --- Bodies as projectiles (bowling) ---------------------------------------------

## The flyer's pelvis speed across the floor (the doc's projectile test and
## bowl tier): the speed it carries into a standing enemy. Falling speed goes
## into the floor, not the enemy (as walls use the speed straight into them),
## so a thrown body's chain runs 16 -> 9.6 -> 5.8 whatever its arc.
## COM speed as a fallback.
func _pelvis_speed(f: Fighter, com_v: Vector3) -> float:
	var pv := com_v
	if f.ragdoll and f.ragdoll.has_method(&"get_bone_velocity"):
		var bv: Variant = f.ragdoll.call(&"get_bone_velocity", Bones.HIPS)
		if bv is Array and (bv as Array).size() >= 1 and (bv as Array)[0] is Vector3 \
				and ((bv as Array)[0] as Vector3).length_squared() > 1e-6:
			pv = (bv as Array)[0]
	return Vector2(pv.x, pv.z).length()

func _consider_bowl(track: Track, f: Fighter, victim: Fighter, v: Vector3, com: Vector3,
		center: Vector3, half: Vector3, delta: float, speed: float) -> void:
	# A flying body only ever bowls enemies: a launched or thrown body bowls
	# enemies, and nobody bowls the player (enemies never launch the player).
	if victim.team != Fighter.TEAM_ENEMY or victim.is_down() or victim.is_dead():
		return
	var vid := victim.get_instance_id()
	if track.bowled.has(vid) or track.chain.count >= Tuning.BOWL_CHAIN_MAX:
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
	if v_rel.dot(d) < MIN_SWEEP_SPEED:
		return  # overlapping but separating (e.g. thrown away from the grabber): no bowl
	track.bowled[vid] = true
	var pos := com + v * t_hit + d * minf(half.x, half.z)
	_bowl(track, f, victim, speed, v, pos)

## One bowl hit: a preset-tier HitInfo by the flyer's speed through the normal
## hit pipeline, then the flyer loses Tuning.BOWL_SPEED_LOSS of its speed.
func _bowl(track: Track, f: Fighter, victim: Fighter, speed: float, v: Vector3, pos: Vector3) -> void:
	var flat := Vector3(v.x, 0.0, v.z)
	flat = flat.normalized() if flat.length() > 0.05 else (victim.get_center_of_mass() - f.get_center_of_mass()).normalized()
	var tier := Power.bowl_tier(speed)
	var info := build_bowl_hit(get_launcher(f) as Fighter, victim, tier, deflect_dir(flat, f.get_center_of_mass(),
		victim.get_center_of_mass(), tier), pos, speed)
	var chain := track.chain
	var vid := victim.get_instance_id()
	_pending_chain[vid] = chain
	var result := victim.take_hit(info)
	_pending_chain.erase(vid)
	if not is_instance_valid(f):
		return
	if result == HitInfo.Result.HIT:
		chain.count += 1
		# The flyer keeps tumbling with 60% of its speed, through the victim.
		if f.ragdoll:
			f.ragdoll.scale_velocity(1.0 - Tuning.BOWL_SPEED_LOSS)
			_vel_changed = true
		if is_instance_valid(victim):
			_ghost_through(track, f, victim, flat)
		# Contact frame: the flyer and the victim freeze by tier (the thrower,
		# meters away, does not).
		var who: Array = [f]
		if is_instance_valid(victim):
			who.append(victim)
			if victim.has_method(&"set_hitstop_jitter"):
				victim.set_hitstop_jitter()
		TimeDirector.hitstop(who, Power.hitstop_for(tier))
		if is_instance_valid(victim):
			var root := get_launcher(f)
			_set_launcher(vid, root if root != null and root != victim else f)
			if victim.is_launched():
				var vt := _track_for(victim)
				vt.chain = chain
				vt.bowled[f.get_instance_id()] = true
		GameEvents.body_bowled.emit(f, victim, 0.5 * f.get_total_mass() * speed * speed, chain.count)
	bowl_dealt.emit(f, victim, speed, tier, info)

## The direction a bowled victim leaves in: the flyer's line `flat`, turned
## BOWL_DEFLECT degrees toward the side the victim stands on (a glancing hit).
static func deflect_dir(flat: Vector3, flyer_com: Vector3, victim_com: Vector3, tier := HitInfo.Tier.STAGGER) -> Vector3:
	var side := Vector3.UP.cross(flat)
	var off := (victim_com - flyer_com).dot(side)
	var sgn := 1.0 if off >= 0.0 else -1.0
	var range_deg := BOWL_DEFLECT_LAUNCH if tier >= HitInfo.Tier.LAUNCH else BOWL_DEFLECT
	var deg := lerpf(range_deg.x, range_deg.y, clampf(absf(off) / BOWL_DEFLECT_OFFSET, 0.0, 1.0))
	# Rotating about +Y by a positive angle turns `flat` toward `side`.
	return flat.rotated(Vector3.UP, sgn * deg_to_rad(deg)).normalized()

## The flyer passes through `victim` from now until it is clear of it.
func _ghost_through(track: Track, f: Fighter, victim: Fighter, flat: Vector3) -> void:
	var mine := _phys_bodies(f, false)
	var theirs := _phys_bodies(victim, true)
	for a: PhysicsBody3D in mine:
		for b: PhysicsBody3D in theirs:
			a.add_collision_exception_with(b)
			b.add_collision_exception_with(a)
	track.ghosts.append({"victim": victim, "mine": mine, "theirs": theirs, "dir": flat,
		"until": _time + GHOST_TIME})

func _update_ghosts(track: Track, com: Vector3) -> void:
	for i in range(track.ghosts.size() - 1, -1, -1):
		var g: Dictionary = track.ghosts[i]
		var victim: Variant = g["victim"]
		var done: bool = _time > float(g["until"]) or not is_instance_valid(victim)
		if not done:
			var vc := (victim as Fighter).get_center_of_mass()
			done = (com - vc).dot(g["dir"] as Vector3) > GHOST_CLEAR
		if done:
			_unghost(g)
			track.ghosts.remove_at(i)

static func _unghost(g: Dictionary) -> void:
	for a: Variant in g["mine"]:
		if not is_instance_valid(a):
			continue
		for b: Variant in g["theirs"]:
			if is_instance_valid(b):
				(a as PhysicsBody3D).remove_collision_exception_with(b as PhysicsBody3D)
				(b as PhysicsBody3D).remove_collision_exception_with(a as PhysicsBody3D)

## A fighter's physics bodies: its bones (and its capsule).
static func _phys_bodies(f: Fighter, with_capsule: bool) -> Array:
	var out: Array = []
	if with_capsule:
		out.append(f)
	if f.rig:
		for b in f.rig.get_physical_bones():
			if is_instance_valid(b):
				out.append(b)
	return out

## A thrown or launched body hitting `victim` (Feel Reference: Thrown bodies are
## projectiles): preset tier, Tuning.BOWL_DAMAGE, unblockable, no hitstop of its
## own (ImpactResolver freezes the flyer and the victim). `flat_dir` is where
## the victim goes (deflect_dir: off the flyer's line). Launch tier sends the
## victim at Tuning.BOWL_SPEED_SHARE of the flyer's speed (6..18 m/s) at the
## launch angle; knockdown drops it in place.
static func build_bowl_hit(attacker: Fighter, victim: Fighter, tier: int, flat_dir: Vector3,
		pos: Vector3, flyer_speed := -1.0) -> HitInfo:
	var info := HitInfo.new()
	info.attacker = attacker
	info.victim = victim
	info.kind = &"bowl"
	info.move_id = &"bowl"
	info.tier = tier
	info.reaction = HitInfo.reaction_for_tier(tier)
	info.damage = float(Tuning.BOWL_DAMAGE.get(HitInfo.tier_name(tier), 5.0))
	info.hit_direction = flat_dir
	info.hit_position = pos
	info.hit_bone = Bones.CHEST
	info.unblockable = true
	info.hitstop = 0.0
	info.level = HitInfo.Level.MID
	var lv := Vector3.ZERO
	if tier >= HitInfo.Tier.LAUNCH:
		var s := Tuning.BOWL_LAUNCH_FROM if flyer_speed < 0.0 else flyer_speed
		var ls := clampf(Tuning.BOWL_SPEED_SHARE * s, Tuning.LAUNCH_SPEED_MIN, Tuning.LAUNCH_SPEED_MAX)
		if victim != null and victim.is_heavy():
			ls *= Tuning.HEAVY_LAUNCH_MULT
		var a := deg_to_rad(Tuning.LAUNCH_ANGLE)
		lv = (flat_dir * cos(a) + Vector3.UP * sin(a)) * ls
	elif tier == HitInfo.Tier.KNOCKDOWN:
		lv = flat_dir * BOWL_KNOCKDOWN_PUSH
	info.launch_velocity = lv
	var m := victim.get_total_mass() if victim != null else 75.0
	info.energy = 0.5 * m * lv.length_squared()
	return info

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

func _reset_history(track: Track) -> void:
	track.hist_t.clear()
	track.hist_v.clear()
	track.peak_dv = Vector3.ZERO

func _detect_impact(track: Track, f: Fighter, M: float, v: Vector3, com: Vector3, bounds: AABB) -> void:
	if _vel_changed:
		_reset_history(track)
		return
	if TimeDirector.now() < track.suspend_until or f.is_frozen():
		_reset_history(track)
		return
	# Hitstop on a ragdoll zeroes every bone velocity: not an impact.
	if v.length_squared() < 1e-6 and track.last_v.length_squared() > 1.0:
		_reset_history(track)
		return
	track.hist_t.append(_time)
	track.hist_v.append(v)
	while track.hist_t.size() > 2 and _time - track.hist_t[1] >= IMPACT_WINDOW:
		track.hist_t.remove_at(0)
		track.hist_v.remove_at(0)
	if _time < track.cooldown_until or track.hist_t.size() < 2:
		return
	var dt := _time - track.hist_t[0]
	var v0 := track.hist_v[0]
	var dv := v - v0 - _gravity * dt
	var threshold := sqrt(2.0 * Tuning.IMPACT_MIN_ENERGY / M) * 0.85
	var in_impact := dv.length() >= threshold and dv.dot(v0) < 0.0
	if in_impact:
		if dv.length_squared() > track.peak_dv.length_squared():
			track.peak_dv = dv
			track.peak_v0 = v0
			track.peak_com = com
			track.peak_time = _time
			return
		if dv.length() > track.peak_dv.length() * 0.8 and _time - track.peak_time < IMPACT_WINDOW:
			return
	if track.peak_dv != Vector3.ZERO:
		_commit_impact(track, f, M, bounds)

## A hard impact found from the COM velocity: floors and bodies only report it
## (body_impact, no damage); static walls (the boundary concrete, structure)
## crack from their surface's crack energy (+ crack damage). Breakables are
## judged by the sweep, never here.
func _commit_impact(track: Track, f: Fighter, M: float, bounds: AABB) -> void:
	var dv := track.peak_dv
	var com := track.peak_com
	var v0 := track.peak_v0
	track.peak_dv = Vector3.ZERO
	var dvn := dv.normalized()
	var reach := bounds.size.length() * 0.5 + 0.4
	var n := dvn
	var pos := com - dvn * 0.5
	var surface := &"concrete"
	var space := f.get_world_3d().direct_space_state
	var excl := _own_rids(f)
	if track.swinging and track.swing_holder is Fighter and is_instance_valid(track.swing_holder):
		excl.append_array(_own_rids(track.swing_holder as Fighter))
	var q := PhysicsRayQueryParameters3D.create(com, com - dvn * reach,
		Layers.WORLD | Layers.DESTRUCTIBLE | Layers.CAPSULE | Layers.RAGDOLL | Layers.DEBRIS | Layers.DEAD_BODY, excl)
	var hit := space.intersect_ray(q)
	if track.swinging and hit.is_empty():
		return  # the grip pulled the body around: not an impact
	var collider: Object = null
	var energy := 0.0
	if not hit.is_empty():
		n = hit["normal"]
		pos = hit["position"]
		collider = hit["collider"]
		surface = _surface_of(collider)
		energy = Power.wall_energy(M, v0, n)
	else:
		surface = _guess_surface(f, pos)
		energy = 0.5 * M * dv.length_squared()
	if energy <= Tuning.IMPACT_MIN_ENERGY:
		return
	track.cooldown_until = _time + IMPACT_COOLDOWN
	_reset_history(track)
	var floor_hit := n.y > 0.7
	var breakable := WorldTags.breakable_of(collider) != null
	var static_wall := not floor_hit and not breakable and collider is StaticBody3D \
		and surface != &"body" and surface != &"debris"
	var dmg := 0.0
	if static_wall:
		var data: Dictionary = Tuning.SURFACES.get(surface, Tuning.SURFACES[&"concrete"])
		if energy >= Tuning.CRACK_FRACTION * float(data["break_energy"]):
			dmg = float(Tuning.WALL_DAMAGE[&"crack"])
			Destructible.spawn_crack_decal(f, pos, n, energy)
			GameEvents.wall_cracked.emit(collider as Node3D, pos, energy)
			_impact_feel(f, energy, WALL_HITSTOP)
	var move := &"floor" if floor_hit else (&"body" if surface == &"body" else &"wall")
	_wall_hit(f, energy, dmg, pos, n, surface, move)

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
	if col is PhysicalBone3D or col is Fighter:
		return &"body"
	if col is RigidBody3D and (col as Node).is_in_group(&"debris"):
		return &"debris"
	if col is Node:
		return WorldTags.surface_of(col)
	return &"concrete"

func _guess_surface(f: Fighter, pos: Vector3) -> StringName:
	for n in get_tree().get_nodes_in_group(&"fighters"):
		var o := n as Fighter
		if o and o != f and o.get_center_of_mass().distance_to(pos) < 1.2:
			return &"body"
	return &"concrete"

# --- Damage --------------------------------------------------------------------

## Report one impact: body_impact (effects) from Tuning.IMPACT_MIN_ENERGY, and
## wall damage `dmg` (Tuning.WALL_DAMAGE, already chosen) to the flying body.
func _wall_hit(f: Fighter, energy: float, dmg: float, pos: Vector3, n: Vector3, surface: StringName,
		move_id: StringName) -> void:
	if energy > Tuning.IMPACT_MIN_ENERGY:
		GameEvents.body_impact.emit(f, pos, n, energy, surface)
	var info: HitInfo = null
	var track: Track = _tracks.get(f.get_instance_id()) if is_instance_valid(f) else null
	if track != null and track.swinging and dmg > 0.0:
		dmg = minf(dmg, maxf(SWING_DAMAGE_CAP - track.swing_damage, 0.0))
		track.swing_damage += dmg
	if dmg > 0.0 and is_instance_valid(f):
		info = HitInfo.new()
		info.victim = f
		info.move_id = move_id
		info.kind = &"impact"
		info.damage = dmg
		info.reaction = HitInfo.Reaction.NONE
		info.tier = HitInfo.Tier.NONE
		info.hit_position = pos
		info.hit_direction = -n
		info.hit_bone = _nearest_bone(f, pos)
		info.energy = energy
		info.result = HitInfo.Result.HIT
		# A thrown (or flung) body's own impacts name the thrower, and a throw
		# into brick or concrete is a finisher (may dismember on a kill).
		if _thrown.has(f.get_instance_id()):
			info.attacker = get_launcher(f) as Fighter
			if surface == &"brick" or surface == &"concrete":
				info.is_finisher = true
		f.apply_damage(dmg, &"impact", info)
		GameEvents.impact_damaged.emit(f, dmg, energy, surface, pos)
		impact_info.emit(info)
	impact_dealt.emit(f, energy, dmg, &"floor" if move_id == &"floor" else surface, pos)

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
