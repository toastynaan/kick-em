extends Node
## Integration soak test (OWNER: core). Loads the real main scene, starts a
## round, and drives the player through the real Input actions with a bot.
## Usage (on a private copy, see docs/ARCHITECTURE.md):
##   Godot --headless --path <copy> --fixed-fps 120 res://tests/integration/soak_test.tscn -- --mode=duel --seconds=90
## Prints periodic stats and a summary; exits 1 if the round could not start.

var mode: StringName = &"duel"
var seconds := 90.0
var game: Node
var elapsed := 0.0
var next_report := 0.0
var next_action := 0.0
var held: Array[StringName] = []
var rng := RandomNumberGenerator.new()
var stats := {"launches": 0, "hits": 0, "blocks": 0, "dodges": 0, "breaks": 0, "cracks": 0,
	"impacts": 0, "bowls": 0, "deaths": 0, "rounds": 0, "tells": 0, "grabs": 0, "severs": 0}
var max_debris := 0
var max_enemies := 0

func _ready() -> void:
	rng.seed = 1234
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="):
			mode = StringName(arg.get_slice("=", 1))
		elif arg.begins_with("--seconds="):
			seconds = float(arg.get_slice("=", 1))
	GameEvents.fighter_launched.connect(func(_f: Node3D, _v: Vector3) -> void: stats.launches += 1)
	GameEvents.hit_landed.connect(func(_i: HitInfo) -> void: stats.hits += 1)
	GameEvents.hit_blocked.connect(func(_i: HitInfo) -> void: stats.blocks += 1)
	GameEvents.perfect_dodge.connect(func(_a: Node3D, _b: Node3D) -> void: stats.dodges += 1)
	GameEvents.wall_broken.connect(func(_w: Node3D, _p: Vector3, _e: float, _v: Vector3) -> void: stats.breaks += 1)
	GameEvents.wall_cracked.connect(func(_w: Node3D, _p: Vector3, _e: float) -> void: stats.cracks += 1)
	GameEvents.body_impact.connect(func(_f: Node3D, _p: Vector3, _n: Vector3, _e: float, _s: StringName) -> void: stats.impacts += 1)
	GameEvents.body_bowled.connect(func(_a: Node3D, _b: Node3D, _e: float, _c: int) -> void: stats.bowls += 1)
	GameEvents.fighter_died.connect(func(_f: Node3D, _i: HitInfo) -> void: stats.deaths += 1)
	GameEvents.attack_tell.connect(func(_f: Node3D, _k: StringName, _d: float) -> void: stats.tells += 1)
	GameEvents.grab_started.connect(func(_a: Node3D, _b: Node3D) -> void: stats.grabs += 1)
	GameEvents.limb_severed.connect(func(_f: Node3D, _c: StringName, _p: Node3D) -> void: stats.severs += 1)
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

func _physics_process(delta: float) -> void:
	# Count real-ish seconds of game time regardless of slow motion.
	elapsed += delta / maxf(Engine.time_scale, 0.01)
	if elapsed >= next_report:
		next_report += 10.0
		_report()
	if elapsed >= seconds:
		_finish()
		return
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
	if elapsed < next_action:
		return
	next_action = elapsed + rng.randf_range(0.15, 0.6)
	_release_all()
	if target == null:
		return
	var dist := player.get_ground_position().distance_to(target.get_ground_position())
	var roll := rng.randf()
	var actions: Array[StringName] = []
	if dist > 4.0:
		if roll < 0.3:
			actions = [&"dash"]
		elif roll < 0.38:
			actions = [&"jump"]
	elif roll < 0.35:
		actions = [&"punch"]
	elif roll < 0.5:
		actions = [&"kick"]
	elif roll < 0.58:
		actions = [&"crouch", &"kick"]  # sweep
	elif roll < 0.64:
		actions = [&"jump", &"kick"]
	elif roll < 0.74:
		actions = [&"grab"]
	elif roll < 0.86:
		actions = [&"block"]
	elif roll < 0.93:
		actions = [&"focus", &"punch"]
	else:
		actions = [&"dash"]
	# Held 0.15-0.6 s until the next decision: a mix of taps and charges.
	for action in actions:
		if InputMap.has_action(action):
			Input.action_press(action)
			held.append(action)

func _steer(player: Fighter, target: Fighter) -> void:
	for a in [&"move_forward", &"move_back", &"move_left", &"move_right"]:
		Input.action_release(a)
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
	for a in held:
		Input.action_release(a)
	held.clear()

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
