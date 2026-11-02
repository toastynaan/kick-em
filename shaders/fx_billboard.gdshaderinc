// Shared body of the additive billboard FX shaders (limb-glow halos, impact
// flashes and rings, dazed stars). OWNER: agent F.
// Per-instance: tint (rgb, a = strength) and spin (radians) so one material
// serves every node (GeometryInstance3D.set_instance_shader_parameter).

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
instance uniform vec4 tint : source_color = vec4(1.0);
instance uniform float spin = 0.0;

void vertex() {
	float c = cos(spin);
	float s = sin(spin);
	VERTEX.xy = vec2(c * VERTEX.x - s * VERTEX.y, s * VERTEX.x + c * VERTEX.y);
	// Billboard that keeps the node's scale.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1],
			INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
			vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec4 t = texture(tex, UV);
	ALBEDO = t.rgb * tint.rgb * t.a * tint.a;
	ALPHA = 1.0;
}
