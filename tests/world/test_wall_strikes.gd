extends Node3D
## Wall strikes (round 3): receive_strike with B's real power numbers
## (jab 15, kick 60, level-3 kick 180) against the Tuning feel targets:
## - hits to open each surface (drywall, roll door, brick), and a level-3 kick
##   opening a body-sized drywall hole;
## - every hit shows progress (cell damage grows, chips pop, cracks spread);
## - the pillar chips every hit and its core holds; the outer concrete holds;
## - props break in a sensible number of hits;
## - a weakened wall breaks under a lower-energy body impact;
## - 50 rapid strikes on one panel stay cheap and inside the debris caps;
## - hole-making strikes emit GameEvents.wall_broken once (chip / crack none),
##   with strike_holes and last_break_by_strike set; props once too;
## - end to end: the real player's kick opens a hole in drywall.

const JAB := 15.0
const KICK := 60.0
const KICK3 := 180.0
var _ok := true
var _struck: Array = []
var _rows: Array[String] = []

func _ready() -> void:
	GameEvents.wall_struck.connect(func(a: Node3D, w: Node3D, pos: Vector3, nrm: Vector3, pw: float, res: StringName, srf: StringName) -> void:
		_struck.append([a, w, pos, nrm, pw, res, srf]))
	var yard := YardBuilder.new()
	add_child(yard)
	yard.build()
	await get_tree().physics_frame
	await get_tree().physics_frame

	# 1. Hits to open each surface (the same contact point every hit).
	await _hits_to_open("drywall, jabs", &"drywall", JAB, 2, 2)
	await _hits_to_open("drywall, kicks", &"drywall", KICK, 1, 1)
	await _hits_to_open("roll door, kicks", &"wood", KICK, 3, 4, &"rolldoor")
	await _hits_to_open("brick, kicks", &"brick", KICK, 7, 9)
	await _hits_to_open("brick, level-3 kicks", &"brick", KICK3, 2, 3)
	# A level-3 kick on drywall opens a body-sized hole.
	var d := _panel(&"drywall", Vector3(0, 0, 40))
	await get_tree().physics_frame
	var c := d.global_transform * Vector3(0, -0.3, 0.125)
	var r := d.receive_strike(null, c, Vector3(-1, 0, 0), KICK3)
	var body := true
	for off: Vector2 in [Vector2(0, 0), Vector2(0.3, 0), Vector2(-0.3, 0), Vector2(0, 0.55), Vector2(0, -0.55)]:
		if not d.is_point_open(d.global_transform * Vector3(off.x, -0.3 + off.y, 0)):
			body = false
	var b_ok := r in [&"hole", &"break"] and body and d.last_removed.size() >= 4
	_line("drywall level-3 kick: %s, %d cells out, body-sized (open 0.3 m to the sides and 0.55 m up/down)=%s" % [
		r, d.last_removed.size(), body], b_ok)

	# 2. Progress on every hit (brick kicks before it opens).
	var p := _panel(&"brick", Vector3(0, 0, 50))
	await get_tree().physics_frame
	var pc := p.global_transform * Vector3(0.2, 0.0, 0.125)
	var progress := true
	var last_dmg := 0.0
	var last_cracks := 0
	var notes: Array[String] = []
	for k in 6:
		var chips0 := DebrisManager.count_small()
		var res := p.receive_strike(null, pc, Vector3(-1, 0, 0), KICK)
		var dmg := p.get_cell_damage_at(pc)
		var cracks := p.get_crack_edge_count()
		var chips := DebrisManager.count_small() - chips0
		notes.append("%s dmg=%.0f cracks=%d chips=%d" % [res, dmg, cracks, chips])
		if dmg <= last_dmg or chips < 1 or cracks < last_cracks:
			progress = false
		last_dmg = dmg
		last_cracks = cracks
	_line("brick progress per kick: %s" % ", ".join(notes), progress and last_cracks > 0)

	# 3. Pillar: chips every hit, a face slab comes off, the core holds.
	var pillar: Pillar = null
	for n in get_tree().get_nodes_in_group(&"pillars"):
		if (n as Node3D).global_position.distance_to(Vector3(6, 0, 6)) < 0.1:
			pillar = n
	var pr: Array[StringName] = []
	var face := Vector3(5.5, 1.2, 6.0)
	for k in 40:
		pr.append(pillar.receive_strike(null, face, Vector3(1, 0, 0), KICK))
	var first_hole := pr.find(&"hole") + 1
	var all_hit := not pr.has(&"hold")
	var core := not get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
		Vector3(4.0, 1.2, 6.0), Vector3(6.0, 1.2, 6.0), Layers.WORLD)).is_empty()
	_line("pillar, 40 kicks: every hit chips=%s, face slab off at kick %d, core holds=%s" % [all_hit, first_hole, core],
		all_hit and first_hole >= 10 and first_hole <= 20 and core)

	# 4. Outer concrete: cracks, chips and dust only.
	var structure := yard.get_node("Structure") as ConcreteWall
	var wall_pt := Vector3(0.0, 1.5, 11.0)   # long south wall, inner face
	var holds := true
	for k in 20:
		if structure.receive_strike(null, wall_pt, Vector3(0, 0, 1), KICK3 * 1.5) != &"hold":
			holds = false
	var solid := not get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
		Vector3(0, 1.5, 10.0), Vector3(0, 1.5, 14.0), Layers.WORLD)).is_empty()
	var decals := get_tree().current_scene.find_children("*", "Decal", true, false).size()
	_line("outer wall, 20 dash level-3 kicks: always hold=%s, still solid=%s, crack decals=%d" % [holds, solid, decals],
		holds and solid and decals >= 1)

	# 5. Props.
	_prop_hits("crate", yard, &"crate", 2, 2)
	_prop_hits("desk", yard, &"desk", 3, 3)
	_prop_hits("lamp post", yard, &"lamp", 5, 7)
	_loose_hits("chair", 8.0, 1, 1)
	_loose_hits("drum", 30.0, 3, 3)
	_loose_hits("filing cabinet", 55.0, 4, 4)

	# 6. Weakened walls: the same body impact cracks fresh brick but breaks
	#    brick that took 6 kicks.
	var fresh := _panel(&"brick", Vector3(0, 0, 60))
	var weak := _panel(&"brick", Vector3(0, 0, 70))
	await get_tree().physics_frame
	for k in 6:
		weak.receive_strike(null, weak.global_transform * Vector3(0, -0.2, 0.125), Vector3(-1, 0, 0), KICK)
	var fp := Rect2(-0.45, -1.2, 0.9, 1.8)
	var e := 4500.0
	var r_fresh := fresh.receive_impact(e, fresh.global_transform * Vector3(0, -0.2, 0.125), Vector3(-11, 0, 0), fp)
	var r_weak := weak.receive_impact(e, weak.global_transform * Vector3(0, -0.2, 0.125), Vector3(-11, 0, 0), fp)
	_line("4,500 J body into brick: fresh -> %s (needs %.0f J), after 6 kicks -> %s (needs %.0f J, weakness %.2f)" % [
		r_fresh, fresh.last_impact_break_energy, r_weak, weak.last_impact_break_energy, weak.weakness(fp)],
		r_fresh == &"crack" and r_weak == &"break" and weak.last_impact_break_energy < 4500.0)

	# 7. Budget: 50 rapid strikes on one panel.
	DebrisManager.reset()
	await get_tree().physics_frame
	var q := _panel(&"brick", Vector3(0, 0, 80))
	await get_tree().physics_frame
	var powers := [JAB, KICK, KICK3, 25.0, 45.0]
	var t_total := 0
	var t_max := 0
	var peak_small := 0
	var peak_large := 0
	for k in 50:
		var at := q.global_transform * Vector3(-1.2 + float(k % 7) * 0.4, -1.0 + float(k % 5) * 0.5, 0.125)
		var t0 := Time.get_ticks_usec()
		q.receive_strike(null, at, Vector3(-1, 0, 0), powers[k % powers.size()])
		var dt := Time.get_ticks_usec() - t0
		t_total += dt
		t_max = maxi(t_max, dt)
		await get_tree().physics_frame
		peak_small = maxi(peak_small, DebrisManager.count_small())
		peak_large = maxi(peak_large, DebrisManager.count_large())
	var avg := float(t_total) / 50.0
	_line("50 rapid strikes on one brick panel: %.0f us avg, %d us max, peak timed debris %d (cap %d), peak persistent %d (cap %d), cells left %d/%d" % [
		avg, t_max, peak_small, Tuning.DEBRIS_MAX, peak_large, DebrisManager.LARGE_MAX, q.get_alive_count(), q.get_cell_count()],
		avg < 2000.0 and peak_small <= Tuning.DEBRIS_MAX and peak_large <= DebrisManager.LARGE_MAX)

	# 8. Strike holes reach everyone: a hole-making strike emits wall_broken
	#    exactly once (wall == panel), chip and crack strikes emit none, and
	#    strike_holes / last_break_by_strike say it was a strike; an impact
	#    break clears last_break_by_strike; a prop broken by strikes emits once.
	var broken_events: Array = []
	var cb := func(w: Node3D, _p: Vector3, _e: float, v: Vector3) -> void: broken_events.append([w, v])
	GameEvents.wall_broken.connect(cb)
	var sp := _panel(&"brick", Vector3(0, 0, 90))
	await get_tree().physics_frame
	var spt := sp.global_transform * Vector3(0.1, -0.3, 0.125)
	var quiet := true
	var res_list: Array[StringName] = []
	var res2 := &"hold"
	while not (res2 in [&"hole", &"break"]) and res_list.size() < 12:
		broken_events.clear()
		res2 = sp.receive_strike(null, spt, Vector3(-1, 0, 0), KICK)
		res_list.append(res2)
		if res2 in [&"chip", &"crack"] and not broken_events.is_empty():
			quiet = false
	var hole_events := broken_events.filter(func(x: Array) -> bool: return x[0] == sp)
	var once := hole_events.size() == 1 and broken_events.size() == 1 \
		and (hole_events[0][1] as Vector3).dot(Vector3(-1, 0, 0)) > 0.9
	var fields := sp.strike_holes == 1 and sp.last_break_by_strike
	broken_events.clear()
	sp.receive_impact(9000.0, sp.global_transform * Vector3(-0.9, 0.3, 0.125), Vector3(-16, 0, 0), Rect2(-1.3, -0.4, 0.8, 1.6))
	var impact_clears := not sp.last_break_by_strike and sp.strike_holes == 1 and broken_events.size() == 1
	_line("strike hole emits wall_broken: chip/crack silent=%s (%s), hole emits once to the panel along the strike=%s, strike_holes=%d by_strike=%s, impact break clears it=%s" % [
		quiet, ",".join(res_list), once, sp.strike_holes, fields, impact_clears], quiet and once and fields and impact_clears)
	var crate := Destructible.new()
	crate.kind = &"crate"
	crate.surface = &"wood"
	crate.size = Vector3.ONE
	crate.break_energy_override = 600.0
	crate.position = Vector3(40, 0.5, 120)
	add_child(crate)
	await get_tree().physics_frame
	broken_events.clear()
	var cr := &"hold"
	var crate_hits := 0
	while cr != &"break" and crate_hits < 10:
		cr = crate.receive_strike(null, crate.global_position + Vector3(0.5, 0, 0), Vector3(-1, 0, 0), KICK)
		crate_hits += 1
	var crate_events := broken_events.filter(func(x: Array) -> bool: return x[0] == crate)
	_line("prop broken by strikes: wall_broken x%d (once), strike_holes=%d, by_strike=%s" % [crate_events.size(),
		crate.strike_holes, crate.last_break_by_strike],
		crate_events.size() == 1 and broken_events.size() == 1 and crate.strike_holes == 1 and crate.last_break_by_strike)
	GameEvents.wall_broken.disconnect(cb)

	# 9. End to end: the real player's kick opens drywall.
	await _end_to_end()

	print("")
	for row in _rows:
		print("[strike] ", row)
	print("[strike] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _line(text: String, ok: bool) -> void:
	_rows.append("%s -> %s" % [text, "PASS" if ok else "FAIL"])
	print("[strike] ", _rows[_rows.size() - 1])
	_ok = _ok and ok

var _lane := 0.0

func _panel(surface: StringName, at: Vector3, style: StringName = &"") -> Destructible:
	var d := Destructible.new()
	d.surface = surface
	d.style = style
	if style == &"rolldoor":
		d.size = Vector3(3, 3, 0.12)
	d.transform = Transform3D(Basis.looking_at(Vector3(-1, 0, 0), Vector3.UP), Vector3(30.0, 1.5, 0) + at)
	add_child(d)
	return d

func _hits_to_open(label: String, surface: StringName, power: float, lo: int, hi: int, style: StringName = &"") -> void:
	_lane += 10.0
	var d := _panel(surface, Vector3(0, 0, _lane), style)
	await get_tree().physics_frame
	var at := d.global_transform * Vector3(0.1, -0.3, d.size.z * 0.5)
	var hits := 0
	var res := &"hold"
	while hits < 30 and not (res in [&"hole", &"break"]):
		res = d.receive_strike(null, at, Vector3(-1, 0, 0), power)
		hits += 1
	_line("%-22s power %3.0f: opens after %d hits (target %d-%d), %d cells out" % [label, power, hits, lo, hi,
		d.last_removed.size()], hits >= lo and hits <= hi)

func _prop_hits(label: String, yard: YardBuilder, kind: StringName, lo: int, hi: int) -> void:
	var prop: Destructible = null
	for d in yard.get_destructibles():
		if d.kind == kind and not d.is_broken:
			prop = d
			break
	var at := prop.global_position + Vector3(0.0, -prop.size.y * 0.5 + minf(prop.size.y, 1.2) * 0.6, 0.0)
	var hits := 0
	while hits < 20 and not prop.is_broken:
		prop.receive_strike(null, at, Vector3(1, 0, 0), KICK)
		hits += 1
	_line("%-22s kicks to break: %d (target %d-%d)" % [label, hits, lo, hi], hits >= lo and hits <= hi)

func _loose_hits(label: String, mass: float, lo: int, hi: int) -> void:
	var target: LooseProp = null
	for n in get_tree().get_nodes_in_group(&"props"):
		var lp := n as LooseProp
		if lp and not lp.is_queued_for_deletion() and is_equal_approx(lp.mass, mass):
			target = lp
			break
	var hits := 0
	var res := &"hold"
	while hits < 20 and res != &"break":
		res = target.receive_strike(null, target.global_position + Vector3(0, 0.5, 0), Vector3(1, 0, 0), KICK)
		hits += 1
	_line("%-22s kicks to break: %d (target %d-%d)" % [label, hits, lo, hi], hits >= lo and hits <= hi)

func _end_to_end() -> void:
	if not await WorldTestUtil.real_ragdoll_available(self):
		_line("end to end: real fighters unavailable", false)
		return
	var d := _panel(&"drywall", Vector3(0, 0, 100))
	await get_tree().physics_frame
	var face_x := d.global_position.x + 0.125
	var p := FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis.looking_at(Vector3(-1, 0, 0), Vector3.UP),
		Vector3(face_x + 0.75, 0.05, d.global_position.z)), Fighter.TEAM_PLAYER)
	for i in 15:
		await get_tree().physics_frame
	_struck.clear()
	p.combat.press(CombatController.Action.KICK)
	var t0 := TimeDirector.now()
	while TimeDirector.now() - t0 < 1.5 and _struck.filter(func(x: Array) -> bool: return x[1] == d).is_empty():
		await get_tree().physics_frame
	var mine := _struck.filter(func(x: Array) -> bool: return x[1] == d)
	var res: StringName = mine[0][5] if mine.size() > 0 else &"none"
	_line("end to end: the player's sparta kick on drywall -> %s, power %.0f, %d cells out" % [
		res, mine[0][4] if mine.size() > 0 else 0.0, d.last_removed.size()], res in [&"hole", &"break"])
