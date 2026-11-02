extends Node3D
## Ragdoll lab (spec M1 acceptance scene): two dummies side by side, Jolt
## hard limits only (left) versus scripted soft limits + neutral tension
## (right), on a floor next to a wall. Built entirely in code.
## Keys: 1 drop both, 2 launch forward, 3 explosion between them, 4 launch at
## the wall, 5 toggle active/passive muscles, G get up, P cycle the right
## dummy's profile, S slow motion, R reset, Esc back to the menu.
## Round 5 (Feel Reference): L one arm limp while the rest animates (POSES
## dummy), 6-0 tier reactions on the POSES dummy, each with its contact-frame
## hitstop (6 jab to the head, 7 hook to the head, 8 stagger, 9 sweep, 0
## knockdown), T severing launch on a fresh dummy (loose limb + wound cap),
## Y hold the right dummy on a moving hand (legs dangle), U kill the left
## dummy (dead body: freezes after 4 s at rest).
## Wall range (F3 wall table, D's Destructible panels; watch it, D's
## tests/world/test_worked_example proves the numbers): Q picks drywall /
## brick / concrete, W picks the power P (5, 7, 9, 11), F launches a fresh 70 kg
## fighter straight into the panel at Power.launch_velocity(P), E rebuilds them.
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
## Pose browser (Upgrade 2): a third dummy in front plays every move and hold.
const POSE_POS := Vector3(0, 0, 2.6)
const AIR_MOVES: Array[StringName] = [&"flying_kick", &"hammer_fist"]
var poser: LabDummy
var _move_i := -1
var _hold_i := -1
var _shown := "-"
var _holds: Array[StringName] = []
# Round 5
const LIMP_ARM: Array[StringName] = [Bones.L_UPPER_ARM, Bones.L_LOWER_ARM]
const SEVER_POS := Vector3(-4.5, 0, 3.0)
var _limp_on := false
var _sever_dummy: LabDummy
var _hand: Node3D
var _hand_t := 0.0
var _last_reaction := "-"
# Wall range
const RANGE_SURFACES: Array[StringName] = [&"drywall", &"brick", &"concrete"]
const RANGE_X: Array[float] = [12.0, 16.0, 20.0]
const RANGE_PANEL_Z := -4.0
const RANGE_LAUNCH_Z := -0.5     ## launch spot: the body flies 3.5 m into the panel
const RANGE_P: Array[float] = [5.0, 7.0, 9.0, 11.0]
const RANGE_ARCHETYPE := &"thrower"   ## 70 kg, the body of the doc's wall table
## Loaded at run time so the lab never fails to compile while another
## module's file is mid-edit (Fighter pulls in all of combat).
const DESTRUCTIBLE_PATH := "res://scripts/world/destructible.gd"
const FACTORY_PATH := "res://scripts/game/fighter_factory.gd"
var _panels: Array[Node3D] = []
var _range_i := 0
var _range_p := 0
var _range_fighter: Node3D
var _range_result := "-"

func _ready() -> void:
	_build_world()
	left = _make_dummy(&"player", LEFT_POS, RagdollProfile.hard_limits_only())
	right = _make_dummy(&"player", RIGHT_POS, RagdollProfile.realistic())
	for d in [left, right]:
		d.ragdoll.auto_getup = false
	_label3d(left, "HARD LIMITS\n(Jolt only)")
	_label3d(right, "SOFT LIMITS +\nNEUTRAL TENSION")
	poser = _make_dummy(&"duelist", POSE_POS, RagdollProfile.realistic())
	poser.ragdoll.auto_getup = true
	_label3d(poser, "POSES")
	_holds.assign(PoseLibrary.ALL_HOLD_IDS)
	for id in PoseLibrary.CHARGEABLE:
		_holds.append(PoseLibrary.charge_hold_of(id))
	_hand = Node3D.new()
	_hand.name = "LabHand"
	add_child(_hand)
	_build_panels()
	GameEvents.wall_cracked.connect(func(w: Node3D, _p: Vector3, e: float) -> void:
		if w in _panels:
			_range_result = "%s cracked (%.0f J)" % [w.get(&"surface"), e])
	GameEvents.wall_broken.connect(func(w: Node3D, _p: Vector3, e: float, _v: Vector3) -> void:
		if w in _panels:
			_range_result = "%s BROKEN (%.0f J)" % [w.get(&"surface"), e])
	_build_ui()
	_reset()

## The lab "hand" for the hold demo: runs a loop with hops (Prototype 1, 0-6 s).
func _physics_process(delta: float) -> void:
	_hand_t += delta
	var a := _hand_t * 1.6
	var hop := maxf(0.0, sin(_hand_t * 2.4)) * 0.9
	_hand.global_position = RIGHT_POS + Vector3(cos(a) * 2.2, 1.45 + hop, sin(a) * 2.2 - 0.5)
	_hand.global_basis = Basis.looking_at(Vector3(-sin(a), 0, cos(a)), Vector3.UP)

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
		+ "Mouse drag or arrow keys: orbit   wheel or +/-: zoom\n" \
		+ "POSES dummy: N/B next/prev move  M replay  H next hold (incl. charges)  J release  V charge level  C crouch  Space jump  X break arm  Z heal\n" \
		+ "ROUND 5: L limp left arm (rest animated)   6 jab head  7 hook head  8 stagger  9 sweep  0 knockdown (with hitstop)   T severing launch   Y hold right dummy   U kill left dummy\n" \
		+ "WALL RANGE (x 12-20): Q panel   W power P   F launch a 70 kg body into it   E rebuild the panels"
	layer.add_child(help)
	status = Label.new()
	status.position = Vector2(16, 162)
	status.add_theme_font_size_override(&"font_size", 16)
	status.add_theme_color_override(&"font_outline_color", Color.BLACK)
	status.add_theme_constant_override(&"outline_size", 6)
	layer.add_child(status)

func _process(_delta: float) -> void:
	if status:
		var names := ["ANIMATED", "FLINCH", "STAGGER", "LAUNCHED", "GROUNDED", "GETUP", "DEAD"]
		var rc := poser.ragdoll
		var st := ""
		for b in [Bones.HEAD, Bones.SPINE, Bones.CHEST, Bones.L_UPPER_ARM, Bones.L_LOWER_ARM, Bones.R_UPPER_ARM,
				Bones.L_LOWER_LEG, Bones.R_LOWER_LEG]:
			st += "%s %.2f  " % [String(b).replace("Left", "L").replace("Right", "R"), rc.get_bone_strength(b)]
		var p: float = RANGE_P[_range_p]
		status.text = "muscles: %s   right profile: %s\nleft: %s%s   right: %s%s   (%.3f / %.3f ms per tick)\nposes: %s   stance %s   charge level %d   limp arm %s   last reaction %s (%s)\nstrength: %s\nloose limbs %d   awake corpses %d\nwall range: %s, P %.0f (%.1f m/s at %.0f deg)   last: %s" % [
			"ACTIVE" if _active else "PASSIVE", _right_profiles[_right_profile_i],
			names[left.ragdoll.state], " (settled)" if left.ragdoll.is_settled() else "",
			names[right.ragdoll.state], " (held)" if right.ragdoll.is_held() else "",
			left.ragdoll.last_tick_ms, right.ragdoll.last_tick_ms,
			_shown, poser.stance, poser.animator.charge_level, "ON" if _limp_on else "off", _last_reaction,
			names[rc.state], st, HumanoidRig.loose_limb_count(), RagdollController.awake_dead_count(),
			RANGE_SURFACES[_range_i], p, Power.launch_speed(p), Power.launch_angle(p), _range_result]

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
			KEY_N:
				_step_move(1)
			KEY_B:
				_step_move(-1)
			KEY_M:
				_step_move(0)
			KEY_H:
				_hold_i = (_hold_i + 1) % _holds.size()
				_shown = "hold " + String(_holds[_hold_i])
				if _holds[_hold_i] in [&"jump_rise", &"jump_fall", &"flying_kick_charge", &"hammer_fist_charge"]:
					poser.jump()
				poser.animator.hold_pose(_holds[_hold_i])
			KEY_J:
				poser.animator.release_pose()
				_shown = "-"
			KEY_V:
				poser.animator.set_charge_level((poser.animator.charge_level + 1) % 4)
			KEY_C:
				poser.stance = &"stand" if poser.stance == &"crouch" else &"crouch"
			KEY_SPACE:
				poser.jump()
			KEY_X:
				poser.ragdoll.break_arm(BodyZones.Zone.ARM_R)
			KEY_Z:
				poser.ragdoll.heal_arms()
			KEY_L:
				_limp_on = not _limp_on
				if _limp_on:
					poser.ragdoll.limp_chain(LIMP_ARM, 1.0, 0.0)
				else:
					poser.ragdoll.restore_chain(LIMP_ARM)
			KEY_6:
				_react(&"jab")
			KEY_7:
				_react(&"hook")
			KEY_8:
				_react(&"stagger")
			KEY_9:
				_react(&"sweep")
			KEY_0:
				_react(&"knockdown")
			KEY_T:
				_sever_demo()
			KEY_Y:
				if right.ragdoll.is_held():
					right.ragdoll.end_held()
				else:
					right.ragdoll.auto_getup = true
					right.ragdoll.begin_held(Bones.CHEST, _hand, null)
			KEY_U:
				left.ragdoll.kill(Vector3(0, 1.0, 2.0))
			KEY_Q:
				_range_i = (_range_i + 1) % RANGE_SURFACES.size()
			KEY_W:
				_range_p = (_range_p + 1) % RANGE_P.size()
			KEY_F:
				_range_launch()
			KEY_E:
				_build_panels()
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

func _step_move(step: int) -> void:
	var ids := PoseLibrary.all_move_ids()   # every move incl. Round 5 (stumble steps, fast get-up...)
	_move_i = wrapi(_move_i + step, 0, ids.size()) if _move_i >= 0 or step > 0 else ids.size() - 1
	var id: StringName = ids[_move_i]
	_shown = "move " + String(id)
	if id in AIR_MOVES:
		poser.jump()
	var tell := String(id).begins_with("e_")
	poser.animator.play_move(id, 0.5 if tell else 0.3, 0.15, 0.45)

## A tier reaction on the POSES dummy, hit from the camera side, then its
## contact-frame hitstop (B's order: reaction, then TimeDirector.hitstop).
func _react(kind: StringName) -> void:
	var d := poser
	var rc := d.ragdoll
	rc.auto_getup = true
	var into := d.global_basis.z      # from its front toward its back (it faces -basis.z)
	var tier := HitInfo.Tier.FLINCH
	match kind:
		&"jab":
			rc.flinch(into, Bones.HEAD, 1.0)
		&"hook":
			rc.flinch(d.global_basis.x * -1.0 + into * 0.3, Bones.HEAD, 1.0)
		&"stagger":
			tier = HitInfo.Tier.STAGGER
			rc.stagger(into, 0.75)
		&"sweep":
			tier = HitInfo.Tier.STUMBLE
			rc.stumble(d.global_basis.x, Bones.L_LOWER_LEG)
		&"knockdown":
			tier = HitInfo.Tier.KNOCKDOWN
			rc.set_getup_after(1.6)
			rc.knockdown(into, Bones.CHEST)
	TimeDirector.hitstop([d], Power.hitstop_for(tier))
	_last_reaction = String(kind)

## Severing launch on a fresh dummy: launch at P 9 speed, take the right arm.
func _sever_demo() -> void:
	if is_instance_valid(_sever_dummy):
		_sever_dummy.queue_free()
	_sever_dummy = _make_dummy(&"grunt", SEVER_POS, RagdollProfile.realistic())
	_sever_dummy.global_transform = Transform3D(Basis.looking_at(Vector3.BACK, Vector3.UP), SEVER_POS)
	_sever_dummy.ragdoll.auto_getup = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_instance_valid(_sever_dummy):
		return
	var p := 9.0
	_sever_dummy.ragdoll.launch(Power.launch_velocity(p, Vector3.FORWARD), _sever_dummy.global_position + Vector3.UP, Bones.R_LOWER_ARM)
	_sever_dummy.rig.sever(&"arm_r")
	TimeDirector.hitstop([_sever_dummy], Power.hitstop_for(HitInfo.Tier.SEVER))
	_last_reaction = "sever arm_r"

## Drywall, brick and concrete panels (D's Destructible, built as YardBuilder
## does), exterior face toward the launch spots.
func _build_panels() -> void:
	for d in _panels:
		if is_instance_valid(d):
			d.queue_free()
	_panels.clear()
	for i in RANGE_SURFACES.size():
		var d: Node3D = load(DESTRUCTIBLE_PATH).new()
		d.set(&"surface", RANGE_SURFACES[i])
		d.set(&"size", Vector3(3.0, 3.0, 0.25))
		d.name = "Range_" + String(RANGE_SURFACES[i])
		d.transform = Transform3D(Basis.looking_at(Vector3.FORWARD, Vector3.UP), Vector3(RANGE_X[i], 1.5, RANGE_PANEL_Z))
		add_child(d)
		_panels.append(d)
	_range_result = "-"

## A fresh 70 kg fighter launched straight at the selected panel with the
## launch velocity of power P (30 degrees up under P 7, 18 from P 7).
func _range_launch() -> void:
	if is_instance_valid(_range_fighter):
		_range_fighter.queue_free()
	var pos := Vector3(RANGE_X[_range_i], 0, RANGE_LAUNCH_Z)
	_range_fighter = load(FACTORY_PATH).spawn_dummy(self, RANGE_ARCHETYPE, Transform3D(Basis(), pos))
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_instance_valid(_range_fighter):
		return
	var p: float = RANGE_P[_range_p]
	_range_result = "flying (P %.0f)" % p
	_range_fighter.call(&"launch", Power.launch_velocity(p, Vector3.FORWARD), _range_fighter.call(&"get_center_of_mass"), Bones.CHEST)

func _both(f: Callable) -> void:
	for d in [left, right]:
		f.call(d)

func _reset() -> void:
	_limp_on = false
	for pair in [[left, LEFT_POS], [right, RIGHT_POS], [poser, POSE_POS]]:
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
