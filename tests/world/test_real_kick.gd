extends Node3D
## Round 5 worked examples through REAL strikes (Feel Reference: Launch speed and
## walls). A player Fighter charges a strike to level 3 on a 70 kg dummy whose
## COM stands 2 m in front of a single panel; B's power score sets the tier and
## launch, the wall decides on E = 1/2 M v^2 straight into it.
##   level-3 standing kick:  P = 2.5 x 3.2 = 8.0, hard launch 12 m/s at 18 deg,
##     4,559 J: breaks drywall, cracks brick, bounces off concrete.
##   level-3 standing cross: P = 2.0 x 3.2 = 6.4, launch 8.8 m/s at 30 deg,
##     2,033 J: breaks drywall ("just"), bounces off brick.
## Prints P, tier, the launch speed, the measured wall energy and the outcome.

const WALL_DIST := 2.0
const HOLD := 1.05          ## s: past CHARGE_LEVELS[2] (1.0 s) = level 3
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
	var kick_expect := {&"drywall": &"break", &"brick": &"crack", &"concrete": &"bounce"}
	for surface: StringName in [&"drywall", &"brick", &"concrete"]:
		await _case(CombatController.Action.KICK, "L3 kick ", 8.0, surface, kick_expect[surface], lane)
		lane += 1
	var cross_expect := {&"drywall": &"break", &"brick": &"bounce"}
	for surface: StringName in [&"drywall", &"brick"]:
		await _case(CombatController.Action.HEAVY, "L3 cross", 6.4, surface, cross_expect[surface], lane)
		lane += 1
	print("")
	for r in _rows:
		print("[realkick] ", r)
	print("[realkick] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _case(action: int, label: String, want_p: float, surface: StringName, expect: StringName, lane: int) -> void:
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
	attacker.combat.force_hold_charge = true   # tap vs hold like the player's buttons
	attacker.combat.press(action)
	await _wait(HOLD)
	attacker.combat.release(action)
	var t0 := TimeDirector.now()
	while _hits.is_empty() and TimeDirector.now() - t0 < 1.5:
		await get_tree().physics_frame
	var info: HitInfo = _hits[0] if not _hits.is_empty() else null
	var t1 := TimeDirector.now()
	var dec: Dictionary = {}
	while TimeDirector.now() - t1 < 2.0 and dec.is_empty():
		await get_tree().physics_frame
		for d: Dictionary in _decisions:
			if d["wall"] == panel and d["fighter"] == victim:
				dec = d
	var e: float = dec.get("energy", -1.0)
	var outcome: StringName = dec.get("outcome", &"none")
	var p := info.power if info else -1.0
	var lv := info.launch_velocity if info else Vector3.ZERO
	var ok := outcome == expect and absf(p - want_p) < 0.05
	var spec_e := 0.5 * victim.get_total_mass() * pow(Power.launch_speed(want_p) * cos(deg_to_rad(Power.launch_angle(want_p))), 2.0)
	_rows.append("%s %-8s P=%.2f (want %.1f) tier=%s launch %.2f m/s at %.0f deg -> E=%6.0f J (table %5.0f) -> %-6s (expect %-6s) %s" % [
		label, surface, p, want_p, HitInfo.tier_name(info.tier) if info else &"-", lv.length(),
		rad_to_deg(asin(clampf(lv.normalized().y, -1.0, 1.0))) if lv.length() > 0.01 else 0.0, e, spec_e, outcome, expect,
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
