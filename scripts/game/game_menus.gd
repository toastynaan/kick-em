class_name GameMenus
extends CanvasLayer
## Title menu, pause menu and the results / round-over panel. Always processes
## (works while the tree is paused) and owns Esc (pause), Restart (Backspace /
## Back: in a round, in the pause menu and on the results) and F1 outside a
## round's HUD. Emits signals; GameMode does the work. Keyboard and gamepad
## navigable.
## OWNER: agent J (HUD, flow & menus).
##
## Pause > Debug settings holds the player's upgrades until the progression
## round (Round 7 amendment: God path): sprint speed cap (8 / 10 / 12 m/s),
## Battering Ram level (0-3), teleport (on / off), pursuit chain (0-3), plus the
## F3 overlay. Each writes its Tuning.debug_* static at once and is saved in
## user://settings.cfg (section "debug") next to the camera settings. The
## Focus meter is gone, so there is no starting-Focus setting.

signal duel_pressed
signal waves_pressed
signal lab_pressed
signal grab_lab_pressed
signal quit_pressed
signal pause_requested
signal resume_pressed
signal restart_pressed
signal menu_pressed

enum Screen { NONE, TITLE, PAUSE, ROUND_OVER, DEBUG }

const LAB_SCENE := "res://scenes/ragdoll_lab.tscn"
const GRAB_LAB_SCENE := "res://scenes/grab_lab.tscn"
## Same file as CameraRig.SETTINGS_PATH; each writer loads it first and keeps the other sections.
const SETTINGS_PATH := "user://settings.cfg"
const RAM_LEVELS := 4      ## Battering Ram 0 (not earned) .. 3
const PURSUIT_LEVELS := 4  ## pursuits chained off one launch: 0 (off) .. 3

static var _debug_loaded := false

## Set by GameMode: true while a round is running and may be paused.
var can_pause := false
## Set by GameMode: true from a round's start until it is torn down (the
## Restart key works in play, in the pause menu and on the results).
var can_restart := false
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
var sens_slider: HSlider
var invert_check: CheckButton
var _sens_value: Label
## Pause menu items (tests press them).
var restart_button: Button
var debug_settings_button: Button
var _debug: Control
var _debug_first: Button
## Debug setting buttons by key: &"speed_cap", &"ram_level", &"teleport",
## &"pursuit_max", &"overlay".
var debug_buttons := {}
var _over_grid: GridContainer
## Last stats shown on the results panel (tests read it).
var last_results := {}

func _ready() -> void:
	layer = UIKit.layer_above_screen_fx(get_tree(), 20)  # above the HUD (10) and ScreenFX
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = UIKit.full_rect("MenusRoot")
	add_child(_root)
	_build_title()
	_build_pause()
	_build_debug()
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
	_sync_camera_settings()
	_pause_resume.call_deferred(&"grab_focus")

## Results screen (Feel Reference F11): the run's stats as GameMode built them
## (GameMode.get_run_stats(): mode, won, waves_cleared, wave_reached, kills,
## time, biggest_hit (damage), biggest_hit_move, biggest_hit_react,
## walls_broken, objects_smashed, structures_down, limbs_taken).
func show_results(stats: Dictionary) -> void:
	hide_all()
	screen = Screen.ROUND_OVER
	last_results = stats.duplicate()
	_over.visible = true
	var won := bool(stats.get("won", false))
	var waves := StringName(stats.get("mode", &"duel")) == &"waves"
	_over_title.text = "VICTORY" if won else ("RUN OVER" if waves else "DEFEATED")
	_over_title.add_theme_color_override(&"font_color", UIKit.RESULT_GOOD if won else UIKit.HP_COLOR)
	if waves:
		_over_sub.text = "You fell in wave %d" % int(stats.get("wave_reached", 1))
	else:
		_over_sub.text = "Duel vs the Duelist" + ("" if won else "  ·  round lost")
	for c in _over_grid.get_children():
		_over_grid.remove_child(c)
		c.queue_free()
	for row: Array in results_rows(stats):
		var name_l := UIKit.label(row[0], 22, UIKit.TEXT_DIM, true, 3)
		name_l.custom_minimum_size.x = 260
		_over_grid.add_child(name_l)
		var val := UIKit.label(row[1], 26, Color.WHITE, true, 4)
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val.custom_minimum_size.x = 240
		_over_grid.add_child(val)
	_over_restart.call_deferred(&"grab_focus")

## [label, value] rows of the results screen.
static func results_rows(stats: Dictionary) -> Array:
	var rows: Array = []
	if StringName(stats.get("mode", &"duel")) == &"waves":
		rows.append(["WAVES CLEARED", "%d" % int(stats.get("waves_cleared", 0))])
	rows.append(["KILLS", "%d" % int(stats.get("kills", 0))])
	var secs := int(stats.get("time", 0.0))
	@warning_ignore("integer_division")
	rows.append(["TIME", "%d:%02d" % [secs / 60, secs % 60]])
	rows.append(["BIGGEST HIT", biggest_hit_text(stats)])
	rows.append(["WALLS BROKEN", "%d" % int(stats.get("walls_broken", 0))])
	rows.append(["OBJECTS SMASHED", "%d" % int(stats.get("objects_smashed", 0))])
	rows.append(["STRUCTURES BROUGHT DOWN", "%d" % int(stats.get("structures_down", 0))])
	rows.append(["LIMBS TAKEN", "%d" % int(stats.get("limbs_taken", 0))])
	return rows

func hide_all() -> void:
	screen = Screen.NONE
	if _title:
		_title.visible = false
		_pause.visible = false
		_over.visible = false
		_debug.visible = false
		_help.visible = false

## F3 may flip the overlay while Debug settings is up: keep its item honest.
func _process(_delta: float) -> void:
	if screen == Screen.DEBUG:
		_refresh_debug_labels()

# --- Input -------------------------------------------------------------------------
## Key names in the menus follow the device the player is using.
func _input(event: InputEvent) -> void:
	UIKit.note_input(event)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	if event.is_action_pressed(&"pause"):
		match screen:
			Screen.PAUSE:
				resume_pressed.emit()
				_handled()
			Screen.DEBUG:
				show_pause()
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
		if screen in [Screen.PAUSE, Screen.ROUND_OVER, Screen.DEBUG] or (screen == Screen.NONE and can_restart):
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
	_menu_button(col, "WAVES  —  how long can you last?", waves_pressed.emit)
	var lab := _menu_button(col, "RAGDOLL LAB", lab_pressed.emit)
	if not ResourceLoader.exists(LAB_SCENE):
		lab.disabled = true
		lab.text = "RAGDOLL LAB  (not built yet)"
	var grab_lab := _menu_button(col, "GRAB LAB", grab_lab_pressed.emit)
	if not ResourceLoader.exists(GRAB_LAB_SCENE):
		grab_lab.disabled = true
		grab_lab.text = "GRAB LAB  (not built yet)"
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
	for line: Array in title_key_lines():
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
	box.add_child(UIKit.label(title_tips(), 18, UIKit.TEXT, false, 3))
	box.add_child(UIKit.label("Gamepad works too.  F1: every control", 17, UIKit.TEXT_DIM, false, 3))

## [name, key, name, key] rows of the title's HOW TO FIGHT panel (keyboard + mouse).
static func title_key_lines() -> Array:
	var k := func(action: StringName) -> String: return UIKit.key_label(action, false)
	return [
		["Move", "WASD", "Camera", "Mouse"],
		["Punch", k.call(&"punch"), "Leg kick", k.call(&"leg_kick")],
		["Gut punch", k.call(&"gut_punch"), "Uppercut", k.call(&"uppercut")],
		["Front kick", k.call(&"front_kick"), "Roundhouse", k.call(&"roundhouse")],
		["Counter", UIKit.keys_label(&"counter", false), "Dash / sprint", k.call(&"dash")],
		["Jump", k.call(&"jump"), "Grab", k.call(&"grab")],
		["Restart", k.call(&"restart"), "Help", k.call(&"help")],
	]

## The title's short lesson on the Round 7 kit and the god path.
static func title_tips() -> String:
	var k := func(action: StringName) -> String: return UIKit.key_label(action, false)
	var back := "S"
	for spec: Array in Controls.ACTIONS.get(&"move_back", []):
		if spec[0] == &"key":
			back = OS.get_keycode_string(int(spec[1]))
	return ("Tap %s: jab, cross, hook. Hold it, or a kick: the heavy version.\n" % k.call(&"punch")
		+ "Uppercut lifts, gut punch folds, leg kick drops them to a knee:\nhit those states for bigger results.\n"
		+ "Orange icon over an enemy: %s to counter. Blue icon: %s to dodge.\n" % [k.call(&"counter"), k.call(&"dash")]
		+ "%s just before a hit lands: teleport behind them.\n" % k.call(&"dash")
		+ "Right after a launch, %s again to pursue the body: attack to send it\nfurther, or %s + attack to spike it into the ground.\n" % [k.call(&"dash"), back]
		+ "Hold %s to sprint: speed is power. Sprint + %s at a wall: wall run.\n" % [k.call(&"dash"), k.call(&"jump")]
		+ "Grab (%s), then hold %s to drive them through walls, or %s to throw.\n" % [
			k.call(&"grab"), k.call(&"dash"), k.call(&"punch")]
		+ "Launch bodies into walls and into each other.")

func _build_pause() -> void:
	_pause = _modal("PAUSED", Color.WHITE)
	var box: VBoxContainer = _pause.get_meta(&"box")
	_pause_resume = _menu_button(box, "RESUME", resume_pressed.emit)
	restart_button = _menu_button(box, restart_text(), restart_pressed.emit)
	debug_settings_button = _menu_button(box, "DEBUG SETTINGS", show_debug)
	_menu_button(box, "MAIN MENU", menu_pressed.emit)
	# Camera settings (saved to CameraRig.SETTINGS_PATH).
	var sens_row := HBoxContainer.new()
	sens_row.add_theme_constant_override(&"separation", 14)
	box.add_child(sens_row)
	var sens_name := UIKit.label("MOUSE SENSITIVITY", 22, UIKit.TEXT, true, 3)
	sens_name.custom_minimum_size.x = 250
	sens_row.add_child(sens_name)
	sens_slider = HSlider.new()
	sens_slider.min_value = Tuning.CAM_SENS_RANGE.x
	sens_slider.max_value = Tuning.CAM_SENS_RANGE.y
	sens_slider.step = 0.05
	sens_slider.custom_minimum_size = Vector2(160, 32)
	sens_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sens_slider.focus_mode = Control.FOCUS_ALL
	sens_row.add_child(sens_slider)
	_sens_value = UIKit.label("1.00", 22, Color.WHITE, true, 3)
	_sens_value.custom_minimum_size.x = 60
	sens_row.add_child(_sens_value)
	sens_slider.value_changed.connect(_on_sens_changed)
	invert_check = CheckButton.new()
	invert_check.text = "INVERT Y"
	invert_check.add_theme_font_override(&"font", UIKit.heavy_font())
	invert_check.add_theme_font_size_override(&"font_size", 22)
	invert_check.focus_mode = Control.FOCUS_ALL
	invert_check.toggled.connect(_on_invert_toggled)
	box.add_child(invert_check)
	box.add_child(UIKit.label("F1: controls", 18, UIKit.TEXT_DIM, false, 3))

func _sync_camera_settings() -> void:
	CameraRig.load_settings()
	sens_slider.set_value_no_signal(CameraRig.sensitivity)
	_sens_value.text = "%.2f" % CameraRig.sensitivity
	invert_check.set_pressed_no_signal(CameraRig.invert_y)

func _on_sens_changed(v: float) -> void:
	CameraRig.sensitivity = clampf(v, Tuning.CAM_SENS_RANGE.x, Tuning.CAM_SENS_RANGE.y)
	_sens_value.text = "%.2f" % CameraRig.sensitivity
	CameraRig.save_settings()

func _on_invert_toggled(on: bool) -> void:
	CameraRig.invert_y = on
	CameraRig.save_settings()

func _build_round_over() -> void:
	_over = _modal("VICTORY", Color.WHITE)
	var box: VBoxContainer = _over.get_meta(&"box")
	_over_title = _over.get_meta(&"title")
	_over_sub = UIKit.label("", 24, UIKit.TEXT, false, 4)
	_over_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_over_sub)
	_over_grid = GridContainer.new()
	_over_grid.columns = 2
	_over_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_over_grid.add_theme_constant_override(&"v_separation", 4)
	box.add_child(_over_grid)
	var gap := Control.new()
	gap.custom_minimum_size.y = 6
	box.add_child(gap)
	_over_restart = _menu_button(box, restart_text(), restart_pressed.emit)
	_menu_button(box, "MAIN MENU", menu_pressed.emit)

# --- Labels and debug settings ---------------------------------------------------
## "RESTART  (Backspace / Back)": the Restart keys of both devices.
static func restart_text() -> String:
	return "RESTART  (%s / %s)" % [UIKit.key_label(&"restart", false), UIKit.key_label(&"restart", true)]

## "21  ROUNDHOUSE  LAUNCH": the player's hardest single hit (damage, move,
## and the reaction when it sent the body down or flying); "-" when none.
static func biggest_hit_text(stats: Dictionary) -> String:
	var dmg := float(stats.get("biggest_hit", 0.0))
	if dmg <= 0.0:
		return "-"
	var text := "%d" % roundi(dmg)
	var move := String(stats.get("biggest_hit_move", &"")).replace("_", " ").to_upper()
	if move != "":
		text += "  " + move
	var react := StringName(stats.get("biggest_hit_react", &""))
	if react in [&"launch", &"knockdown"]:
		text += "  " + String(react).to_upper()
	return text

## Pause > Debug settings: the player's upgrades and the F3 overlay.
func show_debug() -> void:
	hide_all()
	screen = Screen.DEBUG
	_debug.visible = true
	_refresh_debug_labels()
	_debug_first.call_deferred(&"grab_focus")

func _build_debug() -> void:
	_debug = _modal("DEBUG", Color.WHITE)
	var box: VBoxContainer = _debug.get_meta(&"box")
	(_debug.get_meta(&"title") as Label).add_theme_font_size_override(&"font_size", 64)
	box.add_child(UIKit.label("Your upgrades until progression arrives. Saved between sessions.", 18, UIKit.TEXT_DIM, false, 3))
	_debug_first = _debug_button(box, &"speed_cap")
	_debug_button(box, &"ram_level")
	_debug_button(box, &"teleport")
	_debug_button(box, &"pursuit_max")
	_debug_button(box, &"overlay")
	_menu_button(box, "BACK", show_pause)
	box.add_child(UIKit.label("Enter / A: next value   ←/→: change", 18, UIKit.TEXT_DIM, false, 3))

## A button that cycles one setting: press = next value, left / right = step.
func _debug_button(parent: Control, key: StringName) -> Button:
	var b := _menu_button(parent, "", step_debug_setting.bind(key, 1))
	b.gui_input.connect(func(ev: InputEvent) -> void:
		if ev.is_action_pressed(&"ui_left") or ev.is_action_pressed(&"ui_right"):
			step_debug_setting(key, -1 if ev.is_action_pressed(&"ui_left") else 1)
			b.accept_event())
	debug_buttons[key] = b
	return b

## Step a debug setting by `dir` (wraps), apply it to Tuning at once and save.
func step_debug_setting(key: StringName, dir: int) -> void:
	match key:
		&"speed_cap":
			var caps := Tuning.SPRINT_CAPS
			var i := caps.find(Tuning.debug_speed_cap)
			Tuning.debug_speed_cap = caps[wrapi((i if i >= 0 else 0) + dir, 0, caps.size())]
		&"ram_level":
			Tuning.debug_ram_level = wrapi(Tuning.debug_ram_level + dir, 0, RAM_LEVELS)
		&"teleport":
			Tuning.debug_teleport = not Tuning.debug_teleport
		&"pursuit_max":
			Tuning.debug_pursuit_max = wrapi(Tuning.debug_pursuit_max + dir, 0, PURSUIT_LEVELS)
		&"overlay":
			Tuning.debug_overlay = not Tuning.debug_overlay
	save_debug_settings()
	_refresh_debug_labels()

## The F3 overlay on or off (Debug settings item), applied at once and saved.
func toggle_overlay() -> void:
	step_debug_setting(&"overlay", 1)

func _refresh_debug_labels() -> void:
	if debug_buttons.is_empty():
		return
	(debug_buttons[&"speed_cap"] as Button).text = "SPEED CAP:  %d m/s%s" % [roundi(Tuning.debug_speed_cap),
		"  (base)" if is_equal_approx(Tuning.debug_speed_cap, Tuning.SPRINT_CAPS[0]) else "  (upgraded)"]
	(debug_buttons[&"ram_level"] as Button).text = "BATTERING RAM:  %s" % (
		"0  (not earned)" if Tuning.debug_ram_level <= 0
		else "LEVEL %d%s" % [Tuning.debug_ram_level, "  (launches)" if Tuning.debug_ram_level >= RAM_LEVELS - 1 else ""])
	(debug_buttons[&"teleport"] as Button).text = "TELEPORT:  %s" % ("ON" if Tuning.debug_teleport else "OFF")
	(debug_buttons[&"pursuit_max"] as Button).text = "PURSUIT CHAIN:  %s" % (
		"0  (off)" if Tuning.debug_pursuit_max <= 0 else "%d per launch" % Tuning.debug_pursuit_max)
	(debug_buttons[&"overlay"] as Button).text = "DEBUG OVERLAY (F3):  %s" % ("ON" if Tuning.debug_overlay else "OFF")

## Load the debug settings once per session (GameMode._ready). force: reload.
## The speed cap must be one of Tuning.SPRINT_CAPS; levels are clamped.
static func load_debug_settings(force := false) -> void:
	if _debug_loaded and not force:
		return
	_debug_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	var cap := float(cfg.get_value("debug", "speed_cap", Tuning.debug_speed_cap))
	if Tuning.SPRINT_CAPS.has(cap):
		Tuning.debug_speed_cap = cap
	Tuning.debug_ram_level = clampi(int(cfg.get_value("debug", "ram_level", Tuning.debug_ram_level)), 0, RAM_LEVELS - 1)
	Tuning.debug_teleport = bool(cfg.get_value("debug", "teleport", Tuning.debug_teleport))
	Tuning.debug_pursuit_max = clampi(int(cfg.get_value("debug", "pursuit_max", Tuning.debug_pursuit_max)), 0, PURSUIT_LEVELS - 1)
	Tuning.debug_overlay = bool(cfg.get_value("debug", "overlay", Tuning.debug_overlay))

static func save_debug_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # keep the camera section
	cfg.set_value("debug", "speed_cap", Tuning.debug_speed_cap)
	cfg.set_value("debug", "ram_level", Tuning.debug_ram_level)
	cfg.set_value("debug", "teleport", Tuning.debug_teleport)
	cfg.set_value("debug", "pursuit_max", Tuning.debug_pursuit_max)
	cfg.set_value("debug", "overlay", Tuning.debug_overlay)
	cfg.save(SETTINGS_PATH)

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
