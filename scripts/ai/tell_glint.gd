class_name TellGlint
extends MeshInstance3D
## Attack tell (spec: Enemies and AI, rule 5; Upgrade 2 U3 limb-glow tells).
## The attacking fist or foot glows (BloodFX.limb_glow on the move's strike
## bone from PoseLibrary.STRIKE_BONES), so where it glows shows the height:
## fist at head height = HIGH, fist or foot at the waist = MID, foot at the
## ankles = LOW (MoveData.hit_level). Colours: white strike (answer: Block,
## crouch a high, jump a low), red grab (Grab, or duck it), blue teleport
## counter (kind &"counter"). Until BloodFX.limb_glow exists (returns null)
## the old billboard star above the head is shown instead, so a tell never
## vanishes. Unshaded, drawn over everything, render layer Layers.VIS_FX.
## Spawned by AttackDirector on GameEvents.attack_tell. OWNER: agent C (AI).
##
## A closing ring shrinks onto the glow (or star) and meets it exactly when
## the perfect dodge window opens (active frame - Tuning.PERFECT_DODGE_WINDOW),
## so the player can time the dodge. Subtle on strikes, strong on counters,
## none on grabs (grabs are answered with Grab, not a dodge). Everything runs
## on scaled game time like the attack's startup, so in Focus (world at 0.3x)
## the tell, glow and ring all last 3.3x longer in real time together.

const STRIKE_COLOR := Color(1.0, 1.0, 1.0)
const GRAB_COLOR := Color(1.0, 0.13, 0.08)
const COUNTER_COLOR := Color(0.25, 0.6, 1.0)
## Frames to wait for combat to report the move id before the star fallback.
const LIMB_RESOLVE_TRIES := 3
## BloodFX.limb_glow intensity per tell kind.
const GLOW_INTENSITY := {&"strike": 1.0, &"grab": 1.0, &"counter": 1.4}
## Closing ring: scale at the tell's start and when it meets the star.
const RING_START_SCALE := 3.4
const RING_MEET_SCALE := 1.0
const RING_ALPHA := {&"strike": 0.35, &"counter": 0.8}
## Ring circle radius as a fraction of the quad's half size.
const RING_RADIUS := 0.82
## Quad size in metres at scale 1.
const SIZE := 0.62
## Metres above the head bone (or above the aim point + 0.45 without a rig).
const HEAD_OFFSET := 0.42
## Seconds of the opening pop and of the closing flash / fade. The glint runs
## on scaled game time, like the attack's startup, so it ends on the active
## frame in slow motion too.
const POP_TIME := 0.07
const FLASH_TIME := 0.12
## Pulses per second during the tell.
const PULSE_HZ := 7.0
const TEXTURE_SIZE := 128

static var _texture: ImageTexture
static var _ring_texture: ImageTexture

var attacker: Node3D
var kind: StringName = &"strike"
var duration := 0.5

var _t := 0.0             ## Game seconds since the tell began.
var _end_at := INF        ## _t at which the closing flash started.
var _cancelled := false
var _seen_attacking := false
var _mat: StandardMaterial3D
var _color := STRIKE_COLOR
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _meet_t := 0.0        ## _t at which the ring meets the star (dodge window opens).
var _glows: Array[Node3D] = []  ## BloodFX limb glows (empty: star fallback)
var _move_id: StringName = &""
var _resolve_tries := 0

## Spawn a glint above `attacker` (replaces one already there).
static func spawn(p_attacker: Node3D, p_kind: StringName, p_duration: float) -> TellGlint:
	if p_attacker == null or not is_instance_valid(p_attacker) or not p_attacker.is_inside_tree():
		return null
	for c in p_attacker.get_children():
		if c is TellGlint:
			(c as TellGlint)._stop_glows()
			c.queue_free()
	var g := TellGlint.new()
	g.name = "TellGlint"
	g.attacker = p_attacker
	g.kind = p_kind
	g.duration = maxf(p_duration, 0.05)
	p_attacker.add_child(g)
	return g

## Drop the cached texture (AttackDirector calls this on exit to avoid a leak warning).
static func clear_cache() -> void:
	_texture = null
	_ring_texture = null

static func get_ring_texture() -> ImageTexture:
	if _ring_texture == null:
		var n := TEXTURE_SIZE
		var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
		var half := (n - 1) * 0.5
		for py in n:
			for px in n:
				var r := Vector2((px - half) / half, (py - half) / half).length()
				var a := clampf(1.0 - absf(r - RING_RADIUS) / 0.06, 0.0, 1.0)
				img.set_pixel(px, py, Color(1, 1, 1, a * a))
		_ring_texture = ImageTexture.create_from_image(img)
	return _ring_texture

static func get_star_texture() -> ImageTexture:
	if _texture == null:
		_texture = ImageTexture.create_from_image(_make_star_image(TEXTURE_SIZE))
	return _texture

## A sharp 4-point star with thinner diagonal rays, a hot core and a faint
## dark rim so a white glint still reads against a bright sky.
static func _make_star_image(n: int) -> Image:
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var half := (n - 1) * 0.5
	for py in n:
		for px in n:
			var x := (px - half) / half
			var y := (py - half) / half
			var r := sqrt(x * x + y * y)
			var main_ray := _astroid(x, y, 1.0)
			var diag_ray := _astroid((x + y) * 0.7071, (x - y) * 0.7071, 0.55)
			var core := exp(-r * r * 30.0)
			var bright := clampf(maxf(main_ray, diag_ray * 0.85) * 1.6 + core, 0.0, 1.0)
			var rim := clampf(_astroid(x, y, 1.15) * 4.0, 0.0, 1.0) * clampf(1.2 - r, 0.0, 1.0)
			var alpha := clampf(maxf(bright, rim * 0.6), 0.0, 1.0)
			var lum := clampf(bright / maxf(alpha, 0.001), 0.0, 1.0)
			img.set_pixel(px, py, Color(lum, lum, lum, alpha))
	return img

## 1 at the centre, falling to 0 at the edge of an astroid star of `reach`.
static func _astroid(x: float, y: float, reach: float) -> float:
	var a := absf(x) / reach
	var b := absf(y) / reach
	var s := pow(sqrt(a) + sqrt(b), 2.0)
	return clampf(1.0 - s, 0.0, 1.0)

func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	layers = Layers.VIS_FX
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = Vector2(SIZE, SIZE)
	mesh = quad
	_color = color_for(kind)
	_mat = _make_material(get_star_texture())
	material_override = _mat
	scale = Vector3.ONE * 0.2
	# The ring meets the star when the perfect-dodge window opens. The tell
	# runs on scaled game time; the window is real time.
	_update_meet_time()
	if RING_ALPHA.has(kind):
		_ring = MeshInstance3D.new()
		_ring.name = "Ring"
		_ring.top_level = true
		_ring.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_ring.layers = Layers.VIS_FX
		_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ring.mesh = mesh
		_ring_mat = _make_material(get_ring_texture())
		_ring.material_override = _ring_mat
		add_child(_ring)
	_follow()

static func color_for(p_kind: StringName) -> Color:
	match p_kind:
		&"grab":
			return GRAB_COLOR
		&"counter":
			return COUNTER_COLOR
	return STRIKE_COLOR

func _make_material(tex: Texture2D) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	m.no_depth_test = true
	m.disable_receive_shadows = true
	m.disable_fog = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.billboard_keep_scale = true
	m.albedo_texture = tex
	m.albedo_color = _color
	m.render_priority = Material.RENDER_PRIORITY_MAX
	return m

func _process(delta: float) -> void:
	if attacker == null or not is_instance_valid(attacker):
		queue_free()
		return
	_t += delta
	var now := _t
	var t := _t
	if _resolve_tries < LIMB_RESOLVE_TRIES and _glows.is_empty():
		_resolve_limb()
	_update_meet_time()
	if not _cancelled and _attack_aborted():
		_cancelled = true
		_end_at = now
		_stop_glows()
	elif not is_finite(_end_at) and t >= duration:
		_end_at = now
	_follow()
	var s: float
	var alpha := 1.0
	if is_finite(_end_at):
		# Closing flash: a quick swell and fade (a cancel just fades).
		var e := (now - _end_at) / FLASH_TIME
		if e >= 1.0:
			queue_free()
			return
		s = lerpf(1.25, 0.6 if _cancelled else 1.7, e)
		alpha = 1.0 - e
	elif t < POP_TIME:
		s = lerpf(0.2, 1.25, t / POP_TIME)
	else:
		# Pulse, swelling toward the active frame.
		var p := clampf(t / duration, 0.0, 1.0)
		s = lerpf(0.95, 1.25, p) + 0.16 * sin(t * TAU * PULSE_HZ)
	scale = Vector3.ONE * maxf(s, 0.05)
	_mat.albedo_color = Color(_color.r, _color.g, _color.b, alpha)
	if _ring:
		_ring.global_position = get_anchor_position()
		var ring_alpha: float = RING_ALPHA[kind] * alpha
		if t >= _meet_t and not _cancelled:
			ring_alpha = minf(ring_alpha * 1.6, 1.0)  # the window is open
		_ring.scale = Vector3.ONE * get_ring_scale()
		_ring_mat.albedo_color = Color(_color.r, _color.g, _color.b, ring_alpha)

## Ring scale now: shrinks linearly from RING_START_SCALE to RING_MEET_SCALE
## at the meet time, then stays on the star.
func get_ring_scale() -> float:
	if _meet_t <= 0.0:
		return RING_MEET_SCALE
	return lerpf(RING_START_SCALE, RING_MEET_SCALE, clampf(_t / _meet_t, 0.0, 1.0))

## Game seconds after the tell's start at which the ring meets the star.
func get_meet_time() -> float:
	return _meet_t

func get_ring() -> MeshInstance3D:
	return _ring

## True when the tell is a limb glow (BloodFX), false for the star fallback.
func is_limb_glow() -> bool:
	return not _glows.is_empty()

## Strike bone(s) the glow sits on (empty until resolved).
func get_glow_bones() -> Array[StringName]:
	return glow_bones(_move_id, kind)

## Where the ring sits: the (first) glowing limb, or the star.
func get_anchor_position() -> Vector3:
	for g in _glows:
		if is_instance_valid(g) and g.is_inside_tree():
			return g.global_position
	return global_position

## The bones that glow for an enemy move: both hands for a grab, the strike
## bone (fist or foot) otherwise; the chest for a shoulder charge.
static func glow_bones(move_id: StringName, p_kind := &"strike") -> Array[StringName]:
	var out: Array[StringName] = []
	var bones: Array = PoseLibrary.STRIKE_BONES.get(move_id, [])
	if p_kind == &"grab" or move_id == &"e_grab":
		for b: StringName in bones:
			if String(b).ends_with("Hand"):
				out.append(b)
		if out.is_empty():
			out.append_array([&"LeftHand", &"RightHand"])
		return out
	if not bones.is_empty():
		out.append(bones[0])
	elif String(move_id).contains("kick") or String(move_id).contains("sweep"):
		out.append(&"RightFoot")
	else:
		out.append(&"RightHand")
	return out

## Ask BloodFX for a glow on the strike limb(s). The move id is known only
## once combat has begun the move (attack_tell fires just before), so this
## retries for a few frames. With no glow the star stays.
func _resolve_limb() -> void:
	_resolve_tries += 1
	var f := attacker as Fighter
	if f == null or f.combat == null:
		_resolve_tries = LIMB_RESOLVE_TRIES
		return
	_move_id = f.combat.current_move_id()
	if _move_id == &"" and _resolve_tries < LIMB_RESOLVE_TRIES:
		return
	var remaining := maxf(duration - _t, 0.05)
	var intensity: float = GLOW_INTENSITY.get(kind, 1.0)
	for bone in glow_bones(_move_id, kind):
		var g: Node3D = BloodFX.limb_glow(f, bone, _color, remaining, intensity)
		if g != null:
			_glows.append(g)
	_resolve_tries = LIMB_RESOLVE_TRIES
	if not _glows.is_empty():
		mesh = null  # the limb glows instead of the star; the ring stays

func _stop_glows() -> void:
	for g in _glows:
		if is_instance_valid(g):
			if g.has_method(&"stop"):
				g.stop()
			else:
				g.queue_free()
	_glows.clear()

## The ring meets the glow when the perfect-dodge window opens. The tell runs
## on scaled game time and the window is real time, so the meet point is
## re-derived each frame (Focus may start or end mid-tell).
func _update_meet_time() -> void:
	_meet_t = maxf(duration - Tuning.PERFECT_DODGE_WINDOW * Engine.time_scale, duration * 0.3)

func get_color() -> Color:
	return _color

func _follow() -> void:
	if attacker == null or not is_instance_valid(attacker):
		return
	global_position = _head_position()

func _head_position() -> Vector3:
	var f := attacker as Fighter
	if f and f.rig:
		var att := f.rig.get_attachment(&"Head")
		if att and att.is_inside_tree():
			return att.global_position + Vector3.UP * HEAD_OFFSET
	if f:
		return f.get_aim_point() + Vector3.UP * (0.45 + HEAD_OFFSET)
	return attacker.global_position + Vector3.UP * 2.2

## The attack the glint announces was cancelled (attacker hit, launched,
## dead). Combat counts only once it has reported the attack, so a glint
## emitted by hand (tests, stub combat) runs its full length.
func _attack_aborted() -> bool:
	var f := attacker as Fighter
	if f == null:
		return false
	if f.is_dead() or f.is_down():
		return true
	if f.combat == null:
		return false
	if f.combat.is_attacking():
		_seen_attacking = true
		return false
	return _seen_attacking
