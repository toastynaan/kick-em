extends Node
## Integration soak test (OWNER: core). Loads the real main scene, starts a
## round, and drives the player through the real Input actions with a bot.
## Usage (on a private copy, see docs/ARCHITECTURE.md):
##   Godot --headless --path <copy> --fixed-fps 120 res://tests/integration/soak_test.tscn -- --mode=duel --seconds=90
## Prints periodic stats and a summary; exits 1 if the round could not start.
##
## Round 7 bot (docs/Round 7 — Freeflow Combat.md): plays short combos from
## COMBOS (taps, and holds that charge: Round 8), grabs then drives or throws,
## answers counter windows on the player with Counter (orange) or a dodge
## (blue) after a human-ish reaction delay, and sprints, dodges or jumps to
## close in. God path (amendment): after a launch it often pursues (Dash), then
## attacks with the stick neutral (relaunch) or pulled back (spike).

## Combos the bot plays: [action, hold seconds] per step. Hold 0 is a tap;
## a hold past Tuning.R8_TAP_MAX charges (Round 8), 1.1 s is a full charge.
const COMBOS := [
	[[&"punch", 0.0], [&"punch", 0.0], [&"punch", 0.0]],
	[[&"punch", 0.0], [&"punch", 0.0], [&"punch", 0.7]],
	[[&"punch", 0.0], [&"punch", 0.0], [&"gut_punch", 1.1], [&"front_kick", 1.1]],
	[[&"gut_punch", 0.6], [&"uppercut", 0.5], [&"roundhouse", 0.0]],
	[[&"leg_kick", 1.1], [&"roundhouse", 0.8]],
	[[&"punch", 0.0], [&"punch", 0.0], [&"front_kick", 0.4]],
	[[&"leg_kick", 0.0], [&"gut_punch", 0.0], [&"uppercut", 0.0], [&"punch", 0.0], [&"front_kick", 0.0]],
]
## The air combo (Round 8): a full-charge uppercut, Jump to follow, air hits, a kick away.
const AIR_COMBO := [[&"uppercut", 1.1, 0.12], [&"jump", 0.0, 0.3], [&"punch", 0.0, 0.2], [&"punch", 0.0, 0.2],
	[&"punch", 0.0, 0.2], [&"punch", 0.0, 0.2], [&"roundhouse", 0.0, 0.4]]
const AIR_COMBO_CHANCE := 0.2
const STEP_GAP := Vector2(0.28, 0.42)   ## s between combo presses (presses during startup/active are dropped)
const TAP_TIME := 0.06                  ## s a tap is held
const REACT_DELAY := Vector2(0.05, 0.25) ## s before answering a counter window
const ANSWER_CHANCE := 0.8
const PURSUE_CHANCE := 0.7
const SPIKE_CHANCE := 0.4

var mode: StringName = &"duel"
var seconds := 90.0
var game: Node
var elapsed := 0.0
var next_report := 0.0
var next_action := 0.0
var rng := RandomNumberGenerator.new()
## Scheduled input: [time, action, pressed], sorted by time.
var _queue: Array = []
## While elapsed < this, steering holds the stick back (toward the camera): a spike.
var _pull_back_until := -1.0
var stats := {"launches": 0, "hits": 0, "blocks": 0, "breaks": 0, "cracks": 0,
	"impacts": 0, "bowls": 0, "deaths": 0, "rounds": 0, "tells": 0, "grabs": 0, "severs": 0,
	"chains": 0, "best_chain": 0, "payoffs": 0, "windows": 0, "counters": 0, "counter_whiffs": 0,
	"dodges": 0, "drives": 0, "drive_breaks": 0, "slams": 0, "throws": 0,
	"pursuits": 0, "spikes": 0, "teleports": 0, "rams": 0, "jumps": 0,
	"charges": 0, "full_charges": 0, "charge_cancels": 0, "pressure_breaks": 0, "air_follows": 0, "air_hits": 0}
var max_debris := 0
var max_enemies := 0

func _ready() -> void:
	rng.seed = 1234
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="):
			mode = StringName(arg.get_slice("=", 1))
		elif arg.begins_with("--seconds="):
			seconds = float(arg.get_slice("=", 1))
	GameEvents.fighter_launched.connect(_on_launched)
	GameEvents.pursuit.connect(func(_a: Node3D, _v: Node3D) -> void: stats.pursuits += 1)
	GameEvents.teleported.connect(func(_f: Node3D, _a: Vector3, _b: Vector3, _k: StringName) -> void: stats.teleports += 1)
	GameEvents.rammed.connect(func(_r: Node3D, _v: Node3D, _a: StringName, _b: StringName) -> void: stats.rams += 1)
	GameEvents.jumped.connect(func(_f: Node3D) -> void: stats.jumps += 1)
	GameEvents.hit_landed.connect(_on_hit)
	GameEvents.hit_blocked.connect(func(_i: HitInfo) -> void: stats.blocks += 1)
	GameEvents.wall_broken.connect(func(_w: Node3D, _p: Vector3, _e: float, _v: Vector3) -> void: stats.breaks += 1)
	GameEvents.wall_cracked.connect(func(_w: Node3D, _p: Vector3, _e: float) -> void: stats.cracks += 1)
	GameEvents.body_impact.connect(func(_f: Node3D, _p: Vector3, _n: Vector3, _e: float, _s: StringName) -> void: stats.impacts += 1)
	GameEvents.body_bowled.connect(func(_a: Node3D, _b: Node3D, _e: float, _c: int) -> void: stats.bowls += 1)
	GameEvents.fighter_died.connect(func(_f: Node3D, _i: HitInfo) -> void: stats.deaths += 1)
	GameEvents.attack_tell.connect(func(_f: Node3D, _k: StringName, _d: float) -> void: stats.tells += 1)
	GameEvents.grab_started.connect(func(_a: Node3D, _b: Node3D) -> void: stats.grabs += 1)
	GameEvents.limb_severed.connect(func(_f: Node3D, _c: StringName, _p: Node3D) -> void: stats.severs += 1)
	GameEvents.chain_ended.connect(_on_chain_ended)
	GameEvents.counter_window.connect(_on_counter_window)
	GameEvents.countered.connect(func(_d: Node3D, _a: Node3D) -> void: stats.counters += 1)
	GameEvents.counter_whiffed.connect(func(_d: Node3D) -> void: stats.counter_whiffs += 1)
	GameEvents.dodged.connect(func(_f: Node3D, _d: Vector3) -> void: stats.dodges += 1)
	GameEvents.drive_started.connect(func(_h: Node3D, _b: Node3D) -> void: stats.drives += 1)
	GameEvents.drive_impact.connect(_on_drive_impact)
	GameEvents.thrown.connect(func(_g: Node3D, _v: Node3D, _vel: Vector3) -> void: stats.throws += 1)
	GameEvents.charge_started.connect(func(_f: Node3D, _m: StringName) -> void: stats.charges += 1)
	GameEvents.charge_full.connect(func(_f: Node3D, _m: StringName) -> void: stats.full_charges += 1)
	GameEvents.charge_cancelled.connect(func(_f: Node3D, _m: StringName, _r: StringName) -> void: stats.charge_cancels += 1)
	GameEvents.pressure_broken.connect(func(_f: Node3D, _a: Node3D) -> void: stats.pressure_breaks += 1)
	GameEvents.air_follow_started.connect(func(_f: Node3D, _t: Node3D) -> void: stats.air_follows += 1)
	GameEvents.air_hit.connect(func(_a: Node3D, _v: Node3D, _c: int) -> void: stats.air_hits += 1)
	GameEvents.round_over.connect(_on_round_over)
	var packed: PackedScene = load("res://scenes/main.tscn")
	game = packed.instantiate()
	add_child(game)
	await get_tree().process_frame
	_start()

func _start() -> void:
	stats.rounds += 1
	if game.has_method(&"start_round"):
		game.start_round(mode)
	print("[soak] round %d started, mode=%s" % [stats.rounds, mode])

func _on_round_over(player_won: bool) -> void:
	print("[soak] round over at %.1fs, player_won=%s" % [elapsed, player_won])
	_release_all()
	await get_tree().create_timer(3.0, true, false, true).timeout
	if elapsed < seconds:
		_start()

func _on_hit(info: HitInfo) -> void:
	stats.hits += 1
	if info.payoff:
		stats.payoffs += 1
	if info.pursuit and info.launch_velocity.y < -5.0:
		stats.spikes += 1

## A body launched by the player: pursue it (Dash), then relaunch or spike.
func _on_launched(f: Node3D, _v: Vector3) -> void:
	stats.launches += 1
	var player := Targeting.player(get_tree())
	if player == null or f == player or rng.randf() > PURSUE_CHANCE:
		return
	var at := elapsed + rng.randf_range(0.12, 0.3)
	_tap(&"dash", at, TAP_TIME)
	var hit_at := at + rng.randf_range(0.08, 0.18)
	if rng.randf() < SPIKE_CHANCE:
		_pull_back_until = hit_at + 0.15
	_tap(&"punch" if rng.randf() < 0.5 else &"roundhouse", hit_at, TAP_TIME)
	next_action = maxf(next_action, hit_at + 0.6)

func _on_chain_ended(attacker: Node3D, count: int) -> void:
	if attacker is Fighter and (attacker as Fighter).is_player:
		stats.chains += 1
		stats.best_chain = maxi(stats.best_chain, count)

func _on_drive_impact(_h: Node3D, _v: Node3D, _t: Node3D, _p: Vector3, _s: float, result: StringName) -> void:
	if result == &"break":
		stats.drive_breaks += 1
	elif result == &"slam":
		stats.slams += 1

## Answer a counter window on the player: Counter for orange, a dodge for blue.
func _on_counter_window(_attacker: Node3D, target: Node3D, open: bool, counterable: bool) -> void:
	if not open or target != Targeting.player(get_tree()):
		return
	stats.windows += 1
	if rng.randf() > ANSWER_CHANCE:
		return
	var at := elapsed + rng.randf_range(REACT_DELAY.x, REACT_DELAY.y)
	_tap(&"counter" if counterable else &"dash", at, TAP_TIME)
	next_action = maxf(next_action, at + 0.5)

func _physics_process(delta: float) -> void:
	# Count real-ish seconds of game time regardless of slow motion.
	elapsed += delta / maxf(Engine.time_scale, 0.01)
	if elapsed >= next_report:
		next_report += 10.0
		_report()
	if elapsed >= seconds:
		_finish()
		return
	_flush_queue()
	_drive_bot()

func _drive_bot() -> void:
	var player := Targeting.player(get_tree())
	if player == null or player.is_dead():
		_release_all()
		return
	var enemies := Targeting.opponents_of(player)
	max_enemies = maxi(max_enemies, enemies.size())
	max_debris = maxi(max_debris, DebrisManager.count())
	var target: Fighter = Targeting.pick_target(player, Vector3.ZERO, 40.0)
	_steer(player, target)
	if elapsed < next_action or not _queue.is_empty():
		return
	if target == null:
		next_action = elapsed + 0.3
		return
	var dist := player.get_ground_position().distance_to(target.get_ground_position())
	var roll := rng.randf()
	if player.carry != null and player.carry.is_holding():
		_play_hold(roll)
	elif dist > Tuning.R7_TARGET_RANGE:
		if roll < 0.5:
			_tap(&"dash", elapsed, 1.2)  # sprint in (rams at higher levels)...
			_tap(&"jump", elapsed + 0.8, TAP_TIME)  # ...and jump (a wall run beside a wall)
		else:
			_tap(&"dash", elapsed, 0.6 if roll < 0.8 else TAP_TIME)  # sprint, or a dodge
		next_action = elapsed + 1.3
	elif roll < 0.15:
		_tap(&"grab", elapsed, TAP_TIME)
		next_action = elapsed + 0.6
	elif roll < 0.15 + AIR_COMBO_CHANCE:
		_play_air_combo()
	else:
		_play_combo(COMBOS[rng.randi() % COMBOS.size()])

## A combo: each step pressed STEP_GAP apart, held for its hold time (or a tap).
func _play_combo(combo: Array) -> void:
	var t := elapsed
	for step: Array in combo:
		var hold: float = step[1]
		_tap(step[0], t, hold if hold > 0.0 else TAP_TIME)
		t += rng.randf_range(STEP_GAP.x, STEP_GAP.y) + hold
	next_action = t + rng.randf_range(0.2, 0.6)

## [action, hold, gap to the next step] per step: timed for the follow jump and the hangs.
func _play_air_combo() -> void:
	var t := elapsed
	for step: Array in AIR_COMBO:
		var hold: float = step[1]
		_tap(step[0], t, hold if hold > 0.0 else TAP_TIME)
		t += hold + float(step[2])
	next_action = t + 0.8

## Holding a body: drive it (hold Dash), throw it (hold Punch to wind up), or knee it.
func _play_hold(roll: float) -> void:
	if roll < 0.45:
		_tap(&"dash", elapsed, rng.randf_range(0.8, 2.0))
	elif roll < 0.85:
		_tap(&"punch", elapsed, rng.randf_range(0.05, 0.8))
	else:
		_tap(&"leg_kick", elapsed, TAP_TIME)
	next_action = elapsed + 2.2

func _tap(action: StringName, at: float, hold: float) -> void:
	_queue.append([at, action, true])
	_queue.append([at + hold, action, false])
	_queue.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])

func _flush_queue() -> void:
	while not _queue.is_empty() and _queue[0][0] <= elapsed:
		var e: Array = _queue.pop_front()
		if not InputMap.has_action(e[1]):
			continue
		if e[2]:
			Input.action_press(e[1])
		else:
			Input.action_release(e[1])

func _steer(player: Fighter, target: Fighter) -> void:
	for a in [&"move_forward", &"move_back", &"move_left", &"move_right"]:
		Input.action_release(a)
	if elapsed < _pull_back_until:
		Input.action_press(&"move_back")  # pursuit spike: stick pulled back toward the camera
		return
	if target == null:
		return
	var to := target.get_ground_position() - player.get_ground_position()
	to.y = 0.0
	if to.length() < 1.2:
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

func _release_all() -> void:
	for e: Array in _queue:
		if not e[2] and InputMap.has_action(e[1]):
			Input.action_release(e[1])
	_queue.clear()
	for a: StringName in Controls.ACTIONS:
		if Input.is_action_pressed(a):
			Input.action_release(a)

func _report() -> void:
	var player := Targeting.player(get_tree())
	var php := "%.0f" % player.hp if player else "-"
	var pstate := str(player.get_state()) if player else "-"
	print("[soak] t=%.0fs hp=%s state=%s enemies=%d debris=%d scale=%.2f %s" % [
		elapsed, php, pstate, Targeting.opponents_of(player).size() if player else 0,
		DebrisManager.count(), Engine.time_scale, stats])

func _finish() -> void:
	set_physics_process(false)
	_release_all()
	_report()
	print("[soak] DONE mode=%s seconds=%.0f max_enemies=%d max_debris=%d" % [mode, seconds, max_enemies, max_debris])
	get_tree().quit(0)
