extends Node
## Round 8 camera: the air combo (docs/Round 8 — Charge and Pressure.md: Air
## combo). Each run scripts the combo the way B, H and M report it: a charged
## uppercut lifts the body (hit_landed react &"lift"), the launcher jump
## (GameEvents.air_follow_started; Traversal.is_air_following() for its
## R8_AIR_FOLLOW_TIME) takes the player up beside it, 4 air hits (air_hit +
## hit_landed with HitInfo.air) each hang both for R8_AIR_HANG with a short
## fall between, then a finisher: the air kick (a real ragdoll launch at
## R8_AIR_KICK_LAUNCH, R8_AIR_KICK_ANGLE up) or the spike (a real launch
## straight down at R7_SPIKE_SPEED, react &"spike"), and the player falls and
## lands. The fighters' capsules are moved by the script (their own processing
## is off until the finisher launches the body for real); the air combo state
## (follow, air hits, airborne) comes from test_cam_fake_rig.gd.
## Runs: the body ahead of the camera and 45 deg to either side, lifted 2.5 m
## and 3 m. Checked on every rendered frame:
## - the player (head, chest, feet) and the body (head, chest, feet; its centre
##   of mass after the finisher, for AFTER_LAUNCH s) stay in the viewport;
## - the air framing raises the look-at and pulls back, on springs: no jolt in
##   the look point or the distance at any hang;
## - an air hit punches at AIR_HIT_PUNCH_SHARE of its weight; the kick launch is
##   picked up by the launch framing, the spike's floor impact by the spike
##   framing; no fall tilt; the framing eases out after the landing.

const FakeRig := preload("res://tests/game/test_cam_fake_rig.gd")
const G := 9.8
const RUNS := [
	{"angle": 0.0, "lift": 2.5, "finish": &"kick"},
	{"angle": 45.0, "lift": 2.5, "finish": &"spike"},
	{"angle": -45.0, "lift": 3.0, "finish": &"kick"},
	{"angle": 0.0, "lift": 3.0, "finish": &"spike"},
	{"angle": -45.0, "lift": 2.5, "finish": &"spike"},
	{"angle": 45.0, "lift": 3.0, "finish": &"kick"},
]
const BODY_DIST := 2.0          ## m ahead of the player at the uppercut
const JUMP_AT := 0.3            ## s after the uppercut the Jump press comes (inside R8_AIR_FOLLOW_WINDOW)
const REACH := 1.0              ## m from the body where the launcher jump ends
const FEET_BELOW := 0.2         ## m the player's feet end below the body's
const GAP := 0.12               ## s of free fall between the hangs (the next press)
const HITS := 4
const AIR_WEIGHT := 0.3         ## an air jab's weight
const AFTER_LAUNCH := 0.6       ## real s the launched / spiked body must stay in view
const LOOK_JOLT := 40.0         ## m/s^2: the look point's acceleration at a hang stays under this
const DIST_JOLT := 0.02         ## m: the framing distance never jumps more than this in a frame

var _fails := 0
var _rig
var _p: Fighter
var _b: Fighter
var _world: Node3D
var _phase := &""
var _hang_n := -1                ## the hang running (0-based), -1 outside the hangs
var _m := {}
var _probe_on := false

class Probe:
	extends Node
	var owner_test: Node
	func _process(_d: float) -> void:
		owner_test.call(&"_measure")

func _ready() -> void:
	for i in 5:
		await get_tree().process_frame
	await _run()
	TimeDirector.reset()
	print("TEST test_cam_aircombo: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _box(pos: Vector3, size: Vector3, nm: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = nm
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = pos
	add_child(body)
	return body

func _wait_real(sec: float) -> void:
	var until := TimeDirector.now() + sec
	while TimeDirector.now() < until:
		await get_tree().process_frame

## One physics tick; returns its game-time length.
func _tick() -> float:
	await get_tree().physics_frame
	return Engine.time_scale / float(Engine.physics_ticks_per_second)

## Pixels from the nearest viewport edge (negative = outside, -1e6 = behind the camera).
func _margin(q: Vector3) -> float:
	var cam: Camera3D = _rig.camera
	var size := get_viewport().get_visible_rect().size
	if cam.is_position_behind(q):
		return -1e6
	var s := cam.unproject_position(q)
	return minf(minf(s.x, size.x - s.x), minf(s.y, size.y - s.y))

func _reset_probe() -> void:
	_m = {"frames": 0, "p_out": 0, "p_worst": INF, "b_frames": 0, "b_out": 0, "b_worst": INF,
		"look_prev": null, "look_v": null, "jolt": 0.0, "dist_prev": -1.0, "dist_step": 0.0,
		"max_roll": 0.0, "hang_frames": 0, "raise_min": INF, "dist_min": INF, "air_k_min": INF,
		"hang_t0": -100.0, "body_ok": true, "after_t0": -100.0}

func _measure() -> void:
	if not _probe_on or not is_instance_valid(_rig) or not is_instance_valid(_p):
		return
	_m["frames"] += 1
	var aim := _p.get_aim_point()
	var pw := INF
	for q: Vector3 in [aim, aim + Vector3.UP * 0.5, _p.get_ground_position() + Vector3.UP * 0.05]:
		pw = minf(pw, _margin(q))
	_m["p_worst"] = minf(_m["p_worst"], pw)
	if pw < 0.0:
		_m["p_out"] += 1
	if is_instance_valid(_b) and _phase != &"after":
		var pts: Array[Vector3] = []
		if _phase == &"finish":
			if TimeDirector.now() - float(_m["after_t0"]) <= AFTER_LAUNCH:
				pts.append(_b.get_center_of_mass())
		else:
			var ba := _b.get_aim_point()
			pts = [ba, ba + Vector3.UP * 0.5, _b.get_ground_position() + Vector3.UP * 0.05]
		if not pts.is_empty():
			var bw := INF
			for q in pts:
				bw = minf(bw, _margin(q))
			_m["b_frames"] += 1
			_m["b_worst"] = minf(_m["b_worst"], bw)
			if bw < 0.0:
				_m["b_out"] += 1
	# Framing continuity (the look point and the distance carry no shake).
	var dt := TimeDirector.frame_delta()
	var look: Vector3 = _rig.get_look_point()
	if _m["look_prev"] != null and dt > 0.0:
		var v: Vector3 = (look - (_m["look_prev"] as Vector3)) / dt
		if _m["look_v"] != null and _hang_n >= 1 and TimeDirector.now() - float(_m["hang_t0"]) < 0.15:
			_m["jolt"] = maxf(_m["jolt"], (v - (_m["look_v"] as Vector3)).length() / dt)
		_m["look_v"] = v
	_m["look_prev"] = look
	var d: float = _rig.get_distance()
	if float(_m["dist_prev"]) >= 0.0 and _phase in [&"follow", &"hangs"]:
		_m["dist_step"] = maxf(_m["dist_step"], absf(d - float(_m["dist_prev"])))
	_m["dist_prev"] = d
	_m["max_roll"] = maxf(_m["max_roll"], absf(_rig.get_roll_degrees()))
	if _phase == &"hangs":
		_m["hang_frames"] += 1

func _run() -> void:
	_box(Vector3(0, -0.5, 0), Vector3(200, 1, 200), "Floor")
	_world = Node3D.new()
	add_child(_world)
	_p = FighterFactory.spawn_player(_world, Transform3D(Basis(), Vector3(0, 0.05, 0)))
	_p.max_hp = 100000.0
	_p.hp = _p.max_hp
	AttackDirector.set_player(_p)
	_rig = FakeRig.new()
	_rig.target = _p
	_rig.script_air = true
	add_child(_rig)
	var probe := Probe.new()
	probe.owner_test = self
	probe.process_priority = 1000  # after the rig: measures what is rendered
	add_child(probe)
	await _wait_real(0.6)
	_p.process_mode = Node.PROCESS_MODE_DISABLED  # the script moves the player from here on
	var tot := {"frames": 0, "p_out": 0, "b_frames": 0, "b_out": 0, "p_worst": INF, "b_worst": INF}
	for i in RUNS.size():
		var r: Dictionary = await _combo(RUNS[i], i)
		for k: String in ["frames", "p_out", "b_frames", "b_out"]:
			tot[k] = int(tot[k]) + int(r[k])
		tot["p_worst"] = minf(tot["p_worst"], r["p_worst"])
		tot["b_worst"] = minf(tot["b_worst"], r["b_worst"])
	print("  all runs: player in view %d/%d (worst margin %.0f px), body in view %d/%d (worst %.0f px)" % [
		tot["frames"] - tot["p_out"], tot["frames"], tot["p_worst"], tot["b_frames"] - tot["b_out"], tot["b_frames"], tot["b_worst"]])
	_check(tot["p_out"] == 0 and tot["b_out"] == 0, "the player and the body stay in the viewport through every air combo")

## One combo. Returns the probe's numbers.
func _combo(cfg: Dictionary, idx: int) -> Dictionary:
	var lift: float = cfg["lift"]
	var finish: StringName = cfg["finish"]
	var dir := Vector3.FORWARD
	# Start: the player at the origin facing the body; the camera behind, turned
	# by the run's angle (the player's own camera input, a while ago).
	_rig.fake_air_following = false
	_rig.fake_air_hits = 0
	_rig.fake_airborne = false
	_p.teleport_to(Vector3(0, 0.05, 0), dir)
	if is_instance_valid(_b):
		_b.queue_free()
	_b = FighterFactory.spawn_dummy(_world, &"grunt", Transform3D(Basis.looking_at(-dir), dir * BODY_DIST + Vector3(0, 0.05, 0)))
	_b.max_hp = 100000.0
	_b.hp = _b.max_hp
	await _wait_real(0.3)
	_b.process_mode = Node.PROCESS_MODE_DISABLED
	_rig.fake_target = _b
	_rig.snap_behind()
	await get_tree().process_frame
	_rig.apply_manual_input(Vector2(deg_to_rad(float(cfg["angle"])), 0.0))
	await _wait_real(Tuning.CAM_MOUSE_IDLE + 0.6)
	_rig._trauma = 0.0
	var ground_dist: float = _rig.get_distance()
	var punches := PackedFloat32Array()
	var launch_picked := false
	var spikes0: int = _rig.get_spike_impacts()
	_reset_probe()
	_probe_on = true
	# --- The charged uppercut: the lift arc.
	_phase = &"lift"
	var b0 := _b.global_position
	var bv := sqrt(2.0 * G * lift)
	var by := b0.y
	_hit(&"uppercut", &"lift", 0.8, false)
	var t := 0.0
	while t < JUMP_AT:
		var dt: float = await _tick()
		t += dt
		bv -= G * dt
		by += bv * dt
		_put(_b, Vector3(b0.x, by, b0.z))
	# --- The launcher jump: up beside the body in R8_AIR_FOLLOW_TIME.
	_phase = &"follow"
	GameEvents.air_follow_started.emit(_p, _b)
	_rig.fake_air_following = true
	_rig.fake_airborne = true
	var p0 := _p.global_position
	var tf := 0.0
	var follow: float = Tuning.R8_AIR_FOLLOW_TIME
	while tf < follow:
		var dt: float = await _tick()
		tf += dt
		bv -= G * dt
		by += bv * dt
		_put(_b, Vector3(b0.x, by, b0.z))
		var k := smoothstep(0.0, 1.0, minf(tf / follow, 1.0))
		var goal := Vector3(b0.x, by - FEET_BELOW, b0.z) - dir * REACH
		_put(_p, p0.lerp(goal, k))
	_rig.fake_air_following = false
	var pv := 0.0
	var py := _p.global_position.y
	var px := _p.global_position
	# --- Four air hits, each a hang of both, a short fall between.
	_phase = &"hangs"
	for n in HITS:
		_hang_n = n
		_rig.fake_air_hits = n + 1
		_m["hang_t0"] = TimeDirector.now()
		GameEvents.air_hit.emit(_p, _b, n + 1)
		var fov0: float = _rig.get_fov_punch()
		_hit(&"jab", &"snap", AIR_WEIGHT, true)
		var hang_until := TimeDirector.now() + Tuning.R8_AIR_HANG
		var peak := 0.0
		while TimeDirector.now() < hang_until:
			await get_tree().process_frame
			peak = maxf(peak, _rig.get_fov_punch() - fov0)
		punches.append(peak)
		if n >= 1:  # settled framing at the end of hangs 2..4
			_m["raise_min"] = minf(_m["raise_min"], _rig.get_look_point().y - _p.get_aim_point().y)
			_m["dist_min"] = minf(_m["dist_min"], _rig.get_distance())
			_m["air_k_min"] = minf(_m["air_k_min"], _rig.get_air_k())
		var tg := 0.0
		while tg < GAP:
			var dt: float = await _tick()
			tg += dt
			bv -= G * dt
			by += bv * dt
			pv -= G * dt
			py += pv * dt
			_put(_b, Vector3(b0.x, by, b0.z))
			_put(_p, Vector3(px.x, py, px.z))
	var hang_raise: float = _m["raise_min"]
	var hang_dist: float = _m["dist_min"]
	var hang_k: float = _m["air_k_min"]
	var air_body_ok: bool = _rig.get_air_body() == _b
	var body_height := _b.global_position.y
	# --- The finisher: a real launch of the body; the player falls and lands.
	_hang_n = -1
	_phase = &"finish"
	_m["after_t0"] = TimeDirector.now()
	_b.process_mode = Node.PROCESS_MODE_INHERIT
	var v := Vector3.ZERO
	if finish == &"kick":
		var a := deg_to_rad(Tuning.R8_AIR_KICK_ANGLE)
		v = (dir * cos(a) + Vector3.UP * sin(a)) * Tuning.R8_AIR_KICK_LAUNCH
	else:
		var cf: Vector3 = -_rig.get_flat_basis().z
		v = (Vector3.DOWN * cos(deg_to_rad(5.0)) + cf * sin(deg_to_rad(5.0))) * Tuning.R7_SPIKE_SPEED
	_b.launch(v, _b.get_aim_point())
	GameEvents.fighter_launched.emit(_b, v)
	_hit(&"roundhouse" if finish == &"kick" else &"cross", &"launch" if finish == &"kick" else &"spike", 0.9, true, v)
	var landed := false
	var t_end := TimeDirector.now() + maxf(AFTER_LAUNCH, 0.8)
	while TimeDirector.now() < t_end or not landed:
		var dt: float = await _tick()
		if _rig.get_launch_body() == _b:
			launch_picked = true
		if not landed:
			pv -= G * dt
			py += pv * dt
			if py <= 0.05:
				py = 0.05
				landed = true
				_rig.fake_airborne = false
				_rig.fake_air_hits = 0
			_put(_p, Vector3(px.x, py, px.z))
	var spiked: int = _rig.get_spike_impacts() - spikes0
	# After the landing: the air framing eases out.
	_phase = &"after"
	var t_land := TimeDirector.now()
	var out_at := -1.0
	while TimeDirector.now() - t_land < 1.5:
		await get_tree().process_frame
		if out_at < 0.0 and _rig.get_air_k() < 0.05:
			out_at = TimeDirector.now() - t_land
	_probe_on = false
	TimeDirector.reset()
	var pstr := PackedStringArray()
	for x in punches:
		pstr.append("%.2f" % x)
	var tag := "run %d (camera %+.0f deg, lift %.1f m, %s)" % [idx + 1, float(cfg["angle"]), lift, finish]
	print("  %s: body at %.2f m at the last hang; player in view %d/%d (worst %.0f px), body %d/%d (worst %.0f px); hangs 2-4: air framing >= %.2f, look-at >= %.2f m above the player's chest, distance >= %.2f (ground %.2f), look acceleration at a hang <= %.1f m/s^2, distance step <= %.3f m/frame; air hit punches %s deg; roll at most %.2f deg; finisher %s; air framing under 0.05 %.2f s after the landing" % [
		tag, body_height, _m["frames"] - _m["p_out"], _m["frames"], _m["p_worst"], _m["b_frames"] - _m["b_out"], _m["b_frames"], _m["b_worst"],
		hang_k, hang_raise, hang_dist, ground_dist, _m["jolt"], _m["dist_step"], ", ".join(pstr), _m["max_roll"],
		("launch framing on the body" if launch_picked else "launch framing missed") if finish == &"kick" else ("%d spike impact" % spiked), out_at])
	_check(_m["p_out"] == 0 and _m["b_out"] == 0, "%s: the player and the body stay in the viewport" % tag)
	_check(air_body_ok and hang_k > 0.9 and hang_raise > CameraRig.AIR_LOOK_RAISE * 0.8 and hang_dist > ground_dist + CameraRig.AIR_PULLBACK * 0.8,
		"%s: the air framing raises the look-at and pulls back during the hangs" % tag)
	_check(_m["jolt"] < LOOK_JOLT and _m["dist_step"] < DIST_JOLT, "%s: no jolt at the hangs (look %.1f m/s^2, distance %.3f m/frame)" % [tag, _m["jolt"], _m["dist_step"]])
	var punch_ok := true
	for x in punches:
		if x > AIR_WEIGHT * Tuning.R7_CAM_PUNCH_FOV * CameraRig.AIR_HIT_PUNCH_SHARE + 0.05:
			punch_ok = false
	_check(punch_ok, "%s: air hits punch at %.0f%% of their weight" % [tag, CameraRig.AIR_HIT_PUNCH_SHARE * 100.0])
	if finish == &"kick":
		_check(launch_picked, "%s: the launch framing picks up the kicked body" % tag)
	else:
		_check(spiked == 1, "%s: the spike's floor impact punches once" % tag)
	_check(_m["max_roll"] < 0.5 and out_at > 0.0 and not _rig.is_air_combo(), "%s: no fall tilt, and the air framing eases out after the landing" % tag)
	return {"frames": _m["frames"], "p_out": _m["p_out"], "b_frames": _m["b_frames"], "b_out": _m["b_out"],
		"p_worst": _m["p_worst"], "b_worst": _m["b_worst"]}

func _put(f: Fighter, pos: Vector3) -> void:
	f.global_position = pos
	f.velocity = Vector3.ZERO

## The player's strike on the body as B reports it.
func _hit(move: StringName, react: StringName, weight: float, air: bool, v := Vector3.ZERO) -> void:
	var info := HitInfo.new()
	info.attacker = _p
	info.victim = _b
	info.move_id = move
	info.react = react
	info.weight = weight
	info.air = air
	info.charged = not air
	info.charge = 1.0 if not air else 0.0
	info.launch_velocity = v
	info.tier = HitInfo.Tier.LAUNCH if react in [&"launch", &"spike"] else HitInfo.Tier.STAGGER
	info.reaction = HitInfo.Reaction.LAUNCH if react in [&"launch", &"spike"] else HitInfo.Reaction.STAGGER
	info.hit_position = _b.get_aim_point()
	info.hit_direction = (_b.global_position - _p.global_position).normalized()
	info.damage = 1.0
	GameEvents.hit_landed.emit(info)
