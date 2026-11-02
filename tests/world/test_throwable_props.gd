extends Node3D
## Round 5 throwable props (Feel Reference: Props; F9).
## 1. Every kind builds its own mass, shape and mesh on Layers.DEBRIS in group
##    "throwable_props"; a limb built by its creator (A) keeps the creator's
##    children, mass and layers.
## 2. pick_up(): held, frozen, touches nothing; drop(): loose again.
## 3. A brick thrown at a standing grunt's chest: a stagger-tier projectile hit
##    for Tuning.PROP_DAMAGE, the thrower untouched; it shatters (prop_broken,
##    pieces through DebrisManager that stay) and is gone.
## 4. A brick thrown at the head knocks down; a bottle at the chest staggers.
## 5. A bottle thrown at a drywall panel breaks on it and strikes the wall.
## 6. An arena prop comes back at its start point Tuning.PROP_RESPAWN s after
##    it breaks; a dropped stick does not; a loose limb never breaks (it stays).
## 7. The Yard scatters props of several kinds, all respawning, none in a
##    wall-run lane.

var _broken: Array = []
var _hits: Array[HitInfo] = []
var _struck: Array = []
var _ok := true

func _ready() -> void:
	GameEvents.prop_broken.connect(func(prop: Node3D, pos: Vector3, kind: StringName) -> void:
		_broken.append({"prop": prop, "pos": pos, "kind": kind}))
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void: _hits.append(info))
	GameEvents.wall_struck.connect(func(_a: Node3D, wall: Node3D, _p: Vector3, _n: Vector3, power: float, result: StringName,
			_s: StringName) -> void: _struck.append([wall, power, result]))
	WorldTestUtil.make_floor(self, 200.0)
	await get_tree().physics_frame

	# 1. Kinds.
	var rows: Array = []
	var kinds_ok := true
	var x := -20.0
	for kind: StringName in [&"brick", &"bottle", &"chair_leg", &"crate_small", &"stick"]:
		var p := ThrowableProp.spawn(self, kind, Transform3D(Basis(), Vector3(x, 0.5, -20)))
		x += 2.0
		await get_tree().physics_frame
		var shapes := p.get_children().filter(func(c: Node) -> bool: return c is CollisionShape3D).size()
		var meshes := p.get_children().filter(func(c: Node) -> bool: return c is MeshInstance3D).size()
		var ok := shapes == 1 and meshes == 1 and is_equal_approx(p.mass, float(ThrowableProp.KINDS[kind]["mass"])) \
			and p.collision_layer == Layers.DEBRIS and p.is_in_group(&"throwable_props") and p.can_pick_up()
		rows.append("%s %.1f kg" % [kind, p.mass])
		kinds_ok = kinds_ok and ok
		p.queue_free()
	var limb := ThrowableProp.new()
	limb.kind = &"limb"
	var lcs := CollisionShape3D.new()
	var lcap := CapsuleShape3D.new()
	lcap.radius = 0.06
	lcap.height = 0.7
	lcs.shape = lcap
	limb.add_child(lcs)
	limb.mass = 3.3
	limb.collision_layer = Layers.DEBRIS
	limb.collision_mask = Layers.MASK_DEBRIS
	add_child(limb)
	limb.global_position = Vector3(x, 0.4, -20)
	await get_tree().physics_frame
	var limb_ok := limb.get_child_count() == 1 and is_equal_approx(limb.mass, 3.3) and limb.is_in_group(&"throwable_props")
	_line("kinds build: %s; A's limb keeps its own shape and mass=%s" % [rows, limb_ok], kinds_ok and limb_ok)

	# 2. Pick up / drop.
	var holder := WorldTestUtil.spawn_body(self, Transform3D(Basis(), Vector3(0, 0.05, -30)), false, &"player", Fighter.TEAM_PLAYER)
	var b := ThrowableProp.spawn(self, &"brick", Transform3D(Basis(), Vector3(0.6, 0.05, -30)))
	await get_tree().physics_frame
	b.pick_up(holder)
	var held_ok := b.is_held() and b.freeze and b.collision_layer == 0 and b.collision_mask == 0 and not b.can_pick_up()
	b.drop(Vector3(1, 0, 0))
	await get_tree().physics_frame
	var drop_ok := not b.is_held() and not b.freeze and b.collision_layer == Layers.DEBRIS and b.can_pick_up()
	_line("pick_up: held, frozen, no collisions=%s; drop: loose again=%s" % [held_ok, drop_ok], held_ok and drop_ok)
	b.queue_free()

	# 3. A brick at a grunt's chest.
	var r := await _throw_at(&"brick", Bones.CHEST, Vector3(0, 0, 0))
	var info: HitInfo = r["info"]
	var hit_ok: bool = info != null and info.kind == &"projectile" and info.tier == HitInfo.Tier.STAGGER \
		and absf(r["hp_lost"] - Tuning.PROP_DAMAGE) < 0.01 and r["broken"] and r["gone"] and r["pieces"] >= 2 \
		and r["thrower_hp_lost"] < 0.01
	_line("brick at a grunt's chest: tier %s, damage %.0f (want %.0f), shattered=%s pieces=%d gone=%s, thrower hit=%s" % [
		HitInfo.tier_name(info.tier) if info else &"none", r["hp_lost"], Tuning.PROP_DAMAGE, r["broken"], r["pieces"],
		r["gone"], r["thrower_hp_lost"] > 0.0], hit_ok)

	# 4. Brick to the head: knockdown. Bottle to the chest: stagger.
	r = await _throw_at(&"brick", Bones.HEAD, Vector3(0, 0, 10))
	info = r["info"]
	var head_ok: bool = info != null and info.tier == HitInfo.Tier.KNOCKDOWN and info.hit_bone == Bones.HEAD and r["broken"]
	r = await _throw_at(&"bottle", Bones.CHEST, Vector3(0, 0, 20))
	var bi: HitInfo = r["info"]
	var bottle_ok: bool = bi != null and bi.tier == HitInfo.Tier.STAGGER and r["broken"] and r["pieces"] == 0
	_line("brick to the head: %s on %s; bottle to the chest: %s, shattered=%s" % [
		HitInfo.tier_name(info.tier) if info else &"none", info.hit_bone if info else &"-",
		HitInfo.tier_name(bi.tier) if bi else &"none", r["broken"]], head_ok and bottle_ok)

	# 5. A bottle at a drywall panel.
	_broken.clear()
	_struck.clear()
	var panel := WorldTestUtil.make_panel(self, &"drywall", Vector3(0, 0, 40))
	var bot := ThrowableProp.spawn(self, &"bottle", Transform3D(Basis(), Vector3(3.0, 1.4, 40)))
	await get_tree().physics_frame
	bot.throw(Vector3(-14, 1.0, 0), null)
	await WorldTestUtil.wait_game(self, 0.5)
	var wall_hit := _struck.filter(func(s: Array) -> bool: return s[0] == panel)
	var w_ok := _broken.size() == 1 and wall_hit.size() == 1 and not is_instance_valid(bot)
	_line("bottle into drywall: broke=%d, wall struck=%s" % [_broken.size(), wall_hit.map(func(s: Array) -> String:
		return "%s %.0f" % [s[2], s[1]])], w_ok)
	panel.queue_free()

	# 6. Respawn: arena prop yes; dropped stick and loose limb no.
	var home := Transform3D(Basis(), Vector3(10, 0.05, -40))
	var arena := ThrowableProp.spawn(self, &"crate_small", home, true)
	var stick := ThrowableProp.spawn(self, &"stick", Transform3D(Basis(), Vector3(14, 0.05, -40)))
	await get_tree().physics_frame
	arena.shatter()
	stick.shatter()
	_broken.clear()
	limb.shatter()
	var limb_stays := is_instance_valid(limb) and not limb.is_queued_for_deletion() and _broken.is_empty()
	await WorldTestUtil.wait_game(self, Tuning.PROP_RESPAWN - 1.0)
	var early := _props_near(home.origin, 0.5).size()
	await WorldTestUtil.wait_game(self, 1.5)
	var back := _props_near(home.origin, 0.5)
	var stick_back := _props_near(Vector3(14, 0.05, -40), 1.0).size()
	var limbs := get_tree().get_nodes_in_group(&"throwable_props").filter(func(n: Node) -> bool:
		return (n as ThrowableProp).kind == &"limb" and not n.is_queued_for_deletion()).size()
	var r_ok := early == 0 and back.size() == 1 and back[0].kind == &"crate_small" and back[0].respawns and stick_back == 0 \
		and limb_stays and limbs == 1
	_line("respawn: arena crate back after %.0f s=%s (not before=%s); dropped stick back=%s; a limb never breaks=%s and is not duplicated (%d)" % [
		Tuning.PROP_RESPAWN, back.size() == 1, early == 0, stick_back > 0, limb_stays, limbs], r_ok)

	# 7. The Yard's props.
	var yard := YardBuilder.new()
	add_child(yard)
	yard.position = Vector3(0, 0, 200)
	yard.build()
	await get_tree().physics_frame
	var props := yard.get_throwables()
	var kinds := {}
	var in_lane := 0
	var respawn_all := true
	for p in props:
		kinds[p.kind] = kinds.get(p.kind, 0) + 1
		respawn_all = respawn_all and p.respawns
		var lp := p.global_position - yard.global_position
		if absf(absf(lp.x) - YardBuilder.HALF) < 1.2 and absf(lp.z) < 7.5:
			in_lane += 1
		if absf(lp.z - YardBuilder.HALF) < 1.2 and absf(lp.x) < 9.0:
			in_lane += 1
	_line("yard props: %d %s, all respawn=%s, in a run lane=%d" % [props.size(), kinds, respawn_all, in_lane],
		props.size() >= 6 and kinds.size() >= 3 and respawn_all and in_lane == 0)

	print("[props] RESULT: ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)

func _line(s: String, ok: bool) -> void:
	_ok = _ok and ok
	print("[props] %s -> %s" % [s, "PASS" if ok else "FAIL"])

func _props_near(pos: Vector3, radius: float) -> Array[ThrowableProp]:
	var out: Array[ThrowableProp] = []
	for n in get_tree().get_nodes_in_group(&"throwable_props"):
		var p := n as ThrowableProp
		if p and not p.is_queued_for_deletion() and p.global_position.distance_to(pos) <= radius:
			out.append(p)
	return out

## Throw a fresh `kind` from a thrower 4 m away at `bone` of a standing grunt.
func _throw_at(kind: StringName, bone: StringName, at: Vector3) -> Dictionary:
	_broken.clear()
	_hits.clear()
	var victim := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, -PI * 0.5), at + Vector3(0, 0.05, 0)), false)
	var thrower := WorldTestUtil.spawn_body(self, Transform3D(Basis(Vector3.UP, PI * 0.5), at + Vector3(4.0, 0.05, 0)), false,
		&"player", Fighter.TEAM_PLAYER)
	for i in 6:
		await get_tree().physics_frame
	var hp0 := victim.hp
	var thp0 := thrower.hp
	var aim := victim.rig.get_bone_global_position(bone) if victim.rig else victim.get_aim_point()
	var from := at + Vector3(3.2, 1.45, 0)
	var p := ThrowableProp.spawn(self, kind, Transform3D(Basis(), from))
	await get_tree().physics_frame
	p.pick_up(thrower)
	# A flat 16 m/s throw with a little lift for the drop over 3 m.
	var d := aim - from
	var t := Vector2(d.x, d.z).length() / 16.0
	var vel := Vector3(d.x / t, d.y / t + 0.5 * 9.8 * t, d.z / t)
	p.throw(vel, thrower)
	var debris0 := DebrisManager.count()
	await WorldTestUtil.wait_game(self, 0.5)
	var info: HitInfo = null
	for h in _hits:
		if h.victim == victim and h.kind == &"projectile":
			info = h
	var res := {"info": info, "hp_lost": hp0 - victim.hp, "thrower_hp_lost": thp0 - thrower.hp,
		"broken": _broken.size() >= 1, "gone": not is_instance_valid(p) or p.is_queued_for_deletion(),
		"pieces": DebrisManager.count() - debris0}
	victim.queue_free()
	thrower.queue_free()
	WorldTestUtil.cleanup()
	await get_tree().physics_frame
	return res
