# Ragdoll Brawler — Upgrade Spec 2

Nov 1, 2026 · @Pahul

## Summary

This upgrade replaces the fixed button-per-move scheme with a tap-to-combo, hold-to-charge input model, then builds combos, crouch and jump, body-zone targeting, limb grabs and player-speed Focus on top of it. Fix the camera first: it is the cheapest change and every other upgrade is judged through it.

**Priority order**

1. Camera: stop following thrown bodies; fix odd views.
2. Input model: tap to combo, hold to charge any move, move while charging.
3. Crouch and jump, with high, mid and low attacks.
4. Combos: strings, cancels, juggles (sweep into front kick), damage scaling.
5. Body-zone targeting for strikes and grabs, including limb grabs.
6. Focus: the world slows, the player does not.
7. Roguelike direction: designed here, not built yet.

**What it builds on** (from your build overview): Godot 4.8.dev7, Jolt at 120 Hz, a procedural 16-bone mannequin, procedural keyframe poses, and the `Controls`, `TimeDirector`, `AttackDirector` and `ImpactResolver` autoloads. Existing moves: jab, power punch, kick, punt, sweep, grab and throw, dash, pursuit, block and perfect dodge. Two known gaps this upgrade fixes along the way: Cmd+Ctrl+F also triggers grab, and the player's guard covers all sides while enemies guard only their front.

**Evidence standard:** mechanics cite shipped games or engine docs. Numbers marked "tuning start" are mine, to be tuned in play; tune them in `tuning.gd`, not in module constants.

## Camera fixes

The camera never leaves the player during play: a thrown body is shown by widening the frame, not by following it, and walls between the camera and the player fade instead of pushing the camera in. Following thrown bodies moves to the kill-cam, where the player is not in control.

**Likely causes (I have not seen the code or footage, so confirm):** the original spec's follow-cam on launches over 10 m/s takes the camera away mid-fight; a sphere-cast spring arm snaps forward when walls, props or rubble pass behind the player; soft-target switches rotate the camera in large jumps. A clip of each odd view would confirm which.

**Evidence**

- Batman: Arkham Asylum keeps an offset camera while exploring and "zooms out and centers itself" in combat ([Game Developer](https://www.gamedeveloper.com/design/third-person-camera-view-in-games-a-record-of-the-most-common-problems-in-modern-games-solutions-taken-from-new-and-retro-games)).
- Same source: Assassin's Creed Syndicate's camera "often bounces off objects and walls", blamed on sphere colliders; The Witcher 3 dithers objects near the camera; For Honor lets the camera pass through geometry and marks it at the screen edge.
- Same source: a hybrid camera returns to its programmed position only after the player stops rotating it.
- John Nesky (Journey) on cameras: "Cameras are most noticeable when they fail" ([Game Developer](https://gamedeveloper.com/design/video-50-common-game-camera-mistakes----and-how-to-fix-them)).

**Rules (tuning starts)**

1. **No follow-cam in play.** When a launch or throw sends a body more than 6 m, pull back up to 2 m and widen the field of view by up to 8° to keep it in frame, for at most 1.2 s. If it leaves the frame anyway, let it go.
2. **Kill-cam gets the follow.** The final KO and "THROUGH 3+ WALLS" moments replay with a follow-cam after the action (the kill-cam from the original spec).
3. **Combat framing.** The frame holds the player and the soft target; the player sits slightly left of centre; the camera pulls back from 3.5 m to 7 m as token holders spread out.
4. **Fade, don't snap.** Breakable walls, props, rubble and ragdolls fade or dither when they block the view; they never move the camera. Only the concrete outer walls and pillars collide with the spring arm.
5. **Clamp the angles.** Pitch from −35° to +20°, minimum distance 2.2 m, so the camera never goes top-down or under the floor.
6. **Respect the mouse.** No auto-rotation within 1 s of the player moving the camera; then ease back behind the player over 0.5 s.
7. **Calm target switches.** At most one camera mode change per 0.75 s, each blended over 0.25 s. A soft-target change rotates at most 90° per second.
8. **While the player is down:** look at the pelvis with heavy lag; no orbit, no follow of anyone else.
9. **Debug overlay (F3):** show the camera mode, the target and what is blocking the view, so odd views can be captured and named.

## Input model: tap to combo, hold to charge

Every attack button works the same way: a tap plays the next move in the combo string, and holding the button charges that same move. Press once and you jab; press again and hold, and you charge the cross; hold on the first press and you charge the jab. Punches, kicks, sweeps and throws all charge.

**How a press is read (my design)**

1. Pressing starts the move's wind-up at once, so there is visible response on the first frame.
2. Released before the hold threshold (150 ms, tuning start) → the move fires as a normal strike. If the move's startup is shorter than the release time, the strike waits for the release; a quick 80 ms tap delays a 5-frame jab by about 1 frame.
3. Still held at 150 ms → the fighter freezes in the wind-up pose and charges. Release fires the charged version.
4. The hold threshold is the main feel setting. Too short and fast clicks turn into charges; too long and taps feel late. Tune it with you at the keyboard.

**Charge levels (tuning starts)**

| Held for | Level | Effect |
| --- | --- | --- |
| 0.15–0.4 s | 1 | ×1.4 damage; jabs and crosses stagger |
| 0.4–0.8 s | 2 | ×2 damage; any strike launches |
| 0.8 s and over | 3 | ×3 damage, glowing; breaks brick, counts as a finisher for dismemberment |
| Over 1.5 s | — | Auto-release at level 3, so a held button never locks the fighter |

A hit taken while charging cancels the charge; there is no armour. In a crowd that makes charging a risk the player chooses, which is what keeps it from being the default.

**Buffer and string timing (tuning starts):** a press during the last 10 frames of a move's recovery is stored and fires the next string move the moment it can. The string resets if nothing is pressed within 0.4 s after a move ends. God of War's designers describe this as the buffer method of cancelling, against the instant method that lets players delay their timing ([Game Developer](https://www.gamedeveloper.com/pc/combat-canceled-i-god-of-war-i-action-game-design)).

**Proposed key map (your call)**

| Action | Keyboard and mouse | Gamepad |
| --- | --- | --- |
| Punch (tap, hold) | Left click | X / Square |
| Kick (tap, hold) | Right click | Y / Triangle |
| Grab (tap, hold) | F | B / Circle |
| Jump | Space | A / Cross |
| Crouch (hold) | C or Ctrl | Left stick click |
| Block (hold), perfect dodge (tap) | Q | RB / R1 |
| Dash, pursuit | Shift | RT / R2 |
| Focus (hold) | E | LB / L1 |
| Sweep | Crouch + kick | Crouch + kick |

This frees right click for kicks and Space for jump. It moves block to Q, which is the biggest habit change; try it before committing. Move fullscreen off Cmd+Ctrl+F (or ignore F while Cmd is held) to fix the grab conflict.

**Where it lives:** an `InputInterpreter` in `Controls` turns presses into tap, hold and release events with timestamps; a `ComboGraph` resource (next section) decides which move a tap or hold means.

## Combos and new moves

Combos are short strings on the punch and kick buttons that branch into each other and into launchers, plus juggles: any kick or punch on a tumbling or airborne enemy is a juggle hit. Your sweep-into-front-kick is the signature juggle: a quick sweep makes the enemy stumble, and a front kick on a stumbling enemy knocks them off their feet and launches them flat toward the nearest wall. A fully charged sweep takes them off their feet on its own.

**Strings (tuning starts)**

| Input | Moves | Ender effect |
| --- | --- | --- |
| P, P, P | Jab, cross, hook | Hook staggers |
| P, P, forward + P | Jab, cross, uppercut | Launcher: lifts 1.5 m for a juggle |
| P, P, K | Jab, cross, front kick | Launch toward wall |
| K, K | Front kick, roundhouse | Roundhouse spins the target sideways |
| Crouch + K, then K | Sweep, front kick | Stumble, then off-balance launch, flat and fast |
| Uppercut, jump + K | Launcher, flying kick | Air juggle; dash for pursuit |
| Grab, P (up to 3) | Knees while holding | Then throw |
| Back + P (any point) | Spinning backfist | Hits the enemy behind you; crowd tool |

Holding any press charges that move (Input model), so P, hold P is a charged cross, and crouch, hold K is a charged sweep (see Sweep: stumble or trip).

&#91;embedded content: combo graph · starters and their branches\]

Every string starts from one of four starters (the spinning backfist, usable anywhere, is left out); the highlighted link is the sweep-into-front-kick juggle you asked for.

**Cancel rules**

1. **On hit,** a strike can cancel its recovery into the next move of its string, or into a different string, from the end of its active frames.
2. **On whiff,** no cancels: a missed string is punishable.
3. **Block and perfect dodge cancel any basic strike's wind-up.** In a crowd, the player must be able to abort an attack when a tell appears. God of War allows guard as a pre-hit cancel on basic attacks ([Game Developer](https://www.gamedeveloper.com/pc/combat-canceled-i-god-of-war-i-action-game-design)).
4. **Charged moves** cancel only into a perfect dodge. Same source: God of War gates its specials to post-hit cancels "for balance reasons (infinite lock down loops, mostly)".

**Juggles**

- A tumbling or airborne enemy takes juggle hits: ×1.3 launch, launch angle flattened toward the nearest wall.
- One trip per combo: a second sweep on an enemy already off their feet in the same combo only knocks them down. Tekken allows its tornado flip "once in any given combo" ([Hotspawn, Tekken 8](https://www.hotspawn.com/fgc/guide/tekken-8-beginner-series-how-to-juggle-combo)).
- Pursuit stays as built: dash teleports to a launched body for one follow-up; the third relaunch in one flight gets half the impulse.

**Sweep: stumble or trip (your call, tuning starts)**

| Sweep | Result on the enemy | What it sets up |
| --- | --- | --- |
| Tap | Stumble: 0.6 s off balance, one foot kicked out, cannot attack or block; stays on their feet | Any kick or charged punch in the window knocks them down with ×1.3 launch, flattened toward the nearest wall |
| Charge level 1–2 | Trip: off their feet, a 0.5 s tumble at hip height | Juggle hits; the front kick launch |
| Charge level 3 | Upward launch: 1.5 m into the air | Flying kick or pursuit in the air |

A stumble that is not followed up within 0.6 s recovers to standing. Armoured enemies (Brute) only stumble from a level 3 sweep.

**Damage scaling (anti-infinite)**

- Hits 1–2 do full damage, then each hit does 10% less, down to 50%. Street Fighter drops damage 10% per move; KOF drops 5% ([Dustloop](https://dustloop.com/w/User:Slimegirl-scientist/Infinite_Prevention_and_Combo_Mechanics)).
- Environment damage (walls, pillars, bodies) is never scaled. Tekken's wall enders reset scaling on their last hit ([Hotspawn](https://www.hotspawn.com/fgc/guide/tekken-8-beginner-series-how-to-juggle-combo)); here the wall is the ender.
- Enemy armour still absorbs jabs during kicks and heavies, so strings cannot run through an armoured attack.

**New moves to animate:** cross, hook, uppercut, roundhouse, spinning backfist, flying kick, hammer fist (jump + P), crouch punch, knee, and a crouch-walk, jump and land set. Each is a wind-up pose, a strike pose and a recovery pose in the current procedural system, plus a held charge pose for the chargeable ones.

**Where it lives:** a `ComboGraph` resource lists each move's string position, its links, its cancel windows and its charged variant, so new strings are data, not code.

## Crouch and jump

Every attack gets a height — high, mid or low — and the defence follows from it: crouch under highs, jump over lows, block mids. The enemy tell shows the height by which limb glows and where: a fist at head height, a fist or foot at the waist, a foot at the ankles (see New moves and effects from the clips).

**Evidence:** in Tekken, highs "miss entirely on crouching opponents", mids must be blocked standing, lows hit standing opponents and are blocked crouching, and crouching makes highs and most throws whiff ([Hotspawn, Tekken 8](https://www.hotspawn.com/tekken/guide/tekken-8-beginner-series-attacking-and-defending)). In Sifu, ducking or jumping over strikes avoids damage and recovers balance, "especially against heavy hits you can't parry" ([PlayStation Blog](https://blog.playstation.com/2021/11/18/how-sifus-kung-fu-combat-works/)).

| Height | Examples | Hits a crouching fighter? | Hits a jumping fighter? | Defence |
| --- | --- | --- | --- | --- |
| High | Hooks, high kicks, standing grabs | No | Yes | Crouch, block, dodge |
| Mid | Front kick, body punches | Yes | Yes | Block, dodge |
| Low | Sweeps, low kicks | Yes | No | Jump, crouch-block |

**Crouch (tuning starts)**

- Capsule from 1.8 m to 1.1 m; moves at 40% speed; can still block, and a crouching block stops lows.
- Standing grabs whiff on a crouching fighter, as in Tekken. That gives a second answer to the red grab glint: break it with Grab, or duck it.
- Crouch moves: crouch + P is a low body punch; crouch + K is the sweep; releasing crouch into P is a rising uppercut (launcher).

**Jump (tuning starts)**

- 0.9 m apex, 0.6 s in the air, steerable at 50%; 6 frames of landing recovery.
- Clears lows. A fighter hit in the air takes a counter-hit (×1.25 launch), so jumping is a read, not a free escape.
- Jump moves: jump + K is a flying kick (mid, launches); jump + P is a hammer fist (hits grounded and tumbling bodies).

**Implementation:** hit height is a tag on each attack, but the hurtboxes also move with the crouch and jump poses, so a high hitbox physically passes over a crouching fighter. The tag is the fallback when geometry is ambiguous. The A\* navigation needs no change: crouch and jump do not change where enemies can walk.

## Moving while charging

A charging fighter can walk, strafe and turn, so a charge sets up a hit rather than rooting you in place.

| Charge level | Move speed | Allowed |
| --- | --- | --- |
| 1–2 | 60% of walk | Walk, strafe, turn toward the soft target |
| 3 | 40% of walk | Walk, strafe |

- Jumping or crouching keeps the charge, so a jump + held K becomes a charged flying kick.
- Dashing releases the charge at the end of the dash. Because launch impulse already adds the attacker's speed into the hit, a dash-released level 3 kick is the strongest standing hit in the game. That is intended: it rewards the setup.
- Blocking or perfect-dodging drops the charge.
- Facing locks to the soft target while charging, so the strike lands where it is aimed.

## Body-zone targeting and limb grabs

Strikes and grabs go to one of five zones — head, torso, either arm, legs — picked by where the camera aims on the soft target. Each zone does something different, and a grab by a limb turns the enemy into a physical object you can swing.

**Evidence:** Sifu's Focus slows time and lets you aim at "a specific body part" ([Pro Game Guides](https://progameguides.com/sifu/what-does-focus-do-in-sifu-explained/)) to "disable or seriously wound" an enemy ([PlayStation Blog](https://blog.playstation.com/2021/11/18/how-sifus-kung-fu-combat-works/)). Tekken has limb throws such as King's Giant Swing ([Prima Games](https://primagames.com/gaming/how-to-break-throws-in-tekken-8)).

**Picking a zone (my design)**

1. A ray from the screen centre hits the soft target's hurtboxes; the zone it hits is highlighted on the enemy.
2. No hit (aiming off the body) falls back to the torso, so casual play still works.
3. Crouch forces the legs; jump forces the head.
4. During Focus (next section) the highlight is larger and the aim is exact.
5. The existing strike magnetism bends the strike pose to the chosen zone.

**What each zone does (tuning starts)**

| Zone | Strike effect | Grab |
| --- | --- | --- |
| Head | +30% damage; stuns; can be ducked (high) | Headlock: knees with P, headbutt with K, neck throw on release |
| Torso | Full launch; the best wall breaker (closest to the centre of mass) | Standard hold and throw (as built) |
| Arm | Hitting the attacking arm during an enemy wind-up cancels the attack. Damage builds up; at 100 the arm is broken: weaker attacks, no blocking with it | Arm drag: swing the enemy around you with the mouse; release flings them. The swinging body hits other enemies (bowling) |
| Legs | Slows the enemy 30% for 3 s; a quick sweep makes them stumble, a charged one trips them | On a tumbling or downed enemy: giant swing, then release |

A broken arm reuses the dislocation idea from the original spec: the joint's limits widen and the forearm hangs.

**Grabbing more freely**

- Grab works on standing, tumbling and downed enemies. Picking up a downed body and throwing it is allowed; catching a flying body is a stretch goal.
- A limb grab anchors your hand to that enemy's physical bone with a joint, and the rest of the body ragdolls. Swinging an enemy by the arm is then real physics, not an animation. The current grab snaps the capsule to a socket; keep that for torso and head grabs.
- Limb grabs can still be broken by the enemy's Grab at the same timing as now; arm drags take a 30% shorter break window, because they are the strongest crowd tool.

**Risk:** active ragdolls under Jolt are reported as fragile, with springs exploding after hits ([Godot forum](https://forum.godotengine.org/t/active-ragdolls-in-godot-jolt-is-it-even-possible/117047)). A hand-to-bone joint swung fast may stretch or jitter. Spike one arm drag before building the rest; clamp swing speed and the victim's bone velocities.

## Focus: the world slows, you don't

Holding Focus drops the world to 0.3× while the player keeps moving, striking and charging at full speed in real time, and drains the Focus meter as it runs. It turns the existing slow-motion moments into a tool the player controls.

**Evidence:** Max Payne's bullet time slows Max and his enemies but lets the player "react to enemy gunfire quickly"; its meter drains while active and refills only from kills ([Wikipedia](<https://en.wikipedia.org/wiki/Max_Payne_(video_game)>)). Sifu's Focus slows time to a crawl and lets the player pick a body part ([Pro Game Guides](https://progameguides.com/sifu/what-does-focus-do-in-sifu-explained/)).

**Rules (tuning starts)**

- Hold E (LB) to activate; needs at least half a bar. Drains 1 bar per 2.5 s of real time; ends when released or empty.
- Fills as now (perfect dodges, launches), plus 0.25 bar per kill.
- The player runs at full real-time speed; enemies, ragdolls, debris and blood run at 0.3×. Enemy tells last 3.3× longer in real time, so dodges and grab breaks get easier.
- Zone aiming is exact and highlighted (previous section).
- Charging fills at the player's real-time rate, so a level 3 charge takes 0.8 s of your time, not of the world's.
- Getting launched ends Focus.
- Focus does not count against the slow-motion budget; it costs meter instead. Local hitstop still applies inside it.

**How to build it in Godot (my design)**

`Engine.time_scale` slows everything, including the player. Each physics tick's delta is the time scale divided by the ticks per second ([Godot API, via godot-rust docs](https://godot-rust.github.io/docs/gdext/pr-1606/godot/classes/trait.ITileMapLayer.html)), so a `move_and_slide` player moves 0.3× as far; a Godot forum user hit exactly this when slowing time ([Godot forum](https://forum.godotengine.org/t/how-could-i-slow-down-time-without-affecting-the-players-movement/65110)). The fix is to undo the scale for the player only:

1. `TimeDirector` exposes `player_time_factor` = 1 ÷ `Engine.time_scale` while Focus is active, else 1.
2. The player's velocity, animation speed, combo timers, buffer, charge timers and cooldowns all multiply by that factor. Route every one through one helper so none is missed, including gravity on the player's jumps, or jump arcs change shape in Focus.
3. Impulses the player applies to enemies are not scaled: an impulse is instant, so a launched enemy flies at the correct speed in slowed time and speeds up when Focus ends.
4. Audio: world sounds slow with `AudioServer.playback_speed_scale`; the player's own sounds would slow too, so pitch-correct them or accept it.

## Dash pursuit

Keep pursuit as built: you said it works. Two additions: during Focus, pursuit costs no extra Focus beyond the drain, so a Focus burst can chain up to three pursuits on one body; and a pursuit that ends in a wall impact never follows the body with the camera (Camera rule 1).

## Roguelike direction: becoming god-like

A run is a chain of fights; after each, you pick one of three boons, and every few fights you ascend a tier that visibly changes the rules of physics around you. The player should outgrow the enemies, so the game gets harder by sending more of them and changing their mix, not by turning them into sponges that stop ragdolls from flying. Not built yet; this is the direction to build toward.

**What shipped games do**

| Game | Mechanic | What we take |
| --- | --- | --- |
| Hades | Gods offer boons; duo boons combine two gods' effects and need specific boons from both first; rarity tiers up to legendary ([Prima Games](https://primagames.com/tips/hades-what-are-duo-boons-how-get-duo-boons)) | Boon families with themes, and duo boons as late-run rewards |
| Vampire Survivors | Each level-up offers "three or four" weapons or passives; weapons evolve into ultimate forms ([Wikipedia](https://en.wikipedia.org/wiki/Vampire_Survivors)) | Pick 1 of 3; boons that evolve when maxed |
| Risk of Rain 2 | A "snowball effect" of stacking items, about fifty by 45 minutes ([Vice](https://vice.com/en/article/7xgvbz/risk-of-rain-2-makes-you-a-force-of-nature)); difficulty rises with time and ×1.15 per stage, and each enemy level adds 30% health and 20% damage ([wiki](https://riskofrain2.wiki.gg/wiki/Difficulty)) | A visible snowball, but scale enemy count and mix more than enemy health |
| Max Payne | The bullet-time meter refills only from kills ([Wikipedia](<https://en.wikipedia.org/wiki/Max_Payne_(video_game)>)) | Kills fuel god powers |

**Run structure (proposal)**

- Fights are wave sets in arenas built from the existing kit. After each, pick 1 of 3 boons.
- Every fourth fight is a boss (Duelist variants first).
- Death ends the run, matching the current rule that a round ends at death.
- Between-run unlocks (like Hades' Mirror of Night) come later.

**Tiers of godhood (proposal)**

| Tier | Reached | What changes in the world |
| --- | --- | --- |
| Mortal | Start | The game as it is now |
| Awakened | After fight 4 | An aura; launches ×1.25; a dash kick breaks brick; double jump |
| Ascended | After fight 8 | Level 3 charges release a shockwave that knocks the crowd back; air dash; Focus refills from blood |
| Godlike | After fight 12 | Hits crack concrete, so outer walls break and the fight spills into the next area; grab from 6 m; Focus can stop time for 1 s |

Each tier is a transformation the enemies react to: grunts hesitate and Throwers keep further back. Unlike stat boons, tiers change what the arena can do.

**Boon families (proposal):** each family bends one physics system, so every pick changes what happens on screen, not just a number.

| Family | Bends | Example boons |
| --- | --- | --- |
| Force | Launches and walls | Bodies break one extra wall; walls you break explode outward |
| Gravity | Airtime and falls | Launched enemies float 0.5 s longer; slams pull nearby enemies in |
| Time | Focus and dodges | Perfect dodges refill half a bar; Focus at 0.15× |
| Blood | Gore and healing | Standing in a blood pool heals; severed limbs become projectiles |
| Bone | Grabs and limbs | Arm drags rip the arm off on release; grabbed enemies are armour |

Duo boons combine two families, for example Force + Time: bodies launched during Focus hold their speed and all release at once when it ends.

**Rules that keep it fun**

1. **Powers must stay inside the physics budget.** Shockwaves and explosions multiply ragdolls and debris; the existing caps (rubble 120, active ragdolls) become hard limits that god powers work within. Shockwaves push existing bodies; they do not spawn more.
2. **Enemies scale by count and mix first.** More enemies at once, more elites, tougher archetypes; health rises slowly (about 10% a fight, tuning start). Ragdolls only feel good when enemies fly.
3. **Every boon must be readable.** If a player cannot see what a boon did, cut it.
4. **The arena escalates with the player.** Mortal breaks drywall, Awakened brick, Godlike concrete.

## Reviewing your reference videos

Yes: send YouTube Shorts links and I can open them in the browser pane of the Claude desktop app, slow them down, step through them and take screenshots, which I see as images. I did this for the two ragdoll videos behind the first spec, capturing their full captions.

**Limits**

- I see frames, not motion. I sample screenshots, so a move faster than my sampling can fall between frames; I slow the video to 0.25× to reduce that.
- I cannot hear audio. Shorts often have no captions, so I get nothing from narration there.
- The browser pane runs on your computer, so the desktop app must be open and online while I work.
- YouTube blocks fetching videos from my cloud workspace, so I cannot download them myself.

**The most precise route:** if you save a clip as an .mp4 and attach it, I can pull every frame in my workspace and lay them out as contact sheets. That catches every pose of a fast move, which is what you need to copy a combo.

**What to send with each clip:** the timestamp and one line on what you want from it, for example "0:04, the way the knee follows the sweep". I will turn each into a move entry: inputs, poses, timing and what it would add to the combo graph.

## What your four clips show

All four get their best moments from grabs, the environment and finishers, and in all four the enemy reactions are canned animations. The move ideas carry over; our version makes each reaction physical, which is exactly what you felt was missing in the second clip.

I watched each clip at full resolution and sampled frames every 0.5–0.6 s, with a closer pass on the throws. A move faster than that can be misread; timestamps are approximate.

| Clip | What I saw | What we take |
| --- | --- | --- |
| [Throws: Crimson Desert](https://www.youtube.com/shorts/e77aNN2fTgA) (named in the title) | 2–3 s: grabs and carries an enemy. 4.25 s: throws him into a fire, which flares. 6–7 s: wrestles one to the ground and slams. 8.75 s: throws one high into the air. 13.75–14.75 s: throws one into a wooden scaffold, which breaks. 17.4–19 s and 21–22 s: holds an enemy and swings the body into others | Bodies as weapons; throws into breakables and hazards; an upward throw |
| [Hand to hand, not ragdoll enough](https://www.youtube.com/shorts/uoqWWvpXG4g) (the game is not named; it looks like Sleeping Dogs) | 0.25–1.25 s: the attacking enemy is outlined red with a ring at his feet, the counter cue. 3.75–5.25 s: a "HOLD F" prompt over a downed enemy, then a stomp. 8.75–9.75 s: catches an arm into a takedown. 10–12 s: punches a downed enemy from a low, close camera. 12.75 s: blood on the player's face and chest. 14.25–15.25 s: a dazed enemy hunched with a swirl over his head, then a spinning kick launches him | A dazed state; ground finishers; the cue on the attacker himself |
| [Combat and effects: Sifu](https://www.youtube.com/shorts/XSHaBju7yuQ) (named in the title) | 0.25–1.25 s: a ring of enemies waits its turn. 3.25 s on: a balance bar under the target. 3.75 s: a radial flash at the point of contact; rain splashes on every impact. 4.75 s: an enemy's foot glows just before his kick. 7.75 s: an enemy knocked flat through the air. 12.75 s: a large circular swirl on a hit. 17.65–18.45 s: the camera closes in for the final hit | An impact-effect recipe; the attacking limb glows as the tell; a finisher close-up |
| [More: 007 First Light](https://www.youtube.com/shorts/bHyse0S7cic) (1 against 3, per its description) | 0.3 s and 10.5 s: a yellow-green flash on an enemy's chest before he attacks. 3.9–4.5 s: slams an enemy's head into a wall. 7.5–9.9 s: throws one into a wall; he slides down it. 19.5–21.3 s: a clinch with head control. 27.3–33.3 s: pins an enemy against a railing and punches down. The camera moves close for finishers | Grabs that use the nearest wall |

## New moves and effects from the clips

| Addition | Seen in | Our version (tuning starts) | Milestone |
| --- | --- | --- | --- |
| Wall slam | 007, Crimson Desert | Grab within 1.5 m of a wall, pillar or railing drives the enemy head first into it at 9 m/s through the impact resolver: about 2,800 J for 70 kg, enough to put a head through drywall | U5 |
| Body as a weapon | Crimson Desert | Hold an enemy by an arm or the legs and swing; every enemy the body hits is checked for bowling | U5 |
| Upward throw | Crimson Desert | Grab, back + release: straight up 2 m, for a flying kick or pursuit | U4 |
| Ground finishers | Sleeping Dogs, Sifu, Crimson Desert | Standing over a downed enemy: P is three mounted punches, K a stomp (the current punt when on top), hold F lifts them for a throw | U4 |
| Dazed | Sleeping Dogs | After a broken arm, a level 2+ head hit, or three hits on a blocking enemy: 1.5 s hunched over with a swirl, no actions; the next hit always launches | U4 |
| Limb-glow tells | Sifu, 007, Sleeping Dogs | The attacking fist or foot glows instead of a glint above the head. Where it glows still shows the height (head, waist, feet); the colours stay: white strike, red grab, blue counter | U3 |
| Hazard props | Crimson Desert | Fire barrels in The Yard: a body thrown into one bursts it, burns for damage over time and pushes nearby enemies away | Later |
| Impact flash | Sifu | A 2–3 frame radial flash and streak ring at the contact point, sized by hit power; dust bursts on body-to-ground and wall impacts | U7 |
| Finisher close-up | Sifu, Sleeping Dogs, 007 | On the last enemy's KO, or a finisher with no enemy winding up: 0.6 s push-in to 2 m at 0.3×, then back. The player stays in frame, so camera rule 1 still holds | U7 |
| Blood on the player | Sleeping Dogs | The wound shader already marks fighters; make sure the player shows it, so damage taken is visible without the HP bar | U7 |

## Build order

Seven upgrade milestones, each playable on its own; the roguelike waits until U6 feels right.

| # | Milestone | Scope | Done when |
| --- | --- | --- | --- |
| U1 | Camera and key map | Camera rules 1–9; new key map; fullscreen-grab conflict fixed | 10 minutes of Waves with no camera follow of a thrown body and no top-down or in-wall view |
| U2 | Input model | `InputInterpreter`, tap/hold at 150 ms, 3 charge levels on every attack, buffer, move while charging | A fast click always jabs; a hold always charges; you rate the hold threshold as right |
| U3 | Crouch and jump | Heights on every attack; limb-glow tells at head, waist and feet; crouch and jump moves | Ducking a hook, jumping a sweep and crouch-blocking a low each work 9 of 10 times in the Lab |
| U4 | Combos | `ComboGraph`; the 8 strings; stumble and trip sweeps; cancels; juggles; damage scaling; upward throw; ground finishers; dazed state; new move poses | Sweep into front kick launches into a wall reliably; no combo kills a full-health Brawler on its own |
| U5 | Zones and limb grabs | Zone aiming and highlight; zone effects; arm-drag spike first, then head, leg and downed grabs; wall slam; swinging a body as a weapon | An arm drag swings one enemy into another without the joint stretching or exploding |
| U6 | Focus | `player_time_factor`; Focus meter; zone aiming in Focus; pursuit chains | In Focus the player's run, jump and combo timings match normal speed to within 5% |
| U7 | Finishers and impact effects | Impact flash and dust bursts; finisher close-up; blood on the player | A side-by-side recording of the same hit before and after reads clearly stronger to you |

## Risks

| Risk | Mitigation |
| --- | --- |
| Tap/hold makes fast attacks feel late | Wind-up starts on press; tune the 150 ms threshold with you; measure input-to-hit time |
| Hand-to-bone joints stretch or explode under Jolt when swinging bodies | Spike in U5 first; clamp swing speed; fall back to a scripted arm-drag animation |
| One player system misses `player_time_factor` and breaks in Focus | One helper for all player timing; a Lab test that runs every move in and out of Focus |
| Procedural poses for about a dozen new moves | Build U4's moves as data in `ComboGraph`; reference clips speed up posing |
| Combos plus a crowd become too easy | Enemy armour, block cancels for the player only on basic moves, damage scaling; watch the crowd attack rate (still 1 per 3 s against a 1–1.5 s target) |
| God-tier powers blow the physics budget | Powers act on existing bodies; the rubble and ragdoll caps are hard limits |

## Open questions

- [ ] Key map: is block on Q acceptable, and Space for jump?
- [ ] Zone aiming: camera centre (proposed), or a separate stick or modifier?
- [ ] Should crouching dodge standing grabs, as in Tekken, or should Grab stay the only answer?
- [ ] Roguelike: does a tier ladder (Mortal to Godlike) match the god-like feeling you want, or should power come only from boons?
- [ ] Art direction: still open; it does not block U1–U6.

## Sources

Camera and combat design:

- [Game Developer: third-person camera problems and solutions](https://www.gamedeveloper.com/design/third-person-camera-view-in-games-a-record-of-the-most-common-problems-in-modern-games-solutions-taken-from-new-and-retro-games)
- [Game Developer: 50 game camera mistakes (Nesky, GDC 2014)](https://gamedeveloper.com/design/video-50-common-game-camera-mistakes----and-how-to-fix-them)
- [Game Developer: Combat Canceled, God of War and action design](https://www.gamedeveloper.com/pc/combat-canceled-i-god-of-war-i-action-game-design)
- [Dustloop: infinite prevention and combo mechanics](https://dustloop.com/w/User:Slimegirl-scientist/Infinite_Prevention_and_Combo_Mechanics)
- [Hotspawn: Tekken 8 juggles](https://www.hotspawn.com/fgc/guide/tekken-8-beginner-series-how-to-juggle-combo)
- [Hotspawn: Tekken 8 attacking and defending](https://www.hotspawn.com/tekken/guide/tekken-8-beginner-series-attacking-and-defending)
- [PlayStation Blog: Sifu combat](https://blog.playstation.com/2021/11/18/how-sifus-kung-fu-combat-works/)
- [Pro Game Guides: Sifu Focus](https://progameguides.com/sifu/what-does-focus-do-in-sifu-explained/)
- [Prima Games: Tekken 8 throw breaks](https://primagames.com/gaming/how-to-break-throws-in-tekken-8)
- [Wikipedia: Max Payne](<https://en.wikipedia.org/wiki/Max_Payne_(video_game)>)

Godot:

- [Godot API delta and time scale (godot-rust mirror)](https://godot-rust.github.io/docs/gdext/pr-1606/godot/classes/trait.ITileMapLayer.html)
- [Godot forum: slowing time without slowing the player](https://forum.godotengine.org/t/how-could-i-slow-down-time-without-affecting-the-players-movement/65110)
- [Godot forum: active ragdolls in Jolt](https://forum.godotengine.org/t/active-ragdolls-in-godot-jolt-is-it-even-possible/117047)

Roguelikes:

- [Prima Games: Hades duo boons](https://primagames.com/tips/hades-what-are-duo-boons-how-get-duo-boons)
- [Wikipedia: Vampire Survivors](https://en.wikipedia.org/wiki/Vampire_Survivors)
- [Vice: Risk of Rain 2 makes you a force of nature](https://vice.com/en/article/7xgvbz/risk-of-rain-2-makes-you-a-force-of-nature)
- [Risk of Rain 2 wiki: difficulty](https://riskofrain2.wiki.gg/wiki/Difficulty)
