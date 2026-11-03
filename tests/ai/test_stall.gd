extends Node
## Round 7 stalled approach (AIBrain.STALL_*): a token holder blocked short of
## its move's range swings anyway, with its normal tell; a normal close-in
## never does.
## A. The duel case made deterministic: the player dummy stands on a 0.4 m
##    block (the clutter a launch put it on), the Duelist can get no closer
##    than about 2.2 m (beyond every move's range, too close to vanish-step).
##    Three times over, he starts an attack within LIMIT s of the tokens
##    opening, from where he is blocked, with a tell of at least R7_COUNTER_WINDOW +
##    R7_TELL_MARGIN (B's counter window is logged).
## B. Narrow: a Duelist and a grunt closing in on a player on open floor from
##    5 m start every attack within their move's range (+ RANGE_SLACK), never
##    a stall swing.
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const LIMIT := 3.0               ## s from the tokens opening to his attack
const BLOCK := Vector3(3.0, 0.4, 3.0)  ## m: the block the dummy stands on (centred at the origin)
const PLAYER_ON := Vector3(0.0, 0.45, 0.25)
const DUELIST_AT := Vector3(0.0, 0.05, -2.6)

var failures := 0
var player: Fighter
var launches: Array = []    ## [time, enemy, move, start distance]
var tells := {}             ## enemy -> [world time of the tell, duration]
var leads: Array[float] = []
var windows := 0

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	Tuning.difficulty = Tuning.Difficulty.NORMAL
	AIBrain.test_seed = 77
	Util.build_floor(self)
	GameEvents.attack_tell.connect(func(a: Node3D, _k: StringName, d: float) -> void:
		tells[a] = [AttackDirector.world_now(), d])
	GameEvents.attack_active.connect(func(a: Node3D, _m: StringName) -> void:
		if tells.has(a):
			leads.append(AttackDirector.world_now() - float(tells[a][0]))
			tells.erase(a))
	GameEvents.counter_window.connect(func(_a: Node3D, _t: Node3D, open: bool, _c: bool) -> void:
		if open: windows += 1)
	await _part_block()
	await _part_open_floor()
	AIBrain.test_seed = -1
	_finish()

# --- A. The player on a block ----------------------------------------------------

func _part_block() -> void:
	AttackDirector.camera_busy = true
	var block := StaticBody3D.new()
	block.name = "Block"
	block.collision_layer = Layers.WORLD
	block.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = BLOCK
	cs.shape = box
	block.add_child(cs)
	block.position = Vector3(0.0, BLOCK.y * 0.5, 0.0)
	add_child(block)
	if AttackDirector.nav_ready():
		AttackDirector.nav.refresh(Vector3.ZERO, 3.0)
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), PLAYER_ON), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	var d := FighterFactory.spawn_enemy(self, &"duelist", Transform3D(Basis.looking_at(Vector3.BACK, Vector3.UP), DUELIST_AT))
	var b := d.brain as AIBrain
	b.attack_launched.connect(func(m: StringName) -> void:
		launches.append([Util.game_now(), d, m, b.last_start_dist]))
	await _wait(0.5)
	var rows: Array[String] = []
	var ok := 0
	for attempt in 3:
		AttackDirector.camera_busy = true
		await _settle(d)
		_place_player()
		d.global_position = DUELIST_AT
		d.snap_facing(Vector3.BACK)
		d.reset_physics_interpolation()
		await _wait(0.4)
		var l0 := launches.size()
		var s0 := b.stall_swings
		var closest := INF
		var t0 := Util.game_now()
		AttackDirector.camera_busy = false
		while Util.game_now() - t0 < LIMIT + 2.0 and launches.size() == l0:
			closest = minf(closest, Util.flat_dist(d.get_ground_position(), player.get_ground_position()))
			_keep_player()
			await get_tree().physics_frame
		AttackDirector.camera_busy = true
		if launches.size() == l0:
			rows.append("no attack in %.0f s (closest %.2f m: %s)" % [LIMIT + 2.0, closest, b.get_debug_text().substr(0, 120)])
			continue
		var l: Array = launches[l0]
		var dt: float = l[0] - t0
		rows.append("%s after %.2f s from %.2f m (closest %.2f m, player y %.2f, stall swing %s)" % [l[2], dt, l[3], closest,
			player.global_position.y, b.stall_swings > s0])
		if dt <= LIMIT and b.stall_swings > s0:
			ok += 1
		await _wait(1.2)
	print("[ai] info: the Duelist against a player on a %.1f m block: %s" % [BLOCK.y, "; ".join(rows)])
	check(ok == 3, "blocked beyond his range, he attacks within %.0f s every time (%d / 3)" % [LIMIT, ok])
	var need := Tuning.R7_COUNTER_WINDOW + Tuning.R7_TELL_MARGIN
	var shortest: float = leads.min() if not leads.is_empty() else -1.0
	check(not leads.is_empty() and shortest >= need - 1e-4,
		"the stall swing keeps its normal tell (shortest %.3f s >= %.2f; B's counter window opened %d times)" % [shortest, need, windows])
	AttackDirector.unregister_enemy(d)
	d.queue_free()
	player.queue_free()
	block.queue_free()
	await _wait(0.3)

func _place_player() -> void:
	player.global_position = PLAYER_ON
	player.reset_physics_interpolation()
	player.snap_facing(Vector3.FORWARD)

# --- B. Open floor: no stall swings --------------------------------------------------

func _part_open_floor() -> void:
	AttackDirector.camera_busy = true
	var home := Vector3(20.0, 0.05, 0.0)
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), home), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	var rows: Array[String] = []
	var bad := 0
	var total := 0
	var stalls := 0
	for arch: StringName in [&"duelist", &"grunt"]:
		var e := FighterFactory.spawn_enemy(self, arch, Transform3D(Basis.looking_at(Vector3.BACK, Vector3.UP), home + Vector3(0, 0, -5.0)))
		var b := e.brain as AIBrain
		var mine: Array = []
		b.attack_launched.connect(func(m: StringName) -> void: mine.append([m, b.last_start_dist]))
		await _wait(0.5)
		AttackDirector.camera_busy = false
		var t0 := Util.game_now()
		while Util.game_now() - t0 < 20.0 and mine.size() < 6:
			if Util.flat_dist(player.get_ground_position(), home) > 0.3 and not player.is_down():
				player.global_position = home
				player.reset_physics_interpolation()
			_keep_player()
			await get_tree().physics_frame
		AttackDirector.camera_busy = true
		var dists: Array[String] = []
		for m: Array in mine:
			total += 1
			var allow: float = float(AIBrain.MOVE_RANGE.get(m[0], 1.5)) + AIBrain.RANGE_SLACK + 0.05
			if float(m[1]) > allow:
				bad += 1
			dists.append("%s %.2f" % [m[0], m[1]])
		stalls += b.stall_swings
		rows.append("%s: %s" % [arch, ", ".join(dists)])
		AttackDirector.unregister_enemy(e)
		e.queue_free()
		await _wait(0.3)
	print("[ai] info: open floor attack start distances (m): %s" % "; ".join(rows))
	check(total >= 8 and bad == 0 and stalls == 0,
		"on open floor every attack starts within its move's range + slack (%d attacks, %d beyond, %d stall swings)" % [total, bad, stalls])

# --- Helpers -----------------------------------------------------------------------

func _settle(f: Fighter) -> void:
	var t0 := Util.game_now()
	while (f.combat.is_attacking() or not f.can_act() or f.is_down() or player.is_down()) and Util.game_now() - t0 < 6.0:
		_keep_player()
		await get_tree().physics_frame

func _keep_player() -> void:
	if player == null or not is_instance_valid(player) or player.is_queued_for_deletion():
		return
	if "invuln_until" in player:
		player.set(&"invuln_until", TimeDirector.now() + 5.0)
	if player.hp < player.max_hp * 0.5:
		player.heal_fraction(1.0)

func _wait(s: float) -> void:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < s:
		_keep_player()
		await get_tree().physics_frame

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_stall: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
