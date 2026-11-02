extends Node3D
## F9 acceptance: "A tapped standing throw only cracks drywall; a level-3
## charged standing throw breaks it." (Feel Reference: throws are no stronger
## than strikes: 6 m/s -> 1,260 J cracks drywall; 12 m/s -> 5,040 J breaks
## drywall and cracks brick; 16 m/s at full sprint -> 8,960 J breaks brick.)
## The player holds a grunt by the collar 2.2 m from a real drywall panel
## (Destructible + ImpactResolver, agent D) and throws it with Heavy: a tap,
## then a level-3 charge. Logs ImpactResolver's decision and energy. Then the
## same two throws at brick: the tap does nothing to it, level 3 cracks it.
## OWNER: agent G.

const WALL_DIST := 2.2   ## m from the player to the panel's face

var _fail: Array[String] = []
var _decisions: Array = []

func _ready() -> void:
	get_tree().create_timer(150.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	Carry.force_enabled = true
	ImpactResolver.wall_decided.connect(func(f: Node3D, w: Node3D, outcome: StringName, e: float, _p: Vector3) -> void:
		_decisions.append({"fighter": f, "wall": w, "outcome": outcome, "energy": e}))
	GrabTestUtil.make_floor(self)
	await get_tree().physics_frame
	var tap: Dictionary = await _throw(&"drywall", 0, 0.0)
	var l3: Dictionary = await _throw(&"drywall", 3, 20.0)
	_check(tap["outcome"] == &"crack", "a tapped standing throw cracks drywall (%s, %.0f J)" % [tap["outcome"], tap["energy"]])
	_check(l3["outcome"] == &"break", "a level-3 charged standing throw breaks drywall (%s, %.0f J)" % [l3["outcome"], l3["energy"]])
	var btap: Dictionary = await _throw(&"brick", 0, 40.0)
	var bl3: Dictionary = await _throw(&"brick", 3, 60.0)
	_check(btap["outcome"] != &"break" and btap["outcome"] != &"crack", "a tapped throw does not mark brick (%s)" % btap["outcome"])
	_check(bl3["outcome"] == &"crack", "a level-3 throw cracks brick, no break (%s, %.0f J)" % [bl3["outcome"], bl3["energy"]])
	_finish()

func _throw(surface: StringName, level: int, x: float) -> Dictionary:
	GrabTestUtil.reset_world()
	_decisions.clear()
	var p := GrabTestUtil.spawn(self, &"player", Vector3(x, 0.0, 0.0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := GrabTestUtil.spawn(self, &"grunt", Vector3(x, 0.0, -1.0), Vector3.BACK)
	var wall := GrabTestUtil.make_panel(self, surface, Vector3(x, 0.0, -WALL_DIST - 0.125), Vector3.BACK)
	await GrabTestUtil.frames(self, 20)
	p.carry.grab_now(e, &"", true)
	await GrabTestUtil.wait(self, 0.35)
	var held := p.carry.is_holding_body()
	if level == 0:
		await GrabTestUtil.tap(self, p, CombatController.Action.HEAVY, 0.05)
	else:
		GrabTestUtil.press(p, CombatController.Action.HEAVY)
		await GrabTestUtil.wait(self, Tuning.CHARGE_LEVELS[level - 1] + 0.05)
		GrabTestUtil.release(p, CombatController.Action.HEAVY)
	var v := p.carry.last_throw_velocity
	await GrabTestUtil.wait_until(self, func() -> bool: return not _decisions.is_empty(), 1.0)
	await GrabTestUtil.wait(self, 0.3)
	var d: Dictionary = _decisions[0] if not _decisions.is_empty() else {"outcome": &"none", "energy": 0.0}
	var m := e.get_total_mass()
	print("[%s] %s throw (level %d, held=%s) at %.2f m/s, %.0f kg body: wall %s at %.0f J (1/2 M v^2 = %.0f J); crack from %.0f J, break %.0f J; wall broken=%s" % [
		surface, "tapped" if level == 0 else "charged", p.carry.last_throw_level, held, v.length(), m, d["outcome"], d["energy"],
		0.5 * m * v.length_squared(), wall.get_crack_threshold(), Tuning.SURFACES[surface]["break_energy"], wall.is_broken])
	p.queue_free()
	e.queue_free()
	wall.queue_free()
	await GrabTestUtil.frames(self, 4)
	return d

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	Carry.force_enabled = false
	if _fail.is_empty():
		print("PASS test_throw_walls")
		get_tree().quit(0)
	else:
		print("FAIL test_throw_walls: ", _fail)
		get_tree().quit(1)
