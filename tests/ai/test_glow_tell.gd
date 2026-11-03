extends Node
## Round 7 tells (docs/Round 7 — Freeflow Combat.md: Enemies; Defence >
## Counter): every enemy move started through B's real combat, the way the
## brain starts it, at waves 1-4 and in Duel (wave 0):
## - its limb glows from the tick the wind-up starts until its first active
##   frame, and that lasts at least Tuning.R7_COUNTER_WINDOW +
##   Tuning.R7_TELL_MARGIN real seconds (measured on the world clock at 1x);
## - the glow is ORANGE when the player can Counter the move and BLUE when he
##   cannot (grabs, the heavy's shoulder charge: MoveData.counterable, B), and
##   B's GameEvents.counter_window agrees (counterable flag, opening at least
##   the margin after the glow starts) once B emits it;
## - grabs glow both hands, the charge the shoulder, the stick with the hand.
## Also: AttackDirector.enemy_startup_frames() never under the minimum at any
## wave 0..12, and the timing ring meets the glow when the answer's window
## opens (counter window on orange, dodge invulnerability on blue), following
## the time scale. While BloodFX.limb_glow returns null the star stays.
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
## [archetype, move] started for real (every enemy move of the Waves roster
## and the Duelist).
const CASES := [[&"grunt", &"e_jab"], [&"grunt", &"e_hook"], [&"grunt", &"e_kick"], [&"grunt", &"e_grab"],
	[&"stick", &"e_stick_swing"], [&"stick", &"e_stick_thrust"],
	[&"heavy", &"e_heavy"], [&"heavy", &"e_charge"], [&"heavy", &"e_grab_slam"],
	[&"duelist", &"e_hook"], [&"duelist", &"e_kick"], [&"duelist", &"e_heavy"], [&"duelist", &"e_grab"],
	[&"duelist", &"e_sweep"]]
## Waves checked (0 = Duel).
const WAVES := [1, 2, 3, 4, 0]
## Moves the Round 7 doc makes uncounterable (blue).
const BLUE: Array[StringName] = [&"e_grab", &"e_grab_slam", &"e_charge"]

var failures := 0
var player: Fighter
var windows := {}   ## attacker -> [world time opened, counterable] of B's first counter_window

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
	Util.build_floor(self)
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	GameEvents.counter_window.connect(func(attacker: Node3D, _t: Node3D, open: bool, counterable: bool) -> void:
		if open and not windows.has(attacker):
			windows[attacker] = [AttackDirector.world_now(), counterable])
	await get_tree().physics_frame
	var need := Tuning.R7_COUNTER_WINDOW + Tuning.R7_TELL_MARGIN
	print("[ai] info: minimum tell %.3f s (window %.2f + margin %.2f) = %.0f frames" % [
		need, Tuning.R7_COUNTER_WINDOW, Tuning.R7_TELL_MARGIN, AttackDirector.tell_min_frames()])

	# Startup table at every wave (cheap: no fighters).
	var low := INF
	var low_at := ""
	for w in 13:
		AttackDirector.set_wave(w)
		for m: StringName in Tuning.ENEMY_STARTUP.keys() + AttackDirector.LEGACY_STARTUP.keys():
			var f := AttackDirector.enemy_startup_frames(m)
			if f < low:
				low = f
				low_at = "%s wave %d" % [m, w]
	check(Tuning.frames(low) >= need - 1e-6, "enemy_startup_frames never under %.0f frames at waves 0-12 (lowest %.0f: %s)" % [
		need * 60.0, low, low_at])

	# Colour rule per move (B's MoveData.counterable, or the fallback list).
	var has_field := MoveLibrary.has_move(&"e_jab") and &"counterable" in MoveLibrary.get_move(&"e_jab")
	print("[ai] info: MoveData.counterable %s" % ("is in B's MoveData" if has_field else "not in MoveData yet: TellGlint.UNCOUNTERABLE_FALLBACK decides"))
	for c: Array in CASES:
		var mv: StringName = c[1]
		var want := not mv in BLUE
		check(TellGlint.is_counterable(mv) == want, "%s is %s" % [mv, "counterable (orange)" if want else "uncounterable (blue)"])

	# Bones per move / height.
	var bones := {}
	for m: StringName in [&"e_jab", &"e_hook", &"e_kick", &"e_grab", &"e_grab_slam", &"e_heavy", &"e_charge",
			&"e_stick_swing", &"e_stick_thrust", &"e_sweep"]:
		bones[m] = TellGlint.glow_bones(m, &"grab" if m in AIBrain.GRAB_MOVES else &"strike")
	print("[ai] info: glow bones %s" % str(bones))
	check(bones[&"e_jab"].size() == 1 and String(bones[&"e_jab"][0]).ends_with("Hand"), "jab glows a fist (%s)" % str(bones[&"e_jab"]))
	check(bones[&"e_hook"].size() == 1 and String(bones[&"e_hook"][0]).ends_with("Hand"), "cross glows a fist (%s)" % str(bones[&"e_hook"]))
	check(bones[&"e_kick"].size() == 1 and String(bones[&"e_kick"][0]).ends_with("Foot"), "front kick glows a foot (%s)" % str(bones[&"e_kick"]))
	check(bones[&"e_sweep"].size() == 1 and String(bones[&"e_sweep"][0]).ends_with("Foot"), "sweep glows a foot (%s)" % str(bones[&"e_sweep"]))
	for g: StringName in AIBrain.GRAB_MOVES:
		check(bones[g].size() == 2 and bones[g].has(&"LeftHand") and bones[g].has(&"RightHand"), "%s glows both hands (%s)" % [g, str(bones[g])])
	check(bones[&"e_charge"].size() == 1 and not bones[&"e_charge"][0] in TellGlint.TRUNK, "shoulder charge glows a limb, not the chest (%s)" % str(bones[&"e_charge"]))

	var probe: Node3D = BloodFX.limb_glow(player, &"RightHand", Color.WHITE, 0.1, 1.0)
	var has_glow := probe != null
	if probe:
		probe.queue_free()
	print("[ai] info: BloodFX.limb_glow %s" % ("returns a glow" if has_glow else "returns null (star fallback)"))

	# Every move, started for real, at waves 1-4 and in Duel.
	var min_lead := INF
	var min_at := ""
	var measured := 0
	var window_seen := 0
	var win_lo := INF
	var win_hi := -INF
	for w: int in WAVES:
		AttackDirector.set_wave(w)
		var x := -12.0
		var rows: Array[String] = []
		for c: Array in CASES:
			var arch: StringName = c[0]
			var move: StringName = c[1]
			if not MoveLibrary.has_move(move):
				print("[ai] info: %s not in MoveLibrary, skipped" % move)
				continue
			var r := await _measure(arch, move, Vector3(x, 0.05, -6.0), has_glow)
			x += 2.0
			var tag := "wave %d %s %s" % [w, arch, move]
			if r.is_empty():
				check(false, "%s: the attack started and went active" % tag)
				continue
			measured += 1
			if r.lead < min_lead:
				min_lead = r.lead
				min_at = tag
			rows.append("%s %.3f" % [move, r.lead])
			var blue := move in BLUE
			check(r.lead >= need - 1e-4, "%s: glow to first active frame %.3f s >= %.3f" % [tag, r.lead, need])
			check(r.color == (TellGlint.GRAB_COLOR if blue else TellGlint.STRIKE_COLOR),
				"%s glows %s" % [tag, "blue" if blue else "orange"])
			check(r.stopped, "%s: the glow ends on the first active frame" % tag)
			if has_glow:
				check(r.limb, "%s: the attacking limb glows (not the star)" % tag)
			if String(move).begins_with("e_stick"):
				check(r.weapon, "%s: the stick glows with the hand" % tag)
			if r.window_open >= 0.0:
				window_seen += 1
				win_lo = minf(win_lo, r.window_open)
				win_hi = maxf(win_hi, r.window_open)
				check(r.window_counterable == not blue,
					"%s: B's counter_window says counterable=%s, the tell is %s" % [tag, r.window_counterable, "blue" if blue else "orange"])
				check(r.window_open >= Tuning.R7_TELL_MARGIN - 1e-4,
					"%s: the counter window opens %.3f s after the glow (>= margin %.2f)" % [tag, r.window_open, Tuning.R7_TELL_MARGIN])
		print("[ai] info: wave %d glow to first active frame (s): %s" % [w, ", ".join(rows)])
	print("[ai] info: %d attacks measured; shortest tell %.3f s (%s), needed %.3f s; B's counter_window seen on %d, opening %.3f-%.3f s after the glow" % [
		measured, min_lead, min_at, need, window_seen, win_lo, win_hi])
	if window_seen == 0:
		print("[ai] info: B emits no GameEvents.counter_window yet: the window cross-check waits for B")
	else:
		check(window_seen == measured, "B's counter window opened on every measured attack (%d / %d)" % [window_seen, measured])
	check(measured >= WAVES.size() * (CASES.size() - 1), "measured every move at every wave (%d)" % measured)

	# The ring meets the glow when the answer's window opens, at any time scale.
	var e := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis(), Vector3(0, 0.05, -1.4)))
	await get_tree().physics_frame
	for kind: StringName in [&"strike", &"grab"]:
		GameEvents.attack_tell.emit(e, kind, 0.6)
		await get_tree().process_frame
		var g := _glint(e)
		check(g != null, "a tell node exists for a hand-emitted %s tell" % kind)
		if g:
			var win := Tuning.R7_COUNTER_WINDOW if kind == &"strike" else Tuning.R7_DODGE_INVULN
			var d := g.duration
			var meet1 := g.get_meet_time()
			Engine.time_scale = 0.3
			var meet2 := g.get_meet_time()
			Engine.time_scale = 1.0
			check(absf(meet1 - (d - win)) < 0.01 and absf(meet2 - (d - win * 0.3)) < 0.01,
				"%s ring meets at the %s window: %.3f s at 1x, %.3f s at 0.3x (tell %.2f)" % [
					kind, "counter" if kind == &"strike" else "dodge", meet1, meet2, d])
			g.queue_free()
		await get_tree().process_frame
	_finish()

## Start `move` on a fresh `arch` enemy facing the player dummy 1.3 m away,
## the way AIBrain._try_start does (the brain names the move, then B starts
## it with the brain's startup), and log the glow: {lead (real s at 1x),
## color, stopped, limb, weapon, window_open (s after the glow, -1 without B's
## event), window_counterable}.
func _measure(arch: StringName, move: StringName, at: Vector3, has_glow: bool) -> Dictionary:
	# The dummy stays a standing, live target (invulnerable: the hits miss).
	var tw := Util.game_now()
	while (player.is_down() or player.is_in_hitstun()) and Util.game_now() - tw < 5.0:
		_keep_player()
		await get_tree().physics_frame
	_keep_player()
	player.global_position = at + Vector3(0, 0, 1.3)
	player.reset_physics_interpolation()
	# Facing the player (+Z), so B's counter window has its target from the start.
	var e := FighterFactory.spawn_enemy(self, arch, Transform3D(Basis.looking_at(Vector3.BACK, Vector3.UP), at))
	for i in 3:
		await get_tree().physics_frame
	var active_at := [-1.0]
	var cb := func(_m: StringName) -> void:
		if active_at[0] < 0.0:
			active_at[0] = AttackDirector.world_now()
	e.combat.attack_active.connect(cb)
	var b := e.brain as AIBrain
	var startup := b._startup_for(move)
	b._tell_move = move
	if not e.combat.start_enemy_attack(move, startup):
		b._tell_move = &""
		e.queue_free()
		return {}
	var g := _glint(e)
	var weapon := false
	var limb := false
	var t0 := Util.game_now()
	while active_at[0] < 0.0 and Util.game_now() - t0 < 2.0:
		_keep_player()
		await get_tree().physics_frame
		if g == null:
			g = _glint(e)
		if g and g.is_limb_glow():
			limb = true
		if b.get_weapon_mesh() and (b.get_weapon_mesh().material_override as StandardMaterial3D).emission_enabled:
			weapon = true
	await get_tree().physics_frame
	var out := {}
	if g != null and active_at[0] >= 0.0:
		var glow_t := g.glow_world_time if g.glow_world_time >= 0.0 else g._spawn_world
		out = {"lead": active_at[0] - glow_t, "color": g.get_color(),
			"stopped": g.active_world_time >= 0.0 and g.get_glows().is_empty(), "limb": limb or not has_glow,
			"weapon": weapon, "window_open": -1.0, "window_counterable": true}
		if windows.has(e):
			out["window_open"] = float(windows[e][0]) - glow_t
			out["window_counterable"] = bool(windows[e][1])
	e.combat.attack_active.disconnect(cb)
	e.queue_free()
	await get_tree().physics_frame
	return out

func _keep_player() -> void:
	if "invuln_until" in player:
		player.set(&"invuln_until", TimeDirector.now() + 5.0)
	if player.hp < player.max_hp * 0.5:
		player.heal_fraction(1.0)

func _finish() -> void:
	Engine.time_scale = 1.0
	AttackDirector.reset()
	print("[ai] test_glow_tell: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
