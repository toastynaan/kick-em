extends Node3D
## Round 6 clutter kinds (agent K): for every kind in Tuning.FURNITURE, on the
## breakable contract directly (the real-resolver bodies are test_bodies_real):
## - a body below its crack energy bounces, below its break energy cracks it
##   (it holds; light kinds come loose instead), and the crack lowers its break
##   energy by half the hit's energy;
## - a body at its break energy breaks it: GameEvents.furniture_broken with that
##   energy, collision off at once (no longer blocks movement or the AI grid),
##   one debris body per kit piece (+ glass shards), pieces with a share of
##   the hit's velocity;
## - strikes: strike_hp - 1 holds, the next point breaks it (furniture_broken
##   energy >= break energy); kicks (60) to break printed;
## - the pieces of both breaks stay (none fades) and are all at rest and frozen
##   (Tuning.DEBRIS_FREEZE_AFTER after settling) within FREEZE_BOUND s;
## - a slam-sized blast (WorldDamage.blast) breaks glass and cardboard only:
##   every other kind cracks and holds (a chair hops loose).

const KICK := 60.0
## J of the slam-sized blast: at 1 m from the object, more than any break energy.
const BLAST_POWER := 6000.0
## s at most from the break until every lasting piece has come to rest and
## frozen (Tuning.DEBRIS_FREEZE_AFTER after it settles); the time taken is printed.
const FREEZE_BOUND := 12.0

var _ok := true
var _breaks: Array = []

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[kinds] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _ready() -> void:
	ClutterTestUtil.make_floor(self)
	ClutterTestUtil.record_breaks(_breaks)
	await ClutterTestUtil.frames(self, 2)
	var x := 0.0
	for kind: StringName in Tuning.FURNITURE:
		await _kind(kind, Vector3(x, 0, 0))
		x += 6.0
	print("[kinds] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _kind(kind: StringName, at: Vector3) -> void:
	var spec: Dictionary = Tuning.FURNITURE[kind]
	var b := float(spec["break"])
	var hp := float(spec["strike_hp"])
	var v := Vector3(6.0, 0, 0)
	# Bounce, then crack (holds), on one object.
	var a := ClutterTestUtil.make(self, kind, at)
	var c := ClutterTestUtil.make(self, kind, at + Vector3(0, 0, 4))
	var d := ClutterTestUtil.make(self, kind, at + Vector3(0, 0, 8))
	await ClutterTestUtil.frames(self, 2)
	var face := a.get_box_transform().origin - Vector3(a.size.x * 0.5, 0, 0)
	var r1 := a.receive_impact(0.3 * b, face, v)
	var r2 := a.receive_impact(0.9 * b, face, v)
	var light := kind in Furniture.LOOSE_KINDS
	var after := a.break_energy
	var hold_ok := r1 == &"bounce" and r2 == &"crack" and not a.is_broken \
		and is_equal_approx(after, b - 0.45 * b) and (a.is_loose == light)
	# Break at the break energy.
	_breaks.clear()
	DebrisManager.reset()
	await ClutterTestUtil.frames(self, 1)
	var face_c := c.get_box_transform().origin - Vector3(c.size.x * 0.5, 0, 0)
	var r3 := c.receive_impact(b, face_c, v)
	var want_pieces := c.get_spec().pieces.size() + (Furniture.SHARDS_LASTING + Furniture.SHARDS_FINE if kind == &"glass" else 0)
	var ev := _breaks.filter(func(e: Dictionary) -> bool: return e["node"] == c)
	var space := get_world_3d().direct_space_state
	await ClutterTestUtil.frames(self, 1)
	var blocking := _blocks(space, c)
	var fwd := 0.0
	for p in c.last_chunks:
		fwd += p.linear_velocity.x
	fwd /= maxf(c.last_chunks.size(), 1)
	var break_ok := r3 == &"break" and c.is_broken and c.last_chunks.size() == want_pieces and ev.size() == 1 \
		and is_equal_approx(float(ev[0]["energy"]), b) and not blocking and fwd > 1.0
	# Strikes: hp - 1 holds, the next point breaks.
	var hit := d.get_box_transform().origin - Vector3(d.size.x * 0.5, 0, 0)
	var s1 := d.receive_strike(null, hit, Vector3.RIGHT, hp - 1.0)
	var broke_early := d.is_broken
	var s2 := d.receive_strike(null, hit, Vector3.RIGHT, 1.0)
	var ev2 := _breaks.filter(func(e: Dictionary) -> bool: return e["node"] == d)
	var strike_ok := not broke_early and s1 in [&"chip", &"crack"] and s2 == &"break" and d.is_broken \
		and ev2.size() == 1 and float(ev2[0]["energy"]) >= b
	var kicks := int(ceil(hp / KICK))
	_line("%-12s break %5.0f J: 0.3x -> %s, 0.9x -> %s (holds, break energy now %.0f%s), 1.0x -> %s, %d pieces (want %d), event energy %.0f, still blocking=%s, pieces forward %.1f m/s" % [
		kind, b, r1, r2, after, ", came loose" if a.is_loose else "", r3, c.last_chunks.size(), want_pieces,
		float(ev[0]["energy"]) if ev.size() > 0 else -1.0, blocking, fwd], hold_ok and break_ok)
	_line("%-12s strike_hp %3.0f: %.0f power -> %s (holds), +1 -> %s (event energy %.0f); kicks to break %d" % [
		kind, hp, hp - 1.0, s1, s2, float(ev2[0]["energy"]) if ev2.size() > 0 else -1.0, kicks], strike_ok)
	# Pieces stay and freeze.
	var pieces: Array[RigidBody3D] = []
	pieces.append_array(c.last_chunks)
	pieces.append_array(d.last_chunks)
	var waited := 0.0
	var timed := Furniture.SHARDS_FINE * 2 if kind == &"glass" else 0  # fine shards fade on their timer (effects)
	while waited < FREEZE_BOUND:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		if waited < Tuning.DEBRIS_FREEZE_AFTER + 1.0:
			continue
		var all_frozen := true
		for i in pieces.size():
			var p: Variant = pieces[i]
			if is_instance_valid(p) and not (p as Node).is_queued_for_deletion() and DebrisManager.get_bodies().has(p) \
					and not DebrisManager.is_frozen(p):
				all_frozen = false
				break
		if all_frozen:
			break
	var alive := 0
	var frozen := 0
	var moving: Array = []
	for i in pieces.size():
		var p: Variant = pieces[i]
		if is_instance_valid(p) and not (p as Node).is_queued_for_deletion():
			alive += 1
			if DebrisManager.is_frozen(p):
				frozen += 1
			else:
				var rb := p as RigidBody3D
				moving.append("%s v=%.2f w=%.2f" % [rb.name, rb.linear_velocity.length(), rb.angular_velocity.length()])
	_line("%-12s pieces all at rest and frozen %.1f s after the break (bound %.0f s): %d of %d stay (%d fine shards timed out), %d frozen %s" % [
		kind, waited, FREEZE_BOUND, alive, pieces.size(), timed, frozen, moving],
		alive == pieces.size() - timed and frozen == alive)
	await _blast(kind, at + Vector3(0, 0, 14))
	for n in [a, c, d]:
		if is_instance_valid(n):
			n.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)

## A slam-sized blast 1 m from the object through the real WorldDamage.blast:
## glass and cardboard break; every other kind cracks (break energy down to
## at least Furniture.BLAST_CRACK_FLOOR of it) and never breaks; a chair hops loose.
func _blast(kind: StringName, at: Vector3) -> void:
	_breaks.clear()
	var e := ClutterTestUtil.make(self, kind, at)
	await ClutterTestUtil.frames(self, 2)
	var b0 := e.break_energy
	var center := e.get_box_transform().origin - Vector3(e.get_half_extent_along(Vector3.RIGHT) + 1.0, 0, 0)
	center.y = 0.1
	var results: Array = []
	var cb := func(_c: Vector3, _r: float, _p: float, _s: StringName, reached: Array) -> void:
		for r: Array in reached:
			if r[0] == e:
				results.append([r[1], r[2]])
	WorldDamage.blasted.connect(cb)
	WorldDamage.blast(center, float(Tuning.BLAST[&"slam"]), BLAST_POWER, &"slam")
	WorldDamage.blasted.disconnect(cb)
	await ClutterTestUtil.frames(self, 3)
	var light := kind in Tuning.RUN_THROUGH_KINDS
	var power: float = results[0][0] if results.size() > 0 else -1.0
	var res: StringName = results[0][1] if results.size() > 0 else &"none"
	var ok := results.size() == 1
	if light:
		ok = ok and res == &"break" and e.is_broken
	else:
		ok = ok and res == &"crack" and not e.is_broken and e.is_cracked \
			and e.break_energy < b0 and e.break_energy >= Furniture.BLAST_CRACK_FLOOR * b0 - 0.01 \
			and e.is_loose == (kind in Furniture.LOOSE_KINDS) and _breaks.filter(func(x: Dictionary) -> bool:
				return x["node"] == e).is_empty()
	_line("%-12s slam blast %.0f J 1 m off (WorldDamage) reached it with %.0f J -> %s, broken=%s%s, break energy %.0f -> %.0f" % [
		kind, BLAST_POWER, power, res, e.is_broken, " (hopped loose)" if e.is_loose else "", b0, e.break_energy], ok)
	if e.loose_body != null and is_instance_valid(e.loose_body):
		e.loose_body.queue_free()
	e.queue_free()
	WorldDamage.reset()

## True if the object's old place still blocks a capsule-sized query.
func _blocks(space: PhysicsDirectSpaceState3D, f: Furniture) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var box := BoxShape3D.new()
	box.size = f.size
	q.shape = box
	q.transform = f.get_box_transform()
	q.collision_mask = Layers.DESTRUCTIBLE | Layers.WORLD
	for r: Dictionary in space.intersect_shape(q, 8):
		if r["collider"] == f:
			return true
	return false
