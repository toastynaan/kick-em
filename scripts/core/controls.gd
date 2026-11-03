extends Node
## Autoload "Controls": registers every input action at startup so the bindings
## live in one readable place. OWNER: core (contract).
##
## Round 7 key map (docs/Round 7 — Freeflow Combat.md: Controls). One button,
## one move. No two actions share a binding. On the gamepad, LT is the kick
## layer: while it is held, X / A / B are the leg kick / front kick /
## roundhouse (PlayerController resolves the layer).
##
## Keyboard + mouse                      Gamepad (Xbox layout)
##   Move ........ WASD                    Left stick
##   Camera ...... Mouse                   Right stick
##   Punch ....... LMB / J                 X        tap = jab, cross, hook; hold = heavy
##   Leg kick .... RMB                     LT + X
##   Gut punch ... Q                       B
##   Uppercut .... E                       LB
##   Front kick .. F                       LT + A
##   Roundhouse .. R                       LT + B
##   (kicks: tap = kick, hold = heavy kick)
##   Grab ........ C                       RB       grab, release; while holding:
##                                                   punch = throw (hold to wind up),
##                                                   leg kick = knee, dash = drive
##   Counter ..... V / mouse thumb (back)  Y
##   Jump ........ Space                   A        sprint + jump at a wall = wall run
##   Dash ........ Shift                   RT       tap = dodge, or teleport just before a
##                                                   hit lands, or pursuit right after a
##                                                   launch; hold = sprint
##   Pause ....... Esc                     Start
##   Restart ..... Backspace               Back
##   Help ........ F1
##   Debug ....... F3
##   Fullscreen .. F11 / Alt+Enter
##
## Ctrl is not bound: on macOS Ctrl+click is a right click. The player's
## InputInterpreter drops presses made while Cmd is held.
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
	&"punch": [[&"mouse", MOUSE_BUTTON_LEFT], [&"key", KEY_J], [&"joy", JOY_BUTTON_X]],
	&"leg_kick": [[&"mouse", MOUSE_BUTTON_RIGHT]],          # pad: LT + X
	&"gut_punch": [[&"key", KEY_Q], [&"joy", JOY_BUTTON_B]],
	&"uppercut": [[&"key", KEY_E], [&"joy", JOY_BUTTON_LEFT_SHOULDER]],
	&"front_kick": [[&"key", KEY_F]],                       # pad: LT + A
	&"roundhouse": [[&"key", KEY_R]],                       # pad: LT + B
	&"kick_layer": [[&"axis", JOY_AXIS_TRIGGER_LEFT, 1.0]], # pad only
	&"grab": [[&"key", KEY_C], [&"joy", JOY_BUTTON_RIGHT_SHOULDER]],
	&"counter": [[&"key", KEY_V], [&"mouse", MOUSE_BUTTON_XBUTTON1], [&"joy", JOY_BUTTON_Y]],
	&"jump": [[&"key", KEY_SPACE], [&"joy", JOY_BUTTON_A]],
	&"dash": [[&"key", KEY_SHIFT], [&"axis", JOY_AXIS_TRIGGER_RIGHT, 1.0]],
	&"pause": [[&"key", KEY_ESCAPE], [&"joy", JOY_BUTTON_START]],
	&"restart": [[&"key", KEY_BACKSPACE], [&"joy", JOY_BUTTON_BACK]],
	&"help": [[&"key", KEY_F1]],
	&"debug": [[&"key", KEY_F3]],
	&"fullscreen": [[&"key", KEY_F11], [&"key", KEY_ENTER, KEY_MASK_ALT]],
}

## Gamepad kick layer (PlayerController): with kick_layer held, a press of the
## key's action means the value's action. The layer lives on X / A / B, so A
## (jump) becomes the front kick while LT is held.
const KICK_LAYER := {&"punch": &"leg_kick", &"jump": &"front_kick", &"gut_punch": &"roundhouse"}

## Round 7 removed these. They stay registered WITHOUT bindings, so any stray
## read never errors, and tests use the list to check that nothing binds,
## reads or documents them. Never bind them again.
const LEGACY_ACTIONS: Array[StringName] = [&"heavy", &"kick", &"crouch", &"block",
	&"focus", &"lock_on", &"lock_next", &"lock_prev"]

const FULLSCREEN_RECHECK := 1.5  ## real s after start before checking the window really went fullscreen

func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # the fullscreen key works while paused
	for action: StringName in ACTIONS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.2)
		for spec: Array in ACTIONS[action]:
			InputMap.action_add_event(action, _make_event(spec))
	for action: StringName in LEGACY_ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.2)

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
