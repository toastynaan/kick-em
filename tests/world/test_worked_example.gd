extends Node3D
## Round 5 wall table (Feel Reference: Launch speed and walls; acceptance check
## F3 "walls crack/break per the wall table, concrete on the second 18 m/s
## hit", owner D). A 70 kg body (real Fighter, real ragdoll) is launched with
## Power.launch_velocity(P) straight at a fresh drywall, brick and concrete
## panel for P 5, 6.4, 7, 8, 9 and 11. The wall decides on E = 1/2 M v^2 with
## the speed straight into it (Tuning.SURFACES: 2,000 / 6,000 / 15,000 J,
## cracking at Tuning.CRACK_FRACTION = 40%). Expected, from the table:
##   P 5   6 m/s at 30   945 J   drywall crack, brick bounce, concrete bounce
##   P 6.4 8.8 m/s 30  2,033 J   drywall break (just), brick bounce
##   P 7  10 m/s at 18 3,166 J   drywall break, brick crack
##   P 8  12 m/s at 18 4,559 J   drywall break, brick crack
##   P 9  14 m/s at 18 6,205 J   brick break, concrete crack
##   P 11 18 m/s at 18 10,257 J  brick break, concrete crack
## Then concrete is a two-hit payoff: after the P 11 crack its break energy is
## 15,000 - E/2 (~9,872 J) and a second 18 m/s body breaks it; a pillar does the
## same. Also: wall damage (Tuning.WALL_DAMAGE) on each outcome, the wall-break
## freeze holds the flyer only, the body ends beyond a broken wall and leaves at
## sqrt(1 - absorption) of its speed. Prints every energy and outcome.

const TOL_E := 0.05        ## measured energy within 5% of 1/2 M (v cos a)^2
const START_DIST := 1.5    ## m from the panel face to the body's COM
const LANE := 12.0         ## m between cases (z)

const TABLE := [
	[5.0, {&"drywall": &"crack", &"brick": &"bounce", &"concrete": &"bounce"}],
	[6.4, {&"drywall": &"break", &"brick": &"bounce", &"concrete": &"bounce"}],
	[7.0, {&"drywall": &"break", &"brick": &"crack", &"concrete": &"bounce"}],
	[8.0, {&"drywall": &"break", &"brick": &"crack", &"concrete": &"bounce"}],
	[9.0, {&"drywall": &"break", &"brick": &"break", &"concrete": &"crack"}],
	[11.0, {&"drywall": &"break", &"brick": &"break", &"concrete": &"crack"}],
]

var _decisions: Array = []
var _impacts: Array = []
var _broken_by: Array = []
var _ok := true
var _rows: Array[String] = []
var _lane := 0

func _ready() -> void:
	ImpactResolver.wall_decided.connect(func(f: Node3D, w: Node3D, outcome: StringName, e: float, pos: Vector3) -> void:
		_decisions.append({"fighter": f, "wall": w, "outcome": outcome, "energy": e, "pos": pos}))
	ImpactResolver.impact_dealt.connect(func(f: Node3D, e: float, dmg: float, surface: StringName, pos: Vector3) -> void:
		_impacts.append({"fighter": f, "energy": e, "damage": dmg, "surface": surface, "pos": pos}))
	GameEvents.wall_broken_by.connect(func(flyer: Node3D, wall: Node3D, e: float) -> void:
		_broken_by.append([flyer, wall, e]))
	WorldTestUtil.make_floor(self, 400.0)
	await get_tree().physics_frame
	if not await WorldTestUtil.real_ragdoll_available(self):
		print("[walls] FAIL: real ragdoll unavailable")
		get_tree().quit(1)
		return

	for row: Array in TABLE:
		var p: float = row[0]
		var expect: Dictionary = row[1]
		for surface: StringName in [&"drywall", &"brick", &"concrete"]:
			await _case(p, surface, expect[surface])

	await _concrete_two_hits()
	await _pillar_two_hits()

	print("")
	print("[walls] ---- summary ----")
	for r in _rows:
		print("[walls] ", r)
	print("[walls] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _pf(b: bool) -> String:
	return "PASS" if b else "FAIL"

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	_rows.append("%s  %s" % [s, _pf(ok)])
	print("[walls] ", _rows[_rows.size() - 1])

func _next_z() -> float:
	_lane += 1
	return float(_lane) * LANE

## One table cell: P into a fresh panel of `surface`.
func _case(p: float, surface: StringName, expect: StringName) -> void:
	var z := _next_z()
	var panel := WorldTestUtil.make_panel(self, surface, Vector3(0, 0, z))
	await get_tree().physics_frame
	var res := await _launch_at(panel, panel.global_position.x + panel.size.z * 0.5, z, p)
	var e: float = res.get("energy", -1.0)
	var spec_e: float = res.get("spec_energy", 0.0)
	var outcome: StringName = res.get("outcome", &"none")
	var e_ok := spec_e > 0.0 and absf(e - spec_e) / spec_e <= TOL_E
	var ok := outcome == expect and e_ok
	var dmg: float = res.get("damage", 0.0)
	var want_dmg := 0.0
	match outcome:
		&"crack":
			want_dmg = Tuning.WALL_DAMAGE[&"crack"]
		&"break":
			want_dmg = Tuning.WALL_DAMAGE[surface]
	var dmg_ok := absf(dmg - want_dmg) < 0.01
	ok = ok and dmg_ok
	var extra := ""
	if outcome == &"break":
		var past: float = res.get("past", -9.0)
		var froze: bool = res.get("froze", false)
		extra = " past=%.2f m exit=%.1f m/s (sqrt(1-abs) x %.1f = %.1f) freeze=%s" % [past, res.get("exit_speed", 0.0),
			res.get("v_in", 0.0), res.get("v_in", 0.0) * sqrt(1.0 - float(Tuning.SURFACES[surface]["absorption"])), froze]
		var exit_ok := absf(float(res.get("exit_speed", 0.0)) - float(res.get("v_in", 0.0))
			* sqrt(1.0 - float(Tuning.SURFACES[surface]["absorption"]))) <= 0.15 * float(res.get("v_in", 1.0))
		ok = ok and past > 0.3 and froze and exit_ok
		var by_ok: bool = res.get("broken_by", false)
		extra += " wall_broken_by=%s" % by_ok
		ok = ok and by_ok
	elif res.has("past"):
		var front: bool = res["past"] < 0.0
		extra = " in_front=%s" % front
		ok = ok and front
	_line("P %4.1f v=%5.2f m/s at %2.0f  %-8s M=%.1f kg E=%6.0f J (table %6.0f, %+4.1f%%) -> %-6s (expect %-6s) dmg=%4.1f (want %4.1f)%s" % [
		p, Power.launch_speed(p), Power.launch_angle(p), surface, res.get("mass", 0.0), e, spec_e,
		(e - spec_e) / maxf(spec_e, 1.0) * 100.0, outcome, expect, dmg, want_dmg, extra], ok)
	panel.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

## Concrete: P 11 (18 m/s) cracks it and drops its break energy to 15,000 - E/2;
## a second 18 m/s body on the cracked panel breaks it.
func _concrete_two_hits() -> void:
	var z := _next_z()
	var panel := WorldTestUtil.make_panel(self, &"concrete", Vector3(0, 0, z))
	await get_tree().physics_frame
	var face_x := panel.global_position.x + panel.size.z * 0.5
	var first := await _launch_at(panel, face_x, z, 11.0)
	var be := panel.break_energy
	var e1: float = first.get("energy", -1.0)
	var be_ok := absf(be - (15000.0 - 0.5 * e1)) < 1.0 and absf(be - 9872.0) / 9872.0 <= TOL_E
	WorldTestUtil.cleanup()
	await get_tree().physics_frame
	var second := await _launch_at(panel, face_x, z, 11.0)
	var ok: bool = first.get("outcome", &"") == &"crack" and second.get("outcome", &"") == &"break" and be_ok
	_line("concrete panel, two 18 m/s hits: first E=%.0f J -> %s, break energy now %.0f J (spec 15,000 - 5,128 = 9,872); second E=%.0f J -> %s (expect crack, break) dmg %.0f + %.0f" % [
		e1, first.get("outcome", &"none"), be, second.get("energy", -1.0), second.get("outcome", &"none"),
		first.get("damage", 0.0), second.get("damage", 0.0)], ok)
	panel.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

## A concrete pillar breaks the same way: crack, then break on the second 18 m/s hit.
func _pillar_two_hits() -> void:
	var z := _next_z()
	var pillar := Pillar.new()
	pillar.position = Vector3(0, 0, z)
	add_child(pillar)
	await get_tree().physics_frame
	var face_x := pillar.size.x * 0.5
	var first := await _launch_at(pillar, face_x, z, 11.0)
	var be := pillar.break_energy
	WorldTestUtil.cleanup()
	await get_tree().physics_frame
	var second := await _launch_at(pillar, face_x, z, 11.0)
	var debris := DebrisManager.count_large()
	var ok: bool = first.get("outcome", &"") == &"crack" and second.get("outcome", &"") == &"break" \
		and pillar.is_broken and second.get("past", -9.0) > 0.3
	_line("pillar, two 18 m/s hits: first E=%.0f J -> %s (break energy now %.0f J), second E=%.0f J -> %s, body past=%.2f m, pieces=%d" % [
		first.get("energy", -1.0), first.get("outcome", &"none"), be, second.get("energy", -1.0),
		second.get("outcome", &"none"), second.get("past", -9.0), debris], ok)
	pillar.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

## Launch a fresh 70 kg body (player archetype, enemy team) with
## Power.launch_velocity(p) toward -X at `wall`, whose struck face is at x = face_x.
func _launch_at(wall: Node3D, face_x: float, z: float, p: float) -> Dictionary:
	_decisions.clear()
	_impacts.clear()
	_broken_by.clear()
	var start := Vector3(face_x + START_DIST, 0.05, z)
	var f := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, -PI * 0.5), start), false, &"player")
	await get_tree().physics_frame
	await get_tree().physics_frame
	var com := f.get_center_of_mass()
	f.global_position += Vector3(face_x + START_DIST - com.x, 0, z - com.z)
	f.reset_physics_interpolation()
	await get_tree().physics_frame
	var mass := f.get_total_mass()
	var vel := Power.launch_velocity(p, Vector3(-1, 0, 0), mass)
	var v_in := Vector2(vel.x, vel.z).length()
	f.launch(vel, f.get_center_of_mass(), &"Chest")
	var res := {"mass": mass, "v_in": v_in, "spec_energy": 0.5 * mass * v_in * v_in}
	var t := 0.0
	var decided_at := -1.0
	var froze := false
	while t < 1.4:
		await get_tree().physics_frame
		t += 1.0 / 120.0
		if not is_instance_valid(f):
			break
		if decided_at < 0.0:
			for d: Dictionary in _decisions:
				if d["wall"] == wall and d["fighter"] == f:
					decided_at = t
					res["energy"] = d["energy"]
					res["outcome"] = d["outcome"]
					break
		else:
			if f.is_frozen():
				froze = true
			elif froze and t - decided_at <= 0.4:
				# Fastest horizontal speed after the freeze, before the floor slows it.
				var v := f.get_com_velocity()
				res["exit_speed"] = maxf(float(res.get("exit_speed", 0.0)), Vector2(v.x, v.z).length())
	res["froze"] = froze
	for im: Dictionary in _impacts:
		if im["fighter"] == f and im["damage"] > 0.0:
			res["damage"] = float(res.get("damage", 0.0)) + float(im["damage"])
	for b: Array in _broken_by:
		if b[0] == f and b[1] == wall:
			res["broken_by"] = true
	if is_instance_valid(f):
		res["past"] = (face_x - (wall.get(&"size") as Vector3).z if wall is Destructible else -face_x) \
			- f.get_center_of_mass().x
		f.queue_free()
	return res
