extends Node3D
## Local fracture (round 2): a 13 m/s body through the centre of a drywall
## panel removes 3-8 cells (a body-sized hole), the panel is not marked broken
## and the body ends past the wall; a second 13 m/s body through the same hole
## triggers no new decision and also ends past the wall; a hit 1.2 m away
## decides fresh; is_point_open() reports the hole; cells that lose every
## supported side fall; cracks are local and accumulate.

var _use_fake := false
var _decisions: Array = []
var _ok := true

func _ready() -> void:
	ImpactResolver.wall_decided.connect(func(f: Node3D, w: Node3D, outcome: StringName, e: float, _p: Vector3) -> void:
		_decisions.append({"fighter": f, "wall": w, "outcome": outcome, "energy": e}))
	WorldTestUtil.make_floor(self)
	await get_tree().physics_frame
	_use_fake = not await WorldTestUtil.real_ragdoll_available(self)
	print("[partial] ragdoll: ", "TEST STAND-IN" if _use_fake else "real RagdollController")

	# 1. Centre hit.
	var panel := WorldTestUtil.make_panel(self, &"drywall")
	await get_tree().physics_frame
	var cells := panel.get_cell_count()
	var r := await _fly(panel, 0.0)
	var removed := panel.last_removed.size()
	var c_ok: bool = r["outcome"] == &"break" and removed >= 3 and removed <= 8 and not panel.is_broken and r["past"] > 0.5
	print("[partial] centre 13 m/s: %s E=%.0f removed %d of %d cells, panel broken=%s, body %.2f m past the face -> %s" % [
		r["outcome"], r["energy"], removed, cells, panel.is_broken, r["past"], _pf(c_ok)])
	_ok = _ok and c_ok
	var hole_pt := panel.global_transform * Vector3(0.0, -0.45, 0.0)
	var corner := panel.global_transform * Vector3(1.35, 1.35, 0.0)
	var open_ok := panel.is_point_open(hole_pt) and not panel.is_point_open(corner) \
		and not panel.is_point_open(panel.global_transform * Vector3(0, 0, 3.0))
	print("[partial] is_point_open: hole=%s corner=%s far off the face=%s -> %s" % [
		panel.is_point_open(hole_pt), panel.is_point_open(corner),
		panel.is_point_open(panel.global_transform * Vector3(0, 0, 3.0)), _pf(open_ok)])
	_ok = _ok and open_ok
	var cracks_after_hole := panel.get_crack_edge_count()

	# 2. Second body through the same hole: no decision, ends past the wall.
	WorldTestUtil.cleanup()
	await get_tree().physics_frame
	r = await _fly(panel, 0.0)
	var alive_before: int = panel.get_alive_count()
	var p_ok: bool = r["decisions"] == 0 and r["past"] > 0.5
	print("[partial] second 13 m/s through the hole: decisions=%d, body %.2f m past -> %s" % [
		r["decisions"], r["past"], _pf(p_ok)])
	_ok = _ok and p_ok

	# 3. A hit 1.2 m to the side decides fresh.
	WorldTestUtil.cleanup()
	await get_tree().physics_frame
	r = await _fly(panel, 1.2)
	var s_ok: bool = r["decisions"] >= 1
	print("[partial] hit 1.2 m to the side: decisions=%d first=%s E=%.0f cells left %d -> %d -> %s" % [
		r["decisions"], r["outcome"], r["energy"], alive_before, panel.get_alive_count(), _pf(s_ok)])
	_ok = _ok and s_ok
	panel.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

	# 4. Unsupported cells fall: cut the left, right and bottom bands; the rest
	#    (held only by the free top edge) must drop and the panel counts as broken.
	var p2 := WorldTestUtil.make_panel(self, &"brick", Vector3(0, 0, 12))
	await get_tree().physics_frame
	var n2 := p2.get_cell_count()
	var dropped_total := 0
	for rect: Rect2 in [Rect2(-1.5, -1.5, 0.45, 3.0), Rect2(1.05, -1.5, 0.45, 3.0), Rect2(-1.5, -1.5, 3.0, 0.45)]:
		if p2.is_broken:
			break
		p2.break_hole(p2.global_transform * Vector3(rect.get_center().x, rect.get_center().y, 0), Vector3(-3, 0, 0), rect)
		dropped_total += p2.last_removed.size()
	var u_ok := p2.is_broken and p2.get_alive_count() == 0 and dropped_total == n2
	print("[partial] cut left/right/bottom bands: removed %d of %d, broken=%s -> %s" % [dropped_total, n2, p2.is_broken, _pf(u_ok)])
	_ok = _ok and u_ok
	p2.queue_free()
	DebrisManager.reset()
	await get_tree().physics_frame

	# 5. Cracks are local and accumulate.
	var p3 := WorldTestUtil.make_panel(self, &"brick", Vector3(0, 0, -12))
	await get_tree().physics_frame
	var total := PanelFracture.get_set(&"brick", p3.size, p3.variant).edges.size()
	p3.receive_impact(3000.0, p3.global_transform * Vector3(-0.9, 0.6, 0.125), Vector3(-9, 0, 0))
	var first := p3.get_crack_edge_count()
	p3.receive_impact(3000.0, p3.global_transform * Vector3(0.9, -0.7, 0.125), Vector3(-9, 0, 0))
	var second := p3.get_crack_edge_count()
	var k_ok := first > 0 and first < total * 0.7 and second > first and not p3.is_broken
	print("[partial] cracks: after one hit %d of %d edges, after a second hit %d -> %s" % [first, total, second, _pf(k_ok)])
	_ok = _ok and k_ok
	print("[partial] cracks around the first hole: %d edges" % cracks_after_hole)

	print("[partial] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _pf(b: bool) -> String:
	return "PASS" if b else "FAIL"

## Launch a fresh 70 kg dummy at the panel (exterior face +X) at 13 m/s, offset
## `side` m along the panel; report the decisions for this panel.
func _fly(panel: Destructible, side: float) -> Dictionary:
	_decisions.clear()
	var face_x := panel.global_position.x + panel.size.z * 0.5
	var z := panel.global_position.z + side
	var f := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(face_x + 2.0, 0.05, z)), _use_fake)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var com := f.get_center_of_mass()
	f.global_position += Vector3(face_x + 2.0 - com.x, 0, z - com.z)
	f.reset_physics_interpolation()
	await get_tree().physics_frame
	f.launch(Vector3(-13, 1.8, 0), f.get_center_of_mass(), &"Chest")
	await WorldTestUtil.wait_game(self, 1.2)
	var mine := _decisions.filter(func(d: Dictionary) -> bool: return d["wall"] == panel and d["fighter"] == f)
	var res := {"decisions": mine.size(), "outcome": mine[0]["outcome"] if mine.size() > 0 else &"none",
		"energy": mine[0]["energy"] if mine.size() > 0 else -1.0}
	res["past"] = (panel.global_position.x - panel.size.z * 0.5) - f.get_center_of_mass().x
	f.queue_free()
	await get_tree().physics_frame
	return res
