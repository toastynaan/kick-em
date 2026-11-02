extends "res://tests/input/input_test_base.gd"
## Jump (Space), Round 5 numbers (Feel Reference: Jump; lead decision 14): a
## standing jump peaks at Tuning.JUMP_HEIGHT (1.2 m) under
## Tuning.PLAYER_GRAVITY rising and x Tuning.FALL_GRAVITY_MULT falling (air time
## ~0.89 s), within 5%; a soft landing has no recovery (the player never stops);
## a jump pressed up to Tuning.JUMP_BUFFER_TIME before landing fires on landing;
## horizontal velocity is kept exactly (a running jump covers v x air time);
## a jump while crouched stands up first. Whoever drives the jump (Traversal,
## or Fighter's own movement when it does not) must meet these. Air steering
## of a standing hop is checked on Fighter's own movement only.

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	await ticks(40)
	check(p.is_on_floor(), "player starts on the floor")
	var y0 := p.global_position.y
	var g := Tuning.PLAYER_GRAVITY
	var want_air := sqrt(2.0 * Tuning.JUMP_HEIGHT / g) + sqrt(2.0 * Tuning.JUMP_HEIGHT / (g * Tuning.FALL_GRAVITY_MULT))

	var r := await _jump_once(p)
	check(near(r["apex"], Tuning.JUMP_HEIGHT, 0.05), "apex %.3f m (Tuning %.2f)" % [r["apex"], Tuning.JUMP_HEIGHT])
	check(near(r["air"], want_air, 0.05), "air time %.3f s (want %.3f)" % [r["air"], want_air])
	check(r["airborne_seen"], "is_airborne() true in the air")
	check(absf(p.global_position.y - y0) < 0.02, "lands back on the floor")
	print("  landing speed %.2f m/s (soft under %.0f)" % [r["land_speed"], Tuning.LAND_HARD_SPEED])
	check(r["land_speed"] < Tuning.LAND_HARD_SPEED, "a standing jump lands soft")
	await ticks(1)
	check(p.can_act() and not p.is_landing(), "a soft landing has no recovery: the player can act at once")
	await ticks(30)

	# A jump pressed just before landing (inside the buffer) fires on landing.
	press(&"jump")
	await ticks(1)
	release(&"jump")
	await wait_until(func() -> bool: return p.is_airborne() and p.velocity.y < -2.0, 240)
	await wait_until(func() -> bool: return p.global_position.y - y0 < 0.25, 240)
	press(&"jump")  # ~0.06 s before touching down
	await ticks(1)
	release(&"jump")
	var low := INF
	var again := false
	for i in 60:
		await get_tree().physics_frame
		var h := p.global_position.y - y0
		low = minf(low, h)
		if low < 0.02 and h > low + 0.1:
			again = true  # touched down and took off again (often on the same tick)
			break
	check(again, "a jump pressed just before landing fires on landing (buffered)")
	await wait_until(func() -> bool: return not p.is_airborne(), 240)
	await ticks(30)

	if not p.is_traversal_driving():
		# Air steering (Fighter's own movement): the stick steers up to JUMP_AIR_STEER x walk speed.
		var cap := Tuning.WALK_SPEED * Tuning.JUMP_AIR_STEER
		var x0 := p.global_position
		press(&"move_forward")
		press(&"jump")
		await ticks(1)
		release(&"jump")
		var top := 0.0
		await ticks(2)
		while p.is_airborne():
			top = maxf(top, _hspeed(p))
			await get_tree().physics_frame
		var drift := Vector2(p.global_position.x - x0.x, p.global_position.z - x0.z).length()
		release(&"move_forward")
		check(drift > 0.6 and drift <= 1.4, "standing jump, stick held: drift %.2f m (<= 1.4)" % drift)
		check(top <= cap * 1.01, "standing jump air speed %.2f m/s (cap %.2f)" % [top, cap])
		await wait_until(func() -> bool: return p.velocity.length() < 0.01 and p.can_act(), 240)
		await ticks(20)
	else:
		print("  NOTE Traversal drives the jump; air steering is Traversal's")

	# Running jump: horizontal velocity kept exactly.
	press(&"move_forward")
	await ticks(60)  # full walk speed
	var v0 := _hspeed(p)
	var r0 := p.global_position
	var t0 := TimeDirector.now()
	press(&"jump")
	await ticks(1)
	release(&"jump")
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
	check(near(lo, v0, 0.02) and hi <= v0 * 1.01, "running jump keeps its speed (%.2f..%.2f m/s, take-off %.2f)" % [lo, hi, v0])
	check(near(run_dist, v0 * air, 0.06), "running jump covers %.2f m (v x air time %.2f)" % [run_dist, v0 * air])
	await wait_until(func() -> bool: return p.velocity.length() < 0.01 and p.can_act(), 240)
	await ticks(20)

	# Jump from a crouch: stands up, takes off.
	press(&"crouch")
	await ticks(3)
	check(p.is_crouching(), "crouching before the jump")
	press(&"jump")
	await ticks(2)
	release(&"jump")
	check(p.is_airborne() and not p.is_crouching(), "jump from a crouch stands up and leaves the floor")
	await wait_until(func() -> bool: return not p.is_airborne(), 240)
	await ticks(3)
	check(p.is_crouching(), "still holding crouch: ducks again after landing")
	release(&"crouch")
	await ticks(5)
	done()

func _hspeed(p: Fighter) -> float:
	return Vector2(p.velocity.x, p.velocity.z).length()

## Press jump once; track apex, real air time and the landing speed.
func _jump_once(p: Fighter) -> Dictionary:
	var base := p.global_position.y
	var apex := 0.0
	var seen := false
	var t0 := TimeDirector.now()
	var t_land := -1.0
	var vy_last := 0.0
	var prev_y := base
	press(&"jump")
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
	release(&"jump")
	return {"apex": apex, "air": t_land - t0 if t_land > 0.0 else 0.0, "airborne_seen": seen, "land_speed": absf(vy_last)}
