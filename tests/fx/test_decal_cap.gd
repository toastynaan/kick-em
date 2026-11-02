extends Node3D
## Round 5 decal budget (Feel Reference: Budget, Things stay): 400 splat
## requests never leave more than Tuning.BLOOD_DECAL_MAX blood decals that are
## not fading (the oldest fade first, the newest stays); floor cracks have
## their own cap (BloodFX.MARK_DECAL_MAX) and never evict blood; the counts
## J's end-of-wave check reads add up (created = live + fading + evicted +
## released); world decals skip the character render layer; reset() clears
## everything. OWNER: agent F.

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
	var max_live := 0
	var max_total := 0
	for i in 400:
		var p := Vector3(r.randf_range(-15, 15), r.randf_range(0.6, 1.6), r.randf_range(-15, 15))
		BloodFX.splat(p, Vector3(r.randf_range(-1, 1), -0.3, r.randf_range(-1, 1)), r.randf_range(800, 9000))
		if i % 20 == 19:
			await get_tree().physics_frame
			var c := BloodFX.get_decal_counts()
			max_live = maxi(max_live, c["blood"])
			max_total = maxi(max_total, BloodFX.decal_count())
	await U.drain(get_tree())
	var c0 := BloodFX.get_decal_counts()
	max_live = maxi(max_live, c0["blood"])
	print("after 400 splats: %s (max live blood %d, max on screen %d, cap %d)" % [c0, max_live, max_total,
		Tuning.BLOOD_DECAL_MAX])
	if max_live > Tuning.BLOOD_DECAL_MAX:
		fails.append("live blood decals exceeded the cap: %d" % max_live)
	if max_total > Tuning.BLOOD_DECAL_MAX + BloodFX.FADE_SLACK:
		fails.append("decals on screen (incl. fading) exceeded cap + slack: %d" % max_total)
	if c0["blood"] < Tuning.BLOOD_DECAL_MAX:
		fails.append("cap never reached (%d); test did not stress it" % c0["blood"])
	_check_sum(c0, fails)

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

	# Fades finish: exactly the cap stays, nothing fading.
	await get_tree().create_timer(BloodFX.DECAL_FADE_TIME + 0.3).timeout
	var c1 := BloodFX.get_decal_counts()
	print("after fades: %s" % [c1])
	if c1["blood"] != Tuning.BLOOD_DECAL_MAX or c1["fading"] != 0 or BloodFX.decal_count() != Tuning.BLOOD_DECAL_MAX:
		fails.append("after fades: %d live, %d fading, %d on screen" % [c1["blood"], c1["fading"], BloodFX.decal_count()])
	_check_sum(c1, fails)

	# The newest decal survives a further burst; the oldest goes. Decal nodes are
	# pooled, so compare positions, not identities.
	var newest: Decal = BloodFX.get_decals().back()
	var oldest: Decal = BloodFX.get_decals().front()
	var newest_pos := newest.global_position
	var oldest_pos := oldest.global_position
	for i in 6:
		BloodFX.splat(Vector3(r.randf_range(-15, 15), 1.0, r.randf_range(-15, 15)), Vector3.DOWN, 900.0)
	await U.drain(get_tree())
	await get_tree().create_timer(BloodFX.DECAL_FADE_TIME + 0.3).timeout
	var live := BloodFX.get_decals()
	if not (live.has(newest) and newest.global_position == newest_pos):
		fails.append("newest decal was evicted")
	if live.has(oldest) and oldest.global_position == oldest_pos:
		fails.append("oldest decal survived")

	# Floor cracks: their own cap, and they never push blood out.
	var blood_before: int = BloodFX.get_decal_counts()["blood"]
	for i in 40:
		BloodFX.crack(Vector3(r.randf_range(-15, 15), 0.5, r.randf_range(-15, 15)))
		if i % 8 == 7:
			await get_tree().physics_frame
	await U.drain(get_tree())
	await get_tree().create_timer(BloodFX.DECAL_FADE_TIME + 0.3).timeout
	var c2 := BloodFX.get_decal_counts()
	print("after 40 cracks: %s" % [c2])
	if c2["marks"] != BloodFX.MARK_DECAL_MAX:
		fails.append("marks %d, want the cap %d" % [c2["marks"], BloodFX.MARK_DECAL_MAX])
	if c2["blood"] != blood_before:
		fails.append("cracks evicted blood decals (%d -> %d)" % [blood_before, c2["blood"]])
	_check_sum(c2, fails)

	BloodFX.reset()
	if BloodFX.decal_count() != 0 or BloodFX.get_decal_counts()["created"] != 0:
		fails.append("reset() left %d decals / counts %s" % [BloodFX.decal_count(), BloodFX.get_decal_counts()])
	U.finish(get_tree(), "test_decal_cap", fails, errlog)

func _check_sum(c: Dictionary, fails: Array[String]) -> void:
	var sum: int = c["live"] + c["fading"] + c["evicted"] + c["released"]
	if sum != c["created"]:
		fails.append("decal counts do not add up: %s" % [c])
