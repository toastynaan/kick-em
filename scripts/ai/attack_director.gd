extends Node
## Autoload "AttackDirector": attack tokens, rings and swing spacing (Feel
## Reference: Enemies have to be readable first; original spec rules 1-6).
## OWNER: agent C (AI).
##
## 1. At most Tuning.TOKEN_MAX tokens (Easy: Tuning.TOKENS[0]); an enemy needs
##    one to start an attack. It comes back when the attack ends (a string's
##    follow-up keeps it), or the holder is hit out of its attack, launched,
##    grabbed, dies, starts fleeing, or sits on it too long.
## 2. Rings: token holders and the next in line (one per free token plus one
##    standby; on-screen enemies first, then who waited longest) are NEAR, the
##    rest FAR. Everyone waiting circles in Tuning.CIRCLE_RING (the brain picks
##    the radius). Crowd pacing spaces grants by Tuning.ATTACK_INTERVAL x CROWD_PACE.
## 3. No grants while the player is in hitstun, down (launched / grounded /
##    getting up), held by a grab, or while the camera is busy (follow-cam).
##    While the player is knocked down, holders keep their token and get
##    Tuning.DOWNED_FREE_SWINGS free swings at him; the rest wait.
## 4. An enemy must have been inside the camera view for
##    Tuning.ONSCREEN_BEFORE_TOKEN s before it gets a token.
## 5. Tells: GameEvents.attack_tell spawns a TellGlint from wind-up to first
##    active frame: orange on the striking limb when the player can Counter
##    it, blue (both hands for grabs, the shoulder for the heavy's charge)
##    when only a dodge answers it (MoveData.counterable).
## 6. Two holders' first active frames are at least Tuning.TOKEN_ACTIVE_GAP
##    apart by design (plus ACTIVE_GAP_MARGIN): every swing reserves its first
##    active frame (a string reserves each hit's), and request_swing() refuses
##    a swing whose active frame would land inside another holder's gap. The
##    enemy then waits a beat; its startup itself never changes, so each move
##    always has the same, learnable timing.
## Enemy startup: enemy_startup_frames() (Tuning.ENEMY_STARTUP, faster from
## Tuning.ENEMY_STARTUP_SHRINK_FROM; set_wave() at each wave start). Round 7:
## never under tell_min_frames(), so every tell outlasts the player's counter
## window (Tuning.R7_COUNTER_WINDOW) by Tuning.R7_TELL_MARGIN, at every wave.
## Round 7 freeflow: an enemy in a reaction state (Fighter.is_reacting /
## is_lifted), held, down or in hitstun gets no token, loses a held one
## (unless its attack is still live: tell armor) and leaves the line, so the
## enemies the player is not hitting keep coming.
## Round 8 (docs/Round 8 — Charge and Pressure.md): a tap's flinch (react
## &"flinch", about 0.2 s; is_flinching) is shrugged off: the enemy keeps its
## token, its place in line and its turn, and a wind-up the tap cut short
## just starts again once the flinch is over. Broken open by pressure
## (is_enemy_broken) counts as impaired: no token, out of the line. A brain
## that backs off under pressure (AIBrain.is_backing_off) leaves the line.
## Clocks: world_now() (scaled game time, the enemies' own time) for token
## timeouts, grant gaps, pacing and swing spacing; now() = TimeDirector.now()
## (real time, physics ticks) for the on-screen rule. B reports time to the
## active frame in real seconds; it is converted to world time here.

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
## Frames (s) added to Tuning.TOKEN_ACTIVE_GAP when scheduling. A heavy keeps
## winding up through flinches (ignore_flinch) and each flinch hitstop (0.04 s)
## pushes his active frame back; this margin keeps two such delays from
## squeezing two hits into one parry window.
const ACTIVE_GAP_MARGIN := 4.0 / 60.0
## A string's follow-up reservation is an estimate (the first hit's recovery
## is cut when it lands); it is held this much wider on each side.
const FOLLOWUP_SLACK := 4.0 / 60.0
## Crowd pacing: after a grant, the next one waits Tuning.ATTACK_INTERVAL x this
## (s), so a crowd attacks about every 1-1.5 s on Normal, 2-3 s on Easy.
## A lone enemy (duel) and urgent requests (counter, whiff punish) skip it.
const CROWD_PACE := [1.0, 0.45]  ## [easy, normal]
## s: an enemy that asked within this long counts as waiting in line.
const LINE_ASK_WINDOW := 0.6
## m: enemies further than this from the player go behind closer ones in line.
const LINE_FAR := 8.0
## Navigation (AINavGrid): path queries allowed per physics tick across all
## enemies, and the delay before re-testing cells round a broken wall (its
## collision shapes are rebuilt the frame after the break).
const NAV_QUERIES_PER_TICK := 2
const NAV_REFRESH_DELAY := 0.25
## Cells re-tested per tick in a slow background sweep (a full 93x93 grid every
## ~6 s, ~25 us per tick), so props, crates and walls that move, break or
## appear (the Yard's low walls, crates and platform) reach the grid without
## an event.
const NAV_SWEEP_CELLS := 12
## Waypoint searches (AIBrain._find_waypoint: many sweeps) allowed per tick.
const ROUTE_SEARCHES_PER_TICK := 1
# Round 6: the world changes under the grid (clutter, structure).
## s between polls of breakables that change without an event: static clutter
## knocked loose (its collision goes), rigid props on Layers.DESTRUCTIBLE that
## capsules bump into and that get shoved about.
const DYNAMIC_POLL := 0.5
const DYNAMIC_MOVE := 0.3            ## m a polled obstacle may move before its cells are re-tested
const DYNAMIC_RADIUS := 1.2          ## m re-tested round a changed clutter object
const BREAK_RADIUS := 1.6            ## m re-tested round furniture_broken
const COLLAPSE_RADIUS := 2.5         ## m re-tested round structure_collapsed...
const COLLAPSE_AGAIN := 1.5          ## ...and again this long after (what fell has come down)
## Hazards waiting enemies keep out of (optional Round 6 polish): the floor
## where glass broke (shards) and the footprint under a cracked pillar's beam.
const GLASS_HAZARD_RADIUS := 1.0
const BEAM_HAZARD_MARGIN := 0.7      ## m beyond the beam's footprint
const BEAM_HALF_LENGTH := 1.1        ## m (Pillar.HEAD_LENGTH / 2)
const HAZARD_MAX := 32
const HAZARD_TURN := 20.0            ## degrees per step a ring spot rotates out of a hazard
## Startup frames of legacy enemy moves Tuning.ENEMY_STARTUP does not list
## (their Upgrade 2 tells): kept for the legacy archetypes' tests.
const LEGACY_STARTUP := {&"e_throw_debris": 30.0, &"e_sweep": 26.0}

## Set by the camera while the launch follow-cam runs: no new tokens then.
var camera_busy := false
## 1-based current wave (0 = Duel / none); enemy startup shrinks from
## Tuning.ENEMY_STARTUP_SHRINK_FROM.
var wave_index := 0

var _player: Fighter = null
var _enemies: Array[Fighter] = []
## Fighter -> {"granted": float, "active_at": float, "attacking": bool, "started": float,
##             "reserved": Array[float] (later hits of a string), "followup": bool}
var _holders: Dictionary = {}
## [world time, Fighter] of recent first active frames (spacing across releases).
var _recent_actives: Array = []
## Fighter -> now() when it entered the camera view, or -1.0 while off screen.
var _onscreen_since: Dictionary = {}
## Fighter -> now() of its last turn end (or registration): line order.
var _last_turn: Dictionary = {}
## Next in line (NEAR without a token): one per free token, at least one.
var _line: Array[Fighter] = []
var _last_grant := -INF
var _next_paced_grant := -INF
var _last_denial: Dictionary = {}  ## Fighter -> String (debugging)
var _last_request: Dictionary = {} ## Fighter -> world time of its last token request
## Fighter -> swings it started at the player during the current knockdown.
var _down_swings: Dictionary = {}
## Shared navigation grid (built at round start, a few rows per tick).
var nav: AINavGrid = null
var _nav_budget := 0
var _route_budget := 0
var _nav_refresh: Array = []       ## [due time, centre, radius]
var _rng := RandomNumberGenerator.new()
var _world_time := 0.0
var _next_slot := 0
var _dyn_poll_at := 0.0
var _dyn_tracked := {}               ## CollisionObject3D -> [position, collision_layer]
var _glass_hazards: Array[Vector3] = []
var _beam_hazards: Array = []        ## [centre (flat), axis (flat unit)] under cracked pillars' beams
## Closest gap (world s) between first active frames of different enemies
## since the last reset (soak tests; INF before two).
var min_active_gap := INF
## Crowd-pacing slots given back by holders knocked out of their turn (tests).
var paced_refunds := 0
## Round 8: holders whose wind-up a tap's flinch cut short and that kept their turn.
var flinch_keeps := 0
var _last_active_t := -INF
var _last_active_by: Node3D = null

func _ready() -> void:
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.fighter_launched.connect(_on_fighter_launched)
	GameEvents.grab_started.connect(_on_grab_started)
	GameEvents.fighter_died.connect(_on_fighter_died)
	GameEvents.attack_tell.connect(_on_attack_tell)
	GameEvents.attack_active.connect(_on_attack_active)
	GameEvents.wall_broken.connect(_on_wall_broken)
	GameEvents.wall_broken_by.connect(_on_wall_broken_by)
	GameEvents.wave_started.connect(_on_wave_started)
	GameEvents.fleeing_changed.connect(_on_fleeing_changed)
	GameEvents.carry_changed.connect(_on_carry_changed)
	GameEvents.furniture_broken.connect(_on_furniture_broken)
	GameEvents.structure_collapsed.connect(_on_structure_collapsed)
	GameEvents.dazed.connect(func(f: Node3D, _d: float) -> void: _drop(f))
	GameEvents.stumbled.connect(func(f: Node3D, _d: float) -> void: _drop(f))
	GameEvents.tripped.connect(func(f: Node3D) -> void: _drop(f))

func _exit_tree() -> void:
	TellGlint.clear_cache()

func set_player(player: Fighter) -> void:
	_player = player

func register_enemy(enemy: Fighter) -> void:
	if enemy == null or enemy in _enemies:
		return
	_enemies.append(enemy)
	_onscreen_since[enemy] = -1.0
	_last_turn[enemy] = world_now()
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
	_last_request.erase(enemy)
	_down_swings.erase(enemy)
	_line.erase(enemy)
	if is_instance_valid(enemy):
		if enemy.combat and enemy.combat.attack_ended.is_connected(_on_enemy_attack_ended):
			enemy.combat.attack_ended.disconnect(_on_enemy_attack_ended)
			enemy.combat.attack_started.disconnect(_on_enemy_attack_started)
			enemy.combat.attack_incoming.disconnect(_on_enemy_attack_incoming)
		if enemy.tree_exiting.is_connected(unregister_enemy):
			enemy.tree_exiting.disconnect(unregister_enemy)

## True if `enemy` may start an attack now; it then holds a token until release_token().
## `urgent` (the Duelist's answer to a broken guard, its whiff punish) skips
## the crowd pacing and the turn order; `cut_line` (a Brawler punishing a
## blocker) skips only the turn order. Neither skips rules 1-6.
func request_token(enemy: Fighter, urgent := false, cut_line := false) -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	if _holders.has(enemy):
		if _holders[enemy]["attacking"]:
			return true
		if keeps_turn(enemy) and (not is_player_down_or_held() or _may_swing_at_downed(enemy)):
			return true
		release_token(enemy, _enemy_can_attack(enemy))
		return false
	if not enemy in _enemies:
		register_enemy(enemy)
	var t_now := world_now()
	_last_request[enemy] = t_now
	var reason := _denial(enemy, urgent, t_now, cut_line)
	_last_denial[enemy] = reason
	if reason != "":
		return false
	var none: Array[float] = []
	_holders[enemy] = {"granted": t_now, "active_at": INF, "attacking": false, "started": INF,
		"reserved": none, "followup": false}
	_last_grant = t_now
	var pace: float = CROWD_PACE[clampi(Tuning.difficulty, 0, CROWD_PACE.size() - 1)]
	_next_paced_grant = t_now + _rng.randf_range(Tuning.ATTACK_INTERVAL.x, Tuning.ATTACK_INTERVAL.y) * pace
	_line.erase(enemy)
	token_granted.emit(enemy)
	return true

## Why request_token() would refuse `enemy` now ("" = it would grant).
func _denial(enemy: Fighter, urgent: bool, t_now: float, cut_line := false) -> String:
	if not _enemy_can_attack(enemy):
		return "fleeing" if _is_fleeing(enemy) else "enemy busy"
	var p := get_player()
	if p == null or p.is_dead():
		return "no player"
	if p.is_down():
		return "player down"
	if _player_held(p):
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
	if not urgent and not cut_line:
		var first := _waiting_ahead_of(enemy, t_now)
		if first != null:
			return "line: %s first" % first.name
	if not _onscreen_long_enough(enemy, _now()):
		return "off screen" if _onscreen_since.get(enemy, -1.0) < 0.0 else "on screen < %.1fs" % Tuning.ONSCREEN_BEFORE_TOKEN
	return ""

## Turn order among enemies that are actually asking: another enemy that
## waited longer (older last turn) and asked within LINE_ASK_WINDOW goes
## first, so a slow enemy (Heavy) is not starved by quick ones.
func _waiting_ahead_of(enemy: Fighter, t_now: float) -> Fighter:
	var mine: float = _last_turn.get(enemy, 0.0)
	for e in _enemies:
		if e == enemy or not is_instance_valid(e) or _holders.has(e):
			continue
		if t_now - float(_last_request.get(e, -INF)) > LINE_ASK_WINDOW:
			continue
		if float(_last_turn.get(e, 0.0)) < mine - 0.05 and _enemy_can_attack(e) \
				and _onscreen_long_enough(e, _now()):
			return e
	return null

## Last reason request_token() refused `enemy` ("" if its last request was granted).
func get_last_denial(enemy: Fighter) -> String:
	return _last_denial.get(enemy, "")

## `keep_place`: the token was taken back for a reason that is not the
## enemy's (the player went down or was grabbed), so it keeps its place in
## line. Otherwise (it attacked, gave up, was hit) it goes to the back.
## Round 7 freeflow: a holder the player knocks out of its turn before it
## swings (hit, reacting, held, down, dead) gives back its crowd-pacing slot
## too, so the next enemy comes at once (after GRANT_GAP); the crowd never
## attacks faster than the pacing, since that turn produced no attack.
func release_token(enemy: Fighter, keep_place := false) -> void:
	if not _holders.has(enemy):
		return
	var entry: Dictionary = _holders[enemy]
	_holders.erase(enemy)
	if _last_turn.has(enemy) and (not keep_place or entry["attacking"]):
		_last_turn[enemy] = world_now()
	if not entry["attacking"] and is_instance_valid(enemy) and not _enemy_can_attack(enemy):
		_next_paced_grant = minf(_next_paced_grant, world_now() + GRANT_GAP)
		paced_refunds += 1
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

# --- Round 5: waves and enemy startup ------------------------------------------

## GameMode (J) calls this at each wave start with the 1-based wave number.
## GameEvents.wave_started (0-based index) sets it too, so it stays right
## whichever lands first.
func set_wave(index: int) -> void:
	wave_index = maxi(index, 0)

## Enemy startup frames for `move_id` this wave: Tuning.ENEMY_STARTUP; early in
## a run never under Tuning.ENEMY_STARTUP_EARLY_MIN; from wave
## Tuning.ENEMY_STARTUP_SHRINK_FROM, Tuning.ENEMY_STARTUP_SHRINK frames faster
## per wave, never under Tuning.ENEMY_STARTUP_MIN. Moves the table does not
## list (legacy archetypes) keep their old tells (LEGACY_STARTUP). Round 7:
## never under tell_min_frames() at any wave or in Duel (wave 0).
func enemy_startup_frames(move_id: StringName) -> float:
	var f: float = Tuning.ENEMY_STARTUP.get(move_id, LEGACY_STARTUP.get(move_id, Tuning.ENEMY_STARTUP_EARLY_MIN))
	if wave_index >= Tuning.ENEMY_STARTUP_SHRINK_FROM:
		f -= Tuning.ENEMY_STARTUP_SHRINK * float(wave_index - Tuning.ENEMY_STARTUP_SHRINK_FROM + 1)
		f = maxf(f, Tuning.ENEMY_STARTUP_MIN)
	else:
		f = maxf(f, Tuning.ENEMY_STARTUP_EARLY_MIN)
	return maxf(f, tell_min_frames())

## Round 7: the shortest enemy tell, in frames of the enemy's own time: the
## player's counter window plus the margin before it opens
## (Tuning.R7_COUNTER_WINDOW + Tuning.R7_TELL_MARGIN), rounded up to a whole
## frame.
static func tell_min_frames() -> float:
	return ceilf((Tuning.R7_COUNTER_WINDOW + Tuning.R7_TELL_MARGIN) * Tuning.FPS - 1e-4)

## The same in seconds of the enemy's own time.
func enemy_startup_s(move_id: StringName) -> float:
	return Tuning.frames(enemy_startup_frames(move_id))

## Minimum world seconds kept between two holders' first active frames.
func active_gap() -> float:
	return Tuning.TOKEN_ACTIVE_GAP + ACTIVE_GAP_MARGIN

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
	_recent_actives.clear()
	_down_swings.clear()
	nav = null
	_nav_refresh.clear()
	_dyn_tracked.clear()
	_glass_hazards.clear()
	_beam_hazards.clear()
	_last_grant = -INF
	_next_paced_grant = -INF
	_player = null
	wave_index = 0
	min_active_gap = INF
	paced_refunds = 0
	flinch_keeps = 0
	_last_active_t = -INF
	_last_active_by = null

# --- Additions (AI module) ---------------------------------------------------

func get_token_count() -> int:
	return mini(Tuning.TOKENS[clampi(Tuning.difficulty, 0, Tuning.TOKENS.size() - 1)], Tuning.TOKEN_MAX)

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

## A small integer per brain (registration order), so periodic work (path
## re-plans, route searches) is spread over different ticks.
func claim_slot() -> int:
	_next_slot += 1
	return _next_slot

## Rule 3: the player can be attacked (not in hitstun, not down, not held,
## camera not following a launch).
func is_player_open() -> bool:
	var p := get_player()
	if p == null or p.is_dead():
		return false
	if p.is_in_hitstun() or p.is_down():
		return false
	if _player_held(p):
		return false
	return not is_camera_busy()

## The long rule-3 states: down (launched / grounded / getting up), held, or dead.
## A holder that has not started its attack loses its token while the player
## is held; while he is down it keeps it for its free swing (DOWNED_FREE_SWINGS).
func is_player_down_or_held() -> bool:
	var p := get_player()
	if p == null or p.is_dead() or p.is_down():
		return true
	return _player_held(p)

## The player is on the ground after a knockdown (not held, not dead).
func is_player_knocked_down() -> bool:
	var p := get_player()
	return p != null and not p.is_dead() and p.is_down() and not _player_held(p)

func _player_held(p: Fighter) -> bool:
	return p.carry != null and p.carry.is_held()

## Free swings `enemy` has left at the knocked-down player.
func free_swings_left(enemy: Fighter) -> int:
	return maxi(Tuning.DOWNED_FREE_SWINGS - int(_down_swings.get(enemy, 0)), 0)

## A holder may swing at the knocked-down player: a free swing left, the
## player not in his get-up invulnerability.
func _may_swing_at_downed(enemy: Fighter) -> bool:
	if not is_player_knocked_down() or free_swings_left(enemy) <= 0:
		return false
	var p := get_player()
	return not p.is_invulnerable() and not is_camera_busy()

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

## Rule 6. The holder is in range and wants to start a move whose startup is
## `startup` s (its own time; AIBrain passes enemy_startup_s()). `followups`
## are the expected first active frames of a string's later hits, in s after
## this one's. Returns `startup` if every one of those active frames is at
## least active_gap() from every other holder's (and from any active frame in
## the last active_gap()), else -1.0: the enemy waits a beat and asks again.
## Also -1.0 with no token or while the player is not open (a holder may still
## take its free swing at a knocked-down player). A non-negative return
## reserves those active frames until the attack starts or the token goes.
## The startup is never stretched: each move keeps its learnable timing.
func request_swing(enemy: Fighter, startup: float, followups: Array = []) -> float:
	if not _holders.has(enemy):
		return -1.0
	if _holders[enemy].has("cut"):
		return -1.0  # its wind-up was just cut short: kept only if a flinch did it (next tick)
	if not is_player_open() and not _may_swing_at_downed(enemy):
		return -1.0
	var t_now := world_now()
	var first := t_now + maxf(startup, 0.0)
	var times: Array[float] = [first]
	for off: float in followups:
		times.append(first + off)
	if not _swing_is_spaced(enemy, times, FOLLOWUP_SLACK if followups.size() > 0 else 0.0):
		return -1.0
	var entry: Dictionary = _holders[enemy]
	entry["active_at"] = first
	var rest: Array[float] = []
	for i in range(1, times.size()):
		rest.append(times[i])
	entry["reserved"] = rest
	return startup

## The brain started its attack; `time_to_active` is the real seconds until
## the first active frame (combat.time_to_active()). `followup` marks a
## string's later hit (it keeps the token past the previous hit's end).
func notify_attack_started(enemy: Fighter, time_to_active: float) -> void:
	if not _holders.has(enemy):
		return
	var entry: Dictionary = _holders[enemy]
	var t_now := world_now()
	entry["attacking"] = true
	entry["started"] = t_now
	entry["followup"] = false
	entry["went_active"] = false
	if is_finite(time_to_active):
		entry["active_at"] = t_now + time_to_active * Engine.time_scale
	if is_player_knocked_down():
		_down_swings[enemy] = int(_down_swings.get(enemy, 0)) + 1

## The brain could not start the attack it reserved a slot for.
func cancel_swing(enemy: Fighter) -> void:
	if _holders.has(enemy) and not _holders[enemy]["attacking"]:
		var none: Array[float] = []
		_holders[enemy]["active_at"] = INF
		_holders[enemy]["reserved"] = none

## The holder's string continues: keep the token when its current attack ends
## (AIBrain calls this before the follow-up; attack_ended would release it).
func hold_for_followup(enemy: Fighter) -> void:
	if _holders.has(enemy):
		_holders[enemy]["followup"] = true

## Scheduled first-active time of a holder's attack (INF if none).
func get_scheduled_active(enemy: Fighter) -> float:
	return _holders[enemy]["active_at"] if _holders.has(enemy) else INF

## Scheduled first-active times of a holder's string hits after the first.
func get_reserved_actives(enemy: Fighter) -> Array:
	return (_holders[enemy]["reserved"] as Array).duplicate() if _holders.has(enemy) else []

# --- Internals ---------------------------------------------------------------

func _now() -> float:
	return now()

## Real (unscaled) clock: what the player perceives (on-screen rule).
func now() -> float:
	return TimeDirector.now()

## World clock: scaled game time, the time enemies live in. Token timeouts,
## grant gaps, pacing and swing spacing use it, so a long slow motion (a
## finisher, a KO) neither times out a slowed enemy nor squeezes two swings
## together when the world speeds up again (a world-time gap is never shorter
## in real time while time_scale <= 1).
func world_now() -> float:
	return _world_time

func _camera() -> Camera3D:
	var vp := get_viewport()
	return vp.get_camera_3d() if vp else null

func _enemy_can_attack(enemy: Fighter) -> bool:
	if enemy.is_dead() or enemy.is_down() or enemy.is_in_hitstun():
		return false
	if _is_fleeing(enemy):
		return false
	return not is_enemy_impaired(enemy)

## The holder's attack is still running (startup to recovery) and it is on its
## feet: an armored tell takes a hit (Round 7: a tapped punch's small snap)
## and keeps swinging, so it keeps its token and its reserved active frame.
func _swing_live(enemy: Fighter) -> bool:
	return enemy.combat != null and enemy.combat.is_attacking() and not enemy.is_down() and not enemy.is_dead()

func _is_fleeing(enemy: Fighter) -> bool:
	return enemy.has_method(&"is_fleeing") and enemy.is_fleeing()

## States that keep an enemy out of the rotation: held by a grab, a Round 7
## reaction (snap, spin, fold, buckle, push, or popped up by a lift), the
## Upgrade 2 daze and stumble (tripped enemies are down), and Round 8's
## pressure break (is_enemy_broken).
func is_enemy_impaired(enemy: Fighter) -> bool:
	if enemy.carry != null and enemy.carry.is_held():
		return true
	if enemy.is_reacting() or enemy.is_lifted():
		return true
	if is_enemy_broken(enemy):
		return true
	var c := enemy.combat
	if c == null:
		return false
	if c.has_method(&"is_dazed") and c.is_dazed():
		return true
	return c.has_method(&"is_stumbling") and c.is_stumbling()

## Round 8: broken open by pressure (B's CombatController.is_broken(), H's
## &"broken" reaction): dazed for Tuning.R8_BREAK_TIME, no attack, no guard,
## no token. A hit's reaction may play over it; the break still counts.
static func is_enemy_broken(enemy: Fighter) -> bool:
	if enemy.get_react_state() == &"broken":
		return true
	return enemy.combat != null and enemy.combat.is_broken()

## Round 8: in a tap's flinch (react &"flinch", about 0.2 s), or the
## ragdoll's own flinch tier with no other reaction (it can outlast the
## react by a few frames). Taps barely stun: the enemy shrugs it off.
static func is_flinching(enemy: Fighter) -> bool:
	var state := enemy.get_react_state()
	if state == &"flinch":
		return true
	return state == &"" and enemy.get_state() == RagdollController.State.FLINCH

## Can attack now, or the moment a tap's flinch is over: a flinching enemy
## keeps its token and its place in line (Round 8). Anything more (another
## reaction, down, held, fleeing, broken, dazed, stumbling) ends its turn.
func keeps_turn(enemy: Fighter) -> bool:
	if _enemy_can_attack(enemy):
		return true
	if not is_flinching(enemy) or enemy.is_dead() or enemy.is_down() or _is_fleeing(enemy):
		return false
	if enemy.carry != null and enemy.carry.is_held():
		return false
	if is_enemy_broken(enemy):
		return false
	var c := enemy.combat
	if c != null and ((c.has_method(&"is_dazed") and c.is_dazed()) or (c.has_method(&"is_stumbling") and c.is_stumbling())):
		return false
	return true

func _onscreen_long_enough(enemy: Fighter, t_now: float) -> bool:
	if _camera() == null:
		return true
	var since: float = _onscreen_since.get(enemy, -1.0)
	return since >= 0.0 and t_now - since >= Tuning.ONSCREEN_BEFORE_TOKEN

## Every time in `times` is at least active_gap() from every other holder's
## reserved active frames and from any first active frame that happened in
## the last active_gap(). Estimated times (a string's later hits, ours with
## `slack`, theirs always) are kept FOLLOWUP_SLACK further.
func _swing_is_spaced(enemy: Fighter, times: Array[float], slack := 0.0) -> bool:
	var gap := active_gap()
	for other in _holders:
		if other == enemy:
			continue
		var entry: Dictionary = _holders[other]
		var theirs: Array[Vector2] = []  # (time, extra gap)
		if is_finite(float(entry["active_at"])):
			theirs.append(Vector2(float(entry["active_at"]), 0.0))
		for r: float in entry["reserved"]:
			theirs.append(Vector2(r, FOLLOWUP_SLACK))
		for i in times.size():
			var g := gap + (slack if i > 0 else 0.0)
			for t: Vector2 in theirs:
				if absf(t.x - times[i]) < g + t.y:
					return false
	for rec: Array in _recent_actives:
		if rec[1] == enemy:
			continue
		for t: float in times:
			if absf(float(rec[0]) - t) < gap:
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

func _physics_process(delta: float) -> void:
	_world_time += delta
	_nav_tick()
	_route_budget = ROUTE_SEARCHES_PER_TICK
	var t_now := world_now()
	var knocked_down := is_player_knocked_down()
	var player_gone := is_player_down_or_held()
	if not knocked_down:
		_down_swings.clear()
	for e in _holders.keys():
		if not is_instance_valid(e):
			_holders.erase(e)
			continue
		var entry: Dictionary = _holders[e]
		var attacking: bool = entry["attacking"]
		if entry.has("cut"):
			# Its wind-up ended before the active frames (_on_enemy_attack_ended):
			# a tap's flinch keeps the turn (it swings again once free);
			# anything else ends it as a used turn.
			entry.erase("cut")
			if is_flinching(e) and keeps_turn(e):
				var none: Array[float] = []
				entry["attacking"] = false
				entry["started"] = INF
				entry["active_at"] = INF
				entry["reserved"] = none
				entry["granted"] = t_now
				flinch_keeps += 1
			else:
				release_token(e)
			continue
		if not keeps_turn(e) and not (attacking and _swing_live(e)):
			release_token(e)
		elif not attacking and player_gone and not (knocked_down and free_swings_left(e) > 0):
			# Rule 3: an approaching holder does not keep its token while the
			# player is held (or down with its free swing used); it asks again
			# later, keeping its place.
			release_token(e, true)
		elif not attacking and t_now - float(entry["granted"]) > HOLD_TIMEOUT:
			release_token(e)
		elif attacking and e.combat and not e.combat.is_attacking() \
				and t_now - float(entry["started"]) > ATTACK_LOST_GRACE and not entry["followup"]:
			release_token(e)
		elif attacking and e.combat and e.combat.is_attacking():
			# Keep the reservation true to the real active frame (a hitstop on
			# a heavy that winds up through a flinch pushes it back).
			var tta: float = e.combat.time_to_active()
			if is_finite(tta) and tta > 0.0:
				entry["active_at"] = t_now + tta * Engine.time_scale
	for e in _enemies.duplicate():
		if not is_instance_valid(e):
			_enemies.erase(e)
			_onscreen_since.erase(e)
			_last_turn.erase(e)
	var keep: Array = []
	for rec: Array in _recent_actives:
		if t_now - float(rec[0]) < active_gap() + 0.05:
			keep.append(rec)
	_recent_actives = keep
	_update_line()

## Pick the next in line: one enemy per free token plus one standby (just one
## when every token is out), the eligible ones that waited longest (ties:
## nearest), preferring enemies inside the camera view. Members keep their
## place while eligible, unless off screen while someone else is on screen.
func _update_line() -> void:
	var cam := _camera()
	# One per free token plus one on standby, so a ready enemy is waiting
	# when the pacing opens (with every token out: just the next one).
	var free_tokens := get_token_count() - _holders.size()
	var size := free_tokens + 1 if free_tokens > 0 else 1
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

## In line: registered, fighting, and able to attack now. An enemy the player
## is hitting (a reaction, hitstun, held) steps out, so another one moves up
## and takes the next turn (freeflow: the crowd keeps coming). Round 8: a
## tap's flinch keeps its place; backing off under pressure gives it up.
func _line_eligible(e: Fighter) -> bool:
	if not is_instance_valid(e) or not e in _enemies or _holders.has(e):
		return false
	if not keeps_turn(e):
		return false
	var b := e.brain as AIBrain
	return b == null or (b.is_fighting() and not b.is_backing_off())

# --- Navigation ----------------------------------------------------------------

## Grid ready for path queries.
func nav_ready() -> bool:
	return nav != null and nav.ready

## A path from `from` to `to` (world points), or empty when the grid is not
## ready or this tick's query budget is spent (ask again next tick).
func nav_path(from: Vector3, to: Vector3, wide := false) -> PackedVector3Array:
	if not nav_ready() or _nav_budget <= 0:
		return PackedVector3Array()
	_nav_budget -= 1
	return nav.find_path(from, to, wide)

func nav_has_budget() -> bool:
	return _nav_budget > 0

## One waypoint search (AIBrain._find_waypoint) this tick; false = try next tick.
func take_route_budget() -> bool:
	if _route_budget <= 0:
		return false
	_route_budget -= 1
	return true

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
	nav.sweep_step(NAV_SWEEP_CELLS)
	nav.expire_penalties()
	if _now() >= _dyn_poll_at:
		_dyn_poll_at = _now() + DYNAMIC_POLL
		_poll_dynamic()
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

## Re-test the grid round `position` shortly (a wall, crate or prop changed).
func queue_nav_refresh(position: Vector3, radius: float) -> void:
	_nav_refresh.append([_now() + NAV_REFRESH_DELAY, position, radius])

func _on_wall_broken(wall: Node3D, position: Vector3, _energy: float, _velocity: Vector3) -> void:
	var radius := 2.0
	if wall is Destructible:
		var sz: Vector3 = (wall as Destructible).size
		radius = clampf(maxf(sz.x, sz.z) * 0.5 + 0.8, 1.5, 3.0)
	queue_nav_refresh(position, radius)
	if wall and is_instance_valid(wall) and wall.is_inside_tree() and wall.global_position.distance_to(position) > 1.0:
		queue_nav_refresh(wall.global_position, radius)

## Clutter broke: its collision is gone at once. Glass leaves shards: a hazard.
func _on_furniture_broken(node: Node3D, position: Vector3, kind: StringName, _energy: float, _by: Node3D) -> void:
	queue_nav_refresh(position, BREAK_RADIUS)
	if node != null and is_instance_valid(node) and node.is_inside_tree() \
			and node.global_position.distance_to(position) > 0.5:
		queue_nav_refresh(node.global_position, BREAK_RADIUS)
	if kind == &"glass":
		_glass_hazards.append(Vector3(position.x, 0.0, position.z))
		if _glass_hazards.size() > HAZARD_MAX:
			_glass_hazards.remove_at(0)

## Structure came down (panel cells, a pillar's beam, a lintel): re-test now
## and again once the pieces have landed wherever physics put them.
func _on_structure_collapsed(node: Node3D, position: Vector3, _kind: StringName) -> void:
	var ground := Vector3(position.x, 0.0, position.z)
	queue_nav_refresh(ground, COLLAPSE_RADIUS)
	_nav_refresh.append([_now() + COLLAPSE_AGAIN, ground, COLLAPSE_RADIUS])
	if node != null and is_instance_valid(node) and node.is_inside_tree():
		var at := node.global_position
		if Vector2(at.x - ground.x, at.z - ground.z).length() > 1.0:
			queue_nav_refresh(Vector3(at.x, 0.0, at.z), COLLAPSE_RADIUS)

## Breakables that change without an event: a static clutter object whose
## collision went (knocked loose, broken) and rigid props on
## Layers.DESTRUCTIBLE (capsules collide with them) that moved. Also keeps
## the cracked-pillar beam hazards current.
func _poll_dynamic() -> void:
	var seen := {}
	for n in get_tree().get_nodes_in_group(&"breakables"):
		var co := n as CollisionObject3D
		if co == null or not co.is_inside_tree():
			continue
		var dynamic := co is RigidBody3D
		if not dynamic and not co.is_in_group(&"clutter"):
			continue
		seen[co] = true
		var pos := co.global_position
		var layer := co.collision_layer
		if not _dyn_tracked.has(co):
			_dyn_tracked[co] = [pos, layer]
			continue
		var rec: Array = _dyn_tracked[co]
		var was_blocking: bool = (int(rec[1]) & Layers.DESTRUCTIBLE) != 0
		var blocking := (layer & Layers.DESTRUCTIBLE) != 0
		var moved: bool = (pos - (rec[0] as Vector3)).length() > DYNAMIC_MOVE
		if was_blocking != blocking or ((blocking or was_blocking) and moved):
			queue_nav_refresh(rec[0], DYNAMIC_RADIUS)
			if moved:
				queue_nav_refresh(pos, DYNAMIC_RADIUS)
			_dyn_tracked[co] = [pos, layer]
	for co in _dyn_tracked.keys():
		if not seen.has(co):
			var rec: Array = _dyn_tracked[co]
			if (int(rec[1]) & Layers.DESTRUCTIBLE) != 0:
				queue_nav_refresh(rec[0], DYNAMIC_RADIUS)  # freed: its cells are open now
			_dyn_tracked.erase(co)
	_beam_hazards.clear()
	for n in get_tree().get_nodes_in_group(&"pillars"):
		if not is_instance_valid(n) or not bool(n.get(&"is_cracked")) or bool(n.get(&"is_broken")):
			continue
		var head := n.get(&"head") as Node3D
		if head == null or not is_instance_valid(head) or not head.is_inside_tree():
			continue
		var axis := head.global_basis.z
		axis.y = 0.0
		axis = axis.normalized() if axis.length() > 0.01 else Vector3.FORWARD
		var c := head.global_position
		_beam_hazards.append([Vector3(c.x, 0.0, c.z), axis])

## True where a waiting enemy should not stand: on broken glass, or under a
## cracked pillar's beam.
func is_hazard(p: Vector3) -> bool:
	var f := Vector3(p.x, 0.0, p.z)
	for g in _glass_hazards:
		if f.distance_to(g) < GLASS_HAZARD_RADIUS:
			return true
	for h: Array in _beam_hazards:
		var c: Vector3 = h[0]
		var axis: Vector3 = h[1]
		var along := clampf((f - c).dot(axis), -BEAM_HALF_LENGTH, BEAM_HALF_LENGTH)
		if f.distance_to(c + axis * along) < BEAM_HAZARD_MARGIN:
			return true
	return false

## A ring spot `goal` round `center` that is not a hazard: the spot itself, or
## the nearest one rotated round the centre in HAZARD_TURN steps (up to 100
## degrees each way); `goal` when every candidate is a hazard.
func avoid_hazards(goal: Vector3, center: Vector3) -> Vector3:
	if (_glass_hazards.is_empty() and _beam_hazards.is_empty()) or not is_hazard(goal):
		return goal
	var off := Vector3(goal.x - center.x, 0.0, goal.z - center.z)
	for k in range(1, 6):
		for sgn: float in [1.0, -1.0]:
			var c := center + off.rotated(Vector3.UP, deg_to_rad(HAZARD_TURN * k) * sgn)
			c.y = goal.y
			if not is_hazard(c):
				return c
	return goal

func get_hazard_counts() -> Vector2i:
	return Vector2i(_glass_hazards.size(), _beam_hazards.size())

func _on_wall_broken_by(_flyer: Node3D, wall: Node3D, _energy: float) -> void:
	if wall and is_instance_valid(wall) and wall.is_inside_tree():
		queue_nav_refresh(wall.global_position, 2.5)

# --- Events ------------------------------------------------------------------

func _on_wave_started(index: int, _total: int) -> void:
	set_wave(index + 1)

func _on_enemy_attack_started(_move_id: StringName, enemy: Fighter) -> void:
	if _holders.has(enemy):
		var entry: Dictionary = _holders[enemy]
		entry["attacking"] = true
		entry["went_active"] = false
		if not is_finite(float(entry["started"])):
			entry["started"] = world_now()

func _on_enemy_attack_incoming(_move_id: StringName, time_to_active: float, enemy: Fighter) -> void:
	if _holders.has(enemy) and is_finite(time_to_active):
		_holders[enemy]["active_at"] = world_now() + time_to_active * Engine.time_scale

func _on_enemy_attack_ended(_move_id: StringName, enemy: Fighter) -> void:
	if _holders.has(enemy) and _holders[enemy]["attacking"] and not _holders[enemy].get("went_active", false) \
			and not _holders[enemy]["followup"] and not enemy.is_dead() and not enemy.is_down():
		# Cut short in its wind-up (a tap cancels it): decided next tick, once
		# the reaction that cut it is known (Round 8: a flinch keeps the turn).
		_holders[enemy]["cut"] = true
		return
	if _holders.has(enemy) and _holders[enemy]["followup"]:
		# The string goes on: the next hit's reservation becomes the current one.
		var entry: Dictionary = _holders[enemy]
		entry["attacking"] = false
		entry["followup"] = false  # used up: the brain asks again before a further hit
		entry["granted"] = world_now()
		entry["started"] = INF
		var rest: Array = entry["reserved"]
		entry["active_at"] = rest.pop_front() if not rest.is_empty() else INF
		return
	if _last_turn.has(enemy):
		_last_turn[enemy] = world_now()
	release_token(enemy)

## A first active frame: logged for spacing across releases and for the
## minimum-gap statistic (soak tests).
func _on_attack_active(attacker: Node3D, _move_id: StringName) -> void:
	if not attacker is Fighter or not attacker in _enemies:
		return
	if _holders.has(attacker):
		_holders[attacker]["went_active"] = true
	var t := world_now()
	if _last_active_by != null and _last_active_by != attacker and is_instance_valid(_last_active_by):
		min_active_gap = minf(min_active_gap, t - _last_active_t)
	_last_active_t = t
	_last_active_by = attacker
	_recent_actives.append([t, attacker])

## Dazed, stumbling or tripped: give the token back at once.
func _drop(f: Node3D) -> void:
	if f is Fighter:
		release_token(f as Fighter)

## A hit takes the token back, unless the holder is still mid-attack (a
## heavy's wind-up ignores flinches): it keeps its swing and its slot.
## Round 8: a tap's flinch is shrugged off: the holder keeps its turn.
func _on_hit_landed(info: HitInfo) -> void:
	if info == null or not info.victim is Fighter:
		return
	var v := info.victim as Fighter
	if _holders.has(v) and v.combat != null and v.combat.is_attacking() and not v.is_down():
		return
	if _holders.has(v) and (info.react == &"flinch" or is_flinching(v)) and keeps_turn(v):
		return
	release_token(v)

func _on_fighter_launched(f: Node3D, _velocity: Vector3) -> void:
	if f is Fighter:
		release_token(f as Fighter)

func _on_grab_started(_grabber: Node3D, victim: Node3D) -> void:
	if victim is Fighter:
		release_token(victim as Fighter)

func _on_carry_changed(_holder: Node3D, held: Node3D) -> void:
	if held is Fighter and _holders.has(held):
		release_token(held as Fighter)

func _on_fleeing_changed(f: Node3D, fleeing: bool) -> void:
	if fleeing and f is Fighter:
		release_token(f as Fighter)

func _on_fighter_died(f: Node3D, _info: HitInfo) -> void:
	if f is Fighter and f in _enemies:
		unregister_enemy(f as Fighter)

func _on_attack_tell(attacker: Node3D, kind: StringName, duration: float) -> void:
	if attacker is Fighter and _holders.has(attacker):
		var entry: Dictionary = _holders[attacker]
		if not is_finite(float(entry["active_at"])):
			entry["active_at"] = world_now() + duration
	TellGlint.spawn(attacker, kind, duration)
