extends RefCounted
## Shared helpers for tests/fx. OWNER: agent F.

const FakeFighter := preload("res://tests/fx/fx_fake_fighter.gd")
const ErrorLogger := preload("res://tests/fx/fx_error_logger.gd")

## 40 x 40 m floor whose top face is y = 0.
static func make_floor(parent: Node) -> StaticBody3D:
	return make_box(parent, Vector3(0, -0.5, 0), Vector3(40, 1, 40), Layers.WORLD)

## Static box on the given physics layer.
static func make_box(parent: Node, center: Vector3, size: Vector3, layer: int) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.collision_layer = layer
	b.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	b.add_child(cs)
	parent.add_child(b)
	b.global_position = center
	return b

static func make_fighter(parent: Node, pos: Vector3, body := true) -> Node3D:
	var f := FakeFighter.new()
	f.name = "FakeFighter"
	parent.add_child(f)
	f.global_position = pos
	if body:
		f.build_body()
	return f

## Wait (wall clock: the synth runs on a worker thread, and --fixed-fps frames
## can outrun it) until AudioFX has every sound. Returns AudioFX.is_ready().
static func wait_audio(tree: SceneTree, max_ms := 20000) -> bool:
	var t0 := Time.get_ticks_msec()
	while not AudioFX.is_ready() and Time.get_ticks_msec() - t0 < max_ms:
		await tree.process_frame
	return AudioFX.is_ready()

static func physics_frames(tree: SceneTree, n: int) -> void:
	for i in n:
		await tree.physics_frame

## Wait until BloodFX has resolved every queued decal request.
static func drain(tree: SceneTree, max_frames := 600) -> void:
	var i := 0
	while BloodFX.pending() > 0 and i < max_frames:
		await tree.physics_frame
		i += 1
	await tree.physics_frame

static func is_red(c: Color) -> bool:
	return c.r > 0.15 and c.r > c.g * 2.0 and c.r > c.b * 2.0

static func near(a: float, b: float, eps := 0.01) -> bool:
	return absf(a - b) <= eps

static func hit(victim: Node3D, move: StringName, pos: Vector3, dir: Vector3, damage: float,
		energy: float, kind := &"strike") -> HitInfo:
	var h := HitInfo.new()
	h.victim = victim
	h.move_id = move
	h.kind = kind
	h.damage = damage
	h.energy = energy
	h.hit_position = pos
	h.hit_direction = dir.normalized()
	h.result = HitInfo.Result.HIT
	return h

## Print the result and quit. Stops audio first and lets the AudioServer drop
## the stopped playbacks, so quitting does not report leaked instances.
static func finish(tree: SceneTree, name: String, fails: Array[String], errlog: ErrorLogger) -> void:
	if errlog.other_errors > 0:
		print("note: %d errors from other modules, last: %s" % [errlog.other_errors, errlog.last_other])
	if errlog.errors > 0:
		fails.append("%d FX errors, last: %s" % [errlog.errors, errlog.last])
	BloodFX.reset()
	AudioFX.stop_all()
	for i in 10:
		await tree.process_frame
	for f in fails:
		print("FAIL ", f)
	print(("PASS " if fails.is_empty() else "FAIL ") + name)
	tree.quit(0 if fails.is_empty() else 1)
