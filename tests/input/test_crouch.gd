extends "res://tests/input/input_test_base.gd"
## Crouch (hold C): capsule 1.8 m -> Tuning.CROUCH_HEIGHT, walk x
## Tuning.CROUCH_SPEED, crouch_changed events, block still works, standing up
## restores the capsule; a launch stands the body up; get_input_intent().

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	await ticks(30)
	var shape := p.capsule.shape as CapsuleShape3D
	check(near(shape.height, Fighter.CAPSULE_HEIGHT, 0.01), "standing capsule %.2f m" % shape.height)

	# Standing walk speed for reference.
	var walk := await _measure_speed(p)
	check(near(walk, Tuning.WALK_SPEED, 0.05), "standing walk %.2f m/s (Tuning %.2f)" % [walk, Tuning.WALK_SPEED])

	clear_events()
	press(&"crouch")
	await ticks(2)
	check(p.is_crouching(), "holding crouch -> is_crouching()")
	check(near(shape.height, Tuning.CROUCH_HEIGHT, 0.01), "crouch capsule %.2f m (Tuning %.2f)" % [shape.height, Tuning.CROUCH_HEIGHT])
	check(near(p.capsule.position.y, Tuning.CROUCH_HEIGHT * 0.5, 0.01), "crouch capsule sits on the floor")
	var ev := last_event(&"crouch_changed")
	check(not ev.is_empty() and ev[1] == p and ev[2] == true, "crouch_changed(player, true) emitted")

	var crouch_walk := await _measure_speed(p)
	var want := Tuning.WALK_SPEED * Tuning.CROUCH_SPEED
	check(near(crouch_walk, want, 0.05), "crouch walk %.2f m/s (want %.2f)" % [crouch_walk, want])
	check(p.is_on_floor(), "crouching fighter stays on the floor")

	press(&"block")
	await ticks(4)
	check(p.combat.is_blocking() and p.is_crouching(), "can block while crouching")
	release(&"block")
	await ticks(3)

	release(&"crouch")
	await ticks(2)
	check(not p.is_crouching(), "release crouch -> standing")
	check(near(shape.height, Fighter.CAPSULE_HEIGHT, 0.01), "capsule back to %.2f m" % shape.height)
	ev = last_event(&"crouch_changed")
	check(not ev.is_empty() and ev[2] == false, "crouch_changed(player, false) emitted")

	# A launch stands the body up (the capsule comes back at full height).
	press(&"crouch")
	await ticks(2)
	check(p.is_crouching(), "crouched again")
	p.launch(Vector3(0.0, 3.0, 4.0), p.get_center_of_mass(), Bones.CHEST)
	await ticks(2)
	check(not p.is_crouching() and near(shape.height, Fighter.CAPSULE_HEIGHT, 0.01), "launch ends the crouch")
	release(&"crouch")
	await wait_until(func() -> bool: return p.can_act(), 1200)
	await ticks(10)

	# Input intent (Round 5): the player's stick against the camera ("back" is
	# toward the camera: S), whatever way he faces; a fighter without a
	# PlayerController reads move_input against facing.
	var dummy := spawn_dummy(&"grunt", Vector3(0, 0, -30), Vector3.BACK)
	await ticks(2)
	for facing: Vector3 in [Vector3.FORWARD, Vector3.RIGHT, Vector3.BACK]:
		p.snap_facing(facing)
		press(&"move_forward")
		check(p.get_input_intent() == &"forward", "W -> forward (facing %s)" % facing)
		release(&"move_forward")
		press(&"move_back")
		check(p.get_input_intent() == &"back", "S -> back, toward the camera (facing %s)" % facing)
		press(&"move_right")
		check(p.get_input_intent() == &"back", "S + D (45 degrees) -> back (facing %s)" % facing)
		release(&"move_back")
		check(p.get_input_intent() == &"neutral", "D -> neutral (facing %s)" % facing)
		release(&"move_right")
		check(p.get_input_intent() == &"neutral", "no stick -> neutral")
	dummy.snap_facing(Vector3.FORWARD)
	dummy.move_input = Vector3.FORWARD
	check(dummy.get_input_intent() == &"forward", "no controller: move_input along facing -> forward")
	dummy.move_input = Vector3.BACK
	check(dummy.get_input_intent() == &"back", "no controller: move_input against facing -> back")
	dummy.move_input = Vector3.RIGHT
	check(dummy.get_input_intent() == &"neutral", "no controller: sideways -> neutral")
	dummy.move_input = Vector3.FORWARD * 0.1
	check(dummy.get_input_intent() == &"neutral", "no controller: tiny stick -> neutral")
	dummy.move_input = Vector3.ZERO
	dummy.queue_free()
	done()

## Hold W for a while and return the steady ground speed (m/s, real time).
func _measure_speed(p: Fighter) -> float:
	press(&"move_forward")
	await ticks(40)  # reach full speed
	var a := p.global_position
	await ticks(120)
	var b := p.global_position
	release(&"move_forward")
	await ticks(40)
	return Vector2(b.x - a.x, b.z - a.z).length()
