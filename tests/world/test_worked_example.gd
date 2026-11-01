extends Node3D
## Worked example (spec: Impact resolution > Worked example). 70 kg Fighters
## launched at a single panel of each surface from 2 m away. Checks each
## outcome, that the measured E is within +-15% of the spec energy, the brick
## break-energy drop after a crack, the drywall exit speed, that a break is
## decided before contact (the body lands beyond the wall) and the impact
## damage of a drywall break. Uses real Fighters; falls back to the test
## stand-in ragdoll only while agent A's ragdoll is unavailable.

const TOL := 0.15
const LIFT := 1.8          ## m/s upward so the feet clear the floor on the way in
const START_DIST := 2.0    ## m from the panel face to the body's COM

var _use_fake := false
var _decisions: Array = []
var _impacts: Array = []
var _ok := true
var _rows: Array[String] = []

func _ready() -> void:
	ImpactResolver.wall_decided.connect(func(f: Node3D, w: Node3D, outcome: StringName, e: float, pos: Vector3) -> void:
		_decisions.append({"fighter": f, "wall": w, "outcome": outcome, "energy": e, "pos": pos,
			"com": (f as Fighter).get_center_of_mass(), "t": Time.get_ticks_msec()}))
	ImpactResolver.impact_dealt.connect(func(f: Node3D, e: float, dmg: float, surface: StringName, pos: Vector3) -> void:
		_impacts.append({"fighter": f, "energy": e, "damage": dmg, "surface": surface, "pos": pos}))
	WorldTestUtil.make_floor(self)
	await get_tree().physics_frame
	_use_fake = not await WorldTestUtil.real_ragdoll_available(self)
	print("[worked] ragdoll: ", "TEST STAND-IN (agent A ragdoll unavailable)" if _use_fake else "real RagdollController")

	# Spec table: speed into the wall -> expected outcome per surface.
	await _case("standing kick 8 m/s", &"drywall", 8.0, 0.0, 2240.0, &"break")
	await _case("standing kick 8 m/s", &"brick", 8.0, 0.0, 2240.0, &"bounce")
	await _case("standing kick 8 m/s", &"concrete", 8.0, 0.0, 2240.0, &"bounce")
	await _case("45 deg 13 m/s", &"drywall", 13.0, 45.0, 2957.0, &"break")
	await _case("45 deg 13 m/s", &"brick", 13.0, 45.0, 2957.0, &"crack")
	await _case("45 deg 13 m/s", &"concrete", 13.0, 45.0, 2957.0, &"bounce")
	var dry := await _case("dash kick 13 m/s", &"drywall", 13.0, 0.0, 5915.0, &"break")
	var brick := await _case("dash kick 13 m/s", &"brick", 13.0, 0.0, 5915.0, &"crack", true)
	await _case("dash kick 13 m/s", &"concrete", 13.0, 0.0, 5915.0, &"bounce")
	await _case("counter 16 m/s", &"drywall", 16.0, 0.0, 8960.0, &"break")
	await _case("counter 16 m/s", &"brick", 16.0, 0.0, 8960.0, &"break")
	await _case("counter 16 m/s", &"concrete", 16.0, 0.0, 8960.0, &"bounce")
	await _case("power punch 18 m/s", &"drywall", 18.0, 0.0, 11340.0, &"break")
	await _case("power punch 18 m/s", &"brick", 18.0, 0.0, 11340.0, &"break")
	await _case("power punch 18 m/s", &"concrete", 18.0, 0.0, 11340.0, &"bounce")

	# Concrete decal from 5,000 J: the 13 m/s concrete case must have marked it.
	# Brick after a 13 m/s crack: break energy ~4,542 J; a second 13 m/s breaks it,
	# a second 8 m/s does not.
	var be: float = brick.get("break_energy_after", 0.0)
	var drop_ok := absf(be - 4542.0) / 4542.0 <= TOL
	_line("brick break energy after 13 m/s crack: %.0f J (spec 4,542 J) -> %s" % [be, _pf(drop_ok)])
	_ok = _ok and drop_ok
	await _second_hit("brick cracked, second 13 m/s", 13.0, &"break")
	await _second_hit("brick cracked, second 8 m/s", 8.0, &"crack")

	# Drywall exit speed at 13 m/s (absorption 0.3): ~10.9 m/s.
	var exit_v: float = dry.get("exit_speed", 0.0)
	var exit_ok := absf(exit_v - 13.0 * sqrt(0.7)) <= 13.0 * sqrt(0.7) * TOL
	_line("drywall 13 m/s exit speed: %.2f m/s (spec ~11, sqrt(0.7)*13 = 10.88) -> %s" % [exit_v, _pf(exit_ok)])
	_ok = _ok and exit_ok
	var beyond_ok: bool = dry.get("beyond", false)
	_line("drywall 13 m/s body lands beyond the wall: final COM %.2f m past the face -> %s" % [
		dry.get("past", 0.0), _pf(beyond_ok)])
	_ok = _ok and beyond_ok

	print("")
	print("[worked] ---- summary ----")
	for r in _rows:
		print("[worked] ", r)
	print("[worked] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _pf(b: bool) -> String:
	return "PASS" if b else "FAIL"

func _line(s: String) -> void:
	_rows.append(s)
	print("[worked] ", s)

var _brick_keep: Destructible

func _case(label: String, surface: StringName, speed: float, angle_deg: float, spec_e: float,
		expect: StringName, keep_panel := false) -> Dictionary:
	var panel := WorldTestUtil.make_panel(self, surface)
	await get_tree().physics_frame
	var res := await _launch_at(panel, speed, angle_deg)
	var e: float = res.get("energy", -1.0)
	var outcome: StringName = res.get("outcome", &"none")
	var e_ok := absf(e - spec_e) / spec_e <= TOL
	var o_ok := outcome == expect
	var extra := ""
	if surface == &"concrete" and spec_e >= 5000.0:
		extra = " decal=%s" % panel.is_cracked
		o_ok = o_ok and panel.is_cracked
	if surface == &"concrete" and spec_e < 5000.0:
		o_ok = o_ok and not panel.is_cracked
	if outcome == &"break":
		extra += " exit=%.2f m/s past=%.2f m" % [res.get("exit_speed", 0.0), res.get("past", 0.0)]
	elif res.has("past"):
		# Crack / bounce: the body must end up in front of the wall (it bounced).
		var front: bool = res["past"] < 0.0
		extra += " in_front=%s" % front
		o_ok = o_ok and front
	if res.has("damage"):
		extra += " dmg=%.1f" % res["damage"]
	if surface == &"drywall" and is_equal_approx(speed, 8.0):
		# Spec: a drywall break at 2,240 J deals 87.
		var d: float = res.get("damage", -1.0)
		var d_ok := absf(d - 87.0) <= 87.0 * TOL
		extra += " (spec 87 HP: %s)" % _pf(d_ok)
		o_ok = o_ok and d_ok
	_line("%-22s %-8s E=%7.0f J (spec %5.0f, %+5.1f%%) -> %-6s (expect %-6s)%s  %s" % [
		label, surface, e, spec_e, (e - spec_e) / spec_e * 100.0, outcome, expect, extra,
		_pf(e_ok and o_ok)])
	_ok = _ok and e_ok and o_ok
	res["break_energy_after"] = panel.break_energy
	if keep_panel:
		_brick_keep = panel
	else:
		panel.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame
	return res

func _second_hit(label: String, speed: float, expect: StringName) -> void:
	# Fresh brick cracked by a 13 m/s hit, then the second hit.
	var panel := WorldTestUtil.make_panel(self, &"brick")
	await get_tree().physics_frame
	var first := await _launch_at(panel, 13.0, 0.0)
	var be := panel.break_energy
	WorldTestUtil.cleanup()
	await get_tree().physics_frame
	var res := await _launch_at(panel, speed, 0.0)
	var outcome: StringName = res.get("outcome", &"none")
	var ok: bool = first.get("outcome", &"") == &"crack" and outcome == expect
	_line("%-34s first=%s (break energy now %.0f J) second E=%.0f J -> %s (expect %s)  %s" % [
		label, first.get("outcome", &"none"), be, res.get("energy", -1.0), outcome, expect, _pf(ok)])
	_ok = _ok and ok
	panel.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

## Launch a fresh 70 kg body at `panel` (exterior face +X) and report the decision.
func _launch_at(panel: Destructible, speed: float, angle_deg: float) -> Dictionary:
	_decisions.clear()
	_impacts.clear()
	var a := deg_to_rad(angle_deg)
	var face_x := panel.global_position.x + panel.size.z * 0.5
	var v_in := speed * cos(a)
	var v_tan := speed * sin(a)
	var t_travel := START_DIST / v_in
	var com_y := 1.05
	var start := Vector3(face_x + START_DIST, 0.0, panel.global_position.z - v_tan * t_travel)
	# Facing away from the wall (kicked backwards into it).
	var f := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, -PI * 0.5), start + Vector3(0, 0.05, 0)), _use_fake)
	await get_tree().physics_frame
	await get_tree().physics_frame
	# Re-centre so the COM starts exactly START_DIST from the face.
	var com := f.get_center_of_mass()
	var shift := Vector3(face_x + START_DIST - com.x, 0, 0)
	f.global_position += shift
	f.reset_physics_interpolation()
	await get_tree().physics_frame
	com = f.get_center_of_mass()
	var vel := Vector3(-v_in, LIFT, v_tan)
	f.launch(vel, com + Vector3(0.15, 0.2, 0), &"Chest")
	var res := {}
	var t := 0.0
	var decided_at := -1.0
	var mass := f.get_total_mass()
	while t < 1.6:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		if not is_instance_valid(f):
			break
		if decided_at < 0.0:
			for d: Dictionary in _decisions:
				if d["wall"] == panel and d["fighter"] == f:
					decided_at = t
					res["energy"] = d["energy"]
					res["outcome"] = d["outcome"]
					res["com_at_decision"] = d["com"]
					res["v_launch"] = f.get_com_velocity()
					break
		elif not res.has("exit_speed") and t - decided_at >= 0.08:
			var v := f.get_com_velocity()
			res["exit_speed"] = Vector2(v.x, v.z).length()
	if res.has("energy"):
		for im: Dictionary in _impacts:
			if im["fighter"] == f and im["surface"] == panel.surface:
				res["damage"] = im["damage"]
				break
	if is_instance_valid(f):
		var end := f.get_center_of_mass()
		res["past"] = (panel.global_position.x - panel.size.z * 0.5) - end.x
		res["beyond"] = res["past"] > 0.5
		res["mass"] = mass
		f.queue_free()
	return res
