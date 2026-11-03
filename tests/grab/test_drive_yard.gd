extends Node3D
## Round 7 acceptance 8 (Grab, drive and throw: "Drive") in D's real Yard
## (YardBuilder + K's clutter), through the real input path:
## Input.action_press(&"grab") then held &"dash" -> PlayerController ->
## InputInterpreter -> CombatController -> Carry -> Traversal.begin_drive().
## A lane is searched for (a box swept along it meets nothing but the target).
## - Lane A, toward a west-facade drywall panel 11.5 m away: the drive speed
##   reaches R7_DRIVE_MAX_SPEED (9.5 +-0.3 m/s) at 1 s (Traversal's number and
##   the capsule's); the panel breaks (receive_impact with E = 1/2 (victim +
##   share x player) v^2), the drive goes on through it at speed x
##   sqrt(1 - absorption) (>= R7_DRIVE_MIN_SPEED), the hold stays, the victim
##   takes R7_DRIVE_BREAK_DAMAGE. Every drive contact after that is logged.
## - Lane B, toward the south concrete arena wall, a grunt standing 4.5 m out:
##   it is bowled (knockdown, R7_DRIVE_BOWL_DAMAGE, the drive keeps
##   R7_DRIVE_BOWL_KEEP); then the concrete slams: drive_ended(&"slam"), the
##   victim knocked down against the wall, R7_DRIVE_SLAM_DAMAGE +
##   R7_DRIVE_SLAM_DAMAGE_PER_MS x v taken, the hold ended.
## Measured numbers are printed.
## OWNER: agent G.

const RAMP_TOL := 0.3
const LANE_A := 11.5      ## m from the drywall panel
const LANE_B := 9.0       ## m from the south wall
const BOWL_AT := 4.5      ## m from lane B's start
const SOUTH_FACE := 11.0  ## z of the south concrete wall's inner face (YardBuilder.SOUTH_Z.x)

var _fail: Array[String] = []
var _impacts: Array = []
var _ends: Array = []
var _started := 0
var yard: YardBuilder

func _ready() -> void:
	get_tree().create_timer(280.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		GrabTestUtil.release_all_input()
		get_tree().quit(1))
	Carry.force_enabled = true
	GameEvents.drive_impact.connect(func(h: Node3D, v: Node3D, t: Node3D, pos: Vector3, speed: float, result: StringName) -> void:
		_impacts.append({"holder": h, "victim": v, "target": t, "pos": pos, "speed": speed, "result": result,
			"t": TimeDirector.now()}))
	GameEvents.drive_ended.connect(func(_h: Node3D, reason: StringName) -> void: _ends.append(reason))
	GameEvents.drive_started.connect(func(_h: Node3D, _v: Node3D) -> void: _started += 1)
	yard = YardBuilder.new()
	yard.name = "Yard"
	add_child(yard)
	yard.build()
	await GrabTestUtil.frames(self, 10)
	await _lane_drywall()
	await _lane_concrete()
	_finish()

# --- Lanes ---------------------------------------------------------------------------
## A box 0.9 m wide, 0.25..1.75 m high swept from `from` to `to` meets nothing
## (or only `allow`'s colliders).
func _clear_lane(from: Vector3, to: Vector3, allow: Node = null) -> bool:
	var box := BoxShape3D.new()
	box.size = Vector3(0.9, 1.5, 0.3)
	var dir := (to - from)
	dir.y = 0.0
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = box
	q.transform = Transform3D(Basis.looking_at(dir.normalized(), Vector3.UP), from + Vector3.UP * 1.0)
	q.motion = dir
	q.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
	var space := get_world_3d().direct_space_state
	var excl: Array[RID] = []
	for i in 8:
		q.exclude = excl
		var r := space.cast_motion(q)
		if r[1] >= 1.0:
			return true
		q.transform = Transform3D(Basis.looking_at(dir.normalized(), Vector3.UP), from + Vector3.UP * 1.0 + dir * r[1])
		q.motion = Vector3.ZERO
		var info := space.get_rest_info(q)
		q.transform = Transform3D(Basis.looking_at(dir.normalized(), Vector3.UP), from + Vector3.UP * 1.0)
		q.motion = dir
		if info.is_empty():
			return false
		var col := instance_from_id(int(info["collider_id"]))
		if col is RigidBody3D or (allow != null and WorldTags.breakable_of(col) == allow):
			excl.append(info["rid"])
			continue
		return false
	return false

## [panel, start, dir] of a clear lane to a west-facade drywall panel, or [].
func _find_drywall_lane() -> Array:
	for n in get_tree().get_nodes_in_group(&"destructibles"):
		var d := n as Destructible
		if d == null or d.surface != &"drywall" or d.kind != &"panel" or absf(d.global_position.x + 11.125) > 0.3:
			continue
		var nrm := d.get_face_normal(d.global_position + Vector3.RIGHT * 5.0)
		nrm.y = 0.0
		if nrm.dot(Vector3.RIGHT) < 0.9:
			continue
		for off: float in [0.0, -0.6, 0.6]:
			var face := Vector3(d.global_position.x, 0.05, d.global_position.z + off) + nrm * 0.15
			var start := face + nrm * LANE_A
			if _clear_lane(start, face, d):
				return [d, start, -nrm.normalized()]
	return []

## [start, dir] of a clear lane to the south concrete wall, or [].
func _find_concrete_lane() -> Array:
	for x: float in [0.0, -2.0, 2.0, -4.0, 4.0, -1.0, 1.0, -3.0, 3.0, -8.0, 8.0]:
		var start := Vector3(x, 0.05, SOUTH_FACE - LANE_B)
		if _clear_lane(start, Vector3(x, 0.05, SOUTH_FACE - 0.35)):
			return [start, Vector3.BACK]
	return []

## The real player at `start` facing `dir` holding a grunt by the collar
## (grabbed with C), the camera looking down the lane.
func _setup(start: Vector3, dir: Vector3) -> Array:
	GrabTestUtil.reset_world()
	GrabTestUtil.release_all_input()
	_impacts.clear()
	_ends.clear()
	_started = 0
	var p := GrabTestUtil.spawn_player(self, start, dir)
	var cam := GrabTestUtil.make_camera(self, p, dir)
	var e := GrabTestUtil.spawn(self, &"grunt", start + dir * 1.1, -dir)
	await GrabTestUtil.frames(self, 30)
	await GrabTestUtil.key_tap(self, &"grab")
	var ok := await GrabTestUtil.wait_until(self, func() -> bool: return p.carry.is_holding_body(), 1.0)
	await GrabTestUtil.wait(self, 0.3)
	_check(ok and p.carry.held == e, "C grabs the grunt (real input)")
	return [p, e, cam]

func _clear(nodes: Array) -> void:
	GrabTestUtil.release_all_input()
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	await GrabTestUtil.frames(self, 6)

func _impact(result: StringName) -> Dictionary:
	for i in _impacts:
		if i["result"] == result:
			return i
	return {}

func _impact_log() -> String:
	return ", ".join(_impacts.map(func(i: Dictionary) -> String:
		return "%s %s at %.2f m/s" % [i["result"], (i["target"] as Node).name if i["target"] != null and is_instance_valid(i["target"]) else "-", i["speed"]]))

# --- Lane A: ramp and drywall ----------------------------------------------------------
func _lane_drywall() -> void:
	var lane := _find_drywall_lane()
	_check(not lane.is_empty(), "a clear lane to a drywall panel exists in the Yard")
	if lane.is_empty():
		return
	var panel: Destructible = lane[0]
	var start: Vector3 = lane[1]
	var dir: Vector3 = lane[2]
	print("[lane A] %s at %s, start %s, dir %s, break energy %.0f J, absorption %.2f" % [panel.name, panel.global_position,
		start, dir, panel.break_energy, panel.absorption])
	var s: Array = await _setup(start, dir)
	var p: Fighter = s[0]
	var e: Fighter = s[1]
	var hp0 := e.hp
	GrabTestUtil.key_down(&"dash")
	var driving := await GrabTestUtil.wait_until(self, func() -> bool: return p.carry.is_driving(), 0.3)
	_check(driving and _started == 1, "held Shift starts the drive (drive_started)")
	var t0 := TimeDirector.now()
	var at := {"drive": 0.0, "capsule": 0.0, "done": false}
	var samples: Array[String] = []
	await GrabTestUtil.wait_until(self, func() -> bool:
		var t := TimeDirector.now() - t0
		if int(round(t * 120.0)) % 24 == 0:
			samples.append("%.1fs %.2f" % [t, p.carry.get_drive_speed()])
		if not at["done"] and t >= 1.0 - 1e-4:
			at["drive"] = p.carry.get_drive_speed()
			at["capsule"] = GrabTestUtil.hspeed(p)
			at["done"] = true
		return not _impact(&"break").is_empty() or not p.carry.is_driving(), 3.0)
	var brk := _impact(&"break")
	print("[ramp] drive speed %s; at 1.0 s: drive %.2f m/s, capsule %.2f m/s (want %.1f +-%.1f)" % [", ".join(samples),
		at["drive"], at["capsule"], Tuning.R7_DRIVE_MAX_SPEED, RAMP_TOL])
	_check(at["done"] and absf(float(at["drive"]) - Tuning.R7_DRIVE_MAX_SPEED) <= RAMP_TOL,
		"from a standstill the drive reaches 9.5 m/s +-0.3 at 1 s")
	_check(at["done"] and absf(float(at["capsule"]) - Tuning.R7_DRIVE_MAX_SPEED) <= RAMP_TOL + 0.2,
		"the capsule really runs at it")
	_check(not brk.is_empty() and brk["target"] == panel, "the drywall panel breaks (drive_impact break)")
	if brk.is_empty():
		await _clear(s)
		return
	await GrabTestUtil.frames(self, 2)
	var v_in: float = brk["speed"]
	var v_out := p.carry.get_drive_speed()
	var want_out := maxf(v_in * sqrt(1.0 - panel.absorption), Tuning.R7_DRIVE_MIN_SPEED)
	var mass := e.get_total_mass() + Tuning.R7_DRIVE_MASS_SHARE * p.get_total_mass()
	var hole := panel.is_broken or panel.is_point_open(brk["pos"])
	var dmg := hp0 - e.hp
	print("[drywall] break at %.2f m/s, E %.0f J (1/2 x %.1f kg x v^2 = %.0f), panel broken/holed=%s, speed after %.2f (want %.2f), holding=%s driving=%s, victim -%.1f HP" % [
		v_in, p.carry.last_drive_energy, mass, 0.5 * mass * v_in * v_in, hole, v_out, want_out, p.carry.is_holding_body(),
		p.carry.is_driving(), dmg])
	_check(hole, "the panel is broken open")
	_check(p.carry.is_driving() and p.carry.is_holding_body(), "the drive goes on through it, the hold stays")
	_check(absf(v_out - want_out) < 0.35, "speed after = speed x sqrt(1 - absorption)")
	_check(absf(dmg - Tuning.R7_DRIVE_BREAK_DAMAGE) < 0.5, "the victim takes R7_DRIVE_BREAK_DAMAGE")
	# Carry on: the capsule follows the body through the hole.
	var face_x := panel.global_position.x
	var through := await GrabTestUtil.wait_until(self, func() -> bool:
		return (p.global_position - panel.global_position).dot(dir) > 0.4 or not p.carry.is_driving(), 1.0)
	var past := (p.global_position - panel.global_position).dot(dir)
	await GrabTestUtil.wait_until(self, func() -> bool: return not p.carry.is_driving(), 2.5)
	GrabTestUtil.key_up(&"dash")
	print("[drywall] player %.2f m past the panel (face x %.2f), contacts: %s; drive ended %s" % [past, face_x, _impact_log(), _ends])
	_check(through and past > 0.4, "the player follows the body through the hole")
	await _clear(s)

# --- Lane B: bowl, then the concrete slam ---------------------------------------------
func _lane_concrete() -> void:
	var lane := _find_concrete_lane()
	_check(not lane.is_empty(), "a clear lane to the south concrete wall exists in the Yard")
	if lane.is_empty():
		return
	var start: Vector3 = lane[0]
	var dir: Vector3 = lane[1]
	var s: Array = await _setup(start, dir)
	var p: Fighter = s[0]
	var e: Fighter = s[1]
	var bowl := GrabTestUtil.spawn(self, &"grunt", start + dir * BOWL_AT, -dir)
	await GrabTestUtil.frames(self, 10)
	var hp0 := e.hp
	var bowl_hp0 := bowl.hp
	print("[lane B] start %s, dir %s, bowl target at %s, wall face z %.2f" % [start, dir, bowl.global_position, SOUTH_FACE])
	GrabTestUtil.key_down(&"dash")
	await GrabTestUtil.wait_until(self, func() -> bool: return p.carry.is_driving(), 0.3)
	var speed_before_bowl := {"v": 0.0}
	await GrabTestUtil.wait_until(self, func() -> bool:
		if _impact(&"bowl").is_empty():
			speed_before_bowl["v"] = p.carry.get_drive_speed()
		return not _impact(&"bowl").is_empty() or not p.carry.is_driving(), 2.0)
	var b := _impact(&"bowl")
	await GrabTestUtil.frames(self, 2)
	var after_bowl := p.carry.get_drive_speed()
	await GrabTestUtil.wait(self, 0.15)
	var bowl_down := bowl.is_down()
	print("[bowl] grunt in the path: %s at %.2f m/s, its state %s, -%.1f HP; drive speed %.2f -> %.2f (keep %.2f, want %.2f)" % [
		"bowled" if not b.is_empty() else "NOT bowled", b.get("speed", 0.0), GrabTestUtil.state_name(bowl), bowl_hp0 - bowl.hp,
		b.get("speed", 0.0), after_bowl, after_bowl / maxf(float(b.get("speed", 1.0)), 0.01), Tuning.R7_DRIVE_BOWL_KEEP])
	_check(not b.is_empty() and b["target"] == bowl, "a grunt in the path is bowled (drive_impact bowl)")
	_check(bowl_down and absf((bowl_hp0 - bowl.hp) - Tuning.R7_DRIVE_BOWL_DAMAGE) < 0.5,
		"it is knocked down and takes R7_DRIVE_BOWL_DAMAGE")
	_check(not b.is_empty() and absf(after_bowl - float(b["speed"]) * Tuning.R7_DRIVE_BOWL_KEEP) < 0.3,
		"the drive keeps R7_DRIVE_BOWL_KEEP of its speed")
	_check(p.carry.is_driving() and p.carry.is_holding_body(), "the drive goes on after the bowl")
	await GrabTestUtil.wait_until(self, func() -> bool: return not _impact(&"slam").is_empty() or not p.carry.is_holding(), 3.0)
	var sl := _impact(&"slam")
	GrabTestUtil.key_up(&"dash")
	await GrabTestUtil.wait(self, 0.5)
	var v: float = sl.get("speed", 0.0)
	var want_dmg := Tuning.R7_DRIVE_SLAM_DAMAGE + Tuning.R7_DRIVE_SLAM_DAMAGE_PER_MS * v
	var dmg := hp0 - e.hp
	var gap := SOUTH_FACE - e.get_ground_position().z
	print("[slam] concrete at %.2f m/s: drive ended %s, holding=%s, victim %s (down=%s) -%.1f HP (want %.1f = %.0f + %.0f x %.2f), %.2f m from the wall; contacts: %s" % [
		v, _ends, p.carry.is_holding(), GrabTestUtil.state_name(e), e.is_down(), dmg, want_dmg,
		Tuning.R7_DRIVE_SLAM_DAMAGE, Tuning.R7_DRIVE_SLAM_DAMAGE_PER_MS, v, gap, _impact_log()])
	_check(not sl.is_empty() and v >= Tuning.R7_DRIVE_SLAM_MIN_SPEED, "the concrete wall slams (drive_impact slam)")
	_check(_ends.has(&"slam") and not p.carry.is_holding() and not e.carry.is_held(), "the drive and the hold end (drive_ended slam)")
	_check(e.is_down() and gap < 1.6, "the victim is knocked down against the wall")
	_check(absf(dmg - want_dmg) < 1.0, "the victim takes R7_DRIVE_SLAM_DAMAGE + PER_MS x v")
	await _clear(s + [bowl])

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	Carry.force_enabled = false
	GrabTestUtil.release_all_input()
	if _fail.is_empty():
		print("PASS test_drive_yard")
		get_tree().quit(0)
	else:
		print("FAIL test_drive_yard: ", _fail)
		get_tree().quit(1)
