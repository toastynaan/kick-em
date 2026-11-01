extends Node3D
## Every move and hold id from the PoseAnimator contract exists; strike poses
## physically reach (jab fist ~0.6 m in front of the chest, sparta kick foot
## ~0.9 m in front of the hips); play_move stretches to the given timing and
## emits move_finished; time_scale 0 freezes; IK keeps planted feet planted.

var _ok := true

func _check(name: String, cond: bool, info := "") -> void:
	print("  %-40s %s %s" % [name, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("POSES FAIL (timeout)")
		get_tree().quit(1))
	RigTestUtil.make_floor(self)
	var d := RigTestUtil.make_dummy(self, &"player", Vector3.ZERO, null, true)
	for i in 4:
		await get_tree().physics_frame
	var ids_ok := true
	for id in PoseLibrary.ALL_MOVE_IDS:
		ids_ok = ids_ok and PoseLibrary.MOVES.has(id)
		for k in PoseLibrary.MOVES[id]["keys"]:
			ids_ok = ids_ok and PoseLibrary.POSES.has(k[2])
	for id in PoseLibrary.ALL_HOLD_IDS:
		ids_ok = ids_ok and PoseLibrary.HOLDS.has(id)
	_check("all move/hold ids defined", ids_ok)
	# Reach at the first active frame (character at origin facing -Z).
	var chest_z := d.rig.get_bone_global_position(Bones.CHEST).z
	var hips_z := d.rig.get_bone_global_position(Bones.HIPS).z
	var reach := {}
	for id in PoseLibrary.STRIKE_BONES:
		var startup := 0.5 if String(id).begins_with("e_") else 0.18
		var finished := [false]
		var cb := func(m: StringName) -> void:
			if m == id:
				finished[0] = true
		d.animator.move_finished.connect(cb)
		d.animator.play_move(id, startup, 0.1, 0.2)
		var frames := int(roundf((startup + 0.02) * 120.0))
		for i in frames:
			await get_tree().physics_frame
		var bone: StringName = PoseLibrary.STRIKE_BONES[id][0]
		var p := d.rig.get_fist_position(bone) if bone in [Bones.L_HAND, Bones.R_HAND] else d.rig.get_bone_global_position(bone)
		reach[id] = p
		print("    %-16s %-14s at active: fwd %.2f m (from chest), height %.2f m, side %.2f m" % [id, bone, chest_z - p.z, p.y, p.x])
		for i in int(0.35 * 120.0):
			await get_tree().physics_frame
		_check("%s finishes on time" % id, finished[0])
		d.animator.move_finished.disconnect(cb)
	var jab: Vector3 = reach[&"jab1"]
	_check("jab1 fist ~0.6 m in front of chest", chest_z - jab.z > 0.5 and chest_z - jab.z < 0.85, "%.2f" % (chest_z - jab.z))
	var jab2: Vector3 = reach[&"jab2"]
	_check("jab2 fist ~0.6 m in front of chest", chest_z - jab2.z > 0.5 and chest_z - jab2.z < 0.85, "%.2f" % (chest_z - jab2.z))
	var kick: Vector3 = reach[&"sparta_kick"]
	_check("sparta kick foot ~0.9 m in front of hips", hips_z - kick.z > 0.75 and hips_z - kick.z < 1.1, "%.2f" % (hips_z - kick.z))
	var power: Vector3 = reach[&"power_punch"]
	_check("power punch reaches past the jab", power.z < jab.z, "%.2f vs %.2f" % [chest_z - power.z, chest_z - jab.z])
	var sweep: Vector3 = reach[&"leg_sweep"]
	_check("leg sweep foot low", sweep.y < 0.25, "foot y %.2f" % sweep.y)
	# Hitstop freeze.
	d.animator.play_move(&"jab2", 0.2, 0.1, 0.2)
	for i in 10:
		await get_tree().physics_frame
	d.animator.time_scale = 0.0
	var h0 := d.rig.get_bone_global_position(Bones.R_HAND)
	for i in 10:
		await get_tree().physics_frame
	var frozen := d.rig.get_bone_global_position(Bones.R_HAND).distance_to(h0) < 0.0001
	d.animator.time_scale = 1.0
	_check("time_scale 0 freezes", frozen)
	for i in 60:
		await get_tree().physics_frame
	# Planted feet while punching (legs come from locomotion IK).
	var f0 := d.rig.get_bone_global_position(Bones.L_FOOT)
	d.animator.play_move(&"jab2", 0.15, 0.1, 0.2)
	var slide := 0.0
	for i in 50:
		await get_tree().physics_frame
		slide = maxf(slide, d.rig.get_bone_global_position(Bones.L_FOOT).distance_to(f0))
	_check("lead foot stays planted during jab2", slide < 0.12, "%.3f m" % slide)
	# Holds blend in and out.
	d.animator.hold_pose(&"block")
	for i in 30:
		await get_tree().physics_frame
	var lf := d.rig.get_fist_position(Bones.L_HAND)
	_check("block raises fists to head height", lf.y > 1.5, "%.2f" % lf.y)
	d.animator.release_pose()
	for i in 40:
		await get_tree().physics_frame
	_check("release returns to idle", not d.animator.is_busy())
	print("POSES ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)
