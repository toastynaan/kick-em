extends CanvasLayer
## Autoload "ScreenFX" (Round 5): full-screen effects that sell speed and power
## (Feel Reference: Screen effects, On the character): radial speed blur, speed
## lines, the Focus tint, the hit flash, limb trails and the teleport
## after-image. Effects read GameEvents and poll the player's Traversal;
## nobody calls this from gameplay code.
## OWNER: agent F (FX & audio).
##
## Rules from the doc: effect size follows ONE number (the hit tier for
## strikes, sprint_charge for movement) and nothing is on or off: blur, lines,
## trails and the tint all ramp.
## - Speed level = max(the player's Traversal.sprint_charge, a pulse from a
##   pursuit teleport or an air dash). Blur strength = level^2 x Tuning.BLUR_MAX
##   (0.15 at half charge, 0.6 at full), centred slightly above the middle.
##   Speed lines ramp in from Tuning.SPEED_LINES_FROM. Trails on both hands and
##   feet from Tuning.TRAIL_FROM (LimbTrails).
## - Hit flash: launch tier and up, white at Tuning.HIT_FLASH_ALPHA for
##   Tuning.HIT_FLASH_FRAMES rendered frames, at most one per Tuning.FX_FLASH_GAP.
## - Focus tint: while TimeDirector.is_focus_active() the world desaturates to
##   Tuning.FOCUS_SATURATION with a cool tint; the player and glowing limbs keep
##   full colour and the player gets a thin rim glow. Approach (chosen after
##   testing 4.8 on this machine): a stencil-masked full-screen pass. The
##   player's and glowing limbs' materials get a next_pass
##   (keep_color_mask.gdshader) that writes stencil 1 where they are visible;
##   a full-screen quad (focus_tint.gdshader) drawn first in the transparent
##   pass reads the screen texture and tints only where the stencil is not 1.
##   Why: it needs no change to world materials (another module's), costs one
##   full-screen pass plus the player's parts once more while Focus is on, keeps
##   additive FX (glow halos, flashes, trails, after-images) in full colour
##   because they draw after it, and the HUD (off-screen arrows) is a
##   CanvasLayer above the 3D view. A canvas-layer pass could not tell the
##   player's pixels from the world's, and per-material uniforms would need
##   every world material to cooperate.
## - Layer 5: above the 3D view, below the HUD (10) and menus (20), so the blur
##   and flash never touch the HUD.

const LimbTrailsScript := preload("res://scripts/fx/limb_trails.gd")
const SPEED_SHADER := preload("res://shaders/screen_speed.gdshader")
const TINT_SHADER := preload("res://shaders/focus_tint.gdshader")
const MASK_SHADER := preload("res://shaders/keep_color_mask.gdshader")
const GHOST_SHADER := preload("res://shaders/ghost.gdshader")

# --- Local tuning (candidates for Tuning) ---------------------------------------
const LAYER := 5
const BLUR_CENTER := Vector2(0.5, 0.45)   ## screen UV, y down: slightly above the middle
const PULSE_TIME := 0.3          ## s for a pursuit teleport's full-speed blur to fade
const AIR_DASH_SPEED := 8.5      ## m/s: airborne faster than this counts as an air dash (fallback)
const FOCUS_TINT := Color(0.82, 0.92, 1.12)
const FOCUS_DARKEN := 0.08
const FOCUS_RIM_COLOR := Color(0.45, 0.72, 1.0)
const FOCUS_RIM_GLOW := 0.9      ## fighter.gdshader rim_glow on the player at full Focus
const RIM_DEFAULT_COLOR := Color(0.75, 0.82, 1.0)  ## fighter.gdshader defaults
const RIM_DEFAULT_GLOW := 0.1
const AFTERIMAGE_POOL := 3
const MASK_PRIORITY := -100
const TINT_PRIORITY := -90
const PLAYER_POLL := 0.5         ## s between player lookups
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
var _pulse := 0.0                ## 0..1 speed pulse (pursuit teleport)
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
var _focus := 0.0
var _tint_quad: MeshInstance3D
var _tint_mat: ShaderMaterial
var _mask_mat: ShaderMaterial
var _kept: Dictionary = {}       ## material id -> ShaderMaterial carrying our mask
var _kept_nodes: Dictionary = {} ## node id -> GeometryInstance3D carrying our mask as material_overlay
var _rim_on := false
var _ghost_mat: ShaderMaterial
var _ghosts: Array[Node3D] = []
var _ghost_age := PackedFloat32Array()
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
	_build_tint()
	_build_ghosts()
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.teleported.connect(_on_teleported)
	GameEvents.strike_started.connect(_on_strike_started)
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
## teleport, air dash) when that is higher. AudioFX's wind loop reads it too.
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

## 0..1 how far the Focus tint has faded in.
func get_focus_amount() -> float:
	return _focus

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

## Materials currently keeping full colour through the Focus tint (tests).
func kept_materials() -> Array:
	var out: Array = []
	for id: int in _kept:
		var m = _kept[id]
		if is_instance_valid(m):
			out.append(m)
	return out

## Geometry keeping full colour through its material_overlay (group
## &"focus_keep_color", e.g. a stick enemy's glowing stick) (tests).
func kept_nodes() -> Array:
	var out: Array = []
	for id: int in _kept_nodes:
		var g = _kept_nodes[id]
		if is_instance_valid(g):
			out.append(g)
	return out

## Full-speed look for `seconds`, fading out: pursuit teleports and air dashes.
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
	_focus = 0.0
	_apply_focus()


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
	_update_focus(real)
	# The after-image fades in world time: it lingers through the teleport's
	# 0.3x slow motion, so the attack visibly passes through where you were.
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
func _on_hit_landed(info: HitInfo) -> void:
	if info == null or info.kind == &"grab":
		return
	if FXRules.tier_of(info) >= HitInfo.Tier.LAUNCH:
		flash()

## Teleport: after-image at the vanish point; a pursuit teleport also gets the
## full-speed blur.
func _on_teleported(fighter: Node3D, from: Vector3, _to: Vector3, kind: StringName) -> void:
	afterimage(fighter, from)
	if kind == &"pursuit":
		pulse_speed(1.0)

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
# Focus tint
# =============================================================================

func _build_tint() -> void:
	_mask_mat = ShaderMaterial.new()
	_mask_mat.shader = MASK_SHADER
	_mask_mat.render_priority = MASK_PRIORITY
	_tint_mat = ShaderMaterial.new()
	_tint_mat.shader = TINT_SHADER
	_tint_mat.render_priority = TINT_PRIORITY
	_tint_mat.set_shader_parameter(&"saturation", Tuning.FOCUS_SATURATION)
	_tint_mat.set_shader_parameter(&"tint", FOCUS_TINT)
	_tint_mat.set_shader_parameter(&"darken", FOCUS_DARKEN)
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)
	_tint_quad = MeshInstance3D.new()
	_tint_quad.name = "FocusTint"
	_tint_quad.mesh = quad
	_tint_quad.material_override = _tint_mat
	_tint_quad.layers = Layers.VIS_FX
	_tint_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_tint_quad.extra_cull_margin = 16384.0
	_tint_quad.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_tint_quad.visible = false
	add_child(_tint_quad)

func _update_focus(real: float) -> void:
	var td := get_node_or_null(^"/root/TimeDirector")
	var on: bool = td != null and td.has_method(&"is_focus_active") and td.call(&"is_focus_active")
	var goal := 1.0 if on else 0.0
	if is_equal_approx(_focus, goal):
		if on:
			_keep_colors(true)  # glows come and go while Focus is on
		elif _rim_on or not _kept.is_empty() or not _kept_nodes.is_empty():
			_apply_focus()  # finish the clean-up
		return
	_focus = move_toward(_focus, goal, real / maxf(Tuning.SLOWMO_EASE, 0.01))
	_apply_focus()

func _apply_focus() -> void:
	var a := smoothstep(0.0, 1.0, _focus)
	var on := _focus > 0.001
	_tint_quad.visible = on
	if on:
		var cam := get_viewport().get_camera_3d()
		if cam != null:  # keep the quad's node near the camera (never culled)
			_tint_quad.global_position = cam.global_position
		_tint_mat.set_shader_parameter(&"amount", a)
	_keep_colors(on)
	_set_player_rim(a if on else 0.0)

## Materials that keep full colour: the player's parts and the parts of every
## live limb glow (enemy wind-up tells, charge glows). Glows are never dimmed.
func _keep_colors(on: bool) -> void:
	var want: Dictionary = {}
	if on:
		for m in _player_materials():
			want[m.get_instance_id()] = m
		var bfx := get_node_or_null(^"/root/BloodFX")
		if bfx != null:
			for g in bfx.get(&"_glows"):
				if not is_instance_valid(g):
					continue
				for part in g.get(&"parts"):
					if is_instance_valid(part):
						var m: ShaderMaterial = bfx.call(&"_part_material", part)
						if m != null:
							want[m.get_instance_id()] = m
	for id: int in _kept.keys():
		if not want.has(id):
			var m = _kept[id]
			if is_instance_valid(m) and (m as Material).next_pass == _mask_mat:
				(m as Material).next_pass = null
			_kept.erase(id)
	for id: int in want:
		if _kept.has(id):
			continue
		var m: ShaderMaterial = want[id]
		if m.next_pass == null:
			m.next_pass = _mask_mat
			_kept[id] = m
	_keep_group(on)

## Any GeometryInstance3D in group &"focus_keep_color" (or under a node in it)
## keeps full colour: other modules' glows that are not limb glows (the stick
## enemy's stick, AIBrain's own material). The mask goes on as the node's
## material_overlay, so their materials (maybe shared) are never touched.
## Checked every frame while Focus is on: nodes that join mid-Focus are kept.
func _keep_group(on: bool) -> void:
	var want: Dictionary = {}
	if on:
		for n in get_tree().get_nodes_in_group(&"focus_keep_color"):
			if n is GeometryInstance3D:
				want[n.get_instance_id()] = n
			else:
				for g in n.find_children("*", "GeometryInstance3D", true, false):
					want[g.get_instance_id()] = g
	for id: int in _kept_nodes.keys():
		if not want.has(id):
			var g = _kept_nodes[id]
			if is_instance_valid(g) and (g as GeometryInstance3D).material_overlay == _mask_mat:
				(g as GeometryInstance3D).material_overlay = null
			_kept_nodes.erase(id)
	for id: int in want:
		if _kept_nodes.has(id):
			continue
		var g: GeometryInstance3D = want[id]
		if g.material_overlay == null:
			g.material_overlay = _mask_mat
			_kept_nodes[id] = g

## A thin cool rim glow on the player while Focus is on.
func _set_player_rim(a: float) -> void:
	if a <= 0.0 and not _rim_on:
		return
	for m in _player_materials():
		m.set_shader_parameter(&"rim_color", RIM_DEFAULT_COLOR.lerp(FOCUS_RIM_COLOR, a))
		m.set_shader_parameter(&"rim_glow", lerpf(RIM_DEFAULT_GLOW, FOCUS_RIM_GLOW, a))
	_rim_on = a > 0.0

func _player_materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	if not is_instance_valid(_player):
		return out
	var rig = _player.get(&"rig")
	var bfx := get_node_or_null(^"/root/BloodFX")
	if not (rig is Node3D) or not is_instance_valid(rig) or not (rig as Node3D).has_method(&"get_mesh_parts") \
			or bfx == null:
		return out
	for part in rig.call(&"get_mesh_parts"):
		if is_instance_valid(part):
			var m: ShaderMaterial = bfx.call(&"_part_material", part)
			if m != null:
				out.append(m)
	return out


# =============================================================================
# After-image (teleport)
# =============================================================================

func _build_ghosts() -> void:
	_ghost_mat = ShaderMaterial.new()
	_ghost_mat.shader = GHOST_SHADER
	_ghost_mat.set_shader_parameter(&"color", Tuning.TRAIL_COLOR)
	_ghost_age.resize(AFTERIMAGE_POOL)
	_ghost_age.fill(-1.0)
	for i in AFTERIMAGE_POOL:
		var g := Node3D.new()
		g.name = "AfterImage%d" % i
		g.top_level = true
		g.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		g.visible = false
		add_child(g)
		_ghosts.append(g)

## A copy of `fighter`'s mesh at `at` (its pose right now, moved there) that
## fades over Tuning.AFTERIMAGE_FADE seconds of world time. Returns the copy's node.
func afterimage(fighter: Node3D, at: Vector3) -> Node3D:
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
	return g

func _update_ghosts(world_delta: float) -> void:
	for i in _ghosts.size():
		if _ghost_age[i] < 0.0:
			continue
		_ghost_age[i] += world_delta
		var u := _ghost_age[i] / maxf(Tuning.AFTERIMAGE_FADE, 0.01)
		if u >= 1.0:
			_ghost_age[i] = -1.0
			_ghosts[i].visible = false
			continue
		var f := (1.0 - u) * (1.0 - u)
		for c in _ghosts[i].get_children():
			if (c as Node3D).visible:
				(c as MeshInstance3D).set_instance_shader_parameter(&"fade", f)
