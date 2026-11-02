extends Node3D
## F9 acceptance: "A 16 m/s throw into 3 grunts in a line knocks down or
## launches at least 2." (Feel Reference: under 6 m/s a stagger, 6-10 a
## knockdown, 10+ a launch, -40% speed per hit: 16 -> launch, 9.6 -> knockdown,
## 5.8 -> stagger.) The thrown body is a projectile for ImpactResolver (agent D).
## Case 1: Carry.throw_at() exactly 16 m/s along the line.
## Case 2: the real input at full sprint: hold a body, sprint at the line,
## charge Heavy to level 3 and release (Power.throw_speed(3, run) = 16 m/s:
## carrying's top speed counts as full sprint) when Traversal sprints.
## Logs every bowl hit (tier, flyer speed) and each grunt's state.
## OWNER: agent G.

const LINE_START := 3.0   ## m from the thrower to the first grunt
const LINE_GAP := 1.3     ## m between grunts

var _fail: Array[String] = []
var _hits: Array[HitInfo] = []
var _bowl_speeds: Array[float] = []

func _ready() -> void:
	get_tree().create_timer(150.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	Carry.force_enabled = true
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void: _hits.append(info))
	if ImpactResolver.has_signal(&"bowl_dealt"):
		ImpactResolver.connect(&"bowl_dealt", func(_f: Node3D, _v: Node3D, speed: float, _t: int, _i: HitInfo) -> void:
			_bowl_speeds.append(speed))
	GrabTestUtil.make_floor(self)
	await get_tree().physics_frame
	await _scripted()
	await _sprint_charge()
	_finish()

func _line(origin: Vector3) -> Array[Fighter]:
	var out: Array[Fighter] = []
	for i in 3:
		out.append(GrabTestUtil.spawn(self, &"grunt", origin + Vector3(0.0, 0.0, -(LINE_START + LINE_GAP * i)), Vector3.BACK))
	return out

func _report(label: String, flyer: Fighter, line: Array[Fighter], v: Vector3) -> int:
	var down := 0
	var states: Array[String] = []
	for g in line:
		var hit := _hits.filter(func(h: HitInfo) -> bool: return h.victim == g and h.move_id == &"bowl")
		var tier := HitInfo.tier_name((hit[0] as HitInfo).tier) if hit.size() > 0 else &"-"
		var is_down := g.is_down() or (hit.size() > 0 and (hit[0] as HitInfo).tier >= HitInfo.Tier.KNOCKDOWN)
		if is_down:
			down += 1
		states.append("%s %s (%s)" % [g.name, tier, GrabTestUtil.state_name(g)])
	print("[%s] thrown %s at %.2f m/s: %s -> %d of 3 knocked down or launched; flyer speed at each hit: %s" % [label,
		flyer.name, v.length(), ", ".join(states), down, ", ".join(_bowl_speeds.map(func(x: float) -> String: return "%.1f" % x))])
	return down

func _scripted() -> void:
	GrabTestUtil.reset_world()
	_hits.clear()
	_bowl_speeds.clear()
	var p := GrabTestUtil.spawn(self, &"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := GrabTestUtil.spawn(self, &"grunt", Vector3(0.0, 0.0, -1.0), Vector3.BACK)
	var line := _line(Vector3(0.0, 0.0, 0.0))
	await GrabTestUtil.frames(self, 20)
	p.carry.grab_now(e, &"", true)
	await GrabTestUtil.wait(self, 0.35)
	var a := deg_to_rad(Tuning.THROW_UP_ANGLE)
	var v := (Vector3.FORWARD * cos(a) + Vector3.UP * sin(a)) * 16.0
	_check(p.carry.throw_at(v), "throw_at accepted")
	await GrabTestUtil.wait(self, 1.2)
	var down := _report("16 m/s", e, line, v)
	_check(down >= 2, "a 16 m/s throw into 3 grunts in a line downs at least 2")
	for n in [p, e] + line:
		n.queue_free()
	await GrabTestUtil.frames(self, 4)

func _sprint_charge() -> void:
	GrabTestUtil.reset_world()
	_hits.clear()
	_bowl_speeds.clear()
	# A long lane: the sprint ramp (~1.2 s) and a level-3 charge at a sprint
	# (1.0 s, you cannot stop) cover ~15 m; the line must still be ahead.
	var p := GrabTestUtil.spawn(self, &"player", Vector3(30.0, 0.0, 17.0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := GrabTestUtil.spawn(self, &"grunt", Vector3(30.0, 0.0, 16.0), Vector3.BACK)
	var line := _line(Vector3(30.0, 0.0, 0.0))
	await GrabTestUtil.frames(self, 20)
	if p.traversal == null:
		print("[sprint] SKIP: no Traversal")
		for n in [p, e] + line:
			n.queue_free()
		return
	p.carry.grab_now(e, &"", true)
	await GrabTestUtil.wait(self, 0.12)   # the whole run fits inside Tuning.HOLD_MAX
	p.move_input = Vector3.FORWARD
	p.face_dir = Vector3.FORWARD
	GrabTestUtil.press(p, CombatController.Action.DASH)
	# Full earned sprint (sprint_charge 1), not the opening dash burst.
	var top := await GrabTestUtil.wait_until(self, func() -> bool:
		return p.traversal.sprint_charge >= 0.999, 3.0)
	# Charge to level 3 on the run and release.
	GrabTestUtil.press(p, CombatController.Action.HEAVY)
	var t0 := TimeDirector.now()
	await GrabTestUtil.wait_until(self, func() -> bool:
		return TimeDirector.now() - t0 >= Tuning.CHARGE_LEVELS[2] + 0.02, 2.0)
	var gap := p.global_position.z - line[0].global_position.z
	var run := p.traversal.speed_toward(Vector3.FORWARD)
	var held_t := p.carry.get_hold_time()
	var hold_cap := p.traversal.get_speed_cap()
	var lvl := p.carry.get_charge_level()
	GrabTestUtil.release(p, CombatController.Action.HEAVY)
	GrabTestUtil.release(p, CombatController.Action.DASH)
	p.move_input = Vector3.ZERO
	var v := p.carry.last_throw_velocity
	print("[sprint] sprint_charge 1 reached=%s, %.1f m from the line, held %.2f s, earned run %.2f m/s (holding cap %.2f = %.0f%% of %.1f), charge level %d -> throw %.2f m/s (Power.throw_speed(3, cap) = %.2f)" % [
		top, gap, held_t, run, hold_cap, 100.0 * Tuning.HOLD_SPRINT_MULT, Tuning.debug_speed_cap, lvl, v.length(), Power.throw_speed(3, Tuning.debug_speed_cap)])
	await GrabTestUtil.wait(self, 1.2)
	var down := _report("full-sprint L3", e, line, v)
	_check(lvl == 3 and absf(v.length() - Tuning.THROW_SPEED_CAP) < 0.3, "a level-3 throw at full sprint leaves at 16 m/s")
	_check(down >= 2, "the full-sprint level-3 throw downs at least 2 of 3")
	for n in [p, e] + line:
		if is_instance_valid(n):
			n.queue_free()
	await GrabTestUtil.frames(self, 4)

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	Carry.force_enabled = false
	if _fail.is_empty():
		print("PASS test_throw_bowl")
		get_tree().quit(0)
	else:
		print("FAIL test_throw_bowl: ", _fail)
		get_tree().quit(1)
