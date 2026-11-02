shader_type spatial;
// Focus tint (ScreenFX; Feel Reference: Screen effects > Focus tint, Prototype 4
// at 9.5-10.5 s): a full-screen quad drawn first in the transparent pass. It
// desaturates the world to Tuning.FOCUS_SATURATION with a cool tint everywhere
// EXCEPT where the stencil holds 1: the player and glowing enemy limbs write
// it through keep_color_mask.gdshader (a next_pass on their materials). Drawn
// at render_priority -90, after the mask (-100); additive FX (glow halos,
// flashes, trails) draw after it in full colour, and the HUD (off-screen
// arrows) is a CanvasLayer above the 3D view. OWNER: agent F.
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled, fog_disabled;
stencil_mode read, compare_not_equal, 1;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
// 0..1 how far Focus has faded in.
uniform float amount : hint_range(0.0, 1.0) = 0.0;
// World saturation at full amount.
uniform float saturation : hint_range(0.0, 1.0) = 0.4;
uniform vec3 tint : source_color = vec3(0.82, 0.92, 1.12);
uniform float darken : hint_range(0.0, 1.0) = 0.08;

void vertex() {
	// A 2 x 2 quad covering clip space.
	POSITION = vec4(VERTEX.xy, 0.5, 1.0);
}

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	vec3 g = mix(vec3(l), c, saturation) * tint * (1.0 - darken);
	ALBEDO = mix(c, g, amount);
}
