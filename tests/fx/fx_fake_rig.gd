extends Node3D
## Stand-in for HumanoidRig in FX tests: box parts on per-bone attachment
## nodes, each with its own fighter.gdshader material. OWNER: agent F.

const FIGHTER_SHADER := preload("res://shaders/fighter.gdshader")

var parts: Array[MeshInstance3D] = []
var attachments: Dictionary = {}

## Standing mannequin: hips 0.95 m, chest 1.35 m, head 1.72 m (rig conventions).
func build_body() -> void:
	add_part(Bones.HIPS, Vector3(0.34, 0.22, 0.22), Vector3(0, 0.95, 0))
	add_part(Bones.SPINE, Vector3(0.32, 0.2, 0.2), Vector3(0, 1.12, 0))
	add_part(Bones.CHEST, Vector3(0.4, 0.3, 0.24), Vector3(0, 1.35, 0))
	add_part(Bones.HEAD, Vector3(0.2, 0.24, 0.22), Vector3(0, 1.72, 0))
	add_part(Bones.L_UPPER_ARM, Vector3(0.1, 0.28, 0.1), Vector3(-0.3, 1.32, 0))
	add_part(Bones.L_LOWER_ARM, Vector3(0.09, 0.26, 0.09), Vector3(-0.3, 1.05, 0))
	add_part(Bones.R_UPPER_ARM, Vector3(0.1, 0.28, 0.1), Vector3(0.3, 1.32, 0))
	add_part(Bones.R_LOWER_ARM, Vector3(0.09, 0.26, 0.09), Vector3(0.3, 1.05, 0))
	add_part(Bones.L_UPPER_LEG, Vector3(0.14, 0.4, 0.14), Vector3(-0.1, 0.65, 0))
	add_part(Bones.L_LOWER_LEG, Vector3(0.11, 0.4, 0.11), Vector3(-0.1, 0.25, 0))
	add_part(Bones.R_UPPER_LEG, Vector3(0.14, 0.4, 0.14), Vector3(0.1, 0.65, 0))
	add_part(Bones.R_LOWER_LEG, Vector3(0.11, 0.4, 0.11), Vector3(0.1, 0.25, 0))
	add_part(Bones.L_HAND, Vector3(0.08, 0.1, 0.09), Vector3(-0.3, 0.86, 0))
	add_part(Bones.R_HAND, Vector3(0.08, 0.1, 0.09), Vector3(0.3, 0.86, 0))
	add_part(Bones.L_FOOT, Vector3(0.1, 0.07, 0.25), Vector3(-0.1, 0.04, -0.05))
	add_part(Bones.R_FOOT, Vector3(0.1, 0.07, 0.25), Vector3(0.1, 0.04, -0.05))

func add_part(bone: StringName, size: Vector3, pos: Vector3, part_basis := Basis(),
		shared: ShaderMaterial = null) -> MeshInstance3D:
	var att := Node3D.new()
	att.name = String(bone)
	att.transform = Transform3D(part_basis, pos)
	add_child(att)
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	var mat := shared
	if mat == null:
		mat = ShaderMaterial.new()
		mat.shader = FIGHTER_SHADER
	mi.material_override = mat
	mi.layers = Layers.VIS_CHARACTERS
	att.add_child(mi)
	parts.append(mi)
	attachments[bone] = att
	return mi

func get_mesh_parts() -> Array[MeshInstance3D]:
	return parts

## Parts riding one bone (HumanoidRig API).
func get_bone_parts(bone: StringName) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var a: Node3D = attachments.get(bone)
	if a != null:
		for c in a.get_children():
			if c is MeshInstance3D:
				out.append(c)
	return out

func get_attachment(bone: StringName) -> Node3D:
	return attachments.get(bone)

func get_bone_global_transform(bone: StringName) -> Transform3D:
	var a: Node3D = attachments.get(bone)
	return a.global_transform if a else global_transform

func get_bone_global_position(bone: StringName) -> Vector3:
	return get_bone_global_transform(bone).origin
