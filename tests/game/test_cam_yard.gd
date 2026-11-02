extends Node
## Round 6 camera and time in the real Yard (YardBuilder: K's clutter, D's
## structure, the pillars' beams and signs):
## - Crowd camera (3 enemies: 7 m, 8 enemies: 9 m; 2.5 m higher) orbiting 360
##   deg at three spots round every pillar: frames where the player's chest or
##   head is hidden by something not faded (clutter, partitions, door frames,
##   beams, signs, debris fade; concrete is the arm's job), the longest run of
##   such frames, what hid it; the arm never pulled in by a beam or sign.
## - A pillar snapped (two 12,000 J hits): wall-break slow time as a pillar, no
##   slow time from its structure_collapsed; the beam's landing thumps the
##   camera near the player and less far away; the camera keeps the player
##   visible round the fallen beam.
## - Door frames and clutter breaking: no slow time, a small shake.
## Enemies for the crowd count are parked under the map (alive, idle), so they
## never stand in a sight line.

const ORBIT_TIME := 3.0       ## real s per 360 deg orbit
const SPOT_DIST := 1.7        ## m from a pillar's centre

var _fails := 0
var _rig: CameraRig
var _p: Fighter
var _yard: YardBuilder
var _parked: Array[Fighter] = []
# Probe state.
var _measure := false
var _frames := 0
var _occ_chest := 0
var _occ_head := 0
var _run := 0
var _longest := 0
var _by := {}
var _beam_frames := 0
var _beam_short := 0
var _thumps: Array = []       ## [pre-distance amount, trauma added, distance]
var _thump_count_seen := 0
var _prev_trauma := 0.0
var _world_blocked_at := -100.0

class Probe:
	extends Node
	var owner_test: Node
	func _process(_d: float) -> void:
		owner_test.call(&"_probe")

func _ready() -> void:
	for i in 3:
		await get_tree().physics_frame
	await _run_all()
	TimeDirector.reset()
	print("TEST test_cam_yard: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _wait_real(sec: float) -> void:
	var until := TimeDirector.now() + sec
	while TimeDirector.now() < until:
		await get_tree().process_frame

# --- Occlusion probe (after the rig has placed the camera) -------------------------
func _fade_of(n) -> float:
	if not is_instance_valid(n):
		return 0.0
	if n is Fighter:
		return BloodFX.get_fighter_fade(n)
	return float((n as Node).get_meta(&"view_fade", 0.0))

## Name of the first opaque thing between the camera and `pt`, "" when clear.
func _blocker(cam: Vector3, pt: Vector3) -> String:
	var space := _rig.get_world_3d().direct_space_state
	var mask := Layers.WORLD | Layers.DESTRUCTIBLE | Layers.DEBRIS | Layers.DEBRIS_SMALL | Layers.DEAD_BODY \
		| Layers.CAPSULE | Layers.RAGDOLL
	var exclude: Array[RID] = []
	var dir := (pt - cam).normalized()
	var from := cam
	for i in 12:
		var q := PhysicsRayQueryParameters3D.create(from, pt, mask, exclude)
		q.hit_from_inside = true
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return ""
		var col = hit["collider"]
		if (hit["position"] as Vector3).distance_to(pt) < 0.25 or CameraRig._owner_fighter(col) == _p:
			exclude.append(hit["rid"])
			continue
		if col is CollisionObject3D and ((col as CollisionObject3D).collision_layer & Layers.WORLD) != 0:
			var shape := int(hit["shape"])
			if _rig.is_low_shape(col, shape, _p.get_ground_position().y):
				var mesh := _rig._shape_mesh(col, shape)
				if mesh == null or _fade_of(mesh) < 0.5:
					return "low:" + (mesh.name if mesh else (col as Node).name)
				var t := CameraRig._ray_exit(_rig._shape_box(col, shape), from, dir)
				from = from + dir * (t + 0.01) if t >= 0.0 else (hit["position"] as Vector3) + dir * 0.01
				continue
			return "concrete:" + (col as Node).name
		var f := CameraRig._owner_fighter(col)
		var faded := _fade_of(f if f != null else col)
		if faded < 0.5:
			return str((col as Node).name)
		exclude.append(hit["rid"])
	return ""

func _probe() -> void:
	if _rig == null or not is_instance_valid(_rig):
		return
	# Thumps (the beam landing): the trauma the camera added that frame.
	if _rig.get_thump_count() != _thump_count_seen:
		_thump_count_seen = _rig.get_thump_count()
		var added := _rig.get_trauma() - maxf(_prev_trauma - Tuning.TRAUMA_DECAY * TimeDirector.frame_delta(), 0.0)
		var info := _rig.get_last_thump()
		_thumps.append([snappedf(float(info["energy"]), 1.0), snappedf(float(info["amount"]), 0.001), snappedf(added, 0.001),
			snappedf((info["pos"] as Vector3).distance_to(_p.global_position), 0.1), "%s %.0f kg" % [info.get("piece", ""), float(info.get("mass", 0.0))],
			snappedf(_rig.get_trauma(), 0.001)])
	_prev_trauma = _rig.get_trauma()
	if not _measure or not is_instance_valid(_p) or _rig.get_crowd_factor() < 0.99:
		return
	_frames += 1
	var cam := _rig.camera.global_position
	var chest := _blocker(cam, _p.get_aim_point())
	var head := _blocker(cam, _p.get_aim_point() + Vector3.UP * 0.45)
	if chest != "":
		_occ_chest += 1
		_by[chest] = int(_by.get(chest, 0)) + 1
		_run += 1
		_longest = maxi(_longest, _run)
	else:
		_run = 0
	if head != "":
		_occ_head += 1
	# The arm through a beam / sign / clutter: never pulled in. The whole arm
	# (pivot to the full framing length) is checked for concrete with the rig's
	# own soft sweep; just after concrete let go, the arm is still easing out.
	var space := _rig.get_world_3d().direct_space_state
	var back := (cam - _rig._pivot).normalized()
	var full := _rig.arm.spring_length
	var far := _rig._pivot + back * full
	var subject := _p.get_aim_point()
	var world_free := _rig._cast_free(space, _rig._pivot, back * full, CameraRig.ARM_SOFT_RADIUS) >= full - 0.05 \
		and _rig._cast_free(space, subject, far - subject, CameraRig.SIGHT_SOFT_RADIUS) >= subject.distance_to(far) - 0.05 \
		and _rig._world_ray(space, subject, far).is_empty()
	if not world_free:
		_world_blocked_at = TimeDirector.now()
	var q := PhysicsRayQueryParameters3D.create(_rig._pivot, _rig._pivot + back * full, Layers.DESTRUCTIBLE | Layers.DEBRIS)
	if not space.intersect_ray(q).is_empty() and world_free and TimeDirector.now() - _world_blocked_at > 0.75:
		_beam_frames += 1
		if _rig.get_arm_length() < full - 0.3:
			_beam_short += 1

# --- Setup --------------------------------------------------------------------------
func _run_all() -> void:
	_yard = YardBuilder.new()
	add_child(_yard)
	_yard.build()
	await _ticks(3)
	var pillars: Array = _yard.get_parkour_features()["pillars"]
	_check(pillars.size() == 4, "the Yard has 4 pillars with overhead pieces (%d)" % pillars.size())
	_p = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	_p.name = "Player"
	_p.max_hp = 100000.0
	_p.hp = _p.max_hp
	for i in 8:
		# Far off the courtyard and under it: counted alive, never framed or in a sight line.
		var e := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis(), Vector3(300.0 + i * 2.0, -60.0, 300.0)))
		_parked.append(e)
	await _ticks(2)
	for e in _parked:
		e.process_mode = Node.PROCESS_MODE_DISABLED
	_rig = CameraRig.new()
	_rig.target = _p
	add_child(_rig)
	var probe := Probe.new()
	probe.owner_test = self
	probe.process_priority = 1000
	add_child(probe)
	await _ticks(10)
	_check(_rig._cast_q.collision_mask == Layers.WORLD, "the arm's casts are WORLD only (clutter, beams, signs, debris never move it)")
	var td: Node = TimeDirector
	_check(not _connected(GameEvents.furniture_broken, td) and not _connected(GameEvents.structure_collapsed, td),
		"TimeDirector does not listen to furniture_broken or structure_collapsed (no slow time from them)")
	_check(not _connected(GameEvents.floor_damaged, _rig), "the camera does not listen to floor_damaged (a slam's crater is not counted twice)")

	# --- Crowd camera round every pillar ---------------------------------------------
	for pass_n: int in [3, 8]:
		_set_crowd(pass_n)
		_reset_counts()
		for pl: Pillar in pillars:
			await _orbit_round(pl)
		print("  crowd x%d (%d enemies alive, crowd %.2f, distance %.1f m, camera %.1f m above the chest): %d frames; chest hidden %d, head hidden %d; longest run %d frames; by %s" % [
			pass_n, _rig.get_enemies_alive(), _rig.get_crowd_factor(), _rig.get_distance(),
			_rig.camera.global_position.y - _p.get_aim_point().y, _frames, _occ_chest, _occ_head, _longest, str(_by)])
		print("  crowd x%d: the arm ran through a beam, sign or clutter on %d frames, pulled in on %d" % [pass_n, _beam_frames, _beam_short])
		_check(_frames > 4 * 3 * ORBIT_TIME * 100, "crowd x%d: watched every orbit (%d frames)" % [pass_n, _frames])
		_check(_longest <= 8, "crowd x%d: the chest is never hidden longer than the fade-in (longest %d frames)" % [pass_n, _longest])
		_check(_occ_chest <= _frames / 50, "crowd x%d: chest hidden on at most 2%% of frames (%d / %d)" % [pass_n, _occ_chest, _frames])
		_check(_beam_short == 0, "crowd x%d: a beam, sign or clutter in the arm's path never pulls it in" % pass_n)

	# --- Snap a pillar near the player: slow time, the beam's thump, the fallen beam ---
	_set_crowd(3)
	var near_p: Pillar = _pillar_at(pillars, Vector2(6, 6))
	var far_p: Pillar = _pillar_at(pillars, Vector2(-6, -6))
	var at := _toward_centre(near_p, 4.5)
	_place(at)
	await _wait_real(0.5)
	var thump_near := await _snap(near_p, at)
	await _wait_real(1.0)
	# Round the fallen beam.
	if is_instance_valid(near_p.fallen_head):
		var fb := near_p.fallen_head.global_position
		_reset_counts()
		for k in 3:
			var a := TAU * k / 3.0
			_place(Vector3(fb.x, 0.05, fb.z) + Vector3(cos(a), 0, sin(a)) * 1.6)
			await _wait_real(0.4)
			await _orbit(ORBIT_TIME)
		print("  round the fallen beam: %d frames; chest hidden %d (longest %d frames); by %s" % [_frames, _occ_chest, _longest, str(_by)])
		_check(_longest <= 8 and _occ_chest <= maxi(_frames / 50, 1), "the fallen beam never hides the player for long (%d frames, longest %d)" % [_occ_chest, _longest])
	# Far: the player 18+ m from the second pillar.
	var far_at := Vector3(far_p.global_position.x, 0.05, far_p.global_position.z) * -1.0 + Vector3(2.0, 0, 2.0)
	_place(far_at)
	await _wait_real(1.0)
	var thump_far := await _snap(far_p, far_at)
	var d_near := Vector2(at.x - near_p.global_position.x, at.z - near_p.global_position.z).length()
	var d_far := Vector2(far_at.x - far_p.global_position.x, far_at.z - far_p.global_position.z).length()
	print("  beam landing thump: pillar %.1f m away %s, pillar %.1f m away %s  ([energy J, thump before distance, trauma added, m from the player, piece, camera trauma after])" % [
		d_near, str(thump_near), d_far, str(thump_far)])
	_check(not thump_near.is_empty() and float(thump_near[1]) > float(Tuning.TRAUMA[&"heavy_landing"]) * 0.95
		and float(thump_near[5]) > float(Tuning.TRAUMA[&"heavy_landing"]) * 0.9,
		"a pillar's beam and sections landing near the player are a heavy thump (camera trauma %.2f)" % (float(thump_near[5]) if not thump_near.is_empty() else 0.0))
	# The far collapse is the same thump scaled by distance; a single clean drop
	# is checked below too.
	if not thump_far.is_empty():
		var k := lerpf(1.0, CameraRig.TRAUMA_FAR_MIN, clampf((float(thump_far[3]) - CameraRig.TRAUMA_FAR.x) / (CameraRig.TRAUMA_FAR.y - CameraRig.TRAUMA_FAR.x), 0.0, 1.0))
		_check(absf(float(thump_far[5]) - float(thump_far[1]) * k) < 0.03 or float(thump_far[2]) <= float(thump_far[1]) * k + 0.01,
			"the snapped beam's landing %.0f m away is scaled by distance (%.2f of %.2f, x%.2f)" % [float(thump_far[3]), float(thump_far[5]), float(thump_far[1]), k])
	else:
		_check(false, "the far beam's landing was felt")
	await _clean_drops()

	# --- Door frames and clutter: no slow time, a small shake ------------------------------
	await _break_others()

func _connected(sig: Signal, obj: Object) -> bool:
	for c: Dictionary in sig.get_connections():
		if (c["callable"] as Callable).get_object() == obj:
			return true
	return false

func _set_crowd(n: int) -> void:
	for i in _parked.size():
		var e := _parked[i]
		if i < n:
			if not e.is_in_group(&"fighters"):
				e.add_to_group(&"fighters")
		elif e.is_in_group(&"fighters"):
			e.remove_from_group(&"fighters")

func _reset_counts() -> void:
	_frames = 0
	_occ_chest = 0
	_occ_head = 0
	_run = 0
	_longest = 0
	_by.clear()
	_beam_frames = 0
	_beam_short = 0

func _place(pos: Vector3) -> void:
	_p.teleport_to(pos, -Vector3(pos.x, 0, pos.z))
	_p.velocity = Vector3.ZERO
	_p.reset_physics_interpolation()

func _pillar_at(pillars: Array, xz: Vector2) -> Pillar:
	for p: Pillar in pillars:
		if Vector2(p.global_position.x, p.global_position.z).distance_to(xz) < 0.1:
			return p
	return pillars[0]

func _toward_centre(pl: Pillar, dist: float) -> Vector3:
	var c := Vector3(pl.global_position.x, 0, pl.global_position.z)
	return c - c.normalized() * dist + Vector3(0, 0.05, 0)

## Three spots round a pillar (under the sign, outside, beside), one 360 deg orbit each.
func _orbit_round(pl: Pillar) -> void:
	var c := Vector3(pl.global_position.x, 0, pl.global_position.z)
	var inward := -c.normalized()
	for off: Vector3 in [inward, -inward, inward.cross(Vector3.UP)]:
		_place(c + off * SPOT_DIST + Vector3(0, 0.05, 0))
		_measure = false
		await _wait_real(0.5)
		await _orbit(ORBIT_TIME)

func _orbit(sec: float) -> void:
	_measure = true
	var until := TimeDirector.now() + sec
	while TimeDirector.now() < until:
		_rig.apply_manual_input(Vector2(TAU / sec * TimeDirector.frame_delta(), 0.0))
		await get_tree().process_frame
	_measure = false

## Two 12,000 J hits snap `pl`. Returns the thump [pre-distance trauma, trauma added].
func _snap(pl: Pillar, _at: Vector3) -> Array:
	TimeDirector.reset()
	await get_tree().process_frame
	var hit_pos := pl.global_position + Vector3(0, 1.0, 0) - pl.global_position.normalized() * 0.5
	var vel := pl.global_position.normalized() * 16.0
	var granted0: int = TimeDirector.get_granted()
	pl.receive_impact(12000.0, hit_pos, vel)
	var crack_scale := Engine.time_scale
	await _ticks(2)
	pl.receive_impact(12000.0, hit_pos, vel)
	var snap_scale := Engine.time_scale
	var granted := TimeDirector.get_granted() - granted0
	_check(pl.is_broken and is_equal_approx(snap_scale, 0.25) and is_equal_approx(crack_scale, 1.0),
		"%s snaps: wall-break slow time as a pillar (%.2fx; the crack before it %.2fx)" % [pl.name, snap_scale, crack_scale])
	_check(granted == 1, "its structure_collapsed (the beam's creak) adds no slow time (%d granted)" % granted)
	var n0 := _thumps.size()
	await _wait_real(Tuning.PILLAR_COLLAPSE_DELAY + 3.0)
	# The collapse's thump: the beam (160 kg) and the pillar's upper sections
	# (77 kg) landing together are one thump; the strongest moment of it.
	var best: Array = []
	for i in range(n0, _thumps.size()):
		var r: Array = _thumps[i]
		if best.is_empty() or float(r[1]) > float(best[1]) + 0.001 \
				or (absf(float(r[1]) - float(best[1])) <= 0.001 and float(r[5]) > float(best[5])):
			best = r
	print("  %s: %d thumps while it came down %s" % [pl.name, _thumps.size() - n0, str(_thumps.slice(n0))])
	return best

## A 160 kg beam dropped 4 m onto open floor, 4.5 m and 20 m from the player.
func _clean_drops() -> void:
	var rows: Array = []
	for d: float in [4.5, 20.0]:
		_place(Vector3(0, 0.05, 30.0))  # an open stretch
		var spot := Vector3(d, 4.0, 30.0)
		if absf(d - 20.0) < 0.1:
			_place(Vector3(-10.0, 0.05, 30.0))
			spot = Vector3(10.0, 4.0, 30.0)
		await _wait_real(0.6)
		_rig._trauma = 0.0
		var piece := FallingPiece.new()
		piece.mass = 160.0
		piece.collision_layer = Layers.DEBRIS
		piece.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE | Layers.DEBRIS
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(2.2, 0.26, 0.22)
		cs.shape = box
		piece.add_child(cs)
		add_child(piece)
		piece.global_position = spot
		var n0 := _thumps.size()
		await _wait_real(1.5)
		var mine: Array = []
		for i in range(n0, _thumps.size()):
			if mine.is_empty() or float(_thumps[i][0]) > float(mine[0]):
				mine = _thumps[i]
		rows.append([snappedf(_p.global_position.distance_to(Vector3(spot.x, 0, spot.z)), 0.1), mine])
		piece.queue_free()
	print("  clean 4 m drop of a 160 kg beam: %s  ([m away, [energy J, thump before distance, trauma added, m, piece, camera trauma after]])" % str(rows))
	var near: Array = rows[0][1]
	var far: Array = rows[1][1]
	_check(not near.is_empty() and float(near[1]) > float(Tuning.TRAUMA[&"heavy_landing"]) * 0.95 and float(near[5]) > float(Tuning.TRAUMA[&"heavy_landing"]) * 0.9,
		"a beam landing 4.5 m from the player thumps like a heavy landing (trauma %.2f)" % (float(near[5]) if not near.is_empty() else 0.0))
	_check(not far.is_empty() and float(far[5]) < float(near[5]) * 0.8 and float(far[5]) > 0.1,
		"the same landing 20 m away shakes less (%.2f)" % (float(far[5]) if not far.is_empty() else 0.0))

func _break_others() -> void:
	var jamb: Node3D = null
	for n in get_tree().get_nodes_in_group(&"breakables"):
		if "kind" in n and n.get(&"kind") == &"jamb" and not bool(n.get(&"is_broken")):
			jamb = n
			break
	var clutter: Node3D = null
	for n in get_tree().get_nodes_in_group(&"clutter"):
		if n.has_method(&"receive_impact") and not bool(n.get(&"is_broken")):
			clutter = n
			break
	for pair: Array in [["door jamb", jamb], ["clutter", clutter]]:
		var node: Node3D = pair[1]
		if node == null:
			_check(false, "found a %s to break" % pair[0])
			continue
		TimeDirector.reset()
		_place(node.global_position + Vector3(2.5, 0.05, 0.0) * Vector3(1, 0, 1) + Vector3(0, 0.05, 0))
		await _wait_real(0.3)
		_rig._trauma = 0.0
		_rig._last_furniture = -100.0
		# The jamb as a flying body breaks it (receive_impact); the clutter as the
		# player's punch does (receive_strike; ImpactResolver sets meta first for flights).
		var res: StringName
		if pair[0] == "clutter":
			res = node.call(&"receive_strike", _p, node.global_position + Vector3.UP * 0.6, Vector3(0, 0, -1), 5000.0)
		else:
			res = node.call(&"receive_impact", 50000.0, node.global_position + Vector3.UP * 0.8, Vector3(0, 0, 16.0))
		var scale := Engine.time_scale
		var tr := _rig.get_trauma()
		print("  %s %s -> %s: time %.2fx, trauma %.2f" % [pair[0], node.name, res, scale, tr])
		_check(is_equal_approx(scale, 1.0), "breaking a %s: no slow time" % pair[0])
		_check(tr > 0.05 and tr <= CameraRig.FURNITURE_TRAUMA + 0.001, "breaking a %s: a small shake (%.2f)" % [pair[0], tr])
		await _wait_real(1.5)
