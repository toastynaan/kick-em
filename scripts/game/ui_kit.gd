class_name UIKit
## Shared look for the HUD and menus: one theme, big readable type, outlined
## labels that read over the 3D scene, and the controls help built from
## Controls.ACTIONS. OWNER: agent J (HUD, flow & menus).

const ACCENT := Color(1.0, 0.42, 0.18)
const ACCENT_DIM := Color(0.55, 0.2, 0.08)
const TEXT := Color(0.96, 0.95, 0.92)
const TEXT_DIM := Color(0.72, 0.72, 0.74)
const PANEL_BG := Color(0.05, 0.05, 0.07, 0.96)
const HP_COLOR := Color(0.86, 0.16, 0.14)
const HP_LOST := Color(1.0, 0.86, 0.45)
const FOCUS_COLOR := Color(0.3, 0.85, 1.0)
const PERFECT_COLOR := Color(0.55, 0.9, 1.0)
const GRAB_COLOR := Color(1.0, 0.18, 0.15)
const STRIKE_COLOR := Color(1.0, 1.0, 1.0)
## Round 5 enemy wind-ups (Feel Reference: Enemies have to be readable first):
## strikes glow orange, grabs blue. Off-screen arrows use the same colours.
const TELL_STRIKE := Color(1.0, 0.5, 0.1)
const TELL_GRAB := Color(0.25, 0.6, 1.0)
const COUNTER_COLOR := Color(1.0, 0.82, 0.3)  ## live counter bonus (parry / teleport)
const RESULT_GOOD := Color(1.0, 0.85, 0.35)

static var _theme: Theme
static var _heavy_font: Font

## Bold display font for titles, banners and pop text (system font with fallback).
static func heavy_font() -> Font:
	if _heavy_font == null:
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["Arial Black", "Helvetica Neue", "Impact", "Arial", "sans-serif"])
		f.font_weight = 900
		_heavy_font = f
	return _heavy_font

static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font_size = 22
	t.set_color(&"font_color", &"Label", TEXT)
	t.set_color(&"font_outline_color", &"Label", Color(0, 0, 0, 0.9))
	t.set_constant(&"outline_size", &"Label", 6)

	t.set_font_size(&"font_size", &"Button", 28)
	t.set_font(&"font", &"Button", heavy_font())
	t.set_color(&"font_color", &"Button", TEXT)
	t.set_color(&"font_hover_color", &"Button", Color.WHITE)
	t.set_color(&"font_focus_color", &"Button", Color.WHITE)
	t.set_color(&"font_pressed_color", &"Button", Color.WHITE)
	t.set_color(&"font_disabled_color", &"Button", Color(0.5, 0.5, 0.52))
	t.set_stylebox(&"normal", &"Button", _box(Color(0.1, 0.1, 0.12, 0.92), Color(0, 0, 0, 0), 0))
	t.set_stylebox(&"hover", &"Button", _box(Color(0.2, 0.12, 0.08, 0.95), ACCENT, 3))
	t.set_stylebox(&"pressed", &"Button", _box(ACCENT_DIM, ACCENT, 3))
	t.set_stylebox(&"focus", &"Button", _box(Color(0, 0, 0, 0), ACCENT, 4))
	t.set_stylebox(&"disabled", &"Button", _box(Color(0.08, 0.08, 0.09, 0.8), Color(0, 0, 0, 0), 0))
	t.set_constant(&"h_separation", &"Button", 12)

	t.set_stylebox(&"panel", &"PanelContainer", _box(PANEL_BG, Color(1, 1, 1, 0.08), 2, 18))
	t.set_stylebox(&"panel", &"Panel", _box(PANEL_BG, Color(1, 1, 1, 0.08), 2, 18))
	t.set_constant(&"separation", &"VBoxContainer", 12)
	t.set_constant(&"separation", &"HBoxContainer", 12)
	t.set_constant(&"h_separation", &"GridContainer", 28)
	t.set_constant(&"v_separation", &"GridContainer", 6)
	_theme = t
	return t

static func _box(bg: Color, border: Color, border_w: int, pad := 14) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_w)
	s.set_corner_radius_all(6)
	s.content_margin_left = pad + 8
	s.content_margin_right = pad + 8
	s.content_margin_top = pad
	s.content_margin_bottom = pad
	return s

static func label(text: String, size := 22, color := TEXT, heavy := false, outline := 6) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override(&"font_size", size)
	l.add_theme_color_override(&"font_color", color)
	l.add_theme_constant_override(&"outline_size", outline)
	if heavy:
		l.add_theme_font_override(&"font", heavy_font())
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

static func button(text: String, min_width := 460.0) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(min_width, 56)
	b.focus_mode = Control.FOCUS_ALL
	return b

## A canvas layer at least `min_layer` and above every layer of the ScreenFX
## autoload (Focus tint, blur, flashes), so HUD and menus keep full colour.
static func layer_above_screen_fx(tree: SceneTree, min_layer: int) -> int:
	var top := min_layer - 1
	var fx := tree.root.get_node_or_null(^"ScreenFX") if tree != null else null
	if fx != null:
		var layers: Array = fx.find_children("*", "CanvasLayer", true, false)
		if fx is CanvasLayer:
			layers.append(fx)
		for l: CanvasLayer in layers:
			top = maxi(top, l.layer)
	return maxi(min_layer, top + 1)

## Full-rect control that ignores the mouse (root for overlay layers).
static func full_rect(name: String) -> Control:
	var c := Control.new()
	c.name = name
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.theme = theme()
	return c

# --- Controls help (F1) --------------------------------------------------------
## What each action does, in the words the player needs (Feel Reference:
## Controls and targeting; Round 5 key map in Controls).
const ACTION_HELP := {
	&"move": "Move (camera-relative). Locked on: strafe around your target",
	&"camera": "Turn the camera (it never turns on its own)",
	&"punch": "Light (jab). Tap: next strike in the string. Hold: charge it",
	&"heavy": "Heavy (cross). Tap or hold to charge. Holding a body: throw it",
	&"kick": "Kick. Tap or hold to charge",
	&"sweep": "Sweep: pull back (toward the camera) + Kick",
	&"grab": "Grab a body or a prop; press again to let go. Blue glow: press to break their grab",
	&"jump": "Jump. Sprinting along a wall: wall run. Attack in the air: dropping strike",
	&"crouch": "Crouch (hold): ducks high attacks and standing grabs",
	&"block": "Tap just before a hit lands: parry. Hold: guard (-80% damage)",
	&"dash": "Tap: dash. In the parry window: teleport behind them (1 Focus). Hold: sprint",
	&"focus": "Focus mode (1 bar): the world slows to 0.3x for 2 s, you don't",
	&"lock_on": "Lock on to the enemy nearest the centre. Press again to unlock. No enemy: recentre",
	&"lock_switch": "While locked on: switch to the next or previous enemy",
	&"pause": "Pause menu (debug settings are in there)",
	&"restart": "Restart the round (pause and results screens)",
	&"help": "Show or hide this panel",
	&"debug": "Debug overlay: P and its parts, tier, speed, Focus, health",
	&"fullscreen": "Switch between fullscreen and a window",
}
const ACTION_TITLES := {
	&"move": "Move", &"camera": "Camera", &"punch": "Light", &"heavy": "Heavy", &"kick": "Kick",
	&"sweep": "Sweep", &"grab": "Grab", &"jump": "Jump", &"crouch": "Crouch", &"block": "Block",
	&"dash": "Dash / sprint", &"focus": "Focus", &"lock_on": "Lock on", &"lock_switch": "Switch target",
	&"pause": "Pause", &"restart": "Restart",
	&"help": "Help", &"debug": "Debug", &"fullscreen": "Fullscreen",
}
## Combinations that are not actions of their own: [group, after group, keyboard, gamepad].
const COMBO_ROWS := [[&"sweep", &"kick", "S + E", "Back + B"]]

## Rows of [title, keyboard+mouse, gamepad, description], one per action, built
## from Controls.ACTIONS (move_* and cam_* are merged into one row each).
static func control_rows() -> Array:
	var groups := {}  # group id -> {"kb": PackedStringArray, "pad": PackedStringArray}
	var order: Array[StringName] = []
	for action: StringName in Controls.ACTIONS:
		var gid := action
		if String(action).begins_with("move_"):
			gid = &"move"
		elif String(action).begins_with("cam_"):
			gid = &"camera"
		elif action == &"lock_next" or action == &"lock_prev":
			gid = &"lock_switch"
		if not groups.has(gid):
			groups[gid] = {"kb": PackedStringArray(), "pad": PackedStringArray()}
			order.append(gid)
		for spec: Array in Controls.ACTIONS[action]:
			var is_pad: bool = spec[0] == &"joy" or spec[0] == &"axis"
			var key := "pad" if is_pad else "kb"
			var n := _binding_name(spec)
			var arr: PackedStringArray = groups[gid][key]
			if not arr.has(n):
				arr.append(n)
				groups[gid][key] = arr
	if groups.has(&"camera"):
		var kb: PackedStringArray = groups[&"camera"]["kb"]
		kb.insert(0, "Mouse")
		groups[&"camera"]["kb"] = kb
	var rows: Array = []
	for gid in order:
		var kb_list: PackedStringArray = groups[gid]["kb"]
		var pad_list: PackedStringArray = groups[gid]["pad"]
		var kb_text := " ".join(kb_list) if gid == &"move" else " / ".join(kb_list)
		rows.append([ACTION_TITLES.get(gid, String(gid).capitalize()),
			kb_text if not kb_list.is_empty() else "-",
			" / ".join(pad_list) if not pad_list.is_empty() else "-",
			ACTION_HELP.get(gid, "")])
		for combo: Array in COMBO_ROWS:
			if combo[1] == gid:
				rows.append([ACTION_TITLES.get(combo[0], String(combo[0]).capitalize()), combo[2], combo[3],
					ACTION_HELP.get(combo[0], "")])
	return rows

static func _binding_name(spec: Array) -> String:
	match spec[0]:
		&"key":
			match int(spec[1]):
				KEY_ESCAPE: return "Esc"
				KEY_SEMICOLON: return ";"
				KEY_SPACE: return "Space"
				KEY_SHIFT: return "Shift"
				KEY_TAB: return "Tab"
			var mods: int = spec[2] if spec.size() > 2 else 0  # e.g. "Option+Enter" on macOS
			return OS.get_keycode_string(int(spec[1]) | mods)
		&"mouse":
			match int(spec[1]):
				MOUSE_BUTTON_LEFT: return "LMB"
				MOUSE_BUTTON_RIGHT: return "RMB"
				MOUSE_BUTTON_MIDDLE: return "MMB"
				MOUSE_BUTTON_WHEEL_UP: return "Wheel up"
				MOUSE_BUTTON_WHEEL_DOWN: return "Wheel down"
			return "Mouse %d" % int(spec[1])
		&"joy":
			match int(spec[1]):
				JOY_BUTTON_A: return "A"
				JOY_BUTTON_B: return "B"
				JOY_BUTTON_X: return "X"
				JOY_BUTTON_Y: return "Y"
				JOY_BUTTON_LEFT_SHOULDER: return "LB"
				JOY_BUTTON_RIGHT_SHOULDER: return "RB"
				JOY_BUTTON_BACK: return "Back"
				JOY_BUTTON_START: return "Start"
				JOY_BUTTON_LEFT_STICK: return "L3"
				JOY_BUTTON_RIGHT_STICK: return "R3"
				JOY_BUTTON_DPAD_LEFT: return "D-pad left"
				JOY_BUTTON_DPAD_RIGHT: return "D-pad right"
			return "Button %d" % int(spec[1])
		_:
			match int(spec[1]):
				JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y: return "Left stick"
				JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y: return "Right stick"
				JOY_AXIS_TRIGGER_LEFT: return "LT"
				JOY_AXIS_TRIGGER_RIGHT: return "RT"
			return "Axis %d" % int(spec[1])

## Centered panel listing every binding. Hidden by default.
static func controls_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "ControlsHelp"
	panel.theme = theme()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(box)
	box.add_child(label("CONTROLS", 40, ACCENT, true))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(grid)
	for h in ["", "Keyboard + mouse", "Gamepad", ""]:
		grid.add_child(label(h, 17, TEXT_DIM))
	for row: Array in control_rows():
		grid.add_child(label(row[0], 21, ACCENT, true, 5))
		grid.add_child(label(row[1], 21, TEXT))
		grid.add_child(label(row[2], 21, TEXT))
		var d := label(row[3], 18, TEXT_DIM)
		d.custom_minimum_size.x = 560
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		grid.add_child(d)
	var focus_note := label("Focus (3 bars, each wave starts with 1): Focus mode, a teleport and a pursuit each cost a full bar. Fills from parries and strong hits, never over time.", 18, FOCUS_COLOR)
	focus_note.custom_minimum_size.x = 900
	focus_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(focus_note)
	box.add_child(label("F1 closes this panel", 16, TEXT_DIM))
	panel.visible = false
	return panel
