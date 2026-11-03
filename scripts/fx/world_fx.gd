extends Node
## Round 5 world and movement effects (Feel Reference: Movement spec signals,
## On the world, Landing has levels). A child of BloodFX ("WorldFX"); every
## effect listens to GameEvents:
## - sprint_started: a dust kick behind the feet.
## - footstep: on every sprint footstep a small puff sized by sprint_charge
##   (water spray on &"water", sparks on &"metal"); feet on water always ripple.
## - landing: soft = a small dust puff; hard = a dust ring Tuning.LAND_DUST_RING.x;
##   heavy = Tuning.LAND_DEBRIS small chunks via DebrisManager, a dust ring
##   LAND_DUST_RING.y and a vertical streak (Round 6: the floor crack itself
##   comes from floor_damaged). Water and metal floors
##   splash or spark instead of dust.
## - parkour: dust where the hands or feet push off; a wall kick-off throws chips.
## - wall_run_step: dust and small chips off the wall (Prototype 2, 39.9-49.9 s).
## - rammed (Battering Ram): dust where the bodies meet and a contact flash
##   that grows with the result (the god path's level-3 launch flashes biggest,
##   with a shock ring).
## - prop_broken: a burst by prop kind (brick dust, glass shards, wood chips).
## - foot_puff(), dust_ring() and debris() also serve FreeflowFX (Round 7: push
##   skids, drive steps, drive slams).
## - water_impact() (BloodFX body_impact on water): ripple rings and a splash.
## OWNER: agent F (FX & audio).

const RIPPLE_SHADER := preload("res://shaders/ripple.gdshader")
const STREAK_SHADER := preload("res://shaders/fx_streak.gdshader")

# --- Local tuning (candidates for Tuning) ---------------------------------------
const FOOT_POOL := 10
const RING_POOL := 4
const RIPPLE_POOL := 18
const STREAK_POOL := 3
const GLASS_POOL := 5
const FOOT_SIZE := Vector2(0.35, 1.0)   ## foot puff amount at sprint_charge 0 .. 1
const RING_STOP := 0.45          ## s for a landing's dust ring to reach its radius
const RING_LIFE := 1.1           ## s a dust ring's puffs live
const RIPPLE_TIME := 0.9         ## s for a ripple ring to spread and fade (world time)
const RIPPLE_FOOT := Vector2(0.45, 0.8)  ## m ring radius from a walking .. sprinting foot
const RIPPLE_BODY := Vector2(0.8, 1.8)   ## m from a light .. heavy body impact
const RIPPLE_GAP := 0.12         ## s between the concentric rings of one impact
const STREAK_HEIGHT := 3.2       ## m: the heavy landing's vertical streak
const STREAK_WIDTH := 0.38       ## m
const STREAK_TIME := 0.32        ## real s to fade
const DEBRIS_SIZE := Vector2(0.06, 0.14)  ## m heavy-landing chunk edge
const DEBRIS_SPEED := Vector2(1.5, 4.0)   ## m/s outward
const DEBRIS_LIFT := Vector2(2.0, 4.5)    ## m/s up
const WALL_DUST_ENERGY := 1500.0
const RING_DEDUPE := Vector2(1.0, 0.15)   ## m, s: one dust ring per spot and moment
const SLAM_FLASH := 0.75         ## body slam contact flash size (0..1)
const SPRINT_KICK_ENERGY := 1400.0
## Ram contact flash size (0..1 of BloodFX.IMPACT_FLASH_SIZE) by the victim's
## result; a launch also gets RAM_LAUNCH_BRIGHT and a shock ring (budgeted).
const RAM_FLASH := {&"flinch": 0.25, &"stumble": 0.3, &"knockdown": 0.55, &"launch": 0.9}
const RAM_LAUNCH_BRIGHT := 3.0
const RAM_DUST := {&"knockdown": 2400.0, &"launch": 3600.0}  ## dust energy (1800 otherwise)
const GLASS_COLOR := Color(0.82, 0.93, 1.0)
const METAL_DUST := Color(0.45, 0.46, 0.48)
const EXTRA_DUST := {&"dirt": Color(0.5, 0.42, 0.32), &"metal": Color(0.45, 0.46, 0.48)}

## Effects started since the last reset, by name (tests, end-of-wave logs).
var counts: Dictionary = {}
## Parameters of the most recent effect of each kind (tests): e.g. "dust_ring" -> radius.
var last: Dictionary = {}
var rng := RandomNumberGenerator.new()

var _fx: Node          ## BloodFX
var _holder: Node3D
var _foot: Array[GPUParticles3D] = []
var _foot_next := 0
var _rings: Array[GPUParticles3D] = []
var _ring_next := 0
var _glass: Array[GPUParticles3D] = []
var _glass_next := 0
var _ripples: Array[MeshInstance3D] = []
var _ripple_age := PackedFloat32Array()   ## s; < -100 idle, < 0 waiting (staggered start)
var _ripple_next := 0
var _streaks: Array[MeshInstance3D] = []
var _streak_age := PackedFloat32Array()   ## real s; < 0 idle
var _streak_next := 0
var _wall_color: Dictionary = {}          ## fighter id -> dust colour of the wall it runs on
var _last_ring_t := -INF
var _last_ring_at := Vector3.ZERO
var _last_ring_r := 0.0
var _debris_mesh: Array[BoxMesh] = []
var _debris_shape: Array[BoxShape3D] = []
var _debris_mat: Dictionary = {}          ## colour hash -> StandardMaterial3D

func setup(fx: Node, holder: Node3D) -> void:
	_fx = fx
	_holder = holder
	rng.randomize()
	_build()
	GameEvents.sprint_started.connect(_on_sprint_started)
	GameEvents.footstep.connect(_on_footstep)
	GameEvents.parkour.connect(_on_parkour)
	GameEvents.wall_run_started.connect(_on_wall_run_started)
	GameEvents.wall_run_step.connect(_on_wall_run_step)
	GameEvents.wall_run_ended.connect(_on_wall_run_ended)
	GameEvents.landing.connect(_on_landing)
	GameEvents.prop_broken.connect(_on_prop_broken)
	GameEvents.body_slammed.connect(_on_body_slammed)
	GameEvents.rammed.connect(_on_rammed)

func reset() -> void:
	counts.clear()
	last.clear()
	_wall_color.clear()
	for list in [_foot, _rings, _glass]:
		for e: GPUParticles3D in list:
			e.emitting = false
			e.visible = false
	for i in _ripples.size():
		_ripple_age[i] = -1000.0
		_ripples[i].visible = false
	for i in _streaks.size():
		_streak_age[i] = -1.0
		_streaks[i].visible = false

func _count(key: StringName) -> void:
	counts[key] = int(counts.get(key, 0)) + 1


# =============================================================================
# Public effects
# =============================================================================

## Dust colour for a floor or wall surface.
func surface_color(surface: StringName) -> Color:
	if EXTRA_DUST.has(surface):
		return EXTRA_DUST[surface]
	var table: Dictionary = _fx.get(&"DUST_BY_SURFACE")
	return table.get(surface, table[&"floor"])

## A small puff at a foot; `size` 0..1.
func foot_puff(position: Vector3, color: Color, size: float, direction := Vector3.UP) -> void:
	var e := _foot[_foot_next]
	_foot_next = (_foot_next + 1) % _foot.size()
	var pm := e.process_material as ParticleProcessMaterial
	var s := clampf(size, 0.0, 1.0)
	pm.color = color
	pm.initial_velocity_min = lerpf(0.3, 0.6, s)
	pm.initial_velocity_max = lerpf(0.8, 1.6, s)
	pm.scale_min = lerpf(0.3, 0.5, s)
	pm.scale_max = lerpf(0.6, 1.05, s)
	e.amount_ratio = lerpf(FOOT_SIZE.x, FOOT_SIZE.y, s)
	e.global_transform = Transform3D(_basis_toward(direction), position)
	e.visible = true
	e.restart()
	_count(&"foot_puff")
	last[&"foot_puff"] = s

## A ring of dust rolling out along the floor to `radius` m. One ring per spot:
## a second ring within RING_DEDUPE (m, s) of the last is skipped (a slam that
## also reports a heavy landing).
func dust_ring(position: Vector3, radius: float, color: Color) -> void:
	var now := Engine.get_physics_frames() / float(Engine.physics_ticks_per_second)
	if now - _last_ring_t < RING_DEDUPE.y and position.distance_to(_last_ring_at) < RING_DEDUPE.x \
			and radius <= _last_ring_r:
		return
	_last_ring_t = now
	_last_ring_at = position
	_last_ring_r = radius
	var e := _rings[_ring_next]
	_ring_next = (_ring_next + 1) % _rings.size()
	var pm := e.process_material as ParticleProcessMaterial
	# Constant deceleration: a puff launched at v stops after RING_STOP s, v^2 / 2d = radius.
	var v := 2.0 * radius / RING_STOP
	pm.initial_velocity_min = v * 0.85
	pm.initial_velocity_max = v
	pm.damping_min = v / RING_STOP
	pm.damping_max = v / RING_STOP
	pm.color = color
	pm.scale_min = lerpf(0.7, 1.0, radius / 3.0)
	pm.scale_max = lerpf(1.3, 1.9, radius / 3.0)
	e.amount_ratio = clampf(radius / 3.0, 0.45, 1.0)
	e.global_transform = Transform3D(Basis(), position + Vector3.UP * 0.08)
	e.visible = true
	e.restart()
	_count(&"dust_ring")
	last[&"dust_ring"] = radius

## Concentric ripple rings on water: `count` rings, the first `radius` m.
func ripple(position: Vector3, radius: float, count := 1, strength := 1.0) -> void:
	for k in count:
		var i := _ripple_next
		_ripple_next = (_ripple_next + 1) % _ripples.size()
		var r := radius * (1.0 - 0.18 * k)
		var q := _ripples[i]
		q.global_transform = Transform3D(Basis().scaled(Vector3(r, 1.0, r)), position + Vector3.UP * 0.02)
		q.set_instance_shader_parameter(&"strength", strength * (1.0 - 0.25 * k))
		q.set_instance_shader_parameter(&"age", 0.0)
		q.visible = k == 0
		_ripple_age[i] = -RIPPLE_GAP * k
		_count(&"ripple")
	last[&"ripple"] = radius

## A body (or anything heavy) hitting the water: rings and a splash.
func water_impact(position: Vector3, energy: float) -> void:
	var t := clampf(energy / 6000.0, 0.0, 1.0)
	ripple(position, lerpf(RIPPLE_BODY.x, RIPPLE_BODY.y, t), 3, lerpf(0.7, 1.0, t))
	_fx.call(&"splash", position + Vector3.UP * 0.05, Vector3.UP, lerpf(1500.0, 6000.0, t))
	_count(&"splash")

## A vertical streak standing on `position` (heavy landing).
func streak(position: Vector3) -> void:
	var i := _streak_next
	_streak_next = (_streak_next + 1) % _streaks.size()
	var q := _streaks[i]
	q.global_transform = Transform3D(Basis().scaled(Vector3(STREAK_WIDTH, STREAK_HEIGHT, 1.0)), position)
	q.set_instance_shader_parameter(&"fade", 1.0)
	q.visible = true
	_streak_age[i] = 0.0
	_count(&"streak")

## `count` small chunks thrown out of the floor, owned by DebrisManager (it
## caps and freezes them).
func debris(position: Vector3, count: int, color: Color) -> void:
	var parent: Node = get_tree().current_scene if get_tree().current_scene != null else _holder
	var dm := get_node_or_null(^"/root/DebrisManager")
	var mat := _chunk_mat(color)
	for k in count:
		var b := RigidBody3D.new()
		b.name = "LandingChunk"
		var j := rng.randi_range(0, _debris_mesh.size() - 1)
		var mi := MeshInstance3D.new()
		mi.mesh = _debris_mesh[j]
		mi.material_override = mat
		mi.layers = Layers.VIS_WORLD
		b.add_child(mi)
		var cs := CollisionShape3D.new()
		cs.shape = _debris_shape[j]
		b.add_child(cs)
		b.mass = 0.35
		b.set_meta(&"surface", &"concrete")
		b.collision_layer = Layers.DEBRIS_SMALL
		b.collision_mask = Layers.MASK_DEBRIS_SMALL
		var ang := TAU * (float(k) + rng.randf_range(-0.35, 0.35)) / count
		var out := Vector3(cos(ang), 0.0, sin(ang))
		parent.add_child(b)
		b.global_position = position + out * rng.randf_range(0.15, 0.45) + Vector3.UP * 0.12
		b.linear_velocity = out * rng.randf_range(DEBRIS_SPEED.x, DEBRIS_SPEED.y) \
				+ Vector3.UP * rng.randf_range(DEBRIS_LIFT.x, DEBRIS_LIFT.y)
		b.angular_velocity = Vector3(rng.randf_range(-10, 10), rng.randf_range(-10, 10), rng.randf_range(-10, 10))
		if dm != null and dm.has_method(&"register"):
			dm.call(&"register", b, true)
		else:
			get_tree().create_timer(Tuning.DEBRIS_FADE_AFTER).timeout.connect(b.queue_free)
		_count(&"debris")
	last[&"debris"] = count

## Glass shards bursting out (a thrown bottle).
func glass(position: Vector3, size := 1.0) -> void:
	var e := _glass[_glass_next]
	_glass_next = (_glass_next + 1) % _glass.size()
	e.amount_ratio = clampf(size, 0.2, 1.0)
	e.global_transform = Transform3D(Basis(), position)
	e.visible = true
	e.restart()
	_count(&"glass")


# =============================================================================
# Events
# =============================================================================

## Sprint start: a dust kick behind the feet (Prototype 2).
func _on_sprint_started(fighter: Node3D) -> void:
	if not is_instance_valid(fighter):
		return
	var feet := _feet(fighter)
	var fwd := _forward(fighter)
	var surface := _floor(feet)
	var c := surface_color(surface)
	var at := feet - fwd * 0.3 + Vector3.UP * 0.06
	var dir := (-fwd + Vector3.UP * 0.7).normalized()
	if surface == &"water":
		_fx.call(&"splash", at, dir, 2500.0)
		ripple(feet, RIPPLE_FOOT.y, 2)
	else:
		_fx.call(&"dust", at, c, SPRINT_KICK_ENERGY, dir, false)
		foot_puff(at, c, 1.0, dir)
	_count(&"sprint_kick")

## Sprint footsteps puff (sized by sprint_charge); water and metal react
## (Prototype 4 at 20.5 s); a foot in water always ripples.
func _on_footstep(fighter: Node3D, position: Vector3, surface: StringName, sprint_charge: float) -> void:
	var drive: Node = _fx.call(&"get_freeflow_fx")
	if drive != null and drive.call(&"is_driving", fighter):
		return  # Round 7: a driving holder's steps are FreeflowFX's drive dust
	var c := clampf(sprint_charge, 0.0, 1.0)
	var sprinting := c > 0.0 or _is_sprinting(fighter)
	var back := -_forward(fighter) if is_instance_valid(fighter) else Vector3.BACK
	match surface:
		&"water":
			ripple(position, lerpf(RIPPLE_FOOT.x, RIPPLE_FOOT.y, c), 1, lerpf(0.6, 1.0, c))
			if sprinting:
				_fx.call(&"splash", position + Vector3.UP * 0.05, (Vector3.UP + back * 0.6).normalized(),
						lerpf(700.0, 2600.0, c))
				_count(&"splash")
		&"metal":
			if sprinting:
				_fx.call(&"spark", position + Vector3.UP * 0.03, (Vector3.UP + back * 0.5).normalized(),
						lerpf(0.35, 0.8, c))
				foot_puff(position + Vector3.UP * 0.05, METAL_DUST, c * 0.5, (Vector3.UP + back).normalized())
				_count(&"sparks")
		_:
			if sprinting:
				foot_puff(position + Vector3.UP * 0.05, surface_color(surface), c,
						(Vector3.UP + back * 0.8).normalized())

## Automatic parkour: dust where the hands or feet push.
func _on_parkour(fighter: Node3D, kind: StringName, position: Vector3, height: float) -> void:
	var c := surface_color(_floor(position))
	match kind:
		&"step":
			foot_puff(position + Vector3.UP * 0.04, c, 0.3)
		&"vault", &"air_mantle":
			_fx.call(&"dust", position + Vector3.UP * 0.05, c, 900.0, Vector3.UP, false)
		&"mantle":
			_fx.call(&"dust", position + Vector3.UP * 0.05, c, 1200.0, Vector3.UP, true, 0.5)
		&"kickoff":
			var n := -_forward(fighter) if is_instance_valid(fighter) else Vector3.BACK
			_fx.call(&"dust", position, c, 1800.0, n, true, 0.7)
	_count(&"parkour")
	last[&"parkour"] = [kind, height]

func _on_wall_run_started(fighter: Node3D, wall: Node3D, _side: int) -> void:
	if not is_instance_valid(fighter):
		return
	var c: Color = _fx.call(&"_surface_color", wall)
	if is_instance_valid(wall) and wall.get(&"surface") == null:
		c = surface_color(FXRules.surface_of(wall))
	_wall_color[fighter.get_instance_id()] = c

## Each footstep on the wall kicks dust and small chips off it.
func _on_wall_run_step(fighter: Node3D, position: Vector3, normal: Vector3) -> void:
	var n := normal.normalized() if normal.length_squared() > 1e-6 else Vector3.UP
	var c: Color = _wall_color.get(fighter.get_instance_id(), surface_color(&"concrete")) \
			if is_instance_valid(fighter) else surface_color(&"concrete")
	_fx.call(&"dust", position + n * 0.05, c, WALL_DUST_ENERGY, (n + Vector3.UP * 0.3).normalized(), true, 0.55)
	_count(&"wall_dust")

func _on_wall_run_ended(fighter: Node3D, _reason: StringName) -> void:
	if is_instance_valid(fighter):
		_wall_color.erase(fighter.get_instance_id())

## Landing levels (Feel Reference: Landing has levels; Prototype 3 at 10.7 and 15.2 s).
func _on_landing(_fighter: Node3D, level: StringName, position: Vector3, vertical_speed: float) -> void:
	var surface := _floor(position)
	var c := surface_color(surface)
	var wet := surface == &"water"
	match level:
		&"heavy":
			if wet:
				ripple(position, RIPPLE_BODY.y, 3)
				_fx.call(&"splash", position + Vector3.UP * 0.05, Vector3.UP, 6000.0)
				_count(&"splash")
			else:
				# Round 6: the floor crack comes from WorldDamage's floor_damaged
				# (BloodFX.floor_mark), so a heavy landing never doubles it.
				debris(position, rng.randi_range(Tuning.LAND_DEBRIS.x, Tuning.LAND_DEBRIS.y), c.darkened(0.1))
				dust_ring(position, Tuning.LAND_DUST_RING.y, c)
				_fx.call(&"dust", position + Vector3.UP * 0.1, c, 4500.0, Vector3.UP, false)
			streak(position)
		&"hard":
			if wet:
				ripple(position, lerpf(RIPPLE_BODY.x, RIPPLE_BODY.y, 0.5), 2)
				_fx.call(&"splash", position + Vector3.UP * 0.05, Vector3.UP, 3500.0)
				_count(&"splash")
			else:
				dust_ring(position, Tuning.LAND_DUST_RING.x, c)
		_:
			if wet:
				ripple(position, RIPPLE_FOOT.y, 1)
				_fx.call(&"splash", position + Vector3.UP * 0.05, Vector3.UP, 1200.0)
				_count(&"splash")
			else:
				var size := clampf(vertical_speed / Tuning.LAND_HARD_SPEED, 0.4, 1.0)
				foot_puff(position + Vector3.UP * 0.05, c, size)
	if surface == &"metal" and level != &"soft":
		_fx.call(&"spark", position + Vector3.UP * 0.05, Vector3.UP, 1.0)
	last[&"landing"] = level

## Battering Ram (agent M): a dust puff where the bodies meet, kicked out
## along the runner's line, and a contact flash by the victim's result (the
## god path's level-3 launch: the biggest, brighter, with a shock ring).
func _on_rammed(runner: Node3D, victim: Node3D, result: StringName, _self_result: StringName) -> void:
	if not is_instance_valid(runner) or not is_instance_valid(victim):
		return
	var at := (runner.global_position + victim.global_position) * 0.5
	var dir := victim.global_position - runner.global_position
	dir.y = 0.0
	var c := surface_color(_floor(at))
	_fx.call(&"dust", at + Vector3.UP * 0.15, c, float(RAM_DUST.get(result, 1800.0)),
			(dir.normalized() if dir.length() > 0.01 else Vector3.UP) + Vector3.UP * 0.5, false)
	var launch := result == &"launch"
	var size: float = RAM_FLASH.get(result, RAM_FLASH[&"stumble"])
	var ring: bool = launch and _fx.call(&"_ring_allowed")
	_fx.call(&"impact_flash", at + Vector3.UP * 1.1, size, false, ring, RAM_LAUNCH_BRIGHT if launch else -1.0)
	_count(&"ram")
	last[&"ram"] = [result, size, ring]

## Body slam (Feel Reference: Actions while holding): the holder lands on the
## body. A contact flash (a shock ring if the budget allows), dust like a heavy
## landing; the heavy thud is AudioFX's.
func _on_body_slammed(_holder: Node3D, _victim: Node3D, position: Vector3) -> void:
	var surface := _floor(position)
	var c := surface_color(surface)
	_fx.call(&"impact_flash", position + Vector3.UP * 0.3, SLAM_FLASH, false, _fx.call(&"_ring_allowed"))
	if surface == &"water":
		water_impact(position, 6000.0)
	else:
		dust_ring(position, Tuning.LAND_DUST_RING.y, c)
		_fx.call(&"dust", position + Vector3.UP * 0.1, c, 4000.0, Vector3.UP, false)
	_count(&"slam")

## A thrown prop broke: a burst by kind.
func _on_prop_broken(_prop: Node3D, position: Vector3, kind: StringName) -> void:
	var table: Dictionary = _fx.get(&"DUST_BY_SURFACE")
	match kind:
		&"brick":
			_fx.call(&"dust", position, table[&"brick"], 2600.0, Vector3.UP, true, 0.9)
		&"bottle":
			glass(position)
			_fx.call(&"splash", position, Vector3.UP, 900.0)
		&"limb":
			if Tuning.gore != Tuning.Gore.OFF:
				_fx.call(&"spray", position, Vector3.UP, 1500.0)
				_fx.call(&"splat", position, Vector3.DOWN, 1500.0)
		_:  # chair leg, small crate, stick: wood
			_fx.call(&"dust", position, table[&"wood"], 1800.0, Vector3.UP, true, 0.75)
	_count(&"prop_burst")
	last[&"prop_burst"] = kind


# =============================================================================
# Frame update
# =============================================================================

func _process(delta: float) -> void:
	var real := delta / maxf(Engine.time_scale, 0.001)
	for i in _ripples.size():
		if _ripple_age[i] < -100.0:
			continue
		_ripple_age[i] += delta
		var q := _ripples[i]
		if _ripple_age[i] < 0.0:
			continue
		var u := _ripple_age[i] / RIPPLE_TIME
		if u >= 1.0:
			_ripple_age[i] = -1000.0
			q.visible = false
			continue
		q.visible = true
		q.set_instance_shader_parameter(&"age", u)
	for i in _streaks.size():
		if _streak_age[i] < 0.0:
			continue
		_streak_age[i] += real
		var u := _streak_age[i] / STREAK_TIME
		if u >= 1.0:
			_streak_age[i] = -1.0
			_streaks[i].visible = false
			continue
		var q := _streaks[i]
		q.set_instance_shader_parameter(&"fade", (1.0 - u) * (1.0 - u))
		var o := q.global_position
		q.global_transform = Transform3D(Basis().scaled(Vector3(STREAK_WIDTH * (1.0 - 0.6 * u), STREAK_HEIGHT, 1.0)), o)

## Ripple rings showing now (tests).
func active_ripples() -> int:
	var n := 0
	for a in _ripple_age:
		if a > -100.0:
			n += 1
	return n

## Streaks showing now (tests).
func active_streaks() -> int:
	var n := 0
	for a in _streak_age:
		if a >= 0.0:
			n += 1
	return n


# =============================================================================
# Helpers and startup
# =============================================================================

func _floor(position: Vector3) -> StringName:
	return FXRules.floor_surface(_holder.get_world_3d() if _holder != null and _holder.is_inside_tree() else null,
			position)

static func _feet(f: Node3D) -> Vector3:
	return f.call(&"get_ground_position") if f.has_method(&"get_ground_position") else f.global_position

static func _forward(f: Node3D) -> Vector3:
	var v := Vector3.FORWARD
	if f.has_method(&"get_forward"):
		v = f.call(&"get_forward")
	else:
		v = -f.global_basis.z
	v.y = 0.0
	return v.normalized() if v.length_squared() > 1e-6 else Vector3.FORWARD

static func _is_sprinting(f: Node3D) -> bool:
	if not is_instance_valid(f):
		return false
	var tr = f.get(&"traversal")
	return tr != null and is_instance_valid(tr) and tr.has_method(&"is_sprinting") and tr.call(&"is_sprinting")

static func _basis_toward(dir: Vector3) -> Basis:
	var d := dir.normalized() if dir.length_squared() > 1e-6 else Vector3.UP
	var up := Vector3.UP if absf(d.y) < 0.95 else Vector3.FORWARD
	return Basis.looking_at(d, up)

func _chunk_mat(color: Color) -> StandardMaterial3D:
	var key := color.to_rgba32()
	if not _debris_mat.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.95
		_debris_mat[key] = m
	return _debris_mat[key]

func _build() -> void:
	var puff_tex: Texture2D = _fx.get(&"_puff_tex")
	# Foot puffs: small soft billboards.
	var puff_mesh := QuadMesh.new()
	puff_mesh.size = Vector2(0.35, 0.35)
	var puff_mat := StandardMaterial3D.new()
	puff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	puff_mat.vertex_color_use_as_albedo = true
	puff_mat.albedo_texture = puff_tex
	puff_mesh.material = puff_mat
	var grow := _curve([Vector2(0.0, 0.5), Vector2(0.4, 1.0), Vector2(1.0, 1.4)])
	var alpha := GradientTexture1D.new()
	alpha.gradient = Gradient.new()
	alpha.gradient.set_color(0, Color(1, 1, 1, 0.0))
	alpha.gradient.set_color(1, Color(1, 1, 1, 0.0))
	alpha.gradient.add_point(0.1, Color(1, 1, 1, 0.7))
	alpha.gradient.add_point(0.55, Color(1, 1, 1, 0.35))
	for i in FOOT_POOL:
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(0, 0, -1)
		pm.spread = 55.0
		pm.gravity = Vector3(0, 0.2, 0)
		pm.damping_min = 2.0
		pm.damping_max = 3.0
		pm.scale_curve = grow
		pm.color_ramp = alpha
		pm.angle_min = 0.0
		pm.angle_max = 360.0
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		pm.emission_sphere_radius = 0.08
		_foot.append(_emitter(puff_mesh, pm, 10, 0.7, 0.95))
	# Dust rings: puffs rolling out flat along the floor, decelerating.
	var ring_mesh := QuadMesh.new()
	ring_mesh.size = Vector2(0.6, 0.6)
	ring_mesh.material = puff_mat
	var ring_grow := _curve([Vector2(0.0, 0.6), Vector2(0.4, 1.2), Vector2(1.0, 1.8)])
	for i in RING_POOL:
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(1, 0, 0)
		pm.spread = 180.0
		pm.flatness = 1.0
		pm.gravity = Vector3(0, 0.35, 0)
		pm.scale_curve = ring_grow
		pm.color_ramp = alpha
		pm.angle_min = 0.0
		pm.angle_max = 360.0
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
		pm.emission_ring_axis = Vector3.UP
		pm.emission_ring_radius = 0.25
		pm.emission_ring_inner_radius = 0.1
		pm.emission_ring_height = 0.05
		_rings.append(_emitter(ring_mesh, pm, 48, RING_LIFE, 1.0))
	# Glass shards: thin bright flakes that tumble and bounce.
	var shard := BoxMesh.new()
	shard.size = Vector3(0.035, 0.004, 0.025)
	var shard_mat := StandardMaterial3D.new()
	shard_mat.albedo_color = GLASS_COLOR
	shard_mat.metallic_specular = 1.0
	shard_mat.roughness = 0.05
	shard_mat.emission_enabled = true
	shard_mat.emission = GLASS_COLOR * 0.35
	shard.material = shard_mat
	for i in GLASS_POOL:
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(0, 1, 0)
		pm.spread = 75.0
		pm.initial_velocity_min = 1.5
		pm.initial_velocity_max = 4.5
		pm.gravity = Vector3(0, -12.0, 0)
		pm.angular_velocity_min = -720.0
		pm.angular_velocity_max = 720.0
		pm.scale_min = 0.5
		pm.scale_max = 1.4
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		pm.emission_sphere_radius = 0.08
		pm.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
		pm.collision_bounce = 0.3
		pm.collision_friction = 0.5
		pm.collision_use_scale = true
		_glass.append(_emitter(shard, pm, 26, 1.6, 0.95))
	# Ripples: flat additive quads.
	var plane := PlaneMesh.new()
	plane.size = Vector2(2, 2)
	var rmat := ShaderMaterial.new()
	rmat.shader = RIPPLE_SHADER
	_ripple_age.resize(RIPPLE_POOL)
	_ripple_age.fill(-1000.0)
	for i in RIPPLE_POOL:
		_ripples.append(_quad(plane, rmat, "Ripple%d" % i))
	# Streaks: a quad standing on its bottom edge.
	var sq := QuadMesh.new()
	sq.size = Vector2(1, 1)
	sq.center_offset = Vector3(0, 0.5, 0)
	var smat := ShaderMaterial.new()
	smat.shader = STREAK_SHADER
	smat.set_shader_parameter(&"color", Tuning.TRAIL_COLOR)
	_streak_age.resize(STREAK_POOL)
	_streak_age.fill(-1.0)
	for i in STREAK_POOL:
		var q := _quad(sq, smat, "Streak%d" % i)
		q.extra_cull_margin = 4.0
		_streaks.append(q)
	# Landing chunks.
	for sz: Vector3 in [Vector3(0.1, 0.06, 0.08), Vector3(0.07, 0.05, 0.12), Vector3(0.13, 0.07, 0.09)]:
		var bm := BoxMesh.new()
		bm.size = sz
		_debris_mesh.append(bm)
		var bs := BoxShape3D.new()
		bs.size = sz * 0.9
		_debris_shape.append(bs)

func _emitter(mesh: Mesh, pm: ParticleProcessMaterial, amount: int, lifetime: float,
		explosiveness: float) -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.amount = amount
	e.lifetime = lifetime
	e.one_shot = true
	e.explosiveness = explosiveness
	e.randomness = 0.3
	e.emitting = false
	e.visible = false
	e.local_coords = false
	e.draw_pass_1 = mesh
	e.process_material = pm
	e.collision_base_size = 0.02
	e.visibility_aabb = AABB(Vector3(-6, -6, -6), Vector3(12, 12, 12))
	e.layers = Layers.VIS_FX
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	e.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_holder.add_child(e)
	return e

func _quad(mesh: Mesh, mat: Material, node_name: String) -> MeshInstance3D:
	var q := MeshInstance3D.new()
	q.name = node_name
	q.mesh = mesh
	q.material_override = mat
	q.layers = Layers.VIS_FX
	q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	q.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	q.visible = false
	_holder.add_child(q)
	return q

static func _curve(points: Array) -> CurveTexture:
	var c := Curve.new()
	var top := 1.0
	for p: Vector2 in points:
		top = maxf(top, p.y)
	c.max_value = top
	for p: Vector2 in points:
		c.add_point(p)
	var t := CurveTexture.new()
	t.curve = c
	return t
