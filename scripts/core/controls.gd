extends Node
## Autoload "Controls": registers every input action at startup so the bindings
## live in one readable place. OWNER: core (contract).
##
## Round 5 key map (Feel Reference: Controls and targeting). No two actions
## share a binding; Sweep is the only combination (pull back + Kick).
##
## Keyboard + mouse                      Gamepad (Xbox layout)
##   Move ........ WASD                    Left stick
##   Camera ...... Mouse                   Right stick
##   Jump ........ Space                   A
##   Light (jab) . LMB / J                 X        tap = next move in the string, hold = charge
##   Heavy (cross) RMB / L                 Y        tap or hold to charge
##   Kick ........ E / K                   B        tap or hold to charge
##   Sweep ....... S + E                   back + B  ("back" is toward the camera)
##   Block ....... Q                       RB       tap = parry, hold = guard
##   Dash/sprint . Shift                   RT       tap = dash / teleport / pursuit, hold = sprint
##   Grab ........ G                       LT       grab, grab break, release
##   Focus mode .. F                       LB       the world slows for 2 s (1 bar)
##   Crouch ...... C                       R3 (right stick click)
##   Lock-on ..... MMB / Tab               L3 (left stick click)   Round 4; moved off R3 for crouch
##   Lock next/prev  wheel                 D-pad right / left
##   Pause ....... Esc                     Start
##   Restart ..... R                       Back
##   Help ........ F1
##   Debug ....... F3
##   Fullscreen .. F11 / Alt+Enter
##
## The Light action keeps its Upgrade 2 name "punch" (bots, tests and the
## showcase use it). Ctrl is not a crouch key: on macOS Ctrl+click is a right
## click, so crouch + punch would read as Heavy. The player's InputInterpreter
## drops presses made while Cmd is held.
##
## A key spec may carry a modifier mask as a third element:
## [&"key", KEY_ENTER, KEY_MASK_ALT] is Alt+Enter.
##
## The game starts in native fullscreen (project.godot window/size/mode=3;
## the windowed size is the 1600x900 viewport size). "fullscreen" is handled
## here, so it works in every scene and while paused. The engine's own
## ui_toggle_fullscreen shortcut is turned off in project.godot because it
## uses the same keys and would undo every toggle.

const ACTIONS := {
	&"move_forward": [[&"key", KEY_W], [&"axis", JOY_AXIS_LEFT_Y, -1.0]],
	&"move_back": [[&"key", KEY_S], [&"axis", JOY_AXIS_LEFT_Y, 1.0]],
	&"move_left": [[&"key", KEY_A], [&"axis", JOY_AXIS_LEFT_X, -1.0]],
	&"move_right": [[&"key", KEY_D], [&"axis", JOY_AXIS_LEFT_X, 1.0]],
	&"cam_left": [[&"axis", JOY_AXIS_RIGHT_X, -1.0]],
	&"cam_right": [[&"axis", JOY_AXIS_RIGHT_X, 1.0]],
	&"cam_up": [[&"axis", JOY_AXIS_RIGHT_Y, -1.0]],
	&"cam_down": [[&"axis", JOY_AXIS_RIGHT_Y, 1.0]],
	&"punch": [[&"mouse", MOUSE_BUTTON_LEFT], [&"key", KEY_J], [&"joy", JOY_BUTTON_X]],  # Light (jab)
	&"heavy": [[&"mouse", MOUSE_BUTTON_RIGHT], [&"key", KEY_L], [&"joy", JOY_BUTTON_Y]],  # Heavy (cross)
	&"kick": [[&"key", KEY_E], [&"key", KEY_K], [&"joy", JOY_BUTTON_B]],
	&"grab": [[&"key", KEY_G], [&"axis", JOY_AXIS_TRIGGER_LEFT, 1.0]],
	&"jump": [[&"key", KEY_SPACE], [&"joy", JOY_BUTTON_A]],
	&"crouch": [[&"key", KEY_C], [&"joy", JOY_BUTTON_RIGHT_STICK]],
	&"block": [[&"key", KEY_Q], [&"joy", JOY_BUTTON_RIGHT_SHOULDER]],
	&"dash": [[&"key", KEY_SHIFT], [&"axis", JOY_AXIS_TRIGGER_RIGHT, 1.0]],
	&"focus": [[&"key", KEY_F], [&"joy", JOY_BUTTON_LEFT_SHOULDER]],
	# Round 4 lock-on: toggle, then cycle targets while locked.
	&"lock_on": [[&"mouse", MOUSE_BUTTON_MIDDLE], [&"key", KEY_TAB], [&"joy", JOY_BUTTON_LEFT_STICK]],
	&"lock_next": [[&"mouse", MOUSE_BUTTON_WHEEL_DOWN], [&"joy", JOY_BUTTON_DPAD_RIGHT]],
	&"lock_prev": [[&"mouse", MOUSE_BUTTON_WHEEL_UP], [&"joy", JOY_BUTTON_DPAD_LEFT]],
	&"pause": [[&"key", KEY_ESCAPE], [&"joy", JOY_BUTTON_START]],
	&"restart": [[&"key", KEY_R], [&"joy", JOY_BUTTON_BACK]],
	&"help": [[&"key", KEY_F1]],
	&"debug": [[&"key", KEY_F3]],
	&"fullscreen": [[&"key", KEY_F11], [&"key", KEY_ENTER, KEY_MASK_ALT]],
}

const FULLSCREEN_RECHECK := 1.5  ## real s after start before checking the window really went fullscreen

func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # the fullscreen key works while paused
	for action: StringName in ACTIONS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.2)
		for spec: Array in ACTIONS[action]:
			InputMap.action_add_event(action, _make_event(spec))

func _make_event(spec: Array) -> InputEvent:
	match spec[0]:
		&"key":
			var k := InputEventKey.new()
			k.physical_keycode = spec[1]
			var mods: int = spec[2] if spec.size() > 2 else 0
			k.alt_pressed = (mods & KEY_MASK_ALT) != 0
			k.ctrl_pressed = (mods & KEY_MASK_CTRL) != 0
			k.meta_pressed = (mods & KEY_MASK_META) != 0
			k.shift_pressed = (mods & KEY_MASK_SHIFT) != 0
			return k
		&"mouse":
			var m := InputEventMouseButton.new()
			m.button_index = spec[1]
			return m
		&"joy":
			var j := InputEventJoypadButton.new()
			j.button_index = spec[1]
			return j
		_:
			var a := InputEventJoypadMotion.new()
			a.axis = spec[1]
			a.axis_value = spec[2]
			return a

func _ready() -> void:
	if get_window().mode == Window.MODE_FULLSCREEN and DisplayServer.get_name() != "headless":
		get_tree().create_timer(FULLSCREEN_RECHECK, true, false, true).timeout.connect(_recheck_fullscreen)

## macOS drops the fullscreen request when the game starts while another
## fullscreen window is still animating away (F5 restart from the editor).
## Godot then reports MODE_FULLSCREEN for a plain 1600x900 window, and asking
## for MODE_WINDOWED is what makes macOS enter fullscreen (it toggles).
func _recheck_fullscreen() -> void:
	var w := get_window()
	if w.mode == Window.MODE_FULLSCREEN and w.size.x < DisplayServer.screen_get_size(w.current_screen).x:
		w.mode = Window.MODE_WINDOWED

## _input runs before the GUI, so Alt+Enter never also presses a focused button.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"fullscreen"):
		toggle_fullscreen()
		get_viewport().set_input_as_handled()

## Native fullscreen <-> window. Leaving fullscreen restores the window's
## previous size and position (1600x900 centered when the game started fullscreen).
func toggle_fullscreen() -> void:
	var w := get_window()
	if w.mode == Window.MODE_FULLSCREEN or w.mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
		w.mode = Window.MODE_WINDOWED
	else:
		w.mode = Window.MODE_FULLSCREEN
