class_name MoveData
extends Resource
## Frame data and hit properties of one move (spec: Combat system > Moves).
## Frame counts are at 60 fps (Tuning.frames). Built by MoveLibrary.
## OWNER: agent B (fighter & combat).

@export var id: StringName
## PoseAnimator move id (play_move). Usually the same as id.
@export var anim: StringName
## &"strike" | &"grab" | &"counter" | &"projectile" | &"throw"
@export var kind: StringName = &"strike"

@export var startup := 5.0      ## frames (enemy moves: replaced by the tell time)
@export var active := 3.0       ## frames
@export var recovery := 10.0    ## frames
@export var whiff_recovery := -1.0  ## frames on a miss; -1 = same as recovery

@export var damage := 0.0
@export var reaction: int = HitInfo.Reaction.FLINCH
@export var launch_speed := 0.0     ## m/s velocity change of the victim's body
@export var fixed_launch := false   ## true: attacker speed does not add (counter, charge)
@export var up_angle := Tuning.LAUNCH_UP_ANGLE  ## degrees above horizontal
## Non-launch hits: nominal body speed used for HitInfo.energy (blood, sound, shake).
@export var nominal_speed := 2.0
@export var is_finisher := false
@export var unblockable := false
@export var sweep := false          ## leg sweep: legs go out, victim falls in place

# Hit detection
@export var limb: StringName = &"RightHand"  ## main striking bone (PoseLibrary.STRIKE_BONES[id][0])
## Every bone swept for hits (PoseLibrary.STRIKE_BONES[id]); empty = [limb].
@export var limbs: Array[StringName] = []
@export var force_bone := false     ## launch impulse always goes to target_bone
@export var limb_radius := 0.2
@export var reach := 1.1            ## m from the chest along facing (fallback query)
@export var reach_radius := 0.38
@export var height := 1.35          ## m above the feet of the fallback query (x appearance height)
@export var target_bone: StringName = &"Chest"  ## preferred bone for the launch impulse

# Feel
@export var hitstop_key: StringName = &"jab"
@export var hitstun := 0.3          ## s of victim stun on FLINCH (game time)
@export var blockstun := 8.0        ## frames
@export var block_pushback := 0.0   ## m/s blocker slides back
@export var lunge_speed := 0.0      ## m/s forward while lunging
@export var lunge_start := 0.0      ## fraction of startup at which the lunge begins
@export var lunge_through_active := true
@export var shake := 0.05           ## screen-shake trauma on hit (launches scale with energy)

## Tell armor while in startup/active: 1 absorbs flinches, 2 also staggers.
## Launches always go through. Non-player fighters add config "armor_bonus".
@export var armor := 0

# Flow
@export var chain_next: StringName = &""   ## jab chain
## Moves this one may cancel into after it HITS, within cancel_window frames of recovery.
@export var cancel_into: Array[StringName] = []
@export var cancel_window := 6.0
@export var enemy := false
@export var tell_kind: StringName = &"strike"   ## enemy tell glint: &"strike" | &"grab"

func startup_s() -> float:
	return Tuning.frames(startup)

func active_s() -> float:
	return Tuning.frames(active)

func recovery_s(hit: bool = true) -> float:
	if not hit and whiff_recovery >= 0.0:
		return Tuning.frames(whiff_recovery)
	return Tuning.frames(recovery)

func hitstop_time() -> float:
	return Tuning.HITSTOP.get(hitstop_key, 0.05)

func strike_limbs() -> Array[StringName]:
	if limbs.is_empty():
		return [limb] as Array[StringName]
	return limbs
