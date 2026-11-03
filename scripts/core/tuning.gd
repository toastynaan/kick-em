class_name Tuning
## Every gameplay number from the spec, in one place. Values are tuning starts.
## OWNER: core (contract). Modules read from here; add new constants rather
## than hard-coding numbers in module code. Frame counts are at 60 fps.

const FPS := 60.0

static func frames(n: float) -> float:
	return n / FPS

# --- Difficulty -------------------------------------------------------------
enum Difficulty { EASY, NORMAL }
static var difficulty: int = Difficulty.NORMAL

# --- Fighters ---------------------------------------------------------------
## Archetype table. appearance keys are read by HumanoidRig.build().
## ragdoll: "active" = muscles (player, elites), "passive" = soft limits only.
const ARCHETYPES := {
	&"player": {
		"hp": 100.0, "mass": 70.0, "ragdoll": "active",
		"appearance": {"height": 1.0, "width": 1.0, "skin": Color(0.87, 0.69, 0.55),
			"shirt": Color(0.12, 0.35, 0.85), "pants": Color(0.12, 0.12, 0.16), "accessory": &"none"},
	},
	&"grunt": {
		"hp": 100.0, "mass": 75.0, "ragdoll": "passive",
		"appearance": {"height": 0.97, "width": 1.0, "skin": Color(0.78, 0.58, 0.45),
			"shirt": Color(0.55, 0.52, 0.45), "pants": Color(0.25, 0.25, 0.22), "accessory": &"none"},
		# Round 5: jab-cross string (e_jab then e_hook), front kick, grab.
		"moves": [&"e_jab", &"e_hook", &"e_kick", &"e_grab"],
		"guard_chance": 0.15,          # guards this share of tapped strikes (Tuning.GUARD_TAP_CHANCE)
		"sidesteps_sprint": true,      # may sidestep a sprint attack seen from > SIDESTEP_SPRINT_MIN_DIST
	},
	# Round 5 roster (Feel Reference: Enemy types).
	&"stick": {
		"hp": 100.0, "mass": 75.0, "ragdoll": "passive",
		"appearance": {"height": 1.0, "width": 0.95, "skin": Color(0.72, 0.52, 0.4),
			"shirt": Color(0.22, 0.27, 0.4), "pants": Color(0.18, 0.18, 0.2), "accessory": &"stick"},
		"moves": [&"e_stick_swing", &"e_stick_thrust"],
		"reach": 2.2, "keep_distance": 3.0,
		"drops_stick_at": HitInfo.Tier.STAGGER,  # a stagger or more makes him drop the stick (it becomes a prop)
		"sidesteps_sprint": true,
	},
	&"heavy": {
		"hp": 160.0, "mass": 110.0, "ragdoll": "active",
		"appearance": {"height": 1.12, "width": 1.4, "skin": Color(0.58, 0.42, 0.33),
			"shirt": Color(0.32, 0.1, 0.1), "pants": Color(0.12, 0.1, 0.1), "accessory": &"none"},
		"moves": [&"e_heavy", &"e_charge", &"e_grab_slam"],
		"ignore_flinch": true,         # only a stagger or more interrupts him
		"heavy": true,                 # launches at HEAVY_LAUNCH_MULT, never sidesteps, Battering Ram "heavy" column
	},
	&"brawler": {
		"hp": 130.0, "mass": 80.0, "ragdoll": "passive",  # legacy (not in Round 5 waves)
		"appearance": {"height": 1.02, "width": 1.12, "skin": Color(0.6, 0.42, 0.3),
			"shirt": Color(0.75, 0.45, 0.1), "pants": Color(0.2, 0.18, 0.15), "accessory": &"bandana"},
		"moves": [&"e_hook", &"e_heavy", &"e_grab"],
		"blocks_jabs": true, "grab_blocker_after": 1.0,
	},
	&"shield": {
		"hp": 140.0, "mass": 85.0, "ragdoll": "passive",  # legacy
		"appearance": {"height": 1.03, "width": 1.1, "skin": Color(0.7, 0.55, 0.42),
			"shirt": Color(0.3, 0.32, 0.36), "pants": Color(0.15, 0.15, 0.18), "accessory": &"shield"},
		"moves": [&"e_hook", &"e_heavy"],
		"front_block": true,
	},
	&"brute": {
		"hp": 220.0, "mass": 140.0, "ragdoll": "active",  # legacy
		"appearance": {"height": 1.18, "width": 1.45, "skin": Color(0.55, 0.4, 0.32),
			"shirt": Color(0.45, 0.08, 0.08), "pants": Color(0.12, 0.1, 0.1), "accessory": &"armor"},
		"moves": [&"e_heavy", &"e_charge", &"e_grab"],
		"throw_speed": 14.0,
		"armor_bonus": 1,
	},
	&"duelist": {
		"hp": 200.0, "mass": 65.0, "ragdoll": "active",  # Duel mode opponent (Round 5 health scale)
		"appearance": {"height": 1.0, "width": 0.95, "skin": Color(0.9, 0.75, 0.62),
			"shirt": Color(0.85, 0.85, 0.88), "pants": Color(0.55, 0.08, 0.1), "accessory": &"bandana"},
		"moves": [&"e_hook", &"e_kick", &"e_heavy", &"e_grab"],
		"dodge_chance": [0.15, 0.3],  # [easy, normal]
		"damage_mult": 1.3,      # scales its move damage (round 2: 45-60 s duels)
		"perfect_dodge": true,   # only the player and fighters with this flag can perfect-dodge
		"focus": 2.0,            # starting Focus; its teleport counter costs 1, a dodge earns 0.5
		"armor_bonus": 1,        # added to every enemy move's armor level
	},
	&"thrower": {
		"hp": 100.0, "mass": 70.0, "ragdoll": "passive",  # legacy
		"appearance": {"height": 0.95, "width": 0.92, "skin": Color(0.8, 0.62, 0.5),
			"shirt": Color(0.2, 0.5, 0.25), "pants": Color(0.2, 0.2, 0.2), "accessory": &"none"},
		"moves": [&"e_throw_debris", &"e_hook"],
	},
}

# --- Movement ---------------------------------------------------------------
const WALK_SPEED := 4.5          ## m/s, player
const ENEMY_WALK_SPEED := 3.2    ## m/s
const TURN_SPEED := 14.0         ## rad/s facing slerp rate
const DASH_SPEED := 9.0          ## m/s burst
const DASH_TIME := 0.22          ## s of dash burst
const DASH_COOLDOWN := 0.35
const GRAVITY := 20.0            ## m/s^2 for capsules (ragdolls use project gravity)

# --- Enemy damage on the player -------------------------------------------
## Round 5 (Feel Reference: Enemy hits on the player). e_charge is a guess (not in the table).
const DMG_ENEMY := {&"e_jab": 10.0, &"e_hook": 10.0, &"e_kick": 15.0, &"e_grab": 15.0,
	&"e_stick_swing": 15.0, &"e_stick_thrust": 15.0, &"e_heavy": 20.0, &"e_charge": 20.0,
	&"e_grab_slam": 15.0, &"e_throw_debris": 8.0}

const IMPACT_MIN_ENERGY := 500.0  ## J: impacts below this make no event

# --- Throws and sweeps (shape only; speeds and tiers are in the Round 5 block) -
const THROW_UP_ANGLE := 15.0
const SWEEP_SPIN := 9.0           ## rad/s spin added to shins on a sweep

# --- Defence leftovers (the Duelist's teleport counter, enemy get-up) --------
const COUNTER_BEHIND_DIST := 1.2
const AIR_RECOVERY_AFTER := 0.4
const ENEMY_GETUP_INVULN := 0.25  ## enemies: short, so punts and follow-ups stay possible

# --- Focus ------------------------------------------------------------------
const FOCUS_MAX := 3.0
const FOCUS_COST := 1.0  ## teleport counter, pursuit, air recovery, reversal

# --- Pursuit ----------------------------------------------------------------
const PURSUIT_WINDOW := 0.5     ## s after a launch

# --- Grab (spec: Grab, throw and grab break) --------------------------------
const GRAB_RANGE := 1.4  ## Round 5
const GRAB_BREAK_EARLY := 6.0 / 60.0   ## before the enemy grab becomes active
const GRAB_BREAK_LATE := 10.0 / 60.0   ## after it connects
const GRAB_BREAK_PUSH := 1.5           ## m apart

# --- Ragdoll states ---------------------------------------------------------
const GROUNDED_SPEED := 0.5      ## m/s pelvis speed
const GROUNDED_HOLD := 0.4       ## s under that speed
const GROUNDED_TIMEOUT := 3.0    ## s after first landing, whatever the speed
const GETUP_BLEND := 0.3       ## ragdoll -> get-up blend (round 2: get-up totals ~0.8 s)
const FLINCH_TIME := 0.3

# --- AI (spec: Enemies and AI) ----------------------------------------------
const TOKENS := [1, 2]           ## [easy, normal]
const NEAR_RING := Vector2(2.5, 4.0)
const FAR_RING := Vector2(6.0, 9.0)
const ONSCREEN_BEFORE_TOKEN := 0.4
const ATTACK_INTERVAL := Vector2(2.0, 3.0)
const MAX_ENEMIES_ON_FIELD := 8  ## Round 5: at most 8 alive at once

# --- Rounds -----------------------------------------------------------------
## Round 5 starting mix. After the last entry GameMode adds one enemy per wave
## (WAVE_GROWTH_MIX), with at most MAX_ENEMIES_ON_FIELD alive at once.
const WAVES := [
	{&"grunt": 3},
	{&"grunt": 5},
	{&"grunt": 4, &"stick": 1},
	{&"grunt": 4, &"heavy": 1},
]
const CORPSE_MAX := 20  ## Round 5

# --- Impact resolution (spec: Impact resolution) ----------------------------
const CRACK_FRACTION := 0.4  ## Round 5 (original spec: cracking at 40%)
const SURFACES := {
	&"drywall": {"break_energy": 2000.0, "absorption": 0.3},
	&"brick": {"break_energy": 6000.0, "absorption": 0.45},
	## Round 5: concrete breaks at 15,000 J. Never in one hit (18 m/s cap, 10,257 J):
	## a crack lowers the threshold by half the hit's energy, so a second hit does it.
	## The arena's outer boundary walls stay unbreakable (D).
	&"concrete": {"break_energy": 15000.0, "absorption": 0.0, "decal_from": 5000.0},
	&"wood": {"break_energy": 1200.0, "absorption": 0.2},
}
const BOWL_SPEED_SHARE := 0.5
const BOWL_CHAIN_MAX := 4

# --- Budgets ----------------------------------------------------------------
const DEBRIS_MAX := 250  ## Round 6: raised from 150 with full clutter (perf: 2.54 ms avg, 7.29 ms max)
const DEBRIS_FREEZE_AFTER := 4.0
const DEBRIS_FADE_AFTER := 10.0
const ACTIVE_RAGDOLL_MAX := 4

# --- Slow motion (spec: Game feel) ------------------------------------------
const SLOWMO_EASE := 0.15

# --- Camera (Upgrade 2: Camera fixes) ----------------------------------------
const CAM_MIN_DIST := 2.2        ## m; was 3.0. The camera never gets closer.
const CAM_PLAYER_OFFSET_X := -0.1  ## player sits this fraction of the screen width left of centre
const CAM_PITCH_RANGE := Vector2(-35.0, 20.0)  ## degrees (negative looks down)
## In play the camera never follows a flying body: a launch or throw sending a
## body more than CAM_WIDEN_TRIGGER m widens the frame instead, for at most CAM_WIDEN_TIME.
const CAM_WIDEN_TRIGGER := 6.0
const CAM_WIDEN_TIME := 1.2      ## s, at most
const CAM_MOUSE_IDLE := 1.0      ## s after the last camera input before auto-rotation
const CAM_RETURN_TIME := 0.5     ## s to ease back behind the player
const CAM_MODE_GAP := 0.75       ## s: at most one camera mode change per this
const CAM_MODE_BLEND := 0.25     ## s per mode blend
const CAM_TARGET_TURN := 90.0    ## degrees per s on a soft-target change
const CAM_BLOCKER_ALPHA := 0.25  ## walls, props, rubble and ragdolls in the way fade to this

# --- Camera control and lock-on (Round 4) -----------------------------------------
# Free camera by default: the camera only turns when the player turns it (mouse
# or right stick). It never auto-rotates toward enemies or back behind the
# player; that replaces CAM_MOUSE_IDLE / CAM_RETURN_TIME / CAM_TARGET_TURN in play.
# Lock-on is a toggle (Controls "lock_on"); while locked the camera keeps the
# target framed and the player strafes around it.
## rad per logical mouse point at sensitivity 1.0. CameraRig divides raw deltas
## by the screen's HiDPI scale, so on a 2x retina screen this is 0.002 rad per
## physical pixel: about 30% slower than the old 0.0028 per physical pixel.
const CAM_MOUSE_SENS := 0.004
const CAM_STICK_SPEED := 2.4     ## rad/s at full right-stick deflection (was 3.2)
const CAM_SENS_RANGE := Vector2(0.25, 2.0)  ## player sensitivity setting range (pause menu)
const LOCK_RANGE := 12.0         ## m: lock_on picks the enemy nearest the screen centre within this
const LOCK_BREAK_RANGE := 18.0   ## m: the lock drops beyond this
const LOCK_LOS_GRACE := 1.5      ## s with the target hidden behind walls before the lock drops
const LOCK_TURN_SPEED := 240.0   ## degrees/s at most while the camera keeps the target framed
const LOCK_PITCH := -12.0        ## degrees: default look-down while locked
const LOCK_RETARGET_ON_KO := true  ## when the locked target dies, lock the next nearest in range

# --- Input model (Upgrade 2: tap to combo, hold to charge) --------------------
const HOLD_THRESHOLD := 0.15     ## s: released before = tap, still held = charge (main feel setting)
const CHARGE_LEVELS: Array[float] = [0.3, 0.6, 1.0]  ## s held (real time) to reach level 1, 2, 3 (Round 5)
## Round 5 charge_mult by level 0..3: multiplies both the power base and the strike damage.
const CHARGE_MULT: Array[float] = [1.0, 1.6, 2.3, 3.2]
const CHARGE_DAMAGE: Array[float] = CHARGE_MULT  ## alias kept for older callers
const CHARGE_AUTO_RELEASE := 1.5 ## s: a held button never locks the fighter
const BUFFER_FRAMES := 10.0      ## a press in the last N frames of recovery fires the next move
const STRING_RESET := 0.4        ## s after a move ends with no press: the string resets
const COMBO_DROP := 1.0          ## s without a landed hit ends the combo count

# --- Crouch and jump (Upgrade 2) -----------------------------------------------
const CROUCH_HEIGHT := 1.1       ## m capsule (standing 1.8)
const CROUCH_SPEED := 0.4        ## walk x
const JUMP_APEX := 0.9           ## m; with GRAVITY 20 this is 0.6 s in the air (v0 = 6 m/s)
const JUMP_AIR_STEER := 0.5      ## of walk control while airborne
const JUMP_LAND_FRAMES := 6.0
const AIR_COUNTER_LAUNCH := 1.25 ## launch x on a fighter hit while jumping

# --- Combos (Upgrade 2) ----------------------------------------------------------
const COMBO_FULL_HITS := 2       ## hits 1-2 do full damage...
const COMBO_SCALE_STEP := 0.1    ## ...then each hit 10% less...
const COMBO_SCALE_MIN := 0.5     ## ...down to 50%
# Anti-infinite (round 3). Scaling alone never ends a stun loop, so the victim's
# hitstun shrinks over a combo and a hard cap lets it break away. Counted per
# VICTIM: hits taken from anyone with no COMBO_DROP gap.
const COMBO_STUN_DECAY_FROM := 4 ## from this hit taken, flinch/stagger stun shrinks...
const COMBO_STUN_DECAY := 0.15   ## ...by this much per hit...
const COMBO_STUN_MIN := 0.4      ## ...down to 40% of its normal length
const COMBO_ESCAPE_HITS := 8     ## the hit that would make this many: damage, no stun, the victim breaks away
const COMBO_ESCAPE_STUN := 2.5   ## s of stun taken in one combo also triggers the break-away
const COMBO_ESCAPE_GUARD := 0.6  ## s of auto-guard (frontal strikes blocked) after breaking away
const COMBO_ESCAPE_PUSH := 1.2   ## m the break-away opens between the two fighters
const JUGGLE_MAX_RELAUNCH := 2   ## juggle relaunches per flight; later hits only damage, the body falls
const DAZED_TIME := 1.5          ## hunched, no actions (the reaction still comes from P)

# --- Body zones and grabs (Upgrade 2) ----------------------------------------------
const ZONE_LEG_SLOW := 0.3       ## enemy walk -30%...
const ZONE_LEG_SLOW_TIME := 3.0  ## ...for this long
const ARM_BREAK_AT := 100.0      ## zone damage on one arm
const ARM_DRAG_BREAK_MULT := 0.7 ## arm drags give the victim a 30% shorter break window
const WALL_SLAM_RANGE := 1.5     ## m from a wall/pillar when the grab connects
const WALL_SLAM_SPEED := 9.0     ## m/s head first into it (~2,800 J for 70 kg)

# --- Focus --------------------------------------------------------------------
## Units are bars: FOCUS_MAX (3.0) is three bars.
const FOCUS_SCALE := 0.3         ## world time scale during Focus mode (Tuning.SLOW_TIME.focus)

# --- Wall strikes (Round 3: punch and kick walls) ---------------------------------
## The player's punches and kicks damage the wall cells under the striking
## limb. Strike power = move damage x CHARGE_DAMAGE[level] x (1 + STRIKE_DASH_BONUS
## while dash momentum is on). Each surface soaks power per cell; damage stays
## for the round, so harder walls break over several hits, and a weakened wall
## breaks more easily when a body is thrown into it.
## Feel targets (agent D tunes these numbers):
##   drywall: two jabs or one kick open a fist-sized hole, a charged kick a body-sized one
##   wood (roll door): 3-4 kicks
##   brick: about 8 kicks, or 2-3 level-3 charges
##   concrete pillar: chips every hit, the core holds
##   outer concrete walls: chips, cracks and dust only (the arena boundary never opens)
const STRIKE_CELL_HP := {&"drywall": 28.0, &"wood": 170.0, &"brick": 450.0, &"concrete": 900.0}
const STRIKE_SPREAD := 0.12      ## m: cells within this of the contact take half the power (D widens it for strong hits)
const STRIKE_DASH_BONUS := 0.5
const STRIKE_HITSTOP := 0.04     ## real s, attacker only (a wall hit needs weight too)
const STRIKE_RECOIL := 1.5       ## m/s push back off a wall that holds
const STRIKE_SHAKE := 0.12       ## screen-shake trauma for a wall that holds (x2 when it breaks)

# --- Dismemberment ----------------------------------------------------------
enum Gore { OFF, BLOOD, DISMEMBER }
static var gore: int = Gore.DISMEMBER

# =============================================================================
# Round 5: Feel Reference (docs/Feel Reference — Sifu × Prototype for the
# Ragdoll Brawler.md). Every number here is a starting value from that doc.
# Where an older constant above disagrees, these win; older ones still in use
# are marked SUPERSEDED and go once their last caller has moved over.
# Frames are 1/60 s of the fighter's OWN time (Tuning.frames()).
# =============================================================================

# --- Debug settings (pause menu > Debug. J writes them, everyone reads) ------
## Round 7: the player's upgrades are these settings (pause menu > Debug) until
## the progression round. Every reader takes them live.
static var debug_speed_cap := 8.0     ## m/s sprint cap: 8 base; 10 and 12 are the upgraded caps
static var debug_ram_level := 0       ## Battering Ram 0 (not earned) .. 3
static var debug_teleport := true     ## Round 7: Dash just before a hit teleports behind the attacker
static var debug_pursuit_max := 2     ## Round 7: pursuits that may chain off one launch (0 = no pursuit), 0..3
static var debug_start_focus := 1.0   ## SUPERSEDED (Round 7 removed the Focus meter); unread
static var debug_overlay := false     ## debug overlay (HUD)

# --- Power score P (Strikes and body reactions) -------------------------------
## P = base x CHARGE_MULT[level] + speed_bonus + counter_bonus + finisher_bonus.
## Math lives in Power (scripts/core/power.gd).
const POWER_BASE := {&"jab": 1.0, &"cross": 2.0, &"kick": 2.5, &"sweep": 1.5,
	&"knee": 1.5, &"elbow": 1.5, &"ground": 1.0}
const SPEED_BONUS_K := 1.5       ## speed_bonus = K x max(0, v - SPEED_BONUS_FROM)
const SPEED_BONUS_FROM := 6.0    ## m/s
const SPEED_CAP_SNAP := 0.98     ## v counts as the cap once it reaches this share of it
const COUNTER_BONUS_PARRY := 2.5
const COUNTER_BONUS_TELEPORT := 3.0
const COUNTER_BONUS_TIME := 1.5  ## real s, or until the next hit lands
const FINISHER_BONUS := 1.0      ## third hit of a tap string
## Tier bands, half-open: a value on a boundary goes to the higher tier.
## [stagger from, knockdown from, launch from, hard launch from, sever from]
const TIER_BANDS: Array[float] = [2.0, 3.5, 5.0, 7.0, 9.0]
## Sweep reads the leg: [knockdown (trip) from, launch (upended) from]; under = stumble.
const SWEEP_BANDS: Array[float] = [3.5, 5.0]

# --- Strikes: frame data and damage -------------------------------------------
## [startup, active, recovery on miss] in frames. Charging adds hold time on top.
const STRIKE_FRAMES := {&"jab": Vector3(5, 3, 10), &"cross": Vector3(9, 4, 16),
	&"kick": Vector3(12, 4, 22), &"sweep": Vector3(10, 5, 20), &"knee": Vector3(7, 3, 14),
	&"elbow": Vector3(7, 3, 14), &"ground": Vector3(8, 3, 14)}  # ground strike: a guess
const HIT_RECOVERY_CUT := 0.4    ## recovery x (1 - this) when the hit lands
## Strike damage before CHARGE_MULT.
const STRIKE_DAMAGE := {&"jab": 4.0, &"cross": 8.0, &"kick": 10.0, &"sweep": 5.0,
	&"knee": 6.0, &"elbow": 6.0, &"ground": 6.0}
const SPRINT_WHIFF_FRAMES := 8.0 ## extra recovery on a missed sprint strike
const SPRINT_LUNGE_STOP := 0.9   ## m: a sprint lunge stops this short of the target
const LUNGE_MAX := 1.0           ## m: strikes turn to the target and lunge up to this
const GROUND_STRIKE_RANGE := 1.6 ## m: attacking this close to a body on the ground is a ground strike (guess)

# --- Target picking (Controls and targeting) -----------------------------------
const TARGET_CONE := 60.0        ## degrees each side of the stick (or camera forward)
const STRIKE_TARGET_RANGE := 4.0 ## m
const SPRINT_TARGET_RANGE := 10.0 ## m while sprinting
const TARGET_ANGLE_WEIGHT := 0.6 ## score = 0.6 (1 - angle/cone) + 0.4 (1 - dist/range)

# --- Reactions by tier (Partial ragdoll reactions) -----------------------------
## physics: share of the hit chain given to physics (1 - muscle strength) at the hit.
## fade: s for that share to fall back to 0. act: s until the victim can act again.
## ground: s on the ground before getting up (x = min, y = max).
const REACT_FLINCH := {"physics": 0.6, "fade": 0.25, "act": 0.3}
const REACT_STUMBLE := {"physics": 0.5, "hold": 0.3, "act": 0.6, "steps": Vector2(2, 3)}
const REACT_STAGGER := {"physics": 0.8, "fade": 0.6, "act": 0.8, "push": Vector2(0.6, 1.0)}
const REACT_KNOCKDOWN := {"ground": Vector2(1.2, 2.0)}
const REACT_LAUNCH := {"ground": Vector2(1.5, 2.5)}
## Hitstop by tier (real s): attacker and victim only, others keep moving.
const HITSTOP_TIER := {&"flinch": 0.04, &"stumble": 0.06, &"stagger": 0.06, &"knockdown": 0.08,
	&"launch": 0.11, &"hard_launch": 0.15, &"sever": 0.18}
const PLAYER_HITSTOP_MAX := 0.06 ## the player never freezes longer than this
const HITSTOP_JITTER_RANGE := Vector2(0.02, 0.04)  ## m victim mesh jitter during the freeze
const WALL_BREAK_FREEZE := 0.15  ## real s: only the flying body freezes at a wall break

# --- Launches (Launch speed and walls) -----------------------------------------
const LAUNCH_SPEED_MIN := 6.0    ## v = clamp(6 + 2 (P - 5), 6, 18)
const LAUNCH_SPEED_MAX := 18.0   ## also the cap on every flying body, throws included
const LAUNCH_ANGLE := 30.0       ## degrees up for P under 7
const LAUNCH_ANGLE_HARD := 18.0  ## degrees up for P 7 and more: flat and fast
const HEAVY_MASS := 95.0         ## kg: at or above this (or archetype "heavy") a fighter is heavy
const HEAVY_LAUNCH_MULT := 0.8   ## heavies launch at 80% of v
const LAUNCH_DAMAGE_BASE := 10.0 ## launch damage = 10 + 3 (P - 5)...
const LAUNCH_DAMAGE_PER_P := 3.0
const LAUNCH_DAMAGE_CAP := 0.35  ## ...capped at this share of the victim's max health
const PURSUIT_POWER_ADD := 3.0   ## a pursuit hit relaunches at max(current speed, v(P + 3))

# --- Health and damage (Health, damage and enemies) ----------------------------
## Damage a flying body takes from a wall (replaces energy-based impact damage on walls).
const WALL_DAMAGE := {&"crack": 5.0, &"drywall": 10.0, &"wood": 10.0, &"brick": 20.0, &"concrete": 30.0}
const LIMB_LOST_DAMAGE := 25.0
const HEAL_BETWEEN_WAVES_HP := 25.0
const GUARD_DAMAGE_MULT := 0.2   ## holding Block: 80% less damage
const GUARD_PUSH := 0.5          ## m heavy hits push a guarding fighter back

# --- Defence (Parry, teleport, pursuit) -----------------------------------------
const PARRY_WINDOW := 8.0 / 60.0     ## real s: Block press before an attack's first active frame
const PARRY_LOCKOUT := 20.0 / 60.0   ## real s of parry lockout after a tap with no attack in its window
const PARRY_FREEZE := 0.06           ## real s both freeze on a parry
const TELEPORT_WINDOW := 8.0 / 60.0  ## real s: fresh Dash press before an attack's (or grab's) first active frame
const TELEPORT_COST := 1.0           ## Focus bars; with less it is a sidestep
const TELEPORT_SPOTS: Array[Vector2] = [Vector2(0.0, 1.2), Vector2(0.0, 0.9),
	Vector2(1.2, 0.0), Vector2(-1.2, 0.0)]  ## (side m, behind m) tried in order from the attacker
const SIDESTEP_DIST := 1.5           ## m
const AFTERIMAGE_FADE := 0.2         ## s
const SHORT_DASH_DIST := 3.0         ## m: any other Dash tap
const DASH_HOLD_SPRINT := 0.15       ## real s: Dash held longer than this sprints
const PURSUIT_COST := 1.0
const PURSUIT_MAX := 2               ## pursuits that may chain off one launch
const PURSUIT_STICK_CONE := 60.0     ## degrees: stick neutral or within this of the body
const PURSUIT_DIST := 1.2            ## m from the body
const PURSUIT_HANG := 0.25           ## real s the player hangs in the air waiting for the attack
## PURSUIT_WINDOW (0.5 s after the launch's hitstop ends) is above.

# --- Focus ------------------------------------------------------------------------
## FOCUS_MAX (3 bars) and FOCUS_SCALE (0.3) are above.
const FOCUS_WAVE_START := 1.0        ## each wave starts with this many bars (debug_start_focus overrides)
const FOCUS_GAIN := {&"parry": 0.34, &"stagger": 0.1, &"knockdown": 0.1, &"launch": 0.25,
	&"wall_break": 0.5}               ## nothing over time, nothing during Focus mode
const FOCUS_MODE_COST := 1.0
const FOCUS_MODE_TIME := 2.0         ## real s

# --- Slow time (one owner: TimeDirector) -------------------------------------------
## scale, real s, ease-out s, cooldown: whether it respects (and starts) SLOW_TIME_COOLDOWN.
## Only the strongest active request applies (lowest scale); requests never stack.
const SLOW_TIME := {
	&"parry": {"scale": 0.5, "time": 0.15, "ease": 0.08, "cooldown": true},
	&"teleport": {"scale": 0.3, "time": 0.25, "ease": 0.15, "cooldown": false},
	&"wall_break": {"scale": 0.25, "time": 0.35, "ease": 0.15, "cooldown": true},
	&"sever": {"scale": 0.3, "time": 0.4, "ease": 0.15, "cooldown": true},
	&"last_kill": {"scale": 0.2, "time": 1.0, "ease": 0.15, "cooldown": false},
	&"player_death": {"scale": 0.3, "time": 1.0, "ease": 0.15, "cooldown": false},
	&"focus": {"scale": 0.3, "time": 2.0, "ease": 0.15, "cooldown": false},
	# Round 7: a player launch payoff (hit_landed with HitInfo.react == &"launch").
	&"finisher": {"scale": 0.35, "time": 0.25, "ease": 0.1, "cooldown": true},
}
const SLOW_TIME_COOLDOWN := 1.0      ## real s between cooldown-respecting slow-motion events

# --- Sprint that builds (Movement spec) --------------------------------------------
## WALK_SPEED (4.5) is above.
const SPRINT_START_SPEED := 6.0  ## m/s on the first step
const SPRINT_RAMP_TIME := 1.2    ## s of holding (ease-out) from start speed to the cap
const SPRINT_RELEASE_TIME := 0.25 ## s to bleed back to walk after releasing Dash
const SPRINT_CAPS: Array[float] = [8.0, 10.0, 12.0]  ## base, upgrade 1, upgrade 2
const TURN_PENALTY_ANGLE := 60.0 ## degrees turned...
const TURN_PENALTY_WINDOW := 0.2 ## ...inside this many s...
const TURN_PENALTY := 0.3        ## ...loses this share of current speed
const CHARGE_WALK_MULT := 0.5    ## charging while walking
const CHARGE_SPRINT_STEER := 30.0 ## degrees/s steering while charging at a sprint (cannot stop)
const SIDESTEP_SPRINT_CHANCE := 0.3   ## enemies further than SIDESTEP_SPRINT_MIN_DIST sidestep a sprint attack
const SIDESTEP_SPRINT_MIN_DIST := 4.0

# --- Automatic parkour --------------------------------------------------------------
const PARKOUR_MIN_SPEED := 3.0   ## m/s toward the obstacle
const PARKOUR_PROBE_AHEAD := 0.8 ## m, scaled up with speed
const PARKOUR_PROBE_HEIGHTS: Array[float] = [0.45, 1.25, 1.75]  ## knee, chest, head (m above the feet)
const STEP_MAX := 0.5            ## m: under this, step over (lift the capsule)
const VAULT_MAX := 1.2           ## m: speed vault up to this
const VAULT_MAX_HOLDING := 1.0   ## m while carrying a body
const MANTLE_MAX := 2.2          ## m: sprinting only; walking it acts as a wall
const VAULT_TIME := Vector2(0.25, 0.35) ## s (shorter when faster)
const VAULT_KEEP := 0.9
const MANTLE_TIME := 0.45
const MANTLE_KEEP := 0.7
const KICKOFF_TIME := 0.3        ## over MANTLE_MAX at full speed: wall kick-off
const KICKOFF_KEEP := 0.8
const KICKOFF_TURN := 120.0      ## degrees at most
const VAULT_ATTACK_FROM := 0.6   ## an attack in the last 40% of a vault becomes a dropping strike

# --- Wall run ------------------------------------------------------------------------
const WALLRUN_MIN_CHARGE := 0.6  ## sprint_charge needed
const WALLRUN_REACH := 0.8       ## m from the wall
const WALLRUN_ANGLE := Vector2(10.0, 45.0)  ## degrees velocity off the wall's surface
const WALLRUN_TIME := 1.0        ## s at most
const WALLRUN_RISE := 0.5        ## m over...
const WALLRUN_RISE_TIME := 0.3   ## ...this many s, then held (no gravity)
const WALLRUN_DROP_KEEP := 0.9   ## speed kept when it ends
const WALLRUN_KICK_ANGLE := 45.0 ## degrees away from the wall on Jump
const WALLRUN_KICK_HEIGHT := 1.6 ## m added
const WALLRUN_NORMAL_Y := 0.2    ## |normal.y| at most for a runnable surface
const AIR_MANTLE_REACH := 0.5    ## m: hands this close to a ledge top during a jump mantle up

# --- Jump and landing ------------------------------------------------------------------
const PLAYER_GRAVITY := 9.8      ## m/s^2 rising (the doc's landing speeds assume 9.8 up, 1.6x down)
const FALL_GRAVITY_MULT := 1.6
const JUMP_HEIGHT := 1.2         ## m standing
const JUMP_HEIGHT_SPRINT := 1.5  ## m at full speed (lerp by sprint_charge)
const COYOTE_TIME := 0.1
const JUMP_BUFFER_TIME := 0.12
const SLAM_MIN_HEIGHT := 2.0     ## m above the floor: an air attack from here is a ground slam
const LAND_HARD_SPEED := 8.0     ## m/s vertical: soft under this
const LAND_HEAVY_SPEED := 11.0   ## m/s: heavy over this (or any slam)
const LAND_HARD_CROUCH := 0.12   ## s
const LAND_HEAVY_TIME := 0.2     ## s three-point landing
const LAND_ROLL_KEEP := 0.85     ## horizontal speed kept by the heavy-landing roll
const LAND_DUST_RING := Vector2(1.5, 3.0)  ## m: hard, heavy
const LAND_DEBRIS := Vector2i(6, 10)       ## chunks on a heavy landing
const SHOCK_STUMBLE_RADIUS := 2.5
const SHOCK_KNOCKDOWN_RADIUS := 1.0

# --- Running into enemies (Battering Ram) ---------------------------------------------
const RAM_SPEED_SHARE := 0.85    ## of the speed cap
const RAM_HITSTOP := 0.05
## Per level 0..3: what happens to the victim and to you. loss: share of speed lost
## (-1 = drop to walk). self: &"none" | &"stumble" | &"knockdown".
## Round 7: level 3 LAUNCHES normal enemies (R7_RAM_LAUNCH_*) and knocks heavies down.
const RAM_TABLE := [
	{"normal": {"victim": &"stumble", "self": &"stumble", "loss": -1.0},
		"heavy": {"victim": &"flinch", "self": &"knockdown", "loss": -1.0}},
	{"normal": {"victim": &"stumble", "self": &"none", "loss": 0.15},
		"heavy": {"victim": &"stumble", "self": &"stumble", "loss": -1.0}},
	{"normal": {"victim": &"knockdown", "self": &"none", "loss": 0.15},
		"heavy": {"victim": &"stumble", "self": &"none", "loss": 0.3}},
	{"normal": {"victim": &"launch", "self": &"none", "loss": 0.05},
		"heavy": {"victim": &"knockdown", "self": &"none", "loss": 0.15}},
]
const PLAYER_GETUP_AFTER := 0.8  ## s on the ground after the player is knocked down
const PLAYER_GETUP_INVULN := 0.3 ## s the player can't be hit after getting up

# --- Grabs, carrying, throwing ------------------------------------------------------------
## GRAB_RANGE (1.4) is above.
const GRAB_FRAMES := 6.0         ## standing grab startup
const GRAB_SPRINT_REACH := 2.0   ## m, with a short lunge
const GRAB_SPRINT_KEEP := 0.6    ## of your speed: the victim is dragged backwards on contact
const GRAB_BREAK_FRAMES := 10.0  ## press Grab within this to break a neutral grab (both ways)
const GRAB_CONNECT_HITSTOP := 0.05
const HOLD_MAX := 2.5            ## s before the victim struggles out (both stumble)
const HOLD_WALK_MULT := 0.7
const HOLD_SPRINT_MULT := 0.8    ## of the speed cap
const HOLD_KNEES_MAX := 3
const THROW_SPEED_TAP := 6.0     ## m/s
const THROW_SPEED_CHARGED: Array[float] = [6.0, 9.0, 12.0]  ## levels 1..3
const THROW_RUN_SHARE := 0.5     ## + this x your run speed
const THROW_SPEED_CAP := 16.0
const PROJECTILE_MIN_SPEED := 4.0 ## pelvis m/s: a thrown body is a projectile above this
const BOWL_STAGGER_BELOW := 6.0  ## m/s thrown body hits an enemy: stagger under this...
const BOWL_LAUNCH_FROM := 10.0   ## ...knockdown under this, launch from it
const BOWL_SPEED_LOSS := 0.4     ## share of speed lost per enemy hit
const BOWL_DAMAGE := {&"stagger": 5.0, &"knockdown": 10.0, &"launch": 15.0}
const PROP_DAMAGE := 8.0
const PROP_RESPAWN := 20.0       ## s
## Arena prop kinds (scattered, respawn). ThrowableProp also has &"stick" (dropped) and &"limb" (severed); neither respawns.
const PROP_KINDS: Array[StringName] = [&"brick", &"bottle", &"chair_leg", &"crate_small"]

# --- Enemies (Enemy types) ---------------------------------------------------------------
## Startup frames per enemy move early in a run (never under ENEMY_STARTUP_MIN).
## Round 7: every tell lasts at least R7_COUNTER_WINDOW + R7_TELL_MARGIN (30
## frames, AttackDirector.tell_min_frames); the table sits above that floor so
## moves still read differently (quick jab, slow overhead and charge).
const ENEMY_STARTUP := {&"e_jab": 30.0, &"e_hook": 34.0, &"e_kick": 36.0, &"e_grab": 34.0,
	&"e_stick_swing": 34.0, &"e_stick_thrust": 36.0, &"e_heavy": 44.0, &"e_charge": 42.0,
	&"e_grab_slam": 40.0}
const ENEMY_STARTUP_EARLY_MIN := 30.0  ## frames: early in a run, never faster
const ENEMY_STARTUP_MIN := 30.0
const ENEMY_STARTUP_SHRINK_FROM := 5   ## from this wave (1-based)...
const ENEMY_STARTUP_SHRINK := 2.0      ## ...frames faster per wave
const TOKEN_MAX := 2
const TOKEN_ACTIVE_GAP := 20.0 / 60.0  ## s between two token holders' first active frames
const CIRCLE_RING := Vector2(3.0, 5.0) ## m: the rest circle here
const GUARD_TAP_CHANCE := 0.15
## Tell colours shared by the limb glow (C), the off-screen arrows (J) and the
## Focus tint exemption (F): orange strikes, blue grabs (grabs can't be parried).
const TELL_COLOR_STRIKE := Color(1.0, 0.5, 0.1)
const TELL_COLOR_GRAB := Color(0.25, 0.6, 1.0)
const LIMB_LOST_FLEE_HP := 40.0  ## lost an arm: fights one-handed above this, limps away at or below
const ARM_LOST_DAMAGE_MULT := 0.5
const CRAWL_SPEED := 0.8         ## m/s: lost a leg
const DOWNED_FREE_SWINGS := 1    ## token holders get this many swings at a downed player
const WAVE_GROWTH_MIX: Array[StringName] = [&"grunt", &"grunt", &"stick", &"grunt", &"heavy"]  ## cycled after WAVES

# --- Bodies and persistence (Bodies stay) -------------------------------------------------
## CORPSE_MAX (20) is above.
const DEAD_FREEZE_AFTER := 4.0   ## s at rest before a dead body freezes
const LOOSE_LIMB_MAX := 12
const BLOOD_DECAL_MAX := 30

# --- Camera (Effects: Camera) --------------------------------------------------------------
const CAM_FOV := 70.0
const CAM_FOV_SPRINT := 78.0     ## at sprint_charge 1, base cap
const CAM_FOV_SPRINT_MAX := 85.0 ## at the upgraded caps
const CAM_SPRINT_PULLBACK := 1.5 ## m at sprint_charge 1
const CAM_SPRINT_DROP := 0.3     ## m lower
const CAM_CROWD_DIST := Vector2(7.0, 9.0)
const CAM_CROWD_HEIGHT := 2.5    ## m higher
const CAM_CROWD_FRAME := 3       ## nearest enemies framed with the player
const CAM_DUEL_DIST := Vector2(4.0, 5.0)  ## one or two enemies left: low over the shoulder
const CAM_LAUNCH_DIST := 9.0     ## m at most while framing a launch
const CAM_LAUNCH_FOLLOW := 1.0   ## s at most the look-at leans toward a flying body
const CAM_LAUNCH_YAW_RATE := 60.0 ## degrees/s at most
const CAM_WALLRUN_SHIFT := 1.5   ## m toward the open side
const CAM_WALLRUN_ROLL := 6.0    ## degrees away from the wall
const CAM_FALL_FROM := 3.0       ## m fallen before the fall tilt
const CAM_FALL_ROLL := 8.0       ## degrees at most
const CAM_LAST_KILL_DIST := 2.5  ## m close side angle
const CAM_DEATH_ORBIT := 3.0     ## m
const TRAUMA := {&"flinch": 0.05, &"stumble": 0.1, &"stagger": 0.1, &"knockdown": 0.2,
	&"launch": 0.3, &"hard_launch": 0.3, &"sever": 0.3, &"wall_break": 0.5,
	&"heavy_landing": 0.4, &"limb_lost": 0.45, &"ram": 0.1}
const TRAUMA_DECAY := 1.5        ## per s; shake = trauma^2

# --- Screen and character effects -----------------------------------------------------------
const BLUR_MAX := 0.6            ## radial blur = sprint_charge^2 x this
const SPEED_LINES_FROM := 0.8    ## sprint_charge
const FOCUS_SATURATION := 0.4    ## the world desaturates to this during Focus mode
const HIT_FLASH_ALPHA := 0.15    ## launch tier and up
const HIT_FLASH_FRAMES := 2
const TRAIL_FROM := 0.6          ## sprint_charge
const TRAIL_LENGTH := Vector2(0.4, 1.2) ## m
const TRAIL_FADE := 0.15         ## s
const TRAIL_COLOR := Color(1.0, 0.94, 0.85)  ## brand colour: neutral warm white until art direction decides
const FX_RING_GAP := 0.2         ## s: at most one shock ring...
const FX_FLASH_GAP := 0.2        ## ...and one screen flash per this

# =============================================================================
# Round 6: More destruction (user request): clutter in the fight area,
# breakable structure, floor and impact damage. Same energy model as walls:
# a flying body breaks an object with E = 1/2 M v^2 straight into it
# (Power.wall_energy); CRACK_FRACTION of that cracks it. Pieces stay.
# Contract and checks: docs/ARCHITECTURE.md, "Round 6".
# =============================================================================

# --- Clutter: breakable furniture and objects (agent K) ----------------------
## Per kind: break = J for a flying body (cracks at CRACK_FRACTION); absorb = share
## of the body's energy the break eats (it keeps sqrt(1 - absorb) of its speed);
## strike_hp = strike power to break it with punches and kicks; surface for effects.
const FURNITURE := {
	&"glass": {"break": 150.0, "absorb": 0.05, "strike_hp": 10.0, "surface": &"glass"},
	&"cardboard": {"break": 120.0, "absorb": 0.05, "strike_hp": 15.0, "surface": &"cardboard"},
	&"chair": {"break": 400.0, "absorb": 0.1, "strike_hp": 60.0, "surface": &"wood"},
	&"coffee_table": {"break": 500.0, "absorb": 0.1, "strike_hp": 70.0, "surface": &"wood"},
	&"fence": {"break": 600.0, "absorb": 0.1, "strike_hp": 80.0, "surface": &"wood"},
	&"table": {"break": 700.0, "absorb": 0.15, "strike_hp": 90.0, "surface": &"wood"},
	&"barrel": {"break": 800.0, "absorb": 0.15, "strike_hp": 100.0, "surface": &"wood"},
	&"bench": {"break": 900.0, "absorb": 0.2, "strike_hp": 120.0, "surface": &"wood"},
	&"shelf": {"break": 900.0, "absorb": 0.2, "strike_hp": 110.0, "surface": &"wood"},
	&"planter": {"break": 1000.0, "absorb": 0.25, "strike_hp": 140.0, "surface": &"concrete"},
	&"sofa": {"break": 1500.0, "absorb": 0.4, "strike_hp": 200.0, "surface": &"fabric"},
}
const FURNITURE_BODY_DAMAGE := 5.0   ## a flying body that breaks furniture takes this (like a wall crack)
const CLUTTER_MIN_COUNT := 30        ## breakable clutter objects in the courtyard...
const CLUTTER_MIN_KINDS := 8         ## ...of at least this many kinds
const SHELF_SPILL := Vector2i(2, 4)  ## throwable props a broken shelf drops
const RUN_THROUGH_SPEED := 6.0       ## m/s: a fighter running into glass or cardboard this fast smashes it
const RUN_THROUGH_KINDS: Array[StringName] = [&"glass", &"cardboard"]

# --- Structure (agent D) ----------------------------------------------------------
const PLATFORM_SKIRT_SURFACE := &"wood"  ## the platform's four faces break (deck stays walkable)
const PARTITION_MIN := 2             ## free-standing partitions (drywall or glass) in the courtyard
const COLLAPSE_DELAY := 0.15         ## s: cells left unsupported in a panel fall after this (dust first)
const PILLAR_COLLAPSE_DELAY := 0.4   ## s: a snapped pillar's overhead piece creaks, then drops
## A heavy falling piece (structure, never small debris) hitting a fighter.
const FALLING_MIN_MASS := 15.0       ## kg
const FALLING_HIT_ENERGY := Vector2(150.0, 600.0)  ## J: stagger from x, knockdown from y
const FALLING_DAMAGE := {&"stagger": 5.0, &"knockdown": 12.0}

# --- Floor and impact damage (agent D: WorldDamage autoload) -----------------------
const FLOOR_CELL := 0.5              ## m: floor damage grid
## Damage per cell accumulates for the round. Levels: 1 crack, 2 crater, 3 rubble.
const FLOOR_LEVEL_ENERGY: Array[float] = [2000.0, 5000.0, 10000.0]
const FLOOR_LEVEL_RADIUS: Array[float] = [0.6, 1.2, 1.6]  ## m of the mark at each level
const FLOOR_DECAL_MAX := 40          ## floor marks before the oldest fades
const TILE_BREAK_ENERGY := 600.0     ## J: a tile in the tiled plaza pops out as a persistent piece
## Blasts: everything breakable within the radius takes the source's energy with
## linear falloff (glass shatters, light props hop, crates crack).
const BLAST := {&"slam": 2.5, &"heavy_landing": 2.5, &"wall_break": 1.5, &"structure": 2.0}

# =============================================================================
# Round 7: Freeflow combat (docs/Round 7 — Freeflow Combat.md). Wins over every
# block above for the player's kit: moves, reactions, chains, targeting,
# defence, grabs, drive, throw, camera. Frames are 1/60 s of the fighter's OWN
# time (Tuning.frames()); times are seconds (real for input windows and
# hitstop, the fighter's own for stun). Contract: docs/ARCHITECTURE.md "Round 7".
# =============================================================================

# --- Player moves ------------------------------------------------------------------
## Per move: "f" = Vector3(startup, active, recovery on a miss) frames; "dmg";
## "react" = Fighter.react kind (&"snap" | &"spin" | &"fold" | &"lift" | &"buckle" |
## &"push" | &"knockdown" | &"launch"); "push" m; "stun" s the victim can't act
## (0 for knockdown: the ragdoll's get-up decides); "hitstop" real s (attacker
## and victim); "weight" 0..1 (FX, sound, camera punch); "tier" = the
## HitInfo.TIER_NAMES name listeners see; "guard_break": breaks a guard and tell armor;
## a move whose own "react" is &"launch" also carries "launch_speed" m/s and "launch_angle" degrees.
const R7_MOVES := {
	&"jab": {"f": Vector3(7, 3, 14), "dmg": 5.0, "react": &"snap", "push": 0.4, "stun": 0.45,
		"hitstop": 0.07, "weight": 0.2, "tier": &"flinch", "guard_break": false},
	&"cross": {"f": Vector3(9, 3, 16), "dmg": 7.0, "react": &"snap", "push": 0.6, "stun": 0.5,
		"hitstop": 0.08, "weight": 0.3, "tier": &"flinch", "guard_break": false},
	&"hook": {"f": Vector3(11, 4, 18), "dmg": 9.0, "react": &"spin", "push": 0.7, "stun": 0.6,
		"hitstop": 0.10, "weight": 0.45, "tier": &"stagger", "guard_break": false},
	&"heavy_jab": {"f": Vector3(20, 4, 18), "dmg": 10.0, "react": &"snap", "push": 1.4, "stun": 0.7,
		"hitstop": 0.12, "weight": 0.6, "tier": &"stagger", "guard_break": true},
	&"heavy_cross": {"f": Vector3(22, 4, 20), "dmg": 13.0, "react": &"snap", "push": 1.8, "stun": 0.75,
		"hitstop": 0.13, "weight": 0.7, "tier": &"stagger", "guard_break": true},
	&"heavy_hook": {"f": Vector3(24, 5, 22), "dmg": 15.0, "react": &"knockdown", "push": 1.5, "stun": 0.0,
		"hitstop": 0.14, "weight": 0.8, "tier": &"knockdown", "guard_break": true},
	&"uppercut": {"f": Vector3(12, 4, 20), "dmg": 10.0, "react": &"lift", "push": 0.3, "stun": 0.0,
		"hitstop": 0.11, "weight": 0.6, "tier": &"stagger", "guard_break": true},
	&"gut_punch": {"f": Vector3(10, 4, 20), "dmg": 8.0, "react": &"fold", "push": 0.3, "stun": 1.1,
		"hitstop": 0.12, "weight": 0.55, "tier": &"stagger", "guard_break": true},
	&"leg_kick": {"f": Vector3(10, 4, 18), "dmg": 7.0, "react": &"buckle", "push": 0.2, "stun": 0.9,
		"hitstop": 0.09, "weight": 0.45, "tier": &"stagger", "guard_break": true},
	&"front_kick": {"f": Vector3(14, 4, 22), "dmg": 10.0, "react": &"push", "push": 2.8, "stun": 0.8,
		"hitstop": 0.11, "weight": 0.65, "tier": &"stagger", "guard_break": true},
	&"roundhouse": {"f": Vector3(18, 5, 26), "dmg": 14.0, "react": &"knockdown", "push": 1.5, "stun": 0.0,
		"hitstop": 0.14, "weight": 0.85, "tier": &"knockdown", "guard_break": true},
	&"counter": {"f": Vector3(4, 3, 16), "dmg": 8.0, "react": &"push", "push": 1.2, "stun": 0.9,
		"hitstop": 0.10, "weight": 0.6, "tier": &"stagger", "guard_break": true},
	# Heavy kicks (hold the kick's button past R7_HOLD_THRESHOLD; startup counts from the press).
	&"heavy_leg_kick": {"f": Vector3(18, 4, 20), "dmg": 11.0, "react": &"buckle", "push": 0.3, "stun": 1.3,
		"hitstop": 0.12, "weight": 0.65, "tier": &"stagger", "guard_break": true},
	&"heavy_front_kick": {"f": Vector3(22, 4, 24), "dmg": 15.0, "react": &"push", "push": 4.5, "stun": 1.0,
		"hitstop": 0.14, "weight": 0.8, "tier": &"knockdown", "guard_break": true},
	&"heavy_roundhouse": {"f": Vector3(26, 5, 28), "dmg": 19.0, "react": &"launch", "push": 0.0, "stun": 0.0,
		"hitstop": 0.16, "weight": 0.95, "tier": &"launch", "guard_break": true,
		"launch_speed": 11.0, "launch_angle": 20.0},
}
## The punch button's string: 1st, 2nd, 3rd press (wraps to the 1st), and the
## heavy version of each position (still held at R7_HOLD_THRESHOLD).
const R7_PUNCH_STRING: Array[StringName] = [&"jab", &"cross", &"hook"]
## Heavy version of a move whose button is still held at R7_HOLD_THRESHOLD: the
## punch string's positions and the three kicks. Uppercut and gut punch have none.
const R7_HEAVY_OF := {&"jab": &"heavy_jab", &"cross": &"heavy_cross", &"hook": &"heavy_hook",
	&"leg_kick": &"heavy_leg_kick", &"front_kick": &"heavy_front_kick", &"roundhouse": &"heavy_roundhouse"}
const R7_HOLD_THRESHOLD := 0.2   ## real s: a press still held this long is the heavy version

# --- Payoffs: move on a victim state -> replacement result -------------------------
## R7_PAYOFFS[move][state] = {"react", optional "push", "stun", "dmg_mult",
## "launch_speed" m/s, "launch_angle" degrees up, "lift" m}. A move/state pair
## not listed uses the move's own entry. "repop" = the juggle re-pop.
const R7_PAYOFFS := {
	&"jab": {&"lift": {"react": &"repop"}},
	&"cross": {&"lift": {"react": &"repop"}},
	&"hook": {&"lift": {"react": &"repop"}},
	&"leg_kick": {&"lift": {"react": &"repop"}},
	&"heavy_jab": {&"fold": {"react": &"knockdown"}, &"buckle": {"react": &"knockdown"}, &"lift": {"react": &"repop"}},
	&"heavy_cross": {&"fold": {"react": &"knockdown"}, &"buckle": {"react": &"knockdown"}, &"lift": {"react": &"repop"}},
	&"heavy_hook": {&"fold": {"react": &"launch", "launch_speed": 9.0, "launch_angle": 25.0},
		&"buckle": {"react": &"launch", "launch_speed": 9.0, "launch_angle": 25.0}, &"lift": {"react": &"repop"}},
	&"uppercut": {&"fold": {"react": &"lift", "lift": 1.5, "dmg_mult": 1.5}, &"buckle": {"react": &"lift"},
		&"lift": {"react": &"repop"}},
	&"gut_punch": {&"buckle": {"react": &"fold"}, &"lift": {"react": &"repop"}},
	&"front_kick": {&"fold": {"react": &"launch", "launch_speed": 10.0, "launch_angle": 25.0},
		&"lift": {"react": &"launch", "launch_speed": 13.0, "launch_angle": 20.0},
		&"buckle": {"react": &"knockdown"}},
	&"roundhouse": {&"fold": {"react": &"knockdown", "dmg_mult": 1.5},
		&"lift": {"react": &"launch", "launch_speed": 15.0, "launch_angle": 12.0},
		&"buckle": {"react": &"knockdown", "dmg_mult": 1.5}},
	&"heavy_leg_kick": {&"fold": {"react": &"knockdown"}, &"lift": {"react": &"repop"}},
	&"heavy_front_kick": {&"fold": {"react": &"launch", "launch_speed": 13.0, "launch_angle": 20.0},
		&"lift": {"react": &"launch", "launch_speed": 15.0, "launch_angle": 15.0},
		&"buckle": {"react": &"launch", "launch_speed": 10.0, "launch_angle": 25.0}},
	&"heavy_roundhouse": {&"fold": {"react": &"launch", "launch_speed": 13.0, "launch_angle": 15.0},
		&"lift": {"react": &"launch", "launch_speed": 18.0, "launch_angle": 10.0},
		&"buckle": {"react": &"launch", "launch_speed": 13.0, "launch_angle": 15.0}},
}

# --- Reactions (Fighter.react) --------------------------------------------------------
const R7_LIFT_HEIGHT := 1.0      ## m the uppercut pops the feet above the floor
const R7_LIFT_PEAK_TIME := 0.35  ## s to the peak (sets the pop's gravity: g = 2h / t^2)
const R7_REPOP_HEIGHT := 0.5     ## m a juggle re-pop adds above the current height
const R7_JUGGLE_MAX := 2         ## re-pops per lift; past it the body falls into a knockdown
const R7_PUSH_SLIDE_SHARE := 0.4 ## the push slides over this share of the stun
const R7_PUSH_STEP_FROM := 1.0   ## m: pushes this long add stumble steps
const R7_HEAVY_PUSH_MULT := 0.6  ## heavy enemies (Fighter.is_heavy)
const R7_HEAVY_STUN_MULT := 0.75
const R7_HEAVY_LIFT_MULT := 0.6
const R7_SEVER_ON_KILL := 0.35   ## chance a killing launch or drive slam severs a limb

# --- Chains and the input buffer -----------------------------------------------------------
const R7_CHAIN_CUT := 0.5        ## on a hit the buffered press starts after this share of recovery
const R7_CHAIN_GRACE := 0.3      ## s after recovery in which the chain (and punch string) stays alive
## Anti-infinite (replaces COMBO_ESCAPE_HITS / COMBO_STUN_DECAY_FROM / COMBO_STUN_DECAY / COMBO_STUN_MIN for player strikes).
const R7_COMBO_ESCAPE_HITS := 10
const R7_COMBO_STUN_DECAY_FROM := 6
const R7_COMBO_STUN_DECAY := 0.1
const R7_COMBO_STUN_MIN := 0.6

# --- Freeflow targeting and the auto-follow ---------------------------------------------------
const R7_TARGET_RANGE := 6.0     ## m
const R7_TARGET_CONE := 70.0     ## degrees each side of the stick (or camera forward)
const R7_TARGET_KEEP_EXTRA := 2.0 ## m beyond R7_TARGET_RANGE before the combat target clears
const R7_GLIDE_FROM := 0.6       ## m beyond the move's reach before a glide starts
const R7_GLIDE_SPEED := 11.0     ## m/s
const R7_GLIDE_MAX_TIME := 0.35  ## s
const R7_FOLLOW_MAX_PUSH := 1.5  ## m: pushes up to this get the follow step
const R7_FOLLOW_SHARE := 0.8     ## of the push the attacker follows during recovery
const R7_CONNECT_MARGIN := 0.5   ## m beyond reach in which the target still connects on the first active frame

# --- Hit feel ----------------------------------------------------------------------------------
const R7_PLAYER_HITSTOP_MAX := 0.16  ## replaces PLAYER_HITSTOP_MAX
const R7_CAM_PUNCH_FOV := 4.0    ## degrees x weight
const R7_CAM_PUNCH_TRAUMA := 0.25 ## x weight
## Launch payoffs slow time: SLOW_TIME[&"finisher"] (TimeDirector requests it from hit_landed).

# --- Defence: counter and dodge -------------------------------------------------------------------
const R7_COUNTER_WINDOW := 0.4   ## real s before an enemy strike's first active frame (and through its active frames)
const R7_COUNTER_INVULN := 0.45  ## real s from the press
const R7_COUNTER_GLIDE := 3.0    ## m: the counter glides to an attacker this far away
const R7_COUNTER_WHIFF_LOCK := 0.4 ## real s after a press with no counterable window
const R7_TELL_MARGIN := 0.1      ## s every enemy strike's tell lasts beyond R7_COUNTER_WINDOW
const R7_DODGE_DIST := 2.5       ## m
const R7_DODGE_TIME := 0.22      ## s
const R7_DODGE_INVULN := 0.25    ## s from the press
const R7_DODGE_COOLDOWN := 0.2   ## s after a dodge ends

# --- Grab, drive, throw ------------------------------------------------------------------------------
const R7_GRAB_GLIDE := 3.0       ## m: a grab glides to a target this far away
const R7_HOLD_MAX := 3.0         ## s of clinch before the victim struggles out (driving resets it)
const R7_DRIVE_START_SPEED := 4.0  ## m/s
const R7_DRIVE_MAX_SPEED := 9.5    ## m/s
const R7_DRIVE_RAMP_TIME := 1.0    ## s from start to max (ease-out)
const R7_DRIVE_TURN_RATE := 120.0  ## degrees/s
const R7_DRIVE_MAX_TIME := 3.0     ## s, then the body is thrown forward at the current speed
const R7_DRIVE_MASS_SHARE := 0.5   ## of the player's mass added to the victim's for slam energy
const R7_DRIVE_MIN_SPEED := 3.0    ## m/s the drive keeps at least after breaking through
const R7_DRIVE_SLAM_MIN_SPEED := 3.0 ## m/s: slower contacts are only a shove (stagger, hold ends)
const R7_DRIVE_BREAK_DAMAGE := 8.0
const R7_DRIVE_SLAM_DAMAGE := 10.0
const R7_DRIVE_SLAM_DAMAGE_PER_MS := 2.0
const R7_DRIVE_SLAM_HITSTOP := 0.12
const R7_DRIVE_BOWL_DAMAGE := 6.0
const R7_DRIVE_BOWL_KEEP := 0.85   ## of the drive speed kept after bowling an enemy
const R7_THROW_SPEED_MIN := 8.0    ## m/s: a tap
const R7_THROW_SPEED_MAX := 18.0   ## m/s: a full wind-up
const R7_THROW_WINDUP_FULL := 0.7  ## s
const R7_THROW_PITCH := 8.0        ## degrees up
const R7_THROW_ASSIST_CONE := 20.0 ## degrees

# --- Camera ------------------------------------------------------------------------------------------
const R7_CAM_LEAN := 0.25          ## share of the way the look-at leans toward the combat target
const R7_CAM_AUTO_YAW_RATE := 40.0 ## degrees/s at most, only to keep the player and target on screen
const R7_CAM_DRIVE_FOV := 8.0      ## degrees added while driving
const R7_CAM_DRIVE_PULLBACK := 1.0 ## m
const R7_CAM_DRIVE_DROP := 0.3     ## m lower
const R7_CAM_THROW_ZOOM_FOV := 5.0 ## degrees narrower at a full wind-up

# --- Round 7 amendment (user, 2026-11-03): the god path ---------------------------------
# Jump, wall run, vault/mantle, teleport, pursuit and the Battering Ram stay.
# Teleport and pursuit are free (cooldowns and the chain cap only); the Focus
# meter is gone. Upgrades are the debug settings above (speed cap, ram level,
# teleport, pursuit chain). See the doc's "God path" section.
const R7_TELEPORT_WINDOW := 0.2    ## real s: a Dash press this close before an enemy attack's first active frame teleports (else it dodges)
const R7_TELEPORT_COOLDOWN := 0.6  ## real s between teleports
## Pursuit: Dash within PURSUIT_WINDOW after a launch the player caused, stick
## neutral or toward the body: teleport next to it (PURSUIT_DIST, hang
## PURSUIT_HANG) and the next attack press is the pursuit hit. The stick at that
## press decides: pulled back toward the camera (deflected 0.3 or more, within
## 60 degrees of straight back) spikes the body down into the floor; otherwise it
## relaunches along camera forward.
const R7_PURSUIT_RELAUNCH_SPEED := 15.0 ## m/s (heavies x HEAVY_LAUNCH_MULT; never under the body's current speed; cap LAUNCH_SPEED_MAX)
const R7_PURSUIT_RELAUNCH_ANGLE := 20.0 ## degrees up
const R7_PURSUIT_DAMAGE := 10.0
const R7_SPIKE_SPEED := 18.0       ## m/s straight down (5 degrees of camera-forward drift)
const R7_SPIKE_DAMAGE := 14.0      ## plus the floor impact
const R7_SPIKE_BLAST_RADIUS := 2.5 ## m: the spike's floor impact staggers enemies and blasts breakables in this radius
## Sprint strikes: a strike committed at speed v >= SPEED_BONUS_FROM (6 m/s)
## toward its target (wall-run strikes and vault drops count as the speed cap).
## Punches and the leg kick push x (1 + R7_SPRINT_PUSH_PER_MS x (v - 6)) and become
## at least a &"push"; heavies, front kick, roundhouse and uppercut LAUNCH at
## R7_SPRINT_LAUNCH_BASE + R7_SPRINT_LAUNCH_PER_MS x (v - 6) m/s (cap LAUNCH_SPEED_MAX).
const R7_SPRINT_PUSH_PER_MS := 0.25
const R7_SPRINT_LAUNCH_BASE := 8.0
const R7_SPRINT_LAUNCH_PER_MS := 1.5
const R7_SPRINT_LAUNCH_ANGLE := 22.0
## Battering Ram level 3 launch: runner speed x this, angle up.
const R7_RAM_LAUNCH_SHARE := 1.3
const R7_RAM_LAUNCH_ANGLE := 25.0
## Ground cracks at speed: sprinting at or above this cracks the floor under each footstep (WorldDamage.damage_floor).
const R7_SPEED_CRACK_FROM := 10.0  ## m/s (the first upgraded cap)
