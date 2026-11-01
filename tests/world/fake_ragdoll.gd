class_name WorldTestFakeRagdoll
extends RagdollController
## TEST-ONLY stand-in for agent A's RagdollController, used by tests/world/*
## while the real ragdoll is unavailable (the stub never leaves ANIMATED). A
## 70 kg body made of three RigidBody3Ds (torso, two legs) pinned together, on
## Layers.RAGDOLL. Implements just what ImpactResolver and Fighter call.

var bodies: Array[RigidBody3D] = []
var _ignore := false
var _slow_t := 0.0
var _t_launch := INF

static func install(f: Fighter) -> WorldTestFakeRagdoll:
	var fake := WorldTestFakeRagdoll.new()
	fake.name = "FakeRagdoll"
	var old := f.ragdoll
	if old:
		old.set_physics_process(false)
		old.process_mode = Node.PROCESS_MODE_DISABLED
	f.add_child(fake)
	fake.host = f
	fake.rig = f.rig
	f.ragdoll = fake
	fake.launched.connect(func(v: Vector3) -> void: GameEvents.fighter_launched.emit(f, v))
	fake.recovered.connect(func() -> void: GameEvents.fighter_recovered.emit(f))
	fake._build(f.get_total_mass() if old == null else 70.0)
	return fake

func _build(mass_total: float) -> void:
	var parts := [
		["Torso", Vector3(0, 1.25, 0), Vector3(0.42, 0.75, 0.26), 0.6],
		["LegL", Vector3(-0.11, 0.48, 0), Vector3(0.16, 0.86, 0.18), 0.2],
		["LegR", Vector3(0.11, 0.48, 0), Vector3(0.16, 0.86, 0.18), 0.2],
	]
	for p: Array in parts:
		var b := RigidBody3D.new()
		b.name = p[0]
		b.mass = mass_total * float(p[3])
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = p[2]
		cs.shape = box
		b.add_child(cs)
		b.collision_layer = Layers.RAGDOLL
		b.collision_mask = Layers.MASK_RAGDOLL
		b.freeze = true
		b.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		b.top_level = true
		add_child(b)
		b.global_position = host.global_position + host.global_basis * (p[1] as Vector3)
		b.global_basis = host.global_basis
		b.add_collision_exception_with(host)
		bodies.append(b)
	for i in [1, 2]:
		var j := Generic6DOFJoint3D.new()
		j.top_level = true
		add_child(j)
		j.global_position = (bodies[0].global_position + bodies[i].global_position) * 0.5
		j.node_a = bodies[0].get_path()
		j.node_b = bodies[i].get_path()
		for axis in ["x", "y", "z"]:
			j.set("angular_limit_%s/upper_angle" % axis, deg_to_rad(40.0))
			j.set("angular_limit_%s/lower_angle" % axis, deg_to_rad(-40.0))
	if rig:
		for pb in rig.get_physical_bones():
			for b in bodies:
				b.add_collision_exception_with(pb)
	bodies[0].add_collision_exception_with(bodies[1])
	bodies[0].add_collision_exception_with(bodies[2])
	bodies[1].add_collision_exception_with(bodies[2])

func launch(velocity: Vector3, _hit_point: Vector3, _hit_bone: StringName = &"Chest") -> void:
	for b in bodies:
		b.freeze = false
		b.linear_velocity += velocity
	var old := state
	state = State.LAUNCHED
	_t_launch = 0.0
	_slow_t = 0.0
	host.collision_layer = 0
	state_changed.emit(old, state)
	launched.emit(velocity)

func add_velocity(dv: Vector3) -> void:
	for b in bodies:
		b.linear_velocity += dv

func scale_velocity(factor: float) -> void:
	for b in bodies:
		b.linear_velocity *= factor

func apply_limb_spin(_direction: Vector3, _strength: float = 1.0) -> void:
	pass

func set_ignore_breakables(ignore: bool) -> void:
	_ignore = ignore
	for b in bodies:
		b.collision_mask = Layers.MASK_RAGDOLL & ~Layers.DESTRUCTIBLE if ignore else Layers.MASK_RAGDOLL

func is_ignoring_breakables() -> bool:
	return _ignore

func is_simulating() -> bool:
	return state in [State.LAUNCHED, State.GROUNDED, State.DEAD]

func time_since_launch() -> float:
	return _t_launch

func get_total_mass() -> float:
	var m := 0.0
	for b in bodies:
		m += b.mass
	return m

func get_center_of_mass() -> Vector3:
	var s := Vector3.ZERO
	var m := 0.0
	for b in bodies:
		s += b.global_position * b.mass
		m += b.mass
	return s / m

func get_com_velocity() -> Vector3:
	var s := Vector3.ZERO
	var m := 0.0
	for b in bodies:
		s += b.linear_velocity * b.mass
		m += b.mass
	return s / m

func get_bounds() -> AABB:
	var a := AABB()
	var first := true
	for b in bodies:
		var cs: CollisionShape3D = b.get_child(0)
		var box: BoxShape3D = cs.shape
		var bb := b.global_transform * AABB(-box.size * 0.5, box.size)
		a = bb if first else a.merge(bb)
		first = false
	return a

func get_ground_position() -> Vector3:
	var c := get_center_of_mass()
	return Vector3(c.x, 0.0, c.z)

func _physics_process(delta: float) -> void:
	if state == State.LAUNCHED:
		_t_launch += delta
		if get_com_velocity().length() < 0.5 and _t_launch > 0.3:
			_slow_t += delta
			if _slow_t > 0.4:
				var old := state
				state = State.GROUNDED
				state_changed.emit(old, state)
				grounded.emit()
		else:
			_slow_t = 0.0
