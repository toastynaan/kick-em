# Round 9 — Playtest Fixes

Fixes from the user's Round 8 playtest. Numbers are in `Tuning` (Round 9 block). Where this disagrees with Round 8, Round 9 wins.

**Keep (the user loves it):** hits are physics-based on where they actually connect. A held kick from a jump that lands on the head sends them down. Contact-driven results stay; partial animation layers come later.

## 1. Hook: forward and spinning

The charged hook's knockdown and launch go **along the hit** (away from you), no longer sideways. The body **spins** around its vertical axis at `R9_HOOK_SPIN` (7 rad/s at c = 0, 14 rad/s at c = 1), in the direction of the hook's swing. The tap hook keeps its head turn (`&"spin"` reaction).

## 2. The punch string is easy to hold

Holding the cross or the hook was hard because the string snapped back to the jab on a whiff, a blocked jab, being hit, or a 0.3 s pause.

- The string resets to the jab only after `R9_STRING_RESET` (1.2 s) with no punch press. Nothing else resets it. Wrapping after the hook is unchanged.
- The combo counter (chain) keeps its own Round 7 rules; it is separate from the string.
- The HUD shows three small pips (J, C, H) by the charge meter. The next punch's pip is lit, so you know which punch a hold will charge.

## 3. Axe kick

The leg kick (RMB / LT + X) on a **lifted** target becomes the **axe kick**. Lifted means popped by a charged uppercut, or juggled in the air combo. The leg rises above the head and the heel chops straight down, driving the body into the floor:

- `react = &"spike"`, with the Round 7 floor shockwave and a crater.
- Tap: 12 m/s down. Charged: 14 → 18 m/s, with a bigger blast.
- From the ground it connects with a lifted body up to `R9_AXE.reach_up` (2.6 m).
- In the air combo, the leg kick is the axe kick (down). Front kick and roundhouse still send the body away. Pulling back on the stick with a punch is still the spike.

## 4. Pressure is a guard breaker, not a stun

- Pressure only weakens the enemy's guard: block chance × (1 − p). Enemies keep their normal attack pace and tells, and don't back off (`R9_PRESSURE_PASSIVE` false).
- **Broken = GUARD BROKEN** for `R8_BREAK_TIME`. They can't block, and take the break bonus (×1.5 damage, ×1.3 push), but they keep moving and attacking. No daze (`R9_BROKEN_STUN` false). The effect is a cracked-guard look, not a dazed head.
- **Only the gut punch stuns** (its fold; at full charge it also breaks the guard).

## 5. Strikes hit downed bodies (physical contact)

Answer to "if we leg sweep them on the ground, will it hit them?": in Round 8, no. Player strikes skipped downed bodies. Now any strike whose limb **physically touches** a body that is down hits it:

- The body is shoved along the floor (`R9_GROUND_HIT`): 3 m/s on a tap, up to 7 m/s charged.
- Small damage.
- It may extend the get-up once per knockdown (the existing anti-lock rule).
- Downed bodies are still never targeted, glided to or auto-connected. It only happens when your kick actually reaches them.

## Testing this round

Light, by the user's request. Each owner writes at most one small focused test per change and runs its own module once at the end. Playtest first.
