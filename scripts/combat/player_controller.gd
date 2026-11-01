class_name PlayerController
extends Node
## Reads Input actions (see Controls autoload) and drives the parent Fighter.
## Movement is relative to the active Camera3D. Added as a child of the player
## Fighter by FighterFactory. OWNER: agent B. CONTRACT STUB.
##
## Light / Kick / Heavy / Sweep / Grab auto-face the opponent nearest the stick
## (Targeting.pick_target) within AUTO_FACE_RANGE. While blocking or charging
## the player faces the soft target.

const AUTO_FACE_RANGE := 4.0
const STICK_DEADZONE := 0.15

const BUTTONS := {
	&"light": CombatController.Action.LIGHT,
	&"heavy": CombatController.Action.HEAVY,
	&"kick": CombatController.Action.KICK,
	&"sweep": CombatController.Action.SWEEP,
	&"grab": CombatController.Action.GRAB,
	&"block": CombatController.Action.BLOCK,
	&"dash": CombatController.Action.DASH,
}

var fighter: Fighter
## False freezes the player's input (menus, round over).
var enabled := true

func _ready() -> void:
	fighter = get_parent() as Fighter
	fighter.brain = self
	# Read input before the Fighter moves in the same physics tick.
	process_physics_priority = -10

func _physics_process(_delta: float) -> void:
	if fighter == null or fighter.combat == null:
		return
	if not enabled or fighter.is_dead():
		fighter.move_input = Vector3.ZERO
		return
	var stick := get_stick_world()
	fighter.move_input = stick
	var c := fighter.combat
	if c.blocking or c.is_charging():
		var t := Targeting.pick_target(fighter, stick, AUTO_FACE_RANGE * 2.0)
		if t != null:
			_face(t.get_ground_position() - fighter.global_position, false)
	elif stick.length() > STICK_DEADZONE:
		fighter.face_dir = stick.normalized()
	for action: StringName in BUTTONS:
		if not InputMap.has_action(action):
			continue
		if Input.is_action_just_pressed(action):
			_press(BUTTONS[action])
		if Input.is_action_just_released(action):
			c.release(BUTTONS[action])

func _press(action: int) -> void:
	if action in [CombatController.Action.LIGHT, CombatController.Action.HEAVY,
			CombatController.Action.KICK, CombatController.Action.SWEEP,
			CombatController.Action.GRAB]:
		auto_face()
	fighter.combat.press(action)

## Turn to the target nearest the stick (within AUTO_FACE_RANGE) if free to.
func auto_face() -> void:
	var c := fighter.combat
	if c.is_attacking() and not c.is_in_recovery():
		return
	if not (fighter.can_act() or c.is_in_recovery()):
		return
	var t := _soft_target()
	if t == null:
		t = Targeting.pick_target(fighter, get_stick_world(), AUTO_FACE_RANGE)
	if t != null:
		_face(t.get_ground_position() - fighter.global_position, true)

## The camera's soft target when it is a standing opponent within AUTO_FACE_RANGE.
func _soft_target() -> Fighter:
	var rig := get_tree().get_first_node_in_group(&"camera_rig")
	if rig == null or not rig.has_method(&"get_soft_target"):
		return null
	var t := rig.call(&"get_soft_target") as Fighter
	if t == null or not is_instance_valid(t) or t.is_dead() or t.is_down() or t.team == fighter.team:
		return null
	var d := t.get_ground_position() - fighter.get_ground_position()
	d.y = 0.0
	return t if d.length() <= AUTO_FACE_RANGE else null

func _face(dir: Vector3, instant: bool) -> void:
	dir.y = 0.0
	if dir.length_squared() < 1e-4:
		return
	if instant:
		fighter.snap_facing(dir)
	else:
		fighter.face_dir = dir.normalized()

## Stick/WASD direction in world XZ (camera-relative), length 0..1.
func get_stick_world() -> Vector3:
	if not InputMap.has_action(&"move_left"):
		return Vector3.ZERO
	var v := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back", STICK_DEADZONE)
	if v.length_squared() < 1e-6:
		return Vector3.ZERO
	var w := _camera_basis() * Vector3(v.x, 0.0, v.y)
	w.y = 0.0
	if w.length_squared() < 1e-6:
		return Vector3.ZERO
	return w.normalized() * minf(v.length(), 1.0)

func _camera_basis() -> Basis:
	var rig := get_tree().get_first_node_in_group(&"camera_rig")
	if rig != null and rig.has_method(&"get_flat_basis"):
		return rig.get_flat_basis()
	var cam := get_viewport().get_camera_3d() if get_viewport() else null
	if cam != null:
		var fwd := -cam.global_basis.z
		fwd.y = 0.0
		if fwd.length_squared() > 1e-4:
			return Basis.looking_at(fwd.normalized(), Vector3.UP)
	return Basis()
