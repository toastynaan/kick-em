# Feel Reference — Sifu × Prototype for the Ragdoll Brawler

Nov 2, 2026 · @Pahul

## Summary

The target: Sifu's grounded, readable hand-to-hand fighting, Prototype's sense of speed and overwhelming power, and BT3's launches and teleports, all delivered through the physics ragdolls that are this game's brand. Every reaction stays physical; the reference games' canned animations are only a guide to timing, poses and effects.

**How Claude Code should use this doc:** the clip sections are evidence, with timestamps you can open. The spec sections turn that evidence into behaviour. Every number in them is a starting value I chose, not a measurement from the clips: put them in `tuning.gd` and tune them in play. Work through the build tasks at the end in order. Anything I could not see clearly in a clip is marked as a guess.

**Decisions already made**

- Physics ragdolls on every hit; partial ragdolls for small reactions. Never replace them with canned reactions.
- Sifu-style fighting is the base, with BT3 launching and teleporting on top, and slow time throughout.
- Two timed defences: tap block at the right moment to parry; dash in that window to teleport behind. The teleport costs Focus.
- No complicated structure or balance gauge. The goal is the enjoyment of Max Payne and Prototype.
- Launches can happen from any strike. Charging is the risk; sprinting and speed give the power for big launches.
- No signature moves: any strike can launch, break a wall or sever a limb if it carries enough power from charge or speed.
- Enemies are not one-launch kills. Living enemies can lose limbs.
- The player starts weak and earns power over a run (roguelike, not built yet).
- Charging during a sprint keeps your speed, but you can only steer slowly. Charging while walking slows you to half speed.
- Throws are no stronger than strikes. Throw speed follows run speed and is capped.
- Sweep is pull back + Kick. Grab is on LT.
- Enemies can grab you and knock you down, but can't launch you or take your limbs (for now). Your death ends the run.
- Each wave starts with 1 Focus bar. Focus doesn't refill during Focus mode. Pursuit costs 1 Focus, with at most 2 chained.
- An enemy who loses a limb limps or crawls away and can be finished off. Dead bodies can be grabbed and thrown.
- Running into enemies is an upgrade (Battering Ram). Before it, you fall when you run into heavies.
- Wall runs are in. Focus mode is LB / L1, or F on keyboard.

## This doc replaces parts of the older specs

Claude Code will also have the original spec (Ragdoll Brawler — Godot Game Spec) and Upgrade Spec 2. **Where they disagree, this doc wins.** Ideas from Upgrade Spec 2 still stand: tap and hold input, the combo graph, body-part grabs and the roguelike.

| Topic | Older spec | This doc (wins) |
| --- | --- | --- |
| Defence | Free perfect dodge on Block; teleport counter on Light or Kick | Tap Block to parry. Teleport is a fresh Dash press in the same window and costs 1 Focus. |
| Hitstop | Global `Engine.time_scale` 0.02 for jab 50 / kick 120 / counter 160 ms | Only the attacker and victim freeze, 40–180 ms by tier. The player's own freeze is capped at 60 ms. |
| Launch model | `J = J_move × m_charge + k × M × v` | The power score P sets the tier and launch speed. **Delete the J formula.** Keep only the wall energy check E = ½Mv². |
| Frame data | Power punch 14–30 frames of startup | Jab 5, cross 9, kick 12, sweep 10. Charging adds hold time on top. |
| Partial ragdoll | Flinch influence 0.3 over 0.3 s; stagger becomes a launch at 35° pelvis tilt | The tier table in "Strikes and body reactions". A stagger keeps the legs animated and never turns into a launch by itself. |
| Sweep | Falls in place | Stumble when tapped, knockdown at P 3.5 or more, launch at P 5 or more |
| Camera | 3–8 m, follows the victim for 1.5 s | 4–9 m depending on crowd and launches. Follows for 1.0 s at most. The player is always in frame. |
| Slow motion | Dodge 0.3×; launches over 12,000 J at 0.35× | The table in "Defence and time". The 12,000 J rule is removed because no launch reaches it. |
| Focus refill | From hits and perfect dodges | From parries and strong hits only. Each wave starts with 1 bar. Nothing refills during Focus mode. |

Unchanged from the original spec: the wall energy thresholds (drywall 2,000 J, brick 6,000 J, concrete 15,000 J, cracking at 40% of those), the crack rule that lowers a panel's threshold by half the hit's energy, the destruction system, blood, and Jolt at 120 Hz.

## Sifu clips: what happens, second by second

Times are approximate. I sampled frames every 0.35–1 s, so a move shorter than that may be missing. Each clip ends with the lesson Claude Code should take from it.

### Sifu 1: fighting, animations, body reactions (20 s, rain, enemies in suits)

| Time | What you see | Why it feels good |
| --- | --- | --- |
| 0.25–1.25 s | A ring of enemies stands around the player. Only one or two step in. | You can read the fight. You are never hit from behind by five people at once. |
| from 3.25 s | A balance bar shows under the current target. | You can see the enemy breaking before it happens. |
| 3.75 s | Every connecting hit gets a sharp radial flash and a burst of rain splash. | You get a visible hit confirm on the exact contact frame. |
| 4.75 s | The enemy's foot glows before his kick. | His wind-up is easy to read, so you have time to parry. |
| 7.75 s | One hit sends an enemy horizontally through the air, flat and stiff. | A big hit changes where the body is, not just how much health it has. |
| 8.25–9.75 s | The player finishes a downed enemy on the ground. | The fight still has a payoff once an enemy is down. |
| 12.75 s | A big circular swirl effect on a heavy hit. | Effect size goes up with the power of the hit. |
| 17.65–18.45 s | The camera closes in and time slows for the last hit. | Only the last hit gets the cinematic treatment. |

**Lesson:** each hit gets a flash and a body reaction, and both get bigger with power. Frames sampled 0.35–1 s apart can't show hitstop or exact frame timing, so the same-frame rule and the hitstop values later in this doc are our design, not measurements from the clip. Enemies telegraph clearly, and only the last enemy gets the slow-motion close-up.

### Sifu 2: fighting, animations, grab (11.4 s)

| Time | What you see | Why it feels good |
| --- | --- | --- |
| 0.1–1.15 s | The player picks a brick off a ledge mid-stride and throws it. Dust puffs off the ledge. | Objects in the level become weapons with no menu. |
| 1.5 s | The brick bursts on the big enemy's head. | A thrown object breaks on impact, and it reads clearly. |
| 1.85–2.55 s | The player rushes in and lands close strikes. | The gap closes fast after a ranged opener. |
| 2.9–3.25 s | A shove sends the enemy stumbling backwards into a shallow pool, with motion blur. | A stumble is a reaction of its own, between a flinch and a fall. |
| 3.6–5.35 s | The player follows, kneels on the downed enemy in the water and strikes. Water rings spread out. | You chase the downed body, and the setting reacts. |
| 5.7–6.75 s | The player clinches the big enemy. | A grab is a state you hold, not a one-frame move. |
| 7.1–7.45 s | The player throws him into another enemy and both go down. | Bodies are projectiles. |
| 7.8–8.15 s | Two red markers appear on an enemy's chest. This is very likely Sifu's Focus attack: time slows and the player aims at a body point with the stick. |  |
| 8.5–10.95 s | Palm strike, knee (9.55 s), push (10.25 s), with a stick enemy waiting behind. | Short strings mix strikes with pushes. |

**Lesson:** grab and throw is the core of the clip. Any body or loose object becomes something to throw, and a thrown body knocks over whoever it hits. A shove makes the enemy stumble, which is our sweep stumble.

### Sifu 3: combat, "as intended" (44.8 s, sepia, no HUD)

| Time | What you see | Why it feels good |
| --- | --- | --- |
| 0–5 s | A lobby with sofas and about eight enemies. | The room has props. |
| 5–30 s | The camera sits wide and high during the group fight. Enemies attack one or two at a time while the rest hover in a loose ring. | You can see everyone, and the attack tokens are invisible but obvious. |
| 12.3 s | A white-shirt enemy is launched backward. | A launch happens inside normal fighting. It isn't a special mode. |
| 17–30 s | Bodies pile up on the floor and stay there. | The room keeps a record of the fight. |
| 33.3–35.7 s | A kick sends an enemy into a coffee table, which breaks. The pieces stay. | The environment pays off a hit. |
| 30.9–44 s | The camera drops lower and closer over the shoulder as the crowd thins. | Camera distance follows how many enemies are still up. |
| end | The player stands over the bodies. | A clear end beat. |

**Lesson:** the camera pulls back for crowds and moves in for one-on-one. Bodies and broken furniture stay. The player flows from target to target with no lock-on button.

## Prototype clips: what happens, second by second

Prototype is open-world, so we only take what fits a small arena: how the sprint builds up, how the character climbs obstacles without help from the player, how landings and speed are shown, and how a grabbed body travels with you.

### Prototype 1: the grab, the running and the jump (25 s, Prototype 2)

| Time | What you see | Take for our game |
| --- | --- | --- |
| 0–6 s | The player holds a soldier in one arm while running and leaping across rooftops. At 3.3–4.9 s he carries him through the air. | **Carrying is a movement state.** You can grab, then run, jump and dash with the body in hand. |
| while holding | Three prompts appear: consume, throw and one more. | The grab has a short, clear menu: throw, slam, or let go. No more than that. |
| 6.5–9.3 s | Tendrils wrap the victim, who turns into a red mass. | Too much for us. Skip it. Use a body slam instead. |
| 11.7–12.2 s | A running start, then a huge leap off the roof while still carrying the victim. | The jump inherits sprint speed. |
| 13.2–17.7 s | They fall together and the camera follows, tilted. | Tilting the camera during a fall sells height. |
| 19.5 s | A red burst near the ground. | Landing with a body triggers a hit. |
| 21.3 s | He lands cleanly on the street, standing, with no fall damage. | **The player never falls over from a jump.** Landings look heavy but you keep moving. |

### Prototype 2: running that gets faster, automatic parkour (58 s)

| Time | What you see | Take for our game |
| --- | --- | --- |
| 0–10 s | A sprint through a park and a street. People hit by the runner fly sideways (2.7 s). | **Sprinting into an enemy is an attack.** Here it is an upgrade; see "Running into enemies". |
| 5.1–5.9 s | Sprinting through traffic with a red streak trail behind him. | A trail shows when you are at top speed. |
| 10.7 s | He runs straight up a building wall with red streaks. | Too much for an arena, but **a short wall run-up (one storey) or a wall kick-off** fits. |
| 11.5–12.3 s | Lands on a roof with a dust puff. | Every landing makes dust. |
| 13–19 s | Huge roof-to-roof leaps with streak trails. The camera pulls far back and up. | **The camera pulls back as speed rises.** |
| 1.9, 16.3, 18.7 s | A white corner-bracket marker. It could be a target or a ledge marker; I can't tell which. | A small marker on the enemy your sprint attack will hit. |
| 23.9–27.9 s | Strong radial blur at top speed. At 7 s, while still accelerating, the blur is mild. | **Blur scales with speed.** It is a curve, not on or off. |
| 28.9–35.9 s | He dives off a roof into a group of enemies. A big impact and a burst of blood. | **Landing from a height on enemies is an attack.** |
| 39.9–49.9 s | He runs up a brick wall, kicking dust and debris off it. | The wall reacts to the feet. |
| 50.9 s | He vaults over the top ledge without a button press. | **Vaulting is automatic.** |

### Prototype 3: parkour and running (25 s, night city, first Prototype)

| Time | What you see | Take for our game |
| --- | --- | --- |
| 0–5 s | Rooftop jumps chained together. |  |
| 5.7–7.2 s | He vaults vents and obstacles automatically and keeps his speed. | **A vault must not slow you down much.** We use a 10% speed loss at most. |
| 8.7–9.7 s | He lands on roof edges in a crouch. | A small landing crouch for short falls. |
| 10.7–11.2 s, 15.2–16.2 s | A heavy landing with a big dust cloud and debris chunks. | **Landing severity has levels.** Short drops get a small puff; big drops crack the floor and shake the camera. |
| 13.2 s, 18.95 s | A wall run sideways along a building face. | Optional: a short wall run on arena walls. |
| 14.2 s | A roll on landing. | A roll keeps speed after a high fall. |
| 18.2 s, 21.95 s | Radial blur during an air dash or glide. | An air dash gets the same blur as top-speed sprint. |

### Prototype 4: full speed with all upgrades, power effects (62 s, Prototype 2)

| Time | What you see | Take for our game |
| --- | --- | --- |
| 0.5–2.5 s | A street full of enemies and bodies, with blood pools on the wet road. | Bodies and blood stay. |
| 3.5–8.5 s | He sprints along the street through the crowd. The camera sits low, behind and wide, with ground blur. | **Wide angle at speed.** Raise the field of view as you run. |
| 9.5–10.5 s | The whole screen tints red-orange and a blue glow wraps the character. | **A full-screen color shift** marks a power state. We use it for Focus. |
| 14.5 s | An explosion fireball next to a car. | Out of scope. We don't have explosives. |
| 15.5–17.5 s | Red streaks and a body knocked aside on the run. | Running into enemies again; an upgrade here. |
| 20.5 s | His feet throw water spray as he slides on the wet road. | **Feet react to the floor:** dust, water, sparks. |
| 28.5–35.5 s | He runs past enemies who are knocked down, with bodies on the ground and burning wrecks. | Running through a fight is part of the fight. |
| 55.35–57.05 s | A big jump with a red trail, seen from above. | The trail stays during jumps. |
| 57.9 s | He lands with a vertical red trail behind him. | The landing gets a vertical streak. |
| 58.75–61.3 s | He holds a red, burning enemy, then fights at close range. |  |

**Prototype lesson for us:** the player is never stopped. Obstacles are climbed for you, landings don't knock you down, and the faster you go, the more the screen tells you so: wider field of view, more blur, trails, dust. Speed itself becomes a weapon.

## Movement spec: sprint, automatic parkour, jump, landing

The goal is Prototype's "never stopped" feel, sized for an arena. All numbers are starting values and belong in `tuning.gd`.

### Sprint that builds

Hold Dash to sprint. That was already decided. Speed is not a switch: it ramps up, and holding a straight line is what gets you to the top.

| Stage | Speed | How you get there | Signals |
| --- | --- | --- | --- |
| Walk | 4.5 m/s | Default (the current value) | none |
| Sprint start | 6 m/s | Press and hold Dash | A small dust kick at the first step |
| Sprint | 6 → 8 m/s | Ease-out over 1.2 s of holding | Field of view 70° → 78°, light blur |
| Full speed | 8 m/s (base cap) | Holding for 1.2 s or more | Trail on hands and feet, full blur, footstep dust every step |
| Upgraded cap | 10, then 12 m/s | Roguelike upgrades only | Same signals, stronger |

- **You start weak.** The 8 m/s cap matches "earn your way there". Upgrades raise the cap and the ramp rate; the base game never shows 12 m/s.
- **Turning costs speed.** For a turn sharper than 60° inside 0.2 s, lose 30% of current speed. Gentle curves cost nothing. This rewards running at a target in a straight line.
- **Store a speed value** as `sprint_charge` (0–1 = 6 → cap). Effects and the camera read this number. Attack power reads your actual speed instead (see the power score), so speed upgrades also hit harder.
- Releasing Dash bleeds speed back to walk over 0.25 s. It doesn't snap.

### Automatic parkour

The player never presses a button to get over something. While moving toward an obstacle faster than 3 m/s, the character handles it. Probe with three forward `ShapeCast3D`s (at knee, chest and head height, 0.8 m ahead, length scaled by speed). Find the top of the obstacle with a downward `RayCast3D` from above the hit point.

| Obstacle height | Action | Duration | Speed kept |
| --- | --- | --- | --- |
| under 0.5 m | Step over (no animation, just lift the capsule) | instant | 100% |
| 0.5–1.2 m | Speed vault: one hand on top, legs swing over | 0.25–0.35 s (shorter when faster) | 90% |
| 1.2–2.2 m, sprinting only | Wall kick and mantle: one foot on the wall, then hands, then up | 0.45 s | 70% |
| 1.2–2.2 m, walking | Nothing. It acts as a wall. |  |  |
| over 2.2 m | Wall. At full speed you get a single wall kick-off that turns you up to 120°, keeping 80% of speed. | 0.3 s | 80% |

- Drive the capsule along a short curve (start → top of obstacle → landing point) with a tween. Turn root motion off, and drive the animation from the tween's progress.
- **The player can attack out of a vault.** If attack is pressed in the last 40% of the vault, the vault ends with a dropping strike that inherits the vault speed.
- Never vault over an enemy. A body in the probe counts as a target, not an obstacle.
- **The arena needs things to vault.** Add low walls (0.9 m), crates (1.1 m), a raised platform (1.8 m) and pillars to The Yard. Without them, none of this is ever seen.

### Wall run

This comes from Prototype 3 (13.2 s and 18.95 s). Sized for an arena, it is a short burst along a wall that sets up a strike, not a way to travel.

**Starting it.** You must be sprinting with `sprint_charge` of at least 0.6 and moving along a wall within 0.8 m, with velocity 10–45° off the wall's surface. Press Jump to start. Vaults are automatic, but a wall run takes a press: arena walls are everywhere, and an automatic wall run would trigger by accident mid-fight.

| Rule | Value |
| --- | --- |
| Speed | Keeps 100% of sprint speed along the wall |
| Length | 1.0 s at most, so 8 m at the base cap |
| Height | Rises 0.5 m over the first 0.3 s, then holds that height until the run ends. No gravity during the run. |
| Ends | After 1.0 s, at the end of the wall, or if the stick points away from the wall: you drop off and keep 90% of your speed |
| Jump during the run | Kick off the wall at 45° away from it, keeping 100% speed and adding 1.6 m of height. From the run's 0.5 m that clears the 1.8 m platform. |
| Mantle from the air | If your hands come within 0.5 m of a ledge top during any jump or kick-off, you mantle up automatically |
| Attack during the run | A wall-run strike. It counts as a full-sprint attack (speed bonus as if at the cap), so a tapped kick from a wall run launches. It ends the run and drops you to walking speed like any sprint strike. |
| Cooldown | The same wall can't be run again until you touch the floor |

**Which walls.** Arena walls and building faces get a `runnable` tag. Destructible panels are runnable while intact; a cracked panel is not. Bodies and debris are never runnable.

**Effects.** Each footstep on the wall kicks dust and small chips off it, as at Prototype 2, 39.9–49.9 s. The camera rolls 6° away from the wall, and trails and blur continue at the current sprint level.

**In code.** Cast a `RayCast3D` sideways from the chest on both sides. Accept a hit only if the wall normal is close to horizontal (normal.y between −0.2 and 0.2). Project velocity onto the wall plane and add a small force into the wall so the capsule stays on it. Play a left or right wall-run cycle, with its speed matched to velocity.

**The arena needs long walls.** The Yard needs at least two straight runnable walls of 8 m or more, with open floor beside them so the strike at the end has targets.

### Jump

- Tap Jump. Horizontal velocity is kept exactly, so a sprint jump goes much further than a standing jump. Jump height 1.2 m standing, 1.5 m at full speed.
- Coyote time 0.1 s. A jump press is buffered for 0.12 s before landing.
- Gravity is 1.6× normal while falling, so jumps feel heavy, not floaty.
- An attack in the air becomes a dropping strike. If the drop is higher than 2 m, it becomes a **ground slam** (see the landing table).

### Landing has levels

The player never falls over from a landing. That rule comes from Prototype 1 at 21.3 s.

| Vertical speed at landing | Name | Player animation | Effects | Gameplay |
| --- | --- | --- | --- | --- |
| under 8 m/s | Soft (every normal jump: 1.2 m lands at 6.1 m/s, 1.5 m at 6.9 m/s) | none, keep running | small dust puff | none |
| 8–11 m/s | Hard (jumping off the 1.8 m platform lands at about 9.7 m/s) | 0.12 s crouch, or none if rolling | dust ring 1.5 m, light shake | none |
| over 11 m/s, or any slam | Heavy | 0.2 s three-point landing, or a roll if holding a direction | crack decal, 6–10 small debris, strong shake, dust ring 3 m | A shockwave: enemies within 2.5 m stumble, within 1 m they are knocked down |

In our arena, falling alone would need a 4 m drop to make a heavy landing. So in practice heavy landings come from slams: any air attack from 2 m or more above the floor.

The roll on a heavy landing keeps 85% of horizontal speed. Use the existing `DebrisManager` for chunks and `BloodFX` only if the landing hits a body.

### Running into enemies

Running into enemies is **an upgrade you earn**. At the start, sprinting into someone hurts *you*, which fits "start weak, earn your way there".

A collision counts when you are at 85% or more of your speed cap and your capsule touches an enemy's.

| Level | Normal enemy | Heavy enemy (mass 95 kg or more, or tagged heavy) |
| --- | --- | --- |
| Base (no upgrade) | Both of you stumble. Your speed drops to walk. | **You fall and ragdoll** (knockdown tier). The enemy only flinches. |
| Battering Ram 1 | The enemy stumbles. You lose 15% speed and keep running. | Both of you stumble. |
| Battering Ram 2 | The enemy is knocked down. You lose 15% speed. | The enemy stumbles. You lose 30% speed. |
| Battering Ram 3 | The enemy is knocked down. You lose 10% speed. | The enemy is knocked down. You lose 15% speed. |

- Every collision adds a 50 ms hitstop. Running through a group should feel like ploughing, not gliding.
- A collision never launches and never breaks walls, at any level. Launching still takes an attack, so the power ladder still means something.
- **When you fall:** use the normal knockdown ragdoll on the player, but keep it short and fair. Get up after 0.8 s on the ground, and you can't be hit for 0.3 s after you're up. Enemies with attack tokens get one free swing at you while you're down; the rest wait.
- **Sprint attacks don't trigger collisions.** From the attack press until the end of its active frames, your body ignores the target, and the lunge stops 0.9 m short. So a sprint attack never knocks you down, even at base level. Only running into someone *without* attacking risks the fall.

## Strikes and body reactions

This is the core of the brand: physics bodies reacting to punches and kicks. Sifu decides how readable and fast it is. Our ragdolls decide how it looks.

### One power number decides the reaction

Every hit computes a **power score P**. The reaction tier comes from P, not from which move was used. That is how "no signature moves" works: any strike can launch, break a wall or take a limb if it carries enough power.

`P = base × charge_mult + speed_bonus + counter_bonus + finisher_bonus`

| Input | Values |
| --- | --- |
| base | jab 1.0, cross 2.0, kick 2.5, sweep 1.5, knee or elbow 1.5, ground strike 1.0 |
| charge\_mult | tap 1.0, level 1 (held 0.3 s) 1.6, level 2 (0.6 s) 2.3, level 3 (1.0 s) 3.2 |
| speed\_bonus | `1.5 × max(0, v − 6)`, where v is your real speed toward the target in m/s. Count v as the cap once it reaches 98% of the cap. That gives 3.0 at the base cap of 8 m/s, 6.0 at 10 m/s and 9.0 at 12 m/s, so speed upgrades hit harder. |
| counter\_bonus | +2.5 after a parry, +3 after a teleport. It lasts 1.5 s of real time, or until your next hit lands. |
| finisher\_bonus | +1 on the third hit of a tap string |

Tiers use half-open bands, so a value on a boundary goes to the higher tier:

| P | Tier |
| --- | --- |
| 0 to under 2 | Flinch |
| 2 to under 3.5 | Stagger |
| 3.5 to under 5 | Knockdown |
| 5 to under 7 | Launch |
| 7 to under 9 | Hard launch (flat and fast, breaks walls) |
| 9 or more | Severing launch (the hit limb comes off) |

**Sweep is the exception.** It reads the leg instead of the body: under 3.5 it is a stumble, 3.5 to under 5 a knockdown (trip), and 5 or more it upends them into a launch.

**Worked examples** (base speed cap 8 m/s unless noted):

| Hit | P | Tier |
| --- | --- | --- |
| Standing jab | 1.0 | Flinch |
| Standing cross | 2.0 | Stagger |
| Jab right after a parry | 3.5 | Knockdown |
| Jab at full sprint | 4.0 | Knockdown |
| Cross at full sprint | 5.0 | Launch |
| Tapped kick after a teleport | 5.5 | Launch |
| Standing cross, charge level 3 | 6.4 | Launch |
| Standing kick, charge level 3 | 8.0 | Hard launch |
| Kick at charge level 2 while sprinting | 8.75 | Hard launch |
| Kick at charge level 2 after a teleport | 8.75 | Hard launch (0.6 s charge + 0.2 s startup fits in the 1.5 s window) |
| Kick at charge level 3 while sprinting | 11.0 | Severing launch |
| Tapped kick at an upgraded 12 m/s | 11.5 | Severing launch (late-game power) |

### Launch speed and walls

- Launch speed `v = clamp(6 + 2 × (P − 5), 6, 18)` m/s.
- Launch angle: 30° up for P under 7. For P 7 or more, 18°: a flat, fast flight like Sifu 1 at 7.75 s.
- Whether a wall breaks is still decided by E = ½Mv² using the speed straight into the wall. A heavy (110 kg) launches at 80% of v.

What a 70 kg body does to a wall it hits straight on:

| P | v | Energy into the wall | Result |
| --- | --- | --- | --- |
| 5 | 6 m/s at 30° | 945 J | Cracks drywall |
| 6.4 | 8.8 m/s at 30° | 2,033 J | Breaks drywall, just |
| 7 | 10 m/s at 18° | 3,166 J | Breaks drywall, cracks brick |
| 8 | 12 m/s at 18° | 4,559 J | Breaks drywall, cracks brick |
| 9 | 14 m/s at 18° | 6,205 J | Breaks brick |
| 11 or more | 18 m/s at 18° | 10,257 J | Breaks brick, cracks concrete |

Concrete never breaks in one hit. A crack lowers its threshold by half the hit's energy, so a second 18 m/s body on cracked concrete (15,000 − 5,128 = 9,872 J) breaks it. That makes concrete a two-hit payoff.

### Not a one-launch kill

Launch damage is `10 + 3 × (P − 5)`, capped at 35% of the victim's max health. Strike damage and wall damage add to it (see "Health, damage and enemies"). A full-health grunt survives any single launch that doesn't hit a wall, gets up and comes back.

### Charging is the risk

- **Charging while walking:** you move at 50% speed. A hit knocks you out of the charge.
- **Charging while sprinting:** you keep your current speed, but you can steer only 30° per second and can't stop. A hit knocks you out of the charge and you stumble.
- Charge levels count in real time, so they don't stretch during slow motion.

### Sprint strikes

A sprint strike gets the speed bonus for free. So it must cost something, or tapping at full sprint becomes the best move every time.

- **Any strike thrown during a sprint, hit or miss, drops you to walking speed.** You have to build speed again for the next one.
- A missed sprint strike adds 8 frames of recovery.
- **From the attack press until the end of its active frames, your body ignores collisions with the target**, so the strike lands before you can run into them. The attack lunges and stops 0.9 m from the target.
- Enemies more than 4 m away who see a sprint attack coming sidestep it 30% of the time. Heavies never sidestep.

### Wind-up, contact, recovery

Sifu's strikes come out fast. The power comes from what happens on contact, not from long wind-ups.

| Move | Startup | Active | Recovery (on miss) |
| --- | --- | --- | --- |
| Jab | 5 frames | 3 | 10 |
| Cross | 9 | 4 | 16 |
| Kick | 12 | 4 | 22 |
| Sweep | 10 | 5 | 20 |
| Knee or elbow | 7 | 3 | 14 |

A frame is 1/60 s of that fighter's own time, not a 120 Hz physics tick. Recovery is cut by 40% if the hit lands, so strings flow.

**Contact frame.** On the frame the hit lands:

1. **Hitstop on the attacker and victim only**, while other enemies keep moving. The victim freezes for flinch 40 ms, stagger 60, knockdown 80, launch 110, hard launch 150, severing launch 180. **The player never freezes for more than 60 ms.** Block and Dash pressed during the freeze are buffered and fire when it ends.
2. **The victim mesh jitters** 2–4 cm during the freeze.
3. **A flash at the contact point:** a white radial burst sized by tier. From launch up, add a circular shock ring.
4. **Blood** from `BloodFX`: none on flinch, a small spray on stagger, more from knockdown up.
5. **Then the reaction starts.** The ragdoll takes each bone's velocity from the last two animated poses. Cache them before the freeze, because a frozen animation gives zero velocity.

A wall break has its own freeze at the moment of wall contact. Only the flying body freezes, for 150 ms, and the wall-break slow motion runs alongside it.

### Partial ragdoll reactions

Each tier says which bones go physical and how long they stay that way.

| Tier | Physical bones | Strength | Body motion | Recovery |
| --- | --- | --- | --- | --- |
| Flinch | The hit chain only: head and neck, or one arm, or the upper spine | 60% physics, fading to 0 over 0.25 s | impulse at the hit bone, no step | Attack interrupted. Can act again after 0.3 s. |
| Stumble (sweep) | The hit leg from the knee down | 50% for 0.3 s | 2–3 stumble steps sideways | Can act again after 0.6 s |
| Stagger | Spine and up, both arms | 80% fading to 0 over 0.6 s | pushed back 0.6–1.0 m with stumble steps; legs stay animated | Can act again after 0.8 s |
| Knockdown | Full body | full, low muscle tone | drops in place, little travel | 1.2–2.0 s on the ground, then gets up |
| Launch and hard launch | Full body | full, very low tone, limb spin | flies at the launch speed | 1.5–2.5 s on the ground, then gets up |
| Severing launch | Full body; the hit limb detaches at the joint | full | as a launch; the limb flies on its own | gets up and flees, or dies if health is 0 |

- **Pick the hit chain from the hurtbox that was hit.** A jab to the head snaps the head back; a jab to the body bends the spine.
- **Push in the strike direction,** not just "away from the player". A hook turns the head sideways.
- Keep the stagger legs animated so the enemy stays upright. That's the difference between a stagger and a knockdown.
- In code, "strength" is per-bone muscle strength in the existing torque controller, not the simulator's influence value. See "Godot implementation notes".

### Hitting bodies that are down

Sifu finishes enemies on the ground (Sifu 1 at 8.25 s, Sifu 2 at 3.6 s). Attacking near a body on the ground does a **ground strike** (a stomp or knee drop). It applies a small impulse to the nearest bone, deals damage and adds a blood spray. It never launches.

### Bodies stay

Dead bodies freeze after 4 s at rest and stay for the whole round, up to 20. After that, the oldest fades out. They sit on their own collision layer that walking capsules ignore, so fighters don't jitter over piles. Your feet have an `Area3D` that gives a body a nudge when you walk through it. Dead bodies can be grabbed and thrown.

### What we deliberately don't take

Sifu's balance bar (Sifu 1 from 3.25 s). You asked to keep the structure simple. Stagger and knockdown come from the power number, not from a bar.

## Grab spec: grabbing on the move, holding, throwing

Sifu 2 turns grabs into crowd control: bodies are thrown into other bodies. Prototype 1 shows a held body coming with you while you run and jump. We want both.

### Getting the grab

| Situation | Reach | What happens |
| --- | --- | --- |
| Standing or walking | 1.4 m in front | A 6-frame grab. Whiffs if nobody is there. |
| Sprinting | 2.0 m, with a short lunge | The grab keeps 60% of your speed, so the victim is dragged backwards on contact. It counts as a sprint strike: you drop to walking speed afterwards. |
| Enemy staggered or stumbling | 1.4 m | Always succeeds. |
| Enemy neutral | 1.4 m | The enemy can break it: if they press grab within 10 frames, both are pushed apart 1.5 m. This is the grab break, the same window you have against them. |
| Enemy ragdolling (flying or on the ground) | 1.4 m | You grab the nearest bone. Their ragdoll turns into the held state. |
| Dead body | 1.4 m | You pick it up and can carry and throw it like a live one. |
| No body in reach but a loose prop is | 1.4 m | You pick up the prop. |

- **Pick the target body part from the stick direction** (as in Upgrade Spec 2, https://claude.ai/artifact/6rz5gUcFCEmdEnwsTfs194): up = collar, sideways = arm, down = leg. The part decides the hold and throw variants below.
- On a neutral enemy with no break, the grab connects and a 50 ms hitstop plays.

### Holding

**The victim is a partial ragdoll while held.** Pin the victim's chest bone (or the grabbed limb) to the player's hand with a strong target-velocity motor (not a hard joint, which snags on walls), and turn off collisions between the held body and the player. The legs and free arm are physical with low muscle tone, so they dangle and swing as you move. This is what Prototype 1 shows from 0 to 6 s.

- **Moving while holding:** walk at 70% speed, sprint at up to 80% of the cap, jump at full height. The body comes with you through jumps and vaults (vault height limit drops to 1.0 m).
- **Struggle-out:** the hold lasts up to 2.5 s. After that, the victim breaks free with a shove (both stumble).
- **Others don't wait:** enemies with attack tokens can still hit you, and a hit makes you drop the body.

### Actions while holding

Prototype 1 shows three prompts while holding. We use five actions, all on buttons you already use.

| Input | Action | Result |
| --- | --- | --- |
| Light on the ground (up to 3) | Knee or headbutt to the held body | flinch-tier hit each, small blood, keeps the hold |
| Heavy, tap | Throw along the stick | body leaves at 6 m/s plus half your run speed |
| Heavy, hold | Charged throw | 6 / 9 / 12 m/s at charge levels 1 / 2 / 3, plus half your run speed, capped at 16 m/s |
| Light or Heavy in the air | Body slam | You land on top of the body. The victim is knocked down and you get a heavy-landing shockwave. |
| Grab | Release | drops the body, which stumbles |

Variants by grabbed part (optional, same inputs): an arm grab makes the throw a twisting throw that spins the body; a leg grab makes the heavy throw a sweep that trips them in place.

### Thrown bodies are projectiles

This is the main payoff (Sifu 2 at 7.1–7.45 s).

- A thrown body is a projectile while its pelvis moves faster than 4 m/s. Detect hits with an `Area3D` on the pelvis and chest bones.
- When it hits another enemy: under 6 m/s is a stagger, 6–10 m/s a knockdown, 10 m/s or more a launch. The thrown body loses 40% of its speed per hit and keeps tumbling. A 16 m/s throw goes launch → knockdown (9.6 m/s) → stagger (5.8 m/s). That's the bowling moment.
- A body hitting a wall uses the same E = ½Mv² check as a launch. **Throws are no stronger than strikes:**
  - tapped standing throw, 6 m/s: 1,260 J, cracks drywall
  - charged standing throw at level 3, 12 m/s: 5,040 J, breaks drywall and cracks brick
  - charged throw at full sprint, 16 m/s: 8,960 J, breaks brick
- The thrown body takes wall-impact damage like a launched one.

### Props

Sifu 2 opens by throwing a brick (0.1–1.5 s). Scatter a few throwable props in the arena: bricks, bottles, chair legs, small crates.

- Pick up with Grab when no body is in reach. You can pick up while sprinting with no slowdown.
- Throw with Heavy. A prop hit is a stagger and 8 damage. Only a brick to the head knocks down.
- The prop breaks on impact with a dust or shard burst. Bricks and crates can use `DebrisManager`.
- Props respawn at their start points after 20 s so the arena never runs out. A stick dropped by a stick enemy is a prop too.

## Defence and time: parry, teleport, Focus

Your decisions: tap Block to parry, press Dash in the same window to teleport, and the teleport costs Focus. Slow time stays. This section makes those exact.

### Enemies have to be readable first

You can only parry what you can see coming.

- **The attacking limb glows orange** from the start of the wind-up until its first active frame (Sifu 1 at 4.75 s shows a glow; we use it on every strike). **Enemy grabs glow blue on both hands** instead, because grabs can't be parried. The glow is never dimmed by the Focus-mode colour change.
- **Enemy startup is never under 18 frames** (0.3 s) early in a run. Later enemies go down to 12.
- **Attack tokens:** at most 2 enemies attack at once (Sifu 1 at 0.25 s, Sifu 3 at 5–30 s). The rest circle at 3–5 m. `AttackDirector` also keeps the two token holders' first active frames at least 20 frames apart, so two hits never land in one parry window by design.
- **Off-screen attackers:** if a token holder starts a wind-up off screen, show an arrow at the screen edge pointing to it.
- Enemies are alive: they dodge sprint attacks, block some tapped strikes, recover from launches and come back.

### Parry: tap Block

| Rule | Value |
| --- | --- |
| Window | A Block press within 8 frames (133 ms) before the first active frame of an attack aimed at you |
| Several attacks | One parry covers every attack whose first active frame falls inside that window |
| Success | The attacker is staggered. Both freeze for 60 ms with a white flash. Time drops to 0.5× for 0.15 s. |
| Reward | +2.5 counter bonus on your next hit within 1.5 s, and +0.34 Focus |
| Holding Block through the window | A normal guard: 80% less damage, and heavy hits push you back 0.5 m. No parry. |
| A tap with no attack in its window | Parry is locked for 20 frames (anti-mash). Holding still guards. |
| Enemy grabs | Can't be parried. Break them with Grab in the 10-frame window, or teleport. |

### Teleport: Dash in the same window

| Rule | Value |
| --- | --- |
| Trigger | A fresh Dash press (not a held one) within the same 8 frames before an attack or grab aimed at you |
| Cost | 1 Focus bar. With less than a full bar, it is a 1.5 m sidestep instead. |
| Which attacker | The one whose hit lands soonest |
| Where you appear | Test a capsule 1.2 m behind the attacker, then 0.9 m behind, then 1.2 m to each side. Use the first that fits. If none fits, sidestep and refund the Focus. |
| Effect | You vanish, leaving a fading after-image, and appear facing the attacker's back. The attack misses. |
| Time | 0.3× for 0.25 s from the vanish. This never waits on the slow-motion cooldown. |
| Reward | +3 counter bonus on your next hit within 1.5 s. A tapped kick out of a teleport launches (P 5.5). |

### Pursuit after a launch

| Rule | Value |
| --- | --- |
| Trigger | A fresh Dash press within 0.5 s of real time after a launch's hitstop ends, with the stick neutral or pointing within 60° of the flying body. Pointing away starts a sprint instead. |
| Cost | 1 Focus. At most 2 pursuits chain off one launch. |
| Position | You appear 1.2 m from the body and hang in the air for up to 0.25 s, waiting for your attack |
| The hit | Any attack. It is not a dropping strike. It always relaunches the body at `max(its current speed, v(P + 3))` in the strike direction, so the stick decides where it flies next. |

### What Dash does, in one place

| Input | Result |
| --- | --- |
| Fresh press while an attack or grab aimed at you is inside the 8-frame window | Teleport (1 Focus), or a sidestep without Focus |
| Fresh press within 0.5 s after your launch, stick toward the body or neutral | Pursuit (1 Focus) |
| Any other tap | A short dash, 3 m |
| Held for more than 150 ms | Sprint |

Sprinting can't spend Focus by accident: the teleport needs an attack inside a 133 ms window, and pursuit needs the stick pointed at the body.

### Focus

| Rule | Value |
| --- | --- |
| Bars | 3. Each wave starts with 1. |
| Refill | Parry +0.34, stagger or knockdown hit +0.1, launch +0.25, wall break +0.5. **Nothing over time, and nothing during Focus mode.** |
| What one bar costs you | 3 parries, or 4 launches, or 10 stagger hits |
| Spend | Teleport 1, pursuit 1, Focus mode 1 |
| Focus mode | LB / L1, or F on keyboard. The world runs at 0.3× for 2.0 s of real time while you move at normal speed. |

### Time, in code

- **One owner.** All slow motion goes through `TimeDirector`, which sets `Engine.time_scale`. Only the strongest active request wins; requests don't stack.
- **Each fighter also has its own time value** (`actor_time`, normally 1). Hitstop sets it to 0 for the attacker and victim. Drive every `AnimationTree` in manual process mode and call `advance(delta × actor_time)`, and skip movement while it is 0. A body that is already ragdolling stores its bone velocities, has gravity turned off for the freeze, then gets them back.
- **The player during slow motion:** `player_time_factor = 1 / Engine.time_scale`. Multiply the player's velocity by it, accelerations (gravity, sprint ramp) by its square, and the player's animation advance by it. Player timers run in real time: coyote time, jump buffer, charge levels, counter-bonus window, parry window. Use `create_timer(dur, true, false, true)` or tick counts.
- **Collisions during slow motion.** When the player's velocity is scaled up, any impulse the player gives a ragdoll must use the real speed (velocity × time\_scale), or every hit in Focus mode is 3.3× too strong.
- **Enemy frame data** counts in their own scaled time, so enemies really do attack slowly in Focus mode.
- **Audio.** `AudioServer.playback_speed_scale` follows the time scale for the world. As far as I know it is global, so compensate the player's own sound players with `pitch_scale = 1 / time_scale`. Check this in F0.

### Slow-time table

| Event | Scale | Length (real time) |
| --- | --- | --- |
| Parry | 0.5× | 0.15 s, easing back over 0.08 s |
| Teleport | 0.3× | 0.25 s (ignores the cooldown) |
| Wall break | 0.25× | 0.35 s |
| Limb comes off | 0.3× | 0.4 s |
| Last enemy of a wave killed | 0.2× | 1.0 s, with the close-up camera |
| Player death | 0.3× | 1.0 s |
| Focus mode | 0.3× | 2.0 s |

Ease back to 1.0 over 0.15 s unless the table says otherwise. Apart from the teleport, the last kill, player death and Focus mode, leave a 1 s cooldown between slow-motion events so it stays special.

## Effects that sell power

Two rules from the clips. **Effect size follows one number:** the hit tier for strikes, `sprint_charge` for movement. **Nothing is on or off:** blur, field of view and trails all ramp. Prototype 2 shows this clearly: mild blur at 7 s, strong blur at 24–28 s.

### Camera

| Situation | Behaviour | Clip |
| --- | --- | --- |
| Many enemies up | Distance 7–9 m, 2.5 m higher, frames the player and the nearest 3 enemies | Sifu 3, 5–30 s |
| One or two enemies left | Distance 4–5 m, low over the shoulder | Sifu 3, from 30.9 s |
| Sprint | Field of view 70° → 78° (up to 85° at upgraded caps), distance +1.5 m, 0.3 m lower, all by `sprint_charge` | Prototype 2, 13–19 s; Prototype 4, 3.5–8.5 s |
| Wall run | Shift 1.5 m toward the open side. Leave the runnable wall out of the spring arm's collision check so the camera doesn't snap in. |  |
| Falling more than 3 m | Roll the camera up to 8° and pitch down to show the ground | Prototype 1, 13.2–17.7 s |
| Launch | Pull back up to 9 m so the player and the flying body both fit. The look-at moves toward the body for at most 1.0 s, and yaw changes at most 60° per second. **The player always stays in frame.** | fixes the "weird views" from your build notes |
| Last enemy of a wave killed | Cut to a close side angle at 2.5 m, 0.2× time for 1.0 s, then ease back | Sifu 1, 17.65–18.45 s |
| Player death | Slow orbit around the player's ragdoll at 3 m during the 1.0 s of slow motion |  |

**Camera shake** uses trauma (shake = trauma², decays by 1.5 per second). Add trauma by tier: flinch 0.05, stagger 0.1, knockdown 0.2, launch 0.3, wall break 0.5, heavy landing 0.4, limb comes off 0.45. The camera ignores ragdolls and debris when checking for walls, so a body flying past never pushes the camera in.

### Screen effects

- **Radial speed blur:** a full-screen shader centred slightly above the screen middle. Strength = `sprint_charge`² × 0.6, so it only gets strong near the top. Also during air dashes and pursuit teleports.
- **Speed lines:** thin white streaks at the screen edges once `sprint_charge` passes 0.8. Keep them subtle.
- **Focus tint:** during Focus mode, desaturate the world to 40% and push a cool tint. The player, enemy wind-up glows and off-screen attack arrows stay in full colour. Prototype 4 does something similar at 9.5–10.5 s with a full-screen colour shift and a glow on the character. Add a thin rim glow on the player.
- **Hit flash:** on launch tier and above, flash the screen white at 15% for 2 frames.

### On the character

- **Trails** on both hands and feet when `sprint_charge` is above 0.6: a ribbon 0.4–1.2 m long, longer with speed, fading over 0.15 s. Use a single colour you pick for the brand. Prototype uses red.
- **Strike trails** on the striking limb during the active frames of any charged attack (level 1 and up).
- **After-image** on teleport: a copy of the player mesh at the vanish point, fading over 0.2 s.
- **Charge glow:** while holding an attack, the limb glows brighter at each charge level, with a short pulse and sound at each level-up.

### On the world

| Event | Effect | Clip |
| --- | --- | --- |
| Every footstep while sprinting | a small puff; water spray on wet ground; sparks on metal | Prototype 4, 20.5 s |
| Sprint start | a dust kick behind the feet | Prototype 2 |
| Landings | the three levels in the movement section | Prototype 3, 10.7 s and 15.2 s |
| Hit contact | radial flash, plus a shock ring from launch up | Sifu 1, 3.75 s and 12.75 s |
| Body hits the floor hard | dust puff, blood decal if wounded | Sifu 1, 7.75 s |
| Body breaks furniture | furniture breaks, pieces stay | Sifu 3, 33.3–35.7 s |
| Body hits a wall | crack decal, or a wall break with debris | existing impact resolver |
| Water | ripple rings from bodies and feet | Sifu 2, 3.6–5.35 s |

**Things stay.** Bodies (up to 20), broken furniture, wall holes, blood decals and debris all stay for the round. Freeze debris after 4 s. Sifu 3 and Prototype 4 both show the fight piling up around you, and that is a big part of feeling powerful.

### Sound

- A wind loop that rises in volume and pitch with `sprint_charge`.
- Impact sounds layered by tier: a slap for flinch, a thud for stagger and up, and a deep boom for launch and wall break.
- A whoosh on every strike, longer for charged ones.
- During slow motion, lower the pitch of everything except the player's own impacts, using `AudioServer.playback_speed_scale` plus a separate player bus.

### Budget

At most 1 shock ring and 1 screen flash per 0.2 s, at most 150 live debris chunks, and at most 30 live blood decals before the oldest fades. Effects are tied to `GameEvents` signals, so each effect script listens rather than being called from combat code.

## Controls and targeting

If the existing `Controls` autoload binds things differently, change it to match this table.

| Action | Controller | Keyboard and mouse | Notes |
| --- | --- | --- | --- |
| Move | Left stick | WASD |  |
| Camera | Right stick | Mouse |  |
| Jump | A / Cross | Space |  |
| Light (jab) | X / Square | Left mouse | Tap or hold to charge (150 ms tap/hold rule) |
| Heavy (cross) | Y / Triangle | Right mouse | Tap or hold to charge |
| Kick | B / Circle | E | Tap or hold to charge |
| Sweep | Pull back + Kick | S + E | "Back" is toward the camera |
| Block | RB / R1 | Q | Tap to parry, hold to guard |
| Dash and sprint | RT / R2 | Left Shift | See "What Dash does, in one place" |
| Grab | LT / L2 | G | Grab, grab break, release |
| Focus mode | LB / L1 | F |  |
| Crouch | Right stick click / R3 | C | From Upgrade Spec 2 |

Knees and elbows come out of combo strings (Upgrade Spec 2's combo graph), not from their own buttons. While holding a body: Light on the ground is a knee, Heavy throws, any attack in the air slams, and Grab releases.

### Picking the target

When you press an attack:

1. Collect enemies inside a 60° cone around the stick direction (camera forward if the stick is neutral), within 4 m, or 10 m while sprinting.
2. Score each one: `0.6 × (1 − angle / 60°) + 0.4 × (1 − distance / range)`. The highest score wins.
3. Turn to face it and lunge up to 1.0 m (a sprint lunge stops 0.9 m short). With no target, strike along the stick.

The same target drives the speed bonus direction, the small corner-bracket marker shown while sprinting (Prototype 2 at 1.9 s and 16.3 s), and the camera's launch framing. Bodies on the ground are targets only for ground strikes.

## Health, damage and enemies

All of these are starting values for `tuning.gd`. If Waves mode already has numbers for these, replace them with these.

### Health and damage

| Item | Value |
| --- | --- |
| Health | Player 100, grunt 100, stick enemy 100, heavy 160 |
| Strike damage | jab 4, cross 8, kick 10, sweep 5, knee or elbow 6, ground strike 6, each multiplied by charge\_mult |
| Launch damage | `10 + 3 × (P − 5)` for launches, capped at 35% of the victim's max health |
| Wall damage | crack +5, drywall break +10, brick break +20, concrete break +30 |
| Limb lost | +25 |
| Thrown body hitting an enemy | 5 (stagger), 10 (knockdown), 15 (launch) |
| Prop hit | 8 |
| Enemy hits on the player | grunt punch 10, grunt kick 15, stick swing 15, heavy smash 20, being grab-thrown 15 |
| Guarding | 80% less damage |
| Between waves | The player gets 25 health back. No health regen during a wave. |

Check on "not a one-launch kill": the worst single hit with no wall is a level-3 kick that also takes a limb: 32 strike damage + 35 launch damage (the cap) + 25 for the limb = 92. A full-health grunt survives it, barely. A wall impact on top can kill.

### Enemy types

| Type | Mass | Health | Attacks (startup frames) | Behaviour |
| --- | --- | --- | --- | --- |
| Grunt | 75 kg | 100 | jab-cross (18, 22), front kick (24), grab (20, blue glow) | Circles and takes tokens. Sidesteps a sprint attack it sees from more than 4 m away 30% of the time. Guards 15% of tapped strikes. |
| Stick enemy | 75 kg | 100 | swing (20), thrust (24), reach 2.2 m | Keeps about 3 m away. A stagger or more makes him drop the stick, which becomes a prop. |
| Heavy | 110 kg | 160 | overhead smash (30), shoulder charge (28), grab and slam (26, blue glow) | Never sidesteps. Ignores flinches: only a stagger or more interrupts him. Launches at 80% speed. The charge knocks you down unless parried or teleported. |

From wave 5, enemy startup times shrink by 2 frames per wave down to 12.

**Starting wave mix:** wave 1 is 3 grunts; wave 2, 5 grunts; wave 3, 4 grunts and a stick enemy; wave 4, 4 grunts and a heavy. After that, add one enemy per wave, with at most 8 alive at once.

### What enemies can do to you

- Punches and kicks flinch or stagger you, using the same partial ragdoll system.
- A heavy's shoulder charge or any enemy grab-throw knocks you down. You get up after 0.8 s and can't be hit for 0.3 s after.
- Enemies never launch you or take your limbs. That may change with later enemy types.
- **At 0 health you die.** Full ragdoll, 0.3× slow motion for 1.0 s with the death camera, then the run ends with a results screen. In Duel mode the round is lost.

### Enemies who lose a limb

- **Lost an arm:** above 40 health, keeps fighting one-handed at half damage. At 40 or below, limps away.
- **Lost a leg:** crawls away at 0.8 m/s and can't attack.
- Either way, a ground strike finishes them. They don't take attack tokens while fleeing.

## Dismemberment and assets

If the original spec's dismemberment section says something different, this one wins.

### How a limb comes off

1. **Prepare the meshes in Blender.** Split each arm (upper arm to hand) and each leg (thigh to foot) into its own mesh on the same skeleton. Add a hidden wound cap at each shoulder, hip, elbow and knee. Use joints only; no heads for now.
2. **On a severing launch,** hide the limb mesh on the body and show the wound cap at the stump.
3. **Spawn the loose limb** as its own small physics body, using the limb mesh at the bone's position, with that bone's velocity.
4. **Turn off the cut bones** on the body's ragdoll so they stop pulling.
5. **Spray blood** from the stump for 1.5 s and leave a decal where the limb lands.

Which limb comes off: the one on the hit hurtbox chain. A head or torso hit takes the nearest arm. Loose limbs persist like bodies, up to 12, and can be picked up as props.

### New animations needed

Try Mixamo first. Make the rest in Blender.

| Group | Animations |
| --- | --- |
| Strikes | knee, elbow, stomp or knee drop (ground strike), a charge-hold pose for each strike |
| Movement | sprint start, speed vault, mantle, wall kick-off, wall run left and right, three-point landing, landing roll, crouch landing |
| Grab | grab lunge, hold idle, carry walk and run, knee to held body, headbutt, throw, charged throw wind-up, body slam |
| Defence | parry deflect, guard push-back, sidestep, teleport vanish and appear poses |
| Reactions | stumble steps (forward, back, sideways), fast player get-up |
| Enemies | grunt jab-cross, front kick, grab, sidestep, guard, circle-strafe; stick swing and thrust; heavy smash, shoulder charge, grab and slam; crawl and limp (limb lost) |

## Godot implementation notes

These are the places where the obvious approach may not work. Items I'm not certain of are marked; check them in F0.

- **Per-chain partial ragdolls.** As far as I know, `PhysicalBoneSimulator3D`'s influence is one value for every simulated bone, so it can't fade one arm. Simulate the whole body during a reaction and use the per-bone muscle strength from the existing torque controller: bones outside the hit chain track the animation at full strength. *Check.*
- **Bone velocities at the reaction.** There's no built-in "inherit animation velocity". Work it out per bone from the last two animated poses, and cache those before the hitstop freeze.
- **Body mass.** `PhysicalBone3D` mass defaults to 1 kg, so a ragdoll may weigh far less than intended. Set each bone's mass from standard human segment fractions (for example Winter's tables) so bodies total 70 kg (player), 75 kg (grunt and stick enemy) and 110 kg (heavy).
- **Held bodies.** Drive the held bone toward the hand with a target-velocity motor rather than a hard joint, and turn off collisions between the held body and the player.
- **Thrown-body hits.** Contact reporting on `PhysicalBone3D` is still unverified, so use an `Area3D` on the pelvis and chest bones.
- **Speed and tunnelling.** At 120 Hz an 18 m/s body moves 0.15 m per tick, and wall panels are 0.25 m thick. Keep the original spec's predictive sweep ahead of flying bodies, and cap every body at 18 m/s, throws included.
- **Per-fighter time and Focus mode:** see "Time, in code" in the defence section.
- **Bodies on the floor.** Put dead bodies on a collision layer that walking capsules ignore. Enemy navigation treats them as walkable.
- **Performance.** So far only 2 ragdolls plus 150 debris chunks have been profiled. This doc needs about 8 live enemies, 20 dead bodies and 150 chunks at once. F0 profiles that before any new feature is built.

## Build tasks for Claude Code

Give these to Claude Code in order, one per session. **Don't remove or replace the ragdoll system in any task.** Everything here is built on top of it. All numbers go in `tuning.gd`.

Every check is something Claude Code can test with a log, a scripted bot or a test scene in Ragdoll Lab. The feel check at the end is the one only you can do.

### F0: Foundations and a performance test

Build the plumbing everything else needs: per-fighter time and hitstop freezing, `player_time_factor`, the `TimeDirector` slow-time table, the input map, target picking, health, damage and enemy stats, ragdoll bone masses, and the dead-body collision layer. Add a debug overlay (P, tier, speed, Focus, health) and debug settings (speed cap, Battering Ram level, starting Focus).

- [ ] With 8 live enemies, 20 dead bodies and 150 debris chunks in the Waves arena, physics averages 8 ms or less per frame and never passes 12 ms over 60 s at 120 Hz, per the profiler log.
- [ ] In Focus mode, the player covers the same distance per real second as at normal speed, within 5%.
- [ ] During a 110 ms hitstop on two fighters, a third enemy's logged position keeps changing.
- [ ] Logged ragdoll masses total 70, 75 and 110 kg, within 1 kg.
- [ ] Every action in the controls table fires from both controller and keyboard, and no two actions share a binding except the listed combinations.
- [ ] In Ragdoll Lab, one arm can go limp while the rest of the body follows its animation.

### F1: Launch camera

Fix the launch camera before adding more launches: pull back up to 9 m, follow for at most 1.0 s, turn at most 60° per second, and always keep the player in frame.

- [ ] In a scripted test of 50 launches in random directions, the player is inside the viewport on every frame.

### F2: Sprint that builds

Add `sprint_charge`, the speed ramp, the turn penalty, charging while sprinting, the sprint-strike speed reset, and the speed effects: field of view, camera distance, radial blur, speed lines, limb trails and the wind sound.

- [ ] Holding Dash in a straight line reaches the cap in 1.2 s, give or take 0.1 s.
- [ ] A 90° turn inside 0.2 s at full speed logs a 30% speed drop.
- [ ] Logged blur strength is 0.15 at half charge and 0.6 at full.
- [ ] Charging during a sprint keeps speed within 5% and limits turning to 30° per second.
- [ ] Any sprint strike, hit or miss, logs your speed back at walking.

### F3: Power number and reactions

Add the power score P, the tiers, the sweep exception, launch speed and angle, launch damage, the per-tier partial ragdoll and the hit-chain choice.

- [ ] A scripted test runs every worked example and logs P and tier. All 12 match the table.
- [ ] Logged launch speed and angle match the formula at P 5, 7, 9 and 11.
- [ ] In Ragdoll Lab, launches into drywall, brick and concrete panels crack or break them as the wall table says, including concrete breaking on the second 18 m/s hit.
- [ ] A full-health grunt hit by a level-3 kick with no wall ends with health above 0 and gets up.
- [ ] A jab to the head lowers muscle strength only in the head and neck bones.

### F4: The contact frame

Add the hitstop on the attacker and victim, the 60 ms cap for the player, input buffering, mesh jitter, flash, shock ring, blood, shake and sound by tier, and the ragdoll taking the cached bone velocities. Wire it all through `GameEvents`.

- [ ] The flash, sound and blood spawn on the same physics frame as the hit event, per the log.
- [ ] The player's logged freeze never passes 60 ms, and a Block pressed during it fires afterwards.
- [ ] Each tier plays a different sound stream, per the log.

### F5: Readable enemies, parry and the enemy roster

Add the wind-up glows (orange for strikes, blue for grabs), the 2-token limit with spaced active frames, off-screen arrows, the parry and grab break, and the three enemy types with their attacks and behaviours.

- [ ] Glows start at least 18 frames before the first active frame in early waves.
- [ ] Over 5 minutes of Waves, never more than 2 token holders, and their first active frames are always 20 or more frames apart.
- [ ] A bot pressing Block inside the window parries all of 100 attacks. A press outside any window locks parry for 20 frames.
- [ ] A jab right after a parry logs P 3.5 and a knockdown.
- [ ] A staggered stick enemy drops his stick, and it can be picked up.

### F6: Teleport, pursuit and Focus

Add the teleport with its placement rules, pursuit, all Dash meanings, Focus refill and spending, starting Focus, and Focus mode.

- [ ] With 0 Focus, Dash in the window logs a sidestep and no Focus change.
- [ ] With a wall right behind the attacker, the teleport uses a side position, or sidesteps and refunds.
- [ ] A bot holding Dash to sprint through 100 enemy wind-ups never spends Focus.
- [ ] A pursuit hit relaunches at no less than `max(current speed, v(P + 3))`, and a third pursuit is refused.
- [ ] Focus gained during Focus mode is 0, and every wave starts with 1 bar.
- [ ] Two slow-motion requests at once: only the strongest applies.

### F7: Automatic parkour and landings

Add the obstacle probes, step, vault, mantle, mantle from the air, wall kick-off, the dropping strike out of a vault, the jump rules, the three landing levels and the slam shockwave. Add low walls, crates, the raised platform and pillars to The Yard.

- [ ] Sprinting into a 0.9 m wall vaults it with no input and keeps at least 90% of speed.
- [ ] Walking into the 1.8 m platform is blocked; sprinting into it mantles you up.
- [ ] Landing levels log as Soft for a normal jump, Hard for jumping off the platform, and Heavy for a slam off the platform. The slam stumbles a dummy 2 m away.
- [ ] Over 200 scripted landings, the player is never knocked down.
- [ ] An attack in the last 40% of a vault gives a dropping strike.

### F7b: Wall run

Add the wall run, the `runnable` tag, the kick-off, the wall-run strike, the camera shift and roll, and the wall dust. Add two runnable walls of 8 m or more to The Yard.

- [ ] Sprint plus Jump next to a runnable wall starts a wall run; walk plus Jump is a normal jump.
- [ ] A bot doing 200 sprint jabs along a wall starts 0 wall runs.
- [ ] A tapped kick at the end of a wall run logs P 5 or more and launches a dummy.
- [ ] A kick-off from the run reaches the top of the 1.8 m platform.
- [ ] A cracked panel can't be run on.

### F8: Running into enemies (Battering Ram)

Add sprint collisions at base level and the three upgrade levels, the player's short fall and get-up, the speed costs and the 50 ms hitstop. The level is a debug setting until the roguelike exists.

- [ ] At base level, running into a heavy knocks you down, and you can act again within 1.1 s.
- [ ] At base level, running into a grunt makes you both stumble.
- [ ] At level 3, a line of 3 grunts all get knocked down.
- [ ] Over 200 sprint attacks at base level, the player is knocked down 0 times.
- [ ] No collision at any level causes a launch.

### F9: Grabs, carrying and throwing

Add the sprint grab, grab break, grabbing ragdolling and dead bodies, the held partial ragdoll on a motor, moving and jumping while holding, the hold actions, thrown bodies as projectiles, and props.

- [ ] A held enemy's leg bones keep moving while you run, per logged angular velocity.
- [ ] A tapped standing throw only cracks drywall; a level-3 charged standing throw breaks it.
- [ ] A 16 m/s throw into 3 grunts in a line knocks down or launches at least 2.
- [ ] Grabbing a flying, a downed and a dead body all succeed.
- [ ] A thrown brick staggers and shatters.

### F10: Dismemberment

Prepare the split limb meshes and wound caps in Blender. Add severing, loose limbs, stump blood, and the limb-loss behaviours.

- [ ] A severing launch hides the limb, shows the wound cap, and spawns a loose limb moving at the bone's speed.
- [ ] An enemy who lost a leg crawls away, and a ground strike finishes him.
- [ ] Loose limbs never pass 12.

### F11: Camera, effects and the round's end

Add crowd framing, the one-on-one camera, the wall-run camera, the fall tilt, the last-kill close-up, the death camera and results screen, the remaining world effects, and the persistent bodies, props and decals.

- [ ] Logged camera distance follows the number of enemies alive.
- [ ] Over 20 waves, the last kill always plays the close-up.
- [ ] Player death plays the death camera and then the results screen.
- [ ] At the end of a wave, the logged count of bodies, broken props and decals matches what was created.

### Feel check after every task

Play three rounds and answer yes or no. Did I want to sprint at someone? Did a launch feel earned? Did I ever lose track of where I was? Did the bodies look physical, not canned? Did I want to play again?

## Open questions

1. **Trail and glow colour.** Not decided yet. For now F2 uses a single exported colour in `tuning.gd`, set to a neutral warm white, so changing it later is one value. Decide once the art direction is set.
2. **Aiming at body parts in Focus mode.** The Sifu 2 markers at 7.8 s are very likely Sifu's Focus attack: you hold a button, time slows, you aim at a body point with the stick, and a strong targeted attack knocks the enemy back. We could add the same thing to our Focus mode, so the limb you aim at is the one your next strong hit takes off. It's **not in any build task yet**; decide after F6 is playable.
3. **Numbers to watch in the first playtests:** enemy health, the wave mix, 25 health back between waves, and starting each wave with 1 Focus bar. These are my starting values, not your decisions.

## Sources

- Sifu 1, "Sifu combat is EXTREMELY sick!": https://www.youtube.com/shorts/XSHaBju7yuQ
- Sifu 2, "C-C-C-Combo": https://www.youtube.com/shorts/JnJDKzdCCsQ
- Sifu 3, "Sifu As Intended For 44 Seconds": https://www.youtube.com/watch?v=7hZSWtkYN\_c
- Prototype 1, Prototype 2 consume and carry clip: https://www.youtube.com/shorts/AUejJX4JRM4
- Prototype 2, maxed movement, jump and speed: https://www.youtube.com/watch?v=nhfZtIaQJe4
- Prototype 3, "\[Prototype\] These games parkour animations still hold up": https://www.youtube.com/watch?v=rbjGF338w9w
- Prototype 4, "Prototype 2 - James Heller Full Speed | With All Upgrades \[HD\]" (iGamingWEB): https://www.youtube.com/watch?v=R3-iqc2F-d0
- Ragdoll Brawler — Godot Game Spec: https://claude.ai/artifact/PCeTuYctuPu6f4Mtmyw9c1
- Ragdoll Brawler — Upgrade Spec 2: https://claude.ai/artifact/6rz5gUcFCEmdEnwsTfs194
