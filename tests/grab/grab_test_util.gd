class_name GrabTestUtil
## Shared helpers for tests/grab/* (Round 7 Carry): geometry, fighters, the
## real input path (Input.action_press -> PlayerController -> InputInterpreter
## -> CombatController -> Carry), presses straight through CombatController's
## routing, a camera rig to aim with, panels, and the global resets.
## OWNER: agent G.

static func make_floor(parent: Node, size := 200.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Floor"
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, 1.0, size)
	cs.shape = box
	cs.position = Vector3(0.0, -0.5, 0.0)
	body.add_child(cs)
	parent.add_child(body)
	return body

## A static concrete-like wall (Layers.WORLD) centred at `pos`.
static func make_wall(parent: Node, pos: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Wall"
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	body.position = pos
	parent.add_child(body)
	return body

## A controller-less fighter (dummies never break grabs).
static func spawn(parent: Node, archetype: StringName, pos: Vector3, facing: Vector3,
		team := Fighter.TEAM_ENEMY) -> Fighter:
	var xf := Transform3D(Basis.looking_at(facing.normalized(), Vector3.UP), pos)
	return FighterFactory.spawn_dummy(parent, archetype, xf, team)

## The real player (PlayerController + InputInterpreter) at `pos` facing `facing`.
static func spawn_player(parent: Node, pos: Vector3, facing := Vector3.FORWARD) -> Fighter:
	return FighterFactory.spawn_player(parent, Transform3D(Basis.looking_at(facing.normalized(), Vector3.UP), pos))

## A CameraRig following `target`, its yaw looking along `look` (flat).
static func make_camera(parent: Node, target: Fighter, look: Vector3) -> CameraRig:
	var rig := CameraRig.new()
	rig.name = "CameraRig"
	rig.target = target
	parent.add_child(rig)
	set_camera_yaw(rig, look)
	return rig

## Turn the camera rig to look along `look` (flat): what the mouse would do.
static func set_camera_yaw(rig: CameraRig, look: Vector3) -> void:
	rig.set(&"_yaw", yaw_of(look))

static func yaw_of(d: Vector3) -> float:
	return atan2(-d.x, -d.z)

static func yaw_dir(y: float) -> Vector3:
	return Vector3(-sin(y), 0.0, -cos(y))

# --- Stepping ----------------------------------------------------------------------------
## Await `n` physics frames.
static func frames(node: Node, n: int) -> void:
	for i in n:
		await node.get_tree().physics_frame

## Await physics frames until `seconds` of game time passed.
static func wait(node: Node, seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		await node.get_tree().physics_frame
		t += node.get_physics_process_delta_time() * Engine.time_scale

## Await until `cond` is true or `timeout` game seconds passed. Returns cond's last value.
static func wait_until(node: Node, cond: Callable, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if cond.call():
			return true
		await node.get_tree().physics_frame
		t += node.get_physics_process_delta_time() * Engine.time_scale
	return bool(cond.call())

# --- Buttons -------------------------------------------------------------------------------
## Straight through CombatController's routing (no PlayerController needed).
static func press(f: Fighter, action: int) -> void:
	f.combat.press(action)

static func release(f: Fighter, action: int) -> void:
	f.combat.release(action)

## Tap a button: press, `hold` game seconds, release.
static func tap(node: Node, f: Fighter, action: int, hold := 0.05) -> void:
	press(f, action)
	await wait(node, hold)
	release(f, action)

## The real input path: an action press / release the PlayerController polls.
static func key_down(action: StringName) -> void:
	Input.action_press(action)

static func key_up(action: StringName) -> void:
	Input.action_release(action)

## Tap an action through the real input path: held `ticks` physics ticks.
static func key_tap(node: Node, action: StringName, ticks := 2) -> void:
	Input.action_press(action)
	await frames(node, ticks)
	Input.action_release(action)
	await frames(node, 1)

static func release_all_input() -> void:
	for a: StringName in Controls.ACTIONS:
		if InputMap.has_action(a):
			Input.action_release(a)

# --- World --------------------------------------------------------------------------------
## A Destructible panel of `surface` centred at (pos.x, 1.5, pos.z) whose face
## looks along `face` (the side bodies come from).
static func make_panel(parent: Node3D, surface: StringName, pos: Vector3, face: Vector3) -> Destructible:
	var d := Destructible.new()
	d.surface = surface
	d.name = "Panel_" + String(surface)
	d.transform = Transform3D(Basis.looking_at(-face.normalized(), Vector3.UP), Vector3(pos.x, 1.5, pos.z))
	parent.add_child(d)
	return d

## Mean angular speed (rad/s) of a fighter's leg bodies (thighs, shins, feet).
static func leg_spin(f: Fighter) -> float:
	var sum := 0.0
	var n := 0
	for b: StringName in [Bones.L_UPPER_LEG, Bones.L_LOWER_LEG, Bones.L_FOOT, Bones.R_UPPER_LEG, Bones.R_LOWER_LEG, Bones.R_FOOT]:
		if f.rig.is_bone_severed(b):
			continue
		var av: Vector3 = PhysicsServer3D.body_get_state(f.rig.get_physical_bone(b).get_rid(),
			PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		sum += av.length()
		n += 1
	return sum / maxf(n, 1)

## Horizontal speed (m/s) of a fighter's capsule.
static func hspeed(f: Fighter) -> float:
	return Vector2(f.velocity.x, f.velocity.z).length()

static func flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

## Reset the global singletons between cases.
static func reset_world() -> void:
	ImpactResolver.reset()
	DebrisManager.reset()
	TimeDirector.reset()

static func state_name(f: Fighter) -> String:
	var names := ["ANIMATED", "FLINCH", "STAGGER", "LAUNCHED", "GROUNDED", "GETUP", "DEAD"]
	var s := f.get_state()
	return names[s] if s >= 0 and s < names.size() else str(s)
