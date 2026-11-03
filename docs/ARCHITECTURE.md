# Ragdoll Brawler — architecture and build contract

The game spec is `Ragdoll Brawler — Godot Game Spec.md` in the project root. This file says how the code is split, who owns what, and the rules that keep parallel work compatible.

## First playable (v1) scope

Goal: a build the user can open in Godot and play.

- **Duel mode** (1v1 against the Duelist in The Yard) must work well. It is the vertical slice (spec M3–M6).
- **Waves mode** (4 waves, Tuning.WAVES) should work. Grunt and Brawler are required; Shield, Brute and Thrower are best effort.
- **Ragdoll Lab** scene from the title menu (spec M1 acceptance scene).
- No Mixamo or Blender assets exist yet. Characters are a **procedural primitive mannequin** on a real `Skeleton3D` with `PhysicalBone3D`s, so a Mixamo rig can replace the mesh later. Walls are **procedurally pre-fractured** (2D Voronoi extruded). Sounds are **procedurally synthesised**. Animation is **procedural keyframes** (PoseLibrary), not clips.
- Cut from v1: dislocation, protect-head pose, building collapse, kill-cam, debris-as-ammo (except Thrower), chaos rounds, second arena, the active-ragdoll addon spike (we use our own torque loop).

## Engine and testing

- Godot **4.8.dev7** at `/Applications/Godot_4_8.app/Contents/MacOS/Godot` (the project was created with it). Keep code 4.7-compatible where cheap. Jolt physics, 120 Hz ticks, physics interpolation on, Forward+.
- Class reference XML for this exact build: `/private/tmp/claude-501/-Users-pahulmatharu-Git-GameDevelopment-big-kick/ade7f50f-6e7f-4258-bdf9-c389a33f54b7/scratchpad/godot_doc/doc/classes/<Class>.xml`. Check method names there before using an API you are unsure of.
- **Never run Godot on the real project directory** (several agents work at once and the `.godot` cache would be clobbered). Test on a private copy:

```bash
G=/Applications/Godot_4_8.app/Contents/MacOS/Godot
P=/Users/pahulmatharu/Git/GameDevelopment/big-kick
C=<your own scratch dir>/proj          # unique per agent
rsync -a --delete --exclude .godot "$P/" "$C/"
"$G" --headless --path "$C" --import    # registers class_name scripts (~2 s)
"$G" --headless --path "$C" res://tests/<module>/<test>.tscn   # test calls get_tree().quit(code)
"$G" --headless --path "$C" --quit-after 600   # run the main scene for 600 frames
```

- Tests live in `tests/<module>/` as a tiny `.tscn` whose root script runs the check, prints results, and calls `get_tree().quit(0)` on pass or `quit(1)` on fail. Use `await get_tree().physics_frame` to step physics. Headless has no rendering, so test logic and physics, not visuals.
- Treat any `SCRIPT ERROR`, `Parse Error` or `ERROR:` line in the output as a failure.
- Other agents' files may be mid-rewrite when you copy. If a file you do not own fails to parse, wait a minute and copy again; do not edit it.

## Ownership

Each file has exactly one owner. Edit only your own files. If you need something from another module, code against its contract stub (it already exists and parses) and note the request in your final report.

| Owner | Files |
| --- | --- |
| core (lead) | `project.godot`, `scripts/core/*` (Layers, Bones, Tuning, HitInfo, GameEvents, Controls, Targeting), `scripts/game/fighter_factory.gd`, this doc |
| A — rig & ragdoll | `scripts/fighter/humanoid_rig.gd`, `ragdoll_controller.gd`, `ragdoll_profile.gd`, `pose_animator.gd`, `pose_library.gd`, `scenes/ragdoll_lab.tscn` + `scripts/lab/*`, `tests/rig/*` |
| B — fighter & combat | `scripts/fighter/fighter.gd`, `scripts/combat/*` (CombatController, PlayerController, MoveData, MoveLibrary, hurtboxes), `tests/combat/*` |
| C — AI | `scripts/ai/*` (AIBrain, AttackDirector autoload, tell glints), `tests/ai/*` |
| D — world | `scripts/world/*` (YardBuilder, Destructible, ImpactResolver autoload, DebrisManager autoload, fracture generation, world materials), `tests/world/*` |
| E — feel & flow | `scripts/core/time_director.gd` (autoload TimeDirector), `scripts/game/*` except fighter_factory (GameMode, CameraRig, HUD, menus), `scenes/main.tscn`, `tests/game/*` |
| F — blood & audio | `scripts/fx/*` (BloodFX, AudioFX autoloads), `shaders/*`, `tests/fx/*` |

## Code conventions

- GDScript 2, static typing everywhere, tabs, `class_name` for reusable classes. Match the style of the contract stubs.
- **Build nodes in code**, not in hand-written `.tscn` files, except tiny test/entry scenes. Fighters, rigs, arenas and HUDs are constructed procedurally.
- Every contract stub's public signatures are fixed. You may add methods, signals and properties.
- Numbers come from `Tuning`. If you need a new number, use a local `const` with a comment and list it in your report so the lead can move it into Tuning.
- Cross-module calls go through the contract API or `GameEvents`. Prefer emitting an event over calling another module directly.
- Real time vs game time: input windows, cooldowns and hitstop use `TimeDirector.now()` and `TimeDirector.real_timer()`. Physics and animation use the scaled delta.
- Physics interpolation is on. After teleporting a node, call `reset_physics_interpolation()` on it. Move physics bodies in `_physics_process`.
- Group membership: every Fighter is in `fighters`; the player also in `player`; enemies in `enemies`; the camera rig in `camera_rig`; every Destructible in `destructibles`; the arena builder in `arena`.

## Collision and render layers

See `scripts/core/layers.gd`. Key rules: a fighter's capsule never touches its own physical bones (collision exceptions). Capsules do not collide with ragdolls or debris; bones and debris do collide with capsules (so walking pushes bodies). Small debris never collides with other small debris. Fighter meshes are on render layer 2 (`VIS_CHARACTERS`), and world decals leave that layer out of their cull mask.

## Rig conventions (A implements, everyone relies on them)

- Bone names are in `scripts/core/bones.gd` (Godot `SkeletonProfileHumanoid` names). 16 bones, 14 physical (hands ride the forearms).
- The character faces **-Z**; its right is **+X**; Y is up. Fighter forward = `-global_basis.z`.
- Every bone's rest rotation is identity; rest pose is a standing I-pose (arms down). Spine and head bones point +Y; arm and leg bones point -Y.
- Pose rotations are Euler degrees in bone-local space. Positive X swings a hanging limb **forward** (toward -Z) and leans the spine **back**. Positive Z swings a hanging limb toward **+X** (right arm out, left arm in).
- Standing height about 1.8 m at height scale 1.0; hips about 0.95 m above the floor.
- Bone masses: `Bones.MASS_70 * mass_kg / 70.1`. A 70 kg fighter's physical bones sum to 70 kg.

## How the modules connect

```
PlayerController / AIBrain ──move_input, face_dir, combat.press()/start_enemy_attack()──▶ Fighter
Fighter ──owns──▶ HumanoidRig (A), RagdollController (A), PoseAnimator (A), CombatController (B)
CombatController ──HitInfo──▶ victim.take_hit() ──▶ damage, flinch/stagger/launch ──▶ GameEvents
GameEvents.fighter_launched ──▶ ImpactResolver (D) sweeps the flying body ──▶ Destructible.receive_impact(), bowling, impact damage
GameEvents ──▶ BloodFX, AudioFX (F), CameraRig, HUD, TimeDirector triggers (E)
AttackDirector (C) ◀── AIBrain token requests; reads player state + camera
GameMode (E) ──▶ YardBuilder.build() (D), FighterFactory.spawn_*()
```

Who emits what:

- **B (Fighter/Combat):** hit_landed, hit_blocked, perfect_dodge, teleport_counter, pursuit, air_recovery, grab_*, thrown, attack_tell, attack_active, attack_whiff, fighter_spawned, fighter_launched, fighter_grounded, fighter_recovered, fighter_damaged, fighter_died, focus_changed, limb_severed (B decides when to sever and calls `rig.sever()`), screen_shake for hits.
- **D (World):** body_impact, wall_cracked, wall_broken, body_bowled.
- **E (Game):** round_started, wave_started, wave_cleared, round_over. TimeDirector slow-motion triggers are requested by whoever detects the event: B for perfect dodge and big launch, D for wall break, E for the final KO.

## Final report format (every agent)

1. What you built, file by file, in a few lines each.
2. Tests you ran and their results (paste the pass/fail lines).
3. Anything stubbed, skipped or known broken.
4. Requests for other modules (API additions, Tuning constants to add).

## Round 2 (improvements after the first playable)

Round 2 came from two reviews (destruction, fighting), real-time soaks and a windowed showcase (`tests/integration/showcase.gd`). Rules are unchanged: own files only, private copies, `--fixed-fps 120` for tests. New shared tools: `tests/run_all.sh <copy_dir> [modules]` runs every module test; `tests/integration/run_soak.sh <copy_dir> duel|waves <seconds>` runs the soak bot (real time; `FAST=1` for fixed fps).

**Clock change (lead):** `TimeDirector.now()` is now `Engine.get_physics_frames() / physics_ticks_per_second`: real time in play, but in step with the simulation under `--fixed-fps` and capture. Do not use `Time.get_ticks_*` for gameplay windows.

**Core changes (lead):** `Tuning`: `KICK_LAUNCH` 8.6, Duelist HP 750 with `damage_mult`, `perfect_dodge`, `focus`, `armor_bonus` keys; Brute `armor_bonus`; `IMPACT_REPEAT_MULT`, `IMPACT_FLIGHT_CAP`; `BIG_LAUNCH_ENERGY` 6,000; `ENEMY_GETUP_INVULN`. `Targeting.pick_target(..., include_down := false)` now skips downed fighters. New `GameEvents`: `dodge_feedback`, `armor_absorbed`, `impact_damaged`, `wall_chain`, `debris_landed`.

**New cross-module APIs (the owner implements them; callers code against these names):**

| API | Owner | Callers |
| --- | --- | --- |
| `CombatController.start_counter(target: Fighter, tell_time: float) -> bool` — AI teleport counter: costs 1 `fighter.focus`, teleports behind `target` (same spot search as the player's), emits `GameEvents.attack_tell(fighter, &"counter", tell_time)`, then a `back_kick` the player can perfect-dodge | B | C (Duelist) |
| `CombatController.pick_up_debris(body: RigidBody3D) -> bool` — takes a chunk from DebrisManager (`release`) into the right hand; the next `e_throw_debris` throws that chunk | B | C (Thrower) |
| `ThrownChunk.launch_body(body: RigidBody3D, velocity: Vector3, thrower: Fighter)` (static) — turns any RigidBody into a projectile that hits hurtboxes | B | B (debris kick), C |
| `PoseAnimator.set_aim_target(world_pos: Vector3)` / `clear_aim_target()` — strike IK bends toward the target | A | B |
| `PoseLibrary.has_move(id: StringName) -> bool` (static) and new move `punt` | A | B |
| `Destructible.is_point_open(world_pos: Vector3) -> bool` — true where cells are gone (partial holes) | D | F (decals), D |
| `GameEvents.attack_tell` kind `&"counter"` draws a **blue** glint | C | B emits |
| `AudioFX` sound ids `clank` (armor), `break_drywall`, `break_brick`, `break_wood`, `debris` | F | B, D, F |

## Upgrade 2 (docs/Ragdoll Brawler — Upgrade Spec 2.md)

Scope: milestones U1–U7 of the upgrade spec. The roguelike section is design only and is **not built**. Hazard props are "Later" and not built. Same rules as before: own files only, private copies, `--fixed-fps 120` for tests, numbers in `Tuning`.

**Decisions on the spec's open questions (defaults until the user says otherwise):** the proposed key map, with block on Q and jump on Space; crouch is **C only** (on macOS Ctrl+click is a right click, so Ctrl as crouch would turn crouch + punch into a kick); zone aiming from the camera centre; crouching makes standing grabs whiff (the spec's crouch rule); no tier ladder or boons yet.

**Ownership changes:** `scripts/fighter/fighter.gd` and `scripts/combat/player_controller.gd` move from B to the new agent **H**. New agent **G** owns limb grabs. Everything else keeps its owner.

| Owner | Upgrade 2 files (in addition to their existing ones) |
| --- | --- |
| core (lead) | `scripts/core/body_zones.gd` (new), Tuning/GameEvents/HitInfo/Controls additions, `tests/integration/*`, `tests/run_all.sh` |
| A — rig & ragdoll | new poses in `pose_library.gd`, stance in `pose_animator.gd`, broken arm and grip in `ragdoll_controller.gd` |
| B — combat | `combat_controller.gd`, `move_data.gd`, `move_library.gd`, `scripts/combat/combo_graph.gd` (new), `hurtbox.gd`, `combat_fx.gd`, `thrown_chunk.gd`, `projectile_probe.gd`, `tests/combat/*` |
| C — AI | unchanged (tells now glow on the attacking limb) |
| D — world | unchanged |
| E — feel & flow | unchanged (camera rewrite, Focus time) |
| F — blood & audio | unchanged |
| **G — limb grabs** (new) | `scripts/combat/limb_grab.gd`, `scripts/combat/grab_lab.gd` + `scenes/grab_lab.tscn`, `tests/grab/*` |
| **H — body & player input** (new) | `scripts/fighter/fighter.gd`, `scripts/combat/player_controller.gd`, `scripts/combat/input_interpreter.gd` (new), `scripts/combat/zone_aim.gd` (new), `tests/input/*` |

**Contract already in the tree (lead):**
- `Controls` key map: actions `punch` (LMB/J, X), `kick` (RMB/K, Y), `grab` (F, B), `jump` (Space, A), `crouch` (C, L3), `block` (Q, RB), `dash` (Shift, RT), `focus` (E, LB). `light`, `heavy` and `sweep` are gone. Fullscreen is F11 / Alt+Enter only.
- `CombatController.Action` enum is **unchanged** (LIGHT, HEAVY, KICK, SWEEP, GRAB, BLOCK, DASH) so bots, tests and the showcase keep working: the punch button presses LIGHT, the kick button KICK. HEAVY and SWEEP stay as scripted entry points (B decides: HEAVY = a charged punch press, SWEEP = crouch + kick).
- `Tuning`: every "tuning start" from the upgrade spec (camera, input model, crouch/jump, combos, zones, Focus). Add new numbers as local consts and list them in your report.
- `HitInfo.Level { HIGH, MID, LOW }` and new fields `level`, `zone`, `charge_level`, `combo_index`, `damage_scale`, `juggle`, `air_counter`.
- `BodyZones` (Zone enum, bones per zone, `of_bone`, `AIM_BONE`).
- `GameEvents`: charge_started / charge_level_changed / charge_released, combo_progress / combo_ended, stumbled, tripped, dazed, limb_damaged, arm_broken, crouch_changed, jumped, landed, aim_zone_changed, limb_grab_started / limb_grab_released, wall_slam, focus_started / focus_ended.
- Stubs with fixed signatures (owners implement, callers code against them now):

| API | Owner | Callers |
| --- | --- | --- |
| `Fighter.aim_zone`, `aim_bone`, `is_crouching()`, `is_airborne()`, `get_input_intent()` (&"forward"/&"back"/&"neutral") | H | B, G, E, F |
| `TimeDirector.begin_focus()`, `end_focus()`, `is_focus_active()`, `player_time_factor()`, `player_delta(delta)` | E | H, A, B, F |
| `CombatController.get_charge_level()`, `get_combo_count()`, `get_damage_scale()`, `is_dazed()`, `is_stumbling()`; `MoveData.hit_level` | B | E (HUD), C, H, F |
| `PoseAnimator.set_stance(&"stand"/&"crouch"/&"air")`; poses for every new move, `<move>_charge` hold poses, `stumble`, `dazed`, `land` | A | H, B |
| `RagdollController.break_arm(zone)`, `set_gripped(on)` | A | B, G |
| `LimbGrab.can_grip()`, `start()`, `is_active()`, `set_swing_input()`, `release()`, `break_free()` | G | B |
| `ImpactResolver.track_swing()`, `untrack_swing()`, `nearest_wall_dir()` | D | G, B |
| `WorldMaterials.set_view_fade(node, amount)` (static) | D | E |
| `BloodFX.set_fighter_fade(fighter, amount)`, `limb_glow(fighter, bone, color, duration, intensity)` | F | E, C, B |

**How the pieces meet:**
- Input: `PlayerController` (H) reads actions through `InputInterpreter` (H: press/release timestamps in player time, drops presses while Cmd is held) and calls `combat.press()` / `combat.release()`. **B** decides what a press means: tap vs hold at `Tuning.HOLD_THRESHOLD`, charge levels, the combo string (`ComboGraph`), crouch/jump/forward/back variants from the Fighter queries. Jump and crouch are movement (H); B reads them.
- Focus: H owns the button, the meter drain (`fighter.focus`, bars) and the end conditions, and calls `TimeDirector.begin_focus()/end_focus()` (E: time scale, budget exemption, `player_time_factor`). Every player-side timer and motion goes through `TimeDirector.player_delta()`: velocity and gravity (H), animation (A), combat timers (B). Audio (F) slows world sounds and keeps the player's own at normal pitch.
- Zones: H casts from the screen centre to the soft target's hurtboxes each tick, sets `fighter.aim_zone/aim_bone`, and emits `aim_zone_changed`; F highlights the zone on the body; B applies the zone's strike effect and picks the grab type; G runs arm drags and giant swings.
- Tells: C replaces the overhead glint with `BloodFX.limb_glow` on the attacking fist or foot, at the move's `hit_level` (head, waist, feet). Colours stay: white strike, red grab, blue counter.
- Camera: E never follows a flying body in play (widen instead), fades blockers through D's and F's fade APIs, collides the spring arm with `Layers.WORLD` only (floor, outer walls, pillars).

**Order of work:** each agent works in the spec's priority order (U1 → U7) inside its own files, keeping the game playable and its tests green after each step. Expect callers to land against your stubs before you implement them.

## Round 3: wall strikes

The player can punch and kick walls; harder walls take more hits. Contract (lead): `Tuning` "Wall strikes" block (per-surface cell HP and feel targets; agent D may change the values in that block only), `GameEvents.wall_struck(attacker, wall, position, normal, power, result, surface)`, and `receive_strike(attacker, hit_pos, direction, power) -> StringName` on any world node that takes strikes (stubs on `Destructible` and `Pillar`; D adds it to props and the outer concrete walls).
- **B** detects strike contact with world geometry during a move's active frames (player only), finds the first node on the collider or its ancestors with `receive_strike`, and calls it once per move; applies hitstop, recoil and shake.
- **D** turns power into per-cell damage with visible progress and breaks; weakened walls break more easily under body impacts.
- **F** plays per-surface strike sounds, dust and chips on `wall_struck`.
- A strike that knocks cells out also emits `GameEvents.wall_broken` (AI nav refresh, decals). `Destructible.strike_holes` and `last_break_by_strike` let the HUD and camera announce only the first strike hole in a panel and a full break.

## Round 3: anti-infinite

Damage scaling alone never ends a stun loop (P,P,P mashed with the stick neutral killed every archetype in one combo). Contract (lead): `Tuning` "Anti-infinite" constants in the Combos block and `GameEvents.combo_escaped(victim, attacker)`. B implements:
- Combos are counted per victim (hits taken from anyone without a `COMBO_DROP` gap); damage scaling uses that count.
- From hit `COMBO_STUN_DECAY_FROM`, flinch/stagger/stumble/daze stun shrinks by `COMBO_STUN_DECAY` per hit, down to `COMBO_STUN_MIN`.
- At `COMBO_ESCAPE_HITS` hits or `COMBO_ESCAPE_STUN` s of stun in one combo the victim breaks away: damage but no stun, `COMBO_ESCAPE_GUARD` s of auto-guard, `COMBO_ESCAPE_PUSH` m of separation, count reset. Applies to the player too.
- At most `JUGGLE_MAX_RELAUNCH` juggle relaunches per flight; ordinary strikes never relaunch a downed body, and hits extend a get-up at most once per knockdown.

## Round 4: free camera and lock-on

The camera is free by default: it turns only when the player turns it (mouse, right stick). No auto-rotation toward enemies or back behind the player during play. Lock-on is a toggle. Contract (lead): `Controls` actions `lock_on` (MMB / Tab / R3), `lock_next` / `lock_prev` (mouse wheel / D-pad); `Tuning` "Camera control and lock-on" block (`CAM_MOUSE_SENS`, `CAM_STICK_SPEED`, `CAM_SENS_RANGE`, `LOCK_*`); `GameEvents.lock_on_changed(fighter, target)`; F1 help rows.
- **E** (camera_rig, HUD, menus) owns the lock: `CameraRig.get_lock_target() -> Fighter` (null = free), and `get_soft_target()` returns the locked target while locked, so combat follows it unchanged. While locked, mouse / right-stick motion moves an aim point over the target's body (zone aiming) and the camera keeps that point at the screen centre. Lock drops beyond `LOCK_BREAK_RANGE`, after `LOCK_LOS_GRACE` s hidden, or on a second press; on the target's KO it moves to the next enemy in range. `lock_on` with no enemy in range recentres the camera behind the player. Mouse sensitivity is a pause-menu setting saved to `user://settings.cfg`.
- **H** (player controller, zone aim): while locked the fighter faces the target and strafes (camera-relative movement circles it); unlocked, movement is as before. Zone aim reads the real camera's centre ray in both modes.
- Cinematic moments the player does not control (own knockdown, KO close-up) may still move the camera; they keep the player in frame.

## Round 5: Feel Reference (docs/Feel Reference — Sifu × Prototype for the Ragdoll Brawler.md)

Scope: every build task F0–F11 (including F7b) of the Feel Reference. **Where it disagrees with the original spec, Upgrade Spec 2 or an earlier round here, the Feel Reference wins.** Never remove or replace the ragdoll system: everything is built on top of it. Every number goes in `Tuning` (the "Round 5" block at the end); a number you need that is not there is a local `const` with a comment, listed in your report.

### Ownership (Round 5)

Same rules: edit only your own files; test on a private copy (`<scratchpad>/agent_<id>/proj`); `--fixed-fps 120`; treat `SCRIPT ERROR`, `Parse Error` and `ERROR:` lines as failures.

| Owner | Files |
| --- | --- |
| core (lead) | `project.godot`, `scripts/core/*` (incl. new `power.gd`), `scripts/game/fighter_factory.gd`, `tests/core/*`, `tests/integration/*`, `tests/run_all.sh`, this doc |
| A — ragdoll & rig | `humanoid_rig.gd`, `ragdoll_controller.gd`, `ragdoll_profile.gd`, `scripts/lab/*`, `scenes/ragdoll_lab.tscn`, `tests/rig/*` |
| P — poses & animation (new) | `pose_library.gd`, `pose_animator.gd`, `tests/anim/*` (new module dir) |
| B — combat | `combat_controller.gd`, `move_data.gd`, `move_library.gd`, `combo_graph.gd`, `hurtbox.gd`, `combat_fx.gd`, `thrown_chunk.gd`, `projectile_probe.gd`, `tests/combat/*` |
| C — AI | `scripts/ai/*`, `tests/ai/*` |
| D — world | `scripts/world/*` (incl. new `world_tags.gd`, `throwable_prop.gd`), `tests/world/*` |
| E — camera & time | `scripts/core/time_director.gd` (autoload), `scripts/game/camera_rig.gd`, `tests/game/test_camera_rig*`, `tests/game/test_time_director*`, new `tests/game/test_cam_*` / `test_time_*` |
| F — FX & audio | `scripts/fx/*` (incl. new screen effects), `shaders/*`, `tests/fx/*` |
| G — grabs & carry | new `scripts/combat/carry.gd`, `limb_grab.gd`, `grab_lab.gd`, `scenes/grab_lab.tscn`, `tests/grab/*` |
| H — fighter, player & defence | `fighter.gd`, `player_controller.gd`, `input_interpreter.gd`, `zone_aim.gd`, new `scripts/combat/defence.gd`, `tests/input/*`, new `tests/defence/*` |
| J — HUD, flow & menus (new) | `scripts/game/hud.gd`, `game_menus.gd`, `game_mode.gd`, `ui_kit.gd`, `scenes/main.tscn`, `tests/game/*` except E's |
| M — movement (new) | new `scripts/fighter/traversal.gd`, new `tests/move/*` |

(`run_all.sh` modules: core rig anim combat ai world game fx grab input defence move. Put each new test scene in your own module dir.)

### Contract already in the tree (lead)

- **`Tuning` Round 5 block**: power score, frame data, damage, tiers, hitstop, launches, defence, Focus, slow-time table, sprint, parkour, wall run, jump/landing, Battering Ram, grabs/throws/props, enemy roster and startups, bodies, camera, screen effects; debug settings as `static var`s (`debug_speed_cap`, `debug_ram_level`, `debug_start_focus`, `debug_overlay`). Values changed in place: archetype health and masses (player 100 HP/70 kg, grunt 100/75, new `stick` 100/75, new `heavy` 160/110; legacy brawler/shield/brute/thrower rescaled and out of Waves; Duelist 200 HP for Duel), `DMG_ENEMY`, `CHARGE_LEVELS` 0.3/0.6/1.0 s, `CHARGE_MULT` (alias `CHARGE_DAMAGE`) 1.0/1.6/2.3/3.2, `GRAB_RANGE` 1.4, `WAVES`, `MAX_ENEMIES_ON_FIELD` 8, `CORPSE_MAX` 20, `CRACK_FRACTION` 0.4, brick 6,000 J, concrete 15,000 J.
- **`Power`** (`scripts/core/power.gd`): `score()`, `tier_of()`, `sweep_tier_of()`, `launch_speed()`, `launch_angle()`, `launch_velocity()`, `launch_speed_for()` (heavies 80%), `launch_damage()`, `strike_damage()`, `pursuit_speed()`, `hitstop_for()`, `trauma_for()`, `wall_energy()`, `bowl_tier()`, `throw_speed()`, `speed_cap()`. `tests/core/test_power` checks all 12 worked examples and the wall table. **Use these; never re-derive the formulas.**
- **`HitInfo`**: `enum Tier { NONE, FLINCH, STUMBLE, STAGGER, KNOCKDOWN, LAUNCH, HARD_LAUNCH, SEVER }`, fields `power`, `tier`, `power_base`, `speed_bonus`, `counter_bonus`, `finisher_bonus`, `sprint`, `ground_strike`, `pursuit`, `sever_cut`; `tier_name()`, `reaction_for_tier()`, `is_launch_tier()`. `reaction` stays for older listeners (B keeps it in step).
- **`Layers.DEAD_BODY`** (bit 9, `MASK_DEAD_BODY`): dead bodies; capsules never touch them.
- **`Controls`**: the Feel Reference table. Light keeps the action name `punch`; new `heavy` (RMB / L / Y); `kick` E / K / B; `grab` G / LT; `focus` F / LB; `crouch` C / R3; lock-on moved to L3 (MMB / Tab unchanged). `tests/core/test_controls` checks both devices and clashes.
- **`Targeting.pick_strike_target(from, aim_dir, sprinting)`**, `strike_score()`, `pick_ground_target()` (the Feel Reference cone scoring).
- **`Bones.CUTS`** gains whole-limb cuts `arm_l`, `arm_r`, `leg_l`, `leg_r`; `Bones.limb_cut_for(bone)`.
- **New signals in `GameEvents`** (Round 5 block, each says who emits): `strike_started`, `parried`, `parry_whiffed`, `teleported`, `sidestepped`, `counter_bonus_changed`, `sprint_started/ended`, `footstep`, `parkour`, `wall_run_started/step/ended`, `landing`, `shockwave`, `rammed`, `carry_changed`, `body_slammed`, `prop_picked_up`, `prop_thrown`, `prop_broken`, `wall_broken_by`, `fleeing_changed`, `last_kill`, `run_ended`.
- **Stubs with fixed signatures** (owners implement; callers code against them now; they do nothing yet, so the game plays as before):

| API | Owner | Callers |
| --- | --- | --- |
| `Traversal` (player only, `fighter.traversal`): `physics_move(delta) -> bool`, `on_dash_pressed() -> bool`, `on_dash_released()`, `on_jump_pressed() -> bool`, `on_strike_started(sprint)`, `begin_drop_strike() -> bool`, `hang(t)`, `get_speed()`, `speed_toward(dir)`, `get_speed_cap()`, `sprint_charge`, `is_sprinting()`, `is_charge_steering()`, `is_vaulting()`, `get_vault_progress()`, `is_wall_running()`, `get_wall_side()`, `get_wall_normal()`, `is_airborne()`, `get_fall_height()` | M | H, B, E, F, J |
| `Defence` (every fighter, `fighter.defence`): `is_enabled()`, `on_block_pressed(now)`, `on_dash_pressed(now) -> bool`, `intercepts(attacker, move_id) -> bool`, `counter_bonus()`, `consume_counter_bonus()`, `get_pursuit_target()`, `on_pursuit_hit(victim)`, `is_parry_locked()`, `is_vanished()` | H | B, C, J |
| `Carry` (every fighter, `fighter.carry`): `is_enabled()`, `on_grab_pressed/released(now)`, `on_attack_pressed(action, now) -> bool`, `on_attack_released`, `held`, `is_holding()`, `is_held()`, `get_holder()`, `connect_enemy_grab(victim, move_id) -> bool`, `drop(reason)`, `get_move_speed_mult()`, `get_sprint_cap_mult()`, `get_vault_max_height()` | G | B, M, H, C, J |
| `RagdollController.stumble(dir, leg_bone)`, `knockdown(dir, hit_bone)`, `limp_chain(bones, physics_amount, fade_time)`, `restore_chain(bones)`, `get_bone_strength(bone)`, `set_getup_after(s)`, `begin_held(bone, hand, holder)`, `end_held()`, `is_held()`, `wake()` | A | H, B, G |
| `PoseAnimator.play_timed(pose_id, duration)`, `set_locomotion_style(style)`, `set_upper_overlay(pose_id)` | P | M, G, B, C, H |
| `Fighter.stumble(dir, leg_bone)`, `knockdown(dir, hit_bone)`, `sever_limb(cut) -> bool`, `get_actor_time()`, `is_fleeing()`, `is_heavy()`, `add_focus(amount, reason)` | H | B, M, G, C, D |
| `CombatController.get_attack_target()`, `suppresses_ram_with(other)`; `time_to_active()` is already real seconds | B | H, M |
| `AttackDirector.set_wave(i)`, `wave_index`, `enemy_startup_frames(move_id)`; `AIBrain.is_fleeing()` | C | J, B, H |
| `WorldTags.is_runnable(collider)`, `surface_of(collider)`, `is_obstacle(collider)` | D | M, F |
| `ThrowableProp` (`kind`, `can_pick_up()`, `pick_up(holder)`, `drop(v)`, `throw(v, thrower)`, `is_held()`) | D | G, A (loose limbs, kind &"limb"), C (dropped stick) |
| `PlayerController.get_aim_dir()` (stick, or camera forward when neutral), `get_sprint_target()` | H | B, J |
| `AIBrain.get_damage_mult()` (one-armed enemies hit at half damage) | C | B |
| Autoload `ScreenFX` (`scripts/fx/screen_fx.gd`): radial blur, speed lines, Focus tint, hit flash; `get_blur_strength()` | F | tests |

- **Routing already wired (lead):** `CombatController.press(BLOCK)` → `defence.on_block_pressed()` first (when enabled); `press(DASH)` → `defence.on_dash_pressed()` → `traversal.on_dash_pressed()` → the old dash; `release(DASH)` → `traversal.on_dash_released()`; `press/release(GRAB)` → `carry` (when enabled); attack presses while `carry.is_holding()` → `carry.on_attack_pressed()`. While `defence.is_enabled()` is false the Upgrade 2 perfect dodge, teleport counter and pursuit still run; likewise `carry.is_enabled()` for grabs. Owners flip their switch to true when their module works; **B then deletes the dead Upgrade 2 code**. `Fighter._physics_process` calls `traversal.physics_move(delta)` after the frozen / ragdolling / held early-outs.

### How the pieces meet (Round 5)

- **One hit pipeline.** Every hit — strikes, enemy hits, thrown bodies, props, Battering Ram, landing shockwaves, ground strikes — is a `HitInfo` passed to `victim.take_hit(info)` → `CombatController.receive_hit()` (B). Strikes carry `power` and B sets `tier` with `Power.tier_of` (sweeps: `sweep_tier_of`); other sources **preset `tier`** (and damage) and B uses it as is. B applies guard, Defence interception, armor/`ignore_flinch`, damage (strike + launch + limb), the reaction by tier, then emits `hit_landed`. Reaction by tier → `Fighter.flinch / stumble / stagger / knockdown / launch / sever_limb` (H) → `RagdollController` (A). Strike reactions come **only from P**: Upgrade 2 rules that forced a reaction (daze auto-launch, juggle x1.3, launcher lift, fixed kick/counter launch speeds, charge-to-launch, air counter x1.25) give way to P. Anti-infinite stun decay / break-away, the juggle relaunch cap and combo damage scaling stay as guards.
- **Contact frame.** On the hit: hitstop on attacker and victim only (`Power.hitstop_for(tier)`, the player capped at `Tuning.PLAYER_HITSTOP_MAX`, via `TimeDirector.hitstop`); the victim holds its contact pose and jitters; then the reaction starts with each bone's velocity from the last two animated poses, **cached before the freeze** (A). Block and Dash pressed during the player's freeze are buffered and fire when it ends (B). A wall break freezes only the flying body for `Tuning.WALL_BREAK_FREEZE` (D).
- **Effects listen, combat does not call them.** Flash, shock ring, blood, sound by tier, screen flash, trails, after-image, charge glow, dust: F, from `GameEvents`. Camera trauma by tier (`Power.trauma_for`, wall break, heavy landing, limb lost): E, from `GameEvents`. Modules stop emitting `screen_shake` for hits, wall breaks and landings (it stays for one-offs such as wall strikes).
- **Slow time has one owner.** TimeDirector (E) implements the `Tuning.SLOW_TIME` table: the strongest (lowest scale) active request wins, nothing stacks, a 1 s cooldown between cooldown-respecting events, and it **requests them itself from events**: `parried` → parry, `teleported` (kind &"counter") → teleport, `wall_broken` → wall break, `limb_severed` → sever, `last_kill` → last kill, player `fighter_died` → player death. Focus mode: H calls `TimeDirector.begin_focus()/end_focus()`. The old `request_slowmo()` stays for callers that still use it. **During any slow motion the player keeps real time** (`player_time_factor() = 1 / Engine.time_scale`), except that a KO / player death ends it; player-side impulses into ragdolls use real speed (velocity x time scale).
- **Per-fighter time.** `Fighter.get_actor_time()` is 0 while frozen: animation, movement and frame timers stop for that fighter only; a ragdolling body stores its bone velocities, gravity off, and gets them back (A). Enemy frame data runs in their own scaled time.
- **Focus.** Bars 0–3 on `fighter.focus`. Income only through `Fighter.add_focus(amount, reason)` (H; ignored during Focus mode): H credits stagger / knockdown / launch hits from `hit_landed` and wall breaks from `wall_broken_by` (the launcher from `ImpactResolver.get_launcher()`); Defence credits parries. Spend: teleport, pursuit, Focus mode (1 each). J sets `player.focus` to `Tuning.debug_start_focus` (default 1) at every wave start.
- **Player speed.** `Traversal.speed_toward(dir)` feeds the speed bonus; B samples it at the strike's commit (press, or charge release) **before** calling `traversal.on_strike_started()`, which drops a sprinting player to walk. A wall-run strike and a vault's dropping strike count as full sprint.
- **AI and the player's strikes.** B emits `strike_started(attacker, target, move_id, sprint, charge_level)` on every strike; C sidesteps sprint attacks and guards tapped strikes from it. Enemy moves (B's `MoveLibrary`, C chooses, P poses): `e_jab`, `e_hook` (the grunt's cross), `e_kick` (front kick), `e_grab`, `e_stick_swing`, `e_stick_thrust`, `e_heavy` (overhead smash), `e_charge` (shoulder charge), `e_grab_slam`. Enemy strikes glow orange from wind-up to first active frame, grabs glow blue on both hands (C via `BloodFX.limb_glow`); Focus tint never dims them (F).
- **Bodies stay.** Dead bodies: `Layers.DEAD_BODY`, freeze after `Tuning.DEAD_FREEZE_AFTER` s at rest (A), up to `CORPSE_MAX` per round, oldest fades (J). The player's feet nudge bodies they walk through (H). Debris stays (freezes at 4 s, cap 150: D); blood decals cap 30 (F); loose limbs cap 12 (A).

### Decisions on open points (lead; defaults until the user says otherwise)

1. The player keeps real time in **all** slow motion, as the doc's "Time, in code" section says (not only Focus mode).
2. **Dash**: a fresh press is first offered to Defence (teleport / sidestep / pursuit, decided at the press by predicting each incoming attack's first active frame in real time); otherwise the short dash starts at once, and a press still held after 150 ms flows into the sprint (no input delay).
3. **Parry** is judged against each attack's first active frame: a Block press in the 8 frames (133 ms) before it parries; one press covers every attack in that window.
4. A **sweep** never hard-launches or severs (it caps at the launch tier).
5. **Heavy** = archetype flag `heavy` or mass ≥ 95 kg.
6. **Lock-on** (Round 4) stays; the free camera stays. Launch framing pulls back to 9 m and leans the look-at toward the body for at most 1 s; yaw turns only if the player or the body would leave the frame, at most 60°/s, and never against the player's camera input.
7. **Concrete** pillars and panels break at 15,000 J (always two hits); the arena's outer boundary walls stay unbreakable.
8. **Focus** is set to exactly 1 bar at every wave start (debug setting overrides).
9. **Roster**: Waves uses grunt / stick / heavy; legacy archetypes stay defined for old tests only; Duel keeps the Duelist.
10. **No Mixamo or Blender**: every new animation is a procedural pose (P). "Split limb meshes" are the mannequin's per-bone parts; wound caps are procedural meshes (A).
11. The Yard gets a shallow **water** patch and a **metal** plate so footstep, landing and body effects are seen (D tags them, F draws them).
12. Gaps in the doc filled with guesses in Tuning and marked: enemy shoulder-charge damage 20, ground-strike frame data, ground-strike range 1.6 m, wood wall damage 10.
13. Focus-mode body-part aiming (open question 2) is **not built**.
14. Player gravity: 9.8 m/s² rising, x1.6 falling (the doc's landing speeds assume this).

Made during the build (owners' calls the lead accepted):

15. A launch-tier strike (P ≥ 5) breaks through any guard, so sprint and charged hits always pay off (B).
16. Battering Ram and landing-shockwave hits deal 0 damage: they are crowd control; launching still takes an attack.
17. Last kill and player death slow the player with the world (and end Focus). All other slow motion keeps the player in real time.
18. Parry and teleport slow time run only for the player's own parries and teleports, not when the Duelist parries the player.
19. Only walls and pillars get wall-break slow time and trauma; broken furniture gets a small shake only.
20. **Earned speed**: the power score's speed bonus, throw speed and the Battering Ram read the sprint ramp only. A dash burst, a lunge or knockback adds nothing, so a dash-tap jab is a standing jab (M, G).
21. Air dash: a Dash tap in the air is the 3 m short dash, once per airtime, adding no power; it gets the full sprint blur (M, F).
22. Crawling enemies (lost a leg) are ground-strike targets, never ordinary strike targets (`Targeting.is_crawling`).
23. A vault's dropping strike counts as full sprint only when the vault began at sprint speed; a walking vault keeps its own speed (M).
24. The air mantle reaches at most 3 m above the take-off floor (one storey), so nobody climbs the outer walls; crouching stops a sprint (M).
25. Only the player and archetypes with `perfect_dodge` (the Duelist) parry; other enemies' Block is a plain guard. The Duelist counters every parry (40% teleport when he has Focus, else a hook) (H, C).
26. Enemies break a neutral grab by chance per archetype (grunt 25%, stick 20%, heavy 50%, Duelist 60%) through `AIBrain.wants_grab_break()` (C, G).
27. Tell colours are shared: `Tuning.TELL_COLOR_STRIKE` (orange), `Tuning.TELL_COLOR_GRAB` (blue).

From the spec-accuracy review:

28. Throws keep an aim assist: along the stick, snapping to an enemy in the strike cone (the same target picking as strikes).
29. The teleport after-image fades over 0.2 s of world time, so it lingers through the teleport's slow motion.
30. Upgraded caps make the speed effects stronger ("same signals, stronger"): at 8 m/s they are exactly the doc's numbers; above it blur, speed lines, trails and wind scale by `1 + 0.5 × (cap − 8) / 4`, blur clamped at 0.85.
31. The Upgrade 2 zone effects (leg-hit slow, arm break after 100 zone damage) are gone: the doc's damage table is complete. Zone aiming still picks the hit zone and chain.
32. The +1 finisher goes to the third hit of a tap string whether or not the earlier hits landed.
33. Any strike that lands on a fleeing enemy (lost a limb, limping or crawling) finishes him.
34. A strike faster than the 150 ms tap/hold threshold (jab, knee, elbow) waits at the end of its startup only while its button is still held; a quick tap fires on its frame data.
35. Pursuit relaunch speed is `Power.pursuit_speed` (heavies 80%, capped at 18 m/s like every flying body).
36. Sprint opening: a Dash press starts the short dash at once, peaking at the speed cap and easing to exactly 6 m/s at 150 ms; a hold hands off there to the ramp, which reaches the cap 1.2 s after the press ("1.2 s of holding"). Speed never falls after the hand-off except for the turn penalty, a strike or a release.
37. A charge (strike or throw) never blocks automatic parkour: it rides the vault or mantle curve and keeps charging. A vault never ends in a dead stop: with a fighter behind the wall it lands shorter or to the side.
38. One turn costs one turn penalty; the wall-run "same wall" cooldown is per wall plane (a facade of panels counts as one wall).

### Acceptance checks (who proves each one)

Each check is an automated test in the owner's module dir that prints its measured numbers.

| Task | Check | Owner |
| --- | --- | --- |
| F0 | physics ≤ 8 ms avg / 12 ms max with 8 live, 20 dead, 150 debris | lead (`tests/integration/perf_crowd`) |
| F0 | Focus mode: same distance per real second within 5% | H |
| F0 | 110 ms hitstop on two fighters, a third keeps moving | H |
| F0 | ragdoll masses 70 / 75 / 110 kg within 1 kg | A |
| F0 | controls: every action on both devices, no clashes | lead (`tests/core/test_controls`) |
| F0 | Ragdoll Lab: one arm limp, rest animated | A |
| F1 | 50 random launches: player in the viewport every frame | E |
| F2 | cap in 1.2 ± 0.1 s; 90° turn in 0.2 s loses 30%; charging at a sprint keeps speed within 5% and turns ≤ 30°/s; any sprint strike drops to walk | M (with B) |
| F2 | blur 0.15 at half charge, 0.6 at full | F |
| F3 | the 12 worked examples through real strikes; launch speed/angle at P 5, 7, 9, 11; level-3 kick on a full grunt leaves it alive and it gets up | B (unit math: lead `test_power`) |
| F3 | walls crack/break per the wall table, concrete on the second 18 m/s hit | D |
| F3 | a jab to the head lowers muscle strength only in the head chain | A (with B) |
| F4 | flash, sound and blood on the hit event's physics frame; a different sound stream per tier | F |
| F4 | player freeze ≤ 60 ms; Block pressed during it fires afterwards | H (with B) |
| F5 | glows ≥ 18 frames before first active early; ≤ 2 token holders 20+ frames apart over 5 min | C |
| F5 | parry bot 100/100; a press outside any window locks parry 20 frames; jab after a parry is P 3.5, knockdown | H (with B) |
| F5 | a staggered stick enemy drops the stick and it can be picked up | C (with G, D) |
| F6 | sidestep at 0 Focus; wall behind → side spot or sidestep + refund; sprint bot through 100 wind-ups spends no Focus; pursuit relaunch rule, third refused; no Focus gained in Focus mode | H |
| F6 | every wave starts with 1 bar | J |
| F6 | two slow-motion requests: only the strongest applies | E |
| F7 | vault 0.9 m keeps ≥ 90%; 1.8 m blocks walking, mantles sprinting; Soft/Hard/Heavy landing levels and the slam stumbles a dummy 2 m away; 200 landings never knock the player down; attack in the last 40% of a vault → dropping strike | M |
| F7b | sprint + Jump by a runnable wall starts a run, walking does not; 200 sprint jabs along a wall start 0 runs; tapped kick off a run P ≥ 5 launches; kick-off reaches the 1.8 m platform; cracked panel not runnable | M (with D) |
| F8 | base: heavy knocks you down, act again within 1.1 s; grunt: both stumble; level 3 knocks down a line of 3 grunts; 200 sprint attacks never knock you down; no collision launches | M |
| F9 | held legs keep moving; tapped throw cracks drywall, level-3 breaks it; 16 m/s throw downs ≥ 2 of 3 grunts; grab flying / downed / dead bodies; thrown brick staggers and shatters | G |
| F10 | severing hides the limb, shows the cap, loose limb at the bone's speed; loose limbs ≤ 12 | A |
| F10 | a legless enemy crawls away and a ground strike finishes him | C (with B) |
| F11 | camera distance follows enemies alive; last kill close-up over 20 waves; death camera | E |
| F11 | death → results screen; end-of-wave counts of bodies, broken props, decals match what was created | J (with D, F) |

### Process (Round 5)

- Work through F0 → F11 in order **inside your own files**, keeping the game playable and your module's tests green after each step. Callers will land against your stubs before you implement them; keep stub signatures.
- **Tests that encode superseded behaviour are rewritten to the Feel Reference by their owner**, never deleted without a replacement and never weakened to pass.
- Other agents' files change under you. If a file you do not own fails to parse, wait a minute and recopy. If you need an API that is not in the contract, use a local fallback and list it under "Requests" in your report: the lead adds it and routes it to the owner.
- Final report: what you built (file by file), the acceptance checks you own with their measured numbers, every test result line, anything stubbed or known broken, requests for other modules.

### Round 5 status (all build tasks F0–F11 done)

- **Tests:** `tests/run_all.sh` → 164 pass, 0 fail (core 2, rig 18, anim 4, combat 27, ai 20, world 20, game 13, fx 22, grab 13, input 12, defence 5, move 8). Every acceptance check in the table above is an automated test that prints its measured numbers; the three bugs the review caught past test doubles are now covered through real input (`tests/combat/test_real_input`, `tests/move/test_review_real`).
- **F0 performance** (`tests/integration/run_perf.sh <copy> [runs]`, `REALTIME=1` for the verdict): 8 live, 20 dead, 150 debris → real time avg 2.72 ms, max 6.74 ms; fixed fps avg 1.96, max 5.03 (budget 8 / 12). Corpse freezing is the one setting that matters.
- **Soaks** (`tests/integration/run_soak.sh <copy> waves|duel <s>`, `FAST=1`): Waves 180 s and Duel 120 s, 0 errors.
- **Review:** four independent reviewers checked F0–F11 against the doc; every finding was fixed or decided above (decisions 28–38).
- **Numbers live in two places by design:** every number the Feel Reference states is in `Tuning` (Round 5 block). Implementation constants each module needed (probe sizes, blend rates, motor gains) stay as commented local `const`s in their files.
- **Known limits:** the launch camera always keeps the player in frame, but frames the flying body on about 63% of follow frames (a body flying past the camera can't be caught within 60°/s and 9 m). The old soak bot (no parries or teleports) dies to wave 1 in about 25 s: the doc's damage and health numbers are flagged by the doc itself as numbers to watch in the first playtests.
- **Not built (by the doc):** the roguelike (speed caps and Battering Ram levels are debug settings in the pause menu), Focus-mode body-part aiming (open question 2).
- **Still the user's:** the doc's feel check after every task (three rounds: did I want to sprint at someone, did a launch feel earned, did I lose track of where I was, did the bodies look physical, did I want to play again).

## Round 6: more destruction (user request)

The user asked for more destructible environment: **clutter in the fight area, breakable structure, and floor and impact damage**. There is no design doc for this round; this section is the spec. It follows the Feel Reference's rules: one energy model (E = ½Mv² of a flying body straight into the object, cracks at `CRACK_FRACTION`), **things stay** for the round, effects listen to events, budgets hold (debris 150, blood decals 30), and the F0 performance budget (≤ 8 ms average, ≤ 12 ms max, real time) must still pass with everything in place. Numbers are in `Tuning` ("Round 6" block).

### Ownership (Round 6)

| Owner | Files |
| --- | --- |
| core (lead) | `scripts/core/*`, `project.godot`, `tests/core/*`, `tests/integration/*`, `tests/run_all.sh`, this doc |
| D — world: structure & floor | `scripts/world/*` **except K's files**, incl. the new `world_damage.gd` (autoload `WorldDamage`), `tests/world/*` |
| K — clutter (new) | `scripts/world/clutter_layout.gd`, `scripts/world/loose_prop.gd` (moved from D), any new `scripts/world/furniture*.gd` / `glass_pane.gd` / clutter classes it creates, `tests/clutter/*` (new module dir) |
| F — FX & audio | `scripts/fx/*`, `shaders/*`, `tests/fx/*` |
| Phase B (after D and K land the layout): C AI, M movement, E camera, J HUD & flow | their Round 5 files |

### Contract (lead, already in the tree)

- **Breakable world contract (duck-typed).** Any world object that can break implements:
  - `receive_impact(energy, hit_pos, velocity, footprint := Rect2()) -> StringName`: a flying body (ImpactResolver). Returns `&"bounce"`, `&"crack"`, `&"hole"` or `&"break"`.
  - `receive_strike(attacker, hit_pos, direction, power) -> StringName`: punches and kicks (CombatController, unchanged).
  - `receive_blast(center, radius, power, source) -> StringName`: shockwaves (WorldDamage).
  - Members `absorption`, `kind`, `surface`, `is_broken`; `get_face_normal(from)` and `get_half_extent_along(n)` (used by the resolver's energy direction); group `&"breakables"`.

  `WorldTags.breakable_of(collider)` finds it, and D switches ImpactResolver from `is Destructible or is Pillar` to this so flying bodies break clutter too.
- **`ClutterLayout.build(yard)`** (K): YardBuilder calls it at the end of `build()`, after the spawns exist.
- **Autoload `WorldDamage`** (D): `floor_level_at(pos)`, `damage_floor(pos, energy, surface)`, `blast(center, radius, power, source)`, `get_floor_counts()`, `reset()`. It listens to `landing` (hard and heavy), `shockwave`, `body_slammed`, `body_impact` (floor), `wall_broken` and `structure_collapsed`; nobody needs to call it.
- **Events** (`GameEvents`, Round 6 block): `furniture_broken(node, position, kind, energy, by)` (K), `structure_collapsed(node, position, kind)` (D), `floor_damaged(position, radius, level, surface)` (D), `world_blast(center, radius, power, source)` (D).
- **Falling structure** hits fighters through the normal pipeline: a preset-tier `HitInfo` with kind `&"debris"` via `victim.take_hit()` (stagger or knockdown by the piece's energy, `Tuning.FALLING_*`). Small debris never hurts anyone.

### Rules

- **Readable fight space.** Clutter sits at the edges of the fight space, around pillars, along walls and in a lobby corner; the centre lanes, spawns, entries, breach spots, the platform's approaches and the wall-run lanes' open floor stay clear. Low clutter (tables, benches, barrels, planters) is a vaultable obstacle; tall clutter (shelves, glass panes, partitions) is a wall until it breaks.
- **Bodies are the main tool.** A launched or thrown body that breaks clutter keeps `sqrt(1 − absorb)` of its speed and takes `FURNITURE_BODY_DAMAGE`; it can break several things in one flight. Strikes break things by `strike_hp`. Blasts break the lightest things (glass, cardboard) and shove or crack the rest.
- **Things stay.** Broken pieces, wall holes, collapsed sections, fallen overhead pieces and floor marks persist for the round (pieces freeze after 4 s at rest). Raise `DEBRIS_MAX` above 150 only if the performance check still passes with it.
- **Physics stays physical.** Pieces are real bodies built from the object's own parts. Overhead pieces fall under gravity after a short creak and dust, and land where physics puts them.

### Decisions (Round 6)

1. "Open floor" beside a wall-run lane is the band 1.2–3.5 m from the runnable face along the lane; it is keep-clear (`get_structure_features()` `run_open`), so a wall-run strike always lands on open floor.
2. Blasts break only `RUN_THROUGH_KINDS` (glass, cardboard). Every other breakable at most cracks (lowering its break energy) or comes loose; bodies and strikes do the breaking.
3. One event is one floor mark: a carry body slam, its heavy landing and the victim's floor impact count once. Floor marks sit on the floor (never on clutter, rubble, corpses or mid-air).
4. Falling structure is physical: it breaks or cracks the breakables it lands on by its own ½mv², hurts fighters only while falling or moving fast (≥ 3 m/s), and its blast fires where it lands.
5. `DEBRIS_MAX` is 250 (measured with full clutter: real time 2.5–2.7 ms average, ≤ 7.3 ms max).
6. Ram and shockwave hits on clutter follow the normal rules: running into glass or cardboard at `RUN_THROUGH_SPEED` smashes it and the runner keeps 100%; loose props are shoved (the runner keeps M/(M+m)).

### Acceptance checks (Round 6)

| Check | Owner |
| --- | --- |
| The courtyard holds at least `CLUTTER_MIN_COUNT` (30) breakable clutter objects of at least `CLUTTER_MIN_KINDS` (8) kinds; fight lanes, spawns, entries, breach spots and wall-run lanes stay clear (a test measures every clearance) | K |
| Every clutter kind: below its break energy it holds (crack or bounce), above it it breaks; strikes break it at `strike_hp`; its pieces persist and freeze; a body that breaks it keeps `sqrt(1 − absorb)` of its speed and takes 5 damage; one thrown body breaks two things in a line | K |
| A broken shelf spills 2–4 throwable props; glass shatters from a body, a strike and a nearby slam; a fighter running at 6 m/s or more smashes glass and cardboard | K |
| The platform's faces break into holes (wood) and its deck stays walkable and mantle-able; the second low wall is concrete and breaks on the second 18 m/s hit; at least 2 partitions and the door frames break | D |
| Panel collapse: knocking out the cells under part of a panel leaves no floating cells; unsupported cells fall within `COLLAPSE_DELAY` | D |
| Every pillar holds an overhead piece; snapping the pillar drops it within `PILLAR_COLLAPSE_DELAY`; it lands, persists, and knocks down a fighter standing under it (any fighter, the player included) | D |
| Floor: a soft landing marks nothing, a hard landing cracks, a slam craters; damage accumulates (repeated hard landings on one spot reach a crater); the tiled plaza pops tiles as persistent pieces; a slam shatters glass within 2.5 m and hops light props; floor marks persist up to `FLOOR_DECAL_MAX` | D (marks drawn by F) |
| Effects for every Round 6 event: splinters, glass, cardboard, fabric by surface; collapse creak, dust and boom; crack and crater decals by level; blast chips and dust; each on the event's frame, within budgets | F |
| F0 performance with the full clutter plus 8 live, 20 dead and 150 debris: real time ≤ 8 ms average, ≤ 12 ms max | D + K (lead runs it) |
| AI reaches the player from every spawn through the clutter; no enemy is stuck for more than 3 s in a 300 s Waves soak (C). Parkour in the new Yard: low clutter vaults, tall clutter blocks walking (M). The camera keeps the player visible through clutter and overhead pieces (E). The end-of-wave counts include clutter, collapses and floor marks (J). Soaks: 0 errors | C, M, E, J, lead |

### Process (Round 6)

Same rules as Round 5: own files only, private copies under `<scratchpad>/agent_<id>/`, `--fixed-fps 120`, every check proved by a test that prints measured numbers and goes through the real game path, superseded tests rewritten not weakened, requests in the report. Phase A (D, K, F) builds the content; phase B (C, M, E, J) adapts and verifies once the layout exists; then a review, the performance run and the soaks.

### Round 6 status (done)

- **Tests:** `tests/run_all.sh` → 183 tests (core 2, rig 18, anim 4, combat 27, ai 21, world 26, game 14, fx 24, grab 13, input 12, defence 5, move 10, clutter 7); the final run passed 182 and the one flaky check (`defence/test_focus_income`, a launcher read during the launch hitstop) was fixed and passes 5/5.
- **What's in the Yard:** 32 courtyard clutter objects of all 11 kinds (lobby, market, garden, pillar groups) plus side-room clutter (56 total); breakable platform skirts, two partitions, both low walls, 9 door frames with falling lintels, a 160 kg beam and sign on every pillar, a tiled plaza, and a floor that cracks, craters and turns to rubble. Everything stays for the round; `DEBRIS_MAX` 250.
- **Performance** (full clutter, 8 live, 20 dead, 150 debris): real time 2.85 ms avg / 6.21 ms max (with the editor and a game instance running); fixed fps 2.04 / 4.13. Budget 8 / 12.
- **Soaks:** Waves 180 s and Duel 120 s, 0 errors; bodies break and crack clutter in normal play.
- **AI:** no enemy stalls more than 3 s in 300 s Waves soaks over 8 seeds (worst 2.5 s); navigation keeps a wide-body layer and refreshes on every break and collapse.
- **Movement through clutter:** steps keep 100% of a sprint, vaults keep 90%, sprinting smashes glass and cardboard at 100%, tall clutter blocks walking; every courtyard object has a clear approach.

## Round 7: Freeflow combat (docs/Round 7 — Freeflow Combat.md)

The user playtested Round 6 and found the kit too complex, the hits spammy and weightless, and the lock-on camera wrong. Round 7 rebuilds the player's kit. **Where the Round 7 doc disagrees with any earlier spec or round, Round 7 wins.** Ragdoll, destruction, blood and audio stay; everything is built on top of them. Animation quality and performance testing are out of scope (the user's call): poses are functional placeholders, and no perf runs are needed.

### Ownership (Round 7)

Same rules as before: edit only your own files; test on a private copy (`<scratchpad>/agent_<id>/proj`); `--fixed-fps 120`; treat `SCRIPT ERROR`, `Parse Error` and `ERROR:` lines as failures.

| Owner | Files |
| --- | --- |
| core (lead) | `project.godot`, `scripts/core/*` except `time_director.gd`, `scripts/game/fighter_factory.gd`, `tests/core/*`, `tests/integration/*`, `tests/run_all.sh`, docs |
| B — combat | `combat_controller.gd`, `move_data.gd`, `move_library.gd`, `combo_graph.gd`, `hurtbox.gd`, `combat_fx.gd`, `thrown_chunk.gd`, `projectile_probe.gd`, `tests/combat/*` |
| H — fighter, player & defence | `fighter.gd`, `player_controller.gd`, `input_interpreter.gd`, `zone_aim.gd`, `defence.gd`, `tests/input/*`, `tests/defence/*` |
| M — movement | `traversal.gd`, `tests/move/*` |
| G — grabs, drive & throw | `carry.gd`, `limb_grab.gd`, `grab_lab.gd`, `scenes/grab_lab.tscn`, `tests/grab/*` |
| E — camera & time | `scripts/core/time_director.gd`, `scripts/game/camera_rig.gd`, `tests/game/test_camera_rig*`, `test_time_director*`, `test_cam_*`, `test_time_*` |
| P — poses | `pose_library.gd`, `pose_animator.gd`, `tests/anim/*` |
| C — AI | `scripts/ai/*`, `tests/ai/*` |
| J — HUD, flow & menus | `hud.gd`, `game_menus.gd`, `game_mode.gd`, `ui_kit.gd`, `scenes/main.tscn`, `tests/game/*` except E's |
| F — FX & audio | `scripts/fx/*`, `shaders/*`, `tests/fx/*` |
| A (rig & ragdoll), D (world), K (clutter) | not active; send requests to the lead |

### Contract already in the tree (lead)

- **`Controls`**: the Round 7 key map (punch, leg_kick, gut_punch, uppercut, front_kick, roundhouse, grab, counter, dash, kick_layer, pause, restart on Backspace / Back). `Controls.KICK_LAYER` maps the pad's LT layer. `Controls.LEGACY_ACTIONS` (heavy, kick, jump, crouch, block, focus, lock_on, lock_next, lock_prev) stay registered **without bindings** so old readers never error; remove your reads of them. `tests/core/test_controls` checks the map.
- **`Tuning` Round 7 block** (end of the file): `R7_MOVES` (frames, damage, reaction, push, stun, hitstop, weight, listener tier, guard break per move), `R7_PUNCH_STRING`, `R7_HEAVY_OF`, `R7_HOLD_THRESHOLD`, `R7_PAYOFFS`, reactions, chains and anti-infinite, targeting and glide, hit feel, counter and dodge, grab/drive/throw, camera. `SLOW_TIME[&"finisher"]` is new. A number you need that is not there is a local `const` with a comment, listed in your report.
- **`HitInfo`** new fields: `react`, `weight`, `push`, `stun`, `lift_height`, `payoff`, `victim_state`, `chain_index`, `counter`, `drive`. `tier` is still filled from the move's listener tier.
- **`Targeting.pick_freeflow_target(from, stick, current, camera_fwd, max_range)`**, `is_freeflow_target()`, `freeflow_score()` (implemented).
- **`GameEvents` Round 7 block**: `chain_hit`, `chain_ended`, `glide_started`, `counter_window` (B); `countered`, `counter_whiffed`, `react_started` (H); `dodged` (M); `drive_started`, `drive_ended`, `drive_impact`, `throw_windup` (G).
- **`CombatController.Action`** gains `LEG_KICK, GUT_PUNCH, UPPERCUT, FRONT_KICK, ROUNDHOUSE, COUNTER` (appended; older ints unchanged).
- **Stubs with fixed signatures** (at the end of each file; owners implement, callers code against them now):

| API | Owner | Callers |
| --- | --- | --- |
| `CombatController.play_counter(target) -> bool`, `get_chain_count()`, `get_string_index()`, `get_combat_target()`, `is_gliding()`, `is_counter_window_open(on)`, `is_attack_counterable()` | B | H, E, J, C, lead (bots) |
| `Fighter.react(kind, direction, push, stun, info)`, `get_react_state()`, `get_react_time_left()`, `is_reacting()`, `is_lifted()` | H | B, C, P, F, E, J |
| `Defence.on_counter_pressed(now) -> bool`, `is_countering()`, `get_counterable_attackers()` | H | B, J, lead (bots) |
| `Traversal.start_dodge(dir)`, `is_dodging()`, `is_dodge_invulnerable()`, `begin_drive()`, `end_drive()`, `is_driving()`, `get_drive_speed()`, `set_drive_speed(v)`, `get_drive_dir()` | M | G, H, E, F |
| `Carry.on_drive_pressed(now) -> bool`, `on_drive_released(now)`, `is_driving()`, `get_throw_windup()` | G | B, E, F, J |

### How the pieces meet (Round 7)

- **Input (H → B).** PlayerController maps buttons to `CombatController.Action` (punch → LIGHT, leg_kick → LEG_KICK, gut_punch → GUT_PUNCH, uppercut → UPPERCUT, front_kick → FRONT_KICK, roundhouse → ROUNDHOUSE, grab → GRAB, counter → COUNTER, dash → DASH), resolving the pad kick layer first. It stops reading jump, crouch, focus, block and lock-on. Before an attack press it sets facing only through B's target pick (no separate auto-face pick). `get_aim_dir()` returns the camera-relative stick (zero when neutral). B picks targets with `Targeting.pick_freeflow_target(fighter, stick, get_combat_target(), camera forward)`.
- **Routing (B, in `press`/`release`).** While `carry.is_holding()`: LIGHT → `carry.on_attack_pressed/released` (throw wind-up and throw), LEG_KICK → carry (knee), DASH → `carry.on_drive_pressed/released` (it returns false with a prop in hand: fall through), GRAB → carry (release). Otherwise: COUNTER → `defence.on_counter_pressed(now)` (Defence finds the earliest open counterable window, starts its invulnerability, cancels the attacker's attack, emits `countered`, then calls `combat.play_counter(attacker)`); **DASH → `defence.on_dash_pressed(now)` first (pursuit, then teleport: amendment), then `traversal.on_dash_pressed()` (tap = dodge at once, hold = sprint)**, release → `traversal.on_dash_released()`; GRAB → carry; the rest are strikes (in the air or late in a vault: the dropping strike). Legacy actions: HEAVY = heavy string punch, KICK = FRONT_KICK, SWEEP = LEG_KICK, BLOCK = the AI's guard. Parry and sidestep are gone. **Jump** (H): PlayerController → `traversal.on_jump_pressed()` (jump, wall run, kick-off), else `Fighter.jump()` with the jump buffer, as in Round 5.
- **Hits (B → H).** B resolves a player strike from `R7_MOVES` and `R7_PAYOFFS` using the victim's `get_react_state()`, applies guard and tell armor, heavy-enemy multipliers (push, stun, lift) and the anti-infinite stun decay, fills the HitInfo Round 7 fields, then calls `victim.react(kind, ...)` for snap / spin / fold / lift / buckle / push / repop, `victim.knockdown()` for knockdown and `victim.launch()` for launch. Hitstop per move (player cap `R7_PLAYER_HITSTOP_MAX`), then `hit_landed`. Enemy hits on the player keep their Round 5 preset tiers.
- **Reactions (H, with P's poses).** `Fighter.react` runs the state: push slide, stun, the lift arc (capsule ballistic, partial physics arms via RagdollController's existing APIs), the re-pop cap (`R7_JUGGLE_MAX`, then knockdown), landing from a lift into a knockdown. `can_act()` is false while reacting. Emits `react_started`. Poses: `react_<kind>` from P.
- **Invulnerability (H).** `Fighter.is_invulnerable()` adds `traversal.is_dodge_invulnerable()` and `defence.is_countering()`.
- **Dodge (M).** A dodge cancels the player's own startup or recovery (`combat.cancel()`), never active frames, never while reacting, down or held. Emits `dodged`. Hold flows into the existing sprint.
- **Drive (G with M).** G owns the hold, the probes ahead of the held body, slams, breaks, bowling, damage and events; M owns the run itself (`begin_drive`, speed ramp, steering, `set_drive_speed`, `end_drive`). Breakables through `WorldTags.breakable_of()` and `receive_impact(energy, hit_pos, velocity, footprint)`.
- **Camera (E)** reads `combat.get_combat_target()`, `combat.is_gliding()`, `carry.is_driving()`, `carry.get_throw_windup()`; punches on `hit_landed` by `info.weight`; requests `&"finisher"` slow time for a player hit with `info.react == &"launch"`. The lock-on goes; `get_lock_target()` returns null until no caller is left, then it may go too.
- **HUD (J)** combo counter from `chain_hit` / `chain_ended`; counter prompts from `counter_window` (or `defence.get_counterable_attackers()`).
- **AI (C)** keeps every enemy strike's tell ≥ `R7_COUNTER_WINDOW + R7_TELL_MARGIN`; grabs and the heavy's charge are uncounterable with a blue tell (B marks them in MoveData). Enemies in a reaction state do nothing.

### Decisions (Round 7; the user's amendment of 2026-11-03 is folded in)

1. Defence is **counter (V / mouse thumb, pad Y) + dodge (Shift tap)**, plus the free **teleport** upgrade (Shift just before a hit). Parry, guard, sidestep, Focus mode and the **Focus meter** are removed from the player.
2. Removed from the player: Heavy and Kick buttons, charge levels, zone aiming, crouch and its moves, sweep, backfist, rising uppercut, elbow and knee strings, the counter and finisher power bonuses, ground strikes, carrying through parkour, the sprint grab drag, stick-chosen grab parts, the air body slam, lock-on. **Kept (amendment): jump and dropping strikes, wall run and kick-off, vault, mantle, air mantle, air dash, landings and the landing shockwave, the Battering Ram, teleport, pursuit, sprint speed feeding strikes.**
3. Hold-for-heavy applies to the punch button and the three kicks. Uppercut and gut punch have one version each.
4. Crawling and fleeing enemies are ordinary freeflow targets; any hit on them kills them.
5. Sprint strikes, ram launches, pursuit relaunches and spikes follow the doc's **God path** section (`Tuning` "Round 7 amendment" block). Upgrades are the debug settings `debug_speed_cap`, `debug_ram_level`, `debug_teleport`, `debug_pursuit_max` (pause menu > Debug, J).
6. Enemy hits on the player keep their Round 5 tiers and reactions.
7. Severing happens only on killing blows from launches and drive slams (`R7_SEVER_ON_KILL`).
8. The Duelist guards and answers a broken guard with a hook; no teleport counter, no parry.
9. Gamepad kicks are the LT kick layer on X / A / B (A is Jump without the layer); uppercut is LB.
10. Animation polish waits for a later mocap round; P's poses only need to read clearly.
11. No performance runs this round.

### Process (Round 7)

- All owners work in parallel against the stubs. Keep your module's tests green after each step. Callers land against your stubs before you implement them; keep the stub signatures.
- **Removing features:** remove the player-facing paths of everything in decision 2 that lives in your files. Delete code that only served removed features when it is yours and clearly dead. Keep enemy-side behaviour working.
- **Tests:** delete tests that only check removed features (list them in your report). Rewrite tests that encode superseded behaviour to Round 7, never weakening them to pass. Add a test for each acceptance check you own (below), through the real input path where input matters (`Input.action_press` / `parse_input_event` → PlayerController → InputInterpreter).
- Other agents' files change under you. If a file you do not own fails to parse, wait a minute and recopy. Need an API that is not in the contract? Use a local fallback and list it under "Requests".
- Final report: what you built (file by file), the acceptance checks you own with their measured numbers, every test result line, tests deleted or rewritten, anything stubbed or known broken, requests for other modules.

### Acceptance checks (Round 7)

| Check (doc: Acceptance) | Owner |
| --- | --- |
| 1 buttons → moves, tap/hold string, wrap and reset | B (real input with H) |
| 2 buffer, chain cut on hits only, mashing never faster | B |
| 3 each reaction's state, push ±20%, stun ±0.05 s; re-pop cap | H |
| 3 every payoff in the table produces its result | B |
| 4 uppercut → roundhouse launches a grunt at 15 ±1 m/s | B |
| 5 glide reaches a 4 m target and hits; auto-connect | B |
| 6 counter 100/100 vs orange tells, whiff lock, blue uncounterable, second attack misses during invulnerability | H (with B, C) |
| 6 every enemy strike's tell ≥ window + margin; blue for grab and charge | C |
| 7 dodge invulnerability, distance, hold into sprint | M |
| 8 drive speed ramp, break-through, slam, bowl | G (with M) |
| 9 throw speeds and aim assist | G |
| 10 no lock-on anywhere; player on screen through glides, drives, launches | E (H, J remove their parts) |
| poses exist for every Round 7 move, hold and reaction id | P |
| combo counter and counter prompts | J |
| effects on every Round 7 event, scaled by weight | F |
| 11 soaks with the new soak bot, 0 errors; run_all green | lead |

### Round 7 status

- **Built:** the doc's full kit plus the user's amendment (God path).
  - The player's kit: 12 moves, heavy versions on the punch string and the three kicks, the state payoffs, the chains and buffer, freeflow targeting with glides, auto-connect and follow steps, the counter on V / mouse thumb / Y, and the dodge.
  - Grabs, the drive through breakables, and the wound-up throw.
  - No lock-on, and the new camera framing.
  - The HUD: combo counter, counter, dodge and pursuit prompts, and the upgrade settings in pause > Debug.
  - Effects scaled by hit weight, and enemy tells of at least 0.5 s with varied wind-ups.
  - God path: jump, wall run and parkour, free teleport and pursuit (relaunch, or a spike into the floor with the stick pulled back), sprint-strike launches, ram level 3 launches, and floor cracks at 10 m/s and up.
- **Integration fixes:**
  - The input buffer now keeps a press from the first active frame on (it used to drop presses made on impact, which ate uppercut → roundhouse and every pursuit).
  - Grabs can be escaped by teleport again.
  - Enemy wind-ups vary above the 30-frame floor.
  - A token holder whose approach stalls next to its range swings anyway.
  - `world/test_real_kick` was rewritten for Round 7 launches; the carry body-slam case left `world/test_floor_damage`.
- **Soaks** (`FAST=1`): Duel 120 s and Waves 180 s, 0 errors. The Duel run had 4 pursuits, 2 spikes, 4 teleports and 2 rams; the Waves run had 52 launches, 27 wall breaks and a best chain of 21.
- **Module runs** by their owners on fresh copies: combat 17, input + defence 13, move 12, grab 12, game 19, fx 26, ai 24 (3 runs), anim 5, rig 18, world fixes by the lead. Performance checks were skipped this round (the user's call).
- **Still the user's:** the feel check in play. Animation is placeholder quality until the mocap round. Many feel numbers are local constants that agents listed as Tuning candidates; they are not moved yet.

## Round 8: Charge and pressure (docs/Round 8 — Charge and Pressure.md)

The user's grill session reworked the **strikes**: taps are light interrupts, holding charges continuously (with a meter), charged strikes do the stuns, sweeps, lifts and launches, an enemy pressure meter makes enemies passive and breaks them open, and a charged uppercut starts an air combo. The Duel is the player fully upgraded; Waves keeps the debug upgrades until the roguelike round. **Counter, dodge, grab, drive, throw, teleport and pursuit are untouched this round.** Round 8 wins over Round 7 for strikes. Animation quality and performance are out of scope.

### Ownership (Round 8)

Same rules as Round 7 (own files only, private copies under `<scratchpad>/agent_<id>/proj`, `--fixed-fps 120`, `SCRIPT ERROR` / `Parse Error` / `ERROR:` are failures, no git commits).

| Owner | Files |
| --- | --- |
| core (lead) | `scripts/core/*` except `time_director.gd`, `scripts/game/fighter_factory.gd`, `tests/core/*`, `tests/integration/*`, `tests/world/*`, `tests/rig/*`, docs |
| B — combat | `combat_controller.gd`, `move_data.gd`, `move_library.gd`, `combo_graph.gd`, `hurtbox.gd`, `combat_fx.gd`, `thrown_chunk.gd`, `projectile_probe.gd`, `tests/combat/*` |
| H — fighter & player | `fighter.gd`, `player_controller.gd`, `input_interpreter.gd`, `zone_aim.gd`, `defence.gd`, `tests/input/*`, `tests/defence/*` |
| M — movement | `traversal.gd`, `tests/move/*` |
| C — AI | `scripts/ai/*`, `tests/ai/*` |
| J — HUD, flow & menus | `hud.gd`, `game_menus.gd`, `game_mode.gd`, `ui_kit.gd`, `scenes/main.tscn`, `tests/game/*` except E's |
| P — poses | `pose_library.gd`, `pose_animator.gd`, `tests/anim/*` |
| F — FX & audio | `scripts/fx/*`, `shaders/*`, `tests/fx/*` |
| E — camera & time | `scripts/core/time_director.gd`, `scripts/game/camera_rig.gd`, `tests/game/test_camera_rig*`, `test_time_director*`, `test_cam_*`, `test_time_*` |
| G (grabs), A, D, K | not active |

### Contract already in the tree (lead)

- **`Tuning` Round 8 block** (end of the file): `R8_TAP_MAX`, charge numbers, `R8_MOVES` (tap and charged entries per move), pressure (`R8_PRESSURE_CAP`, decay, break, immunity, AI effects), levels (`R8_LEVEL_BY_WAVE`, `R8_LEVEL_BLOCK_MULT`, `r8_level_for_wave()`, `r8_pressure_cap()`), the air combo, `R8_UPGRADE_MAX`. New debug statics: `debug_charge_full`, `debug_pressure_mult`, `debug_launch_step`, `debug_air_hits`.
- **`HitInfo`**: `charged`, `charge`, `pressure`, `broken_bonus`, `air`.
- **`GameEvents` Round 8 block**: `charge_full`, `charge_cancelled`, `pressure_broken`, `pressure_recovered` (B); `air_follow_started` (M); `air_hit` (B). The Upgrade 2 `charge_started` / `charge_level_changed` / `charge_released` are reused (B; level = the move's steps passed).
- **`FighterFactory.spawn_enemy`** sets `Fighter.level` from `AttackDirector.wave_index` (Duelist 1).
- **Stubs with fixed signatures** (end of each file):

| API | Owner | Callers |
| --- | --- | --- |
| `CombatController.get_charge()`, `get_charge_move()`, `get_charge_steps()`, `is_charge_full()`, `get_pressure()`, `get_pressure_max()`, `get_pressure_fraction()`, `is_broken()`, `get_broken_time_left()`, `get_air_follow_target()`, `get_air_hits()` | B | J, C, F, E, H |
| `Fighter.level`, `Fighter.air_hang(seconds)` | H | B, C, J |
| `Traversal.start_air_follow(target) -> bool`, `is_air_following()` | M | H, E |
| `PoseAnimator.set_charge_amount(c)` | P | B |

### How the pieces meet (Round 8)

- **Charge (B).**
  - A strike press still held at `R8_TAP_MAX` charges. B emits `charge_started`, calls `animator.set_charge_amount(c)` every tick, emits `charge_level_changed` at each of the move's steps and `charge_full` at full, then fires the strike itself after `R8_CHARGE_HOLD_AT_FULL`.
  - `get_move_speed_mult()` is `R8_CHARGE_WALK_MULT` while charging (Fighter and Traversal already read it).
  - On release (or the auto-fire), the target is re-picked if the stick is pushed. The glide is limited to `R8_CHARGE_LUNGE` lerped by c, then come `R8_RELEASE_STARTUP`, the active frames and the recovery.
  - A hit on the charging player emits `charge_cancelled(..., &"hit")`.
- **Hits (B → H).**
  - B resolves a tap from `R8_MOVES[move].tap` and a charged strike from `.charged` lerped by c. A launch applies at c ≥ min(`launch_from`, `debug_launch_step`); `full_react` and `full_break` apply at c = 1. Payoffs come from `R7_PAYOFFS` (taps by their id, charged by `payoff_id`). The break bonus applies when the victim `is_broken()`.
  - B fills HitInfo (including the Round 8 fields) and calls `victim.react()`, `knockdown()` or `launch()`. A hook's charged knockdown and launch go sideways.
  - New react kinds: **`&"flinch"`** (a physical hit on the struck bone and a short stun; the enemy acts again right after) and **`&"sweep"`** (a knockdown with the legs taken out). Also **`&"broken"`** (dazed, can't act, `R8_BREAK_TIME`): B calls `victim.react(&"broken", ...)` when pressure breaks.
  - Any tap cancels a normal enemy's wind-up; armored wind-ups keep the Round 7 damage-and-snap path.
- **Pressure (B, victim side).** Kept on every fighter's CombatController.
  - It fills from player hits, including blocked ones (x `R8_BLOCKED_PRESSURE_MULT`), and the hit's pressure is x `debug_pressure_mult`.
  - It drains after the delay, breaks at capacity (`Tuning.r8_pressure_cap(archetype, fighter.level)`), and refills at half rate during the immunity.
  - Events: `pressure_broken` / `pressure_recovered`.
- **AI (C)** reads `get_pressure_fraction()` for block chance, attack rate, tell slow-down and backing off, plus `Fighter.level` for blocking. A broken enemy does nothing.
- **Air combo.**
  - H's PlayerController: on Jump, if `combat.get_air_follow_target()` is set, it calls `traversal.start_air_follow(target)` (M; emits `air_follow_started`), else jumps as before.
  - B: an attack press while airborne with a lifted body within `R8_AIR_STRIKE_RANGE` is an air strike (`R8_AIR_FRAMES`, never charged). Each landed one, up to `debug_air_hits`, calls `fighter.hang(R8_AIR_HANG)` (player) and `victim.air_hang(R8_AIR_HANG)` (H) and emits `air_hit`. A kick finishes with a launch at `R8_AIR_KICK_LAUNCH`; a punch with the stick pulled back is the Round 7 spike.
- **HUD (J).**
  - The charge meter at the bottom centre, from `get_charge()` / `get_charge_steps()` / `is_charge_full()`: white, then orange, then red at the steps, flashing at full.
  - The pressure bar under each enemy's health.
  - The pause-menu Debug settings for the four new upgrades.
  - GameMode: the Duel sets every upgrade to `R8_UPGRADE_MAX` and restores the player's settings after.
- **Effects (F)**: the charge glow and hum by c, a step tick, the full-charge ping, a release whoosh by c, pressure-hit ticks, a big break burst and sound on `pressure_broken`, a dazed loop while broken, air-hit accents.
- **Camera (E)**: a slight zoom while charging, a punch by the charged hit's weight (already by weight), and air combo framing (the player up to about 3 m high with the body).

### Decisions (Round 8)

1. The charge is continuous (user). The tap ends at 0.25 s, full charge takes 1.0 s at the start and 0.5 s at max, it holds 0.5 s at full, then fires itself.
2. Taps interrupt a normal wind-up and barely stun (user). Armored wind-ups ignore taps.
3. Pressure (user): fills from every hit (blocked ones too), makes enemies passive, breaks them open for 1.5 s with a 1.5x bonus, and drains when you stop. Level-1 grunts break in 2–3 taps.
4. A hit on the player cancels a charge. Charge armor is a later roguelike upgrade.
5. You walk at half speed while charging. The release glides farther with charge (3 m to 6 m).
6. Punch roles at full (user): the jab shoves, the cross launches straight back, the hook knocks down and launches sideways.
7. Air combo (user): a charged uppercut lifts 0.8 to 2.5 m; Jump follows; 4 hanging air hits; a kick sends them away, a back + punch spikes.
8. The gut punch is the pressure breaker (user). The leg kick at full sweeps (user). The front kick tap makes space and the charged one launches at full, earlier with the `debug_launch_step` upgrade (user).
9. The full payoff table stays (user). Payoff results don't scale with charge.
10. The meter shows colour steps with no labels (user).
11. The roundhouse charge only scales the launch. Enemy level follows the wave (1, 1, 2, 2, 3+). The Duel is at max upgrades and the Duelist's pressure capacity is 16 (lead's assumptions, stated to the user).

### Acceptance checks (Round 8)

| Check (doc: Acceptance) | Owner |
| --- | --- |
| 1 tap vs charge timing, auto-fire, `debug_charge_full` | B (real input with H) |
| 2 every move row tapped and charged at c = 0 and 1; `debug_launch_step` | B (reactions measured with H's react) |
| 3 taps interrupt and the grunt attacks again within 0.4 s; armor not interrupted | B (with C) |
| 4 walk at half speed, glide 3 m / 6 m, hit cancels charge | B |
| 5 pressure fill, blocked fill, break, bonus, drain, immunity, Duelist 16 | B |
| 6 AI under pressure: back off, block and attack rates | C |
| 7 air combo: lift heights, the follow jump, 4 hangs, kick launch, spike | B (with H, M) |
| reactions `flinch`, `sweep`, `broken`; `air_hang` | H |
| launcher jump reaches the body's height in about 0.25 s | M |
| 8 meter colours and flash, the pressure bar; Debug settings for the new upgrades | J |
| 9 Duel at max, settings restored | J |
| poses: charge loads deepen with c, flinch, sweep fall, broken daze, air strikes | P |
| effects on every Round 8 event | F |
| camera: charge zoom, air combo framing | E |
| 10 soaks and run_all | lead |

### Round 8 status

- **Built:**
  - Continuous charge on all eight strikes, with the bottom meter (white, orange, red; always two colour steps), walking while charging, a release lunge of 3–6 m, and charge cancel on hit.
  - Per-move tap and charged results from `R8_MOVES`, keeping the Round 7 payoff table.
  - Enemy pressure (blocked hits count): break, bonus, drain and immunity, with enemy levels by wave (1, 1, 2, 2, 3+) and bars over enemies.
  - The air combo: charged uppercut, buffered launcher jump, 4 hanging air hits, kick launch or spike.
  - The Duel at max upgrades, restoring the player's own afterwards; four new upgrade settings.
  - Flinch, sweep, broken and quick-keel reactions; charge-load poses that deepen with c; charge and break effects; charge zoom and air-combo camera.
  - The Duelist's armor narrowed to `e_heavy` (`"armor_moves"`); stick and heavy got a base `guard_chance`.
- **Owners' module runs** on fresh copies: combat 22, input + defence 17, move 13, ai 29, game 12 (J) + 11 (E), anim 6, fx 27.
- **Full suite** on the integrated tree: 201 of 202. The one failure, `ai/test_roster`, was a duplicate-variable error that C fixed after the copy was taken; C's later fresh-copy run is 29 of 29.
- **Soaks** were not rerun this round: the user stopped the run to playtest.
- **Open for the playtest:** the full-charge time, tap stun lengths, pressure caps (any charged hit breaks a level-1 grunt), the full gut punch's fold (1.8 s) outlasting the break (1.5 s), and the air-combo timing. Many agents' local constants are Tuning candidates and have not been moved yet.

## Round 9: Playtest fixes (docs/Round 9 — Playtest Fixes.md)

Five fixes from the Round 8 playtest; numbers in the `Tuning` Round 9 block (the hook's charged entry now has `"spin": true` instead of `"sideways"`). **Light testing**: each owner writes at most one focused test per change and runs its module once.

| Owner | Work |
| --- | --- |
| B — combat | hook forward + `victim.add_spin(rate)`; the string resets only on `R9_STRING_RESET` idle; the axe kick (leg kick on a lifted target, ground and air; spike react, shockwave; `R9_AXE`); break = guard broken (no `react(&"broken")` when `R9_BROKEN_STUN` is false; the victim can't block but acts); physical hits on downed bodies (`R9_GROUND_HIT`, never targeted or auto-connected) |
| H — fighter | `Fighter.add_spin(rate)` (stub in the tree): a yaw spin of the ragdoll around its centre of mass, on a launch or knockdown already started |
| C — AI | with `R9_PRESSURE_PASSIVE` false: pressure only scales block chance (no attack or tell slow-down, no back-off); a broken enemy keeps acting and only can't block |
| P — poses | `axe_kick` (ground: knee chamber, leg straight up above the head, heel chops down) and `air_axe` (air-combo version) |
| F — FX | the break looks like a cracked guard (forearm and guard sparks, a shatter at the guard) instead of a dazed head loop; the axe kick impact (the spike's floor boom, heavier for charged) |
| J — HUD | three string pips (J, C, H) by the charge meter, the next one lit; "GUARD BROKEN" instead of "BROKEN"; help text for the axe kick and downed-body hits |

### Round 9 status

- **Built**:
  - The hook goes forward and spins (`add_spin`, `R9_HOOK_SPIN` 12–20 rad/s, `R9_HOOK_HOP`).
  - The punch string resets only after `R9_STRING_RESET` idle (`get_string_idle_time()`), with J / C / H pips by the meter.
  - The axe kick (`axe_kick` / `air_axe`, spike with an `R9_AXE` blast).
  - Pressure only weakens the guard, and a break is GUARD BROKEN with no daze. Both behaviours sit behind `R9_PRESSURE_PASSIVE` / `R9_BROKEN_STUN`.
  - Physical strikes hit downed bodies (`R9_GROUND_HIT`, once-per-knockdown get-up delay).
- **Light testing** by request:
  - Module runs: combat 23/23, input + defence 18/18, ai 28/29 (`test_flinch` fixed, rerun passes), anim 7/7, fx 27/28 (`test_real_destruction` flaky, fails without these changes too), game 23/23.
  - The combined build imports and boots with 0 errors.
  - No full suite or soaks.
- **Known**: the axe kick's heel apex is about head height (the hip joint limits); it still connects up to `reach_up` 2.6 m.
