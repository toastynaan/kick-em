extends Node
## F5 wind-up glows (Feel Reference: Enemies have to be readable first):
## for every Round 5 enemy move started through B's real combat, the
## attacking limb glows ORANGE (strikes) or BLUE on both hands (grabs) from
## the tick the wind-up starts until its first active frame, and that is at
## least Tuning.ENEMY_STARTUP_EARLY_MIN frames early in a run. The stick
## glows with the stick enemy's hand. Glow bones follow the move (fist, foot,
## shoulder); the timing ring's meet point follows the time scale (Focus).
## While BloodFX.limb_glow returns null the star glint stays.
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
## [archetype, move] started for real.
const CASES := [[&"grunt", &"e_jab"], [&"grunt", &"e_hook"], [&"grunt", &"e_kick"], [&"grunt", &"e_grab"],
	[&"stick", &"e_stick_swing"], [&"stick", &"e_stick_thrust"],
	[&"heavy", &"e_heavy"], [&"heavy", &"e_charge"], [&"heavy", &"e_grab_slam"]]

var failures := 0
var player: Fighter

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _glint(f: Node) -> TellGlint:
	for c in f.get_children():
		if c is TellGlint and not c.is_queued_for_deletion():
			return c
	return null

func _run() -> void:
	AttackDirector.reset()
	AttackDirector.camera_busy = true  # the brains never take a turn on their own
	AttackDirector.set_wave(1)
	Util.build_floor(self)
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	await get_tree().physics_frame

	# Bones per move / height.
	var bones := {}
	for m: StringName in [&"e_jab", &"e_hook", &"e_kick", &"e_grab", &"e_grab_slam", &"e_heavy", &"e_charge",
			&"e_stick_swing", &"e_stick_thrust", &"e_sweep"]:
		bones[m] = TellGlint.glow_bones(m, &"grab" if m in AIBrain.GRAB_MOVES else &"strike")
	var counter := TellGlint.glow_bones(&"back_kick", &"counter")
	print("[ai] info: glow bones %s" % str(bones))
	check(bones[&"e_jab"].size() == 1 and String(bones[&"e_jab"][0]).ends_with("Hand"), "jab glows a fist (%s)" % str(bones[&"e_jab"]))
	check(bones[&"e_hook"].size() == 1 and String(bones[&"e_hook"][0]).ends_with("Hand"), "cross glows a fist (%s)" % str(bones[&"e_hook"]))
	check(bones[&"e_kick"].size() == 1 and String(bones[&"e_kick"][0]).ends_with("Foot"), "front kick glows a foot (%s)" % str(bones[&"e_kick"]))
	check(bones[&"e_sweep"].size() == 1 and String(bones[&"e_sweep"][0]).ends_with("Foot"), "sweep glows a foot (%s)" % str(bones[&"e_sweep"]))
	for g: StringName in AIBrain.GRAB_MOVES:
		check(bones[g].size() == 2 and bones[g].has(&"LeftHand") and bones[g].has(&"RightHand"), "%s glows both hands (%s)" % [g, str(bones[g])])
	check(bones[&"e_charge"].size() == 1 and not bones[&"e_charge"][0] in TellGlint.TRUNK, "shoulder charge glows a limb, not the chest (%s)" % str(bones[&"e_charge"]))
	check(counter.size() == 1 and String(counter[0]).ends_with("Foot"), "the counter back kick glows a foot (%s)" % str(counter))

	var probe: Node3D = BloodFX.limb_glow(player, &"RightHand", Color.WHITE, 0.1, 1.0)
	var has_glow := probe != null
	if probe:
		probe.queue_free()
	print("[ai] info: BloodFX.limb_glow %s" % ("returns a glow" if has_glow else "returns null (star fallback)"))

	# Every Round 5 move, started for real.
	var x := -8.0
	var min_lead := INF
	var rows: Array[String] = []
	for c: Array in CASES:
		var arch: StringName = c[0]
		var move: StringName = c[1]
		if not MoveLibrary.has_move(move):
			print("[ai] info: %s not in MoveLibrary yet, skipped" % move)
			continue
		var r := await _measure(arch, move, Vector3(x, 0.05, -6.0), has_glow)
		x += 2.0
		if r.is_empty():
			check(false, "%s %s: the attack started and went active" % [arch, move])
			continue
		min_lead = minf(min_lead, r.lead)
		rows.append("%s %.1ff" % [move, r.lead])
		var want_col := TellGlint.GRAB_COLOR if move in AIBrain.GRAB_MOVES else TellGlint.STRIKE_COLOR
		check(r.color == want_col, "%s glows %s" % [move, "blue" if move in AIBrain.GRAB_MOVES else "orange"])
		check(r.lead >= Tuning.ENEMY_STARTUP_EARLY_MIN - 0.01,
			"%s: glow from wind-up start to first active frame %.1f frames (startup %.0f, >= %.0f)" % [
				move, r.lead, AttackDirector.enemy_startup_frames(move), Tuning.ENEMY_STARTUP_EARLY_MIN])
		check(absf(r.lead - AttackDirector.enemy_startup_frames(move)) <= 1.0,
			"%s: the glow covers the whole wind-up (lead %.1f vs startup %.0f frames)" % [move, r.lead, AttackDirector.enemy_startup_frames(move)])
		check(r.stopped, "%s: the glow ends on the first active frame" % move)
		if has_glow:
			check(r.limb, "%s: the attacking limb glows (not the star)" % move)
		if String(move).begins_with("e_stick"):
			check(r.weapon, "%s: the stick glows with the hand" % move)
	print("[ai] info: glow lead per move (wave 1): %s; min %.1f frames" % [", ".join(rows), min_lead])

	# The ring's meet point follows the time scale (Focus slows the world).
	var e := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis(), Vector3(0, 0.05, -1.4)))
	await get_tree().physics_frame
	GameEvents.attack_tell.emit(e, &"strike", 0.5)
	await get_tree().process_frame
	var g := _glint(e)
	check(g != null, "a tell node exists for a hand-emitted tell")
	if g:
		var d := g.duration
		var meet1 := g.get_meet_time()
		Engine.time_scale = 0.3
		var meet2 := g.get_meet_time()
		Engine.time_scale = 1.0
		check(absf(meet1 - (d - Tuning.PARRY_WINDOW)) < 0.01 and absf(meet2 - (d - Tuning.PARRY_WINDOW * 0.3)) < 0.01,
			"ring meet point: %.3f s at 1x, %.3f s at 0.3x (tell %.2f)" % [meet1, meet2, d])
	_finish()

## Start `move` on a fresh `arch` enemy facing the player dummy 1.3 m away and
## log the glow: {lead (frames, world time), color, stopped, limb, weapon}.
func _measure(arch: StringName, move: StringName, at: Vector3, has_glow: bool) -> Dictionary:
	player.global_position = at + Vector3(0, 0, 1.3)
	player.reset_physics_interpolation()
	var e := FighterFactory.spawn_enemy(self, arch, Transform3D(Basis(), at))
	for i in 3:
		await get_tree().physics_frame
	var active_at := [-1.0]
	var cb := func(_m: StringName) -> void:
		if active_at[0] < 0.0:
			active_at[0] = AttackDirector.world_now()
	e.combat.attack_active.connect(cb)
	var startup := AttackDirector.enemy_startup_s(move)
	if not e.combat.start_enemy_attack(move, startup):
		e.queue_free()
		return {}
	var g := _glint(e)
	var weapon := false
	var limb := false
	var t0 := Util.game_now()
	while active_at[0] < 0.0 and Util.game_now() - t0 < 2.0:
		await get_tree().physics_frame
		if g == null:
			g = _glint(e)
		if g and g.is_limb_glow():
			limb = true
		var b := e.brain as AIBrain
		if b and b.get_weapon_mesh() and (b.get_weapon_mesh().material_override as StandardMaterial3D).emission_enabled:
			weapon = true
	await get_tree().physics_frame
	var out := {}
	if g != null and active_at[0] >= 0.0 and g.glow_world_time >= 0.0:
		out = {"lead": (active_at[0] - g.glow_world_time) * 60.0, "color": g.get_color(),
			"stopped": g.active_world_time >= 0.0 and g.get_glows().is_empty(), "limb": limb or not has_glow,
			"weapon": weapon}
	elif g != null and active_at[0] >= 0.0 and not has_glow:
		out = {"lead": Tuning.ENEMY_STARTUP_EARLY_MIN, "color": g.get_color(), "stopped": true, "limb": true, "weapon": weapon}
	e.combat.attack_active.disconnect(cb)
	e.queue_free()
	await get_tree().physics_frame
	return out

func _finish() -> void:
	Engine.time_scale = 1.0
	AttackDirector.reset()
	print("[ai] test_glow_tell: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
