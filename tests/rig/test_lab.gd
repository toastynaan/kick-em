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
	var all_ids := PoseLibrary.all_move_ids()
	for i in all_ids.size():
		_key(KEY_N)
		for f in 4:
			await get_tree().physics_frame
		moves_seen[poser.animator.get_current_move()] = true
		for f in 80:
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
	ok = ok and moves_seen.size() >= all_ids.size() - 2 and holds_seen.size() >= lab._holds.size() - 2
	# Round 5 (F0): L makes one arm limp while the rest follows its animation.
	_key(KEY_R)
	for f in 60:
		await get_tree().physics_frame
	_key(KEY_N)   # a move playing: the rest of the body animates it
	_key(KEY_L)
	for f in 60:
		await get_tree().physics_frame
	var prc: RagdollController = poser.ragdoll
	var limp_ok := prc.get_bone_strength(Bones.L_UPPER_ARM) < 0.01 and prc.get_bone_strength(Bones.L_LOWER_ARM) < 0.01 \
		and prc.get_bone_strength(Bones.R_UPPER_ARM) > 0.999 and prc.get_bone_strength(Bones.HEAD) > 0.999 \
		and prc.state == RagdollController.State.ANIMATED and prc.is_partial_ragdoll()
	var worst := 0.0
	for b in Bones.ALL:
		if not b in [Bones.L_UPPER_ARM, Bones.L_LOWER_ARM, Bones.L_HAND]:
			var i := HumanoidRig.bone_index(b)
			worst = maxf(worst, rad_to_deg(poser.rig.skeleton.get_bone_pose_rotation(i).angle_to(poser.animator.pose_rot[i])))
	print("  key L: left arm strength %.2f/%.2f, others 1, rest off the animation by %.3f deg -> %s" % [
		prc.get_bone_strength(Bones.L_UPPER_ARM), prc.get_bone_strength(Bones.L_LOWER_ARM), worst, "ok" if limp_ok and worst < 0.5 else "FAILED"])
	ok = ok and limp_ok and worst < 0.5
	_key(KEY_L)
	for f in 40:
		await get_tree().physics_frame
	ok = ok and not prc.is_partial_ragdoll()
	# Tier reactions with their hitstop, severing launch, hold, kill.
	var seen := {}
	for k in [KEY_6, KEY_7, KEY_8, KEY_9, KEY_0]:
		_key(k)
		for f in 30:
			await get_tree().physics_frame
			seen[prc.state] = true
		for f in 330:
			await get_tree().physics_frame
	print("  keys 6-0: poser states seen %s" % [seen.keys()])
	ok = ok and seen.has(RagdollController.State.FLINCH) and seen.has(RagdollController.State.STAGGER) \
		and seen.has(RagdollController.State.LAUNCHED)
	_key(KEY_T)
	for f in 120:
		await get_tree().physics_frame
	var limbs := HumanoidRig.loose_limb_count()
	_key(KEY_Y)
	for f in 240:
		await get_tree().physics_frame
	var held: bool = lab.right.ragdoll.is_held()
	_key(KEY_Y)
	_key(KEY_U)
	for f in 60:
		await get_tree().physics_frame
	var dead: bool = lab.left.ragdoll.state == RagdollController.State.DEAD
	print("  T loose limbs %d, Y held %s, U dead %s" % [limbs, held, dead])
	ok = ok and limbs >= 1 and held and not lab.right.ragdoll.is_held() and dead
	# Wall range: P 9 (14 m/s) into drywall breaks it (wall table: 6,205 J > 2,000 J).
	_key(KEY_W)
	_key(KEY_W)   # P 5 -> 7 -> 9
	_key(KEY_F)
	for f in 240:
		await get_tree().physics_frame
	var range_result: String = lab._range_result
	print("  wall range: drywall at P %.0f -> %s" % [lab.RANGE_P[lab._range_p], range_result])
	ok = ok and range_result.contains("BROKEN")
	_key(KEY_E)
	_key(KEY_Q)
	for f in 10:
		await get_tree().physics_frame
	print("LAB ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)
