class_name Fighter
extends CharacterBody3D
## A fighter: animated capsule + HumanoidRig + RagdollController + PoseAnimator
## + CombatController, driven by a controller child (PlayerController or AIBrain)
## that writes move_input / face_dir and calls combat.press()/release().
## Built entirely in code: call setup() before add_child().
## OWNER: agent B (fighter & combat). CONTRACT STUB: keep every public signature.

signal hp_changed(hp: float, max_hp: float)
signal died(fighter: Fighter)
signal focus_changed(value: float)

const TEAM_PLAYER := 0
const TEAM_ENEMY := 1

## Capsule acceleration toward the desired walking velocity (m/s^2).
const ACCEL := 40.0
const AIR_ACCEL := 8.0
## Walking speed multiplier while holding block.
const BLOCK_WALK_MULT := 0.35
## Mesh jitter during hitstop (m), applied to the victim.
const HITSTOP_JITTER := 0.03
## At most this many limbs come off one body.
const MAX_SEVERS := 2
## Capsule radius (m at width 1.0) and nominal height (m at height 1.0).
const CAPSULE_RADIUS := 0.3
const CAPSULE_HEIGHT := 1.8

var archetype: StringName = &"player"
var team: int = TEAM_PLAYER
var is_player := false
var config: Dictionary = {}   ## Tuning.ARCHETYPES[archetype]
var max_hp := 1000.0
var hp := 1000.0
var focus := 0.0

var rig: HumanoidRig
var ragdoll: RagdollController
var animator: PoseAnimator
var combat: CombatController
var brain: Node               ## PlayerController or AIBrain (set by that node)

## Movement intent, written by the controller every physics frame.
## World-space XZ, length 0..1.
var move_input := Vector3.ZERO
## Desired facing, world XZ. The fighter turns toward it at Tuning.TURN_SPEED.
var face_dir := Vector3.FORWARD

## Collision shape named "Capsule" (RagdollController toggles it).
var capsule: CollisionShape3D
var hurtboxes: Array[Hurtbox] = []
## Launches (first + relaunches) in the current flight (pursuit halving).
var flight_launches := 0
## Real time until which this fighter ignores every hit.
var invuln_until := 0.0
## Hits taken while down this time (one punt per down). Reset on recovery.
var downed_hits := 0

var _freeze_until := 0.0      ## real time; hitstop
var _jitter := 0.0            ## m; hitstop mesh jitter for the current freeze
var _rig_rest_pos := Vector3.ZERO
var _forced_velocity := Vector3.ZERO  ## dash / knockback / lunge (horizontal)
var _forced_left := 0.0               ## game seconds
var _severed := 0
var _death_info: HitInfo
var _fading := false

## Call before add_child(). Reads Tuning.ARCHETYPES[archetype_id].
func setup(archetype_id: StringName, p_team: int) -> void:
	archetype = archetype_id
	team = p_team
	is_player = p_team == TEAM_PLAYER
	config = Tuning.ARCHETYPES.get(archetype_id, Tuning.ARCHETYPES[&"grunt"])
	max_hp = config["hp"]
	hp = max_hp

func _ready() -> void:
	if config.is_empty():
		setup(archetype, team)
	add_to_group(&"fighters")
	add_to_group(&"player" if is_player else &"enemies")
	collision_layer = Layers.CAPSULE
	collision_mask = Layers.MASK_CAPSULE
	floor_snap_length = 0.25
	var app: Dictionary = config.get("appearance", {})
	var h: float = app.get("height", 1.0)
	var w: float = app.get("width", 1.0)
	face_dir = get_forward()

	capsule = CollisionShape3D.new()
	capsule.name = "Capsule"
	var shape := CapsuleShape3D.new()
	shape.radius = CAPSULE_RADIUS * lerpf(1.0, w, 0.6)
	shape.height = CAPSULE_HEIGHT * h
	capsule.shape = shape
	capsule.position = Vector3(0.0, shape.height * 0.5, 0.0)
	add_child(capsule)

	rig = HumanoidRig.new()
	rig.name = "Rig"
	add_child(rig)
	rig.build(app, config.get("mass", 70.0))
	_rig_rest_pos = rig.position

	animator = PoseAnimator.new()
	animator.name = "PoseAnimator"
	add_child(animator)
	animator.setup(rig)

	ragdoll = RagdollController.new()
	ragdoll.name = "RagdollController"
	add_child(ragdoll)
	ragdoll.setup(self, rig, animator, config.get("ragdoll", "passive") == "active")
	ragdoll.launched.connect(_on_ragdoll_launched)
	ragdoll.grounded.connect(_on_ragdoll_grounded)
	ragdoll.recovered.connect(_on_ragdoll_recovered)
	ragdoll.landed.connect(_on_ragdoll_landed)
	ragdoll.state_changed.connect(_on_ragdoll_state_changed)

	combat = CombatController.new()
	combat.name = "CombatController"
	add_child(combat)
	combat.setup(self)

	hurtboxes = Hurtbox.build_for(self, config.get("ragdoll", "passive") == "active")

	# Player: Tuning.FOCUS_START. Enemies: config "focus" (Duelist), else 0.
	focus = float(config.get("focus", Tuning.FOCUS_START if is_player else 0.0))
	GameEvents.fighter_spawned.emit(self)
	if focus > 0.0:
		focus_changed.emit(focus)
		GameEvents.focus_changed.emit(self, focus)

# --- State queries ---------------------------------------------------------
func get_state() -> int:
	return ragdoll.state if ragdoll else RagdollController.State.ANIMATED

func is_dead() -> bool:
	return hp <= 0.0

func is_launched() -> bool:
	return get_state() == RagdollController.State.LAUNCHED

## Launched, grounded or getting up.
func is_down() -> bool:
	return get_state() in [RagdollController.State.LAUNCHED, RagdollController.State.GROUNDED,
		RagdollController.State.GETUP, RagdollController.State.DEAD]

func is_invulnerable() -> bool:
	if is_dead():
		return false
	if TimeDirector.now() < invuln_until:
		return true
	if is_player and get_state() == RagdollController.State.GETUP:
		return true  # enemies get Tuning.ENEMY_GETUP_INVULN from the start of the get-up
	return combat != null and combat.is_invulnerable()

## Flinch, stagger, blockstun, held by a grab.
func is_in_hitstun() -> bool:
	if combat and combat.is_stunned():
		return true
	if combat and combat.held_by != null:
		return true
	return get_state() in [RagdollController.State.FLINCH, RagdollController.State.STAGGER]

## Can start a new action (not down, not in hitstun, not mid-move).
func can_act() -> bool:
	return not is_dead() and not is_down() and not is_in_hitstun() \
		and not (combat and (combat.is_attacking() or combat.holding != null))

## True while the physics ragdoll (not the capsule) moves this fighter.
func is_body_simulating() -> bool:
	return ragdoll != null and ragdoll.is_simulating() \
		and get_state() != RagdollController.State.FLINCH

func is_frozen() -> bool:
	return TimeDirector.now() < _freeze_until

# --- Geometry ----------------------------------------------------------------
func get_total_mass() -> float:
	if ragdoll and rig and rig.mass_kg > 0.0:
		return ragdoll.get_total_mass()
	return config.get("mass", 70.0)

func get_center_of_mass() -> Vector3:
	if ragdoll and ragdoll.is_simulating():
		return ragdoll.get_center_of_mass()
	return global_position + Vector3.UP * get_height() * 0.55

func get_com_velocity() -> Vector3:
	if ragdoll and ragdoll.is_simulating():
		return ragdoll.get_com_velocity()
	return velocity

## Facing direction, world XZ unit vector.
func get_forward() -> Vector3:
	var f := -global_basis.z
	f.y = 0.0
	return f.normalized() if f.length_squared() > 1e-6 else Vector3.FORWARD

## Body position on the floor in every state (use this for distances).
func get_ground_position() -> Vector3:
	if ragdoll and ragdoll.is_simulating():
		return ragdoll.get_ground_position()
	return global_position

## Chest-height aim point (camera framing, targeting, glint placement).
func get_aim_point() -> Vector3:
	if ragdoll and ragdoll.is_simulating():
		return ragdoll.get_center_of_mass() + Vector3.UP * 0.3
	return global_position + Vector3.UP * get_height() * 0.72

func get_height() -> float:
	return CAPSULE_HEIGHT * float(config.get("appearance", {}).get("height", 1.0))

## Height scale from the archetype appearance (1.0 = 1.8 m).
func get_height_scale() -> float:
	return float(config.get("appearance", {}).get("height", 1.0))

# --- Damage and reactions ----------------------------------------------------
## Subtract HP, emit hp_changed + GameEvents.fighter_damaged, and die at 0.
## `info` is the killing hit if any (for dismemberment / KO slow motion).
## Impact damage from ImpactResolver arrives here with source &"impact",
## info.energy = impact energy and info.hit_position = contact point.
func apply_damage(amount: float, source: StringName, info: HitInfo = null) -> void:
	if is_dead():
		# A body already at 0 HP: big impacts may still take a limb.
		_try_dismember(info)
		return
	if amount <= 0.0:
		return
	hp = maxf(hp - amount, 0.0)
	hp_changed.emit(hp, max_hp)
	GameEvents.fighter_damaged.emit(self, amount, source)
	if hp <= 0.0:
		_die(info)

## Full defender-side hit pipeline (invulnerable -> dodge -> block -> hit).
## Returns HitInfo.Result.
func take_hit(info: HitInfo) -> int:
	if combat == null:
		return HitInfo.Result.IGNORED
	return combat.receive_hit(info)

## Physical reactions (no damage). Forward to RagdollController and update combat state.
## RagdollController handles every state (a flinch on a flying body nudges the
## hit bone) and pushes the capsule back itself.
func flinch(direction: Vector3, hit_bone: StringName = &"Chest", strength := 1.0) -> void:
	if is_dead():
		return
	if not is_body_simulating():
		combat.on_reaction(HitInfo.Reaction.FLINCH, Tuning.FLINCH_TIME * clampf(strength, 0.5, 1.6))
		clear_forced_velocity()
	ragdoll.flinch(direction, hit_bone, strength)

## strength < 1 recovers on the feet; strength >= 1 makes the legs give way
## (RagdollController tips the body into LAUNCHED).
func stagger(direction: Vector3, strength := 1.0) -> void:
	if is_dead():
		return
	if not is_body_simulating() or get_state() == RagdollController.State.STAGGER:
		combat.on_reaction(HitInfo.Reaction.STAGGER, CombatController.STAGGER_TIME * clampf(strength, 0.6, 1.5))
		clear_forced_velocity()
	ragdoll.stagger(direction, strength)

func launch(velocity_change: Vector3, hit_point: Vector3, hit_bone: StringName = &"Chest") -> void:
	if combat:
		combat.on_reaction(HitInfo.Reaction.LAUNCH, 0.0)
	if is_launched():
		flight_launches += 1
	else:
		flight_launches = 1
	_forced_left = 0.0
	if rig:
		rig.position = _rig_rest_pos  # drop any hitstop jitter before the bodies take over
	ragdoll.launch(velocity_change, hit_point, hit_bone)

## Local hitstop: freeze animation, combat timers and (if ragdoll) bone velocities.
func freeze_hitstop(duration_real: float) -> void:
	if duration_real <= 0.0 or not is_inside_tree():
		return
	var until := TimeDirector.now() + duration_real
	if until <= _freeze_until:
		return
	_freeze_until = until
	if animator:
		animator.time_scale = 0.0
	if combat:
		combat.freeze_until(until)
	if ragdoll and ragdoll.is_simulating() and get_state() != RagdollController.State.FLINCH:
		ragdoll.freeze(duration_real)
	TimeDirector.real_timer(duration_real).timeout.connect(_end_freeze)

func _end_freeze() -> void:
	if not is_instance_valid(self) or not is_inside_tree():
		return
	if TimeDirector.now() + 0.02 < _freeze_until:
		return  # a longer freeze is still running (the tick poll ends it)
	_freeze_until = 0.0
	_jitter = 0.0
	if animator:
		animator.time_scale = 1.0
	if rig:
		rig.position = _rig_rest_pos

## Victim-side mesh jitter for the next freeze (call before TimeDirector.hitstop).
func set_hitstop_jitter(amount := HITSTOP_JITTER) -> void:
	_jitter = amount

## Slide the capsule at `vel` (horizontal) for `duration` game seconds, ignoring move_input.
func knockback(vel: Vector3, duration: float) -> void:
	_forced_velocity = Vector3(vel.x, 0.0, vel.z)
	_forced_left = duration

func clear_forced_velocity() -> void:
	_forced_left = 0.0
	_forced_velocity = Vector3.ZERO

## Instant teleport of the capsule (ANIMATED state only).
func teleport_to(pos: Vector3, look_dir := Vector3.ZERO) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	clear_forced_velocity()
	if look_dir.length_squared() > 1e-4:
		snap_facing(look_dir)
	reset_physics_interpolation()

## Turn to `dir` (world XZ) immediately.
func snap_facing(dir: Vector3) -> void:
	var d := Vector3(dir.x, 0.0, dir.z)
	if d.length_squared() < 1e-6:
		return
	d = d.normalized()
	face_dir = d
	rotation.y = atan2(-d.x, -d.z)

# --- Focus (player) ----------------------------------------------------------
func add_focus(amount: float) -> void:
	var old := focus
	focus = clampf(focus + amount, 0.0, Tuning.FOCUS_MAX)
	if not is_equal_approx(old, focus):
		focus_changed.emit(focus)
		GameEvents.focus_changed.emit(self, focus)

## Returns false (and spends nothing) if there is not enough.
func spend_focus(amount: float) -> bool:
	if focus + 1e-4 < amount:
		return false
	focus = maxf(focus - amount, 0.0)
	focus_changed.emit(focus)
	GameEvents.focus_changed.emit(self, focus)
	return true

# --- Lifetime ---------------------------------------------------------------
## Corpse cleanup: fade the body out over `duration`, then queue_free().
func fade_out_and_free(duration := 1.0) -> void:
	if _fading:
		return
	_fading = true
	for hb in hurtboxes:
		if is_instance_valid(hb):
			hb.set_enabled(false)
	var mats: Array[ShaderMaterial] = []
	if rig:
		for part in rig.get_mesh_parts():
			var m := _shader_material_of(part)
			if m and not mats.has(m):
				mats.append(m)
	if mats.is_empty() or duration <= 0.0:
		queue_free()
		return
	var tw := create_tween()
	tw.tween_method(func(v: float) -> void:
		for m in mats:
			m.set_shader_parameter(&"dissolve", v), 0.0, 1.0, duration)
	tw.tween_callback(queue_free)

static func _shader_material_of(mi: MeshInstance3D) -> ShaderMaterial:
	if mi == null:
		return null
	if mi.material_override is ShaderMaterial:
		return mi.material_override
	if mi.mesh:
		for s in mi.mesh.get_surface_count():
			var o := mi.get_surface_override_material(s)
			if o is ShaderMaterial:
				return o
			var sm := mi.mesh.surface_get_material(s)
			if sm is ShaderMaterial:
				return sm
	return null

## Short white flash on every body part (armor clank).
func flash_white(duration := 0.12) -> void:
	if rig == null:
		return
	var mats: Array[ShaderMaterial] = []
	for part in rig.get_mesh_parts():
		var m := _shader_material_of(part)
		if m and not mats.has(m):
			mats.append(m)
	if mats.is_empty():
		return
	var tw := create_tween()
	tw.tween_method(func(v: float) -> void:
		for m in mats:
			m.set_shader_parameter(&"flash", v), 0.9, 0.0, duration)

## Restore HP fraction (heal between waves).
func heal_fraction(fraction: float) -> void:
	if is_dead():
		return
	hp = minf(hp + max_hp * fraction, max_hp)
	hp_changed.emit(hp, max_hp)

# --- Physics -----------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if _freeze_until > 0.0 and TimeDirector.now() >= _freeze_until:
		_end_freeze()  # backstop for the real-time timer
	if combat:
		combat.physics_tick(delta)
	var frozen := is_frozen()
	if frozen and _jitter > 0.0 and rig and not is_body_simulating():
		rig.position = _rig_rest_pos + Vector3(randf_range(-1, 1), randf_range(-0.5, 0.5),
			randf_range(-1, 1)) * _jitter
	if is_dead() or (ragdoll and ragdoll.is_simulating()):
		return  # RagdollController moves the host (FLINCH/STAGGER push included).
	if frozen:
		return
	if combat and combat.held_by != null:
		velocity = Vector3.ZERO
		return  # the grabber places us every tick

	var max_speed := Tuning.WALK_SPEED if is_player else Tuning.ENEMY_WALK_SPEED
	var mult := combat.get_move_speed_mult() if combat else 1.0
	var desired := Vector3(move_input.x, 0.0, move_input.z)
	if desired.length() > 1.0:
		desired = desired.normalized()
	desired *= max_speed * mult

	var hv := Vector3(velocity.x, 0.0, velocity.z)
	if _forced_left > 0.0:
		_forced_left -= delta
		hv = _forced_velocity
	elif combat and combat.has_forced_velocity():
		var forced := combat.get_forced_velocity()
		hv = Vector3(forced.x, 0.0, forced.z)
	else:
		var a := ACCEL if is_on_floor() else AIR_ACCEL
		hv = hv.move_toward(desired, a * delta)
	velocity.x = hv.x
	velocity.z = hv.z
	if is_on_floor():
		velocity.y = minf(velocity.y, 0.0)
	else:
		velocity.y -= Tuning.GRAVITY * delta
	move_and_slide()

	# Facing.
	var allow_turn := combat.can_turn() if combat else true
	if allow_turn:
		var fd := Vector3(face_dir.x, 0.0, face_dir.z)
		if fd.length_squared() > 1e-4:
			fd = fd.normalized()
			var target_yaw := atan2(-fd.x, -fd.z)
			var rate := Tuning.TURN_SPEED * (combat.get_turn_mult() if combat else 1.0)
			rotation.y = rotate_toward(rotation.y, target_yaw, rate * delta)

	if animator:
		var local_v := global_basis.inverse() * Vector3(velocity.x, 0.0, velocity.z)
		animator.set_locomotion(local_v, max_speed)

# --- Death and dismemberment --------------------------------------------------
func _die(info: HitInfo) -> void:
	_death_info = info
	if combat:
		combat.on_death()
	var push := Vector3.ZERO
	if not is_launched() and info != null:
		var d := Vector3(info.hit_direction.x, 0.0, info.hit_direction.z)
		if d.length_squared() > 1e-4:
			push = d.normalized() * 2.5 + Vector3.UP * 0.8
	for hb in hurtboxes:
		if is_instance_valid(hb):
			hb.set_enabled(false)
	if combat:
		combat.force_reappear()
	ragdoll.kill(push)
	died.emit(self)
	GameEvents.fighter_died.emit(self, info)
	_try_dismember(info)

## Spec: Dismemberment > When a limb comes off. Only at 0 HP; the blow or the
## impact must reach Tuning.SEVER_ENERGY or be a finisher; the cut nearest the
## hit point goes.
func _try_dismember(info: HitInfo) -> void:
	if info == null or not is_dead() or rig == null:
		return
	if Tuning.gore != Tuning.Gore.DISMEMBER:
		return
	if _severed >= MAX_SEVERS:
		return
	if info.energy < Tuning.SEVER_ENERGY and not info.is_finisher:
		return
	var point := info.hit_position
	if point == Vector3.ZERO:
		point = rig.get_bone_global_position(info.hit_bone)
	var best: StringName = &""
	var best_d := INF
	for cut: StringName in Bones.CUTS:
		if rig.is_severed(cut):
			continue
		var bone: StringName = Bones.CUTS[cut]
		var d := rig.get_bone_global_position(bone).distance_to(point)
		if d < best_d:
			best_d = d
			best = cut
	if best == &"":
		return
	var piece := rig.sever(best)
	if piece != null or rig.is_severed(best):
		_severed += 1
		GameEvents.limb_severed.emit(self, best, piece)

# --- Ragdoll signal relays ------------------------------------------------------
func _on_ragdoll_launched(v: Vector3) -> void:
	velocity = Vector3.ZERO  # stale walk/dash velocity must not survive the flight
	clear_forced_velocity()
	GameEvents.fighter_launched.emit(self, v)

func _on_ragdoll_landed() -> void:
	pass

func _on_ragdoll_grounded() -> void:
	flight_launches = 0
	GameEvents.fighter_grounded.emit(self)

func _on_ragdoll_state_changed(_old: int, new_state: int) -> void:
	if new_state == RagdollController.State.GETUP and not is_player and not is_dead():
		invuln_until = maxf(invuln_until, TimeDirector.now() + Tuning.ENEMY_GETUP_INVULN)

func _on_ragdoll_recovered() -> void:
	flight_launches = 0
	downed_hits = 0
	if is_dead():
		return
	if is_player:
		invuln_until = maxf(invuln_until, TimeDirector.now() + Tuning.GETUP_INVULN)
	clear_forced_velocity()
	if combat:
		combat.force_reappear()
	face_dir = get_forward()
	GameEvents.fighter_recovered.emit(self)
