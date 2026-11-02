extends Node3D
## The Grab Lab (scenes/grab_lab.tscn) keeps working: it loads with the real
## player, camera rig, dummies, walls and props, and its scripted demo grabs
## the dummy in front, carries it and throws it with a level-2 charge. Then
## the lab keys that script enemy grabs, knockdowns, kills and the arm drag run.
## OWNER: agent G.

var _fail: Array[String] = []
var _thrown := 0
var _grabs := 0

func _ready() -> void:
	get_tree().create_timer(90.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	GameEvents.thrown.connect(func(_g: Node3D, _v: Node3D, _vel: Vector3) -> void: _thrown += 1)
	GameEvents.grab_started.connect(func(_g: Node3D, _v: Node3D) -> void: _grabs += 1)
	var lab: Node3D = load("res://scenes/grab_lab.tscn").instantiate()
	lab.set(&"_demo", true)
	add_child(lab)
	var player: Fighter = lab.get(&"player")
	for i in 40:
		await GrabTestUtil.wait(self, 0.1)
		if i % 6 == 0:
			print("  t=%.1f %s result=%s drop=%s" % [i * 0.1, player.carry.get_debug_text(), player.carry.last_grab_result, player.carry.last_drop_reason])
	print("[lab] demo: grabs %d, throws %d, last throw %.1f m/s level %d, props %d, walls %d" % [_grabs, _thrown,
		player.carry.last_throw_velocity.length(), player.carry.last_throw_level, (lab.get(&"props") as Array).size(),
		(lab.get(&"walls") as Array).size()])
	_check(_grabs >= 1 and _thrown >= 1, "the demo grabs and throws")
	_check(player.carry.last_throw_level == 2, "with a level-2 charge")
	lab.set(&"_demo", false)
	await GrabTestUtil.wait(self, 3.2)
	for key in [KEY_1, KEY_2, KEY_3, KEY_1, KEY_4, KEY_8, KEY_8, KEY_5, KEY_6, KEY_7, KEY_R]:
		var ev := InputEventKey.new()
		ev.keycode = key
		ev.pressed = true
		lab.call(&"_unhandled_input", ev)
		await GrabTestUtil.wait(self, 0.9)
	print("[lab] lab keys ran: grabs %d, player %s, carry %s" % [_grabs, GrabTestUtil.state_name(player), player.carry.get_debug_text()])
	_check(_grabs >= 2, "the lab's scripted enemy grab connects")
	lab.queue_free()
	await GrabTestUtil.frames(self, 3)
	_finish()

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
