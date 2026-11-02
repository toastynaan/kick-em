class_name HUD
extends CanvasLayer
## Player HP bar, Focus (3 bars), wave counter, bowling chain (x2, x3), off-screen
## attack arrows, perfect-dodge flash, controls help (F1), debug overlay (F3),
## title menu, pause and round-over panels. OWNER: agent E.
## (Title, pause and round-over panels live in GameMenus; this layer is the
## in-round overlay.) Built entirely in code. No health bars over enemies.

const HP_DELAY := 0.55          ## s before the "damage taken" bar starts to drain
const HP_DRAIN := 0.45          ## share of max HP drained per second by that bar
const CHAIN_HOLD := 2.2         ## s the bowling chain counter stays up
const ARROW_GRACE := 0.3        ## s an off-screen arrow outlives the tell
const ARROW_MARGIN := 56.0      ## px from the screen edge
const DEBUG_REFRESH := 0.2      ## s
const HINT_TIME := 9.0          ## s the key hint stays on screen at round start
const POPUP_MAX := 14           ## world popups alive at once (oldest dropped)
const POPUP_RISE := 46.0        ## px a popup drifts up over its life
const OPP_W := 360.0            ## px, duel opponent HP bar width
const FLOOR_SLAM_HEIGHT := 0.35 ## m: impacts lower than this read as FLOOR SLAM
const POPUP_STACK_AGE := 0.6    ## s a popup counts as recent for stacking
const POPUP_MARGIN_SIDE := 24.0 ## px safe margin left/right for world popups
const POPUP_MARGIN_TOP := 120.0 ## px: popups stay below the top HUD rows
const POPUP_MARGIN_BOTTOM := 70.0
const BANNER_CLEAR := 8.0       ## px gap kept between a popup and a banner
const CHAIN_MERGE_TIME := 1.0   ## s: THROUGH N WALLS replaces a WALL BREAK banner this recent
const POP_SIZE := 76            ## px, WALL BREAK / PERFECT / COUNTER pop text
const POP_Y_FRAC := -0.31       ## pop text centre at 19% of the screen height (was 30%)
const CHARGE_FLASH := 0.35      ## s the charge meter stays up after the release
const COMBO_HOLD := 1.6         ## s the combo counter stays after the last hit
const FOCUS_TINT := 0.1         ## alpha of the cold screen tint during Focus

var player: Fighter
var mode: StringName = &"duel"

var _root: Control
var _bars: _Bars
var _hp_label: Label
var _focus_label: Label
var _mode_label: Label
var _sub_label: Label
var _chain_label: Label
var _chain_sub: Label
var _pop_label: Label
var _banner_label: Label
var _banner_sub: Label
var _flash: ColorRect
var _hurt: ColorRect
var _arrows: _Arrows
var _help: PanelContainer
var _debug_panel: PanelContainer
var _debug_label: Label
var _hint: Label
var _charge: _Charge
var _prompt: Label
var _reticle: _Reticle
var _focus_tint: ColorRect
var _combo_label: Label
var _combo_sub: Label
var _combo_count := 0
var _combo_at := -100.0
var _charging := false
var _charge_level := 0
var _charge_t0 := 0.0
var _charge_move: StringName = &""
var _charge_release_at := -100.0
var _popups: _Popups
var _popup_items: Array[Dictionary] = []   ## {pos, text, color, size, t0, dur}
var _suppressed_walls := {}                 ## wall instance id -> true (staged breaches)
var _popup_rects: Array[Rect2] = []         ## last laid-out popup rects (screen px)
var _wall_break_at := -100.0                ## real s the WALL BREAK banner last appeared
var _last_chain_at := -100.0
var _last_chain_count := 0
var opponent: Fighter                       ## duel mode: the Duelist
var _opp_root: Control
var _opp_bars: _Bars
var _opp_hp_label: Label
var _opp_hp_delayed := 1.0
var _opp_hp_last := -1.0
var _opp_hit_at := -100.0

var _hp_shown := 1.0
var _hp_delayed := 1.0
var _hp_last := -1.0
var _hp_hit_at := -100.0
var _chain := 0
var _chain_at := -100.0
var _tells: Array[Dictionary] = []   ## {fighter, kind, until}
var _last_real := 0.0
var _debug_t := 0.0
var _hint_until := 0.0
var _wave_index := 0
var _wave_total := 0
var _enemies_left := 0
var _round_over := false

func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_last_real = TimeDirector.now()
	_build()
	GameEvents.perfect_dodge.connect(_on_perfect_dodge)
	GameEvents.teleport_counter.connect(_on_teleport_counter)
	GameEvents.wall_broken.connect(_on_wall_broken)
	GameEvents.body_bowled.connect(_on_body_bowled)
	GameEvents.attack_tell.connect(_on_attack_tell)
	GameEvents.grab_broken.connect(_on_grab_broken)
	GameEvents.pursuit.connect(_on_pursuit)
	GameEvents.air_recovery.connect(_on_air_recovery)
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.wave_started.connect(_on_wave_started)
	GameEvents.impact_damaged.connect(_on_impact_damaged)
	GameEvents.wall_chain.connect(_on_wall_chain)
	GameEvents.armor_absorbed.connect(_on_armor_absorbed)
	GameEvents.dodge_feedback.connect(_on_dodge_feedback)
	GameEvents.charge_started.connect(_on_charge_started)
	GameEvents.charge_level_changed.connect(_on_charge_level_changed)
	GameEvents.charge_released.connect(_on_charge_released)
	GameEvents.combo_progress.connect(_on_combo_progress)
	GameEvents.combo_ended.connect(_on_combo_ended)
	_hint_until = TimeDirector.now() + HINT_TIME

# --- Public API ----------------------------------------------------------------
func set_player(f: Fighter) -> void:
	player = f
	if f:
		_hp_shown = f.hp / maxf(f.max_hp, 1.0)
		_hp_delayed = _hp_shown
		_hp_last = f.hp

func set_mode(m: StringName) -> void:
	mode = m
	_refresh_mode_labels()

func set_wave(index: int, total: int) -> void:
	_wave_index = index
	_wave_total = total
	_refresh_mode_labels()

func set_enemies_left(n: int) -> void:
	if n != _enemies_left:
		_enemies_left = n
		_refresh_mode_labels()

## Big centre banner ("WAVE 2", "FIGHT").
func show_banner(text: String, sub := "", duration := 1.8) -> void:
	_banner_label.text = text
	_banner_sub.text = sub
	_pop(_banner_label, 1.35, duration)
	_pop(_banner_sub, 1.0, duration)

## Short pop text ("PERFECT", "COUNTER", "WALL BREAK").
func pop_text(text: String, color := UIKit.TEXT, duration := 0.9) -> void:
	_pop_label.text = text
	_pop_label.add_theme_color_override(&"font_color", color)
	_pop(_pop_label, 1.6, duration)

## Full-screen flash that fades over `duration` real seconds.
func flash(color: Color, duration := 0.25) -> void:
	_flash.color = color
	_flash.modulate.a = 1.0
	var tw := _tween()
	tw.tween_property(_flash, ^"modulate:a", 0.0, duration)

func toggle_help() -> void:
	_help.visible = not _help.visible

func toggle_debug() -> void:
	_debug_panel.visible = not _debug_panel.visible
	_debug_t = 0.0

func is_help_visible() -> bool:
	return _help.visible

## Duel mode: show the opponent's HP bar and Focus pips (waves keep no enemy bars).
func set_opponent(f: Fighter) -> void:
	opponent = f
	_opp_root.visible = f != null
	if f:
		_opp_hp_delayed = f.hp / maxf(f.max_hp, 1.0)
		_opp_hp_last = f.hp
	_debug_panel.position.y = 150.0

## Do not announce WALL BREAK for this panel (GameMode's staged breach entries).
func suppress_wall_break(wall: Node3D) -> void:
	if wall != null:
		_suppressed_walls[wall.get_instance_id()] = true

## World-space popup (projected each frame), e.g. "WALL SLAM −271" at the impact.
func popup_at(world_pos: Vector3, text: String, color := UIKit.TEXT, size := 34, duration := 1.1) -> void:
	# Stack above recent popups at the same spot (a body through two walls
	# reports the slam and the chain together): lift by their height in pixels.
	var t := TimeDirector.now()
	var lift := 0.0
	for p in _popup_items:
		var other: Vector3 = p["pos"]
		if t - float(p["t0"]) < POPUP_STACK_AGE and absf(other.y - world_pos.y) < 1.0 \
				and Vector2(other.x - world_pos.x, other.z - world_pos.z).length() < 1.5:
			lift = maxf(lift, float(p["lift"]) + float(p["size"]) * 1.05)
	_popup_items.append({"pos": world_pos, "text": text, "color": color, "size": size,
		"t0": t, "dur": duration, "lift": lift})
	while _popup_items.size() > POPUP_MAX:
		_popup_items.pop_front()

func get_popup_texts() -> PackedStringArray:
	var out := PackedStringArray()
	for p in _popup_items:
		out.append(p["text"])
	return out

## Hide transient elements (round over).
func set_round_over() -> void:
	_round_over = true
	_help.visible = false
	_tells.clear()
	_chain_label.modulate.a = 0.0
	_chain_sub.modulate.a = 0.0

# --- Build -----------------------------------------------------------------------
func _build() -> void:
	_root = UIKit.full_rect("HUDRoot")
	add_child(_root)

	_hurt = ColorRect.new()
	_hurt.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hurt.color = Color(0.7, 0.0, 0.0, 0.22)
	_hurt.modulate.a = 0.0
	_hurt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_hurt)

	_flash = ColorRect.new()
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.color = Color(0.7, 0.92, 1.0, 0.4)
	_flash.modulate.a = 0.0
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_flash)

	_arrows = _Arrows.new()
	_arrows.set_anchors_preset(Control.PRESET_FULL_RECT)
	_arrows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_arrows)

	# Player block, top-left.
	var name_l := UIKit.label("YOU", 20, UIKit.TEXT_DIM, true, 5)
	name_l.position = Vector2(36, 18)
	_root.add_child(name_l)
	_bars = _Bars.new()
	_bars.position = Vector2(36, 48)
	_bars.size = Vector2(_Bars.HP_W, 80)
	_bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_bars)
	_hp_label = UIKit.label("1000", 24, Color.WHITE, true, 6)
	_hp_label.position = Vector2(36 + _Bars.HP_W + 14, 44)
	_root.add_child(_hp_label)
	_focus_label = UIKit.label("FOCUS", 18, UIKit.FOCUS_COLOR, true, 5)
	_focus_label.position = Vector2(36 + _Bars.FOCUS_W * 3 + _Bars.FOCUS_GAP * 3 + 4, 84)
	_root.add_child(_focus_label)

	# Mode / wave counter, top-centre.
	var top := VBoxContainer.new()
	top.set_anchors_preset(Control.PRESET_CENTER_TOP)
	top.grow_horizontal = Control.GROW_DIRECTION_BOTH
	top.position.y = 16
	top.alignment = BoxContainer.ALIGNMENT_BEGIN
	top.add_theme_constant_override(&"separation", 0)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(top)
	_mode_label = UIKit.label("DUEL", 40, Color.WHITE, true, 8)
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(_mode_label)
	_sub_label = UIKit.label("", 22, UIKit.TEXT_DIM, false, 6)
	_sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(_sub_label)

	# Bowling chain, right side: "x3" over "BOWLED".
	var chain_box := VBoxContainer.new()
	chain_box.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	chain_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	chain_box.grow_vertical = Control.GROW_DIRECTION_BOTH
	chain_box.offset_left = -260
	chain_box.offset_right = -60
	chain_box.offset_top = -200
	chain_box.offset_bottom = -20
	chain_box.alignment = BoxContainer.ALIGNMENT_END
	chain_box.add_theme_constant_override(&"separation", -22)
	chain_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(chain_box)
	_chain_label = UIKit.label("", 96, UIKit.ACCENT, true, 12)
	_chain_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_chain_label.modulate.a = 0.0
	chain_box.add_child(_chain_label)
	_chain_sub = UIKit.label("BOWLED", 26, UIKit.TEXT, true, 6)
	_chain_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_chain_sub.modulate.a = 0.0
	chain_box.add_child(_chain_sub)

	# Pop text (upper third) and banner (centre).
	# Upper band, off the screen centre: when the player faces a wall the hole
	# is at the centre and must stay visible (anchored by fraction, so it holds
	# at 1600x900 and 3456x2168 alike).
	_pop_label = _centered_label(POP_SIZE, POP_Y_FRAC)
	_banner_label = _centered_label(120, -0.04)
	_banner_sub = _centered_label(30, 0.08)
	_banner_sub.add_theme_font_override(&"font", UIKit.heavy_font())

	# Key hint, bottom-left.
	_hint = UIKit.label("F1 controls     F3 debug     Esc pause", 18, UIKit.TEXT_DIM, false, 5)
	_hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hint.position = Vector2(36, -48)
	_root.add_child(_hint)

	# Power punch charge meter, bottom-centre (only while Heavy is held).
	# Focus: faint cold tint over the world while it runs.
	_focus_tint = ColorRect.new()
	_focus_tint.set_anchors_preset(Control.PRESET_FULL_RECT)
	_focus_tint.color = Color(0.35, 0.62, 1.0, 1.0)
	_focus_tint.modulate.a = 0.0
	_focus_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_focus_tint)
	_root.move_child(_focus_tint, 0)

	# Centre reticle: zone aiming is from the screen centre.
	_reticle = _Reticle.new()
	_reticle.set_anchors_preset(Control.PRESET_CENTER)
	_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_reticle)

	# Combo counter, left of centre: "4 HITS" over "DMG 80%".
	var combo_box := VBoxContainer.new()
	combo_box.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	combo_box.offset_left = 40.0
	combo_box.offset_right = 360.0
	combo_box.offset_top = -40.0
	combo_box.offset_bottom = 90.0
	combo_box.add_theme_constant_override(&"separation", -14)
	combo_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(combo_box)
	_combo_label = UIKit.label("", 64, Color.WHITE, true, 10)
	_combo_label.modulate.a = 0.0
	combo_box.add_child(_combo_label)
	_combo_sub = UIKit.label("", 24, UIKit.ACCENT, true, 6)
	_combo_sub.modulate.a = 0.0
	combo_box.add_child(_combo_sub)

	_charge = _Charge.new()
	_charge.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_charge.offset_left = -_Charge.W * 0.5
	_charge.offset_right = _Charge.W * 0.5
	_charge.offset_top = -190
	_charge.offset_bottom = -140
	_charge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_charge.visible = false
	_root.add_child(_charge)

	# Action prompts: "COUNTER!  Jab / Kick" during the dodge window, "PURSUIT  Dash".
	_prompt = UIKit.label("", 40, UIKit.ACCENT, true, 8)
	_prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_prompt.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.offset_left = -400
	_prompt.offset_right = 400
	_prompt.offset_top = -270
	_prompt.offset_bottom = -210
	_prompt.visible = false
	_root.add_child(_prompt)

	# World popups (impact numbers, ARMOR, EARLY/LATE), drawn under the banners.
	_popups = _Popups.new()
	_popups.set_anchors_preset(Control.PRESET_FULL_RECT)
	_popups.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_popups)
	_root.move_child(_popups, _arrows.get_index() + 1)

	# Duel opponent, top-right: name, HP bar with damage trail, Focus pips.
	_opp_root = Control.new()
	_opp_root.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_opp_root.offset_left = -(OPP_W + 36.0 + 70.0)
	_opp_root.offset_right = -36.0
	_opp_root.offset_top = 18.0
	_opp_root.offset_bottom = 120.0
	_opp_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_opp_root.visible = false
	_root.add_child(_opp_root)
	var opp_name := UIKit.label("THE DUELIST", 20, UIKit.TEXT_DIM, true, 5)
	opp_name.position = Vector2(70.0, 0.0)
	_opp_root.add_child(opp_name)
	_opp_bars = _Bars.new()
	_opp_bars.hp_w = OPP_W
	_opp_bars.pips = true
	_opp_bars.position = Vector2(70.0, 30.0)
	_opp_bars.size = Vector2(OPP_W, 70)
	_opp_bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_opp_root.add_child(_opp_bars)
	_opp_hp_label = UIKit.label("750", 24, Color.WHITE, true, 6)
	_opp_hp_label.position = Vector2(0.0, 26.0)
	_opp_hp_label.custom_minimum_size.x = 60.0
	_opp_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_opp_root.add_child(_opp_hp_label)

	# Debug overlay, top-right.
	_debug_panel = PanelContainer.new()
	_debug_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_debug_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_debug_panel.position = Vector2(-24, 150)  # below the wave counter and the opponent bar
	_debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_debug_panel.visible = false
	_root.add_child(_debug_panel)
	_debug_label = UIKit.label("", 16, UIKit.TEXT, false, 3)
	_debug_panel.add_child(_debug_label)

	_help = UIKit.controls_panel()
	_root.add_child(_help)
	_refresh_mode_labels()

func _centered_label(size: int, y_frac: float) -> Label:
	@warning_ignore("integer_division")
	var l := UIKit.label("", size, Color.WHITE, true, maxi(6, size / 9))
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.anchor_top = 0.5 + y_frac
	l.anchor_bottom = 0.5 + y_frac
	l.offset_top = -size
	l.offset_bottom = size
	l.modulate.a = 0.0
	_root.add_child(l)
	return l

func _refresh_mode_labels() -> void:
	if _mode_label == null:
		return
	if mode == &"waves":
		_mode_label.text = "WAVE %d/%d" % [_wave_index + 1, maxi(_wave_total, 1)]
		_sub_label.text = "%d %s LEFT" % [_enemies_left, "ENEMY" if _enemies_left == 1 else "ENEMIES"]
	else:
		_mode_label.text = "DUEL"
		_sub_label.text = "vs THE DUELIST" if _enemies_left > 0 else ""

# --- Animation helpers -------------------------------------------------------------
func _tween() -> Tween:
	var tw := create_tween()
	tw.set_ignore_time_scale(true)
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	return tw

func _pop(l: Label, from_scale: float, hold: float) -> void:
	l.pivot_offset = l.size * 0.5
	l.scale = Vector2.ONE * from_scale
	l.modulate.a = 1.0
	var tw := _tween()
	tw.tween_property(l, ^"scale", Vector2.ONE, 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(maxf(hold - 0.4, 0.05))
	tw.tween_property(l, ^"modulate:a", 0.0, 0.26)

# --- Per frame ------------------------------------------------------------------
func _process(_delta: float) -> void:
	var t := TimeDirector.now()
	var dt := TimeDirector.frame_delta()
	_last_real = t
	_update_player_bars(t, dt)
	_update_opponent(t, dt)
	_update_popups(t)
	_update_chain(t)
	_update_arrows(t)
	if _hint.visible and t > _hint_until:
		_hint.modulate.a = maxf(_hint.modulate.a - dt * 1.5, 0.0)
		if _hint.modulate.a <= 0.0:
			_hint.visible = false
	if _debug_panel.visible:
		_debug_t -= dt
		if _debug_t <= 0.0:
			_debug_t = DEBUG_REFRESH
			_debug_label.text = _debug_text()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"help"):
		# While paused or after the round, GameMenus shows its own help on top.
		if get_tree().paused or _round_over:
			return
		toggle_help()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"debug"):
		toggle_debug()
		get_viewport().set_input_as_handled()

func _update_player_bars(t: float, dt: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	var max_hp := maxf(player.max_hp, 1.0)
	if player.hp < _hp_last - 0.01:
		_hp_hit_at = t
	_hp_last = player.hp
	var frac := clampf(player.hp / max_hp, 0.0, 1.0)
	_hp_shown = move_toward(_hp_shown, frac, dt * 3.0) if frac > _hp_shown else frac
	if _hp_delayed < _hp_shown:
		_hp_delayed = _hp_shown
	elif t - _hp_hit_at > HP_DELAY:
		_hp_delayed = move_toward(_hp_delayed, _hp_shown, dt * HP_DRAIN)
	_bars.hp = _hp_shown
	_bars.hp_delayed = _hp_delayed
	_bars.focus = player.focus
	var focus_on := TimeDirector.is_focus_active()
	_bars.focus_active = focus_on
	_focus_tint.modulate.a = move_toward(_focus_tint.modulate.a, FOCUS_TINT if focus_on else 0.0, dt * 0.6)
	_reticle.visible = not _round_over and not player.is_down()
	_reticle.focus = focus_on
	_reticle.queue_redraw()
	if _combo_count > 0 and t - _combo_at > COMBO_HOLD:
		_combo_count = 0
		var tw := _tween()
		tw.tween_property(_combo_label, ^"modulate:a", 0.0, 0.3)
		tw.parallel().tween_property(_combo_sub, ^"modulate:a", 0.0, 0.3)
	_bars.low = frac < 0.25
	_bars.pulse = t
	_bars.queue_redraw()
	_update_combat_cues(t)
	_hp_label.text = "%d" % ceili(player.hp)
	_focus_label.text = ("FOCUS ON " if focus_on else "FOCUS ") + String.num(player.focus, 2)

## Charge meter and action prompts from the player's CombatController
## (called dynamically: these queries are B's additions to the contract).
func _update_combat_cues(t: float) -> void:
	var c: Node = player.combat
	if c == null or player.is_dead():
		_charge.visible = false
		_prompt.visible = false
		return
	# Charge: events drive it (charge_started / level / released); polling
	# get_charge_level() covers a missed event.
	var polled: int = c.call(&"get_charge_level") if c.has_method(&"get_charge_level") else 0
	if polled > 0 and not _charging:
		_charging = true
		_charge_t0 = t - Tuning.CHARGE_LEVELS[clampi(polled - 1, 0, 2)]
	if _charging:
		_charge_level = maxi(_charge_level, polled)
	var show_charge := _charging or t - _charge_release_at < CHARGE_FLASH
	_charge.visible = show_charge
	if show_charge:
		_charge.level = _charge_level
		_charge.fill = clampf((t - _charge_t0) / Tuning.CHARGE_LEVELS[2], 0.0, 1.0) if _charging else 1.0
		_charge.released = not _charging
		_charge.move_name = String(_charge_move).to_upper()
		_charge.pulse = t
		_charge.queue_redraw()
	var text := ""
	var color := UIKit.ACCENT
	if c.has_method(&"can_counter") and c.call(&"can_counter"):
		text = "COUNTER!   Punch / Kick"
	elif c.has_method(&"can_pursue") and c.call(&"can_pursue"):
		text = "PURSUIT   Dash"
		color = UIKit.FOCUS_COLOR
	_prompt.visible = text != ""
	if _prompt.visible:
		_prompt.text = text
		_prompt.add_theme_color_override(&"font_color", color)
		_prompt.modulate.a = 0.75 + 0.25 * sin(t * 20.0)

func _update_opponent(t: float, dt: float) -> void:
	if not _opp_root.visible:
		return
	if not is_instance_valid(opponent):
		_opp_bars.hp = 0.0
		_opp_bars.focus = 0.0
		_opp_hp_label.text = "0"
		_opp_bars.queue_redraw()
		return
	var f: Fighter = opponent
	var max_hp := maxf(f.max_hp, 1.0)
	if f.hp < _opp_hp_last - 0.01:
		_opp_hit_at = t
	_opp_hp_last = f.hp
	var frac := clampf(f.hp / max_hp, 0.0, 1.0)
	if _opp_hp_delayed < frac:
		_opp_hp_delayed = frac
	elif t - _opp_hit_at > HP_DELAY:
		_opp_hp_delayed = move_toward(_opp_hp_delayed, frac, dt * HP_DRAIN)
	_opp_bars.hp = frac
	_opp_bars.hp_delayed = _opp_hp_delayed
	_opp_bars.focus = f.focus
	_opp_bars.pulse = t
	_opp_bars.queue_redraw()
	_opp_hp_label.text = "%d" % ceili(f.hp)

## Project world popups to the screen; drop expired ones.
func _update_popups(t: float) -> void:
	var cam := get_viewport().get_camera_3d()
	var items: Array = []
	var rects: Array[Rect2] = []
	var banners := get_banner_rects()
	var i := _popup_items.size() - 1
	while i >= 0:
		var p: Dictionary = _popup_items[i]
		var age := t - float(p["t0"])
		var dur: float = p["dur"]
		if age > dur:
			_popup_items.remove_at(i)
		elif cam != null and not cam.is_position_behind(p["pos"]):
			var k := age / dur
			var sp := cam.unproject_position(p["pos"])
			var pop := 1.0 + 0.45 * maxf(1.0 - age / 0.12, 0.0)
			var col: Color = p["color"]
			col.a = clampf((1.0 - k) / 0.3, 0.0, 1.0)
			var size := int(p["size"])
			var center := _layout_popup(sp - Vector2(0.0, POPUP_RISE * k + float(p["lift"])),
				_popup_size(p["text"], size), banners)
			items.append({"pos": center, "text": p["text"], "color": col, "size": size, "scale": pop})
			rects.append(Rect2(center - _popup_size(p["text"], size) * 0.5, _popup_size(p["text"], size)))
		i -= 1
	_popups.items = items
	_popup_rects = rects
	_popups.queue_redraw()

func _popup_size(text: String, size: int) -> Vector2:
	var w := UIKit.heavy_font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	return Vector2(w, size * 1.1)

## Keep a popup inside the safe margins and out of every visible banner band.
func _layout_popup(center: Vector2, size: Vector2, banners: Array[Rect2]) -> Vector2:
	var vp := get_viewport().get_visible_rect().size
	var half := size * 0.5
	var c := center
	c.x = clampf(c.x, POPUP_MARGIN_SIDE + half.x, maxf(vp.x - POPUP_MARGIN_SIDE - half.x, POPUP_MARGIN_SIDE + half.x))
	c.y = clampf(c.y, POPUP_MARGIN_TOP + half.y, maxf(vp.y - POPUP_MARGIN_BOTTOM - half.y, POPUP_MARGIN_TOP + half.y))
	for b in banners:
		var r := Rect2(c - half, size).grow(BANNER_CLEAR)
		if r.intersects(b):
			var below := b.end.y + half.y + BANNER_CLEAR
			if below + half.y <= vp.y - POPUP_MARGIN_BOTTOM:
				c.y = below
			else:
				c.y = b.position.y - half.y - BANNER_CLEAR
	return c

## Screen rects of the big centre texts currently showing (WALL BREAK, WAVE n...).
func get_banner_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	for l: Label in [_pop_label, _banner_label, _banner_sub]:
		if l == null or not l.visible or l.modulate.a < 0.05 or l.text == "":
			continue
		var fs := l.get_theme_font_size(&"font_size")
		var font := l.get_theme_font(&"font")
		var sz := Vector2(font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x, fs * 1.15) * maxf(l.scale.x, 1.0)
		var gr := l.get_global_rect()
		var c := gr.position + gr.size * 0.5
		out.append(Rect2(c - sz * 0.5, sz))
	return out

## Screen rects of the world popups as last drawn (tests, debugging).
func get_popup_rects() -> Array[Rect2]:
	return _popup_rects

func _update_chain(t: float) -> void:
	if _chain > 0 and t - _chain_at > CHAIN_HOLD:
		_chain = 0
		var tw := _tween()
		tw.tween_property(_chain_label, ^"modulate:a", 0.0, 0.3)
		tw.parallel().tween_property(_chain_sub, ^"modulate:a", 0.0, 0.3)

func _update_arrows(t: float) -> void:
	var cam := get_viewport().get_camera_3d()
	var items: Array = []
	var i := _tells.size() - 1
	while i >= 0:
		var e: Dictionary = _tells[i]
		var fv = e["fighter"]  # untyped: may be a freed instance
		if t > e["until"] or not is_instance_valid(fv) or not (fv is Fighter) or fv.is_dead():
			_tells.remove_at(i)
		elif cam != null:
			var f: Fighter = fv
			var p := f.get_aim_point()
			if not _on_screen(cam, p):
				var a := _edge_arrow(cam, p)
				a["color"] = UIKit.GRAB_COLOR if e["kind"] == &"grab" else UIKit.STRIKE_COLOR
				a["alpha"] = 0.65 + 0.35 * sin(t * 18.0)
				items.append(a)
		i -= 1
	_arrows.items = items
	_arrows.queue_redraw()

func _on_screen(cam: Camera3D, p: Vector3) -> bool:
	if cam.is_position_behind(p):
		return false
	var sp := cam.unproject_position(p)
	return get_viewport().get_visible_rect().grow(-8.0).has_point(sp)

## Screen-edge position and angle of the arrow pointing at world point `p`.
func _edge_arrow(cam: Camera3D, p: Vector3) -> Dictionary:
	var rect := get_viewport().get_visible_rect()
	var center := rect.size * 0.5
	var local := cam.global_transform.affine_inverse() * p
	var dir := Vector2(local.x, -local.y)
	if local.z > 0.0 and dir.length() < 0.001:
		dir = Vector2(0, 1)
	if dir.length() < 0.001:
		dir = Vector2(1, 0)
	dir = dir.normalized()
	var half := center - Vector2(ARROW_MARGIN, ARROW_MARGIN)
	var k := minf(half.x / maxf(absf(dir.x), 0.0001), half.y / maxf(absf(dir.y), 0.0001))
	return {"pos": center + dir * k, "angle": dir.angle()}

# --- Events -------------------------------------------------------------------------
func _is_player(n: Node3D) -> bool:
	return player != null and n == player

func _on_perfect_dodge(defender: Node3D, _attacker: Node3D) -> void:
	if not _is_player(defender):
		return
	flash(Color(0.75, 0.93, 1.0, 0.42), 0.3)
	pop_text("PERFECT", UIKit.PERFECT_COLOR, 0.8)

func _on_teleport_counter(defender: Node3D, _target: Node3D) -> void:
	if _is_player(defender):
		pop_text("COUNTER", UIKit.ACCENT, 0.9)

func _on_wall_broken(wall: Node3D, _position: Vector3, _energy: float, _velocity: Vector3) -> void:
	if wall != null and _suppressed_walls.has(wall.get_instance_id()):
		return  # a staged breach entry, not something the player did
	if not CameraRig.is_headline_break(wall):
		return  # a jab widening an existing strike hole: no banner every hit
	var t := TimeDirector.now()
	if t - _last_chain_at < 0.3 and _last_chain_count >= 2:
		# The chain was reported first: one banner says it all.
		_show_chain_banner(_last_chain_count)
		return
	_wall_break_at = t
	pop_text("WALL BREAK", Color(1.0, 0.85, 0.35), 1.0)

func _show_chain_banner(count: int) -> void:
	var text := "THROUGH %d WALLS" % count
	for i in range(_popup_items.size() - 1, -1, -1):
		if _popup_items[i]["text"] == text:
			_popup_items.remove_at(i)
	_wall_break_at = TimeDirector.now()
	pop_text(text, UIKit.ACCENT, 1.3)

## Walls are the weapon: name the surface and show the damage where it happened.
func _on_impact_damaged(fighter: Node3D, damage: float, _energy: float, surface: StringName, position: Vector3) -> void:
	if damage < 1.0 or not is_instance_valid(fighter):
		return
	var what := "WALL SLAM"
	if surface == &"body":
		what = "BODY SLAM"
	elif surface == &"floor" or position.y < FLOOR_SLAM_HEIGHT:
		what = "FLOOR SLAM"
	var col := Color(1.0, 0.35, 0.3) if _is_player(fighter) else Color(1.0, 0.82, 0.3)
	popup_at(position + Vector3.UP * 0.3, "%s −%d" % [what, roundi(damage)], col,
		30 + mini(int(damage / 10.0), 26), 1.2)

func _on_wall_chain(fighter: Node3D, count: int) -> void:
	if count < 2 or not is_instance_valid(fighter):
		return
	var t := TimeDirector.now()
	_last_chain_at = t
	_last_chain_count = count
	if t - _wall_break_at < CHAIN_MERGE_TIME:
		_show_chain_banner(count)  # WALL BREAK is up: upgrade it instead of stacking text
		return
	var at: Vector3 = (fighter as Fighter).get_center_of_mass() if fighter is Fighter else fighter.global_position
	popup_at(at + Vector3.UP * 0.8, "THROUGH %d WALLS" % count, UIKit.ACCENT, 46 + 6 * mini(count, 4), 1.6)

func _on_armor_absorbed(info: HitInfo) -> void:
	if info == null or not is_instance_valid(info.victim):
		return
	var v := info.victim
	var at: Vector3 = (v as Fighter).get_aim_point() if v is Fighter else v.global_position
	popup_at(at + Vector3.UP * 0.5, "ARMOR", Color(0.7, 0.82, 1.0), 30, 0.8)

func _on_dodge_feedback(defender: Node3D, result: StringName) -> void:
	if not _is_player(defender):
		return
	var text := "EARLY" if result == &"early" else ("LATE" if result == &"late" else String(result).to_upper())
	popup_at(player.get_aim_point() + Vector3.UP * 0.7, text, Color(1.0, 0.92, 0.45), 30, 0.7)

func _on_grab_broken(_grabber: Node3D, victim: Node3D, reversal: bool) -> void:
	if _is_player(victim):
		pop_text("REVERSAL" if reversal else "GRAB BREAK", Color(1.0, 0.55, 0.5), 0.8)

func _on_pursuit(attacker: Node3D, _victim: Node3D) -> void:
	if _is_player(attacker):
		pop_text("PURSUIT", UIKit.FOCUS_COLOR, 0.6)

func _on_air_recovery(f: Node3D) -> void:
	if _is_player(f):
		pop_text("RECOVER", UIKit.FOCUS_COLOR, 0.6)

func _on_hit_landed(info: HitInfo) -> void:
	if info == null or not _is_player(info.victim):
		return
	_hurt.modulate.a = clampf(0.45 + info.damage / 120.0, 0.45, 1.0)
	var tw := _tween()
	tw.tween_property(_hurt, ^"modulate:a", 0.0, 0.35)

func _on_body_bowled(_flyer: Node3D, _victim: Node3D, _energy: float, chain: int) -> void:
	# chain counts bowled bodies in this flight (1 = first victim), so the
	# number of bodies flying is chain + 1: "x2", "x3".
	var count := maxi(chain + 1, 2)
	_chain = maxi(_chain, count) if TimeDirector.now() - _chain_at < CHAIN_HOLD else count
	_chain_at = TimeDirector.now()
	_chain_label.text = "×%d" % _chain
	_chain_sub.modulate.a = 1.0
	_pop(_chain_label, 1.7, CHAIN_HOLD + 1.0)

func _on_attack_tell(attacker: Node3D, kind: StringName, duration: float) -> void:
	var f := attacker as Fighter
	if f == null or _is_player(f):
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null or _on_screen(cam, f.get_aim_point()):
		return
	_tells.append({"fighter": f, "kind": kind, "until": TimeDirector.now() + duration + ARROW_GRACE})

func _on_charge_started(fighter: Node3D, move_id: StringName) -> void:
	if not _is_player(fighter):
		return
	_charging = true
	_charge_level = 0
	_charge_move = move_id
	_charge_t0 = TimeDirector.now()

func _on_charge_level_changed(fighter: Node3D, level: int) -> void:
	if not _is_player(fighter):
		return
	if not _charging:
		_charging = true
		_charge_t0 = TimeDirector.now() - Tuning.CHARGE_LEVELS[clampi(level - 1, 0, 2)]
	_charge_level = level
	_charge.level_pulse = 1.0

func _on_charge_released(fighter: Node3D, _move_id: StringName, level: int) -> void:
	if not _is_player(fighter):
		return
	_charge_level = level
	_charging = false
	_charge_release_at = TimeDirector.now()

func _on_combo_progress(attacker: Node3D, count: int, damage_scale: float) -> void:
	if not _is_player(attacker) or count < 2:
		return
	_combo_count = count
	_combo_at = TimeDirector.now()
	_combo_label.text = "%d HITS" % count
	_combo_sub.text = "DMG %d%%" % roundi(damage_scale * 100.0)
	_combo_sub.add_theme_color_override(&"font_color", UIKit.TEXT if damage_scale >= 0.99 else UIKit.ACCENT)
	_combo_sub.modulate.a = 1.0
	_pop(_combo_label, 1.3, COMBO_HOLD + 1.0)

func _on_combo_ended(attacker: Node3D, _count: int) -> void:
	if not _is_player(attacker):
		return
	_combo_at = minf(_combo_at, TimeDirector.now() - COMBO_HOLD + 0.4)

func get_combo_text() -> String:
	return _combo_label.text if _combo_label.modulate.a > 0.05 else ""

func get_charge_state() -> Dictionary:
	return {"visible": _charge.visible, "level": _charge_level, "charging": _charging}

func _on_wave_started(index: int, total: int) -> void:
	set_wave(index, total)

# --- Debug -----------------------------------------------------------------------------
func _debug_text() -> String:
	var lines := PackedStringArray()
	lines.append("FPS %d   physics %.2f ms   process %.2f ms" % [
		Performance.get_monitor(Performance.TIME_FPS),
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])
	lines.append(TimeDirector.get_debug_text())
	if player != null and is_instance_valid(player):
		var st := player.get_state()
		var names := RagdollController.State.keys()
		lines.append("player %s  hp %.0f  focus %.2f%s" % [names[st] if st >= 0 and st < names.size() else str(st),
			player.hp, player.focus, "  INVULN" if player.is_invulnerable() else ""])
	var holders := PackedStringArray()
	for h in AttackDirector.get_token_holders():
		if is_instance_valid(h):
			holders.append(h.name)
	lines.append("tokens [%s]  camera_busy %s" % [", ".join(holders), AttackDirector.camera_busy])
	lines.append("enemies %d  fighters %d  launched tracked %d" % [
		get_tree().get_nodes_in_group(&"enemies").size(),
		get_tree().get_nodes_in_group(&"fighters").size(), ImpactResolver.tracked.size()])
	lines.append("debris %d" % DebrisManager.count())
	if player != null and is_instance_valid(player) and player.combat != null:
		var dealt = player.combat.get(&"last_dealt")
		var got = player.combat.get(&"last_received")
		lines.append("last dealt %s" % (str(dealt) if dealt != null else "-"))
		lines.append("last taken %s" % (str(got) if got != null else "-"))
	var rig := get_tree().get_first_node_in_group(&"camera_rig") as CameraRig
	if rig:
		lines.append(rig.get_debug_text())
	return "\n".join(lines)

# --- Drawing ---------------------------------------------------------------------------
## HP bar with a trailing "damage taken" bar, and Focus as 3 segments.
class _Bars extends Control:
	const HP_W := 460.0
	const HP_H := 26.0
	const FOCUS_W := 92.0
	const FOCUS_H := 12.0
	const FOCUS_GAP := 8.0
	var hp_w := HP_W
	var pips := false   ## Focus as 3 round pips (opponent) instead of bars
	var focus_active := false
	var hp := 1.0
	var hp_delayed := 1.0
	var focus := 0.0
	var low := false
	var pulse := 0.0

	func _draw() -> void:
		var back := Rect2(Vector2.ZERO, Vector2(hp_w, HP_H))
		draw_rect(back.grow(3.0), Color(0, 0, 0, 0.75))
		draw_rect(back, Color(0.16, 0.05, 0.05, 0.9))
		draw_rect(Rect2(Vector2.ZERO, Vector2(hp_w * hp_delayed, HP_H)), UIKit.HP_LOST)
		var col := UIKit.HP_COLOR
		if low:
			col = col.lerp(Color(1, 0.5, 0.4), 0.35 + 0.35 * sin(pulse * 9.0))
		draw_rect(Rect2(Vector2.ZERO, Vector2(hp_w * hp, HP_H)), col)
		draw_rect(Rect2(Vector2.ZERO, Vector2(hp_w * hp, HP_H * 0.35)), Color(1, 1, 1, 0.12))
		var y := HP_H + 12.0
		if pips:
			for i in 3:
				var c := Vector2(10.0 + i * 26.0, y + 8.0)
				draw_circle(c, 9.0, Color(0, 0, 0, 0.75))
				draw_circle(c, 7.0, Color(0.05, 0.12, 0.16, 0.9))
				var fill := clampf(focus - i, 0.0, 1.0)
				if fill > 0.0:
					draw_circle(c, 7.0 * fill, UIKit.FOCUS_COLOR if fill >= 1.0 else UIKit.FOCUS_COLOR.darkened(0.35))
			return
		for i in 3:
			var x := i * (FOCUS_W + FOCUS_GAP)
			var r := Rect2(Vector2(x, y), Vector2(FOCUS_W, FOCUS_H))
			draw_rect(r.grow(2.0), Color(0, 0, 0, 0.75))
			draw_rect(r, Color(0.05, 0.12, 0.16, 0.9))
			var fill := clampf(focus - i, 0.0, 1.0)
			if fill > 0.0:
				var c := UIKit.FOCUS_COLOR if fill >= 1.0 else UIKit.FOCUS_COLOR.darkened(0.35)
				if focus_active:
					c = c.lerp(Color.WHITE, 0.25 + 0.2 * sin(pulse * 10.0))
				draw_rect(Rect2(r.position, Vector2(FOCUS_W * fill, FOCUS_H)), c)
			if focus_active:
				draw_rect(r.grow(2.0), Color(UIKit.FOCUS_COLOR, 0.9), false, 2.0)
		# Mark where Focus can start (Tuning.FOCUS_MIN_START bars).
		var mx := Tuning.FOCUS_MIN_START * (FOCUS_W + FOCUS_GAP) if Tuning.FOCUS_MIN_START >= 1.0 \
			else Tuning.FOCUS_MIN_START * FOCUS_W
		draw_line(Vector2(mx, y - 4.0), Vector2(mx, y + FOCUS_H + 4.0), Color(1, 1, 1, 0.85), 2.0)

## Power punch charge: 0..1 with marks where it starts to launch and at full.
class _Charge extends Control:
	const W := 320.0
	const H := 16.0
	var level := 0          ## 0..3 reached
	var fill := 0.0         ## 0..1 of the time to level 3
	var released := false
	var move_name := ""
	var pulse := 0.0
	var level_pulse := 0.0

	func _draw() -> void:
		var font := get_theme_default_font()
		var label := "CHARGE %d" % level if level > 0 else "CHARGE"
		if move_name != "":
			label = move_name + "  " + label
		level_pulse = maxf(level_pulse - 0.05, 0.0)
		draw_string(font, Vector2(0, 14), label, HORIZONTAL_ALIGNMENT_CENTER, W, 18 + int(6.0 * level_pulse),
			UIKit.ACCENT if level >= 2 else UIKit.TEXT)
		var r := Rect2(Vector2(0, 26), Vector2(W, H))
		draw_rect(r.grow(3.0), Color(0, 0, 0, 0.75))
		draw_rect(r, Color(0.12, 0.1, 0.08, 0.9))
		var col := UIKit.TEXT.lerp(UIKit.ACCENT, clampf(fill * 1.3, 0.0, 1.0))
		if level >= 3 or released:
			col = col.lerp(Color.WHITE, 0.5 + 0.5 * sin(pulse * 24.0))
		draw_rect(Rect2(r.position, Vector2(W * fill, H)), col)
		# Level marks at Tuning.CHARGE_LEVELS (time held, as a share of level 3).
		for i in 3:
			var x := W * Tuning.CHARGE_LEVELS[i] / Tuning.CHARGE_LEVELS[2]
			var reached := level > i
			draw_line(Vector2(minf(x, W - 1.0), 22), Vector2(minf(x, W - 1.0), 26 + H + 4),
				UIKit.ACCENT if reached else Color(1, 1, 1, 0.7), 3.0 if reached else 2.0)

## Small centre reticle: strikes and grabs aim at the zone under it.
class _Reticle extends Control:
	var focus := false

	func _draw() -> void:
		var col := Color(1, 1, 1, 0.55) if not focus else Color(UIKit.FOCUS_COLOR, 0.95)
		var gap := 6.0 if not focus else 4.0
		var tick := 7.0
		draw_circle(Vector2.ZERO, 2.0, col)
		for d: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
			draw_line(d * gap, d * (gap + tick), Color(0, 0, 0, col.a * 0.6), 4.0)
			draw_line(d * gap, d * (gap + tick), col, 2.0)

## World popups projected to the screen: outlined heavy text, pop-in, drift up, fade.
class _Popups extends Control:
	var items: Array = []

	func _draw() -> void:
		var font := UIKit.heavy_font()
		for it: Dictionary in items:
			var text: String = it["text"]
			var font_size: int = it["size"]
			var col: Color = it["color"]
			var sc: float = it["scale"]
			var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			var pos: Vector2 = it["pos"]
			draw_set_transform(pos, 0.0, Vector2(sc, sc))
			var at := Vector2(-w * 0.5, font_size * 0.35)
			@warning_ignore("integer_division")
			draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, maxi(6, font_size / 6),
				Color(0, 0, 0, 0.85 * col.a))
			draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## Off-screen attack arrows: white = strike (Block), red = grab (Grab).
class _Arrows extends Control:
	var items: Array = []

	func _draw() -> void:
		for a: Dictionary in items:
			var pos: Vector2 = a["pos"]
			var ang: float = a["angle"]
			var col: Color = a["color"]
			col.a = a["alpha"]
			var fwd := Vector2.from_angle(ang)
			var side := fwd.orthogonal()
			var tip := pos + fwd * 22.0
			var pts := PackedVector2Array([tip, pos - fwd * 14.0 + side * 20.0, pos - fwd * 6.0, pos - fwd * 14.0 - side * 20.0])
			var outline := PackedVector2Array([tip + fwd * 4.0, pos - fwd * 17.0 + side * 25.0, pos - fwd * 8.0, pos - fwd * 17.0 - side * 25.0])
			draw_colored_polygon(outline, Color(0, 0, 0, 0.6 * col.a))
			draw_colored_polygon(pts, col)
			draw_circle(pos - fwd * 34.0, 7.0, col)
