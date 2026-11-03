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
##
## Round 8 (docs/Round 8 — Charge and Pressure.md):
## - Charging is CombatController's: a held strike button stays held here (only
##   its real release reaches combat.release()). While combat.is_charging(), the
##   stick walks but does not turn the body: it tracks the target B picked at
##   the press (combat.get_charge_target(); B also faces it in its own charge
##   tick, which runs after this); with no target the stick turns it as usual.
## - Jump with combat.get_air_follow_target() set (or right after the current
##   charged uppercut's hit lifted a body) is the launcher jump
##   (traversal.start_air_follow). If Traversal cannot start it yet (the
##   uppercut's active frames or hitstop), the press waits and retries every
##   tick until it starts or Tuning.R8_AIR_FOLLOW_WINDOW runs out, with no
##   normal jump meanwhile. With no body to follow, Jump is a normal jump.

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
var _follow_body: Fighter = null  ## Round 8: a launcher jump waiting to start (the uppercut's active frames, hitstop)
var _follow_until := -INF         ## interpreter clock after which that press is dropped

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
		_follow_body = null
		return
	var stick := get_stick_world()
	fighter.move_input = stick
	if c.is_charging():
		_face_charge_target(stick)
	elif stick.length() > STICK_DEADZONE:
		fighter.face_dir = stick.normalized()
	# Jump first: attacks on this tick see the take-off.
	var holding_body := fighter.carry != null and fighter.carry.is_holding_body()
	for ev in events:
		if ev.pressed and ev.action == &"jump" and not _layered_now(ev.action) and not holding_body:
			_jump_until = -INF
			if _air_follow_press():
				pass  # the launcher jump to the lifted body (Traversal): started or waiting
			elif fighter.traversal != null and fighter.traversal.on_jump_pressed():
				pass  # Traversal took it
			elif not fighter.is_traversal_driving():
				_jump_until = interpreter.now() + JUMP_BUFFER
	_retry_air_follow()
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

# --- Round 8 ----------------------------------------------------------------------
## A Jump press right after a charged uppercut's lift: the launcher jump to
## the lifted body. true when the press is taken for it (the leap started, or
## waits for the uppercut's active frames and hitstop to end: _retry_air_follow
## tries every tick); false when there is no body to follow (a normal jump).
func _air_follow_press() -> bool:
	if fighter.traversal == null:
		return false
	var t := _air_follow_target()
	if t == null:
		return false
	_follow_body = t
	_follow_until = interpreter.now() + Tuning.R8_AIR_FOLLOW_WINDOW
	_retry_air_follow()
	return true

## The waiting launcher jump: start it as soon as Traversal accepts (the
## uppercut's active frames are over); drop it once there is no body to follow
## any more (CombatController's follow window ran out, the body landed) or
## R8_AIR_FOLLOW_WINDOW after the press.
func _retry_air_follow() -> void:
	if _follow_body == null:
		return
	var t := _air_follow_target()
	if t == null or interpreter.now() > _follow_until:
		_follow_body = null
		return
	_follow_body = t
	if fighter.traversal.start_air_follow(t):
		_follow_body = null

## The body a Jump would follow: combat.get_air_follow_target(), else the body
## the current charged uppercut's hit has just lifted (its active frames or
## hitstop, before B's window opens), else null. Only a body still lifted.
func _air_follow_target() -> Fighter:
	var c := fighter.combat
	var t := c.get_air_follow_target()
	if t != null and is_instance_valid(t) and _followable(t):
		return t
	var hit := c.last_dealt
	if hit == null or not c.is_attacking() or c.current_move_id() != &"uppercut":
		return null
	if not hit.charged or hit.react != &"lift" or not is_instance_valid(hit.victim) or not (hit.victim is Fighter):
		return null
	var v := hit.victim as Fighter
	return v if _followable(v) else null

static func _followable(f: Fighter) -> bool:
	return f.is_lifted() and not f.is_dead() and not f.is_down() and not f.is_held()

## While a strike charges, the body turns (at its normal turn rate; B's
## can_turn() decides) toward the target B picked at the press; with no target
## the stick turns it as usual.
func _face_charge_target(stick: Vector3) -> void:
	var t := get_charge_target()
	if t != null:
		var d := t.get_ground_position() - fighter.global_position
		d.y = 0.0
		if d.length_squared() > 1e-4:
			fighter.face_dir = d.normalized()
			return
	if stick.length() > STICK_DEADZONE:
		fighter.face_dir = stick.normalized()

## The target the charging strike tracks: combat.get_charge_target() (null
## when not charging, none, or B does not expose it: B's own charge tick then
## does the facing).
func get_charge_target() -> Fighter:
	var c := fighter.combat
	if c == null or not c.is_charging() or not c.has_method(&"get_charge_target"):
		return null
	var v: Variant = c.call(&"get_charge_target")
	if v == null or not is_instance_valid(v) or not (v is Fighter):
		return null
	var t := v as Fighter
	return null if t.is_dead() else t

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
