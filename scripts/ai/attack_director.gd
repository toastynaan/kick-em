extends Node
## Autoload "AttackDirector": attack tokens and rings (spec: Enemies and AI,
## rules 1-6). OWNER: agent C (AI).
##
## 1. Tuning.TOKENS[difficulty] tokens; an enemy needs one to start an attack.
##    It comes back when the attack ends, or the holder is hit, launched,
##    grabbed, dies, or sits on it too long.
## 2. Rings: token holders and the next in line (one per free token, at least
##    one; on-screen enemies first, then who waited longest) are NEAR, the
##    rest FAR. Crowd pacing spaces grants by Tuning.ATTACK_INTERVAL x CROWD_PACE.
## 3. No grants while the player is in hitstun, down (launched / grounded /
##    getting up), held by a grab, or while the camera is busy (follow-cam).
## 4. An enemy must have been inside the camera view for
##    Tuning.ONSCREEN_BEFORE_TOKEN s before it gets a token.
## 5. Tells: GameEvents.attack_tell spawns a TellGlint above the attacker.
## 6. Two holders' first active frames are at least Tuning.SWING_SPACING s
##    apart: grants are staggered, and request_swing() picks a tell length
##    (inside [TELL_MIN, TELL_MAX]) that keeps the active frames spaced.
## All timing here uses now() = TimeDirector.now(): physics ticks / tick rate
## (round 2). In play it equals real time, slow motion does not stretch it,
## and it stays in step with the simulation under --fixed-fps.

enum Ring { NONE, NEAR, FAR }

signal token_granted(enemy: Fighter)
signal token_released(enemy: Fighter)

## A holder that has not started its attack after this many seconds
## loses the token (the brain gives up after 2 s of game time on its own).
const HOLD_TIMEOUT := 2.0
## Minimum seconds between two grants, so holders do not wind up together.
const GRANT_GAP := 0.25
## A holder whose attack started but whose combat no longer reports an attack
## for this long (missed attack_ended) loses its token.
const ATTACK_LOST_GRACE := 0.3
## Step used when searching for a tell length that satisfies the spacing rule.
const TELL_SEARCH_STEP := 0.025
## Crowd pacing: after a grant, the next one waits Tuning.ATTACK_INTERVAL x this
## (s), so a crowd attacks about every 1-1.5 s on Normal, 2-3 s on Easy.
## A lone enemy (duel) and urgent requests (counter, whiff punish) skip it.
const CROWD_PACE := [1.0, 0.5]  ## [easy, normal]
## m: enemies further than this from the player go behind closer ones in line.
const LINE_FAR := 8.0
## Navigation (AINavGrid): path queries allowed per physics tick across all
## enemies, and the delay before re-testing cells round a broken wall (its
## collision shapes are rebuilt the frame after the break).
const NAV_QUERIES_PER_TICK := 3
const NAV_REFRESH_DELAY := 0.25

## Set by the camera while the launch follow-cam runs: no new tokens then.
var camera_busy := false

var _player: Fighter = null
var _enemies: Array[Fighter] = []
## Fighter -> {"granted": float, "active_at": float, "attacking": bool, "started": float}
var _holders: Dictionary = {}
## Fighter -> now() when it entered the camera view, or -1.0 while off screen.
var _onscreen_since: Dictionary = {}
## Fighter -> now() of its last turn end (or registration): line order.
var _last_turn: Dictionary = {}
## Next in line (NEAR without a token): one per free token, at least one.
var _line: Array[Fighter] = []
var _last_grant := -INF
var _next_paced_grant := -INF
var _last_denial: Dictionary = {}  ## Fighter -> String (debugging)
## Shared navigation grid (built at round start, a few rows per tick).
var nav: AINavGrid = null
var _nav_budget := 0
var _nav_refresh: Array = []       ## [due time, centre, radius]
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.fighter_launched.connect(_on_fighter_launched)
	GameEvents.grab_started.connect(_on_grab_started)
	GameEvents.fighter_died.connect(_on_fighter_died)
	GameEvents.attack_tell.connect(_on_attack_tell)
	GameEvents.wall_broken.connect(_on_wall_broken)

func _exit_tree() -> void:
	TellGlint.clear_cache()

func set_player(player: Fighter) -> void:
	_player = player

func register_enemy(enemy: Fighter) -> void:
	if enemy == null or enemy in _enemies:
		return
	_enemies.append(enemy)
	_onscreen_since[enemy] = -1.0
	_last_turn[enemy] = _now()
	if enemy.combat:
		var c := enemy.combat
		if not c.attack_ended.is_connected(_on_enemy_attack_ended):
			c.attack_ended.connect(_on_enemy_attack_ended.bind(enemy))
			c.attack_started.connect(_on_enemy_attack_started.bind(enemy))
			c.attack_incoming.connect(_on_enemy_attack_incoming.bind(enemy))
	if not enemy.tree_exiting.is_connected(unregister_enemy):
		enemy.tree_exiting.connect(unregister_enemy.bind(enemy))

func unregister_enemy(enemy: Fighter) -> void:
	if enemy == null:
		return
	release_token(enemy)
	_enemies.erase(enemy)
	_onscreen_since.erase(enemy)
	_last_turn.erase(enemy)
	_last_denial.erase(enemy)
	_line.erase(enemy)
	if is_instance_valid(enemy):
		if enemy.combat and enemy.combat.attack_ended.is_connected(_on_enemy_attack_ended):
			enemy.combat.attack_ended.disconnect(_on_enemy_attack_ended)
			enemy.combat.attack_started.disconnect(_on_enemy_attack_started)
			enemy.combat.attack_incoming.disconnect(_on_enemy_attack_incoming)
		if enemy.tree_exiting.is_connected(unregister_enemy):
			enemy.tree_exiting.disconnect(unregister_enemy)

## True if `enemy` may start an attack now; it then holds a token until release_token().
## `urgent` (Duelist counter / whiff punish) skips the crowd pacing, never
## the other rules.
func request_token(enemy: Fighter, urgent := false) -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	if _holders.has(enemy):
		if _holders[enemy]["attacking"]:
			return true
		if _enemy_can_attack(enemy) and not is_player_down_or_held():
			return true
		release_token(enemy, _enemy_can_attack(enemy))
		return false
	if not enemy in _enemies:
		register_enemy(enemy)
	var t_now := _now()
	var reason := _denial(enemy, urgent, t_now)
	_last_denial[enemy] = reason
	if reason != "":
		return false
	_holders[enemy] = {"granted": t_now, "active_at": INF, "attacking": false, "started": INF}
	_last_grant = t_now
	var pace: float = CROWD_PACE[clampi(Tuning.difficulty, 0, CROWD_PACE.size() - 1)]
	_next_paced_grant = t_now + _rng.randf_range(Tuning.ATTACK_INTERVAL.x, Tuning.ATTACK_INTERVAL.y) * pace
	_line.erase(enemy)
	token_granted.emit(enemy)
	return true

## Why request_token() would refuse `enemy` now ("" = it would grant).
func _denial(enemy: Fighter, urgent: bool, t_now: float) -> String:
	if not _enemy_can_attack(enemy):
		return "enemy busy"
	var p := get_player()
	if p == null or p.is_dead():
		return "no player"
	if p.is_down():
		return "player down"
	if p.combat and p.combat.held_by != null:
		return "player held"
	if p.is_in_hitstun():
		return "player hitstun"
	if is_camera_busy():
		return "camera busy"
	if _holders.size() >= get_token_count():
		return "no free token"
	if t_now - _last_grant < GRANT_GAP:
		return "grant gap"
	if not urgent and live_enemy_count() > 1 and t_now < _next_paced_grant:
		return "pacing %.1fs" % (_next_paced_grant - t_now)
	if not _onscreen_long_enough(enemy, t_now):
		return "off screen" if _onscreen_since.get(enemy, -1.0) < 0.0 else "on screen < %.1fs" % Tuning.ONSCREEN_BEFORE_TOKEN
	return ""

## Last reason request_token() refused `enemy` ("" if its last request was granted).
func get_last_denial(enemy: Fighter) -> String:
	return _last_denial.get(enemy, "")

## `keep_place`: the token was taken back for a reason that is not the
## enemy's (the player went down or was grabbed), so it keeps its place in
## line. Otherwise (it attacked, gave up, was hit) it goes to the back.
func release_token(enemy: Fighter, keep_place := false) -> void:
	if not _holders.has(enemy):
		return
	var entry: Dictionary = _holders[enemy]
	_holders.erase(enemy)
	if _last_turn.has(enemy) and (not keep_place or entry["attacking"]):
		_last_turn[enemy] = _now()
	token_released.emit(enemy)

func has_token(enemy: Fighter) -> bool:
	return _holders.has(enemy)

## Token holders and the next in line are NEAR; everyone else FAR.
func get_ring(enemy: Fighter) -> int:
	if not enemy in _enemies:
		return Ring.NONE
	if _holders.has(enemy):
		return Ring.NEAR
	if _line.is_empty():
		_update_line()
	return Ring.NEAR if enemy in _line else Ring.FAR

## Enemies currently holding tokens (camera framing).
func get_token_holders() -> Array[Fighter]:
	var out: Array[Fighter] = []
	for e in _holders:
		if is_instance_valid(e):
			out.append(e)
	return out

## Clear all state (round restart).
func reset() -> void:
	camera_busy = false
	for e in _holders.keys():
		release_token(e)
	for e in _enemies.duplicate():
		unregister_enemy(e)
	_holders.clear()
	_enemies.clear()
	_onscreen_since.clear()
	_last_turn.clear()
	_line.clear()
	nav = null
	_nav_refresh.clear()
	_last_grant = -INF
	_next_paced_grant = -INF
	_player = null

# --- Additions (AI module) ---------------------------------------------------

func get_token_count() -> int:
	return Tuning.TOKENS[clampi(Tuning.difficulty, 0, Tuning.TOKENS.size() - 1)]

func get_player() -> Fighter:
	if _player != null and is_instance_valid(_player) and _player.is_inside_tree():
		return _player
	_player = Targeting.player(get_tree())
	return _player

func get_enemies() -> Array[Fighter]:
	return _enemies

func is_registered(enemy: Fighter) -> bool:
	return enemy in _enemies

## Enemies registered and alive (a lone enemy plays more aggressively).
func live_enemy_count() -> int:
	var n := 0
	for e in _enemies:
		if is_instance_valid(e) and not e.is_dead():
			n += 1
	return n

func get_next_in_line() -> Fighter:
	if _line.is_empty():
		_update_line()
	return _line[0] if not _line.is_empty() else null

## Rule 3: the player can be attacked (not in hitstun, not down, not held,
## camera not following a launch).
func is_player_open() -> bool:
	var p := get_player()
	if p == null or p.is_dead():
		return false
	if p.is_in_hitstun() or p.is_down():
		return false
	if p.combat and p.combat.held_by != null:
		return false
	return not is_camera_busy()

## The long rule-3 states: down (launched / grounded / getting up), held, or dead.
## A holder that has not started its attack loses its token in these; during
## the short ones (hitstun, follow-cam) it keeps it but may not swing.
func is_player_down_or_held() -> bool:
	var p := get_player()
	if p == null or p.is_dead() or p.is_down():
		return true
	return p.combat != null and p.combat.held_by != null

func is_camera_busy() -> bool:
	if camera_busy:
		return true
	var rig := get_tree().get_first_node_in_group(&"camera_rig")
	if rig and rig.has_method(&"is_follow_cam_active"):
		return rig.is_follow_cam_active()
	return false

## Rule 4: inside the camera view now (true when there is no camera).
func is_on_screen(enemy: Fighter) -> bool:
	var cam := _camera()
	if cam == null:
		return true
	return _onscreen_since.get(enemy, -1.0) >= 0.0

## Real seconds the enemy has been continuously on screen (INF without a camera).
func onscreen_time(enemy: Fighter) -> float:
	if _camera() == null:
		return INF
	var since: float = _onscreen_since.get(enemy, -1.0)
	return _now() - since if since >= 0.0 else 0.0

## Rule 6. The holder is in range and wants to swing with a tell of
## `preferred_tell` s (plus `extra_startup` s of startup after the tell).
## Returns the tell to pass to start_enemy_attack(), inside
## [TELL_MIN, TELL_MAX] and as close to `preferred_tell` as spacing allows,
## or -1.0 if it must wait (no token, player not open, or no spaced slot).
## A non-negative return reserves that active time until the attack starts
## or the token is released.
func request_swing(enemy: Fighter, preferred_tell: float, extra_startup := 0.0) -> float:
	if not _holders.has(enemy) or not is_player_open():
		return -1.0
	var t_now := _now()
	var pref := clampf(preferred_tell, Tuning.TELL_MIN, Tuning.TELL_MAX)
	var candidates: Array[float] = [pref]
	var step := TELL_SEARCH_STEP
	var up := pref + step
	while up <= Tuning.TELL_MAX + 0.0001:
		candidates.append(minf(up, Tuning.TELL_MAX))
		up += step
	var down := pref - step
	while down >= Tuning.TELL_MIN - 0.0001:
		candidates.append(maxf(down, Tuning.TELL_MIN))
		down -= step
	for tell in candidates:
		var active_at := t_now + tell + extra_startup
		if _swing_is_spaced(enemy, active_at):
			_holders[enemy]["active_at"] = active_at
			return tell
	return -1.0

## The brain started its attack; `time_to_active` is the real seconds until
## the first active frame (combat.time_to_active()).
func notify_attack_started(enemy: Fighter, time_to_active: float) -> void:
	if not _holders.has(enemy):
		return
	var entry: Dictionary = _holders[enemy]
	var t_now := _now()
	entry["attacking"] = true
	entry["started"] = t_now
	if is_finite(time_to_active):
		entry["active_at"] = t_now + time_to_active

## The brain could not start the attack it reserved a slot for.
func cancel_swing(enemy: Fighter) -> void:
	if _holders.has(enemy) and not _holders[enemy]["attacking"]:
		_holders[enemy]["active_at"] = INF

## Scheduled first-active time of a holder's attack (INF if none).
func get_scheduled_active(enemy: Fighter) -> float:
	return _holders[enemy]["active_at"] if _holders.has(enemy) else INF

# --- Internals ---------------------------------------------------------------

func _now() -> float:
	return now()

## The director's clock (see the header). AIBrain uses it too.
func now() -> float:
	return TimeDirector.now()

func _camera() -> Camera3D:
	var vp := get_viewport()
	return vp.get_camera_3d() if vp else null

func _enemy_can_attack(enemy: Fighter) -> bool:
	if enemy.is_dead() or enemy.is_down() or enemy.is_in_hitstun():
		return false
	if enemy.combat and enemy.combat.held_by != null:
		return false
	return true

func _onscreen_long_enough(enemy: Fighter, t_now: float) -> bool:
	if _camera() == null:
		return true
	var since: float = _onscreen_since.get(enemy, -1.0)
	return since >= 0.0 and t_now - since >= Tuning.ONSCREEN_BEFORE_TOKEN

func _swing_is_spaced(enemy: Fighter, active_at: float) -> bool:
	for other in _holders:
		if other == enemy:
			continue
		var t: float = _holders[other]["active_at"]
		if is_finite(t) and absf(t - active_at) < Tuning.SWING_SPACING:
			return false
	return true

func _process(_delta: float) -> void:
	# Rule 4 bookkeeping, per rendered frame (the camera moves in _process).
	var cam := _camera()
	var t_now := _now()
	for e in _enemies:
		if not is_instance_valid(e):
			continue
		var inside := cam == null or cam.is_position_in_frustum(e.get_aim_point())
		if inside:
			if _onscreen_since.get(e, -1.0) < 0.0:
				_onscreen_since[e] = t_now
		else:
			_onscreen_since[e] = -1.0

func _physics_process(_delta: float) -> void:
	_nav_tick()
	var t_now := _now()
	var player_gone := is_player_down_or_held()
	for e in _holders.keys():
		if not is_instance_valid(e):
			_holders.erase(e)
			continue
		var entry: Dictionary = _holders[e]
		var attacking: bool = entry["attacking"]
		if not _enemy_can_attack(e):
			release_token(e)
		elif not attacking and player_gone:
			# Rule 3: an approaching holder does not keep its token while the
			# player is down or held; it asks again later, keeping its place.
			release_token(e, true)
		elif not attacking and t_now - float(entry["granted"]) > HOLD_TIMEOUT:
			release_token(e)
		elif attacking and e.combat and not e.combat.is_attacking() \
				and t_now - float(entry["started"]) > ATTACK_LOST_GRACE:
			release_token(e)
	for e in _enemies.duplicate():
		if not is_instance_valid(e):
			_enemies.erase(e)
			_onscreen_since.erase(e)
			_last_turn.erase(e)
	_update_line()

## Pick the next in line: one enemy per free token (at least one), the
## eligible ones that waited longest (ties: nearest), preferring enemies inside
## the camera view. Members keep their place while eligible, unless off screen
## while someone else is on screen.
func _update_line() -> void:
	var cam := _camera()
	var size := maxi(1, get_token_count() - _holders.size())
	var p := get_player()
	var keep: Array[Fighter] = []
	for e in _line:
		if _line_eligible(e) and (cam == null or _onscreen_since.get(e, -1.0) >= 0.0) \
				and (p == null or e.get_ground_position().distance_to(p.get_ground_position()) <= _line_far(e)):
			keep.append(e)
	var ranked: Array = []  # [key Vector3(off screen or far, last turn, distance), enemy]
	for e in _enemies:
		if not _line_eligible(e) or e in keep:
			continue
		var dist := e.get_ground_position().distance_to(p.get_ground_position()) if p else 0.0
		var off := 0.0 if cam == null or _onscreen_since.get(e, -1.0) >= 0.0 else 1.0
		if dist > _line_far(e):
			off += 0.5  # enemies that could not reach the player soon wait behind closer ones
		var turn: float = _last_turn.get(e, 0.0)
		ranked.append([Vector3(off, snappedf(turn, 0.1), dist), e])
	ranked.sort_custom(func(a: Array, b: Array) -> bool:
		var ka: Vector3 = a[0]
		var kb: Vector3 = b[0]
		if ka.x != kb.x:
			return ka.x < kb.x
		if ka.y != kb.y:
			return ka.y < kb.y
		return ka.z < kb.z)
	# Off-screen members stay only if nobody on screen can take their place.
	for e in _line:
		if _line_eligible(e) and not e in keep and (ranked.is_empty() or ranked[0][0].x > 0.0):
			keep.append(e)
	_line = keep.slice(0, size)
	for r in ranked:
		if _line.size() >= size:
			break
		if not r[1] in _line:
			_line.append(r[1])

## Beyond this distance an enemy waits behind closer ones in line (a
## Thrower attacks from range, so its limit is wider).
func _line_far(e: Fighter) -> float:
	var b := e.brain as AIBrain
	return b.get_line_reach() if b else LINE_FAR

func _line_eligible(e: Fighter) -> bool:
	if not is_instance_valid(e) or not e in _enemies or _holders.has(e):
		return false
	if e.is_dead() or e.is_down():
		return false
	var b := e.brain as AIBrain
	return b == null or b.is_fighting()

# --- Navigation ----------------------------------------------------------------

## Grid ready for path queries.
func nav_ready() -> bool:
	return nav != null and nav.ready

## A path from `from` to `to` (world points), or empty when the grid is not
## ready or this tick's query budget is spent (ask again next tick).
func nav_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	if not nav_ready() or _nav_budget <= 0:
		return PackedVector3Array()
	_nav_budget -= 1
	return nav.find_path(from, to)

func nav_has_budget() -> bool:
	return _nav_budget > 0

## Throw the grid away and build it again (tests that move walls around).
func rebuild_nav() -> void:
	nav = null
	_nav_refresh.clear()

func _nav_tick() -> void:
	_nav_budget = NAV_QUERIES_PER_TICK
	if nav == null:
		if _enemies.is_empty() or get_viewport() == null:
			return
		nav = AINavGrid.new()
		nav.start_build(get_viewport().get_world_3d().direct_space_state)
	if not nav.ready:
		nav.step_build()
		return
	if _nav_refresh.is_empty():
		return
	var t_now := _now()
	var keep: Array = []
	for r: Array in _nav_refresh:
		if t_now >= float(r[0]):
			nav.refresh(r[1], r[2])
		else:
			keep.append(r)
	_nav_refresh = keep

func _on_wall_broken(wall: Node3D, position: Vector3, _energy: float, _velocity: Vector3) -> void:
	var radius := 2.0
	if wall is Destructible:
		var sz: Vector3 = (wall as Destructible).size
		radius = clampf(maxf(sz.x, sz.z) * 0.5 + 0.8, 1.5, 3.0)
	var due := _now() + NAV_REFRESH_DELAY
	_nav_refresh.append([due, position, radius])
	if wall and wall.global_position.distance_to(position) > 1.0:
		_nav_refresh.append([due, wall.global_position, radius])

# --- Events ------------------------------------------------------------------

func _on_enemy_attack_started(_move_id: StringName, enemy: Fighter) -> void:
	if _holders.has(enemy):
		var entry: Dictionary = _holders[enemy]
		entry["attacking"] = true
		if not is_finite(float(entry["started"])):
			entry["started"] = _now()

func _on_enemy_attack_incoming(_move_id: StringName, time_to_active: float, enemy: Fighter) -> void:
	if _holders.has(enemy) and is_finite(time_to_active):
		_holders[enemy]["active_at"] = _now() + time_to_active

func _on_enemy_attack_ended(_move_id: StringName, enemy: Fighter) -> void:
	if _last_turn.has(enemy):
		_last_turn[enemy] = _now()
	release_token(enemy)

func _on_hit_landed(info: HitInfo) -> void:
	if info and info.victim is Fighter:
		release_token(info.victim as Fighter)

func _on_fighter_launched(f: Node3D, _velocity: Vector3) -> void:
	if f is Fighter:
		release_token(f as Fighter)

func _on_grab_started(_grabber: Node3D, victim: Node3D) -> void:
	if victim is Fighter:
		release_token(victim as Fighter)

func _on_fighter_died(f: Node3D, _info: HitInfo) -> void:
	if f is Fighter and f in _enemies:
		unregister_enemy(f as Fighter)

func _on_attack_tell(attacker: Node3D, kind: StringName, duration: float) -> void:
	if attacker is Fighter and _holders.has(attacker):
		var entry: Dictionary = _holders[attacker]
		if not is_finite(float(entry["active_at"])):
			entry["active_at"] = _now() + duration
	TellGlint.spawn(attacker, kind, duration)
