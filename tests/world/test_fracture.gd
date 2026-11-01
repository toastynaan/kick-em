extends Node
## Fracture data: every wall surface yields 20-26 convex cells whose volumes sum
## to the panel volume within 5%; neighbours are symmetric and connected; every
## cell has a full-size static hull and an inset flying hull; cells touching
## the panel sides are tagged; the roll door is horizontal slats; prop piece
## sets exist; the cache works.

func _ready() -> void:
	var ok := true
	var size := Vector3(3, 3, 0.25)
	for surface: StringName in [&"drywall", &"brick", &"concrete", &"wood"]:
		for variant in PanelFracture.VARIANTS:
			var fs := PanelFracture.get_set(surface, size, variant)
			ok = _check_set("%s v%d" % [surface, variant], fs, size, 20, 26) and ok
	# Roll door: slats (rows of 0.3 m, 1-3 pieces each).
	var door := PanelFracture.get_set(&"wood", Vector3(3, 3, 0.12), 0, &"rolldoor")
	var flat := true
	for c: PanelFracture.Chunk in door.chunks:
		var b := Rect2(c.polygon[0], Vector2.ZERO)
		for p in c.polygon:
			b = b.expand(p)
		if b.size.y > 0.31 or b.size.x < 0.5:
			flat = false
	var door_ok := door.kind == &"slats" and door.chunks.size() >= 10 and door.chunks.size() <= 30 and flat
	print("[fracture] roll door slats=%d all horizontal strips=%s -> %s" % [door.chunks.size(), flat, _pf(door_ok)])
	ok = ok and door_ok and _check_set("rolldoor", door, Vector3(3, 3, 0.12), 10, 30)
	# Props.
	for k: StringName in [&"crate", &"desk", &"lamp"]:
		var ps := PanelFracture.get_prop_set(k, Vector3(1, 1, 1) if k != &"lamp" else Vector3(0.28, 4.6, 0.28))
		var p_ok := ps.full_only and ps.chunks.size() >= 1 and ps.intact_mesh.get_surface_count() == 1
		print("[fracture] prop %s pieces=%d -> %s" % [k, ps.chunks.size(), _pf(p_ok)])
		ok = ok and p_ok
	# Cache returns the same object.
	if PanelFracture.get_set(&"brick", size, 1) != PanelFracture.get_set(&"brick", size, 1):
		print("[fracture] cache FAIL")
		ok = false
	var t0 := Time.get_ticks_usec()
	for i in 60:
		PanelFracture.get_set(&"drywall", size, i)
	print("[fracture] 60 cached lookups: %d us" % (Time.get_ticks_usec() - t0))
	var t1 := Time.get_ticks_usec()
	PanelFracture.build_set(size, 12345)
	print("[fracture] one uncached build: %d us" % (Time.get_ticks_usec() - t1))
	print("[fracture] RESULT: ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)

func _pf(b: bool) -> String:
	return "PASS" if b else "FAIL"

func _check_set(label: String, fs: PanelFracture.FractureSet, size: Vector3, lo: int, hi: int) -> bool:
	var n := fs.chunks.size()
	var vol := 0.0
	var convex := true
	var hulls := true
	var sym := true
	var isolated := 0
	var edge_cells := 0
	var small := 0
	for i in n:
		var c: PanelFracture.Chunk = fs.chunks[i]
		vol += c.volume
		if c.small:
			small += 1
		if not PanelFracture.is_convex(c.polygon):
			convex = false
		if c.mesh == null or c.mesh.get_surface_count() != 1 or c.shape.points.size() < 6 \
				or c.static_shape == null or c.static_shape.points.size() < 6:
			hulls = false
		if c.neighbors.is_empty():
			isolated += 1
		for j in c.neighbors:
			if not (fs.chunks[j] as PanelFracture.Chunk).neighbors.has(i):
				sym = false
		if (c.edge_mask & PanelFracture.SUPPORT_SIDES) != 0:
			edge_cells += 1
	# All cells reachable from cell 0 through neighbours.
	var seen := {0: true}
	var stack: Array[int] = [0]
	while not stack.is_empty():
		var i: int = stack.pop_back()
		for j in (fs.chunks[i] as PanelFracture.Chunk).neighbors:
			if not seen.has(j):
				seen[j] = true
				stack.append(j)
	var connected := seen.size() == n
	var panel_vol := size.x * size.y * size.z
	var err := absf(vol - panel_vol) / panel_vol
	var ok := n >= lo and n <= hi and convex and hulls and sym and isolated == 0 and connected \
		and edge_cells > 0 and err <= 0.05 and fs.edges.size() > 0
	print("[fracture] %s cells=%d small=%d vol err=%.4f%% convex=%s hulls=%s neighbours symmetric=%s connected=%s edge_cells=%d crack_edges=%d -> %s" % [
		label, n, small, err * 100.0, convex, hulls, sym, connected, edge_cells, fs.edges.size(), _pf(ok)])
	return ok
