extends Node
## Autoload "DebrisManager": owns every loose debris body (wall chunks, prop
## pieces, severed limbs, thrown chunks).
## OWNER: agent D (world). CONTRACT STUB.
##
## Rules (round 2, tiers from upgrade 2):
## - PERSISTENT bodies (big wall chunks, prop tops, lamp poles, pillar chips,
##   severed limbs, thrown chunks) stay for the round (the arena remembers), at
##   most LARGE_MAX.
## - TIMED bodies fade `life` s after they register: small chunks
##   (Tuning.DEBRIS_FADE_AFTER, Layers.DEBRIS_SMALL) and medium chunks
##   (MEDIUM_LIFE, Layers.DEBRIS). At most Tuning.DEBRIS_MAX together.
##   Only about a quarter of a panel's cells persist, so the persistent pool
##   holds roughly 25 whole-panel breaks before it starts evicting.
## - Over a cap the oldest SETTLED body (at rest for SETTLED_AFTER s) fades out
##   over FADE_TIME. A body in the air is never removed; only if a pool
##   overflows by OVERFLOW_HARD does its oldest body fade regardless.
## - Settled bodies are left to Jolt's sleeping and are never frozen STATIC,
##   so a ragdoll or a fast body that runs into rubble wakes and pushes it.
## - GameEvents.debris_landed when a chunk's speed drops sharply (throttled).
## Ages are game time (they stretch in slow motion like the physics).

signal body_registered(body: RigidBody3D)

const LARGE_MAX := 160          ## persistent bodies (local; candidate for Tuning)
const MEDIUM_LIFE := 30.0       ## s a medium chunk stays (Destructible passes it)
const FADE_TIME := 0.6          ## s of shrink before free
const SETTLE_SPEED := 0.15      ## m/s under which a body counts as at rest
const SETTLED_AFTER := 0.75     ## s at rest -> settled (may be evicted)
const OVERFLOW_HARD := 40       ## a pool this far over its cap fades its oldest anyway
const LAND_DROP := 2.5          ## m/s lost in one tick = a landing
const LAND_MIN_SPEED := 2.5     ## m/s before the drop
const LAND_GAP_GLOBAL := 0.04   ## s between any two debris_landed
const LAND_GAP_BODY := 0.35     ## s between two debris_landed of one body
const LAND_WATCH_AGE := 12.0    ## s after registering a body is watched for landings
const BOOKKEEP_INTERVAL := 0.1  ## s between age / cap sweeps

class Entry:
	var body: RigidBody3D
	var small := false
	var life := -1.0          ## s until it fades; < 0 = persistent
	var age := 0.0
	var rest := 0.0
	var fading := false
	var fade_t := 0.0
	var visuals: Array = []   ## [Node3D, original scale]
	var last_speed := 0.0
	var last_land := -INF

var _large: Array = []        ## Array[Entry], persistent, oldest first
var _small: Array = []        ## Array[Entry], timed (small and medium), oldest first
var _acc := 0.0
var _time := 0.0
var _last_land := -INF

func _ready() -> void:
	process_physics_priority = 50

## Take ownership of a live debris body (already in the tree).
## small: put it on Layers.DEBRIS_SMALL so small chunks skip each other; small
## bodies fade after Tuning.DEBRIS_FADE_AFTER. `life` > 0 makes a large-layer
## body timed too (medium chunks); otherwise large bodies persist for the round.
func register(body: RigidBody3D, small := false, life := -1.0) -> void:
	if body == null or not is_instance_valid(body) or _find(body) != null:
		return
	if small:
		body.collision_layer = Layers.DEBRIS_SMALL
		body.collision_mask = Layers.MASK_DEBRIS_SMALL
	else:
		body.collision_layer = Layers.DEBRIS
		body.collision_mask = Layers.MASK_DEBRIS
	body.freeze = false
	body.can_sleep = true
	body.add_to_group(&"debris")
	body.set_meta(&"debris_small", small)
	var e := Entry.new()
	e.body = body
	e.small = small
	e.life = Tuning.DEBRIS_FADE_AFTER if small and life <= 0.0 else life
	e.last_speed = body.linear_velocity.length()
	var timed := e.life > 0.0
	(_small if timed else _large).append(e)
	_enforce(_small if timed else _large, Tuning.DEBRIS_MAX if timed else LARGE_MAX)
	body_registered.emit(body)

## Live registered bodies (including ones fading out).
func count() -> int:
	return _large.size() + _small.size()

## Large / small pool sizes; include_fading = false counts only bodies that
## are not on their way out.
func count_large(include_fading := true) -> int:
	return _large.size() if include_fading else _active(_large)

func count_small(include_fading := true) -> int:
	return _small.size() if include_fading else _active(_small)

func _active(pool: Array) -> int:
	var n := 0
	for e: Entry in pool:
		if not e.fading:
			n += 1
	return n

## Live, non-fading debris bodies, oldest first (Thrower AI looks for ammo here).
func get_bodies() -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	for pool in [_large, _small]:
		for e: Entry in pool:
			if is_instance_valid(e.body) and not e.fading:
				out.append(e.body)
	return out

## Nearest live, non-fading debris body within `radius` of `pos`, or null.
func find_nearest(pos: Vector3, radius: float, large_only := false) -> RigidBody3D:
	var best: RigidBody3D = null
	var best_d := radius
	for pool in [_large, _small]:
		for e: Entry in pool:
			if e.fading or not is_instance_valid(e.body) or (large_only and e.small):
				continue
			var d := e.body.global_position.distance_to(pos)
			if d < best_d:
				best_d = d
				best = e.body
	return best

## Stop managing a body (e.g. the Thrower picked it up). The caller owns it now.
func release(body: RigidBody3D) -> void:
	for pool in [_large, _small]:
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

## Free all debris (round restart).
func reset() -> void:
	for pool in [_large, _small]:
		for e: Entry in pool:
			_free_body(e.body)
		pool.clear()

func _find(body: RigidBody3D) -> Entry:
	for pool in [_large, _small]:
		for e: Entry in pool:
			if e.body == body:
				return e
	return null

func _physics_process(delta: float) -> void:
	_time += delta
	_acc += delta
	var bookkeep := _acc >= BOOKKEEP_INTERVAL
	var dt_book := _acc
	if bookkeep:
		_acc = 0.0
	for pool in [_large, _small]:
		var i := 0
		while i < pool.size():
			var e: Entry = pool[i]
			# Settled, old bodies are only re-checked on bookkeeping ticks (a hit
			# wakes them; the next sweep resets their rest time). Checked before
			# touching the body so the common case costs two field reads.
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
			_watch(e, dt_book if bookkeep and e.rest >= SETTLED_AFTER and e.age >= LAND_WATCH_AGE else delta)
			if bookkeep:
				e.age += dt_book
				if e.life > 0.0 and e.age >= e.life:
					_start_fade(e)
			i += 1
	if bookkeep:
		_enforce(_large, LARGE_MAX)
		_enforce(_small, Tuning.DEBRIS_MAX)

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

## Fade settled bodies (oldest first) until the pool is within `cap`; a body in
## the air is only faded if the pool overflows by OVERFLOW_HARD.
func _enforce(pool: Array, cap: int) -> void:
	var live := 0
	for e: Entry in pool:
		if not e.fading:
			live += 1
	if live <= cap:
		return
	for e: Entry in pool:
		if live <= cap:
			return
		if not e.fading and is_instance_valid(e.body) and e.rest >= SETTLED_AFTER:
			_start_fade(e)
			live -= 1
	for e: Entry in pool:
		if live <= cap + OVERFLOW_HARD:
			return
		if not e.fading:
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
