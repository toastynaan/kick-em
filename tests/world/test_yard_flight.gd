extends Node3D
## Real 70 kg Fighters launched across the real Yard (Round 5 wall rules):
## 1. 13 m/s west from the courtyard (5,915 J): breaks the office facade, crosses
##    the room, breaks the inner wall (4,140 J after absorption) and ends in the
##    back room; wall damage 10 + 10, wall_chain 2.
## 2. 16 m/s north into a garage brick panel (8,960 J): breaks; 8 m/s into
##    another (2,240 J, under the 2,400 J crack energy): bounces.
## 3. 18 m/s south into the long concrete boundary wall (11,340 J): it never
##    breaks; a crack (+5 damage, decal), the body bounces.
## 4. Pillars: 14 m/s (6,860 J) cracks one (a slab comes off, +5) and bounces;
##    10 m/s (3,500 J) bounces with no damage; 18 m/s bodies crack then break
##    one (each checked against the rule at its arrival energy).
## Also checks that nothing errors and debris stays within budget. Round 6:
## agent K's clutter near the pillars is cleared first (this tests D's pillar
## rules; the west flight keeps whatever clutter K put in the offices).

var _use_fake := false
var _ok := true
var _decisions: Array = []
var _impacts: Array = []
var yard: YardBuilder
var _chains: Array = []
var _spawned_at := {}   ## debris instance id -> position when DebrisManager took it

func _ready() -> void:
	ImpactResolver.wall_decided.connect(func(f: Node3D, w: Node3D, outcome: StringName, e: float, _p: Vector3) -> void:
		_decisions.append({"fighter": f, "wall": w, "outcome": outcome, "energy": e}))
	ImpactResolver.impact_dealt.connect(func(f: Node3D, e: float, dmg: float, surface: StringName, pos: Vector3) -> void:
		_impacts.append({"fighter": f, "energy": e, "damage": dmg, "surface": surface, "pos": pos}))
	GameEvents.wall_chain.connect(func(f: Node3D, count: int) -> void: _chains.append([f, count]))
	DebrisManager.body_registered.connect(func(b: RigidBody3D) -> void:
		_spawned_at[b.get_instance_id()] = b.global_position)
	yard = YardBuilder.new()
	add_child(yard)
	yard.build()
	for pl: Vector2 in YardBuilder.PILLARS:
		WorldTestUtil.clear_clutter_near(get_tree(), Vector3(pl.x, 0, pl.y), 4.0)
	await get_tree().physics_frame
	_use_fake = not await WorldTestUtil.real_ragdoll_available(self)
	print("[flight] ragdoll: ", "TEST STAND-IN" if _use_fake else "real RagdollController")

	# 1. Two rooms west.
	var r := await _fly(Vector3(-8.9, 0, 0), Vector3(-13, 2.4, 0), 2.0)
	var breaks: Array = r["dec"].filter(func(d: Dictionary) -> bool: return d["outcome"] == &"break")
	var names: Array = breaks.map(func(d: Dictionary) -> String: return "%s(%.0f J)" % [(d["wall"] as Node).name, d["energy"]])
	var hits: Array = r["imp"].map(func(d: Dictionary) -> String: return "%s:%.0f" % [d["surface"], d["damage"]])
	# Two drywall walls broken; the damage is what it broke (walls by the wall
	# table, any clutter in the rooms by FURNITURE_BODY_DAMAGE).
	var walls_broken := breaks.filter(func(d: Dictionary) -> bool: return d["wall"] is Destructible \
		and (d["wall"] as Destructible).kind == &"panel" and (d["wall"] as Destructible).surface == &"drywall")
	var owed := 0.0
	for d: Dictionary in breaks:
		owed += ImpactResolver.break_damage(d["wall"])
	var two_ok: bool = walls_broken.size() >= 2 and r["end"].x < -14.5 and r["chain"].has(2) \
		and absf(r["hp_lost"] - owed) < 0.01 and owed >= 2.0 * Tuning.WALL_DAMAGE[&"drywall"]
	print("[flight] west 13 m/s: breaks=%s end x=%.2f hits=%s hp lost=%.0f wall_chain=%s -> %s" % [
		names, r["end"].x, hits, r["hp_lost"], r["chain"], "PASS" if two_ok else "FAIL"])
	_ok = _ok and two_ok
	# Chunks must clear the hole: none left hanging where it spawned in the
	# panel's plane (a chunk that fell and came to rest on the rim below the hole
	# is rubble, not hanging).
	var hanging := 0
	var total := 0
	for d: Dictionary in walls_broken:
		var w := d["wall"] as Destructible
		for c in w.last_chunks:
			if not is_instance_valid(c):
				continue
			total += 1
			var local := w.global_transform.affine_inverse() * c.global_position
			var from: Vector3 = _spawned_at.get(c.get_instance_id(), Vector3(INF, INF, INF))
			if absf(local.z) < 0.15 and c.global_position.y > 0.3 and c.global_position.distance_to(from) < 0.15:
				hanging += 1
	var clear_ok := total > 0 and hanging == 0
	print("[flight] chunks left hanging in the broken panels: %d of %d -> %s" % [hanging, total, "PASS" if clear_ok else "FAIL"])
	_ok = _ok and clear_ok

	# 2. Garage brick north: 16 m/s breaks (x = 3 panel), 8 m/s bounces (x = -3 panel).
	r = await _fly(Vector3(3, 0, -8.9), Vector3(0, 2.0, -16), 1.5)
	var gb: Array = r["dec"].filter(func(d: Dictionary) -> bool: return d["wall"] is Destructible and (d["wall"] as Destructible).surface == &"brick" \
		and (d["wall"] as Destructible).kind == &"panel")
	var g_ok: bool = gb.size() >= 1 and gb[0]["outcome"] == &"break" and r["end"].z < -11.5
	print("[flight] garage brick 16 m/s: %s E=%.0f end z=%.2f -> %s" % [
		gb[0]["outcome"] if gb.size() > 0 else "none", gb[0]["energy"] if gb.size() > 0 else -1.0,
		r["end"].z, "PASS" if g_ok else "FAIL"])
	_ok = _ok and g_ok
	r = await _fly(Vector3(-3, 0, -8.9), Vector3(0, 1.8, -8), 1.5)
	gb = r["dec"].filter(func(d: Dictionary) -> bool: return d["wall"] is Destructible and (d["wall"] as Destructible).surface == &"brick" \
		and (d["wall"] as Destructible).kind == &"panel")
	var gb_ok: bool = gb.size() >= 1 and gb[0]["outcome"] == &"bounce" and r["end"].z > -11.0
	print("[flight] garage brick 8 m/s: %s E=%.0f end z=%.2f -> %s" % [
		gb[0]["outcome"] if gb.size() > 0 else "none", gb[0]["energy"] if gb.size() > 0 else -1.0,
		r["end"].z, "PASS" if gb_ok else "FAIL"])
	_ok = _ok and gb_ok

	# 3. South concrete wall at 18 m/s.
	r = await _fly(Vector3(2, 0, 8.9), Vector3(0, 1.8, 18), 1.5)
	var sc: Array = r["imp"].filter(func(d: Dictionary) -> bool: return d["surface"] == &"concrete" and d["pos"].z > 10.5)
	var s_ok: bool = sc.size() == 1 and sc[0]["energy"] > 6000.0 and r["end"].z < 11.0 \
		and absf(sc[0]["damage"] - Tuning.WALL_DAMAGE[&"crack"]) < 0.01
	print("[flight] south concrete 18 m/s: impacts=%s end z=%.2f -> %s" % [
		sc.map(func(d: Dictionary) -> String: return "E=%.0f dmg=%.0f" % [d["energy"], d["damage"]]),
		r["end"].z, "PASS" if s_ok else "FAIL"])
	_ok = _ok and s_ok

	# 4b. Pillar chipping: 14 m/s (6,860 J) into the pillar at (-6, 6) knocks a
	#     face slab off; the body still bounces. From the north (Round 6: a
	#     partition stands on its west side).
	var pil: Pillar = null
	for n in get_tree().get_nodes_in_group(&"pillars"):
		if (n as Node3D).global_position.distance_to(Vector3(-6, 0, 6)) < 0.1:
			pil = n
	r = await _fly(Vector3(-6, 0, 3.1), Vector3(0, 1.6, 14), 1.0)
	var pd: Array = r["dec"].filter(func(d: Dictionary) -> bool: return d["wall"] == pil)
	var chip_ok: bool = pil != null and pil.chips >= 1 and r["end"].z < 5.5 and pd.size() == 1 \
		and pd[0]["outcome"] == &"crack" and absf(r["hp_lost"] - Tuning.WALL_DAMAGE[&"crack"]) < 0.01
	print("[flight] pillar 14 m/s: %s E=%.0f chips=%d end z=%.2f (bounced) hp lost=%.0f -> %s" % [
		pd[0]["outcome"] if pd.size() > 0 else "none", pd[0]["energy"] if pd.size() > 0 else -1.0,
		pil.chips if pil else -1, r["end"].z, r["hp_lost"], "PASS" if chip_ok else "FAIL"])
	_ok = _ok and chip_ok

	# 4. Pillar at (6, 6): from the west at 10 m/s.
	var pil2: Pillar = null
	for n in get_tree().get_nodes_in_group(&"pillars"):
		if (n as Node3D).global_position.distance_to(Vector3(6, 0, 6)) < 0.1:
			pil2 = n
	r = await _fly(Vector3(3.3, 0, 5.8), Vector3(10, 1.5, 0), 1.0)
	var pc: Array = r["dec"].filter(func(d: Dictionary) -> bool: return d["wall"] == pil2)
	var p_ok: bool = pc.size() == 1 and pc[0]["outcome"] == &"bounce" and r["hp_lost"] < 0.01 and not pil2.is_broken
	print("[flight] pillar 10 m/s: %s E=%s hp lost=%.0f end x=%.2f -> %s" % [
		pc.map(func(d: Dictionary) -> String: return String(d["outcome"])), pc.map(func(d: Dictionary) -> int: return int(d["energy"])),
		r["hp_lost"], r["end"].x, "PASS" if p_ok else "FAIL"])
	_ok = _ok and p_ok
	# 18 m/s bodies into the pillar at (6, -6) from the south (Round 6: the
	# crates stand west of it), 1 m off its face: crack, then break. Each
	# decision is checked against the rule at the energy it arrived with (a
	# body that lost a few % on the way correctly only cracks it), and a slow
	# one is followed by another (at most 4).
	var pil3: Pillar = null
	for n in get_tree().get_nodes_in_group(&"pillars"):
		if (n as Node3D).global_position.distance_to(Vector3(6, 0, -6)) < 0.1:
			pil3 = n
	var outs: Array = []
	var rule_ok := pil3 != null
	var k := 0
	while pil3 != null and k < 4 and not pil3.is_broken:
		var be := pil3.break_energy
		var ct := ImpactResolver.crack_threshold_of(pil3)
		r = await _fly(Vector3(6, 0, -4.5), Power.launch_velocity(11.0, Vector3.FORWARD, 70.0), 1.0)
		var mine: Array = r["dec"].filter(func(d: Dictionary) -> bool: return d["wall"] == pil3)
		if mine.is_empty():
			rule_ok = false
			outs.append("none")
		else:
			var e := float(mine[0]["energy"])
			var want := &"break" if e >= be else (&"crack" if e >= ct else &"bounce")
			rule_ok = rule_ok and mine[0]["outcome"] == want
			outs.append("%s(%.0f J; break %.0f, crack %.0f)" % [mine[0]["outcome"], e, be, ct])
		k += 1
	var pb_ok: bool = pil3 != null and pil3.is_broken and rule_ok and k >= 2 and String(outs[0]).begins_with("crack")
	print("[flight] pillar 18 m/s hits: %s broken=%s -> %s" % [outs, pil3.is_broken if pil3 else false,
		"PASS" if pb_ok else "FAIL"])
	_ok = _ok and pb_ok

	var deb_ok := DebrisManager.count() <= Tuning.DEBRIS_MAX
	print("[flight] debris alive %d -> %s" % [DebrisManager.count(), "PASS" if deb_ok else "FAIL"])
	_ok = _ok and deb_ok
	print("[flight] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

## Launch a fresh 70 kg dummy whose COM starts at com_xz and report what it hit.
func _fly(com_xz: Vector3, vel: Vector3, seconds: float) -> Dictionary:
	_decisions.clear()
	_impacts.clear()
	_chains.clear()
	var d := Vector3(-vel.x, 0, -vel.z).normalized()   # face away from the flight (kicked backwards)
	var f := WorldTestUtil.spawn_body(self, Transform3D(Basis.looking_at(d, Vector3.UP), com_xz + Vector3(0, 0.05, 0)),
		_use_fake, &"player")
	f.max_hp = 2000.0
	f.hp = 2000.0
	await get_tree().physics_frame
	await get_tree().physics_frame
	var c := f.get_center_of_mass()
	f.global_position += Vector3(com_xz.x - c.x, 0, com_xz.z - c.z)
	f.reset_physics_interpolation()
	await get_tree().physics_frame
	f.launch(vel, f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, seconds)
	var res := {
		"dec": _decisions.filter(func(x: Dictionary) -> bool: return x["fighter"] == f),
		"imp": _impacts.filter(func(x: Dictionary) -> bool: return x["fighter"] == f),
		"end": f.get_center_of_mass(),
		"hp_lost": 2000.0 - f.hp,
		"chain": _chains.filter(func(entry: Array) -> bool: return entry[0] == f).map(func(entry: Array) -> int: return entry[1]),
	}
	f.queue_free()
	ImpactResolver.reset()
	TimeDirector.reset()
	await get_tree().physics_frame
	return res
