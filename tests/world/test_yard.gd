extends Node3D
## Yard: builds without errors; every spawn path has no wall or prop between
## consecutive points (raycasts at three heights and +-0.3 m to each side);
## paths end inside the courtyard; spawns sit outside it; props exist and the
## courtyard floor stays clear; layout sanity.

func _ready() -> void:
	var yard := YardBuilder.new()
	yard.name = "Yard"
	add_child(yard)
	var t0 := Time.get_ticks_usec()
	yard.build()
	print("[yard] build took %d ms" % ((Time.get_ticks_usec() - t0) / 1000))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var ok := true
	var walls := yard.get_destructibles()
	var by_surface := {}
	for d in walls:
		by_surface[d.surface] = by_surface.get(d.surface, 0) + 1
		if not d.is_in_group(&"destructibles"):
			ok = false
	print("[yard] destructibles=%d %s" % [walls.size(), by_surface])
	if walls.size() < 30 or not yard.is_in_group(&"arena"):
		ok = false
	var space := get_world_3d().direct_space_state
	var bounds := yard.get_courtyard_bounds()
	var spawns := yard.get_enemy_spawns()
	print("[yard] spawns=%d" % spawns.size())
	for s: Dictionary in spawns:
		var pts: Array[Vector3] = [s["position"]]
		for p in (s["path"] as PackedVector3Array):
			pts.append(p)
		var clear := true
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			var dir := (b - a).normalized()
			var side := Vector3(-dir.z, 0, dir.x) * 0.3
			for h in [0.3, 1.0, 1.7]:
				for off in [Vector3.ZERO, side, -side]:
					var q := PhysicsRayQueryParameters3D.create(a + Vector3(0, h, 0) + off,
						b + Vector3(0, h, 0) + off, Layers.WORLD | Layers.DESTRUCTIBLE | Layers.DEBRIS)
					var hit := space.intersect_ray(q)
					if not hit.is_empty():
						clear = false
						print("[yard]   blocked %s seg %d at %s by %s" % [s["name"], i, hit["position"], hit["collider"].name])
		var start_out := not _inside(bounds, s["position"])
		var end_in := _inside(bounds, pts[pts.size() - 1])
		# Spawn must not be inside static geometry.
		var pq := PhysicsPointQueryParameters3D.new()
		pq.position = s["position"] + Vector3(0, 0.9, 0)
		pq.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
		var free := space.intersect_point(pq).is_empty()
		var pass_s := clear and start_out and end_in and free
		print("[yard] spawn %s pos=%s path=%s clear=%s start_outside=%s end_inside=%s free=%s -> %s" % [
			s["name"], s["position"], s["path"], clear, start_out, end_in, free, "PASS" if pass_s else "FAIL"])
		ok = ok and pass_s
	# Player / duel spawns inside the courtyard and free.
	var xs: Array[Transform3D] = [yard.get_player_spawn()]
	xs.append_array(yard.get_duel_spawns())
	for x in xs:
		var pq := PhysicsPointQueryParameters3D.new()
		pq.position = x.origin + Vector3(0, 0.9, 0)
		pq.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
		if not space.intersect_point(pq).is_empty() or not _inside(bounds, x.origin):
			print("[yard] fighter spawn blocked: ", x.origin)
			ok = false
	# Floor exists under the courtyard and rooms.
	for p in [Vector3(0, 1, 0), Vector3(-15, 1, 0), Vector3(15, 1, 0), Vector3(0, 1, -15), Vector3(-15, 1, -15)]:
		var q := PhysicsRayQueryParameters3D.create(p, p + Vector3(0, -3, 0), Layers.WORLD)
		var hit := space.intersect_ray(q)
		if hit.is_empty() or absf(hit["position"].y) > 0.01:
			print("[yard] floor missing at ", p)
			ok = false
	# Courtyard is enclosed: rays from the centre outward hit something within 20 m.
	for i in 16:
		var ang := TAU * i / 16.0
		var d := Vector3(cos(ang), 0, sin(ang))
		var q := PhysicsRayQueryParameters3D.create(Vector3(0, 1.0, 0), Vector3(0, 1.0, 0) + d * 40.0,
			Layers.WORLD | Layers.DESTRUCTIBLE)
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			print("[yard] escape route at angle ", i)
			ok = false
	# Props: breakable desks, crates and lamp posts, loose chairs / cabinets /
	# drums; the courtyard floor stays clear apart from lamps on the south edge.
	var kinds := {}
	var in_court := 0
	for d in walls:
		if d.kind != &"panel":
			kinds[d.kind] = kinds.get(d.kind, 0) + 1
			var p := d.global_position
			if absf(p.x) < 10.5 and absf(p.z) < 10.5 and d.kind != &"lamp":
				in_court += 1
	var loose := 0
	for n in get_tree().get_nodes_in_group(&"props"):
		loose += 1
		var p := (n as Node3D).global_position
		if absf(p.x) < 10.5 and absf(p.z) < 10.5:
			in_court += 1
	var lamps_edge := true
	for d in walls:
		if d.kind == &"lamp" and d.global_position.z < 9.5:
			lamps_edge = false
	var props_ok: bool = kinds.get(&"desk", 0) >= 4 and kinds.get(&"crate", 0) >= 8 and kinds.get(&"lamp", 0) >= 2 \
		and loose >= 8 and in_court == 0 and lamps_edge
	print("[yard] props %s loose=%d in courtyard=%d lamps on south edge=%s -> %s" % [kinds, loose, in_court, lamps_edge,
		"PASS" if props_ok else "FAIL"])
	ok = ok and props_ok
	print("[yard] RESULT: ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)

func _inside(b: AABB, p: Vector3) -> bool:
	return p.x >= b.position.x and p.x <= b.end.x and p.z >= b.position.z and p.z <= b.end.z
