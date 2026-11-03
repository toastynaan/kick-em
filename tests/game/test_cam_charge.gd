extends Node
## Round 8 camera (docs/Round 8 — Charge and Pressure.md), charge and pressure:
## - Charge zoom: the FOV narrows with the player's charge c, monotonic in c, up
##   to CameraRig.CHARGE_ZOOM_FOV at c = 1; a real-time charge (0 -> 1 over
##   Tuning.debug_charge_full - R8_TAP_MAX) narrows the rendered FOV on every
##   frame, never widening; charge_full adds a short pulse (the player's only);
##   the release eases back to the base FOV (no snap) and so does a cancel.
## - Pressure break: the player breaking an enemy's pressure punches the FOV and
##   shakes a little; no slow motion. An enemy's break of another (or of the
##   player) does nothing.
## The charge comes from test_cam_fake_rig.gd (CombatController.get_charge()).

const FakeRig := preload("res://tests/game/test_cam_fake_rig.gd")
const STEPS := 10

var _fails := 0
var _rig
var _p: Fighter
var _world: Node3D

func _ready() -> void:
	for i in 5:
		await get_tree().process_frame
	await _run()
	TimeDirector.reset()
	print("TEST test_cam_charge: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
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

func _run() -> void:
	_box(Vector3(0, -0.5, 0), Vector3(120, 1, 120), "Floor")
	_world = Node3D.new()
	add_child(_world)
	_p = FighterFactory.spawn_player(_world, Transform3D(Basis(), Vector3(0, 0.05, 0)))
	_p.max_hp = 100000.0
	_p.hp = _p.max_hp
	AttackDirector.set_player(_p)
	_rig = FakeRig.new()
	_rig.target = _p
	add_child(_rig)
	await _wait_real(0.5)
	_rig.snap_behind()
	await _wait_real(0.5)
	for pair: Array in [[GameEvents.charge_full, _rig._on_charge_full], [GameEvents.pressure_broken, _rig._on_pressure_broken],
			[GameEvents.air_follow_started, _rig._on_air_follow_started], [GameEvents.air_hit, _rig._on_air_hit]]:
		_check((pair[0] as Signal).is_connected(pair[1]), "camera listens to GameEvents.%s" % (pair[0] as Signal).get_name())
	await _zoom_by_c()
	await _real_charge()
	await _cancel()
	await _pressure_break()

## Settled zoom at c = 0, 0.1, ... 1.
func _zoom_by_c() -> void:
	var base: float = _rig.camera.fov
	var zooms: Array[float] = []
	var fovs: Array[float] = []
	for i in STEPS + 1:
		_rig.fake_charge = float(i) / STEPS
		await _wait_real(0.5)
		zooms.append(_rig.get_charge_zoom())
		fovs.append(_rig.camera.fov)
	var mono := true
	for i in STEPS:
		if zooms[i + 1] < zooms[i] - 0.0001 or fovs[i + 1] > fovs[i] + 0.0001:
			mono = false
	var row := PackedStringArray()
	for i in STEPS + 1:
		row.append("%.1f:%.2f" % [float(i) / STEPS, zooms[i]])
	print("  charge zoom by c (deg): %s; FOV %.2f -> %.2f" % [" ".join(row), base, fovs[STEPS]])
	_check(zooms[0] < 0.001 and absf(fovs[0] - base) < 0.01, "no zoom at c = 0")
	_check(mono and zooms[STEPS] > zooms[STEPS / 2] and zooms[STEPS / 2] > zooms[1], "the zoom is monotonic in c (and grows)")
	_check(absf(zooms[STEPS] - CameraRig.CHARGE_ZOOM_FOV) < 0.02 and absf(base - fovs[STEPS] - CameraRig.CHARGE_ZOOM_FOV) < 0.05,
		"c = 1 narrows the FOV by %.1f deg (%.2f)" % [CameraRig.CHARGE_ZOOM_FOV, base - fovs[STEPS]])
	_rig.fake_charge = 0.0
	await _wait_real(1.0)
	_check(_rig.get_charge_zoom() < 0.01 and absf(_rig.camera.fov - base) < 0.02, "and recovers to the base FOV (%.2f)" % _rig.camera.fov)

## A real-time charge: c from 0 to 1 over (debug_charge_full - R8_TAP_MAX) s,
## charge_full, the hold at full, then the release.
func _real_charge() -> void:
	var base: float = _rig.camera.fov
	var ramp: float = Tuning.debug_charge_full - Tuning.R8_TAP_MAX
	var t0 := TimeDirector.now()
	var prev := base
	var widened := 0.0
	var frames := 0
	while TimeDirector.now() - t0 < ramp:
		_rig.fake_charge = clampf((TimeDirector.now() - t0) / ramp, 0.0, 1.0)
		await get_tree().process_frame
		var fov: float = _rig.camera.fov
		widened = maxf(widened, fov - prev)
		prev = fov
		frames += 1
	_rig.fake_charge = 1.0
	var n0: int = _rig.get_charge_full_count()
	GameEvents.charge_full.emit(_p, &"front_kick")
	var low := INF
	var pulse := 0.0
	var t1 := TimeDirector.now()
	while TimeDirector.now() - t1 < Tuning.R8_CHARGE_HOLD_AT_FULL:
		await get_tree().process_frame
		low = minf(low, _rig.camera.fov)
		pulse = maxf(pulse, _rig.get_charge_pulse())
	var held: float = _rig.camera.fov
	# The release (the strike fires): ease back.
	_rig.fake_charge = 0.0
	var t2 := TimeDirector.now()
	var back := -1.0
	var max_step := 0.0
	prev = held
	while TimeDirector.now() - t2 < 1.2:
		await get_tree().process_frame
		var fov: float = _rig.camera.fov
		max_step = maxf(max_step, absf(fov - prev))
		prev = fov
		if back < 0.0 and absf(fov - base) < 0.05:
			back = TimeDirector.now() - t2
	print("  real-time charge over %.2f s (%d frames): FOV widened at most %.4f deg/frame on the way in; held %.2f (base %.2f); charge_full pulse %.2f deg (FOV low %.2f); release back to within 0.05 deg in %.2f s, at most %.3f deg/frame" % [
		ramp, frames, widened, held, base, pulse, low, back, max_step])
	_check(widened <= 0.01, "the FOV narrows on every frame of a real charge (monotonic in time; widened at most %.4f deg)" % widened)
	_check(absf(base - held - CameraRig.CHARGE_ZOOM_FOV) < 0.1, "a full charge holds %.1f deg narrower (%.2f)" % [CameraRig.CHARGE_ZOOM_FOV, base - held])
	_check(_rig.get_charge_full_count() == n0 + 1 and absf(pulse - CameraRig.CHARGE_FULL_PULSE) < 0.05 and held - low > CameraRig.CHARGE_FULL_PULSE * 0.9,
		"charge_full pulses %.1f deg further in, then back (%.2f)" % [CameraRig.CHARGE_FULL_PULSE, held - low])
	_check(back > 0.2 and back < 0.9 and max_step < 0.25, "the release eases back to the base FOV (%.2f s, %.3f deg/frame at most: no snap)" % [back, max_step])
	# An enemy's charge_full does not pulse.
	var e := FighterFactory.spawn_dummy(_world, &"grunt", Transform3D(Basis(), Vector3(3, 0.05, -3)))
	await get_tree().process_frame
	GameEvents.charge_full.emit(e, &"jab")
	await _wait_real(0.1)
	_check(_rig.get_charge_full_count() == n0 + 1 and _rig.get_charge_pulse() < 0.001, "an enemy's charge_full does not pulse")
	e.queue_free()
	await _wait_real(0.3)

## A charge cancelled half way (a hit on the player) eases back the same way.
func _cancel() -> void:
	var base: float = _rig.camera.fov
	_rig.fake_charge = 0.6
	await _wait_real(0.5)
	var z: float = _rig.get_charge_zoom()
	_rig.fake_charge = 0.0
	await get_tree().process_frame
	var right_after: float = _rig.get_charge_zoom()
	await _wait_real(1.0)
	print("  cancel at c = 0.6: zoom %.2f deg, %.2f a frame later, %.3f after 1 s" % [z, right_after, _rig.get_charge_zoom()])
	_check(right_after > z * 0.9 and _rig.get_charge_zoom() < 0.01 and absf(_rig.camera.fov - base) < 0.02,
		"a cancelled charge eases back (no snap) to the base FOV")

func _pressure_break() -> void:
	var e := FighterFactory.spawn_dummy(_world, &"grunt", Transform3D(Basis.looking_at(Vector3.BACK), Vector3(0.5, 0.05, -1.6)))
	var other := FighterFactory.spawn_dummy(_world, &"grunt", Transform3D(Basis(), Vector3(-3, 0.05, -3)))
	await _wait_real(0.6)
	_rig._trauma = 0.0
	TimeDirector.reset()
	var n0: int = _rig.get_break_count()
	GameEvents.pressure_broken.emit(e, _p)
	var punch := 0.0
	var trauma: float = _rig.get_trauma()
	var slow := 1.0
	var t0 := TimeDirector.now()
	while TimeDirector.now() - t0 < 0.5:
		await get_tree().process_frame
		punch = maxf(punch, _rig.get_fov_punch())
		slow = minf(slow, Engine.time_scale)
	var after: float = _rig.get_fov_punch()
	print("  pressure break by the player: FOV punch %.2f deg (%.2f after 0.5 s), trauma %.2f, time scale at least %.2f" % [punch, after, trauma, slow])
	_check(_rig.get_break_count() == n0 + 1 and punch > CameraRig.BREAK_PUNCH_FOV - 0.1 and after < 0.01,
		"the player's pressure break punches the FOV (%.2f deg) and eases back" % punch)
	_check(trauma >= CameraRig.BREAK_TRAUMA - 0.01 and trauma < 0.5, "with a small shake (trauma %.2f)" % trauma)
	_check(slow > 0.999, "and no slow motion")
	_rig._trauma = 0.0
	GameEvents.pressure_broken.emit(e, other)
	GameEvents.pressure_broken.emit(_p, e)
	var p2 := 0.0
	t0 = TimeDirector.now()
	while TimeDirector.now() - t0 < 0.2:
		await get_tree().process_frame
		p2 = maxf(p2, _rig.get_fov_punch())
	_check(_rig.get_break_count() == n0 + 1 and p2 < 0.001 and _rig.get_trauma() < 0.01, "an enemy's break (or the player's own) does not punch")
	e.queue_free()
	other.queue_free()
