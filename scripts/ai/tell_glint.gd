class_name TellGlint
extends MeshInstance3D
## Attack tell (Feel Reference: Enemies have to be readable first; Round 7:
## Defence > Counter). The attacking limb glows from the start of the wind-up
## until its first active frame, on every enemy attack: ORANGE when the player
## can Counter it, BLUE when only a dodge answers it: every tell kind other
## than &"strike" (grabs &"grab" on both hands, the heavy's shoulder charge
## &"charge" on the shoulder), and any move whose MoveData.counterable is
## false (UNCOUNTERABLE_FALLBACK while a move lacks the field). A stick
## enemy's stick glows with his hand. The glow is BloodFX.limb_glow on the move's strike bone
## (PoseLibrary.STRIKE_BONES), so where it glows also shows the height: fist
## at head height = HIGH, waist = MID, ankles = LOW. Until BloodFX.limb_glow
## returns a glow the old billboard star above the head is shown instead, so
## a tell never vanishes. Unshaded, drawn over everything, render layer
## Layers.VIS_FX. Spawned by AttackDirector on GameEvents.attack_tell.
## OWNER: agent C (AI).
##
## Timing: the glow starts on the physics tick the wind-up starts (resolved
## with a deferred call, flushed at the end of that tick) and stops on the
## attacker's CombatController.attack_active signal, its exact first active
## frame, whatever hitstop or slow motion did to the startup in between.
## Every enemy startup is at least AttackDirector.tell_min_frames(), so the
## glow is up Tuning.R7_TELL_MARGIN before the counter window opens. A closing
## ring shrinks onto the glow and meets it when the answer's window opens:
## Tuning.R7_COUNTER_WINDOW before the active frame on orange tells,
## Tuning.R7_DODGE_INVULN on blue ones (a dodge pressed then is still
## invulnerable on the active frame). Everything runs on scaled game time like
## the attack's startup, so in slow motion the tell, glow and ring all last
## longer in real time together (the windows are real time).

## The contract's tell colours (J's off-screen arrows use the same ones).
const STRIKE_COLOR := Tuning.TELL_COLOR_STRIKE  ## orange: Counter it
const GRAB_COLOR := Tuning.TELL_COLOR_GRAB      ## blue: uncounterable, dodge it
## Enemy moves the player cannot Counter while B's MoveData has no
## `counterable` field yet (the Round 7 doc: grabs and the heavy's shoulder charge).
const UNCOUNTERABLE_FALLBACK: Array[StringName] = [&"e_grab", &"e_grab_slam", &"e_charge"]
## BloodFX.limb_glow intensity per tell kind.
const GLOW_INTENSITY := {&"strike": 1.2, &"grab": 1.2, &"charge": 1.2}
## Glows are asked for this much longer than the tell and stopped on the
## active frame (a hitstop during the wind-up delays it).
const GLOW_SAFETY := 1.0
## Closing ring: scale at the tell's start and when it meets the star.
const RING_START_SCALE := 3.4
const RING_MEET_SCALE := 1.0
## Ring alpha on counterable (orange) and dodge-only (blue) tells.
const RING_ALPHA := {true: 0.35, false: 0.3}
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
## Bones never chosen as "the attacking limb" when the move lists a limb too.
const TRUNK: Array[StringName] = [&"Hips", &"Spine", &"Chest"]

static var _texture: ImageTexture
static var _ring_texture: ImageTexture

var attacker: Node3D
var kind: StringName = &"strike"
var duration := 0.5
## AttackDirector.world_now() / physics frame when the limb glow started (-1: not yet).
var glow_world_time := -1.0
var glow_frame := -1
## AttackDirector.world_now() when the glow stopped on the active frame (-1: not yet).
var active_world_time := -1.0

var _t := 0.0             ## Game seconds since the tell began.
var _end_at := INF        ## _t at which the closing flash started.
var _cancelled := false
var _seen_attacking := false
var _mat: StandardMaterial3D
var _color := STRIKE_COLOR
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _meet_t := 0.0        ## _t at which the ring meets the glow (the answer's window opens).
var _counterable := true  ## orange (Counter) or blue (dodge only)
var _glows: Array[Node3D] = []  ## BloodFX limb glows (empty: star fallback)
var _move_id: StringName = &""
var _resolved := false
var _weapon_lit := false
var _spawn_world := 0.0   ## AttackDirector.world_now() when the tell (wind-up) began
var _spawn_frame := 0

## Spawn a glint on `attacker` (replaces one already there).
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
## dark rim so the glint still reads against a bright sky.
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
	_spawn_world = AttackDirector.world_now()
	_spawn_frame = Engine.get_physics_frames()
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	layers = Layers.VIS_FX
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = Vector2(SIZE, SIZE)
	mesh = quad
	# The brain names the move it is starting (B emits attack_tell from inside
	# start_enemy_attack, so this runs before the move begins); _resolve_limb
	# looks again at the end of the tick.
	_move_id = _tell_move_of(attacker as Fighter)
	_set_counterable(is_counterable(_move_id, kind))
	_mat = _make_material(get_star_texture())
	material_override = _mat
	scale = Vector3.ONE * 0.2
	# The ring meets the glow when the answer's window opens. The tell runs on
	# scaled game time; the window is real time.
	_update_meet_time()
	_ring = MeshInstance3D.new()
	_ring.name = "Ring"
	_ring.top_level = true
	_ring.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_ring.layers = Layers.VIS_FX
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.mesh = quad
	_ring_mat = _make_material(get_ring_texture())
	_ring.material_override = _ring_mat
	add_child(_ring)
	var f := attacker as Fighter
	if f != null and f.combat != null:
		f.combat.attack_active.connect(_on_attack_active)
	_follow()
	# B emits attack_tell just before it begins the move, so the move id is
	# known by the end of this physics tick: resolve then (same tick).
	_resolve_limb.call_deferred()

## Tell colour of an enemy move: orange when the player can Counter it, blue
## when only a dodge answers it. `p_kind` is the attack_tell kind: only a
## &"strike" can be orange (a grab or a charge never is, even without a move id).
static func color_for(p_kind: StringName, move_id := &"") -> Color:
	return STRIKE_COLOR if is_counterable(move_id, p_kind) else GRAB_COLOR

## Round 7: can the player Counter this enemy move? Only a &"strike" tell
## kind can be (B: &"grab" for grabs, &"charge" for the shoulder charge), and
## then only when the move's MoveData.counterable is true (a move without the
## field falls back to UNCOUNTERABLE_FALLBACK).
static func is_counterable(move_id: StringName, p_kind := &"strike") -> bool:
	if p_kind != &"strike":
		return false
	if move_id == &"":
		return true
	if MoveLibrary.has_move(move_id):
		var m := MoveLibrary.get_move(move_id)
		if m != null and &"counterable" in m:
			return bool(m.get(&"counterable"))
		if m != null and m.tell_kind != &"strike":
			return false
	return not move_id in UNCOUNTERABLE_FALLBACK

## Orange (the player can Counter it) or blue (dodge only).
func is_counterable_tell() -> bool:
	return _counterable

func _set_counterable(on: bool) -> void:
	_counterable = on
	_color = STRIKE_COLOR if on else GRAB_COLOR

## The move a brain is starting this tick (&"" for hand-emitted tells).
static func _tell_move_of(f: Fighter) -> StringName:
	if f != null and f.brain != null and f.brain.has_method(&"get_tell_move"):
		return f.brain.get_tell_move()
	return &""

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

func _exit_tree() -> void:
	_stop_glows()
	var f := attacker as Fighter
	if f != null and is_instance_valid(f) and f.combat != null and f.combat.attack_active.is_connected(_on_attack_active):
		f.combat.attack_active.disconnect(_on_attack_active)

func _process(delta: float) -> void:
	if attacker == null or not is_instance_valid(attacker):
		queue_free()
		return
	_t += delta
	var now := _t
	var t := _t
	_update_meet_time()
	if not _cancelled and not is_finite(_end_at) and _attack_aborted():
		_cancelled = true
		_end_at = now
		_stop_glows()
	elif not is_finite(_end_at) and t >= duration and not _awaiting_active():
		_end_at = now
		_stop_glows()
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
		var ring_alpha: float = RING_ALPHA[_counterable] * alpha
		if t >= _meet_t and not _cancelled:
			ring_alpha = minf(ring_alpha * 1.6, 1.0)  # the window is open
		_ring.scale = Vector3.ONE * get_ring_scale()
		_ring_mat.albedo_color = Color(_color.r, _color.g, _color.b, ring_alpha)

## Still in the wind-up of a real attack (combat reports it): the glow waits
## for attack_active instead of the nominal duration.
func _awaiting_active() -> bool:
	var f := attacker as Fighter
	return f != null and f.combat != null and active_world_time < 0.0 \
		and f.combat.is_attacking() and not f.combat.is_attack_active() and not f.combat.is_in_recovery()

## The attack reached its first active frame: the glow ends here.
func _on_attack_active(_move: StringName) -> void:
	if active_world_time >= 0.0 or _cancelled:
		return
	active_world_time = AttackDirector.world_now()
	_stop_glows()
	if not is_finite(_end_at):
		_end_at = _t

## Ring scale now: shrinks linearly from RING_START_SCALE to RING_MEET_SCALE
## at the meet time, then stays on the glow.
func get_ring_scale() -> float:
	if _meet_t <= 0.0:
		return RING_MEET_SCALE
	return lerpf(RING_START_SCALE, RING_MEET_SCALE, clampf(_t / _meet_t, 0.0, 1.0))

## Game seconds after the tell's start at which the ring meets the glow
## (follows the current time scale).
func get_meet_time() -> float:
	_update_meet_time()
	return _meet_t

func get_ring() -> MeshInstance3D:
	return _ring

## True when the tell is a limb glow (BloodFX), false for the star fallback.
func is_limb_glow() -> bool:
	return not _glows.is_empty() or (glow_world_time >= 0.0 and mesh == null)

## Live BloodFX glow handles (tests).
func get_glows() -> Array[Node3D]:
	return _glows

## Strike bone(s) the glow sits on (empty until resolved).
func get_glow_bones() -> Array[StringName]:
	return glow_bones(_move_id, kind)

func get_move_id() -> StringName:
	return _move_id

## Where the ring sits: the (first) glowing limb, or the star.
func get_anchor_position() -> Vector3:
	for g in _glows:
		if is_instance_valid(g) and g.is_inside_tree():
			return g.global_position
	return global_position

## The bones that glow for an enemy move: both hands for a grab, else the
## attacking limb (fist or foot; the leading shoulder of a shoulder charge;
## the stick hand of a stick attack).
static func glow_bones(move_id: StringName, p_kind := &"strike") -> Array[StringName]:
	var out: Array[StringName] = []
	var bones: Array = PoseLibrary.STRIKE_BONES.get(move_id, [])
	var id := String(move_id)
	if p_kind == &"grab" or move_id in [&"e_grab", &"e_grab_slam"]:
		for b: StringName in bones:
			if String(b).ends_with("Hand"):
				out.append(b)
		if out.size() < 2:
			out.assign([&"LeftHand", &"RightHand"])
		return out
	for b: StringName in bones:
		if not b in TRUNK:
			out.append(b)
			return out
	if id.contains("kick") or id.contains("sweep"):
		out.append(&"RightFoot")
	elif id.contains("charge"):
		out.append(&"LeftUpperArm")
	elif id.contains("jab"):
		out.append(&"LeftHand")
	else:
		out.append(&"RightHand")
	return out

## Ask BloodFX for a glow on the attacking limb(s), on the tick the wind-up
## began. The move id comes from the brain (set just before it starts the
## attack) or from combat (B has begun the move by now). With no glow the
## star stays.
func _resolve_limb() -> void:
	if _resolved or not is_inside_tree():
		return
	_resolved = true
	var f := attacker as Fighter
	if f == null:
		return
	if _move_id == &"":
		_move_id = _tell_move_of(f)
	if _move_id == &"" and f.combat != null:
		_move_id = f.combat.current_move_id()
	# Colour and ring by the move now known (before this tick renders).
	_set_counterable(is_counterable(_move_id, kind))
	_update_meet_time()
	if _ring_mat != null:
		_ring_mat.albedo_color = Color(_color.r, _color.g, _color.b, RING_ALPHA[_counterable])
	if _attack_aborted() or active_world_time >= 0.0:
		return
	var remaining := maxf(duration - _t, 0.05) + GLOW_SAFETY
	var intensity: float = GLOW_INTENSITY.get(kind, 1.0)
	for bone in glow_bones(_move_id, kind):
		var g: Node3D = BloodFX.limb_glow(f, bone, _color, remaining, intensity)
		if g != null:
			_glows.append(g)
	if f.brain != null and f.brain.has_method(&"set_weapon_glow") and String(_move_id).begins_with("e_stick"):
		f.brain.set_weapon_glow(_color, true)
		_weapon_lit = true
	if not _glows.is_empty() or _weapon_lit:
		# Resolved in the tick the wind-up began (the deferred call flushes
		# before that frame renders): the glow starts with the wind-up.
		var same_tick := Engine.get_physics_frames() == _spawn_frame
		glow_world_time = _spawn_world if same_tick else AttackDirector.world_now()
		glow_frame = _spawn_frame if same_tick else Engine.get_physics_frames()
		mesh = null  # the limb glows instead of the star; the ring stays

func _stop_glows() -> void:
	for g in _glows:
		if is_instance_valid(g):
			if g.has_method(&"stop"):
				g.stop()
			else:
				g.queue_free()
	_glows.clear()
	if _weapon_lit:
		_weapon_lit = false
		var f := attacker as Fighter
		if f != null and is_instance_valid(f) and f.brain != null and f.brain.has_method(&"set_weapon_glow"):
			f.brain.set_weapon_glow(_color, false)

## The ring meets the glow when the answer's window opens: the counter window
## on orange tells, the dodge's invulnerability on blue ones. The tell runs on
## scaled game time and the window is real time, so the meet point is
## re-derived each frame (slow motion may start or end mid-tell).
func _update_meet_time() -> void:
	_meet_t = maxf(duration - answer_window(_counterable) * Engine.time_scale, 0.0)

## Real seconds before the active frame in which the player's answer works:
## Counter (orange) or dodge (blue).
static func answer_window(counterable: bool) -> float:
	return Tuning.R7_COUNTER_WINDOW if counterable else Tuning.R7_DODGE_INVULN

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
	return _seen_attacking and active_world_time < 0.0
