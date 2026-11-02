class_name UIKit
## Shared look for the HUD and menus: one theme, big readable type, outlined
## labels that read over the 3D scene, and the controls help built from
## Controls.ACTIONS. OWNER: agent E (feel & flow).

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

## Full-rect control that ignores the mouse (root for overlay layers).
static func full_rect(name: String) -> Control:
	var c := Control.new()
	c.name = name
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.theme = theme()
	return c

# --- Controls help (F1) --------------------------------------------------------
## What each action does, in the words the player needs (spec: Combat system).
const ACTION_HELP := {
	&"move": "Move (camera-relative)",
	&"camera": "Orbit the camera",
	&"punch": "Tap: next punch in the string. Hold: charge it. In dodge slow-mo: teleport counter",
	&"kick": "Tap: next kick in the string. Hold: charge it. Crouch + kick: sweep",
	&"grab": "Grab; release throws. Red glint: press to break their grab",
	&"jump": "Jump: clears low attacks",
	&"crouch": "Crouch (hold): ducks high attacks and standing grabs",
	&"block": "Block (-80% damage). Tap just before a hit: perfect dodge",
	&"dash": "Dash: speed feeds your next hit. After a launch: pursuit",
	&"focus": "Focus (hold): the world slows, you don't. Drains the Focus meter",
	&"pause": "Pause menu",
	&"restart": "Restart the round (pause and round-over screens)",
	&"help": "Show or hide this panel",
	&"debug": "Debug overlay",
	&"fullscreen": "Switch between fullscreen and a window",
}
const ACTION_TITLES := {
	&"move": "Move", &"camera": "Camera", &"punch": "Punch", &"kick": "Kick",
	&"grab": "Grab", &"jump": "Jump", &"crouch": "Crouch", &"block": "Block",
	&"dash": "Dash", &"focus": "Focus", &"pause": "Pause", &"restart": "Restart",
	&"help": "Help", &"debug": "Debug", &"fullscreen": "Fullscreen",
}

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
	return rows

static func _binding_name(spec: Array) -> String:
	match spec[0]:
		&"key":
			match int(spec[1]):
				KEY_ESCAPE: return "Esc"
				KEY_SEMICOLON: return ";"
				KEY_SPACE: return "Space"
				KEY_SHIFT: return "Shift"
			var mods: int = spec[2] if spec.size() > 2 else 0  # e.g. "Option+Enter" on macOS
			return OS.get_keycode_string(int(spec[1]) | mods)
		&"mouse":
			match int(spec[1]):
				MOUSE_BUTTON_LEFT: return "LMB"
				MOUSE_BUTTON_RIGHT: return "RMB"
				MOUSE_BUTTON_MIDDLE: return "MMB"
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
	box.add_child(label("Focus (3 bars): hold to slow the world while you keep full speed (needs half a bar). Fills from perfect dodges, launches and kills.", 18, FOCUS_COLOR))
	box.add_child(label("F1 closes this panel", 16, TEXT_DIM))
	panel.visible = false
	return panel
