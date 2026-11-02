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
		"hp": 1000.0, "mass": 70.0, "ragdoll": "active",
		"appearance": {"height": 1.0, "width": 1.0, "skin": Color(0.87, 0.69, 0.55),
			"shirt": Color(0.12, 0.35, 0.85), "pants": Color(0.12, 0.12, 0.16), "accessory": &"none"},
	},
	&"grunt": {
		"hp": 150.0, "mass": 70.0, "ragdoll": "passive",
		"appearance": {"height": 0.97, "width": 1.0, "skin": Color(0.78, 0.58, 0.45),
			"shirt": Color(0.55, 0.52, 0.45), "pants": Color(0.25, 0.25, 0.22), "accessory": &"none"},
		"moves": [&"e_hook", &"e_kick"],
	},
	&"brawler": {
		"hp": 250.0, "mass": 80.0, "ragdoll": "passive",
		"appearance": {"height": 1.02, "width": 1.12, "skin": Color(0.6, 0.42, 0.3),
			"shirt": Color(0.75, 0.45, 0.1), "pants": Color(0.2, 0.18, 0.15), "accessory": &"bandana"},
		"moves": [&"e_hook", &"e_heavy", &"e_grab"],
		"blocks_jabs": true, "grab_blocker_after": 1.0,
	},
	&"shield": {
		"hp": 300.0, "mass": 85.0, "ragdoll": "passive",
		"appearance": {"height": 1.03, "width": 1.1, "skin": Color(0.7, 0.55, 0.42),
			"shirt": Color(0.3, 0.32, 0.36), "pants": Color(0.15, 0.15, 0.18), "accessory": &"shield"},
		"moves": [&"e_hook", &"e_heavy"],
		"front_block": true,
	},
	&"brute": {
		"hp": 600.0, "mass": 140.0, "ragdoll": "active",
		"appearance": {"height": 1.18, "width": 1.45, "skin": Color(0.55, 0.4, 0.32),
			"shirt": Color(0.45, 0.08, 0.08), "pants": Color(0.12, 0.1, 0.1), "accessory": &"armor"},
		"moves": [&"e_heavy", &"e_charge", &"e_grab"],
		"throw_speed": 14.0,
		"armor_bonus": 1,
	},
	&"duelist": {
		"hp": 750.0, "mass": 65.0, "ragdoll": "active",
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
		"hp": 150.0, "mass": 70.0, "ragdoll": "passive",
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
const DASH_MOMENTUM_TIME := 0.35 ## s after a dash during which speed still feeds a hit
const DASH_COOLDOWN := 0.35
const GRAVITY := 20.0            ## m/s^2 for capsules (ragdolls use project gravity)

# --- Damage (spec: Mode and rules) -----------------------------------------
const DMG_JAB := 15.0
const DMG_SWEEP := 30.0
const DMG_KICK := 60.0
const DMG_POWER_MIN := 50.0
const DMG_POWER_MAX := 120.0
const DMG_COUNTER := 90.0
const DMG_THROW := 40.0
const DMG_ENEMY := {&"e_hook": 60.0, &"e_heavy": 100.0, &"e_kick": 80.0, &"e_grab": 40.0,
	&"e_charge": 120.0, &"e_throw_debris": 50.0}
const BLOCK_DAMAGE_MULT := 0.2   ## block cuts damage 80%

const IMPACT_MIN_ENERGY := 500.0  ## J
const IMPACT_DAMAGE_DIV := 20.0   ## (E - 500) / 20
const IMPACT_DAMAGE_MAX := 300.0
## Per flight (one launch until recovery): the 2nd+ impact deals x0.5, and the
## flight's total impact damage is capped. Keeps one wall slam from deciding a duel.
const IMPACT_REPEAT_MULT := 0.5
const IMPACT_FLIGHT_CAP := 200.0

static func impact_damage(energy: float) -> float:
	if energy <= IMPACT_MIN_ENERGY:
		return 0.0
	return minf((energy - IMPACT_MIN_ENERGY) / IMPACT_DAMAGE_DIV, IMPACT_DAMAGE_MAX)

# --- Launch speeds (m/s of the victim's body) -------------------------------
const LAUNCH_UP_ANGLE := 12.0     ## degrees above horizontal for strikes
## Standing sparta kick. 8.6 (not the spec's 8.0) because the launch is tilted
## LAUNCH_UP_ANGLE up and contact loses ~7%: measured speed into a wall is then
## ~8 m/s, so a standing kick breaks drywall as the spec intends (~2,300 J).
const KICK_LAUNCH := 8.6
const POWER_LAUNCH_MID := 9.5     ## power punch at 50% charge
const POWER_LAUNCH_FULL := 13.0   ## power punch at full charge
const POWER_STAGGER_BELOW := 0.5  ## charge fraction under which power punch only staggers
const COUNTER_LAUNCH := 16.0      ## teleport counter, fixed
const THROW_SPEED := 12.0
const THROW_UP_ANGLE := 15.0
const SPEED_POWER_K := 0.6        ## J += k * M_attacker * max(0, v . d)
const SWEEP_SPIN := 9.0           ## rad/s spin added to shins on a sweep
const ENEMY_LAUNCH := {&"e_heavy": 9.0, &"e_kick": 10.0, &"e_charge": 14.0}

# --- Hitstop, real seconds (spec: Game feel) --------------------------------
const HITSTOP := {&"jab": 0.05, &"sweep": 0.07, &"power_min": 0.09, &"power_max": 0.15,
	&"kick": 0.12, &"counter": 0.16, &"throw": 0.08, &"grab_break": 0.1, &"enemy": 0.09}

# --- Defence (spec: Perfect dodge and teleport counter) ----------------------
const PERFECT_DODGE_WINDOW := 8.0 / 60.0    ## real s before first active frame
const DODGE_ATTEMPT_HORIZON := 20.0 / 60.0  ## a press counts as an attempt if an attack goes active within this
const DODGE_LOCKOUT := 20.0 / 60.0
const VANISH_INVULN := 0.25
const DODGE_SLOWMO_SCALE := 0.3
const DODGE_SLOWMO_TIME := 0.25
const COUNTER_BEHIND_DIST := 1.2
const COUNTER_COOLDOWN := 1.5
const AIR_RECOVERY_AFTER := 0.4
const GETUP_INVULN := 0.5         ## player
const ENEMY_GETUP_INVULN := 0.25  ## enemies: short, so punts and follow-ups stay possible

# --- Focus ------------------------------------------------------------------
const FOCUS_START := 1.0
const FOCUS_MAX := 3.0
const FOCUS_PERFECT_DODGE := 0.5
const FOCUS_LAUNCH_LANDS := 0.25
const FOCUS_GRAB_BREAK := 0.5
const FOCUS_COST := 1.0  ## teleport counter, pursuit, air recovery, reversal

# --- Pursuit ----------------------------------------------------------------
const PURSUIT_WINDOW := 0.5     ## s after a launch
const PURSUIT_HALF_AT := 3      ## the 3rd relaunch of one body in one flight gets half impulse

# --- Grab (spec: Grab, throw and grab break) --------------------------------
const GRAB_RANGE := 1.3
const GRAB_HOLD_MAX := 1.0
const GRAB_BREAK_EARLY := 6.0 / 60.0   ## before the enemy grab becomes active
const GRAB_BREAK_LATE := 10.0 / 60.0   ## after it connects
const GRAB_REVERSAL_LATE := 4.0 / 60.0
const GRAB_BREAK_PUSH := 1.5           ## m apart
const GRAB_BREAK_STAGGER := 20.0 / 60.0
const GRAB_WALK_MULT := 0.5

# --- Ragdoll states ---------------------------------------------------------
const GROUNDED_SPEED := 0.5      ## m/s pelvis speed
const GROUNDED_HOLD := 0.4       ## s under that speed
const GROUNDED_TIMEOUT := 3.0    ## s after first landing, whatever the speed
const GETUP_BLEND := 0.3       ## ragdoll -> get-up blend (round 2: get-up totals ~0.8 s)
const STAGGER_TIP_ANGLE := 35.0  ## degrees pelvis tilt -> launch
const FLINCH_TIME := 0.3

# --- AI (spec: Enemies and AI) ----------------------------------------------
const TOKENS := [1, 2]           ## [easy, normal]
const NEAR_RING := Vector2(2.5, 4.0)
const FAR_RING := Vector2(6.0, 9.0)
const ONSCREEN_BEFORE_TOKEN := 0.4
const TELL_MIN := 0.35
const TELL_MAX := 0.6
const SWING_SPACING := 0.25
const ATTACK_INTERVAL := Vector2(2.0, 3.0)
const MAX_ENEMIES_ON_FIELD := 5

# --- Rounds -----------------------------------------------------------------
const WAVES := [
	{&"grunt": 4},
	{&"grunt": 3, &"brawler": 2},
	{&"brawler": 2, &"shield": 1, &"thrower": 1},
	{&"brute": 1, &"grunt": 3},
]
const HEAL_BETWEEN_WAVES := 0.2
const CORPSE_FADE_AFTER := 20.0
const CORPSE_MAX := 6

# --- Impact resolution (spec: Impact resolution) ----------------------------
const CRACK_FRACTION := 0.35
const SURFACES := {
	&"drywall": {"break_energy": 2000.0, "absorption": 0.3},
	&"brick": {"break_energy": 7500.0, "absorption": 0.45},
	&"concrete": {"break_energy": INF, "absorption": 0.0, "decal_from": 5000.0},
	&"wood": {"break_energy": 1200.0, "absorption": 0.2},
}
const BOWL_FLINCH_BELOW := 600.0
const BOWL_LAUNCH_ABOVE := 1500.0
const BOWL_SPEED_SHARE := 0.5
const BOWL_CHAIN_MAX := 4

# --- Budgets ----------------------------------------------------------------
const DEBRIS_MAX := 150
const DEBRIS_FREEZE_AFTER := 4.0
const DEBRIS_FADE_AFTER := 10.0
const DECAL_MAX := 256
const ACTIVE_RAGDOLL_MAX := 4

# --- Slow motion (spec: Game feel) ------------------------------------------
const SLOWMO_BUDGET_FRACTION := 0.15  ## of any 10 s window, KO excepted
const SLOWMO_BUDGET_WINDOW := 10.0
const SLOWMO_EASE := 0.15
const WALL_BREAK_SLOWMO := Vector2(0.25, 0.35)  ## (scale, real seconds)
const BIG_LAUNCH_SLOWMO := Vector2(0.35, 0.5)
const BIG_LAUNCH_ENERGY := 6000.0  ## lowered from 9,000 so counters and dash kicks get slow motion
const KO_SLOWMO := Vector2(0.2, 1.0)

# --- Camera (Upgrade 2: Camera fixes) ----------------------------------------
const CAM_MIN_DIST := 2.2        ## m; was 3.0. The camera never gets closer.
const CAM_MAX_DIST := 9.0
const CAM_COMBAT_DIST := Vector2(3.5, 7.0)  ## m: pulls back as token holders spread out
const CAM_PLAYER_OFFSET_X := -0.1  ## player sits this fraction of the screen width left of centre
const CAM_PITCH_RANGE := Vector2(-35.0, 20.0)  ## degrees (negative looks down)
## In play the camera never follows a flying body: a launch or throw sending a
## body more than CAM_WIDEN_TRIGGER m widens the frame instead, for at most CAM_WIDEN_TIME.
const CAM_WIDEN_TRIGGER := 6.0
const CAM_WIDEN_PULLBACK := 2.0  ## m, at most
const CAM_WIDEN_FOV := 8.0       ## degrees, at most
const CAM_WIDEN_TIME := 1.2      ## s, at most
const CAM_MOUSE_IDLE := 1.0      ## s after the last camera input before auto-rotation
const CAM_RETURN_TIME := 0.5     ## s to ease back behind the player
const CAM_MODE_GAP := 0.75       ## s: at most one camera mode change per this
const CAM_MODE_BLEND := 0.25     ## s per mode blend
const CAM_TARGET_TURN := 90.0    ## degrees per s on a soft-target change
const CAM_BLOCKER_ALPHA := 0.25  ## walls, props, rubble and ragdolls in the way fade to this
## Kill-cam only (player not in control): follow a flying body.
const FOLLOW_CAM_SPEED := 10.0
const FOLLOW_CAM_TIME := 1.5
const KILLCAM_WALLS := 3         ## a flight through this many walls earns a replay
const FINISHER_CLOSEUP := Vector3(0.6, 2.0, 0.3)  ## (real s, m from the target, time scale)

# --- Input model (Upgrade 2: tap to combo, hold to charge) --------------------
const HOLD_THRESHOLD := 0.15     ## s: released before = tap, still held = charge (main feel setting)
const CHARGE_LEVELS: Array[float] = [0.15, 0.4, 0.8]  ## s held to reach level 1, 2, 3
const CHARGE_DAMAGE: Array[float] = [1.0, 1.4, 2.0, 3.0]  ## damage x by level 0..3
const CHARGE_AUTO_RELEASE := 1.5 ## s: a held button never locks the fighter
const CHARGE_WALK: Array[float] = [1.0, 0.6, 0.6, 0.4]    ## walk speed x by level 0..3
const BUFFER_FRAMES := 10.0      ## a press in the last N frames of recovery fires the next move
const STRING_RESET := 0.4        ## s after a move ends with no press: the string resets
const COMBO_DROP := 1.0          ## s without a landed hit ends the combo count

# --- Crouch and jump (Upgrade 2) -----------------------------------------------
const CROUCH_HEIGHT := 1.1       ## m capsule (standing 1.8)
const CROUCH_SPEED := 0.4        ## walk x
const JUMP_APEX := 0.9           ## m; with GRAVITY 20 this is 0.6 s in the air (v0 = 6 m/s)
const JUMP_AIR_TIME := 0.6
const JUMP_AIR_STEER := 0.5      ## of walk control while airborne
const JUMP_LAND_FRAMES := 6.0
const AIR_COUNTER_LAUNCH := 1.25 ## launch x on a fighter hit while jumping

# --- Combos (Upgrade 2) ----------------------------------------------------------
const JUGGLE_LAUNCH := 1.3       ## launch x on a tumbling/airborne/stumbling victim, flattened toward the nearest wall
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
const STUMBLE_TIME := 0.6        ## tap sweep: off balance, cannot attack or block
const TRIP_TIME := 0.5           ## charged sweep L1-2: off their feet, tumble at hip height
const LAUNCHER_LIFT := 1.5       ## m: uppercut, L3 sweep
const UPWARD_THROW_LIFT := 2.0   ## m: grab, back + release
const DAZED_TIME := 1.5          ## hunched, no actions; the next hit always launches
const DAZE_BLOCKED_HITS := 3     ## hits on a blocking enemy that daze it

# --- Body zones and grabs (Upgrade 2) ----------------------------------------------
const ZONE_HEAD_DAMAGE := 1.3
const ZONE_LEG_SLOW := 0.3       ## enemy walk -30%...
const ZONE_LEG_SLOW_TIME := 3.0  ## ...for this long
const ARM_BREAK_AT := 100.0      ## zone damage on one arm
const ARM_DRAG_BREAK_MULT := 0.7 ## arm drags give the victim a 30% shorter break window
const WALL_SLAM_RANGE := 1.5     ## m from a wall/pillar when the grab connects
const WALL_SLAM_SPEED := 9.0     ## m/s head first into it (~2,800 J for 70 kg)

# --- Focus (Upgrade 2: the world slows, you don't) --------------------------------
## Units are bars: FOCUS_MAX (3.0) is three bars.
const FOCUS_SCALE := 0.3         ## world time scale while Focus is held
const FOCUS_MIN_START := 0.5     ## bars needed to start
const FOCUS_DRAIN := 0.4         ## bars per real second (1 bar per 2.5 s)
const FOCUS_KILL := 0.25         ## bars per kill
const FOCUS_PURSUIT_CHAIN := 3   ## pursuits on one body inside one Focus burst

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
const SEVER_ENERGY := 4000.0
enum Gore { OFF, BLOOD, DISMEMBER }
static var gore: int = Gore.DISMEMBER
