extends Node
## Autoload "GameEvents": global signal bus. The system that owns an event emits
## it; anyone may listen. Fighters are typed Node3D to keep this file free of
## module dependencies. OWNER: core (contract). Add signals, never rename.

# Other modules emit these signals, so none is used inside this file.
@warning_ignore_start("unused_signal")

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

# Upgrade 2: input, combos and states (B emits unless noted)
signal charge_started(fighter: Node3D, move_id: StringName)
signal charge_level_changed(fighter: Node3D, level: int)
signal charge_released(fighter: Node3D, move_id: StringName, level: int)
## A combo hit landed. count = hits in the current combo; damage_scale applied to it.
signal combo_progress(attacker: Node3D, count: int, damage_scale: float)
signal combo_ended(attacker: Node3D, count: int)
## Round 3 anti-infinite: a comboed victim broke away (Tuning.COMBO_ESCAPE_*). (B emits.)
signal combo_escaped(victim: Node3D, attacker: Node3D)
signal stumbled(fighter: Node3D, duration: float)
signal tripped(fighter: Node3D)
signal dazed(fighter: Node3D, duration: float)
## Zone damage built up on a limb (BodyZones.Zone); arms break at Tuning.ARM_BREAK_AT.
signal limb_damaged(fighter: Node3D, zone: int, total: float)
signal arm_broken(fighter: Node3D, zone: int)
## H emits the movement ones.
signal crouch_changed(fighter: Node3D, crouching: bool)
signal jumped(fighter: Node3D)
signal landed(fighter: Node3D)
## The player's aimed zone on the soft target changed (H emits; target null = none).
signal aim_zone_changed(aimer: Node3D, target: Node3D, zone: int)
## Limb grabs (G emits) and wall slams (B emits).
signal limb_grab_started(grabber: Node3D, victim: Node3D, bone: StringName)
signal limb_grab_released(grabber: Node3D, victim: Node3D, velocity: Vector3)
signal wall_slam(grabber: Node3D, victim: Node3D, wall: Node3D)
## Round 3: a fighter's strike landed on a wall, prop or pillar (D emits from
## receive_strike). result: &"chip" | &"crack" | &"hole" | &"break" | &"hold"
## (unbreakable: outer concrete). surface: &"drywall", &"brick", &"wood", &"concrete".
signal wall_struck(attacker: Node3D, wall: Node3D, position: Vector3, normal: Vector3, power: float, result: StringName, surface: StringName)
## Round 4: the player's lock-on target changed (E emits; target null = unlocked).
signal lock_on_changed(fighter: Node3D, target: Node3D)
## Focus: the world slows, the player does not (H emits).
signal focus_started(fighter: Node3D)
signal focus_ended(fighter: Node3D)

# Round 5: Feel Reference. hit_landed is the contact frame: flash, sound, blood,
# shake and slow time all key off it (HitInfo.power / HitInfo.tier). Effects,
# camera and TimeDirector LISTEN to these; combat code does not call them.
## B: any strike's startup began (sprint = thrown at sprint speed; target may be null).
## The AI reads it to sidestep sprint attacks and guard tapped strikes.
signal strike_started(attacker: Node3D, target: Node3D, move_id: StringName, sprint: bool, charge_level: int)
## H (Defence): a timed Block press parried `attacker` (it is staggered). TimeDirector slows time.
signal parried(defender: Node3D, attacker: Node3D)
## H (Defence): a Block tap with no attack in its window; parry is locked out.
signal parry_whiffed(defender: Node3D)
## H (Defence): vanish at `from`, appear at `to`. kind: &"counter" (behind an attacker) | &"pursuit".
## TimeDirector slows time for &"counter"; FX leaves the after-image at `from`.
signal teleported(fighter: Node3D, from: Vector3, to: Vector3, kind: StringName)
## H (Defence): Dash in the window without a full Focus bar (or no room to teleport).
signal sidestepped(fighter: Node3D, direction: Vector3)
## H (Defence): the counter bonus on the next hit changed (0 = expired or used).
signal counter_bonus_changed(fighter: Node3D, bonus: float)
## M (Traversal): sprint state; sprint_charge itself is polled (Traversal.sprint_charge).
signal sprint_started(fighter: Node3D)
signal sprint_ended(fighter: Node3D)
## M: a footstep of a moving player. surface from WorldTags.surface_of (&"concrete", &"water", &"metal", ...).
signal footstep(fighter: Node3D, position: Vector3, surface: StringName, sprint_charge: float)
## M: automatic parkour. kind: &"step" | &"vault" | &"mantle" | &"kickoff" | &"air_mantle". height: obstacle m.
signal parkour(fighter: Node3D, kind: StringName, position: Vector3, height: float)
## M: wall run. side: -1 wall on the left, +1 on the right.
signal wall_run_started(fighter: Node3D, wall: Node3D, side: int)
signal wall_run_step(fighter: Node3D, position: Vector3, normal: Vector3)
## reason: &"time" | &"end" | &"stick" | &"jump" | &"strike" | &"hit"
signal wall_run_ended(fighter: Node3D, reason: StringName)
## M: every player landing. level: &"soft" | &"hard" | &"heavy" (heavy also emits shockwave).
signal landing(fighter: Node3D, level: StringName, position: Vector3, vertical_speed: float)
## M: heavy-landing / slam shockwave (enemies inside stumble / knockdown radius react).
signal shockwave(fighter: Node3D, position: Vector3, stumble_radius: float, knockdown_radius: float)
## M: Battering Ram collision. result: what happened to the victim (&"flinch" | &"stumble" | &"knockdown" | &"launch" (Round 7, level 3));
## self_result: to the runner (&"none" | &"stumble" | &"knockdown").
signal rammed(runner: Node3D, victim: Node3D, result: StringName, self_result: StringName)
## G (Carry): holder started or stopped holding `held` (a Fighter, alive or dead, or a ThrowableProp; null = let go).
signal carry_changed(holder: Node3D, held: Node3D)
## G: air attack while holding a body: holder lands on it.
signal body_slammed(holder: Node3D, victim: Node3D, position: Vector3)
## G: props in hand.
signal prop_picked_up(holder: Node3D, prop: Node3D)
signal prop_thrown(holder: Node3D, prop: Node3D, velocity: Vector3)
## D: a thrown prop broke (burst FX). kind: ThrowableProp.kind.
signal prop_broken(prop: Node3D, position: Vector3, kind: StringName)
## D: a flying body (launched or thrown) broke a wall. Focus +0.5 goes to whoever
## launched or threw it (ImpactResolver.get_launcher(flyer)).
signal wall_broken_by(flyer: Node3D, wall: Node3D, energy: float)
## C: an enemy who lost a limb started (or stopped) fleeing: limping or crawling away.
signal fleeing_changed(fighter: Node3D, fleeing: bool)
## J (GameMode): the last enemy of a wave died. Camera close-up + TimeDirector &"last_kill".
signal last_kill(fighter: Node3D)
## J: the player died in Waves; the run is over (results screen data).
signal run_ended(stats: Dictionary)

# Round 6: more destruction. Effects, camera, AI nav and counts LISTEN to these.
## K: a clutter object broke. by = the flying body or the attacker that broke it (null: a blast or a fall).
signal furniture_broken(node: Node3D, position: Vector3, kind: StringName, energy: float, by: Node3D)
## D: part of the structure collapsed: unsupported panel cells fell, or a snapped
## pillar dropped what it held up. kind: &"panel" | &"overhead" | &"platform" | ...
signal structure_collapsed(node: Node3D, position: Vector3, kind: StringName)
## D (WorldDamage): the floor took damage. level 1 crack, 2 crater, 3 rubble (the new level reached).
signal floor_damaged(position: Vector3, radius: float, level: int, surface: StringName)
## D (WorldDamage): a blast was applied to the breakables around `center`.
## source: &"slam" | &"heavy_landing" | &"wall_break" | &"structure"
signal world_blast(center: Vector3, radius: float, power: float, source: StringName)

# Round 7: freeflow combat (docs/Round 7 — Freeflow Combat.md). Effects, camera,
# HUD and AI LISTEN to these; the owner named on each emits it.
## B: a player hit landed inside a chain. count = hits in the chain so far (HUD combo counter).
signal chain_hit(attacker: Node3D, victim: Node3D, move_id: StringName, count: int)
## B: the chain dropped (grace ran out, a whiff, or the attacker was hit). count = its final length.
signal chain_ended(attacker: Node3D, count: int)
## B: a strike glides to its target before its startup (camera smoothing, whoosh).
signal glide_started(fighter: Node3D, target: Node3D, distance: float)
## B: an enemy attack's counter window on `target` opened (open = true) or closed.
## counterable: false for grabs and the shoulder charge (blue tell: dodge only).
signal counter_window(attacker: Node3D, target: Node3D, open: bool, counterable: bool)
## H (Defence): a Counter press caught `attacker`'s attack; the counter move follows.
signal countered(defender: Node3D, attacker: Node3D)
## H (Defence): a Counter press with no counterable window (whiff lock starts).
signal counter_whiffed(defender: Node3D)
## M (Traversal): a dodge started. direction: world, flat.
signal dodged(fighter: Node3D, direction: Vector3)
## H (Fighter): a reaction started. kind: Fighter.react kind (&"snap", &"spin", &"fold",
## &"lift", &"buckle", &"push", &"repop"); knockdown and launch keep their own events.
signal react_started(victim: Node3D, kind: StringName, attacker: Node3D)
## G (Carry): a drive started / ended. reason: &"release" | &"slam" | &"shove" | &"timeout" | &"hit" | &"drop".
signal drive_started(holder: Node3D, held: Node3D)
signal drive_ended(holder: Node3D, reason: StringName)
## G: the driven body met something. result: &"break" (went through) | &"slam" | &"shove" | &"bowl".
## target: the breakable or the bowled fighter. speed: m/s at contact.
signal drive_impact(holder: Node3D, victim: Node3D, target: Node3D, position: Vector3, speed: float, result: StringName)
## G: throw wind-up progress 0..1 while LMB is held with a body (FX arm glow, camera zoom). 0 = ended.
signal throw_windup(holder: Node3D, amount: float)

# Round 8: charge and pressure (docs/Round 8 — Charge and Pressure.md). The
# Upgrade 2 charge signals are reused: charge_started(fighter, move_id) when a held
# press passes R8_TAP_MAX; charge_level_changed(fighter, level) when c crosses one
# of the move's steps (level = steps passed); charge_released(fighter, move_id, level)
# at the release (or the auto-fire). All emitted by B.
## B: the charge reached full (the meter flashes; it fires itself R8_CHARGE_HOLD_AT_FULL later).
signal charge_full(fighter: Node3D, move_id: StringName)
## B: a charge ended without a strike. reason: &"hit" | &"cancel" | &"grabbed" | &"down".
signal charge_cancelled(fighter: Node3D, move_id: StringName, reason: StringName)
## B: a fighter's pressure broke (dazed and open for R8_BREAK_TIME). attacker: who filled it last.
signal pressure_broken(fighter: Node3D, attacker: Node3D)
## B: the break ended (the fighter can act again).
signal pressure_recovered(fighter: Node3D)
## M: the player's launcher jump toward a lifted body started.
signal air_follow_started(fighter: Node3D, target: Node3D)
## B: an air strike landed. count: air hits in this combo so far (hangs while count <= debug_air_hits).
signal air_hit(attacker: Node3D, victim: Node3D, count: int)

# Flow
signal round_started(mode: StringName)
signal wave_started(index: int, total: int)
signal wave_cleared(index: int)
signal round_over(player_won: bool)
signal screen_shake(trauma: float)      ## 0..1 added to the camera's trauma
