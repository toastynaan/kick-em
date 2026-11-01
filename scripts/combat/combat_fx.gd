class_name CombatFX
## Small visual effects owned by combat: the perfect-dodge afterimage and the
## teleport puff. Blood and sound belong to agent F (event-driven).
## OWNER: agent B (fighter & combat).

const AFTERIMAGE_COLOR := Color(0.65, 0.85, 1.0, 0.45)
const AFTERIMAGE_TIME := 0.3   ## game s (lingers in slow motion)
const PUFF_TIME := 0.25

## Translucent copy of the fighter's current pose that fades out.
static func afterimage(f: Fighter, color := AFTERIMAGE_COLOR, duration := AFTERIMAGE_TIME) -> void:
	if f == null or not f.is_inside_tree():
		return
	var parent := f.get_parent()
	if parent == null:
		return
	var parts: Array[MeshInstance3D] = f.rig.get_mesh_parts() if f.rig else []
	if parts.is_empty():
		puff(f.get_aim_point(), color, duration)
		return
	var holder := Node3D.new()
	holder.name = "Afterimage"
	holder.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	parent.add_child(holder)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = color
	for p in parts:
		if not is_instance_valid(p) or p.mesh == null or not p.is_visible_in_tree():
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = p.mesh
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.layers = Layers.VIS_FX
		holder.add_child(mi)
		mi.global_transform = p.global_transform
	var tw := holder.create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, duration)
	tw.tween_callback(holder.queue_free)

## Expanding, fading sphere (teleport in/out).
static func puff(pos: Vector3, color := AFTERIMAGE_COLOR, duration := PUFF_TIME) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "Puff"
	mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var sm := SphereMesh.new()
	sm.radius = 0.35
	sm.height = 0.7
	sm.radial_segments = 12
	sm.rings = 6
	mi.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.layers = Layers.VIS_FX
	tree.current_scene.add_child(mi)
	mi.global_position = pos
	var tw := mi.create_tween().set_parallel(true)
	tw.tween_property(mi, "scale", Vector3.ONE * 2.2, duration)
	tw.tween_property(mat, "albedo_color:a", 0.0, duration)
	tw.chain().tween_callback(mi.queue_free)

## Clash spark between two hands (grab break).
static func spark(pos: Vector3) -> void:
	puff(pos, Color(1.0, 0.85, 0.35, 0.8), 0.12)
