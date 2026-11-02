shader_type spatial;
// Teleport after-image (ScreenFX; Feel Reference: On the character > After-image):
// a copy of the player's mesh parts that fades over Tuning.AFTERIMAGE_FADE.
// Additive: a soft fill and a bright fresnel edge in the brand colour.
// OWNER: agent F.
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

uniform vec3 color : source_color = vec3(1.0, 0.94, 0.85);
instance uniform float fade = 1.0;

void fragment() {
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	ALBEDO = color * (0.18 + 1.1 * fres) * fade;
}
