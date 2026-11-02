class_name HitInfo
extends RefCounted
## One hit, built by the attacker's CombatController (or ImpactResolver for
## body-on-body hits) and passed to the defender. OWNER: core (contract).

enum Reaction { NONE, FLINCH, STAGGER, LAUNCH }
enum Result { IGNORED, HIT, BLOCKED, DODGED, GRAB_BROKEN }
## Attack height (Upgrade 2: Crouch and jump). HIGH misses crouching fighters,
## LOW misses jumping ones, a crouching block stops LOW.
enum Level { HIGH, MID, LOW }

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

func _to_string() -> String:
	return "HitInfo(%s %s dmg=%.0f react=%d v=%s)" % [move_id, kind, damage, reaction, launch_velocity]
