extends Node
## Round 5 roster behaviours (Feel Reference: Enemy types; F5):
## A. Stick enemy: holds a visible stick in his right hand; a flinch keeps it;
##    a stagger (a real tapped cross when B's strike lands, else a stagger
##    hit event) knocks it out of his hand as D's ThrowableProp &"stick" with
##    the hand's velocity; it can be picked up (can_pick_up(), and through the
##    player's Carry, forced on for the test while G's switch is off); he
##    fights on with the grunt's moves.
## C. Grunt: guards Tuning.GUARD_TAP_CHANCE of the tapped punches aimed at
##    him (jab, cross, hook). Round 8: every tap is guardable (the kicks, gut
##    punch and uppercut too, at the same chance); a charged strike (B's
##    strike_started charge_level >= 1, same id) breaks a guard, so never one,
##    nor a Round 7 heavy id or an older charged strike; a plain guard, never
##    a parry. Round 8: the stick enemy and the heavy guard tapped strikes at
##    their own "guard_chance" x AIBrain.block_mult() (measured like the
##    grunt's), never a charged one.
## D. Breaking the player's grab (G's Carry asks wants_grab_break): per
##    archetype rate (heavies more), never while stunned, reacting or
##    fleeing, likelier for each recent grab on him; Round 7: never once the
##    clinch has connected (the grabber holds the body) nor during a drive.
## (Round 7 removed part B, the sidestep of sprint strikes.)
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const FakeCarry := preload("res://tests/ai/fake_carry.gd")
const GUARD_TRIALS := 300
## Round 7 heavy ids (Tuning.R7_MOVES "guard_break"): never guarded.
const BREAKERS: Array[StringName] = [&"heavy_jab", &"heavy_cross", &"heavy_hook"]
## Round 8 strikes other than the punches: guarded tapped, never charged.
const R8_OTHERS: Array[StringName] = [&"gut_punch", &"uppercut", &"leg_kick", &"front_kick", &"roundhouse"]

var failures := 0
var player: Fighter

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	AttackDirector.camera_busy = true  # nobody takes an attack turn
	Tuning.difficulty = Tuning.Difficulty.NORMAL
	Util.build_floor(self)
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	await _wait(0.2)
	await _part_stick()
	await _part_guard()
	await _part_grab_break()
	_finish()

# --- A. The stick ------------------------------------------------------------------

func _part_stick() -> void:
	var e := FighterFactory.spawn_enemy(self, &"stick", Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3(0, 0.05, -1.25)))
	var brain := e.brain as AIBrain
	await _wait(0.3)
	var att := e.rig.get_attachment(&"RightHand")
	var mesh := brain.get_weapon_mesh()
	check(brain.has_stick() and mesh != null and mesh.get_parent() == att and mesh.visible and mesh.layers == Layers.VIS_CHARACTERS,
		"stick enemy holds a visible stick on his right hand attachment")
	if mesh:
		var tip := mesh.global_transform * Vector3(0, AIBrain.STICK_LENGTH * 0.5, 0)
		print("[ai] info: stick length %.2f m, tip %.2f m from the fist" % [AIBrain.STICK_LENGTH,
			tip.distance_to(e.rig.get_fist_position(&"RightHand"))])
	# A flinch keeps it.
	var flinch := HitInfo.new()
	flinch.attacker = player
	flinch.victim = e
	flinch.tier = HitInfo.Tier.FLINCH
	flinch.hit_direction = Vector3.FORWARD
	GameEvents.hit_landed.emit(flinch)
	check(brain.has_stick(), "a flinch does not make him drop it")
	# A real tapped cross (P 2.0: stagger) when B's strike lands it.
	var landed: Array = []
	var on_hit := func(i: HitInfo) -> void:
		if i.victim == e: landed.append(i.tier)
	GameEvents.hit_landed.connect(on_hit)
	var path := "real cross"
	for attempt in 6:
		if not brain.has_stick():
			break
		await _settle(e)
		_face(player, e)
		player.combat.press(CombatController.Action.HEAVY)
		await get_tree().physics_frame
		player.combat.release(CombatController.Action.HEAVY)
		await _wait(0.6)
	GameEvents.hit_landed.disconnect(on_hit)
	print("[ai] info: real strikes on the stick enemy landed tiers %s" % str(landed.map(func(t): return HitInfo.tier_name(t))))
	if brain.has_stick():
		path = "stagger hit event (no real stagger landed)"
		var st := HitInfo.new()
		st.attacker = player
		st.victim = e
		st.tier = HitInfo.Tier.STAGGER
		st.hit_direction = Vector3.FORWARD
		GameEvents.hit_landed.emit(st)
	var prop := brain.dropped_stick as ThrowableProp
	check(not brain.has_stick() and prop != null and is_instance_valid(prop) and prop.is_inside_tree() and prop.kind == &"stick",
		"a stagger drops the stick as a ThrowableProp &\"stick\" (%s)" % path)
	if prop == null or not is_instance_valid(prop):
		return
	var v0 := prop.linear_velocity
	check(v0.length() > 1.0, "the stick leaves the hand moving (%.1f m/s)" % v0.length())
	check(att.get_node_or_null(^"Stick") == null, "the stick mesh is gone from his hand")
	var grunt_moves: Array = Tuning.ARCHETYPES[&"grunt"]["moves"]
	var picks := {}
	for i in 60:
		var m: StringName = brain._pick_move(1.4, player)
		picks[m] = picks.get(m, 0) + 1
	check(picks.keys().all(func(m): return m in grunt_moves), "unarmed he fights with the grunt's moves (%s)" % str(picks))
	# It lands and can be picked up.
	var t0 := Util.game_now()
	while Util.game_now() - t0 < 3.0 and prop.linear_velocity.length() > 0.2:
		await get_tree().physics_frame
	await _wait(0.3)
	check(prop.global_position.y < 0.4, "the stick comes to rest on the floor (y %.2f)" % prop.global_position.y)
	check(prop.can_pick_up() and not prop.is_held(), "ThrowableProp.can_pick_up() is true")
	# Through the player's Carry (G). Its switch is off until G enables it, so
	# the test forces it on (Carry.force_enabled) and restores it.
	e.global_position = Vector3(8, 0.05, 8)
	e.reset_physics_interpolation()
	await _wait(0.3)
	var carry := player.carry
	var carry_script: Script = Carry
	var was_forced: Variant = carry_script.get(&"force_enabled")  # null: G has no test switch
	var had_force := was_forced != null
	if not carry.is_enabled() and had_force:
		carry_script.set(&"force_enabled", true)
	if carry.is_enabled():
		var to := prop.global_position - Vector3(0, prop.global_position.y, 0)
		var dir := Vector3(1, 0, 0)
		player.global_position = to - dir * 0.7 + Vector3(0, 0.05, 0)
		player.reset_physics_interpolation()
		player.snap_facing(dir)
		player.face_dir = dir
		await _wait(0.2)
		player.combat.press(CombatController.Action.GRAB)
		await _wait(0.1)
		player.combat.release(CombatController.Action.GRAB)
		await _wait(0.4)
		check(prop.is_held() and carry.held == prop, "the player picks the stick up with Grab (Carry holds %s)" % str(carry.held))
		if carry.is_holding():
			carry.drop(&"release")
	else:
		print("[ai] info: Carry is not enabled and cannot be forced: pick-up through Carry not checked")
	if had_force:
		carry_script.set(&"force_enabled", was_forced)
	e.queue_free()
	await _wait(0.2)

# --- C. Tap guards ------------------------------------------------------------------

func _part_guard() -> void:
	player.global_position = Vector3(0, 0.05, 0)
	player.reset_physics_interpolation()
	var g := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3(0, 0.05, -1.5)))
	var s := FighterFactory.spawn_enemy(self, &"stick", Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3(3, 0.05, -1.5)))
	var h := FighterFactory.spawn_enemy(self, &"heavy", Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3(-3, 0.05, -1.5)))
	await _wait(0.5)
	var gb := g.brain as AIBrain
	var guards := 0
	var blocked_up := 0
	var taps: Array[StringName] = Tuning.R7_PUNCH_STRING
	for i in GUARD_TRIALS:
		await _clear_guard(g, gb)
		var before := gb.tap_guards
		GameEvents.strike_started.emit(player, g, taps[i % taps.size()], false, 0)
		if gb.tap_guards > before:
			guards += 1
			await get_tree().physics_frame
			if g.combat.is_blocking():
				blocked_up += 1
	var p := float(guards) / GUARD_TRIALS
	check(absf(p - Tuning.GUARD_TAP_CHANCE) <= 0.07,
		"grunt guards %d of %d tapped punches (jab, cross, hook: %.0f%%, target %.0f%%)" % [guards, GUARD_TRIALS, p * 100.0, Tuning.GUARD_TAP_CHANCE * 100.0])
	check(guards > 0 and blocked_up == guards, "every guard raises his block at once (%d / %d)" % [blocked_up, guards])
	var breakers := 0
	var all_moves: Array[StringName] = []
	all_moves.append_array(Tuning.R7_PUNCH_STRING)
	all_moves.append_array(R8_OTHERS)
	for i in 160:
		await _clear_guard(g, gb)
		var before := gb.tap_guards
		var k := i >> 1
		if i % 2 == 0:
			GameEvents.strike_started.emit(player, g, BREAKERS[k % BREAKERS.size()], false, 0)
		else:
			GameEvents.strike_started.emit(player, g, all_moves[k % all_moves.size()], false, 1 + k % 3)
		if gb.tap_guards > before:
			breakers += 1
	check(breakers == 0, "never raises a tap guard against a guard breaker (Round 7 heavies, any charged strike: %d of 160)" % breakers)
	var other_guards := 0
	for i in GUARD_TRIALS:
		await _clear_guard(g, gb)
		var before := gb.tap_guards
		GameEvents.strike_started.emit(player, g, R8_OTHERS[i % R8_OTHERS.size()], false, 0)
		if gb.tap_guards > before:
			other_guards += 1
	var po := float(other_guards) / GUARD_TRIALS
	check(absf(po - Tuning.GUARD_TAP_CHANCE) <= 0.07,
		"Round 8: guards tapped kicks, gut punches and uppercuts like punches (%d of %d: %.0f%%, target %.0f%%)" % [
			other_guards, GUARD_TRIALS, po * 100.0, Tuning.GUARD_TAP_CHANCE * 100.0])
	var charged := 0
	for i in 100:
		await _clear_guard(g, gb)
		var before := gb.tap_guards
		GameEvents.strike_started.emit(player, g, &"jab1", false, 2)
		if gb.tap_guards > before:
			charged += 1
	check(charged == 0, "never guards an older charged strike (%d of 100)" % charged)
	for f: Fighter in [s, h]:
		var fb := f.brain as AIBrain
		# Brain paused between its own turns: every trial is a strike it is free to guard.
		await _settle(f)
		fb.process_mode = Node.PROCESS_MODE_DISABLED
		var want := fb.get_guard_chance()
		var base := float(f.config.get("guard_chance", 0.0))
		var tap_guards_f := 0
		for i in GUARD_TRIALS:
			await _clear_guard(f, fb)
			var before := fb.tap_guards
			GameEvents.strike_started.emit(player, f, all_moves[i % all_moves.size()], false, 0)
			if fb.tap_guards > before:
				tap_guards_f += 1
		var charged_f := 0
		for i in 100:
			await _clear_guard(f, fb)
			var before := fb.tap_guards
			GameEvents.strike_started.emit(player, f, all_moves[i % all_moves.size()], false, 1 + i % 3)
			if fb.tap_guards > before:
				charged_f += 1
		fb.process_mode = Node.PROCESS_MODE_INHERIT
		var rate := float(tap_guards_f) / GUARD_TRIALS
		var tol := maxf(0.03, 3.5 * sqrt(maxf(want * (1.0 - want), 1e-6) / GUARD_TRIALS))
		print("[ai] info: %s (level %d, p %.2f): guards %d of %d taps (%.1f%%; chance %.3f = %.2f x block mult %.2f), %d of 100 charged" % [
			f.archetype, f.level, fb.get_pressure(), tap_guards_f, GUARD_TRIALS, rate * 100.0, want, base, fb.block_mult(), charged_f])
		check(base > 0.0 and absf(want - base * fb.block_mult()) < 1e-6, "%s: guard chance %.3f = its guard_chance %.2f x block_mult()" % [
			f.archetype, want, base])
		check(absf(rate - want) <= tol, "%s guards %.1f%% of %d tapped strikes (target %.1f%% +- %.1f)" % [
			f.archetype, rate * 100.0, GUARD_TRIALS, want * 100.0, tol * 100.0])
		check(charged_f == 0, "%s never guards a charged strike (%d of 100)" % [f.archetype, charged_f])
	# Real jabs: B's strike_started reaches the brain, a guard is a plain guard.
	# Counters in arrays: lambdas capture plain locals by value.
	var parried := [0]
	var blocked := [0]
	var on_parry := func(d: Node3D, _a: Node3D) -> void:
		if d == g: parried[0] += 1
	var on_block := func(i: HitInfo) -> void:
		if i.victim == g: blocked[0] += 1
	if GameEvents.has_signal(&"parried"):
		GameEvents.connect(&"parried", on_parry)
	GameEvents.hit_blocked.connect(on_block)
	var before_real := gb.tap_guards
	for i in 40:
		await _clear_guard(g, gb)
		await _settle(g)
		g.global_position = Vector3(0, 0.05, -1.1)
		g.reset_physics_interpolation()
		g.snap_facing(Vector3.BACK)
		_face(player, g)
		player.combat.press(CombatController.Action.LIGHT)
		await get_tree().physics_frame
		player.combat.release(CombatController.Action.LIGHT)
		await _wait(0.45)
		if player.hp < player.max_hp * 0.5:
			player.heal_fraction(1.0)
	if GameEvents.has_signal(&"parried"):
		GameEvents.disconnect(&"parried", on_parry)
	GameEvents.hit_blocked.disconnect(on_block)
	var real_guards := gb.tap_guards - before_real
	print("[ai] info: 40 real jabs: %d tap guards, %d blocked hits, %d parries" % [real_guards, blocked[0], parried[0]])
	check(real_guards >= 1, "real jabs (B's strike_started) draw tap guards (%d of 40)" % real_guards)
	check(blocked[0] >= 1, "a tap guard blocks the jab (B: hit_blocked, %d)" % blocked[0])
	check(parried[0] == 0, "a grunt's guard is never a parry (%d)" % parried[0])
	for f: Fighter in [g, s, h]:
		f.queue_free()

# --- D. Grab breaks ------------------------------------------------------------------

func _part_grab_break() -> void:
	var g := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis(), Vector3(-3, 0.05, -4)))
	var h := FighterFactory.spawn_enemy(self, &"heavy", Transform3D(Basis(), Vector3(3, 0.05, -4)))
	await _wait(0.4)
	var rates := {}
	for f: Fighter in [g, h]:
		var b := f.brain as AIBrain
		var n := 0
		for i in 400:
			b._grabbed_at.clear()
			if b.wants_grab_break(player):
				n += 1
		rates[f.archetype] = float(n) / 400.0
		var want: float = AIBrain.GRAB_BREAK_CHANCE[f.archetype]
		check(absf(rates[f.archetype] - want) <= 0.07, "%s breaks %.0f%% of neutral grabs (target %.0f%%)" % [f.archetype, rates[f.archetype] * 100.0, want * 100.0])
	check(rates[&"heavy"] > rates[&"grunt"], "heavies break grabs more often than grunts")
	var gb := g.brain as AIBrain
	gb._grabbed_at.clear()
	var c0 := gb.grab_break_chance(true)
	var c1 := gb.grab_break_chance(true)
	var c2 := gb.grab_break_chance(true)
	check(c1 > c0 and c2 > c1 and c2 <= AIBrain.GRAB_BREAK_CAP, "repeated grabs get broken more (%.2f, %.2f, %.2f)" % [c0, c1, c2])
	gb._grabbed_at.clear()
	g.flinch(Vector3.FORWARD, &"Chest")
	await get_tree().physics_frame
	var stunned := gb.grab_break_chance()
	var fb := 0
	for i in 50:
		if gb.wants_grab_break(player):
			fb += 1
	check(stunned == 0.0 and fb == 0, "never breaks while stunned (chance %.2f, %d of 50)" % [stunned, fb])
	await _settle(g)
	# Round 7: once the clinch has connected, or while the holder drives, never.
	var holder := FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(8, 0.05, 8)), Fighter.TEAM_PLAYER)
	var fake: Carry = FakeCarry.new()
	fake.name = "FakeCarry"
	holder.add_child(fake)
	holder.carry = fake
	await get_tree().physics_frame
	var hb := h.brain as AIBrain
	hb.grab_break_override = 1.0
	var rows: Array[String] = []
	var gate_ok := true
	for state: Array in [[false, false, 1], [true, false, 0], [false, true, 0], [true, true, 0]]:
		fake.set(&"fake_holding_body", state[0])
		fake.set(&"fake_driving", state[1])
		var n := 0
		for i in 50:
			if hb.wants_grab_break(holder):
				n += 1
		var want: int = 50 * int(state[2])
		gate_ok = gate_ok and n == want
		rows.append("connected %s driving %s: %d/50" % [state[0], state[1], n])
	hb.grab_break_override = -1.0
	check(gate_ok, "no break attempt once the clinch has connected or during a drive (break chance forced to 1: %s)" % "; ".join(rows))
	holder.queue_free()
	# Reacting (Round 7): a reacting body connects at once (FakeFighter's forced state).
	var fe := Util.spawn_fake_enemy(self, &"grunt", Vector3(-6, 0.05, -4))
	await _wait(0.2)
	var feb := fe.brain as AIBrain
	fe.set(&"fake_reacting", true)
	var react_n := 0
	for i in 50:
		if feb.wants_grab_break(player):
			react_n += 1
	check(feb.grab_break_chance() == 0.0 and react_n == 0, "never breaks while reacting (chance %.2f, %d of 50)" % [feb.grab_break_chance(), react_n])
	fe.set(&"fake_reacting", false)
	fe.queue_free()
	g.sever_limb(&"leg_r")
	await get_tree().physics_frame
	check(gb.is_fleeing() and gb.grab_break_chance() == 0.0, "never breaks while fleeing")
	g.queue_free()
	h.queue_free()
	await _wait(0.2)

# --- Helpers -------------------------------------------------------------------------

func _clear_guard(f: Fighter, b: AIBrain) -> void:
	b._tap_guard_until = -INF
	b._want_guard = false
	b._apply_guard()
	await get_tree().physics_frame
	var t0 := Util.game_now()
	while f.combat.is_blocking() and Util.game_now() - t0 < 1.0:
		await get_tree().physics_frame

## Wait until `f` can act again (a stagger or a block stun has ended).
func _settle(f: Fighter) -> void:
	var t0 := Util.game_now()
	while (not f.can_act() or f.is_down()) and Util.game_now() - t0 < 4.0:
		if player.hp < player.max_hp * 0.5:
			player.heal_fraction(1.0)
		await get_tree().physics_frame

func _face(a: Fighter, b: Fighter) -> void:
	var to := b.get_ground_position() - a.get_ground_position()
	to.y = 0.0
	if to.length() > 0.01:
		a.snap_facing(to)
		a.face_dir = to.normalized()

func _wait(s: float) -> void:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < s:
		await get_tree().physics_frame

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_roster: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
