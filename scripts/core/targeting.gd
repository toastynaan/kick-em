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
