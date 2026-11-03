extends Node3D
## Round 7 throws into walls ("the thrown body is the existing projectile:
## walls"), by the wall table (E = 1/2 M v^2 into the face, cracks at
## CRACK_FRACTION): a tap leaves at R7_THROW_SPEED_MIN (8 m/s, ~2,400 J for a
## 75 kg grunt): it breaks drywall (2,000 J) and does not break brick (6,000 J);
## a full wind-up leaves at R7_THROW_SPEED_MAX (18 m/s, ~12,000 J) and breaks brick.
## The player holds a grunt by the collar 2.2 m from a real panel (Destructible
## + ImpactResolver, agent D) and throws it with LIGHT through CombatController's
## routing. Logs ImpactResolver's decision and energy.
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
	var tap: Dictionary = await _throw(&"drywall", false, 0.0)
	_check(tap["outcome"] == &"break", "a tapped throw (8 m/s) breaks drywall (%s, %.0f J)" % [tap["outcome"], tap["energy"]])
	var btap: Dictionary = await _throw(&"brick", false, 40.0)
	var bfull: Dictionary = await _throw(&"brick", true, 60.0)
	_check(btap["outcome"] != &"break", "a tapped throw does not break brick (%s, %.0f J)" % [btap["outcome"], btap["energy"]])
	_check(bfull["outcome"] == &"break", "a full wind-up throw (18 m/s) breaks brick (%s, %.0f J)" % [bfull["outcome"], bfull["energy"]])
	_finish()

func _throw(surface: StringName, full: bool, x: float) -> Dictionary:
	GrabTestUtil.reset_world()
	_decisions.clear()
	var p := GrabTestUtil.spawn(self, &"player", Vector3(x, 0.0, 0.0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := GrabTestUtil.spawn(self, &"grunt", Vector3(x, 0.0, -1.0), Vector3.BACK)
	var wall := GrabTestUtil.make_panel(self, surface, Vector3(x, 0.0, -WALL_DIST - 0.125), Vector3.BACK)
	await GrabTestUtil.frames(self, 20)
	p.carry.grab_now(e, &"", true)
	await GrabTestUtil.wait(self, 0.35)
	var held := p.carry.is_holding_body()
	if not full:
		await GrabTestUtil.tap(self, p, CombatController.Action.LIGHT, 0.05)
	else:
		GrabTestUtil.press(p, CombatController.Action.LIGHT)
		await GrabTestUtil.wait(self, Tuning.R7_THROW_WINDUP_FULL + 0.05)
		GrabTestUtil.release(p, CombatController.Action.LIGHT)
	var v := p.carry.last_throw_velocity
	await GrabTestUtil.wait_until(self, func() -> bool: return not _decisions.is_empty(), 1.0)
	await GrabTestUtil.wait(self, 0.3)
	var d: Dictionary = _decisions[0] if not _decisions.is_empty() else {"outcome": &"none", "energy": 0.0}
	var m := e.get_total_mass()
	print("[%s] %s throw (wind-up %.2f, held=%s) at %.2f m/s, %.0f kg body: wall %s at %.0f J (1/2 M v^2 = %.0f J); crack from %.0f J, break %.0f J; wall broken=%s" % [
		surface, "full wind-up" if full else "tapped", p.carry.last_throw_windup, held, v.length(), m, d["outcome"], d["energy"],
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
