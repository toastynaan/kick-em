shader_type spatial;
// Vertical streak (WorldFX): a heavy landing's streak (Feel Reference: Landing
// has levels; Prototype 4 at 57.9 s). An axis-locked billboard: it stands on
// the node's up axis and turns about it to face the camera. Bright at the
// bottom (the landing point), fading upward. Brand colour. OWNER: agent F.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 color : source_color = vec3(1.0, 0.94, 0.85);
instance uniform float fade = 1.0;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 up = normalize(MODEL_MATRIX[1].xyz);
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	vec3 to_cam = CAMERA_POSITION_WORLD - origin;
	vec3 right = cross(up, to_cam);
	right = length(right) > 1e-4 ? normalize(right) : vec3(1.0, 0.0, 0.0);
	vec3 world = origin + right * VERTEX.x * sx + up * VERTEX.y * sy;
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));
}

void fragment() {
	float across = abs(UV.x * 2.0 - 1.0);
	float core = exp(-across * across * 9.0) + exp(-across * across * 60.0) * 0.8;
	float along = pow(clamp(UV.y, 0.0, 1.0), 1.6);
	ALBEDO = color * core * along * fade * 1.6;
}
