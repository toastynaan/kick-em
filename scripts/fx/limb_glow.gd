extends Node3D
## Handle returned by BloodFX.limb_glow(): a glow on one bone of a fighter.
## Lights that bone's mesh parts through fighter.gdshader (glow, glow_color),
## and adds an additive halo drawn over geometry plus a small OmniLight3D, so a
## tell reads from the gameplay camera at 7 m. Rides the bone's
## BoneAttachment3D. Free it to stop; with duration > 0 it frees itself.
## Duration counts the fighter's own time: world time for enemies (a tell
## stretches with slow motion and Focus like the attack it announces), player
## time for the player (TimeDirector.player_delta).
## OWNER: agent F (blood & fx). Created only by BloodFX.

const POP_TIME := 0.08      ## s: the glow pops in brighter
const FADE_OUT := 0.1       ## s: fades out at the end of a timed glow
const PULSE_HZ := 6.0
const HALO_SIZE := 0.62     ## m at intensity 1 (reads at 7 m)
const LIGHT_ENERGY := 2.0   ## at intensity 1
const LIGHT_RANGE := 1.1    ## m
const PART_GLOW := 3.0      ## shader glow at intensity 1
const PULSE_TIME := 0.18    ## s: a charge level-up flares the glow (Round 5)
const PULSE_GAIN := 0.9     ## extra strength at the start of a pulse

var fighter: Node3D
var bone: StringName
var color := Color.WHITE
var duration := 0.0
var intensity := 1.0
var parts: Array[MeshInstance3D] = []
var age := 0.0

var _fx: Node          ## BloodFX (material lookup)
var _halo: MeshInstance3D
var _light: OmniLight3D
var _is_player := false
var _pulse_age := -1.0

func setup(fx: Node, p_fighter: Node3D, p_bone: StringName, p_parts: Array[MeshInstance3D],
		p_color: Color, p_duration: float, p_intensity: float, halo_mesh: Mesh,
		halo_material: Material) -> void:
	_fx = fx
	fighter = p_fighter
	bone = p_bone
	parts = p_parts
	color = p_color
	duration = p_duration
	intensity = maxf(p_intensity, 0.0)
	_is_player = is_instance_valid(p_fighter) and p_fighter.is_in_group(&"player")
	name = "LimbGlow_%s" % p_bone
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_halo = MeshInstance3D.new()
	_halo.name = "Halo"
	_halo.mesh = halo_mesh
	_halo.material_override = halo_material
	_halo.layers = Layers.VIS_FX
	_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_halo)
	_light = OmniLight3D.new()
	_light.name = "Light"
	_light.omni_range = LIGHT_RANGE
	_light.shadow_enabled = false
	_light.light_specular = 0.3
	add_child(_light)
	_apply(1.0)

## Change the colour while it glows (e.g. a charge reaching level 3).
func set_color(c: Color) -> void:
	color = c

## Change the strength while it glows (0 hides it without freeing).
func set_intensity(v: float) -> void:
	intensity = maxf(v, 0.0)

## A short flare (a charge reaching the next level).
func pulse() -> void:
	_pulse_age = 0.0

## Fade out over FADE_OUT s, then free (an abrupt queue_free also works).
func stop() -> void:
	duration = age + FADE_OUT

## 0..1 current strength (tests and debug).
func get_level() -> float:
	return _level()

func _process(delta: float) -> void:
	var dt := delta
	if _is_player:
		var td := get_node_or_null(^"/root/TimeDirector")
		if td != null:
			dt = td.call(&"player_delta", delta)
	age += dt
	if _pulse_age >= 0.0:
		_pulse_age += dt
		if _pulse_age >= PULSE_TIME:
			_pulse_age = -1.0
	if duration > 0.0 and age >= duration:
		queue_free()
		return
	_apply(_level())

func _level() -> float:
	var pop := 1.0 + 0.6 * clampf(1.0 - age / POP_TIME, 0.0, 1.0)
	var pulse := 0.85 + 0.15 * sin(age * TAU * PULSE_HZ)
	var fade := 1.0
	if duration > 0.0:
		fade = clampf((duration - age) / FADE_OUT, 0.0, 1.0)
	var flare := 1.0 + (PULSE_GAIN * (1.0 - _pulse_age / PULSE_TIME) if _pulse_age >= 0.0 else 0.0)
	return intensity * pop * pulse * fade * flare

func _apply(level: float) -> void:
	# A fighter faded for the camera takes its glow with it (no floating halo).
	if is_instance_valid(_fx) and is_instance_valid(fighter):
		level *= 1.0 - float(_fx.call(&"get_fighter_fade", fighter))
	var s := HALO_SIZE * (0.75 + 0.35 * minf(level, 2.0))
	_halo.scale = Vector3(s, s, s)
	_halo.set_instance_shader_parameter(&"tint", Color(color.r, color.g, color.b, clampf(level, 0.0, 2.0)))
	_halo.set_instance_shader_parameter(&"spin", age * 1.5)
	_light.light_color = color
	_light.light_energy = LIGHT_ENERGY * level
	for part in parts:
		if is_instance_valid(part):
			var mat: ShaderMaterial = _fx.call(&"_part_material", part)
			if mat != null:
				mat.set_shader_parameter(&"glow_color", color)
				mat.set_shader_parameter(&"glow", PART_GLOW * level)

func _exit_tree() -> void:
	for part in parts:
		if is_instance_valid(part):
			var mat: ShaderMaterial = _fx.call(&"_part_material", part) if is_instance_valid(_fx) else null
			if mat != null:
				mat.set_shader_parameter(&"glow", 0.0)
	if is_instance_valid(_fx):
		_fx.call(&"_on_glow_exit", self)
