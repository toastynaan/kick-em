extends Node3D
## Get-up takes ~0.8 s (GETUP entered -> recovered) and stays readable: the
## hips rise steadily through it. Covers both face-up and face-down get-ups.
## Also checks that get_bounds() encloses every collision shape in flight
## (agent D's resolver sweeps it).

func _ready() -> void:
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("GETUP FAIL (timeout)")
		get_tree().quit(1))
	RigTestUtil.make_floor(self, 200.0)
	var d := RigTestUtil.make_dummy(self, &"brute", Vector3.ZERO, null, true)
	for i in 4:
		await get_tree().physics_frame
	var rc := d.ragdoll
	var ok := true
	var kinds := {}
	var worst_bounds_gap := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for n in 8:
		var a := rng.randf_range(0, TAU)
		rc.launch(Vector3(cos(a), 0.3, sin(a)) * rng.randf_range(4, 10), d.global_position, Bones.CHEST)
		var t := 0
		while rc.state != RagdollController.State.GETUP and t < 1200:
			await get_tree().physics_frame
			t += 1
			if rc.state == RagdollController.State.LAUNCHED and t % 6 == 0:
				var box := rc.get_bounds()
				for pb in d.rig.get_physical_bones():
					for pt in _shape_extremes(pb.get_node("Shape") as CollisionShape3D):
						if not box.has_point(pt):
							var c := pt.clamp(box.position, box.end)
							worst_bounds_gap = maxf(worst_bounds_gap, pt.distance_to(c))
		if rc.state != RagdollController.State.GETUP:
			print("  launch %d never reached GETUP" % n)
			ok = false
			continue
		var kind: StringName = rc._getup_move
		kinds[kind] = true
		var start_hips := d.rig.get_bone_global_position(Bones.HIPS).y
		var heights: Array[float] = []
		var frames := 0
		while rc.state == RagdollController.State.GETUP and frames < 600:
			await get_tree().physics_frame
			frames += 1
			heights.append(d.rig.get_bone_global_position(Bones.HIPS).y)
		var dur := frames / 120.0
		var q1 := heights[int(heights.size() * 0.35)]
		var q3 := heights[int(heights.size() * 0.75)]
		var end_h := heights[heights.size() - 1]
		var rises := start_hips < q1 + 0.05 and q1 < q3 and q3 < end_h + 0.05 and end_h > 0.8 * d.rig.height_scale
		print("  %d %-16s get-up %.2f s, hips %.2f -> %.2f -> %.2f -> %.2f m" % [n, kind, dur, start_hips, q1, q3, end_h])
		ok = ok and absf(dur - 0.8) < 0.06 and rises and rc.state == RagdollController.State.ANIMATED
		for i in 20:
			await get_tree().physics_frame
	print("  get-up kinds seen: %s; bounds overshoot %.3f m" % [kinds.keys(), worst_bounds_gap])
	ok = ok and kinds.size() == 2 and worst_bounds_gap < 0.001
	print("GETUP ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)

## Exact extreme points of a shape in world space (box corners, capsule and
## sphere extents along the world axes).
func _shape_extremes(cs: CollisionShape3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var xf := cs.global_transform
	var axes := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	if cs.shape is BoxShape3D:
		var h := (cs.shape as BoxShape3D).size * 0.5
		for x in [-1, 1]:
			for y in [-1, 1]:
				for z in [-1, 1]:
					out.append(xf * Vector3(h.x * x, h.y * y, h.z * z))
	elif cs.shape is SphereShape3D:
		var r := (cs.shape as SphereShape3D).radius
		for a in axes:
			out.append(xf.origin + a * r)
			out.append(xf.origin - a * r)
	elif cs.shape is CapsuleShape3D:
		var c := cs.shape as CapsuleShape3D
		for e in [-1, 1]:
			var end := xf * Vector3(0, (c.height * 0.5 - c.radius) * e, 0)
			for a in axes:
				out.append(end + a * c.radius)
				out.append(end - a * c.radius)
	return out
