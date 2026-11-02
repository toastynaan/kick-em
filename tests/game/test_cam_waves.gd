extends Node
## F11 cinematics through the real GameMode (Feel Reference: Camera; F11):
## - Over 20 fast scripted waves (J's GameMode emits GameEvents.last_kill), the
##   last kill of every wave plays the close-up: a cut to a side angle at
##   Tuning.CAM_LAST_KILL_DIST during TimeDirector's 0.2x for 1.0 s, then an ease
##   back to the combat camera. Only the last kill gets it.
## - The logged camera distance follows the enemies alive on the real waves.
## - The player's death plays the death camera (a slow orbit at
##   Tuning.CAM_DEATH_ORBIT during the 0.3x slow motion), then J shows results.

const WAVES := 20
const PER_WAVE := 3            ## enemies per wave kept in the queue (fast waves)
const PUSH_IN := 0.35          ## s: the death camera's blend in from the combat distance

var _fails := 0
var _gm: GameMode
var _rig: CameraRig
var _last_kills: Array = []
var _kill_t := -1.0
var _victim = null
# Close-up measurement (probe, after the rig).
var _watch := false
var _cine_seen := false
var _cine_frames := 0
var _cine_start := -1.0
var _cine_end := -1.0
var _cine_scale0 := 1.0
var _cine_arm_min := INF
var _cine_arm_max := 0.0
var _cine_side_err := 0.0
var _cine_victim_in := 0
var _closeups_other := 0

class Probe:
	extends Node
	var owner_test: Node
	func _process(_d: float) -> void:
		owner_test.call(&"_measure")

func _ready() -> void:
	GameEvents.last_kill.connect(_on_last_kill)
	await get_tree().process_frame
	await _run()
	TimeDirector.reset()
	print("TEST test_cam_waves: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _on_last_kill(f: Node3D) -> void:
	_last_kills.append(f)
	_kill_t = TimeDirector.now()
	_victim = f
	_watch = true
	_cine_seen = false
	_cine_frames = 0
	_cine_start = -1.0
	_cine_end = -1.0
	_cine_arm_min = INF
	_cine_arm_max = 0.0
	_cine_side_err = 0.0
	_cine_victim_in = 0
	_cine_scale0 = Engine.time_scale

func _measure() -> void:
	if _rig == null or not is_instance_valid(_rig):
		return
	if not _watch:
		if _rig.get_mode() == CameraRig.Mode.CLOSEUP:
			_closeups_other += 1
		return
	var t := TimeDirector.now()
	if _rig.get_mode() == CameraRig.Mode.CLOSEUP:
		if not _cine_seen:
			_cine_seen = true
			_cine_start = t
		_cine_frames += 1
		_cine_end = t
		var cam := _rig.camera
		var arm := cam.global_position.distance_to(_rig._pivot)
		_cine_arm_min = minf(_cine_arm_min, arm)
		_cine_arm_max = maxf(_cine_arm_max, arm)
		if is_instance_valid(_victim) and is_instance_valid(_gm.player):
			var line: Vector3 = (_victim as Fighter).get_center_of_mass() - _gm.player.get_aim_point()
			line.y = 0.0
			var fwd := -cam.global_basis.z
			fwd.y = 0.0
			if line.length() > 0.3 and fwd.length() > 0.1:
				_cine_side_err = maxf(_cine_side_err, absf(rad_to_deg(fwd.angle_to(line)) - 90.0))
			if cam.is_position_in_frustum((_victim as Fighter).get_center_of_mass()):
				_cine_victim_in += 1
	elif _cine_seen and t - _cine_start > 0.2:
		_watch = false

func _step(frames: int) -> void:
	for i in frames:
		await get_tree().physics_frame

func _wait_until(cond: Callable, max_real: float) -> void:
	var until := TimeDirector.now() + max_real
	while not cond.call() and TimeDirector.now() < until:
		await get_tree().process_frame

func _shield(on: bool) -> void:
	if is_instance_valid(_gm.player):
		_gm.player.max_hp = 100000.0 if on else Tuning.ARCHETYPES[&"player"]["hp"]
		_gm.player.hp = _gm.player.max_hp

## Bring an enemy in front of the player (as if the player fought it there).
func _bring(f: Fighter) -> void:
	var p := _gm.player
	var at := p.global_position + p.get_forward() * 1.5
	f.teleport_to(at, p.global_position - at)

func _freeze_brains() -> void:
	for f in _gm.get_alive_enemies():
		if f.brain and f.brain.process_mode != Node.PROCESS_MODE_DISABLED:
			f.brain.process_mode = Node.PROCESS_MODE_DISABLED

func _run() -> void:
	_gm = GameMode.new()
	_gm.show_title = false
	_gm.breather_time = 0.4
	add_child(_gm)
	_gm.start_round(&"waves")
	await get_tree().process_frame
	_rig = _gm.camera_rig
	var probe := Probe.new()
	probe.owner_test = self
	probe.process_priority = 1000
	add_child(probe)
	_shield(true)
	_check(_rig != null and GameEvents.last_kill.is_connected(_rig._on_last_kill), "camera listens to GameEvents.last_kill")
	_check(GameEvents.last_kill.is_connected(TimeDirector._on_last_kill), "TimeDirector listens to GameEvents.last_kill")

	var dist_rows: Array[String] = []
	var dist_ok := true
	var results: Array[String] = []
	var all_ok := true
	for w in WAVES:
		await _wait_until(func() -> bool: return _gm.wave_index == w and _gm.phase == GameMode.Phase.FIGHTING, 8.0)
		if w > 0 and _gm._wave_queue.size() > PER_WAVE - 1:
			_gm._wave_queue.resize(PER_WAVE - 1)
		var kills_before := _last_kills.size()
		var frames := 0
		while _last_kills.size() == kills_before and frames < 120 * 40:
			_freeze_brains()
			var alive := _gm.get_alive_enemies()
			# Wave 1 waits for its whole crowd and logs the distance at every count;
			# later waves are killed as they appear (fast waves).
			var whole := _gm.get_enemies_left() == alive.size()
			if not alive.is_empty() and (w > 0 or whole):
				if w == 0:
					for f in alive:
						_bring_ring(f)
					await _settle_and_log(dist_rows, alive.size())
					var d := _rig.get_distance()
					if alive.size() >= CameraRig.CROWD_FROM:
						dist_ok = dist_ok and d >= Tuning.CAM_CROWD_DIST.x - 0.05 and d <= Tuning.CAM_CROWD_DIST.y + 0.05
					else:
						dist_ok = dist_ok and d >= Tuning.CAM_DUEL_DIST.x - 0.1 and d <= Tuning.CAM_DUEL_DIST.y + 0.1
				var f: Fighter = alive[0]
				_bring(f)
				await _step(2)
				if is_instance_valid(f) and not f.is_dead():
					f.apply_damage(f.max_hp + 10.0, &"test")
			await _step(1)
			frames += 1
		if _last_kills.size() == kills_before:
			all_ok = false
			results.append("wave %d: no last_kill" % (w + 1))
			break
		# Watch the close-up play out.
		await _wait_until(func() -> bool: return not _watch, 4.0)
		var dur := _cine_end - _cine_start
		var delay := _cine_start - _kill_t
		var ok := _cine_seen and delay < 0.05 and dur >= float(Tuning.SLOW_TIME[&"last_kill"]["time"]) - 0.06 \
			and dur <= float(Tuning.SLOW_TIME[&"last_kill"]["time"]) + 0.1 \
			and is_equal_approx(snappedf(_cine_scale0, 0.01), float(Tuning.SLOW_TIME[&"last_kill"]["scale"])) \
			and _cine_arm_min >= Tuning.CAM_LAST_KILL_DIST * 0.75 and _cine_arm_max <= CameraRig.LAST_KILL_FIT_MAX + 0.2 \
			and _cine_side_err < 25.0 and _cine_victim_in == _cine_frames
		all_ok = all_ok and ok
		results.append("wave %2d: close-up %s after %.3f s, %.2f s long, time %.2fx, arm %.2f-%.2f m, side-on within %.0f deg, victim in view %d/%d" % [
			w + 1, "played" if _cine_seen else "MISSING", delay, dur, _cine_scale0, _cine_arm_min, _cine_arm_max,
			_cine_side_err, _cine_victim_in, _cine_frames])
		await _wait_until(func() -> bool: return _rig.get_mode() == CameraRig.Mode.COMBAT, 2.0)
	for r in dist_rows:
		print("  F11 ", r)
	for r in results:
		print("  F11 ", r)
	_check(dist_ok, "F11: on the real wave 1 the distance follows the enemies alive (crowd at 3, close at 2 and 1)")
	_check(_last_kills.size() >= WAVES, "F11: %d waves played (%d last kills)" % [WAVES, _last_kills.size()])
	_check(all_ok, "F11: over %d waves the last kill always plays the close-up (cut on the kill, 0.2x, ~1.0 s, side-on at ~%.1f m, victim in view)" % [WAVES, Tuning.CAM_LAST_KILL_DIST])
	_check(_closeups_other == 0, "only the last kill gets the close-up (%d close-up frames at other times)" % _closeups_other)

	# --- Player death: the death camera, then results -------------------------------------
	await _wait_until(func() -> bool: return _gm.phase == GameMode.Phase.FIGHTING, 6.0)
	await _step(30)
	_shield(false)
	var p := _gm.player
	var orbit_frames := 0
	var body_in := 0
	var arm_min := INF
	var arm_max := 0.0
	var yaw0 := 0.0
	var scale0 := 1.0
	var push_from := 0.0
	p.apply_damage(p.max_hp + 10.0, &"test")
	var t0 := TimeDirector.now()
	await get_tree().process_frame
	await get_tree().process_frame
	scale0 = Engine.time_scale
	yaw0 = _rig._yaw
	var slow_len := float(Tuning.SLOW_TIME[&"player_death"]["time"])
	while TimeDirector.now() - t0 < slow_len:
		await get_tree().process_frame
		if _rig.get_cinematic() == &"death":
			orbit_frames += 1
			var d := _rig.camera.global_position.distance_to(_rig._pivot)
			if TimeDirector.now() - t0 > PUSH_IN:
				arm_min = minf(arm_min, d)
				arm_max = maxf(arm_max, d)
			else:
				push_from = maxf(push_from, d)
			if _rig.camera.is_position_in_frustum(p.get_center_of_mass()):
				body_in += 1
	var turned := rad_to_deg(absf(wrapf(_rig._yaw - yaw0, -PI, PI)))
	await _wait_until(func() -> bool: return _gm.menus.screen == GameMenus.Screen.ROUND_OVER, 4.0)
	var shown_after := TimeDirector.now() - t0
	print("  F11 death: time %.2fx, death orbit on %d frames over %.1f s, pushed in from %.2f m, then arm %.2f-%.2f m, turned %.0f deg, body in view %d/%d, results at %.2f s" % [
		scale0, orbit_frames, slow_len, push_from, arm_min, arm_max, turned, body_in, orbit_frames, shown_after])
	_check(_near(scale0, float(Tuning.SLOW_TIME[&"player_death"]["scale"]), 0.01), "F11: player death slows time to %.1fx" % float(Tuning.SLOW_TIME[&"player_death"]["scale"]))
	_check(orbit_frames >= int(slow_len * 120.0) - 6, "F11: the death camera plays through the slow motion (%d frames)" % orbit_frames)
	_check(arm_max <= Tuning.CAM_DEATH_ORBIT + 0.25 and arm_min >= Tuning.CAM_DEATH_ORBIT - 0.6,
		"F11: orbit at about %.0f m once pushed in (%.2f-%.2f m after %.2f s)" % [Tuning.CAM_DEATH_ORBIT, arm_min, arm_max, PUSH_IN])
	_check(turned > 10.0, "F11: the camera orbits the body (%.0f deg in %.1f s)" % [turned, slow_len])
	_check(body_in == orbit_frames, "F11: the player's body stays in view during the orbit")
	_check(_gm.menus.screen == GameMenus.Screen.ROUND_OVER and shown_after >= slow_len,
		"F11: then the results screen (%.2f s after death)" % shown_after)

func _near(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps

## Spread the wave's enemies in front of the player (a fight in progress).
func _bring_ring(f: Fighter) -> void:
	var p := _gm.player
	var i := _gm.get_alive_enemies().find(f)
	var ang := (float(i) - 1.0) * 0.6
	var at := p.global_position + p.get_forward().rotated(Vector3.UP, ang) * (2.5 + float(i))
	f.teleport_to(at, p.global_position - at)

func _settle_and_log(rows: Array[String], alive: int) -> void:
	var until := TimeDirector.now() + 4.0
	while TimeDirector.now() < until:
		_freeze_brains()
		await get_tree().physics_frame
	rows.append("wave 1, %d alive: distance %.2f m, arm %.2f m, height %+.2f m, crowd %.2f" % [
		alive, _rig.get_distance(), _rig.get_arm_length(), _rig.get_height(), _rig.get_crowd_factor()])
