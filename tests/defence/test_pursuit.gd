extends "res://tests/defence/defence_test_base.gd"
## Pursuit (Feel Reference: Pursuit after a launch; Round 7 God path amendment:
## free, at most Tuning.debug_pursuit_max per flight). Every press is real
## input: Shift (dash) -> PlayerController -> CombatController.press(DASH) ->
## Defence.on_dash_pressed (pursuit first). The launches are launch-tier
## HitInfos from the player through take_hit (B's receive path). Agent H:
## - A press inside the window teleports the player Tuning.PURSUIT_DIST from the
##   flying body at its height (teleported kind &"pursuit", GameEvents.pursuit),
##   free; get_pursuit_target() names the body and the player hangs in the air
##   until the hang runs out or an attack starts.
## - A relaunch in the same flight reopens the window; the chain stops at
##   debug_pursuit_max (2 by default; 1; 0 = no pursuit at all).
## - B's pursuit hit (a real punch press during the hang) strikes the body,
##   calls on_pursuit_hit (the target clears) and its relaunch reopens the window.
## - A spiked body (HitInfo.react &"spike") is not pursuable again.
## - The window closes Tuning.PURSUIT_WINDOW real s after the launch's hitstop;
##   a stick pointing away from the body is not a pursuit, one within
##   Tuning.PURSUIT_STICK_CONE is; a press during the launch's hitstop starts the
##   pursuit when it ends.

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	await ticks(30)
	var g := spawn_attacker(p, &"grunt", Vector3(0, 0, -1.2))
	g.max_hp = 100000.0
	g.hp = g.max_hp
	await ticks(20)
	var max_was := Tuning.debug_pursuit_max
	var teleport_was := Tuning.debug_teleport
	Tuning.debug_teleport = false  # nothing else may take the press

	# --- The chain, capped at debug_pursuit_max. ------------------------------------------------
	for cap: int in [2, 1, 0]:
		Tuning.debug_pursuit_max = cap
		print("pursuit chain, debug_pursuit_max %d" % cap)
		g.take_hit(scripted_hit(p, g, HitInfo.Tier.LAUNCH, 7.0))
		await ticks(2)
		check(g.is_launched(), "cap %d: the launch hit sends the grunt flying" % cap)
		var got := 0
		for n in cap + 1:
			await _wait_flying(g)
			clear_events()
			press(&"dash")
			await ticks(1)  # the tick the press is read: measure before the body flies on
			var ev := _event(&"teleported")
			var com := g.get_center_of_mass()
			release(&"dash")
			await ticks(1)
			if ev.is_empty():
				break
			got += 1
			check(ev[5] == &"pursuit" and count_events(&"pursuit") == 1, "cap %d, pursuit %d: teleported (kind pursuit), GameEvents.pursuit" % [cap, got])
			check(p.defence.pursuit_chain(g) == got and p.defence.get_pursuit_target() == g, "cap %d, pursuit %d: chain %d, target set" % [cap, got, p.defence.pursuit_chain(g)])
			if got == 1:
				var flat := Vector2(p.global_position.x - com.x, p.global_position.z - com.z).length()
				print("  pursuit: %.2f m from the body (want %.1f), feet %.2f m, body COM %.2f m" % [flat, Tuning.PURSUIT_DIST, p.global_position.y, com.y])
				check(absf(flat - Tuning.PURSUIT_DIST) < 0.15, "appeared %.2f m from the body" % flat)
				check(p.global_position.y > 0.05 or com.y < 1.2, "up at the body's height")
				var y_hang := p.global_position.y
				await ticks(6)
				check(p.is_hanging() and absf(p.global_position.y - y_hang) < 0.02,
					"hangs in the air waiting for the attack (moved %.3f m)" % absf(p.global_position.y - y_hang))
			# The follow-up relaunch (scripted here) reopens the window.
			g.take_hit(scripted_hit(p, g, HitInfo.Tier.LAUNCH, 7.0))
			await ticks(2)
			p.defence.on_pursuit_hit(g)
		print("  cap %d: %d pursuits before the refusal" % [cap, got])
		check(got == cap, "cap %d: exactly %d pursuits chain off one flight (got %d)" % [cap, cap, got])
		await _reset(p, g)

	# --- B's pursuit hit: a real punch during the hang. ----------------------------------------
	Tuning.debug_pursuit_max = 2
	print("B's pursuit hit")
	clear_events()
	g.take_hit(scripted_hit(p, g, HitInfo.Tier.LAUNCH, 7.0))
	await _wait_flying(g)
	await _dash()
	var hanging := p.is_hanging() and p.defence.get_pursuit_target() == g
	clear_events()
	press(&"punch")
	await ticks(1)
	release(&"punch")
	await wait_until(func() -> bool: return last_hit_by(p) != null, 90)
	var hit := last_hit_by(p)
	await ticks(2)
	print("  pursuit hit: %s, react %s, pursuit %s; target now %s; window reopened %s"
		% [hit, hit.react if hit else &"-", hit.pursuit if hit else false, p.defence.get_pursuit_target(),
		g.is_launched()])
	check(hanging, "the press pursued and the player hangs")
	check(hit != null and hit.victim == g and hit.pursuit, "a punch during the hang strikes the flying body (a pursuit hit)")
	check(p.defence.get_pursuit_target() == null, "the hit clears the pursuit target (on_pursuit_hit)")
	if hit != null and HitInfo.is_launch_tier(hit.tier):
		await _wait_flying(g)
		clear_events()
		await _dash()
		check(count_events(&"teleported") == 1 and p.defence.pursuit_chain(g) == 2, "the relaunch reopens the window: pursuit 2")
	else:
		check(hit != null and hit.react == &"spike", "the pursuit hit relaunches (or spikes)")
	await _reset(p, g)

	# --- A spiked body is not pursuable again. ---------------------------------------------
	print("spike")
	clear_events()
	g.take_hit(scripted_hit(p, g, HitInfo.Tier.LAUNCH, 7.0))
	await _wait_flying(g)
	await _dash()
	var spike := scripted_hit(p, g, HitInfo.Tier.LAUNCH, 7.0)
	spike.react = &"spike"
	spike.pursuit = true
	spike.result = HitInfo.Result.HIT
	GameEvents.hit_landed.emit(spike)  # the hit B reports for a spike
	await _wait_flying(g)
	clear_events()
	var again := p.defence.on_dash_pressed(TimeDirector.now())
	check(not again and count_events(&"teleported") == 0, "after a spike the body is not pursuable")
	await _reset(p, g)

	# --- Window: 0.5 s after the launch's hitstop. -------------------------------------
	print("window")
	clear_events()
	g.take_hit(scripted_hit(p, g, HitInfo.Tier.LAUNCH, 7.0))
	await wait_real(Power.hitstop_for(HitInfo.Tier.LAUNCH) + Tuning.PURSUIT_WINDOW + 0.05)
	await _dash()
	check(count_events(&"teleported") == 0, "a press 0.55 s after the hitstop: no pursuit (a dodge: %d)" % count_events(&"dodged"))
	await _reset(p, g)

	# --- Stick pointing away: not a pursuit. ---------------------------------------------
	print("stick away")
	clear_events()
	g.take_hit(scripted_hit(p, g, HitInfo.Tier.LAUNCH, 6.0))
	await wait_real(Power.hitstop_for(HitInfo.Tier.LAUNCH) + 0.1)
	press(&"move_back")  # the body flies toward -Z; back is +Z (no camera: world axes)
	await ticks(2)
	await _dash()
	release(&"move_back")
	check(count_events(&"teleported") == 0, "stick away from the body: no pursuit")
	await _reset(p, g)

	# --- Stick toward the body (within 60 degrees): pursuit. --------------------------------
	print("stick toward")
	clear_events()
	g.take_hit(scripted_hit(p, g, HitInfo.Tier.LAUNCH, 6.0))
	await wait_real(Power.hitstop_for(HitInfo.Tier.LAUNCH) + 0.1)
	press(&"move_forward")
	press(&"move_right")
	await ticks(2)
	await _dash()
	release(&"move_forward")
	release(&"move_right")
	check(count_events(&"teleported") == 1, "stick 45 degrees off the body: pursuit")
	await _reset(p, g)

	# --- Pressed during the launch's hitstop: appears once the body flies. ------------------
	print("pressed in the hitstop")
	clear_events()
	g.take_hit(scripted_hit(p, g, HitInfo.Tier.HARD_LAUNCH, 8.0))
	await ticks(2)
	await _dash()
	check(count_events(&"teleported") == 0, "not yet: the body is still in its hitstop")
	await wait_real(Power.hitstop_for(HitInfo.Tier.HARD_LAUNCH) + 0.05)
	check(count_events(&"teleported") == 1, "the pursuit starts when the hitstop ends")
	Tuning.debug_pursuit_max = max_was
	Tuning.debug_teleport = teleport_was
	done()

## A real Dash tap (Shift): B gives it to Defence first, else Traversal.
func _dash() -> void:
	press(&"dash")
	await ticks(1)
	release(&"dash")
	await ticks(1)

## Wait until `g`'s launch hitstop is over and it has flown 0.1 s.
func _wait_flying(g: Fighter) -> void:
	await wait_until(func() -> bool: return not g.is_frozen(), 60)
	await wait_real(0.1)

func _event(what: StringName) -> Array:
	for i in range(events.size() - 1, -1, -1):
		if events[i][0] == what:
			return events[i]
	return []

func _reset(p: Fighter, g: Fighter) -> void:
	await wait_until(func() -> bool: return not g.is_launched(), 900)
	await wait_until(func() -> bool: return not p.is_airborne() and not p.is_hanging(), 240)
	await settle(p)
	await reset_fighter(p, Vector3.ZERO, Vector3.FORWARD)
	await reset_fighter(g, Vector3(0, 0, -1.2), Vector3.BACK)
	await settle(g)
	g.hp = g.max_hp
	await ticks(30)
