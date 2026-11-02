class_name PlayerController
extends Node
## Reads the player's buttons through an InputInterpreter child and drives the
## parent Fighter. Movement is relative to the active Camera3D. Added as a
## child of the player Fighter by FighterFactory. OWNER: agent H (Upgrade 2).
## CONTRACT STUB: keep every public signature.
##
## Each physics tick, in this order (before the Fighter moves):
## 1. Stick -> fighter.move_input.
## 2. Movement and Focus buttons: crouch (hold), jump, Focus (hold). They are
##    in effect before any attack press of the same tick, so crouch + kick
##    reads as the sweep and jump + kick as the flying kick.
## 3. Facing: the stick, or the soft target while blocking or charging (a
##    charge locks onto its target).
## 4. Zone aim (ZoneAim) on the soft target.
## 5. Attack buttons -> fighter.combat.press() / release(): punch -> LIGHT,
##    kick -> KICK, grab -> GRAB, block -> BLOCK, dash -> DASH. What a press
##    means (tap, hold, charge, combo, crouch/jump/forward/back variants) is
##    CombatController's call.
##
## Punch / Kick / Grab auto-face the soft target, else the opponent nearest the
## stick (Targeting.pick_target) within AUTO_FACE_RANGE.

const AUTO_FACE_RANGE := 4.0
const STICK_DEADZONE := 0.15
## m: a charge or a block turns toward an opponent this close.
const LOCK_RANGE := AUTO_FACE_RANGE * 2.0
## Player s a jump press waits for the fighter to be able to jump (landing
## recovery, the last frames of a move).
const JUMP_BUFFER := 0.1

const BUTTONS := {
	&"punch": CombatController.Action.LIGHT,
	&"kick": CombatController.Action.KICK,
	&"grab": CombatController.Action.GRAB,
	&"block": CombatController.Action.BLOCK,
	&"dash": CombatController.Action.DASH,
}

var fighter: Fighter
## False freezes the player's input (menus, round over).
var enabled := true
## Press/release timestamps in player time (CombatController may read it).
var interpreter: InputInterpreter
var zone_aim: ZoneAim

var _charge_target: Fighter
var _jump_until := -INF

func _ready() -> void:
	fighter = get_parent() as Fighter
	fighter.brain = self
	# Read input before the Fighter moves in the same physics tick.
	process_physics_priority = -10
	interpreter = InputInterpreter.new()
	interpreter.name = "InputInterpreter"
	add_child(interpreter)
	zone_aim = ZoneAim.new(fighter)

func get_interpreter() -> InputInterpreter:
	return interpreter

func _physics_process(delta: float) -> void:
	if fighter == null or fighter.combat == null:
		return
	var live := enabled and not fighter.is_dead()
	var events := interpreter.poll(delta, live)
	var c := fighter.combat
	if not live:
		fighter.move_input = Vector3.ZERO
		fighter.set_crouch_input(false)
		fighter.end_focus()
		_jump_until = -INF
		_charge_target = null
		for ev in events:
			if not ev.pressed and BUTTONS.has(ev.action) and not fighter.is_dead():
				c.release(BUTTONS[ev.action])  # nothing stays held while input is off
		zone_aim.clear()
		return
	var stick := get_stick_world()
	fighter.move_input = stick

	# Movement and Focus first: attacks on this tick see the new stance.
	fighter.set_crouch_input(interpreter.is_held(&"crouch"))
	for ev in events:
		match ev.action:
			&"jump":
				if ev.pressed:
					_jump_until = interpreter.now() + JUMP_BUFFER
			&"focus":
				if ev.pressed:
					fighter.begin_focus()
				else:
					fighter.end_focus()
	if _jump_until >= interpreter.now() and fighter.jump():
		_jump_until = -INF

	_update_facing(stick)
	zone_aim.update(_aim_target(stick), delta, fighter.is_focusing())

	for ev in events:
		if not BUTTONS.has(ev.action):
			continue
		if ev.pressed:
			_press(BUTTONS[ev.action])
		else:
			c.release(BUTTONS[ev.action])

func _update_facing(stick: Vector3) -> void:
	var c := fighter.combat
	if c.is_charging():
		# The charge locks onto its target so the strike lands where it is aimed.
		if not _valid_opponent(_charge_target, LOCK_RANGE):
			_charge_target = _soft_target(LOCK_RANGE)
			if _charge_target == null:
				_charge_target = Targeting.pick_target(fighter, stick, LOCK_RANGE)
		if _charge_target != null:
			_face(_charge_target.get_ground_position() - fighter.global_position, false)
		return
	_charge_target = null
	if c.blocking:
		var t := Targeting.pick_target(fighter, stick, LOCK_RANGE)
		if t != null:
			_face(t.get_ground_position() - fighter.global_position, false)
	elif stick.length() > STICK_DEADZONE:
		fighter.face_dir = stick.normalized()

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

## The camera's soft target when it is a standing opponent within `max_range`.
func _soft_target(max_range := AUTO_FACE_RANGE) -> Fighter:
	var t := _camera_soft_target()
	return t if _valid_opponent(t, max_range) else null

func _camera_soft_target() -> Fighter:
	var rig := get_tree().get_first_node_in_group(&"camera_rig")
	if rig == null or not rig.has_method(&"get_soft_target"):
		return null
	return rig.call(&"get_soft_target") as Fighter

func _valid_opponent(t: Fighter, max_range: float) -> bool:
	if t == null or not is_instance_valid(t) or t.is_dead() or t.is_down() or t.team == fighter.team:
		return false
	var d := t.get_ground_position() - fighter.get_ground_position()
	d.y = 0.0
	return d.length() <= max_range

## Zone-aim target: the camera's soft target; without one (no camera rig, or
## only downed bodies near) the opponent nearest the stick within
## AUTO_FACE_RANGE, downed ones included (grabs on tumbling and downed bodies).
func _aim_target(stick: Vector3) -> Fighter:
	var t := _camera_soft_target()
	if t != null and is_instance_valid(t) and not t.is_dead() and t.team != fighter.team:
		return t
	return Targeting.pick_target(fighter, stick, AUTO_FACE_RANGE, true)

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
