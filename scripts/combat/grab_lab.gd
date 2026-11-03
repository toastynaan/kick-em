extends Node3D
## Grab Lab (Round 7): the test bench for grabs, the drive and the throw
## (Carry). The real player (PlayerController, Traversal, CameraRig) with the
## game's controls, dummy enemies, a drive lane (a drywall panel, then a brick
## panel, then a concrete wall), a bowling line and props. Built entirely in code.
##
## Game controls: WASD move, mouse camera, C grab / let go (a prop if no body
## is in reach), while holding: LMB throw (hold to wind up), RMB knee (x3),
## Shift drive (release to stop; the hold stays). Shift alone dodges / sprints.
## Lab keys: 1 stand the dummies back up, 2 knock the nearest dummy down,
## 3 kill the nearest dummy (a body to carry), 4 a grunt grabs you (e_grab:
## press C within 10 frames to break), 5 the heavy grabs and slams you,
## 6 three grunts in a line for bowling, 7 props by the player, 8 rebuild the
## drive lane and put a grunt in your hands facing it, R reset all, Esc back
## to the menu.
## The readout shows the carry state, hold time against R7_HOLD_MAX, the
## wind-up, the last throw (speed, wind-up, assist), the drive (speed, time),
## the last drive contact and end, and the last event.
## `-- demo` on the command line loops a scripted grab, drive and throw.
## OWNER: agent G.

const PLAYER_POS := Vector3(0.0, 0.0, 4.0)
const DUMMY_SPOTS: Array[Vector3] = [Vector3(0.0, 0.0, 2.9), Vector3(-2.5, 0.0, 1.5), Vector3(2.5, 0.0, 1.5)]
const HEAVY_SPOT := Vector3(-5.0, 0.0, 6.0)
const LINE_GAP := 1.3
## The drive lane runs toward +X from LANE_START: drywall at LANE_X[0], brick at
## LANE_X[1], a static concrete wall at LANE_X[2].
const LANE_START := Vector3(4.0, 0.0, 8.0)
const LANE_X: Array[float] = [9.0, 13.0, 17.0]
const DEMO_PERIOD := 8.0

var player: Fighter
var dummies: Array[Fighter] = []
var heavy: Fighter
var line: Array[Fighter] = []
var props: Array[ThrowableProp] = []
var camera_rig: CameraRig
var walls: Array[Node3D] = []
var help: Label
var status: Label
var _last_event := "-"
var _demo := false
var _demo_t := 0.0

func _ready() -> void:
	Carry.force_enabled = true
	_build_world()
	player = FighterFactory.spawn_player(self, Transform3D(Basis.looking_at(Vector3.FORWARD, Vector3.UP), PLAYER_POS))
	camera_rig = CameraRig.new()
	camera_rig.name = "CameraRig"
	camera_rig.target = player
	add_child(camera_rig)
	_build_ui()
	_demo = _demo or OS.get_cmdline_user_args().has("demo")
	GameEvents.body_bowled.connect(func(flyer: Node3D, victim: Node3D, energy: float, chain: int) -> void:
		_last_event = "%s bowled %s (%.0f J, chain %d)" % [flyer.name, victim.name, energy, chain])
	GameEvents.wall_broken_by.connect(func(flyer: Node3D, wall: Node3D, energy: float) -> void:
		_last_event = "%s broke %s (%.0f J)" % [flyer.name, wall.name, energy])
	GameEvents.wall_cracked.connect(func(wall: Node3D, _p: Vector3, energy: float) -> void:
		_last_event = "%s cracked (%.0f J)" % [wall.name, energy])
	GameEvents.grab_broken.connect(func(g: Node3D, v: Node3D, _r: bool) -> void:
		_last_event = "%s broke free of %s" % [v.name, g.name])
	GameEvents.drive_impact.connect(func(_h: Node3D, _v: Node3D, target: Node3D, _p: Vector3, speed: float, result: StringName) -> void:
		_last_event = "drive %s %s at %.1f m/s" % [result, target.name if target else "-", speed])
	GameEvents.drive_ended.connect(func(_h: Node3D, reason: StringName) -> void:
		_last_event += "  (drive ended: %s)" % reason)
	_reset()

# --- World and UI ---------------------------------------------------------------------
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
	var floor_body := _box_body("Floor", Vector3(80, 1, 80), Vector3(0, -0.5, 0), Color(0.33, 0.34, 0.36))
	floor_body.add_to_group(&"world_static")
	(floor_body.get_child(1) as MeshInstance3D).material_override = _checker_material()
	_build_lane()

## The drive lane: drywall (breaks at a run), brick (slams below ~10 m/s), concrete.
func _build_lane() -> void:
	for w in walls:
		if is_instance_valid(w):
			w.queue_free()
	walls.clear()
	for i in 2:
		var surf: StringName = [&"drywall", &"brick"][i]
		var d := Destructible.new()
		d.surface = surf
		d.name = "Panel_" + String(surf)
		d.transform = Transform3D(Basis.looking_at(Vector3.RIGHT, Vector3.UP), Vector3(LANE_X[i], 1.5, LANE_START.z))
		add_child(d)
		walls.append(d)
	var concrete := _box_body("Concrete", Vector3(0.6, 3.0, 4.0), Vector3(LANE_X[2], 1.5, LANE_START.z), Color(0.5, 0.48, 0.44))
	walls.append(concrete)

func _box_body(n: String, size: Vector3, pos: Vector3, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = n
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mi.material_override = mat
	body.add_child(mi)
	body.position = pos
	add_child(body)
	return body

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
	help.add_theme_font_size_override(&"font_size", 17)
	help.add_theme_color_override(&"font_outline_color", Color.BLACK)
	help.add_theme_constant_override(&"outline_size", 6)
	help.text = "GRAB LAB   C grab / let go (a prop if no body)   holding: LMB throw (hold to wind up)   RMB knee   Shift drive\n" \
		+ "WASD move   mouse camera   Shift dodge / sprint\n" \
		+ "1 stand dummies   2 knock nearest down   3 kill nearest   4 grunt grabs you   5 heavy slam   6 bowling line   7 props   8 drive lane   R reset   Esc menu"
	layer.add_child(help)
	status = Label.new()
	status.position = Vector2(16, 100)
	status.add_theme_font_size_override(&"font_size", 16)
	status.add_theme_color_override(&"font_outline_color", Color.BLACK)
	status.add_theme_constant_override(&"outline_size", 6)
	layer.add_child(status)

# --- Loop -------------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if _demo:
		_demo_step(delta)

func _process(_delta: float) -> void:
	if status == null or player == null:
		return
	var c := player.carry
	var lines: Array[String] = []
	lines.append(c.get_debug_text())
	var v := c.held as Fighter
	if v != null and is_instance_valid(v) and c.is_holding_body():
		lines.append("holding %s by the collar, motor %s, %.1f / %.1f s" % [v.name,
			"RagdollController.begin_held" if c.uses_ragdoll_motor() else "fallback pin",
			c.get_hold_time(), Tuning.R7_HOLD_MAX])
	lines.append("wind-up %.2f   last throw %.1f m/s (wind-up %.2f, assist %s)   grab: %s" % [c.get_throw_windup(),
		c.last_throw_velocity.length(), c.last_throw_windup,
		c.last_throw_assist.name if c.last_throw_assist != null and is_instance_valid(c.last_throw_assist) else "-",
		c.last_grab_result])
	lines.append("drive %s %.1f m/s %.1f s   last contact %s (%.0f J)   last end %s" % [
		"ON" if c.is_driving() else "off", c.get_drive_speed(), c.get_drive_time(),
		c.last_drive_result, c.last_drive_energy, c.last_drive_end])
	if c.is_held():
		lines.append("HELD by %s: C to break!" % c.get_holder().name)
	lines.append("last: " + _last_event)
	status.text = "\n".join(lines)

## Demo loop: grab the dummy in front, drive it 0.8 s toward the bowling
## line, stop, then wind up a full throw at the line, and reset.
func _demo_step(delta: float) -> void:
	var was := _demo_t
	_demo_t += delta
	var c := player.combat
	if _at(was, 0.4):
		_spawn_line()
	if _at(was, 0.8):
		c.press(CombatController.Action.GRAB)
		c.release(CombatController.Action.GRAB)
	if _at(was, 1.4):
		c.press(CombatController.Action.DASH)
	if _at(was, 2.2):
		c.release(CombatController.Action.DASH)
	if _at(was, 2.6):
		c.press(CombatController.Action.LIGHT)
	if _at(was, 2.6 + Tuning.R7_THROW_WINDUP_FULL + 0.05):
		c.release(CombatController.Action.LIGHT)
	if _demo_t >= DEMO_PERIOD:
		_reset()
		_demo_t = 0.0

func _at(was: float, t: float) -> bool:
	return was < t and _demo_t >= t

# --- Input --------------------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match (event as InputEventKey).keycode:
		KEY_1:
			_stand_dummies()
		KEY_2:
			var d := _nearest_dummy()
			if d and not d.is_down():
				d.knockdown(_away(d), Bones.CHEST)
		KEY_3:
			var d := _nearest_dummy()
			if d and not d.is_dead():
				d.apply_damage(d.hp + 1.0, &"lab")
		KEY_4:
			_enemy_grab(dummies[0], &"e_grab")
		KEY_5:
			_enemy_grab(heavy, &"e_grab_slam")
		KEY_6:
			_spawn_line()
		KEY_7:
			_spawn_props()
		KEY_8:
			_drive_setup()
		KEY_R:
			_reset()
		KEY_ESCAPE:
			Carry.force_enabled = false
			var td := get_node_or_null(^"/root/TimeDirector")
			if td and td.has_method(&"reset"):
				td.reset()
			get_tree().change_scene_to_file("res://scenes/main.tscn")

func _exit_tree() -> void:
	Carry.force_enabled = false

func _nearest_dummy() -> Fighter:
	var best: Fighter = null
	var best_d := INF
	for d: Fighter in dummies + line + ([heavy] if heavy else []):
		if d == null or not is_instance_valid(d) or (player.carry.held == d):
			continue
		var dist := d.get_ground_position().distance_to(player.global_position)
		if dist < best_d:
			best_d = dist
			best = d
	return best

func _away(d: Fighter) -> Vector3:
	var a := d.get_ground_position() - player.global_position
	a.y = 0.0
	return a.normalized() if a.length() > 0.05 else Vector3.FORWARD

## A dummy steps in front of the player and runs its grab move (the blue tell,
## then the hold: C within 10 frames breaks it).
func _enemy_grab(e: Fighter, move: StringName) -> void:
	if e == null or not is_instance_valid(e) or e.is_down() or player.carry.is_held() or player.is_down():
		return
	var fwd := player.get_forward()
	e.teleport_to(player.global_position + fwd * 1.0, -fwd)
	e.combat.start_enemy_attack(move, Tuning.frames(Tuning.ENEMY_STARTUP.get(move, 20.0)))

func _spawn_line() -> void:
	for f in line:
		if is_instance_valid(f):
			f.queue_free()
	line.clear()
	var fwd := player.get_forward()
	for i in 3:
		var p := player.global_position + fwd * (3.0 + LINE_GAP * i)
		line.append(FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis.looking_at(-fwd, Vector3.UP), p)))

func _spawn_props() -> void:
	for p in props:
		if is_instance_valid(p):
			p.queue_free()
	props.clear()
	var kinds: Array[StringName] = [&"brick", &"bottle", &"chair_leg", &"crate_small"]
	var right := player.get_forward().cross(Vector3.UP)
	for i in kinds.size():
		var at := player.global_position + right * (0.8 + 0.5 * i) + Vector3.UP * 0.3
		props.append(ThrowableProp.spawn(self, kinds[i], Transform3D(Basis(), at)))

## Rebuild the drive lane, stand the player at its start facing +X with the
## first dummy in its hands, and turn the camera down the lane.
func _drive_setup() -> void:
	if player.carry.is_holding():
		player.carry.drop(&"reset")
	_build_lane()
	var d := dummies[0] if not dummies.is_empty() else null
	if d == null or not is_instance_valid(d):
		return
	if d.ragdoll:
		d.ragdoll.force_recover()
	d.hp = d.max_hp
	player.teleport_to(LANE_START, Vector3.RIGHT)
	d.teleport_to(LANE_START + Vector3.RIGHT * 0.9, Vector3.LEFT)
	camera_rig.set(&"_yaw", atan2(-1.0, 0.0))
	player.carry.grab_now(d, &"", true)

func _stand_dummies() -> void:
	for f: Fighter in dummies + [heavy]:
		if f == null or not is_instance_valid(f):
			continue
		if f.is_dead():
			f.hp = f.max_hp
		if f.ragdoll:
			f.ragdoll.force_recover()
		f.hp = f.max_hp
	for i in dummies.size():
		dummies[i].teleport_to(DUMMY_SPOTS[i], PLAYER_POS - DUMMY_SPOTS[i])
	if heavy:
		heavy.teleport_to(HEAVY_SPOT, PLAYER_POS - HEAVY_SPOT)

func _reset() -> void:
	if player.carry.is_holding():
		player.carry.drop(&"reset")
	for f: Fighter in dummies + line + ([heavy] if heavy else []):
		if f != null and is_instance_valid(f):
			f.queue_free()
	dummies.clear()
	line.clear()
	for p in props:
		if is_instance_valid(p):
			p.queue_free()
	props.clear()
	for i in DUMMY_SPOTS.size():
		var d := FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis.looking_at(PLAYER_POS - DUMMY_SPOTS[i], Vector3.UP), DUMMY_SPOTS[i]))
		d.name = "Grunt" + "ABC"[i]
		dummies.append(d)
	heavy = FighterFactory.spawn_dummy(self, &"heavy", Transform3D(Basis.looking_at(PLAYER_POS - HEAVY_SPOT, Vector3.UP), HEAVY_SPOT))
	heavy.name = "Heavy"
	if player.ragdoll:
		player.ragdoll.force_recover()
	player.hp = player.max_hp
	player.teleport_to(PLAYER_POS, Vector3.FORWARD)
	camera_rig.set(&"_yaw", 0.0)
	_spawn_props()
	_last_event = "-"
