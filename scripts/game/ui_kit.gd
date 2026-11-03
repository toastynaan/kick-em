class_name UIKit
## Shared look for the HUD and menus: one theme, big readable type, outlined
## labels that read over the 3D scene, the controls help built from
## Controls.ACTIONS (Round 7 key map) and the key names for the device the
## player used last. OWNER: agent J (HUD, flow & menus).

const ACCENT := Color(1.0, 0.42, 0.18)
const ACCENT_DIM := Color(0.55, 0.2, 0.08)
const TEXT := Color(0.96, 0.95, 0.92)
const TEXT_DIM := Color(0.72, 0.72, 0.74)
const PANEL_BG := Color(0.05, 0.05, 0.07, 0.96)
const HP_COLOR := Color(0.86, 0.16, 0.14)
const HP_LOST := Color(1.0, 0.86, 0.45)
const GRAB_COLOR := Color(1.0, 0.18, 0.15)
const STRIKE_COLOR := Color(1.0, 1.0, 1.0)
## Enemy attacks (Round 7: Defence): orange = counterable (press Counter),
## blue = uncounterable, grabs and the shoulder charge (dodge). Counter prompts
## and off-screen arrows use the same colours as the world tells.
const TELL_STRIKE := Tuning.TELL_COLOR_STRIKE
const TELL_GRAB := Tuning.TELL_COLOR_GRAB
## Pursuit cues (God path: "DASH: PURSUE", the hang's attack choice); apart
## from the orange counter and blue dodge colours.
const PURSUIT_COLOR := Color(0.45, 1.0, 0.72)
const RESULT_GOOD := Color(1.0, 0.85, 0.35)

static var _theme: Theme
static var _heavy_font: Font
## The player last used a gamepad (prompts show Y / RT instead of Space / Shift).
## HUD and GameMenus feed every input event to note_input().
static var pad_active := false
static var _groups: Dictionary = {}   ## _binding_groups() cache (Controls.ACTIONS is const)

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
## What each action does, in the words the player needs (Round 7: Controls,
## with the amendment's god path: jump and wall run, teleport, pursuit).
const ACTION_HELP := {
	&"move": "Move (camera-relative)",
	&"camera": "Turn the camera. It only turns itself to keep your target in view",
	&"punch": "Tap: jab, cross, hook (then back to the jab). Hold: the heavy version",
	&"leg_kick": "Buckles the leg: the enemy drops to one knee. Hold: heavy kick",
	&"gut_punch": "Folds the enemy over",
	&"uppercut": "Pops the enemy into the air: keep hitting to juggle",
	&"front_kick": "Shoves the enemy far back. Hold: heavy kick",
	&"roundhouse": "Knockdown. Launches a lifted enemy into the walls. Hold: heavy kick",
	&"kick_layer": "Gamepad kick layer: hold LT, then X / A / B for the three kicks",
	&"grab": "Grab the enemy you face (or a prop). Press again to let go",
	&"counter": "Orange icon over an enemy: counter its attack. Blue icon: dodge instead",
	&"jump": "Jump. Sprint + jump at a wall: wall run. Attack in the air: dropping strike",
	&"dash": "Tap: dodge, teleport just before a hit, pursue right after a launch. Hold: sprint",
	&"pursuit": "Right after you launch someone: Dash to the flying body",
	&"pursuit_hit": "Attack: launch it further. Pull back + attack: spike it into the ground",
	&"throw": "Holding a body: throw it. Hold to wind up a harder throw",
	&"knee": "Holding a body: knee it",
	&"drive": "Holding a body: run it forward and slam it through walls",
	&"release": "Holding a body: drop it",
	&"pause": "Pause menu (the upgrades are in Debug settings)",
	&"restart": "Restart the round",
	&"help": "Show or hide this panel",
	&"debug": "Debug overlay: move, string, chain, glide, the target's state",
	&"fullscreen": "Switch between fullscreen and a window",
}
const ACTION_TITLES := {
	&"move": "Move", &"camera": "Camera", &"punch": "Punch", &"leg_kick": "Leg kick",
	&"gut_punch": "Gut punch", &"uppercut": "Uppercut", &"front_kick": "Front kick",
	&"roundhouse": "Roundhouse", &"kick_layer": "Kick layer", &"grab": "Grab", &"counter": "Counter",
	&"jump": "Jump", &"dash": "Dash / sprint", &"pursuit": "Pursuit", &"pursuit_hit": "Pursuit hit",
	&"throw": "Holding: throw", &"knee": "Holding: knee", &"drive": "Holding: drive",
	&"release": "Holding: release", &"pause": "Pause", &"restart": "Restart",
	&"help": "Help", &"debug": "Debug", &"fullscreen": "Fullscreen",
}
## While holding a body the buttons change (Round 7: Grab, drive and throw):
## [row id, the action whose keys it uses, suffix added to the keys]. Listed
## right after the Grab row.
const HOLD_ROWS := [[&"throw", &"punch", ""], [&"knee", &"leg_kick", ""],
	[&"drive", &"dash", " (hold)"], [&"release", &"grab", ""]]
const HOLD_AFTER := &"grab"
## The pursuit (God path) rows follow the Dash row.
const PURSUIT_AFTER := &"dash"

## Rows of [title, keyboard+mouse, gamepad, description], one per action, built
## from Controls.ACTIONS (move_* and cam_* are merged into one row each). The
## gamepad's kick-layer moves read "LT + X" (Controls.KICK_LAYER); the pursuit
## rows follow Dash and the hold actions follow Grab.
static func control_rows() -> Array:
	var groups := _binding_groups()
	var rows: Array = []
	for gid: StringName in groups["order"]:
		rows.append(_row(gid, groups[gid]["kb"], groups[gid]["pad"], ""))
		if gid == PURSUIT_AFTER:
			rows.append_array(_pursuit_rows(groups))
		if gid == HOLD_AFTER:
			for h: Array in HOLD_ROWS:
				var src: StringName = h[1]
				if groups.has(src):
					rows.append(_row(h[0], groups[src]["kb"], groups[src]["pad"], h[2]))
	return rows

## Pursuit: Dash after a launch, then the pursuit hit (back + attack spikes).
static func _pursuit_rows(groups: Dictionary) -> Array:
	var dash_kb := _first_key(groups, &"dash", "kb")
	var dash_pad := _first_key(groups, &"dash", "pad")
	var back := "back"
	if Controls.ACTIONS.has(&"move_back"):
		for spec: Array in Controls.ACTIONS[&"move_back"]:
			if spec[0] == &"key":
				back = _binding_name(spec)
				break
	return [
		[ACTION_TITLES[&"pursuit"], "%s (after a launch)" % dash_kb, "%s (after a launch)" % dash_pad, ACTION_HELP[&"pursuit"]],
		[ACTION_TITLES[&"pursuit_hit"], "Attack / %s + attack" % back, "Attack / stick back + attack", ACTION_HELP[&"pursuit_hit"]],
	]

static func _first_key(groups: Dictionary, gid: StringName, device: String) -> String:
	var list: PackedStringArray = groups.get(gid, {}).get(device, PackedStringArray())
	return list[0] if not list.is_empty() else "-"

static func _row(gid: StringName, kb_list: PackedStringArray, pad_list: PackedStringArray, suffix: String) -> Array:
	var kb_text := " ".join(kb_list) if gid == &"move" else " / ".join(kb_list)
	return [ACTION_TITLES.get(gid, String(gid).capitalize()),
		kb_text + suffix if not kb_list.is_empty() else "-",
		" / ".join(pad_list) + suffix if not pad_list.is_empty() else "-",
		ACTION_HELP.get(gid, "")]

## {group id: {"kb": names, "pad": names}, "order": [group ids]} from Controls.
static func _binding_groups() -> Dictionary:
	if not _groups.is_empty():
		return _groups
	var groups := {}
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
	# Gamepad kick layer: "LT + X" for the moves the layer turns a button into.
	var layer: PackedStringArray = groups.get(&"kick_layer", {}).get("pad", PackedStringArray())
	for base: StringName in Controls.KICK_LAYER:
		var kicked: StringName = Controls.KICK_LAYER[base]
		if not groups.has(kicked) or not groups.has(base) or layer.is_empty():
			continue
		var base_pad: PackedStringArray = groups[base]["pad"]
		var pad: PackedStringArray = groups[kicked]["pad"]
		for b in base_pad:
			var n := "%s + %s" % [layer[0], b]
			if not pad.has(n):
				pad.append(n)
		groups[kicked]["pad"] = pad
	if groups.has(&"kick_layer") and not layer.is_empty():
		groups[&"kick_layer"]["pad"] = PackedStringArray(["%s (hold)" % layer[0]])
	groups["order"] = order
	_groups = groups
	return groups

## The first key of `action` on the keyboard + mouse or the gamepad ("V",
## "Y", "LT + X"); "-" when it has none. Prompts use the device in pad_active.
static func key_label(action: StringName, pad := pad_active) -> String:
	return _first_key(_binding_groups(), action, "pad" if pad else "kb")

## Every key of `action` on one device, "V / Mouse thumb"; "-" when none.
static func keys_label(action: StringName, pad := pad_active) -> String:
	var list: PackedStringArray = _binding_groups().get(action, {}).get("pad" if pad else "kb", PackedStringArray())
	return " / ".join(list) if not list.is_empty() else "-"

## Follow the device the player is using (keyboard + mouse or gamepad).
## Stick drift and tiny mouse moves do not switch it.
static func note_input(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		if (event as InputEventJoypadButton).pressed:
			pad_active = true
	elif event is InputEventJoypadMotion:
		if absf((event as InputEventJoypadMotion).axis_value) > 0.5:
			pad_active = true
	elif event is InputEventKey:
		if (event as InputEventKey).pressed:
			pad_active = false
	elif event is InputEventMouseButton:
		if (event as InputEventMouseButton).pressed:
			pad_active = false
	elif event is InputEventMouseMotion:
		if (event as InputEventMouseMotion).relative.length() > 4.0:
			pad_active = false

static func _binding_name(spec: Array) -> String:
	match spec[0]:
		&"key":
			match int(spec[1]):
				KEY_ESCAPE: return "Esc"
				KEY_SEMICOLON: return ";"
				KEY_SPACE: return "Space"
				KEY_SHIFT: return "Shift"
				KEY_TAB: return "Tab"
				KEY_BACKSPACE: return "Backspace"
			var mods: int = spec[2] if spec.size() > 2 else 0  # e.g. "Option+Enter" on macOS
			return OS.get_keycode_string(int(spec[1]) | mods)
		&"mouse":
			match int(spec[1]):
				MOUSE_BUTTON_LEFT: return "LMB"
				MOUSE_BUTTON_RIGHT: return "RMB"
				MOUSE_BUTTON_MIDDLE: return "MMB"
				MOUSE_BUTTON_WHEEL_UP: return "Wheel up"
				MOUSE_BUTTON_WHEEL_DOWN: return "Wheel down"
				MOUSE_BUTTON_XBUTTON1: return "Mouse thumb"
				MOUSE_BUTTON_XBUTTON2: return "Mouse thumb 2"
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

## Centered panel listing every binding. Hidden by default. Sized to fit a
## 1600x900 window.
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
	box.add_theme_constant_override(&"separation", 8)
	panel.add_child(box)
	box.add_child(label("CONTROLS", 34, ACCENT, true))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_theme_constant_override(&"v_separation", 2)
	box.add_child(grid)
	for h in ["", "Keyboard + mouse", "Gamepad", ""]:
		grid.add_child(label(h, 15, TEXT_DIM))
	for row: Array in control_rows():
		grid.add_child(label(row[0], 18, ACCENT, true, 4))
		grid.add_child(label(row[1], 18, TEXT))
		grid.add_child(label(row[2], 18, TEXT))
		var d := label(row[3], 16, TEXT_DIM)
		d.custom_minimum_size.x = 680
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		grid.add_child(d)
	var tells := label("Orange icon over an enemy: Counter (%s / %s). Blue icon: it can't be countered, Dodge (%s / %s)." % [
		keys_label(&"counter", false), key_label(&"counter", true), key_label(&"dash", false), key_label(&"dash", true)],
		16, TELL_STRIKE)
	tells.custom_minimum_size.x = 900
	tells.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(tells)
	box.add_child(label("F1 closes this panel", 15, TEXT_DIM))
	panel.visible = false
	return panel
