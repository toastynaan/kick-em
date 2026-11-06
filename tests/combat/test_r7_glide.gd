extends "res://tests/combat/combat_test_base.gd"
## Round 7 acceptance check 5 and the rest of freeflow targeting (docs/Round 7
## — Freeflow Combat.md: Freeflow targeting and the auto-follow):
## - a target 4 m away is reached by a glide (R7_GLIDE_SPEED, glide_started,
##   is_gliding) that stops at reach x LUNGE_GAP, and is hit;
## - auto-connect: a target that sidesteps 0.3 m during the startup is hit on
##   the first active frame (within reach + R7_CONNECT_MARGIN), but never a
##   dodging, invulnerable or downed one;
## - the pick: the stick picks the enemy it points at; with the stick neutral
##   the combat target (the last struck) wins; get_combat_target() clears when
##   that enemy goes down or leaves R7_TARGET_RANGE + R7_TARGET_KEEP_EXTRA;
## - with no target the strike goes along the stick;
## - the follow step: a push up to R7_FOLLOW_MAX_PUSH is followed by
##   R7_FOLLOW_SHARE of it during recovery; a bigger push is not.

const AimBrain := preload("res://tests/combat/aim_brain.gd")
const TraversalDouble := preload("res://tests/combat/traversal_double.gd")

var _x := 0.0

func _init() -> void:
	_timeout = 120.0

func run() -> void:
	print("a target 4 m away: glide, then hit")
	var p := _player()
	var g := spawn(&"grunt", p.global_position + Vector3(0, 0, -4.0), Vector3.BACK)
	await ticks(15)
	clear_events()
	var glide := [0.0, 0.0, Vector3.ZERO, 0.0]  # start t, end t, start pos, gap at the startup
	var gliding := [false]
	var t0 := TimeDirector.now()
	var p0 := p.global_position
	tap(p, A.LIGHT)
	gliding[0] = p.combat.is_gliding()
	while TimeDirector.now() - t0 < 1.0 and p.combat.is_gliding():
		await get_tree().physics_frame
	var t1 := TimeDirector.now()
	var covered := p.global_position.distance_to(p0)
	var gap := (g.get_ground_position() - p.global_position) * Vector3(1, 0, 1)
	await wait_until(func() -> bool: return not hits_on(g).is_empty(), 1.0)
	var ev := last_event(&"glide_started")
	var reach := MoveLibrary.get_move(&"jab").reach
	print("DATA glide: %.2f m in %.3f s (%.1f m/s), stopped %.2f m from the target (reach x LUNGE_GAP %.2f), glide_started distance %.2f, hit %s" % [
		covered, t1 - t0, covered / maxf(t1 - t0, 1e-3), gap.length(), reach * CombatController.LUNGE_GAP,
		float(ev[3]) if not ev.is_empty() else -1.0, not hits_on(g).is_empty()])
	check(gliding[0], "is_gliding() from the press")
	check(not ev.is_empty() and ev[1] == p and ev[2] == g and absf(float(ev[3]) - 4.0) < 0.05,
		"glide_started(player, target, 4 m)")
	check(absf(covered / maxf(t1 - t0, 1e-3) - Tuning.R7_GLIDE_SPEED) < 1.0, "it glides at R7_GLIDE_SPEED")
	check(absf(gap.length() - reach * CombatController.LUNGE_GAP) < 0.05, "it stops at reach x LUNGE_GAP")
	check(not hits_on(g).is_empty() and hits_on(g)[0].move_id == &"jab", "the 4 m target is hit")

	print("auto-connect: a target that sidesteps 0.3 m during the startup")
	var r := await _sidestep_trial(false, false, false)
	check(r["hit"], "a target that sidestepped 0.3 m is still hit (%s)" % r["how"])
	# Its hurtboxes off, only the auto-connect can find it.
	r = await _sidestep_trial(true, false, false)
	check(r["auto"], "with no limb contact possible it is hit by the auto-connect (%s)" % r["how"])
	r = await _sidestep_trial(true, true, false)
	check(not r["hit"], "a dodging target is not auto-connected (%s)" % r["how"])
	r = await _sidestep_trial(true, false, true)
	check(not r["hit"], "an invulnerable target is not hit (%s)" % r["how"])

	print("the pick: stick, combat target, clearing")
	p = _player()
	var front := spawn(&"grunt", p.global_position + Vector3(0, 0, -2.0), Vector3.BACK)
	var left := spawn(&"grunt", p.global_position + Vector3(-2.2, 0, -1.0), Vector3.RIGHT)
	await ticks(15)
	var brain := p.brain as Node
	brain.set(&"stick", Vector3(-1, 0, 0))
	clear_events()
	tap(p, A.LIGHT)
	check(p.combat.get_attack_target() == left, "the stick pointing left picks the left enemy")
	await wait_until(func() -> bool: return not hits_on(left).is_empty(), 1.0)
	check(p.combat.get_combat_target() == left, "the enemy struck is the combat target")
	await wait_until(func() -> bool: return not p.combat.is_attacking(), 1.5)
	brain.set(&"stick", Vector3.ZERO)
	place_in_front(p, front, 1.6)  # straight ahead now, the combat target off to the side
	await ticks(4)
	tap(p, A.LIGHT)
	check(p.combat.get_attack_target() == left, "stick neutral: the combat target wins over the enemy in front")
	await wait_until(func() -> bool: return not p.combat.is_attacking(), 1.5)
	await wait_until(func() -> bool: return not left.is_reacting() and not left.is_body_simulating(), 2.0)
	check(p.combat.get_combat_target() == left, "still the combat target while it stays in range")
	left.global_position = p.global_position + Vector3(Tuning.R7_TARGET_RANGE + Tuning.R7_TARGET_KEEP_EXTRA + 0.5, 0, 0)
	left.reset_physics_interpolation()
	await ticks(4)
	check(p.combat.get_combat_target() == null, "the combat target clears beyond R7_TARGET_RANGE + R7_TARGET_KEEP_EXTRA")
	left.global_position = p.global_position + Vector3(-1.5, 0, 0)
	left.reset_physics_interpolation()
	await ticks(2)
	check(p.combat.get_combat_target() == null, "and stays cleared when it comes back")
	front.queue_free()
	left.queue_free()
	await wait_real(0.6)
	p = _player()
	var kd := spawn(&"grunt", p.global_position + Vector3(0, 0, -1.2), Vector3.BACK)
	await ticks(15)
	p.combat.play_move(&"heavy_hook", kd)  # a knockdown (a tapped roundhouse only staggers a fresh guard)
	await wait_until(func() -> bool: return not hits_on(kd).is_empty(), 1.0)
	check(p.combat.get_combat_target() == null and kd.is_down(), "a target knocked down is no combat target")

	print("no target: the strike goes along the stick")
	p = _player()
	await ticks(10)
	(p.brain as Node).set(&"stick", Vector3(1, 0, 0))
	tap(p, A.LIGHT)
	await ticks(2)
	check(p.get_forward().dot(Vector3.RIGHT) > 0.99 and p.combat.get_attack_target() == null,
		"no enemy in reach: it turns to the stick and strikes there")
	await wait_until(func() -> bool: return not p.combat.is_attacking(), 1.5)

	print("the follow step")
	for spec: Array in [[&"jab", true], [&"cross", true], [&"front_kick", false]]:
		p = _player()
		var v := spawn(&"grunt", p.global_position + Vector3(0, 0, -1.0), Vector3.BACK)
		await ticks(15)
		clear_events()
		p.combat.play_move(spec[0], v)
		await wait_until(func() -> bool: return p.combat.is_in_recovery(), 1.0)
		var at := p.global_position
		await wait_until(func() -> bool: return not p.combat.is_attacking(), 1.0)
		var moved := (p.global_position - at).dot(Vector3.FORWARD)
		var info: HitInfo = hits_on(v)[0] if not hits_on(v).is_empty() else null
		var push := info.push if info else 0.0
		var want := push * Tuning.R7_FOLLOW_SHARE if spec[1] else 0.0
		print("  %s: push %.2f m, the attacker stepped %.2f m in recovery (want %.2f)" % [spec[0], push, moved, want])
		check(info != null and absf(moved - want) <= 0.06, "%s: %s" % [spec[0],
			"followed by %.0f%% of its push" % (Tuning.R7_FOLLOW_SHARE * 100.0) if spec[1] else "a push over R7_FOLLOW_MAX_PUSH is not followed"])
		v.queue_free()
	done()

## A fake player (no PlayerController) with a neutral-stick aim brain, on fresh ground.
func _player() -> Fighter:
	_x += 20.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var b: Node = AimBrain.new()
	p.add_child(b)
	p.brain = b
	return p

## A grunt 1.0 m in front; the jab starts; on its last startup tick the grunt
## steps 0.3 m to the side. no_boxes: its hurtboxes are off (no limb contact);
## dodging: it is mid-dodge (a Traversal double); invuln: it is invulnerable.
func _sidestep_trial(no_boxes: bool, dodging: bool, invuln: bool) -> Dictionary:
	var side := 0.3
	var p := _player()
	var g := spawn(&"grunt", p.global_position + Vector3(0, 0, -1.0), Vector3.BACK)
	if dodging:
		var td: Traversal = TraversalDouble.new()
		g.add_child(td)
		td.setup(g)
		g.traversal = td
		td.set(&"dodging", true)
	await ticks(15)
	if no_boxes:
		for hb in g.hurtboxes:
			hb.set_enabled(false)
	clear_events()
	var m := MoveLibrary.get_move(&"jab")
	tap(p, A.LIGHT)
	while p.combat.time_to_active() > 1.5 / 120.0 and p.combat.is_attacking():
		await get_tree().physics_frame
	g.global_position += Vector3(side, 0, 0)
	g.reset_physics_interpolation()
	if invuln:
		g.invuln_until = TimeDirector.now() + 1.0
	await wait_until(func() -> bool: return not p.combat.is_attack_active() and p.combat.is_in_recovery(), 1.0)
	var info: HitInfo = hits_on(g)[0] if not hits_on(g).is_empty() else null
	var d := (g.get_ground_position() - p.global_position) * Vector3(1, 0, 1)
	var auto := info != null and bool(info.get_meta(&"auto_connect", false))
	var how := "none"
	if info != null:
		how = ("auto-connect on %s" if auto else "the limb sweep on %s") % info.hit_bone
	print("  sidestep %.1f m%s%s%s: target %.2f m away at the active frame (reach + margin %.2f), hit: %s" % [side, " (hurtboxes off)" if no_boxes else "",
		" (dodging)" if dodging else "", " (invulnerable)" if invuln else "", d.length(),
		m.reach + Tuning.R7_CONNECT_MARGIN, how])
	await wait_real(0.3)
	g.queue_free()
	return {"hit": info != null, "auto": auto, "how": how}
