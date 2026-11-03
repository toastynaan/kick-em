# Round 8 — Charge and Pressure

Round 8 reworks the **strikes only**, from the user's grill session of 2026-11-03. Counter, dodge, grab, drive, throw, teleport, pursuit, the camera's base rules and movement are unchanged and are tuned in later rounds. Where this doc disagrees with Round 7 about a strike, Round 8 wins. Animation quality and performance are still out of scope.

## The loop

Tap to pressure the enemy. Pressure makes them passive, then breaks them open. Charge a heavy strike and send them flying, or lift them and follow them into the air.

- **Taps** are light. They interrupt a normal enemy's wind-up but barely stun it. Taps alone never lock anyone down.
- **Charged strikes** are the payoff: stuns, sweeps, lifts, launches.
- **Pressure** is how you earn the time to charge.

## Modes

- **Duel**: you are fully upgraded against the Duelist. GameMode sets every upgrade setting to its max for the round and restores the player's own settings afterwards.
- **Waves**: becomes the roguelike in a later round. Until then, upgrades are the pause-menu debug settings. Enemy **level** follows the wave (Pressure).

## Charge (every strike)

Numbers are in `Tuning` (Round 8 block). Times are the player's real seconds from the press.

- Released before `R8_TAP_MAX` (0.25 s): a **tap**. The tap entry of the move fires on its own frame data.
- Still held at `R8_TAP_MAX`: **charging** begins. The charge amount c goes from 0 at `R8_TAP_MAX` to 1 at full, which is `Tuning.debug_charge_full` (1.0 s at the start, 0.5 s fully upgraded).
- **At full**, the meter flashes and holds for `R8_CHARGE_HOLD_AT_FULL` (0.5 s), then the strike fires on its own.
- **Walking while charging** at `R8_CHARGE_WALK_MULT` (0.5) of walk speed. The body turns to track the target picked at the press.
- **On release**, the strike glides to its target first. The glide reaches `R8_CHARGE_LUNGE` (3 m at c = 0, 6 m at c = 1) at `R7_GLIDE_SPEED`. Then come `R8_RELEASE_STARTUP` frames, the active frames and the move's recovery plus `R8_CHARGED_EXTRA_RECOVERY`. With the stick pushed at the release, the target is re-picked along the stick. With the stick neutral, it stays on the charge's target.
- **A hit on the player while charging cancels the charge** (no strike). Charge armor is a later roguelike upgrade.
- Charging uses the move's `heavy_<move>_load` pose, deepening with c.
- **The punch string is unchanged**: LMB counts jab, cross, hook; holding charges that position's punch. Air strikes never charge (a held press in the air fires as a tap).
- Charged strikes break a guard and tell armor (as Round 7 heavies did).

## The meter (HUD)

A bar at the bottom centre, like Round 5's. It fills with c, changes colour at the move's steps (no labels), and flashes at full. Colours:

- white: under the first step
- orange: past it
- red: past the last step

The steps are `CombatController.get_charge_steps()`: each move's c values where its result changes (for example, the front kick's launch step). It stays up for a moment after the release.

## Moves

`Tuning.R8_MOVES[move]` has a **"tap"** entry and a **"charged"** entry. Charged values are pairs [at c = 0, at c = 1], interpolated by c. A "launch_from" c (default 1.0) marks where a charged move becomes a ragdoll launch. `Tuning.debug_launch_step` lowers every launch_from to at most that value (1.0 at the start, 0.5 fully upgraded): "ragdoll as they level up".

| Move | Tap | Charged | At launch_from / full |
| --- | --- | --- | --- |
| Jab | flinch (0.2 s), 0.3 m | push 1.5 → 4 m, stays standing | — |
| Cross | flinch (0.2 s), 0.35 m | push 2 → 3.5 m | ragdoll launch straight back, 10 → 14 m/s |
| Hook | head turn (spin 0.25 s) | spin and knock down sideways | launch sideways, 10 → 13 m/s |
| Leg kick | leg flinch (0.15 s): they keep coming | knee buckle, 0.6 → 1.5 s | sweep: legs out, flat on the floor |
| Gut punch | quick half-keel (fold, 0.3 s) | fold 0.6 → 1.8 s, pressure 5 → 8 | full charge breaks their pressure outright |
| Uppercut | head snap (0.25 s), stays standing | lift 0.8 → 2.5 m | — |
| Front kick | shove 1.75 m with a stumble (0.4 s), no ragdoll | push 2.5 → 4.5 m | ragdoll launch, 11 → 15 m/s |
| Roundhouse | knockdown | launch 11 → 16 m/s | — |

- **Flinch** (new reaction kind `&"flinch"`): a physical hit on the struck bone and a stun of a fraction of a second. After it, the enemy is free to walk in and attack.
- **Interrupts**: any tap cancels a normal enemy's wind-up. Armored wind-ups (heavy archetype, the Duelist's big swings, `MoveData.armor`) ignore taps and take the damage and a small snap.
- **Sweep** (new kind `&"sweep"`): a knockdown with the legs taken out (falls on the back).
- **Hook knockdown**: a knockdown pushed sideways, across the hook.
- **Payoffs**: the full Round 7 table stays. A tap uses its move id (`jab`); a charged strike uses its heavy id (`heavy_jab`). Payoff results do not scale with charge.
- **Sprint strikes** (God path) apply to charged and tapped strikes as before.

## Pressure

Every enemy has a pressure meter (`CombatController.get_pressure()` / `get_pressure_max()`).

- **Filling**: every player hit adds the move's "pressure" (taps about 1, charged about 3 to 4, the charged gut punch 5 to 8), times `Tuning.debug_pressure_mult` (1.0 at the start, 2.0 fully upgraded). **Blocked hits add pressure too.** That is how guards break.
- **Effect** (AI reads `get_pressure_fraction()` p):
  - block chance × (1 − p)
  - time between attacks × (1 + p)
  - tells `R8_PRESSURE_TELL_SLOW` × p slower
  - at p ≥ `R8_PRESSURE_BACK_OFF` (0.6), a free enemy backs off instead of trading
- **Full: broken open** for `R8_BREAK_TIME` (1.5 s). They can't block or attack (dazed, reaction state `&"broken"`). Player hits on them do x `R8_BREAK_DAMAGE_MULT` (1.5) damage and push and launch x `R8_BREAK_PUSH_MULT` (1.3). A reaction from a hit plays as usual and the broken timer keeps running. Afterwards the meter is empty and fills at half rate for `R8_BREAK_IMMUNE` (2 s), so it can't be chain-broken.
- **Draining**: after `R8_PRESSURE_DECAY_DELAY` (1.5 s) with no hit, it drains at `R8_PRESSURE_DECAY` (35% of max per s).
- **Capacity** by archetype and level (`R8_PRESSURE_CAP`):
  - grunt: level 1 breaks in about 2–3 taps (2.5), level 2 in 5, level 3 in 8
  - stick: 3 / 6 / 9
  - heavy: 6 / 10 / 14
  - Duelist: 16
- **Level**: `Fighter.level` (1–3) is set at spawn from `R8_LEVEL_BY_WAVE` (waves 1–2: 1, 3–4: 2, 5+: 3); the Duelist is level 1. Higher levels also block more (`R8_LEVEL_BLOCK_MULT`).
- A bar under the enemy's health shows it (HUD).

## Air combo

- **Follow**: within `R8_AIR_FOLLOW_WINDOW` (0.6 s) of a charged uppercut that lifts a body at least `R8_AIR_FOLLOW_MIN_LIFT` (1.2 m), a Jump press with that body within `R8_AIR_FOLLOW_RANGE` (4 m) is a **launcher jump**. The player leaps to the body's height in about `R8_AIR_FOLLOW_TIME` (0.25 s).
- **Air strikes**: while the player is airborne and a lifted body is within `R8_AIR_STRIKE_RANGE` (2 m), an attack press is an **air strike**. It uses the button's move with `R8_AIR_FRAMES` frame data and is always a tap. It is not the dropping strike.
- **Hang**: each air strike that lands freezes the player's and the body's vertical motion for `R8_AIR_HANG` (0.35 s), up to `Tuning.debug_air_hits` air hits per combo (4 at the start). Past the cap there is no hang and both fall.
- **Finishers**:
  - Any kick in the air launches the body away at `R8_AIR_KICK_LAUNCH` (14 m/s, `R8_AIR_KICK_ANGLE` up).
  - A punch with the stick pulled back toward the camera is the spike (Round 7's spike: `R7_SPIKE_SPEED`, the floor shockwave).
  - Other punches keep the body floating.
- A body that lands without a finisher falls into a knockdown (Round 7's lift landing).

## Upgrades (debug settings, pause menu)

Added this round:

| Setting | Start | Max |
| --- | --- | --- |
| `debug_charge_full` (s to full charge) | 1.0 | 0.5 |
| `debug_pressure_mult` | 1.0 | 2.0 |
| `debug_launch_step` (launch_from cap) | 1.0 | 0.5 |
| `debug_air_hits` | 4 | 6 |

The Round 7 settings stay: speed cap, ram level, teleport, pursuit chain. The Duel sets all of them to max.

## Acceptance (automated, real input where input matters)

1. Tap vs charge: a 0.2 s press is the tap; a 0.6 s hold gives c = 0.47 ±0.03 at release (base); full at 1.0 s holds 0.5 s then auto-fires; with `debug_charge_full` 0.5, full at 0.5 s.
2. Every row of the moves table, tapped and charged at c = 0 and 1, gives its reaction, push (±20%), stun (±0.05 s), lift (±0.15 m) and launch speed (±0.5 m/s). `debug_launch_step` 0.5 makes the front kick launch at c = 0.5.
3. Taps interrupt a grunt's wind-up and the grunt can attack again within 0.4 s of the tap; armored wind-ups are not interrupted.
4. Charging: walk at half speed; the release glides 3 m (c = 0) and 6 m (c = 1); a hit during the charge cancels it.
5. Pressure: a level-1 grunt breaks on the 3rd jab; blocked hits add pressure; the break lasts 1.5 s with no enemy attack or block; bonus damage x1.5; drain after 1.5 s idle; half-rate refill for 2 s after a break; the Duelist needs 16.
6. AI under pressure: at p ≥ 0.6, a free grunt backs off; block chance and attack rate scale down (measured over a scripted run).
7. Air combo: a full-charge uppercut lifts 2.5 m, Jump follows to that height, 4 air jabs each hang 0.35 s, the 5th does not hang; an air roundhouse launches at 14 m/s; an air punch with the stick back spikes.
8. HUD: the meter fills with c, changes colour at the move's steps, flashes at full; the pressure bar tracks `get_pressure()`.
9. Duel: every upgrade setting at max during the round, the player's own settings restored after.
10. Soaks (Waves 180 s, Duel 120 s) with the bot charging and tapping: 0 errors; run_all green.
