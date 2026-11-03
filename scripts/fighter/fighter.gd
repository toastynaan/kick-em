class_name Fighter
extends CharacterBody3D
## A fighter: animated capsule + HumanoidRig + RagdollController + PoseAnimator
## + CombatController, driven by a controller child (PlayerController or AIBrain)
## that writes move_input / face_dir and calls combat.press()/release().
## Built entirely in code: call setup() before add_child().
## OWNER: agent H (Upgrade 2; agent B before). CONTRACT STUB: keep every public signature.
##
## Player time (Upgrade 2, Round 5): the player's velocity, gravity, forced
## velocities, turning and reactions step by own_delta() (TimeDirector.player_delta).
##
## Round 5 (agent H, Feel Reference):
## - Per-fighter time: get_actor_time() is 0 while frozen by hitstop; a frozen
##   fighter skips movement, animation and its reaction clock (a ragdolling one
##   freezes through RagdollController.freeze); everyone else keeps moving. The
##   player's own freeze never passes Tuning.R7_PLAYER_HITSTOP_MAX (Round 7).
## - Player time in any slow motion: TimeDirector.player_time_factor() is
##   1 / time scale, so velocity x factor, accelerations x factor^2 (stepping by
##   own_delta) and animation x factor (PoseAnimator) keep the player at real
##   speed. `velocity` holds the OWN-TIME velocity between ticks (m per player
##   second; Traversal keeps the same convention). Impulses the player gives
##   ragdolls use real_velocity(), never velocity x own_time_factor().
## - Reactions by tier (enemy hits on the player, bodies, props): flinch,
##   stumble, stagger, knockdown, launch, sever_limb. The player gets up
##   Tuning.PLAYER_GETUP_AFTER after a knockdown and is untouchable
##   Tuning.PLAYER_GETUP_INVULN after.
## - Bodies stay: a foot Area3D nudges dead bodies (Layers.DEAD_BODY, which
##   capsules pass through) that a walking fighter steps into.
## - When Traversal (M) drives the player's movement, is_airborne() reads it.
##
## Round 7 (agent H, docs/Round 7 — Freeflow Combat.md):
## - react(kind, ...) runs the player strikes' reactions on the capsule (the
##   body stays ANIMATED, so the next hit finds it): snap / spin / push slide
##   along the hit over Tuning.R7_PUSH_SLIDE_SHARE of the stun, with stepping
##   legs from Tuning.R7_PUSH_STEP_FROM; fold / buckle hold for the stun; lift is
##   a ballistic capsule arc (arms loose through RagdollController.limp_chain)
##   that lands into a knockdown; repop re-pops a lifted body, at most
##   Tuning.R7_JUGGLE_MAX times per lift. The stun runs in the fighter's own
##   time and stops during its hitstop. can_act() is false while reacting.
## - is_invulnerable() adds the dodge (Traversal) and the counter (Defence).
## - Kept (God path amendment): jump (jump(), can_jump(), the landing; the
##   player's is Traversal's while it drives him) and the pursuit hang (hang(),
##   held here so it works whoever drives the player).
## - Removed from the player: Focus mode and the Focus meter (focus reads 0,
##   add_focus / spend_focus are no-ops while callers remain), crouch, lock-on
##   strafing and zone aiming.

signal hp_changed(hp: float, max_hp: float)
signal died(fighter: Fighter)

const TEAM_PLAYER := 0
const TEAM_ENEMY := 1

## Capsule acceleration toward the desired walking velocity (m/s^2).
const ACCEL := 40.0
const AIR_ACCEL := 8.0
## Landing pose blend back to locomotion after the landing recovery (s).
const LAND_POSE_RECOVERY := 0.15
## Mesh jitter during hitstop (m), applied to the victim. Negative = a random
## amount in Tuning.HITSTOP_JITTER_RANGE.
const HITSTOP_JITTER := -1.0
## At most this many limbs come off one body.
const MAX_SEVERS := 2
## Capsule radius (m at width 1.0) and nominal height (m at height 1.0).
const CAPSULE_RADIUS := 0.3
const CAPSULE_HEIGHT := 1.8
## Round 5 bodies stay: the foot Area3D (Feel Reference: Bodies stay).
const FOOT_RADIUS := 0.32       ## m (x width) around the feet
const FOOT_HEIGHT := 0.4        ## m tall from the floor: low enough to touch only bodies lying down
const NUDGE_MIN_SPEED := 0.6    ## m/s: slower walkers leave bodies alone
const NUDGE_SHARE := 0.35       ## of the walker's real speed given to each bone it steps into...
const NUDGE_MAX := 1.4          ## ...at most (m/s), so a pile is shoved, never kicked across the room
const NUDGE_UP := 0.25          ## m/s upward part, so limbs roll over the feet instead of scraping
const NUDGE_COOLDOWN := 0.2     ## real s between nudges of the same bone
## Round 7 reactions (Fighter.react). Numbers that are not in Tuning:
const REACT_KINDS: Array[StringName] = [&"snap", &"spin", &"fold", &"lift", &"buckle", &"push", &"repop"]
const REACT_SPIN_TURN := 100.0  ## degrees the body turns away over a spin's slide (the half-turn stumble)
const REACT_POSE_BLEND := 0.06  ## s: a held reaction pose (fold, buckle, lift) blends in...
const REACT_POSE_RELEASE := 0.15 ## ...and back out to locomotion
const LIFT_ARM_LIMP := 0.7      ## physics share of both arms during a lift (loose, flailing)
const LIFT_LAND_GRACE := 0.05   ## own s after a pop before a floor contact counts as the landing
## Pose fallbacks until P's react_<kind> poses land: timed moves for snap,
## spin and push (spin picks the side), holds for fold, buckle and lift.
const REACT_POSE_FALLBACK := {&"snap": [&"stumble_back"], &"push": [&"stumble_back"],
	&"spin": [&"stumble_side_l", &"stumble_side_r"], &"fold": [&"limp_hunch", &"stagger"],
	&"buckle": [&"crouch"], &"lift": [&"fall", &"jump_fall"]}
const LIFT_ARMS: Array[StringName] = [Bones.L_UPPER_ARM, Bones.L_LOWER_ARM, Bones.R_UPPER_ARM, Bones.R_LOWER_ARM]

var archetype: StringName = &"player"
var team: int = TEAM_PLAYER
var is_player := false
var config: Dictionary = {}   ## Tuning.ARCHETYPES[archetype]
var max_hp := 1000.0
var hp := 1000.0
## Round 7 (God path amendment): the Focus meter is gone; nothing costs Focus.
## Reads 0, assignments are ignored. Kept while callers remain (B's Duelist
## teleport counter reads it; tests/combat/test_round2_api).
var focus: float:
	get:
		return 0.0
	set(_value):
		pass

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

var _freeze_until := 0.0      ## real time; hitstop
var _jitter := 0.0            ## m; hitstop mesh jitter for the current freeze
var _rig_rest_pos := Vector3.ZERO
var _forced_velocity := Vector3.ZERO  ## dash / knockback / lunge (horizontal)
var _forced_left := 0.0               ## own-time seconds
var _forced_stop := false             ## the knockback ends dead (knockback(..., stop))
var _severed := 0
var _death_info: HitInfo
var _fading := false

# Jump and landing (Upgrade 2; kept in Round 7), the pursuit hang (Defence).
var _airborne := false        ## jumping (capsule in the air by choice)
var _air_time := 0.0          ## player s since take-off
var _takeoff_speed := 0.0     ## m/s horizontal at take-off (a running jump keeps it)
var _land_left := 0.0         ## player s of landing recovery left
var _hang_left := 0.0         ## player s of pursuit hang left
var _traversal_driving := false  ## Traversal moved the capsule on its last tick
var _feet: Area3D
var _nudged := {}             ## bone instance id -> real time it may be nudged again

# Round 7 reactions (react()). Times are this fighter's own seconds.
var _react_kind: StringName = &""   ## &"" | snap | spin | fold | buckle | push | lift (repop keeps lift)
var _react_left := 0.0               ## stun left (not lift: the arc decides)
var _react_t := 0.0                  ## since the reaction started
var _react_dir := Vector3.ZERO       ## flat hit direction (attacker -> victim)
var _react_attacker: Node3D
var _react_hold: StringName = &""    ## held pose id (fold, buckle, lift); &"" = a timed move
var _slide_v0 := 0.0                 ## m/s at the start of the push slide
var _slide_time := 0.0               ## s the slide lasts
var _slide_steps := false            ## push >= R7_PUSH_STEP_FROM: the legs step with the slide
var _turn_rate := 0.0                ## rad/s of a spin's turn while it slides (signed)
var _lift_vy := 0.0                  ## m/s vertical speed of the lift arc
var _lift_hv := Vector3.ZERO         ## m/s horizontal drift of the lift
var _lift_g := 0.0                   ## m/s^2 of the lift (from R7_LIFT_HEIGHT / R7_LIFT_PEAK_TIME)
var _lift_floor := 0.0               ## floor height at the first pop (heights are measured from it)
var _lift_since_pop := 0.0           ## s since the last pop
var _repops := 0                     ## re-pops in this lift
var _arms_loose := false

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
	GameEvents.fighter_spawned.emit(self)

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

## Untouchable now: invuln_until (get-ups), the dodge (Traversal), the counter
## (Defence), the player's get-up, and CombatController's own (AI moves).
func is_invulnerable() -> bool:
	if is_dead():
		return false
	if TimeDirector.now() < invuln_until:
		return true
	if is_instance_valid(defence) and defence.is_countering():
		return true
	if is_instance_valid(traversal) and traversal.is_dodge_invulnerable():
		return true
	if is_player and get_state() == RagdollController.State.GETUP:
		return true  # enemies get Tuning.ENEMY_GETUP_INVULN from the start of the get-up
	return combat != null and combat.is_invulnerable()

## Flinch, stagger, blockstun, a Round 7 reaction, held by a grab.
func is_in_hitstun() -> bool:
	if is_reacting():
		return true
	if combat and combat.is_stunned():
		return true
	if is_held():
		return true
	return get_state() in [RagdollController.State.FLINCH, RagdollController.State.STAGGER]

## Can start a new action (not down, not reacting or in hitstun, not mid-move,
## not in a grab, a hold or a throw (Carry), not in jump landing recovery).
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
## every slow-motion hit 1 / scale times too strong. Between ticks `velocity` already holds
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
## Animated: halfway between the chest and head bones, so a folded or buckled
## body is aimed at where its upper body really is (about 0.72 x height when
## standing).
func get_aim_point() -> Vector3:
	if ragdoll and ragdoll.is_simulating():
		return ragdoll.get_center_of_mass() + Vector3.UP * 0.3
	if rig and rig.skeleton and rig.is_inside_tree():
		return (rig.get_bone_global_position(Bones.CHEST) + rig.get_bone_global_position(Bones.HEAD)) * 0.5
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
	if _lift_interrupted(direction):
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
	if _lift_interrupted(direction):
		return
	if not is_body_simulating() or get_state() == RagdollController.State.STAGGER:
		combat.on_reaction(HitInfo.Reaction.STAGGER, float(Tuning.REACT_STAGGER["act"]))
		clear_forced_velocity()
	ragdoll.stagger(direction, strength)

func launch(velocity_change: Vector3, hit_point: Vector3, hit_bone: StringName = &"Chest") -> void:
	if combat:
		combat.on_reaction(HitInfo.Reaction.LAUNCH, 0.0)
	clear_react()  # a launch payoff ends any reaction (a lifted body keeps its arc speed)
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
	if _lift_interrupted(direction):
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
	clear_react()
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

## Local hitstop: freeze animation, movement, combat timers, the reaction clock
## and (if ragdoll) bone velocities of this fighter only. The player's own
## freeze is capped at Tuning.R7_PLAYER_HITSTOP_MAX (Round 7: Hit feel); the
## victim keeps its full freeze.
func freeze_hitstop(duration_real: float) -> void:
	if is_player:
		duration_real = minf(duration_real, Tuning.R7_PLAYER_HITSTOP_MAX)
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
## `duration_real` player s or until an attack starts. Fighter holds it itself
## (Traversal is skipped while it hangs), and tells Traversal so its own air
## state knows; the fall afterwards is whoever drives the player.
func hang(duration_real: float) -> void:
	velocity = Vector3.ZERO
	_land_left = 0.0
	_hang_left = maxf(duration_real, 0.0)
	_air_time = 0.0
	_takeoff_speed = 0.0
	if traversal != null:
		traversal.hang(duration_real)
	else:
		_airborne = true

## Hanging in the air for a pursuit follow-up.
func is_hanging() -> bool:
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
## Round 7: zone aiming is gone. These keep their defaults (torso, chest)
## for old readers; nothing writes them.
var aim_zone: int = BodyZones.Zone.TORSO
var aim_bone: StringName = Bones.CHEST

## In the air by choice (jump, pursuit hang): Traversal's state while it
## drives the player. Launched ragdolls are is_launched() and lifted bodies
## is_lifted(), not this.
func is_airborne() -> bool:
	if is_body_simulating():
		return false
	if _hang_left > 0.0:
		return true
	if _traversal_driving and traversal != null:
		return traversal.is_airborne()
	return _airborne

## In the landing recovery after a jump (Traversal's landing pause while it
## drives the player).
func is_landing() -> bool:
	if _traversal_driving and traversal != null and traversal.has_method(&"is_landing"):
		return bool(traversal.call(&"is_landing"))
	return _land_left > 0.0

## Traversal (M) moved the player's capsule on its last tick.
func is_traversal_driving() -> bool:
	return _traversal_driving

# --- Player time (Upgrade 2; Round 5: every slow motion) ----------------------------
## This fighter's share of a physics delta: the player's runs in player time
## (TimeDirector.player_delta: real time in any slow motion); everyone else's
## in game time.
func own_delta(delta: float) -> float:
	return TimeDirector.player_delta(delta) if is_player else delta

## Player seconds per game second: 1, except the player in slow motion.
func own_time_factor() -> float:
	return maxf(TimeDirector.player_time_factor(), 0.01) if is_player else 1.0

# --- Jump (Upgrade 2; Round 5 numbers for the player; kept in Round 7) --------------
## Take-off speed of the player's jump: Tuning.JUMP_HEIGHT under
## Tuning.PLAYER_GRAVITY (4.85 m/s; Traversal raises it toward
## Tuning.JUMP_HEIGHT_SPRINT at full speed). Enemies: Tuning.JUMP_APEX under Tuning.GRAVITY.
static func jump_speed(player := true) -> float:
	if player:
		return sqrt(2.0 * Tuning.PLAYER_GRAVITY * Tuning.JUMP_HEIGHT)
	return sqrt(2.0 * Tuning.GRAVITY * Tuning.JUMP_APEX)

## Jump now if able. Returns true on take-off. The player's jump is
## Traversal.jump() while Traversal drives him (M); otherwise Fighter's own:
## the player's height follows Traversal.sprint_charge (1.2 m standing, 1.5 m
## at full speed), horizontal velocity kept exactly.
func jump() -> bool:
	if is_player and traversal != null and traversal.has_method(&"jump"):
		return bool(traversal.call(&"jump"))  # Traversal owns the player's jump state
	if not can_jump():
		return false
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

## On the floor, free (or between moves), not reacting, held or in a landing.
func can_jump() -> bool:
	if is_dead() or _airborne or _land_left > 0.0 or is_frozen() or not is_on_floor() or is_reacting():
		return false
	if get_state() != RagdollController.State.ANIMATED:
		return false
	if combat == null:
		return true
	if is_held() or combat.is_stunned() or combat.is_dashing():
		return false
	if carry != null and carry.is_busy() and not carry.is_holding():
		return false  # reaching or throwing (a held body jumps along: Carry)
	return not combat.is_attacking()

## Landing. The player never falls over from a jump: a soft landing keeps
## running with no recovery; a hard one crouches Tuning.LAND_HARD_CROUCH; a
## heavy one Tuning.LAND_HEAVY_TIME. Enemies keep the Upgrade 2 landing recovery.
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
	_apply_stance()

## Launch, death, grab: no jump, no hang, no landing.
func _leave_stance() -> void:
	_airborne = false
	_air_time = 0.0
	_land_left = 0.0
	_hang_left = 0.0
	_apply_stance()

func _apply_stance() -> void:
	if animator:
		# Vertical speed times exactly when jump_rise blends into jump_fall.
		animator.set_stance(&"air" if _airborne else &"stand", velocity.y)

# --- Removed in Round 7: the Focus meter (no-ops while callers remain) ----------------
## Round 7: the Focus meter is gone. Does nothing.
func add_focus(_amount: float, _reason: StringName = &"") -> void:
	pass

## Round 7: the Focus meter is gone; nothing costs Focus. Always true (spent
## nothing; B's Duelist code still calls it).
func spend_focus(_amount: float) -> bool:
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
	if combat:
		combat.physics_tick(delta)  # B applies player time to combat timers
	var frozen := is_frozen()
	if frozen and _jitter > 0.0 and rig and not is_body_simulating():
		rig.position = _rig_rest_pos + Vector3(randf_range(-1, 1), randf_range(-0.5, 0.5),
			randf_range(-1, 1)) * _jitter
	# Round 7 reactions: the clock runs in own time and stops during hitstop;
	# the reaction moves the capsule itself (slide, spin, lift arc).
	if not frozen and _react_kind != &"" and _tick_react(delta):
		_nudge_bodies()
		return
	if is_dead() or (ragdoll and ragdoll.is_simulating()):
		return  # RagdollController moves the host (FLINCH/STAGGER push included).
	if frozen:
		return  # actor time 0: no movement, no turning (the animator is stopped too)
	if is_held():
		velocity = Vector3.ZERO
		if _airborne or _hang_left > 0.0:
			_leave_stance()
		return  # the grabber places us every tick
	var pdt := own_delta(delta)
	var factor := own_time_factor()
	# Pursuit hang (Defence): held still in the air until it runs out or an attack starts.
	if _hang_left > 0.0:
		if combat and combat.is_attacking():
			_hang_left = 0.0  # the pursuit attack started: the hang ends
		else:
			_hang_left = maxf(_hang_left - pdt, 0.0)
			velocity = Vector3.ZERO
			return
	if _forced_stop and _forced_left <= 0.0:
		_forced_stop = false  # a dead-stop slide just ended: no deceleration tail
		velocity.x = 0.0
		velocity.z = 0.0
	if traversal != null and traversal.physics_move(delta):
		_traversal_driving = true  # Round 5: M drives the player's locomotion (and jump)
		_airborne = false
		_land_left = 0.0
		_nudge_bodies()
		return
	_traversal_driving = false

	if _land_left > 0.0:
		_land_left -= pdt
		if _land_left < 1e-6:
			_land_left = 0.0
	if _airborne:
		_air_time += pdt
	var max_speed := Tuning.WALK_SPEED if is_player else Tuning.ENEMY_WALK_SPEED
	var mult := combat.get_move_speed_mult() if combat else 1.0
	var desired := Vector3(move_input.x, 0.0, move_input.z)
	if desired.length() > 1.0:
		desired = desired.normalized()
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
	var vy := _move_capsule(hv, pdt, factor)
	if _airborne and is_on_floor() and vy <= 0.0:
		_land(vy)

	# Facing.
	var allow_turn := combat.can_turn() if combat else true
	if allow_turn:
		var fd := Vector3(face_dir.x, 0.0, face_dir.z)
		if fd.length_squared() > 1e-4:
			fd = fd.normalized()
			var target_yaw := atan2(-fd.x, -fd.z)
			var rate := Tuning.TURN_SPEED * (combat.get_turn_mult() if combat else 1.0)
			rotation.y = rotate_toward(rotation.y, target_yaw, rate * pdt)

	if animator:
		_apply_stance()
		var local_v := global_basis.inverse() * Vector3(velocity.x, 0.0, velocity.z)
		animator.set_locomotion(local_v, max_speed)
	_nudge_bodies()

## Move the capsule at horizontal own-time velocity `hv` with gravity (own
## time, integrated exactly: trapezoid, so the jump apex, air time and a fall
## do not depend on the tick rate or slow motion; the player rises at
## Tuning.PLAYER_GRAVITY and falls Tuning.FALL_GRAVITY_MULT times harder,
## everyone else at Tuning.GRAVITY). Returns the vertical speed at the end of
## the tick (before the floor clamps it).
func _move_capsule(hv: Vector3, pdt: float, factor: float) -> float:
	var vy := velocity.y
	var vy_move := vy
	if is_on_floor() and not (_airborne and vy > 0.0):
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
	return vy

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
## Layers.DEAD_BODY), hurtboxes off, any reaction over, GameEvents.fighter_died.
func _die(info: HitInfo) -> void:
	_death_info = info  # get_death_info() (results screen, death camera)
	clear_react()
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
	clear_react()  # a stagger can tip into a launch too
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




# =============================================================================
# Round 7: reactions (docs/Round 7 — Freeflow Combat.md: Reactions). Owner H.
# B calls react() for player strikes (snap, spin, fold, lift, buckle, push,
# repop) after applying the heavy and anti-infinite multipliers; knockdown and
# launch go through knockdown() / launch().
# =============================================================================

## Apply a Round 7 reaction. kind: &"snap" | &"spin" | &"fold" | &"lift" |
## &"buckle" | &"push" | &"repop". direction: world, attacker -> victim. push:
## m. stun: own s the fighter cannot act (lift and repop: ignored, the arc decides).
## - snap, spin, push, fold, buckle: the body slides `push` m along the hit over
##   Tuning.R7_PUSH_SLIDE_SHARE of the stun, slowing evenly; from
##   Tuning.R7_PUSH_STEP_FROM the legs step with the slide (stumble steps).
##   A spin also turns REACT_SPIN_TURN degrees away over the slide. Poses:
##   P's react_<kind> (timed over the stun for snap, spin and push; held for
##   fold and buckle), else REACT_POSE_FALLBACK.
## - lift: a ballistic capsule arc (not a ragdoll launch) whose feet peak
##   info.lift_height (else Tuning.R7_LIFT_HEIGHT) above the floor, under the
##   gravity that takes R7_LIFT_HEIGHT to its peak in R7_LIFT_PEAK_TIME; `push`
##   drifts it along the hit over the arc; the arms go loose
##   (RagdollController.limp_chain). Landing turns it into a knockdown. A lift
##   on a lifted body counts as a re-pop.
## - repop (lifted body): up Tuning.R7_REPOP_HEIGHT more from where it is, at
##   most Tuning.R7_JUGGLE_MAX times per lift; past that the body falls into a
##   knockdown at once. On a body that is not lifted: a lift of R7_REPOP_HEIGHT.
## Any other kind on a lifted body adds its push to the arc (it still lands
## into a knockdown). A new reaction replaces the current one and cancels the
## fighter's own move (so a hit on an armored tell must not call this). Held
## and downed bodies are left to Carry / the ragdoll. Emits
## GameEvents.react_started(self, kind, info.attacker).
func react(kind: StringName, direction: Vector3, push: float, stun: float, info: HitInfo = null) -> void:
	if is_dead() or is_held():
		return
	if not REACT_KINDS.has(kind):
		push_warning("Fighter.react: unknown kind %s" % kind)
		return
	var dir := Vector3(direction.x, 0.0, direction.z)
	if dir.length_squared() < 1e-6:
		dir = -get_forward()
	dir = dir.normalized()
	var bone: StringName = info.hit_bone if info != null else Bones.CHEST
	var attacker: Node3D = info.attacker if info != null else null
	if is_down():
		ragdoll.flinch(dir, bone, 0.5)  # already falling: a nudge, no new state
		return
	push = maxf(push, 0.0)
	stun = maxf(stun, 0.0)
	if is_lifted():
		_react_attacker = attacker
		if kind == &"repop" or kind == &"lift":
			if _repops >= Tuning.R7_JUGGLE_MAX:
				knockdown(dir, bone)  # past the juggle cap: no re-pop, the body falls
				return
			_repops += 1
			_pop(Tuning.R7_REPOP_HEIGHT, dir, push, true)
			GameEvents.react_started.emit(self, &"repop", attacker)
		else:
			_pop(0.0, dir, push, true)
			GameEvents.react_started.emit(self, kind, attacker)
		return
	_end_react_pose()
	if combat:
		combat.on_reaction(HitInfo.Reaction.STAGGER, 0.0)  # cancels its move and buffered press
	clear_forced_velocity()
	if rig:
		rig.position = _rig_rest_pos
	_react_dir = dir
	_react_attacker = attacker
	_react_t = 0.0
	_turn_rate = 0.0
	_slide_v0 = 0.0
	if kind == &"lift" or kind == &"repop":
		var h := Tuning.R7_LIFT_HEIGHT
		if kind == &"repop":
			h = Tuning.R7_REPOP_HEIGHT
		elif info != null and info.lift_height > 0.0:
			h = info.lift_height
		_react_kind = &"lift"
		_react_left = 0.0
		_repops = 0
		_lift_g = 2.0 * Tuning.R7_LIFT_HEIGHT / (Tuning.R7_LIFT_PEAK_TIME * Tuning.R7_LIFT_PEAK_TIME)
		_lift_floor = global_position.y
		_lift_vy = 0.0
		_lift_hv = Vector3.ZERO
		velocity = Vector3.ZERO
		_pop(h, dir, push, false)
		_set_arms_loose(true)
		_play_react_pose(&"lift", 0.0, 0)
		GameEvents.react_started.emit(self, &"lift", attacker)
		return
	_react_kind = kind
	_react_left = stun
	_slide_time = maxf(stun * Tuning.R7_PUSH_SLIDE_SHARE, 1e-3)
	_slide_v0 = 2.0 * push / _slide_time
	_slide_steps = push >= Tuning.R7_PUSH_STEP_FROM - 1e-4
	var side := 0
	if kind == &"spin":
		# The head and shoulders turn away with the hook: toward the side the
		# hit travels (yaw + turns left); straight on, to the right.
		var right := global_basis.x
		var lat := dir.dot(Vector3(right.x, 0.0, right.z).normalized())
		side = 1 if lat > 0.1 or absf(lat) <= 0.1 else -1
		_turn_rate = -float(side) * deg_to_rad(REACT_SPIN_TURN) / _slide_time
	_play_react_pose(kind, stun, side)
	GameEvents.react_started.emit(self, kind, attacker)

## The current reaction state: &"" | &"snap" | &"spin" | &"fold" | &"lift" |
## &"buckle" | &"push" | &"down" (knocked down, launched, getting up or dead).
## A re-popped body still reports &"lift".
func get_react_state() -> StringName:
	if is_down():
		return &"down"
	return _react_kind

## Own seconds left in the current reaction (0 when none). Lift: the time to
## land from the arc as it is now.
func get_react_time_left() -> float:
	if _react_kind == &"":
		return 0.0
	if _react_kind == &"lift":
		var h := maxf(global_position.y - _lift_floor, 0.0)
		return (_lift_vy + sqrt(_lift_vy * _lift_vy + 2.0 * _lift_g * h)) / maxf(_lift_g, 0.01)
	return maxf(_react_left, 0.0)

func is_reacting() -> bool:
	return _react_kind != &""

## Popped up by a lift (the controlled arc, not a ragdoll launch).
func is_lifted() -> bool:
	return _react_kind == &"lift"

## Re-pops so far in the current lift (0 when not lifted). Tests, debug.
func get_repops() -> int:
	return _repops if is_lifted() else 0

## Who caused the current reaction (the last hit's attacker; null when none).
func get_react_attacker() -> Node3D:
	if _react_kind == &"" or not is_instance_valid(_react_attacker):
		return null
	return _react_attacker

## Feet above the floor the lift started from (0 when not lifted).
func get_lift_height() -> float:
	return maxf(global_position.y - _lift_floor, 0.0) if is_lifted() else 0.0

## End the current reaction now, with no knockdown (knockdown, launch, death,
## a grab; tests). Safe to call any time.
func clear_react() -> void:
	if _react_kind == &"":
		return
	_end_react_pose()
	_set_arms_loose(false)
	_react_kind = &""
	_react_left = 0.0
	_react_t = 0.0
	_slide_v0 = 0.0
	_turn_rate = 0.0
	_lift_vy = 0.0
	_lift_hv = Vector3.ZERO
	_repops = 0
	_react_attacker = null

## One tick of the reaction (own time; never called during hitstop). true when
## it moved the capsule (the caller skips normal movement).
func _tick_react(delta: float) -> bool:
	if is_dead() or is_down() or is_held():
		clear_react()
		return false
	var pdt := own_delta(delta)
	var factor := own_time_factor()
	var free := not (ragdoll and ragdoll.is_simulating())  # an older-tier ragdoll reaction moves the host itself
	if _react_kind == &"lift":
		if free:
			_move_lift(pdt, factor)
		return free
	var t0 := _react_t
	_react_t += pdt
	_react_left -= pdt
	if free:
		_move_slide(t0, pdt, factor)
	if _react_left <= 1e-6:
		clear_react()
	return free

## The push slide: v(t) = v0 (1 - t / T) along the hit for T = the slide time,
## integrated exactly over the tick, so it covers `push` at any tick rate.
func _move_slide(t0: float, pdt: float, factor: float) -> void:
	var hv := Vector3.ZERO
	if _slide_v0 > 0.0 and t0 < _slide_time and pdt > 0.0:
		var t1 := minf(t0 + pdt, _slide_time)
		var d := _slide_v0 * ((t1 - t0) - (t1 * t1 - t0 * t0) / (2.0 * _slide_time))
		hv = _react_dir * (d / pdt)
		if _turn_rate != 0.0:
			rotation.y = wrapf(rotation.y + _turn_rate * (t1 - t0), -PI, PI)
	_move_capsule(hv, pdt, factor)
	if animator:
		var legs := hv if _slide_steps else Vector3.ZERO
		animator.set_locomotion(global_basis.inverse() * legs, Tuning.WALK_SPEED)

## The lift arc: own-time gravity _lift_g, integrated exactly (trapezoid).
## Landing (floor, falling) turns into a knockdown along the last hit.
func _move_lift(pdt: float, factor: float) -> void:
	_lift_since_pop += pdt
	var vy := _lift_vy
	var vy_end := vy - _lift_g * pdt
	velocity = Vector3(_lift_hv.x, 0.5 * (vy + vy_end), _lift_hv.z) * factor
	move_and_slide()
	velocity /= factor
	_lift_vy = vy_end
	if is_on_ceiling() and _lift_vy > 0.0:
		_lift_vy = 0.0
	if animator:
		animator.set_locomotion(Vector3.ZERO, Tuning.WALK_SPEED)
	if is_on_floor() and _lift_vy <= 0.0 and _lift_since_pop >= LIFT_LAND_GRACE:
		velocity = Vector3(_lift_hv.x, 0.0, _lift_hv.z)
		knockdown(_react_dir, Bones.CHEST)  # nothing followed: the body lands into a knockdown

## Pop the lifted body: it rises `rise` m from where it is now (a rising body
## keeps its speed if that is more); `push` m along `dir` spreads over the
## remaining air time (added to the drift when `add`, else replacing it).
func _pop(rise: float, dir: Vector3, push: float, add: bool) -> void:
	if rise > 0.0:
		var vy := sqrt(2.0 * _lift_g * rise)
		_lift_vy = maxf(_lift_vy, vy) if add else vy
		_lift_since_pop = 0.0
	var h := maxf(global_position.y - _lift_floor, 0.0)
	var t_air := (_lift_vy + sqrt(_lift_vy * _lift_vy + 2.0 * _lift_g * h)) / maxf(_lift_g, 0.01)
	var drift := dir * (push / maxf(t_air, 0.05))
	_lift_hv = _lift_hv + drift if add else drift

## An older-tier reaction (enemy hits, bodies, props) on a lifted body brings
## it down: a knockdown. true when it did.
func _lift_interrupted(direction: Vector3) -> bool:
	if not is_lifted():
		return false
	knockdown(direction, Bones.CHEST)
	return true

## Loose arms for the lift (partial physics on both arm chains, held until restored).
func _set_arms_loose(on: bool) -> void:
	if ragdoll == null or on == _arms_loose:
		return
	_arms_loose = on
	if on:
		ragdoll.limp_chain(LIFT_ARMS, LIFT_ARM_LIMP, 0.0)
	else:
		ragdoll.restore_chain(LIFT_ARMS)

## P's react_<kind> pose, else the first fallback the library has. Snap, spin
## and push play as timed moves over `stun`; fold, buckle and lift hold until
## the reaction ends. `side` (spin): 1 = turning right, which plays P's mirrored
## react_spin_r (the torso leads the turn).
func _play_react_pose(kind: StringName, stun: float, side: int) -> void:
	if animator == null:
		return
	var ids: Array[StringName] = [StringName("react_" + String(kind))]
	for id: StringName in REACT_POSE_FALLBACK.get(kind, []):
		ids.append(id)
	if kind == &"spin" and side > 0:
		ids.insert(0, &"react_spin_r")
		ids.erase(&"stumble_side_r")
		ids.insert(2, &"stumble_side_r")
	var hold := kind == &"fold" or kind == &"buckle" or kind == &"lift"
	for id in ids:
		if hold and (PoseLibrary.HOLDS.has(id) or PoseLibrary.POSES.has(id)):
			animator.hold_pose(id, REACT_POSE_BLEND)
			_react_hold = id
			return
		if PoseLibrary.has_move(id):
			animator.play_timed(id, maxf(stun if not hold else get_react_time_left(), 0.1))
			return

func _end_react_pose() -> void:
	if _react_hold != &"" and animator and get_state() == RagdollController.State.ANIMATED:
		animator.release_pose(REACT_POSE_RELEASE)
	_react_hold = &""
