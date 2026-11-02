class_name Power
## Round 5 power score and everything derived from it (Feel Reference: Strikes
## and body reactions). Pure math, no state: combat, world, grabs, tests and the
## debug overlay all use these so the numbers never drift apart.
## OWNER: core (contract). Numbers come from Tuning.

## Real speed toward the target counts as the cap once it reaches
## Tuning.SPEED_CAP_SNAP of it, so full sprint always gives the full bonus.
static func speed_bonus(speed_toward: float, cap: float) -> float:
	var v := speed_toward
	if cap > 0.0 and v >= cap * Tuning.SPEED_CAP_SNAP:
		v = cap
	return Tuning.SPEED_BONUS_K * maxf(0.0, v - Tuning.SPEED_BONUS_FROM)

static func charge_mult(level: int) -> float:
	return Tuning.CHARGE_MULT[clampi(level, 0, Tuning.CHARGE_MULT.size() - 1)]

## Base for a strike class (&"jab", &"cross", &"kick", &"sweep", &"knee", &"elbow", &"ground").
static func base_of(strike_class: StringName) -> float:
	return Tuning.POWER_BASE.get(strike_class, 1.0)

## P = base x charge_mult + speed_bonus + counter_bonus + finisher_bonus.
static func score(base: float, charge_level: int, speed_toward := 0.0, cap := 8.0,
		counter_bonus := 0.0, finisher := false) -> float:
	return base * charge_mult(charge_level) + speed_bonus(speed_toward, cap) + counter_bonus \
		+ (Tuning.FINISHER_BONUS if finisher else 0.0)

## Body tier from P (half-open bands: a boundary value goes to the higher tier).
static func tier_of(p: float) -> int:
	var b := Tuning.TIER_BANDS
	if _at_least(p, b[4]):
		return HitInfo.Tier.SEVER
	if _at_least(p, b[3]):
		return HitInfo.Tier.HARD_LAUNCH
	if _at_least(p, b[2]):
		return HitInfo.Tier.LAUNCH
	if _at_least(p, b[1]):
		return HitInfo.Tier.KNOCKDOWN
	if _at_least(p, b[0]):
		return HitInfo.Tier.STAGGER
	return HitInfo.Tier.FLINCH

## Sweep reads the leg: stumble, knockdown (trip), or upended into a launch.
## A sweep never hard-launches or severs.
static func sweep_tier_of(p: float) -> int:
	if _at_least(p, Tuning.SWEEP_BANDS[1]):
		return HitInfo.Tier.LAUNCH
	if _at_least(p, Tuning.SWEEP_BANDS[0]):
		return HitInfo.Tier.KNOCKDOWN
	return HitInfo.Tier.STUMBLE

## Launch speed v = clamp(6 + 2 (P - 5), 6, 18) m/s.
static func launch_speed(p: float) -> float:
	return clampf(Tuning.LAUNCH_SPEED_MIN + 2.0 * (p - 5.0), Tuning.LAUNCH_SPEED_MIN, Tuning.LAUNCH_SPEED_MAX)

## Degrees above horizontal: 30 under P 7, 18 (flat and fast) from P 7.
static func launch_angle(p: float) -> float:
	return Tuning.LAUNCH_ANGLE_HARD if _at_least(p, Tuning.TIER_BANDS[3]) else Tuning.LAUNCH_ANGLE

## Launch speed for a victim: heavies (mass >= Tuning.HEAVY_MASS or flagged) fly at 80%.
static func launch_speed_for(p: float, victim_mass: float, is_heavy := false) -> float:
	var v := launch_speed(p)
	if is_heavy or victim_mass >= Tuning.HEAVY_MASS:
		v *= Tuning.HEAVY_LAUNCH_MULT
	return v

## World launch velocity: `direction` is the strike direction (flattened here),
## tilted up by launch_angle(p).
static func launch_velocity(p: float, direction: Vector3, victim_mass := 70.0, is_heavy := false) -> Vector3:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 1e-6:
		flat = Vector3.FORWARD
	flat = flat.normalized()
	var a := deg_to_rad(launch_angle(p))
	return (flat * cos(a) + Vector3.UP * sin(a)) * launch_speed_for(p, victim_mass, is_heavy)

## Launch damage 10 + 3 (P - 5), capped at 35% of max health. 0 under launch tier.
static func launch_damage(p: float, max_hp: float) -> float:
	if not _at_least(p, Tuning.TIER_BANDS[2]):
		return 0.0
	return minf(Tuning.LAUNCH_DAMAGE_BASE + Tuning.LAUNCH_DAMAGE_PER_P * (p - 5.0),
		Tuning.LAUNCH_DAMAGE_CAP * max_hp)

## Strike damage before combo scaling: STRIKE_DAMAGE[class] x charge_mult.
static func strike_damage(strike_class: StringName, charge_level: int) -> float:
	return float(Tuning.STRIKE_DAMAGE.get(strike_class, 4.0)) * charge_mult(charge_level)

## Pursuit relaunch speed: max(current speed, v(P + 3)). Heavies take v at 80%
## like any launch, and every flying body stays under Tuning.LAUNCH_SPEED_MAX.
static func pursuit_speed(p: float, current_speed: float, victim_mass := 70.0, is_heavy := false) -> float:
	var v := launch_speed_for(p + Tuning.PURSUIT_POWER_ADD, victim_mass, is_heavy)
	return minf(maxf(current_speed, v), Tuning.LAUNCH_SPEED_MAX)

## Hitstop (real s) by tier; the player's own freeze is capped separately.
static func hitstop_for(tier: int) -> float:
	return Tuning.HITSTOP_TIER.get(HitInfo.tier_name(tier), 0.0)

## Camera trauma by tier.
static func trauma_for(tier: int) -> float:
	return Tuning.TRAUMA.get(HitInfo.tier_name(tier), 0.0)

## Wall energy E = 1/2 M v^2 using the speed straight into the wall.
static func wall_energy(mass: float, velocity: Vector3, wall_normal: Vector3) -> float:
	var vn := maxf(0.0, -velocity.dot(wall_normal.normalized()))
	return 0.5 * mass * vn * vn

## Thrown body hitting an enemy: tier by its speed.
static func bowl_tier(speed: float) -> int:
	if speed >= Tuning.BOWL_LAUNCH_FROM:
		return HitInfo.Tier.LAUNCH
	if speed >= Tuning.BOWL_STAGGER_BELOW:
		return HitInfo.Tier.KNOCKDOWN
	return HitInfo.Tier.STAGGER

## Throw speed: tap 6 m/s, charged 6 / 9 / 12, plus half the run speed, capped at 16.
static func throw_speed(charge_level: int, run_speed: float) -> float:
	var base := Tuning.THROW_SPEED_TAP
	if charge_level >= 1:
		base = Tuning.THROW_SPEED_CHARGED[clampi(charge_level, 1, 3) - 1]
	return minf(base + Tuning.THROW_RUN_SHARE * maxf(run_speed, 0.0), Tuning.THROW_SPEED_CAP)

## Sprint cap for the current debug setting (8 base; 10 and 12 are upgrades).
static func speed_cap() -> float:
	return Tuning.debug_speed_cap

static func _at_least(v: float, threshold: float) -> bool:
	return v + 1e-6 >= threshold
