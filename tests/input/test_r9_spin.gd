extends "res://tests/input/input_test_base.gd"
## Round 9 (agent H): Fighter.add_spin(rate) on a knockdown spins the ragdoll
## about its vertical axis (positive = counter-clockwise from above), and the
## body still falls. Measures the hips' yaw rate over the first 0.2 s, with no
## hitstop and with a hitstop on the hit (the spin then lands when it ends).

const RATE := 10.0
const WINDOW := 0.2

func _yaw(f: Fighter) -> float:
	var x := f.rig.get_physical_bone(Bones.HIPS).global_transform.basis.x
	return atan2(-x.z, x.x)

## Mean yaw rate (rad/s) over WINDOW s of physics, from now.
func _yaw_rate(f: Fighter) -> float:
	var t := 0.0
	var turned := 0.0
	var last := _yaw(f)
	while t < WINDOW - 1e-6:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		var y := _yaw(f)
		turned += wrapf(y - last, -PI, PI)
		last = y
	return turned / t

func _knock(f: Fighter, spin: float, hitstop: float) -> float:
	if hitstop > 0.0:
		f.freeze_hitstop(hitstop)
	f.knockdown(f.get_forward() * -1.0, Bones.CHEST)
	if spin != 0.0:
		f.add_spin(spin)
	await wait_until(func() -> bool: return not f.ragdoll.is_in_hitstop() and not f.is_frozen(), 120)
	return await _yaw_rate(f)

func run() -> void:
	var a := spawn_dummy(&"grunt", Vector3(-6, 0, 0), Vector3.FORWARD)
	var b := spawn_dummy(&"grunt", Vector3(0, 0, 0), Vector3.FORWARD)
	var c := spawn_dummy(&"grunt", Vector3(6, 0, 0), Vector3.FORWARD)
	await ticks(40)
	b.add_spin(RATE)  # animated: no effect
	await ticks(3)
	check(b.get_state() == RagdollController.State.ANIMATED and absf(b.global_rotation.y) < 0.05,
		"add_spin on an animated body does nothing")
	var h0 := b.get_center_of_mass().y
	var base := await _knock(a, 0.0, 0.0)
	var w := await _knock(b, RATE, 0.0)
	var wh := await _knock(c, -RATE, 0.1)
	print("  yaw rate over %.1f s: no spin %.2f, add_spin(%.0f) %.2f, add_spin(-%.0f) after a 0.1 s hitstop %.2f rad/s"
		% [WINDOW, base, RATE, w, RATE, wh])
	check(near(w, RATE, 0.3), "knockdown + add_spin(10): yaw rate %.2f rad/s (want 10 +-30%%)" % w)
	check(near(wh, -RATE, 0.3), "same tick as a hitstop hit: yaw rate %.2f rad/s (want -10 +-30%%)" % wh)
	await ticks(60)
	var h1 := b.get_center_of_mass().y
	print("  centre of mass height: %.2f m before, %.2f m 0.7 s after" % [h0, h1])
	check(b.is_down() and h1 < h0 - 0.3, "the spinning body still falls (%.2f -> %.2f m)" % [h0, h1])
	done()
