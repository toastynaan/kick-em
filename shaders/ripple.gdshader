shader_type spatial;
// Water ripple rings (WorldFX; Feel Reference: On the world > Water, Sifu 2 at
// 3.6-5.35 s): a flat additive quad on the water whose ring expands and fades.
// Per instance: age 0..1, strength. OWNER: agent F.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 color : source_color = vec3(0.85, 0.93, 1.0);
instance uniform float age = 0.0;
instance uniform float strength = 1.0;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float d = length(p);
	float grow = 1.0 - pow(1.0 - clamp(age, 0.0, 1.0), 2.2);
	float r = mix(0.08, 0.95, grow);
	float w = mix(0.035, 0.1, age);
	float ring = exp(-pow((d - r) / w, 2.0));
	float inner = exp(-pow((d - r * 0.7) / (w * 0.8), 2.0)) * 0.45;
	float a = (ring + inner) * (1.0 - age) * strength * (1.0 - smoothstep(0.96, 1.0, d));
	ALBEDO = color * a * 0.55;
}
