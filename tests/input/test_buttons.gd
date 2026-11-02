extends "res://tests/input/input_test_base.gd"
## Key map and InputInterpreter: a tap reaches combat, press/release pairs,
## player-time stamps, presses made while Cmd is held are dropped (with their
## release), crouch on the same tick as an attack press is already in effect,
## and disabling the controller lets go of held buttons.

var _starts: Array[StringName] = []
var _crouched_at_start: Array[bool] = []

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	await ticks(30)
	var pc := p.brain as PlayerController
	check(pc != null and pc.interpreter != null, "player has a PlayerController with an InputInterpreter")
	if pc == null:
		done()
		return
	var interp := pc.interpreter
	p.combat.attack_started.connect(func(id: StringName) -> void:
		_starts.append(id)
		_crouched_at_start.append(p.is_crouching()))

	# --- A tap reaches combat (press, then release one tick later). ----------
	var t0 := interp.now()
	press(&"punch")
	await ticks(1)
	release(&"punch")
	await ticks(2)
	check(_starts.size() >= 1, "punch tap starts an attack (%s)" % [_starts])
	check(interp.last_press_time(&"punch") >= t0, "punch press stamped in player time")
	var held := interp.last_hold(&"punch")
	check(held > 0.0 and held < 0.05, "tap hold time is about one tick (%.4f s)" % held)
	await _settle(p)

	# --- Kick and grab buttons reach combat too. -----------------------------
	_starts.clear()
	press(&"kick")
	await ticks(1)
	release(&"kick")
	await ticks(2)
	check(_starts.size() >= 1, "kick tap starts an attack (%s)" % [_starts])
	await _settle(p)

	# --- Block: press holds the guard, release drops it (release reaches combat).
	press(&"block")
	await ticks(4)
	check(p.combat.is_blocking(), "block held -> guarding")
	release(&"block")
	await ticks(3)
	check(not p.combat.is_blocking(), "block released -> guard down")

	# --- Hold time in player seconds. -----------------------------------------
	press(&"block")
	await ticks(36)
	release(&"block")
	await ticks(1)
	var hold := interp.last_hold(&"block")
	check(near(hold, 0.3, 0.05), "a 36-tick hold reads 0.3 s (%.3f)" % hold)
	await ticks(3)

	# --- Cmd held: the press is dropped, and so is its release. ---------------
	_starts.clear()
	var dropped0 := interp.dropped_presses
	_key(KEY_META, true)
	await ticks(2)
	check(InputInterpreter.is_meta_held(), "Cmd (meta) reads as held")
	press(&"grab")
	await ticks(3)
	check(interp.dropped_presses == dropped0 + 1, "Cmd + grab press dropped (dropped=%d)" % interp.dropped_presses)
	check(not interp.is_held(&"grab"), "dropped grab is not held")
	check(_starts.is_empty() and not p.combat.is_attacking(), "Cmd + F did not grab")
	_key(KEY_META, false)
	await ticks(2)
	check(not interp.is_held(&"grab"), "letting go of Cmd while F is down does not revive the press")
	release(&"grab")
	await ticks(2)
	check(interp.last_release_time(&"grab") < 0.0, "the dropped press's release was dropped too")

	# A raw key event that carries the Cmd modifier is dropped as well.
	var dropped1 := interp.dropped_presses
	_key(KEY_F, true, true)
	await ticks(3)
	check(interp.dropped_presses == dropped1 + 1, "F event with meta_pressed dropped")
	check(_starts.is_empty(), "F event with meta_pressed did not grab")
	_key(KEY_F, false)
	await ticks(3)

	# Without Cmd the same button grabs again.
	press(&"grab")
	await ticks(1)
	release(&"grab")
	await ticks(2)
	check(_starts.size() >= 1, "grab without Cmd starts an attack (%s)" % [_starts])
	await _settle(p)

	# --- Crouch + punch on the same tick: the press already sees the crouch. ---
	_starts.clear()
	_crouched_at_start.clear()
	press(&"crouch")
	press(&"punch")
	await ticks(1)
	release(&"punch")
	await ticks(2)
	check(not _starts.is_empty() and _crouched_at_start[0], "crouch + punch on one tick: crouching when the attack starts")
	release(&"crouch")
	await _settle(p)

	# --- Disabling the controller lets go of held buttons. ---------------------
	press(&"block")
	await ticks(4)
	check(p.combat.is_blocking(), "guard up before disabling input")
	pc.enabled = false
	await ticks(3)
	check(not p.combat.is_blocking(), "disabled controller released the held block")
	release(&"block")
	await ticks(2)
	pc.enabled = true
	await ticks(2)
	check(not p.combat.is_blocking() and not interp.is_held(&"block"), "re-enabled: block not stuck")
	done()

func _settle(p: Fighter) -> void:
	await wait_until(func() -> bool: return p.can_act() and not p.combat.is_attacking(), 240)
	await ticks(30)

func _key(code: Key, down: bool, meta := false) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = down
	e.meta_pressed = meta or (code == KEY_META and down)
	Input.parse_input_event(e)
