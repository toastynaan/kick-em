extends Node3D
## Round 8 poses (docs/Round 8 — Charge and Pressure.md; agent P):
## - every Round 8 id exists (moves, holds, charge loads, STRIKE_BONES) and
##   every pose they use compiles inside the joint limits;
## - set_charge_amount at c = 0, 0.5 and 1 gives a monotonically deeper load
##   for all 8 chargeable strikes: hips / chest twist and the fist or foot
##   pulled back (printed); a slight tremble at full only; a jump in c moves
##   the pose smoothly (no pop); a strike released from the load goes
##   straight to contact (no un-load first);
## - react_flinch lands at once and is gone by the end of a tap's stun;
##   react_sweep tips back with the legs out; react_broken drops the guard,
##   lolls the head and sways; react_fold over 0.3 s is a half-keel that is
##   back up by the end;
## - air strikes on R8_AIR_FRAMES: contact positions printed, the limb out in
##   front, the legs tucked; air_follow reads as a rising leap;
## - the live output stays inside the limits (+RUNTIME_TOL) throughout.
## Measured standing still, no aim target.
## OWNER: agent P.

const TICK := 1.0 / 120.0
const RUNTIME_TOL := 3.0

## The ids the Round 8 doc and brief ask for (independent of the library's lists).
const MOVES_NEEDED: Array[StringName] = [&"react_flinch", &"react_sweep", &"react_broken", &"air_jab", &"air_cross",
	&"air_kick", &"air_follow", &"react_fold"]
const HOLDS_NEEDED: Array[StringName] = [&"react_flinch", &"react_sweep", &"react_broken", &"air_follow"]
## Chargeable strike -> [its load hold, strike limb sample key].
const LOADS := {
	&"jab": [&"heavy_jab_load", "lfist"], &"cross": [&"heavy_cross_load", "rfist"],
	&"hook": [&"heavy_hook_load", "lfist"], &"leg_kick": [&"heavy_leg_kick_load", "rankle"],
	&"front_kick": [&"heavy_front_kick_load", "rankle"], &"roundhouse": [&"heavy_roundhouse_load", "rankle"],
	&"gut_punch": [&"gut_punch_load", "rfist"], &"uppercut": [&"uppercut_load", "rfist"]}
const AIR_LIMBS := {&"air_jab": [&"LeftHand"], &"air_cross": [&"RightHand"], &"air_kick": [&"RightFoot", &"RightLowerLeg"]}

var _ok := true

func _check(what: String, cond: bool, info := "") -> void:
	print("  %-66s %s %s" % [what, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _ready() -> void:
	get_tree().create_timer(200.0).timeout.connect(func() -> void:
		print("ANIM_ROUND8 FAIL (timeout)")
		get_tree().quit(1))
	_check_ids()
	_check_static_limits()
	var h := AnimTestUtil.make_host(self)
	await _frames(30)
	var stance := _sample(h)
	print("    stance: head %s  hips %s  lfist %s  rfist %s  rankle %s  hips yaw %.1f  chest yaw %.1f" % [
		_v(stance["head"]), _v(stance["hips"]), _v(stance["lfist"]), _v(stance["rfist"]), _v(stance["rankle"]),
		stance["hips_yaw"], stance["chest_yaw"]])
	var rt := {"worst": 0.0, "at": ""}
	await _check_charge(h, stance, rt)
	await _check_reactions(h, stance, rt)
	await _check_air(h, stance, rt)
	_check("live output inside the limits (+%.0f deg) through every Round 8 pose" % RUNTIME_TOL,
		float(rt["worst"]) <= RUNTIME_TOL, "worst %.2f deg at %s" % [rt["worst"], rt["at"]])
	print("ANIM_ROUND8 ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

# --- Ids and static limits ------------------------------------------------------
func _check_ids() -> void:
	var missing: Array = []
	for id in MOVES_NEEDED:
		if not PoseLibrary.has_move(id):
			missing.append("move " + String(id))
	for id in HOLDS_NEEDED:
		if not PoseLibrary.HOLDS.has(id):
			missing.append("hold " + String(id))
	for mv in LOADS:
		var load: StringName = LOADS[mv][0]
		if not PoseLibrary.HOLDS.has(load) or not PoseLibrary.HOLDS[load].get("by_charge", false):
			missing.append("load " + String(load))
		if PoseLibrary.charge_load_of(mv) != load:
			missing.append("charge_load_of(%s) = %s" % [mv, PoseLibrary.charge_load_of(mv)])
	_check("all Round 8 moves, holds and the 8 charge loads exist", missing.is_empty(), str(missing))
	var listed := true
	for id in PoseLibrary.ROUND8_MOVE_IDS:
		listed = listed and PoseLibrary.has_move(id) and PoseLibrary.all_move_ids().has(id)
	for id in PoseLibrary.ROUND8_HOLD_IDS:
		listed = listed and PoseLibrary.HOLDS.has(id)
	for id in PoseLibrary.ROUND8_LOAD_IDS:
		listed = listed and PoseLibrary.ROUND8_HOLD_IDS.has(id)
	for id in MOVES_NEEDED:
		listed = listed and (PoseLibrary.ROUND8_MOVE_IDS.has(id) or PoseLibrary.ROUND7_MOVE_IDS.has(id))
	_check("ROUND8_MOVE_IDS / ROUND8_HOLD_IDS / ROUND8_LOAD_IDS list playable ids", listed)
	var bad: Array = []
	for id in AIR_LIMBS:
		if PoseLibrary.STRIKE_BONES.get(id, []) != AIR_LIMBS[id] or not PoseLibrary.ROUND8_AIR_IDS.has(id):
			bad.append(id)
		var has_contact := false
		for k in PoseLibrary.MOVES[id]["keys"]:
			if int(k[0]) == 1 and typeof(k[1]) == TYPE_FLOAT and float(k[1]) == 0.0:
				has_contact = true
		if not has_contact:
			bad.append("%s: no contact key" % id)
	_check("STRIKE_BONES: air strikes on their limbs, each with a contact key", bad.is_empty(), str(bad))

func _round8_pose_names() -> Array:
	var names: Array = []
	for id in PoseLibrary.ROUND8_MOVE_IDS:
		for k in PoseLibrary.MOVES[id]["keys"]:
			if not names.has(k[2]):
				names.append(k[2])
	for id in PoseLibrary.ROUND8_HOLD_IDS:
		for pn in PoseLibrary.HOLDS[id]["poses"]:
			if not names.has(pn):
				names.append(pn)
	return names

func _check_static_limits() -> void:
	var names := _round8_pose_names()
	var worst := 0.0
	var at := ""
	var bad: Array = []
	var missing: Array = []
	for pn in names:
		if not PoseLibrary.has_pose(pn):
			missing.append(pn)
			continue
		var r := AnimTestUtil.worst_excess(PoseLibrary.get_pose(pn).rot)
		if float(r[0]) > worst:
			worst = r[0]
			at = "%s %s" % [pn, r[1]]
		if float(r[0]) > AnimTestUtil.LIMIT_TOL:
			bad.append("%s %s %.1f" % [pn, r[1], r[0]])
	_check("every Round 8 key / hold names a pose", missing.is_empty(), str(missing))
	_check("all %d Round 8 poses compile inside the joint limits" % names.size(), bad.is_empty(),
		"worst %.2f deg (%s) %s" % [worst, at, str(bad) if not bad.is_empty() else ""])

# --- Charge loads -------------------------------------------------------------------
## Holds each load at c = 0, 0.5, 1 (fresh hold each time, settled), then
## measures the twist (hips + chest yaw away from the stance, toward the full
## load) and the strike limb's travel from the stance toward its full-load spot.
func _check_charge(h: AnimTestUtil.AnimHost, stance: Dictionary, rt: Dictionary) -> void:
	print("    charge loads (c = 0 / 0.5 / 1): twist = |hips yaw| + |chest yaw| change toward the full load (deg);")
	print("    pull = strike limb travel from the stance toward its full-load spot (m); hips z = weight back (m)")
	for mv in LOADS:
		var load: StringName = LOADS[mv][0]
		var limb: String = LOADS[mv][1]
		var s: Array = []
		for c in [0.0, 0.5, 1.0]:
			h.anim.hold_pose(load)
			h.anim.set_charge_amount(c)
			await _frames(50)
			_track_limits(h, rt, "%s c=%.1f" % [load, c])
			s.append(await _avg_sample(h, 6))
			h.anim.release_pose(0.0)
			await _frames(30)
		var full: Dictionary = s[2]
		var hy_dir := signf(float(full["hips_yaw"]) - float(stance["hips_yaw"]))
		var cy_dir := signf(float(full["chest_yaw"]) - float(stance["chest_yaw"]))
		var dir: Vector3 = (full[limb] as Vector3) - (stance[limb] as Vector3)
		var dlen := dir.length()
		dir = dir / maxf(dlen, 0.0001)
		var tw: Array[float] = []
		var pull: Array[float] = []
		for r: Dictionary in s:
			tw.append((float(r["hips_yaw"]) - float(stance["hips_yaw"])) * hy_dir
				+ (float(r["chest_yaw"]) - float(stance["chest_yaw"])) * cy_dir)
			pull.append(((r[limb] as Vector3) - (stance[limb] as Vector3)).dot(dir))
		print("    %-22s twist %5.1f / %5.1f / %5.1f   pull %4.2f / %4.2f / %4.2f   %s %s / %s / %s   hips z %5.2f / %5.2f / %5.2f   hips y %4.2f / %4.2f / %4.2f" % [
			load, tw[0], tw[1], tw[2], pull[0], pull[1], pull[2], limb, _v(s[0][limb]), _v(s[1][limb]), _v(s[2][limb]),
			s[0]["hips"].z, s[1]["hips"].z, s[2]["hips"].z, s[0]["hips"].y, s[1]["hips"].y, s[2]["hips"].y])
		var twist_ok := tw[0] < tw[1] - 1.0 and tw[1] < tw[2] - 1.0 if tw[2] >= 8.0 else true
		var pull_ok := pull[0] < pull[1] - 0.01 and pull[1] < pull[2] - 0.01
		var light_ok := pull[0] >= 0.15 * dlen and pull[0] <= 0.8 * dlen
		_check("%s: deeper with c (twist and pull rise 0 -> 0.5 -> 1)" % load, twist_ok and pull_ok,
			"twist %.0f/%.0f/%.0f, pull %.2f/%.2f/%.2f" % [tw[0], tw[1], tw[2], pull[0], pull[1], pull[2]])
		_check("%s: a light load at c = 0 (15-80%% of the full pull)" % load, light_ok, "%.0f%%" % (100.0 * pull[0] / maxf(dlen, 0.0001)))
		if mv == &"cross":
			var back_ok: bool = float(full["hips"].z) > float(stance["hips"].z) + 0.03 and float(s[0]["hips"].z) < float(full["hips"].z)
			_check("heavy_cross_load: weight back at full (hips +3 cm behind the stance)", back_ok,
				"hips z %.2f -> %.2f" % [stance["hips"].z, full["hips"].z])
	# Tremble: slight at full, (almost) none when light.
	var trem := []
	for c in [0.0, 1.0]:
		h.anim.hold_pose(&"heavy_cross_load")
		h.anim.set_charge_amount(c)
		await _frames(60)
		var prev: Quaternion = h.anim.pose_rot[HumanoidRig.bone_index(Bones.CHEST)]
		var dmax := 0.0
		for i in 40:
			await get_tree().physics_frame
			var q: Quaternion = h.anim.pose_rot[HumanoidRig.bone_index(Bones.CHEST)]
			dmax = maxf(dmax, AnimTestUtil.angle_deg(prev, q))
			prev = q
		trem.append(dmax)
		h.anim.release_pose(0.0)
		await _frames(20)
	_check("tremble: slight at full (0.5-4 deg/tick), much less light (< 40% of full)",
		trem[1] >= 0.5 and trem[1] <= 4.0 and trem[0] < trem[1] * 0.4, "light %.2f, full %.2f deg per tick" % [trem[0], trem[1]])
	# Smooth: c jumps 0 -> 1 and back; the fist never pops (per-tick travel small).
	h.anim.hold_pose(&"heavy_cross_load")
	h.anim.set_charge_amount(0.0)
	await _frames(40)
	var step_max := 0.0
	var prev_p: Vector3 = _sample(h)["rfist"]
	var travel := 0.0
	var p0 := prev_p
	h.anim.set_charge_amount(1.0)
	for i in 60:
		await get_tree().physics_frame
		var p: Vector3 = _sample(h)["rfist"]
		step_max = maxf(step_max, p.distance_to(prev_p))
		prev_p = p
	travel = p0.distance_to(prev_p)
	h.anim.set_charge_amount(0.0)
	for i in 60:
		await get_tree().physics_frame
		var p: Vector3 = _sample(h)["rfist"]
		step_max = maxf(step_max, p.distance_to(prev_p))
		prev_p = p
	_check("c jumps 0 -> 1 -> 0: no pop (fist <= 2.5 cm per tick, <= 20% of the travel)",
		step_max <= 0.025 and step_max <= travel * 0.2, "max %.3f m/tick, travel %.2f m" % [step_max, travel])
	# Release from a full load: straight to contact, no un-load on the way.
	h.anim.set_charge_amount(1.0)
	await _frames(60)
	var loaded: Vector3 = _sample(h)["rfist"]
	var st := Tuning.frames(Tuning.R8_RELEASE_STARTUP)
	var mf: Vector3 = Tuning.R8_MOVES[&"cross"]["tap"]["f"]
	h.anim.play_move(&"heavy_cross", st, Tuning.frames(mf.y), Tuning.frames(mf.z + Tuning.R8_CHARGED_EXTRA_RECOVERY))
	var back := 0.0
	var last_z := loaded.z
	var n := roundi(st * 120.0)
	for i in n:
		await get_tree().physics_frame
		_track_limits(h, rt, "heavy_cross from load")
		var z: float = _sample(h)["rfist"].z
		back = maxf(back, z - last_z)
		last_z = z
	var contact: Vector3 = _sample(h)["rfist"]
	_check("heavy_cross released from the full load: no un-load, contact on frame %d (z <= -0.55)" % n,
		back <= 0.01 and contact.z <= -0.55, "load %s -> contact %s, worst backward step %.3f m" % [_v(loaded), _v(contact), back])
	await _frames(60)
	# The other strikes released from their full loads (B's charged release:
	# R8_RELEASE_STARTUP, then the tap's active frames): contact printed; kicks
	# keep the standing foot on the floor and the kicking foot never digs in.
	var rel := {&"heavy_leg_kick": [&"heavy_leg_kick_load", &"leg_kick", "rankle"],
		&"heavy_front_kick": [&"heavy_front_kick_load", &"front_kick", "rankle"],
		&"heavy_roundhouse": [&"heavy_roundhouse_load", &"roundhouse", "rankle"],
		&"heavy_jab": [&"heavy_jab_load", &"jab", "lfist"], &"heavy_hook": [&"heavy_hook_load", &"hook", "lfist"],
		&"gut_punch": [&"gut_punch_load", &"gut_punch", "rfist"], &"uppercut": [&"uppercut_load", &"uppercut", "rfist"]}
	var low_bad: Array = []
	for mid: StringName in rel:
		var spec: Array = rel[mid]
		h.anim.hold_pose(spec[0])
		h.anim.set_charge_amount(1.0)
		await _frames(60)
		var tf: Vector3 = Tuning.R8_MOVES[spec[1]]["tap"]["f"]
		h.anim.play_move(mid, st, Tuning.frames(tf.y), Tuning.frames(tf.z + Tuning.R8_CHARGED_EXTRA_RECOVERY))
		var low := INF
		for i in n:
			await get_tree().physics_frame
			_track_limits(h, rt, "%s from load" % mid)
			var sm := _sample(h)
			low = minf(low, minf(float(sm["lankle"].y), float(sm["rankle"].y)))
		var cs := _sample(h)
		print("    %-16s from its full load, contact (frame %d): %s %s  lowest ankle y %.2f" % [mid, n, spec[2], _v(cs[spec[2]]), low])
		if low < 0.05:
			low_bad.append("%s %.2f" % [mid, low])
		await _frames(70)
	_check("strikes released from a load: no foot dips into the floor (ankle y >= 0.05)", low_bad.is_empty(), str(low_bad))

# --- Reactions -------------------------------------------------------------------------
func _check_reactions(h: AnimTestUtil.AnimHost, stance: Dictionary, rt: Dictionary) -> void:
	# Flinch over a tap's stun (0.2 s): in within 0.04 s, gone by the end.
	var stun: float = Tuning.R8_MOVES[&"jab"]["tap"]["stun"]
	h.anim.play_timed(&"react_flinch", stun)
	var land := await _time_to_pose(h, PoseLibrary.get_pose(&"react_flinch_a"), 0.2, rt, "react_flinch")
	var mid := _sample(h)
	_check("react_flinch (%.2f s): the wince lands within 0.04 s" % stun, land <= 0.04 + 0.0001, "%.3f s" % land)
	_check("react_flinch: head jerked back (tipped >= 8 deg more than the stance)",
		float(mid["head_pitch"]) >= float(stance["head_pitch"]) + 8.0, "head pitch %.0f (stance %.0f)" % [mid["head_pitch"], stance["head_pitch"]])
	await _frames(roundi((stun - land) * 120.0) + 2)
	var end := _sample(h)
	_check("react_flinch: back to the stance by the end of the stun (head < 3 cm)",
		(end["head"] as Vector3).distance_to(stance["head"]) < 0.03, "head %s" % _v(end["head"]))
	await _frames(30)
	# Quick half-keel: react_fold played over 0.3 s (a tapped gut punch).
	var full_fold := 0.0
	h.anim.play_timed(&"react_fold", 1.1)
	for i in 60:
		await get_tree().physics_frame
		full_fold = maxf(full_fold, float(stance["head"].y) - float(_sample(h)["head"].y))
	await _frames(120)
	var qstun: float = Tuning.R8_MOVES[&"gut_punch"]["tap"]["stun"]
	h.anim.play_timed(&"react_fold", qstun)
	var drops: Array[float] = []
	var nq := roundi(qstun * 120.0)
	for i in nq:
		await get_tree().physics_frame
		_track_limits(h, rt, "react_fold %.2f" % qstun)
		drops.append(float(stance["head"].y) - float(_sample(h)["head"].y))
	var drop: float = drops.max()
	var t_low := INF   # first time the head is 80% of the way down
	for i in drops.size():
		if drops[i] >= 0.8 * drop:
			t_low = (i + 1) * TICK
			break
	var qend := _sample(h)
	_check("react_fold over %.2f s: a half-keel (head drop 25-75%% of the full fold)" % qstun,
		drop >= 0.25 * full_fold and drop <= 0.75 * full_fold, "drop %.2f m at %.2f s (full fold %.2f m)" % [drop, t_low, full_fold])
	_check("react_fold over %.2f s: down within 0.08 s, back up by the end (head < 3 cm)" % qstun,
		t_low <= 0.08 and (qend["head"] as Vector3).distance_to(stance["head"]) < 0.03, "end head %s" % _v(qend["head"]))
	await _frames(30)
	# Sweep: legs out, tipping back (timed, the moment before the ragdoll).
	h.anim.play_timed(&"react_sweep", 0.35)
	var land_s := await _time_to_pose(h, PoseLibrary.get_pose(&"react_sweep_a"), 0.2, rt, "react_sweep")
	await _frames(roundi((0.35 * 0.9 - land_s) * 120.0))
	var sw := _sample(h)
	print("    react_sweep near its end: hips %s  chest pitch %.0f  lankle %s  rankle %s  head %s" % [
		_v(sw["hips"]), sw["chest_pitch"], _v(sw["lankle"]), _v(sw["rankle"]), _v(sw["head"])])
	_check("react_sweep: in within 0.05 s; hips dropped >= 0.25 m, torso tipped back >= 25 deg",
		land_s <= 0.05 and float(sw["hips"].y) <= float(stance["hips"].y) - 0.25 and float(sw["chest_pitch"]) <= -25.0,
		"land %.3f s, hips y %.2f, chest pitch %.0f" % [land_s, sw["hips"].y, sw["chest_pitch"]])
	_check("react_sweep: both feet off the floor and out in front (y >= 0.2, z <= -0.2)",
		float(sw["lankle"].y) >= 0.2 and float(sw["rankle"].y) >= 0.2 and float(sw["lankle"].z) <= -0.2 and float(sw["rankle"].z) <= -0.2,
		"lankle %s rankle %s" % [_v(sw["lankle"]), _v(sw["rankle"])])
	await _frames(40)
	# Broken: hold, dazed and open, swaying.
	h.anim.hold_pose(&"react_broken")
	await _frames(20)
	var hx := Vector2(INF, -INF)
	var worst_gap := INF
	var pitch_min := INF
	for i in 240:
		await get_tree().physics_frame
		_track_limits(h, rt, "react_broken")
		var b := _sample(h)
		hx = Vector2(minf(hx.x, b["head"].x), maxf(hx.y, b["head"].x))
		var top := maxf(float(b["lfist"].y), float(b["rfist"].y))
		worst_gap = minf(worst_gap, float(b["head"].y) - top)
		pitch_min = minf(pitch_min, -float(b["head_pitch"]))
	var bs := _sample(h)
	print("    react_broken: head %s  lfist %s  rfist %s  head x sway %.2f m  head drooped >= %.0f deg" % [
		_v(bs["head"]), _v(bs["lfist"]), _v(bs["rfist"]), hx.y - hx.x, pitch_min])
	_check("react_broken: guard dropped (hands >= 0.6 m below the head all the time)", worst_gap >= 0.6, "min gap %.2f m" % worst_gap)
	_check("react_broken: head lolled forward (>= 15 deg) and the body sways (head x range >= 0.1 m)",
		pitch_min >= 15.0 and hx.y - hx.x >= 0.1, "droop %.0f deg, sway %.2f m" % [pitch_min, hx.y - hx.x])
	h.anim.release_pose(0.1)
	await _frames(40)
	h.anim.play_timed(&"react_broken", Tuning.R8_BREAK_TIME)
	var land_b := await _time_to_pose(h, PoseLibrary.get_pose(&"react_broken_a"), 0.3, rt, "react_broken timed")
	_check("react_broken (play_timed %.1f s): in within 0.1 s" % Tuning.R8_BREAK_TIME, land_b <= 0.1, "%.3f s" % land_b)
	await _frames(roundi(Tuning.R8_BREAK_TIME * 120.0) + 20)

# --- Air strikes and the launcher jump ---------------------------------------------------------
func _check_air(h: AnimTestUtil.AnimHost, stance: Dictionary, rt: Dictionary) -> void:
	var f: Vector3 = Tuning.R8_AIR_FRAMES
	var st := Tuning.frames(f.x)
	var ac := Tuning.frames(f.y)
	var rc := Tuning.frames(f.z)
	print("    air strikes on R8_AIR_FRAMES %s: contact frame (first active frame), character space, metres:" % f)
	for id in [&"air_jab", &"air_cross", &"air_kick"]:
		h.anim.play_move(id, st, ac, rc)
		var c: Dictionary = {}
		var n := roundi((st + ac + rc) * 120.0)
		for i in n:
			await get_tree().physics_frame
			_track_limits(h, rt, String(id))
			if i == roundi(st * 120.0) - 1:
				c = _sample(h)
		print("    %-10s lfist %s  rfist %s  rankle %s  rshin %s  rfootbox %s  lknee %s  rknee %s  hips %s" % [
			id, _v(c["lfist"]), _v(c["rfist"]), _v(c["rankle"]), _v(c["rshin"]), _v(c["rfootbox"]),
			_v(c["lknee"]), _v(c["rknee"]), _v(c["hips"])])
		var hip_y: float = c["hips"].y
		match id:
			&"air_jab":
				_check("air_jab: left fist out in front at chest-head height (y 1.25-1.55, z <= -0.55)",
					c["lfist"].y >= 1.25 and c["lfist"].y <= 1.55 and c["lfist"].z <= -0.55, _v(c["lfist"]))
			&"air_cross":
				_check("air_cross: right fist out in front at chest-head height (y 1.25-1.55, z <= -0.55)",
					c["rfist"].y >= 1.25 and c["rfist"].y <= 1.55 and c["rfist"].z <= -0.55, _v(c["rfist"]))
			&"air_kick":
				_check("air_kick: right foot driven out in front at the middle (y 0.8-1.2, z <= -0.65)",
					c["rankle"].y >= 0.8 and c["rankle"].y <= 1.2 and c["rankle"].z <= -0.65, _v(c["rankle"]))
		var tucked: bool = c["lknee"].y >= hip_y - 0.2 and c["lankle"].y >= hip_y - 0.55
		if id != &"air_kick":
			tucked = tucked and c["rknee"].y >= hip_y - 0.25 and c["rankle"].y >= hip_y - 0.55
		_check("%s: legs tucked (knees near hip height, feet up)" % id, tucked,
			"hips y %.2f, knees %.2f / %.2f, ankles %.2f / %.2f" % [hip_y, c["lknee"].y, c["rknee"].y, c["lankle"].y, c["rankle"].y])
		await _frames(30)
	# Launcher jump.
	h.anim.play_timed(&"air_follow", Tuning.R8_AIR_FOLLOW_TIME)
	await _frames(roundi(Tuning.R8_AIR_FOLLOW_TIME * 0.5 * 120.0))
	var a := _sample(h)
	print("    air_follow mid-leap: rknee %s  lankle %s  rfist %s  head %s  head pitch %.0f" % [
		_v(a["rknee"]), _v(a["lankle"]), _v(a["rfist"]), _v(a["head"]), a["head_pitch"]])
	_check("air_follow: right knee driven up (above the hips), left leg trailing, right hand reaching up",
		float(a["rknee"].y) >= float(a["hips"].y) and float(a["lankle"].y) < float(a["hips"].y) - 0.6 \
			and float(a["rfist"].y) >= float(a["head"].y) + 0.05,
		"hips y %.2f, rknee y %.2f, lankle y %.2f, rfist y %.2f, head y %.2f" % [a["hips"].y, a["rknee"].y, a["lankle"].y, a["rfist"].y, a["head"].y])
	await _frames(60)

# --- Helpers ---------------------------------------------------------------------------------
func _sample(h: AnimTestUtil.AnimHost) -> Dictionary:
	var inv := h.global_transform.affine_inverse()
	var head_xf := h.rig.get_bone_global_transform(Bones.HEAD)
	var chest_b := (inv.basis * h.rig.get_bone_global_transform(Bones.CHEST).basis).orthonormalized()
	var head_b := (inv.basis * head_xf.basis).orthonormalized()
	var hips_b := (inv.basis * h.rig.get_bone_global_transform(Bones.HIPS).basis).orthonormalized()
	var rk := AnimTestUtil.local_pos(h, Bones.R_LOWER_LEG)
	var ra := AnimTestUtil.local_pos(h, Bones.R_FOOT)
	return {
		"head": inv * (head_xf.origin + head_xf.basis.orthonormalized() * Vector3(0, 0.15, 0)),
		"lfist": inv * h.rig.get_fist_position(Bones.L_HAND),
		"rfist": inv * h.rig.get_fist_position(Bones.R_HAND),
		"lankle": AnimTestUtil.local_pos(h, Bones.L_FOOT),
		"rankle": ra,
		"lknee": AnimTestUtil.local_pos(h, Bones.L_LOWER_LEG),
		"rknee": rk,
		"rshin": (rk + ra) * 0.5,
		"rfootbox": inv * (h.rig.get_bone_global_transform(Bones.R_FOOT) * Vector3(0, -0.045, -0.05)),
		"hips": AnimTestUtil.local_pos(h, Bones.HIPS),
		"hips_yaw": _yaw_deg(hips_b),
		"chest_yaw": _yaw_deg(chest_b),
		# + = pitched forward (the bone's up axis leans toward -Z).
		"chest_pitch": rad_to_deg(atan2(-chest_b.y.z, chest_b.y.y)),
		# + = tipped back (the head's up axis leans toward +Z).
		"head_pitch": rad_to_deg(atan2(head_b.y.z, head_b.y.y)),
	}

## A sample averaged over `n` ticks (smooths the tremble out of the numbers).
func _avg_sample(h: AnimTestUtil.AnimHost, n: int) -> Dictionary:
	var acc := {}
	for i in n:
		if i > 0:
			await get_tree().physics_frame
		var s := _sample(h)
		for k in s:
			acc[k] = s[k] if not acc.has(k) else acc[k] + s[k]
	for k in acc:
		acc[k] = acc[k] / float(n)
	return acc

static func _yaw_deg(b: Basis) -> float:
	var f := -b.z
	return rad_to_deg(atan2(-f.x, -f.z))

func _time_to_pose(h: AnimTestUtil.AnimHost, p: PoseLibrary.Pose, limit: float, rt: Dictionary, label: String) -> float:
	var t := 0.0
	while t < limit:
		await get_tree().physics_frame
		t += TICK
		_track_limits(h, rt, label)
		var m := 0.0
		for i in 10:
			if p.rot[i] != null:
				m = maxf(m, AnimTestUtil.angle_deg(h.anim.pose_rot[i], p.rot[i]))
		if m <= 1.5:
			return t
	return INF

func _track_limits(h: AnimTestUtil.AnimHost, rt: Dictionary, label: String) -> void:
	var r := AnimTestUtil.worst_excess(h.anim.pose_rot)
	if float(r[0]) > float(rt["worst"]):
		rt["worst"] = r[0]
		rt["at"] = "%s (%s)" % [label, r[1]]

static func _v(v: Vector3) -> String:
	return "(%5.2f %5.2f %5.2f)" % [v.x, v.y, v.z]
