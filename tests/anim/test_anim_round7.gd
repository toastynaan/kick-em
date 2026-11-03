extends Node3D
## Round 7 poses (docs/Round 7 — Freeflow Combat.md "Poses"; agent P):
## - every Round 7 move, hold and timed reaction id exists, names real poses
##   and compiles inside the joint limits; STRIKE_BONES lists every strike with
##   its limb; every Tuning.R7_MOVES id animates;
## - each strike, played on its R7_MOVES frames, puts its striking limb where
##   the hit lands on the first active frame (character space, printed);
## - heavies wind up deeper and follow through further than the light versions;
##   heavy kicks land where their light kicks land;
## - reactions read: snap head back, spin turned away, push arms flailing,
##   fold doubled over, buckle on one knee with the head at chest height, lift
##   tilted back with loose limbs that follow the flight;
## - reaction holds and moves land within 0.08 s, whatever blend is asked;
## - dodge, glide, throw wind-up / release, drive and clinch holds read.
## Measured standing still, no aim target (B's aim moves strikes at run time).
## OWNER: agent P.

const TICK := 1.0 / 120.0
## Runtime output may pass a soft joint range by this much (test_anim_limits).
const RUNTIME_TOL := 3.0

## The ids the Round 7 doc and contract ask for (independent of the library's lists).
const MOVES_NEEDED: Array[StringName] = [&"jab", &"cross", &"hook", &"heavy_jab", &"heavy_cross", &"heavy_hook",
	&"uppercut", &"gut_punch", &"leg_kick", &"front_kick", &"roundhouse", &"counter", &"dodge", &"glide", &"throw_release",
	&"heavy_leg_kick", &"heavy_front_kick", &"heavy_roundhouse"]
const HOLDS_NEEDED: Array[StringName] = [&"throw_windup", &"drive_hold", &"clinch_hold", &"react_fold", &"react_lift", &"react_buckle"]
const TIMED_REACTIONS: Array[StringName] = [&"react_snap", &"react_spin", &"react_push"]
const STRIKE_LIMBS := {
	&"jab": [&"LeftHand"], &"heavy_jab": [&"LeftHand"], &"hook": [&"LeftHand"], &"heavy_hook": [&"LeftHand"],
	&"cross": [&"RightHand"], &"heavy_cross": [&"RightHand"], &"uppercut": [&"RightHand"], &"gut_punch": [&"RightHand"],
	&"counter": [&"RightHand"], &"leg_kick": [&"RightFoot", &"RightLowerLeg"],
	&"front_kick": [&"RightFoot", &"RightLowerLeg"], &"roundhouse": [&"RightFoot", &"RightLowerLeg"],
	&"heavy_leg_kick": [&"RightFoot", &"RightLowerLeg"], &"heavy_front_kick": [&"RightFoot", &"RightLowerLeg"],
	&"heavy_roundhouse": [&"RightFoot", &"RightLowerLeg"]}
## Stun used for each reaction (Tuning.R7_MOVES of the move that causes it).
const REACT_STUN := {&"react_snap": 0.5, &"react_spin": 0.6, &"react_push": 0.8, &"react_fold": 1.1,
	&"react_buckle": 0.9, &"react_lift": 0.7}

var _ok := true

func _check(what: String, cond: bool, info := "") -> void:
	print("  %-64s %s %s" % [what, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _ready() -> void:
	get_tree().create_timer(200.0).timeout.connect(func() -> void:
		print("ANIM_ROUND7 FAIL (timeout)")
		get_tree().quit(1))
	_check_ids()
	_check_static_limits()
	var h := AnimTestUtil.make_host(self)
	await _frames(30)
	var stance := _sample(h)
	print("    stance: head %s  hips y %.2f  lfist %s  rfist %s" % [_v(stance["head"]), stance["hips"].y, _v(stance["lfist"]), _v(stance["rfist"])])
	var rt := {"worst": 0.0, "at": ""}
	var runs := {}
	for id in Tuning.R7_MOVES:
		runs[id] = await _run_strike(h, id, rt)
		await _frames(50)
	_check_contacts(runs, stance)
	_check_heavies(runs)
	await _check_reactions(h, stance, rt)
	await _check_other_moves(h, stance, rt)
	_check("live output inside the limits (+%.0f deg) through every Round 7 move" % RUNTIME_TOL,
		float(rt["worst"]) <= RUNTIME_TOL, "worst %.2f deg at %s" % [rt["worst"], rt["at"]])
	print("ANIM_ROUND7 ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

# --- Ids and static limits ------------------------------------------------------
func _check_ids() -> void:
	var missing: Array = []
	for id in MOVES_NEEDED + TIMED_REACTIONS:
		if not PoseLibrary.has_move(id):
			missing.append(id)
	_check("all %d Round 7 moves and timed reactions (has_move)" % (MOVES_NEEDED.size() + TIMED_REACTIONS.size()),
		missing.is_empty(), str(missing))
	missing.clear()
	for id in HOLDS_NEEDED:
		if not PoseLibrary.HOLDS.has(id):
			missing.append(id)
	# The held reactions also play as timed moves (play_timed(id, stun)).
	for id in [&"react_fold", &"react_buckle", &"react_lift"]:
		if not PoseLibrary.has_move(id):
			missing.append("move " + String(id))
	_check("all %d Round 7 holds (and fold / buckle / lift as moves)" % HOLDS_NEEDED.size(), missing.is_empty(), str(missing))
	var listed := true
	for id in MOVES_NEEDED + TIMED_REACTIONS:
		listed = listed and PoseLibrary.ROUND7_MOVE_IDS.has(id) and PoseLibrary.all_move_ids().has(id)
	for id in HOLDS_NEEDED:
		listed = listed and PoseLibrary.ROUND7_HOLD_IDS.has(id)
	for id in PoseLibrary.ROUND7_MOVE_IDS:
		listed = listed and PoseLibrary.has_move(id)
	for id in PoseLibrary.ROUND7_HOLD_IDS:
		listed = listed and PoseLibrary.HOLDS.has(id)
	_check("ROUND7_MOVE_IDS / ROUND7_HOLD_IDS list exactly playable ids", listed)
	var bad: Array = []
	for id in STRIKE_LIMBS:
		var got: Array = PoseLibrary.STRIKE_BONES.get(id, [])
		if got != STRIKE_LIMBS[id]:
			bad.append("%s %s" % [id, got])
	for id in Tuning.R7_MOVES:
		if not PoseLibrary.has_move(id) or not PoseLibrary.STRIKE_BONES.has(id) or not PoseLibrary.ROUND7_STRIKE_IDS.has(id):
			bad.append("R7_MOVES %s" % id)
	_check("STRIKE_BONES: every R7 strike on its limb; every R7_MOVES id animates", bad.is_empty(), str(bad))
	var bad_keys: Array = []
	for id in PoseLibrary.ROUND7_MOVE_IDS:
		for k in PoseLibrary.MOVES[id]["keys"]:
			if not PoseLibrary.POSES.has(StringName(String(k[2]).trim_suffix("#m"))):
				bad_keys.append("%s:%s" % [id, k[2]])
		# The contact key (first key of the active segment) exists for strikes.
		if PoseLibrary.ROUND7_STRIKE_IDS.has(id):
			var has_contact := false
			for k in PoseLibrary.MOVES[id]["keys"]:
				if int(k[0]) == 1 and typeof(k[1]) == TYPE_FLOAT and float(k[1]) == 0.0:
					has_contact = true
					break
			if not has_contact:
				bad_keys.append("%s: no contact key" % id)
	for id in PoseLibrary.ROUND7_HOLD_IDS:
		for pn in PoseLibrary.HOLDS[id]["poses"]:
			if not PoseLibrary.POSES.has(pn):
				bad_keys.append("hold %s:%s" % [id, pn])
	_check("every Round 7 key / hold names a pose; strikes have a contact key", bad_keys.is_empty(), str(bad_keys))

func _check_static_limits() -> void:
	var names: Array = []
	for id in PoseLibrary.ROUND7_MOVE_IDS:
		for k in PoseLibrary.MOVES[id]["keys"]:
			if not names.has(k[2]):
				names.append(k[2])
	for id in PoseLibrary.ROUND7_HOLD_IDS:
		for pn in PoseLibrary.HOLDS[id]["poses"]:
			if not names.has(pn):
				names.append(pn)
	var worst := 0.0
	var at := ""
	var bad: Array = []
	for pn in names:
		var r := AnimTestUtil.worst_excess(PoseLibrary.get_pose(pn).rot)
		if float(r[0]) > worst:
			worst = r[0]
			at = "%s %s" % [pn, r[1]]
		if float(r[0]) > AnimTestUtil.LIMIT_TOL:
			bad.append("%s %s %.1f" % [pn, r[1], r[0]])
	_check("all %d Round 7 poses compile inside the joint limits" % names.size(), bad.is_empty(),
		"worst %.2f deg (%s) %s" % [worst, at, str(bad) if not bad.is_empty() else ""])

# --- Strikes ----------------------------------------------------------------------
## Plays a strike on its R7_MOVES frames; returns per-tick samples and the
## index of the contact tick (the first active frame).
func _run_strike(h: AnimTestUtil.AnimHost, id: StringName, rt: Dictionary) -> Dictionary:
	var f: Vector3 = Tuning.R7_MOVES[id]["f"]
	var st := Tuning.frames(f.x)
	var ac := Tuning.frames(f.y)
	var rc := Tuning.frames(f.z)
	h.anim.play_move(id, st, ac, rc)
	var samples: Array = []
	var n := roundi((st + ac + rc) * 120.0)
	for i in n:
		await get_tree().physics_frame
		samples.append(_sample(h))
		_track_limits(h, rt, String(id))
	return {"s": samples, "contact": roundi(st * 120.0) - 1, "active_end": roundi((st + ac) * 120.0) - 1,
		"st": st, "ac": ac, "rc": rc}

func _check_contacts(runs: Dictionary, stance: Dictionary) -> void:
	print("    contact frame (first active frame), character space (-Z forward, +X right), metres:")
	var lines := {}
	for id in runs:
		var r: Dictionary = runs[id]
		var c: Dictionary = r["s"][r["contact"]]
		lines[id] = c
		print("    %-12s startup %4.3f s  lfist %s  rfist %s  rankle %s  rshin %s  rfootbox %s  head %s  hips y %.2f  hips yaw %5.1f" % [
			id, r["st"], _v(c["lfist"]), _v(c["rfist"]), _v(c["rankle"]), _v(c["rshin"]), _v(c["rfootbox"]),
			_v(c["head"]), c["hips"].y, c["hips_yaw"]])
	# Head punches: fist at head height, well in front.
	for id in [&"jab", &"heavy_jab", &"hook", &"heavy_hook"]:
		var p: Vector3 = lines[id]["lfist"]
		var reach := -0.45 if String(id).ends_with("hook") else -0.55
		_check("%s: lead (left) fist at the head (y 1.40-1.65, z <= %.2f)" % [id, reach],
			p.y >= 1.40 and p.y <= 1.65 and p.z <= reach, _v(p))
	for id in [&"cross", &"heavy_cross", &"counter"]:
		var p: Vector3 = lines[id]["rfist"]
		_check("%s: right fist at the head (y 1.40-1.65, z <= -0.55)" % id, p.y >= 1.40 and p.y <= 1.65 and p.z <= -0.55, _v(p))
	for id in [&"cross", &"heavy_cross", &"counter"]:
		var y: float = lines[id]["hips_yaw"]
		_check("%s: hips turned into the right hand (yaw >= +10 deg)" % id, y >= 10.0, "%.1f deg" % y)
	for id in [&"hook", &"heavy_hook"]:
		var r: Dictionary = runs[id]
		var c_yaw: float = r["s"][r["contact"]]["chest_yaw"]
		var w_yaw := -INF
		for i in r["contact"]:
			w_yaw = maxf(w_yaw, float(r["s"][i]["chest_yaw"]))
		_check("%s: torso rotates through the hook (>= 30 deg wind-up -> contact)" % id, w_yaw - c_yaw >= 30.0,
			"chest yaw %.0f -> %.0f deg" % [w_yaw, c_yaw])
	# Uppercut: from the hip, contact under the chin, rising through the active frames.
	var u: Dictionary = runs[&"uppercut"]
	var low := INF
	for i in u["contact"]:
		low = minf(low, float(u["s"][i]["rfist"].y))
	var uc: Vector3 = u["s"][u["contact"]]["rfist"]
	var ue: Vector3 = u["s"][u["active_end"]]["rfist"]
	var up := -INF
	for i in range(u["active_end"], u["s"].size()):
		up = maxf(up, float(u["s"][i]["rfist"].y))
	_check("uppercut: fist from the hip (<= 1.10 m in the startup)", low <= 1.10, "lowest %.2f m" % low)
	_check("uppercut: contact under the chin (y 1.35-1.60, z <= -0.4)", uc.y >= 1.35 and uc.y <= 1.60 and uc.z <= -0.4, _v(uc))
	_check("uppercut: fist rising through the active frames (+0.06 m), on overhead",
		ue.y >= uc.y + 0.06 and up >= 1.70, "contact %.2f -> last active %.2f -> peak %.2f m" % [uc.y, ue.y, up])
	# Gut punch: stomach height, low body.
	var g: Dictionary = lines[&"gut_punch"]
	_check("gut_punch: right fist at the stomach (y 1.00-1.15, z <= -0.5)",
		g["rfist"].y >= 1.0 and g["rfist"].y <= 1.15 and g["rfist"].z <= -0.5, _v(g["rfist"]))
	_check("gut_punch: knees bent, body low (hips >= 0.12 m under the stance)",
		g["hips"].y <= float(stance["hips"].y) - 0.12, "hips %.2f m (stance %.2f)" % [g["hips"].y, stance["hips"].y])
	for id in [&"leg_kick", &"heavy_leg_kick"]:
		# Leg kick: shin to the thigh, low.
		var lk: Dictionary = lines[id]
		_check("%s: right foot and shin below 0.8 m, off the floor, in front" % id,
			lk["rankle"].y < 0.8 and lk["rshin"].y < 0.8 and lk["rankle"].y > 0.25 and lk["rshin"].z <= -0.5,
			"ankle %s shin mid %s" % [_v(lk["rankle"]), _v(lk["rshin"])])
	for id in [&"front_kick", &"heavy_front_kick"]:
		# Front kick: chamber, then the heel straight out at the torso.
		var fk: Dictionary = runs[id]
		var knee_hi := -INF
		for i in fk["contact"]:
			knee_hi = maxf(knee_hi, float(fk["s"][i]["rknee"].y))
		var fc: Vector3 = lines[id]["rankle"]
		_check("%s: knee chambered (>= 0.95 m) before the kick" % id, knee_hi >= 0.95, "knee peak %.2f m" % knee_hi)
		_check("%s: heel straight out at the torso (y 0.95-1.30, z <= -0.75, |x| <= 0.25)" % id,
			fc.y >= 0.95 and fc.y <= 1.30 and fc.z <= -0.75 and absf(fc.x) <= 0.25, _v(fc))
	for id in [&"roundhouse", &"heavy_roundhouse"]:
		# Roundhouse: pivot, foot at head height.
		var rh: Dictionary = lines[id]
		_check("%s: right foot at head height (>= 1.40 m), in front" % id, rh["rankle"].y >= 1.40 and rh["rankle"].z <= -0.5,
			"ankle %s foot %s" % [_v(rh["rankle"]), _v(rh["rfootbox"])])
		_check("%s: pivoted on the lead foot (hips yaw >= 45 deg)" % id, float(rh["hips_yaw"]) >= 45.0, "%.0f deg" % rh["hips_yaw"])
	# Counter: the left hand catches first.
	var cr: Dictionary = runs[&"counter"]
	var catch_z := INF
	for i in cr["contact"] + 1:
		catch_z = minf(catch_z, float(cr["s"][i]["lfist"].z))
	_check("counter: the left hand shoots out to catch (z <= -0.5) before the right lands", catch_z <= -0.5, "left hand z %.2f" % catch_z)

func _check_heavies(runs: Dictionary) -> void:
	for pair in [[&"jab", &"heavy_jab", "lfist"], [&"cross", &"heavy_cross", "rfist"], [&"hook", &"heavy_hook", "lfist"]]:
		var lt: Dictionary = runs[pair[0]]
		var hv: Dictionary = runs[pair[1]]
		var limb: String = pair[2]
		var lw := _windup(lt, limb)
		var hw := _windup(hv, limb)
		var lr := _turn_range(lt)
		var hr := _turn_range(hv)
		_check("%s: deeper wind-up than %s (fist +0.10 m back, hips lower)" % [pair[1], pair[0]],
			hw.x >= lw.x + 0.10 and hw.y <= lw.y - 0.03,
			"fist back %.2f vs %.2f m, hips %.2f vs %.2f m" % [hw.x, lw.x, hw.y, lw.y])
		_check("%s: bigger turn through the strike than %s (+15 deg)" % [pair[1], pair[0]], hr >= lr + 15.0,
			"%.0f vs %.0f deg" % [hr, lr])

	# Heavy kicks: land where the light kick lands; a deeper load; a bigger follow-through.
	for id in [&"leg_kick", &"front_kick", &"roundhouse"]:
		var lt: Dictionary = runs[id]
		var hv: Dictionary = runs[StringName("heavy_" + String(id))]
		var la: Vector3 = lt["s"][lt["contact"]]["rankle"]
		var ha: Vector3 = hv["s"][hv["contact"]]["rankle"]
		_check("heavy_%s: lands where %s lands (ankle within 0.10 m)" % [id, id], la.distance_to(ha) <= 0.10,
			"%s vs %s" % [_v(ha), _v(la)])
		if id == &"front_kick":
			var lc := _chamber_time(lt)
			var hc := _chamber_time(hv)
			var lk := _peak(lt, "rknee", 0, lt["contact"])
			var hk := _peak(hv, "rknee", 0, hv["contact"])
			_check("heavy_front_kick: longer, higher chamber (+0.05 s above 0.95 m)", hc >= lc + 0.05 and hk >= lk,
				"%.3f vs %.3f s, knee %.2f vs %.2f m" % [hc, lc, hk, lk])
			var ld := _low(lt, "hips", 2, lt["contact"], lt["s"].size())
			var hd := _low(hv, "hips", 2, hv["contact"], hv["s"].size())
			_check("heavy_front_kick: drives through further (hips +0.08 m forward)", hd <= ld - 0.08,
				"hips z %.2f vs %.2f m" % [hd, ld])
		else:
			var lw := _low_val(lt, "hips_yaw", 0, lt["contact"])
			var hw := _low_val(hv, "hips_yaw", 0, hv["contact"])
			_check("heavy_%s: hips loaded further back in the wind-up (-15 deg)" % id, hw <= lw - 15.0,
				"hips yaw %.0f vs %.0f deg" % [hw, lw])
			var lr := _range_of(lt, "hips_yaw")
			var hr := _range_of(hv, "hips_yaw")
			_check("heavy_%s: bigger turn through the kick (+15 deg)" % id, hr >= lr + 15.0, "%.0f vs %.0f deg" % [hr, lr])

## Seconds the right knee is chambered (>= 0.95 m) before contact.
func _chamber_time(r: Dictionary) -> float:
	var n := 0
	for i in r["contact"]:
		if float(r["s"][i]["rknee"].y) >= 0.95:
			n += 1
	return n * TICK

## Highest y of a sampled point over ticks [a, b).
func _peak(r: Dictionary, key: String, a: int, b: int) -> float:
	var m := -INF
	for i in range(a, b):
		m = maxf(m, float(r["s"][i][key].y))
	return m

## Lowest component `axis` of a sampled point over ticks [a, b).
func _low(r: Dictionary, key: String, axis: int, a: int, b: int) -> float:
	var m := INF
	for i in range(a, b):
		m = minf(m, float((r["s"][i][key] as Vector3)[axis]))
	return m

## Lowest value of a sampled scalar over ticks [a, b).
func _low_val(r: Dictionary, key: String, a: int, b: int) -> float:
	var m := INF
	for i in range(a, b):
		m = minf(m, float(r["s"][i][key]))
	return m

## Max - min of a sampled scalar over the whole move.
func _range_of(r: Dictionary, key: String) -> float:
	var lo := INF
	var hi := -INF
	for smp in r["s"]:
		lo = minf(lo, float(smp[key]))
		hi = maxf(hi, float(smp[key]))
	return hi - lo

## (furthest-back fist z during the startup, lowest hips y during the startup)
func _windup(r: Dictionary, limb: String) -> Vector2:
	var back := -INF
	var hips := INF
	for i in r["contact"]:
		back = maxf(back, float(r["s"][i][limb].z))
		hips = minf(hips, float(r["s"][i]["hips"].y))
	return Vector2(back, hips)

## Degrees the chest turns over the whole move (wind-up extreme to follow-through extreme).
func _turn_range(r: Dictionary) -> float:
	var lo := INF
	var hi := -INF
	for s in r["s"]:
		lo = minf(lo, float(s["chest_yaw"]))
		hi = maxf(hi, float(s["chest_yaw"]))
	return hi - lo

# --- Reactions --------------------------------------------------------------------
func _check_reactions(h: AnimTestUtil.AnimHost, stance: Dictionary, rt: Dictionary) -> void:
	# Timed reactions: the first pose lands within 0.08 s; the state reads mid-way.
	for id in [&"react_snap", &"react_spin", &"react_push", &"react_fold", &"react_buckle", &"react_lift"]:
		var stun: float = REACT_STUN[id]
		var first: StringName = PoseLibrary.MOVES[id]["keys"][0][2]
		h.anim.play_timed(id, stun)
		var land := await _time_to_pose(h, PoseLibrary.get_pose(first), 0.3, rt, String(id))
		_check("%s (play_timed %.2f s): first pose lands within 0.08 s" % [id, stun], land <= 0.08 + 0.0001, "%.3f s" % land)
		await _frames(roundi(stun * 0.45 * 120.0) - (roundi(land * 120.0) if land < 1.0 else 0))
		var mid := _sample(h)
		match id:
			&"react_snap":
				_check("react_snap: head snapped back (+0.15 m behind the stance, tipped back)",
					mid["head"].z >= float(stance["head"].z) + 0.15 and float(mid["head_pitch"]) >= 15.0,
					"head %s, pitched back %.0f deg" % [_v(mid["head"]), mid["head_pitch"]])
			&"react_spin":
				_check("react_spin: head and shoulders turned away (chest >= 35, head >= 60 deg)",
					float(mid["chest_yaw"]) >= 35.0 and float(mid["head_yaw"]) >= 60.0,
					"chest %.0f, head %.0f deg" % [mid["chest_yaw"], mid["head_yaw"]])
			&"react_fold":
				_check("react_fold (move): doubled over, head low (< 1.45) and forward",
					mid["head"].y < 1.45 and mid["head"].z <= -0.15, _v(mid["head"]))
			&"react_buckle":
				_check("react_buckle (move): head at chest height (1.20-1.35 m)", mid["head"].y >= 1.20 and mid["head"].y <= 1.35, _v(mid["head"]))
		if id == &"react_push":
			# Arms flail: the higher hand swaps sides; stumble steps lift the feet.
			var swaps := 0
			var lift := 0.0
			var prev := 0
			var t := 0.0
			h.anim.play_timed(id, stun)
			while t < stun * 0.9:
				await get_tree().physics_frame
				t += TICK
				var s := _sample(h)
				var d: float = s["lfist"].y - s["rfist"].y
				var side := 1 if d > 0.25 else (-1 if d < -0.25 else 0)
				if side != 0 and prev != 0 and side != prev:
					swaps += 1
				if side != 0:
					prev = side
				lift = maxf(lift, maxf(float(s["lankle"].y), float(s["rankle"].y)) - 0.08)
			_check("react_push: arms flailing (high hand swaps >= 2), stumble steps (foot up >= 5 cm)",
				swaps >= 2 and lift >= 0.05, "%d swaps, foot lift %.2f m" % [swaps, lift])
		await _frames(roundi(stun * 120.0) + 40)
	# Held reactions: land within 0.08 s even when a slow blend is asked.
	for id in [&"react_fold", &"react_buckle"]:
		for blend in [0.08, 0.3]:
			h.anim.hold_pose(id, blend)
			var land := await _time_to_pose(h, PoseLibrary.get_pose(PoseLibrary.HOLDS[id]["poses"][0]), 0.3, rt, "hold " + String(id))
			_check("hold %s (blend %.2f asked): in within 0.08 s" % [id, blend], land <= 0.08 + 0.0001, "%.3f s" % land)
			await _frames(30)
			var s := _sample(h)
			if id == &"react_fold":
				var hands_ok: bool = s["lfist"].y >= 0.8 and s["lfist"].y <= 1.15 and s["rfist"].y >= 0.8 and s["rfist"].y <= 1.15 \
					and s["lfist"].z < -0.15 and s["rfist"].z < -0.15
				_check("react_fold: head low (< 1.45) and forward, hands at the stomach",
					s["head"].y < 1.45 and s["head"].z <= -0.15 and hands_ok,
					"head %s  hands %s %s" % [_v(s["head"]), _v(s["lfist"]), _v(s["rfist"])])
			else:
				_check("react_buckle: down on the left knee, head at chest height (1.20-1.35 m)",
					s["head"].y >= 1.20 and s["head"].y <= 1.35 and s["lknee"].y <= 0.15 and s["rankle"].y <= 0.12,
					"head %s  left knee y %.2f  right ankle y %.2f" % [_v(s["head"]), s["lknee"].y, s["rankle"].y])
			h.anim.release_pose(0.1)
			await _frames(40)
	# A hit landing while a strike plays: the reaction hold takes over within 0.08 s.
	h.anim.play_move(&"cross", 0.15, 0.05, 0.27)
	await _frames(10)
	h.anim.hold_pose(&"react_fold")
	var from_move := await _time_to_pose(h, PoseLibrary.get_pose(&"react_fold_a"), 0.3, rt, "fold from cross")
	_check("react_fold over a playing strike: in within 0.08 s", from_move <= 0.08 + 0.0001, "%.3f s" % from_move)
	h.anim.release_pose(0.1)
	await _frames(40)
	# react_spin_r mirrors the spin (turned to the victim's right).
	h.anim.play_timed(&"react_spin_r", REACT_STUN[&"react_spin"])
	await _frames(roundi(float(REACT_STUN[&"react_spin"]) * 0.45 * 120.0))
	var sr := _sample(h)
	_check("react_spin_r: turned away to the right (chest <= -35, head <= -60 deg)",
		float(sr["chest_yaw"]) <= -35.0 and float(sr["head_yaw"]) <= -60.0, "chest %.0f, head %.0f deg" % [sr["chest_yaw"], sr["head_yaw"]])
	await _frames(80)
	# Heavy wind-up holds (a punch waiting for the hold decision) then the heavy.
	h.anim.play_move(&"jab", Tuning.frames(7), Tuning.frames(3), Tuning.frames(14))
	await _frames(14)
	h.anim.hold_pose(&"heavy_jab_load")
	await _frames(10)
	var wl: Vector3 = _sample(h)["lfist"]
	h.anim.play_move(&"heavy_jab", Tuning.frames(8), Tuning.frames(4), Tuning.frames(18))
	await _frames(16)
	var wh: Vector3 = _sample(h)["lfist"]
	_check("heavy_jab_load hold, then heavy_jab from it: loaded back, then lands",
		wl.z >= -0.2 and wh.z <= -0.75 and wh.y >= 1.4, "loaded %s -> contact %s" % [_v(wl), _v(wh)])
	h.anim.release_pose(0.1)
	await _frames(40)
	await _check_lift(h, rt)

## The lift hold while the body flies: rising limbs trail, falling limbs float
## up; they keep moving loosely; the body is tilted back; inside the limits.
func _check_lift(h: AnimTestUtil.AnimHost, rt: Dictionary) -> void:
	h.anim.hold_pose(&"react_lift", 0.3)
	var tilt := 0.0
	var arm_rise: Array = []
	var arm_fall: Array = []
	var land := -1.0
	var lift_pose := PoseLibrary.get_pose(&"react_lift_rise")
	var vy := 5.7   # the uppercut pop (2 h / t at R7_LIFT_HEIGHT, R7_LIFT_PEAK_TIME)
	var g := 2.0 * Tuning.R7_LIFT_HEIGHT / (Tuning.R7_LIFT_PEAK_TIME * Tuning.R7_LIFT_PEAK_TIME)
	var t := 0.0
	var flail := 0.0
	var prev_arm := Quaternion.IDENTITY
	while t < 0.75:
		await get_tree().physics_frame
		t += TICK
		h.position.y = maxf(h.position.y + vy * TICK, 0.0)
		vy -= g * TICK
		_track_limits(h, rt, "hold react_lift")
		if land < 0.0 and _torso_diff(h, lift_pose) <= 1.0:
			land = t
		var s := _sample(h)
		tilt = maxf(tilt, -float(s["chest_pitch"]))
		var arm: Quaternion = h.anim.pose_rot[HumanoidRig.bone_index(Bones.L_UPPER_ARM)]
		if t > 0.1:
			flail = maxf(flail, AnimTestUtil.angle_deg(arm, prev_arm))
		prev_arm = arm
		# The upper arm's direction (rest hangs down), averaged per window so
		# the flail's phase does not decide the result.
		if t > 0.05 and t < 0.15:
			arm_rise.append(arm * Vector3.DOWN)
		if t > 0.55:
			arm_fall.append(arm * Vector3.DOWN)
	h.position.y = 0.0
	var mr := Vector3.ZERO
	var mf := Vector3.ZERO
	for v: Vector3 in arm_rise:
		mr += v
	for v: Vector3 in arm_fall:
		mf += v
	var rise_fall := rad_to_deg(mr.angle_to(mf))
	_check("react_lift (hold, 0.3 s blend asked): torso in within 0.08 s", land >= 0.0 and land <= 0.08 + 0.0001, "%.3f s" % land)
	_check("react_lift: body tilted back (chest >= 20 deg back)", tilt >= 20.0, "%.0f deg" % tilt)
	_check("react_lift: limbs follow the flight (mean rising vs falling arm >= 25 deg)", rise_fall >= 25.0, "%.0f deg" % rise_fall)
	_check("react_lift: limbs keep moving loosely (arm >= 0.5 deg per tick at peak)", flail >= 0.5, "%.2f deg/tick" % flail)
	h.anim.release_pose(0.1)
	h.reset_physics_interpolation()
	await _frames(40)

# --- Dodge, glide, throw, drive, clinch -------------------------------------------
func _check_other_moves(h: AnimTestUtil.AnimHost, stance: Dictionary, rt: Dictionary) -> void:
	# Dodge: a quick crouched step.
	for side in [0.0, 1.5]:
		# Standing (slips left) and already moving right (mirrored: slips right).
		h.anim.set_locomotion(Vector3(side, 0, 0), 4.5)
		await _frames(20 if side > 0.0 else 1)
		h.anim.play_timed(&"dodge", Tuning.R7_DODGE_TIME)
		var low := INF
		var step := 0.0
		var aside := 0.0
		for i in roundi(Tuning.R7_DODGE_TIME * 120.0):
			await get_tree().physics_frame
			_track_limits(h, rt, "dodge")
			var s := _sample(h)
			low = minf(low, float(s["hips"].y))
			step = maxf(step, maxf(float(s["lankle"].y), float(s["rankle"].y)) - 0.08)
			var dx: float = s["head"].x - float(stance["head"].x)
			aside = dx if absf(dx) > absf(aside) else aside
		var want := 1.0 if side > 0.0 else -1.0
		_check("dodge (%.2f s, %s): crouched (hips -0.18 m), stepping, head off the line" % [Tuning.R7_DODGE_TIME, "moving right" if side > 0.0 else "standing"],
			low <= float(stance["hips"].y) - 0.18 and step >= 0.04 and aside * want >= 0.25,
			"hips %.2f m (stance %.2f), foot up %.2f m, head aside %.2f m" % [low, stance["hips"].y, step, aside])
		h.anim.set_locomotion(Vector3.ZERO, 4.5)
		await _frames(40)
	# Glide at 11 m/s: leaning in, legs run.
	h.anim.set_locomotion(Vector3(0, 0, -Tuning.R7_GLIDE_SPEED), Tuning.R7_GLIDE_SPEED)
	await _frames(20)
	h.anim.play_timed(&"glide", Tuning.R7_GLIDE_MAX_TIME)
	var lean := 0.0
	var head_fwd := 0.0
	var feet_up := Vector2.ZERO
	for i in roundi(Tuning.R7_GLIDE_MAX_TIME * 0.8 * 120.0):
		await get_tree().physics_frame
		_track_limits(h, rt, "glide")
		var s := _sample(h)
		lean = maxf(lean, float(s["chest_pitch"]))
		head_fwd = maxf(head_fwd, float(s["hips"].z) - float(s["head"].z))
		feet_up = Vector2(maxf(feet_up.x, float(s["lankle"].y) - 0.08), maxf(feet_up.y, float(s["rankle"].y) - 0.08))
	_check("glide at %.0f m/s: torso pitched in (>= 35 deg), head ahead (>= 0.3 m)" % Tuning.R7_GLIDE_SPEED,
		lean >= 35.0 and head_fwd >= 0.3, "chest %.0f deg, head %.2f m ahead of the hips" % [lean, head_fwd])
	_check("glide: the legs run (both feet leave the ground)", feet_up.x >= 0.1 and feet_up.y >= 0.1, "%.2f / %.2f m" % [feet_up.x, feet_up.y])
	h.anim.set_locomotion(Vector3.ZERO, 4.5)
	await _frames(60)
	# Throw wind-up: grows to a full baseball load; re-holding does not restart it.
	h.anim.hold_pose(&"throw_windup")
	await _frames(roundi(Tuning.R7_THROW_WINDUP_FULL * 0.4 * 120.0))
	var early: Vector3 = _sample(h)["rfist"]
	h.anim.hold_pose(&"throw_windup")
	await _frames(roundi(Tuning.R7_THROW_WINDUP_FULL * 0.7 * 120.0))
	var full := _sample(h)
	_check("throw_windup: grows to full (arm loaded behind the head, turned back)",
		full["rfist"].z >= 0.25 and full["rfist"].y >= 1.5 and full["rfist"].z > early.z + 0.05 and float(full["chest_yaw"]) <= -45.0,
		"fist %s (early %s), chest yaw %.0f deg" % [_v(full["rfist"]), _v(early), full["chest_yaw"]])
	var tr: Vector3 = PoseLibrary.MOVES[&"throw_release"].get("timed", PoseLibrary.TIMED_SPLIT)
	var rel_len := 0.4
	h.anim.play_timed(&"throw_release", rel_len)
	var st := rel_len * tr.x / (tr.x + tr.y + tr.z)
	await _frames(ceili(st * 120.0 - 0.0001))
	var rel := _sample(h)
	_check("throw_release: the arm whips through (fist in front at the release)",
		rel["rfist"].z <= -0.55 and float(rel["chest_yaw"]) >= 20.0, "fist %s, chest yaw %.0f deg" % [_v(rel["rfist"]), rel["chest_yaw"]])
	await _frames(80)
	# Overlay form of the wind-up grows too.
	h.anim.set_upper_overlay(&"throw_windup")
	await _frames(roundi(Tuning.R7_THROW_WINDUP_FULL * 120.0) + 10)
	var ov: Vector3 = _sample(h)["rfist"]
	# (An overlay leaves the hips to the locomotion, so the turn is smaller than the hold's.)
	_check("throw_windup as an upper overlay reaches the full load (fist up, behind the shoulders)", ov.z >= 0.0 and ov.y >= 1.45, _v(ov))
	h.anim.set_upper_overlay(&"")
	await _frames(40)
	# Drive: leaning hard, both hands driving the body in front; legs run at speed.
	h.anim.set_locomotion_style(&"carry")
	h.anim.set_locomotion(Vector3(0, 0, -Tuning.R7_DRIVE_MAX_SPEED), Tuning.R7_DRIVE_MAX_SPEED)
	h.anim.hold_pose(&"drive_hold")
	await _frames(30)
	var dl := 0.0
	var dfeet := Vector2.ZERO
	var dhands := Vector3.ZERO
	for i in 60:
		await get_tree().physics_frame
		_track_limits(h, rt, "drive_hold")
		var s := _sample(h)
		dl = maxf(dl, float(s["chest_pitch"]))
		dfeet = Vector2(maxf(dfeet.x, float(s["lankle"].y) - 0.08), maxf(dfeet.y, float(s["rankle"].y) - 0.08))
		dhands = Vector3(maxf(s["lfist"].z, s["rfist"].z), minf(s["lfist"].y, s["rfist"].y), maxf(s["lfist"].y, s["rfist"].y))
	_check("drive_hold at %.1f m/s: leaning in (>= 35 deg), legs running" % Tuning.R7_DRIVE_MAX_SPEED,
		dl >= 35.0 and dfeet.x >= 0.1 and dfeet.y >= 0.1, "chest %.0f deg, feet up %.2f / %.2f m" % [dl, dfeet.x, dfeet.y])
	_check("drive_hold: both hands in front, driving (z <= -0.45, y 0.9-1.35)",
		dhands.x <= -0.45 and dhands.y >= 0.9 and dhands.z <= 1.35, "hands z <= %.2f, y %.2f-%.2f" % [dhands.x, dhands.y, dhands.z])
	h.anim.release_pose(0.1)
	h.anim.set_locomotion_style(&"walk")
	h.anim.set_locomotion(Vector3.ZERO, 4.5)
	await _frames(60)
	# Clinch: both hands at the opponent's collar.
	h.anim.hold_pose(&"clinch_hold")
	await _frames(30)
	var c := _sample(h)
	var collar_ok := true
	for k in ["lfist", "rfist"]:
		var p: Vector3 = c[k]
		collar_ok = collar_ok and p.y >= 1.30 and p.y <= 1.50 and p.z >= -0.66 and p.z <= -0.50 and absf(p.x) <= 0.15
	# The clinched body stands Carry.CLINCH_DIST (0.72 m) in front: its collar is ~0.62 m out.
	_check("clinch_hold: both hands at the collar (y 1.30-1.50, z -0.66..-0.50)", collar_ok, "%s %s" % [_v(c["lfist"]), _v(c["rfist"])])
	h.anim.release_pose(0.1)
	await _frames(30)

# --- Sampling -------------------------------------------------------------------------
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
		"head_yaw": _yaw_deg(head_b),
		# + = pitched forward (the bone's up axis leans toward -Z).
		"chest_pitch": rad_to_deg(atan2(-chest_b.y.z, chest_b.y.y)),
		# + = tipped back (the head's up axis leans toward +Z).
		"head_pitch": rad_to_deg(atan2(head_b.y.z, head_b.y.y)),
	}

## Heading of a bone frame in character space (+ = turned to the character's
## left, the PoseLibrary +Y convention), from its forward (-Z) axis.
static func _yaw_deg(b: Basis) -> float:
	var f := -b.z
	return rad_to_deg(atan2(-f.x, -f.z))

## Seconds until the upper body (hips..head and arms) is within 1 deg of `p`
## where `p` defines it (INF if not within `limit` s).
func _time_to_pose(h: AnimTestUtil.AnimHost, p: PoseLibrary.Pose, limit: float, rt: Dictionary, label: String) -> float:
	var t := 0.0
	while t < limit:
		await get_tree().physics_frame
		t += TICK
		_track_limits(h, rt, label)
		if _upper_diff(h, p) <= 1.0:
			return t
	return INF

func _upper_diff(h: AnimTestUtil.AnimHost, p: PoseLibrary.Pose) -> float:
	var m := 0.0
	for i in 10:
		if p.rot[i] != null:
			m = maxf(m, AnimTestUtil.angle_deg(h.anim.pose_rot[i], p.rot[i]))
	return m

## Torso only (hips, spine, chest, head): the lift's limbs flail by design.
func _torso_diff(h: AnimTestUtil.AnimHost, p: PoseLibrary.Pose) -> float:
	var m := 0.0
	for i in 4:
		if p.rot[i] != null:
			m = maxf(m, AnimTestUtil.angle_deg(h.anim.pose_rot[i], p.rot[i]))
	return m

func _track_limits(h: AnimTestUtil.AnimHost, rt: Dictionary, label: String) -> void:
	var r := AnimTestUtil.worst_excess(h.anim.pose_rot)
	if float(r[0]) > float(rt["worst"]):
		rt["worst"] = r[0]
		rt["at"] = "%s (%s)" % [label, r[1]]

static func _v(v: Vector3) -> String:
	return "(%5.2f %5.2f %5.2f)" % [v.x, v.y, v.z]
