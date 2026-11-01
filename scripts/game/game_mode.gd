class_name GameMode
extends Node3D
## Root of scenes/main.tscn. Title menu (Duel / Waves / Ragdoll Lab), builds
## the arena (YardBuilder), spawns the player and enemies (FighterFactory),
## runs waves (Tuning.WAVES, at most Tuning.MAX_ENEMIES_ON_FIELD at once),
## heals between waves, corpse cleanup (Tuning.CORPSE_*), round over and
## restart (resets TimeDirector, AttackDirector, ImpactResolver, DebrisManager,
## BloodFX). OWNER: agent E (feel & flow).
##
## Restart and "main menu" reload this scene; `pending_mode` (static, so it
## survives the reload) makes the fresh scene skip the title and start a round.

enum Phase { TITLE, FIGHTING, BREATHER, ENDING, OVER }

# Local tuning (candidates for Tuning).
const WAVE_BREATHER := 4.0       ## s between "WAVE CLEARED" and the next wave
const SPAWN_SPACING := 0.8       ## s between two enemy spawns
const SPAWN_CLEARANCE := 1.4     ## m: a spawn point is busy while a fighter is this close
const SPAWN_STALL_MAX := 2.5     ## s all spawn points may stay busy before spawning beside one
const BREACH_DELAY := 1.5       ## s from first crack to burst (room for D's three thumps)
const BREACH_BEHIND := 1.4       ## m behind the facade panel the breaching enemy waits
const WAVES_FOLLOW_TIME := 0.8  ## s follow-cam in waves (tokens pause while it runs)
const KO_PANEL_DELAY := 0.9      ## real s after the KO slow motion before the panel
const CORPSE_FADE_TIME := 1.5    ## s fade-out duration passed to fade_out_and_free
const TITLE_ORBIT_RATE := 0.07   ## rad/s of the title backdrop camera
const LAB_SCENE := "res://scenes/ragdoll_lab.tscn"

static var pending_mode: StringName = &""

## Show the title menu on _ready when no round is pending (tests set false).
var show_title := true
var breather_time := WAVE_BREATHER

var mode: StringName = &""
var phase := Phase.TITLE
var arena: YardBuilder
var player: Fighter
var camera_rig: CameraRig
var hud: HUD
var menus: GameMenus
var fighters_root: Node3D

var wave_index := -1
var wave_total := 0
var kills := 0

var _wave_queue: Array[StringName] = []
## Untyped: entries may be freed by other code before _poll_deaths sees them,
## and a freed object in a typed variable is a script error.
var _alive: Array = []
var _handled_dead := {}             ## instance id -> true
var _corpses: Array[Dictionary] = []  ## {"fighter": Fighter, "at": float real s}
var _spawn_cd := 0.0
var _spawn_cursor := 0
var _spawn_blocked := 0.0
var _gen := 0
var _round_started_at := 0.0
var _title_cam: Camera3D
var _arena_used := false   ## the arena has hosted a round (a fresh one is built next time)
var _title_yaw := 0.0

func _ready() -> void:
	add_to_group(&"game_mode")
	menus = GameMenus.new()
	menus.name = "Menus"
	add_child(menus)
	menus.duel_pressed.connect(_on_choose.bind(&"duel"))
	menus.waves_pressed.connect(_on_choose.bind(&"waves"))
	menus.lab_pressed.connect(_on_lab)
	menus.quit_pressed.connect(_on_quit)
	menus.pause_requested.connect(pause)
	menus.resume_pressed.connect(resume)
	menus.restart_pressed.connect(restart)
	menus.menu_pressed.connect(back_to_menu)
	GameEvents.fighter_died.connect(_on_fighter_died_event)
	if pending_mode != &"":
		var m := pending_mode
		pending_mode = &""
		start_round(m)
	elif show_title:
		_show_title()

# --- Public API -------------------------------------------------------------------
## &"duel" (1v1 vs Duelist) or &"waves" (4 waves in The Yard).
## Idempotent: a running or finished round is torn down first (fighters,
## camera, HUD, timers, corpses, autoload state, and the arena unless it is
## the untouched title backdrop), then everything is built fresh.
func start_round(round_mode: StringName) -> void:
	_teardown_round(not _arena_used)
	mode = round_mode if round_mode in [&"duel", &"waves"] else &"duel"
	_ensure_arena()
	_arena_used = true
	fighters_root = Node3D.new()
	fighters_root.name = "Fighters"
	add_child(fighters_root)

	var duel_spawns := arena.get_duel_spawns()
	var duel := mode == &"duel"
	var p_xform: Transform3D = duel_spawns[0] if duel and duel_spawns.size() > 0 else arena.get_player_spawn()
	if duel and duel_spawns.size() > 1:
		p_xform = _facing(p_xform, duel_spawns[1].origin)
	elif not duel:
		p_xform = _facing(p_xform, arena.get_courtyard_bounds().get_center())
	player = FighterFactory.spawn_player(fighters_root, p_xform)
	player.face_dir = -p_xform.basis.z
	player.reset_physics_interpolation()
	AttackDirector.set_player(player)

	camera_rig = CameraRig.new()
	camera_rig.name = "CameraRig"
	camera_rig.target = player
	if mode == &"waves":
		# Keep crowds attacking: short follow-cam, only for launches heading at a wall.
		camera_rig.follow_time = WAVES_FOLLOW_TIME
		camera_rig.follow_needs_wall = true
	add_child(camera_rig)

	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)
	hud.set_player(player)
	hud.set_mode(mode)

	kills = 0
	_round_started_at = TimeDirector.now()
	phase = Phase.FIGHTING
	menus.can_pause = true
	_capture_mouse()

	if duel:
		wave_total = 1
		var e_xform: Transform3D = duel_spawns[1] if duel_spawns.size() > 1 else Transform3D(Basis(), p_xform.origin + Vector3(0, 0, -8))
		e_xform = _facing(e_xform, p_xform.origin)
		var duelist := _spawn_enemy(&"duelist", e_xform, PackedVector3Array())
		hud.set_opponent(duelist)
		hud.set_enemies_left(1)
		hud.show_banner("FIGHT", "Duel vs the Duelist", 1.6)
	else:
		wave_total = Tuning.WAVES.size()
		_begin_wave(0)
	GameEvents.round_started.emit(mode)

## Free everything a round built and clear all round state. Nodes leave the
## tree at once (remove_child) so groups such as "player" never see the old
## round; pending _after() callbacks are invalidated by bumping _gen.
func _teardown_round(keep_arena: bool) -> void:
	_gen += 1
	get_tree().paused = false
	menus.hide_all()
	menus.can_pause = false
	_free_title_cam()
	var doomed: Array = [hud, camera_rig, fighters_root]
	if not keep_arena:
		doomed.append(arena)
	for n in doomed:
		if is_instance_valid(n):
			if n.get_parent() == self:
				remove_child(n)
			n.queue_free()
	hud = null
	camera_rig = null
	fighters_root = null
	player = null
	if not keep_arena:
		arena = null
		_arena_used = false
	_alive.clear()
	_corpses.clear()
	_handled_dead.clear()
	_wave_queue.clear()
	wave_index = -1
	wave_total = 0
	kills = 0
	_won = false
	_spawn_cd = 0.0
	_spawn_blocked = 0.0
	_spawn_cursor = 0
	reset_globals()

## Reset every autoload that holds round state.
func reset_globals() -> void:
	TimeDirector.reset()
	AttackDirector.reset()
	ImpactResolver.reset()
	DebrisManager.reset()
	BloodFX.reset()

func pause() -> void:
	if phase == Phase.TITLE or phase == Phase.OVER or get_tree().paused:
		return
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	menus.show_pause()

func resume() -> void:
	if not get_tree().paused:
		return
	get_tree().paused = false
	menus.hide_all()
	menus.can_pause = phase != Phase.OVER
	if phase == Phase.OVER:
		menus.show_round_over(_won, _stats_text())
	else:
		_capture_mouse()

## Rebuild the same mode from scratch (reloads the scene).
func restart() -> void:
	_reload_with(mode if mode != &"" else &"duel")

func back_to_menu() -> void:
	_reload_with(&"")

func get_alive_enemies() -> Array[Fighter]:
	var out: Array[Fighter] = []
	for f in _alive:
		if is_instance_valid(f) and f is Fighter and not f.is_dead():
			out.append(f)
	return out

## Enemies still to beat in this wave: alive + queued.
func get_enemies_left() -> int:
	return get_alive_enemies().size() + _wave_queue.size()

func is_round_over() -> bool:
	return phase == Phase.ENDING or phase == Phase.OVER

# --- Title -----------------------------------------------------------------------
func _show_title() -> void:
	phase = Phase.TITLE
	menus.can_pause = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_ensure_arena()
	_title_cam = Camera3D.new()
	_title_cam.name = "TitleCamera"
	_title_cam.fov = 60.0
	_title_cam.far = 250.0
	_title_cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_title_cam)
	_title_cam.make_current()
	_update_title_cam(0.0)
	menus.show_title()

func _update_title_cam(dt: float) -> void:
	if _title_cam == null:
		return
	_title_yaw += TITLE_ORBIT_RATE * dt
	var c := arena.get_courtyard_bounds().get_center() if arena else Vector3.ZERO
	c.y = 1.0
	var pos := c + Vector3(sin(_title_yaw) * 17.0, 8.5, cos(_title_yaw) * 17.0)
	_title_cam.look_at_from_position(pos, c + Vector3(-3.0, 0.0, 0.0).rotated(Vector3.UP, _title_yaw), Vector3.UP)

func _free_title_cam() -> void:
	if _title_cam:
		_title_cam.queue_free()
		_title_cam = null

func _on_choose(round_mode: StringName) -> void:
	AudioFX.play_ui(&"ui")
	start_round(round_mode)

func _on_lab() -> void:
	if not ResourceLoader.exists(LAB_SCENE):
		return
	reset_globals()
	get_tree().paused = false
	get_tree().change_scene_to_file(LAB_SCENE)

func _on_quit() -> void:
	get_tree().quit()

# --- Arena and spawning -------------------------------------------------------------
func _ensure_arena() -> void:
	if arena != null:
		return
	arena = YardBuilder.new()
	arena.name = "Arena"
	add_child(arena)
	if not arena.is_in_group(&"arena"):
		arena.add_to_group(&"arena")
	arena.build()

func _spawn_enemy(archetype: StringName, xform: Transform3D, path: PackedVector3Array) -> Fighter:
	var f := FighterFactory.spawn_enemy(fighters_root, archetype, xform, path)
	f.face_dir = -xform.basis.z
	f.reset_physics_interpolation()
	AttackDirector.register_enemy(f)
	_alive.append(f)
	return f

## Look from xform.origin toward `toward` on the floor plane (fighters face -Z).
static func _facing(xform: Transform3D, toward: Vector3) -> Transform3D:
	var d := toward - xform.origin
	d.y = 0.0
	if d.length() < 0.01:
		return xform
	return Transform3D(Basis.looking_at(d.normalized(), Vector3.UP), xform.origin)

# --- Waves ----------------------------------------------------------------------
func _begin_wave(index: int) -> void:
	wave_index = index
	_wave_queue.clear()
	var spec: Dictionary = Tuning.WAVES[index]
	for archetype: StringName in spec:
		for i in int(spec[archetype]):
			_wave_queue.append(archetype)
	_spawn_cd = 0.0
	phase = Phase.FIGHTING
	if index >= 1:
		_stage_breach()
	hud.set_wave(index, wave_total)
	hud.set_enemies_left(get_enemies_left())
	hud.show_banner("WAVE %d" % (index + 1), "FINAL WAVE" if index == wave_total - 1 else "of %d" % wave_total, 1.8)
	GameEvents.wave_started.emit(index, wave_total)

func _spawn_tick(delta: float) -> void:
	_spawn_cd -= delta
	if _spawn_cd > 0.0 or _wave_queue.is_empty():
		return
	if get_alive_enemies().size() >= Tuning.MAX_ENEMIES_ON_FIELD:
		return
	var entry := _pick_spawn_entry()
	var offset := Vector3.ZERO
	if entry.is_empty():
		# Every spawn point is busy. Wait a little, then spawn beside one anyway
		# so an enemy loitering at a spawn can never stall the wave.
		_spawn_blocked += delta
		var entries := arena.get_enemy_spawns()
		if _spawn_blocked < SPAWN_STALL_MAX or entries.is_empty():
			return
		entry = entries[_spawn_cursor % entries.size()]
		_spawn_cursor += 1
		offset = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)).normalized() * SPAWN_CLEARANCE
	_spawn_blocked = 0.0
	var archetype: StringName = _wave_queue.pop_front()
	var pos: Vector3 = entry.get("position", Vector3.ZERO) + offset
	var path: PackedVector3Array = entry.get("path", PackedVector3Array())
	var look_at_pos: Vector3 = path[0] if path.size() > 0 and path[0].distance_to(pos) > 0.5 else arena.get_courtyard_bounds().get_center()
	var xform := _facing(Transform3D(Basis(), pos), look_at_pos)
	_spawn_enemy(archetype, xform, path)
	_spawn_cd = SPAWN_SPACING

## Next spawn entry (round robin) whose spawn point is not occupied.
func _pick_spawn_entry() -> Dictionary:
	var entries := arena.get_enemy_spawns()
	if entries.is_empty():
		return {}
	for k in entries.size():
		var e: Dictionary = entries[(_spawn_cursor + k) % entries.size()]
		var pos: Vector3 = e.get("position", Vector3.ZERO)
		var busy := false
		for n in get_tree().get_nodes_in_group(&"fighters"):
			var f := n as Fighter
			if f and not f.is_dead() and CameraRig._flat_dist(f.get_ground_position(), pos) < SPAWN_CLEARANCE:
				busy = true
				break
		if not busy:
			_spawn_cursor = (_spawn_cursor + k + 1) % entries.size()
			return e
	return {}

## Spec creative angle "enemies arrive through walls": from wave 2 the first
## enemy of the wave waits in a room behind an intact facade panel, the panel
## cracks, and it bursts open BREACH_DELAY s later (YardBuilder.breach). The
## Brute uses the garage roll door. Skipped if the arena has no such walls.
func _stage_breach() -> void:
	# Dynamic calls: breach() and friends are D's additions, not contract API.
	if _wave_queue.is_empty() or not arena.has_method(&"breach"):
		return
	var archetype: StringName = _wave_queue[0]
	var wall: Node3D = null
	if archetype == &"brute" and arena.has_method(&"get_roll_door"):
		var door := arena.call(&"get_roll_door") as Node3D
		if door != null and not door.get(&"is_broken"):
			wall = door
	if wall == null and arena.has_method(&"get_breach_walls"):
		wall = _pick_breach_wall(arena.call(&"get_breach_walls"))
	if wall == null:
		return
	if hud:
		hud.suppress_wall_break(wall)
	var into := wall.global_basis.z
	into.y = 0.0
	if into.length() < 0.01:
		return
	into = into.normalized()
	var base := wall.global_position
	base.y = arena.get_player_spawn().origin.y
	var pos := base - into * BREACH_BEHIND
	_wave_queue.pop_front()
	_spawn_enemy(archetype, _facing(Transform3D(Basis(), pos), base), PackedVector3Array([base + into * 2.5]))
	arena.call(&"breach", wall, BREACH_DELAY)
	_spawn_cd = BREACH_DELAY

## A breach only teaches if the player sees it: prefer panels on screen, the
## west drywall offices first (spec: The map), then any visible panel, then
## offices, then anything.
func _pick_breach_wall(walls: Array) -> Node3D:
	if walls.is_empty():
		return null
	var on_screen: Array = []
	if camera_rig:
		on_screen = walls.filter(func(w: Node3D) -> bool:
			return camera_rig.is_on_screen(w.global_position) or camera_rig.is_on_screen(w.global_position + Vector3.UP))
	var offices := func(list: Array) -> Array:
		return list.filter(func(w: Node3D) -> bool: return w.global_position.x < -10.0)
	for pool: Array in [offices.call(on_screen), on_screen, offices.call(walls), walls]:
		if not pool.is_empty():
			return pool.pick_random()
	return null

func _wave_done() -> void:
	phase = Phase.BREATHER
	GameEvents.wave_cleared.emit(wave_index)
	if player and is_instance_valid(player) and not player.is_dead():
		player.heal_fraction(Tuning.HEAL_BETWEEN_WAVES)
	hud.show_banner("WAVE CLEARED", "+%d%% HP" % roundi(Tuning.HEAL_BETWEEN_WAVES * 100.0), minf(breather_time * 0.6, 2.4))
	_after(breather_time, _on_breather_done.bind(_gen, wave_index + 1))

func _on_breather_done(gen: int, next_index: int) -> void:
	if gen != _gen or phase != Phase.BREATHER:
		return
	_begin_wave(next_index)

# --- Per frame ----------------------------------------------------------------------
func _process(_delta: float) -> void:
	if phase == Phase.TITLE:
		_update_title_cam(TimeDirector.frame_delta())

func _physics_process(delta: float) -> void:
	if phase == Phase.TITLE or player == null:
		return
	_poll_deaths()
	_update_corpses()
	if mode == &"waves" and phase == Phase.FIGHTING:
		_spawn_tick(delta)
	if hud:
		hud.set_enemies_left(get_enemies_left())

func _unhandled_input(event: InputEvent) -> void:
	if phase in [Phase.FIGHTING, Phase.BREATHER, Phase.ENDING] and event is InputEventMouseButton \
			and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_capture_mouse()

# --- Deaths, corpses, round end ---------------------------------------------------------
func _on_fighter_died_event(fighter: Node3D, _info: HitInfo) -> void:
	var f := fighter as Fighter
	if f != null and (f == player or _alive.has(f)):
		_handle_death(f)

## Death detection does not depend on the event alone: a fighter at 0 HP (or
## freed) is handled here too, so the loop works whatever emits fighter_died.
func _poll_deaths() -> void:
	if player != null and is_instance_valid(player) and player.is_dead():
		_handle_death(player)
	for i in range(_alive.size() - 1, -1, -1):
		var f = _alive[i]
		if not is_instance_valid(f):
			_alive.remove_at(i)
			_after_enemy_removed(null)
		elif f.is_dead():
			_handle_death(f)

func _handle_death(f: Fighter) -> void:
	var id := f.get_instance_id()
	if _handled_dead.has(id):
		return
	_handled_dead[id] = true
	if f == player:
		_end_round(false, f)
		return
	_alive.erase(f)
	kills += 1
	AttackDirector.unregister_enemy(f)
	_corpses.append({"fighter": f, "at": TimeDirector.now()})
	_after_enemy_removed(f)

func _after_enemy_removed(last: Fighter) -> void:
	if phase != Phase.FIGHTING:
		return
	if not get_alive_enemies().is_empty() or not _wave_queue.is_empty():
		return
	if mode == &"duel" or wave_index >= wave_total - 1:
		_end_round(true, last)
	else:
		_wave_done()

func _update_corpses() -> void:
	var t := TimeDirector.now()
	for i in range(_corpses.size() - 1, -1, -1):
		if not is_instance_valid(_corpses[i]["fighter"]):
			_corpses.remove_at(i)
	while _corpses.size() > Tuning.CORPSE_MAX:
		_fade_corpse(0)
	while not _corpses.is_empty() and t - float(_corpses[0]["at"]) > Tuning.CORPSE_FADE_AFTER:
		_fade_corpse(0)

func _fade_corpse(i: int) -> void:
	var f = _corpses[i]["fighter"]
	_corpses.remove_at(i)
	if is_instance_valid(f):
		f.fade_out_and_free(CORPSE_FADE_TIME)

var _won := false

func _end_round(won: bool, focus: Fighter) -> void:
	if phase == Phase.ENDING or phase == Phase.OVER:
		return
	phase = Phase.ENDING
	_won = won
	_wave_queue.clear()
	GameEvents.round_over.emit(won)
	TimeDirector.request_slowmo(Tuning.KO_SLOWMO.x, Tuning.KO_SLOWMO.y, TimeDirector.PRIO_KO)
	var focus_node: Node3D = focus if focus != null and is_instance_valid(focus) else player
	if camera_rig and focus_node and is_instance_valid(focus_node):
		camera_rig.start_orbit(focus_node)
	if hud:
		hud.set_round_over()
	_after(Tuning.KO_SLOWMO.y + KO_PANEL_DELAY, _show_round_over.bind(_gen))

func _show_round_over(gen: int) -> void:
	if gen != _gen:
		return
	phase = Phase.OVER
	menus.can_pause = false
	if player and is_instance_valid(player) and player.brain:
		if &"enabled" in player.brain:
			player.brain.set(&"enabled", false)  # PlayerController freezes input
		else:
			player.brain.process_mode = Node.PROCESS_MODE_DISABLED
		player.move_input = Vector3.ZERO
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if not get_tree().paused:
		menus.show_round_over(_won, _stats_text())

func _stats_text() -> String:
	var secs := int(TimeDirector.now() - _round_started_at)
	@warning_ignore("integer_division")
	var time_s := "%d:%02d" % [secs / 60, secs % 60]
	if mode == &"waves":
		var reached := "all %d waves" % wave_total if _won else "wave %d of %d" % [wave_index + 1, wave_total]
		return "Waves  ·  %s  ·  %d KOs  ·  %s" % [reached, kills, time_s]
	return "Duel vs the Duelist  ·  %s" % time_s

# --- Helpers ----------------------------------------------------------------------------
## Call `cb` after `seconds` of real time; the timer pauses with the tree and
## dies with this node (the connection is to a method of this object).
func _after(seconds: float, cb: Callable) -> void:
	get_tree().create_timer(seconds, false, false, true).timeout.connect(cb)

func _capture_mouse() -> void:
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _reload_with(next_mode: StringName) -> void:
	reset_globals()
	get_tree().paused = false
	pending_mode = next_mode
	if get_tree().current_scene == self:
		get_tree().reload_current_scene()
	elif next_mode != &"":
		pending_mode = &""
		start_round(next_mode)  # not the current scene (tests, harnesses): rebuild in place
	else:
		pending_mode = &""
		_teardown_round(false)
		_show_title()
