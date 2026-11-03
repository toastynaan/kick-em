extends Node3D
## F9 acceptance, Round 7 speeds: "a thrown body is the existing projectile:
## bowling". Under 6 m/s a stagger, 6-10 a knockdown, 10+ a launch, -40% speed
## per hit (ImpactResolver, agent D).
## Case 1: Carry.throw_at() exactly R7_THROW_SPEED_MAX (18 m/s) along a line of
## 3 grunts, pitched R7_THROW_PITCH: at least 2 knocked down or launched.
## Case 2: the real input: hold a grunt, hold LMB for a full wind-up
## (Input.action_press(&"punch") -> PlayerController -> Carry), the camera
## looking down the line: the throw leaves at 18 m/s and downs at least 2 of 3.
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
	await _full_windup()
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
	var a := deg_to_rad(Tuning.R7_THROW_PITCH)
	var v := (Vector3.FORWARD * cos(a) + Vector3.UP * sin(a)) * Tuning.R7_THROW_SPEED_MAX
	_check(p.carry.throw_at(v), "throw_at accepted")
	await GrabTestUtil.wait(self, 1.2)
	var down := _report("18 m/s", e, line, v)
	_check(down >= 2, "an 18 m/s throw into 3 grunts in a line downs at least 2")
	for n in [p, e] + line:
		n.queue_free()
	await GrabTestUtil.frames(self, 4)

func _full_windup() -> void:
	GrabTestUtil.reset_world()
	GrabTestUtil.release_all_input()
	_hits.clear()
	_bowl_speeds.clear()
	var p := GrabTestUtil.spawn_player(self, Vector3(30.0, 0.0, 0.0), Vector3.FORWARD)
	var cam := GrabTestUtil.make_camera(self, p, Vector3.FORWARD)
	var e := GrabTestUtil.spawn(self, &"grunt", Vector3(30.0, 0.0, -1.0), Vector3.BACK)
	var line := _line(Vector3(30.0, 0.0, 0.0))
	await GrabTestUtil.frames(self, 20)
	p.carry.grab_now(e, &"", true)
	await GrabTestUtil.wait(self, 0.35)
	await GrabTestUtil.key_tap(self, &"punch", int(round(Tuning.R7_THROW_WINDUP_FULL * 120.0)) + 2)
	var v := p.carry.last_throw_velocity
	print("[wind-up] full wind-up %.2f -> throw %.2f m/s (assist %s)" % [p.carry.last_throw_windup, v.length(),
		p.carry.last_throw_assist.name if p.carry.last_throw_assist else "-"])
	await GrabTestUtil.wait(self, 1.2)
	var down := _report("full wind-up", e, line, v)
	_check(absf(v.length() - Tuning.R7_THROW_SPEED_MAX) < 0.5, "a full wind-up throw leaves at 18 m/s")
	_check(down >= 2, "the full wind-up throw downs at least 2 of 3")
	GrabTestUtil.release_all_input()
	for n in [p, e, cam] + line:
		if is_instance_valid(n):
			n.queue_free()
	await GrabTestUtil.frames(self, 4)

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	Carry.force_enabled = false
	GrabTestUtil.release_all_input()
	if _fail.is_empty():
		print("PASS test_throw_bowl")
		get_tree().quit(0)
	else:
		print("FAIL test_throw_bowl: ", _fail)
		get_tree().quit(1)
