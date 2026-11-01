extends Node3D
## Round 2 animation checks: punt reach; set_aim_target bends strikes toward
## a lower/taller/sideways target within limits and clear_aim_target undoes
## it; enemy tells build 60% -> 100% then freeze ~2 frames before the snap;
## follow-through overshoot on power_punch / sparta_kick; the dodge reads as a
## clear sidestep; a long-startup back_kick (AI counter) turns away early.

var _ok := true
var d: LabDummy

func _check(what: String, cond: bool, info := "") -> void:
	print("  %-46s %s %s" % [what, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

## Play `id` and return the position of `bone` (fist centre for hands) at the
## first active frame.
func _strike(id: StringName, startup: float, bone: StringName) -> Vector3:
	d.animator.play_move(id, startup, 0.1, 0.25)
	await _frames(int(roundf(startup * 120.0)) + 2)
	var p := d.rig.get_fist_position(bone) if bone in [Bones.L_HAND, Bones.R_HAND] else d.rig.get_bone_global_position(bone)
	await _frames(50)
	return p

func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("ROUND2_POSES FAIL (timeout)")
		get_tree().quit(1))
	RigTestUtil.make_floor(self)
	d = RigTestUtil.make_dummy(self, &"player", Vector3.ZERO, null, true)
	await _frames(6)
	var hips_z := d.rig.get_bone_global_position(Bones.HIPS).z
	_check("has_move punt / unknown", PoseLibrary.has_move(&"punt") and not PoseLibrary.has_move(&"nope"))
	_check("punt in STRIKE_BONES", PoseLibrary.STRIKE_BONES.get(&"punt", [])[0] == Bones.R_FOOT)

	# Punt (9 frames startup at 60 fps).
	var pf := await _strike(&"punt", 9.0 / 60.0, Bones.R_FOOT)
	_check("punt foot ~0.8 m ahead, ~0.25 m up", hips_z - pf.z > 0.65 and hips_z - pf.z < 0.95 and pf.y > 0.12 and pf.y < 0.4,
		"fwd %.2f up %.2f" % [hips_z - pf.z, pf.y])

	# Aim.
	var base := await _strike(&"jab2", 5.0 / 60.0, Bones.R_HAND)
	d.animator.set_aim_target(Vector3(0.0, base.y - 0.3, -0.9))
	var low := await _strike(&"jab2", 5.0 / 60.0, Bones.R_HAND)
	_check("aim low: fist drops ~0.3 m", base.y - low.y > 0.18 and base.y - low.y < 0.36, "%.2f" % (base.y - low.y))
	d.animator.set_aim_target(Vector3(0.0, base.y + 0.6, -0.9))
	var high := await _strike(&"jab2", 5.0 / 60.0, Bones.R_HAND)
	_check("aim high: clamped to ~+0.3 m", high.y - base.y > 0.15 and high.y - base.y < 0.36, "%.2f" % (high.y - base.y))
	var ang0 := atan2(base.x, -base.z)
	d.animator.set_aim_target(Vector3(sin(deg_to_rad(18.0)), base.y, -cos(deg_to_rad(18.0))) * 0.9 + Vector3(0, base.y * 0.1, 0))
	var side := await _strike(&"jab2", 5.0 / 60.0, Bones.R_HAND)
	var dang := rad_to_deg(atan2(side.x, -side.z) - ang0)
	_check("aim 18 deg right: fist turns toward it", dang > 10.0 and dang < 26.0, "%.1f deg" % dang)
	d.animator.set_aim_target(Vector3(2.0, base.y, -0.5))
	var wide := await _strike(&"jab2", 5.0 / 60.0, Bones.R_HAND)
	var dwide := rad_to_deg(atan2(wide.x, -wide.z) - ang0)
	_check("aim 76 deg right: clamped to ~25 deg", dwide > 15.0 and dwide < 30.0, "%.1f deg" % dwide)
	d.animator.clear_aim_target()
	var back := await _strike(&"jab2", 5.0 / 60.0, Bones.R_HAND)
	_check("clear_aim_target restores the strike", back.distance_to(base) < 0.02, "%.3f m" % back.distance_to(base))
	var kick := await _strike(&"sparta_kick", 12.0 / 60.0, Bones.R_FOOT)
	d.animator.set_aim_target(Vector3(0.0, kick.y - 0.3, -0.9))
	var kick_low := await _strike(&"sparta_kick", 12.0 / 60.0, Bones.R_FOOT)
	d.animator.clear_aim_target()
	_check("aim works on kicks", kick.y - kick_low.y > 0.15, "%.2f" % (kick.y - kick_low.y))

	# Enemy tell builds, sets, snaps (startup = tell 0.45 s).
	var s0 := d.rig.get_fist_position(Bones.R_HAND)
	d.animator.play_move(&"e_hook", 0.45, 0.07, 0.3)
	var samples: Array[Vector3] = []
	for i in int(0.45 * 120.0):
		await get_tree().physics_frame
		samples.append(d.rig.get_fist_position(Bones.R_HAND))
	await _frames(60)
	var full := samples[int(0.34 * 120.0)].distance_to(s0)
	var early := samples[int(0.10 * 120.0)].distance_to(s0)
	var mid := samples[int(0.22 * 120.0)].distance_to(s0)
	_check("tell starts at ~60% of the windup", early > full * 0.45 and early < full * 0.85, "%.0f%%" % (early / full * 100.0))
	_check("tell deepens over the tell", mid > early + 0.02 and full > mid + 0.02, "%.2f %.2f %.2f m" % [early, mid, full])
	var set_move := 0.0
	# Key times for a 0.45 s tell: 100% at 0.347 s, set until 0.380 s.
	# samples[i] shows t = (i + 1) / 120.
	for i in range(42, 44):
		set_move = maxf(set_move, samples[i + 1].distance_to(samples[i]))
	_check("~2 frame set freeze before the strike", set_move < 0.004, "max %.4f m/tick" % set_move)
	var snap := samples[samples.size() - 1].distance_to(samples[int(0.38 * 120.0)])
	_check("snap to the strike in the last frames", snap > 0.3, "%.2f m" % snap)

	# Follow-through overshoot.
	for pair in [[&"power_punch", Bones.R_HAND, 14.0 / 60.0], [&"sparta_kick", Bones.R_FOOT, 12.0 / 60.0]]:
		var id: StringName = pair[0]
		var bone: StringName = pair[1]
		var st: float = pair[2]
		d.animator.play_move(id, st, 4.0 / 60.0, 0.4)
		await _frames(int(roundf((st + 4.0 / 60.0) * 120.0)))
		var at_end := d.rig.get_bone_global_position(bone)
		var best := at_end.z
		for i in 12:
			await get_tree().physics_frame
			best = minf(best, d.rig.get_bone_global_position(bone).z)
		await _frames(60)
		_check("%s follow-through overshoots" % id, at_end.z - best > 0.03, "%.2f m" % (at_end.z - best))

	# Dodge reads as a sidestep (B plays it with startup 0, active 0.25).
	var c0 := d.rig.get_bone_global_position(Bones.CHEST)
	var h0 := d.rig.get_bone_global_position(Bones.HEAD)
	d.animator.play_move(&"dodge", 0.0, 0.25, 0.1)
	await _frames(14)
	var dc := d.rig.get_bone_global_position(Bones.CHEST) - c0
	var dh := d.rig.get_bone_global_position(Bones.HEAD) - h0
	await _frames(60)
	_check("dodge leans the upper body >= 0.3 m aside", absf(dh.x) > 0.3 and absf(dc.x) > 0.2, "head %.2f chest %.2f m" % [dh.x, dc.x])

	# AI counter back_kick: long startup, turns away early, holds a set.
	d.animator.play_move(&"back_kick", 0.4, 0.07, 0.3)
	await _frames(int(0.15 * 120.0))
	var away := -d.rig.get_bone_global_transform(Bones.HIPS).basis.z
	await _frames(int(0.25 * 120.0) + 2)
	var heel := d.rig.get_bone_global_position(Bones.R_FOOT)
	await _frames(80)
	_check("counter back_kick turns its back early", away.z > 0.5, "hips forward z %.2f" % away.z)
	_check("counter back_kick heel drives forward", hips_z - heel.z > 0.7 and heel.y > 0.7, "fwd %.2f up %.2f" % [hips_z - heel.z, heel.y])
	print("ROUND2_POSES ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)
