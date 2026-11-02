extends Node3D
## Dismemberment (Feel Reference F10, "How a limb comes off"), agent A.
## A severing launch (B's order: launch, sever, hitstop) hides the limb, shows
## the wound cap at the stump and spawns the loose limb (a ThrowableProp of
## kind &"limb") that waits frozen through the hitstop, then flies at the
## bone's speed (both speeds logged). Mid-flight without a hitstop the limb
## leaves at the bone's speed at once; severed just before a launch in the
## same frame it gets the launch too. A living fighter missing an arm and a
## leg keeps animating, flinching, falling and getting up. Loose limbs never
## pass Tuning.LOOSE_LIMB_MAX (the oldest dissolves).

var _ok := true

func _check(what: String, cond: bool, info := "") -> void:
	print("  %-60s %s %s" % [what, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _limb_parts(d: LabDummy, bones: Array) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for b in bones:
		out.append_array(d.rig.get_bone_parts(b))
	return out

func _all_hidden(parts: Array[MeshInstance3D]) -> bool:
	for p in parts:
		if p.visible:
			return false
	return parts.size() > 0

func _ready() -> void:
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		print("SEVER FAIL (timeout)")
		get_tree().quit(1))
	RigTestUtil.make_floor(self, 400.0)
	var d := RigTestUtil.make_dummy(self, &"grunt", Vector3(0, 0, 0), null, false)
	await _frames(8)
	var max_seen := 0

	# --- 1. Severing launch with its hitstop -------------------------------------------------
	var parts := _limb_parts(d, [Bones.R_UPPER_ARM, Bones.R_LOWER_ARM, Bones.R_HAND])
	var v := Power.launch_velocity(9.0, Vector3.BACK)   # P 9: a severing launch, 14 m/s at 18 degrees
	d.ragdoll.launch(v, d.global_position + Vector3.UP, Bones.R_LOWER_ARM)
	var bone_v: Vector3 = d.ragdoll.get_bone_velocity(Bones.R_UPPER_ARM)[0]
	var piece := d.rig.sever(&"arm_r")
	TimeDirector.hitstop([d], Power.hitstop_for(HitInfo.Tier.SEVER))
	var cap := d.rig.get_wound_cap(&"arm_r")
	_check("loose limb is a ThrowableProp of kind limb", piece is ThrowableProp and (piece as ThrowableProp).kind == &"limb"
		and piece.is_in_group(&"loose_limbs") and (piece as ThrowableProp).can_pick_up())
	_check("the limb's parts are hidden, the wound cap shows", _all_hidden(parts) and cap != null and cap.is_visible_in_tree()
		and d.rig.is_severed(&"arm_r") and d.rig.is_bone_severed(Bones.R_HAND))
	var pb := d.rig.get_physical_bone(Bones.R_UPPER_ARM).get_rid()
	_check("the cut bones are out of the ragdoll", PhysicsServer3D.body_get_collision_layer(pb) == 0
		and PhysicsServer3D.body_get_mode(pb) == PhysicsServer3D.BODY_MODE_STATIC
		and absf(d.ragdoll.get_total_mass() - (75.0 - (Bones.MASS_70[Bones.R_UPPER_ARM] + Bones.MASS_70[Bones.R_LOWER_ARM]) * 75.0 / 70.1)) < 0.01,
		"%.2f kg left" % d.ragdoll.get_total_mass())
	var p0 := piece.global_position
	var frozen_ticks := 0
	var held_still := 0.0
	await get_tree().physics_frame   # the hold starts on the controller's next tick (host poll)
	while d.ragdoll.is_in_hitstop() and frozen_ticks < 60:
		held_still = maxf(held_still, piece.global_position.distance_to(p0))
		await get_tree().physics_frame
		frozen_ticks += 1
	var limb_v := piece.linear_velocity
	_check("the limb waits at the stump through the hitstop", held_still < 0.005 and frozen_ticks >= 18,
		"%d ticks, moved %.4f m" % [frozen_ticks, held_still])
	print("    bone speed at the cut %.2f m/s %s, loose limb after the hitstop %.2f m/s %s" % [bone_v.length(), bone_v, limb_v.length(), limb_v])
	_check("the loose limb flies at the bone's speed", absf(limb_v.length() - bone_v.length()) < 0.1 * bone_v.length()
		and limb_v.normalized().dot(bone_v.normalized()) > 0.97)
	max_seen = maxi(max_seen, HumanoidRig.loose_limb_count())
	var n := 0
	var nan := false
	while d.ragdoll.state != RagdollController.State.ANIMATED and n < 1200:
		await get_tree().physics_frame
		n += 1
		nan = nan or RigTestUtil.has_nan(d.ragdoll)
	_check("the one-armed body lands and gets up", d.ragdoll.state == RagdollController.State.ANIMATED and not nan,
		"%.2f s" % (n / 120.0))

	# --- 2. Mid-flight, no hitstop: the limb leaves at once -------------------------------------
	d.ragdoll.launch(Vector3(0, 4, 7), d.global_position + Vector3.UP, Bones.CHEST)
	await _frames(10)
	var leg_v: Vector3 = d.ragdoll.get_bone_velocity(Bones.L_UPPER_LEG)[0]
	var piece2 := d.rig.sever(&"leg_l")
	_check("mid-flight: the leg leaves at the bone's speed", piece2 != null and not piece2.freeze
		and piece2.linear_velocity.distance_to(leg_v) < 0.01 and d.rig.get_wound_cap(&"leg_l").is_visible_in_tree(),
		"bone %.2f m/s, limb %.2f m/s" % [leg_v.length(), piece2.linear_velocity.length()])
	max_seen = maxi(max_seen, HumanoidRig.loose_limb_count())
	n = 0
	nan = false
	while d.ragdoll.state != RagdollController.State.ANIMATED and n < 1200:
		await get_tree().physics_frame
		n += 1
		nan = nan or RigTestUtil.has_nan(d.ragdoll)
	_check("missing an arm and a leg: still lands and gets up", d.ragdoll.state == RagdollController.State.ANIMATED and not nan,
		"%.2f s" % (n / 120.0))

	# --- 3. A living fighter missing limbs keeps working -------------------------------------------
	d.move_input = Vector3(0, 0, -1)
	await _frames(60)
	d.move_input = Vector3.ZERO
	d.ragdoll.flinch(Vector3(0, 0, 1), Bones.R_LOWER_ARM, 1.0)   # the missing arm: the body takes it
	var s_chest := d.ragdoll.get_bone_strength(Bones.CHEST)
	await _frames(40)
	d.ragdoll.limp_chain([Bones.R_UPPER_ARM, Bones.R_LOWER_ARM] as Array[StringName], 1.0, 0.0)   # ignored: it is gone
	d.ragdoll.stagger(Vector3(0, 0, 1), 0.75)
	await _frames(90)
	d.ragdoll.knockdown(Vector3(0, 0, 1), Bones.CHEST)
	n = 0
	nan = false
	while d.ragdoll.state != RagdollController.State.ANIMATED and n < 900:
		await get_tree().physics_frame
		n += 1
		nan = nan or RigTestUtil.has_nan(d.ragdoll)
	_check("one arm, one leg: walks, flinches, staggers, falls, gets up", not nan and s_chest < 0.5
		and d.ragdoll.state == RagdollController.State.ANIMATED, "flinch on the missing arm moved the chest (%.2f)" % s_chest)

	# --- 4. Sever, then launch in the same frame -------------------------------------------------
	var e := RigTestUtil.make_dummy(self, &"grunt", Vector3(12, 0, 0), null, false)
	await _frames(8)
	var piece3 := e.rig.sever(&"arm_l")
	var lv := Vector3(0, 3, 10)
	e.ragdoll.launch(lv, e.global_position + Vector3.UP, Bones.L_LOWER_ARM)
	await get_tree().physics_frame
	_check("severed just before a launch: the limb gets the launch too", piece3.linear_velocity.z > lv.z * 0.8,
		"limb %s" % piece3.linear_velocity)
	max_seen = maxi(max_seen, HumanoidRig.loose_limb_count())

	# --- 5. Never more than 12 loose limbs ---------------------------------------------------------
	var extra: Array[LabDummy] = []
	for i in 4:
		extra.append(RigTestUtil.make_dummy(self, &"grunt", Vector3(-12 - 4 * i, 0, 0), null, false))
	await _frames(8)
	for x in extra:
		x.ragdoll.launch(Vector3(0, 3, 4), x.global_position + Vector3.UP, Bones.CHEST)
	await _frames(10)
	for x in extra:
		for cut in [&"arm_l", &"arm_r", &"leg_l", &"leg_r"]:
			if x.rig.sever(cut) != null:
				max_seen = maxi(max_seen, HumanoidRig.loose_limb_count())
				await get_tree().physics_frame
	await _frames(int((HumanoidRig.LIMB_FADE_TIME + 0.2) * 120.0))
	var in_group := get_tree().get_nodes_in_group(&"loose_limbs").size()
	var alive := 0
	for node in get_children():
		if node is ThrowableProp and (node as ThrowableProp).kind == &"limb":
			alive += 1
	_check("loose limbs never pass %d (oldest dissolve)" % Tuning.LOOSE_LIMB_MAX, max_seen <= Tuning.LOOSE_LIMB_MAX
		and in_group <= Tuning.LOOSE_LIMB_MAX and alive <= Tuning.LOOSE_LIMB_MAX,
		"20 cut, at most %d counted, %d in the scene after the fade" % [max_seen, alive])
	print("SEVER ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)
