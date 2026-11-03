extends CanvasLayer
## Autoload "ScreenFX" (Round 5): full-screen effects that sell speed and power
## (Feel Reference: Screen effects, On the character): radial speed blur, speed
## lines, the hit flash, limb trails and the teleport after-image. Effects read
## GameEvents and poll the player's Traversal; nobody calls this from gameplay
## code.
## OWNER: agent F (FX & audio).
##
## Rules from the doc: effect size follows ONE number (the hit tier for
## strikes, sprint_charge for movement) and nothing is on or off: blur, lines
## and trails all ramp.
## - Speed level = max(the player's Traversal.sprint_charge, a pulse from a
##   pursuit teleport, an air dash or a glide). Blur strength = level^2 x
##   Tuning.BLUR_MAX (0.15 at half charge, 0.6 at full), centred slightly above
##   the middle. Speed lines ramp in from
##   Tuning.SPEED_LINES_FROM. Trails on both hands and feet from
##   Tuning.TRAIL_FROM (LimbTrails).
## - Hit flash: launch tier and up, white at Tuning.HIT_FLASH_ALPHA for
##   Tuning.HIT_FLASH_FRAMES rendered frames, at most one per Tuning.FX_FLASH_GAP.
## - Round 7 (Freeflow combat): a player hit (HitInfo.react set) flashes the
##   screen from R7_FLASH_FROM weight (small, R7_FLASH_ALPHA by weight; a
##   launch payoff gets the full HIT_FLASH_ALPHA); a counter flashes it too. A
##   dodge leaves a short after-image where it started. A glide pulses the
##   speed blur and draws speed streaks on both hands and feet, both scaled by
##   the glide's distance. Focus mode and its tint are gone (Round 7); the god
##   path (amendment) keeps the teleport after-image, the pursuit teleport's
##   full blur and the air dash's.
## - Layer 5: above the 3D view, below the HUD (10) and menus (20), so the blur
##   and flash never touch the HUD.

const LimbTrailsScript := preload("res://scripts/fx/limb_trails.gd")
const SPEED_SHADER := preload("res://shaders/screen_speed.gdshader")
const GHOST_SHADER := preload("res://shaders/ghost.gdshader")

# --- Local tuning (candidates for Tuning) ---------------------------------------
const LAYER := 5
const BLUR_CENTER := Vector2(0.5, 0.45)   ## screen UV, y down: slightly above the middle
const PULSE_TIME := 0.3          ## s for a pursuit teleport's full-speed blur to fade
const AIR_DASH_SPEED := 8.5      ## m/s: airborne faster than this counts as an air dash (fallback)
const AFTERIMAGE_POOL := 3
const PLAYER_POLL := 0.5         ## s between player lookups
## Round 7. Screen flash for a player hit from this weight (doc: "a small
## screen flash for weight >= 0.7"), alpha from R7_FLASH_ALPHA.x there to .y
## at weight 1; a launch payoff flashes at Tuning.HIT_FLASH_ALPHA.
const R7_FLASH_FROM := 0.7
const R7_FLASH_ALPHA := Vector2(0.07, 0.12)
const COUNTER_FLASH_ALPHA := 0.1  ## the player's counter lands: a small white flash
const DODGE_AFTERIMAGE_FADE := 0.18  ## s (world time) the dodge's after-image takes to fade
## Glide: speed-level pulse from a short glide to FXRules.GLIDE_FULL (blur
## 0.12 .. 0.43, speed lines only on the longest glides), held for the glide's
## time (distance / Tuning.R7_GLIDE_SPEED) plus GLIDE_FADE; streak strength on
## both hands and feet over the same range.
const GLIDE_PULSE := Vector2(0.45, 0.85)
const GLIDE_STREAK := Vector2(0.45, 0.9)
const GLIDE_FADE := 0.12
const GLIDE_BONES: Array[StringName] = [Bones.L_HAND, Bones.R_HAND, Bones.L_FOOT, Bones.R_FOOT]
## Upgraded caps (Feel Reference: Sprint that builds, "10, then 12 m/s: same
## signals, stronger"; lead decision): sprint_charge is relative to the cap, so
## the effects scale by k = 1 + UPGRADE_GAIN x (cap - base cap) / UPGRADE_SPAN
## (1 at 8 m/s, 1.25 at 10, 1.5 at 12): blur strength (at most BLUR_CEILING),
## speed-line density, the trail length cap and the wind's ceiling.
const UPGRADE_GAIN := 0.5
const UPGRADE_SPAN := 4.0
const BLUR_CEILING := 0.85

## Every hit flash shown: {frame (physics), alpha} (tests).
var flash_log: Array[Dictionary] = []

var _player: Node3D
var _player_poll := 0.0
var _charge := 0.0
var _pulse := 0.0                ## 0..1 speed pulse (pursuit teleport, glide)
var _pulse_rate := 0.0
var _level := 0.0
var _k := 1.0                    ## upgraded-cap intensity scale
var _blur := 0.0
var _lines := 0.0
var _time := 0.0
var _speed_rect: ColorRect
var _speed_mat: ShaderMaterial
var _flash_rect: ColorRect
var _flash_shown := -1           ## rendered frames shown (-1 idle)
var _last_flash := -INF          ## real s
var _trails: Node3D
var _ghost_mat: ShaderMaterial
var _ghosts: Array[Node3D] = []
var _ghost_age := PackedFloat32Array()
var _ghost_fade := PackedFloat32Array()  ## s each after-image takes to fade
var _ghost_next := 0


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_speed_mat = ShaderMaterial.new()
	_speed_mat.shader = SPEED_SHADER
	_speed_mat.set_shader_parameter(&"center", BLUR_CENTER)
	_speed_rect = _full_rect("SpeedBlur")
	_speed_rect.material = _speed_mat
	_flash_rect = _full_rect("HitFlash")
	_flash_rect.color = Color(1, 1, 1, 0)
	_trails = LimbTrailsScript.new()
	_trails.name = "LimbTrails"
	add_child(_trails)
	_build_ghosts()
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.teleported.connect(_on_teleported)
	GameEvents.strike_started.connect(_on_strike_started)
	GameEvents.countered.connect(_on_countered)
	GameEvents.dodged.connect(_on_dodged)
	GameEvents.glide_started.connect(_on_glide_started)
	GameEvents.round_started.connect(func(_m: StringName) -> void: reset())

func _full_rect(node_name: String) -> ColorRect:
	var r := ColorRect.new()
	r.name = node_name
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.visible = false
	add_child(r)
	return r


# =============================================================================
# Public API (tests, HUD debug)
# =============================================================================

## Current radial blur strength 0..BLUR_MAX (tests read it).
func get_blur_strength() -> float:
	return _blur

## 0..1 speed level the effects follow: sprint_charge, or a pulse (pursuit
## teleport, air dash, glide) when that is higher. AudioFX's wind loop reads it too.
func get_speed_level() -> float:
	return _level

## Upgraded-cap intensity scale k (1 at the base cap, 1.25 at 10 m/s, 1.5 at 12).
func get_speed_scale() -> float:
	return _k

## k for a sprint cap (m/s).
static func speed_scale_for(cap: float) -> float:
	return 1.0 + UPGRADE_GAIN * maxf(cap - Tuning.SPRINT_CAPS[0], 0.0) / UPGRADE_SPAN

## The player's Traversal.sprint_charge as last polled.
func get_sprint_charge() -> float:
	return _charge

## 0..1 speed-line amount.
func get_speed_lines() -> float:
	return _lines

## Alpha of the hit flash this frame (0 when not showing).
func get_flash_alpha() -> float:
	return _flash_rect.color.a if _flash_rect.visible else 0.0

## The limb-trail renderer (LimbTrails): stats(), sprint_strength(), sprint_length().
func get_trails() -> Node3D:
	return _trails

## After-images still fading.
func active_afterimages() -> int:
	var n := 0
	for a in _ghost_age:
		if a >= 0.0:
			n += 1
	return n

## A speed look at `level` that fades out over `seconds`: pursuit teleports
## (full speed), Round 7 glides.
func pulse_speed(level: float, seconds := PULSE_TIME) -> void:
	_pulse = maxf(_pulse, clampf(level, 0.0, 1.0))
	_pulse_rate = _pulse / maxf(seconds, 0.01)

## A white screen flash for Tuning.HIT_FLASH_FRAMES frames at `alpha`. Budget:
## one per Tuning.FX_FLASH_GAP real seconds. Returns false when refused.
func flash(alpha := Tuning.HIT_FLASH_ALPHA) -> bool:
	var now := _real_now()
	if now - _last_flash < Tuning.FX_FLASH_GAP - 1e-4:
		return false
	_last_flash = now
	_flash_rect.color = Color(1, 1, 1, alpha)
	_flash_rect.visible = true
	_flash_shown = 0
	flash_log.append({"frame": Engine.get_physics_frames(), "alpha": alpha})
	if flash_log.size() > 64:
		flash_log.pop_front()
	return true

## Clear every effect (round restart).
func reset() -> void:
	_pulse = 0.0
	_flash_shown = -1
	_flash_rect.visible = false
	_last_flash = -INF
	_trails.call(&"clear")
	for i in _ghosts.size():
		_ghost_age[i] = -1.0
		_ghosts[i].visible = false


# =============================================================================
# Frame update
# =============================================================================

func _process(delta: float) -> void:
	var real := delta / maxf(Engine.time_scale, 0.001)
	if get_tree().paused:
		real = 0.0
	_time += real
	_player_poll -= real
	if _player_poll <= 0.0 or not is_instance_valid(_player):
		_player_poll = PLAYER_POLL
		_player = FXRules.player(get_tree())
	_update_speed(real)
	_trails.call(&"update", real, _player, _level, _k)
	_update_flash()
	# The after-image fades in world time: in slow motion it lingers, so an
	# attack visibly passes through where the dodger was.
	_update_ghosts(0.0 if get_tree().paused else delta)

func _update_speed(real: float) -> void:
	_charge = FXRules.sprint_charge(_player)
	_pulse = maxf(_pulse - _pulse_rate * real, 0.0)
	var air := _air_dash_level()
	var dead: bool = is_instance_valid(_player) and _player.has_method(&"is_dead") and _player.call(&"is_dead")
	_level = 0.0 if dead else maxf(_charge, maxf(_pulse, air))
	_k = speed_scale_for(Power.speed_cap())
	_blur = minf(_level * _level * Tuning.BLUR_MAX * _k, BLUR_CEILING)
	_lines = clampf((_level - Tuning.SPEED_LINES_FROM) / maxf(1.0 - Tuning.SPEED_LINES_FROM, 0.01), 0.0, 1.0)
	var on := _blur > 0.002 or _lines > 0.0
	_speed_rect.visible = on
	if on:
		_speed_mat.set_shader_parameter(&"strength", _blur)
		_speed_mat.set_shader_parameter(&"lines", _lines)
		_speed_mat.set_shader_parameter(&"density", _k)
		_speed_mat.set_shader_parameter(&"time_s", _time)

## An air dash gets the same blur as a top-speed sprint (Prototype 3, 18.2 s).
## Traversal.is_air_dashing() when M provides it; else airborne faster than
## AIR_DASH_SPEED.
func _air_dash_level() -> float:
	if not is_instance_valid(_player):
		return 0.0
	var tr = _player.get(&"traversal")
	if tr == null or not is_instance_valid(tr):
		return 0.0
	if tr.has_method(&"is_air_dashing"):
		return 1.0 if tr.call(&"is_air_dashing") else 0.0
	if tr.has_method(&"is_airborne") and tr.call(&"is_airborne") and tr.has_method(&"get_speed"):
		var cap: float = tr.call(&"get_speed_cap") if tr.has_method(&"get_speed_cap") else 8.0
		var v: float = tr.call(&"get_speed")
		if v > AIR_DASH_SPEED:
			return clampf((v - Tuning.SPRINT_START_SPEED) / maxf(cap - Tuning.SPRINT_START_SPEED, 0.5), 0.0, 1.0)
	return 0.0

func _update_flash() -> void:
	if _flash_shown < 0:
		return
	if _flash_shown >= Tuning.HIT_FLASH_FRAMES:
		_flash_shown = -1
		_flash_rect.visible = false
		return
	_flash_shown += 1

static func _real_now() -> float:
	return Engine.get_physics_frames() / float(Engine.physics_ticks_per_second)


# =============================================================================
# Events
# =============================================================================

## Contact frame: a white screen flash on launch tier and up (budgeted).
## Round 7 player hits flash from R7_FLASH_FROM weight, small; a launch payoff
## at the full alpha.
func _on_hit_landed(info: HitInfo) -> void:
	if info == null or info.kind == &"grab" or FXRules.is_throw_release(info):
		return
	if FXRules.is_round7(info):
		if info.react == &"launch":
			flash()
			return
		var w := FXRules.weight_of(info)
		if w >= R7_FLASH_FROM - 1e-4:
			flash(lerpf(R7_FLASH_ALPHA.x, R7_FLASH_ALPHA.y, clampf((w - R7_FLASH_FROM) / (1.0 - R7_FLASH_FROM), 0.0, 1.0)))
		return
	if FXRules.tier_of(info) >= HitInfo.Tier.LAUNCH:
		flash()

## Teleport: after-image at the vanish point; a pursuit teleport also gets the
## full-speed blur.
func _on_teleported(fighter: Node3D, from: Vector3, _to: Vector3, kind: StringName) -> void:
	afterimage(fighter, from)
	if kind == &"pursuit":
		pulse_speed(1.0)

## The player's counter caught an attack: a small white flash (budgeted).
func _on_countered(defender: Node3D, _attacker: Node3D) -> void:
	if is_instance_valid(defender) and defender.is_in_group(&"player"):
		flash(COUNTER_FLASH_ALPHA)

## Dodge: a short after-image where the dodge started.
func _on_dodged(fighter: Node3D, _direction: Vector3) -> void:
	if is_instance_valid(fighter):
		afterimage(fighter, fighter.global_position, DODGE_AFTERIMAGE_FADE)

## Glide: speed streaks on both hands and feet for the glide's time, and (the
## player's) a speed-blur pulse, both bigger for a longer glide.
func _on_glide_started(fighter: Node3D, _target: Node3D, distance: float) -> void:
	if not is_instance_valid(fighter):
		return
	var t := FXRules.glide_share(distance)
	var time := clampf(distance / Tuning.R7_GLIDE_SPEED, 0.05, Tuning.R7_GLIDE_MAX_TIME)
	for b in GLIDE_BONES:
		_trails.call(&"streak", fighter, b, time, lerpf(GLIDE_STREAK.x, GLIDE_STREAK.y, t))
	if fighter.is_in_group(&"player"):
		pulse_speed(lerpf(GLIDE_PULSE.x, GLIDE_PULSE.y, t), time + GLIDE_FADE)

## Strike trails on the striking limb of any charged attack (level 1+), from
## late in the startup to the end of the active frames.
func _on_strike_started(attacker: Node3D, _target: Node3D, move_id: StringName, _sprint: bool,
		charge_level: int) -> void:
	if charge_level < 1 or not is_instance_valid(attacker):
		return
	var w := FXRules.strike_window(move_id)
	# Frame data is the fighter's own time: the player keeps real time; anyone
	# else runs in world time, stretched by slow motion.
	var k := 1.0 if attacker.is_in_group(&"player") else 1.0 / maxf(Engine.time_scale, 0.01)
	_trails.call(&"strike", attacker, FXRules.strike_limb(move_id), w.x * LimbTrailsScript.STRIKE_FROM * k,
			(w.x + w.y) * k + 0.02, charge_level)


# =============================================================================
# After-image (teleport; Round 7: the dodge)
# =============================================================================

func _build_ghosts() -> void:
	_ghost_mat = ShaderMaterial.new()
	_ghost_mat.shader = GHOST_SHADER
	_ghost_mat.set_shader_parameter(&"color", Tuning.TRAIL_COLOR)
	_ghost_age.resize(AFTERIMAGE_POOL)
	_ghost_age.fill(-1.0)
	_ghost_fade.resize(AFTERIMAGE_POOL)
	_ghost_fade.fill(Tuning.AFTERIMAGE_FADE)
	for i in AFTERIMAGE_POOL:
		var g := Node3D.new()
		g.name = "AfterImage%d" % i
		g.top_level = true
		g.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		g.visible = false
		add_child(g)
		_ghosts.append(g)

## A copy of `fighter`'s mesh at `at` (its pose right now, moved there) that
## fades over `fade` seconds of world time. Returns the copy's node.
func afterimage(fighter: Node3D, at: Vector3, fade := Tuning.AFTERIMAGE_FADE) -> Node3D:
	if not is_instance_valid(fighter):
		return null
	var rig = fighter.get(&"rig")
	if not (rig is Node3D) or not is_instance_valid(rig) or not (rig as Node3D).has_method(&"get_mesh_parts"):
		return null
	var parts: Array = rig.call(&"get_mesh_parts")
	var i := _ghost_next
	_ghost_next = (_ghost_next + 1) % AFTERIMAGE_POOL
	var g := _ghosts[i]
	var offset := at - fighter.global_position
	var used := 0
	for part in parts:
		var src := part as MeshInstance3D
		if src == null or not is_instance_valid(src) or not src.visible or src.mesh == null:
			continue
		var mi: MeshInstance3D
		if used < g.get_child_count():
			mi = g.get_child(used) as MeshInstance3D
		else:
			mi = MeshInstance3D.new()
			mi.material_override = _ghost_mat
			mi.layers = Layers.VIS_FX
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
			g.add_child(mi)
		mi.mesh = src.mesh
		mi.global_transform = src.global_transform.translated(offset)
		mi.visible = true
		mi.set_instance_shader_parameter(&"fade", 1.0)
		used += 1
	for k in range(used, g.get_child_count()):
		(g.get_child(k) as Node3D).visible = false
	g.visible = used > 0
	_ghost_age[i] = 0.0 if used > 0 else -1.0
	_ghost_fade[i] = maxf(fade, 0.01)
	return g

func _update_ghosts(world_delta: float) -> void:
	for i in _ghosts.size():
		if _ghost_age[i] < 0.0:
			continue
		_ghost_age[i] += world_delta
		var u := _ghost_age[i] / _ghost_fade[i]
		if u >= 1.0:
			_ghost_age[i] = -1.0
			_ghosts[i].visible = false
			continue
		var f := (1.0 - u) * (1.0 - u)
		for c in _ghosts[i].get_children():
			if (c as Node3D).visible:
				(c as MeshInstance3D).set_instance_shader_parameter(&"fade", f)
