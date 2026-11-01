extends Node3D
## 20 random launches in a row (2-16 m/s, random directions, some into a
## wall): every one must reach ANIMATED again within 8 s of game time, with
## no NaN or explosion. Also checks the landed/grounded/recovered signals and
## that relaunching mid-flight adds velocity.

const LAUNCHES := 20
const MAX_TIME := 8.0

var _signals := {}

func _ready() -> void:
	get_tree().create_timer(LAUNCHES * MAX_TIME + 30.0).timeout.connect(func() -> void:
		print("LAUNCH_RECOVER FAIL (timeout)")
		get_tree().quit(1))
	RigTestUtil.make_floor(self, 200.0)
	var wall := RigTestUtil.make_wall(self, Vector3(0, 2, -6), Vector3(12, 4, 0.5))
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var d := RigTestUtil.make_dummy(self, &"player", Vector3.ZERO, null, true)
	for s in ["launched", "landed", "grounded", "recovered"]:
		_signals[s] = 0
		if s == "launched":
			d.ragdoll.launched.connect(func(_v: Vector3) -> void: _signals["launched"] += 1)
		else:
			d.ragdoll.connect(s, _count.bind(s))
	for i in 3:
		await get_tree().physics_frame
	var ok := true
	var worst := 0.0
	var max_speed := 0.0
	for n in LAUNCHES:
		var into_wall := n % 4 == 0
		var speed := rng.randf_range(2.0, 16.0)
		var dir: Vector3
		if into_wall:
			# Stand 3 m in front of the wall and fly into it.
			d.global_position = Vector3(rng.randf_range(-3, 3), 0, -3.0)
			d.reset_physics_interpolation()
			dir = Vector3(rng.randf_range(-0.3, 0.3), 0, -1).normalized()
		else:
			d.global_position = Vector3(rng.randf_range(-20, 20), 0, rng.randf_range(5, 30))
			d.reset_physics_interpolation()
			var a := rng.randf_range(0, TAU)
			dir = Vector3(cos(a), 0, sin(a))
		await get_tree().physics_frame
		await get_tree().physics_frame
		var up := deg_to_rad(rng.randf_range(0.0, 35.0))
		var v := (dir * cos(up) + Vector3.UP * sin(up)) * speed
		var bone: StringName = [Bones.CHEST, Bones.HEAD, Bones.HIPS, Bones.L_LOWER_LEG, Bones.R_HAND][n % 5]
		d.ragdoll.launch(v, d.rig.get_bone_global_position(bone), bone)
		if n % 7 == 3:
			for f in 20:
				await get_tree().physics_frame
			var before := d.ragdoll.get_com_velocity()
			d.ragdoll.launch(Vector3(0, 4, 0), d.ragdoll.get_center_of_mass(), Bones.CHEST)
			var after := d.ragdoll.get_com_velocity()
			print("  relaunch: com vy %.2f -> %.2f" % [before.y, after.y])
			ok = ok and after.y > before.y + 3.0
		var t := 0.0
		var nan := false
		while d.ragdoll.state != RagdollController.State.ANIMATED and t < MAX_TIME:
			await get_tree().physics_frame
			t += 1.0 / 120.0
			if d.ragdoll.is_full_ragdoll():
				max_speed = maxf(max_speed, RigTestUtil.max_bone_speed(d.ragdoll))
				nan = nan or RigTestUtil.has_nan(d.ragdoll)
		var recovered := d.ragdoll.state == RagdollController.State.ANIMATED
		worst = maxf(worst, t)
		print("  launch %2d v=%5.1f m/s %s bone=%s -> %s in %.2f s" % [n, speed, "WALL" if into_wall else "open", bone,
			"recovered" if recovered else "STUCK state=%d" % d.ragdoll.state, t])
		ok = ok and recovered and not nan
		# Stand a moment between launches.
		for f in 24:
			await get_tree().physics_frame
	ok = ok and max_speed < 60.0
	ok = ok and _signals["recovered"] == LAUNCHES and _signals["grounded"] == LAUNCHES and _signals["landed"] >= LAUNCHES
	print("worst recovery %.2f s, max bone speed %.1f m/s, signals %s" % [worst, max_speed, _signals])
	print("LAUNCH_RECOVER ", "PASS" if ok else "FAIL")
	wall.queue_free()
	get_tree().quit(0 if ok else 1)

func _count(sig_name: String) -> void:
	_signals[sig_name] += 1
