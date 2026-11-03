class_name Targeting
## Shared target selection used by the player controller and the camera.
## OWNER: core (contract).
##
## Groups (added by Fighter._ready): every fighter is in "fighters";
## the player is also in "player"; enemies are also in "enemies".

static func player(tree: SceneTree) -> Fighter:
	return tree.get_first_node_in_group(&"player") as Fighter

## Live fighters on the other team from `from`.
static func opponents_of(from: Fighter) -> Array[Fighter]:
	var out: Array[Fighter] = []
	for n in from.get_tree().get_nodes_in_group(&"fighters"):
		var f := n as Fighter
		if f and f != from and f.team != from.team and not f.is_dead():
			out.append(f)
	return out

## Opponent nearest the direction `dir` (world XZ) within max_dist.
## An idle stick (dir ~ zero) picks the nearest opponent. Downed opponents
## (launched, grounded, getting up) are skipped unless include_down is true.
static func pick_target(from: Fighter, dir: Vector3, max_dist := 14.0, include_down := false) -> Fighter:
	var origin := from.get_ground_position()
	var flat_dir := Vector3(dir.x, 0.0, dir.z)
	var use_dir := flat_dir.length() > 0.2
	if use_dir:
		flat_dir = flat_dir.normalized()
	var best: Fighter = null
	var best_score := INF
	for f in opponents_of(from):
		if not include_down and f.is_down():
			continue
		var to := f.get_ground_position() - origin
		to.y = 0.0
		var d := to.length()
		if d > max_dist:
			continue
		var score := d
		if use_dir and d > 0.01:
			# Angle off the stick dominates; distance breaks ties.
			score = (1.0 - flat_dir.dot(to / d)) * 10.0 + d * 0.15
		if score < best_score:
			best_score = score
			best = f
	return best

# --- Round 5: strike target picking (Feel Reference: Picking the target) -------
## Opponents inside Tuning.TARGET_CONE degrees (each side) of `aim_dir`, within
## Tuning.STRIKE_TARGET_RANGE (Tuning.SPRINT_TARGET_RANGE while sprinting), scored
## 0.6 x (1 - angle / cone) + 0.4 x (1 - distance / range); the highest wins.
## aim_dir is the stick in world space, or camera forward when the stick is
## neutral: the caller decides. Downed and dead fighters are never strike targets
## (bodies on the ground are targets only for ground strikes: pick_ground_target).
## Crawlers (lost a leg) are on the ground too: ground-strike targets only.
static func pick_strike_target(from: Fighter, aim_dir: Vector3, sprinting := false) -> Fighter:
	var reach := Tuning.SPRINT_TARGET_RANGE if sprinting else Tuning.STRIKE_TARGET_RANGE
	var origin := from.get_ground_position()
	var best: Fighter = null
	var best_score := -INF
	for f in opponents_of(from):
		if f.is_down() or is_crawling(f):
			continue
		var s := strike_score(origin, aim_dir, f.get_ground_position(), reach)
		if s > best_score:
			best_score = s
			best = f
	return best

## Score of a target at `target_pos` for a strike from `origin` along `aim_dir`
## (world XZ). -INF outside the cone or the range. A zero aim_dir scores by
## distance only (any direction counts).
static func strike_score(origin: Vector3, aim_dir: Vector3, target_pos: Vector3, reach: float) -> float:
	var to := target_pos - origin
	to.y = 0.0
	var d := to.length()
	if d > reach:
		return -INF
	var flat := Vector3(aim_dir.x, 0.0, aim_dir.z)
	var angle := 0.0
	if flat.length_squared() > 1e-6 and d > 0.01:
		angle = rad_to_deg(flat.normalized().angle_to(to / d))
		if angle > Tuning.TARGET_CONE:
			return -INF
	var w := Tuning.TARGET_ANGLE_WEIGHT
	return w * (1.0 - angle / Tuning.TARGET_CONE) + (1.0 - w) * (1.0 - d / maxf(reach, 0.01))

## An enemy who lost a leg and crawls (C's brain). On the floor but animated,
## so is_down() is false and its centre of mass sits about 1 m up.
static func is_crawling(f: Fighter) -> bool:
	return f != null and f.brain != null and f.brain.has_method(&"is_crawling") and f.brain.is_crawling()

## Nearest opponent on the ground (lying: is_down, or crawling; not dead) within
## max_dist, preferring ones in front along `dir`: the ground strike's target.
static func pick_ground_target(from: Fighter, dir: Vector3, max_dist := Tuning.GROUND_STRIKE_RANGE) -> Fighter:
	var origin := from.get_ground_position()
	var flat := Vector3(dir.x, 0.0, dir.z)
	var use_dir := flat.length() > 0.2
	if use_dir:
		flat = flat.normalized()
	var best: Fighter = null
	var best_score := INF
	for f in opponents_of(from):
		if not f.is_down() and not is_crawling(f):
			continue
		var to := f.get_center_of_mass() - origin
		to.y = 0.0
		var d := to.length()
		if d > max_dist:
			continue
		var score := d
		if use_dir and d > 0.01:
			score += (1.0 - flat.dot(to / d)) * 0.5
		if score < best_score:
			best_score = score
			best = f
	return best

# --- Round 7: freeflow target picking (docs/Round 7 — Freeflow Combat.md) -------
## The target of a strike, grab or counter glide at the press.
## `stick`: the stick in world space (camera-relative, zero when neutral).
## `current`: the attacker's combat target (CombatController.get_combat_target()).
## `camera_fwd`: flat camera forward, used when the stick is neutral and
## `current` is no longer valid. Stick pushed: the best opponent within
## Tuning.R7_TARGET_CONE degrees of the stick and `max_range`, scored like
## strike_score (angle 0.6, distance 0.4). Downed and dead opponents are never
## picked; crawlers, fleeing and lifted ones are.
static func pick_freeflow_target(from: Fighter, stick: Vector3, current: Fighter, camera_fwd: Vector3,
		max_range := Tuning.R7_TARGET_RANGE) -> Fighter:
	var dir := Vector3(stick.x, 0.0, stick.z)
	if dir.length() <= 0.2:
		if is_freeflow_target(from, current, max_range):
			return current
		dir = Vector3(camera_fwd.x, 0.0, camera_fwd.z)
	var origin := from.get_ground_position()
	var best: Fighter = null
	var best_score := -INF
	for f in opponents_of(from):
		if not is_freeflow_target(from, f, max_range):
			continue
		var s := freeflow_score(origin, dir, f.get_ground_position(), max_range)
		if s > best_score:
			best_score = s
			best = f
	return best

## `f` can be a freeflow target of `from`: alive, an opponent, on its feet (or
## crawling, or lifted), within `max_range` on the ground plane.
static func is_freeflow_target(from: Fighter, f: Fighter, max_range := Tuning.R7_TARGET_RANGE) -> bool:
	if f == null or not is_instance_valid(f) or f == from or f.is_dead() or f.team == from.team:
		return false
	if f.is_down():
		return false
	var to := f.get_ground_position() - from.get_ground_position()
	to.y = 0.0
	return to.length() <= max_range

## strike_score with Tuning.R7_TARGET_CONE: -INF outside the cone or `reach`;
## a zero `aim_dir` scores by distance only.
static func freeflow_score(origin: Vector3, aim_dir: Vector3, target_pos: Vector3, reach: float) -> float:
	var to := target_pos - origin
	to.y = 0.0
	var d := to.length()
	if d > reach:
		return -INF
	var flat := Vector3(aim_dir.x, 0.0, aim_dir.z)
	var angle := 0.0
	if flat.length_squared() > 1e-6 and d > 0.01:
		angle = rad_to_deg(flat.normalized().angle_to(to / d))
		if angle > Tuning.R7_TARGET_CONE:
			return -INF
	var w := Tuning.TARGET_ANGLE_WEIGHT
	return w * (1.0 - angle / Tuning.R7_TARGET_CONE) + (1.0 - w) * (1.0 - d / maxf(reach, 0.01))
