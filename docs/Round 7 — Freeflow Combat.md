# Round 7 — Freeflow Combat

This round rebuilds the player's kit from the user's playtest feedback. It **wins over the original spec, Upgrade Spec 2, the Feel Reference and every earlier round** wherever they disagree about the player's controls, moves, reactions, defence, grabs or camera. The ragdoll, destruction, blood and audio systems stay; everything here is built on top of them.

Out of scope this round: animation quality (poses are functional placeholders; a mocap pass comes later) and performance testing.

**Amendment (user, 2026-11-03).** Jump, wall run, vault/mantle, teleport, pursuit and the Battering Ram **stay**. They are the "god path": as the player upgrades, they move extremely fast, crack the ground, ram enemies into the air, teleport after launched bodies and follow up by launching them further or spiking them into the ground. Hold-for-heavy also applies to the three kicks. Space is Jump; Counter moves to V (and the mouse thumb button). Teleport and pursuit are free (cooldowns and a chain cap). The Focus meter is gone. Upgrades are pause-menu debug settings this round. See **God path** below. Where older lines in this doc disagree, the amendment wins.

## The feedback this answers

1. The moves and controls were too complex to be fun. Fewer moves, each on its own button, that still combine into combos.
2. Combat was spammy and quick. Hits must land with weight, every hit staggers the enemy, and a hit that pushes the enemy back is followed automatically.
3. The lock-on camera was weird. Remove it. Free camera, freeflow targeting (pick the enemy with the stick, the fighter closes the gap).
4. Grabs: no parkour while carrying. Grab, then drive the enemy forward at speed and slam them through things, or throw them like a baseball.

## Design rules

- **One button, one move.** The only context rules are: the punch button counts its string (jab, cross, hook), holding it gives the heavy version, and a move that lands on an enemy in a special state pays off (the payoff table).
- **Combos come from states, not strings.** Every move leaves the enemy in a state. Some moves hit harder on some states. Uppercut into roundhouse works because the uppercut lifts and the roundhouse launches a lifted body.
- **Commit to every swing.** Moves are longer, presses during a move's startup and active frames are ignored, and only one press is buffered. Mashing never makes you faster.
- **The chosen target is always hit.** A strike glides to its target and connects if the target is still within reach on the first active frame and not invulnerable. Whiffs happen only with no target in range.
- **Every hit staggers.** No hit is a tiny flinch. Each move has its own reaction, push distance, stun time and hitstop.

## Controls

| Action | Keyboard + mouse | Gamepad |
| --- | --- | --- |
| Move | WASD | Left stick |
| Camera | Mouse | Right stick |
| Punch (tap: jab → cross → hook; hold: heavy) | LMB | X |
| Leg kick | RMB | LT + X |
| Gut punch | Q | B |
| Uppercut | E | LB |
| Front kick | F | LT + A |
| Roundhouse | R | LT + B |
| Grab / release | C | RB |
| Counter | V / mouse thumb (back) | Y |
| Jump (sprint + jump at a wall: wall run) | Space | A |
| Dash: tap = dodge, or teleport just before a hit lands, or pursuit right after a launch; hold = sprint; drive while holding a body | Shift | RT |
| Pause | Esc | Start |
| Restart | Backspace | Back |
| Help / debug / fullscreen | F1 / F3 / F11, Alt+Enter | — |

Gamepad: LT is the **kick layer** (`kick_layer` action). While it is held, X, A and B are the leg kick, front kick and roundhouse (A is Jump without the layer). The PlayerController resolves the layer; CombatController only sees the resolved action.

While holding a body: LMB (X) = throw (hold to wind up), RMB (LT + X) = knee, Shift (RT) = drive, C (RB) = release.

Removed buttons: Heavy, Kick, Block/parry, Crouch, Focus, Lock-on, lock next/prev.

## Moves

Frames are 1/60 s of the fighter's own time: startup / active / recovery. Recovery is the value on a miss; on a hit the next move may start after `R7_CHAIN_CUT` of it (see Chains). All numbers are in `Tuning` (Round 7 block, `R7_MOVES`).

| Move | Button | Frames | Damage | Reaction | Push | Stun | Hitstop | Weight |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Jab | LMB 1st | 7/3/14 | 5 | snap | 0.4 m | 0.45 s | 0.07 s | 0.2 |
| Cross | LMB 2nd | 9/3/16 | 7 | snap | 0.6 m | 0.5 s | 0.08 s | 0.3 |
| Hook | LMB 3rd | 11/4/18 | 9 | spin | 0.7 m | 0.6 s | 0.10 s | 0.45 |
| Heavy jab | hold LMB 1st | 20/4/18 | 10 | snap | 1.4 m | 0.7 s | 0.12 s | 0.6 |
| Heavy cross | hold LMB 2nd | 22/4/20 | 13 | snap | 1.8 m | 0.75 s | 0.13 s | 0.7 |
| Heavy hook | hold LMB 3rd | 24/5/22 | 15 | knockdown | 1.5 m | — | 0.14 s | 0.8 |
| Uppercut | E | 12/4/20 | 10 | lift | 0.3 m | airtime | 0.11 s | 0.6 |
| Gut punch | Q | 10/4/20 | 8 | fold | 0.3 m | 1.1 s | 0.12 s | 0.55 |
| Leg kick | RMB | 10/4/18 | 7 | buckle | 0.2 m | 0.9 s | 0.09 s | 0.45 |
| Front kick | F | 14/4/22 | 10 | push | 2.8 m | 0.8 s | 0.11 s | 0.65 |
| Roundhouse | R | 18/5/26 | 14 | knockdown | 1.5 m | — | 0.14 s | 0.85 |
| Counter | Space | 4/3/16 | 8 | push | 1.2 m | 0.9 s | 0.10 s | 0.6 |

- **Punch string.** The LMB counts 1, 2, 3 (jab, cross, hook) and wraps back to the jab after the hook. The count continues while the chain is alive (a hit, then the next press inside the chain window plus `R7_CHAIN_GRACE`). Any other move in between does not reset it. A whiff or a dropped chain resets it to the jab.
- **Hold for heavy.** A press still held at `R7_HOLD_THRESHOLD` (0.2 s) becomes the heavy version (`R7_HEAVY_OF`): the punch string's position, or the kick. A heavy's startup counts from the press. A quick tap fires on its frame data (a jab does not wait for the hold decision unless the button is still held at the end of its startup). Heavies break guard.
- **Heavy kicks**: heavy leg kick (longer buckle), heavy front kick (4.5 m push, knockdown-weight), heavy roundhouse (launches on its own at 11 m/s). Numbers in `R7_MOVES`, payoffs in `R7_PAYOFFS`.
- **Uppercut and gut punch** have one version each.
- **Damage** keeps the existing combo damage scaling (`CombatController.combo_scale`).

## Reactions (victim states)

`Fighter.react(kind, direction, push, stun, info)` applies a reaction; `Fighter.get_react_state()` reports it while it lasts. While reacting, a fighter cannot act (`can_act()` is false). Push is a slide along the hit direction over about the first 40% of the stun, on the feet, with a stumble step when push ≥ 1 m.

| Kind | What it looks like | State reported |
| --- | --- | --- |
| `snap` | Head snaps back, upper body rocks, steps back | `&"snap"` |
| `spin` | Head and shoulders turn away with the hook, half-turn stumble | `&"spin"` |
| `fold` | Doubled over, hands at the stomach, head low and forward | `&"fold"` |
| `lift` | Popped off the ground: a controlled ballistic arc to `R7_LIFT_HEIGHT` (1.0 m) above the feet, arms loose, lands into a knockdown if nothing follows | `&"lift"` |
| `buckle` | Leg gives way, drops to one knee, head at about chest height of a standing fighter | `&"buckle"` |
| `push` | Shoved back hard, stumbling steps, arms flailing | `&"push"` |
| `knockdown` | The existing `Fighter.knockdown` (ragdoll fall, gets up) | `&"down"` |
| `launch` | The existing `Fighter.launch` (full ragdoll flight, walls, bowling) | `&"down"` |

Rules:
- `lift` is not a ragdoll launch: the capsule follows the arc and the pose is animated with loose arms (partial physics), so the next hit can find the body reliably. Landing without being hit again turns it into a knockdown.
- Heavy enemies (`Fighter.is_heavy()`) take push x `R7_HEAVY_PUSH_MULT` and stun x `R7_HEAVY_STUN_MULT`, and lift x `R7_HEAVY_LIFT_MULT` in height.
- `HitInfo.tier` is still filled for listeners (FX, camera, audio, AI): the `tier` column of `R7_MOVES` (snap = flinch, spin and push = stagger, fold and buckle = stagger, lift = stagger, knockdown = knockdown, launch = launch).

## Payoffs (state → bigger result)

When a move lands on an enemy in a state, the payoff replaces the move's normal reaction. `Tuning.R7_PAYOFFS[move][state]`.

| Move | On `fold` | On `lift` | On `buckle` |
| --- | --- | --- | --- |
| Jab, cross, hook, leg kick | — | re-pop (juggle) | — |
| Heavy jab, heavy cross | knockdown | re-pop | knockdown |
| Heavy hook | launch 9 m/s | re-pop | launch 9 m/s |
| Uppercut | high lift (1.5 m), x1.5 dmg | re-pop | lift |
| Gut punch | — | re-pop | fold |
| Front kick | launch 10 m/s | launch 13 m/s | knockdown |
| Roundhouse | knockdown x1.5 dmg | launch 15 m/s (flat, into walls) | knockdown x1.5 dmg |

- **Re-pop**: a lifted body hit by a punch or leg kick is pushed up `R7_REPOP_HEIGHT` (0.5 m) again. At most `R7_JUGGLE_MAX` (2) re-pops per lift; past that, the hit lands with no re-pop and the body falls into a knockdown.
- **Launch** uses the existing launch pipeline (`Fighter.launch`, ImpactResolver walls and bowling). Speed and angle come from the payoff entry (heavies x `Tuning.HEAVY_LAUNCH_MULT`).
- A killing blow from a launch or a drive slam severs a limb with chance `R7_SEVER_ON_KILL` (the existing severing code).

## Chains and the input buffer

- A press during the current move's **glide or startup is dropped** (mashing through a wind-up does nothing).
- A press from the **first active frame on** (the hitstop and recovery included) is buffered: the latest press wins, one press only. Pressing on the beat of the hit is the natural rhythm, so it must never be lost. (Changed in integration: an active-frame press used to be dropped, which ate follow-ups pressed on impact.)
- **On a hit**, the buffered press starts after `R7_CHAIN_CUT` (50%) of the recovery. **On a miss**, it waits for the full recovery and the punch string resets.
- The chain stays alive for `R7_CHAIN_GRACE` (0.3 s) after the recovery ends. A press after that starts a new chain (punch string back to the jab).
- Counter and dodge are not buffered: they cancel the player's own startup or recovery at once (never the active frames).
- `CombatController.get_chain_count()` is the number of hits in the current chain (HUD combo counter). `GameEvents.chain_hit` fires on each and `chain_ended` when it drops.

## Freeflow targeting and the auto-follow

- **Target pick at the press** (`Targeting.pick_freeflow_target`): with the stick pushed, the best enemy within `R7_TARGET_CONE` (70°) of the stick (camera-relative) and `R7_TARGET_RANGE` (6 m); with the stick neutral, the current combat target if it is still valid, else the best enemy along camera forward. Downed enemies are never targets. Crawling and fleeing enemies are targets, and any hit on them kills them.
- **Glide**: if the target is farther than the move's reach + `R7_GLIDE_FROM` (0.6 m), the fighter glides to it at `R7_GLIDE_SPEED` (11 m/s, at most `R7_GLIDE_MAX_TIME` 0.35 s) before the startup begins, stopping at reach x `LUNGE_GAP`. Closer targets get the existing short lunge. A glide turns the fighter to face the target and emits `GameEvents.glide_started`.
- **Follow step**: after a hit that pushes the victim up to `R7_FOLLOW_MAX_PUSH` (1.5 m), the attacker steps forward with it during recovery, covering `R7_FOLLOW_SHARE` (80%) of the push, so close-range strings stay close. Bigger pushes (front kick, launches) leave the gap for the next glide.
- **Auto-connect**: a strike whose target is within reach + `R7_CONNECT_MARGIN` (0.5 m) on its first active frame hits it, even if the limb sweep misses. It does not hit if the target is invulnerable, dodging, or down.
- The **combat target** (`CombatController.get_combat_target()`) is the last target struck. It clears when that enemy goes down, dies or leaves `R7_TARGET_RANGE` + 2 m. The camera leans toward it.

## Hit feel

- Hitstop per move (table above), on the attacker and victim only. The player's cap rises to `R7_PLAYER_HITSTOP_MAX` (0.16 s).
- Camera punch on every player hit: FOV kick = weight x `R7_CAM_PUNCH_FOV`, trauma = weight x `R7_CAM_PUNCH_TRAUMA`. A launch payoff also asks TimeDirector for `&"finisher"` slow time (`R7_SLOW_FINISHER`).
- FX and sound scale with `HitInfo.weight` (0..1): flash size, impact sound layer (a heavy thump at weight ≥ 0.6), dust on pushes of 1 m or more.
- **Anti-infinite stays, looser**: per-victim chains break away at `R7_COMBO_ESCAPE_HITS` (10) hits; stun decay starts at hit `R7_COMBO_STUN_DECAY_FROM` (6), `R7_COMBO_STUN_DECAY` per hit, down to `R7_COMBO_STUN_MIN`.
- **Enemy tell armor**: an enemy in an armored tell (heavy archetype, `MoveData.armor`) takes tapped punches with damage and a small snap but keeps attacking. Heavies, specials and kicks break the armor.
- **Enemy guard**: a guarding enemy blocks tapped punches. Heavies, the gut punch, the uppercut and every kick break the guard (stagger).

## Defence

**Counter (Space).**
- Every enemy strike opens a counter window on its target `R7_COUNTER_WINDOW` (0.4 s) before its first active frame, through its active frames. `CombatController` emits `GameEvents.counter_window(attacker, target, true, counterable)` when it opens and `false` when the attack ends or is cancelled.
- A Counter press with an open counterable window: the player becomes invulnerable at once (`R7_COUNTER_INVULN`), glides to the attacker if it is within `R7_COUNTER_GLIDE` (3 m), and plays the counter move (always connects). The attacker's attack is cancelled. Every other attack whose first active frame falls inside the invulnerable time misses.
- With several windows open, the earliest attack is countered.
- A press with no counterable window open locks the counter out for `R7_COUNTER_WHIFF_LOCK` (0.4 s).
- **Uncounterable attacks** (grabs and the heavy's shoulder charge) show a blue tell. Counter does nothing against them; dodge instead.
- Counter cancels the player's own startup or recovery, never active frames, never while the player is reacting or down.

**Dodge (Shift tap).** (With the teleport upgrade on, a Shift press inside `R7_TELEPORT_WINDOW` before an enemy attack's first active frame teleports instead: see God path. Right after a launch, it is a pursuit.)
- The press starts it at once: `R7_DODGE_DIST` (2.5 m) over `R7_DODGE_TIME` (0.22 s) along the stick, or straight back from the nearest attacker when the stick is neutral.
- Invulnerable for `R7_DODGE_INVULN` (0.25 s), then `R7_DODGE_COOLDOWN` (0.2 s) before the next dodge.
- Cancels the player's own startup or recovery.

**Sprint (Shift hold).** Still held after `Tuning.DASH_HOLD_SPRINT`, the dodge flows into the existing sprint ramp (cap `Tuning.debug_speed_cap`: 8, 10 or 12 m/s). A strike from a sprint glides like any other and gets the sprint-strike result (God path).

**Counter key**: V or the mouse thumb button (pad Y).

Removed: parry, guard (Block hold), sidestep, Focus mode and the Focus meter, the counter bonus.

## Grab, drive and throw

**Grab (C).** The target is picked like a strike (freeflow pick, glide up to `R7_GRAB_GLIDE` 3 m). Startup `Tuning.GRAB_FRAMES`. A neutral standing enemy may break it (the existing per-archetype chance). Reacting, downed and dead bodies connect at once. With no body in reach, a loose prop within `Tuning.GRAB_RANGE` is picked up as before. The hold is always a collar clinch, with the body held upright in front. Stick-chosen grab parts are gone.

**Holding.** The clinch lasts at most `R7_HOLD_MAX` (3 s), then the victim struggles out (both stumble). Driving resets that clock.
- **Knee (RMB)**: the existing hold knee, up to `Tuning.HOLD_KNEES_MAX`.
- **Release (C)**: drops the body in front; the victim stumbles.

**Drive (hold Shift while holding).**
- The player runs forward with the body held in front, speed ramping from `R7_DRIVE_START_SPEED` (4 m/s) to `R7_DRIVE_MAX_SPEED` (9.5 m/s) over `R7_DRIVE_RAMP_TIME` (1 s). Steer with the camera and stick at up to `R7_DRIVE_TURN_RATE` (120°/s).
- Releasing Shift ends the drive and keeps the hold. At `R7_DRIVE_MAX_TIME` (3 s) the body is thrown forward at the current speed.
- **Hitting a breakable** (wall panel, pillar, clutter, door frame: anything `WorldTags.breakable_of` finds) with the held body: energy E = ½ (victim mass + `R7_DRIVE_MASS_SHARE` x player mass) v², through the breakable contract `receive_impact(energy, hit_pos, velocity, footprint)`.
  - `&"break"` (or a passable hole): the drive goes through, speed x sqrt(1 − absorption) (at least `R7_DRIVE_MIN_SPEED`), the victim takes `R7_DRIVE_BREAK_DAMAGE`. The drive can break several things in a row.
  - Anything else (crack, bounce, an unbreakable wall): **slam**. The drive ends, and the victim takes `R7_DRIVE_SLAM_DAMAGE` + `R7_DRIVE_SLAM_DAMAGE_PER_MS` x v and is knocked down against the wall. Hitstop `R7_DRIVE_SLAM_HITSTOP`, trauma by speed. The hold ends.
  - Below `R7_DRIVE_SLAM_MIN_SPEED` (3 m/s) it is only a shove: the victim is staggered and the hold ends.
- **Enemies in the path** are bowled (knockdown, `R7_DRIVE_BOWL_DAMAGE`). The drive keeps `R7_DRIVE_BOWL_KEEP` of its speed.
- A hit on the player during a drive ends the drive and the hold.

**Throw (LMB while holding).**
- Tap = a quick throw at `R7_THROW_SPEED_MIN` (8 m/s).
- Hold = wind-up (baseball): the speed grows to `R7_THROW_SPEED_MAX` (18 m/s) at `R7_THROW_WINDUP_FULL` (0.7 s); release throws.
- Direction: camera forward (flat), pitched up `R7_THROW_PITCH` (8°), snapping to an enemy within `R7_THROW_ASSIST_CONE` (20°). While driving, the drive speed x `Tuning.THROW_RUN_SHARE` is added.
- The thrown body is the existing projectile: bowling, walls and clutter.

Removed: carrying through vaults, jumps and wall runs; the sprint grab drag; the air body slam; giant swings and limb grabs from the player's kit.

## Movement

Kept: walk, sprint, dodge, step-ups, **jump (Space), wall run and kick-off, vault, mantle, air mantle, air dash, landing levels and the landing shockwave, the Battering Ram, dropping strikes** (an attack in the air or late in a vault). Removed from the player: crouch. Carrying a body through vaults, jumps and wall runs stays removed (the drive replaces it).

## God path (amendment)

The fantasy: the more the player upgrades, the more they feel like a god. Upgrades this round are pause-menu debug settings (`Tuning.debug_speed_cap` 8 / 10 / 12, `debug_ram_level` 0–3, `debug_teleport`, `debug_pursuit_max` 0–3); the progression that earns them comes in a later round.

- **Dash routing**: holding a body → drive. Otherwise Defence first: inside the pursuit window after a launch the player caused → **pursuit**; with `debug_teleport` on, inside `R7_TELEPORT_WINDOW` before an enemy attack's first active frame and off `R7_TELEPORT_COOLDOWN` → **teleport**. Otherwise Traversal: tap = dodge, hold = sprint.
- **Teleport** (free): the existing teleport behind the attacker (`TELEPORT_SPOTS`; a sidestep when no spot is free). The attacker's attack misses and it is open from behind.
- **Pursuit** (free, at most `debug_pursuit_max` per launch): Dash within `PURSUIT_WINDOW` after a launch the player caused (strike, payoff, sprint strike, ram, throw), stick neutral or toward the body → teleport next to the flying body (`PURSUIT_DIST`) and hang `PURSUIT_HANG` for the attack. The next attack press is the **pursuit hit**, and the stick at that press decides:
  - **Stick pulled back** (toward the camera: deflected 0.3 or more, within 60° of straight back): **spike**. The body is driven straight down at `R7_SPIKE_SPEED` (18 m/s), `R7_SPIKE_DAMAGE` plus the floor impact. The floor cracks or craters (WorldDamage listens to the floor impact), and the impact staggers enemies and blasts breakables within `R7_SPIKE_BLAST_RADIUS`. A spiked body is not pursuable again.
  - **Otherwise**: **relaunch** along camera forward at max(the body's speed, `R7_PURSUIT_RELAUNCH_SPEED`), `R7_PURSUIT_RELAUNCH_ANGLE` up, `R7_PURSUIT_DAMAGE`. The pursuit window reopens for the next link in the chain.
- **Sprint strikes**: a strike committed at speed v ≥ 6 m/s toward its target (wall-run strikes and vault drops count as the cap). Punches and the leg kick push x (1 + `R7_SPRINT_PUSH_PER_MS` (v − 6)) and are at least a push. Heavies, the front kick, roundhouse and uppercut **launch** at `R7_SPRINT_LAUNCH_BASE` + `R7_SPRINT_LAUNCH_PER_MS` (v − 6) m/s (11 m/s at the 8 m/s cap, 17 m/s at 12), `R7_SPRINT_LAUNCH_ANGLE` up. A sprint strike drops the runner to walk (as before).
- **Battering Ram**: the existing levels; **level 3 now launches** normal enemies at runner speed x `R7_RAM_LAUNCH_SHARE`, `R7_RAM_LAUNCH_ANGLE` up, and the runner keeps 95% of their speed. Rammed launches open the pursuit window.
- **Ground cracks at speed**: sprinting at ≥ `R7_SPEED_CRACK_FROM` (10 m/s, the first upgraded cap) cracks the floor under each footstep (`WorldDamage.damage_floor`, level 1 crack, within the floor-decal budget). Hard and heavy landings crack and crater as before.
- **Wall run** is the existing one (sprint + Jump by a runnable wall). Any attack off a wall run counts as a full-speed sprint strike; the kick-off launches.

## Camera

- **Lock-on is removed**: the actions, the rig's lock state, the HUD reticle, the player's strafe mode. `CameraRig.get_lock_target()` stays and always returns null until every caller is gone.
- **Free orbit** stays (mouse and right stick only; no auto-rotation behind the player).
- **Combat framing**: the existing crowd/duel distances stay. The look-at leans toward the combat target by `R7_CAM_LEAN` (25% of the way). Yaw turns on its own only to keep the player and the combat target on screen, at most `R7_CAM_AUTO_YAW_RATE` (40°/s), never against the player's input.
- **Glides** must not jolt the camera: follow damping covers an 11 m/s glide smoothly.
- **Hit punch**: FOV kick and trauma per hit (Hit feel).
- **Drive**: FOV + `R7_CAM_DRIVE_FOV`, pull back `R7_CAM_DRIVE_PULLBACK`, lower `R7_CAM_DRIVE_DROP`.
- **Throw wind-up**: zoom in by `R7_CAM_THROW_ZOOM_FOV` while winding up.
- Launch framing, last-kill close-up and the death camera stay.

## Enemies

- Enemy moves, tells, tokens and archetypes stay. Every enemy **strike** shows an orange tell lasting at least `R7_COUNTER_WINDOW` + `R7_TELL_MARGIN` (0.1 s) before its first active frame. Grabs and the heavy's shoulder charge are **uncounterable**, with a blue tell.
- Enemies in a reaction state do nothing. After a push they re-approach.
- Removed AI behaviour: sidestepping the player's sprint strikes, the Duelist's teleport counter and parry. The Duelist guards (broken by heavies, the gut punch, the uppercut and kicks) and answers a broken guard with a hook.
- The AI does not try to break a grab once the clinch has connected, and never during a drive.

## HUD

- Removed: Focus bars, lock-on reticle, zone readout, charge meter, speed cap and Ram debug settings, wall-run and parkour hints.
- **Combo counter**: chain hits, large, popping on each hit, fading after `chain_ended`.
- **Counter prompt** above every attacker with an open counter window aimed at the player: orange for counterable, blue for dodge-only.
- F1 help lists the new controls. Restart is Backspace / Back and a pause-menu item.
- Debug overlay (F3): the current move, string position, chain state, buffered press, glide, the target's reaction state.

## Effects

- Hit flash, impact sound and dust scale with `HitInfo.weight`.
- Counter: a sharp flash and a distinct counter sound on `GameEvents.countered`.
- Drive: footstep thuds and rising wind while driving (`drive_started`/`drive_ended`); a slam boom, dust and debris burst on `drive_slam`.
- Throw: whoosh on release; the throwing arm glows during the wind-up.
- Removed: Focus tint, zone highlight. Code that only served removed features may stay if harmless.

## Poses (placeholder quality)

Every new move needs a readable pose move with a wind-up, contact and follow-through. Heavies get a deeper wind-up and bigger follow-through. Reaction poses must make each state readable from the camera. Polish waits for the mocap pass.

- Moves: `jab`, `cross`, `hook`, `heavy_jab`, `heavy_cross`, `heavy_hook`, `uppercut`, `gut_punch`, `leg_kick`, `front_kick`, `roundhouse`, `counter`, `dodge`, `glide` (a fast forward lean / run-in), `throw_windup` (hold), `throw_release`.
- Holds: `drive_hold` (leaning forward, driving the clinched body), `clinch_hold`.
- Reactions: `react_snap`, `react_spin`, `react_fold` (hold), `react_lift` (hold), `react_buckle` (hold), `react_push`.

## Acceptance (automated, through the real input path where input matters)

1. Each button fires its move; tap and hold on LMB give jab/cross/hook and their heavies; the string wraps and resets on a whiff or a dropped chain.
2. Presses during glide/startup are dropped, one press from the first active frame on is buffered, the chain cut applies on a hit only; mashing at 20 Hz never shortens a 3-hit string's total time; a follow-up pressed in the hit's hitstop comes out.
3. Every listed reaction produces its state, push (±20%) and stun (±0.05 s); every payoff in the table produces its result; re-pop caps at 2.
4. Uppercut → roundhouse launches a grunt at 15 m/s ±1 into the air (a wall in the path cracks or breaks per the existing wall table).
5. A target 4 m away is reached by a glide and hit; auto-connect hits a target that sidesteps 0.3 m during startup.
6. Counter: a press inside the window counters every orange-tell enemy move (100/100 bot); outside it, the whiff lock applies; blue-tell moves cannot be countered; a second attack landing during the counter's invulnerability misses.
7. Dodge: invulnerable for 0.25 s, travels 2.5 m ±0.2, holds into sprint.
8. Drive: from a standstill the speed reaches 9.5 m/s ±0.3 at 1 s; a drywall panel breaks and the drive continues; a concrete wall slams (victim knocked down, damaged, hold ended); a grunt in the path is bowled.
9. Throw: tap 8 m/s, full wind-up 18 m/s ±0.5, aim assist snaps within 20°.
10. Camera: no lock-on anywhere; the player stays on screen through glides, drives and launches.
11. Waves 180 s and Duel 120 s soaks with the new soak bot: 0 errors.
