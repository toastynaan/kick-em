extends Node3D
## Ragdoll lab (spec M1 acceptance scene): two dummies side by side, Jolt
## hard limits only (left) versus scripted soft limits + neutral tension
## (right), on a floor next to a wall. Built entirely in code.
## Keys: 1 drop both, 2 launch forward, 3 explosion between them, 4 launch at
## the wall, 5 toggle active/passive muscles, G get up, P cycle the right
## dummy's profile, S slow motion, R reset, Esc back to the menu.
## OWNER: agent A.

const LEFT_POS := Vector3(-1.6, 0, 0)
const RIGHT_POS := Vector3(1.6, 0, 0)
const WALL_Z := -6.0

var left: LabDummy
var right: LabDummy
var help: Label
var status: Label
var cam: Camera3D
var _yaw := deg_to_rad(35.0)
var _pitch := deg_to_rad(-18.0)
var _dist := 9.0
var _target := Vector3(0, 0.9, -1.0)
var _active := true
var _right_profiles: Array[StringName] = [&"realistic", &"wacky"]
var _right_profile_i := 0

func _ready() -> void:
	_build_world()
	left = _make_dummy(&"player", LEFT_POS, RagdollProfile.hard_limits_only())
	right = _make_dummy(&"player", RIGHT_POS, RagdollProfile.realistic())
	for d in [left, right]:
		d.ragdoll.auto_getup = false
	_label3d(left, "HARD LIMITS\n(Jolt only)")
	_label3d(right, "SOFT LIMITS +\nNEUTRAL TENSION")
	_build_ui()
	_reset()

func _make_dummy(archetype: StringName, pos: Vector3, profile: RagdollProfile) -> LabDummy:
	var d := LabDummy.new()
	d.name = "Dummy"
	d.setup(archetype, profile, _active)
	d.position = pos
	add_child(d)
	return d

func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.18, 0.22)
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
	# Floor
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
	# Wall
	var wall := StaticBody3D.new()
	wall.name = "Wall"
	wall.collision_layer = Layers.WORLD
	wall.collision_mask = 0
	var ws := CollisionShape3D.new()
	var wb := BoxShape3D.new()
	wb.size = Vector3(10, 3, 0.4)
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
	wall.position = Vector3(0, 1.5, WALL_Z)
	add_child(wall)
	cam = Camera3D.new()
	cam.fov = 55.0
	add_child(cam)
	_update_camera()

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

func _label3d(d: LabDummy, text: String) -> void:
	var l := Label3D.new()
	l.text = text
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.position = Vector3(0, 2.25, 0)
	l.font_size = 36
	l.outline_size = 8
	l.modulate = Color(1, 0.95, 0.8)
	l.no_depth_test = true
	d.add_child(l)

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	help = Label.new()
	help.position = Vector2(16, 12)
	help.add_theme_font_size_override(&"font_size", 18)
	help.add_theme_color_override(&"font_outline_color", Color.BLACK)
	help.add_theme_constant_override(&"outline_size", 6)
	help.text = "RAGDOLL LAB   left: Jolt hard limits only   right: soft limits + neutral tension (+ muscles)\n" \
		+ "1 drop (go limp)   2 launch forward   3 explosion between them   4 launch into the wall\n" \
		+ "5 toggle active/passive muscles   G get up   P cycle right profile   S slow motion   R reset   Esc menu\n" \
		+ "Mouse drag or arrow keys: orbit   wheel or +/-: zoom"
	layer.add_child(help)
	status = Label.new()
	status.position = Vector2(16, 120)
	status.add_theme_font_size_override(&"font_size", 16)
	status.add_theme_color_override(&"font_outline_color", Color.BLACK)
	status.add_theme_constant_override(&"outline_size", 6)
	layer.add_child(status)

func _process(_delta: float) -> void:
	if status:
		var names := ["ANIMATED", "FLINCH", "STAGGER", "LAUNCHED", "GROUNDED", "GETUP", "DEAD"]
		status.text = "muscles: %s   right profile: %s\nleft: %s   right: %s   (%.3f / %.3f ms per tick)" % [
			"ACTIVE" if _active else "PASSIVE", _right_profiles[_right_profile_i],
			names[left.ragdoll.state], names[right.ragdoll.state], left.ragdoll.last_tick_ms, right.ragdoll.last_tick_ms]

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT or event.button_mask & MOUSE_BUTTON_MASK_RIGHT):
		_yaw -= event.relative.x * 0.006
		_pitch = clampf(_pitch - event.relative.y * 0.006, deg_to_rad(-80), deg_to_rad(10))
		_update_camera()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(_dist * 0.9, 2.5)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(_dist * 1.1, 30.0)
			_update_camera()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				_both(func(d: LabDummy) -> void: d.ragdoll.launch(Vector3.ZERO, d.global_position + Vector3.UP, Bones.CHEST))
			KEY_2:
				_both(func(d: LabDummy) -> void:
					var fwd := -d.global_basis.z
					d.ragdoll.launch(fwd * 8.0 + Vector3.UP * 2.5, d.rig.get_bone_global_position(Bones.CHEST), Bones.CHEST))
			KEY_3:
				var c := (left.global_position + right.global_position) * 0.5 + Vector3(0, 0.6, 0)
				_both(func(d: LabDummy) -> void:
					var away := d.rig.get_bone_global_position(Bones.CHEST) - c
					away.y = 0.0
					d.ragdoll.launch(away.normalized() * 9.0 + Vector3.UP * 3.5, c, Bones.CHEST))
			KEY_4:
				_both(func(d: LabDummy) -> void:
					d.ragdoll.launch(Vector3(0, 2.0, -12.0), d.rig.get_bone_global_position(Bones.CHEST), Bones.CHEST))
			KEY_5:
				_active = not _active
				for d in [left, right]:
					d.ragdoll.active_muscles = _active
			KEY_G:
				_both(func(d: LabDummy) -> void:
					if d.ragdoll.state == RagdollController.State.GROUNDED:
						d.ragdoll.start_getup()
					elif d.ragdoll.state == RagdollController.State.LAUNCHED:
						d.ragdoll.auto_getup = true)
			KEY_P:
				_right_profile_i = (_right_profile_i + 1) % _right_profiles.size()
				right.ragdoll.set_profile(RagdollProfile.wacky() if _right_profiles[_right_profile_i] == &"wacky" else RagdollProfile.realistic())
			KEY_S:
				var td := get_node_or_null(^"/root/TimeDirector")
				if td:
					td.request_slowmo(0.25, 2.0, 1)
			KEY_R:
				_reset()
			KEY_ESCAPE:
				var td := get_node_or_null(^"/root/TimeDirector")
				if td and td.has_method(&"reset"):
					td.reset()
				get_tree().change_scene_to_file("res://scenes/main.tscn")
			KEY_LEFT:
				_yaw += 0.15
				_update_camera()
			KEY_RIGHT:
				_yaw -= 0.15
				_update_camera()
			KEY_UP:
				_pitch = clampf(_pitch - 0.1, deg_to_rad(-80), deg_to_rad(10))
				_update_camera()
			KEY_DOWN:
				_pitch = clampf(_pitch + 0.1, deg_to_rad(-80), deg_to_rad(10))
				_update_camera()
			KEY_EQUAL, KEY_KP_ADD:
				_dist = maxf(_dist * 0.9, 2.5)
				_update_camera()
			KEY_MINUS, KEY_KP_SUBTRACT:
				_dist = minf(_dist * 1.1, 30.0)
				_update_camera()

func _both(f: Callable) -> void:
	for d in [left, right]:
		f.call(d)

func _reset() -> void:
	for pair in [[left, LEFT_POS], [right, RIGHT_POS]]:
		var d: LabDummy = pair[0]
		d.ragdoll.force_recover()
		d.ragdoll.auto_getup = false
		d.global_transform = Transform3D(Basis.looking_at(Vector3.BACK, Vector3.UP), pair[1])
		d.velocity = Vector3.ZERO
		d.reset_physics_interpolation()
		d.animator.reset_pose()

func _update_camera() -> void:
	if cam == null:
		return
	var dir := Vector3(sin(_yaw) * cos(_pitch), -sin(_pitch), cos(_yaw) * cos(_pitch))
	cam.global_position = _target + dir * _dist
	cam.look_at(_target, Vector3.UP)
