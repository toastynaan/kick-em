class_name CombatController
extends Node
## Moves, frame data, hit detection (hit registry: each attack hits each target
## once), the hit pipeline, guard, and the routing hub to Defence (counter:
## agent H), Carry (grabs, holds, drive, throws: agent G) and Traversal (dodge,
## sprint: agent M). Same component for the player and for enemies; enemies
## start attacks via start_enemy_attack() (tell + startup) instead of buttons.
## OWNER: agent B (combat). CONTRACT STUB: keep every public signature.
##
## Round 7 (docs/Round 7 — Freeflow Combat.md):
## - One button, one move (MoveLibrary.PLAYER_MOVES, frame data and reactions
##   from Tuning.R7_MOVES). The punch button counts jab, cross, hook (ComboGraph)
##   while the chain is alive; the punch or a kick still held at
##   Tuning.R7_HOLD_THRESHOLD is its heavy version (R7_HEAVY_OF), its startup
##   counted from the press. A tap fires on its own frame data (it waits at the
##   end of its startup, in the heavy's load pose, only while still held).
## - Commit to every swing: presses during a move's glide and startup are
##   dropped; from its first active frame on (hitstop and recovery included)
##   the latest press is buffered (a press on the beat of the hit). On a hit
##   the recovery ends after Tuning.R7_CHAIN_CUT of it (the buffered press fires
##   then); on a whiff it runs in full and the punch string resets. The chain
##   (GameEvents.chain_hit / chain_ended) survives Tuning.R7_CHAIN_GRACE after a
##   recovery, a dodge or a counter; a whiff, a blocked hit or being hit ends it.
## - Freeflow targeting: the target is picked at the press (Defence's pursuit
##   body first, else Targeting.pick_freeflow_target along the stick, else the
##   combat target, else camera forward). A target farther than reach +
##   R7_GLIDE_FROM is glided to (R7_GLIDE_SPEED, at most R7_GLIDE_MAX_TIME)
##   before the startup, stopping at reach x LUNGE_GAP; closer ones get the
##   short lunge. On the first active frame the target connects when within
##   reach + R7_CONNECT_MARGIN (auto-connect), unless invulnerable, dodging or
##   down. A hit that pushes up to R7_FOLLOW_MAX_PUSH is followed during
##   recovery (R7_FOLLOW_SHARE of it).
## - Hits: R7_MOVES, or the R7_PAYOFFS entry for the victim's react state;
##   heavy enemies scale push, stun and lift; guards and tell armor stop tapped
##   punches only; the victim's Fighter.react / knockdown / launch applies it.
##   Hitstop per move on the attacker and victim only (the player's capped at
##   R7_PLAYER_HITSTOP_MAX). Enemy hits on the player keep their Round 5 tiers.
## - The god path (the user's amendment): sprint strikes (the speed toward the
##   target, sampled at the press before Traversal.on_strike_started; wall-run
##   strikes and vault drops count as the cap) push harder or launch; dropping
##   strikes (any strike in the air or late in a vault) hit with the button's
##   move; the pursuit hit on Defence's pursuit body relaunches along camera
##   forward, or spikes it into the floor with the stick pulled back (its floor
##   impact a shockwave); Dash goes to Defence first (pursuit, teleport);
##   Defence.intercepts() on an attack's first active frame; vanished bodies are
##   not hit; the Duelist's teleport counter (start_counter). Every launch the
##   player causes is a launch tier on hit_landed (Defence's pursuit window).
## - Counter: Defence (H) calls play_counter(attacker) on a caught window. Every
##   enemy attack emits GameEvents.counter_window(attacker, target, true,
##   counterable) R7_COUNTER_WINDOW before its first active frame, and false
##   when it ends, is cancelled or the attacker is hit. An attack whose first
##   active frame finds its target invulnerable (counter, dodge) misses it.
## - Effects, camera shake and slow time listen to GameEvents; this file never
##   spawns contact effects or shakes the screen for hits.
##
## Round 8 (docs/Round 8 — Charge and Pressure.md; wins over Round 7 for strikes):
## - Charge: every strike button (the punch string's jab, cross, hook and the
##   five specials) is a tap or a charge. A press released before
##   Tuning.R8_TAP_MAX is the tap (its "tap" entry, its own frame data; a tap
##   whose target needs a glide waits for the release before gliding). Still
##   held at R8_TAP_MAX it charges (Phase.CHARGE): c goes 0 -> 1 from
##   R8_TAP_MAX to Tuning.debug_charge_full s after the press, the player walks
##   at R8_CHARGE_WALK_MULT turning to the target picked at the press, the
##   heavy_<move>_load pose deepens (PoseAnimator.set_charge_amount). At full
##   it holds R8_CHARGE_HOLD_AT_FULL, then fires itself. The meter's steps
##   (get_charge_steps) are the c values where the result changes, padded to
##   at least two ending at 1.0 (lead's rule: [0.5, 1.0] when there is none). The release re-picks
##   the target along a pushed stick, glides up to R8_CHARGE_LUNGE (lerped by
##   c), then R8_RELEASE_STARTUP frames, the tap's active frames and its
##   recovery + R8_CHARGED_EXTRA_RECOVERY (MoveLibrary.charged_move). A hit on
##   the charging player cancels it. Events: charge_started,
##   charge_level_changed (the move's steps passed), charge_full,
##   charge_released, charge_cancelled.
## - Hits: a tap from R8_MOVES[move].tap, a charged strike from .charged lerped
##   by c; a launch from c >= min(launch_from, debug_launch_step), full_react
##   and full_break at c = 1; a sideways move (the hook) pushes and launches
##   across the facing. Payoffs from R7_PAYOFFS (taps by id, charged strikes by
##   payoff_id; they do not scale with c; a non-launch payoff never replaces a
##   charged launch). Taps never break guards or tell armor; charged strikes do.
## - Pressure (victim side, every fighter): player hits add their pressure x
##   debug_pressure_mult (blocked hits x R8_BLOCKED_PRESSURE_MULT); at
##   Tuning.r8_pressure_cap(archetype, level) the fighter breaks open for
##   R8_BREAK_TIME (react &"broken": no block, no attack; hits on it x
##   R8_BREAK_DAMAGE_MULT damage, x R8_BREAK_PUSH_MULT push and launch); then it
##   is empty and fills at R8_BREAK_IMMUNE_RATE for R8_BREAK_IMMUNE. It drains
##   after R8_PRESSURE_DECAY_DELAY. Events: pressure_broken, pressure_recovered.
## - Air combo: a charged uppercut lifting a body R8_AIR_FOLLOW_MIN_LIFT or
##   more makes it the air follow target (get_air_follow_target) for
##   R8_AIR_FOLLOW_WINDOW. An attack press in the air with a lifted body within
##   R8_AIR_STRIKE_RANGE (or during Traversal's launcher jump) is an air strike
##   (MoveLibrary.air_move: R8_AIR_FRAMES, never charged). Each landed one up to
##   debug_air_hits hangs the player and the body R8_AIR_HANG; a kick launches
##   the body at R8_AIR_KICK_LAUNCH, a punch with the stick pulled back spikes it.
##
## Round 9 (docs/Round 9 — Playtest Fixes.md; wins over Round 8):
## - Hook: a charged hook's push, knockdown and launch go along the hit (no
##   longer sideways); right after its knockdown or launch the victim spins
##   (Fighter.add_spin: Tuning.R9_HOOK_SPIN lerped by c, the sign following the
##   swing: a left hook turns the victim to its left), and its knockdown hops
##   the body R9_HOOK_HOP up so the feet leave the floor. The tap is unchanged.
## - The punch string goes back to the jab only after Tuning.R9_STRING_RESET
##   with no punch press (counted from the press, or the end of that punch when
##   later). Whiffs, blocked hits, being hit and the chain ending keep it; a
##   cancel still gives the position back. The chain keeps its own rules.
## - Axe kick: a leg kick press whose target is lifted (Fighter.is_lifted) plays
##   MoveLibrary.AXE (tap or charged, Tuning.R9_AXE): a spike straight down
##   (SPIKE_DRIFT along the hit) at its speed, with the floor shockwave of its
##   "blast" radius; from the ground it auto-connects within reach horizontally
##   and up to R9_AXE "reach_up" above the feet. In the air combo the leg kick is
##   the air axe kick. No payoffs.
## - Broken = guard broken: with Tuning.R9_BROKEN_STUN false a break shows no
##   daze (no Fighter.react &"broken") and the fighter keeps moving and
##   attacking; it cannot block or guard and takes the break bonus.
## - Downed bodies: a player strike whose limb sweep touches a lying body
##   (is_lying: knocked down, a launch at rest, getting up) hits it
##   (Tuning.R9_GROUND_HIT, react &"ground", HitInfo.ground_strike): damage, a
##   whole-body shove along the strike plus lift through the ragdoll, pressure,
##   and the first such hit of a knockdown delays its get-up GROUND_HIT_HOLD.
##   Never targeted, glided to or auto-connected.
##
## Timing: move phases run in the fighter's own time (the player's in player
## time, full speed in any slow motion) and stop during its hitstop. Input
## windows (the tap, the charge, the chain grace) use TimeDirector.now() (real
## time). Pressure runs in the victim's own time.

## Round 7: LIGHT is the punch button (string + hold for heavy); the specials
## and COUNTER are appended so older ints stay stable. Legacy entries: HEAVY =
## the heavy version of the next string punch, KICK = FRONT_KICK, SWEEP =
## LEG_KICK (bots and old tests); BLOCK stays the AI's guard.
enum Action { LIGHT, HEAVY, KICK, SWEEP, GRAB, BLOCK, DASH, LEG_KICK, GUT_PUNCH, UPPERCUT,
	FRONT_KICK, ROUNDHOUSE, COUNTER }
## GLIDE: a strike closing on its target before its startup. Round 8 (appended):
## HOLD: a held press whose target needs a glide, waiting for the tap/charge
## decision (the tap glides at the release); CHARGE: charging (is_charging()).
enum Phase { IDLE, GLIDE, STARTUP, ACTIVE, RECOVERY, HOLD, CHARGE }
enum Stun { NONE, HIT, BLOCK, STUMBLE, DAZE }

signal attack_started(move_id: StringName)
## Real seconds until the first active frame, sent when an attack's startup starts (AI dodge timing).
signal attack_incoming(move_id: StringName, time_to_active: float)
signal attack_active(move_id: StringName)
signal attack_ended(move_id: StringName)
signal hit_dealt(info: HitInfo)
signal hit_received(info: HitInfo)

# --- Local tuning (candidates for Tuning) -----------------------------------
const STAGGER_STRENGTH := 0.75     ## Round 5 stagger strength: < 1 stays on its feet
const STRIKE_BREAK_HITSTOP_MULT := 2.0  ## wall strike hitstop x on &"break"
const STRIKE_RECOIL_TIME := 0.15   ## s of the recoil slide off a wall that holds
const STRIKE_FIGHTER_MARGIN := 0.6 ## m beyond reach in which an opponent takes priority over a wall
const FLOOR_NORMAL_Y := 0.7        ## contacts with a more upward normal are floors, never struck
const BLOCK_WALK_MULT := 0.35      ## walking while guarding (the AI's guard)
const BLOCK_PUSH_TIME := 0.15      ## s the guard push-back slide lasts
const ESCAPE_PUSH_TIME := 0.2      ## s of the break-away slide
const ESCAPE_VICTIM_SHARE := 0.8   ## of Tuning.COMBO_ESCAPE_PUSH covered by the victim
const LYING_HEIGHT := 0.45         ## m: a launched body with its COM this low...
const LYING_SPEED := 2.0           ## ...and slower than this is lying, not airborne
const GRAB_CONE_DOT := 0.4         ## grab only catches fighters roughly in front
const ENEMY_REACH_MARGIN := 0.5    ## m beyond an enemy move's reach + lunge in which the player is still its target
const ENEMY_REACH_FRONT_DOT := 0.5 ## ...when within 60 degrees of the enemy's facing
const PROJECTILE_SPEED := 15.0     ## m/s debris chunk
const LOCKED_TARGET_REACH := 0.9   ## m beyond reach in which a locked target (a free swing at a downed player) connects
const CARRY_OFFSET := Vector3(0.0, -0.16, -0.05)  ## chunk position in the right-hand attachment
const GUARD_FRONT_DOT := 0.3       ## guards and archetype blocks cover this front cone
const DEBRIS_KICK_RADIUS := 0.7    ## m from the kicking foot
const DEBRIS_KICK_SPEED := 14.0    ## m/s
const DEBRIS_KICK_DAMAGE := 8.0    ## a kicked chunk hits like a thrown prop (Tuning.PROP_DAMAGE)
const DEBRIS_KICK_RANGE := 10.0    ## m: a kicked chunk flies at an enemy this far (Tuning.SPRINT_TARGET_RANGE's reach)
const ARMOR_HITSTOP := 0.05        ## Round 5 armor (non-strike hits on ignore_flinch fighters)
## A normal lunge (and a glide) stops when the target is this share of the
## move's reach away (the fist lands with the arm still bending).
const LUNGE_GAP := 0.7
## m/s cap of the short lunge to a close target (a step, not a teleport).
const LUNGE_SPEED_MAX := 8.0
## Body speed (m/s) used for HitInfo.energy on hits that do not launch (old listeners scale on it).
const NOMINAL_SPEED := {HitInfo.Tier.FLINCH: 2.0, HitInfo.Tier.STUMBLE: 2.5, HitInfo.Tier.STAGGER: 3.0,
	HitInfo.Tier.KNOCKDOWN: 4.0}
# Round 7 (local; candidates for Tuning)
## Wall strike power = this x the move's R7 weight: a front kick (0.65) strikes
## with 62, about Round 3's tapped kick (60), so D's STRIKE_CELL_HP targets hold.
const WALL_POWER_PER_WEIGHT := 96.0
## Strength of the small snap tell armor shows (RagdollController.flinch; it keeps attacking).
const ARMOR_SNAP := 0.5
## m: the follow step never closes the gap to its victim below this (two capsules + a little).
const FOLLOW_MIN_GAP := 0.65
## Reactions that slide the victim on its feet: the follow step goes after them.
const FOLLOW_REACTS: Array[StringName] = [&"snap", &"spin", &"fold", &"lift", &"buckle", &"push", &"repop", &"flinch"]
## HitInfo.tier listeners see for a Round 7 reaction (doc: Reactions).
const REACT_TIER := {&"snap": HitInfo.Tier.FLINCH, &"spin": HitInfo.Tier.STAGGER,
	&"push": HitInfo.Tier.STAGGER, &"fold": HitInfo.Tier.STAGGER, &"buckle": HitInfo.Tier.STAGGER,
	&"lift": HitInfo.Tier.STAGGER, &"repop": HitInfo.Tier.STAGGER, &"knockdown": HitInfo.Tier.KNOCKDOWN,
	&"launch": HitInfo.Tier.LAUNCH, &"spike": HitInfo.Tier.LAUNCH,
	&"flinch": HitInfo.Tier.FLINCH, &"sweep": HitInfo.Tier.KNOCKDOWN, &"broken": HitInfo.Tier.STAGGER}
## Round 8 reaction kinds and the Round 7 kind played while agent H's
## Fighter.react does not know them yet (Fighter.REACT_KINDS); &"" = none.
const R8_REACT_FALLBACK := {&"flinch": &"snap", &"sweep": &"knockdown", &"broken": &""}
## s: phase ends compare with this slack, so float sums of 1/120 s ticks end a
## 7-frame startup on its 14th tick, not the 15th.
const PHASE_EPS := 1e-5
## Degrees of camera-forward drift in the spike's straight-down velocity (doc: God path).
const SPIKE_DRIFT := 5.0
## The stick pulled back (toward the camera) when Fighter has no get_input_intent:
## at least this long (0..1) and within 60 degrees of straight back (Round 5's numbers).
const INTENT_DEADZONE := 0.3
const INTENT_DOT := 0.5
## m above the Head bone's origin (the neck) a head strike aims at (agent P).
const HEAD_AIM_UP := 0.15
## s a spiked body is watched for its floor impact (the shockwave).
const SPIKE_WATCH := 3.0
## Sprint strikes (doc: God path): these moves launch at speed, the rest push.
const SPRINT_LAUNCHERS: Array[StringName] = [&"front_kick", &"roundhouse", &"uppercut"]
const PURSUIT_REACH := 2.8         ## m: the pursuit follow-up connects with the flying body inside this
const INTERCEPT_EXTRA := 2.0       ## m beyond the move's reach in which a defender's Defence is asked
const AI_COUNTER_INVULN := 0.1     ## real s of invulnerability on the AI teleport (the tell is hittable)
## A sprint lunge runs at the sprint speed, and up to this x it when that is
## needed to reach the stop point by the end of the active frames.
const SPRINT_LUNGE_BOOST := 1.5
## s: a dropping strike stays active while Traversal still falls, at most this long.
const DROP_ACTIVE_LIMIT := 3.0
## s an attack pressed early in a vault waits for the landing before it is dropped.
const VAULT_PRESS_KEEP := 1.0
## Pose played while gliding (agent P's), else the closest existing one.
const GLIDE_ANIMS: Array[StringName] = [&"glide", &"dash"]
# Round 8 (local; candidates for Tuning)
## Hold shown while charging when P has no heavy_<move>_load for the move.
const CHARGE_HOLD_FALLBACK: Array[StringName] = [&"power_charge"]
## s added to a charged glide's time limit beyond lunge / R7_GLIDE_SPEED (it stops on distance first).
const CHARGE_GLIDE_SLACK := 0.1
## s of break left below which a broken fighter's daze is not shown again after a hit reaction.
const BROKEN_SHOW_MIN := 0.1
# Round 9 (local; candidates for Tuning)
## s the first strike on a downed body keeps it down longer (once per knockdown; Round 3's GROUND_HOLD).
const GROUND_HIT_HOLD := 0.6
## Hitstop (real s, attacker only) and weight (tap, charged at c = 1) of a strike on a downed body.
const GROUND_HIT_HITSTOP := 0.05
const GROUND_HIT_WEIGHT := Vector2(0.3, 0.5)

var fighter: Fighter
var blocking := false
## AI: world direction for the next throw (Carry reads it for enemy grab-throws).
var throw_aim := Vector3.ZERO
## Result of the last receive_hit() (HitInfo.Result), -1 before any hit.
var last_result := -1
## Last HitInfo this fighter received / dealt (tests, debug HUD, overlay).
var last_received: HitInfo
var last_dealt: HitInfo
## Last wall strike {target, position, normal, power, result} (tests, debug HUD).
var last_wall_strike: Dictionary = {}
## Tests and the lab: read press/release like the player's buttons (a held
## press charges: Round 8) even without a PlayerController.
var force_hold_charge := false
## Chance a killing launch takes a limb (Tuning.R7_SEVER_ON_KILL; tests set 0 or 1).
var sever_on_kill_chance := Tuning.R7_SEVER_ON_KILL
## The punch string (jab, cross, hook and their heavies).
var graph: ComboGraph = ComboGraph.default_graph()

var _phase: int = Phase.IDLE
var _move: MoveData
var _seq_id: StringName = &""   ## move id reported by attack_ended
var _t := 0.0                   ## own-time s in the current phase
var _startup := 0.0
var _active := 0.0
var _recovery := 0.0
var _registry := {}             ## victim instance id -> true
var _prev_limbs := {}           ## bone -> last tick's position (limb sweep)
var _hit_any := false           ## struck anything (a fighter, a wall, debris): not a whiff
var _landed := false            ## landed a clean HIT on a fighter: the chain cut
var _blocked := false           ## a guard stopped it
var _first_active := false      ## the first active frame (auto-connect, invulnerable targets)
var _locked_target: Fighter     ## always connects when close (a free swing at a downed player)
var _target: Fighter            ## the attack's target, picked at the press
var _aim_set := false
var _debris_kicked := false
var _wall_struck := false       ## this move already struck a wall (once per move)
var _committed := false         ## strike_started sent for this move
# Buttons, the punch hold and the buffer
var _btn_down := {}             ## Action -> held
var _press_action := -1         ## button that started the current move
var _press_t := 0.0             ## its press time (real)
var _hold_pending := false      ## a strike press still held: it charges at R8_TAP_MAX
var _waited := false            ## a held tap reached the end of its startup and waits
var _carry_took := {}           ## Action -> the Carry action that took its press
# Sprint strikes, dropping strikes, the teleport counter
var _p_speed := 0.0             ## m/s toward the target at the press
var _p_cap := 8.0               ## speed cap at the press
var _p_sprint := false          ## a sprint strike (sprint, wall run, vault drop)
var _sprint_excepted: Fighter   ## capsule collision exception of a sprint strike
var _drop_t := 0.0              ## own s in the current dropping strike's active frames
var _drop_from_vault := false
var _vault_action := -1         ## attack pressed early in a vault: a normal strike once landed
var _vault_press_t := 0.0
var _teleport_invuln_until := 0.0
var _drop_as: StringName = &""  ## the move whose R7 entry a dropping strike hits with (the button's)
var _pursuit_spike := false     ## the pursuit hit of this move is a spike (stick pulled back at the press)
var _spiked := {}               ## victim instance id -> [victim, real time]: watched for the spike's floor impact
var _buffer_action := -1
var _buffer_time := 0.0
# Glide, lunge, follow step
var _glide_t := 0.0             ## own s gliding
var _glide_velocity := Vector3.ZERO
var _lunge_left := 0.0          ## m of short lunge left (Tuning.LUNGE_MAX)
var _lunge_velocity := Vector3.ZERO
var _has_lunge := false
var _follow_left := 0.0         ## m of follow step left
var _follow_speed := 0.0
var _follow_dir := Vector3.ZERO
var _follow_victim: Fighter
# Chains and the punch string
var _chain_count := 0
var _chain_until := -INF        ## real time the idle chain drops
var _string_next := 0           ## punch string position of the next punch (0 jab, 1 cross, 2 hook)
var _cur_string := -1           ## string position of the punch in progress (-1: not a string punch)
var _string_last := -INF        ## Round 9: real time of the last punch press (or the end of that punch)
var _combat_target: Fighter
# Counter window (enemy attacks)
var _window_open := false
var _window_target: Fighter
var _window_counterable := true
# Victim side
var _freeze_until := 0.0
var _stun_left := 0.0
var _stun_kind: int = Stun.NONE
var _guard_stun := false        ## blockstun came from a real guard (stays blocking)
var _taken := 0                 ## hits taken in the current combo (from anyone)
var _taken_last := -INF
var _taken_stun := 0.0          ## Round 5: stun taken in the current combo (break-away at COMBO_ESCAPE_STUN)
var _getup_extended := false    ## Round 9: a strike on this downed body already delayed its get-up
var _escape_guard_until := 0.0  ## break-away auto-guard
var _block_held := false
var _slide_left := 0.0          ## guard push-back slide (own time s)
var _slide_velocity := Vector3.ZERO
var _slide_plant := false       ## feet planted for the rest of the blockstun after the slide
var _dash_left := 0.0
var _dash_velocity := Vector3.ZERO
var _dash_cooldown_until := 0.0

var _carried: RigidBody3D       ## debris chunk in the right hand (Thrower)

# Round 8: the charge (player side)
var _charge_id: StringName = &""  ## the strike being charged (&"" when not charging)
var _charge_action := -1        ## its button
var _charge_t0 := 0.0           ## real time of its press
var _charge_c := 0.0            ## c now (0..1)
var _charge_full := false       ## c reached 1 (charge_full sent)
var _charge_level := 0          ## steps passed (charge_level_changed)
var _charge_steps: Array[float] = []
var _charge_target: Fighter     ## the target picked at the press
var _strike_c := 0.0            ## c of the charged strike in progress
var _glide_limit := INF         ## m the current glide may cover (a charged release: R8_CHARGE_LUNGE)
var _glide_dist := 0.0          ## m it covered
# Round 8: pressure (victim side)
var _pressure := 0.0
var _pressure_idle := 0.0       ## own s since the last pressure hit
var _broken_left := 0.0         ## own s of the break left
var _immune_left := 0.0         ## own s of the half-rate refill left
var _presser: Fighter           ## who filled it last
var _break_dir := Vector3.ZERO
# Round 8: the air combo (player side)
var _air_follow_body: Fighter   ## the charged uppercut's lifted body
var _air_follow_t := -INF       ## real time it was lifted
var _air_hits := 0              ## air hits landed in this air combo
var _air_spike := false         ## the current air strike spikes (stick pulled back at the press)

var _q_sphere := SphereShape3D.new()
var _q_capsule := CapsuleShape3D.new()
var _q_params := PhysicsShapeQueryParameters3D.new()

func setup(p_fighter: Fighter) -> void:
	fighter = p_fighter
	if not GameEvents.body_impact.is_connected(_on_body_impact):
		GameEvents.body_impact.connect(_on_body_impact)

## A fighter freed mid-attack still closes its counter window (HUD prompts).
func _exit_tree() -> void:
	_close_window()

# =============================================================================
# Input
# =============================================================================

## Button input (the player, or the AI's guard). Routing (Round 7): while
## holding a body, the punch and the leg kick go to Carry (throw, knee), Dash
## drives, Grab releases; otherwise Counter goes to Defence, Dash to Traversal
## (tap dodge, hold sprint), Grab to Carry and the rest are strikes.
func press(action: int) -> void:
	if fighter == null or fighter.is_dead():
		return
	var now := TimeDirector.now()
	match action:
		Action.BLOCK:
			_block_held = true  # the AI's guard
			_update_block_state()
		Action.DASH:
			# Holding: Carry's drive (a body; false with a prop). Then Defence
			# (teleport, pursuit), then Traversal (tap dodge, hold sprint).
			if _new_carry() and fighter.carry.is_holding() and fighter.carry.on_drive_pressed(now):
				return
			if fighter.defence != null and fighter.defence.has_method(&"on_dash_pressed") \
					and bool(fighter.defence.call(&"on_dash_pressed", now)):
				return
			if fighter.traversal != null and fighter.traversal.on_dash_pressed():
				return
			_on_dash_pressed(now)
		Action.GRAB:
			# Grabs, holds, throws and grab breaks are Carry's (agent G).
			if _new_carry():
				fighter.carry.on_grab_pressed(now)
		Action.COUNTER:
			# Defence (H) finds the open window, cancels that attack and calls play_counter().
			if fighter.defence != null:
				fighter.defence.on_counter_pressed(now)
		_:
			_btn_down[action] = true
			if _carry_press(action, now):
				return
			_strike_press(action, now)

func release(action: int) -> void:
	if fighter == null:
		return
	var now := TimeDirector.now()
	match action:
		Action.BLOCK:
			_block_held = false
			_update_block_state()
		Action.DASH:
			# Both hear the release (each ignores one it did not take).
			if _new_carry():
				fighter.carry.on_drive_released(now)
			if fighter.traversal != null:
				fighter.traversal.on_dash_released()
		Action.GRAB:
			if _new_carry():
				fighter.carry.on_grab_released(now)
		Action.COUNTER:
			pass
		_:
			_btn_down[action] = false
			if _carry_took.has(action):
				var ca: int = _carry_took[action]
				_carry_took.erase(action)
				if fighter.carry != null:
					fighter.carry.on_attack_released(ca, now)
				return
			if is_charging() and action == _charge_action:
				_release_charge()
			elif action == _press_action and _hold_pending:
				_release_hold()

## While holding: the punch throws (hold to wind up) and the leg kick knees
## (Carry). A body in hand takes every strike press (no strikes while holding
## a body); with a prop in hand the other buttons strike. True = consumed.
func _carry_press(action: int, now: float) -> bool:
	_carry_took.erase(action)
	if not _new_carry() or not fighter.carry.is_holding():
		return false
	var ca := _carry_action(action)
	if ca >= 0 and fighter.carry.on_attack_pressed(ca, now):
		_carry_took[action] = ca
		return true
	return _holding_body()

## The Carry action a strike button means while holding (-1: none). Legacy
## Heavy is the punch, legacy Sweep the leg kick.
static func _carry_action(action: int) -> int:
	match action:
		Action.LIGHT, Action.HEAVY:
			return Action.LIGHT
		Action.LEG_KICK, Action.SWEEP:
			return Action.LEG_KICK
	return -1

## A strike button: starts at once when free; dropped during a glide or a
## startup (no mashing through a wind-up); from the first active frame on
## (hitstop and recovery included) buffered, the latest press winning: players
## press the next attack on the beat of the hit. The buffered press starts when
## the move ends (the chain cut on a hit, the full recovery on a whiff).
func _strike_press(action: int, now: float) -> void:
	if _held() or _move_for(action) == &"":
		return
	match _phase:
		Phase.IDLE:
			# A vault: in its last 40% the press ends it in a dropping strike that
			# keeps the vault speed; earlier it waits for the landing.
			if _vaulting():
				if _vault_progress() >= Tuning.VAULT_ATTACK_FROM and _traversal_call(&"begin_drop_strike"):
					_drop_from_vault = true
					_start_drop(action, now)
				else:
					_vault_action = action
					_vault_press_t = now
				return
			if _can_start():
				_start_from_idle(action, now)
		Phase.ACTIVE, Phase.RECOVERY:
			_buffer_action = action
			_buffer_time = now

## A strike starting from idle: an air strike at a lifted body (Round 8), a
## dropping strike in the air, else the move.
func _start_from_idle(action: int, press_t: float) -> void:
	var air := _air_strike_target(action)
	if air != null:
		_start_air(action, press_t, air)
	elif _drop_ok():
		_start_drop(action, press_t)
	else:
		_start_strike(action, press_t)

## Enemy attack entry point. `move_id` is an enemy move (MoveLibrary.ENEMY_MOVES).
## Startup: AttackDirector.enemy_startup_frames(move_id) (frames of the enemy's
## own time), or `tell_time` when that is longer (AttackDirector spaces the
## token holders' active frames). The tell (pose + glow, GameEvents.attack_tell)
## covers the whole startup; the counter window opens R7_COUNTER_WINDOW before
## its first active frame. Returns false if the fighter cannot attack now.
func start_enemy_attack(move_id: StringName, tell_time: float) -> bool:
	var m := MoveLibrary.get_move(move_id)
	if m == null:
		push_warning("CombatController: unknown move %s" % move_id)
		return false
	if not _can_start():
		return false
	var frames: float = Tuning.ENEMY_STARTUP.get(move_id, m.startup)
	if AttackDirector.has_method(&"enemy_startup_frames"):
		frames = float(AttackDirector.call(&"enemy_startup_frames", move_id))
	var startup := maxf(maxf(tell_time, Tuning.frames(frames)), Tuning.frames(Tuning.ENEMY_STARTUP_MIN))
	_press_action = -1
	_hold_pending = false
	_cur_string = -1
	_target = Targeting.pick_strike_target(fighter, fighter.get_forward(), false)
	if _target == null:
		_target = _enemy_reach_target(m, startup)
	# A token holder's one free swing at a knocked-down player (Feel Reference:
	# Running into enemies): it locks onto the body so the swing can land.
	var lock: Fighter = null
	if _target == null and m.kind == &"strike" and AttackDirector.has_method(&"is_player_knocked_down") \
			and bool(AttackDirector.call(&"is_player_knocked_down")):
		var pl := _player_of_ai()
		if pl != null and pl.team != fighter.team:
			var to := pl.get_center_of_mass() - fighter.global_position
			to.y = 0.0
			if to.length() <= m.reach * fighter.get_height_scale() + LOCKED_TARGET_REACH + 1.0:
				_target = pl
				lock = pl
	GameEvents.attack_tell.emit(fighter, m.tell_kind, startup)
	_setup_move(m)
	_locked_target = lock
	_seq_id = m.id
	attack_started.emit(m.id)
	_enter_startup(startup)
	_update_window()
	return true

## The player as the AI sees it (AttackDirector), else the "player" group.
func _player_of_ai() -> Fighter:
	if AttackDirector.has_method(&"get_player"):
		return AttackDirector.call(&"get_player") as Fighter
	return Targeting.player(fighter.get_tree())

## A ranged enemy move (the heavy's shoulder charge from 5 m) still has a
## target: the player in front within the move's reach plus its lunge, so its
## counter window and Defence see it coming.
func _enemy_reach_target(m: MoveData, startup: float) -> Fighter:
	var pl := _player_of_ai()
	if pl == null or not is_instance_valid(pl) or pl.team == fighter.team or pl.is_dead() or pl.is_down():
		return null
	var hs := fighter.get_height_scale()
	var lunge := m.lunge_speed * hs * (startup * (1.0 - m.lunge_start) + m.active_s())
	var to := pl.get_ground_position() - fighter.get_ground_position()
	to.y = 0.0
	var d := to.length()
	if d > m.reach * hs + lunge + ENEMY_REACH_MARGIN:
		return null
	if d > 0.05 and fighter.get_forward().dot(to / d) < ENEMY_REACH_FRONT_DOT:
		return null
	return pl

# =============================================================================
# Queries
# =============================================================================

## The new Carry (G) owns grabs once it is enabled.
func _new_carry() -> bool:
	return fighter != null and fighter.carry != null and fighter.carry.is_enabled()

## The fighter the current attack is aimed at (null when none). Defence and
## the camera read it.
func get_attack_target() -> Fighter:
	if not is_attacking():
		return null
	if _alive(_target):
		return _target
	if is_instance_valid(_locked_target):
		return _locked_target
	return null

## A strike never doubles as a run into its target: from the press to the end
## of its active frames Traversal skips body collisions with anyone.
func suppresses_ram_with(_other: Fighter) -> bool:
	return _phase == Phase.GLIDE or _phase == Phase.STARTUP or _phase == Phase.ACTIVE

func is_attacking() -> bool:
	return _phase != Phase.IDLE

func is_attack_active() -> bool:
	return _phase == Phase.ACTIVE

func is_in_recovery() -> bool:
	return _phase == Phase.RECOVERY

## Round 8: a strike is charging (held past R8_TAP_MAX, not yet released).
func is_charging() -> bool:
	return _phase == Phase.CHARGE and _charge_id != &""

## The player's own glide, startup or recovery (or nothing) is running: a
## dodge (M) or a counter (H) may cancel() it. Never during active frames.
func can_cancel() -> bool:
	return _phase != Phase.ACTIVE

## Current move id, or &"" when idle.
func current_move_id() -> StringName:
	if _phase == Phase.IDLE or _move == null:
		return &""
	return _move.id

## Real seconds until the current attack's first active frame (INF if none).
## A glide counts its estimated remaining time.
func time_to_active() -> float:
	var own := TimeDirector.player_time_factor() if fighter.is_player else 1.0
	var scale := maxf(Engine.time_scale * own, 0.05)
	var frozen := maxf(_freeze_until - TimeDirector.now(), 0.0)
	match _phase:
		Phase.GLIDE:
			return (_glide_left() + _startup) / scale + frozen
		Phase.STARTUP:
			return maxf(_startup - _t, 0.0) / scale + frozen
		Phase.ACTIVE:
			return 0.0
	return INF  # idle, recovery, a held press or a charge (no strike decided yet)

## Debug overlay (F3): the current move, phase (&"idle", &"startup" (a glide
## and a held press waiting for its glide included: see "gliding"), &"charge",
## &"active", &"recovery"), string position, chain, the buffered press (its
## Action name, "" when none), glide, the charge (c, charged strike in
## progress), the air combo and the target's reaction state and pressure.
func get_strike_debug() -> Dictionary:
	var tgt := get_attack_target()
	var phase: StringName = &"idle"
	match _phase:
		Phase.GLIDE, Phase.STARTUP, Phase.HOLD:
			phase = &"startup"
		Phase.CHARGE:
			phase = &"charge"
		Phase.ACTIVE:
			phase = &"active"
		Phase.RECOVERY:
			phase = &"recovery"
	return {"move": current_move_id(), "phase": phase, "string_index": get_string_index(),
		"chain": get_chain_count(), "chain_alive": _chain_alive(TimeDirector.now()),
		"buffered": String(Action.keys()[_buffer_action]).to_lower() if _buffer_action >= 0 else "",
		"hold_pending": _hold_pending, "gliding": is_gliding(), "sprint": _p_sprint, "speed": _p_speed,
		"pursuit": _pursuit_victim() != null,
		"charge": get_charge(), "charged": _move != null and _move.charged and _phase != Phase.IDLE,
		"strike_c": _strike_c, "air": _move != null and _move.air and _phase != Phase.IDLE, "air_hits": _air_hits,
		"target": tgt, "target_state": tgt.get_react_state() if tgt != null else &"",
		"target_pressure": tgt.combat.get_pressure_fraction() if tgt != null and tgt.combat != null else 0.0}

## The Duelist's teleport counter is briefly untouchable (Fighter.is_invulnerable
## adds the player's dodge and counter).
func is_invulnerable() -> bool:
	return TimeDirector.now() < _teleport_invuln_until

## Vanished mid-teleport (Defence): hits miss, the body is hidden.
func is_vanished() -> bool:
	var d: Defence = fighter.defence if fighter != null else null
	return d != null and d.has_method(&"is_vanished") and bool(d.call(&"is_vanished"))

## Kept for callers of the Upgrade 2 vanish.
func force_reappear() -> void:
	pass

## Held by someone (Carry, agent G).
func _held() -> bool:
	return fighter != null and fighter.carry != null and fighter.carry.is_held()

## Holding a body (Carry): no guard, no attacks of ours.
func _holding_body() -> bool:
	return fighter != null and fighter.carry != null and fighter.carry.is_holding_body()

## Any stun (hit or block). Fighter.is_in_hitstun() uses this.
func is_stunned() -> bool:
	return _stun_left > 0.0

## Flinch / stagger / grab-break stun, stumble and daze (not blockstun).
func is_hit_stunned() -> bool:
	return _stun_left > 0.0 and _stun_kind in [Stun.HIT, Stun.STUMBLE, Stun.DAZE]

## The AI's guard (Block held), not while acting, reacting, off balance or
## broken open (Round 8 pressure).
func is_blocking() -> bool:
	if fighter == null or fighter.is_dead() or _held() or _holding_body() or is_broken():
		return false
	if _phase != Phase.IDLE or fighter.is_down() or fighter.is_reacting():
		return false
	if is_hit_stunned():
		return false
	if _stun_left > 0.0 and _stun_kind == Stun.BLOCK and _guard_stun:
		return true
	return _block_held

func is_dashing() -> bool:
	return _dash_left > 0.0

# --- Movement hooks for Fighter / Traversal --------------------------------------
func get_move_speed_mult() -> float:
	if _held():
		return 0.0
	if is_charging() and _stun_left <= 0.0:
		return Tuning.R8_CHARGE_WALK_MULT  # Round 8: walking while charging
	if _phase != Phase.IDLE or _stun_left > 0.0:
		return 0.0
	if is_blocking():
		return BLOCK_WALK_MULT
	return 1.0

func has_forced_velocity() -> bool:
	return _forced_velocity_or_inf() != Vector3.INF

## Horizontal velocity that overrides walking this tick, or Vector3.INF for none.
func get_forced_velocity() -> Vector3:
	return _forced_velocity_or_inf()

func _forced_velocity_or_inf() -> Vector3:
	if _slide_left > 0.0:
		return _slide_velocity
	if _slide_plant and _stun_left > 0.0 and _stun_kind == Stun.BLOCK:
		return Vector3.ZERO  # the guard slid exactly GUARD_PUSH; no drift after it
	if _dash_left > 0.0:
		return _dash_velocity
	if _move == null:
		return Vector3.INF
	if _move.r7 and not _move.drop and not _move.air:  # dropping and air strikes keep Traversal's air motion
		match _phase:
			Phase.GLIDE:
				return _glide_velocity
			Phase.HOLD:
				return Vector3.ZERO  # a held press waits for its glide with the feet planted
			Phase.STARTUP, Phase.ACTIVE, Phase.RECOVERY:
				# The lunge, the follow step, else the feet stay planted (no slide).
				return _lunge_velocity if _has_lunge else Vector3.ZERO
	if _move.r7:
		return Vector3.INF
	# Enemy moves keep their own telegraphed step.
	if _move.enemy and _move.lunge_speed > 0.0:
		var e_lunging := (_phase == Phase.STARTUP and _t >= _startup * _move.lunge_start) \
			or (_phase == Phase.ACTIVE and _move.lunge_through_active and not _hit_any)
		if e_lunging:
			return fighter.get_forward() * _move.lunge_speed * fighter.get_height_scale()
	return Vector3.INF

func can_turn() -> bool:
	if _held():
		return false
	if _phase == Phase.ACTIVE or _phase == Phase.RECOVERY:
		return false
	return not is_hit_stunned()

func get_turn_mult() -> float:
	if _phase == Phase.STARTUP:
		return 0.6
	return 1.0

# =============================================================================
# Per-tick update (called by Fighter._physics_process before it moves)
# =============================================================================

func physics_tick(delta: float) -> void:
	if fighter == null or fighter.is_dead():
		return
	var now := TimeDirector.now()
	# The player's combat timers run in player time (full speed in any slow motion).
	if fighter.is_player:
		delta = TimeDirector.player_delta(delta)
	_tick_victim(now)
	_tick_chain(now)
	_tick_air_combo()
	if is_charging():
		_check_charge_interrupts()
	if now < _freeze_until or fighter.is_frozen():
		return
	_tick_pressure(delta)
	if _slide_left > 0.0:
		_slide_left -= delta
	if _stun_left > 0.0:
		_stun_left -= delta
		if _stun_left <= 0.0:
			_stun_left = 0.0
			_on_stun_end()
	if _dash_left > 0.0:
		_dash_left -= delta
		if _dash_left <= 0.0:
			_dash_left = 0.0
	if _vault_action >= 0:
		_tick_vault_press(now)
	if _phase != Phase.IDLE:
		_advance(delta)
	_update_motion(delta)
	_update_window()
	_update_block_state()

func freeze_until(real_time: float) -> void:
	if real_time > _freeze_until:
		_freeze_until = real_time

# =============================================================================
# Starting moves
# =============================================================================

## Free to start a move: idle, able to act (Round 9: a broken fighter acts;
## with Tuning.R9_BROKEN_STUN it cannot, as in Round 8).
func _can_start() -> bool:
	return _phase == Phase.IDLE and fighter.can_act() and not (Tuning.R9_BROKEN_STUN and is_broken())

## A held strike press charges (Round 8) for the player's buttons (through
## PlayerController or press()/release() directly) and for tests and the lab
## (force_hold_charge). Other scripted presses (enemy bots) are taps.
func _hold_enabled() -> bool:
	return force_hold_charge or fighter.is_player

## The move a strike button means now: the punch string's next punch (legacy
## Heavy too: it fires charged), else the button's own move. &"" for non-strikes.
func _move_for(action: int) -> StringName:
	match action:
		Action.LIGHT, Action.HEAVY:
			return graph.punch_at(_string_index_now())
		Action.LEG_KICK, Action.SWEEP:
			return &"leg_kick"
		Action.GUT_PUNCH:
			return &"gut_punch"
		Action.UPPERCUT:
			return &"uppercut"
		Action.FRONT_KICK, Action.KICK:
			return &"front_kick"
		Action.ROUNDHOUSE:
			return &"roundhouse"
	return &""

## The punch string position a punch started now plays (Round 9): it holds
## until Tuning.R9_STRING_RESET passes with no punch press (from the press, or
## the end of that punch when later), then the jab.
func _string_index_now() -> int:
	if _cur_string < 0 and TimeDirector.now() - _string_last > Tuning.R9_STRING_RESET:
		return 0
	return _string_next

## A string punch starts at position `idx`: the string moves on, its clock restarts.
func _begin_string_punch(idx: int) -> void:
	_cur_string = idx
	_string_next = graph.next_index(idx)
	_string_last = TimeDirector.now()

## The leg kick on a lifted target is the axe kick (Round 9).
static func _axe_for(id: StringName, tgt: Fighter) -> StringName:
	if id == &"leg_kick" and _alive(tgt) and tgt.is_lifted():
		return MoveLibrary.AXE
	return id

## A strike press that can start now: the move (the punch string), the
## freeflow target, then the tap (glide or startup) with the charge decision
## pending while the button is held (Round 8). A buffered press already held
## past R8_TAP_MAX charges at once (c counts from its press); legacy Heavy
## fires the string punch charged to full.
func _start_strike(action: int, press_t: float) -> void:
	var now := TimeDirector.now()
	_tick_chain(now)  # a chain past its grace drops first
	var punch := action == Action.LIGHT or action == Action.HEAVY
	var idx := _string_index_now()
	var tgt := _pick_freeflow_target()
	var id := _axe_for(_move_for(action), tgt)  # Round 9: the leg kick on a lifted target
	var m := MoveLibrary.get_move(id)
	if m == null:
		return
	var hold := m.r8 and action != Action.HEAVY and _hold_enabled() and bool(_btn_down.get(action, false))
	_press_action = action
	_press_t = press_t
	_hold_pending = hold
	if punch:
		_begin_string_punch(idx)
	else:
		_cur_string = -1
	if action == Action.HEAVY and m.r8:
		_hold_pending = false
		_fire_charged(id, 1.0, tgt, true)
		return
	if hold and now - press_t >= Tuning.R8_TAP_MAX:
		# Held past the tap before it could start (a buffered press): it charges now.
		_setup_move(m)
		_target = tgt
		_seq_id = m.id
		attack_started.emit(m.id)
		if tgt != null:
			fighter.snap_facing(tgt.get_ground_position() - fighter.global_position)
		_begin_charge()
		return
	_launch_move(m, tgt)

## Any strike in the air (a jump, a fall, a kick-off) or late in a vault is a
## dropping strike at the freeflow target (no glide, no lunge): active until
## the fighter lands. Traversal is told (begin_drop_strike) unless the vault
## already began it.
func _start_drop(action: int, press_t: float) -> void:
	var m := MoveLibrary.get_move(&"drop_strike")
	if m == null:
		return
	_tick_chain(TimeDirector.now())
	_press_action = action
	_press_t = press_t
	_hold_pending = false
	_cur_string = -1
	_drop_as = _move_for(action)  # it hits with the button's move entry (doc: God path)
	if not _drop_from_vault:
		_traversal_call(&"begin_drop_strike")
	_launch_move(m, _pick_freeflow_target())

func _vaulting() -> bool:
	return _traversal_bool(&"is_vaulting")

func _vault_progress() -> float:
	var t := fighter.traversal
	return float(t.call(&"get_vault_progress")) if t != null and t.has_method(&"get_vault_progress") else 0.0

## In the air (a jump, a fall, a kick-off), not wall running, not in a vault
## and not hanging for a pursuit: a strike here is a dropping strike.
func _drop_ok() -> bool:
	if not fighter.is_player or _pursuit_victim() != null:
		return false
	if _traversal_bool(&"is_wall_running") or _vaulting():
		return false
	return _fighter_bool(&"is_airborne") or _traversal_bool(&"is_airborne")

## Still falling in a dropping strike: Traversal's drop (timed on the real
## landing), else the jump / air state.
func _drop_falling() -> bool:
	return _traversal_bool(&"is_drop_striking") or _traversal_bool(&"is_airborne") or _vaulting() \
		or _fighter_bool(&"is_airborne")

## A strike pressed in the first 60% of a vault fires as a normal strike once
## the fighter is back on the ground (dropped after VAULT_PRESS_KEEP).
func _tick_vault_press(now: float) -> void:
	if now - _vault_press_t > VAULT_PRESS_KEEP:
		_vault_action = -1
		return
	if _vaulting() or _traversal_bool(&"is_airborne") or _fighter_bool(&"is_airborne"):
		return
	var a := _vault_action
	_vault_action = -1
	if _can_start():
		_start_strike(a, now)

## Sprinting right now (sprint, wall run, sprint charge).
func _sprinting_now() -> bool:
	return _traversal_bool(&"is_sprinting") or _traversal_bool(&"is_wall_running") \
		or _traversal_bool(&"is_charge_steering")

## Traversal / Fighter queries that other modules may rename or drop: false when absent.
func _traversal_bool(method: StringName) -> bool:
	var t := fighter.traversal
	return t != null and t.has_method(method) and bool(t.call(method))

func _traversal_call(method: StringName) -> bool:
	return _traversal_bool(method)

func _fighter_bool(method: StringName) -> bool:
	return fighter.has_method(method) and bool(fighter.call(method))

## The flying body a pursuit is chasing (Defence), or null.
func _pursuit_victim() -> Fighter:
	var d: Defence = fighter.defence if fighter != null else null
	if d == null or not d.has_method(&"get_pursuit_target"):
		return null
	var v: Variant = d.call(&"get_pursuit_target")
	return v as Fighter if _alive(v) else null

func _is_pursuit_target(f: Variant) -> bool:
	return _alive(f) and f == _pursuit_victim()

## Scripted move (tests, the lab, bots): start the Round 7 move `id` now, at
## `target` (null: the freeflow pick), exactly as its button would (glide,
## lunge, auto-connect; a string punch moves the string on). A Round 8 strike
## id is its tap; the Round 7 heavy ids keep their Round 7 entries. False when
## the fighter is not free to start it.
func play_move(id: StringName, target: Fighter = null) -> bool:
	var m := MoveLibrary.get_move(id)
	if m == null or not m.r7 or not _can_start() or _held() or _holding_body():
		return false
	_tick_chain(TimeDirector.now())
	_press_action = -1
	_press_t = TimeDirector.now()
	_hold_pending = false
	_cur_string = graph.index_of(id)
	if _cur_string >= 0:
		_begin_string_punch(_cur_string)
	var tgt: Fighter = target if _alive(target) else _pick_freeflow_target()
	_launch_move(m, tgt, Tuning.R7_COUNTER_GLIDE if id == &"counter" else INF)
	return true

## Scripted charged strike (tests, the lab, bots): fire the Round 8 strike
## `id` charged to `c` now, at `target` (null: the release's pick), exactly as a
## release at c would (the lunge glide, the release startup). No charge
## events. False when the fighter is not free or `id` has no charged version.
func play_charged(id: StringName, c: float, target: Fighter = null) -> bool:
	var m := MoveLibrary.get_move(id)
	if m == null or not m.r8 or not _can_start() or _held() or _holding_body():
		return false
	_tick_chain(TimeDirector.now())
	_press_action = -1
	_press_t = TimeDirector.now()
	_hold_pending = false
	_cur_string = graph.index_of(id)
	if _cur_string >= 0:
		_begin_string_punch(_cur_string)
	_fire_charged(id, clampf(c, 0.0, 1.0), target if _alive(target) else null, true)
	return true

## Start a Round 7 move at `tgt` (null: along the stick, else facing). A target
## farther than reach + R7_GLIDE_FROM (and within `max_glide` m) is glided to
## first, at most `glide_limit` m (a charged release's lunge); closer ones get
## the short lunge in the startup. A held press (Round 8) whose target needs a
## glide waits in Phase.HOLD: the glide starts if it turns out a tap.
## `announce`: attack_started (false: a charge's release, the same sequence).
func _launch_move(m: MoveData, tgt: Fighter, max_glide := INF, glide_limit := INF, announce := true) -> void:
	_setup_move(m)
	_target = tgt
	_seq_id = m.id
	_glide_limit = glide_limit
	# Sprint strike: the speed toward the target, sampled before Traversal drops
	# a sprinting player to walk; the strike carries the run.
	_sample_speed()
	var t := fighter.traversal
	if t != null and t.has_method(&"on_strike_started"):
		t.on_strike_started(_p_sprint)
	if _p_sprint and tgt != null and not m.drop and not m.air:
		_sprint_excepted = tgt
		fighter.add_collision_exception_with(tgt)
		tgt.add_collision_exception_with(fighter)
	if announce:
		attack_started.emit(m.id)
	_pursuit_spike = false
	if _is_pursuit_target(tgt):
		_locked_target = tgt  # the pursuit body: struck wherever it flies
		_pursuit_spike = _intent_back()  # the stick pulled back at the press: a spike
	if tgt != null:
		fighter.snap_facing(tgt.get_ground_position() - fighter.global_position)
		var d := _flat_dist(tgt)
		if not m.drop and not m.air and _locked_target == null \
				and d > m.reach * fighter.get_height_scale() + Tuning.R7_GLIDE_FROM and d <= max_glide:
			if _hold_pending:
				_enter_hold()
			else:
				_start_glide(tgt, d)
			return
	else:
		var stick := _stick_dir()
		if stick.length() > 0.2:
			fighter.snap_facing(stick)
	_enter_startup()

## Fresh per-move state.
func _setup_move(m: MoveData) -> void:
	_move = m
	_t = 0.0
	_startup = m.startup_s()
	_active = m.active_s()
	_recovery = m.recovery_s(false)
	_registry.clear()
	_prev_limbs.clear()
	_hit_any = false
	_landed = false
	_blocked = false
	_first_active = false
	_waited = false
	_debris_kicked = false
	_wall_struck = false
	_committed = false
	_locked_target = null
	_glide_t = 0.0
	_glide_velocity = Vector3.ZERO
	_glide_limit = INF
	_glide_dist = 0.0
	_air_spike = false
	if not m.charged:
		_strike_c = 0.0
	_lunge_left = Tuning.LUNGE_MAX
	_lunge_velocity = Vector3.ZERO
	_has_lunge = false
	_follow_left = 0.0
	_follow_victim = null
	_buffer_action = -1
	_dash_left = 0.0
	_drop_t = 0.0
	if not m.drop:
		_drop_as = &""
	_p_speed = 0.0
	_p_sprint = false
	_end_sprint_exception()
	_close_window()
	blocking = false

## Sprint strike sample: the speed toward the target (else facing), the cap,
## and whether this is a sprint (sprint, wall run, sprint charge, vault drop).
func _sample_speed() -> void:
	var t := fighter.traversal
	_p_cap = Power.speed_cap()
	if t == null or _move == null or _move.enemy:
		return
	var dir := fighter.get_forward()
	if _alive(_target):
		var to := _target.get_ground_position() - fighter.get_ground_position()
		to.y = 0.0
		if to.length_squared() > 1e-4:
			dir = to.normalized()
	if t.has_method(&"speed_toward"):
		_p_speed = maxf(float(t.call(&"speed_toward", dir)), 0.0)
	if t.has_method(&"get_speed_cap"):
		_p_cap = float(t.call(&"get_speed_cap"))
	_p_sprint = _sprinting_now() or _drop_from_vault
	# Wall-run strikes and vault drops count as the speed cap (doc: God path).
	if _drop_from_vault or _traversal_bool(&"is_wall_running"):
		_p_speed = maxf(_p_speed, _p_cap)

func _end_sprint_exception() -> void:
	var t: Variant = _sprint_excepted
	_sprint_excepted = null
	if not is_instance_valid(t) or fighter == null:
		return
	fighter.remove_collision_exception_with(t)
	(t as Fighter).remove_collision_exception_with(fighter)

func _start_glide(tgt: Fighter, d: float) -> void:
	_phase = Phase.GLIDE
	_glide_t = 0.0
	_glide_dist = 0.0
	GameEvents.glide_started.emit(fighter, tgt, d)
	if _move.charged and fighter.animator != null and fighter.animator.is_charge_load_held():
		return  # a charged release glides in its held load (the strike then skips its wind-up)
	if fighter.animator and _move.id == &"counter" and PoseLibrary.HOLDS.has(&"counter_catch"):
		fighter.animator.hold_pose(&"counter_catch")  # the lead hand catches through the glide
	elif fighter.animator:
		for a: StringName in GLIDE_ANIMS:
			if PoseLibrary.has_move(a):
				fighter.animator.play_timed(a, maxf(_glide_left(), Tuning.frames(4)))
				break

## The startup begins (after any glide). `startup` < 0 uses the move's frames.
func _enter_startup(startup := -1.0) -> void:
	_phase = Phase.STARTUP
	_t = 0.0
	_glide_velocity = Vector3.ZERO
	if startup >= 0.0:
		_startup = startup
	if fighter.animator:
		fighter.animator.play_move(_move.anim, _startup, _active, _move.recovery_s(false))
	attack_incoming.emit(_move.id, time_to_active())
	if not _hold_pending:
		_commit()
	_update_aim()

## The move is decided (a tap released, a charge released, a special): tell
## Traversal's fallback, the AI (guards) and the whoosh (GameEvents.strike_started;
## charge_level: 0 a tap, 1 + the steps passed for a charged strike, 1 a Round 7 heavy).
func _commit() -> void:
	if _committed or _move == null:
		return
	_committed = true
	if _move.kind == &"strike":
		var level := 1 if graph.is_heavy(_move.id) else 0
		if _move.charged:
			level = 1 + _steps_passed(_steps_for(_move.id), _strike_c)
		GameEvents.strike_started.emit(fighter, get_attack_target(), _move.id, _p_sprint, level)

## The button came up before R8_TAP_MAX: a tap. A tap waiting for its glide
## (Phase.HOLD) glides now (or starts, its target having come close); one that
## waited at the end of its startup goes active now (its pose snaps to the hit).
func _release_hold() -> void:
	_hold_pending = false
	if _phase == Phase.HOLD:
		_tap_from_hold()
	elif _phase == Phase.STARTUP:
		if _t >= _startup:
			_t = _startup
		if _waited and fighter.animator:
			fighter.animator.play_move(_move.anim, Tuning.frames(1), _active, _move.recovery_s(false))
		_waited = false
	_commit()

## A held press whose target needs a glide: stand in the charge pose until the
## tap/charge decision (the release, or R8_TAP_MAX).
func _enter_hold() -> void:
	_phase = Phase.HOLD
	_t = 0.0
	_update_aim()
	_hold_charge_pose()

## The held press turned out a tap: the glide (re-measured), else the startup.
func _tap_from_hold() -> void:
	if fighter.animator:
		fighter.animator.release_pose(0.05)
	var tgt: Fighter = _target if _alive(_target) and not _target.is_down() else null
	if tgt != null:
		var d := _flat_dist(tgt)
		fighter.snap_facing(tgt.get_ground_position() - fighter.global_position)
		if d > _move.reach * fighter.get_height_scale() + Tuning.R7_GLIDE_FROM:
			_start_glide(tgt, d)
			return
	_enter_startup()

# --- Round 8: the charge ---------------------------------------------------------
## Still held at R8_TAP_MAX: the strike charges (Phase.CHARGE). The tap is
## dropped; c counts from the press. The target picked at the press is kept.
func _begin_charge() -> void:
	var id := _move.id
	_phase = Phase.CHARGE
	_hold_pending = false
	_waited = false
	_t = 0.0
	_has_lunge = false
	_glide_velocity = Vector3.ZERO
	_lunge_velocity = Vector3.ZERO
	_charge_id = id
	_charge_action = _press_action
	_charge_t0 = _press_t
	_charge_c = 0.0
	_charge_full = false
	_charge_level = 0
	_charge_steps = _steps_for(id)
	_charge_target = _target if _alive(_target) else null
	_hold_charge_pose()
	GameEvents.charge_started.emit(fighter, id)
	_tick_charge(TimeDirector.now())

## The pose held while charging: P's charge load (MoveData.charge_hold:
## PoseLibrary.charge_load_of), else a fallback hold. PoseAnimator's
## set_charge_amount(c) deepens it every charge tick.
func _hold_charge_pose() -> void:
	if fighter.animator == null or _move == null or fighter.animator.is_charge_load_held():
		return
	var load := _move.charge_hold
	if load == &"" or not PoseLibrary.HOLDS.has(load):
		load = &""
		for h: StringName in CHARGE_HOLD_FALLBACK:
			if PoseLibrary.HOLDS.has(h):
				load = h
				break
	if load != &"":
		fighter.animator.hold_pose(load)

## c of a charge pressed at real time `t0`, now: 0 at R8_TAP_MAX, 1 at
## Tuning.debug_charge_full s after the press.
static func charge_at(t0: float, now: float) -> float:
	var span := maxf(Tuning.debug_charge_full - Tuning.R8_TAP_MAX, 1e-3)
	return clampf((now - t0 - Tuning.R8_TAP_MAX) / span, 0.0, 1.0)

## The charge meter's colour steps of strike `id` (ascending, each in (0, 1],
## always at least two; lead's rule, 2026-11-03): the c values where its
## charged result changes (its launch step: launch_from capped by
## Tuning.debug_launch_step; 1.0 for full_react and full_break; for a lifting
## move the c whose lift reaches R8_AIR_FOLLOW_MIN_LIFT, where the air combo
## opens; a step at 0 is not shown), then 1.0 appended if the last is below it,
## 0.5 inserted before a lone 1.0, and [0.5, 1.0] for a move with none (pure
## scaling: jab, roundhouse). The HUD goes orange at the first, red at the last.
static func _steps_for(id: StringName) -> Array[float]:
	var out: Array[float] = []
	var row: Dictionary = MoveLibrary.r8_row(id)
	if row.is_empty():
		return out
	var ch: Dictionary = row["charged"]
	var cand: Array[float] = []
	if ch.has("launch_from"):
		cand.append(minf(float(ch["launch_from"]), Tuning.debug_launch_step))
	if ch.has("full_react") or bool(ch.get("full_break", false)):
		cand.append(1.0)
	if ch.has("lift"):
		var lift: Vector2 = ch["lift"]
		if lift.y > lift.x:
			cand.append(clampf((Tuning.R8_AIR_FOLLOW_MIN_LIFT - lift.x) / (lift.y - lift.x), 0.0, 1.0))
	cand.sort()
	for c: float in cand:
		if c > 1e-4 and (out.is_empty() or c - out[-1] > 1e-4):
			out.append(c)
	if out.is_empty() or out[-1] < 1.0 - 1e-4:
		out.append(1.0)
	if out.size() == 1:
		out.insert(0, 0.5)
	return out

static func _steps_passed(steps: Array[float], c: float) -> int:
	var n := 0
	for st: float in steps:
		if c >= st - 1e-4:
			n += 1
	return n

## One charge tick (real time): c, the animator, the steps, full, the facing
## toward the charge's target, and the fire-itself at full + R8_CHARGE_HOLD_AT_FULL.
func _tick_charge(now: float) -> void:
	if not is_charging():
		return
	var c := charge_at(_charge_t0, now)
	_charge_c = c
	if fighter.animator != null:
		fighter.animator.set_charge_amount(c)
	var level := _steps_passed(_charge_steps, c)
	if level > _charge_level:
		_charge_level = level
		GameEvents.charge_level_changed.emit(fighter, level)
	if c >= 1.0 and not _charge_full:
		_charge_full = true
		GameEvents.charge_full.emit(fighter, _charge_id)
	if not _alive(_charge_target) or _charge_target.is_down():
		_charge_target = null
	_target = _charge_target
	if _charge_target != null:
		var to := _charge_target.get_ground_position() - fighter.global_position
		to.y = 0.0
		if to.length_squared() > 1e-4:
			fighter.face_dir = to.normalized()
		_update_aim()
	if now - _charge_t0 >= Tuning.debug_charge_full + Tuning.R8_CHARGE_HOLD_AT_FULL - PHASE_EPS:
		_release_charge()

## A charge ends without a strike: grabbed, knocked down, holding something.
func _check_charge_interrupts() -> void:
	if _held():
		_cancel_charge(&"grabbed")
	elif fighter.is_down():
		_cancel_charge(&"down")
	elif fighter.carry != null and (fighter.carry.is_holding() or fighter.carry.is_busy()):
		_cancel_charge(&"cancel")

## The charge ends without a strike (charge_cancelled; reason &"hit" | &"cancel" |
## &"grabbed" | &"down"), then the move is cancelled.
func _cancel_charge(reason: StringName) -> void:
	if not is_charging():
		return
	var id := _charge_id
	_end_charge()
	if fighter.animator != null:
		fighter.animator.set_charge_amount(0.0)
	GameEvents.charge_cancelled.emit(fighter, id, reason)
	cancel()

func _end_charge() -> void:
	_charge_id = &""
	_charge_action = -1
	_charge_target = null
	_charge_steps = []

## The release (or the fire-itself at full): charge_released, then the charged
## strike at the c reached. The load stays held through the glide: the strike
## plays from it and skips its own wind-up (PoseAnimator).
func _release_charge() -> void:
	if not is_charging():
		return
	var now := TimeDirector.now()
	var id := _charge_id
	var c := charge_at(_charge_t0, now)
	var level := _steps_passed(_charge_steps, c)
	var tgt := _charge_target
	_end_charge()
	GameEvents.charge_released.emit(fighter, id, level)
	_fire_charged(id, c, tgt, false)

## The charged strike of `id` at charge `c`: the target re-picked along a
## pushed stick (else `keep`, else the pick along camera forward), within the
## lunge's reach; a glide of at most R8_CHARGE_LUNGE (lerped by c), then
## R8_RELEASE_STARTUP frames. `announce`: a new sequence (attack_started).
func _fire_charged(id: StringName, c: float, keep: Fighter, announce: bool) -> void:
	var m := MoveLibrary.charged_move(id)
	if m == null:
		cancel()
		return
	var lunge := lerpf(Tuning.R8_CHARGE_LUNGE.x, Tuning.R8_CHARGE_LUNGE.y, c)
	var reach := maxf(Tuning.R7_TARGET_RANGE, lunge + m.reach * fighter.get_height_scale())
	var tgt := _pursuit_victim()
	if tgt == null:
		var current: Fighter = keep if _alive(keep) else get_combat_target()
		tgt = Targeting.pick_freeflow_target(fighter, _stick_dir(), current, _camera_forward(), reach)
	_strike_c = c
	_launch_move(m, tgt, INF, lunge, announce)

# --- Freeflow targeting --------------------------------------------------------
## The target of a press: Targeting.pick_freeflow_target along the stick, else
## the combat target, else camera forward.
## A pursuit body (Defence) comes first.
func _pick_freeflow_target() -> Fighter:
	var pt := _pursuit_victim()
	if pt != null:
		return pt
	return Targeting.pick_freeflow_target(fighter, _stick_dir(), get_combat_target(), _camera_forward())

## The camera-relative stick (PlayerController.get_aim_dir; zero when neutral).
func _stick_dir() -> Vector3:
	if fighter.brain != null and fighter.brain.has_method(&"get_aim_dir"):
		var d: Vector3 = fighter.brain.call(&"get_aim_dir")
		return Vector3(d.x, 0.0, d.z)
	return Vector3.ZERO

## Flat camera forward: PlayerController.get_camera_forward() (the camera
## rig's), else the viewport camera's, else the fighter's facing.
func _camera_forward() -> Vector3:
	if fighter.brain != null and fighter.brain.has_method(&"get_camera_forward"):
		var cf: Vector3 = fighter.brain.call(&"get_camera_forward")
		cf.y = 0.0
		if cf.length_squared() > 1e-4:
			return cf.normalized()
	var vp: Viewport = fighter.get_viewport() if fighter.is_inside_tree() else null
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam != null:
		var f := -cam.global_basis.z
		f.y = 0.0
		if f.length_squared() > 1e-4:
			return f.normalized()
	return fighter.get_forward()

func _flat_dist(f: Fighter) -> float:
	var to := f.get_ground_position() - fighter.global_position
	to.y = 0.0
	return to.length()

## A live fighter (`f` may hold a freed body, hence Variant).
static func _alive(f: Variant) -> bool:
	return is_instance_valid(f) and f is Fighter and not (f as Fighter).is_dead()

## The HitInfo.Tier named `n` (R7_MOVES "tier").
static func _tier_named(n: StringName) -> int:
	for t: int in HitInfo.TIER_NAMES:
		if HitInfo.TIER_NAMES[t] == n:
			return t
	return HitInfo.Tier.STAGGER

# --- Glide, lunge, follow step ---------------------------------------------------
## Estimated own-time seconds of glide left (0 when not gliding).
func _glide_left() -> float:
	if _phase != Phase.GLIDE or _move == null or not _alive(_target):
		return 0.0
	var gap := _flat_dist(_target) - _move.reach * fighter.get_height_scale() * LUNGE_GAP
	gap = minf(gap, _glide_limit - _glide_dist)
	return clampf(gap / Tuning.R7_GLIDE_SPEED, 0.0, maxf(_glide_max_time() - _glide_t, 0.0))

## s a glide may last: R7_GLIDE_MAX_TIME, or a charged release's lunge at
## R7_GLIDE_SPEED (+ CHARGE_GLIDE_SLACK; it stops on its distance first).
func _glide_max_time() -> float:
	if is_finite(_glide_limit):
		return maxf(Tuning.R7_GLIDE_MAX_TIME, _glide_limit / Tuning.R7_GLIDE_SPEED + CHARGE_GLIDE_SLACK)
	return Tuning.R7_GLIDE_MAX_TIME

## Glide tick: close on the target at R7_GLIDE_SPEED, facing it; the startup
## begins at reach x LUNGE_GAP, after _glide_limit m (a charged release's
## lunge) or after the glide's time limit.
func _tick_glide(delta: float) -> void:
	_glide_t += delta
	_glide_velocity = Vector3.ZERO
	if not _alive(_target) or _target.is_down():
		_enter_startup()
		return
	var to := _target.get_ground_position() - fighter.global_position
	to.y = 0.0
	var d := to.length()
	var gap := d - _move.reach * fighter.get_height_scale() * LUNGE_GAP
	var left := _glide_limit - _glide_dist
	if gap <= 0.01 or left <= 0.005 or _glide_t > _glide_max_time():
		_enter_startup()
		return
	var dir := to / d
	fighter.snap_facing(dir)
	var speed := maxf(Tuning.R7_GLIDE_SPEED, _p_speed) if _p_sprint else Tuning.R7_GLIDE_SPEED
	var step := minf(speed * delta, minf(gap, left))
	_glide_dist += step
	_glide_velocity = dir * step / maxf(delta, 1e-4)

## Per tick: the startup lunge toward the target (up to Tuning.LUNGE_MAX,
## stopping at reach x LUNGE_GAP) and the follow step during recovery. Once
## the gap is closed (or the hit lands) the feet are planted.
func _update_motion(delta: float) -> void:
	_has_lunge = false
	_lunge_velocity = Vector3.ZERO
	if _target != null and not _alive(_target):
		_target = null
		_clear_aim()
	var tgt: Fighter = _target
	if _move == null or not _move.r7:
		if tgt != null and (_phase == Phase.STARTUP or _phase == Phase.ACTIVE):
			_update_aim()
		return
	match _phase:
		Phase.STARTUP, Phase.ACTIVE:
			if tgt != null:
				_update_aim()
				_update_lunge(tgt, delta)
		Phase.RECOVERY:
			_update_follow(delta)

## A sprint strike carries its run speed instead, through the active frames,
## and stops Tuning.SPRINT_LUNGE_STOP short. A dropping strike falls as it is.
func _update_lunge(tgt: Fighter, delta: float) -> void:
	if _move.drop or _move.air:
		return
	_has_lunge = true
	if _phase == Phase.ACTIVE and (_hit_any or not _p_sprint):
		return
	if (tgt.is_down() and not _is_pursuit_target(tgt)) or (_lunge_left <= 0.0 and not _p_sprint):
		return
	var to := tgt.get_ground_position() - fighter.global_position
	to.y = 0.0
	var d := to.length()
	if d < 0.05:
		return
	var dir := to / d
	fighter.face_dir = dir
	var stop := Tuning.SPRINT_LUNGE_STOP if _p_sprint else _move.reach * fighter.get_height_scale() * LUNGE_GAP
	var gap := d - stop
	if gap <= 0.0:
		return
	var speed := 0.0
	if _p_sprint:
		var run := maxf(_p_speed, Tuning.WALK_SPEED)
		var left_s := maxf((_startup - _t) + _active if _phase == Phase.STARTUP else _active - _t, 1.0 / 60.0)
		speed = minf(clampf(gap / left_s, run, run * SPRINT_LUNGE_BOOST), gap / maxf(delta, 1e-4))
	else:
		var left := maxf(_startup - _t, 1.0 / 60.0)
		speed = minf(minf(gap, _lunge_left) / left, LUNGE_SPEED_MAX)
		_lunge_left -= speed * delta
	_lunge_velocity = dir * speed

## Follow step: the attacker steps after a victim it pushed (R7_FOLLOW_SHARE of
## the push over the recovery), never closer than FOLLOW_MIN_GAP.
func _update_follow(delta: float) -> void:
	_has_lunge = true
	if _follow_left <= 0.0:
		return
	if not _alive(_follow_victim):
		_follow_left = 0.0
		return
	var to := _follow_victim.get_ground_position() - fighter.global_position
	to.y = 0.0
	if to.length() <= FOLLOW_MIN_GAP:
		return
	var step := minf(_follow_speed * delta, _follow_left)
	_follow_left -= step
	_lunge_velocity = _follow_dir * step / maxf(delta, 1e-4)

## The animator aims the strike at its target bone: a head strike at the head
## itself (the Head bone + HEAD_AIM_UP), the gut punch at the waist, kicks at
## their bone (P's AIM_YAW_ONLY moves only turn).
func _update_aim() -> void:
	if not _alive(_target) or fighter.animator == null or not fighter.animator.has_method(&"set_aim_target"):
		return
	var bone := _move.target_bone if _move else Bones.CHEST
	var p := _bone_pos(_target, bone)
	if bone == Bones.HEAD and _target.rig != null:
		p += Vector3.UP * HEAD_AIM_UP
	fighter.animator.call(&"set_aim_target", p)
	_aim_set = true

func _clear_aim() -> void:
	if not _aim_set:
		return
	_aim_set = false
	if fighter and fighter.animator and fighter.animator.has_method(&"clear_aim_target"):
		fighter.animator.call(&"clear_aim_target")

## World position of `bone` on `f` (its aim point without a rig).
static func _bone_pos(f: Fighter, bone: StringName) -> Vector3:
	if f.rig != null and f.rig.skeleton != null:
		return f.rig.get_bone_global_position(bone)
	return f.get_aim_point()

# =============================================================================
# Phase machine
# =============================================================================

func _advance(delta: float) -> void:
	if _phase == Phase.CHARGE:
		_tick_charge(TimeDirector.now())
		return
	if _hold_pending and _phase in [Phase.HOLD, Phase.GLIDE, Phase.STARTUP] \
			and TimeDirector.now() - _press_t >= Tuning.R8_TAP_MAX:
		_begin_charge()  # still held at R8_TAP_MAX: it charges
		return
	if _phase == Phase.HOLD:
		return  # a held press waits for the tap/charge decision before its glide
	if _phase == Phase.GLIDE:
		_tick_glide(delta)
		return
	_t += delta
	if _phase == Phase.STARTUP:
		if _t < _startup - PHASE_EPS:
			return
		if _hold_pending:
			if not _waited:
				_hold_charge_pose()  # held past its startup: the charge's load pose while it is decided
			_waited = true
			return  # a held tap waits for the tap/charge decision (its time keeps counting)
		_t -= _startup
		_enter_active()
		if _phase != Phase.ACTIVE:
			return
	if _phase == Phase.ACTIVE:
		if _move.kind == &"grab":
			_detect_grab()
		elif _move.kind == &"strike" or _move.kind == &"counter":
			_detect_hits()
		_first_active = false
		if _phase != Phase.ACTIVE:
			return
		if _move.drop:
			# A dropping strike ends on landing; a high drop stays active until it lands.
			var dropping := _drop_falling()
			_drop_t += delta
			if _t >= Tuning.frames(2.0) and not dropping:
				_t = _active
			elif dropping and _t >= _active and _drop_t < DROP_ACTIVE_LIMIT:
				_t = _active - 1e-3
		if _t < _active - PHASE_EPS:
			return
		_t -= _active
		_enter_recovery()
		if _phase != Phase.RECOVERY:
			return
	if _phase == Phase.RECOVERY:
		if _t >= _recovery - PHASE_EPS:
			_finish()

func _enter_active() -> void:
	_phase = Phase.ACTIVE
	_first_active = true
	_prev_limbs.clear()
	if _move.kind in [&"strike", &"grab", &"counter"]:
		_skip_invulnerable()
		_check_interceptions()
		if _phase != Phase.ACTIVE:
			return  # parried: the parry stagger cancelled this attack
	attack_active.emit(_move.id)
	GameEvents.attack_active.emit(fighter, _move.id)
	if _move.kind == &"projectile":
		_spawn_projectile()
		_hit_any = true

## Recovery: the chain cut on a hit (the move ends after R7_CHAIN_CUT of it);
## a whiff or a blocked hit plays it in full and ends the chain (Round 9: the
## punch string holds). The follow step spreads over it.
func _enter_recovery() -> void:
	_close_window()
	_end_sprint_exception()
	if not _hit_any and _move.kind in [&"strike", &"grab", &"counter"]:
		GameEvents.attack_whiff.emit(fighter, _move.id)
	_phase = Phase.RECOVERY
	_clear_aim()
	if _move.r7:
		_recovery = _move.recovery_s(_landed)
		if not _hit_any and _p_sprint:
			_recovery += Tuning.frames(Tuning.SPRINT_WHIFF_FRAMES)  # a missed sprint strike
		if not _landed and (_blocked or not _hit_any):
			_end_chain()
		_follow_speed = _follow_left / maxf(_recovery, Tuning.frames(2))
	else:
		_recovery = _move.recovery_s(_hit_any)

func _finish() -> void:
	var was_r7 := _move != null and _move.r7
	_phase = Phase.IDLE
	_drop_from_vault = false
	_end_sprint_exception()
	_press_action = -1
	_hold_pending = false
	if _cur_string >= 0:
		_string_last = TimeDirector.now()  # the string's idle clock runs from the end of the punch
	_cur_string = -1
	_locked_target = null
	_target = null
	_has_lunge = false
	_follow_left = 0.0
	_close_window()
	_clear_aim()
	_end_sequence()
	_update_block_state()
	if was_r7 and _chain_count > 0:
		_chain_until = TimeDirector.now() + Tuning.R7_CHAIN_GRACE
	_fire_buffer()

## The press buffered during the active frames or the recovery starts the
## moment the move ends; still held, it is already its heavy version (the hold
## counts from the press).
func _fire_buffer() -> void:
	var a := _buffer_action
	_buffer_action = -1
	if a >= 0 and _can_start() and not _held():
		_start_from_idle(a, _buffer_time)

func _end_sequence() -> void:
	if _seq_id != &"":
		var id := _seq_id
		_seq_id = &""
		attack_ended.emit(id)

## Abort the current move: got hit, launched, died, or a dodge (M) / counter
## (H) cancelling the player's own glide, startup or recovery (call only when
## can_cancel()). The chain survives a cancel (being hit ends it:
## on_reaction); a punch cancelled before its active frames gives its string
## position back.
func cancel() -> void:
	if is_charging():
		_cancel_charge(&"cancel")  # charge_cancelled, then back here
		return
	var was_busy := _phase != Phase.IDLE
	var was_r7 := was_busy and _move != null and _move.r7
	if was_busy and _cur_string >= 0 and _phase in [Phase.GLIDE, Phase.STARTUP, Phase.HOLD, Phase.CHARGE]:
		_string_next = _cur_string
	if _cur_string >= 0:
		_string_last = TimeDirector.now()
	_close_window()
	_phase = Phase.IDLE
	_registry.clear()
	_locked_target = null
	_target = null
	_dash_left = 0.0
	_has_lunge = false
	_glide_velocity = Vector3.ZERO
	_follow_left = 0.0
	_clear_aim()
	_end_sprint_exception()
	_press_action = -1
	_hold_pending = false
	_waited = false
	_buffer_action = -1
	_vault_action = -1
	_drop_from_vault = false
	_cur_string = -1
	if was_r7 and _chain_count > 0:
		_chain_until = maxf(_chain_until, TimeDirector.now() + Tuning.R7_CHAIN_GRACE)
	if was_busy:
		_end_sequence()
		if fighter and fighter.animator:
			fighter.animator.cancel()
	blocking = false

# --- Reactions (called by Fighter.flinch / stagger / stumble / knockdown / launch) ---
func on_reaction(reaction: int, stun: float) -> void:
	cancel()
	_end_chain()
	drop_debris()
	match reaction:
		HitInfo.Reaction.FLINCH, HitInfo.Reaction.STAGGER:
			_stun_left = maxf(_stun_left, stun)
			_stun_kind = Stun.HIT
		HitInfo.Reaction.LAUNCH:
			_stun_left = 0.0
			_stun_kind = Stun.NONE

func on_death() -> void:
	cancel()
	if is_broken():
		_broken_left = 0.0
		GameEvents.pressure_recovered.emit(fighter)  # the daze ends with the fighter
	_end_chain()
	drop_debris()
	_clear_aim()
	_stun_left = 0.0
	_block_held = false
	blocking = false

func _on_stun_end() -> void:
	var was := _stun_kind
	_stun_kind = Stun.NONE
	_slide_plant = false
	if (was == Stun.STUMBLE or was == Stun.DAZE) and fighter.animator \
			and fighter.get_state() == RagdollController.State.ANIMATED and not is_blocking():
		fighter.animator.release_pose()
	if fighter.animator and fighter.get_state() == RagdollController.State.ANIMATED:
		if is_blocking():
			fighter.animator.hold_pose(&"block")
			blocking = true

func _update_block_state() -> void:
	var want := is_blocking()
	if want == blocking:
		return
	blocking = want
	if fighter.animator == null:
		return
	if want:
		fighter.animator.hold_pose(&"block")
	elif _phase == Phase.IDLE and _stun_left <= 0.0 and not _held() \
			and not (fighter.carry != null and fighter.carry.is_holding()) and not fighter.is_reacting():
		fighter.animator.release_pose()

# =============================================================================
# Chains (Round 7)
# =============================================================================

## Hits in the current chain (0 = no chain). HUD combo counter.
func get_chain_count() -> int:
	return _chain_count if _chain_alive(TimeDirector.now()) else 0

## Punch string position the next punch press will use: 0 jab, 1 cross, 2 hook
## (the HUD's pips read it).
func get_string_index() -> int:
	return _string_index_now()

## Round 9: real seconds on the clock R9_STRING_RESET runs on: since the last
## punch press (or the end of that punch when later); 0 while a string punch is
## in progress; capped at Tuning.R9_STRING_RESET (also before any punch). The
## HUD fades the lit pip with it.
func get_string_idle_time() -> float:
	if _cur_string >= 0:
		return 0.0
	return clampf(TimeDirector.now() - _string_last, 0.0, Tuning.R9_STRING_RESET)

## Kept for older callers: the chain count.
func get_combo_count() -> int:
	return get_chain_count()

## The chain is alive: a hit landed and a move is still going, or the last
## one ended less than R7_CHAIN_GRACE ago.
func _chain_alive(now: float) -> bool:
	return _chain_count > 0 and (_phase != Phase.IDLE or now <= _chain_until)

## Per tick: the idle chain drops after its grace; the combat target clears
## when it goes down, dies or leaves R7_TARGET_RANGE + R7_TARGET_KEEP_EXTRA.
func _tick_chain(now: float) -> void:
	if _chain_count > 0 and _phase == Phase.IDLE and now > _chain_until:
		_end_chain()
	get_combat_target()

## The chain is over (grace ran out, a whiff, a blocked hit, or this fighter
## was hit): chain_ended. Round 9: the punch string keeps its place
## (_string_index_now: only R9_STRING_RESET idle sends it back to the jab).
func _end_chain() -> void:
	if _chain_count <= 0:
		return
	var n := _chain_count
	_chain_count = 0
	_chain_until = -INF
	GameEvents.chain_ended.emit(fighter, n)
	GameEvents.combo_ended.emit(fighter, n)

## A Round 7 move landed on `victim`: the chain grows, the combat target is
## set, and a short push is followed during recovery.
func _on_r7_landed(victim: Fighter, info: HitInfo) -> void:
	_landed = true
	_chain_count += 1
	info.chain_index = _chain_count
	info.combo_index = _chain_count
	if victim == _target or not _alive(_target):
		_combat_target = victim  # the target struck (not a bystander the swing also caught)
	GameEvents.chain_hit.emit(fighter, victim, info.move_id, _chain_count)
	GameEvents.combo_progress.emit(fighter, _chain_count, info.damage_scale)
	if info.react in FOLLOW_REACTS and info.push > 0.0 and info.push <= Tuning.R7_FOLLOW_MAX_PUSH \
			and not info.has_meta(&"escaped"):
		_follow_left = info.push * Tuning.R7_FOLLOW_SHARE
		_follow_dir = info.hit_direction
		_follow_victim = victim

## The last target struck while it is still a valid freeflow target within
## Tuning.R7_TARGET_RANGE + R7_TARGET_KEEP_EXTRA; null otherwise. Once it went
## down or out of range it stays cleared until struck again.
func get_combat_target() -> Fighter:
	if _combat_target == null:
		return null
	if not is_instance_valid(_combat_target) or not Targeting.is_freeflow_target(fighter, _combat_target,
			Tuning.R7_TARGET_RANGE + Tuning.R7_TARGET_KEEP_EXTRA):
		_combat_target = null
	return _combat_target

## True while a strike, a grab (Carry's glide) or a counter glides to its
## target before its startup.
func is_gliding() -> bool:
	if _phase == Phase.GLIDE:
		return true
	var c := fighter.carry if fighter != null else null
	return c != null and c.has_method(&"is_gliding") and bool(c.call(&"is_gliding"))

# =============================================================================
# Counter (Round 7)
# =============================================================================

## Defence calls this on a successful Counter press: cancel the player's own
## glide, startup or recovery, glide to `target` (up to Tuning.R7_COUNTER_GLIDE)
## and play the counter move, which connects on its first active frame
## (auto-connect). False if it could not start (active frames, reacting, down,
## held or holding).
func play_counter(target: Fighter) -> bool:
	if fighter == null or fighter.is_dead() or fighter.is_down() or _held() or _holding_body():
		return false
	if _phase == Phase.ACTIVE or fighter.is_reacting() or is_hit_stunned():
		return false
	var m := MoveLibrary.get_move(&"counter")
	if m == null:
		return false
	cancel()
	var tgt: Fighter = target if _alive(target) and target.team != fighter.team and not target.is_down() else null
	_press_action = Action.COUNTER
	_press_t = TimeDirector.now()
	_hold_pending = false
	_cur_string = -1
	_launch_move(m, tgt, Tuning.R7_COUNTER_GLIDE)
	return true

## Attacker side: this fighter's current enemy attack has its counter window
## open on `on` (Tuning.R7_COUNTER_WINDOW before the first active frame, through
## the active frames).
func is_counter_window_open(on: Fighter) -> bool:
	return _window_open and on != null and on == _window_target

## Attacker side: the current attack can be countered (false for grabs and the
## shoulder charge: blue tell, dodge only).
func is_attack_counterable() -> bool:
	return _move != null and _move.enemy and _move.counterable \
		and (_phase == Phase.STARTUP or _phase == Phase.ACTIVE)

## Per tick: an enemy attack's window opens when its time to active reaches
## R7_COUNTER_WINDOW (on its target, else the player in its reach).
func _update_window() -> void:
	if _window_open:
		if not _alive(_window_target):
			_close_window()
		return
	if _move == null or not _move.enemy or not (_phase == Phase.STARTUP or _phase == Phase.ACTIVE):
		return
	if time_to_active() > Tuning.R7_COUNTER_WINDOW:
		return
	var tgt: Fighter = _target if _alive(_target) and _target.team != fighter.team else null
	if tgt == null:
		tgt = _enemy_reach_target(_move, maxf(_startup - _t, 0.0))
	if tgt == null:
		return
	_window_open = true
	_window_target = tgt
	_window_counterable = _move.counterable
	GameEvents.counter_window.emit(fighter, tgt, true, _window_counterable)

func _close_window() -> void:
	if not _window_open:
		return
	_window_open = false
	var t: Variant = _window_target
	_window_target = null
	GameEvents.counter_window.emit(fighter, t if is_instance_valid(t) else null, false, _window_counterable)

# =============================================================================
# Hit detection (attacker side)
# =============================================================================

## Striking point of a bone: the fist for hands, else the bone origin.
func _bone_point(bone: StringName) -> Vector3:
	if not _rig_ready():
		return Vector3.INF
	if String(bone).ends_with("Hand") and fighter.rig.has_method(&"get_fist_position"):
		return fighter.rig.call(&"get_fist_position", bone)
	return fighter.rig.get_bone_global_position(bone)

func _rig_ready() -> bool:
	return fighter.rig != null and fighter.rig.skeleton != null

## First active frame: an opponent that is invulnerable now (a counter or a
## dodge) cannot be hit by this attack at all (doc: Counter, "every other
## attack whose first active frame falls inside the invulnerable time misses").
func _skip_invulnerable() -> void:
	for opp in Targeting.opponents_of(fighter):
		if opp.is_invulnerable():
			_registry[opp.get_instance_id()] = true

## The first active frame of every attack: each fighter it is aimed at gets
## the first say through its Defence (Defence.intercepts: the teleport, the
## parry, the sidestep while H keeps them). An intercepted attack cannot hit
## that fighter (a parry that staggers the attacker ends the attack).
func _check_interceptions() -> void:
	var reach := _move.reach * fighter.get_height_scale() + INTERCEPT_EXTRA
	var fwd := fighter.get_forward()
	for opp in Targeting.opponents_of(fighter):
		if _phase != Phase.ACTIVE:
			return
		var d := opp.defence
		if d == null or not d.has_method(&"intercepts") or _registry.has(opp.get_instance_id()):
			continue
		if d.has_method(&"is_enabled") and not bool(d.call(&"is_enabled")):
			continue
		var to := opp.get_ground_position() - fighter.get_ground_position()
		to.y = 0.0
		var dist := to.length()
		if dist > reach:
			continue
		if opp != get_attack_target() and dist > 0.05 and fwd.dot(to / dist) < 0.0:
			continue
		if bool(d.call(&"intercepts", fighter, _move.id)):
			_registry[opp.get_instance_id()] = true

func _detect_hits() -> void:
	var space := fighter.get_world_3d().direct_space_state
	var found := {}  # Fighter -> [dist, bone, pos]
	var ground := {}  # Round 9: lying bodies the limbs touch -> [dist, bone, pos]
	var m := _move
	var hs := fighter.get_height_scale()
	# 1. Striking limbs (PoseLibrary.STRIKE_BONES), each swept from the previous tick.
	_q_sphere.radius = m.limb_radius
	for bone in m.strike_limbs():
		var limb := _bone_point(bone)
		if limb == Vector3.INF:
			break
		var prev: Vector3 = _prev_limbs.get(bone, limb)
		var seg := limb - prev
		var n := clampi(int(ceil(seg.length() / maxf(m.limb_radius, 0.05))), 1, 8)
		for i in n + 1:
			var p := prev.lerp(limb, float(i) / float(n))
			_query(space, _q_sphere, Transform3D(Basis(), p), p, found, ground)
		_prev_limbs[bone] = limb
	# 2. Fallback: capsule forward along facing to the move's reach.
	var fwd := fighter.get_forward()
	var base := fighter.global_position + Vector3.UP * m.height * hs
	var a := base + fwd * 0.2
	var b := base + fwd * m.reach * hs
	_q_capsule.radius = m.reach_radius
	_q_capsule.height = maxf((b - a).length() + m.reach_radius * 2.0, m.reach_radius * 2.0 + 0.01)
	# Capsule axis is local Y; rotate it onto the facing direction.
	_query(space, _q_capsule, Transform3D(Basis(Quaternion(Vector3.UP, fwd)), (a + b) * 0.5), b, found)
	# 3. Locked target (a free swing at a downed player) connects if close enough.
	var lt: Fighter = _locked_target if _alive(_locked_target) else null
	if lt != null and _valid_victim(lt) and not found.has(lt):
		var com := lt.get_center_of_mass()
		var flat := Vector3(com.x - fighter.global_position.x, 0.0, com.z - fighter.global_position.z)
		var lreach := PURSUIT_REACH if _is_pursuit_target(lt) else m.reach * hs + LOCKED_TARGET_REACH
		if flat.length() <= lreach and absf(com.y - base.y) < 3.0:
			var bone := m.target_bone
			if lt.is_down():
				bone = _nearest_bone(lt, _bone_point(m.limb) if _rig_ready() else com)
			found[lt] = [0.0, bone, com]
	# 4. Round 7 auto-connect: the chosen target is always hit when it is within
	# reach + R7_CONNECT_MARGIN on the first active frame (not invulnerable,
	# dodging or down), even if the limb sweep missed.
	# An air strike's target (Round 8) connects within R8_AIR_STRIKE_RANGE +
	# R7_CONNECT_MARGIN in 3D (it is up in the air with the player).
	var tgt: Fighter = _target if _alive(_target) else null
	if _first_active and m.r7 and tgt != null and not found.has(tgt) and _valid_victim(tgt) \
			and not tgt.is_invulnerable() and not _is_dodging(tgt):
		var near := _flat_dist(tgt) <= m.reach * hs + Tuning.R7_CONNECT_MARGIN
		if m.air:
			near = tgt.global_position.distance_to(fighter.global_position) \
				<= Tuning.R8_AIR_STRIKE_RANGE + Tuning.R7_CONNECT_MARGIN
		elif m.id == MoveLibrary.AXE:
			# Round 9: the ground axe kick reaches a lifted body up to reach_up above the feet.
			near = near and tgt.global_position.y - fighter.global_position.y <= float(Tuning.R9_AXE["reach_up"])
		if near:
			found[tgt] = [0.0, m.target_bone, _bone_pos(tgt, m.target_bone), true]
	for victim: Fighter in found:
		if not is_instance_valid(victim) or _registry.has(victim.get_instance_id()):
			continue
		var rec: Array = found[victim]
		_deliver(victim, rec[1], rec[2], rec.size() > 3)
		if _phase != Phase.ACTIVE:
			return
	# 5. Round 9: lying bodies the striking limbs touched (contact only).
	for victim: Fighter in ground:
		if not is_instance_valid(victim) or _registry.has(victim.get_instance_id()):
			continue
		var gr: Array = ground[victim]
		_deliver_ground(victim, gr[1], gr[2])
		if _phase != Phase.ACTIVE:
			return
	if found.is_empty() and not _hit_any:
		_try_wall_strike(space)
	if found.is_empty() and not _hit_any:
		_try_debris_kick()

static func _is_dodging(f: Fighter) -> bool:
	return f.traversal != null and f.traversal.is_dodging()

## The victim's physical bone nearest `point` (a swing at a body on the ground).
static func _nearest_bone(victim: Fighter, point: Vector3) -> StringName:
	if victim.rig == null:
		return Bones.CHEST
	var best := Bones.CHEST
	var best_d := INF
	for b: StringName in [Bones.HEAD, Bones.CHEST, Bones.SPINE, Bones.HIPS, Bones.L_UPPER_LEG,
			Bones.R_UPPER_LEG, Bones.L_UPPER_ARM, Bones.R_UPPER_ARM]:
		var d := victim.rig.get_bone_global_position(b).distance_to(point)
		if d < best_d:
			best_d = d
			best = b
	return best

# --- Wall strikes (Round 3): the player's punches and kicks hit walls ---------
## A player strike that reaches world geometry with a `receive_strike` method
## (Destructible panels, pillars, props, outer walls) strikes it once per move.
## Fighters win: nothing is struck while an opponent is in the move's reach.
func _try_wall_strike(space: PhysicsDirectSpaceState3D) -> void:
	if _wall_struck or not fighter.is_player or _move == null or not _move.r7:
		return
	if _opponent_in_reach():
		return
	var contact := _wall_contact(space)
	if contact.is_empty():
		return
	var target: Node = contact["target"]
	var pos: Vector3 = contact["position"]
	var normal: Vector3 = contact["normal"]
	var dir := fighter.get_forward()
	var power := strike_power()
	_wall_struck = true
	_hit_any = true  # no whiff (and no whiff recovery) off a wall
	var result: Variant = target.call(&"receive_strike", fighter, pos, dir, power)
	var res: StringName = result if result is StringName else &"hold"
	last_wall_strike = {"target": target, "position": pos, "normal": normal, "power": power, "result": res}
	_wall_feel(res, normal)

## Strike power on a wall: WALL_POWER_PER_WEIGHT x the move's Round 7 weight
## (Round 8: a strike's own weight when that is more: a charged one's at its c),
## so the wall tables keep holding for taps.
func strike_power() -> float:
	if _move == null:
		return 0.0
	var w := float(_move.r7_entry().get("weight", 0.0))
	if _move.r8:
		w = maxf(w, float(_r8_values(_move.id, _move.charged, _strike_c)["weight"]))
	return WALL_POWER_PER_WEIGHT * w

func _wall_feel(result: StringName, normal: Vector3) -> void:
	var broke := result == &"break" or result == &"hole"
	var stop := Tuning.STRIKE_HITSTOP * (STRIKE_BREAK_HITSTOP_MULT if result == &"break" else 1.0)
	fighter.freeze_hitstop(stop)  # attacker only
	if result in [&"hold", &"chip", &"crack"]:
		var back := Vector3(normal.x, 0.0, normal.z)
		if back.length_squared() < 1e-4:
			back = -fighter.get_forward()
		_fighter_call(&"knockback", [back.normalized() * Tuning.STRIKE_RECOIL, STRIKE_RECOIL_TIME])
	# A one-off (not a hit on a body): wall strikes keep their own shake.
	GameEvents.screen_shake.emit(Tuning.STRIKE_SHAKE * (2.0 if broke else 1.0))

## An opponent the current move could still hit (the fighter wins over a wall).
func _opponent_in_reach() -> bool:
	var reach := _move.reach * fighter.get_height_scale() + STRIKE_FIGHTER_MARGIN
	var fwd := fighter.get_forward()
	for opp in Targeting.opponents_of(fighter):
		if _registry.has(opp.get_instance_id()) or opp.is_down():
			continue
		var to := opp.get_ground_position() - fighter.get_ground_position()
		to.y = 0.0
		var d := to.length()
		if d <= reach and (d < 0.05 or fwd.dot(to / d) > 0.3):
			return true
	return false

## Contact with a strikeable world node: the striking limbs first (the same
## limb points the fighter query uses), else a ray along facing at the move's
## height to its reach. Floors (normal mostly up) and nodes without
## receive_strike are ignored. {} when nothing.
func _wall_contact(space: PhysicsDirectSpaceState3D) -> Dictionary:
	var m := _move
	var hs := fighter.get_height_scale()
	var fwd := fighter.get_forward()
	var mask := Layers.WORLD | Layers.DESTRUCTIBLE
	for bone in m.strike_limbs():
		var limb := _bone_point(bone)
		if limb == Vector3.INF:
			break
		_q_sphere.radius = m.limb_radius + 0.05
		_q_params.shape = _q_sphere
		_q_params.transform = Transform3D(Basis(), limb)
		_q_params.collide_with_areas = false
		_q_params.collide_with_bodies = true
		_q_params.collision_mask = mask
		for r in space.intersect_shape(_q_params, 8):
			var target := _strike_target(r.get("collider") as Node)
			if target == null:
				continue
			var hit := _ray_to(space, limb - fwd * 0.6, limb + fwd * (m.limb_radius + 0.2), target)
			if hit.is_empty():
				# The limb is inside the surface: ask the solver for the contact normal.
				var rest := space.get_rest_info(_q_params)
				if rest.is_empty() or _strike_target(instance_from_id(rest.get("collider_id", 0)) as Node) != target:
					continue
				hit = {"position": rest["point"], "normal": rest["normal"]}
			if absf((hit["normal"] as Vector3).y) > FLOOR_NORMAL_Y:
				continue
			hit["target"] = target
			return hit
	# Fallback: facing ray at the move's height (poses that stop short of the wall).
	var base := fighter.global_position + Vector3.UP * m.height * hs
	var reach := m.reach * hs + m.reach_radius * 0.5
	var ray := PhysicsRayQueryParameters3D.create(base, base + fwd * reach, mask, [fighter.get_rid()])
	for _i in 3:
		var h := space.intersect_ray(ray)
		if h.is_empty():
			break
		var tgt := _strike_target(h.get("collider") as Node)
		var n: Vector3 = h["normal"]
		if tgt != null and absf(n.y) <= FLOOR_NORMAL_Y:
			return {"target": tgt, "position": h["position"], "normal": n}
		var ex: Array[RID] = ray.exclude
		ex.append(h["rid"])
		ray.exclude = ex
	return {}

## Ray toward `target` only (other colliders are skipped).
func _ray_to(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, target: Node) -> Dictionary:
	var ray := PhysicsRayQueryParameters3D.create(from, to, Layers.WORLD | Layers.DESTRUCTIBLE, [fighter.get_rid()])
	for _i in 4:
		var h := space.intersect_ray(ray)
		if h.is_empty():
			return {}
		if _strike_target(h.get("collider") as Node) == target:
			return {"position": h["position"], "normal": h["normal"]}
		var ex: Array[RID] = ray.exclude
		ex.append(h["rid"])
		ray.exclude = ex
	return {}

## The first node on `n` or its ancestors with receive_strike (never a fighter).
static func _strike_target(n: Node) -> Node:
	while n != null:
		if n is Fighter:
			return null
		if n.has_method(&"receive_strike"):
			return n
		n = n.get_parent()
	return null

## The player's front kick or roundhouse sweeping through a large debris chunk
## kicks it at the target (or straight ahead) as a projectile.
func _try_debris_kick() -> void:
	if _debris_kicked or not fighter.is_player or _move == null:
		return
	if not (_move.id == &"front_kick" or _move.id == &"roundhouse"):
		return
	var foot := _bone_point(&"RightFoot")
	if foot == Vector3.INF:
		foot = fighter.global_position + fighter.get_forward() * 0.8 + Vector3.UP * 0.4
	var low := Vector3(foot.x, fighter.global_position.y + 0.25, foot.z)
	var body := DebrisManager.find_nearest(foot, DEBRIS_KICK_RADIUS, true)
	if body == null:
		body = DebrisManager.find_nearest(low, DEBRIS_KICK_RADIUS, true)
	if body == null or not is_instance_valid(body):
		return
	_debris_kicked = true
	_hit_any = true
	DebrisManager.release(body)
	var t: Fighter = _target if _alive(_target) else Targeting.pick_freeflow_target(fighter, _stick_dir(), null,
		_camera_forward(), DEBRIS_KICK_RANGE)
	var v: Vector3
	if t != null:
		v = ThrownChunk.ballistic_velocity(body.global_position, t.get_aim_point() - Vector3.UP * 0.2,
			DEBRIS_KICK_SPEED, body.gravity_scale)
	else:
		v = fighter.get_forward() * DEBRIS_KICK_SPEED + Vector3.UP * 3.0
	ThrownChunk.launch_body(body, v, fighter, DEBRIS_KICK_DAMAGE, &"debris_kick")

## Hurtboxes the shape touches: valid victims into `found`; with `ground`
## (the limb sweep only, Round 9), lying opponents into `ground`.
func _query(space: PhysicsDirectSpaceState3D, shape: Shape3D, xform: Transform3D,
		ref: Vector3, found: Dictionary, ground = null) -> void:
	_q_params.shape = shape
	_q_params.transform = xform
	_q_params.collide_with_areas = true
	_q_params.collide_with_bodies = false
	_q_params.collision_mask = Layers.HURTBOX
	for r in space.intersect_shape(_q_params, 32):
		var area := r.get("collider") as Area3D
		if area == null or not area.has_meta(&"fighter"):
			continue
		var f := area.get_meta(&"fighter") as Fighter
		var into: Dictionary = found
		if not _valid_victim(f):
			if ground == null or not _ground_victim(f):
				continue
			into = ground
		var p := area.global_position
		if area.get_child_count() > 0 and area.get_child(0) is Node3D:
			p = (area.get_child(0) as Node3D).global_position
		var d := p.distance_to(ref)
		if not into.has(f) or (into[f][0] as float) > d:
			into[f] = [d, area.get_meta(&"bone"), p]

## Round 9: a lying opponent (knocked down, a launch at rest, getting up) a
## player strike's limb may hit by contact (never a target).
func _ground_victim(f: Fighter) -> bool:
	if f == null or not is_instance_valid(f) or f == fighter or f.team == fighter.team or f.is_dead() \
			or _registry.has(f.get_instance_id()):
		return false
	return _move != null and _move.r7 and f.is_down() and f.combat != null and f.combat.is_lying()

## Downed bodies (knocked down, launched, getting up) are never struck by the
## player's moves (doc: Freeflow targeting); a lifted body is.
func _valid_victim(f: Fighter) -> bool:
	if f == null or not is_instance_valid(f) or f == fighter or f.team == fighter.team \
			or f.is_dead() or _registry.has(f.get_instance_id()):
		return false
	return not (_move != null and _move.r7 and f.is_down() and not _is_pursuit_target(f))

## `auto`: the hit came from the auto-connect (HitInfo meta "auto_connect").
func _deliver(victim: Fighter, bone: StringName, pos: Vector3, auto := false) -> void:
	_registry[victim.get_instance_id()] = true
	var info := _build_hit(victim, bone, pos)
	if auto:
		info.set_meta(&"auto_connect", true)
	var result := victim.take_hit(info)
	_hit_any = true
	last_dealt = info
	hit_dealt.emit(info)
	if result == HitInfo.Result.BLOCKED:
		_blocked = true
	if result != HitInfo.Result.HIT or _move == null:
		return
	if info.pursuit and fighter.defence != null and fighter.defence.has_method(&"on_pursuit_hit"):
		fighter.defence.call(&"on_pursuit_hit", victim)
	if info.react == &"spike":
		# Its floor impact is a shockwave (the axe kick's blast radius, else Round 7's).
		_spiked[victim.get_instance_id()] = [victim, TimeDirector.now(),
			float(info.get_meta(&"spike_blast", Tuning.R7_SPIKE_BLAST_RADIUS))]
	if _move.r7:
		_on_r7_landed(victim, info)
	if _move.air:
		_on_air_hit(victim, info)
	elif _move.charged and _move.id == &"uppercut" and info.react == &"lift" \
			and info.lift_height >= Tuning.R8_AIR_FOLLOW_MIN_LIFT - 1e-3:
		# A charged uppercut's lift: Jump follows it (get_air_follow_target).
		_air_follow_body = victim
		_air_follow_t = TimeDirector.now()
		_air_hits = 0

## Round 9: a strike's limb touched a lying body (_ground_victim): the ground
## hit (_build_ground_hit). No chain, no target change; not a whiff.
func _deliver_ground(victim: Fighter, bone: StringName, pos: Vector3) -> void:
	_registry[victim.get_instance_id()] = true
	var info := _build_ground_hit(victim, bone, pos)
	victim.take_hit(info)
	_hit_any = true
	last_dealt = info
	hit_dealt.emit(info)

## The ground hit (Tuning.R9_GROUND_HIT; a tap's numbers, a charged strike's
## lerped by its c): react &"ground", HitInfo.ground_strike, flinch tier,
## damage (combo scaled), pressure, and meta "ground_dv": the shove along the
## strike (flat) plus the lift, which the victim adds to its ragdoll.
func _build_ground_hit(victim: Fighter, bone: StringName, pos: Vector3) -> HitInfo:
	var c := _strike_c if _move.charged else 0.0
	var g: Dictionary = Tuning.R9_GROUND_HIT
	var info := HitInfo.new()
	info.attacker = fighter
	info.victim = victim
	info.move_id = _move.id
	info.kind = &"strike"
	var sdir := _strike_dir(victim)
	var flat := Vector3(sdir.x, 0.0, sdir.z)
	if flat.length_squared() < 1e-4:
		flat = fighter.get_forward()
	flat = flat.normalized()
	info.set_meta(&"strike_dir", flat)
	info.hit_direction = flat
	info.hit_position = pos
	info.hit_bone = bone
	info.zone = BodyZones.of_bone(bone)
	info.level = HitInfo.Level.LOW
	info.react = &"ground"
	info.ground_strike = true
	info.victim_state = victim.get_react_state()
	info.charged = _move.charged
	info.charge = c
	info.air = _move.air
	info.tier = HitInfo.Tier.FLINCH
	info.reaction = HitInfo.reaction_for_tier(info.tier)
	info.hitstop = GROUND_HIT_HITSTOP
	info.weight = lerpf(GROUND_HIT_WEIGHT.x, GROUND_HIT_WEIGHT.y, c) if _move.charged else GROUND_HIT_WEIGHT.x
	info.pressure = float(g["pressure"]) * Tuning.debug_pressure_mult
	info.set_meta(&"guard_break", false)
	var dmg_v: Vector2 = g["dmg"]
	var shove_v: Vector2 = g["shove"]
	var shove := lerpf(shove_v.x, shove_v.y, c) if _move.charged else shove_v.x
	info.set_meta(&"ground_dv", flat * shove + Vector3.UP * float(g["lift"]))
	var vc := victim.combat
	var scale := combo_scale(vc.next_taken_index() if vc != null else 1)
	info.damage = (lerpf(dmg_v.x, dmg_v.y, c) if _move.charged else dmg_v.x) * scale * _damage_mult()
	info.damage_scale = scale
	info.chain_index = (_chain_count if _chain_alive(TimeDirector.now()) else 0) + 1
	info.combo_index = info.chain_index
	if fighter.is_player:
		_apply_break_bonus(info, victim)
	info.energy = _energy_of(info, victim.get_total_mass())
	return info

# --- The hit an attack deals -------------------------------------------------------
## Attacker side of the hit pipeline: a Round 7 move from R7_MOVES / R7_PAYOFFS
## (_fill_r7); enemy moves deal their preset Round 5 tier (_fill_preset).
func _build_hit(victim: Fighter, bone: StringName, pos: Vector3) -> HitInfo:
	var m := _move
	var info := HitInfo.new()
	info.attacker = fighter
	info.victim = victim
	info.move_id = m.id
	info.kind = m.kind
	var sdir := _strike_dir(victim)
	info.set_meta(&"strike_dir", sdir)
	var to := victim.get_ground_position() - fighter.get_ground_position()
	to.y = 0.0
	info.hit_direction = to.normalized() if to.length() > 0.05 else fighter.get_forward()
	if not m.r7:
		# Enemy moves push along their strike (a hook turns the head across).
		var flat := Vector3(sdir.x, 0.0, sdir.z)
		if flat.length_squared() > 1e-4:
			info.hit_direction = flat.normalized()
	info.hit_position = pos
	info.hit_bone = m.target_bone if (m.force_bone and not fighter.is_player) else bone
	info.zone = BodyZones.of_bone(info.hit_bone)
	info.level = m.hit_level
	info.unblockable = m.unblockable
	if m.id == MoveLibrary.AXE:
		_fill_axe(info, victim)  # Round 9: ground and air
	elif m.r8:
		if m.air:
			_fill_air(info, victim)
		else:
			_fill_r8(info, victim)
	elif m.r7:
		_fill_r7(info, victim)
	else:
		_fill_preset(info, victim)
	if m.r7 and fighter.is_player:
		_apply_break_bonus(info, victim)
	return info

## World direction the strike pushes `victim`: MoveData.push_dir in the frame
## of the line from the attacker to the victim (a hook turns the head across,
## an uppercut lifts, a roundhouse sweeps sideways).
func _strike_dir(victim: Fighter) -> Vector3:
	var base := victim.get_ground_position() - fighter.get_ground_position()
	base.y = 0.0
	base = base.normalized() if base.length() > 0.05 else fighter.get_forward()
	if _move == null:
		return base
	var p := _move.push_dir
	var right := base.cross(Vector3.UP).normalized()
	var d := right * p.x + Vector3.UP * p.y + base * p.z
	return d.normalized() if d.length_squared() > 1e-6 else base

## A Round 7 player move (docs/Round 7: Moves, Payoffs, Hit feel, God path):
## the move's R7_MOVES entry (a dropping strike: its button's move), or the
## R7_PAYOFFS entry for the victim's react state; a sprint strike at v >=
## SPEED_BONUS_FROM pushes harder or launches (_apply_sprint); the pursuit hit
## relaunches or spikes (_fill_pursuit). Heavy enemies take push x
## R7_HEAVY_PUSH_MULT, stun x R7_HEAVY_STUN_MULT, lift x R7_HEAVY_LIFT_MULT
## (launches x HEAVY_LAUNCH_MULT). Damage keeps the combo scaling; a fleeing or
## crawling enemy is finished; a killing launch may take a limb
## (sever_on_kill_chance). The victim's side applies guard, tell armor and the
## anti-infinite stun decay.
func _fill_r7(info: HitInfo, victim: Fighter) -> void:
	var id := _entry_id()
	var e := _entry_of(id)
	var state := victim.get_react_state()
	info.victim_state = state
	if _drop_as != &"" and _move.drop:
		info.set_meta(&"drop_as", _drop_as)
	var pay: Dictionary = (Tuning.R7_PAYOFFS.get(id, {}) as Dictionary).get(state, {})
	info.payoff = not pay.is_empty()
	var heavy := victim.is_heavy()
	info.react = pay.get("react", e["react"])
	info.push = float(pay.get("push", e["push"]))
	info.stun = float(pay.get("stun", e["stun"]))
	info.weight = float(e["weight"])
	info.hitstop = float(e["hitstop"])
	info.counter = _move.id == &"counter"
	info.chain_index = (_chain_count if _chain_alive(TimeDirector.now()) else 0) + 1
	info.combo_index = info.chain_index
	info.set_meta(&"guard_break", bool(e.get("guard_break", false)))
	var launch_speed := float(pay.get("launch_speed", e.get("launch_speed", 9.0)))
	var launch_angle := float(pay.get("launch_angle", e.get("launch_angle", 20.0)))
	# Sprint strikes (kept for the god path): recorded, and at speed they push
	# harder or launch.
	info.speed_bonus = Power.speed_bonus(_p_speed, _p_cap)
	info.sprint = _p_speed >= Tuning.SPEED_BONUS_FROM and not info.counter
	if info.sprint:
		var sprint_launch := _apply_sprint(info, id, graph.is_heavy(id))
		if sprint_launch > 0.0:
			launch_speed = maxf(launch_speed if info.react == &"launch" else 0.0, sprint_launch)
			launch_angle = Tuning.R7_SPRINT_LAUNCH_ANGLE if launch_speed == sprint_launch else launch_angle
			info.react = &"launch"
	info.lift_height = 0.0
	if info.react == &"lift":
		info.lift_height = float(pay.get("lift", Tuning.R7_LIFT_HEIGHT))
	elif info.react == &"repop":
		info.lift_height = Tuning.R7_REPOP_HEIGHT
	if heavy:
		info.push *= Tuning.R7_HEAVY_PUSH_MULT
		info.stun *= Tuning.R7_HEAVY_STUN_MULT
		info.lift_height *= Tuning.R7_HEAVY_LIFT_MULT
	info.launch_velocity = Vector3.ZERO
	if info.react == &"launch":
		# A payoff's launch, the move's own (a heavy roundhouse), or a sprint launch.
		var speed := minf(launch_speed * (Tuning.HEAVY_LAUNCH_MULT if heavy else 1.0), Tuning.LAUNCH_SPEED_MAX)
		var a := deg_to_rad(launch_angle)
		info.launch_velocity = (info.hit_direction * cos(a) + Vector3.UP * sin(a)) * speed
	info.tier = REACT_TIER.get(info.react, HitInfo.Tier.STAGGER) if (info.payoff or info.react != e["react"]) \
		else _tier_named(e["tier"])
	# Damage: the move's (x the payoff's), combo scaled by the victim's hit count.
	var vc := victim.combat
	var n := vc.next_taken_index() if vc != null else 1
	var scale := combo_scale(n)
	var base := float(e["dmg"]) * float(pay.get("dmg_mult", 1.0))
	if _is_pursuit_target(victim):
		base = _fill_pursuit(info, victim)
	info.damage = base * scale * _damage_mult()
	info.damage_scale = scale
	if victim.is_fleeing() or Targeting.is_crawling(victim):
		info.damage = maxf(info.damage, victim.hp)  # any hit finishes a fleeing or crawling enemy
	_sever_on_kill(info, victim)
	info.reaction = HitInfo.reaction_for_tier(info.tier)
	info.energy = _energy_of(info, victim.get_total_mass())

## A Round 8 strike (docs/Round 8 — Charge and Pressure.md: Moves): a tap from
## R8_MOVES[id].tap, a charged strike from .charged at the c of its release
## (_r8_values). The R7_PAYOFFS row for the victim's react state replaces the
## result (taps by their id, charged strikes by payoff_id; payoffs never scale
## with c), except that a non-launch payoff never replaces a charged launch.
## Round 9: a spinning move (the charged hook: "spin") pushes, knocks down and
## launches along the hit (meta "push_dir") and, when it knocks down or
## launches, spins the body (meta "spin_rate": R9_HOOK_SPIN lerped by c, the
## sign of MoveData.push_dir.x: a left hook turns the victim to its left) and
## hops a knockdown (meta "hop": R9_HOOK_HOP). Then Round 7's rules: sprint strikes (charged strikes launch
## like Round 7's heavies), heavy enemies, combo scaling, the pursuit hit,
## fleeing and crawling enemies, the sever on a killing launch. The hit's
## pressure is its entry's x Tuning.debug_pressure_mult (the victim applies its
## own multipliers); a charged strike breaks guards and tell armor.
func _fill_r8(info: HitInfo, victim: Fighter) -> void:
	var id := _move.id
	var charged := _move.charged
	var e := _r8_values(id, charged, _strike_c)
	var state := victim.get_react_state()
	info.victim_state = state
	var pay: Dictionary = (Tuning.R7_PAYOFFS.get(e["payoff_id"], {}) as Dictionary).get(state, {})
	if bool(e["launched"]) and StringName(pay.get("react", &"")) != &"launch":
		pay = {}  # the charged launch outranks a non-launch payoff
	info.payoff = not pay.is_empty()
	var heavy := victim.is_heavy()
	info.react = pay.get("react", e["react"])
	info.push = float(pay.get("push", e["push"]))
	info.stun = float(pay.get("stun", e["stun"]))
	info.weight = float(e["weight"])
	info.hitstop = float(e["hitstop"])
	info.charged = charged
	info.charge = _strike_c if charged else 0.0
	info.charge_level = (1 + _steps_passed(_steps_for(id), _strike_c)) if charged else 0
	info.pressure = float(e["pressure"]) * Tuning.debug_pressure_mult
	info.counter = false
	info.chain_index = (_chain_count if _chain_alive(TimeDirector.now()) else 0) + 1
	info.combo_index = info.chain_index
	info.set_meta(&"guard_break", charged)
	if bool(e["full_break"]):
		info.set_meta(&"full_break", true)
	var launch_speed := float(pay.get("launch_speed", e.get("launch_speed", 9.0)))
	var launch_angle := float(pay.get("launch_angle", e.get("launch_angle", 20.0)))
	# Sprint strikes (god path): at speed they push harder or launch.
	info.speed_bonus = Power.speed_bonus(_p_speed, _p_cap)
	info.sprint = _p_speed >= Tuning.SPEED_BONUS_FROM
	if info.sprint:
		var sprint_launch := _apply_sprint(info, id, charged)
		if sprint_launch > 0.0:
			launch_speed = maxf(launch_speed if info.react == &"launch" else 0.0, sprint_launch)
			launch_angle = Tuning.R7_SPRINT_LAUNCH_ANGLE if launch_speed == sprint_launch else launch_angle
			info.react = &"launch"
	info.lift_height = 0.0
	if info.react == &"lift":
		info.lift_height = float(pay.get("lift", e.get("lift", Tuning.R7_LIFT_HEIGHT)))
	elif info.react == &"repop":
		info.lift_height = Tuning.R7_REPOP_HEIGHT
	if heavy:
		info.push *= Tuning.R7_HEAVY_PUSH_MULT
		info.stun *= Tuning.R7_HEAVY_STUN_MULT
		info.lift_height *= Tuning.R7_HEAVY_LIFT_MULT
	var dir := info.hit_direction
	if bool(e["spin"]):
		info.set_meta(&"push_dir", dir)  # every push of it along the hit
		if info.react in [&"knockdown", &"launch"]:
			var side := 1.0 if _move.push_dir.x >= 0.0 else -1.0
			info.set_meta(&"spin_rate", lerpf(Tuning.R9_HOOK_SPIN.x, Tuning.R9_HOOK_SPIN.y, _strike_c) * side)
			if info.react == &"knockdown":
				info.set_meta(&"hop", Tuning.R9_HOOK_HOP)
	info.launch_velocity = Vector3.ZERO
	if info.react == &"launch":
		var speed := minf(launch_speed * (Tuning.HEAVY_LAUNCH_MULT if heavy else 1.0), Tuning.LAUNCH_SPEED_MAX)
		var a := deg_to_rad(launch_angle)
		info.launch_velocity = (dir * cos(a) + Vector3.UP * sin(a)) * speed
	info.tier = _tier_named(e["tier"]) if (not info.payoff and info.react == e["base_react"]) \
		else REACT_TIER.get(info.react, HitInfo.Tier.STAGGER)
	var vc := victim.combat
	var n := vc.next_taken_index() if vc != null else 1
	var scale := combo_scale(n)
	var base := float(e["dmg"]) * float(pay.get("dmg_mult", 1.0))
	if _is_pursuit_target(victim):
		base = _fill_pursuit(info, victim)
	info.damage = base * scale * _damage_mult()
	info.damage_scale = scale
	if victim.is_fleeing() or Targeting.is_crawling(victim):
		info.damage = maxf(info.damage, victim.hp)  # any hit finishes a fleeing or crawling enemy
	_sever_on_kill(info, victim)
	info.reaction = HitInfo.reaction_for_tier(info.tier)
	info.energy = _energy_of(info, victim.get_total_mass())

## The resolved Round 8 entry of strike `id` (MoveLibrary.r8_row: Round 9's axe
## kick too): its "tap" entry, or its "charged" entry at c (Vector2 pairs
## lerped; "react" &"launch" from min(launch_from, Tuning.debug_launch_step),
## "full_react" at c = 1). Adds "base_react" (the entry's own react),
## "launched", "full_break" (c = 1), "spin" (Round 9: the charged hook) and
## "payoff_id" (the tap's own id, or the charged entry's).
static func _r8_values(id: StringName, charged: bool, c: float) -> Dictionary:
	var row: Dictionary = MoveLibrary.r8_row(id)
	if not charged:
		var t: Dictionary = (row["tap"] as Dictionary).duplicate()
		t["base_react"] = t["react"]
		t["launched"] = false
		t["full_break"] = false
		t["spin"] = false
		t["payoff_id"] = id
		return t
	var ch: Dictionary = row["charged"]
	var out := {}
	for k: String in ch:
		var v: Variant = ch[k]
		out[k] = lerpf((v as Vector2).x, (v as Vector2).y, c) if v is Vector2 else v
	out["base_react"] = ch["react"]
	out["launched"] = false
	var full := c >= 1.0 - 1e-4
	if ch.has("launch_from") and c >= minf(float(ch["launch_from"]), Tuning.debug_launch_step) - 1e-4:
		out["react"] = &"launch"
		out["launched"] = true
	elif full and ch.has("full_react"):
		out["react"] = ch["full_react"]
	out["full_break"] = full and bool(ch.get("full_break", false))
	out["spin"] = bool(ch.get("spin", false))
	out["payoff_id"] = ch.get("payoff_id", id)
	return out

## Round 9: the axe kick (ground or air; docs/Round 9: Axe kick): a spike
## straight down (SPIKE_DRIFT degrees along the hit) at its "speed", with
## its damage, hitstop, weight and pressure: the tap's, or the charged entry's
## lerped by c (an air axe kick is never charged); meta "spike_blast" is the
## floor shockwave's radius. Never a payoff. A charged one breaks guards.
## HitInfo.move_id: &"axe_kick", or &"air_axe" for the air combo's.
func _fill_axe(info: HitInfo, victim: Fighter) -> void:
	var charged := _move.charged
	var e := _r8_values(MoveLibrary.AXE, charged, _strike_c)
	info.move_id = MoveLibrary.AIR_ANIM_AXE if _move.air else MoveLibrary.AXE  # &"air_axe" / &"axe_kick" (F)
	info.air = _move.air
	info.charged = charged
	info.charge = _strike_c if charged else 0.0
	info.charge_level = (1 + _steps_passed(_steps_for(MoveLibrary.AXE), _strike_c)) if charged else 0
	info.victim_state = victim.get_react_state()
	info.payoff = false
	info.react = &"spike"
	info.push = 0.0
	info.stun = 0.0
	info.lift_height = 0.0
	info.weight = float(e["weight"])
	info.hitstop = float(e["hitstop"])
	info.pressure = float(e["pressure"]) * Tuning.debug_pressure_mult
	info.counter = false
	info.chain_index = (_chain_count if _chain_alive(TimeDirector.now()) else 0) + 1
	info.combo_index = info.chain_index
	info.set_meta(&"guard_break", charged)
	info.set_meta(&"spike_blast", float(e["blast"]))
	var d := deg_to_rad(SPIKE_DRIFT)
	info.launch_velocity = (info.hit_direction * sin(d) + Vector3.DOWN * cos(d)) \
		* minf(float(e["speed"]), Tuning.LAUNCH_SPEED_MAX)
	info.tier = HitInfo.Tier.LAUNCH
	var vc := victim.combat
	var scale := combo_scale(vc.next_taken_index() if vc != null else 1)
	info.damage = float(e["dmg"]) * scale * _damage_mult()
	info.damage_scale = scale
	if victim.is_fleeing() or Targeting.is_crawling(victim):
		info.damage = maxf(info.damage, victim.hp)
	_sever_on_kill(info, victim)
	info.reaction = HitInfo.reaction_for_tier(info.tier)
	info.energy = _energy_of(info, victim.get_total_mass())

## An air strike (docs/Round 8: Air combo): the tap's damage, weight, hitstop
## and pressure. A kick launches the body away at R8_AIR_KICK_LAUNCH
## (R8_AIR_KICK_ANGLE up, along the hit; heavies x HEAVY_LAUNCH_MULT); a punch
## with the stick pulled back at the press spikes it (Round 7's spike:
## R7_SPIKE_SPEED straight down, R7_SPIKE_DAMAGE, the floor shockwave); any
## other punch keeps it floating (its tap reaction with no push or stun: the
## hang holds it, no re-pop cap). Never a payoff, never charged.
func _fill_air(info: HitInfo, victim: Fighter) -> void:
	var id := _move.id
	var t: Dictionary = MoveLibrary.r8_row(id)["tap"]
	info.air = true
	info.charged = false
	info.victim_state = victim.get_react_state()
	info.payoff = false
	info.weight = float(t["weight"])
	info.hitstop = float(t["hitstop"])
	info.pressure = float(t["pressure"]) * Tuning.debug_pressure_mult
	info.push = 0.0
	info.stun = 0.0
	info.lift_height = 0.0
	info.counter = false
	info.chain_index = (_chain_count if _chain_alive(TimeDirector.now()) else 0) + 1
	info.combo_index = info.chain_index
	info.set_meta(&"guard_break", false)
	info.launch_velocity = Vector3.ZERO
	var dmg := float(t["dmg"])
	if _move.is_kick:
		info.react = &"launch"
		var speed := minf(Tuning.R8_AIR_KICK_LAUNCH * (Tuning.HEAVY_LAUNCH_MULT if victim.is_heavy() else 1.0),
			Tuning.LAUNCH_SPEED_MAX)
		var a := deg_to_rad(Tuning.R8_AIR_KICK_ANGLE)
		info.launch_velocity = (info.hit_direction * cos(a) + Vector3.UP * sin(a)) * speed
		info.tier = HitInfo.Tier.LAUNCH
	elif _air_spike:
		var d := deg_to_rad(SPIKE_DRIFT)
		info.react = &"spike"
		info.launch_velocity = (_camera_forward() * sin(d) + Vector3.DOWN * cos(d)) * Tuning.R7_SPIKE_SPEED
		info.tier = HitInfo.Tier.LAUNCH
		dmg = Tuning.R7_SPIKE_DAMAGE
	else:
		info.react = t["react"]
		info.tier = _tier_named(t["tier"])
	var vc := victim.combat
	var n := vc.next_taken_index() if vc != null else 1
	var scale := combo_scale(n)
	info.damage = dmg * scale * _damage_mult()
	info.damage_scale = scale
	if victim.is_fleeing() or Targeting.is_crawling(victim):
		info.damage = maxf(info.damage, victim.hp)
	_sever_on_kill(info, victim)
	info.reaction = HitInfo.reaction_for_tier(info.tier)
	info.energy = _energy_of(info, victim.get_total_mass())

## A killing launch or spike may take a limb (sever_on_kill_chance).
func _sever_on_kill(info: HitInfo, victim: Fighter) -> void:
	if info.react in [&"launch", &"spike"] and info.damage >= victim.hp and randf() < sever_on_kill_chance:
		var cut := _sever_cut(victim, info)
		if cut != &"":
			info.sever_cut = cut
			info.tier = HitInfo.Tier.SEVER
			info.is_finisher = true

## Round 8: a player hit on a broken-open victim (CombatController.is_broken):
## x R8_BREAK_DAMAGE_MULT damage, x R8_BREAK_PUSH_MULT push and launch speed
## (cap LAUNCH_SPEED_MAX), HitInfo.broken_bonus.
func _apply_break_bonus(info: HitInfo, victim: Fighter) -> void:
	if victim.combat == null or not victim.combat.is_broken():
		return
	info.broken_bonus = true
	info.damage *= Tuning.R8_BREAK_DAMAGE_MULT
	info.push *= Tuning.R8_BREAK_PUSH_MULT
	if info.launch_velocity.length_squared() > 1e-6:
		info.launch_velocity = (info.launch_velocity * Tuning.R8_BREAK_PUSH_MULT).limit_length(Tuning.LAUNCH_SPEED_MAX)
	info.energy = _energy_of(info, victim.get_total_mass())

## The move whose R7 entry this hit uses: a dropping strike hits with its
## button's move (doc: God path), any other move with its own.
func _entry_id() -> StringName:
	return _drop_as if _move.drop and _drop_as != &"" else _move.id

func _entry_of(id: StringName) -> Dictionary:
	var m := MoveLibrary.get_move(id)
	return m.r7_entry() if m != null else _move.r7_entry()

## Sprint strike at v = _p_speed >= SPEED_BONUS_FROM (doc: God path): the
## heavies (Round 8: every charged strike), the front kick, the roundhouse and
## the uppercut launch (returns the launch speed: R7_SPRINT_LAUNCH_BASE +
## R7_SPRINT_LAUNCH_PER_MS (v - 6), cap LAUNCH_SPEED_MAX); punches and the leg
## kick push x (1 + R7_SPRINT_PUSH_PER_MS (v - 6)) and are at least a push
## (returns 0).
func _apply_sprint(info: HitInfo, id: StringName, heavy: bool) -> float:
	var over := _p_speed - Tuning.SPEED_BONUS_FROM
	if heavy or SPRINT_LAUNCHERS.has(id):
		return minf(Tuning.R7_SPRINT_LAUNCH_BASE + Tuning.R7_SPRINT_LAUNCH_PER_MS * over, Tuning.LAUNCH_SPEED_MAX)
	info.push *= 1.0 + Tuning.R7_SPRINT_PUSH_PER_MS * over
	if info.react in [&"snap", &"spin", &"fold", &"buckle", &"flinch"]:
		info.react = &"push"
	return 0.0

## The pursuit hit (Defence's pursuit body; doc: God path). The stick pulled
## back at the press: a spike (HitInfo.react &"spike", flown through
## Fighter.launch), straight down at R7_SPIKE_SPEED (SPIKE_DRIFT degrees toward
## camera forward), its floor impact a shockwave; Defence pursues a spiked body
## no more. Otherwise a relaunch along camera forward at max(the body's
## speed, R7_PURSUIT_RELAUNCH_SPEED, heavies x HEAVY_LAUNCH_MULT; cap
## LAUNCH_SPEED_MAX), R7_PURSUIT_RELAUNCH_ANGLE up. Returns the damage before
## scaling.
func _fill_pursuit(info: HitInfo, victim: Fighter) -> float:
	var cam := _camera_forward()
	info.pursuit = true
	info.payoff = false
	info.react = &"launch"
	info.push = 0.0
	info.stun = 0.0
	info.lift_height = 0.0
	info.hit_direction = cam
	if _pursuit_spike:
		var d := deg_to_rad(SPIKE_DRIFT)
		info.react = &"spike"
		info.launch_velocity = (cam * sin(d) + Vector3.DOWN * cos(d)) * Tuning.R7_SPIKE_SPEED
		info.tier = HitInfo.Tier.LAUNCH
		return Tuning.R7_SPIKE_DAMAGE
	var hm := Tuning.HEAVY_LAUNCH_MULT if victim.is_heavy() else 1.0
	var speed := minf(maxf(victim.get_com_velocity().length(), Tuning.R7_PURSUIT_RELAUNCH_SPEED * hm),
		Tuning.LAUNCH_SPEED_MAX)
	var a := deg_to_rad(Tuning.R7_PURSUIT_RELAUNCH_ANGLE)
	info.launch_velocity = (cam * cos(a) + Vector3.UP * sin(a)) * speed
	info.tier = HitInfo.Tier.LAUNCH
	return Tuning.R7_PURSUIT_DAMAGE

## The stick is pulled back (toward the camera): Fighter.get_input_intent()
## when it exists, else the stick against camera forward.
func _intent_back() -> bool:
	for o: Object in [fighter, fighter.brain]:
		if o != null and o.has_method(&"get_input_intent"):
			return StringName(o.call(&"get_input_intent")) == &"back"
	var stick := _stick_dir()
	return stick.length() >= INTENT_DEADZONE and stick.normalized().dot(_camera_forward()) <= -INTENT_DOT

## A spiked body's floor impact: the shockwave (GameEvents.shockwave; WorldDamage
## and FX listen) and a stagger on every enemy within R7_SPIKE_BLAST_RADIUS
## (Round 9: the axe kick's own "blast" radius).
func _on_body_impact(body: Node3D, pos: Vector3, normal: Vector3, _energy: float, _surface: StringName) -> void:
	if _spiked.is_empty() or body == null or not is_instance_valid(body):
		return
	var key := body.get_instance_id()
	if not _spiked.has(key):
		return
	if TimeDirector.now() - float(_spiked[key][1]) > SPIKE_WATCH:
		_spiked.erase(key)
		return
	if normal.y <= FLOOR_NORMAL_Y:
		return  # a wall on the way down: wait for the floor
	var radius := float(_spiked[key][2])
	_spiked.erase(key)
	GameEvents.shockwave.emit(fighter, pos, radius, 0.0)
	for f in Targeting.opponents_of(fighter):
		if f == body or f.is_down():
			continue
		var to := f.get_ground_position() - pos
		to.y = 0.0
		var d := to.length()
		if d > radius:
			continue
		f.take_hit(_shockwave_hit(f, to / d if d > 0.01 else fighter.get_forward()))

## The spike shockwave's preset stagger (unblockable, no damage).
func _shockwave_hit(victim: Fighter, dir: Vector3) -> HitInfo:
	var info := HitInfo.new()
	info.attacker = fighter
	info.victim = victim
	info.move_id = &"spike_shockwave"
	info.kind = &"shockwave"
	info.tier = HitInfo.Tier.STAGGER
	info.reaction = HitInfo.reaction_for_tier(info.tier)
	info.unblockable = true
	info.hit_direction = Vector3(dir.x, 0.0, dir.z).normalized()
	info.hit_bone = Bones.HIPS
	info.hit_position = victim.get_ground_position() + Vector3.UP * 1.1
	info.hitstop = Power.hitstop_for(info.tier)
	return info

## Enemy moves deal a preset tier: punches and kicks flinch or stagger, the
## heavy's charge and grab-throws knock down. Enemies never launch the player
## or take its limbs.
func _fill_preset(info: HitInfo, victim: Fighter) -> void:
	var m := _move
	var tier := m.preset_tier if m.preset_tier >= 0 else HitInfo.Tier.FLINCH
	if victim.is_player:
		tier = mini(tier, HitInfo.Tier.KNOCKDOWN)
	var vc := victim.combat
	if vc != null and vc.is_lying():
		# A swing at a body on the floor (the free swing at a downed player):
		# damage and a push into the nearest bone; it never knocks it down again.
		tier = HitInfo.Tier.FLINCH
		info.set_meta(&"nudge", 1.0)
	var n := vc.next_taken_index() if vc != null else 1
	var scale := combo_scale(n)
	var dmg: float = Tuning.DMG_ENEMY.get(m.id, m.damage)
	info.tier = tier
	info.reaction = HitInfo.reaction_for_tier(tier)
	info.hitstop = Power.hitstop_for(tier)
	if HitInfo.is_launch_tier(tier):
		info.launch_velocity = Power.launch_velocity(Tuning.TIER_BANDS[2], info.hit_direction,
			victim.get_total_mass(), victim.is_heavy())
	info.damage = dmg * scale * _damage_mult()
	info.damage_scale = scale
	info.combo_index = n
	info.energy = _energy_of(info, victim.get_total_mass())

## HitInfo.energy for old listeners: the launch's kinetic energy, else a
## nominal body speed by tier.
static func _energy_of(info: HitInfo, mass: float) -> float:
	if HitInfo.is_launch_tier(info.tier):
		return 0.5 * mass * info.launch_velocity.length_squared()
	var v: float = NOMINAL_SPEED.get(info.tier, 2.0)
	return 0.5 * mass * v * v

## Which limb a severing launch takes: the hit hurtbox's limb, or for head and
## torso hits the arm nearest the hit point. &"" when gore is off or none is left.
func _sever_cut(victim: Fighter, info: HitInfo) -> StringName:
	if Tuning.gore != Tuning.Gore.DISMEMBER or victim.rig == null or victim.is_player:
		return &""
	if victim.get_lost_limbs().size() >= Fighter.MAX_SEVERS:
		return &""  # no more limbs come off this body
	var cut := Bones.limb_cut_for(info.hit_bone)
	if cut != &"" and not _cut_gone(victim, cut):
		return cut
	var best: StringName = &""
	var best_d := INF
	for c: StringName in [&"arm_l", &"arm_r"]:
		if _cut_gone(victim, c):
			continue
		var d := victim.rig.get_bone_global_position(Bones.CUTS[c]).distance_to(info.hit_position)
		if d < best_d:
			best_d = d
			best = c
	return best

static func _cut_gone(victim: Fighter, cut: StringName) -> bool:
	return victim.rig.is_severed(cut) or victim.rig.is_bone_severed(Bones.CUTS[cut])

# =============================================================================
# Defender side
# =============================================================================

## Defender side of the hit pipeline: invulnerability, guard, tell armor,
## damage, the contact frame, then the reaction. Returns HitInfo.Result.
func receive_hit(info: HitInfo) -> int:
	info.victim = fighter
	last_received = info
	if fighter.is_dead():
		info.result = HitInfo.Result.IGNORED
		return info.result
	_resolve_tier(info)
	match info.kind:
		&"throw":
			return _apply_hit(info)
		&"bowl":
			if fighter.is_invulnerable():
				return _ignored(info)
			return _apply_hit(info)
	if is_vanished():
		info.result = HitInfo.Result.DODGED  # mid-teleport (Defence)
		last_result = info.result
		return info.result
	if fighter.is_invulnerable():
		return _ignored(info)
	if not info.unblockable and _blocks(info):
		return _apply_block(info)
	if info.react != &"" and _armored(info):
		return _apply_armor(info)
	return _apply_hit(info)

## Hits from sources that set neither tier nor power (older callers) get a tier
## from their legacy reaction; power-scored ones from P.
static func _resolve_tier(info: HitInfo) -> void:
	if info.tier != HitInfo.Tier.NONE:
		return
	if info.power > 0.0:
		info.tier = Power.tier_of(info.power)
	else:
		match info.reaction:
			HitInfo.Reaction.FLINCH:
				info.tier = HitInfo.Tier.FLINCH
			HitInfo.Reaction.STAGGER:
				info.tier = HitInfo.Tier.STAGGER
			HitInfo.Reaction.LAUNCH:
				info.tier = HitInfo.Tier.LAUNCH
	if info.hitstop <= 0.0 and info.tier != HitInfo.Tier.NONE:
		info.hitstop = Power.hitstop_for(info.tier)

func _ignored(info: HitInfo) -> int:
	info.result = HitInfo.Result.IGNORED
	last_result = info.result
	return info.result

## Guards (the AI holding Block, archetype blocks) cover strikes from the
## front. Round 7 player strikes: a guard stops tapped punches; heavies, the
## gut punch, the uppercut and every kick break it (the hit lands, the guard
## drops; HitInfo meta "guard_broken"). Round 5 rules for other hits.
func _blocks(info: HitInfo) -> bool:
	if not (info.kind == &"strike" or info.kind == &"projectile"):
		return false
	if is_broken():
		return false  # Round 8: broken open, no guard at all
	# Break-away auto-guard: frontal strikes count as blocked (grabs still work).
	if TimeDirector.now() < _escape_guard_until and _attacker_in_front(info, GUARD_FRONT_DOT) \
			and not fighter.is_down():
		info.set_meta(&"escape_guard", true)
		return true
	if is_dazed() or is_stumbling() or fighter.is_reacting():
		return false  # no guard off balance
	var front := _attacker_in_front(info, GUARD_FRONT_DOT)
	var guarding := is_blocking() and front
	# Legacy archetypes: the Shield blocks from the front, the Brawler blocks jabs, when idle.
	var passive := not guarding and front and _phase == Phase.IDLE and not fighter.is_down() \
		and not _held() and not is_hit_stunned() and fighter.get_state() == RagdollController.State.ANIMATED \
		and (bool(fighter.config.get("front_block", false)) or bool(fighter.config.get("blocks_jabs", false)))
	if info.react != &"":
		if not (guarding or passive):
			return false
		if bool(info.get_meta(&"guard_break", false)):
			info.set_meta(&"guard_broken", true)
			_block_held = false  # the guard is broken: the AI presses Block again to re-guard
			return false
		return true
	if HitInfo.is_launch_tier(info.tier):
		return false
	if guarding:
		return info.level != HitInfo.Level.LOW
	if passive and info.level != HitInfo.Level.LOW:
		return bool(fighter.config.get("front_block", false))
	return false

func _attacker_in_front(info: HitInfo, min_dot: float) -> bool:
	var to_attacker := -info.hit_direction
	var att := info.attacker as Fighter
	if att != null and is_instance_valid(att) and info.kind != &"projectile":
		to_attacker = att.get_ground_position() - fighter.get_ground_position()
	to_attacker.y = 0.0
	if to_attacker.length_squared() < 1e-4:
		return true
	return fighter.get_forward().dot(to_attacker.normalized()) > min_dot

## Tell armor of the move in progress (0 when not in startup/active): the
## move's own, + the archetype's "armor_bonus" (legacy: every move, the brute),
## and at least 1 on the moves the archetype lists in "armor_moves" (Round 8:
## the Duelist's big swing; his other wind-ups are interrupted by taps).
func get_armor_level() -> int:
	if _move == null or not (_phase == Phase.STARTUP or _phase == Phase.ACTIVE):
		return 0
	if fighter.is_player:
		return _move.armor
	var a := _move.armor + int(fighter.config.get("armor_bonus", 0))
	var listed: Variant = fighter.config.get("armor_moves", [])
	if listed is Array and (listed as Array).has(_move.id):
		a = maxi(a, 1)
	return a

## Round 7 tell armor: an enemy in an armored tell (the heavy archetype, a
## move's armor) takes tapped punches with damage and a small snap and keeps
## attacking; heavies, specials and kicks (guard_break) break the armor.
func _armored(info: HitInfo) -> bool:
	if bool(info.get_meta(&"guard_break", false)) or fighter.is_player:
		return false
	if not (_phase == Phase.STARTUP or _phase == Phase.ACTIVE):
		return false
	return get_armor_level() >= 1 or bool(fighter.config.get("ignore_flinch", false))

## Guard (the AI's): Tuning.GUARD_DAMAGE_MULT of the damage; a stagger-tier or
## heavier hit pushes the guard back Tuning.GUARD_PUSH m.
func _apply_block(info: HitInfo) -> int:
	_cancel_charge(&"hit")
	info.result = HitInfo.Result.BLOCKED
	last_result = info.result
	var m := MoveLibrary.get_move(info.move_id)
	var stun := Tuning.frames(m.blockstun if m else 10.0)
	var heavy_hit := info.tier >= HitInfo.Tier.STAGGER
	info.set_meta(&"guarded_tier", info.tier)
	var chip := info.damage * Tuning.GUARD_DAMAGE_MULT
	info.damage = chip
	info.tier = HitInfo.Tier.NONE
	info.reaction = HitInfo.Reaction.NONE
	info.launch_velocity = Vector3.ZERO
	var push := Tuning.GUARD_PUSH if heavy_hit else 0.0
	var auto_guard: bool = info.get_meta(&"escape_guard", false)
	if auto_guard:
		push = 0.0  # no blockstun or slide: the break-away keeps the fighter free
	elif _phase == Phase.IDLE:
		# A real guard (or an idle archetype block): blockstun, push-back, block-hit pose.
		var guard := is_blocking()
		_stun_left = maxf(_stun_left, stun)
		_stun_kind = Stun.BLOCK
		_guard_stun = guard
		var d := Vector3(info.hit_direction.x, 0.0, info.hit_direction.z)
		if push > 0.0 and d.length_squared() > 1e-4:
			_slide_velocity = d.normalized() * push / BLOCK_PUSH_TIME
			_slide_left = BLOCK_PUSH_TIME
		_slide_plant = true
		if fighter.animator:
			fighter.animator.play_move(&"block_hit", Tuning.frames(2), Tuning.frames(2), maxf(stun - Tuning.frames(4), 0.05))
		blocking = false  # re-held when blockstun ends
	_freeze_pair(info.attacker as Fighter, Power.hitstop_for(HitInfo.Tier.FLINCH), true)
	_add_pressure(info, true)  # Round 8: blocked hits fill pressure too (guards break this way)
	fighter.apply_damage(chip, &"block", info)
	GameEvents.hit_blocked.emit(info)
	hit_received.emit(info)
	return info.result

## Contact-frame hitstop on this fighter (the victim) and the attacker only;
## the player's own freeze never passes Tuning.R7_PLAYER_HITSTOP_MAX.
func _freeze_pair(att: Fighter, duration: float, victim_too: bool) -> void:
	if duration <= 0.0:
		return
	var now := TimeDirector.now()
	if victim_too:
		var hv := minf(duration, Tuning.R7_PLAYER_HITSTOP_MAX) if fighter.is_player else duration
		TimeDirector.hitstop([fighter], hv)
		freeze_until(now + hv)
	if att != null and is_instance_valid(att) and att != fighter:
		var ha := minf(duration, Tuning.R7_PLAYER_HITSTOP_MAX) if att.is_player else duration
		TimeDirector.hitstop([att], ha)
		if att.combat != null:
			att.combat.freeze_until(now + ha)

func _apply_hit(info: HitInfo) -> int:
	_cancel_charge(&"hit")  # Round 8: a hit on the charging player cancels the charge
	info.result = HitInfo.Result.HIT
	last_result = info.result
	_end_chain()  # this fighter was hit: its own chain drops
	if info.react == &"ground":
		return _apply_ground_hit(info)
	if info.react != &"":
		return _apply_r7_hit(info)
	var att := info.attacker as Fighter
	var tier := info.tier
	if HitInfo.is_launch_tier(tier) and info.launch_velocity.length_squared() < 1e-4 \
			and not info.has_meta(&"nudge"):
		# A preset launch with no velocity: the band's lowest launch.
		var bp: float = Tuning.TIER_BANDS[clampi(tier - HitInfo.Tier.LAUNCH + 2, 2, 4)]
		info.launch_velocity = Power.launch_velocity(bp, info.hit_direction, fighter.get_total_mass(), fighter.is_heavy())
	# Heavies (ignore_flinch) take the damage but only a stagger or more
	# interrupts them; tell armor (the Duelist) too.
	if info.kind != &"throw" and info.kind != &"bowl" and not info.has_meta(&"nudge"):
		var light := tier == HitInfo.Tier.FLINCH or tier == HitInfo.Tier.STUMBLE
		if light and bool(fighter.config.get("ignore_flinch", false)):
			return _apply_armor(info)
		var armor := get_armor_level()
		if (light and armor >= 1) or (tier == HitInfo.Tier.STAGGER and armor >= 2):
			return _apply_armor(info)
	var lethal := info.damage >= fighter.hp
	# Anti-infinite (Round 5 rules for these hits): stun decay, break-away.
	var n := next_taken_index()
	var decay := stun_decay(n)
	var escape := not lethal and _breakaway_due(info, n, decay)
	_register_taken()
	info.set_meta(&"decay", decay)
	if escape:
		_break_away(info, att)
	# Contact frame: the reaction now, then the freeze holds the body in its
	# contact pose (RagdollController) and releases it with the cached
	# animation velocities + the impulse. A lethal hit only keeps its launch.
	if not escape and info.tier != HitInfo.Tier.NONE \
			and (not lethal or HitInfo.is_launch_tier(info.tier)):
		_react(info)
	# A hit that does nothing to a body on the floor freezes only the attacker,
	# so the body's grounding and get-up timers keep running.
	var victim_freezes := not (info.has_meta(&"nudge") and is_lying())
	if victim_freezes:
		_fighter_call(&"set_hitstop_jitter", [_jitter_for(info.tier)])
	_freeze_pair(att, info.hitstop, victim_freezes)
	fighter.apply_damage(info.damage, info.move_id, info)
	GameEvents.hit_landed.emit(info)
	hit_received.emit(info)
	return info.result

## A Round 7 player strike lands (doc: Hit feel): the anti-infinite (stun decay
## from R7_COMBO_STUN_DECAY_FROM, the break-away at R7_COMBO_ESCAPE_HITS), the
## reaction on the contact frame, hitstop, damage, hit_landed.
func _apply_r7_hit(info: HitInfo) -> int:
	var att := info.attacker as Fighter
	var lethal := info.damage >= fighter.hp
	var n := next_taken_index()
	var decay := r7_stun_decay(n)
	var downs := info.react in [&"knockdown", &"launch", &"spike", &"sweep"]
	var escape := not lethal and not downs and n >= Tuning.R7_COMBO_ESCAPE_HITS and not fighter.is_down()
	_register_taken()
	info.stun *= decay
	info.set_meta(&"decay", decay)
	if escape:
		_break_away(info, att)
		info.stun = 0.0
	elif not lethal or info.react == &"launch" or info.react == &"spike":
		_react_r7(info)
	if not lethal:
		_add_pressure(info, false)  # Round 8 (may break it open: the daze after this reaction)
	_fighter_call(&"set_hitstop_jitter", [_jitter_for(info.tier)])
	_freeze_pair(att, info.hitstop, true)
	fighter.apply_damage(info.damage, info.move_id, info)
	GameEvents.hit_landed.emit(info)
	hit_received.emit(info)
	return info.result

## Round 9: a player strike's limb touched this lying body (react &"ground"):
## the shove (meta "ground_dv") on every simulating bone of the ragdoll, the
## first such hit of a knockdown delays the get-up GROUND_HIT_HOLD, pressure,
## damage, hit_landed. Only the attacker freezes (the body's timers run on).
func _apply_ground_hit(info: HitInfo) -> int:
	_register_taken()
	cancel()
	drop_debris()
	var rd := fighter.ragdoll
	if rd != null:
		rd.add_velocity(info.get_meta(&"ground_dv", Vector3.ZERO))
		if not _getup_extended and fighter.is_down():
			_getup_extended = true
			rd.delay_getup(GROUND_HIT_HOLD)
	if info.damage < fighter.hp:
		_add_pressure(info, false)
	_freeze_pair(info.attacker as Fighter, info.hitstop, false)
	fighter.apply_damage(info.damage, info.move_id, info)
	GameEvents.hit_landed.emit(info)
	hit_received.emit(info)
	return info.result

## The Round 7 reaction: Fighter.react for the on-feet states (snap, spin,
## fold, lift, buckle, push, repop), Fighter.knockdown, or a launch at the
## payoff's velocity (a launch sets the flight). Round 9: meta "push_dir" (the
## charged hook: along the hit), "hop" (m/s up on a knockdown) and
## "spin_rate" (Fighter.add_spin right after the knockdown or launch).
func _react_r7(info: HitInfo) -> void:
	if fighter.is_dead():
		if info.react == &"launch" or info.react == &"spike":
			_launch_body(info)
			_add_spin(info)
		return
	cancel()
	drop_debris()
	var pdir: Vector3 = info.get_meta(&"push_dir", info.hit_direction)
	match info.react:
		&"knockdown":
			if _roundhouse_stagger(info):
				return
			fighter.knockdown(pdir, info.hit_bone)
			var hop := float(info.get_meta(&"hop", 0.0))
			if hop > 0.0 and fighter.ragdoll != null:
				fighter.ragdoll.add_velocity(Vector3.UP * hop)  # the feet leave the floor: the spin carries
			_add_spin(info)
			_set_getup(Tuning.REACT_KNOCKDOWN["ground"])
		&"launch", &"spike":
			_launch_body(info)
			_add_spin(info)
			_set_getup(Tuning.REACT_LAUNCH["ground"])
		&"sweep":
			# Round 8: the legs taken out (H's sweep), else a knockdown.
			if _react_kind_ok(fighter, &"sweep"):
				fighter.react(&"sweep", pdir, info.push, info.stun, info)
			else:
				fighter.knockdown(pdir, info.hit_bone)
			_set_getup(Tuning.REACT_KNOCKDOWN["ground"])
		_:
			var sdir: Vector3 = info.get_meta(&"push_dir", info.get_meta(&"strike_dir", info.hit_direction))
			var flat := Vector3(sdir.x, 0.0, sdir.z)
			flat = flat.normalized() if flat.length_squared() > 1e-4 else info.hit_direction
			var kind := info.react
			if not _react_kind_ok(fighter, kind):
				kind = R8_REACT_FALLBACK.get(kind, kind)  # flinch -> snap until H's react knows it
			fighter.react(kind, flat, info.push, info.stun, info)

## A tapped roundhouse on a guard that isn't broken (Tuning.ROUNDHOUSE_STAGGER):
## a push on its feet with meta "stagger" (Fighter.react: the upper body goes
## partly ragdoll, the stagger-back clip with F5) instead of the knockdown.
## A payoff (on a fold / buckle) still knocks down. true when it staggered.
func _roundhouse_stagger(info: HitInfo) -> bool:
	if info.move_id != &"roundhouse" or info.charged or info.payoff or is_broken() \
			or fighter.is_lifted() or fighter.is_held():
		return false
	var sdir: Vector3 = info.get_meta(&"push_dir", info.get_meta(&"strike_dir", info.hit_direction))
	var flat := Vector3(sdir.x, 0.0, sdir.z)
	flat = flat.normalized() if flat.length_squared() > 1e-4 else info.hit_direction
	# The hit reports what happened (hit_landed listeners: HUD, FX, the overlay).
	info.react = &"push"
	info.tier = REACT_TIER[&"push"]
	info.stun = float(Tuning.ROUNDHOUSE_STAGGER["stun"]) * (Tuning.R7_HEAVY_STUN_MULT if fighter.is_heavy() else 1.0) \
		* float(info.get_meta(&"decay", 1.0))
	info.set_meta(&"stagger", true)
	fighter.react(&"push", flat, info.push, info.stun, info)
	return true

## Round 9: the charged hook's spin (meta "spin_rate", rad/s) on the body
## just knocked down or launched (agent H's Fighter.add_spin).
func _add_spin(info: HitInfo) -> void:
	var rate := float(info.get_meta(&"spin_rate", 0.0))
	if rate != 0.0:
		_fighter_call(&"add_spin", [rate])

## Mesh jitter for a tier (Tuning.HITSTOP_JITTER_RANGE, flinch to sever).
static func _jitter_for(tier: int) -> float:
	var r := Tuning.HITSTOP_JITTER_RANGE
	var k := clampf(float(tier - HitInfo.Tier.FLINCH) / float(HitInfo.Tier.SEVER - HitInfo.Tier.FLINCH), 0.0, 1.0)
	return lerpf(r.x, r.y, k)

## Round 5 reaction by tier (enemy hits on the player, thrown bodies, props):
## flinch the hit chain, stumble the hit leg, stagger the upper body, knock
## down, or launch. Act-again times from Tuning.REACT_*.
func _react(info: HitInfo) -> void:
	if fighter == null or not is_instance_valid(fighter):
		return
	var tier := info.tier
	var dir3: Vector3 = info.get_meta(&"strike_dir", info.hit_direction)
	var flat := info.hit_direction
	var decay: float = info.get_meta(&"decay", 1.0)
	if fighter.is_dead():
		if HitInfo.is_launch_tier(tier):
			_launch_body(info)
		return
	if info.has_meta(&"nudge"):
		fighter.flinch(dir3, info.hit_bone, float(info.get_meta(&"nudge")))
		return
	match tier:
		HitInfo.Tier.FLINCH:
			fighter.flinch(dir3, info.hit_bone, 1.0)
			_set_hit_stun(float(Tuning.REACT_FLINCH["act"]) * decay)
		HitInfo.Tier.STUMBLE:
			var stun := float(Tuning.REACT_STUMBLE["act"]) * decay
			fighter.stumble(flat, _leg_bone_for(info))
			_set_hit_stun(stun)
			_stun_kind = Stun.STUMBLE
			GameEvents.stumbled.emit(fighter, stun)
		HitInfo.Tier.STAGGER:
			fighter.stagger(flat, STAGGER_STRENGTH)
			_set_hit_stun(float(Tuning.REACT_STAGGER["act"]) * decay)
		HitInfo.Tier.KNOCKDOWN:
			fighter.knockdown(flat, info.hit_bone)
			_set_getup(Tuning.REACT_KNOCKDOWN["ground"])
		HitInfo.Tier.LAUNCH, HitInfo.Tier.HARD_LAUNCH, HitInfo.Tier.SEVER:
			_launch_body(info)
			_set_getup(Tuning.REACT_LAUNCH["ground"])

## Launch the body so it flies at info.launch_velocity: a launch sets the
## flight (the body's current velocity is replaced: a flying body's, the
## capsule's arc in a lift, the capsule's run on its feet; an active ragdoll's
## bones jitter too much to read standing). A severing launch takes its limb
## first, in the same frame, so the loose limb flies off with the launch.
func _launch_body(info: HitInfo) -> void:
	var cur := fighter.velocity
	if fighter.is_down() or fighter.is_dead():
		cur = fighter.get_com_velocity()
	elif not fighter.is_lifted():
		cur.y = 0.0
	var change := info.launch_velocity - cur
	if info.sever_cut != &"":
		fighter.sever_limb(info.sever_cut)
	fighter.launch(change, info.hit_position, info.hit_bone)

func _set_getup(ground: Vector2) -> void:
	if fighter.ragdoll == null:
		return
	var t := Tuning.PLAYER_GETUP_AFTER if fighter.is_player else randf_range(ground.x, ground.y)
	fighter.ragdoll.set_getup_after(t)

## The leg a stumble buckles: the hit leg, else the lower leg nearest the hit.
func _leg_bone_for(info: HitInfo) -> StringName:
	match info.hit_bone:
		Bones.L_UPPER_LEG, Bones.L_LOWER_LEG, Bones.L_FOOT:
			return Bones.L_LOWER_LEG
		Bones.R_UPPER_LEG, Bones.R_LOWER_LEG, Bones.R_FOOT:
			return Bones.R_LOWER_LEG
	if fighter.rig == null:
		return Bones.L_LOWER_LEG
	var dl := fighter.rig.get_bone_global_position(Bones.L_LOWER_LEG).distance_to(info.hit_position)
	var dr := fighter.rig.get_bone_global_position(Bones.R_LOWER_LEG).distance_to(info.hit_position)
	return Bones.L_LOWER_LEG if dl <= dr else Bones.R_LOWER_LEG

## Damage, no interruption: Round 7 tell armor (a tapped punch on an armored
## tell: a small snap, it keeps attacking), Round 5 heavies under a stagger
## (ignore_flinch) and tell armor. The hit still lands (hit_landed: flash,
## sound) and the attacker feels it.
func _apply_armor(info: HitInfo) -> int:
	_cancel_charge(&"hit")
	info.result = HitInfo.Result.HIT
	last_result = info.result
	_register_taken()
	info.set_meta(&"armored", true)
	info.reaction = HitInfo.Reaction.NONE
	info.launch_velocity = Vector3.ZERO
	var stop := ARMOR_HITSTOP
	if info.react != &"":
		info.react = &"snap"
		info.payoff = false
		info.push = 0.0
		info.stun = 0.0
		info.lift_height = 0.0
		info.tier = HitInfo.Tier.FLINCH
		stop = info.hitstop
		var sdir: Vector3 = info.get_meta(&"strike_dir", info.hit_direction)
		if fighter.ragdoll != null and not fighter.is_body_simulating():
			fighter.ragdoll.flinch(sdir, info.hit_bone, ARMOR_SNAP)
	_freeze_pair(info.attacker as Fighter, stop, true)
	if info.damage < fighter.hp:
		_add_pressure(info, false)  # Round 8: armored hits fill pressure (a break cancels the wind-up)
	fighter.apply_damage(info.damage, info.move_id, info)
	GameEvents.hit_landed.emit(info)
	GameEvents.armor_absorbed.emit(info)
	hit_received.emit(info)
	return info.result

# --- Anti-infinite (victim side) ---------------------------------------------------
## Hits this fighter has taken in the current combo (from anyone, no COMBO_DROP gap).
func hits_taken() -> int:
	return _taken if TimeDirector.now() - _taken_last <= Tuning.COMBO_DROP else 0

## 1-based number of the next hit this fighter takes (scales its damage).
func next_taken_index() -> int:
	return hits_taken() + 1

func _register_taken() -> void:
	var now := TimeDirector.now()
	if now - _taken_last > Tuning.COMBO_DROP:
		_taken = 0
		_taken_stun = 0.0
	_taken += 1
	_taken_last = now

## Round 5 stun multiplier of the n-th hit taken (Tuning.COMBO_STUN_*): enemy hits on the player.
static func stun_decay(n: int) -> float:
	if n < Tuning.COMBO_STUN_DECAY_FROM:
		return 1.0
	return maxf(Tuning.COMBO_STUN_MIN,
		1.0 - Tuning.COMBO_STUN_DECAY * float(n - Tuning.COMBO_STUN_DECAY_FROM + 1))

## Round 7 stun multiplier of the n-th hit taken (Tuning.R7_COMBO_STUN_*): player strikes.
static func r7_stun_decay(n: int) -> float:
	if n < Tuning.R7_COMBO_STUN_DECAY_FROM:
		return 1.0
	return maxf(Tuning.R7_COMBO_STUN_MIN,
		1.0 - Tuning.R7_COMBO_STUN_DECAY * float(n - Tuning.R7_COMBO_STUN_DECAY_FROM + 1))

## Act-again time after a flinch, stumble or stagger: set (not extended) and
## summed for the break-away.
func _set_hit_stun(t: float) -> void:
	_stun_left = t
	_stun_kind = Stun.HIT
	_taken_stun += t

## Act-again time of a tier before decay (0 for tiers that leave no stun).
static func stun_of_tier(tier: int) -> float:
	match tier:
		HitInfo.Tier.FLINCH:
			return float(Tuning.REACT_FLINCH["act"])
		HitInfo.Tier.STUMBLE:
			return float(Tuning.REACT_STUMBLE["act"])
		HitInfo.Tier.STAGGER:
			return float(Tuning.REACT_STAGGER["act"])
	return 0.0

## Round 5 (enemy hits): the hit that would be number Tuning.COMBO_ESCAPE_HITS,
## or that would push the combo's stun past Tuning.COMBO_ESCAPE_STUN, breaks
## the fighter away. A knockdown or launch ends a loop by itself.
func _breakaway_due(info: HitInfo, n: int, decay: float) -> bool:
	if info.tier >= HitInfo.Tier.KNOCKDOWN or info.has_meta(&"nudge"):
		return false
	if not (info.kind == &"strike" or info.kind == &"projectile") or fighter.is_down():
		return false
	if n >= Tuning.COMBO_ESCAPE_HITS:
		return true
	var stun := stun_of_tier(info.tier) * decay
	return stun > 0.0 and _taken_stun + stun >= Tuning.COMBO_ESCAPE_STUN

## Break-away: no stun from this hit, a short auto-guard, the two pushed apart
## (mostly the victim), the count reset, combo_escaped emitted.
func _break_away(info: HitInfo, att: Fighter) -> void:
	var now := TimeDirector.now()
	_taken = 0
	_taken_stun = 0.0
	_stun_left = 0.0
	_stun_kind = Stun.NONE
	_escape_guard_until = now + Tuning.COMBO_ESCAPE_GUARD
	var st := fighter.get_state()
	if (st == RagdollController.State.FLINCH or st == RagdollController.State.STAGGER) and fighter.ragdoll:
		fighter.ragdoll.force_recover()  # regain balance at once
	if fighter.animator and fighter.get_state() == RagdollController.State.ANIMATED and _phase == Phase.IDLE:
		fighter.animator.release_pose()
	var dir := Vector3(info.hit_direction.x, 0.0, info.hit_direction.z)
	if att != null and is_instance_valid(att):
		var to := fighter.get_ground_position() - att.get_ground_position()
		to.y = 0.0
		if to.length_squared() > 1e-4:
			dir = to
	dir = dir.normalized() if dir.length_squared() > 1e-4 else -fighter.get_forward()
	var push := Tuning.COMBO_ESCAPE_PUSH
	_fighter_call(&"knockback", [dir * push * ESCAPE_VICTIM_SHARE / ESCAPE_PUSH_TIME, ESCAPE_PUSH_TIME])
	if att != null and is_instance_valid(att) and att.has_method(&"knockback") and not att.is_down():
		att.knockback(-dir * push * (1.0 - ESCAPE_VICTIM_SHARE) / ESCAPE_PUSH_TIME, ESCAPE_PUSH_TIME)
	info.set_meta(&"escaped", true)
	info.tier = mini(info.tier, HitInfo.Tier.FLINCH)  # the hit lands; the stun does not
	info.reaction = HitInfo.Reaction.NONE
	GameEvents.combo_escaped.emit(fighter, att)

## Lying on the floor or getting up from it (grounded, getting up, or a
## launched body that has come to rest low).
func is_lying() -> bool:
	var st := fighter.get_state()
	if st == RagdollController.State.GROUNDED or st == RagdollController.State.GETUP:
		return true
	if st != RagdollController.State.LAUNCHED:
		return false
	var h := fighter.get_center_of_mass().y - fighter.get_ground_position().y
	return h < LYING_HEIGHT and fighter.get_com_velocity().length() < LYING_SPEED

## Off balance for `duration`: cannot attack or block (grabs always connect).
func apply_stumble(duration: float) -> void:
	if fighter.is_dead() or fighter.is_down():
		return
	cancel()
	_stun_left = maxf(_stun_left, duration)
	_stun_kind = Stun.STUMBLE
	if fighter.animator:
		fighter.animator.hold_pose(_hold_or(&"stumble", &"stagger"))
	GameEvents.stumbled.emit(fighter, duration)

## Hunched, no actions for `duration` (Upgrade 2 headbutt while holding).
func apply_daze(duration: float) -> void:
	if fighter.is_dead() or fighter.is_down():
		return
	cancel()
	_block_held = false
	_stun_left = maxf(_stun_left, duration)
	_stun_kind = Stun.DAZE
	if fighter.animator:
		fighter.animator.hold_pose(_hold_or(&"dazed", &"stagger"))
	GameEvents.dazed.emit(fighter, duration)

static func _hold_or(id: StringName, fallback: StringName) -> StringName:
	return id if PoseLibrary.HOLDS.has(id) or PoseLibrary.POSES.has(id) else fallback

## Fighter helpers that live in agent H's fighter.gd; skipped if renamed.
func _fighter_call(method: StringName, args: Array) -> void:
	if fighter.has_method(method):
		fighter.callv(method, args)

## Per tick: the victim's combo count expires after Tuning.COMBO_DROP; back on
## its feet, the next knockdown's get-up may be delayed again (Round 9).
func _tick_victim(now: float) -> void:
	if _taken > 0 and now - _taken_last > Tuning.COMBO_DROP:
		_taken = 0
		_taken_stun = 0.0
	if _getup_extended and not fighter.is_down():
		_getup_extended = false

## Damage multiplier of the n-th hit of a combo (1-based).
static func combo_scale(n: int) -> float:
	if n <= Tuning.COMBO_FULL_HITS:
		return 1.0
	return maxf(1.0 - Tuning.COMBO_SCALE_STEP * float(n - Tuning.COMBO_FULL_HITS), Tuning.COMBO_SCALE_MIN)

func is_dazed() -> bool:
	return _stun_left > 0.0 and _stun_kind == Stun.DAZE

func is_stumbling() -> bool:
	return _stun_left > 0.0 and _stun_kind == Stun.STUMBLE

# =============================================================================
# The Duelist's teleport counter (AI) and the fallback dash
# =============================================================================

## AI teleport counter (the Duelist; free since the amendment removed the
## Focus meter: C paces it): teleports behind `target` (the first free spot of Tuning.TELEPORT_SPOTS),
## shows a blue tell (attack_tell kind &"counter") for `tell_time`, then a
## back_kick (on the player: a knockdown; uncounterable, dodge it). False if it
## cannot happen.
func start_counter(target: Fighter, tell_time: float) -> bool:
	if fighter == null or fighter.is_dead() or fighter.is_down() or _held() or _holding_body():
		return false
	if not _alive(target) or target.is_down() or (Tuning.R9_BROKEN_STUN and is_broken()):
		return false
	if not (_phase == Phase.IDLE or _phase == Phase.RECOVERY) or is_hit_stunned() or fighter.is_reacting():
		return false
	var spot := _find_counter_spot(target)
	if spot == Vector3.INF:
		return false
	_teleport_invuln_until = TimeDirector.now() + AI_COUNTER_INVULN
	_teleport_behind(target, spot)
	var m := MoveLibrary.get_move(&"back_kick")
	var startup := maxf(tell_time, Tuning.frames(Tuning.ENEMY_STARTUP_MIN))
	GameEvents.attack_tell.emit(fighter, m.tell_kind, startup)
	_press_action = -1
	_hold_pending = false
	_cur_string = -1
	_setup_move(m)
	_target = target
	_locked_target = target
	_seq_id = m.id
	attack_started.emit(m.id)
	_enter_startup(startup)
	_update_window()
	return true

func _teleport_behind(target: Fighter, spot: Vector3) -> void:
	cancel()
	fighter.teleport_to(spot, target.get_ground_position() - spot)
	if fighter.rig:
		CombatFX.puff(fighter.get_aim_point())
	if GameEvents.has_signal(&"teleport_counter"):
		GameEvents.emit_signal(&"teleport_counter", fighter, target)

func _find_counter_spot(target: Fighter) -> Vector3:
	var tp := target.get_ground_position()
	var tf := target.get_forward()
	var right := tf.cross(Vector3.UP).normalized()
	for sp: Vector2 in Tuning.TELEPORT_SPOTS:
		var c := tp - tf * sp.y + right * sp.x
		if _spot_clear(c):
			return c
	return Vector3.INF

## Capsule-sized shape cast at a floor point: clear of walls and capsules, with floor below.
func _spot_clear(p: Vector3) -> bool:
	var space := fighter.get_world_3d().direct_space_state
	var shape := fighter.capsule.shape as CapsuleShape3D if fighter.capsule else null
	var cap := CapsuleShape3D.new()
	cap.radius = shape.radius if shape else 0.3
	cap.height = (shape.height if shape else 1.8) - 0.1
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.transform = Transform3D(Basis(), p + Vector3.UP * (cap.height * 0.5 + 0.08))
	q.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE | Layers.CAPSULE
	q.exclude = [fighter.get_rid()]
	if not space.intersect_shape(q, 1).is_empty():
		return false
	var ray := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.5, p + Vector3.DOWN * 1.0,
		Layers.WORLD | Layers.DESTRUCTIBLE)
	return not space.intersect_ray(ray).is_empty()

## The fallback dash for a fighter without Traversal (no enemy needs more):
## a short burst along its move input when it is free to act.
func _on_dash_pressed(now: float) -> void:
	if now < _dash_cooldown_until or not _can_start():
		return
	var dir := Vector3(fighter.move_input.x, 0.0, fighter.move_input.z)
	if dir.length() < 0.2:
		dir = fighter.get_forward()
	_dash_velocity = dir.normalized() * Tuning.DASH_SPEED
	_dash_left = Tuning.DASH_TIME
	_dash_cooldown_until = now + Tuning.DASH_TIME + Tuning.DASH_COOLDOWN

# =============================================================================
# Enemy grabs (the player's grabs, holds and throws are Carry's, agent G)
# =============================================================================

## Active frames of an enemy grab move (e_grab, e_grab_slam): the first fighter
## in front within reach that Carry lets connect is held (Carry runs the hold,
## the break window and the throw or slam). An invulnerable target (dodge) was
## skipped on the first active frame.
func _detect_grab() -> void:
	if not _move.enemy:
		return
	var reach := _move.reach * fighter.get_height_scale()
	var fwd := fighter.get_forward()
	var best: Fighter = null
	var best_d := INF
	for opp in Targeting.opponents_of(fighter):
		if _registry.has(opp.get_instance_id()) or opp.carry == null or opp.is_down():
			continue
		var to := opp.get_ground_position() - fighter.get_ground_position()
		to.y = 0.0
		var d := to.length()
		if d > reach or (d > 0.05 and fwd.dot(to / d) < GRAB_CONE_DOT):
			continue
		if d < best_d:
			best_d = d
			best = opp
	if best == null:
		return
	if best.carry.is_enabled() and best.carry.connect_enemy_grab(best, _move.id):
		_registry[best.get_instance_id()] = true
		_hit_any = true

# =============================================================================
# Projectile (Thrower)
# =============================================================================

func _spawn_projectile() -> void:
	# The opponent the thrower faces (the AI faces the player), else the player.
	var target := Targeting.pick_target(fighter, fighter.get_forward(), 25.0)
	if target == null:
		var p := Targeting.player(fighter.get_tree())
		if p != null and p.team != fighter.team and not p.is_dead():
			target = p
	var hs := fighter.get_height_scale()
	var start := fighter.global_position + Vector3.UP * 1.7 * hs + fighter.get_forward() * 0.45
	if _rig_ready():
		var hand := fighter.rig.get_bone_global_position(&"RightHand")
		if hand.distance_to(fighter.global_position) < 3.0:
			start = hand + Vector3.UP * 0.1 + fighter.get_forward() * 0.25
	var aim := target.get_aim_point() - Vector3.UP * 0.25 if target else start + fighter.get_forward() * 8.0
	var dmg := _move.damage * _damage_mult()
	if _carried != null and is_instance_valid(_carried):
		var body := _carried
		_carried = null
		# Leave the hand at a point clear of the thrower and the walls, with no
		# leftover velocity, before collisions come back on (launch_body).
		var from := _clear_launch_point(body)
		body.reparent(fighter.get_parent(), true)
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		body.global_position = from
		body.reset_physics_interpolation()
		ThrownChunk.launch_body(body, ThrownChunk.ballistic_velocity(from, aim, PROJECTILE_SPEED,
			body.gravity_scale), fighter, dmg)
		return
	var chunk := ThrownChunk.new()
	chunk.setup(fighter, dmg)
	var parent := fighter.get_parent()
	parent.add_child(chunk)
	chunk.global_position = start
	chunk.reset_physics_interpolation()
	chunk.launch_at(aim, PROJECTILE_SPEED)

## Release point for a carried chunk: in front of the thrower's chest, far
## enough out that the chunk does not overlap the thrower, and not inside a
## wall, floor or other body (else the solver would fling it out).
func _clear_launch_point(body: RigidBody3D) -> Vector3:
	var r := ProjectileProbe.body_radius(body)
	var hs := fighter.get_height_scale()
	var fwd := fighter.get_forward()
	var cap_r := (fighter.capsule.shape as CapsuleShape3D).radius if fighter.capsule else 0.3
	var out := cap_r + r + 0.12
	var base := fighter.global_position
	var shape := SphereShape3D.new()
	shape.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE | Layers.DEBRIS | Layers.CAPSULE | Layers.RAGDOLL
	var ex: Array[RID] = [fighter.get_rid(), body.get_rid()]
	if fighter.rig:
		for pb in fighter.rig.get_physical_bones():
			ex.append(pb.get_rid())
	q.exclude = ex
	var space := fighter.get_world_3d().direct_space_state
	for c: Vector3 in [base + Vector3.UP * 1.5 * hs + fwd * out, base + Vector3.UP * 1.9 * hs + fwd * out,
			base + Vector3.UP * (2.0 * hs + r) + fwd * 0.1]:
		q.transform = Transform3D(Basis(), c)
		if space.intersect_shape(q, 1).is_empty():
			return c
	return base + Vector3.UP * (2.0 * hs + r + 0.1)

## Thrower: take a chunk out of DebrisManager into the right hand. The next
## e_throw_debris throws this chunk instead of spawning a box.
func pick_up_debris(body: RigidBody3D) -> bool:
	if body == null or not is_instance_valid(body) or not body.is_inside_tree():
		return false
	if fighter.is_dead() or fighter.is_down() or _held() or _holding_body():
		return false
	if _carried != null and is_instance_valid(_carried):
		return false
	if _phase != Phase.IDLE and not (_move != null and _move.id == &"e_throw_debris" and _phase == Phase.STARTUP):
		return false
	DebrisManager.release(body)
	for c in body.get_children():
		if c is ProjectileProbe:
			(c as ProjectileProbe).live = false
			c.queue_free()
	var hand: Node3D = fighter.rig.get_attachment(&"RightHand") if fighter.rig else null
	if hand == null:
		hand = fighter
	# STATIC, not KINEMATIC: a kinematic body reports the hand's motion as its
	# velocity (a pose snap read as ~46 m/s); a static one carries none.
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	body.freeze = true
	body.collision_layer = 0
	body.collision_mask = 0
	body.reparent(hand, false)
	body.position = CARRY_OFFSET if hand != fighter else Vector3(0.3, 1.2, -0.3)
	body.rotation = Vector3.ZERO
	body.reset_physics_interpolation()
	_carried = body
	return true

## The chunk in hand, if any.
func get_carried_debris() -> RigidBody3D:
	return _carried if _carried != null and is_instance_valid(_carried) else null

## Let go of a carried chunk (hit, grabbed, died): it falls as debris.
func drop_debris() -> void:
	var body := _carried
	_carried = null
	if body == null or not is_instance_valid(body) or not fighter.is_inside_tree():
		return
	var at := _clear_launch_point(body)
	body.reparent(fighter.get_parent(), true)
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	body.global_position = at
	body.reset_physics_interpolation()
	body.freeze = false
	body.collision_layer = Layers.DEBRIS
	body.collision_mask = Layers.MASK_DEBRIS
	DebrisManager.register(body, false)

## Damage multiplier of this fighter's attacks: its archetype's damage_mult
## (the Duelist) x AIBrain.get_damage_mult() (one-armed enemies hit at half).
func _damage_mult() -> float:
	var m := float(fighter.config.get("damage_mult", 1.0))
	if fighter.brain != null and fighter.brain.has_method(&"get_damage_mult"):
		m *= float(fighter.brain.call(&"get_damage_mult"))
	return m


# =============================================================================
# Round 8: the charge, pressure and the air combo (contract API; agent B)
# =============================================================================

## The charge amount c (0..1) of the strike being charged; 0 when not charging
## (is_charging() tells the two apart).
func get_charge() -> float:
	return _charge_c if is_charging() else 0.0

## The move being charged (&"jab", &"front_kick", ...), &"" when not charging.
func get_charge_move() -> StringName:
	return _charge_id if is_charging() else &""

## The target picked at the charge's press (the body turns to it while
## charging; PlayerController faces it), null when not charging or none.
func get_charge_target() -> Fighter:
	return _charge_target if is_charging() and _alive(_charge_target) else null

## The c values where the charged move's result changes (the meter's colour
## steps), ascending, each in (0, 1]. Empty when not charging.
func get_charge_steps() -> Array[float]:
	if not is_charging():
		return []
	return _charge_steps.duplicate()

func is_charge_full() -> bool:
	return is_charging() and _charge_full

## Victim side: current pressure and the break capacity (Tuning.r8_pressure_cap).
func get_pressure() -> float:
	return _pressure

func get_pressure_max() -> float:
	if fighter == null:
		return Tuning.R8_PRESSURE_CAP_DEFAULT
	return Tuning.r8_pressure_cap(fighter.archetype, fighter.level)

## get_pressure() / get_pressure_max(), 0..1 (1 while broken).
func get_pressure_fraction() -> float:
	if is_broken():
		return 1.0
	return clampf(_pressure / maxf(get_pressure_max(), 1e-3), 0.0, 1.0)

## Broken open: can't block or guard, takes the break bonus (Round 9: guard
## broken; it still moves and attacks unless Tuning.R9_BROKEN_STUN, the Round 8 daze).
func is_broken() -> bool:
	return _broken_left > 0.0

func get_broken_time_left() -> float:
	return maxf(_broken_left, 0.0)

## Player side: the body a Jump press would follow right now (a charged
## uppercut's lift inside R8_AIR_FOLLOW_WINDOW and range), else null. H reads it
## on Jump and calls traversal.start_air_follow(target).
func get_air_follow_target() -> Fighter:
	var b: Fighter = _air_follow_body if _alive(_air_follow_body) else null
	if b == null or TimeDirector.now() - _air_follow_t > Tuning.R8_AIR_FOLLOW_WINDOW:
		return null
	if not b.is_lifted() or b.is_down() or b.is_held():
		return null
	var to := b.global_position - fighter.global_position
	if Vector2(to.x, to.z).length() > Tuning.R8_AIR_FOLLOW_RANGE:
		return null
	return b

## Air hits landed in the current air combo (0 when none).
func get_air_hits() -> int:
	return _air_hits

# --- Pressure (victim side) ---------------------------------------------------------
## A player hit adds its pressure (HitInfo.pressure: the move's x
## debug_pressure_mult) x R8_BLOCKED_PRESSURE_MULT when blocked, x
## R8_BREAK_IMMUNE_RATE in the immunity after a break; a full charged gut
## punch (meta "full_break") fills it outright. HitInfo.pressure becomes what
## was added. Nothing is added while broken. Full: broken open.
func _add_pressure(info: HitInfo, blocked: bool) -> void:
	var att := info.attacker as Fighter
	if info.pressure <= 0.0 or att == null or not is_instance_valid(att) or not att.is_player \
			or fighter.is_player or fighter.is_dead() or is_broken():
		info.pressure = 0.0
		return
	var cap := get_pressure_max()
	var add := info.pressure * (Tuning.R8_BLOCKED_PRESSURE_MULT if blocked else 1.0)
	if _immune_left > 0.0:
		add *= Tuning.R8_BREAK_IMMUNE_RATE
	elif bool(info.get_meta(&"full_break", false)):
		add = maxf(add, cap - _pressure)  # the full charged gut punch breaks it outright
	info.pressure = add
	_pressure_idle = 0.0
	_presser = att
	_pressure = minf(_pressure + add, cap)
	if _pressure >= cap - 1e-4:
		var d := info.hit_direction
		_break_open(att, Vector3(d.x, 0.0, d.z))

## Broken open for R8_BREAK_TIME: the guard drops. Round 9: no daze and it
## keeps acting (guard broken); with Tuning.R9_BROKEN_STUN the Round 8 daze
## (Fighter.react &"broken": H's Fighter shows it once a reaction, a lift or a
## knockdown from the breaking hit is over, and again after later hits while
## is_broken() holds) and no attacks.
func _break_open(att: Fighter, dir: Vector3) -> void:
	_pressure = get_pressure_max()
	_broken_left = Tuning.R8_BREAK_TIME
	_immune_left = 0.0
	_break_dir = dir
	_block_held = false
	if _stun_left > 0.0 and _stun_kind == Stun.BLOCK:
		_stun_left = 0.0  # out of blockstun (into the daze with R9_BROKEN_STUN)
		_stun_kind = Stun.NONE
		_slide_plant = false
	_update_block_state()
	GameEvents.pressure_broken.emit(fighter, att)
	if Tuning.R9_BROKEN_STUN:
		_show_broken()

## The daze for the rest of the break: H's react &"broken" (it waits for the
## body to be free), else the dazed stun once the body is free. Cancels any wind-up.
func _show_broken() -> void:
	if fighter.is_dead():
		return
	if _react_kind_ok(fighter, &"broken"):
		var info := HitInfo.new()
		info.attacker = _presser if is_instance_valid(_presser) else null
		info.victim = fighter
		info.hit_bone = Bones.CHEST
		fighter.react(&"broken", _break_dir, 0.0, _broken_left, info)
	elif not fighter.is_reacting() and not fighter.is_down() and not fighter.is_held():
		apply_daze(_broken_left)

## Per tick (own time, not in hitstop): the break runs out (pressure_recovered,
## the meter empty, the immunity starts; without H's &"broken" the dazed stun
## comes back after a hit's reaction); otherwise the meter drains
## R8_PRESSURE_DECAY of its capacity per s once R8_PRESSURE_DECAY_DELAY passed
## without a hit.
func _tick_pressure(delta: float) -> void:
	if _broken_left > 0.0:
		_broken_left -= delta
		if _broken_left <= 0.0:
			_recover_pressure()
		elif Tuning.R9_BROKEN_STUN and _broken_left > BROKEN_SHOW_MIN and not _react_kind_ok(fighter, &"broken") \
				and not fighter.is_reacting() \
				and not is_dazed() and not fighter.is_down() and not fighter.is_held():
			apply_daze(_broken_left)
		return
	if _immune_left > 0.0:
		_immune_left = maxf(_immune_left - delta, 0.0)
	if _pressure > 0.0:
		_pressure_idle += delta
		if _pressure_idle >= Tuning.R8_PRESSURE_DECAY_DELAY:
			_pressure = maxf(_pressure - Tuning.R8_PRESSURE_DECAY * get_pressure_max() * delta, 0.0)

func _recover_pressure() -> void:
	_broken_left = 0.0
	_pressure = 0.0
	_pressure_idle = 0.0
	_immune_left = Tuning.R8_BREAK_IMMUNE  # H's daze ends itself once is_broken() is false
	if is_dazed():
		_stun_left = 0.0
		_on_stun_end()
	GameEvents.pressure_recovered.emit(fighter)

## H's Fighter.react knows `kind` (Fighter.REACT_KINDS; the Round 8 kinds land
## there when H implements them).
static func _react_kind_ok(f: Fighter, kind: StringName) -> bool:
	var sc: Script = f.get_script() if f != null else null
	while sc != null:
		var cm := sc.get_script_constant_map()
		if cm.has("REACT_KINDS"):
			return (cm["REACT_KINDS"] as Array).has(kind)
		sc = sc.get_base_script()
	return false

# --- The air combo (player side) -----------------------------------------------------
## In the air by choice: a jump, a hang, Traversal's air state or its launcher jump.
func _player_airborne() -> bool:
	return _fighter_bool(&"is_airborne") or _traversal_bool(&"is_airborne") \
		or _traversal_bool(&"is_air_following")

## The lifted body an attack press in the air strikes (Round 8): Traversal's
## launcher-jump target, else the nearest lifted opponent within
## R8_AIR_STRIKE_RANGE. null on the ground, for non-strikes, or when none.
func _air_strike_target(action: int) -> Fighter:
	if not fighter.is_player or not Tuning.R8_MOVES.has(_move_for(action)) or not _player_airborne():
		return null
	var t := fighter.traversal
	if t != null and t.has_method(&"get_air_follow_target"):
		var af: Variant = t.call(&"get_air_follow_target")
		if _alive(af) and (af as Fighter).team != fighter.team:
			return af
	var best: Fighter = null
	var best_d := Tuning.R8_AIR_STRIKE_RANGE
	for f in Targeting.opponents_of(fighter):
		if f.is_dead() or not f.is_lifted():
			continue
		var d := f.global_position.distance_to(fighter.global_position)
		if d <= best_d:
			best_d = d
			best = f
	return best

## An air strike at `tgt`: the button's move (the punch string counts on) on
## R8_AIR_FRAMES, never charged; a punch with the stick pulled back spikes.
## Round 9: the leg kick is the air axe kick (R9_AXE "air_frames", a spike).
func _start_air(action: int, press_t: float, tgt: Fighter) -> void:
	_tick_chain(TimeDirector.now())
	var idx := _string_index_now()
	var id := _move_for(action)
	var m := MoveLibrary.air_move(MoveLibrary.AXE if id == &"leg_kick" else id)
	if m == null:
		return
	_press_action = action
	_press_t = press_t
	_hold_pending = false
	if action == Action.LIGHT or action == Action.HEAVY:
		_begin_string_punch(idx)
	else:
		_cur_string = -1
	var spike := not m.is_kick and _intent_back()
	_launch_move(m, tgt)
	_air_spike = spike

## A landed air strike: up to Tuning.debug_air_hits per combo the player and
## the body hang R8_AIR_HANG (a finisher's body flies: only the player hangs);
## GameEvents.air_hit.
func _on_air_hit(victim: Fighter, info: HitInfo) -> void:
	_air_hits += 1
	if _air_hits <= Tuning.debug_air_hits:
		fighter.hang(Tuning.R8_AIR_HANG)
		if not info.react in [&"launch", &"spike"]:
			victim.air_hang(Tuning.R8_AIR_HANG)
	GameEvents.air_hit.emit(fighter, victim, _air_hits)

## The air combo ends when the player is back on the ground.
func _tick_air_combo() -> void:
	if _air_hits > 0 and not _player_airborne() and not (_move != null and _move.air and _phase != Phase.IDLE):
		_air_hits = 0
