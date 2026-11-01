class_name GameMenus
extends CanvasLayer
## Title menu, pause menu and round-over panel. Always processes (works while
## the tree is paused) and owns the Esc / R / F1 handling outside a round's HUD.
## Emits signals; GameMode does the work. Keyboard and gamepad navigable.
## OWNER: agent E (feel & flow).

signal duel_pressed
signal waves_pressed
signal lab_pressed
signal quit_pressed
signal pause_requested
signal resume_pressed
signal restart_pressed
signal menu_pressed

enum Screen { NONE, TITLE, PAUSE, ROUND_OVER }

const LAB_SCENE := "res://scenes/ragdoll_lab.tscn"

## Set by GameMode: true while a round is running and may be paused.
var can_pause := false
var screen := Screen.NONE

var _root: Control
var _title: Control
var _pause: Control
var _over: Control
var _over_title: Label
var _over_sub: Label
var _over_restart: Button
var _pause_resume: Button
var _title_first: Button
var _difficulty_btn: Button
var _gore_btn: Button
var _help: PanelContainer

func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = UIKit.full_rect("MenusRoot")
	add_child(_root)
	_build_title()
	_build_pause()
	_build_round_over()
	_help = UIKit.controls_panel()
	_root.add_child(_help)
	hide_all()

# --- Public API ------------------------------------------------------------------
func show_title() -> void:
	hide_all()
	screen = Screen.TITLE
	_title.visible = true
	_refresh_option_labels()
	_title_first.call_deferred(&"grab_focus")

func show_pause() -> void:
	hide_all()
	screen = Screen.PAUSE
	_pause.visible = true
	_pause_resume.call_deferred(&"grab_focus")

func show_round_over(won: bool, stats: String) -> void:
	hide_all()
	screen = Screen.ROUND_OVER
	_over.visible = true
	_over_title.text = "VICTORY" if won else "DEFEATED"
	_over_title.add_theme_color_override(&"font_color", Color(1.0, 0.85, 0.35) if won else UIKit.HP_COLOR)
	_over_sub.text = stats
	_over_restart.call_deferred(&"grab_focus")

func hide_all() -> void:
	screen = Screen.NONE
	if _title:
		_title.visible = false
		_pause.visible = false
		_over.visible = false
		_help.visible = false

# --- Input -------------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	if event.is_action_pressed(&"pause"):
		match screen:
			Screen.PAUSE:
				resume_pressed.emit()
				_handled()
			Screen.NONE:
				if can_pause:
					pause_requested.emit()
					_handled()
			Screen.TITLE:
				if _help.visible:
					_help.visible = false
					_handled()
	elif event.is_action_pressed(&"restart"):
		if screen == Screen.PAUSE or screen == Screen.ROUND_OVER:
			# Mark first: restart reloads the scene, which takes this node out
			# of the tree before emit() returns.
			_handled()
			restart_pressed.emit()
	elif event.is_action_pressed(&"help"):
		if screen != Screen.NONE:
			_help.visible = not _help.visible
			_handled()

func _handled() -> void:
	if is_inside_tree():
		get_viewport().set_input_as_handled()

# --- Build -------------------------------------------------------------------------
func _build_title() -> void:
	_title = Control.new()
	_title.name = "Title"
	_title.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_title)

	# Dark gradient on the left so the menu reads over the arena backdrop.
	var grad := Gradient.new()
	grad.set_color(0, Color(0.02, 0.02, 0.03, 0.94))
	grad.set_color(1, Color(0.02, 0.02, 0.03, 0.0))
	grad.add_point(0.55, Color(0.02, 0.02, 0.03, 0.8))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.width = 256
	gt.height = 4
	var shade := TextureRect.new()
	shade.texture = gt
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.add_child(shade)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	col.offset_left = 96
	col.offset_top = 48
	col.offset_bottom = -24
	col.add_theme_constant_override(&"separation", 8)
	_title.add_child(col)

	var title_box := VBoxContainer.new()
	title_box.add_theme_constant_override(&"separation", -40)
	col.add_child(title_box)
	title_box.add_child(UIKit.label("RAGDOLL", 96, Color.WHITE, true, 14))
	title_box.add_child(UIKit.label("BRAWLER", 96, UIKit.ACCENT, true, 14))
	col.add_child(UIKit.label("Every big hit ends with a body in flight.", 24, UIKit.TEXT_DIM, false, 4))
	var gap := Control.new()
	gap.custom_minimum_size.y = 18
	col.add_child(gap)

	_title_first = _menu_button(col, "DUEL  —  1v1 vs the Duelist", duel_pressed.emit)
	_menu_button(col, "WAVES  —  4 waves in The Yard", waves_pressed.emit)
	var lab := _menu_button(col, "RAGDOLL LAB", lab_pressed.emit)
	if not ResourceLoader.exists(LAB_SCENE):
		lab.disabled = true
		lab.text = "RAGDOLL LAB  (not built yet)"
	_difficulty_btn = _menu_button(col, "", _cycle_difficulty)
	_gore_btn = _menu_button(col, "", _cycle_gore)
	_menu_button(col, "QUIT", quit_pressed.emit)

	# Short controls summary, right side.
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.position.x -= 80
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 6)
	panel.add_child(box)
	box.add_child(UIKit.label("HOW TO FIGHT", 28, UIKit.ACCENT, true, 4))
	for line: Array in [
		["Move", "WASD", "Camera", "Mouse"],
		["Jab", "LMB", "Power punch", "hold RMB"],
		["Kick", "E", "Sweep", "Q"],
		["Grab / throw", "F", "Block", "Space"],
		["Dash", "Shift", "Pause", "Esc"],
	]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 8)
		box.add_child(row)
		for k in 2:
			var name_l := UIKit.label(line[k * 2], 20, UIKit.TEXT_DIM, false, 3)
			name_l.custom_minimum_size.x = 150
			name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			row.add_child(name_l)
			var key_l := UIKit.label(line[k * 2 + 1], 20, Color.WHITE, true, 3)
			key_l.custom_minimum_size.x = 110
			row.add_child(key_l)
	var tips := UIKit.label(
		"White glint: Block just before the hit to perfect-dodge,\nthen Jab or Kick to teleport behind them.\nRed glint: a grab. Press Grab to break it.\nKick bodies into walls and into each other.",
		18, UIKit.TEXT, false, 3)
	box.add_child(tips)
	box.add_child(UIKit.label("Gamepad works too.  F1: every control", 17, UIKit.TEXT_DIM, false, 3))

func _build_pause() -> void:
	_pause = _modal("PAUSED", Color.WHITE)
	var box: VBoxContainer = _pause.get_meta(&"box")
	_pause_resume = _menu_button(box, "RESUME", resume_pressed.emit)
	_menu_button(box, "RESTART  (R)", restart_pressed.emit)
	_menu_button(box, "MAIN MENU", menu_pressed.emit)
	box.add_child(UIKit.label("F1: controls", 18, UIKit.TEXT_DIM, false, 3))

func _build_round_over() -> void:
	_over = _modal("VICTORY", Color.WHITE)
	var box: VBoxContainer = _over.get_meta(&"box")
	_over_title = _over.get_meta(&"title")
	_over_sub = UIKit.label("", 24, UIKit.TEXT, false, 4)
	_over_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_over_sub)
	_over_restart = _menu_button(box, "RESTART  (R)", restart_pressed.emit)
	_menu_button(box, "MAIN MENU", menu_pressed.emit)

## Dimmed full-screen layer with a centred panel; the VBox is in meta "box".
func _modal(title: String, color: Color) -> Control:
	var layer_root := Control.new()
	layer_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(layer_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer_root.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 14)
	panel.add_child(box)
	var t := UIKit.label(title, 88, color, true, 12)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t)
	layer_root.set_meta(&"box", box)
	layer_root.set_meta(&"title", t)
	return layer_root

func _menu_button(parent: Control, text: String, on_press: Callable) -> Button:
	var b := UIKit.button(text)
	b.pressed.connect(on_press)
	b.focus_entered.connect(_on_button_focus.bind(b))
	b.mouse_entered.connect(func() -> void:
		if not b.disabled:
			b.grab_focus())
	parent.add_child(b)
	return b

func _on_button_focus(_b: Button) -> void:
	AudioFX.play_ui(&"ui", -4.0)

# --- Options -------------------------------------------------------------------------
func _cycle_difficulty() -> void:
	Tuning.difficulty = Tuning.Difficulty.NORMAL if Tuning.difficulty == Tuning.Difficulty.EASY else Tuning.Difficulty.EASY
	_refresh_option_labels()

func _cycle_gore() -> void:
	Tuning.gore = (Tuning.gore + 1) % 3
	_refresh_option_labels()

func _refresh_option_labels() -> void:
	var diff := "EASY" if Tuning.difficulty == Tuning.Difficulty.EASY else "NORMAL"
	_difficulty_btn.text = "DIFFICULTY:  %s" % diff
	var gore_names := ["OFF", "BLOOD", "DISMEMBERMENT"]
	_gore_btn.text = "GORE:  %s" % gore_names[clampi(Tuning.gore, 0, 2)]
