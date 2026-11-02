extends Node
## Move picks per archetype. Round 5 roster (Feel Reference: Enemy types):
## grunt jab-cross string (e_jab then e_hook), front kick, grab; stick swing /
## thrust (grunt moves once he drops the stick); heavy smash, grab-and-slam,
## shoulder charge from range. Every archetype uses only moves it has and
## MoveLibrary knows, mixes heights where it has them, and never picks a
## third attack in a row at one height. Legacy archetypes keep their Upgrade 2
## mixes (LOW e_sweep once MoveLibrary has it; Shield / Brute identity).
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const PICKS := 300

var failures := 0

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	AttackDirector.camera_busy = true  # brains pick, nobody attacks
	Util.build_floor(self)
	var player := FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	var has_sweep := MoveLibrary.has_move(&"e_sweep")
	print("[ai] info: MoveLibrary has e_sweep: %s, e_jab: %s, e_stick_swing: %s, e_grab_slam: %s" % [
		has_sweep, MoveLibrary.has_move(&"e_jab"), MoveLibrary.has_move(&"e_stick_swing"), MoveLibrary.has_move(&"e_grab_slam")])
	var names := ["HIGH", "MID", "LOW"]
	var x := -8.0
	for arch: StringName in [&"grunt", &"stick", &"heavy", &"brawler", &"shield", &"brute", &"duelist"]:
		var e := FighterFactory.spawn_enemy(self, arch, Transform3D(Basis(), Vector3(x, 0.05, -5)))
		x += 2.5
		await get_tree().physics_frame
		var brain := e.brain as AIBrain
		var r := _picks(brain, player, 1.5)
		var moves: Dictionary = r[0]
		var levels: Dictionary = r[1]
		var max_run: int = r[2]
		var strings: int = r[3]
		print("[ai] info: %s picks %s heights %s (strings %d)" % [arch, str(moves), str(levels), strings])
		var allowed: Array = (e.config.get("moves", []) as Array).duplicate()
		allowed.append_array(AIBrain.MOVE_MIX.get(arch, {}).keys())
		for m: StringName in AIBrain.MOVE_FALLBACK:
			if m in allowed:
				allowed.append(AIBrain.MOVE_FALLBACK[m])
		var only_known := true
		for m: StringName in moves:
			only_known = only_known and (m in allowed) and MoveLibrary.has_move(m)
		check(only_known, "%s uses only moves it has and MoveLibrary knows" % arch)
		if levels.size() >= 2:
			check(max_run <= AIBrain.MAX_SAME_LEVEL, "%s: never %d picks in a row at one height (max %d)" % [arch, AIBrain.MAX_SAME_LEVEL + 1, max_run])
		match arch:
			&"grunt":
				check(levels.size() >= 2, "grunt mixes heights (%d)" % levels.size())
				if MoveLibrary.has_move(&"e_jab"):
					check(moves.has(&"e_jab") and moves.has(&"e_kick") and moves.has(&"e_grab") and not moves.has(&"e_sweep"),
						"grunt: jab-cross, front kick and grab, no sweep (%s)" % str(moves))
					check(strings == moves.get(&"e_jab", 0), "grunt: every jab opens the jab-cross string (%d of %d)" % [strings, moves.get(&"e_jab", 0)])
			&"stick":
				check(moves.keys().all(func(m): return String(m).begins_with("e_stick") or m in AIBrain.MOVE_FALLBACK.values()),
					"stick: swings and thrusts while armed (%s)" % str(moves))
				brain._drop_stick(Vector3.ZERO)
				await get_tree().physics_frame
				var r2 := _picks(brain, player, 1.5)
				var unarmed: Dictionary = r2[0]
				var grunt_moves: Array = Tuning.ARCHETYPES[&"grunt"]["moves"]
				check(not brain.has_stick() and unarmed.keys().all(func(m): return m in grunt_moves),
					"stick: grunt moves once the stick is gone (%s)" % str(unarmed))
			&"heavy":
				check(moves.keys().all(func(m): return m in [&"e_heavy", &"e_grab_slam", &"e_grab", &"e_charge"]),
					"heavy: smash and grab-and-slam up close (%s)" % str(moves))
				check(not moves.has(&"e_charge"), "heavy: no shoulder charge from 1.5 m")
				var far := {}
				for i in 200:
					var m2: StringName = brain._pick_move(4.0, player)
					far[m2] = far.get(m2, 0) + 1
				var share := float(far.get(&"e_charge", 0)) / 200.0
				check(share > AIBrain.HEAVY_CHARGE_CHANCE - 0.15 and share < AIBrain.HEAVY_CHARGE_CHANCE + 0.15,
					"heavy: shoulder-charges from range %.0f%% of the time (%s)" % [share * 100.0, str(far)])
			&"brawler", &"duelist":
				check(levels.size() >= (3 if has_sweep else 2), "%s mixes heights (%d)" % [arch, levels.size()])
				check(moves.has(&"e_sweep") == has_sweep, "%s: sweeps only when MoveLibrary has e_sweep" % arch)
			&"shield":
				check(moves.keys().all(func(m): return m in [&"e_hook", &"e_heavy"]), "Shield keeps hook / heavy")
			&"brute":
				check(moves.keys().all(func(m): return m in [&"e_heavy", &"e_grab", &"e_charge"]), "Brute keeps heavy / grab")
				var far_b := {}
				for i in 100:
					var m3: StringName = brain._pick_move(4.0, player)
					far_b[m3] = far_b.get(m3, 0) + 1
				check(far_b.get(&"e_charge", 0) > 50, "Brute charges from range (%s)" % str(far_b))
	# Heights: MoveData.hit_level once B tags a move, the spec's table before.
	for m: StringName in AIBrain.MOVE_LEVEL_FALLBACK:
		if MoveLibrary.has_move(m):
			var b_level: int = MoveLibrary.get_move(m).hit_level
			var tagged := b_level != HitInfo.Level.MID
			print("[ai] info: %s height %s (%s)" % [m, names[AIBrain.move_level(m)],
				"MoveData.hit_level" if tagged else "spec table; MoveData still MID"])
			if tagged:
				check(AIBrain.move_level(m) == b_level, "%s height from MoveData.hit_level" % m)
	_finish()

## PICKS picks at `dist`: [moves, heights, longest same-height run, strings opened].
func _picks(brain: AIBrain, player: Fighter, dist: float) -> Array:
	var names := ["HIGH", "MID", "LOW"]
	var levels := {}
	var moves := {}
	var run := 0
	var max_run := 0
	var last := -1
	var strings := 0
	for i in PICKS:
		var m: StringName = brain._pick_move(dist, player)
		if not brain._string_rest.is_empty() and brain._string_rest[0] == &"e_hook":
			strings += 1
		var lv := AIBrain.move_level(m)
		moves[m] = moves.get(m, 0) + 1
		levels[names[lv]] = levels.get(names[lv], 0) + 1
		run = run + 1 if lv == last else 1
		last = lv
		max_run = maxi(max_run, run)
	return [moves, levels, max_run, strings]

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_heights: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
