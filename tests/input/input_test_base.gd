extends Node3D
## Shared helpers for tests/input/* and tests/defence/*. Each test extends
## this, overrides run(), and calls done(). Prints "PASS ..."/"FAIL ..." per
## check and quits 0/1.
## OWNER: agent H (fighter, player & defence).

var failures: Array[String] = []
var events: Array = []  ## [name, a, b, c, real time] captured from GameEvents
var _timeout := 40.0
var _checks := 0
var _completed := false

func _ready() -> void:
	_make_floor()
	_capture_events()
	get_tree().create_timer(_timeout, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout after %.0f s" % _timeout)
		Engine.time_scale = 1.0
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
	for sig: StringName in [&"react_started", &"countered", &"counter_whiffed", &"fighter_died"]:
		var s := sig
		GameEvents.connect(s, func(a = null, b = null, c = null) -> void:
			events.append([s, a, b, c, TimeDirector.now()]))

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

## The player (with PlayerController) at `pos`, facing -Z.
func spawn_player(pos := Vector3.ZERO) -> Fighter:
	return FighterFactory.spawn_player(self, Transform3D(Basis(), pos))

## A controller-less fighter at `pos` facing `facing`.
func spawn_dummy(archetype: StringName, pos: Vector3, facing: Vector3, team := Fighter.TEAM_ENEMY) -> Fighter:
	var xf := Transform3D(Basis.looking_at(facing.normalized(), Vector3.UP), pos)
	return FighterFactory.spawn_dummy(self, archetype, xf, team)

func ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

## Step until `cond` is true or `max_ticks` pass. Returns cond().
func wait_until(cond: Callable, max_ticks := 360) -> bool:
	for i in max_ticks:
		if cond.call():
			return true
		await get_tree().physics_frame
	return cond.call()

func press(action: StringName) -> void:
	Input.action_press(action)

func release(action: StringName) -> void:
	Input.action_release(action)

## A real press-and-release input event for `action` (reaches _input /
## _unhandled_input handlers), one tick apart.
func tap_action(action: StringName) -> void:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	Input.parse_input_event(e)
	await ticks(1)
	var r := InputEventAction.new()
	r.action = action
	r.pressed = false
	Input.parse_input_event(r)
	await ticks(1)

func release_all_input() -> void:
	for a: StringName in Controls.ACTIONS:
		if InputMap.has_action(a):
			Input.action_release(a)

func check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS ", msg)
	else:
		print("  FAIL ", msg)
		failures.append(msg)

func near(a: float, b: float, rel: float) -> bool:
	return absf(a - b) <= absf(b) * rel

func finish() -> void:
	release_all_input()
	if TimeDirector.has_method(&"reset"):
		TimeDirector.reset()
	Engine.time_scale = 1.0
	if failures.is_empty() and _checks == 0:
		failures.append("no checks ran")
	if failures.is_empty():
		print("RESULT PASS ", name)
		get_tree().quit(0)
	else:
		print("RESULT FAIL ", name, " ", failures)
		get_tree().quit(1)
