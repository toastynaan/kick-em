extends Node
## Round 7 check (docs/Round 7 — Freeflow Combat.md: Controls): every action
## in the table fires from keyboard/mouse and from the gamepad, no two actions
## share a binding, and the removed actions are registered without bindings.
## The pad's kicks are the LT kick layer (Controls.KICK_LAYER), so they have a
## keyboard/mouse binding only. Actions fire through Input.parse_input_event.

## Actions with both a keyboard/mouse and a gamepad binding.
const TABLE := [&"move_forward", &"move_back", &"move_left", &"move_right", &"punch",
	&"gut_punch", &"uppercut", &"grab", &"counter", &"jump", &"dash", &"pause", &"restart"]
## Keyboard/mouse only (pad: kick layer).
const KB_ONLY := [&"leg_kick", &"front_kick", &"roundhouse"]
## Camera is mouse motion on keyboard (not an action); right stick on the pad.
const PAD_ONLY := [&"cam_left", &"cam_right", &"cam_up", &"cam_down", &"kick_layer"]

var _fails := 0

func _ready() -> void:
	await get_tree().process_frame
	await _run()
	print("TEST test_controls: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)

func _run() -> void:
	# Every table action has a keyboard/mouse event and a gamepad event, and each fires.
	for action: StringName in TABLE + KB_ONLY + PAD_ONLY:
		_check(InputMap.has_action(action), "%s exists" % action)
		var kb: InputEvent = null
		var pad: InputEvent = null
		for e in InputMap.action_get_events(action):
			if (e is InputEventKey or e is InputEventMouseButton) and kb == null:
				kb = e
			elif (e is InputEventJoypadButton or e is InputEventJoypadMotion) and pad == null:
				pad = e
		if not PAD_ONLY.has(action):
			_check(kb != null, "%s has a keyboard/mouse binding" % action)
			if kb != null:
				_check(await _fires(action, kb), "%s fires from %s" % [action, kb.as_text()])
		if KB_ONLY.has(action):
			_check(pad == null, "%s has no gamepad binding (kick layer)" % action)
			continue
		_check(pad != null, "%s has a gamepad binding" % action)
		if pad != null:
			_check(await _fires(action, pad), "%s fires from %s" % [action, _pad_text(pad)])

	# No two actions share a binding.
	var seen := {}
	for action: StringName in Controls.ACTIONS:
		for e in InputMap.action_get_events(action):
			var key := _event_key(e)
			if seen.has(key):
				_check(false, "%s and %s share %s" % [seen[key], action, key])
			else:
				seen[key] = action
	_check(true, "%d bindings checked for clashes" % seen.size())

	# Round 7 bindings.
	_check(_has_mouse(&"punch", MOUSE_BUTTON_LEFT) and _has_mouse(&"leg_kick", MOUSE_BUTTON_RIGHT), "LMB punch, RMB leg kick")
	_check(_has_key(&"gut_punch", KEY_Q) and _has_key(&"uppercut", KEY_E) and _has_key(&"front_kick", KEY_F)
		and _has_key(&"roundhouse", KEY_R), "Q gut punch, E uppercut, F front kick, R roundhouse")
	_check(_has_key(&"grab", KEY_C) and _has_key(&"counter", KEY_V) and _has_mouse(&"counter", MOUSE_BUTTON_XBUTTON1)
		and _has_key(&"jump", KEY_SPACE) and _has_key(&"dash", KEY_SHIFT) and _has_key(&"restart", KEY_BACKSPACE),
		"C grab, V / mouse thumb counter, Space jump, Shift dash, Backspace restart")
	_check(_has_joy(&"counter", JOY_BUTTON_Y) and _has_joy(&"grab", JOY_BUTTON_RIGHT_SHOULDER)
		and _has_joy(&"jump", JOY_BUTTON_A) and _has_joy(&"uppercut", JOY_BUTTON_LEFT_SHOULDER)
		and _has_axis(&"kick_layer", JOY_AXIS_TRIGGER_LEFT) and _has_axis(&"dash", JOY_AXIS_TRIGGER_RIGHT),
		"Y counter, A jump, LB uppercut, RB grab, LT kick layer, RT dash")
	for k: StringName in Controls.KICK_LAYER:
		_check(TABLE.has(k) and KB_ONLY.has(Controls.KICK_LAYER[k]), "kick layer %s -> %s" % [k, Controls.KICK_LAYER[k]])
	_check(_has_joy(&"punch", JOY_BUTTON_X) and _has_joy(&"jump", JOY_BUTTON_A) and _has_joy(&"gut_punch", JOY_BUTTON_B),
		"kick layer sits on X / A / B")

	# Removed actions exist (old readers never error) but nothing fires them.
	for action: StringName in Controls.LEGACY_ACTIONS:
		_check(InputMap.has_action(action) and InputMap.action_get_events(action).is_empty(),
			"%s registered with no bindings" % action)

func _fires(action: StringName, e: InputEvent) -> bool:
	var down := e.duplicate() as InputEvent
	_set_pressed(down, true)
	Input.parse_input_event(down)
	Input.flush_buffered_events()
	await get_tree().process_frame
	var ok := Input.is_action_pressed(action)
	var up := e.duplicate() as InputEvent
	_set_pressed(up, false)
	Input.parse_input_event(up)
	Input.flush_buffered_events()
	await get_tree().process_frame
	return ok and not Input.is_action_pressed(action)

func _set_pressed(e: InputEvent, on: bool) -> void:
	if e is InputEventKey:
		(e as InputEventKey).pressed = on
	elif e is InputEventMouseButton:
		(e as InputEventMouseButton).pressed = on
	elif e is InputEventJoypadButton:
		(e as InputEventJoypadButton).pressed = on
	elif e is InputEventJoypadMotion:
		var m := e as InputEventJoypadMotion
		m.axis_value = signf(m.axis_value) if on else 0.0

func _event_key(e: InputEvent) -> String:
	if e is InputEventKey:
		var k := e as InputEventKey
		return "key:%d:%d%d%d" % [k.physical_keycode, int(k.alt_pressed), int(k.ctrl_pressed), int(k.meta_pressed)]
	if e is InputEventMouseButton:
		return "mouse:%d" % (e as InputEventMouseButton).button_index
	if e is InputEventJoypadButton:
		return "joy:%d" % (e as InputEventJoypadButton).button_index
	var m := e as InputEventJoypadMotion
	return "axis:%d:%d" % [m.axis, int(signf(m.axis_value))]

func _pad_text(e: InputEvent) -> String:
	return _event_key(e)

func _has_key(action: StringName, code: Key) -> bool:
	for e in InputMap.action_get_events(action):
		if e is InputEventKey and (e as InputEventKey).physical_keycode == code:
			return true
	return false

func _has_mouse(action: StringName, b: MouseButton) -> bool:
	for e in InputMap.action_get_events(action):
		if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == b:
			return true
	return false

func _has_joy(action: StringName, b: JoyButton) -> bool:
	for e in InputMap.action_get_events(action):
		if e is InputEventJoypadButton and (e as InputEventJoypadButton).button_index == b:
			return true
	return false

func _has_axis(action: StringName, a: JoyAxis) -> bool:
	for e in InputMap.action_get_events(action):
		if e is InputEventJoypadMotion and (e as InputEventJoypadMotion).axis == a:
			return true
	return false
