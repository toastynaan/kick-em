class_name WorldTestUtil
## Shared helpers for tests/world/*. TEST-ONLY.

## Static floor on Layers.WORLD, top at y = 0.
static func make_floor(parent: Node3D, size := 80.0) -> StaticBody3D:
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_layer = Layers.WORLD
	floor_body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, 2, size)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	floor_body.add_child(cs)
	parent.add_child(floor_body)
	return floor_body

## Panel of `surface` centred at (x, 1.5, z) with its exterior face toward +X.
static func make_panel(parent: Node3D, surface: StringName, at := Vector3.ZERO) -> Destructible:
	var d := Destructible.new()
	d.surface = surface
	d.name = "Panel_" + String(surface)
	d.transform = Transform3D(Basis.looking_at(Vector3(-1, 0, 0), Vector3.UP), at + Vector3(0, 1.5, 0))
	parent.add_child(d)
	return d

## True when agent A's real RagdollController launches bodies.
static func real_ragdoll_available(parent: Node3D) -> bool:
	var f := FighterFactory.spawn_dummy(parent, &"grunt", Transform3D(Basis(), Vector3(30, 0.05, 30)))
	await parent.get_tree().physics_frame
	f.launch(Vector3(0, 1, 0), f.get_aim_point())
	for i in 3:
		await parent.get_tree().physics_frame
	var ok := f.get_state() == RagdollController.State.LAUNCHED and f.ragdoll.get_com_velocity().length() > 0.1
	f.queue_free()
	await parent.get_tree().physics_frame
	ImpactResolver.reset()
	return ok

## Spawn a 70 kg dummy; with use_fake, swap in the test stand-in ragdoll.
static func spawn_body(parent: Node3D, xform: Transform3D, use_fake: bool,
		archetype: StringName = &"grunt", team := Fighter.TEAM_ENEMY) -> Fighter:
	var f := FighterFactory.spawn_dummy(parent, archetype, xform, team)
	if use_fake:
		WorldTestFakeRagdoll.install(f)
	return f

## Await physics frames until `seconds` of game time passed.
static func wait_game(node: Node, seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		await node.get_tree().physics_frame
		t += node.get_physics_process_delta_time()

static func cleanup() -> void:
	ImpactResolver.reset()
	DebrisManager.reset()
	TimeDirector.reset()

## Round 6: free agent K's clutter (breakables that are not D's Destructibles or
## Pillars, and loose clutter bodies) within `radius` of `center`, so a test of
## D's structure flies through a lane K's layout does not own. Returns how many.
static func clear_clutter_near(tree: SceneTree, center: Vector3, radius: float) -> int:
	var cands: Array = []
	cands.append_array(tree.get_nodes_in_group(&"breakables"))
	cands.append_array(tree.get_nodes_in_group(&"clutter"))
	# Everything K's layout put under its "Clutter" containers (loose furniture too).
	for root in tree.root.find_children("Clutter", "", true, false):
		cands.append_array(root.get_children())
	var n := 0
	var done := {}
	for node: Node in cands:
		if done.has(node.get_instance_id()) or node is Destructible or node is Pillar or not (node is Node3D) \
				or node.is_queued_for_deletion():
			continue
		done[node.get_instance_id()] = true
		var p := (node as Node3D).global_position
		if Vector2(p.x - center.x, p.z - center.z).length() <= radius:
			node.queue_free()
			n += 1
	return n
