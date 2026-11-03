extends "res://tests/combat/combat_test_base.gd"
## Round 8 acceptance check 3 (docs/Round 8 — Charge and Pressure.md: Moves,
## Interrupts), with agent H's real reactions:
## - every tap cancels a grunt's wind-up (its e_jab never reaches its active
##   frames); after the light taps (jab, cross, hook, leg kick, gut punch,
##   uppercut) the grunt can start an attack again within 0.4 s of the tap
##   landing (the jab through the real input path);
## - armored wind-ups ignore every tap: the heavy archetype's e_heavy takes the
##   damage and a small snap (HitInfo meta "armored") and still reaches its
##   active frames; charged strikes break the armor (the attack is cancelled);
## - the Duelist (Tuning.ARCHETYPES "armor_moves": only his big swing): a jab
##   tap interrupts his e_hook and e_kick, not his e_heavy; a charged strike
##   breaks the e_heavy. A legacy "armor_bonus" archetype (the brute) still
##   ignores the tap.

const AGAIN_MAX := 0.4   ## s from the tap landing to the grunt's next attack
const LIGHT: Array[StringName] = [&"jab", &"cross", &"hook", &"leg_kick", &"gut_punch", &"uppercut"]

var _x := 0.0

func _init() -> void:
	_timeout = 150.0

func run() -> void:
	print("taps on a grunt's wind-up")
	for id: StringName in Tuning.R8_MOVES:
		await _tap_trial(id, id == &"jab")
	print("armored wind-ups (the heavy's e_heavy)")
	for id: StringName in Tuning.R8_MOVES:
		await _armor_trial(id, false)
	for id: StringName in [&"jab", &"leg_kick", &"front_kick"]:
		await _armor_trial(id, true)
	print("the Duelist: only his big swing (armor_moves) ignores taps")
	for spec: Array in [[&"duelist", &"e_hook", false, false], [&"duelist", &"e_kick", false, false],
			[&"duelist", &"e_heavy", false, true], [&"duelist", &"e_heavy", true, false], [&"brute", &"e_heavy", false, true]]:
		await _wind_up_trial(spec[0], spec[1], spec[2], spec[3])
	release_inputs()
	done()

## `arch` starts `move` (0.7 s tell); the player hits it 0.1 s in with a jab
## tap (or a charged jab at c = 0.5). `armored`: the wind-up must go on.
func _wind_up_trial(arch: StringName, move: StringName, charged: bool, armored: bool) -> void:
	_x += 10.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := spawn(arch, Vector3(_x, 0, -1.2), Vector3.BACK)
	await ticks(15)
	var started := e.combat.start_enemy_attack(move, 0.7)
	await wait_real(0.1)
	var level := e.combat.get_armor_level()
	clear_events()
	if charged:
		p.combat.play_charged(&"jab", 0.5, e)
	else:
		p.combat.play_move(&"jab", e)
	var landed := await wait_until(func() -> bool: return not hits_on(e).is_empty(), 1.5)
	await ticks(2)
	var info: HitInfo = hits_on(e)[0] if landed else null
	var goes_on := e.combat.is_attacking() and e.combat.current_move_id() == move
	var reached := goes_on and await wait_until(func() -> bool: return e.combat.is_attack_active(), 1.5)
	var label := "%s %s, %s" % [arch, move, "a charged jab" if charged else "a jab tap"]
	print("  %s: armor level %d in the tell, armored hit %s, react %s, the wind-up goes on %s (reaches its active frames %s)" % [
		label, level, info.get_meta(&"armored", false) if info else false, info.react if info else &"-", goes_on, reached])
	if armored:
		check(started and landed and info.get_meta(&"armored", false) and goes_on and reached,
			"%s: not interrupted (damage and a snap)" % label)
	else:
		check(started and landed and not info.get_meta(&"armored", false) and not goes_on,
			"%s: interrupted" % label)
	p.queue_free()
	e.queue_free()
	await ticks(2)

## A grunt 1.1 m ahead starts its e_jab (0.6 s tell); the player taps `id`
## 0.1 s in. The grunt's attack is cancelled; for a light tap, the first tick
## at which it can start an attack again is within AGAIN_MAX of the tap landing.
func _tap_trial(id: StringName, real_input: bool) -> void:
	_x += 10.0
	var p: Fighter
	if real_input:
		p = spawn_player(Vector3(_x, 0, 0))
	else:
		p = spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(_x, 0, -1.1), Vector3.BACK)
	await ticks(15)
	clear_events()
	var actives := [0]
	g.combat.attack_active.connect(func(_m: StringName) -> void: actives[0] += 1)
	g.combat.start_enemy_attack(&"e_jab", 0.6)
	await wait_real(0.1)
	if real_input:
		var btn := &"punch"
		await tap_input(btn, 0.05)
	else:
		p.combat.play_move(id, g)
	var landed := await wait_until(func() -> bool: return not hits_on(g).is_empty(), 1.0)
	var t_hit := first_time(&"hit_landed")
	var info: HitInfo = hits_on(g)[0] if landed else null
	var cancelled := landed and not (g.combat.is_attacking() and g.combat.current_move_id() == &"e_jab")
	var again := INF
	if landed and LIGHT.has(id):
		while TimeDirector.now() - t_hit < 1.0:
			if g.combat.start_enemy_attack(&"e_jab", 0.6):
				again = TimeDirector.now() - t_hit
				break
			await get_tree().physics_frame
		g.combat.cancel()
	await wait_real(0.1)
	print("  %s tap%s: react %s, the grunt's e_jab cancelled %s (active frames %d), it attacks again %.3f s after the tap landed" % [
		id, " (real input)" if real_input else "", info.react if info else &"-", cancelled, actives[0], again])
	check(landed and info != null and not info.charged and cancelled and actives[0] == 0,
		"the %s tap cancels the grunt's wind-up" % id)
	if LIGHT.has(id):
		check(again <= AGAIN_MAX, "after the %s tap the grunt attacks again within %.1f s (%.3f)" % [id, AGAIN_MAX, again])
	p.queue_free()
	g.queue_free()
	await ticks(2)

## The heavy in its e_heavy wind-up (0.7 s tell); `id` tapped (or charged at
## c = 0.5) 0.1 s in.
func _armor_trial(id: StringName, charged: bool) -> void:
	_x += 10.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var h := spawn(&"heavy", Vector3(_x, 0, -1.3), Vector3.BACK)
	await ticks(15)
	h.combat.start_enemy_attack(&"e_heavy", 0.7)
	await wait_real(0.1)
	var hp0 := h.hp
	clear_events()
	if charged:
		p.combat.play_charged(id, 0.5, h)
	else:
		p.combat.play_move(id, h)
	var landed := await wait_until(func() -> bool: return not hits_on(h).is_empty(), 1.5)
	await ticks(2)
	var info: HitInfo = hits_on(h)[0] if landed else null
	var armored := info != null and bool(info.get_meta(&"armored", false))
	var label := "%s %s" % [id, "charged" if charged else "tap"]
	if charged:
		print("  %s: armored %s, the heavy's attack goes on %s, reacting %s" % [label, armored,
			h.combat.is_attacking(), h.is_reacting() or h.is_down()])
		check(info != null and not armored and not (h.combat.is_attacking() and h.combat.current_move_id() == &"e_heavy"),
			"the %s breaks the armor: the attack is cancelled" % label)
	else:
		var still := h.combat.is_attacking() and h.combat.current_move_id() == &"e_heavy" and not h.is_reacting()
		var reached := await wait_until(func() -> bool: return h.combat.is_attack_active(), 1.5)
		print("  %s: armored %s, react %s, %.1f damage, the e_heavy goes on %s and reaches its active frames %s" % [label,
			armored, info.react if info else &"-", hp0 - h.hp, still, reached])
		check(armored and info.react == &"snap" and hp0 - h.hp > 0.0 and still and reached,
			"the %s tap does not interrupt the armored wind-up (damage and a snap)" % id)
	p.queue_free()
	h.queue_free()
	await ticks(2)
