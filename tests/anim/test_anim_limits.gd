extends Node3D
## Every keyframe sits inside HumanoidRig.JOINT_LIMITS (the ragdoll's soft
## ranges, measured exactly as RagdollController does: hinge X, cone swing
## X / Z and twist), so the ragdoll blend never pulls against a pose. Then
## the animator's live output is sampled every tick through every move, hold
## (charge level 3) and locomotion style, and fists / ankles of the strike
## contact poses are checked to land on their IK targets.
## OWNER: agent P.

## Runtime output (blends, tremble at charge level 3, procedural cycles) may
## pass a soft range by at most this many degrees.
const RUNTIME_TOL := 3.0

var _ok := true

func _check(what: String, cond: bool, info := "") -> void:
	print("  %-58s %s %s" % [what, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _ready() -> void:
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		print("ANIM_LIMITS FAIL (timeout)")
		get_tree().quit(1))
	# --- 1. Static: every compiled pose (and every mirrored one a move uses). ---
	var names: Array = PoseLibrary.POSES.keys()
	for id in PoseLibrary.MOVES:
		for k in PoseLibrary.MOVES[id]["keys"]:
			if String(k[2]).ends_with("#m") and not names.has(k[2]):
				names.append(k[2])
	var worst := 0.0
	var worst_at := ""
	var bad: Array = []
	for pn in names:
		var p := PoseLibrary.get_pose(pn)
		var r := AnimTestUtil.worst_excess(p.rot)
		if float(r[0]) > worst:
			worst = r[0]
			worst_at = "%s %s" % [pn, r[1]]
		if float(r[0]) > AnimTestUtil.LIMIT_TOL:
			bad.append("%s %s %.1f" % [pn, r[1], r[0]])
	_check("all %d keyframe poses inside the joint limits" % names.size(), bad.is_empty(),
		"worst %.2f deg (%s) %s" % [worst, worst_at, str(bad) if not bad.is_empty() else ""])
	# --- 2. Contact poses reach their targets (the limits did not bend them away). ---
	var miss_bad: Array = []
	var worst_miss := 0.0
	for id in PoseLibrary.ROUND5_MOVE_IDS:
		if not PoseLibrary.STRIKE_BONES.has(id):
			continue
		var pname := _contact_pose(id)
		var d: Dictionary = PoseLibrary.POSES.get(pname, {})
		for b in PoseLibrary.STRIKE_BONES[id]:
			var key: String = PoseLibrary.AIM_LIMB.get(b, "")
			if key == "" or not d.has(key):
				continue
			var miss := _ik_miss(pname, key)
			worst_miss = maxf(worst_miss, miss)
			print("    %-16s %-10s contact %-16s target miss %.3f m" % [id, b, pname, miss])
			if miss > 0.06:
				miss_bad.append("%s %.2f" % [id, miss])
	_check("strike limbs reach their contact targets (<= 6 cm)", miss_bad.is_empty(), "worst %.3f m %s" % [worst_miss, str(miss_bad)])
	# --- 3. Runtime: sample the animator's output every tick. ---
	var h := AnimTestUtil.make_host(self)
	for i in 4:
		await get_tree().physics_frame
	var rt := {"worst": 0.0, "at": ""}
	var ids := PoseLibrary.all_move_ids()
	for id in ids:
		if id in [&"getup_face_up", &"getup_face_down", &"getup_fast", &"getup_fast_down"]:
			h.anim.play_timed(id, 0.6)
		elif String(id).begins_with("e_"):
			h.anim.play_move(id, 0.4, 0.07, 0.3)
		else:
			h.anim.play_move(id, 0.15, 0.07, 0.25)
		await _sample(h, 0.6, rt, String(id))
	for id in PoseLibrary.HOLDS:
		h.anim.hold_pose(id)
		if PoseLibrary.HOLDS[id].get("charge", false):
			h.anim.set_charge_level(3)
		await _sample(h, 0.35, rt, "hold " + String(id))
		h.anim.release_pose(0.05)
	await _sample(h, 0.2, rt, "release")
	for st in PoseAnimator.STYLES:
		h.anim.set_locomotion_style(st)
		for v in [0.0, 1.0, 3.0, 4.5, 6.0, 8.0, 10.0, 12.0]:   # walk .. the upgraded sprint caps
			var vel := Vector3(0, 0, -v) if st != &"strafe" else Vector3(v * 0.4, 0, 0)
			h.anim.set_locomotion(vel, 8.0)
			await _sample(h, 0.5, rt, "%s %.0f m/s" % [st, v])
	h.anim.set_locomotion_style(&"sprint")
	h.anim.set_upper_overlay(&"carry_hold")
	h.anim.set_locomotion(Vector3(0, 0, -6), 8.0)
	await _sample(h, 0.5, rt, "carry overlay sprint")
	_check("live output inside the limits (+%.0f deg) through every move, hold, style" % RUNTIME_TOL,
		float(rt["worst"]) <= RUNTIME_TOL, "worst %.2f deg at %s" % [rt["worst"], rt["at"]])
	print("ANIM_LIMITS ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _sample(h: AnimTestUtil.AnimHost, secs: float, rt: Dictionary, label: String) -> void:
	var local := 0.0
	var lb: StringName = &""
	for i in int(secs * 120.0):
		await get_tree().physics_frame
		var r := AnimTestUtil.worst_excess(h.anim.pose_rot)
		if float(r[0]) > local:
			local = r[0]
			lb = r[1]
		if float(r[0]) > float(rt["worst"]):
			rt["worst"] = r[0]
			rt["at"] = "%s (%s)" % [label, r[1]]
	if local > RUNTIME_TOL:
		print("    over the limits: %-28s %5.1f deg (%s)" % [label, local, lb])

## Pose of the move's first active key.
func _contact_pose(id: StringName) -> StringName:
	for k in PoseLibrary.MOVES[id]["keys"]:
		if int(k[0]) == 1:
			return StringName(String(k[2]).trim_suffix("#m"))
	return &""

## Distance from an IK target of a pose to where the compiled pose puts it.
func _ik_miss(pname: StringName, key: String) -> float:
	var d: Dictionary = PoseLibrary.POSES[pname]
	var p := PoseLibrary.get_pose(pname)
	var rots: Array = []
	for i in HumanoidRig.BONE_COUNT:
		rots.append(p.rot[i] if p.rot[i] != null else Quaternion.IDENTITY)
	var xf := PoseLibrary.fk(rots, p.pos)
	var body: bool = d.get("frame", &"char") == &"body"
	var yaw := Basis(Vector3.UP, p.hips_yaw) if body else Basis()
	var org := Vector3(p.pos.x, 0, p.pos.z) if body else Vector3.ZERO
	var t: Vector3 = org + yaw * (d[key] as Vector3)
	var got: Vector3
	match key:
		"lfist": got = xf[HumanoidRig.bone_index(Bones.L_HAND)] * HumanoidRig.FIST_OFFSET
		"rfist": got = xf[HumanoidRig.bone_index(Bones.R_HAND)] * HumanoidRig.FIST_OFFSET
		"lankle": got = xf[HumanoidRig.bone_index(Bones.L_FOOT)].origin
		_: got = xf[HumanoidRig.bone_index(Bones.R_FOOT)].origin
	return got.distance_to(t)
