extends Node3D
## Worked example with REAL moves (round 2): a player Fighter sparta-kicks a
## 70 kg Grunt standing 2 m (COM) in front of a single panel. Standing kick
## (Tuning.KICK_LAUNCH) and dash-in kick, into drywall, brick and concrete.
## Prints the launch speed, the measured wall energy and the outcome.
## Expected (spec table): standing kick breaks drywall and bounces off brick
## and concrete; a dash kick breaks drywall and cracks brick.

const WALL_DIST := 2.0
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
		print("[realkick] SKIP: real ragdoll unavailable")
		get_tree().quit(1)
		return
	var lane := 0
	for dash in [false, true]:
		for surface: StringName in [&"drywall", &"brick", &"concrete"]:
			var expect: StringName = &"bounce"
			if surface == &"drywall":
				expect = &"break"
			elif surface == &"brick" and dash:
				expect = &"crack"
			await _case(surface, dash, expect, lane)
			lane += 1
	print("")
	for r in _rows:
		print("[realkick] ", r)
	print("[realkick] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _case(surface: StringName, dash: bool, expect: StringName, lane: int) -> void:
	_decisions.clear()
	_hits.clear()
	var z := float(lane) * 12.0
	var victim := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis.looking_at(Vector3(1, 0, 0)), Vector3(0, 0.05, z)))
	var attacker := FighterFactory.spawn_dummy(self, &"player",
		Transform3D(Basis.looking_at(Vector3(-1, 0, 0)), Vector3(3.6 if dash else 1.3, 0.05, z)), Fighter.TEAM_PLAYER)
	for i in 20:
		await get_tree().physics_frame
	var com := victim.get_center_of_mass()
	var panel := WorldTestUtil.make_panel(self, surface, Vector3(com.x - WALL_DIST - 0.125, 0, z))
	await get_tree().physics_frame
	if dash:
		attacker.move_input = attacker.get_forward()
		attacker.combat.press(CombatController.Action.DASH)
		await _wait(0.12)
		attacker.move_input = Vector3.ZERO
	attacker.combat.press(CombatController.Action.KICK)
	var t0 := TimeDirector.now()
	while _hits.is_empty() and TimeDirector.now() - t0 < 1.5:
		await get_tree().physics_frame
	var launch := -1.0
	if not _hits.is_empty():
		launch = (_hits[0] as HitInfo).launch_velocity.length()
	var t1 := TimeDirector.now()
	var dec: Dictionary = {}
	while TimeDirector.now() - t1 < 2.0 and dec.is_empty():
		await get_tree().physics_frame
		for d: Dictionary in _decisions:
			if d["wall"] == panel and d["fighter"] == victim:
				dec = d
	var e: float = dec.get("energy", -1.0)
	var outcome: StringName = dec.get("outcome", &"none")
	var ok := outcome == expect
	var label := "dash-in kick" if dash else "standing kick"
	_rows.append("%-13s %-8s launch %.2f m/s -> E=%6.0f J -> %-6s (expect %-6s) %s" % [
		label, surface, launch, e, outcome, expect, "PASS" if ok else "FAIL"])
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
