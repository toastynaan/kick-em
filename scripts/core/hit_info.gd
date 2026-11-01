class_name HitInfo
extends RefCounted
## One hit, built by the attacker's CombatController (or ImpactResolver for
## body-on-body hits) and passed to the defender. OWNER: core (contract).

enum Reaction { NONE, FLINCH, STAGGER, LAUNCH }
enum Result { IGNORED, HIT, BLOCKED, DODGED, GRAB_BROKEN }

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

func _to_string() -> String:
	return "HitInfo(%s %s dmg=%.0f react=%d v=%s)" % [move_id, kind, damage, reaction, launch_velocity]
