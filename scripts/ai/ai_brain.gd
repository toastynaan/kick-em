class_name AIBrain
extends Node
## Enemy controller: one per enemy Fighter, behaviour chosen by archetype.
## OWNER: agent C (AI). Added as a child of the enemy Fighter by FighterFactory.
##
## Round 5 roster (Feel Reference: Enemy types; Waves uses these three):
## - grunt (75 kg): jab-cross string (e_jab then e_hook), front kick (e_kick),
##   grab (e_grab, blue glow). Circles and takes tokens. Guards
##   Tuning.GUARD_TAP_CHANCE of tapped punches aimed at him
##   (GameEvents.strike_started; is_tapped_strike).
## - stick (75 kg): swing (e_stick_swing), thrust (e_stick_thrust), reach
##   2.2 m, keeps about 3 m away. Holds a stick (this brain's mesh on the right
##   hand); a stagger or more drops it as a ThrowableProp &"stick" and he
##   fights on unarmed with the grunt's moves.
## - heavy (110 kg): overhead smash (e_heavy), shoulder charge (e_charge, from
##   range, blue glow: uncounterable), grab and slam (e_grab_slam, blue glow).
##   B gives his wind-ups tell armor.
## Duel mode: the Duelist reads the player's strikes and guards them (Block
## held, the AI guard; more often against a repeated move), answers a broken
## guard with a quick hook (e_hook), punishes whiffs and whiffed Counters,
## feints, and vanish-steps when he cannot reach the player. Round 7 removed
## his parry and teleport counter. Legacy archetypes (brawler, shield, brute,
## thrower) keep working for their tests.
##
## Readability (Feel Reference: Enemies have to be readable first; Round 7):
## every move starts with AttackDirector.enemy_startup_s(move) of startup,
## never under AttackDirector.tell_min_frames() (the counter window plus
## Tuning.R7_TELL_MARGIN); the director spaces the two token holders' first
## active frames; TellGlint makes the attacking limb glow from wind-up to first
## active frame, orange (Counter) or blue (dodge only). While the player is
## knocked down a holder takes Tuning.DOWNED_FREE_SWINGS free swing; the rest
## wait in the ring.
##
## Limb loss (F10, GameEvents.limb_severed): lost an arm, it fights on
## one-handed at Tuning.ARM_LOST_DAMAGE_MULT damage (get_damage_mult) above
## Tuning.LIMB_LOST_FLEE_HP and limps away at or below it; lost a leg, it
## crawls away at Tuning.CRAWL_SPEED and never attacks. Fleeing enemies take
## no tokens, emit GameEvents.fleeing_changed, use P's limp / crawl
## locomotion, and a ground strike finishes them.
##
## Flow: ENTRY walks entry_path into the courtyard, then FIGHT. In FIGHT the
## enemy circles the player in its ring (Tuning.CIRCLE_RING; NEAR when next
## in line), strafes, keeps ~1.6 m from other enemies and slides along walls
## (the nav grid routes round walls, low walls, crates and the platform;
## bodies on the floor are walkable). A NEAR enemy (or one the player walked
## up to) asks for a token; with one it closes to the move's range, asks the
## director for a spaced swing (request_swing) and starts the attack, or
## gives the token back after GIVE_UP_TIME. It never acts while down, in
## hitstun, held or in a Round 7 reaction (Fighter.is_reacting / is_lifted:
## no attack, no token request, a held token goes back; Round 8: a tap's
## flinch keeps it, below), pauses briefly after
## a get-up, and walks back into its ring after being pushed or launched away.
## It never tries to break a grab once the clinch has connected, nor while
## the holder drives it (Carry.is_driving).
##
## Round 8 (docs/Round 8 — Charge and Pressure.md: Pressure). The brain reads
## its pressure p (CombatController.get_pressure_fraction, get_pressure()):
## - guards (the grunt's tap guard, the Duelist's read) x (1 - p), and x
##   Tuning.R8_LEVEL_BLOCK_MULT for its level (Fighter.level; block_mult());
## - the time between its attacks x (1 + p) (the interval runs 1 / (1 + p) as fast);
## - tells Tuning.R8_PRESSURE_TELL_SLOW x p s longer, never under the tell floor;
## - from Tuning.R8_PRESSURE_BACK_OFF a free enemy (not mid-attack, not about
##   to swing a token it holds) backs off BACK_OFF_STEP m and circles there
##   instead of trading, and re-engages as its pressure drains (_update_back_off).
## Broken open (is_broken: B's is_broken, H's &"broken" reaction) it does
## nothing: no attack, no guard, no token; after GameEvents.pressure_recovered
## it fights on normally. A tap's flinch (react &"flinch", about 0.2 s) is
## shrugged off: it keeps its token and its move, and walks in and swings
## again the tick it can act (_while_flinching).

signal attack_launched(move_id: StringName)
## Duelist vanish step done (round 2.5): reappeared at `spot`.
signal vanish_stepped(spot: Vector3)

enum Mode { ENTRY, FIGHT }

# --- Local tuning (candidates for Tuning) ------------------------------------
const ENTRY_REACH := 0.6            ## m: entry waypoint reached
const ENTRY_POINT_TIMEOUT := 5.0    ## s stuck on one waypoint before skipping it
const SEPARATION := 1.6             ## m kept between enemies
const SEPARATION_WEIGHT := 1.6
const PLAYER_SPACE := 1.3           ## m a non-attacking enemy keeps from the player
const ARRIVE_RADIUS := 0.9          ## m: slow down inside this of a steering target
const WALL_PROBE := 1.0             ## m look-ahead ray
const WALL_PROBE_HEIGHT := 0.6      ## m above the floor
const WHISKER_ANGLE := 0.6          ## rad, side rays
const BOUNDS_MARGIN := 1.0          ## m kept inside the courtyard bounds
const DEFAULT_BOUNDS_HALF := 10.0   ## m, courtyard half size when no arena
const GIVE_UP_TIME := 2.0           ## s to reach range and swing with a token before releasing it
const ROUTE_BLOCKED_TIME := 0.75    ## s the straight line must stay blocked before routing via waypoints
const ROUTE_REPLAN := 0.5           ## s between waypoint searches while routing
const GETUP_PAUSE := 0.6            ## s after a get-up before attacking again
const REQUEST_RETRY := 0.25         ## s between refused token requests
## s between attacks for a lone enemy (duel), start to start. Round 5: every
## Duelist hit now flinches or staggers the player instead of launching him,
## so he is open again sooner; a slightly longer gap keeps a readable rhythm
## (about one attack per 1.2-2.5 s of open play).
const LONE_INTERVAL := Vector2(0.8, 1.7)
const REQUEST_MAX_DIST := 6.0       ## m: closer than this before asking for a melee token (it must arrive within GIVE_UP_TIME)
const FACE_TOLERANCE := 0.8         ## dot(forward, to player) needed to swing
const FACE_WAIT_MAX := 0.35         ## s: swing anyway if turning takes longer
const START_FAIL_MAX := 30          ## refused start_enemy_attack calls before giving up the token
## Centre-to-centre distance at which each move starts. Stick moves reach
## 2.2 m (archetype "reach"); they start a little inside it.
const MOVE_RANGE := {&"e_jab": 1.3, &"e_hook": 1.4, &"e_kick": 1.6, &"e_heavy": 1.6, &"e_grab": 1.05,
	&"e_grab_slam": 1.1, &"e_stick_swing": 2.0, &"e_stick_thrust": 2.1,
	&"e_charge": 5.5, &"e_throw_debris": 11.0, &"e_sweep": 1.45}
## Minimum distance for ranged / charging moves.
const MOVE_MIN_RANGE := {&"e_charge": 2.6, &"e_throw_debris": 3.5}
## Move weights per archetype. Round 5 roster: the grunt's e_jab is the
## jab-cross string (STRINGS), the heavy also charges from range (_pick_move).
## Legacy archetypes keep their Upgrade 2 height mix (HIGH e_hook / e_grab,
## MID e_kick / e_heavy, LOW e_sweep once MoveLibrary has it).
const MOVE_MIX := {
	&"grunt": {&"e_jab": 0.5, &"e_kick": 0.3, &"e_grab": 0.2},
	&"stick": {&"e_stick_swing": 0.55, &"e_stick_thrust": 0.45},
	&"heavy": {&"e_heavy": 0.6, &"e_grab_slam": 0.4},
	&"brawler": {&"e_hook": 0.4, &"e_heavy": 0.35, &"e_sweep": 0.25},
	&"shield": {&"e_hook": 0.55, &"e_heavy": 0.45},
	&"brute": {&"e_heavy": 0.7, &"e_grab": 0.3},
	&"duelist": {&"e_hook": 0.25, &"e_kick": 0.2, &"e_heavy": 0.15, &"e_grab": 0.15, &"e_sweep": 0.25},
	&"thrower": {&"e_hook": 0.6, &"e_kick": 0.4},
}
## Strings: the moves that follow a move while its holder keeps the token
## (the grunt's jab-cross: e_jab, then e_hook as the cross).
const STRINGS := {&"e_jab": [&"e_hook"]}
## A Round 5 move B's MoveLibrary does not have yet is swapped for its nearest
## older move, so the roster fights before every move lands.
const MOVE_FALLBACK := {&"e_jab": &"e_hook", &"e_stick_swing": &"e_hook",
	&"e_stick_thrust": &"e_kick", &"e_grab_slam": &"e_grab"}
## Grabs: blue glow, need both hands.
const GRAB_MOVES: Array[StringName] = [&"e_grab", &"e_grab_slam"]
## Hit heights when MoveLibrary has no entry (MoveData.hit_level is the source).
const MOVE_LEVEL_FALLBACK := {&"e_jab": HitInfo.Level.HIGH, &"e_hook": HitInfo.Level.HIGH,
	&"e_grab": HitInfo.Level.HIGH, &"e_grab_slam": HitInfo.Level.HIGH,
	&"e_stick_swing": HitInfo.Level.HIGH, &"e_stick_thrust": HitInfo.Level.MID,
	&"e_kick": HitInfo.Level.MID, &"e_heavy": HitInfo.Level.MID, &"e_charge": HitInfo.Level.MID,
	&"e_throw_debris": HitInfo.Level.MID, &"e_sweep": HitInfo.Level.LOW}
const MAX_SAME_LEVEL := 2           ## no third attack in a row at one height
## Moves a fighter with a broken arm still uses (kicks, the shoulder charge).
const ARM_FREE_MOVES: Array[StringName] = [&"e_kick", &"e_sweep", &"e_charge"]
## Easy difficulty: s added to every enemy startup.
const EASY_TELL_BONUS := 0.05
const SPEED_MULT := {&"shield": 0.65, &"brute": 0.75, &"heavy": 0.85}
const BRAWLER_GUARD_DIST := 3.0
const SHIELD_GUARD_DIST := 4.5      ## m: the Shield raises its guard inside this
const SHIELD_CLOSE_GUARD := 2.4     ## m: with a token, guard only this close (or if the player swings)
const SHIELD_REQUEST_DIST := 3.6    ## m: the slow Shield asks for a token only this close
## Rings. Waiting enemies circle in Tuning.CIRCLE_RING (Sifu 3, 5-30 s): the
## next in line on its inner part, the rest further out, as a fraction across
## the band. The Duelist (alone) and the legacy Thrower keep their old rings.
const CIRCLE_NEAR_BIAS := Vector2(0.0, 0.3)
const CIRCLE_FAR_BIAS := Vector2(0.4, 1.0)
const OLD_RING_ARCHETYPES: Array[StringName] = [&"duelist", &"thrower"]
## Ring radius as a fraction across the ring band, per archetype (old rings).
const RING_BIAS := {&"duelist": Vector2(0.05, 0.3), &"thrower": Vector2(0.4, 0.8)}
const STRAFE_SPEED := {&"duelist": 0.55}
const STRAFE_NEAR := 0.3
const STRAFE_FAR := 0.22
const STRAFE_SWITCH := Vector2(1.5, 3.0)
const DUELIST_STRAFE_SWITCH := Vector2(0.6, 1.4)
const SPREAD_ANGLE_NEAR := deg_to_rad(55.0)
const SPREAD_ANGLE_FAR := deg_to_rad(40.0)
const TAUNT_INTERVAL := Vector2(4.0, 9.0)
const TAUNT_HOLD := 1.2
## m: a player this close to a waiting (FAR) enemy that is on screen engages it.
const ENGAGE_DIST := 3.0
# Round 5: guarding the player's tapped strikes (GameEvents.strike_started).
const TAP_GUARD_AFTER := 0.25       ## s a tap guard is held past the strike's first active frame
## s one tap guard spell lasts at most, however long the string goes on: then
## the guard drops and a token holder swings (block, then punish), so a
## player who keeps punching never turns an enemy into a turtle.
const TAP_GUARD_MAX := 0.9
# Round 5: strings, the downed player, heavies.
const STRING_WAIT_MAX := 0.35       ## s a string's follow-up may wait for a spaced slot before it is dropped
const STRING_RANGE_SLACK := 0.7     ## m beyond the follow-up's range it still swings (the jab's lunge closed in)
## The free swing at a knocked-down player: moves that reach a body on the floor, best first.
const DOWNED_MOVES: Array[StringName] = [&"e_kick", &"e_stick_swing", &"e_heavy", &"e_stick_thrust"]
const HEAVY_CHARGE_FROM := 3.2      ## m: a heavy this far away may shoulder-charge...
const HEAVY_CHARGE_CHANCE := 0.45   ## ...this often (it knocks the player down: keep it a threat, not a habit)
# Round 5: breaking the player's grab (Carry asks wants_grab_break in the
# Tuning.GRAB_BREAK_FRAMES window of a neutral grab). The doc gives no rate;
# G's fallback is 0.3. Heavies are strong, a stick enemy's hands are busy.
const GRAB_BREAK_CHANCE := {&"grunt": 0.25, &"stick": 0.2, &"heavy": 0.5, &"duelist": 0.6,
	&"brawler": 0.35, &"brute": 0.5, &"shield": 0.25, &"thrower": 0.15}
const GRAB_BREAK_GUARD_BONUS := 0.15    ## guard up when caught: alert
const GRAB_BREAK_REPEAT_WINDOW := 4.0   ## s: grabs on him inside this...
const GRAB_BREAK_REPEAT_BONUS := 0.1    ## ...each make the next break likelier (anti-spam)...
const GRAB_BREAK_CAP := 0.75            ## ...up to this
# Round 5: limb loss.
## m/s limping away (lost an arm at <= Tuning.LIMB_LOST_FLEE_HP). The doc gives no
## number: a hurt walk well under the player's 4.5 m/s, so he can be caught.
const LIMP_SPEED := 1.4
const FLEE_STEP := 3.0              ## m ahead of a fleeing enemy its steering target sits
const FLEE_REST_DIST := 8.0         ## m from the player a fleeing enemy stops and cowers
# Round 5: the stick enemy's stick (own mesh on the right hand attachment).
const STICK_LENGTH := 0.95          ## m
const STICK_RADIUS := 0.026         ## m at the butt (the tip is 85%)
const STICK_GRIP := 0.2             ## m from the butt end to the fist
const STICK_TILT := 25.0            ## degrees the stick points down from the fist's forward axis
const STICK_COLOR := Color(0.42, 0.27, 0.13)
const STICK_GLOW_ENERGY := 3.0      ## emission while it winds up (the tell glow)
## Added to the hand's velocity when he drops it (m/s along the hit, m/s up):
## the stick visibly flies out of his hand instead of sliding off.
const STICK_DROP_TOSS := Vector2(1.5, 1.8)
const STICK_MASS := 0.7             ## kg, only when ThrowableProp builds nothing itself
const HAND_SPEED_MAX := 12.0        ## m/s cap on the tracked hand velocity
# Duelist (Round 7: guards, answers a broken guard with a hook; no parry, no teleport)
## The read: a player strike aimed at him (within READ_RANGE, the player facing
## him) is guarded with the archetype's "dodge_chance" (its read chance,
## [easy, normal]) plus MASH_BONUS per repeat of the same move.
const READ_RANGE := 3.0             ## m: only strikes aimed at us are read
const READ_FACING := 0.5            ## dot(player forward, to us)
## s a read guard is held past the strike's first active frame: long enough
## that the rest of a string meets it (each read strike extends it).
const GUARD_AFTER_ACTIVE := 0.6
## The move that answers a broken guard (Round 7: the Duelist hooks).
const GUARD_BREAK_ANSWER := {&"duelist": &"e_hook"}
## s after a broken guard's stun (or get-up) in which the answer may still
## start. The player is never swung at in hitstun, so the answer goes the
## moment he can be attacked again.
const ANSWER_WINDOW := 1.6
## While the answer waits for its turn, the Duelist closes to this share of
## its hook's range, so the hook comes the moment the player can be hit.
const ANSWER_CLOSE_IN := 0.8
const MASH_WINDOW := 2.0            ## s: repeats of the same player move inside this raise the read chance
const MASH_BONUS := 0.15            ## read chance added per repeat
const MASH_CAP := 0.85
const PUNISH_RANGE := 3.0
const PUNISH_WINDOW := 0.6
const FEINT_INTERVAL := Vector2(3.0, 5.5)
const FEINT_TIME := 0.45
const FEINT_RADIUS := 1.9
const STUCK_CHECK := 1.0            ## s between stuck checks
## Stuck metric (Round 6 acceptance: no enemy stuck for more than 3 s): over
## each STALL_WINDOW in which the enemy was free to move and asked for at
## least STALL_MIN_SPEED, covering under STALL_SHARE of the asked distance
## counts as stalled; stuck_time is the run of stalled windows.
const STALL_WINDOW := 0.5
const STALL_MIN_SPEED := 0.6        ## m/s asked
const STALL_SHARE := 0.25
## Stalled this long: re-test the grid round it, drop its path and detour
## the other way (a corner of clutter the grid had wrong).
const STALL_ESCALATE := 1.5
const STALL_BACKOFF := 0.45         ## s of the escalation's straight back-out (then it re-plans)
const STALL_PENALTY_RADIUS := 0.7   ## m of grid made costly round the wedge (AINavGrid.penalize)
const STUCK_MOVE := 0.25            ## m moved per check below which we are stuck
const DETOUR_TIME := 0.8
const NEAR_JOIN_INTERVAL := Vector2(0.3, 0.8)  ## s: max wait after moving up to the NEAR ring
## Crowd enemies use Tuning.ATTACK_INTERVAL x this, start to start (the
## director's pacing keeps the crowd at one grant per 1-1.5 s on Normal).
const CROWD_INTERVAL_MULT := 0.5
const ENTRY_FIGHT_DIST := 4.0       ## m: an entering enemy inside the courtyard turns to fight this close
const PLAYER_OUTSIDE_GROW := 2.5    ## m: play area margin around a player outside the courtyard
const OUTSIDE_RETURN_TIME := 2.5    ## s outside the courtyard before walking a spawn path back in
const OUTSIDE_MARGIN := 0.5         ## m beyond the bounds that counts as outside
const SIDE_ROUTE_BLOCKED := 0.15    ## s blocked before trying a side point round a pillar
const SIDE_ROUTE_OFFSETS := [1.2, 2.0, 2.8]  ## m sideways probed for a clear way round
# Enemy throws (round 2): aim the grab's throw at a wall in front, never at enemies.
const THROW_WALL_RANGE := 8.0       ## m: walls searched in front of the grabber
const THROW_FAN := 4                ## rays each side of forward, 15 degrees apart
const THROW_LANE := 1.0             ## m: an enemy this close to the throw line blocks it
# Thrower rubble
const RUBBLE_SEARCH := 8.0          ## m: large debris searched around the Thrower
const RUBBLE_REACH := 1.1           ## m: close enough to pick a chunk up
const FETCH_TIMEOUT := 4.0          ## s walking to a chunk before giving up on it
const FETCH_COOLDOWN := 3.0         ## s before trying rubble again after a failed fetch
const CLEAR_RADIUS := 0.24          ## m: radius of the capsule swept by _clear_line
const CLEAR_HEIGHT := 1.5           ## m: its height (bottom ~0.2 m above the floor)
const CLEAR_CENTER := 0.95          ## m: its centre above the floor
const HEAD_PROBE_RISE := 0.8        ## m above WALL_PROBE_HEIGHT for the second forward ray
## m below WALL_PROBE_HEIGHT for a third forward ray: Round 6 clutter as low as
## 0.45 m (benches, coffee tables, boxes) sits under the waist ray.
const LOW_PROBE_DROP := 0.35
const SPOT_RADIUS := 0.45           ## m: free radius a steering target needs
const BODY_CLEARANCE := 0.32        ## m: wall hits closer than this to the movement line block it (~body radius)
const RANGE_SLACK := 0.4            ## m added to a move's range once the approach stalls
## Round 7 stalled approach: a token holder that has gained less than
## STALL_PROGRESS on a standing player for STALL_TIME (something it cannot
## pass: the clutter the player was knocked onto, a body, a corner) swings
## anyway when within STALL_SWING_REACH of its move's range, with its normal
## tell (the counter window applies as always). A player moving away more than
## STALL_PLAYER_MOVE in that time is a chase, never a stall.
const STALL_TIME := 0.5
const STALL_PROGRESS := 0.15        ## m
const STALL_PLAYER_MOVE := 0.3      ## m
const STALL_SWING_REACH := 1.0      ## m beyond the move's range
# Navigation (AINavGrid via AttackDirector)
const NAV_REPLAN := 0.6             ## s between path re-plans
const NAV_GOAL_MOVE := 1.0          ## m the goal may move before an early re-plan
const NAV_LOOKAHEAD := 8            ## path points checked for a clear shortcut
const NAV_LOOK_EVERY := 0.06        ## s between shortcut checks (and only on this brain's slot tick)
const NAV_STUCK := 1.2              ## s without progress along a path before a local grid refresh
const WIDE_DETOUR_MAX := 2.0        ## m a wide-layer way may be longer than the normal one and still be taken
## Periodic path work (re-plans, shortcut checks) runs only on ticks where
## (physics frame + slot) % SLOT_STRIDE == 0, so up to 8 enemies never
## re-plan on the same tick (perf: ~1 ms spikes when they lined up).
const SLOT_STRIDE := 8
const UNREACHABLE_WAIT := 1.5       ## s before asking again after the player proved unreachable
# Duelist vanish step (free, BT3 flavour) when it cannot reach an open player
const VSTEP_NO_PROGRESS := 2.5      ## s without getting VSTEP_PROGRESS closer
const VSTEP_PROGRESS := 0.5         ## m
const VSTEP_PATH_LEN := 14.0        ## m: a longer path triggers it at once
const VSTEP_MIN_DIST := 2.2         ## m: closer than this it just walks
const VSTEP_RADII: Array[float] = [2.5, 1.8, 3.2]  ## m from the player, in order of preference
const VSTEP_HIDE := 0.12            ## s hidden before the teleport
const VSTEP_SHOW := 0.05            ## s after reappearing before it acts
const VSTEP_COOLDOWN := 6.0
# Round 8: backing off under pressure (the doc says "backs off"; distances are ours).
const BACK_OFF_STEP := 2.0          ## m a pressured enemy backs off beyond where it stood
const BACK_OFF_MAX_RADIUS := 6.0    ## m from the player it backs off to at most
## s a back-off lasts at most. Pressure drains well before this (1.5 s after
## the last hit, then Tuning.R8_PRESSURE_DECAY of max per s), so it only
## guards against running away forever; it then waits for a new hit.
const BACK_OFF_MAX_TIME := 4.0

## Tests: >= 0 seeds every brain's RNG (seed + its slot) for reproducible soaks.
static var test_seed := -1

var fighter: Fighter
## Path into the arena: the enemy walks these points in order after spawning,
## then fights. Set by the spawner (GameMode) before or right after add_child.
var entry_path: PackedVector3Array = PackedVector3Array()

var mode := Mode.ENTRY
## Attacks this brain has started (tests, debugging).
var attacks_started := 0
## Tests: force the Duelist's read (guard) chance (negative = use Tuning).
var read_chance_override := -1.0
## Tests: force the grab-break chance (negative = GRAB_BREAK_CHANCE rules).
var grab_break_override := -1.0
var _grabbed_at: Array[float] = []  ## game times the player caught us (anti-spam)
## Tap guards raised (tests, debugging).
var tap_guards := 0
## Free swings started at a knocked-down player (tests).
var downed_swings := 0
## The ThrowableProp this stick enemy dropped (tests; null until then).
var dropped_stick: Node3D = null

var _rng := RandomNumberGenerator.new()
var _time := 0.0
var _path_index := 0
var _entry_point_time := 0.0
var _interval_left := 1.0
var _has_move := false
var _move_id: StringName = &""
var _approach_time := 0.0
var _in_range_time := 0.0
var _start_failures := 0
var _resume_at := 0.0
var _was_down := false
var _want_guard := false
var _block_down := false
var _guard_until := 0.0             ## game time a Duelist read guard is held until
var _player_block_time := 0.0
var _player_attacking := false
var _ring_bias := 0.5
var _near_bias := 0.2
var _strafe_sign := 1.0
var _strafe_timer := 0.0
var _taunt_timer := 0.0
var _taunt_until := 0.0
var _feint_timer := 0.0
var _feint_until := 0.0
var _answer_pending := false        ## Duelist: a broken guard waits for its hook
var _answer_deadline := INF         ## game time; INF until he can act again after the break
var _punish_until := 0.0
var _watched_player: Fighter = null
var _stuck_timer := 0.0
var _stuck_pos := Vector3.ZERO
var _stuck_intent := 0.0
var _detour_until := 0.0
var _detour_dir := Vector3.ZERO
var _bounds := AABB()
var _bounds_age := INF
var _was_near := false
var _attack_started_at := -INF
var _route_point := Vector3.INF
var _side_sign := 1.0
var _side_locked := false
var _best_dist := INF              ## closest the current approach got to the player
var _progress_best := INF          ## stalled approach: distance at the last real progress...
var _progress_at := 0.0            ## ...the game time of it...
var _progress_player := Vector3.ZERO  ## ...and where the player stood then
## Attacks started from a stalled approach beyond the move's range, and the
## distance of the last attack start (tests, debugging).
var stall_swings := 0
var last_start_dist := 0.0
var _steer_in := Vector3.ZERO       ## debug: steering before / after avoidance
var _steer_out := Vector3.ZERO
var _sweep_params := PhysicsShapeQueryParameters3D.new()
var _spot_params := PhysicsShapeQueryParameters3D.new()
var _route_age := INF
var _blocked_time := 0.0
var _nav_points := PackedVector3Array()
var _nav_age := INF
var _entry_interrupted := false
var _outside_time := 0.0
var _player_moves: Array = []       ## [game time, move family] of recent player attacks
var _aim_timer := 0.0
var _aim_set := false
var _has_chunk := false             ## Thrower holds a picked-up debris chunk
var _fetch_target: RigidBody3D = null
var _fetch_scan := 0.0
var _fetch_started := 0.0
var _fetch_cooldown_until := 0.0
## Duelist (tests, debugging): strikes read and guarded, guards broken
## (a player hit landed through the raised guard), hooks started answering one.
var guard_reads := 0
var guard_breaks := 0
var guard_answers := 0
## Duelist vanish steps taken (tests, debugging).
var vanish_steps := 0
var _arm_broken := false
var _recent_levels: Array[int] = []
## Length of the current nav path (m; INF when the grid found none).
var nav_path_length := 0.0
## The grid says the current goal cannot be reached on foot.
var nav_unreachable := false
var _unreachable_until := 0.0
var _nav_path := PackedVector3Array()
var _nav_goal := Vector3.INF
var _npath_age := INF
var _nav_index := 0
var _nav_target := Vector3.ZERO
var _nav_look_age := INF
var _nav_best := INF
var _nav_progress_at := 0.0
var _vstep_until := 0.0
var _vstep_done := true
var _vstep_spot := Vector3.ZERO
var _vstep_ready_at := 0.0
var _vstep_best := INF
var _vstep_progress_at := 0.0
# Round 5
var _slot := 0                      ## AttackDirector.claim_slot(): spreads periodic work over ticks
var _string_rest: Array[StringName] = []  ## the current string's moves still to come
var _following := false             ## the current move is a string's follow-up
var _turn_downed := false           ## the current turn's move was picked for a downed player
var _tell_move: StringName = &""    ## move being started this tick (TellGlint reads it)
var _flee: StringName = &""         ## &"" | &"limp" | &"crawl"
var _lost_arm := {}                 ## &"left" / &"right" -> true
var _lost_leg := false
var _tap_guard_until := -INF        ## game time a tap guard is held until
var _tap_guard_since := -INF        ## game time the current tap guard spell began
var _stick: MeshInstance3D = null
var _stick_mat: StandardMaterial3D = null
var _hand_prev := Vector3.INF
var _hand_vel := Vector3.ZERO
## Stuck metric: current and longest run of stalled time (s), where the longest happened.
var stuck_time := 0.0
var max_stuck_time := 0.0
var max_stuck_at := Vector3.ZERO
var _sw_t := 0.0                    ## s into the current stall window
var _sw_free := 0.0                 ## s of it free to move
var _sw_asked := 0.0                ## m asked over it
var _sw_start := Vector3.INF
var _next_escalate := STALL_ESCALATE  ## stuck_time at which the next escalation fires
var _backoff_until := 0.0
var _wide := false                  ## body wider than AINavGrid.BODY_RADIUS: always takes a wide way when one exists
# Round 8: pressure
var backoffs := 0                   ## back-offs started (tests, soaks)
var flinch_shrugs := 0              ## taps' flinches shrugged off with the token kept (tests, soaks)
var pressure_breaks := 0            ## GameEvents.pressure_broken on us (tests, soaks)
var _backing_off := false
var _backoff_since := 0.0
var _backoff_radius := 0.0          ## m from the player kept while backing off
var _backoff_spent_p := INF         ## a back-off timed out at this pressure: none again until it rises
var _turn_flinched := false         ## the current token turn was flinched by a tap
var _in_flinch := false             ## flinching now (counts each flinch once)

func _ready() -> void:
	# Body-sized checks: a hole knocked into a wall at waist height must not
	# read as a way through.
	var sweep := CapsuleShape3D.new()
	sweep.radius = CLEAR_RADIUS
	sweep.height = CLEAR_HEIGHT
	_sweep_params.shape = sweep
	_sweep_params.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
	var spot := CapsuleShape3D.new()
	spot.radius = SPOT_RADIUS
	spot.height = maxf(CLEAR_HEIGHT, SPOT_RADIUS * 2.0)
	_spot_params.shape = spot
	_spot_params.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE
	fighter = get_parent() as Fighter
	fighter.brain = self
	# Round 6: sweeps sized to this body (a heavy is wider than the grid's
	# test body and wedges in gaps a grunt slips through; paths prefer the
	# grid's wide layer, _nav_route).
	var body_r := CLEAR_RADIUS + 0.04
	if fighter.capsule != null and fighter.capsule.shape is CapsuleShape3D:
		body_r = (fighter.capsule.shape as CapsuleShape3D).radius
	sweep.radius = maxf(CLEAR_RADIUS, body_r - 0.04)
	_wide = body_r > AINavGrid.BODY_RADIUS + 0.04
	_slot = AttackDirector.claim_slot()
	if test_seed >= 0:
		_rng.seed = hash(test_seed * 7919 + _slot)
	else:
		_rng.randomize()
	if fighter.archetype in OLD_RING_ARCHETYPES:
		var bias: Vector2 = RING_BIAS.get(fighter.archetype, Vector2(0.2, 0.7))
		_ring_bias = _rng.randf_range(bias.x, bias.y)
		_near_bias = _rng.randf_range(bias.x, bias.y)
	else:
		_ring_bias = _rng.randf_range(CIRCLE_FAR_BIAS.x, CIRCLE_FAR_BIAS.y)
		_near_bias = _rng.randf_range(CIRCLE_NEAR_BIAS.x, CIRCLE_NEAR_BIAS.y)
	_strafe_sign = 1.0 if _rng.randf() < 0.5 else -1.0
	_strafe_timer = _rng.randf_range(STRAFE_SWITCH.x, STRAFE_SWITCH.y)
	_taunt_timer = _rng.randf_range(TAUNT_INTERVAL.x, TAUNT_INTERVAL.y)
	_feint_timer = _rng.randf_range(FEINT_INTERVAL.x, FEINT_INTERVAL.y)
	_interval_left = _rng.randf_range(0.4, 1.2)
	if fighter.combat:
		fighter.combat.attack_ended.connect(_on_attack_ended)
	GameEvents.counter_whiffed.connect(_on_counter_whiffed)
	GameEvents.arm_broken.connect(_on_arm_broken)
	GameEvents.attack_whiff.connect(_on_attack_whiff)
	GameEvents.strike_started.connect(_on_strike_started)
	GameEvents.limb_severed.connect(_on_limb_severed)
	GameEvents.hit_landed.connect(_on_hit_landed)
	GameEvents.fighter_died.connect(_on_fighter_died)
	GameEvents.pressure_broken.connect(_on_pressure_broken)
	GameEvents.pressure_recovered.connect(_on_pressure_recovered)
	AttackDirector.register_enemy(fighter)
	if _armed_archetype():
		_build_stick()

func _exit_tree() -> void:
	if fighter and is_instance_valid(fighter):
		AttackDirector.unregister_enemy(fighter)

## In the courtyard and fighting (entry walk done).
func is_fighting() -> bool:
	return mode == Mode.FIGHT

func get_move_id() -> StringName:
	return _move_id if _has_move else &""

## Distance from the player within which this enemy can take its turn soon
## (AttackDirector puts enemies further out behind closer ones in line).
func get_line_reach() -> float:
	if fighter.archetype == &"thrower":
		return MOVE_RANGE[&"e_throw_debris"] + 1.0
	return AttackDirector.LINE_FAR

# --- Round 5 contract -----------------------------------------------------------

## Lost a limb and limping or crawling away: no attack tokens, never attacks;
## a ground strike finishes him.
func is_fleeing() -> bool:
	return _flee != &""

## Lost a leg: crawling (on the floor; ground-strike target).
func is_crawling() -> bool:
	return _flee == &"crawl"

## &"" | &"limp" | &"crawl"
func get_flee_style() -> StringName:
	return _flee

## Multiplier on this enemy's move damage: Tuning.ARM_LOST_DAMAGE_MULT once it
## fights one-handed. B applies it.
func get_damage_mult() -> float:
	return Tuning.ARM_LOST_DAMAGE_MULT if not _lost_arm.is_empty() else 1.0

## Lost an arm (&"left" / &"right") or a leg.
func has_lost_arm(side := &"") -> bool:
	return _lost_arm.has(side) if side != &"" else not _lost_arm.is_empty()

func has_lost_leg() -> bool:
	return _lost_leg

## G's Carry: the player caught us in a neutral grab; true = press Grab in
## the break window (both pushed apart). Never while stunned, dazed,
## stumbling, reacting, down or fleeing; never once the clinch has connected
## (the grabber holds the body) or while the grabber drives us; per archetype
## GRAB_BREAK_CHANCE, more with the guard up, more for each recent grab on us
## (spamming grabs gets broken).
func wants_grab_break(grabber: Fighter) -> bool:
	if not can_try_grab_break(grabber):
		return false
	return _rng.randf() < grab_break_chance(true)

## Round 7: a grab can still be broken: the clinch has not connected yet (the
## grabber is not holding the body) and the grabber is not driving.
func can_try_grab_break(grabber: Fighter) -> bool:
	if grabber == null or not is_instance_valid(grabber) or grabber.carry == null:
		return true
	var c := grabber.carry
	return not c.is_driving() and not c.is_holding_body()

## The chance wants_grab_break() rolls now. `record` notes this grab for the
## anti-spam bonus.
func grab_break_chance(record := false) -> float:
	var repeats := 0
	var kept: Array[float] = []
	for t in _grabbed_at:
		if _time - t <= GRAB_BREAK_REPEAT_WINDOW:
			kept.append(t)
			repeats += 1
	if record:
		kept.append(_time)
	_grabbed_at = kept
	if fighter.is_dead() or fighter.is_down() or is_fleeing():
		return 0.0
	if fighter.is_reacting() or fighter.is_lifted() or is_broken():
		return 0.0  # Round 7: a reacting body connects at once (Round 8: a broken one too)
	var c := fighter.combat
	if c != null and (c.is_hit_stunned() or (c.has_method(&"is_dazed") and c.is_dazed()) \
			or (c.has_method(&"is_stumbling") and c.is_stumbling())):
		return 0.0
	if grab_break_override >= 0.0:
		return grab_break_override
	var p: float = GRAB_BREAK_CHANCE.get(fighter.archetype, 0.25)
	if _block_down:
		p += GRAB_BREAK_GUARD_BONUS
	return minf(p + GRAB_BREAK_REPEAT_BONUS * repeats, GRAB_BREAK_CAP)

## The move this brain is starting on this tick (TellGlint reads it; &"" otherwise).
func get_tell_move() -> StringName:
	return _tell_move

## A stick enemy still holding his stick.
func has_stick() -> bool:
	return _stick != null and is_instance_valid(_stick)

## The stick mesh in his hand (null once dropped).
func get_weapon_mesh() -> MeshInstance3D:
	return _stick if has_stick() else null

## TellGlint: the stick glows with the hand while a stick attack winds up.
func set_weapon_glow(color: Color, on: bool) -> void:
	if _stick_mat == null:
		return
	_stick_mat.emission_enabled = on
	_stick_mat.emission = color
	_stick_mat.emission_energy_multiplier = STICK_GLOW_ENERGY

## One-line state for debug overlays and test logs.
func get_debug_text() -> String:
	return "mode=%d move=%s token=%s ring=%d approach=%.2f in_range=%.2f interval=%.2f resume_in=%.2f fails=%d guard=%s can_act=%s attacking=%s flee=%s steer=%s->%s route=%s side=%+.0f%s" % [
		mode, get_move_id(), AttackDirector.has_token(fighter), AttackDirector.get_ring(fighter),
		_approach_time, _in_range_time, _interval_left, maxf(_resume_at - _time, 0.0), _start_failures,
		_block_down, fighter.can_act(), _is_attacking(), _flee, _steer_in.snapped(Vector3.ONE * 0.01),
		_steer_out.snapped(Vector3.ONE * 0.01), "-" if _route_point == Vector3.INF else str(_route_point.snapped(Vector3.ONE * 0.01)),
		_side_sign, " locked" if _side_locked else ""] + " blocked=%.2f pos=%s" % [_blocked_time, _pos().snapped(Vector3.ONE * 0.1)] \
		+ " p=%.2f backoff=%s broken=%s" % [get_pressure(), _backing_off, is_broken()]

# --- Round 8: pressure -----------------------------------------------------------

## The pressure fraction p, 0..1 (1 while broken): CombatController.get_pressure_fraction().
func get_pressure() -> float:
	if fighter == null or fighter.combat == null:
		return 0.0
	return clampf(fighter.combat.get_pressure_fraction(), 0.0, 1.0)

## Broken open by pressure (AttackDirector.is_enemy_broken): it does nothing.
func is_broken() -> bool:
	return fighter != null and AttackDirector.is_enemy_broken(fighter)

## Backing off under pressure (_update_back_off): it asks for no token.
func is_backing_off() -> bool:
	return _backing_off

## The share of its guards and reads this enemy still makes: x (1 - p), and x
## Tuning.R8_LEVEL_BLOCK_MULT for its level (higher levels block more). 0 while broken.
func block_mult() -> float:
	if is_broken():
		return 0.0
	var mults := Tuning.R8_LEVEL_BLOCK_MULT
	return (1.0 - get_pressure()) * mults[clampi(fighter.level - 1, 0, mults.size() - 1)]

## The share of tapped strikes aimed at it that it guards now: the
## archetype's "guard_chance" (grunts: Tuning.GUARD_TAP_CHANCE) x block_mult().
func get_guard_chance() -> float:
	return clampf(float(fighter.config.get("guard_chance", 0.0)) * block_mult(), 0.0, 1.0)

## B: our pressure broke (dazed and open for Tuning.R8_BREAK_TIME). The guard
## drops, a pending answer, punish, move or string goes, and the token goes
## back (the director sees is_enemy_broken too). It does nothing until it
## can act again; pressure_recovered then clears what pressure left.
func _on_pressure_broken(f: Node3D, _attacker: Node3D) -> void:
	if f != fighter or fighter.is_dead():
		return
	pressure_breaks += 1
	_want_guard = false
	_guard_until = 0.0
	_tap_guard_until = -INF
	_apply_guard()
	_answer_pending = false
	_punish_until = 0.0
	_has_move = false
	_following = false
	_string_rest.clear()
	_backing_off = false
	if AttackDirector.has_token(fighter) and not _is_attacking():
		AttackDirector.release_token(fighter)

## B: the break is over and the meter is empty: it fights on normally.
func _on_pressure_recovered(f: Node3D) -> void:
	if f != fighter:
		return
	_backing_off = false
	_backoff_spent_p = INF
	_turn_flinched = false

## Round 8: from Tuning.R8_PRESSURE_BACK_OFF a free enemy (not mid-attack,
## not about to swing a token it holds: _about_to_swing) backs off instead of
## trading: BACK_OFF_STEP m beyond where it stood (at most
## BACK_OFF_MAX_RADIUS from the player), circling out there (_do_ring) and
## asking for no token. A token it is still closing in with goes back, and a
## pending answer or punish is dropped. It re-engages once its pressure
## drains below the line, or after BACK_OFF_MAX_TIME (then not again until a
## new hit raises its pressure). True while it backs off this tick.
func _update_back_off(player: Fighter) -> bool:
	var p := get_pressure()
	var line := Tuning.R8_PRESSURE_BACK_OFF
	if _backing_off and (p < line or _time - _backoff_since > BACK_OFF_MAX_TIME):
		_backing_off = false
		_backoff_spent_p = p if p >= line else INF
	if not _backing_off:
		if p < line:
			_backoff_spent_p = INF
			return false
		if is_finite(_backoff_spent_p):
			if p <= _backoff_spent_p + 1e-4:
				_backoff_spent_p = minf(_backoff_spent_p, p)  # still draining: no new hit yet
				return false
			_backoff_spent_p = INF
		if _is_attacking() or _about_to_swing(player):
			return false
		_backing_off = true
		_backoff_since = _time
		_backoff_radius = minf(_dist_to(player) + BACK_OFF_STEP, BACK_OFF_MAX_RADIUS)
		backoffs += 1
	if _is_attacking():
		return false
	_answer_pending = false
	_punish_until = 0.0
	if AttackDirector.has_token(fighter):
		_give_up_token()
	return true

## A token holder about to use it trades even under pressure: a string's
## next hit, or its move in range. One still closing in, or one a tap
## flinched this turn, is free to back off.
func _about_to_swing(player: Fighter) -> bool:
	if not AttackDirector.has_token(fighter) or _turn_flinched:
		return false
	if _following:
		return true
	return _has_move and _dist_to(player) <= float(MOVE_RANGE.get(_move_id, 1.5)) + RANGE_SLACK

## Round 8: a tap's flinch is shrugged off (AttackDirector.is_flinching and
## keeps_turn: nothing worse on top of it).
func _shrugging_off() -> bool:
	return AttackDirector.is_flinching(fighter) and AttackDirector.keeps_turn(fighter)

## A tap's flinch (about 0.2 s): it stands for it and keeps its token, its
## move and its place; the tick it can act it walks in and swings again (a
## wind-up the tap cut short starts over). The flinch got through its guard:
## the guard drops.
func _while_flinching() -> void:
	_want_guard = false
	_guard_until = 0.0
	_tap_guard_until = -INF
	_apply_guard()
	_answer_deadline = INF
	_fetch_target = null
	if AttackDirector.has_token(fighter):
		if not _in_flinch:
			flinch_shrugs += 1
		_turn_flinched = true
	_in_flinch = true

# --- Main loop ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if fighter == null or not is_instance_valid(fighter) or not fighter.is_inside_tree():
		return
	_time += delta
	_tell_move = &""
	_track_hand(delta)
	_track_stall(delta)
	if fighter.is_dead():
		_on_dead()
		return
	if not AttackDirector.is_registered(fighter):
		AttackDirector.register_enemy(fighter)  # e.g. after AttackDirector.reset()
	var player := _get_player()
	_watch_player(player)
	_update_flee()
	if _is_disabled():
		_while_disabled()
		return
	_in_flinch = false
	if _was_down:
		_was_down = false
		_resume_at = _time + GETUP_PAUSE
	if mode == Mode.ENTRY and not is_fleeing():
		_do_entry(delta)
		_apply_guard()
		return
	if is_fleeing():
		_do_flee(player)
		_apply_guard()
		return
	if player == null or player.is_dead():
		_want_guard = false
		fighter.move_input = Vector3.ZERO
		_apply_guard()
		return
	_track_player(delta, player)
	_update_throw_aim(delta)
	var backing := _update_back_off(player)  # Round 8: under pressure it backs off instead of trading
	if _answer_pending and _tick_answer(player):
		_apply_guard()
		return
	if _tick_vanish_step(player):
		_apply_guard()
		return
	if not _is_attacking() and _check_outside(delta):
		_apply_guard()
		return
	if _is_attacking():
		_want_guard = false
		fighter.move_input = Vector3.ZERO
		if not _carrying():
			_face(player.get_ground_position())
	elif AttackDirector.has_token(fighter):
		_do_token_turn(delta, player)
	else:
		_has_move = false
		_following = false
		_turn_flinched = false
		_string_rest.clear()
		_do_ring(delta, player)
		if not backing:
			_tick_request(delta, player)
	_apply_guard()

func _is_disabled() -> bool:
	var disabled := _is_impaired()
	if fighter.is_down():
		_was_down = true
	if disabled and mode == Mode.ENTRY:
		_entry_interrupted = true
	return disabled

## Down, in hitstun, held, in a Round 7 reaction (snap, spin, fold,
## buckle, push, lifted, a tap's flinch) or broken open by pressure (no side effects).
func _is_impaired() -> bool:
	return fighter.is_down() or fighter.is_in_hitstun() or AttackDirector.is_enemy_impaired(fighter)

func _is_attacking() -> bool:
	if fighter.combat == null:
		return false
	return fighter.combat.is_attacking() or _carrying()

## Holding the player through G's Carry (an enemy grab connected).
func _carrying() -> bool:
	return fighter.carry != null and fighter.carry.is_holding()

## Down, stunned, held, reacting or broken: no moves, no turn, no token
## request; a token not yet used for an attack goes back. A Duelist's answer
## to a broken guard waits (its deadline starts once he can act again).
## Round 8: a tap's flinch keeps the turn (_while_flinching).
func _while_disabled() -> void:
	fighter.move_input = Vector3.ZERO
	if _shrugging_off():
		_while_flinching()
		return
	# Keep a raised guard through blockstun; drop it when down, held or
	# reacting, or when it was broken (_on_guard_broken).
	if fighter.is_down() or (fighter.carry and fighter.carry.is_held()) \
			or fighter.is_reacting() or fighter.is_lifted() or is_broken():
		_want_guard = false
		_guard_until = 0.0
		_tap_guard_until = -INF
	if not _want_guard:
		_apply_guard()  # only ever lowers it here
	_has_move = false
	_following = false
	_string_rest.clear()
	_answer_deadline = INF
	_fetch_target = null
	if AttackDirector.has_token(fighter) and not _is_attacking():
		AttackDirector.release_token(fighter)

func _on_dead() -> void:
	fighter.move_input = Vector3.ZERO
	_want_guard = false
	_answer_pending = false
	_apply_guard()
	if has_stick():
		_drop_stick(Vector3.ZERO)
	AttackDirector.unregister_enemy(fighter)
	set_physics_process(false)

# --- Entry -------------------------------------------------------------------

func _do_entry(delta: float) -> void:
	if _path_index >= entry_path.size():
		_enter_fight()
		return
	# Already in the courtyard and attacked, or the player is right here: fight.
	if _inside_courtyard(0.5):
		var player := _get_player()
		if _entry_interrupted or (player and _dist_to(player) < ENTRY_FIGHT_DIST):
			_enter_fight()
			return
	var target := entry_path[_path_index]
	var to := _flat(target - _pos())
	if to.length() < ENTRY_REACH:
		_path_index += 1
		_entry_point_time = 0.0
		return
	_entry_point_time += delta
	if _entry_point_time > ENTRY_POINT_TIMEOUT:
		_path_index += 1
		_entry_point_time = 0.0
		return
	var last := _path_index == entry_path.size() - 1
	var goal := target
	if not _clear_line(_pos(), target):
		if _waiting_for_breach(target):
			# Behind a wall that is being breached (YardBuilder.breach): wait
			# for it to burst instead of pushing into it.
			_entry_point_time = 0.0
			fighter.move_input = Vector3.ZERO
			fighter.face_dir = to.normalized()
			return
		# Round 6: a hole's edge, clutter or a shoved prop in the way: the
		# grid routes round it (entries were straight lines before).
		goal = _route(target, target)
	var gto := _flat(goal - _pos())
	var dir := gto.normalized() if gto.length() > 0.05 else to.normalized()
	var v := dir * (clampf(to.length() / ARRIVE_RADIUS, 0.3, 1.0) if last else 1.0)
	v += _separation() * 0.5
	if _time < _backoff_until:
		v = _detour_dir
	elif _time < _detour_until:
		v = v * 0.3 + _detour_dir
	v = _avoid_walls(v, 0.7)
	_check_stuck(v)
	_set_move(v)
	if v.length() > 0.05:
		fighter.face_dir = _flat(v).normalized()

## The straight line to `target` hits a wall that is being breached
## (meta &"staged_breach", not broken yet) and has no hole on this line.
func _waiting_for_breach(target: Vector3) -> bool:
	var space := fighter.get_world_3d().direct_space_state
	var from := _pos() + Vector3.UP * CLEAR_CENTER
	var to := Vector3(target.x, from.y, target.z)
	var q := PhysicsRayQueryParameters3D.create(from, to, Layers.WORLD | Layers.DESTRUCTIBLE, [fighter.get_rid()])
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return false
	var n := hit["collider"] as Node
	for i in 3:
		if n == null:
			return false
		if n.has_meta(&"staged_breach"):
			return not bool(n.get(&"is_broken"))
		n = n.get_parent()
	return false

func _enter_fight() -> void:
	mode = Mode.FIGHT
	_bounds_age = INF
	_stuck_pos = _pos()
	_entry_interrupted = false
	_outside_time = 0.0

func _inside_courtyard(margin: float) -> bool:
	return _point_in_courtyard(_pos(), margin)

func _point_in_courtyard(p: Vector3, margin: float) -> bool:
	var b := get_courtyard_bounds()
	return p.x > b.position.x + margin and p.x < b.end.x - margin \
		and p.z > b.position.z + margin and p.z < b.end.z - margin

## Knocked out of the courtyard (through a wall into a room): after a while,
## walk back along the nearest visible spawn path.
func _check_outside(delta: float) -> bool:
	if AttackDirector.nav_ready():
		return false  # the nav grid routes back in by itself
	var player := _get_player()
	var player_outside := player != null and not _point_in_courtyard(player.get_ground_position(), 0.0)
	if _inside_courtyard(-OUTSIDE_MARGIN) or player_outside:
		_outside_time = 0.0
		return false
	_outside_time += delta
	if _outside_time < OUTSIDE_RETURN_TIME:
		return false
	_outside_time = 0.0
	var path := _return_path()
	if path.is_empty():
		return false
	entry_path = path
	_path_index = 0
	_entry_point_time = 0.0
	mode = Mode.ENTRY
	if AttackDirector.has_token(fighter) and not _is_attacking():
		AttackDirector.release_token(fighter)
	return true

func _return_path() -> PackedVector3Array:
	var arena := get_tree().get_first_node_in_group(&"arena")
	if arena == null or not arena.has_method(&"get_enemy_spawns"):
		return PackedVector3Array()
	var me := _pos()
	var best := PackedVector3Array()
	var best_d := INF
	for entry: Dictionary in arena.get_enemy_spawns():
		var pts := PackedVector3Array([entry.get("position", me)])
		pts.append_array(entry.get("path", PackedVector3Array()))
		for i in pts.size():
			var d := _flat(pts[i] - me).length()
			if d < best_d and _clear_line(me, pts[i]):
				best_d = d
				best = pts.slice(i)
	return best

## True if a body fits at `p`: no wall or pillar within SPOT_RADIUS at waist
## height (steering targets too close to an obstacle are unreachable).
func _spot_free(p: Vector3) -> bool:
	var space := fighter.get_world_3d().direct_space_state
	_spot_params.transform = Transform3D(Basis(), Vector3(p.x, p.y + CLEAR_CENTER, p.z))
	_spot_params.exclude = [fighter.get_rid()]
	return space.intersect_shape(_spot_params, 1).is_empty()

## True if a body can pass from a to b: a capsule (CLEAR_RADIUS, a little
## thinner than a fighter's, CLEAR_HEIGHT tall) swept along the floor misses
## walls and pillars, so a corner the body would catch on, or a hole in a
## wall that is not floor to head height, reads as blocked.
func _clear_line(a: Vector3, b: Vector3) -> bool:
	var space := fighter.get_world_3d().direct_space_state
	var from := Vector3(a.x, a.y + CLEAR_CENTER, a.z)
	var motion := Vector3(b.x - a.x, 0.0, b.z - a.z)
	if motion.length() < 0.01:
		return true
	_sweep_params.transform = Transform3D(Basis(), from)
	_sweep_params.motion = motion
	_sweep_params.exclude = [fighter.get_rid()]
	var r := space.cast_motion(_sweep_params)
	return r.size() == 0 or r[0] >= 1.0

# --- Ring behaviour ----------------------------------------------------------

## The ring band (m from the player) this enemy waits in: Tuning.CIRCLE_RING
## for the crowd (the Duelist and the Thrower keep the old NEAR / FAR rings).
func ring_band(far: bool) -> Vector2:
	if fighter.archetype in OLD_RING_ARCHETYPES:
		return Tuning.FAR_RING if far else Tuning.NEAR_RING
	return Tuning.CIRCLE_RING

## Radius this enemy aims for in its ring now.
func ring_radius(far: bool) -> float:
	var band := ring_band(far)
	var r := lerpf(band.x, band.y, _ring_bias if far else _near_bias)
	if has_stick():
		r = maxf(r, float(fighter.config.get("keep_distance", 3.0)))  # the stick keeps his distance
	return r

func _do_ring(delta: float, player: Fighter) -> void:
	var center := player.get_ground_position()
	var me := _pos()
	var to_me := _flat(me - center)
	var d := to_me.length()
	var dir := to_me / d if d > 0.05 else _flat(-fighter.get_forward()).normalized()
	if dir.length() < 0.5:
		dir = Vector3.BACK
	var ring := AttackDirector.get_ring(fighter)
	var far := ring != AttackDirector.Ring.NEAR or fighter.archetype == &"thrower"
	var radius := ring_radius(far)
	if _backing_off:
		radius = maxf(radius, _backoff_radius)  # Round 8: backed off under pressure
	_want_guard = _guard_wanted(d, false)
	if _fetch_rubble(delta, center):
		return

	# Taunts (far ring only; not while backing off).
	if _time < _taunt_until and not _backing_off:
		fighter.move_input = Vector3.ZERO
		_face(center)
		return
	if far and fighter.archetype != &"thrower" and not _backing_off:
		_taunt_timer -= delta
		if _taunt_timer <= 0.0:
			_taunt_timer = _rng.randf_range(TAUNT_INTERVAL.x, TAUNT_INTERVAL.y)
			if d > ring_band(true).x - 0.5 and _try_taunt():
				fighter.move_input = Vector3.ZERO
				_face(center)
				return

	# Duelist feints: a quick step in, then back out (not while backing off).
	if fighter.archetype == &"duelist" and not far and not _backing_off:
		_feint_timer -= delta
		if _feint_timer <= 0.0:
			_feint_timer = _rng.randf_range(FEINT_INTERVAL.x, FEINT_INTERVAL.y)
			_feint_until = _time + FEINT_TIME
		if _time < _feint_until:
			radius = FEINT_RADIUS

	# Off screen and next in line: drift into the camera's view (rule 4).
	if not far and not AttackDirector.is_on_screen(fighter):
		var cam_fwd := _camera_forward()
		if cam_fwd != Vector3.ZERO:
			dir = (dir + cam_fwd * 1.2).normalized()

	_strafe_timer -= delta
	if _strafe_timer <= 0.0:
		var sw := DUELIST_STRAFE_SWITCH if fighter.archetype == &"duelist" else STRAFE_SWITCH
		_strafe_timer = _rng.randf_range(sw.x, sw.y)
		_strafe_sign = -_strafe_sign if _rng.randf() < 0.75 else _strafe_sign
	var tangent := Vector3(-dir.z, 0.0, dir.x)
	var strafe: float = STRAFE_SPEED.get(fighter.archetype, STRAFE_FAR if far else STRAFE_NEAR)
	var spread := _angular_spread(center, dir, far)

	# Round 6: not on broken glass, not under a cracked pillar's beam.
	var goal := AttackDirector.avoid_hazards(_clamp_to_bounds(center + dir * radius), center)
	if not _clear_line(center, goal):
		goal = _visible_ring_point(center, dir, radius)
	goal = _route(goal, center)
	var v := _seek(goal)
	v += tangent * (strafe * _strafe_sign + spread * 0.8)
	_finish_move(v, center, true)
	_face(center)

## A ring point with a clear line to the player (not behind a wall when the
## player is in a room or next to one): rotate around the ring, then come closer.
func _visible_ring_point(center: Vector3, dir: Vector3, radius: float) -> Vector3:
	for r: float in [radius, 1.8]:
		for k in range(1, 7):
			for sgn: float in [1.0, -1.0]:
				var g := _clamp_to_bounds(center + dir.rotated(Vector3.UP, sgn * k * PI / 6.0) * r)
				if _clear_line(center, g):
					return g
	return center + dir * 1.5

## Where to stand to swing: `r` from the player on our side, or, when that
## spot is behind (or inside) a pillar or wall as seen from the player, the
## nearest spot round the player with a clear line to it. Rays are cast from
## the player outward so a spot inside an obstacle reads as blocked.
func _approach_goal(center: Vector3, dir: Vector3, r: float) -> Vector3:
	var g := center - dir * r
	if _spot_free(g) and _clear_line(center, g):
		return g
	var me := _pos()
	var best := g
	var best_d := INF
	var perp := Vector3(-dir.z, 0.0, dir.x)
	for k in range(1, 7):
		for sgn: float in [1.0, -1.0]:
			var c := center - dir.rotated(Vector3.UP, sgn * k * PI / 6.0) * r
			if not _spot_free(c) or not _clear_line(center, c):
				continue
			var d := _flat(c - me).length()
			# While going round an obstacle, stay on the committed side.
			if _side_locked and signf(perp.dot(c - me)) != _side_sign:
				d += 3.0
			if d < best_d:
				best_d = d
				best = c
	return best

func _try_taunt() -> bool:
	if fighter.animator == null or fighter.animator.is_busy() or _is_attacking():
		return false
	if not AttackDirector.is_on_screen(fighter):
		return false
	fighter.animator.play_move(&"taunt", 0.3, 0.5, 0.4)
	_taunt_until = _time + TAUNT_HOLD
	return true

## Tangential push away from enemies in the same ring at similar angles.
func _angular_spread(center: Vector3, dir: Vector3, far: bool) -> float:
	var tangent := Vector3(-dir.z, 0.0, dir.x)
	var limit := SPREAD_ANGLE_FAR if far else SPREAD_ANGLE_NEAR
	var push := 0.0
	for e in AttackDirector.get_enemies():
		if e == fighter or not is_instance_valid(e) or e.is_dead() or e.is_down() or e.is_fleeing():
			continue
		var other_far := AttackDirector.get_ring(e) != AttackDirector.Ring.NEAR or e.archetype == &"thrower"
		if other_far != far:
			continue
		var o := _flat(e.get_ground_position() - center)
		if o.length() < 0.05:
			continue
		o = o.normalized()
		var ang := atan2(o.dot(tangent), o.dot(dir))
		if absf(ang) < limit:
			var s := 1.0 - absf(ang) / limit
			push += -signf(ang) * s if absf(ang) > 0.01 else (1.0 if get_instance_id() < e.get_instance_id() else -1.0)
	return clampf(push, -1.0, 1.0)

# --- Attacks -----------------------------------------------------------------

func _tick_request(delta: float, player: Fighter) -> void:
	if _time < _resume_at:
		return
	# The attack interval runs in the NEAR ring (or when the player is right
	# here); FAR enemies wait their turn.
	var near := AttackDirector.get_ring(fighter) == AttackDirector.Ring.NEAR
	var dist := _dist_to(player)
	# A FAR enemy the player has walked up to (close and on screen) may also
	# ask; the director's pacing keeps the crowd's rate in check.
	var engaged := dist <= ENGAGE_DIST and AttackDirector.is_on_screen(fighter)
	if near and not _was_near:
		# Just moved up (next in line): the walk in covers most of the wait.
		_interval_left = minf(_interval_left, _rng.randf_range(NEAR_JOIN_INTERVAL.x, NEAR_JOIN_INTERVAL.y))
	_was_near = near
	if near or engaged:
		# Round 8: under pressure the interval runs 1 / (1 + p) as fast (time between attacks x (1 + p)).
		_interval_left -= delta / (1.0 + get_pressure())
	var urgent := _answer_pending or _time < _punish_until or _brawler_wants_grab()
	if not urgent and (_interval_left > 0.0 or not (near or engaged)):
		return
	if _fetch_target != null:
		return  # the Thrower fetches its rubble first
	if _time < _unreachable_until:
		return  # the player is walled off from here
	var max_dist := SHIELD_REQUEST_DIST if fighter.archetype == &"shield" else REQUEST_MAX_DIST
	if not fighter.archetype in [&"thrower", &"brute", &"heavy"] and dist > max_dist:
		return
	# Only the Duelist's answer to a broken guard / whiff punish skip the crowd
	# pacing; a Brawler punishing a blocker skips its interval and the turn order.
	if AttackDirector.request_token(fighter, _answer_pending or _time < _punish_until, _brawler_wants_grab()):
		_begin_turn(dist, player)
	else:
		_interval_left = maxf(_interval_left, REQUEST_RETRY)

func _begin_turn(dist: float, player: Fighter) -> void:
	_turn_downed = AttackDirector.is_player_knocked_down()
	_move_id = _pick_move(dist, player, _turn_downed)
	_has_move = true
	_following = false
	_approach_time = 0.0
	_in_range_time = 0.0
	_start_failures = 0

func _do_token_turn(delta: float, player: Fighter) -> void:
	var dist := _dist_to(player)
	var downed := AttackDirector.is_player_knocked_down()
	if not _has_move:
		_begin_turn(dist, player)
	elif downed and not _following and not _turn_downed:
		# The player went down while we closed in: take the free swing with a
		# move that reaches the floor (picked once).
		_begin_turn(dist, player)
	if _approach_time == 0.0:
		_best_dist = INF
		_progress_best = INF
	_approach_time += delta
	if _following:
		_do_followup(dist, player, downed)
		return
	if _approach_time > GIVE_UP_TIME:
		_give_up_token()
		return
	# Fall back to a close move when the target is inside a ranged move's minimum.
	if _move_id == &"e_charge" and dist < MOVE_MIN_RANGE[&"e_charge"]:
		_move_id = _resolve_move(&"e_heavy")
	elif _move_id == &"e_throw_debris" and dist < 2.2:
		_move_id = &"e_hook"
	var max_r: float = MOVE_RANGE.get(_move_id, 1.5)
	var min_r: float = MOVE_MIN_RANGE.get(_move_id, 0.0)
	# The approach has stalled (a pillar corner, a body in the way): swing from
	# a little further out; the move's lunge covers the gap.
	if _approach_time > GIVE_UP_TIME * 0.5 and dist < _best_dist + 0.05 and _clear_line(player.get_ground_position(), _pos()):
		max_r += RANGE_SLACK
	_best_dist = minf(_best_dist, dist)
	var center := player.get_ground_position()
	var to_player := _flat(center - _pos())
	var dir := to_player.normalized() if to_player.length() > 0.01 else fighter.get_forward()
	_want_guard = _guard_wanted(dist, true)
	_face(center)
	if dist > max_r and _approach_stalled(dist, center) and dist <= max_r + STALL_SWING_REACH:
		max_r = dist  # blocked short of range: swing from here (the lunge closes in)
	if dist > max_r:
		_in_range_time = 0.0
		var goal := _route(_approach_goal(center, dir, max_r * 0.75), center)
		if nav_unreachable and fighter.archetype != &"duelist":
			# Walled off from the player: give the turn to someone who can
			# reach it (the Duelist vanish-steps instead).
			_give_up_token()
			_unreachable_until = _time + UNREACHABLE_WAIT
			return
		var v := _flat(goal - _pos()).normalized()
		_finish_move(v, center, false)
		return
	if dist < min_r:
		_in_range_time = 0.0
		_finish_move(-dir, center, false)
		return
	fighter.move_input = Vector3.ZERO
	_in_range_time += delta
	if _time < _resume_at or not fighter.can_act() or _time < _tap_guard_until or _time < _guard_until:
		return
	if fighter.get_forward().dot(dir) < FACE_TOLERANCE and _in_range_time < FACE_WAIT_MAX:
		return
	_try_start(downed)

## The token approach has stalled: less than STALL_PROGRESS closer for
## STALL_TIME while the player stood (moved under STALL_PLAYER_MOVE). Real
## progress, or a player on the move, restarts the clock.
func _approach_stalled(dist: float, player_pos: Vector3) -> bool:
	if dist < _progress_best - STALL_PROGRESS or _flat(player_pos - _progress_player).length() > STALL_PLAYER_MOVE:
		_progress_best = dist
		_progress_at = _time
		_progress_player = player_pos
		return false
	return _time - _progress_at >= STALL_TIME

## A string's next hit: it swings from where it stands (the first hit's lunge
## closed in), waiting at most STRING_WAIT_MAX for a spaced slot.
func _do_followup(dist: float, player: Fighter, downed: bool) -> void:
	fighter.move_input = Vector3.ZERO
	_face(player.get_ground_position())
	var max_r: float = MOVE_RANGE.get(_move_id, 1.5) + STRING_RANGE_SLACK
	if downed or dist > max_r or _approach_time > STRING_WAIT_MAX:
		_give_up_token()
		return
	if not fighter.can_act():
		return
	_try_start(false)

## Ask the director for a spaced swing and start the move.
func _try_start(downed: bool) -> void:
	var startup := _startup_for(_move_id)
	var followups: Array = []
	if not _following and not downed:
		followups = _followup_offsets(_move_id)
	if AttackDirector.request_swing(fighter, startup, followups) < 0.0:
		return
	_want_guard = false
	_tap_guard_until = -INF
	_apply_guard()
	_tell_move = _move_id
	var started := fighter.combat != null and fighter.combat.start_enemy_attack(_move_id, startup)
	if started:
		last_start_dist = _dist_to(_get_player()) if _get_player() != null else 0.0
		if not _following and not downed and last_start_dist > float(MOVE_RANGE.get(_move_id, 1.5)) + RANGE_SLACK:
			stall_swings += 1
		var tta := fighter.combat.time_to_active()
		AttackDirector.notify_attack_started(fighter, tta if is_finite(tta) else startup)
		attacks_started += 1
		if downed:
			downed_swings += 1
		_attack_started_at = _time
		if _move_id == &"e_throw_debris":
			_has_chunk = false
		elif _move_id in GRAB_MOVES:
			_aim_timer = 0.0
			_update_throw_aim(0.0)
		if _following or downed:
			_string_rest.clear()
		if not _string_rest.is_empty():
			AttackDirector.hold_for_followup(fighter)
		if _answer_pending and _move_id == GUARD_BREAK_ANSWER.get(fighter.archetype, &""):
			guard_answers += 1
		_has_move = false
		_following = false
		_answer_pending = false
		_punish_until = 0.0
		attack_launched.emit(_move_id)
	else:
		_tell_move = &""
		AttackDirector.cancel_swing(fighter)
		_start_failures += 1
		if _start_failures > START_FAIL_MAX:
			_give_up_token()

## Startup (s of the enemy's own time) of `move` this wave. Round 8:
## Tuning.R8_PRESSURE_TELL_SLOW x p longer under pressure; never under the
## tell floor (AttackDirector.tell_min_frames).
func _startup_for(move: StringName) -> float:
	var s := AttackDirector.enemy_startup_s(move)
	if Tuning.difficulty == Tuning.Difficulty.EASY:
		s += EASY_TELL_BONUS
	s += Tuning.R8_PRESSURE_TELL_SLOW * get_pressure()
	return maxf(s, Tuning.frames(AttackDirector.tell_min_frames()))

## Expected first active frames of the string's later hits, in s after the
## first hit's: each previous hit's active + whiff recovery, then the next
## move's startup (the director holds a slack round these estimates).
func _followup_offsets(move: StringName) -> Array:
	var out: Array = []
	var off := 0.0
	var prev := move
	for nxt: StringName in _string_rest:
		var m := MoveLibrary.get_move(prev) if MoveLibrary.has_move(prev) else null
		var after := (m.active_s() + m.recovery_s(false)) if m != null else Tuning.frames(13.0)
		off += after + get_physics_process_delta_time() + _startup_for(nxt)
		out.append(off)
		prev = nxt
	return out

func _give_up_token() -> void:
	AttackDirector.release_token(fighter)
	_has_move = false
	_following = false
	_string_rest.clear()
	_answer_pending = false
	_interval_left = REQUEST_RETRY * 2.0

## The attack interval runs start to start: the time the attack took counts
## (at 1 / (1 + p), as the interval runs: Round 8, start to start x (1 + p)).
## A string goes on with its next move while the token is held.
func _on_attack_ended(_move_id_ended: StringName) -> void:
	if not _string_rest.is_empty() and AttackDirector.has_token(fighter) and not fighter.is_dead():
		_move_id = _string_rest.pop_front()
		_has_move = true
		_following = true
		_approach_time = 0.0
		_in_range_time = 0.0
		_start_failures = 0
		return
	_string_rest.clear()
	_interval_left = maxf(_new_interval() - (_time - _attack_started_at) / (1.0 + get_pressure()), REQUEST_RETRY)

func _new_interval() -> float:
	if AttackDirector.live_enemy_count() <= 1:
		return _rng.randf_range(LONE_INTERVAL.x, LONE_INTERVAL.y)
	return _rng.randf_range(Tuning.ATTACK_INTERVAL.x, Tuning.ATTACK_INTERVAL.y) * CROWD_INTERVAL_MULT

func _pick_move(dist: float, _player: Fighter, downed := false) -> StringName:
	_string_rest.clear()
	var pick: StringName = &""
	if downed:
		for m in DOWNED_MOVES:
			if _move_available(m):
				pick = m
				break
	if pick == &"":
		match fighter.archetype:
			&"heavy":
				if dist >= HEAVY_CHARGE_FROM and _move_available(&"e_charge") and _rng.randf() < HEAVY_CHARGE_CHANCE:
					pick = &"e_charge"
			&"brawler":
				if _brawler_wants_grab() and not _arm_broken:
					pick = &"e_grab"
			&"brute":
				if dist >= 3.0 and _rng.randf() < 0.75:
					pick = &"e_charge"  # a shoulder charge: fine with a broken arm too
			&"duelist":
				if _answer_pending:
					var answer: StringName = GUARD_BREAK_ANSWER[&"duelist"]
					pick = answer if not _arm_broken else &"e_kick"
				elif _time < _punish_until:
					pick = &"e_kick"  # a whiff is punished with a launch
				elif _player_block_time > 0.5 and _rng.randf() < 0.7 and not _arm_broken:
					pick = &"e_grab"
			&"thrower":
				if dist >= 2.5:
					pick = &"e_throw_debris"
	if pick == &"":
		pick = _weighted_pick()
	var resolved := _resolve_move(pick)
	if resolved == pick and not downed:
		for nxt: StringName in STRINGS.get(pick, []):
			if _move_available(nxt) and MoveLibrary.has_move(nxt):
				_string_rest.append(nxt)
	_note_level(resolved)
	return resolved

## A move B's MoveLibrary has: `move`, or its MOVE_FALLBACK while B's Round 5
## move has not landed.
func _resolve_move(move: StringName) -> StringName:
	if MoveLibrary.has_move(move):
		return move
	return MOVE_FALLBACK.get(move, move)

## The moves this enemy has now: its archetype's, the grunt's once a stick
## enemy has dropped his stick.
func _moves() -> Array:
	if fighter.archetype == &"stick" and not has_stick():
		return Tuning.ARCHETYPES[&"grunt"].get("moves", [])
	return fighter.config.get("moves", [])

func _mix() -> Dictionary:
	if fighter.archetype == &"stick" and not has_stick():
		return MOVE_MIX[&"grunt"]
	return MOVE_MIX.get(fighter.archetype, {})

## Weighted pick from the mix: only moves the enemy has (e_sweep once
## MoveLibrary has it) and its limbs allow, kicks only with a broken arm, and
## never a third attack in a row at the same height (so crouching or jumping
## on a guess does not always work, nor does blocking everything).
func _weighted_pick() -> StringName:
	var mix := _mix()
	var cands: Array[StringName] = []
	var weights: Array[float] = []
	for m: StringName in mix:
		if not _move_available(m):
			continue
		if _arm_broken and not m in ARM_FREE_MOVES:
			continue
		cands.append(m)
		weights.append(float(mix[m]))
	if cands.is_empty():
		if _arm_broken and _move_available(&"e_kick", true):
			return &"e_kick"
		for m: StringName in _moves():
			if _limbs_allow(m):
				return m
		var moves := _moves()
		return moves[0] if not moves.is_empty() else &"e_hook"
	# Height variety: drop the repeated height when the last MAX_SAME_LEVEL matched.
	if _recent_levels.size() >= MAX_SAME_LEVEL:
		var last: int = _recent_levels[-1]
		var same := true
		for l in _recent_levels.slice(_recent_levels.size() - MAX_SAME_LEVEL):
			same = same and l == last
		if same:
			var keep_c: Array[StringName] = []
			var keep_w: Array[float] = []
			for i in cands.size():
				if move_level(cands[i]) != last:
					keep_c.append(cands[i])
					keep_w.append(weights[i])
			if not keep_c.is_empty():
				cands = keep_c
				weights = keep_w
	var total := 0.0
	for w in weights:
		total += w
	var roll := _rng.randf() * total
	for i in cands.size():
		roll -= weights[i]
		if roll <= 0.0:
			return cands[i]
	return cands[-1]

## The enemy can use `move`: listed in its moves, or e_sweep / e_kick added
## by the Upgrade 2 height mix once MoveLibrary has them; MoveLibrary (or a
## fallback) has it; and its remaining limbs can throw it.
func _move_available(move: StringName, any_archetype := false) -> bool:
	if not _limbs_allow(move):
		return false
	var listed := _moves()
	if move in listed:
		return MoveLibrary.has_move(_resolve_move(move))
	if not (any_archetype or move in _mix()):
		return false
	return MoveLibrary.has_move(move)

## One-handed after losing an arm: grabs need both hands; a strike needs at
## least one of its striking hands (feet always work). A stick attack needs
## the stick.
func _limbs_allow(move: StringName) -> bool:
	if String(move).begins_with("e_stick") and not has_stick():
		return false
	if _lost_arm.is_empty():
		return true
	if move in GRAB_MOVES:
		return false
	var hands: Array[StringName] = []
	for b: StringName in PoseLibrary.STRIKE_BONES.get(move, []):
		if String(b).ends_with("Hand") or String(b).ends_with("Arm"):
			hands.append(b)
	if hands.is_empty():
		var id := String(move)
		if id.contains("kick") or id.contains("sweep") or id.contains("charge"):
			return true
		hands.append(&"LeftHand" if id.contains("jab") else &"RightHand")
	for b in hands:
		var side := &"left" if String(b).begins_with("Left") else &"right"
		if not _lost_arm.has(side):
			return true
	return false

## Hit height of an enemy move: MoveData.hit_level from B's MoveLibrary,
## else the spec's table (hook and grab HIGH, kicks MID, sweep LOW). While
## B has not tagged a move (hit_level still the MID default) the table wins
## where it says otherwise.
static func move_level(move: StringName) -> int:
	var fallback := int(MOVE_LEVEL_FALLBACK.get(move, HitInfo.Level.MID))
	if MoveLibrary.has_move(move):
		var m := MoveLibrary.get_move(move)
		if m != null and (m.hit_level != HitInfo.Level.MID or fallback == HitInfo.Level.MID):
			return m.hit_level
	return fallback

func _note_level(move: StringName) -> void:
	_recent_levels.append(move_level(move))
	if _recent_levels.size() > 4:
		_recent_levels.remove_at(0)

func _on_arm_broken(f: Node3D, _zone: int) -> void:
	if f == fighter:
		_arm_broken = true

func _brawler_wants_grab() -> bool:
	if fighter.archetype != &"brawler":
		return false
	return _player_block_time > float(fighter.config.get("grab_blocker_after", 1.0))

# --- Guarding the player's strikes ------------------------------------------------

## B: a strike's startup began. A tapped strike aimed at us (is_tapped_strike):
## guard it with get_guard_chance() (the archetype's "guard_chance", grunts:
## Tuning.GUARD_TAP_CHANCE, x (1 - p) and x the level's block mult: Round 8).
## Round 7 removed sidestepping the player's sprint strikes.
func _on_strike_started(attacker: Node3D, target: Node3D, move: StringName, _sprint: bool, charge_level: int) -> void:
	if target != fighter or not attacker is Fighter or attacker == fighter:
		return
	var a := attacker as Fighter
	if a.team == fighter.team or mode != Mode.FIGHT or fighter.is_dead() or is_fleeing():
		return
	if _is_impaired() or _is_attacking():
		return
	var guard_chance := get_guard_chance()
	if guard_chance > 0.0 and is_tapped_strike(move, charge_level):
		# Already guarding (the string goes on): keep it up; else roll.
		if _time < _tap_guard_until or _rng.randf() < guard_chance:
			_tap_guard(a)

## A strike a tap guard is raised against. Round 8 strikes (Tuning.R8_MOVES,
## B's GameEvents.strike_started charge_level 0 for a tap, 1+ for a charged
## strike, same id): every tap; a charged strike breaks a guard (B), so never
## one. Other Round 7 ids (the heavies) by Tuning.R7_MOVES "guard_break"; for
## older move ids, a Round 5 strike at charge level 0.
static func is_tapped_strike(move: StringName, charge_level := 0) -> bool:
	if Tuning.R8_MOVES.has(move):
		return charge_level == 0
	if Tuning.R7_MOVES.has(move):
		return not bool(Tuning.R7_MOVES[move].get("guard_break", false))
	return charge_level == 0

## Raise the guard now and hold it until the strike's active frames are past
## (a string extends it, but one spell never outlasts TAP_GUARD_MAX).
func _tap_guard(a: Fighter) -> void:
	var tta := a.combat.time_to_active() if a.combat else 0.1
	if not is_finite(tta):
		tta = 0.1
	var hold := minf(tta * Engine.time_scale + Tuning.frames(4.0) + TAP_GUARD_AFTER, TAP_GUARD_MAX)
	if _time >= _tap_guard_until:
		tap_guards += 1
		_tap_guard_since = _time
	_tap_guard_until = minf(maxf(_tap_guard_until, _time + hold), _tap_guard_since + TAP_GUARD_MAX)
	_face(a.get_ground_position())
	_want_guard = true
	_apply_guard()

# --- Guard -------------------------------------------------------------------

func _guard_wanted(dist: float, with_token: bool) -> bool:
	if _time < _tap_guard_until:
		return true
	match fighter.archetype:
		&"shield":
			if with_token:
				return dist < SHIELD_CLOSE_GUARD or _player_attacking
			return dist < SHIELD_GUARD_DIST
		&"brawler":
			return not with_token and dist < BRAWLER_GUARD_DIST
		&"duelist":
			return _time < _guard_until
	return false

## Press / release BLOCK on changes of the wanted guard state only.
func _apply_guard() -> void:
	var want := _want_guard
	if want == _block_down:
		return
	_block_down = want
	if fighter.combat == null:
		return
	if want:
		fighter.combat.press(CombatController.Action.BLOCK)
	else:
		fighter.combat.release(CombatController.Action.BLOCK)

# --- Limb loss (F10) -----------------------------------------------------------

func _on_limb_severed(f: Node3D, cut: StringName, _piece: Node3D) -> void:
	if f != fighter or fighter.is_dead():
		return
	match cut:
		&"arm_l", &"forearm_l":
			_lost_arm[&"left"] = true
		&"arm_r", &"forearm_r":
			_lost_arm[&"right"] = true
			if has_stick():
				_drop_stick(Vector3.ZERO)
		&"leg_l", &"leg_r", &"shin_l", &"shin_r":
			_lost_leg = true
	_has_move = false
	_following = false
	_string_rest.clear()
	_update_flee()  # starts at once: no token, fleeing_changed, limp / crawl

## Lost a leg: crawl. Lost an arm at or below Tuning.LIMB_LOST_FLEE_HP: limp.
## Starting to flee gives the token back and tells everyone.
func _update_flee() -> void:
	if fighter.is_dead():
		return
	var want: StringName = &""
	if _lost_leg:
		want = &"crawl"
	elif not _lost_arm.is_empty() and fighter.hp <= Tuning.LIMB_LOST_FLEE_HP:
		want = &"limp"
	if want == _flee:
		return
	var was := _flee != &""
	_flee = want
	if fighter.animator and fighter.animator.has_method(&"set_locomotion_style"):
		fighter.animator.set_locomotion_style(want if want != &"" else &"walk")
	if (want != &"") != was:
		if want != &"":
			_want_guard = false
			_tap_guard_until = -INF
			_has_move = false
			_following = false
			_string_rest.clear()
			_answer_pending = false
			if AttackDirector.has_token(fighter) and not _is_attacking():
				AttackDirector.release_token(fighter)
		GameEvents.fleeing_changed.emit(fighter, want != &"")

## Limp or crawl away from the player (no attacks, no guard), and stop to
## cower once FLEE_REST_DIST away. Speeds: Tuning.CRAWL_SPEED / LIMP_SPEED.
func _do_flee(player: Fighter) -> void:
	_want_guard = false
	if AttackDirector.has_token(fighter) and not _is_attacking():
		AttackDirector.release_token(fighter)
	if player == null or player.is_dead() or _is_attacking():
		fighter.move_input = Vector3.ZERO
		return
	var speed := Tuning.CRAWL_SPEED if _flee == &"crawl" else LIMP_SPEED
	var mult := speed / Tuning.ENEMY_WALK_SPEED
	var center := player.get_ground_position()
	var me := _pos()
	var away := _flat(me - center)
	var d := away.length()
	if d >= FLEE_REST_DIST:
		fighter.move_input = Vector3.ZERO
		_face(center)
		return
	var dir := away / d if d > 0.05 else _flat(-fighter.get_forward()).normalized()
	# Cornered (a wall or the bounds ahead): turn along it, whichever way
	# gains the most distance from the player.
	var best := dir
	var best_score := -INF
	for ang: float in [0.0, 0.6, -0.6, 1.2, -1.2, 1.6, -1.6]:
		var cand := dir.rotated(Vector3.UP, ang)
		var g := _clamp_to_bounds(me + cand * FLEE_STEP)
		var gain := _flat(g - center).length() - d
		if not _clear_line(me, g):
			gain -= 2.0
		var score := gain - absf(ang) * 0.3
		if score > best_score:
			best_score = score
			best = cand
	var goal := _route(_clamp_to_bounds(me + best * FLEE_STEP), center)
	var v := _flat(goal - me)
	v = v.normalized() if v.length() > 0.05 else best
	v += _separation() * 0.5
	v = _avoid_walls(v, WALL_PROBE)
	v.y = 0.0
	fighter.move_input = v.limit_length(1.0) * mult
	if v.length() > 0.05:
		fighter.face_dir = v.normalized()

## A hit on us: a string stops; a ground strike finishes a fleeing enemy (the
## doc's rule; B may already deal it as a kill); a stagger or more knocks the
## stick out of a stick enemy's hand. A strike that lands while our guard is
## up broke it (B decides which moves do): the Duelist answers with a hook
## once he can act again.
func _on_hit_landed(info: HitInfo) -> void:
	if info == null or info.victim != fighter:
		return
	_string_rest.clear()
	_following = false
	if _block_down and info.attacker is Fighter and info.attacker != fighter and not fighter.is_dead() \
			and (info.attacker as Fighter).team != fighter.team:
		_on_guard_broken()
	if is_fleeing() and info.ground_strike and not fighter.is_dead():
		fighter.apply_damage(fighter.hp, &"ground_strike", info)
	if has_stick() and not fighter.is_dead():
		var drop_at := int(fighter.config.get("drops_stick_at", HitInfo.Tier.STAGGER))
		var tier := info.tier
		if tier == HitInfo.Tier.NONE:
			tier = _tier_from_reaction(info.reaction)
		if tier >= drop_at:
			_drop_stick(info.hit_direction)

static func _tier_from_reaction(reaction: int) -> int:
	match reaction:
		HitInfo.Reaction.STAGGER:
			return HitInfo.Tier.STAGGER
		HitInfo.Reaction.LAUNCH:
			return HitInfo.Tier.LAUNCH
		HitInfo.Reaction.FLINCH:
			return HitInfo.Tier.FLINCH
	return HitInfo.Tier.NONE

func _on_fighter_died(f: Node3D, _info: HitInfo) -> void:
	if f == fighter and has_stick():
		_drop_stick(Vector3.ZERO)

# --- The stick (stick enemy) ----------------------------------------------------

func _armed_archetype() -> bool:
	var app: Dictionary = fighter.config.get("appearance", {})
	return fighter.archetype == &"stick" or StringName(app.get("accessory", &"none")) == &"stick"

## A wooden stick in the right fist: along the fist's forward axis, tilted
## STICK_TILT down, gripped STICK_GRIP from the butt.
func _build_stick() -> void:
	if fighter.rig == null:
		return
	var att := fighter.rig.get_attachment(&"RightHand")
	if att == null:
		return
	var mesh := CylinderMesh.new()
	mesh.top_radius = STICK_RADIUS * 0.85
	mesh.bottom_radius = STICK_RADIUS
	mesh.height = STICK_LENGTH
	mesh.radial_segments = 8
	mesh.rings = 1
	_stick_mat = StandardMaterial3D.new()
	_stick_mat.albedo_color = STICK_COLOR
	_stick_mat.roughness = 0.85
	_stick = MeshInstance3D.new()
	_stick.name = "Stick"
	_stick.mesh = mesh
	_stick.material_override = _stick_mat
	_stick.layers = Layers.VIS_CHARACTERS
	var t := deg_to_rad(STICK_TILT)
	var axis := Vector3(0.0, -sin(t), -cos(t))
	var fist := att.global_transform.affine_inverse() * fighter.rig.get_fist_position(&"RightHand") \
		if att.is_inside_tree() else HumanoidRig.FIST_OFFSET
	_stick.transform = Transform3D(Basis(Quaternion(Vector3.UP, axis)), fist + axis * (STICK_LENGTH * 0.5 - STICK_GRIP))
	att.add_child(_stick)

func _track_hand(delta: float) -> void:
	if not has_stick() or delta <= 0.0:
		return
	var p := _stick.global_position
	if _hand_prev != Vector3.INF:
		_hand_vel = ((p - _hand_prev) / delta).limit_length(HAND_SPEED_MAX)
	_hand_prev = p

## Drop the stick: free the mesh in the hand and spawn D's ThrowableProp
## (kind &"stick") at the stick's transform with the hand's velocity plus a
## small toss along the hit. He fights on with the grunt's moves.
func _drop_stick(push_dir: Vector3) -> void:
	if not has_stick():
		return
	var xf := _stick.global_transform
	var flat := _flat(push_dir)
	var v := _hand_vel + (flat.normalized() * STICK_DROP_TOSS.x if flat.length() > 0.01 else Vector3.ZERO) \
		+ Vector3.UP * STICK_DROP_TOSS.y
	var mesh_node := _stick
	_stick = null
	_stick_mat = null
	_has_move = false
	_string_rest.clear()
	var parent := fighter.get_parent()
	if parent == null or not parent.is_inside_tree():
		mesh_node.queue_free()
		return
	# D's prop builds its own stick (same size, along its local Y like ours).
	var prop := ThrowableProp.spawn(parent, &"stick", xf, false)
	prop.name = "DroppedStick"
	if _prop_is_bare(prop):
		# The prop built nothing for &"stick": dress it with this mesh.
		mesh_node.get_parent().remove_child(mesh_node)
		prop.add_child(mesh_node)
		mesh_node.transform = Transform3D()
		var col := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = STICK_RADIUS * 1.2
		shape.height = STICK_LENGTH
		col.shape = shape
		prop.add_child(col)
		prop.collision_layer = Layers.DEBRIS
		prop.collision_mask = Layers.MASK_DEBRIS
		prop.mass = STICK_MASS
	else:
		mesh_node.queue_free()
	prop.linear_velocity = v
	prop.angular_velocity = Vector3(_rng.randf_range(-6.0, 6.0), _rng.randf_range(-3.0, 3.0), _rng.randf_range(-6.0, 6.0))
	prop.reset_physics_interpolation()
	dropped_stick = prop

## True when the prop has no visible mesh and no collision shape of its own.
static func _prop_is_bare(prop: Node) -> bool:
	for c in prop.get_children():
		if c is CollisionShape3D or c is MeshInstance3D or c is CollisionPolygon3D:
			return false
	return true

# --- Player tracking, Duelist reactions ---------------------------------------

func _get_player() -> Fighter:
	return AttackDirector.get_player()

func _track_player(delta: float, player: Fighter) -> void:
	_player_attacking = player.combat != null and player.combat.is_attacking()
	if player.combat and player.combat.blocking:
		_player_block_time += delta
	else:
		_player_block_time = 0.0

func _watch_player(player: Fighter) -> void:
	if player == _watched_player:
		return
	if _watched_player != null and is_instance_valid(_watched_player) and _watched_player.combat:
		if _watched_player.combat.attack_incoming.is_connected(_on_player_attack_incoming):
			_watched_player.combat.attack_incoming.disconnect(_on_player_attack_incoming)
	_watched_player = player
	if player != null and player.combat and fighter.config.has("dodge_chance"):
		player.combat.attack_incoming.connect(_on_player_attack_incoming)

## The archetype's read chance (config "dodge_chance" [easy, normal]: the Duelist's).
func _read_chance() -> float:
	if read_chance_override >= 0.0:
		return read_chance_override
	var chances: Array = fighter.config.get("dodge_chance", [0.0, 0.0])
	return float(chances[clampi(Tuning.difficulty, 0, chances.size() - 1)])

## Read chance against a player move repeated `repeats` times within
## MASH_WINDOW: the archetype's chance, +MASH_BONUS per repeat, capped at
## MASH_CAP; Round 8: x block_mult() (pressure, level). The test override is exact.
func get_read_chance(repeats := 0) -> float:
	if read_chance_override >= 0.0:
		return read_chance_override
	var base := _read_chance()
	if repeats > 0:
		base = maxf(base, minf(base + MASH_BONUS * repeats, MASH_CAP))
	return clampf(base * block_mult(), 0.0, 1.0)

## The anti-mash family of a player move: every press of the punch button
## (Round 7's jab, cross, hook and their heavies) is one move; older ids drop
## their string number (jab1, jab2 -> jab).
static func move_family(move: StringName) -> String:
	if move in Tuning.R7_PUNCH_STRING or Tuning.R7_HEAVY_OF.values().has(move):
		return "punch"
	return String(move).rstrip("0123456789")

## The player started an attack: maybe read it (Duelist). Repeating the same
## move within MASH_WINDOW raises the chance (anti-mash). A read raises the
## guard at once (Block held: the AI guard; never a timed tap) and holds it
## until GUARD_AFTER_ACTIVE past the strike's first active frame; he does not
## start an attack meanwhile. While the guard is up (blockstun included) every
## further strike is read and extends it, so a string meets a raised guard.
## B's guard stops tapped punches; heavies, the gut punch, the uppercut and
## kicks break it, and he answers with a hook (_on_guard_broken).
func _on_player_attack_incoming(move: StringName, time_to_active: float) -> void:
	var family := move_family(move)
	var repeats := 0
	var kept: Array = []
	for m: Array in _player_moves:
		if _time - float(m[0]) <= MASH_WINDOW:
			kept.append(m)
			if m[1] == family:
				repeats += 1
	kept.append([_time, family])
	_player_moves = kept
	if mode != Mode.FIGHT or fighter.is_dead() or _is_attacking() or not _can_guard_now():
		return
	var player := _get_player()
	if player == null:
		return
	var to_me := _flat(_pos() - player.get_ground_position())
	if to_me.length() > READ_RANGE:
		return
	if to_me.length() > 0.05 and player.get_forward().dot(to_me.normalized()) < READ_FACING:
		return
	var guarding := _block_down and _time < _guard_until
	if not guarding and _rng.randf() >= get_read_chance(repeats):
		return
	var tta := time_to_active if is_finite(time_to_active) else 0.0
	_guard_until = maxf(_guard_until, _time + tta * Engine.time_scale + GUARD_AFTER_ACTIVE)
	guard_reads += 1
	_want_guard = true
	_face(player.get_ground_position())
	_apply_guard()

## Free to raise (or keep) a guard: not down, held, reacting, broken or
## hit-stunned (a blockstun is fine: the guard is up).
func _can_guard_now() -> bool:
	if fighter.is_down() or fighter.is_reacting() or fighter.is_lifted() or is_broken():
		return false
	if fighter.carry != null and fighter.carry.is_held():
		return false
	var c := fighter.combat
	return c == null or not c.is_hit_stunned()

## Our raised guard let a player strike through (B decides the guard breaks:
## heavies, the gut punch, the uppercut, kicks). The guard drops; an archetype
## with a GUARD_BREAK_ANSWER (the Duelist) answers with it through an urgent
## token once he can act again (_tick_answer).
func _on_guard_broken() -> void:
	guard_breaks += 1
	_guard_until = 0.0
	_tap_guard_until = -INF
	_want_guard = false
	if not GUARD_BREAK_ANSWER.has(fighter.archetype) or is_fleeing():
		return
	_has_move = false  # a move picked before the break gives way to the answer
	_string_rest.clear()
	_following = false
	_answer_pending = true
	_answer_deadline = INF

## The answer to a broken guard, from the first tick he can act again: close
## in to ANSWER_CLOSE_IN of the hook's range and ask for an urgent token (no
## crowd pacing); the normal token turn then swings the hook. Given up after
## ANSWER_WINDOW. Returns true while it owns this frame.
func _tick_answer(player: Fighter) -> bool:
	if not is_finite(_answer_deadline):
		_answer_deadline = _time + ANSWER_WINDOW
	if _time > _answer_deadline or player.is_dead():
		_answer_pending = false
		return false
	if _is_attacking() or AttackDirector.has_token(fighter):
		return false  # the normal token turn swings the hook
	var center := player.get_ground_position()
	var d := _dist_to(player)
	var r: float = MOVE_RANGE[&"e_hook"] * ANSWER_CLOSE_IN
	_want_guard = false
	if d > r:
		var to := _flat(center - _pos())
		var dir := to.normalized() if to.length() > 0.01 else fighter.get_forward()
		var goal := _route(_approach_goal(center, dir, r), center)
		_finish_move(_flat(goal - _pos()).normalized(), center, false)
	else:
		fighter.move_input = Vector3.ZERO
	_face(center)
	if AttackDirector.request_token(fighter, true):
		_begin_turn(d, player)
	return true

## Round 7: the player pressed Counter with no counterable attack coming (his
## Counter is locked for Tuning.R7_COUNTER_WHIFF_LOCK). A Duelist in reach
## punishes it like a whiff.
func _on_counter_whiffed(defender: Node3D) -> void:
	if fighter.archetype != &"duelist" or defender == null or defender != _get_player():
		return
	if mode == Mode.FIGHT and not is_fleeing() and _dist_to(defender as Fighter) < PUNISH_RANGE:
		_punish_until = _time + PUNISH_WINDOW

func _on_attack_whiff(attacker: Node3D, _move: StringName) -> void:
	if fighter.archetype != &"duelist" or attacker == null or attacker != _get_player():
		return
	if mode == Mode.FIGHT and _dist_to(attacker as Fighter) < PUNISH_RANGE:
		_punish_until = _time + PUNISH_WINDOW

# --- Enemy throws ---------------------------------------------------------------

## While holding a grab victim, aim the throw (combat.throw_aim) at the
## nearest wall in front (breakable first), never along a lane with an enemy.
func _update_throw_aim(delta: float) -> void:
	if fighter.combat == null:
		return
	# Holding the player through G's Carry (Carry reads combat.throw_aim for the
	# grab-throw's direction).
	var holding := _carrying()
	var grabbing := holding \
		or (fighter.combat.is_attacking() and fighter.combat.current_move_id() in GRAB_MOVES)
	if not grabbing:
		if _aim_set:
			_set_throw_aim(Vector3.ZERO)
			_aim_set = false
		return
	_aim_timer -= delta
	if _aim_timer > 0.0:
		return
	_aim_timer = 0.15
	var aim := find_throw_aim()
	_set_throw_aim(aim)
	_aim_set = true
	if aim != Vector3.ZERO and holding:
		fighter.face_dir = aim

## Both readers: G's Carry (enemy hold) and the Upgrade 2 grab.
func _set_throw_aim(aim: Vector3) -> void:
	fighter.combat.throw_aim = aim
	if fighter.carry != null and &"throw_aim" in fighter.carry:
		fighter.carry.set(&"throw_aim", aim)

## Direction for a throw: the nearest breakable wall within THROW_WALL_RANGE
## in a +-60 degree fan, else the nearest wall, else the first fan direction
## with nothing in the way. Lanes with an enemy are skipped. ZERO when none
## qualifies (B then throws straight ahead).
func find_throw_aim() -> Vector3:
	var space := fighter.get_world_3d().direct_space_state
	var origin := _pos() + Vector3.UP * 1.0
	var fwd := _flat(fighter.get_forward()).normalized()
	var best_break := Vector3.ZERO
	var best_break_d := INF
	var best_wall := Vector3.ZERO
	var best_wall_d := INF
	var open_dir := Vector3.ZERO
	for k in THROW_FAN * 2 + 1:
		@warning_ignore("integer_division")
		var i: int = (k + 1) / 2 * (1 if k % 2 == 1 else -1)  # 0, 1, -1, 2, -2, ...
		var d := fwd.rotated(Vector3.UP, deg_to_rad(15.0) * i)
		var q := PhysicsRayQueryParameters3D.create(origin, origin + d * THROW_WALL_RANGE,
			Layers.WORLD | Layers.DESTRUCTIBLE, [fighter.get_rid()])
		var hit := space.intersect_ray(q)
		var end: Vector3 = hit["position"] if not hit.is_empty() else origin + d * THROW_WALL_RANGE * 1.5
		if _enemy_in_lane(origin, end):
			continue
		if hit.is_empty():
			if open_dir == Vector3.ZERO:
				open_dir = d
			continue
		var dist := origin.distance_to(end)
		var col: Object = hit["collider"]
		var breakable := col is Destructible \
			and ((col as CollisionObject3D).collision_layer & Layers.DESTRUCTIBLE) != 0
		if breakable and dist < best_break_d:
			best_break_d = dist
			best_break = d
		elif not breakable and dist < best_wall_d:
			best_wall_d = dist
			best_wall = d
	if best_break != Vector3.ZERO:
		return best_break
	if best_wall != Vector3.ZERO:
		return best_wall
	return open_dir

func _enemy_in_lane(a: Vector3, b: Vector3) -> bool:
	var a2 := Vector2(a.x, a.z)
	var b2 := Vector2(b.x, b.z)
	for e in AttackDirector.get_enemies():
		if e == fighter or not is_instance_valid(e) or e.is_dead():
			continue
		var p := e.get_ground_position()
		var p2 := Vector2(p.x, p.z)
		if Geometry2D.get_closest_point_to_segment(p2, a2, b2).distance_to(p2) < THROW_LANE:
			return true
	return false

# --- Thrower rubble -------------------------------------------------------------

## The Thrower picks up a large debris chunk near it while it waits for a
## token (round 2: large chunks persist). Returns true while walking to one.
func _fetch_rubble(delta: float, center: Vector3) -> bool:
	if fighter.archetype != &"thrower" or _has_chunk or fighter.combat == null:
		return false
	if _time < _fetch_cooldown_until:
		return false
	if not fighter.combat.has_method(&"pick_up_debris") or not DebrisManager.has_method(&"find_nearest"):
		return false
	_fetch_scan -= delta
	if _fetch_target == null or not is_instance_valid(_fetch_target) or not _fetch_target.is_inside_tree():
		_fetch_target = null
		if _fetch_scan > 0.0:
			return false
		_fetch_scan = 0.5
		_fetch_target = DebrisManager.find_nearest(_pos(), RUBBLE_SEARCH, true)
		if _fetch_target == null:
			return false
		_fetch_started = _time
	var to := _flat(_fetch_target.global_position - _pos())
	if to.length() <= RUBBLE_REACH:
		if fighter.combat.pick_up_debris(_fetch_target):
			_has_chunk = true
		else:
			_fetch_cooldown_until = _time + FETCH_COOLDOWN  # B refused this chunk
		_fetch_target = null
		_fetch_scan = 0.5
		fighter.move_input = Vector3.ZERO
		return false
	if _time - _fetch_started > FETCH_TIMEOUT:
		_fetch_target = null
		_fetch_cooldown_until = _time + FETCH_COOLDOWN
		return false
	var goal := _route(_fetch_target.global_position, _fetch_target.global_position)
	_finish_move(_seek(goal) * 1.0 + to.normalized() * 0.3, center, true)
	_face(_fetch_target.global_position)
	return true

## Thrower: holds a picked-up chunk (its next e_throw_debris throws it).
func has_chunk() -> bool:
	return _has_chunk

# --- Steering ----------------------------------------------------------------

func _seek(goal: Vector3) -> Vector3:
	var to := _flat(goal - _pos())
	var d := to.length()
	if d < 0.05:
		return Vector3.ZERO
	return to / d * clampf(d / ARRIVE_RADIUS, 0.0, 1.0)

## Add separation, player space, bounds and wall sliding, then write move_input.
func _finish_move(v: Vector3, player_pos: Vector3, keep_player_space: bool) -> void:
	_steer_in = v
	v += _separation() * SEPARATION_WEIGHT
	if keep_player_space:
		var from_player := _flat(_pos() - player_pos)
		var d := from_player.length()
		if d < PLAYER_SPACE and d > 0.01:
			v += from_player / d * (1.0 - d / PLAYER_SPACE) * 2.0
	# A nav path only crosses walkable cells; it may leave the courtyard
	# (round a wall end, through a room) where the bounds push would fight it.
	if _nav_path.is_empty():
		v += _bounds_push()
	if _time < _backoff_until:
		v = _detour_dir  # the escalation's back-out overrides the steering
	elif _time < _detour_until:
		v = v * 0.3 + _detour_dir
	v = _avoid_walls(v, WALL_PROBE)
	_steer_out = v
	_check_stuck(v)
	_set_move(v)

## Steering target toward `goal`: the goal itself while the straight line is
## clear of walls (or only briefly blocked, e.g. by a pillar: wall sliding
## handles that), else an arena waypoint (spawn-path point) on a clear line,
## so an enemy walks round a wall to reach a player knocked into a room.
## Waypoints are searched toward `anchor` (the player: stable while the ring
## goal moves around); a failed search keeps the previous waypoint.
func _route(goal: Vector3, anchor: Vector3) -> Vector3:
	var dt := get_physics_process_delta_time()
	_route_age += dt
	var me := _pos()
	if _clear_line(me, goal):
		_blocked_time = 0.0
		_route_point = Vector3.INF
		_side_locked = false
		_nav_path = PackedVector3Array()
		nav_path_length = 0.0
		nav_unreachable = false
		return goal
	_blocked_time += dt
	if _blocked_time < SIDE_ROUTE_BLOCKED:
		return goal
	# The shared nav grid knows doors, holes and props: follow its path.
	var nav_pt := _nav_route(me, goal)
	if nav_pt != Vector3.INF:
		return nav_pt
	if not _side_locked:
		# Commit to one side of the obstacle for this blockage: the side the
		# goal lies on, seen along the line to the player (else keep the last).
		_side_locked = true
		var line := _flat(anchor - me)
		if line.length() > 0.05:
			line = line.normalized()
			var off := Vector3(-line.z, 0.0, line.x).dot(_flat(goal - me))
			if absf(off) > 0.1:
				_side_sign = signf(off)
	var reached := _route_point != Vector3.INF and _flat(_route_point - me).length() <= ENTRY_REACH
	if _route_point != Vector3.INF and not reached and _route_age < ROUTE_REPLAN:
		return _route_point
	_route_age = 0.0
	# Round a pillar or a wall end first: a point to the side with a clear
	# line both ways. Arena waypoints only when that fails for a while.
	var side := _side_point(me, goal)
	if side != Vector3.INF:
		_route_point = side
		return side
	if _blocked_time < ROUTE_BLOCKED_TIME:
		return goal
	if not AttackDirector.take_route_budget():
		_route_age = ROUTE_REPLAN  # another enemy searched this tick: next tick
		return goal if _route_point == Vector3.INF else _route_point
	var found := _find_waypoint(me, anchor)
	if found != Vector3.INF:
		_route_point = found
	elif reached:
		_route_point = Vector3.INF
	return goal if _route_point == Vector3.INF else _route_point

## Steering point along the nav grid's path to `goal` (INF when the grid is
## not ready or has no path). Re-plans every NAV_REPLAN s or when the goal
## moves; looks ahead to the furthest path point in clear line (string
## pulling, re-checked every NAV_LOOK_EVERY s). If following makes no
## progress, the cells round the enemy are re-tested (stale grid repair).
func _nav_route(me: Vector3, goal: Vector3) -> Vector3:
	if not AttackDirector.nav_ready():
		return Vector3.INF
	var dt := get_physics_process_delta_time()
	_npath_age += dt
	var replan := _npath_age > NAV_REPLAN or _flat(goal - _nav_goal).length() > NAV_GOAL_MOVE
	if _nav_path.is_empty() or (replan and _my_tick()):
		# Both layers: the wide way (0.42 m clearance: off jambs, clutter
		# corners and hole edges) whenever it exists for a wide body, and for
		# the rest unless it is more than WIDE_DETOUR_MAX longer than the
		# normal way; the normal way when no wide one exists (a wide body then
		# squeezes).
		var p := AttackDirector.nav_path(me, goal, true)
		var complete := not p.is_empty() and AttackDirector.nav.last_path_complete
		if AttackDirector.nav_has_budget():
			var p2 := AttackDirector.nav_path(me, goal, false)
			var c2 := not p2.is_empty() and AttackDirector.nav.last_path_complete
			var detour_ok := _wide or AINavGrid.path_length(me, p) <= AINavGrid.path_length(me, p2) + WIDE_DETOUR_MAX
			if c2 and (not complete or not detour_ok):
				p = p2
				complete = true
			elif p.is_empty():
				p = p2
		if not p.is_empty():
			_nav_path = p
			_nav_goal = goal
			_npath_age = 0.0
			_nav_index = 0
			_nav_look_age = INF
			# A partial path stops at the closest reachable cell: the goal is
			# walled off (a sealed room, a hole too small to walk through).
			nav_unreachable = not complete
			nav_path_length = INF if nav_unreachable else AINavGrid.path_length(me, p)
		elif AttackDirector.nav_has_budget():
			_nav_path = PackedVector3Array()  # no path at all
			nav_path_length = INF
			nav_unreachable = true
	if _nav_path.is_empty():
		return Vector3.INF
	while _nav_index < _nav_path.size() - 1 and _flat(_nav_path[_nav_index] - me).length() < AINavGrid.CELL * 1.5:
		_nav_index += 1
	_nav_look_age += dt
	if _nav_look_age > NAV_LOOK_EVERY and (_my_tick() or not is_finite(_nav_look_age)):
		_nav_look_age = 0.0
		_nav_target = _nav_path[_nav_index]
		for k in range(_nav_index + 1, mini(_nav_index + NAV_LOOKAHEAD, _nav_path.size())):
			if not _clear_line(me, _nav_path[k]):
				break
			_nav_target = _nav_path[k]
		# Stale grid (geometry changed without a break event): no progress
		# for a while along the path -> re-test the cells round us.
		var d_target := _flat(_nav_target - me).length()
		if d_target < _nav_best - 0.2:
			_nav_best = d_target
			_nav_progress_at = _time
		elif _time - _nav_progress_at > NAV_STUCK:
			AttackDirector.nav.refresh(me, 1.6)
			_nav_path = PackedVector3Array()
			_nav_best = INF
			_nav_progress_at = _time
	return _nav_target

# --- Duelist vanish step ----------------------------------------------------------

## Duelist only: no path, or no progress toward an open player for
## VSTEP_NO_PROGRESS s, or a path longer than VSTEP_PATH_LEN: a free vanish
## step (6 s cooldown) to a clear spot ~2.5 m from the player in its line of
## sight, with B's afterimage and puff. Returns true while it owns the frame.
func _tick_vanish_step(player: Fighter) -> bool:
	if fighter.archetype != &"duelist":
		return false
	if _time < _vstep_until:
		fighter.move_input = Vector3.ZERO
		if not _vstep_done and _time >= _vstep_until - 0.001 - VSTEP_SHOW:
			_finish_vanish_step(player)
		return true
	var d := _dist_to(player)
	var long_way := nav_path_length > VSTEP_PATH_LEN  # INF: the grid found no way at all
	# Only when it means to close in: holding a token, or well outside its ring.
	var want_close := AttackDirector.has_token(fighter) or d > Tuning.NEAR_RING.y + 1.0 or long_way
	if _is_attacking() or _backing_off or not AttackDirector.is_player_open() or d <= VSTEP_MIN_DIST or not want_close:
		_vstep_best = d
		_vstep_progress_at = _time
		return false
	if d < _vstep_best - VSTEP_PROGRESS:
		_vstep_best = d
		_vstep_progress_at = _time
	var stuck := _time - _vstep_progress_at > VSTEP_NO_PROGRESS
	if not (stuck or long_way) or _time < _vstep_ready_at:
		return false
	var spot := _vanish_spot(player)
	if spot == Vector3.INF:
		_vstep_ready_at = _time + 1.0  # nowhere clear: look again shortly
		return false
	_vstep_spot = spot
	_vstep_until = _time + VSTEP_HIDE + VSTEP_SHOW
	_vstep_done = false
	_vstep_ready_at = _time + VSTEP_COOLDOWN
	fighter.move_input = Vector3.ZERO
	if fighter.rig:
		CombatFX.afterimage(fighter)
		fighter.rig.set_body_visible(false)
	return true

func _finish_vanish_step(player: Fighter) -> void:
	_vstep_done = true
	var look := _flat(player.get_ground_position() - _vstep_spot)
	if fighter.has_method(&"teleport_to"):
		fighter.teleport_to(_vstep_spot, look)
	else:
		fighter.global_position = _vstep_spot
		fighter.reset_physics_interpolation()
	if fighter.rig:
		fighter.rig.set_body_visible(true)
		CombatFX.puff(fighter.get_aim_point())
	_nav_path = PackedVector3Array()
	_vstep_best = _dist_to(player)
	_vstep_progress_at = _time
	vanish_steps += 1
	vanish_stepped.emit(_vstep_spot)

## A clear floor spot VSTEP_RADII from the player with a clear line to it,
## preferring the player's front (so the Duelist reappears in view).
func _vanish_spot(player: Fighter) -> Vector3:
	var center := player.get_ground_position()
	var fwd := _flat(player.get_forward())
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	# In a cramped room (an office with desks) 2.5 m may not fit: try others.
	for radius: float in VSTEP_RADII:
		for k in 12:
			@warning_ignore("integer_division")
			var i: int = (k + 1) / 2 * (1 if k % 2 == 1 else -1)  # 0, 1, -1, 2, -2, ...
			var c := center + fwd.rotated(Vector3.UP, deg_to_rad(30.0) * i) * radius
			if AttackDirector.nav_ready() and not AttackDirector.nav.is_walkable(c):
				continue
			if _spot_free(c) and _clear_line(center, c):
				return c
	return Vector3.INF

## A point beside the blocked line (SIDE_ROUTE_OFFSETS) seen from here and
## seeing the goal, keeping to the side used last; INF if none.
func _side_point(me: Vector3, goal: Vector3) -> Vector3:
	var dir := _flat(goal - me)
	if dir.length() < 0.05:
		return Vector3.INF
	dir = dir.normalized()
	var perp := Vector3(-dir.z, 0.0, dir.x)
	for sgn: float in [_side_sign, -_side_sign]:
		for off: float in SIDE_ROUTE_OFFSETS:
			var p := me + perp * sgn * off + dir * 0.5
			if _spot_free(p) and _clear_line(me, p) and _clear_line(p, goal):
				return p
	return Vector3.INF

## Best waypoint toward `goal`: one hop (visible from both ends), else the
## first point of a two-hop route.
func _find_waypoint(me: Vector3, goal: Vector3) -> Vector3:
	var pts := _get_nav_points()
	var from_me: Array[Vector3] = []
	var from_goal: Array[Vector3] = []
	var best := Vector3.INF
	var best_cost := INF
	for p in pts:
		if _flat(p - me).length() < ENTRY_REACH:
			continue
		var seen_me := _clear_line(me, p)
		var seen_goal := _clear_line(p, goal)
		if seen_me:
			from_me.append(p)
		if seen_goal:
			from_goal.append(p)
		if seen_me and seen_goal:
			var cost := _flat(p - me).length() + _flat(goal - p).length()
			if cost < best_cost:
				best_cost = cost
				best = p
	if best != Vector3.INF:
		return best
	for p in from_me:
		for q in from_goal:
			if p == q or not _clear_line(p, q):
				continue
			var cost := _flat(p - me).length() + _flat(q - p).length() + _flat(goal - q).length()
			if cost < best_cost:
				best_cost = cost
				best = p
	return best

## Spawn positions and entry-path points of the arena (doors and room routes).
func _get_nav_points() -> PackedVector3Array:
	_nav_age += get_physics_process_delta_time()
	if _nav_age < 5.0:
		return _nav_points
	_nav_age = 0.0
	_nav_points = PackedVector3Array()
	var arena := get_tree().get_first_node_in_group(&"arena")
	if arena and arena.has_method(&"get_enemy_spawns"):
		for entry: Dictionary in arena.get_enemy_spawns():
			_nav_points.append(entry.get("position", Vector3.ZERO))
			_nav_points.append_array(entry.get("path", PackedVector3Array()))
	return _nav_points

## True on this brain's tick of every SLOT_STRIDE (periodic path work).
func _my_tick() -> bool:
	return (Engine.get_physics_frames() + _slot) % SLOT_STRIDE == 0

func _set_move(v: Vector3) -> void:
	v.y = 0.0
	# Guarding already slows the walk (Fighter.BLOCK_WALK_MULT); do not stack.
	var mult: float = 1.0 if _block_down else float(SPEED_MULT.get(fighter.archetype, 1.0))
	fighter.move_input = v.limit_length(1.0) * mult

func _separation() -> Vector3:
	var push := Vector3.ZERO
	var me := _pos()
	for e in AttackDirector.get_enemies():
		if e == fighter or not is_instance_valid(e) or e.is_dead():
			continue
		var away := _flat(me - e.get_ground_position())
		var d := away.length()
		if d >= SEPARATION:
			continue
		if d < 0.01:
			away = Vector3(cos(get_instance_id()), 0.0, sin(get_instance_id()))
			d = 0.01
		var w := 1.0 - d / SEPARATION
		push += away.normalized() * w * (0.5 if e.is_down() else 1.0)
	return push

## Slide along walls ahead. A ray hit only blocks when it lies in the
## body's path (within BODY_CLEARANCE of the movement line); an obstacle
## beside the path (e.g. a pillar edge a whisker sees) is passed, not
## braked for.
func _avoid_walls(v: Vector3, probe: float) -> Vector3:
	if v.length() < 0.05 or not fighter.is_inside_tree():
		return v
	var space := fighter.get_world_3d().direct_space_state
	if space == null:
		return v
	var origin := _pos() + Vector3.UP * WALL_PROBE_HEIGHT
	var dir := _flat(v).normalized()
	var perp := Vector3(-dir.z, 0.0, dir.x)
	var mask := Layers.WORLD | Layers.DESTRUCTIBLE
	var speed := v.length()
	# Forward at waist and head height (a hole knocked into a wall at one
	# height is no way through), plus two whiskers.
	for probe_ray: Vector2 in [Vector2(0.0, 0.0), Vector2(0.0, HEAD_PROBE_RISE), Vector2(0.0, -LOW_PROBE_DROP),
			Vector2(WHISKER_ANGLE, 0.0), Vector2(-WHISKER_ANGLE, 0.0)]:
		var angle := probe_ray.x
		var d := dir.rotated(Vector3.UP, angle)
		var length := probe if angle == 0.0 else probe * 0.7
		var o := origin + Vector3.UP * probe_ray.y
		var q := PhysicsRayQueryParameters3D.create(o, o + d * length, mask, [fighter.get_rid()])
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var n: Vector3 = hit["normal"]
		n.y = 0.0
		if n.length() < 0.1:
			continue
		n = n.normalized()
		var rel := _flat(hit["position"] - o)
		var in_path := absf(rel.dot(perp)) < BODY_CLEARANCE and rel.dot(dir) > 0.0
		var into := v.dot(n)
		# Only a near head-on push is redirected; a glancing one is left to
		# move_and_slide, which slides along the face by itself.
		if in_path and into < -0.7 * speed:
			v -= n * into
			# Head-on into a pillar or wall: slide round it, not to a stop.
			if angle == 0.0 and v.length() < speed * 0.3:
				v += Vector3(-n.z, 0.0, n.x) * _side_sign * speed * 0.8
		var dist := rel.length()
		if dist < 0.6:
			v += n * 0.3 * (1.0 - dist / 0.6)
	return v

## The stuck metric, from what the last tick asked (move_input) and where the
## body went. Not free to move (down, stunned, held, attacking, a knockback or
## sidestep, a hitstop freeze) never counts as stuck.
func _track_stall(delta: float) -> void:
	var free := not fighter.is_dead() and not _is_impaired() and not _is_attacking() and not fighter.is_frozen() \
		and not (fighter.combat != null and fighter.combat.has_forced_velocity())
	if _sw_start == Vector3.INF:
		_sw_start = _pos()
	_sw_t += delta
	if free:
		_sw_free += delta
		var mult := fighter.combat.get_move_speed_mult() if fighter.combat else 1.0
		_sw_asked += _flat(fighter.move_input).limit_length(1.0).length() * Tuning.ENEMY_WALK_SPEED * mult * delta
	if _sw_t < STALL_WINDOW:
		return
	var moved := _flat(_pos() - _sw_start).length()
	var stalled := _sw_free >= _sw_t * 0.8 and _sw_asked >= STALL_MIN_SPEED * _sw_t \
		and moved < STALL_SHARE * _sw_asked
	if stalled:
		stuck_time += _sw_t
		if stuck_time > max_stuck_time:
			max_stuck_time = stuck_time
			max_stuck_at = _pos()
		if stuck_time >= _next_escalate:
			_next_escalate = stuck_time + STALL_ESCALATE
			_escalate_stall()
	else:
		stuck_time = 0.0
		_next_escalate = STALL_ESCALATE
	_sw_t = 0.0
	_sw_free = 0.0
	_sw_asked = 0.0
	_sw_start = _pos()

## Stalled for STALL_ESCALATE: the grid may be wrong here (a shoved prop, a
## broken piece): re-test the cells round us, re-plan, and detour the other way.
func _escalate_stall() -> void:
	if AttackDirector.nav_ready():
		AttackDirector.nav.refresh(_pos(), 2.0)
		AttackDirector.nav.penalize(_pos(), STALL_PENALTY_RADIUS)
	_nav_path = PackedVector3Array()
	_route_point = Vector3.INF
	_side_locked = false
	_side_sign = -_side_sign
	var base := _flat(fighter.move_input)
	base = base.normalized() if base.length() > 0.05 else fighter.get_forward()
	# Back straight out of the wedge (a little to the other side), then re-plan.
	_detour_dir = (-base * 0.8 + Vector3(-base.z, 0.0, base.x) * _side_sign * 0.6).normalized()
	_backoff_until = _time + STALL_BACKOFF
	_detour_until = _time + STALL_BACKOFF + DETOUR_TIME * 0.5

func _check_stuck(v: Vector3) -> void:
	_stuck_timer += get_physics_process_delta_time()
	_stuck_intent = maxf(_stuck_intent, v.length())
	if _stuck_timer < STUCK_CHECK:
		return
	var moved := _flat(_pos() - _stuck_pos).length()
	if _stuck_intent > 0.5 and moved < STUCK_MOVE and _time >= _detour_until:
		var base := _flat(v).normalized()
		var side := Vector3(-base.z, 0.0, base.x) * (1.0 if _rng.randf() < 0.5 else -1.0)
		_detour_dir = side
		_detour_until = _time + DETOUR_TIME
	_stuck_timer = 0.0
	_stuck_intent = 0.0
	_stuck_pos = _pos()

func get_courtyard_bounds() -> AABB:
	_bounds_age += get_physics_process_delta_time()
	if _bounds_age > 2.0:
		_bounds_age = 0.0
		var arena := get_tree().get_first_node_in_group(&"arena")
		if arena and arena.has_method(&"get_courtyard_bounds"):
			_bounds = arena.get_courtyard_bounds()
		else:
			var h := DEFAULT_BOUNDS_HALF
			_bounds = AABB(Vector3(-h, 0.0, -h), Vector3(h * 2.0, 4.0, h * 2.0))
	return _bounds

## Where enemies may stand: the courtyard, grown to take in the player when
## the player is outside it (knocked through a wall into a room).
func _play_bounds() -> AABB:
	var b := get_courtyard_bounds()
	var player := _get_player()
	if player != null and not player.is_dead():
		var p := player.get_ground_position()
		if p.x < b.position.x or p.x > b.end.x or p.z < b.position.z or p.z > b.end.z:
			b = b.expand(Vector3(p.x, b.position.y, p.z)).grow(PLAYER_OUTSIDE_GROW)
	return b

func _clamp_to_bounds(p: Vector3) -> Vector3:
	var b := _play_bounds()
	var m := minf(BOUNDS_MARGIN, minf(b.size.x, b.size.z) * 0.25)
	p.x = clampf(p.x, b.position.x + m, b.end.x - m)
	p.z = clampf(p.z, b.position.z + m, b.end.z - m)
	return p

func _bounds_push() -> Vector3:
	var me := _pos()
	var inside := _clamp_to_bounds(me)
	var out := _flat(inside - me)
	return out.limit_length(1.0) * 1.5

func _camera_forward() -> Vector3:
	var cam := get_viewport().get_camera_3d() if get_viewport() else null
	if cam == null:
		return Vector3.ZERO
	var f := _flat(-cam.global_basis.z)
	return f.normalized() if f.length() > 0.01 else Vector3.ZERO

func _face(point: Vector3) -> void:
	var d := _flat(point - _pos())
	if d.length() > 0.05:
		fighter.face_dir = d.normalized()

func _pos() -> Vector3:
	return fighter.get_ground_position()

func _dist_to(other: Fighter) -> float:
	if other == null or not is_instance_valid(other):
		return INF
	return _flat(other.get_ground_position() - _pos()).length()

static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)
