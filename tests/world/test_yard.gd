extends Node3D
## Yard: builds without errors; every spawn path has no wall or prop between
## consecutive points (raycasts at three heights and +-0.3 m to each side);
## paths end inside the courtyard; spawns sit outside it; props exist; layout
## sanity. Round 5 (Feel Reference: Movement spec, F7 / F7b, On the world):
## - things to vault and mantle: low walls 0.9 m, crates 1.1 m, a 1.8 m platform
##   with open floor on every side, 4 pillars; none on the duel line, a spawn,
##   an entry path or a breach lane, and enemies can path from every entry to
##   the player spawn and to each side of the platform (AINavGrid);
## - at least two straight runnable walls of 8 m or more: rays hit runnable
##   geometry along each lane, the run strip beside it is free, and there is
##   open floor beyond it;
## - WorldTags: arena walls and intact wall panels are runnable, a cracked
##   panel, a low wall, a pillar, a body, a bone and debris are not; floors are
##   tagged (concrete courtyard, wood offices, dirt outside, water, metal);
##   obstacles are static geometry, never bodies or props.

func _ready() -> void:
	var yard := YardBuilder.new()
	yard.name = "Yard"
	add_child(yard)
	var t0 := Time.get_ticks_usec()
	yard.build()
	@warning_ignore("integer_division")
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
	# drums; in the courtyard only the Round 5 crates and the two lamps at the
	# ends of the south wall.
	var kinds := {}
	var in_court := 0
	for d in walls:
		if d.kind != &"panel":
			kinds[d.kind] = kinds.get(d.kind, 0) + 1
			var p := d.global_position
			if absf(p.x) < 10.5 and absf(p.z) < 10.5 and d.kind != &"lamp" and not d.has_meta(&"courtyard"):
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
	print("[yard] props %s loose=%d stray in courtyard=%d lamps on south edge=%s -> %s" % [kinds, loose, in_court, lamps_edge,
		"PASS" if props_ok else "FAIL"])
	ok = ok and props_ok
	ok = _check_parkour(yard, space) and ok
	ok = _check_lanes(yard, space) and ok
	ok = _check_tags(yard, space) and ok
	ok = _check_nav(yard, space) and ok
	print("[yard] RESULT: ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)

func _inside(b: AABB, p: Vector3) -> bool:
	return p.x >= b.position.x and p.x <= b.end.x and p.z >= b.position.z and p.z <= b.end.z

func _pf(b: bool) -> String:
	return "PASS" if b else "FAIL"

## Height of the first surface under (x, z) from 3 m up (WORLD | DESTRUCTIBLE).
func _top_at(space: PhysicsDirectSpaceState3D, x: float, z: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, 3.0, z), Vector3(x, -1.0, z), Layers.WORLD | Layers.DESTRUCTIBLE)
	var hit := space.intersect_ray(q)
	return hit["position"].y if not hit.is_empty() else -INF

func _free_at(space: PhysicsDirectSpaceState3D, p: Vector3, radius := 0.35) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = radius
	cap.height = 1.5
	q.shape = cap
	q.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
	q.transform = Transform3D(Basis(), Vector3(p.x, 0.95, p.z))
	return space.intersect_shape(q, 1).is_empty()

## Low walls 0.9 m, crates 1.1 m, the 1.8 m platform with open floor round it,
## pillars; the duel line and the player spawn stay open.
func _check_parkour(yard: YardBuilder, space: PhysicsDirectSpaceState3D) -> bool:
	var feat := yard.get_parkour_features()
	var ok := true
	var lows: Array = []
	for b: AABB in feat["low_walls"]:
		var c := b.get_center()
		lows.append("%.2f" % _top_at(space, c.x, c.z))
		ok = ok and absf(_top_at(space, c.x, c.z) - 0.9) < 0.02
	var crates: Array = []
	for d: Destructible in feat["crates"]:
		var t := _top_at(space, d.global_position.x, d.global_position.z)
		crates.append("%.2f" % t)
		ok = ok and absf(t - 1.1) < 0.02
	var pl: AABB = feat["platform"]
	var pc := pl.get_center()
	var p_top := _top_at(space, pc.x, pc.z)
	# Open floor on every side, as far as YardBuilder publishes the platform's
	# approach (2 m, get_structure_features &"platform_approach"): capsule-sized
	# spots (0.35 m) 1.0 and 1.6 m out from each edge.
	var open := true
	for k in 4:
		for out in [1.0, 1.6]:
			var p := pc
			match k:
				0: p.x = pl.position.x - out
				1: p.x = pl.end.x + out
				2: p.z = pl.position.z - out
				3: p.z = pl.end.z + out
			if not _free_at(space, p):
				open = false
				print("[yard]   platform side %d blocked at %s" % [k, p])
	ok = ok and absf(p_top - 1.8) < 0.02 and open and lows.size() >= 2 and crates.size() >= 3 \
		and (feat["pillars"] as Array).size() == 4
	# Duel line and spawns open.
	var q := PhysicsRayQueryParameters3D.create(Vector3(0, 1.0, 4.0), Vector3(0, 1.0, -4.0), Layers.WORLD | Layers.DESTRUCTIBLE)
	var duel_clear := space.intersect_ray(q).is_empty()
	ok = ok and duel_clear
	print("[yard] parkour: low walls top %s (0.9), crates top %s (1.1), platform top %.2f (1.8) open sides=%s, pillars=%d, duel line clear=%s -> %s" % [
		lows, crates, p_top, open, (feat["pillars"] as Array).size(), duel_clear, _pf(ok)])
	return ok

## Wall-run lanes: >= 2 of 8 m or more; along each, rays at chest height from
## 0.5 m off the wall hit runnable geometry, the strip 0.2-1.2 m off the wall is
## free, and 3 m off it there is open floor.
func _check_lanes(yard: YardBuilder, space: PhysicsDirectSpaceState3D) -> bool:
	var long := 0
	var all_ok := true
	for lane: Dictionary in yard.get_wall_run_lanes():
		var a: Vector3 = lane["from"]
		var b: Vector3 = lane["to"]
		var n: Vector3 = lane["normal"]
		var length: float = lane["length"]
		var steps := int(length)
		var runnable := 0
		var strip_free := true
		var open := 0
		for i in steps + 1:
			var p := a.lerp(b, float(i) / float(steps))
			var from := p + n * 0.5 + Vector3.UP * 1.3
			var q := PhysicsRayQueryParameters3D.create(from, from - n * 1.0, Layers.WORLD | Layers.DESTRUCTIBLE)
			var hit := space.intersect_ray(q)
			if not hit.is_empty() and WorldTags.is_runnable(hit["collider"]):
				runnable += 1
			if i > 0 and i < steps and not _free_at(space, p + n * 0.75, 0.3):
				strip_free = false
			if _free_at(space, p + n * 3.0, 0.3):
				open += 1
		var lane_ok := runnable == steps + 1 and strip_free and open >= int(0.7 * (steps + 1))
		if length >= 8.0 and lane_ok:
			long += 1
		print("[yard] lane %s %.1f m: runnable %d/%d, run strip free=%s, open floor beside %d/%d -> %s" % [
			lane["name"], length, runnable, steps + 1, strip_free, open, steps + 1, _pf(lane_ok)])
		all_ok = all_ok and lane_ok
	var ok := all_ok and long >= 2
	print("[yard] runnable lanes of 8 m or more: %d -> %s" % [long, _pf(ok)])
	return ok

## WorldTags on the real Yard.
func _check_tags(yard: YardBuilder, space: PhysicsDirectSpaceState3D) -> bool:
	var ok := true
	var facade: Destructible = null
	var low: Destructible = null
	for d in yard.get_destructibles():
		if d.has_meta(&"facade") and d.surface == &"drywall" and facade == null:
			facade = d
		if d.has_meta(&"low_wall"):
			low = d
	var arena := yard.get_node(^"ArenaWalls")
	var pillar: Pillar = (yard.get_parkour_features()["pillars"] as Array)[0]
	var before := WorldTags.is_runnable(facade)
	facade.force_crack(facade.global_position)
	var after := WorldTags.is_runnable(facade)
	var dummy := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis(), Vector3(0, 0.05, 0)))
	var bone: Object = dummy.rig.get_physical_bones()[0] if dummy.rig and not dummy.rig.get_physical_bones().is_empty() else dummy
	var chunk := RigidBody3D.new()
	add_child(chunk)
	DebrisManager.register(chunk, false)
	var tags_ok := before and not after and WorldTags.is_runnable(arena) and not WorldTags.is_runnable(low) \
		and not WorldTags.is_runnable(pillar) and not WorldTags.is_runnable(dummy) and not WorldTags.is_runnable(bone) \
		and not WorldTags.is_runnable(chunk)
	var obst_ok := WorldTags.is_obstacle(low) and WorldTags.is_obstacle(pillar) and WorldTags.is_obstacle(arena) \
		and not WorldTags.is_obstacle(dummy) and not WorldTags.is_obstacle(bone) and not WorldTags.is_obstacle(chunk)
	print("[yard] runnable: facade %s -> cracked %s, arena walls %s, low wall %s, pillar %s, body %s, bone %s, debris %s; obstacles ok=%s -> %s" % [
		before, after, WorldTags.is_runnable(arena), WorldTags.is_runnable(low), WorldTags.is_runnable(pillar),
		WorldTags.is_runnable(dummy), WorldTags.is_runnable(bone), WorldTags.is_runnable(chunk), obst_ok, _pf(tags_ok and obst_ok)])
	ok = tags_ok and obst_ok
	dummy.queue_free()
	DebrisManager.reset()
	# Floor surfaces under sample points.
	var feat := yard.get_parkour_features()
	var w: Rect2 = feat["water"]
	var m: Rect2 = feat["metal"]
	var samples := {&"water": w.get_center(), &"metal": m.get_center(), &"wood": Vector2(-14.0, 0.0),
		&"concrete": Vector2(0.0, 6.0), &"dirt": Vector2(30.0, 0.0)}
	var got := {}
	for want: StringName in samples:
		var c: Vector2 = samples[want]
		var q := PhysicsRayQueryParameters3D.create(Vector3(c.x, 1.0, c.y), Vector3(c.x, -1.0, c.y), Layers.WORLD)
		var hit := space.intersect_ray(q)
		got[want] = WorldTags.surface_of(hit["collider"]) if not hit.is_empty() else &"none"
		ok = ok and got[want] == want
	print("[yard] floor surfaces %s -> %s" % [got, _pf(ok)])
	return ok

## Enemies can walk from every entry to the player spawn and to each side of
## the platform; >= 4 breach walls stay usable.
func _check_nav(yard: YardBuilder, space: PhysicsDirectSpaceState3D) -> bool:
	var grid := AINavGrid.new()
	grid.start_build(space)
	while not grid.step_build():
		pass
	var pl: AABB = yard.get_parkour_features()["platform"]
	var goals: Array[Vector3] = [yard.get_player_spawn().origin, Vector3(pl.position.x - 1.2, 0, pl.get_center().z),
		Vector3(pl.end.x + 1.2, 0, pl.get_center().z), Vector3(pl.get_center().x, 0, pl.position.z - 1.2),
		Vector3(pl.get_center().x, 0, pl.end.z + 1.2)]
	var ok := true
	var bad: Array = []
	for s: Dictionary in yard.get_enemy_spawns():
		var path: PackedVector3Array = s["path"]
		var entry := path[path.size() - 1]
		for g in goals:
			grid.find_path(entry, g)
			if not grid.last_path_complete:
				ok = false
				bad.append("%s->%s" % [s["name"], g])
	var breaches := yard.get_breach_walls().size()
	ok = ok and breaches >= 4
	print("[yard] nav: every entry reaches the spawn and the platform sides (%s), breach walls=%d -> %s" % [
		"all" if bad.is_empty() else str(bad), breaches, _pf(ok)])
	return ok
