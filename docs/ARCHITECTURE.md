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
