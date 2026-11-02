class_name Fighter
extends CharacterBody3D
## A fighter: animated capsule + HumanoidRig + RagdollController + PoseAnimator
## + CombatController, driven by a controller child (PlayerController or AIBrain)
## that writes move_input / face_dir and calls combat.press()/release().
## Built entirely in code: call setup() before add_child().
## OWNER: agent H (Upgrade 2; agent B before). CONTRACT STUB: keep every public signature.
##
## Upgrade 2 (agent H): crouch (hold) and jump, and player time: the player's
## velocity, gravity, jump arcs, forced velocities, turning and landing
## recovery all step by own_delta() (TimeDirector.player_delta).
##
## Round 5 (agent H, Feel Reference):
## - Per-fighter time: get_actor_time() is 0 while frozen by hitstop; a frozen
##   fighter skips movement and animation (a ragdolling one freezes through
##   RagdollController.freeze); everyone else keeps moving. The player's own
##   freeze never passes Tuning.PLAYER_HITSTOP_MAX.
## - Player time in any slow motion: TimeDirector.player_time_factor() is
##   1 / time scale, so velocity x factor, accelerations x factor^2 (stepping by
##   own_delta) and animation x factor (PoseAnimator) keep the player at real
##   speed. `velocity` holds the OWN-TIME velocity between ticks (m per player
##   second; Traversal keeps the same convention). Impulses the player gives
##   ragdolls use real_velocity(), never velocity x own_time_factor().
## - Focus (the player's meter, 0..Tuning.FOCUS_MAX bars): income only through
##   add_focus(amount, reason), never during Focus mode; this node credits the
##   player's stagger / knockdown / launch hits (GameEvents.hit_landed) and wall
##   breaks by bodies it launched (GameEvents.wall_broken_by); Defence credits
##   parries. Focus mode is a press (begin_focus): 1 bar, the world at
##   Tuning.FOCUS_SCALE for Tuning.FOCUS_MODE_TIME real s.
## - Reactions by tier (B calls them): flinch, stumble, stagger, knockdown,
##   launch, sever_limb. The player gets up Tuning.PLAYER_GETUP_AFTER after a
##   knockdown and is untouchable Tuning.PLAYER_GETUP_INVULN after.
## - Bodies stay: a foot Area3D nudges dead bodies (Layers.DEAD_BODY, which
##   capsules pass through) that a walking fighter steps into.
## - When Traversal (M) drives the player's movement, is_airborne() reads it.

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
## Mesh jitter during hitstop (m), applied to the victim. Negative = a random
## amount in Tuning.HITSTOP_JITTER_RANGE.
const HITSTOP_JITTER := -1.0
## At most this many limbs come off one body.
const MAX_SEVERS := 2
## Capsule radius (m at width 1.0) and nominal height (m at height 1.0).
const CAPSULE_RADIUS := 0.3
const CAPSULE_HEIGHT := 1.8
## get_input_intent(): stick length below this is neutral...
const INTENT_DEADZONE := 0.3
## ...and it must point within 60 degrees of facing (or of its back) to count.
const INTENT_DOT := 0.5
## Landing pose blend back to locomotion after the landing recovery (s).
const LAND_POSE_RECOVERY := 0.15
## Round 4 lock-on: walking away from the locked target (backpedal) and
## sideways (strafe) are slower than closing in (x walk speed).
const LOCK_BACK_MULT := 0.75
const LOCK_STRAFE_MULT := 0.9
## Round 5 bodies stay: the foot Area3D (Feel Reference: Bodies stay).
const FOOT_RADIUS := 0.32       ## m (x width) around the feet
const FOOT_HEIGHT := 0.4        ## m tall from the floor: low enough to touch only bodies lying down
const NUDGE_MIN_SPEED := 0.6    ## m/s: slower walkers leave bodies alone
const NUDGE_SHARE := 0.35       ## of the walker's real speed given to each bone it steps into...
const NUDGE_MAX := 1.4          ## ...at most (m/s), so a pile is shoved, never kicked across the room
const NUDGE_UP := 0.25          ## m/s upward part, so limbs roll over the feet instead of scraping
const NUDGE_COOLDOWN := 0.2     ## real s between nudges of the same bone

var archetype: StringName = &"player"
var team: int = TEAM_PLAYER
var is_player := false
var config: Dictionary = {}   ## Tuning.ARCHETYPES[archetype]
var max_hp := 1000.0
var hp := 1000.0
## Focus bars (0..Tuning.FOCUS_MAX). Assigning it (J sets the wave's starting
## bars) emits focus_changed; gains go through add_focus().
var focus: float:
	get:
		return _focus
	set(value):
		_set_focus(value)

var rig: HumanoidRig
var ragdoll: RagdollController
var animator: PoseAnimator
var combat: CombatController
var brain: Node               ## PlayerController or AIBrain (set by that node)
# Round 5 modules (contract): every fighter has Defence (H) and Carry (G);
# only the player has Traversal (M).
var defence: Defence
var carry: Carry
var traversal: Traversal

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
## Real seconds of the last hitstop freeze this fighter took (after the player's cap).
var last_freeze := 0.0

var _focus := 0.0
var _freeze_until := 0.0      ## real time; hitstop
var _jitter := 0.0            ## m; hitstop mesh jitter for the current freeze
var _rig_rest_pos := Vector3.ZERO
var _forced_velocity := Vector3.ZERO  ## dash / knockback / lunge (horizontal)
var _forced_left := 0.0               ## own-time seconds
var _forced_stop := false             ## the knockback ends dead (knockback(..., stop))
var _severed := 0
var _death_info: HitInfo
var _fading := false

# Upgrade 2 (agent H): crouch, jump, Focus.
## Crouch button held (written by the controller through set_crouch_input()).
var crouch_input := false
## Round 4: the player's lock-on target (PlayerController copies it from the
## camera rig every tick; null = free camera). Walking slows by direction to it.
var lock_target: Fighter
## Facing turn-rate cap (rad/s), written by the controller (lock-on); INF = none.
var max_turn_rate := INF
var _crouching := false
var _airborne := false        ## jumping (capsule in the air by choice)
var _air_time := 0.0          ## player s since take-off
var _takeoff_speed := 0.0     ## m/s horizontal at take-off (a running jump keeps it)
var _land_left := 0.0         ## player s of landing recovery left
var _focusing := false
var _focus_left := 0.0        ## real s of Focus mode left
var _hang_left := 0.0         ## player s of pursuit hang left (Fighter's own movement)
var _traversal_driving := false  ## Traversal moved the capsule on its last tick
var _feet: Area3D
var _nudged := {}             ## bone instance id -> real time it may be nudged again

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
	_build_feet(lerpf(1.0, w, 0.6))

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

	defence = Defence.new()
	defence.name = "Defence"
	add_child(defence)
	defence.setup(self)
	carry = Carry.new()
	carry.name = "Carry"
	add_child(carry)
	carry.setup(self)
	if is_player:
		traversal = Traversal.new()
		traversal.name = "Traversal"
		add_child(traversal)
		traversal.setup(self)

	hurtboxes = Hurtbox.build_for(self, config.get("ragdoll", "passive") == "active")

	# Player: Tuning.FOCUS_WAVE_START (J resets it every wave). Enemies: config "focus" (Duelist), else 0.
	_focus = clampf(float(config.get("focus", Tuning.FOCUS_WAVE_START if is_player else 0.0)), 0.0, Tuning.FOCUS_MAX)
	if is_player:
		# A KO slow motion or a round reset ends Focus on TimeDirector's side.
		TimeDirector.focus_changed.connect(_on_time_focus_changed)
		GameEvents.hit_landed.connect(_on_hit_landed)
		GameEvents.wall_broken_by.connect(_on_wall_broken_by)
	GameEvents.fighter_spawned.emit(self)
	if _focus > 0.0:
		focus_changed.emit(_focus)
		GameEvents.focus_changed.emit(self, _focus)

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
	if defence != null and defence.is_vanished():
		return true
	if is_player and get_state() == RagdollController.State.GETUP:
		return true  # enemies get Tuning.ENEMY_GETUP_INVULN from the start of the get-up
	return combat != null and combat.is_invulnerable()

## Flinch, stagger, blockstun, held by a grab.
func is_in_hitstun() -> bool:
	if combat and combat.is_stunned():
		return true
	if is_held():
		return true
	return get_state() in [RagdollController.State.FLINCH, RagdollController.State.STAGGER]

## Can start a new action (not down, not in hitstun, not mid-move, not in a
## grab, a hold or a throw (Carry), not in jump landing recovery).
func can_act() -> bool:
	return not is_dead() and not is_down() and not is_in_hitstun() and _land_left <= 0.0 \
		and not (combat and combat.is_attacking()) and not (carry and carry.is_busy())

## Held by a grabber (Carry).
func is_held() -> bool:
	return carry != null and carry.is_held()

## Holding a body or a prop (Carry).
func is_holding() -> bool:
	return carry != null and carry.is_holding()

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

## Round 5 (Feel Reference: Time, in code > Collisions during slow motion):
## this fighter's velocity at real speed, the one to use for any impulse it
## gives a ragdoll, a prop or debris (B: strike pushes; G: throws and carries;
## M: Battering Ram). In slow motion the player's capsule moves 1 / time scale
## faster in game time to keep real speed; using that scaled velocity would make
## every Focus-mode hit 3.3x too strong. Between ticks `velocity` already holds
## the own-time (real-speed) value, so never multiply it by own_time_factor().
## A ragdolling body reports its centre-of-mass velocity.
func real_velocity() -> Vector3:
	if is_body_simulating():
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
## `info` is the killing hit if any (KO slow motion, death push).
## Impact damage from ImpactResolver arrives here with source &"impact",
## info.energy = impact energy and info.hit_position = contact point.
## Round 5: limbs come off only on a severing launch (sever_limb, P >= 9), never
## from damage on a body at 0 HP.
func apply_damage(amount: float, source: StringName, info: HitInfo = null) -> void:
	if is_dead() or amount <= 0.0:
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
## Flinch tier: the hit chain only; can act again after Tuning.REACT_FLINCH.act.
func flinch(direction: Vector3, hit_bone: StringName = &"Chest", strength := 1.0) -> void:
	if is_dead():
		return
	if not is_body_simulating():
		combat.on_reaction(HitInfo.Reaction.FLINCH,
			float(Tuning.REACT_FLINCH["act"]) * clampf(strength, 0.5, 1.6))
		clear_forced_velocity()
	ragdoll.flinch(direction, hit_bone, strength)

## Stagger tier: spine and up, both arms reel; the legs stay animated (it never
## turns into a launch by itself); can act again after Tuning.REACT_STAGGER.act.
## `strength` scales the reel (RagdollController).
func stagger(direction: Vector3, strength := 1.0) -> void:
	if is_dead():
		return
	if not is_body_simulating() or get_state() == RagdollController.State.STAGGER:
		combat.on_reaction(HitInfo.Reaction.STAGGER, float(Tuning.REACT_STAGGER["act"]))
		clear_forced_velocity()
	ragdoll.stagger(direction, strength)

func launch(velocity_change: Vector3, hit_point: Vector3, hit_bone: StringName = &"Chest") -> void:
	if combat:
		combat.on_reaction(HitInfo.Reaction.LAUNCH, 0.0)
	end_focus()  # getting launched ends Focus
	_leave_stance()
	if is_launched():
		flight_launches += 1
	else:
		flight_launches = 1
	_forced_left = 0.0
	if rig:
		rig.position = _rig_rest_pos  # drop any hitstop jitter before the bodies take over
	ragdoll.launch(velocity_change, hit_point, hit_bone)
	if is_player:
		ragdoll.set_getup_after(Tuning.PLAYER_GETUP_AFTER)

# --- Round 5 reactions (contract; H implements, B calls by tier) ---------------
## Sweep tier: the hit leg buckles from the knee down, 2-3 stumble steps; can
## act again after Tuning.REACT_STUMBLE.act. A body already down only takes a nudge.
func stumble(direction: Vector3, leg_bone: StringName = Bones.L_LOWER_LEG) -> void:
	if is_dead():
		return
	if is_down():
		ragdoll.flinch(direction, leg_bone, 0.5)
		return
	if not is_body_simulating():
		clear_forced_velocity()
		var act := float(Tuning.REACT_STUMBLE["act"])
		if combat:
			if combat.has_method(&"apply_stumble"):
				combat.apply_stumble(act)  # cancels the move, stun kind STUMBLE, GameEvents.stumbled
			else:
				combat.on_reaction(HitInfo.Reaction.STAGGER, act)
	ragdoll.stumble(direction, leg_bone)

## Knockdown tier: full body, low tone, drops in place; gets up after
## Tuning.REACT_KNOCKDOWN.ground (the player after Tuning.PLAYER_GETUP_AFTER,
## then untouchable for Tuning.PLAYER_GETUP_INVULN).
func knockdown(direction: Vector3, hit_bone: StringName = &"Chest") -> void:
	if is_dead():
		return
	if combat:
		combat.on_reaction(HitInfo.Reaction.LAUNCH, 0.0)
	end_focus()
	_leave_stance()
	if is_launched():
		flight_launches += 1
	else:
		flight_launches = 1
	_forced_left = 0.0
	if rig:
		rig.position = _rig_rest_pos
	ragdoll.knockdown(direction, hit_bone)
	if is_player:
		ragdoll.set_getup_after(Tuning.PLAYER_GETUP_AFTER)  # the fast, fair player get-up

## Severing launch: take limb `cut` (a Bones.CUTS key; Round 5 strikes take
## &"arm_l", &"arm_r", &"leg_l", &"leg_r"). true if it came off. The rig hides
## the limb, caps the stump and throws the loose limb at the bone's speed (A);
## here: the gore setting, the player keeps his limbs, at most MAX_SEVERS per
## body, the lost bones' hurtboxes switch off, GameEvents.limb_severed (blood,
## sound, slow time). B adds Tuning.LIMB_LOST_DAMAGE.
func sever_limb(cut: StringName) -> bool:
	if rig == null or is_player or not Bones.CUTS.has(cut):
		return false
	if Tuning.gore != Tuning.Gore.DISMEMBER or _severed >= MAX_SEVERS:
		return false
	if rig.is_severed(cut) or rig.is_bone_severed(Bones.CUTS[cut]):
		return false
	var piece := rig.sever(cut)
	if piece == null and not rig.is_severed(cut):
		return false
	_severed += 1
	for hb in hurtboxes:
		if is_instance_valid(hb) and rig.is_bone_severed(hb.bone):
			hb.set_enabled(false)
	GameEvents.limb_severed.emit(self, cut, piece)
	return true

## Limbs lost so far (Bones.CUTS keys, in order).
func get_lost_limbs() -> Array[StringName]:
	var out: Array[StringName] = []
	if rig == null:
		return out
	for cut: StringName in Bones.CUTS:
		if rig.is_severed(cut):
			out.append(cut)
	return out

## Lost an arm (whole arm or forearm): fights one-handed or limps away (C).
func has_lost_arm() -> bool:
	return rig != null and (rig.is_bone_severed(Bones.L_LOWER_ARM) or rig.is_bone_severed(Bones.R_LOWER_ARM))

## Lost a leg (whole leg or shin): crawls (C).
func has_lost_leg() -> bool:
	return rig != null and (rig.is_bone_severed(Bones.L_LOWER_LEG) or rig.is_bone_severed(Bones.R_LOWER_LEG))

## 1 normally, 0 while frozen by hitstop. Scales this fighter's animation,
## movement and frame timers (on top of the player's time factor).
func get_actor_time() -> float:
	return 0.0 if is_frozen() else 1.0

## Lost a limb and limping or crawling away (C's brain decides).
func is_fleeing() -> bool:
	return brain != null and brain.has_method(&"is_fleeing") and brain.is_fleeing()

## Heavy fighters (Battering Ram "heavy" column, 80% launch speed, no sidestep).
func is_heavy() -> bool:
	return bool(config.get("heavy", false)) or float(config.get("mass", 70.0)) >= Tuning.HEAVY_MASS

## Local hitstop: freeze animation, movement, combat timers and (if ragdoll)
## bone velocities of this fighter only. The player's own freeze is capped at
## Tuning.PLAYER_HITSTOP_MAX (Feel Reference: Contact frame); the victim keeps
## its full freeze.
func freeze_hitstop(duration_real: float) -> void:
	if is_player:
		duration_real = minf(duration_real, Tuning.PLAYER_HITSTOP_MAX)
	if duration_real <= 0.0 or not is_inside_tree():
		return
	var until := TimeDirector.now() + duration_real
	if until <= _freeze_until:
		return
	_freeze_until = until
	last_freeze = duration_real
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
## The default picks Tuning.HITSTOP_JITTER_RANGE.
func set_hitstop_jitter(amount := HITSTOP_JITTER) -> void:
	if amount < 0.0:
		amount = randf_range(Tuning.HITSTOP_JITTER_RANGE.x, Tuning.HITSTOP_JITTER_RANGE.y)
	_jitter = amount

## Slide the capsule at `vel` (horizontal) for `duration` seconds of this
## fighter's time (own_delta), ignoring move_input. `stop`: the slide ends
## dead (no deceleration tail), so it covers exactly vel x duration (sidestep).
func knockback(vel: Vector3, duration: float, stop := false) -> void:
	_forced_velocity = Vector3(vel.x, 0.0, vel.z)
	_forced_left = duration
	_forced_stop = stop

func clear_forced_velocity() -> void:
	_forced_left = 0.0
	_forced_velocity = Vector3.ZERO
	_forced_stop = false

## Traversal (M): this tick's knockback velocity (own time), stepping its timer
## by `pdt` (player s); Vector3.INF when none is running.
func consume_knockback(pdt: float) -> Vector3:
	if _forced_left <= 0.0:
		return Vector3.INF
	_forced_left -= pdt
	return _forced_velocity

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

## Pursuit (Defence): hold the capsule in the air, no gravity, for up to
## `duration_real` player s or until an attack starts. Traversal does it while
## it drives the player; Fighter's own movement does it otherwise.
func hang(duration_real: float) -> void:
	velocity = Vector3.ZERO
	_land_left = 0.0
	if traversal != null and _traversal_driving:
		_hang_left = 0.0
		traversal.hang(duration_real)  # Traversal's HANG mode (its jump state stays its own)
		return
	_hang_left = maxf(duration_real, 0.0)
	_airborne = true
	_air_time = 0.0
	_takeoff_speed = 0.0
	if traversal != null:
		traversal.hang(duration_real)

## Hanging in the air for a pursuit follow-up.
func is_hanging() -> bool:
	if _traversal_driving and traversal != null:
		return traversal.has_method(&"is_hanging") and bool(traversal.call(&"is_hanging"))
	return _hang_left > 0.0

## Drop any jump, hang and landing state (a teleport puts the fighter on the floor).
func reset_air_state() -> void:
	_airborne = false
	_air_time = 0.0
	_takeoff_speed = 0.0
	_land_left = 0.0
	_hang_left = 0.0
	_apply_stance()

# --- Upgrade 2 contract (agent H) -----------------------------------------------
## Body zone and bone the player aims at on the soft target (BodyZones), set
## every tick by the player's ZoneAim. Enemies keep TORSO.
var aim_zone: int = BodyZones.Zone.TORSO
var aim_bone: StringName = Bones.CHEST
## Round 4: the fighter aim_zone / aim_bone are on (null = none).
var aim_target: Fighter

## Zone a strike or grab by this fighter takes on `victim`: the aimed zone only
## on the aimed target, else the torso. Crouch (legs) and a jump (head) set the
## height on anyone.
func zone_for(victim: Node3D) -> int:
	if _crouching:
		return BodyZones.Zone.LEGS
	if is_airborne() and not is_hanging():
		return BodyZones.Zone.HEAD
	if victim != null and victim == aim_target:
		return aim_zone
	return BodyZones.Zone.TORSO

## Bone a strike aims at / a limb grab anchors to on `victim` (see zone_for()).
func aim_bone_for(victim: Node3D) -> StringName:
	var zone := zone_for(victim)
	if victim != null and victim == aim_target and zone == aim_zone:
		return aim_bone
	return BodyZones.AIM_BONE.get(zone, Bones.CHEST)

## Crouching: capsule at Tuning.CROUCH_HEIGHT, walking at Tuning.CROUCH_SPEED.
func is_crouching() -> bool:
	return _crouching

## In the air by choice (jump, wall kick-off, pursuit hang): Traversal's state
## while it drives the player. Launched ragdolls are is_launched(), not this.
func is_airborne() -> bool:
	if is_body_simulating():
		return false
	if _traversal_driving and traversal != null:
		return traversal.is_airborne()
	return _airborne

## Traversal (M) moved the player's capsule on its last tick.
func is_traversal_driving() -> bool:
	return _traversal_driving

## &"forward", &"back" or &"neutral" (B: back + Kick is the sweep, back + P).
## The player: the stick against the camera (Feel Reference: Controls, "back"
## is toward the camera: S, or the stick pulled down), from PlayerController.
## Everyone else: move_input against facing.
func get_input_intent() -> StringName:
	if brain != null and brain.has_method(&"get_input_intent"):
		return brain.call(&"get_input_intent")
	var s := Vector3(move_input.x, 0.0, move_input.z)
	if s.length() < INTENT_DEADZONE:
		return &"neutral"
	var d := s.normalized().dot(get_forward())
	if d >= INTENT_DOT:
		return &"forward"
	if d <= -INTENT_DOT:
		return &"back"
	return &"neutral"

## In the landing recovery after a jump (Traversal's landing pause while it
## drives the player; an attack cuts that pause short, so can_act() ignores it).
func is_landing() -> bool:
	if _traversal_driving and traversal != null and traversal.has_method(&"is_landing"):
		return bool(traversal.call(&"is_landing"))
	return _land_left > 0.0

# --- Player time (Upgrade 2: Focus; Round 5: every slow motion) -------------------
## This fighter's share of a physics delta: the player's runs in player time
## (TimeDirector.player_delta: real time in any slow motion); everyone else's
## in game time.
func own_delta(delta: float) -> float:
	return TimeDirector.player_delta(delta) if is_player else delta

## Player seconds per game second: 1, except the player in slow motion.
func own_time_factor() -> float:
	return maxf(TimeDirector.player_time_factor(), 0.01) if is_player else 1.0

# --- Crouch and jump (Upgrade 2; Round 5 numbers for the player) --------------------
## Take-off speed of the player's jump: Tuning.JUMP_HEIGHT under
## Tuning.PLAYER_GRAVITY (4.85 m/s; Traversal raises it toward
## Tuning.JUMP_HEIGHT_SPRINT at full speed). Enemies: Tuning.JUMP_APEX under Tuning.GRAVITY.
static func jump_speed(player := true) -> float:
	if player:
		return sqrt(2.0 * Tuning.PLAYER_GRAVITY * Tuning.JUMP_HEIGHT)
	return sqrt(2.0 * Tuning.GRAVITY * Tuning.JUMP_APEX)

## Hold-crouch input from the controller. Applied at once when allowed, so an
## attack pressed on the same tick (crouch + kick = sweep) already sees it.
func set_crouch_input(on: bool) -> void:
	crouch_input = on
	_update_crouch()

## Jump now if able (on the floor, free or charging: a jump keeps the charge).
## Returns true on take-off. A crouch stands up first (if there is headroom).
## The player's jump is Traversal.jump() while Traversal has one.
## The player's height follows Traversal.sprint_charge (1.2 m standing, 1.5 m at
## full speed); horizontal velocity is kept exactly.
func jump() -> bool:
	if is_player and traversal != null and traversal.has_method(&"jump"):
		return bool(traversal.call(&"jump"))  # Traversal owns the player's jump state
	if not can_jump():
		return false
	if _crouching:
		if not _has_headroom():
			return false
		_set_crouch(false)
	_airborne = true
	_air_time = 0.0
	_takeoff_speed = Vector2(velocity.x, velocity.z).length()
	if is_player:
		var charge := clampf(traversal.sprint_charge, 0.0, 1.0) if traversal != null else 0.0
		var height := lerpf(Tuning.JUMP_HEIGHT, Tuning.JUMP_HEIGHT_SPRINT, charge)
		velocity.y = sqrt(2.0 * Tuning.PLAYER_GRAVITY * height)
	else:
		velocity.y = jump_speed(false)
	GameEvents.jumped.emit(self)
	_apply_stance()
	return true

func can_jump() -> bool:
	if is_dead() or _airborne or _land_left > 0.0 or is_frozen() or not is_on_floor():
		return false
	if get_state() != RagdollController.State.ANIMATED:
		return false
	if combat == null:
		return true
	if is_held() or combat.is_stunned() or combat.is_dashing():
		return false
	if carry != null and carry.is_busy() and not carry.is_holding():
		return false  # reaching or throwing (a held body jumps along: Carry)
	return combat.is_charging() or not combat.is_attacking()

func _can_crouch() -> bool:
	if is_dead() or is_airborne() or capsule == null:
		return false
	if not (get_state() in [RagdollController.State.ANIMATED, RagdollController.State.FLINCH,
			RagdollController.State.STAGGER]):
		return false
	return not is_held() and not is_holding()

func _update_crouch() -> void:
	var want := crouch_input and _can_crouch()
	if want == _crouching:
		return
	if want:
		_set_crouch(true)
	elif not _can_crouch() or _has_headroom():
		_set_crouch(false)

## Room to stand up from a crouch (a crouch under a low gap stays down).
func _has_headroom() -> bool:
	if not _crouching or not is_inside_tree() or capsule.disabled:
		return true
	var rise := (CAPSULE_HEIGHT - Tuning.CROUCH_HEIGHT) * get_height_scale()
	return not test_move(global_transform, Vector3.UP * rise)

func _set_crouch(on: bool) -> void:
	_crouching = on
	var shape := capsule.shape as CapsuleShape3D
	shape.height = (Tuning.CROUCH_HEIGHT if on else CAPSULE_HEIGHT) * get_height_scale()
	capsule.position.y = shape.height * 0.5
	GameEvents.crouch_changed.emit(self, on)
	_apply_stance()

## Round 4 lock-on: split the walk intent into toward/away from the locked
## target and sideways, and slow the backpedal and the strafe.
func _lock_scaled(desired: Vector3) -> Vector3:
	if lock_target == null or not is_instance_valid(lock_target) or desired.length_squared() < 1e-6:
		return desired
	var to := lock_target.get_ground_position() - global_position
	to.y = 0.0
	if to.length_squared() < 1e-4:
		return desired
	to = to.normalized()
	var along := desired.dot(to)
	var side := desired - to * along
	return to * along * (LOCK_BACK_MULT if along < 0.0 else 1.0) + side * LOCK_STRAFE_MULT

## Capsule height now (crouch-aware); get_height() stays the standing height.
func get_capsule_height() -> float:
	return (capsule.shape as CapsuleShape3D).height if capsule else get_height()

## Landing. The player never falls over from a jump (Feel Reference: Landing has
## levels): a soft landing keeps running with no recovery; a hard one crouches
## Tuning.LAND_HARD_CROUCH; a heavy one Tuning.LAND_HEAVY_TIME (Traversal adds
## the effects and the shockwave while it drives). Enemies keep the Upgrade 2
## landing recovery.
func _land(vertical_speed := 0.0) -> void:
	_airborne = false
	_air_time = 0.0
	_takeoff_speed = 0.0
	_hang_left = 0.0
	if is_player:
		var vs := absf(vertical_speed)
		_land_left = 0.0
		if vs >= Tuning.LAND_HEAVY_SPEED:
			_land_left = Tuning.LAND_HEAVY_TIME
		elif vs >= Tuning.LAND_HARD_SPEED:
			_land_left = Tuning.LAND_HARD_CROUCH
	else:
		_land_left = Tuning.frames(Tuning.JUMP_LAND_FRAMES)
	GameEvents.landed.emit(self)
	if animator and _land_left > 0.0 and not (combat and combat.is_attacking()):
		animator.play_move(&"land", 0.0, _land_left, LAND_POSE_RECOVERY)
	_update_crouch()  # still holding crouch: duck on landing
	_apply_stance()

## Launch, death, grab: no jump, no crouch (capsule back to full height), no landing.
func _leave_stance() -> void:
	_airborne = false
	_air_time = 0.0
	_land_left = 0.0
	_hang_left = 0.0
	if _crouching:
		_set_crouch(false)
	_apply_stance()

func _apply_stance() -> void:
	if animator:
		# Vertical speed times exactly when jump_rise blends into jump_fall.
		animator.set_stance(&"air" if _airborne else (&"crouch" if _crouching else &"stand"), velocity.y)

# --- Focus (player) ----------------------------------------------------------
## In Focus mode: the world runs at Tuning.FOCUS_SCALE, the player at full speed.
func is_focusing() -> bool:
	return _focusing

## Real seconds of Focus mode left (0 when off).
func get_focus_time_left() -> float:
	return _focus_left if _focusing else 0.0

## The player's Focus button (a press, Round 5): costs Tuning.FOCUS_MODE_COST
## (a full bar) and runs Focus mode for Tuning.FOCUS_MODE_TIME real s (a pause
## does not count). A press while it runs does nothing. Returns true when Focus
## mode is (now) on.
func begin_focus() -> bool:
	if _focusing:
		return true
	if not is_player or is_dead() or is_down():
		return false
	if _focus + 1e-4 < Tuning.FOCUS_MODE_COST:
		return false
	if not TimeDirector.begin_focus():
		return false
	spend_focus(Tuning.FOCUS_MODE_COST)
	_focusing = true
	_focus_left = Tuning.FOCUS_MODE_TIME
	GameEvents.focus_started.emit(self)
	return true

## Ends Focus mode (time up, knocked down, launched, dead, input off). Safe to call any time.
func end_focus() -> void:
	if not _focusing:
		return
	_focusing = false
	_focus_left = 0.0
	TimeDirector.end_focus()
	GameEvents.focus_ended.emit(self)

## TimeDirector ended Focus itself (KO slow motion, round reset).
func _on_time_focus_changed(active: bool) -> void:
	if active or not _focusing:
		return
	_focusing = false
	_focus_left = 0.0
	GameEvents.focus_ended.emit(self)

## Focus mode's clock: one physics tick of real time per tick, so a paused
## tree (where this does not run) costs nothing.
func _tick_focus() -> void:
	if not _focusing:
		return
	if is_dead() or not TimeDirector.is_focus_active():
		end_focus()
		return
	_focus_left -= 1.0 / float(Engine.physics_ticks_per_second)
	if _focus_left <= 1e-6:
		end_focus()

## Focus income (Feel Reference: Focus). reason is a Tuning.FOCUS_GAIN key:
## &"parry" (Defence), &"stagger", &"knockdown", &"launch" (this node, from the
## player's hits), &"wall_break" (this node, from bodies the player launched).
## Nothing is gained during Focus mode. Any other reason (&"" ...) is a plain
## grant (debug, tests, the Duelist's script) under the same rule. Negative
## amounts spend.
func add_focus(amount: float, _reason: StringName = &"") -> void:
	if amount > 0.0 and _focusing:
		return  # nothing refills during Focus mode
	_set_focus(_focus + amount)

## Returns false (and spends nothing) if there is not enough.
func spend_focus(amount: float) -> bool:
	if _focus + 1e-4 < amount:
		return false
	_set_focus(maxf(_focus - amount, 0.0))
	return true

func _set_focus(value: float) -> void:
	var v := clampf(value, 0.0, Tuning.FOCUS_MAX)
	if absf(v - _focus) < 1e-6:
		return
	_focus = v
	focus_changed.emit(_focus)
	if is_inside_tree():
		GameEvents.focus_changed.emit(self, _focus)

## The player's hits that stagger, knock down or launch an enemy earn Focus.
func _on_hit_landed(info: HitInfo) -> void:
	if info == null or info.attacker != self or info.result != HitInfo.Result.HIT:
		return
	var v := info.victim as Fighter
	if v == null or v == self or v.team == team:
		return
	var tier := info.tier
	if tier == HitInfo.Tier.NONE:
		# A source that has not set a tier yet: read the older reaction.
		match info.reaction:
			HitInfo.Reaction.STAGGER:
				tier = HitInfo.Tier.STAGGER
			HitInfo.Reaction.LAUNCH:
				tier = HitInfo.Tier.LAUNCH
	if HitInfo.is_launch_tier(tier):
		add_focus(float(Tuning.FOCUS_GAIN[&"launch"]), &"launch")
	elif tier == HitInfo.Tier.KNOCKDOWN:
		add_focus(float(Tuning.FOCUS_GAIN[&"knockdown"]), &"knockdown")
	elif tier == HitInfo.Tier.STAGGER:
		add_focus(float(Tuning.FOCUS_GAIN[&"stagger"]), &"stagger")

## A body this player launched or threw broke a wall.
func _on_wall_broken_by(flyer: Node3D, _wall: Node3D, _energy: float) -> void:
	if flyer == null or flyer == self:
		return
	var launcher: Node3D = null
	if ImpactResolver.has_method(&"get_launcher"):
		launcher = ImpactResolver.get_launcher(flyer)
	if launcher == self:
		add_focus(float(Tuning.FOCUS_GAIN[&"wall_break"]), &"wall_break")

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
	heal(max_hp * fraction)

## Restore `amount` HP (Round 5: Tuning.HEAL_BETWEEN_WAVES_HP between waves).
func heal(amount: float) -> void:
	if is_dead() or amount <= 0.0:
		return
	hp = minf(hp + amount, max_hp)
	hp_changed.emit(hp, max_hp)

# --- Physics -----------------------------------------------------------------
## `velocity` holds this fighter's own-time velocity (m per player second for
## the player): gravity, acceleration and forced velocities step by own_delta(),
## and only the move itself is scaled by own_time_factor(), because
## move_and_slide() steps by the scaled physics delta. Impulses the player
## gives others read real_velocity(), so they are not inflated in slow motion.
func _physics_process(delta: float) -> void:
	if _freeze_until > 0.0 and TimeDirector.now() >= _freeze_until:
		_end_freeze()  # backstop for the real-time timer
	if is_player:
		_tick_focus()
	if combat:
		combat.physics_tick(delta)  # B applies player time to combat timers
	var frozen := is_frozen()
	if frozen and _jitter > 0.0 and rig and not is_body_simulating():
		rig.position = _rig_rest_pos + Vector3(randf_range(-1, 1), randf_range(-0.5, 0.5),
			randf_range(-1, 1)) * _jitter
	if is_dead() or (ragdoll and ragdoll.is_simulating()):
		return  # RagdollController moves the host (FLINCH/STAGGER push included).
	if frozen:
		return  # actor time 0: no movement, no turning (the animator is stopped too)
	if is_held():
		velocity = Vector3.ZERO
		if _crouching or _airborne:
			_leave_stance()
		return  # the grabber places us every tick
	_update_crouch()
	if _forced_stop and _forced_left <= 0.0:
		_forced_stop = false  # a dead-stop slide just ended: no deceleration tail
		velocity.x = 0.0
		velocity.z = 0.0
	if traversal != null and traversal.physics_move(delta):
		_traversal_driving = true  # Round 5: M drives the player's locomotion
		_hang_left = 0.0
		_nudge_bodies()
		return
	_traversal_driving = false

	var pdt := own_delta(delta)
	var factor := own_time_factor()
	if _land_left > 0.0:
		_land_left -= pdt
		if _land_left < 1e-6:
			_land_left = 0.0
	if _airborne:
		_air_time += pdt
	var hanging := false
	if _hang_left > 0.0:
		if combat and combat.is_attacking():
			_hang_left = 0.0  # the pursuit attack started: the hang ends
		else:
			_hang_left -= pdt
			hanging = true

	var max_speed := Tuning.WALK_SPEED if is_player else Tuning.ENEMY_WALK_SPEED
	var mult := combat.get_move_speed_mult() if combat else 1.0
	if _crouching:
		mult *= Tuning.CROUCH_SPEED
	var desired := Vector3(move_input.x, 0.0, move_input.z)
	if desired.length() > 1.0:
		desired = desired.normalized()
	desired = _lock_scaled(desired)
	if _land_left > 0.0:
		desired = Vector3.ZERO  # landing recovery: feet planted
	desired *= max_speed * mult

	var on_floor := is_on_floor()
	var hv := Vector3(velocity.x, 0.0, velocity.z)
	if _forced_left > 0.0:
		_forced_left -= pdt
		hv = _forced_velocity
	elif combat and combat.has_forced_velocity():
		var forced := combat.get_forced_velocity()
		hv = Vector3(forced.x, 0.0, forced.z)
	elif hanging:
		hv = Vector3.ZERO
	elif _airborne:
		# Jump steering: half the walk acceleration, and the stick may only steer
		# up to JUMP_AIR_STEER x walk speed, or the take-off speed if that is
		# higher (a running jump keeps its speed; a standing hop drifts little).
		# No stick: the jump keeps its momentum.
		if desired.length_squared() > 1e-4:
			var cap := maxf(_takeoff_speed, max_speed * Tuning.JUMP_AIR_STEER)
			hv = hv.move_toward(desired.limit_length(cap), ACCEL * Tuning.JUMP_AIR_STEER * pdt)
	else:
		hv = hv.move_toward(desired, (ACCEL if on_floor else AIR_ACCEL) * pdt)

	# Gravity in own time, integrated exactly (trapezoid: constant acceleration),
	# so the jump apex and air time do not depend on the tick rate or on slow
	# motion. The player rises at Tuning.PLAYER_GRAVITY and falls
	# Tuning.FALL_GRAVITY_MULT times harder (heavy, not floaty).
	var vy := velocity.y
	var vy_move := vy
	if hanging:
		vy = 0.0
		vy_move = 0.0
	elif on_floor and not (_airborne and vy > 0.0):
		vy = minf(vy, 0.0)
		vy_move = vy
	else:
		var g := Tuning.GRAVITY
		if is_player:
			g = Tuning.PLAYER_GRAVITY * (Tuning.FALL_GRAVITY_MULT if vy <= 0.0 else 1.0)
		var vy_end := vy - g * pdt
		vy_move = 0.5 * (vy + vy_end)
		vy = vy_end
	velocity = Vector3(hv.x, vy_move, hv.z) * factor
	move_and_slide()
	velocity /= factor
	if is_on_floor():
		velocity.y = minf(velocity.y, 0.0)
	elif is_on_ceiling():
		velocity.y = minf(vy, 0.0)
	else:
		velocity.y = vy
	if _airborne and is_on_floor() and vy <= 0.0 and not hanging:
		_land(vy)

	# Facing.
	var allow_turn := combat.can_turn() if combat else true
	if allow_turn:
		var fd := Vector3(face_dir.x, 0.0, face_dir.z)
		if fd.length_squared() > 1e-4:
			fd = fd.normalized()
			var target_yaw := atan2(-fd.x, -fd.z)
			var rate := Tuning.TURN_SPEED * (combat.get_turn_mult() if combat else 1.0)
			rate = minf(rate, max_turn_rate)
			rotation.y = rotate_toward(rotation.y, target_yaw, rate * pdt)

	if animator:
		_apply_stance()
		var local_v := global_basis.inverse() * Vector3(velocity.x, 0.0, velocity.z)
		animator.set_locomotion(local_v, max_speed)
	_nudge_bodies()

# --- Bodies stay: the feet nudge dead bodies ---------------------------------------
func _build_feet(width: float) -> void:
	_feet = Area3D.new()
	_feet.name = "Feet"
	_feet.collision_layer = 0
	_feet.collision_mask = Layers.DEAD_BODY
	_feet.monitorable = false
	_feet.monitoring = true
	var cs := CollisionShape3D.new()
	var sh := CylinderShape3D.new()
	sh.radius = FOOT_RADIUS * width
	sh.height = FOOT_HEIGHT
	cs.shape = sh
	cs.position = Vector3(0.0, FOOT_HEIGHT * 0.5, 0.0)
	_feet.add_child(cs)
	add_child(_feet)

## Dead bodies are on Layers.DEAD_BODY, which walking capsules pass through, so
## fighters never jitter over a pile. Every bone the feet walk into gets a small
## shove along the walk (and away from the feet), scaled by the walker's real
## speed: piles shift and roll as you wade through them. A frozen (settled)
## body is woken first (RagdollController.wake).
func _nudge_bodies() -> void:
	if _feet == null or not _feet.monitoring or not _feet.has_overlapping_bodies():
		return
	var v := real_velocity()
	v.y = 0.0
	var speed := v.length()
	if speed < NUDGE_MIN_SPEED:
		return
	var now := TimeDirector.now()
	var dir := v / speed
	var dv_len := minf(speed * NUDGE_SHARE, NUDGE_MAX)
	for b in _feet.get_overlapping_bodies():
		var body := b as PhysicsBody3D
		if body == null:
			continue
		var id := body.get_instance_id()
		if now < float(_nudged.get(id, -INF)):
			continue
		_nudged[id] = now + NUDGE_COOLDOWN
		var owner_f := _fighter_of(body)
		if owner_f == self:
			continue
		if owner_f != null and owner_f.ragdoll != null:
			owner_f.ragdoll.wake()
		var away := body.global_position - global_position
		away.y = 0.0
		var push := dir
		if away.length_squared() > 1e-4:
			push = (dir + away.normalized() * 0.5).normalized()
		var mass := 1.0
		if body is PhysicalBone3D:
			mass = (body as PhysicalBone3D).mass
		elif body is RigidBody3D:
			mass = (body as RigidBody3D).mass
		var rid := body.get_rid()
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING, false)
		PhysicsServer3D.body_apply_central_impulse(rid, (push * dv_len + Vector3.UP * NUDGE_UP) * mass)
	if _nudged.size() > 64:
		for k in _nudged.keys():
			if float(_nudged[k]) < now:
				_nudged.erase(k)

static func _fighter_of(n: Node) -> Fighter:
	var p := n
	for i in 6:
		if p == null:
			return null
		if p is Fighter:
			return p as Fighter
		p = p.get_parent()
	return null

# --- Death ---------------------------------------------------------------------
## 0 HP: a full ragdoll (RagdollController.kill; A moves the body to
## Layers.DEAD_BODY), hurtboxes off, Focus mode over, GameEvents.fighter_died.
func _die(info: HitInfo) -> void:
	_death_info = info  # get_death_info() (results screen, death camera)
	end_focus()
	_leave_stance()
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
	if _feet:
		_feet.set_deferred(&"monitoring", false)
	ragdoll.kill(push)
	died.emit(self)
	GameEvents.fighter_died.emit(self, info)

## The hit that killed this fighter (null if alive, or killed without one).
func get_death_info() -> HitInfo:
	return _death_info

# --- Ragdoll signal relays ------------------------------------------------------
func _on_ragdoll_launched(v: Vector3) -> void:
	velocity = Vector3.ZERO  # stale walk/dash velocity must not survive the flight
	clear_forced_velocity()
	end_focus()  # getting launched ends Focus (a stagger can tip into a launch too)
	_leave_stance()
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
		invuln_until = maxf(invuln_until, TimeDirector.now() + Tuning.PLAYER_GETUP_INVULN)
	clear_forced_velocity()
	if combat:
		combat.force_reappear()
	face_dir = get_forward()
	GameEvents.fighter_recovered.emit(self)
