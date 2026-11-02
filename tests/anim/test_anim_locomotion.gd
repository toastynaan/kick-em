extends Node3D
## Locomotion styles and layering (agent P):
## - every style switches in; the cycle speed follows the velocity: planted
##   feet (and the crawler's planted hands) stay put on the ground while the
##   body moves (measured world slide vs body speed);
## - strafe feet never cross; the wall run plants the feet on the wall side
##   and rolls the body away from it; the crawl is low, the limp hunched;
## - the upper overlay (carry_hold) leaves the legs' locomotion untouched;
## - upper-body strikes and charge holds keep the legs running at speed;
## - stumble moves take 2-3 quick steps.
## OWNER: agent P.

const TICK := 1.0 / 120.0

var _ok := true

func _check(what: String, cond: bool, info := "") -> void:
	print("  %-62s %s %s" % [what, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("ANIM_LOCOMOTION FAIL (timeout)")
		get_tree().quit(1))
	var h := AnimTestUtil.make_host(self)
	await _frames(4)
	# --- Styles switch; cycle speed follows the velocity -------------------------
	for c in [[&"walk", Vector3(0, 0, -1.5), Bones.L_FOOT], [&"walk", Vector3(0, 0, -4.5), Bones.L_FOOT],
			[&"sprint", Vector3(0, 0, -6.0), Bones.L_FOOT], [&"sprint", Vector3(0, 0, -8.0), Bones.L_FOOT],
			[&"sprint", Vector3(0, 0, -12.0), Bones.R_FOOT], [&"carry", Vector3(0, 0, -6.4), Bones.L_FOOT],
			[&"strafe", Vector3(1.2, 0, 0), Bones.L_FOOT], [&"limp", Vector3(0, 0, -1.2), Bones.R_FOOT],
			[&"crawl", Vector3(0, 0, -0.8), Bones.L_HAND]]:
		var st: StringName = c[0]
		var v: Vector3 = c[1]
		h.anim.set_locomotion_style(st)
		var r := await _run(h, v, 1.6, c[2])
		var speed := v.length()
		_check("%-6s %4.1f m/s: planted %s slides <= 15%% of body speed" % [st, speed, c[2]],
			h.anim.get_locomotion_style() == st and float(r["slide"]) <= 0.15 * speed and int(r["planted"]) > 10,
			"median slide %.2f m/s, %d planted ticks, %.2f steps/s" % [r["slide"], r["planted"], r["steps"]])
	# Cadence rises with speed (the sprint stride grows too).
	h.anim.set_locomotion_style(&"sprint")
	var r6 := await _run(h, Vector3(0, 0, -6.0), 1.2, Bones.L_FOOT)
	var r8 := await _run(h, Vector3(0, 0, -8.0), 1.2, Bones.L_FOOT)
	var r12 := await _run(h, Vector3(0, 0, -12.0), 1.2, Bones.L_FOOT)
	_check("sprint cycle follows velocity (steps/s 6 < 8 <= 12 m/s)", float(r6["steps"]) < float(r8["steps"]) and float(r8["steps"]) <= float(r12["steps"]) + 0.05,
		"%.2f / %.2f / %.2f steps/s, stride %.2f / %.2f / %.2f m" % [r6["steps"], r8["steps"], r12["steps"],
			6.0 / maxf(r6["steps"], 0.01), 8.0 / maxf(r8["steps"], 0.01), 12.0 / maxf(r12["steps"], 0.01)])
	# --- Style specifics ---------------------------------------------------------
	h.anim.set_locomotion_style(&"strafe")
	var min_gap := INF
	for dir in [Vector3(1.3, 0, 0), Vector3(-1.3, 0, 0)]:
		h.anim.set_locomotion(dir, 3.2)
		for i in 120:
			await get_tree().physics_frame
			h.position += dir * TICK
			if i > 30:
				var gap := AnimTestUtil.local_pos(h, Bones.R_FOOT).x - AnimTestUtil.local_pos(h, Bones.L_FOOT).x
				min_gap = minf(min_gap, gap)
	_check("strafe: feet never cross (right foot stays right of the left)", min_gap > 0.08, "min gap %.2f m" % min_gap)
	for wall in [&"wall_run_l", &"wall_run_r"]:
		h.anim.set_locomotion_style(wall)
		h.anim.set_locomotion(Vector3(0, 0, -8), 8.0)
		var sgn := -1.0 if wall == &"wall_run_l" else 1.0
		var foot_x := 0.0
		var n := 0
		var lean := 0.0
		for i in 120:
			await get_tree().physics_frame
			h.position += Vector3(0, 0, -8) * TICK
			if i < 40:
				continue
			for b in [Bones.L_FOOT, Bones.R_FOOT]:
				var p := AnimTestUtil.local_pos(h, b)
				if p.y < 0.5:
					foot_x += p.x * sgn
					n += 1
			lean += (AnimTestUtil.local_pos(h, Bones.HEAD).x - AnimTestUtil.local_pos(h, Bones.HIPS).x) * -sgn
		foot_x /= maxf(n, 1)
		lean /= 80.0
		_check("%s: feet on the wall side, body rolled away from it" % wall, foot_x > 0.2 and lean > 0.1,
			"low feet %.2f m toward the wall, head %.2f m away from it" % [foot_x, lean])
	h.anim.set_locomotion_style(&"crawl")
	h.anim.set_locomotion(Vector3(0, 0, -0.8), 3.2)
	await _frames(90)
	var hips_y := AnimTestUtil.local_pos(h, Bones.HIPS).y
	var head := AnimTestUtil.local_pos(h, Bones.HEAD)
	_check("crawl: on the floor, head forward and up", hips_y < 0.3 and head.z < -0.3 and head.y > hips_y,
		"hips %.2f m, head (y %.2f, z %.2f)" % [hips_y, head.y, head.z])
	h.anim.set_locomotion_style(&"walk")
	h.anim.set_locomotion(Vector3(0, 0, -1.2), 3.2)
	await _frames(60)
	var walk_head := AnimTestUtil.local_pos(h, Bones.HEAD).y
	h.anim.set_locomotion_style(&"limp")
	await _frames(60)
	var limp_head := AnimTestUtil.local_pos(h, Bones.HEAD).y
	var clutch := h.rig.get_fist_position(Bones.R_HAND).distance_to(h.rig.get_bone_global_position(Bones.L_UPPER_ARM))
	_check("limp: hunched, right hand clutching the left shoulder", walk_head - limp_head > 0.08 and clutch < 0.2,
		"head %.2f m lower, hand %.2f m from the shoulder" % [walk_head - limp_head, clutch])
	h.anim.set_locomotion(Vector3.ZERO, 3.2)
	h.anim.set_locomotion_style(&"walk")
	await _frames(30)
	# --- The walk style picks sprint / strafe / wall run by itself ------------------
	var picks := {}
	for c in [[Vector3(0, 0, -4.5), &"walk"], [Vector3(0.9, 0, -0.9), &"walk"], [Vector3(0, 0, -8.0), &"sprint"],
			[Vector3(1.2, 0, 0), &"strafe"], [Vector3(0, 0, -8.0), &"wall_run_l"], [Vector3(0, 0, -8.0), &"wall_run_r"]]:
		var ft := AnimTestUtil.FakeTraversal.new()
		ft.side = -1 if c[1] == &"wall_run_l" else (1 if c[1] == &"wall_run_r" else 0)
		h.traversal = ft
		h.anim.set_locomotion(c[0], 8.0)
		await _frames(40)
		picks["%s %s" % [c[0], c[1]]] = h.anim.get_effective_style()
		_check("walk style at (%.1f, %.1f) m/s plays %s" % [c[0].x, c[0].z, c[1]],
			h.anim.get_effective_style() == c[1] and h.anim.get_locomotion_style() == &"walk", str(h.anim.get_effective_style()))
	h.traversal = null
	h.anim.set_locomotion_style(&"crawl")
	h.anim.set_locomotion(Vector3(0, 0, -8.0), 8.0)
	await _frames(10)
	_check("an explicit style wins over the auto pick", h.anim.get_effective_style() == &"crawl")
	h.anim.set_locomotion_style(&"walk")
	h.anim.set_locomotion(Vector3.ZERO, 8.0)
	await _frames(30)
	# --- Overlay keeps the legs' locomotion ---------------------------------------
	var a := AnimTestUtil.make_host(self, &"player", Vector3(3, 0, 0))
	var b := AnimTestUtil.make_host(self, &"player", Vector3(6, 0, 0))
	await _frames(2)
	for x in [a, b]:
		x.anim.set_locomotion_style(&"sprint")
	b.anim.set_upper_overlay(&"carry_hold")
	var leg_diff := 0.0
	var arm_diff := 0.0
	for i in 150:
		await get_tree().physics_frame
		for x in [a, b]:
			x.anim.set_locomotion(Vector3(0, 0, -7), 8.0)
		if i > 40:
			leg_diff = maxf(leg_diff, AnimTestUtil.max_diff(a.anim.pose_rot, b.anim.pose_rot, 10, 16))
			arm_diff = maxf(arm_diff, AnimTestUtil.angle_deg(a.anim.pose_rot[7], b.anim.pose_rot[7]))
	var rf := b.rig.get_fist_position(Bones.R_HAND) - b.global_position
	_check("carry_hold overlay: legs identical to the plain sprint, right arm holds", leg_diff < 0.01 and arm_diff > 20.0,
		"legs differ %.4f deg, right arm %.0f deg, hold hand at (%.2f, %.2f, %.2f)" % [leg_diff, arm_diff, rf.x, rf.y, rf.z])
	b.anim.set_upper_overlay(&"")
	await _frames(40)
	_check("clearing the overlay returns the arm to the cycle", AnimTestUtil.angle_deg(a.anim.pose_rot[7], b.anim.pose_rot[7]) < 0.5)
	# Carry style shows carry_hold by itself.
	b.anim.set_locomotion_style(&"carry")
	await _frames(40)
	var carry_arm := AnimTestUtil.angle_deg(b.anim.pose_rot[7], (PoseLibrary.get_pose(&"carry_hold").rot[7] as Quaternion))
	_check("carry style holds the body with carry_hold", carry_arm < 1.0, "%.2f deg from carry_hold" % carry_arm)
	b.anim.set_locomotion_style(&"sprint")
	await _frames(40)
	# --- Upper-body strikes and charge holds keep the legs running -------------------
	var worst_leg := 0.0
	var arm_moved := 0.0
	for c in [[&"move", &"jab"], [&"move", &"cross"], [&"hold", &"cross_charge"], [&"hold", &"jab_charge"]]:
		var p0: Quaternion = b.anim.pose_rot[4]
		if c[0] == &"move":
			b.anim.play_move(c[1], Tuning.frames(5), Tuning.frames(3), Tuning.frames(10))
		else:
			b.anim.hold_pose(c[1])
			b.anim.set_charge_level(2)
		var d := 0.0
		for i in 40:
			await get_tree().physics_frame
			for x in [a, b]:
				x.anim.set_locomotion(Vector3(0, 0, -7), 8.0)
			# The feet stay on the cycle's targets (the strike only bends the upper body).
			for bone in [Bones.L_FOOT, Bones.R_FOOT]:
				var pa := AnimTestUtil.local_pos(a, bone)
				var pb := AnimTestUtil.local_pos(b, bone)
				d = maxf(d, pa.distance_to(pb))
			arm_moved = maxf(arm_moved, AnimTestUtil.angle_deg(p0, b.anim.pose_rot[4]) + AnimTestUtil.angle_deg(a.anim.pose_rot[7], b.anim.pose_rot[7]))
		print("    %-14s at 7 m/s: feet differ from the plain sprint by %.4f m" % [c[1], d])
		worst_leg = maxf(worst_leg, d)
		b.anim.release_pose(0.05)
		await _frames(30)
	_check("jab / cross / charge holds at a sprint: feet keep the cycle (2 cm)", worst_leg < 0.02 and arm_moved > 20.0,
		"worst foot offset %.4f m" % worst_leg)
	# Standing still the same jab plants its own footwork.
	a.anim.set_locomotion(Vector3.ZERO, 8.0)
	await _frames(60)
	var lf0 := AnimTestUtil.local_pos(a, Bones.L_FOOT)
	a.anim.play_move(&"jab", Tuning.frames(5), Tuning.frames(3), Tuning.frames(10))
	await _frames(10)
	var lf1 := AnimTestUtil.local_pos(a, Bones.L_FOOT)
	_check("standing jab steps the lead foot in", lf0.z - lf1.z > 0.06, "%.2f m" % (lf0.z - lf1.z))
	await _frames(40)
	# --- Stumble steps ---------------------------------------------------------------
	for c in [[&"stumble_back", Vector3.ZERO], [&"stumble_back", Vector3(0, 0, 1.4)], [&"stumble_side_l", Vector3(-1.2, 0, 0)],
			[&"stumble_fwd", Vector3(0, 0, -1.2)]]:
		var vel: Vector3 = c[1]
		a.anim.set_locomotion(vel, 4.5)
		await _frames(2)
		a.anim.play_timed(c[0], 0.6)
		var lifts := 0
		var up := [false, false]
		var slides: Array[float] = []
		var prev := [AnimTestUtil.local_pos(a, Bones.L_FOOT), AnimTestUtil.local_pos(a, Bones.R_FOOT)]
		var prev_w := [a.rig.get_bone_global_position(Bones.L_FOOT), a.rig.get_bone_global_position(Bones.R_FOOT)]
		for i in 72:
			await get_tree().physics_frame
			a.position += vel * TICK
			for s in 2:
				var bone := Bones.L_FOOT if s == 0 else Bones.R_FOOT
				var p := AnimTestUtil.local_pos(a, bone)
				var w := a.rig.get_bone_global_position(bone)
				if p.y > 0.13 and not up[s]:
					lifts += 1
					up[s] = true
				elif p.y < 0.1:
					up[s] = false
					if (prev[s] as Vector3).y < 0.1:
						slides.append(Vector2(w.x - prev_w[s].x, w.z - prev_w[s].z).length() / TICK)
				prev[s] = p
				prev_w[s] = w
		slides.sort()
		var med: float = slides[int(slides.size() / 2.0)] if not slides.is_empty() else 0.0
		_check("%s at %.1f m/s: %d quick steps, planted feet hold" % [c[0], vel.length(), lifts],
			lifts >= 2 and lifts <= 5 and med <= maxf(0.25, 0.25 * vel.length()), "median planted slide %.2f m/s" % med)
		a.anim.set_locomotion(Vector3.ZERO, 4.5)
		await _frames(40)
	print("ANIM_LOCOMOTION ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

## Move the host at `v` (character space = world here) for `secs`; returns the
## median world speed of `bone` while it is planted (low and nearly still in
## the body frame's sense: on the ground), and steps per second.
func _run(h: AnimTestUtil.AnimHost, v: Vector3, secs: float, bone: StringName) -> Dictionary:
	h.anim.set_locomotion(v, 8.0)
	for i in 60:
		await get_tree().physics_frame
		h.position += v * TICK
	var prev := h.rig.get_bone_global_position(bone)
	var slides: Array[float] = []
	var ph0 := h.anim.get_locomotion_phase()
	var turns := 0.0
	var last_ph := ph0
	var floor_y := 0.13 if bone != Bones.L_HAND else 0.16
	for i in int(secs * 120.0):
		await get_tree().physics_frame
		h.position += v * TICK
		var p := h.rig.get_bone_global_position(bone)
		var ph := h.anim.get_locomotion_phase()
		turns += fposmod(ph - last_ph, TAU)
		last_ph = ph
		if p.y < floor_y and prev.y < floor_y:
			slides.append(Vector2(p.x - prev.x, p.z - prev.z).length() / TICK)
		prev = p
	slides.sort()
	var med: float = slides[int(slides.size() / 2.0)] if not slides.is_empty() else INF
	return {"slide": med, "planted": slides.size(), "steps": turns / TAU * 2.0 / secs}
