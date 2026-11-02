extends "res://tests/input/input_test_base.gd"
## Zone aiming (ZoneAim): a ray at each body part picks its zone, a miss falls
## back to the torso, the screen-centre ray of the active camera drives the
## player's aim_zone/aim_bone, crouch forces the legs and a jump the head,
## Focus is more forgiving, minions' arms can be aimed at, and
## aim_zone_changed reports changes (target null = none).

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	var duelist := spawn_dummy(&"duelist", Vector3(0, 0, -2.5), Vector3.BACK)
	var grunt := spawn_dummy(&"grunt", Vector3(20, 0, -2.5), Vector3.BACK)
	var aimer := spawn_dummy(&"player", Vector3(20, 0, 30), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	await ticks(40)

	# --- 1. A ray at each hurtbox picks that body part's zone. -----------------
	var zones_hit := {}
	for hb in duelist.hurtboxes:
		var c := _hurtbox_centre(hb)
		var origin := Vector3(c.x, c.y, c.z + 3.0)
		var bone := ZoneAim.pick_bone(duelist, origin, c - origin)
		var want := BodyZones.of_bone(hb.bone)
		var got := BodyZones.of_bone(bone) if bone != &"" else -1
		check(got == want, "ray at %s -> %s (hit %s)" % [hb.bone, BodyZones.name_of(want), bone])
		zones_hit[got] = true
	check(zones_hit.has(BodyZones.Zone.HEAD) and zones_hit.has(BodyZones.Zone.TORSO) \
		and zones_hit.has(BodyZones.Zone.ARM_L) and zones_hit.has(BodyZones.Zone.ARM_R) \
		and zones_hit.has(BodyZones.Zone.LEGS), "all five zones reachable on the Duelist")

	# --- 2. A miss falls back to the torso. -----------------------------------
	var top := duelist.global_position + Vector3(0, 2.6, 0)
	check(ZoneAim.pick_bone(duelist, top + Vector3(0, 0, 3), Vector3.FORWARD) == &"", "ray over the head misses")
	var za := ZoneAim.new(aimer)
	za.ray_override = [top + Vector3(0, 0, 3), Vector3.FORWARD]
	za.update(duelist, 1.0 / 120.0)
	check(aimer.aim_zone == BodyZones.Zone.TORSO and aimer.aim_bone == Bones.CHEST, "miss -> TORSO / Chest")

	# --- 3. Aim bones: torso/head keep the bone hit, limbs take the zone's anchor on that side.
	check(ZoneAim.aim_bone_for(BodyZones.Zone.LEGS, Bones.R_UPPER_LEG) == Bones.R_LOWER_LEG, "right thigh -> right shin anchor")
	check(ZoneAim.aim_bone_for(BodyZones.Zone.ARM_L, Bones.L_UPPER_ARM) == Bones.L_LOWER_ARM, "left upper arm -> left forearm anchor")
	check(ZoneAim.aim_bone_for(BodyZones.Zone.TORSO, Bones.HIPS) == Bones.HIPS, "hips stay hips")

	# --- 4. Focus is forgiving: just outside the upper arm misses, in Focus it counts.
	var arm := _find_hurtbox(duelist, Bones.L_UPPER_ARM)
	var ac := _hurtbox_centre(arm)
	var side := signf(ac.x - duelist.global_position.x)
	var r := ((arm.get_child(0) as CollisionShape3D).shape as CapsuleShape3D).radius
	var off := Vector3(ac.x + side * (r + 0.08), ac.y, ac.z + 3.0)
	check(ZoneAim.pick_bone(duelist, off, Vector3.FORWARD) == &"", "0.08 m outside the arm misses normally")
	var focus_bone := ZoneAim.pick_bone(duelist, off, Vector3.FORWARD, ZoneAim.FOCUS_MARGIN)
	check(focus_bone == Bones.L_UPPER_ARM, "in Focus the near miss picks the arm (%s)" % focus_bone)
	za.ray_override = [off, Vector3.FORWARD]
	za.update(duelist, 1.0 / 120.0, true)
	check(aimer.aim_zone == BodyZones.Zone.ARM_L, "ZoneAim in Focus -> ARM_L")

	# --- 5. Outside Focus a new zone settles before it shows; in Focus it is instant.
	var head := _hurtbox_centre(_find_hurtbox(duelist, Bones.HEAD))
	za.ray_override = [head + Vector3(0, 0, 3), Vector3.FORWARD]
	za.update(duelist, 1.0 / 120.0)
	check(aimer.aim_zone == BodyZones.Zone.ARM_L, "outside Focus the head does not show on the first tick")
	for i in 12:
		za.update(duelist, 1.0 / 120.0)
	check(aimer.aim_zone == BodyZones.Zone.HEAD and aimer.aim_bone == Bones.HEAD, "after the settle time -> HEAD / Head")
	var chest := _hurtbox_centre(_find_hurtbox(duelist, Bones.CHEST))
	za.ray_override = [chest + Vector3(0, 0, 3), Vector3.FORWARD]
	za.update(duelist, 1.0 / 120.0, true)
	check(aimer.aim_zone == BodyZones.Zone.TORSO, "in Focus the change is instant")

	# --- 6. Minions have no arm hurtboxes: their arms are aimed from the rig bones.
	var g_ua := grunt.rig.get_bone_global_position(Bones.R_LOWER_ARM)
	var g_hand := grunt.rig.get_bone_global_position(Bones.R_HAND)
	var g_mid := (g_ua + g_hand) * 0.5
	var g_bone := ZoneAim.pick_bone(grunt, g_mid + Vector3(0, 0, 3), Vector3.FORWARD)
	check(BodyZones.of_bone(g_bone) == BodyZones.Zone.ARM_R, "Grunt forearm -> ARM_R (hit %s)" % g_bone)

	# --- 7. The player: the active camera's screen-centre ray drives aim_zone. ---
	var cam := Camera3D.new()
	add_child(cam)
	cam.make_current()
	clear_events()
	var leg := _hurtbox_centre(_find_hurtbox(duelist, Bones.R_LOWER_LEG))
	cam.look_at_from_position(Vector3(leg.x, 1.6, 2.0), leg, Vector3.UP)
	await ticks(12)
	check(p.aim_zone == BodyZones.Zone.LEGS, "camera on the shin -> player aim LEGS (%s)" % BodyZones.name_of(p.aim_zone))
	check(p.aim_bone == Bones.R_LOWER_LEG or p.aim_bone == Bones.L_LOWER_LEG, "aim bone is a shin (%s)" % p.aim_bone)
	var ev := last_event(&"aim_zone_changed")
	check(not ev.is_empty() and ev[1] == p and ev[2] == duelist and ev[3] == BodyZones.Zone.LEGS,
		"aim_zone_changed(player, Duelist, LEGS)")
	cam.look_at_from_position(Vector3(head.x, 1.9, 2.0), head, Vector3.UP)
	await ticks(12)
	check(p.aim_zone == BodyZones.Zone.HEAD, "camera on the head -> HEAD")
	cam.look_at_from_position(Vector3(0, 1.6, 2.0), Vector3(0, 4.5, -2.5), Vector3.UP)
	await ticks(12)
	check(p.aim_zone == BodyZones.Zone.TORSO, "camera off the body -> TORSO fallback")
	var n_changes := count_events(&"aim_zone_changed")
	await ticks(20)
	check(count_events(&"aim_zone_changed") == n_changes, "no event while the zone stays the same")

	# --- 8. Crouch forces the legs, a jump the head. --------------------------
	cam.look_at_from_position(Vector3(chest.x, 1.6, 2.0), chest, Vector3.UP)
	await ticks(12)
	check(p.aim_zone == BodyZones.Zone.TORSO, "camera on the chest -> TORSO")
	press(&"crouch")
	await ticks(2)
	check(p.aim_zone == BodyZones.Zone.LEGS, "crouching forces LEGS")
	release(&"crouch")
	await ticks(3)
	press(&"jump")
	await ticks(2)
	release(&"jump")
	check(p.is_airborne() and p.aim_zone == BodyZones.Zone.HEAD, "jumping forces HEAD")
	await wait_until(func() -> bool: return not p.is_airborne() and p.can_act(), 240)
	await ticks(12)
	check(p.aim_zone == BodyZones.Zone.TORSO, "back on the chest after landing")

	# --- 9. No target: the aim drops to torso and says target null. -----------
	clear_events()
	duelist.global_position = Vector3(0, 0, -40)
	duelist.reset_physics_interpolation()
	await ticks(4)
	ev = last_event(&"aim_zone_changed")
	check(not ev.is_empty() and ev[2] == null and ev[3] == BodyZones.Zone.TORSO, "target gone -> aim_zone_changed(player, null, TORSO)")
	check(p.aim_zone == BodyZones.Zone.TORSO, "no target -> TORSO")
	done()

func _find_hurtbox(f: Fighter, bone: StringName) -> Hurtbox:
	for hb in f.hurtboxes:
		if hb.bone == bone:
			return hb
	return null

func _hurtbox_centre(hb: Hurtbox) -> Vector3:
	return (hb.get_child(0) as CollisionShape3D).global_position
