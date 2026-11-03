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
##
## Round 8 (agent H, docs/Round 8 — Charge and Pressure.md):
## - react() kinds: flinch (a physical kick on the struck bone through
##   RagdollController.limp_chain, a short stun and a small slide; the body
##   stays animated and in control, so it walks and attacks right after),
##   sweep (a knockdown onto the back with the legs thrown forward and up) and
##   broken (dazed for the break: it cannot act or block; CombatController's
##   is_broken() is the status, and the daze comes back after any reaction
##   that plays on top of it). A fold shorter than FOLD_QUICK_MAX is a quick
##   half-keel; longer folds are the full keel.
## - air_hang() holds a lifted body still in the air for B's air combo; while
##   the combo runs, B (not the Round 7 re-pop cap) decides when it falls.
## - hang() begun during an attack (B's landed air strike) lasts its whole
##   time: the next strike does not end it.

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
const REACT_KINDS: Array[StringName] = [&"snap", &"spin", &"fold", &"lift", &"buckle", &"push", &"repop",
	&"flinch", &"sweep", &"broken"]
const REACT_SPIN_TURN := 100.0  ## degrees the body turns away over a spin's slide (the half-turn stumble)
const REACT_POSE_BLEND := 0.06  ## s: a held reaction pose (fold, buckle, lift) blends in...
const REACT_POSE_RELEASE := 0.15 ## ...and back out to locomotion
const LIFT_ARM_LIMP := 0.7      ## physics share of both arms during a lift (loose, flailing)
const LIFT_LAND_GRACE := 0.05   ## own s after a pop before a floor contact counts as the landing
## Pose fallbacks until P's react_<kind> poses land: timed moves for snap,
## spin and push (spin picks the side), holds for fold, buckle and lift.
const REACT_POSE_FALLBACK := {&"snap": [&"stumble_back"], &"push": [&"stumble_back"],
	&"spin": [&"stumble_side_l", &"stumble_side_r"], &"fold": [&"limp_hunch", &"stagger"],
	&"buckle": [&"crouch"], &"lift": [&"fall", &"jump_fall"], &"broken": [&"dazed", &"stagger"]}
const LIFT_ARMS: Array[StringName] = [Bones.L_UPPER_ARM, Bones.L_LOWER_ARM, Bones.R_UPPER_ARM, Bones.R_LOWER_ARM]
## Round 8 reactions. Numbers that are not in Tuning:
const FLINCH_SLIDE_SHARE := 0.75 ## a flinch's push slides over this share of its stun (a jolt, no step)
const FLINCH_STRENGTH := 1.0     ## x the Round 5 flinch kick on the struck bone (RagdollProfile.flinch_impulse)
const FLINCH_CHAIN_SHARE := 0.4  ## the rest of the struck chain gets this share of the kick
## A fold shorter than this (the gut punch tap's 0.3 s) plays P's react_fold
## timed (its "quick" half-keel, back up by the end of the stun) instead of
## holding the full keel. PoseLibrary's own "quick" threshold wins when it has one.
const FOLD_QUICK_MAX := 0.45
## Sweep: after the knockdown (upper body tipped back), the legs get this
## velocity change (m/s) along the victim's facing and up, so it falls onto its
## back legs first. Mostly up: the attacker stands right in front, and bones
## collide with capsules...
const SWEEP_LEG_FWD := 1.0
const SWEEP_LEG_UP := 6.5
## ...feet x1, shins and thighs less; the leg that was not struck x SWEEP_OTHER_LEG.
const SWEEP_LEG_SHARE := {Bones.L_FOOT: 1.0, Bones.R_FOOT: 1.0, Bones.L_LOWER_LEG: 0.75,
	Bones.R_LOWER_LEG: 0.75, Bones.L_UPPER_LEG: 0.35, Bones.R_UPPER_LEG: 0.35}
const SWEEP_OTHER_LEG := 0.8
const SWEEP_POSE := &"react_sweep"  ## P's sweep fall: the knockdown's muscle target while it exists

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
# Round 8 reactions.
var _broken_left := 0.0              ## own s of the break left (B's is_broken() wins once it reports one)
var _broken_seen := false            ## B reported this break (its timer is the status from then on)
var _air_hang_left := 0.0            ## own s the lifted body still hangs (air_hang)
var _air_combo := false              ## air_hang() was called in this lift: B decides the combo, not R7_JUGGLE_MAX
var _sweep_flight := false           ## the sweep set P's react_sweep as the fall's muscle target (cleared on landing)
var _hang_keep := false              ## the hang began during an attack (an air strike): strikes do not end it

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
	_end_react()  # a launch payoff ends any reaction but not the break (a lifted body keeps its arc speed)
	_sweep_flight = false
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
	_end_react()  # the break (broken) keeps running
	_sweep_flight = false
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
## Round 8: a hang that begins during an attack (B's landed air strike,
## Tuning.R8_AIR_HANG) lasts its whole time from the hit (its hitstop
## included), so the next air strike starts while still hanging; only the
## strike's own step moves the body (sideways).
func hang(duration_real: float) -> void:
	velocity = Vector3.ZERO
	_land_left = 0.0
	_hang_left = maxf(duration_real, 0.0)
	_hang_keep = combat != null and combat.is_attacking()
	_air_time = 0.0
	_takeoff_speed = 0.0
	if traversal != null:
		traversal.hang(duration_real)
	else:
		_airborne = true

## Hanging in the air for a pursuit follow-up.
func is_hanging() -> bool:
	return _hang_left > 0.0

## Round 8: the air combo's hangs (air_hang on a lifted body, a hang begun
## during an air strike) count from the hit, through the hitstop that follows
## it, so each lasts Tuning.R8_AIR_HANG from the hit whatever the hitstop (the
## pursuit hang and every stun still stop during hitstop).
func _tick_frozen_hangs(delta: float) -> void:
	var pdt := own_delta(delta)
	if _air_hang_left > 0.0 and is_lifted():
		_air_hang_left = maxf(_air_hang_left - pdt, 0.0)
	if _hang_left > 0.0 and _hang_keep:
		_hang_left = maxf(_hang_left - pdt, 0.0)

## One tick of the hang: no gravity, no vertical motion. A kept hang (an air
## strike's) moves sideways with the strike's own step toward its target
## (CombatController's forced velocity) and turns toward face_dir.
func _tick_hang(pdt: float, factor: float) -> void:
	var hv := Vector3.ZERO
	if _hang_keep and combat and combat.has_forced_velocity():
		var f := combat.get_forced_velocity()
		hv = Vector3(f.x, 0.0, f.z)
	if hv.length_squared() > 1e-6:
		velocity = hv * factor
		move_and_slide()
	velocity = hv
	if _hang_keep and (combat == null or combat.can_turn()):
		var fd := Vector3(face_dir.x, 0.0, face_dir.z)
		if fd.length_squared() > 1e-4:
			fd = fd.normalized()
			var rate := Tuning.TURN_SPEED * (combat.get_turn_mult() if combat else 1.0)
			rotation.y = rotate_toward(rotation.y, atan2(-fd.x, -fd.z), rate * pdt)

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
	_tick_pending_spin()
	if combat:
		combat.physics_tick(delta)  # B applies player time to combat timers
	var frozen := is_frozen()
	if frozen and _jitter > 0.0 and rig and not is_body_simulating():
		rig.position = _rig_rest_pos + Vector3(randf_range(-1, 1), randf_range(-0.5, 0.5),
			randf_range(-1, 1)) * _jitter
	# Round 7 reactions: the clock runs in own time and stops during hitstop;
	# the reaction moves the capsule itself (slide, spin, lift arc). Round 8:
	# the break's clock runs under any reaction (and while down).
	if not frozen:
		_tick_broken(delta)
	else:
		_tick_frozen_hangs(delta)
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
	# Pursuit hang (Defence): held still in the air until it runs out or an
	# attack starts. An air strike's hang (begun during the attack) runs out.
	if _hang_left > 0.0:
		if combat and combat.is_attacking() and not _hang_keep:
			_hang_left = 0.0  # the pursuit attack started: the hang ends
		else:
			_hang_left = maxf(_hang_left - pdt, 0.0)
			_tick_hang(pdt, factor)
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
	_end_react()  # a stagger can tip into a launch too
	_leave_stance()
	GameEvents.fighter_launched.emit(self, v)

func _on_ragdoll_landed() -> void:
	if _sweep_flight:
		_sweep_flight = false
		ragdoll.set_flight_pose(&"")  # down: the body relaxes like any knockdown

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
# repop; Round 8: flinch, sweep, broken) after applying the heavy and
# anti-infinite multipliers; knockdown and launch go through knockdown() / launch().
# =============================================================================

## Apply a Round 7 / Round 8 reaction. kind: &"snap" | &"spin" | &"fold" |
## &"lift" | &"buckle" | &"push" | &"repop" | &"flinch" | &"sweep" | &"broken".
## direction: world, attacker -> victim. push: m. stun: own s the fighter
## cannot act (lift and repop: ignored, the arc decides; sweep: ignored).
## - snap, spin, push, fold, buckle: the body slides `push` m along the hit over
##   Tuning.R7_PUSH_SLIDE_SHARE of the stun, slowing evenly; from
##   Tuning.R7_PUSH_STEP_FROM the legs step with the slide (stumble steps).
##   A spin also turns REACT_SPIN_TURN degrees away over the slide. Poses:
##   P's react_<kind> (timed over the stun for snap, spin and push; held for
##   fold and buckle), else REACT_POSE_FALLBACK. A fold shorter than
##   FOLD_QUICK_MAX is a quick half-keel that comes straight back up.
## - flinch (Round 8 taps): the struck bone's chain (info.hit_bone,
##   RagdollController.hit_chain) goes Tuning.REACT_FLINCH physical while the
##   body stays animated, and the struck bone takes the Round 5 flinch kick
##   along the hit; the body slides `push` m over FLINCH_SLIDE_SHARE of the
##   stun with its feet planted. Nothing outlasts the stun: it walks and
##   attacks right after (the chain finishes its fade under its control).
## - sweep: a knockdown onto the back, legs first (the upper body tips back,
##   the legs are thrown forward and up); reports &"down" at once.
## - broken: dazed for `stun` s (Tuning.R8_BREAK_TIME): it cannot act or block
##   (P's react_broken, else the dazed hold). CombatController.is_broken() is
##   the status once B reports it: the daze lasts while B says broken. A
##   reaction from a further hit plays on top (fold, lift, push, knockdown,
##   launch...) and the daze comes back when it ends if the break is still on
##   (a flinch on a dazed body is a bone kick and a slide; the daze stays). A
##   break that starts during a longer reaction, a lift or a knockdown waits
##   for the body to be back on its feet.
## - lift: a ballistic capsule arc (not a ragdoll launch) whose feet peak
##   info.lift_height (else Tuning.R7_LIFT_HEIGHT) above the floor, under the
##   gravity that takes R7_LIFT_HEIGHT to its peak in R7_LIFT_PEAK_TIME; `push`
##   drifts it along the hit over the arc; the arms go loose
##   (RagdollController.limp_chain). Landing turns it into a knockdown. A lift
##   on a lifted body counts as a re-pop.
## - repop (lifted body): up Tuning.R7_REPOP_HEIGHT more from where it is, at
##   most Tuning.R7_JUGGLE_MAX times per lift; past that the body falls into a
##   knockdown at once. Not during an air combo (air_hang): B decides when it
##   falls. On a body that is not lifted: a lift of R7_REPOP_HEIGHT.
## Any other kind on a lifted body adds its push to the arc (it still lands
## into a knockdown; a flinch also kicks the struck bone). A new reaction
## replaces the current one and cancels the fighter's own move (so a hit on an
## armored tell must not call this). Held and downed bodies are left to Carry /
## the ragdoll (a break still starts its clock). Emits
## GameEvents.react_started(self, kind, info.attacker).
func react(kind: StringName, direction: Vector3, push: float, stun: float, info: HitInfo = null) -> void:
	if is_dead():
		return
	if not REACT_KINDS.has(kind):
		push_warning("Fighter.react: unknown kind %s" % kind)
		return
	var dir := Vector3(direction.x, 0.0, direction.z)
	if dir.length_squared() < 1e-6:
		dir = -get_forward()
	dir = dir.normalized()
	var bone: StringName = info.hit_bone if info != null and info.hit_bone != &"" else Bones.CHEST
	var attacker: Node3D = info.attacker if info != null else null
	push = maxf(push, 0.0)
	stun = maxf(stun, 0.0)
	if kind == &"broken":
		_begin_broken(dir, push, stun, attacker)
		return
	if is_held():
		return
	if is_down():
		ragdoll.flinch(dir, bone, 0.5)  # already falling: a nudge, no new state
		return
	if kind == &"sweep":
		_sweep(dir, bone, attacker)
		return
	if is_lifted():
		_react_attacker = attacker
		if kind == &"repop" or kind == &"lift":
			if _repops >= Tuning.R7_JUGGLE_MAX and not _air_combo:
				knockdown(dir, bone)  # past the juggle cap: no re-pop, the body falls
				return
			_repops += 1
			_pop(Tuning.R7_REPOP_HEIGHT, dir, push, true)
			GameEvents.react_started.emit(self, &"repop", attacker)
		else:
			if kind == &"flinch":
				_flinch_bone(dir, bone)
			_pop(0.0, dir, push, true)
			GameEvents.react_started.emit(self, kind, attacker)
		return
	if kind == &"flinch" and _react_kind == &"broken":
		# Dazed: the tap lands on the body (bone kick, slide); the daze stays.
		_react_attacker = attacker
		_react_dir = dir
		_react_t = 0.0
		_start_slide(push, stun * FLINCH_SLIDE_SHARE)
		_flinch_bone(dir, bone)
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
		_air_hang_left = 0.0
		_air_combo = false
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
	_start_slide(push, stun * (FLINCH_SLIDE_SHARE if kind == &"flinch" else Tuning.R7_PUSH_SLIDE_SHARE))
	var side := 0
	if kind == &"spin":
		# The head and shoulders turn away with the hook: toward the side the
		# hit travels (yaw + turns left); straight on, to the right.
		var right := global_basis.x
		var lat := dir.dot(Vector3(right.x, 0.0, right.z).normalized())
		side = 1 if lat > 0.1 or absf(lat) <= 0.1 else -1
		_turn_rate = -float(side) * deg_to_rad(REACT_SPIN_TURN) / _slide_time
	if kind == &"flinch":
		_flinch_bone(dir, bone)
	_play_react_pose(kind, stun, side)
	GameEvents.react_started.emit(self, kind, attacker)

## The push slide: `push` m along _react_dir over `time` own s, slowing evenly;
## from Tuning.R7_PUSH_STEP_FROM the legs step with it.
func _start_slide(push: float, time: float) -> void:
	_slide_time = maxf(time, 1e-3)
	_slide_v0 = 2.0 * push / _slide_time
	_slide_steps = push >= Tuning.R7_PUSH_STEP_FROM - 1e-4

## The current reaction state: &"" | &"snap" | &"spin" | &"fold" | &"lift" |
## &"buckle" | &"push" | &"flinch" | &"broken" | &"down" (knocked down,
## launched, getting up or dead; a sweep reports &"down" at once). A re-popped
## body still reports &"lift"; a reaction on top of a break reports its own kind.
func get_react_state() -> StringName:
	if is_down():
		return &"down"
	return _react_kind

## Own seconds left in the current reaction (0 when none). Lift: the time to
## land from the arc as it is now (plus any air hang). Broken: the break left.
func get_react_time_left() -> float:
	if _react_kind == &"":
		return 0.0
	if _react_kind == &"lift":
		var h := maxf(global_position.y - _lift_floor, 0.0)
		return _air_hang_left + (_lift_vy + sqrt(_lift_vy * _lift_vy + 2.0 * _lift_g * h)) / maxf(_lift_g, 0.01)
	if _react_kind == &"broken":
		return maxf(_broken_left, 0.0)
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

## End the current reaction now, with no knockdown, and any break's daze
## (death, tests). Safe to call any time. B's own broken status is B's.
func clear_react() -> void:
	_broken_left = 0.0
	_broken_seen = false
	_end_react()

## End the current reaction (knockdown, launch, a grab): the break's clock keeps
## running, and its daze comes back once the body is on its feet.
func _end_react() -> void:
	_air_hang_left = 0.0
	_air_combo = false
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
		_end_react()
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
	if _react_kind != &"broken":
		_react_left -= pdt
	if free:
		_move_slide(t0, pdt, factor)
	var over := _broken_left <= 1e-6 if _react_kind == &"broken" else _react_left <= 1e-6
	if over:
		var dazed_left := _react_kind != &"broken" and _broken_left > 1e-6
		var last_dir := _react_dir
		_end_react()
		if dazed_left:
			_enter_broken(last_dir, 0.0)  # the break is still on: back to the daze
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
## Landing (floor, falling) turns into a knockdown along the last hit. During
## an air hang the body holds still (no fall, no drift); the arc then goes on
## from where it was.
func _move_lift(pdt: float, factor: float) -> void:
	if _air_hang_left > 1e-6:
		_air_hang_left = maxf(_air_hang_left - pdt, 0.0)
		velocity = Vector3.ZERO
		if animator:
			animator.set_locomotion(Vector3.ZERO, Tuning.WALK_SPEED)
		return
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

## P's react_<kind> pose, else the first fallback the library has. Snap, spin,
## push and flinch play as timed moves over `stun`; fold, buckle, lift and
## broken hold until the reaction ends, except a fold under the quick
## threshold, which plays P's react_fold timed (the quick half-keel). `side`
## (spin): 1 = turning right, which plays P's mirrored react_spin_r (the torso
## leads the turn).
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
	var hold := kind == &"fold" or kind == &"buckle" or kind == &"lift" or kind == &"broken"
	if kind == &"fold" and stun < fold_quick_max():
		hold = false
	for id in ids:
		if hold and (PoseLibrary.HOLDS.has(id) or PoseLibrary.POSES.has(id)):
			animator.hold_pose(id, REACT_POSE_BLEND)
			_react_hold = id
			return
		if PoseLibrary.has_move(id):
			animator.play_timed(id, maxf(stun if not hold else get_react_time_left(), 0.1))
			return

## Stun under which a fold is P's quick half-keel (react_fold's "quick"
## threshold in PoseLibrary, else FOLD_QUICK_MAX).
static func fold_quick_max() -> float:
	var def: Dictionary = PoseLibrary.MOVES.get(&"react_fold", {})
	var quick: Array = def.get("quick", [])
	return float(quick[0]) if quick.size() >= 2 else FOLD_QUICK_MAX

func _end_react_pose() -> void:
	if _react_hold != &"" and animator and get_state() == RagdollController.State.ANIMATED:
		animator.release_pose(REACT_POSE_RELEASE)
	_react_hold = &""

# --- Round 8 reactions --------------------------------------------------------------
## The flinch's physical hit: the struck bone's chain (RagdollController.hit_chain)
## goes Tuning.REACT_FLINCH "physics" for its "fade" through
## RagdollController.limp_chain, so the fighter stays animated and in control;
## the struck bone takes the Round 5 flinch kick along `dir`
## (RagdollProfile.flinch_impulse / its mass, clamped to flinch_dv_min..max,
## x FLINCH_STRENGTH), the rest of the chain FLINCH_CHAIN_SHARE of its own, and
## a sideways head hit turns the head (RagdollController.HEAD_TWIST). A lost
## limb's hit lands on the body.
func _flinch_bone(dir: Vector3, bone: StringName) -> void:
	if ragdoll == null or rig == null or ragdoll.is_full_ragdoll() \
			or get_state() == RagdollController.State.GETUP:
		return
	var chain := RagdollController.hit_chain(bone)
	if rig.is_bone_severed(chain[0]):
		chain = RagdollController.hit_chain(Bones.CHEST)
		bone = Bones.CHEST
	# The struck body: the bone itself, else its nearest ancestor in the chain
	# (a hand rides its forearm), else the chain's first bone.
	var struck: StringName = chain[0]
	var b := bone
	while b != &"":
		if chain.has(b):
			struck = b
			break
		b = Bones.PARENT.get(b, &"")
	var r: Dictionary = Tuning.REACT_FLINCH
	ragdoll.limp_chain(chain, float(r["physics"]), float(r["fade"]))
	var prof := ragdoll.profile
	for cb: StringName in chain:
		var pb := rig.get_physical_bone(cb)
		if pb == null or rig.is_bone_severed(cb):
			continue
		var dv := FLINCH_STRENGTH
		if prof != null:
			dv *= clampf(prof.flinch_impulse / maxf(pb.mass, 0.1), prof.flinch_dv_min, prof.flinch_dv_max)
		if cb != struck:
			dv *= FLINCH_CHAIN_SHARE
		var rid := pb.get_rid()
		var lv: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, lv + dir * dv)
		if cb == struck and cb == Bones.HEAD:
			# The fist lands on the face, ahead of the neck: a sideways hit turns it.
			var av: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
			var twist := get_forward().cross(dir) * RagdollController.HEAD_TWIST * FLINCH_STRENGTH
			PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, av + twist)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING, false)
	if _arms_loose and chain.any(func(x: StringName) -> bool: return LIFT_ARMS.has(x)):
		ragdoll.limp_chain(LIFT_ARMS, LIFT_ARM_LIMP, 0.0)  # a lifted body's arms stay loose (held, no fade)

## The sweep: a knockdown with the upper body tipped back (against the
## victim's facing), then both legs thrown forward and up (SWEEP_LEG_*), the
## struck leg most, so the body falls onto its back legs first. The struck leg
## is the hit bone's, else the one on the side the sweep comes from.
func _sweep(dir: Vector3, bone: StringName, attacker: Node3D) -> void:
	var fwd := get_forward()
	var left := bone in [Bones.L_UPPER_LEG, Bones.L_LOWER_LEG, Bones.L_FOOT]
	var right := bone in [Bones.R_UPPER_LEG, Bones.R_LOWER_LEG, Bones.R_FOOT]
	if not left and not right:
		# Hit travelling toward the victim's right came from its left.
		var rgt := Vector3(global_basis.x.x, 0.0, global_basis.x.z).normalized()
		left = dir.dot(rgt) >= 0.0
		bone = Bones.L_LOWER_LEG if left else Bones.R_LOWER_LEG
	knockdown(-fwd, bone)
	if ragdoll == null or rig == null or not ragdoll.is_full_ragdoll():
		return
	var kick := fwd * SWEEP_LEG_FWD + Vector3.UP * SWEEP_LEG_UP
	for lb: StringName in SWEEP_LEG_SHARE:
		var pb := rig.get_physical_bone(lb)
		if pb == null or rig.is_bone_severed(lb):
			continue
		var same := (lb in [Bones.L_UPPER_LEG, Bones.L_LOWER_LEG, Bones.L_FOOT]) == left
		var k: float = SWEEP_LEG_SHARE[lb] * (1.0 if same else SWEEP_OTHER_LEG)
		ragdoll.nudge(pb.global_position, kick * k)
	if PoseLibrary.HOLDS.has(SWEEP_POSE) or PoseLibrary.POSES.has(SWEEP_POSE):
		ragdoll.set_flight_pose(SWEEP_POSE)  # P's sweep fall, until the body lands
		_sweep_flight = true
	GameEvents.react_started.emit(self, &"sweep", attacker)

## A break starts: its clock (`stun`, else Tuning.R8_BREAK_TIME) runs from now,
## the fighter's move stops, and the daze shows at once on a free body (or on
## top of a flinch); during a longer reaction, a lift or a knockdown it waits
## for the body to be back on its feet.
func _begin_broken(dir: Vector3, push: float, stun: float, attacker: Node3D) -> void:
	_broken_left = stun if stun > 0.0 else Tuning.R8_BREAK_TIME
	_broken_seen = false
	var waits := is_down() or is_held() or is_lifted() \
		or not (_react_kind == &"" or _react_kind == &"flinch" or _react_kind == &"broken")
	if not is_down() and not is_held() and combat:
		combat.on_reaction(HitInfo.Reaction.STAGGER, 0.0)  # it cannot act: its move stops
	GameEvents.react_started.emit(self, &"broken", attacker)
	if waits:
		return
	_react_attacker = attacker
	_enter_broken(dir, push)

## Show the daze for the break's time left: state &"broken", P's react_broken
## hold (else REACT_POSE_FALLBACK), `push` m of slide.
func _enter_broken(dir: Vector3, push: float) -> void:
	var attacker := _react_attacker
	if _react_kind != &"":
		_end_react()
	clear_forced_velocity()
	if rig:
		rig.position = _rig_rest_pos
	_react_kind = &"broken"
	_react_attacker = attacker
	_react_dir = dir
	_react_t = 0.0
	_react_left = 0.0
	_turn_rate = 0.0
	_start_slide(push, _broken_left * Tuning.R7_PUSH_SLIDE_SHARE)
	_play_react_pose(&"broken", _broken_left, 0)

## The break's clock (own time; not during hitstop): B's is_broken() /
## get_broken_time_left() once B reports the break, else our own countdown.
## A body back on its feet with the break still on goes back to the daze.
func _tick_broken(delta: float) -> void:
	if combat == null and _broken_left <= 0.0:
		return
	if combat != null and combat.is_broken():
		if not _broken_seen and _broken_left <= 0.0:
			return  # B's break without a react(&"broken") call: B's to show
		_broken_seen = true
		_broken_left = maxf(combat.get_broken_time_left(), 1e-4)
	elif _broken_seen:
		_broken_seen = false
		_broken_left = 0.0  # B ended the break
	elif _broken_left > 0.0:
		_broken_left = maxf(_broken_left - own_delta(delta), 0.0)
	if _broken_left > 0.0 and _react_kind == &"" and not is_dead() and not is_down() and not is_held() \
			and get_state() == RagdollController.State.ANIMATED:
		_enter_broken(-get_forward(), 0.0)


# =============================================================================
# Round 8 contract stubs (lead). Owner H implements; callers code against them now.
# =============================================================================

## Enemy level 1..3 (FighterFactory sets it at spawn from the wave; the player and the Duelist are 1).
var level := 1

## Air combo: freeze this lifted body's vertical motion and its drift for
## `seconds` of its own time from now, hitstop included (its arc then goes on
## from where it was: the same vertical speed and drift). Calls keep the
## longest hang left and repeat as often as B calls. No effect unless
## is_lifted(). Once called in a lift, the Round 7 re-pop cap no longer knocks
## the body down: B decides the combo.
func air_hang(seconds: float) -> void:
	if not is_lifted() or seconds <= 0.0:
		return
	_air_hang_left = maxf(_air_hang_left, seconds)
	_air_combo = true
	velocity = Vector3.ZERO

## Own seconds the lifted body still hangs (0 when not hanging). Tests, debug.
func get_air_hang_left() -> float:
	return _air_hang_left if is_lifted() else 0.0

# =============================================================================
# Round 9 contract stub (lead). Owner H implements; B calls it on a charged hook.
# =============================================================================

## Spin this fighter's ragdoll around the vertical axis through its centre of
## mass at `rate` rad/s (positive = counter-clockwise seen from above), on top of
## a launch or knockdown that has just started. No effect while animated.
## Every simulated bone gets w x r (r from the centre of mass) on its linear
## velocity and w on its angular velocity. A body in a hitstop hold gets it
## when the hold ends (the hold would drop it); one not yet fully simulating
## gets it next tick if it is by then, else never.
func add_spin(rate: float) -> void:
	if ragdoll == null or rig == null or is_dead() or absf(rate) < 1e-4:
		return
	if ragdoll.is_full_ragdoll() and not ragdoll.is_in_hitstop():
		_apply_spin(rate)
		return
	_spin_pending += rate
	_spin_frame = Engine.get_physics_frames()

var _spin_pending := 0.0   ## rad/s of add_spin() waiting for the bodies (hitstop, or not simulating yet)
var _spin_frame := -1      ## physics frame of that call

## Called each physics tick: a pending spin lands once the hold is over; on a
## body not fully simulating it waits one tick only.
func _tick_pending_spin() -> void:
	if _spin_pending == 0.0 or Engine.get_physics_frames() == _spin_frame:
		return
	if ragdoll == null or is_dead() or not ragdoll.is_full_ragdoll():
		_spin_pending = 0.0
		return
	if ragdoll.is_in_hitstop():
		return
	var rate := _spin_pending
	_spin_pending = 0.0
	_apply_spin(rate)

func _apply_spin(rate: float) -> void:
	var rids: Array[RID] = []
	var pos := PackedVector3Array()
	var com := Vector3.ZERO
	var m := 0.0
	for b: StringName in Bones.PHYSICAL:
		if rig.is_bone_severed(b):
			continue
		var pb := rig.get_physical_bone(b)
		if pb == null:
			continue
		var rid := pb.get_rid()
		var xf: Transform3D = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
		rids.append(rid)
		pos.append(xf.origin)
		com += xf.origin * pb.mass
		m += pb.mass
	if m <= 0.0:
		return
	com /= m
	var w := Vector3(0.0, rate, 0.0)
	for k in rids.size():
		var rid := rids[k]
		var r := pos[k] - com
		r.y = 0.0
		var lv: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, lv + w.cross(r))
		var av: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, av + w)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING, false)
