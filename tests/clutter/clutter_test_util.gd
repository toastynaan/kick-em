class_name ClutterTestUtil
## Shared helpers for tests/clutter/* (agent K). TEST-ONLY.

## Static floor on Layers.WORLD, top at y = 0.
static func make_floor(parent: Node3D, size := 300.0) -> StaticBody3D:
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_layer = Layers.WORLD
	floor_body.collision_mask = 0
	floor_body.add_to_group(&"world_static")
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, 2, size)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	floor_body.add_child(cs)
	parent.add_child(floor_body)
	return floor_body

## A clutter object of `kind` at `pos` (floor), front toward +Z rotated by `yaw` (rad).
static func make(parent: Node3D, kind: StringName, pos: Vector3, yaw := 0.0, variant: StringName = &"") -> Furniture:
	var f := Furniture.create(kind, Transform3D(Basis(Vector3.UP, yaw), pos), variant)
	parent.add_child(f)
	return f

## A 70 kg dummy body (real ragdoll) of `archetype`.
static func spawn_body(parent: Node3D, pos: Vector3, yaw := 0.0, archetype: StringName = &"player",
		team := Fighter.TEAM_ENEMY) -> Fighter:
	var f := FighterFactory.spawn_dummy(parent, archetype, Transform3D(Basis(Vector3.UP, yaw), pos), team)
	f.max_hp = 1000.0
	f.hp = 1000.0
	return f

static func frames(node: Node, n: int) -> void:
	for i in n:
		await node.get_tree().physics_frame

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

## Every furniture_broken emitted while `fn` runs is appended to `out` as
## {"node", "position", "kind", "energy", "by", "chunks" (pieces it spawned)}.
static func record_breaks(out: Array) -> Callable:
	var cb := func(node: Node3D, position: Vector3, kind: StringName, energy: float, by: Node3D) -> void:
		var chunks: Variant = node.get(&"last_chunks") if is_instance_valid(node) else null
		out.append({"node": node, "position": position, "kind": kind, "energy": energy, "by": by,
			"chunks": (chunks as Array).size() if chunks is Array else 0})
	GameEvents.furniture_broken.connect(cb)
	return cb

## Live (not fading) debris bodies that came from clutter of `kind` (any if &"").
static func pieces_of(kind: StringName = &"") -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	for b in DebrisManager.get_bodies():
		if b.has_meta(&"clutter_piece") and (kind == &"" or b.get_meta(&"clutter_piece") == kind):
			out.append(b)
	return out

## The capsule speed of a fighter across the floor.
static func hspeed(f: Fighter) -> float:
	return Vector2(f.velocity.x, f.velocity.z).length()
