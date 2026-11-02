extends Node
## F0 check: "Every action in the controls table fires from both controller and
## keyboard, and no two actions share a binding except the listed combinations."
## Sweep (pull back + Kick) is the only combination, so no two actions may
## share any event. Actions fire through Input.parse_input_event.

## The Feel Reference controls table: action -> [needs keyboard/mouse, needs gamepad].
const TABLE := [&"move_forward", &"move_back", &"move_left", &"move_right", &"jump", &"punch",
	&"heavy", &"kick", &"block", &"dash", &"grab", &"focus", &"crouch"]
## Camera is mouse motion on keyboard (not an action); right stick on the pad.
const PAD_ONLY := [&"cam_left", &"cam_right", &"cam_up", &"cam_down"]

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
	for action: StringName in TABLE + PAD_ONLY:
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

	# Spec bindings that changed in Round 5.
	_check(_has_key(&"kick", KEY_E) and _has_key(&"grab", KEY_G) and _has_key(&"focus", KEY_F), "E kick, G grab, F focus")
	_check(_has_mouse(&"punch", MOUSE_BUTTON_LEFT) and _has_mouse(&"heavy", MOUSE_BUTTON_RIGHT), "LMB light, RMB heavy")
	_check(_has_joy(&"crouch", JOY_BUTTON_RIGHT_STICK) and _has_joy(&"focus", JOY_BUTTON_LEFT_SHOULDER), "R3 crouch, LB focus")
	_check(_has_axis(&"grab", JOY_AXIS_TRIGGER_LEFT) and _has_axis(&"dash", JOY_AXIS_TRIGGER_RIGHT), "LT grab, RT dash")

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
