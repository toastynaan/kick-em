extends Node3D
## Round 7 drive rules (Grab, drive and throw: "Drive") on flat ground with
## built walls and real Destructible panels (agent D), the run being
## Traversal's (agent M). The press is Carry.on_drive_pressed (the input
## routing is test_drive_yard's):
## - two drywall panels in a row both break: the drive goes through both and
##   keeps driving (speed x sqrt(1 - absorption) at each);
## - a wall met at 55 degrees from the line at the start of the drive: vn under
##   R7_DRIVE_SLAM_MIN_SPEED is a shove (stagger, the hold ends, drive_ended shove);
## - a wall alongside the lane (grazed) neither slams nor shoves; the wall at
##   the lane's end still slams;
## - R7_DRIVE_MAX_TIME: the body is thrown forward at the drive speed
##   (drive_ended timeout, GameEvents.thrown);
## - a hit on the player ends the drive and the hold (drive_ended hit);
## - a killing slam kills (and logs whether R7_SEVER_ON_KILL took a limb); a
##   driven corpse slams with no damage and the hold ends.
## OWNER: agent G.

var _fail: Array[String] = []
var _impacts: Array = []
var _ends: Array[StringName] = []
var _thrown: Array = []
var _severed: Array = []

func _ready() -> void:
	get_tree().create_timer(200.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	Carry.force_enabled = true
	GameEvents.drive_impact.connect(func(_h: Node3D, _v: Node3D, t: Node3D, _p: Vector3, speed: float, result: StringName) -> void:
		_impacts.append({"target": t, "speed": speed, "result": result}))
	GameEvents.drive_ended.connect(func(_h: Node3D, reason: StringName) -> void: _ends.append(reason))
	GameEvents.thrown.connect(func(g: Node3D, v: Node3D, vel: Vector3) -> void: _thrown.append([g, v, vel]))
	GameEvents.limb_severed.connect(func(f: Node3D, cut: StringName, _p: Node3D) -> void: _severed.append([f, cut]))
	GrabTestUtil.make_floor(self, 600.0)
	await get_tree().physics_frame
	await _two_panels(Vector3(-100.0, 0.0, 100.0))
	await _shove(Vector3(-50.0, 0.0, 100.0))
	await _graze(Vector3(0.0, 0.0, 100.0))
	await _timeout(Vector3(50.0, 0.0, 150.0))
	await _hit(Vector3(100.0, 0.0, 100.0))
	await _killing_slam(Vector3(150.0, 0.0, 100.0))
	await _corpse_slam(Vector3(200.0, 0.0, 100.0))
	_finish()

## A player-team fighter (with Traversal) at `at` facing -Z holding a grunt.
func _pair(at: Vector3) -> Array:
	GrabTestUtil.reset_world()
	_impacts.clear()
	_ends.clear()
	_thrown.clear()
	var p := GrabTestUtil.spawn(self, &"player", at, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := GrabTestUtil.spawn(self, &"grunt", at + Vector3(0.0, 0.0, -1.0), Vector3.BACK)
	await GrabTestUtil.frames(self, 20)
	p.carry.grab_now(e, &"", true)
	await GrabTestUtil.wait(self, 0.3)
	return [p, e]

func _drive(p: Fighter) -> bool:
	p.carry.on_drive_pressed(TimeDirector.now())
	return await GrabTestUtil.wait_until(self, func() -> bool: return p.carry.is_driving(), 0.2)

func _clear(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	await GrabTestUtil.frames(self, 6)

func _results() -> Array:
	return _impacts.map(func(i: Dictionary) -> StringName: return i["result"])

func _log() -> String:
	return ", ".join(_impacts.map(func(i: Dictionary) -> String: return "%s %.2f m/s" % [i["result"], i["speed"]]))

func _two_panels(at: Vector3) -> void:
	var pr: Array = await _pair(at)
	var p: Fighter = pr[0]
	var a := GrabTestUtil.make_panel(self, &"drywall", at + Vector3(0.0, 0.0, -6.0), Vector3.BACK)
	var b := GrabTestUtil.make_panel(self, &"drywall", at + Vector3(0.0, 0.0, -10.5), Vector3.BACK)
	await GrabTestUtil.frames(self, 3)
	var driving := await _drive(p)
	await GrabTestUtil.wait_until(self, func() -> bool:
		return _results().count(&"break") >= 2 or not p.carry.is_driving(), 2.5)
	await GrabTestUtil.frames(self, 3)
	var still := p.carry.is_driving() and p.carry.is_holding_body()
	var speed := p.carry.get_drive_speed()
	p.carry.on_drive_released(TimeDirector.now())
	var breaks: Array = _impacts.filter(func(i: Dictionary) -> bool: return i["result"] == &"break")
	print("[two panels] driving=%s, contacts: %s; after the second: driving=%s at %.2f m/s; panels broken/holed %s %s" % [
		driving, _log(), still, speed, a.is_broken or a.is_point_open(at + Vector3(0, 1.0, -6.0)),
		b.is_broken or b.is_point_open(at + Vector3(0, 1.0, -10.5))])
	_check(breaks.size() == 2 and breaks[0]["target"] == a and breaks[1]["target"] == b, "both drywall panels break in one drive")
	_check(still, "the drive goes on after both")
	await _clear(pr + [a, b])

func _shove(at: Vector3) -> void:
	var pr: Array = await _pair(at)
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var basis := Basis(Vector3.UP, deg_to_rad(55.0))
	var n := basis.z
	var face := at + Vector3(0.0, 0.0, -1.25)
	var wall := GrabTestUtil.make_wall(self, face - n * 0.2 + Vector3.UP * 1.5, Vector3(5.0, 3.0, 0.4))
	wall.basis = basis
	await GrabTestUtil.frames(self, 3)
	var hp0 := e.hp
	await _drive(p)
	await GrabTestUtil.wait_until(self, func() -> bool: return not p.carry.is_holding(), 1.0)
	await GrabTestUtil.wait(self, 0.15)
	var res := _results()
	var sh: Dictionary = _impacts[0] if not _impacts.is_empty() else {}
	print("[shove] wall at 55 deg: contacts %s, drive ended %s, holding=%s, victim %s reacting=%s down=%s -%.1f HP" % [_log(), _ends,
		p.carry.is_holding(), GrabTestUtil.state_name(e), e.is_reacting(), e.is_down(), hp0 - e.hp])
	_check(res == [&"shove"] and float(sh.get("speed", 9.0)) < Tuning.R7_DRIVE_SLAM_MIN_SPEED,
		"under R7_DRIVE_SLAM_MIN_SPEED into the wall it is a shove")
	_check(_ends == [&"shove"] and not p.carry.is_holding() and not e.carry.is_held(), "the shove ends the drive and the hold")
	_check(not e.is_down(), "the shoved victim stays on its feet (stagger)")
	await _clear(pr + [wall])

func _graze(at: Vector3) -> void:
	var pr: Array = await _pair(at)
	var p: Fighter = pr[0]
	var side := GrabTestUtil.make_wall(self, at + Vector3(0.5, 1.5, -6.0), Vector3(0.4, 3.0, 14.0))
	var end := GrabTestUtil.make_wall(self, at + Vector3(0.0, 1.5, -9.2), Vector3(4.0, 3.0, 0.4))
	await GrabTestUtil.frames(self, 3)
	await _drive(p)
	await GrabTestUtil.wait_until(self, func() -> bool: return not p.carry.is_holding(), 2.5)
	print("[graze] wall 0.3 m beside the lane, a wall across at its end: contacts %s, drive ended %s" % [_log(), _ends])
	_check(_results() == [&"slam"] and _ends == [&"slam"], "the wall alongside is slid along; the wall across slams")
	await _clear(pr + [side, end])

func _timeout(at: Vector3) -> void:
	var pr: Array = await _pair(at)
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var t0 := TimeDirector.now()
	await _drive(p)
	var last := {"v": 0.0}
	await GrabTestUtil.wait_until(self, func() -> bool:
		if p.carry.is_driving():
			last["v"] = p.carry.get_drive_speed()
		return not p.carry.is_holding(), Tuning.R7_DRIVE_MAX_TIME + 1.0)
	var t := TimeDirector.now() - t0
	var vel: Vector3 = _thrown[0][2] if not _thrown.is_empty() else Vector3.ZERO
	var pitch := rad_to_deg(atan2(vel.y, Vector2(vel.x, vel.z).length()))
	await GrabTestUtil.frames(self, 2)
	print("[timeout] drive held %.2f s (R7_DRIVE_MAX_TIME %.1f): drive ended %s, thrown %d at %.2f m/s (drive speed %.2f), pitch %.1f deg, body %.2f m/s" % [
		t, Tuning.R7_DRIVE_MAX_TIME, _ends, _thrown.size(), vel.length(), last["v"], pitch, e.get_com_velocity().length()])
	_check(absf(t - Tuning.R7_DRIVE_MAX_TIME) < 0.1 and _ends == [&"timeout"], "at R7_DRIVE_MAX_TIME the drive ends (timeout)")
	_check(_thrown.size() == 1 and absf(vel.length() - float(last["v"])) < 0.3 and vel.dot(Vector3.FORWARD) > 0.0,
		"the body is thrown forward at the drive speed")
	await _clear(pr)

func _hit(at: Vector3) -> void:
	var pr: Array = await _pair(at)
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var other := GrabTestUtil.spawn(self, &"grunt", at + Vector3(3.0, 0.0, -3.0), Vector3.LEFT)
	await GrabTestUtil.frames(self, 5)
	await _drive(p)
	await GrabTestUtil.wait(self, 0.4)
	var info := HitInfo.new()
	info.attacker = other
	info.victim = p
	info.move_id = &"e_jab"
	info.kind = &"strike"
	info.tier = HitInfo.Tier.FLINCH
	info.reaction = HitInfo.Reaction.FLINCH
	info.damage = 10.0
	info.hit_direction = Vector3.LEFT
	info.hit_position = p.get_aim_point()
	info.unblockable = true
	p.take_hit(info)
	await GrabTestUtil.frames(self, 3)
	print("[hit] hit while driving: drive ended %s, driving=%s, holding=%s, victim held=%s, traversal driving=%s" % [_ends,
		p.carry.is_driving(), p.carry.is_holding(), e.carry.is_held(), p.traversal.is_driving()])
	_check(_ends == [&"hit"] and not p.carry.is_driving() and not p.carry.is_holding() and not e.carry.is_held(),
		"a hit on the player ends the drive and the hold")
	await _clear(pr + [other])

func _killing_slam(at: Vector3) -> void:
	var pr: Array = await _pair(at)
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	e.hp = 5.0
	var wall := GrabTestUtil.make_wall(self, at + Vector3(0.0, 1.5, -5.5), Vector3(4.0, 3.0, 0.4))
	_severed.clear()
	await GrabTestUtil.frames(self, 3)
	await _drive(p)
	await GrabTestUtil.wait_until(self, func() -> bool: return not p.carry.is_holding(), 2.0)
	await GrabTestUtil.wait(self, 0.2)
	var cut := _severed.filter(func(s: Array) -> bool: return s[0] == e)
	print("[kill] slam on a 5 HP grunt: contacts %s, dead=%s, limb severed %s (chance %.2f)" % [_log(), e.is_dead(),
		cut.map(func(s: Array) -> StringName: return s[1]), Tuning.R7_SEVER_ON_KILL])
	_check(_results() == [&"slam"] and e.is_dead(), "a killing slam kills")
	_check(cut.size() <= 1, "at most one limb comes off")
	await _clear(pr + [wall])

func _corpse_slam(at: Vector3) -> void:
	GrabTestUtil.reset_world()
	_impacts.clear()
	_ends.clear()
	var p := GrabTestUtil.spawn(self, &"player", at, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := GrabTestUtil.spawn(self, &"grunt", at + Vector3(0.0, 0.0, -1.0), Vector3.BACK)
	var wall := GrabTestUtil.make_wall(self, at + Vector3(0.0, 1.5, -5.5), Vector3(4.0, 3.0, 0.4))
	await GrabTestUtil.frames(self, 20)
	e.apply_damage(e.hp + 1.0, &"test")
	await GrabTestUtil.wait(self, 1.0)
	p.carry.grab_now(e, &"", true)
	await GrabTestUtil.wait(self, 0.4)
	var holding := p.carry.is_holding_body()
	await _drive(p)
	await GrabTestUtil.wait_until(self, func() -> bool: return not p.carry.is_holding(), 2.0)
	print("[corpse] driving a corpse (held=%s) into a wall: contacts %s, drive ended %s, holding=%s" % [holding, _log(), _ends,
		p.carry.is_holding()])
	_check(holding and _results() == [&"slam"] and _ends == [&"slam"] and not p.carry.is_holding(), "a driven corpse slams and is let go")
	await _clear([p, e, wall])

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	Carry.force_enabled = false
	if _fail.is_empty():
		print("PASS test_drive_rules")
		get_tree().quit(0)
	else:
		print("FAIL test_drive_rules: ", _fail)
		get_tree().quit(1)
