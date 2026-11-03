extends "res://tests/move/move_test_base.gd"
## Round 7 drive run (docs/Round 7 — Freeflow Combat.md: Grab > Drive; agent M
## owns the run, agent G the body, impacts and slams). Acceptance 8, the ramp
## part, with measured numbers:
## - from a standstill the speed reaches R7_DRIVE_MAX_SPEED (9.5 m/s +- 0.3) at
##   1 s (R7_DRIVE_RAMP_TIME), ease-out from R7_DRIVE_START_SPEED, the capsule
##   really moving that fast; the fighter faces the drive;
## - after set_drive_speed() the ramp goes on from the new speed (above and
##   below the start speed);
## - steering toward the stick never turns faster than R7_DRIVE_TURN_RATE
##   (120 deg/s); with the stick neutral it steers toward camera forward;
## - Carry's walking share slows walking with a body but never the drive; the
##   drive ends by itself when the body is let go or the player is hit;
## - the capsule follows the body through a freshly broken wall (a hole along
##   its line, or a whole broken panel) without stopping; an intact wall stops
##   it; debris never blocks capsules (layer rules);
## - with G's real Carry (a grab that connects), the drive started through the
##   real input path (Dash while holding) ramps the same.

var p: Fighter

func _init() -> void:
	_timeout = 300.0

func run() -> void:
	p = spawn_player(Vector3(0.0, 0.02, 60.0))
	await ticks(30)
	await _ramp_from_standstill()
	await _ramp_after_set_speed()
	await _turn_cap()
	await _camera_steer()
	await _carry_mult_never_slows()
	await _ends_by_itself()
	await _through_broken_wall(false)
	await _through_broken_wall(true)
	await _through_broken_panel_whole()
	await _intact_wall_stops()
	_debris_layers()
	await _real_hold_real_input()
	done()

func _reset(pos: Vector3, facing := Vector3.FORWARD) -> void:
	await settle(p, 10)
	await place(p, pos, facing)
	await ticks(4)

## Drive from a standstill for `secs`, sampling every tick. Returns
## {at: {t: [drive speed, capsule speed]}, mono: bool, first: float, face_err: deg}.
func _drive_samples(secs: float, marks: Array) -> Dictionary:
	var ok := p.traversal.begin_drive()
	var out := {"ok": ok, "at": {}, "mono": true, "first": -1.0, "face_err": 0.0}
	var prev := 0.0
	var n := int(round(secs * 120.0))
	for i in n:
		await get_tree().physics_frame
		var t := (i + 1) / 120.0
		var v := p.traversal.get_drive_speed()
		if i == 0:
			out["first"] = v
		if v < prev - 1e-4:
			out["mono"] = false
		prev = v
		var face := p.get_forward()
		var dd := p.traversal.get_drive_dir()
		if dd != Vector3.ZERO:
			out["face_err"] = maxf(float(out["face_err"]), rad_to_deg(face.angle_to(dd)))
		for m: float in marks:
			if absf(t - m) < 0.5 / 120.0:
				(out["at"] as Dictionary)[m] = [v, hspeed(p)]
	return out

# --- The ramp from a standstill -------------------------------------------------------------
func _ramp_from_standstill() -> void:
	await _reset(Vector3(0.0, 0.02, 60.0))
	var marks := [0.25, 0.5, 0.75, 1.0, 1.5]
	var r := await _drive_samples(1.5, marks)
	var at: Dictionary = r["at"]
	var rows := []
	for m: float in marks:
		var a: Array = at.get(m, [-1.0, -1.0])
		rows.append("%.2f s %.2f (capsule %.2f)" % [m, a[0], a[1]])
	print("  drive from a standstill: first tick %.2f m/s; %s; ramp never drops %s; facing off the drive at most %.2f deg" % [
		r["first"], ", ".join(rows), r["mono"], r["face_err"]])
	var at1: Array = at.get(1.0, [0.0, 0.0])
	check(r["ok"] and p.traversal.is_driving(), "begin_drive() starts the drive")
	check(near(float(r["first"]), Tuning.R7_DRIVE_START_SPEED, 0.15), "it opens at R7_DRIVE_START_SPEED (%.2f m/s)" % r["first"])
	check(near(float(at1[0]), Tuning.R7_DRIVE_MAX_SPEED, 0.3) and near(float(at1[1]), Tuning.R7_DRIVE_MAX_SPEED, 0.3),
		"%.2f m/s at 1 s (capsule %.2f; 9.5 +- 0.3)" % [at1[0], at1[1]])
	var at05: Array = at.get(0.5, [0.0, 0.0])
	var mid := Tuning.R7_DRIVE_START_SPEED + 0.5 * (Tuning.R7_DRIVE_MAX_SPEED - Tuning.R7_DRIVE_START_SPEED)
	check(r["mono"] and float(at05[0]) > mid, "an ease-out ramp: never dropping, past halfway by 0.5 s (%.2f > %.2f)" % [at05[0], mid])
	var at15: Array = at.get(1.5, [0.0, 0.0])
	check(near(float(at15[0]), Tuning.R7_DRIVE_MAX_SPEED, 0.01), "it holds R7_DRIVE_MAX_SPEED (%.2f at 1.5 s)" % at15[0])
	check(float(r["face_err"]) < 1.0, "the fighter faces the drive (within %.2f deg)" % r["face_err"])
	await settle(p, 10)

# --- set_drive_speed: the ramp goes on from the new speed ----------------------------------------
func _ramp_after_set_speed() -> void:
	await _reset(Vector3(10.0, 0.02, 60.0))
	p.traversal.begin_drive()
	await ticks(150)
	var full := p.traversal.get_drive_speed()
	p.traversal.set_drive_speed(5.0)
	var got := p.traversal.get_drive_speed()
	await ticks(12)
	var after_01 := p.traversal.get_drive_speed()
	var want_01 := Traversal._drive_speed_at(Traversal._drive_time_of(5.0) + 0.1)
	var t_back := -1.0
	var t0 := TimeDirector.now()
	for i in 150:
		await get_tree().physics_frame
		if t_back < 0.0 and p.traversal.get_drive_speed() >= Tuning.R7_DRIVE_MAX_SPEED - 0.3:
			t_back = TimeDirector.now() - t0
	var want_back := Traversal._drive_time_of(Tuning.R7_DRIVE_MAX_SPEED - 0.3) - Traversal._drive_time_of(5.0) - 0.1
	print("  set_drive_speed(5) at %.2f m/s: reads %.2f, %.2f after 0.1 s (the curve from 5: %.2f), 9.2 m/s %.3f s later (the curve: %.3f)" % [
		full, got, after_01, want_01, t_back, want_back])
	check(near(got, 5.0, 1e-4) and near(after_01, want_01, 0.05), "after set_drive_speed() the ramp goes on from the new speed")
	check(near(t_back, want_back, 2.0 / 120.0), "and climbs back along the ramp (%.3f s to 9.2 m/s)" % t_back)
	# Below the start speed: back up at the ramp's opening slope, then the curve.
	p.traversal.set_drive_speed(1.0)
	await ticks(1)
	var low1 := p.traversal.get_drive_speed()
	await ticks(60)
	var low2 := p.traversal.get_drive_speed()
	print("  set_drive_speed(1): %.2f the next tick, %.2f 0.5 s later" % [low1, low2])
	check(low1 > 1.0 and low1 < 1.2 and low2 > Tuning.R7_DRIVE_START_SPEED + 1.0, "from below the start speed it builds back up (%.2f -> %.2f)" % [low1, low2])
	p.traversal.set_drive_speed(30.0)
	check(p.traversal.get_drive_speed() <= Tuning.R7_DRIVE_MAX_SPEED, "set_drive_speed() never goes over R7_DRIVE_MAX_SPEED")
	await settle(p, 10)

# --- Turn rate cap (stick) ------------------------------------------------------------------------
func _turn_cap() -> void:
	await _reset(Vector3(20.0, 0.02, 60.0))
	p.traversal.begin_drive()
	await ticks(120)
	var y0 := yaw_of(p.traversal.get_drive_dir())
	p.move_input = Vector3.RIGHT  # a hard 90-degree pull
	var rate_max := 0.0
	var prev := y0
	var t90 := -1.0
	var t0 := TimeDirector.now()
	var face_err := 0.0
	for i in 120:
		await get_tree().physics_frame
		var y := yaw_of(p.traversal.get_drive_dir())
		rate_max = maxf(rate_max, absf(rad_to_deg(angle_difference(prev, y))) * 120.0)
		prev = y
		face_err = maxf(face_err, rad_to_deg(p.get_forward().angle_to(p.traversal.get_drive_dir())))
		if t90 < 0.0 and absf(rad_to_deg(angle_difference(y0, y))) >= 89.9:
			t90 = TimeDirector.now() - t0
	var dir := p.traversal.get_drive_dir()
	var v := Vector3(p.velocity.x, 0.0, p.velocity.z)
	print("  stick 90 deg right at full drive: fastest turn %.1f deg/s, 90 deg in %.3f s, now heading %s (velocity %s), facing off at most %.2f deg" % [
		rate_max, t90, dir, v.normalized(), face_err])
	check(rate_max <= Tuning.R7_DRIVE_TURN_RATE + 0.5, "the drive turns at most %.1f deg/s (cap %.0f)" % [rate_max, Tuning.R7_DRIVE_TURN_RATE])
	check(near(t90, 90.0 / Tuning.R7_DRIVE_TURN_RATE, 2.0 / 120.0), "a 90-degree pull takes %.3f s (at the cap: %.3f)" % [t90, 90.0 / Tuning.R7_DRIVE_TURN_RATE])
	check(dir.dot(Vector3.RIGHT) > 0.999 and v.normalized().dot(Vector3.RIGHT) > 0.99, "it ends along the stick, the capsule with it")
	check(face_err < 1.0, "the fighter faces the drive while it turns (within %.2f deg)" % face_err)
	p.move_input = Vector3.ZERO
	await settle(p, 10)

# --- Camera forward with the stick neutral ----------------------------------------------------------
func _camera_steer() -> void:
	await _reset(Vector3(-20.0, 0.02, 60.0))
	var cam := Camera3D.new()
	cam.name = "TestCamera"
	add_child(cam)
	cam.global_transform = Transform3D(Basis.looking_at(Vector3.LEFT, Vector3.UP), Vector3(-20.0, 3.0, 64.0))
	cam.make_current()
	await ticks(2)
	p.move_input = Vector3.ZERO
	p.traversal.begin_drive()
	var y0 := yaw_of(p.traversal.get_drive_dir())
	var rate_max := 0.0
	var prev := y0
	for i in 120:
		await get_tree().physics_frame
		var y := yaw_of(p.traversal.get_drive_dir())
		rate_max = maxf(rate_max, absf(rad_to_deg(angle_difference(prev, y))) * 120.0)
		prev = y
	var dir := p.traversal.get_drive_dir()
	print("  stick neutral, camera looking -X: the drive turned to %s, fastest %.1f deg/s" % [dir, rate_max])
	check(dir.dot(Vector3.LEFT) > 0.999 and rate_max <= Tuning.R7_DRIVE_TURN_RATE + 0.5,
		"stick neutral: the drive steers toward camera forward at most at the turn rate")
	cam.queue_free()
	await settle(p, 10)

# --- Carry's multipliers ------------------------------------------------------------------------------
func _carry_mult_never_slows() -> void:
	await _reset(Vector3(30.0, 0.02, 60.0))
	var d := install_carry_double(p, 0.5)
	p.move_input = Vector3.FORWARD
	await ticks(60)
	var walk := hspeed(p)
	p.move_input = Vector3.ZERO
	await ticks(30)
	var r := await _drive_samples(1.0, [1.0])
	var at1: Array = (r["at"] as Dictionary).get(1.0, [0.0, 0.0])
	print("  holding (Carry walking share 0.5): walks at %.2f m/s; drive %.2f m/s at 1 s (capsule %.2f)" % [walk, at1[0], at1[1]])
	check(near(walk, Tuning.WALK_SPEED * 0.5, 0.05), "Carry's walking share slows walking with a body (%.2f)" % walk)
	check(near(float(at1[1]), Tuning.R7_DRIVE_MAX_SPEED, 0.3), "but never the drive (%.2f m/s at 1 s)" % at1[1])
	# Letting go of the body ends the drive.
	d.set(&"holding", false)
	await ticks(2)
	var ended := not p.traversal.is_driving()
	print("  the body let go: drive ended %s" % ended)
	check(ended, "letting go of the held body ends the drive")
	remove_carry_double(p, d)
	await settle(p, 20)

# --- The drive ends by itself on a hit; end_drive() and a dead stop -------------------------------------
func _ends_by_itself() -> void:
	await _reset(Vector3(40.0, 0.02, 60.0))
	p.traversal.begin_drive()
	await ticks(60)
	p.react(&"snap", Vector3.BACK, 0.4, 0.45)
	await ticks(1)
	var ended_react := not p.traversal.is_driving()
	await settle(p, 60)
	# end_drive() keeps the run going (walking slows it); set_drive_speed(0) first stops dead.
	await place(p, Vector3(40.0, 0.02, 60.0))
	p.traversal.begin_drive()
	await ticks(120)
	p.traversal.end_drive()
	await ticks(1)
	var v_after := hspeed(p)
	await ticks(40)
	var v_later := hspeed(p)
	p.traversal.begin_drive()
	await ticks(60)
	p.traversal.set_drive_speed(0.0)
	p.traversal.end_drive()
	await ticks(1)
	var v_dead := hspeed(p)
	var refused := false
	p.react(&"snap", Vector3.BACK, 0.4, 0.45)
	await ticks(1)
	refused = not p.traversal.begin_drive()
	print("  hit mid-drive (react snap): drive ended %s; end_drive at 9.5: %.2f then %.2f after 1/3 s; set_drive_speed(0) + end_drive: %.2f; begin_drive while reacting refused %s" % [
		ended_react, v_after, v_later, v_dead, refused])
	check(ended_react, "a hit on the player ends the drive")
	check(v_after > 8.0 and v_later < 0.1, "end_drive() leaves the run, walking brings it to a stop")
	check(v_dead < 0.05, "set_drive_speed(0) then end_drive() stops dead")
	check(refused, "no drive while reacting")
	await settle(p, 60)

# --- Following the body through a wall it broke ----------------------------------------------------------
## A drywall panel across the lane, broken open by `late`: early (the body's
## probe 0.8 m ahead of the capsule) or late (just before the capsule meets it).
func _through_broken_wall(late: bool) -> void:
	var x := 60.0 if not late else 70.0
	await _reset(Vector3(x, 0.02, 60.0))
	var panel := _panel(Vector3(x, 0.0, 50.0))
	await ticks(5)
	var face_z := 50.0 + panel.size.z * 0.5
	# Late: inside the last tick of motion before the capsule meets the panel
	# (9.5 m/s is 0.079 m a tick), so the cells it breaks are still there for it.
	var lead := Tuning.R7_DRIVE_MAX_SPEED / 120.0 if late else 0.8
	p.traversal.begin_drive()
	var m := {"broke": false, "v_in": 0.0, "lo": INF, "passes0": p.traversal.drive_passes}
	var r := (p.capsule.shape as CapsuleShape3D).radius
	for i in 360:
		await get_tree().physics_frame
		var z := p.global_position.z
		if not m["broke"]:
			m["v_in"] = p.traversal.get_drive_speed()
			if z - r - face_z <= lead:
				panel.receive_impact(1.0e6, Vector3(x, 1.0, face_z), Vector3(0.0, 0.0, -9.0), Rect2(-0.4, -1.5, 0.8, 1.8))
				m["broke"] = true
		elif z > 50.0 - 1.5:
			m["lo"] = minf(float(m["lo"]), hspeed(p))
		else:
			break
	var z_end := p.global_position.z
	var passes: int = p.traversal.drive_passes - int(m["passes0"])
	var kept := float(m["lo"]) / maxf(float(m["v_in"]), 0.01)
	print("  drive into drywall broken %s (%.2f m ahead): through to z %.2f, lowest speed %.2f of %.2f (%.1f%%), passes %d, still driving %s" % [
		"late" if late else "early", lead, z_end, m["lo"], m["v_in"], kept * 100.0, passes, p.traversal.is_driving()])
	check(m["broke"] and float(m["v_in"]) >= Tuning.R7_DRIVE_MAX_SPEED - 0.3 and z_end < 50.0 - 1.5 and kept >= 0.9 \
			and p.traversal.is_driving(),
		"the capsule follows the body through a hole broken %s (%.1f%% kept)" % ["just before contact" if late else "0.8 m ahead", kept * 100.0])
	await settle(p, 10)
	panel.queue_free()

## A panel broken whole (props, clutter, a door frame break whole).
func _through_broken_panel_whole() -> void:
	var x := 80.0
	await _reset(Vector3(x, 0.02, 60.0))
	var panel := _panel(Vector3(x, 0.0, 50.0))
	await ticks(5)
	var face_z := 50.0 + panel.size.z * 0.5
	p.traversal.begin_drive()
	var m := {"broke": false, "v_in": 0.0, "lo": INF}
	for i in 360:
		await get_tree().physics_frame
		var z := p.global_position.z
		if not m["broke"]:
			m["v_in"] = p.traversal.get_drive_speed()
			if z - (p.capsule.shape as CapsuleShape3D).radius - face_z <= 0.3:
				panel.force_break(Vector3(x, 1.0, face_z), Vector3(0.0, 0.0, -9.0))
				m["broke"] = true
		elif z > 50.0 - 1.5:
			m["lo"] = minf(float(m["lo"]), hspeed(p))
		else:
			break
	var kept := float(m["lo"]) / maxf(float(m["v_in"]), 0.01)
	print("  drive into a panel broken whole 0.3 m ahead at %.2f m/s: to z %.2f, %.1f%% kept" % [m["v_in"], p.global_position.z, kept * 100.0])
	check(panel.is_broken and float(m["v_in"]) >= Tuning.R7_DRIVE_MAX_SPEED - 0.3 and p.global_position.z < 50.0 - 1.5 and kept >= 0.9,
		"the capsule follows the body through a panel broken whole")
	await settle(p, 10)
	panel.queue_free()

func _intact_wall_stops() -> void:
	var x := 90.0
	await _reset(Vector3(x, 0.02, 60.0))
	var panel := _panel(Vector3(x, 0.0, 50.0))
	await ticks(5)
	var face_z := 50.0 + panel.size.z * 0.5
	var passes0 := p.traversal.drive_passes
	p.traversal.begin_drive()
	await ticks(240)
	var z := p.global_position.z
	var v := p.traversal.get_drive_speed()
	print("  drive into an intact drywall panel: stops at z %.2f (face %.2f), drive speed %.2f, passes %d, panel broken %s" % [
		z, face_z, v, p.traversal.drive_passes - passes0, panel.is_broken])
	check(z > face_z + (p.capsule.shape as CapsuleShape3D).radius - 0.05 and v < 1.0 and not panel.is_broken \
			and p.traversal.drive_passes == passes0,
		"an intact wall stops the capsule (the run collapses; Carry slams the body)")
	await settle(p, 10)
	panel.queue_free()

func _debris_layers() -> void:
	var blocked := Layers.MASK_CAPSULE & (Layers.DEBRIS | Layers.DEBRIS_SMALL | Layers.RAGDOLL | Layers.DEAD_BODY)
	print("  capsule mask %d: debris, small debris, ragdolls and dead bodies %s" % [Layers.MASK_CAPSULE, "never block it" if blocked == 0 else "BLOCK it"])
	check(blocked == 0 and p.collision_mask == Layers.MASK_CAPSULE, "debris never blocks the player's capsule (layer rules)")

func _panel(at: Vector3) -> Destructible:
	var d := Destructible.new()
	d.surface = &"drywall"
	d.name = "DrivePanel"
	d.size = Vector3(3.0, 3.0, 0.25)
	d.transform = Transform3D(Basis(), Vector3(at.x, 1.5, at.z))
	add_child(d)
	return d

# --- G's real Carry: a held body, Dash through the real input path -----------------------------------------
func _real_hold_real_input() -> void:
	# The lane: the grab at z 59, a drywall panel at z 44, a concrete wall at z 32.
	var rp := spawn_real_player(Vector3(-40.0, 0.02, 60.0))
	await ticks(20)
	var g := spawn_enemy(&"grunt", Vector3(-40.0, 0.0, 59.1), Vector3.BACK)
	var dry := _panel(Vector3(-40.0, 0.0, 44.0))
	var concrete := _panel(Vector3(-40.0, 0.0, 32.0))
	concrete.surface = &"concrete"
	concrete.unbreakable = true
	concrete.name = "DriveConcrete"
	await ticks(20)
	var holding := false
	if rp.carry != null and rp.carry.has_method(&"grab_now"):
		rp.carry.call(&"grab_now", g, &"", true)
		holding = await wait_until(func() -> bool: return rp.carry.is_holding(), 60)
	if not holding:
		print("  NOTE G's Carry did not take a hold (grab_now); the real-hold drive is not measured here (G owns it)")
		g.queue_free()
		rp.queue_free()
		return
	stick(Vector3.FORWARD)
	await ticks(60)
	var walk := hspeed(rp)
	release_all_input()
	await ticks(20)
	var impacts := []
	var on_impact := func(holder: Node3D, _victim: Node3D, target: Node3D, _pos: Vector3, speed: float, result: StringName) -> void:
		if holder == rp:
			impacts.append("%s %s at %.1f m/s" % [result, target.name if target != null else &"-", speed])
	GameEvents.drive_impact.connect(on_impact)
	hold(&"dash")
	var started := await wait_until(func() -> bool: return rp.traversal.is_driving(), 10)
	var t0 := TimeDirector.now()
	var at1 := 0.0
	var cap1 := 0.0
	var passed_dry := false
	for i in 480:
		await get_tree().physics_frame
		if absf(TimeDirector.now() - t0 - 1.0) < 0.5 / 120.0:
			at1 = rp.traversal.get_drive_speed()
			cap1 = hspeed(rp)
		if rp.global_position.z < 44.0 - 0.6:
			passed_dry = true
		if not rp.traversal.is_driving() and TimeDirector.now() - t0 > 1.2:
			break
	let_go(&"dash")
	GameEvents.drive_impact.disconnect(on_impact)
	await ticks(30)
	print("  G's real hold: walks %.2f m/s with the body; Dash through Input drives %s; %.2f m/s at 1 s (capsule %.2f); drive impacts %s; drywall broken %s, the player through it %s, stopped at z %.2f (concrete at 32), still holding %s, passes %d" % [
		walk, started, at1, cap1, impacts, dry.is_broken, passed_dry, rp.global_position.z, rp.carry.is_holding(), rp.traversal.drive_passes])
	check(started and near(at1, Tuning.R7_DRIVE_MAX_SPEED, 0.3) and near(cap1, Tuning.R7_DRIVE_MAX_SPEED, 0.3),
		"holding a real body, Dash through Input drives at %.2f m/s at 1 s" % at1)
	check(dry.is_broken or passed_dry, "with G's real drive the body breaks the drywall")
	check(passed_dry and rp.global_position.z > 32.0, "the player follows the body through the broken drywall and stops at the concrete")
	release_all_input()
	if is_instance_valid(g):
		g.queue_free()
	rp.queue_free()
	await ticks(5)
