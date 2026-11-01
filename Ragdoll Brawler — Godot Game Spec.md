# Ragdoll Brawler — Godot Game Spec

Nov 1, 2026 · @Pahul

## Summary

Build a bloody, melee-only, one-against-many brawler versus AI in Godot 4.7 on Jolt physics, where every big hit turns the victim into a ragdoll and the victim's impact energy decides whether they bounce off a wall, go through it, or bowl over the enemy behind them. Build the ragdoll lab first, then a 1v1 slice against one AI opponent, then the crowd: the ragdoll is the product, and combat is tuned around it.

### Revision 2: what the adversarial review changed

An independent reviewer, given only the spec, found that it was built for 1v1 and broke in a crowd. Its time model, defence model and milestone order needed changing, and two physics assumptions were wrong. I checked its key Godot claims against the docs before acting on them.

| Finding | Severity | Change made |
| --- | --- | --- |
| Nothing limits how many enemies attack at once; an 8-frame dodge against free-for-all attacks is a coin flip | Critical | Attack tokens, near and far rings, mandatory tells (Enemies and AI) |
| Enemies using the player's 5-frame jab cannot be reacted to | Critical | Enemies get their own moves with 21–36 frames of tell and startup |
| Global hitstop freezes the whole crowd on every hit; windows counted in scaled time stretch 3.3× in slow motion | Critical | Hitstop is local to attacker and victim; all input windows are in real time; slow motion has a budget |
| No health, death or anti-juggle model, though rounds now end at death | Critical | Mode and rules; air recovery; no attack tokens while the player is down |
| Dodge and teleport undefined with two attackers; teleport can land inside an enemy | Critical | 0.25 s invulnerability on vanish; shape-cast the destination; pick the target with the stick |
| AI was milestone 7, but the game is AI-only | Critical | Milestones re-ordered: 1v1 AI moves to M3 |
| `PhysicalBone3D` mass defaults to 1 kg, so a 15-bone ragdoll weighs 15 kg, not 70 | Major, verified | Set per-bone masses explicitly (Ragdoll system) |
| `PhysicalBone3D` has no contact monitor or continuous-collision property | Major, verified | Test the `PhysicsServer3D` calls on the bone's RID in M1 |
| Enemies are `CharacterBody3D`, which physics does not move, so thrown bodies bounce off them | Major | Body-on-body resolver (Impact resolution) |
| Pelvis velocity is not the body's velocity; a 2-tick sweep is shorter than an arm | Major | Centre-of-mass velocity; sweep covers the body's extent |
| Focus refills from counters, so counter loops never end | Major | Fixed Focus numbers; counters refund nothing |
| Camera assumes one opponent | Major | Group framing, stick-chosen soft target, off-screen markers |
| Dash kick sat 1.4% below brick's break energy; one slow-motion trigger could never fire | Minor | Thresholds moved to give 12–21% margins |
| Active ragdolls under Jolt are reported as fragile | Minor, verified | Muscles drive hit reactions only, never locomotion |

The reviewer could not find two tools the spec relies on. Both exist: the [active-ragdoll addon](https://github.com/DanilKhmyrov/godot-active-ragdoll) (MIT, 3 commits, 2 stars, so young) and [MixaBridge](https://www.godotengine.org/asset-library/asset/5096).

**Revision 3, your decisions:** no edge to fall off (the yard is walled on every side), melee only, a bloody presentation with dismemberment on killing blows (Blood), grab, throw and grab break (Combat), and no last stand.

**Did I watch the videos?** Yes, by their narration. YouTube blocked direct fetching, so I played both videos in the built-in browser at 3x speed and captured the auto-generated English captions with timestamps. I have the full spoken content of both. I did not analyse the footage frame by frame, so anything shown but not said is not in this spec. Timestamps below (V1 m:ss, V2 m:ss) come from those captions and may be off by a second or two.

- **V1** — [Improving ragdolls forever](https://www.youtube.com/watch?v=yY6vck8SuCY), Lincoln Margison, 8:31
- **V2** — [Ragdolls improved by YOUR suggestions.. you weirdos](https://www.youtube.com/watch?v=X1V_VeR0h4E), Lincoln Margison, 6:51

Both videos explain techniques and show results; neither shows code. The courses linked in their descriptions are Unreal Engine courses (Control Rig, Animating in Unreal Engine). So the techniques below are from the videos, and every Godot implementation detail is my design, marked as such.

**Findings that change the plan**

1. **V1's core technique cannot be configured on Godot's joints under Jolt.** Godot's Jolt docs say joint soft-limit properties are not supported, and Jolt's author said they will probably never be mapped. Soft limits and neutral-pose tension must be scripted torques per bone (Section: Ragdoll system).
2. **Jolt is already the default.** Godot 4.6 made Jolt the default 3D engine for new projects; 4.7.2 is the current stable line (August 2026).
3. **Slow motion is cheap and physics-friendly.** With `Engine.time_scale` lowered, each physics tick's delta shrinks, so the simulation takes smaller steps instead of skipping. Hitstop and slow motion can share one mechanism.
4. **Wall break-through must be decided before contact.** If the wall breaks after the solver resolves the collision, the body has already lost its speed and drops in front of the hole. This is my design reasoning, to be verified in M5.

## Pillars and references

Four pillars decide every scope call: if a feature does not serve one, it waits. In a crowd, pillar 1 extends to bodies hitting bodies.

1. **Every big hit ends with a body in flight.** Launches are full ragdolls, never canned knockdown animations.
2. **Timing beats mashing.** A precisely timed block turns into a dodge and a teleport counter; an early or late one is just a block.
3. **Speed is power.** The attacker's speed into the hit adds to the launch, so dashing in and chasing a flying body pays off.
4. **The arena remembers.** Walls crack, then break; a few big chunks, not hundreds of fragments. Blood stays where it lands.

| Reference | What we take | Evidence |
| --- | --- | --- |
| Budokai Tenkaichi 3 | Teleport counter: dodge to behind the attacker and send them flying; costs a resource; strict timing, before the hit lands | [Kanzenshuu forum](https://www.kanzenshuu.com/forum/viewtopic.php?p=1528004) |
| Budokai Tenkaichi 3 | Running out of the resource loses a vanish exchange, which stops infinite counter loops | [SuperCombo wiki, BT3 Defense](https://srk.shib.live/w/Dragon_Ball_Z:_Budokai_Tenkaichi_3/Defense) |
| Budokai 3 / Sparking Zero | Chasing a knocked-back opponent with repeated teleport-and-smash; Z-counter by pressing block just before the hit | [Giant Bomb, Budokai 3](https://wiki-origin.giantbomb.com/wiki/Games/Dragon_Ball_Z_Budokai_3) |
| Overgrowth | Physics-driven animation; a sweep visibly pushes the legs out from under the target | [PC Gamer](https://www.pcgamer.com/au/physics-based-brawler-overgrowth-released-on-steam-early-access) |
| Overgrowth | Few keyframes plus procedural layers instead of large animation sets (GDC 2014, David Rosen) | [Game Developer](https://gamedeveloper.com/design/video-an-indie-approach-to-procedural-animation) |
| V1, V2 (Lincoln Margison) | Soft joint limits, neutral-posture tension, limb spin on impact, layered falling animation, protective pose, dislocation | Timestamped in Ragdoll system |

The BT3 rules come from community wikis and forums, not official docs; the exact frame windows below are my tuning starts, not BT3's values.

## Mode and rules

The game is the player against waves of AI enemies, and a round ends when the player dies or the last enemy of the last wave dies. Build it 1v1 first: one AI opponent is the vertical slice (M3–M6), and the crowd comes after (M7).

**Why 1v1 first.** Every combat number in this spec — launch impulse, wall energies, the dodge window — has to be tuned against one opponent before it can be tuned against five. A crowd adds attack tokens, more ragdolls at once and a multi-target camera, each of which hides whether the core feels good. The 1v1 opponent is the Duelist archetype, which stays in the final game, so none of the slice is thrown away.

**Round structure:** 4 waves in The Yard, at most 5 enemies on the field at once. Broken walls stay broken between waves. The player heals 20% between waves; Focus carries over.

**Health and damage (tuning starts)**

| Fighter | HP |
| --- | --- |
| Player | 1,000 |
| Grunt, Thrower | 150 |
| Brawler | 250 |
| Shield | 300 |
| Duelist | 350 |
| Brute | 600 |

- Hit damage comes from the move: jab 15, sweep 30, kick 60, power punch 50–120 by charge, teleport counter 90, throw 40.
- Impact damage comes from the environment: every wall, pillar, floor or body impact above 500 J deals (E − 500) ÷ 20 HP, at most 300 per impact. A drywall break at 2,240 J deals 87; a body bounced through two rooms takes several hits.
- There is no edge to fall off: the yard is walled on every side, so every KO comes from damage.
- An enemy that reaches 0 HP while flying finishes its flight as a ragdoll. Once it settles, it freezes into a static body and fades after 20 s, or sooner when more than 6 bodies are down.

**Player protection:** no enemy gets an attack token while the player is launched, grounded or getting up (AI rule 3), and the get-up has 0.5 s of invulnerability. A crowd can punish a mistake once, never juggle it.

## Enemies and AI

A crowd only feels fair if it takes turns: at most 2 enemies hold attack tokens at once, the rest circle at a distance, and every attack is telegraphed on screen before it can land. These are established patterns from shipped melee games, not inventions.

**Evidence**

- A study of melee games found enemies attack about every 2–3 seconds on average, hold off while the player is still staggered, and pick the next attacker through a slot system; God of War's Alex Sulman wanted to avoid "the chaos of just everyone attacking you at once" ([Game Developer, Vossen](https://gamedeveloper.com/design/enemy-design-and-enemy-ai-for-melee-combat-systems)).
- Same source: only a near group attacks; a far group waits; DmC keeps an exclusion zone around the player; Sulman's team had enemies "almost never" attack from off screen; Arkham City flashes an icon over an enemy about to attack.
- The battle-circle pattern caps simultaneous attackers; cinematic games such as Arkham Asylum use 1, the reference demo uses 2, and a high cap makes big groups unbeatable ([Envato Tuts+](https://code.tutsplus.com/battle-circle-ai-let-your-player-feel-like-theyre-fighting-lots-of-enemies--gamedev-13535t)).
- Most melee games use at most three enemy types in one fight ([Game Developer, Vossen](https://www.gamedeveloper.com/design/level-design-for-melee-combat-systems), quoting Aztez's Ben Ruiz).

**Our rules (tuning starts)**

1. `AttackDirector` owns 2 tokens on Normal and 1 on Easy. An enemy needs one to start an attack; it returns the token when its attack ends or it is hit.
2. Near ring 2.5–4 m: token holders and the next one in line. Far ring 6–9 m: everyone else strafes, taunts, or throws debris (Thrower only).
3. No token is granted while the player is in hitstun, airborne after a launch, or getting up. This removes crowd juggles.
4. An enemy must be inside the camera view for 0.4 s before its token is granted. No off-screen hits.
5. Every attack starts with a 0.35–0.6 s tell: a pose, a glint above the head and a sound. A white glint is a strike (answer with Block); a red glint is a grab (answer with Grab). Heavier attacks get longer, louder tells.
6. Two token holders may not swing within 0.25 s of each other, so the player can perfect-dodge one at a time.

**Archetypes (max three per wave)**

| Archetype | Mass | What it demands | Role |
| --- | --- | --- | --- |
| Grunt | 70 kg | Nothing special; launches from any kick or charged punch | Smasher: fun to send through walls |
| Brawler | 80 kg | Blocks jabs; must be swept, charged, grabbed or countered; grabs you if you block for more than 1 s | Basic test of the move set |
| Shield | 85 kg | Blocks every strike from the front; a grab or a teleport counter opens him | Enforcer: only the teleport counter or a back hit opens him |
| Brute | 140 kg | Barely moves from standard kicks; his charge breaks drywall; his grab throws you at 14 m/s, so break it | Wall breaker; needs a dash kick or pursuit chain to launch |
| Duelist | 65 kg | Perfect-dodges you on some difficulty-scaled chance | Mirror of the player; teaches timing |
| Thrower | 70 kg | Stays in the far ring; throws debris chunks from broken walls | Punishes standing still; uses the destruction |

**Waves:** wave 1 = 4 Grunts; wave 2 = 3 Grunts + 2 Brawlers; wave 3 = 2 Brawlers + 1 Shield + 1 Thrower; wave 4 = 1 Brute + 3 Grunts. At most 5 enemies on the field; the rest wait at spawn points. Ratios and counts are tuning starts. All archetypes share one Mixamo rig, so each needs its own silhouette and colour (scale, armour, a shield, a bandana) to be read at a glance in a crowd.

## Tech stack

Godot 4.7.2 with Jolt, one Mixamo character, Blender (via your MCP) for poses and pre-fractured meshes; no runtime fracture and no engine plugins required to start.

| Area | Choice | Why / evidence |
| --- | --- | --- |
| Engine | Godot 4.7.2 stable, GDScript | Current stable line, released August 2026 ([gamedev.net](https://gamedev.net/news/5172-godot-engine-472-stable-released/)) |
| Physics | Jolt, physics ticks 120 Hz | Default for new 3D projects since 4.6 ([Godot 4.6 release](https://godotengine.org/releases/4.6/)); 120 Hz is my call to reduce tunnelling at 15–20 m/s; turn on physics interpolation so 120 Hz ticks look smooth on 144 Hz screens |
| Ragdoll | `PhysicalBoneSimulator3D` + `PhysicalBone3D` from Create Physical Skeleton; prune fingers and utility bones | Godot [ragdoll docs](https://docs.godotengine.org/en/stable/tutorials/physics/ragdoll_system.html): fewer bones is cheaper; partial simulation by bone list; Influence blends ragdoll over animation |
| Joint behaviour | Jolt hard limits as a safety net; soft limits and tension as scripted torques | Jolt module does not support joint soft-limit properties ([Godot Jolt docs](https://docs.godotengine.org/it/4.4/tutorials/physics/using_jolt_physics.html), [Jolt author](https://github.com/godot-jolt/godot-jolt/discussions/826)) |
| Active ragdoll (muscles) | Spike [godot-active-ragdoll](https://github.com/DanilKhmyrov/godot-active-ragdoll) first; fall back to our own velocity motor | Addon: Godot 4.4+, Jolt, PD muscles pulling bones to the animated pose, per-bone tone 0–1. Fallback formula from Jolt's author: set body velocity = (target − current) / step ([discussion](https://github.com/jrouwe/JoltPhysics/discussions/1764)) |
| Character and animation | One Mixamo humanoid; clips retargeted to `SkeletonProfileHumanoid` | [MixaBridge](https://www.godotengine.org/asset-library/asset/5096) automates the bone map for Godot 4.4+; the [Godot forum](https://forum.godotengine.org/t/retargeted-animations-look-weird/108751) warns against saving clips out of AnimationPlayer |
| Blender MCP | Author the neutral body pose and protect-head pose; pre-fracture wall panels; export .glb | Keeps every asset in one pipeline |
| Destruction | Own GDScript `Destructible` node | Reference: [Destructibles-CSharp](https://www.godotengine.org/asset-library/asset/edit/9886), CC0, Godot 4.6, built for Blender cell-fracture shards |
| Renderer | Forward+ | Blood decals: Mobile and Compatibility allow only 8 decals per mesh (Godot decal docs) |

**Animation list (Mixamo, names vary — check availability):** fighting idle, jab, cross for power punch (hold pose for charge), front push kick, leg sweep, block idle, block hit, side dodge, forward dash, stagger, falling loop, get-up face-up, get-up face-down. Author two in Blender: neutral body posture (one frame) and protect-head (short loop).

## Ragdoll system

A fighter is an animated capsule until a hit crosses a threshold; then the body becomes a ragdoll whose bones carry muscle tone, soft joint limits and a pull toward a relaxed pose, and it blends back into a get-up animation.

### States

&#91;embedded content: ragdoll states · 6 states\]

Flinch and Stagger usually return straight to Animated; only a launch, or a stagger that tips over, goes through the full ragdoll loop.

1. **Animated** — `CharacterBody3D` capsule plus `AnimationTree`. Physical bones exist but do not simulate. Hurtboxes ride bone attachments.
2. **Flinch** (light hits) — partial ragdoll on spine, arms and head via `physical_bones_start_simulation([...])`, Influence tweened from 0.3 to 0 over about 0.3 s. A [Godot forum thread](https://forum.godotengine.org/t/active-ragdoll-in-godot-4-5-how-to-achieve-good-results/128728) reports it looks better with the AnimationTree left running.
3. **Stagger** (medium hits) — V1 7:46–8:07 shows the body going limp in phases: upper body first while the legs keep stepping, then the legs, then a fall if the feet cannot keep up. We do this as a tone ramp: arm and spine tone drop at once, leg tone over 0.5–1 s; if the pelvis tilts past about 35°, go to Launched.
4. **Launched** — full ragdoll. Capsule collision off; capsule follows the pelvis. Launch impulses applied (see Impact resolution). Muscles at low tone, targeting a falling loop.
5. **Grounded** — pelvis speed under about 0.5 m/s for 0.4 s, or 3 s after landing whatever the speed, so a jittering body cannot stay down forever. Only soft limits and neutral tension act.
6. **Get-up** — face-up or face-down chosen from the pelvis orientation; capsule snaps to the pelvis position; Influence blends 1 → 0 over 0.3–0.5 s into the get-up clip.

### Techniques, evidence and Godot build

| Technique | What the video shows or says | Godot build (my design) | Priority |
| --- | --- | --- | --- |
| Soft limits | V1 0:19–1:05: hard limits let a joint swing at full speed, then stop dead or bounce; soft limits slow it as it nears min/max, like muscles and ligaments reaching full stretch | Keep Jolt's hard limit about 10–15° wider than the target range. A script adds a damping torque that grows through the last \~20% of the range, plus a spring back inside it | P0 |
| Neutral tension | V1 1:08–1:35: a slight, constant pull toward a neutral angle even when fully simulated; with hard limits a moved limb stays where it was put | Low-gain spring torque per bone toward the neutral pose. V1 3:37 notes gravity overrides most of it, so it shows in the details, not the big motion | P0 |
| Neutral body posture | V1 1:50–2:45: neutral angles based on NASA's microgravity posture — knees bent, feet relaxed, shoulders rolled forward, elbows bent | Author the pose once in Blender (via MCP) as a one-frame clip; read per-bone neutral rotations from it | P0 |
| Settling | V1 5:06–5:42: with hard limits the fall stops instantly at the knee limit and can settle with arms raised overhead; with soft limits it stops gradually and the final pose looks like an unconscious person | Acceptance test for M1 (side-by-side scene) | P0 |
| Limb spin on impact | V1 6:27–7:11: on any impact, also give the shoulders and legs a rotational impulse. In an explosion the arms fly back and the legs go forward because the feet resist. Add randomness so limbs differ | On launch: angular impulse on upper arms against the hit direction, on thighs along it, each scaled ±25% at random | P0 — cheapest big win |
| Phased limpness | V1 7:16–8:07: active ragdoll moving toward an underlying animation; upper body goes simulated first, legs later | Stagger state above | P1 |
| Falling-animation layer | V2 1:46–2:03: the creator's preferred version (#4) keeps the ragdoll pulling gently toward a falling animation; that animation plays faster while rising and slower while falling | Active-ragdoll target = falling loop; AnimationTree time scale driven by pelvis vertical velocity | P1 |
| Over-wobble | V2 2:03–2:16: version #5, a sped-up animation with wobblier physics, is the one he rejects | Cap muscle gains; expose them in a `RagdollProfile` resource | Guardrail |
| Protective pose | V2 3:29–3:49: a short loop covering the head with knees up; blend toward it from fall speed and closeness to the floor; still physics, so collisions can stop it | Blend weight = downward speed factor × (1 − floor distance / 2 m) | P1 |
| Hand bracing | V2 3:54–4:36: hands reaching to break a fall mostly failed and looked like climbing down stairs; he says it needs a procedural stepping system for hands | Skip | Cut |
| Dislocation | V2 2:21–3:23: when a joint hits its limit fast enough, the range shifts permanently into hyperextension, with a jolt to the arm to sell it. V2 4:56–5:15: that jolt made the body launch itself off surfaces | Optional; cap the jolt impulse and apply it only to the two bones of the joint | P2 |
| Tuning philosophy | V2 5:15–5:32: build it realistic; wacky is then just different numbers | All gains in one resource with presets | P0 |
| Self-balancing | V2 5:40–5:59: his balancing legs reacted too fast because they were capsule-driven, not truly self-balancing | No self-balancing in v1 | Cut |
| Impact sounds | V2 6:04–6:29: planned, not shown — sounds generated from body impacts and sliding | Volume and pitch from contact impulse | P2 |

### Per-bone torque (my design)

Each physics tick, per simulated bone, with θ the joint angle relative to its parent and ω the relative angular velocity:

```latex
\tau = s\,(k_p\,(\theta_{anim} - \theta) - k_d\,\omega) + k_n\,(\theta_{neutral} - \theta) - c(\theta)\,\omega
```

s is muscle tone (0–1, per bone, animated by state). The first term follows the animation; the second is neutral tension; c(θ) is 0 inside the comfortable range and ramps up near the limits, which is the soft limit. Apply as `apply_torque` in `_integrate_forces`, using the scaled physics delta so slow motion stays consistent.

**Setup rules (from the docs and the review)**

- **Set every bone's mass.** `PhysicalBone3D` mass defaults to 1.0 kg ([Godot API](https://docs.godotengine.org/en/latest/_sources/classes/class_physicalbone3d.rst.txt)), so a generated 15-bone ragdoll weighs 15 kg and every energy number here would be wrong. For a 70 kg fighter, using Dempster's fractions ([Visual3D wiki](https://wiki.has-motion.com/Segment_Mass)): head 5.7, chest and spine 24.9 split across their bones, pelvis 9.9, upper arm 2.0, forearm 1.1, hand 0.4, thigh 7.0, shin 3.3, foot 1.0 kg.
- **Specify launches as speed, not impulse.** Each bone gets impulse = its mass × the launch velocity change, so a Brute and a Grunt fly correctly from the same move data. A 13 m/s launch of 70 kg is about 910 N·s in total.
- **Joints:** use cone joints for shoulders, hips and neck and hinge joints for elbows and knees, as the [ragdoll docs](https://docs.godotengine.org/en/stable/tutorials/physics/ragdoll_system.html) advise when in doubt. Remove fingers and utility bones.
- **Collision layers:** the capsule never touches its own physical bones.
- **No contact signals or continuous collision on bones.** `PhysicalBone3D` exposes neither. In M1, test `PhysicsServer3D.body_set_max_contacts_reported` and `body_set_enable_continuous_collision_detection` on the bone's RID; whether Jolt honours them for bones is unverified.
- **Muscles for hit reactions only.** Forum reports describe Jolt active ragdolls exploding or behaving strangely when they drive locomotion ([Godot forum](https://forum.godotengine.org/t/active-ragdolls-in-godot-jolt-is-it-even-possible/117047)). Locomotion stays on the capsule and animation.
- **Ragdoll LOD.** The player and elites get muscles; minions get a passive ragdoll of about 10 bones with soft limits only. At most 4 bodies simulate actively at once; dead bodies freeze when they settle. The addon's author measured about 0.13 ms per character per physics frame on an Apple M4 ([repo](https://github.com/DanilKhmyrov/godot-active-ragdoll)); profile your own number in M1.
- **One loop per character.** Run the per-bone torques from one `_physics_process` per character through `PhysicsServer3D` RIDs, not 15 GDScript `_integrate_forces` callbacks per body.

## Combat system

Seven buttons — light, heavy (hold to charge), kick, sweep, grab, block, dash — plus one resource, Focus (3 bars), that pays for teleports. All frame numbers are tuning starts at 60 fps, not values from BT3.

### Moves

| Move | Input | Startup / active / recovery (frames) | On hit | Wall-capable |
| --- | --- | --- | --- | --- |
| Jab | Light (chains up to 3) | 5 / 3 / 10 | Flinch; no launch | No |
| Power punch | Heavy, hold 0.2–1.0 s | 14–30 / 4 / 22 | Stagger at low charge; launch at mid and full | Yes at full charge |
| Sparta kick | Kick | 12 / 4 / 24 | Launch: big horizontal impulse to chest and pelvis | Yes — main wall breaker |
| Leg sweep | Sweep | 10 / 5 / 20 | Impulse to shins plus spin; victim falls in place (the Overgrowth sweep) | No |
| Block | Hold block | — | Damage cut 80%; heavy and kick push the blocker back | — |
| Dash | Dash | — | Builds speed that feeds the next hit | — |
| Grab and throw | Grab; release or wait 1 s to throw | 8 / 3 / 30 on a miss | Beats block; hold, then throw at 12 m/s in the stick's direction | Yes — breaks drywall, cracks brick, bowls enemies |

### Perfect dodge and teleport counter

BT3's teleport counter sends you behind the opponent, costs ki, and must be pressed before the attack lands ([Kanzenshuu](https://www.kanzenshuu.com/forum/viewtopic.php?p=1528004)). Our version:

1. **Perfect dodge:** block pressed within the 8 frames (\~133 ms, real time) before an attack's first active frame. The defender vanishes with an afterimage and is invulnerable to every hit for 0.25 s, so a second attacker cannot catch the vanish. Time drops to 0.3× for 0.25 s real time. Free.
2. **Teleport counter:** during that slow motion, press Light or Kick. The defender reappears behind the attacker, or behind whichever enemy the stick points at. Before moving, shape-cast the spot 1.2 m behind the target; if it is blocked, try the target's left and right sides, else cancel to a plain dodge. The counter is a back kick with a fixed launch of 16 m/s. Costs 1 Focus; 1.5 s cooldown.
3. **Anti-mash:** a block press counts as a dodge attempt only if an enemy attack becomes active within the next 20 frames. An attempt outside the 8-frame window locks out perfect dodge for 20 frames. A block press with no attack coming never locks anything, so ordinary blocking is not punished.
4. **Air recovery:** while launched, after 0.4 s, press Dash to flip upright and land on your feet. Costs 1 Focus. This is the player's escape from a bad launch.
5. **Focus:** start each round with 1, cap 3. Perfect dodge +0.5. A launch that lands +0.25. Teleport counter, pursuit and air recovery cost 1 each. Counter hits refund nothing, so dodge-counter loops always drain Focus.
6. **Enemy timing:** enemies do not use the player's frame data. Every enemy attack has 21–36 frames of tell and startup (Enemies and AI, rule 5), so the dodge is a reaction, not a guess.
7. **Window clock:** every input window and cooldown counts real time, never scaled game time, so slow motion does not widen the windows.

### Grab, throw and grab break

Grab beats block, strikes beat a slow grab, and a grab is broken by pressing Grab at the right moment: the strike-throw-block triangle every fighting game uses, with BT3-style timing on the break. Grabs are the answer to blockers and the Shield, and a throw is the most precise way to aim a body at a wall or a crowd.

**Evidence:** throws are "unblockable but short-range" attacks meant to "force defenders to take action other than blocking"; Killer Instinct gives 7 frames after a throw connects to break it, throws start in 5 frames, and a missed throw has "very long whiff recovery" ([Infil's KI guide](https://ki.infil.net/basics3.html)). Tekken signals which button breaks a throw through the grabber's hand position, so the break is read, not guessed ([Prima Games](https://primagames.com/gaming/how-to-break-throws-in-tekken-8)).

**Rules (tuning starts)**

1. **Grab:** 1.3 m in front, 8 frames startup, 3 active, 30 frames of recovery on a miss so a missed grab is punishable. It ignores block. It cannot catch a fighter who is in hitstun, launched, grounded or invulnerable.
2. **Hold:** on connect, the victim's capsule snaps to a socket in front of the grabber and its upper body goes into partial ragdoll so the arms flail. The grabber can turn and walk at half speed for up to 1 s. Other enemies may still attack a player who is holding someone, so a long hold is a risk.
3. **Throw:** release Grab, or wait out the 1 s, and the victim launches at a fixed 12 m/s in the stick's direction, 15° upward. That is 5,040 J for 70 kg: it breaks drywall, cracks brick, and launches any enemy it hits. Throw damage is 40 plus impact damage.
4. **Grab break:** when an enemy grabs you, press Grab from 6 frames before their grab becomes active until 10 frames after it connects, about 267 ms in real time. Both fighters are pushed 1.5 m apart and the grabber staggers for 20 frames. +0.5 Focus. The window is wider than KI's 7 frames because this is a 3D camera with a crowd; tune it down if breaks feel free.
5. **Reversal:** a break in the first 4 frames after connect, with 1 Focus available, turns it around: you are now holding them. This is the grab's version of the teleport counter.
6. **Anti-mash comes free:** pressing Grab early just throws out your own grab, which misses and leaves you in 30 frames of recovery.
7. **Reading it in a crowd:** enemy strike tells glint white (answer: Block), grab tells glint red (answer: Grab). Block does nothing against a grab, so the two defences never share an input.
8. **No free hits on a held player:** while an enemy holds the player, no other enemy gets an attack token.
9. **Feel:** 80 ms local hitstop on the throw release; 100 ms on a break with a clash spark between the two hands.

**Animation:** the grabber needs grab, hold, throw and pushed-back clips; the victim is mostly ragdoll, so it needs only a short struggle loop. Check Mixamo for these; author what is missing in Blender via MCP.

### Speed is power

Launch impulse grows with the attacker's speed along the hit direction:

```latex
J = J_{move}\,m_{charge} + k\,M_{attacker}\,\max(0,\ \vec v_{attacker}\cdot\hat d)
```

With k around 0.6, a dash-in kick launches noticeably further than a standing one. Moves that start from a standstill after a teleport (teleport counter, pursuit) use a fixed launch speed instead, because the attacker-speed term would be zero. **Pursuit:** within 0.5 s of a launch, Dash teleports you beside the flying body for one follow-up hit, which adds the victim's current speed to the new launch. Each pursuit costs 1 Focus. The third relaunch of the same body within one flight gets half the impulse, so chains end. This is the BT3 chase loop and the source of the flying-bodies fights.

### Hit pipeline

1. A hitbox (`Area3D`) on the attacking limb is live on active frames and overlaps a hurtbox. The player and elites have about 10 hurtboxes; minions have 6. A hit registry lets each attack hit each target once.
2. Check the defender: invulnerable → ignore; perfect-dodge window → dodge; blocking → block; else hit.
3. Compute power from move, charge and attacker speed (or the move's fixed launch speed).
4. Local hitstop for attacker and victim only, length by power (see Game feel).
5. Apply hit damage; reaction by power: flinch, stagger or launch.
6. On launch: start the ragdoll and give each bone the velocity of its animated pose, found by differencing the last two animated poses (animated bones have no velocity of their own). Then apply the impulse at the hit bone and the pelvis, then the limb-spin impulses from V1.
7. Hand the victim to the impact resolver until they land.

## Impact resolution: through the wall or off it

The victim's kinetic energy into the wall decides the outcome: at or above the wall's break energy they go through; between 35% and 100% the wall cracks and they bounce; below 35% they simply ragdoll off it. The same check against a standing enemy knocks that enemy down. This whole section is my design; V1 and V2 supply the bounce behaviour.

&#91;embedded content: wall impact decision · 3 outcomes\]

One energy number, compared against one wall property, picks one of three outcomes; all three keep the victim fully physical.

### Rules

- Each `Destructible` has `break_energy` (J), `absorption` (0–1, speed lost when broken through) and a cracked state.
- While a victim is Launched, each physics tick the resolver sweeps the body's bounding box along its centre-of-mass velocity, as far as the body's own extent plus two ticks of travel. A 2-tick torso sweep (0.3 m at 18 m/s) is shorter than an arm, so a hand would touch the wall and bounce before the check fired. While E is above the crack threshold, launched bones ignore intact breakables so only the resolver decides.
- On a hit, with M the summed bone mass, v the centre-of-mass velocity (Σ mᵢvᵢ ÷ Σ mᵢ, not the pelvis, which spins) and n the wall normal:

```latex
E = \tfrac{1}{2}\,M\,(\vec v\cdot -\hat n)^2
```

- **Break** (E ≥ break\_energy): fracture the panel this tick, before contact. Every bone's velocity is scaled by √(1 − absorption), so the body slows as one piece instead of twisting apart. Shards get the impact impulse. 0.25× slow motion for 0.35 s.
- **Crack** (0.35 × break\_energy ≤ E < break\_energy): swap to the cracked mesh and subtract 0.5 × E from break\_energy. The victim bounces with normal contact physics plus an extra limb-spin impulse (V1 6:27). Dislocation check here if enabled (V2 2:21).
- **Bounce** (E below that): plain contact. Soft limits and neutral tension make it read as a body hitting a wall, not a doll (V1 4:25–4:55).
- Arena boundaries are never destructible: always bounce.
- **Body hits body.** Standing enemies are `CharacterBody3D`, which physics does not move ([Godot API](https://docs.godotengine.org/en/latest/_sources/classes/class_characterbody3d.rst.txt)), so a flying body would bounce off them like a pillar. The resolver therefore also sweeps against enemy capsules, using energy from the relative velocity: below 600 J the enemy flinches, 600–1,500 J staggers, above 1,500 J launches with half the flyer's speed. A chain stops after 4 bodies. This is the human-bowling idea in Creative angles.

**Why decide before contact:** if the panel breaks after Jolt has resolved the collision, the victim's speed into the wall is already gone and they drop in front of the hole. Verify in M5; if it proves unnecessary, a contact-based check is simpler.

### Worked example

Victim mass 70 kg. Thresholds and speeds are tuning starts, not measurements.

| Surface | Break energy | Crack from (35%) |
| --- | --- | --- |
| Drywall | 2,000 J | 700 J |
| Brick | 7,500 J | 2,625 J |
| Concrete (outer walls, pillars) | Never | Crack decal only, from 5,000 J |

| Hit (speed into wall) | Energy | Drywall | Brick | Concrete |
| --- | --- | --- | --- | --- |
| Standing sparta kick (8 m/s) | 2,240 J | Breaks (12% over) | Bounces (15% under crack) | Bounces |
| Same kick at 45° (13 m/s total, 9.19 m/s into wall) | 2,957 J | Breaks | Cracks (13% over crack) | Bounces |
| Dash-in sparta kick (13 m/s) | 5,915 J | Breaks | Cracks (21% under break) | Bounces, decal |
| Teleport counter (fixed 16 m/s) | 8,960 J | Breaks | Breaks (19% over) | Bounces, decal |
| Full-charge dash power punch (18 m/s) | 11,340 J | Breaks | Breaks | Bounces, decal |

Every outcome now clears its threshold by at least 12%, so results feel decided, not random. A dash kick cracks brick and lowers its break energy to 4,542 J (7,500 − ½ × 5,915): a second dash kick then breaks it, a standing kick still does not. That makes speed and pursuit matter. A body breaking drywall at 13 m/s exits at about 11 m/s (absorption 0.3) and can reach the next wall. Impact damage follows the same energies (Mode and rules).

## Destruction

Walls are pre-fractured panels of 8–15 chunks, swapped in at the moment of breaking; nothing is fractured at runtime. Big chunks read better at fighting speed and keep the physics budget for ragdolls.

**Authoring (Blender via MCP)**

1. Model a panel, for example 3 × 3 × 0.25 m, per material (drywall, brick, concrete).
2. Fracture into 8–15 chunks with Blender's Cell Fracture add-on (check it is enabled in your Blender version), biasing smaller chunks toward the centre where hits land.
3. Export intact mesh, cracked mesh and chunks in one .glb; give each chunk a convex collision shape.

**Runtime**

- `Destructible` = a `StaticBody3D` holding the intact mesh and collider, plus the hidden chunk set.
- On break: hide the intact panel, enable the chunks as `RigidBody3D`, impulse each one radially from the impact point plus a share of the victim's velocity; chunk mass from its volume.
- Buildings v1 = grids of independent panels. Stretch: when a panel loses the panels beside and below it, it unfreezes and falls.
- Props (pillars, crates, lamp posts) use the same node with lower break energies.

**Budget (my starting numbers)**

- At most 150 live chunks; chunks that sleep freeze after 4 s and fade out after 10 s, oldest first.
- Small chunks do not collide with each other (a collision layer); all chunks collide with ragdolls and the floor.
- Profile at 5 enemies + 150 chunks in M7 before adding more.

## Blood

Blood is a feedback system, not decoration: every hit and impact sprays blood scaled by its energy onto the fighters, the floor and the walls, and it stays for the round. It also shows damage, since a fighter's blood level tracks their lost HP. Killing blows can also sever limbs and heads (Dismemberment, below).

Overgrowth is the precedent: weapons "slash open wounds" with "blood spurts and trickles realistically down their clothing", and David Rosen promised "really disturbing depictions of blood and pain" ([PC Gamer](https://pcgamer.com/overgrowth-preview)).

| Layer | Trigger | Godot build (my design) | Budget |
| --- | --- | --- | --- |
| Spray | Every hit above a jab, and every impact over 500 J | `GPUParticles3D` burst, droplet count scaled by energy, aimed along the hit with spread. Particle colliders make droplets land on the floor and walls instead of passing through ([Godot GPU particles](https://godotengine.org/article/improvements-gpuparticles-godot-40)) | One pooled emitter per fighter |
| Wall and floor splats | Same events | GPU particles cannot report where they land, so the game casts 3–6 rays from the hit along the spray cone and places a `Decal` at each surface they reach, sized by energy | Shared cap of 256 decals; the oldest fade first |
| Impact smears | A launched body hitting a wall, pillar or floor | One large decal at the contact point, stretched along the body's velocity. Bodies through drywall leave a smear on both sides of the hole | Counts toward the 256 |
| Blood on fighters | Each hit | A shader mask on the character material: keep the last 16 hit positions in the hit bone's local space and redden the skin and clothes around each. Because positions are bone-local, the blood follows animation and ragdoll | 16 points per fighter |
| Pools | A body lying still for 1.5 s, and every dead body | A floor decal under the chest that grows from 0 to 1.2 m over 4 s | Counts toward the 256 |

**Decal rules from the docs** ([Godot decals](https://docs.godotengine.org/en/latest/_sources/tutorials/3d/using_decals.rst.txt)): put characters on their own visual layer and leave it out of world decals' cull mask, so wall splats do not paint fighters. Keep each decal's projection depth short for culling. On the Forward+ renderer decals share a default limit of 512 clustered elements per view with lights; the Mobile and Compatibility renderers allow only 8 decals per mesh, so this game targets Forward+. The docs do not say whether decals work on skinned meshes, which is why fighters use the shader mask instead.

**Gameplay:** enemies' blood level shows how hurt they are, so no health bars float over a crowd. Pools and smears record where the round's big hits happened, alongside the broken walls.

**Settings:** a Gore option with Off, Blood, and Blood and dismemberment. Off swaps red for dust and keeps every limb attached.

### Dismemberment

Yes, it is possible, and the reliable way is to plan the cuts in the model: split the character into pieces at 5 cut points in Blender, hide a piece when it is severed, and spawn a loose copy of it at the same pose. That avoids cutting meshes at runtime, which this game does not need.

**Evidence:** developers on Unreal's forum describe the same three approaches: hide the hit bone and spawn a copy of that part; pre-slice the model and attach a "gore stump" at planned cut points, at the cost that you "have to plan ahead"; or spawn separate gibs, as Left 4 Dead 2 did ([Unreal Engine forum](https://answers.unrealengine.com/questions/20643/view.html)). We use pre-sliced pieces plus a spawned copy.

**Cut points:** head (at the neck), each forearm (at the elbow) and each lower leg (at the knee). Five cuts cover the iconic moments without modelling every joint.

**When a limb comes off (tuning starts)**

1. Only on a killing blow, or on a body already at 0 HP. Living enemies never lose limbs, so dismemberment never changes how a fight plays, only how it ends.
2. The blow on that part, or the impact it takes, must reach 4,000 J or come from a finisher: a fully charged power punch, a teleport counter, or a throw into brick or concrete.
3. The part nearest the hit point goes. A teleport-counter kick to the head is a decapitation; a throw into brick can take a lower leg.
4. The player is never dismembered while alive; only the final death on a lost round can show it.

**How it is built (my design; verify in a spike)**

1. **Blender (via MCP):** cut the mesh at the 5 seams into separate objects that share the armature. Model a stump cap for both sides of each cut. Export one .glb.
2. **On sever:** hide that piece's `MeshInstance3D`; show the body-side cap; remove the piece's physical bones from the ragdoll by restarting the simulation with them left out of the bone list; spawn a loose copy of the piece, with its cap, as a `RigidBody3D` at the piece's current transform and velocity.
3. **Effects:** an arterial spray emitter on the stump for 2 s, a decal trail where the loose part bounces, and a pool where it stops. A decapitation gets slow motion if the budget allows.
4. **Budget:** loose parts count toward the 150-chunk debris cap and freeze and fade the same way.

Two engine details are unverified and belong in an M5 spike: whether restarting the ragdoll with fewer bones is clean mid-flight, and whether the bones of hidden pieces need their collision turned off by hand. Godot's docs do not state the order in which skeleton modifiers run, which is why this design hides mesh pieces instead of scaling bones to zero.

## The map: The Yard

The first arena is a raised warehouse yard: an open, flat 22 × 22 m courtyard ringed by rooms whose walls break at three different energies, walled on every side so nobody leaves the fight. Everything in it is built from one Blender kit of 3 m panels, so a second arena is a re-arrangement, not new art.

&#91;embedded content: first arena, The Yard · top-down floor plan\]

Walls get harder the further a body has to travel: drywall to the west, brick to the north and east, concrete around the outside.

| Piece | Why it is there | Evidence or pillar |
| --- | --- | --- |
| Open, flat courtyard | Combos and launches are never cut short by low geometry; the camera has nothing to snag on | Melee arenas are usually open, flat and empty; DmC's Rahni Tucker on combos ending when you "bump into a waist-height wall" ([Game Developer](https://www.gamedeveloper.com/design/level-design-for-melee-combat-systems)) |
| 22 m across | A body launched at 13 m/s from the centre reaches a wall in under a second, so wall hits are frequent, not rare | Arena size should scale with how far and fast fighters move (same source); figure is my arithmetic from the impact table |
| Drywall offices (west) | First walls anyone breaks; a standing kick goes through, so the energy rule is learned in wave 1 | Pillar 4; impact table |
| Brick garage and storage | Need a dash kick, teleport counter or pursuit to break; the deliberate near-miss | Pillar 3; impact table |
| Concrete outer walls and 4 pillars | Guaranteed bounce surfaces; pillars give wall-splats mid-field without sending bodies out of the fight | Pillar 1 |
| Concrete south wall | No exits and no drop: every launch ends on a surface, and the long run south across the open strip gives the biggest wall splats in the yard | Your call: melee only, no edge; arenas bounded by walls ([Game Developer](https://www.gamedeveloper.com/design/level-design-for-melee-combat-systems)) |
| Stairwell spawns, out of the courtyard | Enemies arrive out of sight but must walk into view before they may attack | AI rule 4; enemies "almost never" attack from off screen |
| Entries through rooms | Wave 2+ enemies come through the offices; the Brute bursts the roll door | Arrival as a telegraph: a crack sound, then a body through the wall |

**The arena remembers across waves.** Broken walls stay broken for the rest of the round. By wave 4 the courtyard is bigger, launch paths are longer, and debris is on the floor for the Thrower. The round's history is visible on the map.

**Kit to build in Blender:** a 3 × 3 × 0.25 m wall panel in drywall, brick and concrete (each with intact, cracked and 8–15 chunk versions), a 1 m pillar, a roll door, and a floor tile. Godot scenes instance the kit; no unique meshes.

## Game feel: hitstop, slow motion, camera

Hitstop is local to the two fighters in a hit; slow motion is global and rationed. Slow motion uses `Engine.time_scale` — run from a single `TimeDirector` that owns all time changes, so effects never fight each other.

**Why `Engine.time_scale` works here:** each physics tick's delta equals time\_scale divided by ticks per second ([Godot API, via godot-rust docs](https://godot-rust.github.io/docs/gdext/pr-1606/godot/classes/trait.ITileMapLayer.html)), so in slow motion Jolt takes smaller steps rather than skipping time. Bodies in flight stay smooth. Scripted torques must use that scaled delta.

### Hitstop

Fighting games freeze both fighters on impact, longer for heavier attacks ([SuperCombo, SF6](https://srk.shib.live/w/Street_Fighter_6/Game_Data)); Smash also shakes characters during it ([critpoints](https://critpoints.net/2017/05/17/hitstophitfreezehitlaghitpausehitshit/)).

| Hit | Hitstop (real time) |
| --- | --- |
| Jab | 50 ms |
| Leg sweep | 70 ms |
| Power punch | 90–150 ms by charge |
| Sparta kick | 120 ms |
| Teleport counter | 160 ms |

**Hitstop is local.** With several enemies a hit lands every few hundred milliseconds; freezing the whole world each time would make the game stutter, and hitstop write-ups describe freezing the characters in the hit, not the world ([critpoints](https://critpoints.net/2017/05/17/hitstophitfreezehitlaghitpausehitshit/)). So for the durations above: set the attacker's and victim's `AnimationTree` speed to 0, store and zero the victim's bone velocities if it is already a ragdoll, then restore them. Time it with `create_timer(duration, true, false, true)` so the timer ignores time scale. Jitter the victim's mesh a few centimetres during the freeze.

### Slow motion triggers

| Trigger | Scale | Duration (real) |
| --- | --- | --- |
| Perfect dodge | 0.3× | 0.25 s |
| Wall break | 0.25× | 0.35 s |
| Launch of 9,000 J or more | 0.35× | 0.5 s |
| Final KO | 0.2× | 1.0 s, camera orbits |

**TimeDirector rules**

- Requests go on a priority stack: final KO > wall break > big launch > perfect dodge. A request ends by restoring the scale below it, not by jumping to 1.0×.
- Budget: slow motion may cover at most 15% of any 10 s of real time, KO excepted. A crowd triggers far more events than a duel, so most requests will be refused; that is intended.
- Ease back over 0.15 s. Input windows and cooldowns count real time.
- `Engine.time_scale` does not slow audio; set `AudioServer.playback_speed_scale` alongside it ([Godot Engine API](https://docs.godotengine.org/en/latest/_sources/classes/class_engine.rst.txt)).
- The editor's game-speed control multiplies the physics tick rate ([docs](https://docs.godotengine.org/en/latest/tutorials/editor/game_embedding.html)), so judge the final feel with in-game time scale.

### Camera (BT3-style)

- Third person behind the player. The soft target is the enemy nearest the direction of the left stick, or the current token holder when the stick is idle. The camera frames the player, the soft target and any token holder, pulling back from 3 m to 9 m as they spread.
- An arrow at the screen edge marks any enemy winding up off screen; the AI already may not attack from off screen (Enemies and AI, rule 4).
- Launch over 10 m/s: follow the victim's pelvis with lag for up to 1.5 s, then return. While the follow-cam runs, the `AttackDirector` grants no new tokens, so the player is never hit while the camera looks away. During pursuit, cut to behind the pursuer.
- Spring arm ignores debris and ragdoll layers so chunks never shove the camera.
- Screen shake from a trauma value set by hit energy; small amplitude.

## Creative angles

The strongest idea for 1 vs many is that bodies are weapons: a launched enemy that hits another enemy hard enough launches them too. It reuses the impact resolver, costs little, and makes a crowd an opportunity instead of a threat. The rest are ranked by payoff against cost; all are my proposals.

| Idea | What happens | Cost | Priority |
| --- | --- | --- | --- |
| Human bowling | A flying body hitting an enemy above a topple energy (e.g. 1,500 J) launches that enemy too and passes on part of its speed. A chain counter shows ×2, ×3 | Low: same energy check as walls, with enemies as targets | P0 |
| Pick your teleport target | During the perfect-dodge slow motion, flick the stick toward any enemy to reappear behind that one, not only the attacker. Defence becomes crowd control | Low | P0 |
| The environment deals damage | Wall, pillar and floor impacts deal damage scaled by impact energy. Aiming launches is how you win, not mashing | Low | P0 |
| Enemies arrive through walls | A crack sound and dust on a wall, then a body bursts through it 1 s later. Arrival is the telegraph and the arena keeps the scar | Low: scripted break on a spawn panel | P1 |
| Kill-cam replay | The last KO of each wave replays in slow motion from an orbiting camera. Record every bone transform for the last 4 s in a ring buffer and play it back; no re-simulation | Medium | P1 |
| Debris as ammo | Chunks from broken walls can be kicked at enemies; the Thrower picks them up. Destruction feeds combat | Medium | P1 |
| Procedural impact sounds | Thud, crack and slide sounds pitched and scaled by contact impulse (V2 6:04) | Medium | P1 |
| Chaos rounds | Optional round modifiers that only change numbers: half gravity, double body mass, glass walls. V2's point that wacky is just different numbers makes these nearly free | Low | P2 |
| Second arena from the same kit | A dojo with paper walls (500 J) where everything breaks, or a construction site whose scaffold falls when its legs are kicked out | Medium | P2 |

## Milestones

Ten milestones in three stages: the ragdoll (M0–M2), a 1v1 slice against one AI opponent (M3–M6), then the crowd and the full arena (M7–M8). M6 is the first point where the game is fun to play; if it is not fun there, adding enemies will not fix it.

| # | Milestone | Scope | Done when |
| --- | --- | --- | --- |
| M0 | Project and character | Godot 4.7.2 + Jolt at 120 Hz, physics interpolation on; Mixamo character and clips retargeted; physical skeleton pruned, cone and hinge joints, Dempster bone masses; collision layers | Character walks; toggling full ragdoll 50 times never explodes or self-collides; ragdoll mass sums to 70 kg |
| M1 | Ragdoll lab | `RagdollProfile`; scripted soft limits and neutral tension from one loop per character; limb spin; test contact reporting and continuous collision on bone RIDs; profile cost per ragdoll | Side-by-side scene reproduces V1 (gradual knee stop, no arms overhead, arms back and legs forward in an explosion); measured ms per ragdoll written down |
| M2 | Launch and get-up | Launch as velocity; falling-loop layer; get-up face up and down; Grounded timeout; addon spike (one day) | 20 random launches in a row all recover with no stuck bodies or visible pops |
| M3 | Hit pipeline and 1v1 AI | Player moves; hit registry; local hitstop; HP and damage; one Duelist with tokened, telegraphed attacks | A full 1v1 round plays start to KO against the AI |
| M4 | Timing and speed | Perfect dodge with invulnerability, teleport counter with shape-cast, Focus numbers, anti-mash rule, dash momentum, pursuit, air recovery, grab, throw, grab break and reversal | A tester lands a perfect dodge on purpose 8 of 10 times and breaks the AI's grab 7 of 10 times after 5 minutes; dash kick launches at least 50% further than standing |
| M5 | Walls and impact | Drywall and brick panels from Blender; `Destructible`; centre-of-mass sweep; break, crack, bounce; impact damage; blood spray and wall decals | Worked-example table reproduces within ±15%; a one-forearm dismemberment spike works mid-flight |
| M6 | 1v1 feel pass | `TimeDirector` with stack and budget; audio speed; camera; shake; blood on fighters, impact smears and pools | The 1v1 slice is fun to replay; slow motion never stacks or exceeds its budget |
| M7 | The crowd | `AttackDirector`, rings, tells, off-screen arrows; Grunt, Brawler, Shield; body-on-body resolver; ragdoll LOD; multi-target camera | 5 enemies at once hold 60 fps on your machine; no hit lands from off screen in a 10-minute test |
| M8 | The Yard, full round | Whole arena kit; 4 waves; Brute and Thrower; spawn entries through walls; persistent damage; dismemberment at 5 cut points | A 4-wave round plays start to finish without a bug |
| M9 | Stretch | Kill-cam, debris as ammo, procedural sounds, chaos rounds, second arena, dislocation | Pick from playtest feedback |

**Cut from the first playable:** dislocation, building collapse, local two-player, the protect-head pose, procedural sounds, and AI that counters your teleport counter. Ki blasts, central to BT3, are out of scope: this game is melee only.

## Risks and open questions

| Risk | Mitigation |
| --- | --- |
| Active ragdolls under Jolt are fragile: springs explode or misbehave after hits ([forum](https://forum.godotengine.org/t/active-ragdolls-in-godot-jolt-is-it-even-possible/117047)) | Muscles only for hit reactions; clamp torques; passive ragdolls for minions |
| GDScript cost of per-bone torques for 4–6 bodies at 120 Hz (unmeasured) | One loop per character on RIDs; ragdoll LOD; measure in M1 before M7 |
| No contact reporting or continuous collision on `PhysicalBone3D` | The resolver's sweep does not depend on contacts; test the `PhysicsServer3D` RID calls in M1 |
| Tunnelling through thin walls at 15–20 m/s | Sweep covers the body's extent; outer colliders at least 1 m thick; panels 0.25 m with the resolver deciding |
| Crowd stays unreadable even with tokens | Start Normal with 2 tokens and Easy with 1; tune tells first, numbers second |
| Active-ragdoll addon is young (3 commits, 2 stars) | One-day spike in M2; own velocity motor as fallback |
| Mixamo retargeting artefacts | MixaBridge or one consistent BoneMap; build libraries from imports, not from AnimationPlayer |
| Debris plus several ragdolls | 150-chunk cap; dead bodies freeze when settled; profile in M7 |

**Open questions for you**

- [x] 1v1 or one against many? One against many, built 1v1 first.
- [x] Versus AI or local players? Versus AI.
- [x] How does a round end? When the player dies or the last enemy dies. No last stand: death is final.
- [x] An edge to fall off? No: walled on every side.
- [x] Ranged attacks? No: melee only.
- [x] Blood? Yes, with dismemberment (Blood section).
- [ ] Art direction: Mixamo-realistic, or stylised? Undecided. It changes how the blood, stump caps and enemy silhouettes are drawn, not the systems, so it can wait until M8's art pass.

## Sources

Videos (narration captured from auto-generated captions):

- [V1 — Improving ragdolls forever](https://www.youtube.com/watch?v=yY6vck8SuCY)
- [V2 — Ragdolls improved by YOUR suggestions.. you weirdos](https://www.youtube.com/watch?v=X1V_VeR0h4E)

Godot and Jolt:

- [Godot ragdoll system docs](https://docs.godotengine.org/en/stable/tutorials/physics/ragdoll_system.html)
- [PhysicalBoneSimulator3D API](https://docs.godotengine.org/en/4.3/classes/class_physicalbonesimulator3d.html)
- [Using Jolt Physics (Godot docs)](https://docs.godotengine.org/it/4.4/tutorials/physics/using_jolt_physics.html)
- [Godot 4.6 release: Jolt by default](https://godotengine.org/releases/4.6/)
- [Godot 4.7.2 maintenance release](https://gamedev.net/news/5172-godot-engine-472-stable-released/)
- [Jolt author on soft limits](https://github.com/godot-jolt/godot-jolt/discussions/826)
- [Jolt author on driving ragdolls](https://github.com/jrouwe/JoltPhysics/discussions/1764)
- [godot-active-ragdoll addon](https://github.com/DanilKhmyrov/godot-active-ragdoll)
- [Godot forum: active ragdoll in 4.5](https://forum.godotengine.org/t/active-ragdoll-in-godot-4-5-how-to-achieve-good-results/128728)
- [Game embedding and game speed](https://docs.godotengine.org/en/latest/tutorials/editor/game_embedding.html)
- [MixaBridge](https://www.godotengine.org/asset-library/asset/5096)
- [Destructibles-CSharp](https://www.godotengine.org/asset-library/asset/edit/9886)
- [PhysicalBone3D API source](https://docs.godotengine.org/en/latest/_sources/classes/class_physicalbone3d.rst.txt)
- [CharacterBody3D API source](https://docs.godotengine.org/en/latest/_sources/classes/class_characterbody3d.rst.txt)
- [Engine API source (time scale, audio)](https://docs.godotengine.org/en/latest/_sources/classes/class_engine.rst.txt)
- [Godot forum: active ragdolls in Jolt](https://forum.godotengine.org/t/active-ragdolls-in-godot-jolt-is-it-even-possible/117047)
- [Visual3D wiki: Dempster segment masses](https://wiki.has-motion.com/Segment_Mass)
- [Godot docs: using decals](https://docs.godotengine.org/en/latest/_sources/tutorials/3d/using_decals.rst.txt)
- [Godot: GPU particle improvements (collision)](https://godotengine.org/article/improvements-gpuparticles-godot-40)

Game references:

- [Kanzenshuu: teleport counters across Budokai and BT3](https://www.kanzenshuu.com/forum/viewtopic.php?p=1528004)
- [SuperCombo: BT3 Defense](https://srk.shib.live/w/Dragon_Ball_Z:_Budokai_Tenkaichi_3/Defense)
- [Giant Bomb: Budokai 3](https://wiki-origin.giantbomb.com/wiki/Games/Dragon_Ball_Z_Budokai_3)
- [PC Gamer: Overgrowth](https://www.pcgamer.com/au/physics-based-brawler-overgrowth-released-on-steam-early-access)
- [Game Developer: Rosen GDC 2014](https://gamedeveloper.com/design/video-an-indie-approach-to-procedural-animation)
- [SuperCombo: SF6 hitstop](https://srk.shib.live/w/Street_Fighter_6/Game_Data)
- [critpoints: hitstop](https://critpoints.net/2017/05/17/hitstophitfreezehitlaghitpausehitshit/)
- [Game Developer: enemy design and AI for melee combat](https://gamedeveloper.com/design/enemy-design-and-enemy-ai-for-melee-combat-systems)
- [Game Developer: level design for melee combat](https://www.gamedeveloper.com/design/level-design-for-melee-combat-systems)
- [Envato Tuts+: battle circle AI](https://code.tutsplus.com/battle-circle-ai-let-your-player-feel-like-theyre-fighting-lots-of-enemies--gamedev-13535t)
- [PlayStation Blog: Sifu combat](https://blog.playstation.com/2021/11/18/how-sifus-kung-fu-combat-works/)
- [Siliconera: Sleeping Dogs combat](https://www.siliconera.com/sleeping-dogs-fighting-system-inspired-by-tony-jaa-action-flick-the-protector/)
- [Infil's Killer Instinct guide: throws and throw techs](https://ki.infil.net/basics3.html)
- [Prima Games: breaking throws in Tekken 8](https://primagames.com/gaming/how-to-break-throws-in-tekken-8)
- [PC Gamer: Overgrowth preview (blood)](https://pcgamer.com/overgrowth-preview)
- [Unreal Engine forum: dismemberment approaches](https://answers.unrealengine.com/questions/20643/view.html)
