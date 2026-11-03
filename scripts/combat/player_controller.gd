class_name PlayerController
extends Node
## Reads the player's buttons through an InputInterpreter child and drives the
## parent Fighter. Movement is relative to the active Camera3D. Added as a
## child of the player Fighter by FighterFactory. OWNER: agent H (Upgrade 2).
## CONTRACT STUB: keep every public signature.
##
## Round 7 (docs/Round 7 — Freeflow Combat.md: Controls). Each physics tick,
## before the Fighter moves:
## 1. Stick -> fighter.move_input (camera-relative), and the facing when pushed.
## 2. Buttons -> fighter.combat.press() / release(), one button one action:
##    punch -> LIGHT, leg_kick -> LEG_KICK, gut_punch -> GUT_PUNCH,
##    uppercut -> UPPERCUT, front_kick -> FRONT_KICK, roundhouse -> ROUNDHOUSE,
##    grab -> GRAB, counter -> COUNTER, dash -> DASH. What a press means (the
##    punch string, hold for heavy, routing while holding a body) is
##    CombatController's call.
## 3. The pad's kick layer is resolved here first: while kick_layer (LT) is
##    held, punch / jump / gut_punch (X / A / B) mean Controls.KICK_LAYER's leg
##    kick / front kick / roundhouse. The release of a layered press maps to the same
##    action as its press, whatever LT did in between.
## 4. Jump (Space / pad A): Traversal first (on_jump_pressed), else
##    Fighter.jump(), buffered Tuning.JUMP_BUFFER_TIME. It runs before the
##    attack presses of the same tick. With LT held, pad A is the front kick
##    (Controls.KICK_LAYER), never a jump. No jump while holding a body.
## Strike and grab presses turn the body at once to the enemy the strike will
## hit (auto_face: the same Targeting.pick_freeflow_target pick B makes).
## Removed in Round 7: crouch, Focus mode, block, lock-on (strafing, turn
## caps), zone aiming.

const STICK_DEADZONE := 0.15
## Player s a jump press waits for the fighter to be able to jump (landing
## recovery, the last frames of a move): the Feel Reference's jump buffer.
const JUMP_BUFFER := Tuning.JUMP_BUFFER_TIME

const BUTTONS := {
	&"punch": CombatController.Action.LIGHT,
	&"leg_kick": CombatController.Action.LEG_KICK,
	&"gut_punch": CombatController.Action.GUT_PUNCH,
	&"uppercut": CombatController.Action.UPPERCUT,
	&"front_kick": CombatController.Action.FRONT_KICK,
	&"roundhouse": CombatController.Action.ROUNDHOUSE,
	&"grab": CombatController.Action.GRAB,
	&"counter": CombatController.Action.COUNTER,
	&"dash": CombatController.Action.DASH,
}
## Presses that turn the body to the freeflow target first (auto_face).
const FACING_ACTIONS: Array[int] = [CombatController.Action.LIGHT, CombatController.Action.LEG_KICK,
	CombatController.Action.GUT_PUNCH, CombatController.Action.UPPERCUT,
	CombatController.Action.FRONT_KICK, CombatController.Action.ROUNDHOUSE, CombatController.Action.GRAB]

var fighter: Fighter
## False freezes the player's input (menus, round over).
var enabled := true
## Press/release timestamps in player time (CombatController may read it).
var interpreter: InputInterpreter

var _layered := {}  ## raw action -> the action its accepted press resolved to (kick layer)
var _jump_until := -INF  ## interpreter clock until which a buffered jump may fire

func _ready() -> void:
	fighter = get_parent() as Fighter
	fighter.brain = self
	# Read input before the Fighter moves in the same physics tick.
	process_physics_priority = -10
	interpreter = InputInterpreter.new()
	interpreter.name = "InputInterpreter"
	add_child(interpreter)

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
		for ev in events:
			if ev.pressed:
				continue
			var a := _resolve_release(ev.action)
			if a >= 0 and not fighter.is_dead():
				c.release(a)  # nothing stays held while input is off
		_layered.clear()
		_jump_until = -INF
		return
	var stick := get_stick_world()
	fighter.move_input = stick
	if stick.length() > STICK_DEADZONE:
		fighter.face_dir = stick.normalized()
	# Jump first: attacks on this tick see the take-off.
	var holding_body := fighter.carry != null and fighter.carry.is_holding_body()
	for ev in events:
		if ev.pressed and ev.action == &"jump" and not _layered_now(ev.action) and not holding_body:
			_jump_until = -INF
			if fighter.traversal != null and fighter.traversal.on_jump_pressed():
				pass  # Traversal took it
			elif not fighter.is_traversal_driving():
				_jump_until = interpreter.now() + JUMP_BUFFER
	if _jump_until >= interpreter.now() and not holding_body and fighter.jump():
		_jump_until = -INF
	for ev in events:
		if ev.pressed:
			var a := _resolve_press(ev.action)
			if a >= 0:
				_press(a)
		else:
			var r := _resolve_release(ev.action)
			if r >= 0:
				c.release(r)

## The pad's kick layer turns a press of `raw` into a kick right now.
func _layered_now(raw: StringName) -> bool:
	return Controls.KICK_LAYER.has(raw) and interpreter.is_held(&"kick_layer")

## The action a press of `raw` means now (-1 for none, e.g. the kick layer
## itself or a plain jump), remembered so its release maps the same way.
func _resolve_press(raw: StringName) -> int:
	var id := raw
	if _layered_now(raw):
		id = Controls.KICK_LAYER[raw]
	if not BUTTONS.has(id):
		return -1
	_layered[raw] = id
	return BUTTONS[id]

## The action the release of `raw` lets go of: the one its press resolved to.
func _resolve_release(raw: StringName) -> int:
	var id: StringName = _layered.get(raw, raw)
	_layered.erase(raw)
	return BUTTONS.get(id, -1)

func _press(action: int) -> void:
	if action in FACING_ACTIONS:
		auto_face()
	fighter.combat.press(action)

## Turn at once to the enemy the strike will hit: the same pick B makes,
## Targeting.pick_freeflow_target(fighter, stick, combat target, camera
## forward). Only when free to act (a press during the fighter's own move is
## B's to drop or buffer) and never while holding a body (the throw aims itself).
func auto_face() -> void:
	var c := fighter.combat
	if c.is_attacking() or not fighter.can_act() or fighter.is_holding():
		return
	var t := Targeting.pick_freeflow_target(fighter, get_aim_dir(), c.get_combat_target(), get_camera_forward())
	if t != null:
		_face(t.get_ground_position() - fighter.global_position)

func _face(dir: Vector3) -> void:
	dir.y = 0.0
	if dir.length_squared() < 1e-4:
		return
	fighter.snap_facing(dir)

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

## Flat camera forward (world XZ unit vector; the fighter's forward without a camera).
func get_camera_forward() -> Vector3:
	var f := -_camera_basis().z
	f.y = 0.0
	return f.normalized() if f.length_squared() > 1e-6 else fighter.get_forward()

# --- Round 7 freeflow aim -------------------------------------------------------
## Round 7 freeflow aim: the camera-relative stick (world XZ, length 0..1),
## Vector3.ZERO when neutral. B passes it to Targeting.pick_freeflow_target
## with combat.get_combat_target() and get_camera_forward().
func get_aim_dir() -> Vector3:
	var s := get_stick_world()
	return s if s.length() > STICK_DEADZONE else Vector3.ZERO

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
