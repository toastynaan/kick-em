class_name HUD
extends CanvasLayer
## In-round overlay (Round 7: HUD): player HP bar (100 scale), wave counter,
## duel opponent bar, the combo counter (GameEvents.chain_hit / chain_ended),
## counter prompts over every enemy whose counter window is open on the player
## (GameEvents.counter_window: orange = Counter, blue = dodge only), the
## pursuit cues of the god path ("DASH: PURSUE" near a body the player just
## launched, then "ATTACK: LAUNCH  /  BACK + ATTACK: SPIKE" during the pursuit
## hang), TELEPORT / SIDESTEP feedback, off-screen attack arrows, world popups,
## bowling chain, controls help (F1) and the debug
## overlay (F3, mirrors Tuning.debug_overlay: move, string, chain, glide, the
## combat target's reaction state; Round 8: the charge c and steps, the
## target's pressure, broken state and level, the air hits).
## Round 8 (docs/Round 8 — Charge and Pressure.md, The meter and Pressure):
## - The charge meter, bottom centre where Round 5's was: shown while
##   CombatController.is_charging(), it fills with get_charge() and is white
##   under the first of get_charge_steps(), orange past it and red past the last
##   (no labels; thin ticks mark the steps). It pops as c crosses a step,
##   flashes on charge_full and pulses while full, stays up CHARGE_HOLD after
##   charge_released, and drains with a shake on charge_cancelled. The events
##   and the getters are both read, so a missed event never strands it.
## - Pressure bars from get_pressure() / get_pressure_max(): under the
##   Duelist's top health bar, and in Waves a compact health + pressure pair
##   over each enemy that is engaged (the player's target, close, under
##   pressure) or damaged. While is_broken() the bar is full and flashes, then
##   it empties. A break pops "BROKEN" over the enemy.
## The layer sits above ScreenFX's, so screen effects never dim it.
## Title, pause and results panels live in GameMenus. Built entirely in code.
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
const POP_SIZE := 76            ## px, WALL BREAK / COUNTER pop text
const POP_Y_FRAC := -0.31       ## pop text centre at 19% of the screen height
## Combo counter (Round 7: HUD): left side, a big number that pops on each hit.
const COMBO_MIN := 2            ## chain hits before the counter shows (one hit is not a combo)
const COMBO_SIZE := 128         ## px, the number
const COMBO_POP := 1.45         ## scale of the number on the hit frame, settling to 1
const COMBO_POP_TIME := 0.16    ## s for the pop to settle
const COMBO_END_HOLD := 0.45    ## s the final count stays after chain_ended
const COMBO_FADE := 0.4         ## s fade-out after that
const COMBO_STALE := 3.0        ## s without a chain_hit: fade even if chain_ended never came
const COMBO_HOT := 10           ## the number reaches the accent colour at this many hits
## Counter prompts: a key badge over each attacker whose window is open on the player.
const PROMPT_HEAD_UP := 0.15    ## m above the top of the attacker's head (the pointer tip)
const PROMPT_H := 44.0          ## px badge height (a circle for one-letter keys, a pill for longer)
const PROMPT_GAP := 12.0        ## px between the pointer tip and the badge
const PROMPT_IN := 0.12         ## s the badge takes to pop in
const PROMPT_MAX_AGE := 3.0     ## s: no window lasts this long; drops a prompt whose close was missed
const PROMPT_MARGIN := 16.0     ## px the badge stays inside the screen
const PROMPT_REOPEN_GAP := 0.25 ## s after a close event in which Defence's poll may not reopen a prompt
## Pursuit cues (Round 7 amendment: God path).
const PURSUE_CAPTION := "DASH: PURSUE"
const HANG_TEXT := "ATTACK: LAUNCH  /  BACK + ATTACK: SPIKE"
const PURSUE_ABOVE := 0.7       ## m above the flying body's centre of mass
const LAUNCH_HITSTOP_FALLBACK := 0.11 ## real s for a launch HitInfo with no hitstop (Defence's value)
const HANG_GRACE := 0.35        ## real s after Tuning.PURSUIT_HANG the hang cue may stay (Defence's strike grace)
## Round 8 charge meter (bottom centre, Round 5's place and look).
const CHARGE_HOLD := 0.35       ## real s the meter stays up after the release (fading over the second half)
const CHARGE_CANCEL_TIME := 0.35 ## real s a cancelled charge takes to drain and shake out
const CHARGE_SHAKE := 10.0      ## px peak sideways shake of a cancel
const CHARGE_STEP_POP := 0.14   ## real s the bar pops when c crosses one of the move's steps
const CHARGE_FULL_POP := 0.2    ## real s of the white flash when the charge reaches full
const CHARGE_PULSE := 24.0      ## rad/s of the white pulse while full
const CHARGE_STEP_EPS := 0.001  ## c this close under a step counts as past it
## Round 8 pressure bars.
const PRESSURE_DRAIN := 2.5     ## share of the bar per real s the shown pressure falls (it rises at once)
const PRESSURE_PULSE := 22.0    ## rad/s of the broken flash
const OPP_PRESSURE_H := 10.0    ## px, the Duelist's pressure bar under its HP bar
const ENEMY_BAR_W := 78.0       ## px, Waves: the bar pair over an enemy
const ENEMY_BAR_HP_H := 7.0
const ENEMY_BAR_P_H := 5.0
const ENEMY_BAR_GAP := 2.0      ## px between the two bars
const ENEMY_BAR_ABOVE := 0.3    ## m above a standing enemy's head
const ENEMY_BAR_ABOVE_BODY := 0.9 ## m above a ragdolling body's centre of mass
const ENEMY_BAR_ENGAGE := 6.0   ## m: an enemy this close to the player is engaged
const ENEMY_BAR_FADE := 0.2     ## real s to fade in or out
const ENEMY_BAR_MAX_DIST := 30.0 ## m from the camera: farther bars are not drawn

var player: Fighter
var mode: StringName = &"duel"

var _root: Control
var _bars: _Bars
var _hp_label: Label
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
var _prompts_draw: _Prompts
var _help: PanelContainer
var _debug_panel: PanelContainer
var _debug_label: Label
var _hint: Label
var _combo_box: VBoxContainer
var _combo_num: Label
var _combo_hits: Label
var _combo_move_label: Label
var _combo_count := 0                       ## hits in the player's live (or just ended) chain
var _combo_hit_at := -100.0                 ## real s of the last chain_hit
var _combo_end_at := -1.0                   ## real s the chain ended (-1 = live)
var _combo_move: StringName = &""
var _combo_polled := false                  ## get_chain_count() reported this chain (fallback path)
## Open counter windows on the player: attacker instance id -> {fighter,
## counterable, t0, seen_open}. Drawn each frame by _prompts_draw.
var _prompts := {}
var _prompt_items: Array = []               ## last drawn prompts (tests)
var _prompt_closed_at := {}                 ## attacker instance id -> real s its close event came
## Pursuit window after the player's launch (local mirror of Defence's rule
## until Defence answers get_pursuit_window_target()). Untyped: may be freed.
var _pursue_victim = null
var _pursue_until := -INF                   ## real s the window closes
var _pursue_t0 := -INF
var _hang_victim = null                     ## pursuit event's body (fallback for get_pursuit_target)
var _hang_until := -INF
var _cue_t0 := -INF                         ## real s the current cue appeared
var _cue_kind: StringName = &""
var _cue: Dictionary = {}                   ## last drawn pursuit cue (tests)
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
var _opp_pressure: _PressureBar
var _opp_p_shown := 0.0
## Round 8 charge meter: &"" hidden, &"charging", &"released" (held up for
## CHARGE_HOLD), &"cancelled" (draining for CHARGE_CANCEL_TIME).
var _charge: _Charge
var _charge_state: StringName = &""
var _charge_c := 0.0
var _charge_steps: Array[float] = []
var _charge_move: StringName = &""
var _charge_t0 := -INF                      ## real s the current state began
var _charge_full := false
var _charge_full_at := -INF
var _charge_polled := false                 ## is_charging() reported this charge (else events only)
var _charge_passed := 0                     ## steps passed (pops on each new one)
var _charge_step_at := -INF
var _charge_info := {}                      ## the meter as last drawn (tests)
## Round 8 enemy bars (Waves): instance id -> {fighter, shown, alpha}.
var _enemy_bar_state := {}
var _enemy_bars_draw: _EnemyBars
var _enemy_bar_items: Array = []            ## last drawn (tests)

var _hp_shown := 1.0
var _hp_delayed := 1.0
var _hp_last := -1.0
var _hp_hit_at := -100.0
var _chain := 0
var _chain_at := -100.0
## Enemy wind-ups in progress: {fighter, kind, left (game s to the first active
## frame), arrow (started off screen)}. Arrows draw for the off-screen ones.
var _tells: Array[Dictionary] = []
var _last_real := 0.0
var _debug_t := 0.0
var _hint_until := 0.0
var _wave_index := 0
var _wave_total := 0
var _enemies_left := 0
var _round_over := false

func _ready() -> void:
	layer = UIKit.layer_above_screen_fx(get_tree(), HUD_LAYER)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_last_real = TimeDirector.now()
	_build()
	_debug_panel.visible = Tuning.debug_overlay
	GameEvents.wall_broken.connect(_on_wall_broken)
	GameEvents.body_bowled.connect(_on_body_bowled)
	GameEvents.attack_tell.connect(_on_attack_tell)
	GameEvents.attack_active.connect(_on_attack_active)
	GameEvents.grab_broken.connect(_on_grab_broken)
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.wave_started.connect(_on_wave_started)
	GameEvents.impact_damaged.connect(_on_impact_damaged)
	GameEvents.wall_chain.connect(_on_wall_chain)
	GameEvents.armor_absorbed.connect(_on_armor_absorbed)
	# Round 7: combo counter and counter prompts.
	GameEvents.chain_hit.connect(_on_chain_hit)
	GameEvents.chain_ended.connect(_on_chain_ended)
	GameEvents.counter_window.connect(_on_counter_window)
	GameEvents.countered.connect(_on_countered)
	GameEvents.counter_whiffed.connect(_on_counter_whiffed)
	# God path: teleport and pursuit feedback.
	GameEvents.pursuit.connect(_on_pursuit)
	GameEvents.teleported.connect(_on_teleported)
	GameEvents.sidestepped.connect(_on_sidestepped)
	# Round 8: the charge meter and pressure.
	GameEvents.charge_started.connect(_on_charge_started)
	GameEvents.charge_level_changed.connect(_on_charge_level_changed)
	GameEvents.charge_full.connect(_on_charge_full)
	GameEvents.charge_released.connect(_on_charge_released)
	GameEvents.charge_cancelled.connect(_on_charge_cancelled)
	GameEvents.pressure_broken.connect(_on_pressure_broken)
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

## Short pop text ("COUNTER", "WALL BREAK").
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

## Duel mode: show the opponent's HP bar (waves keep no enemy bars).
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
	_prompts.clear()
	_prompt_items = []
	_cue = {}
	_pursue_victim = null
	_hang_victim = null
	_prompts_draw.items = []
	_prompts_draw.queue_redraw()
	_charge_state = &""
	_charge.visible = false
	_enemy_bar_state.clear()
	_enemy_bar_items = []
	_enemy_bars_draw.items = []
	_enemy_bars_draw.queue_redraw()
	_combo_count = 0
	_combo_box.modulate.a = 0.0
	_chain_label.modulate.a = 0.0
	_chain_sub.modulate.a = 0.0

## Off-screen attack arrows drawn this frame: [{pos, angle, color, alpha}].
func get_arrows() -> Array:
	return _arrows.items

## Combo counter: the count shown (0 = hidden), its text, opacity, the number's
## scale (> 1 right after a hit) and the move name under it.
func get_combo_count() -> int:
	return _combo_count if _combo_box.modulate.a > 0.05 else 0

func get_combo_text() -> String:
	return _combo_num.text if _combo_box.modulate.a > 0.05 else ""

func get_combo_alpha() -> float:
	return _combo_box.modulate.a

func get_combo_scale() -> float:
	return _combo_num.scale.x

func get_combo_move() -> String:
	return _combo_move_label.text if _combo_box.modulate.a > 0.05 else ""

## Counter prompts drawn this frame: [{fighter, counterable, color, key,
## caption, center (badge, screen px), tip (pointer), on_screen, alpha}].
func get_counter_prompts() -> Array:
	return _prompt_items

## The pursuit cue drawn this frame ({} = none): {kind (&"pursue" | &"hang"),
## fighter (the flying body), text ("DASH: PURSUE" or the hang's choice), key,
## center, on_screen}.
func get_pursuit_cue() -> Dictionary:
	return _cue

## The charge meter as drawn this frame: {visible, state (&"charging",
## &"released", &"cancelled" or &""), fill, c, steps, passed, tier (0 white,
## 1 orange, 2 red), color (the tier's), draw_color (with the full flash),
## full, flashing, shake (px), alpha, scale, move}.
func get_charge_meter() -> Dictionary:
	return _charge_info

## Waves: the health + pressure pairs drawn this frame over enemies:
## [{fighter, pos (screen px), hp, pressure (shown fraction), broken, alpha}].
func get_enemy_bars() -> Array:
	return _enemy_bar_items

## Duel: the Duelist's pressure bar under its health bar {visible, fill, broken}.
func get_opponent_pressure() -> Dictionary:
	return {"visible": _opp_root.visible, "fill": _opp_pressure.fill, "broken": _opp_pressure.broken}

## Attackers with an open counter window on the player (drawn or not).
func get_prompt_attackers() -> Array:
	var out: Array = []
	for id in _prompts:
		out.append(_prompts[id]["fighter"])
	return out

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
	_bars.size = Vector2(_Bars.HP_W, _Bars.HP_H)
	_bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_bars)
	_hp_label = UIKit.label("100", 24, Color.WHITE, true, 6)
	_hp_label.position = Vector2(36 + _Bars.HP_W + 14, 44)
	_root.add_child(_hp_label)

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

	# Combo counter, left side: a big "7" with "HITS" beside it, the move under.
	_combo_box = VBoxContainer.new()
	_combo_box.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_combo_box.grow_vertical = Control.GROW_DIRECTION_BOTH
	_combo_box.offset_left = 48.0
	_combo_box.offset_right = 420.0
	_combo_box.offset_top = -110.0
	_combo_box.offset_bottom = 70.0
	_combo_box.add_theme_constant_override(&"separation", -18)
	_combo_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_combo_box.modulate.a = 0.0
	_root.add_child(_combo_box)
	var combo_row := HBoxContainer.new()
	combo_row.add_theme_constant_override(&"separation", 10)
	combo_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	combo_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_combo_box.add_child(combo_row)
	_combo_num = UIKit.label("", COMBO_SIZE, Color.WHITE, true, 16)
	combo_row.add_child(_combo_num)
	_combo_hits = UIKit.label("HITS", 34, UIKit.ACCENT, true, 7)
	_combo_hits.size_flags_vertical = Control.SIZE_SHRINK_END
	combo_row.add_child(_combo_hits)
	_combo_move_label = UIKit.label("", 26, UIKit.TEXT, true, 6)
	_combo_box.add_child(_combo_move_label)

	# Pop text (upper third) and banner (centre).
	# Upper band, off the screen centre: when the player faces a wall the hole
	# is at the centre and must stay visible (anchored by fraction, so it holds
	# at 1600x900 and 3456x2168 alike).
	_pop_label = _centered_label(POP_SIZE, POP_Y_FRAC)
	_banner_label = _centered_label(120, -0.04)
	_banner_sub = _centered_label(30, 0.08)
	_banner_sub.add_theme_font_override(&"font", UIKit.heavy_font())

	# Key hint, bottom-left.
	_hint = UIKit.label("F1 controls     F3 debug     Esc pause     %s restart" % UIKit.key_label(&"restart", false),
		18, UIKit.TEXT_DIM, false, 5)
	_hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hint.position = Vector2(36, -48)
	_root.add_child(_hint)

	# World popups (impact numbers, ARMOR, WHIFF), drawn under the banners.
	_popups = _Popups.new()
	_popups.set_anchors_preset(Control.PRESET_FULL_RECT)
	_popups.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_popups)
	_root.move_child(_popups, _arrows.get_index() + 1)

	# Round 8: health + pressure over Waves enemies, under the prompts.
	_enemy_bars_draw = _EnemyBars.new()
	_enemy_bars_draw.set_anchors_preset(Control.PRESET_FULL_RECT)
	_enemy_bars_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_enemy_bars_draw)

	# Counter prompts over the attackers, above the popups.
	_prompts_draw = _Prompts.new()
	_prompts_draw.set_anchors_preset(Control.PRESET_FULL_RECT)
	_prompts_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_prompts_draw)

	# Duel opponent, top-right: name, HP bar with damage trail.
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
	_opp_bars.position = Vector2(70.0, 30.0)
	_opp_bars.size = Vector2(OPP_W, _Bars.HP_H)
	_opp_bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_opp_root.add_child(_opp_bars)
	_opp_hp_label = UIKit.label("200", 24, Color.WHITE, true, 6)
	_opp_hp_label.position = Vector2(0.0, 26.0)
	_opp_hp_label.custom_minimum_size.x = 60.0
	_opp_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_opp_root.add_child(_opp_hp_label)
	# Round 8: its pressure, under the health bar.
	_opp_pressure = _PressureBar.new()
	_opp_pressure.bar_w = OPP_W
	_opp_pressure.position = Vector2(70.0, 30.0 + _Bars.HP_H + 8.0)
	_opp_pressure.size = Vector2(OPP_W, OPP_PRESSURE_H)
	_opp_pressure.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_opp_root.add_child(_opp_pressure)

	# Round 8: the charge meter, bottom centre (Round 5's place).
	_charge = _Charge.new()
	_charge.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_charge.offset_left = -_Charge.W * 0.5
	_charge.offset_right = _Charge.W * 0.5
	_charge.offset_top = -190
	_charge.offset_bottom = -140
	_charge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_charge.visible = false
	_root.add_child(_charge)

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
	_update_combo(t)
	_update_prompts(t)
	_update_pursuit_cue(t)
	_update_charge(t)
	_update_enemy_bars(t, dt)
	_prompts_draw.items = _prompt_items + ([_cue] if not _cue.is_empty() else [])
	_prompts_draw.queue_redraw()
	_update_arrows(t, dt)
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

## Prompts name the device the player is using: every event updates it.
func _input(event: InputEvent) -> void:
	UIKit.note_input(event)

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
	_bars.low = frac < 0.25
	_bars.pulse = t
	_bars.queue_redraw()
	_hp_label.text = "%d" % ceili(player.hp)

func _update_opponent(t: float, dt: float) -> void:
	if not _opp_root.visible:
		return
	if not is_instance_valid(opponent):
		_opp_bars.hp = 0.0
		_opp_hp_label.text = "0"
		_opp_bars.queue_redraw()
		_opp_pressure.fill = 0.0
		_opp_pressure.broken = false
		_opp_pressure.queue_redraw()
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
	_opp_bars.pulse = t
	_opp_bars.queue_redraw()
	_opp_hp_label.text = "%d" % ceili(f.hp)
	var cc := _combat(f)
	var broken := cc != null and cc.is_broken()
	var p := pressure_fraction(cc.get_pressure(), cc.get_pressure_max(), broken) if cc != null else 0.0
	_opp_p_shown = p if p >= _opp_p_shown else move_toward(_opp_p_shown, p, dt * PRESSURE_DRAIN)
	_opp_pressure.fill = _opp_p_shown
	_opp_pressure.broken = broken
	_opp_pressure.pulse = t
	_opp_pressure.queue_redraw()

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

# --- Combo counter -----------------------------------------------------------------
## Chain hits from GameEvents.chain_hit (count, move); the counter shows from
## COMBO_MIN hits, pops on each, holds COMBO_END_HOLD after chain_ended and
## fades over COMBO_FADE. Fallback: CombatController.get_chain_count(), once it
## has reported this chain, ends it when it drops to 0 (a missed chain_ended).
func _update_combo(t: float) -> void:
	_poll_chain(t)
	if _combo_count > 0 and _combo_end_at < 0.0 and t - _combo_hit_at > COMBO_STALE:
		_combo_end_at = t - COMBO_END_HOLD  # no hit and no chain_ended for a while: fade now
	var a := 0.0
	if _combo_count >= COMBO_MIN and not _round_over:
		a = 1.0
		if _combo_end_at >= 0.0:
			a = clampf(1.0 - (t - _combo_end_at - COMBO_END_HOLD) / COMBO_FADE, 0.0, 1.0)
	if _combo_end_at >= 0.0 and a <= 0.0:
		_combo_count = 0
		_combo_end_at = -1.0
		_combo_polled = false
	_combo_box.modulate.a = a
	var k := clampf((t - _combo_hit_at) / COMBO_POP_TIME, 0.0, 1.0)
	_combo_num.pivot_offset = Vector2(0.0, _combo_num.size.y * 0.6)
	_combo_num.scale = Vector2.ONE * lerpf(COMBO_POP, 1.0, ease(k, 0.4))

func _poll_chain(t: float) -> void:
	if player == null or not is_instance_valid(player) or player.combat == null:
		return
	var n := player.combat.get_chain_count()
	if n > 0:
		_combo_polled = true
		if n > _combo_count:
			_set_combo(n, player.combat.current_move_id(), t)
	elif _combo_polled and _combo_count > 0 and _combo_end_at < 0.0:
		_combo_end_at = t
		_combo_polled = false

func _set_combo(count: int, move_id: StringName, t: float) -> void:
	_combo_count = count
	_combo_hit_at = t
	_combo_end_at = -1.0
	if move_id != &"":
		_combo_move = move_id
	_combo_num.text = "%d" % count
	var heat := clampf(float(count - COMBO_MIN) / float(COMBO_HOT - COMBO_MIN), 0.0, 1.0)
	_combo_num.add_theme_color_override(&"font_color", Color.WHITE.lerp(UIKit.ACCENT, heat))
	_combo_move_label.text = String(_combo_move).replace("_", " ").to_upper()

func _on_chain_hit(attacker: Node3D, _victim: Node3D, move_id: StringName, count: int) -> void:
	if not _is_player(attacker) or _round_over:
		return
	_set_combo(maxi(count, 1), move_id, TimeDirector.now())

func _on_chain_ended(attacker: Node3D, count: int) -> void:
	if not _is_player(attacker) or _combo_count <= 0:
		return
	if count > _combo_count:
		_set_combo(count, _combo_move, _combo_hit_at)
	_combo_end_at = TimeDirector.now()
	_combo_polled = false

# --- Counter prompts ----------------------------------------------------------------
func _on_counter_window(attacker: Node3D, target: Node3D, open: bool, counterable: bool) -> void:
	if not _is_player(target) or attacker == null:
		return
	var id := attacker.get_instance_id()
	if open and not _round_over and attacker is Fighter:
		_prompts[id] = {"fighter": attacker, "counterable": counterable, "t0": TimeDirector.now(), "seen_open": false}
	else:
		_prompts.erase(id)
		_prompt_closed_at[id] = TimeDirector.now()

## Cross-check with Defence, which reads the same windows: an open window whose
## counter_window event was missed still gets its prompt, and the colour follows
## the attacker's current attack (Defence.get_counterable_attackers /
## get_uncounterable_attackers). A prompt its close event ended stays closed for
## PROMPT_REOPEN_GAP, so the poll never flickers it back.
func _cross_check_prompts(t: float) -> void:
	if _round_over or player == null or not is_instance_valid(player) or player.defence == null:
		return
	var d := player.defence
	for counterable: bool in [true, false]:
		var list: Array = []
		if counterable:
			list = d.get_counterable_attackers()
		elif d.has_method(&"get_uncounterable_attackers"):
			list = d.call(&"get_uncounterable_attackers")
		for f in list:
			if not is_instance_valid(f):
				continue
			var id: int = (f as Object).get_instance_id()
			if _prompts.has(id):
				_prompts[id]["counterable"] = counterable
			elif t - float(_prompt_closed_at.get(id, -INF)) > PROMPT_REOPEN_GAP:
				_prompts[id] = {"fighter": f, "counterable": counterable, "t0": t, "seen_open": true}
	if _prompt_closed_at.size() > 64:
		_prompt_closed_at.clear()

## Badges over the attackers (or at the screen edge toward one off screen),
## from counter_window events cross-checked with Defence's open windows.
## A prompt goes when its window closes, the attacker dies, goes down, reacts
## to a hit, is grabbed or freed, or after PROMPT_MAX_AGE. When the attacker's CombatController has
## reported its window open (is_counter_window_open), it closing ends the prompt too.
func _update_prompts(t: float) -> void:
	_cross_check_prompts(t)
	var cam := get_viewport().get_camera_3d()
	var items: Array = []
	for id in _prompts.keys():
		var e: Dictionary = _prompts[id]
		var fv = e["fighter"]  # untyped: may be a freed instance
		var gone := _round_over or not is_instance_valid(fv) or not (fv is Fighter)
		if not gone:
			var f := fv as Fighter
			# Reacting or held fighters cannot attack: their window is over even
			# if the close event has not arrived yet.
			gone = f.is_dead() or f.is_down() or f.is_reacting() or f.is_held() \
				or t - float(e["t0"]) > PROMPT_MAX_AGE
			if not gone and f.combat != null and player != null and is_instance_valid(player):
				if f.combat.is_counter_window_open(player):
					e["seen_open"] = true
				elif e["seen_open"]:
					gone = true
		if gone:
			_prompts.erase(id)
			continue
		if cam == null:
			continue
		items.append(_prompt_item(cam, fv as Fighter, bool(e["counterable"]), t - float(e["t0"]), t))
	_prompt_items = items

func _prompt_item(cam: Camera3D, f: Fighter, counterable: bool, age: float, t: float) -> Dictionary:
	var head := f.get_ground_position() + Vector3.UP * (f.get_height() + PROMPT_HEAD_UP)
	var it := _badge_item(cam, head, UIKit.key_label(&"counter" if counterable else &"dash"),
		"COUNTER" if counterable else "DODGE", UIKit.TELL_STRIKE if counterable else UIKit.TELL_GRAB, age, t)
	it["fighter"] = f
	it["counterable"] = counterable
	return it

## A badge with `key` written in it and `caption` above, pointing at world
## point `anchor` (or toward the screen edge when it is off screen).
func _badge_item(cam: Camera3D, anchor: Vector3, key: String, caption: String, color: Color, age: float, t: float) -> Dictionary:
	var font := UIKit.heavy_font()
	var key_size := _Prompts.key_font_size(key)
	var w := maxf(PROMPT_H, font.get_string_size(key, HORIZONTAL_ALIGNMENT_LEFT, -1, key_size).x + 26.0)
	var half := Vector2(w, PROMPT_H) * 0.5
	var vp := get_viewport().get_visible_rect().size
	var on_screen := _is_on_screen(cam, anchor)
	var tip: Vector2
	var dir: Vector2  # pointer direction, badge -> anchor
	if on_screen:
		tip = cam.unproject_position(anchor)
		dir = Vector2.DOWN
	else:
		var edge := _edge_arrow(cam, anchor)
		tip = edge["pos"]
		dir = Vector2.from_angle(float(edge["angle"]))
	var reach := absf(dir.x) * half.x + absf(dir.y) * half.y
	var center := tip - dir * (reach + PROMPT_GAP)
	var top := half.y + _Prompts.CAPTION_SIZE + PROMPT_MARGIN  # room for the caption above
	center.x = clampf(center.x, half.x + PROMPT_MARGIN, maxf(vp.x - half.x - PROMPT_MARGIN, half.x + PROMPT_MARGIN))
	center.y = clampf(center.y, top, maxf(vp.y - half.y - PROMPT_MARGIN, top))
	var k := clampf(age / PROMPT_IN, 0.0, 1.0)
	return {"color": color, "key": key, "key_size": key_size, "caption": caption,
		"center": center, "tip": tip, "dir": dir, "size": Vector2(w, PROMPT_H), "on_screen": on_screen,
		"scale": lerpf(1.6, 1.0, ease(k, 0.4)), "alpha": k, "pulse": fposmod(t * 2.2, 1.0)}

# --- Pursuit cues (God path) --------------------------------------------------------
## After a launch the player caused, while Dash would pursue: "DASH: PURSUE"
## (the Dash key in the badge) near the flying body. During the pursuit hang:
## "ATTACK: LAUNCH  /  BACK + ATTACK: SPIKE" at the body. Sources, most
## authoritative first: Defence.get_pursuit_target() for the hang, Defence's
## get_pursuit_window_target() for the window when it has one, else this HUD's
## mirror of Defence's rule (a launch hit_landed by the player opens it for the
## hit's hitstop + Tuning.PURSUIT_WINDOW; no window with Tuning.debug_pursuit_max
## at 0 or the chain spent, or for a spike).
func _update_pursuit_cue(t: float) -> void:
	var kind: StringName = &""
	var body: Fighter = null
	if not _round_over and player != null and is_instance_valid(player) and not player.is_dead():
		var d := player.defence
		var hang = null
		if d != null and d.has_method(&"get_pursuit_target"):
			hang = d.call(&"get_pursuit_target")
		elif t <= _hang_until:
			hang = _hang_victim
		if is_instance_valid(hang) and hang is Fighter and not (hang as Fighter).is_dead():
			kind = &"hang"
			body = hang as Fighter
		else:
			var pv = null
			if d != null and d.has_method(&"get_pursuit_window_target"):
				pv = d.call(&"get_pursuit_window_target")
			elif t <= _pursue_until:
				pv = _pursue_victim
			if is_instance_valid(pv) and pv is Fighter and _pursuable(pv as Fighter):
				kind = &"pursue"
				body = pv as Fighter
	var cam := get_viewport().get_camera_3d()
	if kind == &"" or cam == null:
		_cue = {}
		_cue_kind = &""
		return
	if kind != _cue_kind:
		_cue_t0 = t
		_cue_kind = kind
	var at := body.get_center_of_mass() + Vector3.UP * PURSUE_ABOVE
	if kind == &"pursue":
		_cue = _badge_item(cam, at, UIKit.key_label(&"dash"), PURSUE_CAPTION, UIKit.PURSUIT_COLOR, t - _cue_t0, t)
		_cue["text"] = PURSUE_CAPTION
	else:
		_cue = _badge_item(cam, at, HANG_TEXT, "", UIKit.PURSUIT_COLOR, t - _cue_t0, t)
		_cue["text"] = HANG_TEXT
	_cue["kind"] = kind
	_cue["fighter"] = body

## A launched body Dash may still chase: flying, alive, pursuit unlocked
## (Tuning.debug_pursuit_max) and the chain on this flight not spent.
func _pursuable(v: Fighter) -> bool:
	if v.is_dead() or not v.is_launched() or Tuning.debug_pursuit_max <= 0:
		return false
	var d := player.defence
	if d != null and d.has_method(&"pursuit_chain") and int(d.call(&"pursuit_chain", v)) >= Tuning.debug_pursuit_max:
		return false
	return true

## A launch by the player opens the pursuit window, the mirror of Defence's
## rule (a launch tier, or Reaction.LAUNCH for an untiered hit); a spike
## (HitInfo.react &"spike") closes it for that body.
func _note_player_launch(info: HitInfo) -> void:
	var v := info.victim as Fighter
	if v == null or not is_instance_valid(v) or info.result != HitInfo.Result.HIT:
		return
	if _hang_victim == v:
		_hang_victim = null  # the pursuit hit landed
	if info.react == &"spike":
		if _pursue_victim == v:
			_pursue_victim = null
		return
	var launch := HitInfo.is_launch_tier(info.tier) if info.tier != HitInfo.Tier.NONE \
		else info.reaction == HitInfo.Reaction.LAUNCH
	if not launch or v.is_dead():
		return
	var now := TimeDirector.now()
	var stop := info.hitstop if info.hitstop > 0.0 else LAUNCH_HITSTOP_FALLBACK
	_pursue_victim = v
	_pursue_t0 = now
	_pursue_until = now + stop + Tuning.PURSUIT_WINDOW

func _on_pursuit(attacker: Node3D, victim: Node3D) -> void:
	if not _is_player(attacker):
		return
	_pursue_victim = null  # this launch's window is used; the relaunch opens the next
	_pursue_until = -INF
	_hang_victim = victim
	_hang_until = TimeDirector.now() + Tuning.PURSUIT_HANG + HANG_GRACE

func _on_teleported(fighter: Node3D, _from: Vector3, _to: Vector3, kind: StringName) -> void:
	if _is_player(fighter) and kind != &"pursuit":
		pop_text("TELEPORT", UIKit.PURSUIT_COLOR, 0.7)

## Teleport with no free spot behind the attacker: a sidestep instead.
func _on_sidestepped(fighter: Node3D, _direction: Vector3) -> void:
	if _is_player(fighter) and player != null:
		popup_at(player.get_aim_point() + Vector3.UP * 0.7, "SIDESTEP", Color(0.85, 0.9, 1.0), 28, 0.7)

func _on_countered(defender: Node3D, attacker: Node3D) -> void:
	if attacker != null:
		_prompts.erase(attacker.get_instance_id())
		_prompt_closed_at[attacker.get_instance_id()] = TimeDirector.now()
	if _is_player(defender):
		pop_text("COUNTER", UIKit.TELL_STRIKE, 0.7)

## A Counter press with nothing to counter: WHIFF, or DODGE IT when a blue
## (uncounterable) attack is the one coming.
func _on_counter_whiffed(defender: Node3D) -> void:
	if not _is_player(defender) or player == null:
		return
	var blue := false
	for id in _prompts:
		if not bool(_prompts[id]["counterable"]):
			blue = true
	popup_at(player.get_aim_point() + Vector3.UP * 0.7, "DODGE IT" if blue else "WHIFF",
		UIKit.TELL_GRAB if blue else UIKit.TEXT_DIM, 28, 0.7)

# --- Round 8: charge meter ------------------------------------------------------------
## The CombatController the Round 8 reads go through (tests substitute a double).
func _combat(f: Fighter) -> CombatController:
	return f.combat if f != null and is_instance_valid(f) else null

func _player_ok() -> bool:
	return player != null and is_instance_valid(player) and not player.is_dead()

## Steps of `steps` that `c` has reached.
static func charge_steps_passed(c: float, steps: Array) -> int:
	var n := 0
	for s: float in steps:
		if c >= s - CHARGE_STEP_EPS:
			n += 1
	return n

## The meter's colour tier: 0 white under the first step, 1 orange past it, 2
## red past the last. A move with one step goes white -> red; with none it
## stays white (and still flashes at full).
static func charge_tier(c: float, steps: Array) -> int:
	var passed := charge_steps_passed(c, steps)
	if passed <= 0:
		return 0
	return 2 if passed >= steps.size() else 1

static func charge_color(tier: int) -> Color:
	return [UIKit.CHARGE_WHITE, UIKit.CHARGE_ORANGE, UIKit.CHARGE_RED][clampi(tier, 0, 2)]

func _charge_begin(move_id: StringName, t: float) -> void:
	_charge_state = &"charging"
	_charge_t0 = t
	_charge_c = 0.0
	_charge_steps = []
	_charge_move = move_id
	_charge_full = false
	_charge_full_at = -INF
	_charge_polled = false
	_charge_passed = 0
	_charge_step_at = -INF

func _charge_end(state: StringName, t: float) -> void:
	_charge_state = state
	_charge_t0 = t

func _on_charge_started(fighter: Node3D, move_id: StringName) -> void:
	if _is_player(fighter) and not _round_over:
		_charge_begin(move_id, TimeDirector.now())

func _on_charge_level_changed(fighter: Node3D, _level: int) -> void:
	if _is_player(fighter) and _charge_state == &"charging":
		_charge_step_at = TimeDirector.now()

func _on_charge_full(fighter: Node3D, move_id: StringName) -> void:
	if not _is_player(fighter) or _round_over:
		return
	var t := TimeDirector.now()
	if _charge_state != &"charging":
		_charge_begin(move_id, t)
	_charge_c = 1.0
	if not _charge_full:
		_charge_full = true
		_charge_full_at = t

func _on_charge_released(fighter: Node3D, _move_id: StringName, _level: int) -> void:
	if _is_player(fighter) and _charge_state == &"charging":
		_charge_end(&"released", TimeDirector.now())

func _on_charge_cancelled(fighter: Node3D, _move_id: StringName, _reason: StringName) -> void:
	if _is_player(fighter) and _charge_state == &"charging":
		_charge_end(&"cancelled", TimeDirector.now())

## The meter follows CombatController's getters each frame, and the charge
## events in between. A charge the getters reported that stops with no event
## counts as released. With events only (no getter reports it), c runs on the
## time held, from R8_TAP_MAX to Tuning.debug_charge_full.
func _update_charge(t: float) -> void:
	var cc := _combat(player) if _player_ok() else null
	if cc != null and not _round_over and cc.is_charging():
		if _charge_state != &"charging":
			_charge_begin(cc.get_charge_move(), t)
		_charge_polled = true
		_charge_c = clampf(cc.get_charge(), 0.0, 1.0)
		_charge_steps = cc.get_charge_steps()
		if cc.get_charge_move() != &"":
			_charge_move = cc.get_charge_move()
		if cc.is_charge_full() and not _charge_full:
			_charge_full = true
			_charge_full_at = t
	elif _charge_state == &"charging":
		if _charge_polled or _round_over or not _player_ok():
			_charge_end(&"released", t)
		elif not _charge_full:
			var span := maxf(Tuning.debug_charge_full - Tuning.R8_TAP_MAX, 0.01)
			_charge_c = clampf((t - _charge_t0) / span, _charge_c, 1.0)
	if _charge_state == &"charging":
		var passed := charge_steps_passed(_charge_c, _charge_steps)
		if passed > _charge_passed:
			_charge_step_at = t
		_charge_passed = passed
	var fill := _charge_c
	var alpha := 1.0
	var shake := 0.0
	var shown := _charge_state == &"charging"
	if _charge_state == &"released":
		var k := (t - _charge_t0) / CHARGE_HOLD
		shown = k < 1.0
		alpha = clampf(2.0 - 2.0 * k, 0.0, 1.0)
	elif _charge_state == &"cancelled":
		var k := (t - _charge_t0) / CHARGE_CANCEL_TIME
		shown = k < 1.0
		fill = _charge_c * clampf(1.0 - k, 0.0, 1.0)
		shake = CHARGE_SHAKE * (1.0 - clampf(k, 0.0, 1.0)) * sin(k * 46.0)
		alpha = clampf(1.0 - k * k, 0.0, 1.0)
	if not shown:
		_charge_state = &""
	var tier := charge_tier(_charge_c, _charge_steps)
	var col := charge_color(tier)
	var flashing := shown and _charge_full and _charge_state != &"cancelled"
	var full_pop := clampf(1.0 - (t - _charge_full_at) / CHARGE_FULL_POP, 0.0, 1.0) if flashing else 0.0
	var step_pop := clampf(1.0 - (t - _charge_step_at) / CHARGE_STEP_POP, 0.0, 1.0) if shown else 0.0
	var draw_col := col
	if _charge_state == &"cancelled":
		draw_col = col.lerp(Color(0.45, 0.45, 0.47), 0.65)
	elif flashing:
		draw_col = col.lerp(Color.WHITE, maxf(0.5 + 0.5 * sin(t * CHARGE_PULSE), full_pop))
	_charge.visible = shown
	if shown:
		_charge.fill = fill
		_charge.color = draw_col
		_charge.tick_color = col
		_charge.steps = _charge_steps
		_charge.passed = charge_steps_passed(_charge_c, _charge_steps)
		_charge.glow = (0.35 + 0.5 * (0.5 + 0.5 * sin(t * CHARGE_PULSE))) if flashing else 0.0
		_charge.full_pop = full_pop
		_charge.bar_scale = 1.0 + 0.12 * step_pop + 0.1 * full_pop
		_charge.shake = shake
		_charge.alpha = alpha
		_charge.queue_redraw()
	_charge_info = {"visible": shown, "state": _charge_state, "fill": fill if shown else 0.0, "c": _charge_c,
		"steps": _charge_steps, "passed": charge_steps_passed(_charge_c, _charge_steps), "tier": tier, "color": col,
		"draw_color": draw_col, "full": _charge_full, "flashing": flashing, "shake": shake, "alpha": alpha,
		"scale": _charge.bar_scale, "move": _charge_move}

# --- Round 8: pressure bars -------------------------------------------------------------
## The bar's share: 1 while broken open, else pressure / capacity (0..1).
static func pressure_fraction(pressure: float, pressure_max: float, broken: bool) -> float:
	if broken:
		return 1.0
	return clampf(pressure / maxf(pressure_max, 0.001), 0.0, 1.0)

## Waves: a compact health + pressure pair over each enemy that is engaged (the
## player's combat target, within ENEMY_BAR_ENGAGE, or under pressure or
## broken) or damaged, fading in and out. The Duelist uses the top bars.
## Shown pressure rises at once and falls at PRESSURE_DRAIN, so a break's full
## bar visibly empties. Bars lift above an enemy's counter prompt.
func _update_enemy_bars(t: float, dt: float) -> void:
	var cam := get_viewport().get_camera_3d()
	var vp := get_viewport().get_visible_rect().grow(-8.0)
	var target: Fighter = null
	if _player_ok() and player.combat != null:
		target = player.combat.get_combat_target()
	var items: Array = []
	var seen := {}
	for n in get_tree().get_nodes_in_group(&"enemies"):
		var f := n as Fighter
		if f == null or f == opponent or f.is_queued_for_deletion():
			continue
		var id := f.get_instance_id()
		seen[id] = true
		if not _enemy_bar_state.has(id):
			_enemy_bar_state[id] = {"fighter": f, "shown": 0.0, "alpha": 0.0}
		var e: Dictionary = _enemy_bar_state[id]
		var cc := _combat(f)
		var broken := cc != null and cc.is_broken()
		var p := pressure_fraction(cc.get_pressure(), cc.get_pressure_max(), broken) if cc != null else 0.0
		var shown_p: float = e["shown"]
		shown_p = p if p >= shown_p else move_toward(shown_p, p, dt * PRESSURE_DRAIN)
		e["shown"] = shown_p
		var engaged := f == target or p > 0.0 or broken
		if not engaged and _player_ok():
			var d := player.get_ground_position() - f.get_ground_position()
			engaged = Vector2(d.x, d.z).length() <= ENEMY_BAR_ENGAGE
		var damaged := f.hp < f.max_hp - 0.01
		var want := not _round_over and not f.is_dead() and (engaged or damaged)
		var a := move_toward(float(e["alpha"]), 1.0 if want else 0.0, dt / ENEMY_BAR_FADE)
		e["alpha"] = a
		if a <= 0.0 or cam == null:
			continue
		var anchor := f.get_center_of_mass() + Vector3.UP * ENEMY_BAR_ABOVE_BODY if f.is_body_simulating() \
			else f.get_ground_position() + Vector3.UP * (f.get_height() + ENEMY_BAR_ABOVE)
		if cam.is_position_behind(anchor) or cam.global_position.distance_to(anchor) > ENEMY_BAR_MAX_DIST:
			continue
		var sp := cam.unproject_position(anchor)
		if _prompts.has(id):
			sp.y -= PROMPT_GAP + PROMPT_H + _Prompts.CAPTION_SIZE + 6.0  # above the counter badge
		if not vp.has_point(sp):
			continue
		items.append({"fighter": f, "pos": sp, "hp": clampf(f.hp / maxf(f.max_hp, 1.0), 0.0, 1.0),
			"pressure": shown_p, "broken": broken, "alpha": a, "pulse": t})
	for id in _enemy_bar_state.keys():
		if not seen.has(id):
			_enemy_bar_state.erase(id)
	_enemy_bar_items = items
	_enemy_bars_draw.items = items
	_enemy_bars_draw.queue_redraw()

## A break pops "BROKEN" over the enemy (its bar flashes until it recovers).
func _on_pressure_broken(fighter: Node3D, _attacker: Node3D) -> void:
	if _round_over or not is_instance_valid(fighter) or not (fighter is Fighter) or _is_player(fighter):
		return
	popup_at((fighter as Fighter).get_aim_point() + Vector3.UP * 0.6, "BROKEN", UIKit.PRESSURE_COLOR, 34, 0.9)

## A pressure bar in `r`: dark back, gold fill that brightens toward full;
## while broken it is full and flashes white with an outline.
static func draw_pressure(ci: CanvasItem, r: Rect2, fill: float, broken: bool, pulse: float, alpha: float) -> void:
	ci.draw_rect(r.grow(2.0), Color(0, 0, 0, 0.75 * alpha))
	ci.draw_rect(r, Color(0.14, 0.11, 0.04, 0.9 * alpha))
	var col := UIKit.PRESSURE_COLOR.darkened(0.3 * (1.0 - clampf(fill, 0.0, 1.0)))
	var flash := 0.5 + 0.5 * sin(pulse * PRESSURE_PULSE)
	if broken:
		fill = 1.0
		col = UIKit.PRESSURE_COLOR.lerp(UIKit.PRESSURE_BROKEN, flash)
	col.a *= alpha
	ci.draw_rect(Rect2(r.position, Vector2(r.size.x * clampf(fill, 0.0, 1.0), r.size.y)), col)
	if broken:
		ci.draw_rect(r.grow(3.0), Color(UIKit.PRESSURE_BROKEN, (0.4 + 0.6 * flash) * alpha), false, 2.0)

# --- Off-screen arrows -------------------------------------------------------------
## Off-screen attack arrows (Feel Reference: Off-screen attackers): from a
## wind-up that started off screen until its first active frame (attack_active),
## orange for strikes, blue for the rest (grabs, the charge). An attacker with a
## counter prompt shows the prompt at the screen edge instead. The wind-up's own
## clock is game time, so the fallback expiry is too.
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
			# Wind-up over once the attack we saw stops (countered, interrupted, cancelled).
			if (fv as Fighter).combat.is_attacking():
				e["seen_attacking"] = true
			elif e.get("seen_attacking", false):
				ended = true
		if ended or float(e["left"]) < -ARROW_GRACE or not is_instance_valid(fv) or not (fv is Fighter) or fv.is_dead() or fv.is_down():
			_tells.remove_at(i)
		elif e["arrow"] and cam != null and not _round_over and not _prompts.has((fv as Object).get_instance_id()):
			var p: Vector3 = (fv as Fighter).get_aim_point()
			if not _is_on_screen(cam, p):
				var a := _edge_arrow(cam, p)
				a["color"] = UIKit.TELL_STRIKE if e["kind"] == &"strike" else UIKit.TELL_GRAB
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

func _on_hit_landed(info: HitInfo) -> void:
	if info == null:
		return
	if _is_player(info.attacker):
		_note_player_launch(info)
	if not _is_player(info.victim):
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

## Every enemy wind-up is tracked; one that starts off screen gets an edge
## arrow until its first active frame.
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
	for i in range(_tells.size() - 1, -1, -1):
		if _tells[i]["fighter"] == attacker:
			_tells.remove_at(i)

func _on_wave_started(index: int, total: int) -> void:
	set_wave(index, total)

# --- Debug -----------------------------------------------------------------------------
## One player hit for the overlay: move, Round 7 reaction, damage, weight, push,
## stun, chain index, payoff (on the victim's state), counter / drive.
static func describe_hit(info: HitInfo) -> String:
	if info == null:
		return "-"
	var react := String(info.react) if info.react != &"" else String(HitInfo.tier_name(info.tier))
	var flags := PackedStringArray()
	if info.payoff:
		flags.append("PAYOFF on %s" % (String(info.victim_state) if info.victim_state != &"" else "?"))
	if info.counter:
		flags.append("COUNTER")
	if info.drive:
		flags.append("DRIVE")
	return "%-11s %-9s dmg %5.1f  w %.2f  push %.2f  stun %.2f  chain #%d  %s" % [
		String(info.move_id), react.to_upper(), info.damage, info.weight, info.push, info.stun,
		info.chain_index, " ".join(flags)]

## The player's combat state for the overlay, read through the Round 7 contract
## (CombatController, Defence, Traversal, Carry, Fighter stubs) and, when B adds
## them, get_strike_debug()'s "buffered" / "phase" keys. Round 8: the charge
## (c, steps, full), the air hits, and the target's pressure, broken time and level.
func gather_combat_debug() -> Dictionary:
	var d := {"move": &"", "phase": "IDLE", "string_index": 0, "chain": 0, "glide": false,
		"buffered": "-", "target": "", "target_react": &"", "target_left": 0.0, "target_dist": -1.0,
		"target_down": false, "target_lifted": false, "hud_combo": _combo_count,
		"charging": false, "charge": 0.0, "charge_steps": [], "charge_full": false, "charge_move": &"",
		"air_hits": 0, "target_pressure": 0.0, "target_pressure_max": 0.0, "target_broken": false,
		"target_broken_left": 0.0, "target_level": 0}
	if player == null or not is_instance_valid(player) or player.combat == null:
		return d
	var c := player.combat
	d["move"] = c.current_move_id()
	if c.is_attack_active():
		d["phase"] = "ACTIVE"
	elif c.is_in_recovery():
		d["phase"] = "RECOVERY"
	elif c.is_attacking():
		d["phase"] = "STARTUP"
	d["string_index"] = c.get_string_index()
	d["chain"] = c.get_chain_count()
	d["glide"] = c.is_gliding()
	var cc := _combat(player)
	if cc != null:
		d["charging"] = cc.is_charging()
		d["charge"] = cc.get_charge()
		d["charge_steps"] = cc.get_charge_steps()
		d["charge_full"] = cc.is_charge_full()
		d["charge_move"] = cc.get_charge_move()
		d["air_hits"] = cc.get_air_hits()
	if c.has_method(&"get_strike_debug"):
		var sd: Dictionary = c.call(&"get_strike_debug")
		for k in ["buffered", "buffer"]:
			if sd.has(k) and str(sd[k]) != "":
				d["buffered"] = str(sd[k])
		if sd.has("phase"):
			d["phase"] = str(sd["phase"]).to_upper()
	var target: Fighter = c.get_combat_target()
	var how := "combat target"
	if target == null and c.last_dealt != null and is_instance_valid(c.last_dealt.victim) \
			and c.last_dealt.victim is Fighter and not (c.last_dealt.victim as Fighter).is_dead():
		target = c.last_dealt.victim as Fighter
		how = "last hit"
	if target != null and is_instance_valid(target):
		d["target"] = "%s (%s)" % [target.name, how]
		d["target_react"] = target.get_react_state()
		d["target_left"] = target.get_react_time_left()
		d["target_down"] = target.is_down()
		d["target_lifted"] = target.is_lifted()
		d["target_dist"] = player.get_ground_position().distance_to(target.get_ground_position())
		d["target_level"] = target.level
		var tc := _combat(target)
		if tc != null:
			d["target_pressure"] = tc.get_pressure()
			d["target_pressure_max"] = tc.get_pressure_max()
			d["target_broken"] = tc.is_broken()
			d["target_broken_left"] = tc.get_broken_time_left()
	return d

## Overlay lines for gather_combat_debug()'s dictionary.
static func combat_debug_lines(d: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	var idx := clampi(int(d.get("string_index", 0)), 0, Tuning.R7_PUNCH_STRING.size() - 1)
	var move := String(d.get("move", &""))
	lines.append("MOVE       %-11s %-8s  buffered %s" % [move if move != "" else "-", d.get("phase", "IDLE"), d.get("buffered", "-")])
	lines.append("STRING     %d/%d (next punch: %s)   CHAIN %d hits (HUD %d)   GLIDE %s" % [idx + 1,
		Tuning.R7_PUNCH_STRING.size(), String(Tuning.R7_PUNCH_STRING[idx]).to_upper(), int(d.get("chain", 0)),
		int(d.get("hud_combo", 0)), "ON" if d.get("glide", false) else "off"])
	var target: String = d.get("target", "")
	if target == "":
		lines.append("TARGET     -")
	else:
		var react := String(d.get("target_react", &""))
		var state := react.to_upper() if react != "" else "none"
		if d.get("target_down", false) and react != "down":
			state += " DOWN"
		if d.get("target_lifted", false):
			state += " LIFTED"
		lines.append("TARGET     %s  react %s %.2f s  %.1f m" % [target, state, float(d.get("target_left", 0.0)),
			float(d.get("target_dist", 0.0))])
	# Round 8: the charge, the target's pressure, the air combo.
	var steps := PackedStringArray()
	for s: float in d.get("charge_steps", []):
		steps.append("%.2f" % s)
	if d.get("charging", false):
		lines.append("CHARGE     c %.2f  steps [%s]%s  %s" % [float(d.get("charge", 0.0)), ", ".join(steps),
			"  FULL" if d.get("charge_full", false) else "", String(d.get("charge_move", &""))])
	else:
		lines.append("CHARGE     -")
	if target == "":
		lines.append("PRESSURE   -")
	else:
		var pmax := float(d.get("target_pressure_max", 0.0))
		var pv := float(d.get("target_pressure", 0.0))
		lines.append("PRESSURE   %.2f / %.2f (%d%%)%s   level %d" % [pv, pmax, roundi(100.0 * pv / maxf(pmax, 0.001)),
			"  BROKEN %.2f s" % float(d.get("target_broken_left", 0.0)) if d.get("target_broken", false) else "",
			int(d.get("target_level", 0))])
	lines.append("AIR        hits %d / %d" % [int(d.get("air_hits", 0)), Tuning.debug_air_hits])
	return lines

func _debug_text() -> String:
	var lines := PackedStringArray()
	if player != null and is_instance_valid(player):
		lines.append_array(combat_debug_lines(gather_combat_debug()))
		var c := player.combat
		lines.append("LAST HIT   " + describe_hit(c.last_dealt if c != null else null))
		lines.append("TAKEN      " + describe_hit(c.last_received if c != null else null))
		var tr := player.traversal
		var speed := Vector2(player.velocity.x, player.velocity.z).length()
		var moving := PackedStringArray()
		if tr != null:
			if tr.has_method(&"get_speed"):
				speed = maxf(float(tr.call(&"get_speed")), speed)
			if tr.has_method(&"is_sprinting") and tr.call(&"is_sprinting"):
				moving.append("SPRINT")
			if tr.is_dodging():
				moving.append("DODGE")
			if tr.is_driving():
				moving.append("DRIVE %.1f m/s" % tr.get_drive_speed())
		if player.carry != null and player.carry.get_throw_windup() > 0.0:
			moving.append("WINDUP %.2f" % player.carry.get_throw_windup())
		lines.append("SPEED      %5.2f m/s  %s" % [speed, " ".join(moving)])
		var st := player.get_state()
		var names := RagdollController.State.keys()
		var own := String(player.get_react_state())
		lines.append("YOU        HP %.0f / %.0f   state %s   react %s%s%s" % [player.hp, player.max_hp,
			names[st] if st >= 0 and st < names.size() else str(st), own if own != "" else "-",
			"  INVULN" if player.is_invulnerable() else "",
			"  COUNTERING" if player.defence != null and player.defence.is_countering() else ""])
		lines.append("UPGRADES   speed cap %d m/s  ram %d  teleport %s  pursuit x%d   cue %s" % [
			roundi(Tuning.debug_speed_cap), Tuning.debug_ram_level, "ON" if Tuning.debug_teleport else "off",
			Tuning.debug_pursuit_max, String(_cue.get("text", "-"))])
		lines.append("           full charge %.2f s  pressure x%.2f  launch step %.2f  air hits %d%s" % [
			Tuning.debug_charge_full, Tuning.debug_pressure_mult, Tuning.debug_launch_step, Tuning.debug_air_hits,
			"   (DUEL: all at max)" if GameMenus.is_max_upgrades_applied() else ""])
		lines.append("PROMPTS    %d open (%d counterable)" % [_prompts.size(),
			_prompts.values().filter(func(e: Dictionary) -> bool: return bool(e["counterable"])).size()])
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
	if rig and rig.has_method(&"get_debug_text"):
		lines.append(str(rig.call(&"get_debug_text")))
	return "\n".join(lines)

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

# --- Drawing ---------------------------------------------------------------------------
## HP bar with a trailing "damage taken" bar.
class _Bars extends Control:
	const HP_W := 460.0
	const HP_H := 26.0
	var hp_w := HP_W
	var hp := 1.0
	var hp_delayed := 1.0
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
		# Quarter ticks: the 100-point scale reads as 25-HP steps.
		for q in range(1, 4):
			var x := hp_w * q * 0.25
			draw_line(Vector2(x, HP_H * 0.6), Vector2(x, HP_H), Color(0, 0, 0, 0.45), 2.0)

## Round 8 charge meter: a bar that fills with c in the colour of the steps
## passed (white, orange, red), thin ticks at the steps (no labels), popping
## when a step is crossed and pulsing white with a glow while full. HUD sets
## every value; this only draws.
class _Charge extends Control:
	const W := 320.0
	const H := 16.0
	const BAR_Y := 26.0
	var fill := 0.0
	var color := UIKit.CHARGE_WHITE      ## fill colour, the full flash included
	var tick_color := UIKit.CHARGE_WHITE ## the tier's own colour
	var steps: Array[float] = []
	var passed := 0
	var glow := 0.0                      ## > 0 while full: outline alpha
	var full_pop := 0.0
	var bar_scale := 1.0
	var shake := 0.0                     ## px sideways (a cancel)
	var alpha := 1.0

	func _draw() -> void:
		var r := Rect2(Vector2(0, BAR_Y), Vector2(W, H))
		var c := r.get_center()
		draw_set_transform(c * (1.0 - bar_scale) + Vector2(shake, 0.0), 0.0, Vector2(bar_scale, bar_scale))
		draw_rect(r.grow(3.0), Color(0, 0, 0, 0.75 * alpha))
		draw_rect(r, Color(0.12, 0.1, 0.08, 0.9 * alpha))
		var w := W * clampf(fill, 0.0, 1.0)
		draw_rect(Rect2(r.position, Vector2(w, H)), Color(color, color.a * alpha))
		draw_rect(Rect2(r.position, Vector2(w, H * 0.35)), Color(1, 1, 1, 0.15 * alpha))
		for i in steps.size():
			if steps[i] >= 0.999:
				continue  # the bar's end is the full mark
			var x := W * steps[i]
			var reached := i < passed
			draw_line(Vector2(x, BAR_Y - 4.0), Vector2(x, BAR_Y + H + 4.0),
				Color(tick_color, alpha) if reached else Color(1, 1, 1, 0.7 * alpha), 3.0 if reached else 2.0)
		if glow > 0.0:
			draw_rect(r.grow(5.0 + 4.0 * full_pop), Color(1, 1, 1, glow * alpha), false, 2.0)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## Round 8: the Duelist's pressure under its health bar.
class _PressureBar extends Control:
	var bar_w := 360.0
	var fill := 0.0
	var broken := false
	var pulse := 0.0

	func _draw() -> void:
		HUD.draw_pressure(self, Rect2(Vector2.ZERO, Vector2(bar_w, HUD.OPP_PRESSURE_H)), fill, broken, pulse, 1.0)

## Round 8 (Waves): a compact health + pressure pair over each shown enemy.
class _EnemyBars extends Control:
	var items: Array = []

	func _draw() -> void:
		var w := HUD.ENEMY_BAR_W
		for it: Dictionary in items:
			var a: float = it["alpha"]
			var c: Vector2 = it["pos"]
			var hp_r := Rect2(c + Vector2(-w * 0.5, -(HUD.ENEMY_BAR_HP_H + HUD.ENEMY_BAR_GAP + HUD.ENEMY_BAR_P_H)),
				Vector2(w, HUD.ENEMY_BAR_HP_H))
			draw_rect(hp_r.grow(2.0), Color(0, 0, 0, 0.75 * a))
			draw_rect(hp_r, Color(0.16, 0.05, 0.05, 0.9 * a))
			draw_rect(Rect2(hp_r.position, Vector2(w * float(it["hp"]), hp_r.size.y)), Color(UIKit.HP_COLOR, a))
			var p_r := Rect2(hp_r.position + Vector2(0.0, HUD.ENEMY_BAR_HP_H + HUD.ENEMY_BAR_GAP), Vector2(w, HUD.ENEMY_BAR_P_H))
			HUD.draw_pressure(self, p_r, float(it["pressure"]), bool(it["broken"]), float(it["pulse"]), a)

## Counter prompts: a key badge (circle for one-letter keys, a pill otherwise)
## in the tell colour, the caption above it, a pointer to the attacker's head
## (or toward the screen edge for one off screen) and a ring that pulses out.
class _Prompts extends Control:
	const CAPTION_SIZE := 18
	var items: Array = []
	var _box := StyleBoxFlat.new()
	var _ring := StyleBoxFlat.new()

	static func key_font_size(key: String) -> int:
		if key.length() <= 2:
			return 26
		return 20 if key.length() <= 10 else 18

	func _init() -> void:
		_box.set_border_width_all(3)
		_ring.draw_center = false
		_ring.set_border_width_all(3)

	func _draw() -> void:
		var font := UIKit.heavy_font()
		for it: Dictionary in items:
			var col: Color = it["color"]
			var a: float = it["alpha"]
			var sc: float = it["scale"]
			var size: Vector2 = it["size"] * sc
			var c: Vector2 = it["center"]
			var dir: Vector2 = it["dir"]
			var tip: Vector2 = it["tip"]
			var rect := Rect2(c - size * 0.5, size)
			var radius := int(size.y * 0.5)
			# Pointer from the badge toward the attacker.
			var side := dir.orthogonal()
			var reach := absf(dir.x) * size.x * 0.5 + absf(dir.y) * size.y * 0.5
			var base := c + dir * (reach - 2.0)
			var point := base + dir * minf(maxf((tip - base).dot(dir), 6.0), 14.0)
			draw_colored_polygon(PackedVector2Array([point + dir * 3.0, base + side * 11.0, base - side * 11.0]), Color(0, 0, 0, 0.7 * a))
			draw_colored_polygon(PackedVector2Array([point, base + side * 8.0, base - side * 8.0]), Color(col, a))
			# Pulsing ring.
			var p: float = it["pulse"]
			_ring.set_corner_radius_all(radius + int(10.0 * p))
			_ring.border_color = Color(col, 0.7 * a * (1.0 - p))
			draw_style_box(_ring, rect.grow(4.0 + 10.0 * p))
			# Badge.
			_box.set_corner_radius_all(radius)
			_box.bg_color = Color(col, a)
			_box.border_color = Color(0, 0, 0, 0.8 * a)
			draw_style_box(_box, rect)
			var key: String = it["key"]
			var fs := int(float(it["key_size"]) * sc)
			var kw := font.get_string_size(key, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(font, c + Vector2(-kw * 0.5, fs * 0.36), key, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.06, 0.05, 0.05, a))
			# Caption above the badge.
			var cap: String = it["caption"]
			if cap == "":
				continue
			var cw := font.get_string_size(cap, HORIZONTAL_ALIGNMENT_LEFT, -1, CAPTION_SIZE).x
			var at := Vector2(c.x - cw * 0.5, rect.position.y - 6.0)
			draw_string_outline(font, at, cap, HORIZONTAL_ALIGNMENT_LEFT, -1, CAPTION_SIZE, 5, Color(0, 0, 0, 0.85 * a))
			draw_string(font, at, cap, HORIZONTAL_ALIGNMENT_LEFT, -1, CAPTION_SIZE, Color(col, a))

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

## Off-screen attack arrows: orange = a strike (counter it), blue = a grab or charge (dodge it).
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
