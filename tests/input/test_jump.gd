extends "res://tests/input/input_test_base.gd"
## Jump (Space / pad A; Round 5 numbers, Feel Reference: Jump; kept by the
## Round 7 amendment) through the real input path: a Space key event ->
## InputInterpreter -> PlayerController's jump buffer -> Traversal.on_jump_pressed
## (it drives the player: agent M), else Fighter.jump().
## - A standing jump peaks at Tuning.JUMP_HEIGHT (1.2 m) under
##   Tuning.PLAYER_GRAVITY rising and x Tuning.FALL_GRAVITY_MULT falling (air
##   time ~0.89 s), within 5%; a soft landing has no recovery; a jump pressed up
##   to Tuning.JUMP_BUFFER_TIME before landing fires on landing; horizontal
##   velocity is kept exactly (a running jump covers v x air time). Whoever
##   drives the jump must meet these: checked with Traversal driving, and on
##   Fighter's own movement (Traversal detached), where the stick steers a
##   standing hop at no more than Tuning.JUMP_AIR_STEER x walk speed.
## - An enemy's jump peaks at Tuning.JUMP_APEX.
## - No jump while holding a body.

func run() -> void:
	_timeout = 120.0
	# --- Traversal drives the player (the game's path). --------------------------------------
	print("Traversal drives the jump")
	var p := spawn_player(Vector3.ZERO)
	await ticks(40)
	check(p.traversal != null, "the player has Traversal")
	await _suite(p, true)
	p.queue_free()
	await ticks(5)

	# --- Fighter's own movement (Traversal detached). -------------------------------------------
	print("Fighter's own movement drives the jump")
	var q := spawn_player(Vector3(10, 0, 0))
	await ticks(5)
	q.traversal.queue_free()
	q.traversal = null
	await ticks(40)
	check(not q.is_traversal_driving(), "Fighter's own movement drives the player")
	await _suite(q, false)
	# Air steering of a standing hop: the stick steers up to JUMP_AIR_STEER x walk speed.
	var cap := Tuning.WALK_SPEED * Tuning.JUMP_AIR_STEER
	var x0 := q.global_position
	var t0 := TimeDirector.now()
	press(&"move_forward")
	_space(true)
	await ticks(1)
	_space(false)
	var top := 0.0
	await ticks(2)
	while q.is_airborne():
		top = maxf(top, _hspeed(q))
		await get_tree().physics_frame
	var air := TimeDirector.now() - t0
	var drift := Vector2(q.global_position.x - x0.x, q.global_position.z - x0.z).length()
	release(&"move_forward")
	print("  standing hop, stick held: top %.2f m/s (cap %.2f), drift %.2f m in %.2f s" % [top, cap, drift, air])
	check(top <= cap * 1.01, "standing hop air speed %.2f m/s <= cap %.2f" % [top, cap])
	check(drift > 0.6 and drift <= cap * air + 0.05, "standing hop drift %.2f m (at most cap x air time %.2f)" % [drift, cap * air])
	await wait_until(func() -> bool: return q.velocity.length() < 0.01 and q.can_act(), 240)

	# --- An enemy's jump: Tuning.JUMP_APEX under Tuning.GRAVITY. ---------------------------------
	var e := spawn_dummy(&"grunt", Vector3(6, 0, 0), Vector3.FORWARD)
	await ticks(30)
	var ey := e.global_position.y
	var took := e.jump()
	var e_apex := 0.0
	for i in 200:
		await get_tree().physics_frame
		e_apex = maxf(e_apex, e.global_position.y - ey)
		if e_apex > 0.05 and not e.is_airborne():
			break
	print("  enemy jump apex %.3f m (Tuning %.2f)" % [e_apex, Tuning.JUMP_APEX])
	check(took and near(e_apex, Tuning.JUMP_APEX, 0.05), "an enemy's jump peaks at %.3f m" % e_apex)
	await ticks(10)
	check(e.is_landing() or e.can_act(), "the enemy lands")

	# --- No jump while holding a body. ---------------------------------------------------------
	var r := spawn_player(Vector3(20, 0, 0))
	var held := spawn_dummy(&"grunt", Vector3(20, 0, -1.0), Vector3.BACK)
	await ticks(40)
	held.react(&"fold", Vector3.FORWARD, 0.0, 3.0)  # a reacting body connects at once (Carry)
	press(&"grab")
	await ticks(1)
	release(&"grab")
	await wait_until(func() -> bool: return r.carry.is_holding_body(), 120)
	check(r.carry.is_holding_body(), "the player holds the grunt")
	var ry := r.global_position.y
	var rose := 0.0
	_space(true)
	await ticks(1)
	_space(false)
	for i in 40:
		await get_tree().physics_frame
		rose = maxf(rose, r.global_position.y - ry)
	check(rose < 0.05 and not r.is_airborne(), "Space while holding a body does not jump (rose %.3f m)" % rose)
	done()

## The Round 5 jump numbers on `p` (Space key events). `traversal`: Traversal drives.
func _suite(p: Fighter, traversal: bool) -> void:
	var tag := "Traversal" if traversal else "own movement"
	check(p.is_on_floor(), "%s: starts on the floor" % tag)
	var y0 := p.global_position.y
	var g := Tuning.PLAYER_GRAVITY
	var want_air := sqrt(2.0 * Tuning.JUMP_HEIGHT / g) + sqrt(2.0 * Tuning.JUMP_HEIGHT / (g * Tuning.FALL_GRAVITY_MULT))
	var r := await _jump_once(p)
	print("  %s: apex %.3f m, air %.3f s (want %.3f), landing %.2f m/s" % [tag, r["apex"], r["air"], want_air, r["land_speed"]])
	check(near(r["apex"], Tuning.JUMP_HEIGHT, 0.05), "%s: apex %.3f m (Tuning %.2f)" % [tag, r["apex"], Tuning.JUMP_HEIGHT])
	check(near(r["air"], want_air, 0.05), "%s: air time %.3f s (want %.3f)" % [tag, r["air"], want_air])
	check(r["airborne_seen"], "%s: is_airborne() true in the air" % tag)
	check(absf(p.global_position.y - y0) < 0.02, "%s: lands back on the floor" % tag)
	check(r["land_speed"] < Tuning.LAND_HARD_SPEED, "%s: a standing jump lands soft" % tag)
	await ticks(1)
	check(p.can_act() and not p.is_landing(), "%s: a soft landing has no recovery" % tag)
	await ticks(30)

	# A jump pressed just before landing (inside the buffer) fires on landing.
	_space(true)
	await ticks(1)
	_space(false)
	await wait_until(func() -> bool: return p.is_airborne() and p.velocity.y < -2.0, 240)
	await wait_until(func() -> bool: return p.global_position.y - y0 < 0.25, 240)
	_space(true)  # ~0.06 s before touching down
	await ticks(1)
	_space(false)
	var low := INF
	var again := false
	for i in 60:
		await get_tree().physics_frame
		var h := p.global_position.y - y0
		low = minf(low, h)
		if low < 0.02 and h > low + 0.1:
			again = true  # touched down and took off again (often on the same tick)
			break
	check(again, "%s: a jump pressed just before landing fires on landing (buffered)" % tag)
	await wait_until(func() -> bool: return not p.is_airborne(), 240)
	await wait_until(func() -> bool: return p.velocity.length() < 0.01 and p.can_act(), 240)
	await ticks(20)

	# Running jump: horizontal velocity kept exactly.
	press(&"move_forward")
	await ticks(60)  # full walk speed
	var v0 := _hspeed(p)
	var r0 := p.global_position
	var t0 := TimeDirector.now()
	_space(true)
	await ticks(1)
	_space(false)
	var lo := INF
	var hi := 0.0
	await ticks(1)
	while p.is_airborne():
		lo = minf(lo, _hspeed(p))
		hi = maxf(hi, _hspeed(p))
		await get_tree().physics_frame
	var air := TimeDirector.now() - t0
	release(&"move_forward")
	var run_dist := Vector2(p.global_position.x - r0.x, p.global_position.z - r0.z).length()
	check(near(lo, v0, 0.02) and hi <= v0 * 1.01, "%s: running jump keeps its speed (%.2f..%.2f m/s, take-off %.2f)" % [tag, lo, hi, v0])
	check(near(run_dist, v0 * air, 0.06), "%s: running jump covers %.2f m (v x air time %.2f)" % [tag, run_dist, v0 * air])
	await wait_until(func() -> bool: return p.velocity.length() < 0.01 and p.can_act(), 240)
	await ticks(20)

func _hspeed(p: Fighter) -> float:
	return Vector2(p.velocity.x, p.velocity.z).length()

## The Space key (Controls binds it to `jump` by physical keycode).
func _space(down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = KEY_SPACE
	e.physical_keycode = KEY_SPACE
	e.pressed = down
	Input.parse_input_event(e)

## Press Space once; track apex, real air time and the landing speed.
func _jump_once(p: Fighter) -> Dictionary:
	var base := p.global_position.y
	var apex := 0.0
	var seen := false
	var t0 := TimeDirector.now()
	var t_land := -1.0
	var vy_last := 0.0
	var prev_y := base
	_space(true)
	for i in 400:
		await get_tree().physics_frame
		if p.is_airborne():
			seen = true
		var y := p.global_position.y
		if seen and p.is_airborne():
			vy_last = (y - prev_y) * 120.0
		prev_y = y
		apex = maxf(apex, y - base)
		if seen and not p.is_airborne():
			t_land = TimeDirector.now()
			break
	_space(false)
	return {"apex": apex, "air": t_land - t0 if t_land > 0.0 else 0.0, "airborne_seen": seen, "land_speed": absf(vy_last)}
