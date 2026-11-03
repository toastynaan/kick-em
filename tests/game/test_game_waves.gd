extends Node
## GameMode waves (Feel Reference: Health, damage and enemies; F11): the wave
## mix (Tuning.WAVES, then +1 enemy per wave from WAVE_GROWTH_MIX), at most
## MAX_ENEMIES_ON_FIELD alive, AttackDirector.set_wave per wave, the last kill
## (GameEvents.last_kill, the next wave held until it has played), 25 HP back
## between waves, no regen during a wave, and the player's death ending the run.
## Round 8: Waves use the player's own upgrades (not the Duel's max); an
## enemy close to the player in view gets a health + pressure pair that reads
## the real CombatController; the enemies' levels are printed.

const RUN_SECONDS := 8.0

var _fails := 0
var _waves_started: Array = []
var _waves_cleared: Array = []
var _round_over: Array = []
var _last_kills: Array = []
var _event_times := {}   ## name -> real s
var _max_alive := 0
var _freeze_ai := false   ## after the free run: enemy brains off, so only the test deals damage

func _ready() -> void:
	GameEvents.wave_started.connect(func(i: int, _t: int) -> void:
		_waves_started.append(i)
		_event_times["wave_started_%d" % i] = TimeDirector.now())
	GameEvents.wave_cleared.connect(func(i: int) -> void:
		_waves_cleared.append(i)
		_event_times["wave_cleared_%d" % i] = TimeDirector.now())
	GameEvents.round_over.connect(func(w: bool) -> void: _round_over.append(w))
	GameEvents.last_kill.connect(func(f: Node3D) -> void:
		_last_kills.append(f)
		_event_times["last_kill_%d" % _last_kills.size()] = TimeDirector.now())
	await get_tree().process_frame
	_check_mix()
	await _run()
	TimeDirector.reset()
	print("TEST test_game_waves: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _count(mix: Array[StringName]) -> Dictionary:
	var d := {}
	for a in mix:
		d[a] = int(d.get(a, 0)) + 1
	return d

## Feel Reference: wave 1 is 3 grunts; wave 2, 5 grunts; wave 3, 4 grunts and a
## stick enemy; wave 4, 4 grunts and a heavy. After that, one enemy more per wave.
func _check_mix() -> void:
	_check(_count(GameMode.wave_mix(0)) == {&"grunt": 3}, "wave 1: 3 grunts %s" % _count(GameMode.wave_mix(0)))
	_check(_count(GameMode.wave_mix(1)) == {&"grunt": 5}, "wave 2: 5 grunts %s" % _count(GameMode.wave_mix(1)))
	_check(_count(GameMode.wave_mix(2)) == {&"grunt": 4, &"stick": 1}, "wave 3: 4 grunts + stick %s" % _count(GameMode.wave_mix(2)))
	_check(_count(GameMode.wave_mix(3)) == {&"grunt": 4, &"heavy": 1}, "wave 4: 4 grunts + heavy %s" % _count(GameMode.wave_mix(3)))
	var sizes := PackedInt32Array()
	var grows := true
	for i in 20:
		var n := GameMode.wave_mix(i).size()
		sizes.append(n)
		if i >= Tuning.WAVES.size():
			var prev := _count(GameMode.wave_mix(i - 1))
			var cur := _count(GameMode.wave_mix(i))
			var added: StringName = Tuning.WAVE_GROWTH_MIX[(i - Tuning.WAVES.size()) % Tuning.WAVE_GROWTH_MIX.size()]
			prev[added] = int(prev.get(added, 0)) + 1
			if cur != prev:
				grows = false
	_check(grows, "waves 5-20 add one enemy each, cycling WAVE_GROWTH_MIX (sizes %s)" % sizes)
	_check(GameMode.wave_mix(4)[0] == &"heavy" and GameMode.wave_mix(2)[0] == &"stick",
		"special enemies first in the queue (they make the breach entrance)")

func _alive_on_field() -> int:
	var n := 0
	for e in get_tree().get_nodes_in_group(&"enemies"):
		var f := e as Fighter
		if f and not f.is_dead():
			n += 1
	return n

## The free run must not end early whatever the AI and impacts deal: give the
## player a deep pool for it (restored to the 100 scale before any HP check).
func _shield(gm: GameMode, on: bool) -> void:
	if not is_instance_valid(gm.player):
		return
	gm.player.max_hp = 100000.0 if on else Tuning.ARCHETYPES[&"player"]["hp"]
	gm.player.hp = gm.player.max_hp

func _step(gm: GameMode, frames: int) -> void:
	for i in frames:
		if _freeze_ai:
			for f in gm.get_alive_enemies():
				if f.brain and f.brain.process_mode != Node.PROCESS_MODE_DISABLED:
					f.brain.process_mode = Node.PROCESS_MODE_DISABLED
		await get_tree().physics_frame
		_max_alive = maxi(_max_alive, maxi(_alive_on_field(), gm.get_alive_enemies().size()))
		_clear_spawns(gm)

## Walk-in stand-in: move enemies off their spawn points so the next ones can
## spawn quickly (works the same whether or not the AI walks them in).
func _clear_spawns(gm: GameMode) -> void:
	var spawns := gm.arena.get_enemy_spawns()
	for f in gm.get_alive_enemies():
		for e: Dictionary in spawns:
			var p: Vector3 = e["position"]
			if Vector2(f.global_position.x - p.x, f.global_position.z - p.z).length() < 2.5:
				f.global_position = Vector3(randf_range(-6.0, 6.0), f.global_position.y, randf_range(-6.0, 2.0))
				f.reset_physics_interpolation()
				break

## Kill every enemy as it appears until the wave is empty. Returns the last one killed.
func _kill_wave(gm: GameMode, max_frames: int) -> Fighter:
	var last: Fighter = null
	for i in max_frames:
		for f in gm.get_alive_enemies():
			last = f
			f.apply_damage(f.max_hp + 10.0, &"test")
		await _step(gm, 1)
		if gm.get_enemies_left() == 0:
			return last
	return null

func _run() -> void:
	var gm := GameMode.new()
	gm.show_title = false
	gm.breather_time = 1.0
	add_child(gm)
	gm.start_round(&"waves")
	await get_tree().process_frame
	_shield(gm, true)
	_check(_waves_started == [0], "wave_started(0) emitted")
	_check(gm.wave_total == 0, "waves are endless (wave_total 0)")
	_check(AttackDirector.wave_index == 1, "AttackDirector.set_wave(1) at wave 1 (wave_index %d)" % AttackDirector.wave_index)
	_check(gm.get_enemies_left() == 3, "wave 1 has 3 enemies (%d)" % gm.get_enemies_left())
	_check(not gm.hud._opp_root.visible, "waves show no enemy HP bar")
	_check(gm.hud._mode_label.text == "WAVE 1", "HUD reads 'WAVE 1' (%s)" % gm.hud._mode_label.text)
	_check(not GameMenus.is_max_upgrades_applied(), "Round 8: Waves use the player's own upgrades")

	# Make the queue bigger than the field cap to exercise the cap.
	for i in 9:
		gm._wave_queue.append(&"grunt")
	var tps := Engine.physics_ticks_per_second
	await _step(gm, int(RUN_SECONDS * tps))
	_check(_max_alive > 0, "enemies spawned (max alive %d)" % _max_alive)
	_check(_max_alive <= Tuning.MAX_ENEMIES_ON_FIELD, "never more than %d alive (max %d)" % [Tuning.MAX_ENEMIES_ON_FIELD, _max_alive])
	if gm.is_round_over():
		_check(false, "round ended during the free run")
		return

	# No regen during a wave: 50 HP never goes up until the wave ends.
	_freeze_ai = true
	await _step(gm, 2)
	await _check_enemy_bars(gm)
	_shield(gm, false)
	gm.player.apply_damage(50.0, &"test")
	var hp_max_seen := [gm.player.hp]
	for i in int(0.5 * tps):
		await _step(gm, 1)
		hp_max_seen[0] = maxf(hp_max_seen[0], gm.player.hp)
	_check(hp_max_seen[0] <= 50.0 + 0.01, "no regen during a wave (hp never above %.1f in 0.5 s)" % hp_max_seen[0])
	var hp_at_clear := [gm.player.hp]
	GameEvents.wave_cleared.connect(func(_i: int) -> void: hp_at_clear[0] = gm.player.hp, CONNECT_ONE_SHOT)
	var last := await _kill_wave(gm, int(30.0 * tps))
	_check(last != null, "wave 1 emptied by kills")
	await get_tree().physics_frame
	_check(_last_kills.size() == 1 and _last_kills[0] == last, "last_kill emitted with the wave's last enemy")
	_check(gm.phase == GameMode.Phase.CLEARING and _waves_cleared.is_empty(), "the wave holds while the last kill plays")
	await _wait_until(func() -> bool: return not _waves_cleared.is_empty(), 6.0)
	var hold: float = _event_times.get("wave_cleared_0", 0.0) - _event_times.get("last_kill_1", 0.0)
	var slow: Dictionary = Tuning.SLOW_TIME[&"last_kill"]
	_check(_waves_cleared == [0] and hold >= float(slow["time"]) - 0.02,
		"wave_cleared(0) only after the last-kill close-up played (%.2f s after last_kill; slow time %.2f s)" % [hold, slow["time"]])
	var healed: float = gm.player.hp - hp_at_clear[0]
	_check(absf(healed - Tuning.HEAL_BETWEEN_WAVES_HP) < 0.5, "%.0f HP back between waves (+%.1f)" % [Tuning.HEAL_BETWEEN_WAVES_HP, healed])
	await _wait_until(func() -> bool: return _waves_started.size() >= 2, gm.breather_time + 2.0)
	_check(gm.wave_index == 1 and _waves_started == [0, 1], "advanced to wave 2")
	_check(AttackDirector.wave_index == 2, "AttackDirector.set_wave(2) at wave 2 (%d)" % AttackDirector.wave_index)
	_check(gm.hud._mode_label.text == "WAVE 2", "HUD reads 'WAVE 2'")
	await _step(gm, int(1.0 * tps))
	_check(gm.get_enemies_left() == 5, "wave 2 has 5 enemies (%d)" % gm.get_enemies_left())

	# A full-health player is not over-healed.
	gm.player.hp = gm.player.max_hp
	await _kill_wave(gm, int(30.0 * tps))
	await _wait_until(func() -> bool: return _waves_cleared.size() >= 2, 6.0)
	_check(is_equal_approx(gm.player.hp, gm.player.max_hp), "healing never passes max HP (%.0f)" % gm.player.hp)
	await _wait_until(func() -> bool: return _waves_started.size() >= 3, gm.breather_time + 2.0)
	_check(gm.get_enemies_left() == 5, "wave 3 has 5 enemies (%d)" % gm.get_enemies_left())

	gm.player.apply_damage(gm.player.max_hp + 10.0, &"test")
	await _step(gm, 3)
	_check(gm.is_round_over(), "killing the player ends the run")
	_check(_round_over == [false], "round_over(false) emitted")
	await _wait_until(func() -> bool: return gm.menus.screen == GameMenus.Screen.ROUND_OVER, 4.0)
	_check(gm.menus.screen == GameMenus.Screen.ROUND_OVER, "results screen shown")
	_check(int(gm.menus.last_results.get("waves_cleared", -1)) == 2, "results: 2 waves cleared (%s)" % gm.menus.last_results.get("waves_cleared"))
	_check(_max_alive <= Tuning.MAX_ENEMIES_ON_FIELD, "cap held for the whole test (max %d)" % _max_alive)

## Round 8: an enemy placed in view 3 m in front of the player shows its
## health + pressure pair, reading the real CombatController.
func _check_enemy_bars(gm: GameMode) -> void:
	var alive := gm.get_alive_enemies()
	var levels := PackedStringArray()
	for f in alive:
		levels.append("%s L%d" % [f.archetype, f.level])
	print("    wave 1 enemy levels: %s" % ", ".join(levels))
	if alive.is_empty() or gm.camera_rig == null:
		_check(false, "an enemy to show bars over")
		return
	var f: Fighter = alive[0]
	var fwd := -gm.camera_rig.get_camera().global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	f.global_position = gm.player.global_position + fwd * 3.0 + Vector3.UP * 0.05
	f.reset_physics_interpolation()
	await _step(gm, int(0.4 * Engine.physics_ticks_per_second))
	var it := {}
	for e: Dictionary in gm.hud.get_enemy_bars():
		if e["fighter"] == f:
			it = e
	var c := f.combat
	var want := HUD.pressure_fraction(c.get_pressure(), c.get_pressure_max(), c.is_broken())
	_check(not it.is_empty() and absf(float(it["pressure"]) - want) < 0.02 and absf(float(it["hp"]) - f.hp / f.max_hp) < 0.001,
		"an engaged enemy shows health + pressure from the real CombatController (pressure %.2f / %.2f, bars %s)" % [
			c.get_pressure(), c.get_pressure_max(), it.get("pressure", "none")])

func _wait_until(cond: Callable, max_real: float) -> void:
	var until := TimeDirector.now() + max_real
	while not cond.call() and TimeDirector.now() < until:
		await get_tree().physics_frame
