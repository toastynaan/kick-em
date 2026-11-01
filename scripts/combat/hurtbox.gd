class_name Hurtbox
extends Area3D
## Hurtbox on one bone (spec: Hit pipeline step 1). Monitorable only: attacks
## find hurtboxes with shape queries on Layers.HURTBOX, so hurtboxes never run
## overlap callbacks themselves. Meta "fighter" (Fighter) and "bone" (StringName)
## are set for any code that only sees the Area3D.
## OWNER: agent B (fighter & combat).

## Player and elites (active ragdoll): about 10 hurtboxes.
const FULL_SET: Array[StringName] = [&"Head", &"Chest", &"Spine", &"Hips",
	&"LeftUpperArm", &"RightUpperArm", &"LeftUpperLeg", &"RightUpperLeg",
	&"LeftLowerLeg", &"RightLowerLeg"]
## Minions (passive ragdoll): 6 hurtboxes.
const MINION_SET: Array[StringName] = [&"Head", &"Chest", &"Spine", &"Hips",
	&"LeftLowerLeg", &"RightLowerLeg"]

## Shape radius per bone (m, before width scale).
const RADIUS := {
	&"Head": 0.15, &"Chest": 0.21, &"Spine": 0.19, &"Hips": 0.19,
	&"LeftUpperArm": 0.08, &"RightUpperArm": 0.08, &"LeftLowerArm": 0.07, &"RightLowerArm": 0.07,
	&"LeftUpperLeg": 0.11, &"RightUpperLeg": 0.11, &"LeftLowerLeg": 0.1, &"RightLowerLeg": 0.1,
}
## Fallback bone length (m at height 1.0) when the skeleton cannot tell us.
const LENGTH := {
	&"Hips": 0.12, &"Spine": 0.2, &"Chest": 0.3, &"Head": 0.24,
	&"LeftUpperArm": 0.3, &"RightUpperArm": 0.3, &"LeftLowerArm": 0.27, &"RightLowerArm": 0.27,
	&"LeftUpperLeg": 0.45, &"RightUpperLeg": 0.45, &"LeftLowerLeg": 0.45, &"RightLowerLeg": 0.45,
}
## Child bone whose rest offset gives the bone's length.
const LENGTH_FROM := {
	&"Hips": &"Spine", &"Spine": &"Chest", &"Chest": &"Head",
	&"LeftUpperArm": &"LeftLowerArm", &"RightUpperArm": &"RightLowerArm",
	&"LeftLowerArm": &"LeftHand", &"RightLowerArm": &"RightHand",
	&"LeftUpperLeg": &"LeftLowerLeg", &"RightUpperLeg": &"RightLowerLeg",
	&"LeftLowerLeg": &"LeftFoot", &"RightLowerLeg": &"RightFoot",
}
## Position relative to the fighter's feet when the rig has no bone attachments
## yet (stub rig): (x, y) at height 1.0.
const FALLBACK_POS := {
	&"Head": Vector2(0.0, 1.65), &"Chest": Vector2(0.0, 1.35), &"Spine": Vector2(0.0, 1.13),
	&"Hips": Vector2(0.0, 0.95), &"LeftUpperArm": Vector2(-0.24, 1.3),
	&"RightUpperArm": Vector2(0.24, 1.3), &"LeftLowerArm": Vector2(-0.26, 1.0),
	&"RightLowerArm": Vector2(0.26, 1.0), &"LeftUpperLeg": Vector2(-0.1, 0.7),
	&"RightUpperLeg": Vector2(0.1, 0.7), &"LeftLowerLeg": Vector2(-0.1, 0.28),
	&"RightLowerLeg": Vector2(0.1, 0.28),
}

var fighter: Fighter
var bone: StringName

func _init(p_fighter: Fighter = null, p_bone: StringName = &"") -> void:
	fighter = p_fighter
	bone = p_bone
	name = "Hurtbox_%s" % p_bone
	monitoring = false
	monitorable = true
	collision_layer = Layers.HURTBOX
	collision_mask = 0
	set_meta(&"fighter", p_fighter)
	set_meta(&"bone", p_bone)

## Create the hurtbox set for `f` (after its rig is built). Returns them.
static func build_for(f: Fighter, full: bool) -> Array[Hurtbox]:
	var out: Array[Hurtbox] = []
	var app: Dictionary = f.config.get("appearance", {})
	var h: float = app.get("height", 1.0)
	var w: float = app.get("width", 1.0)
	var bones: Array[StringName] = FULL_SET if full else MINION_SET
	for b in bones:
		var hb := Hurtbox.new(f, b)
		var radius: float = RADIUS.get(b, 0.12) * lerpf(1.0, w, 0.7)
		if not full:
			radius *= 1.15  # fewer boxes, so each covers a bit more
		var length := _bone_length(f, b, h)
		var shape := CapsuleShape3D.new()
		shape.radius = radius
		shape.height = maxf(length + radius * 1.2, radius * 2.0 + 0.01)
		var cs := CollisionShape3D.new()
		cs.shape = shape
		hb.add_child(cs)
		var att: Node3D = f.rig.get_attachment(b) if f.rig else null
		if att:
			# Bone-local: spine bones point +Y, limbs -Y. Centre the capsule on the bone.
			var dir := 1.0 if b in [&"Hips", &"Spine", &"Chest", &"Head"] else -1.0
			cs.position = Vector3(0.0, dir * length * 0.5, 0.0)
			att.add_child(hb)
		else:
			var p: Vector2 = FALLBACK_POS.get(b, Vector2(0.0, 1.0))
			hb.position = Vector3(p.x * w, p.y * h, 0.0)
			f.add_child(hb)
		out.append(hb)
	return out

static func _bone_length(f: Fighter, b: StringName, h: float) -> float:
	var fallback: float = LENGTH.get(b, 0.25) * h
	if f.rig == null or f.rig.skeleton == null:
		return fallback
	var sk := f.rig.skeleton
	var child: StringName = LENGTH_FROM.get(b, &"")
	if child == &"":
		return fallback
	var idx := sk.find_bone(String(child))
	if idx < 0:
		return fallback
	var l := sk.get_bone_rest(idx).origin.length()
	return l if l > 0.03 else fallback

func set_enabled(on: bool) -> void:
	monitorable = on
	for c in get_children():
		if c is CollisionShape3D:
			(c as CollisionShape3D).set_deferred(&"disabled", not on)
