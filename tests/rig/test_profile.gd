extends Node3D
## Cost per character per physics frame: 4 bodies simulating with active
## muscles, then 4 passive, then 4 animated (walking). Measures the time
## spent in RagdollController._physics_process (torque loop + pose write +
## host follow) and the animator, plus the engine's physics step time.
## Prints the numbers (spec M1: "measured ms per ragdoll written down").

const N := 4
const FRAMES := 180

func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("PROFILE FAIL (timeout)")
		get_tree().quit(1))
	RigTestUtil.make_floor(self, 200.0)
	var results := {}
	# Baseline wall time per frame with no characters.
	var tb := Time.get_ticks_usec()
	for f in FRAMES:
		await get_tree().physics_frame
	var base_ms := (Time.get_ticks_usec() - tb) / 1000.0 / FRAMES
	print("baseline frame %.3f ms (no characters)" % base_ms)
	for mode in ["active", "passive", "animated"]:
		var ds: Array[LabDummy] = []
		for i in N:
			ds.append(RigTestUtil.make_dummy(self, &"player", Vector3(i * 3.0 - 4.5, 0, 0), null, mode == "active"))
		for i in 4:
			await get_tree().physics_frame
		for d in ds:
			d.ragdoll.auto_getup = false
			if mode == "animated":
				d.move_input = Vector3(0, 0, -1)
			else:
				d.ragdoll.launch(Vector3(0, 9, -3), d.global_position + Vector3.UP, Bones.CHEST)
		var ctrl_us := 0.0
		var anim_us := 0.0
		var frames := 0
		var tw := Time.get_ticks_usec()
		for f in FRAMES:
			await get_tree().physics_frame
			for d in ds:
				ctrl_us += d.ragdoll.last_tick_ms * 1000.0
			frames += 1
		var wall_ms := (Time.get_ticks_usec() - tw) / 1000.0 / FRAMES
		# Animator cost: time a direct evaluation.
		var t0 := Time.get_ticks_usec()
		for k in 200:
			ds[0].animator._evaluate(1.0 / 120.0)
		anim_us = (Time.get_ticks_usec() - t0) / 200.0
		var sim_count := 0
		for d in ds:
			if d.ragdoll.is_full_ragdoll():
				sim_count += 1
		results[mode] = [ctrl_us / frames / N / 1000.0, anim_us / 1000.0, (wall_ms - base_ms) / N, sim_count]
		print("%-8s controller script %.3f ms/char/frame, animator %.3f ms/char/frame, total incl. Jolt %.3f ms/char/frame (frame %.3f ms, %d chars, %d simulating)" % [
			mode, results[mode][0], results[mode][1], results[mode][2], wall_ms, N, sim_count])
		for d in ds:
			d.queue_free()
		for i in 3:
			await get_tree().physics_frame
	var ok: bool = results["active"][3] == N and results["passive"][3] == N
	print("PROFILE ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)
