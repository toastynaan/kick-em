extends Node3D
## Real Fighters launched across the real Yard:
## 1. 13 m/s west from the courtyard: breaks the office facade, crosses the
##    room, breaks the inner wall and ends in the back room ("a body bounced
##    through two rooms takes several hits").
## 2. 16 m/s north into a garage brick panel: breaks; 8 m/s into another: bounces.
## 3. 18 m/s south into the long concrete wall: bounces, impact damage, decal.
## 4. 10 m/s into a pillar: one concrete impact.
## Also checks that nothing errors and debris stays within budget.

var _use_fake := false
var _ok := true
var _decisions: Array = []
var _impacts: Array = []
var yard: YardBuilder
var _chains: Array = []

func _ready() -> void:
	ImpactResolver.wall_decided.connect(func(f: Node3D, w: Node3D, outcome: StringName, e: float, _p: Vector3) -> void:
		_decisions.append({"fighter": f, "wall": w, "outcome": outcome, "energy": e}))
	ImpactResolver.impact_dealt.connect(func(f: Node3D, e: float, dmg: float, surface: StringName, pos: Vector3) -> void:
		_impacts.append({"fighter": f, "energy": e, "damage": dmg, "surface": surface, "pos": pos}))
	GameEvents.wall_chain.connect(func(f: Node3D, count: int) -> void: _chains.append([f, count]))
	yard = YardBuilder.new()
	add_child(yard)
	yard.build()
	await get_tree().physics_frame
	_use_fake = not await WorldTestUtil.real_ragdoll_available(self)
	print("[flight] ragdoll: ", "TEST STAND-IN" if _use_fake else "real RagdollController")

	# 1. Two rooms west.
	var r := await _fly(Vector3(-8.9, 0, 0), Vector3(-13, 2.4, 0), 2.0)
	var breaks: Array = r["dec"].filter(func(d: Dictionary) -> bool: return d["outcome"] == &"break")
	var names: Array = breaks.map(func(d: Dictionary) -> String: return "%s(%.0f J)" % [(d["wall"] as Node).name, d["energy"]])
	var hits: Array = r["imp"].map(func(d: Dictionary) -> String: return "%s:%.0f" % [d["surface"], d["damage"]])
	var two_ok: bool = breaks.size() >= 2 and r["end"].x < -14.5 and r["chain"].has(2)
	print("[flight] west 13 m/s: breaks=%s end x=%.2f hits=%s hp lost=%.0f wall_chain=%s -> %s" % [
		names, r["end"].x, hits, r["hp_lost"], r["chain"], "PASS" if two_ok else "FAIL"])
	_ok = _ok and two_ok
	# Chunks must clear the hole (none left hanging in the panel's plane).
	var hanging := 0
	var total := 0
	for d: Dictionary in breaks:
		var w := d["wall"] as Destructible
		for c in w.last_chunks:
			if not is_instance_valid(c):
				continue
			total += 1
			var local := w.global_transform.affine_inverse() * c.global_position
			if absf(local.z) < 0.15 and c.global_position.y > 0.3:
				hanging += 1
	var clear_ok := total > 0 and hanging == 0
	print("[flight] chunks left hanging in the broken panels: %d of %d -> %s" % [hanging, total, "PASS" if clear_ok else "FAIL"])
	_ok = _ok and clear_ok

	# 2. Garage brick north: 16 m/s breaks (x = 3 panel), 8 m/s bounces (x = -3 panel).
	r = await _fly(Vector3(3, 0, -8.9), Vector3(0, 2.0, -16), 1.5)
	var gb: Array = r["dec"].filter(func(d: Dictionary) -> bool: return (d["wall"] as Destructible).surface == &"brick")
	var g_ok: bool = gb.size() >= 1 and gb[0]["outcome"] == &"break" and r["end"].z < -11.5
	print("[flight] garage brick 16 m/s: %s E=%.0f end z=%.2f -> %s" % [
		gb[0]["outcome"] if gb.size() > 0 else "none", gb[0]["energy"] if gb.size() > 0 else -1.0,
		r["end"].z, "PASS" if g_ok else "FAIL"])
	_ok = _ok and g_ok
	r = await _fly(Vector3(-3, 0, -8.9), Vector3(0, 1.8, -8), 1.5)
	gb = r["dec"].filter(func(d: Dictionary) -> bool: return (d["wall"] as Destructible).surface == &"brick")
	var gb_ok: bool = gb.size() >= 1 and gb[0]["outcome"] == &"bounce" and r["end"].z > -11.0
	print("[flight] garage brick 8 m/s: %s E=%.0f end z=%.2f -> %s" % [
		gb[0]["outcome"] if gb.size() > 0 else "none", gb[0]["energy"] if gb.size() > 0 else -1.0,
		r["end"].z, "PASS" if gb_ok else "FAIL"])
	_ok = _ok and gb_ok

	# 3. South concrete wall at 18 m/s.
	r = await _fly(Vector3(2, 0, 8.9), Vector3(0, 1.8, 18), 1.5)
	var sc: Array = r["imp"].filter(func(d: Dictionary) -> bool: return d["surface"] == &"concrete" and d["pos"].z > 10.5)
	var s_ok: bool = sc.size() == 1 and sc[0]["energy"] > 5000.0 and r["end"].z < 11.0
	print("[flight] south concrete 18 m/s: impacts=%s end z=%.2f -> %s" % [
		sc.map(func(d: Dictionary) -> String: return "E=%.0f dmg=%.0f" % [d["energy"], d["damage"]]),
		r["end"].z, "PASS" if s_ok else "FAIL"])
	_ok = _ok and s_ok

	# 4b. Pillar chipping: 14 m/s (6,860 J) into the pillar at (-6, 6) knocks a
	#     face slab off; the body still bounces.
	var pil: Pillar = null
	for n in get_tree().get_nodes_in_group(&"pillars"):
		if (n as Node3D).global_position.distance_to(Vector3(-6, 0, 6)) < 0.1:
			pil = n
	r = await _fly(Vector3(-8.9, 0, 6), Vector3(14, 1.6, 0), 1.0)
	var chip_ok: bool = pil != null and pil.chips >= 1 and r["end"].x < -6.5
	print("[flight] pillar 14 m/s: chips=%d end x=%.2f (bounced) -> %s" % [pil.chips if pil else -1, r["end"].x, "PASS" if chip_ok else "FAIL"])
	_ok = _ok and chip_ok

	# 4. Pillar at (6, 6): from the west at 10 m/s.
	r = await _fly(Vector3(3.3, 0, 6), Vector3(10, 1.5, 0), 1.0)
	var pc: Array = r["imp"].filter(func(d: Dictionary) -> bool: return d["surface"] == &"concrete" and absf(d["pos"].x - 5.5) < 0.4)
	var p_ok: bool = pc.size() == 1
	print("[flight] pillar 10 m/s: impacts=%s end x=%.2f -> %s" % [
		pc.map(func(d: Dictionary) -> String: return "E=%.0f dmg=%.0f" % [d["energy"], d["damage"]]),
		r["end"].x, "PASS" if p_ok else "FAIL"])
	_ok = _ok and p_ok

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
	var f := WorldTestUtil.spawn_body(self, Transform3D(Basis.looking_at(d, Vector3.UP), com_xz + Vector3(0, 0.05, 0)), _use_fake)
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
