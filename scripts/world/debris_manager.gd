extends Node
## Autoload "DebrisManager": owns every loose debris body (wall chunks, prop
## pieces, pillar pieces, thrown chunks) and the strike chips.
## OWNER: agent D (world). CONTRACT STUB.
##
## Round 5 rules (Feel Reference: "Things stay"; Budget):
## - Debris STAYS for the round: no timer ever removes it. At most
##   Tuning.DEBRIS_MAX (150) bodies live together; past that the oldest SETTLED
##   body fades out over FADE_TIME. A body in the air is never removed; only if
##   the pool overflows by OVERFLOW_HARD does its oldest body fade regardless.
## - A body at rest for Tuning.DEBRIS_FREEZE_AFTER (4 s) is frozen (static, no
##   cost). It wakes again when a flying body sweeps toward it (ImpactResolver
##   calls wake_in_box) or a standing fighter walks within WAKE_RADIUS of it,
##   so rubble still gets knocked about; it freezes again 4 s after it settles.
## - Strike chips (StrikeMarks, life <= FX_LIFE_MAX) are effects, not debris:
##   a separate small pool, timed, at most FX_MAX.
## - Counters for the end-of-wave check (J): props_broken_total(),
##   furniture_broken_count(), wall_holes_count(), get_world_counts().
## - GameEvents.debris_landed when a chunk's speed drops sharply (throttled).
## - Pieces a break just spawned (hold_young, called by the break with its
##   reference speed: the breaking body's speed) are held for YOUNG_TIME s to
##   at most max(YOUNG_SHARE x that speed, that speed + YOUNG_ALLOW), so pieces
##   spawned overlapping never shoot off (a 77 kg pillar core once left at
##   28 m/s from an 18 m/s body). Only those: register() alone never holds a
##   body, and a hold ends at once when something launches, throws or picks the
##   body up (release_young; a ProjectileProbe on it; frozen).
## Ages are game time (they stretch in slow motion like the physics).

signal body_registered(body: RigidBody3D)

## SUPERSEDED pools kept as names for callers: LARGE_MAX is the round cap now.
const LARGE_MAX := Tuning.DEBRIS_MAX
const MEDIUM_LIFE := 30.0       ## SUPERSEDED (Round 5: debris never times out); callers still pass it
const FADE_TIME := 0.6          ## s of shrink before free
const SETTLE_SPEED := 0.15      ## m/s under which a body counts as at rest
const SETTLED_AFTER := 0.75     ## s at rest -> settled (may be evicted)
const OVERFLOW_HARD := 40       ## a pool this far over its cap fades its oldest anyway
const LAND_DROP := 2.5          ## m/s lost in one tick = a landing
const LAND_MIN_SPEED := 2.5     ## m/s before the drop
const LAND_GAP_GLOBAL := 0.04   ## s between any two debris_landed
const LAND_GAP_BODY := 0.35     ## s between two debris_landed of one body
const LAND_WATCH_AGE := 12.0    ## s after registering a body is watched for landings
const BOOKKEEP_INTERVAL := 0.1  ## s between age / cap / wake sweeps
## Strike chips: a body registered with 0 < life <= FX_LIFE_MAX is an effect.
const FX_LIFE_MAX := 5.0
const FX_MAX := 48
## m: a standing fighter this close wakes frozen debris (its feet push it).
const WAKE_RADIUS := 0.9
## Pieces of a break: speed held for this long (s), to this share of the
## break's reference speed or that speed plus this much (m/s, room for
## gravity), whichever is more.
const YOUNG_TIME := 0.2
const YOUNG_SHARE := 1.2
const YOUNG_ALLOW := 2.5

class Entry:
	var body: RigidBody3D
	var small := false
	var keep := false         ## structure (a fallen overhead piece): never faded, not counted in the cap
	var life := -1.0          ## s until it fades (FX chips only); < 0 = stays
	var age := 0.0
	var rest := 0.0
	var frozen := false
	var fading := false
	var fade_t := 0.0
	var visuals: Array = []   ## [Node3D, original scale]
	var last_speed := 0.0
	var last_land := -INF
	var young_cap := -1.0     ## m/s a break's piece is held to while young (< 0: not held)
	var born := 0.0

var _debris: Array = []       ## Array[Entry], stays for the round, oldest first
var _fx: Array = []           ## Array[Entry], strike chips, timed
var _acc := 0.0
var _time := 0.0
var _last_land := -INF
var _young: Array = []        ## Array[Entry] held by hold_young less than YOUNG_TIME ago
var _props_broken := 0
var _loose_props_broken := 0

func _ready() -> void:
	process_physics_priority = 50

## Take ownership of a live debris body (already in the tree).
## small: put it on Layers.DEBRIS_SMALL so small chunks skip each other.
## life in (0, FX_LIFE_MAX]: a strike chip (timed effect); anything else stays
## for the round. keep: a big structural piece (a pillar's fallen overhead
## piece) that is frozen like debris but never faded and not counted in the cap.
func register(body: RigidBody3D, small := false, life := -1.0, keep := false) -> void:
	if body == null or not is_instance_valid(body) or _find(body) != null:
		return
	if small:
		body.collision_layer = Layers.DEBRIS_SMALL
		body.collision_mask = Layers.MASK_DEBRIS_SMALL
	else:
		body.collision_layer = Layers.DEBRIS
		body.collision_mask = Layers.MASK_DEBRIS
	body.freeze = false
	body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	body.can_sleep = true
	body.add_to_group(&"debris")
	body.set_meta(&"debris_small", small)
	var e := Entry.new()
	e.body = body
	e.small = small
	e.keep = keep
	var fx := life > 0.0 and life <= FX_LIFE_MAX
	e.life = life if fx else -1.0
	e.last_speed = body.linear_velocity.length()
	e.born = _time
	(_fx if fx else _debris).append(e)
	_enforce(_fx if fx else _debris, FX_MAX if fx else Tuning.DEBRIS_MAX)
	body_registered.emit(body)

## Live registered bodies (including ones fading out, chips included).
func count() -> int:
	return _debris.size() + _fx.size()

## Round debris (not chips); include_fading = false counts only bodies that are
## not on their way out.
func count_debris(include_fading := true) -> int:
	return _debris.size() if include_fading else _active(_debris)

## Large-layer debris / small-layer debris plus strike chips.
func count_large(include_fading := true) -> int:
	var n := 0
	for e: Entry in _debris:
		if not e.small and (include_fading or not e.fading):
			n += 1
	return n

func count_small(include_fading := true) -> int:
	var n := 0
	for e: Entry in _debris:
		if e.small and (include_fading or not e.fading):
			n += 1
	return n + (_fx.size() if include_fading else _active(_fx))

## Round debris currently frozen (at rest for Tuning.DEBRIS_FREEZE_AFTER).
func count_frozen() -> int:
	var n := 0
	for e: Entry in _debris:
		if e.frozen:
			n += 1
	return n

func _active(pool: Array) -> int:
	var n := 0
	for e: Entry in pool:
		if not e.fading:
			n += 1
	return n

## Live, non-fading debris bodies, oldest first (AI looks for ammo here).
func get_bodies() -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	for pool in [_debris, _fx]:
		for e: Entry in pool:
			if is_instance_valid(e.body) and not e.fading:
				out.append(e.body)
	return out

## Nearest live, non-fading debris body within `radius` of `pos`, or null.
func find_nearest(pos: Vector3, radius: float, large_only := false) -> RigidBody3D:
	var best: RigidBody3D = null
	var best_d := radius
	for pool in [_debris, _fx]:
		for e: Entry in pool:
			if e.fading or not is_instance_valid(e.body) or (large_only and (e.small or pool == _fx)):
				continue
			var d := e.body.global_position.distance_to(pos)
			if d < best_d:
				best_d = d
				best = e.body
	return best

## Stop managing a body (e.g. picked up). The caller owns it now.
func release(body: RigidBody3D) -> void:
	for pool in [_debris, _fx]:
		for i in pool.size():
			var e: Entry = pool[i]
			if e.body == body:
				if is_instance_valid(body):
					body.freeze = false
					_restore_visuals(e)
				pool.remove_at(i)
				return

## True if `body` is managed and settled (at rest).
func is_settled(body: RigidBody3D) -> bool:
	var e := _find(body)
	return e != null and e.rest >= SETTLED_AFTER

## True if `body` is managed and frozen.
func is_frozen(body: RigidBody3D) -> bool:
	var e := _find(body)
	return e != null and e.frozen

## Unfreeze every frozen debris body inside `box` (a flying body's sweep). Cheap:
## a loop over the frozen bodies.
func wake_in_box(box: AABB) -> void:
	for e: Entry in _debris:
		if e.frozen and is_instance_valid(e.body) and box.has_point(e.body.global_position):
			_unfreeze(e)

## Unfreeze frozen debris within `radius` of `pos`.
func wake_near(pos: Vector3, radius: float) -> void:
	var r2 := radius * radius
	for e: Entry in _debris:
		if e.frozen and is_instance_valid(e.body) and e.body.global_position.distance_squared_to(pos) <= r2:
			_unfreeze(e)

## A ThrowableProp broke (it calls this before GameEvents.prop_broken).
func note_prop_broken(_prop: Node3D) -> void:
	_props_broken += 1

## A LooseProp (chair, cabinet, drum) shattered.
func note_loose_prop_broken(_prop: Node3D) -> void:
	_loose_props_broken += 1

## Thrown props (ThrowableProp) broken this round.
func props_broken_total() -> int:
	return _props_broken

## Furniture broken and still lying in the arena: every breakable that is not
## a wall (D's crates, desks, lamps, door frames; K's clutter) reporting
## is_broken, plus loose props (chairs, cabinets, drums) that shattered this round.
func furniture_broken_count() -> int:
	var n := _loose_props_broken
	for node in get_tree().get_nodes_in_group(&"breakables"):
		if node.is_queued_for_deletion() or ImpactResolver.is_wall(node):
			continue
		if bool(node.get(&"is_broken")):
			n += 1
	return n

## Wall holes that stay: panels with cells missing (holes or fully broken) and
## broken pillars.
func wall_holes_count() -> int:
	var n := 0
	for node in get_tree().get_nodes_in_group(&"destructibles"):
		var d := node as Destructible
		if d != null and d.kind == &"panel" and not d.is_queued_for_deletion() \
				and d.get_cell_count() > 0 and d.get_alive_count() < d.get_cell_count():
			n += 1
	for node in get_tree().get_nodes_in_group(&"pillars"):
		if node.get(&"is_broken"):
			n += 1
	return n

## Everything the end-of-wave check reads, in one call.
func get_world_counts() -> Dictionary:
	return {"debris": count_debris(false), "debris_frozen": count_frozen(), "chips": _active(_fx),
		"props_broken": props_broken_total(), "furniture_broken": furniture_broken_count(),
		"wall_holes": wall_holes_count(), "collapses": WorldDamage.get_collapse_count()}

## Free all debris and zero the counters (round restart).
func reset() -> void:
	for pool in [_debris, _fx]:
		for e: Entry in pool:
			_free_body(e.body)
		pool.clear()
	_props_broken = 0
	_loose_props_broken = 0
	_young.clear()

## A break just spawned `body` (registered) at about `ref_speed` m/s (the
## breaking body's speed): hold its speed for YOUNG_TIME s to at most
## max(YOUNG_SHARE x ref_speed, ref_speed + YOUNG_ALLOW).
func hold_young(body: RigidBody3D, ref_speed: float) -> void:
	var e := _find(body)
	if e == null:
		return
	e.born = _time
	e.young_cap = maxf(ref_speed * YOUNG_SHARE, ref_speed + YOUNG_ALLOW)
	if not _young.has(e):
		_young.append(e)

## Something launched, threw or picked up `body`: no speed hold from now on.
func release_young(body: RigidBody3D) -> void:
	var e := _find(body)
	if e == null:
		return
	e.young_cap = -1.0
	_young.erase(e)

## True while `body` is under a young-piece speed hold (tests, debug).
func is_held_young(body: RigidBody3D) -> bool:
	var e := _find(body)
	return e != null and _young.has(e) and e.young_cap >= 0.0

func _find(body: RigidBody3D) -> Entry:
	for pool in [_debris, _fx]:
		for e: Entry in pool:
			if e.body == body:
				return e
	return null

func _physics_process(delta: float) -> void:
	_time += delta
	_acc += delta
	if not _young.is_empty():
		_hold_young()
	var bookkeep := _acc >= BOOKKEEP_INTERVAL
	var dt_book := _acc
	if bookkeep:
		_acc = 0.0
	for pool in [_debris, _fx]:
		var i := 0
		while i < pool.size():
			var e: Entry = pool[i]
			# Frozen bodies cost two field reads a tick; settled old ones are
			# only looked at on bookkeeping ticks.
			if e.frozen and not e.fading:
				i += 1
				continue
			if not bookkeep and not e.fading and e.rest >= SETTLED_AFTER and e.age >= LAND_WATCH_AGE:
				i += 1
				continue
			if not is_instance_valid(e.body) or e.body.is_queued_for_deletion():
				pool.remove_at(i)
				continue
			if e.fading:
				e.fade_t += delta
				var k := clampf(1.0 - e.fade_t / FADE_TIME, 0.0, 1.0)
				for pair: Array in e.visuals:
					if is_instance_valid(pair[0]):
						(pair[0] as Node3D).scale = (pair[1] as Vector3) * maxf(k, 0.01)
				if e.fade_t >= FADE_TIME:
					_free_body(e.body)
					pool.remove_at(i)
					continue
				i += 1
				continue
			var dt := dt_book if bookkeep and e.rest >= SETTLED_AFTER and e.age >= LAND_WATCH_AGE else delta
			_watch(e, dt)
			if bookkeep:
				e.age += dt_book
				if e.life > 0.0 and e.age >= e.life:
					_start_fade(e)
				elif pool == _debris and e.rest >= Tuning.DEBRIS_FREEZE_AFTER:
					_freeze(e)
			i += 1
	if bookkeep:
		_enforce(_debris, Tuning.DEBRIS_MAX)
		_enforce(_fx, FX_MAX)
		_wake_by_fighters()

## A break's new pieces never leave faster than the break sent them (overlap
## at spawn). Launched, thrown or picked-up bodies are let go.
func _hold_young() -> void:
	var keep: Array = []
	for e: Entry in _young:
		if _time - e.born > YOUNG_TIME or not is_instance_valid(e.body) or e.fading or e.young_cap < 0.0 \
				or e.body.freeze or _is_launched(e.body):
			e.young_cap = -1.0
			continue
		keep.append(e)
		var v := e.body.linear_velocity
		if v.length() > e.young_cap:
			e.body.linear_velocity = v * (e.young_cap / v.length())
	_young = keep

## ThrownChunk.launch_body made it a projectile (a ProjectileProbe child).
static func _is_launched(body: RigidBody3D) -> bool:
	for c in body.get_children():
		if c is ProjectileProbe:
			return true
	return false

## Rest time and landing detection for one body.
func _watch(e: Entry, delta: float) -> void:
	if e.body.sleeping:
		e.rest += delta
		e.last_speed = 0.0
		return
	var speed := e.body.linear_velocity.length()
	if speed < SETTLE_SPEED:
		e.rest += delta
	else:
		e.rest = 0.0
	if e.age < LAND_WATCH_AGE and e.last_speed > LAND_MIN_SPEED and e.last_speed - speed > LAND_DROP \
			and _time - e.last_land > LAND_GAP_BODY and _time - _last_land > LAND_GAP_GLOBAL:
		e.last_land = _time
		_last_land = _time
		GameEvents.debris_landed.emit(e.body, e.body.global_position, e.last_speed,
			e.body.get_meta(&"surface", &"concrete"))
	e.last_speed = speed

func _freeze(e: Entry) -> void:
	if e.frozen or not is_instance_valid(e.body):
		return
	e.frozen = true
	e.body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	e.body.set_deferred(&"freeze", true)

func _unfreeze(e: Entry) -> void:
	e.frozen = false
	e.rest = 0.0
	e.age = maxf(e.age, LAND_WATCH_AGE)   # a woken chunk is not re-announced as landing
	if is_instance_valid(e.body):
		e.body.freeze = false
		e.body.sleeping = false

## Standing fighters' feet push rubble: wake frozen debris next to them.
func _wake_by_fighters() -> void:
	var frozen := 0
	for e: Entry in _debris:
		if e.frozen:
			frozen += 1
	if frozen == 0:
		return
	for n in get_tree().get_nodes_in_group(&"fighters"):
		var f := n as Node3D
		if f == null or not f.has_method(&"get_ground_position"):
			continue
		if f.has_method(&"is_dead") and f.call(&"is_dead"):
			continue
		var v: Variant = f.get(&"velocity")
		if v is Vector3 and (v as Vector3).length_squared() < 0.04:
			continue   # standing still: nothing to push
		wake_near(f.call(&"get_ground_position") + Vector3.UP * 0.2, WAKE_RADIUS)

## Fade settled bodies (oldest first) until the pool is within `cap`; a body in
## the air is only faded if the pool overflows by OVERFLOW_HARD.
func _enforce(pool: Array, cap: int) -> void:
	var live := 0
	for e: Entry in pool:
		if not e.fading and not e.keep:
			live += 1
	if live <= cap:
		return
	for e: Entry in pool:
		if live <= cap:
			return
		if not e.fading and not e.keep and is_instance_valid(e.body) and (e.rest >= SETTLED_AFTER or e.frozen):
			_start_fade(e)
			live -= 1
	for e: Entry in pool:
		if live <= cap + OVERFLOW_HARD:
			return
		if not e.fading and not e.keep:
			_start_fade(e)
			live -= 1

func _start_fade(e: Entry) -> void:
	e.fading = true
	e.fade_t = 0.0
	e.visuals.clear()
	if not is_instance_valid(e.body):
		return
	for c in e.body.get_children():
		if c is Node3D and not (c is CollisionShape3D):
			e.visuals.append([c, (c as Node3D).scale])
	e.body.set_deferred(&"freeze", true)
	e.body.set_deferred(&"collision_layer", 0)
	e.body.set_deferred(&"collision_mask", 0)

func _restore_visuals(e: Entry) -> void:
	for pair: Array in e.visuals:
		if is_instance_valid(pair[0]):
			(pair[0] as Node3D).scale = pair[1]
	e.visuals.clear()
	if e.fading and is_instance_valid(e.body):
		e.body.collision_layer = Layers.DEBRIS_SMALL if e.small else Layers.DEBRIS
		e.body.collision_mask = Layers.MASK_DEBRIS_SMALL if e.small else Layers.MASK_DEBRIS

func _free_body(body: RigidBody3D) -> void:
	if is_instance_valid(body) and not body.is_queued_for_deletion():
		body.visible = false
		body.queue_free()
