extends Node3D
## Round 5 animation ids (Feel Reference "New animations needed"; agent P):
## every move, hold, overlay and locomotion style other agents call exists;
## every keyframe names a real pose; strike bones are real bones; every
## frame-data id in Tuning has a move; the moves MoveLibrary and ComboGraph
## play still exist.
## OWNER: agent P.

const MOVES_NEEDED: Array[StringName] = [
	# Strikes
	&"jab", &"cross", &"kick", &"sweep", &"knee", &"elbow", &"ground_stomp", &"knee_drop", &"drop_strike", &"slam",
	# Movement
	&"sprint_start", &"vault_speed", &"mantle", &"wall_kickoff", &"land_three_point", &"land_roll", &"land_crouch",
	# Grab
	&"grab_lunge", &"held_knee", &"headbutt", &"throw", &"body_slam",
	# Defence
	&"parry", &"guard_push", &"sidestep_l", &"sidestep_r", &"vanish", &"appear",
	# Reactions
	&"stumble_fwd", &"stumble_back", &"stumble_side_l", &"stumble_side_r", &"getup_fast",
	# Enemies
	&"e_jab", &"e_hook", &"e_kick", &"e_grab", &"e_stick_swing", &"e_stick_thrust", &"e_heavy", &"e_charge",
	&"e_grab_slam", &"sidestep", &"guard"]
const HOLDS_NEEDED: Array[StringName] = [&"jab_charge", &"cross_charge", &"kick_charge", &"sweep_charge",
	&"throw_charge", &"carry_hold", &"hold_idle", &"guard"]
const OVERLAYS: Array[StringName] = [&"carry_hold", &"guard", &"hold_idle"]
const STYLES: Array[StringName] = [&"walk", &"sprint", &"carry", &"limp", &"crawl", &"strafe", &"wall_run_l", &"wall_run_r"]
## Feel Reference frame-data ids -> the move(s) that animate them.
const FRAME_MOVES := {&"jab": [&"jab"], &"cross": [&"cross"], &"kick": [&"kick"], &"sweep": [&"sweep"],
	&"knee": [&"knee"], &"elbow": [&"elbow"], &"ground": [&"ground_stomp", &"knee_drop"]}

var _ok := true

func _check(what: String, cond: bool, info := "") -> void:
	print("  %-58s %s %s" % [what, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _ready() -> void:
	var missing: Array = []
	for id in MOVES_NEEDED:
		if not PoseLibrary.has_move(id):
			missing.append(id)
	_check("all %d Round 5 move ids (PoseLibrary.has_move)" % MOVES_NEEDED.size(), missing.is_empty(), str(missing))
	missing.clear()
	for id in HOLDS_NEEDED:
		if not PoseLibrary.HOLDS.has(id):
			missing.append(id)
	_check("all %d Round 5 hold ids" % HOLDS_NEEDED.size(), missing.is_empty(), str(missing))
	missing.clear()
	for id in [&"jab", &"cross", &"kick", &"sweep", &"throw"]:
		var h := PoseLibrary.charge_hold_of(id)
		if h == &"" or not PoseLibrary.HOLDS[h].get("charge", false):
			missing.append(id)
	_check("charge hold (trembles per level) for jab/cross/kick/sweep/throw", missing.is_empty(), str(missing))
	# Every key names a pose ("#m" = mirrored).
	var bad_keys: Array = []
	var n_keys := 0
	for id in PoseLibrary.MOVES:
		for k in PoseLibrary.MOVES[id]["keys"]:
			n_keys += 1
			var pn := String(k[2]).trim_suffix("#m")
			if not PoseLibrary.POSES.has(StringName(pn)):
				bad_keys.append("%s:%s" % [id, k[2]])
	for id in PoseLibrary.HOLDS:
		for pn in PoseLibrary.HOLDS[id]["poses"]:
			if not PoseLibrary.POSES.has(pn):
				bad_keys.append("hold %s:%s" % [id, pn])
	_check("every keyframe / hold names a pose (%d moves, %d keys)" % [PoseLibrary.MOVES.size(), n_keys], bad_keys.is_empty(), str(bad_keys))
	var round5_listed := true
	for id in PoseLibrary.ROUND5_MOVE_IDS:
		round5_listed = round5_listed and PoseLibrary.has_move(id)
	for id in MOVES_NEEDED:
		round5_listed = round5_listed and PoseLibrary.ROUND5_MOVE_IDS.has(id)
	_check("ROUND5_MOVE_IDS lists exactly playable moves", round5_listed)
	# Strike bones.
	var bad_strike: Array = []
	for id in PoseLibrary.STRIKE_BONES:
		if not PoseLibrary.has_move(id):
			bad_strike.append(id)
		for b in PoseLibrary.STRIKE_BONES[id]:
			if not Bones.ALL.has(b):
				bad_strike.append("%s:%s" % [id, b])
	for id in [&"jab", &"cross", &"kick", &"sweep", &"knee", &"elbow", &"ground_stomp", &"knee_drop", &"drop_strike",
			&"e_jab", &"e_hook", &"e_kick", &"e_grab", &"e_stick_swing", &"e_stick_thrust", &"e_heavy", &"e_charge", &"e_grab_slam"]:
		if not PoseLibrary.STRIKE_BONES.has(id):
			bad_strike.append("no bones: %s" % id)
	_check("STRIKE_BONES: real moves, real bones, every strike listed", bad_strike.is_empty(), str(bad_strike))
	# Tuning frame data.
	var bad_frames: Array = []
	for k in Tuning.STRIKE_FRAMES:
		for id in FRAME_MOVES.get(k, [k]):
			if not PoseLibrary.has_move(id):
				bad_frames.append(id)
	for k in Tuning.ENEMY_STARTUP:
		if not PoseLibrary.has_move(k) or not PoseLibrary.STRIKE_BONES.has(k):
			bad_frames.append(k)
	_check("every Tuning.STRIKE_FRAMES / ENEMY_STARTUP id animates", bad_frames.is_empty(), str(bad_frames))
	# Older ids other modules still play.
	var legacy_missing: Array = []
	for id in PoseLibrary.ALL_MOVE_IDS:
		if not PoseLibrary.has_move(id):
			legacy_missing.append(id)
	for id in PoseLibrary.ALL_HOLD_IDS:
		if not PoseLibrary.HOLDS.has(id):
			legacy_missing.append(id)
	_check("older rounds' move and hold ids kept", legacy_missing.is_empty(), str(legacy_missing))
	_check_callers()
	# Styles and overlays are accepted.
	var host := AnimTestUtil.make_host(self)
	await get_tree().physics_frame
	var bad_api: Array = []
	for st in STYLES:
		host.anim.set_locomotion_style(st)
		await get_tree().physics_frame
		if host.anim.get_locomotion_style() != st:
			bad_api.append(st)
	for ov in OVERLAYS:
		host.anim.set_upper_overlay(ov)
		await get_tree().physics_frame
		if host.anim.get_upper_overlay() != ov:
			bad_api.append(ov)
	host.anim.set_upper_overlay(&"")
	_check("8 locomotion styles and 3 overlays accepted", bad_api.is_empty(), str(bad_api))
	print("ANIM_IDS ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

## MoveLibrary / ComboGraph (agent B) are loaded at run time so a file
## mid-rewrite elsewhere does not break this test's parse; skipped if absent.
func _check_callers() -> void:
	var ml: Script = load("res://scripts/combat/move_library.gd")
	var missing: Array = []
	var checked := 0
	if ml != null and ml.can_instantiate():
		var ids: Array = []
		for c in ["PLAYER_MOVES", "ENEMY_MOVES"]:
			var cm: Dictionary = ml.get_script_constant_map()
			ids.append_array(cm.get(c, []))
		for id in ids:
			if not bool(ml.call(&"has_move", id)):
				continue
			var m = ml.call(&"get_move", id)
			if m == null:
				continue
			checked += 1
			var anim_id: StringName = m.get(&"anim")
			if not PoseLibrary.has_move(anim_id):
				missing.append("%s->%s" % [id, anim_id])
			# Round 7 dropped charge holds from MoveData; check them only where they exist.
			var hold = m.get(&"charge_hold")
			if hold is StringName and hold != &"" and not (PoseLibrary.HOLDS.has(hold) or PoseLibrary.POSES.has(hold)):
				missing.append("%s charge %s" % [id, hold])
	var cg: Script = load("res://scripts/combat/combo_graph.gd")
	if cg != null and cg.can_instantiate() and _has_static(cg, &"default_graph"):
		var g = cg.call(&"default_graph")
		var st = g.get(&"starters") if g != null else null
		var ln = g.get(&"links") if g != null else null
		if st is Dictionary and ln is Dictionary:
			var ids: Array = (st as Dictionary).values()
			for prev in ln:
				ids.append(prev)
				var nx = ln[prev]
				if nx is Dictionary:
					ids.append_array((nx as Dictionary).values())
			for id in ids:
				checked += 1
				if not PoseLibrary.has_move(id) and not (ml != null and bool(ml.call(&"has_move", id))):
					missing.append("combo %s" % id)
	print("    MoveLibrary / ComboGraph moves checked: %d" % checked)
	_check("every MoveLibrary anim and ComboGraph move plays", missing.is_empty(), str(missing))

static func _has_static(sc: Script, method: StringName) -> bool:
	for m in sc.get_script_method_list():
		if StringName(m["name"]) == method:
			return true
	return false
