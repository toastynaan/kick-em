extends Node3D
## Animation timing (agent P):
## - play_timed(id, d) lasts exactly d s of the fighter's time (move_finished
##   on the tick that reaches d), for moves, holds and plain poses;
##   set_move_progress scrubs it.
## - A strike's contact keyframe lands on its first active frame for any
##   startup: the player's frame data (Tuning.STRIKE_FRAMES, Round 7
##   Tuning.R7_MOVES) and enemy startups 12-30 frames (Tuning.ENEMY_STARTUP).
## - Per-fighter time: time_scale 0 (hitstop) or the host's get_actor_time() 0
##   freezes the animation exactly; it resumes where it stopped.
## OWNER: agent P.

const TICK := 1.0 / 120.0

var _ok := true

func _check(what: String, cond: bool, info := "") -> void:
	print("  %-60s %s %s" % [what, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("ANIM_TIMING FAIL (timeout)")
		get_tree().quit(1))
	var h := AnimTestUtil.make_host(self)
	await _frames(4)
	# --- play_timed --------------------------------------------------------------
	var cases := [[&"vault_speed", 0.28], [&"vault_speed", 0.35], [&"mantle", 0.45], [&"wall_kickoff", 0.3],
		[&"land_crouch", 0.12], [&"land_three_point", 0.2], [&"land_roll", 0.5], [&"sprint_start", 0.3],
		[&"parry", 0.25], [&"throw", 0.4], [&"body_slam", 0.6], [&"getup_fast", 0.45], [&"stumble_back", 0.6],
		[&"jab", 0.25], [&"guard", 0.3], [&"carry_hold", 0.3], [&"throw_charge", 0.5]]
	var worst := 0.0
	var bad: Array = []
	for c in cases:
		var id: StringName = c[0]
		var d: float = c[1]
		# The animator advances once per physics frame from this one on: a move that
		# finishes on frame F has run (F - f0 + 1) ticks.
		var done := [-1.0]
		var f0 := Engine.get_physics_frames()
		var cb := func(m: StringName) -> void:
			if m == id and done[0] < 0.0:
				done[0] = float(Engine.get_physics_frames() - f0 + 1) * TICK
		h.anim.move_finished.connect(cb)
		h.anim.play_timed(id, d)
		var len_ok := absf(h.anim.get_move_length() - d) < 0.000001
		for i in int(d * 120.0) + 6:
			await get_tree().physics_frame
			if done[0] >= 0.0:
				break
		h.anim.move_finished.disconnect(cb)
		var err := absf(float(done[0]) - d)
		worst = maxf(worst, err)
		print("    %-18s asked %.3f s  finished after %.4f s (%d ticks)" % [id, d, done[0], roundi(float(done[0]) * 120.0)])
		if done[0] < 0.0 or err > TICK + 0.0001 or not len_ok:
			bad.append("%s %.3f->%.4f" % [id, d, done[0]])
		await _frames(30)
	_check("play_timed lasts its duration (within one 120 Hz tick)", bad.is_empty(), "worst %.4f s %s" % [worst, str(bad)])
	# Scrub.
	h.anim.play_timed(&"vault_speed", 0.3)
	await _frames(2)
	h.anim.set_move_progress(0.5)
	var mt := h.anim.get_move_time()
	await get_tree().physics_frame
	var prog := h.anim.get_move_progress()
	_check("set_move_progress(0.5) scrubs to mid-vault", absf(mt - 0.15) < 0.0001 and absf(prog - (0.15 + TICK) / 0.3) < 0.001,
		"t %.4f, progress %.3f" % [mt, prog])
	await _frames(60)
	# --- Contact keyframe on the first active frame ----------------------------------
	var strikes := [[&"jab", 5], [&"cross", 9], [&"kick", 12], [&"sweep", 10], [&"knee", 7], [&"elbow", 7],
		[&"ground_stomp", 8], [&"knee_drop", 8], [&"drop_strike", 8],
		[&"e_jab", 18], [&"e_hook", 22], [&"e_kick", 24], [&"e_grab", 20], [&"e_stick_swing", 20],
		[&"e_stick_thrust", 24], [&"e_heavy", 30], [&"e_charge", 28], [&"e_grab_slam", 26]]
	for id in Tuning.ENEMY_STARTUP:
		strikes.append([id, int(Tuning.ENEMY_STARTUP_MIN)])
	# Round 7: every player strike on its own R7_MOVES startup.
	for id in Tuning.R7_MOVES:
		strikes.append([id, int((Tuning.R7_MOVES[id]["f"] as Vector3).x)])
	var late: Array = []
	var worst_at := 0.0
	for s in strikes:
		var id: StringName = s[0]
		var n: int = s[1]
		var startup := Tuning.frames(n)
		var contact := _contact_pose(id)
		var bones := _strike_chain(id)
		h.anim.play_move(id, startup, Tuning.frames(3), Tuning.frames(12))
		var key_t := -1.0
		for k in h.anim._keys:
			if int(k[1]) == 0 and k[2] == contact:
				key_t = k[0]
				break
		var ticks := int(roundf(startup * 120.0))
		await _frames(ticks - 1)
		var before := _pose_diff(h, contact, bones)
		await get_tree().physics_frame
		var at := _pose_diff(h, contact, bones)
		worst_at = maxf(worst_at, at)
		print("    %-16s startup %2d f (%.4f s): contact key at %.4f s; limb vs contact pose one tick before %5.2f deg, on the first active frame %.4f deg" % [
			id, n, startup, key_t, before, at])
		if at > 0.01 or absf(key_t - startup) > 0.000001:
			late.append(id)
		await _frames(60)
	_check("contact pose exactly on the first active frame (%d strikes)" % strikes.size(), late.is_empty(),
		"worst %.3f deg %s" % [worst_at, str(late)])
	# --- Per-fighter time ------------------------------------------------------------
	for mode in ["time_scale", "actor_time"]:
		h.anim.play_move(&"kick", 0.2, 0.07, 0.3)
		await _frames(8)
		if mode == "time_scale":
			h.anim.time_scale = 0.0
		else:
			h.actor_time = 0.0
		await get_tree().physics_frame
		var t0 := h.anim.get_move_time()
		var p0: Array = h.anim.pose_rot.duplicate()
		var foot0 := h.rig.get_bone_global_position(Bones.R_FOOT)
		await _frames(24)
		var t1 := h.anim.get_move_time()
		var drift := AnimTestUtil.max_diff(p0, h.anim.pose_rot, 0, HumanoidRig.BONE_COUNT)
		var same := true
		for i in HumanoidRig.BONE_COUNT:
			same = same and p0[i] == h.anim.pose_rot[i]
		var foot_drift := h.rig.get_bone_global_position(Bones.R_FOOT).distance_to(foot0)
		var frozen_dt := h.anim.last_dt
		h.anim.time_scale = 1.0
		h.actor_time = 1.0
		await _frames(6)
		var t2 := h.anim.get_move_time()
		_check("%s 0 freezes the animation (24 ticks)" % mode, t1 == t0 and same and foot_drift == 0.0 and frozen_dt == 0.0,
			"move time %.4f -> %.4f, pose drift %.4f deg, foot %.5f m" % [t0, t1, drift, foot_drift])
		_check("%s 1 resumes where it stopped" % mode, absf(t2 - (t0 + 6.0 * TICK)) < 0.0001, "%.4f -> %.4f" % [t0, t2])
		await _frames(60)
	print("ANIM_TIMING ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _contact_pose(id: StringName) -> PoseLibrary.Pose:
	for k in PoseLibrary.move_def(id)["keys"]:
		if int(k[0]) == 1:
			return PoseLibrary.get_pose(k[2])
	return null

## Bones of the striking limb(s) the contact pose defines.
func _strike_chain(id: StringName) -> Array[int]:
	var out: Array[int] = []
	for b in PoseLibrary.STRIKE_BONES.get(id, []):
		var chain: Array[StringName] = []
		match b:
			Bones.L_HAND, Bones.L_LOWER_ARM:
				chain = [Bones.L_UPPER_ARM, Bones.L_LOWER_ARM]
			Bones.R_HAND, Bones.R_LOWER_ARM:
				chain = [Bones.R_UPPER_ARM, Bones.R_LOWER_ARM]
			Bones.R_FOOT, Bones.R_LOWER_LEG, Bones.R_UPPER_LEG:
				chain = [Bones.R_UPPER_LEG, Bones.R_LOWER_LEG]
			Bones.L_FOOT, Bones.L_LOWER_LEG:
				chain = [Bones.L_UPPER_LEG, Bones.L_LOWER_LEG]
			_:
				chain = [Bones.SPINE, Bones.CHEST]
		for c in chain:
			var i := HumanoidRig.bone_index(c)
			if not out.has(i):
				out.append(i)
	return out

func _pose_diff(h: AnimTestUtil.AnimHost, p: PoseLibrary.Pose, bones: Array[int]) -> float:
	var m := 0.0
	for i in bones:
		if p.rot[i] != null:
			m = maxf(m, AnimTestUtil.angle_deg(h.anim.pose_rot[i], p.rot[i]))
	return m
