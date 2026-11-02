class_name HitInfo
extends RefCounted
## One hit, built by the attacker's CombatController (or ImpactResolver for
## body-on-body hits) and passed to the defender. OWNER: core (contract).

enum Reaction { NONE, FLINCH, STAGGER, LAUNCH }
enum Result { IGNORED, HIT, BLOCKED, DODGED, GRAB_BROKEN }
## Attack height (Upgrade 2: Crouch and jump). HIGH misses crouching fighters,
## LOW misses jumping ones, a crouching block stops LOW.
enum Level { HIGH, MID, LOW }
## Round 5 reaction tier (Feel Reference: One power number decides the reaction).
## Strikes get it from the power score (Power.tier_of / sweep_tier_of); other
## sources preset it (enemy hits, thrown bodies, props, ram, landing shockwave).
enum Tier { NONE, FLINCH, STUMBLE, STAGGER, KNOCKDOWN, LAUNCH, HARD_LAUNCH, SEVER }

const TIER_NAMES := {Tier.NONE: &"none", Tier.FLINCH: &"flinch", Tier.STUMBLE: &"stumble",
	Tier.STAGGER: &"stagger", Tier.KNOCKDOWN: &"knockdown", Tier.LAUNCH: &"launch",
	Tier.HARD_LAUNCH: &"hard_launch", Tier.SEVER: &"sever"}

var attacker: Node3D             ## Fighter, or null for environment hits
var victim: Node3D               ## Fighter
var move_id: StringName          ## &"jab1", &"sparta_kick", &"e_hook", &"bowl", ...
var kind: StringName = &"strike" ## &"strike" | &"grab" | &"throw" | &"counter" | &"projectile" | &"bowl"
var damage: float = 0.0
var reaction: int = Reaction.FLINCH
var launch_velocity := Vector3.ZERO  ## World m/s added to the victim's body when reaction == LAUNCH
var hit_position := Vector3.ZERO     ## World point of contact
var hit_direction := Vector3.FORWARD ## World unit vector, attacker -> victim
var hit_bone: StringName = &"Chest"
var hitstop: float = 0.0             ## Real seconds of local hitstop
var energy: float = 0.0              ## J, 0.5 * victim mass * |launch_velocity|^2 (scales blood, sound, shake)
var unblockable := false
var is_finisher := false             ## Full-charge punch, teleport counter, throw: may dismember on a kill
var result: int = Result.IGNORED     ## Filled in by the defender

# Upgrade 2
var level: int = Level.MID           ## attack height
var zone: int = BodyZones.Zone.TORSO ## body zone struck or grabbed
var charge_level: int = 0            ## 0 = tap, 1..3 = charged (Tuning.CHARGE_LEVELS)
var combo_index: int = 0             ## 1-based hit number in the attacker's combo, 0 = none
var damage_scale := 1.0              ## combo scaling already applied to damage (environment damage is never scaled)
var juggle := false                  ## victim was tumbling, airborne or stumbling
var air_counter := false             ## victim was jumping (x Tuning.AIR_COUNTER_LAUNCH)

# Round 5 (Feel Reference)
## Power score P. Strikes: Power.score(). 0 for preset-tier hits.
var power := 0.0
## Reaction tier. A source may preset it (non-strikes); otherwise the receiver's
## CombatController fills it from power. Tier.NONE + power 0 = no reaction (guarded, ignored).
var tier: int = Tier.NONE
var power_base := 0.0                ## parts of P, for the debug overlay and logs
var speed_bonus := 0.0
var counter_bonus := 0.0
var finisher_bonus := 0.0
var sprint := false                  ## thrown at sprint speed (sprint, wall run, vault drop)
var ground_strike := false           ## stomp / knee drop on a body on the ground
var pursuit := false                 ## pursuit follow-up (relaunch rule)
var sever_cut: StringName = &""      ## Tier.SEVER: the Bones.CUTS key that came off

static func tier_name(t: int) -> StringName:
	return TIER_NAMES.get(t, &"none")

## Legacy Reaction for listeners that predate tiers.
static func reaction_for_tier(t: int) -> int:
	match t:
		Tier.NONE:
			return Reaction.NONE
		Tier.FLINCH:
			return Reaction.FLINCH
		Tier.STUMBLE, Tier.STAGGER:
			return Reaction.STAGGER
	return Reaction.LAUNCH

## True for every tier that sends the whole body flying (launch and up).
static func is_launch_tier(t: int) -> bool:
	return t >= Tier.LAUNCH

func _to_string() -> String:
	return "HitInfo(%s %s dmg=%.1f P=%.2f tier=%s v=%s)" % [move_id, kind, damage, power, tier_name(tier), launch_velocity]
