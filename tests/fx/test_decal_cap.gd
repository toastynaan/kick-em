extends Node3D
## 400 splat requests on a floor leave at most Tuning.DECAL_MAX decals; the
## oldest fade first; world decals skip the character render layer; reset()
## clears everything. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	BloodFX.rng.seed = 7
	U.make_floor(self)
	await U.physics_frames(get_tree(), 2)

	var r := RandomNumberGenerator.new()
	r.seed = 11
	var max_seen := 0
	for i in 400:
		var p := Vector3(r.randf_range(-15, 15), r.randf_range(0.6, 1.6), r.randf_range(-15, 15))
		BloodFX.splat(p, Vector3(r.randf_range(-1, 1), -0.3, r.randf_range(-1, 1)), r.randf_range(800, 9000))
		if i % 20 == 19:
			await get_tree().physics_frame
			max_seen = maxi(max_seen, BloodFX.decal_count())
	await U.drain(get_tree())
	max_seen = maxi(max_seen, BloodFX.decal_count())
	var count := BloodFX.decal_count()
	print("decals after 400 splats: %d (max seen %d, cap %d)" % [count, max_seen, Tuning.DECAL_MAX])
	if max_seen > Tuning.DECAL_MAX:
		fails.append("decal count exceeded the cap: %d" % max_seen)
	if count < Tuning.DECAL_MAX - 64:
		fails.append("cap never reached (%d); test did not stress it" % count)

	# Every decal is on a surface of the floor and leaves fighters alone.
	for d: Decal in BloodFX.get_decals():
		if d.cull_mask & Layers.VIS_CHARACTERS:
			fails.append("decal cull mask includes VIS_CHARACTERS")
			break
		if not U.near(d.global_position.y, 0.0, 0.02):
			fails.append("decal off the floor at %s" % d.global_position)
			break
		if d.size.y > 0.5:
			fails.append("projection depth too long: %.2f" % d.size.y)
			break

	# Oldest fade first: after the fade time the count drops under the soft cap.
	await get_tree().create_timer(BloodFX.DECAL_FADE_TIME + 0.3).timeout
	var settled := BloodFX.decal_count()
	print("decals after fades: %d (soft cap %d)" % [settled, Tuning.DECAL_MAX - BloodFX.DECAL_SOFT_MARGIN])
	if settled > Tuning.DECAL_MAX - BloodFX.DECAL_SOFT_MARGIN:
		fails.append("oldest decals did not fade: %d" % settled)

	# The newest decal survives a further burst; the oldest goes.
	# Decal nodes are pooled, so a recycled node may come back elsewhere: compare
	# positions, not identities.
	var newest: Decal = BloodFX.get_decals().back()
	var oldest: Decal = BloodFX.get_decals().front()
	var newest_pos := newest.global_position
	var oldest_pos := oldest.global_position
	for i in 30:
		BloodFX.splat(Vector3(r.randf_range(-15, 15), 1.0, r.randf_range(-15, 15)), Vector3.DOWN, 3000.0)
	await U.drain(get_tree())
	await get_tree().create_timer(BloodFX.DECAL_FADE_TIME + 0.3).timeout
	var live := BloodFX.get_decals()
	if not (live.has(newest) and newest.global_position == newest_pos):
		fails.append("newest decal was evicted")
	if live.has(oldest) and oldest.global_position == oldest_pos:
		fails.append("oldest decal survived")

	BloodFX.reset()
	if BloodFX.decal_count() != 0:
		fails.append("reset() left %d decals" % BloodFX.decal_count())
	U.finish(get_tree(), "test_decal_cap", fails, errlog)
