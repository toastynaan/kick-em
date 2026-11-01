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
