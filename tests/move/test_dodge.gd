extends "res://tests/move/move_test_base.gd"
## Round 7 acceptance 7 (docs/Round 7 — Freeflow Combat.md: Defence > Dodge;
## agent M), through the real input path (Input.action_press(&"dash") ->
## PlayerController -> InputInterpreter -> CombatController -> Traversal).
## Checks, with measured numbers:
## - a Dash tap starts a dodge on the tick it is read (GameEvents.dodged);
## - invulnerable for R7_DODGE_INVULN (0.25 s) from the press: is_dodge_invulnerable(),
##   Fighter.is_invulnerable(), and a hit inside the window is ignored while
##   one after it lands;
## - it travels R7_DODGE_DIST (2.5 m +- 0.2) in R7_DODGE_TIME: straight back
##   from the enemy with the stick neutral, along the stick otherwise;
## - neutral stick: away from the nearest attacking enemy before a closer idle one;
## - R7_DODGE_COOLDOWN after a dodge ends: a tap in it does nothing, one after it dodges;
## - held past Tuning.DASH_HOLD_SPRINT it flows into the sprint (never under
##   6 m/s, the cap 1.2 s after the press), and the release bleeds to walking;
## - it cancels the player's own recovery but never active frames, and is not buffered;
## - never while reacting, or while holding a body.

var p: Fighter

func _init() -> void:
	_timeout = 240.0

func run() -> void:
	p = spawn_real_player(Vector3(0.0, 0.02, 0.0))
	await ticks(30)
	check(p.traversal != null and p.brain is PlayerController, "the real player (PlayerController) has a Traversal")
	await _tap_back_from_enemy()
	await _tap_along_stick()
	await _away_from_attacker()
	await _cooldown()
	await _hold_into_sprint()
	await _cancel_recovery_not_active()
	await _refused_while_reacting()
	await _refused_while_holding()
	done()

func _reset(pos: Vector3, facing := Vector3.FORWARD) -> void:
	release_all_input()
	await ticks(2)
	await settle(p, 10)
	await place(p, pos, facing)
	# The cooldown of an earlier dodge must not leak into the next check.
	await wait_until(func() -> bool: return p.traversal.get_dodge_cooldown_left() <= 0.0, 120)
	clear_events()

## Press Dash through Input for `n` ticks. Returns the real time the dodge
## started (the dodged event), or -1 when none did.
func _tap_dash(n := 2) -> float:
	var before := count_events(&"dodged")
	hold(&"dash")
	await ticks(n)
	let_go(&"dash")
	return last_event_time(&"dodged") if count_events(&"dodged") > before else -1.0

## Ticks until the player stops (speed under 0.05) or `max_ticks`.
func _until_still(max_ticks := 120) -> void:
	await wait_until(func() -> bool: return hspeed(p) < 0.05 and not p.traversal.is_dodging(), max_ticks)

func _hit_info(from: Fighter) -> HitInfo:
	var info := HitInfo.new()
	info.attacker = from
	info.victim = p
	info.move_id = &"e_jab"
	info.kind = &"strike"
	info.damage = 3.0
	info.tier = HitInfo.Tier.FLINCH
	info.reaction = HitInfo.Reaction.FLINCH
	info.hit_direction = Vector3.BACK
	info.hit_position = p.get_aim_point()
	info.hit_bone = Bones.CHEST
	info.unblockable = true
	return info

# --- Tap, stick neutral: straight back from the enemy; invulnerability ---------------
func _tap_back_from_enemy() -> void:
	await _reset(Vector3(0.0, 0.02, 0.0))
	var g := spawn_enemy(&"grunt", Vector3(0.0, 0.0, -3.0), Vector3.BACK)  # in front, idle
	await ticks(10)
	var x0 := p.global_position
	var hp0 := p.hp
	hold(&"dash")
	await ticks(1)
	var t0 := last_event_time(&"dodged")
	var started := t0 >= 0.0 and p.traversal.is_dodging()
	var dodge_ev := last_event(&"dodged")
	# Sample the invulnerability every tick from the press on, and hit the player
	# inside the window (at 0.2 s) and after it (at 0.3 s).
	var inv_until := -1.0
	var fighter_inv_ok := true
	var hit_in := -1
	var hit_out := -1
	var hp_in := hp0
	var dodge_ticks := 0
	var t_end := -1.0
	for i in 60:
		var now := TimeDirector.now()
		var dt := now - t0
		if i == 1:
			let_go(&"dash")
		if p.traversal.is_dodging():
			dodge_ticks += 1
		elif t_end < 0.0 and started:
			t_end = dt
		if p.traversal.is_dodge_invulnerable():
			inv_until = dt
			fighter_inv_ok = fighter_inv_ok and p.is_invulnerable()
		elif dt > 0.0 and dt < Tuning.R7_DODGE_INVULN - 1e-4:
			fighter_inv_ok = false
		if hit_in < 0 and dt >= 0.2 - 1e-4:
			hit_in = p.take_hit(_hit_info(g))
			hp_in = p.hp
		await get_tree().physics_frame
	var dist_at_stop := 0.0
	await _until_still()
	dist_at_stop = Vector2(p.global_position.x - x0.x, p.global_position.z - x0.z).length()
	var back := (p.global_position - x0)
	back.y = 0.0
	var dir: Vector3 = dodge_ev[1] if dodge_ev.size() > 1 and dodge_ev[1] is Vector3 else Vector3.ZERO
	var inv_len := inv_until + 1.0 / 120.0  # the window's last tick counts whole
	print("  tap, stick neutral, grunt 3 m in front: dodge started %s (dir %s), %d dodge ticks, ended at %.3f s; invulnerable %.3f s (Fighter.is_invulnerable in step %s); travelled %.3f m (straight back %.3f)" % [
		started, dir, dodge_ticks, t_end, inv_len, fighter_inv_ok, dist_at_stop, back.dot(Vector3.BACK)])
	check(started and count_events(&"dodged") == 1, "a Dash tap through Input starts a dodge at once (GameEvents.dodged)")
	check(near(inv_len, Tuning.R7_DODGE_INVULN, 1.0 / 120.0 + 1e-4),
		"invulnerable for %.3f s from the press (R7_DODGE_INVULN %.2f)" % [inv_len, Tuning.R7_DODGE_INVULN])
	check(fighter_inv_ok, "Fighter.is_invulnerable() is true for exactly the dodge's window")
	check(near(dist_at_stop, Tuning.R7_DODGE_DIST, 0.2), "a tap travels %.3f m (2.5 +- 0.2)" % dist_at_stop)
	check(back.dot(Vector3.BACK) >= dist_at_stop * 0.98 and dir.dot(Vector3.BACK) > 0.99,
		"stick neutral: straight back from the enemy (%.3f of %.3f m along +Z)" % [back.dot(Vector3.BACK), dist_at_stop])
	check(near(t_end, Tuning.R7_DODGE_TIME, 1.5 / 120.0), "the dodge lasts %.3f s (R7_DODGE_TIME %.2f)" % [t_end, Tuning.R7_DODGE_TIME])
	# Hit inside the window: ignored, no damage. A hit after it lands.
	await ticks(2)
	hit_out = p.take_hit(_hit_info(g))
	await ticks(2)
	print("  hit at 0.2 s: result %d, hp %.1f -> %.1f; hit after the window: result %d, hp %.1f" % [hit_in, hp0, hp_in, hit_out, p.hp])
	check(hit_in != HitInfo.Result.HIT and is_equal_approx(hp_in, hp0), "a hit inside the dodge's invulnerability is ignored")
	check(hit_out == HitInfo.Result.HIT and p.hp < hp0, "a hit after the window lands")
	g.queue_free()
	await settle(p, 30)

# --- Tap with the stick: along the stick ------------------------------------------------------
func _tap_along_stick() -> void:
	await _reset(Vector3(10.0, 0.02, 0.0))
	stick(Vector3.RIGHT)
	await ticks(1)  # the stick is read before the press
	var x0 := p.global_position
	var t0 := await _tap_dash(2)
	var pose := p.animator.get_current_move() if p.animator != null else &""
	var at_end := Vector3.ZERO
	var v_end := 0.0
	await wait_until(func() -> bool: return not p.traversal.is_dodging(), 60)
	at_end = p.global_position
	v_end = hspeed(p)
	await ticks(30)
	var walk_v := hspeed(p)
	release_all_input()
	var d := at_end - x0
	d.y = 0.0
	print("  tap with the stick right: dodge %s, %.3f m at its end (along +X %.3f), leaves at %.2f m/s, then walks at %.2f" % [
		t0 >= 0.0, d.length(), d.dot(Vector3.RIGHT), v_end, walk_v])
	check(t0 >= 0.0 and near(d.length(), Tuning.R7_DODGE_DIST, 0.2) and d.dot(Vector3.RIGHT) >= d.length() * 0.98,
		"stick pushed: the dodge travels %.3f m along the stick (2.5 +- 0.2)" % d.length())
	check(near(walk_v, Tuning.WALK_SPEED, 0.3), "the dodge flows into walking along the stick (%.2f m/s)" % walk_v)
	print("  dodge pose playing: %s" % pose)
	check(pose == (&"dodge" if PoseLibrary.has_move(&"dodge") else &"dash"), "the dodge plays P's dodge pose (%s)" % pose)
	await settle(p, 20)

# --- Neutral stick: away from the attacking enemy ----------------------------------------------
func _away_from_attacker() -> void:
	await _reset(Vector3(-10.0, 0.02, 0.0))
	var idle := spawn_enemy(&"grunt", Vector3(-8.5, 0.0, 0.0), Vector3.LEFT)   # 1.5 m to the right, idle
	var att := spawn_enemy(&"grunt", Vector3(-10.0, 0.0, -3.0), Vector3.BACK) # 3 m in front, attacking
	await ticks(10)
	var started := att.combat.start_enemy_attack(&"e_jab", 0.8)
	await ticks(2)
	var attacking := att.combat.is_attacking()
	var x0 := p.global_position
	var t0 := await _tap_dash(2)
	var ev := last_event(&"dodged")
	var dir: Vector3 = ev[1] if ev.size() > 1 and ev[1] is Vector3 else Vector3.ZERO
	await _until_still()
	var d := p.global_position - x0
	d.y = 0.0
	print("  neutral tap, idle grunt 1.5 m right, grunt 3 m in front attacking (%s, %s): dodge dir %s, moved (%.2f, %.2f)" % [
		started, attacking, dir, d.x, d.z])
	check(attacking and t0 >= 0.0 and dir.dot(Vector3.BACK) > 0.99,
		"stick neutral: straight back from the nearest attacking enemy, not the closer idle one")
	idle.queue_free()
	att.queue_free()
	await settle(p, 20)

# --- Cooldown -----------------------------------------------------------------------------------
func _cooldown() -> void:
	await _reset(Vector3(20.0, 0.02, 0.0))
	var t0 := await _tap_dash(2)
	await wait_until(func() -> bool: return not p.traversal.is_dodging(), 60)
	var t_end := TimeDirector.now() - 1.0 / 120.0  # it ended during the previous tick
	# A tap 0.05 s after the dodge ends (inside the 0.2 s cooldown).
	await ticks(4)
	var t1 := await _tap_dash(2)
	var cd_left := p.traversal.get_dodge_cooldown_left()
	await wait_until(func() -> bool: return p.traversal.get_dodge_cooldown_left() <= 0.0, 60)
	var t_ready := TimeDirector.now()
	var t2 := await _tap_dash(2)
	print("  cooldown: first dodge at %.3f, ended %.3f; a tap 0.05 s later dodged %s; ready again %.3f s after the end; the next tap dodged %s" % [
		t0, t_end, t1 >= 0.0, t_ready - t_end, t2 >= 0.0])
	check(t0 >= 0.0 and t1 < 0.0 and cd_left > 0.0, "a tap inside R7_DODGE_COOLDOWN does not dodge")
	check(near(t_ready - t_end, Tuning.R7_DODGE_COOLDOWN, 1.0 / 120.0), "the cooldown lasts %.3f s after the dodge (%.2f)" % [
		t_ready - t_end, Tuning.R7_DODGE_COOLDOWN])
	check(t2 >= 0.0, "a tap after the cooldown dodges")
	await settle(p, 30)

# --- Hold into the sprint ------------------------------------------------------------------------
func _hold_into_sprint() -> void:
	await _reset(Vector3(30.0, 0.02, 60.0))
	stick(Vector3.FORWARD)
	await ticks(1)
	var cap := p.traversal.get_speed_cap()
	hold(&"dash")
	await ticks(1)
	var t0 := last_event_time(&"dodged")
	var dodged := t0 >= 0.0
	var min_after := INF
	var t_cap := -1.0
	var sprint_at := -1.0
	var lo_flow := INF  # lowest speed from the dodge's end to 0.1 s after it
	var t_dodge_end := -1.0
	for i in 200:
		await get_tree().physics_frame
		var t := TimeDirector.now() - t0
		var v := hspeed(p)
		if t >= Tuning.DASH_HOLD_SPRINT + 1.0 / 120.0:
			min_after = minf(min_after, v)
		if t_dodge_end < 0.0 and not p.traversal.is_dodging():
			t_dodge_end = t
		if t_dodge_end >= 0.0 and t <= t_dodge_end + 0.1:
			lo_flow = minf(lo_flow, v)
		if sprint_at < 0.0 and p.traversal.is_sprinting():
			sprint_at = t
		if t_cap < 0.0 and p.traversal.sprint_charge >= 0.999:
			t_cap = t
	var v_held := hspeed(p)
	print("  hold Dash (stick forward): dodge %s, sprinting from %.3f s (dodge ended %.3f s), lowest speed after 150 ms %.2f, through the hand-off %.2f, cap %.1f at %.3f s, %.2f m/s at 1.66 s" % [
		dodged, sprint_at, t_dodge_end, min_after, lo_flow, cap, t_cap, v_held])
	check(dodged and sprint_at >= 0.0 and near(sprint_at, Tuning.R7_DODGE_TIME, 1.5 / 120.0),
		"a held press dodges, then flows into the sprint as the dodge ends (%.3f s)" % sprint_at)
	check(min_after >= Tuning.SPRINT_START_SPEED - 0.05, "never under 6 m/s after the 150 ms hold (min %.2f)" % min_after)
	check(near(t_cap, Tuning.SPRINT_RAMP_TIME, 0.1), "the existing ramp reaches the cap %.3f s after the press (1.2 +- 0.1)" % t_cap)
	check(near(v_held, cap, 0.05), "holds the cap (%.2f m/s)" % v_held)
	# Release: the sprint bleeds back to walking over SPRINT_RELEASE_TIME.
	var v0 := hspeed(p)
	var t_rel := TimeDirector.now()
	let_go(&"dash")
	await ticks(2)
	var v1 := hspeed(p)
	var t_walk := -1.0
	for i in 90:
		await get_tree().physics_frame
		if t_walk < 0.0 and hspeed(p) <= Tuning.WALK_SPEED + 0.01:
			t_walk = TimeDirector.now() - t_rel
	print("  release at %.2f m/s: %.2f two ticks later, walking (%.1f) after %.3f s" % [v0, v1, Tuning.WALK_SPEED, t_walk])
	check(v1 > v0 - 0.8 and near(t_walk, Tuning.SPRINT_RELEASE_TIME + 1.0 / 120.0, 0.03),
		"the release bleeds to walking in %.3f s (0.25), as before" % t_walk)
	release_all_input()
	await settle(p, 30)
	# Stick neutral: the back-dodge flows into a run straight back at the ramp's speed.
	await _reset(Vector3(40.0, 0.02, 0.0))
	hold(&"dash")
	await ticks(int(round((Tuning.R7_DODGE_TIME + 0.15) * 120.0)))
	var sprinting := p.traversal.is_sprinting()
	var v := Vector3(p.velocity.x, 0.0, p.velocity.z)
	let_go(&"dash")
	print("  hold Dash, stick neutral: sprinting %s at %.2f m/s along %s" % [sprinting, v.length(), v.normalized()])
	check(sprinting and v.length() >= Tuning.SPRINT_START_SPEED - 0.05 and v.normalized().dot(Vector3.BACK) > 0.98,
		"stick neutral: the back-dodge flows into the sprint along the dodge")
	await settle(p, 30)

# --- Cancels the player's own recovery, never active frames; not buffered ------------------
func _cancel_recovery_not_active() -> void:
	await _reset(Vector3(50.0, 0.02, 0.0))
	# Recovery: a whiffed punch.
	hold(&"punch")
	await ticks(2)
	let_go(&"punch")
	var rec := await wait_until(func() -> bool: return p.combat.is_in_recovery(), 120)
	var t0 := await _tap_dash(2)
	var attacking_after := p.combat.is_attacking()
	print("  Dash in the punch's recovery (%s): dodge %s, still attacking %s" % [rec, t0 >= 0.0, attacking_after])
	check(rec and t0 >= 0.0 and not attacking_after, "a dodge cancels the player's own recovery")
	await settle(p, 30)
	# Startup.
	await _reset(Vector3(50.0, 0.02, 10.0))
	hold(&"punch")
	await ticks(2)
	let_go(&"punch")
	var in_startup := p.combat.is_attacking() and not p.combat.is_attack_active() and not p.combat.is_in_recovery()
	var t1 := await _tap_dash(1)
	print("  Dash in the punch's startup (%s): dodge %s, still attacking %s" % [in_startup, t1 >= 0.0, p.combat.is_attacking()])
	check(not in_startup or (t1 >= 0.0 and not p.combat.is_attacking()), "a dodge cancels the player's own startup")
	await settle(p, 30)
	# Active frames: refused, and not buffered.
	await _reset(Vector3(50.0, 0.02, 20.0))
	hold(&"punch")
	await ticks(2)
	let_go(&"punch")
	var act := await wait_until(func() -> bool: return p.combat.is_attack_active(), 120)
	var move := p.combat.current_move_id()
	hold(&"dash")
	await ticks(1)  # read on this tick, while the active frames run
	var dodged_active := count_events(&"dodged") > 0
	var still := p.combat.is_attacking()
	let_go(&"dash")
	await wait_until(func() -> bool: return not p.combat.is_attacking(), 240)
	await ticks(30)
	print("  Dash in %s's active frames (%s): dodge %s, the attack went on %s, dodges after it %d" % [
		move, act, dodged_active, still, count_events(&"dodged")])
	check(act and not dodged_active and still, "a dodge never cancels active frames")
	check(count_events(&"dodged") == 0, "a Dash press refused in active frames is not buffered")
	await settle(p, 30)

# --- Never while reacting ------------------------------------------------------------------------
func _refused_while_reacting() -> void:
	await _reset(Vector3(60.0, 0.02, 0.0))
	p.react(&"snap", Vector3.BACK, 0.4, 0.45)
	await ticks(2)
	var reacting := p.is_reacting()
	var t0 := await _tap_dash(2)
	print("  Dash while reacting (snap, %s): dodge %s" % [reacting, t0 >= 0.0])
	check(reacting and t0 < 0.0, "no dodge while reacting")
	await settle(p, 60)

# --- Never while holding a body ---------------------------------------------------------------------
func _refused_while_holding() -> void:
	await _reset(Vector3(70.0, 0.02, 0.0))
	var d := install_carry_double(p, 0.7)
	await ticks(2)
	var t0 := await _tap_dash(2)
	var direct := p.traversal.start_dodge(Vector3.RIGHT)
	print("  holding a body: Dash through Input dodged %s, start_dodge() %s" % [t0 >= 0.0, direct])
	check(t0 < 0.0 and not direct and not p.traversal.is_dodging(), "no dodge while holding a body")
	remove_carry_double(p, d)
	await settle(p, 20)
