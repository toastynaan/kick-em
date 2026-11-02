extends Node
## F11 acceptance (J), Round 6 Yard: at the end of a wave, the logged counts of
## bodies, broken props and clutter, wall holes, structure collapses, floor
## marks and decals match what was created; bodies stay for the round (no timed
## fade) up to Tuning.CORPSE_MAX, past which the oldest fade. Restart and back to
## the menu clear everything Round 6 adds.
## Wave 1 breaks two wall panels, a breakable prop, a loose prop and a thrown
## prop (ThrowableProp.shatter), puts down blood pools and kills 3 enemies, then waits
## out the old 20 s corpse timer before wave 2. Wave 2 kills enough to pass the
## cap. Prints GameMode's persistence line for each wave.

const BREATHER := 22.0   ## s: longer than the old Tuning.CORPSE_FADE_AFTER (20 s)

var _fails := 0
var _gm: GameMode
var _death_order: Array[int] = []

func _ready() -> void:
	GameEvents.fighter_died.connect(func(f: Node3D, _i: HitInfo) -> void:
		if f != null and f.is_in_group(&"enemies"):
			_death_order.append(f.get_instance_id()))
	await get_tree().process_frame
	await _run()
	TimeDirector.reset()
	print("TEST test_persistence: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)

func _check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		_fails += 1

func _frames(n: int) -> void:
	for i in n:
		_hold_still()
		await get_tree().physics_frame

## The test does all the damage: enemy brains off, the player topped up.
func _hold_still() -> void:
	if _gm == null:
		return
	if is_instance_valid(_gm.player):
		_gm.player.hp = _gm.player.max_hp
	for f in _gm.get_alive_enemies():
		if f.brain and f.brain.process_mode != Node.PROCESS_MODE_DISABLED:
			f.brain.process_mode = Node.PROCESS_MODE_DISABLED

func _kill_all(max_frames: int) -> void:
	for i in max_frames:
		for f in _gm.get_alive_enemies():
			f.apply_damage(f.max_hp + 10.0, &"test")
		await _frames(1)
		if _gm.get_enemies_left() == 0:
			return

func _wait_until(cond: Callable, max_game_s: float) -> void:
	var frames := int(max_game_s * Engine.physics_ticks_per_second)
	for i in frames:
		if cond.call():
			return
		await _frames(1)

func _bodies_in_scene() -> int:
	var n := 0
	for node in get_tree().get_nodes_in_group(&"fighters"):
		var f := node as Fighter
		if f != null and f != _gm.player and f.is_dead() and not f.is_queued_for_deletion():
			n += 1
	return n

func _run() -> void:
	_gm = GameMode.new()
	_gm.show_title = false
	_gm.breather_time = BREATHER
	add_child(_gm)
	_gm.start_round(&"waves")
	await _frames(5)

	# --- Wave 1: break things, make blood, kill 3 ------------------------------------
	var panels: Array[Destructible] = []
	var crate: Destructible = null
	for d in _gm.arena.get_destructibles():
		if d.is_unbreakable() or d.is_broken or d.has_meta(&"staged_breach"):
			continue
		if d.kind == &"panel" and d.style != &"rolldoor" and panels.size() < 2:
			panels.append(d)
		elif d.kind == &"desk" and crate == null:
			crate = d
	_check(panels.size() == 2 and crate != null, "arena has panels and a desk to break")
	for p in panels:
		p.force_break(p.global_position, -p.global_basis.z * 6.0)
	if crate:
		crate.force_break(crate.global_position, Vector3.FORWARD * 4.0)
	var loose: Node3D = null
	for n in get_tree().get_nodes_in_group(&"props"):
		if not (n is Destructible) and not (n is ThrowableProp) and n.has_method(&"receive_strike"):
			loose = n
			break
	if loose:
		loose.call(&"receive_strike", _gm.player, loose.global_position, Vector3.FORWARD, 1.0e6)
	# A thrown brick bursting: a real ThrowableProp broken through D's scripted break.
	var brick := ThrowableProp.new()
	brick.kind = &"brick"
	_gm.arena.add_child(brick)
	brick.global_position = _gm.player.global_position + Vector3(2.0, 0.5, 0.0)
	await _frames(2)
	if brick.has_method(&"shatter"):
		brick.call(&"shatter")
	else:
		GameEvents.prop_broken.emit(brick, brick.global_position, &"brick")
	var at := _gm.player.global_position
	for i in 6:
		BloodFX.pool(at + Vector3(1.0 + i * 0.7, 0.3, 1.5), 0.6)

	# Round 6: clutter of different kinds broken four ways, a pillar snapped
	# (its overhead piece comes down), the floor cracked, cratered and rubbled.
	var clutter: Array = get_tree().get_nodes_in_group(&"clutter").filter(
		func(n: Node) -> bool: return n.get(&"is_broken") == false and n.get(&"is_loose") != true)
	print("    the Yard holds %d clutter objects" % clutter.size())
	_check(clutter.size() >= 4, "the Yard has clutter to break (%d)" % clutter.size())
	var kinds := {}
	var ways := [&"force", &"impact", &"strike", &"force"]
	var smashed: Array = []
	for c in clutter:
		if smashed.size() >= ways.size():
			break
		if kinds.has(c.get(&"kind")):
			continue
		kinds[c.get(&"kind")] = true
		var pos: Vector3 = (c as Node3D).global_position + Vector3.UP * 0.4
		match ways[smashed.size()]:
			&"force":
				c.call(&"force_break", pos, Vector3.FORWARD * 3.0, _gm.player)
			&"impact":
				c.call(&"receive_impact", 1.0e6, pos, Vector3.FORWARD * 12.0)
			&"strike":
				c.call(&"receive_strike", _gm.player, pos, Vector3.FORWARD, 1.0e6)
		smashed.append(c)
	await _frames(2)
	var smashed_ok := smashed.size() == ways.size()
	for c in smashed:
		smashed_ok = smashed_ok and c.get(&"is_broken") == true
	_check(smashed_ok, "%d clutter objects of %d kinds broken (force, impact, strike)" % [smashed.size(), kinds.size()])
	var pillar: Node3D = null
	for n in get_tree().get_nodes_in_group(&"pillars"):
		if n.get(&"is_broken") == false and n.has_method(&"receive_impact"):
			pillar = n
			break
	if pillar:
		var e := float(pillar.get(&"break_energy")) * 1.5 + 1.0
		pillar.call(&"receive_impact", e, pillar.global_position + Vector3.UP * 1.0, Vector3(10.0, 0.0, 0.0))
	_check(pillar != null and pillar.get(&"is_broken") == true, "a pillar snapped")
	var spots := [Vector3(-3.0, 0.0, 3.0), Vector3(-5.5, 0.0, 3.0), Vector3(-8.0, 0.0, 3.0), Vector3(-10.5, 0.0, 3.0)]
	WorldDamage.damage_floor(at + spots[0], 2500.0)   # crack
	WorldDamage.damage_floor(at + spots[1], 6000.0)   # crater
	WorldDamage.damage_floor(at + spots[2], 12000.0)  # rubble
	WorldDamage.damage_floor(at + spots[3], 2600.0)   # two hard landings on one spot...
	WorldDamage.damage_floor(at + spots[3], 2600.0)   # ...accumulate to a crater
	await _frames(int((Tuning.PILLAR_COLLAPSE_DELAY + 1.5) * Engine.physics_ticks_per_second))
	await _kill_all(int(20.0 * Engine.physics_ticks_per_second))
	await _wait_until(func() -> bool: return _gm.phase == GameMode.Phase.BREATHER, 6.0)
	_check(_gm.persistence_log.size() == 1, "wave 1 logged its persistence report")
	if _gm.persistence_log.is_empty():
		return
	var r1: Dictionary = _gm.persistence_log[0]
	print("    " + GameMode.persistence_line(r1))
	_check(r1["bodies_created"] == 3 and r1["bodies_present"] == 3, "wave 1: 3 bodies created, 3 in the scene")
	_check(r1["holes_events"] >= 3 and r1["holes_ok"], "wave 1: wall holes (2 panels + the pillar) %d events / %d world" % [r1["holes_events"], r1["holes_world"]])
	var props_made := (1 if crate else 0) + (1 if loose else 0) + 1 + smashed.size()
	_check(r1["props_events"] >= props_made and r1["props_ok"],
		"wave 1: props + clutter broken %d events / %d world (at least %d made)" % [r1["props_events"], r1["props_world"], props_made])
	_check(r1["collapses_events"] >= 1 and r1["collapses_ok"] and r1["falling_pieces"] >= r1["overhead_events"],
		"wave 1: collapses %d events / %d world, %d overhead, %d fallen pieces in the scene" % [r1["collapses_events"],
		r1["collapses_world"], r1["overhead_events"], r1["falling_pieces"]])
	var fe: Array = r1["floor_events"]
	var fw: Array = r1["floor_world"]
	_check(fe[0] >= 1 and fe[1] >= 2 and fe[2] >= 1 and r1["floor_ok"],
		"wave 1: floor crack/crater/rubble %s events / %s world, %d marks (cap %d)" % [fe, fw, r1["marks_live"], Tuning.FLOOR_DECAL_MAX])
	_check(r1["decals_created"] >= 6 and r1["decals_ok"],
		"wave 1: decals %d created, %d accounted for (%d live)" % [r1["decals_created"], r1["decals_accounted"], r1["decals_live"]])
	_check(r1["ok"], "wave 1: every count matches")

	# --- Bodies stay: no timed fade -------------------------------------------------------
	var t_dead := TimeDirector.now()
	await _wait_until(func() -> bool: return _gm.wave_index == 1, BREATHER + 4.0)
	var waited := TimeDirector.now() - t_dead
	_check(_gm.wave_index == 1, "wave 2 started after the breather")
	_check(_bodies_in_scene() == 3, "%d bodies still there %.1f s after the kills (no timed fade)" % [_bodies_in_scene(), waited])

	# --- Wave 2: pass CORPSE_MAX ---------------------------------------------------------
	var extra := Tuning.CORPSE_MAX + 1 - 3 - _gm.get_enemies_left()
	for i in maxi(extra, 0):
		_gm._wave_queue.append(&"grunt")
	var total := 3 + _gm.get_enemies_left()
	# More blood than the cap: the oldest decals go, the count still adds up.
	for i in Tuning.BLOOD_DECAL_MAX + 8:
		BloodFX.pool(at + Vector3(-6.0 + (i % 8) * 0.9, 0.3, -4.0 - floorf(i / 8.0) * 0.9), 0.4)
	_gm.breather_time = 1.0
	await _kill_all(int(60.0 * Engine.physics_ticks_per_second))
	await _wait_until(func() -> bool: return _gm.persistence_log.size() >= 2, 6.0)
	await _frames(int(GameMode.CORPSE_FADE_TIME * Engine.physics_ticks_per_second) + 30)
	_check(_gm.persistence_log.size() == 2, "wave 2 logged its persistence report")
	if _gm.persistence_log.size() < 2:
		return
	var r2: Dictionary = _gm.persistence_log[1]
	print("    " + GameMode.persistence_line(r2))
	_check(r2["bodies_created"] == total, "wave 2: %d bodies created in the round (%d)" % [total, r2["bodies_created"]])
	_check(r2["bodies_present"] == Tuning.CORPSE_MAX and r2["bodies_ok"], "wave 2: %d bodies kept (cap %d)" % [r2["bodies_present"], Tuning.CORPSE_MAX])
	_check(_bodies_in_scene() == Tuning.CORPSE_MAX, "after the fade, exactly %d bodies in the scene (%d)" % [Tuning.CORPSE_MAX, _bodies_in_scene()])
	var oldest_gone := true
	for i in total - Tuning.CORPSE_MAX:
		if is_instance_valid(instance_from_id(_death_order[i])):
			oldest_gone = false
	var newest_kept := true
	for i in range(total - Tuning.CORPSE_MAX, total):
		if not is_instance_valid(instance_from_id(_death_order[i])):
			newest_kept = false
	_check(oldest_gone and newest_kept, "the %d oldest bodies faded, the newest %d stayed" % [total - Tuning.CORPSE_MAX, Tuning.CORPSE_MAX])
	_check(r2["blood_decals"] <= Tuning.BLOOD_DECAL_MAX and r2["decals_ok"],
		"wave 2: %d blood decals live (cap %d), %d created = %d accounted (%d evicted)" % [r2["blood_decals"],
		Tuning.BLOOD_DECAL_MAX, r2["decals_created"], r2["decals_accounted"], r2["decals_evicted"]])
	_check(r2["ok"], "wave 2: every count matches")

	# --- Restart and back to the menu clear Round 6's world ---------------------------
	var clutter_before := get_tree().get_nodes_in_group(&"clutter").size()
	_gm.start_round(&"waves")
	await _frames(10)
	_check_clean("restart")
	var clutter_after := get_tree().get_nodes_in_group(&"clutter")
	var intact := clutter_after.filter(func(n: Node) -> bool: return n.get(&"is_broken") == false)
	_check(clutter_after.size() == clutter_before and intact.size() == clutter_after.size(),
		"restart: the rebuilt Yard has all %d clutter objects intact (%d intact)" % [clutter_after.size(), intact.size()])
	_gm.back_to_menu()
	await _frames(10)
	_check(_gm.phase == GameMode.Phase.TITLE, "back to the menu")
	_check_clean("main menu")

## Nothing from the last round is left: broken things, floor, collapses, debris, decals.
func _check_clean(when: String) -> void:
	var wc: Dictionary = DebrisManager.get_world_counts() if DebrisManager.has_method(&"get_world_counts") else {}
	var fl: Dictionary = WorldDamage.get_floor_counts()
	var dc: Dictionary = BloodFX.get_decal_counts() if BloodFX.has_method(&"get_decal_counts") else {}
	var floor_total := int(fl.get("cracks", 0)) + int(fl.get("craters", 0)) + int(fl.get("rubble", 0)) + int(fl.get("tiles", 0))
	var broken := 0
	for n in get_tree().get_nodes_in_group(&"breakables"):
		if not n.is_queued_for_deletion() and n.get(&"is_broken") == true:
			broken += 1
	var pieces := get_tree().get_nodes_in_group(&"falling_pieces").filter(func(n: Node) -> bool: return not n.is_queued_for_deletion()).size()
	print("    %s: world %s, floor %s, decals live %d, broken breakables %d, fallen pieces %d" % [when, wc, fl,
		int(dc.get("live", 0)), broken, pieces])
	_check(int(wc.get("furniture_broken", 0)) == 0 and int(wc.get("wall_holes", 0)) == 0 and int(wc.get("collapses", 0)) == 0
		and int(wc.get("props_broken", 0)) == 0 and int(wc.get("debris", 0)) == 0,
		"%s: no broken furniture, holes, collapses, thrown props or debris left" % when)
	_check(floor_total == 0 and WorldDamage.get_collapse_count() == 0, "%s: floor and collapse counts reset" % when)
	_check(int(dc.get("live", 0)) == 0 and broken == 0 and pieces == 0, "%s: no decals, broken breakables or fallen pieces" % when)
