extends Node
## Round 5 camera framing kept under Round 7 (Feel Reference: Camera; F2, F7,
## F7b, F11; the Round 7 doc keeps the crowd and duel distances, the
## amendment keeps the wall run):
## - F11: the logged camera distance follows the number of enemies alive over
##   two scripted waves (crowd 7-9 m and 2.5 m higher with 3+ alive, the
##   nearest 3 framed; 4-5 m low over the shoulder with 1-2 left; smooth).
## - F2: FOV 70 -> 78 by sprint_charge (85 at the 12 m/s cap), +1.5 m, 0.3 m
##   lower; a sprint strike's drop to walk eases the FOV back (no snap).
## - F7: a fall past 3 m rolls up to 8 deg and pitches down; landing clears it.
## - F7b: a wall run shifts 1.5 m to the open side, rolls 6 deg away from the
##   wall, and leaves the run wall out of the arm's casts.
## - Low WORLD geometry (a 0.9 m wall, the 1.8 m platform) never pulls the arm
##   in; it fades when it blocks the view. A 4 m wall still collides.
## - Shake: trauma per event (Tuning.TRAUMA / Power.trauma_for), shake = trauma^2,
##   decaying Tuning.TRAUMA_DECAY per s (hits without a Round 7 react: enemy
##   hits and other sources; the player's Round 7 punch is test_cam_freeflow).
## Traversal is a scripted stand-in (test_cam_fake_traversal.gd).

const FakeTraversal := preload("res://tests/game/test_cam_fake_traversal.gd")

## Stand-in for a Destructible reporting its kind (furniture vs panel).
class KindNode:
	extends Node3D
	var kind: StringName = &"panel"

var _fails := 0
var _rig: CameraRig
var _player: Fighter
var _trav: Traversal
var _world: Node3D

func _ready() -> void:
	for i in 5:
		await get_tree().process_frame
	await _run()
	AttackDirector.reset()
	TimeDirector.reset()
	print("TEST test_cam_framing: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _box(pos: Vector3, size: Vector3, nm: String, layer := Layers.WORLD) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = nm
	body.collision_layer = layer
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

func _near(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps

## Camera height above the player's aim point (m).
func _cam_height() -> float:
	return _rig.camera.global_position.y - _player.get_aim_point().y

func _run() -> void:
	_box(Vector3(0, -0.5, 0), Vector3(80, 1, 80), "Floor")
	_world = Node3D.new()
	add_child(_world)
	_player = FighterFactory.spawn_player(_world, Transform3D(Basis(), Vector3(0, 0.05, 0)))
	AttackDirector.set_player(_player)
	# Scripted traversal (sprint_charge, fall, wall run).
	var fake: Traversal = FakeTraversal.new()
	fake.name = "FakeTraversal"
	_player.add_child(fake)
	fake.setup(_player)
	var old := _player.traversal
	_player.traversal = fake
	if old != null:
		old.queue_free()
	_trav = fake
	_rig = CameraRig.new()
	_rig.target = _player
	add_child(_rig)
	await _wait_real(0.5)
	_rig.snap_behind()
	await _wait_real(0.3)
	await _crowd()
	await _sprint()
	await _fall()
	await _wall_run()
	await _low_geometry()
	await _shake()

# --- F11: distance follows the enemies alive ---------------------------------------------
func _crowd() -> void:
	var rows: Array[String] = []
	var ok_crowd := true
	var ok_duel := true
	var ok_height := true
	var ok_monotonic := true
	var ok_framed := true
	var max_step := 0.0
	var first_dist: Array[float] = []
	# Wave A: 7 enemies; wave B: 4. All in front of the camera (it looks -Z), the
	# nearest three placed so a 7 m view does not fit them all (the fit pulls back).
	var waves: Array = [
		[Vector3(-4.5, 0, -2.5), Vector3(4.0, 0, -3.0), Vector3(0.5, 0, -4.0), Vector3(-2.0, 0, -7.5),
			Vector3(3.0, 0, -8.0), Vector3(-6.0, 0, -9.0), Vector3(6.5, 0, -10.0)],
		[Vector3(-2.0, 0, -3.0), Vector3(2.5, 0, -3.5), Vector3(0.0, 0, -6.0), Vector3(-1.0, 0, -9.0)],
	]
	for wave: Array in waves:
		var enemies: Array[Fighter] = []
		for pos: Vector3 in wave:
			enemies.append(FighterFactory.spawn_dummy(_world, &"grunt",
				Transform3D(Basis.looking_at(Vector3.BACK), pos + Vector3(0, 0.05, 0))))
		var prev_dist := INF
		while true:
			var alive := 0
			for e in enemies:
				if is_instance_valid(e) and not e.is_dead():
					alive += 1
			# Settle, watching the per-frame change (smooth transitions).
			var until := TimeDirector.now() + 4.0
			var last := _rig.camera.global_position
			while TimeDirector.now() < until:
				await get_tree().process_frame
				var cp := _rig.camera.global_position
				max_step = maxf(max_step, cp.distance_to(last))
				last = cp
			var d := _rig.get_distance()
			var h := _cam_height()
			rows.append("alive %d: distance %.2f m, arm %.2f m, camera %.2f m above the chest, crowd %.2f, fov %.1f" % [
				alive, d, _rig.get_arm_length(), h, _rig.get_crowd_factor(), _rig.camera.fov])
			if alive >= CameraRig.CROWD_FROM:
				ok_crowd = ok_crowd and d >= Tuning.CAM_CROWD_DIST.x - 0.05 and d <= Tuning.CAM_CROWD_DIST.y + 0.05
				ok_height = ok_height and _rig.get_height() > Tuning.CAM_CROWD_HEIGHT - 0.1
				# The nearest three (and the player) are in view.
				var near := enemies.filter(func(e: Fighter) -> bool: return is_instance_valid(e) and not e.is_dead())
				near.sort_custom(func(a: Fighter, b: Fighter) -> bool:
					return a.global_position.length() < b.global_position.length())
				for i in mini(3, near.size()):
					ok_framed = ok_framed and _rig.camera.is_position_in_frustum((near[i] as Fighter).get_aim_point())
				ok_framed = ok_framed and _rig.camera.is_position_in_frustum(_player.get_aim_point())
			else:
				ok_duel = ok_duel and d >= Tuning.CAM_DUEL_DIST.x - 0.1 and d <= Tuning.CAM_DUEL_DIST.y + 0.1
				ok_height = ok_height and _rig.get_height() < 0.0
			# 0 alive (wave over) may widen a little to show the next entrance.
			if alive > 0:
				ok_monotonic = ok_monotonic and d <= prev_dist + 0.05
				prev_dist = d
			if alive == wave.size():
				first_dist.append(d)
			if alive == 0:
				break
			# Kill the farthest still alive (the crowd thins from the outside in).
			var far: Fighter = null
			for e in enemies:
				if is_instance_valid(e) and not e.is_dead() and (far == null or e.global_position.length() > far.global_position.length()):
					far = e
			far.apply_damage(far.max_hp + 10.0, &"test")
		for e in enemies:
			if is_instance_valid(e):
				e.queue_free()
		await _wait_real(0.5)
	for r in rows:
		print("  F11 ", r)
	_check(ok_crowd, "F11: 3+ enemies alive -> distance %.0f-%.0f m" % [Tuning.CAM_CROWD_DIST.x, Tuning.CAM_CROWD_DIST.y])
	_check(ok_duel, "F11: 0-2 enemies alive -> distance %.0f-%.0f m" % [Tuning.CAM_DUEL_DIST.x, Tuning.CAM_DUEL_DIST.y])
	_check(ok_height, "F11: crowd sits %.1f m higher, one or two left sits lower (over the shoulder)" % Tuning.CAM_CROWD_HEIGHT)
	_check(ok_monotonic, "F11: distance never grows as the crowd thins (1+ alive)")
	_check(first_dist.size() == 2 and first_dist[0] > first_dist[1] + 0.5,
		"F11: a bigger crowd sits further back (7 alive %.2f m, 4 alive %.2f m)" % [first_dist[0], first_dist[1]])
	_check(ok_framed, "F11: the player and the nearest 3 enemies are in view in a crowd")
	_check(max_step < 0.2, "F11: smooth transitions (largest camera move in one frame %.3f m)" % max_step)

# --- F2: sprint ---------------------------------------------------------------------------
func _sprint() -> void:
	_rig.snap_behind()
	await _wait_real(1.0)
	var d0 := _rig.get_distance()
	var fov0 := _rig.camera.fov
	var h0 := _rig.get_height()
	_trav.sprint_charge = 0.5
	await _wait_real(1.0)
	var fov_half := _rig.camera.fov
	_trav.sprint_charge = 1.0
	await _wait_real(1.5)
	var fov1 := _rig.camera.fov
	var d1 := _rig.get_distance()
	var h1 := _rig.get_height()
	print("  F2 sprint_charge 0 / 0.5 / 1: fov %.1f / %.1f / %.1f deg; distance %.2f -> %.2f m; height %+.2f -> %+.2f m" % [
		fov0, fov_half, fov1, d0, d1, h0, h1])
	_check(_near(fov0, Tuning.CAM_FOV, 0.2), "F2: walking FOV %.0f (%.1f)" % [Tuning.CAM_FOV, fov0])
	_check(_near(fov_half, lerpf(Tuning.CAM_FOV, Tuning.CAM_FOV_SPRINT, 0.5), 0.3), "F2: half charge FOV %.1f" % fov_half)
	_check(_near(fov1, Tuning.CAM_FOV_SPRINT, 0.2), "F2: full charge at the 8 m/s cap: FOV %.0f (%.1f)" % [Tuning.CAM_FOV_SPRINT, fov1])
	_check(_near(d1 - d0, Tuning.CAM_SPRINT_PULLBACK, 0.1), "F2: +%.1f m at full charge (+%.2f)" % [Tuning.CAM_SPRINT_PULLBACK, d1 - d0])
	_check(_near(h0 - h1, Tuning.CAM_SPRINT_DROP, 0.05), "F2: %.1f m lower at full charge (%.2f)" % [Tuning.CAM_SPRINT_DROP, h0 - h1])
	_trav.set(&"fake_cap", 10.0)
	await _wait_real(0.6)
	var fov10 := _rig.camera.fov
	_trav.set(&"fake_cap", 12.0)
	await _wait_real(0.6)
	var fov12 := _rig.camera.fov
	print("  F2 full charge at caps 8 / 10 / 12 m/s: fov %.1f / %.1f / %.1f" % [fov1, fov10, fov12])
	_check(fov10 > fov1 + 1.0 and _near(fov12, Tuning.CAM_FOV_SPRINT_MAX, 0.2), "F2: the upgraded caps widen up to %.0f deg" % Tuning.CAM_FOV_SPRINT_MAX)
	_trav.set(&"fake_cap", 8.0)
	await _wait_real(0.6)
	# A sprint strike drops you to walk at once: the FOV eases back, never snaps.
	var max_drop := 0.0
	var last_fov := _rig.camera.fov
	_trav.sprint_charge = 0.0
	var until := TimeDirector.now() + 1.5
	while TimeDirector.now() < until:
		await get_tree().process_frame
		max_drop = maxf(max_drop, last_fov - _rig.camera.fov)
		last_fov = _rig.camera.fov
	_check(max_drop < 0.6 and _near(_rig.camera.fov, Tuning.CAM_FOV, 0.2),
		"F2: sprint_charge 1 -> 0 eases the FOV back (largest per-frame drop %.2f deg, now %.1f)" % [max_drop, _rig.camera.fov])

# --- F7: fall tilt -------------------------------------------------------------------------
func _fall() -> void:
	_rig.snap_behind()
	await _wait_real(0.5)
	var pitch0 := _rig.get_view_pitch()
	_trav.set(&"fake_airborne", true)
	_trav.set(&"fake_fall", Tuning.CAM_FALL_FROM - 0.2)
	await _wait_real(0.8)
	var roll_short := absf(_rig.get_roll_degrees())
	_trav.set(&"fake_fall", Tuning.CAM_FALL_FROM + CameraRig.FALL_RAMP + 0.5)
	await _wait_real(1.0)
	var roll_full := absf(_rig.get_roll_degrees())
	var pitch_fall := _rig.get_view_pitch()
	var cam_roll := absf(rad_to_deg(_rig.camera.global_basis.get_euler().z))
	_trav.set(&"fake_airborne", false)
	_trav.set(&"fake_fall", 0.0)
	await _wait_real(1.0)
	var roll_after := absf(_rig.get_roll_degrees())
	print("  F7 fall %.1f m: roll %.2f deg; fall %.1f m: roll %.2f deg (camera %.2f), pitch %.1f -> %.1f deg; landed: roll %.2f" % [
		Tuning.CAM_FALL_FROM - 0.2, roll_short, Tuning.CAM_FALL_FROM + CameraRig.FALL_RAMP + 0.5, roll_full, cam_roll,
		rad_to_deg(pitch0), rad_to_deg(pitch_fall), roll_after])
	_check(roll_short < 0.05, "F7: under %.0f m fallen: no roll" % Tuning.CAM_FALL_FROM)
	_check(_near(roll_full, Tuning.CAM_FALL_ROLL, 0.3) and _near(cam_roll, Tuning.CAM_FALL_ROLL, 0.6),
		"F7: falling far: roll %.0f deg" % Tuning.CAM_FALL_ROLL)
	_check(pitch_fall < pitch0 - deg_to_rad(8.0), "F7: falling far pitches down to show the ground")
	_check(roll_after < 0.2, "F7: landing clears the roll")

# --- F7b: wall run --------------------------------------------------------------------------
func _wall_run() -> void:
	# A runnable concrete wall 1 m to the player's left (the camera looks -Z).
	var wall := _box(Vector3(-1.0, 2.0, 0.0), Vector3(0.3, 4.0, 16.0), "RunWall")
	wall.add_to_group(&"runnable")
	_rig.snap_behind()
	await _wait_real(0.6)
	var fake := _trav
	fake.set(&"fake_wall", true)
	fake.set(&"fake_side", -1)
	fake.set(&"fake_normal", Vector3.RIGHT)
	GameEvents.wall_run_started.emit(_player, wall, -1)
	await _wait_real(0.8)
	var shift := (_rig._pivot - _player.get_aim_point()).dot(Vector3.RIGHT)
	var roll := _rig.get_roll_degrees()
	print("  F7b wall on the left: pivot %+.2f m from the player toward the open side, roll %+.2f deg" % [shift, roll])
	_check(_near(shift, Tuning.CAM_WALLRUN_SHIFT, 0.15), "F7b: shift %.1f m toward the open side (%.2f)" % [Tuning.CAM_WALLRUN_SHIFT, shift])
	_check(_near(absf(roll), Tuning.CAM_WALLRUN_ROLL, 0.3) and roll < 0.0,
		"F7b: roll %.0f deg away from the wall (top leans right, away from a left wall: %.2f)" % [Tuning.CAM_WALLRUN_ROLL, roll])
	# Look along +X (the camera behind the wall): the run wall is left out of the casts.
	_rig._yaw = -PI * 0.5
	await _wait_real(0.6)
	var arm_run := _rig.get_arm_length()
	fake.set(&"fake_wall", false)
	GameEvents.wall_run_ended.emit(_player, &"time")
	await _wait_real(CameraRig.WALLRUN_EXCLUDE_GRACE + 1.2)
	var arm_after := _rig.get_arm_length()
	print("  F7b camera behind the run wall: arm %.2f m during the run, %.2f m after it" % [arm_run, arm_after])
	_check(arm_run > Tuning.CAM_DUEL_DIST.x - 0.3, "F7b: during the run the wall does not pull the camera in (arm %.2f m)" % arm_run)
	_check(arm_after < 2.0, "F7b: after the run the same wall clamps the arm again (%.2f m)" % arm_after)
	wall.queue_free()
	_rig.snap_behind()
	await _wait_real(0.5)

# --- Low geometry ------------------------------------------------------------------------------
func _low_geometry() -> void:
	_rig.snap_behind()
	await _wait_real(0.8)
	var free_arm := _rig.get_arm_length()
	# The camera sits behind the player (+Z): a 1.8 m platform and a 0.9 m wall in the arm's path.
	var platform := _box(Vector3(0.0, 0.9, 2.2), Vector3(4.0, 1.8, 2.0), "LowPlatform")
	var low_wall := _box(Vector3(0.0, 0.45, 4.0), Vector3(4.0, 0.9, 0.3), "LowWall")
	var min_arm := INF
	var faded := false
	var until := TimeDirector.now() + 1.0
	while TimeDirector.now() < until:
		await get_tree().process_frame
		min_arm = minf(min_arm, _rig.get_arm_length())
		faded = faded or _rig.get_blockers().has("LowPlatform")
	print("  low geometry: arm %.2f m in the open, %.2f m at least with the platform and low wall in its path; platform faded: %s" % [
		free_arm, min_arm, faded])
	_check(min_arm > free_arm - 0.1, "a 1.8 m platform and a 0.9 m wall in the arm's path do not pull the camera in")
	_check(faded, "the platform fades where it blocks the view of the player")
	platform.queue_free()
	low_wall.queue_free()
	# Moving past a low wall: no yank.
	var wall := _box(Vector3(0.0, 0.45, 2.5), Vector3(0.3, 0.9, 6.0), "LowWallAlong")
	await _wait_real(0.3)
	var max_drop := 0.0
	var last := _rig.get_arm_length()
	for i in 90:
		_rig.apply_manual_input(Vector2(0.02, 0.0))  # the arm sweeps across the low wall
		await get_tree().process_frame
		max_drop = maxf(max_drop, last - _rig.get_arm_length())
		last = _rig.get_arm_length()
	_check(max_drop < 0.05, "the arm sweeping across a 0.9 m wall never jumps in (largest drop %.3f m)" % max_drop)
	wall.queue_free()
	var tall := _box(Vector3(0.0, 2.0, 2.2), Vector3(4.0, 4.0, 0.4), "TallWall")
	_rig.snap_behind()
	await _wait_real(0.6)
	_check(_rig.get_arm_length() < 2.0, "a 4 m wall in the same place still holds the camera off (arm %.2f m)" % _rig.get_arm_length())
	tall.queue_free()
	_rig.snap_behind()
	await _wait_real(0.6)

# --- Shake by trauma -------------------------------------------------------------------------
func _shake() -> void:
	for pair: Array in [[GameEvents.hit_landed, _rig._on_hit_landed], [GameEvents.wall_broken, _rig._on_wall_broken],
			[GameEvents.landing, _rig._on_landing], [GameEvents.limb_severed, _rig._on_limb_severed],
			[GameEvents.drive_impact, _rig._on_drive_impact], [GameEvents.rammed, _rig._on_rammed],
			[GameEvents.wall_run_started, _rig._on_wall_run_started], [GameEvents.screen_shake, _rig._on_screen_shake]]:
		_check((pair[0] as Signal).is_connected(pair[1]), "camera listens to GameEvents.%s" % (pair[0] as Signal).get_name())
	var dummy := FighterFactory.spawn_dummy(_world, &"grunt", Transform3D(Basis(), Vector3(0, 0.05, -1.5)))
	await _wait_real(0.2)
	var cases: Array = []
	for tier: int in [HitInfo.Tier.FLINCH, HitInfo.Tier.STAGGER, HitInfo.Tier.KNOCKDOWN, HitInfo.Tier.LAUNCH]:
		var info := HitInfo.new()
		info.attacker = _player
		info.victim = dummy
		info.tier = tier
		info.hit_position = dummy.get_aim_point()
		info.hit_direction = Vector3.FORWARD
		cases.append(["hit %s" % HitInfo.tier_name(tier), func() -> void: _rig._on_hit_landed(info), Power.trauma_for(tier)])
	cases.append(["wall break", func() -> void: _rig._on_wall_broken(null, _player.global_position, 6000.0, Vector3.FORWARD),
		float(Tuning.TRAUMA[&"wall_break"])])
	cases.append(["heavy landing", func() -> void: _rig._on_landing(_player, &"heavy", _player.global_position, 12.0),
		float(Tuning.TRAUMA[&"heavy_landing"])])
	cases.append(["limb lost", func() -> void: _rig._on_limb_severed(dummy, &"arm_l", null), float(Tuning.TRAUMA[&"limb_lost"])])
	cases.append(["ram", func() -> void: _rig._on_rammed(_player, dummy, &"stumble", &"none"), float(Tuning.TRAUMA[&"ram"])])
	var desk := KindNode.new()
	desk.kind = &"desk"
	add_child(desk)
	cases.append(["broken furniture", func() -> void: _rig._on_wall_broken(desk, _player.global_position, 3000.0, Vector3.FORWARD),
		CameraRig.FURNITURE_TRAUMA])
	var line := PackedStringArray()
	for c: Array in cases:
		_rig._trauma = 0.0
		_rig._last_heavy = -100.0
		(c[1] as Callable).call()
		var tr := _rig.get_trauma()
		line.append("%s %.2f (shake %.4f)" % [c[0], tr, _rig.get_shake()])
		_check(_near(tr, float(c[2]), 0.001) and _near(_rig.get_shake(), tr * tr, 0.0001),
			"trauma from %s: %.2f, shake = trauma^2" % [c[0], c[2]])
	print("  shake: ", ", ".join(line))
	_rig._fov_amp = 0.0
	_rig._on_wall_broken(desk, _player.global_position, 3000.0, Vector3.FORWARD)
	_check(_rig._fov_amp == 0.0, "broken furniture does not punch the FOV like a wall break")
	# One heavy landing reported twice shakes once.
	_rig._trauma = 0.0
	_rig._last_heavy = -100.0
	_rig._on_landing(_player, &"heavy", _player.global_position, 12.0)
	_rig._on_landing(_player, &"heavy", _player.global_position, 12.0)
	_check(absf(_rig.get_trauma() - float(Tuning.TRAUMA[&"heavy_landing"])) < 0.001,
		"a heavy landing reported twice adds the trauma once (%.2f)" % _rig.get_trauma())
	desk.queue_free()
	# Far events shake less; a soft landing none; decay 1.5 per s.
	_rig._trauma = 0.0
	_rig._on_wall_broken(null, _player.global_position + Vector3(30, 0, 0), 6000.0, Vector3.FORWARD)
	_check(_rig.get_trauma() < float(Tuning.TRAUMA[&"wall_break"]) * 0.5, "a wall break 30 m away shakes less (%.2f)" % _rig.get_trauma())
	_rig._trauma = 0.0
	_rig._on_landing(_player, &"soft", _player.global_position, 5.0)
	_check(_rig.get_trauma() == 0.0, "a soft landing adds no trauma")
	await _wait_real(0.3)
	var still := _rig.camera.global_transform
	await get_tree().process_frame
	var still2 := _rig.camera.global_transform
	_rig._trauma = 1.0
	var t0 := TimeDirector.now()
	var moved := 0.0
	var turned := 0.0
	for i in 12:
		await get_tree().process_frame
		moved = maxf(moved, _rig.camera.global_position.distance_to(still2.origin))
		turned = maxf(turned, rad_to_deg((-_rig.camera.global_basis.z).angle_to(-still.basis.z)))
	var elapsed := TimeDirector.now() - t0
	var expect := 1.0 - Tuning.TRAUMA_DECAY * elapsed
	print("  shake at trauma 1: camera moved up to %.3f m, turned %.2f deg; trauma %.3f after %.3f s (expected %.3f)" % [
		moved, turned, _rig.get_trauma(), elapsed, expect])
	_check(moved > 0.05 and turned > 0.3, "full trauma visibly shakes the camera")
	_check(_near(_rig.get_trauma(), expect, 0.03), "trauma decays %.1f per s" % Tuning.TRAUMA_DECAY)
	dummy.queue_free()
