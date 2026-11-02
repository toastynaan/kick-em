extends "res://tests/input/input_test_base.gd"
## Jump (Space): apex Tuning.JUMP_APEX and air time Tuning.JUMP_AIR_TIME within
## 5%, jumped / landed events, is_airborne(), landing recovery of
## Tuning.JUMP_LAND_FRAMES (cannot act, then can), air steering capped at
## Tuning.JUMP_AIR_STEER x walk speed (a standing hop drifts <= 1.4 m, a running
## jump keeps its take-off speed), and a jump while crouched stands up first.

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	await ticks(40)
	check(p.is_on_floor(), "player starts on the floor")
	var y0 := p.global_position.y

	var r := await _jump_once(p)
	check(near(r["apex"], Tuning.JUMP_APEX, 0.05), "apex %.3f m (Tuning %.2f)" % [r["apex"], Tuning.JUMP_APEX])
	check(near(r["air"], Tuning.JUMP_AIR_TIME, 0.05), "air time %.3f s (Tuning %.2f)" % [r["air"], Tuning.JUMP_AIR_TIME])
	check(r["airborne_seen"], "is_airborne() true in the air")
	check(count_events(&"jumped") == 1 and count_events(&"landed") == 1, "one jumped and one landed event")
	check(absf(p.global_position.y - y0) < 0.02, "lands back on the floor")

	# Landing recovery: cannot act for JUMP_LAND_FRAMES, then can.
	var rec := Tuning.frames(Tuning.JUMP_LAND_FRAMES)
	check(not p.can_act() and p.is_landing(), "landing recovery right after landing")
	var t_land := TimeDirector.now()
	await wait_until(func() -> bool: return p.can_act(), 120)
	var rec_measured := TimeDirector.now() - t_land
	check(absf(rec_measured - rec) <= 1.5 / 120.0, "landing recovery %.3f s (want %.3f)" % [rec_measured, rec])
	await ticks(30)

	# A jump pressed during the landing recovery waits for it (jump buffer).
	clear_events()
	press(&"jump")
	await ticks(1)
	release(&"jump")
	await wait_until(func() -> bool: return count_events(&"landed") > 0, 240)
	await ticks(4)
	press(&"jump")
	await ticks(1)
	release(&"jump")
	check(not p.is_airborne() and p.is_landing(), "no jump during landing recovery")
	await wait_until(func() -> bool: return p.is_airborne(), 30)
	check(p.is_airborne(), "the buffered jump fires when the recovery ends")
	await wait_until(func() -> bool: return not p.is_airborne(), 240)
	await ticks(30)

	# Air steering, standing jump: the stick steers up to JUMP_AIR_STEER x walk speed.
	var cap := Tuning.WALK_SPEED * Tuning.JUMP_AIR_STEER
	var x0 := p.global_position
	press(&"move_forward")
	press(&"jump")
	await ticks(1)
	release(&"jump")
	var top := 0.0
	while p.is_airborne():
		top = maxf(top, _hspeed(p))
		await get_tree().physics_frame
	var drift := Vector2(p.global_position.x - x0.x, p.global_position.z - x0.z).length()
	release(&"move_forward")
	check(drift > 0.8 and drift <= 1.4, "standing jump, stick held: drift %.2f m (<= 1.4)" % drift)
	check(top <= cap * 1.01, "standing jump air speed %.2f m/s (cap %.2f)" % [top, cap])
	await wait_until(func() -> bool: return p.velocity.length() < 0.01 and p.can_act(), 240)
	await ticks(20)

	# Running jump: keeps its take-off speed with the stick held, and after
	# letting go of the stick mid-air, never goes faster.
	press(&"move_forward")
	await ticks(60)  # full walk speed
	var v0 := _hspeed(p)
	var r0 := p.global_position
	press(&"jump")
	await ticks(1)
	release(&"jump")
	var lo := INF
	var hi := 0.0
	var n := 0
	while p.is_airborne():
		lo = minf(lo, _hspeed(p))
		hi = maxf(hi, _hspeed(p))
		n += 1
		if n == 36:
			release(&"move_forward")  # stick let go at the apex
		await get_tree().physics_frame
	release(&"move_forward")
	var run_dist := Vector2(p.global_position.x - r0.x, p.global_position.z - r0.z).length()
	check(near(v0, Tuning.WALK_SPEED, 0.02), "running at %.2f m/s before the jump" % v0)
	check(near(lo, v0, 0.02) and hi <= v0 * 1.01, "running jump keeps its take-off speed (%.2f..%.2f m/s)" % [lo, hi])
	check(near(run_dist, v0 * Tuning.JUMP_AIR_TIME, 0.05), "running jump covers %.2f m (want %.2f)" % [run_dist, v0 * Tuning.JUMP_AIR_TIME])
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

## Press jump once; track apex and air time (real seconds, from the event
## stamps) until landing.
func _jump_once(p: Fighter) -> Dictionary:
	clear_events()
	var base := p.global_position.y
	var apex := 0.0
	var seen := false
	press(&"jump")
	for i in 400:
		await get_tree().physics_frame
		if p.is_airborne():
			seen = true
		apex = maxf(apex, p.global_position.y - base)
		if count_events(&"landed") > 0:
			break
	release(&"jump")
	var j := last_event(&"jumped")
	var l := last_event(&"landed")
	var air: float = l[4] - j[4] if not j.is_empty() and not l.is_empty() else 0.0
	return {"apex": apex, "air": air, "airborne_seen": seen}
