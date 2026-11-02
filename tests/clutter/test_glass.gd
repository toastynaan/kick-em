extends Node3D
## Round 6 glass (agent K): a pane shatters from
## - a body: a real 70 kg body thrown at the tapped-throw speed (6 m/s,
##   GameEvents.thrown) through the real ImpactResolver;
## - a strike: a real player jab (CombatController.press(LIGHT), the wall-strike
##   path) on a pane in front of him;
## - a nearby slam: GameEvents.body_slammed 2.0 m away (WorldDamage's real
##   blast, Tuning.BLAST.slam radius); a pane 3.0 m away holds;
## - a real slam: the player (real Traversal) jumps off a 2 m block and
##   drop-strikes; his heavy landing and shockwave reach WorldDamage, which
##   shatters the pane inside the blast radius, leaves the one outside it, and
##   only cracks a sofa inside it (blasts break only glass and cardboard);
## and leaves Furniture.SHARDS_LASTING shards that stay (and freeze) plus
## SHARDS_FINE fine shards that are gone within 5 s, inside DebrisManager's
## budgets; the frame comes down as pieces that stay.

var _ok := true
var _breaks: Array = []
var _struck: Array = []

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[glass] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _ready() -> void:
	ClutterTestUtil.make_floor(self, 400.0)
	ClutterTestUtil.record_breaks(_breaks)
	GameEvents.wall_struck.connect(func(a: Node3D, w: Node3D, _p: Vector3, _n: Vector3, power: float, result: StringName,
			surface: StringName) -> void: _struck.append({"by": a, "wall": w, "power": power, "result": result,
			"surface": surface}))
	await ClutterTestUtil.frames(self, 2)
	await _body(Vector3(0, 0, 0))
	await _strike(Vector3(0, 0, 20))
	await _slam(Vector3(0, 0, 40))
	await _real_slam(Vector3(0, 0, 70))
	print("[glass] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _body(at: Vector3) -> void:
	_breaks.clear()
	var pane := ClutterTestUtil.make(self, &"glass", at, PI * 0.5)
	await ClutterTestUtil.frames(self, 1)
	var face_x := pane.get_box_transform().origin.x + pane.get_half_extent_along(Vector3.RIGHT)
	var thrower := ClutterTestUtil.spawn_body(self, at + Vector3(face_x + 2.6, 0.05, 1.5), 0.0, &"player",
		Fighter.TEAM_PLAYER)
	var body := ClutterTestUtil.spawn_body(self, at + Vector3(face_x + 1.2, 0.05, 0), -PI * 0.5)
	await ClutterTestUtil.frames(self, 8)
	var v := Vector3(-Tuning.THROW_SPEED_TAP, 1.0, 0)
	body.launch(v, body.get_center_of_mass())
	GameEvents.thrown.emit(thrower, body, v)
	await ClutterTestUtil.wait_game(self, 0.8)
	var ev := _breaks.filter(func(x: Dictionary) -> bool: return x["node"] == pane)
	_line("thrown body at %.0f m/s -> broken=%s by body=%s, energy %.0f J; %d pieces (frame %d, shards %d)" % [
		Tuning.THROW_SPEED_TAP, pane.is_broken, ev.size() == 1 and ev[0]["by"] == body,
		float(ev[0]["energy"]) if ev.size() > 0 else -1.0, pane.last_chunks.size(),
		pane.get_spec().pieces.size(), Furniture.SHARDS_LASTING + Furniture.SHARDS_FINE],
		pane.is_broken and ev.size() == 1 and ev[0]["by"] == body)
	var shards := pane.last_chunks.filter(func(p: RigidBody3D) -> bool: return p.has_meta(&"glass_shard"))
	await ClutterTestUtil.wait_game(self, 5.0 + 1.0)
	var stay := 0
	var frozen := 0
	var live := DebrisManager.get_bodies()
	for i in shards.size():
		var p: Variant = shards[i]
		if is_instance_valid(p) and live.has(p):
			stay += 1
			if DebrisManager.is_frozen(p):
				frozen += 1
	var frame_left := 0
	for i in pane.last_chunks.size():
		var p: Variant = pane.last_chunks[i]
		if is_instance_valid(p) and not (p as Node).has_meta(&"glass_shard"):
			frame_left += 1
	var fine := shards.size() - stay
	_line("after 6 s: %d lasting shards stay (want %d, %d frozen), %d fine shards gone (want %d), frame pieces stay %d / %d; debris %d / %d, chips %d / %d" % [
		stay, Furniture.SHARDS_LASTING, frozen, fine, Furniture.SHARDS_FINE, frame_left, pane.get_spec().pieces.size(),
		DebrisManager.count_debris(), Tuning.DEBRIS_MAX, int(DebrisManager.get_world_counts()["chips"]),
		DebrisManager.FX_MAX],
		stay == Furniture.SHARDS_LASTING and fine == Furniture.SHARDS_FINE and frame_left == pane.get_spec().pieces.size())
	for n in [pane, thrower, body]:
		if is_instance_valid(n):
			n.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)

## The real player's jab on a pane in front of him.
func _strike(at: Vector3) -> void:
	_breaks.clear()
	_struck.clear()
	var pane := ClutterTestUtil.make(self, &"glass", at)
	await ClutterTestUtil.frames(self, 1)
	# Pane face toward +Z; the player stands in front facing -Z.
	var face_z := pane.get_box_transform().origin.z + pane.get_half_extent_along(Vector3.BACK)
	var p := FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(at.x, 0.05, face_z + 0.75)),
		Fighter.TEAM_PLAYER)
	await ClutterTestUtil.frames(self, 15)
	p.combat.press(CombatController.Action.LIGHT)
	await ClutterTestUtil.frames(self, 2)
	p.combat.release(CombatController.Action.LIGHT)
	var t := 0.0
	while t < 1.5 and not pane.is_broken:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
	var s := _struck.filter(func(x: Dictionary) -> bool: return x["wall"] == pane)
	var ev := _breaks.filter(func(x: Dictionary) -> bool: return x["node"] == pane)
	_line("player jab: wall_struck %s power %.0f (glass strike_hp %.0f) -> broken=%s by player=%s, event energy %.0f J (>= %.0f)" % [
		s[0]["result"] if s.size() > 0 else &"none", float(s[0]["power"]) if s.size() > 0 else 0.0,
		float(Tuning.FURNITURE[&"glass"]["strike_hp"]), pane.is_broken, ev.size() == 1 and ev[0]["by"] == p,
		float(ev[0]["energy"]) if ev.size() > 0 else -1.0, float(Tuning.FURNITURE[&"glass"]["break"])],
		s.size() >= 1 and s[0]["result"] == &"break" and s[0]["surface"] == &"glass" and pane.is_broken and ev.size() == 1 \
		and ev[0]["by"] == p and float(ev[0]["energy"]) >= float(Tuning.FURNITURE[&"glass"]["break"]))
	for n in [pane, p]:
		if is_instance_valid(n):
			n.queue_free()
	ClutterTestUtil.cleanup()
	await ClutterTestUtil.frames(self, 2)

## A body slam 2.0 m from one pane and 3.0 m from another.
func _slam(at: Vector3) -> void:
	_breaks.clear()
	var near := ClutterTestUtil.make(self, &"glass", at + Vector3(2.0, 0, 0), PI * 0.5)
	var far := ClutterTestUtil.make(self, &"glass", at + Vector3(-3.0 - 0.05, 0, 0), PI * 0.5)
	var holder := ClutterTestUtil.spawn_body(self, at + Vector3(0, 0.05, 1.0), 0.0, &"player", Fighter.TEAM_PLAYER)
	var victim := ClutterTestUtil.spawn_body(self, at + Vector3(0, 0.05, -1.0))
	await ClutterTestUtil.frames(self, 6)
	var d_near := absf(near.get_box_transform().origin.x - at.x) - near.get_half_extent_along(Vector3.RIGHT)
	var d_far := absf(far.get_box_transform().origin.x - at.x) - far.get_half_extent_along(Vector3.RIGHT)
	GameEvents.body_slammed.emit(holder, victim, at)
	await ClutterTestUtil.frames(self, 3)
	var ev := _breaks.filter(func(x: Dictionary) -> bool: return x["node"] == near)
	_line("body slam (blast radius %.1f m): pane %.2f m away -> broken=%s (event energy %.0f J, by %s), pane %.2f m away -> broken=%s" % [
		float(Tuning.BLAST[&"slam"]), d_near, near.is_broken, float(ev[0]["energy"]) if ev.size() > 0 else -1.0,
		ev[0]["by"] if ev.size() > 0 else null, d_far, far.is_broken],
		near.is_broken and not far.is_broken and ev.size() == 1 and float(ev[0]["energy"]) >= float(Tuning.FURNITURE[&"glass"]["break"]))
	for n in [near, far, holder, victim]:
		if is_instance_valid(n):
			n.queue_free()
	ClutterTestUtil.cleanup()
	WorldDamage.reset()
	await ClutterTestUtil.frames(self, 2)

## The player's drop-strike slam off a 2 m block, through Traversal and WorldDamage.
func _real_slam(at: Vector3) -> void:
	_breaks.clear()
	var block := StaticBody3D.new()
	block.collision_layer = Layers.WORLD
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(3.0, 2.0, 3.0)
	cs.shape = bs
	block.add_child(cs)
	add_child(block)
	block.global_position = at + Vector3(0, 1.0, 0)
	var land_x := at.x + 3.2   # about where a running drop off the edge lands
	var near := ClutterTestUtil.make(self, &"glass", Vector3(land_x, 0, at.z + 1.6))
	var far := ClutterTestUtil.make(self, &"glass", Vector3(land_x, 0, at.z + 4.6))
	var sofa := ClutterTestUtil.make(self, &"sofa", Vector3(land_x, 0, at.z - 1.9))
	var sofa_b0 := sofa.break_energy
	var blasts: Array = []
	var cb := func(c: Vector3, r: float, pw: float, src: StringName, _reached: Array) -> void:
		blasts.append([c, r, pw, src])
	WorldDamage.blasted.connect(cb)
	var landings: Array = []
	var p := FighterFactory.spawn_dummy(self, &"player",
		Transform3D(Basis.looking_at(Vector3.RIGHT, Vector3.UP), at + Vector3(1.0, 2.05, 0)), Fighter.TEAM_PLAYER)
	await ClutterTestUtil.frames(self, 20)
	var lcb := func(f: Node3D, level: StringName, pos: Vector3, vs: float) -> void:
		if f == p:
			landings.append([level, pos, vs])
	GameEvents.landing.connect(lcb)
	p.move_input = Vector3.RIGHT * 0.6
	await ClutterTestUtil.frames(self, 10)
	p.traversal.on_jump_pressed()
	p.move_input = Vector3.ZERO
	var t := 0
	while t < 120 and p.velocity.y >= 0.0:
		await get_tree().physics_frame
		t += 1
	var slam := p.traversal.begin_drop_strike()
	t = 0
	while t < 360 and landings.is_empty():
		await get_tree().physics_frame
		t += 1
	await ClutterTestUtil.frames(self, 6)
	WorldDamage.blasted.disconnect(cb)
	GameEvents.landing.disconnect(lcb)
	var c: Vector3 = blasts[0][0] if blasts.size() > 0 else Vector3.INF
	var r: float = blasts[0][1] if blasts.size() > 0 else 0.0
	var d_near := _dist(near, c)
	var d_far := _dist(far, c)
	var d_sofa := _dist(sofa, c)
	var srcs: Array = blasts.map(func(b: Array) -> String: return "%s %.0f J r %.1f" % [b[3], b[2], b[1]])
	var ok: bool = slam and not landings.is_empty() and landings[0][0] == &"heavy" and blasts.size() >= 1 \
		and (near.is_broken == (d_near < r)) and (far.is_broken == (d_far < r)) and d_near < r and d_far > r \
		and not sofa.is_broken and (d_sofa >= r or sofa.break_energy < sofa_b0)
	_line("real slam: drop strike=%s, landing %s at %.1f m/s; blasts %s; pane %.2f m away broken=%s, pane %.2f m away broken=%s, sofa %.2f m away broken=%s (break energy %.0f -> %.0f)" % [
		slam, landings[0][0] if landings.size() > 0 else &"none", float(landings[0][2]) if landings.size() > 0 else 0.0,
		srcs, d_near, near.is_broken, d_far, far.is_broken, d_sofa, sofa.is_broken, sofa_b0, sofa.break_energy], ok)
	for n in [block, near, far, sofa, p]:
		if is_instance_valid(n):
			n.queue_free()
	ClutterTestUtil.cleanup()
	WorldDamage.reset()
	await ClutterTestUtil.frames(self, 2)

static func _dist(f: Furniture, c: Vector3) -> float:
	if c == Vector3.INF:
		return INF
	var xf := f.get_box_transform()
	var lp := xf.affine_inverse() * c
	var h := f.size * 0.5
	return (xf * lp.clamp(-h, h)).distance_to(c)
