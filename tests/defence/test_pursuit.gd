extends "res://tests/defence/defence_test_base.gd"
## F6 pursuit (Feel Reference: Pursuit after a launch). Acceptance (agent H, with B):
## - A pursuit hit relaunches at no less than max(current speed, v(P + 3)).
## - A third pursuit is refused (at most 2 chain off one launch).
## The chain runs through real input only: a charged kick launches, then Dash
## + a tapped kick twice (B's pipeline relaunches), then a third Dash. The
## relaunch is checked on the body's first free tick after the hit's hitstop,
## within 2% of the rule.
## Also: 1 Focus each, the player appears 1.2 m from the body at its height and
## hangs there; the window closes 0.5 s of real time after the launch's
## hitstop; a stick pointing away from the body is not a pursuit; no Focus, no
## pursuit (these rule checks open the window with a launch HitInfo through
## take_hit, B's real receive path).

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	await ticks(30)
	var g := spawn_attacker(p, &"grunt", Vector3(0, 0, -1.2))
	await ticks(20)

	# --- A real chain: charged kick launch, pursuit + kick, pursuit + kick, third refused. ---
	# Everything goes through the player's input (Input -> PlayerController ->
	# CombatController -> Defence / B's hit pipeline); nothing is scripted.
	print("pursuit chain through real input")
	p.focus = 3.0
	clear_events()
	press(&"kick")  # held to charge level 2: P = 2.5 x 2.3 = 5.75, a launch
	await wait_real(Tuning.CHARGE_LEVELS[1] + 0.05)
	release(&"kick")
	await wait_until(func() -> bool: return last_hit_by(p) != null, 120)
	var launch := last_hit_by(p)
	check(launch != null and HitInfo.is_launch_tier(launch.tier) and g.is_launched(),
		"charged kick launches the grunt (%s)" % [launch])
	var worst := 0.0
	for n in [1, 2]:
		await _wait_flying(g)
		var f0 := p.focus
		clear_events()
		press(&"dash")
		await ticks(1)
		release(&"dash")
		var ev := _event(&"teleported")
		check(not ev.is_empty() and ev[5] == &"pursuit", "pursuit %d: Dash after the launch teleports (kind pursuit)" % n)
		check(is_equal_approx(p.focus, f0 - Tuning.PURSUIT_COST), "pursuit %d cost 1 bar (%.2f -> %.2f)" % [n, f0, p.focus])
		check(p.defence.pursuit_chain(g) == n, "chain %d" % p.defence.pursuit_chain(g))
		if n == 1:
			var com := g.get_center_of_mass()
			var flat := Vector2(p.global_position.x - com.x, p.global_position.z - com.z).length()
			check(absf(flat - Tuning.PURSUIT_DIST) < 0.15, "appeared %.2f m from the body (want %.1f)" % [flat, Tuning.PURSUIT_DIST])
			check(p.global_position.y > 0.05 or com.y < 1.2, "up at the body's height (feet %.2f m, body COM %.2f m)" % [p.global_position.y, com.y])
			check(p.defence.get_pursuit_target() == g, "pursuit target set")
			var y_hang := p.global_position.y
			await ticks(6)
			check(absf(p.global_position.y - y_hang) < 0.02, "hangs in the air waiting for the attack (moved %.3f m)" % absf(p.global_position.y - y_hang))
		var r := await _pursuit_kick(p, g)
		if r.is_empty():
			check(false, "pursuit %d: the follow-up kick landed" % n)
			break
		var info: HitInfo = r["info"]
		var want: float = r["want"]
		var err: float = (r["after"] - want) / want
		worst = maxf(worst, absf(err))
		print("  pursuit %d hit: %s; body %.3f m/s before; relaunch %.3f m/s; body %.3f m/s on its first free tick; rule max(%.3f, v(P %.2f + 3) = %.3f) = %.3f (%+.1f%%)"
			% [n, info, r["before"], info.launch_velocity.length(), r["after"], r["before"], info.power,
			Power.launch_speed(info.power + 3.0), want, err * 100.0])
		check(info.pursuit and HitInfo.is_launch_tier(info.tier), "pursuit %d: B marks a pursuit hit and relaunches" % n)
		check(info.launch_velocity.length() >= want - 1e-3, "pursuit %d: relaunch velocity %.3f >= %.3f m/s" % [n, info.launch_velocity.length(), want])
		check(absf(err) <= 0.02, "pursuit %d: the body flies on at %.3f m/s, the rule's %.3f within 2%% (%+.1f%%)" % [n, r["after"], want, err * 100.0])
	print("  worst relaunch error vs max(current, v(P + 3)): %.2f%%" % (worst * 100.0))
	# The third: still flying, inside the window, a bar in hand, the stick neutral: refused.
	await _wait_flying(g)
	var f2 := p.focus
	clear_events()
	check(g.is_launched() and f2 >= Tuning.PURSUIT_COST, "third try: the body is still flying, %.2f bars" % f2)
	press(&"dash")
	await ticks(1)
	release(&"dash")
	check(count_events(&"teleported") == 0, "a third pursuit is refused (chain %d / %d)" % [p.defence.pursuit_chain(g), Tuning.PURSUIT_MAX])
	check(is_equal_approx(p.focus, f2), "no Focus spent on the refused pursuit (%.2f)" % p.focus)
	await _reset(p, g)

	# --- Window: 0.5 s after the launch's hitstop. -------------------------------------
	print("window")
	p.focus = 3.0
	clear_events()
	g.take_hit(scripted_hit(p, g, HitInfo.Tier.LAUNCH, 7.0))
	await wait_real(Power.hitstop_for(HitInfo.Tier.LAUNCH) + Tuning.PURSUIT_WINDOW + 0.05)
	var late := p.defence.on_dash_pressed(TimeDirector.now())
	check(not late and count_events(&"teleported") == 0, "Dash 0.55 s after the hitstop: no pursuit")
	await _reset(p, g)

	# --- Stick pointing away: a sprint, not a pursuit. -----------------------------------
	print("stick away")
	p.focus = 3.0
	clear_events()
	g.take_hit(scripted_hit(p, g, HitInfo.Tier.LAUNCH, 6.0))
	await wait_real(Power.hitstop_for(HitInfo.Tier.LAUNCH) + 0.1)
	press(&"move_back")  # the body flies toward -Z; back is +Z (no camera: world axes)
	await ticks(2)
	press(&"dash")
	await ticks(1)
	release(&"dash")
	release(&"move_back")
	check(count_events(&"teleported") == 0 and is_equal_approx(p.focus, 3.0), "stick away from the body: no pursuit, no Focus spent")
	await _reset(p, g)

	# --- Stick toward the body (within 60 degrees): pursuit. --------------------------------
	print("stick toward")
	clear_events()
	g.take_hit(scripted_hit(p, g, HitInfo.Tier.LAUNCH, 6.0))
	await wait_real(Power.hitstop_for(HitInfo.Tier.LAUNCH) + 0.1)
	press(&"move_forward")
	press(&"move_right")
	await ticks(2)
	press(&"dash")
	await ticks(1)
	release(&"dash")
	release(&"move_forward")
	release(&"move_right")
	check(count_events(&"teleported") == 1, "stick 45 degrees off the body: pursuit")
	await _reset(p, g)

	# --- Pressed during the launch's hitstop: appears once the body flies. ------------------
	print("pressed in the hitstop")
	clear_events()
	p.focus = 3.0
	g.take_hit(scripted_hit(p, g, HitInfo.Tier.HARD_LAUNCH, 8.0))
	await ticks(2)
	press(&"dash")
	await ticks(1)
	release(&"dash")
	check(count_events(&"teleported") == 0, "not yet: the body is still in its hitstop")
	await wait_real(Power.hitstop_for(HitInfo.Tier.HARD_LAUNCH) + 0.05)
	check(count_events(&"teleported") == 1, "the pursuit starts when the hitstop ends")
	await _reset(p, g)

	# --- No Focus: no pursuit. -----------------------------------------------------------
	print("no Focus")
	p.focus = 0.5
	clear_events()
	g.take_hit(scripted_hit(p, g, HitInfo.Tier.LAUNCH, 6.0))
	await wait_real(Power.hitstop_for(HitInfo.Tier.LAUNCH) + 0.1)
	check(not p.defence.on_dash_pressed(TimeDirector.now()), "half a bar: Dash is not a pursuit")
	done()

## Wait until `g`'s launch hitstop is over and it has flown 0.1 s.
func _wait_flying(g: Fighter) -> void:
	await wait_until(func() -> bool: return not g.is_frozen(), 60)
	await wait_real(0.1)

## A tapped kick into the pursued body through the input path. Returns
## {info, before, after, want}: the body's speed on the tick before the hit,
## on its first tick after the hit's hitstop, and the rule max(before, v(P + 3)).
func _pursuit_kick(p: Fighter, g: Fighter) -> Dictionary:
	clear_events()
	press(&"kick")
	await ticks(1)
	release(&"kick")
	var before := g.get_com_velocity().length()
	for i in 60:
		if last_hit_by(p) != null:
			break
		before = g.get_com_velocity().length()
		await get_tree().physics_frame
	var info := last_hit_by(p)
	if info == null:
		return {}
	await wait_until(func() -> bool: return not g.is_frozen(), 60)
	await get_tree().physics_frame
	var after := g.get_com_velocity().length()
	return {"info": info, "before": before, "after": after, "want": Power.pursuit_speed(info.power, before)}

func _event(what: StringName) -> Array:
	for i in range(events.size() - 1, -1, -1):
		if events[i][0] == what:
			return events[i]
	return []

func wait_real(seconds: float) -> void:
	var t0 := TimeDirector.now()
	while TimeDirector.now() - t0 < seconds:
		await get_tree().physics_frame

func _reset(p: Fighter, g: Fighter) -> void:
	await wait_until(func() -> bool: return not g.is_launched(), 900)
	await settle(p)
	await reset_fighter(p, Vector3.ZERO, Vector3.FORWARD)
	await reset_fighter(g, Vector3(0, 0, -1.2), Vector3.BACK)
	await settle(g)
	g.hp = g.max_hp
	await ticks(30)
