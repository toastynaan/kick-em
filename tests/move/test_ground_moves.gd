extends "res://tests/move/move_test_base.gd"
## Ground movement through the real input path (PlayerController reading
## Input), with measured numbers:
## - step-ups: a 0.3 m step and a 0.45 m curb are stepped onto at 100% of the
##   walking speed; 0.25 m stairs are climbed to their landing;
## - walking off a 3 m ledge falls (is_airborne(), get_fall_height()) and lands
##   Hard on the feet (GameEvents.landing): no shockwave (heavy landings only),
##   the run held through the crouch;
## - holding a body (Round 7, docs/Round 7 — Freeflow Combat.md: "no parkour while
##   carrying"): steps stay, but no vault, no jump; a prop in hand changes nothing;
## - Space (a real key event through Controls -> PlayerController) jumps, and
##   beside a runnable wall at a sprint starts a wall run.

var p: Fighter

func _init() -> void:
	_timeout = 240.0

func run() -> void:
	p = spawn_real_player(Vector3(0.0, 0.02, 0.0))
	await ticks(30)
	await _steps()
	await _stairs()
	await _fall()
	await _holding_body()
	await _space_jump_and_wall_run()
	done()

func _reset(pos: Vector3, facing := Vector3.FORWARD) -> void:
	release_all_input()
	await ticks(2)
	await settle(p, 10)
	await place(p, pos, facing)
	await ticks(4)
	clear_events()

## Walk (or sprint) along `dir` for `n` ticks; returns {y_max, v_lo (after 0.3 s), v_in, x_end}.
func _run(dir: Vector3, n: int, sprint := false) -> Dictionary:
	stick(dir)
	if sprint:
		hold(&"dash")
	var m := {"y_max": -INF, "v_lo": INF, "v_in": 0.0, "kinds": []}
	for i in n:
		await get_tree().physics_frame
		m["y_max"] = maxf(float(m["y_max"]), p.global_position.y)
		var k := p.traversal.get_parkour_kind()
		if k != &"" and not (m["kinds"] as Array).has(k):
			(m["kinds"] as Array).append(k)
	release_all_input()
	m["end"] = p.global_position
	return m

# --- Step-ups ----------------------------------------------------------------------------------
func _steps() -> void:
	for h: float in [0.3, 0.45]:
		var x := 0.0 if h < 0.4 else 4.0
		await _reset(Vector3(x, 0.02, 0.0))
		make_box(Vector3(x, h * 0.5, -3.0 - 1.0), Vector3(1.6, h, 2.0), "Step%.2f" % h)  # near face at z -3
		await ticks(2)
		stick(Vector3.FORWARD)
		var v_in := 0.0
		var lo := INF
		var stepped := false
		for i in 150:
			await get_tree().physics_frame
			var z := p.global_position.z
			if z > -2.0:
				v_in = hspeed(p)
			elif z > -4.0:
				lo = minf(lo, hspeed(p))
			if p.traversal.get_parkour_kind() == &"step":
				stepped = true
			if z < -4.0:
				break
		release_all_input()
		var y := p.global_position.y
		print("  walking into a %.2f m step at %.2f m/s: stepped %s, lowest speed over it %.2f (%.1f%%), standing at y %.2f" % [
			h, v_in, stepped, lo, lo / maxf(v_in, 0.01) * 100.0, y])
		check(stepped and near(y, h, 0.05), "a %.2f m step is stepped onto" % h)
		check(lo >= v_in * 0.99, "the step keeps 100%% of the walking speed (%.1f%%)" % (lo / maxf(v_in, 0.01) * 100.0))
		check(count_events(&"parkour") >= 1 and (last_event(&"parkour")[1] as StringName) == &"step", "the step emits GameEvents.parkour &\"step\" (effects)")

func _stairs() -> void:
	await _reset(Vector3(10.0, 0.02, 0.0))
	var top := make_stairs(10.0, -2.0, 8, 0.25, 0.3, 1.6, 6.0)
	await ticks(2)
	var m := await _run(Vector3.FORWARD, 240)
	var e: Vector3 = m["end"]
	print("  walking up 8 stairs (0.25 m rise, 0.3 m run): ends at y %.2f, z %.2f (landing %.2f m high), steps %d" % [
		e.y, e.z, top, count_events(&"parkour")])
	check(near(e.y, top, 0.05) and e.z < -2.0 - 0.3 * 8, "stairs are climbed to the landing (step-ups)")

# --- Falls -----------------------------------------------------------------------------------------
func _fall() -> void:
	make_box(Vector3(30.0, 1.5, -2.0), Vector3(3.0, 3.0, 4.0), "Ledge3m")  # top at y 3, far edge at z -4
	await _reset(Vector3(30.0, 3.05, -2.0))
	await ticks(10)
	stick(Vector3.FORWARD)
	var m := {"air": false, "fighter_air": false, "fall": 0.0}
	var landed := await wait_until(func() -> bool:
		m["air"] = bool(m["air"]) or p.traversal.is_airborne()
		m["fighter_air"] = bool(m["fighter_air"]) or p.is_airborne()
		m["fall"] = maxf(float(m["fall"]), p.traversal.get_fall_height())
		return count_events(&"landing") > 0, 240)
	var air_after := p.traversal.is_airborne() or p.traversal.get_fall_height() > 0.0
	var land := last_event(&"landing")
	await ticks(2)
	var v_after := hspeed(p)
	await ticks(20)
	release_all_input()
	var level: StringName = land[1] if land.size() > 1 and land[1] is StringName else &""
	var vs: float = land[3] if land.size() > 3 and land[3] is float else 0.0
	print("  walking off a 3 m ledge: airborne %s (Fighter %s), fall height up to %.2f m; landed %s (%s at %.2f m/s), walking at %.2f m/s two ticks later, shockwaves %d, down %s" % [
		m["air"], m["fighter_air"], m["fall"], landed, level, vs, v_after, count_events(&"shockwave"), p.is_down()])
	check(landed and level == &"hard" and count_events(&"landed") >= 1, "a 3 m fall lands Hard (GameEvents.landing / landed for effects)")
	check(count_events(&"shockwave") == 0 and not p.is_down() and p.can_act(), "a Hard landing: no shockwave (heavy only), on the feet")
	check(v_after >= Tuning.WALK_SPEED * 0.9, "the stick held runs on through the hard-landing crouch (%.2f)" % v_after)
	check(bool(m["air"]) and bool(m["fighter_air"]) and float(m["fall"]) > 2.5 and not air_after,
		"a real fall reports is_airborne() and get_fall_height() (%.2f m), cleared on landing" % m["fall"])

# --- Holding a body: steps, but no parkour and no jump --------------------------------------------
func _holding_body() -> void:
	for prop: bool in [false, true]:
		var x := 40.0 if not prop else 50.0
		make_box(Vector3(x, 0.15, -4.0), Vector3(1.6, 0.3, 2.0), "HoldStep")      # near face z -3
		make_wall_across(-10.0, 0.9, 0.3, 4.0, x)                                # near face z -10
		await _reset(Vector3(x, 0.02, 0.0))
		var d := install_carry_double(p, 0.7, prop)
		await ticks(2)
		stick(Vector3.FORWARD)
		if prop:
			hold(&"dash")
		var m := {"step": false, "y_top": 0.0, "kinds": [], "still": 0}
		for i in 600:
			await get_tree().physics_frame
			var k := p.traversal.get_parkour_kind()
			if k != &"" and not (m["kinds"] as Array).has(k):
				(m["kinds"] as Array).append(k)
			if p.global_position.z < -3.2 and p.global_position.z > -4.8:
				m["y_top"] = maxf(float(m["y_top"]), p.global_position.y)  # over the step
			m["still"] = int(m["still"]) + 1 if p.global_position.z < -9.0 and hspeed(p) < 0.2 else 0
			if p.global_position.z < -11.0 or int(m["still"]) >= 30:
				break
		var z_end := p.global_position.z
		var v := hspeed(p)
		release_all_input()
		await ticks(4)
		var jumped := p.traversal.on_jump_pressed()
		var y_max := 0.0
		for i in 30:
			await get_tree().physics_frame
			y_max = maxf(y_max, p.global_position.y)
		var what := "a prop in hand" if prop else "a body held (walking %.2f m/s)" % (Tuning.WALK_SPEED * 0.7)
		print("  %s: parkour %s, stopped at z %.2f (0.9 m wall at -10), on the step at y %.2f, Jump taken %s (highest %.2f)" % [
			what, m["kinds"], z_end, m["y_top"], jumped, y_max])
		if prop:
			check((m["kinds"] as Array).has(&"vault") and z_end < -10.0 and jumped,
				"a prop in hand changes nothing: the sprint vaults the wall, Jump jumps")
		else:
			check((m["kinds"] as Array).has(&"step") and near(float(m["y_top"]), 0.3, 0.05), "holding a body, steps stay")
			check(not (m["kinds"] as Array).has(&"vault") and z_end > -10.0 and v < 1.0,
				"holding a body, a 0.9 m wall is a wall (no parkour while carrying)")
			check(not jumped and y_max < 0.35, "holding a body, no jump")
		remove_carry_double(p, d)
		await settle(p, 40)

# --- Space: jump and wall run through the real key path -----------------------------------------
func _space_jump_and_wall_run() -> void:
	await _reset(Vector3(80.0, 0.02, 0.0))
	clear_events()
	var y0 := p.global_position.y
	await tap_key(KEY_SPACE, 3)
	var apex := 0.0
	for i in 120:
		await get_tree().physics_frame
		apex = maxf(apex, p.global_position.y - y0)
	print("  Space (standing): jumped %d, apex %.2f m (Tuning.JUMP_HEIGHT %.2f), landings %d" % [
		count_events(&"jumped"), apex, Tuning.JUMP_HEIGHT, count_events(&"landing")])
	check(count_events(&"jumped") == 1 and near(apex, Tuning.JUMP_HEIGHT, 0.08) and count_events(&"landing") >= 1,
		"Space jumps (%.2f m) and lands" % apex)
	# Sprint beside a runnable wall on the right, steer ~20 degrees in, Space.
	make_runnable_wall(91.2, 0.0, -12.0, 4.0, 0.4)
	await _reset(Vector3(90.3, 0.02, 14.0))
	hold(&"move_forward")
	hold(&"dash")
	await wait_until(func() -> bool: return p.global_position.z <= 0.2 and p.traversal.sprint_charge >= 0.65, 400)
	hold(&"move_right", 0.364)  # with move_forward: ~20 degrees toward the wall
	await wait_until(func() -> bool: return p.global_position.z <= -0.8, 60)
	var charge := p.traversal.sprint_charge
	clear_events()
	await tap_key(KEY_SPACE, 3)
	var ran := count_events(&"wall_run_started") > 0 or p.traversal.is_wall_running()
	var m := {"y": 0.0}
	await wait_until(func() -> bool:
		m["y"] = maxf(float(m["y"]), p.global_position.y)
		return not p.traversal.is_wall_running(), 200)
	release_all_input()
	print("  sprint (sprint_charge %.2f) beside a runnable wall + Space: wall run %s, rose to %.2f m" % [charge, ran, m["y"]])
	check(ran and float(m["y"]) > 0.3, "sprint + Space beside a runnable wall starts a wall run")
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 300)
	await settle(p, 20)
