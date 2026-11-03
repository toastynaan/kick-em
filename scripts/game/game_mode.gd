class_name GameMode
extends Node3D
## Root of scenes/main.tscn. Title menu (Duel / Waves / Ragdoll Lab / Grab Lab),
## builds the arena (YardBuilder), spawns the player and enemies (FighterFactory),
## and runs the round (Feel Reference: Health, damage and enemies; F6; F11):
## - Waves: Tuning.WAVES, then one more enemy per wave from Tuning.WAVE_GROWTH_MIX
##   (cycled), at most Tuning.MAX_ENEMIES_ON_FIELD alive at once. The run lasts
##   until the player dies. AttackDirector.set_wave() at each wave start.
## - The last enemy of a wave: GameEvents.last_kill (E plays the close-up and
##   the 0.2x slow time); the next wave waits until it has played. Then
##   Tuning.HEAL_BETWEEN_WAVES_HP back. No regen during a wave.
## - Player death: E's 0.3x slow time and death camera, then the results screen
##   and GameEvents.run_ended(stats). In Duel the round is lost.
## - Bodies stay for the round, up to Tuning.CORPSE_MAX; past that the oldest fades.
## - F11 persistence check: at the end of every wave the bodies, broken props and
##   clutter, wall holes, structure collapses, floor marks and decals created
##   (counted from events) are compared with what the world still holds, and
##   logged (get_persistence_report()). Round 6 adds clutter, collapses and floor.
## - The player's upgrades are the pause menu's Debug settings (Tuning.debug_*,
##   loaded from user://settings.cfg at start; every reader takes them live).
##   Waves use them as they are. Round 8: the Duel plays fully upgraded: its
##   start sets the player's own values aside and applies every upgrade at
##   Tuning.R8_UPGRADE_MAX (GameMenus.apply_max_upgrades, before the fighters
##   spawn); the round's end, leaving the Duel (teardown, the title, a lab) or
##   this node leaving the tree puts them back. A restart rebuilds the Duel at
##   max. Saves never write the max (GameMenus.save_debug_settings).
## - Results: kills, time, the biggest single hit (damage, move, reaction) and
##   the destruction counts.
## Restart (Backspace / Back, the pause menu, the results) and "main menu"
## reload this scene; `pending_mode` (static, so it survives the reload) makes
## the fresh scene skip the title and start a round.
## OWNER: agent J (HUD, flow & menus).

enum Phase { TITLE, FIGHTING, BREATHER, ENDING, OVER, CLEARING }

# Local tuning (candidates for Tuning).
const WAVE_BREATHER := 4.0       ## s between "WAVE CLEARED" and the next wave
const SPAWN_SPACING := 0.8       ## s between two enemy spawns
const SPAWN_CLEARANCE := 1.4     ## m: a spawn point is busy while a fighter is this close
const SPAWN_STALL_MAX := 2.5     ## s all spawn points may stay busy before spawning beside one
const BREACH_DELAY := 1.5        ## s from first crack to burst (room for D's three thumps)
const BREACH_BEHIND := 1.4       ## m behind the facade panel the breaching enemy waits
## Real s between the end of the death camera / last-kill slow time and the
## results panel: a beat to see the body settle before the menu covers it.
const RESULTS_BEAT := 0.35
## Real s at most the next wave waits on a last-kill close-up that is still playing.
const LAST_KILL_HOLD_MAX := 3.0
const CORPSE_FADE_TIME := 1.5    ## s fade-out of the oldest body past Tuning.CORPSE_MAX
const TITLE_ORBIT_RATE := 0.07   ## rad/s of the title backdrop camera
## TimeDirector.PRIO_KO of the pre-Round 5 TimeDirector, used only by the
## fallback below while TimeDirector does not yet request slow time from events.
const FALLBACK_SLOWMO_PRIO := 4
const LAB_SCENE := "res://scenes/ragdoll_lab.tscn"
const GRAB_LAB_SCENE := "res://scenes/grab_lab.tscn"  ## agent G's grab lab (Esc returns to main.tscn)

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
## Duel: 1. Waves: 0 (endless: the run lasts until the player dies).
var wave_total := 0
var waves_cleared := 0
var kills := 0
## F11: the report logged at the end of each wave (newest last).
var persistence_log: Array[Dictionary] = []

var _wave_queue: Array[StringName] = []
## Untyped: entries may be freed by other code before _poll_deaths sees them,
## and a freed object in a typed variable is a script error.
var _alive: Array = []
var _handled_dead := {}             ## instance id -> true
var _corpses: Array = []            ## dead enemy Fighters, oldest first (untyped: may be freed)
var _spawn_cd := 0.0
var _spawn_cursor := 0
var _spawn_blocked := 0.0
var _gen := 0
var _round_started_at := 0.0
var _round_time := -1.0             ## frozen run time once the round is decided
var _title_cam: Camera3D
var _arena_used := false   ## the arena has hosted a round (a fresh one is built next time)
var _title_yaw := 0.0
var _won := false

# Run stats (results screen).
var _biggest_dmg := 0.0                 ## the player's hardest single hit (hit_landed damage)
var _biggest_move: StringName = &""
var _biggest_react: StringName = &""    ## its Round 7 reaction (HitInfo.react, else the tier name)
var _walls_broken := {}             ## wall id -> true (staged breaches left out)
var _limbs_taken := 0

# F11 ledger: creations counted from events this round.
var _spawned_ids := {}              ## enemy instance id -> true (this round)
var _died_ids := {}                 ## enemy deaths seen (fighter_died or poll)
var _fading_ids := {}               ## bodies faded past CORPSE_MAX
var _hole_ids := {}                 ## panels and pillars that reported a hole (wall_broken)
## Every non-wall breakable that broke: D's props (wall_broken), K's clutter
## (furniture_broken), loose props (wall_struck "break" or furniture_broken).
var _prop_ids := {}
var _collapses := 0                 ## GameEvents.structure_collapsed this round
var _collapses_overhead := 0        ## ...of them overhead pieces (each leaves a FallingPiece)
var _collapses_by_fight := 0        ## ...not from a staged breach (results screen)
var _floor_cells := {}              ## floor_damaged: cell position key -> highest level
var _thrown_props_broken := 0       ## GameEvents.prop_broken (ThrowableProp)
var _loose_props: Array = []        ## loose props in the arena at round start (untyped: freed on break)
var _world_base := {}               ## world counts before the round (pre-broken scenery)
var _decal_high := 0                ## most blood decals seen at once (fallback for a creation count)
var _debris_registered := 0

func _ready() -> void:
	add_to_group(&"game_mode")
	CameraRig.load_settings()        # mouse sensitivity / invert Y from user://settings.cfg
	GameMenus.load_debug_settings()  # the player's upgrades (speed cap, ram, teleport, pursuit) and the F3 overlay
	menus = GameMenus.new()
	menus.name = "Menus"
	add_child(menus)
	menus.duel_pressed.connect(_on_choose.bind(&"duel"))
	menus.waves_pressed.connect(_on_choose.bind(&"waves"))
	menus.lab_pressed.connect(_open_lab.bind(LAB_SCENE))
	menus.grab_lab_pressed.connect(_open_lab.bind(GRAB_LAB_SCENE))
	menus.quit_pressed.connect(_on_quit)
	menus.pause_requested.connect(pause)
	menus.resume_pressed.connect(resume)
	menus.restart_pressed.connect(restart)
	menus.menu_pressed.connect(back_to_menu)
	GameEvents.fighter_died.connect(_on_fighter_died_event)
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.wall_broken.connect(_on_wall_broken)
	GameEvents.wall_struck.connect(_on_wall_struck)
	GameEvents.prop_broken.connect(_on_prop_broken)
	GameEvents.limb_severed.connect(_on_limb_severed)
	GameEvents.furniture_broken.connect(_on_furniture_broken)
	GameEvents.structure_collapsed.connect(_on_structure_collapsed)
	GameEvents.floor_damaged.connect(_on_floor_damaged)
	DebrisManager.body_registered.connect(_on_debris_registered)
	if pending_mode != &"":
		var m := pending_mode
		pending_mode = &""
		start_round(m)
	elif show_title:
		_show_title()

## A reload (restart, main menu), a lab or a test freeing this node: never
## leave the Duel's max upgrades applied behind it.
func _exit_tree() -> void:
	GameMenus.restore_own_upgrades()

# --- Public API -------------------------------------------------------------------
## &"duel" (1v1 vs Duelist) or &"waves" (endless waves in The Yard).
## Idempotent: a running or finished round is torn down first (fighters,
## camera, HUD, timers, corpses, autoload state, and the arena unless it is
## the untouched title backdrop), then everything is built fresh.
func start_round(round_mode: StringName) -> void:
	_teardown_round(not _arena_used)
	mode = round_mode if round_mode in [&"duel", &"waves"] else &"duel"
	if mode == &"duel":
		GameMenus.apply_max_upgrades()  # Round 8: the Duel is fully upgraded (restored at the end)
	_ensure_arena()
	_arena_used = true
	fighters_root = Node3D.new()
	fighters_root.name = "Fighters"
	add_child(fighters_root)
	_snapshot_world()

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
	menus.can_restart = true
	_capture_mouse()

	if duel:
		wave_total = 1
		wave_index = 0
		AttackDirector.set_wave(0)  # 0 = Duel (no wave scaling)
		var e_xform: Transform3D = duel_spawns[1] if duel_spawns.size() > 1 else Transform3D(Basis(), p_xform.origin + Vector3(0, 0, -8))
		e_xform = _facing(e_xform, p_xform.origin)
		var duelist := _spawn_enemy(&"duelist", e_xform, PackedVector3Array())
		hud.set_opponent(duelist)
		hud.set_enemies_left(1)
		hud.show_banner("FIGHT", "Duel vs the Duelist", 1.6)
	else:
		wave_total = 0
		_begin_wave(0)
	GameEvents.round_started.emit(mode)

## Free everything a round built and clear all round state. Nodes leave the
## tree at once (remove_child) so groups such as "player" never see the old
## round; pending _after() callbacks are invalidated by bumping _gen.
func _teardown_round(keep_arena: bool) -> void:
	_gen += 1
	GameMenus.restore_own_upgrades()  # leaving a Duel: the player's own upgrades again
	get_tree().paused = false
	menus.hide_all()
	menus.can_pause = false
	menus.can_restart = false
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
	waves_cleared = 0
	kills = 0
	_won = false
	_round_time = -1.0
	_spawn_cd = 0.0
	_spawn_blocked = 0.0
	_spawn_cursor = 0
	_biggest_dmg = 0.0
	_biggest_move = &""
	_biggest_react = &""
	_walls_broken.clear()
	_limbs_taken = 0
	_spawned_ids.clear()
	_died_ids.clear()
	_fading_ids.clear()
	_hole_ids.clear()
	_prop_ids.clear()
	_collapses = 0
	_collapses_overhead = 0
	_collapses_by_fight = 0
	_floor_cells.clear()
	_thrown_props_broken = 0
	_loose_props.clear()
	_world_base.clear()
	_decal_high = 0
	_debris_registered = 0
	persistence_log.clear()
	reset_globals()

## Reset every autoload that holds round state.
func reset_globals() -> void:
	TimeDirector.reset()
	AttackDirector.reset()
	ImpactResolver.reset()
	DebrisManager.reset()
	WorldDamage.reset()  # also runs on round_started; here too for the title and labs
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
		menus.show_results(get_run_stats())
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

## Dead enemy bodies kept on the field (oldest first; the oldest fades past CORPSE_MAX).
func get_corpse_count() -> int:
	_prune_corpses()
	return _corpses.size()

## Results screen and GameEvents.run_ended payload.
func get_run_stats() -> Dictionary:
	return {
		"mode": mode,
		"won": _won,
		"waves_cleared": waves_cleared,
		"wave_reached": maxi(wave_index + 1, 1),
		"kills": kills,
		"time": _round_elapsed(),
		"biggest_hit": _biggest_dmg,
		"biggest_hit_move": _biggest_move,
		"biggest_hit_react": _biggest_react,
		"walls_broken": _walls_broken.size(),
		"limbs_taken": _limbs_taken,
		"objects_smashed": _prop_ids.size(),
		"structures_down": _collapses_by_fight,
	}

## Wave `index` (0-based): Tuning.WAVES as written, then the last of them plus
## one enemy per later wave from Tuning.WAVE_GROWTH_MIX (cycled). Special
## enemies come first so they make the breach entrance from wave 2.
static func wave_mix(index: int) -> Array[StringName]:
	var out: Array[StringName] = []
	var base := clampi(index, 0, Tuning.WAVES.size() - 1)
	var spec: Dictionary = Tuning.WAVES[base]
	for archetype: StringName in spec:
		for i in int(spec[archetype]):
			out.append(archetype)
	for k in maxi(index - base, 0):
		out.append(Tuning.WAVE_GROWTH_MIX[k % Tuning.WAVE_GROWTH_MIX.size()])
	var specials: Array[StringName] = []
	var grunts: Array[StringName] = []
	for a in out:
		if a == &"grunt":
			grunts.append(a)
		else:
			specials.append(a)
	specials.append_array(grunts)
	return specials

# --- Title -----------------------------------------------------------------------
func _show_title() -> void:
	phase = Phase.TITLE
	menus.can_pause = false
	menus.can_restart = false
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

func _open_lab(scene_path: String) -> void:
	if not ResourceLoader.exists(scene_path):
		return
	reset_globals()
	get_tree().paused = false
	get_tree().change_scene_to_file(scene_path)

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
	_spawned_ids[f.get_instance_id()] = true
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
	_wave_queue = wave_mix(index)
	_spawn_cd = 0.0
	phase = Phase.FIGHTING
	AttackDirector.set_wave(index + 1)  # 1-based: enemy startups shrink from Tuning.ENEMY_STARTUP_SHRINK_FROM
	var subtitle := _mix_text(_wave_queue)
	if index >= 1:
		_stage_breach()
	hud.set_wave(index, wave_total)
	hud.set_enemies_left(get_enemies_left())
	hud.show_banner("WAVE %d" % (index + 1), subtitle, 1.8)
	GameEvents.wave_started.emit(index, wave_total)

## "4 GRUNTS · 1 HEAVY": what is coming this wave.
static func _mix_text(queue: Array[StringName]) -> String:
	var counts := {}
	var order: Array[StringName] = []
	for a in queue:
		if not counts.has(a):
			counts[a] = 0
			order.append(a)
		counts[a] += 1
	order.sort_custom(func(a: StringName, b: StringName) -> bool: return a == &"grunt" and b != &"grunt")
	var parts := PackedStringArray()
	for a in order:
		var n: int = counts[a]
		parts.append("%d %s%s" % [n, String(a).to_upper(), "S" if n > 1 else ""])
	return "  ·  ".join(parts)

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
## heavy uses the garage roll door. Skipped if the arena has no such walls.
func _stage_breach() -> void:
	# Dynamic calls: breach() and friends are D's additions, not contract API.
	if _wave_queue.is_empty() or not arena.has_method(&"breach"):
		return
	var archetype: StringName = _wave_queue[0]
	var wall: Node3D = null
	if archetype in [&"heavy", &"brute"] and arena.has_method(&"get_roll_door"):
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

## The last enemy of a wave died: its close-up plays (E), then the wave ends.
func _wave_last_kill(last: Fighter) -> void:
	phase = Phase.CLEARING
	_play_last_kill(last)
	_after(_slow_time_length(&"last_kill"), _on_last_kill_played.bind(_gen, TimeDirector.now()))

## Hold the next wave until the close-up has played (at most LAST_KILL_HOLD_MAX).
func _on_last_kill_played(gen: int, started: float) -> void:
	if gen != _gen or phase != Phase.CLEARING:
		return
	if camera_rig != null and camera_rig.has_method(&"is_closeup_active") and camera_rig.call(&"is_closeup_active") \
			and TimeDirector.now() - started < LAST_KILL_HOLD_MAX:
		_after(0.1, _on_last_kill_played.bind(gen, started))
		return
	_wave_done()

func _wave_done() -> void:
	phase = Phase.BREATHER
	waves_cleared += 1
	_log_persistence()
	GameEvents.wave_cleared.emit(wave_index)
	var healed := 0.0
	if player and is_instance_valid(player) and not player.is_dead():
		var before := player.hp
		player.heal_fraction(Tuning.HEAL_BETWEEN_WAVES_HP / maxf(player.max_hp, 1.0))
		healed = player.hp - before
	hud.show_banner("WAVE %d CLEARED" % (wave_index + 1), "+%d HP" % roundi(healed) if healed >= 0.5 else "FULL HEALTH",
		minf(breather_time * 0.6, 2.4))
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
	_enforce_corpse_cap()
	_decal_high = maxi(_decal_high, BloodFX.decal_count())
	if mode == &"waves" and phase == Phase.FIGHTING:
		_spawn_tick(delta)
	if hud:
		hud.set_enemies_left(get_enemies_left())

func _unhandled_input(event: InputEvent) -> void:
	if phase in [Phase.FIGHTING, Phase.BREATHER, Phase.CLEARING, Phase.ENDING] and event is InputEventMouseButton \
			and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_capture_mouse()

# --- Deaths, bodies, round end --------------------------------------------------------
func _on_fighter_died_event(fighter: Node3D, _info: HitInfo) -> void:
	var f := fighter as Fighter
	if f == null:
		return
	if _spawned_ids.has(f.get_instance_id()):
		_died_ids[f.get_instance_id()] = true
	if f == player or _alive.has(f):
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
		_end_round(false)
		return
	_died_ids[id] = true
	_alive.erase(f)
	kills += 1
	AttackDirector.unregister_enemy(f)
	_corpses.append(f)
	_enforce_corpse_cap()
	_after_enemy_removed(f)

func _after_enemy_removed(last: Fighter) -> void:
	if phase != Phase.FIGHTING:
		return
	if not get_alive_enemies().is_empty() or not _wave_queue.is_empty():
		return
	if mode == &"duel":
		_play_last_kill(last)
		_end_round(true)
	else:
		_wave_last_kill(last)

## Bodies stay for the round (Feel Reference: Bodies stay): only past
## Tuning.CORPSE_MAX does the oldest fade out. No timed fade.
func _enforce_corpse_cap() -> void:
	_prune_corpses()
	while _corpses.size() > Tuning.CORPSE_MAX:
		var f = _corpses.pop_front()
		if is_instance_valid(f):
			_fading_ids[f.get_instance_id()] = true
			f.fade_out_and_free(CORPSE_FADE_TIME)

func _prune_corpses() -> void:
	for i in range(_corpses.size() - 1, -1, -1):
		if not is_instance_valid(_corpses[i]):
			_corpses.remove_at(i)

## GameEvents.last_kill for E (close-up camera, TimeDirector &"last_kill").
## Until E's modules listen to it, the old slow-motion and close-up APIs stand in.
func _play_last_kill(f: Fighter) -> void:
	if f == null or not is_instance_valid(f):
		return
	GameEvents.last_kill.emit(f)
	var slow: Dictionary = Tuning.SLOW_TIME[&"last_kill"]
	if not _has_listener(GameEvents.last_kill, TimeDirector) and TimeDirector.has_method(&"request_slowmo"):
		TimeDirector.call(&"request_slowmo", float(slow["scale"]), float(slow["time"]), FALLBACK_SLOWMO_PRIO)
	if camera_rig != null and not _has_listener(GameEvents.last_kill, camera_rig) \
			and camera_rig.has_method(&"start_closeup"):
		camera_rig.call(&"start_closeup", f, float(slow["time"]))

func _end_round(won: bool) -> void:
	if phase == Phase.ENDING or phase == Phase.OVER:
		return
	phase = Phase.ENDING
	_won = won
	_round_time = TimeDirector.now() - _round_started_at
	GameMenus.restore_own_upgrades()  # the Duel's max ends with the round
	if camera_rig:
		camera_rig.input_enabled = false  # no camera input once the round is decided
	_wave_queue.clear()
	GameEvents.round_over.emit(won)
	if not won:
		_play_player_death()
	if hud:
		hud.set_round_over()
	_after(_slow_time_length(&"last_kill" if won else &"player_death") + RESULTS_BEAT, _show_results.bind(_gen))

## Player death: E's TimeDirector requests &"player_death" (0.3x, 1 s) from
## fighter_died and the camera orbits the body. Fallbacks for both until E's
## modules do it themselves.
func _play_player_death() -> void:
	var slow: Dictionary = Tuning.SLOW_TIME[&"player_death"]
	if not _has_listener(GameEvents.fighter_died, TimeDirector) and TimeDirector.has_method(&"request_slowmo"):
		TimeDirector.call(&"request_slowmo", float(slow["scale"]), float(slow["time"]), FALLBACK_SLOWMO_PRIO)
	_start_death_camera.call_deferred(_gen)

## Deferred so a death camera E starts from fighter_died wins; otherwise orbit the body.
func _start_death_camera(gen: int) -> void:
	if gen != _gen or camera_rig == null or player == null or not is_instance_valid(player):
		return
	if camera_rig.has_method(&"get_mode_name") and String(camera_rig.call(&"get_mode_name")).to_lower() in ["ko", "death"]:
		return
	if camera_rig.has_method(&"start_orbit"):
		camera_rig.call(&"start_orbit", player)

func _show_results(gen: int) -> void:
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
	var stats := get_run_stats()
	if mode == &"waves" and not _won:
		GameEvents.run_ended.emit(stats)
	if not get_tree().paused:
		menus.show_results(stats)

func _round_elapsed() -> float:
	if _round_time >= 0.0:
		return _round_time
	return TimeDirector.now() - _round_started_at if phase != Phase.TITLE else 0.0

## Real seconds a Tuning.SLOW_TIME entry lasts, ease-out included.
static func _slow_time_length(id: StringName) -> float:
	var e: Dictionary = Tuning.SLOW_TIME.get(id, {})
	return float(e.get("time", 1.0)) + float(e.get("ease", Tuning.SLOWMO_EASE))

## True when `obj` has a handler connected to `sig`.
static func _has_listener(sig: Signal, obj: Object) -> bool:
	if obj == null:
		return false
	for c: Dictionary in sig.get_connections():
		var cb: Callable = c["callable"]
		if cb.get_object() == obj:
			return true
	return false

# --- Run stats --------------------------------------------------------------------------
## The biggest hit is the most damage one player hit did (strikes, counters,
## drive slams, throws): Round 7 resolves hits per move, not by power score.
func _on_hit_landed(info: HitInfo) -> void:
	if info == null or player == null or info.attacker != player:
		return
	if info.damage > _biggest_dmg:
		_biggest_dmg = info.damage
		_biggest_move = info.move_id
		_biggest_react = info.react if info.react != &"" else HitInfo.tier_name(info.tier)

func _on_limb_severed(fighter: Node3D, _cut: StringName, _piece: Node3D) -> void:
	if fighter != null and _spawned_ids.has(fighter.get_instance_id()):
		_limbs_taken += 1

func _on_wall_broken(wall: Node3D, _position: Vector3, _energy: float, _velocity: Vector3) -> void:
	if wall == null or phase == Phase.TITLE:
		return
	var id := wall.get_instance_id()
	var d := wall as Destructible
	if d != null and d.kind != &"panel":
		_prop_ids[id] = true
		return
	_hole_ids[id] = true
	if not wall.has_meta(&"staged_breach"):
		_walls_broken[id] = true

func _on_wall_struck(_attacker: Node3D, wall: Node3D, _position: Vector3, _normal: Vector3, _power: float,
		result: StringName, _surface: StringName) -> void:
	# Loose props (chairs, cabinets, drums) break whole under strikes and leave no wall_broken.
	if result == &"break" and wall != null and wall.is_in_group(&"props") and not (wall is Destructible):
		_prop_ids[wall.get_instance_id()] = true

## Round 6 clutter (K): every broken object once, whatever broke it.
func _on_furniture_broken(node: Node3D, _position: Vector3, _kind: StringName, _energy: float, _by: Node3D) -> void:
	if node != null and phase != Phase.TITLE:
		_prop_ids[node.get_instance_id()] = true

func _on_structure_collapsed(node: Node3D, _position: Vector3, kind: StringName) -> void:
	if phase == Phase.TITLE:
		return
	_collapses += 1
	if kind == &"overhead":
		_collapses_overhead += 1
	var staged := node != null and is_instance_valid(node) and (node.has_meta(&"staged_breach")
		or (node.get_parent() != null and node.get_parent().has_meta(&"staged_breach")))
	if not staged:
		_collapses_by_fight += 1

## WorldDamage emits each new level a floor cell reaches, at the cell's centre.
func _on_floor_damaged(position: Vector3, _radius: float, level: int, _surface: StringName) -> void:
	if phase == Phase.TITLE:
		return
	var key := Vector3i((position * 100.0).round())
	_floor_cells[key] = maxi(int(_floor_cells.get(key, 0)), level)

func _on_prop_broken(_prop: Node3D, _position: Vector3, _kind: StringName) -> void:
	if phase != Phase.TITLE:
		_thrown_props_broken += 1

func _on_debris_registered(_body: RigidBody3D) -> void:
	if phase != Phase.TITLE:
		_debris_registered += 1

# --- F11 persistence check ---------------------------------------------------------------
## World counts before any fighting: scenery that starts broken is not "created".
func _snapshot_world() -> void:
	_loose_props.clear()
	for n in get_tree().get_nodes_in_group(&"props"):
		if not (n is Destructible) and not (n is ThrowableProp):
			_loose_props.append(n)
	_world_base = _world_counts()

## What the world holds now. D's counters when it has them
## (DebrisManager.furniture_broken_count / wall_holes_count / props_broken_total,
## WorldDamage.get_floor_counts / get_collapse_count), else counted here from
## the breakables themselves.
func _world_counts() -> Dictionary:
	var holes := 0
	var props := 0
	for n in get_tree().get_nodes_in_group(&"destructibles"):
		var d := n as Destructible
		if d == null or d.is_queued_for_deletion():
			continue
		if d.kind == &"panel":
			if d.get_cell_count() > 0 and d.get_alive_count() < d.get_cell_count():
				holes += 1
		elif d.is_broken:
			props += 1
	for n in get_tree().get_nodes_in_group(&"pillars"):
		if not (n is Destructible) and n.get(&"is_broken") == true:
			holes += 1  # a broken pillar reports wall_broken like a panel
	for n in get_tree().get_nodes_in_group(&"clutter"):
		if not n.is_queued_for_deletion() and n.get(&"is_broken") == true:
			props += 1
	for p in _loose_props:
		if not is_instance_valid(p) or p.is_queued_for_deletion():
			props += 1
	if DebrisManager.has_method(&"furniture_broken_count"):
		props = int(DebrisManager.call(&"furniture_broken_count"))
	if DebrisManager.has_method(&"wall_holes_count"):
		holes = int(DebrisManager.call(&"wall_holes_count"))
	var thrown := -1
	if DebrisManager.has_method(&"props_broken_total"):
		thrown = int(DebrisManager.call(&"props_broken_total"))
	var floor_counts := {}
	if WorldDamage.has_method(&"get_floor_counts"):
		floor_counts = WorldDamage.call(&"get_floor_counts")
	var collapses := -1
	if WorldDamage.has_method(&"get_collapse_count"):
		collapses = int(WorldDamage.call(&"get_collapse_count"))
	return {"holes": holes, "props": props, "thrown": thrown, "floor": floor_counts, "collapses": collapses,
		"falling_pieces": get_tree().get_nodes_in_group(&"falling_pieces").filter(
			func(n: Node) -> bool: return not n.is_queued_for_deletion()).size()}

## F11: what this round created (counted from events) against what the world
## still holds. ok is true when every pair matches.
## - bodies: enemy deaths (fighter_died) vs dead enemy bodies still in the
##   scene; past Tuning.CORPSE_MAX the oldest have faded, so kept = min(created, cap).
## - props: breakable / loose / thrown props broken (wall_broken on a prop,
##   wall_struck "break" on a loose prop, prop_broken) vs broken props in the world.
## - wall holes: panels that reported wall_broken vs panels with cells missing.
## - collapses (Round 6): structure_collapsed events vs WorldDamage's count;
##   each overhead collapse leaves a FallingPiece that is still in the scene.
## - floor (Round 6): floor_damaged cells by their highest level vs
##   WorldDamage.get_floor_counts() (cracks, craters, rubble); floor-mark decals
##   never pass Tuning.FLOOR_DECAL_MAX.
## - decals: BloodFX.get_decal_counts(): every decal created is still live,
##   fading, evicted by the caps or released with a broken wall; blood decals
##   never pass Tuning.BLOOD_DECAL_MAX, and the cap evicts only once more than it
##   were made. (Without that API: the most seen at once vs BloodFX.decal_count().)
## - debris: DebrisManager registrations vs live chunks (logged, not judged).
func get_persistence_report() -> Dictionary:
	var present := 0
	for n in get_tree().get_nodes_in_group(&"fighters"):
		var f := n as Fighter
		if f == null or f == player or not f.is_dead() or f.is_queued_for_deletion():
			continue
		var id := f.get_instance_id()
		if _spawned_ids.has(id) and not _fading_ids.has(id):
			present += 1
	var created_bodies := _died_ids.size()
	var world := _world_counts()
	var props_world := int(world["props"]) - int(_world_base.get("props", 0))
	var thrown_world := int(world["thrown"])
	props_world += thrown_world - maxi(int(_world_base.get("thrown", 0)), 0) if thrown_world >= 0 else _thrown_props_broken
	var holes_world := int(world["holes"]) - int(_world_base.get("holes", 0))
	var fl: Dictionary = world["floor"]
	var fl0: Dictionary = _world_base.get("floor", {})
	var floor_events := [0, 0, 0]
	for k in _floor_cells:
		floor_events[clampi(int(_floor_cells[k]), 1, 3) - 1] += 1
	var floor_world := [int(fl.get("cracks", 0)) - int(fl0.get("cracks", 0)),
		int(fl.get("craters", 0)) - int(fl0.get("craters", 0)), int(fl.get("rubble", 0)) - int(fl0.get("rubble", 0))]
	var collapses_world := int(world["collapses"])
	var pieces := int(world["falling_pieces"]) - int(_world_base.get("falling_pieces", 0))
	_decal_high = maxi(_decal_high, BloodFX.decal_count())
	var dc := {"created": _decal_high, "live": BloodFX.decal_count(), "fading": 0, "evicted": 0, "released": 0,
		"blood": BloodFX.decal_count()}
	var decal_source := "high-water"
	if BloodFX.has_method(&"get_decal_counts"):
		dc = BloodFX.call(&"get_decal_counts")
		decal_source = "BloodFX.get_decal_counts"
	var decals_created := int(dc.get("created", 0))
	var accounted := int(dc.get("live", 0)) + int(dc.get("fading", 0)) + int(dc.get("evicted", 0)) + int(dc.get("released", 0))
	var r := {
		"wave": wave_index + 1,
		"bodies_created": created_bodies,
		"bodies_expected": mini(created_bodies, Tuning.CORPSE_MAX),
		"bodies_present": present,
		"props_events": _prop_ids.size() + _thrown_props_broken,
		"props_world": props_world,
		"thrown_props_counter": thrown_world >= 0,
		"holes_events": _hole_ids.size(),
		"holes_world": holes_world,
		"collapses_events": _collapses,
		"collapses_world": collapses_world,
		"overhead_events": _collapses_overhead,
		"falling_pieces": pieces,
		"floor_events": floor_events,
		"floor_world": floor_world,
		"floor_tiles": int(fl.get("tiles", 0)) - int(fl0.get("tiles", 0)),
		"floor_counter": not fl.is_empty(),
		"marks_live": int(dc.get("marks", 0)),
		"marks_created": int(dc.get("marks_created", 0)),
		"decals_created": decals_created,
		"decals_accounted": accounted,
		"decals_live": int(dc.get("live", 0)),
		"decals_fading": int(dc.get("fading", 0)),
		"decals_evicted": int(dc.get("evicted", 0)),
		"decals_released": int(dc.get("released", 0)),
		"blood_decals": int(dc.get("blood", 0)),
		"decal_source": decal_source,
		"debris_registered": _debris_registered,
		"debris_live": DebrisManager.count(),
		"objects_smashed": _prop_ids.size(),
	}
	r["bodies_ok"] = r["bodies_present"] == r["bodies_expected"]
	r["props_ok"] = r["props_events"] == r["props_world"]
	r["holes_ok"] = r["holes_events"] == r["holes_world"]
	r["collapses_ok"] = (collapses_world < 0 or _collapses == collapses_world) and pieces >= _collapses_overhead
	r["floor_ok"] = (fl.is_empty() or floor_events == floor_world) and r["marks_live"] <= Tuning.FLOOR_DECAL_MAX
	var blood_made := int(dc.get("blood_created", decals_created))
	r["decals_ok"] = decals_created == accounted and r["blood_decals"] <= Tuning.BLOOD_DECAL_MAX \
		and (r["decals_evicted"] == 0 or blood_made - r["decals_released"] > Tuning.BLOOD_DECAL_MAX
			or r["marks_created"] > Tuning.FLOOR_DECAL_MAX)
	r["ok"] = r["bodies_ok"] and r["props_ok"] and r["holes_ok"] and r["collapses_ok"] and r["floor_ok"] and r["decals_ok"]
	return r

static func persistence_line(r: Dictionary) -> String:
	var fe: Array = r["floor_events"]
	var fw: Array = r["floor_world"]
	return ("F11 persistence wave %d: bodies %d created / %d kept (expect %d, cap %d) | props+clutter broken %d events / %d world%s" \
		+ " | wall holes %d events / %d world | collapses %d events / %d world, %d overhead / %d fallen pieces" \
		+ " | floor crack/crater/rubble %d/%d/%d events / %d/%d/%d world, %d tiles, %d marks (cap %d)" \
		+ " | decals %d created = %d live + %d fading + %d evicted + %d released" \
		+ " (%d accounted; blood %d, cap %d; %s) | debris %d registered / %d live (cap %d) -> %s") % [
		r["wave"], r["bodies_created"], r["bodies_present"], r["bodies_expected"], Tuning.CORPSE_MAX,
		r["props_events"], r["props_world"], "" if r["thrown_props_counter"] else " (thrown props: events only)",
		r["holes_events"], r["holes_world"], r["collapses_events"], r["collapses_world"], r["overhead_events"],
		r["falling_pieces"], fe[0], fe[1], fe[2], fw[0], fw[1], fw[2], r["floor_tiles"], r["marks_live"],
		Tuning.FLOOR_DECAL_MAX, r["decals_created"], r["decals_live"], r["decals_fading"],
		r["decals_evicted"], r["decals_released"], r["decals_accounted"], r["blood_decals"], Tuning.BLOOD_DECAL_MAX,
		r["decal_source"], r["debris_registered"], r["debris_live"], Tuning.DEBRIS_MAX, "MATCH" if r["ok"] else "MISMATCH"]

func _log_persistence() -> void:
	var r := get_persistence_report()
	persistence_log.append(r)
	print(persistence_line(r))

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
