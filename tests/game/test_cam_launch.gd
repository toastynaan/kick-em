extends Node
## F1 launch camera (Feel Reference: Camera > Launch; Build task F1) under
## Round 7 (Acceptance 10: the player stays on screen through launches): 50
## launches in random directions (random camera yaw; two in five are Round 7
## launch payoffs (HitInfo.react &"launch", the R7_PAYOFFS speeds and angles,
## with TimeDirector's finisher slow time), one in five with the player
## turning the camera, one in five with a combat target the look-at was leaning
## toward (test_cam_fake_rig.gd), one in five a thrown body (GameEvents.thrown);
## walls and pillars around). On every rendered frame the player's chest, head
## and feet must be inside the viewport (Camera3D.unproject_position against the
## visible rect, measured after the rig has placed the camera). Also logged: the
## launch yaw never passes Tuning.CAM_LAUNCH_YAW_RATE (the combat auto-yaw never
## passes R7_CAM_AUTO_YAW_RATE) and neither runs while the player is turning
## the camera, the framing distance never passes CAM_LAUNCH_DIST, the look-at
## lean is gone by CAM_LAUNCH_FOLLOW, the arm never shortens for a ragdoll
## (WORLD-only casts), how often the body was framed, and each launch payoff
## asked TimeDirector for the finisher exactly once.

const FakeRig := preload("res://tests/game/test_cam_fake_rig.gd")
const LAUNCHES := 50
## Round 7 launch payoffs: [move, victim state] from Tuning.R7_PAYOFFS.
const PAYOFFS: Array = [[&"heavy_hook", &"fold"], [&"front_kick", &"fold"], [&"front_kick", &"lift"],
	[&"roundhouse", &"lift"]]
const WATCH := 1.6          ## real s watched per launch (the 1.0 s follow and the return)
const SEED := 20261102

var _fails := 0
var _rng := RandomNumberGenerator.new()

# Per-frame measurement (filled by the probe after the rig has run).
var _rig: CameraRig
var _player: Fighter
var _victim: Fighter
var _measuring := false
var _launch_t0 := 0.0
var _frames := 0
var _out_frames := 0
var _worst := {"chest": INF, "head": INF, "feet": INF}
var _worst_at := ""
var _max_yaw_rate := 0.0
var _yaw_during_input := 0
var _max_dist := 0.0
var _late_lean := 0.0
var _body_frames := 0
var _body_in := 0
var _corrections := 0
var _launch_index := 0
var _max_combat_yaw := 0.0
var _combat_yaw_input := 0
var _other: Fighter

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
	print("TEST test_cam_launch: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
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
func _margin(cam: Camera3D, p: Vector3, size: Vector2) -> float:
	if cam.is_position_behind(p):
		return -1e6
	var s := cam.unproject_position(p)
	return minf(minf(s.x, size.x - s.x), minf(s.y, size.y - s.y))

func _measure() -> void:
	if not _measuring or not is_instance_valid(_rig) or not is_instance_valid(_player):
		return
	var cam := _rig.camera
	var size := get_viewport().get_visible_rect().size
	var aim := _player.get_aim_point()
	var pts := {"chest": aim, "head": aim + Vector3.UP * 0.5, "feet": _player.get_ground_position() + Vector3.UP * 0.05}
	_frames += 1
	var out := false
	for k: String in pts:
		var m := _margin(cam, pts[k], size)
		if m < _worst[k]:
			_worst[k] = m
			_worst_at = "launch %d, %.2f s after" % [_launch_index, TimeDirector.now() - _launch_t0]
		if m < 0.0:
			out = true
	if out:
		_out_frames += 1
	var age := TimeDirector.now() - _launch_t0
	_max_yaw_rate = maxf(_max_yaw_rate, _rig.get_auto_yaw_rate())
	if _rig.get_auto_yaw_rate() > 0.0 and _rig.get_input_age() < CameraRig.LAUNCH_INPUT_YIELD:
		_yaw_during_input += 1
	_max_combat_yaw = maxf(_max_combat_yaw, _rig.get_combat_yaw_rate())
	if _rig.get_combat_yaw_rate() > 0.0 and _rig.get_input_age() < Tuning.CAM_MOUSE_IDLE:
		_combat_yaw_input += 1
	_max_dist = maxf(_max_dist, _rig.get_distance())
	if _rig.get_view_correction() > 0.0005:
		_corrections += 1
	if age > Tuning.CAM_LAUNCH_FOLLOW + 0.1:
		_late_lean = maxf(_late_lean, _rig._launch_lean.length())
	if age < Tuning.CAM_LAUNCH_FOLLOW and is_instance_valid(_victim):
		_body_frames += 1
		if cam.is_position_in_frustum(_victim.get_center_of_mass()):
			_body_in += 1

func _run() -> void:
	# Arena: floor, outer walls 14 m out, two pillars near the middle (all WORLD).
	_box(Vector3(0, -0.5, 0), Vector3(60, 1, 60), "Floor")
	_box(Vector3(0, 2, -14.2), Vector3(30, 4, 0.4), "WallN")
	_box(Vector3(0, 2, 14.2), Vector3(30, 4, 0.4), "WallS")
	_box(Vector3(-14.2, 2, 0), Vector3(0.4, 4, 30), "WallW")
	_box(Vector3(14.2, 2, 0), Vector3(0.4, 4, 30), "WallE")
	_box(Vector3(4.0, 2, 3.0), Vector3(0.8, 4, 0.8), "Pillar1")
	_box(Vector3(-3.5, 2, -4.0), Vector3(0.8, 4, 0.8), "Pillar2")
	var world := Node3D.new()
	add_child(world)
	_player = FighterFactory.spawn_player(world, Transform3D(Basis(), Vector3(0, 0.05, 0)))
	AttackDirector.set_player(_player)
	_rig = FakeRig.new()
	_rig.target = _player
	add_child(_rig)
	var probe := Probe.new()
	probe.owner_test = self
	probe.process_priority = 1000  # after the rig: measures what is rendered
	add_child(probe)
	await _wait_real(0.6)
	_check(_rig.arm.collision_mask == Layers.WORLD and _rig._cast_q.collision_mask == Layers.WORLD,
		"arm casts are WORLD-only (ragdolls, dead bodies and debris never move the camera)")

	# Bodies and debris in the arm's path never pull the camera in.
	for layer: int in [Layers.RAGDOLL, Layers.DEAD_BODY, Layers.DEBRIS, Layers.DEBRIS_SMALL, Layers.DESTRUCTIBLE]:
		var before := _rig.get_arm_length()
		var cam_pos := _rig.camera.global_position
		var blocker := _box((_rig._pivot + cam_pos) * 0.5, Vector3(1.2, 1.2, 1.2), "Blocker")
		blocker.collision_layer = layer
		await _wait_real(0.4)
		_check(absf(_rig.get_arm_length() - before) < 0.05,
			"a layer-%d body in the arm's path leaves the arm at %.2f m (was %.2f)" % [layer, _rig.get_arm_length(), before])
		blocker.queue_free()
		await get_tree().process_frame
	var with_input := 0
	var with_target := 0
	var with_throw := 0
	var with_r7 := 0
	var finisher_ok := 0
	var finisher_rows := PackedStringArray()
	for i in LAUNCHES:
		_launch_index = i
		# Fresh victim at a random side of the player, 1.3 m off.
		if is_instance_valid(_victim):
			_victim.queue_free()
		var around := _rng.randf_range(-PI, PI)
		var at := Vector3(sin(around), 0.0, cos(around)) * 1.3 + Vector3(0, 0.05, 0)
		_player.teleport_to(Vector3(0, 0.05, 0), at)
		_victim = FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis.looking_at(-at), at))
		# Random camera yaw (the player turned the camera earlier).
		_rig.apply_manual_input(Vector2(_rng.randf_range(-PI, PI), 0.0))
		_rig.set(&"fake_target", null)
		if is_instance_valid(_other):
			_other.queue_free()
		await _wait_real(0.35)
		if i % 5 == 3:
			# The look-at was leaning toward another enemy (the combat target) when the launch lands.
			var side := Vector3(-at.z, 0.0, at.x).normalized() * 2.2 + Vector3(0, 0.05, 0)
			_other = FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis.looking_at(-side), side))
			_rig.set(&"fake_target", _other)
			with_target += 1
			await _wait_real(0.8)
		# Launch away from the player, +-50 deg.
		var dir := Vector3(at.x, 0.0, at.z).normalized().rotated(Vector3.UP, deg_to_rad(_rng.randf_range(-50.0, 50.0)))
		var info := HitInfo.new()
		info.attacker = _player
		info.victim = _victim
		info.hit_position = _victim.get_aim_point()
		info.hit_direction = dir
		info.damage = 1.0
		var r7 := i % 5 == 0 or i % 5 == 2
		var v := Vector3.ZERO
		if r7:
			# Round 7 launch payoff: the table's speed and angle, react &"launch", the move's weight.
			var pay: Array = PAYOFFS[(int(i / 5.0) * 2 + (1 if i % 5 == 2 else 0)) % PAYOFFS.size()]
			var row: Dictionary = Tuning.R7_PAYOFFS[pay[0]][pay[1]]
			var up := deg_to_rad(float(row["launch_angle"]))
			v = (dir * cos(up) + Vector3.UP * sin(up)) * float(row["launch_speed"])
			info.move_id = pay[0]
			info.react = &"launch"
			info.payoff = true
			info.victim_state = pay[1]
			info.weight = float(Tuning.R7_MOVES[pay[0]]["weight"])
			info.tier = HitInfo.Tier.LAUNCH
			with_r7 += 1
		else:
			# Round 5 power launches (P 5..12: launch .. severing launch): other sources still frame alike.
			var power := _rng.randf_range(5.0, 12.0)
			v = Power.launch_velocity(power, dir, _victim.get_total_mass())
			info.move_id = &"kick"
			info.power = power
			info.tier = Power.tier_of(power)
			info.reaction = HitInfo.reaction_for_tier(info.tier)
		info.launch_velocity = v
		_victim.launch(v, _victim.get_aim_point())
		if i % 5 == 4:
			# A thrown body (G's Carry emits thrown): framed by the same rules.
			GameEvents.thrown.emit(_player, _victim, v)
			with_throw += 1
		else:
			var n0 := TimeDirector.get_finisher_requests()
			GameEvents.fighter_launched.emit(_victim, v)
			GameEvents.hit_landed.emit(info)
			var asked := TimeDirector.get_finisher_requests() - n0
			if r7:
				var slowed := absf(Engine.time_scale - float(Tuning.SLOW_TIME[&"finisher"]["scale"])) < 0.001
				if asked == 1 and slowed:
					finisher_ok += 1
				finisher_rows.append("%s on %s %.0f m/s: %d request, %.2fx" % [info.move_id, info.victim_state, v.length(), asked, Engine.time_scale])
			elif asked != 0:
				finisher_rows.append("launch %d (no payoff) asked for the finisher" % i)
		_launch_t0 = TimeDirector.now()
		_measuring = true
		var turning := i % 5 == 1
		if turning:
			with_input += 1
		var until := _launch_t0 + WATCH
		var sign_in := 1.0 if _rng.randf() < 0.5 else -1.0
		while TimeDirector.now() < until:
			if turning and TimeDirector.now() - _launch_t0 < 0.8:
				_rig.apply_manual_input(Vector2(0.025 * sign_in, 0.0))  # ~3 rad/s: the player is turning the camera
			await get_tree().process_frame
		_measuring = false
		TimeDirector.reset()

	print("  F1 measured: %d launches (%d Round 7 launch payoffs, %d thrown bodies, %d with camera input, %d with a combat target), %d frames watched" % [
		LAUNCHES, with_r7, with_throw, with_input, with_target, _frames])
	print("  finisher: ", "; ".join(finisher_rows.slice(0, 6)), " ...")
	print("  F1 worst viewport margin (px, negative = outside): chest %.0f, head %.0f, feet %.0f  (worst at %s)" % [
		_worst["chest"], _worst["head"], _worst["feet"], _worst_at])
	print("  F1 body framed on %d / %d follow frames (%.0f%%); view corrections on %d frames" % [
		_body_in, _body_frames, 100.0 * _body_in / maxf(_body_frames, 1.0), _corrections])
	_check(_out_frames == 0, "F1: the player (chest, head, feet) is inside the viewport on every frame (%d / %d frames outside)" % [_out_frames, _frames])
	_check(_frames > LAUNCHES * 100, "watched every launch (%d frames)" % _frames)
	_check(_max_yaw_rate <= deg_to_rad(Tuning.CAM_LAUNCH_YAW_RATE) + 0.001,
		"launch yaw never faster than %.0f deg/s (max %.1f deg/s)" % [Tuning.CAM_LAUNCH_YAW_RATE, rad_to_deg(_max_yaw_rate)])
	_check(_yaw_during_input == 0, "no launch yaw while the player turns the camera (%d frames)" % _yaw_during_input)
	_check(_max_combat_yaw <= deg_to_rad(Tuning.R7_CAM_AUTO_YAW_RATE) + 0.001 and _combat_yaw_input == 0,
		"combat auto-yaw at most %.0f deg/s (max %.1f), never within %.1f s of camera input (%d frames)" % [
		Tuning.R7_CAM_AUTO_YAW_RATE, rad_to_deg(_max_combat_yaw), Tuning.CAM_MOUSE_IDLE, _combat_yaw_input])
	_check(finisher_ok == with_r7 and finisher_rows.size() == with_r7,
		"every launch payoff asked TimeDirector for the finisher once, and it slowed time (%d / %d; other launches never asked)" % [finisher_ok, with_r7])
	_check(_max_dist <= Tuning.CAM_LAUNCH_DIST + 0.01, "framing distance never past %.0f m (max %.2f m)" % [Tuning.CAM_LAUNCH_DIST, _max_dist])
	_check(_late_lean < 0.15, "the look-at lean is gone by %.1f s + 0.1 (max %.2f m left)" % [Tuning.CAM_LAUNCH_FOLLOW, _late_lean])
	_check(_body_in > _body_frames * 0.5, "the flying body is framed on most follow frames (%d / %d)" % [_body_in, _body_frames])
