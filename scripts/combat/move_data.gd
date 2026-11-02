class_name MoveData
extends Resource
## Frame data and hit properties of one move. Frame counts are at 60 fps
## (Tuning.frames), in the fighter's own time. Built by MoveLibrary.
## OWNER: agent B (combat).
##
## Round 5 (Feel Reference: Strikes and body reactions): a player strike's
## reaction comes only from its power score P (Power.score), so what defines it
## is its strike_class (base power, frame data from Tuning.STRIKE_FRAMES,
## damage from Tuning.STRIKE_DAMAGE) and push_dir (which way the hit pushes).
## Enemy moves carry a preset_tier and their damage from Tuning.DMG_ENEMY.

@export var id: StringName
## PoseAnimator move id (play_move). Usually the same as id.
@export var anim: StringName
## &"strike" | &"grab" | &"counter" | &"projectile"
@export var kind: StringName = &"strike"

@export var startup := 5.0      ## frames (enemy moves: AttackDirector.enemy_startup_frames)
@export var active := 3.0       ## frames
@export var recovery := 10.0    ## frames (Round 5 strikes: on a miss)
@export var whiff_recovery := -1.0  ## frames on a miss for moves without hit_recovery_cut; -1 = recovery

@export var damage := 0.0       ## player strikes: STRIKE_DAMAGE of the class; enemies: DMG_ENEMY
@export var unblockable := false
@export var sweep := false      ## a leg sweep: tiers by Power.sweep_tier_of

# Hit detection
@export var limb: StringName = &"RightHand"  ## main striking bone (PoseLibrary.STRIKE_BONES[id][0])
## Every bone swept for hits (PoseLibrary.STRIKE_BONES[id]); empty = [limb].
@export var limbs: Array[StringName] = []
@export var force_bone := false     ## enemy moves: the hit always lands on target_bone
@export var limb_radius := 0.2
@export var reach := 1.1            ## m from the chest along facing (fallback query)
@export var reach_radius := 0.38
@export var height := 1.35          ## m above the feet of the fallback query (x appearance height)
@export var target_bone: StringName = &"Chest"  ## bone for force_bone, sweeps and locked targets
## Attack height (HitInfo.Level). Not to be confused with `height` above.
@export var hit_level: int = HitInfo.Level.MID

# Behaviour flags
## Player move that charges while its button is held (Tuning.CHARGE_LEVELS).
@export var chargeable := false
## Hold pose while charging (falls back to power_charge / kick_chamber).
@export var charge_hold: StringName = &""
## Kick-button move.
@export var is_kick := false
## Backfist: turns to the opponent behind before striking.
@export var hits_behind := false
## Built to hit bodies on the ground (ground strikes): no wall strikes.
@export var ground_hit := false
## The last hit of its string (no hit cancel out of it).
@export var ender := false

# Feel
@export var blockstun := 8.0        ## frames
@export var lunge_speed := 0.0      ## m/s forward step without a target (enemies: their own lunge)
@export var lunge_start := 0.0      ## fraction of startup at which that step begins
@export var lunge_through_active := true

## Tell armor while in startup/active: 1 absorbs flinches, 2 also staggers.
## Launches always go through. Non-player fighters add config "armor_bonus".
@export var armor := 0

# Flow
@export var cancel_window := 10.0  ## frames of recovery in which a HIT may cancel into the string's next hit
@export var enemy := false
@export var tell_kind: StringName = &"strike"   ## enemy tell: &"strike" | &"grab"

# Round 5 (Feel Reference: Strikes and body reactions)
## &"jab" | &"cross" | &"kick" | &"sweep" | &"knee" | &"elbow" | &"ground" (Tuning.POWER_BASE);
## &"" for moves that are not power-scored strikes (grabs, enemy moves).
@export var strike_class: StringName = &""
## Strike direction in the attacker's frame (x = right, y = up, z = forward):
## a hook pushes the head across, an uppercut lifts, a roundhouse sweeps sideways.
@export var push_dir := Vector3(0.0, 0.0, 1.0)
## Enemy moves (and other preset hits): the HitInfo.Tier they deal; -1 = from P.
@export var preset_tier: int = -1
## Recovery on a landed hit is cut by Tuning.HIT_RECOVERY_CUT (recovery = the miss value).
@export var hit_recovery_cut := false
## Dropping strike: the active frames last until the fighter lands (or drop_max frames).
@export var drop := false
@export var drop_max := 40.0
## Stomp / knee drop on a body on the ground: small impulse, never launches.
@export var ground_strike := false

## Frame data of a Round 5 strike class (Tuning.STRIKE_FRAMES: startup, active, miss recovery).
func set_class_frames(cls: StringName) -> void:
	strike_class = cls
	var f: Vector3 = Tuning.STRIKE_FRAMES.get(cls, Vector3(startup, active, recovery))
	startup = f.x
	active = f.y
	recovery = f.z
	whiff_recovery = -1.0
	hit_recovery_cut = true

func startup_s() -> float:
	return Tuning.frames(startup)

func active_s() -> float:
	return Tuning.frames(active)

## Recovery after the active frames: `hit` = a hit landed. Round 5 strikes
## recover in Tuning.STRIKE_FRAMES' miss value, cut by Tuning.HIT_RECOVERY_CUT on a hit.
func recovery_s(hit: bool = true) -> float:
	if hit_recovery_cut:
		return Tuning.frames(recovery * ((1.0 - Tuning.HIT_RECOVERY_CUT) if hit else 1.0))
	if not hit and whiff_recovery >= 0.0:
		return Tuning.frames(whiff_recovery)
	return Tuning.frames(recovery)

func strike_limbs() -> Array[StringName]:
	if limbs.is_empty():
		return [limb] as Array[StringName]
	return limbs
