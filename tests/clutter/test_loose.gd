extends Node3D
## Round 6 light clutter coming loose (agent K):
## - a real body tumbling into a chair below its break energy knocks it loose:
##   the chair becomes one LooseFurniture debris body (Layers.DEBRIS, managed by
##   DebrisManager), stops blocking, and moves off along the hit;
## - a second, hard hit (a real body thrown at 9 m/s) breaks the loose chair
##   where it lies (furniture_broken by that body), and costs that body what the
##   ImpactResolver charges for any breakable: sqrt(1 - absorb) of its speed and
##   Tuning.FURNITURE_BODY_DAMAGE;
## - a blast too weak to crack a chair hops it loose; a stacked box falls when
##   the box under it breaks (no floating boxes);
## - a loose object at rest freezes (DebrisManager) like any debris;
## - the office LooseProps (chair 8 kg, drum 30 kg, cabinet 55 kg) are
##   breakables too: a real body breaks the chair (furniture_broken, pieces
##   stay), cracks shove a drum; a slam blast never breaks one (it cracks the
##   drum and hops it; the cabinet holds).

var _ok := true
var _breaks: Array = []

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[loose] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _ready() -> void:
	ClutterTestUtil.make_floor(self, 400.0)
	ClutterTestUtil.record_breaks(_breaks)
	await ClutterTestUtil.frames(self, 2)
	await _knock_and_break(Vector3(0, 0, 0))
	await _blast_hop(Vector3(0, 0, 20))
	await _stack(Vector3(0, 0, 30))
	await _loose_props(Vector3(0, 0, 45))
	print("[loose] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _knock_and_break(at: Vector3) -> void:
	var chair := ClutterTestUtil.make(self, &"chair", at, PI * 0.5)
	await ClutterTestUtil.frames(self, 1)
	var p0 := chair.get_box_transform().origin
	var face_x := p0.x + chair.get_half_extent_along(Vector3.RIGHT)
	var body := ClutterTestUtil.spawn_body(self, at + Vector3(face_x + 1.1, 0.05, 0), -PI * 0.5)
	await ClutterTestUtil.frames(self, 8)
	var b := float(Tuning.FURNITURE[&"chair"]["break"])
	var speed := sqrt(2.0 * 0.65 * b / body.get_total_mass())
	body.launch(Vector3(-speed, 0.5, 0), body.get_center_of_mass())
	await ClutterTestUtil.wait_game(self, 1.2)
	var lb := chair.loose_body
	var moved := lb.global_position.distance_to(p0) if lb != null and is_instance_valid(lb) else 0.0
	var managed := lb != null and DebrisManager.get_bodies().has(lb) and lb.collision_layer == Layers.DEBRIS
	_line("body at %.1f m/s (%.0f%% of break) -> chair loose=%s broken=%s, debris body managed=%s, moved %.2f m, its old place blocking=%s" % [
		speed, 65.0, chair.is_loose, chair.is_broken, managed, moved, chair.collision_layer != 0],
		chair.is_loose and not chair.is_broken and managed and moved > 0.05 and chair.collision_layer == 0)
	body.queue_free()
	await ClutterTestUtil.wait_game(self, Tuning.DEBRIS_FREEZE_AFTER + 2.5)
	var frozen := lb != null and is_instance_valid(lb) and DebrisManager.is_frozen(lb)
	_line("loose chair at rest freezes: %s" % frozen, frozen)
	# A thrown body breaks it where it lies.
	_breaks.clear()
	var lp := lb.global_position if lb != null and is_instance_valid(lb) else p0
	var thrower := ClutterTestUtil.spawn_body(self, lp + Vector3(3.0, 0.05, 2.0), 0.0, &"player", Fighter.TEAM_PLAYER)
	var body2 := ClutterTestUtil.spawn_body(self, Vector3(lp.x + 1.4, 0.05, lp.z), -PI * 0.5)
	await ClutterTestUtil.frames(self, 8)
	var v := Vector3(-9.0, 0.3, 0)
	body2.max_hp = 1000.0
	body2.hp = 1000.0
	var hp0 := body2.hp
	body2.launch(v, body2.get_center_of_mass())
	GameEvents.thrown.emit(thrower, body2, v)
	var max_v := 0.0
	var closest := INF
	for i in 120:
		await get_tree().physics_frame
		if lb != null and is_instance_valid(lb):
			max_v = maxf(max_v, lb.linear_velocity.length())
			closest = minf(closest, body2.get_center_of_mass().distance_to(lb.global_position))
	print("[loose] contact: loose chair top speed %.2f, body closest %.2f, frozen=%s" % [max_v, closest,
		DebrisManager.is_frozen(lb) if lb != null and is_instance_valid(lb) else false])
	var ev := _breaks.filter(func(x: Dictionary) -> bool: return x["node"] == chair)
	var kept := chair.last_flyer_speeds.y / maxf(chair.last_flyer_speeds.x, 0.01)
	var want := sqrt(1.0 - float(Tuning.FURNITURE[&"chair"]["absorb"]))
	var dmg := hp0 - body2.hp
	_line("thrown body at 9 m/s into the loose chair -> broken=%s by body=%s, %d pieces, event energy %.0f J; the body kept %.3f of its speed (%.1f -> %.1f m/s, want sqrt(1-0.1) = %.3f) and took %.0f damage (want %.0f)" % [
		chair.is_broken, ev.size() == 1 and ev[0]["by"] == body2, chair.last_chunks.size(),
		float(ev[0]["energy"]) if ev.size() > 0 else -1.0, kept, chair.last_flyer_speeds.x, chair.last_flyer_speeds.y,
		want, dmg, Tuning.FURNITURE_BODY_DAMAGE],
		chair.is_broken and ev.size() == 1 and ev[0]["by"] == body2 and chair.last_chunks.size() == 6 \
		and float(ev[0]["energy"]) >= b and absf(kept - want) < 0.01 and is_equal_approx(dmg, Tuning.FURNITURE_BODY_DAMAGE))
	for n in [chair, thrower, body2]:
		n.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)

func _blast_hop(at: Vector3) -> void:
	var chair := ClutterTestUtil.make(self, &"chair", at)
	var bench := ClutterTestUtil.make(self, &"bench", at + Vector3(2.0, 0, 0))
	await ClutterTestUtil.frames(self, 1)
	var b := float(Tuning.FURNITURE[&"chair"]["break"])
	var r := chair.receive_blast(at + Vector3(-1.2, 0.1, 0), 2.5, 0.25 * b, &"slam")
	var rb := bench.receive_blast(at + Vector3(0.8, 0.1, 0), 2.5, 0.25 * b, &"slam")
	await ClutterTestUtil.frames(self, 6)
	var lb := chair.loose_body
	var up := lb.linear_velocity.y if lb != null else 0.0
	var away := lb.linear_velocity.x if lb != null else 0.0
	_line("blast of %.0f J at a chair -> %s (loose=%s, hop %.1f m/s up, %.1f m/s away); at a bench -> %s (holds=%s)" % [
		0.25 * b, r, chair.is_loose, up, away, rb, not bench.is_broken and not bench.is_loose],
		r == &"shove" and chair.is_loose and up > 0.3 and away > 0.1 and rb == &"shove" and not bench.is_broken)
	for n in [chair, bench]:
		n.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)

func _stack(at: Vector3) -> void:
	var bottom := ClutterTestUtil.make(self, &"cardboard", at, 0.0, &"big")
	var top := Furniture.create(&"cardboard", Transform3D(Basis(Vector3.UP, 0.3),
		at + Vector3(0, bottom.get_spec().bounds.end.y, 0)), &"small")
	top.resting_on = bottom
	add_child(top)
	await ClutterTestUtil.frames(self, 2)
	var y0 := top.get_box_transform().origin.y
	bottom.receive_strike(null, bottom.get_box_transform().origin + Vector3(0, 0, 0.23), Vector3.FORWARD, 30.0)
	await ClutterTestUtil.wait_game(self, 1.5)
	var lb := top.loose_body
	var y1 := lb.global_position.y if lb != null and is_instance_valid(lb) else y0
	_line("stacked box: the box under it broken=%s -> the top box came loose=%s and fell %.2f m" % [
		bottom.is_broken, top.is_loose, y0 - y1 - top.get_spec().bounds.get_center().y],
		bottom.is_broken and top.is_loose and y1 < y0 - 0.2)
	for n in [bottom, top]:
		n.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)

## D's office props through the contract (and a real body for the chair).
func _loose_props(at: Vector3) -> void:
	_breaks.clear()
	var chair := _make_prop(at, 8.0, &"wood", 60.0)
	var drum := _make_prop(at + Vector3(0, 0, 6), 30.0, &"concrete", 180.0)
	var cab := _make_prop(at + Vector3(0, 0, 12), 55.0, &"concrete", 240.0)
	await ClutterTestUtil.frames(self, 20)
	var kinds := [chair.kind, drum.kind, cab.kind]
	var contract := WorldTags.breakable_of(chair) == chair and chair.is_in_group(&"props") \
		and is_equal_approx(chair.break_energy, float(Tuning.FURNITURE[&"chair"]["break"])) and chair.size.length() > 0.3
	# A body thrown at the chair.
	var thrower := ClutterTestUtil.spawn_body(self, at + Vector3(3.0, 0.05, 1.5), 0.0, &"player", Fighter.TEAM_PLAYER)
	var body := ClutterTestUtil.spawn_body(self, at + Vector3(1.3, 0.05, 0), -PI * 0.5)
	await ClutterTestUtil.frames(self, 8)
	var v := Vector3(-8.0, 0.8, 0)
	body.launch(v, body.get_center_of_mass())
	GameEvents.thrown.emit(thrower, body, v)
	await ClutterTestUtil.wait_game(self, 0.8)
	var ev := _breaks.filter(func(x: Dictionary) -> bool: return x["kind"] == &"chair")
	var chunks: int = ev[0]["chunks"] if ev.size() > 0 else 0
	# A crack-level hit shoves the drum; a blast hops the drum, not the cabinet.
	var d0 := drum.global_position
	var r_drum := drum.receive_impact(0.6 * drum.break_energy, drum.global_position + Vector3(0.3, 0.4, 0), Vector3(-5, 0, 0))
	await ClutterTestUtil.frames(self, 30)
	var shoved := drum.global_position.distance_to(d0)
	var rb_cab := cab.receive_blast(cab.global_position + Vector3(1, 0, 0), 2.5, 300.0, &"slam")
	var drum_e0 := drum.break_energy
	var rb_drum := drum.receive_blast(drum.global_position + Vector3(0.8, 0, 0), 2.5, 5000.0, &"slam")
	await ClutterTestUtil.frames(self, 2)
	var drum_ok := rb_drum == &"crack" and not drum.is_broken and is_instance_valid(drum) \
		and drum.break_energy >= LooseProp.BLAST_CRACK_FLOOR * drum.original_break_energy - 0.01 and drum.break_energy < drum_e0
	_line("office props %s: contract=%s; thrown body at 8 m/s breaks the chair: %d event(s) by body=%s, %d pieces (one per mesh: 2); drum at 0.6x break -> %s, shoved %.2f m; cabinet blast 300 J -> %s; drum blast 5000 J -> %s, broken=%s, break energy %.0f -> %.0f" % [
		kinds, contract, ev.size(), ev.size() == 1 and ev[0]["by"] == body, chunks, r_drum, shoved, rb_cab, rb_drum,
		drum.is_broken, drum_e0, drum.break_energy],
		kinds == [&"chair", &"drum", &"cabinet"] and contract and ev.size() == 1 and ev[0]["by"] == body and chunks == 2 \
		and r_drum == &"crack" and shoved > 0.05 and rb_cab == &"hold" and drum_ok)
	for n in [drum, cab, thrower, body]:
		if is_instance_valid(n):
			n.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)

## A LooseProp built the way YardBuilder does (mass, surface, strike_hp, then meshes and shapes).
func _make_prop(at: Vector3, mass: float, surface: StringName, hp: float) -> LooseProp:
	var b := LooseProp.new()
	b.mass = mass
	b.surface = surface
	b.strike_hp = hp
	add_child(b)
	b.position = at
	var size := Vector3(0.45, 0.9, 0.45) if mass < 15.0 else Vector3(0.58, 0.9, 0.58)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = Vector3(0, size.y * 0.5, 0)
	b.add_child(mi)
	var leg := MeshInstance3D.new()
	var lm := BoxMesh.new()
	lm.size = Vector3(0.06, 0.3, 0.06)
	leg.mesh = lm
	leg.position = Vector3(0, size.y + 0.15, 0)
	b.add_child(leg)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	cs.position = Vector3(0, size.y * 0.5, 0)
	b.add_child(cs)
	return b
