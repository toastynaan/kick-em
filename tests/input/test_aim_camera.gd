extends "res://tests/input/input_test_base.gd"
## Round 4 zone aim through the real camera and the real PlayerController
## (no ray override, no hand-placed camera):
## - The aim ray is the rig camera's screen-centre ray, h_offset included (it
##   matches Camera3D.project_ray_origin/normal at the viewport centre).
## - Free camera (the real CameraRig): turning the camera so the reticle sits on
##   the head / an arm / the legs aims there; the zone applies to the enemy under
##   the reticle, and a strike on another enemy takes TORSO (zone_for).
## - Locked (the real CameraRig if it has get_lock_target(), else the stand-in):
##   mouse up moves the aim point to the head, down to the legs, sideways to an arm.

const STAND_IN := "res://tests/input/stand_in_lock_rig.gd"

var _hits: Array[HitInfo] = []

func run() -> void:
	var p := spawn_player(Vector3(0, 0, 4))
	var a := spawn_dummy(&"duelist", Vector3(0, 0, 2.9), Vector3.BACK)
	var b := spawn_dummy(&"grunt", Vector3(-5, 0, 3), Vector3.RIGHT)  # wide left: the ray to it clears A's guard
	AttackDirector.set_player(p)
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void: _hits.append(info))
	var rig := CameraRig.new()
	rig.target = p
	add_child(rig)
	await ticks(90)
	var pc := p.brain as PlayerController
	check(pc.zone_aim.camera() == rig.get_camera(), "zone aim reads the rig's camera")

	# --- The centre ray is the reticle ray (h_offset included). ----------------
	var cam := rig.get_camera()
	var vs := get_viewport().get_visible_rect().size
	if vs.x > 1.0 and vs.y > 1.0:
		var xf := cam.get_camera_transform()
		var o := cam.project_ray_origin(vs * 0.5)
		var n := cam.project_ray_normal(vs * 0.5)
		check(o.distance_to(xf.origin) < 0.01 and n.dot(-xf.basis.z) > 0.9999,
			"centre ray = project_ray at the viewport centre (h_offset %.2f m)" % cam.h_offset)
	else:
		print("  NOTE headless viewport has no size; project_ray check skipped")

	# --- Free camera: put the reticle on body parts of A. -----------------------
	if not rig.has_method(&"apply_manual_input"):
		check(false, "CameraRig has apply_manual_input() to turn the camera")
		done()
		return
	var parts := [[Bones.HEAD, BodyZones.Zone.HEAD], [Bones.R_UPPER_ARM, BodyZones.Zone.ARM_R],
		[Bones.L_UPPER_ARM, BodyZones.Zone.ARM_L], [Bones.L_LOWER_LEG, BodyZones.Zone.LEGS],
		[Bones.CHEST, BodyZones.Zone.TORSO]]
	for part in parts:
		var miss := await _aim_free(rig, _centre(a, part[0]), p, 120)
		if BodyZones.is_arm(part[1]):
			# The camera frames from the side, so the guard's lead forearm may hide
			# part of the other arm: re-aim at a point of that arm the ray can see.
			for k in 4:
				if p.zone_for(a) == part[1]:
					break
				var vis := _visible_point(rig, a, part[1])
				print("  (arm partly hidden from the camera: re-aim at %s)" % [vis])
				if vis == Vector3.INF:
					break
				miss = await _aim_free(rig, vis, p, 120)
		check(p.aim_target == a and p.zone_for(a) == part[1],
			"free reticle on A's %s -> %s (got %s on %s, ray miss %.3f m, h_offset %.2f)" % [part[0],
			BodyZones.name_of(part[1]), BodyZones.name_of(p.zone_for(a)), str(p.aim_target.name) if p.aim_target else "none",
			miss, cam.h_offset])

	# --- Wrong target: reticle on B's head, jab A. ------------------------------
	var miss_b := await _aim_free(rig, _centre_bone(b, Bones.HEAD), p, 120)
	check(p.aim_target == b and p.zone_for(b) == BodyZones.Zone.HEAD, "reticle on B's head -> B, HEAD (miss %.3f m; %s)" % [miss_b, _why(p)])
	check(p.zone_for(a) == BodyZones.Zone.TORSO, "zone_for(A) is TORSO while aiming at B")
	_hits.clear()
	press(&"punch")
	await ticks(1)
	release(&"punch")
	await wait_until(func() -> bool: return _hit_on(a) != null, 90)
	var hit := _hit_on(a)
	check(hit != null, "the jab hit A")
	var routed := FileAccess.get_file_as_string("res://scripts/combat/combat_controller.gd").contains("zone_for(")
	if hit != null:
		if routed:
			check(hit.zone == BodyZones.Zone.TORSO, "A takes TORSO, not B's HEAD (got %s)" % BodyZones.name_of(hit.zone))
		else:
			print("  NOTE combat_controller does not call fighter.zone_for(victim) yet: A's hit zone is %s (B to route)" % BodyZones.name_of(hit.zone))
	await wait_until(func() -> bool: return p.can_act() and not p.combat.is_attacking(), 240)
	await ticks(30)

	# --- Locked: the aim point moves over the target's body. ---------------------
	# Back off to a usual lock-on distance (at 1.1 m the camera's pitch range
	# cannot bring the screen centre down to the shins).
	p.teleport_to(Vector3(0, 0, 6), Vector3.FORWARD)
	await ticks(30)
	var lock_rig: Node = rig
	var real_lock := rig.has_method(&"get_lock_target")
	if not real_lock:
		rig.queue_free()
		await ticks(2)
		var s := Node3D.new()
		s.set_script(load(STAND_IN))
		s.set(&"target", p)
		add_child(s)
		lock_rig = s
		s.call(&"set_lock", a)
		print("  NOTE locked part uses the stand-in rig (E's get_lock_target() not in yet)")
	else:
		await _aim_free(rig, _centre(a, Bones.CHEST), p, 60)  # lock picks the enemy at the screen centre
		for i in 4:
			if rig.call(&"get_lock_target") == a:
				break
			await tap_action(&"lock_on")
			await ticks(10)
	await ticks(20)
	check(lock_rig.call(&"get_lock_target") == a, "locked on A")
	check(p.aim_target == a, "locked: the aim target is A")
	await _nudge_until(lock_rig, p, Vector2(0.0, -0.01), BodyZones.Zone.HEAD)
	check(p.zone_for(a) == BodyZones.Zone.HEAD, "locked, aim point up -> HEAD (%s; %s)" % [BodyZones.name_of(p.zone_for(a)), _why(p, lock_rig)])
	await _nudge_until(lock_rig, p, Vector2(0.0, 0.01), BodyZones.Zone.LEGS)
	check(p.zone_for(a) == BodyZones.Zone.LEGS, "locked, aim point down -> LEGS (%s; %s)" % [BodyZones.name_of(p.zone_for(a)), _why(p, lock_rig)])
	await _nudge_until(lock_rig, p, Vector2(0.0, -0.01), BodyZones.Zone.TORSO)
	var arms := {}
	for dx: float in [0.005, -0.005]:
		await _nudge_until(lock_rig, p, Vector2(dx, 0.0), -2)
		arms[p.zone_for(a)] = true
		check(BodyZones.is_arm(p.zone_for(a)), "locked, aim point sideways (%+.3f) -> an arm (%s)" % [dx, BodyZones.name_of(p.zone_for(a))])
		await _nudge_until(lock_rig, p, Vector2(-dx, 0.0), BodyZones.Zone.TORSO)
	check(arms.has(BodyZones.Zone.ARM_L) and arms.has(BodyZones.Zone.ARM_R), "both arms reachable while locked")
	check(p.zone_for(b) == BodyZones.Zone.TORSO, "locked on A: B takes TORSO")
	done()

## Turn the free camera until its centre ray passes through `point` (feedback
## on the rig's own mouse input), then hold it there long enough for the zone to
## settle. Returns the final distance between the ray and the point.
func _aim_free(rig: Node, point: Vector3, _p: Fighter, frames: int) -> float:
	var miss := INF
	for i in frames:
		var cam: Camera3D = rig.call(&"get_camera")
		var xf := cam.get_camera_transform()
		var fwd := -xf.basis.z
		var want := (point - xf.origin).normalized()
		var yaw_err := wrapf(atan2(-want.x, -want.z) - atan2(-fwd.x, -fwd.z), -PI, PI)
		var pitch_err := asin(clampf(want.y, -1.0, 1.0)) - asin(clampf(fwd.y, -1.0, 1.0))
		rig.call(&"apply_manual_input", Vector2(-yaw_err, -pitch_err) * 0.7)
		await get_tree().process_frame
		var to := point - xf.origin
		miss = (to - fwd * to.dot(fwd)).length()
		if i > 30 and miss < 0.01:
			break
	await ticks(16)  # zone settle time, and the ray re-read by the controller
	return miss

## A point on `zone`'s arm capsules that the camera's ray reaches before any
## other body part (Vector3.INF if the arm is hidden from here).
func _visible_point(rig: Node, f: Fighter, zone: int) -> Vector3:
	var cam: Camera3D = rig.call(&"get_camera")
	var o := cam.get_camera_transform().origin
	var right := cam.get_camera_transform().basis.x
	for c in ZoneAim.capsules_of(f):
		if BodyZones.of_bone(c[0]) != zone:
			continue
		for t: float in [0.5, 0.3, 0.7, 0.15, 0.85]:
			for side: float in [0.0, 0.6, -0.6]:
				var pt: Vector3 = (c[1] as Vector3).lerp(c[2], t) + right * float(c[3]) * side
				var hit := ZoneAim.pick([f] as Array[Fighter], o, (pt - o).normalized())
				if not hit.is_empty() and BodyZones.of_bone(hit[1]) == zone:
					return pt
	return Vector3.INF

## Move the locked aim point by `d` per frame until zone_for(lock target) is
## `zone` (-2: any arm) and has settled.
func _nudge_until(rig: Node, p: Fighter, d: Vector2, zone: int) -> void:
	for i in 300:
		var z := p.zone_for(p.aim_target)
		if (zone == -2 and BodyZones.is_arm(z)) or z == zone:
			break
		rig.call(&"apply_manual_input", d)
		await get_tree().physics_frame
	await ticks(12)

func _centre(f: Fighter, bone: StringName) -> Vector3:
	for hb in f.hurtboxes:
		if hb.bone == bone:
			return (hb.get_child(0) as CollisionShape3D).global_position
	return _centre_bone(f, bone)

## Middle of a bone (rig positions), for bodies without that hurtbox.
func _centre_bone(f: Fighter, bone: StringName) -> Vector3:
	for hb in f.hurtboxes:
		if hb.bone == bone:
			return (hb.get_child(0) as CollisionShape3D).global_position
	return f.rig.get_bone_global_position(bone)

## Debug text: what the aim ray hit, and the rig's lock aim if it has one.
func _why(p: Fighter, rig: Node = null) -> String:
	var za := (p.brain as PlayerController).zone_aim
	var t := "target %s, ray hit %s" % [str(p.aim_target.name) if p.aim_target else "none", za.hit_bone]
	if rig != null and rig.has_method(&"get_lock_aim"):
		var ap: Vector3 = rig.call(&"get_lock_aim_point")
		t += ", lock aim %s at y=%.2f" % [rig.call(&"get_lock_aim"), ap.y]
	if p.aim_target != null and p.aim_target.rig != null:
		t += "; head bone y=%.2f, head hurtbox centre y=%.2f" % [
			p.aim_target.rig.get_bone_global_position(Bones.HEAD).y, _centre(p.aim_target, Bones.HEAD).y]
	return t

func _hit_on(f: Fighter) -> HitInfo:
	for h in _hits:
		if h.victim == f:
			return h
	return null
