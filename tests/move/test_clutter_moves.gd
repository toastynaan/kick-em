extends "res://tests/move/move_test_base.gd"
## Round 6 clutter and structure (docs/ARCHITECTURE.md "Round 6"), through the
## real game path (PlayerController reading Input) with K's real Furniture and
## props and D's real platform. Measured numbers printed for each:
## - low static clutter (about 1.2 m and under) is vaulted or stepped at speed,
##   never a dead stop; tall clutter (a shelf, glass) blocks walking;
## - dynamic clutter (rigid bodies) never triggers a vault; the capsule pushes it;
## - a sprinting player runs through glass and cardboard (K smashes them at
##   Tuning.RUN_THROUGH_SPEED): no dead stop on the contact frame, speed kept logged;
## - the Yard's platform still mantles with a skirt broken, and with a hole
##   right where the mantle goes in; a wall-run kick-off still lands on it.

const LOW_KINDS: Array[StringName] = [&"coffee_table", &"bench", &"table", &"planter", &"barrel",
	&"fence", &"sofa", &"chair"]

var p: Fighter

func _init() -> void:
	_timeout = 1200.0

func run() -> void:
	p = spawn_real_player(Vector3(0.0, 0.02, 30.0))
	await ticks(30)
	await _low_clutter()
	await _tall_clutter_walk()
	await _run_through()
	await _dynamic_clutter()
	await _platform_in_yard()
	done()

func _reset(pos: Vector3, facing := Vector3.FORWARD) -> void:
	release_all_input()
	await ticks(4)
	await settle(p, 20)
	p.global_position = pos
	p.snap_facing(facing)
	p.velocity = Vector3.ZERO
	await ticks(8)

## Run (sprinting or walking) along -Z from z0 through an object whose near face
## is near z 0. Returns {kinds, v_in, lo, z_end, stopped}.
func _run_lane(x: float, z0: float, sprint: bool, past_z: float, max_ticks := 300) -> Dictionary:
	await _reset(Vector3(x, 0.02, z0))
	clear_events()
	hold(&"move_forward")
	if sprint:
		hold(&"dash")
	var m := {"kinds": [], "v_in": 0.0, "lo": INF, "stopped_ticks": 0}
	parkour_reset()
	for i in max_ticks:
		await get_tree().physics_frame
		parkour_track(p)
		var z := p.global_position.z
		var v := hspeed(p)
		if z > 2.0:
			m["v_in"] = v
		elif z > past_z:
			m["lo"] = minf(float(m["lo"]), v)
			if v < 1.0:
				m["stopped_ticks"] = int(m["stopped_ticks"]) + 1
		var k := p.traversal.get_parkour_kind()
		if k != &"" and not (m["kinds"] as Array).has(k):
			(m["kinds"] as Array).append(k)
		if z < past_z - 1.5 and not p.traversal.is_vaulting() and not p.traversal.is_airborne():
			break
	for i in 40:  # 0.3 s after the last landing
		await get_tree().physics_frame
		parkour_track(p)
	release_all_input()
	m["z_end"] = p.global_position.z
	m["stopped"] = int(m["stopped_ticks"]) >= 6
	m["moves"] = parkour_finish().duplicate()
	return m

# --- Low static clutter --------------------------------------------------------------------
func _low_clutter() -> void:
	var x := 0.0
	for kind in LOW_KINDS:
		x += 12.0
		var f := Furniture.create(kind, Transform3D(Basis(), Vector3(x, 0.0, -0.6)), &"")
		add_child(f)
		await ticks(3)
		var b := f.get_spec().bounds
		var far_z := -0.6 + b.position.z  # the far face (object space -Z side)
		var near_z := -0.6 + b.end.z
		# Shift so the near face sits at z 0.
		f.global_position.z -= near_z
		far_z -= near_z
		await ticks(2)
		var r := await _run_lane(x, 16.0, true, far_z)
		print("  %s (%.2f m tall, %.2f m deep): sprint %.2f m/s -> %s; ends z %.2f, dead stop %s" % [
			kind, b.size.y, b.size.z, r["v_in"], parkour_text(r["moves"]), r["z_end"], r["stopped"]])
		check(not (r["kinds"] as Array).is_empty() and not r["stopped"] and float(r["z_end"]) < far_z - 0.5,
			"sprinting over a %s (%.2f m): %s, no dead stop" % [kind, b.size.y, r["kinds"]])
		check(parkour_ok(r["moves"]), "over the %s every step keeps 100%% and every vault >= 90%% (%s)" % [kind, parkour_text(r["moves"])])
		# Walking (4.5 m/s, over the 3 m/s parkour gate) gets over it too.
		if kind == &"table" or kind == &"fence":
			var w := await _run_lane(x, 8.0, false, far_z)
			print("  %s walking at %.2f m/s: %s, ends z %.2f" % [kind, w["v_in"], parkour_text(w["moves"]), w["z_end"]])
			check(parkour_ok(w["moves"]), "walking over the %s keeps >= 90%% (%s)" % [kind, parkour_text(w["moves"])])
			check(not (w["kinds"] as Array).is_empty() and float(w["z_end"]) < far_z - 0.5,
				"walking over a %s vaults it (%s)" % [kind, w["kinds"]])

# --- Tall clutter -----------------------------------------------------------------------------
func _tall_clutter_walk() -> void:
	for kind: StringName in [&"shelf", &"glass"]:
		var x := 150.0 + (0.0 if kind == &"shelf" else 12.0)
		var f := Furniture.create(kind, Transform3D(Basis(), Vector3(x, 0.0, -0.4)), &"")
		add_child(f)
		await ticks(3)
		var b := f.get_spec().bounds
		var r := await _run_lane(x, 6.0, false, -3.0, 160)
		print("  walking into a %s (%.2f m): parkour %s, stops at z %.2f (near face %.2f), broken %s" % [
			kind, b.size.y, r["kinds"], r["z_end"], -0.4 + b.end.z, f.is_broken])
		check((r["kinds"] as Array).is_empty() and float(r["z_end"]) > -0.4 + b.end.z and not f.is_broken,
			"walking into tall clutter (%s) is blocked" % kind)

# --- Run-through: glass and cardboard -------------------------------------------------------------
func _run_through() -> void:
	var x := -10.0
	for kind: StringName in [&"glass", &"cardboard"]:
		for cap: float in [8.0, Tuning.RUN_THROUGH_SPEED + 0.4]:
			x -= 12.0
			Tuning.debug_speed_cap = cap
			var f := Furniture.create(kind, Transform3D(Basis(), Vector3(x, 0.0, -0.4)), &"big" if kind == &"cardboard" else &"")
			add_child(f)
			await ticks(3)
			await _reset(Vector3(x, 0.02, 16.0))
			hold(&"move_forward")
			hold(&"dash")
			await wait_until(func() -> bool: return p.traversal.sprint_charge >= 0.999 or p.global_position.z < 3.0, 300)
			var m := {"before": 0.0, "lo": INF, "broke_at": INF}
			for i in 360:
				await get_tree().physics_frame
				var z := p.global_position.z
				if z > 1.5:
					m["before"] = hspeed(p)
				elif z > -2.0:
					m["lo"] = minf(float(m["lo"]), hspeed(p))
				if f.is_broken and float(m["broke_at"]) == INF:
					m["broke_at"] = z
				if z < -3.0:
					break
			release_all_input()
			Tuning.debug_speed_cap = 8.0
			var kept := float(m["lo"]) / maxf(float(m["before"]), 0.01)
			print("  sprint through %s at %.2f m/s (cap %.1f): broken %s (player at z %.2f), lowest speed through it %.2f (%.1f%% kept), parkour %d" % [
				kind, m["before"], cap, f.is_broken, m["broke_at"], m["lo"], kept * 100.0, count_events(&"parkour")])
			check(f.is_broken and kept >= 0.95 and count_events(&"parkour") == 0,
				"sprinting at %.1f m/s through %s: no dead stop (%.1f%% kept)" % [m["before"], kind, kept * 100.0])
			await settle(p, 30)

# --- Dynamic clutter --------------------------------------------------------------------------------
func _dynamic_clutter() -> void:
	var x := -80.0
	# A LooseProp chair (K's loose office prop: a rigid body).
	var prop := LooseProp.new()
	prop.mass = 8.0
	prop.surface = &"wood"
	add_child(prop)
	prop.position = Vector3(x, 0.4, -0.3)
	var box := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(0.45, 0.8, 0.45)
	box.shape = bs
	prop.add_child(box)
	await ticks(60)
	var p0 := prop.global_position
	var r := await _run_lane(x, 16.0, true, -2.0, 400)
	var moved := prop.global_position.distance_to(p0)
	print("  sprint into a loose rigid chair (8 kg): parkour %s, lowest speed %.2f (%.1f%% of %.2f), prop moved %.2f m, ends z %.2f" % [
		r["kinds"], r["lo"], float(r["lo"]) / maxf(float(r["v_in"]), 0.01) * 100.0, r["v_in"], moved, r["z_end"]])
	check((r["kinds"] as Array).is_empty(), "a rigid body never triggers a vault")
	check(moved > 0.3 and not r["stopped"] and float(r["z_end"]) < -2.5, "the capsule pushes it (moved %.2f m) and runs on" % moved)
	# Walking into a loose 55 kg cabinet: it moves along with the walker (not flung).
	x -= 12.0
	var cab := LooseProp.new()
	cab.mass = 55.0
	cab.surface = &"metal"
	add_child(cab)
	cab.position = Vector3(x, 0.8, -0.3)
	var cbox := CollisionShape3D.new()
	var cbs := BoxShape3D.new()
	cbs.size = Vector3(0.6, 1.6, 0.5)
	cbox.shape = cbs
	cab.add_child(cbox)
	await ticks(60)
	var c0 := cab.global_position
	await _reset(Vector3(x, 0.02, 3.0))
	hold(&"move_forward")
	var cm := {"top": 0.0, "pv": 0.0, "n": 0}
	for i in 150:
		await get_tree().physics_frame
		cm["top"] = maxf(float(cm["top"]), Vector2(cab.linear_velocity.x, cab.linear_velocity.z).length())
		if i >= 60:
			cm["pv"] = float(cm["pv"]) + hspeed(p)
			cm["n"] = int(cm["n"]) + 1
	cm["pv"] = float(cm["pv"]) / maxf(float(cm["n"]), 1.0)
	release_all_input()
	var cmoved := c0.distance_to(cab.global_position)
	print("  walking into a loose 55 kg cabinet: it moved %.2f m, its top speed %.2f m/s, the walker averages %.2f m/s while pushing (%.0f%% of walk)" % [
		cmoved, cm["top"], cm["pv"], float(cm["pv"]) / Tuning.WALK_SPEED * 100.0])
	check(cmoved > 1.0 and float(cm["top"]) <= Tuning.WALK_SPEED * 0.8 and float(cm["pv"]) >= 1.5,
		"walking pushes a heavy prop along, not flung (%.2f m/s), and keeps going (%.2f m/s)" % [cm["top"], cm["pv"]])
	await settle(p, 20)
	# A chair knocked loose from the clutter (LooseFurniture).
	x -= 12.0
	var chair := Furniture.create(&"chair", Transform3D(Basis(), Vector3(x, 0.0, -0.3)), &"")
	add_child(chair)
	await ticks(3)
	# A crack-level hit knocks a light chair loose (K: light kinds come loose when cracked).
	var res := chair.receive_impact(0.6 * Tuning.FURNITURE[&"chair"]["break"],
		chair.global_position + Vector3(0.0, 0.4, 0.25), Vector3(0.0, 0.0, -1.5))
	await ticks(2)
	var loose := chair.loose_body
	var had_loose := loose != null
	print("  chair hit: %s, loose body %s" % [res, had_loose])
	await ticks(60)
	var lp0 := loose.global_position if is_instance_valid(loose) else Vector3.ZERO
	var r2 := await _run_lane(x, 16.0, true, -2.0, 400)
	var moved2 := loose.global_position.distance_to(lp0) if is_instance_valid(loose) else -1.0
	print("  sprint into a chair knocked loose (LooseFurniture %s): parkour %s, lowest speed %.2f, moved %.2f m (-1: smashed), smashed by the run %s" % [
		had_loose, r2["kinds"], r2["lo"], moved2, chair.is_broken])
	check(had_loose and (r2["kinds"] as Array).is_empty() and not r2["stopped"] and float(r2["z_end"]) < -2.5,
		"a loose chair never triggers a vault and never stops the run")

# --- The Yard's platform with its skirts damaged ----------------------------------------------------
func _platform_in_yard() -> void:
	var yard := YardBuilder.new()
	yard.name = "Yard"
	add_child(yard)
	yard.global_position = Vector3(0.0, 0.0, -400.0)
	yard.build()
	await ticks(5)
	var plat: AABB = yard.get_parkour_features()["platform"]
	var off := yard.global_position
	var face_x := off.x + plat.end.x
	var skirt: Destructible = null
	for d in yard.get_destructibles():
		if d.has_meta(&"platform_skirt") and absf(d.global_position.x - (face_x - 0.05)) < 0.2:
			skirt = d
	check(skirt != null, "found the platform's east skirt")
	if skirt == null:
		return
	# A hole right where the mantle goes in (z 0 of the platform, knee to chest).
	var hole_at := Vector3(face_x, 0.9, off.z + plat.get_center().z)
	var res := skirt.receive_impact(20000.0, hole_at, Vector3(-12.0, 0.0, 0.0), Rect2(-0.45, -0.7, 0.9, 1.4))
	await ticks(30)
	print("  platform skirt hit: %s, broken %s, point at the mantle open %s" % [res, skirt.is_broken, skirt.is_point_open(hole_at)])
	await _platform_mantle(face_x, off.z + plat.get_center().z, "a hole where the mantle goes in")
	# Now the whole skirt gone.
	if not skirt.is_broken:
		skirt.force_break(hole_at, Vector3(-12.0, 0.0, 0.0))
	await ticks(30)
	await _platform_mantle(face_x, off.z + plat.get_center().z, "the skirt broken")
	await _platform_walk(face_x, off.z + plat.get_center().z)
	await _facade_kickoff(yard, plat, off)

func _platform_mantle(face_x: float, z: float, label: String) -> void:
	await _reset(Vector3(face_x + 9.5, 0.05, z), Vector3.LEFT)
	clear_events()
	hold(&"move_left")
	hold(&"dash")
	var m := {"kinds": []}
	await wait_until(func() -> bool:
		var k := p.traversal.get_parkour_kind()
		if k != &"" and not (m["kinds"] as Array).has(k):
			(m["kinds"] as Array).append(k)
		return p.global_position.y > 1.7 and not p.traversal.is_vaulting(), 300)
	release_all_input()
	await ticks(10)
	print("  Yard platform, %s: sprint -> parkour %s, on the deck y %.2f" % [label, m["kinds"], p.global_position.y])
	check((m["kinds"] as Array).has(&"mantle") and p.global_position.y > 1.7, "the platform still mantles with %s" % label)

func _platform_walk(face_x: float, z: float) -> void:
	await _reset(Vector3(face_x + 3.0, 0.05, z), Vector3.LEFT)
	hold(&"move_left")
	await ticks(150)
	release_all_input()
	print("  Yard platform with the skirt broken, walking: stops at x %.2f (face %.2f), y %.2f" % [
		p.global_position.x, face_x, p.global_position.y])
	check(p.global_position.y < 0.3 and p.global_position.x > face_x - 0.6, "walking into the broken-skirt platform is still blocked by the deck")

## A wall-run kick-off from the west facade still lands on the platform (skirt broken).
func _facade_kickoff(yard: YardBuilder, plat: AABB, off: Vector3) -> void:
	var into := Vector3(-sin(deg_to_rad(20.0)), 0.0, -cos(deg_to_rad(20.0)))
	await _reset(off + Vector3(-10.3, 0.05, 10.3), Vector3.FORWARD)
	clear_events()
	hold(&"move_forward")
	hold(&"dash")
	await wait_until(func() -> bool: return p.traversal.sprint_charge >= Tuning.WALLRUN_MIN_CHARGE + 0.05, 400)
	let_go(&"move_forward")
	hold(&"move_forward", cos(deg_to_rad(20.0)))
	hold(&"move_left", sin(deg_to_rad(20.0)))
	await ticks(3)
	await tap(&"jump")
	var ran := p.traversal.is_wall_running()
	await wait_until(func() -> bool: return p.global_position.z <= off.z + 3.2 or not p.traversal.is_wall_running(), 120)
	release_all_input()
	await tap(&"jump")
	await wait_until(func() -> bool: return not p.traversal.is_airborne() and not p.traversal.is_vaulting(), 240)
	await ticks(2)
	var e := p.global_position - off
	var on_plat := e.y > 1.7 and e.x >= plat.position.x - 0.1 and e.x <= plat.end.x + 0.1 \
		and e.z >= plat.position.z - 0.1 and e.z <= plat.end.z + 0.1
	print("  Yard west facade kick-off (skirt broken): wall run %s, ends at (%.2f, %.2f, %.2f), on the platform %s" % [
		ran, e.x, e.y, e.z, on_plat])
	check(ran and on_plat, "a wall-run kick-off still lands on the platform")
	await settle(p, 20)
	yard.queue_free()
	await ticks(2)
