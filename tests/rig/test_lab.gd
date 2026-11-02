extends Node
## Loads the ragdoll lab scene and presses its keys (1-5, G, R) headless:
## no script errors, both dummies simulate and reset.

func _key(k: Key) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.pressed = true
	Input.parse_input_event(e)

func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("LAB FAIL (timeout)")
		get_tree().quit(1))
	var lab: Node = load("res://scenes/ragdoll_lab.tscn").instantiate()
	add_child(lab)
	for i in 10:
		await get_tree().physics_frame
	var ok := true
	for k in [KEY_1, KEY_R, KEY_2, KEY_R, KEY_3, KEY_R, KEY_4, KEY_5, KEY_R, KEY_P, KEY_1]:
		_key(k)
		for i in 150:
			await get_tree().physics_frame
		var l: LabDummy = lab.left
		var r: LabDummy = lab.right
		var sim: bool = l.ragdoll.is_simulating() and r.ragdoll.is_simulating()
		print("  key %s -> left %d right %d" % [OS.get_keycode_string(k), l.ragdoll.state, r.ragdoll.state])
		if k != KEY_R and k != KEY_5 and k != KEY_P:
			ok = ok and sim
		if k == KEY_R:
			ok = ok and not l.ragdoll.is_simulating() and not r.ragdoll.is_simulating()
	_key(KEY_G)
	for i in 300:
		await get_tree().physics_frame
	print("  after G: left %d right %d" % [lab.left.ragdoll.state, lab.right.ragdoll.state])
	ok = ok and lab.left.ragdoll.state == RagdollController.State.ANIMATED and lab.right.ragdoll.state == RagdollController.State.ANIMATED
	# Pose browser (Upgrade 2): step through every move and hold.
	var poser: LabDummy = lab.poser
	var moves_seen := {}
	for i in PoseLibrary.ALL_MOVE_IDS.size():
		_key(KEY_N)
		for f in 4:
			await get_tree().physics_frame
		moves_seen[poser.animator.get_current_move()] = true
		for f in 110:
			await get_tree().physics_frame
	var holds_seen := {}
	for i in lab._holds.size():
		_key(KEY_H)
		for f in 3:
			await get_tree().physics_frame
		holds_seen[poser.animator.get_hold_id()] = true
		_key(KEY_V)
		for f in 30:
			await get_tree().physics_frame
	_key(KEY_J)
	for k in [KEY_C, KEY_SPACE, KEY_X, KEY_M, KEY_Z, KEY_C]:
		_key(k)
		for f in 90:
			await get_tree().physics_frame
	print("  pose browser: %d moves, %d holds shown" % [moves_seen.size(), holds_seen.size()])
	ok = ok and moves_seen.size() >= PoseLibrary.ALL_MOVE_IDS.size() - 2 and holds_seen.size() >= lab._holds.size() - 2
	print("LAB ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)
