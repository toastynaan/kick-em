extends RefCounted
## Shared helpers for tests/ai. OWNER: agent C (AI tests).

const FakeFighter := preload("res://tests/ai/fake_fighter.gd")

## 80 x 80 m static floor on Layers.WORLD, top at y = 0.
static func build_floor(parent: Node) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Floor"
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80.0, 1.0, 80.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	body.add_child(shape)
	parent.add_child(body)
	return body

## Fighter with forceable state. Ensures combat exists and groups are set
## even while fighter.gd is still a stub.
static func spawn_fake(parent: Node, archetype: StringName, team: int, pos: Vector3) -> Fighter:
	var f: Fighter = FakeFighter.new()
	f.name = "Fake" + String(archetype).capitalize()
	f.setup(archetype, team)
	f.position = pos
	parent.add_child(f)
	ensure_wired(f)
	return f

## Stub fighters build nothing; give them a CombatController and groups.
static func ensure_wired(f: Fighter) -> void:
	if f.combat == null:
		var c := CombatController.new()
		c.name = "Combat"
		c.setup(f)
		f.add_child(c)
		f.combat = c
	if not f.is_in_group(&"fighters"):
		f.add_to_group(&"fighters")
	if f.is_player and not f.is_in_group(&"player"):
		f.add_to_group(&"player")
	if not f.is_player and not f.is_in_group(&"enemies"):
		f.add_to_group(&"enemies")

## True if fighter.gd is still the contract stub (no movement, no combat).
static func fighter_is_stub(f: Fighter) -> bool:
	return f.rig == null and f.ragdoll == null

static func flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

## Four static walls (Layers.WORLD, 4 m high) around a square of half size `half`.
static func build_walls(parent: Node, half: float) -> void:
	for i in 4:
		var body := StaticBody3D.new()
		body.name = "Wall%d" % i
		body.collision_layer = Layers.WORLD
		body.collision_mask = 0
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(half * 2.0 + 1.0, 4.0, 0.5)
		shape.shape = box
		body.add_child(shape)
		parent.add_child(body)
		body.rotation.y = PI * 0.5 * i
		body.position = body.basis * Vector3(0.0, 2.0, -(half + 0.25))

## The real arena (agent D's YardBuilder) in group "arena". Returns null if
## the builder produced nothing (still a stub); the caller then uses walls.
static func build_yard(parent: Node) -> Node3D:
	var yard := YardBuilder.new()
	yard.name = "Arena"
	parent.add_child(yard)
	yard.add_to_group(&"arena")
	yard.build()
	if yard.get_child_count() == 0:
		yard.queue_free()
		return null
	return yard

## Test clock: physics ticks / tick rate. Equals real time in a normal run and
## stays in step with the simulation under --fixed-fps (TimeDirector.now() is
## the wall clock, which falls behind the simulation there).
static func game_now() -> float:
	return Engine.get_physics_frames() / float(Engine.physics_ticks_per_second)
