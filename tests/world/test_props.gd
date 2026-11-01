extends Node3D
## Props (round 2): a desk breaks at its ~900 J (a softer hit only cracks it);
## a crate stack falls together when the bottom crate breaks; a lamp post
## survives a standing kick but topples at 13 m/s and keeps its stump; a loose
## chair gets knocked around by a flying body.

var _use_fake := false
var _decisions: Array = []
var _ok := true

func _ready() -> void:
	ImpactResolver.wall_decided.connect(func(f: Node3D, w: Node3D, outcome: StringName, e: float, _p: Vector3) -> void:
		_decisions.append({"fighter": f, "wall": w, "outcome": outcome, "energy": e}))
	WorldTestUtil.make_floor(self, 200.0)
	await get_tree().physics_frame
	_use_fake = not await WorldTestUtil.real_ragdoll_available(self)
	print("[props] ragdoll: ", "TEST STAND-IN" if _use_fake else "real RagdollController")

	# 1. Desk: 6 m/s (1,260 J) breaks it, 4 m/s (560 J) cracks it.
	var desk := _prop(&"desk", Vector3(0, 0.38, 0), Vector3(1.4, 0.76, 0.7), 900.0, PI * 0.5)
	await get_tree().physics_frame
	var r := await _fly(desk, 4.0, 0.0)
	var d1: StringName = r["outcome"]
	var still_up := not desk.is_broken
	r = await _fly(desk, 6.0, 0.0)
	var desk_ok: bool = d1 == &"crack" and still_up and r["outcome"] == &"break" and desk.is_broken
	print("[props] desk: 4 m/s -> %s (standing=%s), 6 m/s -> %s E=%.0f broken=%s -> %s" % [
		d1, still_up, r["outcome"], r["energy"], desk.is_broken, _pf(desk_ok)])
	_ok = _ok and desk_ok

	# 2. Crate stack: breaking the bottom crate takes the top one with it.
	var bottom := _prop(&"crate", Vector3(0, 0.5, 10), Vector3.ONE, 600.0, 0.0)
	var top := _prop(&"crate", Vector3(0, 1.5, 10), Vector3.ONE, 600.0, 0.3)
	await get_tree().physics_frame
	bottom.receive_impact(800.0, bottom.global_position + Vector3(0.5, 0, 0), Vector3(-5, 0, 0))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var planks := bottom.last_chunks.size()
	var stack_ok := bottom.is_broken and top.is_broken and planks >= 10
	print("[props] crate stack: bottom broken=%s (%d planks), top broken=%s -> %s" % [bottom.is_broken, planks, top.is_broken, _pf(stack_ok)])
	_ok = _ok and stack_ok

	# 3. Lamp post: standing kick survives, 13 m/s topples, stump stays.
	var lamp := _prop(&"lamp", Vector3(0, 2.3, 20), Vector3(0.28, 4.6, 0.28), 3000.0, PI)
	await get_tree().physics_frame
	r = await _fly(lamp, 8.0, 20.0)
	var l1: StringName = r["outcome"]
	var standing := not lamp.is_broken
	r = await _fly(lamp, 13.0, 20.0, true)
	var pole: RigidBody3D = lamp.last_chunks[0] if lamp.last_chunks.size() > 0 else null
	var tilt := 0.0
	if pole and is_instance_valid(pole):
		tilt = rad_to_deg(pole.global_basis.y.angle_to(Vector3.UP))
	var stump_hit := not get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
		Vector3(1.0, 0.15, 20), Vector3(-1.0, 0.15, 20), Layers.DESTRUCTIBLE)).is_empty()
	var lamp_ok: bool = standing and l1 != &"break" and r["outcome"] == &"break" and tilt > 45.0 and stump_hit
	print("[props] lamp: 8 m/s -> %s (standing=%s), 13 m/s -> %s, pole tilt %.0f deg, stump solid=%s -> %s" % [
		l1, standing, r["outcome"], tilt, stump_hit, _pf(lamp_ok)])
	_ok = _ok and lamp_ok

	# 4. Loose chair gets knocked around.
	var chair := RigidBody3D.new()
	chair.mass = 8.0
	chair.collision_layer = Layers.DEBRIS
	chair.collision_mask = Layers.MASK_DEBRIS
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = Vector3(0.5, 0.9, 0.5)
	cs.shape = bx
	chair.add_child(cs)
	add_child(chair)
	chair.global_position = Vector3(0, 0.45, 30)
	await WorldTestUtil.wait_game(self, 0.5)
	var c0 := chair.global_position
	r = await _fly_at(Vector3(0.0, 0, 30), 8.0)
	var moved := chair.global_position.distance_to(c0)
	var chair_ok := moved > 0.3
	print("[props] loose chair moved %.2f m when a body flew into it -> %s" % [moved, _pf(chair_ok)])
	_ok = _ok and chair_ok

	print("[props] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _pf(b: bool) -> String:
	return "PASS" if b else "FAIL"

func _prop(kind: StringName, at: Vector3, size: Vector3, energy: float, yaw: float) -> Destructible:
	var d := Destructible.new()
	d.kind = kind
	d.surface = &"concrete" if kind == &"lamp" else &"wood"
	d.size = size
	d.break_energy_override = energy
	d.transform = Transform3D(Basis(Vector3.UP, yaw), at)
	add_child(d)
	return d

## Launch a 70 kg body from 2 m (+X side) at `speed` toward the prop.
func _fly(prop: Destructible, speed: float, z: float, keep_debris := false) -> Dictionary:
	_decisions.clear()
	var face_x := prop.global_position.x + prop.get_half_extent_along(Vector3.RIGHT)
	var _r := await _fly_at(Vector3(face_x, 0, z), speed, keep_debris)
	var mine := _decisions.filter(func(d: Dictionary) -> bool: return d["wall"] == prop)
	return {"outcome": mine[0]["outcome"] if mine.size() > 0 else &"none",
		"energy": mine[0]["energy"] if mine.size() > 0 else -1.0}

func _fly_at(face: Vector3, speed: float, keep_debris := false) -> Dictionary:
	var f := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, -PI * 0.5), face + Vector3(2.0, 0.05, 0)), _use_fake)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var com := f.get_center_of_mass()
	f.global_position += Vector3(face.x + 2.0 - com.x, 0, face.z - com.z)
	f.reset_physics_interpolation()
	await get_tree().physics_frame
	f.launch(Vector3(-speed, 1.6, 0), f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 1.5)
	f.queue_free()
	if keep_debris:
		ImpactResolver.reset()
		TimeDirector.reset()
	else:
		WorldTestUtil.cleanup()
	await get_tree().physics_frame
	return {}
