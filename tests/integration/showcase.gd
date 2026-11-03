extends Node
## Visual showcase (OWNER: core). Runs the real game windowed, stages scripted
## fights with a cinematic camera and writes contact sheets of frames.
## The game starts fullscreen and Godot's --windowed flag does not override the
## project setting, so write an override.cfg into the copy first:
##   printf '[display]\nwindow/size/mode=0\n' > <copy>/override.cfg
##   Godot --path <copy> --resolution 1600x900 res://tests/integration/showcase.tscn -- --out=<dir>
## Round 7 shots: uppercut into roundhouse through drywall, a sprint front kick
## into brick, a counter in the garage, a wound-up throw into drywall, then a
## waves crowd under the game's own camera.

var out_dir := "user://showcase"
var game: Node
var player: Fighter
var duelist: Fighter
var cam: Camera3D
var sheet := SnapSheet.new()

func _ready() -> void:
	if get_window().mode != Window.MODE_WINDOWED:
		push_error("[showcase] the window is fullscreen: write <copy>/override.cfg (see the usage comment)")
		get_tree().quit(1)
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.get_slice("=", 1)
	DirAccess.make_dir_recursive_absolute(out_dir)
	game = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(game)
	await _wait(0.5)
	game.start_round(&"duel")
	await _wait(1.5)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player = Targeting.player(get_tree())
	duelist = Targeting.opponents_of(player)[0]
	for f in [player, duelist]:
		f.max_hp = 99999.0
		f.hp = 99999.0
	# Remove the brain outright: its guard and grab breaks run from signals,
	# which a disabled process_mode does not stop.
	AttackDirector.unregister_enemy(duelist)
	duelist.brain.queue_free()
	duelist.brain = null
	cam = Camera3D.new()
	cam.fov = 60.0
	add_child(cam)

	# Overview of the yard under the game camera first.
	await _wait(0.3)
	await sheet.capture(get_viewport(), "game cam start")
	cam.make_current()
	_cam_at(Vector3(0, 24, 26), Vector3(0, 0, -2))
	await sheet.capture(get_viewport(), "yard overview")
	_cam_at(Vector3(-2.5, 1.7, 3.2), Vector3(-0.3, 1.1, 0.0))
	await _stage(player, Vector3(0.6, 0.05, 0), Vector3.LEFT)
	await _stage(duelist, Vector3(-0.6, 0.05, 0), Vector3.RIGHT)
	await _wait(0.4)
	await sheet.capture(get_viewport(), "fighters close-up")
	sheet.save(out_dir.path_join("00_overview.png"))

	await _shot_kick_drywall()
	await _shot_dash_kick_brick()
	await _shot_counter_garage()
	await _shot_throw_drywall()
	await _shot_crowd()
	print("[showcase] DONE")
	get_tree().quit(0)

func _shot_kick_drywall() -> void:
	await _stage(duelist, Vector3(-8.6, 0.05, 0.0), Vector3.RIGHT)
	await _stage(player, Vector3(-7.4, 0.05, 0.0), Vector3.LEFT)
	_cam_at(Vector3(-7.0, 1.8, 6.0), Vector3(-10.0, 1.0, 0.0))
	await _wait(0.3)
	await sheet.capture(get_viewport(), "before uppercut")
	await _tap(CombatController.Action.UPPERCUT)
	await _wait(0.3)
	await sheet.capture(get_viewport(), "lifted")
	await _tap(CombatController.Action.ROUNDHOUSE)
	for t in [0.25, 0.12, 0.12, 0.2, 0.4]:
		await _wait(t)
		await sheet.capture(get_viewport(), "roundhouse +%.2f" % t)
	sheet.save(out_dir.path_join("01_kick_drywall.png"))
	await _wait(1.5)

func _shot_dash_kick_brick() -> void:
	await _stage(duelist, Vector3(8.6, 0.05, -3.0), Vector3.LEFT)
	await _stage(player, Vector3(5.6, 0.05, -3.0), Vector3.RIGHT)
	_cam_at(Vector3(7.0, 1.9, 3.5), Vector3(10.0, 1.0, -3.0))
	await _wait(0.3)
	await sheet.capture(get_viewport(), "before sprint kick")
	# Back off, then sprint in (Dash held) and front kick at speed: a sprint strike launch.
	await _stage(player, Vector3(1.6, 0.05, -3.0), Vector3.RIGHT)
	player.move_input = Vector3.RIGHT
	player.combat.press(CombatController.Action.DASH)
	await _wait(0.75)
	await _tap(CombatController.Action.FRONT_KICK)
	player.combat.release(CombatController.Action.DASH)
	player.move_input = Vector3.ZERO
	for t in [0.15, 0.12, 0.12, 0.25, 0.5]:
		await _wait(t)
		await sheet.capture(get_viewport(), "sprint kick +%.2f" % t)
	sheet.save(out_dir.path_join("02_dash_kick_brick.png"))
	await _wait(1.5)

func _shot_counter_garage() -> void:
	await _stage(player, Vector3(-3.0, 0.05, -9.7), Vector3.BACK)
	await _stage(duelist, Vector3(-3.0, 0.05, -8.5), Vector3.FORWARD)
	_cam_at(Vector3(2.0, 2.2, -5.0), Vector3(-3.0, 1.0, -10.0))
	await _wait(0.3)
	await sheet.capture(get_viewport(), "before e_hook")
	var tell := 0.6
	duelist.combat.start_enemy_attack(&"e_hook", tell)
	await _wait(0.15)
	await sheet.capture(get_viewport(), "tell")
	await _wait(tell - 0.15 - 0.2)  # inside the counter window (R7_COUNTER_WINDOW before the first active frame)
	await _tap(CombatController.Action.COUNTER)
	await _wait(0.06)
	await sheet.capture(get_viewport(), "counter")
	await _wait(0.4)
	await _tap(CombatController.Action.GUT_PUNCH)
	for t in [0.1, 0.15, 0.2, 0.4]:
		await _wait(t)
		await sheet.capture(get_viewport(), "counter +%.2f" % t)
	sheet.save(out_dir.path_join("03_counter_garage.png"))
	await _wait(1.5)

func _shot_throw_drywall() -> void:
	await _stage(duelist, Vector3(-8.2, 0.05, -3.0), Vector3.RIGHT)
	await _stage(player, Vector3(-7.1, 0.05, -3.0), Vector3.LEFT)
	_cam_at(Vector3(-6.5, 2.0, 3.5), Vector3(-11.0, 1.0, -3.0))
	await _wait(0.3)
	await _tap(CombatController.Action.GRAB)
	await _wait(0.35)
	await sheet.capture(get_viewport(), "grab")
	# Turn toward the wall and wind up the baseball throw (LIGHT held), then let go.
	player.face_dir = Vector3.LEFT
	player.combat.press(CombatController.Action.LIGHT)
	await _wait(0.45)
	await sheet.capture(get_viewport(), "wind-up")
	await _wait(0.3)
	player.combat.release(CombatController.Action.LIGHT)
	for t in [0.12, 0.15, 0.3, 0.6]:
		await _wait(t)
		await sheet.capture(get_viewport(), "throw +%.2f" % t)
	sheet.save(out_dir.path_join("04_throw_drywall.png"))
	await _wait(1.0)

func _shot_crowd() -> void:
	game.start_round(&"waves")
	await _wait(1.0)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player = Targeting.player(get_tree())
	player.max_hp = 99999.0
	player.hp = 99999.0
	var game_cam := get_viewport().get_camera_3d()
	if cam:
		cam.queue_free()
		cam = null
	await _wait(0.2)
	game_cam = get_viewport().get_camera_3d()
	if game_cam:
		game_cam.make_current()
	# Walk toward the enemies and fight with simple scripted inputs.
	for i in 12:
		var target := Targeting.pick_target(player, Vector3.ZERO, 40.0)
		if target:
			var to := target.get_ground_position() - player.get_ground_position()
			to.y = 0.0
			player.move_input = to.normalized() if to.length() > 1.6 else Vector3.ZERO
			player.face_dir = to.normalized()
			if to.length() < 2.0:
				var acts := [CombatController.Action.LIGHT, CombatController.Action.GUT_PUNCH,
					CombatController.Action.UPPERCUT, CombatController.Action.ROUNDHOUSE,
					CombatController.Action.LEG_KICK, CombatController.Action.FRONT_KICK]
				await _tap(acts[i % acts.size()])
		await _wait(1.25)
		if i % 2 == 1:
			await sheet.capture(get_viewport(), "crowd %d" % i)
	sheet.save(out_dir.path_join("05_crowd.png"))

## A quick tap (shorter than Tuning.R7_HOLD_THRESHOLD, so never a heavy).
func _tap(action: int) -> void:
	player.combat.press(action)
	await _wait(0.05)
	player.combat.release(action)

func _stage(f: Fighter, pos: Vector3, look: Vector3) -> void:
	if f.ragdoll.is_simulating() or f.get_state() != RagdollController.State.ANIMATED:
		f.ragdoll.force_recover()
		await get_tree().physics_frame
		await get_tree().physics_frame
	f.combat.cancel()
	f.move_input = Vector3.ZERO
	f.teleport_to(pos, look)

func _cam_at(pos: Vector3, target: Vector3) -> void:
	cam.global_position = pos
	cam.look_at(target, Vector3.UP)
	cam.reset_physics_interpolation()

func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout
