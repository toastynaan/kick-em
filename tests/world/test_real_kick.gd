extends Node3D
## Round 7 launches through REAL strikes into walls (docs/Round 7 — Freeflow
## Combat.md: Moves, Payoffs; the wall table is unchanged). A player Fighter
## strikes a 70 kg dummy whose COM stands 2 m in front of a single panel; the
## wall decides on E = 1/2 M v^2 straight into it (break at break_energy, crack
## at CRACK_FRACTION of it, else bounce).
##   heavy roundhouse (its own launch, 11 m/s at 20 deg): ~3,740 J:
##     breaks drywall, cracks brick, bounces off concrete.
##   uppercut -> roundhouse (the lift payoff, 15 m/s at 12 deg): ~7,530 J:
##     breaks drywall and brick, cracks concrete.
## Prints the launch speed and angle, the measured wall energy and the outcome.

const WALL_DIST := 2.0
const SPEED_TOL := 0.5      ## m/s
var _decisions: Array = []
var _hits: Array = []
var _ok := true
var _rows: Array[String] = []

func _ready() -> void:
	ImpactResolver.wall_decided.connect(func(f: Node3D, w: Node3D, outcome: StringName, e: float, _p: Vector3) -> void:
		_decisions.append({"fighter": f, "wall": w, "outcome": outcome, "energy": e}))
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void: _hits.append(info))
	WorldTestUtil.make_floor(self, 200.0)
	await get_tree().physics_frame
	if not await WorldTestUtil.real_ragdoll_available(self):
		print("[realkick] FAIL: real ragdoll unavailable")
		get_tree().quit(1)
		return
	var lane := 0
	var heavy: Dictionary = Tuning.R7_MOVES[&"heavy_roundhouse"]
	var heavy_expect := {&"drywall": &"break", &"brick": &"crack", &"concrete": &"bounce"}
	for surface: StringName in [&"drywall", &"brick", &"concrete"]:
		await _case([&"heavy_roundhouse"], "heavy roundhouse   ", float(heavy["launch_speed"]),
			float(heavy["launch_angle"]), surface, heavy_expect[surface], lane)
		lane += 1
	var payoff: Dictionary = Tuning.R7_PAYOFFS[&"roundhouse"][&"lift"]
	var payoff_expect := {&"drywall": &"break", &"brick": &"break", &"concrete": &"crack"}
	for surface: StringName in [&"drywall", &"brick", &"concrete"]:
		await _case([&"uppercut", &"roundhouse"], "uppercut->roundhouse", float(payoff["launch_speed"]),
			float(payoff["launch_angle"]), surface, payoff_expect[surface], lane)
		lane += 1
	print("")
	for r in _rows:
		print("[realkick] ", r)
	print("[realkick] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

## Play `moves` from the attacker on the victim (each starts once the previous
## one has hit and finished: play_move never cancels a move), then read the last
## hit's launch and the panel's decision.
func _case(moves: Array, label: String, want_v: float, want_angle: float, surface: StringName,
		expect: StringName, lane: int) -> void:
	_decisions.clear()
	_hits.clear()
	var z := float(lane) * 12.0
	var victim := FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis.looking_at(Vector3(1, 0, 0)),
		Vector3(0, 0.05, z)), Fighter.TEAM_ENEMY)
	var attacker := FighterFactory.spawn_dummy(self, &"player",
		Transform3D(Basis.looking_at(Vector3(-1, 0, 0)), Vector3(1.1, 0.05, z)), Fighter.TEAM_PLAYER)
	for i in 20:
		await get_tree().physics_frame
	var com := victim.get_center_of_mass()
	var panel := WorldTestUtil.make_panel(self, surface, Vector3(com.x - WALL_DIST - 0.125, 0, z))
	await get_tree().physics_frame
	var info: HitInfo = null
	for i in moves.size():
		if i > 0:
			var tw := TimeDirector.now()
			while attacker.combat.is_attacking() and TimeDirector.now() - tw < 1.0:
				await get_tree().physics_frame
		_hits.clear()
		attacker.combat.play_move(moves[i], victim)
		var t0 := TimeDirector.now()
		while _hits.is_empty() and TimeDirector.now() - t0 < 1.5:
			await get_tree().physics_frame
		info = _hits[0] if not _hits.is_empty() else null
	var t1 := TimeDirector.now()
	var dec: Dictionary = {}
	while TimeDirector.now() - t1 < 2.0 and dec.is_empty():
		await get_tree().physics_frame
		for d: Dictionary in _decisions:
			if d["wall"] == panel and d["fighter"] == victim:
				dec = d
	var e: float = dec.get("energy", -1.0)
	var outcome: StringName = dec.get("outcome", &"none")
	var lv := info.launch_velocity if info else Vector3.ZERO
	var angle := rad_to_deg(asin(clampf(lv.normalized().y, -1.0, 1.0))) if lv.length() > 0.01 else 0.0
	var react: StringName = info.react if info else &"-"
	var ok := outcome == expect and react == &"launch" and absf(lv.length() - want_v) < SPEED_TOL \
		and absf(angle - want_angle) < 2.0
	var spec_e := 0.5 * victim.get_total_mass() * pow(want_v * cos(deg_to_rad(want_angle)), 2.0)
	_rows.append("%s %-8s react=%s launch %.2f m/s at %.1f deg (want %.0f at %.0f) -> E=%6.0f J (table %5.0f) -> %-6s (expect %-6s) %s" % [
		label, surface, react, lv.length(), angle, want_v, want_angle, e, spec_e, outcome, expect,
		"PASS" if ok else "FAIL"])
	print("[realkick] ", _rows[_rows.size() - 1])
	_ok = _ok and ok
	victim.queue_free()
	attacker.queue_free()
	panel.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

func _wait(seconds: float) -> void:
	var t0 := TimeDirector.now()
	while TimeDirector.now() - t0 < seconds:
		await get_tree().physics_frame
