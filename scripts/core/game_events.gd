extends Node
## Autoload "GameEvents": global signal bus. The system that owns an event emits
## it; anyone may listen. Fighters are typed Node3D to keep this file free of
## module dependencies. OWNER: core (contract). Add signals, never rename.

# Combat
signal hit_landed(info: HitInfo)        ## After damage and reaction were applied.
signal hit_blocked(info: HitInfo)
signal perfect_dodge(defender: Node3D, attacker: Node3D)
signal teleport_counter(defender: Node3D, target: Node3D)
signal pursuit(attacker: Node3D, victim: Node3D)
signal air_recovery(fighter: Node3D)
signal grab_started(grabber: Node3D, victim: Node3D)
signal grab_broken(grabber: Node3D, victim: Node3D, reversal: bool)
signal thrown(grabber: Node3D, victim: Node3D, velocity: Vector3)
## Enemy tell began. kind: &"strike" (white glint, answer Block) or &"grab" (red glint, answer Grab).
signal attack_tell(attacker: Node3D, kind: StringName, duration: float)
signal attack_active(attacker: Node3D, move_id: StringName)
signal attack_whiff(attacker: Node3D, move_id: StringName)
## A defender's dodge attempt was mistimed. result: &"early" | &"late". (B emits; HUD shows it.)
signal dodge_feedback(defender: Node3D, result: StringName)
## A hit landed on an armored enemy move: damage taken, no flinch or cancel. (B emits.)
signal armor_absorbed(info: HitInfo)

# Fighters
signal fighter_spawned(fighter: Node3D)
signal fighter_launched(fighter: Node3D, velocity: Vector3)
signal fighter_grounded(fighter: Node3D)
signal fighter_recovered(fighter: Node3D)
signal fighter_damaged(fighter: Node3D, amount: float, source: StringName)
signal fighter_died(fighter: Node3D, info: HitInfo)
signal focus_changed(fighter: Node3D, value: float)
signal limb_severed(fighter: Node3D, cut: StringName, piece: Node3D)

# World
## A launched body hit a surface (floor, wall, pillar, body) with energy above Tuning.IMPACT_MIN_ENERGY.
signal body_impact(fighter: Node3D, position: Vector3, normal: Vector3, energy: float, surface: StringName)
signal wall_cracked(wall: Node3D, position: Vector3, energy: float)
signal wall_broken(wall: Node3D, position: Vector3, energy: float, velocity: Vector3)
signal body_bowled(flyer: Node3D, victim: Node3D, energy: float, chain: int)
## Impact damage dealt to a fighter by the ImpactResolver (after per-flight rules). (D emits.)
signal impact_damaged(fighter: Node3D, damage: float, energy: float, surface: StringName, position: Vector3)
## One flight broke its 2nd, 3rd... wall. count = walls broken this flight. (D emits.)
signal wall_chain(fighter: Node3D, count: int)
## A debris chunk hit the floor or a wall hard enough to be heard. (D emits.)
signal debris_landed(body: Node3D, position: Vector3, speed: float, surface: StringName)

# Flow
signal round_started(mode: StringName)
signal wave_started(index: int, total: int)
signal wave_cleared(index: int)
signal round_over(player_won: bool)
signal screen_shake(trauma: float)      ## 0..1 added to the camera's trauma
