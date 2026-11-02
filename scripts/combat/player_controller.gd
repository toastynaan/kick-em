class_name PlayerController
extends Node
## Reads the player's buttons through an InputInterpreter child and drives the
## parent Fighter. Movement is relative to the active Camera3D. Added as a
## child of the player Fighter by FighterFactory. OWNER: agent H (Upgrade 2).
## CONTRACT STUB: keep every public signature.
##
## Each physics tick, in this order (before the Fighter moves):
## 1. Stick -> fighter.move_input.
## 2. Movement and Focus buttons: crouch (hold), jump, Focus mode (a press).
##    They are in effect before any attack press of the same tick, so crouch +
##    kick reads as the sweep and jump + kick as the flying kick. Jump goes to
##    Traversal first (jump, wall run, kick-off), else Fighter.jump() (buffered
##    Tuning.JUMP_BUFFER_TIME).
## 3. Facing: the stick, or the soft target while blocking or charging (a
##    charge locks onto its target).
## 4. Zone aim (ZoneAim) on the soft target.
## 5. Combat buttons -> fighter.combat.press() / release() (Round 5 key map):
##    punch -> LIGHT, heavy -> HEAVY, kick -> KICK (B reads back + Kick as the
##    sweep from Fighter.get_input_intent), grab -> GRAB, block -> BLOCK (tap
##    to parry, hold to guard: Defence then B), dash -> DASH (Defence's
##    teleport / sidestep / pursuit, then Traversal's dash and sprint). What a
##    press means (tap, hold, charge, combo, variants) is CombatController's call.
##
## Punch / Kick / Grab auto-face the soft target, else the opponent nearest the
## stick (Targeting.pick_target) within AUTO_FACE_RANGE.
##
## Round 4 lock-on (the camera rig owns the lock: get_lock_target()): while
## locked the fighter always faces the target, turning at most LOCK_TURN_RATE,
## and the stick is read in the target's frame (W closes in, S backs off, A/D
## circle it; the rig keeps the camera behind the player looking at the
## target, so this is what the screen shows). Fighter slows the backpedal and
## the strafe. Attacks do not snap while locked. On unlock or a target change
## the facing keeps the cap until it has caught up (no snap).

const AUTO_FACE_RANGE := 4.0
const STICK_DEADZONE := 0.15
## m: a charge or a block turns toward an opponent this close.
const LOCK_RANGE := AUTO_FACE_RANGE * 2.0
## Player s a jump press waits for the fighter to be able to jump (landing
## recovery, the last frames of a move): the Feel Reference's jump buffer.
const JUMP_BUFFER := Tuning.JUMP_BUFFER_TIME
## rad/s: facing turn cap while locked on, and after an unlock or a target
## change until the facing has caught up (a 180-degree turn takes ~0.4 s).
const LOCK_TURN_RATE := 8.0
## The cap lifts once facing is this close to the wanted direction (cos ~8 deg)...
const LOCK_ALIGNED_DOT := 0.99
## ...and at least this long (player s) after the unlock or retarget, so a turn
## the player starts just after unlocking is still capped.
const LOCK_RELEASE_GRACE := 0.5

const BUTTONS := {
	&"punch": CombatController.Action.LIGHT,
	&"heavy": CombatController.Action.HEAVY,
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
var _lock: Fighter            ## lock-on target last tick
var _turn_capped := false     ## keep LOCK_TURN_RATE until the facing catches up
var _capped_at := 0.0         ## interpreter clock of the last unlock / retarget

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
		fighter.lock_target = null
		fighter.max_turn_rate = INF
		_lock = null
		_turn_capped = false
		_jump_until = -INF
		_charge_target = null
		for ev in events:
			if not ev.pressed and BUTTONS.has(ev.action) and not fighter.is_dead():
				c.release(BUTTONS[ev.action])  # nothing stays held while input is off
		zone_aim.clear()
		return
	var lock := get_lock_target()
	if lock != _lock:
		_turn_capped = true  # unlock or a new target: no snap, turn at the cap
		_capped_at = interpreter.now()
		_lock = lock
	fighter.lock_target = lock
	var stick := get_stick_world()
	fighter.move_input = stick

	# Movement and Focus first: attacks on this tick see the new stance.
	fighter.set_crouch_input(interpreter.is_held(&"crouch"))
	for ev in events:
		if not ev.pressed:
			continue
		match ev.action:
			&"jump":
				_jump_until = -INF
				if fighter.traversal != null and fighter.traversal.on_jump_pressed():
					pass  # Traversal took it (jump, wall run, kick-off)
				elif not fighter.is_traversal_driving():
					_jump_until = interpreter.now() + JUMP_BUFFER
			&"focus":
				fighter.begin_focus()  # Round 5: a press, 1 bar, 2 s of real time
	if _jump_until >= interpreter.now() and fighter.jump():
		_jump_until = -INF

	_update_facing(stick)
	_update_turn_cap()
	zone_aim.update(_aim_target(stick), delta, fighter.is_focusing(), lock)

	for ev in events:
		if not BUTTONS.has(ev.action):
			continue
		if ev.pressed:
			_press(BUTTONS[ev.action])
		else:
			c.release(BUTTONS[ev.action])

func _update_facing(stick: Vector3) -> void:
	var c := fighter.combat
	if _charge_target != null and not is_instance_valid(_charge_target):
		_charge_target = null  # freed (a body faded out)
	if _lock != null:
		_charge_target = _lock
		_face(_lock.get_ground_position() - fighter.global_position, false)
		return
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

## Turn to the strike target if free to (Feel Reference: Picking the target):
## Targeting.pick_strike_target along get_aim_dir() (the 60-degree cone, 4 m,
## 10 m while sprinting), the same pick CombatController makes, so the body
## turns to the enemy the strike will hit. Locked on: no snap (the fighter
## already turns toward the lock target).
func auto_face() -> void:
	if _lock != null:
		return
	var c := fighter.combat
	if c.is_attacking() and not c.is_in_recovery():
		return
	if not (fighter.can_act() or c.is_in_recovery()):
		return
	var sprinting := fighter.traversal != null and fighter.traversal.is_sprinting()
	var t := Targeting.pick_strike_target(fighter, get_aim_dir(), sprinting)
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

## The camera rig's lock-on target (Round 4), or null when free / no rig.
func get_lock_target() -> Fighter:
	var rig := get_tree().get_first_node_in_group(&"camera_rig")
	if rig == null or not rig.has_method(&"get_lock_target"):
		return null
	var t := rig.call(&"get_lock_target") as Fighter
	if t == null or not is_instance_valid(t) or t.is_dead() or t == fighter:
		return null
	return t

## Locked: always LOCK_TURN_RATE. After an unlock or a retarget: the cap stays
## until the facing has caught up with face_dir, then turning is free again.
func _update_turn_cap() -> void:
	if _lock != null:
		fighter.max_turn_rate = LOCK_TURN_RATE
		return
	if _turn_capped and interpreter.now() - _capped_at >= LOCK_RELEASE_GRACE:
		var want := Vector3(fighter.face_dir.x, 0.0, fighter.face_dir.z)
		if want.length_squared() < 1e-4 or fighter.get_forward().dot(want.normalized()) >= LOCK_ALIGNED_DOT:
			_turn_capped = false
	fighter.max_turn_rate = LOCK_TURN_RATE if _turn_capped else INF

## `o` may be a freed body (a corpse that faded out), hence Object.
func _valid_opponent(o: Variant, max_range: float) -> bool:
	if o == null or not is_instance_valid(o) or not (o is Fighter):
		return false
	var t := o as Fighter
	if t.is_dead() or t.is_down() or t.team == fighter.team:
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

## Stick/WASD direction in world XZ (camera-relative; locked on, relative to
## the direction to the target), length 0..1.
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

# --- Round 5 contract (agent H implements) --------------------------------------
## Round 5 (Feel Reference: Controls: Sweep is pull back + Kick, "back" is
## toward the camera): the stick against the camera, whatever way the fighter
## faces: &"back" (S / stick down, within 60 degrees), &"forward" (W / stick
## up), else &"neutral". Locked on, the stick is in the target's frame, where
## back is still toward the camera (away from the target).
func get_input_intent() -> StringName:
	if not enabled or not InputMap.has_action(&"move_back"):
		return &"neutral"
	var v := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back", STICK_DEADZONE)
	if v.length() < Fighter.INTENT_DEADZONE:
		return &"neutral"
	var d := v.normalized()
	if d.y >= Fighter.INTENT_DOT:
		return &"back"
	if d.y <= -Fighter.INTENT_DOT:
		return &"forward"
	return &"neutral"

## Strike aim (Feel Reference: Picking the target): the stick in world space, or
## camera forward when the stick is neutral. B passes it to Targeting.pick_strike_target.
## Neutral stick right after a parry or a teleport: toward the fighter the
## counter bonus came from (Defence.get_counter_target), so the counter lands on
## the one you beat even when the camera looks elsewhere. Locked on: toward the
## lock target.
func get_aim_dir() -> Vector3:
	var s := get_stick_world()
	if s.length() > STICK_DEADZONE:
		return s.normalized()
	var t: Fighter = null
	if fighter.defence != null:
		t = fighter.defence.get_counter_target()
	if t == null and _lock != null and is_instance_valid(_lock) and not _lock.is_dead():
		t = _lock
	if t != null:
		var to := t.get_ground_position() - fighter.get_ground_position()
		to.y = 0.0
		if to.length_squared() > 1e-4:
			return to.normalized()
	var f := -_camera_basis().z
	f.y = 0.0
	return f.normalized() if f.length_squared() > 1e-6 else fighter.get_forward()

## The enemy a sprint attack would hit right now (null when not sprinting or
## none): the HUD's corner-bracket marker.
func get_sprint_target() -> Fighter:
	if fighter == null or fighter.traversal == null or not fighter.traversal.is_sprinting():
		return null
	return Targeting.pick_strike_target(fighter, get_aim_dir(), true)

func _camera_basis() -> Basis:
	if _lock != null and is_instance_valid(_lock):
		var to := _lock.get_ground_position() - fighter.global_position
		to.y = 0.0
		if to.length_squared() > 1e-4:
			return Basis.looking_at(to.normalized(), Vector3.UP)
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
