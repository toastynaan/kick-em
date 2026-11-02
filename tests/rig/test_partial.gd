extends Node3D
## Round 5 partial ragdolls (Feel Reference: Partial ragdoll reactions), agent A.
## F0: one arm limp while the rest follows its animation (strength 0 in that
## arm, it hangs and swings under gravity, every other bone matches the
## animation, the fighter keeps walking). F3: a jab to the head lowers muscle
## strength only in the head chain (get_bone_strength of all 16 bones logged).
## Then every on-feet tier: hook turns the head, arm and body flinch chains,
## stagger (spine and up + arms 80%, legs animated, pushed 0.6-1.0 m, upright,
## never a launch), stumble (swept leg from the knee down 50%, side steps),
## and the ground tiers: knockdown (drops in place, set_getup_after honoured,
## default 1.2-2.0 s), launch (default 1.5-2.5 s), the player's 0.8 s + fast get-up.

var _ok := true

func _check(what: String, cond: bool, info := "") -> void:
	print("  %-58s %s %s" % [what, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

## Degrees between the written skeleton pose and the animator's pose for bone `b`.
func _off_anim(d: LabDummy, b: StringName) -> float:
	var i := HumanoidRig.bone_index(b)
	return rad_to_deg(d.rig.skeleton.get_bone_pose_rotation(i).angle_to(d.animator.pose_rot[i]))

func _strengths(rc: RagdollController) -> Dictionary:
	var out := {}
	for b in Bones.ALL:
		out[b] = rc.get_bone_strength(b)
	return out

func _fmt(s: Dictionary) -> String:
	var parts: Array[String] = []
	for b in Bones.ALL:
		parts.append("%s %.2f" % [String(b).replace("Left", "L").replace("Right", "R"), s[b]])
	return ", ".join(parts)

## Bones whose strength is below 0.999.
func _lowered(s: Dictionary) -> Array:
	var out := []
	for b in Bones.ALL:
		if s[b] < 0.999:
			out.append(b)
	return out

func _reset(d: LabDummy, pos: Vector3) -> void:
	d.ragdoll.force_recover()
	d.global_transform = Transform3D(Basis(), pos)
	d.velocity = Vector3.ZERO
	d.move_input = Vector3.ZERO
	d.reset_physics_interpolation()
	d.animator.reset_pose()
	await _frames(20)

func _ready() -> void:
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		print("PARTIAL FAIL (timeout)")
		get_tree().quit(1))
	RigTestUtil.make_floor(self, 200.0)
	var d := RigTestUtil.make_dummy(self, &"grunt", Vector3.ZERO, null, false)
	await _frames(8)
	var rc := d.ragdoll

	# --- F0: one arm limp, the rest animated -----------------------------------------
	print("F0 limp arm (Ragdoll Lab key L does the same on the POSES dummy)")
	d.animator.hold_pose(&"block")   # both fists up by the face
	await _frames(30)
	var limp: Array[StringName] = [Bones.L_UPPER_ARM, Bones.L_LOWER_ARM]
	rc.limp_chain(limp, 1.0, 0.0)
	_check("limp_chain keeps the fighter in control (ANIMATED)", rc.state == RagdollController.State.ANIMATED
		and not rc.is_simulating() and rc.is_partial_ragdoll())
	await _frames(90)
	var s := _strengths(rc)
	print("    strength: ", _fmt(s))
	_check("limp arm strength 0, every other bone 1", s[Bones.L_UPPER_ARM] < 0.001 and s[Bones.L_LOWER_ARM] < 0.001
		and _lowered(s) == [Bones.L_UPPER_ARM, Bones.L_LOWER_ARM, Bones.L_HAND], str(_lowered(s)))
	# It dropped from the guard and swings: average the hang over 1 s.
	var drop := 0.0
	var rdrop := 0.0
	for f in 120:
		await get_tree().physics_frame
		var lsh := d.rig.get_bone_global_position(Bones.L_UPPER_ARM)
		drop += lsh.y - d.rig.get_fist_position(Bones.L_HAND).y
		rdrop += lsh.y - d.rig.get_fist_position(Bones.R_HAND).y
	drop /= 120.0
	rdrop /= 120.0
	_check("limp arm hangs under gravity, the other keeps the guard", drop > 0.4 and rdrop < 0.15,
		"left fist %.2f m below the shoulder (mean over 1 s), right fist %.2f m" % [drop, rdrop])
	var worst := 0.0
	for b in Bones.ALL:
		if not b in [Bones.L_UPPER_ARM, Bones.L_LOWER_ARM, Bones.L_HAND]:
			worst = maxf(worst, _off_anim(d, b))
	_check("every other bone matches the animation", worst < 0.5, "worst %.3f deg" % worst)
	# Walk with it: the fighter moves, the arm swings.
	d.animator.release_pose()
	d.move_input = Vector3(0, 0, -1)
	var spin_max := 0.0
	var spin_sum := 0.0
	var la := d.rig.get_physical_bone(Bones.L_LOWER_ARM).get_rid()
	var walked := 0.0
	var prev := d.global_position
	for f in 240:
		await get_tree().physics_frame
		walked += d.global_position.distance_to(prev)
		prev = d.global_position
		if f == 120:
			d.move_input = Vector3(0, 0, 1)   # turn back: the arm swings through
		var w: Vector3 = PhysicsServer3D.body_get_state(la, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		spin_max = maxf(spin_max, w.length())
		spin_sum += w.length()
	d.move_input = Vector3.ZERO
	worst = 0.0
	for b in Bones.ALL:
		if not b in [Bones.L_UPPER_ARM, Bones.L_LOWER_ARM, Bones.L_HAND]:
			worst = maxf(worst, _off_anim(d, b))
	_check("walking: limp arm swings, rest animated", spin_max > 1.0 and worst < 0.5 and walked > 7.0
		and rc.state == RagdollController.State.ANIMATED,
		"forearm spin max %.2f mean %.2f rad/s, others off %.3f deg, walked %.1f m" % [spin_max, spin_sum / 240.0, worst, walked])
	rc.restore_chain(limp)
	await _frames(30)
	s = _strengths(rc)
	_check("restore_chain: full strength, partial off", _lowered(s).is_empty() and not rc.is_partial_ragdoll())
	await _reset(d, Vector3.ZERO)

	# --- F3: a jab to the head lowers strength only in the head chain ------------------
	print("F3 jab to the head")
	var jab_dir := Vector3(0, 0, 1)   # the dummy faces -Z; a jab from the front travels +Z
	rc.flinch(jab_dir, Bones.HEAD, 1.0)
	s = _strengths(rc)
	print("    strength right after the head flinch: ", _fmt(s))
	_check("only the head chain is lowered", _lowered(s) == [Bones.HEAD] and absf(s[Bones.HEAD] - 0.4) < 0.01,
		"head %.2f, lowered %s" % [s[Bones.HEAD], _lowered(s)])
	_check("flinch state, capsule kept", rc.state == RagdollController.State.FLINCH and not (d.get_node("Capsule") as CollisionShape3D).disabled)
	var peak := 0.0
	var peak_t := 0.0
	var head_z0 := d.rig.get_bone_global_position(Bones.HEAD).z
	var back := 0.0
	var mid := 0.0
	var t := 0
	while t < 60:
		await get_tree().physics_frame
		t += 1
		var a := _off_anim(d, Bones.HEAD)
		if a > peak:
			peak = a
			peak_t = t / 120.0
		back = maxf(back, (d.rig.get_bone_global_transform(Bones.HEAD) * Vector3(0, 0.15, 0)).z - head_z0)
		if t == 18:
			mid = rc.get_bone_strength(Bones.HEAD)
	var after := _off_anim(d, Bones.HEAD)
	_check("head snaps back, then recovers by 0.5 s", peak > 12.0 and back > 0.0 and after < 2.0,
		"peak %.1f deg at %.2f s, crown %.3f m back, %.2f deg at 0.5 s" % [peak, peak_t, back, after])
	_check("strength fades back to 1 (0.15 s: %.2f)" % mid, mid > 0.45 and mid < 0.95 and rc.get_bone_strength(Bones.HEAD) > 0.999)
	_check("flinch over in 0.25 s", rc.state == RagdollController.State.ANIMATED)
	await _reset(d, Vector3.ZERO)

	# A hook turns the head sideways.
	var hook_dir := Vector3(-1, 0, 0.2).normalized()   # from the right, travelling across the face
	var yaw0 := d.rig.get_bone_global_transform(Bones.HEAD).basis.z
	rc.flinch(hook_dir, Bones.HEAD, 1.0)
	var yaw_peak := 0.0
	var side := 0.0
	for f in 40:
		await get_tree().physics_frame
		var z := d.rig.get_bone_global_transform(Bones.HEAD).basis.z
		var yz := rad_to_deg(Vector2(yaw0.x, yaw0.z).angle_to(Vector2(z.x, z.z)))
		yaw_peak = maxf(yaw_peak, absf(yz))
		side = minf(side, (d.rig.get_bone_global_transform(Bones.HEAD) * Vector3(0, 0.15, 0)).x)
	_check("a hook turns the head sideways", yaw_peak > 8.0 and side < -0.02, "yaw %.1f deg, crown %.3f m sideways" % [yaw_peak, side])
	await _reset(d, Vector3.ZERO)

	# Arm and body chains.
	rc.flinch(Vector3(0, 0, 1), Bones.R_LOWER_ARM, 1.0)
	s = _strengths(rc)
	_check("arm hit: only that arm's upper + lower arm", _lowered(s) == [Bones.R_UPPER_ARM, Bones.R_LOWER_ARM, Bones.R_HAND],
		str(_lowered(s)))
	await _frames(50)
	rc.flinch(Vector3(0, 0, 1), Bones.CHEST, 1.0)
	s = _strengths(rc)
	_check("body hit: spine + chest only", _lowered(s) == [Bones.SPINE, Bones.CHEST], str(_lowered(s)))
	var spine_peak := 0.0
	for f in 30:
		await get_tree().physics_frame
		spine_peak = maxf(spine_peak, maxf(_off_anim(d, Bones.SPINE), _off_anim(d, Bones.CHEST)))
	_check("a body jab bends the spine (less than the head snaps)", spine_peak > 4.0 and spine_peak < peak, "%.1f deg" % spine_peak)
	await _reset(d, Vector3.ZERO)

	# --- Stagger ----------------------------------------------------------------------
	print("Stagger")
	var start := d.global_position
	rc.stagger(Vector3(0, 0, 1), 0.75)
	s = _strengths(rc)
	print("    strength right after the stagger: ", _fmt(s))
	var want_low := [Bones.SPINE, Bones.CHEST, Bones.HEAD, Bones.L_UPPER_ARM, Bones.L_LOWER_ARM, Bones.L_HAND,
		Bones.R_UPPER_ARM, Bones.R_LOWER_ARM, Bones.R_HAND]
	_check("spine and up + both arms at 20% strength, legs 1", _lowered(s) == want_low and absf(s[Bones.CHEST] - 0.2) < 0.01)
	var tilt := 0.0
	var states := {}
	var full := false
	var end_t := -1.0
	for f in 150:
		await get_tree().physics_frame
		states[rc.state] = true
		full = full or rc.is_full_ragdoll()
		var up := d.rig.get_bone_global_transform(Bones.HIPS).basis.y
		tilt = maxf(tilt, rad_to_deg(up.angle_to(Vector3.UP)))
		if end_t < 0.0 and rc.state == RagdollController.State.ANIMATED:
			end_t = (f + 1) / 120.0
	var pushed := Vector2(d.global_position.x - start.x, d.global_position.z - start.z).length()
	_check("stagger: pushed back 0.6-1.0 m, upright, never a launch", pushed >= 0.6 and pushed <= 1.0 and tilt < 25.0
		and not full and not states.has(RagdollController.State.LAUNCHED),
		"pushed %.2f m, hips tilt %.1f deg, back on its feet after %.2f s" % [pushed, tilt, end_t])
	await _reset(d, Vector3.ZERO)
	rc.stagger(Vector3(0.3, 0, 1), 1.5)   # the strongest stagger still never tips over
	full = false
	for f in 240:
		await get_tree().physics_frame
		full = full or rc.is_full_ragdoll()
	_check("a strong stagger never tips into a launch", not full and rc.state == RagdollController.State.ANIMATED)
	await _reset(d, Vector3.ZERO)

	# --- Stumble ----------------------------------------------------------------------
	print("Stumble (sweep)")
	start = d.global_position
	rc.stumble(Vector3(1, 0, 0), Bones.L_LOWER_LEG)
	s = _strengths(rc)
	_check("stumble: swept leg from the knee down at 50%", _lowered(s) == [Bones.L_LOWER_LEG, Bones.L_FOOT]
		and absf(s[Bones.L_LOWER_LEG] - 0.5) < 0.01 and rc.get_reaction_kind() == &"stumble", str(_lowered(s)))
	var knee := 0.0
	full = false
	end_t = -1.0
	var held_at := 0.0
	for f in 120:
		await get_tree().physics_frame
		knee = maxf(knee, _off_anim(d, Bones.L_LOWER_LEG))
		full = full or rc.is_full_ragdoll()
		if f == 30:
			held_at = rc.get_bone_strength(Bones.L_LOWER_LEG)
		if end_t < 0.0 and rc.state == RagdollController.State.ANIMATED:
			end_t = (f + 1) / 120.0
	var side_m := d.global_position.x - start.x
	_check("stumble: the knee folds, 0.3 s hold, side steps", knee > 10.0 and absf(held_at - 0.5) < 0.01 and side_m > 0.5
		and side_m < 0.9 and not full and end_t > 0.55 and end_t < 0.7,
		"knee %.1f deg, strength at 0.25 s %.2f, %.2f m sideways, over at %.2f s" % [knee, held_at, side_m, end_t])
	await _reset(d, Vector3.ZERO)
	# A sweep from straight ahead still steps sideways (toward the swept leg).
	start = d.global_position
	rc.stumble(Vector3(0, 0, 1), Bones.R_FOOT)
	await _frames(80)
	var moved := d.global_position - start
	_check("a straight-on sweep steps sideways, toward the swept leg", moved.x > 0.4 and absf(moved.z) < moved.x * 0.5,
		"moved x %.2f z %.2f m" % [moved.x, moved.z])
	await _reset(d, Vector3.ZERO)

	# --- Knockdown ---------------------------------------------------------------------
	print("Knockdown and launch ground time")
	for case in [[1.5, true], [-1.0, true], [-1.0, false]]:
		await _reset(d, Vector3.ZERO)
		var p_start := d.global_position
		var set_t: float = case[0]
		if set_t > 0.0:
			rc.set_getup_after(set_t)
		var is_kd: bool = case[1]
		if is_kd:
			rc.knockdown(Vector3(0, 0, 1), Bones.CHEST)
		else:
			rc.launch(Power.launch_velocity(6.0, Vector3(0, 0, 1)), d.global_position + Vector3.UP, Bones.CHEST)
		var low_strength := rc.get_bone_strength(Bones.CHEST)
		var land_at := -1.0
		var getup_at := -1.0
		var rest_pos := Vector3.ZERO
		var n := 0
		var landed := [false]
		var cb := func() -> void: landed[0] = true
		rc.landed.connect(cb)
		while n < 900 and rc.state != RagdollController.State.ANIMATED:
			await get_tree().physics_frame
			n += 1
			if land_at < 0.0 and landed[0]:
				land_at = n / 120.0
			if getup_at < 0.0 and rc.state == RagdollController.State.GETUP:
				getup_at = n / 120.0
				rest_pos = d.global_position
		rc.landed.disconnect(cb)
		var ground := getup_at - land_at
		var travel := Vector2(rest_pos.x - p_start.x, rest_pos.z - p_start.z).length()
		var want: Vector2 = Vector2(set_t, set_t) if set_t > 0.0 else (Tuning.REACT_KNOCKDOWN["ground"] if is_kd else Tuning.REACT_LAUNCH["ground"])
		var ok := ground >= want.x - 0.05 and ground <= want.y + 0.15 and rc.state == RagdollController.State.ANIMATED
		if is_kd:
			ok = ok and travel < 1.3 and low_strength < 0.1
		_check("%s%s: ground time %.2f s (want %.1f-%.1f)" % ["knockdown" if is_kd else "launch",
			" set_getup_after(%.1f)" % set_t if set_t > 0.0 else " default", ground, want.x, want.y], ok,
			"landed %.2f s, get-up %.2f s, travel %.2f m, chest strength %.2f" % [land_at, getup_at, travel, low_strength])

	# --- Player: 0.8 s on the ground, fast get-up --------------------------------------------
	await _reset(d, Vector3.ZERO)
	d.add_to_group(&"player")
	rc.knockdown(Vector3(0, 0, 1), Bones.CHEST)
	var n2 := 0
	var gu := -1.0
	while n2 < 600 and rc.state != RagdollController.State.ANIMATED:
		await get_tree().physics_frame
		n2 += 1
		if gu < 0.0 and rc.state == RagdollController.State.GETUP:
			gu = n2 / 120.0
	var act := n2 / 120.0
	_check("player knockdown: up and acting within 1.1 s", rc.state == RagdollController.State.ANIMATED and act <= 1.1
		and absf(rc.get_getup_after() - Tuning.PLAYER_GETUP_AFTER) < 0.001,
		"get-up starts %.2f s, acting at %.2f s" % [gu, act])
	d.remove_from_group(&"player")

	print("PARTIAL ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)
