extends Node3D
## Round 6 breakable contract through the real resolver (D's task 1: flying
## bodies break any breakable, K's clutter included). Two stand-ins that
## implement only the duck-typed contract (tests/world/fake_furniture.gd: no
## size, no get_box_transform, no get_crack_threshold), set up as two tables
## (Tuning.FURNITURE: break 700 J, absorb 0.15) in a line 1.6 m apart:
## 1. One 8 m/s body breaks both in one flight; after each it keeps
##    sqrt(1 - absorb) of its speed and takes Tuning.FURNITURE_BODY_DAMAGE;
##    no wall freeze, no wall_broken_by (furniture is not a wall). During each
##    receive_impact the breakable's meta "impact_body" names that flying body.
## 2. A 3.5 m/s body (~430 J) only cracks one (crack at 40% of 700 = 280 J):
##    no damage, it holds.
## 3. A slam's blast reaches a stand-in 1.0 m away with the blast's power
##    attenuated linearly (power x (1 - d / radius)), once.

const FakeFurniture := preload("res://tests/world/fake_furniture.gd")

var _decisions: Array = []
var _broken_by: Array = []
var _ok := true

func _ready() -> void:
	ImpactResolver.wall_decided.connect(func(f: Node3D, w: Node3D, outcome: StringName, e: float, _p: Vector3) -> void:
		_decisions.append({"fighter": f, "wall": w, "outcome": outcome, "energy": e}))
	GameEvents.wall_broken_by.connect(func(flyer: Node3D, wall: Node3D, _e: float) -> void: _broken_by.append([flyer, wall]))
	WorldTestUtil.make_floor(self, 200.0)
	await get_tree().physics_frame
	if not await WorldTestUtil.real_ragdoll_available(self):
		print("[contract] FAIL: real ragdoll unavailable")
		get_tree().quit(1)
		return
	await _two_tables()
	await _crack_only()
	await _blast()
	print("[contract] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[contract] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _table(at: Vector3) -> Node:
	var t: Node = FakeFurniture.new()
	add_child(t)
	(t as Node3D).global_position = at
	t.call(&"setup", &"table", Vector3(0.35, 0.4, 0.6))
	return t

func _body(at: Vector3) -> Fighter:
	var f := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, -PI * 0.5), at + Vector3(0, 0.05, 0)), false, &"player")
	f.max_hp = 1000.0
	f.hp = 1000.0
	for i in 3:
		await get_tree().physics_frame
	var c := f.get_center_of_mass()
	f.global_position += Vector3(at.x - c.x, 0, at.z - c.z)
	f.reset_physics_interpolation()
	await get_tree().physics_frame
	return f

func _hv(f: Fighter) -> float:
	var v := f.get_com_velocity()
	return Vector2(v.x, v.z).length()

func _two_tables() -> void:
	var a := _table(Vector3(0, 0, 0))
	var b := _table(Vector3(-1.6, 0, 0))
	await get_tree().physics_frame
	var f := await _body(Vector3(1.5, 0, 0))
	_decisions.clear()
	_broken_by.clear()
	var hp0 := f.hp
	f.launch(Vector3(-8, 1.0, 0), f.get_center_of_mass())
	var speeds: Array = []   ## [before, after] per break
	var last := _hv(f)
	var seen := 0
	var froze := false
	var t := 0.0
	var pending := -1
	while t < 0.8:
		await get_tree().physics_frame
		t += 1.0 / 120.0
		froze = froze or f.is_frozen()
		var mine := _decisions.filter(func(d: Dictionary) -> bool: return d["fighter"] == f and d["outcome"] == &"break")
		if mine.size() > seen:
			seen = mine.size()
			speeds.append([last, 0.0])
			pending = 2
		elif pending > 0:
			pending -= 1
			if pending == 0:
				speeds[speeds.size() - 1][1] = _hv(f)
		last = _hv(f)
	var keep := sqrt(1.0 - float(Tuning.FURNITURE[&"table"]["absorb"]))
	var ratios: Array = speeds.map(func(s: Array) -> float: return float(s[1]) / maxf(float(s[0]), 0.01))
	var ratio_ok := ratios.size() == 2 and ratios.all(func(r: float) -> bool: return absf(r - keep) <= 0.05)
	var dmg := hp0 - f.hp
	var named := true
	for table: Node in [a, b]:
		for imp: Array in table.get(&"impacts"):
			named = named and imp[2] == f
	var ok: bool = a.get(&"is_broken") and b.get(&"is_broken") and ratio_ok \
		and absf(dmg - 2.0 * Tuning.FURNITURE_BODY_DAMAGE) < 0.01 and not froze and _broken_by.is_empty() and named
	_line("an 8 m/s body through two tables: broke %s; speed kept per break %s (want sqrt(1 - %.2f) = %.3f +- 0.05); damage %.0f (want %.0f); wall freeze=%s, wall_broken_by=%d; meta impact_body named the flyer=%s" % [
		[a.get(&"is_broken"), b.get(&"is_broken")], ratios.map(func(r: float) -> String: return "%.3f" % r),
		float(Tuning.FURNITURE[&"table"]["absorb"]), keep, dmg, 2.0 * Tuning.FURNITURE_BODY_DAMAGE, froze, _broken_by.size(),
		named], ok)
	f.queue_free()
	a.queue_free()
	b.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

func _crack_only() -> void:
	var a := _table(Vector3(0, 0, 20))
	await get_tree().physics_frame
	var f := await _body(Vector3(1.5, 0, 20))
	var hp0 := f.hp
	_decisions.clear()
	f.launch(Vector3(-3.5, 0.6, 0), f.get_center_of_mass())
	await WorldTestUtil.wait_game(self, 0.8)
	var d := _decisions.filter(func(x: Dictionary) -> bool: return x["wall"] == a)
	var ok: bool = d.size() >= 1 and d[0]["outcome"] == &"crack" and not a.get(&"is_broken") and is_equal_approx(f.hp, hp0)
	_line("a 3.5 m/s body: %s at %s J (crack from %.0f J), table holds=%s, damage %.0f" % [
		d.map(func(x: Dictionary) -> String: return String(x["outcome"])), d.map(func(x: Dictionary) -> int: return int(x["energy"])),
		Tuning.CRACK_FRACTION * float(Tuning.FURNITURE[&"table"]["break"]), not a.get(&"is_broken"), hp0 - f.hp], ok)
	f.queue_free()
	a.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame

func _blast() -> void:
	var a := _table(Vector3(0, 0, 40))
	await get_tree().physics_frame
	var center := Vector3(1.35, 0.1, 40)   # 1.0 m from the table's +X face (half 0.35)
	var radius := float(Tuning.BLAST[&"slam"])
	WorldDamage.blast(center, radius, 3000.0, &"slam")
	var got: Array = a.get(&"blasts")
	var want := 3000.0 * (1.0 - 1.0 / radius)
	var ok: bool = got.size() == 1 and absf(float(got[0][0]) - want) < 30.0 and got[0][1] == &"slam"
	_line("a 3,000 J slam blast 1.0 m away (radius %.1f m): received %s (want %.0f J, once)" % [radius,
		got.map(func(x: Array) -> String: return "%.0f J %s" % [x[0], x[1]]), want], ok)
	a.queue_free()
