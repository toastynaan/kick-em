extends Node3D
## The Grab Lab (scenes/grab_lab.tscn) keeps working: it loads with the real
## player, camera rig, dummies, the drive lane and props; its scripted demo
## grabs the dummy in front, drives it, and throws it with a full wind-up
## (R7_THROW_SPEED_MAX). Key 8 puts a grunt in the player's hands at the drive
## lane, and a drive from there breaks the drywall panel. Then the other lab
## keys (enemy grabs, knockdowns, kills, bowling line, props, reset) run.
## OWNER: agent G.

var _fail: Array[String] = []
var _thrown := 0
var _grabs := 0
var _drives := 0
var _impacts: Array[StringName] = []

func _ready() -> void:
	get_tree().create_timer(90.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	GameEvents.thrown.connect(func(_g: Node3D, _v: Node3D, _vel: Vector3) -> void: _thrown += 1)
	GameEvents.grab_started.connect(func(_g: Node3D, _v: Node3D) -> void: _grabs += 1)
	GameEvents.drive_started.connect(func(_h: Node3D, _v: Node3D) -> void: _drives += 1)
	GameEvents.drive_impact.connect(func(_h: Node3D, _v: Node3D, _t: Node3D, _p: Vector3, _s: float, r: StringName) -> void:
		_impacts.append(r))
	var lab: Node3D = load("res://scenes/grab_lab.tscn").instantiate()
	lab.set(&"_demo", true)
	add_child(lab)
	var player: Fighter = lab.get(&"player")
	for i in 45:
		await GrabTestUtil.wait(self, 0.1)
		if i % 6 == 0:
			print("  t=%.1f %s result=%s drop=%s" % [i * 0.1, player.carry.get_debug_text(), player.carry.last_grab_result, player.carry.last_drop_reason])
	print("[lab] demo: grabs %d, drives %d, throws %d, last throw %.1f m/s (wind-up %.2f), props %d, walls %d" % [_grabs, _drives,
		_thrown, player.carry.last_throw_velocity.length(), player.carry.last_throw_windup, (lab.get(&"props") as Array).size(),
		(lab.get(&"walls") as Array).size()])
	_check(_grabs >= 1 and _drives >= 1 and _thrown >= 1, "the demo grabs, drives and throws")
	_check(absf(player.carry.last_throw_velocity.length() - Tuning.R7_THROW_SPEED_MAX) < 0.5, "with a full wind-up")
	lab.set(&"_demo", false)
	await GrabTestUtil.wait(self, 4.0)
	_key(lab, KEY_8)
	await GrabTestUtil.wait(self, 0.5)
	var holding := player.carry.is_holding_body()
	_impacts.clear()
	player.combat.press(CombatController.Action.DASH)
	await GrabTestUtil.wait_until(self, func() -> bool: return _impacts.has(&"break") or not player.carry.is_holding(), 2.0)
	player.combat.release(CombatController.Action.DASH)
	print("[lab] key 8: holding=%s, drive contacts %s, %s" % [holding, _impacts, player.carry.get_debug_text()])
	_check(holding and _impacts.has(&"break"), "key 8: the drive lane's drywall breaks")
	await GrabTestUtil.wait(self, 1.5)
	for key in [KEY_R, KEY_1, KEY_2, KEY_3, KEY_1, KEY_4, KEY_5, KEY_6, KEY_7, KEY_R]:
		_key(lab, key)
		await GrabTestUtil.wait(self, 0.9)
	print("[lab] lab keys ran: grabs %d, player %s, carry %s" % [_grabs, GrabTestUtil.state_name(player), player.carry.get_debug_text()])
	_check(_grabs >= 3, "the lab's scripted enemy grab connects")
	lab.queue_free()
	await GrabTestUtil.frames(self, 3)
	_finish()

func _key(lab: Node, key: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = key
	ev.pressed = true
	lab.call(&"_unhandled_input", ev)

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	if _fail.is_empty():
		print("PASS test_grab_lab")
		get_tree().quit(0)
	else:
		print("FAIL test_grab_lab: ", _fail)
		get_tree().quit(1)
