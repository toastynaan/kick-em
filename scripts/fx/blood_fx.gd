extends Node
## Autoload "BloodFX" (spec: Blood). Sprays (pooled GPUParticles3D with
## particle colliders), wall/floor splat decals placed by raycasts, impact
## smears, growing pools, the per-fighter wound mask (fighter.gdshader
## blood_points), stump sprays.
## Round 5 (Feel Reference: Contact frame, Effects that sell power): the
## contact frame follows the hit TIER (flash size, a shock ring from launch up
## at most once per Tuning.FX_RING_GAP, blood none / small / more, the victim's
## mesh jitter during the freeze); the charge glow; body effects; world
## effects for movement live in the WorldFX child (scripts/fx/world_fx.gd).
## Round 7 (Freeflow combat): a player hit (HitInfo.react set) sizes its flash,
## brightness, shock ring and jitter by HitInfo.weight instead of the tier;
## the other Round 7 effects (push dust and skid, counter, dodge, reactions,
## drive, throw wind-up glow) live in the FreeflowFX child
## (scripts/fx/freeflow_fx.gd). Round 8 (Charge and pressure): the charge glow
## by c, the charged and broken hit accents, pressure ticks, the break burst,
## the dazed loop and the air combo touches live in the ChargeFX child
## (scripts/fx/charge_fx.gd). Parry, sidestep and the aimed-zone highlight
## are gone with their features. Decals persist for the round within caps: blood
## decals at most Tuning.BLOOD_DECAL_MAX, marks (floor cracks) MARK_DECAL_MAX,
## the oldest fading first; get_decal_counts() reports them (end-of-wave check).
## Mostly event-driven: listens to GameEvents (hit_landed, body_impact,
## fighter_died, limb_severed, wall_broken). Respects Tuning.gore.
## OWNER: agent F (blood & audio). CONTRACT STUB: keep the public API.
##
## Notes
## - Raycasts need the physics space, so splat(), smear() and pool() queue a
##   request that _physics_process resolves under a per-tick ray budget.
## - Every node is pooled: spray / stump / spark / dust emitters are fixed sets
##   reused round-robin; decals come from a free list and go back to it.
## - Gore OFF: decals and sprays use dust colours, pools and stump sprays are
##   skipped, and the fighter wound mask uses a dirt colour (so an enemy's
##   damage still shows without health bars).
## - Fighters are duck-typed (rig, hp, max_hp, get_com_velocity, is_down,
##   is_dead) so this autoload never fails to compile when fighter code is
##   mid-rewrite.

# --- Local tuning (candidates for Tuning) ------------------------------------
const SPRAY_POOL := 12            ## Hit-spray emitters, round-robin
const SPRAY_MAX_DROPS := 96       ## Droplets per spray emitter at full energy
const STUMP_POOL := 4             ## Arterial stump emitters
const SPARK_POOL := 6             ## Block sparks
const DUST_POOL := 8              ## Dust puff + chip emitter pairs
const STUMP_TIME := 1.5           ## s of arterial spray (Feel Reference: Dismemberment step 5)
const STUMP_PULSE_HZ := 2.2       ## Heartbeat pulses per second
const STUMP_DRIP_EVERY := 0.5     ## s between stump splat requests (3 drips in 1.5 s: the 30-decal budget)
const SPLAT_VARIANTS := 6
const SMEAR_VARIANTS := 3
const POOL_VARIANTS := 2
const TEX_SIZE := 128
const DECAL_DEPTH := 0.3          ## m, projection depth (short for culling)
const DECAL_FADE_TIME := 0.8      ## s
const POOL_GROW_TIME := 4.0       ## s (spec)
const POOL_MAX_SIZE := 1.2        ## m (spec)
const PIECE_POOL_SIZE := 0.5      ## m, pool where a severed piece stops
const LIE_STILL_TIME := 1.5       ## s lying still before a pool (spec)
const STILL_SPEED := 0.4          ## m/s centre-of-mass speed counted as still
const DEAD_REST_SPEED := 0.3      ## m/s
const DEAD_REST_HOLD := 0.3       ## s under DEAD_REST_SPEED before the death pool
const DEAD_WATCH_MAX := 10.0      ## s; pool anyway if a corpse never settles
const BODY_POLL := 0.1            ## s between body rest checks
const WOUND_POINTS := 16          ## Shader array size
const WOUND_REACH := 0.06         ## m; extra parts within radius + this get painted too
const WOUND_MAX_PARTS := 4
const WOUND_MIN_PART := 0.06      ## m; smaller parts (eyes, nose) are skipped
const FLASH_TIME := 0.09          ## s white hit flash
const RAY_BUDGET := 96            ## rays per physics tick
const QUEUE_MAX := 512            ## pending decal requests
const PIECE_TRACK_TIME := 4.0     ## s: a limb still moving after this pools where it is
const PIECE_TRAIL_MAX := 3        ## marks per severed piece: where it lands + 2 slide marks (+ a pool at rest)
const WALL_BODY_RADIUS := 2.5     ## m; a wall break bleeds only with a launched body this close
const HOLE_FALLBACK_RADIUS := 0.9  ## m; decals this close to a hole go when the panel has no is_point_open
const STRIKE_FULL_POWER := 400.0  ## wall-strike power that makes the biggest dust and chips
const STRIKE_DUST_ENERGY := Vector2(600.0, 7000.0)  ## dust() energy for the weakest .. full-power strike
const STRIKE_FLASH_FULL := 500.0  ## strike power for the largest wall contact flash (capped at 0.45)
const CONCRETE_DUST_ENERGY := 2500.0  ## J; hard-surface hits at or above this also throw chips
const IMPACT_DUST_ENERGY := 800.0  ## J; body hits on floor and walls at or above this kick up dust (U7)
const ARMOR_SPARK_SCALE := 0.6    ## armor spark size relative to a block spark
const DECAL_CULL_MASK := 0xFFFFF & ~(Layers.VIS_CHARACTERS | Layers.VIS_FX)
const RAY_MASK := Layers.WORLD | Layers.DESTRUCTIBLE

const BLOOD_DECAL := Color(0.48, 0.02, 0.025, 0.96)
const BLOOD_SMEAR := Color(0.46, 0.018, 0.022, 0.94)
const BLOOD_POOL := Color(0.34, 0.01, 0.015, 0.97)
const BLOOD_DROP := Color(0.5, 0.02, 0.03)
const BLOOD_SHADER := Color(0.32, 0.0, 0.01)
const DIRT_SHADER := Color(0.3, 0.26, 0.21)
const DUST_DEFAULT := Color(0.62, 0.58, 0.5)
const DUST_DECAL_ALPHA := 0.55
const DUST_BY_SURFACE := {
	&"drywall": Color(0.86, 0.84, 0.8),
	&"brick": Color(0.66, 0.42, 0.32),
	&"concrete": Color(0.62, 0.62, 0.6),
	&"wood": Color(0.58, 0.45, 0.3),
	&"floor": Color(0.6, 0.57, 0.5),
	# Round 6 surfaces (clutter, plaza tiles, offices, outside).
	&"glass": Color(0.82, 0.9, 0.95),
	&"cardboard": Color(0.66, 0.55, 0.38),
	&"fabric": Color(0.86, 0.84, 0.8),
	&"tile": Color(0.72, 0.7, 0.66),
	&"dirt": Color(0.5, 0.42, 0.32),
}
const SPARK_COLOR := Color(1.0, 0.85, 0.45)

enum Req { SPLAT, SMEAR, FLOOR_SMEAR, POOL, TRAIL, MARK }

## Random source (tests may seed it).
var rng := RandomNumberGenerator.new()

var _holder: Node3D
var _ray := PhysicsRayQueryParameters3D.new()

# Textures
var _splat_tex: Array[ImageTexture] = []
var _smear_tex: Array[ImageTexture] = []
var _pool_tex: Array[ImageTexture] = []
var _puff_tex: ImageTexture
var _wet_orm: ImageTexture

# Emitters
var _sprays: Array[GPUParticles3D] = []
var _spray_next := 0
var _sparks: Array[GPUParticles3D] = []
var _spark_next := 0
var _puffs: Array[GPUParticles3D] = []
var _chips: Array[GPUParticles3D] = []
var _dust_next := 0
var _stumps: Array[GPUParticles3D] = []
var _stump_next := 0
var _stump_attach: Array = []                 ## Node3D or null per slot
var _stump_offset := PackedVector3Array()     ## local to the attachment
var _stump_dir := PackedVector3Array()        ## local to the attachment
var _stump_time := PackedFloat32Array()       ## s left (<= 0: idle)
var _stump_age := PackedFloat32Array()
var _stump_drip := PackedFloat32Array()

# Decals
var _live: Array = []                ## Decal (maybe freed with a wall), oldest first
var _free: Array = []                ## Hidden Decals ready for reuse
var _fading: Dictionary = {}         ## decal id -> Vector2(time left, base alpha)
var _growing: Dictionary = {}        ## decal id -> PackedFloat32Array [x0, z0, x1, z1, t, dur]
var _pool_of: Dictionary = {}        ## fighter id -> pool decal id
var _fade_done: Array[int] = []      ## scratch

# Request queue (resolved in _physics_process)
var _rq_type := PackedInt32Array()
var _rq_pos := PackedVector3Array()
var _rq_dir := PackedVector3Array()
var _rq_vec := PackedVector3Array()
var _rq_val := PackedFloat32Array()
var _rq_owner := PackedInt64Array()
var _rq_head := 0

# Fighters
var _wounds: Dictionary = {}         ## part id -> [Array[Vector4], next, count]
var _mat_owner: Dictionary = {}      ## material id -> part id
var _flashing: Dictionary = {}       ## fighter id -> [parts, time left]
var _flash_done: Array[int] = []     ## scratch
var _dead_watch: Dictionary = {}     ## fighter id -> Vector2(still time, watch time)
var _lying: Dictionary = {}          ## fighter id -> still time while down
var _pooled: Dictionary = {}         ## fighter id -> true once pooled this down period
var _body_poll_t := 0.0

# Severed pieces
var _pieces: Array = []
var _piece_prev_v := PackedVector3Array()
var _piece_time := PackedFloat32Array()
var _piece_still := PackedFloat32Array()
var _piece_dist := PackedFloat32Array()
var _piece_trails := PackedInt32Array()
## Where tracked severed limbs first touched down (tests, newest last).
var piece_landings: Array[Vector3] = []

# Arena particle collision
var _arena_id := 0
var _heightfield: GPUParticlesCollisionHeightField3D
var _arena_check_t := 0.0
var _hf_nudge := 1.0


func _ready() -> void:
	rng.randomize()
	_holder = Node3D.new()
	_holder.name = "BloodFXWorld"
	add_child(_holder)
	_ray.collision_mask = RAY_MASK
	_ray.collide_with_areas = false
	_ray.collide_with_bodies = true
	_ray.hit_back_faces = false
	_build_textures()
	_build_emitters()
	_build_upgrade2()
	_build_round5()
	_connect_events()


# =============================================================================
# Public API
# =============================================================================

func spray(position: Vector3, direction: Vector3, energy: float) -> void:
	if Tuning.gore == Tuning.Gore.OFF:
		dust(position, DUST_DEFAULT, energy * 0.25, direction)
		return
	var dir := _safe_dir(direction, Vector3.UP)
	var e := _sprays[_spray_next]
	_spray_next = (_spray_next + 1) % _sprays.size()
	var t := clampf(energy / 9000.0, 0.0, 1.0)
	var pm := e.process_material as ParticleProcessMaterial
	pm.color = BLOOD_DROP
	pm.spread = lerpf(16.0, 34.0, t)
	pm.initial_velocity_min = lerpf(1.5, 4.0, t)
	pm.initial_velocity_max = lerpf(3.5, 9.5, t)
	e.amount_ratio = clampf((10.0 + energy / 70.0) / SPRAY_MAX_DROPS, 0.1, 1.0)
	e.global_transform = Transform3D(_basis_toward(dir), position)
	e.visible = true
	e.restart()

## Raycast 3-6 rays along the spray cone and place decals where they land.
func splat(position: Vector3, direction: Vector3, energy: float) -> void:
	_enqueue(Req.SPLAT, position, _safe_dir(direction, Vector3.DOWN), Vector3.ZERO, energy, 0)

func smear(position: Vector3, normal: Vector3, velocity: Vector3, energy: float) -> void:
	_enqueue(Req.SMEAR, position, _safe_dir(normal, Vector3.UP), velocity, energy, 0)

## Floor pool under a body, growing to max_size m over 4 s.
func pool(position: Vector3, max_size := 1.2) -> void:
	if Tuning.gore == Tuning.Gore.OFF:
		return
	_enqueue(Req.POOL, position, Vector3.DOWN, Vector3.ZERO, max_size, 0)

## Paint a wound on a fighter at a world position (blood mask shader).
func wound(fighter: Node3D, position: Vector3, amount: float) -> void:
	_wound(fighter, position, amount, Vector3.ZERO)
	_flash(fighter)

## Arterial spray from a stump for `duration` s, following `attach_to`.
func stump(attach_to: Node3D, duration := 2.0) -> void:
	_start_stump(attach_to, Vector3.ZERO, Vector3.UP, duration)

## Remove all decals, pools and live sprays (round restart).
func reset() -> void:
	for d in _live:
		_recycle(d)
	_live.clear()
	_fading.clear()
	_decals_created.clear()
	_decals_evicted = 0
	_decals_released = 0
	_growing.clear()
	_pool_of.clear()
	for list in [_sprays, _sparks, _puffs, _chips, _stumps]:
		for e: GPUParticles3D in list:
			e.emitting = false
			e.visible = false
	for i in _stumps.size():
		_stump_time[i] = 0.0
		_stump_attach[i] = null
	_pieces.clear()
	_piece_prev_v.clear()
	_piece_time.clear()
	_piece_still.clear()
	_piece_dist.clear()
	_piece_trails.clear()
	_clear_queue()
	for part_id: int in _wounds:
		var part := instance_from_id(part_id) as MeshInstance3D
		if part != null:
			var mat := _part_material(part)
			if mat != null:
				mat.set_shader_parameter(&"blood_count", 0)
				mat.set_shader_parameter(&"blood_level", 0.0)
				mat.set_shader_parameter(&"flash", 0.0)
	_wounds.clear()
	_mat_owner.clear()
	_flashing.clear()
	_dead_watch.clear()
	_lying.clear()
	_pooled.clear()
	_reset_upgrade2()
	_reset_round5()


# --- Extra API ---------------------------------------------------------------

## Debris / dust puff (wall breaks and cracks, impacts, gore-off hits). No
## blood. `chips` adds the small debris chips.
func dust(position: Vector3, color: Color, energy: float, direction := Vector3.UP, chips := true,
		chip_scale := 1.0) -> void:
	var i := _dust_next
	_dust_next = (_dust_next + 1) % _puffs.size()
	var t := clampf(energy / 8000.0, 0.0, 1.0)
	var xf := Transform3D(_basis_toward(_safe_dir(direction, Vector3.UP)), position)
	var puff := _puffs[i]
	var ppm := puff.process_material as ParticleProcessMaterial
	ppm.color = color
	ppm.initial_velocity_min = lerpf(0.4, 1.0, t)
	ppm.initial_velocity_max = lerpf(1.2, 3.5, t)
	ppm.emission_sphere_radius = lerpf(0.15, 0.6, t)
	puff.amount_ratio = lerpf(0.3, 1.0, t)
	puff.global_transform = xf
	puff.visible = true
	puff.restart()
	if not chips:
		return
	var ce := _chips[i]
	var cpm := ce.process_material as ParticleProcessMaterial
	cpm.color = color.darkened(0.15)
	cpm.scale_min = 0.5 * chip_scale
	cpm.scale_max = 1.6 * chip_scale
	cpm.initial_velocity_min = lerpf(1.0, 2.5, t)
	cpm.initial_velocity_max = lerpf(2.5, 7.0, t)
	ce.amount_ratio = lerpf(0.2, 1.0, t)
	ce.global_transform = xf
	ce.visible = true
	ce.restart()

## Small spark burst (blocked hits; armor at scale < 1).
func spark(position: Vector3, normal: Vector3, scale := 1.0) -> void:
	var e := _sparks[_spark_next]
	_spark_next = (_spark_next + 1) % _sparks.size()
	e.global_transform = Transform3D(_basis_toward(_safe_dir(normal, Vector3.UP)), position)
	e.amount_ratio = clampf(scale, 0.1, 1.0)
	e.speed_scale = lerpf(1.3, 1.0, clampf(scale, 0.0, 1.0))
	e.visible = true
	e.restart()

## Visible decals in use (live + fading + growing).
func decal_count() -> int:
	var n := 0
	for d in _live:
		if is_instance_valid(d):
			n += 1
	return n

## Live decals (for tests and debug overlays). May include freed entries.
func get_decals() -> Array:
	var out: Array = []
	for d in _live:
		if is_instance_valid(d):
			out.append(d)
	return out

## Decal requests not yet resolved by raycasts.
func pending() -> int:
	return _rq_type.size() - _rq_head

## Stump emitters currently spraying.
func active_stumps() -> int:
	var n := 0
	for t in _stump_time:
		if t > 0.0:
			n += 1
	return n

## Wound points painted on a mesh part (local space, w = radius) for tests.
func get_wound_points(part: MeshInstance3D) -> Array:
	var st: Array = _wounds.get(part.get_instance_id(), [])
	if st.is_empty():
		return []
	return (st[0] as Array).slice(0, st[2])

## Re-read hp/max_hp and push blood_level to every part (heals, impact damage).
func refresh_blood_level(fighter: Node3D) -> void:
	if not is_instance_valid(fighter):
		return
	var level := _blood_level(fighter)
	var spread := PLAYER_BLOOD_SPREAD if fighter.is_in_group(&"player") else 1.0
	for part in _mesh_parts(fighter):
		var mat := _part_material(part)
		if mat != null:
			mat.set_shader_parameter(&"blood_level", level)
			mat.set_shader_parameter(&"blood_spread", spread)


# =============================================================================
# Events
# =============================================================================

func _connect_events() -> void:
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.hit_blocked.connect(_on_hit_blocked)
	GameEvents.body_impact.connect(_on_body_impact)
	GameEvents.wall_broken.connect(_on_wall_broken)
	GameEvents.wall_cracked.connect(_on_wall_cracked)
	GameEvents.fighter_died.connect(_on_fighter_died)
	GameEvents.limb_severed.connect(_on_limb_severed)
	GameEvents.fighter_damaged.connect(_on_fighter_damaged)
	GameEvents.wave_started.connect(_on_wave_started)
	GameEvents.armor_absorbed.connect(_on_armor_absorbed)
	GameEvents.dazed.connect(_on_dazed)
	GameEvents.stumbled.connect(_on_stumbled)
	GameEvents.tripped.connect(_on_tripped)
	GameEvents.arm_broken.connect(_on_arm_broken)
	GameEvents.wall_struck.connect(_on_wall_struck)

## Round 5 contact frame (Feel Reference: Contact frame items 2-4), all on the
## physics frame of hit_landed: the victim's body flashes and its mesh jitters
## through the freeze; a white radial flash at the contact point sized by
## tier, plus a shock ring from launch up (one per Tuning.FX_RING_GAP); blood
## by tier: none on flinch (or a sweep's stumble), a small spray on stagger,
## more from knockdown up; a ground strike adds a spray into the floor.
## Grabs do not bleed; a throw bleeds when the body lands (body_impact).
## Round 7: a player hit (HitInfo.react set) sizes the flash, its brightness,
## the shock ring (from R7_RING_FROM, or any launch payoff) and the jitter by
## HitInfo.weight; the jitter lasts the move's own hitstop. Blood stays by tier.
func _on_hit_landed(info: HitInfo) -> void:
	if info == null or not is_instance_valid(info.victim):
		return
	_drop_charge_glow(info.victim)  # a hit knocks the victim out of any charge
	if FXRules.is_throw_release(info):
		return  # Round 7: a throw's release is no contact (its whoosh is AudioFX's)
	var tier := FXRules.tier_of(info)
	var at := _hit_point(info)
	var frame := Engine.get_physics_frames()
	var rec := {"frame": frame, "tier": tier, "flash": false, "ring": false, "blood": false, "weight": -1.0}
	_flash(info.victim)
	if info.kind != &"grab":
		if FXRules.is_round7(info):
			var w := FXRules.weight_of(info)
			var p := lerpf(R7_FLASH_POWER.x, R7_FLASH_POWER.y, w)
			var bright := lerpf(R7_FLASH_BRIGHT.x, R7_FLASH_BRIGHT.y, w)
			var rp := lerpf(R7_RING_POWER.x, R7_RING_POWER.y, clampf((w - R7_RING_FROM) / (1.0 - R7_RING_FROM), 0.0, 1.0))
			var ring := (w >= R7_RING_FROM or info.react == &"launch") and _ring_allowed()
			impact_flash(at, p, false, ring, bright, rp)
			rec["ring"] = ring
			rec["weight"] = w
			rec["flash_size"] = lerpf(IMPACT_FLASH_SIZE.x, IMPACT_FLASH_SIZE.y, p)
			rec["brightness"] = bright
			rec["ring_size"] = lerpf(IMPACT_RING_SIZE.x, IMPACT_RING_SIZE.y, rp) if ring else 0.0
			_jitter_start(info.victim, tier, w, info.hitstop)
		else:
			var ring := tier >= HitInfo.Tier.LAUNCH and _ring_allowed()
			var p := TIER_FLASH[clampi(tier, 0, TIER_FLASH.size() - 1)]
			impact_flash(at, p, false, ring)
			rec["ring"] = ring
			rec["flash_size"] = lerpf(IMPACT_FLASH_SIZE.x, IMPACT_FLASH_SIZE.y, p)
			rec["brightness"] = IMPACT_BRIGHTNESS
			rec["ring_size"] = lerpf(IMPACT_RING_SIZE.x, IMPACT_RING_SIZE.y, p) if ring else 0.0
			_jitter_start(info.victim, tier)
		rec["flash"] = true
	var bleeds := info.kind != &"grab" and info.kind != &"throw"
	var spray_e: float = TIER_SPRAY[clampi(tier, 0, TIER_SPRAY.size() - 1)]
	# Knees and headbutts on a held body are flinch-tier but bleed a little
	# (Feel Reference: Actions while holding; G tags them meta blood = &"small").
	if spray_e <= 0.0 and info.has_meta(&"blood") and StringName(info.get_meta(&"blood")) == &"small":
		spray_e = HELD_STRIKE_SPRAY
	if bleeds and spray_e > 0.0:
		# The player's wounds are drawn larger so damage taken reads without the HP bar.
		var scale := PLAYER_WOUND_SCALE if info.victim.is_in_group(&"player") else 1.0
		_wound(info.victim, at, TIER_WOUND[clampi(tier, 0, TIER_WOUND.size() - 1)], info.hit_direction, scale)
		spray(at, info.hit_direction, spray_e)
		splat(at, info.hit_direction, spray_e)
		rec["blood"] = true
	if bleeds and info.ground_strike:
		spray(at, (Vector3.DOWN + info.hit_direction * 0.4).normalized(), GROUND_SPRAY)
		splat(at, Vector3.DOWN, GROUND_SPRAY)
		rec["blood"] = true
	refresh_blood_level(info.victim)
	contact_log.append(rec)
	if contact_log.size() > 64:
		contact_log.pop_front()

func _on_hit_blocked(info: HitInfo) -> void:
	if info == null:
		return
	spark(_hit_point(info), -info.hit_direction)

## Armor took the hit (no flinch): a small spark where it landed.
func _on_armor_absorbed(info: HitInfo) -> void:
	if info == null:
		return
	spark(_hit_point(info), -info.hit_direction, ARMOR_SPARK_SCALE)

## Contact point; when a hit carries none, the hit bone (or chest height).
func _hit_point(info: HitInfo) -> Vector3:
	if info.hit_position != Vector3.ZERO or not is_instance_valid(info.victim):
		return info.hit_position
	var rig := _rig_of(info.victim)
	if rig != null and rig.has_method(&"get_bone_global_position"):
		return rig.call(&"get_bone_global_position", info.hit_bone)
	return info.victim.global_position + Vector3.UP * 1.3

## Round 5 (Feel Reference: On the world > Body hits the floor hard): a dust
## puff in the surface's colour (chips off hard walls on big hits), and blood
## only if the body is wounded: a smear on the surface and a small spray. On
## water: ripple rings and a splash instead of dust and blood.
func _on_body_impact(fighter: Node3D, position: Vector3, normal: Vector3, energy: float,
		surface: StringName) -> void:
	if energy <= Tuning.IMPACT_MIN_ENERGY:
		return
	var n := _safe_dir(normal, Vector3.UP)
	if surface == &"water":
		if _world != null:
			_world.call(&"water_impact", position, energy)
		return
	var vel := Vector3.ZERO
	if is_instance_valid(fighter) and fighter.has_method(&"get_com_velocity"):
		vel = fighter.call(&"get_com_velocity")
	var tangent := vel - n * vel.dot(n)
	var out := n
	if tangent.length_squared() > 0.01:
		out = (n * 0.6 + tangent.normalized() * 0.8).normalized()
	var solid := surface != &"body" and surface != &"debris"
	if solid:
		var chips := energy >= CONCRETE_DUST_ENERGY and (surface == &"concrete" or surface == &"brick")
		dust(position + n * 0.05, DUST_BY_SURFACE.get(surface, DUST_BY_SURFACE[&"floor"]),
				maxf(energy * 0.5, IMPACT_DUST_ENERGY * 0.5), n, chips)
	var wounded := is_instance_valid(fighter) and _blood_level(fighter) >= WOUNDED_LEVEL
	if wounded:
		spray(position, out, energy * 0.3)
		if solid:
			smear(position, n, vel, energy)
		_wound(fighter, position, clampf(energy / 6000.0, 0.2, 1.0), n)
	if is_instance_valid(fighter):
		refresh_blood_level(fighter)

func _on_wall_broken(wall: Node3D, position: Vector3, energy: float, velocity: Vector3) -> void:
	_release_decals_over_holes(wall, position)
	_nudge_heightfield()
	var vdir := _safe_dir(Vector3(velocity.x, 0.0, velocity.z), Vector3.FORWARD)
	# A strike that opens a hole emits wall_broken and wall_struck in the same
	# frame; the strike makes its own (bigger) burst, so this one waits for the
	# end of the frame and is skipped if a strike on this wall arrived.
	_wall_dust_deferred.call_deferred(_id_of(wall), position, _surface_color(wall), energy, vdir,
			Engine.get_process_frames())
	# A scripted break (an enemy bursting in) has no flying body: dust only.
	if not _launched_body_near(position, WALL_BODY_RADIUS):
		return
	# Smears on both sides of the hole: where the body went in and where it came out.
	_enqueue(Req.FLOOR_SMEAR, position - vdir * 0.8, vdir, velocity, energy * 0.6, 0)
	_enqueue(Req.FLOOR_SMEAR, position + vdir * 1.8, vdir, velocity, energy, 0)
	splat(position + vdir * 0.4, vdir, energy * 0.5)

func _launched_body_near(position: Vector3, radius: float) -> bool:
	for f in get_tree().get_nodes_in_group(&"fighters"):
		if not (f.has_method(&"is_launched") and f.call(&"is_launched")):
			continue
		var c: Vector3 = f.call(&"get_center_of_mass") if f.has_method(&"get_center_of_mass") \
				else (f as Node3D).global_position
		if c.distance_to(position) < radius:
			return true
	return false

func _on_wall_cracked(wall: Node3D, position: Vector3, energy: float) -> void:
	var dir := Vector3.UP
	if is_instance_valid(wall) and wall.has_method(&"get_face_normal"):
		dir = wall.call(&"get_face_normal", position + Vector3.UP)
	_wall_dust_deferred.call_deferred(_id_of(wall), position, _surface_color(wall), energy * 0.4, dir,
			Engine.get_process_frames())

func _wall_dust_deferred(wall_id: int, position: Vector3, color: Color, energy: float, dir: Vector3,
		frame: int) -> void:
	if wall_id != 0 and int(_struck_frame.get(wall_id, -1)) == frame:
		return
	dust(position, color, energy, dir)

static func _id_of(n: Object) -> int:
	return n.get_instance_id() if is_instance_valid(n) else 0

## Round 3: a punch or kick on a wall. A dust puff in the surface's colour
## along the normal, chips sized by power and result, a bigger burst (and a
## puff out of the far side) for a hole or a break, and a small contact flash.
func _on_wall_struck(_attacker: Node3D, wall: Node3D, position: Vector3, normal: Vector3, power: float,
		result: StringName, surface: StringName) -> void:
	if is_instance_valid(wall):
		_struck_frame[wall.get_instance_id()] = Engine.get_process_frames()
	var n := _safe_dir(normal, Vector3.UP)
	var t := clampf(power / STRIKE_FULL_POWER, 0.05, 1.0)
	var big := result == &"hole" or result == &"break"
	var energy := lerpf(STRIKE_DUST_ENERGY.x, STRIKE_DUST_ENERGY.y, t) * (1.8 if big else 1.0)
	var chips := result != &"hold" or surface == &"concrete"
	var chip_scale := lerpf(0.45, 1.1, t) * (1.6 if big else (1.2 if result == &"crack" else 1.0))
	var color: Color = DUST_BY_SURFACE.get(surface, DUST_DEFAULT)
	dust(position + n * 0.05, color, energy, n, chips, chip_scale)
	if big:
		dust(position - n * 0.35, color, energy * 0.7, -n, true, chip_scale)
	impact_flash(position + n * 0.03, clampf(power / STRIKE_FLASH_FULL, 0.04, 0.45) * (1.3 if big else 1.0))

func _on_fighter_died(fighter: Node3D, _info: HitInfo) -> void:
	if not is_instance_valid(fighter):
		return
	_dead_watch[fighter.get_instance_id()] = Vector2.ZERO
	refresh_blood_level(fighter)

func _on_limb_severed(fighter: Node3D, cut: StringName, piece: Node3D) -> void:
	if Tuning.gore == Tuning.Gore.OFF or not is_instance_valid(fighter):
		return
	var bone: StringName = Bones.CUTS.get(cut, &"")
	if bone == &"":
		return
	var parent_bone: StringName = Bones.PARENT[bone]
	var rig: Node3D = _rig_of(fighter)
	var attach: Node3D = null
	var joint := fighter.global_position + Vector3.UP * 1.4
	var parent_pos := fighter.global_position + Vector3.UP * 1.2
	if rig != null:
		attach = rig.call(&"get_attachment", parent_bone)
		joint = rig.call(&"get_bone_global_position", bone)
		parent_pos = rig.call(&"get_bone_global_position", parent_bone)
	if attach == null:
		attach = fighter
	var dir_world := _safe_dir(joint - parent_pos, Vector3.UP)
	var inv := attach.global_transform.affine_inverse()
	var local_dir := (inv.basis * dir_world).normalized()
	_start_stump(attach, inv * joint, local_dir, STUMP_TIME)
	_wound(fighter, joint, 1.0, -dir_world)
	spray(joint, dir_world, 6000.0)
	splat(joint, dir_world, 3000.0)
	if is_instance_valid(piece):
		_paint_piece(piece, joint)
		if piece is RigidBody3D:
			_track_piece(piece)

func _on_fighter_damaged(fighter: Node3D, _amount: float, _source: StringName) -> void:
	refresh_blood_level(fighter)

func _on_wave_started(_index: int, _total: int) -> void:
	# Heals between waves lower hp loss; refresh every fighter's blood level.
	for f in get_tree().get_nodes_in_group(&"fighters"):
		refresh_blood_level(f)


# =============================================================================
# Frame updates
# =============================================================================

func _process(delta: float) -> void:
	_update_fades(delta)
	_update_growth(delta)
	_update_flashes(delta)
	_update_stumps(delta)
	var real := delta / maxf(Engine.time_scale, 0.001)
	_update_jitter(real)
	_update_impact_flashes(real)
	_update_swirls(delta)
	_arena_check_t -= delta
	if _arena_check_t <= 0.0:
		_arena_check_t = 0.5
		_check_arena()

func _physics_process(delta: float) -> void:
	if pending() > 0:
		_resolve_requests()
	if not _pieces.is_empty():
		_update_pieces(delta)
	_body_poll_t += delta
	if _body_poll_t >= BODY_POLL:
		_poll_bodies(_body_poll_t)
		_body_poll_t = 0.0

func _update_fades(delta: float) -> void:
	if _fading.is_empty():
		return
	_fade_done.clear()
	for id: int in _fading:
		var d := instance_from_id(id) as Decal
		if d == null:
			_fade_done.append(id)
			continue
		var f: Vector2 = _fading[id]
		f.x -= delta
		_fading[id] = f
		var c := d.modulate
		c.a = f.y * clampf(f.x / DECAL_FADE_TIME, 0.0, 1.0)
		d.modulate = c
		if f.x <= 0.0:
			_fade_done.append(id)
	for id in _fade_done:
		_fading.erase(id)
		var d := instance_from_id(id) as Decal
		if d != null:
			if _live.has(d):
				_live.erase(d)
				_decals_evicted += 1
			_recycle(d)

func _update_growth(delta: float) -> void:
	if _growing.is_empty():
		return
	_fade_done.clear()
	for id: int in _growing:
		var d := instance_from_id(id) as Decal
		if d == null:
			_fade_done.append(id)
			continue
		var g: PackedFloat32Array = _growing[id]
		g[4] += delta
		_growing[id] = g
		var u := clampf(g[4] / g[5], 0.0, 1.0)
		var k := 1.0 - pow(1.0 - u, 2.2)  # fast spread, slow finish
		d.size = Vector3(lerpf(g[0], g[2], k), DECAL_DEPTH, lerpf(g[1], g[3], k))
		if u >= 1.0:
			_fade_done.append(id)
	for id in _fade_done:
		_growing.erase(id)

func _update_flashes(delta: float) -> void:
	if _flashing.is_empty():
		return
	_flash_done.clear()
	for id: int in _flashing:
		var rec: Array = _flashing[id]
		var t: float = rec[1] - delta
		rec[1] = t
		var v := clampf(t / FLASH_TIME, 0.0, 1.0)
		for part in rec[0]:
			if is_instance_valid(part):
				var mat := _part_material(part)
				if mat != null:
					mat.set_shader_parameter(&"flash", v * v)
		if t <= 0.0:
			_flash_done.append(id)
	for id in _flash_done:
		_flashing.erase(id)

func _update_stumps(delta: float) -> void:
	for i in _stump_time.size():
		if _stump_time[i] <= 0.0:
			continue
		var e := _stumps[i]
		var a = _stump_attach[i]
		if not is_instance_valid(a) or not (a as Node3D).is_inside_tree():
			_stop_stump(i)
			continue
		var xf := (a as Node3D).global_transform
		var pos := xf * _stump_offset[i]
		var dir := _safe_dir(xf.basis * _stump_dir[i], Vector3.UP)
		e.global_transform = Transform3D(_basis_toward(dir), pos)
		_stump_age[i] += delta
		_stump_time[i] -= delta
		var beat := maxf(sin(_stump_age[i] * TAU * STUMP_PULSE_HZ), 0.0)
		var fade := clampf(_stump_time[i] / 0.6, 0.0, 1.0)
		e.amount_ratio = (0.2 + 0.8 * beat * beat) * fade
		var pm := e.process_material as ParticleProcessMaterial
		pm.initial_velocity_max = lerpf(1.5, 4.5, beat) * (0.4 + 0.6 * fade)
		_stump_drip[i] -= delta
		if _stump_drip[i] <= 0.0:
			_stump_drip[i] = STUMP_DRIP_EVERY
			_enqueue(Req.SPLAT, pos, dir, Vector3.ZERO, 700.0, 0)
		if _stump_time[i] <= 0.0:
			_stop_stump(i)

func _stop_stump(i: int) -> void:
	_stump_time[i] = 0.0
	_stump_attach[i] = null
	_stumps[i].emitting = false

func _start_stump(attach: Node3D, local_offset: Vector3, local_dir: Vector3, duration: float) -> void:
	if Tuning.gore == Tuning.Gore.OFF or not is_instance_valid(attach):
		return
	var i := _stump_next
	_stump_next = (_stump_next + 1) % _stumps.size()
	_stump_attach[i] = attach
	_stump_offset[i] = local_offset
	_stump_dir[i] = _safe_dir(local_dir, Vector3.UP)
	_stump_time[i] = maxf(duration, 0.05)
	_stump_age[i] = 0.0
	_stump_drip[i] = 0.05
	var e := _stumps[i]
	var xf := attach.global_transform
	e.global_transform = Transform3D(_basis_toward(_safe_dir(xf.basis * local_dir, Vector3.UP)),
			xf * local_offset)
	e.visible = true
	e.emitting = true

func _poll_bodies(dt: float) -> void:
	# Corpses: pool once the body has come to rest.
	if not _dead_watch.is_empty():
		_fade_done.clear()
		for id: int in _dead_watch:
			var f := instance_from_id(id) as Node3D
			if f == null or not f.is_inside_tree():
				_fade_done.append(id)
				continue
			var w: Vector2 = _dead_watch[id]
			w.y += dt
			if _com_speed(f) < DEAD_REST_SPEED:
				w.x += dt
			else:
				w.x = 0.0
			_dead_watch[id] = w
			if w.x >= DEAD_REST_HOLD or w.y >= DEAD_WATCH_MAX:
				_pool_under(f, POOL_MAX_SIZE)
				_fade_done.append(id)
		for id in _fade_done:
			_dead_watch.erase(id)
	# Living fighters lying still.
	for f in get_tree().get_nodes_in_group(&"fighters"):
		var id: int = f.get_instance_id()
		if f.has_method(&"is_dead") and f.call(&"is_dead"):
			continue
		var down: bool = f.call(&"is_down") if f.has_method(&"is_down") else false
		if not down:
			_lying.erase(id)
			_pooled.erase(id)
			continue
		if _pooled.has(id):
			continue
		var t: float = _lying.get(id, 0.0)
		t = t + dt if _com_speed(f) < STILL_SPEED else 0.0
		_lying[id] = t
		if t >= LIE_STILL_TIME:
			_pooled[id] = true
			_pool_under(f, lerpf(0.5, POOL_MAX_SIZE, _blood_level(f)))

func _update_pieces(delta: float) -> void:
	for i in range(_pieces.size() - 1, -1, -1):
		var p = _pieces[i]
		if not is_instance_valid(p) or not (p as RigidBody3D).is_inside_tree():
			_untrack_piece(i)
			continue
		var body := p as RigidBody3D
		var v := body.linear_velocity
		var pv := _piece_prev_v[i]
		var pos := body.global_position
		_piece_time[i] += delta
		var speed := v.length()
		# A bounce: sharp velocity change while it was moving. The first one is
		# where the limb lands (Feel Reference: Dismemberment step 5): a bigger mark.
		if pv.length() > 1.5 and (v - pv).length() > 2.0 and _piece_trails[i] < PIECE_TRAIL_MAX:
			_enqueue(Req.TRAIL, pos, pv.normalized(), Vector3.ZERO, 0.45 if _piece_trails[i] == 0 else 0.3, 0)
			if _piece_trails[i] == 0:
				piece_landings.append(pos)
				if piece_landings.size() > 16:
					piece_landings.pop_front()
			_piece_trails[i] += 1
			_piece_dist[i] = 0.0
		# Rolling / sliding after it has landed: a smaller mark every 0.6 m.
		_piece_dist[i] += speed * delta
		if _piece_trails[i] >= 1 and _piece_dist[i] > 0.6 and _piece_trails[i] < PIECE_TRAIL_MAX:
			_enqueue(Req.TRAIL, pos, Vector3.DOWN, Vector3.ZERO, 0.22, 0)
			_piece_trails[i] += 1
			_piece_dist[i] = 0.0
		_piece_still[i] = _piece_still[i] + delta if speed < 0.15 else 0.0
		_piece_prev_v[i] = v
		if _piece_still[i] > 0.5 or _piece_time[i] > PIECE_TRACK_TIME:
			pool(pos, PIECE_POOL_SIZE)
			_untrack_piece(i)

func _track_piece(piece: RigidBody3D) -> void:
	_pieces.append(piece)
	_piece_prev_v.append(piece.linear_velocity)
	_piece_time.append(0.0)
	_piece_still.append(0.0)
	_piece_dist.append(0.0)
	_piece_trails.append(0)

func _untrack_piece(i: int) -> void:
	_pieces.remove_at(i)
	_piece_prev_v.remove_at(i)
	_piece_time.remove_at(i)
	_piece_still.remove_at(i)
	_piece_dist.remove_at(i)
	_piece_trails.remove_at(i)


# =============================================================================
# Decal requests (raycasts)
# =============================================================================

func _enqueue(type: int, pos: Vector3, dir: Vector3, vec: Vector3, val: float, owner_id: int) -> void:
	if pending() >= QUEUE_MAX:
		return
	_rq_type.append(type)
	_rq_pos.append(pos)
	_rq_dir.append(dir)
	_rq_vec.append(vec)
	_rq_val.append(val)
	_rq_owner.append(owner_id)

func _clear_queue() -> void:
	_rq_type.clear()
	_rq_pos.clear()
	_rq_dir.clear()
	_rq_vec.clear()
	_rq_val.clear()
	_rq_owner.clear()
	_rq_head = 0

func _resolve_requests() -> void:
	var space := _holder.get_world_3d().direct_space_state
	if space == null:
		return
	var rays := 0
	while _rq_head < _rq_type.size() and rays < RAY_BUDGET:
		var i := _rq_head
		_rq_head += 1
		match _rq_type[i]:
			Req.SPLAT:
				rays += _do_splat(space, _rq_pos[i], _rq_dir[i], _rq_val[i])
			Req.SMEAR:
				rays += _do_smear(space, _rq_pos[i], _rq_dir[i], _rq_vec[i], _rq_val[i])
			Req.FLOOR_SMEAR:
				rays += _do_floor_smear(space, _rq_pos[i], _rq_vec[i], _rq_val[i])
			Req.POOL:
				rays += _do_pool(space, _rq_pos[i], _rq_val[i], _rq_owner[i])
			Req.TRAIL:
				rays += _do_trail(space, _rq_pos[i], _rq_dir[i], _rq_val[i])
			Req.MARK:
				rays += _do_mark(space, _rq_pos[i], _rq_val[i])
	if _rq_head >= _rq_type.size():
		_clear_queue()

func _cast(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	_ray.from = from
	_ray.to = to
	return space.intersect_ray(_ray)

func _do_splat(space: PhysicsDirectSpaceState3D, pos: Vector3, dir: Vector3, energy: float) -> int:
	# Round 5: blood decals cap at Tuning.BLOOD_DECAL_MAX for the whole round, so
	# a hit leaves 1 (stagger) to 4 (severing launch) marks, not a carpet.
	var n := clampi(1 + int(energy / 3000.0), 1, 4)
	var reach := clampf(1.2 + energy / 2500.0, 1.2, 5.0)
	var size := clampf(0.22 + energy / 9000.0, 0.22, 0.9)
	var spread := deg_to_rad(lerpf(18.0, 32.0, clampf(energy / 9000.0, 0.0, 1.0)))
	var rays := 0
	for k in n:
		var rd: Vector3
		var length := reach
		if k == 0:
			# Drip: blood falls just below and ahead of the wound.
			rd = (Vector3.DOWN + dir * 0.35).normalized()
			length = 3.5
		else:
			rd = _cone_dir(dir, spread)
			rd = (rd + Vector3.DOWN * rng.randf_range(0.0, 0.35)).normalized()
		var hit := _cast(space, pos, pos + rd * length)
		rays += 1
		if hit.is_empty() and k != 0:
			# Fell short of a wall: the droplets come down on the floor.
			var end := pos + rd * length * rng.randf_range(0.5, 1.0)
			hit = _cast(space, end, end + Vector3.DOWN * 4.0)
			rays += 1
		if hit.is_empty():
			continue
		var s := size * rng.randf_range(0.7, 1.3) * (0.75 if k == 0 else 1.0)
		var c := _decal_color(BLOOD_DECAL)
		_place_decal(hit.position, hit.normal, Vector2(s, s), _pick(_splat_tex), c,
				Vector3.ZERO, hit.collider)
	return rays

func _do_smear(space: PhysicsDirectSpaceState3D, pos: Vector3, normal: Vector3, vel: Vector3,
		energy: float) -> int:
	var hit := _cast(space, pos + normal * 0.4, pos - normal * 0.5)
	var p := pos
	var n := normal
	var parent: Object = null
	if not hit.is_empty():
		p = hit.position
		n = hit.normal
		parent = hit.collider
	_place_smear(p, n, vel, energy, parent)
	return 1

func _do_floor_smear(space: PhysicsDirectSpaceState3D, pos: Vector3, vel: Vector3, energy: float) -> int:
	var hit := _cast(space, pos + Vector3.UP * 0.6, pos + Vector3.DOWN * 3.0)
	if hit.is_empty() or (hit.normal as Vector3).y < 0.6:
		return 1
	_place_smear(hit.position, hit.normal, vel, energy, hit.collider)
	return 1

func _place_smear(p: Vector3, n: Vector3, vel: Vector3, energy: float, parent: Object) -> void:
	var along := vel - n * vel.dot(n)
	if along.length_squared() < 0.04:
		along = Vector3.ZERO
	var length := clampf(0.9 + energy / 2500.0, 0.9, 2.8) * rng.randf_range(0.85, 1.15)
	var width := clampf(0.5 + energy / 15000.0, 0.5, 0.95)
	var center := p
	if along != Vector3.ZERO:
		center += along.normalized() * length * 0.26  # the head (u ~ 0.24) sits on the contact
	_place_decal(center, n, Vector2(length, width), _pick(_smear_tex), _decal_color(BLOOD_SMEAR),
			along, parent)

func _do_pool(space: PhysicsDirectSpaceState3D, pos: Vector3, max_size: float, owner_id: int) -> int:
	if Tuning.gore == Tuning.Gore.OFF:
		return 0
	var hit := _cast(space, pos + Vector3.UP * 0.3, pos + Vector3.DOWN * 3.0)
	if hit.is_empty() or (hit.normal as Vector3).y < 0.6:
		return 1
	var aspect := rng.randf_range(0.85, 1.15)
	var x1 := max_size * aspect
	var z1 := max_size / aspect
	# A body that already has a pool here grows it instead of stacking a second.
	if owner_id != 0 and _pool_of.has(owner_id):
		var old := instance_from_id(_pool_of[owner_id]) as Decal
		if old != null and old.visible and old.global_position.distance_to(hit.position) < 0.6:
			_grow(old, maxf(x1, old.size.x), maxf(z1, old.size.z))
			return 1
	var d := _place_decal(hit.position, hit.normal, Vector2(0.05, 0.05), _pick(_pool_tex), BLOOD_POOL,
			Vector3.ZERO, hit.collider)
	_grow(d, x1, z1)
	if owner_id != 0:
		_pool_of[owner_id] = d.get_instance_id()
	return 1

func _do_trail(space: PhysicsDirectSpaceState3D, pos: Vector3, dir: Vector3, size: float) -> int:
	var hit := _cast(space, pos, pos + dir * 0.7)
	var rays := 1
	if hit.is_empty() and dir.y > -0.9:
		hit = _cast(space, pos, pos + Vector3.DOWN * 0.7)
		rays += 1
	if hit.is_empty():
		return rays
	var s := size * rng.randf_range(0.8, 1.25)
	_place_decal(hit.position, hit.normal, Vector2(s, s), _pick(_splat_tex), _decal_color(BLOOD_DECAL),
			Vector3.ZERO, hit.collider)
	return rays

func _grow(d: Decal, x1: float, z1: float) -> void:
	var g := PackedFloat32Array([d.size.x, d.size.z, x1, z1, 0.0, POOL_GROW_TIME])
	_growing[d.get_instance_id()] = g

func _pool_under(f: Node3D, max_size: float) -> void:
	if Tuning.gore == Tuning.Gore.OFF:
		return
	var pos := f.global_position
	var rig: Node3D = _rig_of(f)
	if rig != null:
		pos = rig.call(&"get_bone_global_position", Bones.CHEST)
	elif f.has_method(&"get_center_of_mass"):
		pos = f.call(&"get_center_of_mass")
	_enqueue(Req.POOL, pos, Vector3.DOWN, Vector3.ZERO, max_size, f.get_instance_id())


# =============================================================================
# Decal pool
# =============================================================================

func _decal_color(blood: Color) -> Color:
	if Tuning.gore == Tuning.Gore.OFF:
		var c := DUST_DEFAULT
		c.a = DUST_DECAL_ALPHA
		return c
	return blood

func _place_decal(pos: Vector3, normal: Vector3, size: Vector2, tex: Texture2D, color: Color,
		tangent_hint: Vector3, collider: Object, kind := &"blood") -> Decal:
	var d := _alloc_decal()
	d.set_meta(&"fx_kind", kind)
	_decals_created[kind] = int(_decals_created.get(kind, 0)) + 1
	var n := _safe_dir(normal, Vector3.UP)
	var x := Vector3.ZERO
	if tangent_hint.length_squared() > 0.0001:
		x = tangent_hint - n * tangent_hint.dot(n)
	if x.length_squared() < 0.0001:
		x = n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT)
		x = x.normalized().rotated(n, rng.randf() * TAU)
	x = x.normalized()
	var z := x.cross(n).normalized()
	var parent: Node = _holder
	var wall := _destructible_of(collider)
	if wall != null:
		parent = wall
	if d.get_parent() != parent:
		d.reparent(parent, false)
	d.global_transform = Transform3D(Basis(x, n, z), pos)
	d.size = Vector3(size.x, DECAL_DEPTH, size.y)
	d.texture_albedo = tex
	d.texture_orm = _wet_orm if color.r > color.g * 2.0 else null
	d.modulate = color
	d.visible = true
	_live.append(d)
	_enforce_cap()
	return d

func _alloc_decal() -> Decal:
	while not _free.is_empty():
		var o = _free.pop_back()
		if is_instance_valid(o):
			return o
	var d := Decal.new()
	d.cull_mask = DECAL_CULL_MASK
	d.normal_fade = 0.45
	d.upper_fade = 0.15
	d.lower_fade = 0.3
	d.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	d.visible = false
	_holder.add_child(d)
	return d

func _recycle(o) -> void:
	if not is_instance_valid(o):
		return
	var d := o as Decal
	var id := d.get_instance_id()
	_fading.erase(id)
	_growing.erase(id)
	d.visible = false
	if d.get_parent() != _holder:
		d.reparent(_holder, false)
	_free.append(d)

func _start_fade(d: Decal) -> void:
	var id := d.get_instance_id()
	if _fading.has(id):
		return
	_growing.erase(id)
	_fading[id] = Vector2(DECAL_FADE_TIME, d.modulate.a)

## Round 5 caps per kind: at most Tuning.BLOOD_DECAL_MAX blood decals (marks:
## MARK_DECAL_MAX) that are not fading; past it the oldest of that kind fades
## out over DECAL_FADE_TIME. A burst that leaves more than FADE_SLACK of one
## kind still fading recycles the oldest at once.
func _enforce_cap() -> void:
	_prune_live()
	var i := 0
	for kind: StringName in [&"blood", &"mark"]:
		var cap: int = Tuning.BLOOD_DECAL_MAX if kind == &"blood" else MARK_DECAL_MAX
		var active := 0
		var total := 0
		for d in _live:
			if _kind_of(d) == kind:
				total += 1
				if not _fading.has((d as Decal).get_instance_id()):
					active += 1
		i = 0
		while (active > cap or total > cap + FADE_SLACK) and i < _live.size():
			var d := _live[i] as Decal
			if _kind_of(d) != kind:
				i += 1
				continue
			if total > cap + FADE_SLACK:
				if not _fading.has(d.get_instance_id()):
					active -= 1
				_live.remove_at(i)
				_recycle(d)
				_decals_evicted += 1
				total -= 1
				continue
			if not _fading.has(d.get_instance_id()):
				_start_fade(d)
				active -= 1
			i += 1

## Drop entries freed with their wall (they count as released).
func _prune_live() -> void:
	var i := 0
	while i < _live.size():
		if is_instance_valid(_live[i]):
			i += 1
		else:
			_live.remove_at(i)
			_decals_released += 1

static func _kind_of(d: Object) -> StringName:
	return StringName((d as Node).get_meta(&"fx_kind", &"blood"))

## Decal bookkeeping since the last reset() (Feel Reference F11: the end-of-wave
## counts match what was created). created == live + fading + evicted + released.
## live: on screen and not fading; blood / marks: live by kind; evicted: faded
## out by the caps; released: taken away with a broken wall.
func get_decal_counts() -> Dictionary:
	_prune_live()
	var live := 0
	var fading := 0
	var blood := 0
	var marks := 0
	for d in _live:
		if not is_instance_valid(d):
			continue
		if _fading.has((d as Decal).get_instance_id()):
			fading += 1
			continue
		live += 1
		if _kind_of(d) == &"mark":
			marks += 1
		else:
			blood += 1
	var created := 0
	for k: StringName in _decals_created:
		created += int(_decals_created[k])
	return {"created": created, "live": live, "fading": fading, "evicted": _decals_evicted,
		"released": _decals_released, "blood": blood, "marks": marks,
		"blood_created": int(_decals_created.get(&"blood", 0)), "marks_created": int(_decals_created.get(&"mark", 0))}

## A broken panel takes its decals with it.
## A hole in a panel takes only the decals over the open cells (local
## fracture: a panel can be holed several times). A panel that is fully gone
## (is_broken) takes all of them. Panels without is_point_open() fall back to
## a body-sized radius around the hole centre.
func _release_decals_over_holes(wall: Node, hole: Vector3) -> void:
	if not is_instance_valid(wall):
		return
	var gone: bool = wall.get(&"is_broken") == true
	var probe := wall.has_method(&"is_point_open")
	var i := 0
	while i < _live.size():
		var d = _live[i]
		var drop := false
		if is_instance_valid(d) and (d as Node).get_parent() == wall:
			var at := (d as Decal).global_position
			if gone:
				drop = true
			elif probe:
				drop = wall.call(&"is_point_open", at)
			else:
				drop = at.distance_to(hole) < HOLE_FALLBACK_RADIUS
		if drop:
			_live.remove_at(i)
			_recycle(d)
			_decals_released += 1
		else:
			i += 1

## The Destructible a ray hit, if any: the collider itself or an ancestor
## (a fracture cell may be its own body under the panel).
func _destructible_of(o: Object) -> Node3D:
	var n := o as Node
	for k in 3:
		if n == null:
			return null
		if n is Node3D and (n.is_in_group(&"destructibles") or n.has_method(&"receive_impact")):
			return n
		n = n.get_parent()
	return null


# =============================================================================
# Wounds (fighter.gdshader blood mask)
# =============================================================================

## Paint the parts near `position`. `blow_dir` (attacker -> victim) moves a point
## that lies inside a part out to the surface facing the attacker.
func _wound(fighter: Node3D, position: Vector3, amount: float, blow_dir: Vector3,
		radius_scale := 1.0) -> void:
	if not is_instance_valid(fighter):
		return
	var parts := _mesh_parts(fighter)
	if parts.is_empty():
		return
	var radius := lerpf(0.05, 0.13, clampf(amount, 0.0, 1.0)) * radius_scale
	# Rank parts by distance from the hit to their bounds.
	var best: Array[MeshInstance3D] = []
	var best_d: Array[float] = []
	for part in parts:
		if not is_instance_valid(part) or not part.is_visible_in_tree():
			continue
		var aabb := part.get_aabb()
		var s := _avg_scale(part)
		if aabb.get_longest_axis_size() * s < WOUND_MIN_PART:
			continue
		var local := part.global_transform.affine_inverse() * position
		var closest := local.clamp(aabb.position, aabb.end)
		var d := local.distance_to(closest) * s
		var at := best_d.bsearch(d)
		best.insert(at, part)
		best_d.insert(at, d)
	for k in mini(best.size(), WOUND_MAX_PARTS):
		if k > 0 and best_d[k] > radius + WOUND_REACH:
			break
		var part := best[k]
		var inv := part.global_transform.affine_inverse()
		var local := inv * position
		var aabb := part.get_aabb()
		var s := _avg_scale(part)
		var p := _surface_point(aabb, local, (inv.basis * blow_dir) if blow_dir != Vector3.ZERO else Vector3.ZERO)
		_paint(part, p, radius / s * (1.0 if k == 0 else 0.7))
	refresh_blood_level(fighter)

## Point on the box surface: points outside snap to the closest surface point;
## points inside are pushed out against `dir` when given (the side the blow
## came from), else to the nearest face.
static func _surface_point(aabb: AABB, p: Vector3, dir: Vector3) -> Vector3:
	if not aabb.has_point(p):
		return p.clamp(aabb.position, aabb.end)
	var lo := aabb.position
	var hi := aabb.end
	if dir.length_squared() > 0.000001:
		var u := -dir.normalized()
		var t := INF
		for ax in 3:
			if absf(u[ax]) > 0.00001:
				var bound: float = hi[ax] if u[ax] > 0.0 else lo[ax]
				t = minf(t, (bound - p[ax]) / u[ax])
		if t < INF:
			return p + u * t
	var best_ax := 0
	var best_side := 0.0
	var best_gap := INF
	for ax in 3:
		var g0: float = p[ax] - lo[ax]
		var g1: float = hi[ax] - p[ax]
		if g0 < best_gap:
			best_gap = g0
			best_ax = ax
			best_side = lo[ax]
		if g1 < best_gap:
			best_gap = g1
			best_ax = ax
			best_side = hi[ax]
	var q := p
	q[best_ax] = best_side
	return q

func _paint(part: MeshInstance3D, local: Vector3, local_radius: float) -> void:
	var mat := _part_material(part)
	if mat == null:
		return
	var id := part.get_instance_id()
	var st: Array = _wounds.get(id, [])
	if st.is_empty():
		var fresh: Array[Vector4] = []
		fresh.resize(WOUND_POINTS)
		fresh.fill(Vector4.ZERO)
		st = [fresh, 0, 0]
		_wounds[id] = st
	var pts: Array[Vector4] = st[0]
	var next: int = st[1]
	pts[next] = Vector4(local.x, local.y, local.z, local_radius)
	st[1] = (next + 1) % WOUND_POINTS
	st[2] = mini(int(st[2]) + 1, WOUND_POINTS)
	mat.set_shader_parameter(&"blood_points", pts)
	mat.set_shader_parameter(&"blood_count", st[2])
	mat.set_shader_parameter(&"blood_color",
			DIRT_SHADER if Tuning.gore == Tuning.Gore.OFF else BLOOD_SHADER)

## Red cut end on a severed piece's meshes.
func _paint_piece(piece: Node3D, joint: Vector3) -> void:
	for m in piece.find_children("*", "MeshInstance3D", true, false):
		var part := m as MeshInstance3D
		var local := part.global_transform.affine_inverse() * joint
		var closest := local.clamp(part.get_aabb().position, part.get_aabb().end)
		if local.distance_to(closest) * _avg_scale(part) < 0.3:
			_paint(part, local, 0.12 / _avg_scale(part))

func _flash(fighter: Node3D) -> void:
	if not is_instance_valid(fighter):
		return
	var parts := _mesh_parts(fighter)
	if parts.is_empty():
		return
	_flashing[fighter.get_instance_id()] = [parts, FLASH_TIME]
	for part in parts:
		var mat := _part_material(part)
		if mat != null:
			mat.set_shader_parameter(&"flash", 1.0)

## The part's ShaderMaterial. If two parts share one material, the second gets
## its own copy (blood points are per part, in that part's local space).
func _part_material(part: MeshInstance3D) -> ShaderMaterial:
	var m := part.material_override
	if m == null:
		m = part.get_active_material(0)
	if not (m is ShaderMaterial):
		return null
	var mid := m.get_instance_id()
	var pid := part.get_instance_id()
	var owner_id: int = _mat_owner.get(mid, 0)
	if owner_id == 0 or owner_id == pid or instance_from_id(owner_id) == null:
		_mat_owner[mid] = pid
		return m
	var dup := m.duplicate() as ShaderMaterial
	part.material_override = dup
	_mat_owner[dup.get_instance_id()] = pid
	return dup

func _mesh_parts(fighter: Node3D) -> Array[MeshInstance3D]:
	var rig: Node3D = _rig_of(fighter)
	if rig == null:
		return []
	var parts: Array[MeshInstance3D] = []
	parts.assign(rig.call(&"get_mesh_parts"))
	return parts

func _rig_of(fighter: Node) -> Node3D:
	if not is_instance_valid(fighter):
		return null
	var rig = fighter.get(&"rig")
	if rig is Node3D and is_instance_valid(rig) and (rig as Node3D).has_method(&"get_mesh_parts"):
		return rig
	return null

func _blood_level(f: Node) -> float:
	var max_hp = f.get(&"max_hp")
	var hp = f.get(&"hp")
	if max_hp == null or hp == null or float(max_hp) <= 0.0:
		return 0.0
	return clampf(1.0 - float(hp) / float(max_hp), 0.0, 1.0)

static func _avg_scale(n: Node3D) -> float:
	var s := n.global_basis.get_scale()
	return maxf((absf(s.x) + absf(s.y) + absf(s.z)) / 3.0, 0.0001)

static func _com_speed(f: Node) -> float:
	if f.has_method(&"get_com_velocity"):
		return (f.call(&"get_com_velocity") as Vector3).length()
	if f is CharacterBody3D:
		return (f as CharacterBody3D).velocity.length()
	return 0.0


# =============================================================================
# Helpers
# =============================================================================

static func _safe_dir(v: Vector3, fallback: Vector3) -> Vector3:
	return v.normalized() if v.length_squared() > 0.000001 else fallback

## Basis whose -Z points along dir.
static func _basis_toward(dir: Vector3) -> Basis:
	var up := Vector3.UP if absf(dir.y) < 0.95 else Vector3.FORWARD
	return Basis.looking_at(dir, up)

func _cone_dir(axis: Vector3, half_angle: float) -> Vector3:
	var side := axis.cross(Vector3.UP if absf(axis.y) < 0.95 else Vector3.RIGHT).normalized()
	var a := sqrt(rng.randf()) * half_angle
	return axis.rotated(side, a).rotated(axis, rng.randf() * TAU).normalized()

func _pick(list: Array[ImageTexture]) -> ImageTexture:
	return list[rng.randi_range(0, list.size() - 1)]

func _surface_color(wall: Node) -> Color:
	if is_instance_valid(wall):
		var s = wall.get(&"surface")
		if s != null:
			return DUST_BY_SURFACE.get(StringName(s), DUST_DEFAULT)
	return DUST_DEFAULT

func _check_arena() -> void:
	var a := get_tree().get_first_node_in_group(&"arena")
	var id := a.get_instance_id() if a != null else 0
	if id == _arena_id and (id == 0 or is_instance_valid(_heightfield)):
		return
	if is_instance_valid(_heightfield):
		_heightfield.queue_free()
	_heightfield = null
	_arena_id = id
	if a == null:
		return
	# Particle collision over the whole arena so droplets land on floor and walls.
	var bounds := AABB(Vector3(-20, 0, -20), Vector3(40, 6, 40))
	if a.has_method(&"get_courtyard_bounds"):
		bounds = a.call(&"get_courtyard_bounds")
	var area := bounds.grow(12.0)
	var hf := GPUParticlesCollisionHeightField3D.new()
	hf.name = "BloodHeightField"
	hf.size = Vector3(area.size.x, 14.0, area.size.z)
	hf.position = Vector3(area.get_center().x, bounds.position.y + 5.0, area.get_center().z)
	hf.resolution = GPUParticlesCollisionHeightField3D.RESOLUTION_1024
	hf.update_mode = GPUParticlesCollisionHeightField3D.UPDATE_MODE_WHEN_MOVED
	hf.heightfield_mask = Layers.VIS_WORLD
	_holder.add_child(hf)
	_heightfield = hf

## A heightfield in WHEN_MOVED mode re-renders when it moves; nudge it after a
## wall breaks so droplets stop colliding with the missing panel.
func _nudge_heightfield() -> void:
	if is_instance_valid(_heightfield):
		_hf_nudge = -_hf_nudge
		_heightfield.position.y += 0.002 * _hf_nudge


# =============================================================================
# Startup: emitters
# =============================================================================

func _build_emitters() -> void:
	# Droplets: small stretched spheres, unshaded dark red, aligned to velocity.
	var drop_mesh := SphereMesh.new()
	drop_mesh.radius = 0.011
	drop_mesh.height = 0.05
	drop_mesh.radial_segments = 6
	drop_mesh.rings = 3
	var drop_mat := StandardMaterial3D.new()
	drop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	drop_mat.vertex_color_use_as_albedo = true
	drop_mesh.material = drop_mat
	var shrink := _curve([Vector2(0.0, 1.0), Vector2(0.7, 0.9), Vector2(1.0, 0.0)])
	for i in SPRAY_POOL:
		var pm := _droplet_material(shrink)
		_sprays.append(_emitter(drop_mesh, pm, SPRAY_MAX_DROPS, 1.2, true, 0.95))
	for i in STUMP_POOL:
		var pm := _droplet_material(shrink)
		pm.spread = 9.0
		pm.initial_velocity_min = 1.0
		pm.initial_velocity_max = 3.5
		pm.emission_sphere_radius = 0.02
		var e := _emitter(drop_mesh, pm, 80, 0.9, false, 0.0)
		_stumps.append(e)
		_stump_attach.append(null)
	_stump_offset.resize(STUMP_POOL)
	_stump_dir.resize(STUMP_POOL)
	_stump_time.resize(STUMP_POOL)
	_stump_age.resize(STUMP_POOL)
	_stump_drip.resize(STUMP_POOL)
	_stump_time.fill(0.0)

	# Sparks: thin bright streaks.
	var spark_mesh := SphereMesh.new()
	spark_mesh.radius = 0.006
	spark_mesh.height = 0.07
	spark_mesh.radial_segments = 4
	spark_mesh.rings = 2
	var spark_mat := StandardMaterial3D.new()
	spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_mat.vertex_color_use_as_albedo = true
	spark_mesh.material = spark_mat
	for i in SPARK_POOL:
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(0, 0, -1)
		pm.spread = 55.0
		pm.initial_velocity_min = 3.0
		pm.initial_velocity_max = 7.0
		pm.gravity = Vector3(0, -9.0, 0)
		pm.damping_min = 2.0
		pm.damping_max = 4.0
		pm.particle_flag_align_y = true
		pm.scale_min = 0.6
		pm.scale_max = 1.3
		pm.scale_curve = shrink
		pm.color = SPARK_COLOR
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		pm.emission_sphere_radius = 0.03
		_sparks.append(_emitter(spark_mesh, pm, 20, 0.28, true, 1.0))

	# Dust: soft billboard puffs plus small chips.
	var puff_mesh := QuadMesh.new()
	puff_mesh.size = Vector2(0.55, 0.55)
	var puff_mat := StandardMaterial3D.new()
	puff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	puff_mat.vertex_color_use_as_albedo = true
	puff_mat.albedo_texture = _puff_tex
	puff_mesh.material = puff_mat
	var chip_mesh := BoxMesh.new()
	chip_mesh.size = Vector3(0.05, 0.03, 0.045)
	var chip_mat := StandardMaterial3D.new()
	chip_mat.vertex_color_use_as_albedo = true
	chip_mat.roughness = 0.95
	chip_mesh.material = chip_mat
	var grow := _curve([Vector2(0.0, 0.45), Vector2(0.3, 0.9), Vector2(1.0, 1.5)])
	var alpha_ramp := Gradient.new()
	alpha_ramp.set_color(0, Color(1, 1, 1, 0.0))
	alpha_ramp.set_color(1, Color(1, 1, 1, 0.0))
	alpha_ramp.add_point(0.08, Color(1, 1, 1, 0.75))
	alpha_ramp.add_point(0.5, Color(0.92, 0.92, 0.92, 0.4))
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = alpha_ramp
	for i in DUST_POOL:
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(0, 0, -1)
		pm.spread = 80.0
		pm.gravity = Vector3(0, -0.5, 0)
		pm.damping_min = 1.5
		pm.damping_max = 2.5
		pm.scale_min = 0.6
		pm.scale_max = 1.6
		pm.scale_curve = grow
		pm.color_ramp = ramp_tex
		pm.angle_min = 0.0
		pm.angle_max = 360.0
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		pm.emission_sphere_radius = 0.3
		_puffs.append(_emitter(puff_mesh, pm, 36, 1.8, true, 0.9))
		var cm := ParticleProcessMaterial.new()
		cm.direction = Vector3(0, 0, -1)
		cm.spread = 70.0
		cm.gravity = Vector3(0, -14.0, 0)
		cm.angular_velocity_min = -540.0
		cm.angular_velocity_max = 540.0
		cm.scale_min = 0.5
		cm.scale_max = 1.6
		cm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		cm.emission_sphere_radius = 0.25
		cm.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
		cm.collision_bounce = 0.25
		cm.collision_friction = 0.6
		cm.collision_use_scale = true
		_chips.append(_emitter(chip_mesh, cm, 28, 1.6, true, 0.95))

func _droplet_material(shrink: CurveTexture) -> ParticleProcessMaterial:
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 0, -1)
	pm.spread = 25.0
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 5.0
	pm.gravity = Vector3(0, -14.0, 0)
	pm.damping_min = 0.2
	pm.damping_max = 0.8
	pm.particle_flag_align_y = true
	pm.scale_min = 0.6
	pm.scale_max = 1.5
	pm.scale_curve = shrink
	pm.color = BLOOD_DROP
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.05
	pm.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
	pm.collision_bounce = 0.0
	pm.collision_friction = 1.0
	pm.collision_use_scale = true
	return pm

func _emitter(mesh: Mesh, pm: ParticleProcessMaterial, amount: int, lifetime: float,
		one_shot: bool, explosiveness: float) -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.amount = amount
	e.lifetime = lifetime
	e.one_shot = one_shot
	e.explosiveness = explosiveness
	e.randomness = 0.3
	e.emitting = false
	e.visible = false
	e.local_coords = false
	e.draw_pass_1 = mesh
	e.process_material = pm
	e.collision_base_size = 0.02
	e.visibility_aabb = AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16))
	e.layers = Layers.VIS_FX
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	e.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_holder.add_child(e)
	return e

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


# =============================================================================
# Startup: procedural textures (white albedo + alpha; decals tint via modulate)
# =============================================================================

func _build_textures() -> void:
	var trng := RandomNumberGenerator.new()
	trng.seed = 90210
	for i in SPLAT_VARIANTS:
		_splat_tex.append(_make_splat(trng))
	for i in SMEAR_VARIANTS:
		_smear_tex.append(_make_smear(trng))
	for i in POOL_VARIANTS:
		_pool_tex.append(_make_pool(trng))
	_puff_tex = _make_puff(trng)
	# Wet look for blood decals: AO 1, fairly low roughness, metal 0 (masked by
	# albedo alpha). Not mirror-smooth: a sky reflection washes the red out.
	var orm := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	orm.fill(Color(1.0, 0.32, 0.0, 1.0))
	_wet_orm = ImageTexture.create_from_image(orm)

## Smooth value noise on a wrapped grid (grid x grid cells), sampled at u, v in 0..1.
class _Noise:
	var g: int
	var vals := PackedFloat32Array()

	func _init(r: RandomNumberGenerator, grid: int) -> void:
		g = grid
		vals.resize(g * g)
		for i in g * g:
			vals[i] = r.randf()

	func at(u: float, v: float) -> float:
		var x := u * g
		var y := v * g
		var xi := int(floorf(x))
		var yi := int(floorf(y))
		var fx := x - xi
		var fy := y - yi
		fx = fx * fx * (3.0 - 2.0 * fx)
		fy = fy * fy * (3.0 - 2.0 * fy)
		var x0 := posmod(xi, g)
		var x1 := posmod(xi + 1, g)
		var y0 := posmod(yi, g)
		var y1 := posmod(yi + 1, g)
		var a := lerpf(vals[y0 * g + x0], vals[y0 * g + x1], fx)
		var b := lerpf(vals[y1 * g + x0], vals[y1 * g + x1], fx)
		return lerpf(a, b, fy)

static func _image_from(alpha: PackedFloat32Array, value: PackedFloat32Array, w: int, h: int) -> ImageTexture:
	var bytes := PackedByteArray()
	bytes.resize(w * h * 4)
	for i in w * h:
		var v := int(clampf(value[i], 0.0, 1.0) * 255.0)
		bytes[i * 4] = v
		bytes[i * 4 + 1] = v
		bytes[i * 4 + 2] = v
		bytes[i * 4 + 3] = int(clampf(alpha[i], 0.0, 1.0) * 255.0)
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

## Noisy radial blob with spikes and flung droplets.
func _make_splat(r: RandomNumberGenerator) -> ImageTexture:
	var S := TEX_SIZE
	var alpha := PackedFloat32Array()
	var value := PackedFloat32Array()
	alpha.resize(S * S)
	value.resize(S * S)
	var noise := _Noise.new(r, 12)
	var r0 := r.randf_range(0.32, 0.42)
	var harm_k := [2, 3, 5, 7, 11]
	var harm_a: Array[float] = []
	var harm_p: Array[float] = []
	for k in harm_k:
		harm_a.append(r.randf_range(0.04, 0.12) / sqrt(float(k)))
		harm_p.append(r.randf() * TAU)
	var spikes := r.randi_range(4, 9)
	var spike_ang: Array[float] = []
	var spike_len: Array[float] = []
	for i in spikes:
		spike_ang.append(r.randf() * TAU)
		spike_len.append(r.randf_range(0.12, 0.45))
	var px := 2.0 / S
	for y in S:
		for x in S:
			var u := (x + 0.5) / S * 2.0 - 1.0
			var v := (y + 0.5) / S * 2.0 - 1.0
			var d := sqrt(u * u + v * v)
			var th := atan2(v, u)
			var rr := 1.0
			for k in harm_k.size():
				rr += harm_a[k] * sin(harm_k[k] * th + harm_p[k])
			var spike := 0.0
			for s in spikes:
				var dth := wrapf(th - spike_ang[s], -PI, PI)
				spike = maxf(spike, spike_len[s] * exp(-dth * dth / 0.004))
			var edge := r0 * rr * (1.0 + spike) + (noise.at(u * 0.5 + 0.5, v * 0.5 + 0.5) - 0.5) * 0.06
			var i := y * S + x
			alpha[i] = clampf((edge - d) / (px * 1.2), 0.0, 1.0)
			var rim := clampf(1.0 - (edge - d) / 0.05, 0.0, 1.0)
			value[i] = 0.82 + 0.18 * noise.at(u * 2.0 + 0.5, v * 2.0 + 0.5) - 0.18 * rim
	# Droplets flung outward, elongated radially.
	for n in r.randi_range(10, 18):
		var ang := r.randf() * TAU
		var dist := r.randf_range(r0 * 1.15, 0.92)
		var rad := r.randf_range(0.012, 0.045) * (1.0 - dist * 0.5)
		var stretch := r.randf_range(1.0, 2.6)
		var cu := cos(ang) * dist
		var cv := sin(ang) * dist
		var ext := rad * stretch + px * 2.0
		var x0 := clampi(int((cu - ext + 1.0) * 0.5 * S), 0, S - 1)
		var x1 := clampi(int((cu + ext + 1.0) * 0.5 * S) + 1, 0, S - 1)
		var y0 := clampi(int((cv - ext + 1.0) * 0.5 * S), 0, S - 1)
		var y1 := clampi(int((cv + ext + 1.0) * 0.5 * S) + 1, 0, S - 1)
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var u := (x + 0.5) / S * 2.0 - 1.0 - cu
				var v := (y + 0.5) / S * 2.0 - 1.0 - cv
				var along := (u * cos(ang) + v * sin(ang)) / stretch
				var across := -u * sin(ang) + v * cos(ang)
				var dd := sqrt(along * along + across * across)
				var a := clampf((rad - dd) / (px * 1.2), 0.0, 1.0)
				var i := y * S + x
				if a > alpha[i]:
					alpha[i] = a
					value[i] = 0.78
	return _image_from(alpha, value, S, S)

## Streak along +U: a splat-like head at u ~ 0.15, a body with ragged edges and
## streaks along the motion, thinning and breaking into drops toward u = 1.
func _make_smear(r: RandomNumberGenerator) -> ImageTexture:
	var W := TEX_SIZE
	@warning_ignore("integer_division")
	var H := TEX_SIZE / 2
	var alpha := PackedFloat32Array()
	var value := PackedFloat32Array()
	alpha.resize(W * H)
	value.resize(W * H)
	var edge_n := _Noise.new(r, 14)
	var streaks := _Noise.new(r, 20)
	var blots := _Noise.new(r, 9)
	var px := 1.0 / H
	for y in H:
		for x in W:
			var u := (x + 0.5) / W
			var v := (y + 0.5) / H * 2.0 - 1.0
			# Ragged half-width: wide behind the head, narrowing along the motion.
			var width := 0.72 * (1.0 - 0.55 * smoothstep(0.12, 1.0, u)) \
					* (0.8 + 0.4 * edge_n.at(u * 1.5, 0.2 + 0.6 * (0.5 + 0.5 * signf(v))))
			var a := clampf((width - absf(v)) / (px * 1.5), 0.0, 1.0) * smoothstep(0.2, 0.26, u)
			# Streaks run along the motion (constant along u, varying across v),
			# getting more broken toward the tail.
			var st := streaks.at(0.37 + u * 0.08, v * 0.5 + 0.5)
			var gaps := lerpf(0.0, 0.5, smoothstep(0.35, 1.0, u))
			a *= lerpf(0.75, 1.0, st) * smoothstep(gaps, gaps + 0.15, st)
			# Tail breaks into blots.
			a *= lerpf(1.0, smoothstep(0.35, 0.55, blots.at(u * 2.0, v * 0.5 + 0.5)), smoothstep(0.6, 0.95, u))
			# Head: a noisy splat where the body hit.
			var hu := (u - 0.24) * 4.0
			var hd := sqrt(hu * hu + v * v)
			var hth := atan2(v, hu)
			var head_r := 0.78 * (1.0 + 0.12 * sin(3.0 * hth + 1.3) + 0.08 * sin(5.0 * hth + 0.4)) \
					+ 0.2 * (edge_n.at(0.5 + hu * 0.25, 0.5 + v * 0.25) - 0.5)
			a = maxf(a, clampf((head_r - hd) / (px * 3.0), 0.0, 1.0))
			a *= clampf((1.0 - u) / 0.06, 0.0, 1.0)
			var i := y * W + x
			alpha[i] = a * lerpf(1.0, 0.75, u)
			value[i] = 0.8 + 0.15 * u + 0.1 * (st - 0.5)
	return _image_from(alpha, value, W, H)

## Smooth round pool with a darker meniscus rim.
func _make_pool(r: RandomNumberGenerator) -> ImageTexture:
	var S := TEX_SIZE
	var alpha := PackedFloat32Array()
	var value := PackedFloat32Array()
	alpha.resize(S * S)
	value.resize(S * S)
	var noise := _Noise.new(r, 6)
	var harm_p: Array[float] = [r.randf() * TAU, r.randf() * TAU, r.randf() * TAU]
	var px := 2.0 / S
	for y in S:
		for x in S:
			var u := (x + 0.5) / S * 2.0 - 1.0
			var v := (y + 0.5) / S * 2.0 - 1.0
			var d := sqrt(u * u + v * v)
			var th := atan2(v, u)
			var edge := 0.86 * (1.0 + 0.05 * sin(2.0 * th + harm_p[0]) + 0.04 * sin(3.0 * th + harm_p[1]) \
					+ 0.03 * sin(5.0 * th + harm_p[2])) + (noise.at(u * 0.5 + 0.5, v * 0.5 + 0.5) - 0.5) * 0.035
			var i := y * S + x
			alpha[i] = clampf((edge - d) / (px * 2.0), 0.0, 1.0)
			value[i] = 0.92 - 0.3 * smoothstep(edge - 0.08, edge, d)
	return _image_from(alpha, value, S, S)

## Soft round puff for dust billboards.
func _make_puff(r: RandomNumberGenerator) -> ImageTexture:
	var S := 64
	var alpha := PackedFloat32Array()
	var value := PackedFloat32Array()
	alpha.resize(S * S)
	value.resize(S * S)
	var noise := _Noise.new(r, 6)
	for y in S:
		for x in S:
			var u := (x + 0.5) / S * 2.0 - 1.0
			var v := (y + 0.5) / S * 2.0 - 1.0
			var d := sqrt(u * u + v * v)
			var n := noise.at(u * 0.5 + 0.5, v * 0.5 + 0.5)
			var i := y * S + x
			alpha[i] = clampf(1.0 - d, 0.0, 1.0) ** 1.5 * (0.6 + 0.4 * n)
			value[i] = 0.85 + 0.15 * n
	return _image_from(alpha, value, S, S)


# =============================================================================
# Upgrade 2: limb glow, view fade, zone highlight, impact flash, dazed swirl
# =============================================================================

const LimbGlowScript := preload("res://scripts/fx/limb_glow.gd")
const BILLBOARD_ADD := preload("res://shaders/fx_billboard_add.gdshader")
const BILLBOARD_XRAY := preload("res://shaders/fx_billboard_add_xray.gdshader")

const IMPACT_POOL := 8
const IMPACT_FLASH_TIME := 0.05          ## real s: the radial flash (about 3 frames at 60 fps)
const IMPACT_RING_TIME := 0.13           ## real s: the streak ring expands and fades
const IMPACT_FLASH_SIZE := Vector2(0.3, 1.4)   ## m: weakest .. full-power hit
const IMPACT_RING_SIZE := Vector2(0.5, 2.3)    ## m
const IMPACT_FULL_ENERGY := 12000.0      ## J: a hit this strong is full power
const IMPACT_BRIGHTNESS := 2.2           ## additive strength (HDR)
const IMPACT_COLOR := Color(1.0, 0.95, 0.85)
const IMPACT_COLOR_CHARGED := Color(1.0, 0.8, 0.4)
const SWIRL_POOL := 4
const SWIRL_STARS := 3
const SWIRL_HEIGHT := 0.22        ## m above the head bone (+0.12 to the crown)
const SWIRL_RADIUS := 0.24        ## m
const SWIRL_SPEED := 5.0          ## rad/s
const SWIRL_STAR_SIZE := 0.2      ## m
const SWIRL_COLOR := Color(1.0, 0.9, 0.4)
const PLAYER_WOUND_SCALE := 1.35  ## wound radius x on the player (damage reads without the HP bar)
const PLAYER_BLOOD_SPREAD := 1.6  ## lost-HP grime spread x on the player (shows on the back, to the camera)
const STUMBLE_DUST_ENERGY := 900.0
const TRIP_DUST_ENERGY := 1800.0

var _halo_mesh: QuadMesh
var _halo_mat: ShaderMaterial
var _impact_mat: ShaderMaterial
var _impact_ring_mat: ShaderMaterial
var _star_mat: ShaderMaterial
var _glows: Array = []                    ## live LimbGlow handles
var _impact_nodes: Array[MeshInstance3D] = []
var _impact_rings: Array[MeshInstance3D] = []
var _impact_age := PackedFloat32Array()    ## real s since the flash; < 0 idle
var _impact_power := PackedFloat32Array()
var _impact_bright := PackedFloat32Array()     ## additive strength per flash
var _impact_ring_power := PackedFloat32Array() ## ring size 0..1 per flash
var _impact_tint: Array[Color] = []
var _impact_next := 0
var _swirls: Array[Node3D] = []
var _swirl_fighter: Array = []
var _swirl_time := PackedFloat32Array()   ## s left (<= 0 idle)
var _swirl_age := PackedFloat32Array()
var _swirl_next := 0
var _fade_of: Dictionary = {}             ## fighter id -> last view_fade (absent = 0)
var _fade_mats: Dictionary = {}           ## fighter id -> its parts' ShaderMaterials while faded
var _struck_frame: Dictionary = {}        ## wall id -> process frame of its last wall_struck


## Glow on one bone (attacking fist or foot for tells, charged limb). Returns a
## handle node; free it to stop early, else it ends after `duration` s of the
## fighter's own time (world time for enemies, so a tell stretches with slow
## motion like the attack it announces; player time for the player).
## duration <= 0: until freed. The handle also has set_color() and
## set_intensity().
func limb_glow(fighter: Node3D, bone: StringName, color: Color, duration: float, intensity := 1.0) -> Node3D:
	if not is_instance_valid(fighter) or not fighter.is_inside_tree():
		return null
	var rig := _rig_of(fighter)
	var attach: Node3D = null
	if rig != null and rig.has_method(&"get_attachment"):
		attach = rig.call(&"get_attachment", bone)
	var parts := _bone_parts(fighter, bone)
	var parent: Node3D = attach if attach != null else fighter
	var h: Node3D = LimbGlowScript.new()
	h.call(&"setup", self, fighter, bone, parts, color, duration, intensity, _halo_mesh, _halo_mat)
	parent.add_child(h)
	# Centre the halo on the limb's meshes (the fist, not the wrist joint).
	var center := Vector3(0, 1.3, 0) if attach == null else Vector3.ZERO
	if not parts.is_empty():
		var inv := parent.global_transform.affine_inverse()
		var sum := Vector3.ZERO
		for p in parts:
			sum += inv * (p.global_transform * p.get_aabb().get_center())
		center = sum / parts.size()
	h.position = center
	_glows.append(h)
	return h

## Live limb glows (tests, debug).
func active_glows() -> int:
	var n := 0
	for g in _glows:
		if is_instance_valid(g):
			n += 1
	return n

func _on_glow_exit(handle: Node) -> void:
	_glows.erase(handle)

## Fade a fighter that blocks the camera's view, or the player when walls push
## the camera close (0 = opaque, 1 = gone). A screen-door dither in
## fighter.gdshader (view_fade), the same look as the world blocker fade; it
## covers every mesh part with its blood and wounds, and glows and the dazed
## swirl on that fighter fade with it. Shadows stay solid. Nothing is swapped:
## materials, shadow casting and render priority never change, and 0 writes
## an exact 0. Repeated calls with the same amount return at once; while a
## fighter is faded its materials are cached, so per-call cost is one uniform
## write per part and no allocation.
func set_fighter_fade(fighter: Node3D, amount: float) -> void:
	if not is_instance_valid(fighter):
		return
	var a := clampf(amount, 0.0, 1.0)
	var id := fighter.get_instance_id()
	var old: float = _fade_of.get(id, 0.0)
	if absf(old - a) < 0.004 and (a > 0.0 or old == 0.0):
		return
	var mats: Array = _fade_mats.get(id, [])
	var rig := _rig_of(fighter)
	var count := (rig.call(&"get_mesh_parts") as Array).size() if rig != null else 0
	if mats.size() != count:  # first fade, or parts added (a stump cap after a sever)
		mats = []
		for part in _mesh_parts(fighter):
			var mat := _part_material(part)
			if mat != null:
				mats.append(mat)
		while mats.size() < count:  # parts without the fighter shader keep the count stable
			mats.append(null)
		_fade_mats[id] = mats
	for m in mats:
		if m != null:
			(m as ShaderMaterial).set_shader_parameter(&"view_fade", a)
	if a > 0.0:
		_fade_of[id] = a
	else:
		_fade_of.erase(id)
		_fade_mats.erase(id)

## Current view fade of a fighter (tests, debug).
func get_fighter_fade(fighter: Node3D) -> float:
	return float(_fade_of.get(fighter.get_instance_id(), 0.0)) if is_instance_valid(fighter) else 0.0

## Mesh parts riding one bone: HumanoidRig.get_bone_parts(), else parts tagged
## with that bone (meta "bone"), else the attachment's mesh children.
func _bone_parts(fighter: Node3D, bone: StringName) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var rig := _rig_of(fighter)
	if rig == null:
		return out
	if rig.has_method(&"get_bone_parts"):
		out.assign(rig.call(&"get_bone_parts", bone))
		return out
	for p in _mesh_parts(fighter):
		if p.has_meta(&"bone") and StringName(p.get_meta(&"bone")) == bone:
			out.append(p)
	if out.is_empty() and rig.has_method(&"get_attachment"):
		var att: Node = rig.call(&"get_attachment", bone)
		if att != null:
			for c in att.get_children():
				if c is MeshInstance3D:
					out.append(c)
	return out

# --- Impact flash (U7) -----------------------------------------------------------

## A 2-3 frame radial flash at a contact point, plus an expanding shock ring
## when `ring` (Round 5: launch tier and up, budgeted by the caller).
## Round 7: `brightness` (additive strength, IMPACT_BRIGHTNESS when < 0),
## `ring_power` (0..1 ring size, `power` when < 0) and `color` (alpha 0 = the
## default white, or the charged tint) can be set per flash.
func impact_flash(position: Vector3, power: float, charged := false, ring := true, brightness := -1.0,
		ring_power := -1.0, color := Color(0, 0, 0, 0)) -> void:
	var i := _impact_next
	_impact_next = (_impact_next + 1) % IMPACT_POOL
	_impact_age[i] = 0.0
	_impact_power[i] = clampf(power, 0.0, 1.0)
	_impact_bright[i] = brightness if brightness >= 0.0 else IMPACT_BRIGHTNESS
	_impact_ring_power[i] = clampf(ring_power if ring_power >= 0.0 else power, 0.0, 1.0)
	if color.a > 0.0:
		_impact_tint[i] = Color(color.r, color.g, color.b)
	else:
		_impact_tint[i] = IMPACT_COLOR_CHARGED if charged else IMPACT_COLOR
	var f := _impact_nodes[i]
	var r := _impact_rings[i]
	f.global_position = position
	r.global_position = position
	f.set_instance_shader_parameter(&"spin", rng.randf() * TAU)
	r.set_instance_shader_parameter(&"spin", rng.randf() * TAU)
	f.visible = true
	r.visible = ring
	_impact_ring_on[i] = ring
	_update_impact_flash(i, 0.0)

## The flash quad and ring quad used last (tests): [flash, ring].
func last_impact_nodes() -> Array[MeshInstance3D]:
	var i := (_impact_next + IMPACT_POOL - 1) % IMPACT_POOL
	return [_impact_nodes[i], _impact_rings[i]]

## Additive strength of the most recent flash (tests).
func last_impact_brightness() -> float:
	return _impact_bright[(_impact_next + IMPACT_POOL - 1) % IMPACT_POOL]

## Flashes currently showing (tests, debug).
func active_impact_flashes() -> int:
	var n := 0
	for a in _impact_age:
		if a >= 0.0:
			n += 1
	return n

func _update_impact_flashes(real_delta: float) -> void:
	for i in IMPACT_POOL:
		if _impact_age[i] < 0.0:
			continue
		_impact_age[i] += real_delta
		_update_impact_flash(i, _impact_age[i])

func _update_impact_flash(i: int, age: float) -> void:
	var p := _impact_power[i]
	var b := _impact_bright[i]
	var c := _impact_tint[i]
	var f := _impact_nodes[i]
	var r := _impact_rings[i]
	if age > IMPACT_RING_TIME:
		_impact_age[i] = -1.0
		f.visible = false
		r.visible = false
		return
	var fu := clampf(age / IMPACT_FLASH_TIME, 0.0, 1.0)
	var fs := lerpf(IMPACT_FLASH_SIZE.x, IMPACT_FLASH_SIZE.y, p) * (1.0 + 0.3 * fu)
	f.scale = Vector3(fs, fs, fs)
	f.visible = age <= IMPACT_FLASH_TIME
	f.set_instance_shader_parameter(&"tint", Color(c.r, c.g, c.b, b * (1.0 - fu * fu)))
	var ru := clampf(age / IMPACT_RING_TIME, 0.0, 1.0)
	var rs := lerpf(IMPACT_RING_SIZE.x, IMPACT_RING_SIZE.y, _impact_ring_power[i]) \
			* (0.35 + 0.65 * (1.0 - pow(1.0 - ru, 2.5)))
	r.scale = Vector3(rs, rs, rs)
	r.visible = _impact_ring_on[i]
	r.set_instance_shader_parameter(&"tint", Color(c.r, c.g, c.b, b * 0.8 * pow(1.0 - ru, 1.5)))

# --- Dazed swirl, stumble and trip dust, broken arm ---------------------------------

func _on_dazed(fighter: Node3D, duration: float) -> void:
	if not is_instance_valid(fighter):
		return
	var slot := -1
	for i in SWIRL_POOL:  # re-dazing the same fighter refreshes its swirl
		if _swirl_time[i] > 0.0 and _swirl_fighter[i] == fighter:
			slot = i
	if slot < 0:
		slot = _swirl_next
		_swirl_next = (_swirl_next + 1) % SWIRL_POOL
	_swirl_fighter[slot] = fighter
	_swirl_time[slot] = duration if duration > 0.0 else Tuning.DAZED_TIME
	_swirl_age[slot] = 0.0
	_swirls[slot].visible = true
	_place_swirl(slot)

## Dazed swirls currently showing (tests, debug).
func active_swirls() -> int:
	var n := 0
	for t in _swirl_time:
		if t > 0.0:
			n += 1
	return n

func _update_swirls(delta: float) -> void:
	for i in SWIRL_POOL:
		if _swirl_time[i] <= 0.0:
			continue
		var f = _swirl_fighter[i]
		var gone: bool = not is_instance_valid(f) or not (f as Node3D).is_inside_tree()
		if not gone and ((f.has_method(&"is_dead") and f.call(&"is_dead"))
				or (f.has_method(&"is_launched") and f.call(&"is_launched"))):
			gone = true
		_swirl_time[i] -= delta
		_swirl_age[i] += delta
		if gone or _swirl_time[i] <= 0.0:
			_swirl_time[i] = 0.0
			_swirl_fighter[i] = null
			_swirls[i].visible = false
			continue
		_place_swirl(i)

func _place_swirl(i: int) -> void:
	var f: Node3D = _swirl_fighter[i]
	var head := f.global_position + Vector3.UP * 1.7
	var rig := _rig_of(f)
	if rig != null and rig.has_method(&"get_bone_global_position"):
		head = rig.call(&"get_bone_global_position", Bones.HEAD) + Vector3.UP * 0.12
	var node := _swirls[i]
	node.global_position = head + Vector3.UP * SWIRL_HEIGHT
	var age := _swirl_age[i]
	var fade := clampf(_swirl_time[i] / 0.25, 0.0, 1.0) * clampf(age / 0.1, 0.0, 1.0) \
			* (1.0 - get_fighter_fade(f))
	for k in SWIRL_STARS:
		var star := node.get_child(k) as MeshInstance3D
		var ang := age * SWIRL_SPEED + k * TAU / SWIRL_STARS
		star.position = Vector3(cos(ang) * SWIRL_RADIUS, 0.03 * sin(age * 7.0 + k * 2.0), sin(ang) * SWIRL_RADIUS * 0.6)
		star.set_instance_shader_parameter(&"spin", age * 4.0 + k)
		star.set_instance_shader_parameter(&"tint", Color(SWIRL_COLOR.r, SWIRL_COLOR.g, SWIRL_COLOR.b, 1.4 * fade))

func _ground_of(f: Node3D) -> Vector3:
	if f.has_method(&"get_ground_position"):
		return f.call(&"get_ground_position")
	return f.global_position

func _on_stumbled(fighter: Node3D, _duration: float) -> void:
	if is_instance_valid(fighter):
		dust(_ground_of(fighter) + Vector3.UP * 0.05, DUST_BY_SURFACE[&"floor"], STUMBLE_DUST_ENERGY,
				Vector3.UP, false)

func _on_tripped(fighter: Node3D) -> void:
	if is_instance_valid(fighter):
		dust(_ground_of(fighter) + Vector3.UP * 0.05, DUST_BY_SURFACE[&"floor"], TRIP_DUST_ENERGY,
				Vector3.UP, false)

## A broken arm: a small flash and a little blood at the forearm.
func _on_arm_broken(fighter: Node3D, zone: int) -> void:
	if not is_instance_valid(fighter):
		return
	var bone: StringName = BodyZones.AIM_BONE.get(zone, Bones.R_LOWER_ARM)
	var rig := _rig_of(fighter)
	var at := fighter.global_position + Vector3.UP * 1.1
	if rig != null and rig.has_method(&"get_bone_global_position"):
		at = rig.call(&"get_bone_global_position", bone)
	impact_flash(at, 0.5)
	if Tuning.gore != Tuning.Gore.OFF:
		spray(at, Vector3.UP, 1500.0)
	_wound(fighter, at, 0.7, Vector3.ZERO)

# --- Startup / reset -------------------------------------------------------------

func _build_upgrade2() -> void:
	var trng := RandomNumberGenerator.new()
	trng.seed = 4242
	_halo_mesh = QuadMesh.new()
	_halo_mesh.size = Vector2(1, 1)
	_halo_mat = _billboard_mat(BILLBOARD_XRAY, _make_glow_tex())
	_impact_mat = _billboard_mat(BILLBOARD_XRAY, _make_flash_tex(trng))
	_impact_ring_mat = _billboard_mat(BILLBOARD_XRAY, _make_ring_tex(trng))
	_star_mat = _billboard_mat(BILLBOARD_ADD, _make_star_tex())
	_impact_age.resize(IMPACT_POOL)
	_impact_age.fill(-1.0)
	_impact_power.resize(IMPACT_POOL)
	_impact_bright.resize(IMPACT_POOL)
	_impact_bright.fill(IMPACT_BRIGHTNESS)
	_impact_ring_power.resize(IMPACT_POOL)
	_impact_ring_on.resize(IMPACT_POOL)
	for i in IMPACT_POOL:
		_impact_nodes.append(_fx_quad(_impact_mat, "ImpactFlash%d" % i, _holder))
		_impact_rings.append(_fx_quad(_impact_ring_mat, "ImpactRing%d" % i, _holder))
		_impact_tint.append(IMPACT_COLOR)
	_swirl_time.resize(SWIRL_POOL)
	_swirl_time.fill(0.0)
	_swirl_age.resize(SWIRL_POOL)
	for i in SWIRL_POOL:
		var n := Node3D.new()
		n.name = "DazedSwirl%d" % i
		n.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		n.visible = false
		_holder.add_child(n)
		for k in SWIRL_STARS:
			var star := _fx_quad(_star_mat, "Star%d" % k, n)
			star.scale = Vector3.ONE * SWIRL_STAR_SIZE
			star.visible = true
		_swirls.append(n)
		_swirl_fighter.append(null)

func _reset_upgrade2() -> void:
	for i in IMPACT_POOL:
		_impact_age[i] = -1.0
		_impact_nodes[i].visible = false
		_impact_rings[i].visible = false
	for i in SWIRL_POOL:
		_swirl_time[i] = 0.0
		_swirl_fighter[i] = null
		_swirls[i].visible = false
	_fade_of.clear()
	_fade_mats.clear()

func _billboard_mat(shader: Shader, tex: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter(&"tex", tex)
	return m

func _fx_quad(mat: Material, node_name: String, parent: Node) -> MeshInstance3D:
	var q := MeshInstance3D.new()
	q.name = node_name
	q.mesh = _halo_mesh
	q.material_override = mat
	q.layers = Layers.VIS_FX
	q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	q.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	q.visible = false
	parent.add_child(q)
	return q

## Soft round glow: bright core, long falloff.
func _make_glow_tex() -> ImageTexture:
	var S := 64
	var alpha := PackedFloat32Array()
	var value := PackedFloat32Array()
	alpha.resize(S * S)
	value.resize(S * S)
	for y in S:
		for x in S:
			var u := (x + 0.5) / S * 2.0 - 1.0
			var v := (y + 0.5) / S * 2.0 - 1.0
			var d := sqrt(u * u + v * v)
			var i := y * S + x
			alpha[i] = clampf(exp(-d * d * 7.0) * 0.9 + exp(-d * d * 40.0) * 0.6, 0.0, 1.0) * clampf((1.0 - d) * 4.0, 0.0, 1.0)
			value[i] = 1.0
	return _image_from(alpha, value, S, S)

## Radial flash: hot core with 8-12 sharp spikes.
func _make_flash_tex(r: RandomNumberGenerator) -> ImageTexture:
	var S := 128
	var alpha := PackedFloat32Array()
	var value := PackedFloat32Array()
	alpha.resize(S * S)
	value.resize(S * S)
	var spikes := r.randi_range(8, 12)
	var phase := r.randf() * TAU
	var lens: Array[float] = []
	for k in spikes:
		lens.append(r.randf_range(0.55, 1.0))
	for y in S:
		for x in S:
			var u := (x + 0.5) / S * 2.0 - 1.0
			var v := (y + 0.5) / S * 2.0 - 1.0
			var d := sqrt(u * u + v * v)
			var th := atan2(v, u) + phase
			var sector := th / TAU * spikes
			var k := posmod(int(floor(sector + 0.5)), spikes)
			var off := absf(sector - roundf(sector))
			var width := 0.09 * (1.0 - d / maxf(lens[k], 0.01))
			var spike := clampf(1.0 - off / maxf(width, 0.001), 0.0, 1.0) * clampf(1.0 - d / lens[k], 0.0, 1.0)
			var core := exp(-d * d * 30.0)
			var i := y * S + x
			alpha[i] = clampf(maxf(core, spike * 0.9) + exp(-d * d * 6.0) * 0.25, 0.0, 1.0)
			value[i] = 1.0
	return _image_from(alpha, value, S, S)

## Ring of radial streaks (a shock ring).
func _make_ring_tex(r: RandomNumberGenerator) -> ImageTexture:
	var S := 128
	var alpha := PackedFloat32Array()
	var value := PackedFloat32Array()
	alpha.resize(S * S)
	value.resize(S * S)
	var n := _Noise.new(r, 32)
	for y in S:
		for x in S:
			var u := (x + 0.5) / S * 2.0 - 1.0
			var v := (y + 0.5) / S * 2.0 - 1.0
			var d := sqrt(u * u + v * v)
			var th := atan2(v, u) / TAU + 0.5
			var streak := smoothstep(0.45, 0.75, n.at(th, 0.5))
			var band := smoothstep(0.5, 0.78, d) * (1.0 - smoothstep(0.86, 1.0, d))
			var rim := exp(-pow((d - 0.82) / 0.035, 2.0))
			var i := y * S + x
			alpha[i] = clampf(band * streak + rim * 0.55, 0.0, 1.0)
			value[i] = 1.0
	return _image_from(alpha, value, S, S)

## Four-point star for the dazed swirl.
func _make_star_tex() -> ImageTexture:
	var S := 64
	var alpha := PackedFloat32Array()
	var value := PackedFloat32Array()
	alpha.resize(S * S)
	value.resize(S * S)
	for y in S:
		for x in S:
			var u := absf((x + 0.5) / S * 2.0 - 1.0)
			var v := absf((y + 0.5) / S * 2.0 - 1.0)
			var star := clampf(1.0 - (sqrt(u) + sqrt(v)) / 1.0, 0.0, 1.0)
			var core := exp(-(u * u + v * v) * 18.0)
			var i := y * S + x
			alpha[i] = clampf(star * 2.2 + core * 0.8, 0.0, 1.0)
			value[i] = 1.0
	return _image_from(alpha, value, S, S)


# =============================================================================
# Round 5: Feel Reference (contact frame by tier, charge glow, parry,
# sidestep, splashes, floor cracks; movement effects in WorldFX)
# =============================================================================

const WorldFXScript := preload("res://scripts/fx/world_fx.gd")
const DestructionFXScript := preload("res://scripts/fx/destruction_fx.gd")
const FreeflowFXScript := preload("res://scripts/fx/freeflow_fx.gd")
const ChargeFXScript := preload("res://scripts/fx/charge_fx.gd")

## Contact frame by tier. Index = HitInfo.Tier: NONE, FLINCH, STUMBLE, STAGGER,
## KNOCKDOWN, LAUNCH, HARD_LAUNCH, SEVER. Flash size 0..1 (IMPACT_FLASH_SIZE),
## blood spray energy for the emitters (0 = no blood), wound size.
const TIER_FLASH: Array[float] = [0.12, 0.18, 0.22, 0.35, 0.5, 0.72, 0.88, 1.0]
const TIER_SPRAY: Array[float] = [0.0, 0.0, 0.0, 900.0, 2600.0, 4800.0, 7000.0, 9000.0]
const TIER_WOUND: Array[float] = [0.0, 0.0, 0.0, 0.35, 0.55, 0.75, 0.9, 1.0]
## Round 7 contact frame by HitInfo.weight (0 .. 1): flash size (0..1 of
## IMPACT_FLASH_SIZE) and additive brightness; a shock ring from R7_RING_FROM
## (the hook and up; a launch payoff always asks) sized R7_RING_POWER over
## R7_RING_FROM .. 1. A jab (0.2) flashes 0.53 m at 1.8; a roundhouse (0.85)
## 1.1 m at 3.1 with a 1.9 m ring.
const R7_FLASH_POWER := Vector2(0.05, 0.85)
const R7_FLASH_BRIGHT := Vector2(1.4, 3.4)
const R7_RING_FROM := 0.45
const R7_RING_POWER := Vector2(0.25, 1.0)
const GROUND_SPRAY := 1600.0      ## a ground strike's extra spray into the floor
const HELD_STRIKE_SPRAY := 600.0  ## a knee or headbutt on a held body: small blood (1 decal)
const WOUNDED_LEVEL := 0.05       ## lost-HP share from which a body bleeds on impacts
## Floor marks (cracks, craters, rubble) persisting at once (Round 6: Tuning.FLOOR_DECAL_MAX).
const MARK_DECAL_MAX := Tuning.FLOOR_DECAL_MAX
## Round 6 floor marks by level (1 crack, 2 crater, 3 rubble): colour; the
## size is the event's radius (Tuning.FLOOR_LEVEL_RADIUS) across.
const FLOOR_MARK_COLOR: Array[Color] = [Color(0.1, 0.095, 0.09, 0.92), Color(0.07, 0.065, 0.06, 0.96),
	Color(0.09, 0.085, 0.08, 0.98)]
## A new mark this close to an older one (share of the larger radius) grows it in place.
const FLOOR_MARK_MERGE := 0.75
const FADE_SLACK := 10            ## decals of one kind allowed to be fading at once
const CRACK_SIZE := Vector2(1.7, 2.3)  ## m: a heavy landing's floor crack
const CRACK_COLOR := Color(0.1, 0.095, 0.09, 0.92)
## Round 8: a charge glow never outlives its charge (ChargeFX.charge_glow_max():
## the longest legal charge, to full and the hold at full, plus a margin).
## Dropped on charge_released and charge_cancelled, on a hit landing on the
## charging fighter, when it dies, goes down / flies, or is grabbed.
const CHARGE_GLOW_MAX := 1.0 - Tuning.R8_TAP_MAX + Tuning.R8_CHARGE_HOLD_AT_FULL + ChargeFXScript.CHARGE_SLACK
const WATER_DROP := Color(0.78, 0.86, 0.95)

## Every contact frame: {frame (physics), tier, flash, ring, blood} (F4 check, newest last).
var contact_log: Array[Dictionary] = []
var _decals_created: Dictionary = {}   ## kind -> decals placed since reset
var _decals_evicted := 0
var _decals_released := 0
var _impact_ring_on: Array[bool] = []
var _last_ring := -INF                 ## real s of the last shock ring
var _jitter: Dictionary = {}           ## fighter id -> [parts, s left, amplitude m, offset]
var _crack_tex: ImageTexture
var _crater_tex: ImageTexture
var _rubble_tex: ImageTexture
var _world: Node
var _destruction: Node
var _freeflow: Node
var _charge: Node

func _build_round5() -> void:
	var trng := RandomNumberGenerator.new()
	trng.seed = 5150
	_crack_tex = _make_crack_tex(trng)
	_crater_tex = _make_crater_tex(trng)
	_rubble_tex = _make_rubble_tex(trng)
	_world = WorldFXScript.new()
	_world.name = "WorldFX"
	add_child(_world)
	_world.call(&"setup", self, _holder)
	_destruction = DestructionFXScript.new()
	_destruction.name = "DestructionFX"
	add_child(_destruction)
	_destruction.call(&"setup", self, _world, _holder)
	_freeflow = FreeflowFXScript.new()
	_freeflow.name = "FreeflowFX"
	add_child(_freeflow)
	_freeflow.call(&"setup", self, _world, _holder)
	# Round 8: the charge glow (by c), the pressure ticks, the break burst, the
	# dazed loop and the air combo touches live in ChargeFX.
	_charge = ChargeFXScript.new()
	_charge.name = "ChargeFX"
	add_child(_charge)
	_charge.call(&"setup", self, _world, _holder)

func _reset_round5() -> void:
	for id: int in _jitter:
		_set_jitter(_jitter[id][0], Vector3.ZERO)
	_jitter.clear()
	contact_log.clear()
	_last_ring = -INF
	if _world != null:
		_world.call(&"reset")
	if _destruction != null:
		_destruction.call(&"reset")
	if _freeflow != null:
		_freeflow.call(&"reset")
	if _charge != null:
		_charge.call(&"reset")

## The movement / world effects node (WorldFX).
func get_world_fx() -> Node:
	return _world

## The Round 6 destruction effects node (DestructionFX).
func get_destruction_fx() -> Node:
	return _destruction

## The Round 7 effects node (FreeflowFX).
func get_freeflow_fx() -> Node:
	return _freeflow

## The Round 8 effects node (ChargeFX).
func get_charge_fx() -> Node:
	return _charge

static func _real_now() -> float:
	return Engine.get_physics_frames() / float(Engine.physics_ticks_per_second)

## Budget: at most one shock ring per Tuning.FX_RING_GAP real seconds.
func _ring_allowed() -> bool:
	var now := _real_now()
	if now - _last_ring < Tuning.FX_RING_GAP - 1e-4:
		return false
	_last_ring = now
	return true

# --- Mesh jitter during the freeze (Contact frame item 2) ---------------------------

## The victim's mesh shakes HITSTOP_JITTER_RANGE (2-4 cm, more for bigger
## tiers) for its freeze: Power.hitstop_for(tier), the player's capped at
## Tuning.PLAYER_HITSTOP_MAX. Real time, like the hitstop.
## Round 7: `weight` >= 0 sizes it instead of the tier, and `hold` > 0 (the
## move's own hitstop, HitInfo.hitstop) sets how long it lasts.
func _jitter_start(victim: Node3D, tier: int, weight := -1.0, hold := -1.0) -> void:
	var t := hold if hold > 0.0 else Power.hitstop_for(tier)
	if victim.is_in_group(&"player"):
		t = minf(t, Tuning.PLAYER_HITSTOP_MAX)
	if t <= 0.0:
		return
	var parts := _mesh_parts(victim)
	if parts.is_empty():
		return
	var k := weight if weight >= 0.0 else FXRules.tier_t(tier)
	var amp := lerpf(Tuning.HITSTOP_JITTER_RANGE.x, Tuning.HITSTOP_JITTER_RANGE.y, clampf(k, 0.0, 1.0))
	_jitter[victim.get_instance_id()] = [parts, t, amp, Vector3.ZERO]

## Current jitter offset of a fighter's mesh (tests): ZERO when still.
func get_jitter(fighter: Node3D) -> Vector3:
	var rec: Array = _jitter.get(fighter.get_instance_id(), []) if is_instance_valid(fighter) else []
	return rec[3] if not rec.is_empty() else Vector3.ZERO

## Seconds of jitter left (tests).
func jitter_left(fighter: Node3D) -> float:
	var rec: Array = _jitter.get(fighter.get_instance_id(), []) if is_instance_valid(fighter) else []
	return float(rec[1]) if not rec.is_empty() else 0.0

func _update_jitter(real: float) -> void:
	if _jitter.is_empty():
		return
	for id: int in _jitter.keys():
		var rec: Array = _jitter[id]
		rec[1] = float(rec[1]) - real
		if rec[1] <= 0.0 or instance_from_id(id) == null:
			_set_jitter(rec[0], Vector3.ZERO)
			_jitter.erase(id)
			continue
		# A fresh direction every frame, mostly sideways (reads as a shudder).
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.5, 0.5), rng.randf_range(-1, 1))
		var off := _safe_dir(d, Vector3.RIGHT) * float(rec[2]) * rng.randf_range(0.7, 1.0)
		rec[3] = off
		_set_jitter(rec[0], off)

func _set_jitter(parts: Array, off: Vector3) -> void:
	for p in parts:
		if is_instance_valid(p):
			var mat := _part_material(p)
			if mat != null:
				mat.set_shader_parameter(&"jitter", off)

# --- Charge glow (Feel Reference: On the character > Charge glow) --------------------
# Round 8: the glow follows the charge amount c and lives in ChargeFX
# (scripts/fx/charge_fx.gd); these keep the older entry points.

func _drop_charge_glow(fighter: Node3D) -> void:
	if _charge != null:
		_charge.call(&"drop_charge_glow", fighter)

## The charge glow handle on a fighter (tests), or null.
func get_charge_glow(fighter: Node3D) -> Node3D:
	return _charge.call(&"get_charge_glow", fighter) if _charge != null else null

# --- Water, floor cracks ------------------------------------------------------------------

## Water droplets (feet and bodies in the water patch). Not blood: gore never hides it.
func splash(position: Vector3, direction: Vector3, energy: float) -> void:
	var dir := _safe_dir(direction, Vector3.UP)
	var e := _sprays[_spray_next]
	_spray_next = (_spray_next + 1) % _sprays.size()
	var t := clampf(energy / 6000.0, 0.0, 1.0)
	var pm := e.process_material as ParticleProcessMaterial
	pm.color = WATER_DROP
	pm.spread = lerpf(30.0, 50.0, t)
	pm.initial_velocity_min = lerpf(1.2, 3.0, t)
	pm.initial_velocity_max = lerpf(2.8, 7.0, t)
	e.amount_ratio = clampf(lerpf(0.15, 0.9, t), 0.1, 1.0)
	e.global_transform = Transform3D(_basis_toward(dir), position)
	e.visible = true
	e.restart()

## Round 6 (Feel Reference rule "things stay"; ARCHITECTURE Round 6): a floor
## mark for WorldDamage's floor_damaged, placed at once (same physics frame)
## at `position` on the floor, `radius` m. Level 1 crack, 2 crater (darker,
## wider, a rim), 3 rubble. A mark already at that spot GROWS in place (new
## texture, size and colour) instead of stacking a second decal. Marks cap at
## Tuning.FLOOR_DECAL_MAX, the oldest fading. Returns the decal.
func floor_mark(position: Vector3, radius: float, level: int, _surface := &"concrete") -> Decal:
	var lvl := clampi(level, 1, 3)
	var size := maxf(radius, 0.1) * 2.0 * rng.randf_range(0.95, 1.1)
	var tex: Texture2D = [_crack_tex, _crater_tex, _rubble_tex][lvl - 1]
	for d in _live:
		if not is_instance_valid(d) or _kind_of(d) != &"mark" or not (d as Node).has_meta(&"floor_level"):
			continue
		var dd := d as Decal
		if _fading.has(dd.get_instance_id()):
			continue
		var flat := Vector2(dd.global_position.x - position.x, dd.global_position.z - position.z).length()
		if flat < maxf(size, dd.size.x) * 0.5 * FLOOR_MARK_MERGE and absf(dd.global_position.y - position.y) < 0.3:
			if lvl >= int(dd.get_meta(&"floor_level")):
				dd.texture_albedo = tex
				var s := maxf(size, dd.size.x)
				dd.size = Vector3(s, DECAL_DEPTH, s)
				dd.modulate = FLOOR_MARK_COLOR[lvl - 1]
				dd.set_meta(&"floor_level", lvl)
			_live.erase(dd)  # the newest touch: last to fade
			_live.append(dd)
			return dd
	var nd := _place_decal(position, Vector3.UP, Vector2(size, size), tex, FLOOR_MARK_COLOR[lvl - 1], Vector3.ZERO,
			null, &"mark")
	nd.set_meta(&"floor_level", lvl)
	return nd

## Live floor marks by level (tests): [cracks, craters, rubble].
func floor_mark_levels() -> Array[int]:
	var out: Array[int] = [0, 0, 0]
	for d in _live:
		if is_instance_valid(d) and (d as Node).has_meta(&"floor_level") and not _fading.has((d as Decal).get_instance_id()):
			out[int((d as Node).get_meta(&"floor_level")) - 1] += 1
	return out

## A floor crack decal under `position`, `size` m across (scripted cracks; Round
## 6 floor damage goes through floor_mark()).
func crack(position: Vector3, size := -1.0) -> void:
	var s := size if size > 0.0 else rng.randf_range(CRACK_SIZE.x, CRACK_SIZE.y)
	_enqueue(Req.MARK, position, Vector3.DOWN, Vector3.ZERO, s, 0)

func _do_mark(space: PhysicsDirectSpaceState3D, pos: Vector3, size: float) -> int:
	var hit := _cast(space, pos + Vector3.UP * 0.5, pos + Vector3.DOWN * 2.0)
	if hit.is_empty() or (hit.normal as Vector3).y < 0.6:
		return 1
	_place_decal(hit.position, hit.normal, Vector2(size, size), _crack_tex, CRACK_COLOR, Vector3.ZERO,
			hit.collider, &"mark")
	return 1

## Radial floor cracks: a crushed centre and 8-11 jagged cracks with branches,
## stamped as tapering lines (cheap to build at startup).
func _make_crack_tex(r: RandomNumberGenerator) -> ImageTexture:
	var S := 128
	var alpha := PackedFloat32Array()
	var value := PackedFloat32Array()
	alpha.resize(S * S)
	value.resize(S * S)
	value.fill(0.85)
	var stamp := func(u: float, v: float, rad: float, a: float) -> void:
		var cx := (u * 0.5 + 0.5) * S
		var cy := (v * 0.5 + 0.5) * S
		var rp := maxf(rad * S * 0.5, 0.6)
		for y in range(maxi(int(cy - rp - 1), 0), mini(int(cy + rp + 2), S)):
			for x in range(maxi(int(cx - rp - 1), 0), mini(int(cx + rp + 2), S)):
				var d := Vector2(x + 0.5 - cx, y + 0.5 - cy).length()
				var k := clampf(rp + 0.5 - d, 0.0, 1.0) * a
				var i := y * S + x
				alpha[i] = maxf(alpha[i], k)
	# Crushed centre.
	for n in 14:
		var ang := r.randf() * TAU
		var dist := r.randf_range(0.0, 0.12)
		stamp.call(cos(ang) * dist, sin(ang) * dist, r.randf_range(0.04, 0.09), r.randf_range(0.6, 0.95))
	var cracks := r.randi_range(8, 11)
	for c in cracks:
		var ang := TAU * (float(c) + r.randf_range(-0.3, 0.3)) / cracks
		var reach := r.randf_range(0.55, 0.95)
		var p := Vector2(cos(ang), sin(ang)) * 0.08
		var dir := Vector2(cos(ang), sin(ang))
		var steps := int(reach * 60.0)
		for k in steps:
			var u := float(k) / steps
			dir = dir.rotated(r.randf_range(-0.35, 0.35)).normalized()
			dir = (dir + Vector2(cos(ang), sin(ang)) * 0.4).normalized()
			p += dir * (reach / steps)
			stamp.call(p.x, p.y, lerpf(0.022, 0.006, u), lerpf(1.0, 0.6, u))
			if r.randf() < 0.05 and u < 0.8:  # a branch
				var q := p
				var bd := dir.rotated(r.randf_range(0.5, 1.0) * (1.0 if r.randf() < 0.5 else -1.0))
				for j in int(steps * 0.3):
					bd = bd.rotated(r.randf_range(-0.3, 0.3))
					q += bd * (reach / steps)
					stamp.call(q.x, q.y, 0.006, 0.7)
	return _image_from(alpha, value, S, S)


## Crater: a dark crushed bowl with a lighter broken rim, short radial cracks
## running out of it (Round 6 floor level 2).
func _make_crater_tex(r: RandomNumberGenerator) -> ImageTexture:
	var S := 128
	var alpha := PackedFloat32Array()
	var value := PackedFloat32Array()
	alpha.resize(S * S)
	value.resize(S * S)
	var noise := _Noise.new(r, 10)
	var cracks := r.randi_range(9, 13)
	var ang: Array[float] = []
	var reach: Array[float] = []
	for c in cracks:
		ang.append(TAU * (float(c) + r.randf_range(-0.3, 0.3)) / cracks)
		reach.append(r.randf_range(0.7, 0.98))
	for y in S:
		for x in S:
			var u := (x + 0.5) / S * 2.0 - 1.0
			var v := (y + 0.5) / S * 2.0 - 1.0
			var d := sqrt(u * u + v * v)
			var th := atan2(v, u)
			var n := noise.at(u * 0.5 + 0.5, v * 0.5 + 0.5)
			var edge := 0.5 + 0.08 * (n - 0.5) * 2.0
			var bowl := clampf((edge - d) / 0.04, 0.0, 1.0)
			var rim := exp(-pow((d - edge) / 0.06, 2.0))
			var crack := 0.0
			for c in cracks:
				# A slight jag along each crack; width in texture units (continuous lines).
				var dth := absf(wrapf(th - ang[c] + 0.04 * sin(d * 13.0 + c * 1.7), -PI, PI))
				if d > edge * 0.85 and d < reach[c]:
					var w := lerpf(0.022, 0.008, (d - edge) / maxf(reach[c] - edge, 0.01))
					crack = maxf(crack, clampf(1.0 - dth * d / w, 0.0, 1.0) * (1.0 - 0.6 * d / reach[c]))
			var i := y * S + x
			alpha[i] = clampf(maxf(maxf(bowl * (0.75 + 0.25 * n), rim * 0.55), crack), 0.0, 1.0)
			# Dark bowl, lighter rim (the decal tints this value).
			value[i] = lerpf(0.55 + 0.25 * n, 1.0, rim) if bowl < 0.99 else 0.45 + 0.2 * n
	return _image_from(alpha, value, S, S)

## Rubble: the crater broken up into scattered chunks and grit around it
## (Round 6 floor level 3).
func _make_rubble_tex(r: RandomNumberGenerator) -> ImageTexture:
	var S := 128
	var base := _make_crater_tex(r).get_image()
	var alpha := PackedFloat32Array()
	var value := PackedFloat32Array()
	alpha.resize(S * S)
	value.resize(S * S)
	for y in S:
		for x in S:
			var c := base.get_pixel(x, y)
			alpha[y * S + x] = c.a
			value[y * S + x] = c.r
	for k in r.randi_range(26, 40):
		var a := r.randf() * TAU
		var dist := r.randf_range(0.15, 0.9)
		var rad := r.randf_range(0.015, 0.06) * (1.1 - dist * 0.6)
		var cx := (cos(a) * dist * 0.5 + 0.5) * S
		var cy := (sin(a) * dist * 0.5 + 0.5) * S
		var rp := rad * S * 0.5
		var shade := r.randf_range(0.5, 1.0)
		for y in range(maxi(int(cy - rp - 1), 0), mini(int(cy + rp + 2), S)):
			for x in range(maxi(int(cx - rp - 1), 0), mini(int(cx + rp + 2), S)):
				var dd := absf(x + 0.5 - cx) + absf(y + 0.5 - cy) * 0.8  # angular chips
				var k2 := clampf(rp + 0.5 - dd, 0.0, 1.0)
				var i := y * S + x
				if k2 > 0.0:
					alpha[i] = maxf(alpha[i], k2)
					value[i] = lerpf(value[i], shade, k2)
	return _image_from(alpha, value, S, S)
