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

func _capture_events() -> void:
	for sig: StringName in [&"hit_landed", &"hit_blocked", &"perfect_dodge", &"teleport_counter",
			&"grab_started", &"grab_broken", &"fighter_died", &"limb_severed",
			&"attack_whiff", &"attack_active", &"fighter_launched", &"focus_changed", &"pursuit", &"air_recovery", &"armor_absorbed", &"dodge_feedback",
			&"attack_tell", &"thrown", &"charge_started", &"charge_level_changed", &"charge_released",
			&"combo_progress", &"combo_ended", &"stumbled", &"tripped", &"dazed", &"limb_damaged",
			&"arm_broken", &"wall_slam"]:
		var s := sig
		GameEvents.connect(s, func(a = null, b = null, c = null, d = null) -> void:
			events.append([s, a, b, c, d]))

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

## A fighter whose crouch / jump / stick intent the test sets (fake_crouch,
## fake_air, fake_intent). hold: read press/release as tap vs hold.
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
