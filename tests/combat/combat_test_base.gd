extends Node3D
## Shared helpers for tests/combat/*. Each test extends this, overrides run(),
## and calls finish(). Prints "PASS ..."/"FAIL ..." per check and quits 0/1.
## OWNER: agent B (fighter & combat).

var failures: Array[String] = []
var events: Array = []  ## [name, args...] captured from GameEvents
var _timeout := 30.0

func _ready() -> void:
	_make_floor()
	_capture_events()
	get_tree().create_timer(_timeout, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout after %.0f s" % _timeout)
		get_tree().quit(1))
	@warning_ignore("redundant_await")
	await run()
	if not _completed:
		failures.append("run() did not complete (script error or early abort)")
		print("  FAIL run() did not complete")
	finish()

## Override; end with done().
func run() -> void:
	done()

var _completed := false

## Call at the end of run() (and before any early return).
func done() -> void:
	_completed = true

func _make_floor() -> void:
	var body := StaticBody3D.new()
	body.name = "Floor"
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(500.0, 1.0, 500.0)
	cs.shape = box
	cs.position = Vector3(0.0, -0.5, 0.0)
	body.add_child(cs)
	add_child(body)

## Every GameEvents signal a combat test reads (skipped if the lead removed it).
func _capture_events() -> void:
	for sig: StringName in [&"hit_landed", &"hit_blocked", &"grab_started", &"grab_broken",
			&"fighter_died", &"limb_severed", &"attack_whiff", &"attack_active", &"fighter_launched",
			&"armor_absorbed", &"attack_tell", &"thrown", &"combo_progress", &"combo_ended",
			&"combo_escaped", &"stumbled", &"dazed", &"strike_started", &"screen_shake",
			&"chain_hit", &"chain_ended", &"glide_started", &"counter_window", &"countered",
			&"react_started", &"dodged"]:
		if not GameEvents.has_signal(sig):
			continue
		var s := sig
		GameEvents.connect(s, func(a = null, b = null, c = null, d = null, e = null) -> void:
			events.append([s, a, b, c, d, e]))

func count_events(what: StringName) -> int:
	var n := 0
	for e in events:
		if e[0] == what:
			n += 1
	return n

func last_event(what: StringName) -> Array:
	for i in range(events.size() - 1, -1, -1):
		if events[i][0] == what:
			return events[i]
	return []

func clear_events() -> void:
	events.clear()

## Spawn a dummy fighter standing at `pos` facing `facing` (world XZ).
func spawn(archetype: StringName, pos: Vector3, facing: Vector3, team := Fighter.TEAM_ENEMY) -> Fighter:
	var xf := Transform3D(Basis.looking_at(facing.normalized(), Vector3.UP), pos)
	return FighterFactory.spawn_dummy(self, archetype, xf, team)

const FakeFighter := preload("res://tests/combat/fake_fighter.gd")

## A fighter whose Round 7 react state the test sets (fake_react) and that
## records its reactions (reacts). hold: read press/release as tap vs hold.
func spawn_fake(archetype: StringName, pos: Vector3, facing: Vector3, team := Fighter.TEAM_ENEMY,
		hold := false) -> Fighter:
	var f: Fighter = FakeFighter.new()
	f.name = String(archetype).capitalize() + "Fake"
	f.setup(archetype, team)
	f.transform = Transform3D(Basis.looking_at(facing.normalized(), Vector3.UP), pos)
	add_child(f)
	f.combat.force_hold_charge = hold
	return f

## Press and hold `action` for `seconds` of real time, then release.
func hold_press(f: Fighter, action: int, seconds: float) -> void:
	f.combat.press(action)
	await wait_real(seconds)
	f.combat.release(action)

func tap(f: Fighter, action: int) -> void:
	f.combat.press(action)
	f.combat.release(action)

func ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func wait_real(seconds: float) -> void:
	var t0 := TimeDirector.now()
	while TimeDirector.now() - t0 < seconds:
		await get_tree().physics_frame

## Step physics for `seconds` of game time (slows down with Engine.time_scale).
func wait_game(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		await get_tree().physics_frame
		t += Engine.time_scale / float(Engine.physics_ticks_per_second)

## Step physics until `cond` is true or `max_real` seconds pass. Returns cond().
func wait_until(cond: Callable, max_real := 3.0) -> bool:
	var t0 := TimeDirector.now()
	while not cond.call():
		if TimeDirector.now() - t0 > max_real:
			return false
		await get_tree().physics_frame
	return true

var _checks := 0

func check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS ", msg)
	else:
		print("  FAIL ", msg)
		failures.append(msg)

## True when agent A's real rig AND ragdoll are in (not the contract stubs), so
## ragdoll state checks (LAUNCHED, DEAD) are meaningful.
func rig_is_real(f: Fighter) -> bool:
	if f.rig == null or f.rig.skeleton == null or f.rig.get_physical_bones().is_empty():
		return false
	var src := FileAccess.get_file_as_string("res://scripts/fighter/ragdoll_controller.gd")
	return src.length() > 8000

func finish() -> void:
	TimeDirector.reset()
	if failures.is_empty() and _checks == 0:
		failures.append("no checks ran")
	if failures.is_empty():
		print("RESULT PASS ", name)
		get_tree().quit(0)
	else:
		print("RESULT FAIL ", name, " ", failures)
		get_tree().quit(1)

# --- Round 7 helpers -------------------------------------------------------------
const A := CombatController.Action

## hit_landed infos on `victim` (all of them, in order).
func hits_on(victim: Fighter) -> Array[HitInfo]:
	var out: Array[HitInfo] = []
	for e: Array in events:
		if e[0] == &"hit_landed" and (e[1] as HitInfo).victim == victim:
			out.append(e[1])
	return out

## The last hit_landed of `move_id` (null when none).
func last_hit(move_id: StringName) -> HitInfo:
	for i in range(events.size() - 1, -1, -1):
		var e: Array = events[i]
		if e[0] == &"hit_landed" and (e[1] as HitInfo).move_id == move_id:
			return e[1]
	return null

## Moves started by `f` from now on (attack_started), in order.
func record_moves(f: Fighter) -> Array[StringName]:
	var out: Array[StringName] = []
	f.combat.attack_started.connect(func(id: StringName) -> void: out.append(id))
	return out

## The real player (PlayerController + InputInterpreter, M's Traversal, H's Defence).
func spawn_player(pos: Vector3, facing := Vector3.FORWARD) -> Fighter:
	var p := FighterFactory.spawn_player(self, Transform3D(Basis.looking_at(facing.normalized(), Vector3.UP), pos))
	AttackDirector.set_player(p)
	return p

## Release every input action (between real-input sections).
func release_inputs() -> void:
	for a in InputMap.get_actions():
		if not String(a).begins_with("ui_"):
			Input.action_release(a)

## Press input `action` for `secs` of real time, then release.
func tap_input(action: StringName, secs := 0.05) -> void:
	Input.action_press(action)
	await wait_real(secs)
	Input.action_release(action)

## Put `victim` back on its feet `dist` m in front of `p`, facing it.
func place_in_front(p: Fighter, victim: Fighter, dist: float) -> void:
	victim.global_position = p.global_position + p.get_forward() * dist
	victim.snap_facing(-p.get_forward())
	victim.reset_physics_interpolation()
