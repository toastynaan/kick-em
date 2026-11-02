extends Node3D
## Grab lab (Upgrade 2 U5 spike scene): a player-team grabber in the middle of
## three grunts, for limb grabs. Built entirely in code.
## Keys: 1 arm drag (A's right arm), 2 arm drag (left arm), 3 giant swing
## (knocks A down first, grabs the legs once A lies still), Space release toward
## the camera, X drop, B break free, T auto-swing on/off, A/D or left/right or
## mouse drag: turn the camera (the swing follows the camera yaw), M cycle the
## hold method (PIN / SIX_DOF / PULL), V bone velocity clamp on/off, [ ] swing
## rate limit, R reset, Esc back to the menu.
## The readout shows the grip stretch (hand to wrist), the ragdoll's worst
## joint gap, peak bone speeds, NaN ticks and the last bowl.
## `-- demo` on the command line loops: arm drag, auto-swing, release, reset.
## OWNER: agent G.

const GRABBER_POS := Vector3.ZERO
const ENEMY_SPOTS: Array[Vector3] = [Vector3(0, 0, -1.0), Vector3(-1.6, 0, 0.2), Vector3(0.3, 0, 1.8)]
const WALL_X := 5.0
const CAM_TURN := 2.2   ## rad/s camera yaw on A/D

var grabber: Fighter
var enemies: Array[Fighter] = []
var grab: LimbGrab
var cam: Camera3D
var help: Label
var status: Label
var _yaw := 0.0
var _pitch := deg_to_rad(-28.0)
var _dist := 6.5
var _auto := false
var _pending_legs := false
var _last_bowl := "-"
var _peak_gap := 0.0
var _hand_mesh: MeshInstance3D
var _line: MeshInstance3D
var _line_mesh := ImmediateMesh.new()
var _line_mat := StandardMaterial3D.new()
var _demo := false
var _demo_t := 0.0

func _ready() -> void:
	_build_world()
	grabber = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), GRABBER_POS), Fighter.TEAM_PLAYER)
	for i in ENEMY_SPOTS.size():
		var e := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis(), ENEMY_SPOTS[i]), Fighter.TEAM_ENEMY)
		e.name = "Grunt" + "ABC"[i]
		enemies.append(e)
	_build_ui()
	_demo = OS.get_cmdline_user_args().has("demo")
	GameEvents.body_bowled.connect(func(flyer: Node3D, victim: Node3D, energy: float, chain: int) -> void:
		_last_bowl = "%s bowled %s: %.0f J (chain %d)" % [flyer.name, victim.name, energy, chain])
	_reset()

# --- World and UI -----------------------------------------------------------------
func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.15, 0.17, 0.2)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.58, 0.65)
	e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_layer = Layers.WORLD
	floor_body.collision_mask = 0
	var fs := CollisionShape3D.new()
	var fb := BoxShape3D.new()
	fb.size = Vector3(60, 1, 60)
	fs.shape = fb
	fs.position = Vector3(0, -0.5, 0)
	floor_body.add_child(fs)
	var fm := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	fm.mesh = plane
	fm.material_override = _checker_material()
	floor_body.add_child(fm)
	add_child(floor_body)
	var wall := StaticBody3D.new()
	wall.name = "Wall"
	wall.collision_layer = Layers.WORLD
	wall.collision_mask = 0
	var ws := CollisionShape3D.new()
	var wb := BoxShape3D.new()
	wb.size = Vector3(0.4, 3, 10)
	ws.shape = wb
	wall.add_child(ws)
	var wm := MeshInstance3D.new()
	var wbm := BoxMesh.new()
	wbm.size = wb.size
	wm.mesh = wbm
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = Color(0.62, 0.55, 0.5)
	wm.material_override = wmat
	wall.add_child(wm)
	wall.position = Vector3(WALL_X, 1.5, 0)
	add_child(wall)
	cam = Camera3D.new()
	cam.fov = 60.0
	add_child(cam)
	cam.make_current()
	# Hand marker and hand-to-grip line (the stretch, visible).
	_hand_mesh = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.05
	sm.height = 0.1
	_hand_mesh.mesh = sm
	var hm := StandardMaterial3D.new()
	hm.albedo_color = Color(1.0, 0.85, 0.2)
	hm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hm.no_depth_test = true
	_hand_mesh.material_override = hm
	_hand_mesh.visible = false
	add_child(_hand_mesh)
	_line_mat.albedo_color = Color(1.0, 0.2, 0.2)
	_line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_mat.no_depth_test = true
	_line = MeshInstance3D.new()
	_line.mesh = _line_mesh
	_line.material_override = _line_mat
	add_child(_line)

func _checker_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode diffuse_burley;
void fragment() {
	vec3 w = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float c = mod(floor(w.x) + floor(w.z), 2.0);
	ALBEDO = mix(vec3(0.30, 0.31, 0.33), vec3(0.38, 0.39, 0.41), c);
	ROUGHNESS = 0.9;
}"""
	var m := ShaderMaterial.new()
	m.shader = sh
	return m

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	help = Label.new()
	help.position = Vector2(16, 12)
	help.add_theme_font_size_override(&"font_size", 18)
	help.add_theme_color_override(&"font_outline_color", Color.BLACK)
	help.add_theme_constant_override(&"outline_size", 6)
	help.text = "GRAB LAB   limb grabs: the hand is a jointed anchor, the body is real physics\n" \
		+ "1 arm drag (right arm)   2 arm drag (left arm)   3 giant swing (knock down, then grab the legs)\n" \
		+ "A/D, arrows or mouse drag: turn the camera = swing   T auto-swing   Space release toward the camera   X drop   B break free\n" \
		+ "M hold method   V bone velocity clamp   [ ] swing rate limit   R reset   Esc menu"
	layer.add_child(help)
	status = Label.new()
	status.position = Vector2(16, 150)
	status.add_theme_font_size_override(&"font_size", 16)
	status.add_theme_color_override(&"font_outline_color", Color.BLACK)
	status.add_theme_constant_override(&"outline_size", 6)
	layer.add_child(status)

# --- Loop -------------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		_yaw += CAM_TURN * delta
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		_yaw -= CAM_TURN * delta
	if _demo:
		_demo_step(delta)
	if _auto:
		_yaw += LimbGrab.swing_rate_max * delta
	if _pending_legs:
		var a := enemies[0]
		if a.get_state() == RagdollController.State.GROUNDED:
			_pending_legs = false
			_start(BodyZones.Zone.LEGS)
	if grab and is_instance_valid(grab) and grab.is_active():
		_peak_gap = maxf(_peak_gap, _joint_gap(grab.victim))
	_update_camera()

## Demo loop: grab at 0.5 s, auto-swing, release toward the camera at 2.3 s, reset at 5 s.
func _demo_step(delta: float) -> void:
	var was := _demo_t
	_demo_t += delta
	if was < 0.5 and _demo_t >= 0.5:
		_start(BodyZones.Zone.ARM_R)
		_auto = true
	elif was < 2.3 and _demo_t >= 2.3:
		_auto = false
		if _active():
			grab.release(-cam.global_basis.z)
	elif _demo_t >= 5.0:
		_reset()
		_demo_t = 0.0

## Largest gap (m) between where a ragdoll joint sits on its child body and on
## its parent body: the ragdoll's own joints coming apart.
static func _joint_gap(f: Fighter) -> float:
	var rig := f.rig
	var worst := 0.0
	for b in Bones.PHYSICAL:
		if b == Bones.HIPS or rig.is_bone_severed(b):
			continue
		var p: StringName = Bones.PARENT[b]
		var xc: Transform3D = PhysicsServer3D.body_get_state(rig.get_physical_bone(b).get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
		var xp: Transform3D = PhysicsServer3D.body_get_state(rig.get_physical_bone(p).get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
		var on_child := (xc * rig.get_body_offset(b).affine_inverse()).origin
		var rest := HumanoidRig.scaled(HumanoidRig.REST[b], rig.height_scale, rig.width_scale)
		worst = maxf(worst, on_child.distance_to(xp * rig.get_body_offset(p).affine_inverse() * rest))
	return worst

func _process(_delta: float) -> void:
	_draw_grip()
	if status == null:
		return
	var names := ["ANIMATED", "FLINCH", "STAGGER", "LAUNCHED", "GROUNDED", "GETUP", "DEAD"]
	var lines: Array[String] = []
	lines.append("method %s   bone clamp %s   swing rate limit %.1f rad/s   auto-swing %s" % [
		["PIN", "SIX_DOF", "PULL"][LimbGrab.method], "on" if LimbGrab.clamp_bones else "off",
		LimbGrab.swing_rate_max, "on" if _auto else "off"])
	if grab and is_instance_valid(grab) and grab.is_active():
		var v := grab.get_swing_velocity()
		lines.append("%s on %s (%s): held %.1f s   stretch %.3f m (peak %.3f)   joint gap peak %.3f m" % [
			"GIANT SWING" if grab.kind == LimbGrab.Kind.GIANT_SWING else "ARM DRAG", grab.victim.name, grab.bone,
			grab.get_held_time(), grab.get_stretch(), grab.peak_stretch, _peak_gap])
		lines.append("swing %.1f rad/s   body COM %.1f m/s   bone peak %.1f m/s %.1f rad/s   NaN ticks %d" % [
			grab.get_swing_rate(), v.length(), grab.peak_bone_speed, grab.peak_bone_spin, grab.nan_ticks])
	else:
		lines.append("no grab")
	var st := ""
	for e in enemies:
		st += "%s %s   " % [e.name, names[e.get_state()] if e.get_state() < names.size() else "?"]
	lines.append(st)
	lines.append("last bowl: " + _last_bowl)
	status.text = "\n".join(lines)

func _draw_grip() -> void:
	_line_mesh.clear_surfaces()
	var on := grab != null and is_instance_valid(grab) and grab.is_active()
	_hand_mesh.visible = on
	if not on:
		return
	_hand_mesh.global_position = grab.get_hand_position(0)
	_line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in grab.get_grip_count():
		_line_mesh.surface_add_vertex(grab.get_hand_position(i))
		_line_mesh.surface_add_vertex(grab.get_grip_point(i))
		_line_mesh.surface_add_vertex(grabber.global_position + Vector3.UP * 1.1)
		_line_mesh.surface_add_vertex(grab.get_hand_position(i))
	_line_mesh.surface_end()

# --- Input --------------------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT or event.button_mask & MOUSE_BUTTON_MASK_RIGHT):
		_yaw -= event.relative.x * 0.006
		_pitch = clampf(_pitch - event.relative.y * 0.004, deg_to_rad(-70), deg_to_rad(-5))
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(_dist * 0.9, 2.5)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(_dist * 1.1, 20.0)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				_start(BodyZones.Zone.ARM_R)
			KEY_2:
				_start(BodyZones.Zone.ARM_L)
			KEY_3:
				_knock_down_then_legs()
			KEY_SPACE:
				if _active():
					grab.release(-cam.global_basis.z)
			KEY_X:
				if _active():
					grab.drop()
			KEY_B:
				if _active():
					grab.break_free()
			KEY_T:
				_auto = not _auto
			KEY_M:
				LimbGrab.method = (LimbGrab.method + 1) % 3
			KEY_V:
				LimbGrab.clamp_bones = not LimbGrab.clamp_bones
			KEY_BRACKETLEFT:
				LimbGrab.swing_rate_max = maxf(LimbGrab.swing_rate_max - 1.0, 1.0)
			KEY_BRACKETRIGHT:
				LimbGrab.swing_rate_max = minf(LimbGrab.swing_rate_max + 1.0, 14.0)
			KEY_R:
				_reset()
			KEY_ESCAPE:
				_restore_statics()
				var td := get_node_or_null(^"/root/TimeDirector")
				if td and td.has_method(&"reset"):
					td.reset()
				get_tree().change_scene_to_file("res://scenes/main.tscn")

func _exit_tree() -> void:
	_restore_statics()

func _restore_statics() -> void:
	LimbGrab.method = LimbGrab.Method.PIN
	LimbGrab.swing_rate_max = LimbGrab.SWING_RATE_MAX
	LimbGrab.clamp_bones = true

func _active() -> bool:
	return grab != null and is_instance_valid(grab) and grab.is_active()

func _start(zone: int) -> void:
	if _active():
		return
	var a := enemies[0]
	if not LimbGrab.can_grip(grabber, a, zone):
		_last_bowl = "can_grip refused (%s on %s, state %d)" % [BodyZones.name_of(zone), a.name, a.get_state()]
		return
	_peak_gap = 0.0
	grab = LimbGrab.start(grabber, a, zone)

func _knock_down_then_legs() -> void:
	if _active():
		return
	var a := enemies[0]
	if a.is_down():
		_start(BodyZones.Zone.LEGS)
		return
	var away := a.global_position - grabber.global_position
	away.y = 0.0
	a.launch(away.normalized() * 2.0 + Vector3.UP * 1.5, a.get_center_of_mass(), Bones.CHEST)
	_pending_legs = true

func _reset() -> void:
	if _active():
		grab.drop()
	grab = null
	_pending_legs = false
	_auto = false
	_last_bowl = "-"
	for f in [grabber] + enemies:
		var fi: Fighter = f
		if fi.ragdoll:
			fi.ragdoll.force_recover()
	grabber.teleport_to(GRABBER_POS, Vector3.FORWARD)
	for i in enemies.size():
		var to := GRABBER_POS - ENEMY_SPOTS[i]
		enemies[i].teleport_to(ENEMY_SPOTS[i], to)
		enemies[i].hp = enemies[i].max_hp
		if enemies[i].animator:
			enemies[i].animator.reset_pose()
	_yaw = 0.0

func _update_camera() -> void:
	if cam == null or grabber == null:
		return
	var target := grabber.global_position + Vector3.UP * 1.0
	# Behind the grabber's swing: the camera's forward yaw is _yaw.
	var back := Vector3(sin(_yaw), 0.0, cos(_yaw))
	var dir := back * cos(_pitch) + Vector3.UP * -sin(_pitch)
	cam.global_position = target + dir * _dist
	cam.look_at(target, Vector3.UP)
