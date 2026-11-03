extends Node3D
## Ribbon trails on limbs (Feel Reference: On the character > Trails). Owned
## by ScreenFX. Two kinds of channel:
## - sprint: both hands and both feet of the player while the speed level is
##   above Tuning.TRAIL_FROM. Strength and length ramp with the level (nothing is
##   on or off): Tuning.TRAIL_LENGTH m at most, from its minimum at TRAIL_FROM to
##   its maximum at full speed; every point fades over Tuning.TRAIL_FADE s.
## - strike: the striking limb of a charged attack (level 1+), from late in the
##   startup to the end of the active frames.
## - streak (Round 7): a limb during a glide, from now for the glide's time, at
##   a given strength (ScreenFX: both hands and feet, scaled by the distance).
## One colour for the brand: Tuning.TRAIL_COLOR. Each channel is an
## ImmediateMesh triangle strip in world space, rebuilt each rendered frame and
## turned to face the camera. Times are real seconds (the player keeps real
## time in slow motion). OWNER: agent F (FX & audio).

const SPRINT_BONES: Array[StringName] = [Bones.L_HAND, Bones.R_HAND, Bones.L_FOOT, Bones.R_FOOT]
const WIDTH_SPRINT := 0.075       ## m ribbon width at the head, full speed
const WIDTH_STRIKE := 0.11        ## m for a charged strike
const STRIKE_LENGTH := 1.2        ## m at most along a strike's arc
const SAMPLE_MIN := 0.008         ## m between samples (a still limb adds none)
const ALPHA := 0.85               ## head alpha at full strength
const STRIKE_FROM := 0.4          ## the strike trail starts this far through the startup
const STREAK_LENGTH := 1.6        ## m at most behind a gliding limb

class Channel:
	var fighter: Node3D
	var bone: StringName
	var strike := false
	var streak := false           ## a glide streak (timed like a strike)
	var start_at := 0.0           ## real s (strike: when emission begins)
	var until := -1.0             ## real s (strike: when emission ends)
	var strength := 0.0           ## current emission strength 0..1
	var max_len := 1.0
	var width := 0.07
	var pts := PackedVector3Array()
	var t := PackedFloat32Array()     ## real time of each point
	var a := PackedFloat32Array()     ## emission strength of each point
	var mi: MeshInstance3D
	var mesh: ImmediateMesh

var _mat: StandardMaterial3D
var _channels: Array[Channel] = []
var _now := 0.0

func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.vertex_color_use_as_albedo = true
	_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_mat.disable_receive_shadows = true

## Advance by real seconds. `level` is the player's speed level (0..1);
## `scale` the upgraded-cap intensity (ScreenFX.get_speed_scale(), 1 at 8 m/s).
func update(real_delta: float, player: Node3D, level: float, scale := 1.0) -> void:
	_now += real_delta
	_sync_sprint(player, level, scale)
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var eye := cam.global_position if cam != null else Vector3(0, 2, 6)
	var i := _channels.size() - 1
	while i >= 0:
		var ch := _channels[i]
		if not _step(ch, eye):
			_free(i)
		i -= 1

## Show a strike trail on `bone` of `fighter` from `start_in` s from now until
## `until_in` s from now (real time). Level 1..3 brightens it.
func strike(fighter: Node3D, bone: StringName, start_in: float, until_in: float, level: int) -> void:
	if not is_instance_valid(fighter):
		return
	for ch in _channels:  # restrike on the same limb: extend it
		if ch.strike and not ch.streak and ch.fighter == fighter and ch.bone == bone:
			ch.start_at = _now + start_in
			ch.until = _now + until_in
			ch.strength = clampf(0.65 + 0.12 * level, 0.0, 1.0)
			return
	var ch := _new_channel(fighter, bone, true)
	ch.start_at = _now + start_in
	ch.until = _now + until_in
	ch.strength = clampf(0.65 + 0.12 * level, 0.0, 1.0)
	ch.max_len = STRIKE_LENGTH
	ch.width = WIDTH_STRIKE

## A glide streak on `bone` of `fighter` from now for `duration` s (real time),
## at `strength` 0..1. Another streak on the same limb extends it.
func streak(fighter: Node3D, bone: StringName, duration: float, strength: float) -> void:
	if not is_instance_valid(fighter):
		return
	var ch: Channel = null
	for c in _channels:
		if c.streak and c.fighter == fighter and c.bone == bone:
			ch = c
	if ch == null:
		ch = _new_channel(fighter, bone, true)
		ch.streak = true
		ch.start_at = _now
	ch.until = _now + maxf(duration, 0.0)
	ch.strength = clampf(strength, 0.0, 1.0)
	ch.max_len = STREAK_LENGTH
	ch.width = WIDTH_SPRINT

## Live channels and their total points (tests, debug): {channels, points,
## sprint, strike (strike and streak channels), streak, length}.
func stats() -> Dictionary:
	var pts := 0
	var sprint := 0
	var strikes := 0
	var streaks := 0
	var longest := 0.0
	for ch in _channels:
		pts += ch.pts.size()
		if ch.strike:
			strikes += 1
			if ch.streak:
				streaks += 1
		else:
			sprint += 1
		longest = maxf(longest, _length(ch))
	return {"channels": _channels.size(), "points": pts, "sprint": sprint, "strike": strikes, "streak": streaks,
		"length": longest}

## Strength of the sprint trails now (tests): 0 below TRAIL_FROM.
func sprint_strength(level: float) -> float:
	return clampf((level - Tuning.TRAIL_FROM) / maxf(1.0 - Tuning.TRAIL_FROM, 0.01), 0.0, 1.0)

## Trail length cap for a speed level; longer at upgraded caps (`scale`).
func sprint_length(level: float, scale := 1.0) -> float:
	return lerpf(Tuning.TRAIL_LENGTH.x, Tuning.TRAIL_LENGTH.y, sprint_strength(level)) * scale

func clear() -> void:
	for i in range(_channels.size() - 1, -1, -1):
		_free(i)

# --- Internals -----------------------------------------------------------------------

func _sync_sprint(player: Node3D, level: float, scale: float) -> void:
	var k := sprint_strength(level)
	for b in SPRINT_BONES:
		var ch := _find(player, b, false)
		if ch == null:
			if k <= 0.0 or not is_instance_valid(player):
				continue
			ch = _new_channel(player, b, false)
		ch.strength = k
		ch.max_len = sprint_length(level, scale)
		ch.width = WIDTH_SPRINT * lerpf(0.6, 1.0, k)
	# Channels of a previous player (respawn) only fade out.
	for ch in _channels:
		if not ch.strike and ch.fighter != player:
			ch.strength = 0.0

## Sample, age, trim and rebuild one channel. false = it is empty and done.
func _step(ch: Channel, eye: Vector3) -> bool:
	var alive := is_instance_valid(ch.fighter) and ch.fighter.is_inside_tree()
	var emitting := alive and ch.strength > 0.0
	if ch.strike:
		emitting = alive and _now >= ch.start_at and _now <= ch.until
	if emitting:
		var p := _bone_pos(ch.fighter, ch.bone)
		if ch.pts.is_empty() or ch.pts[ch.pts.size() - 1].distance_to(p) >= SAMPLE_MIN:
			ch.pts.append(p)
			ch.t.append(_now)
			ch.a.append(ch.strength)
	# Age out.
	var drop := 0
	while drop < ch.pts.size() and _now - ch.t[drop] > Tuning.TRAIL_FADE:
		drop += 1
	# Length cap: keep the newest max_len metres.
	var acc := 0.0
	var k := ch.pts.size() - 1
	while k > drop:
		acc += ch.pts[k].distance_to(ch.pts[k - 1])
		if acc > ch.max_len:
			break
		k -= 1
	drop = maxi(drop, k if acc > ch.max_len else drop)
	if drop > 0:
		ch.pts = ch.pts.slice(drop)
		ch.t = ch.t.slice(drop)
		ch.a = ch.a.slice(drop)
	_rebuild(ch, eye)
	if ch.pts.is_empty():
		return emitting or (ch.strike and _now < ch.until)
	return true

func _rebuild(ch: Channel, eye: Vector3) -> void:
	ch.mesh.clear_surfaces()
	var n := ch.pts.size()
	ch.mi.visible = n >= 2
	if n < 2:
		return
	var c := Tuning.TRAIL_COLOR
	ch.mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in n:
		var p := ch.pts[i]
		var tangent := ch.pts[mini(i + 1, n - 1)] - ch.pts[maxi(i - 1, 0)]
		var side := tangent.cross(eye - p)
		if side.length_squared() < 1e-10:
			side = Vector3.UP.cross(tangent)
		side = side.normalized()
		var age := clampf((_now - ch.t[i]) / Tuning.TRAIL_FADE, 0.0, 1.0)
		var along := float(i) / float(n - 1)          # 0 tail .. 1 head
		var fade := (1.0 - age) * (1.0 - age) * smoothstep(0.0, 0.35, along)
		var w := ch.width * 0.5 * (0.25 + 0.75 * along) * (1.0 - 0.5 * age)
		ch.mesh.surface_set_color(Color(c.r, c.g, c.b, ALPHA * ch.a[i] * fade))
		ch.mesh.surface_add_vertex(p + side * w)
		ch.mesh.surface_set_color(Color(c.r, c.g, c.b, ALPHA * ch.a[i] * fade))
		ch.mesh.surface_add_vertex(p - side * w)
	ch.mesh.surface_end()

func _new_channel(fighter: Node3D, bone: StringName, is_strike: bool) -> Channel:
	var ch := Channel.new()
	ch.fighter = fighter
	ch.bone = bone
	ch.strike = is_strike
	ch.mesh = ImmediateMesh.new()
	ch.mi = MeshInstance3D.new()
	ch.mi.name = "Trail_%s" % bone
	ch.mi.mesh = ch.mesh
	ch.mi.material_override = _mat
	ch.mi.layers = Layers.VIS_FX
	ch.mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ch.mi.top_level = true
	ch.mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	ch.mi.extra_cull_margin = 4.0
	ch.mi.visible = false
	add_child(ch.mi)
	ch.mi.global_transform = Transform3D.IDENTITY
	_channels.append(ch)
	return ch

func _free(i: int) -> void:
	var ch := _channels[i]
	if is_instance_valid(ch.mi):
		ch.mi.queue_free()
	_channels.remove_at(i)

func _find(fighter: Node3D, bone: StringName, is_strike: bool) -> Channel:
	for ch in _channels:
		if ch.strike == is_strike and ch.fighter == fighter and ch.bone == bone:
			return ch
	return null

func _length(ch: Channel) -> float:
	var acc := 0.0
	for i in range(1, ch.pts.size()):
		acc += ch.pts[i].distance_to(ch.pts[i - 1])
	return acc

## A limb's world position: the bone's mesh part centre (the fist, not the
## wrist), else the bone origin.
static func _bone_pos(f: Node3D, bone: StringName) -> Vector3:
	var rig = f.get(&"rig")
	if rig is Node3D and is_instance_valid(rig):
		if (rig as Node3D).has_method(&"get_bone_parts"):
			var parts: Array = rig.call(&"get_bone_parts", bone)
			for part in parts:
				if part is MeshInstance3D and is_instance_valid(part) and (part as MeshInstance3D).is_visible_in_tree():
					var mi := part as MeshInstance3D
					return mi.global_transform * mi.get_aabb().get_center()
		if (rig as Node3D).has_method(&"get_bone_global_position"):
			return rig.call(&"get_bone_global_position", bone)
	return f.global_position + Vector3.UP
