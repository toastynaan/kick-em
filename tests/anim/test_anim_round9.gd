extends Node3D
## Round 9 poses (docs/Round 9 — Playtest Fixes.md section 3; agent P), light:
## axe_kick and air_axe exist with strike bones, the axe kick charges on the
## leg-kick load, every pose they use compiles inside the joint limits and the
## live output stays inside them. Prints the heel's highest point and the
## contact position (first active frame) for the tap, the release from a
## full charge load, and the air version. Character space, metres.
## OWNER: agent P.

const RUNTIME_TOL := 3.0
const IDS: Array[StringName] = [&"axe_kick", &"air_axe"]

var _ok := true

func _check(what: String, cond: bool, info := "") -> void:
	print("  %-66s %s %s" % [what, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("ANIM_ROUND9 FAIL (timeout)")
		get_tree().quit(1))
	var missing: Array = []
	for id in IDS:
		if not PoseLibrary.has_move(id):
			missing.append("move " + String(id))
		if PoseLibrary.STRIKE_BONES.get(id, []) != [&"RightFoot", &"RightLowerLeg"]:
			missing.append("bones " + String(id))
	if PoseLibrary.charge_load_of(&"axe_kick") != &"heavy_leg_kick_load":
		missing.append("charge_load_of(axe_kick)")
	_check("axe_kick / air_axe: moves, strike bones, leg-kick load", missing.is_empty(), str(missing))
	var worst := 0.0
	var at := ""
	for id in IDS:
		for k in PoseLibrary.MOVES.get(id, {"keys": []})["keys"]:
			var r := AnimTestUtil.worst_excess(PoseLibrary.get_pose(k[2]).rot)
			if float(r[0]) > worst:
				worst = r[0]
				at = "%s %s" % [k[2], r[1]]
	_check("their poses compile inside the joint limits", worst <= AnimTestUtil.LIMIT_TOL, "worst %.2f deg %s" % [worst, at])
	var h := AnimTestUtil.make_host(self)
	for i in 30:
		await get_tree().physics_frame
	var hs := h.rig.height_scale
	var head := _head_top(h)
	print("    height scale %.2f, standing head top y %.2f" % [hs, head.y])
	var rt := {"worst": 0.0, "at": ""}
	var f: Vector3 = Tuning.R9_AXE["tap"]["f"]
	var tap := await _run(h, &"axe_kick", f, rt, "tap")
	h.anim.hold_pose(&"heavy_leg_kick_load")
	h.anim.set_charge_amount(1.0)
	for i in 40:
		await get_tree().physics_frame
	var held := h.anim.is_charge_load_held()
	var chg := await _run(h, &"axe_kick", f, rt, "from charge load")
	await _run(h, &"air_axe", Tuning.R9_AXE["air_frames"], rt, "air")
	_check("tap: heel apex above the standing head top, contact in front at 1.1-1.7 m",
		tap[0].y > head.y - 0.02 and tap[1].y > 1.1 * hs and tap[1].y < 1.7 * hs and tap[1].z < -0.4 * hs,
		"apex %.2f, contact %s" % [tap[0].y, _v(tap[1])])
	_check("released from the load: the leg still rises (apex within 10 cm of the tap)",
		held and chg[0].y > tap[0].y - 0.10, "load held %s, apex %.2f" % [held, chg[0].y])
	_check("live output inside the limits (+%.0f deg)" % RUNTIME_TOL, float(rt["worst"]) <= RUNTIME_TOL,
		"worst %.2f deg at %s" % [rt["worst"], rt["at"]])
	print("ANIM_ROUND9 ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

## Plays `id` on frames `f`; returns [heel apex, heel at the first active frame].
func _run(h: AnimTestUtil.AnimHost, id: StringName, f: Vector3, rt: Dictionary, label: String) -> Array:
	var st := Tuning.frames(f.x)
	h.anim.play_move(id, st, Tuning.frames(f.y), Tuning.frames(f.z))
	var n_contact := roundi(st * 120.0)
	var n := roundi((st + Tuning.frames(f.y) + Tuning.frames(f.z)) * 120.0) + 10
	var apex := Vector3(0, -INF, 0)
	var apex_t := 0
	var contact := Vector3.ZERO
	var ankle := Vector3.ZERO
	for i in n:
		await get_tree().physics_frame
		var heel := _heel(h)
		if heel.y > apex.y:
			apex = heel
			apex_t = i + 1
		if i + 1 == n_contact:
			contact = heel
			ankle = AnimTestUtil.local_pos(h, Bones.R_FOOT)
		var r := AnimTestUtil.worst_excess(h.anim.pose_rot)
		if float(r[0]) > float(rt["worst"]):
			rt["worst"] = r[0]
			rt["at"] = "%s %s (%s)" % [id, label, r[1]]
	print("    %-8s %-16s frames %s: heel apex %s at tick %d, contact (tick %d) heel %s, ankle %s" % [id, label, f,
		_v(apex), apex_t, n_contact, _v(contact), _v(ankle)])
	return [apex, contact]

func _heel(h: AnimTestUtil.AnimHost) -> Vector3:
	var xf := h.rig.get_bone_global_transform(Bones.R_FOOT)
	return h.global_transform.affine_inverse() * (xf.origin + xf.basis.orthonormalized() * PoseLibrary.SOLE_HEEL * h.rig.height_scale)

func _head_top(h: AnimTestUtil.AnimHost) -> Vector3:
	var xf := h.rig.get_bone_global_transform(Bones.HEAD)
	return h.global_transform.affine_inverse() * (xf.origin + xf.basis.orthonormalized() * Vector3(0, 0.26, 0) * h.rig.height_scale)

static func _v(v: Vector3) -> String:
	return "(%5.2f %5.2f %5.2f)" % [v.x, v.y, v.z]
