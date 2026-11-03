extends Node
## The camera on the god path (docs/Round 7 — Freeflow Combat.md: Amendment,
## God path). Teleports and pursuits are driven the way Defence (H) does them
## (teleport_to, hang, then GameEvents.teleported / pursuit), relaunches and
## spikes the way CombatController (B) reports them (HitInfo.pursuit):
## - Teleport counter: the FOV punches, TimeDirector's teleport slow time, and
##   the follow swoops to the new spot (never a cut), the player always in view.
## - Pursuit chains: eight launches (random camera yaw and direction), each
##   followed by up to three pursuits and relaunches along camera forward. On
##   every frame the player is in the viewport; the flying body is framed on
##   most frames; the launch framing stays on the body through the chain; no
##   camera cut.
## - Spike: the spiked body's floor impact (its own fall stopping, or the
##   player's shockwave right after the spike) pitches the view down by
##   SPIKE_PITCH_PUNCH and raises the trauma to SPIKE_TRAUMA, once per spike;
##   a heavy landing's shockwave, a far one, or an enemy's spike never does.

const CHAINS := 8
const LINKS := 3                ## pursuits per chain (Tuning.debug_pursuit_max at most 3)
const PURSUE_AFTER := 0.3       ## real s after a launch the pursuit fires (inside PURSUIT_WINDOW)
const FEET_BELOW := 0.9         ## m the pursuer's feet sit below the body's centre (as Defence)
const MAX_STEP := 1.0           ## m the camera may move in one frame: a cut of a teleport is several
const SEED := 20261103

var _fails := 0
var _rng := RandomNumberGenerator.new()
var _rig: CameraRig
var _p: Fighter
var _world: Node3D
var _victim: Fighter
var _last_launch_t := -100.0   ## real time of the latest launch or relaunch

# Probe (after the rig).
var _probe_on := false
var _m := {}

class Probe:
	extends Node
	var owner_test: Node
	func _process(_d: float) -> void:
		owner_test.call(&"_measure")

func _ready() -> void:
	for i in 5:
		await get_tree().process_frame
	_rng.seed = SEED
	await _run()
	AttackDirector.reset()
	TimeDirector.reset()
	print("TEST test_cam_godpath: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
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

## Pixels from the nearest viewport edge (negative = outside, -1e6 = behind the camera).
func _margin(p: Vector3) -> float:
	var cam := _rig.camera
	var size := get_viewport().get_visible_rect().size
	if cam.is_position_behind(p):
		return -1e6
	var s := cam.unproject_position(p)
	return minf(minf(s.x, size.x - s.x), minf(s.y, size.y - s.y))

func _reset_probe() -> void:
	_m = {"frames": 0, "out": 0, "worst": INF, "body_frames": 0, "body_in": 0, "framed": 0, "follow_frames": 0,
		"max_step": 0.0, "prev": null, "max_pitch_punch": 0.0, "min_dip": 0.0}

func _measure() -> void:
	if not _probe_on or not is_instance_valid(_rig) or not is_instance_valid(_p):
		return
	_m["frames"] += 1
	var aim := _p.get_aim_point()
	var worst := INF
	for q: Vector3 in [aim, aim + Vector3.UP * 0.5, _p.get_ground_position() + Vector3.UP * 0.05]:
		worst = minf(worst, _margin(q))
	_m["worst"] = minf(_m["worst"], worst)
	if worst < 0.0:
		_m["out"] += 1
	if is_instance_valid(_victim) and _victim.is_launched():
		_m["body_frames"] += 1
		if _rig.camera.is_position_in_frustum(_victim.get_center_of_mass()):
			_m["body_in"] += 1
		# The launch framing holds its full lean until LAUNCH_LEAN_OUT.x after each
		# launch or relaunch (then eases out within CAM_LAUNCH_FOLLOW).
		if TimeDirector.now() - _last_launch_t <= CameraRig.LAUNCH_LEAN_OUT.x:
			_m["follow_frames"] += 1
			if _rig.get_launch_body() == _victim:
				_m["framed"] += 1
	var pos := _rig.camera.global_position
	if _m["prev"] != null:
		_m["max_step"] = maxf(_m["max_step"], pos.distance_to(_m["prev"]))
	_m["prev"] = pos
	_m["max_pitch_punch"] = maxf(_m["max_pitch_punch"], _rig.get_pitch_punch())
	# How far the rendered view looks below the rig's own pitch (the downward punch).
	var fwd := -_rig.camera.global_basis.z
	var cam_pitch := asin(clampf(fwd.y, -1.0, 1.0))
	_m["min_dip"] = minf(_m["min_dip"], rad_to_deg(cam_pitch - _rig.get_view_pitch()))

## A Round 7 launch by the player (B's report of a payoff or relaunch).
func _launch_hit(v: Vector3, move: StringName, pursuit := false, react := &"launch") -> HitInfo:
	var info := HitInfo.new()
	info.attacker = _p
	info.victim = _victim
	info.move_id = move
	info.react = react
	info.weight = float(Tuning.R7_MOVES[move]["weight"])
	info.payoff = not pursuit and react == &"launch"
	info.pursuit = pursuit
	info.tier = HitInfo.Tier.LAUNCH if react == &"launch" else HitInfo.Tier.KNOCKDOWN
	info.reaction = HitInfo.Reaction.LAUNCH
	info.launch_velocity = v
	info.hit_position = _victim.get_aim_point()
	info.hit_direction = Vector3(v.x, 0.0, v.z).normalized() if Vector2(v.x, v.z).length() > 0.1 else Vector3.FORWARD
	info.damage = 1.0
	return info

func _launch(v: Vector3, move: StringName, pursuit := false, react := &"launch") -> void:
	var info := _launch_hit(v, move, pursuit, react)
	_victim.launch(v, _victim.get_aim_point())
	_last_launch_t = TimeDirector.now()
	GameEvents.fighter_launched.emit(_victim, v)
	GameEvents.hit_landed.emit(info)

## As Defence._start_pursuit: next to the body, behind it along its flight, the
## feet below its centre, hang for the attack; then teleported and pursuit.
func _pursue() -> float:
	var com := _victim.get_center_of_mass()
	var vel := _victim.get_com_velocity()
	var along := Vector3(vel.x, 0.0, vel.z)
	along = along.normalized() if along.length() > 1.0 else (com - _p.global_position).normalized()
	along.y = 0.0
	var spot := Vector3(com.x, 0.0, com.z) - along.normalized() * Tuning.PURSUIT_DIST
	spot.y = maxf(0.05, com.y - FEET_BELOW)
	var from := _p.global_position
	_p.teleport_to(spot, com - spot)
	_p.hang(Tuning.PURSUIT_HANG)
	GameEvents.teleported.emit(_p, from, spot, &"pursuit")
	GameEvents.pursuit.emit(_p, _victim)
	return from.distance_to(spot)

func _run() -> void:
	_box(Vector3(0, -0.5, 0), Vector3(240, 1, 240), "Floor")
	_world = Node3D.new()
	add_child(_world)
	_p = FighterFactory.spawn_player(_world, Transform3D(Basis(), Vector3(0, 0.05, 0)))
	_p.max_hp = 100000.0
	_p.hp = _p.max_hp
	AttackDirector.set_player(_p)
	_rig = CameraRig.new()
	_rig.target = _p
	add_child(_rig)
	var probe := Probe.new()
	probe.owner_test = self
	probe.process_priority = 1000  # after the rig: measures what is rendered
	add_child(probe)
	await _wait_real(0.6)
	for pair: Array in [[GameEvents.teleported, _rig._on_teleported], [GameEvents.teleport_counter, _rig._on_teleport_counter],
			[GameEvents.pursuit, _rig._on_pursuit], [GameEvents.shockwave, _rig._on_shockwave],
			[GameEvents.rammed, _rig._on_rammed]]:
		_check((pair[0] as Signal).is_connected(pair[1]), "camera listens to GameEvents.%s" % (pair[0] as Signal).get_name())
	await _teleport_counter()
	await _pursuit_chains()
	await _spikes()

# --- Teleport counter --------------------------------------------------------------------------
func _teleport_counter() -> void:
	_p.teleport_to(Vector3(0, 0.05, 0), Vector3.FORWARD)
	var attacker := FighterFactory.spawn_dummy(_world, &"grunt", Transform3D(Basis.looking_at(Vector3.BACK), Vector3(1.0, 0.05, -2.0)))
	await get_tree().process_frame
	_rig.snap_behind()
	await _wait_real(1.0)
	_reset_probe()
	_probe_on = true
	var from := _p.global_position
	var spot := attacker.global_position + Vector3(0, 0, -Tuning.TELEPORT_SPOTS[0].y)  # behind the attacker
	_p.teleport_to(spot, attacker.global_position - spot)
	GameEvents.teleported.emit(_p, from, spot, &"counter")
	var scale := Engine.time_scale
	var t0 := TimeDirector.now()
	var settle := -1.0
	var punch := 0.0
	while TimeDirector.now() - t0 < 0.8:
		await get_tree().process_frame
		punch = maxf(punch, _rig.get_fov_punch())
		if settle < 0.0 and (_rig._follow - _p.get_aim_point()).length() < 0.05:
			settle = TimeDirector.now() - t0
	_probe_on = false
	print("  teleport counter %.2f m: time %.2fx, FOV punch %.2f deg, camera step at most %.2f m/frame, follow settled in %.2f s, player in view %d/%d (worst margin %.0f px)" % [
		from.distance_to(spot), scale, punch, _m["max_step"], settle, _m["frames"] - _m["out"], _m["frames"], _m["worst"]])
	_check(absf(scale - float(Tuning.SLOW_TIME[&"teleport"]["scale"])) < 0.001, "the player's counter teleport slows time to %.2fx" % float(Tuning.SLOW_TIME[&"teleport"]["scale"]))
	_check(punch > 2.0, "and punches the FOV (%.2f deg)" % punch)
	_check(_m["max_step"] < MAX_STEP and settle > 0.05 and settle < 0.4,
		"the follow swoops to the new spot, never a cut (%.2f m/frame at most, settled in %.2f s)" % [_m["max_step"], settle])
	_check(_m["out"] == 0, "the player stays in the viewport through the teleport")
	TimeDirector.reset()
	attacker.queue_free()
	await _wait_real(0.3)

# --- Pursuit chains -----------------------------------------------------------------------------
func _pursuit_chains() -> void:
	var rows: Array[String] = []
	var tot := {"frames": 0, "out": 0, "worst": INF, "body_frames": 0, "body_in": 0, "framed": 0, "follow_frames": 0, "max_step": 0.0}
	var pursuits0 := _rig.get_pursuit_count()
	var jumps := 0.0
	var links_done := 0
	for c in CHAINS:
		_p.teleport_to(Vector3(0, 0.05, 0), Vector3.FORWARD)
		if is_instance_valid(_victim):
			_victim.queue_free()
		await get_tree().process_frame
		_rig.snap_behind()
		_rig.apply_manual_input(Vector2(_rng.randf_range(-PI, PI), 0.0))  # the player turned the camera earlier
		await _wait_real(0.3)
		var fwd := -_rig.get_flat_basis().z
		var dir := fwd.rotated(Vector3.UP, deg_to_rad(_rng.randf_range(-60.0, 60.0)))
		var at := _p.global_position + dir * 1.3
		_victim = FighterFactory.spawn_dummy(_world, &"grunt", Transform3D(Basis.looking_at(-dir), at))
		await _wait_real(0.4)
		_reset_probe()
		_probe_on = true
		# The opener: a launch payoff (roundhouse on a lifted body: 15 m/s, 12 deg up).
		var row: Dictionary = Tuning.R7_PAYOFFS[&"roundhouse"][&"lift"]
		var a := deg_to_rad(float(row["launch_angle"]))
		_launch((dir * cos(a) + Vector3.UP * sin(a)) * float(row["launch_speed"]), &"roundhouse")
		var chain_rows := PackedStringArray()
		for k in LINKS:
			await _wait_real(PURSUE_AFTER)
			if not is_instance_valid(_victim) or not _victim.is_launched():
				break
			var j := _pursue()
			jumps = maxf(jumps, j)
			await _wait_real(Tuning.PURSUIT_HANG)
			# The pursuit hit: relaunch along camera forward at max(speed, 15 m/s), 20 deg up.
			var cf := -_rig.get_flat_basis().z
			var speed := maxf(_victim.get_com_velocity().length(), Tuning.R7_PURSUIT_RELAUNCH_SPEED)
			speed = minf(speed, Tuning.LAUNCH_SPEED_MAX)
			var up := deg_to_rad(Tuning.R7_PURSUIT_RELAUNCH_ANGLE)
			_launch((cf * cos(up) + Vector3.UP * sin(up)) * speed, &"hook", true)
			links_done += 1
			chain_rows.append("%.1f m jump" % j)
		await _wait_real(1.4)
		_probe_on = false
		TimeDirector.reset()
		for key: String in ["frames", "out", "body_frames", "body_in", "framed", "follow_frames"]:
			tot[key] = int(tot[key]) + int(_m[key])
		tot["worst"] = minf(tot["worst"], _m["worst"])
		tot["max_step"] = maxf(tot["max_step"], _m["max_step"])
		rows.append("chain %d: %s; player in view %d/%d (worst %.0f px); body in frame %d/%d, launch framing on it %d/%d follow frames; camera step at most %.2f m" % [
			c + 1, ", ".join(chain_rows), _m["frames"] - _m["out"], _m["frames"], _m["worst"], _m["body_in"], _m["body_frames"],
			_m["framed"], _m["follow_frames"], _m["max_step"]])
	if is_instance_valid(_victim):
		_victim.queue_free()
	for r in rows:
		print("  pursuit ", r)
	print("  pursuit chains: %d links, teleports up to %.1f m; player in view %d/%d (worst margin %.0f px); body in frame %d/%d (%.0f%%); launch framing on the body %d/%d frames within %.1f s of a launch or relaunch; camera step at most %.2f m/frame" % [
		links_done, jumps, tot["frames"] - tot["out"], tot["frames"], tot["worst"], tot["body_in"], tot["body_frames"],
		100.0 * tot["body_in"] / maxf(tot["body_frames"], 1.0), tot["framed"], tot["follow_frames"], CameraRig.LAUNCH_LEAN_OUT.x, tot["max_step"]])
	_check(links_done >= CHAINS * 2 and _rig.get_pursuit_count() - pursuits0 == links_done,
		"the rig saw every pursuit (%d links)" % links_done)
	_check(tot["out"] == 0, "the player stays in the viewport through every pursuit chain")
	_check(tot["body_in"] > tot["body_frames"] * 0.75, "the flying body stays framed through the chains (%d / %d frames)" % [tot["body_in"], tot["body_frames"]])
	_check(tot["framed"] >= tot["follow_frames"] - 2 * CHAINS, "the launch framing stays on the body through every pursuit and relaunch (%d / %d frames)" % [tot["framed"], tot["follow_frames"]])
	_check(tot["max_step"] < MAX_STEP, "no camera cut on a pursuit teleport (%.2f m/frame at most)" % tot["max_step"])

# --- Spike ----------------------------------------------------------------------------------------
## Pop the body up, then spike it from the apex. Returns the probe's numbers
## and the impact the rig recorded. via_shockwave: the player's shockwave
## arrives right after the spike hit (before the body lands).
func _spike_once(via_shockwave: bool) -> Dictionary:
	_p.teleport_to(Vector3(0, 0.05, 0), Vector3.FORWARD)
	if is_instance_valid(_victim):
		_victim.queue_free()
	await get_tree().process_frame
	_rig.snap_behind()
	_victim = FighterFactory.spawn_dummy(_world, &"grunt", Transform3D(Basis.looking_at(Vector3.BACK), Vector3(0, 0.05, -2.2)))
	await _wait_real(0.5)
	_launch(Vector3(0, 7.0, -0.5), &"uppercut")
	await _wait_real(0.55)  # near the apex
	TimeDirector.reset()
	_pursue()
	await _wait_real(Tuning.PURSUIT_HANG)
	_rig._trauma = 0.0
	var n0 := _rig.get_spike_impacts()
	var h0 := _rig.get_spike_hits()
	_reset_probe()
	_probe_on = true
	var height := _victim.get_center_of_mass().y - _victim.get_ground_position().y
	var cf := -_rig.get_flat_basis().z
	var v := (Vector3.DOWN * cos(deg_to_rad(5.0)) + cf * sin(deg_to_rad(5.0))) * Tuning.R7_SPIKE_SPEED
	_launch(v, &"roundhouse", true, &"spike")
	var t0 := TimeDirector.now()
	if via_shockwave:
		_rig._on_shockwave(_p, _victim.get_ground_position(), Tuning.R7_SPIKE_BLAST_RADIUS, Tuning.SHOCK_KNOCKDOWN_RADIUS)
	var at := -1.0
	var trauma := 0.0
	while TimeDirector.now() - t0 < 0.9:
		await get_tree().process_frame
		if at < 0.0 and _rig.get_spike_impacts() > n0:
			at = TimeDirector.now() - t0
			trauma = _rig.get_trauma()
	_probe_on = false
	TimeDirector.reset()
	return {"hits": _rig.get_spike_hits() - h0, "impacts": _rig.get_spike_impacts() - n0, "at": at, "trauma": trauma,
		"by": _rig.get_last_spike().get("by", &""), "height": height, "pitch": _m["max_pitch_punch"], "dip": _m["min_dip"],
		"out": _m["out"], "frames": _m["frames"], "worst": _m["worst"]}

func _spikes() -> void:
	var fall := await _spike_once(false)
	var sw := await _spike_once(true)
	for r: Array in [["by the body's own fall", fall], ["by the player's shockwave", sw]]:
		var d: Dictionary = r[1]
		print("  spike from %.1f m, impact %s: %d hit, %d impact (%s) %.2f s after the spike; trauma %.2f; downward punch up to %.1f deg (view %.1f deg below the rig's pitch); player in view %d/%d (worst %.0f px)" % [
			d["height"], r[0], d["hits"], d["impacts"], d["by"], d["at"], d["trauma"], d["pitch"], -float(d["dip"]),
			d["frames"] - d["out"], d["frames"], d["worst"]])
	_check(fall["hits"] == 1 and fall["impacts"] == 1 and fall["by"] == &"fall" and fall["at"] > 0.0 and fall["at"] < 0.5,
		"a spike's floor impact is caught from the body's own fall, once (%.2f s after the hit)" % fall["at"])
	_check(sw["impacts"] == 1 and sw["by"] == &"shockwave", "with the player's shockwave right after the spike: that is the impact, once (no second punch when the body lands)")
	for d: Dictionary in [fall, sw]:
		_check(d["trauma"] >= CameraRig.SPIKE_TRAUMA - 0.02, "big trauma at the impact (%.2f, at least %.2f)" % [d["trauma"], CameraRig.SPIKE_TRAUMA])
		_check(absf(float(d["pitch"]) - CameraRig.SPIKE_PITCH_PUNCH) < 0.3 and -float(d["dip"]) > CameraRig.SPIKE_PITCH_PUNCH * 0.8,
			"the view punches down %.0f deg (punch %.1f, the rendered view %.1f deg below the rig's pitch)" % [CameraRig.SPIKE_PITCH_PUNCH, d["pitch"], -float(d["dip"])])
		_check(d["out"] == 0, "the player stays in the viewport through the spike")
	# Not a spike: a heavy landing's shockwave (same stumble radius), a far shockwave, an enemy's spike.
	var n0 := _rig.get_spike_impacts()
	_rig._on_shockwave(_p, _p.global_position, Tuning.SHOCK_STUMBLE_RADIUS, Tuning.SHOCK_KNOCKDOWN_RADIUS)
	_check(_rig.get_spike_impacts() == n0, "a heavy landing's shockwave (radius %.1f m too) is not a spike" % Tuning.SHOCK_STUMBLE_RADIUS)
	_victim.teleport_to(Vector3(0, 0.05, -2.2), Vector3.BACK)
	await _wait_real(0.3)
	var spike := _launch_hit(Vector3.DOWN * Tuning.R7_SPIKE_SPEED, &"roundhouse", true, &"spike")
	_rig._on_hit_landed(spike)
	_rig._on_shockwave(_p, _victim.get_ground_position() + Vector3(8.0, 0, 0), Tuning.R7_SPIKE_BLAST_RADIUS, 1.0)
	_check(_rig.get_spike_impacts() == n0, "a shockwave %.0f m from the spiked body is not its impact" % 8.0)
	_rig._spike_body = null
	var enemy := FighterFactory.spawn_dummy(_world, &"grunt", Transform3D(Basis(), Vector3(3, 0.05, 0)))
	await get_tree().process_frame
	var h0 := _rig.get_spike_hits()
	var theirs := _launch_hit(Vector3.DOWN * Tuning.R7_SPIKE_SPEED, &"roundhouse", true, &"spike")
	theirs.attacker = enemy
	_rig._on_hit_landed(theirs)
	_check(_rig.get_spike_hits() == h0, "an enemy's spike starts no spike watch")
	enemy.queue_free()
	_victim.queue_free()
