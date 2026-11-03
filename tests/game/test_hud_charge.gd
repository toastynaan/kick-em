extends Node
## Round 8 HUD (J): the charge meter and the pressure bars.
## - Charge meter (bottom centre): hidden until is_charging(); fills with
##   get_charge() frame by frame; white under the first of get_charge_steps(),
##   orange past it, red past the last (one step: white -> red; none: white);
##   pops when a step is crossed; flashes on charge_full and pulses while full;
##   stays up HUD.CHARGE_HOLD after charge_released; drains and shakes on
##   charge_cancelled; the events alone (no getter) still drive it; a charge
##   whose getter stops with no event counts as released; enemy charges are
##   ignored.
## - Pressure: the Duelist's bar under its health tracks get_pressure() /
##   get_pressure_max() (rises at once, drains when it falls); while
##   is_broken() it is full and flashing, then it empties. Waves enemies get a
##   health + pressure pair when engaged (close, the target, under pressure) or
##   damaged; none over a far untouched enemy or the Duelist; it lifts above a
##   counter prompt and fades out on death. pressure_broken pops "BROKEN".
## - F3 overlay: the charge c and steps, the target's pressure, max, broken
##   time and level, the air hits.
## A test double (_FakeCombat) stands in for CombatController's Round 8
## getters while B works; the last part reads the real CombatController: the
## grunt's bar, and a real held front kick (Input.action_press, with
## debug_launch_step 0.5) whose meter follows B's get_charge(), turns at B's
## step, flashes at full and stays up after the strike fires itself; and real
## jab taps on a level-1 grunt, whose bar follows get_pressure() hit by hit,
## flashes full through the break and empties after it.
## Prints the measured times.

var _fails := 0

func _ready() -> void:
	for i in 5:
		await get_tree().process_frame
	await _run()
	TimeDirector.reset()
	print("TEST test_hud_charge: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

## Real seconds until cond() holds (or max_s), polled every frame.
func _time_until(cond: Callable, max_s: float) -> float:
	var t0 := TimeDirector.now()
	while not cond.call() and TimeDirector.now() - t0 < max_s:
		await get_tree().process_frame
	return TimeDirector.now() - t0

func _run() -> void:
	var world := Node3D.new()
	add_child(world)
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = Layers.WORLD
	floor_body.collision_mask = 0
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80, 1, 80)
	floor_shape.shape = box
	floor_shape.position = Vector3(0, -0.5, 0)
	floor_body.add_child(floor_shape)
	world.add_child(floor_body)
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.look_at_from_position(Vector3(0, 3, 8), Vector3(0, 1, 0))
	cam.make_current()
	var player := FighterFactory.spawn_dummy(world, &"player", Transform3D(Basis(), Vector3(0, 0.05, 2)), Fighter.TEAM_PLAYER)
	var duelist := FighterFactory.spawn_dummy(world, &"duelist", Transform3D(Basis(), Vector3(-3, 0.05, -6)))
	var near := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(1.5, 0.05, -1)))
	var far := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(5, 0.05, -12)))
	var hud := _TestHUD.new()
	var fp := _FakeCombat.new()
	var fd := _FakeCombat.new()
	var fn := _FakeCombat.new()
	var ff := _FakeCombat.new()
	fd.pressure_max = 16.0
	hud.fakes = {player: fp, duelist: fd, near: fn, far: ff}
	add_child(hud)
	hud.set_player(player)
	hud.set_mode(&"duel")
	hud.set_opponent(duelist)
	await _frames(3)

	await _meter(hud, fp, player, duelist)
	await _pressure(hud, fd, fn, ff, duelist, near, far, player)
	await _overlay(hud, fp, fn, player, near)
	await _real(world, cam)

	hud.queue_free()
	await _frames(2)
	for f: _FakeCombat in [fp, fd, fn, ff]:
		f.free()

# --- Charge meter ------------------------------------------------------------------------
func _meter(hud: HUD, fp: _FakeCombat, player: Fighter, duelist: Fighter) -> void:
	var m := hud.get_charge_meter()
	_check(not m.get("visible", true) and not hud._charge.visible, "no charge: meter hidden")
	var r := hud._charge.get_global_rect()
	var vp := get_viewport().get_visible_rect().size
	_check(absf(r.get_center().x - vp.x * 0.5) < 2.0 and r.position.y > vp.y * 0.7,
		"meter at the bottom centre (%.0f, %.0f of %s)" % [r.get_center().x, r.position.y, vp])

	# Charging with steps [0.4, 0.8]: white, orange past the first, red past the last.
	fp.move = &"front_kick"
	fp.steps = [0.4, 0.8]
	fp.c = 0.0
	fp.charging = true
	await _frames(2)
	m = hud.get_charge_meter()
	_check(m["visible"] and m["state"] == &"charging" and is_zero_approx(m["fill"]) and m["tier"] == 0,
		"is_charging(): meter up, empty, white")
	# The meter fills with c, frame by frame.
	var worst := 0.0
	var tiers := {}
	var pops := 0
	var last_tier := 0
	var tier_at := {}
	for i in 61:
		fp.c = i / 60.0
		await _frames(1)
		m = hud.get_charge_meter()
		worst = maxf(worst, absf(float(m["fill"]) - fp.c))
		tiers[m["tier"]] = true
		if int(m["tier"]) != last_tier:
			tier_at[m["tier"]] = fp.c
			if float(m["scale"]) > 1.05:
				pops += 1
			last_tier = m["tier"]
	print("    fill error over a 0 -> 1 ramp: %.4f; colour steps at c = %s" % [worst, tier_at])
	_check(worst < 0.001, "fill follows get_charge() every frame (worst error %.4f)" % worst)
	_check(tier_at.get(1, -1.0) >= 0.4 - 0.001 and tier_at.get(1, -1.0) < 0.4 + 1.0 / 60.0 + 0.001
		and tier_at.get(2, -1.0) >= 0.8 - 0.001 and tier_at.get(2, -1.0) < 0.8 + 1.0 / 60.0 + 0.001,
		"colour steps at the given steps: orange at c %.3f (step 0.4), red at c %.3f (step 0.8)" % [
			tier_at.get(1, -1.0), tier_at.get(2, -1.0)])
	_check(pops == 2, "the bar pops as each step is crossed (%d pops)" % pops)
	var checks := [[0.39, [0.4, 0.8], 0], [0.4, [0.4, 0.8], 1], [0.79, [0.4, 0.8], 1], [0.8, [0.4, 0.8], 2],
		[0.49, [0.5], 0], [0.5, [0.5], 2], [1.0, [], 0], [0.2, [0.25, 0.5, 1.0], 0], [0.6, [0.25, 0.5, 1.0], 1],
		[1.0, [0.25, 0.5, 1.0], 2]]
	var bad := PackedStringArray()
	for ch: Array in checks:
		if HUD.charge_tier(ch[0], ch[1]) != ch[2]:
			bad.append("c %.2f steps %s -> %d" % [ch[0], ch[1], HUD.charge_tier(ch[0], ch[1])])
	_check(bad.is_empty(), "charge_tier: under the first white, past it orange, past the last red; one step white -> red; none white (%s)" % ", ".join(bad))
	_check(HUD.charge_color(0) == UIKit.CHARGE_WHITE and HUD.charge_color(1) == UIKit.CHARGE_ORANGE
		and HUD.charge_color(2) == UIKit.CHARGE_RED, "colours: white, orange, red")
	m = hud.get_charge_meter()
	_check((m["color"] as Color) == UIKit.CHARGE_RED and not m["flashing"], "at c 1 before full: red, not flashing yet")

	# Full: charge_full flashes the bar, then it pulses while held.
	fp.full = true
	GameEvents.charge_full.emit(player, &"front_kick")
	await _frames(1)
	m = hud.get_charge_meter()
	_check(m["flashing"] and m["full"] and (m["draw_color"] as Color).is_equal_approx(Color.WHITE),
		"charge_full: the bar flashes white (%s)" % m["draw_color"])
	var lo := 9.0
	var hi := -9.0
	for i in 40:
		await _frames(1)
		var g := (hud.get_charge_meter()["draw_color"] as Color).g
		lo = minf(lo, g)
		hi = maxf(hi, g)
	_check(hi - lo > 0.3 and hud.get_charge_meter()["flashing"], "held at full it pulses red <-> white (green %.2f .. %.2f)" % [lo, hi])

	# Release: stays up for CHARGE_HOLD, then goes.
	fp.charging = false
	fp.full = false
	GameEvents.charge_released.emit(player, &"front_kick", 2)
	await _frames(1)
	m = hud.get_charge_meter()
	_check(m["visible"] and m["state"] == &"released" and is_equal_approx(float(m["fill"]), 1.0), "charge_released: meter stays up, full")
	var up := 1.0 / 120.0 + await _time_until(func() -> bool: return not hud.get_charge_meter()["visible"], 2.0)
	print("    released: meter up %.3f s (CHARGE_HOLD %.2f)" % [up, HUD.CHARGE_HOLD])
	_check(absf(up - HUD.CHARGE_HOLD) < 0.03, "stays up %.3f s after the release, then hides" % up)

	# Cancel: drains and shakes out.
	fp.steps = [0.5]
	fp.c = 0.7
	fp.charging = true
	await _frames(2)
	fp.charging = false
	GameEvents.charge_cancelled.emit(player, &"jab", &"hit")
	await _frames(1)
	m = hud.get_charge_meter()
	_check(m["visible"] and m["state"] == &"cancelled", "charge_cancelled: the meter shakes out")
	var fills: Array[float] = []
	var max_shake := 0.0
	var t0 := TimeDirector.now()
	while hud.get_charge_meter()["visible"] and TimeDirector.now() - t0 < 2.0:
		fills.append(float(hud.get_charge_meter()["fill"]))
		max_shake = maxf(max_shake, absf(float(hud.get_charge_meter()["shake"])))
		await _frames(1)
	var gone := TimeDirector.now() - t0
	var draining := fills.size() > 5
	for i in range(1, fills.size()):
		if fills[i] > fills[i - 1] + 0.0001:
			draining = false
	print("    cancel: drained 0.70 -> %.2f in %.3f s, peak shake %.1f px" % [fills[fills.size() - 1] if not fills.is_empty() else -1.0, gone, max_shake])
	_check(draining and fills[0] > 0.6 and fills[fills.size() - 1] < 0.1, "a cancel drains the bar (%.2f -> %.2f)" % [
		fills[0] if not fills.is_empty() else -1.0, fills[fills.size() - 1] if not fills.is_empty() else -1.0])
	_check(max_shake > 4.0, "and shakes it (peak %.1f px)" % max_shake)
	_check(absf(gone - HUD.CHARGE_CANCEL_TIME) < 0.04, "gone after %.3f s (CHARGE_CANCEL_TIME %.2f)" % [gone, HUD.CHARGE_CANCEL_TIME])

	# A charge the getter reported that stops with no event: released.
	fp.c = 0.3
	fp.charging = true
	await _frames(2)
	fp.charging = false
	await _frames(1)
	_check(hud.get_charge_meter()["state"] == &"released", "getter stops with no event: counted as released")
	await _time_until(func() -> bool: return not hud.get_charge_meter()["visible"], 1.0)

	# Events alone (no getter reports a charge): c runs on the time held.
	GameEvents.charge_started.emit(player, &"jab")
	await _frames(1)
	_check(hud.get_charge_meter()["visible"], "charge_started alone shows the meter")
	var span := Tuning.debug_charge_full - Tuning.R8_TAP_MAX
	var t_start := TimeDirector.now()
	await _frames(int(span * 0.5 * 120.0))
	var c_half := float(hud.get_charge_meter()["fill"])
	var want := (TimeDirector.now() - t_start) / span
	_check(absf(c_half - want) < 0.03, "events only: fills by the time held (%.2f, expected %.2f)" % [c_half, want])
	GameEvents.charge_level_changed.emit(player, 1)
	await _frames(1)
	_check(float(hud.get_charge_meter()["scale"]) > 1.05, "charge_level_changed pops the bar")
	GameEvents.charge_full.emit(player, &"jab")
	await _frames(1)
	m = hud.get_charge_meter()
	_check(is_equal_approx(float(m["fill"]), 1.0) and m["flashing"], "charge_full alone: full and flashing")
	GameEvents.charge_released.emit(player, &"jab", 1)
	await _frames(1)
	_check(hud.get_charge_meter()["state"] == &"released", "charge_released alone: released")
	await _time_until(func() -> bool: return not hud.get_charge_meter()["visible"], 1.0)

	# Another fighter's charge is not the player's meter.
	GameEvents.charge_started.emit(duelist, &"jab")
	GameEvents.charge_full.emit(duelist, &"jab")
	await _frames(2)
	_check(not hud.get_charge_meter()["visible"], "an enemy's charge events do not show the meter")

# --- Pressure ------------------------------------------------------------------------------
func _pressure(hud: HUD, fd: _FakeCombat, fn: _FakeCombat, ff: _FakeCombat, duelist: Fighter, near: Fighter,
		far: Fighter, player: Fighter) -> void:
	# Duel: under the Duelist's health bar.
	var opp := hud.get_opponent_pressure()
	_check(opp["visible"] and is_zero_approx(opp["fill"]), "duel: the Duelist's pressure bar, empty")
	var pr := hud._opp_pressure.get_global_rect()
	var hr := hud._opp_bars.get_global_rect()
	_check(pr.position.y > hr.position.y + HUD._Bars.HP_H - 1.0 and absf(pr.position.x - hr.position.x) < 1.0 and is_equal_approx(pr.size.x, hr.size.x),
		"it sits under the health bar, as wide (%s under %s)" % [pr, hr])
	var worst := 0.0
	for p: float in [1.0, 2.5, 4.0, 7.5, 12.0, 15.9]:
		fd.pressure = p
		await _frames(1)
		worst = maxf(worst, absf(float(hud.get_opponent_pressure()["fill"]) - p / 16.0))
	_check(worst < 0.001, "the bar tracks get_pressure() / get_pressure_max() as it rises (worst %.4f)" % worst)
	fd.pressure = 8.0
	await _frames(1)
	var mid := float(hud.get_opponent_pressure()["fill"])
	_check(mid < 15.9 / 16.0 and mid > 0.5, "a drop drains rather than snaps (%.3f on the first frame)" % mid)
	var settle := await _time_until(func() -> bool: return absf(float(hud.get_opponent_pressure()["fill"]) - 0.5) < 0.001, 2.0)
	_check(settle < 0.5, "and settles on get_pressure() (%.3f s)" % settle)

	# Broken: full and flashing for as long as is_broken(), then empties.
	fd.broken = true
	fd.pressure = 0.0
	GameEvents.pressure_broken.emit(duelist, player)
	var full_all := true
	for i in 60:
		await _frames(1)
		var o := hud.get_opponent_pressure()
		if not o["broken"] or not is_equal_approx(float(o["fill"]), 1.0):
			full_all = false
	_check(full_all, "while is_broken(): full and flashing for 0.5 s (even with get_pressure() at 0)")
	_check(hud.get_popup_texts().has("BROKEN"), "pressure_broken pops BROKEN over the enemy")
	fd.broken = false
	await _frames(1)
	_check(not hud.get_opponent_pressure()["broken"], "the flash ends with the break")
	var empty := 1.0 / 120.0 + await _time_until(func() -> bool: return is_zero_approx(float(hud.get_opponent_pressure()["fill"])), 2.0)
	print("    broken: the full bar empties in %.3f s after the break" % empty)
	_check(empty > 0.2 and empty < 0.6, "then empties (%.3f s)" % empty)

	# Waves: a bar pair over enemies that are engaged or damaged.
	var bars := func() -> Dictionary:
		var out := {}
		for it: Dictionary in hud.get_enemy_bars():
			out[it["fighter"]] = it
		return out
	await _frames(int(HUD.ENEMY_BAR_FADE * 120.0) + 2)
	var b: Dictionary = bars.call()
	_check(b.has(near) and is_equal_approx(float(b[near]["alpha"]), 1.0), "an enemy within %.0f m of the player shows its bars" % HUD.ENEMY_BAR_ENGAGE)
	_check(not b.has(far), "a far, untouched enemy shows none")
	_check(not b.has(duelist), "the Duelist keeps its top bars only")
	if b.has(near):
		var head := cam_project(near.get_ground_position() + Vector3.UP * near.get_height())
		var pos: Vector2 = b[near]["pos"]
		_check(pos.y < head.y and absf(pos.x - head.x) < 4.0, "the pair sits over the head (%s over %s)" % [pos, head])
	far.apply_damage(10.0, &"test")
	var fade_in := await _time_until(func() -> bool:
		var d: Dictionary = bars.call()
		return d.has(far) and is_equal_approx(float(d[far]["alpha"]), 1.0), 1.0)
	_check(fade_in < HUD.ENEMY_BAR_FADE + 0.02, "damaged: the far enemy's bars fade in (%.3f s)" % fade_in)
	b = bars.call()
	_check(b.has(far) and absf(float(b[far]["hp"]) - far.hp / far.max_hp) < 0.001, "its health bar reads its HP (%.2f)" % (float(b[far]["hp"]) if b.has(far) else -1.0))
	worst = 0.0
	fn.pressure_max = 2.5
	for p: float in [0.5, 1.0, 1.5, 2.0]:
		fn.pressure = p
		await _frames(1)
		b = bars.call()
		worst = maxf(worst, absf(float(b[near]["pressure"]) - p / 2.5) if b.has(near) else 1.0)
	_check(worst < 0.001, "an enemy's pressure bar tracks get_pressure() (worst %.4f)" % worst)
	fn.broken = true
	fn.pressure = 0.0
	await _frames(2)
	b = bars.call()
	_check(b.has(near) and b[near]["broken"] and is_equal_approx(float(b[near]["pressure"]), 1.0), "broken: its bar full and flashing")
	fn.broken = false
	var empty_n := await _time_until(func() -> bool:
		var d: Dictionary = bars.call()
		return d.has(near) and is_zero_approx(float(d[near]["pressure"])), 2.0)
	_check(empty_n > 0.2 and empty_n < 0.6, "then it empties (%.3f s)" % empty_n)
	# Pressure alone engages a far enemy.
	var far2 := FighterFactory.spawn_dummy(near.get_parent(), &"grunt", Transform3D(Basis(), Vector3(-5, 0.05, -12)))
	var f2 := _FakeCombat.new()
	hud.fakes[far2] = f2
	await _frames(int(HUD.ENEMY_BAR_FADE * 120.0) + 2)
	_check(not bars.call().has(far2), "another far untouched enemy: no bars")
	f2.pressure = 1.0
	await _frames(int(HUD.ENEMY_BAR_FADE * 120.0) + 2)
	_check(bars.call().has(far2), "under pressure: it shows them")
	# A counter prompt over the enemy: the bars lift above the badge.
	b = bars.call()
	var y0: float = b[near]["pos"].y if b.has(near) else 0.0
	GameEvents.counter_window.emit(near, player, true, true)
	await _frames(2)
	b = bars.call()
	var y1: float = b[near]["pos"].y if b.has(near) else 0.0
	_check(y0 - y1 > HUD.PROMPT_H, "a counter prompt over it lifts the bars above the badge (%.0f px)" % (y0 - y1))
	GameEvents.counter_window.emit(near, player, false, true)
	# Death: the bars fade out.
	far.apply_damage(far.max_hp + 10.0, &"test")
	var fade_out := await _time_until(func() -> bool: return not bars.call().has(far), 1.0)
	_check(fade_out < HUD.ENEMY_BAR_FADE + 0.03, "a dead enemy's bars fade out (%.3f s)" % fade_out)
	hud.fakes.erase(far2)
	far2.queue_free()
	await _frames(2)
	f2.free()

func cam_project(p: Vector3) -> Vector2:
	return get_viewport().get_camera_3d().unproject_position(p)

# --- F3 overlay ----------------------------------------------------------------------------
func _overlay(hud: HUD, fp: _FakeCombat, fn: _FakeCombat, player: Fighter, near: Fighter) -> void:
	fp.charging = true
	fp.c = 0.47
	fp.steps = [0.5, 1.0]
	fp.full = false
	fp.move = &"front_kick"
	fp.air_hits = 3
	var info := HitInfo.new()
	info.attacker = player
	info.victim = near
	info.move_id = &"jab"
	player.combat.last_dealt = info
	fn.pressure = 2.0
	fn.pressure_max = 2.5
	fn.broken = true
	fn.broken_left = 1.2
	near.level = 2
	await _frames(1)
	var text := hud.get_debug_text()
	var own := text.substr(0, text.find("FPS"))
	print("    overlay:\n      " + "\n      ".join(own.strip_edges().split("\n")))
	_check(own.contains("CHARGE     c 0.47  steps [0.50, 1.00]  front_kick"), "overlay: the charge c and steps")
	_check(own.contains("PRESSURE   2.00 / 2.50 (80%)  BROKEN 1.20 s   level 2"), "overlay: the target's pressure, max, broken time and level")
	_check(own.contains("AIR        hits 3 / %d" % Tuning.debug_air_hits), "overlay: the air hits")
	_check(own.contains("full charge %.2f s" % Tuning.debug_charge_full) and own.contains("air hits %d" % Tuning.debug_air_hits),
		"overlay: the Round 8 upgrades")
	fp.full = true
	var lines := "\n".join(HUD.combat_debug_lines(hud.gather_combat_debug()))
	_check(lines.contains("FULL"), "overlay: FULL at full charge")
	fp.charging = false
	fp.full = false
	fn.broken = false
	fn.pressure = 0.0
	near.level = 1
	player.combat.last_dealt = null
	lines = "\n".join(HUD.combat_debug_lines(hud.gather_combat_debug()))
	_check(lines.contains("CHARGE     -") and lines.contains("PRESSURE   -"), "overlay: '-' with no charge and no target")
	await _frames(int(HUD.CHARGE_HOLD * 120.0) + 4)

# --- The real CombatController ---------------------------------------------------------------
## Whatever B has landed: the plain HUD reads the real getters.
func _real(world: Node3D, _cam: Camera3D) -> void:
	var player := FighterFactory.spawn_dummy(world, &"player", Transform3D(Basis(), Vector3(0, 0.05, 3)), Fighter.TEAM_PLAYER)
	var grunt := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis(), Vector3(-1, 0.05, 1)))
	var hud := HUD.new()
	add_child(hud)
	hud.set_player(player)
	hud.set_mode(&"waves")
	await _frames(int(HUD.ENEMY_BAR_FADE * 120.0) + 3)
	var gc := grunt.combat
	var pc := player.combat
	var it := {}
	for e: Dictionary in hud.get_enemy_bars():
		if e["fighter"] == grunt:
			it = e
	var want := HUD.pressure_fraction(gc.get_pressure(), gc.get_pressure_max(), gc.is_broken())
	print("    real CombatController: grunt pressure %.2f / %.2f broken %s; player charging %s c %.2f steps %s" % [
		gc.get_pressure(), gc.get_pressure_max(), gc.is_broken(), pc.is_charging(), pc.get_charge(), pc.get_charge_steps()])
	_check(not it.is_empty() and absf(float(it["pressure"]) - want) < 0.001,
		"real getters: the grunt's bar reads get_pressure() / get_pressure_max() (%.3f)" % want)
	_check(hud.get_charge_meter()["visible"] == pc.is_charging(), "real getters: the meter follows is_charging() (%s)" % pc.is_charging())
	var cap := Tuning.r8_pressure_cap(grunt.archetype, grunt.level)
	_check(is_equal_approx(gc.get_pressure_max(), cap) or is_equal_approx(gc.get_pressure_max(), Tuning.R8_PRESSURE_CAP_DEFAULT),
		"real get_pressure_max() %.2f (grunt level %d cap %.2f)" % [gc.get_pressure_max(), grunt.level, cap])
	hud.queue_free()
	player.queue_free()
	grunt.queue_free()
	await _frames(2)
	await _real_charge(world)

## A real held front kick through PlayerController and B's charge.
func _real_charge(world: Node3D) -> void:
	var saved_step := Tuning.debug_launch_step
	Tuning.debug_launch_step = 0.5
	var player := FighterFactory.spawn_player(world, Transform3D(Basis(), Vector3(0, 0.05, 4)))
	AttackDirector.set_player(player)
	var hud := HUD.new()
	add_child(hud)
	hud.set_player(player)
	await _frames(30)
	var pc := player.combat
	Input.action_press(&"front_kick")
	var t_press := TimeDirector.now()
	var started := await _time_until(func() -> bool: return pc.is_charging(), 1.0)
	if not pc.is_charging():
		Input.action_release(&"front_kick")
		print("    note: no real charge yet (B / H in progress); the real-charge checks are skipped")
		hud.queue_free()
		player.queue_free()
		Tuning.debug_launch_step = saved_step
		await _frames(2)
		return
	var steps := pc.get_charge_steps()
	print("    real front kick: charging %.3f s after the press, steps %s" % [started, steps])
	var worst := 0.0
	var seen_full := false
	var red_at := -1.0
	var hidden := 0
	while pc.is_charging() and TimeDirector.now() - t_press < 2.0:
		await _frames(1)
		var m := hud.get_charge_meter()
		if not pc.is_charging():
			break
		# The HUD drew last frame's c: compare with B's c of that frame.
		if not m["visible"]:
			hidden += 1
		worst = maxf(worst, absf(float(m["c"]) - pc.get_charge()))
		if red_at < 0.0 and int(m["tier"]) == 2:
			red_at = float(m["c"])
		if m["flashing"]:
			seen_full = true
	var released_state: StringName = hud.get_charge_meter()["state"]
	await _frames(1)
	released_state = hud.get_charge_meter()["state"]
	Input.action_release(&"front_kick")
	var fired_after := TimeDirector.now() - t_press
	var step_c: float = steps[steps.size() - 1] if not steps.is_empty() else 1.0
	print("    real: meter c within %.3f of get_charge() per frame; red from c %.3f (last step %.2f); full flash %s; fired itself %.2f s after the press" % [
		worst, red_at, step_c, seen_full, fired_after])
	_check(hidden == 0, "real charge: the meter is up the whole charge")
	_check(worst <= 1.0 / (120.0 * (Tuning.debug_charge_full - Tuning.R8_TAP_MAX)) + 0.002,
		"real charge: the meter follows B's get_charge() (worst %.3f, one frame of c is %.3f)" % [worst,
			1.0 / (120.0 * (Tuning.debug_charge_full - Tuning.R8_TAP_MAX))])
	_check(red_at >= step_c - 0.002 and red_at <= step_c + 0.03, "real charge: red from B's step c %.2f (at %.3f)" % [step_c, red_at])
	_check(seen_full, "real charge: flashes at full")
	_check(released_state == &"released", "real charge: the strike fired itself; the meter stays up (%s)" % released_state)
	var gone := await _time_until(func() -> bool: return not hud.get_charge_meter()["visible"], 1.0)
	_check(gone < HUD.CHARGE_HOLD + 0.02, "then hides (%.3f s)" % gone)
	hud.queue_free()
	player.queue_free()
	Tuning.debug_launch_step = saved_step
	await _frames(2)
	await _real_pressure(world)

## Real jab taps on a level-1 grunt (cap 2.5): the bar follows B's pressure
## hit by hit, is full and flashing through the break, then empties.
func _real_pressure(world: Node3D) -> void:
	var player := FighterFactory.spawn_player(world, Transform3D(Basis(), Vector3(0, 0.05, 4)))
	AttackDirector.set_player(player)
	var grunt := FighterFactory.spawn_dummy(world, &"grunt", Transform3D(Basis.looking_at(Vector3.BACK, Vector3.UP), Vector3(0, 0.05, 2.9)))
	var hud := HUD.new()
	add_child(hud)
	hud.set_player(player)
	hud.set_mode(&"waves")
	await _frames(30)
	var gc := grunt.combat
	var hits := [0]
	var on_hit := func(info: HitInfo) -> void:
		if info.victim == grunt and info.attacker == player:
			hits[0] += 1
	GameEvents.hit_landed.connect(on_hit)
	var bar := func() -> Dictionary:
		for e: Dictionary in hud.get_enemy_bars():
			if e["fighter"] == grunt:
				return e
		return {}
	var track := PackedStringArray()
	var ok := true
	var broke_on := -1
	for i in 3:
		var n: int = hits[0]
		Input.action_press(&"punch")
		await _frames(8)
		Input.action_release(&"punch")
		await _time_until(func() -> bool: return hits[0] > n, 1.0)
		await _frames(3)
		var b: Dictionary = bar.call()
		var want := HUD.pressure_fraction(gc.get_pressure(), gc.get_pressure_max(), gc.is_broken())
		track.append("hit %d: pressure %.2f / %.2f%s, bar %.2f" % [hits[0], gc.get_pressure(), gc.get_pressure_max(),
			" BROKEN" if gc.is_broken() else "", float(b.get("pressure", -1.0))])
		if b.is_empty() or absf(float(b["pressure"]) - want) > 0.001 or bool(b["broken"]) != gc.is_broken():
			ok = false
		if gc.is_broken() and broke_on < 0:
			broke_on = hits[0]
		await _time_until(func() -> bool: return not player.combat.is_attacking(), 1.5)
	GameEvents.hit_landed.disconnect(on_hit)
	print("    real jabs on a level-1 grunt: %s" % "; ".join(track))
	if hits[0] < 3:
		print("    note: only %d of 3 real jabs landed (B / H in progress); the real-pressure checks are skipped" % hits[0])
	else:
		_check(ok, "real hits: the grunt's bar follows get_pressure() hit by hit")
		_check(broke_on == 3, "real hits: the third tap breaks the level-1 grunt (on hit %d)" % broke_on)
		var full_through := true
		while gc.is_broken():
			await _frames(1)
			var b: Dictionary = bar.call()
			if gc.is_broken() and (b.is_empty() or not b["broken"] or not is_equal_approx(float(b["pressure"]), 1.0)):
				full_through = false
		_check(full_through, "real break: the bar stays full and flashing while is_broken()")
		var empty := await _time_until(func() -> bool:
			var b: Dictionary = bar.call()
			return not b.is_empty() and float(b["pressure"]) <= HUD.pressure_fraction(gc.get_pressure(), gc.get_pressure_max(), false) + 0.001, 1.0)
		print("    real break over: the bar back on get_pressure() (%.2f) %.3f s later" % [gc.get_pressure(), empty])
		_check(empty < 0.6, "then it empties (%.3f s)" % empty)
	hud.queue_free()
	player.queue_free()
	grunt.queue_free()
	await _frames(2)

## CombatController's Round 8 getters, set by the test.
class _FakeCombat extends CombatController:
	var charging := false
	var c := 0.0
	var steps: Array[float] = []
	var full := false
	var move: StringName = &""
	var pressure := 0.0
	var pressure_max := 2.5
	var broken := false
	var broken_left := 0.0
	var air_hits := 0

	func is_charging() -> bool:
		return charging

	func get_charge() -> float:
		return c if charging else 0.0

	func get_charge_move() -> StringName:
		return move if charging else &""

	func get_charge_steps() -> Array[float]:
		var none: Array[float] = []
		return steps if charging else none

	func is_charge_full() -> bool:
		return full

	func get_pressure() -> float:
		return pressure

	func get_pressure_max() -> float:
		return pressure_max

	func get_pressure_fraction() -> float:
		return 1.0 if broken else clampf(pressure / pressure_max, 0.0, 1.0)

	func is_broken() -> bool:
		return broken

	func get_broken_time_left() -> float:
		return broken_left if broken else 0.0

	func get_air_hits() -> int:
		return air_hits

## The HUD reading the doubles for the fighters in `fakes`.
class _TestHUD extends HUD:
	var fakes := {}

	func _combat(f: Fighter) -> CombatController:
		if fakes.has(f):
			return fakes[f]
		return super(f)
