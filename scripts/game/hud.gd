class_name HUD
extends CanvasLayer
## In-round overlay: player HP bar (100 scale) and Focus (3 bars with fill),
## wave counter, duel opponent bar, counter-bonus cue, parry / teleport /
## sidestep feedback, off-screen attack arrows (orange strike, blue grab, from
## the wind-up to the first active frame), the sprint target marker, lock-on
## brackets, combo / charge meters, world popups, bowling chain, controls help
## (F1) and the Round 5 debug overlay (F3, mirrors Tuning.debug_overlay).
## The layer sits above ScreenFX's, so Focus mode's tint never dims it.
## Title, pause, debug settings and results panels live in GameMenus. Built
## entirely in code. No health bars over enemies.
## OWNER: agent J (HUD, flow & menus).

const HUD_LAYER := 10           ## at least this; always above ScreenFX's layers
const HP_DELAY := 0.55          ## s before the "damage taken" bar starts to drain
const HP_DRAIN := 0.45          ## share of max HP drained per second by that bar
const CHAIN_HOLD := 2.2         ## s the bowling chain counter stays up
const ARROW_GRACE := 0.3        ## game s an off-screen arrow outlives a wind-up with no active frame (interrupted)
const ARROW_MARGIN := 56.0      ## px from the screen edge
const DEBUG_REFRESH := 0.1      ## s
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
const POP_SIZE := 76            ## px, WALL BREAK / PARRY / TELEPORT pop text
const POP_Y_FRAC := -0.31       ## pop text centre at 19% of the screen height (was 30%)
const CHARGE_FLASH := 0.35      ## s the charge meter stays up after the release
const COMBO_HOLD := 1.6         ## s the combo counter stays after the last hit
const LOCK_MARKER_M := 0.5      ## m half-size of the lock brackets around the target's chest
const LOCK_MARKER_MIN := 26.0   ## px minimum half-size
## Sprint target marker (Prototype 2 at 1.9 s / 16.3 s): small white corner brackets.
const SPRINT_MARKER_M := 0.38   ## m half-size at the target's chest
const SPRINT_MARKER_MIN := 16.0 ## px minimum half-size
const SPRINT_MARKER_IN := 0.12  ## s the brackets take to close in on a new target
## A Block tap with no attack in its window reads LATE when an enemy attack went
## active this recently (real s); EARLY when one is still further than the window away.
const PARRY_LATE_WINDOW := 0.25
const FOCUS_GHOST_TIME := 0.4   ## s a spent Focus bar takes to fade out

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
var _lock_marker: _LockMarker
var _sprint_marker: _LockMarker
var _counter_label: Label
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
## Enemy wind-ups in progress: {fighter, kind, left (game s to the first active
## frame), arrow (started off screen)}. Arrows draw for the off-screen ones.
var _tells: Array[Dictionary] = []
var _last_enemy_active := -100.0            ## real s an enemy attack last went active
var _last_real := 0.0
var _debug_t := 0.0
var _hint_until := 0.0
var _wave_index := 0
var _wave_total := 0
var _enemies_left := 0
var _round_over := false
var _counter_bonus := 0.0                   ## live counter bonus on the player's next hit
var _counter_t0 := -100.0
var _focus_last := -1.0
var _focus_mode_t0 := -100.0
var _sprint_target: Fighter
var _sprint_target_at := -100.0

func _ready() -> void:
	layer = UIKit.layer_above_screen_fx(get_tree(), HUD_LAYER)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_last_real = TimeDirector.now()
	_build()
	_debug_panel.visible = Tuning.debug_overlay
	GameEvents.perfect_dodge.connect(_on_perfect_dodge)
	GameEvents.teleport_counter.connect(_on_teleport_counter)
	GameEvents.wall_broken.connect(_on_wall_broken)
	GameEvents.body_bowled.connect(_on_body_bowled)
	GameEvents.attack_tell.connect(_on_attack_tell)
	GameEvents.attack_active.connect(_on_attack_active)
	GameEvents.grab_broken.connect(_on_grab_broken)
	GameEvents.pursuit.connect(_on_pursuit)
	GameEvents.air_recovery.connect(_on_air_recovery)
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.wave_started.connect(_on_wave_started)
	GameEvents.impact_damaged.connect(_on_impact_damaged)
	GameEvents.wall_chain.connect(_on_wall_chain)
	GameEvents.armor_absorbed.connect(_on_armor_absorbed)
	GameEvents.charge_started.connect(_on_charge_started)
	GameEvents.charge_level_changed.connect(_on_charge_level_changed)
	GameEvents.charge_released.connect(_on_charge_released)
	GameEvents.combo_progress.connect(_on_combo_progress)
	GameEvents.combo_ended.connect(_on_combo_ended)
	# Round 5 defence and Focus.
	GameEvents.parried.connect(_on_parried)
	GameEvents.parry_whiffed.connect(_on_parry_whiffed)
	GameEvents.teleported.connect(_on_teleported)
	GameEvents.sidestepped.connect(_on_sidestepped)
	GameEvents.counter_bonus_changed.connect(_on_counter_bonus_changed)
	GameEvents.focus_started.connect(_on_focus_started)
	_hint_until = TimeDirector.now() + HINT_TIME

# --- Public API ----------------------------------------------------------------
func set_player(f: Fighter) -> void:
	player = f
	if f:
		_hp_shown = f.hp / maxf(f.max_hp, 1.0)
		_hp_delayed = _hp_shown
		_hp_last = f.hp
		_focus_last = f.focus

func set_mode(m: StringName) -> void:
	mode = m
	_refresh_mode_labels()

## total 0 = endless waves (the counter shows the wave number only).
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

## Short pop text ("PARRY", "TELEPORT", "WALL BREAK").
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

## F3: the debug overlay. Mirrors (and saves) Tuning.debug_overlay.
func toggle_debug() -> void:
	set_debug_visible(not _debug_panel.visible)

func set_debug_visible(on: bool) -> void:
	_debug_panel.visible = on
	_debug_t = 0.0
	if Tuning.debug_overlay != on:
		Tuning.debug_overlay = on
		GameMenus.save_debug_settings()

func is_debug_visible() -> bool:
	return _debug_panel.visible

func get_debug_text() -> String:
	return _debug_text()

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

## World-space popup (projected each frame), e.g. "WALL SLAM −27" at the impact.
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
	_arrows.items = []
	_arrows.queue_redraw()
	_sprint_marker.visible = false
	_counter_label.visible = false
	_chain_label.modulate.a = 0.0
	_chain_sub.modulate.a = 0.0

## Off-screen attack arrows drawn this frame: [{pos, angle, color, alpha}].
func get_arrows() -> Array:
	return _arrows.items

## The enemy the sprint marker is on (null = hidden).
func get_sprint_marker_target() -> Fighter:
	return _sprint_target if _sprint_marker.visible else null

func get_sprint_marker_rect() -> Rect2:
	return Rect2(_sprint_marker.center - Vector2.ONE * _sprint_marker.half, Vector2.ONE * _sprint_marker.half * 2.0)

## Live counter bonus shown on the HUD (0 = no cue).
func get_counter_cue() -> float:
	return _counter_bonus if _counter_label.visible else 0.0

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
	_hp_label = UIKit.label("100", 24, Color.WHITE, true, 6)
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

	# (Focus mode's world tint is ScreenFX's, below this layer.)
	# Lock-on marker: corner brackets around the locked target's chest.
	_lock_marker = _LockMarker.new()
	_lock_marker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lock_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_lock_marker)

	# Sprint target marker: small white corner brackets on the enemy a sprint
	# attack would hit (PlayerController.get_sprint_target()).
	_sprint_marker = _LockMarker.new()
	_sprint_marker.color = Color(1, 1, 1, 0.95)
	_sprint_marker.width = 2.5
	_sprint_marker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_sprint_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sprint_marker.visible = false
	_root.add_child(_sprint_marker)

	# Centre reticle: zone aiming is from the screen centre.
	_reticle = _Reticle.new()
	_reticle.set_anchors_preset(Control.PRESET_CENTER)
	_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_reticle)

	# Counter bonus cue under the reticle ("+2.5 COUNTER") while the bonus is live;
	# the reticle ring drains over Tuning.COUNTER_BONUS_TIME.
	_counter_label = UIKit.label("", 26, UIKit.COUNTER_COLOR, true, 6)
	_counter_label.set_anchors_preset(Control.PRESET_CENTER)
	_counter_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_counter_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_counter_label.offset_left = -160
	_counter_label.offset_right = 160
	_counter_label.offset_top = 30
	_counter_label.offset_bottom = 64
	_counter_label.visible = false
	_root.add_child(_counter_label)

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

	# Action prompts (Upgrade 2 paths, while B still has them): "COUNTER!", "PURSUIT  Dash".
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
	_opp_hp_label = UIKit.label("200", 24, Color.WHITE, true, 6)
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
	_debug_label.add_theme_font_override(&"font", _mono_font())
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

static func _mono_font() -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Menlo", "SF Mono", "Consolas", "DejaVu Sans Mono", "monospace"])
	return f

func _refresh_mode_labels() -> void:
	if _mode_label == null:
		return
	if mode == &"waves":
		_mode_label.text = "WAVE %d" % (_wave_index + 1) if _wave_total <= 0 \
			else "WAVE %d/%d" % [_wave_index + 1, _wave_total]
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
	_update_arrows(t, dt)
	_update_sprint_marker(t)
	_update_counter_cue(t)
	if _hint.visible and t > _hint_until:
		_hint.modulate.a = maxf(_hint.modulate.a - dt * 1.5, 0.0)
		if _hint.modulate.a <= 0.0:
			_hint.visible = false
	if _debug_panel.visible != Tuning.debug_overlay:
		_debug_panel.visible = Tuning.debug_overlay  # changed in the pause menu
		_debug_t = 0.0
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
	_update_focus_bars(t)
	var focus_on := TimeDirector.is_focus_active()
	_reticle.visible = not _round_over and not player.is_down()
	_reticle.focus = focus_on
	_update_lock_marker(t)
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

## Focus: 3 bars, full bars bright (each costs a whole one), the partial one
## dim. A spent bar flashes out; Focus mode shows its 2 s draining under the bars.
func _update_focus_bars(t: float) -> void:
	var f := player.focus
	if _focus_last >= 0.0 and f < _focus_last - 0.05:
		_bars.ghost_from = f
		_bars.ghost_to = _focus_last
		_bars.ghost_t0 = t
	elif _focus_last >= 0.0 and floorf(f + 1e-4) > floorf(_focus_last + 1e-4):
		_bars.filled_bar = int(floorf(f + 1e-4)) - 1
		_bars.filled_t0 = t
	_focus_last = f
	_bars.focus = f
	_bars.now = t
	var focus_on := TimeDirector.is_focus_active()
	if focus_on and not _bars.focus_active and t - _focus_mode_t0 > 0.1:
		_focus_mode_t0 = t  # Focus mode began without a focus_started from the player
	_bars.focus_active = focus_on
	_bars.mode_left =clampf(1.0 - (t - _focus_mode_t0) / Tuning.FOCUS_MODE_TIME, 0.0, 1.0) if focus_on else -1.0
	_focus_label.text = "FOCUS MODE" if focus_on else "FOCUS"

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

## Corner brackets on the locked target (sized to ~0.5 m at its distance, at
## least LOCK_MARKER_MIN px so it reads at 7 m and at any resolution).
func _update_lock_marker(t: float) -> void:
	var rig := get_tree().get_first_node_in_group(&"camera_rig") as CameraRig
	var lock: Fighter = rig.get_lock_target() if rig != null else null
	_reticle.locked = lock != null
	var cam := get_viewport().get_camera_3d()
	if lock == null or cam == null or _round_over:
		_lock_marker.visible = false
		return
	var chest := lock.get_aim_point()
	if cam.is_position_behind(chest):
		_lock_marker.visible = false
		return
	var c := cam.unproject_position(chest)
	var edge := cam.unproject_position(chest + cam.global_basis.x * LOCK_MARKER_M)
	_lock_marker.visible = true
	_lock_marker.center = c
	_lock_marker.half = maxf(c.distance_to(edge), LOCK_MARKER_MIN)
	_lock_marker.pulse = t
	_lock_marker.queue_redraw()

func is_lock_marker_visible() -> bool:
	return _lock_marker.visible

func _update_chain(t: float) -> void:
	if _chain > 0 and t - _chain_at > CHAIN_HOLD:
		_chain = 0
		var tw := _tween()
		tw.tween_property(_chain_label, ^"modulate:a", 0.0, 0.3)
		tw.parallel().tween_property(_chain_sub, ^"modulate:a", 0.0, 0.3)

## Off-screen attack arrows (Feel Reference: Off-screen attackers): from a
## wind-up that started off screen until its first active frame (attack_active),
## orange for strikes, blue for grabs. The wind-up's own clock is game time
## (enemy frame data slows in Focus mode), so the fallback expiry is too.
func _update_arrows(t: float, dt: float) -> void:
	var game_dt := 0.0 if get_tree().paused else dt * Engine.time_scale
	var cam := get_viewport().get_camera_3d()
	var items: Array = []
	var i := _tells.size() - 1
	while i >= 0:
		var e: Dictionary = _tells[i]
		e["left"] = float(e["left"]) - game_dt
		var fv = e["fighter"]  # untyped: may be a freed instance
		var ended := false
		if is_instance_valid(fv) and fv is Fighter and (fv as Fighter).combat != null:
			# Wind-up over once the attack we saw stops (parried, interrupted, cancelled).
			if (fv as Fighter).combat.is_attacking():
				e["seen_attacking"] = true
			elif e.get("seen_attacking", false):
				ended = true
		if ended or float(e["left"]) < -ARROW_GRACE or not is_instance_valid(fv) or not (fv is Fighter) or fv.is_dead() or fv.is_down():
			_tells.remove_at(i)
		elif e["arrow"] and cam != null and not _round_over:
			var p: Vector3 = (fv as Fighter).get_aim_point()
			if not _is_on_screen(cam, p):
				var a := _edge_arrow(cam, p)
				a["color"] = UIKit.TELL_GRAB if e["kind"] == &"grab" else UIKit.TELL_STRIKE
				a["alpha"] = 0.75 + 0.25 * sin(t * 18.0)
				a["fighter"] = fv
				items.append(a)
		i -= 1
	_arrows.items = items
	_arrows.queue_redraw()

## The camera's own on-screen test when there is a rig, else the viewport rect.
func _is_on_screen(cam: Camera3D, p: Vector3) -> bool:
	var rig := get_tree().get_first_node_in_group(&"camera_rig") as CameraRig
	if rig != null and rig.get_camera() == cam:
		return rig.is_on_screen(p)
	return _on_screen(cam, p)

## F2: white corner brackets on the enemy a sprint attack would hit, while sprinting.
func _update_sprint_marker(t: float) -> void:
	var target: Fighter = null
	if player != null and is_instance_valid(player) and not _round_over and not player.is_down() \
			and player.brain != null and player.brain.has_method(&"get_sprint_target"):
		target = player.brain.call(&"get_sprint_target") as Fighter
	var cam := get_viewport().get_camera_3d()
	if target == null or not is_instance_valid(target) or cam == null:
		_sprint_target = null
		_sprint_marker.visible = false
		return
	var chest := target.get_aim_point()
	if cam.is_position_behind(chest):
		_sprint_marker.visible = false
		return
	if target != _sprint_target:
		_sprint_target = target
		_sprint_target_at = t
	var c := cam.unproject_position(chest)
	var edge := cam.unproject_position(chest + cam.global_basis.x * SPRINT_MARKER_M)
	var k := clampf((t - _sprint_target_at) / SPRINT_MARKER_IN, 0.0, 1.0)
	_sprint_marker.visible = true
	_sprint_marker.center = c
	_sprint_marker.half = maxf(c.distance_to(edge), SPRINT_MARKER_MIN) * lerpf(1.6, 1.0, ease(k, 0.4))
	_sprint_marker.alpha = k
	_sprint_marker.pulse = 0.0
	_sprint_marker.queue_redraw()

## Counter bonus cue: "+2.5 COUNTER" under the reticle, the ring drains over the
## bonus's real-time window; gone when it is used or runs out.
func _update_counter_cue(t: float) -> void:
	var left := 1.0 - (t - _counter_t0) / Tuning.COUNTER_BONUS_TIME
	var live := _counter_bonus > 0.0 and left > 0.0 and not _round_over
	_counter_label.visible = live
	_reticle.counter_left = left if live else -1.0
	if live:
		_counter_label.text = "+%s COUNTER" % String.num(_counter_bonus, 1)
		_counter_label.modulate.a = 0.8 + 0.2 * sin(t * 16.0)

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

## Every enemy wind-up is tracked (parry EARLY / LATE reads them); one that
## starts off screen gets an edge arrow until its first active frame.
func _on_attack_tell(attacker: Node3D, kind: StringName, duration: float) -> void:
	var f := attacker as Fighter
	if f == null or _is_player(f) or _round_over:
		return
	for i in range(_tells.size() - 1, -1, -1):
		if _tells[i]["fighter"] == f:
			_tells.remove_at(i)
	var cam := get_viewport().get_camera_3d()
	var off := cam != null and not _is_on_screen(cam, f.get_aim_point())
	_tells.append({"fighter": f, "kind": kind, "left": duration, "arrow": off})

func _on_attack_active(attacker: Node3D, _move_id: StringName) -> void:
	if attacker == null or _is_player(attacker):
		return
	_last_enemy_active = TimeDirector.now()
	for i in range(_tells.size() - 1, -1, -1):
		if _tells[i]["fighter"] == attacker:
			_tells.remove_at(i)

# --- Round 5 defence feedback ------------------------------------------------------------
func _on_parried(defender: Node3D, attacker: Node3D) -> void:
	if _is_player(defender):
		pop_text("PARRY", Color.WHITE, 0.7)
	# The parry cancels the attack before its active frame: its arrow goes now.
	for i in range(_tells.size() - 1, -1, -1):
		if _tells[i]["fighter"] == attacker:
			_tells.remove_at(i)

## A Block tap with nothing in its window: say whether it came early or late
## against the nearest enemy wind-up (nothing when no attack was coming).
func _on_parry_whiffed(defender: Node3D) -> void:
	if not _is_player(defender) or player == null:
		return
	var text := parry_whiff_text()
	if text != "":
		popup_at(player.get_aim_point() + Vector3.UP * 0.7, text, Color(1.0, 0.92, 0.45), 30, 0.7)

## "EARLY" when an enemy wind-up is still more than the parry window from its
## first active frame, "LATE" when one went active within PARRY_LATE_WINDOW, else "".
func parry_whiff_text() -> String:
	var soonest := INF
	for e in _tells:
		var fv = e["fighter"]
		if is_instance_valid(fv):
			soonest = minf(soonest, float(e["left"]) / maxf(Engine.time_scale, 0.05))  # real s to active
	if soonest < INF and soonest > Tuning.PARRY_WINDOW:
		return "EARLY"
	if TimeDirector.now() - _last_enemy_active < PARRY_LATE_WINDOW:
		return "LATE"
	return ""

func _on_teleported(fighter: Node3D, _from: Vector3, _to: Vector3, kind: StringName) -> void:
	if not _is_player(fighter):
		return
	if kind == &"pursuit":
		pop_text("PURSUIT", UIKit.FOCUS_COLOR, 0.6)
	else:
		pop_text("TELEPORT", UIKit.FOCUS_COLOR, 0.8)

func _on_sidestepped(fighter: Node3D, _direction: Vector3) -> void:
	if not _is_player(fighter):
		return
	var short := player.focus + 1e-4 < Tuning.TELEPORT_COST
	popup_at(player.get_aim_point() + Vector3.UP * 0.7, "SIDESTEP" if not short else "SIDESTEP  ·  NO FOCUS",
		Color(0.85, 0.9, 1.0), 28, 0.7)

func _on_counter_bonus_changed(fighter: Node3D, bonus: float) -> void:
	if not _is_player(fighter):
		return
	_counter_bonus = maxf(bonus, 0.0)
	_counter_t0 = TimeDirector.now()

func _on_focus_started(fighter: Node3D) -> void:
	if _is_player(fighter):
		_focus_mode_t0 = TimeDirector.now()

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
## The parts of a hit's power score P for the overlay: base, charge_mult, their
## product, speed / counter / finisher bonuses, P and the tier. HitInfo.power_base
## may hold the raw base or base x charge: whichever adds up to P is used.
static func power_breakdown(info: HitInfo) -> Dictionary:
	var cm := Power.charge_mult(info.charge_level)
	var rest := info.speed_bonus + info.counter_bonus + info.finisher_bonus
	var base := info.power_base
	if absf(info.power_base + rest - info.power) < 0.02 and absf(info.power_base * cm + rest - info.power) >= 0.02:
		base = info.power_base / cm  # power_base already holds base x charge
	return {"base": base, "charge_mult": cm, "base_part": base * cm, "speed": info.speed_bonus,
		"counter": info.counter_bonus, "finisher": info.finisher_bonus, "power": info.power,
		"tier": HitInfo.tier_name(info.tier)}

static func describe_hit(info: HitInfo) -> String:
	if info == null:
		return "-"
	var b := power_breakdown(info)
	var flags := PackedStringArray()
	if info.sprint:
		flags.append("sprint")
	if info.ground_strike:
		flags.append("ground")
	if info.pursuit:
		flags.append("pursuit")
	if info.charge_level > 0:
		flags.append("L%d" % info.charge_level)
	return "P %5.2f %-11s %s %s  dmg %.1f\n  = base %.2f x charge %.2f (%.2f) + speed %.2f + counter %.2f + finisher %.2f" % [
		b["power"], String(b["tier"]).to_upper(), String(info.move_id), " ".join(flags), info.damage,
		b["base"], b["charge_mult"], b["base_part"], b["speed"], b["counter"], b["finisher"]]

## Round 6 destruction at a glance: debris against its cap, clutter and props
## broken, wall holes, collapses, floor damage by level and the decal budgets.
static func world_debug_line() -> String:
	var wc := {}
	if DebrisManager.has_method(&"get_world_counts"):
		wc = DebrisManager.call(&"get_world_counts")
	var fl := {}
	if WorldDamage.has_method(&"get_floor_counts"):
		fl = WorldDamage.call(&"get_floor_counts")
	var dc := {}
	if BloodFX.has_method(&"get_decal_counts"):
		dc = BloodFX.call(&"get_decal_counts")
	return "WORLD      debris %d/%d  smashed %d  holes %d  collapses %d  floor %d/%d/%d (+%d tiles)  marks %d/%d  blood %d/%d" % [
		int(wc.get("debris", DebrisManager.count())), Tuning.DEBRIS_MAX, int(wc.get("furniture_broken", 0)),
		int(wc.get("wall_holes", 0)), int(wc.get("collapses", 0)), int(fl.get("cracks", 0)), int(fl.get("craters", 0)),
		int(fl.get("rubble", 0)), int(fl.get("tiles", 0)), int(dc.get("marks", 0)), Tuning.FLOOR_DECAL_MAX,
		int(dc.get("blood", BloodFX.decal_count())), Tuning.BLOOD_DECAL_MAX]

func _debug_text() -> String:
	var lines := PackedStringArray()
	if player != null and is_instance_valid(player):
		var c := player.combat
		var dealt: HitInfo = c.last_dealt if c != null else null
		var got: HitInfo = c.last_received if c != null else null
		lines.append("LAST HIT   " + describe_hit(dealt))
		lines.append("TAKEN      " + describe_hit(got))
		var tr := player.traversal
		var speed := tr.get_speed() if tr != null else 0.0
		if speed <= 0.0:
			speed = Vector2(player.velocity.x, player.velocity.z).length()
		var charge := tr.sprint_charge if tr != null else 0.0
		var cap := tr.get_speed_cap() if tr != null else Tuning.debug_speed_cap
		lines.append("SPEED      %5.2f m/s  sprint_charge %.2f  cap %.0f%s  ram %d" % [speed, charge, cap,
			"  SPRINT" if tr != null and tr.is_sprinting() else "", Tuning.debug_ram_level])
		lines.append("FOCUS      %.2f / %.0f bars%s   HP %.0f / %.0f   counter +%.1f" % [player.focus, Tuning.FOCUS_MAX,
			"  (MODE)" if TimeDirector.is_focus_active() else "", player.hp, player.max_hp, _counter_bonus if _counter_label.visible else 0.0])
		var st := player.get_state()
		var names := RagdollController.State.keys()
		lines.append("state %s%s" % [names[st] if st >= 0 and st < names.size() else str(st),
			"  INVULN" if player.is_invulnerable() else ""])
	lines.append("FPS %d   physics %.2f ms   process %.2f ms" % [
		Performance.get_monitor(Performance.TIME_FPS),
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])
	lines.append(TimeDirector.get_debug_text())
	var holders := PackedStringArray()
	for h in AttackDirector.get_token_holders():
		if is_instance_valid(h):
			holders.append(h.name)
	lines.append("tokens [%s]  wave %d" % [", ".join(holders), AttackDirector.wave_index])
	lines.append("enemies %d  fighters %d" % [get_tree().get_nodes_in_group(&"enemies").size(),
		get_tree().get_nodes_in_group(&"fighters").size()])
	lines.append(world_debug_line())
	var rig := get_tree().get_first_node_in_group(&"camera_rig") as CameraRig
	if rig:
		lines.append(rig.get_debug_text())
	return "\n".join(lines)

# --- Drawing ---------------------------------------------------------------------------
## HP bar with a trailing "damage taken" bar, and Focus as 3 bars with fill.
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
	var now := 0.0
	## Focus mode time left 0..1 (-1 = not in Focus mode).
	var mode_left := -1.0
	## A spent stretch of Focus (bars) fading out from ghost_t0.
	var ghost_from := 0.0
	var ghost_to := 0.0
	var ghost_t0 := -100.0
	## The bar that just filled up, flashing from filled_t0.
	var filled_bar := -1
	var filled_t0 := -100.0

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
		# Quarter ticks: the 100-point scale reads as 25-HP steps.
		for q in range(1, 4):
			var x := hp_w * q * 0.25
			draw_line(Vector2(x, HP_H * 0.6), Vector2(x, HP_H), Color(0, 0, 0, 0.45), 2.0)
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
		var ghost_k := 1.0 - (now - ghost_t0) / FOCUS_GHOST_TIME
		var filled_k := 1.0 - (now - filled_t0) / 0.35
		for i in 3:
			var x := i * (FOCUS_W + FOCUS_GAP)
			var r := Rect2(Vector2(x, y), Vector2(FOCUS_W, FOCUS_H))
			draw_rect(r.grow(2.0), Color(0, 0, 0, 0.75))
			draw_rect(r, Color(0.05, 0.12, 0.16, 0.9))
			# Spent Focus flashes out (Focus mode, a teleport or a pursuit takes a whole bar).
			if ghost_k > 0.0:
				var g0 := clampf(ghost_from - i, 0.0, 1.0)
				var g1 := clampf(ghost_to - i, 0.0, 1.0)
				if g1 > g0:
					draw_rect(Rect2(r.position + Vector2(FOCUS_W * g0, 0.0), Vector2(FOCUS_W * (g1 - g0), FOCUS_H)),
						Color(1, 1, 1, 0.9 * ghost_k))
			var fill := clampf(focus - i, 0.0, 1.0)
			if fill > 0.0:
				# A full bar is spendable: bright. The partial one is dim.
				var c := UIKit.FOCUS_COLOR if fill >= 1.0 - 1e-4 else UIKit.FOCUS_COLOR.darkened(0.45)
				if focus_active:
					c = c.lerp(Color.WHITE, 0.25 + 0.2 * sin(pulse * 10.0))
				if i == filled_bar and filled_k > 0.0:
					c = c.lerp(Color.WHITE, filled_k)
				draw_rect(Rect2(r.position, Vector2(FOCUS_W * fill, FOCUS_H)), c)
			if focus_active:
				draw_rect(r.grow(2.0), Color(UIKit.FOCUS_COLOR, 0.9), false, 2.0)
		# Focus mode: its real-time 2 s draining under the bars.
		if mode_left >= 0.0:
			var w := 3.0 * FOCUS_W + 2.0 * FOCUS_GAP
			var r := Rect2(Vector2(0.0, y + FOCUS_H + 6.0), Vector2(w, 4.0))
			draw_rect(r.grow(1.0), Color(0, 0, 0, 0.7))
			draw_rect(Rect2(r.position, Vector2(w * mode_left, r.size.y)), Color(0.85, 0.97, 1.0, 0.95))

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

## Corner brackets around a target: lock-on (accent) and the sprint target (white).
class _LockMarker extends Control:
	var center := Vector2.ZERO
	var half := 30.0
	var pulse := 0.0
	var color := UIKit.ACCENT
	var width := 4.0
	var alpha := 1.0

	func _draw() -> void:
		var h := half * (1.0 + 0.04 * sin(pulse * 6.0))
		var arm := maxf(h * 0.4, 8.0)
		var col := Color(color, color.a * alpha)
		for sx: float in [-1.0, 1.0]:
			for sy: float in [-1.0, 1.0]:
				var corner := center + Vector2(sx * h, sy * h)
				var pts := PackedVector2Array([corner + Vector2(0, -sy * arm), corner, corner + Vector2(-sx * arm, 0)])
				draw_polyline(pts, Color(0, 0, 0, 0.7 * alpha), width + 3.0)
				draw_polyline(pts, col, width)

## Small centre reticle: strikes and grabs aim at the zone under it. A gold
## ring drains around it while a counter bonus is live.
class _Reticle extends Control:
	var focus := false
	var locked := false
	var counter_left := -1.0   ## 0..1 of the counter bonus window left; < 0 = none

	func _draw() -> void:
		var col := Color(1, 1, 1, 0.55) if not focus else Color(UIKit.FOCUS_COLOR, 0.95)
		var gap := 6.0 if not focus else 4.0
		var tick := 7.0
		if locked:
			col = Color(UIKit.ACCENT, 0.95)
			draw_arc(Vector2.ZERO, 13.0, 0.0, TAU, 32, Color(0, 0, 0, 0.6), 4.0)
			draw_arc(Vector2.ZERO, 13.0, 0.0, TAU, 32, col, 2.0)
		if counter_left > 0.0:
			var a0 := -PI * 0.5
			draw_arc(Vector2.ZERO, 21.0, 0.0, TAU, 40, Color(0, 0, 0, 0.55), 6.0)
			draw_arc(Vector2.ZERO, 21.0, a0, a0 + TAU * counter_left, 40, UIKit.COUNTER_COLOR, 3.5)
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

## Off-screen attack arrows: orange = strike (parry it), blue = grab (break it).
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
