extends Node3D
## Upgrade 2 (agent A): crouch height and crouch-walk / crouch block, air
## stance, every new move and hold id present with strike bones and a charge
## pose for each chargeable move (tremble grows with the level), stumble and
## dazed, break_arm widens the arm's limits and hangs it, a gripped body
## never gets up while held and recovers after release, and the player's
## animator steps on TimeDirector.player_delta.

const NEW_MOVES: Array[StringName] = [&"cross", &"hook", &"uppercut", &"sparta_kick", &"roundhouse",
	&"leg_sweep", &"backfist", &"flying_kick", &"hammer_fist", &"crouch_punch", &"rising_uppercut", &"knee",
	&"headbutt", &"neck_throw", &"mount_punch", &"stomp", &"upward_throw", &"wall_slam", &"e_sweep", &"jab1"]
const NEW_HOLDS: Array[StringName] = [&"crouch", &"crouch_walk", &"block_crouch", &"jump_rise", &"jump_fall",
	&"land", &"stumble", &"dazed", &"headlock", &"arm_drag", &"giant_swing"]
const CHARGEABLE: Array[StringName] = [&"jab1", &"cross", &"hook", &"uppercut", &"sparta_kick", &"roundhouse",
	&"leg_sweep", &"crouch_punch", &"flying_kick", &"hammer_fist", &"backfist"]

var _ok := true

func _check(what: String, cond: bool, info := "") -> void:
	print("  %-48s %s %s" % [what, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _head_top(d: LabDummy) -> float:
	return (d.rig.get_bone_global_transform(Bones.HEAD) * Vector3(0, 0.28 * d.rig.height_scale, 0)).y

func _top_attachment(d: LabDummy) -> float:
	var m := -INF
	for b in Bones.ALL:
		m = maxf(m, d.rig.get_attachment(b).global_position.y)
	return m

func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("UPGRADE2 FAIL (timeout)")
		get_tree().quit(1))
	RigTestUtil.make_floor(self, 200.0)
	var d := RigTestUtil.make_dummy(self, &"player", Vector3.ZERO, null, true)
	var brute := RigTestUtil.make_dummy(self, &"brute", Vector3(4, 0, 0), null, true)
	await _frames(6)
	var stand_top := _head_top(d)

	# --- Ids --------------------------------------------------------------------
	var missing: Array = []
	for id in NEW_MOVES:
		if not PoseLibrary.has_move(id) or not PoseLibrary.STRIKE_BONES.has(id):
			missing.append(id)
		else:
			for b in PoseLibrary.STRIKE_BONES[id]:
				if not Bones.ALL.has(b):
					missing.append(b)
	for id in NEW_HOLDS:
		if not PoseLibrary.HOLDS.has(id):
			missing.append(id)
	for id in CHARGEABLE:
		if PoseLibrary.charge_hold_of(id) == &"":
			missing.append(String(id) + "_charge")
	_check("every new move/hold/charge id exists", missing.is_empty(), str(missing))
	_check("stumble and dazed play as moves too", PoseLibrary.has_move(&"stumble") and PoseLibrary.has_move(&"dazed"))

	# --- Crouch -----------------------------------------------------------------
	for dd in [d, brute]:
		dd.stance = &"crouch"
	await _frames(40)
	var h := _head_top(d)
	var hb := _head_top(brute)
	_check("crouch head top <= 1.15 m", h <= 1.15 and stand_top > 1.7, "%.2f m (standing %.2f)" % [h, stand_top])
	_check("crouch scales with height (brute)", hb <= 1.15 * brute.rig.height_scale, "%.2f m" % hb)
	_check("crouch hurtbox attachments below 1.2 m", _top_attachment(d) < 1.2, "%.2f m" % _top_attachment(d))
	d.move_input = Vector3(0, 0, -1)
	var walk_max := 0.0
	var f0 := d.rig.get_bone_global_position(Bones.L_FOOT)
	var foot_moved := 0.0
	for i in 120:
		await get_tree().physics_frame
		walk_max = maxf(walk_max, _head_top(d))
		foot_moved = maxf(foot_moved, d.rig.get_bone_global_position(Bones.L_FOOT).distance_to(f0))
	d.move_input = Vector3.ZERO
	_check("crouch-walk stays low and steps", walk_max <= 1.18 and foot_moved > 0.5, "top %.2f m, %.1f m walked" % [walk_max, d.global_position.length()])
	d.animator.hold_pose(&"block")
	await _frames(30)
	var lf := d.rig.get_fist_position(Bones.L_HAND)
	_check("block while crouched = block_crouch", _head_top(d) <= 1.15 and lf.y < 1.15 and lf.y > 0.8, "fist %.2f, head %.2f" % [lf.y, _head_top(d)])
	d.animator.release_pose()
	for dd in [d, brute]:
		dd.stance = &"stand"
	await _frames(40)
	_check("stand back up", _head_top(d) > 1.7, "%.2f" % _head_top(d))

	# --- Air ----------------------------------------------------------------------
	d.jump()
	var rise_feet := 0.0
	var fall_feet := 1.0
	var landed_ok := false
	for i in 120:
		await get_tree().physics_frame
		var ft := d.rig.get_bone_global_position(Bones.L_FOOT).y - d.global_position.y
		if d.velocity.y > 2.0:
			rise_feet = maxf(rise_feet, ft)
		elif d.velocity.y < -2.0:
			fall_feet = minf(fall_feet, ft)
		if d.animator.get_current_move() == &"land":
			landed_ok = true
	_check("jump_rise tucks the legs, jump_fall reaches down", rise_feet > 0.25 and fall_feet < 0.2, "feet %.2f / %.2f m above capsule base" % [rise_feet, fall_feet])
	_check("landing plays the land move", landed_ok)
	await _frames(30)

	# --- New moves: play each, strike bone moves, no errors ------------------------
	var still: Array = []
	for id in NEW_MOVES:
		var startup := 0.45 if String(id).begins_with("e_") else 0.15
		var bone: StringName = PoseLibrary.STRIKE_BONES[id][0]
		var p0 := d.rig.get_bone_global_position(bone)
		var done := [false]
		var cb := func(m: StringName) -> void:
			if m == id:
				done[0] = true
		d.animator.move_finished.connect(cb)
		d.animator.play_move(id, startup, 0.08, 0.3)
		await _frames(int(roundf((startup + 0.02) * 120.0)))
		var p1 := d.rig.get_bone_global_position(bone)
		var fwd := d.rig.get_bone_global_position(Bones.CHEST).z - p1.z
		print("    %-16s %-14s moved %.2f m, at active fwd %.2f up %.2f side %.2f" % [id, bone, p0.distance_to(p1), fwd, p1.y, p1.x])
		await _frames(50)
		d.animator.move_finished.disconnect(cb)
		if p0.distance_to(p1) < 0.05 or not done[0]:
			still.append(id)
	_check("every new move animates its strike bone and finishes", still.is_empty(), str(still))
	d.animator.play_move(&"backfist", 0.15, 0.08, 0.3)
	await _frames(20)
	var bf_hit := d.rig.get_fist_position(Bones.R_HAND)
	await _frames(60)
	var behind := bf_hit.z - d.global_position.z
	_check("spinning backfist lands behind", behind > 0.5 and bf_hit.y > 1.2, "%.2f m behind, y %.2f" % [behind, bf_hit.y])

	# --- Tell glow heights (agent C glows STRIKE_BONES[id][0] during the tell) ------
	# Round 5: e_hook is the grunt's cross (a straight punch at the head), so its
	# glow reads "head level" when it stays above the shoulder line (1.46 m).
	for spec in [[&"e_hook", 1.46, 1.8], [&"e_sweep", -1.0, 0.25], [&"e_kick", 0.3, 1.1]]:
		var id: StringName = spec[0]
		var b: StringName = PoseLibrary.STRIKE_BONES[id][0]
		d.animator.play_move(id, 0.45, 0.07, 0.3)
		var lo := INF
		var hi := -INF
		for f in 45:
			await get_tree().physics_frame
			if f >= 10:
				var y := d.rig.get_bone_global_position(b).y - d.global_position.y
				lo = minf(lo, y)
				hi = maxf(hi, y)
		await _frames(60)
		_check("%s tell glow height %.2f..%.2f m" % [id, spec[1], spec[2]], lo >= float(spec[1]) and hi <= float(spec[2]),
			"%s %.2f..%.2f m" % [b, lo, hi])

	# --- Charge holds: tremble grows with level ---------------------------------------
	var flat: Array = []
	for id in CHARGEABLE:
		var hold := PoseLibrary.charge_hold_of(id)
		var bone: StringName = PoseLibrary.STRIKE_BONES[id][0]
		d.animator.hold_pose(hold)
		await _frames(20)
		var jitter := []
		for lvl in [0, 3]:
			d.animator.set_charge_level(lvl)
			await _frames(4)
			var prev := d.rig.get_bone_global_position(bone)
			var acc := 0.0
			for i in 24:
				await get_tree().physics_frame
				var p := d.rig.get_bone_global_position(bone)
				acc += p.distance_to(prev)
				prev = p
			jitter.append(acc)
		if jitter[1] <= jitter[0] * 1.5:
			flat.append([id, jitter])
		d.animator.release_pose(0.05)
		await _frames(15)
	_check("charge tremble grows with level (all 11)", flat.is_empty(), str(flat))
	d.animator.hold_pose(&"cross_charge")
	await _frames(20)
	var cf := d.rig.get_fist_position(Bones.R_HAND)
	d.animator.release_pose()
	await _frames(20)
	_check("cross charge: fist cocked back beside the head", cf.z > d.rig.get_bone_global_position(Bones.CHEST).z - 0.05 and cf.y > 1.25, "fist z %.2f y %.2f" % [cf.z, cf.y])

	# --- States ---------------------------------------------------------------------
	d.animator.hold_pose(&"stumble")
	await _frames(30)
	var rf := d.rig.get_bone_global_position(Bones.R_FOOT)
	var lh := d.rig.get_fist_position(Bones.L_HAND)
	_check("stumble: right foot kicked out, arms out", rf.y > 0.15 and absf(lh.x) > 0.45, "foot %.2f up, hand %.2f out" % [rf.y, absf(lh.x)])
	d.animator.hold_pose(&"dazed")
	await _frames(30)
	var head := d.rig.get_bone_global_position(Bones.HEAD)
	_check("dazed: hunched", head.y < 1.42, "neck %.2f m" % head.y)
	for id in [&"headlock", &"arm_drag", &"giant_swing"]:
		d.animator.hold_pose(id)
		await _frames(12)
	d.animator.release_pose()
	await _frames(30)

	# --- Broken arm ---------------------------------------------------------------
	var lim0 := d.rig.get_hinge_limits(Bones.L_LOWER_ARM)
	var span0 := d.rig.get_cone_span(Bones.L_UPPER_ARM)
	d.ragdoll.break_arm(BodyZones.Zone.ARM_L)
	var lim1 := d.rig.get_hinge_limits(Bones.L_LOWER_ARM)
	var span1 := d.rig.get_cone_span(Bones.L_UPPER_ARM)
	_check("break_arm widens elbow and shoulder", lim1.x < lim0.x - 30.0 and lim1.y > lim0.y + 10.0 and span1 > span0 + 20.0,
		"elbow %s -> %s, shoulder %.0f -> %.0f" % [lim0, lim1, span0, span1])
	d.animator.play_move(&"jab1", 0.1, 0.1, 0.2)
	await _frames(14)
	var lfist := d.rig.get_fist_position(Bones.L_HAND)
	var lsh := d.rig.get_bone_global_position(Bones.L_UPPER_ARM)
	_check("broken arm hangs (jab1 can't raise it)", lfist.y < lsh.y - 0.4, "fist %.2f, shoulder %.2f" % [lfist.y, lsh.y])
	d.move_input = Vector3(1, 0, 0)
	var swing := 0.0
	var prev_rel := Vector3.ZERO
	for i in 60:
		await get_tree().physics_frame
		var rel := d.rig.get_fist_position(Bones.L_HAND) - d.rig.get_bone_global_position(Bones.L_UPPER_ARM)
		if i > 0:
			swing = maxf(swing, rel.distance_to(prev_rel))
		prev_rel = rel
	d.move_input = Vector3.ZERO
	_check("broken arm swings with motion", swing > 0.002, "%.4f m/tick" % swing)
	d.ragdoll.launch(Vector3(0, 3, 5), d.global_position, Bones.CHEST)
	var nan := false
	var t := 0
	while d.ragdoll.state != RagdollController.State.ANIMATED and t < 1200:
		await get_tree().physics_frame
		t += 1
		nan = nan or RigTestUtil.has_nan(d.ragdoll)
	_check("ragdoll with a broken arm recovers", not nan and d.ragdoll.state == RagdollController.State.ANIMATED, "%.2f s" % (t / 120.0))
	await _frames(40)

	# --- Gripped ----------------------------------------------------------------------
	var g := brute
	g.ragdoll.launch(Vector3(0, 1, 1), g.global_position, Bones.CHEST)
	g.ragdoll.set_gripped(true)
	var states := {}
	var max_speed := 0.0
	for i in 720:
		await get_tree().physics_frame
		states[g.ragdoll.state] = true
		max_speed = maxf(max_speed, RigTestUtil.max_bone_speed(g.ragdoll))
	_check("gripped body stays LAUNCHED, never gets up", states.keys() == [RagdollController.State.LAUNCHED] and g.ragdoll.is_gripped(),
		"states %s" % [states.keys()])
	g.ragdoll.set_gripped(false)
	t = 0
	while g.ragdoll.state != RagdollController.State.ANIMATED and t < 1200:
		await get_tree().physics_frame
		t += 1
	_check("released body lands and gets up", g.ragdoll.state == RagdollController.State.ANIMATED, "%.2f s" % (t / 120.0))
	g.ragdoll.set_gripped(true)
	await _frames(5)
	_check("set_gripped on a standing body ragdolls it", g.ragdoll.is_full_ragdoll() and g.ragdoll.state == RagdollController.State.LAUNCHED)
	g.ragdoll.set_gripped(false)
	await _frames(5)

	# --- delay_getup: ground finishers keep a downed body down ------------------------
	g.ragdoll.launch(Vector3(0, 1, 2), g.global_position, Bones.CHEST)
	t = 0
	while g.ragdoll.state != RagdollController.State.GROUNDED and t < 1200:
		await get_tree().physics_frame
		t += 1
	g.ragdoll.delay_getup(1.5)
	await _frames(24)
	g.ragdoll.delay_getup(0.2)   # must not shorten the 1.5 s
	var down_t := 0.2
	while g.ragdoll.state == RagdollController.State.GROUNDED and down_t < 5.0:
		await get_tree().physics_frame
		down_t += 1.0 / 120.0
	_check("delay_getup holds the body down (never shortens)", down_t >= 1.48 and g.ragdoll.state == RagdollController.State.GETUP,
		"get-up after %.2f s" % down_t)
	t = 0
	while g.ragdoll.state != RagdollController.State.ANIMATED and t < 600:
		await get_tree().physics_frame
		t += 1

	# --- Focus: the player's animator steps on player time ---------------------------
	d.add_to_group(&"player")
	await _frames(2)
	var expect := TimeDirector.player_delta(1.0 / 120.0)
	_check("player animator uses TimeDirector.player_delta", absf(d.animator.last_dt - expect) < 0.0001,
		"%.5f vs %.5f" % [d.animator.last_dt, expect])
	print("UPGRADE2 ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)
