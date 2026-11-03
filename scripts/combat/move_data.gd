class_name MoveData
extends Resource
## Frame data and hit properties of one move. Frame counts are at 60 fps
## (Tuning.frames), in the fighter's own time. Built by MoveLibrary.
## OWNER: agent B (combat).
##
## Round 7 (docs/Round 7 — Freeflow Combat.md: Moves): a player move's frame
## data, damage, reaction, push, stun, hitstop and weight come from
## Tuning.R7_MOVES[id] (`r7`); this resource adds what the table does not say:
## where the strike lands (reach, height, hit level, target bone), which way it
## pushes (push_dir) and which limbs sweep for hits. Enemy moves carry a preset
## tier (Round 5), their damage from Tuning.DMG_ENEMY and whether the player
## can counter them.

@export var id: StringName
## PoseAnimator move id (play_move). The move id once agent P poses it.
@export var anim: StringName
## &"strike" | &"grab" | &"projectile"
@export var kind: StringName = &"strike"

@export var startup := 5.0      ## frames (enemy moves: AttackDirector.enemy_startup_frames)
@export var active := 3.0       ## frames
@export var recovery := 10.0    ## frames (Round 7 player moves: on a miss)
@export var whiff_recovery := -1.0  ## frames on a miss for enemy moves; -1 = recovery

@export var damage := 0.0       ## player moves: R7_MOVES "dmg"; enemies: DMG_ENEMY
@export var unblockable := false

# Hit detection
@export var limb: StringName = &"RightHand"  ## main striking bone (PoseLibrary.STRIKE_BONES[id][0])
## Every bone swept for hits (PoseLibrary.STRIKE_BONES[id]); empty = [limb].
@export var limbs: Array[StringName] = []
@export var force_bone := false     ## enemy moves: the hit always lands on target_bone
@export var limb_radius := 0.2
@export var reach := 1.1            ## m from the chest along facing (fallback query, glide, auto-connect)
@export var reach_radius := 0.38
@export var height := 1.35          ## m above the feet of the fallback query (x appearance height)
## Bone the strike lands on when it connects without a limb contact (auto-connect,
## the counter, enemy force_bone hits), and the animator's aim point.
@export var target_bone: StringName = &"Chest"
## Attack height (HitInfo.Level). Not to be confused with `height` above.
@export var hit_level: int = HitInfo.Level.MID
## Strike direction in the attacker's frame (x = right, y = up, z = forward):
## a hook turns the victim across, an uppercut lifts, a roundhouse sweeps sideways.
@export var push_dir := Vector3(0.0, 0.0, 1.0)

## Kick (FX strike class, legacy guards).
@export var is_kick := false
## Round 7: no charge holds. Kept empty for older readers (tests/anim).
@export var charge_hold: StringName = &""
## Dropping strike (an attack in the air or late in a vault): the active frames
## last until the fighter lands (at most drop_max frames).
@export var drop := false
@export var drop_max := 40.0

# Feel
@export var blockstun := 8.0        ## frames
@export var lunge_speed := 0.0      ## m/s enemy step during the startup (the player lunges to its target)
@export var lunge_start := 0.0      ## fraction of startup at which that step begins
@export var lunge_through_active := true

## Tell armor while in startup/active: 1 absorbs flinches (Round 7: tapped
## punches), 2 also staggers. Non-player fighters add config "armor_bonus".
@export var armor := 0

# Flow
@export var enemy := false
@export var tell_kind: StringName = &"strike"   ## enemy tell: &"strike" | &"grab"
## Enemy moves (and other preset hits): the HitInfo.Tier they deal; -1 = none.
@export var preset_tier: int = -1

# Round 7
## A player move from Tuning.R7_MOVES: recovery is the miss value; on a hit the
## move ends after Tuning.R7_CHAIN_CUT of it (the next move may start).
@export var r7 := false
## Breaks an enemy guard and tell armor (R7_MOVES "guard_break").
@export var guard_break := false
## Enemy moves: the player can counter it (orange tell). False for grabs and
## the heavy's shoulder charge (blue tell: dodge only).
@export var counterable := true

func startup_s() -> float:
	return Tuning.frames(startup)

func active_s() -> float:
	return Tuning.frames(active)

## Recovery after the active frames: `hit` = a hit landed. Round 7 player
## moves recover in R7_MOVES' miss value, cut to Tuning.R7_CHAIN_CUT of it on a hit.
func recovery_s(hit: bool = true) -> float:
	if r7:
		return Tuning.frames(recovery * (Tuning.R7_CHAIN_CUT if hit else 1.0))
	if not hit and whiff_recovery >= 0.0:
		return Tuning.frames(whiff_recovery)
	return Tuning.frames(recovery)

## The Round 7 table entry of a player move: Tuning.R7_MOVES, else
## MoveLibrary.LOCAL_R7 (moves the table does not list yet); {} for enemy moves.
func r7_entry() -> Dictionary:
	if not r7:
		return {}
	return Tuning.R7_MOVES.get(id, MoveLibrary.LOCAL_R7.get(id, {}))

func strike_limbs() -> Array[StringName]:
	if limbs.is_empty():
		return [limb] as Array[StringName]
	return limbs
