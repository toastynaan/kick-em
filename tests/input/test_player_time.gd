extends "res://tests/input/input_test_base.gd"
## Player time (Round 5 F0 acceptance, agent H): in Focus mode the player
## covers the same distance per real second as at normal speed, within 5%,
## while an enemy walks at the world's slowed rate. Also within 5%: the jump
## apex and real air time, a knockback slide, a sprint (when Traversal drives
## the player), and a run during any other slow motion (the player keeps real
## time in all of it: TimeDirector.player_time_factor). Each measurement runs
## inside one Focus mode (2 s of real time, started with the Focus button).

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	var g := spawn_dummy(&"grunt", Vector3(30, 0, 0), Vector3.FORWARD)
	await ticks(40)

	# --- Walk. --------------------------------------------------------------------
	var normal := await _run(p, g, false)
	var focus := await _run(p, g, true)
	print("  walk: %.3f m per real s normal, %.3f in Focus mode (time %.2fx)" % [normal["run"], focus["run"], focus["scale"]])
	check(near(focus["scale"], Tuning.FOCUS_SCALE, 0.02), "Focus mode: world at %.2fx" % focus["scale"])
	check(near(focus["run"], normal["run"], 0.05), "F0: distance per real second in Focus mode %.3f vs %.3f m (%.1f%%)"
		% [focus["run"], normal["run"], 100.0 * (focus["run"] / maxf(normal["run"], 1e-4) - 1.0)])
	check(near(focus["enemy"], normal["enemy"] * Tuning.FOCUS_SCALE, 0.08),
		"the enemy walks at the world's rate (%.2f vs %.2f m per real s)" % [focus["enemy"], normal["enemy"]])

	# --- Sprint (Traversal). --------------------------------------------------------
	var sn := await _sprint(p, false)
	if sn.is_empty():
		print("  NOTE Traversal does not drive the player's sprint yet; sprint skipped")
	else:
		var sf := await _sprint(p, true)
		print("  sprint: %.3f m per real s normal, %.3f in Focus mode" % [sn["run"], sf["run"]])
		check(near(sf["run"], sn["run"], 0.05), "sprint distance per real second in Focus mode %.3f vs %.3f m" % [sf["run"], sn["run"]])

	# --- Jump and knockback. ----------------------------------------------------------
	var jn := await _jump(p, false)
	var jf := await _jump(p, true)
	check(near(jf["apex"], jn["apex"], 0.05), "jump apex %.3f vs %.3f m" % [jf["apex"], jn["apex"]])
	check(near(jf["air"], jn["air"], 0.05), "air time %.3f vs %.3f real s" % [jf["air"], jn["air"]])
	var kn := await _slide(p, false)
	var kf := await _slide(p, true)
	check(near(kf, kn, 0.05), "knockback slide %.3f vs %.3f m" % [kf, kn])

	# --- Any other slow motion (a 0.25x request): still real speed. --------------------
	var slow := await _run(p, g, false, true)
	print("  walk in a 0.25x slow motion: %.3f m per real s (time %.2fx)" % [slow["run"], slow["scale"]])
	check(slow["scale"] < 0.3, "the slow motion ran (%.2fx)" % slow["scale"])
	check(near(slow["run"], normal["run"], 0.05), "slow motion: distance per real second %.3f vs %.3f m" % [slow["run"], normal["run"]])
	done()

func _focus_on(p: Fighter) -> void:
	p.focus = Tuning.FOCUS_MAX
	press(&"focus")
	await ticks(1)
	release(&"focus")
	await ticks(1)

func _focus_off(p: Fighter) -> void:
	p.end_focus()
	TimeDirector.reset()
	await wait_until(func() -> bool: return Engine.time_scale > 0.99, 240)

## Walk for 1 real second (after 0.25 s to reach speed). Returns the player's
## and the enemy's metres per real second and the time scale seen.
func _run(p: Fighter, g: Fighter, in_focus: bool, other_slowmo := false) -> Dictionary:
	await _home(p)
	if in_focus:
		await _focus_on(p)
	if other_slowmo:
		TimeDirector.request_slowmo(0.25, 1.6, TimeDirector.PRIO_WALL_BREAK)
		await ticks(1)
	g.move_input = Vector3.FORWARD
	press(&"move_right")
	await ticks(30)
	var a := p.global_position
	var ga := g.global_position
	var t0 := TimeDirector.now()
	var scale := Engine.time_scale
	await ticks(120)
	var dt := TimeDirector.now() - t0
	var b := p.global_position
	var gb := g.global_position
	release(&"move_right")
	g.move_input = Vector3.ZERO
	await _focus_off(p)
	return {"run": Vector2(b.x - a.x, b.z - a.z).length() / dt,
		"enemy": Vector2(gb.x - ga.x, gb.z - ga.z).length() / dt, "scale": scale}

## Sprint for 1 real second at full speed. {} when Traversal does not drive it.
func _sprint(p: Fighter, in_focus: bool) -> Dictionary:
	await _home(p)
	press(&"move_right")
	press(&"dash")
	await ticks(180)  # past the 1.2 s ramp
	if not p.is_traversal_driving() or p.traversal == null or not p.traversal.is_sprinting():
		release(&"dash")
		release(&"move_right")
		await ticks(60)
		return {}
	if in_focus:
		await _focus_on(p)
	await ticks(6)
	var a := p.global_position
	var t0 := TimeDirector.now()
	await ticks(120)
	var dt := TimeDirector.now() - t0
	var b := p.global_position
	release(&"dash")
	release(&"move_right")
	await _focus_off(p)
	await ticks(60)
	return {"run": Vector2(b.x - a.x, b.z - a.z).length() / dt}

## One standing jump: apex (m) and real air time (s).
func _jump(p: Fighter, in_focus: bool) -> Dictionary:
	await _home(p)
	if in_focus:
		await _focus_on(p)
	clear_events()
	var base := p.global_position.y
	var apex := 0.0
	var t0 := TimeDirector.now()
	press(&"jump")
	var t_land := -1.0
	for i in 400:
		await get_tree().physics_frame
		apex = maxf(apex, p.global_position.y - base)
		if apex > 0.05 and p.is_on_floor() and not p.is_airborne():
			t_land = TimeDirector.now()
			break
	release(&"jump")
	await _focus_off(p)
	return {"apex": apex, "air": t_land - t0 if t_land > 0.0 else 0.0}

## A 5 m/s knockback for 0.2 s of player time: 1 m.
func _slide(p: Fighter, in_focus: bool) -> float:
	await _home(p)
	if in_focus:
		await _focus_on(p)
	var k0 := p.global_position
	p.knockback(Vector3(5.0, 0.0, 0.0), 0.2)
	await ticks(60)
	var d := Vector2(p.global_position.x - k0.x, p.global_position.z - k0.z).length()
	await _focus_off(p)
	return d

## Back to the start, standing still.
func _home(p: Fighter) -> void:
	await wait_until(func() -> bool: return p.can_act(), 240)
	p.teleport_to(Vector3(0, 0, 0), Vector3.FORWARD)
	p.reset_air_state()
	await ticks(20)
