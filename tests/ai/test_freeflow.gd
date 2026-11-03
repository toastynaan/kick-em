extends Node
## Round 7 freeflow pacing (docs/Round 7 — Freeflow Combat.md: Enemies): a
## short Waves run (real main scene, --seconds of simulation, default 90 s at
## --fixed-fps 120) with a bot that attacks constantly through the real Round 7
## Input actions: it walks at the nearest enemy and presses a strike every
## PRESS_GAP s (punch taps and holds, the specials and kicks), never counters,
## dodges or grabs, in the open: when a launch throws it under the Yard's
## platform deck (few enemies can reach it there), the harness puts it back on
## the plaza once it is on its feet. The player is healed so the run lasts.
## Every hit staggers,
## so the enemies are often reacting; the ones not being hit must keep coming.
## Logged and checked:
## - enemies keep attacking: at least MIN_PER_MIN tells per minute of engaged
##   time (two or more live enemies fighting within AIBrain.REQUEST_MAX_DIST of
##   the open player: wave turnover and walk-ins do not count), and while
##   two or more enemies free to attack (fighting, on their feet, not
##   reacting, not held) are within AIBrain.REQUEST_MAX_DIST of the player
##   with a clear line to him (the crowd is on him, not still walking in or
##   behind a wall or the platform's skirts) and he is open, never more than
##   MAX_QUIET s without an enemy tell;
## - pacing holds: never more than Tuning.TOKEN_MAX token holders, first
##   active frames of different enemies >= Tuning.TOKEN_ACTIVE_GAP apart;
## - no enemy starts an attack while reacting, lifted, held or down, and every
##   tell lasts >= Tuning.R7_COUNTER_WINDOW + Tuning.R7_TELL_MARGIN;
## - the share of enemy time spent reacting is printed (how stunned they are).
## Usage: Godot --headless --path <copy> --fixed-fps 120 res://tests/ai/test_freeflow.tscn [-- --seconds=N --seed=N]
## OWNER: agent C (AI tests).

const PRESS_GAP := Vector2(0.22, 0.4)  ## s between the bot's presses
const MIN_PER_MIN := 20.0              ## enemy tells per minute at least
const MAX_QUIET := 6.0                 ## s without an enemy tell while two or more fight close by and the player is open
const REPORT_EVERY := 10.0
## The bot's press mix: [action, weight, hold s (0 = a tap of 2 ticks)].
const MIX := [[&"punch", 0.45, 0.0], [&"punch", 0.1, 0.3], [&"uppercut", 0.1, 0.0], [&"gut_punch", 0.1, 0.0],
	[&"leg_kick", 0.1, 0.0], [&"front_kick", 0.08, 0.0], [&"roundhouse", 0.07, 0.0]]

var seconds := 90.0
var game: Node
var rng := RandomNumberGenerator.new()
var failures := 0
var started := false
var next_press := 0.0
var release_at := {}             ## action -> time to release it
var tells: Array[float] = []     ## times of enemy tells
var bad_starts := 0              ## tells from an enemy reacting / lifted / held / down
var bad_info: Array[String] = []
var min_lead := INF              ## s, tell to first active frame
var tell_start := {}             ## enemy -> world time of its tell
var min_gap := INF               ## world s between different enemies' first active frames
var last_active_t := -INF
var last_active_by: Node3D = null
var max_holders := 0
var quiet_since := -1.0          ## time the current quiet stretch began (two+ fighting, player open)
var max_quiet := 0.0
var max_quiet_at := 0.0
var engaged_time := 0.0          ## s with two or more live enemies fighting close by and the player open
var engaged_tells := 0           ## enemy tells during engaged time
var react_ticks := 0             ## enemy-ticks spent reacting / lifted
var enemy_ticks := 0             ## enemy-ticks fighting
var reactions := 0               ## react_started on enemies
var player_hits := 0             ## enemy hits on the player
var kills := 0
var presses := 0
var max_wave := 0
var replaced := 0                ## times the harness put the player back on the plaza
var _dumped := -INF
var engaging := false

func _ready() -> void:
	var run_seed := 7007
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seconds="):
			seconds = float(arg.get_slice("=", 1))
		elif arg.begins_with("--seed="):
			run_seed = int(arg.get_slice("=", 1))
	rng.seed = run_seed
	seed(run_seed)
	AIBrain.test_seed = run_seed
	print("[ai] info: seed %d, %.0f s" % [run_seed, seconds])
	GameEvents.attack_tell.connect(_on_tell)
	GameEvents.attack_active.connect(_on_active)
	GameEvents.react_started.connect(func(v: Node3D, _k: StringName, _a: Node3D) -> void:
		if _enemy(v): reactions += 1)
	GameEvents.hit_landed.connect(func(i: HitInfo) -> void:
		if i.victim is Fighter and (i.victim as Fighter).is_player and _enemy(i.attacker): player_hits += 1)
	GameEvents.fighter_died.connect(func(f: Node3D, _i: HitInfo) -> void:
		if _enemy(f): kills += 1)
	GameEvents.round_over.connect(func(_won: bool) -> void:
		print("[ai] info: round over at %.0f s, restarting" % _now())
		_start.call_deferred())
	var packed: PackedScene = load("res://scenes/main.tscn")
	game = packed.instantiate()
	add_child(game)
	await get_tree().process_frame
	_start()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _now() -> float:
	return Engine.get_physics_frames() / float(Engine.physics_ticks_per_second)

func _start() -> void:
	if game.has_method(&"start_round"):
		game.start_round(&"waves")
		started = true

func _enemy(n: Node3D) -> bool:
	return n is Fighter and not (n as Fighter).is_player

# --- Logging ---------------------------------------------------------------------

func _on_tell(attacker: Node3D, _kind: StringName, _d: float) -> void:
	if not _enemy(attacker):
		return
	var a := attacker as Fighter
	tells.append(_now())
	if engaging:
		engaged_tells += 1
	tell_start[a] = AttackDirector.world_now()
	if a.is_reacting() or a.is_lifted() or a.is_down() or (a.carry != null and a.carry.is_held()):
		bad_starts += 1
		bad_info.append("%s %s" % [a.name, a.get_react_state()])

func _on_active(attacker: Node3D, _move: StringName) -> void:
	if not _enemy(attacker):
		return
	var t := AttackDirector.world_now()
	if tell_start.has(attacker):
		min_lead = minf(min_lead, t - float(tell_start[attacker]))
		tell_start.erase(attacker)
	if last_active_by != null and last_active_by != attacker and is_instance_valid(last_active_by):
		min_gap = minf(min_gap, t - last_active_t)
	last_active_t = t
	last_active_by = attacker

# --- Bot ---------------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if not started:
		return
	var t := _now()
	var player := Targeting.player(get_tree())
	max_holders = maxi(max_holders, AttackDirector.get_token_holders().size())
	max_wave = maxi(max_wave, AttackDirector.wave_index)
	var fighting := 0
	var close := 0
	for e in AttackDirector.get_enemies():
		if not is_instance_valid(e) or e.is_dead():
			continue
		var b := e.brain as AIBrain
		if b == null or not b.is_fighting() or b.is_fleeing():
			continue
		enemy_ticks += 1
		if player != null and e.get_ground_position().distance_to(player.get_ground_position()) <= AIBrain.REQUEST_MAX_DIST:
			close += 1
		var stunned := e.is_reacting() or e.is_lifted()
		if stunned:
			react_ticks += 1
		var free := not stunned and not e.is_down() and not (e.carry != null and e.carry.is_held())
		if free and player != null \
				and e.get_ground_position().distance_to(player.get_ground_position()) <= AIBrain.REQUEST_MAX_DIST \
				and _clear_line(e, player):
			fighting += 1
	var open := player != null and not player.is_dead() and AttackDirector.is_player_open()
	var last_tell: float = tells[-1] if not tells.is_empty() else -INF
	engaging = close >= 2 and open
	if engaging:
		engaged_time += 1.0 / Engine.physics_ticks_per_second
	if fighting >= 2 and open:
		if quiet_since < 0.0:
			quiet_since = maxf(t, last_tell)
		var since := maxf(quiet_since, last_tell)
		if t - since > max_quiet:
			max_quiet = t - since
			max_quiet_at = t
		if t - since > 4.0 and t - _dumped > 2.0:
			_dumped = t
			_dump(t, t - since)
	else:
		quiet_since = -1.0
	if player != null and player.hp < player.max_hp * 0.5 and not player.is_dead():
		player.heal_fraction(1.0)
	if t >= seconds:
		_end()
		return
	if fmod(t, REPORT_EVERY) < 1.0 / 120.0:
		_report(t)
	_drive(player, t)

## Why nobody attacks: each fighting enemy's state and last token denial.
func _dump(t: float, quiet: float) -> void:
	var pl := Targeting.player(get_tree())
	print("[ai] info: quiet %.1f s at %.1f s (holders %d; player at %s, speed %.1f m/s, attacking %s, move %s, floor %s):" % [quiet, t,
		AttackDirector.get_token_holders().size(), pl.global_position.snapped(Vector3.ONE * 0.1),
		Vector2(pl.velocity.x, pl.velocity.z).length(), pl.combat.is_attacking(), pl.combat.current_move_id(), pl.is_on_floor()])
	for e in AttackDirector.get_enemies():
		if not is_instance_valid(e) or e.is_dead():
			continue
		var b := e.brain as AIBrain
		var near := []
		var q := PhysicsShapeQueryParameters3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 0.9
		q.shape = sph
		q.transform = Transform3D(Basis(), e.get_ground_position() + Vector3(0, 0.6, 0))
		q.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
		q.exclude = [e.get_rid()]
		for h: Dictionary in e.get_world_3d().direct_space_state.intersect_shape(q, 6):
			var col: Object = h.get("collider")
			if col is Node:
				near.append("%s(%s)" % [(col as Node).name, (col as Node).get_parent().name if (col as Node).get_parent() else "-"])
		print("[ai] info:     touching %s, nav unreachable %s, path len %.1f" % [str(near), b.nav_unreachable if b else false,
			b.nav_path_length if b else 0.0])
		print("[ai] info:   %s %s react=%s dist=%.1f denial='%s' %s" % [e.name, e.archetype, e.get_react_state(),
			e.get_ground_position().distance_to(Targeting.player(get_tree()).get_ground_position()),
			AttackDirector.get_last_denial(e), b.get_debug_text() if b else "-"])

func _drive(player: Fighter, t: float) -> void:
	for a: StringName in release_at.keys():
		if t >= float(release_at[a]):
			Input.action_release(a)
			release_at.erase(a)
	if player == null or player.is_dead():
		return
	if _under_platform(player) and not player.is_down() and not player.is_in_hitstun() \
			and not (player.carry != null and player.carry.is_held()):
		player.global_position = Vector3(0.0, player.global_position.y + 0.05, 2.0)
		player.reset_physics_interpolation()
		replaced += 1
	var target := Targeting.pick_target(player, Vector3.ZERO, 40.0)
	_steer(player, target)
	if target == null or t < next_press or not release_at.is_empty():
		return
	next_press = t + rng.randf_range(PRESS_GAP.x, PRESS_GAP.y)
	var roll := rng.randf()
	var pick: Array = MIX[0]
	for m: Array in MIX:
		roll -= float(m[1])
		if roll <= 0.0:
			pick = m
			break
	var action: StringName = pick[0]
	if not InputMap.has_action(action):
		return
	Input.action_press(action)
	presses += 1
	release_at[action] = t + maxf(float(pick[2]), 2.0 / 120.0)

## Nothing solid (walls, clutter, the platform's skirts) between the two at
## waist and chest height.
func _clear_line(a: Fighter, b: Fighter) -> bool:
	var space := a.get_world_3d().direct_space_state
	for h: float in [0.8, 1.3]:
		var q := PhysicsRayQueryParameters3D.create(a.get_ground_position() + Vector3.UP * h,
			b.get_ground_position() + Vector3.UP * h, Layers.WORLD | Layers.DESTRUCTIBLE, [a.get_rid(), b.get_rid()])
		if not space.intersect_ray(q).is_empty():
			return false
	return true

## Inside the Yard's platform footprint (under its deck), with a margin (report).
static func _under_platform(f: Fighter) -> bool:
	return YardBuilder.PLATFORM_RECT.grow(0.4).has_point(Vector2(f.global_position.x, f.global_position.z))

func _steer(player: Fighter, target: Fighter) -> void:
	if target == null:
		_steer_to(player, player.get_ground_position())
		return
	var to := target.get_ground_position() - player.get_ground_position()
	to.y = 0.0
	if to.length() < 1.3:
		_steer_to(player, player.get_ground_position())
		return
	_steer_to(player, target.get_ground_position())

## Hold the move keys toward `goal` (none when there).
func _steer_to(player: Fighter, goal: Vector3) -> void:
	for a in [&"move_forward", &"move_back", &"move_left", &"move_right"]:
		Input.action_release(a)
	var to := goal - player.get_ground_position()
	to.y = 0.0
	if to.length() < 0.3:
		return
	var cam := get_viewport().get_camera_3d()
	var basis := cam.global_basis if cam else Basis()
	var fwd := -basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var right := basis.x
	right.y = 0.0
	right = right.normalized() if right.length() > 0.01 else Vector3.RIGHT
	to = to.normalized()
	var f := fwd.dot(to)
	var r := right.dot(to)
	if f > 0.1: Input.action_press(&"move_forward", f)
	if f < -0.1: Input.action_press(&"move_back", -f)
	if r > 0.1: Input.action_press(&"move_right", r)
	if r < -0.1: Input.action_press(&"move_left", -r)

# --- Report ------------------------------------------------------------------------

func _report(t: float) -> void:
	var pl := Targeting.player(get_tree())
	var where := "-"
	if pl != null:
		where = "%s%s state %d can_act %s attacking %s held %s" % [pl.global_position.snapped(Vector3.ONE * 0.1),
			" (under the platform)" if _under_platform(pl) else "", pl.get_state(), pl.can_act(),
			pl.combat.is_attacking(), pl.carry != null and pl.carry.is_held()]
	print("[ai] t=%.0fs wave=%d tells=%d presses=%d reactions=%d player_hits=%d kills=%d holders_max=%d quiet_max=%.1fs player %s" % [
		t, AttackDirector.wave_index, tells.size(), presses, reactions, player_hits, kills, max_holders, max_quiet, where])

func _end() -> void:
	set_physics_process(false)
	for a: StringName in release_at.keys():
		Input.action_release(a)
	for a in [&"move_forward", &"move_back", &"move_left", &"move_right"]:
		Input.action_release(a)
	_report(_now())
	var per_min := tells.size() / seconds * 60.0
	var engaged_per_min := engaged_tells / maxf(engaged_time, 1.0) * 60.0
	var react_share := float(react_ticks) / maxf(enemy_ticks, 1)
	var need := Tuning.R7_COUNTER_WINDOW + Tuning.R7_TELL_MARGIN
	print("[ai] info: the player was put back on the plaza from under the platform %d times" % replaced)
	print("[ai] info: %.0f s of freeflow Waves (reached wave %d): %d bot presses, %d enemy reactions, enemies reacting %.0f%% of their fighting time" % [
		seconds, max_wave, presses, reactions, react_share * 100.0])
	print("[ai] info: %d enemy tells (%.1f per minute), %d hits on the player, %d kills; longest quiet stretch %.1f s (at %.0f s); shortest tell %.3f s; closest first actives %.1f frames; %d pacing slots given back by holders knocked out of their turn" % [
		tells.size(), per_min, player_hits, kills, max_quiet, max_quiet_at, min_lead, min_gap * 60.0, AttackDirector.paced_refunds])
	check(reactions >= int(seconds / 3.0), "the bot keeps the enemies reacting (%d reactions, %.0f%% of their time)" % [reactions, react_share * 100.0])
	print("[ai] info: engaged %.0f s of %.0f s: %d tells, %.1f per minute (%.1f per minute over the whole run)" % [
		engaged_time, seconds, engaged_tells, engaged_per_min, per_min])
	check(engaged_time >= seconds * 0.3 and engaged_per_min >= MIN_PER_MIN,
		"enemies keep attacking: %.1f tells per minute while two or more are on the player (%.0f s engaged; >= %.0f)" % [
			engaged_per_min, engaged_time, MIN_PER_MIN])
	check(max_quiet <= MAX_QUIET, "never more than %.0f s without an enemy attack while two or more enemies free to attack are within %.0f m and the player is open (longest %.1f s)" % [
		MAX_QUIET, AIBrain.REQUEST_MAX_DIST, max_quiet])
	check(max_holders <= Tuning.TOKEN_MAX, "never more than %d token holders (max %d)" % [Tuning.TOKEN_MAX, max_holders])
	check(min_gap >= Tuning.TOKEN_ACTIVE_GAP - 0.004, "first active frames of different enemies >= %.0f frames apart (closest %.1f)" % [
		Tuning.TOKEN_ACTIVE_GAP * 60.0, min_gap * 60.0])
	check(bad_starts == 0, "no attack started while reacting, lifted, held or down (%d: %s)" % [bad_starts, ", ".join(bad_info.slice(0, 5))])
	check(is_finite(min_lead) and min_lead >= need - 1e-4, "every tell lasts >= %.2f s (shortest %.3f)" % [need, min_lead])
	print("[ai] test_freeflow: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
