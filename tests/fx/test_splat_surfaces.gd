extends Node3D
## Splat rays put decals on a wall and on the floor, flush with each surface and
## facing out of it; decals on a breakable panel are its children and go when
## it breaks; smears stretch along the velocity; pools grow. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")
const WALL_FACE_Z := -1.9  # wall centre z = -2.0, thickness 0.2

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	BloodFX.rng.seed = 3
	U.make_floor(self)
	var wall := U.make_box(self, Vector3(0, 1.5, -2.0), Vector3(6, 3, 0.2), Layers.DESTRUCTIBLE)
	wall.add_to_group(&"destructibles")
	await U.physics_frames(get_tree(), 2)

	BloodFX.splat(Vector3(0, 1.3, 0), Vector3(0, 0, -1), 6000.0)
	await U.drain(get_tree())
	var on_wall := 0
	var on_floor := 0
	for d: Decal in BloodFX.get_decals():
		var up := d.global_basis.y.normalized()
		var p := d.global_position
		if U.near(p.z, WALL_FACE_Z, 0.02) and up.dot(Vector3.BACK) > 0.99:
			on_wall += 1
			if d.get_parent() != wall:
				fails.append("wall decal not parented to the breakable panel")
		elif U.near(p.y, 0.0, 0.02) and up.dot(Vector3.UP) > 0.99:
			on_floor += 1
		else:
			fails.append("decal not on a surface: pos %s up %s" % [p, up])
	print("splat: %d on wall, %d on floor" % [on_wall, on_floor])
	if on_wall == 0:
		fails.append("no decal on the wall")
	if on_floor == 0:
		fails.append("no decal on the floor")
	var total := on_wall + on_floor
	if total < 3 or total > 6:
		fails.append("expected 3-6 decals from one splat, got %d" % total)

	# A panel that is fully gone (is_broken) takes all its decals with it.
	# (Partial holes: test_partial_break.)
	wall.set_script(preload("res://tests/fx/fx_fake_panel.gd"))
	wall.is_broken = true
	GameEvents.wall_broken.emit(wall, Vector3(0, 1.3, WALL_FACE_Z), 3000.0, Vector3(0, 0, -10))
	var left_on_wall := 0
	for d: Decal in BloodFX.get_decals():
		if d.get_parent() == wall:
			left_on_wall += 1
	if left_on_wall > 0:
		fails.append("%d decals stayed on the broken panel" % left_on_wall)
	wall.queue_free()
	await U.drain(get_tree())

	# A scripted break (no flying body) leaves dust only; a body through the
	# wall leaves floor smears on both sides of the hole.
	BloodFX.reset()
	var hole := Vector3(-6, 1.2, -2.0)
	GameEvents.wall_broken.emit(null, hole, 4000.0, Vector3(0, 0, -10))
	await U.drain(get_tree())
	if BloodFX.decal_count() != 0:
		fails.append("scripted wall break left %d blood decals" % BloodFX.decal_count())
	var flyer := U.make_fighter(self, hole + Vector3(0, -1.0, 0.8), false)
	flyer.add_to_group(&"fighters")
	flyer.launched = true
	GameEvents.wall_broken.emit(null, hole, 4000.0, Vector3(0, 0, -10))
	await U.drain(get_tree())
	var front := 0
	var back := 0
	for d: Decal in BloodFX.get_decals():
		if U.near(d.global_position.y, 0.0, 0.02):
			if d.global_position.z > hole.z:
				front += 1
			else:
				back += 1
	print("body through wall: %d floor marks in front, %d behind" % [front, back])
	if front == 0 or back == 0:
		fails.append("no smears on both sides of the hole (%d / %d)" % [front, back])
	flyer.queue_free()

	# Smear: on a static wall, long axis along the body's velocity.
	BloodFX.reset()
	var wall2 := U.make_box(self, Vector3(4, 1.5, 0), Vector3(0.2, 3, 6), Layers.WORLD)
	await U.physics_frames(get_tree(), 2)
	BloodFX.smear(Vector3(3.9, 1.2, 0), Vector3(-1, 0, 0), Vector3(6, -1, 4), 4000.0)
	await U.drain(get_tree())
	var smears := BloodFX.get_decals()
	if smears.size() != 1:
		fails.append("smear made %d decals" % smears.size())
	else:
		var s: Decal = smears[0]
		var x_axis := s.global_basis.x.normalized()
		var tangent := Vector3(0, -1, 4).normalized()
		print("smear at %s size %s axis %s" % [s.global_position, s.size, x_axis])
		if not U.near(s.global_position.x, 3.9, 0.02):
			fails.append("smear not on the wall face")
		if x_axis.dot(tangent) < 0.98:
			fails.append("smear not stretched along the velocity")
		if s.size.x <= s.size.z:
			fails.append("smear not elongated")
		if s.get_parent() == wall2:
			fails.append("smear parented to a non-breakable wall")

	# Pool grows from small toward its full size.
	BloodFX.reset()
	BloodFX.pool(Vector3(-3, 1.0, 3), 1.2)
	await U.drain(get_tree())
	var pools := BloodFX.get_decals()
	if pools.size() != 1:
		fails.append("pool made %d decals" % pools.size())
	else:
		var pd: Decal = pools[0]
		var s0 := pd.size.x
		await get_tree().create_timer(1.0).timeout
		var s1 := pd.size.x
		print("pool size %.2f -> %.2f after 1 s" % [s0, s1])
		if not (s0 < 0.2 and s1 > s0 + 0.3):
			fails.append("pool did not grow (%.2f -> %.2f)" % [s0, s1])
		if not U.near(pd.global_position.y, 0.0, 0.02):
			fails.append("pool not on the floor")

	U.finish(get_tree(), "test_splat_surfaces", fails, errlog)
