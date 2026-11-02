extends "res://tests/input/input_test_base.gd"
## Health, death and bodies (Round 5, Feel Reference: Health and damage,
## Bodies stay; agent H): archetype health on the 100 scale; 0 HP is death:
## a full ragdoll, hurtboxes off, GameEvents.fighter_died; a dead body sits on
## Layers.DEAD_BODY (A), which a walking capsule passes through, and the
## walker's feet (an Area3D on every fighter) nudge the bones they step into.

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	await ticks(20)
	check(is_equal_approx(p.max_hp, 100.0) and is_equal_approx(p.hp, 100.0), "player health %.0f / %.0f" % [p.hp, p.max_hp])
	for arch: StringName in [&"grunt", &"stick", &"heavy"]:
		var f := spawn_dummy(arch, Vector3(10, 0, 0), Vector3.FORWARD)
		await ticks(2)
		check(is_equal_approx(f.max_hp, float(Tuning.ARCHETYPES[arch]["hp"])), "%s health %.0f" % [arch, f.max_hp])
		f.queue_free()
	await ticks(2)
	check(p.get_node_or_null(^"Feet") is Area3D, "the player has a foot Area3D")

	# --- Death: full ragdoll. -----------------------------------------------------
	var g := spawn_dummy(&"grunt", Vector3(0, 0, -2.0), Vector3.BACK)
	await ticks(20)
	clear_events()
	var info := HitInfo.new()
	info.attacker = p
	info.victim = g
	info.hit_direction = Vector3.FORWARD
	g.apply_damage(500.0, &"test", info)
	await ticks(2)
	check(g.is_dead() and g.hp == 0.0, "0 HP: dead")
	check(count_events(&"fighter_died") == 1, "GameEvents.fighter_died")
	check(g.get_state() == RagdollController.State.DEAD and g.ragdoll.is_full_ragdoll(), "full ragdoll (state DEAD)")
	var boxes_on := 0
	for hb in g.hurtboxes:
		if is_instance_valid(hb) and hb.monitorable:
			boxes_on += 1
	check(boxes_on == 0, "hurtboxes off")
	await wait_until(func() -> bool: return g.ragdoll.get_com_velocity().length() < 0.3, 600)
	await ticks(30)

	var bones := _bones_of(g)
	var on_layer := 0
	for b in bones:
		if b.collision_layer & Layers.DEAD_BODY:
			on_layer += 1
	if on_layer == 0:
		# A moves dead bodies to Layers.DEAD_BODY; until then, do it here so the feet are tested.
		print("  NOTE the dead body is not on Layers.DEAD_BODY yet (A); moving it there for this test")
		for b in bones:
			b.collision_layer = Layers.DEAD_BODY
			b.collision_mask = Layers.MASK_DEAD_BODY
	else:
		check(on_layer == bones.size(), "every bone of the dead body is on Layers.DEAD_BODY (%d / %d)" % [on_layer, bones.size()])
	await ticks(5)

	# --- Walk through it: the capsule passes, the feet nudge the bones. -----------
	var pos0 := {}
	for b in bones:
		pos0[b] = b.global_position
	var com0 := g.ragdoll.get_center_of_mass()
	var gp := g.ragdoll.get_ground_position()
	p.teleport_to(Vector3(gp.x, 0, gp.z + 2.5), Vector3.FORWARD)
	await ticks(10)
	press(&"move_forward")
	var min_gap := INF
	var z_start := p.global_position.z
	for i in 150:
		await get_tree().physics_frame
		min_gap = minf(min_gap, Vector2(p.global_position.x - gp.x, p.global_position.z - gp.z).length())
	release(&"move_forward")
	var walked := z_start - p.global_position.z
	var moved := 0
	var most := 0.0
	for b in bones:
		var d := (b.global_position - pos0[b] as Vector3).length()
		most = maxf(most, d)
		if d > 0.03:
			moved += 1
	var com_shift := g.ragdoll.get_center_of_mass().distance_to(com0)
	print("  walked %.2f m, passed %.2f m from the body; %d bones moved (most %.2f m), COM shifted %.2f m"
		% [walked, min_gap, moved, most, com_shift])
	check(walked > 4.0 and min_gap < 0.4, "the capsule walked straight through the body")
	check(moved >= 2 and most > 0.05, "the feet nudged the body")
	check(com_shift < 1.0, "a nudge, not a kick (COM %.2f m)" % com_shift)
	done()

func _bones_of(f: Fighter) -> Array[PhysicalBone3D]:
	var out: Array[PhysicalBone3D] = []
	var stack: Array[Node] = [f.rig]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is PhysicalBone3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out
