extends Node3D
## Round 7 acceptance 9 (Grab, drive and throw: "Throw (LMB while holding)"),
## through the real input path: Input.action_press(&"punch") -> PlayerController
## -> InputInterpreter -> CombatController -> Carry, with a CameraRig aiming.
## - tap: R7_THROW_SPEED_MIN (8 m/s), measured on the thrown body too;
## - full wind-up (held R7_THROW_WINDUP_FULL): R7_THROW_SPEED_MAX (18 +-0.5 m/s);
##   halfway (0.45 s): about 13 m/s; get_throw_windup() and throw_windup events
##   climb 0 -> 1 and end at 0;
## - direction: camera forward (flat, not the facing), pitched up R7_THROW_PITCH;
## - aim assist: an enemy 6 m out 15 degrees off the camera takes the throw
##   (and is bowled), one 25 degrees off does not (R7_THROW_ASSIST_CONE 20);
## - while driving the drive speed x Tuning.THROW_RUN_SHARE is added;
## - the thrown body is the existing projectile (GameEvents.thrown, bowls the
##   assisted enemy); the release is a launch-tier hit_landed by the player
##   (no damage), which opens Defence's pursuit window;
## - the body swings back toward the right fist during a full wind-up.
## OWNER: agent G.

const SPEED_TOL := 0.5

var _fail: Array[String] = []
var _windup: Array[float] = []
var _thrown: Array = []
var _bowled: Array = []
var _hits: Array[HitInfo] = []

func _ready() -> void:
	get_tree().create_timer(120.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	Carry.force_enabled = true
	GameEvents.throw_windup.connect(func(h: Node3D, amount: float) -> void:
		if h is Fighter and (h as Fighter).is_player:
			_windup.append(amount))
	GameEvents.thrown.connect(func(g: Node3D, v: Node3D, vel: Vector3) -> void: _thrown.append([g, v, vel]))
	GameEvents.body_bowled.connect(func(_f: Node3D, v: Node3D, _e: float, _c: int) -> void: _bowled.append(v))
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void: _hits.append(info))
	GrabTestUtil.make_floor(self, 400.0)
	await get_tree().physics_frame
	await _throw_case("tap", 1, Vector3.FORWARD, Tuning.R7_THROW_SPEED_MIN)
	await _throw_case("half wind-up", int(round(0.45 * 120.0)), Vector3.FORWARD,
		Carry.throw_speed(Carry.windup_of(0.45)))
	await _throw_case("full wind-up", int(round(Tuning.R7_THROW_WINDUP_FULL * 120.0)) + 2, Vector3.FORWARD,
		Tuning.R7_THROW_SPEED_MAX)
	await _throw_case("camera +X", 1, Vector3.RIGHT, Tuning.R7_THROW_SPEED_MIN)
	await _assist(15.0, true)
	await _assist(25.0, false)
	await _drive_bonus()
	_finish()

## The real player at the origin facing -Z holding a grunt by the collar; a
## camera rig looking along `look`.
func _setup(look: Vector3) -> Array:
	GrabTestUtil.reset_world()
	GrabTestUtil.release_all_input()
	_windup.clear()
	_thrown.clear()
	_bowled.clear()
	_hits.clear()
	var p := GrabTestUtil.spawn_player(self, Vector3.ZERO, Vector3.FORWARD)
	var cam := GrabTestUtil.make_camera(self, p, look)
	var e := GrabTestUtil.spawn(self, &"grunt", Vector3(0.0, 0.0, -1.0), Vector3.BACK)
	await GrabTestUtil.frames(self, 20)
	p.carry.grab_now(e, &"", true)
	await GrabTestUtil.wait(self, 0.4)
	return [p, e, cam]

func _clear(nodes: Array) -> void:
	GrabTestUtil.release_all_input()
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	await GrabTestUtil.frames(self, 4)

## Hold LMB `ticks` physics ticks with a body, release, and measure.
func _throw_case(label: String, ticks: int, look: Vector3, want: float) -> void:
	var s: Array = await _setup(look)
	var p: Fighter = s[0]
	var e: Fighter = s[1]
	_check(p.carry.is_holding_body(), "%s: holding a grunt" % label)
	var chest0 := (e.rig.get_bone_global_position(Bones.CHEST) - p.global_position).dot(look)
	var chest_min := chest0
	GrabTestUtil.key_down(&"punch")
	var peak := 0.0
	var at_full := -1.0
	for i in ticks:
		chest_min = minf(chest_min, (e.rig.get_bone_global_position(Bones.CHEST) - p.global_position).dot(look))
		await get_tree().physics_frame
		var w := p.carry.get_throw_windup()
		peak = maxf(peak, w)
		if at_full < 0.0 and w >= 1.0:
			at_full = float(i + 1) / 120.0
	GrabTestUtil.key_up(&"punch")
	await GrabTestUtil.frames(self, 3)
	var v := p.carry.last_throw_velocity
	var flat := Vector3(v.x, 0.0, v.z)
	var pitch := rad_to_deg(atan2(v.y, flat.length()))
	var dir_err := rad_to_deg(flat.normalized().angle_to(look)) if flat.length() > 0.01 else 180.0
	var body := e.get_com_velocity().length()
	var launch: Array[HitInfo] = _hits.filter(func(h: HitInfo) -> bool:
		return h.attacker == p and h.victim == e and h.kind == &"throw" and HitInfo.is_launch_tier(h.tier) \
			and h.result == HitInfo.Result.HIT)
	var pursuable: bool = p.defence != null and p.defence.get(&"_launch_victim") == e
	var events_up := true
	for i in range(1, _windup.size() - 1):
		if _windup[i] + 1e-4 < _windup[i - 1]:
			events_up = false
	print("[%s] held %d ticks (%.3f s): throw %.2f m/s (want %.2f), body %.2f m/s, pitch %.1f deg, %.1f deg off the camera, wind-up peak %.2f%s, events %d (last %.2f), thrown=%d, holding=%s" % [
		label, ticks, ticks / 120.0, v.length(), want, body, pitch, dir_err, peak,
		(" (full at %.3f s)" % at_full) if at_full > 0.0 else "", _windup.size(),
		_windup.back() if not _windup.is_empty() else -1.0, _thrown.size(), p.carry.is_holding()])
	_check(not p.carry.is_holding() and _thrown.size() == 1, "%s: the body is thrown (GameEvents.thrown)" % label)
	_check(absf(v.length() - want) <= SPEED_TOL, "%s: %.1f m/s (+-%.1f)" % [label, want, SPEED_TOL])
	_check(absf(body - want) <= 1.0, "%s: the body really flies at about that speed" % label)
	_check(absf(pitch - Tuning.R7_THROW_PITCH) < 0.5, "%s: pitched up %.0f degrees" % [label, Tuning.R7_THROW_PITCH])
	_check(dir_err < 1.0, "%s: along the camera's forward (not the facing)" % label)
	_check(events_up and not _windup.is_empty() and is_zero_approx(_windup.back()), "%s: throw_windup climbs and ends at 0" % label)
	print("[%s] release: launch hit_landed by the player %d (damage %.0f), Defence pursuit window on the body=%s; chest %.2f m ahead at the press, %.2f m at its furthest back" % [
		label, launch.size(), launch[0].damage if not launch.is_empty() else -1.0, pursuable, chest0, chest_min])
	_check(launch.size() == 1 and is_zero_approx(launch[0].damage), "%s: the release is a launch hit_landed by the player (no damage)" % label)
	_check(pursuable, "%s: it opens Defence's pursuit window" % label)
	if label == "full wind-up":
		_check(absf(at_full - Tuning.R7_THROW_WINDUP_FULL) < 0.03, "full wind-up reached at R7_THROW_WINDUP_FULL")
		_check(chest0 - chest_min > 0.4, "the body swings back with the wind-up (toward the right fist)")
	await _clear(s)

## An enemy 6 m out, `deg` degrees off the camera's forward; a full wind-up.
func _assist(deg: float, expect: bool) -> void:
	var s: Array = await _setup(Vector3.FORWARD)
	var p: Fighter = s[0]
	var a := deg_to_rad(deg)
	var at := Vector3(sin(a), 0.0, -cos(a)) * 6.0
	var target := GrabTestUtil.spawn(self, &"grunt", at, -at)
	await GrabTestUtil.frames(self, 10)
	await GrabTestUtil.key_tap(self, &"punch", int(round(Tuning.R7_THROW_WINDUP_FULL * 120.0)) + 2)
	var v := p.carry.last_throw_velocity
	var flat := Vector3(v.x, 0.0, v.z).normalized()
	var to := Vector3(at.x, 0.0, at.z).normalized()
	var off_target := rad_to_deg(flat.angle_to(to))
	var off_cam := rad_to_deg(flat.angle_to(Vector3.FORWARD))
	var hit := await GrabTestUtil.wait_until(self, func() -> bool: return _bowled.has(target) or target.is_down(), 1.5)
	print("[assist %.0f deg] throw %.1f deg off the enemy, %.1f deg off the camera, assist=%s, enemy hit=%s (%s)" % [
		deg, off_target, off_cam, p.carry.last_throw_assist.name if p.carry.last_throw_assist else "-", hit,
		GrabTestUtil.state_name(target)])
	if expect:
		_check(p.carry.last_throw_assist == target and off_target < 1.0, "an enemy %.0f deg off the aim takes the throw" % deg)
		_check(hit, "the thrown body bowls it")
	else:
		_check(p.carry.last_throw_assist == null and off_cam < 1.0, "an enemy %.0f deg off (outside %.0f) does not" % [
			deg, Tuning.R7_THROW_ASSIST_CONE])
	await _clear(s + [target])

## Throw during a drive: + drive speed x THROW_RUN_SHARE.
func _drive_bonus() -> void:
	var s: Array = await _setup(Vector3.FORWARD)
	var p: Fighter = s[0]
	p.carry.on_drive_pressed(TimeDirector.now())   # the drive's own routing is test_drive_yard's
	await GrabTestUtil.wait(self, 0.5)
	var driving := p.carry.is_driving()
	var ds := p.carry.get_drive_speed()
	await GrabTestUtil.key_tap(self, &"punch", 1)
	var v := p.carry.last_throw_velocity.length()
	var want := minf(Tuning.R7_THROW_SPEED_MIN + ds * Tuning.THROW_RUN_SHARE, Tuning.LAUNCH_SPEED_MAX)
	print("[drive] driving=%s at %.2f m/s: tap throw %.2f m/s (want %.2f = %.1f + %.2f x %.1f), drive ended %s" % [
		driving, ds, v, want, Tuning.R7_THROW_SPEED_MIN, ds, Tuning.THROW_RUN_SHARE, p.carry.last_drive_end])
	_check(driving and ds > Tuning.R7_DRIVE_START_SPEED, "the drive runs")
	_check(absf(v - want) < 0.35, "a throw while driving adds the drive speed x THROW_RUN_SHARE")
	_check(not p.carry.is_driving() and p.carry.last_drive_end == &"drop", "the throw ends the drive")
	await _clear(s)

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	Carry.force_enabled = false
	GrabTestUtil.release_all_input()
	if _fail.is_empty():
		print("PASS test_throw")
		get_tree().quit(0)
	else:
		print("FAIL test_throw: ", _fail)
		get_tree().quit(1)
