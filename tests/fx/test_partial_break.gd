extends Node3D
## Round 2, local fracture: a hole takes only the decals over open cells
## (Destructible.is_point_open), blood elsewhere on the panel stays, a fully
## broken panel takes the rest, panels without is_point_open fall back to a
## radius around the hole, and decals on a fracture cell body are parented to
## the panel above it. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")
const FakePanel := preload("res://tests/fx/fx_fake_panel.gd")
const FACE_Z := -1.9  # panel centre z -2.0, thickness 0.2

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	BloodFX.rng.seed = 21
	U.make_floor(self)

	# Panel A: the StaticBody3D is the Destructible (script attached to it).
	var a := U.make_box(self, Vector3(0, 1.5, -2.0), Vector3(8, 3, 0.2), Layers.DESTRUCTIBLE)
	a.set_script(FakePanel)
	a.add_to_group(&"destructibles")
	await U.physics_frames(get_tree(), 2)
	for x in [-2.5, -1.0, 1.0, 2.5]:
		BloodFX.splat(Vector3(x, 1.5, 0), Vector3(0, 0, -1), 5000.0)
	await U.drain(get_tree())
	var before := _on(a)
	print("panel A: %d decals" % before.size())
	if before.size() < 6:
		fails.append("too few wall decals to test (%d)" % before.size())

	# Hole 1 around x = -1.
	var hole := Vector3(-1.0, 1.5, FACE_Z)
	a.holes.append(hole)
	GameEvents.wall_broken.emit(a, hole, 3000.0, Vector3(0, 0, -10))
	var after := _on(a)
	var inside_left := 0
	for d: Decal in after:
		if a.is_point_open(d.global_position):
			inside_left += 1
	var removed := before.size() - after.size()
	print("hole 1: removed %d, kept %d, kept-but-open %d" % [removed, after.size(), inside_left])
	if removed == 0:
		fails.append("hole 1 removed nothing")
	if after.is_empty():
		fails.append("hole 1 removed every decal on the panel")
	if inside_left > 0:
		fails.append("%d decals left over the open cells" % inside_left)
	for d: Decal in before:
		if not after.has(d) and not a.is_point_open(d.global_position) and d.get_parent() == a:
			fails.append("a decal over a solid cell was removed")
			break

	# Blood still lands on the remaining cells and is parented to the panel.
	BloodFX.splat(Vector3(2.5, 1.5, 0), Vector3(0, 0, -1), 5000.0)
	await U.drain(get_tree())
	if _on(a).size() <= after.size():
		fails.append("new splats did not land on the holed panel")

	# Hole 2 around x = +2.5, then the whole panel goes.
	var hole2 := Vector3(2.5, 1.5, FACE_Z)
	a.holes.append(hole2)
	GameEvents.wall_broken.emit(a, hole2, 3000.0, Vector3(0, 0, -10))
	for d: Decal in _on(a):
		if a.is_point_open(d.global_position):
			fails.append("hole 2 left a decal over an open cell")
			break
	var kept2 := _on(a).size()
	a.is_broken = true
	GameEvents.wall_broken.emit(a, Vector3(0, 1.5, FACE_Z), 3000.0, Vector3(0, 0, -10))
	print("hole 2 kept %d; fully broken kept %d" % [kept2, _on(a).size()])
	if not _on(a).is_empty():
		fails.append("fully broken panel kept %d decals" % _on(a).size())
	a.queue_free()
	await U.physics_frames(get_tree(), 2)

	# Panel B: a plain breakable without is_point_open, built as a parent node
	# with one cell body: decals go to the parent, and a hole falls back to a radius.
	BloodFX.reset()
	var b := Node3D.new()
	b.name = "PanelB"
	b.add_to_group(&"destructibles")
	add_child(b)
	U.make_box(b, Vector3(0, 1.5, -2.0), Vector3(8, 3, 0.2), Layers.DESTRUCTIBLE)
	await U.physics_frames(get_tree(), 2)
	for x in [-2.5, 0.0, 2.5]:
		BloodFX.splat(Vector3(x, 1.5, 0), Vector3(0, 0, -1), 5000.0)
	await U.drain(get_tree())
	var on_b := _on(b)
	print("panel B (cell child): %d decals parented to the panel" % on_b.size())
	if on_b.is_empty():
		fails.append("decals on a cell body were not parented to the panel")
	var hole_b := Vector3(0, 1.5, FACE_Z)
	GameEvents.wall_broken.emit(b, hole_b, 3000.0, Vector3(0, 0, -10))
	var near_left := 0
	var far_kept := 0
	for d: Decal in _on(b):
		if d.global_position.distance_to(hole_b) < BloodFX.HOLE_FALLBACK_RADIUS:
			near_left += 1
		else:
			far_kept += 1
	print("fallback radius: %d near kept (want 0), %d far kept" % [near_left, far_kept])
	if near_left > 0:
		fails.append("fallback left decals within the hole radius")
	if far_kept == 0:
		fails.append("fallback removed decals far from the hole")
	b.queue_free()

	# Integration: agent D's real Destructible with local fracture (break_hole).
	BloodFX.reset()
	var script: Script = load("res://scripts/world/destructible.gd")
	var real: Node3D = script.new() if script != null else null
	if real == null or not real.has_method(&"break_hole") or not real.has_method(&"is_point_open"):
		print("note: Destructible.break_hole / is_point_open not available; skipped real panel")
		if real != null:
			real.free()
	else:
		real.set(&"surface", &"drywall")
		real.set(&"size", Vector3(4, 3, 0.25))
		add_child(real)
		real.global_position = Vector3(0, 1.5, -2.0)
		await U.physics_frames(get_tree(), 3)
		for x in [-1.4, -0.5, 0.5, 1.4]:
			BloodFX.splat(Vector3(x, 1.5, 0), Vector3(0, 0, -1), 5000.0)
		await U.drain(get_tree())
		var before_r := _on(real)
		real.call(&"break_hole", Vector3(0.5, 1.5, -1.875), Vector3(0, 0, -10), Rect2(0.1, -0.5, 0.8, 1.0))
		var after_r := _on(real)
		var open_left := 0
		for d: Decal in after_r:
			if real.call(&"is_point_open", d.global_position):
				open_left += 1
		var fully: bool = real.get(&"is_broken")
		print("real panel: %d decals, hole removed %d, kept %d, kept-but-open %d, fully broken %s" % [
			before_r.size(), before_r.size() - after_r.size(), after_r.size(), open_left, fully])
		if before_r.is_empty():
			fails.append("no decals landed on the real panel")
		if open_left > 0:
			fails.append("real panel: %d decals left over open cells" % open_left)
		if not fully and after_r.is_empty():
			fails.append("real panel: a local hole removed every decal")
	U.finish(get_tree(), "test_partial_break", fails, errlog)

func _on(panel: Node) -> Array[Decal]:
	var out: Array[Decal] = []
	for d: Decal in BloodFX.get_decals():
		if d.get_parent() == panel:
			out.append(d)
	return out
