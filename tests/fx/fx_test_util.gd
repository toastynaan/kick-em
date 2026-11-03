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
## `complete`: wait for every variant, not just the first of each id.
## Generous by default: with many Godot processes on one machine the worker
## thread can take 50x longer than the ~2 s it needs on an idle one.
static func wait_audio(tree: SceneTree, max_ms := 240000, complete := false) -> bool:
	var t0 := Time.get_ticks_msec()
	while not (AudioFX.is_complete() if complete else AudioFX.is_ready()) and Time.get_ticks_msec() - t0 < max_ms:
		await tree.process_frame
	return AudioFX.is_complete() if complete else AudioFX.is_ready()

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

## A float shader parameter, 0 when it was never set (headless has no
## shader introspection, so unset uniforms read back as null).
static func fparam(m: Material, param: StringName) -> float:
	var v = (m as ShaderMaterial).get_shader_parameter(param) if m is ShaderMaterial else null
	return float(v) if v != null else 0.0

## fparam() for a mesh part's material.
static func part_param(part: MeshInstance3D, param: StringName) -> float:
	return fparam(part.material_override, param)

static func is_red(c: Color) -> bool:
	return c.r > 0.15 and c.r > c.g * 2.0 and c.r > c.b * 2.0

static func near(a: float, b: float, eps := 0.01) -> bool:
	return absf(a - b) <= eps

## A landed hit. Round 5: effects follow `tier` (HitInfo.Tier); NONE leaves the
## legacy reaction (FLINCH) to decide.
static func hit(victim: Node3D, move: StringName, pos: Vector3, dir: Vector3, damage: float,
		energy: float, kind := &"strike", tier := HitInfo.Tier.NONE) -> HitInfo:
	var h := HitInfo.new()
	h.tier = tier
	h.victim = victim
	h.move_id = move
	h.kind = kind
	h.damage = damage
	h.energy = energy
	h.hit_position = pos
	h.hit_direction = dir.normalized()
	h.result = HitInfo.Result.HIT
	return h

## Slow the world to `scale` for `seconds` s of TimeDirector time, the player
## keeping real time (Round 7 removed Focus mode, which the slow-motion checks
## used): a TimeDirector slow-motion row through its legacy entry point
## (PRIO_DODGE), called dynamically so a TimeDirector mid-rewrite never stops a
## test compiling. TimeDirector time counts physics frames, which run far ahead
## of the wall clock headless under --fixed-fps, so the default hold is an
## hour: normal_time() ends it. Returns false when refused or missing.
static func slow_world(scale := 0.3, seconds := 3600.0) -> bool:
	normal_time()
	if not TimeDirector.has_method(&"request_slowmo"):
		return false
	return bool(TimeDirector.call(&"request_slowmo", scale, seconds, 1))

## Back to normal speed at once (TimeDirector.reset()).
static func normal_time() -> void:
	if TimeDirector.has_method(&"reset"):
		TimeDirector.call(&"reset")

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
