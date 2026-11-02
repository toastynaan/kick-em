extends "res://tests/move/move_test_base.gd"
## F7 jump and landings (Feel Reference: Jump; Landing has levels). Checks,
## with measured numbers:
## - standing jump apex 1.2 m, full-speed jump apex 1.5 m, horizontal speed kept;
## - coyote time 0.1 s off a ledge; a press 0.12 s before landing is buffered;
## - landing levels: Soft for a normal jump, Hard for jumping off the 1.8 m
##   platform, Heavy for a slam off the platform; the slam stumbles a dummy 2 m away
##   and knocks down one inside 1 m;
## - over 200 scripted landings the player is never knocked down;
## - hang() holds the player in the air until it ends or an attack starts.

const PLATFORM_H := 1.8

var _platform: StaticBody3D

## Simulated seconds (the timeout counts fixed-fps time).
func _init() -> void:
	_timeout = 900.0

func run() -> void:
	# A 1.8 m platform (10 x 10 m) away from the open floor.
	_platform = make_box(Vector3(30.0, PLATFORM_H * 0.5, 0.0), Vector3(10.0, PLATFORM_H, 10.0), "Platform")
	var p := spawn_player(Vector3(0.0, 0.0, 0.0))
	await ticks(30)
	await _standing_jump(p)
	await _sprint_jump(p)
	await _coyote(p)
	await _buffer(p)
	await _platform_levels(p)
	await _slam(p)
	await _roll(p)
	await _many_landings(p)
	await _air_dash(p)
	await _hang(p)
	done()

func _jump_apex(p: Fighter) -> Dictionary:
	var y0 := p.global_position.y
	var x0 := p.global_position
	var top := y0
	var h0 := hspeed(p)
	var hmin := INF
	var hmax := 0.0
	clear_events()
	p.traversal.on_jump_pressed()
	var t0 := TimeDirector.now()
	await ticks(1)
	while p.traversal.is_airborne():
		top = maxf(top, p.global_position.y)
		hmin = minf(hmin, hspeed(p))
		hmax = maxf(hmax, hspeed(p))
		await get_tree().physics_frame
		if TimeDirector.now() - t0 > 3.0:
			break
	var land := last_event(&"landing")
	return {"apex": top - y0, "h0": h0, "hmin": hmin, "hmax": hmax, "air": TimeDirector.now() - t0,
		"dist": Vector2(p.global_position.x - x0.x, p.global_position.z - x0.z).length(),
		"level": land[1] if not land.is_empty() else &"", "vs": float(land[3]) if not land.is_empty() else 0.0}

func _standing_jump(p: Fighter) -> void:
	await settle(p, 20)
	var r := await _jump_apex(p)
	print("  standing jump: apex %.3f m, air %.3f s, landing %s at %.2f m/s" % [r["apex"], r["air"], r["level"], r["vs"]])
	check(near(r["apex"], Tuning.JUMP_HEIGHT, 0.03), "standing jump apex %.3f m (1.2)" % r["apex"])
	check(r["level"] == &"soft" and near(r["vs"], 6.1, 0.15), "a normal jump lands Soft at %.2f m/s (6.1)" % r["vs"])
	check(count_events(&"jumped") == 1, "one jumped event")

func _sprint_jump(p: Fighter) -> void:
	await settle(p, 20)
	p.global_position = Vector3(0.0, 0.0, 40.0)
	await sprint_to_cap(p, Vector3.FORWARD)
	await ticks(5)
	var r := await _jump_apex(p)
	var walk_r := {}
	print("  full-speed jump: apex %.3f m, take-off %.2f m/s, in the air %.2f..%.2f, distance %.2f m, landing %s at %.2f" % [
		r["apex"], r["h0"], r["hmin"], r["hmax"], r["dist"], r["level"], r["vs"]])
	check(near(r["apex"], Tuning.JUMP_HEIGHT_SPRINT, 0.03), "full-speed jump apex %.3f m (1.5)" % r["apex"])
	check(r["hmin"] >= r["h0"] - 0.02 and r["hmax"] <= r["h0"] + 0.02, "horizontal speed kept exactly (%.2f..%.2f of %.2f)" % [r["hmin"], r["hmax"], r["h0"]])
	check(r["level"] == &"soft" and near(r["vs"], 6.9, 0.15), "a full-speed jump lands Soft at %.2f m/s (6.9)" % r["vs"])
	check(p.traversal.is_sprinting(), "the sprint carries on after a soft landing with Dash held")
	await settle(p, 30)
	# A walking jump goes much less far than the sprint jump.
	p.global_position = Vector3(0.0, 0.0, 40.0)
	p.move_input = Vector3.FORWARD
	await ticks(60)
	walk_r = await _jump_apex(p)
	print("  walking jump distance %.2f m vs sprint jump %.2f m" % [walk_r["dist"], r["dist"]])
	check(r["dist"] > walk_r["dist"] * 1.5, "a sprint jump goes much further (%.2f vs %.2f m)" % [r["dist"], walk_r["dist"]])
	await settle(p, 30)

func _coyote(p: Fighter) -> void:
	# Walk off the platform edge, press Jump 0.08 s after leaving it: a jump.
	await settle(p, 20)
	p.global_position = Vector3(30.0, PLATFORM_H + 0.02, 2.0)
	await ticks(20)
	p.move_input = Vector3.BACK  # +Z, toward the edge at z = 5
	var left := await wait_until(func() -> bool: return p.traversal.is_airborne(), 240)
	var t_left := TimeDirector.now()
	await wait_until(func() -> bool: return TimeDirector.now() - t_left >= 0.08, 30)
	clear_events()
	var vy_before := p.velocity.y
	p.traversal.on_jump_pressed()
	await ticks(1)
	var jumped := count_events(&"jumped") == 1 and p.velocity.y > 3.0
	print("  coyote: left the ledge %s, pressed 0.08 s later, vy %.2f -> %.2f, jumped %s" % [left, vy_before, p.velocity.y, jumped])
	check(left and jumped, "a Jump 0.08 s after running off a ledge still jumps (coyote 0.1 s)")
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	await settle(p, 20)
	# Too late: 0.15 s after leaving the ledge.
	p.global_position = Vector3(30.0, PLATFORM_H + 0.02, 2.0)
	await ticks(20)
	p.move_input = Vector3.BACK
	await wait_until(func() -> bool: return p.traversal.is_airborne(), 240)
	t_left = TimeDirector.now()
	await wait_until(func() -> bool: return TimeDirector.now() - t_left >= 0.15, 40)
	clear_events()
	p.traversal.on_jump_pressed()
	await ticks(1)
	check(count_events(&"jumped") == 0, "a Jump 0.15 s after leaving the ledge does not jump")
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	await ticks(2)
	check(count_events(&"jumped") == 0, "...and is not buffered into a jump on landing (pressed > 0.12 s before)")
	await settle(p, 30)

func _buffer(p: Fighter) -> void:
	await settle(p, 20)
	p.global_position = Vector3(0.0, 0.0, 0.0)
	await ticks(10)
	p.traversal.on_jump_pressed()
	await ticks(1)
	# Falling: press 0.1 s before the floor (predicted from height and speed).
	await wait_until(func() -> bool:
		var y := p.global_position.y
		var v := -p.velocity.y
		return v > 0.0 and y <= v * 0.1 + 0.5 * Tuning.PLAYER_GRAVITY * Tuning.FALL_GRAVITY_MULT * 0.01, 240)
	clear_events()
	var t_press := TimeDirector.now()
	p.traversal.on_jump_pressed()
	await wait_until(func() -> bool: return count_events(&"landing") > 0, 60)
	var t_land := TimeDirector.now()
	await ticks(2)
	print("  buffer: pressed %.3f s before landing, jumped again: %d" % [t_land - t_press, count_events(&"jumped")])
	check(t_land - t_press <= Tuning.JUMP_BUFFER_TIME and count_events(&"jumped") == 1 and p.traversal.is_airborne(),
		"a Jump pressed %.3f s before landing fires on landing (buffer 0.12 s)" % (t_land - t_press))
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	await settle(p, 30)

func _platform_levels(p: Fighter) -> void:
	# Jump off the platform: Hard (about 9.7 m/s).
	await settle(p, 20)
	p.global_position = Vector3(30.0, PLATFORM_H + 0.02, 4.4)
	await ticks(20)
	p.move_input = Vector3.BACK
	await ticks(16)
	clear_events()
	p.traversal.on_jump_pressed()
	p.move_input = Vector3.ZERO
	var m := {"fall": 0.0}
	await wait_until(func() -> bool:
		m["fall"] = maxf(float(m["fall"]), p.traversal.get_fall_height())
		return count_events(&"landing") > 0, 360)
	var land := last_event(&"landing")
	print("  jump off the 1.8 m platform: %s at %.2f m/s, fall height %.2f m, knocked down %s" % [
		land[1], float(land[3]), m["fall"], p.is_down()])
	check(near(float(m["fall"]), PLATFORM_H + Tuning.JUMP_HEIGHT, 0.08), "get_fall_height() reaches %.2f m (3.0)" % m["fall"])
	check(land[1] == &"hard" and near(float(land[3]), 9.7, 0.3), "jumping off the platform lands Hard at %.2f m/s (9.7)" % float(land[3]))
	check(p.traversal.is_landing(), "a hard landing crouches (%.2f s)" % Tuning.LAND_HARD_CROUCH)
	check(not p.is_down(), "the hard landing does not knock the player down")
	await settle(p, 40)

func _slam(p: Fighter) -> void:
	await settle(p, 20)
	p.global_position = Vector3(30.0, PLATFORM_H + 0.02, 4.2)
	await ticks(20)
	p.move_input = Vector3.BACK * 0.5
	await ticks(12)
	clear_events()
	p.traversal.on_jump_pressed()
	p.move_input = Vector3.ZERO
	await wait_until(func() -> bool: return p.velocity.y < 0.0 and p.global_position.z > 5.4, 120)
	var h := p.global_position.y
	var ok := p.traversal.begin_drop_strike()
	print("  slam: dropping strike from %.2f m above the floor, accepted %s, slamming %s" % [h, ok, p.traversal.is_slamming()])
	check(ok and p.traversal.is_slamming(), "an air attack from %.2f m (>= 2 m) is a ground slam" % h)
	# Dummies around the predicted landing point (they spawn while the player drops).
	var gf := Tuning.PLAYER_GRAVITY * Tuning.FALL_GRAVITY_MULT
	var v0 := -p.velocity.y
	var t_fall := (-v0 + sqrt(v0 * v0 + 2.0 * gf * h)) / gf
	var land_pt := p.global_position + Vector3(p.velocity.x, 0.0, p.velocity.z) * t_fall
	land_pt.y = 0.0
	var far_d := spawn_enemy(&"grunt", land_pt + Vector3(2.0, 0.0, 0.0), Vector3.LEFT)
	var near_d := spawn_enemy(&"grunt", land_pt + Vector3(-0.8, 0.0, 0.0), Vector3.RIGHT)
	var out_d := spawn_enemy(&"grunt", land_pt + Vector3(0.0, 0.0, 3.2), Vector3.FORWARD)
	await wait_until(func() -> bool: return count_events(&"landing") > 0, 360)
	var land := last_event(&"landing")
	var shock := count_events(&"shockwave")
	await ticks(3)
	var reacted := {}
	for e in events_of(&"hit_landed"):
		var info := e[0] as HitInfo
		if info != null and info.attacker == p:
			reacted[info.victim] = info
	var fd: HitInfo = reacted.get(far_d)
	var nd: HitInfo = reacted.get(near_d)
	var lp: Vector3 = land[2]
	var d_far := Vector2(far_d.global_position.x - lp.x, far_d.global_position.z - lp.z).length()
	var d_near := Vector2(near_d.global_position.x - lp.x, near_d.global_position.z - lp.z).length()
	print("  slam lands %s at %.2f m/s, shockwaves %d; dummy at %.2f m: %s; dummy at %.2f m: %s; dummy at 3.2 m hit: %s" % [
		land[1], float(land[3]), shock, d_far, HitInfo.tier_name(fd.tier) if fd else &"-",
		d_near, HitInfo.tier_name(nd.tier) if nd else &"-", reacted.has(out_d)])
	check(land[1] == &"heavy", "a slam off the platform lands Heavy")
	check(shock == 1, "the heavy landing sends one shockwave")
	check(fd != null and fd.tier == HitInfo.Tier.STUMBLE and d_far > 1.0 and d_far <= 2.5,
		"the slam stumbles a dummy %.2f m away" % d_far)
	check(nd != null and nd.tier == HitInfo.Tier.KNOCKDOWN, "the slam knocks down a dummy %.2f m away (inside 1 m)" % d_near)
	check(not reacted.has(out_d), "a dummy 3.2 m away is untouched")
	check(not p.is_down(), "the slam never knocks the player down")
	await settle(p, 120)
	for d in [far_d, near_d, out_d]:
		d.queue_free()
	await ticks(2)

## A heavy landing holding a direction rolls, keeping 85% of horizontal speed.
func _roll(p: Fighter) -> void:
	await settle(p, 20)
	p.global_position = Vector3(30.0, PLATFORM_H + 0.02, -4.5)
	p.snap_facing(Vector3.BACK)
	await ticks(10)
	p.move_input = Vector3.BACK
	dash_down(p)
	await wait_until(func() -> bool: return p.global_position.z >= 4.4, 300)
	p.traversal.on_jump_pressed()  # off the edge at a sprint, then slam from the top of the arc
	await wait_until(func() -> bool: return p.velocity.y < 0.0, 120)
	dash_up(p)
	var ok := p.traversal.begin_drop_strike() and p.traversal.is_slamming()
	var m := {"h": 0.0}
	await wait_until(func() -> bool:
		if p.traversal.is_airborne():
			m["h"] = hspeed(p)
		return not p.traversal.is_airborne(), 240)
	var h_in: float = m["h"]
	var kind := p.traversal.get_landing_kind()
	var h_out := hspeed(p)
	var land := last_event(&"landing")
	print("  slam running off the platform at %.2f m/s (drop %s): lands %s, %s, keeps %.2f (%.1f%%)" % [
		h_in, ok, land[1] if not land.is_empty() else &"-", kind, h_out, h_out / maxf(h_in, 0.01) * 100.0])
	check(kind == &"roll" and near(h_out, h_in * Tuning.LAND_ROLL_KEEP, 0.1),
		"a heavy landing holding a direction rolls, keeping %.1f%% (85%%)" % (h_out / maxf(h_in, 0.01) * 100.0))
	check(not p.is_down(), "the roll keeps the player on the feet")
	await settle(p, 40)

## 200 scripted landings of every level: standing jumps, sprint jumps, platform
## drops, slams, rolls. The player is never knocked down.
func _many_landings(p: Fighter) -> void:
	await settle(p, 20)
	var cnt := {"downs": 0}
	var counts := {&"soft": 0, &"hard": 0, &"heavy": 0}
	var rolls := 0
	var watch := func(_old: int, new_state: int) -> void:
		if new_state != RagdollController.State.ANIMATED:
			cnt["downs"] += 1
	p.ragdoll.state_changed.connect(watch)
	for i in 200:
		var kind := i % 5
		clear_events()
		match kind:
			0:  # standing jump
				p.global_position = Vector3(-20.0, 0.02, 0.0)
				await ticks(4)
				p.traversal.on_jump_pressed()
			1:  # sprint jump on the open floor
				p.global_position = Vector3(-30.0, 0.02, 30.0)
				p.move_input = Vector3.FORWARD
				dash_down(p)
				await ticks(40)
				p.traversal.on_jump_pressed()
			2:  # off the platform
				p.global_position = Vector3(30.0, PLATFORM_H + 0.02, 4.0)
				p.move_input = Vector3.BACK
				await ticks(14)
				p.traversal.on_jump_pressed()
				p.move_input = Vector3.ZERO if i % 2 == 0 else Vector3.BACK
			3:  # slam off the platform, holding a direction (roll) or not
				p.global_position = Vector3(30.0, PLATFORM_H + 0.02, 4.0)
				p.move_input = Vector3.BACK
				await ticks(14)
				p.traversal.on_jump_pressed()
				await wait_until(func() -> bool: return p.velocity.y < 0.0, 120)
				p.traversal.begin_drop_strike()
				p.move_input = Vector3.BACK if i % 2 == 1 else Vector3.ZERO
			4:  # run off the platform at full speed (no jump)
				p.global_position = Vector3(30.0, PLATFORM_H + 0.02, -4.0)
				p.move_input = Vector3.BACK
				dash_down(p)
				await ticks(4)
		await wait_until(func() -> bool: return count_events(&"landing") > 0, 400)
		var land := last_event(&"landing")
		if not land.is_empty():
			counts[land[1]] = int(counts.get(land[1], 0)) + 1
			if p.traversal.get_landing_kind() == &"roll":
				rolls += 1
		if p.is_down():
			cnt["downs"] += 1
		await ticks(2)
		p.move_input = Vector3.ZERO
		if p.traversal.is_dash_held():
			dash_up(p)
		await wait_until(func() -> bool: return not p.traversal.is_landing() and not p.traversal.is_airborne(), 120)
		await ticks(2)
	p.ragdoll.state_changed.disconnect(watch)
	var downs: int = cnt["downs"]
	var total := int(counts[&"soft"]) + int(counts[&"hard"]) + int(counts[&"heavy"])
	print("  200 scripted landings: %d logged (soft %d, hard %d, heavy %d, rolls %d), knocked down %d times" % [
		total, counts[&"soft"], counts[&"hard"], counts[&"heavy"], rolls, downs])
	check(total == 200, "200 landings logged (%d)" % total)
	check(int(counts[&"soft"]) > 0 and int(counts[&"hard"]) > 0 and int(counts[&"heavy"]) > 0, "every landing level happened")
	check(downs == 0, "over 200 landings the player is never knocked down (%d)" % downs)
	await settle(p, 20)

## A Dash tap in the air is the short dash (an air dash): 3 m, height held,
## once per airtime, and it adds nothing to the power score.
func _air_dash(p: Fighter) -> void:
	await settle(p, 20)
	p.global_position = Vector3(-40.0, 0.02, 0.0)
	p.snap_facing(Vector3.FORWARD)
	await ticks(10)
	p.traversal.on_jump_pressed()
	await wait_until(func() -> bool: return p.velocity.y < 0.5, 120)
	p.move_input = Vector3.FORWARD
	var x0 := p.global_position
	var st0 := p.traversal.speed_toward(Vector3.FORWARD)
	dash_down(p)
	await ticks(1)
	dash_up(p)
	var dashing := p.traversal.is_air_dashing()
	var m := {"st": 0.0, "dy": 0.0, "peak": 0.0}
	while p.traversal.is_air_dashing():
		m["st"] = maxf(float(m["st"]), p.traversal.speed_toward(Vector3.FORWARD))
		m["dy"] = maxf(float(m["dy"]), absf(p.global_position.y - x0.y))
		m["peak"] = maxf(float(m["peak"]), hspeed(p))
		await get_tree().physics_frame
	var d := Vector2(p.global_position.x - x0.x, p.global_position.z - x0.z).length()
	dash_down(p)
	await ticks(1)
	dash_up(p)
	var again := p.traversal.is_air_dashing()
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	print("  air dash at the apex: dashing %s, %.2f m, peak %.2f m/s, height drift %.3f m, speed_toward %.2f (before %.2f), second dash %s" % [
		dashing, d, m["peak"], m["dy"], m["st"], st0, again])
	check(dashing and near(d, Tuning.SHORT_DASH_DIST, 0.15), "a Dash tap in the air is a %.2f m air dash (3 m)" % d)
	check(float(m["dy"]) < 0.02, "the air dash holds its height")
	check(float(m["st"]) <= st0 + 0.05, "the air dash adds no earned speed (power)")
	check(not again, "one air dash per airtime")
	p.move_input = Vector3.ZERO
	await settle(p, 20)

func _hang(p: Fighter) -> void:
	await settle(p, 20)
	p.global_position = Vector3(0.0, 0.02, -20.0)
	await ticks(10)
	p.traversal.on_jump_pressed()
	await ticks(20)
	var y0 := p.global_position.y
	p.traversal.hang(0.25)
	await ticks(24)
	var y1 := p.global_position.y
	var held := absf(y1 - y0) < 0.01 and p.velocity.length() < 0.01 and p.traversal.is_hanging()
	await ticks(10)
	var falls := not p.traversal.is_hanging() and p.velocity.y < 0.0
	print("  hang 0.25 s at %.2f m: drift %.3f m, hanging %s, falls after %s" % [y0, y1 - y0, held, falls])
	check(held, "hang() holds the player in the air (no gravity, zero velocity)")
	check(falls, "the hang ends after its time and the player falls")
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	# An attack ends a hang early, and that strike is not a dropping strike.
	p.traversal.on_jump_pressed()
	await ticks(20)
	p.traversal.hang(1.0)
	await ticks(5)
	p.combat.press(CombatController.Action.LIGHT)
	p.combat.release(CombatController.Action.LIGHT)
	p.traversal.on_strike_started(false)
	await ticks(2)
	check(not p.traversal.is_hanging(), "an attack ends the hang")
	check(not p.traversal.begin_drop_strike(), "the attack out of a hang is not a dropping strike")
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	await settle(p, 20)
