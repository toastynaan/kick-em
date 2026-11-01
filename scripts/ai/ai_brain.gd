class_name AIBrain
extends Node
## Enemy controller: one per enemy Fighter, behaviour chosen by archetype
## (duelist, grunt, brawler, shield, brute, thrower). Writes fighter.move_input /
## face_dir, asks AttackDirector for tokens, starts attacks through
## fighter.combat.start_enemy_attack(). Added as a child of the enemy Fighter
## by FighterFactory. OWNER: agent C (AI).
##
## Flow: ENTRY walks entry_path into the courtyard, then FIGHT. In FIGHT the
## enemy holds a ring position around the player (NEAR or FAR, from the
## AttackDirector), strafes, keeps ~1.6 m from other enemies and slides along
## walls (routing round them via the arena's spawn-path points when the way
## stays blocked). Every attack interval a NEAR enemy (or one the player has
## walked up to) asks for a token; with one it closes to the move's range,
## asks the director for a spaced tell (request_swing) and starts the attack,
## or gives the token back after GIVE_UP_TIME. It never acts while down, in
## hitstun or held, and pauses briefly after a get-up. Enemies follow a player
## knocked out of the courtyard, and walk back in along a spawn path when they
## are knocked out themselves.

signal attack_launched(move_id: StringName)
## Duelist vanish step done (round 2.5): reappeared at `spot`.
signal vanish_stepped(spot: Vector3)

enum Mode { ENTRY, FIGHT }

# --- Local tuning (candidates for Tuning) ------------------------------------
const ENTRY_REACH := 0.6            ## m: entry waypoint reached
const ENTRY_POINT_TIMEOUT := 5.0    ## s stuck on one waypoint before skipping it
const SEPARATION := 1.6             ## m kept between enemies
const SEPARATION_WEIGHT := 1.6
const PLAYER_SPACE := 1.3           ## m a non-attacking enemy keeps from the player
const ARRIVE_RADIUS := 0.9          ## m: slow down inside this of a steering target
const WALL_PROBE := 1.0             ## m look-ahead ray
const WALL_PROBE_HEIGHT := 0.6      ## m above the floor
const WHISKER_ANGLE := 0.6          ## rad, side rays
const BOUNDS_MARGIN := 1.0          ## m kept inside the courtyard bounds
const DEFAULT_BOUNDS_HALF := 10.0   ## m, courtyard half size when no arena
const GIVE_UP_TIME := 2.0           ## s to reach range and swing with a token before releasing it
const ROUTE_BLOCKED_TIME := 0.75    ## s the straight line must stay blocked before routing via waypoints
const ROUTE_REPLAN := 0.5           ## s between waypoint searches while routing
const GETUP_PAUSE := 0.6            ## s after a get-up before attacking again
const REQUEST_RETRY := 0.25         ## s between refused token requests
const LONE_INTERVAL := Vector2(0.35, 1.0)  ## s between attacks for a lone enemy (duel)
const REQUEST_MAX_DIST := 5.5       ## m: closer than this before asking for a melee token (it must arrive within GIVE_UP_TIME)
const FACE_TOLERANCE := 0.8         ## dot(forward, to player) needed to swing
const FACE_WAIT_MAX := 0.35         ## s: swing anyway if turning takes longer
const START_FAIL_MAX := 30          ## refused start_enemy_attack calls before giving up the token
## Centre-to-centre distance at which each move starts.
const MOVE_RANGE := {&"e_hook": 1.4, &"e_kick": 1.6, &"e_heavy": 1.6, &"e_grab": 1.05,
	&"e_charge": 5.5, &"e_throw_debris": 11.0}
## Minimum distance for ranged / charging moves.
const MOVE_MIN_RANGE := {&"e_charge": 2.6, &"e_throw_debris": 3.5}
## Tell length per move (game s, inside [TELL_MIN, TELL_MAX]); heavier = longer.
const MOVE_TELL := {&"e_hook": 0.38, &"e_kick": 0.46, &"e_grab": 0.42, &"e_heavy": 0.54,
	&"e_charge": 0.6, &"e_throw_debris": 0.5}
const TELL_JITTER := 0.03
const EASY_TELL_BONUS := 0.05
const SPEED_MULT := {&"shield": 0.65, &"brute": 0.75}
const BRAWLER_GUARD_DIST := 3.0
const SHIELD_GUARD_DIST := 4.5      ## m: the Shield raises its guard inside this
const SHIELD_CLOSE_GUARD := 2.4     ## m: with a token, guard only this close (or if the player swings)
const SHIELD_REQUEST_DIST := 3.6    ## m: the slow Shield asks for a token only this close
## Ring radius as a fraction across the ring band, per archetype.
const RING_BIAS := {&"duelist": Vector2(0.05, 0.3), &"thrower": Vector2(0.4, 0.8)}
const STRAFE_SPEED := {&"duelist": 0.55}
const STRAFE_NEAR := 0.3
const STRAFE_FAR := 0.22
const STRAFE_SWITCH := Vector2(1.5, 3.0)
const DUELIST_STRAFE_SWITCH := Vector2(0.6, 1.4)
const SPREAD_ANGLE_NEAR := deg_to_rad(55.0)
const SPREAD_ANGLE_FAR := deg_to_rad(40.0)
const TAUNT_INTERVAL := Vector2(4.0, 9.0)
const TAUNT_HOLD := 1.2
# Duelist
const DODGE_LEAD := 0.07            ## s before the active frame to press block
const DODGE_HOLD := 0.12            ## s the dodge press is held
const DODGE_RANGE := 3.0            ## m: only dodge attacks aimed at us
const DODGE_FACING := 0.5           ## dot(player forward, to us)
const DUELIST_BLOCK_CHANCE := [0.1, 0.2]  ## [easy, normal] plain block when the dodge roll fails
const BLOCK_AFTER_ACTIVE := 0.3     ## s a plain block is held past the active frame
const SIDESTEP_TIME := 0.28         ## s of the visible sidestep after a dodge (no Focus to teleport)
const SIDESTEP_SPEED := 4.6         ## m/s: SIDESTEP_TIME x this = 1.3 m
const COUNTER_TELL := 0.3           ## s blue tell of the Duelist's teleport counter (start_counter)
const COUNTER_WINDOW := 1.2         ## s after a dodge in which the counter may still fire
const MASH_WINDOW := 2.0            ## s: repeats of the same player move inside this raise the dodge chance
const MASH_BONUS := 0.15            ## dodge chance added per repeat
const MASH_CAP := 0.85
const PUNISH_RANGE := 3.0
const PUNISH_WINDOW := 0.6
const FEINT_INTERVAL := Vector2(3.0, 5.5)
const FEINT_TIME := 0.45
const FEINT_RADIUS := 1.9
const STUCK_CHECK := 1.0            ## s between stuck checks
const STUCK_MOVE := 0.25            ## m moved per check below which we are stuck
const DETOUR_TIME := 0.8
const NEAR_JOIN_INTERVAL := Vector2(0.3, 0.8)  ## s: max wait after moving up to the NEAR ring
## Crowd enemies use Tuning.ATTACK_INTERVAL x this, start to start (the
## director's pacing keeps the crowd at one grant per 1-1.5 s on Normal).
const CROWD_INTERVAL_MULT := 0.7
const ENTRY_FIGHT_DIST := 4.0       ## m: an entering enemy inside the courtyard turns to fight this close
const PLAYER_OUTSIDE_GROW := 2.5    ## m: play area margin around a player outside the courtyard
const OUTSIDE_RETURN_TIME := 2.5    ## s outside the courtyard before walking a spawn path back in
const OUTSIDE_MARGIN := 0.5         ## m beyond the bounds that counts as outside
const SIDE_ROUTE_BLOCKED := 0.15    ## s blocked before trying a side point round a pillar
const SIDE_ROUTE_OFFSETS := [1.2, 2.0, 2.8]  ## m sideways probed for a clear way round
# Enemy throws (round 2): aim the grab's throw at a wall in front, never at enemies.
const THROW_WALL_RANGE := 8.0       ## m: walls searched in front of the grabber
const THROW_FAN := 4                ## rays each side of forward, 15 degrees apart
const THROW_LANE := 1.0             ## m: an enemy this close to the throw line blocks it
# Thrower rubble
const RUBBLE_SEARCH := 8.0          ## m: large debris searched around the Thrower
const RUBBLE_REACH := 1.1           ## m: close enough to pick a chunk up
const FETCH_TIMEOUT := 4.0          ## s walking to a chunk before giving up on it
const FETCH_COOLDOWN := 3.0         ## s before trying rubble again after a failed fetch
const CLEAR_RADIUS := 0.24          ## m: radius of the capsule swept by _clear_line
const CLEAR_HEIGHT := 1.5           ## m: its height (bottom ~0.2 m above the floor)
const CLEAR_CENTER := 0.95          ## m: its centre above the floor
const HEAD_PROBE_RISE := 0.8        ## m above WALL_PROBE_HEIGHT for the second forward ray
const SPOT_RADIUS := 0.45           ## m: free radius a steering target needs
const BODY_CLEARANCE := 0.45        ## m: wall hits closer than this to the movement line block it
const RANGE_SLACK := 0.4            ## m added to a move's range once the approach stalls
# Navigation (AINavGrid via AttackDirector)
const NAV_REPLAN := 0.6             ## s between path re-plans
const NAV_GOAL_MOVE := 1.0          ## m the goal may move before an early re-plan
const NAV_LOOKAHEAD := 8            ## path points checked for a clear shortcut
const NAV_LOOK_EVERY := 0.12        ## s between shortcut checks
const NAV_STUCK := 1.2              ## s without progress along a path before a local grid refresh
# Duelist vanish step (free, BT3 flavour) when it cannot reach an open player
const VSTEP_NO_PROGRESS := 2.5      ## s without getting VSTEP_PROGRESS closer
const VSTEP_PROGRESS := 0.5         ## m
const VSTEP_PATH_LEN := 14.0        ## m: a longer path triggers it at once
const VSTEP_MIN_DIST := 2.2         ## m: closer than this it just walks
const VSTEP_RADIUS := 2.5           ## m from the player
const VSTEP_HIDE := 0.12            ## s hidden before the teleport
const VSTEP_SHOW := 0.05            ## s after reappearing before it acts
const VSTEP_COOLDOWN := 6.0

var fighter: Fighter
## Path into the arena: the enemy walks these points in order after spawning,
## then fights. Set by the spawner (GameMode) before or right after add_child.
var entry_path: PackedVector3Array = PackedVector3Array()

var mode := Mode.ENTRY
## Attacks this brain has started (tests, debugging).
var attacks_started := 0
## Tests: force the Duelist's perfect-dodge chance (negative = use Tuning).
var dodge_chance_override := -1.0

var _rng := RandomNumberGenerator.new()
var _time := 0.0
var _path_index := 0
var _entry_point_time := 0.0
var _interval_left := 1.0
var _has_move := false
var _move_id: StringName = &""
var _approach_time := 0.0
var _in_range_time := 0.0
var _start_failures := 0
var _resume_at := 0.0
var _was_down := false
var _want_guard := false
var _block_down := false
var _dodge_hold_until := -INF       ## AttackDirector.now() time
var _block_until := 0.0             ## game time (Duelist plain block)
var _player_block_time := 0.0
var _player_attacking := false
var _ring_bias := 0.5
var _strafe_sign := 1.0
var _strafe_timer := 0.0
var _taunt_timer := 0.0
var _taunt_until := 0.0
var _feint_timer := 0.0
var _feint_until := 0.0
var _sidestep_until := 0.0
var _sidestep_dir := Vector3.ZERO
var _counter_pending := false
var _punish_until := 0.0
var _watched_player: Fighter = null
var _stuck_timer := 0.0
var _stuck_pos := Vector3.ZERO
var _stuck_intent := 0.0
var _detour_until := 0.0
var _detour_dir := Vector3.ZERO
var _bounds := AABB()
var _bounds_age := INF
var _was_near := false
var _attack_started_at := -INF
var _route_point := Vector3.INF
var _side_sign := 1.0
var _side_locked := false
var _best_dist := INF              ## closest the current approach got to the player
var _steer_in := Vector3.ZERO       ## debug: steering before / after avoidance
var _steer_out := Vector3.ZERO
var _sweep_params := PhysicsShapeQueryParameters3D.new()
var _spot_params := PhysicsShapeQueryParameters3D.new()
var _route_age := INF
var _blocked_time := 0.0
var _nav_points := PackedVector3Array()
var _nav_age := INF
var _entry_interrupted := false
var _outside_time := 0.0
var _counter_at := INF              ## game time the post-dodge counter may fire
var _counter_deadline := 0.0
var _counter_teleport := false      ## counter with combat.start_counter (costs Focus)
var _player_moves: Array = []       ## [game time, move family] of recent player attacks
var _aim_timer := 0.0
var _aim_set := false
var _has_chunk := false             ## Thrower holds a picked-up debris chunk
var _fetch_target: RigidBody3D = null
var _fetch_scan := 0.0
var _fetch_started := 0.0
var _fetch_cooldown_until := 0.0
## Attacks the Duelist started with start_counter (tests, debugging).
var counters_started := 0
## Duelist vanish steps taken (tests, debugging).
var vanish_steps := 0
## Length of the current nav path (m; INF when the grid found none).
var nav_path_length := 0.0
var _nav_path := PackedVector3Array()
var _nav_goal := Vector3.INF
var _npath_age := INF
var _nav_index := 0
var _nav_target := Vector3.ZERO
var _nav_look_age := INF
var _nav_best := INF
var _nav_progress_at := 0.0
var _vstep_until := 0.0
var _vstep_done := true
var _vstep_spot := Vector3.ZERO
var _vstep_ready_at := 0.0
var _vstep_best := INF
var _vstep_progress_at := 0.0

func _ready() -> void:
	# Body-sized checks: a hole knocked into a wall at waist height must not
	# read as a way through.
	var sweep := CapsuleShape3D.new()
	sweep.radius = CLEAR_RADIUS
	sweep.height = CLEAR_HEIGHT
	_sweep_params.shape = sweep
	_sweep_params.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
	var spot := CapsuleShape3D.new()
	spot.radius = SPOT_RADIUS
	spot.height = maxf(CLEAR_HEIGHT, SPOT_RADIUS * 2.0)
	_spot_params.shape = spot
	_spot_params.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
	fighter = get_parent() as Fighter
	fighter.brain = self
	_rng.randomize()
	var bias: Vector2 = RING_BIAS.get(fighter.archetype, Vector2(0.2, 0.7))
	_ring_bias = _rng.randf_range(bias.x, bias.y)
	_strafe_sign = 1.0 if _rng.randf() < 0.5 else -1.0
	_strafe_timer = _rng.randf_range(STRAFE_SWITCH.x, STRAFE_SWITCH.y)
	_taunt_timer = _rng.randf_range(TAUNT_INTERVAL.x, TAUNT_INTERVAL.y)
	_feint_timer = _rng.randf_range(FEINT_INTERVAL.x, FEINT_INTERVAL.y)
	_interval_left = _rng.randf_range(0.4, 1.2)
	if fighter.combat:
		fighter.combat.attack_ended.connect(_on_attack_ended)
	GameEvents.perfect_dodge.connect(_on_perfect_dodge)
	GameEvents.attack_whiff.connect(_on_attack_whiff)
	AttackDirector.register_enemy(fighter)

func _exit_tree() -> void:
	if fighter and is_instance_valid(fighter):
		AttackDirector.unregister_enemy(fighter)

## In the courtyard and fighting (entry walk done).
func is_fighting() -> bool:
	return mode == Mode.FIGHT

func get_move_id() -> StringName:
	return _move_id if _has_move else &""

## Distance from the player within which this enemy can take its turn soon
## (AttackDirector puts enemies further out behind closer ones in line).
func get_line_reach() -> float:
	if fighter.archetype == &"thrower":
		return MOVE_RANGE[&"e_throw_debris"] + 1.0
	return AttackDirector.LINE_FAR

## One-line state for debug overlays and test logs.
func get_debug_text() -> String:
	return "mode=%d move=%s token=%s ring=%d approach=%.2f in_range=%.2f interval=%.2f resume_in=%.2f fails=%d guard=%s can_act=%s attacking=%s steer=%s->%s route=%s side=%+.0f%s" % [
		mode, get_move_id(), AttackDirector.has_token(fighter), AttackDirector.get_ring(fighter),
		_approach_time, _in_range_time, _interval_left, maxf(_resume_at - _time, 0.0), _start_failures,
		_block_down, fighter.can_act(), _is_attacking(), _steer_in.snapped(Vector3.ONE * 0.01),
		_steer_out.snapped(Vector3.ONE * 0.01), "-" if _route_point == Vector3.INF else str(_route_point.snapped(Vector3.ONE * 0.01)),
		_side_sign, " locked" if _side_locked else ""] + " blocked=%.2f pos=%s" % [_blocked_time, _pos().snapped(Vector3.ONE * 0.1)]

# --- Main loop ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if fighter == null or not is_instance_valid(fighter) or not fighter.is_inside_tree():
		return
	_time += delta
	if fighter.is_dead():
		_on_dead()
		return
	if not AttackDirector.is_registered(fighter):
		AttackDirector.register_enemy(fighter)  # e.g. after AttackDirector.reset()
	var player := _get_player()
	_watch_player(player)
	if _is_disabled():
		_while_disabled()
		return
	if _was_down:
		_was_down = false
		_resume_at = _time + GETUP_PAUSE
	if mode == Mode.ENTRY:
		_do_entry(delta)
		_apply_guard()
		return
	if player == null or player.is_dead():
		_want_guard = false
		fighter.move_input = Vector3.ZERO
		_apply_guard()
		return
	_track_player(delta, player)
	_update_throw_aim(delta)
	if _counter_pending and _tick_counter(player):
		_apply_guard()
		return
	if _tick_vanish_step(player):
		_apply_guard()
		return
	if not _is_attacking() and _check_outside(delta):
		_apply_guard()
		return
	if _is_attacking():
		_want_guard = false
		fighter.move_input = Vector3.ZERO
		if fighter.combat.holding == null:
			_face(player.get_ground_position())
	elif AttackDirector.has_token(fighter):
		_do_token_turn(delta, player)
	else:
		_has_move = false
		_do_ring(delta, player)
		_tick_request(delta, player)
	_apply_guard()

func _is_disabled() -> bool:
	var disabled := fighter.is_down() or fighter.is_in_hitstun() \
		or (fighter.combat != null and fighter.combat.held_by != null)
	if fighter.is_down():
		_was_down = true
	if disabled and mode == Mode.ENTRY:
		_entry_interrupted = true
	return disabled

func _is_attacking() -> bool:
	if fighter.combat == null:
		return false
	return fighter.combat.is_attacking() or fighter.combat.holding != null

func _while_disabled() -> void:
	fighter.move_input = Vector3.ZERO
	# Keep a raised guard through blockstun; drop it when down or held.
	if fighter.is_down() or (fighter.combat and fighter.combat.held_by != null) or not _block_down:
		_want_guard = false
		_dodge_hold_until = -INF
		_apply_guard()
	_has_move = false
	_counter_pending = false
	_fetch_target = null
	if AttackDirector.has_token(fighter) and not _is_attacking():
		AttackDirector.release_token(fighter)

func _on_dead() -> void:
	fighter.move_input = Vector3.ZERO
	_want_guard = false
	_dodge_hold_until = -INF
	_apply_guard()
	AttackDirector.unregister_enemy(fighter)
	set_physics_process(false)

# --- Entry -------------------------------------------------------------------

func _do_entry(delta: float) -> void:
	if _path_index >= entry_path.size():
		_enter_fight()
		return
	# Already in the courtyard and attacked, or the player is right here: fight.
	if _inside_courtyard(0.5):
		var player := _get_player()
		if _entry_interrupted or (player and _dist_to(player) < ENTRY_FIGHT_DIST):
			_enter_fight()
			return
	var target := entry_path[_path_index]
	var to := _flat(target - _pos())
	if to.length() < ENTRY_REACH:
		_path_index += 1
		_entry_point_time = 0.0
		return
	_entry_point_time += delta
	if _entry_point_time > ENTRY_POINT_TIMEOUT:
		_path_index += 1
		_entry_point_time = 0.0
		return
	var last := _path_index == entry_path.size() - 1
	var v := to.normalized() * (clampf(to.length() / ARRIVE_RADIUS, 0.3, 1.0) if last else 1.0)
	v += _separation() * 0.5
	v = _avoid_walls(v, 0.7)
	_set_move(v)
	if v.length() > 0.05:
		fighter.face_dir = _flat(v).normalized()

func _enter_fight() -> void:
	mode = Mode.FIGHT
	_bounds_age = INF
	_stuck_pos = _pos()
	_entry_interrupted = false
	_outside_time = 0.0

func _inside_courtyard(margin: float) -> bool:
	return _point_in_courtyard(_pos(), margin)

func _point_in_courtyard(p: Vector3, margin: float) -> bool:
	var b := get_courtyard_bounds()
	return p.x > b.position.x + margin and p.x < b.end.x - margin \
		and p.z > b.position.z + margin and p.z < b.end.z - margin

## Knocked out of the courtyard (through a wall into a room): after a while,
## walk back along the nearest visible spawn path.
func _check_outside(delta: float) -> bool:
	if AttackDirector.nav_ready():
		return false  # the nav grid routes back in by itself
	var player := _get_player()
	var player_outside := player != null and not _point_in_courtyard(player.get_ground_position(), 0.0)
	if _inside_courtyard(-OUTSIDE_MARGIN) or player_outside:
		_outside_time = 0.0
		return false
	_outside_time += delta
	if _outside_time < OUTSIDE_RETURN_TIME:
		return false
	_outside_time = 0.0
	var path := _return_path()
	if path.is_empty():
		return false
	entry_path = path
	_path_index = 0
	_entry_point_time = 0.0
	mode = Mode.ENTRY
	if AttackDirector.has_token(fighter) and not _is_attacking():
		AttackDirector.release_token(fighter)
	return true

func _return_path() -> PackedVector3Array:
	var arena := get_tree().get_first_node_in_group(&"arena")
	if arena == null or not arena.has_method(&"get_enemy_spawns"):
		return PackedVector3Array()
	var me := _pos()
	var best := PackedVector3Array()
	var best_d := INF
	for entry: Dictionary in arena.get_enemy_spawns():
		var pts := PackedVector3Array([entry.get("position", me)])
		pts.append_array(entry.get("path", PackedVector3Array()))
		for i in pts.size():
			var d := _flat(pts[i] - me).length()
			if d < best_d and _clear_line(me, pts[i]):
				best_d = d
				best = pts.slice(i)
	return best

## True if a body fits at `p`: no wall or pillar within SPOT_RADIUS at waist
## height (steering targets too close to an obstacle are unreachable).
func _spot_free(p: Vector3) -> bool:
	var space := fighter.get_world_3d().direct_space_state
	_spot_params.transform = Transform3D(Basis(), Vector3(p.x, p.y + CLEAR_CENTER, p.z))
	_spot_params.exclude = [fighter.get_rid()]
	return space.intersect_shape(_spot_params, 1).is_empty()

## True if a body can pass from a to b: a capsule (CLEAR_RADIUS, a little
## thinner than a fighter's, CLEAR_HEIGHT tall) swept along the floor misses
## walls and pillars, so a corner the body would catch on, or a hole in a
## wall that is not floor to head height, reads as blocked.
func _clear_line(a: Vector3, b: Vector3) -> bool:
	var space := fighter.get_world_3d().direct_space_state
	var from := Vector3(a.x, a.y + CLEAR_CENTER, a.z)
	var motion := Vector3(b.x - a.x, 0.0, b.z - a.z)
	if motion.length() < 0.01:
		return true
	_sweep_params.transform = Transform3D(Basis(), from)
	_sweep_params.motion = motion
	_sweep_params.exclude = [fighter.get_rid()]
	var r := space.cast_motion(_sweep_params)
	return r.size() == 0 or r[0] >= 1.0

# --- Ring behaviour ----------------------------------------------------------

func _do_ring(delta: float, player: Fighter) -> void:
	var center := player.get_ground_position()
	var me := _pos()
	var to_me := _flat(me - center)
	var d := to_me.length()
	var dir := to_me / d if d > 0.05 else _flat(-fighter.get_forward()).normalized()
	if dir.length() < 0.5:
		dir = Vector3.BACK
	var ring := AttackDirector.get_ring(fighter)
	var far := ring != AttackDirector.Ring.NEAR or fighter.archetype == &"thrower"
	var band: Vector2 = Tuning.FAR_RING if far else Tuning.NEAR_RING
	var radius := lerpf(band.x, band.y, _ring_bias)
	_want_guard = _guard_wanted(d, false)
	if _fetch_rubble(delta, center):
		return

	# Taunts (far ring only).
	if _time < _taunt_until:
		fighter.move_input = Vector3.ZERO
		_face(center)
		return
	if far and fighter.archetype != &"thrower":
		_taunt_timer -= delta
		if _taunt_timer <= 0.0:
			_taunt_timer = _rng.randf_range(TAUNT_INTERVAL.x, TAUNT_INTERVAL.y)
			if d > Tuning.FAR_RING.x - 1.0 and _try_taunt():
				fighter.move_input = Vector3.ZERO
				_face(center)
				return

	# Duelist feints: a quick step in, then back out.
	if fighter.archetype == &"duelist" and not far:
		_feint_timer -= delta
		if _feint_timer <= 0.0:
			_feint_timer = _rng.randf_range(FEINT_INTERVAL.x, FEINT_INTERVAL.y)
			_feint_until = _time + FEINT_TIME
		if _time < _feint_until:
			radius = FEINT_RADIUS

	# Off screen and next in line: drift into the camera's view (rule 4).
	if not far and not AttackDirector.is_on_screen(fighter):
		var cam_fwd := _camera_forward()
		if cam_fwd != Vector3.ZERO:
			dir = (dir + cam_fwd * 1.2).normalized()

	_strafe_timer -= delta
	if _strafe_timer <= 0.0:
		var sw := DUELIST_STRAFE_SWITCH if fighter.archetype == &"duelist" else STRAFE_SWITCH
		_strafe_timer = _rng.randf_range(sw.x, sw.y)
		_strafe_sign = -_strafe_sign if _rng.randf() < 0.75 else _strafe_sign
	var tangent := Vector3(-dir.z, 0.0, dir.x)
	var strafe: float = STRAFE_SPEED.get(fighter.archetype, STRAFE_FAR if far else STRAFE_NEAR)
	var spread := _angular_spread(center, dir, far)

	var goal := _clamp_to_bounds(center + dir * radius)
	if not _clear_line(center, goal):
		goal = _visible_ring_point(center, dir, radius)
	goal = _route(goal, center)
	var v := _seek(goal)
	v += tangent * (strafe * _strafe_sign + spread * 0.8)
	if _time < _sidestep_until:
		v = _sidestep_dir
	_finish_move(v, center, true)
	_face(center)

## A ring point with a clear line to the player (not behind a wall when the
## player is in a room or next to one): rotate around the ring, then come closer.
func _visible_ring_point(center: Vector3, dir: Vector3, radius: float) -> Vector3:
	for r: float in [radius, 1.8]:
		for k in range(1, 7):
			for sgn: float in [1.0, -1.0]:
				var g := _clamp_to_bounds(center + dir.rotated(Vector3.UP, sgn * k * PI / 6.0) * r)
				if _clear_line(center, g):
					return g
	return center + dir * 1.5

## Where to stand to swing: `r` from the player on our side, or, when that
## spot is behind (or inside) a pillar or wall as seen from the player, the
## nearest spot round the player with a clear line to it. Rays are cast from
## the player outward so a spot inside an obstacle reads as blocked.
func _approach_goal(center: Vector3, dir: Vector3, r: float) -> Vector3:
	var g := center - dir * r
	if _spot_free(g) and _clear_line(center, g):
		return g
	var me := _pos()
	var best := g
	var best_d := INF
	var perp := Vector3(-dir.z, 0.0, dir.x)
	for k in range(1, 7):
		for sgn: float in [1.0, -1.0]:
			var c := center - dir.rotated(Vector3.UP, sgn * k * PI / 6.0) * r
			if not _spot_free(c) or not _clear_line(center, c):
				continue
			var d := _flat(c - me).length()
			# While going round an obstacle, stay on the committed side.
			if _side_locked and signf(perp.dot(c - me)) != _side_sign:
				d += 3.0
			if d < best_d:
				best_d = d
				best = c
	return best

func _try_taunt() -> bool:
	if fighter.animator == null or fighter.animator.is_busy() or _is_attacking():
		return false
	if not AttackDirector.is_on_screen(fighter):
		return false
	fighter.animator.play_move(&"taunt", 0.3, 0.5, 0.4)
	_taunt_until = _time + TAUNT_HOLD
	return true

## Tangential push away from enemies in the same ring at similar angles.
func _angular_spread(center: Vector3, dir: Vector3, far: bool) -> float:
	var tangent := Vector3(-dir.z, 0.0, dir.x)
	var limit := SPREAD_ANGLE_FAR if far else SPREAD_ANGLE_NEAR
	var push := 0.0
	for e in AttackDirector.get_enemies():
		if e == fighter or not is_instance_valid(e) or e.is_dead() or e.is_down():
			continue
		var other_far := AttackDirector.get_ring(e) != AttackDirector.Ring.NEAR or e.archetype == &"thrower"
		if other_far != far:
			continue
		var o := _flat(e.get_ground_position() - center)
		if o.length() < 0.05:
			continue
		o = o.normalized()
		var ang := atan2(o.dot(tangent), o.dot(dir))
		if absf(ang) < limit:
			var s := 1.0 - absf(ang) / limit
			push += -signf(ang) * s if absf(ang) > 0.01 else (1.0 if get_instance_id() < e.get_instance_id() else -1.0)
	return clampf(push, -1.0, 1.0)

# --- Attacks -----------------------------------------------------------------

func _tick_request(delta: float, player: Fighter) -> void:
	if _time < _resume_at:
		return
	# The attack interval runs in the NEAR ring (or when the player is right
	# here); FAR enemies wait their turn.
	var near := AttackDirector.get_ring(fighter) == AttackDirector.Ring.NEAR
	var dist := _dist_to(player)
	# A FAR enemy the player has walked up to (close and on screen) may also
	# ask; the director's pacing keeps the crowd's rate in check.
	var engaged := dist <= Tuning.NEAR_RING.y and AttackDirector.is_on_screen(fighter)
	if near and not _was_near:
		# Just moved up (next in line): the walk in covers most of the wait.
		_interval_left = minf(_interval_left, _rng.randf_range(NEAR_JOIN_INTERVAL.x, NEAR_JOIN_INTERVAL.y))
	_was_near = near
	if near or engaged:
		_interval_left -= delta
	var urgent := _counter_pending or _time < _punish_until or _brawler_wants_grab()
	if not urgent and (_interval_left > 0.0 or not (near or engaged)):
		return
	if _fetch_target != null:
		return  # the Thrower fetches its rubble first
	var max_dist := SHIELD_REQUEST_DIST if fighter.archetype == &"shield" else REQUEST_MAX_DIST
	if not fighter.archetype in [&"thrower", &"brute"] and dist > max_dist:
		return
	# Only the Duelist's counter / whiff punish skip the crowd pacing; a
	# Brawler punishing a blocker just skips its own interval.
	if AttackDirector.request_token(fighter, _counter_pending or _time < _punish_until):
		_move_id = _pick_move(dist, player)
		_has_move = true
		_approach_time = 0.0
		_in_range_time = 0.0
		_start_failures = 0
	else:
		_interval_left = maxf(_interval_left, REQUEST_RETRY)

func _do_token_turn(delta: float, player: Fighter) -> void:
	var dist := _dist_to(player)
	if not _has_move:
		_move_id = _pick_move(dist, player)
		_has_move = true
		_approach_time = 0.0
		_in_range_time = 0.0
		_start_failures = 0
	if _approach_time == 0.0:
		_best_dist = INF
	_approach_time += delta
	if _approach_time > GIVE_UP_TIME:
		_give_up_token()
		return
	# Fall back to a close move when the target is inside a ranged move's minimum.
	if _move_id == &"e_charge" and dist < MOVE_MIN_RANGE[&"e_charge"]:
		_move_id = &"e_heavy"
	elif _move_id == &"e_throw_debris" and dist < 2.2:
		_move_id = &"e_hook"
	var max_r: float = MOVE_RANGE.get(_move_id, 1.5)
	var min_r: float = MOVE_MIN_RANGE.get(_move_id, 0.0)
	# The approach has stalled (a pillar corner, a body in the way): swing from
	# a little further out; the move's lunge covers the gap.
	if _approach_time > GIVE_UP_TIME * 0.5 and dist < _best_dist + 0.05 and _clear_line(player.get_ground_position(), _pos()):
		max_r += RANGE_SLACK
	_best_dist = minf(_best_dist, dist)
	var center := player.get_ground_position()
	var to_player := _flat(center - _pos())
	var dir := to_player.normalized() if to_player.length() > 0.01 else fighter.get_forward()
	_want_guard = _guard_wanted(dist, true)
	_face(center)
	if dist > max_r:
		_in_range_time = 0.0
		var goal := _route(_approach_goal(center, dir, max_r * 0.75), center)
		var v := _flat(goal - _pos()).normalized()
		_finish_move(v, center, false)
		return
	if dist < min_r:
		_in_range_time = 0.0
		_finish_move(-dir, center, false)
		return
	fighter.move_input = Vector3.ZERO
	_in_range_time += delta
	if _time < _resume_at or not fighter.can_act():
		return
	if fighter.get_forward().dot(dir) < FACE_TOLERANCE and _in_range_time < FACE_WAIT_MAX:
		return
	var tell := AttackDirector.request_swing(fighter, _tell_for(_move_id))
	if tell < 0.0:
		return
	_want_guard = false
	_apply_guard()
	var started := fighter.combat != null and fighter.combat.start_enemy_attack(_move_id, tell)
	if started:
		var tta := fighter.combat.time_to_active()
		AttackDirector.notify_attack_started(fighter, tta if is_finite(tta) else tell)
		attacks_started += 1
		_attack_started_at = _time
		if _move_id == &"e_throw_debris":
			_has_chunk = false
		elif _move_id == &"e_grab":
			_aim_timer = 0.0
			_update_throw_aim(0.0)
		_has_move = false
		_counter_pending = false
		_punish_until = 0.0
		attack_launched.emit(_move_id)
	else:
		AttackDirector.cancel_swing(fighter)
		_start_failures += 1
		if _start_failures > START_FAIL_MAX:
			_give_up_token()

func _give_up_token() -> void:
	AttackDirector.release_token(fighter)
	_has_move = false
	_counter_pending = false
	_interval_left = REQUEST_RETRY * 2.0

## The attack interval runs start to start: the time the attack took counts.
func _on_attack_ended(_move_id_ended: StringName) -> void:
	_interval_left = maxf(_new_interval() - (_time - _attack_started_at), REQUEST_RETRY)

func _new_interval() -> float:
	if AttackDirector.live_enemy_count() <= 1:
		return _rng.randf_range(LONE_INTERVAL.x, LONE_INTERVAL.y)
	return _rng.randf_range(Tuning.ATTACK_INTERVAL.x, Tuning.ATTACK_INTERVAL.y) * CROWD_INTERVAL_MULT

func _pick_move(dist: float, _player: Fighter) -> StringName:
	var moves: Array = fighter.config.get("moves", [&"e_hook"])
	var pick: StringName = &"e_hook"
	var roll := _rng.randf()
	match fighter.archetype:
		&"grunt":
			pick = &"e_hook" if roll < 0.6 else &"e_kick"
		&"brawler":
			if _brawler_wants_grab():
				pick = &"e_grab"
			else:
				pick = &"e_hook" if roll < 0.55 else &"e_heavy"
		&"shield":
			pick = &"e_hook" if roll < 0.6 else &"e_heavy"
		&"brute":
			if dist >= 3.0 and roll < 0.75:
				pick = &"e_charge"
			elif dist >= 3.0:
				pick = &"e_heavy" if _rng.randf() < 0.65 else &"e_grab"
			else:
				pick = &"e_heavy" if roll < 0.7 else &"e_grab"
		&"duelist":
			if _counter_pending:
				pick = &"e_hook"
			elif _time < _punish_until:
				pick = &"e_kick"  # a whiff is punished with a launch
			elif _player_block_time > 0.5 and roll < 0.7:
				pick = &"e_grab"
			elif roll < 0.35:
				pick = &"e_hook"
			elif roll < 0.6:
				pick = &"e_kick"
			elif roll < 0.8:
				pick = &"e_heavy"
			else:
				pick = &"e_grab"
		&"thrower":
			pick = &"e_hook" if dist < 2.5 else &"e_throw_debris"
		_:
			pick = moves[_rng.randi() % moves.size()] if not moves.is_empty() else &"e_hook"
	if not moves.is_empty() and not pick in moves:
		pick = moves[0]
	return pick

func _tell_for(move_id: StringName) -> float:
	if _counter_pending or _time < _punish_until:
		return Tuning.TELL_MIN
	var t: float = MOVE_TELL.get(move_id, 0.45) + _rng.randf_range(-TELL_JITTER, TELL_JITTER)
	if Tuning.difficulty == Tuning.Difficulty.EASY:
		t += EASY_TELL_BONUS
	return clampf(t, Tuning.TELL_MIN, Tuning.TELL_MAX)

func _brawler_wants_grab() -> bool:
	if fighter.archetype != &"brawler":
		return false
	return _player_block_time > float(fighter.config.get("grab_blocker_after", 1.0))

# --- Guard -------------------------------------------------------------------

func _guard_wanted(dist: float, with_token: bool) -> bool:
	match fighter.archetype:
		&"shield":
			if with_token:
				return dist < SHIELD_CLOSE_GUARD or _player_attacking
			return dist < SHIELD_GUARD_DIST
		&"brawler":
			return not with_token and dist < BRAWLER_GUARD_DIST
		&"duelist":
			return _time < _block_until
	return false

## Press / release BLOCK on changes of the wanted guard state only.
func _apply_guard() -> void:
	var want := _want_guard or AttackDirector.now() < _dodge_hold_until
	if want == _block_down:
		return
	_block_down = want
	if fighter.combat == null:
		return
	if want:
		fighter.combat.press(CombatController.Action.BLOCK)
	else:
		fighter.combat.release(CombatController.Action.BLOCK)

# --- Player tracking, Duelist reactions ---------------------------------------

func _get_player() -> Fighter:
	return AttackDirector.get_player()

func _track_player(delta: float, player: Fighter) -> void:
	_player_attacking = player.combat != null and player.combat.is_attacking()
	if player.combat and player.combat.blocking:
		_player_block_time += delta
	else:
		_player_block_time = 0.0

func _watch_player(player: Fighter) -> void:
	if player == _watched_player:
		return
	if _watched_player != null and is_instance_valid(_watched_player) and _watched_player.combat:
		if _watched_player.combat.attack_incoming.is_connected(_on_player_attack_incoming):
			_watched_player.combat.attack_incoming.disconnect(_on_player_attack_incoming)
	_watched_player = player
	if player != null and player.combat and fighter.config.has("dodge_chance"):
		player.combat.attack_incoming.connect(_on_player_attack_incoming)

func _dodge_chance() -> float:
	if dodge_chance_override >= 0.0:
		return dodge_chance_override
	var chances: Array = fighter.config.get("dodge_chance", [0.0, 0.0])
	return float(chances[clampi(Tuning.difficulty, 0, chances.size() - 1)])

## The player started an attack: maybe perfect-dodge it (Duelist). Repeating
## the same move within MASH_WINDOW raises the chance (anti-mash).
func _on_player_attack_incoming(move: StringName, time_to_active: float) -> void:
	var family := String(move).rstrip("0123456789")
	var repeats := 0
	var kept: Array = []
	for m: Array in _player_moves:
		if _time - float(m[0]) <= MASH_WINDOW:
			kept.append(m)
			if m[1] == family:
				repeats += 1
	kept.append([_time, family])
	_player_moves = kept
	if mode != Mode.FIGHT or fighter.is_dead() or _is_disabled() or _is_attacking():
		return
	var player := _get_player()
	if player == null:
		return
	var to_me := _flat(_pos() - player.get_ground_position())
	if to_me.length() > DODGE_RANGE:
		return
	if to_me.length() > 0.05 and player.get_forward().dot(to_me.normalized()) < DODGE_FACING:
		return
	if _rng.randf() < get_dodge_chance(repeats):
		var delay := time_to_active - DODGE_LEAD
		if delay <= 0.0:
			_dodge_press()
		else:
			TimeDirector.real_timer(delay).timeout.connect(_dodge_press)
	elif dodge_chance_override < 0.0 and time_to_active > Tuning.PERFECT_DODGE_WINDOW + 0.05 \
			and _rng.randf() < DUELIST_BLOCK_CHANCE[clampi(Tuning.difficulty, 0, 1)]:
		# A plain block, pressed now (outside the perfect window). Not against
		# attacks faster than the window: that press would be a perfect dodge.
		_block_until = _time + time_to_active + BLOCK_AFTER_ACTIVE

## Dodge chance against a player move repeated `repeats` times within
## MASH_WINDOW: the Tuning chance, +MASH_BONUS per repeat, capped at MASH_CAP.
func get_dodge_chance(repeats := 0) -> float:
	if dodge_chance_override >= 0.0:
		return dodge_chance_override
	var base := _dodge_chance()
	if repeats <= 0:
		return base
	return maxf(base, minf(base + MASH_BONUS * repeats, MASH_CAP))

func _dodge_press() -> void:
	if not is_instance_valid(fighter) or fighter.is_dead() or _is_disabled() or _is_attacking():
		return
	if fighter.combat == null:
		return
	if _block_down:
		fighter.combat.release(CombatController.Action.BLOCK)
	fighter.combat.press(CombatController.Action.BLOCK)
	_block_down = true
	_dodge_hold_until = AttackDirector.now() + DODGE_HOLD

## After a perfect dodge (BT3 vanish exchange): with Focus and B's
## start_counter, teleport behind the player once visible again (blue tell,
## back kick); without, a visible sidestep (>= 1 m) and, once it has
## reappeared, a quick hook through the normal token turn.
func _on_perfect_dodge(defender: Node3D, attacker: Node3D) -> void:
	if defender != fighter:
		return
	_counter_pending = true
	_counter_deadline = _time + COUNTER_WINDOW
	_counter_teleport = fighter.combat != null and fighter.combat.has_method(&"start_counter") \
		and fighter.focus + 1e-4 >= Tuning.FOCUS_COST and attacker is Fighter
	if _counter_teleport:
		_counter_at = _time + 0.05
		return
	var away := _flat(_pos() - attacker.global_position) if attacker else Vector3.ZERO
	if away.length() < 0.05:
		away = -fighter.get_forward()
	away = away.normalized()
	var side := Vector3(-away.z, 0.0, away.x) * (1.0 if _rng.randf() < 0.5 else -1.0)
	# Prefer the side with room (no wall within 1.5 m).
	if not _clear_line(_pos(), _pos() + side * 1.5):
		side = -side
	_sidestep_dir = side
	_sidestep_until = _time + SIDESTEP_TIME
	if fighter.has_method(&"knockback"):
		fighter.knockback(side * SIDESTEP_SPEED, SIDESTEP_TIME)
	_counter_at = _time + SIDESTEP_TIME + 0.02

## Runs the post-dodge counter. Returns true while it owns this frame.
func _tick_counter(player: Fighter) -> bool:
	if _time > _counter_deadline or player.is_dead():
		_counter_pending = false
		return false
	var vanished := fighter.combat != null and fighter.combat.has_method(&"is_vanished") \
		and fighter.combat.is_vanished()
	if _time < _counter_at or vanished:
		# Dodging: the sidestep slide (or the vanish) runs; no attack yet.
		fighter.move_input = Vector3.ZERO
		_face(player.get_ground_position())
		return true
	if not _counter_teleport:
		return false  # the normal token turn swings the quick hook
	if _is_attacking() or not fighter.can_act():
		return true
	if not AttackDirector.request_token(fighter, true):
		return true
	var started: bool = fighter.combat.start_counter(player, COUNTER_TELL)
	if not started:
		_counter_teleport = false  # fall back to the hook
		return false
	var tta := fighter.combat.time_to_active()
	AttackDirector.notify_attack_started(fighter, tta if is_finite(tta) else COUNTER_TELL)
	attacks_started += 1
	counters_started += 1
	_attack_started_at = _time
	_counter_pending = false
	_has_move = false
	attack_launched.emit(&"counter")
	return true

func _on_attack_whiff(attacker: Node3D, _move: StringName) -> void:
	if fighter.archetype != &"duelist" or attacker == null or attacker != _get_player():
		return
	if mode == Mode.FIGHT and _dist_to(attacker as Fighter) < PUNISH_RANGE:
		_punish_until = _time + PUNISH_WINDOW

# --- Enemy throws ---------------------------------------------------------------

## While holding a grab victim, aim the throw (combat.throw_aim) at the
## nearest wall in front (breakable first), never along a lane with an enemy.
func _update_throw_aim(delta: float) -> void:
	if fighter.combat == null:
		return
	var grabbing := fighter.combat.holding != null \
		or (fighter.combat.is_attacking() and fighter.combat.current_move_id() == &"e_grab")
	if not grabbing:
		if _aim_set:
			fighter.combat.throw_aim = Vector3.ZERO
			_aim_set = false
		return
	_aim_timer -= delta
	if _aim_timer > 0.0:
		return
	_aim_timer = 0.15
	var aim := find_throw_aim()
	fighter.combat.throw_aim = aim
	_aim_set = true
	if aim != Vector3.ZERO and fighter.combat.holding != null:
		fighter.face_dir = aim

## Direction for a throw: the nearest breakable wall within THROW_WALL_RANGE
## in a +-60 degree fan, else the nearest wall, else the first fan direction
## with nothing in the way. Lanes with an enemy are skipped. ZERO when none
## qualifies (B then throws straight ahead).
func find_throw_aim() -> Vector3:
	var space := fighter.get_world_3d().direct_space_state
	var origin := _pos() + Vector3.UP * 1.0
	var fwd := _flat(fighter.get_forward()).normalized()
	var best_break := Vector3.ZERO
	var best_break_d := INF
	var best_wall := Vector3.ZERO
	var best_wall_d := INF
	var open_dir := Vector3.ZERO
	for k in THROW_FAN * 2 + 1:
		@warning_ignore("integer_division")
		var i: int = (k + 1) / 2 * (1 if k % 2 == 1 else -1)  # 0, 1, -1, 2, -2, ...
		var d := fwd.rotated(Vector3.UP, deg_to_rad(15.0) * i)
		var q := PhysicsRayQueryParameters3D.create(origin, origin + d * THROW_WALL_RANGE,
			Layers.WORLD | Layers.DESTRUCTIBLE, [fighter.get_rid()])
		var hit := space.intersect_ray(q)
		var end: Vector3 = hit["position"] if not hit.is_empty() else origin + d * THROW_WALL_RANGE * 1.5
		if _enemy_in_lane(origin, end):
			continue
		if hit.is_empty():
			if open_dir == Vector3.ZERO:
				open_dir = d
			continue
		var dist := origin.distance_to(end)
		var col: Object = hit["collider"]
		var breakable := col is Destructible \
			and ((col as CollisionObject3D).collision_layer & Layers.DESTRUCTIBLE) != 0
		if breakable and dist < best_break_d:
			best_break_d = dist
			best_break = d
		elif not breakable and dist < best_wall_d:
			best_wall_d = dist
			best_wall = d
	if best_break != Vector3.ZERO:
		return best_break
	if best_wall != Vector3.ZERO:
		return best_wall
	return open_dir

func _enemy_in_lane(a: Vector3, b: Vector3) -> bool:
	var a2 := Vector2(a.x, a.z)
	var b2 := Vector2(b.x, b.z)
	for e in AttackDirector.get_enemies():
		if e == fighter or not is_instance_valid(e) or e.is_dead():
			continue
		var p := e.get_ground_position()
		var p2 := Vector2(p.x, p.z)
		if Geometry2D.get_closest_point_to_segment(p2, a2, b2).distance_to(p2) < THROW_LANE:
			return true
	return false

# --- Thrower rubble -------------------------------------------------------------

## The Thrower picks up a large debris chunk near it while it waits for a
## token (round 2: large chunks persist). Returns true while walking to one.
func _fetch_rubble(delta: float, center: Vector3) -> bool:
	if fighter.archetype != &"thrower" or _has_chunk or fighter.combat == null:
		return false
	if _time < _fetch_cooldown_until:
		return false
	if not fighter.combat.has_method(&"pick_up_debris") or not DebrisManager.has_method(&"find_nearest"):
		return false
	_fetch_scan -= delta
	if _fetch_target == null or not is_instance_valid(_fetch_target) or not _fetch_target.is_inside_tree():
		_fetch_target = null
		if _fetch_scan > 0.0:
			return false
		_fetch_scan = 0.5
		_fetch_target = DebrisManager.find_nearest(_pos(), RUBBLE_SEARCH, true)
		if _fetch_target == null:
			return false
		_fetch_started = _time
	var to := _flat(_fetch_target.global_position - _pos())
	if to.length() <= RUBBLE_REACH:
		if fighter.combat.pick_up_debris(_fetch_target):
			_has_chunk = true
		else:
			_fetch_cooldown_until = _time + FETCH_COOLDOWN  # B refused this chunk
		_fetch_target = null
		_fetch_scan = 0.5
		fighter.move_input = Vector3.ZERO
		return false
	if _time - _fetch_started > FETCH_TIMEOUT:
		_fetch_target = null
		_fetch_cooldown_until = _time + FETCH_COOLDOWN
		return false
	var goal := _route(_fetch_target.global_position, _fetch_target.global_position)
	_finish_move(_seek(goal) * 1.0 + to.normalized() * 0.3, center, true)
	_face(_fetch_target.global_position)
	return true

## Thrower: holds a picked-up chunk (its next e_throw_debris throws it).
func has_chunk() -> bool:
	return _has_chunk

# --- Steering ----------------------------------------------------------------

func _seek(goal: Vector3) -> Vector3:
	var to := _flat(goal - _pos())
	var d := to.length()
	if d < 0.05:
		return Vector3.ZERO
	return to / d * clampf(d / ARRIVE_RADIUS, 0.0, 1.0)

## Add separation, player space, bounds and wall sliding, then write move_input.
func _finish_move(v: Vector3, player_pos: Vector3, keep_player_space: bool) -> void:
	_steer_in = v
	v += _separation() * SEPARATION_WEIGHT
	if keep_player_space:
		var from_player := _flat(_pos() - player_pos)
		var d := from_player.length()
		if d < PLAYER_SPACE and d > 0.01:
			v += from_player / d * (1.0 - d / PLAYER_SPACE) * 2.0
	# A nav path only crosses walkable cells; it may leave the courtyard
	# (round a wall end, through a room) where the bounds push would fight it.
	if _nav_path.is_empty():
		v += _bounds_push()
	if _time < _detour_until:
		v = v * 0.3 + _detour_dir
	v = _avoid_walls(v, WALL_PROBE)
	_steer_out = v
	_check_stuck(v)
	_set_move(v)

## Steering target toward `goal`: the goal itself while the straight line is
## clear of walls (or only briefly blocked, e.g. by a pillar: wall sliding
## handles that), else an arena waypoint (spawn-path point) on a clear line,
## so an enemy walks round a wall to reach a player knocked into a room.
## Waypoints are searched toward `anchor` (the player: stable while the ring
## goal moves around); a failed search keeps the previous waypoint.
func _route(goal: Vector3, anchor: Vector3) -> Vector3:
	var dt := get_physics_process_delta_time()
	_route_age += dt
	var me := _pos()
	if _clear_line(me, goal):
		_blocked_time = 0.0
		_route_point = Vector3.INF
		_side_locked = false
		_nav_path = PackedVector3Array()
		nav_path_length = 0.0
		return goal
	_blocked_time += dt
	if _blocked_time < SIDE_ROUTE_BLOCKED:
		return goal
	# The shared nav grid knows doors, holes and props: follow its path.
	var nav_pt := _nav_route(me, goal)
	if nav_pt != Vector3.INF:
		return nav_pt
	if not _side_locked:
		# Commit to one side of the obstacle for this blockage: the side the
		# goal lies on, seen along the line to the player (else keep the last).
		_side_locked = true
		var line := _flat(anchor - me)
		if line.length() > 0.05:
			line = line.normalized()
			var off := Vector3(-line.z, 0.0, line.x).dot(_flat(goal - me))
			if absf(off) > 0.1:
				_side_sign = signf(off)
	var reached := _route_point != Vector3.INF and _flat(_route_point - me).length() <= ENTRY_REACH
	if _route_point != Vector3.INF and not reached and _route_age < ROUTE_REPLAN:
		return _route_point
	_route_age = 0.0
	# Round a pillar or a wall end first: a point to the side with a clear
	# line both ways. Arena waypoints only when that fails for a while.
	var side := _side_point(me, goal)
	if side != Vector3.INF:
		_route_point = side
		return side
	if _blocked_time < ROUTE_BLOCKED_TIME:
		return goal
	var found := _find_waypoint(me, anchor)
	if found != Vector3.INF:
		_route_point = found
	elif reached:
		_route_point = Vector3.INF
	return goal if _route_point == Vector3.INF else _route_point

## Steering point along the nav grid's path to `goal` (INF when the grid is
## not ready or has no path). Re-plans every NAV_REPLAN s or when the goal
## moves; looks ahead to the furthest path point in clear line (string
## pulling, re-checked every NAV_LOOK_EVERY s). If following makes no
## progress, the cells round the enemy are re-tested (stale grid repair).
func _nav_route(me: Vector3, goal: Vector3) -> Vector3:
	if not AttackDirector.nav_ready():
		return Vector3.INF
	var dt := get_physics_process_delta_time()
	_npath_age += dt
	if _nav_path.is_empty() or _npath_age > NAV_REPLAN or _flat(goal - _nav_goal).length() > NAV_GOAL_MOVE:
		var p := AttackDirector.nav_path(me, goal)
		if not p.is_empty():
			_nav_path = p
			_nav_goal = goal
			_npath_age = 0.0
			_nav_index = 0
			_nav_look_age = INF
			nav_path_length = AINavGrid.path_length(me, p)
		elif AttackDirector.nav_has_budget():
			_nav_path = PackedVector3Array()  # no path at all
			nav_path_length = INF
	if _nav_path.is_empty():
		return Vector3.INF
	while _nav_index < _nav_path.size() - 1 and _flat(_nav_path[_nav_index] - me).length() < AINavGrid.CELL * 1.5:
		_nav_index += 1
	_nav_look_age += dt
	if _nav_look_age > NAV_LOOK_EVERY:
		_nav_look_age = 0.0
		_nav_target = _nav_path[_nav_index]
		for k in range(_nav_index + 1, mini(_nav_index + NAV_LOOKAHEAD, _nav_path.size())):
			if not _clear_line(me, _nav_path[k]):
				break
			_nav_target = _nav_path[k]
		# Stale grid (geometry changed without a break event): no progress
		# for a while along the path -> re-test the cells round us.
		var d_target := _flat(_nav_target - me).length()
		if d_target < _nav_best - 0.2:
			_nav_best = d_target
			_nav_progress_at = _time
		elif _time - _nav_progress_at > NAV_STUCK:
			AttackDirector.nav.refresh(me, 1.6)
			_nav_path = PackedVector3Array()
			_nav_best = INF
			_nav_progress_at = _time
	return _nav_target

# --- Duelist vanish step ----------------------------------------------------------

## Duelist only: no path, or no progress toward an open player for
## VSTEP_NO_PROGRESS s, or a path longer than VSTEP_PATH_LEN: a free vanish
## step (6 s cooldown) to a clear spot ~2.5 m from the player in its line of
## sight, with B's afterimage and puff. Returns true while it owns the frame.
func _tick_vanish_step(player: Fighter) -> bool:
	if fighter.archetype != &"duelist":
		return false
	if _time < _vstep_until:
		fighter.move_input = Vector3.ZERO
		if not _vstep_done and _time >= _vstep_until - 0.001 - VSTEP_SHOW:
			_finish_vanish_step(player)
		return true
	var d := _dist_to(player)
	var long_way := nav_path_length > VSTEP_PATH_LEN  # INF: the grid found no way at all
	# Only when it means to close in: holding a token, or well outside its ring.
	var want_close := AttackDirector.has_token(fighter) or d > Tuning.NEAR_RING.y + 1.0 or long_way
	if _is_attacking() or not AttackDirector.is_player_open() or d <= VSTEP_MIN_DIST or not want_close:
		_vstep_best = d
		_vstep_progress_at = _time
		return false
	if d < _vstep_best - VSTEP_PROGRESS:
		_vstep_best = d
		_vstep_progress_at = _time
	var stuck := _time - _vstep_progress_at > VSTEP_NO_PROGRESS
	if not (stuck or long_way) or _time < _vstep_ready_at:
		return false
	var spot := _vanish_spot(player)
	if spot == Vector3.INF:
		_vstep_ready_at = _time + 1.0  # nowhere clear: look again shortly
		return false
	_vstep_spot = spot
	_vstep_until = _time + VSTEP_HIDE + VSTEP_SHOW
	_vstep_done = false
	_vstep_ready_at = _time + VSTEP_COOLDOWN
	fighter.move_input = Vector3.ZERO
	if fighter.rig:
		CombatFX.afterimage(fighter)
		fighter.rig.set_body_visible(false)
	return true

func _finish_vanish_step(player: Fighter) -> void:
	_vstep_done = true
	var look := _flat(player.get_ground_position() - _vstep_spot)
	if fighter.has_method(&"teleport_to"):
		fighter.teleport_to(_vstep_spot, look)
	else:
		fighter.global_position = _vstep_spot
		fighter.reset_physics_interpolation()
	if fighter.rig:
		fighter.rig.set_body_visible(true)
		CombatFX.puff(fighter.get_aim_point())
	_nav_path = PackedVector3Array()
	_vstep_best = _dist_to(player)
	_vstep_progress_at = _time
	vanish_steps += 1
	vanish_stepped.emit(_vstep_spot)

## A clear floor spot VSTEP_RADIUS from the player with a clear line to it,
## preferring the player's front (so the Duelist reappears in view).
func _vanish_spot(player: Fighter) -> Vector3:
	var center := player.get_ground_position()
	var fwd := _flat(player.get_forward())
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	for k in 12:
		@warning_ignore("integer_division")
		var i: int = (k + 1) / 2 * (1 if k % 2 == 1 else -1)  # 0, 1, -1, 2, -2, ...
		var c := center + fwd.rotated(Vector3.UP, deg_to_rad(30.0) * i) * VSTEP_RADIUS
		if AttackDirector.nav_ready() and not AttackDirector.nav.is_walkable(c):
			continue
		if _spot_free(c) and _clear_line(center, c):
			return c
	return Vector3.INF

## A point beside the blocked line (SIDE_ROUTE_OFFSETS) seen from here and
## seeing the goal, keeping to the side used last; INF if none.
func _side_point(me: Vector3, goal: Vector3) -> Vector3:
	var dir := _flat(goal - me)
	if dir.length() < 0.05:
		return Vector3.INF
	dir = dir.normalized()
	var perp := Vector3(-dir.z, 0.0, dir.x)
	for sgn: float in [_side_sign, -_side_sign]:
		for off: float in SIDE_ROUTE_OFFSETS:
			var p := me + perp * sgn * off + dir * 0.5
			if _spot_free(p) and _clear_line(me, p) and _clear_line(p, goal):
				return p
	return Vector3.INF

## Best waypoint toward `goal`: one hop (visible from both ends), else the
## first point of a two-hop route.
func _find_waypoint(me: Vector3, goal: Vector3) -> Vector3:
	var pts := _get_nav_points()
	var from_me: Array[Vector3] = []
	var from_goal: Array[Vector3] = []
	var best := Vector3.INF
	var best_cost := INF
	for p in pts:
		if _flat(p - me).length() < ENTRY_REACH:
			continue
		var seen_me := _clear_line(me, p)
		var seen_goal := _clear_line(p, goal)
		if seen_me:
			from_me.append(p)
		if seen_goal:
			from_goal.append(p)
		if seen_me and seen_goal:
			var cost := _flat(p - me).length() + _flat(goal - p).length()
			if cost < best_cost:
				best_cost = cost
				best = p
	if best != Vector3.INF:
		return best
	for p in from_me:
		for q in from_goal:
			if p == q or not _clear_line(p, q):
				continue
			var cost := _flat(p - me).length() + _flat(q - p).length() + _flat(goal - q).length()
			if cost < best_cost:
				best_cost = cost
				best = p
	return best

## Spawn positions and entry-path points of the arena (doors and room routes).
func _get_nav_points() -> PackedVector3Array:
	_nav_age += get_physics_process_delta_time()
	if _nav_age < 5.0:
		return _nav_points
	_nav_age = 0.0
	_nav_points = PackedVector3Array()
	var arena := get_tree().get_first_node_in_group(&"arena")
	if arena and arena.has_method(&"get_enemy_spawns"):
		for entry: Dictionary in arena.get_enemy_spawns():
			_nav_points.append(entry.get("position", Vector3.ZERO))
			_nav_points.append_array(entry.get("path", PackedVector3Array()))
	return _nav_points

func _set_move(v: Vector3) -> void:
	v.y = 0.0
	# Guarding already slows the walk (Fighter.BLOCK_WALK_MULT); do not stack.
	var mult: float = 1.0 if _block_down else float(SPEED_MULT.get(fighter.archetype, 1.0))
	fighter.move_input = v.limit_length(1.0) * mult

func _separation() -> Vector3:
	var push := Vector3.ZERO
	var me := _pos()
	for e in AttackDirector.get_enemies():
		if e == fighter or not is_instance_valid(e) or e.is_dead():
			continue
		var away := _flat(me - e.get_ground_position())
		var d := away.length()
		if d >= SEPARATION:
			continue
		if d < 0.01:
			away = Vector3(cos(get_instance_id()), 0.0, sin(get_instance_id()))
			d = 0.01
		var w := 1.0 - d / SEPARATION
		push += away.normalized() * w * (0.5 if e.is_down() else 1.0)
	return push

## Slide along walls ahead. A ray hit only blocks when it lies in the
## body's path (within BODY_CLEARANCE of the movement line); an obstacle
## beside the path (e.g. a pillar edge a whisker sees) is passed, not
## braked for.
func _avoid_walls(v: Vector3, probe: float) -> Vector3:
	if v.length() < 0.05 or not fighter.is_inside_tree():
		return v
	var space := fighter.get_world_3d().direct_space_state
	if space == null:
		return v
	var origin := _pos() + Vector3.UP * WALL_PROBE_HEIGHT
	var dir := _flat(v).normalized()
	var perp := Vector3(-dir.z, 0.0, dir.x)
	var mask := Layers.WORLD | Layers.DESTRUCTIBLE
	var speed := v.length()
	# Forward at waist and head height (a hole knocked into a wall at one
	# height is no way through), plus two whiskers.
	for probe_ray: Vector2 in [Vector2(0.0, 0.0), Vector2(0.0, HEAD_PROBE_RISE),
			Vector2(WHISKER_ANGLE, 0.0), Vector2(-WHISKER_ANGLE, 0.0)]:
		var angle := probe_ray.x
		var d := dir.rotated(Vector3.UP, angle)
		var length := probe if angle == 0.0 else probe * 0.7
		var o := origin + Vector3.UP * probe_ray.y
		var q := PhysicsRayQueryParameters3D.create(o, o + d * length, mask, [fighter.get_rid()])
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var n: Vector3 = hit["normal"]
		n.y = 0.0
		if n.length() < 0.1:
			continue
		n = n.normalized()
		var rel := _flat(hit["position"] - o)
		var in_path := absf(rel.dot(perp)) < BODY_CLEARANCE and rel.dot(dir) > 0.0
		var into := v.dot(n)
		# Only a near head-on push is redirected; a glancing one is left to
		# move_and_slide, which slides along the face by itself.
		if in_path and into < -0.7 * speed:
			v -= n * into
			# Head-on into a pillar or wall: slide round it, not to a stop.
			if angle == 0.0 and v.length() < speed * 0.3:
				v += Vector3(-n.z, 0.0, n.x) * _side_sign * speed * 0.8
		var dist := rel.length()
		if dist < 0.6:
			v += n * 0.3 * (1.0 - dist / 0.6)
	return v

func _check_stuck(v: Vector3) -> void:
	_stuck_timer += get_physics_process_delta_time()
	_stuck_intent = maxf(_stuck_intent, v.length())
	if _stuck_timer < STUCK_CHECK:
		return
	var moved := _flat(_pos() - _stuck_pos).length()
	if _stuck_intent > 0.5 and moved < STUCK_MOVE and _time >= _detour_until:
		var base := _flat(v).normalized()
		var side := Vector3(-base.z, 0.0, base.x) * (1.0 if _rng.randf() < 0.5 else -1.0)
		_detour_dir = side
		_detour_until = _time + DETOUR_TIME
	_stuck_timer = 0.0
	_stuck_intent = 0.0
	_stuck_pos = _pos()

func get_courtyard_bounds() -> AABB:
	_bounds_age += get_physics_process_delta_time()
	if _bounds_age > 2.0:
		_bounds_age = 0.0
		var arena := get_tree().get_first_node_in_group(&"arena")
		if arena and arena.has_method(&"get_courtyard_bounds"):
			_bounds = arena.get_courtyard_bounds()
		else:
			var h := DEFAULT_BOUNDS_HALF
			_bounds = AABB(Vector3(-h, 0.0, -h), Vector3(h * 2.0, 4.0, h * 2.0))
	return _bounds

## Where enemies may stand: the courtyard, grown to take in the player when
## the player is outside it (knocked through a wall into a room).
func _play_bounds() -> AABB:
	var b := get_courtyard_bounds()
	var player := _get_player()
	if player != null and not player.is_dead():
		var p := player.get_ground_position()
		if p.x < b.position.x or p.x > b.end.x or p.z < b.position.z or p.z > b.end.z:
			b = b.expand(Vector3(p.x, b.position.y, p.z)).grow(PLAYER_OUTSIDE_GROW)
	return b

func _clamp_to_bounds(p: Vector3) -> Vector3:
	var b := _play_bounds()
	var m := minf(BOUNDS_MARGIN, minf(b.size.x, b.size.z) * 0.25)
	p.x = clampf(p.x, b.position.x + m, b.end.x - m)
	p.z = clampf(p.z, b.position.z + m, b.end.z - m)
	return p

func _bounds_push() -> Vector3:
	var me := _pos()
	var inside := _clamp_to_bounds(me)
	var out := _flat(inside - me)
	return out.limit_length(1.0) * 1.5

func _camera_forward() -> Vector3:
	var cam := get_viewport().get_camera_3d() if get_viewport() else null
	if cam == null:
		return Vector3.ZERO
	var f := _flat(-cam.global_basis.z)
	return f.normalized() if f.length() > 0.01 else Vector3.ZERO

func _face(point: Vector3) -> void:
	var d := _flat(point - _pos())
	if d.length() > 0.05:
		fighter.face_dir = d.normalized()

func _pos() -> Vector3:
	return fighter.get_ground_position()

func _dist_to(other: Fighter) -> float:
	if other == null or not is_instance_valid(other):
		return INF
	return _flat(other.get_ground_position() - _pos()).length()

static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)
