extends Node
## Upgrade 2 height mix: each archetype's picks mix HIGH / MID / LOW where it
## has the moves (LOW e_sweep only once MoveLibrary has it), never three in a
## row at one height, and Shield / Brute keep their identity.
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
	print("[ai] info: MoveLibrary has e_sweep: %s" % has_sweep)
	var names := ["HIGH", "MID", "LOW"]
	var x := -6.0
	for arch: StringName in [&"grunt", &"brawler", &"shield", &"brute", &"duelist"]:
		var e := FighterFactory.spawn_enemy(self, arch, Transform3D(Basis(), Vector3(x, 0.05, -5)))
		x += 3.0
		await get_tree().physics_frame
		var brain := e.brain as AIBrain
		var levels := {}
		var moves := {}
		var run := 0
		var max_run := 0
		var last := -1
		for i in PICKS:
			var m: StringName = brain._pick_move(1.5, player)
			var lv := AIBrain.move_level(m)
			moves[m] = moves.get(m, 0) + 1
			levels[names[lv]] = levels.get(names[lv], 0) + 1
			run = run + 1 if lv == last else 1
			last = lv
			max_run = maxi(max_run, run)
		print("[ai] info: %s picks %s heights %s" % [arch, str(moves), str(levels)])
		var allowed: Array = (e.config.get("moves", []) as Array).duplicate()
		allowed.append_array(AIBrain.MOVE_MIX.get(arch, {}).keys())
		var only_known := true
		for m: StringName in moves:
			only_known = only_known and (m in allowed) and MoveLibrary.has_move(m)
		check(only_known, "%s uses only moves it has and MoveLibrary knows" % arch)
		check(moves.has(&"e_sweep") == (has_sweep and AIBrain.MOVE_MIX[arch].has(&"e_sweep")),
			"%s: sweeps only when MoveLibrary has e_sweep and the archetype uses it" % arch)
		if levels.size() >= 2:
			check(max_run <= AIBrain.MAX_SAME_LEVEL, "%s: never %d in a row at one height (max %d)" % [arch, AIBrain.MAX_SAME_LEVEL + 1, max_run])
		match arch:
			&"grunt", &"duelist":
				check(levels.size() >= (3 if has_sweep else 2), "%s mixes heights (%d)" % [arch, levels.size()])
			&"shield":
				check(moves.keys().all(func(m): return m in [&"e_hook", &"e_heavy"]), "Shield keeps hook / heavy")
			&"brute":
				check(moves.keys().all(func(m): return m in [&"e_heavy", &"e_grab", &"e_charge"]), "Brute keeps heavy / grab")
				var far := {}
				for i in 100:
					var m2: StringName = brain._pick_move(4.0, player)
					far[m2] = far.get(m2, 0) + 1
				check(far.get(&"e_charge", 0) > 50, "Brute charges from range (%s)" % str(far))
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

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_heights: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
